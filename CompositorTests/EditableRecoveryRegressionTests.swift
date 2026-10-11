import AppKit
import ImageIO

#if !EDITABLE_RECOVERY_CLT_CHECKS
import Testing
@testable import Compositor
#endif

@MainActor
struct EditableRecoveryRegressionChecks {
    struct Result {
        var checks = 0
        var failures: [String] = []
        var measurements: [String] = []
    }
    static func bytes(_ image: CGImage) throws -> Data {
        let context = try BrushRaster.copy(image)
        return Data(bytes: context.data!, count: context.bytesPerRow * context.height)
    }
    static func fixture(_ side: Int = 96) throws -> ImageLayer {
        let context = try BrushRaster.context(width: side, height: side, mask: false)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<side { for x in 0..<side {
            let i = y * context.bytesPerRow + x * 4
            let alpha = x % 17 == 0 ? 0 : x % 17 == 1 ? 128 : 255
            pixels[i] = UInt8((x / 5 + y / 7) % 2 == 0 ? alpha : alpha / 4)
            pixels[i + 1] = UInt8(y * alpha / max(1, side - 1))
            pixels[i + 2] = UInt8(x * alpha / max(1, side - 1))
            pixels[i + 3] = UInt8(alpha)
        } }
        let image = context.makeImage()!
        return ImageLayer(asset: ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: "Fixture"), origin: .zero)
    }
    static func session(_ layer: ImageLayer) -> EditorSession {
        let session = EditorSession()
        session.document = CanvasDocument(width: layer.asset!.image.width, height: layer.asset!.image.height, layers: [layer])
        session.activeLayerID = layer.id
        session.history.reset()
        return session
    }
    static func stroke(_ edit: LiquifyWorkspace, tool: LiquifyTool = .push) {
        edit.tool = tool; edit.diameter = 55; edit.strength = 0.8; edit.fixedEdges = false
        edit.beginStroke(CGPoint(x: 35, y: 40)); edit.append(CGPoint(x: 52, y: 43), elapsed: 0.08); edit.endStroke()
    }
    static func record(_ snapshot: ProjectSnapshot, revision: UUID = UUID()) -> RecoveryRecord {
        RecoveryRecord(documentID: snapshot.manifest.documentID, revision: revision,
            projectVersion: snapshot.manifest.version, title: "Regression", originalPath: nil, date: Date())
    }
    static func run(output: URL, large: Bool = false, crash: Bool = false) async throws -> Result {
        var result = Result()
        func check(_ name: String, _ passed: Bool) {
            result.checks += 1
            if !passed { result.failures.append(name); print("FAIL: \(name)") }
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("editable-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let layer = try fixture(), original = try bytes(layer.asset!.image)
        let inverted = ColorLUT(name: "Inverse", size: 2, is1D: true, minimum: [0, 0, 0], maximum: [1, 1, 1], values: [[1, 1, 1], [0, 0, 0]])
        var nodes: [EditableFilterNode] = []
        for kind in EditableFilterKind.allCases where kind != .liquify {
            var node = EditableFilterNode(kind: kind); node.seed = 1234
            if kind == .colorLUT { node.lut.table = inverted }
            let stack = LayerFilterStack(source: layer.asset!, nodes: [node])
            let rendered = try stack.render()
            let direct = try PixelFilter.run(FilterJob(kind: kind.pixelKind!, image: layer.asset!.image, settings: node.settings,
                scale: 1, selection: nil, mapping: .identity, seed: node.seed))
            check("\(kind.rawValue) matches direct filter", try bytes(rendered) == bytes(direct))
            check("\(kind.rawValue) reproducible", try bytes(rendered) == bytes(stack.render()))
            var disabled = node; disabled.enabled = false
            check("\(kind.rawValue) disabled restores source", try bytes(LayerFilterStack(source: layer.asset!, nodes: [disabled]).render()) == original)
            var zero = node; zero.opacity = 0
            check("\(kind.rawValue) zero opacity restores source", try bytes(LayerFilterStack(source: layer.asset!, nodes: [zero]).render()) == original)
            var masked = node; masked.coverage = Data(repeating: 0, count: 96 * 96)
            check("\(kind.rawValue) empty captured mask restores source", try bytes(LayerFilterStack(source: layer.asset!, nodes: [masked]).render()) == original)
            var half = node; half.opacity = 0.5
            check("\(kind.rawValue) opacity mixes once", try bytes(LayerFilterStack(source: layer.asset!, nodes: [half]).render()) == bytes(LayerFilterStack.mix(rendered, over: layer.asset!.image, coverage: nil, opacity: 0.5)))
            nodes.append(node)
        }
        let s = session(layer)
        s.beginFilterStack(); s.filterStackEdit!.stack.nodes = nodes
        await s.renderFilterStack(commit: false)
        check("preview leaves document and history unchanged", s.document?.layers == [layer] && s.history.undoCount == 0)
        await s.renderFilterStack(commit: true)
        let applied = s.document!
        check("filter commit is one undo step", s.filterStackEdit == nil && s.history.undoCount == 1 && s.activeLayer?.filterStack?.nodes == nodes)
        s.undo(); check("undo restores original pixels and recipe", s.document?.layers == [layer])
        s.redo(); check("redo restores entire recipe", s.document == applied)
        s.beginFilterStack(); s.filterStackEdit!.stack.nodes.reverse(); s.cancelFilterStack()
        check("cancel discards reordered draft", s.document == applied && s.history.undoCount == 1)
        s.beginFilterStack(); s.filterStackEdit!.stack.nodes.reverse(); await s.renderFilterStack(commit: true)
        check("reorder renders from retained original", try bytes(s.activeLayer!.asset!.image) == bytes(s.activeLayer!.filterStack!.render()))
        check("noncommuting filters change appearance when reordered", try bytes(s.activeLayer!.asset!.image) != bytes(applied.layers[0].asset!.image))
        s.undo()
        let native = output.appendingPathComponent("filters.comp"), snapshot = s.projectSnapshot()!
        try await ProjectStore.shared.save(snapshot, to: native)
        let loaded = try await ProjectStore.shared.load(from: native)
        check("native format preserves recipe parameters", loaded.manifest.version == snapshot.manifest.version && loaded.filterStacks[layer.id]?.nodes == nodes)
        check("native preserves source and visible cache", try bytes(loaded.filterStacks[layer.id]!.source.image) == original && bytes(loaded.images[layer.id]!.image) == bytes(s.activeLayer!.asset!.image))
        let rerendered = try bytes(loaded.filterStacks[layer.id]!.render()), cached = try bytes(loaded.images[layer.id]!.image)
        check("reopened recipe rerenders identically", rerendered == cached)
        if rerendered != cached {
            let differences = zip(rerendered, cached).map { abs(Int($0) - Int($1)) }
            result.measurements.append("Reopened pixel difference: max \(differences.max() ?? 0), channels \(differences.filter { $0 != 0 }.count)")
        }
        let png = try await ImageExporter.shared.pngData(snapshot)
        try png.write(to: output.appendingPathComponent("filters.png"))
        check("PNG export survives save and reopen", try await ImageExporter.shared.pngData(loaded) == png)
        let composite = try await ImageExporter.shared.render(snapshot)
        let psd = try PSDWriter.encode(snapshot, composite: composite.image, mode: .layered)
        try psd.write(to: output.appendingPathComponent("filters.psd"))
        check("PSD contains rasterized recipe layer", try PSDReader.read(psd).layers.count == 1 && !PSDWriter.conversionNotes(snapshot).isEmpty)
        s.rasterizeFilterStack()
        check("rasterize retains visible pixels and writes format 13", s.activeLayer?.filterStack == nil && s.projectSnapshot()?.manifest.version == 13 && s.activeLayer?.asset?.image === applied.layers[0].asset?.image)
        s.undo(); check("undo rasterize restores recipe", s.activeLayer?.filterStack?.nodes == nodes)
        s.beginEdit("Edit"); s.document?.layers[0].transform.origin.x += 5; s.endEdit()
        check("position edit preserves recipe", s.activeLayer?.filterStack?.nodes == nodes)
        s.undo()
        s.beginEdit("Edit"); s.document?.layers[0].asset = layer.asset; s.endEdit()
        check("direct pixel edit bakes stale recipe", s.activeLayer?.filterStack == nil)
        s.undo(); check("undo pixel edit restores recipe", s.activeLayer?.filterStack?.nodes == nodes)
        let resizedCanvas = try await CanvasResizer.shared.resize(snapshot, to: CanvasSizeOptions(width: 120, height: 110))
        check("canvas resize preserves filter source and recipe", resizedCanvas.filterStacks[layer.id]?.source.image === snapshot.filterStacks[layer.id]?.source.image && resizedCanvas.filterStacks[layer.id]?.nodes == nodes)
        let croppedCanvas = try await CanvasResizer.shared.resize(snapshot, to: CanvasSizeOptions(width: 50, height: 60, contentOffset: CGPoint(x: -10, y: -20)))
        check("crop retains source outside cropped canvas", croppedCanvas.filterStacks[layer.id]?.nodes == nodes && croppedCanvas.images[layer.id]?.image.width == 96)
        let dpiOnly = try await ImageResizer.shared.resize(snapshot, to: ImageSizeOptions(width: 96, height: 96, resolution: 300))
        check("DPI-only edit preserves source and recipe", dpiOnly.manifest.version == snapshot.manifest.version && dpiOnly.filterStacks[layer.id]?.nodes == nodes)
        let resampled = try await ImageResizer.shared.resize(snapshot, to: ImageSizeOptions(width: 48, height: 48, resolution: 72))
        check("image resampling bakes recipe and writes version 13", resampled.manifest.version == 13 && resampled.filterStacks.isEmpty && resampled.manifest.layers[0].editableFilters == nil)
        s.beginEdit("Edit"); s.document?.layers[0].mask = LayerMask.solid(revealing: true); s.endEdit()
        check("adding layer mask preserves recipe", s.activeLayer?.filterStack?.nodes == nodes)
        let maskedSnapshot = s.projectSnapshot()!, maskedURL = temporary.appendingPathComponent("masked.comp")
        try await ProjectStore.shared.save(maskedSnapshot, to: maskedURL)
        let reopenedMask = try await ProjectStore.shared.load(from: maskedURL)
        check("native round trip keeps layer mask outside recipe", reopenedMask.masks[layer.id] != nil && reopenedMask.filterStacks[layer.id]?.nodes == nodes)
        s.undo()
        s.toggleSelectedLayerLock(.content); s.beginFilterStack()
        check("content lock blocks filter entry", s.filterStackEdit == nil)
        s.toggleSelectedLayerLock(.content)
        s.toggleSelectedLayerLock(.transparency); s.beginFilterStack()
        check("transparency lock blocks filter entry", s.filterStackEdit == nil)
        s.toggleSelectedLayerLock(.transparency)
        s.beginFilterStack(); s.filterStackEdit!.stack.nodes[0].radius = 7
        let staleRender = Task { await s.renderFilterStack(commit: true) }
        await Task.yield(); s.cancelFilterStack(); await staleRender.value
        check("cancel in-flight filter cannot commit", s.activeLayer?.filterStack?.nodes == nodes && s.activeEditOwner == nil && !s.isProjectBusy)
        s.beginFilterStack(); s.filterStackEdit!.stack.nodes[0].radius = 9
        let switchedRender = Task { await s.renderFilterStack(commit: true) }
        await Task.yield()
        let replacement = CanvasDocument(width: 96, height: 96, layers: [layer])
        s.document = replacement
        await switchedRender.value
        check("old async filter callback cannot edit replacement document", s.document == replacement)
        s.cancelFilterStack()

        let liquid = session(layer)
        liquid.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 60, height: 96), transform: nil))
        liquid.beginLiquify(); liquid.liquify!.createsCopy = false; stroke(liquid.liquify!)
        stroke(liquid.liquify!, tool: .freeze)
        let saved = liquid.liquify!.savedState
        check("saved liquid field valid", saved.isValid)
        check("persistent liquid render equals live CPU render", try bytes(saved.render(layer.asset!.image)) == bytes(liquid.liquify!.pixels.render(nodes: liquid.liquify!.nodes, useGPU: false)))
        check("persistent liquid commits", await liquid.applyLiquify())
        liquid.beginFilterStack(); liquid.filterStackEdit!.stack.nodes.append(nodes[2]); await liquid.renderFilterStack(commit: true)
        let firstLiquid = liquid.activeLayer!.filterStack!.nodes[0].id
        let liquidSnapshot = liquid.projectSnapshot()!
        try await ProjectStore.shared.save(liquidSnapshot, to: output.appendingPathComponent("liquify.comp"))
        let liquidLoaded = try await ProjectStore.shared.load(from: output.appendingPathComponent("liquify.comp"))
        liquid.installProject(liquidLoaded, from: nil)
        check("native preserves field freeze mask and brush settings", liquid.activeLayer?.filterStack?.nodes[0].liquify == saved)
        liquid.document?.selection = DocumentSelection(path: CGPath(rect: .zero, transform: nil))
        await liquid.beginSavedLiquify(firstLiquid)
        check("saved liquid opens despite current empty selection", liquid.liquify?.savedState == saved && liquid.liquify?.createsCopy == false)
        check("unchanged saved liquid creates no history", !(await liquid.applyLiquify()) && liquid.history.undoCount == 0)
        await liquid.beginSavedLiquify(firstLiquid); stroke(liquid.liquify!, tool: .bloat)
        let altered = liquid.liquify!.savedState
        check("saved liquid re-edit commits", await liquid.applyLiquify())
        let recomputed = try bytes(liquid.activeLayer!.filterStack!.render()) == bytes(liquid.activeLayer!.asset!.image)
        check("re-edit replaces node and recomputes following noise", liquid.activeLayer?.filterStack?.nodes.count == 2 && liquid.activeLayer?.filterStack?.nodes[0].liquify == altered && recomputed)
        liquid.undo(); check("undo re-edit restores original field", liquid.activeLayer?.filterStack?.nodes[0].liquify == saved)
        liquid.redo(); check("redo re-edit restores altered field", liquid.activeLayer?.filterStack?.nodes[0].liquify == altered)
        liquid.document?.selection = nil
        liquid.beginLiquify(); liquid.liquify!.createsCopy = false; stroke(liquid.liquify!, tool: .pinch)
        check("second liquid appends independently", await liquid.applyLiquify() && liquid.activeLayer?.filterStack?.nodes.count == 3)
        await liquid.beginSavedLiquify(firstLiquid)
        check("earlier liquid reconstructs prefix input", try bytes(liquid.liquify!.pixels.render(nodes: saved.field, useGPU: false)) == bytes(saved.render(layer.asset!.image)))
        liquid.cancelLiquify()
        var invalid = nodes[0]; invalid.coverage = Data([0])
        check("bad coverage is rejected", !LayerFilterStack(source: layer.asset!, nodes: [invalid]).isValid)
        invalid = nodes[0]; invalid.version = 99
        check("unknown node version is rejected", !invalid.isValid)
        var broken = saved; broken.field.removeLast()
        check("truncated liquid field is rejected", !broken.isValid)
        let savedNodeFile = liquidLoaded.manifest.layers[0].editableFilters!.nodeFiles[0]
        let tampered = temporary.appendingPathComponent("tampered.comp")
        try FileManager.default.copyItem(at: output.appendingPathComponent("liquify.comp"), to: tampered)
        try Data("{}".utf8).write(to: tampered.appendingPathComponent("edits/" + savedNodeFile))
        do { _ = try await ProjectStore.shared.load(from: tampered); check("corrupt recipe rejected instead of silently flattening", false) }
        catch { check("corrupt recipe rejected instead of silently flattening", true) }

        let recovery = RecoveryStore(directory: temporary.appendingPathComponent("Recovery"))
        let rec = record(liquidSnapshot), recoveryURL = recovery.directory.appendingPathComponent(rec.documentID.uuidString + ".comp")
        try await recovery.write(liquidSnapshot, record: rec)
        let initialStats = await recovery.lastWriteStatistics
        check("first recovery encodes cache and source", initialStats.encodedImages == 2)
        try await recovery.write(liquidSnapshot, record: record(liquidSnapshot))
        let reuse = await recovery.lastWriteStatistics
        check("unchanged recovery reuses all images and nodes", reuse.encodedImages == 0 && reuse.reusedFiles >= 4 && reuse.writtenBytes < initialStats.writtenBytes)
        let restored = try await recovery.load(recoveryURL)
        let restoredPNG = try await ImageExporter.shared.pngData(restored)
        let liquidPNG = try await ImageExporter.shared.pngData(liquidSnapshot)
        check("recovery keeps editable liquid and filter pixels", restored.filterStacks[layer.id]?.nodes == liquidSnapshot.filterStacks[layer.id]?.nodes && restoredPNG == liquidPNG)
        let renamedSession = session(layer); renamedSession.installProject(liquidSnapshot, from: nil)
        renamedSession.document?.layers[0].name = "Renamed"
        let renamed = renamedSession.projectSnapshot()!
        try await recovery.write(renamed, record: record(renamed))
        check("metadata-only recovery encodes zero images", await recovery.lastWriteStatistics.encodedImages == 0)
        let limited = RecoveryStore(directory: recovery.directory, byteLimit: 1)
        do { try await limited.write(renamed, record: record(renamed)); check("capacity failure rejects checkpoint", false) }
        catch { check("capacity failure rejects checkpoint", true) }
        check("capacity failure keeps prior complete package", try await recovery.load(recoveryURL).manifest.layers[0].name == "Renamed")
        let targetImage = recoveryURL.appendingPathComponent("images/" + renamed.manifest.layers[0].imageFile!)
        let good = try Data(contentsOf: targetImage)
        var damaged = good; damaged[damaged.count / 2] ^= 0xff
        try damaged.write(to: targetImage)
        do { try await recovery.write(renamed, record: record(renamed)); check("damaged cached resource cannot be overwritten", false) }
        catch { check("damaged cached resource cannot be overwritten", true) }
        check("damaged resource remains available for review", try Data(contentsOf: targetImage) == damaged)
        try good.write(to: targetImage)
        try await recovery.markClosed(rec.documentID)
        try await recovery.write(renamed, record: record(renamed))
        check("normal-close metadata does not break resource reuse", await recovery.lastWriteStatistics.encodedImages == 0)
        check("new checkpoint clears normal-close flag", try await recovery.entries().first?.record?.closedNormally == false)
        try await recovery.remove(recoveryURL)
        try await recovery.write(renamed, record: record(renamed))
        check("deleted recovery can be rebuilt without stale reuse index", try await recovery.load(recoveryURL).manifest.layers[0].name == "Renamed")
        try FileManager.default.removeItem(at: recoveryURL)
        try await recovery.write(renamed, record: record(renamed))
        check("external removal does not permanently block future recovery", await recovery.lastWriteStatistics.encodedImages == 2)

        let quotaStore = RecoveryStore(directory: temporary.appendingPathComponent("Quota"), recordLimit: 2)
        let blocker = session(layer).projectSnapshot()!
        try await quotaStore.write(liquidSnapshot, record: record(liquidSnapshot))
        try await quotaStore.write(blocker, record: record(blocker))
        let retryWorkspace = ProjectWorkspace(recoveryStore: quotaStore)
        let firstTab = retryWorkspace.current, secondTab = retryWorkspace.addTab(reuseEmpty: false)
        for (index, tab) in [firstTab, secondTab].enumerated() {
            tab.session.document = CanvasDocument(width: 96, height: 96, layers: [layer])
            tab.session.activeLayerID = layer.id
            tab.session.history.reset()
            tab.session.renameLayer(layer.id, to: "Retry \(index)")
            await tab.session.recovery!.flush()
        }
        check("record limit blocks both new documents with a visible error", firstTab.session.recoveryError != nil && secondTab.session.recoveryError != nil)
        check("record limit preserves every existing copy", try await quotaStore.entries().count == 2)
        do { try await quotaStore.write(firstTab.session.projectSnapshot()!, record: record(firstTab.session.projectSnapshot()!)); check("record quota reports document limit", false) }
        catch RecoveryError.recordLimit(let limit) { check("record quota reports document limit", limit == 2) }
        catch { check("record quota reports document limit", false) }
        firstTab.session.renameLayer(layer.id, to: "Latest retry")
        try await quotaStore.remove(quotaStore.directory.appendingPathComponent(rec.documentID.uuidString + ".comp"))
        await retryWorkspace.retryFailedRecoveryCopies()
        check("one freed slot retries the inactive tab without hiding the remaining failure", firstTab.session.recoveryError == nil && secondTab.session.recoveryError != nil)
        let retriedURL = quotaStore.directory.appendingPathComponent(firstTab.session.document!.id.uuidString + ".comp")
        check("retry writes latest committed state and keeps unsaved marker", try await quotaStore.load(retriedURL).manifest.layers[0].name == "Latest retry" && firstTab.session.isModified)
        let blockerURL = quotaStore.directory.appendingPathComponent(blocker.manifest.documentID.uuidString + ".comp")
        check("retry does not evict the other existing copy", try await quotaStore.load(blockerURL).manifest.documentID == blocker.manifest.documentID)
        secondTab.session.recoveryError = nil
        try await quotaStore.remove(blockerURL)
        await retryWorkspace.retryFailedRecoveryCopies()
        let remainingCopies = try await quotaStore.entries()
        check("second freed slot retries even after the error banner was dismissed", secondTab.session.recoveryError == nil && secondTab.session.isModified && remainingCopies.count == 2)
        await retryWorkspace.retryFailedRecoveryCopies()
        check("repeated successful retry creates no extra copies", try await quotaStore.entries().count == 2)

        let continuous = session(layer)
        let timedStore = RecoveryStore(directory: temporary.appendingPathComponent("Timed"))
        let coordinator = RecoveryCoordinator(session: continuous, title: "Timed", store: timedStore,
            delay: .milliseconds(150), maximumDelay: .milliseconds(240))
        continuous.recovery = coordinator
        var observedWhileEditing = false
        for n in 0..<18 {
            continuous.renameLayer(layer.id, to: "Continuous \(n)")
            try await Task.sleep(for: .milliseconds(30))
            if n >= 9, try await !timedStore.entries().isEmpty { observedWhileEditing = true }
        }
        check("continuous commits cannot postpone maximum checkpoint", observedWhileEditing)
        await coordinator.flush()
        let timedURL = timedStore.directory.appendingPathComponent(continuous.document!.id.uuidString + ".comp")
        check("manual flush drains newest committed revision", try await timedStore.load(timedURL).manifest.layers[0].name == "Continuous 17")
        check("recovery never clears dirty marker", continuous.isModified && continuous.projectURL == nil)
        continuous.renameLayer(layer.id, to: "Committed")
        continuous.beginEdit("Edit"); continuous.document?.layers[0].name = "Uncommitted preview"
        try await Task.sleep(for: .milliseconds(280))
        check("pending gesture cannot block older committed checkpoint", try await timedStore.load(timedURL).manifest.layers[0].name == "Committed")
        continuous.document?.layers[0].name = "Committed"; continuous.endEdit()
        continuous.renameLayer(layer.id, to: "Before close")
        await coordinator.finishNormally()
        let closedEntries = try await timedStore.entries()
        check("normal close flushes debounce before marking closed", try await timedStore.load(timedURL).manifest.layers[0].name == "Before close" && closedEntries.first?.record?.closedNormally == true)
        continuous.undo(); await coordinator.flush()
        check("undo checkpoint follows history", try await timedStore.load(timedURL).manifest.layers[0].name == "Committed")
        continuous.redo(); await coordinator.flush()
        check("redo checkpoint follows history", try await timedStore.load(timedURL).manifest.layers[0].name == "Before close")
        continuous.renameLayer(layer.id, to: "Before document switch")
        continuous.document = CanvasDocument(width: 96, height: 96, layers: [layer])
        continuous.history.reset()
        let switchedDocument = continuous.document
        await coordinator.flush()
        check("queued checkpoint stays bound to original document", try await timedStore.load(timedURL).manifest.layers[0].name == "Before document switch")
        check("old checkpoint cannot change new document flags", continuous.document == switchedDocument && !continuous.isModified && continuous.recoveryError == nil)
        continuous.document = CanvasDocument(id: rec.documentID, width: 96, height: 96, layers: [layer])
        continuous.history.reset()
        let stressURL = timedStore.directory.appendingPathComponent(rec.documentID.uuidString + ".comp")
        let beforeStress = Date()
        for n in 0..<40 {
            continuous.beginFilterStack(); var node = nodes[n % nodes.count]; node.amount = Double(n + 1)
            continuous.filterStackEdit!.stack.nodes = [node]; await continuous.renderFilterStack(commit: true)
        }
        await coordinator.flush()
        let afterStress = try await timedStore.load(stressURL)
        check("continuous async filter commits are recovered while busy flag unwinds", afterStress.filterStacks[layer.id]?.nodes == continuous.activeLayer?.filterStack?.nodes)
        check("stress keeps document history bounded", continuous.history.undoCount <= 100 && continuous.activeEditOwner == nil && !continuous.isProjectBusy)
        result.measurements.append(String(format: "40 filter commits and recovery: %.3f s", Date().timeIntervalSince(beforeStress)))

        if crash {
            let crashRoot = temporary.appendingPathComponent("Crash")
            let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--crash-writer", crashRoot.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: crashRoot.appendingPathComponent("ready").path) {
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(35))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            let crashStore = RecoveryStore(directory: crashRoot)
            let entries = try await crashStore.entries()
            check("killed writer leaves a committed recovery package", entries.count == 1 && entries[0].error == nil)
            if let entry = entries.first {
                let survived = try await crashStore.load(entry.url)
                check("killed checkpoint is complete and readable", survived.images.count == 1 && survived.manifest.layers[0].name.hasPrefix("Crash "))
                try await crashStore.write(survived, record: record(survived))
                let remnants = try FileManager.default.contentsOfDirectory(at: crashRoot, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasSuffix(".recovery-stage") }
                check("restart removes interrupted stages after committed package validates", remnants.isEmpty)
            }
        }
        if large {
            for side in [4096, 8192] {
                let start = Date(), big = try fixture(side)
                var node = nodes[0]; node.radius = 2
                let stack = LayerFilterStack(source: big.asset!, nodes: [node])
                let image = try stack.render()
                check("\(side)² filter renders full extent", image.width == side && image.height == side)
                let bigSession = session(big)
                bigSession.document?.layers[0].filterStack = stack
                bigSession.document?.layers[0].asset = ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: "Large")
                let largeSnapshot = bigSession.projectSnapshot()!, store = RecoveryStore(directory: temporary.appendingPathComponent("Large\(side)"))
                try await store.write(largeSnapshot, record: record(largeSnapshot))
                let first = await store.lastWriteStatistics
                try await store.write(largeSnapshot, record: record(largeSnapshot))
                let second = await store.lastWriteStatistics
                check("\(side)² incremental checkpoint reuses source and cache", first.encodedImages == 2 && second.encodedImages == 0)
                let entry = try await store.entries()[0], reopened = try await store.load(entry.url)
                check("\(side)² recovery preserves visible pixels", try bytes(reopened.images[big.id]!.image) == bytes(image))
                result.measurements.append(String(format: "\(side)² filter + two checkpoints + reopen: %.3f s; first write %d bytes, incremental %d bytes", Date().timeIntervalSince(start), first.writtenBytes, second.writtenBytes))
            }
        }
        return result
    }
    static func crashWriter(_ directory: URL) async throws {
        let s = session(try fixture(512)), store = RecoveryStore(directory: directory)
        for n in 0..<100_000 {
            s.document?.layers[0].name = "Crash \(n)"
            let snapshot = s.projectSnapshot()!
            try await store.write(snapshot, record: record(snapshot))
            if n == 0 { try Data().write(to: directory.appendingPathComponent("ready")) }
        }
    }
    static func repeatedNativeSaves(_ count: Int = 500) async throws -> Result {
        var result = Result()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-save-stress-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let s = session(try fixture()), file = root.appendingPathComponent("repeated.comp")
        for n in 0..<count {
            s.document?.layers[0].name = "Save \(n)"
            let snapshot = s.projectSnapshot()!
            do {
                try await ProjectStore.shared.save(snapshot, to: file)
                let reopened = try await ProjectStore.shared.load(from: file)
                result.checks += 1
                if reopened.manifest.layers[0].name != "Save \(n)" { result.failures.append("native replacement \(n)") }
            } catch {
                let ns = error as NSError
                print("Native save \(n): \(ns.domain) \(ns.code) \(ns.userInfo)")
                result.checks += 1; result.failures.append("native save \(n)")
            }
        }
        return result
    }
}

#if !EDITABLE_RECOVERY_CLT_CHECKS
@MainActor struct EditableRecoveryRegressionTests {
    @Test func editableFiltersAndRecovery() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("editable-filter-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await EditableRecoveryRegressionChecks.run(output: output)
        #expect(result.failures.isEmpty, "\(result.failures)")
    }
}
#endif
