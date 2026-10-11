import SwiftUI

struct PosterFilterControls: View {
    @Bindable var session: EditorSession
    let kind: FilterKind
    var settingsOverride: Binding<FilterSettings>? = nil
    var importLUTAction: (() -> Void)? = nil
    @State private var outputChannel = 0
    private var settings: FilterSettings { settingsOverride?.wrappedValue ?? session.filterEdit?.settings ?? FilterSettings() }
    private func update(_ change: (inout FilterSettings) -> Void) {
        var value = settings; change(&value)
        if let settingsOverride { settingsOverride.wrappedValue = value }
        else { session.updateFilter(value, preview: session.filterEdit?.preview ?? true) }
    }
    private func value(_ key: WritableKeyPath<FilterSettings, Double>) -> Binding<Double> {
        Binding(get: { settings[keyPath: key] }, set: { v in update { $0[keyPath: key] = v } })
    }
    private func slider(_ title: String, _ key: WritableKeyPath<FilterSettings, Double>, range: ClosedRange<Double>) -> some View {
        HStack { Text(L10n.text(title)).frame(width: 100, alignment: .leading); Slider(value: value(key), in: range); TextField("Value", value: value(key), format: .number.precision(.fractionLength(0))).frame(width: 45) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch kind {
            case .colorHalftone:
                HStack {
                    Button("Color Halftone") { update { $0.colorHalftone = ColorHalftoneSettings() } }
                    Button("Newsprint") { update { $0.colorHalftone = ColorHalftoneSettings(size: 5) } }
                    Button("Pop Art") { update { $0.colorHalftone = ColorHalftoneSettings(size: 18, shape: .square) } }
                }
                Picker("Screen Channels", selection: Binding(get: { settings.colorHalftone.screen ?? .legacyCMYK }, set: { v in update { $0.colorHalftone.screen = v } })) {
                    ForEach(HalftoneScreen.allCases, id: \.self) { Text(L10n.text($0.rawValue)).tag($0) }
                }
                Picker("Dot Shape", selection: Binding(get: { settings.colorHalftone.shape }, set: { v in update { $0.colorHalftone.shape = v } })) {
                    ForEach(HalftoneDot.allCases, id: \.self) { Text(L10n.text($0.rawValue)).tag($0) }
                }
                slider(settings.colorHalftone.usesLegacyScreen ? "Dot Size" : "Max Radius", \.colorHalftone.size, range: 2...128)
                if settings.colorHalftone.screen != .grayscale {
                    slider(settings.colorHalftone.usesLegacyScreen ? "Cyan Angle" : "Channel 1 Angle", \.colorHalftone.cyan, range: -180...180)
                    slider(settings.colorHalftone.usesLegacyScreen ? "Magenta Angle" : "Channel 2 Angle", \.colorHalftone.magenta, range: -180...180)
                    slider(settings.colorHalftone.usesLegacyScreen ? "Yellow Angle" : "Channel 3 Angle", \.colorHalftone.yellow, range: -180...180)
                }
                if settings.colorHalftone.screen != .rgb {
                    slider(settings.colorHalftone.usesLegacyScreen ? "Black Angle" : "Grayscale Angle", \.colorHalftone.black, range: -180...180)
                }
                slider("Strength", \.colorHalftone.strength, range: 0...100)
                Text(settings.colorHalftone.usesLegacyScreen
                     ? "RGB print simulation; this does not change the document to CMYK."
                     : "Automatic uses one screen for gray pixels and three for color. Dark dots can overlap.").font(.caption).foregroundStyle(.secondary)
            case .selectiveColor:
                Picker("Colors", selection: Binding(get: { settings.selectiveColor.range }, set: { v in update { $0.selectiveColor.range = v } })) {
                    ForEach(SelectiveRange.allCases, id: \.self) { Text(L10n.text($0.rawValue)).tag($0) }
                }
                slider("Cyan", \.selectiveColor.cyan, range: -100...100)
                slider("Magenta", \.selectiveColor.magenta, range: -100...100)
                slider("Yellow", \.selectiveColor.yellow, range: -100...100)
                slider("Black", \.selectiveColor.black, range: -100...100)
                Toggle("Relative", isOn: Binding(get: { settings.selectiveColor.relative }, set: { v in update { $0.selectiveColor.relative = v } }))
            case .channelMixer:
                Picker("Output Channel", selection: $outputChannel) {
                    Text("Red").tag(0); Text("Green").tag(1); Text("Blue").tag(2)
                }
                ForEach(0..<4) { column in
                    HStack {
                        Text(L10n.text(["Red", "Green", "Blue", "Constant"][column])).frame(width: 80, alignment: .leading)
                        let binding = Binding(get: { settings.channelMixer.coefficients[outputChannel * 4 + column] }, set: { value in update { $0.channelMixer.coefficients[outputChannel * 4 + column] = value } })
                        Slider(value: binding, in: -200...200)
                        TextField("Percent", value: binding, format: .number.precision(.fractionLength(0))).frame(width: 45)
                    }
                }
                Button("Reset") { update { $0.channelMixer = ChannelMixerSettings() } }
            case .colorLUT:
                Button("Import .cube LUT…") { if let importLUTAction { importLUTAction() } else { session.importColorLUT() } }
                Text(settings.colorLUT.table?.name ?? L10n.text("No LUT selected")).lineLimit(2)
                Picker("LUT Input Space", selection: Binding(get: { settings.colorLUT.space }, set: { v in update { $0.colorLUT.space = v } })) {
                    ForEach(LUTSpace.allCases, id: \.self) { Text(L10n.text($0.rawValue)).tag($0) }
                }
                slider("Strength", \.colorLUT.strength, range: 0...100)
                Text("Use a LUT made for the selected input space. Log camera LUTs need a separate input conversion.").font(.caption).foregroundStyle(.secondary)
            default: EmptyView()
            }
        }
    }
}
