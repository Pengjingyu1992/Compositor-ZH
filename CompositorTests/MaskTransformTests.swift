import AppKit
import Testing
@testable import Compositor

@MainActor
struct MaskTransformTests {
    private let square = CGRect(x: 100, y: 50, width: 100, height: 100)

    /// A 400 × 200 red layer at the canvas origin whose mask is `revealing` (white) with `square` the opposite color.
    private func maskedSession(revealing: Bool = true) throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 400, height: 200)
        let pixels = try BrushRaster.context(width: 400, height: 200, mask: false)
        pixels.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        pixels.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let image = try #require(pixels.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Layer"))
        let mask = try BrushRaster.context(width: 400, height: 200, mask: true)
        mask.setFillColor(gray: revealing ? 1 : 0, alpha: 1)
        mask.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        mask.setFillColor(gray: revealing ? 0 : 1, alpha: 1)
        mask.fill(square)
        let maskImage = try #require(mask.makeImage())
        let index = try #require(session.document?.layers.firstIndex { $0.id == session.activeLayerID })
        session.document?.layers[index].mask = LayerMask(asset: try LayerMask.asset(from: maskImage))
        #expect(session.document?.layers[index].transform.origin == .zero)
        return session
    }
    private func gray(_ image: CGImage, x: Int, y: Int) throws -> Int {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: true)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: true, context: context)
        return Int(try #require(context.data).assumingMemoryBound(to: UInt8.self)[y * context.bytesPerRow + x])
    }
    private func move(_ session: EditorSession, by dx: CGFloat) -> LayerTransform? {
        session.beginTransform()
        guard var moved = session.transformEdit?.draft else { return nil }
        moved.origin.x += dx
        session.previewTransform(moved)
        return moved
    }

    @Test func aLinkedMaskMovesWithItsLayerWhicheverThumbnailIsSelected() throws {
        let session = try maskedSession()
        let layer = try #require(session.activeLayer)
        #expect(layer.mask?.isLinked == true)
        session.selectLayerTarget(layer.id, mask: true)
        #expect(!session.transformTargetsMask)
        let moved = try #require(move(session, by: 100))
        #expect(session.transformEdit?.mask == false)
        #expect(session.displayedMaskPlacement(for: layer) == nil)
        session.commitTransform()
        #expect(session.activeLayer?.transform == moved)
        #expect(session.activeLayer?.mask?.placement == nil)
        #expect(session.activeLayer?.mask?.asset.image === layer.mask?.asset.image)
    }

    @Test func unlinkedTheLayerMovesAloneAndItsMaskStaysOnTheCanvas() throws {
        let session = try maskedSession()
        let layer = try #require(session.activeLayer)
        session.toggleMaskLink(layer.id)
        #expect(session.activeLayer?.mask?.isLinked == false)
        session.selectLayerTarget(layer.id, mask: false)
        let moved = try #require(move(session, by: 100))
        let unlinked = try #require(session.activeLayer)
        #expect(session.displayedMaskPlacement(for: unlinked) == layer.transform, "the mask stays while the layer drags")
        session.commitTransform()
        let after = try #require(session.activeLayer)
        #expect(after.transform == moved)
        #expect(after.mask?.placement == layer.transform)
        let clip = try #require(after.mask?.clipImage(placement: after.mask?.placement, over: after.transform, width: 400, height: 200))
        #expect(try gray(clip, x: 50, y: 100) < 5, "the square stayed at canvas x 100–200")
        #expect(try gray(clip, x: 150, y: 100) > 250)
        #expect(try gray(clip, x: 350, y: 100) > 250, "past its pixels the mask reveals, like its white edges")
        session.undo()
        #expect(session.activeLayer?.transform == layer.transform)
        #expect(session.activeLayer?.mask?.placement == nil)
        #expect(session.activeLayer?.mask?.isLinked == false)
    }

    @Test func unlinkedTheMaskMovesAloneAndRelinkedTheyMoveTogether() throws {
        let session = try maskedSession()
        let layer = try #require(session.activeLayer)
        session.toggleMaskLink(layer.id)
        session.selectLayerTarget(layer.id, mask: true)
        #expect(session.transformTargetsMask)
        let moved = try #require(move(session, by: 100))
        #expect(session.transformEdit?.mask == true)
        #expect(session.displayedTransform(for: layer) == layer.transform, "the layer stays put")
        #expect(session.editedTransform(for: layer) == moved, "the handles follow the mask")
        #expect(session.displayedMaskPlacement(for: layer) == moved)
        session.commitTransform()
        #expect(session.activeLayer?.transform == layer.transform)
        #expect(session.activeLayer?.mask?.placement == moved)
        #expect(session.activeLayer?.mask?.asset.image === layer.mask?.asset.image, "moving a mask never resamples it")

        session.toggleMaskLink(layer.id)
        session.selectLayerTarget(layer.id, mask: false)
        _ = try #require(move(session, by: 50))
        session.commitTransform()
        let placement = try #require(session.activeLayer?.mask?.placement)
        #expect(abs(placement.origin.x - (moved.origin.x + 50)) < 0.001 && abs(placement.origin.y - moved.origin.y) < 0.001)
        #expect(abs(placement.size.width - moved.size.width) < 0.001 && abs(placement.size.height - moved.size.height) < 0.001)
    }

    @Test func aMovedHideAllMaskKeepsHidingPastItsPixels() throws {
        let session = try maskedSession(revealing: false)
        let layer = try #require(session.activeLayer)
        session.toggleMaskLink(layer.id)
        session.selectLayerTarget(layer.id, mask: true)
        _ = try #require(move(session, by: 100))
        session.commitTransform()
        let after = try #require(session.activeLayer)
        let clip = try #require(after.mask?.clipImage(placement: after.mask?.placement, over: after.transform, width: 400, height: 200))
        #expect(try gray(clip, x: 20, y: 100) < 5, "the uncovered edge stays hidden")
        #expect(try gray(clip, x: 250, y: 100) > 250, "the revealed square moved")
    }

    @Test func placementAndLinkAreSavedAndPaintingFollowsThePlacement() throws {
        let session = try maskedSession()
        let layer = try #require(session.activeLayer)
        session.toggleMaskLink(layer.id)
        session.selectLayerTarget(layer.id, mask: true)
        let moved = try #require(move(session, by: 100))
        session.commitTransform()
        let snapshot = try #require(session.projectSnapshot())
        let records = try JSONDecoder().decode([ProjectLayerRecord].self, from: try JSONEncoder().encode(snapshot.manifest.layers))
        let record = try #require(records.first)
        let restored = try #require(snapshot.mask(for: record))
        #expect(restored.placement == moved && restored.isLinked == false)
        let stroke = try session.makeRasterEdit(for: try #require(session.activeLayer))
        let corner = CGPoint.zero.applying(stroke.pixelToDocument)
        #expect(abs(corner.x - moved.origin.x) < 0.001 && abs(corner.y - moved.origin.y) < 0.001, "mask pixels map through the placement")
    }
}
