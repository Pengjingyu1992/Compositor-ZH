import AppKit

nonisolated struct FillColor: Codable, Equatable, Sendable {
    var red: Double = 1
    var green: Double = 0.35
    var blue: Double = 0.65
    var alpha: Double = 1
    var isValid: Bool { [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

nonisolated struct FillStop: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var position: Double
    var color: FillColor
}

nonisolated enum FillKind: String, Codable, CaseIterable, Sendable {
    case solid = "Solid Color", linear = "Linear", radial = "Radial", pattern = "Pattern"
}

nonisolated enum FillPattern: String, Codable, CaseIterable, Sendable {
    case checker = "Checkerboard", stripes = "Stripes", dots = "Dots"
}

/// Shared by fill layers and overlays. Coordinates and sizes are local layer pixels.
nonisolated struct LayerFillStyle: Codable, Equatable, Sendable {
    var kind: FillKind = .solid
    var stops = [FillStop(position: 0, color: FillColor()),
                 FillStop(position: 1, color: FillColor(red: 1, green: 0.9, blue: 0.6))]
    var angle: Double = 90
    var scale: Double = 1
    var reversed = false
    var pattern: FillPattern = .checker
    var cellSize: Double = 32
    var isValid: Bool {
        (2...32).contains(stops.count) && Set(stops.map(\.id)).count == stops.count
        && stops.allSatisfy { $0.position.isFinite && (0...1).contains($0.position) && $0.color.isValid }
        && zip(stops, stops.dropFirst()).allSatisfy { $0.position <= $1.position }
        && angle.isFinite && (-180...180).contains(angle) && scale.isFinite && (0.01...10).contains(scale)
        && cellSize.isFinite && (4...512).contains(cellSize)
    }

    func render(width: Int, height: Int) throws -> CGImage {
        guard isValid, width > 0, height > 0, width <= DocumentLimits.maxSide,
              height <= DocumentLimits.maxSide, width * height <= DocumentLimits.maxSurfacePixels else { throw ProjectError.invalid }
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if kind == .solid {
            context.setFillColor(stops[0].color.cgColor); context.fill(bounds)
        } else if kind == .pattern {
            let logicalSide = max(0.04, cellSize * scale)
            let side = max(1, min(256, Int(ceil(logicalSide)))), tileSide = side * 2
            let tile = try BrushRaster.context(width: tileSide, height: tileSide, mask: false)
            tile.setFillColor(stops[1].color.cgColor); tile.fill(CGRect(x: 0, y: 0, width: tileSide, height: tileSide))
            tile.setFillColor(stops[0].color.cgColor)
            switch pattern {
            case .checker:
                tile.fill(CGRect(x: 0, y: 0, width: side, height: side)); tile.fill(CGRect(x: side, y: side, width: side, height: side))
            case .stripes: tile.fill(CGRect(x: 0, y: 0, width: side, height: tileSide))
            case .dots: tile.fillEllipse(in: CGRect(x: side / 2, y: side / 2, width: side, height: side))
            }
            guard let image = tile.makeImage() else { throw ExportError.render }
            context.translateBy(x: bounds.midX, y: bounds.midY); context.rotate(by: angle * .pi / 180)
            let extent = hypot(bounds.width, bounds.height)
            context.draw(image, in: CGRect(x: -extent, y: -extent, width: CGFloat(logicalSide * 2), height: CGFloat(logicalSide * 2)), byTiling: true)
        } else {
            let ordered = reversed ? stops.reversed().map { FillStop(position: 1 - $0.position, color: $0.color) } : stops
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: ordered.map { $0.color.cgColor } as CFArray, locations: ordered.map { CGFloat($0.position) }) else { throw ExportError.render }
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            if kind == .radial {
                context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                    endRadius: max(bounds.width, bounds.height) * scale / 2, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            } else {
                let radians = angle * .pi / 180
                let radius = (abs(cos(radians)) * bounds.width + abs(sin(radians)) * bounds.height) * scale / 2
                let offset = CGPoint(x: cos(radians) * radius, y: sin(radians) * radius)
                context.drawLinearGradient(gradient, start: CGPoint(x: center.x - offset.x, y: center.y - offset.y),
                    end: CGPoint(x: center.x + offset.x, y: center.y + offset.y), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        }
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }
}

nonisolated struct LayerFill: Equatable, @unchecked Sendable {
    var style: LayerFillStyle
    let image: CGImage
    static func loaded(_ style: LayerFillStyle?, image: CGImage?) -> LayerFill? {
        guard let style, let image else { return nil }; return LayerFill(style: style, image: image)
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.style == rhs.style && lhs.image === rhs.image }
}

extension ImageLayer {
    var liveFill: LayerFill? {
        guard let fill, fill.image === asset?.image else { return nil }
        return fill
    }
}

struct FillLayerDraft: Identifiable {
    let id = UUID()
    let owner: EditOwner
    let layerID: UUID?
    var style: LayerFillStyle
}

extension EditorSession {
    var sourcePixelCount: Int {
        document?.layers.reduce(0) { total, layer in
            total + (layer.asset.map { $0.image.width * $0.image.height } ?? 0)
                + (layer.mask.map { $0.asset.image.width * $0.asset.image.height } ?? 0)
        } ?? 0
    }

    var canInsertFillLayer: Bool {
        let parent = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        return (document?.layers.count ?? 10_000) < 10_000 && (parent == nil || allowsLayerEdit(parent, .content))
    }

    func openFillLayer(editing: Bool = false) {
        guard canEditLayers, document != nil, editing || canInsertFillLayer else { return }
        if editing, (!allowsLayerEdit(activeLayerID, .content) || activeLayer?.liveFill == nil) { return }
        guard let owner = beginOwnedEdit() else { return }
        fillLayerDraft = FillLayerDraft(owner: owner, layerID: editing ? activeLayerID : nil,
            style: editing ? activeLayer!.liveFill!.style : LayerFillStyle())
    }

    func cancelFillLayer() {
        guard !fillLayerApplying, let draft = fillLayerDraft else { return }
        fillLayerDraft = nil
        releaseEdit(draft.owner)
    }

    func applyFillLayer(_ draft: FillLayerDraft) async {
        guard !fillLayerApplying, ownsEdit(draft.owner), let document,
              fillLayerDraft?.id == draft.id, draft.style.isValid else { return }
        let existing = draft.layerID.flatMap { id in document.layers.first(where: { $0.id == id }) }
        if let existing {
            guard allowsLayerEdit(existing.id, .content), let fill = existing.liveFill else { return }
            if fill.style == draft.style { cancelFillLayer(); return }
            // A fill color can change alpha. Require explicit unlocking before replacing it.
            guard !effectiveLocks(for: existing.id).contains(.transparency) else {
                brushError = L10n.text("Unlock transparency before editing this fill layer."); return
            }
        }
        let width = existing?.asset?.image.width ?? document.width
        let height = existing?.asset?.image.height ?? document.height
        guard width * height <= DocumentLimits.maxSurfacePixels,
              existing != nil || (canInsertFillLayer && width * height <= DocumentLimits.documentPixelBudget - sourcePixelCount) else {
            brushError = ProjectError.tooLarge.localizedDescription; return
        }
        fillLayerApplying = true
        defer { fillLayerApplying = false }
        do {
            let style = draft.style
            let result = try await Task.detached(priority: .userInitiated) {
                let image = try style.render(width: width, height: height)
                return (image, try PixelInvert.thumbnail(of: image))
            }.value
            try Task.checkCancellation()
            guard ownsEdit(draft.owner), fillLayerDraft?.id == draft.id else { return }
            if let id = draft.layerID {
                guard allowsLayerEdit(id, .content), let index = self.document?.layers.firstIndex(where: { $0.id == id }) else { return }
                beginEdit("Edit Fill Layer")
                self.document?.layers[index].asset = ImportedImage(image: result.0, thumbnail: result.1, name: document.layers[index].name)
                self.document?.layers[index].fill = LayerFill(style: style, image: result.0)
                endEdit()
            } else {
                guard canInsertFillLayer else { return }
                addPixelLayer(result.0, at: .zero, name: L10n.text("Fill Layer"), editName: "New Fill Layer",
                    dropsSelection: false, fill: LayerFill(style: style, image: result.0))
            }
            fillLayerDraft = nil; releaseEdit(draft.owner)
        } catch { brushError = error.localizedDescription }
    }
}
