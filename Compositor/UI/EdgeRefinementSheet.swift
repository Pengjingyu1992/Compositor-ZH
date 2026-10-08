import SwiftUI

struct EdgeRefinementSheet: View {
    @Bindable var session: EditorSession
    @Bindable var edit: EdgeRefinement
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
                    let size = CGSize(width: CGFloat(edit.width) * fit, height: CGFloat(edit.height) * fit)
                    ZStack {
                        if edit.background == .black { Color.black }
                        else if edit.background == .white { Color.white }
                        else if edit.background == .mask { Color.gray }
                        else {
                            Canvas { context, bounds in
                                context.fill(Path(CGRect(origin: .zero, size: bounds)), with: .color(.gray.opacity(0.4)))
                                for row in 0...Int(bounds.height / 16) { for column in 0...Int(bounds.width / 16) where (row + column) % 2 == 0 {
                                    context.fill(Path(CGRect(x: column * 16, y: row * 16, width: 16, height: 16)), with: .color(.gray.opacity(0.7)))
                                } }
                            }
                        }
                        if let image = edit.previewImage {
                            Image(nsImage: NSImage(cgImage: image, size: CGSize(width: edit.width, height: edit.height))).resizable().interpolation(.high)
                        }
                    }.frame(width: size.width, height: size.height).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        if !edit.isPainting { edit.beginStroke() }
                        edit.paint(at: CGPoint(x: value.location.x / fit, y: value.location.y / fit))
                    }.onEnded { _ in edit.endStroke() })
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .accessibilityLabel("Edge refinement canvas").accessibilityIdentifier("edgeRefinementCanvas")
                }.frame(width: 680, height: 560)
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
                }.frame(width: 250, height: 560)
            }.disabled(edit.isApplying)
            HStack {
                if edit.isApplying { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { session.cancelEdgeRefinement() }.configuredNativeShortcut(.escape).disabled(edit.isApplying)
                Button("Apply") { Task { await session.applyEdgeRefinement() } }.configuredNativeShortcut(.return).disabled(edit.isApplying || edit.isPainting)
            }
        }.padding(24)
    }
    private func value(_ title: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(L10n.text(title)); Spacer(); TextField("Value", value: binding, format: .number.precision(.fractionLength(1))).frame(width: 60) }
            Slider(value: binding, in: range)
        }
    }
}
