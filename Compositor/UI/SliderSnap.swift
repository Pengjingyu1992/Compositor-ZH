import AppKit
import ObjectiveC

/// On macOS 26, clicking a slider's track glides the knob to the click over about a quarter of a
/// second, even though the value changes at once. Setting a slider's value in code moves the knob
/// immediately, so this sets the value under the pointer just before the slider starts tracking the
/// press: tracking then begins with the knob already under the pointer, so it neither jumps nor
/// glides, and dragging carries on from there. Pressing the knob itself still drags it from where
/// it is. SwiftUI's `Slider` is an `NSSlider`, so this covers every slider in the app.
enum SliderSnap {
    static func install() { _ = installed }

    private static let installed: Void = {
        let selector = #selector(NSSliderCell.startTracking(at:in:))
        guard let method = class_getInstanceMethod(NSSliderCell.self, selector) else { return }
        typealias Original = @convention(c) (NSSliderCell, Selector, NSPoint, NSView) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (NSSliderCell, NSPoint, NSView) -> Bool = { cell, point, view in
            cell.snapValue(to: point, in: view)
            return original(cell, selector, point, view)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }()
}

private extension NSSliderCell {
    /// When a press lands on the track rather than the knob, sets the value whose knob is centered
    /// on the press (the same place the slider's own jump would put it).
    func snapValue(to point: NSPoint, in view: NSView) {
        guard sliderType == .linear, !isVertical, isEnabled, maxValue > minValue else { return }
        let knob = knobRect(flipped: view.isFlipped)
        guard !knob.contains(point) else { return }
        let track = trackRect.isEmpty ? view.bounds : trackRect
        let travel = track.width - knob.width
        guard travel > 0 else { return }
        var fraction = min(1, max(0, (point.x - track.minX - knob.width / 2) / travel))
        if userInterfaceLayoutDirection == .rightToLeft { fraction = 1 - fraction }
        var value = minValue + Double(fraction) * (maxValue - minValue)
        if allowsTickMarkValuesOnly, numberOfTickMarks > 0 { value = closestTickMarkValue(toValue: value) }
        if let control = view as? NSControl { control.doubleValue = value } else { doubleValue = value }
    }
}
