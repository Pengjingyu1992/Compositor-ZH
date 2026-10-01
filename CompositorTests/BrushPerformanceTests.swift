import AppKit
import Testing
@testable import Compositor

@MainActor
struct BrushPerformanceTests {
    /// Run separately from the functional suite to avoid competing main-actor work.
    @Test func fourKInteractiveStroke() async throws {
        guard ProcessInfo.processInfo.environment["BRUSH_BENCHMARK"] == "1" else { return }
        #expect(MetalBrushCoverage.shared != nil)
        for diameter: CGFloat in [40, 800] {
          for opaque in [false, true] {
            let session = EditorSession()
            session.createDocument(width: 4000, height: 4000)
            if opaque {
                let context = try BrushRaster.context(width: 4000, height: 4000, mask: false)
                context.setFillColor(gray: 0, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: 4000, height: 4000))
                let image = try #require(context.makeImage())
                session.insert(ImportedImage(image: image, thumbnail: image, name: "Opaque 4K"))
            } else { session.addBlankLayer() }
            session.selectTool(.brush)
            session.brushSettings = BrushSettings(diameter: diameter, hardness: 0, red: 1, green: 1, blue: 1)
            let view = CanvasView(session: session)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            window.orderFront(nil)
            session.viewport.resize(to: view.bounds.size, backingScale: 2, documentSize: session.document?.size)
            session.viewport.fit(documentSize: session.document!.size)
            var frameTimes: [Double] = []
            for pass in 0..<2 {
                let start = CFAbsoluteTimeGetCurrent()
                session.beginBrush(at: CGPoint(x: 700, y: 3200))
                for i in 1...120 {
                    let t = CFAbsoluteTimeGetCurrent()
                    let point = i <= 60 ? CGPoint(x: 700, y: 3200 - i * 40) : CGPoint(x: 700 + (i - 60) * 40, y: 800)
                    session.continueBrush(at: point)
                    view.synchronizeDisplay()
                    view.displayIfNeeded()
                    frameTimes.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
                }
                let end = CFAbsoluteTimeGetCurrent()
                await session.finishBrush()
                view.synchronizeDisplay()
                view.displayIfNeeded()
                print("BRUSH BENCH diameter=\(diameter) opaque=\(opaque) pass=\(pass) draw=\((end-start)*1000) mouseUp=\((CFAbsoluteTimeGetCurrent()-end)*1000)ms")
                #expect(session.brushError == nil)
            }
            frameTimes.sort()
            print("BRUSH BENCH diameter=\(diameter) opaque=\(opaque) frame median=\(frameTimes[frameTimes.count/2]) p95=\(frameTimes[Int(Double(frameTimes.count)*0.95)]) max=\(frameTimes.last!)ms")
            if diameter == 800, opaque {
                try await ImageExporter.shared.exportPNG(try #require(session.projectSnapshot()),
                    to: URL(fileURLWithPath: "/tmp/compositor-brush-benchmark.png"))
            }
            window.orderOut(nil)
          }
        }
    }
}
