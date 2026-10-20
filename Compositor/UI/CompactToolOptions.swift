import SwiftUI

/// Editing must always have a visible way out, even when every optional parameter is collapsed.
struct ToolEditActions: View {
    @Bindable var session: EditorSession
    var body: some View {
        HStack(spacing: 8) {
            if session.tool == .move, session.transformEdit?.persistent == true {
                Button("Cancel") { session.cancelTransform() }.configuredNativeShortcut(.escape)
                Button("Apply") { session.commitTransform() }.configuredNativeShortcut(.return)
                    .accessibilityIdentifier("applyTransform")
            } else if session.tool == .type, session.textDraft != nil {
                Button("Cancel") { session.cancelText() }
                Button("Done") { _ = session.finishText() }
            } else if session.tool == .crop, session.cropRect != nil {
                Button("Cancel") { session.cancelCrop() }
                Button("Apply Crop") { Task { await session.commitCrop() } }
            } else if session.tool == .pen, session.pathEditing != nil {
                Button("Cancel") { session.pathEditing = nil }
                Button("Apply") { session.finishPathEditing() }
            } else if session.tool == .gradient, session.gradientEdit != nil {
                Button("Cancel") { session.cancelGradient() }
                Button("Apply") { Task { await session.commitGradient() } }
            }
        }.fixedSize().disabled(session.showsBusy)
    }
}
