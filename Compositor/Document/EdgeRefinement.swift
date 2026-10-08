import AppKit
import CoreImage
import Observation

nonisolated enum EdgeBrushMode: String, CaseIterable, Sendable {
    case refine = "Refine Edge", reveal = "Reveal", hide = "Hide"
}
nonisolated enum EdgeBackground: String, CaseIterable, Sendable {
    case checker = "Checkerboard", black = "Black", white = "White", mask = "Mask"
}

@Observable final class EdgeRefinement: Identifiable {
    let id = UUID()
    let owner: EditOwner
    let layer: ImageLayer
    let source: CGImage
    let width: Int, height: Int
    let previewSource: CGImage
    var levels: [Float]
    private var past: [[Float]] = []
    private var future: [[Float]] = []
    var mode: EdgeBrushMode = .refine
    var background: EdgeBackground = .checker
    var diameter: Double = 50
    var strength: Double = 0.6
    var feather: Double = 0
    var shift: Double = 0
    var contrast: Double = 0
    var decontaminate: Double = 0
    var createsCopy = true
    var isApplying = false
    var isPainting = false
    var zoom: Double = 1
    var pan: CGSize = .zero
    private var revision: UInt64 = 0
    @ObservationIgnored private var previewCache: (key: [Double], image: CGImage)?
    private var lastPoint: CGPoint?
    private let guide: [Float]
    private var guided: [Float] = []
    var canUndo: Bool { !past.isEmpty && !isPainting && !isApplying }
    var canRedo: Bool { !future.isEmpty && !isPainting && !isApplying }
    init(owner: EditOwner, layer: ImageLayer, selection: SelectionClip?) throws {
        guard let image = layer.asset?.image else { throw ProjectError.invalid }
        self.owner = owner; self.layer = layer; source = image
        let scale = min(1, 1536 / CGFloat(max(image.width, image.height)))
        width = max(1, Int(CGFloat(image.width) * scale)); height = max(1, Int(CGFloat(image.height) * scale))
        let preview = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: preview)
        guard let small = preview.makeImage() else { throw ExportError.render }; previewSource = small
        let coverage = try BrushRaster.context(width: width, height: height, mask: true)
        coverage.setFillColor(gray: 1, alpha: 1); coverage.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let mask = layer.mask?.clipImage(placement: layer.mask?.placement, over: layer.transform, width: width, height: height) {
            BrushRaster.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height), mask: true, context: coverage)
        } else if let selection {
            coverage.clear(CGRect(x: 0, y: 0, width: width, height: height))
            coverage.concatenate(BrushRaster.pixelToDocument(layer.transform, width: width, height: height).inverted())
            selection.apply(to: coverage); coverage.setFillColor(gray: 1, alpha: 1); coverage.fill(selection.rect)
        }
        guard let initial = coverage.makeImage() else { throw ExportError.render }
        levels = try GuidedMatte.levels(of: initial, width: width, height: height)
        guard let rgba = preview.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
        let guideWidth = width, guideHeight = height
        guide = (0..<(guideWidth * guideHeight)).map { i in
            let p = rgba + (i / guideWidth) * preview.bytesPerRow + (i % guideWidth) * 4
            return p[3] == 0 ? 0 : (Float(p[0]) * 0.2126 + Float(p[1]) * 0.7152 + Float(p[2]) * 0.0722) / Float(p[3])
        }
    }
    func beginStroke() {
        guard !isPainting, !isApplying else { return }
        past.append(levels); future.removeAll(); trim(); isPainting = true; lastPoint = nil
        if mode == .refine { guided = GuidedMatte.filter(mask: levels, guide: guide, width: width, height: height, radius: 8, epsilon: 0.001) }
    }
    private func trim() {
        let limit = max(1, min(32, 64 * 1024 * 1024 / max(1, levels.count * MemoryLayout<Float>.stride)))
        if past.count > limit { past.removeFirst(past.count - limit) }
    }
    func paint(at point: CGPoint) {
        guard isPainting, point.x.isFinite, point.y.isFinite else { return }
        guard point.x >= -10000, point.x <= Double(width) + 10000, point.y >= -10000, point.y <= Double(height) + 10000 else { return }
        let radius = max(1, ImageAdjustmentPixels.clamp(diameter, 1...30000, 50) / 2 * Double(width) / Double(source.width))
        let old = lastPoint ?? point
        let steps = max(1, Int(ceil(hypot(point.x - old.x, point.y - old.y) / max(1, radius / 3))))
        for step in 1...min(steps, 1000) {
            let t = Double(step) / Double(steps)
            let center = CGPoint(x: old.x + (point.x - old.x) * t, y: old.y + (point.y - old.y) * t)
            let left = max(0, Int(floor(center.x - radius))), right = min(width - 1, Int(ceil(center.x + radius)))
            let top = max(0, Int(floor(center.y - radius))), bottom = min(height - 1, Int(ceil(center.y + radius)))
            guard left <= right, top <= bottom else { continue }
            for y in top...bottom { for x in left...right {
                let distance = hypot(Double(x) + 0.5 - center.x, Double(y) + 0.5 - center.y) / radius
                guard distance < 1 else { continue }
                let index = y * width + x, amount = Float((1 - distance) * ImageAdjustmentPixels.clamp(strength, 0...1, 0.6))
                let target: Float
                if mode == .refine {
                    target = min(1, max(0, guided[index]))
                } else { target = mode == .reveal ? 1 : 0 }
                levels[index] += (target - levels[index]) * amount
            } }
        }
        lastPoint = point
        revision &+= 1
    }
    func endStroke() { isPainting = false; lastPoint = nil }
    func undo() { guard canUndo, let value = past.popLast() else { return }; future.append(levels); levels = value; revision &+= 1 }
    func redo() { guard canRedo, let value = future.popLast() else { return }; past.append(levels); levels = value; trim(); revision &+= 1 }
    func replaceMask(_ mask: CGImage) throws {
        guard !isApplying, !isPainting else { return }
        past.append(levels); future.removeAll(); levels = try GuidedMatte.levels(of: mask, width: width, height: height); trim(); revision &+= 1
    }
    var previewImage: CGImage? {
        let key = [Double(revision), feather, shift, contrast, decontaminate, background == .mask ? 1 : 0]
        if let cached = previewCache, cached.key == key { return cached.image }
        guard let mask = try? EdgeRefinement.renderMask(levels, width: width, height: height, feather: feather * Double(width) / Double(source.width), shift: shift * Double(width) / Double(source.width), contrast: contrast),
              let context = try? BrushRaster.context(width: width, height: height, mask: false) else { return nil }
        if background == .mask { BrushRaster.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context) }
        else {
            guard let cleaned = try? EdgeColorDecontamination.apply(previewSource, mask: mask,
                amount: ImageAdjustmentPixels.clamp(decontaminate, 0...100, 0) / 100) else { return nil }
            context.saveGState(); context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
            context.clip(to: CGRect(x: 0, y: 0, width: width, height: height), mask: mask)
            context.draw(cleaned, in: CGRect(x: 0, y: 0, width: width, height: height)); context.restoreGState()
        }
        guard let image = context.makeImage() else { return nil }
        previewCache = (key, image)
        return image
    }
    nonisolated static func renderMask(_ levels: [Float], width: Int, height: Int, feather: Double, shift: Double, contrast: Double) throws -> CGImage {
        guard width > 0, height > 0, width * height <= 1536 * 1536, levels.count == width * height,
              levels.allSatisfy({ $0.isFinite && (0...1).contains($0) }), feather.isFinite, shift.isFinite, contrast.isFinite else { throw ProjectError.invalid }
        let mask = try GuidedMatte.image(levels, width: width, height: height)
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        var image = CIImage(cgImage: mask)
        if abs(shift) > 0.01 { image = image.applyingFilter(shift > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum", parameters: [kCIInputRadiusKey: min(100, abs(shift))]) }
        if feather > 0.01 { image = image.clampedToExtent().applyingGaussianBlur(sigma: min(100, feather) / 2).cropped(to: extent) }
        if contrast > 0 { image = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + min(100, contrast) / 25]) }
        return try PixelAdjust.render(image.cropped(to: extent), width: width, height: height, isMask: true)
    }
}

extension EditorSession {
    var canRefineEdges: Bool { canEditLayers && !isProjectBusy && activeLayer?.asset != nil && activeLayer?.isGroup == false && allowsLayerEdit(activeLayerID, .content) }
    func beginEdgeRefinement() {
        guard canRefineEdges, let layer = activeLayer, let document, let owner = beginOwnedEdit() else { return }
        do { edgeRefinement = try EdgeRefinement(owner: owner, layer: layer, selection: selection?.clip(canvas: document.size)) }
        catch { releaseEdit(owner); brushError = error.localizedDescription }
    }
    func cancelEdgeRefinement() {
        guard let edit = edgeRefinement, !edit.isApplying else { return }
        edgeRefinement = nil; releaseEdit(edit.owner)
    }
    func detectRefinementSubject() async {
        guard let edit = edgeRefinement, ownsEdit(edit.owner), !edit.isApplying else { return }
        edit.isApplying = true
        let image = edit.previewSource
        do {
            let mask = try await Task.detached(priority: .userInitiated) { try SubjectRemoval.subjectMask(image, under: nil, settings: FilterSettings()) }.value
            try Task.checkCancellation()
            edit.isApplying = false
            guard edgeRefinement === edit, ownsEdit(edit.owner) else { return }
            try edit.replaceMask(mask)
        } catch { edit.isApplying = false; brushError = error.localizedDescription }
    }
    func applyEdgeRefinement() async {
        guard let edit = edgeRefinement, ownsEdit(edit.owner), !edit.isApplying, !edit.isPainting,
              allowsLayerEdit(edit.layer.id, .content), let index = document?.layers.firstIndex(where: { $0.id == edit.layer.id }) else { return }
        let copy = edit.createsCopy || edit.decontaminate > 0
        guard !copy || (canInsertFillLayer && allowsLayerEdit(edit.layer.id, .appearance)) else { return }
        let additionalPixels = edit.source.width * edit.source.height * (copy ? 2 : edit.layer.mask == nil ? 1 : 0)
        guard additionalPixels <= DocumentLimits.documentPixelBudget - sourcePixelCount,
              [edit.feather, edit.shift, edit.contrast, edit.decontaminate].allSatisfy(\.isFinite) else {
            brushError = ProjectError.tooLarge.localizedDescription; return
        }
        edit.isApplying = true
        let levels = edit.levels, width = edit.width, height = edit.height
        let source = edit.source, feather = edit.feather, shift = edit.shift, contrast = edit.contrast, decontaminate = edit.decontaminate
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let small = try EdgeRefinement.renderMask(levels, width: width, height: height,
                    feather: feather * Double(width) / Double(source.width), shift: shift * Double(width) / Double(source.width), contrast: contrast)
                let context = try BrushRaster.context(width: source.width, height: source.height, mask: true)
                context.interpolationQuality = .high
                context.saveGState(); context.translateBy(x: 0, y: CGFloat(source.height)); context.scaleBy(x: 1, y: -1)
                context.draw(small, in: CGRect(x: 0, y: 0, width: source.width, height: source.height)); context.restoreGState()
                guard let mask = context.makeImage() else { throw ExportError.render }
                let cleaned = try EdgeColorDecontamination.apply(source, mask: mask, amount: decontaminate / 100)
                return (try LayerMask.asset(from: mask), cleaned, try PixelInvert.thumbnail(of: cleaned))
            }.value
            try Task.checkCancellation()
            guard edgeRefinement === edit, ownsEdit(edit.owner), allowsLayerEdit(edit.layer.id, .content) else { edit.isApplying = false; return }
            beginEdit("Refine Layer Edges")
            if copy {
                let layer = ImageLayer(id: UUID(), asset: ImportedImage(image: result.1, thumbnail: result.2, name: edit.layer.name),
                    name: L10n.format("%@ — Refined", edit.layer.name), isVisible: true, transform: edit.layer.transform,
                    parentID: edit.layer.parentID, opacity: edit.layer.opacity, blendMode: edit.layer.blendMode,
                    mask: LayerMask(asset: result.0), maskSourceID: edit.layer.maskSourceID,
                    shape: decontaminate == 0 ? edit.layer.shape : nil, effects: edit.layer.effects,
                    text: decontaminate == 0 ? edit.layer.text : nil, fill: decontaminate == 0 ? edit.layer.fill : nil)
                document?.layers.insert(layer, at: index + 1); document?.layers[index].isVisible = false; activeLayerID = layer.id
            } else { document?.layers[index].mask = LayerMask(asset: result.0) }
            endEdit(); edit.isApplying = false; edgeRefinement = nil; releaseEdit(edit.owner)
        } catch { edit.isApplying = false; brushError = error.localizedDescription }
    }
}

nonisolated enum EdgeColorDecontamination {
    static func apply(_ image: CGImage, mask: CGImage, amount: Double) throws -> CGImage {
        guard amount.isFinite, (0...1).contains(amount) else { throw ProjectError.invalid }
        guard amount > 0 else { return image }
        let levels = try GuidedMatte.levels(of: mask, width: image.width, height: image.height)
        let source = try BrushRaster.copy(image)
        guard let raw = source.data else { throw ExportError.render }
        let input = raw.assumingMemoryBound(to: UInt8.self), stride = source.bytesPerRow
        return try ImageAdjustmentPixels.run(image) { output, width, height, row in
            for y in 0..<height { for x in 0..<width {
                let coverage = levels[y * width + x]; guard coverage > 0.01, coverage < 0.98 else { continue }
                let target = output + y * row + x * 4; guard target[3] > 0 else { continue }
                search: for radius in [1, 2, 4, 8, 16] {
                    for (dx, dy) in [(-radius,0),(radius,0),(0,-radius),(0,radius),(-radius,-radius),(radius,radius),(-radius,radius),(radius,-radius)] {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < width, ny < height, levels[ny * width + nx] > 0.98 else { continue }
                        let p = input + ny * stride + nx * 4; guard p[3] > 0 else { continue }
                        let blend = min(1, amount) * Double(1 - coverage)
                        for c in 0..<3 { target[c] = UInt8(max(0, min(Double(target[3]), (Double(target[c]) * (1 - blend) + Double(p[c]) / Double(p[3]) * Double(target[3]) * blend).rounded()))) }
                        break search
                    }
                }
            } }
        }
    }
}
