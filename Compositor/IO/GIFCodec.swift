import Foundation
import CoreGraphics
import ImageIO

nonisolated struct GIFImport: @unchecked Sendable {
    let width: Int
    let height: Int
    let frames: [ImportedImage]
    let durations: [Int]
    let loopCount: Int
}

/// Parse GIF block geometry ourselves; ImageIO decodes each isolated LZW patch.
/// Compositing full frames here preserves disposal 2/3, local palettes and offsets.
nonisolated enum GIFCodec {
    static func matches(_ url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 6) else { return false }
        return ["GIF87a", "GIF89a"].contains(String(decoding: data, as: UTF8.self))
    }

    static func header(width: Int, height: Int, loops: Int) -> Data {
        var bytes = Array("GIF89a".utf8) + [UInt8(width & 255), UInt8(width >> 8), UInt8(height & 255), UInt8(height >> 8), 0x70, 0, 0]
        if loops >= 0 { bytes += [0x21, 0xff, 11] + Array("NETSCAPE2.0".utf8) + [3, 1, UInt8(loops & 255), UInt8(loops >> 8), 0] }
        return Data(bytes)
    }

    /// ImageIO quantizes and compresses one frame. Give it a local palette and
    /// explicit disposal 2 so transparent pixels never expose the preceding frame.
    static func encodedFrame(_ data: Data, width: Int, height: Int, duration: Int) throws -> Data {
        try Task.checkCancellation()
        let bytes = [UInt8](data)
        guard bytes.count > 13 else { throw ExportError.encode }
        let tableSize = bytes[10] & 0x80 == 0 ? 0 : 3 * (1 << (Int(bytes[10] & 7) + 1))
        guard 13 + tableSize < bytes.count else { throw ExportError.encode }
        var p = 13 + tableSize, transparency: UInt8 = 0, transparentIndex: UInt8 = 0
        while p < bytes.count {
            let marker = bytes[p]; p += 1
            if marker == 0x21 {
                guard p < bytes.count else { throw ExportError.encode }
                let kind = bytes[p]; p += 1
                if kind == 0xf9 {
                    guard p + 6 <= bytes.count, bytes[p] == 4 else { throw ExportError.encode }
                    transparency = bytes[p + 1] & 1; transparentIndex = bytes[p + 4]
                }
                while p < bytes.count {
                    try Task.checkCancellation()
                    let count = Int(bytes[p]); p += 1
                    if count == 0 { break }
                    guard p + count < bytes.count else { throw ExportError.encode }; p += count
                }
            } else if marker == 0x2c {
                guard p + 10 < bytes.count else { throw ExportError.encode }
                let word: (Int) -> Int = { Int(bytes[$0]) | Int(bytes[$0 + 1]) << 8 }
                guard word(p) == 0, word(p + 2) == 0, word(p + 4) == width, word(p + 6) == height else { throw ExportError.encode }
                var descriptor = Array(bytes[p..<p + 9]); p += 9
                let localSize = descriptor[8] & 0x80 == 0 ? 0 : 3 * (1 << (Int(descriptor[8] & 7) + 1))
                let palette: [UInt8]
                if localSize > 0 {
                    guard p + localSize < bytes.count else { throw ExportError.encode }
                    palette = Array(bytes[p..<p + localSize]); p += localSize
                } else {
                    guard tableSize > 0 else { throw ExportError.encode }
                    palette = Array(bytes[13..<13 + tableSize]); descriptor[8] = (descriptor[8] & 0x78) | 0x80 | (bytes[10] & 7)
                }
                let start = p; p += 1
                while p < bytes.count {
                    try Task.checkCancellation()
                    let count = Int(bytes[p]); p += 1
                    if count == 0 { break }
                    guard p + count < bytes.count else { throw ExportError.encode }; p += count
                }
                guard p == bytes.count - 1, bytes[p] == 0x3b else { throw ExportError.encode }
                let delay = duration / 10
                return Data([0x21, 0xf9, 4, 8 | transparency, UInt8(delay & 255), UInt8(delay >> 8), transparentIndex, 0, 0x2c] + descriptor + palette + Array(bytes[start..<p]))
            } else { throw ExportError.encode }
        }
        throw ExportError.encode
    }

    private struct Patch {
        let x: Int, y: Int, width: Int, height: Int
        let range: Range<Int>
        let control: [UInt8]
        let duration: Int, disposal: Int, transparent: Bool
    }
    private static func validateLZW(_ bytes: UnsafeBufferPointer<UInt8>, start: Int, end: Int, pixels: Int, palette: Int) throws {
        func invalid() throws -> Never { throw ImageImportError.unreadable }
        let minimum = Int(bytes[start])
        guard (2...8).contains(minimum) else { try invalid() }
        var p = start + 1, remaining = 0, bits = 0, value = 0
        func byte() throws -> Int {
            if remaining == 0 {
                guard p < end else { try invalid() }
                remaining = Int(bytes[p]); p += 1
                guard remaining > 0, p + remaining < end else { try invalid() }
            }
            remaining -= 1
            defer { p += 1 }
            return Int(bytes[p])
        }
        func code(_ width: Int) throws -> Int {
            while bits < width { value |= try byte() << bits; bits += 8 }
            let result = value & ((1 << width) - 1); value >>= width; bits -= width
            return result
        }
        let clear = 1 << minimum, stop = clear + 1
        var lengths = [Int](repeating: 0, count: 4096), next = stop + 1, width = minimum + 1, previous = 0, count = 0
        var iterations = 0
        while true {
            if iterations % 1024 == 0 { try Task.checkCancellation() }; iterations += 1
            let c = try code(width)
            if c == clear { next = stop + 1; width = minimum + 1; previous = 0; continue }
            if c == stop { guard count == pixels else { try invalid() }; return }
            let length: Int
            if c < clear { guard c < palette else { try invalid() }; length = 1 }
            else if c < next { length = lengths[c] }
            else if c == next, previous > 0 { length = previous + 1 }
            else { try invalid() }
            guard length > 0, count + length <= pixels else { try invalid() }
            count += length
            if previous > 0, next < 4096 {
                lengths[next] = previous + 1; next += 1
                if next == 1 << width, width < 12 { width += 1 }
            }
            previous = length
        }
    }
    static func decode(_ data: Data, name: String, remainingPixels: Int) throws -> GIFImport {
        guard data.count >= 14, data.count <= 64 * 1024 * 1024 else { throw ImageImportError.gifTooLarge }
        try Task.checkCancellation()
        let started = PerformanceRecorder.shared.begin()
        defer { PerformanceRecorder.shared.end(.gifDecode, since: started) }
        return try data.withUnsafeBytes { raw in
            try decodeBytes(raw.bindMemory(to: UInt8.self), name: name, remainingPixels: remainingPixels)
        }
    }
    private static func decodeBytes(_ bytes: UnsafeBufferPointer<UInt8>, name: String, remainingPixels: Int) throws -> GIFImport {
        guard ["GIF87a", "GIF89a"].contains(String(decoding: bytes.prefix(6), as: UTF8.self)) else { throw ImageImportError.unreadable }
        func word(_ p: Int) -> Int { Int(bytes[p]) | Int(bytes[p + 1]) << 8 }
        let width = word(6), height = word(8), pixels = width * height
        guard width > 0, height > 0, width <= DocumentLimits.maxSide, height <= DocumentLimits.maxSide,
              pixels <= AnimationTrack.maxFramePixels else { throw ImageImportError.gifTooLarge }
        var p = 13
        let tableSize = bytes[10] & 0x80 == 0 ? 0 : 3 * (1 << (Int(bytes[10] & 7) + 1))
        guard p + tableSize <= bytes.count else { throw ImageImportError.unreadable }
        let table = Array(bytes[p..<p + tableSize]); p += tableSize
        var patches: [Patch] = [], control: [UInt8] = [], duration = 100, disposal = 0, transparent = false, loopCount = -1
        func blocks(captureLimit: Int = 0) throws -> [UInt8] {
            var result: [UInt8] = []
            while p < bytes.count {
                try Task.checkCancellation()
                let count = Int(bytes[p]); p += 1
                if count == 0 { return result }
                guard p + count <= bytes.count else { throw ImageImportError.unreadable }
                let kept = min(count, max(0, captureLimit - result.count))
                if kept > 0 { result += bytes[p..<p + kept] }
                p += count
            }
            throw ImageImportError.unreadable
        }
        var complete = false
        while p < bytes.count {
            try Task.checkCancellation()
            let marker = bytes[p]; p += 1
            if marker == 0x3b { complete = true; break }
            if marker == 0x21 {
                guard p < bytes.count else { throw ImageImportError.unreadable }
                let kind = bytes[p]; p += 1
                let start = p, content = try blocks(captureLimit: 32)
                if kind == 0xf9 {
                    guard content.count == 4, bytes[start] == 4 else { throw ImageImportError.unreadable }
                    disposal = Int((content[0] >> 2) & 7)
                    guard disposal <= 3 else { throw ImageImportError.unreadable }
                    let delay = Int(content[1]) | Int(content[2]) << 8
                    duration = delay == 0 ? 100 : delay * 10
                    transparent = content[0] & 1 != 0
                    control = [0x21, 0xf9] + Array(bytes[start..<p])
                } else if kind == 0xff, content.count >= 14,
                          ["NETSCAPE2.0", "ANIMEXTS1.0"].contains(String(decoding: content.prefix(11), as: UTF8.self)), content[11] == 1 {
                    loopCount = Int(content[12]) | Int(content[13]) << 8
                } else if kind == 0x01 {
                    // Plain-text blocks draw pixels too. Refuse an unsupported rendering primitive.
                    throw ImageImportError.gifUnsupported
                }
                continue
            }
            guard marker == 0x2c, p + 9 < bytes.count else { throw ImageImportError.unreadable }
            let x = word(p), y = word(p + 2), w = word(p + 4), h = word(p + 6), flags = bytes[p + 8]
            guard w > 0, h > 0, x + w <= width, y + h <= height,
                  patches.count < AnimationTrack.maxFrames,
                  pixels * (patches.count + 1) <= min(AnimationTrack.maxPixels, remainingPixels) else { throw ImageImportError.gifTooLarge }
            let descriptor = p; p += 9
            let localSize = flags & 0x80 == 0 ? 0 : 3 * (1 << (Int(flags & 7) + 1))
            guard p + localSize + 1 < bytes.count, localSize > 0 || tableSize > 0 else { throw ImageImportError.unreadable }
            p += localSize
            let streamStart = p
            guard (2...8).contains(bytes[p]) else { throw ImageImportError.unreadable }
            p += 1; _ = try blocks()
            let paletteCount = (localSize > 0 ? localSize : tableSize) / 3
            guard !transparent || control.count == 8 && Int(control[6]) < paletteCount else { throw ImageImportError.unreadable }
            try validateLZW(bytes, start: streamStart, end: p, pixels: w * h, palette: paletteCount)
            patches.append(Patch(x: x, y: y, width: w, height: h, range: descriptor + 4..<p, control: control,
                duration: duration, disposal: disposal, transparent: transparent))
            control = []; duration = 100; disposal = 0; transparent = false
        }
        guard complete, p == bytes.count, !patches.isEmpty else { throw ImageImportError.unreadable }
        var canvas = [UInt8](repeating: 0, count: pixels * 4), frames: [ImportedImage] = []
        let backgroundIndex = Int(bytes[11]), hasBackground = tableSize > 0 && backgroundIndex * 3 + 2 < table.count
        let background: [UInt8] = hasBackground ? Array(table[backgroundIndex * 3..<backgroundIndex * 3 + 3]) + [255] : [0, 0, 0, 0]
        if !patches[0].transparent {
            for y in 0..<height {
                if y % 64 == 0 { try Task.checkCancellation() }
                for x in 0..<width { for c in 0..<4 { canvas[(y * width + x) * 4 + c] = background[c] } }
            }
        }
        for patch in patches {
            try Task.checkCancellation()
            let previous = patch.disposal == 3 ? canvas : []
            let image: CGImage = try autoreleasepool {
                // Keep ranges into the immutable input; construct only the patch currently being decoded.
                var isolated = Data(bytes.prefix(13))
                isolated[6] = UInt8(patch.width & 255); isolated[7] = UInt8(patch.width >> 8)
                isolated[8] = UInt8(patch.height & 255); isolated[9] = UInt8(patch.height >> 8)
                isolated.append(contentsOf: table); isolated.append(contentsOf: patch.control)
                isolated.append(contentsOf: [0x2c, 0, 0, 0, 0]); isolated.append(contentsOf: bytes[patch.range]); isolated.append(0x3b)
                guard let source = CGImageSourceCreateWithData(isolated as CFData, nil),
                      CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == patch.width, image.height == patch.height,
                      let context = CGContext(data: nil, width: patch.width, height: patch.height, bitsPerComponent: 8, bytesPerRow: patch.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                      let raw = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ImageImportError.unreadable }
                context.draw(image, in: CGRect(x: 0, y: 0, width: patch.width, height: patch.height))
                for y in 0..<patch.height {
                    if y % 64 == 0 { try Task.checkCancellation() }
                    for x in 0..<patch.width {
                    let sourceAt = (y * patch.width + x) * 4, targetAt = ((y + patch.y) * width + x + patch.x) * 4
                    if raw[sourceAt + 3] != 0 { for c in 0..<4 { canvas[targetAt + c] = raw[sourceAt + c] } }
                } }
                let output = Data(canvas)
                guard let provider = CGDataProvider(data: output as CFData),
                      let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ImageImportError.unreadable }
                return image
            }
            frames.append(ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: name))
            if patch.disposal == 2 {
                let fill = patch.transparent ? [UInt8](repeating: 0, count: 4) : background
                for y in patch.y..<patch.y + patch.height {
                    if y % 64 == 0 { try Task.checkCancellation() }
                    for x in patch.x..<patch.x + patch.width {
                        let at = (y * width + x) * 4; for c in 0..<4 { canvas[at + c] = fill[c] }
                    }
                }
            } else if patch.disposal == 3 { canvas = previous }
        }
        return GIFImport(width: width, height: height, frames: frames, durations: patches.map(\.duration), loopCount: loopCount)
    }
}

extension ImageImporter {
    func decodeGIF(_ url: URL, remainingPixels: Int) throws -> GIFImport {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try Task.checkCancellation()
        var data = Data()
        while let chunk = try file.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            guard data.count + chunk.count <= 64 * 1024 * 1024 else { throw ImageImportError.gifTooLarge }
            data.append(chunk)
        }
        return try GIFCodec.decode(data, name: url.deletingPathExtension().lastPathComponent, remainingPixels: remainingPixels)
    }
}
