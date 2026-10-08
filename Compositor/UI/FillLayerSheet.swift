import SwiftUI

struct FillStyleControls: View {
    @Binding var style: LayerFillStyle
    var showsKind = true
    var gradientOnly = false
    private func color(_ index: Int) -> Binding<Color> {
        Binding(get: {
            guard style.stops.indices.contains(index) else { return .clear }
            let value = style.stops[index].color
            return Color(red: value.red, green: value.green, blue: value.blue, opacity: value.alpha)
        }, set: { value in
            guard style.stops.indices.contains(index), let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
            style.stops[index].color = FillColor(red: rgb.redComponent, green: rgb.greenComponent,
                blue: rgb.blueComponent, alpha: rgb.alphaComponent)
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsKind {
                Picker("Fill Type", selection: $style.kind) {
                    ForEach(gradientOnly ? [.linear, .radial] : FillKind.allCases, id: \.self) { Text(L10n.text($0.rawValue)).tag($0) }
                }
            }
            if style.kind == .solid {
                ColorPicker("Color", selection: color(0))
            } else {
                ForEach(Array(style.stops.indices.prefix(style.kind == .pattern ? 2 : 32)), id: \.self) { index in
                    HStack {
                        ColorPicker(L10n.format("Color Stop %lld", index + 1), selection: color(index))
                        if style.kind != .pattern {
                            TextField("Position", value: $style.stops[index].position, format: .number.precision(.fractionLength(2)))
                                .frame(width: 64).help("Position from 0 to 1")
                            Button { if style.stops.count > 2 { style.stops.remove(at: index) } } label: { Image(systemName: "minus.circle") }
                                .disabled(style.stops.count <= 2)
                        }
                    }
                }
                if style.kind != .pattern {
                    Button("Add Color Stop") {
                        style.stops.append(FillStop(position: 0.5, color: FillColor(red: 0.6, green: 0.7, blue: 1)))
                        style.stops.sort { $0.position < $1.position }
                    }.disabled(style.stops.count >= 32)
                    Toggle("Reverse", isOn: $style.reversed)
                } else {
                    Picker("Pattern", selection: $style.pattern) {
                        ForEach(FillPattern.allCases, id: \.self) { Text(L10n.text($0.rawValue)).tag($0) }
                    }
                    HStack { Text("Cell Size"); Slider(value: $style.cellSize, in: 4...512); Text(Int(style.cellSize).description).monospacedDigit() }
                }
                HStack { Text("Angle"); Slider(value: $style.angle, in: -180...180); Text(Int(style.angle).description + "°").monospacedDigit() }
                HStack { Text("Scale"); Slider(value: $style.scale, in: 0.05...4); Text(style.scale, format: .percent.precision(.fractionLength(0))).monospacedDigit() }
            }
        }
    }
}

struct FillLayerSheet: View {
    @Bindable var session: EditorSession
    let draft: FillLayerDraft
    @State private var style: LayerFillStyle
    init(session: EditorSession, draft: FillLayerDraft) {
        self.session = session; self.draft = draft; _style = State(initialValue: draft.style)
    }
    private var normalized: LayerFillStyle {
        var result = style; result.stops.sort { $0.position < $1.position }; return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(draft.layerID == nil ? "New Fill Layer" : "Edit Fill Layer").font(.title2)
            HStack(alignment: .top, spacing: 24) {
                if let image = try? normalized.render(width: 240, height: 240) {
                    Image(nsImage: NSImage(cgImage: image, size: CGSize(width: 240, height: 240)))
                        .frame(width: 240, height: 240).background(.gray.opacity(0.3))
                }
                ScrollView { FillStyleControls(style: $style) }.frame(width: 360, height: 340)
            }
            Text("Fill layers stay editable until their pixels are painted or filtered.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { session.cancelFillLayer() }.configuredNativeShortcut(.escape)
                Button("Apply") {
                    var edited = draft; edited.style = normalized; Task { await session.applyFillLayer(edited) }
                }.configuredNativeShortcut(.return).disabled(!normalized.isValid || session.fillLayerApplying)
            }
        }.padding(24).disabled(session.fillLayerApplying)
    }
}
