import AppKit
import ImageIO
import UniformTypeIdentifiers
#if !LONG_TASK_CLT_CHECKS
import Testing
@testable import Compositor
#endif

@MainActor struct LongTaskRegressionChecks {
    struct Result { var checks = 0; var failures: [String] = []; var measurements: [String] = [] }
    static func image(_ width: Int, _ height: Int, color: (UInt8, UInt8, UInt8, UInt8)) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let p = context.data!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(width * height) { p[i*4] = color.0; p[i*4+1] = color.1; p[i*4+2] = color.2; p[i*4+3] = color.3 }
        return context.makeImage()!
    }
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [UInt8] {
        let context = try BrushRaster.copy(image), p = context.data!.assumingMemoryBound(to: UInt8.self)
        let at = y * context.bytesPerRow + x * 4
        return Array(UnsafeBufferPointer(start: p + at, count: 4))
    }
    static func block(_ image: CGImage, x: Int = 0, y: Int = 0, duration: Int, disposal: Int) throws -> Data {
        let bytes = NSMutableData()
        let encoder = CGImageDestinationCreateWithData(bytes, UTType.gif.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw ExportError.encode }
        var data = try GIFCodec.encodedFrame(bytes as Data, width: image.width, height: image.height, duration: duration)
        data[3] = UInt8(disposal << 2) | (data[3] & 1)
        data[9] = UInt8(x & 255); data[10] = UInt8(x >> 8); data[11] = UInt8(y & 255); data[12] = UInt8(y >> 8)
        return data
    }
    static func fixture(_ width: Int = 4, _ height: Int = 4, frames: Int = 4) throws -> (EditorSession, ProjectSnapshot) {
        let session = EditorSession()
        let assetImage = try image(width, height, color: (128, 32, 16, 128))
        let asset = ImportedImage(image: assetImage, thumbnail: try PixelAdjust.thumbnail(of: assetImage), name: "Synthetic")
        var layers: [ImageLayer] = [], track: [AnimationFrame] = []
        for index in 0..<frames {
            var group = ImageLayer(name: "Synthetic frame", blankSize: CGSize(width: width, height: height)); group.isGroup = true
            var layer = ImageLayer(asset: asset, origin: .zero); layer.parentID = group.id
            layer.opacity = index % 2 == 0 ? 1 : 0.4
            layers += [group, layer]; track.append(AnimationFrame(groupID: group.id, durationMS: (index % 8 + 1) * 20))
        }
        session.document = CanvasDocument(width: width, height: height, layers: layers)
        session.document!.animation = AnimationTrack(frames: track, loopCount: 3)
        session.document!.displayedAnimationFrameID = track[min(1, frames-1)].id
        session.activeLayerID = layers[min(3, layers.count-1)].id
        session.history.reset()
        return (session, session.projectSnapshot()!)
    }
    static func record(_ snapshot: ProjectSnapshot, revision: UUID = UUID()) -> RecoveryRecord {
        RecoveryRecord(documentID: snapshot.manifest.documentID, revision: revision, projectVersion: snapshot.manifest.version,
            title: "Synthetic", originalPath: nil, date: Date())
    }
    static func run(large: Bool = false) async throws -> Result {
        var result = Result()
        func check(_ name: String, _ value: Bool) {
            result.checks += 1; if !value { result.failures.append(name); print("FAIL: \(name)") }; fflush(stdout)
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("LongTaskRegression-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var disposalData = GIFCodec.header(width: 4, height: 4, loops: 3)
        disposalData.append(try block(image(4, 4, color: (255, 0, 0, 255)), duration: 20, disposal: 1))
        disposalData.append(try block(image(2, 2, color: (0, 0, 255, 255)), x: 1, y: 1, duration: 40, disposal: 3))
        disposalData.append(try block(image(1, 1, color: (0, 255, 0, 255)), duration: 60, disposal: 2))
        disposalData.append(try block(image(1, 1, color: (255, 255, 0, 255)), x: 3, y: 3, duration: 80, disposal: 1))
        disposalData.append(0x3b)
        let decoded = try GIFCodec.decode(disposalData, name: "Synthetic", remainingPixels: 64_000_000)
        check("disposal fixture frame count / delays / loops", decoded.frames.count == 4 && decoded.durations == [20,40,60,80] && decoded.loopCount == 3)
        check("offset patch drawn at its own position", try pixel(decoded.frames[1].image, 1, 1) == [0,0,255,255])
        check("disposal 3 restores earlier pixels", try pixel(decoded.frames[2].image, 1, 1) == [255,0,0,255])
        check("disposal 2 clears only previous patch", try pixel(decoded.frames[3].image, 0, 0)[3] == 0 && pixel(decoded.frames[3].image, 3, 3) == [255,255,0,255])
        let imported = EditorSession(); imported.beginEdit("Import Images"); try imported.insertGIF(decoded, centeredAt: nil); imported.endEdit()
        let disposalSnapshot = imported.projectSnapshot()!
        let full = try await ImageExporter.shared.animationGIF(disposalSnapshot, fallback: ImageExporter.shared.render(disposalSnapshot),
            width: 4, height: 4, background: CGColor(gray: 1, alpha: 1), keepTransparency: true)
        let roundtrip = try GIFCodec.decode(full.data, name: "Synthetic", remainingPixels: 64_000_000)
        check("GIF roundtrip preserves timing and loop", roundtrip.durations == decoded.durations && roundtrip.loopCount == decoded.loopCount)
        for index in 0..<4 { for y in 0..<4 { for x in 0..<4 {
            check("roundtrip pixel \(index),\(x),\(y)", try pixel(roundtrip.frames[index].image, x, y) == pixel(decoded.frames[index].image, x, y))
        } } }
        let (_, snapshot) = try fixture()
        let fallback = try await ImageExporter.shared.render(snapshot)
        let workspace = GIFExportWorkspace(snapshot: snapshot, fallback: fallback)
        let options = GIFExportOptions(width: 4, height: 4)
        let preview = try await workspace.preview(options)
        check("preview does not encode animation", workspace.encodingRuns == 0 && workspace.encoded == nil)
        check("preview identifies current frame", workspace.prepared?.frameID == snapshot.displayedAnimationFrameID)
        check("preview keeps binary transparency threshold", try pixel(preview, 0, 0)[3] == 0)
        _ = try await workspace.preview(options)
        let encoded = try await workspace.encode(options)
        let again = try await workspace.encode(options)
        check("calculate and export reuse exact full bytes", workspace.encodingRuns == 1 && encoded.data == again.data)
        check("completion count describes all frames", workspace.completedFrames == 4 && !workspace.isEncoding)
        let frames = try GIFCodec.decode(encoded.data, name: "Synthetic", remainingPixels: 64_000_000)
        check("current-frame preview matches corresponding final palette", try pixel(preview, 0, 0) == pixel(frames.frames[1].image, 0, 0))
        let opaque = GIFExportOptions(width: 4, height: 4, red: 0, green: 0, blue: 1, keepTransparency: false)
        let opaquePreview = try await workspace.preview(opaque)
        check("settings invalidate encoded bytes", workspace.encoded == nil && workspace.encodedOptions == nil)
        check("matte preview is opaque", try pixel(opaquePreview, 0, 0)[3] == 255)
        let opaqueEncoded = try await workspace.encode(opaque)
        check("new settings cause one new encoding", workspace.encodingRuns == 2 && opaqueEncoded.data != encoded.data)
        let oldPreview = Task { try await workspace.preview(options) }; oldPreview.cancel()
        do { _ = try await oldPreview.value; check("canceled old preview preserves newer encoding", false) }
        catch is CancellationError { check("canceled old preview preserves newer encoding", workspace.encodedOptions == opaque && workspace.encoded?.data == opaqueEncoded.data) }
        var implicitSelection = snapshot; implicitSelection.displayedAnimationFrameID = nil
        let implicit = GIFExportWorkspace(snapshot: implicitSelection, fallback: try await ImageExporter.shared.render(implicitSelection))
        _ = try await implicit.preview(options)
        check("active layer selects frame when display ID is absent", implicit.prepared?.frameID == snapshot.displayedAnimationFrameID)

        let (_, many) = try fixture(large ? 800 : 256, large ? 600 : 192, frames: 100)
        let manyFallback = try await ImageExporter.shared.render(many)
        let manyOptions = GIFExportOptions(width: many.manifest.width, height: many.manifest.height)
        let long = GIFExportWorkspace(snapshot: many, fallback: manyFallback)
        let previewStart = DispatchTime.now().uptimeNanoseconds
        _ = try await long.preview(manyOptions)
        let previewMS = Double(DispatchTime.now().uptimeNanoseconds - previewStart) / 1_000_000
        let canceledEncoding = Task { try await long.encode(manyOptions) }
        for _ in 0..<100 { if long.isEncoding { break }; await Task.yield() }
        long.cancel()
        do { _ = try await canceledEncoding.value; check("full encoding cancels without publishing", false) }
        catch is CancellationError { check("full encoding cancels without publishing", long.encoded == nil && !long.isEncoding) }
        let encodeStart = DispatchTime.now().uptimeNanoseconds
        let manyEncoded = try await long.encode(manyOptions)
        let encodeMS = Double(DispatchTime.now().uptimeNanoseconds - encodeStart) / 1_000_000
        check("100-frame GIF complete", CGImageSourceGetCount(CGImageSourceCreateWithData(manyEncoded.data as CFData, nil)!) == 100)
        result.measurements.append("100 frames \(manyOptions.width)x\(manyOptions.height): current-frame preview \(String(format: "%.2f", previewMS)) ms; complete encode \(String(format: "%.2f", encodeMS)) ms; \(manyEncoded.data.count) bytes")
        let gifURL = temporary.appendingPathComponent("synthetic.gif"); try manyEncoded.data.write(to: gifURL)
        let importSession = EditorSession()
        let importTask = Task { await importSession.importImages([gifURL]) }
        for _ in 0..<100 { if importSession.isImporting { break }; await Task.yield() }
        importSession.cancelImport(); await importTask.value
        check("canceled GIF import does not partially insert frames", importSession.document == nil && importSession.history.undoCount == 0 && !importSession.isImporting && importSession.importError == nil)
        let staleImport = EditorSession()
        let staleTask = Task { await staleImport.importImages([gifURL]) }
        for _ in 0..<100 { if staleImport.isImporting { break }; await Task.yield() }
        staleImport.installProject(snapshot, from: nil)
        await staleTask.value
        check("old GIF decode cannot commit to replacement document", staleImport.document?.id == snapshot.manifest.documentID && staleImport.history.undoCount == 0)
        let cancelDecode = Task.detached { try GIFCodec.decode(manyEncoded.data, name: "Synthetic", remainingPixels: 64_000_000) }
        cancelDecode.cancel()
        do { _ = try await cancelDecode.value; check("decoder checks cancellation", false) }
        catch is CancellationError { check("decoder checks cancellation", true) }

        let (recoverySession, _) = try fixture(64, 64, frames: 1)
        recoverySession.document!.animation = nil
        recoverySession.document!.layers[0].isGroup = false
        recoverySession.document!.layers[1].parentID = nil
        recoverySession.document!.layers.removeFirst()
        recoverySession.activeLayerID = recoverySession.document!.layers[0].id
        let saved = recoverySession.projectSnapshot()!
        let store = RecoveryStore(directory: temporary.appendingPathComponent("Recovery"), byteLimit: 2 * 1024 * 1024)
        let recoveryURL = store.directory.appendingPathComponent(saved.manifest.documentID.uuidString + ".comp")
        try await store.write(saved, record: record(saved))
        let firstStats = await store.lastWriteStatistics
        try await store.write(saved, record: record(saved))
        let reused = await store.lastWriteStatistics
        check("unchanged recovery encodes and hashes zero image files", reused.encodedImages == 0 && reused.hashedFiles == 0 && reused.checkedFiles >= 2)
        check("unchanged recovery only reads small metadata", reused.readBytes > 0 && reused.readBytes < 65_536 && reused.writtenBytes < firstStats.writtenBytes)
        let targetImage = recoveryURL.appendingPathComponent("images/" + saved.manifest.layers[0].imageFile!)
        let original = try Data(contentsOf: targetImage)
        let oldDate = (try FileManager.default.attributesOfItem(atPath: targetImage.path))[.modificationDate]!
        var damaged = original; damaged[damaged.count / 2] ^= 0xff
        try damaged.write(to: targetImage)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: targetImage.path)
        do { try await store.write(saved, record: record(saved)); check("same-size tamper with restored mtime is rejected", false) }
        catch RecoveryError.invalid { check("same-size tamper with restored mtime is rejected", try Data(contentsOf: targetImage) == damaged) }
        try original.write(to: targetImage)
        try await store.write(saved, record: record(saved))
        let repairedStats = await store.lastWriteStatistics
        check("externally repaired resource is rehashed once", repairedStats.hashedFiles == 1 && repairedStats.encodedImages == 0)
        let another = EditorSession(); another.createDocument(width: 32, height: 32); another.addBlankLayer()
        let other = another.projectSnapshot()!
        try await store.write(other, record: record(other))
        try await store.write(saved, record: record(saved))
        check("known capacity inventory avoids directory rescans", await store.lastWriteStatistics.scannedPackages == 0)
        let otherURL = store.directory.appendingPathComponent(other.manifest.documentID.uuidString + ".comp")
        let extra = otherURL.appendingPathComponent("external-growth.bin")
        try Data(repeating: 0, count: 3 * 1024 * 1024).write(to: extra)
        do { try await store.write(saved, record: record(saved)); check("external extra files count toward capacity", false) }
        catch RecoveryError.capacity { check("external extra files count toward capacity", true) }
        let shrinking = try FileHandle(forWritingTo: extra); try shrinking.truncate(atOffset: 1); try shrinking.close()
        try await store.write(saved, record: record(saved))
        check("known-file size changes update quota without rescan", await store.lastWriteStatistics.scannedPackages == 0)
        try FileManager.default.removeItem(at: extra)
        try await store.write(saved, record: record(saved))
        let nested = otherURL.appendingPathComponent("images/external-growth.bin")
        try Data(repeating: 0, count: 3 * 1024 * 1024).write(to: nested)
        do { try await store.write(saved, record: record(saved)); check("additions to empty resource directories count toward quota", false) }
        catch RecoveryError.capacity { check("additions to empty resource directories count toward quota", true) }
        try FileManager.default.removeItem(at: nested)
        try await store.write(saved, record: record(saved))
        let metadataBefore = try Data(contentsOf: recoveryURL.appendingPathComponent("recovery.json"))
        let canceledWrite = Task { try await store.write(saved, record: record(saved)) }; canceledWrite.cancel()
        do { try await canceledWrite.value; check("canceled write keeps complete old checkpoint", false) }
        catch is CancellationError { check("canceled write keeps complete old checkpoint", try Data(contentsOf: recoveryURL.appendingPathComponent("recovery.json")) == metadataBefore) }
        let limited = RecoveryStore(directory: store.directory, byteLimit: 1)
        do { try await limited.write(saved, record: record(saved)); check("capacity failure keeps old checkpoint", false) }
        catch RecoveryError.capacity { check("capacity failure keeps old checkpoint", try await store.load(recoveryURL).manifest.documentID == saved.manifest.documentID) }

        let beforeFailure = try Data(contentsOf: recoveryURL.appendingPathComponent("recovery.json"))
        let diskFullWriter = RecoveryResources(beforeCommit: { throw POSIXError(.ENOSPC) })
        do {
            _ = try await diskFullWriter.write(saved, to: recoveryURL, metadata: JSONEncoder().encode(record(saved)), maximumBytes: 2 * 1024 * 1024)
            check("injected disk-full commit keeps old package", false)
        } catch let error as POSIXError where error.code == .ENOSPC {
            check("injected disk-full commit keeps old package", try Data(contentsOf: recoveryURL.appendingPathComponent("recovery.json")) == beforeFailure && Data(contentsOf: targetImage) == original)
        }
        let remnants = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".recovery-stage") }
        check("failed commit cleans private staging directory", remnants.isEmpty)
        let outside = temporary.appendingPathComponent("outside.png"); try original.write(to: outside)
        try FileManager.default.removeItem(at: targetImage)
        try FileManager.default.createSymbolicLink(at: targetImage, withDestinationURL: outside)
        do { try await store.write(saved, record: record(saved)); check("symlink resource is rejected", false) }
        catch RecoveryError.invalid { check("symlink resource is rejected", try Data(contentsOf: outside) == original) }
        try FileManager.default.removeItem(at: targetImage); try original.write(to: targetImage)
        try await store.write(saved, record: record(saved))

        let coordinator = RecoveryCoordinator(session: recoverySession, title: "Synthetic", store: store, delay: .seconds(60))
        recoverySession.recovery = coordinator
        recoverySession.beginEdit("Edit"); recoverySession.document!.layers[0].name = "Committed"; recoverySession.endEdit()
        let revision = recoverySession.history.currentRevision
        await coordinator.flush()
        check("protection reports only successfully written revision", recoverySession.recoveryProtection?.revision == revision && recoverySession.recoveryWritingDocumentID == nil && recoverySession.recoveryError == nil)
        check("recovery does not mark project saved", recoverySession.isModified)
        recoverySession.beginEdit("Edit"); recoverySession.document!.layers[0].name = "Uncommitted"
        await coordinator.flush()
        check("uncommitted gesture is excluded from recovery", try await store.load(recoveryURL).manifest.layers[0].name == "Committed")
        recoverySession.document!.layers[0].name = "Committed"; recoverySession.endEdit()
        recoverySession.beginEdit("Edit"); recoverySession.document!.layers[0].name = "Newer"; recoverySession.endEdit()
        check("new edits do not advance protection before write", recoverySession.recoveryProtection?.revision == revision && recoverySession.history.currentRevision != revision)
        await coordinator.flush()
        check("completed newer revision updates protection", recoverySession.recoveryProtection?.revision == recoverySession.history.currentRevision)
        let protected = recoverySession.recoveryProtection
        try damaged.write(to: targetImage)
        recoverySession.beginEdit("Edit"); recoverySession.document!.layers[0].name = "Waiting after failure"; recoverySession.endEdit()
        await coordinator.flush()
        check("failed checkpoint retains previous protection revision", recoverySession.recoveryProtection == protected && recoverySession.recoveryError != nil && recoverySession.recoveryWritingDocumentID == nil)
        try original.write(to: targetImage); await coordinator.flush()
        check("retry protects latest revision and clears error", recoverySession.recoveryProtection?.revision == recoverySession.history.currentRevision && recoverySession.recoveryError == nil)
        result.measurements.append("Recovery warm checkpoint: \(reused.encodedImages) encoded images, \(reused.hashedFiles) rehashed files, \(reused.readBytes) logical read bytes, \(reused.writtenBytes) written bytes, \(String(format: "%.2f", reused.elapsedMilliseconds)) ms")
        return result
    }
}
#if !LONG_TASK_CLT_CHECKS
@MainActor struct LongTaskRegressionTests {
    @Test func gifJobsAndRecoveryIntegrity() async throws {
        let result = try await LongTaskRegressionChecks.run()
        #expect(result.failures.isEmpty, "\(result.failures)")
    }
}
#endif
