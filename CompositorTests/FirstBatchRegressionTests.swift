import AppKit
#if !FIRST_BATCH_CLT_CHECKS
import Testing
@testable import Compositor
#endif

@MainActor
struct FirstBatchRegressionChecks {
    struct Result { var checks = 0; var failures: [String] = []; var measurements: [String] = [] }
    static func run(largeCanvases: Bool = false) async throws -> Result {
        var result = Result()
        func check(_ name: String, _ value: Bool) {
            result.checks += 1
            if !value { result.failures.append(name); print("FAIL: \(name)") }
            fflush(stdout)
        }
        func asset(_ side: Int = 32) throws -> ImportedImage {
            let c = try BrushRaster.context(width: side, height: side, mask: false)
            let data = c.data!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<side { for x in 0..<side {
                let i = y * c.bytesPerRow + x * 4
                let a = UInt8((x % 4) * 85)
                data[i] = a / 2; data[i+1] = a / 3; data[i+2] = a / 4; data[i+3] = a
            } }
            let image = c.makeImage()!
            return ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: "Fixture")
        }
        let cacheSource = try asset(8).image
        let nativeFrame = try asset(24).image
        let rendered = (image: nativeFrame, transform: LayerTransform(origin: CGPoint(x: 10, y: 20), size: CGSize(width: 24, height: 24)))
        let cache = try PSDText.cachedAppearance(cacheSource, bounds: CGRect(x: 12, y: 23, width: 8, height: 8), rendered: rendered)
        check("PSD cached glyphs retained", cache != nil)
        if let cache {
            let pixels = try BrushRaster.copy(cache)
            let original = try BrushRaster.copy(cacheSource)
            let a = pixels.data!.assumingMemoryBound(to: UInt8.self)
            let b = original.data!.assumingMemoryBound(to: UInt8.self)
            var equal = true
            for y in 0..<8 { for x in 0..<8 { for c in 0..<4 {
                if a[(y + 3) * pixels.bytesPerRow + (x + 2) * 4 + c] != b[y * original.bytesPerRow + x * 4 + c] { equal = false }
            } } }
            check("PSD cache offset and partial alpha", equal)
        }
        check("PSD out-of-frame cache rejected", try PSDText.cachedAppearance(cacheSource, bounds: CGRect(x: 1, y: 1, width: 8, height: 8), rendered: rendered) == nil)
        var rotated = rendered; rotated.transform.rotation = 30
        check("PSD rotated cache explicit fallback", try PSDText.cachedAppearance(cacheSource, bounds: CGRect(x: 12, y: 23, width: 8, height: 8), rendered: rotated) == nil)
        check("transparency icon exists", NSImage(systemSymbolName: "square.dotted", accessibilityDescription: nil) != nil)
        let source = try asset()
        let session = EditorSession()
        let layer = ImageLayer(asset: source, origin: CGPoint(x: 4, y: 4))
        let other = ImageLayer(asset: source, origin: CGPoint(x: 48, y: 4))
        session.document = CanvasDocument(width: 96, height: 48, layers: [layer, other])
        session.activeLayerID = layer.id
        session.history.reset()
        session.toggleSelectedLayerLock(.content)
        check("locks do not dirty project", !session.isModified)
        check("content gate", !session.canPaint && !session.canAdjustColors && !session.canInvert)
        let before = session.document
        let revision = session.history.currentRevision
        session.beginEdit("Edit")
        session.document?.layers[0].asset = try asset()
        session.document?.layers[1].opacity = 0.4
        session.endEdit()
        check("whole transaction rolls back", session.document == before && session.history.currentRevision == revision)
        check("locked fill rejected", !(await session.fillPixels(on: layer, with: .foreground, name: "Fill")))
        session.deleteSelectedLayers()
        check("locked delete rejected", session.document == before)
        session.toggleSelectedLayerLock(.content)
        session.toggleSelectedLayerLock(.appearance)
        session.setSelectedLayersOpacity(0.2)
        session.toggleLayerVisibility(layer.id)
        check("opacity and visibility respect appearance lock", session.document == before)
        check("appearance lock allows pixels", session.canPaint)
        session.toggleSelectedLayerLock(.appearance)
        session.toggleSelectedLayerLock(.position)
        session.arrangeReference = .canvas
        check("position gate", !session.canTransform && !session.canArrange(.left))
        check("arrange returns refusal", session.arrangeLayers(.left) == .rejected(.locked))
        session.toggleSelectedLayerLock(.position)
        session.toggleSelectedLayerLock(.transparency)
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        await session.fillSelection(with: .foreground)
        let filled = session.activeLayer!.asset!.image
        let a = try BrushRaster.copy(source.image), b = try BrushRaster.copy(filled)
        check("alpha fill keeps dimensions", filled.width == source.image.width && filled.height == source.image.height)
        check("alpha fill keeps every alpha", layer_alpha_equal(a.data!.assumingMemoryBound(to: UInt8.self), b.data!.assumingMemoryBound(to: UInt8.self), filled.width, filled.height, a.bytesPerRow, b.bytesPerRow) != 0)
        check("alpha fill actually recolors", b.data!.assumingMemoryBound(to: UInt8.self)[7] == 85 && b.data!.assumingMemoryBound(to: UInt8.self)[4] > a.data!.assumingMemoryBound(to: UInt8.self)[4])
        session.undo()
        check("undo allowed while locked", session.activeLayer?.asset?.image === source.image)
        session.redo()
        check("redo allowed while locked", session.activeLayer?.asset?.image === filled)
        session.tool = .brush
        session.brushSettings.diameter = 10
        session.beginBrush(at: CGPoint(x: 18, y: 18))
        check("alpha brush starts", session.brushStroke != nil)
        session.finishBrushImmediately()
        check("alpha brush commits", session.brushStroke == nil && session.activeLayer?.size == layer.size)
        session.brushMode = .erase
        let eraserBefore = session.document, eraserRevision = session.history.currentRevision
        session.beginBrush(at: CGPoint(x: 18, y: 18))
        check("alpha lock refuses eraser before stroke", session.brushStroke == nil && session.document == eraserBefore && session.history.currentRevision == eraserRevision)
        session.brushMode = .paint
        session.toggleSelectedLayerLock(.transparency)
        session.toggleSelectedLayerLock(.all)
        check("full lock gates", !session.canPaint && !session.canTransform && !session.canEditOpacity && !session.canEditMask && !session.canDeleteLayerTarget && !session.canGroupSelectedLayers && !session.canRenameActiveLayer)
        session.toggleSelectedLayerLock(.all)
        check("locked layer can be unlocked", session.canPaint)

        var group = ImageLayer(name: "Folder", blankSize: session.document!.size)
        group.isGroup = true
        session.document?.layers.insert(group, at: 0)
        session.document?.layers[1].parentID = group.id
        session.activeLayerID = group.id
        session.toggleSelectedLayerLock(.all)
        session.activeLayerID = layer.id
        check("ancestor lock inherited", !session.canPaint && !session.canTransform)
        session.beginEdit("Edit")
        session.document?.layers[1].parentID = nil
        session.endEdit()
        check("cannot escape locked ancestor", session.activeLayer?.parentID == group.id)
        session.activeLayerID = group.id
        session.toggleSelectedLayerLock(.all)
        session.activeLayerID = layer.id
        check("ancestor unlock restores permission", session.canPaint)

        let masked = EditorSession()
        var maskedLayer = layer
        maskedLayer.mask = LayerMask.solid(revealing: true)
        masked.document = CanvasDocument(width: 96, height: 48, layers: [maskedLayer])
        masked.activeLayerID = maskedLayer.id
        masked.toggleSelectedLayerLock(.content)
        masked.toggleLayerMask()
        check("content lock allows mask appearance", masked.activeLayer?.mask?.isEnabled == false)
        masked.toggleMaskLink(maskedLayer.id)
        check("content lock allows mask linking", masked.activeLayer?.mask?.isLinked == false)
        var placement = maskedLayer.transform
        placement.origin.x += 3
        masked.beginEdit("Transform Layer Mask")
        masked.document?.layers[0].mask?.placement = placement
        masked.endEdit()
        check("content lock allows independent mask position", masked.activeLayer?.mask?.placement == placement)
        let maskBefore = masked.document
        masked.beginEdit("Paint Mask")
        masked.document?.layers[0].mask = LayerMask.solid(revealing: false)
        masked.endEdit()
        check("content lock rejects mask pixels", masked.document == maskBefore)
        masked.toggleSelectedLayerLock(.content)
        masked.toggleSelectedLayerLock(.appearance)
        masked.toggleLayerMask()
        check("appearance lock refuses mask toggle", !masked.canToggleLayerMask && masked.activeLayer?.mask?.isEnabled == false)
        masked.deleteLayerMask()
        check("appearance lock allows mask content removal", masked.activeLayer?.mask == nil)
        masked.toggleSelectedLayerLock(.appearance)
        masked.addLayerMask()
        masked.toggleSelectedLayerLock(.position)
        masked.toggleMaskLink(maskedLayer.id)
        check("position lock refuses mask link changes", masked.activeLayer?.mask?.isLinked == true)
        let positionBefore = masked.document
        masked.beginEdit("Transform Layer Mask")
        masked.document?.layers[0].mask?.placement = placement
        masked.endEdit()
        check("position lock refuses mask movement", masked.document == positionBefore)

        let workspace = ProjectWorkspace()
        let modal = workspace.current.session
        modal.document = CanvasDocument(width: 96, height: 48, layers: [layer])
        modal.activeLayerID = layer.id
        modal.addEffect(.stroke)
        check("effect preview blocks file operations", modal.effectsEditing != nil && !workspace.canSwitch && !modal.canUseHistory)
        var waiting = false, resumed = false
        Task { @MainActor in
            waiting = true
            await modal.waitForFileRequest()
            resumed = true
        }
        while !waiting { await Task.yield() }
        await workspace.settlePendingEdits()
        for _ in 0..<32 where !resumed { await Task.yield() }
        check("quit settles effects and resumes file requests", modal.effectsEditing == nil && workspace.canSwitch && resumed)
        for kind in ["hue", "filter"] {
            if kind == "hue" { modal.beginHueSaturation() }
            else { modal.beginFilter(.gaussianBlur) }
            check("\(kind) preview blocks file operations", !modal.canStartProjectOperation && !modal.canUseHistory)
            waiting = false; resumed = false
            Task { @MainActor in
                waiting = true
                await modal.waitForFileRequest()
                resumed = true
            }
            while !waiting { await Task.yield() }
            if kind == "hue" { modal.cancelHueSaturation() }
            else { modal.cancelFilter() }
            for _ in 0..<32 where !resumed { await Task.yield() }
            check("\(kind) preview ending resumes file requests", modal.canStartProjectOperation && resumed)
        }

        let empty = EditorSession()
        empty.createDocument(width: 32, height: 32, emptyLayer: true)
        empty.history.reset()
        empty.toggleSelectedLayerLock(.transparency)
        check("alpha lock on blank layer refuses paint", !empty.canPaint)
        let zero = try BrushRaster.context(width: 32, height: 32, mask: false).makeImage()!
        let zeroAsset = ImportedImage(image: zero, thumbnail: zero, name: "Empty")
        empty.document?.layers[0].asset = zeroAsset
        let emptyRevision = empty.history.currentRevision
        await empty.fillSelection(with: .foreground)
        check("alpha-only empty fill is unchanged", empty.history.currentRevision == emptyRevision && empty.activeLayer?.asset?.image === zero)

        let h = EditorSession()
        h.createDocument(width: 16, height: 16, emptyLayer: true)
        h.history.reset()
        let id = h.activeLayerID!
        for n in 1...4 { h.renameLayer(id, to: "State \(n)") }
        let timeline = h.history.timeline
        let end = h.document
        h.history.markSaved()
        h.jumpHistory(to: timeline[1].id)
        check("history jumps backward", h.activeLayer?.name == "State 1" && h.canRedo)
        h.jumpHistory(to: timeline.last!.id)
        check("history jumps forward", h.document == end && !h.isModified)
        h.jumpHistory(to: timeline[2].id)
        h.renameLayer(id, to: "New branch")
        check("history branch drops future", !h.canRedo && !h.history.timeline.contains { $0.id == timeline.last!.id })
        let branch = h.document
        h.jumpHistory(to: UUID())
        check("stale history target ignored", h.document == branch)
        h.beginEdit("Edit")
        check("pending history cannot jump", h.history.jump(to: timeline[0].id) == nil)
        h.endEdit()
        for n in 0..<250 { h.renameLayer(id, to: "Stress \(n)") }
        check("history stays bounded", h.history.timeline.count <= 101)
        let first = h.history.timeline.first!.id
        let last = h.history.timeline.last!.id
        h.jumpHistory(to: first)
        check("trimmed boundary can be restored", h.history.currentRevision == first)
        h.jumpHistory(to: last)
        check("trimmed history redoes to end", h.activeLayer?.name == "Stress 249")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("compositor-batch-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recoverySession = EditorSession()
        recoverySession.document = session.document
        recoverySession.history.markUnsaved()
        let recoverySnapshot = recoverySession.projectSnapshot()!
        let recovery = RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let record = RecoveryRecord(documentID: recoverySession.document!.id, revision: recoverySession.history.currentRevision,
            projectVersion: recoverySnapshot.manifest.version, title: "Regression", originalPath: nil, date: Date())
        try await recovery.write(recoverySnapshot, record: record)
        let recoveryURL = recovery.directory.appendingPathComponent(record.documentID.uuidString + ".comp")
        let recovered = try await recovery.load(recoveryURL)
        check("recovery keeps dirty state", recoverySession.isModified)
        check("recovery preserves layers and format", recovered.manifest.layers.count == recoverySnapshot.manifest.layers.count && recovered.manifest.version == ProjectManifest.current)
        check("session locks do not enter project fields", !String(data: try JSONEncoder().encode(recoverySnapshot.manifest), encoding: .utf8)!.contains("lock"))
        for mode in LayerBlendMode.allCases {
            let test = EditorSession()
            var front = other; front.transform = layer.transform; front.blendMode = mode; front.opacity = 0.7
            test.document = CanvasDocument(width: 40, height: 40, layers: [layer, front])
            let snapshot = test.projectSnapshot()!
            let rendered = try await ImageExporter.shared.pngData(snapshot)
            let url = root.appendingPathComponent("mode.comp")
            try await ProjectStore.shared.save(snapshot, to: url)
            let reopened = try await ProjectStore.shared.load(from: url)
            let again = try await ImageExporter.shared.pngData(reopened)
            check("blend round trip \(mode.rawValue)", rendered == again && reopened.manifest.layers.last?.blendMode == mode)
        }
        if largeCanvases {
            for side in [4096, 8192] {
                let start = Date()
                let test = EditorSession()
                let big = try asset(side)
                test.document = CanvasDocument(width: side, height: side, layers: [ImageLayer(asset: big, origin: .zero)])
                test.activeLayerID = test.document!.layers[0].id
                test.history.reset()
                let editStart = Date()
                await test.invertPixels()
                let editSeconds = Date().timeIntervalSince(editStart)
                check("\(side) actual pixel edit", test.activeLayer?.asset?.image !== big.image)
                let fitsUndo = big.image.bytesPerRow * big.image.height + big.thumbnail.bytesPerRow * big.thumbnail.height <= test.history.retainedByteLimit
                check("\(side) history budget explicit", test.history.canUndo == fitsUndo && test.history.droppedLatestUndo == !fitsUndo)
                let edited = test.activeLayer?.asset?.image
                test.undo()
                check("\(side) undo budget behavior", test.activeLayer?.asset?.image === (fitsUndo ? big.image : edited))
                let png = try await ImageExporter.shared.pngData(test.projectSnapshot()!)
                check("\(side) export", !png.isEmpty)
                result.measurements.append("\(side)x\(side): one RGBA layer + invert + undo + PNG export, \(String(format: "%.3f", Date().timeIntervalSince(start))) s total, \(String(format: "%.3f", editSeconds)) s invert; \(png.count) PNG bytes")
            }
        }
        return result
    }
}

extension FirstBatchRegressionChecks {
    static func inspectPSD(_ input: String, output: String) async throws {
        let url = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let parsed = try PSDReader.read(from: URL(fileURLWithPath: input))
        let imported = try PSDDocumentBuilder.makeImport(parsed)
        func write(_ layers: [ImageLayer], _ name: String) async throws {
            let session = EditorSession()
            session.document = CanvasDocument(width: imported.width, height: imported.height, layers: layers)
            try await ImageExporter.shared.exportPNG(session.projectSnapshot()!, to: url.appendingPathComponent(name + ".png"))
        }
        try await write(imported.layers, "native-import")
        var cached = parsed
        for index in cached.layers.indices { cached.layers[index].text = nil }
        let cachedImport = try PSDDocumentBuilder.makeImport(cached)
        try await write(cachedImport.layers, "cached-text")
        for (index, layer) in imported.layers.enumerated() {
            try await write([layer], "native-layer-\(index)")
            if let raw = parsed.layers.first(where: { $0.id == layer.id }), let image = raw.image {
                var replacement = layer
                replacement.text = nil; replacement.shape = nil
                replacement.asset = ImportedImage(image: image, thumbnail: image, name: raw.name)
                replacement.transform = LayerTransform(origin: raw.bounds.origin, size: raw.bounds.size)
                try await write([replacement], "cached-layer-\(index)")
            }
            print("PSD layer \(index): \(layer.name), bounds \(layer.transform), text=\(layer.liveText != nil), adjustment=\(layer.adjustment != nil), mask=\(layer.mask != nil)")
        }
        print("PSD diagnostic written")
    }
}

#if !FIRST_BATCH_CLT_CHECKS
struct FirstBatchRegressionTests {
    @Test @MainActor func locksAndHistoryAndRoundTrips() async throws {
        let result = try await FirstBatchRegressionChecks.run()
        #expect(result.failures.isEmpty, "\(result.failures)")
    }
}
#endif
