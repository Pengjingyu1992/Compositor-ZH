import CoreGraphics
import Foundation

nonisolated enum ArrangeOperation: String, CaseIterable {
    case left = "Align Left", horizontalCenter = "Align Horizontal Centers", right = "Align Right"
    case top = "Align Top", verticalCenter = "Align Vertical Centers", bottom = "Align Bottom"
    case horizontalCenters = "Distribute Horizontal Centers", verticalCenters = "Distribute Vertical Centers"
    case horizontalGaps = "Distribute Horizontal Gaps", verticalGaps = "Distribute Vertical Gaps"
    var isAlignment: Bool { Self.allCases.firstIndex(of: self)! < 6 }
    var horizontal: Bool { [.left, .horizontalCenter, .right, .horizontalCenters, .horizontalGaps].contains(self) }
    var gaps: Bool { self == .horizontalGaps || self == .verticalGaps }
}

nonisolated enum ArrangeReference: Equatable {
    case selection, canvas, keyObject(UUID)
}

/// Geometry adapted from Pentrado's arrange.ts, Copyright (c) 2026 Terry Jia, MIT.
/// The full notice is in Resources/Pentrado-LICENSE.txt.
nonisolated enum LayerArrange {
    static func deltas(_ rects: [CGRect], operation: ArrangeOperation, reference: CGRect? = nil) -> [CGSize] {
        var result = Array(repeating: CGSize.zero, count: rects.count)
        guard !rects.isEmpty else { return result }
        let horizontal = operation.horizontal
        func position(_ r: CGRect) -> CGFloat { horizontal ? r.minX : r.minY }
        func size(_ r: CGRect) -> CGFloat { horizontal ? r.width : r.height }
        func delta(_ value: CGFloat) -> CGSize { horizontal ? CGSize(width: value, height: 0) : CGSize(width: 0, height: value) }
        if operation.isAlignment {
            let bounds = reference ?? rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            let factor: CGFloat = [.left, .top].contains(operation) ? 0 : [.right, .bottom].contains(operation) ? 1 : 0.5
            let target = position(bounds) + size(bounds) * factor
            return rects.map { delta(target - position($0) - size($0) * factor) }
        }
        guard rects.count >= 3 else { return result }
        let order = rects.indices.sorted {
            let a = position(rects[$0]) + (operation.gaps ? 0 : size(rects[$0]) / 2)
            let b = position(rects[$1]) + (operation.gaps ? 0 : size(rects[$1]) / 2)
            return a == b ? $0 < $1 : a < b
        }
        let first = rects[order.first!], last = rects[order.last!]
        if operation.gaps {
            let middle = order.dropFirst().dropLast().reduce(CGFloat.zero) { $0 + size(rects[$1]) }
            let gap = (position(last) - position(first) - size(first) - middle) / CGFloat(rects.count - 1)
            var next = position(first) + size(first)
            for index in order.dropFirst().dropLast() {
                result[index] = delta(next + gap - position(rects[index]))
                next += gap + size(rects[index])
            }
        } else {
            let start = position(first) + size(first) / 2
            let spacing = (position(last) + size(last) / 2 - start) / CGFloat(rects.count - 1)
            for (step, index) in order.enumerated().dropFirst().dropLast() {
                result[index] = delta(start + CGFloat(step) * spacing - position(rects[index]) - size(rects[index]) / 2)
            }
        }
        return result
    }
}

struct ArrangeTarget {
    let id: UUID
    let bounds: CGRect
    let members: Set<UUID>
}

extension EditorSession {
    /// Selected ancestors collapse their descendants into one unit. Hidden children still move with a folder.
    var arrangeTargets: [ArrangeTarget]? {
        guard let document, !isMaskSelected, !selectedLayerIDs.isEmpty else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0) })
        guard selectedLayerIDs.allSatisfy({ byID[$0] != nil }) else { return nil }
        let roots = document.layers.filter { layer in
            guard selectedLayerIDs.contains(layer.id) else { return false }
            var parent = layer.parentID
            for _ in 0..<64 {
                guard let id = parent else { return true }
                if selectedLayerIDs.contains(id) { return false }
                parent = byID[id]?.parentID
            }
            return false
        }
        var result: [ArrangeTarget] = []
        let visible = document.effectiveVisibleIDs
        let children = Dictionary(grouping: document.layers, by: \.parentID)
        for root in roots {
            guard visible.contains(root.id), root.adjustment == nil else { return nil }
            var members = Set<UUID>(), pending = [root]
            var bounds = CGRect.null
            // Collapsed roots have disjoint subtrees. Visit each member once instead of
            // scanning the complete document for every selected layer.
            while let layer = pending.popLast() {
                guard members.insert(layer.id).inserted else { continue }
                if layer.isGroup {
                    pending.append(contentsOf: children[layer.id] ?? [])
                    continue
                }
                guard visible.contains(layer.id), layer.adjustment == nil else { continue }
                let corners = DistortWarp.corners(of: layer.transform)
                let rect = CGRect(x: corners.map(\.x).min()!, y: corners.map(\.y).min()!,
                    width: corners.map(\.x).max()! - corners.map(\.x).min()!,
                    height: corners.map(\.y).max()! - corners.map(\.y).min()!)
                bounds = bounds.union(rect)
            }
            guard !bounds.isNull, !bounds.isEmpty else { return nil }
            result.append(ArrangeTarget(id: root.id, bounds: bounds, members: members))
        }
        return result.isEmpty ? nil : result
    }

    func canArrange(_ operation: ArrangeOperation) -> Bool {
        guard canEditLayers, allowsSelectedLayerEdits(.position, descendants: true), let targets = arrangeTargets else { return false }
        if operation.isAlignment, case .keyObject(let id) = arrangeReference {
            return targets.contains { $0.id == id }
        }
        return operation.isAlignment || targets.count >= 3
    }

    @discardableResult
    func arrangeLayers(_ operation: ArrangeOperation) -> LayerEditResult {
        if let refusal = editingRefusal() { return .rejected(refusal) }
        guard allowsSelectedLayerEdits(.position, descendants: true) else { return .rejected(.locked) }
        guard let targets = arrangeTargets, var changed = document else { return .rejected(.arrangeTarget) }
        let reference: CGRect?
        switch operation.isAlignment ? arrangeReference : .selection {
        case .selection: reference = nil
        case .canvas: reference = CGRect(origin: .zero, size: changed.size)
        case .keyObject(let id):
            guard let key = targets.first(where: { $0.id == id }) else { return .rejected(.reference) }
            reference = key.bounds
        }
        let deltas = LayerArrange.deltas(targets.map(\.bounds), operation: operation, reference: reference)
        let indices = Dictionary(uniqueKeysWithValues: changed.layers.indices.map { (changed.layers[$0].id, $0) })
        for (target, delta) in zip(targets, deltas) where delta != .zero {
            for id in target.members {
                guard let index = indices[id] else { return .rejected(.arrangeTarget) }
                let layer = changed.layers[index]
                // A folder's transform places its mask; an unlinked folder mask stays where it is.
                if layer.isGroup, layer.mask?.isLinked == false { continue }
                var transform = layer.transform
                transform.origin.x += delta.width
                transform.origin.y += delta.height
                guard transform.isValid else { return .rejected(.geometry) }
                let placement = layer.mask?.placement(movingLayer: layer.transform, to: transform)
                guard placement?.isValid != false else { return .rejected(.geometry) }
                changed.layers[index].transform = transform
                changed.layers[index].mask?.placement = placement
            }
        }
        guard changed != document else { return .unchanged }
        finishOpacityEdit()
        beginEdit(operation.rawValue)
        document = changed
        endEdit()
        return .changed
    }

    func performArrange(_ operation: ArrangeOperation) {
        if case .rejected(let refusal) = arrangeLayers(operation) { arrangeError = L10n.text(refusal.rawValue) }
    }
}
