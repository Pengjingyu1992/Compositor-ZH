import Foundation

nonisolated enum RecoveryError: LocalizedError {
    case version, invalid, capacity
    var errorDescription: String? {
        switch self {
        case .version: L10n.text("This recovery copy uses an unsupported version. The files have been kept.")
        case .invalid: L10n.text("This recovery copy is damaged. The files have been kept.")
        case .capacity: L10n.text("Recovery storage is full. Review recovery copies to free space; existing copies have been kept.")
        }
    }
}

nonisolated struct RecoveryRecord: Codable, Equatable, Sendable {
    static let current = 1
    var version = Self.current
    let documentID: UUID
    let revision: UUID
    let projectVersion: Int
    let title: String
    let originalPath: String?
    let date: Date
    var closedNormally = false
}

nonisolated struct RecoveryEntry: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let record: RecoveryRecord?
    let error: String?
    var title: String { record?.title ?? url.deletingPathExtension().lastPathComponent }
}

/// Recovery metadata and the project are replaced in the same atomic package write.
/// Unsupported and damaged copies are listed for review, never silently removed.
actor RecoveryStore {
    static let shared = RecoveryStore()
    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.wonderassembly.compositor.zh-Hans/Recovery", isDirectory: true)
    }
    let directory: URL
    let byteLimit: Int
    let recordLimit: Int
    private var writing: Task<Void, Error>?
    init(directory: URL = RecoveryStore.defaultDirectory, byteLimit: Int = 4 * 1024 * 1024 * 1024, recordLimit: Int = 32) {
        self.directory = directory; self.byteLimit = byteLimit; self.recordLimit = recordLimit
    }
    private func packages() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).filter {
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return $0.pathExtension == "comp" && values?.isDirectory == true && values?.isSymbolicLink != true
            }
    }
    private func validateLocation(_ url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              url.pathExtension == "comp", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw RecoveryError.invalid }
    }
    private func metadata(_ url: URL) throws -> RecoveryRecord {
        try validateLocation(url)
        let file = url.appendingPathComponent("recovery.json")
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= 65_536 else { throw RecoveryError.invalid }
        let record = try JSONDecoder().decode(RecoveryRecord.self, from: Data(contentsOf: file))
        guard record.documentID.uuidString == url.deletingPathExtension().lastPathComponent else { throw RecoveryError.invalid }
        return record
    }
    func entries() throws -> [RecoveryEntry] {
        try packages().map { url in
            do {
                let record = try metadata(url)
                let supported = record.version == RecoveryRecord.current && ProjectManifest.supported.contains(record.projectVersion)
                return RecoveryEntry(url: url, record: record, error: supported ? nil : RecoveryError.version.localizedDescription)
            } catch { return RecoveryEntry(url: url, record: nil, error: RecoveryError.invalid.localizedDescription) }
        }.sorted { ($0.record?.date ?? .distantPast) > ($1.record?.date ?? .distantPast) }
    }
    private func bytes(in url: URL) -> Int {
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total = 0
        for case let file as URL in files {
            if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true {
                total += values.fileSize ?? 0
            }
        }
        return total
    }
    func write(_ snapshot: ProjectSnapshot, record: RecoveryRecord) async throws {
        let previous = writing
        let task = Task {
            if let previous { _ = try? await previous.value }
            try await self.performWrite(snapshot, record: record)
        }
        writing = task
        defer { if writing == task { writing = nil } }
        try await task.value
    }
    private func performWrite(_ snapshot: ProjectSnapshot, record: RecoveryRecord) async throws {
        guard record.version == RecoveryRecord.current, record.documentID == snapshot.manifest.documentID,
              record.projectVersion == snapshot.manifest.version else { throw RecoveryError.invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(record.documentID.uuidString + ".comp", isDirectory: true)
        try validateLocation(url)
        let existing = try packages()
        guard existing.contains(where: { $0.lastPathComponent == url.lastPathComponent }) || existing.count < recordLimit else { throw RecoveryError.capacity }
        if existing.contains(where: { $0.lastPathComponent == url.lastPathComponent }) {
            // A future or damaged copy must not be overwritten by a later automatic save.
            do {
                let previous = try metadata(url)
                guard previous.version == RecoveryRecord.current,
                      ProjectManifest.supported.contains(previous.projectVersion) else { throw RecoveryError.version }
                _ = try await ProjectStore.shared.load(from: url)
            } catch {
                if let known = error as? RecoveryError { throw known }
                throw RecoveryError.invalid
            }
        }
        let available = byteLimit - existing.filter { $0.lastPathComponent != url.lastPathComponent }.reduce(0) { $0 + bytes(in: $1) }
        guard available > 0 else { throw RecoveryError.capacity }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try await ProjectStore.shared.save(snapshot, to: url, recoveryMetadata: encoder.encode(record), maximumPackageBytes: available)
    }
    func load(_ url: URL) async throws -> ProjectSnapshot {
        let record = try metadata(url)
        guard record.version == RecoveryRecord.current else { throw RecoveryError.version }
        let snapshot = try await ProjectStore.shared.load(from: url)
        guard snapshot.manifest.documentID == record.documentID else { throw RecoveryError.invalid }
        return snapshot
    }
    func markClosed(_ documentID: UUID) throws {
        let url = directory.appendingPathComponent(documentID.uuidString + ".comp", isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var record = try metadata(url)
        guard record.version == RecoveryRecord.current else { throw RecoveryError.version }
        record.closedNormally = true
        try JSONEncoder().encode(record).write(to: url.appendingPathComponent("recovery.json"), options: .atomic)
    }
    func remove(_ url: URL) throws {
        try validateLocation(url)
        try FileManager.default.removeItem(at: url)
    }
}
