import Foundation
import CoreGraphics
import CryptoKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

nonisolated struct RecoveryWriteStatistics: Sendable {
    var encodedImages = 0
    var reusedFiles = 0
    var writtenBytes = 0
    var packageBytes = 0
    var readBytes = 0
    var hashedFiles = 0
    var checkedFiles = 0
    var scannedPackages = 0
    var elapsedMilliseconds = 0.0
    var inventory: RecoveryFileInventory?
}

/// Resources are immutable once committed. Weak image identities avoid retaining a second document in memory.
actor RecoveryResources {
    private let beforeCommit: @Sendable () throws -> Void
    init(beforeCommit: @escaping @Sendable () throws -> Void = {}) { self.beforeCommit = beforeCommit }
    private final class Resource {
        weak var image: CGImage?
        let digest: SHA256.Digest
        let bytes: Int
        var stamp: RecoveryFileStamp?
        init(data: Data, image: CGImage? = nil) {
            self.image = image; digest = SHA256.hash(data: data); bytes = data.count
        }
    }
    private var indices: [URL: [String: Resource]] = [:]

    func forget(_ url: URL) { indices.removeValue(forKey: url) }

    /// Hash on a changed stamp; unchanged immutable files only need metadata checks. Cold copies still
    /// use the complete project loader. ctime catches same-size edits even when mtime is restored.
    func validateExisting(_ url: URL) async throws -> RecoveryWriteStatistics {
        var stats = RecoveryWriteStatistics()
        if let index = indices[url] {
            for (path, resource) in index {
                try Task.checkCancellation()
                let file = url.appendingPathComponent(path)
                try checkFile(file, package: url, bytes: resource.bytes)
                let stamp = try RecoveryFileStamp.read(file); stats.checkedFiles += 1
                if resource.stamp != stamp {
                    let digest = try autoreleasepool { SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)) }
                    stats.readBytes += resource.bytes; stats.hashedFiles += 1
                    guard digest == resource.digest, try RecoveryFileStamp.read(file) == stamp else { throw RecoveryError.invalid }
                    resource.stamp = stamp
                }
            }
        } else {
            _ = try await ProjectStore.shared.load(from: url)
            // Cold-read accounting estimates package bytes; unreferenced files can make this exceed actual reads.
            stats.readBytes = try RecoveryFileInventory.scan(url).bytes - RecoveryFileStamp.read(url.appendingPathComponent("recovery.json")).size
        }
        return stats
    }

    func write(_ snapshot: ProjectSnapshot, to url: URL, metadata: Data,
               maximumBytes: Int) async throws -> RecoveryWriteStatistics {
        try Task.checkCancellation()
        let started = DispatchTime.now().uptimeNanoseconds
        let timing = PerformanceRecorder.shared.begin()
        defer { PerformanceRecorder.shared.end(.recoveryWrite, since: timing) }
        try await ProjectStore.shared.validateSnapshot(snapshot)
        let previous = indices[url] ?? [:]
        let fm = FileManager.default
        let stage = url.deletingLastPathComponent().appendingPathComponent(
            ".\(snapshot.manifest.documentID.uuidString).\(UUID().uuidString).recovery-stage", isDirectory: true)
        try fm.createDirectory(at: stage.appendingPathComponent("images"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        var next: [String: Resource] = [:]
        var stats = RecoveryWriteStatistics()

        func admit(_ bytes: Int) throws {
            guard bytes <= maximumBytes - stats.packageBytes else { throw RecoveryError.capacity }
            stats.packageBytes += bytes
        }
        func reuse(_ path: String, resource: Resource) throws {
            try Task.checkCancellation()
            let source = url.appendingPathComponent(path)
            let before = try RecoveryFileStamp.read(source)
            guard before == resource.stamp else { throw RecoveryError.invalid }
            try admit(resource.bytes)
            let target = stage.appendingPathComponent(path)
            try fm.linkItem(at: source, to: target)
            let after = try RecoveryFileStamp.read(target)
            guard before.sameData(as: after) else { throw RecoveryError.invalid }
            resource.stamp = after
            next[path] = resource; stats.reusedFiles += 1
        }
        func writeData(_ data: Data, path: String, image: CGImage? = nil) throws {
            let resource = Resource(data: data, image: image)
            if image == nil, let old = previous[path], old.digest == resource.digest {
                try reuse(path, resource: old); return
            }
            try admit(data.count)
            try data.write(to: stage.appendingPathComponent(path), options: .atomic)
            resource.stamp = try RecoveryFileStamp.read(stage.appendingPathComponent(path))
            next[path] = resource; stats.writtenBytes += data.count
        }
        func writeImage(_ asset: ImportedImage, path: String) throws {
            try Task.checkCancellation()
            if let old = previous[path], old.image === asset.image { try reuse(path, resource: old); return }
            let data: Data = try autoreleasepool {
                let bytes = NSMutableData()
                guard let encoder = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { throw ProjectError.encode }
                CGImageDestinationAddImage(encoder, asset.image, nil)
                guard CGImageDestinationFinalize(encoder), bytes.length <= 512 * 1024 * 1024 else { throw ProjectError.encode }
                return bytes as Data
            }
            try Task.checkCancellation()
            try writeData(data, path: path, image: asset.image)
            stats.encodedImages += 1
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var nodeBytes = 0
        for layer in snapshot.manifest.layers {
            try Task.checkCancellation()
            if let file = layer.imageFile, let asset = snapshot.images[layer.id] {
                try writeImage(asset, path: "images/" + file)
            }
            if let file = layer.maskFile, let asset = snapshot.masks[layer.id] {
                try writeImage(asset, path: "images/" + file)
            }
            if let record = layer.editableFilters, let stack = snapshot.filterStacks[layer.id] {
                try fm.createDirectory(at: stage.appendingPathComponent("edits"), withIntermediateDirectories: true)
                try writeImage(stack.source, path: "edits/" + record.sourceFile)
                for (node, file) in zip(stack.nodes, record.nodeFiles) {
                    try Task.checkCancellation()
                    let data = try encoder.encode(node)
                    nodeBytes += data.count
                    guard data.count <= 192 * 1024 * 1024, nodeBytes <= 384 * 1024 * 1024 else { throw ProjectError.tooLarge }
                    try writeData(data, path: "edits/" + file)
                }
            }
        }
        let manifest = try encoder.encode(snapshot.manifest)
        guard manifest.count <= 4 * 1024 * 1024, metadata.count <= 65_536 else { throw ProjectError.tooLarge }
        try writeData(manifest, path: "manifest.json")
        try admit(metadata.count)
        try metadata.write(to: stage.appendingPathComponent("recovery.json"), options: .atomic)
        stats.writtenBytes += metadata.count
        try Task.checkCancellation()
        for (path, resource) in next {
            guard try RecoveryFileStamp.read(stage.appendingPathComponent(path)) == resource.stamp else { throw RecoveryError.invalid }
        }
        // An interrupted write leaves a complete old or new package at the public path.
        try beforeCommit()
        var coordinationError: NSError?, writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { destination in
            do { try Self.commit(stage: stage, destination: destination) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError as NSError? { throw error }
        // Removing the exchanged old package changes hardlink ctimes again. Refresh stamps after our own cleanup.
        try? fm.removeItem(at: stage)
        for (path, resource) in next { resource.stamp = try RecoveryFileStamp.read(url.appendingPathComponent(path)) }
        indices[url] = next
        stats.inventory = try RecoveryFileInventory.committed(url, paths: Array(next.keys) + ["recovery.json"])
        stats.elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        // RecoveryStore bounds the number of packages; keep this cache bounded even when sharing a writer in tests.
        if indices.count > 32, let key = indices.keys.first(where: { $0 != url }) { indices.removeValue(forKey: key) }
        return stats
    }

    private func checkFile(_ file: URL, package: URL, bytes: Int) throws {
        let root = package.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root),
              (try package.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw RecoveryError.invalid }
        let directory = file.deletingLastPathComponent()
        guard (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw RecoveryError.invalid }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == bytes else { throw RecoveryError.invalid }
    }

    private nonisolated static func commit(stage: URL, destination: URL) throws {
        let exists = FileManager.default.fileExists(atPath: destination.path)
        let result = stage.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                renameatx_np(AT_FDCWD, from!, AT_FDCWD, to!, exists ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL))
            }
        }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Staging directories are private to this writer. Only discard remnants after the committed copy validates.
    func removeInterruptedStages(beside url: URL) throws {
        let prefix = "." + url.deletingPathExtension().lastPathComponent + "."
        for file in try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let name = file.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(".recovery-stage"),
                  UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(".recovery-stage".count))) != nil else { continue }
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true && values.isSymbolicLink != true { try FileManager.default.removeItem(at: file) }
        }
    }
}
