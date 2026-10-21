import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Shared with Kaleiform. The PNG is self-contained; this small sidecar only describes placement.
nonisolated struct ImageTransferPlacement: Codable, Sendable {
    static let folderPrefix = "Kaleiform-Compositor-Transfer-"
    static let typeIdentifier = "org.kaleiform-compositor.image-placement"
    var version = 1
    var width: Double
    var height: Double
    var rotation: Double = 0
    var flipX = false
    var flipY = false
    var name: String? = nil
    var isValid: Bool {
        version == 1 && [width, height, rotation].allSatisfy(\.isFinite)
            && (1...300_000).contains(width) && (1...300_000).contains(height) && abs(rotation) <= 360_000
    }
    static func read(beside url: URL) -> Self? {
        guard url.deletingLastPathComponent().lastPathComponent.hasPrefix(folderPrefix) else { return nil }
        let file = url.deletingLastPathComponent().appendingPathComponent("transfer.json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, (1...4096).contains(size),
              let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return nil }
        return value
    }
    func transform(center: CGPoint) -> LayerTransform {
        LayerTransform(origin: CGPoint(x: center.x - width / 2, y: center.y - height / 2),
            size: CGSize(width: width, height: height), rotation: rotation, flipX: flipX, flipY: flipY)
    }
}

struct ImageTransferPayload {
    let png: Data
    let placement: ImageTransferPlacement
    let name: String

    func write() throws -> URL {
        let fm = FileManager.default, root = fm.temporaryDirectory
        // A receiver may still be loading after the source drag ends. Keep transfers for a day.
        if let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for entry in entries where entry.lastPathComponent.hasPrefix(ImageTransferPlacement.folderPrefix) {
                if let date = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   date < Date().addingTimeInterval(-86400) { try? fm.removeItem(at: entry) }
            }
        }
        let folder = root.appendingPathComponent(ImageTransferPlacement.folderPrefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let file = folder.appendingPathComponent("image.png")
            try png.write(to: file, options: .atomic)
            var info = placement
            info.name = String(name.prefix(255))
            try JSONEncoder().encode(info).write(to: folder.appendingPathComponent("transfer.json"), options: .atomic)
            return file
        } catch { try? fm.removeItem(at: folder); throw error }
    }
}

enum ImageTransferDrag {
    static func begin(_ payload: ImageTransferPayload, from view: NSView, event: NSEvent, source: any NSDraggingSource) throws {
        let file = try payload.write()
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        item.setData(payload.png, forType: .png)
        var placement = payload.placement
        placement.name = String(payload.name.prefix(255))
        item.setData(try JSONEncoder().encode(placement), forType: NSPasteboard.PasteboardType(ImageTransferPlacement.typeIdentifier))
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let point = view.convert(event.locationInWindow, from: nil)
        dragging.setDraggingFrame(NSRect(origin: point, size: NSSize(width: 64, height: 64)), contents: NSImage(data: payload.png))
        view.beginDraggingSession(with: [dragging], event: event, source: source)
    }
}

extension EditorSession {
    var canDragImage: Bool { canEditLayers && activeLayer != nil && !isMaskSelected && transformEdit == nil }

    func imageTransfer() throws -> ImageTransferPayload {
        guard canDragImage, let active = activeLayer, let document, var snapshot = projectSnapshot() else { throw ExportError.render }
        let picked = selectedLayerIDs.union([active.id])
        let records = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0) })
        var visible = picked
        for id in picked { visible.formUnion(descendantIDs(of: id)) }
        var kept = visible
        var changed = true
        while changed {
            let before = kept
            for id in before {
                if let parent = records[id]?.parentID { kept.insert(parent) }
                if let source = records[id]?.maskSourceID { kept.insert(source) }
            }
            changed = kept != before
        }
        let ancestors = kept.subtracting(visible).compactMap { records[$0] }
        if visible.count == 1, let asset = active.asset, selection == nil,
           active.mask == nil, active.maskSourceID == nil, active.effects?.isEmpty != false,
           active.opacity == 1, active.blendMode == .normal,
           ancestors.allSatisfy({ $0.isGroup && $0.mask == nil && $0.maskSourceID == nil && $0.opacity == 1
               && $0.blendMode == .normal && $0.effects?.isEmpty != false }),
           let bytes = asset.originalPNG,
           let source = CGImageSourceCreateWithData(bytes as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           (props[kCGImagePropertyOrientation] as? Int ?? 1) == 1 {
            return ImageTransferPayload(png: bytes,
                placement: ImageTransferPlacement(width: active.size.width, height: active.size.height,
                    rotation: active.transform.rotation, flipX: active.transform.flipX, flipY: active.transform.flipY), name: active.name)
        }
        var bounds = CGRect.null
        var density = 1.0
        for layer in document.layers where visible.contains(layer.id) {
            guard let image = layer.asset?.image else { continue }
            let effects = LayerEffectsRenderer.cached(image, mask: nil, effects: layer.effects)
            let t = effects.map { LayerEffectsRenderer.placed(layer.transform, image: $0.image, inset: $0.inset) } ?? layer.transform
            for p in [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)] {
                let p = t.point(p)
                bounds = bounds.union(CGRect(x: p.x, y: p.y, width: 0, height: 0))
            }
            density = max(density, Double(image.width) / layer.size.width, Double(image.height) / layer.size.height)
        }
        if let selection { bounds = bounds.intersection(selection.coverageBounds) }
        bounds = bounds.integral
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0, density.isFinite else { throw ExportError.render }
        let w = ceil(bounds.width * density), h = ceil(bounds.height * density)
        guard w <= Double(DocumentLimits.maxSide), h <= Double(DocumentLimits.maxSide), w * h <= Double(DocumentLimits.maxSurfacePixels) else { throw ExportError.tooLarge }
        func move(_ t: LayerTransform) -> LayerTransform {
            var t = t
            t.origin = CGPoint(x: (t.origin.x - bounds.minX) * density, y: (t.origin.y - bounds.minY) * density)
            t.size = CGSize(width: t.size.width * density, height: t.size.height * density)
            return t
        }
        snapshot.manifest = ProjectManifest(documentID: document.id, width: Int(w), height: Int(h), activeLayerID: active.id,
            layers: snapshot.manifest.layers.filter { kept.contains($0.id) }.map { record in
                var r = record
                r.transform = move(r.transform)
                r.maskPlacement = r.maskPlacement.map(move)
                if picked.contains(r.id) || (!visible.contains(r.id) && r.isGroup == true) { r.isVisible = true }
                if !visible.contains(r.id), r.isGroup != true { r.isVisible = false }
                return r
            })
        var raster = try ImageExporter.renderTransfer(snapshot)
        if let clip = try selection?.clip(canvas: document.size) {
            let c = try BrushRaster.context(width: Int(w), height: Int(h), mask: false)
            c.scaleBy(x: density, y: density); c.translateBy(x: -bounds.minX, y: -bounds.minY)
            clip.apply(to: c)
            BrushRaster.draw(raster.image, in: bounds, mask: false, context: c)
            guard let image = c.makeImage() else { throw ExportError.render }
            raster = ExportRaster(image: image, resolution: 72)
        }
        return ImageTransferPayload(png: try ImageExporter.transferPNG(raster),
            placement: ImageTransferPlacement(width: bounds.width, height: bounds.height), name: active.name)
    }
}

/// Its own mouse-down starts AppKit's tracking loop, independent of canvas and layer gestures.
struct ImageDragHandle: NSViewRepresentable {
    let session: EditorSession
    func makeNSView(context: Context) -> ImageDragButton { ImageDragButton(session: session) }
    func updateNSView(_ view: ImageDragButton, context: Context) { view.session = session; view.isEnabled = session.canDragImage }
}

final class ImageDragButton: NSButton, NSDraggingSource {
    var session: EditorSession
    init(session: EditorSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: L10n.text("Drag image to another app"))
        imagePosition = .imageOnly
        isBordered = false
        toolTip = L10n.text("Drag image to another app")
        setAccessibilityIdentifier("dragImageToApp")
        setAccessibilityLabel(L10n.text("Drag image to another app"))
    }
    required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) {
        guard session.canDragImage else { return }
        do {
            try ImageTransferDrag.begin(session.imageTransfer(), from: self, event: event, source: self)
        } catch { session.importError = error.localizedDescription }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
