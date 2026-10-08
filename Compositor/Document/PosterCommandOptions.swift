import AppKit

nonisolated struct PosterSelectiveColor: Codable, Sendable {
    var adjustments: [String: [Double]]
    var relative: Bool = true
    func settings() throws -> SelectiveColorSettings {
        var value = SelectiveColorSettings()
        value.relative = relative
        for (name, components) in adjustments {
            guard let range = SelectiveRange(rawValue: name), components.count == 4,
                  components.allSatisfy({ $0.isFinite && (-100...100).contains($0) }) else { throw PosterCommandError.invalid }
            value.adjustments[range] = components
        }
        return value
    }
}

nonisolated struct PosterLUT: Codable, Sendable {
    var cube: String
    var strength: Double = 100
    var space: LUTSpace = .sRGB
    func settings() throws -> ColorLUTSettings {
        guard strength.isFinite, (0...100).contains(strength) else { throw PosterCommandError.invalid }
        return ColorLUTSettings(table: try ColorLUT.parse(Data(cube.utf8), name: "Command.cube"), strength: strength, space: space)
    }
}

nonisolated struct PosterEdgeStroke: Codable, Sendable {
    var mode: String
    var diameter: Double
    var strength: Double
    /// Coordinates in the original layer's pixel grid, with y increasing downward.
    var points: [CGPoint]
}

nonisolated struct PosterEdgeOptions: Codable, Sendable {
    var selectSubject: Bool = false
    var feather: Double = 0
    var shift: Double = 0
    var contrast: Double = 0
    var decontaminate: Double = 0
    var createsCopy: Bool = true
    var strokes: [PosterEdgeStroke] = []
    var isValid: Bool {
        feather.isFinite && (0...100).contains(feather) && shift.isFinite && (-100...100).contains(shift)
        && contrast.isFinite && (0...100).contains(contrast) && decontaminate.isFinite && (0...100).contains(decontaminate)
        && strokes.count <= 1000 && strokes.reduce(0, { $0 + $1.points.count }) <= 100_000
        && strokes.allSatisfy { stroke in
            EdgeBrushMode(rawValue: stroke.mode) != nil && stroke.diameter.isFinite && (1...30000).contains(stroke.diameter)
            && stroke.strength.isFinite && (0...1).contains(stroke.strength) && !stroke.points.isEmpty
            && stroke.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 100_000 && abs($0.y) <= 100_000 }
        }
    }
}

extension EditorSession {
    func runPosterEdgeCommand(_ options: PosterEdgeOptions) async throws {
        guard options.isValid else { throw PosterCommandError.invalid }
        guard canRefineEdges else { throw PosterCommandError.locked }
        beginEdgeRefinement()
        guard let edit = edgeRefinement else { throw PosterCommandError.invalid }
        defer { if edgeRefinement === edit { cancelEdgeRefinement() } }
        if options.selectSubject {
            await detectRefinementSubject()
            if let error = brushError { throw PosterCommandError.failed(error) }
        }
        edit.feather = options.feather; edit.shift = options.shift; edit.contrast = options.contrast
        edit.decontaminate = options.decontaminate; edit.createsCopy = options.createsCopy
        for stroke in options.strokes {
            try Task.checkCancellation()
            edit.mode = EdgeBrushMode(rawValue: stroke.mode)!
            edit.diameter = stroke.diameter; edit.strength = stroke.strength
            edit.beginStroke()
            for point in stroke.points {
                edit.paint(at: CGPoint(x: point.x * CGFloat(edit.width) / CGFloat(edit.source.width),
                                       y: point.y * CGFloat(edit.height) / CGFloat(edit.source.height)))
            }
            edit.endStroke()
        }
        try Task.checkCancellation()
        await applyEdgeRefinement()
        guard edgeRefinement == nil else { throw PosterCommandError.failed(brushError ?? L10n.text("The edit command or its parameters are invalid.")) }
    }

    func setPosterMask(_ data: Data?, clear: Bool) async throws {
        guard canEditMask, let layer = activeLayer,
              let index = document?.layers.firstIndex(where: { $0.id == layer.id }) else { throw PosterCommandError.locked }
        if clear {
            guard data == nil else { throw PosterCommandError.invalid }
            document?.layers[index].mask = nil
            return
        }
        guard let data else { throw PosterCommandError.invalid }
        let budget = DocumentLimits.documentPixelBudget - sourcePixelCount
            + (layer.mask.map { $0.asset.image.width * $0.asset.image.height } ?? 0)
        let asset = try await ImageImporter.shared.decode(data, name: "Layer Mask", remainingPixels: budget)
        let context = try BrushRaster.context(width: asset.image.width, height: asset.image.height, mask: true)
        let rgba = try BrushRaster.copy(asset.image)
        guard let input = rgba.data?.assumingMemoryBound(to: UInt8.self),
              let output = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
        for y in 0..<asset.image.height { for x in 0..<asset.image.width {
            let p = input + y * rgba.bytesPerRow + x * 4
            // Premultiplied RGB makes transparent pixels hide even when their stored color is white.
            output[y * context.bytesPerRow + x] = UInt8((54 * Int(p[0]) + 183 * Int(p[1]) + 19 * Int(p[2]) + 128) >> 8)
        } }
        guard let image = context.makeImage() else { throw ExportError.render }
        document?.layers[index].mask = LayerMask(asset: try LayerMask.asset(from: image))
    }
}
