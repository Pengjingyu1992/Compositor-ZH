import AppKit
import Observation

nonisolated enum EditableFilterError: String, LocalizedError {
    case budget = "This layer exceeds the editable-filter working-memory budget. Use a smaller raster copy."
    var errorDescription: String? { L10n.text(rawValue) }
}

nonisolated enum EditableFilterKind: String, Codable, CaseIterable, Sendable {
    case gaussianBlur = "Gaussian Blur", motionBlur = "Motion Blur", addNoise = "Add Noise"
    case colorHalftone = "Color Halftone", colorLUT = "Color Lookup", liquify = "Advanced Liquify"
    var pixelKind: FilterKind? { FilterKind(rawValue: rawValue) }
}

/// A fixed source-pixel grid keeps selections and saved displacement fields independent of document transforms.
nonisolated struct SavedLiquify: Codable, Equatable, Sendable {
    var width: Int, height: Int, step: Int, gridWidth: Int, gridHeight: Int
    var field: Data
    var coverage: Data?
    var keepsAlpha: Bool
    var diameter: Double, hardness: Double, strength: Double, rate: Double
    var fixedEdges: Bool, usesPressure: Bool, reversesDirection: Bool
    var tool: LiquifyTool
    var isValid: Bool {
        guard width > 0, height > 0, width <= DocumentLimits.maxSide, height <= DocumentLimits.maxSide,
              width * height <= DocumentLimits.maxSurfacePixels,
              step == max(1, Int(ceil(Double(max(width, height)) / 1536))),
              gridWidth == (width - 1 + step - 1) / step + 1,
              gridHeight == (height - 1 + step - 1) / step + 1,
              field.count == gridWidth * gridHeight * 12,
              coverage == nil || coverage?.count == width * height,
              diameter.isFinite, (2...3000).contains(diameter), hardness.isFinite, (0...1).contains(hardness),
              strength.isFinite, (0.01...1).contains(strength), rate.isFinite, (0.1...3).contains(rate) else { return false }
        return field.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Float.self)
            return values.indices.allSatisfy { index in
                let value = values[index]
                return value.isFinite && (index % 3 == 2 ? (0...1).contains(value) : abs(value) <= Float(DocumentLimits.maxSide * 4))
            }
        }
    }
    func render(_ image: CGImage) throws -> CGImage {
        guard isValid, image.width == width, image.height == height,
              LiquifyPixels.fits(width: width, height: height) else { throw LiquifyError.budget }
        let context = try BrushRaster.copy(image)
        let source = Data(bytes: context.data!, count: width * height * 4)
        let pixels = LiquifyPixels(source: source, coverage: coverage, width: width, height: height,
            gridWidth: gridWidth, gridHeight: gridHeight, step: step, keepsAlpha: keepsAlpha, gpu: nil)
        return try pixels.render(nodes: field, useGPU: false)
    }
}

nonisolated struct EditableFilterNode: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var version = 1
    var kind: EditableFilterKind
    var enabled = true
    var opacity: Double = 1
    var seed = UInt32.random(in: .min ... .max)
    var radius: Double = 1
    var angle: Double = 0
    var distance: Double = 10
    var amount: Double = 10
    var gaussian = false
    var monochromatic = false
    var halftone = ColorHalftoneSettings()
    var lut = ColorLUTSettings() { didSet { resourceID = UUID() } }
    var liquify: SavedLiquify? { didSet { resourceID = UUID() } }
    /// Optional grayscale coverage in source-pixel coordinates, captured when the step is added.
    var coverage: Data? { didSet { resourceID = UUID() } }
    // Runtime allocation identity survives value copies; editing payloads starts another resource group.
    private(set) var resourceID = UUID()
    private enum CodingKeys: String, CodingKey {
        case id, version, kind, enabled, opacity, seed, radius, angle, distance, amount, gaussian, monochromatic
        case halftone, lut, liquify, coverage
    }
    var resources: [RenderResource] { [RenderResource(id: .field(resourceID), bytes: retainedBytes)] }
    var isValid: Bool {
        version == 1 && opacity.isFinite && (0...1).contains(opacity)
        && radius.isFinite && (0.1...250).contains(radius)
        && angle.isFinite && (-90...90).contains(angle)
        && distance.isFinite && (1...2000).contains(distance)
        && amount.isFinite && (0.1...400).contains(amount) && halftone.isValid && lut.isValid
        && (kind != .colorLUT || !enabled || lut.table != nil)
        && (kind == .liquify ? liquify?.isValid == true : liquify == nil)
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.version == rhs.version && lhs.kind == rhs.kind
            && lhs.enabled == rhs.enabled && lhs.opacity == rhs.opacity && lhs.seed == rhs.seed
            && lhs.radius == rhs.radius && lhs.angle == rhs.angle && lhs.distance == rhs.distance
            && lhs.amount == rhs.amount && lhs.gaussian == rhs.gaussian && lhs.monochromatic == rhs.monochromatic
            && lhs.halftone == rhs.halftone && lhs.lut == rhs.lut && lhs.liquify == rhs.liquify && lhs.coverage == rhs.coverage
    }
    var settings: FilterSettings {
        var value = FilterSettings()
        value.radius = radius; value.angle = angle; value.distance = distance; value.amount = amount
        value.gaussian = gaussian; value.monochromatic = monochromatic
        value.colorHalftone = halftone; value.colorLUT = lut
        return value
    }
    var retainedBytes: Int {
        // Each LUT triple also owns an Array allocation; count its storage conservatively.
        (coverage?.count ?? 0) + (liquify?.field.count ?? 0) + (liquify?.coverage?.count ?? 0)
            + (lut.table?.values.count ?? 0) * 64
    }
}

nonisolated struct LayerFilterStack: Equatable, @unchecked Sendable {
    var source: ImportedImage
    var nodes: [EditableFilterNode]
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.source.image === rhs.source.image && lhs.nodes == rhs.nodes }
    var retainedBytes: Int { nodes.reduce(0) { $0 + $1.retainedBytes } }
    var minimumProjectVersion: Int {
        nodes.contains { $0.kind == .colorHalftone && !$0.halftone.usesLegacyScreen } ? 15 : 14
    }
    var isValid: Bool {
        let w = source.image.width, h = source.image.height
        return (1...DocumentLimits.maxSide).contains(w) && (1...DocumentLimits.maxSide).contains(h)
            && w * h <= DocumentLimits.maxSurfacePixels
            && nodes.count <= 32 && Set(nodes.map(\.id)).count == nodes.count
            && retainedBytes <= 256 * 1024 * 1024
            && nodes.allSatisfy { $0.isValid && ($0.coverage == nil || $0.coverage?.count == w * h)
                && ($0.liquify == nil || ($0.liquify?.width == w && $0.liquify?.height == h)) }
    }
    func render(through count: Int? = nil, cache: FilterPrefixCache? = .shared) throws -> CGImage {
        guard isValid, count.map({ (0...nodes.count).contains($0) }) ?? true else { throw ProjectError.invalid }
        let pixels = source.image.width * source.image.height
        guard pixels <= DocumentLimits.maxSurfacePixels,
              pixels * 20 + retainedBytes <= min(1536 * 1024 * 1024, Int(ProcessInfo.processInfo.physicalMemory / 4)) else { throw EditableFilterError.budget }
        try Task.checkCancellation()
        let requested = Array(nodes.prefix(count ?? nodes.count))
        let known = cache?.longestPrefix(source: source, nodes: requested)
        let start: Int
        var image: CGImage
        if let known { image = known.image; start = known.count }
        else {
            // Normalize premultiplication identically for uncached and cached paths, including reopened PNGs.
            guard let normalized = try BrushRaster.copy(source.image).makeImage() else { throw ExportError.render }
            image = normalized; start = 0
            cache?.store(image, source: source, nodes: [])
        }
        for index in start..<requested.count {
            try Task.checkCancellation()
            let node = requested[index]
            if node.enabled && node.opacity > 0 {
                let before = image
                if let warp = node.liquify { image = try warp.render(image) }
                else if let kind = node.kind.pixelKind {
                    if kind == .colorLUT && node.lut.table == nil { throw ProjectError.invalid }
                    image = try PixelFilter.run(FilterJob(kind: kind, image: image, settings: node.settings,
                        scale: 1, selection: nil, mapping: .identity, seed: node.seed))
                } else { throw ProjectError.invalid }
                if node.coverage != nil || node.opacity != 1 { image = try Self.mix(image, over: before, coverage: node.coverage, opacity: node.opacity) }
            }
            try Task.checkCancellation()
            cache?.store(image, source: source, nodes: Array(requested.prefix(index + 1)))
        }
        return image
    }
    static func mix(_ image: CGImage, over original: CGImage, coverage: Data?, opacity: Double) throws -> CGImage {
        let input = try BrushRaster.copy(original), output = try BrushRaster.copy(image)
        guard let a = input.data?.assumingMemoryBound(to: UInt8.self), let b = output.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
        func blend(_ mask: UnsafePointer<UInt8>?) {
            for y in 0..<image.height { for x in 0..<image.width {
                let weight = opacity * Double(mask?[y * image.width + x] ?? 255) / 255
                for channel in 0..<4 {
                    let i = y * input.bytesPerRow + x * 4 + channel, j = y * output.bytesPerRow + x * 4 + channel
                    b[j] = UInt8(max(0, min(255, (Double(a[i]) * (1 - weight) + Double(b[j]) * weight).rounded())))
                }
            } }
        }
        if let coverage { coverage.withUnsafeBytes { blend($0.bindMemory(to: UInt8.self).baseAddress) } } else { blend(nil) }
        guard let result = output.makeImage() else { throw ExportError.render }
        return result
    }
    static func coverage(_ selection: SelectionClip?, layer: ImageLayer) throws -> Data? {
        guard let selection, let image = layer.asset?.image else { return nil }
        let mask = try BrushRaster.context(width: image.width, height: image.height, mask: true)
        mask.concatenate(BrushRaster.pixelToDocument(layer.transform, width: image.width, height: image.height).inverted())
        selection.apply(to: mask); mask.setFillColor(gray: 1, alpha: 1); mask.fill(selection.rect)
        var data = Data(count: image.width * image.height)
        data.withUnsafeMutableBytes { to in
            for y in 0..<image.height { memcpy(to.baseAddress! + y * image.width, mask.data! + y * mask.bytesPerRow, image.width) }
        }
        return data
    }
}

nonisolated struct LayerFilterStackRecord: Codable, Sendable {
    var sourceFile: String
    var nodeFiles: [String]
    init(layerID: UUID, stack: LayerFilterStack) {
        sourceFile = "\(layerID.uuidString).source.png"
        nodeFiles = stack.nodes.map { "\(layerID.uuidString).\($0.id.uuidString).filter.json" }
    }
    func isValid(layerID: UUID) -> Bool {
        sourceFile == "\(layerID.uuidString).source.png" && nodeFiles.count <= 32 && Set(nodeFiles).count == nodeFiles.count
            && nodeFiles.allSatisfy { file in
                let prefix = layerID.uuidString + ".", suffix = ".filter.json"
                guard file.hasPrefix(prefix), file.hasSuffix(suffix) else { return false }
                return UUID(uuidString: String(file.dropFirst(prefix.count).dropLast(suffix.count))).map { file == prefix + $0.uuidString + suffix } ?? false
            }
    }
}

@MainActor @Observable final class FilterStackWorkspace {
    let owner: EditOwner
    let layer: ImageLayer
    let initial: LayerFilterStack
    let selectionCoverage: Data?
    var stack: LayerFilterStack
    var selectedID: UUID?
    var preview: CGImage?
    var error: String?
    var busy = false
    var previewNodes: [EditableFilterNode]
    @ObservationIgnored var renderTask: Task<CGImage, Error>?
    init(owner: EditOwner, layer: ImageLayer, coverage: Data?) {
        let original = layer.filterStack ?? LayerFilterStack(source: layer.asset!, nodes: [])
        self.owner = owner; self.layer = layer; selectionCoverage = coverage
        initial = original; stack = original; preview = layer.asset?.image
        selectedID = original.nodes.first?.id; previewNodes = original.nodes
    }
}

extension EditorSession {
    static func fitsFilterResources(_ layers: [ImageLayer]) -> Bool {
        var pixels = 0, masks = 0, bytes = 0
        for layer in layers {
            for asset in [layer.asset, layer.filterStack?.source].compactMap({ $0 }) {
                pixels += asset.image.width * asset.image.height
            }
            masks += layer.mask.map { $0.asset.image.width * $0.asset.image.height } ?? 0
            bytes += layer.filterStack?.retainedBytes ?? 0
            if pixels > DocumentLimits.documentPixelBudget || masks > DocumentLimits.documentPixelBudget
                || bytes > 256 * 1024 * 1024 { return false }
        }
        return true
    }
    var canEditFilterStack: Bool {
        canEditLayers && effectsEditing == nil && !history.hasPendingEdit && selectedLayerIDs.count == 1 && !isMaskSelected
            && activeLayer?.asset != nil && activeLayer?.isGroup == false && activeLayer?.adjustment == nil
            && activeLayer?.text == nil && activeLayer?.shape == nil && activeLayer?.fill == nil
            && !effectiveLocks(for: activeLayerID ?? UUID()).contains(.transparency)
            && allowsLayerEdit(activeLayerID, .content)
    }
    func beginFilterStack() {
        guard canEditFilterStack, let layer = activeLayer, let document, activeEditOwner == nil else { return }
        do {
            let coverage = try LayerFilterStack.coverage(selection?.clip(canvas: document.size), layer: layer)
            let owner = EditOwner(documentID: document.id, revision: history.currentRevision)
            activeEditOwner = owner
            filterStackEdit = FilterStackWorkspace(owner: owner, layer: layer, coverage: coverage)
        } catch { brushError = error.localizedDescription }
    }
    func cancelFilterStack() {
        guard let edit = filterStackEdit else { return }
        edit.renderTask?.cancel()
        filterStackEdit = nil; releaseEdit(edit.owner)
    }
    func renderFilterStack(commit: Bool) async {
        guard let edit = filterStackEdit, !edit.busy, ownsEdit(edit.owner) else { return }
        if commit && edit.stack == edit.initial { cancelFilterStack(); return }
        let stack = edit.stack
        edit.busy = true; edit.error = nil; isProjectBusy = true
        defer { if filterStackEdit === edit { edit.busy = false; isProjectBusy = false } }
        do {
            let task = Task.detached(priority: .userInitiated) { try stack.render() }
            edit.renderTask = task
            let image = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled, filterStackEdit === edit, ownsEdit(edit.owner),
                  let index = document?.layers.firstIndex(where: { $0.id == edit.layer.id }), document?.layers[index] == edit.layer,
                  allowsLayerEdit(edit.layer.id, .content), !effectiveLocks(for: edit.layer.id).contains(.transparency) else { throw EditRefusal.stale }
            edit.preview = image
            edit.previewNodes = stack.nodes
            guard commit else { return }
            let asset = ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: edit.layer.name)
            var candidate = document!
            candidate.layers[index].asset = asset
            candidate.layers[index].filterStack = stack.nodes.isEmpty ? nil : stack
            try await ProjectStore.shared.validateSnapshot(Self.snapshot(for: candidate, activeLayerID: activeLayerID))
            guard filterStackEdit === edit, ownsEdit(edit.owner), document?.layers[index] == edit.layer,
                  allowsLayerEdit(edit.layer.id, .content), !effectiveLocks(for: edit.layer.id).contains(.transparency) else { throw EditRefusal.stale }
            beginEdit("Edit Filter Stack"); document = candidate; endEdit()
            cancelFilterStack()
        } catch { if filterStackEdit === edit { edit.error = error.localizedDescription } }
    }
    static func snapshot(for document: CanvasDocument, activeLayerID: UUID?) -> ProjectSnapshot {
        let session = EditorSession(); session.document = document; session.activeLayerID = activeLayerID
        return session.projectSnapshot()!
    }
    func rasterizeFilterStack() {
        guard canEditFilterStack, let id = activeLayerID, let index = document?.layers.firstIndex(where: { $0.id == id }),
              document?.layers[index].filterStack != nil else { return }
        beginEdit("Rasterize Filter Stack"); document?.layers[index].filterStack = nil; endEdit()
    }
}
