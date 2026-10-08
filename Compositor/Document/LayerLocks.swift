import AppKit

/// Session state: locks do not change the project format or its saved revision.
nonisolated struct LayerLocks: OptionSet, Sendable {
    let rawValue: Int
    static let all = Self(rawValue: 1)
    static let content = Self(rawValue: 2)
    static let position = Self(rawValue: 4)
    static let appearance = Self(rawValue: 8)
    static let transparency = Self(rawValue: 16)
}

nonisolated enum LayerEditCapability { case content, position, appearance, structure }

extension EditorSession {
    var canRenameActiveLayer: Bool {
        canEditLayers && selectedLayerIDs.count == 1 && activeLayerID.map { !effectiveLocks(for: $0).contains(.all) } == true
    }
    var canGroupSelectedLayers: Bool {
        canEditLayers && (document?.layers.count ?? 10_000) < 10_000
            && (selectedLayerIDs.isEmpty || allowsSelectedLayerEdits(.structure, descendants: true))
    }
    var canDeleteLayerTarget: Bool {
        guard canEditLayers, activeLayer != nil else { return false }
        if selectedEffect != nil { return canEditEffects }
        if isMaskSelected { return canEditMask }
        return allowsSelectedLayerEdits(.structure, descendants: true)
    }

    func effectiveLocks(for id: UUID, in source: CanvasDocument? = nil) -> LayerLocks {
        guard !layerLocks.isEmpty, let source = source ?? document, source.id == lockDocumentID else { return [] }
        let parents = Dictionary(uniqueKeysWithValues: source.layers.map { ($0.id, $0.parentID) })
        var result: LayerLocks = [], current: UUID? = id, visited = Set<UUID>()
        while let next = current, visited.insert(next).inserted {
            result.formUnion(layerLocks[next] ?? [])
            current = parents[next] ?? nil
        }
        return result
    }

    func allowsLayerEdit(_ id: UUID?, _ capability: LayerEditCapability) -> Bool {
        guard let id, document?.layers.contains(where: { $0.id == id }) == true else { return false }
        let locks = effectiveLocks(for: id)
        if locks.contains(.all) { return false }
        switch capability {
        case .content: return !locks.contains(.content)
        case .position: return !locks.contains(.position)
        case .appearance: return !locks.contains(.appearance)
        case .structure: return locks.isEmpty
        }
    }

    func allowsSelectedLayerEdits(_ capability: LayerEditCapability, descendants: Bool = false) -> Bool {
        guard let document, !selectedLayerIDs.isEmpty else { return false }
        var ids = selectedLayerIDs
        if descendants {
            for id in selectedLayerIDs { ids.formUnion(descendantIDs(of: id)) }
        }
        let targets = document.layers.filter { ids.contains($0.id) }
        guard targets.count == ids.count else { return false }
        guard document.id == lockDocumentID, !layerLocks.isEmpty else { return true }
        let locks = inheritedLocks(in: document)
        return targets.allSatisfy { target in
            let value = locks[target.id] ?? []
            if value.contains(.all) { return false }
            switch capability {
            case .content: return !value.contains(.content)
            case .position: return !value.contains(.position)
            case .appearance: return !value.contains(.appearance)
            case .structure: return value.isEmpty
            }
        }
    }

    func selectedLayersHaveLock(_ lock: LayerLocks) -> Bool {
        guard lockDocumentID == document?.id, !selectedLayerIDs.isEmpty else { return false }
        return selectedLayerIDs.allSatisfy { layerLocks[$0, default: []].contains(lock) }
    }

    func toggleSelectedLayerLock(_ lock: LayerLocks) {
        guard canEditLayers, !history.hasPendingEdit, effectsEditing == nil, !selectedLayerIDs.isEmpty else { return }
        if lockDocumentID != document?.id { layerLocks.removeAll(); lockDocumentID = document?.id }
        let remove = selectedLayersHaveLock(lock)
        for id in selectedLayerIDs {
            if remove { layerLocks[id, default: []].remove(lock) }
            else { layerLocks[id, default: []].insert(lock) }
            if layerLocks[id]?.isEmpty == true { layerLocks.removeValue(forKey: id) }
        }
    }

    private func inheritedLocks(in source: CanvasDocument) -> [UUID: LayerLocks] {
        let parents = Dictionary(uniqueKeysWithValues: source.layers.map { ($0.id, $0.parentID) })
        var resolved: [UUID: LayerLocks] = [:]
        for layer in source.layers {
            var chain: [UUID] = [], seen = Set<UUID>(), current: UUID? = layer.id
            while let id = current, resolved[id] == nil, seen.insert(id).inserted {
                chain.append(id)
                current = parents[id] ?? nil
            }
            var inherited = current.flatMap { resolved[$0] } ?? []
            for id in chain.reversed() {
                inherited.formUnion(layerLocks[id] ?? [])
                resolved[id] = inherited
            }
        }
        return resolved
    }

    /// Backstop for menus, asynchronous callbacks, and future consumers. Check the whole
    /// outer transaction, so rejecting one target cannot leave the others half modified.
    func violatesLayerLocks(before: CanvasDocument?, after: CanvasDocument?) -> Bool {
        guard let before, before.id == lockDocumentID, !layerLocks.isEmpty else { return false }
        guard let after else { return true }
        let next = Dictionary(uniqueKeysWithValues: after.layers.map { ($0.id, $0) })
        let previous = Dictionary(uniqueKeysWithValues: before.layers.map { ($0.id, $0) })
        let inherited = inheritedLocks(in: before)
        let oldOrder = before.layers.map(\.id).filter { next[$0] != nil }
        let newOrder = after.layers.map(\.id).filter { previous[$0] != nil }
        // Compare relative order in one pass, including unlocked layers crossing a locked one.
        var difference = Set<UUID>()
        for (a, b) in zip(oldOrder, newOrder) {
            if a != b {
                if inherited[a]?.isEmpty == false || inherited[b]?.isEmpty == false { return true }
            } else if !difference.isEmpty, inherited[a]?.isEmpty == false { return true }
            for id in [a, b] {
                if !difference.insert(id).inserted { difference.remove(id) }
            }
        }
        for old in before.layers {
            let locks = inherited[old.id] ?? []
            guard !locks.isEmpty else { continue }
            guard let new = next[old.id] else { return true }
            if locks.contains(.all), old != new { return true }
            if locks.contains(.position), old.transform != new.transform { return true }
            if locks.contains(.position), let a = old.mask, let b = new.mask,
               a.placement != b.placement || a.isLinked != b.isLinked { return true }
            if locks.contains(.content), old.asset?.image !== new.asset?.image || old.text != new.text || old.shape != new.shape || old.fill != new.fill
                || old.mask?.asset.image !== new.mask?.asset.image || old.adjustment != new.adjustment || old.maskSourceID != new.maskSourceID { return true }
            if locks.contains(.appearance), old.opacity != new.opacity || old.blendMode != new.blendMode
                || old.effects != new.effects || old.isVisible != new.isVisible { return true }
            if locks.contains(.appearance), let a = old.mask, let b = new.mask, a.isEnabled != b.isEnabled { return true }
            if old.parentID != new.parentID { return true }
            if locks.contains(.transparency), old.asset?.image !== new.asset?.image {
                guard let a = old.asset?.image, let b = new.asset?.image,
                      a.width == b.width, a.height == b.height,
                      let ca = try? BrushRaster.copy(a), let cb = try? BrushRaster.copy(b),
                      let da = ca.data, let db = cb.data,
                      layer_alpha_equal(da.assumingMemoryBound(to: UInt8.self), db.assumingMemoryBound(to: UInt8.self),
                                        a.width, a.height, ca.bytesPerRow, cb.bytesPerRow) != 0 else { return true }
            }
        }
        for new in after.layers where previous[new.id]?.parentID != new.parentID {
            if let parent = new.parentID {
                let locks = inherited[parent] ?? []
                if locks.contains(.all) || locks.contains(.content) { return true }
            }
        }
        return false
    }
}
