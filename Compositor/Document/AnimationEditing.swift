import Foundation
import CoreGraphics

extension EditorSession {
    func animationFrame(containing id: UUID) -> UUID? {
        guard let document, let animation = document.animation else { return nil }
        let groups = Set(animation.frames.map(\.groupID))
        var current: UUID? = id, seen = Set<UUID>()
        while let next = current, seen.insert(next).inserted {
            if groups.contains(next) { return next }
            current = document.layers.first(where: { $0.id == next })?.parentID
        }
        return nil
    }

    func selectAnimationFrame(_ id: UUID) {
        guard canEditLayers, !history.hasPendingEdit, document?.animation?.frames.contains(where: { $0.groupID == id }) == true else { return }
        document?.displayedAnimationFrameID = id
        activeLayerID = document?.layers.last(where: { $0.parentID == id && !$0.isGroup })?.id ?? id
        revealActiveLayer()
    }

    func startAnimation() {
        guard canEditLayers, !history.hasPendingEdit, var candidate = document, candidate.animation == nil else { return }
        guard candidate.width * candidate.height <= AnimationTrack.maxFramePixels, candidate.layers.count < 10_000 else {
            importError = ImageImportError.gifTooLarge.localizedDescription; return
        }
        var group = ImageLayer(name: L10n.format("Frame %lld", 1), blankSize: candidate.size)
        group.isGroup = true
        for i in candidate.layers.indices where candidate.layers[i].parentID == nil { candidate.layers[i].parentID = group.id }
        candidate.layers.insert(group, at: 0)
        candidate.animation = AnimationTrack(frames: [AnimationFrame(groupID: group.id, durationMS: 100)])
        candidate.displayedAnimationFrameID = group.id
        beginEdit("Create Animation"); document = candidate; endEdit()
        selectAnimationFrame(group.id)
    }

    func insertGIF(_ gif: GIFImport, centeredAt point: CGPoint?) throws {
        var candidate = document ?? CanvasDocument(width: gif.width, height: gif.height)
        var track = candidate.animation ?? AnimationTrack(frames: [], loopCount: gif.loopCount)
        guard track.frames.count + gif.frames.count <= AnimationTrack.maxFrames,
              candidate.width * candidate.height <= AnimationTrack.maxFramePixels,
              candidate.width * candidate.height * (track.frames.count + gif.frames.count) <= AnimationTrack.maxPixels,
              candidate.layers.count + gif.frames.count * 2 <= 10_000 else { throw ImageImportError.gifTooLarge }
        let center = point ?? CGPoint(x: candidate.width / 2, y: candidate.height / 2)
        var first: UUID?
        for (index, asset) in gif.frames.enumerated() {
            var group = ImageLayer(name: L10n.format("Frame %lld", track.frames.count + 1), blankSize: candidate.size)
            group.isGroup = true
            var layer = ImageLayer(asset: asset, origin: CGPoint(x: floor(center.x - CGFloat(gif.width) / 2), y: floor(center.y - CGFloat(gif.height) / 2)))
            layer.parentID = group.id
            candidate.layers += [group, layer]
            track.frames.append(AnimationFrame(groupID: group.id, durationMS: gif.durations[index]))
            first = first ?? group.id
        }
        candidate.animation = track
        candidate.displayedAnimationFrameID = first
        try track.validate(layers: candidate.layers.map(\.hierarchyRecord))
        guard Self.fitsFilterResources(candidate.layers) else { throw ProjectError.tooLarge }
        let fit = document == nil
        document = candidate
        activeLayerID = first.flatMap { id in candidate.layers.first(where: { $0.parentID == id })?.id }
        if fit { viewport.fit(documentSize: candidate.size) }
    }

    func changeAnimationTiming(duration: Int? = nil, loops: Int? = nil) {
        guard canEditLayers, !history.hasPendingEdit, var track = document?.animation else { return }
        if let duration, let index = track.frames.firstIndex(where: { $0.groupID == document?.currentAnimationFrameID }) {
            let bounded = min(655350, max(10, duration))
            track.frames[index].durationMS = ((bounded + 5) / 10) * 10
        }
        if let loops { track.loopCount = min(65535, max(-1, loops)) }
        beginEdit("Animation Timing"); document?.animation = track; endEdit()
    }

    func addAnimationFrame(duplicate: Bool) {
        guard canEditLayers, !history.hasPendingEdit, var candidate = document, var track = candidate.animation,
              let current = candidate.currentAnimationFrameID, let index = track.frames.firstIndex(where: { $0.groupID == current }) else { return }
        guard track.frames.count < AnimationTrack.maxFrames, candidate.width * candidate.height <= AnimationTrack.maxFramePixels,
              candidate.width * candidate.height * (track.frames.count + 1) <= AnimationTrack.maxPixels else {
            importError = ImageImportError.gifTooLarge.localizedDescription; return
        }
        let ids = descendantIDs(of: current).union([current])
        let original = candidate.layers.filter { ids.contains($0.id) }
        var added: [ImageLayer] = []
        let groupID: UUID
        if duplicate {
            let map = Dictionary(uniqueKeysWithValues: original.map { ($0.id, UUID()) })
            groupID = map[current]!
            for old in original {
                added.append(ImageLayer(id: map[old.id]!, asset: old.asset, name: old.id == current ? L10n.format("Frame %lld", index + 2) : old.name,
                    isVisible: old.isVisible, transform: old.transform, parentID: old.parentID.flatMap { map[$0] ?? $0 }, isGroup: old.isGroup,
                    opacity: old.opacity, blendMode: old.blendMode, mask: old.mask, maskSourceID: old.maskSourceID.flatMap { map[$0] ?? $0 },
                    adjustment: old.adjustment, shape: old.shape, effects: old.effects, text: old.text, fill: old.fill, filterStack: old.filterStack))
            }
        } else {
            var group = ImageLayer(name: L10n.format("Frame %lld", index + 2), blankSize: candidate.size); group.isGroup = true
            groupID = group.id
            var layer = ImageLayer(name: L10n.text("Layer"), blankSize: candidate.size); layer.parentID = group.id
            added = [group, layer]
        }
        guard candidate.layers.count + added.count <= 10_000, Self.fitsFilterResources(candidate.layers + added) else {
            importError = ProjectError.tooLarge.localizedDescription; return
        }
        let insertion = (candidate.layers.lastIndex(where: { ids.contains($0.id) }) ?? -1) + 1
        candidate.layers.insert(contentsOf: added, at: insertion)
        track.frames.insert(AnimationFrame(groupID: groupID, durationMS: track.frames[index].durationMS), at: index + 1)
        candidate.animation = track; candidate.displayedAnimationFrameID = groupID
        beginEdit(duplicate ? "Duplicate Animation Frame" : "New Animation Frame"); document = candidate; endEdit()
        selectAnimationFrame(groupID)
    }

    func removeAnimationFrame() {
        guard canEditLayers, !history.hasPendingEdit, var candidate = document, var track = candidate.animation, track.frames.count > 1,
              let id = candidate.currentAnimationFrameID, let index = track.frames.firstIndex(where: { $0.groupID == id }) else { return }
        let ids = descendantIDs(of: id).union([id])
        guard ids.allSatisfy({ effectiveLocks(for: $0).isEmpty }) else { return }
        candidate.layers.removeAll { ids.contains($0.id) }
        track.frames.remove(at: index); candidate.animation = track
        let next = track.frames[min(index, track.frames.count - 1)].groupID
        candidate.displayedAnimationFrameID = next
        beginEdit("Delete Animation Frame"); document = candidate; activeLayerID = next; endEdit()
        selectAnimationFrame(next)
    }

    func moveAnimationFrame(_ direction: Int) {
        guard canEditLayers, !history.hasPendingEdit, var track = document?.animation,
              let index = track.frames.firstIndex(where: { $0.groupID == document?.currentAnimationFrameID }),
              track.frames.indices.contains(index + direction) else { return }
        track.frames.swapAt(index, index + direction)
        beginEdit("Reorder Animation Frames"); document?.animation = track; endEdit()
    }

    func stopAnimation() {
        guard animationPlaying else { return }
        animationPlaying = false
        if let owner = activeEditOwner { releaseEdit(owner) }
        if let id = document?.currentAnimationFrameID { selectAnimationFrame(id) }
    }

    func playAnimation() async {
        if animationPlaying { stopAnimation(); return }
        guard canEditLayers, !history.hasPendingEdit, activeEditOwner == nil, let document, let track = document.animation else { return }
        let owner = EditOwner(documentID: document.id, revision: history.currentRevision)
        activeEditOwner = owner; animationPlaying = true
        defer { if activeEditOwner == owner { stopAnimation() } }
        var cycle = 0
        repeat {
            for frame in track.frames {
                guard animationPlaying, ownsEdit(owner), !Task.isCancelled else { return }
                self.document?.displayedAnimationFrameID = frame.groupID
                do { try await Task.sleep(for: .milliseconds(frame.durationMS)) } catch { return }
            }
            cycle += 1
        } while track.loopCount == 0 || (track.loopCount > 0 && cycle <= track.loopCount)
    }
}
