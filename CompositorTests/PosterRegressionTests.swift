import AppKit
import ImageIO
#if !POSTER_CLT_CHECKS
import Testing
@testable import Compositor
#endif

@MainActor struct PosterRegressionChecks {
    struct Result { var checks = 0; var failures: [String] = []; var measurements: [String] = [] }
    static func run(output: URL, large: Bool = false) async throws -> Result {
        var result = Result()
        func check(_ label: String, _ value: Bool) { result.checks += 1; if !value { result.failures.append(label); print("FAIL: \(label)") } }
        func bytes(_ image: CGImage) throws -> [UInt8] {
            let c = try BrushRaster.copy(image)
            return Array(UnsafeBufferPointer(start: c.data!.assumingMemoryBound(to: UInt8.self), count: c.bytesPerRow * c.height))
        }
        func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [UInt8] {
            let c = try BrushRaster.copy(image); let p = c.data!.assumingMemoryBound(to: UInt8.self) + y * c.bytesPerRow + x * 4
            return Array(UnsafeBufferPointer(start: p, count: 4))
        }
        let red = FillColor(red: 1, green: 0, blue: 0), blue = FillColor(red: 0, green: 0, blue: 1)
        var fill = LayerFillStyle(kind: .linear, stops: [FillStop(position: 0, color: red), FillStop(position: 1, color: blue)], angle: 0)
        let gradient = try fill.render(width: 100, height: 80)
        check("linear endpoints", try pixel(gradient, 0, 40)[0] > 245 && pixel(gradient, 99, 40)[2] > 245)
        fill.reversed = true
        check("reverse gradient", try pixel(fill.render(width: 100, height: 80), 0, 40)[2] > 245)
        fill.reversed = false; fill.kind = .radial
        check("radial center", try pixel(fill.render(width: 100, height: 80), 50, 40)[0] > 245)
        fill.stops.insert(FillStop(position: 0.5, color: FillColor(red: 0, green: 1, blue: 0)), at: 1)
        check("multistop validation", fill.isValid)
        for kind in FillPattern.allCases {
            fill.kind = .pattern; fill.pattern = kind
            let pattern = try fill.render(width: 100, height: 80)
            let patternBytes = try bytes(pattern)
            check("pattern \(kind.rawValue)", Set(stride(from: 0, to: 100 * 80 * 4, by: 4).map { index in Array(patternBytes[index..<index+4]) }).count > 1)
        }
        fill.cellSize = 512; fill.scale = 10
        check("large logical tile bounded render", try fill.render(width: 32, height: 24).width == 32)
        fill.angle = .nan; check("fill rejects nonfinite", !fill.isValid); fill.angle = 0
        fill.stops[0].id = fill.stops[1].id; check("fill rejects duplicate IDs", !fill.isValid)
        fill = LayerFillStyle(kind: .linear)
        let session = EditorSession(); session.createNewProject(width: 96, height: 80)
        let originalRevision = session.history.currentRevision
        session.openFillLayer(); var draft = session.fillLayerDraft!; draft.style = fill
        await session.applyFillLayer(draft)
        check("fill creates editable layer", session.activeLayer?.liveFill?.style == fill && !session.isProjectBusy)
        let fillID = session.activeLayerID!, fillImage = session.activeLayer!.asset!.image
        let createdRevision = session.history.currentRevision
        check("fill history recorded", createdRevision != originalRevision)
        session.openFillLayer(editing: true); await session.applyFillLayer(session.fillLayerDraft!)
        check("identical fill no history", createdRevision == session.history.currentRevision && session.activeLayer!.asset!.image === fillImage)
        session.openFillLayer(editing: true); session.cancelFillLayer()
        check("fill cancel", session.activeLayer!.asset!.image === fillImage && !session.isProjectBusy)
        session.undo(); check("fill undo", !session.document!.layers.contains { $0.id == fillID })
        session.redo(); check("fill redo", session.activeLayer?.liveFill != nil)
        session.selectLayer(fillID); session.toggleSelectedLayerLock(.transparency)
        session.openFillLayer(editing: true); draft = session.fillLayerDraft!; draft.style.angle = 45
        await session.applyFillLayer(draft)
        check("fill transparency lock", session.history.currentRevision == createdRevision && session.fillLayerDraft != nil)
        session.cancelFillLayer(); session.toggleSelectedLayerLock(.transparency); session.brushError = nil
        var effects = LayerEffects(); effects.gradientOverlay = FillOverlayEffect(); effects.patternOverlay = FillOverlayEffect(fill: LayerFillStyle(kind: .pattern)); effects.bevel = BevelEffect()
        session.setEffects(effects)
        check("poster effects valid", effects.isValid && effects.usesPosterEffects && !effects.isEmpty)
        let plain = try await ImageExporter.shared.render(session.projectSnapshot()!)
        check("poster effects render", plain.image.width == 96 && plain.image.height == 80)
        var badEffect = effects; badEffect.bevel?.depth = .infinity; check("effect nonfinite rejected", !badEffect.isValid)
        let project = output.appendingPathComponent("poster-v12.comp")
        let snap = session.projectSnapshot()!
        try await ProjectStore.shared.save(snap, to: project, quickLook: ImageExporter.shared.quickLookImages(snap), mustNotExist: true)
        let loaded = try await ProjectStore.shared.load(from: project)
        check("format 12 fill/effects roundtrip", loaded.manifest.version == 12 && loaded.manifest.layers.last?.fill == fill && loaded.manifest.layers.last?.effects == effects)
        do { try await ProjectStore.shared.save(snap, to: project, mustNotExist: true); check("save no overwrite", false) } catch { check("save no overwrite", true) }
        var older = snap.manifest; older.version = 11
        do { try await ProjectStore.shared.validateSnapshot(ProjectSnapshot(manifest: older, images: snap.images)); check("v11 rejects v12 properties", false) } catch { check("v11 rejects v12 properties", true) }
        var raster = session.activeLayer!; raster.asset = try LiquifyRegressionChecks.fixture().asset
        check("pixel replacement invalidates editable fill", raster.liveFill == nil)
        let fixture = try LiquifyRegressionChecks.fixture(128, 96), source = fixture.asset!.image, sourceBytes = try bytes(source)
        check("mixer identity preserves image", try ChannelMixerSettings().apply(source) === source)
        check("selective identity preserves image", try SelectiveColorSettings().apply(source) === source)
        check("halftone zero preserves image", try ColorHalftoneSettings(strength: 0).apply(source, scale: 1) === source)
        var mixer = ChannelMixerSettings(); mixer.coefficients = [0,0,100,0, 0,100,0,0, 100,0,0,0]
        let swapped = try pixel(mixer.apply(source), 3, 4), oldPixel = try pixel(source, 3, 4)
        check("channel permutation", swapped[0] == oldPixel[2] && swapped[2] == oldPixel[0] && swapped[3] == oldPixel[3])
        mixer.coefficients = [.nan]; do { _ = try mixer.apply(source); check("invalid mixer", false) } catch { check("invalid mixer", true) }
        var selective = SelectiveColorSettings(); selective.cyan = 50; selective.range = .blues; selective.yellow = 40; selective.range = .reds
        check("selective remembers bands", selective.cyan == 50 && selective.adjustments[.blues]?[2] == 40)
        let selectedBytes = try bytes(selective.apply(source))
        check("selective preserves alpha", stride(from: 3, to: selectedBytes.count, by: 4).allSatisfy { selectedBytes[$0] == sourceBytes[$0] })
        for shape in HalftoneDot.allCases {
            let image = try ColorHalftoneSettings(shape: shape).apply(source, scale: 1), b = try bytes(image)
            check("halftone \(shape.rawValue) changes color", b != sourceBytes)
            check("halftone \(shape.rawValue) alpha", stride(from: 3, to: b.count, by: 4).allSatisfy { b[$0] == sourceBytes[$0] })
            check("halftone \(shape.rawValue) premultiplication", stride(from: 0, to: b.count, by: 4).allSatisfy { max(b[$0], b[$0+1], b[$0+2]) <= b[$0+3] })
        }
        let identity = "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"
        let lut = try ColorLUT.parse(Data(identity.utf8), name: "Identity.cube")
        check("3D red fastest trilinear", zip(lut.sample([0.2,0.3,0.4]), [0.2,0.3,0.4]).allSatisfy { abs($0-$1) < 0.000001 })
        let lut1 = try ColorLUT.parse(Data("LUT_1D_SIZE 2\nDOMAIN_MIN -1 -1 -1\nDOMAIN_MAX 1 1 1\n0 0 0\n1 1 1\n".utf8), name: "1D")
        check("1D domains", lut1.sample([0,0,0]) == [0.5,0.5,0.5])
        check("LUT zero no-op", try ColorLUTSettings(table: lut, strength: 0).apply(source) === source)
        for space in LUTSpace.allCases {
            let b = try bytes(ColorLUTSettings(table: lut, space: space).apply(source))
            check("identity LUT \(space.rawValue)", zip(b,sourceBytes).allSatisfy { abs(Int($0)-Int($1)) <= 1 })
        }
        for malformed in ["LUT_3D_SIZE 2\n0 0 0", "LUT_3D_SIZE 1", "LUT_1D_SIZE 2\nNaN 0 0\n1 1 1", "DOMAIN_MIN 0 0 0\nDOMAIN_MIN 0 0 0\n" + identity, identity + "DOMAIN_MIN 0 0 0"] {
            do { _ = try ColorLUT.parse(Data(malformed.utf8), name: "Bad"); check("LUT malformed rejected", false) } catch { check("LUT malformed rejected", true) }
        }
        var text = LayerTextStyle(); text.content = "叠绘中文，Hello！\n第二列"; text.fontName = "PingFangSC-Regular"; text.fontSize = 24; text.vertical = true; text.boxSize = CGSize(width: 160, height: 260)
        let vertical = try EditorSession.textImage(text)
        check("vertical CJK pixels", try bytes(vertical).contains { $0 > 0 })
        text.alignment = .justified; text.vertical = false
        let horizontal = try EditorSession.textImage(text)
        check("horizontal/vertical differ", try bytes(vertical) != bytes(horizontal))
        check("new typography Codable", try JSONDecoder().decode(LayerTextStyle.self, from: JSONEncoder().encode(text)) == text)
        let edge = try EdgeRefinement(owner: EditOwner(documentID: UUID(), revision: UUID()), layer: fixture, selection: nil)
        let initial = edge.levels; edge.mode = .hide; edge.diameter = 50; edge.strength = 1
        edge.beginStroke(); edge.paint(at: CGPoint(x: 32, y: 32)); edge.endStroke()
        check("edge brush hides", edge.levels != initial)
        let painted = edge.levels; edge.undo(); check("edge undo", edge.levels == initial); edge.redo(); check("edge redo", edge.levels == painted)
        edge.diameter = .nan; edge.beginStroke(); edge.paint(at: .zero); edge.paint(at: CGPoint(x: 1e100, y: 0)); edge.endStroke()
        check("edge invalid brush safe", edge.levels.allSatisfy(\.isFinite))
        let mask = try EdgeRefinement.renderMask(painted, width: 128, height: 96, feather: 2, shift: -1, contrast: 10)
        check("edge mask gray", LayerMask.isValid(try LayerMask.asset(from: mask).image))
        let clean = try bytes(EdgeColorDecontamination.apply(source, mask: mask, amount: 0.8))
        check("decontamination preserves alpha", stride(from: 3, to: clean.count, by: 4).allSatisfy { clean[$0] == sourceBytes[$0] })
        check("decontamination zero identity", try EdgeColorDecontamination.apply(source, mask: mask, amount: 0) === source)
        let edgeSession = EditorSession(); edgeSession.document = CanvasDocument(width: 128, height: 96, layers: [fixture]); edgeSession.selectLayer(fixture.id)
        edgeSession.beginEdgeRefinement(); edgeSession.cancelEdgeRefinement()
        check("edge cancel keeps original", edgeSession.document!.layers.count == 1 && edgeSession.activeLayer!.asset!.image === source && !edgeSession.isProjectBusy)
        edgeSession.beginEdgeRefinement(); edgeSession.edgeRefinement!.mode = .hide; edgeSession.edgeRefinement!.beginStroke(); edgeSession.edgeRefinement!.paint(at: CGPoint(x: 30,y: 30)); edgeSession.edgeRefinement!.endStroke(); await edgeSession.applyEdgeRefinement()
        check("edge creates masked copy preserves source", edgeSession.document!.layers.count == 2 && edgeSession.document!.layers[0].asset!.image === source && !edgeSession.document!.layers[0].isVisible && edgeSession.activeLayer?.mask != nil)
        edgeSession.undo(); check("edge undo restores source visibility", edgeSession.document!.layers.count == 1 && edgeSession.document!.layers[0].isVisible)
        var export = BatchExportOptions(longSides: [0,48], prefix: "../../广告:")
        let destination = try await BatchImageExporter.shared.export(snap, selected: [], name: "Poster", options: export, folder: output)
        let files = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        check("batch export file count", files.count == 2)
        var dimensions = Set<Int>()
        for file in files {
            let cg = CGImageSourceCreateWithURL(file as CFURL,nil)!, image = CGImageSourceCreateImageAtIndex(cg,0,nil)!
            dimensions.insert(image.width)
            let parent = file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            let expectedParent = destination.resolvingSymlinksInPath().standardizedFileURL.path
            check("export sanitized path", parent == expectedParent && !file.lastPathComponent.contains(":"))
        }
        check("export aspect dimensions", dimensions == [96,48])
        export.individualLayers = true; export.format = .jpeg
        let individual = try await BatchImageExporter.shared.export(snap, selected: [fillID], name: "Poster", options: export, folder: output)
        check("selected-layer JPEG", try FileManager.default.contentsOfDirectory(atPath: individual.path).allSatisfy { $0.hasSuffix(".jpg") })
        let duplicate = try LiquifyRegressionChecks.fixture(128, 96)
        let collisionSession = EditorSession()
        collisionSession.document = CanvasDocument(width: 128, height: 96, layers: [fixture, duplicate])
        let collisionSnapshot = collisionSession.projectSnapshot()!
        let collision = try await BatchImageExporter.shared.export(collisionSnapshot, selected: [fixture.id, duplicate.id], name: "Poster",
            options: BatchExportOptions(longSides: [0], prefix: String(repeating: "前", count: 120), individualLayers: true), folder: output)
        check("long prefixes preserve all selected layer exports", try FileManager.default.contentsOfDirectory(atPath: collision.path).count == 2)
        let nativeSide = max(snap.manifest.width, snap.manifest.height)
        let deduplicated = try await BatchImageExporter.shared.export(snap, selected: [], name: "Poster",
            options: BatchExportOptions(longSides: [0, nativeSide]), folder: output)
        check("equivalent export sizes deduplicated per layer", try FileManager.default.contentsOfDirectory(atPath: deduplicated.path).count == 1)
        do { _ = try await BatchImageExporter.shared.export(snap, selected: [], name: "Bad", options: export, folder: output); check("invalid export rejected", false) } catch { check("invalid export rejected", true) }
        check("failed export removes partial directories", try FileManager.default.contentsOfDirectory(atPath: output.path).allSatisfy { !$0.hasSuffix(".partial") })
        let current = session.document!, rev = session.history.currentRevision
        let failure = await session.executePosterBatch(PosterBatchRequest(documentID: current.id, expectedRevision: rev, commands: [PosterCommand(kind: .addFill, fill: LayerFillStyle()), PosterCommand(kind: .opacity, opacity: .infinity)]))
        check("batch failure atomic", failure.status == "rejected" && session.document == current && session.history.currentRevision == rev && !session.history.hasPendingEdit && !session.isProjectBusy)
        let success = await session.executePosterBatch(PosterBatchRequest(documentID: current.id, expectedRevision: rev, commands: [PosterCommand(kind: .addFill, fill: LayerFillStyle()), PosterCommand(kind: .opacity, opacity: 0.6)]))
        check("batch success", success.status == "changed" && session.document!.layers.count == current.layers.count + 1 && session.activeLayer?.opacity == 0.6)
        session.undo(); check("batch single undo", session.document == current); session.redo()
        let stale = await session.executePosterBatch(PosterBatchRequest(documentID: current.id, expectedRevision: rev, commands: [PosterCommand(kind: .remove)]))
        check("batch stale rejected", stale.errorCode == "stale")
        let lockRev = session.lockRevision; session.toggleSelectedLayerLock(.content)
        check("session lock sequence advances", session.lockRevision != lockRev)
        let staleLocks = await session.executePosterBatch(PosterBatchRequest(documentID: current.id, expectedRevision: session.history.currentRevision, expectedLockRevision: lockRev, commands: [PosterCommand(kind: .remove)]))
        check("stale session state rejected", staleLocks.errorCode == "stale_locks")
        let locked = await session.executePosterBatch(PosterBatchRequest(documentID: current.id, expectedRevision: session.history.currentRevision, commands: [PosterCommand(kind: .invert)]))
        check("batch respects content lock", locked.errorCode == "locked")
        let commandSession = EditorSession()
        commandSession.document = CanvasDocument(width: 128, height: 96, layers: [fixture])
        commandSession.selectLayer(fixture.id)
        func execute(_ commands: [PosterCommand]) async -> PosterBatchResult {
            await commandSession.executePosterBatch(PosterBatchRequest(documentID: commandSession.document!.id,
                expectedRevision: commandSession.history.currentRevision, commands: commands))
        }
        let encoded = try await ImageExporter.shared.pngData(commandSession.projectSnapshot()!)
        let imported = await execute([PosterCommand(kind: .addImage, name: "Imported", imageData: encoded)])
        check("command imports image", imported.status == "changed" && commandSession.document!.layers.count == 2)
        let importedID = commandSession.activeLayerID!
        let maskOutcome = await execute([PosterCommand(kind: .setMask, maskData: encoded)])
        check("command imports normalized mask", maskOutcome.status == "changed" && LayerMask.isValid(commandSession.activeLayer!.mask!.asset.image))
        let maskBytes = try GuidedMatte.levels(of: commandSession.activeLayer!.mask!.asset.image, width: 128, height: 96)
        let inputPixels = try bytes(source)
        check("command mask uses luminance and alpha", maskBytes.enumerated().allSatisfy { index, value in
            let p = index * 4
            let red: Int = 54 * Int(inputPixels[p]), green: Int = 183 * Int(inputPixels[p+1]), blue: Int = 19 * Int(inputPixels[p+2])
            let expected: Int = (red + green + blue + 128) >> 8
            return abs(value * 255 - Float(expected)) <= 1
        })
        let maskIndex = commandSession.document!.layers.firstIndex { $0.id == importedID }!
        commandSession.document!.layers[maskIndex].mask!.isLinked = false
        let originalPlacement = commandSession.activeLayer!.transform
        var moved = originalPlacement; moved.origin.x += 15
        let transformed = await execute([PosterCommand(kind: .transform, transform: moved)])
        check("command transform preserves unlinked mask placement", transformed.status == "changed" && commandSession.activeLayer!.mask!.placement == originalPlacement)
        let clearMask = await execute([PosterCommand(kind: .setMask, clearMask: true)])
        check("command clears mask", clearMask.status == "changed" && commandSession.activeLayer!.mask == nil)
        let halftone = await execute([PosterCommand(kind: .filter, filter: "Color Halftone", halftone: ColorHalftoneSettings(size: 8, cyan: 10, magenta: 60, yellow: 20, black: 40, shape: .line, strength: 60))])
        check("command full halftone parameters", halftone.status == "changed")
        let preInvalid = commandSession.document
        let badHalftone = await execute([PosterCommand(kind: .filter, filter: "Color Halftone", halftone: ColorHalftoneSettings(size: .infinity))])
        check("command invalid halftone rolls back", badHalftone.errorCode == "invalid" && commandSession.document == preInvalid)
        let noLUT = await execute([PosterCommand(kind: .filter, filter: "Color Lookup")])
        check("command missing LUT rejected", noLUT.errorCode == "invalid")
        let withLUT = await execute([PosterCommand(kind: .filter, filter: "Color Lookup", lut: PosterLUT(cube: identity, strength: 50, space: .linear))])
        check("command LUT accepts cube and space", ["changed", "unchanged"].contains(withLUT.status))
        let bandSettings = try PosterSelectiveColor(adjustments: ["Reds": [20,0,0,0], "Blues": [0,0,30,0]], relative: false).settings()
        check("command selective bands", bandSettings.adjustments[.reds] == [20,0,0,0] && !bandSettings.relative)
        do { _ = try PosterSelectiveColor(adjustments: ["Unknown": [0,0,0,0]]).settings(); check("command unknown band rejected", false) }
        catch { check("command unknown band rejected", true) }
        let beforeRefine = commandSession.document!
        let refined = await execute([PosterCommand(kind: .refineEdges, edge: PosterEdgeOptions(strokes: [PosterEdgeStroke(mode: "Hide", diameter: 20, strength: 1, points: [CGPoint(x: 30,y: 30)])]))])
        check("command local edge brush copy", refined.status == "changed" && commandSession.document!.layers.count == beforeRefine.layers.count + 1 && commandSession.activeLayer!.mask != nil)
        commandSession.undo()
        check("command edge single undo", commandSession.document == beforeRefine)
        let visibility = await execute([PosterCommand(kind: .visibility, layerID: importedID, visible: false)])
        check("command visibility", visibility.status == "changed" && commandSession.activeLayer!.isVisible == false)
        commandSession.selectedLayerIDs = Set(commandSession.document!.layers.map(\.id))
        let countBeforeRemove = commandSession.document!.layers.count
        let removed = await execute([PosterCommand(kind: .remove)])
        check("implicit command targets active layer only", removed.status == "changed" && commandSession.document!.layers.count == countBeforeRemove - 1)
        check("missing run font reported", {
            var value = text; value.fontRuns = [LayerTextFontRun(location: 0, length: 1, fontName: "Missing-Poster-Font")]
            return value.unavailableFontNames.contains("Missing-Poster-Font")
        }())
        edgeSession.redo()
        edgeSession.selectLayer(edgeSession.document!.layers.last!.id)
        let firstPreview = edge.previewImage
        check("edge preview reused for zoom", edge.previewImage === firstPreview)
        let fillSession = EditorSession(); fillSession.createNewProject(width: 64, height: 64)
        fillSession.openFillLayer(); await fillSession.applyFillLayer(fillSession.fillLayerDraft!)
        fillSession.beginEdgeRefinement(); await fillSession.applyEdgeRefinement()
        check("mask-only refinement preserves editable fill copy", fillSession.activeLayer?.liveFill != nil)
        var editableText = LayerTextStyle(); editableText.content = "中文 ABC"; editableText.fontSize = 20
        let textAdded = await execute([PosterCommand(kind: .addText, text: editableText)])
        editableText.content = "叠绘海报 Mixed 中文"
        let textEdited = await execute([PosterCommand(kind: .editText, text: editableText)])
        check("command edits live text", textAdded.status == "changed" && textEdited.status == "changed" && commandSession.activeLayer?.liveText?.style == editableText)
        let cancelledFolder = output.appendingPathComponent("cancelled-export", isDirectory: true)
        try FileManager.default.createDirectory(at: cancelledFolder, withIntermediateDirectories: false)
        let cancelled = Task { try await BatchImageExporter.shared.export(snap, selected: [], name: "Cancelled", options: BatchExportOptions(), folder: cancelledFolder) }
        cancelled.cancel()
        do { _ = try await cancelled.value; check("batch cancellation throws", false) }
        catch is CancellationError { check("batch cancellation throws", true) }
        check("batch cancellation cleans staging", try FileManager.default.contentsOfDirectory(atPath: cancelledFolder.path).isEmpty)
        let partialCancelled = Task {
            try await BatchImageExporter.shared.export(snap, selected: [], name: "Partial", options: BatchExportOptions(longSides: [0,48,24]), folder: cancelledFolder) { completed, _ in
                if completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await partialCancelled.value; check("batch cancellation after first file throws", false) }
        catch is CancellationError { check("batch cancellation after first file throws", true) }
        check("batch cancellation after first file cleans outputs", try FileManager.default.contentsOfDirectory(atPath: cancelledFolder.path).isEmpty)
        let imeSession = EditorSession(); imeSession.createNewProject(width: 320, height: 180)
        imeSession.beginText(in: CGRect(x: 0, y: 0, width: 280, height: 160))
        let imeCanvas = CanvasView(session: imeSession)
        let editor = InlineTextEditor(canvas: imeCanvas)
        editor.synchronize(imeSession.textDraft!)
        editor.textView.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        check("native composition marked text retained", editor.textView.hasMarkedText())
        var refreshed = imeSession.textDraft!; refreshed.style.red = 1; imeSession.textDraft = refreshed
        editor.synchronize(refreshed)
        check("style refresh preserves native composition", editor.textView.hasMarkedText() && editor.textView.string == "nihao")
        editor.textView.insertText("你好", replacementRange: editor.textView.markedRange())
        check("native composition commits CJK", !editor.textView.hasMarkedText() && editor.textView.string == "你好")
        if large {
            let big = try LiquifyRegressionChecks.fixture(3840,2160).asset!.image
            for (name, operation) in [("Halftone 4K", { try ColorHalftoneSettings().apply(big, scale: 1) }), ("LUT 4K", { try ColorLUTSettings(table: lut).apply(big) })] {
                let start = Date(); _ = try operation(); result.measurements.append("\(name): \(String(format: "%.3f", Date().timeIntervalSince(start))) s")
            }
        }
        return result
    }
}
#if !POSTER_CLT_CHECKS
@Suite("Poster editing regression") struct PosterRegressionTests {
    @Test @MainActor func posterBatch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try await PosterRegressionChecks.run(output: folder)
        #expect(result.failures.isEmpty, "\(result.failures)")
    }
}
#endif
