import AppKit
import CoreText

nonisolated struct TextPathLayout: Codable, Equatable, Sendable {
    var path: VectorPathStyle
    var offset: CGFloat = 0
    var reversed = false
    var isValid: Bool {
        path.isValid && path.contours.count == 1 && path.contours[0].anchors.count >= 2
        && path.contours[0].anchors.count <= 3000 && offset.isFinite && abs(offset) <= 30_000
    }
}

nonisolated struct TextWarp: Codable, Equatable, Sendable {
    /// Arc height as a fraction of the text box height, positive bends upwards.
    var bend: CGFloat = 0
    var isValid: Bool { bend.isFinite && (-1...1).contains(bend) }
}

enum PathTypographyError: LocalizedError {
    case glyph, length, singleLine
    var errorDescription: String? {
        switch self {
        case .glyph: L10n.text("Some glyphs have no vector outline. The text layer was not changed.")
        case .length: L10n.text("The path is too short for this text. Reduce the font size or extend the path.")
        case .singleLine: L10n.text("Text on a path requires one horizontal line of text.")
        }
    }
}

private final class OutlineGlyphFonts: NSObject, NSLayoutManagerDelegate {
    var fonts: [Int: NSFont] = [:]
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        for i in glyphRange.location..<NSMaxRange(glyphRange) { fonts[i] = aFont }
        return 0
    }
}

/// Core Text supplies actual fallback fonts and UTF-16 run boundaries, including CJK and ligatures.
enum PathTypography {
    static func outlines(_ style: LayerTextStyle) throws -> VectorPathStyle {
        let size = EditorSession.textBoxSize(style), string = EditorSession.attributedText(style)
        var anchorCount = 0
        var vector = VectorPathStyle()
        func append(_ run: CTRun, baseline: CGPoint, along: ((CGPoint, CGFloat) throws -> CGAffineTransform)? = nil) throws {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let rawFont = attributes[kCTFontAttributeName] else { throw PathTypographyError.glyph }
            let font = rawFont as! CTFont
            let nsColor = attributes[kCTForegroundColorAttributeName] as? NSColor
            let paint = nsColor.flatMap(PaletteColor.init) ?? PaletteColor(red: style.red, green: style.green, blue: style.blue)
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            for i in 0..<count {
                guard let path = CTFontCreatePathForGlyph(font, glyphs[i], nil) else {
                    // Spaces have no ink; bitmap/color glyphs must not disappear during conversion.
                    let bounds = CTFontGetBoundingRectsForGlyphs(font, .default, [glyphs[i]], nil, 1)
                    if !bounds.isEmpty { throw PathTypographyError.glyph }
                    continue
                }
                var transform: CGAffineTransform
                if let along { transform = try along(positions[i], advances[i].width) }
                else {
                    transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                                  tx: baseline.x + positions[i].x, ty: size.height - baseline.y - positions[i].y)
                    transform = CTRunGetTextMatrix(run).concatenating(transform)
                }
                guard let placed = path.copy(using: &transform) else { throw PathTypographyError.glyph }
                let contours = VectorPathStyle.from(placed, size:size,color:paint).contours
                anchorCount += contours.reduce(0) { $0 + $1.anchors.count }
                vector.contours += contours
                guard vector.contours.count <= 10_000,
                      anchorCount <= 40_000 else { throw ProjectError.tooLarge }
            }
        }
        if let layout = style.pathLayout {
            guard !style.isVertical, !style.content.contains(where: \.isNewline) else { throw PathTypographyError.singleLine }
            let samples = samples(layout.path, size: size, reversed: layout.reversed)
            guard samples.count >= 2 else { throw PathTypographyError.length }
            var lengths = [CGFloat](repeating: 0, count: samples.count)
            for i in 1..<samples.count { lengths[i] = lengths[i-1] + hypot(samples[i].x-samples[i-1].x, samples[i].y-samples[i-1].y) }
            let line = CTLineCreateWithAttributedString(string)
            let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let total = lengths.last ?? 0
            let align: CGFloat = style.alignment == .center ? (total-textWidth)/2 : style.alignment == .right ? total-textWidth : 0
            let offset = layout.offset + align
            guard offset >= 0, offset + textWidth <= total + 0.01 else { throw PathTypographyError.length }
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                try append(run, baseline: .zero) { position, advance in
                    let distance = min(total, max(0, offset + position.x + advance/2))
                    var lo = 1, hi = lengths.count-1
                    while lo < hi { let mid = (lo+hi)/2; if lengths[mid] < distance { lo = mid+1 } else { hi = mid } }
                    let i = lo, a = samples[i-1], b = samples[i]
                    let t = (distance-lengths[i-1])/max(0.00001, lengths[i]-lengths[i-1])
                    let angle = atan2(b.y-a.y, b.x-a.x), cs = cos(angle), sn = sin(angle)
                    return CGAffineTransform(a: cs, b: sn, c: sn, d: -cs,
                        tx: a.x+(b.x-a.x)*t-cs*advance/2+sn*position.y,
                        ty: a.y+(b.y-a.y)*t-sn*advance/2-cs*position.y)
                }
            }
        } else if !style.isVertical {
            let fonts = OutlineGlyphFonts(), storage = NSTextStorage(attributedString:string), layout = NSLayoutManager()
            let pad = LayerTextStyle.padding
            let container = NSTextContainer(size:CGSize(width:max(1,size.width-2*pad),height:max(1,size.height-2*pad)))
            container.lineFragmentPadding = 0; layout.delegate = fonts
            storage.addLayoutManager(layout); layout.addTextContainer(container)
            let range = layout.glyphRange(for:container)
            for i in range.location..<NSMaxRange(range) {
                let property = layout.propertyForGlyph(at:i)
                if property.contains(.controlCharacter) || property.contains(.null) { continue }
                guard let font = fonts.fonts[i] else { throw PathTypographyError.glyph }
                let ctFont = font as CTFont, glyph = CGGlyph(layout.glyph(at:i))
                guard let path = CTFontCreatePathForGlyph(ctFont,glyph,nil) else {
                    if !CTFontGetBoundingRectsForGlyphs(ctFont,.default,[glyph],nil,1).isEmpty { throw PathTypographyError.glyph }
                    continue
                }
                let fragment = layout.lineFragmentRect(forGlyphAt:i,effectiveRange:nil), position = layout.location(forGlyphAt:i)
                var transform = CGAffineTransform(a:1,b:0,c:0,d:-1,tx:pad+fragment.minX+position.x,ty:pad+fragment.minY+position.y)
                guard let placed = path.copy(using:&transform) else { throw PathTypographyError.glyph }
                let paint = style.color(at:layout.characterIndexForGlyph(at:i))
                let contours = VectorPathStyle.from(placed,size:size,color:paint).contours
                anchorCount += contours.reduce(0) { $0+$1.anchors.count }; vector.contours += contours
                guard anchorCount <= 40_000, vector.contours.count <= 10_000 else { throw ProjectError.tooLarge }
            }
        } else {
            let padding = LayerTextStyle.padding
            let framePath = CGPath(rect: CGRect(x: padding, y: padding, width: max(1, size.width-padding*2), height: max(1, size.height-padding*2)), transform: nil)
            let attrs = style.isVertical ? [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] as CFDictionary : nil
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(string), CFRange(location: 0, length: 0), framePath, attrs)
            let lines = CTFrameGetLines(frame) as! [CTLine]
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
            for (i, line) in lines.enumerated() {
                for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                    try append(run, baseline: CGPoint(x: padding+origins[i].x, y: padding+origins[i].y))
                }
            }
        }
        if let warp = style.warp, warp.bend != 0 {
            vector = vector.mapped { p in CGPoint(x: p.x, y: p.y - warp.bend * 4 * p.x * (1-p.x)) }
        }
        guard vector.isValid else { throw PathTypographyError.glyph }
        return vector
    }
    static func samples(_ vector: VectorPathStyle, size: CGSize, reversed: Bool) -> [CGPoint] {
        guard let contour = vector.contours.first, let first = contour.anchors.first else { return [] }
        var points = [CGPoint(x: first.point.x*size.width, y: first.point.y*size.height)]
        let anchors = contour.anchors + (contour.closed ? [first] : [])
        for pair in zip(anchors, anchors.dropFirst()) {
            let a = pair.0.point, b = pair.0.outgoing ?? a, d = pair.1.point, c = pair.1.incoming ?? d
            for step in 1...32 {
                let t = CGFloat(step)/32, u = 1-t
                let x = u*u*u*a.x + 3*u*u*t*b.x + 3*u*t*t*c.x + t*t*t*d.x
                let y = u*u*u*a.y + 3*u*u*t*b.y + 3*u*t*t*c.y + t*t*t*d.y
                points.append(CGPoint(x: x*size.width, y: y*size.height))
            }
        }
        return reversed ? points.reversed() : points
    }
    static func image(_ style: LayerTextStyle) throws -> CGImage {
        let size = EditorSession.textBoxSize(style), vector = try outlines(style)
        return try EditorSession.shapeImage(.path, size: size,
            color: PaletteColor(red: style.red, green: style.green, blue: style.blue), vector: vector)
    }
}

extension EditorSession {
    var canConvertTextToOutlines: Bool { canEditLayers && activeLayer?.liveText != nil && allowsLayerEdit(activeLayerID, .content) }
    func convertTextToOutlines() {
        guard canConvertTextToOutlines, let layer = activeLayer, let text = layer.liveText,
              let i = document?.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        do {
            let vector = try PathTypography.outlines(text.style)
            let size = CGSize(width: text.image.width, height: text.image.height)
            let color = PaletteColor(red: text.style.red, green: text.style.green, blue: text.style.blue)
            let image = try Self.shapeImage(.path, size: size, color: color, vector: vector)
            let asset = ImportedImage(image: image, thumbnail: try PixelInvert.thumbnail(of: image), name: layer.name)
            beginEdit("Convert Text to Outlines")
            document?.layers[i].asset = asset; document?.layers[i].text = nil
            document?.layers[i].shape = LayerShape(style: LayerShapeStyle(kind: .path, red: color.red,
                green: color.green, blue: color.blue, cornerRadius: 0, vector: vector), image: image)
            endEdit()
        } catch { brushError = error.localizedDescription }
    }
    func attachTextToPath() {
        guard canEditLayers, let document, let pathLayer = activeLayer, let vector = pathLayer.liveShape?.style.vector,
              let textLayer = document.layers.reversed().first(where: { selectedLayerIDs.contains($0.id) && $0.liveText != nil }),
              var style = textLayer.liveText?.style, allowsLayerEdit(textLayer.id, .content), allowsLayerEdit(textLayer.id, .position),
              let i = document.layers.firstIndex(where: { $0.id == textLayer.id }) else { return }
        let size = document.size
        let target = LayerTransform(origin: .zero, size: size)
        let toText = BrushRaster.pixelToDocument(target, width: 1, height: 1).inverted()
        let toDoc = BrushRaster.pixelToDocument(pathLayer.transform, width: 1, height: 1)
        style.pathLayout = TextPathLayout(path: vector.mapped { $0.applying(toDoc).applying(toText) })
        style.boxSize = size; style.warp = nil
        do {
            let oldPixels = textLayer.asset.map { $0.image.width*$0.image.height } ?? 0
            guard size.width*size.height <= CGFloat(DocumentLimits.documentPixelBudget-sourcePixelCount+oldPixels) else { throw ProjectError.tooLarge }
            let image = try Self.textImage(style)
            let asset = ImportedImage(image: image, thumbnail: try PixelInvert.thumbnail(of: image), name: textLayer.name)
            beginEdit("Text on Path")
            if textLayer.mask?.placement == nil { self.document?.layers[i].mask?.placement = textLayer.transform }
            self.document?.layers[i].transform = target
            self.document?.layers[i].asset = asset; self.document?.layers[i].text = LayerText(style: style, image: image)
            endEdit()
        } catch { brushError = error.localizedDescription }
    }
    func removeTextPath() {
        guard canConvertTextToOutlines, var style = activeLayer?.liveText?.style,
              let i = document?.layers.firstIndex(where: { $0.id == activeLayerID }) else { return }
        style.pathLayout = nil; style.warp = nil
        replacePathText(style, at: i)
    }
    func replacePathText(_ style: LayerTextStyle, at i: Int) {
        do {
            let image = try Self.textImage(style)
            let asset = ImportedImage(image: image, thumbnail: try PixelInvert.thumbnail(of: image), name: document!.layers[i].name)
            beginEdit("Reset Text Layout"); document?.layers[i].asset = asset
            document?.layers[i].text = LayerText(style: style, image: image); endEdit()
        } catch { brushError = error.localizedDescription }
    }
}
