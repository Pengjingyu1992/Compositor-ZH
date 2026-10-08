import Foundation
import CoreGraphics
import Observation

/// Value snapshots share immutable CGImages; no pixel copies for layer edits.
@Observable
final class DocumentHistory {
    struct Snapshot {
        let document: CanvasDocument?
        let activeLayerID: UUID?
        let revision: UUID
    }
    struct TimelineItem: Identifiable {
        let id: UUID
        let name: String
        let isCurrent: Bool
        let isFuture: Bool
        let isSaved: Bool
    }
    private struct Entry {
        let name: String
        let before: Snapshot
        let after: Snapshot
    }
    private var past: [Entry] = []
    private var future: [Entry] = []
    private var revision = UUID()
    private var savedRevision: UUID?
    private var pending: Snapshot?
    private var pendingName = "Edit"
    private var depth = 0
    private var wasTrimmed = false
    private(set) var droppedLatestUndo = false
    let entryLimit: Int
    let retainedByteLimit: Int

    init(entryLimit: Int = 100, retainedByteLimit: Int = 256 * 1024 * 1024) {
        self.entryLimit = max(0, entryLimit)
        self.retainedByteLimit = max(0, retainedByteLimit)
        savedRevision = revision
    }

    var canUndo: Bool { depth == 0 && !past.isEmpty }
    var canRedo: Bool { depth == 0 && !future.isEmpty }
    var undoName: String { past.last?.name ?? "" }
    var redoName: String { future.last?.name ?? "" }
    var isModified: Bool { revision != savedRevision }
    var undoCount: Int { past.count }
    var hasPendingEdit: Bool { depth > 0 }
    /// Metadata only: the panel shares the existing bounded history snapshots.
    var timeline: [TimelineItem] {
        let entries = past + future.reversed()
        let start = entries.first?.before.revision ?? revision
        return [TimelineItem(id: start, name: wasTrimmed ? "Earlier State" : "Initial State", isCurrent: start == revision,
                             isFuture: false, isSaved: start == savedRevision)]
            + entries.enumerated().map { offset, entry in
                TimelineItem(id: entry.after.revision, name: entry.name, isCurrent: entry.after.revision == revision,
                             isFuture: offset >= past.count, isSaved: entry.after.revision == savedRevision)
            }
    }

    /// Move the boundary once, then trim. Per-step trimming could evict the requested state.
    func jump(to target: UUID) -> Snapshot? {
        guard depth == 0, target != revision else { return nil }
        let entries = past + future.reversed()
        guard let first = entries.first else { return nil }
        let boundary: Int
        if target == first.before.revision { boundary = 0 }
        else if let index = entries.firstIndex(where: { $0.after.revision == target }) { boundary = index + 1 }
        else { return nil }
        let snapshot = boundary == 0 ? first.before : entries[boundary - 1].after
        past = Array(entries.prefix(boundary))
        future = Array(entries.dropFirst(boundary).reversed())
        revision = snapshot.revision
        droppedLatestUndo = false
        trim(current: snapshot.document)
        return snapshot
    }

    /// Validate an outer transaction against its original state before installing history.
    var pendingSnapshot: Snapshot? { pending }
    var editDepth: Int { depth }

    func markSaved() { savedRevision = revision }
    func markUnsaved() { savedRevision = nil }
    /// The document as it stands, for a save that captures it now and finishes later.
    var currentRevision: UUID { revision }
    /// A save of `saved` finished. Edits made while it was writing leave the document modified; undoing back to it doesn't.
    func markSaved(_ saved: UUID) { savedRevision = saved }
    func reset() {
        past.removeAll()
        future.removeAll()
        pending = nil
        depth = 0
        wasTrimmed = false
        droppedLatestUndo = false
        revision = UUID()
        savedRevision = revision
    }

    func begin(_ name: String, document: CanvasDocument?, selection: UUID?) {
        if depth == 0 {
            pending = Snapshot(document: document, activeLayerID: selection, revision: revision)
            pendingName = name
        }
        depth += 1
    }

    func end(document: CanvasDocument?, selection: UUID?) {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0, let before = pending else { return }
        pending = nil
        // Selecting, navigating, and no-op edits must preserve redo history.
        guard before.document != document else { return }
        revision = UUID()
        past.append(Entry(name: pendingName, before: before,
            after: Snapshot(document: document, activeLayerID: selection, revision: revision)))
        future.removeAll()
        trim(current: document)
        droppedLatestUndo = past.last?.after.revision != revision
    }

    func undo() -> Snapshot? {
        guard canUndo, let entry = past.popLast() else { return nil }
        future.append(entry)
        revision = entry.before.revision
        droppedLatestUndo = false
        trim(current: entry.before.document)
        return entry.before
    }

    func redo() -> Snapshot? {
        guard canRedo, let entry = future.popLast() else { return nil }
        past.append(entry)
        revision = entry.after.revision
        droppedLatestUndo = false
        trim(current: entry.after.document)
        return entry.after
    }

    /// Bytes retained only by history, excluding images in the live document.
    func retainedBytes(current: CanvasDocument?) -> Int {
        var seen = Set<ObjectIdentifier>()
        for layer in current?.layers ?? [] {
            for asset in [layer.asset, layer.mask?.asset].compactMap({ $0 }) {
                seen.insert(ObjectIdentifier(asset.image))
                seen.insert(ObjectIdentifier(asset.thumbnail))
            }
        }
        var bytes = 0
        for entry in past + future {
            for snapshot in [entry.before, entry.after] {
                for layer in snapshot.document?.layers ?? [] {
                    for asset in [layer.asset, layer.mask?.asset].compactMap({ $0 }) {
                        for image in [asset.image, asset.thumbnail] where seen.insert(ObjectIdentifier(image)).inserted {
                            bytes += image.bytesPerRow * image.height
                        }
                    }
                }
            }
        }
        return bytes
    }

    private func trim(current: CanvasDocument?) {
        while past.count + future.count > entryLimit || retainedBytes(current: current) > retainedByteLimit {
            if !past.isEmpty { past.removeFirst(); wasTrimmed = true }
            else if !future.isEmpty { future.removeFirst() }
            else { break }
        }
    }
}
