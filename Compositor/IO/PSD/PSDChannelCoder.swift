import CoreGraphics
import Foundation
import zlib

nonisolated struct PSDCrop: Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

/// Unpacks Photoshop layer channels from Adobe’s 2019 Photoshop File Formats
/// Specification (Image Data: raw, PackBits, ZIP, and ZIP with prediction).
nonisolated enum PSDChannelCoder {
    static func decode(compression: Int, width: Int, height: Int, data: Data, largeDocument: Bool = false,
                       crop: PSDCrop? = nil, depth: Int = 8) throws -> [UInt8] {
        guard depth == 8 || depth == 16 else { throw PSDError.unsupportedDepth }
        guard width >= 0, height >= 0 else { throw PSDError.truncated }
        guard width > 0, height > 0 else { return [] }
        // Off-canvas PSB layers can exceed the canvas limit. Bound row storage and decode work
        // separately from the retained crop; ZIP never allocates the full source plane.
        guard width <= 300_000, height <= 300_000,
              width * height <= DocumentLimits.documentPixelBudget else { throw ImageImportError.tooLarge }
        let target = crop ?? PSDCrop(x: 0, y: 0, width: width, height: height)
        guard target.x >= 0, target.y >= 0, target.width >= 0, target.height >= 0,
              target.x <= width, target.y <= height,
              target.width <= width - target.x, target.height <= height - target.y else { throw PSDError.truncated }
        guard target.width <= DocumentLimits.maxSide, target.height <= DocumentLimits.maxSide,
              target.width * target.height <= DocumentLimits.maxSurfacePixels else { throw ImageImportError.tooLarge }
        guard target.width > 0, target.height > 0 else { return [] }
        if compression == 2 || compression == 3 {
            return try unpackZIP(width: width, height: height, depth: depth, data: data,
                                 prediction: compression == 3, crop: target)
        }
        let stride = depth / 8
        let byteCrop = PSDCrop(x: target.x * stride, y: target.y,
                               width: target.width * stride, height: target.height)
        let bytes = try decodeBytes(compression: compression, width: width * stride, height: height,
                                    data: data, largeDocument: largeDocument, crop: byteCrop)
        if depth == 8 { return bytes }
        return (0..<(bytes.count / 2)).map { sample8(bytes[$0 * 2], bytes[$0 * 2 + 1]) }
    }

    private static func sample8(_ high: UInt8, _ low: UInt8) -> UInt8 {
        UInt8((Int(high) * 256 + Int(low) + 128) / 257)
    }

    private static func unpackZIP(width: Int, height: Int, depth: Int, data: Data,
                                  prediction: Bool, crop: PSDCrop) throws -> [UInt8] {
        guard !data.isEmpty, data.count <= Int(UInt32.max) else { throw PSDError.truncated }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw PSDError.truncated }
        defer { inflateEnd(&stream) }
        let rowBytes = width * (depth / 8)
        var row = [UInt8](repeating: 0, count: rowBytes)
        var plane = [UInt8](repeating: 0, count: crop.width * crop.height)
        try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress!)
            stream.avail_in = UInt32(data.count)
            var status = Z_OK
            for y in 0..<height {
                try Task.checkCancellation()
                try row.withUnsafeMutableBytes { output in
                    stream.next_out = output.bindMemory(to: UInt8.self).baseAddress!
                    stream.avail_out = UInt32(rowBytes)
                    while stream.avail_out > 0 {
                        guard status != Z_STREAM_END else { throw PSDError.truncated }
                        let beforeIn = stream.avail_in, beforeOut = stream.avail_out
                        status = inflate(&stream, Z_NO_FLUSH)
                        guard status == Z_OK || status == Z_STREAM_END,
                              stream.avail_in != beforeIn || stream.avail_out != beforeOut else { throw PSDError.truncated }
                    }
                }
                if prediction {
                    if depth == 8 {
                        for x in 1..<width { row[x] = row[x] &+ row[x - 1] }
                    } else {
                        var previous = UInt16(row[0]) << 8 | UInt16(row[1])
                        for x in 1..<width {
                            let at = x * 2
                            previous = previous &+ (UInt16(row[at]) << 8 | UInt16(row[at + 1]))
                            row[at] = UInt8(previous >> 8)
                            row[at + 1] = UInt8(truncatingIfNeeded: previous)
                        }
                    }
                }
                if y >= crop.y, y < crop.y + crop.height {
                    let destination = (y - crop.y) * crop.width
                    for x in 0..<crop.width {
                        let source = (crop.x + x) * (depth / 8)
                        plane[destination + x] = depth == 8 ? row[source] : sample8(row[source], row[source + 1])
                    }
                }
            }
            // Consume and validate the zlib trailer. A byte beyond the declared dimensions,
            // an incomplete checksum, or another stream is not valid channel data.
            var overflow: UInt8 = 0
            try withUnsafeMutablePointer(to: &overflow) { output in
                stream.next_out = output
                stream.avail_out = 1
                while status != Z_STREAM_END {
                    let beforeIn = stream.avail_in
                    status = inflate(&stream, Z_NO_FLUSH)
                    guard (status == Z_OK || status == Z_STREAM_END), stream.avail_out == 1,
                          status == Z_STREAM_END || stream.avail_in != beforeIn else { throw PSDError.truncated }
                }
            }
            guard stream.avail_in == 0 else { throw PSDError.truncated }
        }
        return plane
    }

    private static func decodeBytes(compression: Int, width: Int, height: Int, data: Data, largeDocument: Bool,
                                    crop: PSDCrop?) throws -> [UInt8] {
        guard width > 0, height > 0 else { return [] }
        guard let crop else {
            return try decodeFull(compression: compression, width: width, height: height, data: data, largeDocument: largeDocument)
        }
        guard crop.x >= 0, crop.y >= 0, crop.width >= 0, crop.height >= 0,
              crop.x + crop.width <= width, crop.y + crop.height <= height else { throw PSDError.truncated }
        guard crop.width > 0, crop.height > 0 else { return [] }
        switch compression {
        case 0:
            return try cropRaw(width: width, height: height, data: data, crop: crop)
        case 1:
            return try unpackRLE(width: width, height: height, data: data, largeDocument: largeDocument, crop: crop)
        default:
            throw PSDError.unsupportedCompression
        }
    }

    private static func decodeFull(compression: Int, width: Int, height: Int, data: Data, largeDocument: Bool) throws -> [UInt8] {
        let expected = width * height
        switch compression {
        case 0:
            guard data.count >= expected else { throw PSDError.truncated }
            return Array(data.prefix(expected))
        case 1:
            return try unpackRLE(width: width, height: height, data: data, largeDocument: largeDocument)
        default:
            throw PSDError.unsupportedCompression
        }
    }

    private static func cropRaw(width: Int, height: Int, data: Data, crop: PSDCrop) throws -> [UInt8] {
        let expected = width * height
        guard data.count >= expected else { throw PSDError.truncated }
        var plane = [UInt8](repeating: 0, count: crop.width * crop.height)
        for row in 0..<crop.height {
            let sourceStart = (crop.y + row) * width + crop.x
            let targetStart = row * crop.width
            plane.replaceSubrange(targetStart..<(targetStart + crop.width), with: data[sourceStart..<(sourceStart + crop.width)])
        }
        return plane
    }

    static func rgbaImage(width: Int, height: Int, red: [UInt8], green: [UInt8], blue: [UInt8], alpha: [UInt8]) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let count = width * height
        for i in 0..<count {
            let a = alpha[i]
            pixels[i * 4] = UInt8((UInt16(red[i]) * UInt16(a) + 127) / 255)
            pixels[i * 4 + 1] = UInt8((UInt16(green[i]) * UInt16(a) + 127) / 255)
            pixels[i * 4 + 2] = UInt8((UInt16(blue[i]) * UInt16(a) + 127) / 255)
            pixels[i * 4 + 3] = a
        }
        return try image(width: width, height: height, rgba: pixels)
    }

    static func image(width: Int, height: Int, rgba: [UInt8]) throws -> CGImage {
        let bytesPerRow = width * 4
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw PSDError.truncated }
        return image
    }

    static func maskImage(width: Int, height: Int, gray: [UInt8]) throws -> CGImage {
        let data = Data(gray)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw PSDError.truncated }
        return image
    }

    private static func unpackRLE(width: Int, height: Int, data: Data, largeDocument: Bool) throws -> [UInt8] {
        var offset = 0
        func next() throws -> UInt8 {
            guard offset < data.count else { throw PSDError.truncated }
            defer { offset += 1 }
            return data[offset]
        }
        var counts = [Int](repeating: 0, count: height)
        for row in 0..<height {
            if largeDocument {
                let a = try next(), b = try next(), c = try next(), d = try next()
                counts[row] = Int(UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d))
            } else {
                let hi = try next(), lo = try next()
                counts[row] = Int(hi) << 8 | Int(lo)
            }
        }
        var plane = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let end = offset + counts[row]
            guard end <= data.count else { throw PSDError.truncated }
            var written = 0
            while written < width {
                guard offset < end else { throw PSDError.truncated }
                let n = Int8(bitPattern: data[offset])
                offset += 1
                if n >= 0 {
                    let count = Int(n) + 1
                    guard written + count <= width, offset + count <= end else { throw PSDError.truncated }
                    for i in 0..<count { plane[row * width + written + i] = data[offset + i] }
                    offset += count
                    written += count
                } else if n != -128 {
                    let count = 1 - Int(n)
                    guard written + count <= width, offset < end else { throw PSDError.truncated }
                    let value = data[offset]
                    offset += 1
                    for i in 0..<count { plane[row * width + written + i] = value }
                    written += count
                }
            }
            offset = end
        }
        return plane
    }

    private static func unpackRLE(width: Int, height: Int, data: Data, largeDocument: Bool, crop: PSDCrop) throws -> [UInt8] {
        var offset = 0
        func next() throws -> UInt8 {
            guard offset < data.count else { throw PSDError.truncated }
            defer { offset += 1 }
            return data[offset]
        }
        var counts = [Int](repeating: 0, count: height)
        for row in 0..<height {
            if largeDocument {
                let a = try next(), b = try next(), c = try next(), d = try next()
                counts[row] = Int(UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d))
            } else {
                let hi = try next(), lo = try next()
                counts[row] = Int(hi) << 8 | Int(lo)
            }
        }
        var plane = [UInt8](repeating: 0, count: crop.width * crop.height)
        var rowBuffer = [UInt8](repeating: 0, count: width)
        for row in 0..<height {
            let end = offset + counts[row]
            guard end <= data.count else { throw PSDError.truncated }
            guard row >= crop.y, row < crop.y + crop.height else {
                offset = end
                continue
            }
            var written = 0
            while written < width {
                guard offset < end else { throw PSDError.truncated }
                let n = Int8(bitPattern: data[offset])
                offset += 1
                if n >= 0 {
                    let count = Int(n) + 1
                    guard written + count <= width, offset + count <= end else { throw PSDError.truncated }
                    for index in 0..<count { rowBuffer[written + index] = data[offset + index] }
                    offset += count
                    written += count
                } else if n != -128 {
                    let count = 1 - Int(n)
                    guard written + count <= width, offset < end else { throw PSDError.truncated }
                    let value = data[offset]
                    offset += 1
                    for index in 0..<count { rowBuffer[written + index] = value }
                    written += count
                }
            }
            let targetStart = (row - crop.y) * crop.width
            plane.replaceSubrange(targetStart..<(targetStart + crop.width), with: rowBuffer[crop.x..<(crop.x + crop.width)])
            offset = end
        }
        return plane
    }
}
