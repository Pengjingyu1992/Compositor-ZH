import AppKit
import CoreImage
import Metal
#if !MEMORY_PERFORMANCE_CLT_CHECKS
import Testing
@testable import Compositor
#endif

@MainActor struct MemoryPerformanceRegressionChecks {
    struct Result { var checks = 0; var failures: [String] = []; var measurements: [String] = [] }
    static func bytes(_ image: CGImage) throws -> Data {
        let context = try BrushRaster.copy(image)
        return Data(bytes: context.data!, count: context.bytesPerRow * context.height)
    }
    static func pattern(_ width: Int, _ height: Int, mask: Bool = false, seed: Int = 0) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: mask)
        let p = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height { for x in 0..<width {
            if mask { p[y * context.bytesPerRow + x] = UInt8((x + y + seed) & 255); continue }
            let i = y * context.bytesPerRow + x * 4, a = (x + y + seed) % 256
            p[i] = UInt8(a / 2); p[i+1] = UInt8(a / 3); p[i+2] = UInt8(a / 4); p[i+3] = UInt8(a)
        } }
        return context.makeImage()!
    }
    static func asset(_ image: CGImage, raster: RasterSnapshot? = nil) throws -> ImportedImage {
        ImportedImage(image: image, thumbnail: try raster?.thumbnail() ?? PixelAdjust.thumbnail(of: image), name: "Synthetic", raster: raster)
    }
    static func gpuBytes(_ image: CIImage, renderer: GPUCanvasRenderer, width: Int, height: Int) throws -> Data {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]; descriptor.storageMode = .shared
        guard let texture = renderer.device.makeTexture(descriptor: descriptor), let buffer = renderer.queue.makeCommandBuffer() else { throw ExportError.render }
        renderer.context.render(image, to: texture, commandBuffer: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: renderer.space)
        buffer.commit(); buffer.waitUntilCompleted()
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        return data
    }
    static func run(large: Bool = false, widescreen: Bool = false) async throws -> Result {
        var result = Result()
        func stage(_ name: String) {
            if large { print("STAGE: \(name)"); fflush(stdout) }
        }
        func check(_ name: String, _ value: Bool) {
            result.checks += 1; if !value { result.failures.append(name); print("FAIL: \(name)") }; fflush(stdout)
        }
        let small = try pattern(32, 32), resource = RenderResource.image(small)
        let budget = RenderCache(byteLimit: resource.bytes * 2, observesPressure: false)
        budget.insert(small, for: .init(.piece, 1), resources: [resource, resource])
        budget.insert(small, for: .init(.filter, 2), resources: [resource])
        check("shared allocation charged once across cache families", budget.retainedBytes == resource.bytes)
        budget.remove(.init(.piece, 1))
        check("shared allocation retained until final reference", budget.retainedBytes == resource.bytes)
        budget.remove(.init(.filter, 2))
        check("last reference releases accounting", budget.retainedBytes == 0)
        let others = try (0..<3).map { try pattern(32, 32, seed: $0) }
        for (index, image) in others.enumerated() { budget.insert(image, for: .init(.piece, index), resources: [.image(image)]) }
        check("global LRU evicts oldest", budget.count == 2 && budget.value(for: .init(.piece, 0), as: CGImage.self) == nil)
        check("budget includes every retained source", budget.retainedBytes <= budget.currentLimit)
        budget.respond(to: .warning)
        check("warning shrinks all CPU families", budget.retainedBytes <= budget.byteLimit / 4)
        budget.respond(to: .critical)
        budget.insert(small, for: .init(.texture, 0), resources: [resource])
        check("critical clears and refuses cache admission", budget.count == 0 && budget.retainedBytes == 0)
        budget.respond(to: .normal)
        budget.insert(small, for: .init(.piece, 0), resources: [RenderResource(id: .field(UUID()), bytes: budget.byteLimit + 1)])
        check("oversized entry is not pinned", budget.count == 0)
        let concurrent = RenderCache(byteLimit: 32_768, observesPressure: false)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            concurrent.insert(small, for: .init(.piece, index), resources: [resource])
            _ = concurrent.value(for: .init(.piece, index), as: CGImage.self)
            if index % 2 == 0 { concurrent.remove(.init(.piece, index)) }
        }
        check("concurrent cache operations preserve cap and shared accounting", concurrent.retainedBytes == resource.bytes && concurrent.count == 50)
        let reductions = DownsampleCache(cache: budget)
        let reduced = reductions.image(small, level: 2)
        check("oversized reductions still return correct dimensions", reduced.level == 2 && reduced.image.width == 8 && budget.retainedBytes <= budget.currentLimit)

        let localCache = RenderCache(byteLimit: 64 * 1024 * 1024, observesPressure: false)
        let pieces = TiledPieceCache(cache: localCache)
        let patch = BrushPatch(rect: CGRect(x: 30, y: 30, width: 64, height: 64), image: try pattern(64, 64))
        let distant = BrushPatch(rect: CGRect(x: 2400, y: 2400, width: 64, height: 64), image: try pattern(64, 64, seed: 9))
        let bounds = CGRect(x: 0, y: 0, width: 4096, height: 4096)
        let first = RasterSnapshot(width: 4096, height: 4096, base: nil, baseRect: bounds, patches: [patch, distant])
        let near = CGRect(x: 0, y: 0, width: 512, height: 512)
        let firstPieces = pieces.pieces(for: first, level: 1, visible: near)
        check("only visible pieces are built", firstPieces.count == 1 && localCache.count == 1 && !first.hasMaterializedPixels)
        let firstAsset = try asset(first.makeImage(), raster: first)
        let second = RasterSnapshot.replacing(source: firstAsset, sourceRect: bounds,
            patches: [BrushPatch(rect: CGRect(x: 2800, y: 2800, width: 64, height: 64), image: try pattern(64, 64, seed: 4))], crop: bounds)
        let reused = pieces.pieces(for: second, level: 1, visible: near)
        check("unchanged piece reused across snapshot identities", reused.first?.image === firstPieces.first?.image)
        let third = RasterSnapshot.replacing(source: try asset(second.makeImage(), raster: second), sourceRect: bounds,
            patches: [BrushPatch(rect: patch.rect, image: try pattern(64, 64, seed: 111))], crop: bounds)
        check("changed dependency rebuilds affected piece", pieces.pieces(for: third, level: 1, visible: near).first?.image !== reused.first?.image)
        let clipped = RasterSnapshot.replacing(source: firstAsset, sourceRect: bounds,
            patches: [BrushPatch(rect: CGRect(x: 40, y: 40, width: 20, height: 20), image: try pattern(20, 20))], crop: bounds)
        check("split tiles retain original backing allocation identity", clipped.patches.filter { $0.storage === patch.image }.count > 1)
        check("sparse accounting avoids logical full image charge", clipped.resources.reduce(0) { $0 + $1.bytes } < 4096 * 4096 * 4)
        for level in [0, 1, 2] {
            let c = try BrushRaster.context(width: 512, height: 512, mask: false)
            let transform = LayerTransform(origin: .zero, size: CGSize(width: 512, height: 512), sampling: level == 0 ? .nearest : .high)
            TiledLayerRenderer.drawRaster(clipped, transform: transform, center: CGPoint(x: 256, y: 256), scale: 1,
                opacity: 0.5, blendMode: .normal, mask: nil, in: c)
            check("tiled display leaves raster lazy at level \(level)", !clipped.hasMaterializedPixels)
        }

        // Compare the tiled CPU path with a whole-image draw, including translucent replacement edges.
        let comparison = try BrushRaster.context(width: 4096, height: 4096, mask: false)
        TiledLayerRenderer.drawRaster(clipped, transform: LayerTransform(origin: .zero, size: bounds.size),
            center: CGPoint(x: 2048, y: 2048), scale: 1, opacity: 0.5, blendMode: .normal, mask: nil, in: comparison)
        let reference = try BrushRaster.context(width: 4096, height: 4096, mask: false)
        LayerRenderer.draw(try clipped.makeImage(), transform: LayerTransform(origin: .zero, size: bounds.size),
            center: CGPoint(x: 2048, y: 2048), opacity: 0.5, in: reference)
        check("tiled CPU output matches whole raster including alpha", memcmp(comparison.data!, reference.data!, comparison.bytesPerRow * comparison.height) == 0)
        func orphanSource() throws -> WeakRenderSource {
            try autoreleasepool {
                let image = try pattern(256, 256)
                let weak = WeakRenderSource(image)
                _ = DownsampleCache(cache: localCache).image(image, level: 2)
                return weak
            }
        }
        check("cache does not retain dead document sources", try orphanSource().object == nil)

        let placementCache = MaskPlacementCache.shared
        let maskImage = try pattern(32, 32, mask: true)
        let transform = LayerTransform(origin: .zero, size: CGSize(width: 32, height: 32))
        var builds = 0
        func placed() -> CGImage? { builds += 1; return maskImage }
        let placedMask = placementCache.image(mask: maskImage, placement: transform, layer: transform, width: 32, height: 32, build: placed)
        _ = placementCache.image(mask: maskImage, placement: transform, layer: transform, width: 32, height: 32, build: placed)
        check("placed mask shares common cache and reuses output", builds == 1 && placedMask === maskImage)
        RenderCache.shared.respond(to: .critical); RenderCache.shared.respond(to: .normal)
        _ = placementCache.image(mask: maskImage, placement: transform, layer: transform, width: 32, height: 32, build: placed)
        check("pressure also evicts placed masks", builds == 2)
        let effects = LayerEffects(stroke: StrokeEffect(size: 2, red: 1))
        let effect = LayerEffectsRenderer.cached(small, mask: nil, effects: effects)!
        check("cached layer effects equal direct render", try bytes(effect.image) == bytes(LayerEffectsRenderer.render(small, mask: nil, effects: effects).image))
        check("same layer effects reuse output", LayerEffectsRenderer.cached(small, mask: nil, effects: effects)?.image === effect.image)
        let cube = HueSaturationFilter.cube(HueSaturationSettings(hue: 15, saturation: 20))
        RenderCache.shared.respond(to: .critical); RenderCache.shared.respond(to: .normal)
        check("color lookup rebuild after pressure is exact", HueSaturationFilter.cube(HueSaturationSettings(hue: 15, saturation: 20)) == cube)

        let source = try asset(pattern(96, 96))
        var blur = EditableFilterNode(kind: .gaussianBlur); blur.radius = 2
        var noise = EditableFilterNode(kind: .addNoise); noise.seed = 123; noise.amount = 7
        var screen = EditableFilterNode(kind: .colorHalftone); screen.seed = 456
        let prefixCache = FilterPrefixCache(cache: localCache)
        var stack = LayerFilterStack(source: source, nodes: [blur, noise, screen])
        let rendered = try stack.render(cache: prefixCache)
        check("cached filters exactly match uncached pixels", try bytes(rendered) == bytes(stack.render(cache: nil)))
        check("unchanged final render reuses exact output", try stack.render(cache: prefixCache) === rendered)
        let prefix = prefixCache.longestPrefix(source: source, nodes: [blur, noise])!.image
        stack.nodes[2].opacity = 0.4
        check("editing last node preserves two-node prefix", prefixCache.longestPrefix(source: source, nodes: stack.nodes)?.count == 2)
        check("modified last node matches uncached", try bytes(stack.render(cache: prefixCache)) == bytes(stack.render(cache: nil)))
        check("earlier prefix identity remains", prefixCache.longestPrefix(source: source, nodes: [blur, noise])?.image === prefix)
        stack.nodes[1].seed += 1
        check("seed change invalidates only suffix", prefixCache.longestPrefix(source: source, nodes: stack.nodes)?.count == 1)
        stack.nodes[0].coverage = Data(repeating: 80, count: 96 * 96)
        check("coverage change invalidates first node onward", prefixCache.longestPrefix(source: source, nodes: stack.nodes)?.count == 0)
        check("coverage and seed changes preserve exact output", try bytes(stack.render(cache: prefixCache)) == bytes(stack.render(cache: nil)))
        let anotherSource = try asset(pattern(96, 96, seed: 99))
        check("source identity isolates cache", prefixCache.longestPrefix(source: anotherSource, nodes: stack.nodes) == nil)
        let encoded = try JSONEncoder().encode(stack.nodes[0]), decoded = try JSONDecoder().decode(EditableFilterNode.self, from: encoded)
        check("runtime resource identity excluded from project encoding", !String(decoding: encoded, as: UTF8.self).contains("resourceID") && decoded == stack.nodes[0])
        let copiedNode = stack.nodes[0]
        var changedNode = copiedNode; changedNode.coverage = Data(repeating: 40, count: 96 * 96)
        check("value copy shares filter payload accounting", copiedNode.resourceID == stack.nodes[0].resourceID && changedNode.resourceID != copiedNode.resourceID && decoded.resourceID != copiedNode.resourceID)
        let canceled = Task.detached { try Task.checkCancellation(); return try stack.render(cache: prefixCache) }
        canceled.cancel()
        do { _ = try await canceled.value; check("cached result respects cancellation", false) }
        catch is CancellationError { check("cached result respects cancellation", true) }

        // The actual editor path, including final flush, GPU handoff, immutable undo and native save/reopen.
        let session = EditorSession()
        session.createDocument(width: 256, height: 256)
        session.insert(try asset(pattern(256, 256)))
        session.history.reset(); session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 32, hardness: 0, red: 1, opacity: 0.5)
        session.beginBrush(at: CGPoint(x: 80, y: 80))
        let renderer = GPUCanvasRenderer.shared
        let adopts = renderer?.adoptedStrokes ?? 0
        if let renderer, let stroke = session.brushStroke {
            _ = renderer.image(stroke, base: renderer.image(session.activeLayer!.asset!.image))
        }
        session.continueBrush(at: CGPoint(x: 160, y: 100))
        check("brush final flush commits", session.finishBrushImmediately())
        let savedAsset = session.activeLayer!.asset!, raster = savedAsset.raster!
        check("commit does not materialize full image", !raster.hasMaterializedPixels)
        if let renderer, let gpu = renderer.image(raster) {
            check("GPU adopts completed stroke surface", renderer.adoptedStrokes == adopts + 1)
            let firstGPU = try gpuBytes(gpu, renderer: renderer, width: 256, height: 256)
            let firstCPU = try bytes(savedAsset.image)
            let maxDifference = zip(firstGPU, firstCPU).map { abs(Int($0) - Int($1)) }.max() ?? 0
            check("adopted GPU output matches CPU RGBA", maxDifference <= 1)
            result.measurements.append("GPU/CPU adopted raster maximum channel difference: \(maxDifference)")
            session.beginBrush(at: CGPoint(x: 100, y: 100))
            if let stroke = session.brushStroke { _ = renderer.image(stroke, base: renderer.image(raster)) }
            session.continueBrush(at: CGPoint(x: 200, y: 180)); _ = session.finishBrushImmediately()
            _ = renderer.image(session.activeLayer!.asset!.raster!)
            check("later stroke cannot overwrite adopted old texture", try gpuBytes(gpu, renderer: renderer, width: 256, height: 256) == firstGPU)
            session.undo(); check("undo retains exact original snapshot", session.activeLayer?.asset?.image === savedAsset.image)
            session.redo(); check("redo changes pixels", try bytes(session.activeLayer!.asset!.image) != firstCPU)
        } else { result.failures.append("Metal unavailable: GPU handoff not validated") }
        let snapshot = session.projectSnapshot()!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryRegression-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        check("native save/reopen preserves final pixels", try bytes(loaded.images[session.activeLayerID!]!.image) == bytes(session.activeLayer!.asset!.image))
        check("native project format is unchanged", loaded.manifest.version == snapshot.manifest.version)

        let filterSession = EditorSession()
        filterSession.createDocument(width: 96, height: 96); filterSession.insert(source)
        filterSession.beginFilterStack(); filterSession.filterStackEdit!.stack = stack
        await filterSession.renderFilterStack(commit: true)
        let filterURL = FileManager.default.temporaryDirectory.appendingPathComponent("FilterCacheRegression-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: filterURL) }
        try await ProjectStore.shared.save(filterSession.projectSnapshot()!, to: filterURL)
        let reopenedFilters = try await ProjectStore.shared.load(from: filterURL)
        let reopenedStack = reopenedFilters.filterStacks[filterSession.activeLayerID!]!
        check("filter recipe parameters survive native reopen", reopenedStack.nodes == stack.nodes)
        check("reopened filter recipe matches cached pixels exactly", try bytes(reopenedStack.render(cache: nil)) == bytes(reopenedFilters.images[filterSession.activeLayerID!]!.image))

        if let renderer {
            let blank = EditorSession(); blank.createDocument(width: 256, height: 256); blank.addBlankLayer(); blank.selectTool(.brush)
            blank.brushSettings = BrushSettings(diameter: 40, hardness: 0, red: 1)
            blank.beginBrush(at: CGPoint(x: 90, y: 100))
            _ = renderer.image(blank.brushStroke!, base: nil)
            blank.continueBrush(at: CGPoint(x: 130, y: 110)); _ = blank.finishBrushImmediately()
            let cropRaster = blank.activeLayer!.asset!.raster!
            let cropGPU = renderer.image(cropRaster)!
            check("cropped GPU handoff preserves tight bounds and transparent edges", try gpuBytes(cropGPU, renderer: renderer, width: cropRaster.width, height: cropRaster.height) == bytes(blank.activeLayer!.asset!.image))
            blank.addLayerMask(); blank.brushSettings.red = 0
            blank.beginBrush(at: CGPoint(x: 110, y: 105))
            let stroke = blank.brushStroke!
            _ = renderer.image(stroke, base: renderer.image(blank.activeLayer!.mask!.asset.image, mask: true))
            blank.continueBrush(at: CGPoint(x: 120, y: 110)); _ = blank.finishBrushImmediately()
            let maskRaster = blank.activeLayer!.mask!.asset.raster!
            let maskGPU = try gpuBytes(renderer.image(maskRaster)!, renderer: renderer, width: maskRaster.width, height: maskRaster.height)
            let gray = try GPUCanvasRenderer.grayCopy(blank.activeLayer!.mask!.asset.image)
            let grayBytes = gray.data!.assumingMemoryBound(to: UInt8.self)
            let equal = maskGPU.withUnsafeBytes { raw in
                let rgba = raw.bindMemory(to: UInt8.self)
                return (0..<(maskRaster.width * maskRaster.height)).allSatisfy { abs(Int(rgba[$0 * 4]) - Int(grayBytes[$0])) <= 1 }
            }
            check("mask GPU handoff preserves exact coverage", equal)
        }

        session.beginFilterStack()
        session.filterStackEdit!.stack.nodes = [blur, noise]
        let pendingRender = Task { await session.renderFilterStack(commit: true) }
        for _ in 0..<100 {
            if session.isProjectBusy { break }
            await Task.yield()
        }
        let replacement = CanvasDocument(width: 64, height: 64, layers: [])
        session.document = replacement
        await pendingRender.value
        check("old filter completion cannot commit into another document", session.document == replacement)
        session.cancelFilterStack()

        let historyAsset = try asset(pattern(64, 64))
        var historyDocument = CanvasDocument(width: 64, height: 64, layers: [ImageLayer(asset: historyAsset, origin: .zero)])
        let lazy = RasterSnapshot.replacing(source: historyAsset, sourceRect: CGRect(x: 0, y: 0, width: 64, height: 64),
            patches: [BrushPatch(rect: CGRect(x: 0, y: 0, width: 16, height: 16), image: try pattern(16, 16))], crop: CGRect(x: 0, y: 0, width: 64, height: 64))
        historyDocument.layers[0].asset = try asset(lazy.makeImage(), raster: lazy)
        let materializedHistory = DocumentHistory()
        materializedHistory.begin("Brush Stroke", document: historyDocument, selection: historyDocument.layers[0].id)
        let child = RasterSnapshot.replacing(source: historyDocument.layers[0].asset, sourceRect: CGRect(x: 0, y: 0, width: 64, height: 64),
            patches: [BrushPatch(rect: CGRect(x: 0, y: 0, width: 16, height: 16), image: try pattern(16, 16, seed: 17))], crop: CGRect(x: 0, y: 0, width: 64, height: 64))
        historyDocument.layers[0].asset = try asset(child.makeImage(), raster: child)
        materializedHistory.end(document: historyDocument, selection: historyDocument.layers[0].id)
        let sparseBytes = materializedHistory.retainedBytes(current: historyDocument)
        _ = try bytes(lazy.makeImage())
        check("later materialization is included in history accounting", materializedHistory.retainedBytes(current: historyDocument) >= sparseBytes + 64 * 64 * 4)

        for side in large ? [4096, 8192] : [4096] {
            try autoreleasepool {
            stage("history \(side): fixture")
            let started = DispatchTime.now().uptimeNanoseconds
            let base = try pattern(side, side)
            var current = try asset(base)
            var document = CanvasDocument(width: side, height: side, layers: [ImageLayer(asset: current, origin: .zero)])
            let history = DocumentHistory()
            for index in 0..<100 {
                history.begin("Brush Stroke", document: document, selection: document.layers[0].id)
                let tile = BrushPatch(rect: CGRect(x: 100, y: 100, width: 64, height: 64), image: try pattern(64, 64, seed: index))
                let raster = RasterSnapshot.replacing(source: current, sourceRect: CGRect(x: 0, y: 0, width: side, height: side),
                    patches: [tile], crop: CGRect(x: 0, y: 0, width: side, height: side))
                current = try asset(raster.makeImage(), raster: raster)
                document.layers[0].asset = current
                history.end(document: document, selection: document.layers[0].id)
                check("\(side) stroke \(index) stays lazy and undoable", !raster.hasMaterializedPixels && history.undoCount == index + 1)
            }
            stage("history \(side): undo/redo")
            let retained = history.retainedBytes(current: document)
            check("\(side) shared base and tiles fit history budget", retained < 8 * 1024 * 1024 && history.undoCount == 100)
            let latest = document
            for _ in 0..<100 { if let state = history.undo() { document = state.document! } }
            check("\(side) 100 undos restore original allocation", document.layers[0].asset?.image === base)
            for _ in 0..<100 { if let state = history.redo() { document = state.document! } }
            check("\(side) 100 redos restore final allocation", document == latest)
            result.measurements.append("\(side)x\(side), 100 sparse edits: history \(retained) bytes; logical full-image accounting would be at least \(side * side * 4 * 99) bytes; \(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)) ms including fixture and undo/redo")
            RenderCache.shared.removeAll()
        }
            }
        if large, let renderer {
            let scenes = widescreen ? [(3840, 2160, 20), (7680, 4320, 10)] : [(4096, 4096, 20), (8192, 8192, 10)]
            for (width, height, count) in scenes {
                let side = "\(width)x\(height)"
                try autoreleasepool {
                let started = DispatchTime.now().uptimeNanoseconds
                let test = EditorSession()
                var layers: [ImageLayer] = []
                for index in 0..<count {
                    stage("GPU \(side): fixture \(index + 1)/\(count)")
                    var layer = try autoreleasepool { ImageLayer(asset: try asset(pattern(width, height, seed: index * 19)), origin: .zero) }
                    layer.opacity = index == 0 ? 1 : 0.4
                    layer.blendMode = index % 3 == 0 ? .screen : index % 3 == 1 ? .multiply : .normal
                    layers.append(layer)
                }
                test.document = CanvasDocument(width: width, height: height, layers: layers)
                test.viewport.resize(to: CGSize(width: 512, height: 512), backingScale: 1, documentSize: test.document!.size)
                test.viewport.fit(documentSize: test.document!.size)
                let canvas = CanvasView(session: test); canvas.frame = CGRect(x: 0, y: 0, width: 512, height: 512)
                var firstFrame: Data?
                var frameTimes: [Double] = []
                var peakMetalBytes = 0
                for cycle in 0..<20 {
                    stage("GPU \(side): frame \(cycle + 1)/20")
                    try autoreleasepool {
                    let frameStarted = DispatchTime.now().uptimeNanoseconds
                    guard let frame = canvas.gpuFrame(size: CGSize(width: 512, height: 512)) else { throw ExportError.render }
                    let output = try gpuBytes(frame, renderer: renderer, width: 512, height: 512)
                    renderer.endFrame()
                    frameTimes.append(Double(DispatchTime.now().uptimeNanoseconds - frameStarted) / 1_000_000)
                    peakMetalBytes = max(peakMetalBytes, renderer.device.currentAllocatedSize)
                    if cycle == 0 { firstFrame = output }
                    check("\(side), \(count) layers, repeat \(cycle): output and cap", output == firstFrame && RenderCache.shared.retainedBytes <= RenderCache.shared.currentLimit)
                    // Exercise the same common budget with the CPU reductions between GPU frames.
                    _ = DownsampleCache.shared.image(layers[cycle % count].asset!.image, level: 3)
                    }
                }
                result.measurements.append("\(side), \(count) distinct layers, 20 GPU viewport renders: \(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)) ms including fixture; retained cache \(RenderCache.shared.retainedBytes) / \(RenderCache.shared.currentLimit) bytes")
                let warm = frameTimes.dropFirst().sorted()
                result.measurements.append("\(side) viewport 512x512 offscreen composition + GPU readback: cold \(String(format: "%.2f", frameTimes[0])) ms, warm median \(String(format: "%.2f", warm[warm.count / 2])) ms, warm p95 \(String(format: "%.2f", warm[min(warm.count - 1, Int(ceil(Double(warm.count) * 0.95)) - 1)])) ms; peak observed Metal allocation \(peakMetalBytes) bytes. This is not display frame rate or input-to-photon latency.")
                check("\(side) retains no upload intermediates", layers.allSatisfy { layer in
                    let levels = renderer.cachedLevels(of: layer.asset!.image)
                    return levels.count <= 1 && !levels.contains(0)
                })
                RenderCache.shared.removeAll()
                check("\(side) explicit cache release returns accounting to zero", RenderCache.shared.retainedBytes == 0)
            }
        }
            }
        RenderCache.shared.respond(to: .critical)
        check("global critical pressure clears CPU and GPU entries", RenderCache.shared.retainedBytes == 0 && RenderCache.shared.count == 0)
        RenderCache.shared.respond(to: .normal)
        return result
    }
}
#if !MEMORY_PERFORMANCE_CLT_CHECKS
@MainActor struct MemoryPerformanceRegressionTests {
    @Test func cacheHistoryTilesAndFilters() async throws {
        let result = try await MemoryPerformanceRegressionChecks.run()
        #expect(result.failures.isEmpty, "\(result.failures)")
    }
}
#endif
