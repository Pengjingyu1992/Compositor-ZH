import Foundation
import CoreGraphics

nonisolated enum PSDExportMode: String, CaseIterable, Sendable {
    case layered = "Layered PSD", flattened = "Flattened PSD"
}

nonisolated enum PSDExportError: LocalizedError {
    case requiresFlattening, tooLarge
    var errorDescription: String? {
        switch self {
        case .requiresFlattening: L10n.text("Adjustments, layer effects, or nonadjacent clipping links require a flattened PSD in this version.")
        case .tooLarge: L10n.text("PSD export exceeds the 512 MB, 10,000 record, or raster size limit. Try a flattened PSD or a smaller document.")
        }
    }
}

extension LayerBlendMode {
    nonisolated var psdKey: String {
        switch self {
        case .normal: "norm"
        case .darken: "dark"
        case .multiply: "mul "
        case .colorBurn: "idiv"
        case .linearBurn: "lbrn"
        case .lighten: "lite"
        case .screen: "scrn"
        case .colorDodge: "div "
        case .linearDodge: "lddg"
        case .overlay: "over"
        case .softLight: "sLit"
        case .hardLight: "hLit"
        case .vividLight: "vLit"
        case .linearLight: "lLit"
        case .pinLight: "pLit"
        case .hardMix: "hMix"
        case .difference: "diff"
        case .exclusion: "smud"
        case .subtract: "fsub"
        case .divide: "fdiv"
        case .hue: "hue "
        case .saturation: "sat "
        case .color: "colr"
        case .luminosity: "lum "
        }
    }
}

/// Original 8-bit RGB writer following Adobe's 2019 Photoshop File Formats specification.
/// Layer channels are raw, names are UTF-16, and folders use lsct section dividers.
nonisolated enum PSDWriter {
    static let maximumBytes = 512 * 1024 * 1024
    private struct Layer {
        let name: String
        var bounds = CGRect.zero
        var channels: [(id: Int16, data: Data)] = []
        var opacity: Double = 1
        var visible = true
        var blend = "norm"
        var clipping = false
        var section: UInt32?
        var maskBounds: CGRect?
        var maskDefault: UInt8 = 255
        var maskEnabled = true
    }
    static func requiresFlattening(_ snapshot: ProjectSnapshot) -> Bool {
        let layers = snapshot.manifest.layers
        if layers.contains(where: { $0.adjustment != nil || $0.effects?.visible.isEmpty == false }) { return true }
        for siblings in Dictionary(grouping: layers, by: \.parentID).values {
            var base: UUID?
            for layer in siblings {
                if let source = layer.maskSourceID {
                    if source != base { return true }
                } else { base = layer.isGroup == true ? nil : layer.id }
            }
        }
        return false
    }
    static func conversionNotes(_ snapshot: ProjectSnapshot) -> [String] {
        var notes: [String] = []
        if snapshot.manifest.layers.contains(where: { $0.text != nil || $0.shape != nil }) {
            notes.append("Text and shapes are exported as pixels. Their appearance is preserved, but they are no longer editable text or vector shapes in the PSD.")
        }
        if snapshot.manifest.layers.contains(where: { $0.maskLinked == false }) {
            notes.append("Independent masks retain their exported position. Mask linking may differ in other editors.")
        }
        if requiresFlattening(snapshot) {
            notes.append("Adjustments, layer effects, or nonadjacent clipping links require a flattened PSD in this version.")
        }
        return notes
    }
    private static func checkedBounds(_ transform: LayerTransform) throws -> CGRect {
        guard transform.isValid else { throw PSDExportError.tooLarge }
        let corners = DistortWarp.corners(of: transform)
        let left = corners.map(\.x).min()!.rounded(.down), top = corners.map(\.y).min()!.rounded(.down)
        let right = corners.map(\.x).max()!.rounded(.up), bottom = corners.map(\.y).max()!.rounded(.up)
        let bounds = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        guard bounds.width > 0, bounds.height > 0, bounds.width <= CGFloat(DocumentLimits.maxSide),
              bounds.height <= CGFloat(DocumentLimits.maxSide), bounds.width * bounds.height <= CGFloat(DocumentLimits.maxSurfacePixels)
        else { throw PSDExportError.tooLarge }
        return bounds
    }
    private static func context(_ bounds: CGRect, mask: Bool = false) throws -> CGContext {
        let c = try BrushRaster.context(width: Int(bounds.width), height: Int(bounds.height), mask: mask)
        c.translateBy(x: -bounds.minX, y: -bounds.minY)
        return c
    }
    private static func rgbaPlanes(_ c: CGContext) throws -> [Data] {
        guard let pixels = c.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
        var planes = (0..<4).map { _ in Data(count: c.width * c.height) }
        for channel in 0..<4 {
            planes[channel].withUnsafeMutableBytes { bytes in
                let into = bytes.bindMemory(to: UInt8.self)
                for y in 0..<c.height {
                    for x in 0..<c.width {
                        let from = pixels + y * c.bytesPerRow + x * 4
                        let a = Int(from[3])
                        into[y * c.width + x] = channel == 3 ? from[3]
                            : a == 0 ? 0 : UInt8(min(255, (Int(from[channel]) * 255 + a / 2) / a))
                    }
                }
            }
        }
        return planes
    }
    private static func raw(_ plane: Data) -> Data { var data = Data([0, 0]); data.append(plane); return data }
    private static func rasterLayer(_ record: ProjectLayerRecord, snapshot: ProjectSnapshot, remaining: inout Int) throws -> Layer {
        var layer = Layer(name: record.name, opacity: record.opacity ?? 1, visible: record.isVisible,
                          blend: record.isGroup == true ? "pass" : (record.blendMode ?? .normal).psdKey,
                          clipping: record.maskSourceID != nil)
        if record.isGroup == true { layer.section = 1 }
        else {
            let bounds = try checkedBounds(record.transform)
            let cost = Int(bounds.width * bounds.height) * 4 + 8
            guard cost <= remaining else { throw PSDExportError.tooLarge }
            remaining -= cost; layer.bounds = bounds
            let c = try context(bounds)
            if let image = snapshot.images[record.id]?.image {
                LayerRenderer.draw(image, transform: record.transform, center: record.transform.center, in: c)
            } else if record.imageFile != nil { throw ProjectError.missingImage }
            let planes = try rgbaPlanes(c)
            layer.channels = zip([Int16(0), 1, 2, -1], planes).map { ($0, raw($1)) }
        }
        if let mask = snapshot.mask(for: record) {
            // PSD rectangles are in document coordinates; transformed masks become upright pixel grids.
            let placement = record.isGroup == true ? record.transform : mask.placement ?? record.transform
            let bounds = try checkedBounds(placement)
            let cost = Int(bounds.width * bounds.height) + 2
            guard cost <= remaining else { throw PSDExportError.tooLarge }
            remaining -= cost
            let c = try context(bounds, mask: true)
            let background = LayerMask.background(of: mask.asset.thumbnail)
            c.setFillColor(gray: background, alpha: 1); c.fill(bounds)
            LayerRenderer.draw(mask.asset.image, transform: placement, center: placement.center, in: c)
            guard let pixels = c.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
            var plane = Data()
            plane.reserveCapacity(c.width * c.height)
            for y in 0..<c.height { plane.append(pixels + y * c.bytesPerRow, count: c.width) }
            layer.maskBounds = bounds; layer.maskEnabled = mask.isEnabled
            layer.maskDefault = UInt8((background * 255).rounded())
            layer.channels.append((-2, raw(plane)))
        } else if record.maskFile != nil { throw ProjectError.missingImage }
        return layer
    }
    static func encode(_ snapshot: ProjectSnapshot, composite: CGImage, mode: PSDExportMode) throws -> Data {
        try Task.checkCancellation()
        let manifest = snapshot.manifest
        guard composite.width == manifest.width, composite.height == manifest.height,
              manifest.width > 0, manifest.height > 0, manifest.width <= DocumentLimits.maxSide,
              manifest.height <= DocumentLimits.maxSide, manifest.width * manifest.height <= DocumentLimits.maxSurfacePixels
        else { throw PSDExportError.tooLarge }
        try LayerHierarchy.validate(manifest.layers)
        try LiveMaskGraph.validate(manifest.layers)
        if mode == .layered && requiresFlattening(snapshot) { throw PSDExportError.requiresFlattening }
        var remaining = maximumBytes - manifest.width * manifest.height * 4 - 1_024
        guard remaining > 0 else { throw PSDExportError.tooLarge }
        var layers: [Layer] = []
        if mode == .flattened || manifest.layers.isEmpty {
            var record = ProjectLayerRecord(id: UUID(), name: L10n.text("Composite"), isVisible: true,
                transform: LayerTransform(origin: .zero, size: CGSize(width: manifest.width, height: manifest.height)), imageFile: "composite")
            record.opacity = 1
            let asset = ImportedImage(image: composite, thumbnail: composite, name: record.name)
            let flat = ProjectSnapshot(manifest: manifest, images: [record.id: asset])
            layers = [try rasterLayer(record, snapshot: flat, remaining: &remaining)]
        } else {
            let children = Dictionary(grouping: manifest.layers, by: \.parentID)
            func visit(_ parent: UUID?) throws {
                for record in children[parent] ?? [] {
                    try Task.checkCancellation()
                    guard layers.count < 10_000 else { throw PSDExportError.tooLarge }
                    if record.isGroup == true {
                        layers.append(Layer(name: "</Layer group>", section: 3))
                        try visit(record.id)
                    }
                    layers.append(try autoreleasepool { try rasterLayer(record, snapshot: snapshot, remaining: &remaining) })
                }
            }
            try visit(nil)
        }
        guard !layers.isEmpty, layers.count <= 10_000 else { throw PSDExportError.tooLarge }
        var layerInfo = PSDBuffer()
        layerInfo.i16(-Int16(layers.count))
        for layer in layers {
            try layerInfo.record(layer)
            guard layerInfo.data.count < remaining else { throw PSDExportError.tooLarge }
        }
        for layer in layers { for channel in layer.channels { layerInfo.append(channel.data) } }
        layerInfo.pad(2)
        var section = PSDBuffer(); section.block(layerInfo.data); section.u32(0)
        var resources = PSDBuffer(), resolution = PSDBuffer()
        let dpi = UInt32((min(9600, max(1, manifest.resolution ?? 72)) * 65536).rounded())
        resolution.u32(dpi); resolution.u16(1); resolution.u16(1)
        resolution.u32(dpi); resolution.u16(1); resolution.u16(1)
        resources.ascii("8BIM"); resources.u16(1005); resources.u16(0); resources.block(resolution.data)
        if let profile = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() {
            let data = profile as Data
            resources.ascii("8BIM"); resources.u16(1039); resources.u16(0); resources.block(data)
            if data.count % 2 != 0 { resources.u8(0) }
        }
        var output = PSDBuffer()
        output.ascii("8BPS"); output.u16(1); output.append(Data(repeating: 0, count: 6)); output.u16(4)
        output.u32(UInt32(manifest.height)); output.u32(UInt32(manifest.width)); output.u16(8); output.u16(3)
        output.u32(0); output.block(resources.data); output.block(section.data)
        let c = try BrushRaster.context(width: composite.width, height: composite.height, mask: false)
        BrushRaster.draw(composite, in: CGRect(x: 0, y: 0, width: composite.width, height: composite.height), mask: false, context: c)
        output.u16(0)
        for plane in try rgbaPlanes(c) { output.append(plane) }
        guard output.data.count <= maximumBytes else { throw PSDExportError.tooLarge }
        try Task.checkCancellation()
        return output.data
    }

    private struct PSDBuffer {
        var data = Data()
        mutating func append(_ value: Data) { data.append(value) }
        mutating func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        mutating func u8(_ value: UInt8) { data.append(value) }
        mutating func u16(_ value: UInt16) { u8(UInt8(value >> 8)); u8(UInt8(value & 255)) }
        mutating func i16(_ value: Int16) { u16(UInt16(bitPattern: value)) }
        mutating func u32(_ value: UInt32) { u16(UInt16(value >> 16)); u16(UInt16(value & 65535)) }
        mutating func i32(_ value: Int) { u32(UInt32(bitPattern: Int32(value))) }
        mutating func pad(_ multiple: Int) { while data.count % multiple != 0 { u8(0) } }
        mutating func block(_ value: Data) { u32(UInt32(value.count)); append(value) }
        mutating func rectangle(_ r: CGRect) { i32(Int(r.minY)); i32(Int(r.minX)); i32(Int(r.maxY)); i32(Int(r.maxX)) }
        mutating func extra(_ key: String, _ value: Data) {
            ascii("8BIM"); ascii(key); block(value); if value.count % 2 != 0 { u8(0) }
        }
        mutating func record(_ layer: Layer) throws {
            rectangle(layer.bounds); u16(UInt16(layer.channels.count))
            for channel in layer.channels { i16(channel.id); u32(UInt32(channel.data.count)) }
            ascii("8BIM"); ascii(layer.blend)
            u8(UInt8((min(1, max(0, layer.opacity)) * 255).rounded()))
            u8(layer.clipping ? 1 : 0); u8(layer.visible ? 0 : 2); u8(0)
            var details = PSDBuffer()
            if let bounds = layer.maskBounds {
                var mask = PSDBuffer(); mask.rectangle(bounds); mask.u8(layer.maskDefault)
                mask.u8(layer.maskEnabled ? 0 : 2); mask.u16(0); details.block(mask.data)
            } else { details.u32(0) }
            details.u32(0)
            let legacy = Array(layer.name.data(using: .macOSRoman, allowLossyConversion: true)?.prefix(255) ?? Data())
            details.u8(UInt8(legacy.count)); details.append(Data(legacy)); details.pad(4)
            var unicode = PSDBuffer(); unicode.u32(UInt32(layer.name.utf16.count))
            for unit in layer.name.utf16 { unicode.u16(unit) }
            details.extra("luni", unicode.data)
            if let kind = layer.section {
                var folder = PSDBuffer(); folder.u32(kind); folder.ascii("8BIM"); folder.ascii(layer.blend)
                details.extra("lsct", folder.data)
            }
            block(details.data)
        }
    }
}

actor PSDExporter {
    static let shared = PSDExporter()
    func data(_ snapshot: ProjectSnapshot, mode: PSDExportMode) async throws -> Data {
        let composite = try await ImageExporter.shared.render(snapshot).image
        return try autoreleasepool { try PSDWriter.encode(snapshot, composite: composite, mode: mode) }
    }
    func export(_ snapshot: ProjectSnapshot, mode: PSDExportMode, to url: URL) async throws {
        let result = try await data(snapshot, mode: mode)
        try Task.checkCancellation()
        try await ImageExporter.shared.write(result, to: url)
    }
}
