import CoreGraphics
import Foundation

/// Allocation identities, without asking a lazy image provider to materialize its pixels.
nonisolated struct RenderResource: Sendable {
    enum ID: Hashable, Sendable { case object(ObjectIdentifier), png(ObjectIdentifier), field(UUID) }
    let id: ID
    let bytes: Int
    static func image(_ image: CGImage) -> Self {
        Self(id: .object(ObjectIdentifier(image)), bytes: image.bytesPerRow * image.height)
    }
    static func asset(_ asset: ImportedImage) -> [Self] {
        (asset.raster?.resources ?? [image(asset.image)]) + [image(asset.thumbnail)]
            + (asset.originalPNG.map { [Self(id: .png(ObjectIdentifier(asset.image)), bytes: $0.count)] } ?? [])
    }
}

/// Cache keys must not keep document images alive just to prevent identity reuse.
nonisolated final class WeakRenderSource: @unchecked Sendable {
    weak var object: AnyObject?
    init(_ object: AnyObject) { self.object = object }
}

/// One LRU for rebuildable CPU images, filter prefixes and GPU surfaces. In-flight callers retain their
/// own values; eviction only releases the cache's reference. Document sources are held weakly by caches.
nonisolated final class RenderCache: @unchecked Sendable {
    enum Kind: Hashable, Sendable { case downsample, piece, filter, texture, stroke, effects, maskPlacement, effectsRecent, subject, hueCube, adjustmentCube }
    struct Key: Hashable, @unchecked Sendable {
        let kind: Kind
        let value: AnyHashable
        init(_ kind: Kind, _ value: some Hashable) { self.kind = kind; self.value = AnyHashable(value) }
    }
    enum Pressure { case normal, warning, critical }
    static let shared = RenderCache()
    private struct Entry {
        let value: Any
        let resources: [RenderResource.ID: Int]
        var used: UInt64
    }
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var allocations: [RenderResource.ID: (references: Int, bytes: Int)] = [:]
    private var clock: UInt64 = 0
    private var bytes = 0
    private var pressure: Pressure = .normal
    let byteLimit: Int
    private var pressureSource: DispatchSourceMemoryPressure?

    init(byteLimit: Int = max(64 * 1024 * 1024, min(512 * 1024 * 1024,
                                                  Int(ProcessInfo.processInfo.physicalMemory / 32))),
         observesPressure: Bool = true) {
        self.byteLimit = max(0, byteLimit)
        if observesPressure {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in
                guard let self, let event = self.pressureSource?.data else { return }
                self.respond(to: event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal)
            }
            pressureSource = source
            source.resume()
        }
    }
    deinit { pressureSource?.cancel() }

    var retainedBytes: Int { lock.withLock { bytes } }
    var count: Int { lock.withLock { entries.count } }
    var currentLimit: Int { lock.withLock { limit } }
    private var limit: Int { pressure == .critical ? 0 : pressure == .warning ? byteLimit / 4 : byteLimit }

    func value<Value>(for key: Key, as: Value.Type = Value.self) -> Value? {
        lock.withLock {
            guard let entry = entries[key] else { return nil }
            clock &+= 1; entries[key]?.used = clock
            return entry.value as? Value
        }
    }
    func insert<Value>(_ value: Value, for key: Key, resources: [RenderResource]) {
        lock.withLock {
            removeLocked(key)
            guard limit > 0 else { return }
            var unique: [RenderResource.ID: Int] = [:]
            for resource in resources where resource.bytes > 0 {
                unique[resource.id] = max(unique[resource.id] ?? 0, resource.bytes)
            }
            // Oversized values can still be returned to a caller, but must not pin the cache above its cap.
            guard unique.values.reduce(0, +) <= limit else { return }
            clock &+= 1
            entries[key] = Entry(value: value, resources: unique, used: clock)
            for (id, cost) in unique {
                if var known = allocations[id] {
                    bytes += max(known.bytes, cost) - known.bytes
                    known.bytes = max(known.bytes, cost); known.references += 1; allocations[id] = known
                } else { allocations[id] = (1, cost); bytes += cost }
            }
            trimLocked()
        }
    }
    func remove(_ key: Key) { lock.withLock { removeLocked(key) } }
    func remove(kind: Kind, where predicate: (Any) -> Bool) {
        lock.withLock {
            let keys = entries.filter { $0.key.kind == kind && predicate($0.value.value) }.map(\.key)
            for key in keys { removeLocked(key) }
        }
    }
    func removeAll() {
        lock.withLock { entries.removeAll(); allocations.removeAll(); bytes = 0 }
        NotificationCenter.default.post(name: .compositorRenderCacheTrimmed, object: nil)
    }
    func respond(to pressure: Pressure) {
        lock.withLock { self.pressure = pressure; trimLocked() }
        if pressure != .normal { NotificationCenter.default.post(name: .compositorRenderCacheTrimmed, object: nil) }
    }
    private func trimLocked() {
        while bytes > limit || entries.count > 512, let key = entries.min(by: { $0.value.used < $1.value.used })?.key { removeLocked(key) }
    }
    private func removeLocked(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        for id in entry.resources.keys {
            guard var allocation = allocations[id] else { continue }
            allocation.references -= 1
            if allocation.references == 0 { bytes -= allocation.bytes; allocations.removeValue(forKey: id) }
            else { allocations[id] = allocation }
        }
    }
}

extension Notification.Name {
    nonisolated static let compositorRenderCacheTrimmed = Notification.Name("CompositorRenderCacheTrimmed")
}
