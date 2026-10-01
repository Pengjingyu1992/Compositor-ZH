import AppKit

final class BrushCursorOverlay: NSView {
    private var circle: CGRect?
    /// Clone Stamp's source crosshair, in view points.
    private var marker: CGPoint?
    /// Clone Stamp's preview of what a click would stamp, drawn inside the circle.
    private var preview: CGImage?
    private var previewOpacity: CGFloat = 1
    /// One click's coverage (white with alpha), which shapes the preview's edge to the brush hardness.
    private var tip: CGImage?
    private static let markerReach: CGFloat = 7
    /// While hardness is being dragged: the fraction of the radius painted at full strength, shown as an inner ring.
    private var hardness: CGFloat?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(point: CGPoint?, diameter: CGFloat, sample: CGPoint? = nil, preview: CGImage? = nil,
                previewOpacity: CGFloat = 1, tip: CGImage? = nil, hardness: CGFloat? = nil) {
        let next = point.map { CGRect(x: $0.x - diameter / 2, y: $0.y - diameter / 2, width: diameter, height: diameter) }
        if circle != next || self.preview !== preview || self.previewOpacity != previewOpacity || self.tip !== tip || self.hardness != hardness {
            if let circle { setNeedsDisplay(circle.insetBy(dx: -3, dy: -3)) }
            circle = next
            self.preview = preview
            self.previewOpacity = previewOpacity
            self.tip = tip
            self.hardness = hardness
            if let next { setNeedsDisplay(next.insetBy(dx: -3, dy: -3)) }
        }
        if marker != sample {
            let reach = Self.markerReach + 3
            if let marker { setNeedsDisplay(CGRect(x: marker.x - reach, y: marker.y - reach, width: reach * 2, height: reach * 2)) }
            marker = sample
            if let sample { setNeedsDisplay(CGRect(x: sample.x - reach, y: sample.y - reach, width: reach * 2, height: reach * 2)) }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if let circle {
            if let preview {
                context.saveGState()
                context.addEllipse(in: circle)
                context.clip()
                context.setAlpha(previewOpacity)
                context.beginTransparencyLayer(in: circle, auxiliaryInfo: nil)
                context.interpolationQuality = .medium
                // The view is flipped; images draw bottom-up.
                context.translateBy(x: circle.minX, y: circle.maxY)
                context.scaleBy(x: 1, y: -1)
                let bounds = CGRect(origin: .zero, size: circle.size)
                context.draw(preview, in: bounds)
                // Keep only what one click would lay down, so soft brushes preview softly.
                if let tip {
                    context.setBlendMode(.destinationIn)
                    context.draw(tip, in: bounds)
                }
                context.endTransparencyLayer()
                context.restoreGState()
            }
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(2.5)
            context.strokeEllipse(in: circle)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: circle)
            if let hardness, hardness > 0 {
                let inset = circle.width * (1 - hardness) / 2
                let inner = circle.insetBy(dx: inset, dy: inset)
                context.setLineDash(phase: 0, lengths: [4, 3])
                context.setStrokeColor(NSColor.white.cgColor)
                context.setLineWidth(2.5)
                context.strokeEllipse(in: inner)
                context.setStrokeColor(NSColor.black.cgColor)
                context.setLineWidth(1)
                context.strokeEllipse(in: inner)
                context.setLineDash(phase: 0, lengths: [])
            }
        }
        if let marker {
            let reach = Self.markerReach
            context.move(to: CGPoint(x: marker.x - reach, y: marker.y))
            context.addLine(to: CGPoint(x: marker.x + reach, y: marker.y))
            context.move(to: CGPoint(x: marker.x, y: marker.y - reach))
            context.addLine(to: CGPoint(x: marker.x, y: marker.y + reach))
            let arms = context.path
            context.setLineCap(.round)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(3)
            context.strokePath()
            if let arms { context.addPath(arms) }
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1)
            context.strokePath()
        }
    }
}
