import AppKit
#if !POLISH_CLT_CHECKS
import Testing
@testable import Compositor
#endif

private nonisolated final class PreviewProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var active = 0
    private var peak = 0
    private var canceled = 0
    private var released = false
    func release() { lock.lock(); released = true; lock.unlock() }
    private func canFinish() -> Bool { lock.lock(); defer { lock.unlock() }; return released }
    func state() -> (calls: Int, active: Int, peak: Int, canceled: Int) {
        lock.lock(); defer { lock.unlock() }
        return (calls, active, peak, canceled)
    }
    func render(_ job: FilterJob) throws -> FilterPreviewResult {
        lock.lock()
        calls += 1; active += 1; peak = max(peak, active)
        let call = calls
        lock.unlock()
        defer { lock.lock(); active -= 1; lock.unlock() }
        if call == 1 {
            // A controlled slow kernel: cancellation, not machine speed, determines its outcome.
            let deadline = Date().addingTimeInterval(5)
            while !Task.isCancelled && !canFinish() && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            if Task.isCancelled { lock.lock(); canceled += 1; lock.unlock() }
            try Task.checkCancellation()
        }
        return FilterPreviewResult(image: job.image, scope: nil)
    }
}

@MainActor struct PolishFirstBatchChecks {
    struct Result { var checks = 0; var failures: [String] = [] }
    static func run() async throws -> Result {
        var result = Result()
        func check(_ value: Bool, _ label: String) {
            result.checks += 1
            if !value { result.failures.append(label) }
        }
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: false)
        for (choice, expected) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            ApplicationAppearance.apply(choice)
            check(NSApp.appearance?.name == expected, "application appearance follows \(choice)")
            check(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected,
                  "an existing AppKit panel follows \(choice)")
            let later = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            check(later.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected,
                  "a later AppKit panel follows \(choice)")
        }
        ApplicationAppearance.apply("system")
        check(NSApp.appearance == nil, "system appearance clears the app override")

        let context = try BrushRaster.context(width: 64, height: 48, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.4, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = context.makeImage()!
        let imageBytes = try BrushRaster.copy(image)
        let size = imageBytes.bytesPerRow * imageBytes.height
        let baseline = Data(bytes: imageBytes.data!, count: size)
        let cancellation = FilterKernelCancellation()
        cancellation.cancel()
        cancellation.withScope {
            noise_add_at(imageBytes.data!.assumingMemoryBound(to: UInt8.self), 64, 48, imageBytes.bytesPerRow, 60, 1, 0, 42, 0, 0)
        }
        check(Data(bytes: imageBytes.data!, count: size) == baseline, "canceled C noise does not continue through rows")
        check(!filter_cancellation_requested(), "kernel cancellation context is restored after the job")
        noise_add_at(imageBytes.data!.assumingMemoryBound(to: UInt8.self), 64, 48, imageBytes.bytesPerRow, 60, 1, 0, 42, 0, 0)
        check(Data(bytes: imageBytes.data!, count: size) != baseline, "the next uncanceled kernel still runs normally")

        let session = EditorSession()
        session.createDocument(width: 64, height: 48)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Synthetic"))
        let original = session.document!
        let undoCount = session.history.undoCount
        let probe = PreviewProbe()
        session.filterPreviewRenderer = FilterPreviewRenderer(operation: probe.render)
        session.beginFilter(.gaussianBlur)
        session.updateFilter(FilterSettings(radius: 2), preview: true)
        let oldEdit = session.filterEdit!
        let oldTask = oldEdit.previewTask
        let deadline = Date().addingTimeInterval(3)
        while probe.state().calls == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        check(probe.state().active == 1, "controlled preview started")
        session.cancelFilter()
        check(session.filterEdit == nil, "cancel closes the edit immediately")
        check(oldEdit.pending == nil, "cancel discards queued settings")
        check(session.document == original, "cancel preserves document pixels and metadata")
        check(session.history.undoCount == undoCount, "cancel does not add undo history")
        session.beginFilter(.gaussianBlur)
        session.updateFilter(FilterSettings(radius: 4), preview: true)
        let nextEdit = session.filterEdit!
        await oldTask?.value
        while let task = nextEdit.previewTask { await task.value }
        let state = probe.state()
        check(state.canceled == 1, "cancel reaches the detached worker")
        check(state.peak == 1, "old and new previews never overlap for one document")
        check(state.active == 0, "all preview work finishes")
        check(oldEdit.preparedPreview == nil, "obsolete result cannot populate a canceled edit")
        check(nextEdit.preparedPreview != nil && nextEdit.previewError == nil, "the new preview remains usable")
        session.cancelFilter()

        let staleProbe = PreviewProbe()
        session.filterPreviewRenderer = FilterPreviewRenderer(operation: staleProbe.render)
        session.beginFilter(.gaussianBlur)
        let staleEdit = session.filterEdit!
        let staleTask = staleEdit.previewTask
        let staleDeadline = Date().addingTimeInterval(3)
        while staleProbe.state().calls == 0 && Date() < staleDeadline { try await Task.sleep(for: .milliseconds(5)) }
        check(staleProbe.state().active == 1, "stale preview started before the document changes")
        let replacement = CanvasDocument(width: 80, height: 60, layers: [])
        session.document = replacement
        staleProbe.release()
        await staleTask?.value
        check(session.document == replacement, "an old callback cannot change the replacement document")
        check(staleEdit.preparedPreview == nil, "an old document cannot acquire a stale preview")
        check(session.filterEdit == nil, "a stale edit is closed without touching the new document")

        let committing = EditorSession()
        committing.createDocument(width: 64, height: 48)
        committing.insert(ImportedImage(image: image, thumbnail: image, name: "Synthetic"))
        let commitProbe = PreviewProbe()
        committing.filterPreviewRenderer = FilterPreviewRenderer(operation: commitProbe.render)
        committing.beginFilter(.gaussianBlur)
        let commitDeadline = Date().addingTimeInterval(3)
        while commitProbe.state().calls == 0 && Date() < commitDeadline { try await Task.sleep(for: .milliseconds(5)) }
        let countBeforeCommit = committing.history.undoCount
        await committing.commitFilter()
        check(commitProbe.state().canceled == 1 && commitProbe.state().active == 0,
              "commit drains the old preview before full-size rendering")
        check(committing.filterEdit == nil && committing.canUndo, "commit releases the editor and its owner")
        check(committing.history.undoCount == countBeforeCommit + 1, "commit remains one undo step")
        committing.undo()
        check(committing.activeLayer?.asset?.image === image, "undo restores the original pixels after commit")

        // Real pixels still take the same path when no cancellation is requested.
        for kind in [FilterKind.addNoise, .mosaic, .lensCorrection, .gaussianBlur, .colorHalftone] {
            let job = FilterJob(kind: kind, image: image, settings: FilterSettings(radius: 2, amount: 10), scale: 1,
                                selection: nil, mapping: .identity, seed: 17)
            let expected = try PixelFilter.run(job)
            let rendered = try await FilterPreviewRenderer().render(job, cancellation: FilterKernelCancellation())
            let a = try BrushRaster.copy(expected), b = try BrushRaster.copy(rendered.image)
            check(a.width == b.width && a.height == b.height, "\(kind.rawValue) preview dimensions")
            check(Data(bytes: a.data!, count: a.bytesPerRow * a.height) == Data(bytes: b.data!, count: b.bytesPerRow * b.height),
                  "\(kind.rawValue) uncanceled preview preserves pixels")
        }
        return result
    }
}

#if !POLISH_CLT_CHECKS
@MainActor struct PolishFirstBatchTests {
    @Test func appearanceAndFilterCancellation() async throws {
        let result = try await PolishFirstBatchChecks.run()
        #expect(result.failures.isEmpty, "\(result.failures)")
    }
}
#endif
