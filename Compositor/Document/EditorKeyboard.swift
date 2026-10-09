import AppKit

extension EditorSession {
    /// Shared by the canvas and layer list, after custom shortcuts have been mapped.
    @discardableResult
    func handleToolShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if event.keyCode == 48 {
            guard !event.modifierFlags.contains(.shift), textDraft == nil else { return false }
            cycleToolMode()
            return true
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "x": swapPaletteColors()
        case "d": resetPaletteColors()
        case "b": selectTool(.brush); brushMode = .paint
        case "e": selectTool(.brush); brushMode = .erase
        case "j": selectTool(.spotHealing)
        case "s": selectTool(.cloneStamp)
        case "t": selectTool(.type)
        case "p": selectTool(.pen)
        case "g": selectTool(.gradient)
        case "k": selectTool(.bucket)
        case "u":
            if event.modifierFlags.contains(.shift), tool == .shape { toggleShapeKind() }
            else { selectTool(.shape) }
        case "i": selectTool(.eyedropper)
        case "m": if !event.isARepeat { pressMarqueeKey() }
        case "w": if !event.isARepeat { pressWandKey() }
        case "l": if !event.isARepeat { pressLassoKey() }
        case "a": selectTool(.idle)
        case "r": selectTool(.blur)
        case "c": selectTool(.crop)
        case "v": selectTool(.move)
        case "h": selectTool(.hand)
        case "z": selectTool(.zoom)
        default: return false
        }
        return true
    }

    func selectedPixelNudge(for event: NSEvent) -> CGSize? {
        guard selection?.isEmpty == false, lassoDraft == nil,
              [123, 124, 125, 126].contains(event.keyCode),
              event.modifierFlags.contains(.command),
              event.modifierFlags.intersection([.control, .option]).isEmpty else { return nil }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        return CGSize(width: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,
                      height: event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0)
    }

    /// The key can queue before a tab switch. Never start it in the replacement document.
    func nudgePixels(_ offset: CGSize, in documentID: UUID?) async {
        guard let documentID, document?.id == documentID else { return }
        await nudgePixels(dx: offset.width, dy: offset.height)
    }
}
