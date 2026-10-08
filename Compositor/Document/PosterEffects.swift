import AppKit

nonisolated struct FillOverlayEffect: Codable, Equatable, Sendable {
    var enabled: Bool? = nil
    var isEnabled: Bool { enabled ?? true }
    var fill = LayerFillStyle(kind: .linear)
    var opacity: Double = 1
    var isValid: Bool { fill.isValid && opacity.isFinite && (0...1).contains(opacity) }
    var color: PaletteColor { PaletteColor(red: fill.stops[0].color.red, green: fill.stops[0].color.green, blue: fill.stops[0].color.blue) }
}

nonisolated struct BevelEffect: Codable, Equatable, Sendable {
    var enabled: Bool? = nil
    var isEnabled: Bool { enabled ?? true }
    var size: CGFloat = 8
    var depth: Double = 0.75
    var angle: CGFloat = 120
    var isValid: Bool { size.isFinite && (0...500).contains(size) && depth.isFinite && (0...1).contains(depth) && angle.isFinite && (-180...180).contains(angle) }
}

extension LayerEffects {
    nonisolated var usesPosterEffects: Bool { gradientOverlay != nil || patternOverlay != nil || bevel != nil }
}

extension LayerEffectsRenderer {
    nonisolated static func drawPosterEffects(_ effects: LayerEffects, shown: CGImage, placed: CGRect,
                                              full: CGRect, context: CGContext) throws {
        for effect in [effects.gradientOverlay, effects.patternOverlay].compactMap({ $0 }) where effect.isEnabled && effect.opacity > 0 {
            let image = try effect.fill.render(width: shown.width, height: shown.height)
            context.saveGState()
            context.translateBy(x: placed.minX, y: placed.maxY); context.scaleBy(x: 1, y: -1)
            let rect = CGRect(x: 0, y: 0, width: shown.width, height: shown.height)
            context.clip(to: rect, mask: shown)
            context.setAlpha(effect.opacity); context.setBlendMode(.normal)
            context.draw(image, in: rect)
            context.restoreGState()
        }
        if let bevel = effects.bevel, bevel.isEnabled, bevel.size > 0, bevel.depth > 0 {
            for (angle, color) in [(bevel.angle, PaletteColor(red: 1, green: 1, blue: 1)),
                                   (bevel.angle - 180, PaletteColor(red: 0, green: 0, blue: 0))] {
                var edge = InnerShadowEffect()
                edge.angle = angle; edge.distance = bevel.size; edge.blur = bevel.size / 2
                let mask = try innerCoverage(shown, placed: placed, size: full.size, shadow: edge)
                fill(color, alpha: bevel.depth, coverage: mask, in: full, context: context)
            }
        }
    }
}
