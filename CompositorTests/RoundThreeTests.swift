import AppKit
import Testing
@testable import Compositor

private actor FilterResultGate {
    private var waiting: CheckedContinuation<CGImage, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var started = false
    func hold() async -> CGImage {
        started = true; observers.forEach { $0.resume() }; observers = []
        return await withCheckedContinuation { waiting = $0 }
    }
    func ready() async {
        if started { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func finish(_ image: CGImage) { waiting?.resume(returning: image); waiting = nil }
}

@MainActor
struct RoundThreeTests {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("compositor-round3-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func image() throws -> CGImage {
        try PSDChannelCoder.image(width: 3, height: 2,
            rgba: [255,0,0,255, 0,255,0,255, 0,0,255,255, 0,255,255,255, 255,0,255,255, 255,255,0,255])
    }
    private func session() throws -> EditorSession {
        let image = try image()
        let layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: "中文像素"), origin: .zero)
        let s = EditorSession(); s.document = CanvasDocument(width: 8, height: 8, layers: [layer])
        s.activeLayerID = layer.id; s.selectedLayerIDs = [layer.id]
        return s
    }
    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let c = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: c)
        let p = try #require(c.data?.assumingMemoryBound(to: UInt8.self))
        return (0..<image.height).flatMap { Array(UnsafeBufferPointer(start: p + $0 * c.bytesPerRow, count: image.width * 4)) }
    }
    private func record(_ s: EditorSession, version: Int = ProjectManifest.current) throws -> RecoveryRecord {
        RecoveryRecord(documentID: try #require(s.document?.id), revision: s.history.currentRevision,
                       projectVersion: version, title: "未保存中文文档", originalPath: nil, date: Date())
    }
    private func edit(_ s: EditorSession, opacity: Double) {
        s.beginEdit("Opacity"); s.document?.layers[0].opacity = opacity; s.endEdit()
    }

    @Test func recoveryWritesUnsavedContentWithoutChangingSavedState() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecoveryStore(directory: dir), s = try session()
        let coord = RecoveryCoordinator(session: s, title: "中文草稿", store: store)
        let saved = dir.appendingPathComponent("original.comp")
        s.projectURL = saved
        edit(s, opacity: 0.4)
        let before = s.document, revision = s.history.currentRevision
        await coord.flush()
        #expect(s.isModified && s.projectURL == saved && s.document == before)
        #expect(s.history.currentRevision == revision && s.history.undoCount == 1)
        #expect(!FileManager.default.fileExists(atPath: saved.path))
        let entries = try await store.entries(); #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.record?.revision == revision && entry.record?.closedNormally == false)
        let loaded = try await store.load(entry.url)
        #expect(loaded.manifest.layers[0].opacity == 0.4 && loaded.manifest.version == ProjectManifest.current)
        #expect(try bytes(try #require(loaded.images.values.first?.image)) == bytes(try image()))
        await coord.finishNormally()
        #expect(try await store.entries().first?.record?.closedNormally == true)
        s.undo(); await coord.flush()
        #expect(try await store.entries().first?.record?.closedNormally == false)
        #expect(try await store.load(entry.url).manifest.layers[0].opacity == 1)
        #expect(!s.isModified)
    }

    @Test func recoveryDebouncesAndDefersPendingTransactions() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecoveryStore(directory: dir), s = try session()
        let coord = RecoveryCoordinator(session: s, title: "草稿", store: store, delay: .milliseconds(20))
        s.recovery = coord
        for i in 1...50 { edit(s, opacity: Double(i) / 100) }
        s.beginEdit("Move Layer"); s.document?.layers[0].transform.origin.x = 2
        await coord.flush(); #expect(try await store.entries().isEmpty)
        s.endEdit()
        for _ in 0..<40 {
            if try await store.entries().first?.record?.revision == s.history.currentRevision { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let entry = try #require(try await store.entries().first)
        #expect(entry.record?.revision == s.history.currentRevision)
        #expect(try await store.load(entry.url).manifest.layers[0].transform.origin.x == 2)
        #expect(s.isModified && s.recoveryError == nil)
        await coord.finishNormally()
    }

    @Test func recoveryCapacityAndInvalidSnapshotsNeverReplaceOldCopies() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecoveryStore(directory: dir, recordLimit: 1), s = try session()
        let snapshot = try #require(s.projectSnapshot()), r = try record(s)
        try await store.write(snapshot, record: r)
        let entry = try #require(try await store.entries().first)
        let metadata = try Data(contentsOf: entry.url.appendingPathComponent("recovery.json"))
        let manifest = try Data(contentsOf: entry.url.appendingPathComponent("manifest.json"))
        try await store.write(snapshot, record: r)
        #expect(try await store.entries().count == 1)
        let tiny = RecoveryStore(directory: dir, byteLimit: 1)
        do { try await tiny.write(snapshot, record: r); #expect(false) } catch { #expect(error is RecoveryError) }
        var bad = snapshot.manifest; bad.version = 99
        do { try await store.write(ProjectSnapshot(manifest: bad, images: snapshot.images), record: try record(s, version: 99)); #expect(false) }
        catch { print("Invalid recovery snapshot rejected: \(error)"); #expect(error is ProjectError) }
        #expect(try Data(contentsOf: entry.url.appendingPathComponent("recovery.json")) == metadata)
        #expect(try Data(contentsOf: entry.url.appendingPathComponent("manifest.json")) == manifest)
        let other = try session()
        do { try await store.write(try #require(other.projectSnapshot()), record: try record(other)); #expect(false) }
        catch { #expect(error is RecoveryError) }
        #expect(try await store.entries().count == 1)
    }

    @Test func recoverySupportsOldVersionsAndPreservesCorruptOrFutureCopies() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecoveryStore(directory: dir)
        for version in ProjectManifest.supported {
            let s = try session(); var m = try #require(s.projectSnapshot()).manifest
            m.version = version; m.layers[0].opacity = nil; m.layers[0].blendMode = nil
            let snapshot = ProjectSnapshot(manifest: m, images: try #require(s.projectSnapshot()).images)
            try await store.write(snapshot, record: try record(s, version: version))
            let url = dir.appendingPathComponent(m.documentID.uuidString + ".comp")
            #expect(try await store.load(url).manifest.version == version)
        }
        let entry = try #require(try await store.entries().first)
        let preserved = try await store.load(entry.url), oldRecord = try #require(entry.record)
        var future = oldRecord; future.version = 999
        try JSONEncoder().encode(future).write(to: entry.url.appendingPathComponent("recovery.json"), options: .atomic)
        do { _ = try await store.load(entry.url); #expect(false) } catch { #expect(error is RecoveryError) }
        #expect(try await store.entries().first { $0.url.path == entry.url.path }?.error != nil)
        let futureBytes = try Data(contentsOf: entry.url.appendingPathComponent("recovery.json"))
        do { try await store.write(preserved, record: oldRecord); #expect(false) } catch { #expect(error is RecoveryError) }
        #expect(try Data(contentsOf: entry.url.appendingPathComponent("recovery.json")) == futureBytes)
        try Data("broken".utf8).write(to: entry.url.appendingPathComponent("recovery.json"), options: .atomic)
        #expect(try await store.entries().count == ProjectManifest.supported.count)
        #expect(FileManager.default.fileExists(atPath: entry.url.path))
        do { try await store.write(preserved, record: oldRecord); #expect(false) } catch { #expect(error is RecoveryError) }
        #expect(try Data(contentsOf: entry.url.appendingPathComponent("recovery.json")) == Data("broken".utf8))
        try JSONEncoder().encode(oldRecord).write(to: entry.url.appendingPathComponent("recovery.json"), options: .atomic)
        let imageFile = try #require(preserved.manifest.layers[0].imageFile)
        let imageURL = entry.url.appendingPathComponent("images/" + imageFile)
        try Data("damaged pixels".utf8).write(to: imageURL, options: .atomic)
        do { try await store.write(preserved, record: oldRecord); #expect(false) } catch { #expect(error is RecoveryError) }
        #expect(try Data(contentsOf: imageURL) == Data("damaged pixels".utf8))
        try await store.remove(entry.url); #expect(try await store.entries().count == ProjectManifest.supported.count - 1)
    }

    @Test func recoveryRestoresIntoIndependentDirtyDraftAndKeepsSourceUntilDurable() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecoveryStore(directory: dir), original = try session()
        edit(original, opacity: 0.3)
        try await store.write(try #require(original.projectSnapshot()), record: try record(original))
        let source = try #require(try await store.entries().first)
        let workspace = ProjectWorkspace(recoveryStore: store)
        let draft = workspace.installRecovery(try await store.load(source.url), title: source.title)
        #expect(draft.session.document?.id != original.document?.id)
        #expect(draft.session.projectURL == nil && draft.session.isModified && draft.session.history.undoCount == 0)
        #expect(draft.session.document?.layers[0].opacity == 0.3)
        #expect(FileManager.default.fileExists(atPath: source.url.path))
        await draft.session.recovery?.flush()
        #expect(try await store.entries().count == 2 && draft.session.isModified)
        try await store.remove(source.url)
        #expect(try await store.entries().count == 1)
        await draft.session.recovery?.finishNormally()
    }

    @Test func recoverySerializesConcurrentCapacityChecks() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecoveryStore(directory: dir, recordLimit: 1), a = try session(), b = try session()
        let sa = try #require(a.projectSnapshot()), sb = try #require(b.projectSnapshot()), ra = try record(a), rb = try record(b)
        let one = Task { try await store.write(sa, record: ra) }, two = Task { try await store.write(sb, record: rb) }
        var succeeded = 0
        for task in [one, two] { do { try await task.value; succeeded += 1 } catch { #expect(error is RecoveryError) } }
        let count = try await store.entries().count
        #expect(succeeded == 1 && count == 1)
    }

    @Test func mosaicAveragesPremultipliedChannelsAndPartialBlocks() throws {
        var data: [UInt8] = [128,0,0,128, 0,0,0,0, 0,0,255,255, 0,128,0,128, 0,0,0,0, 255,255,0,255]
        data.withUnsafeMutableBufferPointer { mosaic_pixels($0.baseAddress, 3, 2, 12, 2) }
        #expect(Array(data[0..<4]) == [32,32,0,64])
        #expect(Array(data[4..<8]) == [32,32,0,64])
        #expect(Array(data[8..<12]) == [128,128,128,255])
        #expect(Array(data[20..<24]) == [128,128,128,255])
        let before = data
        data.withUnsafeMutableBufferPointer { mosaic_pixels($0.baseAddress, 3, 2, 12, 1) }
        #expect(data == before)
        var settings = FilterSettings(); settings.mosaicSize = .nan; #expect(settings.normalized.mosaicSize == 16)
        settings.mosaicSize = 999; #expect(settings.normalized.mosaicSize == 512)
        settings.mosaicSize = -1; #expect(settings.normalized.mosaicSize == 1)
    }

    @Test func mosaicSelectionScaleAndIdentityAreConsistent() throws {
        var settings = FilterSettings(); settings.mosaicSize = 2
        let source = try image(), rect = CGSize(width: 3, height: 2)
        let selection = try DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 1, height: 2), transform: nil), antialiased: false).clip(canvas: rect)
        let job = FilterJob(kind: .mosaic, image: source, settings: settings, scale: 1, selection: selection, mapping: .identity)
        let result = try bytes(PixelFilter.run(job)), original = try bytes(source)
        #expect(Array(result[4..<12]) == Array(original[4..<12]))
        #expect(Array(result[16..<24]) == Array(original[16..<24]))
        #expect(Array(result[0..<4]) != Array(original[0..<4]))
        let preview = FilterJob(kind: .mosaic, image: source, settings: settings, scale: 0.5, selection: nil, mapping: .identity)
        #expect(try PixelFilter.run(preview) === source)
        let invalid = FilterJob(kind: .mosaic, image: source, settings: settings, scale: .nan, selection: nil, mapping: .identity)
        do { _ = try PixelFilter.run(invalid); #expect(false) } catch { #expect(error is ExportError) }
    }

    @Test func mosaicUsesOneLocalizedUndoAndPreservesMaskEffectsAndTransform() async throws {
        let s = try session()
        s.document?.layers[0].mask = LayerMask.solid(revealing: true)
        s.document?.layers[0].transform.rotation = 30
        s.document?.layers[0].effects = LayerEffects(stroke: StrokeEffect())
        let before = s.document
        s.beginFilter(.mosaic); var settings = s.filterSettings; settings.mosaicSize = 2
        s.updateFilter(settings, preview: false); await s.commitFilter()
        let after = try #require(s.document)
        #expect(after.layers[0].mask == before?.layers[0].mask && after.layers[0].effects == before?.layers[0].effects)
        #expect(after.layers[0].transform == before?.layers[0].transform)
        #expect(s.history.undoCount == 1 && s.history.undoName == "Mosaic" && L10n.text("Mosaic") == "马赛克")
        s.undo(); #expect(s.document == before); s.redo(); #expect(s.document == after)
        s.beginFilter(.mosaic); s.cancelFilter(); #expect(s.document == after && s.history.undoCount == 1)
        s.beginFilter(.mosaic); settings.mosaicSize = 1; s.updateFilter(settings, preview: false); await s.commitFilter()
        #expect(s.document == after && s.history.undoCount == 1 && !s.isProjectBusy && s.activeEditOwner == nil)
    }

    @Test func filterResultsCannotCommitAcrossDocumentsOrAfterCancellation() async throws {
        for cancel in [false, true] {
            let s = try session(), gate = FilterResultGate(), result = try image()
            s.beginFilter(.mosaic)
            let task = Task { await s.commitFilter(render: { _ in await gate.hold() }) }
            await gate.ready()
            if cancel { task.cancel() }
            else {
                let layers = try #require(s.document).layers
                s.document = CanvasDocument(width: 8, height: 8, layers: layers)
            }
            let before = s.document
            await gate.finish(result); await task.value
            #expect(s.document == before && s.history.undoCount == 0 && !s.isProjectBusy && s.activeEditOwner == nil)
        }
    }

    private func fixture() throws -> EditorSession {
        let s = try session(); var base = try #require(s.activeLayer)
        base.name = "背景 中文"; base.transform.origin = CGPoint(x: -1, y: 0)
        var folder = ImageLayer(name: "文件夹 🧩", blankSize: CGSize(width: 8, height: 8)); folder.isGroup = true; folder.opacity = 0.75
        folder.mask = LayerMask.solid(revealing: true)
        var child = ImageLayer(asset: try #require(base.asset), origin: CGPoint(x: 1, y: 2)); child.name = "组内红绿蓝"
        child.parentID = folder.id; child.opacity = 0.5; child.blendMode = .multiply
        let maskImage = try PSDChannelCoder.maskImage(width: 3, height: 2, gray: [255,128,0,0,128,255])
        child.mask = LayerMask(asset: try LayerMask.asset(from: maskImage), isEnabled: false,
                               placement: LayerTransform(origin: CGPoint(x: 4, y: 1), size: CGSize(width: 3, height: 2)), isLinked: false)
        var rotated = ImageLayer(asset: try #require(base.asset), origin: CGPoint(x: 3, y: 4)); rotated.name = "旋转 90°"
        rotated.transform.rotation = 90; rotated.transform.sampling = .nearest
        var hidden = ImageLayer(asset: try #require(base.asset), origin: CGPoint(x: 5, y: 0)); hidden.name = "隐藏"; hidden.isVisible = false
        s.document = CanvasDocument(width: 8, height: 8, layers: [base, folder, child, rotated, hidden]); s.activeLayerID = child.id
        return s
    }

    @Test func layeredPSDRoundTripsGroupsUnicodeOffsetsBlendsAndMasks() async throws {
        let s = try fixture(), snapshot = try #require(s.projectSnapshot()), before = s.document
        let data = try await PSDExporter.shared.data(snapshot, mode: .layered), read = try PSDReader.read(data)
        #expect(read.width == 8 && read.height == 8 && read.layers.count == 5)
        #expect(read.layers.map(\.name) == ["背景 中文", "组内红绿蓝", "文件夹 🧩", "旋转 90°", "隐藏"])
        let group = try #require(read.layers.first { $0.name == "文件夹 🧩" })
        let child = try #require(read.layers.first { $0.name == "组内红绿蓝" })
        #expect(group.isGroup && child.parentID == group.id)
        #expect(abs(group.opacity - 191.0/255) < 0.0001 && abs(child.opacity - 128.0/255) < 0.0001)
        #expect(child.blendKey == "mul " && !read.layers[4].isVisible)
        #expect(read.layers[0].bounds.origin.x == -1 && child.bounds == CGRect(x: 1, y: 2, width: 3, height: 2))
        #expect(child.maskBounds == CGRect(x: 4, y: 1, width: 3, height: 2) && !child.maskEnabled)
        #expect(try bytes(try #require(child.image)) == bytes(try image()))
        #expect(read.layers[3].bounds == CGRect(x: 3, y: 3, width: 3, height: 4))
        #expect(s.document == before && !s.isModified && s.projectURL == nil && s.history.undoCount == 0)
        for blend in LayerBlendMode.allCases { #expect(LayerBlendMode.fromPSD(blend.psdKey) == blend) }
    }

    @Test func PSDRejectsUnsupportedLayerFeaturesAndOffersFaithfulFlattening() async throws {
        let s = try session(); s.document?.layers[0].effects = LayerEffects(stroke: StrokeEffect())
        let supported = try #require(s.projectSnapshot())
        #expect(!PSDWriter.requiresFlattening(supported))
        #expect(try await PSDExporter.shared.data(supported, mode: .layered).count > 0)
        s.document?.layers[0].effects = LayerEffects(bevel: BevelEffect())
        let snapshot = try #require(s.projectSnapshot())
        #expect(PSDWriter.requiresFlattening(snapshot))
        do { _ = try await PSDExporter.shared.data(snapshot, mode: .layered); #expect(false) }
        catch { #expect(error is PSDExportError) }
        let data = try await PSDExporter.shared.data(snapshot, mode: .flattened)
        let read = try PSDReader.read(data), composite = try await ImageExporter.shared.render(snapshot).image
        #expect(read.layers.count == 1 && read.layers[0].bounds == CGRect(x: 0, y: 0, width: 8, height: 8))
        #expect(try bytes(try #require(read.layers[0].image)) == bytes(composite))
        let blank = EditorSession(); blank.document = CanvasDocument(width: 8, height: 8, layers: [])
        #expect(try await PSDExporter.shared.data(try #require(blank.projectSnapshot()), mode: .layered).count > 0)
    }

    @Test func PSDRasterLimitsFailBeforeReplacingDestination() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("existing.psd"), old = Data("keep me".utf8)
        try old.write(to: url)
        let s = try session(); s.document?.layers[0].transform.size = CGSize(width: 12000, height: 12000)
        do { try await PSDExporter.shared.export(try #require(s.projectSnapshot()), mode: .layered, to: url); #expect(false) }
        catch { #expect(error is PSDExportError) }
        #expect(try Data(contentsOf: url) == old)
        s.document?.layers[0].transform.size = CGSize(width: 3, height: 2)
        try await PSDExporter.shared.export(try #require(s.projectSnapshot()), mode: .layered, to: url)
        #expect(PSDReader.matches(try Data(contentsOf: url)))
    }

    @Test func mosaicAndPSDRepeatedWorkStaysBounded() async throws {
        let c = try BrushRaster.context(width: 2048, height: 2048, mask: false)
        c.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 0.5)); c.fill(CGRect(x: 0, y: 0, width: 2048, height: 2048))
        let image = try #require(c.makeImage()); var settings = FilterSettings(); settings.mosaicSize = 32
        let start = Date()
        for _ in 0..<12 { try autoreleasepool {
            let result = try PixelFilter.run(FilterJob(kind: .mosaic, image: image, settings: settings, scale: 1, selection: nil, mapping: .identity))
            #expect(result.width == 2048 && result.height == 2048)
        } }
        print("Round3 mosaic 2048² × 12 seconds: \(Date().timeIntervalSince(start))")
        let s = try session(), layer = try #require(s.activeLayer)
        s.document?.layers = (0..<1000).map { i in ImageLayer(asset: layer.asset!, origin: CGPoint(x: i % 6, y: i % 6)) }
        let snapshot = try #require(s.projectSnapshot()), started = Date()
        let data = try await PSDExporter.shared.data(snapshot, mode: .layered)
        #expect(try PSDReader.read(data).layers.count == 1000)
        print("Round3 PSD 1000 layers bytes: \(data.count), seconds: \(Date().timeIntervalSince(started))")
    }

    @Test func largePSDRepeatedExportsPreserveTransparency() async throws {
        let width = 3840, height = 2160
        let c = try BrushRaster.context(width: width, height: height, mask: false)
        c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(c.makeImage())
        let layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: "4K透明度"), origin: .zero)
        let s = EditorSession(); s.document = CanvasDocument(width: width, height: height, layers: [layer])
        let snapshot = try #require(s.projectSnapshot()), started = Date()
        let expected = Array(try bytes(image).prefix(4))
        #expect((1..<255).contains(expected[3]) && expected.prefix(3).allSatisfy { $0 <= expected[3] })
        print("Round3 PSD source premultiplied RGBA: \(expected)")
        for _ in 0..<3 {
            let data = try await PSDExporter.shared.data(snapshot, mode: .layered)
            try autoreleasepool {
                let read = try PSDReader.read(data), result = try #require(read.layers.first?.image)
                let rgba = try bytes(result)
                #expect(result.width == width && result.height == height)
                #expect(Array(rgba.prefix(4)) == expected && Array(rgba.suffix(4)) == expected)
            }
        }
        print("Round3 PSD 3840×2160 × 3 seconds: \(Date().timeIntervalSince(started))")
    }

    @Test func emitIndependentPSDFixturesAndChineseOperationCatalog() async throws {
        let s = try fixture(), snapshot = try #require(s.projectSnapshot())
        for note in PSDWriter.conversionNotes(snapshot) { #expect(L10n.text(note) != note) }
        let textSession = try session(); textSession.beginText(at: CGPoint(x: 0, y: 0), newLayer: true)
        textSession.textDraft?.style.content = "中文文字转像素"; #expect(textSession.finishText())
        for note in PSDWriter.conversionNotes(try #require(textSession.projectSnapshot())) { #expect(L10n.text(note) != note) }
        #expect(L10n.text("Recovery Copies") == "恢复副本")
        guard let path = ProcessInfo.processInfo.environment["ROUND_THREE_OUTPUT"] else { return }
        let root = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await PSDExporter.shared.export(snapshot, mode: .layered, to: root.appendingPathComponent("分层验证.psd"))
        try await PSDExporter.shared.export(snapshot, mode: .flattened, to: root.appendingPathComponent("合成验证.psd"))
        try await ProjectStore.shared.save(snapshot, to: root.appendingPathComponent("第三批界面验证.comp"))
        let blendSession = try session(), original = try #require(blendSession.activeLayer?.asset)
        let blendLayers = LayerBlendMode.allCases.map { blend in
            var layer = ImageLayer(asset: original, origin: .zero)
            layer.name = blend.rawValue; layer.blendMode = blend; layer.isVisible = false
            return layer
        }
        blendSession.document = CanvasDocument(width: 8, height: 8, layers: blendLayers)
        try await PSDExporter.shared.export(try #require(blendSession.projectSnapshot()), mode: .layered,
                                           to: root.appendingPathComponent("混合模式验证.psd"))
        let merged = try await ImageExporter.shared.render(snapshot).image
        let expected: [String: Any] = ["width": 8, "height": 8, "merged": try bytes(merged), "sourcePixels": try bytes(try image()),
            "blends": LayerBlendMode.allCases.map { $0.rawValue.lowercased().replacingOccurrences(of: " (add)", with: "") },
            "mask": [255,128,0,0,128,255], "topLevelNames": ["背景 中文", "文件夹 🧩", "旋转 90°", "隐藏"]]
        try JSONSerialization.data(withJSONObject: expected, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("expected.json"))
    }
}
