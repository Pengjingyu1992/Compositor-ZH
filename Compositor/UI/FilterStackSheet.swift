import SwiftUI
import UniformTypeIdentifiers

struct FilterStackSheet: View {
    @Bindable var session: EditorSession
    @Bindable var edit: FilterStackWorkspace
    @State private var showsSource = false
    private var selected: EditableFilterNode? { edit.stack.nodes.first { $0.id == edit.selectedID } }
    private func binding<T>(_ key: WritableKeyPath<EditableFilterNode, T>) -> Binding<T> {
        Binding(get: { (selected ?? EditableFilterNode(kind: .gaussianBlur))[keyPath: key] }, set: { value in
            guard !edit.busy, let index = edit.stack.nodes.firstIndex(where: { $0.id == edit.selectedID }) else { return }
            edit.stack.nodes[index][keyPath: key] = value
        })
    }
    private func number(_ label: String, _ key: WritableKeyPath<EditableFilterNode, Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(L10n.text(label)).frame(width: 85, alignment: .leading)
            Slider(value: binding(key), in: range)
            TextField("Value", value: binding(key), format: .number.precision(.fractionLength(1))).frame(width: 65)
        }
    }
    private func add(_ kind: EditableFilterKind) {
        guard edit.stack.nodes.count < 32 else { return }
        var node = EditableFilterNode(kind: kind); node.coverage = edit.selectionCoverage
        edit.stack.nodes.append(node); edit.selectedID = node.id
    }
    private func move(_ delta: Int) {
        guard let index = edit.stack.nodes.firstIndex(where: { $0.id == edit.selectedID }), edit.stack.nodes.indices.contains(index + delta) else { return }
        edit.stack.nodes.swapAt(index, index + delta)
    }
    private func importLUT() {
        guard let id = selected?.id else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .plainText]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, session.filterStackEdit === edit, !edit.busy,
                  let index = edit.stack.nodes.firstIndex(where: { $0.id == id }), let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 16 * 1024 * 1024 else { throw ProjectError.tooLarge }
                edit.stack.nodes[index].lut.table = try ColorLUT.parse(Data(contentsOf: url), name: url.lastPathComponent)
            } catch { edit.error = error.localizedDescription }
        }
    }
    @ViewBuilder private var controls: some View {
        if let node = selected {
            Text(L10n.text(node.kind.rawValue)).font(.headline)
            HStack {
                Text("Filter Opacity").frame(width: 85, alignment: .leading)
                Slider(value: binding(\.opacity), in: 0...1)
                TextField("Percent", value: binding(\.opacity), format: .percent.precision(.fractionLength(0))).frame(width: 65)
            }
            if node.coverage != nil {
                Text("This step uses the selection captured when it was added.").font(.caption).foregroundStyle(.secondary)
                Button("Clear Filter Mask") { binding(\.coverage).wrappedValue = nil }
            }
            switch node.kind {
            case .gaussianBlur: number("Radius", \.radius, 0.1...250)
            case .motionBlur:
                number("Angle", \.angle, -90...90)
                number("Distance", \.distance, 1...2000)
            case .addNoise:
                number("Amount", \.amount, 0.1...400)
                Toggle("Gaussian", isOn: binding(\.gaussian))
                Toggle("Monochromatic", isOn: binding(\.monochromatic))
            case .colorHalftone, .colorLUT:
                PosterFilterControls(session: session, kind: node.kind.pixelKind!, settingsOverride: Binding(get: {
                    selected?.settings ?? FilterSettings()
                }, set: { value in
                    binding(\.halftone).wrappedValue = value.colorHalftone
                    binding(\.lut).wrappedValue = value.colorLUT
                }), importLUTAction: importLUT)
            case .liquify:
                Text("Saved displacement and frozen areas can be edited in Liquify.").font(.callout)
                Button("Edit Saved Liquify…") {
                    edit.endAndOpenLiquify(session: session, nodeID: node.id)
                }.disabled(edit.stack != edit.initial)
                if edit.stack != edit.initial { Text("Apply or cancel these changes before opening Liquify.").font(.caption).foregroundStyle(.secondary) }
            }
        } else {
            Text("Add a filter to keep its settings editable.").foregroundStyle(.secondary)
        }
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Editable Filters").font(.title2.bold())
                Text(edit.layer.name).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Toggle("Before", isOn: $showsSource).toggleStyle(.button)
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading) {
                    List(selection: $edit.selectedID) {
                        ForEach(edit.stack.nodes) { node in
                            HStack {
                                Toggle(L10n.text(node.kind.rawValue), isOn: Binding(get: {
                                    edit.stack.nodes.first(where: { $0.id == node.id })?.enabled ?? false
                                }, set: { enabled in
                                    if let index = edit.stack.nodes.firstIndex(where: { $0.id == node.id }) { edit.stack.nodes[index].enabled = enabled }
                                })).toggleStyle(.checkbox)
                            }.tag(node.id)
                        }
                    }.frame(width: 210)
                    HStack {
                        Menu("Add Filter") {
                            ForEach(EditableFilterKind.allCases.filter { $0 != .liquify }, id: \.self) { kind in
                                Button(L10n.text(kind.rawValue)) { add(kind) }
                            }
                        }.disabled(edit.stack.nodes.count >= 32)
                        Button { move(-1) } label: { Image(systemName: "arrow.up") }.help("Move Filter Earlier")
                        Button { move(1) } label: { Image(systemName: "arrow.down") }.help("Move Filter Later")
                    }
                    Button("Remove Filter") {
                        edit.stack.nodes.removeAll { $0.id == edit.selectedID }
                        edit.selectedID = edit.stack.nodes.first?.id
                    }.disabled(selected == nil)
                }
                VStack(spacing: 10) {
                    if let image = showsSource ? edit.stack.source.image : edit.preview {
                        Image(nsImage: NSImage(cgImage: image, size: .zero)).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.2))
                    }
                    Text(L10n.text(edit.previewNodes == edit.stack.nodes ? "Preview is up to date." : "Refresh the preview to see these changes."))
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView { VStack(alignment: .leading, spacing: 10) { controls }.padding(4) }.frame(height: 235)
                }.frame(minWidth: 420)
            }.disabled(edit.busy)
            Text("Filters run from top to bottom inside the layer bounds, before layer masks and styles. Pixel painting bakes the result; Undo restores editability.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = edit.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                if edit.busy { ProgressView().controlSize(.small) }
                Button("Refresh Preview") { Task { await session.renderFilterStack(commit: false) } }.disabled(edit.busy)
                Spacer()
                Button("Cancel") { session.cancelFilterStack() }.configuredNativeShortcut(.escape)
                Button("Apply") { Task { await session.renderFilterStack(commit: true) } }
                    .buttonStyle(.borderedProminent).configuredNativeShortcut(.return).disabled(edit.busy)
            }
        }.padding(18).frame(width: 820, height: 650).interactiveDismissDisabled(edit.busy)
    }
}

extension FilterStackWorkspace {
    func endAndOpenLiquify(session: EditorSession, nodeID: UUID) {
        guard stack == initial, !busy else { return }
        session.queuedLiquify = (nodeID, owner.documentID, owner.revision, layer.id)
        session.cancelFilterStack()
    }
}
