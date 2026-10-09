import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Image › Rotate Canvas 90°: the canvas turns a quarter, its sides swap, and everything on it turns along.
@MainActor struct CanvasRotationTests {
    /// A 3 × 2 image with a different red value in every pixel, row by row from the top left: 10, 20, 30 / 40, 50, 60.
    private func session() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 3, height: 2)
        let context = try BrushRaster.context(width: 3, height: 2, mask: false)
        for (index, value) in [10, 20, 30, 40, 50, 60].enumerated() {
            context.setFillColor(CGColor(srgbRed: CGFloat(value) / 255, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: index % 3, y: index / 3, width: 1, height: 1))
        }
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Pixels"))
        return session
    }

    /// The red value of every pixel of the flattened canvas, row by row from the top left.
    private func reds(_ session: EditorSession) async throws -> [Int] {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let pixels = try BrushRaster.copy(image)
        let data = try #require(pixels.data).assumingMemoryBound(to: UInt8.self)
        return (0..<image.height).flatMap { y in (0..<image.width).map { x in Int(data[y * pixels.bytesPerRow + x * 4]) } }
    }

    @Test func clockwiseTurnsThePixelsExactly() async throws {
        let session = try session()
        session.rotateCanvas(clockwise: true)
        #expect(session.document?.width == 2 && session.document?.height == 3)
        // The left column, read bottom to top, becomes the top row.
        #expect(try await reds(session) == [40, 10, 50, 20, 60, 30])
    }

    @Test func counterclockwiseTurnsThePixelsExactly() async throws {
        let session = try session()
        session.rotateCanvas(clockwise: false)
        #expect(session.document?.width == 2 && session.document?.height == 3)
        // The right column, read top to bottom, becomes the top row.
        #expect(try await reds(session) == [30, 60, 20, 50, 10, 40])
    }

    @Test func turningBackAndUndoingRestoreTheCanvas() async throws {
        let session = try session()
        let original = try await reds(session)
        session.rotateCanvas(clockwise: true)
        session.rotateCanvas(clockwise: false)
        #expect(session.document?.width == 3 && session.document?.height == 2)
        #expect(try await reds(session) == original)
        session.rotateCanvas(clockwise: true)
        session.rotateCanvas(clockwise: true)
        #expect(try await reds(session) == original.reversed(), "two quarter turns are a half turn")
        session.undo(); session.undo()
        #expect(session.document?.width == 3 && session.document?.height == 2)
        #expect(try await reds(session) == original)
    }

    @Test func guidesAndSelectionTurnWithTheCanvas() throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 60)
        session.document?.guides = [CanvasGuide(id: UUID(), axis: .vertical, position: 30),
                                    CanvasGuide(id: UUID(), axis: .horizontal, position: 10)]
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 20, height: 10), transform: nil))
        session.rotateCanvas(clockwise: true)
        let guides = try #require(session.document?.guides)
        // Clockwise: x becomes y, and y becomes the new width less y.
        #expect(guides[0].axis == .horizontal && guides[0].position == 30)
        #expect(guides[1].axis == .vertical && guides[1].position == 50)
        let box = try #require(session.document?.selection?.path.boundingBoxOfPath)
        #expect(box == CGRect(x: 50, y: 0, width: 10, height: 20), "the top-left corner moves to the top right: \(box)")
    }
}
