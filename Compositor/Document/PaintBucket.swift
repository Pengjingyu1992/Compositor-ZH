import AppKit

nonisolated struct BucketSample: @unchecked Sendable {
    let image: CGImage
    let point: CGPoint
    let settings: WandSettings
}

extension EditorSession {
    /// Match without touching the selection, then send transient coverage through the ordinary fill.
    @discardableResult
    func paintBucket(at point: CGPoint, with source: FillSource = .foreground,
        match: @Sendable (BucketSample) async throws -> SelectionClip? = { sample in
            try await Task.detached(priority: .userInitiated) {
                try MagicWand.coverage(in: sample.image, at: sample.point, settings: sample.settings)
            }.value
        }) async -> LayerEditResult {
        guard !Task.isCancelled else { return .unchanged }
        if let refusal = editingRefusal() { return .rejected(refusal) }
        guard canPaint, let document, let layer = activeLayer else { return .rejected(.target) }
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
              point.x < document.size.width, point.y < document.size.height else { return .unchanged }
        guard document.width <= DocumentLimits.maxSide, document.height <= DocumentLimits.maxSide,
              document.width <= DocumentLimits.maxSurfacePixels / document.height else {
            return .failed(ProjectError.tooLarge.localizedDescription)
        }
        let maskTarget = isMaskSelected
        let color = paletteColor(background: source == .background)
        finishOpacityEdit()
        guard let owner = beginOwnedEdit() else { return .rejected(.busy) }
        defer { releaseEdit(owner) }
        do {
            guard let image = selectionSample(document, sampleAllLayers: bucketSettings.sampleAllLayers,
                                              targetMask: maskTarget) else { throw ExportError.render }
            let sample = BucketSample(image: image, point: point, settings: bucketSettings)
            guard let matched = try await match(sample) else { return .unchanged }
            guard !Task.isCancelled else { return .unchanged }
            guard ownsEdit(owner), activeLayerID == layer.id, isMaskSelected == maskTarget,
                  self.document == document else { return .rejected(.stale) }
            let coverage = try matched.intersecting(document.selection?.clip(canvas: document.size))
            guard coverage.coverage != nil, !coverage.rect.isEmpty else { return .unchanged }
            let committed = await fillPixels(on: layer, with: source,
                name: maskTarget ? "Paint Bucket Mask" : "Paint Bucket", coverage: coverage, owner: owner, color: color)
            if committed { return .changed }
            if Task.isCancelled { return .unchanged }
            if let error = brushError { return .failed(L10n.text(error)) }
            return ownsEdit(owner) ? .unchanged : .rejected(.stale)
        } catch {
            if Task.isCancelled { return .unchanged }
            return .failed(L10n.text(error.localizedDescription))
        }
    }

    func clickPaintBucket(at point: CGPoint, background: Bool) async {
        switch await paintBucket(at: point, with: background ? .background : .foreground) {
        case .failed(let message): brushError = message
        case .rejected(let refusal) where refusal == .target: brushError = L10n.text(refusal.rawValue)
        default: break
        }
    }
}
