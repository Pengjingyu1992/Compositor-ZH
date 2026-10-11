import Foundation
import CoreGraphics

actor GrayscaleConverter {
    static let shared = GrayscaleConverter()

    /// A separate flattened document keeps the source layers and their undo history intact.
    func copy(_ snapshot: ProjectSnapshot, name: String) async throws -> ProjectSnapshot {
        let source = try await ImageExporter.shared.render(snapshot).image
        try Task.checkCancellation()
        guard let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let context = CGContext(data: nil, width: source.width, height: source.height,
                  bitsPerComponent: 8, bytesPerRow: source.width * 2, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportError.render }
        // This context uses the native bitmap coordinates, unlike BrushRaster's flipped contexts.
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard let gray = context.makeImage() else { throw ExportError.render }
        let asset = ImportedImage(image: gray, thumbnail: try PixelAdjust.thumbnail(of: gray), name: name)
        let layerID = UUID()
        let record = ProjectLayerRecord(id: layerID, name: name, isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: source.width, height: source.height)),
            imageFile: "\(layerID.uuidString).png")
        return ProjectSnapshot(manifest: ProjectManifest(version: 13, resolution: snapshot.manifest.resolution,
            documentID: UUID(), width: source.width, height: source.height, activeLayerID: layerID,
            layers: [record]), images: [layerID: asset])
    }
}
