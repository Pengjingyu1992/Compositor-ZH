import AppKit
import Testing
@testable import Compositor

/// Smudge and Liquify on the GPU against the same strokes on the CPU.
@MainActor struct MetalWarpTests {
    private func photo() throws -> CGImage {
        let context = try BrushRaster.context(width: 300, height: 200, mask: false)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<200 { for x in 0..<300 {
            let i = y * context.bytesPerRow + x * 4
            let a: Int = x < 250 ? 255 : 128
            data[i] = UInt8((x * 255 / 300) * a / 255); data[i + 1] = UInt8((y * 255 / 200) * a / 255)
            data[i + 2] = UInt8(((x / 12 + y / 12) % 2 == 0 ? 220 : 40) * a / 255); data[i + 3] = UInt8(a)
        } }
        return try #require(context.makeImage())
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let context = try BrushRaster.copy(image)
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                         count: context.bytesPerRow * context.height))
    }

    @Test(arguments: [BlurToolMode.smudge])
    func matchesTheCPU(mode: BlurToolMode) throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let image = try photo()
        let layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: "Photo"), origin: CGPoint(x: 20, y: 10))
        var settings = BrushSettings()
        settings.diameter = 50
        settings.hardness = 0.3
        settings.opacity = 0.7
        func run(gpu: Bool) throws -> CGImage {
            let stroke = try WarpStroke(layer: layer, image: image, transform: layer.transform, canvas: CGSize(width: 340, height: 240),
                                        mode: mode, settings: settings, useGPU: gpu)
            #expect((stroke.gpu != nil) == gpu)
            for step in 0...40 { stroke.append(CGPoint(x: 30 + Double(step) * 6, y: 60 + 40 * sin(Double(step) / 6))) }
            return try #require(stroke.image)
        }
        let cpu = try bytes(try run(gpu: false)), gpu = try bytes(try run(gpu: true))
        #expect(cpu.count == gpu.count)
        var largest = 0, over = 0
        for (a, b) in zip(cpu, gpu) {
            let difference = abs(Int(a) - Int(b))
            largest = max(largest, difference)
            if difference > 2 { over += 1 }
        }
        // A level here and there: the GPU's square roots round a hair differently.
        #expect(Double(over) / Double(cpu.count) < 0.001 && largest <= 8, "\(mode.rawValue): largest \(largest), \(over) values over 2")
    }

    /// Liquify keeps pixels sharp: a stroke pushed across and back again leaves the layer much as it was. It moves where
    /// each pixel is drawn from and samples the untouched layer once; resampled at every dab instead, as the CPU's are,
    /// the pixels soften with each one.
    @Test func liquifyStaysSharp() throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let image = try photo()
        let layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: "Photo"), origin: .zero)
        var settings = BrushSettings()
        settings.diameter = 60
        settings.hardness = 0.3
        settings.opacity = 0.7
        func stroke(gpu: Bool) throws -> [UInt8] {
            let stroke = try WarpStroke(layer: layer, image: image, transform: layer.transform, canvas: CGSize(width: 300, height: 200),
                                        mode: .liquify, settings: settings, useGPU: gpu)
            for x in stride(from: 60.0, through: 200, by: 4) { stroke.append(CGPoint(x: x, y: 100)) }
            for x in stride(from: 200.0, through: 60, by: -4) { stroke.append(CGPoint(x: x, y: 100)) }
            return try bytes(try #require(stroke.image))
        }
        let untouched = try bytes(image)
        func change(_ result: [UInt8]) -> Double {
            Double(zip(result, untouched).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(untouched.count)
        }
        let gpu = change(try stroke(gpu: true)), cpu = change(try stroke(gpu: false))
        #expect(gpu < cpu / 2, "the GPU's stroke leaves the layer nearer how it was: \(gpu) against \(cpu)")
    }

    /// Smudge drags what's under the brush along and softens it, as Photoshop's does: a bright dot smudged sideways
    /// leaves one trail that fades, not a row of ghost copies of itself.
    @Test(arguments: [false, true])
    func smudgeLeavesOneFadingTrail(gpu: Bool) throws {
        if gpu, GPUCanvasRenderer.shared == nil { return }
        let context = try BrushRaster.context(width: 300, height: 100, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 100))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 52, y: 42, width: 16, height: 16))
        let image = try #require(context.makeImage())
        let layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: "Dot"), origin: .zero)
        var settings = BrushSettings()
        settings.diameter = 40
        settings.hardness = 0.5
        settings.opacity = 0.6
        let stroke = try WarpStroke(layer: layer, image: image, transform: layer.transform, canvas: CGSize(width: 300, height: 100),
                                    mode: .smudge, settings: settings, useGPU: gpu)
        for x in stride(from: 60.0, through: 240, by: 3) { stroke.append(CGPoint(x: x, y: 50)) }
        let result = try bytes(try #require(stroke.image))
        // Brightness along the stroke's line, past the dot.
        let row = (70..<240).map { Int(result[(50 * 300 + $0) * 4]) }
        // A ghost is a bump: brighter than a little way either side of it, however faint.
        var peaks = 0
        for i in 2..<(row.count - 2) where row[i] > row[i - 2] + 2 && row[i] > row[i + 2] + 2 { peaks += 1 }
        #expect(peaks == 0, "the trail fades without repeating: \(peaks) ghost peaks along \(row)")
        #expect(row.first! > row.last! + 20, "and there is a trail: \(row.first!) to \(row.last!)")
    }
}
