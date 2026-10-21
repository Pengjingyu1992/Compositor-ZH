import SwiftUI
import UniformTypeIdentifiers

/// Resolve in pasteboard order; the importer validates contents rather than trusting extensions.
@MainActor
enum ImageFileDrop {
    static func importProviders(_ providers: [NSItemProvider], into session: EditorSession, at point: CGPoint?, projects: ProjectController? = nil, workspace: ProjectWorkspace? = nil, destination: UUID? = nil) async {
        var urls: [URL] = []
        var temporaryFolders: [URL] = []
        defer { for folder in temporaryFolders { try? FileManager.default.removeItem(at: folder) } }
        var unreadable = false
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let value = item as? URL { url = value }
                    else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else { url = nil }
                    continuation.resume(returning: url?.isFileURL == true ? url : nil)
                }
            }
            var resolved = url
            // Not a file on disk: a screenshot's thumbnail, or an image dragged from a web page or another app,
            // hands over image data (or a file it only promises). Copy it somewhere the importer can read.
            if resolved == nil, let copy = await temporaryFile(from: provider) {
                resolved = copy
                temporaryFolders.append(copy.deletingLastPathComponent())
            }
            if let file = resolved {
                // A sandbox grant for image.png need not cover its neighbouring JSON file.
                if let placement = await placementData(from: provider) {
                    do {
                        let copy = try localTransfer(file, placement: placement)
                        urls.append(copy); temporaryFolders.append(copy.deletingLastPathComponent())
                    } catch {
                        // A raw file URL from another app may carry no sandbox grant. Its PNG
                        // data representation remains readable through the drag pasteboard.
                        if let bitmap = await temporaryFile(from: provider) {
                            temporaryFolders.append(bitmap.deletingLastPathComponent())
                            if let copy = try? localTransfer(bitmap, placement: placement) {
                                urls.append(copy); temporaryFolders.append(copy.deletingLastPathComponent())
                            } else { unreadable = true }
                        } else { unreadable = true }
                    }
                } else { urls.append(file) }
            } else { unreadable = true }
        }
        if let workspace { await workspace.receive(urls, into: destination, at: point) }
        else if let projects { await projects.receive(urls, at: point) }
        else { await session.importImages(urls, at: point) }
        if unreadable, !providers.isEmpty {
            let message = L10n.text("Some dropped items couldn’t be read. Drag supported image, GIF, EPS, or Photoshop files from Finder.")
            session.importError = [session.importError, message].compactMap { $0 }.joined(separator: "\n\n")
        }
    }

    private static func placementData(from provider: NSItemProvider) async -> Data? {
        let type = ImageTransferPlacement.typeIdentifier
        guard provider.registeredTypeIdentifiers.contains(type) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                guard let data, data.count <= 4096,
                      let placement = try? JSONDecoder().decode(ImageTransferPlacement.self, from: data), placement.isValid else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: data)
            }
        }
    }

    private static func localTransfer(_ file: URL, placement: Data) throws -> URL {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...(512 * 1024 * 1024)).contains(size) else { throw ImageImportError.tooLarge }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(ImageTransferPlacement.folderPrefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let copy = folder.appendingPathComponent("image.png")
            try fm.copyItem(at: file, to: copy)
            try placement.write(to: folder.appendingPathComponent("transfer.json"), options: .atomic)
            return copy
        } catch { try? fm.removeItem(at: folder); throw error }
    }

    /// A dropped item's image written to a temporary file, or nil when it holds no image.
    private static func temporaryFile(from provider: NSItemProvider) async -> URL? {
        let types = [UTType.gif, .png, .jpeg, .heic, .tiff, .webP, .encapsulatedPostScript, .photoshopImage, .photoshopLargeImage, .rawImage, .image].map(\.identifier)
        guard let type = types.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else { return nil }
        let file: URL? = await withCheckedContinuation { continuation in
            // The file only exists until this closure returns, so it is copied, not referenced.
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let name = url.deletingPathExtension().lastPathComponent
                let suffix = url.pathExtension.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "png") : url.pathExtension
                // A unique folder rather than a unique file name: the copy keeps the name the file
                // was dropped under, which is the name the import sheet and the new layers show.
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                let copy = folder
                    .appendingPathComponent(name.isEmpty ? "Dropped" : name)
                    .appendingPathExtension(suffix)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch { continuation.resume(returning: nil) }
            }
        }
        if let file { return file }
        // Some apps offer only public.png data, without a file representation.
        guard type == UTType.png.identifier else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                guard let data, !data.isEmpty, data.count <= 512 * 1024 * 1024 else { continuation.resume(returning: nil); return }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let file = folder.appendingPathComponent("Dropped.png")
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                    try data.write(to: file, options: .atomic)
                    continuation.resume(returning: file)
                } catch { try? FileManager.default.removeItem(at: folder); continuation.resume(returning: nil) }
            }
        }
    }
}
