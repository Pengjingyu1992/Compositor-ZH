import Foundation
import CoreGraphics
import Observation

nonisolated struct GIFExportOptions: Equatable, Sendable {
    var width: Int
    var height: Int
    var red: CGFloat = 1
    var green: CGFloat = 1
    var blue: CGFloat = 1
    var keepTransparency = true
    var background: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

nonisolated struct GIFPreparedFrame: @unchecked Sendable {
    let options: GIFExportOptions
    let frameID: UUID?
    let duration: Int
    let block: Data
    let preview: CGImage
}

/// A frozen export source and at most one prepared frame / complete encoding per dialog.
@MainActor @Observable final class GIFExportWorkspace {
    let snapshot: ProjectSnapshot?
    let fallback: ExportRaster
    private(set) var prepared: GIFPreparedFrame?
    private(set) var encoded: JPEGResult?
    private(set) var encodedOptions: GIFExportOptions?
    private(set) var isEncoding = false
    private(set) var completedFrames = 0
    private(set) var encodingRuns = 0
    var frameCount: Int { snapshot?.manifest.animation?.frames.count ?? 1 }
    @ObservationIgnored private var task: Task<JPEGResult, Error>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var options: GIFExportOptions?
    init(snapshot: ProjectSnapshot?, fallback: ExportRaster) { self.snapshot = snapshot; self.fallback = fallback }
    func settingsChanged(_ options: GIFExportOptions) {
        guard self.options != options else { return }
        cancel(); self.options = options; prepared = nil; encoded = nil; encodedOptions = nil
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; isEncoding = false; completedFrames = 0
    }
    func preview(_ options: GIFExportOptions) async throws -> CGImage {
        try Task.checkCancellation()
        settingsChanged(options)
        if let prepared, prepared.options == options { return prepared.preview }
        let token = generation
        let frameID = selectedFrameID
        let duration = snapshot?.manifest.animation?.frames.first(where: { $0.groupID == frameID })?.durationMS ?? 100
        let frame = try await ImageExporter.shared.gifPreview(fallback, options: options, frameID: frameID, duration: duration)
        try Task.checkCancellation()
        guard generation == token, self.options == options else { throw CancellationError() }
        prepared = frame
        return frame.preview
    }
    private var selectedFrameID: UUID? {
        guard let snapshot, let track = snapshot.manifest.animation else { return nil }
        let ids = Set(track.frames.map(\.groupID))
        if let id = snapshot.displayedAnimationFrameID { return ids.contains(id) ? id : track.frames.first?.groupID }
        let layers = Dictionary(uniqueKeysWithValues: snapshot.manifest.layers.map { ($0.id, $0) })
        var current = snapshot.manifest.activeLayerID, seen = Set<UUID>()
        while let id = current, seen.insert(id).inserted {
            if ids.contains(id) { return id }
            current = layers[id]?.parentID
        }
        return track.frames.first?.groupID
    }
    func encode(_ options: GIFExportOptions) async throws -> JPEGResult {
        try Task.checkCancellation()
        settingsChanged(options)
        if encodedOptions == options, let encoded { return encoded }
        if let task {
            let token = generation
            let result = try await task.value
            try Task.checkCancellation()
            guard generation == token, self.options == options else { throw CancellationError() }
            return result
        }
        let token = generation, snapshot = snapshot, fallback = fallback, prepared = prepared
        isEncoding = true; completedFrames = 0; encodingRuns += 1
        let progress: @Sendable (Int) -> Void = { [weak self] completed in
            guard let self else { return }
            Task { @MainActor in
                guard self.generation == token, self.isEncoding else { return }
                self.completedFrames = completed
            }
        }
        let job = Task.detached(priority: .userInitiated) {
            try await ImageExporter.shared.animationGIF(snapshot, fallback: fallback, width: options.width, height: options.height,
                background: options.background, keepTransparency: options.keepTransparency, prepared: prepared, progress: progress)
        }
        task = job
        defer { if generation == token { task = nil; isEncoding = false } }
        let result = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
        try Task.checkCancellation()
        guard generation == token, self.options == options else { throw CancellationError() }
        encoded = result; encodedOptions = options; completedFrames = frameCount
        return result
    }
}
