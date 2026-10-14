import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ExportError: LocalizedError {
    case tooLarge, render, encode
    var errorDescription: String? {
        switch self {
        case .tooLarge: L10n.format("Image export supports canvases up to %lld megapixels and %@ pixels per side.", DocumentLimits.maxSurfaceMegapixels, DocumentLimits.maxSide.formatted())
        case .render: L10n.text("The canvas could not be rendered. Try a smaller canvas.")
        case .encode: L10n.text("The image could not be encoded.")
        }
    }
}

actor ImageExporter {
    static let shared = ImageExporter()

    func render(_ input: ProjectSnapshot) throws -> ExportRaster {
        try Task.checkCancellation()
        let snapshot = input.presentingAnimationFrame(input.displayedAnimationFrameID)
        let width = snapshot.manifest.width, height = snapshot.manifest.height
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
              width * height <= DocumentLimits.maxSurfacePixels else { throw ExportError.tooLarge }
        return try autoreleasepool {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ExportError.render
            }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            let records = Dictionary(uniqueKeysWithValues: snapshot.manifest.layers.map { ($0.id, $0) })
            for layer in snapshot.manifest.layers {
                try Task.checkCancellation()
                guard layer.imageFile == nil || snapshot.images[layer.id] != nil,
                      layer.maskFile == nil || snapshot.masks[layer.id] != nil else { throw ProjectError.missingImage }
            }
            try LiveMaskGraph.validate(snapshot.manifest.layers)
            let live = LiveMaskRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: height), source: { records[$0]?.maskSourceID }) { id, target in
                guard let layer = records[id], let image = snapshot.images[id]?.image else { return }
                let opacity = layer.effectiveOpacity(in: records)
                let mask = snapshot.mask(for: layer).flatMap { $0.clipImage(placement: $0.placement, over: layer.transform, width: image.width, height: image.height) }
                let effects = LayerEffectsRenderer.cached(image, mask: mask, effects: layer.effects)
                func drawLayer(_ mode: LayerBlendMode, _ into: CGContext) {
                    if let effects {
                        let grown = LayerEffectsRenderer.placed(layer.transform, image: effects.image, inset: effects.inset)
                        LayerRenderer.draw(effects.image, transform: grown, center: grown.center,
                            opacity: opacity, blendMode: mode, mask: nil, in: into)
                        return
                    }
                    LayerRenderer.draw(image, transform: layer.transform, center: layer.transform.center,
                        opacity: opacity, blendMode: mode, mask: mask, in: into)
                }
                let mode = layer.blendMode ?? .normal
                // Core Graphics blends these two wrong; see SeparableBlend.
                if SeparableBlend.needsSurface(mode), SeparableBlend.draw(mode, in: target, body: { drawLayer(.normal, $0) }) { return }
                drawLayer(mode, target)
            }
            live.adjustment = { records[$0]?.adjustment }
            live.adjustmentOpacity = { records[$0]?.effectiveOpacity(in: records) ?? 1 }
            live.adjustmentClip = { id, ctx in
                if let layer = records[id], let image = snapshot.mask(for: layer)?.enabledImage {
                    FolderMaskClip(image: image, transform: layer.transform).apply(center: layer.transform.center, in: ctx)
                }
            }
            live.prepareStacks(LayerHierarchy.visibleLayers(snapshot.manifest.layers).map(\.id), parent: { records[$0]?.parentID }, blend: { records[$0]?.blendMode ?? .normal })
            FolderMaskClip.draw(LayerHierarchy.visibleLayers(snapshot.manifest.layers).map(\.id), parent: { records[$0]?.parentID }, clip: { id in
                guard let folder = records[id], let image = snapshot.mask(for: folder)?.enabledImage else { return nil }
                let clip = FolderMaskClip(image: image, transform: folder.transform)
                return { clip.apply(center: folder.transform.center, in: $0) }
            }, in: context) { live.drawComposite($0, in: context) }
            try Task.checkCancellation()
            guard let image = context.makeImage() else { throw ExportError.render }
            return ExportRaster(image: image, resolution: snapshot.manifest.resolution ?? 72)
        }
    }

    /// The Space-bar preview, saved in the project's QuickLook folder: the flattened image on white, a JPEG up to
    /// 1,024 px on the long side, about 100–200 KB. Nil for canvases too large to flatten on every save.
    func quickLookImages(_ snapshot: ProjectSnapshot) -> QuickLookImages? {
        guard snapshot.manifest.width * snapshot.manifest.height <= 50_000_000,
              let raster = try? render(snapshot),
              let preview = try? scaledJPEG(raster.image, longSide: 1024) else { return nil }
        return QuickLookImages(preview: preview)
    }

    private func scaledJPEG(_ image: CGImage, longSide: CGFloat) throws -> Data {
        let scale = min(1, longSide / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded())), height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        return try autoreleasepool {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw ExportError.render }
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(bounds)
            context.interpolationQuality = .high
            context.draw(image, in: bounds)
            guard let flattened = context.makeImage() else { throw ExportError.render }
            return try encode(flattened, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        }
    }

    func pngData(_ snapshot: ProjectSnapshot) throws -> Data {
        try pngData(render(snapshot))
    }

    func pngData(_ raster: ExportRaster) throws -> Data {
        try encode(raster.image, type: .png, properties: [
            kCGImagePropertyDPIWidth: raster.resolution, kCGImagePropertyDPIHeight: raster.resolution
        ] as CFDictionary)
    }

    /// One representative frame, with the same resizing, alpha threshold and ImageIO palette as final output.
    func gifPreview(_ raster: ExportRaster, options: GIFExportOptions, frameID: UUID? = nil,
                    duration: Int = 100) throws -> GIFPreparedFrame {
        try Task.checkCancellation()
        let started = PerformanceRecorder.shared.begin()
        defer { PerformanceRecorder.shared.end(.gifPreview, since: started) }
        guard options.width > 0, options.height > 0,
              options.width <= DocumentLimits.maxSide, options.height <= DocumentLimits.maxSide,
              options.width * options.height <= AnimationTrack.maxFramePixels else { throw ImageImportError.gifTooLarge }
        let block = try gifBlock(raster, options: options, duration: duration)
        var data = GIFCodec.header(width: options.width, height: options.height, loops: -1)
        data.append(block); data.append(0x3b)
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let preview = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ExportError.encode }
        return GIFPreparedFrame(options: options, frameID: frameID, duration: duration, block: block, preview: preview)
    }

    private func gifBlock(_ raster: ExportRaster, options: GIFExportOptions, duration: Int) throws -> Data {
        try autoreleasepool {
            try Task.checkCancellation()
            let width = options.width, height = options.height
            let sized = try resized(raster, width: width, height: height)
            let image: CGImage
            if options.keepTransparency {
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                      let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
                context.draw(sized.image, in: CGRect(x: 0, y: 0, width: width, height: height))
                for y in 0..<height {
                    if y % 64 == 0 { try Task.checkCancellation() }
                    for x in 0..<width {
                        let at = (y * width + x) * 4, alpha = Int(pixels[at + 3])
                        for c in 0..<3 { pixels[at + c] = alpha < 128 ? 0 : UInt8(min(255, (Int(pixels[at + c]) * 255 + alpha / 2) / alpha)) }
                        pixels[at + 3] = alpha < 128 ? 0 : 255
                    }
                }
                guard let binary = context.makeImage() else { throw ExportError.render }; image = binary
            } else { image = try flattened(sized, over: options.background) }
            try Task.checkCancellation()
            let frame = try GIFCodec.encodedFrame(encode(image, type: .gif), width: width, height: height, duration: duration)
            try Task.checkCancellation()
            return frame
        }
    }

    func animationGIF(_ snapshot: ProjectSnapshot?, fallback: ExportRaster, width: Int, height: Int,
                      background: CGColor, keepTransparency: Bool, prepared: GIFPreparedFrame? = nil,
                      progress: (@Sendable (Int) -> Void)? = nil) throws -> JPEGResult {
        try Task.checkCancellation()
        let started = PerformanceRecorder.shared.begin()
        defer { PerformanceRecorder.shared.end(.gifEncode, since: started) }
        let track = snapshot?.manifest.animation
        let count = track?.frames.count ?? 1
        guard (1...AnimationTrack.maxFrames).contains(count), (-1...65535).contains(track?.loopCount ?? -1),
              width > 0, height > 0, width <= DocumentLimits.maxSide, height <= DocumentLimits.maxSide,
              width * height <= AnimationTrack.maxFramePixels, width * height * count <= AnimationTrack.maxPixels else { throw ImageImportError.gifTooLarge }
        let components = background.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [1, 1, 1, 1]
        let options = GIFExportOptions(width: width, height: height, red: components[0], green: components[1], blue: components[2], keepTransparency: keepTransparency)
        var output = GIFCodec.header(width: width, height: height, loops: track?.loopCount ?? -1)
        for index in 0..<count {
            try Task.checkCancellation()
            let frameID = track?.frames[index].groupID, duration = track?.frames[index].durationMS ?? 100
            let frame: Data
            if let prepared, prepared.options == options, prepared.frameID == frameID, prepared.duration == duration {
                frame = prepared.block
            } else {
                let rendered: ExportRaster
                if let snapshot, let track { rendered = try render(snapshot.presentingAnimationFrame(track.frames[index].groupID)) }
                else { rendered = fallback }
                frame = try gifBlock(rendered, options: options, duration: duration)
            }
            guard output.count + frame.count + 1 <= 64 * 1024 * 1024 else { throw ImageImportError.gifTooLarge }
            output.append(frame); progress?(index + 1)
        }
        output.append(0x3b)
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(output as CFData, nil), let preview = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ExportError.encode }
        return JPEGResult(data: output, preview: preview)
    }

    func epsData(_ raster: ExportRaster, background: CGColor) throws -> Data {
        try EPSCodec.checkSize(raster.image.width, raster.image.height, remainingPixels: EPSCodec.maxPixels)
        return try EPSCodec.encode(flattened(raster, over: background), resolution: raster.resolution)
    }

    /// The flattened canvas at another size, for Export As: resampled at high quality, keeping its resolution, so a
    /// smaller copy is a smaller print too.
    func resized(_ raster: ExportRaster, width: Int, height: Int) throws -> ExportRaster {
        guard width != raster.image.width || height != raster.image.height else { return raster }
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
              width * height <= DocumentLimits.maxSurfacePixels else { throw ExportError.tooLarge }
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportError.render }
            context.interpolationQuality = .high
            context.draw(raster.image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = context.makeImage() else { throw ExportError.render }
            return ExportRaster(image: image, resolution: raster.resolution)
        }
    }

    private func encode(_ image: CGImage, type: UTType, properties: CFDictionary? = nil) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ExportError.encode
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encode }
        return data as Data
    }

    func jpeg(_ raster: ExportRaster, options: JPEGOptions) throws -> JPEGResult {
        try Task.checkCancellation()
        return try autoreleasepool {
            let image = raster.image
            guard let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ExportError.render }
            context.setFillColor(CGColor(colorSpace: context.colorSpace!,
                components: [options.red, options.green, options.blue, 1])!)
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.fill(bounds)
            context.draw(image, in: bounds)
            guard let flattened = context.makeImage() else { throw ExportError.render }
            try Task.checkCancellation()
            let data = try encode(flattened, type: .jpeg,
                properties: [kCGImageDestinationLossyCompressionQuality: min(1, max(0, options.quality)),
                             kCGImagePropertyDPIWidth: raster.resolution,
                             kCGImagePropertyDPIHeight: raster.resolution] as CFDictionary)
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    // Full size, so the dialog's 100% view shows the real artifacts; capped to keep memory in bounds.
                    kCGImageSourceThumbnailMaxPixelSize: min(max(image.width, image.height), 8192),
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { throw ExportError.encode }
            return JPEGResult(data: data, preview: preview)
        }
    }

    /// The picture over a solid color, as a page with that background shows it.
    func flattened(_ raster: ExportRaster, over background: CGColor) throws -> CGImage {
        let image = raster.image
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ExportError.render }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(background)
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let flattened = context.makeImage() else { throw ExportError.render }
        return flattened
    }

    /// The same profile and intent as the canvas proof, embedded in a lossless four-channel TIFF.
    func cmykTIFF(_ raster: ExportRaster, settings: PrintSettings) throws -> JPEGResult {
        guard let profile = settings.profile else { throw CMYKError.profile }
        try Task.checkCancellation()
        return try autoreleasepool {
            let conversion = try CMYKConversion(profile: profile, intent: settings.intent)
            let image = try conversion.image(raster.image, background: settings.background)
            try Task.checkCancellation()
            let data = try encode(image, type: .tiff, properties: [
                kCGImagePropertyDPIWidth: raster.resolution, kCGImagePropertyDPIHeight: raster.resolution,
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]
            ] as CFDictionary)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let preview = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  preview.colorSpace?.model == .cmyk else { throw ExportError.encode }
            return JPEGResult(data: data, preview: try conversion.preview(preview))
        }
    }

    func exportPNG(_ snapshot: ProjectSnapshot, to url: URL) throws {
        let data = try pngData(snapshot)
        try write(data, to: url)
    }

    /// One page the document's printed size (its pixels at its resolution), holding the flattened canvas at full
    /// resolution. Core Graphics keeps the pixels lossless, and transparency stays transparent, as in a PNG.
    func pdfData(_ snapshot: ProjectSnapshot) throws -> Data {
        try pdfData(render(snapshot))
    }

    /// `background` fills the page under the picture; nil leaves it clear, as a viewer then shows its own paper.
    func pdfData(_ raster: ExportRaster, background: CGColor? = nil) throws -> Data {
        let pointsPerPixel = 72 / (raster.resolution > 0 ? raster.resolution : 72)
        var page = CGRect(x: 0, y: 0, width: CGFloat(raster.image.width) * pointsPerPixel,
                          height: CGFloat(raster.image.height) * pointsPerPixel)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { throw ExportError.encode }
        context.beginPDFPage(nil)
        if let background {
            context.setFillColor(background)
            context.fill(page)
        }
        context.draw(raster.image, in: page)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    func exportPDF(_ snapshot: ProjectSnapshot, to url: URL) throws {
        let data = try pdfData(snapshot)
        try write(data, to: url)
    }

    func write(_ data: Data, to url: URL, mustNotExist: Bool = false) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                if mustNotExist, FileManager.default.fileExists(atPath: target.path) { throw CocoaError(.fileWriteFileExists) }
                try data.write(to: target, options: .atomic)
            }
            catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }
}

nonisolated struct QuickLookImages: Sendable {
    let preview: Data
}
nonisolated struct ExportRaster: @unchecked Sendable {
    let image: CGImage
    var resolution: Double = 72
}
nonisolated struct JPEGOptions: Equatable, Sendable {
    var quality: Double = 0.85
    var red: CGFloat = 1
    var green: CGFloat = 1
    var blue: CGFloat = 1
}
nonisolated struct JPEGResult: @unchecked Sendable {
    let data: Data
    let preview: CGImage
}
