import AppKit
import ImageIO
import UniformTypeIdentifiers
#if !IMAGE_TRANSFER_CLT_CHECKS
import Testing
@testable import Compositor
#endif

@MainActor struct ImageTransferChecks {
    struct Result { var checks = 0; var failures: [String] = [] }
    static func run(output: URL) async throws -> Result {
        var r = Result()
        func check(_ name: String, _ condition: Bool) {
            r.checks += 1
            if !condition { r.failures.append(name); print("FAIL: \(name)") }
            fflush(stdout)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        func fixture(depth: Int, width: Int = 6000, height: Int = 8) throws -> Data {
            let w = width, h = height, stride = depth / 8
            var pixels = Data(count: w * h * 4 * stride)
            pixels.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
                for i in 0..<(w * h) {
                    let alpha = UInt16((i % 4) * 21845)
                    let rgba: [UInt16] = [UInt16(i % 65536), 16384, 49152, alpha]
                    for c in 0..<4 {
                        let n = (i * 4 + c) * stride
                        if depth == 16 { p[n] = UInt8(rgba[c] >> 8); p[n + 1] = UInt8(rgba[c] & 255) }
                        else { p[n] = UInt8(rgba[c] >> 8) }
                    }
                }
            }
            let image = CGImage(width: w, height: h, bitsPerComponent: depth, bitsPerPixel: depth * 4,
                bytesPerRow: w * 4 * stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | (depth == 16 ? CGBitmapInfo.byteOrder16Big.rawValue : 0)),
                provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            return try ImageExporter.transferPNG(ExportRaster(image: image, resolution: 300))
        }
        for depth in [8, 16] {
            let bytes = try fixture(depth: depth)
            let file = output.appendingPathComponent("source-\(depth).png")
            try bytes.write(to: file)
            let asset = try await ImageImporter.shared.decode(file)
            check("\(depth)-bit source bytes retained", asset.originalPNG == bytes)
            check("\(depth)-bit full dimensions", asset.image.width == 6000 && asset.image.height == 8)
            check("\(depth)-bit editing proxy", asset.image.bitsPerComponent == 8)
            let s = EditorSession()
            s.insert(asset)
            s.document!.layers[0].transform.size = CGSize(width: 1500, height: 2)
            s.document!.layers[0].transform.rotation = 30
            s.document!.layers[0].transform.flipX = true
            let payload = try s.imageTransfer()
            check("\(depth)-bit original drag byte equality", payload.png == bytes)
            check("\(depth)-bit placement separate from pixels", payload.placement.width == 1500 && payload.placement.rotation == 30 && payload.placement.flipX)
            let snapshot = s.projectSnapshot()!
            check("\(depth)-bit snapshot declares original resources", snapshot.manifest.version == 17)
            let package = output.appendingPathComponent("roundtrip-\(depth).comp", isDirectory: true)
            try await ProjectStore.shared.save(snapshot, to: package)
            let onDisk = try Data(contentsOf: package.appendingPathComponent("images/\(s.activeLayerID!.uuidString).png"))
            check("\(depth)-bit save retains exact source", onDisk == bytes)
            let loaded = try await ProjectStore.shared.load(from: package)
            let reopened = EditorSession()
            reopened.installProject(loaded, from: nil)
            check("\(depth)-bit reopen retains exact source", try reopened.imageTransfer().png == bytes)
            let resources = RecoveryResources()
            let recovery = output.appendingPathComponent("recovery-\(depth).comp", isDirectory: true)
            _ = try await resources.write(snapshot, to: recovery, metadata: Data("{}".utf8), maximumBytes: 32 * 1024 * 1024)
            let recovered = try await ProjectStore.shared.load(from: recovery)
            check("\(depth)-bit recovery retains source", recovered.images[s.activeLayerID!]?.originalPNG == bytes)
            let exchange = try payload.write()
            let target = EditorSession()
            target.createNewProject(width: 800, height: 600)
            let previousLayerCount = target.document!.layers.count
            await target.importImages([exchange], at: CGPoint(x: 350, y: 250))
            check("\(depth)-bit drop creates one layer", target.document!.layers.count == previousLayerCount + 1)
            check("\(depth)-bit drop reads exact PNG", target.activeLayer?.asset?.originalPNG == bytes)
            check("\(depth)-bit placement at drop point", target.activeLayer?.transform.center == CGPoint(x: 350, y: 250))
            check("\(depth)-bit rotation and reflection retained", target.activeLayer?.transform.rotation == 30 && target.activeLayer?.transform.flipX == true)
            try fm.removeItem(at: exchange.deletingLastPathComponent())
            check("\(depth)-bit target independent of source file", try target.imageTransfer().png == bytes)
            target.undo()
            check("\(depth)-bit import undoes in one step", target.document!.layers.count == previousLayerCount)
            target.redo()
            check("\(depth)-bit redo restores original bytes", target.activeLayer?.asset?.originalPNG == bytes)
            s.document!.layers[0].transform.rotation = 0
            s.document!.layers[0].transform.flipX = false
            s.document!.layers[0].opacity = 0.5
            let baked = try s.imageTransfer()
            let source = CGImageSourceCreateWithData(baked.png as CFData, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            check("\(depth)-bit current appearance never downscales source", image.width >= 6000 && image.height >= 8)
            check("\(depth)-bit appearance is separate from original", baked.png != bytes && s.activeLayer?.asset?.originalPNG == bytes)
            check("\(depth)-bit appearance retains transparency", image.alphaInfo != .none && image.alphaInfo != .noneSkipLast)
            let alphaContext = try BrushRaster.context(width: image.width, height: image.height, mask: false)
            alphaContext.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let pixels = alphaContext.data!.assumingMemoryBound(to: UInt8.self)
            check("\(depth)-bit transparent pixels stay transparent", pixels[3] == 0)
            check("\(depth)-bit opacity is baked without a matte", abs(Int(pixels[3 * 4 + 3]) - 128) <= 1 && abs(Int(pixels[3 * 4 + 2]) - 96) <= 2)
            s.document!.layers[0].opacity = 1
            await s.invertPixels()
            check("\(depth)-bit pixel edit invalidates original", s.activeLayer?.asset?.originalPNG == nil)
            s.undo()
            check("\(depth)-bit undo restores original PNG", s.activeLayer?.asset?.originalPNG == bytes)
            let originalID = s.activeLayerID!
            var parent = ImageLayer(name: "Blended folder", blankSize: s.document!.size)
            parent.isGroup = true
            parent.blendMode = .multiply
            s.document!.layers[0].parentID = parent.id
            s.document!.layers.insert(parent, at: 0)
            s.activeLayerID = originalID
            check("\(depth)-bit ancestor appearance uses rendered transfer", try s.imageTransfer().png != bytes)
        }
        try fixture(depth: 8, width: 800, height: 600).write(to: output.appendingPathComponent("ui-fixture.png"))
        let bytes = try fixture(depth: 8)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { done in done(bytes, nil); return nil }
        let fromData = EditorSession()
        await ImageFileDrop.importProviders([provider], into: fromData, at: nil)
        check("PNG-only pasteboard provider imports", fromData.activeLayer?.asset?.originalPNG == bytes)
        let placedProvider = NSItemProvider()
        placedProvider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { done in done(bytes, nil); return nil }
        let placement = try JSONEncoder().encode(ImageTransferPlacement(width: 1500, height: 2, rotation: 45, flipY: true))
        placedProvider.registerDataRepresentation(forTypeIdentifier: ImageTransferPlacement.typeIdentifier, visibility: .all) { done in done(placement, nil); return nil }
        let sandboxTarget = EditorSession()
        sandboxTarget.createNewProject(width: 800, height: 600)
        await ImageFileDrop.importProviders([placedProvider], into: sandboxTarget, at: CGPoint(x: 200, y: 200))
        check("metadata-only placement imports without adjacent source files", sandboxTarget.activeLayer?.transform.size == CGSize(width: 1500, height: 2) && sandboxTarget.activeLayer?.transform.rotation == 45 && sandboxTarget.activeLayer?.transform.flipY == true)
        check("sandbox copy retains original PNG bytes", sandboxTarget.activeLayer?.asset?.originalPNG == bytes)
        let inaccessible = NSItemProvider()
        let missingURL = URL(fileURLWithPath: "/private/tmp/image-transfer-no-grant-\(UUID().uuidString).png")
        inaccessible.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { done in done(missingURL.dataRepresentation, nil); return nil }
        inaccessible.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { done in done(bytes, nil); return nil }
        inaccessible.registerDataRepresentation(forTypeIdentifier: ImageTransferPlacement.typeIdentifier, visibility: .all) { done in done(placement, nil); return nil }
        let fallback = EditorSession()
        await ImageFileDrop.importProviders([inaccessible], into: fallback, at: nil)
        check("unreadable source URL falls back to complete PNG data", fallback.activeLayer?.asset?.originalPNG == bytes && fallback.activeLayer?.transform.rotation == 45 && fallback.importError == nil)
        check("invalid placement refused", !ImageTransferPlacement(width: .infinity, height: 100).isValid)
        let oldAsset = ImportedImage(image: fromData.activeLayer!.asset!.image, thumbnail: fromData.activeLayer!.asset!.thumbnail, name: "Old")
        let old = EditorSession(); old.insert(oldAsset)
        check("ordinary legacy snapshots retain minimum format", old.projectSnapshot()?.manifest.version == 13)
        return r
    }
}

#if !IMAGE_TRANSFER_CLT_CHECKS
@Suite("Cross-app image transfer") @MainActor struct ImageTransferTests {
    @Test func losslessTransferAndPersistence() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await ImageTransferChecks.run(output: output)
        #expect(result.failures.isEmpty)
    }
}
#endif
