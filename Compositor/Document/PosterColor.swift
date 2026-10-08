import AppKit

nonisolated enum HalftoneDot: String, Codable, CaseIterable, Sendable { case circle = "Round", square = "Square", line = "Line" }
nonisolated struct ColorHalftoneSettings: Codable, Equatable, Sendable {
    var size: Double = 10
    var cyan: Double = 15
    var magenta: Double = 75
    var yellow: Double = 0
    var black: Double = 45
    var shape: HalftoneDot = .circle
    var strength: Double = 100
    var isValid: Bool {
        size.isFinite && (2...128).contains(size) && strength.isFinite && (0...100).contains(strength)
        && [cyan, magenta, yellow, black].allSatisfy { $0.isFinite && (-180...180).contains($0) }
    }
    func apply(_ image: CGImage, scale: CGFloat) throws -> CGImage {
        guard ImageAdjustmentPixels.clamp(strength, 0...100, 100) > 0 else { return image }
        let source = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: source)
        guard let input = source.data else { throw ExportError.render }
        let angles = [cyan, magenta, yellow, black].map { ImageAdjustmentPixels.clamp($0, -180...180, 0) }
        return try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
            angles.withUnsafeBufferPointer {
                poster_halftone(pixels, input.assumingMemoryBound(to: UInt8.self), Int32(width), Int32(height), Int32(stride),
                    max(1, ImageAdjustmentPixels.clamp(size, 2...128, 10) * scale), $0.baseAddress,
                    shape == .circle ? 0 : shape == .square ? 1 : 2, ImageAdjustmentPixels.clamp(strength, 0...100, 100) / 100)
            }
        }
    }
}

nonisolated struct ChannelMixerSettings: Codable, Equatable, Sendable {
    var coefficients: [Double] = [100, 0, 0, 0, 0, 100, 0, 0, 0, 0, 100, 0]
    func apply(_ image: CGImage) throws -> CGImage {
        guard coefficients.count == 12, coefficients.allSatisfy({ $0.isFinite && (-200...200).contains($0) }) else { throw ProjectError.invalid }
        guard coefficients != ChannelMixerSettings().coefficients else { return image }
        return try PosterColorPixels.map(image) { r, g, b in
            func channel(_ i: Int) -> Double { (coefficients[i] * r + coefficients[i+1] * g + coefficients[i+2] * b + coefficients[i+3]) / 100 }
            return (channel(0), channel(4), channel(8))
        }
    }
}

nonisolated enum SelectiveRange: String, Codable, CaseIterable, Sendable {
    case reds = "Reds", yellows = "Yellows", greens = "Greens", cyans = "Cyans", blues = "Blues", magentas = "Magentas"
    case whites = "Whites", neutrals = "Neutrals", blacks = "Blacks"
}
nonisolated struct SelectiveColorSettings: Equatable, Sendable {
    var range: SelectiveRange = .reds
    // All nine ranges survive switching the picker. The range is only the inspected band.
    var adjustments: [SelectiveRange: [Double]] = [:]
    var cyan: Double { get { adjustments[range]?[0] ?? 0 } set { set(0, newValue) } }
    var magenta: Double { get { adjustments[range]?[1] ?? 0 } set { set(1, newValue) } }
    var yellow: Double { get { adjustments[range]?[2] ?? 0 } set { set(2, newValue) } }
    var black: Double { get { adjustments[range]?[3] ?? 0 } set { set(3, newValue) } }
    var relative = true
    private mutating func set(_ index: Int, _ value: Double) {
        var values = adjustments[range] ?? [0, 0, 0, 0]; values[index] = value; adjustments[range] = values
    }
    func apply(_ image: CGImage) throws -> CGImage {
        guard adjustments.values.allSatisfy({ $0.count == 4 && $0.allSatisfy { $0.isFinite && (-100...100).contains($0) } }) else { throw ProjectError.invalid }
        let bands = SelectiveRange.allCases.compactMap { band -> (SelectiveRange, [Double])? in
            guard let values = adjustments[band], values.contains(where: { $0 != 0 }) else { return nil }
            return (band, values.map { $0 / 100 })
        }
        guard !bands.isEmpty else { return image }
        return try PosterColorPixels.map(image) { r, g, b in
            let high = max(r, g, b), low = min(r, g, b), light = (high + low) / 2
            var red = r, green = g, blue = b
            for (range, values) in bands {
                let weight: Double = switch range {
                case .reds: max(0, r - max(g, b))
                case .greens: max(0, g - max(r, b))
                case .blues: max(0, b - max(r, g))
                case .cyans: max(0, min(g, b) - r)
                case .magentas: max(0, min(r, b) - g)
                case .yellows: max(0, min(r, g) - b)
                case .whites: max(0, (light - 0.5) * 2)
                case .blacks: max(0, (0.5 - light) * 2)
                case .neutrals: max(0, 1 - abs(light - 0.5) * 2) * (1 - high + low)
                }
                func delta(_ component: Double, _ index: Int) -> Double {
                    weight * (values[index] * (relative ? 1 - component : 1) + values[3] * (relative ? component : 1))
                }
                red -= delta(r, 0); green -= delta(g, 1); blue -= delta(b, 2)
            }
            return (red, green, blue)
        }
    }
}

nonisolated enum PosterColorPixels {
    static func map(_ image: CGImage, body: (Double, Double, Double) -> (Double, Double, Double)) throws -> CGImage {
        try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
            for y in 0..<height { for x in 0..<width {
                let p = pixels + y * stride + x * 4
                let alpha = Double(p[3]); guard alpha > 0 else { continue }
                let result = body(Double(p[0]) / alpha, Double(p[1]) / alpha, Double(p[2]) / alpha)
                func byte(_ value: Double) -> UInt8 { UInt8(max(0, min(255, (max(0, min(1, value)) * alpha).rounded()))) }
                p[0] = byte(result.0); p[1] = byte(result.1); p[2] = byte(result.2)
            } }
        }
    }
}
