import AppKit
import Darwin
import Testing
@testable import Compositor

private actor PressureGate {
    private var continuation: CheckedContinuation<SelectionClip?, Error>?
    private var started = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    func hold() async throws -> SelectionClip? {
        started = true
        observers.forEach { $0.resume() }; observers = []
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitForStart() async {
        if !started { await withCheckedContinuation { observers.append($0) } }
    }
    func finish(_ clip: SelectionClip?) { continuation?.resume(returning: clip); continuation = nil }
}

@MainActor
struct RoundTwoStressTests {
    private var benchmarkOnly: Bool { ProcessInfo.processInfo.environment["STRESS_PHASE"] == "benchmark" }
    private func layer(_ name: String, x: CGFloat = 0, y: CGFloat = 0, size: CGSize = CGSize(width: 10, height: 10)) -> ImageLayer {
        var layer = ImageLayer(name: name, blankSize: size)
        layer.transform.origin = CGPoint(x: x, y: y)
        return layer
    }
    private func session(_ layers: [ImageLayer], width: Int = 12_000, height: Int = 8_000) -> EditorSession {
        let s = EditorSession()
        s.document = CanvasDocument(width: width, height: height, layers: layers)
        s.activeLayerID = layers.first?.id
        s.selectedLayerIDs = Set(layers.map(\.id))
        return s
    }
    private func raster(width: Int = 64, height: Int = 64) throws -> EditorSession {
        let image = try autoreleasepool {
            let c = try BrushRaster.context(width: width, height: height, mask: false)
            c.setFillColor(gray: 0, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: width, height: height))
            c.setFillColor(gray: 1, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            return try #require(c.makeImage())
        }
        let layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: "Pressure"), origin: .zero)
        let s = session([layer], width: width, height: height)
        s.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        s.bucketSettings.tolerance = 0
        return s
    }
    private func rgba(_ s: EditorSession, x: Int, y: Int) throws -> [UInt8] {
        let image = try #require(s.activeLayer?.asset?.image)
        return try autoreleasepool {
            let c = try BrushRaster.context(width: image.width, height: image.height, mask: false)
            BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: c)
            let data = try #require(c.data?.assumingMemoryBound(to: UInt8.self))
            return Array(UnsafeBufferPointer(start: data + y * c.bytesPerRow + x * 4, count: 4))
        }
    }
    private func metric(_ name: String, since start: UInt64) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        let record: [String: Any] = ["name": name, "seconds": seconds, "peak_rss_bytes": usage.ru_maxrss]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print("METRIC " + text) }
    }

    @Test func flatAndGroupedLayerScaleBenchmarks() throws {
        for count in [100, 1_000, 5_000, 10_000] {
            let layers = (0..<count).map { i in layer("L\(i)", x: CGFloat(10 + i % 4_000), y: CGFloat(i % 80)) }
            let s = session(layers)
            s.arrangeReference = .canvas
            var start = DispatchTime.now().uptimeNanoseconds
            for operation in ArrangeOperation.allCases { #expect(s.canArrange(operation)) }
            metric("flat-\(count)-ten-menu-permissions", since: start)
            let before = s.document
            start = DispatchTime.now().uptimeNanoseconds
            #expect(s.arrangeLayers(.left) == .changed)
            metric("flat-\(count)-align-left", since: start)
            #expect(s.document?.layers.allSatisfy { $0.origin.x == 0 } == true)
            s.undo(); #expect(s.document == before)
        }
        var layers: [ImageLayer] = []
        for index in 0..<100 {
            var group = layer("G\(index)"); group.isGroup = true
            layers.append(group)
            for child in 0..<49 {
                var member = layer("C\(index)-\(child)", x: CGFloat(20 + index), y: CGFloat(child))
                member.parentID = group.id; member.isVisible = child % 7 != 0
                layers.append(member)
            }
        }
        let s = session(layers)
        s.arrangeReference = .canvas
        let start = DispatchTime.now().uptimeNanoseconds
        #expect(s.arrangeTargets?.count == 100)
        #expect(s.arrangeLayers(.left) == .changed)
        metric("grouped-5000-align-left", since: start)
        for layer in try #require(s.document).layers where !layer.isGroup { #expect(layer.origin.x == 0) }
    }

    @Test func sustainedArrangeUndoRedoAndFailurePreserveHistory() throws {
        if benchmarkOnly { return }
        let layers = (0..<96).map { layer("L\($0)", x: CGFloat(1 + $0 * 7), y: CGFloat($0 % 8)) }
        let s = session(layers)
        s.arrangeReference = .canvas
        let ids = Set(layers.map(\.id))
        var states = [try #require(s.document)]
        let start = DispatchTime.now().uptimeNanoseconds
        for iteration in 0..<1_200 {
            s.selectedLayerIDs = ids
            #expect(s.arrangeLayers(iteration % 2 == 0 ? .left : .right) == .changed)
            states.append(try #require(s.document))
            if states.count > s.history.entryLimit + 1 { states.removeFirst() }
            #expect(s.history.undoCount <= s.history.entryLimit && !s.history.hasPendingEdit)
            #expect(L10n.text(s.history.undoName) != s.history.undoName)
        }
        for state in states.dropLast().reversed() { s.undo(); #expect(s.document == state) }
        #expect(!s.canUndo && s.canRedo)
        let revision = s.history.currentRevision
        let beforeFailure = s.document
        s.selectedLayerIDs = [UUID()]
        #expect(s.arrangeLayers(.left) == .rejected(.arrangeTarget))
        #expect(s.history.currentRevision == revision && s.document == beforeFailure && s.canRedo)
        for state in states.dropFirst() { s.redo(); #expect(s.document == state) }
        #expect(!s.canRedo && s.isModified)
        metric("arrange-1200-edits-and-100-undo-redo", since: start)
    }

    @Test func randomizedGeometryChecksAlignmentAndEqualGaps() {
        if benchmarkOnly { return }
        var seed: UInt64 = 0x20261001
        func random(_ max: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(max))
        }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<500 {
            let rects = (0..<(3 + random(98))).map { _ in
                CGRect(x: random(2_000) - 1_000, y: random(2_000) - 1_000, width: 1 + random(100), height: 1 + random(100))
            }
            let reference = CGRect(x: -123, y: -456, width: 1_345, height: 2_345)
            for operation in ArrangeOperation.allCases {
                let deltas = LayerArrange.deltas(rects, operation: operation, reference: reference)
                let moved = zip(rects, deltas).map { $0.offsetBy(dx: $1.width, dy: $1.height) }
                let horizontal = operation.horizontal
                func low(_ r: CGRect) -> CGFloat { horizontal ? r.minX : r.minY }
                func span(_ r: CGRect) -> CGFloat { horizontal ? r.width : r.height }
                if operation.isAlignment {
                    let factor: CGFloat = [.left, .top].contains(operation) ? 0 : [.right, .bottom].contains(operation) ? 1 : 0.5
                    let target = low(reference) + span(reference) * factor
                    for rect in moved { #expect(abs(low(rect) + span(rect) * factor - target) < 0.000001) }
                } else {
                    let order = rects.indices.sorted {
                        let a = low(rects[$0]) + (operation.gaps ? 0 : span(rects[$0]) / 2)
                        let b = low(rects[$1]) + (operation.gaps ? 0 : span(rects[$1]) / 2)
                        return a == b ? $0 < $1 : a < b
                    }
                    #expect(deltas[order.first!] == .zero && deltas[order.last!] == .zero)
                    let distances = zip(order, order.dropFirst()).map { a, b in
                        operation.gaps ? low(moved[b]) - low(moved[a]) - span(moved[a])
                            : low(moved[b]) + span(moved[b]) / 2 - low(moved[a]) - span(moved[a]) / 2
                    }
                    for distance in distances { #expect(abs(distance - distances[0]) < 0.000001) }
                }
                for delta in deltas { #expect(delta.width.isFinite && delta.height.isFinite) }
            }
        }
        metric("geometry-500-random-layouts-ten-operations", since: start)
    }

    @Test func repeatedBucketAndMaskFillsKeepSelectionsPixelsAndHistory() async throws {
        if benchmarkOnly { return }
        let s = try raster()
        s.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 16, height: 64), transform: nil), antialiased: false)
        let selection = s.selection
        var states = [try #require(s.document)]
        var start = DispatchTime.now().uptimeNanoseconds
        for iteration in 0..<300 {
            s.foregroundColor = PaletteColor(red: iteration % 2 == 0 ? 1 : 0, green: iteration % 2 == 0 ? 0 : 1, blue: 0)
            #expect(await s.paintBucket(at: CGPoint(x: 4, y: 4)) == .changed)
            #expect(try rgba(s, x: 4, y: 4) == (iteration % 2 == 0 ? [255, 0, 0, 255] : [0, 255, 0, 255]))
            #expect(try rgba(s, x: 20, y: 4) == [255, 255, 255, 255])
            #expect(try rgba(s, x: 48, y: 4) == [0, 0, 0, 255])
            #expect(s.selection == selection && !s.isProjectBusy && s.activeEditOwner == nil)
            #expect(s.history.undoCount <= 100 && s.history.retainedBytes(current: s.document) <= s.history.retainedByteLimit)
            states.append(try #require(s.document))
            if states.count > 101 { states.removeFirst() }
        }
        for state in states.dropLast().reversed() { s.undo(); #expect(s.document == state) }
        for state in states.dropFirst() { s.redo(); #expect(s.document == state) }
        metric("bucket-300-fills-and-100-undo-redo", since: start)
        s.history.reset()
        s.addLayerMask(revealing: true); s.isMaskSelected = true
        start = DispatchTime.now().uptimeNanoseconds
        for iteration in 0..<120 {
            s.maskPaintWhite = iteration % 2 != 0
            #expect(await s.paintBucket(at: CGPoint(x: 4, y: 4)) == .changed)
            #expect(s.selection == selection && !s.isProjectBusy && s.activeEditOwner == nil)
            let image = try #require(s.activeLayer?.mask?.asset.image)
            try autoreleasepool {
                let c = try BrushRaster.context(width: image.width, height: image.height, mask: true)
                BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: true, context: c)
                let data = try #require(c.data?.assumingMemoryBound(to: UInt8.self))
                #expect(data[4 * c.bytesPerRow + 4] == (iteration % 2 == 0 ? 0 : 255))
                #expect(data[4 * c.bytesPerRow + 48] == 255)
            }
        }
        metric("bucket-mask-120-partial-fills", since: start)
    }

    @Test func busyClickAndStaleCallbackStormNeverPartiallyCommits() async throws {
        if benchmarkOnly { return }
        let start = DispatchTime.now().uptimeNanoseconds
        for iteration in 0..<60 {
            let s = try raster()
            let clip = try #require(MagicWand.coverage(in: try #require(s.activeLayer?.asset?.image), at: CGPoint(x: 4, y: 4), settings: s.bucketSettings))
            let gate = PressureGate()
            let work = Task { await s.paintBucket(at: CGPoint(x: 4, y: 4), match: { _ in try await gate.hold() }) }
            await gate.waitForStart()
            for _ in 0..<32 { #expect(await s.paintBucket(at: CGPoint(x: 4, y: 4)) == .rejected(.busy)) }
            switch iteration % 3 {
            case 0: s.document = CanvasDocument(width: 64, height: 64, layers: try #require(s.document).layers)
            case 1: s.beginEdit("Rename Layer"); s.document?.layers[0].name = "New revision"; s.endEdit()
            default:
                let old = try #require(s.activeEditOwner)
                s.releaseEdit(old)
                let newer = try #require(s.beginOwnedEdit())
                let unchanged = s.document
                await gate.finish(clip)
                #expect(await work.value == .rejected(.stale))
                #expect(s.document == unchanged && s.ownsEdit(newer) && s.isProjectBusy)
                s.releaseEdit(newer)
                continue
            }
            let unchanged = s.document
            await gate.finish(clip)
            #expect(await work.value == .rejected(.stale))
            #expect(s.document == unchanged && !s.isProjectBusy && s.activeEditOwner == nil)
            #expect(s.history.undoCount == (iteration % 3 == 1 ? 1 : 0))
        }
        metric("async-60-stale-jobs-and-1920-busy-clicks", since: start)
    }

    @Test func cancelledBucketJobsNeverInstallTheirResult() async throws {
        if benchmarkOnly { return }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<25 {
            let s = try raster()
            let before = s.document
            let clip = try #require(MagicWand.coverage(in: try #require(s.activeLayer?.asset?.image), at: CGPoint(x: 4, y: 4), settings: s.bucketSettings))
            let gate = PressureGate()
            let work = Task { await s.paintBucket(at: CGPoint(x: 4, y: 4), match: { _ in try await gate.hold() }) }
            await gate.waitForStart()
            work.cancel()
            await gate.finish(clip)
            #expect(await work.value != .changed)
            #expect(s.document == before && s.history.undoCount == 0)
            #expect(!s.isProjectBusy && s.activeEditOwner == nil)
        }
        metric("async-25-cancelled-jobs", since: start)
    }

    @Test func cancelledSharedRasterCommitsKeepPixelsAndHistory() async throws {
        if benchmarkOnly { return }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<25 {
            let s = try raster()
            let before = s.document
            let edit = try s.makeRasterEdit(for: try #require(s.activeLayer), growsMask: true)
            try edit.fill(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            let gate = PressureGate()
            let work = Task {
                _ = try await gate.hold()
                return try await s.commitRasterEdit(edit, name: "Fill")
            }
            await gate.waitForStart()
            work.cancel()
            await gate.finish(nil)
            #expect(try await work.value == false)
            #expect(s.document == before && s.history.undoCount == 0 && !s.history.hasPendingEdit)
            #expect(!s.isProjectBusy && s.activeEditOwner == nil)
        }
        metric("async-25-cancelled-shared-raster-commits", since: start)
    }

    @Test func actualLargeRasterFillsHaveMeasuredBoundsAndUndoBudget() async throws {
        if benchmarkOnly { return }
        for (width, height, count) in [(1920, 1080, 3), (3840, 2160, 24), (6000, 4000, 12)] {
            let s = try raster(width: width, height: height)
            for iteration in 0..<count {
                s.foregroundColor = PaletteColor(red: iteration % 2 == 0 ? 1 : 0, green: iteration % 2 == 0 ? 0 : 1, blue: 0)
                let start = DispatchTime.now().uptimeNanoseconds
                #expect(await s.paintBucket(at: CGPoint(x: 4, y: 4)) == .changed)
                metric("bucket-\(width)x\(height)-fill-\(iteration)", since: start)
                #expect(try rgba(s, x: 4, y: 4) == (iteration % 2 == 0 ? [255, 0, 0, 255] : [0, 255, 0, 255]))
                #expect(try rgba(s, x: width - 4, y: height - 4) == [0, 0, 0, 255])
                #expect(s.history.retainedBytes(current: s.document) <= s.history.retainedByteLimit)
                #expect(!s.isProjectBusy && s.activeEditOwner == nil && !s.history.hasPendingEdit)
            }
            while s.canUndo { s.undo() }
            while s.canRedo { s.redo() }
            #expect(s.history.retainedBytes(current: s.document) <= s.history.retainedByteLimit)
        }
    }
}
