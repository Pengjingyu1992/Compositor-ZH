import Foundation
import Darwin

/// lstat includes inode and nanosecond change time, so replacing a file or restoring its modification date
/// cannot hide an ordinary external edit. No image is decoded or content read to obtain this stamp.
nonisolated struct RecoveryFileStamp: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int
    let mode: UInt16
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    var isDirectory: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
    var isRegular: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFREG) }
    var isSymbolicLink: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFLNK) }
    static func read(_ url: URL) throws -> Self {
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in path.map { lstat($0, &value) } ?? -1 }
        guard result == 0, value.st_size >= 0 else { throw RecoveryError.invalid }
        return Self(device: value.st_dev, inode: value.st_ino, size: Int(clamping: value.st_size), mode: value.st_mode,
            modifiedSeconds: value.st_mtimespec.tv_sec, modifiedNanoseconds: value.st_mtimespec.tv_nsec,
            changedSeconds: value.st_ctimespec.tv_sec, changedNanoseconds: value.st_ctimespec.tv_nsec)
    }
    /// A link operation changes ctime. Require the validated data identity and mtime to survive that operation.
    func sameData(as other: Self) -> Bool {
        device == other.device && inode == other.inode && size == other.size && mode == other.mode
            && modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
    }
}

/// A capacity ledger refreshed with metadata. Directory changes cause a rescan; unchanged package trees
/// only stat their known files. External file growth, replacement and extra files still count toward quota.
nonisolated struct RecoveryFileInventory: Sendable {
    private var files: [URL: RecoveryFileStamp] = [:]
    private var directories: [URL: RecoveryFileStamp] = [:]
    private(set) var bytes = 0
    static func scan(_ root: URL) throws -> Self {
        var result = Self()
        let stamp = try RecoveryFileStamp.read(root)
        guard stamp.isDirectory, !stamp.isSymbolicLink else { throw RecoveryError.invalid }
        result.directories[root] = stamp
        var enumerationError: Error?
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, errorHandler: { _, error in
            enumerationError = error; return false
        }) else { throw RecoveryError.invalid }
        for case let file as URL in iterator {
            try Task.checkCancellation()
            let stamp = try RecoveryFileStamp.read(file)
            if stamp.isDirectory { result.directories[file] = stamp }
            else {
                if stamp.isSymbolicLink { iterator.skipDescendants() }
                result.files[file] = stamp; result.bytes += stamp.size
            }
        }
        if let enumerationError { throw enumerationError }
        return result
    }
    mutating func refresh(_ root: URL) throws -> Bool {
        for (directory, known) in directories {
            if (try? RecoveryFileStamp.read(directory)) != known { self = try Self.scan(root); return true }
        }
        for (file, known) in files {
            guard let current = try? RecoveryFileStamp.read(file), current.mode == known.mode else {
                self = try Self.scan(root); return true
            }
            bytes += current.size - known.size; files[file] = current
        }
        return false
    }
    static func committed(_ root: URL, paths: [String]) throws -> Self {
        var result = Self()
        // Empty resource directories must be watched too: adding a file there doesn't change the root's stamp.
        for name in ["", "images", "edits"] {
            let directory = name.isEmpty ? root : root.appendingPathComponent(name, isDirectory: true)
            if let stamp = try? RecoveryFileStamp.read(directory) {
                guard stamp.isDirectory, !stamp.isSymbolicLink else { throw RecoveryError.invalid }
                result.directories[directory] = stamp
            } else if name != "edits" { throw RecoveryError.invalid }
        }
        for path in paths {
            let file = root.appendingPathComponent(path)
            let stamp = try RecoveryFileStamp.read(file)
            guard stamp.isRegular, !stamp.isSymbolicLink else { throw RecoveryError.invalid }
            result.files[file] = stamp; result.bytes += stamp.size
            var directory = file.deletingLastPathComponent()
            while true {
                if result.directories[directory] == nil { result.directories[directory] = try RecoveryFileStamp.read(directory) }
                if directory == root { break }
                guard directory.path.hasPrefix(root.path + "/") else { throw RecoveryError.invalid }
                directory.deleteLastPathComponent()
            }
        }
        return result
    }
}
