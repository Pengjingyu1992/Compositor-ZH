import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Compositor

/// A project that something else writes while it is open: the document follows the package on disk, and only
/// when the package really changed.
@MainActor
struct ExternalChangeTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorExternalChangeTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// A saved two-layer project: an imported image below a blank layer.
    private func savedProject(in root: URL) async throws -> URL {
        let session = EditorSession()
        await session.importImages([try ImageImportTests().fixture(.png)])
        session.renameLayer(try #require(session.activeLayerID), to: "Base")
        session.addBlankLayer()
        let url = root.appendingPathComponent("Watched.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        return url
    }

    /// Opens the project the way the app does, so the watch is armed and the digest remembered.
    private func opened(_ url: URL) async throws -> ProjectController {
        let controller = ProjectController(session: EditorSession())
        #expect(await controller.open(url))
        return controller
    }

    /// Rewrites the package the way another app would: the same store, a different layer name.
    private func renameFirstLayerOnDisk(_ url: URL, to name: String) async throws {
        var snapshot = try await ProjectStore.shared.load(from: url)
        var layer = snapshot.manifest.layers[0]
        layer = ProjectLayerRecord(id: layer.id, name: name, isVisible: layer.isVisible, transform: layer.transform,
            imageFile: layer.imageFile, parentID: layer.parentID, isGroup: layer.isGroup, opacity: layer.opacity,
            blendMode: layer.blendMode, maskFile: layer.maskFile, maskEnabled: layer.maskEnabled, maskSourceID: layer.maskSourceID,
            adjustment: layer.adjustment, maskPlacement: layer.maskPlacement, maskLinked: layer.maskLinked, shape: layer.shape,
            effects: layer.effects, text: layer.text)
        snapshot = ProjectSnapshot(manifest: ProjectManifest(resolution: snapshot.manifest.resolution, documentID: snapshot.manifest.documentID,
            width: snapshot.manifest.width, height: snapshot.manifest.height, activeLayerID: snapshot.manifest.activeLayerID,
            layers: [layer] + snapshot.manifest.layers.dropFirst(), guides: snapshot.manifest.guides), images: snapshot.images, masks: snapshot.masks)
        try await ProjectStore.shared.save(snapshot, to: url)
    }

    private func eventually(_ timeout: Duration = .seconds(4), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(900)) }

    @Test func digestFollowsContentNotMetadata() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await savedProject(in: root)
        let manifest = url.appendingPathComponent("manifest.json")
        let before = try ProjectDigest.compute(for: url)
        // Touched, and rewritten with the same bytes: what sync clients do.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: manifest.path)
        try Data(contentsOf: manifest).write(to: manifest, options: .atomic)
        #expect(try ProjectDigest.compute(for: url) == before)
        // A real change to the manifest, then a real change to a layer's pixels.
        try await renameFirstLayerOnDisk(url, to: "Renamed elsewhere")
        let renamed = try ProjectDigest.compute(for: url)
        #expect(renamed != before)
        let images = url.appendingPathComponent("images")
        let png = try #require(try FileManager.default.contentsOfDirectory(atPath: images.path).first { $0.hasSuffix(".png") })
        let other = try Data(contentsOf: try ImageImportTests().fixture(.jpeg))
        try other.write(to: images.appendingPathComponent(png), options: .atomic)
        #expect(try ProjectDigest.compute(for: url) != renamed)
    }

    @Test func reloadKeepsViewportSelectionAndFoldersButNotHistory() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await savedProject(in: root)
        let session = EditorSession()
        session.installProject(try await ProjectStore.shared.load(from: url), from: url)
        let size = try #require(session.document?.size)
        session.viewport.viewSize = CGSize(width: 800, height: 600)
        session.viewport.setZoom(3, anchoredAt: .zero, documentSize: size)
        let active = try #require(session.document?.layers.first?.id)
        session.activeLayerID = active
        session.renameLayer(active, to: "Edited here")
        #expect(session.isModified && session.canUndo)
        try await renameFirstLayerOnDisk(url, to: "Renamed elsewhere")
        session.reloadProject(try await ProjectStore.shared.load(from: url))
        #expect(session.document?.layers.first?.name == "Renamed elsewhere")
        #expect(session.viewport.zoom == 3)
        #expect(session.activeLayerID == active)
        #expect(!session.isModified)
        #expect(!session.canUndo)
        #expect(session.projectURL == url)
    }

    @Test func writingThePackageElsewhereReloadsTheOpenProject() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await savedProject(in: root)
        let controller = try await opened(url)
        try await renameFirstLayerOnDisk(url, to: "Renamed elsewhere")
        #expect(await eventually { controller.externalChanges.reloadCount == 1 })
        #expect(controller.session.document?.layers.first?.name == "Renamed elsewhere")
        #expect(!controller.session.isModified)
        // The manifest rewritten in place, as a script would do it, is seen too.
        let manifest = url.appendingPathComponent("manifest.json")
        let text = try String(contentsOf: manifest, encoding: .utf8).replacingOccurrences(of: "Renamed elsewhere", with: "Renamed again")
        try text.write(to: manifest, atomically: true, encoding: .utf8)
        #expect(await eventually { controller.externalChanges.reloadCount == 2 })
        #expect(controller.session.document?.layers.first?.name == "Renamed again")
    }

    @Test func ourOwnSaveAndMetadataTouchesDoNotReload() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await savedProject(in: root)
        let controller = try await opened(url)
        let session = controller.session
        let active = try #require(session.document?.layers.first?.id)
        session.renameLayer(active, to: "Saved by us")
        #expect(await controller.save())
        await settle()
        #expect(controller.externalChanges.reloadCount == 0)
        #expect(session.document?.layers.first?.name == "Saved by us")
        #expect(!session.isModified)
        let manifest = url.appendingPathComponent("manifest.json")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: manifest.path)
        try Data(contentsOf: manifest).write(to: manifest, options: .atomic)
        await settle()
        #expect(controller.externalChanges.reloadCount == 0)
    }

    @Test func halfWrittenPackagesAreIgnoredUntilTheyLoad() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await savedProject(in: root)
        let controller = try await opened(url)
        let manifest = url.appendingPathComponent("manifest.json")
        let good = try Data(contentsOf: manifest)
        try Data("{ \"format\": \"com.compositor.project\", \"version\": 9, \"layers\": [".utf8).write(to: manifest, options: .atomic)
        await settle()
        #expect(controller.externalChanges.reloadCount == 0)
        #expect(controller.session.document?.layers.count == 2)
        let fixed = try #require(String(data: good, encoding: .utf8)).replacingOccurrences(of: "\"Base\"", with: "\"Finished\"")
        try fixed.write(to: manifest, atomically: true, encoding: .utf8)
        #expect(await eventually { controller.externalChanges.reloadCount == 1 })
        #expect(controller.session.document?.layers.contains { $0.name == "Finished" } == true)
    }

    @Test func unsavedWorkIsNeverReplacedWithoutAsking() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await savedProject(in: root)
        let controller = try await opened(url)
        let session = controller.session
        let active = try #require(session.document?.layers.first?.id)
        session.renameLayer(active, to: "Unsaved here")
        try await renameFirstLayerOnDisk(url, to: "Renamed elsewhere")
        await settle()
        // No window to ask in, so the question waits and the document keeps the unsaved edit.
        #expect(controller.externalChanges.reloadCount == 0)
        #expect(controller.externalChanges.pending)
        #expect(session.document?.layers.first?.name == "Unsaved here")
        #expect(session.isModified)
    }
}
