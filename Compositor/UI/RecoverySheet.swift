import SwiftUI
import AppKit

struct RecoverySheet: View {
    let store: RecoveryStore
    let restore: (RecoveryEntry) async throws -> Void
    let close: () -> Void
    @State private var entries: [RecoveryEntry] = []
    @State private var selectedIDs: Set<RecoveryEntry.ID> = []
    @State private var error: String?
    @State private var busy = false
    @State private var deleting: [RecoveryEntry]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recovery Copies").font(.title2.bold())
            Text("Copies are stored locally and do not replace your saved projects. Recovering opens an unsaved draft in a new tab.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(L10n.format("%lld recovery copies · Limit: %lld", entries.count, store.recordLimit))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !selectedIDs.isEmpty {
                    Text(L10n.format("%lld copies selected", selectedIDs.count))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Button("Select All") { selectedIDs = Set(entries.map(\.id)) }
                    .keyboardShortcut("a", modifiers: .command)
                    .disabled(entries.isEmpty)
                Button("Deselect All") { selectedIDs.removeAll() }
                    .disabled(selectedIDs.isEmpty)
            }
            List(entries) { entry in
                recoveryRow(entry)
            }.frame(minHeight: 240)
            if entries.isEmpty { Text("No recovery copies are available.").foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("Up to 32 documents and 4 GB. Existing copies are kept when storage is full.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Delete Selected Copies", role: .destructive) {
                    deleting = entries.filter { selectedIDs.contains($0.id) }
                }.disabled(selectedIDs.isEmpty)
                Button("Close", action: close).configuredNativeShortcut(.escape)
            }
        }
        .padding(20).frame(width: 620).disabled(busy)
        .task { await refresh() }
        .alert(deletionTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
               presenting: deleting) { targets in
            Button("Cancel", role: .cancel) {}
            Button(role: .destructive) { delete(targets) } label: {
                if targets.count == 1 { Text("Delete Recovery Copy") }
                else { Text("Delete Selected Copies") }
            }
        } message: { targets in
            if targets.count == 1 {
                Text("This permanently removes the selected recovery copy. Your open document and saved projects are unchanged.")
            } else {
                Text("This permanently removes the selected recovery copies. Your open documents and saved projects are unchanged.")
            }
        }
    }

    private func recoveryRow(_ entry: RecoveryEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(get: { selectedIDs.contains(entry.id) }, set: { selected in
                if selected { selectedIDs.insert(entry.id) }
                else { selectedIDs.remove(entry.id) }
            })) {
                Text(entry.title)
            }
            .toggleStyle(.checkbox).labelsHidden().padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.title).font(.headline)
                if let record = entry.record {
                    Text(record.date, format: .dateTime.year().month().day().hour().minute().second()).foregroundStyle(.secondary)
                }
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
                    Button("Delete Recovery Copy", role: .destructive) { deleting = [entry] }
                }
            }
        }.padding(.vertical, 6)
    }

    private var deletionTitle: String {
        guard let deleting, deleting.count > 1 else { return L10n.text("Delete this recovery copy?") }
        return L10n.format("Delete %lld recovery copies?", deleting.count)
    }

    private func delete(_ targets: [RecoveryEntry]) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            var removed = Set<RecoveryEntry.ID>()
            var failures: [String] = []
            for entry in targets {
                do {
                    try await store.remove(entry.url)
                    removed.insert(entry.id)
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            // Keep successful removals out of the list even if reloading it fails.
            entries.removeAll { removed.contains($0.id) }
            selectedIDs.subtract(removed)
            await refresh()
            if let failure = failures.first {
                error = targets.count == 1 ? failure
                    : L10n.format("Could not delete %lld of %lld recovery copies.", failures.count, targets.count)
            }
        }
    }

    private func refresh() async {
        do {
            entries = try await store.entries()
            selectedIDs.formIntersection(entries.map(\.id))
        }
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
        await workspace.retryFailedRecoveryCopies()
    }
}
