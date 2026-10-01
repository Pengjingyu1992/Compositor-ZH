import AppKit

/// Display-only comparison: new sample above, pre-drag color below.
final class SampleRingOverlay: NSView {
    var original = PaletteColor.black
    var sampled = PaletteColor.black
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 15, dy: 15))
        ring.lineWidth = 24
        NSColor(white: 0.45, alpha: 1).setStroke()
        ring.stroke()
        ring.lineWidth = 16
        for (color, y) in [(sampled, CGFloat(0)), (original, bounds.midY)] {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: CGRect(x: 0, y: y, width: bounds.width, height: bounds.height / 2)).addClip()
            color.nsColor.setStroke()
            ring.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
