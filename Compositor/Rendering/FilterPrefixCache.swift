import CoreGraphics
import Foundation

/// Full-resolution prefixes. Equality includes coverage, saved fields, LUT values, pixel-grid parameters
/// and random seeds; keys never approximate noisy or screened effects with a smaller preview.
nonisolated final class FilterPrefixCache: @unchecked Sendable {
    static let shared = FilterPrefixCache()
    private struct Key: Hashable {
        let source: ObjectIdentifier
        let nodes: [UUID]
    }
    private struct Entry {
        let source: WeakRenderSource
        let nodes: [EditableFilterNode]
        let image: CGImage
    }
    private let cache: RenderCache
    init(cache: RenderCache = .shared) { self.cache = cache }
    func longestPrefix(source: ImportedImage, nodes: [EditableFilterNode]) -> (image: CGImage, count: Int)? {
        for count in stride(from: nodes.count, through: 0, by: -1) {
            let prefix = Array(nodes.prefix(count))
            let key = RenderCache.Key(.filter, Key(source: ObjectIdentifier(source.image), nodes: prefix.map(\.id)))
            if let entry = cache.value(for: key, as: Entry.self), entry.source.object === source.image, entry.nodes == prefix {
                return (entry.image, count)
            }
        }
        return nil
    }
    func store(_ image: CGImage, source: ImportedImage, nodes: [EditableFilterNode]) {
        let key = RenderCache.Key(.filter, Key(source: ObjectIdentifier(source.image), nodes: nodes.map(\.id)))
        cache.insert(Entry(source: WeakRenderSource(source.image), nodes: nodes, image: image), for: key,
            resources: [RenderResource.image(image)] + nodes.flatMap(\.resources))
    }
}
