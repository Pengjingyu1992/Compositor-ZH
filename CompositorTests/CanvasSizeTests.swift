import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Compositor

@MainActor
struct CanvasSizeTests {
    @Test func everyAnchorPreservesSourceAndTransformForExpansionAndShrink() async throws {
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        session.beginTransform()
        var transform = try #require(session.transformEdit?.draft)
        transform.rotation = 37
        transform.flipX = true
        session.previewTransform(transform)
        session.commitTransform()
        let source = try #require(session.projectSnapshot())
        let layer = try #require(source.manifest.layers.first)
        for delta in [5, -5] {
            for anchor in 0...8 {
                let options = CanvasSizeOptions(width: 64 + delta, height: 32 + delta, anchor: anchor)
                let result = try await CanvasResizer.shared.resize(source, to: options)
                let output = try #require(result.manifest.layers.first)
                let expected = [0, delta == 5 ? 2 : -3, delta]
                #expect(output.transform.origin.x == transform.origin.x + CGFloat(expected[anchor % 3]))
                #expect(output.transform.origin.y == transform.origin.y + CGFloat(expected[anchor / 3]))
                #expect(output.transform.size == transform.size)
                #expect(output.transform.rotation == 37 && output.transform.flipX)
                #expect(output.id == layer.id)
                #expect(result.images[layer.id]?.image === source.images[layer.id]?.image)
            }
        }
    }

    @Test func relativeRatioAndUnitsUseFinalDimensions() {
        var draft = CanvasSizeDraft(width: 1000, height: 500, resolution: 100)
        draft.relative = true
        draft.locked = true
        draft.set(200, widthAxis: true)
        #expect(draft.width == 1200 && draft.height == 600)
        #expect(draft.displayed(widthAxis: false) == 100)
        draft.set(-250, widthAxis: false)
        #expect(draft.width == 500 && draft.height == 250)
        draft.relative = false
        draft.unit = .inches
        draft.set(10, widthAxis: true)
        #expect(draft.width == 1000 && draft.height == 500)
        draft.unit = .percent
        draft.set(50, widthAxis: true)
        #expect(draft.width == 500 && draft.height == 250)
        draft.unit = .centimeters
        #expect(abs(draft.displayed(widthAxis: true) - 12.7) < 0.001)
        draft.unit = .pixels
        draft.set(0, widthAxis: true)
        #expect(!draft.valid)
    }

    @Test func coloredExtensionPreservesOldTransparencyAndRoundTripsWithUndo() async throws {
        let session = EditorSession()
        session.createDocument(width: 4, height: 4)
        session.addBlankLayer()
        let before = try #require(session.document)
        let input = try #require(session.projectSnapshot())
        let red = CanvasExtensionColor(red: 1, green: 0, blue: 0)
        // Mixed shrink/expand: only left/right bands should be colored.
        let output = try await CanvasResizer.shared.resize(input,
            to: CanvasSizeOptions(width: 8, height: 2, fill: red))
        #expect(output.manifest.layers.count == 2)
        #expect(output.manifest.activeLayerID == input.manifest.activeLayerID)
        let data = try await ImageExporter.shared.pngData(output)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(try #require(bitmap.colorAt(x: 0, y: 0)).alphaComponent == 1)
        #expect(try #require(bitmap.colorAt(x: 0, y: 0)).redComponent > 0.99)
        #expect(try #require(bitmap.colorAt(x: 3, y: 0)).alphaComponent == 0)
        #expect(try #require(bitmap.colorAt(x: 7, y: 1)).alphaComponent == 1)
        session.applyDocumentSize(output, actionName: "Canvas Size")
        session.undo()
        #expect(session.document == before)
        session.redo()
        #expect(session.document?.width == 8 && session.document?.height == 2)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Canvas-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(output, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let reopened = try await ImageExporter.shared.pngData(loaded)
        let reopenedBitmap = try #require(NSBitmapImageRep(data: reopened))
        #expect(try #require(reopenedBitmap.colorAt(x: 3, y: 0)).alphaComponent == 0)
        #expect(try #require(reopenedBitmap.colorAt(x: 0, y: 0)).redComponent > 0.99)
    }

    @Test func transparentResizeIsAllocationFreeAndShrinkDoesNotAddFill() async throws {
        let session = EditorSession()
        session.createDocument(width: 4, height: 4)
        let input = try #require(session.projectSnapshot())
        let large = try await CanvasResizer.shared.resize(input, to: CanvasSizeOptions(width: 30_000, height: 30_000))
        #expect(large.images.isEmpty)
        let white = CanvasExtensionColor(red: 1, green: 1, blue: 1)
        let small = try await CanvasResizer.shared.resize(input, to: CanvasSizeOptions(width: 2, height: 2, fill: white))
        #expect(small.images.isEmpty && small.manifest.layers.isEmpty)
        await #expect(throws: ProjectError.self) {
            try await CanvasResizer.shared.resize(input, to: CanvasSizeOptions(width: 30_000, height: 30_000, fill: white))
        }
        #expect(session.document?.width == 4)
    }
}
