import AppKit
import Testing
@testable import Compositor

private actor BucketGate {
    private var continuation: CheckedContinuation<SelectionClip?, Error>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var started = false
    func hold() async throws -> SelectionClip? {
        started = true
        observers.forEach { $0.resume() }
        observers = []
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func finish(_ result: SelectionClip?) { continuation?.resume(returning: result); continuation = nil }
}

@MainActor
struct RoundTwoTests {
    private func unit(_ name: String, x: CGFloat, y: CGFloat = 0, width: CGFloat = 10, height: CGFloat = 10) -> ImageLayer {
        var layer = ImageLayer(name: name, blankSize: CGSize(width: width, height: height))
        layer.transform.origin = CGPoint(x: x, y: y)
        return layer
    }
    private func arrangedSession(_ layers: [ImageLayer]) -> EditorSession {
        let s = EditorSession()
        s.document = CanvasDocument(width: 100, height: 100, layers: layers)
        s.activeLayerID = layers.first?.id
        s.selectedLayerIDs = Set(layers.map(\.id))
        return s
    }
    private func pixels() throws -> EditorSession {
        let c = try BrushRaster.context(width: 8, height: 8, mask: false)
        c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 4, height: 8))
        let image = try #require(c.makeImage())
        let layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: "Colors"), origin: .zero)
        let s = arrangedSession([layer])
        s.document = CanvasDocument(width: 8, height: 8, layers: [layer])
        s.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        s.bucketSettings.tolerance = 0
        return s
    }
    private func pixel(_ s: EditorSession, x: Int, y: Int = 2) throws -> [UInt8] {
        let d = try #require(s.document)
        let image = try #require(s.selectionSample(d, sampleAllLayers: true))
        let c = try BrushRaster.context(width: d.width, height: d.height, mask: false)
        BrushRaster.draw(image, in: CGRect(origin: .zero, size: d.size), mask: false, context: c)
        let data = try #require(c.data?.assumingMemoryBound(to: UInt8.self))
        return Array(UnsafeBufferPointer(start: data + y * c.bytesPerRow + x * 4, count: 4))
    }

    @Test func geometryMatchesAlignmentAndDistributionDefinitions() {
        let rects = [CGRect(x: 10, y: 5, width: 10, height: 10), CGRect(x: 30, y: 30, width: 20, height: 20),
                     CGRect(x: 90, y: 80, width: 30, height: 30)]
        let ref = CGRect(x: 0, y: 0, width: 200, height: 160)
        #expect(LayerArrange.deltas(rects, operation: .left, reference: ref).map(\.width) == [-10, -30, -90])
        #expect(LayerArrange.deltas(rects, operation: .right, reference: ref).map(\.width) == [180, 150, 80])
        #expect(LayerArrange.deltas(rects, operation: .horizontalCenter, reference: ref).map(\.width) == [85, 60, -5])
        #expect(LayerArrange.deltas(rects, operation: .top, reference: ref).map(\.height) == [-5, -30, -80])
        #expect(LayerArrange.deltas(rects, operation: .bottom, reference: ref).map(\.height) == [145, 110, 50])
        #expect(LayerArrange.deltas(rects, operation: .verticalCenter, reference: ref).map(\.height) == [70, 40, -15])
        #expect(LayerArrange.deltas(rects, operation: .horizontalCenters).map(\.width) == [0, 20, 0])
        #expect(LayerArrange.deltas(rects, operation: .verticalCenters).map(\.height) == [0, 12.5, 0])
        #expect(LayerArrange.deltas(rects, operation: .horizontalGaps).map(\.width) == [0, 15, 0])
        #expect(LayerArrange.deltas(rects, operation: .verticalGaps).map(\.height) == [0, 7.5, 0])
        #expect(LayerArrange.deltas(Array(rects.prefix(2)), operation: .horizontalGaps) == [.zero, .zero])
    }

    @Test func foldersCarryHiddenChildrenAndRespectMaskLinksInOneUndo() throws {
        var folder = unit("Folder", x: 0, width: 100, height: 100); folder.isGroup = true
        var child = unit("Child", x: 20); child.parentID = folder.id
        var hidden = unit("Hidden", x: 40); hidden.parentID = folder.id; hidden.isVisible = false
        let gray = try BrushRaster.context(width: 2, height: 2, mask: true)
        gray.setFillColor(gray: 0.5, alpha: 1); gray.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(gray.makeImage())
        child.mask = LayerMask(asset: try LayerMask.asset(from: image))
        hidden.mask = LayerMask(asset: try LayerMask.asset(from: image)); hidden.mask?.isLinked = false
        folder.mask = LayerMask(asset: try LayerMask.asset(from: image)); folder.mask?.isLinked = false
        let other = unit("Other", x: 60)
        let s = arrangedSession([folder, child, hidden, other])
        s.selectedLayerIDs = [folder.id, child.id, other.id]
        s.arrangeReference = .canvas
        let before = s.document
        #expect(s.arrangeTargets?.count == 2)
        #expect(s.arrangeLayers(.left) == .changed)
        let after = try #require(s.document)
        #expect(after.layers[1].origin.x == 0)
        #expect(after.layers[2].origin.x == 20)
        #expect(after.layers[3].origin.x == 0)
        #expect(after.layers[1].mask?.placement == nil)
        #expect(after.layers[2].mask?.placement == hidden.transform)
        #expect(after.layers[0].transform == folder.transform)
        #expect(s.history.undoCount == 1)
        #expect(L10n.text(s.history.undoName) != s.history.undoName)
        s.undo(); #expect(s.document == before)
        s.redo(); #expect(s.document == after)
    }

    @Test func referencesRotationAndKeyObjectDegeneraciesAreExplicit() throws {
        var a = unit("Rotated", x: 10, y: 20, width: 10, height: 20); a.transform.rotation = 90
        let b = unit("Key", x: 40)
        let s = arrangedSession([a, b])
        s.arrangeReference = .keyObject(b.id)
        #expect(s.arrangeLayers(.left) == .changed)
        #expect(abs(try #require(s.document?.layers[0].origin.x) - 45) < 0.000001)
        #expect(s.document?.layers[1].transform == b.transform)
        s.arrangeReference = .keyObject(UUID())
        let before = s.document
        #expect(s.arrangeLayers(.left) == .rejected(.reference))
        #expect(s.document == before)
        s.selectedLayerIDs = [a.id]
        s.arrangeReference = .keyObject(b.id)
        #expect(s.arrangeLayers(.left) == .rejected(.reference))
        s.arrangeReference = .canvas
        #expect(s.arrangeLayers(.left) == .changed)
        #expect(abs(try #require(s.document?.layers[0].origin.x) - 5) < 0.000001)
        #expect(s.arrangeLayers(.horizontalCenters) == .unchanged)

        var group = unit("Group", x: 0); group.isGroup = true
        var member = unit("Member", x: 20); member.parentID = group.id
        let grouped = arrangedSession([group, member, b])
        grouped.selectedLayerIDs = [group.id, member.id, b.id]
        grouped.arrangeReference = .keyObject(member.id)
        #expect(grouped.arrangeLayers(.left) == .rejected(.reference))
        grouped.selectedLayerIDs = [member.id, b.id]
        #expect(grouped.arrangeLayers(.left) == .changed)
        #expect(grouped.document?.layers[1].transform == member.transform)
    }

    @Test func invalidGeometryAndBusyEditsNeverPartiallyArrange() {
        var far = unit("Far", x: 1_000_000, width: 1_000, height: 1_000); far.transform.rotation = 45
        let s = arrangedSession([unit("Near", x: 0), far])
        let before = s.document
        #expect(s.arrangeLayers(.right) == .rejected(.geometry))
        #expect(s.document == before && s.history.undoCount == 0)
        s.isProjectBusy = true
        #expect(s.arrangeLayers(.left) == .rejected(.busy))
        s.isProjectBusy = false
        s.cropRect = CGRect(x: 0, y: 0, width: 2, height: 2)
        #expect(s.arrangeLayers(.left) == .rejected(.modal))
        #expect(s.document == before && s.history.undoCount == 0)
    }

    @Test func textKeyClippingAndDistributionReferenceStayConsistent() throws {
        let a = unit("First", x: 10), b = unit("Middle", x: 35), c = unit("Last", x: 90)
        let s = arrangedSession([a, b, c])
        s.beginText(at: CGPoint(x: 20, y: 30), newLayer: true)
        s.textDraft?.style.content = "关键对象"
        #expect(s.finishText())
        let text = try #require(s.activeLayer)
        s.selectedLayerIDs = [a.id, text.id]
        s.arrangeReference = .keyObject(text.id)
        #expect(s.arrangeLayers(.left) == .changed)
        #expect(s.document?.layers.first { $0.id == text.id }?.transform == text.transform)
        #expect(s.document?.layers.first { $0.id == text.id }?.liveText != nil)
        let middle = try #require(s.document?.layers.firstIndex { $0.id == b.id })
        s.document?.layers[middle].maskSourceID = a.id
        let clipped = s.document?.layers[middle]
        s.selectedLayerIDs = [a.id]; s.arrangeReference = .canvas
        #expect(s.arrangeLayers(.left) == .changed)
        #expect(s.document?.layers[middle] == clipped)
        s.selectedLayerIDs = [a.id, b.id, c.id]
        s.arrangeReference = .keyObject(UUID())
        #expect(s.canArrange(.horizontalCenters))
        #expect(s.arrangeLayers(.horizontalCenters) == .changed)
        #expect(s.document?.layers[middle].maskSourceID == a.id)
        #expect(s.document?.layers.first { $0.id == a.id }?.origin.x == 0)
        #expect(s.document?.layers.first { $0.id == c.id }?.origin.x == 90)
    }

    @Test func bucketIntersectsSelectionAndRoundTripsWithoutChangingIt() async throws {
        let s = try pixels()
        s.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 2, height: 8), transform: nil), antialiased: false)
        let before = s.document
        let selection = s.selection
        #expect(await s.paintBucket(at: CGPoint(x: 6, y: 2)) == .unchanged)
        #expect(s.document == before && s.history.undoCount == 0)
        #expect(await s.paintBucket(at: CGPoint(x: 1, y: 2)) == .changed)
        #expect(s.selection == selection)
        #expect(try pixel(s, x: 1) == [255, 0, 0, 255])
        #expect(try pixel(s, x: 3) == [255, 255, 255, 255])
        #expect(try pixel(s, x: 6) == [0, 0, 0, 255])
        #expect(s.history.undoName == "Paint Bucket" && s.history.undoCount == 1)
        let after = s.document
        s.undo(); #expect(s.document == before)
        s.redo(); #expect(s.document == after)
        #expect(!s.isProjectBusy && s.activeEditOwner == nil)
    }

    @Test func bucketSamplingAndContiguityUseTheSharedWandMatcher() async throws {
        for composite in [false, true] {
            let s = try pixels()
            s.addBlankLayer()
            s.bucketSettings.sampleAllLayers = composite
            #expect(await s.paintBucket(at: CGPoint(x: 1, y: 2)) == .changed)
            #expect(try pixel(s, x: 1) == [255, 0, 0, 255])
            #expect(try pixel(s, x: 6) == (composite ? [0, 0, 0, 255] : [255, 0, 0, 255]))
        }
        let c = try BrushRaster.context(width: 8, height: 8, mask: false)
        c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 2, height: 8))
        c.fill(CGRect(x: 6, y: 2, width: 1, height: 1))
        let image = try #require(c.makeImage())
        for contiguous in [false, true] {
            let s = try pixels()
            s.document?.layers[0].asset = ImportedImage(image: image, thumbnail: image, name: "Islands")
            s.bucketSettings.contiguous = contiguous
            #expect(await s.paintBucket(at: CGPoint(x: 1, y: 2)) == .changed)
            #expect(try pixel(s, x: 6) == (contiguous ? [255, 255, 255, 255] : [255, 0, 0, 255]))
        }
    }

    @Test func bucketMaskAndExistingSolidFillShareTheCommitPath() async throws {
        let s = try pixels()
        s.addLayerMask(revealing: true)
        s.isMaskSelected = true; s.maskPaintWhite = false
        let originalPixels = s.activeLayer?.asset?.image
        #expect(await s.paintBucket(at: CGPoint(x: 1, y: 2)) == .changed)
        #expect(s.activeLayer?.asset?.image === originalPixels)
        #expect(s.history.undoName == "Paint Bucket Mask")
        let mask = try #require(s.activeLayer?.mask?.asset.image)
        let c = try BrushRaster.context(width: mask.width, height: mask.height, mask: true)
        BrushRaster.draw(mask, in: CGRect(x: 0, y: 0, width: mask.width, height: mask.height), mask: true, context: c)
        #expect(try #require(c.data?.assumingMemoryBound(to: UInt8.self))[0] == 0)
        s.isMaskSelected = false
        await s.fillSelection(with: .foreground)
        #expect(s.history.undoName == "Fill")
        #expect(!s.isProjectBusy && s.activeEditOwner == nil)
    }

    @Test func oldBucketCallbackCannotWriteIntoAReplacementDocument() async throws {
        let s = try pixels()
        let gate = BucketGate()
        let sourceImage = try #require(s.activeLayer?.asset?.image)
        let clip = try #require(MagicWand.coverage(in: sourceImage, at: CGPoint(x: 1, y: 2), settings: s.bucketSettings))
        let work = Task { await s.paintBucket(at: CGPoint(x: 1, y: 2), match: { _ in try await gate.hold() }) }
        await gate.waitForStart()
        #expect(s.isProjectBusy)
        let replacement = CanvasDocument(width: 8, height: 8, layers: try #require(s.document).layers)
        s.document = replacement
        await gate.finish(clip)
        #expect(await work.value == .rejected(.stale))
        #expect(s.document == replacement && s.history.undoCount == 0)
        #expect(!s.isProjectBusy && s.activeEditOwner == nil)
    }

    @Test func ownerInstancesRevisionAndNestedTransactionsAreChecked() throws {
        let s = try pixels()
        let first = try #require(s.beginOwnedEdit())
        #expect(s.ownsEdit(first) && s.beginOwnedEdit() == nil)
        s.releaseEdit(first)
        let second = try #require(s.beginOwnedEdit())
        #expect(first != second)
        s.releaseEdit(first)
        #expect(s.isProjectBusy && s.ownsEdit(second))
        s.beginEdit("Rename Layer"); s.document?.layers[0].name = "Changed"; s.endEdit()
        #expect(!s.ownsEdit(second))
        s.releaseEdit(second)
        s.beginEdit("Fill")
        #expect(s.beginOwnedEdit() == nil)
        s.endEdit()
        #expect(!s.isProjectBusy)
    }

    @Test func failedAndRejectedBucketJobsLeaveNoSelectionOrHistoryChanges() async throws {
        let s = try pixels()
        let before = s.document
        let revision = s.history.currentRevision
        let failed = await s.paintBucket(at: CGPoint(x: 1, y: 2), match: { _ in throw ExportError.render })
        if case .failed = failed {} else { #expect(false) }
        #expect(s.document == before && s.history.currentRevision == revision)
        #expect(!s.isProjectBusy && s.activeEditOwner == nil)
        s.isProjectBusy = true
        #expect(await s.paintBucket(at: CGPoint(x: 1, y: 2)) == .rejected(.busy))
        s.isProjectBusy = false
        #expect(await s.paintBucket(at: CGPoint(x: CGFloat.nan, y: 0)) == .unchanged)
        #expect(s.document == before && s.history.undoCount == 0)
    }

    @Test func bucketTargetAndSurfaceBudgetsRejectWithoutMutation() async throws {
        let s = try pixels()
        s.document?.layers[0].isVisible = false
        #expect(await s.paintBucket(at: CGPoint(x: 1, y: 2)) == .rejected(.target))
        s.document?.layers[0].isVisible = true
        s.selectedLayerIDs.insert(UUID())
        #expect(await s.paintBucket(at: CGPoint(x: 1, y: 2)) == .rejected(.target))
        #expect(s.history.undoCount == 0 && !s.isProjectBusy)
        let layer = unit("Oversized", x: 0, width: 30_000, height: 30_000)
        let large = arrangedSession([layer])
        large.document = CanvasDocument(width: 30_000, height: 30_000, layers: [layer])
        let before = large.document
        if case .failed = await large.paintBucket(at: CGPoint(x: 1, y: 2)) {} else { #expect(false) }
        #expect(large.document == before && large.history.undoCount == 0)
        #expect(!large.isProjectBusy && large.activeEditOwner == nil)
    }

    @Test func arrangedAndFilledProjectReopensWithIdenticalPixelsAndPlacement() async throws {
        let s = try pixels()
        var other = unit("Other", x: 3, y: 4, width: 2, height: 2)
        other.maskSourceID = s.activeLayerID
        s.document?.layers.append(other)
        s.selectedLayerIDs = Set(try #require(s.document).layers.map(\.id))
        s.arrangeReference = .canvas
        #expect(s.arrangeLayers(.left) == .changed)
        s.selectedLayerIDs = [try #require(s.activeLayerID)]
        #expect(await s.paintBucket(at: CGPoint(x: 1, y: 2)) == .changed)
        let original = try #require(s.document)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("RoundTwo.comp")
        let snapshot = try #require(s.projectSnapshot())
        #expect(snapshot.manifest.version == 11)
        try await ProjectStore.shared.save(snapshot, to: url)
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: url), from: url)
        let restored = try #require(reopened.document)
        #expect(restored.layers.map(\.id) == original.layers.map(\.id))
        #expect(restored.layers.map(\.transform) == original.layers.map(\.transform))
        #expect(restored.layers.map(\.maskSourceID) == original.layers.map(\.maskSourceID))
        #expect(restored.layers.map(\.name) == original.layers.map(\.name))
        #expect(try pixel(reopened, x: 1) == [255, 0, 0, 255])
        #expect(try pixel(reopened, x: 6) == [0, 0, 0, 255])
        #expect(!reopened.isModified)
    }

    @Test func intersectedMasksKeepFractionalCoverage() throws {
        let c = try BrushRaster.context(width: 2, height: 2, mask: true)
        c.setFillColor(gray: 0.5, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(c.makeImage())
        let clip = SelectionClip(rect: CGRect(x: 0, y: 0, width: 2, height: 2), coverage: image)
        let result = try #require(clip.intersecting(clip).coverage)
        let check = try BrushRaster.context(width: 2, height: 2, mask: true)
        BrushRaster.draw(result, in: clip.rect, mask: true, context: check)
        let value = try #require(check.data?.assumingMemoryBound(to: UInt8.self))[0]
        #expect((63...65).contains(value))
    }

    @Test func repeatedDistributionKeepsEndpointsAndCentersStable() {
        for iteration in 0..<500 {
            let rects = (0..<20).map { index in
                CGRect(x: CGFloat(index * index + iteration % 7), y: 0, width: CGFloat(5 + index % 3), height: 10)
            }
            let deltas = LayerArrange.deltas(rects, operation: .horizontalCenters)
            #expect(deltas.first == .zero && deltas.last == .zero)
            let spacing = (rects.last!.midX - rects.first!.midX) / 19
            for index in rects.indices {
                #expect(abs(rects[index].midX + deltas[index].width - rects[0].midX - CGFloat(index) * spacing) < 0.000001)
            }
        }
    }
}
