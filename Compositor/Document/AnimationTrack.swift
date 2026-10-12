import Foundation

/// Each frame owns a root folder. Layers outside those folders are shared by all frames.
nonisolated struct AnimationFrame: Codable, Equatable, Sendable, Identifiable {
    var groupID: UUID
    var durationMS: Int
    var id: UUID { groupID }
}

nonisolated struct AnimationTrack: Codable, Equatable, Sendable {
    static let maxFrames = 500
    static let maxFramePixels = 16_000_000
    static let maxPixels = 64_000_000
    var frames: [AnimationFrame]
    /// GIF Netscape repeat value: -1 has no extension (once), 0 repeats forever.
    var loopCount: Int = 0

    func validate(layers: [ProjectLayerRecord]) throws {
        let roots = Set(layers.filter { $0.isGroup == true && $0.parentID == nil }.map(\.id))
        guard (1...Self.maxFrames).contains(frames.count), (-1...65535).contains(loopCount),
              Set(frames.map(\.groupID)).count == frames.count,
              frames.allSatisfy({ roots.contains($0.groupID) && (10...655350).contains($0.durationMS) && $0.durationMS % 10 == 0 })
        else { throw ProjectError.invalid }
        // A clipping relationship cannot borrow a source from a different frame.
        let byID = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })
        let groups = Set(frames.map(\.groupID))
        func frame(_ id: UUID) -> UUID? {
            var current: UUID? = id
            var seen = Set<UUID>()
            while let next = current, seen.insert(next).inserted {
                if groups.contains(next) { return next }
                current = byID[next]?.parentID
            }
            return nil
        }
        for layer in layers {
            if let source = layer.maskSourceID, frame(source) != frame(layer.id) { throw ProjectError.invalid }
        }
    }

    func hiddenGroups(showing id: UUID?) -> Set<UUID> {
        let shown = frames.first(where: { $0.groupID == id })?.groupID ?? frames.first?.groupID
        return Set(frames.map(\.groupID).filter { $0 != shown })
    }
}

extension CanvasDocument {
    var currentAnimationFrameID: UUID? {
        animation?.frames.first(where: { $0.groupID == displayedAnimationFrameID })?.groupID ?? animation?.frames.first?.groupID
    }
}

nonisolated extension ProjectSnapshot {
    func presentingAnimationFrame(_ id: UUID?) -> ProjectSnapshot {
        guard let animation = manifest.animation else { return self }
        var manifest = manifest
        var selected = id ?? displayedAnimationFrameID
        if selected == nil {
            let groups = Set(animation.frames.map(\.groupID))
            let byID = Dictionary(uniqueKeysWithValues: manifest.layers.map { ($0.id, $0) })
            var current = manifest.activeLayerID, seen = Set<UUID>()
            while let next = current, seen.insert(next).inserted {
                if groups.contains(next) { selected = next; break }
                current = byID[next]?.parentID
            }
        }
        let hidden = animation.hiddenGroups(showing: selected)
        for i in manifest.layers.indices where hidden.contains(manifest.layers[i].id) { manifest.layers[i].isVisible = false }
        manifest.animation = nil
        return ProjectSnapshot(manifest: manifest, images: images, masks: masks, filterStacks: filterStacks)
    }
}
