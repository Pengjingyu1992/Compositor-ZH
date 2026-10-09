import AppKit

nonisolated enum PSDEditableReader {
    static func descriptor(_ data: Data?, offset: Int = 0) -> [String: DescriptorValue]? {
        guard let data, data.count <= 8_000_000, offset <= data.count else { return nil }
        var reader = PSDDescriptorReader(data: data, offset: offset)
        return reader.descriptor(versioned: true)
    }
    static func fullyMappedEffects(_ data: Data) -> Bool {
        guard let d = descriptor(data,offset:4) else { return false }
        let known: Set<String> = ["masterFXSwitch","Scl ","SoFi","DrSh","IrSh","OrGl","IrGl","FrFX","GrFl"]
        guard Set(d.keys).isSubset(of:known) else { return false }
        for key in ["SoFi","DrSh","IrSh","OrGl","IrGl","FrFX","GrFl"] {
            if let value = d[key] {
                guard case .descriptor(let e) = value, e.enumeration("Md  ") == "Nrml" else { return false }
                if key == "FrFX", e.enumeration("PntT") != "SClr" { return false }
                if key == "GrFl", gradient(e) == nil { return false }
            }
        }; return true
    }
    static func effects(_ data: Data?) -> LayerEffects? {
        guard let root = descriptor(data, offset: 4) else { return nil }
        let master = root.number("masterFXSwitch", 1) != 0
        var result = LayerEffects()
        func e(_ key: String) -> [String:DescriptorValue]? { root.object(key) }
        func enabled(_ d: [String:DescriptorValue]) -> Bool { master && d.number("enab",1) != 0 }
        func color(_ d: [String:DescriptorValue]) -> PaletteColor { d.object("Clr ")?.rgb ?? .black }
        func opacity(_ d: [String:DescriptorValue]) -> Double { d.number("Opct",100)/100 }
        if let d = e("SoFi"), d.enumeration("Md  ") == "Nrml" {
            let c = color(d); result.colorOverlay = ColorOverlayEffect(enabled: enabled(d),red:c.red,green:c.green,blue:c.blue,opacity:opacity(d))
        }
        if let d = e("DrSh"), d.enumeration("Md  ") == "Nrml" {
            let c = color(d); result.shadow = ShadowEffect(enabled:enabled(d),angle:d.cg("lagl",90),distance:d.cg("Dstn",0),blur:d.cg("blur",0),red:c.red,green:c.green,blue:c.blue,opacity:opacity(d))
        }
        if let d = e("IrSh"), d.enumeration("Md  ") == "Nrml" {
            let c = color(d); result.innerShadow = InnerShadowEffect(enabled:enabled(d),angle:d.cg("lagl",90),distance:d.cg("Dstn",0),blur:d.cg("blur",0),red:c.red,green:c.green,blue:c.blue,opacity:opacity(d))
        }
        if let d = e("OrGl"), d.enumeration("Md  ") == "Nrml" {
            let c = color(d); result.outerGlow = OuterGlowEffect(enabled:enabled(d),size:d.cg("blur",0),red:c.red,green:c.green,blue:c.blue,opacity:opacity(d))
        }
        if let d = e("IrGl"), d.enumeration("Md  ") == "Nrml" {
            let c = color(d); result.innerGlow = InnerGlowEffect(enabled:enabled(d),size:d.cg("blur",0),red:c.red,green:c.green,blue:c.blue,opacity:opacity(d))
        }
        if let d = e("FrFX"), d.enumeration("Md  ") == "Nrml", d.enumeration("PntT") == "SClr" {
            let c = color(d); result.stroke = StrokeEffect(enabled:enabled(d),size:d.cg("Sz  ",0),red:c.red,green:c.green,blue:c.blue,opacity:opacity(d),inside:d.enumeration("Styl") == "InsF")
        }
        if let d = e("GrFl"), d.enumeration("Md  ") == "Nrml", let fill = gradient(d) {
            result.gradientOverlay = FillOverlayEffect(enabled:enabled(d),fill:fill,opacity:opacity(d))
        }
        return result.isValid && !result.isEmpty ? result : nil
    }
    static func gradient(_ d: [String:DescriptorValue]) -> LayerFillStyle? {
        guard let gradient = d.object("Grad"), gradient.enumeration("GrdF") == "CstS",
              let colors = gradient.values("Clrs"), let alphas = gradient.values("Trns") else { return nil }
        var fill = LayerFillStyle(kind: d.enumeration("Type") == "Rdl " ? .radial : .linear)
        guard ["Lnr ","Rdl "].contains(d.enumeration("Type") ?? ""), d.number("Algn",1) != 0 else { return nil }
        fill.angle = -d.number("Angl",0); fill.scale = d.number("Scl ",100)/100; fill.reversed = d.number("Rvrs",0) != 0
        var opacity: [(Double,Double)] = []
        for v in alphas {
            guard case .descriptor(let a) = v, a.number("Mdpn",50) == 50 else { return nil }
            opacity.append((a.number("Lctn",0)/4096,a.number("Opct",100)/100))
        }
        opacity.sort { $0.0 < $1.0 }
        func alpha(_ x: Double) -> Double {
            guard let first = opacity.first else { return 1 }
            if x <= first.0 { return first.1 }
            for (a,b) in zip(opacity,opacity.dropFirst()) where x <= b.0 {
                let t = (x-a.0)/max(0.000001,b.0-a.0); return a.1+(b.1-a.1)*t
            }; return opacity.last!.1
        }
        fill.stops = []
        for v in colors {
            guard case .descriptor(let c) = v, c.number("Mdpn",50) == 50, let rgb = c.object("Clr ")?.rgb else { return nil }
            let location = c.number("Lctn",0)/4096
            fill.stops.append(FillStop(position:location,color:FillColor(red:rgb.red,green:rgb.green,blue:rgb.blue,alpha:alpha(location))))
        }
        // Separate opacity breakpoints cannot be discarded when mapping to shared RGBA stops.
        guard opacity.allSatisfy({ a in fill.stops.contains { abs($0.position-a.0) < 0.000001 } }) else { return nil }
        return fill.isValid ? fill : nil
    }
}

nonisolated extension Dictionary where Key == String, Value == DescriptorValue {
    func number(_ key: String, _ fallback: Double = 0) -> Double { if case .number(let n) = self[key] { return n }; return fallback }
    func cg(_ key: String, _ fallback: Double = 0) -> CGFloat { CGFloat(number(key,fallback)) }
    func object(_ key: String) -> Self? { if case .descriptor(let d) = self[key] { return d }; return nil }
    func values(_ key: String) -> [DescriptorValue]? { if case .list(let d) = self[key] { return d }; return nil }
    var rgb: PaletteColor {
        PaletteColor(red:cg("Rd  ")/255,green:cg("Grn ")/255,blue:cg("Bl  ")/255)
    }
}
