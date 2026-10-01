import CoreGraphics
import Foundation

/// Guided filtering (He, Sun & Tang): a mask pulled onto the edges of the image it came from, which is what recovers
/// hair and fur that a segmentation model cuts straight through. Core Image's own `CIGuidedFilter` does nothing on
/// this system and its edge-preserving upsample barely moves the mask, so this does the arithmetic directly.
nonisolated enum GuidedMatte {
    /// Mean over a (2r+1)² square, as two running-sum passes — the cost doesn't grow with the radius.
    static func box(_ source: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        let span = Float(radius * 2 + 1)
        var pass = [Float](repeating: 0, count: width * height)
        source.withUnsafeBufferPointer { src in
            pass.withUnsafeMutableBufferPointer { out in
                for y in 0..<height {
                    let row = y * width
                    var sum: Float = 0
                    for x in -radius...radius { sum += src[row + min(width - 1, max(0, x))] }
                    for x in 0..<width {
                        out[row + x] = sum / span
                        sum -= src[row + min(width - 1, max(0, x - radius))]
                        sum += src[row + min(width - 1, max(0, x + radius + 1))]
                    }
                }
            }
        }
        var result = [Float](repeating: 0, count: width * height)
        pass.withUnsafeBufferPointer { src in
            result.withUnsafeMutableBufferPointer { out in
                for x in 0..<width {
                    var sum: Float = 0
                    for y in -radius...radius { sum += src[min(height - 1, max(0, y)) * width + x] }
                    for y in 0..<height {
                        out[y * width + x] = sum / span
                        sum -= src[min(height - 1, max(0, y - radius)) * width + x]
                        sum += src[min(height - 1, max(0, y + radius + 1)) * width + x]
                    }
                }
            }
        }
        return result
    }

    /// `mask` refined by `guide` (both 0–1, the same size). A bigger radius reaches further for detail; `epsilon`
    /// decides how much of an edge in the guide counts, so a small one follows fine strands.
    static func filter(mask: [Float], guide: [Float], width: Int, height: Int, radius: Int, epsilon: Float) -> [Float] {
        let count = width * height
        let meanGuide = box(guide, width: width, height: height, radius: radius)
        let meanMask = box(mask, width: width, height: height, radius: radius)
        var squares = [Float](repeating: 0, count: count), products = [Float](repeating: 0, count: count)
        for i in 0..<count { squares[i] = guide[i] * guide[i]; products[i] = guide[i] * mask[i] }
        let meanSquares = box(squares, width: width, height: height, radius: radius)
        let meanProducts = box(products, width: width, height: height, radius: radius)
        var slope = [Float](repeating: 0, count: count), offset = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let variance = meanSquares[i] - meanGuide[i] * meanGuide[i]
            let covariance = meanProducts[i] - meanGuide[i] * meanMask[i]
            slope[i] = covariance / (variance + epsilon)
            offset[i] = meanMask[i] - slope[i] * meanGuide[i]
        }
        let meanSlope = box(slope, width: width, height: height, radius: radius)
        let meanOffset = box(offset, width: width, height: height, radius: radius)
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count { result[i] = min(1, max(0, meanSlope[i] * guide[i] + meanOffset[i])) }
        return result
    }

    /// The gray levels of `image` drawn at `width` × `height`, as 0–1.
    static func levels(of image: CGImage, width: Int, height: Int) throws -> [Float] {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { throw ExportError.render }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        var result = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * context.bytesPerRow
            for x in 0..<width { result[y * width + x] = Float(bytes[row + x]) / 255 }
        }
        return result
    }

    /// 0–1 levels back to a gray image.
    static func image(_ levels: [Float], width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { throw ExportError.render }
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        for y in 0..<height {
            let row = y * context.bytesPerRow
            for x in 0..<width { bytes[row + x] = UInt8(min(255, max(0, levels[y * width + x] * 255 + 0.5))) }
        }
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }

    /// `mask` refined against `guide`, both full size. Done on a copy no larger than `limit` on its longest side
    /// (the radius shrinks with it), then drawn back up: fine detail comes from the guide either way, and a preview
    /// stays quick to redraw while a slider moves.
    static func refine(mask: CGImage, guide: CGImage, radius: Double, limit: CGFloat) throws -> CGImage {
        let full = CGSize(width: mask.width, height: mask.height)
        let factor = min(1, limit / max(full.width, full.height))
        let width = max(1, Int((full.width * factor).rounded())), height = max(1, Int((full.height * factor).rounded()))
        let steps = max(1, Int((radius * Double(factor)).rounded()))
        let refined = filter(mask: try levels(of: mask, width: width, height: height),
                             guide: try levels(of: guide, width: width, height: height),
                             width: width, height: height, radius: steps, epsilon: 1e-4)
        let small = try image(refined, width: width, height: height)
        guard width != Int(full.width) || height != Int(full.height) else { return small }
        guard let context = CGContext(data: nil, width: Int(full.width), height: Int(full.height), bitsPerComponent: 8,
                                      bytesPerRow: Int(full.width), space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw ExportError.render }
        context.interpolationQuality = .high
        context.draw(small, in: CGRect(origin: .zero, size: full))
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }
}
