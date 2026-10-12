import Foundation
import CoreGraphics
import Darwin

nonisolated enum EPSError: LocalizedError {
    case invalid, limit, interpreter, render, timeout
    var errorDescription: String? {
        switch self {
        case .invalid: L10n.text("The EPS file is damaged or has no usable bounding box.")
        case .limit: L10n.text("EPS supports up to 16 megapixels, 30,000 pixels per side, and 128 MiB per file.")
        case .interpreter: L10n.text("Install the current Ghostscript 10 release, then choose its folder in Settings → EPS Import. Compositor's own raster EPS files open without it.")
        case .render: L10n.text("The EPS could not be rendered. Embedded fonts or external resources may be unavailable.")
        case .timeout: L10n.text("EPS rendering took too long and was stopped.")
        }
    }
}

/// A small, original raster EPS writer and reader. Other EPS programs are rendered
/// by a separately installed interpreter, never evaluated in the application.
nonisolated enum EPSCodec {
    static let maxPixels = 16_000_000
    static let maxBytes = 128 * 1024 * 1024
    private static let ending = Data("grestore\nshowpage\n%%EOF\n".utf8)

    static func matches(_ url: URL) -> Bool {
        ["eps", "epsf", "epsi"].contains(url.pathExtension.lowercased())
    }

    private static func number(_ value: Double) -> String {
        let scaled = Int64((abs(value) * 1_000_000).rounded())
        return (value < 0 && scaled != 0 ? "-" : "") + String(scaled / 1_000_000) + "." + String(format: "%06lld", scaled % 1_000_000)
    }

    private static func header(width: Int, height: Int, dpi: Double) -> Data {
        let w = Double(width) * 72 / dpi, h = Double(height) * 72 / dpi
        return Data(("%!PS-Adobe-3.0 EPSF-3.0\n" +
            "%%Creator: Compositor Raster EPS 1\n" +
            "%%BoundingBox: 0 0 \(Int(ceil(w))) \(Int(ceil(h)))\n" +
            "%%HiResBoundingBox: 0 0 \(number(w)) \(number(h))\n" +
            "%%LanguageLevel: 2\n%%Pages: 1\n" +
            "%%CompositorRaster: \(width) \(height) \(number(dpi))\n" +
            "%%EndComments\ngsave\n\(number(w)) \(number(h)) scale\n" +
            "/row \(width * 3 <= 65535 ? width * 3 : width) string def\n" +
            "\(width) \(height) 8 [\(width) 0 0 -\(height) 0 \(height)]\n" +
            "{currentfile row readhexstring pop} false 3 colorimage\n").utf8)
    }

    static func encode(_ image: CGImage, resolution: Double) throws -> Data {
        let w = image.width, h = image.height
        try checkSize(w, h, remainingPixels: maxPixels)
        let dpi = resolution.isFinite && (1...9600).contains(resolution) ? (resolution * 1_000_000).rounded() / 1_000_000 : 72
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue),
            let raw = context.data else { throw ExportError.render }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = raw.assumingMemoryBound(to: UInt8.self)
        let hex = Array("0123456789ABCDEF".utf8)
        var output = header(width: w, height: h, dpi: dpi)
        output.reserveCapacity(w * h * 6 + (w * h * 3 + 35) / 36 + output.count + ending.count)
        var block = [UInt8](); block.reserveCapacity(256 * 1024)
        var column = 0
        for y in 0..<h {
            try Task.checkCancellation()
            for x in 0..<w {
                let at = y * context.bytesPerRow + x * 4
                for component in 0..<3 {
                    let value = pixels[at + component]
                    block.append(hex[Int(value >> 4)]); block.append(hex[Int(value & 15)])
                    column += 1
                    if column == 36 { block.append(10); column = 0 }
                }
                if block.count >= 256 * 1024 { output.append(contentsOf: block); block.removeAll(keepingCapacity: true) }
            }
        }
        if column != 0 { block.append(10) }
        output.append(contentsOf: block); output.append(ending)
        guard output.count <= maxBytes else { throw EPSError.limit }
        return output
    }

    static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 0, size <= maxBytes else { throw EPSError.limit }
        try handle.seek(toOffset: 0)
        guard let data = try handle.read(upToCount: maxBytes + 1), data.count <= maxBytes else { throw EPSError.limit }
        // DOS EPS wraps a PostScript section and optional previews in a binary header.
        if data.prefix(4) == Data([0xc5, 0xd0, 0xd3, 0xc6]) {
            guard data.count >= 30 else { throw EPSError.invalid }
            func u32(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(data[at + $1]) << ($1 * 8) } }
            let start = u32(4), count = u32(8)
            guard start >= 30, count > 0, start <= data.count, count <= data.count - start else { throw EPSError.invalid }
            return data.subdata(in: start..<(start + count))
        }
        return data
    }

    /// Only accept the complete known program; a forged Creator comment never
    /// bypasses the interpreter for arbitrary PostScript.
    static func ownImage(_ data: Data, remainingPixels: Int) throws -> (image: CGImage, resolution: Double)? {
        let head = String(decoding: data.prefix(2048), as: UTF8.self)
        guard head.hasPrefix("%!PS-Adobe-3.0 EPSF-3.0\n%%Creator: Compositor Raster EPS 1\n") else { return nil }
        guard let line = head.split(separator: "\n").first(where: { $0.hasPrefix("%%CompositorRaster: ") }) else { throw EPSError.invalid }
        let fields = line.split(separator: " ")
        guard fields.count == 4, let w = Int(fields[1]), let h = Int(fields[2]),
              let dpi = Double(fields[3]), dpi.isFinite, (1...9600).contains(dpi) else { throw EPSError.invalid }
        try checkSize(w, h, remainingPixels: remainingPixels)
        let prefix = header(width: w, height: h, dpi: dpi)
        guard data.starts(with: prefix), data.suffix(ending.count) == ending else { throw EPSError.invalid }
        var rgb = Data(); rgb.reserveCapacity(w * h * 3)
        var high: UInt8?
        for c in data[prefix.count..<(data.count - ending.count)] {
            if c == 10 { continue }
            let v: UInt8
            switch c {
            case 48...57: v = c - 48
            case 65...70: v = c - 55
            default: throw EPSError.invalid
            }
            if let first = high {
                guard rgb.count < w * h * 3 else { throw EPSError.invalid }
                rgb.append(first << 4 | v); high = nil
            } else { high = v }
        }
        guard high == nil, rgb.count == w * h * 3,
              let provider = CGDataProvider(data: rgb as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24,
                bytesPerRow: w * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: [],
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw EPSError.invalid }
        return (image, dpi)
    }

    static func checkSize(_ w: Int, _ h: Int, remainingPixels: Int) throws {
        guard (1...DocumentLimits.maxSide).contains(w), (1...DocumentLimits.maxSide).contains(h),
              w * h <= min(maxPixels, remainingPixels) else { throw EPSError.limit }
    }

    private static func bounds(_ data: Data) throws -> [Double] {
        let first = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        guard let signature = first.split(whereSeparator: \.isNewline).first,
              signature.hasPrefix("%!PS-Adobe-"), signature.contains("EPSF-") else { throw EPSError.invalid }
        let sections = [first, String(decoding: data.suffix(64 * 1024), as: UTF8.self)]
        for key in ["%%HiResBoundingBox:", "%%BoundingBox:"] {
            for section in sections {
                for line in section.split(whereSeparator: \.isNewline) where line.hasPrefix(key) {
                    let values = line.dropFirst(key.count).split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
                    if values.count == 4, values.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
                       values[2] > values[0], values[3] > values[1] { return values }
                }
            }
        }
        throw EPSError.invalid
    }

    static func render(_ data: Data, remainingPixels: Int) throws -> Data {
        let box = try bounds(data)
        // 144 DPI is fixed for general EPS. Explicit geometry and FIXEDMEDIA keep
        // untrusted page-size changes from allocating an unbounded page surface.
        let w = Int(ceil((box[2] - box[0]) * 2)), h = Int(ceil((box[3] - box[1]) * 2))
        try checkSize(w, h, remainingPixels: remainingPixels)
        let authorized = GhostscriptAccess.folder()
        let scoped = authorized?.startAccessingSecurityScopedResource() == true
        defer { if scoped { authorized?.stopAccessingSecurityScopedResource() } }
        let candidates = [authorized?.appendingPathComponent("bin/gs").path, ProcessInfo.processInfo.environment["COMPOSITOR_GHOSTSCRIPT"],
                          "/opt/homebrew/bin/gs", "/usr/local/bin/gs"].compactMap { $0 }
        guard let executable = candidates.first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }) else { throw EPSError.interpreter }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("compositor-eps-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("source.eps"), output = folder.appendingPathComponent("render.png")
        try data.write(to: input, options: .withoutOverwriting)
        let environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GS_") }
        let version = try run(executable, arguments: ["--version"], folder: folder, environment: environment, seconds: 3, capturesOutput: true)
        guard (Int(String(decoding: version, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").first ?? "") ?? 0) >= 10 else { throw EPSError.interpreter }
        _ = try run(executable, arguments: ["-dSAFER", "-dBATCH", "-dNOPAUSE", "-dQUIET", "-dFIXEDMEDIA",
            "-sDEVICE=pngalpha", "-r144", "-g\(w)x\(h)", "-dTextAlphaBits=4", "-dGraphicsAlphaBits=4",
            "-dNumRenderingThreads=1", "-dMaxBitmap=67108864", "-dBufferSpace=8388608",
            "--permit-file-read=\(input.path)", "--permit-file-write=\(output.path)",
            "-sOutputFile=\(output.path)", "-c", "\(number(-box[0])) \(number(-box[1])) translate", "-f", input.path],
            folder: folder, environment: environment, seconds: 30)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= maxBytes else { throw EPSError.limit }
        return try Data(contentsOf: output)
    }

    private static func run(_ executable: String, arguments: [String], folder: URL,
                            environment: [String: String], seconds: Double, capturesOutput: Bool = false) throws -> Data {
        let process = Process(), pipe = capturesOutput ? Pipe() : nil
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments; process.currentDirectoryURL = folder
        var environment = environment; environment["TMPDIR"] = folder.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe.map { $0 as Any } ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { throw EPSError.interpreter }
        if finished.wait(timeout: .now() + seconds) == .timedOut {
            // Do not leave an interpreter running after a timeout, even if it
            // ignores SIGTERM. No shell or interpolated filename is involved.
            kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
            throw EPSError.timeout
        }
        guard process.terminationStatus == 0 else { throw EPSError.render }
        return try pipe?.fileHandleForReading.read(upToCount: 4096) ?? Data()
    }
}
