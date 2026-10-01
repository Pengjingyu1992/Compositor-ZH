import AppKit
import ImageIO
import Testing
@testable import Compositor

@MainActor
struct JPEGExportTests {
    @Test func transparencyUsesChosenMatteAndProducesOpaqueSRGB() async throws {
        let snapshot = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 20,
            height: 12, activeLayerID: nil, layers: []), images: [:])
        let raster = try await ImageExporter.shared.render(snapshot)
        for options in [JPEGOptions(), JPEGOptions(quality: 1, red: 0, green: 0, blue: 1)] {
            let result = try await ImageExporter.shared.jpeg(raster, options: options)
            let source = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
            #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 20 && image.height == 12)
            #expect(image.colorSpace?.name == CGColorSpace.sRGB)
            let decoded = try #require(CGContext(data: nil, width: 20, height: 12, bitsPerComponent: 8,
                bytesPerRow: 80, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            decoded.draw(image, in: CGRect(x: 0, y: 0, width: 20, height: 12))
            let pixel = try #require(decoded.data).assumingMemoryBound(to: UInt8.self)
            #expect(pixel[3] == 255)
            #expect(abs(CGFloat(pixel[0]) / 255 - options.red) < 0.03)
            #expect(abs(CGFloat(pixel[1]) / 255 - options.green) < 0.03)
            #expect(abs(CGFloat(pixel[2]) / 255 - options.blue) < 0.03)
        }
    }

    @Test func qualityChangesBytesAndDecodedPixels() async throws {
        let context = try #require(CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8,
            bytesPerRow: 512, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in 0..<128 {
            for x in 0..<128 {
                context.setFillColor(CGColor(red: CGFloat((x * 37 + y * 17) % 256) / 255,
                    green: CGFloat((x * 11 + y * 53) % 256) / 255,
                    blue: CGFloat((x * 79 + y * 7) % 256) / 255, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let raster = ExportRaster(image: try #require(context.makeImage()))
        let low = try await ImageExporter.shared.jpeg(raster, options: JPEGOptions(quality: 0.1))
        let high = try await ImageExporter.shared.jpeg(raster, options: JPEGOptions(quality: 1))
        #expect(low.data.count < high.data.count)
        let lowBitmap = try #require(NSBitmapImageRep(data: low.data))
        let highBitmap = try #require(NSBitmapImageRep(data: high.data))
        var difference: CGFloat = 0
        for y in 0..<16 {
            for x in 0..<16 {
                let a = try #require(lowBitmap.colorAt(x: x, y: y))
                let b = try #require(highBitmap.colorAt(x: x, y: y))
                difference += abs(a.redComponent - b.redComponent)
            }
        }
        #expect(difference > 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("JPEG-\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ImageExporter.shared.write(high.data, to: url)
        #expect(try Data(contentsOf: url) == high.data)
    }
}
