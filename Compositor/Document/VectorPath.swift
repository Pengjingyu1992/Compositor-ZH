import AppKit
import CoreText

/// Points and handles use the layer's unit rectangle, with y increasing downwards.
nonisolated struct PathAnchor: Codable, Equatable, Sendable {
    var point: CGPoint
    var incoming: CGPoint?
    var outgoing: CGPoint?
    var smooth = false
    var isValid: Bool {
        [point, incoming, outgoing].compactMap { $0 }.allSatisfy {
            $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1000 && abs($0.y) <= 1000
        }
    }
}

nonisolated struct VectorContour: Codable, Equatable, Sendable {
    var anchors: [PathAnchor]
    var closed = false
    /// Used by text outlines to retain different glyph colors.
    var color: PaletteColor?
}

nonisolated struct VectorPathStyle: Codable, Equatable, Sendable {
    var contours: [VectorContour] = []
    var evenOdd = false
    var fillEnabled = true
    var strokeEnabled = false
    var strokeColor = PaletteColor.black
    var strokeWidth: CGFloat = 2
    var roundCaps = false
    var isValid: Bool {
        !contours.isEmpty && contours.count <= 10_000
        && contours.reduce(0, { $0 + $1.anchors.count }) <= 40_000
        && contours.allSatisfy { !$0.anchors.isEmpty && $0.anchors.allSatisfy(\.isValid)
            && ($0.color.map(Self.validColor) ?? true) }
        && Self.validColor(strokeColor) && strokeWidth.isFinite && (0...5000).contains(strokeWidth)
    }
    static func validColor(_ c: PaletteColor) -> Bool {
        [c.red, c.green, c.blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
    func path(size: CGSize, contours chosen: [VectorContour]? = nil) -> CGPath {
        let path = CGMutablePath()
        func p(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * size.width, y: point.y * size.height) }
        for contour in chosen ?? contours {
            guard let first = contour.anchors.first else { continue }
            path.move(to: p(first.point))
            var previous = first
            for anchor in contour.anchors.dropFirst() {
                path.addCurve(to: p(anchor.point), control1: p(previous.outgoing ?? previous.point),
                              control2: p(anchor.incoming ?? anchor.point))
                previous = anchor
            }
            if contour.closed {
                path.addCurve(to: p(first.point), control1: p(previous.outgoing ?? previous.point),
                              control2: p(first.incoming ?? first.point))
                path.closeSubpath()
            }
        }
        return path
    }
    func draw(size: CGSize, color: PaletteColor, in context: CGContext) {
        if fillEnabled {
            // Adjacent contours with the same color share winding, including glyph counters.
            var groups: [(PaletteColor, [VectorContour])] = []
            for c in contours {
                let paint = c.color ?? color
                if groups.last?.0 == paint { groups[groups.count - 1].1.append(c) }
                else { groups.append((paint, [c])) }
            }
            for (paint, group) in groups {
                context.setFillColor(paint.nsColor.cgColor)
                context.addPath(path(size: size, contours: group))
                context.fillPath(using: evenOdd ? .evenOdd : .winding)
            }
        }
        if strokeEnabled && strokeWidth > 0 {
            context.setStrokeColor(strokeColor.nsColor.cgColor)
            context.setLineWidth(strokeWidth)
            context.setLineCap(roundCaps ? .round : .butt)
            context.setLineJoin(.round)
            context.addPath(path(size: size)); context.strokePath()
        }
    }
    /// Converts cubic/quadratic glyphs and imported paths to explicit cubic anchors.
    static func from(_ path: CGPath, size: CGSize, color: PaletteColor? = nil) -> VectorPathStyle {
        var result = VectorPathStyle(), current = VectorContour(anchors: [], color: color)
        func unit(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / size.width, y: p.y / size.height) }
        path.applyWithBlock { pointer in
            let e = pointer.pointee
            switch e.type {
            case .moveToPoint:
                if !current.anchors.isEmpty { result.contours.append(current) }
                current = VectorContour(anchors: [PathAnchor(point: unit(e.points[0]))], color: color)
            case .addLineToPoint: current.anchors.append(PathAnchor(point: unit(e.points[0])))
            case .addCurveToPoint:
                guard !current.anchors.isEmpty else { return }
                current.anchors[current.anchors.count - 1].outgoing = unit(e.points[0])
                current.anchors.append(PathAnchor(point: unit(e.points[2]), incoming: unit(e.points[1])))
            case .addQuadCurveToPoint:
                guard let last = current.anchors.last else { return }
                let c = unit(e.points[0]), end = unit(e.points[1])
                current.anchors[current.anchors.count - 1].outgoing = CGPoint(x: last.point.x + (c.x - last.point.x) * 2/3,
                                                                             y: last.point.y + (c.y - last.point.y) * 2/3)
                current.anchors.append(PathAnchor(point: end, incoming: CGPoint(x: end.x + (c.x - end.x) * 2/3,
                                                                               y: end.y + (c.y - end.y) * 2/3)))
            case .closeSubpath:
                current.closed = true
                if current.anchors.count > 1, current.anchors.last?.point == current.anchors.first?.point {
                    current.anchors[0].incoming = current.anchors.last?.incoming
                    current.anchors.removeLast()
                }
                if !current.anchors.isEmpty { result.contours.append(current) }
                current = VectorContour(anchors: [], color: color)
            @unknown default: break
            }
        }
        if !current.anchors.isEmpty { result.contours.append(current) }
        return result
    }
    func mapped(_ map: (CGPoint) -> CGPoint) -> Self {
        var result = self
        for c in result.contours.indices {
            for a in result.contours[c].anchors.indices {
                result.contours[c].anchors[a].point = map(result.contours[c].anchors[a].point)
                result.contours[c].anchors[a].incoming = result.contours[c].anchors[a].incoming.map(map)
                result.contours[c].anchors[a].outgoing = result.contours[c].anchors[a].outgoing.map(map)
            }
        }
        return result
    }
}

struct PathEditing {
    let documentID: UUID
    let revision: UUID
    let layerID: UUID?
    var transform: LayerTransform
    var style: VectorPathStyle
    var color: PaletteColor
    var contour = 0
    var anchor: Int?
    /// 0 anchor, 1 incoming, 2 outgoing, 3 a newly dragged symmetric handle.
    var dragPart: Int?
    var adding = false
    var mask = false
}

extension EditorSession {
    func beginPathEditing(new: Bool = false) {
        guard canEditLayers, let document else { return }
        if !new, let layer = activeLayer, let vector = layer.liveShape?.style.vector {
            guard allowsLayerEdit(layer.id, .content) else { return }
            pathEditing = PathEditing(documentID: document.id, revision: history.currentRevision, layerID: layer.id,
                                      transform: layer.transform, style: vector, color: layer.liveShape!.style.color)
        } else {
            guard canInsertFillLayer else { return }
            pathEditing = PathEditing(documentID: document.id, revision: history.currentRevision, layerID: nil,
                                      transform: LayerTransform(origin: .zero, size: document.size),
                                      style: VectorPathStyle(), color: foregroundColor, adding: true)
        }
    }
    func beginVectorMaskEditing() {
        guard canEditLayers, let document, let layer = activeLayer, let mask = layer.mask,
              let vector = mask.vector, allowsLayerEdit(layer.id, .content) else { return }
        pathEditing = PathEditing(documentID: document.id, revision: history.currentRevision, layerID: layer.id,
                                  transform: mask.placement ?? layer.transform, style: vector, color: .white, mask: true)
        tool = .pen
    }
    static func vectorMaskImage(_ vector: VectorPathStyle, size: CGSize) throws -> CGImage {
        guard vector.isValid, size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 && size.width <= DocumentLimits.maxSideExtent && size.height <= DocumentLimits.maxSideExtent && ceil(size.width) * ceil(size.height) <= CGFloat(DocumentLimits.maxSurfacePixels) else { throw ProjectError.tooLarge }
        let c = try BrushRaster.context(width: Int(ceil(size.width)), height: Int(ceil(size.height)), mask: true)
        c.setFillColor(gray: 0, alpha: 1); c.fill(CGRect(origin: .zero, size: size))
        c.addPath(vector.path(size: size)); c.setFillColor(gray: 1, alpha: 1)
        c.fillPath(using: vector.evenOdd ? .evenOdd : .winding)
        guard let image = c.makeImage() else { throw ExportError.render }; return image
    }
    func pathPoint(_ point: CGPoint, edit: PathEditing) -> CGPoint {
        point.applying(BrushRaster.pixelToDocument(edit.transform, width: 1, height: 1).inverted())
    }
    func pathMouseDown(_ point: CGPoint, option: Bool, double: Bool) {
        if pathEditing == nil { beginPathEditing() }
        guard var e = pathEditing, e.documentID == document?.id else { return }
        let local = pathPoint(point, edit: e)
        let mapping = BrushRaster.pixelToDocument(e.transform, width: 1, height: 1)
        let reach = 7 / viewport.pointsPerPixel
        for c in e.style.contours.indices {
            for a in e.style.contours[c].anchors.indices {
                let node = e.style.contours[c].anchors[a]
                let points = [node.point, node.incoming, node.outgoing]
                for part in 0..<3 {
                    guard part == 0 || (e.contour == c && e.anchor == a), let p = points[part] else { continue }
                    let dp = p.applying(mapping)
                    if hypot(point.x - dp.x, point.y - dp.y) <= reach {
                        let closing = e.adding && c == e.contour && a == 0 && e.style.contours[c].anchors.count >= 3
                        e.contour = c; e.anchor = a; e.dragPart = part
                        if closing {
                            e.style.contours[c].closed = true; e.adding = false; e.dragPart = nil
                        } else if option && part == 0 {
                            e.style.contours[c].anchors[a].incoming = nil
                            e.style.contours[c].anchors[a].outgoing = nil
                            e.style.contours[c].anchors[a].smooth = false
                        }
                        pathEditing = e; return
                    }
                }
            }
        }
        if e.adding {
            if e.style.contours.isEmpty { e.style.contours = [VectorContour(anchors: [])] }
            guard e.style.contours.reduce(0, { $0 + $1.anchors.count }) < 40_000 else { return }
            e.style.contours[e.contour].anchors.append(PathAnchor(point: local))
            e.anchor = e.style.contours[e.contour].anchors.count - 1; e.dragPart = 3
            if double { e.adding = false }
            pathEditing = e
        }
    }
    func dragPath(to point: CGPoint, option: Bool) {
        guard var e = pathEditing, let a = e.anchor, let part = e.dragPart else { return }
        var node = e.style.contours[e.contour].anchors[a]
        let local = pathPoint(point, edit: e)
        if part == 0 {
            let dx = local.x - node.point.x, dy = local.y - node.point.y
            node.incoming = node.incoming.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            node.outgoing = node.outgoing.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }; node.point = local
        } else {
            let mirror = CGPoint(x: node.point.x * 2 - local.x, y: node.point.y * 2 - local.y)
            if part == 1 { node.incoming = local; if !option { node.outgoing = mirror } }
            else { node.outgoing = local; if !option { node.incoming = mirror } }
            node.smooth = !option
        }
        e.style.contours[e.contour].anchors[a] = node; pathEditing = e
    }
    func removePathAnchor() {
        guard var e = pathEditing, let a = e.anchor else { return }
        e.style.contours[e.contour].anchors.remove(at: a)
        if e.style.contours[e.contour].anchors.isEmpty { e.style.contours.remove(at: e.contour); e.contour = 0 }
        e.anchor = nil; e.dragPart = nil; pathEditing = e
    }
    func finishPathEditing() {
        guard let e = pathEditing else { return }
        guard e.documentID == document?.id, e.revision == history.currentRevision else {
            pathEditing = nil; brushError = EditRefusal.stale.localizedDescription; return
        }
        var cleaned = e.style
        cleaned.contours.removeAll { $0.anchors.isEmpty }
        guard cleaned.isValid, cleaned.contours.contains(where: { $0.anchors.count >= 2 }) else { return }
        do {
            if e.mask, let id = e.layerID {
                let image = try Self.vectorMaskImage(cleaned, size: e.transform.size)
                let asset = try LayerMask.asset(from: image)
                pathEditing = nil
                guard allowsLayerEdit(id, .content), let i = document?.layers.firstIndex(where: { $0.id == id }),
                      let old = document?.layers[i].mask else { return }
                if cleaned == old.vector { return }
                beginEdit("Edit Vector Mask")
                document?.layers[i].mask = LayerMask(asset: asset, isEnabled: old.isEnabled,
                    placement: old.placement, isLinked: old.isLinked, vector: cleaned)
                endEdit(); return
            }
            var vector = cleaned, transform = e.transform
            let margin = vector.strokeEnabled ? ceil(vector.strokeWidth / 2 + 1) : 1
            let pathBounds = vector.path(size: transform.size).boundingBoxOfPath.insetBy(dx:-margin,dy:-margin).integral
            let originalBounds = CGRect(origin:.zero,size:transform.size)
            if e.layerID == nil || !originalBounds.contains(pathBounds) {
                var box = e.layerID == nil ? pathBounds : originalBounds.union(pathBounds).integral
                box.size.width = max(1, box.width); box.size.height = max(1, box.height)
                vector = vector.mapped { CGPoint(x: ($0.x * transform.size.width - box.minX) / box.width,
                                                y: ($0.y * transform.size.height - box.minY) / box.height) }
                let center = CGPoint(x:box.midX/transform.size.width,y:box.midY/transform.size.height)
                    .applying(BrushRaster.pixelToDocument(transform,width:1,height:1))
                transform.size = box.size
                transform.origin = CGPoint(x:center.x-box.width/2,y:center.y-box.height/2)
            }
            let oldPixels = e.layerID.flatMap { id in document?.layers.first { $0.id == id }?.asset }.map { $0.image.width*$0.image.height } ?? 0
            guard ceil(transform.size.width)*ceil(transform.size.height) <= CGFloat(DocumentLimits.documentPixelBudget-sourcePixelCount+oldPixels) else { throw ProjectError.tooLarge }
            let style = LayerShapeStyle(kind: .path, red: e.color.red, green: e.color.green, blue: e.color.blue,
                                        cornerRadius: 0, vector: vector)
            let image = try Self.shapeImage(.path, size: transform.size, color: e.color, vector: vector)
            let thumbnail = try PixelInvert.thumbnail(of: image)
            pathEditing = nil
            guard canEditLayers else { return }
            if let id = e.layerID {
                guard allowsLayerEdit(id, .content), let i = document?.layers.firstIndex(where: { $0.id == id }) else { return }
                guard transform == e.transform || allowsLayerEdit(id, .position) else { return }
                if document?.layers[i].shape?.style == style { return }
                let asset = ImportedImage(image: image, thumbnail: thumbnail, name: document?.layers[i].name ?? "Path")
                beginEdit("Edit Path")
                document?.layers[i].asset = asset
                document?.layers[i].shape = LayerShape(style: style, image: image)
                if transform != e.transform {
                    if document?.layers[i].mask?.placement == nil { document?.layers[i].mask?.placement = e.transform }
                    document?.layers[i].transform = transform
                }
                endEdit()
            } else {
                guard canInsertFillLayer else { return }
                addPixelLayer(image, at: transform.origin, name: L10n.text("Path"), editName: "New Path", dropsSelection: false,
                              shape: LayerShape(style: style, image: image))
            }
        } catch { brushError = error.localizedDescription }
    }
    func makeVectorMask() {
        guard let source = activeLayer, let vector = source.liveShape?.style.vector, let document, canEditLayers,
              let target = document.layers.prefix(while: { $0.id != source.id }).last,
              !target.isGroup, target.asset != nil, target.mask == nil,
              allowsLayerEdit(source.id, .appearance),
              allowsLayerEdit(target.id, .content) else { return }
        do {
            let mapped = vector.mapped { p in
                let doc = p.applying(BrushRaster.pixelToDocument(source.transform, width: 1, height: 1))
                return doc.applying(BrushRaster.pixelToDocument(target.transform, width: 1, height: 1).inverted())
            }
            guard ceil(target.size.width)*ceil(target.size.height) <= CGFloat(DocumentLimits.documentPixelBudget-sourcePixelCount) else { throw ProjectError.tooLarge }
            let image = try Self.vectorMaskImage(mapped, size: target.transform.size)
            guard let i = self.document?.layers.firstIndex(where: { $0.id == target.id }) else { return }
            let asset = try LayerMask.asset(from: image)
            beginEdit("Create Vector Mask")
            self.document?.layers[i].mask = LayerMask(asset: asset, vector: mapped)
            if let s = self.document?.layers.firstIndex(where: { $0.id == source.id }) { self.document?.layers[s].isVisible = false }
            activeLayerID = target.id; endEdit()
        } catch { brushError = error.localizedDescription }
    }
}
