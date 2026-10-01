import SwiftUI

struct LayerArrangeMenu: View {
    @Bindable var session: EditorSession
    var compact = false
    var body: some View {
        Menu {
            Menu("Alignment Reference") {
                Button("Selection Bounds") { session.arrangeReference = .selection }
                Button("Canvas") { session.arrangeReference = .canvas }
                Button("Use Active Layer as Key Object") {
                    if let id = session.activeLayerID { session.arrangeReference = .keyObject(id) }
                }.disabled(session.arrangeTargets?.contains { $0.id == session.activeLayerID } != true)
                if case .keyObject(let id) = session.arrangeReference {
                    Text(L10n.format("Key Object: %@", session.document?.layers.first { $0.id == id }?.name ?? ""))
                } else {
                    Text(L10n.text(session.arrangeReference == .canvas ? "Canvas" : "Selection Bounds"))
                }
            }
            Divider()
            ForEach(ArrangeOperation.allCases.filter(\.isAlignment), id: \.self) { operation in
                Button(L10n.text(operation.rawValue)) { session.performArrange(operation) }
                    .disabled(!session.canArrange(operation))
            }
            Divider()
            ForEach(ArrangeOperation.allCases.filter { !$0.isAlignment }, id: \.self) { operation in
                Button(L10n.text(operation.rawValue)) { session.performArrange(operation) }
                    .disabled(!session.canArrange(operation))
            }
        } label: {
            if compact { Image(systemName: "align.horizontal.left") }
            else { Text("Arrange Layers") }
        }
        .accessibilityLabel(L10n.text("Arrange Layers"))
        .help("Reference affects alignment; distribution keeps the two outer layers fixed.")
        .accessibilityIdentifier("arrangeLayers")
    }
}
