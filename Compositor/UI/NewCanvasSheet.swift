import SwiftUI
import AppKit
import ImageIO

/// The units New Canvas sizes can be typed in. Print units turn into pixels at the chosen DPI.
nonisolated enum NewCanvasUnit: String, CaseIterable, Sendable {
    case pixels = "px", inches = "in", centimeters = "cm", millimeters = "mm"

    /// The unit written out in the menu.
    var name: String {
        switch self {
        case .pixels: "Pixels"
        case .inches: "Inches"
        case .centimeters: "Centimeters"
        case .millimeters: "Millimeters"
        }
    }
    /// The next unit: px → in → cm → mm → px.
    var next: NewCanvasUnit { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
    private var perInch: Double? {
        switch self {
        case .pixels: nil
        case .inches: 1
        case .centimeters: 2.54
        case .millimeters: 25.4
        }
    }
    /// Whole pixels for a typed size, or nil when it isn't a size a canvas can have.
    func pixels(_ text: String, resolution: Double) -> Int? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              value.isFinite, value > 0 else { return nil }
        let pixels = perInch.map { (value / $0 * resolution).rounded() } ?? value
        guard pixels == pixels.rounded(), (1...Double(DocumentLimits.maxSide)).contains(pixels) else { return nil }
        return Int(pixels)
    }
    /// A pixel size written in this unit: whole pixels, or print sizes to two decimals at most.
    func text(_ pixels: Int, resolution: Double) -> String {
        guard let perInch else { return String(pixels) }
        return (Double(pixels) / resolution * perInch).formatted(.number.precision(.fractionLength(0...2)).grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX")))
    }
}

/// What a new canvas starts as: see-through, or a Background layer of white or black.
nonisolated enum NewCanvasBackground: String, CaseIterable, Sendable {
    case transparent, white, black
    var title: String {
        switch self {
        case .transparent: L10n.text("Transparent canvas")
        case .white: L10n.text("White canvas")
        case .black: L10n.text("Black canvas")
        }
    }
    var next: NewCanvasBackground { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
    var color: CGColor? {
        switch self {
        case .transparent: nil
        case .white: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .black: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        }
    }
}

struct NewCanvasSheet: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let session: EditorSession
    var onCreate: ((Int, Int, Double, CGColor?) -> Void)? = nil
    var onOpen: (() -> Void)? = nil
    @State private var width = "1920"
    @State private var height = "1080"
    /// Always starting from the common case: remembered print settings turned the default 1920 × 1080 into inches,
    /// a canvas far too big to make.
    @State private var unit = NewCanvasUnit.pixels
    @State private var resolution = 72.0
    @State private var background = NewCanvasBackground.transparent
    @State private var suggestedClipboardSize = false
    @State private var customSize = false
    @FocusState private var focusedField: Field?
    private enum Field { case width, height }
    private var pixelWidth: Int? { unit.pixels(width, resolution: resolution) }
    private var pixelHeight: Int? { unit.pixels(height, resolution: resolution) }
    private var valid: Bool {
        guard let width = pixelWidth, let height = pixelHeight else { return false }
        return background == .transparent || width * height <= DocumentLimits.maxSurfacePixels
    }
    /// Shows the sizes in another unit, the same canvas written differently.
    private func switchUnit(to new: NewCanvasUnit) {
        if let w = pixelWidth, let h = pixelHeight {
            width = new.text(w, resolution: resolution)
            height = new.text(h, resolution: resolution)
        }
        unit = new
    }
    /// Fills in a size given in pixels, written in the unit in use.
    private func setPixels(_ w: Int, _ h: Int) {
        customSize = false
        width = unit.text(w, resolution: resolution)
        height = unit.text(h, resolution: resolution)
    }
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 560
            let margin: CGFloat = 16
            let cardWidth = min(560, max(0, geometry.size.width - margin * 2))
            ScrollView {
                VStack(spacing: 12) {
                    card(width: cardWidth, compact: compact)
                    Text("Or drop an image into the workspace")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(width: cardWidth)
                .padding(margin)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .disabled(session.isImporting || session.showsBusy)
        .onAppear {
            if !suggestedClipboardSize {
                suggestedClipboardSize = true
                if session.skipsInitialClipboardCanvasSize {
                    session.skipsInitialClipboardCanvasSize = false
                } else if let size = Self.clipboardDimensions() {
                    setPixels(size.width, size.height)
                }
            }
            focusedField = .width
        }
    }

    private func card(width: CGFloat, compact: Bool) -> some View {
        let padding: CGFloat = 18
        return VStack(alignment: .leading, spacing: 14) {
            if compact {
                settings
                canvasPreview(height: 100)
            } else {
                HStack(spacing: 14) {
                    settings.frame(maxWidth: .infinity)
                    Rectangle().fill(.primary.opacity(0.10)).frame(width: 1)
                    canvasPreview(height: 132)
                        .frame(width: max(132, (width - padding * 2 - 29) * 0.30))
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(.primary.opacity(0.10)).frame(height: 1)
            actions(compact: compact)
        }
        .padding(padding)
        .background(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.ultraThinMaterial),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(contrast == .increased ? 0.5 : 0.14), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.20), radius: 14, y: 6)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("New canvas").font(.system(size: 18, weight: .semibold))
                Text("Set your canvas size and start creating.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Common sizes").font(.system(size: 11, weight: .medium))
                    Spacer()
                    presetMenu
                }
                HStack(spacing: 6) {
                    quickPreset("1080P", width: 1920, height: 1080)
                    quickPreset("4K", width: 3840, height: 2160)
                    quickPreset(L10n.text("Square canvas"), width: 1080, height: 1080)
                    Button {
                        customSize = true
                        focusedField = .width
                    } label: {
                        Text("Custom").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CanvasChoiceStyle(selected: customSize || !matchesQuickPreset))
                    .accessibilityIdentifier("customCanvasSize")
                    .accessibilityAddTraits(customSize || !matchesQuickPreset ? .isSelected : [])
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Width").frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: 26, height: 0).accessibilityHidden(true)
                    HStack(spacing: 6) {
                        Text("Height")
                        Spacer(minLength: 6)
                        unitMenu
                    }
                    .frame(maxWidth: .infinity)
                }
                .font(.system(size: 11, weight: .medium))
                HStack(alignment: .bottom, spacing: 8) {
                    dimension("Width", text: $width, field: .width)
                    Button {
                        swap(&width, &height)
                    } label: {
                        Image(systemName: "arrow.left.arrow.right").frame(width: 26, height: 30)
                    }
                    .buttonStyle(CanvasChoiceStyle(selected: false, padded: false))
                    .help("Swap width and height")
                    .accessibilityLabel("Swap width and height")
                    .accessibilityIdentifier("swapCanvasDimensions")
                    dimension("Height", text: $height, field: .height)
                }
            }
            HStack(alignment: .top, spacing: 42) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Background").font(.system(size: 11, weight: .medium))
                    Menu {
                        Picker("Background", selection: $background) {
                            ForEach(NewCanvasBackground.allCases, id: \.self) { value in
                                Text(value.title).tag(value)
                            }
                        }.pickerStyle(.inline).labelsHidden()
                    } label: {
                        menuLabel(backgroundLabel)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .help("Start with a transparent, white or black canvas.")
                    .accessibilityLabel("Background")
                    .accessibilityIdentifier("canvasBackground")
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Resolution").font(.system(size: 11, weight: .medium))
                    Menu {
                        Picker("Resolution", selection: $resolution) {
                            Text(verbatim: "72 DPI").tag(72.0)
                            Text(verbatim: "300 DPI").tag(300.0)
                        }.pickerStyle(.inline).labelsHidden()
                    } label: {
                        menuLabel("\(Int(resolution)) DPI")
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .help("Resolution: 72 for screens, 300 for print.")
                    .accessibilityLabel("Resolution")
                    .accessibilityIdentifier("canvasResolution")
                }
                .frame(maxWidth: .infinity)
            }
            if !valid {
                Text(background != .transparent && pixelWidth != nil && pixelHeight != nil
                     ? L10n.format("Filled canvases support up to %lld megapixels.", DocumentLimits.maxSurfaceMegapixels)
                     : unit == .pixels ? L10n.format("Enter whole numbers from 1 to %@ pixels.", DocumentLimits.maxSide.formatted())
                     : L10n.format("Enter a size up to %@ pixels at this DPI.", DocumentLimits.maxSide.formatted()))
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }

    private var backgroundLabel: String {
        switch background {
        case .transparent: L10n.text("Transparent")
        case .white: L10n.text("White")
        case .black: L10n.text("Black")
        }
    }

    private var unitMenu: some View {
        Menu {
            Picker("Units", selection: Binding(get: { unit }, set: switchUnit)) {
                ForEach(NewCanvasUnit.allCases, id: \.self) { value in
                    Text(L10n.text(value.name)).tag(value)
                }
            }.pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Text(L10n.text(unit.name)).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
            }
            .font(.system(size: 11, weight: .regular))
            .padding(.horizontal, 8).frame(minWidth: 64, minHeight: 22)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.10)) }
            .contentShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityElement(children: .combine)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Units")
        .accessibilityIdentifier("canvasUnit")
    }

    private func menuLabel(_ title: String) -> some View {
        HStack {
            Text(title).lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        }
        .font(.system(size: 12)).padding(.horizontal, 10).frame(height: 30)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.10)) }
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }

    private var matchesQuickPreset: Bool {
        [(1920, 1080), (3840, 2160), (1080, 1080)].contains { pixelWidth == $0.0 && pixelHeight == $0.1 }
    }

    private func quickPreset(_ title: String, width: Int, height: Int) -> some View {
        let selected = !customSize && pixelWidth == width && pixelHeight == height
        return Button { setPixels(width, height) } label: {
            Text(verbatim: title).frame(maxWidth: .infinity)
        }
        .buttonStyle(CanvasChoiceStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var presetMenu: some View {
        Menu {
            Picker("Size", selection: preset) {
                Text("Custom").tag(CanvasPreset?.none)
                ForEach(CanvasPreset.groups.indices, id: \.self) { group in
                    Divider()
                    ForEach(CanvasPreset.groups[group]) { Text(L10n.text($0.title)).tag(CanvasPreset?.some($0)) }
                }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary).frame(width: 24, height: 18).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Preset sizes for screens and common formats")
        .accessibilityLabel("Preset sizes")
    }

    private func canvasPreview(height: CGFloat) -> some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                if let width = pixelWidth, let height = pixelHeight {
                    let scale = min(geometry.size.width / CGFloat(width), geometry.size.height / CGFloat(height))
                    ZStack {
                        switch background {
                        case .transparent: Image(nsImage: Self.checkerboard).resizable(resizingMode: .tile)
                        case .white: Color.white
                        case .black: Color.black
                        }
                    }
                    .frame(width: max(1, CGFloat(width) * scale), height: max(1, CGFloat(height) * scale))
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.40), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "rectangle.dashed").font(.system(size: 32, weight: .light))
                        Text("Enter a valid canvas size to preview.").font(.system(size: 11)).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: height)
            .accessibilityHidden(true)
            VStack(spacing: 4) {
                if let width = pixelWidth, let height = pixelHeight {
                    Text(L10n.format("%lld × %lld px", width, height)).font(.system(size: 11, weight: .medium))
                        .accessibilityIdentifier("newCanvasPreviewDimensions")
                    Text(verbatim: aspectRatio(width: width, height: height)).font(.system(size: 10))
                        .accessibilityIdentifier("newCanvasPreviewRatio")
                } else {
                    Text("Canvas preview").font(.system(size: 11))
                }
            }
            .foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func aspectRatio(width: Int, height: Int) -> String {
        var a = width, b = height
        while b != 0 { (a, b) = (b, a % b) }
        return "\(width / a):\(height / a)"
    }

    private static let checkerboard = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
        NSColor(white: 0.24, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
        NSColor(white: 0.30, alpha: 1).setFill()
        NSRect(x: 0, y: 8, width: 8, height: 8).fill()
        NSRect(x: 8, y: 0, width: 8, height: 8).fill()
        return true
    }

    @ViewBuilder private func actions(compact: Bool) -> some View {
        if compact {
            VStack(spacing: 8) {
                fileActions
                createButton.frame(maxWidth: .infinity)
            }
        } else {
            HStack(spacing: 8) {
                fileActions
                Spacer(minLength: 12)
                createButton
            }
        }
    }

    private var fileActions: some View {
        HStack(spacing: 8) {
            Button { onOpen?() } label: { Label("Open project", systemImage: "folder") }
            Button { session.showsImporter = true } label: { Label("Import image", systemImage: "photo") }
        }
        .buttonStyle(CanvasActionStyle())
    }

    private var createButton: some View {
        Button {
            guard valid, let w = pixelWidth, let h = pixelHeight else { return }
            if let onCreate { onCreate(w, h, resolution, background.color) }
            else { session.createDocument(width: w, height: h, emptyLayer: true, resolution: resolution, background: background.color) }
        } label: {
            HStack(spacing: 10) {
                Text("Create canvas")
                Image(systemName: "arrow.right")
            }
            .frame(minWidth: 92)
        }
        .configuredNativeShortcut(.return).buttonStyle(CanvasActionStyle(primary: true))
        .disabled(!valid).accessibilityIdentifier("createCanvas")
    }

    /// The preset the fields match, or nil (Custom); choosing one fills them in, in the unit in use.
    private var preset: Binding<CanvasPreset?> {
        Binding(get: { customSize ? nil : CanvasPreset.all.first { $0.width == pixelWidth && $0.height == pixelHeight } },
                set: { if let chosen = $0 { setPixels(chosen.width, chosen.height) }
                       else { customSize = true; focusedField = .width } })
    }

    static func clipboardDimensions(_ pasteboard: NSPasteboard = .general) -> (width: Int, height: Int)? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  var width = properties[kCGImagePropertyPixelWidth] as? Int,
                  var height = properties[kCGImagePropertyPixelHeight] as? Int else { continue }
            if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
                swap(&width, &height)
            }
            guard CanvasDocument.validDimension(String(width)) != nil,
                  CanvasDocument.validDimension(String(height)) != nil else { continue }
            return (width, height)
        }
        return nil
    }
    private func dimension(_ title: String, text: Binding<String>, field: Field) -> some View {
        HStack(spacing: 6) {
            TextField(L10n.text(title), text: text).textFieldStyle(.plain)
                .font(.system(size: 12)).monospacedDigit()
                .focused($focusedField, equals: field)
                .accessibilityIdentifier(title.lowercased() + "Input")
            Text(verbatim: unit.rawValue).font(.system(size: 11))
                .foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(focusedField == field ? Color.accentColor.opacity(0.7) : .primary.opacity(0.10))
                .allowsHitTesting(false)
        }
    }
}

private struct CanvasChoiceStyle: ButtonStyle {
    var selected: Bool
    var padded = true
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: selected ? .semibold : .medium)).lineLimit(1)
            .padding(.horizontal, padded ? 6 : 0).frame(minHeight: padded ? 28 : 30)
            .background(selected ? Color.accentColor.opacity(0.22) : .primary.opacity(configuration.isPressed ? 0.12 : 0.035),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.8) : .primary.opacity(0.10), lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct CanvasActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium)).labelStyle(.titleAndIcon)
            .padding(.horizontal, 12).frame(height: 30)
            .foregroundStyle(primary ? Color.white : .primary)
            .background(primary ? Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1)
                        : .primary.opacity(configuration.isPressed ? 0.12 : 0.035), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6).strokeBorder(primary ? .white.opacity(0.12) : .primary.opacity(0.16))
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// New Canvas sizes: common screens and resolutions, in pixels, upright as the device is usually held.
struct CanvasPreset: Identifiable, Hashable {
    let title: String
    let width: Int
    let height: Int
    var id: String { title }
    /// Resolutions, Apple screens, then social formats; the menu divides them.
    static let groups: [[CanvasPreset]] = [
        [
            CanvasPreset(title: "4K", width: 3840, height: 2160),
            CanvasPreset(title: "1440p", width: 2560, height: 1440),
            CanvasPreset(title: "1080p", width: 1920, height: 1080),
        ],
        [
            CanvasPreset(title: "iPhone 18 Pro", width: 1206, height: 2622),
            CanvasPreset(title: "iPhone 18 Pro Max", width: 1320, height: 2868),
            CanvasPreset(title: "MacBook Pro 14\"", width: 3024, height: 1964),
            CanvasPreset(title: "MacBook Pro 16\"", width: 3456, height: 2234),
            CanvasPreset(title: "Studio Display", width: 5120, height: 2880),
        ],
        [
            CanvasPreset(title: "Instagram Square", width: 1080, height: 1080),
            CanvasPreset(title: "Instagram Portrait", width: 1080, height: 1350),
            CanvasPreset(title: "Instagram Story", width: 1080, height: 1920),
            CanvasPreset(title: "YouTube Thumb", width: 1080, height: 608),
        ],
    ]
    static let all = groups.flatMap { $0 }
}
