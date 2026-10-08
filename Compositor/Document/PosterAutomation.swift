import AppKit

nonisolated enum PosterCommandKind: String, Codable, Sendable {
    case addFill, editFill, addText, transform, opacity, blendMode, remove, invert, fillPixels, filter, effects, reorder
}
nonisolated struct PosterCommand: Codable, Sendable {
    var kind: PosterCommandKind
    var layerID: UUID?
    var name: String?
    var fill: LayerFillStyle?
    var text: LayerTextStyle?
    var transform: LayerTransform?
    var opacity: Double?
    var blendMode: LayerBlendMode?
    var color: FillColor?
    var filter: String?
    var amount: Double?
    var effects: LayerEffects?
    var index: Int?
}
nonisolated struct PosterBatchRequest: Codable, Sendable {
    let documentID: UUID
    let expectedRevision: UUID
    var expectedLockRevision: UUID?
    var commands: [PosterCommand]
}
nonisolated struct PosterBatchResult: Codable, Sendable {
    var status: String
    var revision: UUID
    var errorCode: String?
    var message: String?
}
nonisolated enum PosterCommandError: Error {
    case invalid, locked, unsupported, failed(String)
}

extension EditorSession {
    /// The UI command panel, CLI and MCP all enter here. Work is isolated until validation succeeds.
    func executePosterBatch(_ request: PosterBatchRequest) async -> PosterBatchResult {
        func result(_ status: String, _ code: String? = nil, _ message: String? = nil) -> PosterBatchResult {
            PosterBatchResult(status: status, revision: history.currentRevision, errorCode: code, message: message)
        }
        guard let source = document, source.id == request.documentID, history.currentRevision == request.expectedRevision else { return result("rejected", "stale", L10n.text("The document changed before the operation finished.")) }
        guard request.expectedLockRevision == nil || request.expectedLockRevision == lockRevision else { return result("rejected", "stale_locks") }
        let initialLockRevision = lockRevision
        guard canEditLayers, effectsEditing == nil, !history.hasPendingEdit, (1...500).contains(request.commands.count), let owner = beginOwnedEdit() else { return result("rejected", "busy", L10n.text("Finish or cancel the current edit first.")) }
        defer { releaseEdit(owner) }
        let candidate = EditorSession()
        candidate.document = source; candidate.activeLayerID = activeLayerID; candidate.selectedLayerIDs = selectedLayerIDs
        candidate.layerLocks = layerLocks; candidate.lockDocumentID = lockDocumentID
        do {
            for command in request.commands {
                try Task.checkCancellation()
                try await candidate.executePosterCommand(command)
            }
            guard let snapshot = candidate.projectSnapshot() else { throw PosterCommandError.invalid }
            try await ProjectStore.shared.validateSnapshot(snapshot)
            guard !Task.isCancelled, ownsEdit(owner), lockRevision == initialLockRevision, !violatesLayerLocks(before: source, after: candidate.document) else { return result("rejected", "stale_or_locked") }
            guard source != candidate.document else { return result("unchanged") }
            beginEdit("Edit Command Batch")
            document = candidate.document; activeLayerID = candidate.activeLayerID; selectedLayerIDs = candidate.selectedLayerIDs
            endEdit()
            return result("changed")
        } catch PosterCommandError.locked { return result("rejected", "locked", L10n.text("The layer or its folder is locked for content edits.")) }
        catch PosterCommandError.invalid { return result("rejected", "invalid", L10n.text("The edit command or its parameters are invalid.")) }
        catch PosterCommandError.unsupported { return result("rejected", "unsupported", L10n.text("This edit command is not supported.")) }
        catch { return result("failed", "execution", error.localizedDescription) }
    }

    private func executePosterCommand(_ command: PosterCommand) async throws {
        if let id = command.layerID {
            guard document?.layers.contains(where: { $0.id == id }) == true else { throw PosterCommandError.invalid }
            selectLayer(id); isMaskSelected = false
        }
        brushError = nil
        switch command.kind {
        case .addFill:
            guard let fill = command.fill, fill.isValid, canInsertFillLayer else { throw PosterCommandError.invalid }
            openFillLayer()
            guard var draft = fillLayerDraft else { throw PosterCommandError.locked }
            draft.style = fill; await applyFillLayer(draft)
            guard fillLayerDraft == nil else { cancelFillLayer(); throw PosterCommandError.invalid }
        case .editFill:
            guard let fill = command.fill, fill.isValid, activeLayer?.liveFill != nil, allowsLayerEdit(activeLayerID, .content) else { throw PosterCommandError.locked }
            openFillLayer(editing: true)
            guard var draft = fillLayerDraft else { throw PosterCommandError.invalid }
            draft.style = fill; await applyFillLayer(draft)
            guard fillLayerDraft == nil else { cancelFillLayer(); throw PosterCommandError.invalid }
        case .addText:
            guard let style = command.text, style.isValid, canInsertFillLayer else { throw PosterCommandError.invalid }
            let image = try Self.textImage(style)
            addPixelLayer(image, at: command.transform?.origin ?? .zero, name: command.name ?? L10n.text("Text"), editName: "New Text Layer", dropsSelection: false, text: LayerText(style: style, image: image))
            if let transform = command.transform, let index = document?.layers.firstIndex(where: { $0.id == activeLayerID }) {
                guard transform.isValid else { throw PosterCommandError.invalid }; document?.layers[index].transform = transform
            }
        case .transform:
            guard let transform = command.transform, transform.isValid, let id = activeLayerID,
                  let index = document?.layers.firstIndex(where: { $0.id == id }) else { throw PosterCommandError.invalid }
            guard allowsLayerEdit(id, .position), document?.layers[index].isGroup == false else { throw PosterCommandError.locked }
            document?.layers[index].transform = transform
        case .opacity:
            guard let value = command.opacity, value.isFinite, (0...1).contains(value) else { throw PosterCommandError.invalid }
            guard allowsLayerEdit(activeLayerID, .appearance) else { throw PosterCommandError.locked }
            setLayerOpacity(value); finishOpacityEdit()
        case .blendMode:
            guard let mode = command.blendMode else { throw PosterCommandError.invalid }
            guard allowsLayerEdit(activeLayerID, .appearance), activeLayer?.isGroup == false else { throw PosterCommandError.locked }
            setLayerBlendMode(mode)
        case .remove:
            guard allowsSelectedLayerEdits(.structure, descendants: true) else { throw PosterCommandError.locked }
            deleteSelectedLayers()
        case .invert:
            guard canInvert else { throw PosterCommandError.locked }; await invertPixels()
        case .fillPixels:
            guard canEditPixels, let layer = activeLayer, let color = command.color, color.isValid else { throw PosterCommandError.locked }
            guard color.alpha == 1 else { throw PosterCommandError.invalid }
            guard await fillPixels(on: layer, with: .foreground, name: "Fill", color: PaletteColor(red: color.red, green: color.green, blue: color.blue)) else { throw PosterCommandError.invalid }
        case .filter:
            guard let name = command.filter, let kind = FilterKind(rawValue: name), canAdjustColors,
                  !kind.isAutomatic, kind != .cameraRaw else { throw PosterCommandError.invalid }
            beginFilter(kind)
            guard let edit = filterEdit else { throw PosterCommandError.locked }
            if let amount = command.amount {
                guard amount.isFinite else { throw PosterCommandError.invalid }
                switch kind {
                case .colorHalftone: edit.settings.colorHalftone.size = amount
                case .mosaic: edit.settings.mosaicSize = amount
                case .gaussianBlur: edit.settings.radius = amount
                case .grain: edit.settings.grain.amount = amount
                default: throw PosterCommandError.unsupported
                }
            }
            await commitFilter()
            guard filterEdit == nil else { cancelFilter(); throw PosterCommandError.invalid }
        case .effects:
            guard let effects = command.effects, effects.isValid else { throw PosterCommandError.invalid }
            guard canEditEffects else { throw PosterCommandError.locked }; setEffects(effects, name: "Edit Layer Effects")
        case .reorder:
            guard let index = command.index, let layer = activeLayer, !layer.isGroup,
                  let old = document?.layers.firstIndex(where: { $0.id == layer.id }),
                  let count = document?.layers.count, (0..<count).contains(index) else { throw PosterCommandError.invalid }
            guard allowsLayerEdit(layer.id, .structure), allowsLayerEdit(layer.parentID, .structure) || layer.parentID == nil else { throw PosterCommandError.locked }
            guard document?.layers[index].parentID == layer.parentID else { throw PosterCommandError.invalid }
            document?.layers.remove(at: old); document?.layers.insert(layer, at: index)
        }
        if let error = brushError { throw PosterCommandError.failed(error) }
    }

    func automationState() -> [String: Any] {
        ["documentID": document?.id.uuidString ?? "", "revision": history.currentRevision.uuidString,
         "lockRevision": lockRevision.uuidString, "width": document?.width ?? 0, "height": document?.height ?? 0,
         "layers": (document?.layers ?? []).map { layer -> [String: Any] in
             ["id": layer.id.uuidString, "name": layer.name, "visible": layer.isVisible, "isGroup": layer.isGroup,
              "opacity": layer.opacity, "blendMode": layer.blendMode.rawValue,
              "locks": effectiveLocks(for: layer.id).rawValue, "editableFill": layer.liveFill != nil, "editableText": layer.liveText != nil]
         }]
    }
}
