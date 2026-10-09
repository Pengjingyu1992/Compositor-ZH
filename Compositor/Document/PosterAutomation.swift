import AppKit

nonisolated enum PosterCommandKind: String, Codable, Sendable {
    case addFill, editFill, addImage, addText, editText, transform, opacity, blendMode, visibility, remove, invert, fillPixels, filter, effects, reorder, setMask, refineEdges, addPath, editPath, textOutlines, vectorMask
}
nonisolated struct PosterCommand: Codable, Sendable {
    var kind: PosterCommandKind
    var layerID: UUID?
    var name: String?
    var fill: LayerFillStyle?
    var vector: VectorPathStyle?
    var text: LayerTextStyle?
    var transform: LayerTransform?
    var opacity: Double?
    var blendMode: LayerBlendMode?
    var color: FillColor?
    var filter: String?
    var amount: Double?
    var effects: LayerEffects?
    var index: Int?
    var imageData: Data?
    var maskData: Data?
    var clearMask: Bool?
    var visible: Bool?
    var halftone: ColorHalftoneSettings?
    var channelMixer: ChannelMixerSettings?
    var selectiveColor: PosterSelectiveColor?
    var lut: PosterLUT?
    var edge: PosterEdgeOptions?
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
        if let id = command.layerID ?? activeLayerID {
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
        case .addImage:
            guard let data = command.imageData, canInsertFillLayer,
                  command.name.map({ !$0.isEmpty && $0.count <= 200 }) ?? true,
                  command.transform?.isValid != false else { throw PosterCommandError.invalid }
            let asset = try await ImageImporter.shared.decode(data, name: command.name ?? L10n.text("Image"),
                remainingPixels: DocumentLimits.documentPixelBudget - sourcePixelCount)
            addPixelLayer(asset.image, at: command.transform?.origin ?? .zero, name: asset.name, editName: "Import Images", dropsSelection: false)
            guard let index = document?.layers.firstIndex(where: { $0.id == activeLayerID }) else { throw PosterCommandError.invalid }
            if let transform = command.transform { document?.layers[index].transform = transform }
        case .addPath, .editPath:
            guard let vector = command.vector, vector.isValid, let color = command.color, color.isValid, color.alpha == 1 else { throw PosterCommandError.invalid }
            let paint = PaletteColor(red:color.red,green:color.green,blue:color.blue)
            let shape = LayerShapeStyle(kind:.path,red:paint.red,green:paint.green,blue:paint.blue,cornerRadius:0,vector:vector)
            if command.kind == .addPath {
                guard canInsertFillLayer, let transform = command.transform, transform.isValid else { throw PosterCommandError.invalid }
                let image = try Self.shapeImage(.path,size:transform.size,color:paint,vector:vector)
                addPixelLayer(image,at:transform.origin,name:command.name ?? L10n.text("Path"),editName:"New Path",dropsSelection:false,shape:LayerShape(style:shape,image:image))
                if let i = document?.layers.firstIndex(where: { $0.id == activeLayerID }) { document?.layers[i].transform = transform }
            } else {
                guard let layer = activeLayer, layer.liveShape?.style.vector != nil, allowsLayerEdit(layer.id,.content),
                      let i = document?.layers.firstIndex(where: { $0.id == layer.id }) else { throw PosterCommandError.locked }
                let image = try Self.shapeImage(.path,size:layer.size,color:paint,vector:vector)
                document?.layers[i].asset = ImportedImage(image:image,thumbnail:try PixelInvert.thumbnail(of:image),name:layer.name)
                document?.layers[i].shape = LayerShape(style:shape,image:image)
            }
        case .textOutlines:
            guard canConvertTextToOutlines else { throw PosterCommandError.locked }; convertTextToOutlines()
        case .vectorMask:
            guard let vector = command.vector, vector.isValid, let layer = activeLayer,
                  allowsLayerEdit(layer.id,.content), let i = document?.layers.firstIndex(where: { $0.id == layer.id }) else { throw PosterCommandError.locked }
            let image = try Self.vectorMaskImage(vector,size:layer.size)
            document?.layers[i].mask = LayerMask(asset:try LayerMask.asset(from:image),vector:vector)
        case .addText:
            guard let style = command.text, style.isValid, canInsertFillLayer else { throw PosterCommandError.invalid }
            let image = try Self.textImage(style)
            addPixelLayer(image, at: command.transform?.origin ?? .zero, name: command.name ?? L10n.text("Text"), editName: "New Text Layer", dropsSelection: false, text: LayerText(style: style, image: image))
            if let transform = command.transform, let index = document?.layers.firstIndex(where: { $0.id == activeLayerID }) {
                guard transform.isValid else { throw PosterCommandError.invalid }; document?.layers[index].transform = transform
            }
        case .editText:
            guard let style = command.text, style.isValid else { throw PosterCommandError.invalid }
            guard activeLayer?.liveText != nil, allowsLayerEdit(activeLayerID, .content) else { throw PosterCommandError.locked }
            editActiveText()
            guard var draft = textDraft else { throw PosterCommandError.invalid }
            draft.style = style
            guard applyText(draft) else { throw PosterCommandError.invalid }
        case .transform:
            guard let transform = command.transform, transform.isValid, let id = activeLayerID,
                  let index = document?.layers.firstIndex(where: { $0.id == id }) else { throw PosterCommandError.invalid }
            guard allowsLayerEdit(id, .position), document?.layers[index].isGroup == false else { throw PosterCommandError.locked }
            if let layer = activeLayer {
                document?.layers[index].mask?.placement = layer.mask?.placement(movingLayer: layer.transform, to: transform)
            }
            document?.layers[index].transform = transform
        case .opacity:
            guard let value = command.opacity, value.isFinite, (0...1).contains(value) else { throw PosterCommandError.invalid }
            guard allowsLayerEdit(activeLayerID, .appearance) else { throw PosterCommandError.locked }
            setLayerOpacity(value); finishOpacityEdit()
        case .blendMode:
            guard let mode = command.blendMode else { throw PosterCommandError.invalid }
            guard allowsLayerEdit(activeLayerID, .appearance), activeLayer?.isGroup == false else { throw PosterCommandError.locked }
            setLayerBlendMode(mode)
        case .visibility:
            guard let visible = command.visible, let layer = activeLayer else { throw PosterCommandError.invalid }
            guard allowsLayerEdit(layer.id, .appearance) else { throw PosterCommandError.locked }
            if layer.isVisible != visible { toggleLayerVisibility(layer.id) }
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
            defer { if filterEdit === edit { cancelFilter() } }
            if let value = command.halftone {
                guard kind == .colorHalftone, value.isValid else { throw PosterCommandError.invalid }
                edit.settings.colorHalftone = value
            }
            if let value = command.channelMixer {
                guard kind == .channelMixer, value.coefficients.count == 12,
                      value.coefficients.allSatisfy({ $0.isFinite && (-200...200).contains($0) }) else { throw PosterCommandError.invalid }
                edit.settings.channelMixer = value
            }
            if let value = command.selectiveColor {
                guard kind == .selectiveColor else { throw PosterCommandError.invalid }
                edit.settings.selectiveColor = try value.settings()
            }
            if let value = command.lut {
                guard kind == .colorLUT else { throw PosterCommandError.invalid }
                edit.settings.colorLUT = try value.settings()
            }
            if kind == .colorLUT, command.lut == nil { throw PosterCommandError.invalid }
            if let amount = command.amount {
                guard amount.isFinite else { throw PosterCommandError.invalid }
                switch kind {
                case .colorHalftone:
                    guard (2...128).contains(amount) else { throw PosterCommandError.invalid }
                    edit.settings.colorHalftone.size = amount
                case .mosaic:
                    guard (1...512).contains(amount) else { throw PosterCommandError.invalid }
                    edit.settings.mosaicSize = amount
                case .gaussianBlur:
                    guard (0.1...250).contains(amount) else { throw PosterCommandError.invalid }
                    edit.settings.radius = amount
                case .grain:
                    guard (0...100).contains(amount) else { throw PosterCommandError.invalid }
                    edit.settings.grain.amount = amount
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
        case .setMask:
            try await setPosterMask(command.maskData, clear: command.clearMask ?? false)
        case .refineEdges:
            guard let options = command.edge else { throw PosterCommandError.invalid }
            try await runPosterEdgeCommand(options)
        }
        if let error = brushError { throw PosterCommandError.failed(error) }
    }

    func automationState() -> [String: Any] {
        ["documentID": document?.id.uuidString ?? "", "revision": history.currentRevision.uuidString,
         "lockRevision": lockRevision.uuidString, "width": document?.width ?? 0, "height": document?.height ?? 0,
         "layers": (document?.layers ?? []).map { layer -> [String: Any] in
             var value: [String: Any] = ["id": layer.id.uuidString, "name": layer.name, "visible": layer.isVisible, "isGroup": layer.isGroup,
              "opacity": layer.opacity, "blendMode": layer.blendMode.rawValue,
              "locks": effectiveLocks(for: layer.id).rawValue, "editableFill": layer.liveFill != nil, "editableText": layer.liveText != nil,
              "hasMask": layer.mask != nil]
             func json<T: Encodable>(_ item: T) -> Any? { (try? JSONEncoder().encode(item)).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
             value["transform"] = json(layer.transform)
             value["fill"] = layer.liveFill.flatMap { json($0.style) }
             value["shape"] = layer.liveShape.flatMap { json($0.style) }
             value["vectorMask"] = layer.mask?.vector.flatMap { json($0) }
             value["text"] = layer.liveText.flatMap { json($0.style) }
             value["effects"] = layer.effects.flatMap { json($0) }
             value["parentID"] = layer.parentID?.uuidString
             return value
         }]
    }
}
