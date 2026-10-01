import SwiftUI
import AppKit

struct RecoverySheet: View {
    let store: RecoveryStore
    let restore: (RecoveryEntry) async throws -> Void
    let close: () -> Void
    @State private var entries: [RecoveryEntry] = []
    @State private var error: String?
    @State private var busy = false
    @State private var deleting: RecoveryEntry?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recovery Copies").font(.title2.bold())
            Text("Copies are stored locally and do not replace your saved projects. Recovering opens an unsaved draft in a new tab.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(entries) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.title).font(.headline)
                    if let record = entry.record { Text(record.date, style: .date).foregroundStyle(.secondary) }
                    if let message = entry.error { Text(message).foregroundStyle(.orange) }
                    HStack {
                        Button("Recover") {
                            busy = true
                            Task {
                                do { try await restore(entry); close() }
                                catch { self.error = L10n.text(error.localizedDescription) }
                                busy = false
                            }
                        }.disabled(entry.error != nil)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                        Spacer()
                        Button("Delete Recovery Copy", role: .destructive) { deleting = entry }
                    }
                }.padding(.vertical, 6)
            }.frame(minHeight: 240)
            if entries.isEmpty { Text("No recovery copies are available.").foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("Up to 32 documents and 4 GB. Existing copies are kept when storage is full.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 620).disabled(busy)
        .task { await refresh() }
        .confirmationDialog("Delete this recovery copy?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Recovery Copy", role: .destructive) {
                guard let entry = deleting else { return }
                deleting = nil; busy = true
                Task {
                    do { try await store.remove(entry.url); await refresh() }
                    catch { self.error = error.localizedDescription }
                    busy = false
                }
            }
        } message: { Text("This permanently removes the selected recovery copy. Your open document and saved projects are unchanged.") }
    }
    private func refresh() async {
        do { entries = try await store.entries() }
        catch { self.error = error.localizedDescription }
    }
}

extension ProjectController {
    func reviewRecoveryCopies() async {
        guard let workspace, let store = workspace.recoveryStore, let window,
              window.attachedSheet == nil, !workspace.isManaging else { return }
        workspace.isManaging = true
        defer { workspace.isManaging = false }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = L10n.text("Recovery Copies")
            sheet.contentViewController = NSHostingController(rootView: RecoverySheet(store: store, restore: { entry in
                let snapshot = try await store.load(entry.url)
                let tab = workspace.installRecovery(snapshot, title: entry.title)
                // Make the recovered draft durable before removing its source copy.
                await tab.session.recovery?.flush()
                if tab.session.recoveryError == nil {
                    do { try await store.remove(entry.url) }
                    catch { tab.session.recoveryError = error.localizedDescription }
                }
            }, close: {
                window.endSheet(sheet); sheet.orderOut(nil); sheet.contentViewController = nil
                continuation.resume()
            }))
            window.beginSheet(sheet)
        }
    }
}
