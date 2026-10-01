import Foundation

@MainActor
final class RecoveryCoordinator {
    weak var session: EditorSession?
    let store: RecoveryStore
    let title: String
    let delay: Duration
    private var timer: Task<Void, Never>?
    private var writing: Task<Void, Error>?
    private var lastWritten: (document: UUID, revision: UUID)?
    init(session: EditorSession, title: String, store: RecoveryStore = .shared, delay: Duration = .seconds(2)) {
        self.session = session; self.title = title; self.store = store; self.delay = delay
    }
    deinit { timer?.cancel() }
    func schedule() {
        timer?.cancel()
        timer = Task { [weak self] in
            guard let delay = self?.delay else { return }
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self, let session = self.session else { return }
            if session.history.hasPendingEdit || session.isProjectBusy || session.editingRefusal() != nil {
                self.schedule(); return
            }
            await self.flush()
        }
    }
    /// Captures values on the main actor; all PNG encoding and disk work happens in the stores.
    func flush() async {
        if let writing { _ = try? await writing.value }
        guard let session, !session.history.hasPendingEdit, !session.isProjectBusy,
              session.isModified || lastWritten != nil, let snapshot = session.projectSnapshot() else { return }
        let revision = session.history.currentRevision
        if lastWritten?.document == snapshot.manifest.documentID && lastWritten?.revision == revision { return }
        let record = RecoveryRecord(documentID: snapshot.manifest.documentID, revision: revision,
            projectVersion: snapshot.manifest.version,
            title: session.projectURL?.deletingPathExtension().lastPathComponent ?? title,
            originalPath: session.projectURL?.path, date: Date())
        let task = Task { try await store.write(snapshot, record: record) }
        writing = task
        do {
            try await task.value
            lastWritten = (record.documentID, record.revision)
            if session.document?.id == record.documentID { session.recoveryError = nil }
        } catch {
            if session.document?.id == record.documentID {
                session.recoveryError = L10n.format("Recovery copy could not be saved: %@", error.localizedDescription)
            }
        }
        if writing == task { writing = nil }
    }
    func finishNormally() async {
        timer?.cancel(); timer = nil
        if let writing { _ = try? await writing.value }
        guard let id = session?.document?.id else { return }
        do { try await store.markClosed(id) }
        catch { session?.recoveryError = error.localizedDescription }
    }
}
