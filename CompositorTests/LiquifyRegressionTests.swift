import AppKit
import Metal

#if !LIQUIFY_CLT_CHECKS
    import Testing
    @testable import Compositor
#endif

@MainActor
struct LiquifyRegressionChecks {
    struct Result {
        var checks = 0
        var failures: [String] = []
        var measurements: [String] = []
    }
    static func fixture(_ width: Int = 96, _ height: Int = 80) throws -> ImageLayer {
        let c = try BrushRaster.context(width: width, height: height, mask: false)
        let p = c.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * c.bytesPerRow + x * 4
                let a = UInt8(x % 9 == 0 ? 0 : x % 9 == 1 ? 128 : 255)
                p[i] = UInt8((x / 7 + y / 7) % 2 == 0 ? Int(a) : Int(a) / 3)
                p[i + 1] = UInt8(x * Int(a) / max(1, width - 1))
                p[i + 2] = UInt8(y * Int(a) / max(1, height - 1))
                p[i + 3] = a
            }
        }
        let image = c.makeImage()!
        return ImageLayer(
            asset: ImportedImage(
                image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: "Liquify Fixture"), origin: .zero)
    }
    static func run(large: Bool = false, output: String? = nil) async throws -> Result {
        var result = Result()
        func check(_ name: String, _ passes: Bool) {
            result.checks += 1
            if !passes {
                result.failures.append(name)
                print("FAIL: \(name)")
            }
        }
        func bytes(_ image: CGImage) throws -> Data {
            let c = try BrushRaster.copy(image)
            return Data(bytes: c.data!, count: c.bytesPerRow * c.height)
        }
        func create(_ layer: ImageLayer, alpha: Bool = false, selection: SelectionClip? = nil) throws
            -> LiquifyWorkspace
        {
            try LiquifyWorkspace(
                owner: EditOwner(documentID: UUID(), revision: UUID()), layer: layer, selection: selection,
                references: [], keepsAlpha: alpha)
        }
        func stroke(
            _ e: LiquifyWorkspace, _ tool: LiquifyTool, _ start: CGPoint = CGPoint(x: 35, y: 40),
            _ end: CGPoint = CGPoint(x: 52, y: 43)
        ) {
            e.tool = tool
            e.diameter = 56
            e.strength = 0.8
            e.fixedEdges = false
            e.beginStroke(start)
            e.append(end, elapsed: 0.08)
            e.endStroke()
        }
        let layer = try fixture()
        let original = try bytes(layer.asset!.image)
        for tool in LiquifyTool.allCases where tool != .freeze && tool != .thaw {
            let e = try create(layer)
            if tool == .reconstruct { stroke(e, .push) }
            let before = e.nodes
            stroke(e, tool)
            check("\(tool.rawValue) changes displacement", e.nodes != before)
            let cpu = try e.pixels.render(nodes: e.nodes, useGPU: false)
            if let gpu = e.pixels.gpu?.render(
                nodes: e.nodes, gridWidth: e.pixels.gridWidth, gridHeight: e.pixels.gridHeight, step: e.pixels.step,
                width: 96, height: 80, keepsAlpha: false)
            {
                let a = try bytes(cpu)
                let b = try bytes(gpu)
                check("\(tool.rawValue) CPU/Metal parity", zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
            } else {
                check("Metal sampler available on Metal hardware", MTLCreateSystemDefaultDevice() == nil)
            }
            let latest = e.nodes
            e.undo()
            check("\(tool.rawValue) stroke undo", e.nodes == before)
            e.redo()
            check("\(tool.rawValue) stroke redo", e.nodes == latest)
        }
        let frozen = try create(layer)
        frozen.tool = .freeze
        frozen.diameter = 1000
        frozen.hardness = 0.98
        frozen.strength = 1
        frozen.beginStroke(CGPoint(x: 48, y: 40))
        frozen.append(CGPoint(x: 48, y: 40), elapsed: 0.05)
        frozen.endStroke()
        let allFrozen = frozen.nodes
        stroke(frozen, .push)
        check("frozen area cannot warp", frozen.nodes == allFrozen && !frozen.hasWarp)
        frozen.reset(onlyFreeze: true)
        stroke(frozen, .push)
        check("thaw permits warp", frozen.hasWarp)
        let changed = frozen.nodes
        frozen.reset()
        check("restore removes warps", !frozen.hasWarp)
        frozen.undo()
        check("restore can be undone", frozen.nodes == changed)
        frozen.redo()
        check("restore can be redone", !frozen.hasWarp)
        frozen.undo()
        stroke(frozen, .twirl)
        check("new stroke clears redo", !frozen.canRedo)
        let canvas = LiquifyCanvasView(edit: frozen)
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 320)
        frozen.preview = try frozen.pixels.render(nodes: frozen.nodes)
        frozen.frozenOverlay = try frozen.pixels.overlay(nodes: frozen.nodes, width: 96, height: 80)
        let display = try BrushRaster.context(width: 400, height: 320, mask: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: display, flipped: true)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let displayBytes = Data(bytes: display.data!, count: display.bytesPerRow * display.height)
        check(
            "frozen overlay preserves opaque preview and checkerboard",
            stride(from: 3, to: displayBytes.count, by: 4).allSatisfy { displayBytes[$0] == 255 })
        check(
            "liquify canvas has accessibility identity",
            canvas.isAccessibilityElement() && canvas.accessibilityIdentifier() == "liquifyCanvas")
        let shortcutDomain = "com.compositor.liquify-shortcuts.\(UUID().uuidString)"
        let shortcutDefaults = UserDefaults(suiteName: shortcutDomain)!
        defer { shortcutDefaults.removePersistentDomain(forName: shortcutDomain) }
        let shortcuts = ShortcutSettings(defaults: shortcutDefaults)
        func key(_ text: String, _ modifiers: Int = 0) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: ShortcutChord(text, modifiers).cocoaModifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0xffff)!
        }
        let keyed = try create(layer)
        let keyedCanvas = LiquifyCanvasView(edit: keyed)
        keyed.diameter = 100
        keyed.hardness = 0.3
        check("advanced brush key handled", keyedCanvas.handleKeyDown(key("]"), shortcuts: shortcuts))
        check("advanced brush uses basic size step", keyed.diameter == 120)
        keyedCanvas.handleKeyDown(key("【"), shortcuts: shortcuts)
        check("Chinese brush-size punctuation works", keyed.diameter == 100)
        keyedCanvas.handleKeyDown(key("｛", 8), shortcuts: shortcuts)
        check("Chinese Shift-bracket changes hardness", keyed.hardness == 0.25 && keyed.diameter == 100)
        keyedCanvas.handleKeyDown(key("}", 8), shortcuts: shortcuts)
        check("Shift-close-bracket increases hardness", keyed.hardness == 0.5)
        keyed.typeStrengthDigit(4, at: 10)
        keyed.typeStrengthDigit(5, at: 10.1)
        check("two strength digits set exact percentage", keyed.strength == 0.45)
        keyed.typeStrengthDigit(0, at: 11)
        check("zero strength key means full strength", keyed.strength == 1)
        keyed.typeStrengthDigit(5, at: 11.1)
        check("leading zero strength key means five percent", keyed.strength == 0.05)
        keyedCanvas.handleKeyDown(key("8"), shortcuts: shortcuts)
        check("strength key routes through canvas", keyed.strength == 0.8)
        check("Command-bracket is not a brush shortcut", !keyedCanvas.handleKeyDown(key("]", 1), shortcuts: shortcuts))
        shortcuts.save(["Canvas & Layers:Increase brush size": ShortcutChord("y", 6)])
        keyedCanvas.handleKeyDown(key("]"), shortcuts: shortcuts)
        check("retired brush-size key is inactive", keyed.diameter == 100)
        keyedCanvas.handleKeyDown(key("y", 6), shortcuts: shortcuts)
        check("rebound brush-size key works", keyed.diameter == 120)
        shortcuts.save(["Menus:Undo": ShortcutChord("y", 5)])
        let beforeKeyStroke = keyed.nodes
        stroke(keyed, .push)
        let afterKeyStroke = keyed.nodes
        keyedCanvas.handleKeyDown(key("z", 1), shortcuts: shortcuts)
        check("retired undo key is inactive", keyed.nodes == afterKeyStroke)
        keyedCanvas.handleKeyDown(key("y", 5), shortcuts: shortcuts)
        check("rebound undo is local to advanced liquify", keyed.nodes == beforeKeyStroke)
        keyedCanvas.handleKeyDown(key("z", 9), shortcuts: shortcuts)
        check("redo is local to advanced liquify", keyed.nodes == afterKeyStroke)
        shortcuts.save([:])
        keyed.beginStroke(CGPoint(x: 35, y: 40))
        let strokeDiameter = keyed.diameter, strokeHardness = keyed.hardness, strokeStrength = keyed.strength
        keyedCanvas.handleKeyDown(key("]"), shortcuts: shortcuts)
        keyedCanvas.handleKeyDown(key("}", 8), shortcuts: shortcuts)
        keyedCanvas.handleKeyDown(key("1"), shortcuts: shortcuts)
        check("in-flight stroke keeps brush parameters", keyed.diameter == strokeDiameter && keyed.hardness == strokeHardness && keyed.strength == strokeStrength)
        keyed.endStroke()
        keyed.isApplying = true
        keyedCanvas.handleKeyDown(key("]"), shortcuts: shortcuts)
        keyedCanvas.handleKeyDown(key("1"), shortcuts: shortcuts)
        check("applying keeps brush parameters", keyed.diameter == strokeDiameter && keyed.strength == strokeStrength)
        keyed.isApplying = false
        let legacy = ["Menus:Liquify Workspace": ShortcutChord("y", 6),
                      "Canvas & Layers:Blur / Smudge / Liquify": ShortcutChord("q", 2)]
        shortcutDefaults.set(try JSONEncoder().encode(legacy), forKey: "keyboardShortcuts.v1")
        let migrated = ShortcutSettings(defaults: shortcutDefaults)
        check("renamed advanced shortcut survives reload", migrated.overrides["Menus:Advanced Liquify"] == ShortcutChord("y", 6))
        check("renamed basic shortcut survives reload", migrated.overrides["Canvas & Layers:Blur / Smudge / Basic Liquify"] == ShortcutChord("q", 2))
        let edges = try create(layer)
        edges.fixedEdges = true
        edges.diameter = 300
        edges.tool = .push
        edges.beginStroke(CGPoint(x: 1, y: 1))
        edges.append(CGPoint(x: 10, y: 10), elapsed: 0.02)
        edges.endStroke()
        check("pinned border stays fixed", edges.offset(at: .zero) == .zero)
        let alpha = try create(layer, alpha: true)
        stroke(alpha, .push)
        let alphaBytes = try bytes(alpha.pixels.render(nodes: alpha.nodes))
        check(
            "transparency lock preserves every alpha",
            stride(from: 3, to: original.count, by: 4).allSatisfy { original[$0] == alphaBytes[$0] })
        check(
            "premultiplied alpha stays valid",
            stride(from: 0, to: alphaBytes.count, by: 4).allSatisfy { i in
                (0..<3).allSatisfy { alphaBytes[i + $0] <= alphaBytes[i + 3] }
            })
        let cpuAlpha = try bytes(alpha.pixels.render(nodes: alpha.nodes, useGPU: false))
        check("alpha-lock CPU/Metal parity", zip(cpuAlpha, alphaBytes).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: 48, height: 80), transform: nil)
        let clip = try DocumentSelection(path: path).clip(canvas: CGSize(width: 96, height: 80))
        let selected = try create(layer, selection: clip)
        stroke(selected, .push)
        let selectedBytes = try bytes(selected.pixels.render(nodes: selected.nodes, useGPU: false))
        var outsideUnchanged = true
        for y in 0..<80 {
            for x in 49..<96 {
                for c in 0..<4 {
                    let i = (y * 96 + x) * 4 + c
                    if original[i] != selectedBytes[i] { outsideUnchanged = false }
                }
            }
        }
        check("outside selection unchanged", outsideUnchanged)
        if let gpu = selected.pixels.gpu?.render(
            nodes: selected.nodes, gridWidth: selected.pixels.gridWidth, gridHeight: selected.pixels.gridHeight,
            step: selected.pixels.step, width: 96, height: 80, keepsAlpha: false)
        {
            check(
                "selection CPU/Metal parity",
                zip(selectedBytes, try bytes(gpu)).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
        }
        let slow = try create(layer)
        let fast = try create(layer)
        for (e, n) in [(slow, 15), (fast, 120)] {
            e.fixedEdges = false
            e.diameter = 60
            e.tool = .twirl
            e.strength = 0.5
            e.beginStroke(CGPoint(x: 48, y: 40))
            for _ in 0..<n { e.append(CGPoint(x: 48, y: 40), elapsed: 0.25 / Double(n)) }
            e.endStroke()
        }
        let q = CGPoint(x: 60, y: 40)
        let sa = slow.offset(at: q)
        let fa = fast.offset(at: q)
        check("twirl integrates elapsed time", hypot(sa.x - fa.x, sa.y - fa.y) < 0.6)
        let session = EditorSession()
        session.document = CanvasDocument(width: 96, height: 80, layers: [layer])
        session.activeLayerID = layer.id
        session.history.reset()
        session.beginLiquify()
        check(
            "liquify blocks competing editors",
            session.liquify != nil && !session.canEditLayers && !session.canUseHistory
                && !session.canStartProjectOperation && !session.canAdjustColors)
        session.cancelLiquify()
        check("cancel preserves clean document", !session.isModified && session.activeEditOwner == nil)
        session.beginEdit("Edit")
        session.beginLiquify()
        check("pending transaction refuses workspace", session.liquify == nil)
        session.endEdit()
        session.toggleSelectedLayerLock(.content)
        session.beginLiquify()
        check("content lock refuses workspace", session.liquify == nil)
        session.toggleSelectedLayerLock(.content)
        session.toggleSelectedLayerLock(.position)
        session.beginLiquify()
        stroke(session.liquify!, .push)
        let applied = await session.applyLiquify()
        check(
            "copy applies as one transaction",
            applied && session.document?.layers.count == 2 && session.history.undoCount == 1)
        check(
            "copy hides original and preserves placement",
            session.document?.layers[0].isVisible == false && session.activeLayer?.transform == layer.transform)
        session.undo()
        check("main undo restores entire original", session.document?.layers == [layer])
        session.redo()
        check("main redo restores result", session.document?.layers.count == 2)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "liquify-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = session.projectSnapshot()!
        let png = try await ImageExporter.shared.pngData(snapshot)
        try await ProjectStore.shared.save(snapshot, to: directory.appendingPathComponent("result.comp"))
        let loaded = try await ProjectStore.shared.load(from: directory.appendingPathComponent("result.comp"))
        check("save and reopen preserves liquid pixels", try await ImageExporter.shared.pngData(loaded) == png)
        check("project format matches writer", loaded.manifest.version == ProjectManifest.current)
        session.undo()
        session.toggleSelectedLayerLock(.position)
        session.beginLiquify()
        session.liquify?.createsCopy = false
        stroke(session.liquify!, .bloat)
        check("current-layer apply succeeds", await session.applyLiquify())
        check(
            "current-layer apply retains identity",
            session.document?.layers.count == 1 && session.activeLayerID == layer.id)
        session.undo()
        session.beginLiquify()
        session.liquify?.tool = .freeze
        session.liquify?.diameter = 60
        session.liquify?.beginStroke(q)
        session.liquify?.append(q, elapsed: 0.02)
        session.liquify?.endStroke()
        check("freeze-only apply is unchanged", !(await session.applyLiquify()) && !session.isModified)
        session.beginLiquify()
        stroke(session.liquify!, .push)
        let replacement = CanvasDocument(width: 96, height: 80, layers: [layer])
        session.document = replacement
        check("stale owner cannot apply", !(await session.applyLiquify()) && session.document == replacement)
        session.cancelLiquify()
        session.history.reset()
        session.beginLiquify()
        stroke(session.liquify!, .push)
        let pending = Task { await session.applyLiquify() }
        await Task.yield()
        session.cancelLiquify()
        check(
            "cancel during rendering discards result",
            !(await pending.value) && session.document == replacement && session.activeEditOwner == nil)
        session.toggleSelectedLayerLock(.appearance)
        session.beginLiquify()
        stroke(session.liquify!, .push)
        check(
            "appearance lock prevents hiding original for copy",
            !(await session.applyLiquify()) && session.document == replacement)
        session.liquify?.createsCopy = false
        check("appearance lock permits current-layer pixels", await session.applyLiquify())
        session.undo()
        session.toggleSelectedLayerLock(.appearance)
        var shaped = layer
        shaped.shape = LayerShape(
            style: LayerShapeStyle(kind: .rectangle, red: 1, green: 0, blue: 0, cornerRadius: 0),
            image: layer.asset!.image)
        session.document?.layers = [shaped]
        session.history.reset()
        session.beginLiquify()
        check("shape requires raster copy", session.liquify?.mustUseCopy == true)
        session.liquify?.createsCopy = false
        stroke(session.liquify!, .push)
        check("shape apply forces preserved original", await session.applyLiquify())
        check(
            "raster copy removes editable metadata",
            session.document?.layers.first?.liveShape != nil && session.activeLayer?.shape == nil)
        var transformed = layer
        transformed.transform.rotation = 33
        transformed.transform.flipX = true
        transformed.transform.origin = CGPoint(x: 15, y: 10)
        transformed.transform.size = CGSize(width: 120, height: 100)
        transformed.mask = LayerMask.solid(revealing: true)
        transformed.mask?.isLinked = false
        transformed.mask?.placement = LayerTransform(origin: CGPoint(x: 0, y: 0), size: CGSize(width: 96, height: 80))
        session.document = CanvasDocument(width: 200, height: 160, layers: [transformed])
        session.activeLayerID = transformed.id
        session.history.reset()
        let documentClip = DocumentSelection(
            path: CGPath(rect: CGRect(x: 30, y: 30, width: 50, height: 60), transform: nil))
        session.document?.selection = documentClip
        session.beginLiquify()
        session.liquify?.createsCopy = false
        stroke(session.liquify!, .push)
        check("rotated scaled layer applies", await session.applyLiquify())
        check(
            "transform and independent mask preserved",
            session.activeLayer?.transform == transformed.transform && session.activeLayer?.mask == transformed.mask)
        check("document selection preserved", session.selection == documentClip)
        let workspace = ProjectWorkspace()
        workspace.current.session.document = CanvasDocument(width: 96, height: 80, layers: [layer])
        workspace.current.session.activeLayerID = layer.id
        workspace.current.session.beginLiquify()
        check("workspace prevents tab switching", !workspace.canSwitch)
        await workspace.settlePendingEdits()
        check(
            "quit settles liquify without modification",
            workspace.canSwitch && workspace.current.session.liquify == nil && !workspace.current.session.isModified)
        check("oversize memory rejected before allocation", !LiquifyPixels.fits(width: 30000, height: 30000))
        let linked = EditorSession()
        var scaledLayer = layer
        scaledLayer.transform.size = CGSize(width: 192, height: 160)
        linked.document = CanvasDocument(width: 192, height: 160, layers: [scaledLayer])
        linked.activeLayerID = layer.id
        linked.selectTool(.blur)
        linked.brushSettings.diameter = 64
        linked.brushSettings.hardness = 0.75
        linked.brushSettings.opacity = 0.4
        linked.beginLiquify()
        check("basic brush size accounts for layer scale", linked.liquify?.diameter == 32)
        check("advanced inherits basic hardness and strength", linked.liquify?.hardness == 0.75 && linked.liquify?.strength == 0.4)
        linked.liquify?.diameter = 100
        linked.cancelLiquify()
        check("cancel preserves basic brush preferences", linked.brushSettings.diameter == 64 && linked.brushSettings.opacity == 0.4)
        linked.beginLiquify()
        stroke(linked.liquify!, .push)
        check("linked advanced result commits", await linked.applyLiquify())
        check("applied advanced brush returns to basic units", linked.brushSettings.diameter == 112 && linked.brushSettings.opacity == 0.8)
        check("advanced history has a distinct localized action", linked.history.undoName == "Advanced Liquify")
        linked.selectTool(.brush)
        let otherTip = linked.brushSettings
        linked.beginLiquify()
        check("menu entry reads the parked basic brush", linked.liquify?.diameter == 56 && linked.liquify?.strength == 0.8)
        linked.cancelLiquify()
        check("advanced entry leaves other brush families unchanged", linked.brushSettings.diameter == otherTip.diameter && linked.brushSettings.opacity == otherTip.opacity)
        let history = try create(layer)
        for _ in 0..<120 { stroke(history, .push) }
        check(
            "local history stays within budget",
            history.historyBytes <= LiquifyWorkspace.historyLimit && history.historyWasTrimmed)
        if let output {
            let dir = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let demo = EditorSession()
            let raster = try fixture(720, 480)
            demo.document = CanvasDocument(width: 720, height: 480, layers: [raster])
            demo.activeLayerID = raster.id
            try await ProjectStore.shared.save(
                demo.projectSnapshot()!, to: dir.appendingPathComponent("liquify-fixture.comp"))
        }
        if large {
            for side in [4096, 8192] {
                let start = Date()
                let big = try fixture(side, side)
                let e = try create(big)
                e.diameter = 800
                e.tool = .push
                e.fixedEdges = true
                var updates: [Double] = []
                e.beginStroke(CGPoint(x: side / 2, y: side / 2))
                for i in 1...60 {
                    let time = Date()
                    e.append(
                        CGPoint(x: Double(side) / 2 + Double(i) * 3, y: Double(side) / 2 + sin(Double(i) / 10) * 50),
                        elapsed: 1 / 60)
                    updates.append(Date().timeIntervalSince(time))
                }
                e.endStroke()
                let renderStart = Date()
                let rendered = try e.pixels.render(nodes: e.nodes)
                let finalSeconds = Date().timeIntervalSince(renderStart)
                check("\(side) full-resolution render", rendered.width == side && rendered.height == side && e.hasWarp)
                let field = e.nodes
                e.undo()
                check("\(side) stroke undo", !e.hasWarp)
                e.redo()
                check("\(side) stroke redo", e.nodes == field)
                updates.sort()
                result.measurements.append(
                    "\(side)²: \(e.pixels.gpu == nil ? "CPU":"Metal") sampler; stroke median \(String(format:"%.2f",updates[30]*1000)) ms, p95 \(String(format:"%.2f",updates[57]*1000)) ms; final render \(String(format:"%.3f",finalSeconds)) s; total \(String(format:"%.3f",Date().timeIntervalSince(start))) s; history \(e.historyBytes) bytes"
                )
            }
        }
        return result
    }
}
#if !LIQUIFY_CLT_CHECKS
    struct LiquifyRegressionTests {
        @Test @MainActor func workspaceAndSafeCommit() async throws {
            let result = try await LiquifyRegressionChecks.run()
            #expect(result.failures.isEmpty, "\(result.failures)")
        }
    }
#endif
