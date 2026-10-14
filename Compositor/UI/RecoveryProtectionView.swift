import SwiftUI

nonisolated struct RecoveryProtection: Equatable, Sendable {
    let documentID: UUID
    let revision: UUID
    let checkpointDate: Date
    let completedAt: Date
}

/// Report the revision actually written, rather than promising that an in-progress gesture is durable.
struct RecoveryProtectionView: View {
    @Bindable var session: EditorSession
    @State private var expanded = false
    private var protection: RecoveryProtection? {
        session.recoveryProtection.flatMap { $0.documentID == session.document?.id ? $0 : nil }
    }
    private var currentProtected: Bool { protection?.revision == session.history.currentRevision }
    var body: some View {
        Button { expanded.toggle() } label: {
            Image(systemName: session.recoveryError != nil ? "exclamationmark.shield" : currentProtected ? "checkmark.shield" : "shield")
        }
        .buttonStyle(.plain).accessibilityLabel("Recovery Protection").help("Recovery Protection")
        .accessibilityIdentifier("recoveryProtection")
        .popover(isPresented: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recovery Protection").font(.headline)
                if let protection {
                    Text("Last successful copy")
                    Text(protection.completedAt, format: .dateTime.year().month().day().hour().minute().second()).monospacedDigit()
                    Text(L10n.text(currentProtected ? "The current committed revision is protected." : "Newer changes are waiting for a recovery copy."))
                } else { Text("No successful recovery copy for this document yet.") }
                if session.recoveryWritingDocumentID == session.document?.id { Text("Writing recovery copy…") }
                if let error = session.recoveryError { Text(error).foregroundStyle(.orange) }
                Text("In-progress gestures are not included. Recovery copies do not mark your project as saved.")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).padding(16).frame(width: 300)
        }
    }
}
