import AppKit
import Testing
@testable import Compositor

@MainActor
struct ShapeToolTests {
    private func makeSession() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 100, height: 80, emptyLayer: true)
        session.selectTool(.shape)
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        return session
    }
    private func drag(_ session: EditorSession, from start: CGPoint, to end: CGPoint, square: Bool = false, fromCenter: Bool = false) {
        session.beginShape(at: start)
        session.dragShape(to: end, square: square, fromCenter: fromCenter)
        session.finishShape()
    }
    /// The flattened document as RGBA bytes, and a reader for one pixel's red and alpha.
    private func pixels(_ session: EditorSession) async throws -> (Int, Int) -> (red: Int, alpha: Int) {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                              count: image.width * image.height * 4))
        let width = image.width
        return { x, y in (Int(bytes[(y * width + x) * 4]), Int(bytes[(y * width + x) * 4 + 3])) }
    }

    @Test func rectangleFillsANewLayerWithTheForegroundColorAsOneUndoStep() async throws {
        let session = makeSession()
        session.selectAll()
        let count = session.history.undoCount
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 30))
        let document = try #require(session.document)
        #expect(document.layers.map(\.name) == [L10n.format("Layer %lld", 1), L10n.format("%@ %lld", L10n.text("Rectangle"), 1)])
        #expect(session.activeLayer?.name == L10n.format("%@ %lld", L10n.text("Rectangle"), 1) && session.history.undoCount == count + 1)
        #expect(session.activeLayer?.transform.origin == CGPoint(x: 10, y: 10)
                && session.activeLayer?.transform.size == CGSize(width: 30, height: 20))
        #expect(session.selection != nil) // unlike Paste, drawing a shape keeps the selection
        let pixel = try await pixels(session)
        #expect(pixel(25, 20) == (255, 255) && pixel(10, 10) == (255, 255) && pixel(39, 29) == (255, 255))
        #expect(pixel(9, 20).alpha == 0 && pixel(40, 20).alpha == 0 && pixel(25, 30).alpha == 0)

        drag(session, from: CGPoint(x: 60, y: 10), to: CGPoint(x: 70, y: 20))
        #expect(session.activeLayer?.name == L10n.format("%@ %lld", L10n.text("Rectangle"), 2))
        session.undo()
        session.undo()
        #expect(session.document?.layers.map(\.name) == [L10n.format("Layer %lld", 1)])
    }

    @Test func ellipseLeavesItsCornersClearWithShiftCircleAndOptionFromCenter() async throws {
        let session = makeSession()
        session.toggleShapeKind()
        #expect(session.shapeKind == .ellipse)
        drag(session, from: CGPoint(x: 50, y: 40), to: CGPoint(x: 60, y: 45), square: true, fromCenter: true)
        #expect(session.activeLayer?.name == L10n.format("%@ %lld", L10n.text("Ellipse"), 1))
        #expect(session.activeLayer?.transform.origin == CGPoint(x: 40, y: 30)
                && session.activeLayer?.transform.size == CGSize(width: 20, height: 20))
        let pixel = try await pixels(session)
        #expect(pixel(50, 40) == (255, 255) && pixel(41, 40).alpha > 0 && pixel(50, 31).alpha > 0)
        #expect(pixel(40, 30).alpha == 0 && pixel(59, 49).alpha == 0) // outside the circle, inside its box
    }

    @Test func aClickEscapeOrToolSwitchMakesNoLayer() {
        let session = makeSession()
        let count = session.history.undoCount
        session.beginShape(at: CGPoint(x: 20, y: 20))
        session.finishShape()
        session.beginShape(at: CGPoint(x: 20, y: 20))
        session.dragShape(to: CGPoint(x: 50, y: 50), square: false, fromCenter: false)
        #expect(session.shapeDraft?.rect == CGRect(x: 20, y: 20, width: 30, height: 30))
        session.cancelShape()
        session.beginShape(at: CGPoint(x: 20, y: 20))
        session.dragShape(to: CGPoint(x: 50, y: 50), square: false, fromCenter: false)
        session.selectTool(.brush)
        #expect(session.shapeDraft == nil && session.history.undoCount == count)
        #expect(session.document?.layers.count == 1)
    }

    @Test func newShapesAndTextGoAboveExistingFolderContents() throws {
        let session = makeSession()
        session.groupSelectedLayers()
        let folder = try #require(session.activeLayerID)
        session.addBlankLayer()
        session.groupSelectedLayers()
        let nested = try #require(session.activeLayerID)
        let previous = try #require(session.document?.renderLayers.map(\.id))

        session.selectLayer(folder)
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 60))
        let shape = try #require(session.activeLayerID)
        #expect(session.activeLayer?.liveShape != nil && session.activeLayer?.parentID == folder)
        #expect(session.document?.renderLayers.map(\.id) == previous + [shape])
        session.undo()
        #expect(session.document?.renderLayers.map(\.id) == previous)

        session.selectLayer(folder)
        session.beginText(at: CGPoint(x: 10, y: 60), newLayer: true)
        var draft = try #require(session.textDraft)
        draft.style.content = "Top of folder"
        #expect(session.applyText(draft))
        let text = try #require(session.activeLayerID)
        #expect(session.activeLayer?.liveText != nil && session.activeLayer?.parentID == folder)
        #expect(session.document?.renderLayers.map(\.id) == previous + [text])
        #expect(session.document?.layers.first(where: { $0.id == nested })?.parentID == folder)
    }

    @Test(arguments: [false, true])
    func shapePreviewShowsWithAHiddenLayerOrFolderSelected(selectFolder: Bool) throws {
        let session = makeSession()
        if selectFolder {
            let pixels = try BrushRaster.context(width: 100, height: 80, mask: false)
            pixels.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            pixels.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
            let image = try #require(pixels.makeImage())
            session.document?.layers[0].asset = ImportedImage(image: image, thumbnail: image, name: "Blue")
            session.groupSelectedLayers()
        } else {
            session.document?.layers[0].isVisible = false
        }
        let size = CGSize(width: 100, height: 80)
        let canvas = CanvasView(session: session)
        canvas.frame = CGRect(origin: .zero, size: size)
        session.viewport.resize(to: size, backingScale: 1, documentSize: size)
        session.zoom(to: 1)
        session.beginShape(at: CGPoint(x: 10, y: 10))
        session.dragShape(to: CGPoint(x: 90, y: 70), square: false, fromCenter: false)
        _ = try #require(session.shapeDraft)

        func centerPixel(_ image: CGImage) throws -> [UInt8] {
            let pixel = try BrushRaster.context(width: 1, height: 1, mask: false)
            BrushRaster.draw(image, in: CGRect(x: -50, y: -40, width: 100, height: 80), mask: false, context: pixel)
            let bytes = try #require(pixel.data).assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: bytes, count: 3))
        }
        func cpuFrame() throws -> CGImage {
            let cpu = try BrushRaster.context(width: 100, height: 80, mask: false)
            cpu.translateBy(x: 0, y: size.height)
            cpu.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cpu, flipped: true)
            canvas.allowsGPU = false
            canvas.draw(canvas.bounds)
            return try #require(cpu.makeImage())
        }
        func gpuFrame(_ renderer: GPUCanvasRenderer) throws -> CGImage {
            let frame = try #require(canvas.gpuFrame(size: size))
            return try #require(renderer.context.createCGImage(frame, from: CGRect(origin: .zero, size: size),
                                                               format: .RGBA8, colorSpace: renderer.space))
        }
        let cpuPreview = try centerPixel(cpuFrame())
        let renderer = GPUCanvasRenderer.shared
        let gpuPreview = try renderer.map { try centerPixel(gpuFrame($0)) }
        session.finishShape()
        #expect(session.activeLayer?.liveShape != nil)
        #expect(try centerPixel(cpuFrame()) == [255, 0, 0])
        #expect(cpuPreview == [255, 0, 0])
        if let renderer {
            #expect(try centerPixel(gpuFrame(renderer)) == [255, 0, 0])
            #expect(gpuPreview == [255, 0, 0])
        }
    }

    /// A corner radius cuts the rectangle's corners; one larger than half the shorter side makes a pill.
    @Test func roundedRectanglesFollowTheRadiusAndClampToAPill() async throws {
        let session = makeSession()
        session.shapeCornerRadius = 8
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 40)) // 40 × 30
        session.shapeCornerRadius = 500
        drag(session, from: CGPoint(x: 55, y: 50), to: CGPoint(x: 95, y: 70)) // 40 × 20: radius 10
        let pixel = try await pixels(session)
        #expect(pixel(10, 10).alpha == 0, "the corner is cut away")
        #expect(pixel(11, 11).alpha == 0)
        #expect(pixel(13, 13).alpha == 255, "inside the rounded corner")
        #expect(pixel(30, 10).alpha == 255, "straight edges stay full")
        #expect(pixel(30, 25) == (255, 255))
        #expect(pixel(55, 50).alpha == 0, "the pill's corner is round")
        #expect(pixel(75, 60) == (255, 255))
        #expect(session.document?.layers.count == 3)

        session.toggleShapeKind()
        session.beginShape(at: CGPoint(x: 5, y: 5))
        #expect(session.shapeDraft?.cornerRadius == 0, "ellipses take no radius")
        session.cancelShape()
    }
}
