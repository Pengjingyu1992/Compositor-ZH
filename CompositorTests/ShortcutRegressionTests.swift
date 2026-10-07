import AppKit
import SwiftUI
#if !SHORTCUT_CLT_CHECKS
import Testing
@testable import Compositor
#endif

/// The same behavioral checks run under XCTest's host or the standalone CLT runner.
@MainActor
struct ShortcutRegressionChecks {
    struct Result { var checks = 0; var failures: [String] = [] }
    static func run() async throws -> Result {
        let domain = "com.compositor.shortcut-regression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = ShortcutSettings(defaults: defaults)
        var result = Result()
        func check(_ name: String, _ passed: Bool) {
            result.checks += 1
            if !passed { result.failures.append(name) }
        }
        func event(_ key: String, _ modifiers: Int = 0, code: UInt16 = 0xffff) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: ShortcutChord(key, modifiers).cocoaModifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: code)!
        }
        func keyEvent(_ chord: ShortcutChord) -> NSEvent { chord.event(like: event("y"))! }
        check("unique IDs", Set(ShortcutDefinition.all.map(\.id)).count == ShortcutDefinition.all.count)
        check("default conflicts", ShortcutSettings.problem(in: [:]) == nil)
        for definition in ShortcutDefinition.all {
            let replacement = ShortcutChord("y", 6)
            let values = [definition.id: replacement]
            check("valid rebind \(definition.id)", ShortcutSettings.problem(in: values) == nil)
            check("event round trip \(definition.id)", ShortcutChord(keyEvent(definition.original)) == definition.original)
            settings.save(values)
            check("persist \(definition.id)", ShortcutSettings(defaults: defaults).overrides == values)
            check("label \(definition.id)", settings.keyLabel(definition.original.key, definition.original.modifiers, menu: definition.isMenu) == replacement.label)
            if definition.isMenu {
                check("menu lookup \(definition.id)", settings.menu(KeyEquivalent(definition.original.key.first!), modifiers: definition.original.eventModifiers) == replacement)
                check("retired menu \(definition.id)", settings.canvasEvent(keyEvent(definition.original)) == nil)
            } else if definition.group == "Text Editing" {
                check("text mapping \(definition.id)", settings.textEvent(keyEvent(replacement)).map(ShortcutChord.init) == definition.original)
                check("retired text \(definition.id)", settings.textEvent(keyEvent(definition.original)) == nil)
            } else {
                check("canvas mapping \(definition.id)", settings.canvasEvent(keyEvent(replacement)).map(ShortcutChord.init) == definition.original)
                check("retired canvas \(definition.id)", settings.canvasEvent(keyEvent(definition.original)) == nil)
                check("native lookup \(definition.id)", settings.native(KeyEquivalent(definition.original.key.first!), modifiers: definition.original.eventModifiers) == replacement)
            }
            settings.save([:])
        }
        for values in [[:], ["Canvas & Layers:Hand tool": ShortcutChord("y", 6)]] {
            settings.save(values)
            for (key, code, canonical) in [("【", UInt16(33), "["), ("】", 30, "]"), ("「", 33, "["), ("」", 30, "]"), ("『", 33, "["), ("』", 30, "]"), ("［", 33, "["), ("］", 30, "]")] {
                for modifiers in [0, 8] {
                    let incoming = event(key, modifiers, code: code)
                    let expected = modifiers == 8 ? (canonical == "[" ? "{" : "}") : canonical
                    check("Chinese punctuation \(key) \(modifiers) \(values.isEmpty)", settings.canvasEvent(incoming)?.charactersIgnoringModifiers == expected)
                    check("text punctuation unchanged \(key) \(modifiers)", settings.textEvent(incoming) === incoming)
                }
            }
        }
        let brushID = "Canvas & Layers:Brush tool"
        for chord in [ShortcutChord("v"), ShortcutChord("q", 1), ShortcutChord(",", 1), ShortcutChord("m", 3), ShortcutChord("f", 5), ShortcutChord("ab"), ShortcutChord("y", 16)] {
            check("reject invalid/reserved \(chord)", ShortcutSettings.problem(in: [brushID: chord]) != nil)
        }
        settings.save([brushID: ShortcutChord("y")])
        check("implicit Shift follows tool rebind", settings.canvasEvent(event("y", 8)).map(ShortcutChord.init) == ShortcutChord("b", 8))
        check("retired Shift tool suppressed", settings.canvasEvent(event("b", 8)) == nil)
        settings.save(["Canvas & Layers:Decrease brush size": ShortcutChord("y", 6)])
        check("retired Chinese brush key suppressed", settings.canvasEvent(event("【", code: 33)) == nil)
        check("custom brush key normalized", settings.canvasEvent(event("y", 6))?.charactersIgnoringModifiers == "[")
        let legacy = ["Menus:Hide Compositor": ShortcutChord("y", 6)]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "keyboardShortcuts.v1")
        let migrated = ShortcutSettings(defaults: defaults)
        check("legacy Hide Others override migrates", migrated.overrides == ["Menus:Hide Others": ShortcutChord("y", 6)])
        check("Hide Others menu uses migrated binding", migrated.menu("h", modifiers: [.command, .option]) == ShortcutChord("y", 6))
        check("new ID wins over legacy", ShortcutSettings.migrate(legacy.merging(["Menus:Hide Others": ShortcutChord("y", 4)]) { _, new in new }) == ["Menus:Hide Others": ShortcutChord("y", 4)])
        migrated.save(migrated.overrides)
        check("migration survives save/reload", ShortcutSettings(defaults: defaults).overrides == migrated.overrides)
        check("new system reservation preserves other bindings", ShortcutSettings.migrate([brushID: ShortcutChord("f", 5), "Menus:Hide Others": ShortcutChord("y", 6)]) == ["Menus:Hide Others": ShortcutChord("y", 6)])

        let session = EditorSession()
        session.createDocument(width: 80, height: 80, emptyLayer: true)
        let table = LayerTableView()
        table.session = session
        let canvas = CanvasView(session: session)
        session.selectTool(.shape)
        session.shapeKind = .rectangle
        table.keyDown(with: event("u", 8))
        check("layer Shift-U cycles shape", session.shapeKind == .ellipse)
        canvas.keyDown(with: event("u", 8))
        check("canvas Shift-U cycles shape", session.shapeKind == .line)
        check("Shift-Tab is not a mode shortcut", !session.handleToolShortcut(event("\t", 8, code: 48)))
        check("Shift-Tab preserves shape", session.shapeKind == .line)
        table.keyDown(with: event("\t", code: 48))
        check("layer Tab cycles shape", session.shapeKind == .rectangle)
        for flags in [1, 2, 4, 9] { check("modified Tab is not mode shortcut \(flags)", !session.handleToolShortcut(event("\t", flags, code: 48))) }
        session.selectTool(.brush)
        session.brushSettings.diameter = 40
        session.brushSettings.hardness = 1
        canvas.keyDown(with: event("【", code: 33))
        check("Chinese brush size changes pixels tool state", session.brushSettings.diameter < 40)
        canvas.keyDown(with: event("【", 8, code: 33))
        check("Chinese Shift bracket changes hardness", session.brushSettings.hardness == 0.75)
        let beforeFillShortcut = session.document
        table.keyDown(with: event("\u{7f}", 8, code: 51))
        check("unavailable Shift-Delete never deletes a layer", session.document == beforeFillShortcut)
        await session.fillSelection(with: .foreground)
        let rect = CGRect(x: 30, y: 30, width: 10, height: 10)
        session.applySelection(CGPath(rect: rect, transform: nil), mode: .replace, name: "Select")
        session.selectTool(.idle)
        for (code, unit) in [(UInt16(123), CGSize(width: -1, height: 0)), (124, CGSize(width: 1, height: 0)), (125, CGSize(width: 0, height: 1)), (126, CGSize(width: 0, height: -1))] {
            for step in [1, 10] {
                let offset = session.selectedPixelNudge(for: event("", step == 1 ? 1 : 9, code: code))
                check("pixel nudge direction \(code) step \(step)", offset == CGSize(width: unit.width * CGFloat(step), height: unit.height * CGFloat(step)))
            }
        }
        for flags in [0, 2, 4, 3, 5] { check("pixel nudge rejects modifiers \(flags)", session.selectedPixelNudge(for: event("", flags, code: 124)) == nil) }
        let count = session.history.undoCount
        table.keyDown(with: event("", 1, code: 124))
        for _ in 0..<100 where session.history.undoCount == count { try await Task.sleep(for: .milliseconds(10)) }
        check("layer Cmd-right moves actual selected pixels", session.history.undoName == "Move Pixels" && session.selection?.path.boundingBoxOfPath.origin == CGPoint(x: 31, y: 30))
        check("pixel move is one undo step", session.history.undoCount == count + 1)
        session.undo()
        check("pixel nudge undo restores selection", session.selection?.path.boundingBoxOfPath == rect)
        session.redo()
        check("pixel nudge redo restores offset", session.selection?.path.boundingBoxOfPath.origin == CGPoint(x: 31, y: 30))
        let before = session.document
        await session.nudgePixels(CGSize(width: 1, height: 0), in: UUID())
        check("stale document callback rejected", session.document == before)
        session.deselect()
        check("no selection rejects pixel command", session.selectedPixelNudge(for: event("", 1, code: 124)) == nil)

        // Preserve the previously installed asynchronous Color Range repair.
        func colorFixture() throws -> EditorSession {
            let target = EditorSession()
            target.createDocument(width: 64, height: 64)
            let context = try BrushRaster.context(width: 64, height: 64, mask: false)
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
            let image = context.makeImage()!
            target.insert(ImportedImage(image: image, thumbnail: image, name: "Color range fixture"))
            target.beginColorRange()
            return target
        }
        let color = try colorFixture()
        let colorCount = color.history.undoCount
        color.sampleColorRange(at: CGPoint(x: 5, y: 5), shift: false, option: false)
        color.sampleColorRange(at: CGPoint(x: 50, y: 5), shift: false, option: false)
        color.commitColorRange()
        check("Color Range waits for newest sample", color.colorRange?.commitRequested == true)
        for _ in 0..<200 where color.colorRange?.isComputing == true { try await Task.sleep(for: .milliseconds(10)) }
        check("Color Range commits newest sample once", color.colorRange == nil && color.history.undoCount == colorCount + 1)
        check("Color Range keeps correct color", color.selection?.path.contains(CGPoint(x: 50, y: 5)) == true && color.selection?.path.contains(CGPoint(x: 5, y: 5)) == false)
        color.undo()
        check("Color Range undo", color.selection == nil)
        let cancelled = try colorFixture()
        cancelled.cancelColorRange()
        cancelled.selectAll()
        let original = cancelled.selection
        cancelled.beginColorRange()
        cancelled.sampleColorRange(at: CGPoint(x: 5, y: 5), shift: false, option: false)
        cancelled.commitColorRange()
        cancelled.cancelColorRange()
        try await Task.sleep(for: .milliseconds(300))
        check("Color Range cancel ignores late result", cancelled.colorRange == nil && cancelled.selection == original)
        let stale = try colorFixture()
        stale.sampleColorRange(at: CGPoint(x: 5, y: 5), shift: false, option: false)
        stale.commitColorRange()
        let replacement = CanvasDocument(width: 16, height: 16)
        stale.document = replacement
        try await Task.sleep(for: .milliseconds(300))
        stale.commitColorRange()
        stale.cancelColorRange()
        check("Color Range stale document callback rejected", stale.document == replacement)
        return result
    }
}

#if !SHORTCUT_CLT_CHECKS
@MainActor
struct ShortcutRegressionTests {
    @Test func shortcutMappingAndResponderRegressions() async throws {
        let result = try await ShortcutRegressionChecks.run()
        #expect(result.failures.isEmpty, "\(result.checks) checks: \(result.failures)")
    }
}
#endif
