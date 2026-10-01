import AppKit
import Testing
@testable import Compositor

@MainActor
struct GradientTests {
    private func makeSession(width: Int = 101, height: Int = 4) -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: width, height: height)
        session.addBlankLayer()
        session.selectTool(.gradient)
        #expect(session.gradientSettings.style == .foregroundToTransparent)
        session.gradientSettings.style = .foregroundToBackground
        return session
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let index = (y * image.width + x) * 4
        return (0..<4).map { Int(bytes[index + $0]) }
    }
    private func render(_ session: EditorSession) async throws -> CGImage {
        try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
    }
    private func drag(_ session: EditorSession, from start: CGPoint, to end: CGPoint) {
        session.beginGradient(at: start)
        session.moveGradient(end: end)
        session.endGradientDrag()
    }
    // Core Graphics quantizes gradient ramps, so endpoints can land a few levels short.
    private func near(_ value: Int, _ target: Int, _ tolerance: Int = 3) -> Bool { abs(value - target) <= tolerance }
    private func near(_ value: [Int], _ target: [Int]) -> Bool { zip(value, target).allSatisfy { near($0, $1) } }

    @Test func foregroundToBackgroundFillsCanvasAndCommitsOneUndo() async throws {
        let session = makeSession()
        let count = session.history.undoCount
        drag(session, from: CGPoint(x: 0.5, y: 2), to: CGPoint(x: 100.5, y: 2))
        #expect(session.gradientEdit != nil)
        #expect(session.activeLayer?.asset == nil && session.history.undoCount == count)
        await session.commitGradient()
        #expect(session.gradientEdit == nil && session.brushError == nil)
        #expect(session.history.undoCount == count + 1)
        let result = try await render(session)
        #expect(near(try pixel(result, x: 0, y: 0), [0, 0, 0, 255]))
        #expect(near(try pixel(result, x: 100, y: 3), [255, 255, 255, 255]))
        let middle = try pixel(result, x: 50, y: 1)
        #expect(near(middle[0], 128) && middle[0] == middle[1] && middle[3] == 255)
        session.undo()
        #expect(session.activeLayer?.asset == nil)
    }

    @Test func radialSpreadsFromStartToRimInEveryDirection() async throws {
        let session = makeSession(width: 101, height: 101)
        session.gradientSettings.shape = .radial
        drag(session, from: CGPoint(x: 50.5, y: 50.5), to: CGPoint(x: 90.5, y: 50.5))
        await session.commitGradient()
        let result = try await render(session)
        #expect(near(try pixel(result, x: 50, y: 50), [0, 0, 0, 255]))
        // Equal distances in any direction get the same value; beyond the rim is background.
        let halfway = try [(70, 50), (30, 50), (50, 70), (50, 30)].map { try pixel(result, x: $0.0, y: $0.1)[0] }
        #expect(halfway.allSatisfy { near($0, 128, 5) && near($0, halfway[0], 1) }, "\(halfway)")
        #expect(near(try pixel(result, x: 100, y: 50), [255, 255, 255, 255]))
        #expect(near(try pixel(result, x: 0, y: 0), [255, 255, 255, 255]))
    }

    @Test func reverseOpacityAndDirectionFollowSettings() async throws {
        let session = makeSession()
        session.gradientSettings.reversed = true
        session.gradientSettings.opacity = 0.5
        drag(session, from: CGPoint(x: 0.5, y: 2), to: CGPoint(x: 100.5, y: 2))
        await session.commitGradient()
        let result = try await render(session)
        // White at the start with 50% alpha on a blank layer.
        let start = try pixel(result, x: 0, y: 2)
        #expect(near(start[3], 128) && near(start[0], start[3]))
        let end = try pixel(result, x: 100, y: 2)
        #expect(near(end[0], 0) && near(end[3], 128))
    }

    @Test func foregroundToTransparentPreservesUnderlyingPixelsAndAlpha() async throws {
        let session = makeSession()
        session.gradientSettings.style = .foregroundToBackground
        session.setPaletteColor(PaletteColor(red: 1, green: 0, blue: 0), background: false)
        // Everything before the start is foreground: a solid red layer.
        drag(session, from: CGPoint(x: 100.5, y: 2), to: CGPoint(x: 101, y: 2))
        await session.commitGradient()
        #expect(near(try pixel(try await render(session), x: 50, y: 2), [255, 0, 0, 255]))
        session.setPaletteColor(.black, background: false)
        session.gradientSettings.style = .foregroundToTransparent
        drag(session, from: CGPoint(x: 0.5, y: 2), to: CGPoint(x: 100.5, y: 2))
        await session.commitGradient()
        let result = try await render(session)
        #expect(near(try pixel(result, x: 0, y: 2), [0, 0, 0, 255]))
        #expect(near(try pixel(result, x: 100, y: 2), [255, 0, 0, 255]))
        let middle = try pixel(result, x: 50, y: 2)
        #expect(near(middle[0], 128) && middle[1] == 0 && middle[3] == 255)
    }

    @Test func cancelUndoAndClicksLeaveDocumentUntouched() async throws {
        let session = makeSession()
        let before = session.document
        session.beginGradient(at: CGPoint(x: 10, y: 2))
        session.endGradientDrag()
        #expect(session.gradientEdit == nil)
        drag(session, from: CGPoint(x: 0, y: 2), to: CGPoint(x: 100, y: 2))
        session.cancelGradient()
        #expect(session.gradientEdit == nil && session.document == before)
        drag(session, from: CGPoint(x: 0, y: 2), to: CGPoint(x: 100, y: 2))
        session.undo()
        #expect(session.gradientEdit == nil && session.document == before)
    }

    @Test func redraggingReplacesPendingLineWithoutAccumulating() async throws {
        let session = makeSession()
        drag(session, from: CGPoint(x: 0.5, y: 2), to: CGPoint(x: 100.5, y: 2))
        drag(session, from: CGPoint(x: 100.5, y: 2), to: CGPoint(x: 0.5, y: 2))
        await session.commitGradient()
        let result = try await render(session)
        #expect(near(try pixel(result, x: 0, y: 2), [255, 255, 255, 255]))
        #expect(near(try pixel(result, x: 100, y: 2), [0, 0, 0, 255]))
    }

    @Test func maskGradientWritesCoverageInsideLayerBounds() async throws {
        let session = makeSession()
        drag(session, from: CGPoint(x: 0, y: 2), to: CGPoint(x: 0.6, y: 2))
        await session.commitGradient() // Opaque black layer.
        session.addLayerMask(revealing: true)
        let id = try #require(session.activeLayerID)
        session.selectLayerTarget(id, mask: true)
        #expect(session.isMaskSelected)
        drag(session, from: CGPoint(x: 0.5, y: 2), to: CGPoint(x: 100.5, y: 2))
        await session.commitGradient()
        #expect(session.brushError == nil)
        let result = try await render(session)
        // Default mask palette paints black (hide) to white (reveal).
        #expect(near(try pixel(result, x: 0, y: 2)[3], 0))
        #expect(near(try pixel(result, x: 100, y: 2)[3], 255))
        #expect(near(try pixel(result, x: 50, y: 2)[3], 128))
    }

    @Test func paletteChangesUpdatePendingPreview() throws {
        let session = makeSession()
        drag(session, from: CGPoint(x: 0.5, y: 2), to: CGPoint(x: 100.5, y: 2))
        let revision = session.brushRevision
        session.swapPaletteColors()
        #expect(session.brushRevision > revision)
        #expect(session.gradientColors(mask: false).first.flatMap { $0.components?.first } == 1)
        session.cancelGradient()
    }
}
