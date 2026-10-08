import SwiftUI

struct EdgeRefinementSheet: View {
    @Bindable var session: EditorSession
    @Bindable var edit: EdgeRefinement
    @State private var fittingScale: CGFloat = 1
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Refine Layer Edges").font(.title2)
                Spacer()
                Button("Undo") { edit.undo() }.disabled(!edit.canUndo).configuredNativeShortcut("z", modifiers: [.command])
                Button("Redo") { edit.redo() }.disabled(!edit.canRedo).configuredNativeShortcut("z", modifiers: [.command, .shift])
            }
            HStack(alignment: .top, spacing: 20) {
                GeometryReader { geometry in
                    let fit = min(geometry.size.width / CGFloat(edit.width), geometry.size.height / CGFloat(edit.height))
                    let size = CGSize(width: CGFloat(edit.width) * fit * edit.zoom, height: CGFloat(edit.height) * fit * edit.zoom)
                    ScrollView([.horizontal, .vertical]) {
                        ZStack {
                            if edit.background == .black { Color.black }
                            else if edit.background == .white { Color.white }
                            else if edit.background == .mask { Color.gray }
                            else { Image(nsImage: Self.checker).resizable(resizingMode: .tile) }
                            if let image = edit.previewImage {
                                Image(nsImage: NSImage(cgImage: image, size: CGSize(width: edit.width, height: edit.height)))
                                    .resizable().interpolation(.high)
                            }
                        }.frame(width: size.width, height: size.height).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if !edit.isPainting { edit.beginStroke() }
                            edit.paint(at: CGPoint(x: value.location.x / (fit * edit.zoom), y: value.location.y / (fit * edit.zoom)))
                        }.onEnded { _ in edit.endStroke() })
                        .accessibilityLabel("Edge refinement canvas").accessibilityIdentifier("edgeRefinementCanvas")
                    }.defaultScrollAnchor(.center)
                    .onAppear { fittingScale = fit }
                    .onChange(of: geometry.size) { _, _ in fittingScale = fit }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Button("Select Subject") { Task { await session.detectRefinementSubject() } }
                        Picker("Brush", selection: $edit.mode) { ForEach(EdgeBrushMode.allCases, id: \.self) { Text(L10n.text($0.rawValue)).tag($0) } }
                        value("Brush Size", $edit.diameter, 2...1000)
                        value("Strength", $edit.strength, 0...1)
                        Picker("View", selection: $edit.background) { ForEach(EdgeBackground.allCases, id: \.self) { Text(L10n.text($0.rawValue)).tag($0) } }
                        Divider()
                        value("Feather", $edit.feather, 0...100)
                        value("Shift Edge", $edit.shift, -100...100)
                        value("Contrast", $edit.contrast, 0...100)
                        value("Decontaminate Colors", $edit.decontaminate, 0...100)
                        Toggle("Create Copy", isOn: $edit.createsCopy).disabled(edit.decontaminate > 0)
                        Text("Color decontamination creates a pixel copy. The original layer is retained.").font(.caption).foregroundStyle(.secondary)
                        Text("Brush edits use a preview grid up to 1536 pixels. Masks are applied at the original image size; inspect fine hair after applying.").font(.caption).foregroundStyle(.secondary)
                        if edit.layer.mask?.isLinked == false {
                            Text("Applying aligns and links the refined mask to the layer.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.trailing, 8)
                }.frame(width: 250)
            }.disabled(edit.isApplying)
            HStack {
                Button("Fit") { edit.zoom = 1 }
                Button("100%") { edit.zoom = min(20, 1 / max(0.001, fittingScale)) }
                Button("−") { edit.zoom = max(0.1, edit.zoom / 1.25) }
                Text("\(Int(fittingScale * edit.zoom * 100))%").monospacedDigit().frame(width: 50)
                Button("+") { edit.zoom = min(20, edit.zoom * 1.25) }
                Text("Scroll to inspect enlarged edges.").font(.caption).foregroundStyle(.secondary)
                if edit.isApplying { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { session.cancelEdgeRefinement() }.configuredNativeShortcut(.escape).disabled(edit.isApplying)
                Button("Apply") { Task { await session.applyEdgeRefinement() } }.configuredNativeShortcut(.return).disabled(edit.isApplying || edit.isPainting)
            }
        }.padding(24)
            .frame(width: min(1000, (NSScreen.main?.visibleFrame.width ?? 1280) - 80),
                   height: min(720, (NSScreen.main?.visibleFrame.height ?? 900) - 100))
            .interactiveDismissDisabled(edit.isApplying)
            .onDisappear { if session.edgeRefinement === edit { session.cancelEdgeRefinement() } }
    }
    private static let checker: NSImage = {
        guard let context = try? BrushRaster.context(width: 32, height: 32, mask: false) else { return NSImage(size: CGSize(width: 32, height: 32)) }
        context.setFillColor(gray: 0.4, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        context.setFillColor(gray: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16)); context.fill(CGRect(x: 16, y: 16, width: 16, height: 16))
        return context.makeImage().map { NSImage(cgImage: $0, size: CGSize(width: 32, height: 32)) } ?? NSImage(size: CGSize(width: 32, height: 32))
    }()
    private func value(_ title: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(L10n.text(title)); Spacer(); TextField("Value", value: binding, format: .number.precision(.fractionLength(1))).frame(width: 60) }
            Slider(value: binding, in: range)
        }
    }
}
