import AppKit
import CoreText

/// Big-endian descriptors and vector knots from Adobe's public PSD specification.
nonisolated struct PSDBytes {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { u8(UInt8(v >> 8)); u8(UInt8(v & 255)) }
    mutating func u32(_ v: UInt32) { u16(UInt16(v >> 16)); u16(UInt16(v & 65535)) }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func f32(_ v: Double) { u32(Float(v).bitPattern) }
    mutating func f64(_ v: Double) { let b = v.bitPattern; u32(UInt32(b >> 32)); u32(UInt32(b & 0xffffffff)) }
    mutating func ascii(_ v: String) { data.append(contentsOf: v.utf8) }
    mutating func zeros(_ n: Int) { data.append(Data(repeating: 0, count: n)) }
    mutating func unicode(_ v: String) { u32(UInt32(v.utf16.count)); for c in v.utf16 { u16(c) } }
    mutating func id(_ v: String) { u32(v.utf8.count == 4 ? 0 : UInt32(v.utf8.count)); ascii(v) }
    mutating func descriptor(_ name: String, _ items: [(String, PSDValue)], versioned: Bool = true) {
        if versioned { u32(16) }; unicode(""); id(name); u32(UInt32(items.count))
        for (key, value) in items { id(key); value.write(to: &self) }
    }
}

nonisolated indirect enum PSDValue {
    case number(Double), unit(String, Double), integer(Int32), flag(Bool), text(String), bytes(Data)
    case enumeration(String, String), object(String, [(String, PSDValue)]), list([PSDValue])
    func write(to b: inout PSDBytes) {
        switch self {
        case .number(let v): b.ascii("doub"); b.f64(v)
        case .unit(let u, let v): b.ascii("UntF"); b.ascii(u); b.f64(v)
        case .integer(let v): b.ascii("long"); b.i32(v)
        case .flag(let v): b.ascii("bool"); b.u8(v ? 1 : 0)
        case .text(let v): b.ascii("TEXT"); b.unicode(v)
        case .bytes(let v): b.ascii("tdta"); b.u32(UInt32(v.count)); b.data.append(v)
        case .enumeration(let type, let v): b.ascii("enum"); b.id(type); b.id(v)
        case .object(let type, let v): b.ascii("Objc"); b.descriptor(type, v, versioned: false)
        case .list(let v): b.ascii("VlLs"); b.u32(UInt32(v.count)); for item in v { item.write(to: &b) }
        }
    }
    static func color(_ c: PaletteColor) -> PSDValue {
        .object("RGBC", [("Rd  ", .number(Double(c.red)*255)), ("Grn ", .number(Double(c.green)*255)), ("Bl  ", .number(Double(c.blue)*255))])
    }
}

nonisolated enum PSDEditableWriter {
    static func vector(_ path: VectorPathStyle, transform: LayerTransform, canvas: CGSize, enabled: Bool = true, linked: Bool = true) throws -> Data {
        guard path.isValid else { throw ProjectError.invalid }
        let mapping = BrushRaster.pixelToDocument(transform, width: 1, height: 1)
        var b = PSDBytes(); b.u32(3); b.u32((enabled ? 0 : 4) | (linked ? 0 : 2))
        b.u16(6); b.zeros(24); b.u16(8); b.u16(0); b.zeros(22)
        func point(_ point: CGPoint, into b: inout PSDBytes) throws {
            let p = point.applying(mapping)
            for value in [p.y/canvas.height, p.x/canvas.width] {
                guard value.isFinite, value >= -128, value < 128 else { throw PSDExportError.tooLarge }
                b.i32(Int32((value * 16777216).rounded()))
            }
        }
        for contour in path.contours {
            guard contour.anchors.count <= 65535 else { throw PSDExportError.tooLarge }
            b.u16(contour.closed ? 0 : 3); b.u16(UInt16(contour.anchors.count))
            b.u16(0xffff); b.u16(path.evenOdd ? 1 : 2); b.zeros(18)
            for node in contour.anchors {
                b.u16(contour.closed ? (node.smooth ? 1 : 2) : (node.smooth ? 4 : 5))
                try point(node.incoming ?? node.point, into: &b); try point(node.point, into: &b)
                try point(node.outgoing ?? node.point, into: &b)
            }
        }
        return b.data
    }
    static func solid(_ color: PaletteColor) -> Data {
        var b = PSDBytes(); b.descriptor("null", [("Clr ", .color(color))]); return b.data
    }
    static func gradient(_ fill: LayerFillStyle) -> [(String, PSDValue)] {
        let colors: [PSDValue] = fill.stops.map { stop in
            .object("Clrt", [("Clr ", .color(PaletteColor(red: stop.color.red, green: stop.color.green, blue: stop.color.blue))),
                ("Type", .enumeration("Clry", "UsrS")), ("Lctn", .integer(Int32((stop.position*4096).rounded()))), ("Mdpn", .integer(50))])
        }
        let alpha: [PSDValue] = fill.stops.map { stop in
            .object("TrnS", [("Opct", .unit("#Prc", stop.color.alpha*100)),
                ("Lctn", .integer(Int32((stop.position*4096).rounded()))), ("Mdpn", .integer(50))])
        }
        return [("Dthr", .flag(false)), ("Rvrs", .flag(fill.reversed)), ("Angl", .unit("#Ang", -fill.angle)),
            ("Type", .enumeration("GrdT", fill.kind == .radial ? "Rdl " : "Lnr ")), ("Algn", .flag(true)),
            ("Scl ", .unit("#Prc", fill.scale*100)),
            ("Grad", .object("Grdn", [("Nm  ", .text("Compositor Gradient")), ("GrdF", .enumeration("GrdF", "CstS")),
                ("Intr", .number(4096)), ("Clrs", .list(colors)), ("Trns", .list(alpha))]))]
    }
    static func fill(_ fill: LayerFillStyle, record: ProjectLayerRecord, canvas: CGSize) -> (String, Data)? {
        guard record.transform.rotation == 0, !record.transform.flipX, !record.transform.flipY else { return nil }
        if fill.kind == .solid, fill.stops[0].color.alpha == 1 {
            let c = fill.stops[0].color
            return ("SoCo", solid(PaletteColor(red: c.red, green: c.green, blue: c.blue)))
        }
        // PSD's aligned gradient uses the canvas rectangle. Other placements retain their pixel appearance.
        guard (fill.kind == .linear || fill.kind == .radial), record.transform.origin == .zero,
              record.transform.size == canvas else { return nil }
        var b = PSDBytes(); b.descriptor("null", gradient(fill)); return ("GdFl",b.data)
    }
    static func supportsEffects(_ effects: LayerEffects) -> Bool {
        effects.patternOverlay == nil && effects.bevel == nil
            && (effects.gradientOverlay.map { $0.fill.kind == .linear || $0.fill.kind == .radial } ?? true)
    }
    static func effects(_ effects: LayerEffects) -> Data {
        var items: [(String,PSDValue)] = [("masterFXSwitch",.flag(true)),("Scl ",.unit("#Prc",100))]
        func common(_ enabled: Bool, _ opacity: Double, _ color: PaletteColor) -> [(String,PSDValue)] {
            [("enab",.flag(enabled)),("present",.flag(true)),("showInDialog",.flag(true)),
             ("Md  ",.enumeration("BlnM","Nrml")),("Opct",.unit("#Prc",opacity*100)),("Clr ",.color(color))]
        }
        if let e = effects.colorOverlay { items.append(("SoFi",.object("SoFi",common(e.isEnabled,e.opacity,e.color)))) }
        if let e = effects.shadow {
            items.append(("DrSh",.object("DrSh",common(e.isEnabled,e.opacity,e.color)+[("uglg",.flag(false)),
                ("lagl",.unit("#Ang",Double(e.angle))),("Dstn",.unit("#Pxl",Double(e.distance))),
                ("Ckmt",.unit("#Pxl",0)),("blur",.unit("#Pxl",Double(e.blur))),
                ("Nose",.unit("#Prc",0)),("AntA",.flag(true)),("layerConceals",.flag(true))])))
        }
        if let e = effects.innerShadow {
            items.append(("IrSh",.object("IrSh",common(e.isEnabled,e.opacity,e.color)+[("uglg",.flag(false)),
                ("lagl",.unit("#Ang",Double(e.angle))),("Dstn",.unit("#Pxl",Double(e.distance))),
                ("Ckmt",.unit("#Pxl",0)),("blur",.unit("#Pxl",Double(e.blur))), ("Nose",.unit("#Prc",0)),("AntA",.flag(true))])))
        }
        if let e = effects.outerGlow {
            items.append(("OrGl",.object("OrGl",common(e.isEnabled,e.opacity,e.color)+[("GlwT",.enumeration("BETE","SfBL")),
                ("Ckmt",.unit("#Pxl",0)),("blur",.unit("#Pxl",Double(e.size))), ("Nose",.unit("#Prc",0)),
                ("ShdN",.unit("#Prc",0)),("Inpr",.unit("#Prc",50)),("AntA",.flag(true))])))
        }
        if let e = effects.innerGlow {
            items.append(("IrGl",.object("IrGl",common(e.isEnabled,e.opacity,e.color)+[("GlwT",.enumeration("BETE","SfBL")),
                ("glwS",.enumeration("IGSr","SrcE")),("Ckmt",.unit("#Pxl",0)),("blur",.unit("#Pxl",Double(e.size))),
                ("Nose",.unit("#Prc",0)),("ShdN",.unit("#Prc",0)),("Inpr",.unit("#Prc",50)),("AntA",.flag(true))])))
        }
        if let e = effects.stroke {
            items.append(("FrFX",.object("FrFX",common(e.isEnabled,e.opacity,e.color)+[("Styl",.enumeration("FStl",e.inside ? "InsF" : "OutF")),
                ("PntT",.enumeration("FrFl","SClr")),("Sz  ",.unit("#Pxl",Double(e.size)))])))
        }
        if let e = effects.gradientOverlay {
            items.append(("GrFl",.object("GrFl",[("enab",.flag(e.enabled ?? true)),("present",.flag(true)),("showInDialog",.flag(true)),
                ("Md  ",.enumeration("BlnM","Nrml")),("Opct",.unit("#Prc",e.opacity*100))]+gradient(e.fill))))
        }
        var b = PSDBytes(); b.u32(0); b.descriptor("null",items); return b.data
    }
    static func stroke(_ vector: VectorPathStyle) -> Data {
        var b = PSDBytes()
        b.descriptor("strokeStyle", [
            ("strokeStyleVersion", .integer(2)), ("strokeEnabled", .flag(vector.strokeEnabled)), ("fillEnabled", .flag(vector.fillEnabled)),
            ("strokeStyleLineWidth", .unit("#Pxl", Double(vector.strokeWidth))), ("strokeStyleLineDashOffset", .unit("#Pxl", 0)),
            ("strokeStyleMiterLimit", .number(10)), ("strokeStyleLineCapType", .enumeration("strokeStyleLineCapType", vector.roundCaps ? "strokeStyleRoundCap" : "strokeStyleButtCap")),
            ("strokeStyleLineJoinType", .enumeration("strokeStyleLineJoinType", "strokeStyleRoundJoin")),
            ("strokeStyleLineAlignment", .enumeration("strokeStyleLineAlignment", "strokeStyleAlignCenter")),
            ("strokeStyleScaleLock", .flag(false)), ("strokeStyleStrokeAdjust", .flag(false)),
            ("strokeStyleLineDashSet", .list([])), ("strokeStyleBlendMode", .enumeration("BlnM", "Nrml")),
            ("strokeStyleOpacity", .unit("#Prc", 100)), ("strokeStyleContent", .object("solidColorLayer", [("Clr ", .color(vector.strokeColor))])),
            ("strokeStyleResolution", .number(72))])
        return b.data
    }
    static func shapePath(_ style: LayerShapeStyle, size: CGSize) -> VectorPathStyle {
        if let vector = style.vector { return vector }
        if style.kind == .line {
            return VectorPathStyle(contours: [VectorContour(anchors: [PathAnchor(point: style.start ?? .zero), PathAnchor(point: style.end ?? CGPoint(x: 1, y: 1))])],
                fillEnabled: false, strokeEnabled: true, strokeColor: style.color, strokeWidth: style.lineWidth ?? 1, roundCaps: true)
        }
        return VectorPathStyle.from(style.kind.path(in: CGRect(origin: .zero, size: size), cornerRadius: style.cornerRadius), size: size)
    }
    static func canWriteText(_ record: ProjectLayerRecord, snapshot: ProjectSnapshot) -> Bool {
        guard let text = record.text, let image = snapshot.images[record.id]?.image else { return false }
        return text.pathLayout == nil && text.warp == nil && !text.isVertical
            && abs(record.transform.size.width/CGFloat(image.width) - record.transform.size.height/CGFloat(image.height)) < 0.00001
    }
    static func text(_ style: LayerTextStyle, transform: LayerTransform, image: CGImage) -> Data {
        let content = style.content.replacingOccurrences(of: "\n", with: "\r")
        let mapping = BrushRaster.pixelToDocument(transform, width: image.width, height: image.height)
        let baseline = style.boxSize == nil ? PSDText.baseline(style, image: CGSize(width: image.width, height: image.height)) : LayerTextStyle.padding
        let anchorX = style.boxSize != nil ? LayerTextStyle.padding : style.alignment == .center ? CGFloat(image.width)/2 : style.alignment == .right ? CGFloat(image.width)-LayerTextStyle.padding : LayerTextStyle.padding
        let origin = CGPoint(x: anchorX, y: baseline).applying(mapping)
        var b = PSDBytes(); b.u16(1)
        for v in [mapping.a, mapping.b, mapping.c, mapping.d, origin.x, origin.y] { b.f64(Double(v)) }
        b.u16(50)
        b.descriptor("TxLr", [("Txt ", .text(content)), ("textGridding", .enumeration("textGridding", "None")),
            ("Ornt", .enumeration("Ornt", "Hrzn")), ("AntA", .enumeration("Annt", "AnSm")),
            ("TextIndex", .integer(0)), ("EngineData", .bytes(engine(style, content: content)))])
        b.u16(1); b.descriptor("warp", [("warpStyle", .enumeration("warpStyle", "warpNone")),
            ("warpValue", .number(0)), ("warpPerspective", .number(0)), ("warpPerspectiveOther", .number(0)), ("warpRotate", .enumeration("Ornt", "Hrzn"))])
        for v in [0, 0, image.width, image.height] { b.f32(Double(v)) }
        return b.data
    }
    private static func engine(_ style: LayerTextStyle, content: String) -> Data {
        var data = Data()
        func s(_ value: String) { data.append(contentsOf: value.utf8) }
        func string(_ value: String) {
            s("("); data.append(contentsOf: [0xfe,0xff])
            for unit in value.utf16 { for byte in [UInt8(unit >> 8), UInt8(unit & 255)] {
                if [40,41,92].contains(byte) { data.append(92) }; data.append(byte)
            } }; s(")")
        }
        // Persist the actual fallback faces. Helvetica alone renders CJK through a
        // macOS fallback, but Photoshop cannot reconstruct that implicit choice.
        let line = CTLineCreateWithAttributedString(EditorSession.attributedText(style))
        let resolved = (CTLineGetGlyphRuns(line) as! [CTRun]).compactMap { run -> (NSRange, String)? in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName] else { return nil }
            let range = CTRunGetStringRange(run)
            return (NSRange(location: range.location, length: range.length), CTFontCopyPostScriptName(value as! CTFont) as String)
        }
        let fonts = [style.fontName] + Set(resolved.map { $0.1 }).subtracting([style.fontName]).sorted()
        let length = content.utf16.count + 1
        let boundaries = Array(Set([0, content.utf16.count] + (style.fontRuns ?? []).flatMap { [$0.location,$0.location+$0.length] }
            + (style.colorRuns ?? []).flatMap { [$0.location,$0.location+$0.length] }
            + resolved.flatMap { [$0.0.location, NSMaxRange($0.0)] })).sorted()
        var runs: [(Int, String, PaletteColor)] = []
        for (a,z) in zip(boundaries, boundaries.dropFirst()) where z > a {
            let name = resolved.first { NSLocationInRange(a, $0.0) }?.1 ?? style.fontName(at: a)
            runs.append((z-a,name,style.color(at: a)))
        }
        if runs.isEmpty { runs = [(0, style.fontName, style.color(at: 0))] }
        runs[runs.count-1].0 += 1
        let justify = style.alignment == .right ? 1 : style.alignment == .center ? 2 : style.alignment == .justified ? 6 : 0
        s("<< /EngineDict << /Editor << /Text "); string(content+"\r")
        s(" >> /ParagraphRun << /DefaultRunData << /ParagraphSheet << /DefaultStyleSheet 0 /Properties << /Justification \(justify) >> >> >> /RunArray [ << /ParagraphSheet << /DefaultStyleSheet 0 /Properties << /Justification \(justify) /AutoLeading 1.2 >> >> /Adjustments << /Axis [ 1 0 1 ] /XY [ 0 0 ] >> >> ] /RunLengthArray [ \(length) ] /IsJoinable 1 >> /StyleRun << /DefaultRunData << /StyleSheet << /StyleSheetData << /Font 0 /FontSize \(style.fontSize) >> >> >> /RunArray [ ")
        for (_,name,color) in runs {
            s("<< /StyleSheet << /StyleSheetData << /Font \(fonts.firstIndex(of:name) ?? 0) /FontSize \(style.fontSize) /FauxBold false /FauxItalic false /AutoLeading \(style.leading == 0 ? "true" : "false") /Leading \(style.lineHeight) /Tracking \(style.tracking/style.fontSize*1000) /HorizontalScale 1.0 /VerticalScale 1.0 /FillFlag true /StrokeFlag false /FillColor << /Type 1 /Values [ 1.0 \(color.red) \(color.green) \(color.blue) ] >> >> >> >> ")
        }
        s("] /RunLengthArray [ "); for (n,_,_) in runs { s("\(n) ") }
        s("] /IsJoinable 2 >> /AntiAlias 4 /UseFractionalGlyphWidths true /Rendered << /Version 1 /Shapes << /WritingDirection 0 /Children [ << /ShapeType \(style.boxSize == nil ? 0 : 1) /Procession 0 /Lines << /WritingDirection 0 /Children [] >> /Cookie << /Photoshop << \(style.boxSize.map { "/ShapeType 1 /BoxBounds [ 0 0 \($0.width-2*LayerTextStyle.padding) \($0.height-2*LayerTextStyle.padding) ]" } ?? "/ShapeType 0 /PointBase [ 0 0 ]") /Base << /ShapeType \(style.boxSize == nil ? 0 : 1) /TransformPoint0 [ 1 0 ] /TransformPoint1 [ 0 1 ] /TransformPoint2 [ 0 0 ] >> >> >> >> ] >> >> /GridInfo << /GridIsOn false /ShowGrid false /GridSize 18 /GridLeading 22 /GridColor << /Type 1 /Values [ 1.0 0.0 0.0 1.0 ] >> /GridLeadingFillColor << /Type 1 /Values [ 1.0 0.0 0.0 1.0 ] >> /AlignLineHeightToGridFlags false >> >> /ResourceDict << /KinsokuSet [] /MojiKumiSet [] /FontSet [ ")
        for name in fonts { s("<< /Name "); string(name); s(" /Script 0 /FontType 0 /Synthetic 0 >> ") }
        s("] /StyleSheetSet [ << /Name "); string("Normal"); s(" /StyleSheetData << /Font 0 /FontSize \(style.fontSize) >> >> ] /ParagraphSheetSet [ << /Name "); string("Normal"); s(" /DefaultStyleSheet 0 /Properties << /Justification \(justify) >> >> ] /TheNormalStyleSheet 0 /TheNormalParagraphSheet 0 /SuperscriptSize 0.583 /SuperscriptPosition 0.333 /SubscriptSize 0.583 /SubscriptPosition 0.333 /SmallCapSize 0.7 >> >>")
        return data
    }
    static func adjustment(_ a: LayerAdjustment) -> (String, Data)? {
        var b = PSDBytes()
        switch a.kind {
        case .invert: return ("nvrt", Data())
        case .levels:
            b.u16(2)
            for i in 0..<29 {
                let range = i < 4 ? a.levels.ranges[i] : LevelRange()
                for v in [range.black,range.white,range.outputBlack,range.outputWhite,range.gamma*100] { b.u16(UInt16(v.rounded())) }
            }
            return ("levl", b.data)
        case .curves:
            b.u8(0); b.u16(1); b.u16(0); b.u16(15)
            func points(_ p: [CurvePoint], into b: inout PSDBytes) {
                b.u16(UInt16(p.count)); for v in p { b.u16(UInt16(v.y.rounded())); b.u16(UInt16(v.x.rounded())) }
            }
            for channel in a.curves.channels { points(channel, into: &b) }
            b.ascii("Crv "); b.u16(4); b.u16(0); b.u16(4)
            for (i,channel) in a.curves.channels.enumerated() { b.u16(UInt16(i)); points(channel, into: &b) }
            return ("curv", b.data)
        case .exposure:
            b.u16(1); b.f32(a.exposure.exposure); b.f32(a.exposure.offset); b.f32(a.exposure.gamma); b.u16(0)
            return ("expA",b.data)
        default: return nil
        }
    }
}
