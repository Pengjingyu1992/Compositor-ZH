import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum BatchExportFormat: String, Codable, CaseIterable, Sendable { case png = "PNG", jpeg = "JPEG" }
nonisolated struct BatchExportOptions: Codable, Sendable {
    var longSides = [0, 1080, 2048]
    var format: BatchExportFormat = .png
    var quality: Double = 0.9
    var prefix = ""
    var individualLayers = false
    var isValid: Bool {
        !longSides.isEmpty && longSides.count <= 20 && Set(longSides).count == longSides.count
        && longSides.allSatisfy { (0...DocumentLimits.maxSide).contains($0) }
        && quality.isFinite && (0...1).contains(quality) && prefix.count <= 120
    }
}

actor BatchImageExporter {
    static let shared = BatchImageExporter()
    nonisolated static func safeName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        let clean = String(String(name.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined()).prefix(120))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean == "." || clean == ".." ? "Export" : clean
    }
    nonisolated static func isolate(_ id: UUID, in snapshot: ProjectSnapshot) throws -> ProjectSnapshot {
        var manifest = snapshot.manifest
        let records = Dictionary(uniqueKeysWithValues: manifest.layers.map { ($0.id, $0) })
        guard records[id] != nil else { throw ProjectError.invalid }
        var included: Set<UUID> = [id], ancestors = Set<UUID>()
        for layer in manifest.layers {
            var parent = layer.parentID, seen = Set<UUID>()
            while let p = parent, seen.insert(p).inserted {
                if p == id { included.insert(layer.id); break }
                parent = records[p]?.parentID
            }
        }
        var parent = records[id]?.parentID
        while let p = parent, ancestors.insert(p).inserted { parent = records[p]?.parentID }
        guard manifest.layers.contains(where: { included.contains($0.id) && $0.imageFile != nil }) else { throw ProjectError.invalid }
        for index in manifest.layers.indices {
            let layer = manifest.layers[index]
            manifest.layers[index].isVisible = layer.id == id || ancestors.contains(layer.id) || (included.contains(layer.id) && layer.isVisible)
        }
        return ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks)
    }
    func export(_ snapshot: ProjectSnapshot, selected: Set<UUID>, name: String,
                options: BatchExportOptions, folder: URL,
                progress: (@Sendable (Int, Int) async -> Void)? = nil) async throws -> URL {
        guard options.isValid else { throw ProjectError.invalid }
        let fm = FileManager.default
        let run = "Export-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(8)
        let stage = folder.appendingPathComponent("." + run + ".partial", isDirectory: true)
        let destination = folder.appendingPathComponent(run, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        var completed = false
        defer { if !completed { try? fm.removeItem(at: stage) } }
        let targets: [(String, ProjectSnapshot)]
        if options.individualLayers {
            let candidates = snapshot.manifest.layers.filter { selected.contains($0.id) }
            guard !candidates.isEmpty, candidates.count <= 100 else { throw ProjectError.invalid }
            targets = try candidates.map { ($0.name + "-" + $0.id.uuidString.prefix(8), try Self.isolate($0.id, in: snapshot)) }
        } else { targets = [(name, snapshot)] }
        var names = Set<String>()
        let total = targets.count * Set(options.longSides.map { $0 == 0 ? max(snapshot.manifest.width, snapshot.manifest.height) : $0 }).count
        var count = 0
        await progress?(count, total)
        for (targetName, target) in targets {
            try Task.checkCancellation()
            let raster = try await ImageExporter.shared.render(target)
            for side in options.longSides {
                try Task.checkCancellation()
                let factor = side == 0 ? 1 : Double(side) / Double(max(raster.image.width, raster.image.height))
                let width = max(1, Int((Double(raster.image.width) * factor).rounded()))
                let height = max(1, Int((Double(raster.image.height) * factor).rounded()))
                guard width * height <= DocumentLimits.maxSurfacePixels else { throw ExportError.tooLarge }
                let data = try autoreleasepool {
                    let context = try BrushRaster.context(width: width, height: height, mask: false)
                    if options.format == .jpeg { context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height)) }
                    context.interpolationQuality = .high
                    context.saveGState(); context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
                    context.draw(raster.image, in: CGRect(x: 0, y: 0, width: width, height: height)); context.restoreGState()
                    guard let image = context.makeImage() else { throw ExportError.render }
                    let encoded = NSMutableData()
                    guard let writer = CGImageDestinationCreateWithData(encoded, (options.format == .png ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil) else { throw ExportError.encode }
                    CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: options.quality,
                        kCGImagePropertyDPIWidth: raster.resolution, kCGImagePropertyDPIHeight: raster.resolution] as CFDictionary)
                    guard CGImageDestinationFinalize(writer) else { throw ExportError.encode }
                    return encoded as Data
                }
                let file = Self.safeName(options.prefix + targetName) + "_" + width.description + "x" + height.description + "." + (options.format == .png ? "png" : "jpg")
                guard names.insert(file.lowercased()).inserted else { continue }
                try data.write(to: stage.appendingPathComponent(file), options: [.atomic])
                count += 1
                await progress?(count, total)
            }
        }
        try Task.checkCancellation()
        try fm.moveItem(at: stage, to: destination); completed = true
        return destination
    }
}

struct BatchExportDraft: Identifiable {
    let id = UUID()
    let owner: EditOwner
    let snapshot: ProjectSnapshot
    let selected: Set<UUID>
    let name: String
}

extension EditorSession {
    func openBatchExport() {
        guard canEditLayers, let snapshot = projectSnapshot(), let owner = beginOwnedEdit() else { return }
        batchExportResult = nil
        batchExportCompleted = 0; batchExportTotal = 0
        batchExportDraft = BatchExportDraft(owner: owner, snapshot: snapshot, selected: selectedLayerIDs,
            name: projectURL?.deletingPathExtension().lastPathComponent ?? L10n.text("Untitled"))
    }
    func cancelBatchExport() {
        guard let draft = batchExportDraft, !batchExportRunning else { return }
        batchExportDraft = nil; releaseEdit(draft.owner)
    }
    func startBatchExport(_ options: BatchExportOptions, folder: URL, draftID: UUID) {
        guard batchExportDraft?.id == draftID, batchExportTask == nil, !batchExportRunning else { return }
        batchExportTask = Task { [weak self] in
            guard let self else { return }
            await self.exportBatch(options, folder: folder)
            self.batchExportTask = nil
        }
    }
    func stopBatchExport() { batchExportTask?.cancel() }
    func exportBatch(_ options: BatchExportOptions, folder: URL) async {
        guard let draft = batchExportDraft, ownsEdit(draft.owner), !batchExportRunning else { return }
        batchExportRunning = true
        batchExportResult = nil; batchExportCompleted = 0; batchExportTotal = 0
        let access = folder.startAccessingSecurityScopedResource()
        defer { batchExportRunning = false; if access { folder.stopAccessingSecurityScopedResource() } }
        do {
            let output = try await BatchImageExporter.shared.export(draft.snapshot, selected: draft.selected,
                name: draft.name, options: options, folder: folder) { [weak self] completed, total in
                    await self?.updateBatchExportProgress(draftID: draft.id, completed: completed, total: total)
                }
            batchExportResult = L10n.format("Exported to %@", output.path)
        } catch is CancellationError { batchExportResult = L10n.text("Export cancelled. No output folder was created.") }
        catch { brushError = error.localizedDescription }
    }
    private func updateBatchExportProgress(draftID: UUID, completed: Int, total: Int) {
        guard batchExportDraft?.id == draftID else { return }
        batchExportCompleted = completed; batchExportTotal = total
    }
}
