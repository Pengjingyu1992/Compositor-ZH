import CoreImage
import Testing
@testable import Compositor

/// RAW imports are rounded to 8 bits with a little noise, so smooth gradients don't come out in steps.
struct RawDitherTests {
    /// Color values pass straight through, so the test knows exactly what each row should be.
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// A gradient from 0.30 at the top to 0.32 at the bottom: only five 8-bit steps across 400 rows, the kind of sky
    /// that bands.
    private func gradient(width: Int = 300, height: Int = 400) -> CIImage {
        CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: CGFloat(height)), "inputColor0": CIColor(red: 0.30, green: 0.30, blue: 0.30),
            "inputPoint1": CIVector(x: 0, y: 0), "inputColor1": CIColor(red: 0.32, green: 0.32, blue: 0.32),
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func rowMeans(_ image: CGImage) throws -> [Double] {
        let pixels = try BrushRaster.copy(image)
        let data = try #require(pixels.data).assumingMemoryBound(to: UInt8.self)
        return (0..<image.height).map { y in
            Double((0..<image.width).reduce(0) { $0 + Int(data[y * pixels.bytesPerRow + $1 * 4]) }) / Double(image.width)
        }
    }

    @Test func ditheredGradientFollowsTheTonesNotTheSteps() throws {
        let image = try #require(RawImporter.dithered(gradient(), context: context))
        #expect(image.width == 300 && image.height == 400)
        let means = try rowMeans(image)
        // Written out step by step: as one expression, CI's compiler gave up type-checking it.
        let ideal: [Double] = (0..<400).map { row in
            let tone: Double = 0.30 + 0.02 * (Double(row) + 0.5) / 400
            return tone * 255
        }
        let ditheredError = zip(means, ideal).map { abs($0 - $1) }.max() ?? 1
        // Plain rounding is off by up to half a step on every row in between.
        let plainError = ideal.map { abs($0.rounded() - $0) }.max() ?? 0
        #expect(ditheredError < 0.25 && plainError > 0.45, "row averages off by \(ditheredError), plain rounding \(plainError)")
        #expect(means.first! < means.last!, "the top row is the darker end, as in the image")
        let plainSteps = Set(ideal.map { Int($0.rounded()) }).count
        #expect(plainSteps <= 6, "the test gradient really is only a few steps")
    }

    @Test func ditherIsFineAndRepeatable() throws {
        let flat = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let first = try #require(RawImporter.dithered(flat, context: context))
        let second = try #require(RawImporter.dithered(flat, context: context))
        let a = try BrushRaster.copy(first), b = try BrushRaster.copy(second)
        let bytesA = UnsafeBufferPointer(start: try #require(a.data).assumingMemoryBound(to: UInt8.self), count: a.bytesPerRow * 64)
        let bytesB = UnsafeBufferPointer(start: try #require(b.data).assumingMemoryBound(to: UInt8.self), count: b.bytesPerRow * 64)
        #expect(Array(bytesA) == Array(bytesB), "the same develop gives the same pixels")
        let reds = stride(from: 0, to: bytesA.count, by: 4).map { Int(bytesA[$0]) }
        #expect(reds.allSatisfy { (126...129).contains($0) }, "never more than a step or so off: \(Set(reds).sorted())")
        #expect(abs(Double(reds.reduce(0, +)) / Double(reds.count) - 127.5) < 0.1, "and right on average")
        #expect(stride(from: 3, to: bytesA.count, by: 4).allSatisfy { bytesA[$0] == 255 }, "opaque stays opaque")
    }
}
