import Foundation

/// A revision identifies document content; the instance identifies the work using it.
nonisolated struct EditOwner: Equatable, Sendable {
    let documentID: UUID
    let revision: UUID
    let instance = UUID()
}

nonisolated enum EditRefusal: String, LocalizedError {
    var errorDescription: String? { L10n.text(rawValue) }
    case locked = "The layer or its folder is locked for content edits."
    case noDocument = "Create or open a document first."
    case busy = "The editor is busy. Try again when the current operation finishes."
    case modal = "Finish or cancel the current edit first."
    case target = "Select one visible pixel layer or an enabled layer mask to fill."
    case stale = "The document changed before the operation finished."
    case arrangeTarget = "Select visible layers with bounds to arrange."
    case reference = "The key object must be a selected layer or folder that can be arranged."
    case geometry = "The resulting layer position is outside the supported range."
}

nonisolated enum LayerEditResult: Equatable {
    case changed, unchanged
    case rejected(EditRefusal)
    case failed(String)
}

extension EditorSession {
    /// Shared document/busy/modal permission. Target rules belong to each operation family.
    func editingRefusal(owner: EditOwner? = nil) -> EditRefusal? {
        _ = showsBusy
        guard document != nil else { return .noDocument }
        if let owner, !ownsEdit(owner) { return .stale }
        if (isProjectBusy && owner == nil) || isImporting { return .busy }
        if selectionAmountOperation != nil || colorRange != nil || textDraft != nil || brushStroke != nil
            || warpStroke != nil || showsNewDocument || showsImporter || renamingLayerID != nil
            || transformEdit != nil || cropRect != nil || gradientEdit != nil || pixelMove != nil
            || hueSaturation != nil || levels != nil || filterEdit != nil || adjustmentEditingID != nil || liquify != nil {
            return .modal
        }
        return nil
    }

    func beginOwnedEdit() -> EditOwner? {
        guard !isProjectBusy, activeEditOwner == nil, !history.hasPendingEdit, let document else { return nil }
        let owner = EditOwner(documentID: document.id, revision: history.currentRevision)
        activeEditOwner = owner
        isProjectBusy = true
        return owner
    }

    func ownsEdit(_ owner: EditOwner) -> Bool {
        activeEditOwner == owner && document?.id == owner.documentID && history.currentRevision == owner.revision
    }

    func releaseEdit(_ owner: EditOwner) {
        guard activeEditOwner == owner else { return }
        activeEditOwner = nil
        isProjectBusy = false
    }
}
