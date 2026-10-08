import AppKit
import Observation

nonisolated enum LiquifyTool: String, CaseIterable, Sendable {
    case push = "Forward Warp"
    case twirl = "Twirl"
    case pinch = "Pinch"
    case bloat = "Bloat"
    case reconstruct = "Reconstruct"
    case freeze = "Freeze"
    case thaw = "Thaw"
    // Match LiquifyPixels.c independently of the tool order in the UI.
    var code: Int32 {
        switch self {
        case .push: 0
        case .twirl: 1
        case .pinch: 2
        case .bloat: 3
        case .reconstruct: 5
        case .freeze: 7
        case .thaw: 8
        }
    }
    var stationary: Bool { self != .push }
}

/// Valid only inside the synchronous concurrentPerform call. Workers write disjoint rows.
nonisolated private struct LiquifySampleBuffers: @unchecked Sendable {
    let source: UnsafePointer<UInt8>
    let field: UnsafePointer<LiquifyNode>
    let coverage: UnsafePointer<UInt8>?
    let output: UnsafeMutablePointer<UInt8>
    let stride: Int32
}

nonisolated struct LiquifyPixels: @unchecked Sendable {
    let source: Data
    let coverage: Data?
    let width: Int, height: Int, gridWidth: Int, gridHeight: Int, step: Int
    let keepsAlpha: Bool
    let gpu: LiquifyMetalRenderer?
    static func estimate(width: Int, height: Int) -> Int {
        let step = max(1, Int(ceil(Double(max(width, height)) / 1536)))
        return width * height * (width * height <= 16_777_216 ? 20 : 16) + (width / step + 2) * (height / step + 2) * 48
            + 96 * 1024 * 1024
    }
    static func fits(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= DocumentLimits.maxSide && height <= DocumentLimits.maxSide
            && width * height <= DocumentLimits.maxSurfacePixels
            && estimate(width: width, height: height)
                <= min(1536 * 1024 * 1024, Int(ProcessInfo.processInfo.physicalMemory / 4))
    }
    func render(nodes: Data, longSide: Int? = nil, useGPU: Bool = true) throws -> CGImage {
        let factor = longSide.map { min(1, Double($0) / Double(max(width, height))) } ?? 1
        let w = max(1, Int(Double(width) * factor))
        let h = max(1, Int(Double(height) * factor))
        if useGPU,
            let image = gpu?.render(
                nodes: nodes, gridWidth: gridWidth, gridHeight: gridHeight, step: step, width: w, height: h,
                keepsAlpha: keepsAlpha)
        {
            return image
        }
        let c = try BrushRaster.context(width: w, height: h, mask: false)
        guard let target = c.data else { throw ExportError.render }
        source.withUnsafeBytes { src in
            nodes.withUnsafeBytes { field in
                func draw(_ mask: UnsafeRawPointer?) {
                    let buffers = LiquifySampleBuffers(
                        source: src.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        field: field.baseAddress!.assumingMemoryBound(to: LiquifyNode.self),
                        coverage: mask?.assumingMemoryBound(to: UInt8.self),
                        output: target.assumingMemoryBound(to: UInt8.self), stride: Int32(c.bytesPerRow))
                    // Disjoint output rows; every worker reads the same immutable source and field.
                    DispatchQueue.concurrentPerform(iterations: 8) { index in
                        liquify_render(
                            buffers.source, Int32(width), Int32(height), Int32(width * 4),
                            buffers.field, Int32(gridWidth), Int32(gridHeight), Float(step),
                            buffers.coverage, Int32(width), keepsAlpha ? 1 : 0,
                            buffers.output, Int32(w), Int32(h), buffers.stride, Int32(h * index / 8),
                            Int32(h * (index + 1) / 8))
                    }
                }
                if let coverage { coverage.withUnsafeBytes { draw($0.baseAddress) } } else { draw(nil) }
            }
        }
        guard let image = c.makeImage() else { throw ExportError.render }
        return image
    }
    func overlay(nodes: Data, width w: Int, height h: Int) throws -> CGImage {
        let c = try BrushRaster.context(width: w, height: h, mask: false)
        nodes.withUnsafeBytes { field in
            liquify_overlay(
                field.baseAddress!.assumingMemoryBound(to: LiquifyNode.self), Int32(gridWidth), Int32(gridHeight),
                Float(step),
                Int32(width), Int32(height), c.data!.assumingMemoryBound(to: UInt8.self), Int32(w), Int32(h),
                Int32(c.bytesPerRow))
        }
        guard let image = c.makeImage() else { throw ExportError.render }
        return image
    }
}

@MainActor @Observable
final class LiquifyWorkspace {
    let owner: EditOwner
    let layer: ImageLayer
    let original: CGImage
    let pixels: LiquifyPixels
    let referenceLayers: [ImageLayer]
    let mustUseCopy: Bool
    var tool: LiquifyTool = .push
    var diameter: Double = 180
    var hardness: Double = 0.3
    var strength: Double = 0.6
    var rate: Double = 1
    var reversesDirection = false
    var usesPressure = true
    var fixedEdges = true
    var showsOriginal = false
    var showsFrozen = true
    var showsMesh = false
    var showsBackdrop = false
    var createsCopy = true
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    var revision = 0
    var preview: CGImage?
    var frozenOverlay: CGImage?
    var isRendering = false
    var isApplying = false
    var error: String?
    var historyWasTrimmed = false
    @ObservationIgnored private var pendingStrengthDigit: (digit: Int, time: TimeInterval)?
    @ObservationIgnored private(set) var nodes: Data
    @ObservationIgnored private var scratch: Data
    private struct Patch {
        let tile: Int
        let before: Data
        let after: Data
    }
    private struct Step {
        let patches: [Patch]
        var bytes: Int { patches.reduce(0) { $0 + $1.before.count + $1.after.count } }
    }
    @ObservationIgnored private var past: [Step] = []
    @ObservationIgnored private var future: [Step] = []
    @ObservationIgnored private var captured: [Int: Data] = [:]
    @ObservationIgnored private var last: CGPoint?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    private(set) var isStroking = false
    var canUndo: Bool {
        _ = revision
        return !past.isEmpty && !isStroking && !isApplying
    }
    var canRedo: Bool {
        _ = revision
        return !future.isEmpty && !isStroking && !isApplying
    }
    var hasWarp: Bool {
        nodes.withUnsafeBytes { $0.bindMemory(to: LiquifyNode.self).contains { $0.dx != 0 || $0.dy != 0 } }
    }
    var historyBytes: Int { (past + future).reduce(0) { $0 + $1.bytes } }
    static let historyLimit = 64 * 1024 * 1024

    // The two workspaces use document pixels and source pixels respectively.
    // The geometric mean keeps the brush area comparable under uneven scaling.
    private var documentBrushScale: Double {
        sqrt(Double(layer.size.width / CGFloat(pixels.width) * layer.size.height / CGFloat(pixels.height)))
    }
    func inheritBrushTip(_ tip: (diameter: CGFloat, hardness: CGFloat, opacity: CGFloat)) {
        diameter = min(3000, max(2, Double(tip.diameter) / documentBrushScale))
        hardness = min(1, max(0, Double(tip.hardness)))
        strength = min(1, max(0.01, Double(tip.opacity)))
    }
    var basicBrushTip: (diameter: CGFloat, hardness: CGFloat, opacity: CGFloat) {
        (CGFloat(min(2000, max(1, diameter * documentBrushScale))), CGFloat(hardness), CGFloat(strength))
    }
    func changeBrushSize(increase: Bool) {
        guard !isApplying, !isStroking else { return }
        diameter = Double(BrushSettings.steppedDiameter(CGFloat(diameter), increase: increase, range: 2...3000))
    }
    func changeBrushHardness(increase: Bool) {
        guard !isApplying, !isStroking else { return }
        hardness = Double(BrushSettings.steppedHardness(CGFloat(hardness), increase: increase))
    }
    func typeStrengthDigit(_ digit: Int, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !isApplying, !isStroking, (0...9).contains(digit) else { return }
        strength = Double(BrushSettings.opacityValue(digit, at: time, pending: &pendingStrengthDigit))
    }

    init(owner: EditOwner, layer: ImageLayer, selection: SelectionClip?, references: [ImageLayer], keepsAlpha: Bool)
        throws
    {
        guard let image = layer.asset?.image, LiquifyPixels.fits(width: image.width, height: image.height) else {
            throw LiquifyError.budget
        }
        self.owner = owner
        self.layer = layer
        original = image
        referenceLayers = references
        mustUseCopy = layer.text != nil || layer.shape != nil
        let w = image.width
        let h = image.height
        let step = max(1, Int(ceil(Double(max(w, h)) / 1536)))
        let gw = (w - 1 + step - 1) / step + 1
        let gh = (h - 1 + step - 1) / step + 1
        let c = try BrushRaster.copy(image)
        let source = Data(bytes: c.data!, count: w * h * 4)
        var coverage: Data?
        if let selection {
            let mask = try BrushRaster.context(width: w, height: h, mask: true)
            mask.concatenate(BrushRaster.pixelToDocument(layer.transform, width: w, height: h).inverted())
            selection.apply(to: mask)
            mask.setFillColor(gray: 1, alpha: 1)
            mask.fill(selection.rect)
            coverage = Data(bytes: mask.data!, count: w * h)
        }
        pixels = LiquifyPixels(
            source: source, coverage: coverage, width: w, height: h,
            gridWidth: gw, gridHeight: gh, step: step, keepsAlpha: keepsAlpha,
            gpu: LiquifyMetalRenderer(source: source, coverage: coverage, width: w, height: h))
        nodes = Data(count: gw * gh * MemoryLayout<LiquifyNode>.stride)
        scratch = Data(count: nodes.count)
        diameter = min(180, max(10, Double(min(w, h)) / 3))
        preview = try pixels.render(nodes: nodes, longSide: 1280)
    }

    private var tilesAcross: Int { (pixels.gridWidth + 31) / 32 }
    private func tileRect(_ tile: Int) -> (x: Int, y: Int, w: Int, h: Int) {
        let x = (tile % tilesAcross) * 32
        let y = (tile / tilesAcross) * 32
        return (x, y, min(32, pixels.gridWidth - x), min(32, pixels.gridHeight - y))
    }
    private func tileData(_ tile: Int) -> Data {
        let r = tileRect(tile)
        let stride = MemoryLayout<LiquifyNode>.stride
        var data = Data(count: r.w * r.h * stride)
        data.withUnsafeMutableBytes { to in
            nodes.withUnsafeBytes { from in
                for y in 0..<r.h {
                    memcpy(
                        to.baseAddress! + y * r.w * stride,
                        from.baseAddress! + ((r.y + y) * pixels.gridWidth + r.x) * stride, r.w * stride)
                }
            }
        }
        return data
    }
    private func put(_ data: Data, tile: Int) {
        let r = tileRect(tile)
        let stride = MemoryLayout<LiquifyNode>.stride
        nodes.withUnsafeMutableBytes { to in
            data.withUnsafeBytes { from in
                for y in 0..<r.h {
                    memcpy(
                        to.baseAddress! + ((r.y + y) * pixels.gridWidth + r.x) * stride,
                        from.baseAddress! + y * r.w * stride, r.w * stride)
                }
            }
        }
    }
    private func capture(center: CGPoint, radius: Double) {
        let x0 = max(0, Int(floor((center.x - radius) / Double(pixels.step))) / 32)
        let y0 = max(0, Int(floor((center.y - radius) / Double(pixels.step))) / 32)
        let x1 = min(tilesAcross - 1, Int(ceil((center.x + radius) / Double(pixels.step))) / 32)
        let y1 = min((pixels.gridHeight - 1) / 32, Int(ceil((center.y + radius) / Double(pixels.step))) / 32)
        guard x1 >= x0, y1 >= y0 else { return }
        for y in y0...y1 {
            for x in x0...x1 {
                let tile = y * tilesAcross + x
                if captured[tile] == nil { captured[tile] = tileData(tile) }
            }
        }
    }
    func beginStroke(_ point: CGPoint) {
        guard !isApplying else { return }
        isStroking = true
        last = point
        captured = [:]
    }
    /// Stationary tools integrate elapsed time, not pointer-event count. Drag tools integrate distance.
    func append(_ point: CGPoint, elapsed: Double, pressure: Double = 1) {
        guard isStroking, !isApplying, let from = last, point.x.isFinite, point.y.isFinite else { return }
        let dx = point.x - from.x
        let dy = point.y - from.y
        let distance = hypot(dx, dy)
        let steps = max(1, Int(ceil(distance / max(1, diameter * 0.08))))
        let force = strength * (usesPressure ? min(1, max(0.05, pressure)) : 1)
        for index in 1...steps {
            let t = Double(index) / Double(steps)
            let center = CGPoint(x: from.x + dx * t, y: from.y + dy * t)
            capture(center: center, radius: diameter / 2)
            // A shared old field for this dab; only its sampling neighborhood needs refreshing.
            let margin = diameter * 1.5 + Double(pixels.step * 3)
            let stride = MemoryLayout<LiquifyNode>.stride
            let x0 = max(0, Int(floor((center.x - margin) / Double(pixels.step))))
            let y0 = max(0, Int(floor((center.y - margin) / Double(pixels.step))))
            let x1 = min(pixels.gridWidth, Int(ceil((center.x + margin) / Double(pixels.step))) + 1)
            let y1 = min(pixels.gridHeight, Int(ceil((center.y + margin) / Double(pixels.step))) + 1)
            guard x1 > x0, y1 > y0 else { continue }
            scratch.withUnsafeMutableBytes { to in
                nodes.withUnsafeBytes { old in
                    for y in y0..<y1 {
                        let offset = (y * pixels.gridWidth + x0) * stride
                        memcpy(to.baseAddress! + offset, old.baseAddress! + offset, (x1 - x0) * stride)
                    }
                }
            }
            var amount = force
            if tool.stationary { amount *= min(0.1, max(0, elapsed)) / Double(steps) * rate * 3 }
            if tool == .freeze || tool == .thaw { amount = force }
            if tool == .twirl && reversesDirection { amount = -amount }
            nodes.withUnsafeMutableBytes { output in
                scratch.withUnsafeBytes { input in
                    liquify_dab(
                        output.baseAddress!.assumingMemoryBound(to: LiquifyNode.self),
                        input.baseAddress!.assumingMemoryBound(to: LiquifyNode.self),
                        Int32(pixels.gridWidth), Int32(pixels.gridHeight), Float(pixels.step), Int32(pixels.width),
                        Int32(pixels.height),
                        Float(center.x), Float(center.y), Float(dx / Double(steps)), Float(dy / Double(steps)),
                        Float(diameter / 2),
                        Float(min(0.98, max(0, hardness))), Float(amount), tool.code, fixedEdges ? 1 : 0)
                }
            }
        }
        last = point
        revision += 1
        requestPreview()
    }
    func endStroke() {
        guard isStroking else { return }
        isStroking = false
        last = nil
        let patches = captured.compactMap { tile, before -> Patch? in
            let after = tileData(tile)
            return before == after ? nil : Patch(tile: tile, before: before, after: after)
        }
        captured = [:]
        if !patches.isEmpty {
            past.append(Step(patches: patches))
            future = []
            trimHistory()
        }
        revision += 1
    }
    private func trimHistory() {
        while historyBytes > Self.historyLimit || past.count + future.count > 100 {
            if !past.isEmpty {
                past.removeFirst()
                historyWasTrimmed = true
            } else if !future.isEmpty {
                future.removeFirst()
            } else {
                break
            }
        }
    }
    func undo() {
        guard canUndo, let step = past.popLast() else { return }
        for p in step.patches { put(p.before, tile: p.tile) }
        future.append(step)
        revision += 1
        requestPreview()
    }
    func redo() {
        guard canRedo, let step = future.popLast() else { return }
        for p in step.patches { put(p.after, tile: p.tile) }
        past.append(step)
        revision += 1
        requestPreview()
    }
    func reset(onlyFreeze: Bool = false) {
        guard !isApplying else { return }
        endStroke()
        beginStroke(.zero)
        for tile in 0..<(tilesAcross * ((pixels.gridHeight + 31) / 32)) { captured[tile] = tileData(tile) }
        nodes.withUnsafeMutableBytes { raw in
            let list = raw.bindMemory(to: LiquifyNode.self)
            for i in list.indices {
                if onlyFreeze {
                    list[i].frozen = 0
                } else {
                    list[i].dx = 0
                    list[i].dy = 0
                }
            }
        }
        endStroke()
        revision += 1
        requestPreview()
    }
    func offset(at point: CGPoint) -> CGPoint {
        let x = min(pixels.gridWidth - 1, max(0, Int(point.x / CGFloat(pixels.step))))
        let y = min(pixels.gridHeight - 1, max(0, Int(point.y / CGFloat(pixels.step))))
        return nodes.withUnsafeBytes {
            let p = $0.bindMemory(to: LiquifyNode.self)[y * pixels.gridWidth + x]
            return CGPoint(x: point.x + CGFloat(p.dx), y: point.y + CGFloat(p.dy))
        }
    }
    func requestPreview() {
        guard !isRendering, !isApplying else { return }
        isRendering = true
        let generation = revision
        let pixels = pixels
        let field = nodes
        previewTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CGImage?) in
                guard let image = try? pixels.render(nodes: field, longSide: 1280) else { return (nil, nil) }
                return (image, try? pixels.overlay(nodes: field, width: image.width, height: image.height))
            }.value
            guard let self else { return }
            self.isRendering = false
            if self.revision == generation {
                self.preview = result.0
                self.frozenOverlay = result.1
            } else {
                self.requestPreview()
            }
        }
    }
    func rendered() async throws -> CGImage {
        let pixels = pixels
        let field = nodes
        return try await Task.detached(priority: .userInitiated) { try pixels.render(nodes: field) }.value
    }
}

nonisolated enum LiquifyError: String, LocalizedError {
    case budget = "This layer exceeds the Liquify working-memory budget. Use a smaller raster copy."
    case stale = "The document or layer changed. The Liquify result was not applied."
    var errorDescription: String? { L10n.text(rawValue) }
}

extension EditorSession {
    var canLiquify: Bool {
        canEditLayers && effectsEditing == nil && !history.hasPendingEdit && selectedLayerIDs.count == 1
            && !isMaskSelected && activeLayer?.asset != nil
            && activeLayer?.isGroup == false && activeLayer?.adjustment == nil && selection?.isEmpty != true
            && allowsLayerEdit(activeLayerID, .content)
            && activeLayerID.map { document?.effectiveVisibleIDs.contains($0) == true } == true
    }
    func beginLiquify() {
        guard canLiquify, let document, let layer = activeLayer, activeEditOwner == nil else { return }
        finishOpacityEdit()
        let owner = EditOwner(documentID: document.id, revision: history.currentRevision)
        do {
            let references = document.layers.filter {
                document.effectiveVisibleIDs.contains($0.id) && $0.id != layer.id
            }
            let edit = try LiquifyWorkspace(
                owner: owner, layer: layer, selection: try selection?.clip(canvas: document.size),
                references: references,
                keepsAlpha: effectiveLocks(for: layer.id).contains(.transparency))
            edit.inheritBrushTip(basicLiquifyTip)
            activeEditOwner = owner
            liquify = edit
        } catch { brushError = error.localizedDescription }
    }
    func cancelLiquify() {
        guard let edit = liquify else { return }
        liquify = nil
        releaseEdit(edit.owner)
    }
    @discardableResult func applyLiquify() async -> Bool {
        guard let edit = liquify, !edit.isApplying else { return false }
        edit.endStroke()
        guard edit.hasWarp else {
            cancelLiquify()
            return false
        }
        let copy = edit.createsCopy || edit.mustUseCopy
        guard ownsEdit(edit.owner), allowsLayerEdit(edit.layer.id, .content),
            !copy || (allowsLayerEdit(edit.layer.id, .appearance) && (document?.layers.count ?? 10_000) < 10_000),
            !copy
                || (document?.layers.reduce(0) { $0 + ($1.asset.map { $0.image.width * $0.image.height } ?? 0) } ?? 0)
                    + edit.pixels.width * edit.pixels.height <= DocumentLimits.documentPixelBudget
        else {
            edit.error = L10n.text("The layer is locked or the duplicate would exceed this document’s limits.")
            return false
        }
        edit.isApplying = true
        isProjectBusy = true
        do {
            let image = try await edit.rendered()
            guard liquify === edit, ownsEdit(edit.owner),
                let index = document?.layers.firstIndex(where: { $0.id == edit.layer.id }),
                document?.layers[index] == edit.layer, allowsLayerEdit(edit.layer.id, .content)
            else { throw LiquifyError.stale }
            if let bytes = image.dataProvider?.data, CFDataGetLength(bytes) == edit.pixels.source.count,
                edit.pixels.source.withUnsafeBytes({
                    memcmp($0.baseAddress!, CFDataGetBytePtr(bytes)!, edit.pixels.source.count) == 0
                })
            {
                cancelLiquify()
                return false
            }
            let asset = ImportedImage(
                image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: edit.layer.name)
            var candidate = document!
            if copy {
                let source = edit.layer
                let new = ImageLayer(
                    id: UUID(), asset: asset, name: L10n.format("%@ — Advanced Liquify", source.name), isVisible: true,
                    transform: source.transform,
                    parentID: source.parentID, opacity: source.opacity, blendMode: source.blendMode, mask: source.mask,
                    maskSourceID: source.maskSourceID, effects: source.effects)
                candidate.layers[index].isVisible = false
                candidate.layers.insert(new, at: index + 1)
            } else {
                candidate.layers[index].asset = asset
                candidate.layers[index].text = nil
                candidate.layers[index].shape = nil
            }
            guard !violatesLayerLocks(before: document, after: candidate) else { throw EditRefusal.locked }
            let before = document
            beginEdit("Advanced Liquify")
            document = candidate
            activeLayerID = candidate.layers[copy ? index + 1 : index].id
            endEdit()
            let changed = document != before
            basicLiquifyTip = edit.basicBrushTip
            liquify = nil
            releaseEdit(edit.owner)
            return changed
        } catch {
            edit.isApplying = false
            if liquify === edit { edit.error = error.localizedDescription }
            releaseEdit(edit.owner)
            // A failed apply can be retried only while it still owns the same document revision.
            if liquify === edit, document?.id == edit.owner.documentID, history.currentRevision == edit.owner.revision {
                activeEditOwner = edit.owner
            }
            return false
        }
    }
}
