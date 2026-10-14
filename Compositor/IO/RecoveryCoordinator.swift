import Foundation

@MainActor
final class RecoveryCoordinator {
    private struct Checkpoint {
        let snapshot: ProjectSnapshot
        let record: RecoveryRecord
    }
    weak var session: EditorSession?
    let store: RecoveryStore
    let title: String
    let delay: Duration
    let maximumDelay: Duration
    private var timer: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var writing: Task<Bool, Never>?
    private var pending: [UUID: Checkpoint] = [:]
    private var lastWritten: [UUID: UUID] = [:]
    init(session: EditorSession, title: String, store: RecoveryStore = .shared,
         delay: Duration = .seconds(2), maximumDelay: Duration = .seconds(10)) {
        self.session = session; self.title = title; self.store = store
        self.delay = delay; self.maximumDelay = max(delay, maximumDelay)
    }
    deinit { timer?.cancel(); deadline?.cancel() }
    /// Called at a completed history boundary. Retain immutable committed values even if the next gesture starts.
    func schedule() {
        captureCommitted()
        guard !pending.isEmpty else { return }
        timer?.cancel()
        timer = Task { [weak self, delay] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.writePending()
        }
        if deadline == nil {
            deadline = Task { [weak self, maximumDelay] in
                do { try await Task.sleep(for: maximumDelay) } catch { return }
                await self?.writePending()
            }
        }
    }

    private func captureCommitted() {
        let started = PerformanceRecorder.shared.begin()
        defer { PerformanceRecorder.shared.end(.recoveryCapture, since: started) }
        guard let session, !session.history.hasPendingEdit, let snapshot = session.projectSnapshot() else { return }
        let id = snapshot.manifest.documentID
        guard session.isModified || lastWritten[id] != nil || pending[id] != nil else { return }
        let revision = session.history.currentRevision
        if writing == nil && lastWritten[id] == revision {
            pending.removeValue(forKey: id)
            if pending.isEmpty { cancelTimers() }
            return
        }
        pending[id] = Checkpoint(snapshot: snapshot, record: RecoveryRecord(documentID: id,
            revision: revision, projectVersion: snapshot.manifest.version,
            title: session.projectURL?.deletingPathExtension().lastPathComponent ?? title,
            originalPath: session.projectURL?.path, date: Date()))
    }

    private func cancelTimers() {
        timer?.cancel(); timer = nil
        deadline?.cancel(); deadline = nil
    }

    /// Manual flush may capture a stable document; never capture an in-progress preview or gesture.
    func flush() async {
        if let session, !session.isProjectBusy, session.editingRefusal() == nil { captureCommitted() }
        await writePending()
    }

    private func writePending() async {
        while true {
            if let task = writing {
                let succeeded = await task.value
                if writing == task { writing = nil } else { continue }
                if !succeeded { return }
            }
            guard let checkpoint = pending.values.min(by: { $0.record.date < $1.record.date }) else { return }
            pending.removeValue(forKey: checkpoint.record.documentID)
            cancelTimers()
            let task = Task { [store] in
                let documentID = checkpoint.record.documentID
                if session?.document?.id == documentID { session?.recoveryWritingDocumentID = documentID }
                defer { if session?.recoveryWritingDocumentID == documentID { session?.recoveryWritingDocumentID = nil } }
                do {
                    try await store.write(checkpoint.snapshot, record: checkpoint.record)
                    lastWritten[checkpoint.record.documentID] = checkpoint.record.revision
                    if session?.document?.id == checkpoint.record.documentID {
                        session?.recoveryError = nil
                        session?.recoveryProtection = RecoveryProtection(documentID: checkpoint.record.documentID,
                            revision: checkpoint.record.revision, checkpointDate: checkpoint.record.date, completedAt: Date())
                    }
                    return true
                } catch {
                    // Keep the latest committed state available for an explicit retry.
                    if pending[checkpoint.record.documentID] == nil { pending[checkpoint.record.documentID] = checkpoint }
                    if session?.document?.id == checkpoint.record.documentID {
                        session?.recoveryError = L10n.format("Recovery copy could not be saved: %@", error.localizedDescription)
                    }
                    return false
                }
            }
            writing = task
        }
    }
    func finishNormally() async {
        cancelTimers()
        await flush()
        guard pending.isEmpty, let id = session?.document?.id else { return }
        do { try await store.markClosed(id) }
        catch { session?.recoveryError = error.localizedDescription }
    }
}
