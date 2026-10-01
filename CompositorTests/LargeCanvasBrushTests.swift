import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Blur, Smudge and Liquify at the largest brush on a big canvas.
@MainActor
struct LargeCanvasBrushTests {
    private func session(side: Int) throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: side, height: side)
        let context = try BrushRaster.context(width: side, height: side, mask: false)
        for band in 0..<8 {
            context.setFillColor(CGColor(srgbRed: CGFloat(band) / 7, green: 0.4, blue: 1 - CGFloat(band) / 7, alpha: 1))
            context.fill(CGRect(x: band * side / 8, y: 0, width: side / 8 + 1, height: side))
        }
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Bands"))
        session.selectTool(.blur)
        session.brushSettings.diameter = 2000
        session.brushSettings.hardness = 0.5
        return session
    }

    private func stroke(_ session: EditorSession, side: Int) {
        let y = Double(side) / 2
        session.beginBrush(at: CGPoint(x: 1000, y: y))
        for step in 1...20 { session.continueBrush(at: CGPoint(x: 1000 + Double(step) * 100, y: y + Double(step % 3) * 40)) }
        session.finishBrushImmediately()
    }

    /// Committing a Smudge or Liquify lays a tip a little wider than the brush, which at the largest Size was refused.
    @Test(arguments: [BlurToolMode.liquify, .smudge, .blur])
    func largestBrushCommits(mode: BlurToolMode) throws {
        let side = 5000
        let session = try session(side: side)
        session.blurMode = mode
        session.brushSettings.blurRadius = 20
        let before = session.activeLayer?.asset?.image
        stroke(session, side: side)
        #expect(session.brushError == nil, "\(mode.rawValue): \(session.brushError ?? "")")
        #expect(session.activeLayer?.asset?.image !== before, "\(mode.rawValue) left the layer unchanged")
    }

    /// Blur softens a piece at a time; each piece is exactly that part of the layer blurred as a whole.
    @Test func blurPiecesMatchTheWhole() throws {
        let session = try session(side: 600)
        session.blurMode = .blur
        session.brushSettings.blurRadius = 12
        let layer = try #require(session.activeLayer)
        let stroke = try session.makeRasterEdit(for: layer, settings: session.brushSettings)
        let blur = try #require(session.blurSample(for: stroke))
        let image = blur.sample.image
        let whole = try BrushRaster.copy(try #require(blur.render(CGRect(x: 0, y: 0, width: image.width, height: image.height))))
        let wholeData = try #require(whole.data).assumingMemoryBound(to: UInt8.self)
        var largest = 0
        for part in [CGRect(x: 0, y: 0, width: 256, height: 256), CGRect(x: 250, y: 300, width: 260, height: 180),
                     CGRect(x: CGFloat(image.width) - 100, y: CGFloat(image.height) - 70, width: 100, height: 70)] {
            let piece = try BrushRaster.copy(try #require(blur.render(part)))
            let data = try #require(piece.data).assumingMemoryBound(to: UInt8.self)
            for y in 0..<piece.height { for x in 0..<piece.width * 4 {
                let a = Int(data[y * piece.bytesPerRow + x])
                let b = Int(wholeData[(y + Int(part.minY)) * whole.bytesPerRow + Int(part.minX) * 4 + x])
                largest = max(largest, abs(a - b))
            } }
        }
        #expect(largest <= 1, "a piece differs from the whole by \(largest) levels")
    }
}
