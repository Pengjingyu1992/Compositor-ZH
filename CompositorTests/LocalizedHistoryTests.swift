import AppKit
import Testing
@testable import Compositor

@MainActor
struct LocalizedHistoryTests {
    private func fixture() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 64, height: 64)
        let context = try BrushRaster.context(width: 64, height: 64, mask: false)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try #require(context.makeImage())
        session.addPixelLayer(image, at: .zero, name: "验收图层", editName: "Import Image")
        session.foregroundColor = .black
        return session
    }

    private func checkName(_ session: EditorSession, _ key: String) {
        #expect(session.history.undoName == key)
        #expect(L10n.text(key) != key)
        #expect(L10n.format("Undo %@", L10n.text(key)).hasPrefix("撤销"))
    }

    @Test func allAdjustmentAndEffectNamesHaveChineseAndEnglishResources() throws {
        let englishURL = try #require(Bundle.main.url(forResource: "en", withExtension: "lproj"))
        let english = try #require(Bundle(url: englishURL))
        var keys: [String] = []
        for kind in AdjustmentKind.allCases { keys += [kind.historyNames.new, kind.historyNames.edit] }
        for kind in LayerEffectKind.allCases {
            let names = kind.historyNames
            keys += [names.add, names.edit, names.cancel, names.copy, names.hide, names.show, names.remove]
        }
        for key in keys {
            #expect(!key.contains("%@") && !key.contains("\\("))
            #expect(L10n.text(key) != key)
            #expect(english.localizedString(forKey: key, value: key, table: "Localizable") == key)
        }
        #expect(ProjectManifest.current == 12)
    }

    @Test func layerFlipsKeepUndoRedoAndLocalizedMenuNames() throws {
        let session = try fixture()
        for horizontal in [true, false] {
            let before = session.document
            session.flipLayers(horizontally: horizontal)
            let key = horizontal ? "Flip Horizontal" : "Flip Vertical"
            checkName(session, key)
            let after = session.document
            #expect(after != before)
            session.undo()
            #expect(session.document == before)
            #expect(session.history.redoName == key)
            #expect(L10n.format("Redo %@", L10n.text(session.history.redoName)).hasPrefix("重做"))
            session.redo()
            #expect(session.document == after)
        }
    }

    @Test func adjustmentCreationAndLevelsEditingUseFixedKeys() async throws {
        for kind in AdjustmentKind.allCases {
            let session = try fixture()
            session.addAdjustment(kind)
            checkName(session, kind.historyNames.new)
            #expect(session.activeLayer?.adjustment?.kind == kind)
            session.adjustmentEditingID = nil
            session.undo()
            #expect(session.document?.layers.count == 1)
            session.redo()
            #expect(session.activeLayer?.adjustment?.kind == kind)
        }
        let session = try fixture()
        session.addAdjustment(.levels)
        let id = try #require(session.activeLayerID)
        await session.beginAdjustmentEditing(id)
        let levels = try #require(session.levels)
        levels.settings.ranges[0].gamma = 1.5
        #expect(session.finishAdjustmentEditing(commit: true))
        checkName(session, "Edit Levels Adjustment")
        #expect(session.activeLayer?.adjustment?.levels.ranges[0].gamma == 1.5)
        session.undo()
        #expect(session.activeLayer?.adjustment?.levels.ranges[0].gamma == 1)
        session.redo()
        #expect(session.activeLayer?.adjustment?.levels.ranges[0].gamma == 1.5)
    }

    @Test func everyEffectActionUsesItsFixedHistoryName() throws {
        for kind in LayerEffectKind.allCases {
            let session = try fixture()
            let source = try #require(session.activeLayerID)
            session.addEffect(kind)
            checkName(session, kind.historyNames.add)
            session.changeEffects { effects in
                switch kind {
                case .stroke: effects.stroke?.opacity = 0.7
                case .shadow: effects.shadow?.opacity = 0.7
                case .colorOverlay: effects.colorOverlay?.opacity = 0.7
                case .innerShadow: effects.innerShadow?.opacity = 0.7
                case .outerGlow: effects.outerGlow?.opacity = 0.7
                case .innerGlow: effects.innerGlow?.opacity = 0.7
                case .gradientOverlay: effects.gradientOverlay?.opacity = 0.7
                case .patternOverlay: effects.patternOverlay?.opacity = 0.7
                case .bevel: effects.bevel?.depth = 0.4
                }
            }
            checkName(session, kind.historyNames.edit)
            session.finishEffectsEditing(commit: true)
            session.toggleEffect(kind, on: source)
            checkName(session, kind.historyNames.hide)
            session.toggleEffect(kind, on: source)
            checkName(session, kind.historyNames.show)
            let image = try #require(session.activeLayer?.asset?.image)
            session.addPixelLayer(image, at: .zero, name: "复制目标", editName: "Import Image")
            let target = try #require(session.activeLayerID)
            session.copyEffect(kind, from: source, to: target)
            checkName(session, kind.historyNames.copy)
            session.removeSelectedEffect()
            checkName(session, kind.historyNames.remove)
            #expect(session.activeLayer?.effects?.contains(kind) != true)

            let cancelled = try fixture()
            cancelled.addEffect(kind)
            cancelled.finishEffectsEditing(commit: false)
            checkName(cancelled, kind.historyNames.cancel)
            #expect(cancelled.activeLayer?.effects == nil)
        }
    }

    @Test func brushMaskAndNewTextUseTranslatedUndoNames() throws {
        let session = try fixture()
        session.tool = .brush
        session.beginBrush(at: CGPoint(x: 16, y: 16))
        session.continueBrush(at: CGPoint(x: 24, y: 24))
        #expect(session.finishBrushImmediately())
        checkName(session, "Brush Stroke")
        session.addLayerMask(revealing: true)
        session.isMaskSelected = true
        session.maskPaintWhite = false
        session.beginBrush(at: CGPoint(x: 16, y: 16))
        session.continueBrush(at: CGPoint(x: 24, y: 24))
        #expect(session.finishBrushImmediately())
        checkName(session, "Paint Mask")
        session.isMaskSelected = false
        session.beginText(at: CGPoint(x: 10, y: 40), newLayer: true)
        session.textDraft?.style.content = "中文"
        #expect(session.finishText())
        checkName(session, "New Text Layer")
        #expect(session.activeLayer?.name == "中文")
    }

    @Test func localizedHistorySurvivesSustainedEditsAndCapacityBoundary() throws {
        let session = try fixture()
        let initial = try #require(session.document)
        var retainedStates: [CanvasDocument] = []
        let editCount = 5_000
        let retainedStart = editCount - session.history.entryLimit

        for index in 0..<editCount {
            if index == retainedStart { retainedStates = [try #require(session.document)] }
            let horizontal = index.isMultiple(of: 2)
            session.flipLayers(horizontally: horizontal)
            let key = horizontal ? "Flip Horizontal" : "Flip Vertical"
            #expect(session.history.undoName == key)
            #expect(L10n.text(session.history.undoName) != key)
            if index >= retainedStart { retainedStates.append(try #require(session.document)) }
        }

        #expect(session.history.entryLimit == 100)
        #expect(session.history.undoCount == session.history.entryLimit)
        #expect(session.document == initial)

        for step in 0..<session.history.entryLimit {
            let key = step.isMultiple(of: 2) ? "Flip Vertical" : "Flip Horizontal"
            session.undo()
            #expect(session.document == retainedStates[session.history.entryLimit - 1 - step])
            #expect(session.history.redoName == key)
            #expect(L10n.text(session.history.redoName) != key)
        }
        #expect(!session.canUndo)

        for step in 0..<session.history.entryLimit {
            let key = step.isMultiple(of: 2) ? "Flip Horizontal" : "Flip Vertical"
            session.redo()
            #expect(session.document == retainedStates[step + 1])
            #expect(session.history.undoName == key)
            #expect(L10n.text(session.history.undoName) != key)
        }
        #expect(session.document == initial)
        #expect(!session.canRedo)

        session.undo()
        #expect(session.history.redoName == "Flip Vertical")
        session.flipLayers(horizontally: true)
        #expect(!session.canRedo)
        #expect(session.history.undoName == "Flip Horizontal")
        #expect(L10n.text(session.history.undoName) != "Flip Horizontal")
    }
}
