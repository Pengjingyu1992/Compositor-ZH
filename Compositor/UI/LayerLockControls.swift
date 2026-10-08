import SwiftUI

struct LayerLockControls: View {
    @Bindable var session: EditorSession
    private let options: [(LayerLocks, String, String)] = [
        (.transparency, "square.dotted", "Lock Transparency"),
        (.content, "paintbrush", "Lock Content"),
        (.position, "arrow.up.and.down.and.arrow.left.and.right", "Lock Position"),
        (.appearance, "circle.lefthalf.filled", "Lock Appearance"),
        (.all, "lock", "Lock All")
    ]

    var body: some View {
        HStack(spacing: 4) {
            Text("Lock").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            ForEach(options, id: \.2) { lock, icon, title in
                Button { session.toggleSelectedLayerLock(lock) } label: {
                    Image(systemName: icon).frame(width: 24, height: 26)
                        .background(session.selectedLayersHaveLock(lock) ? Color.accentColor.opacity(0.25) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain).help(L10n.text(title)).accessibilityLabel(L10n.text(title))
                .accessibilityValue(session.selectedLayersHaveLock(lock) ? L10n.text("Locked") : L10n.text("Unlocked"))
                .accessibilityIdentifier("layerLock-\(lock.rawValue)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .disabled(!session.canEditLayers || session.history.hasPendingEdit || session.effectsEditing != nil || session.selectedLayerIDs.isEmpty)
        .help("Locks apply to this session and are inherited from folders.")
    }
}

struct LayerLockMenuItems: View {
    @Bindable var session: EditorSession
    var body: some View {
        Toggle("Lock Content", isOn: binding(.content))
        Toggle("Lock Position", isOn: binding(.position))
        Toggle("Lock Appearance", isOn: binding(.appearance))
        Toggle("Lock Transparency", isOn: binding(.transparency))
        Toggle("Lock All", isOn: binding(.all))
    }
    private func binding(_ lock: LayerLocks) -> Binding<Bool> {
        Binding(get: { session.selectedLayersHaveLock(lock) }, set: { value in
            if value != session.selectedLayersHaveLock(lock) { session.toggleSelectedLayerLock(lock) }
        })
    }
}
