import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
import Testing
@testable import Compositor

@MainActor
struct ImageImportTests {
    func fixture(_ type: UTType, orientation: Int = 1, p3: Bool = false) throws -> URL {
        let colorSpace = CGColorSpace(name: p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
        let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
                                             bytesPerRow: 256, space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(type.preferredFilenameExtension ?? "image")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test(arguments: [UTType.png, .jpeg, .tiff, .heic])
    func supportedFormats(type: UTType) async throws {
        let url = try fixture(type)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await ImageImporter.shared.decode(url)
        #expect(result.image.width == 64)
        #expect(result.image.height == 32)
        #expect(result.image.colorSpace?.name == CGColorSpace.sRGB)
        #expect(result.thumbnail.width <= 96)
        #expect(result.thumbnail.height <= 96)
    }

    @Test func orientationAndColorConversion() async throws {
        let url = try fixture(.tiff, orientation: 6, p3: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await ImageImporter.shared.decode(url)
        #expect(result.image.width == 32)
        #expect(result.image.height == 64)
        #expect(result.image.colorSpace?.name == CGColorSpace.sRGB)
    }

    @Test func pngPreservesTransparency() async throws {
        let url = try fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await ImageImporter.shared.decode(url)
        let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
                                             bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(result.image, in: CGRect(x: 0, y: 0, width: 64, height: 32))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[3] == 255)
        #expect(bytes[0] >= 250)
        #expect(bytes[63 * 4 + 3] == 0)
    }

    @Test func limitsAndInvalidFiles() async throws {
        let url = try fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await ImageImporter.shared.decode(url, remainingPixels: 10)
            Issue.record("Over-budget image should fail")
        } catch ImageImportError.tooLarge { }
        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data("not an image".utf8).write(to: invalid)
        defer { try? FileManager.default.removeItem(at: invalid) }
        do {
            _ = try await ImageImporter.shared.decode(invalid)
            Issue.record("Invalid image should fail")
        } catch ImageImportError.unreadable { }
        let gif = try fixture(.gif)
        defer { try? FileManager.default.removeItem(at: gif) }
        do {
            _ = try await ImageImporter.shared.decode(gif)
            Issue.record("Unsupported image should fail")
        } catch ImageImportError.unsupported { }
    }

    @Test func importPlacementAndPartialFailure() async throws {
        let url = try fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url, url])
        #expect(session.document?.size == CGSize(width: 64, height: 32))
        #expect(session.document?.layers.count == 2)
        #expect(session.activeLayerID == session.document?.layers.last?.id)
        session.createDocument(width: 128, height: 128)
        await session.importImages([url, url.appendingPathExtension("missing")])
        #expect(session.document?.size == CGSize(width: 128, height: 128))
        #expect(session.document?.layers.count == 1)
        #expect(session.document?.layers.first?.origin == CGPoint(x: 32, y: 48))
        #expect(session.importError != nil)
        #expect(!session.isImporting)
    }

    @Test func dropPositionUsesDocumentCoordinates() async throws {
        let url = try fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        session.createDocument(width: 1000, height: 800)
        session.viewport.resize(to: CGSize(width: 700, height: 500), backingScale: 2, documentSize: session.document?.size)
        session.zoom(to: 2.5)
        session.viewport.translate(by: CGSize(width: 70, height: -35))
        let location = session.viewport.viewPoint(from: CGPoint(x: 300, y: 250), documentSize: session.document!.size)
        let dropPoint = session.viewport.documentPoint(from: location, documentSize: session.document!.size)
        await session.importImages([url], at: dropPoint)
        #expect(session.document?.layers.first?.origin == CGPoint(x: 268, y: 234))
        #expect(session.document?.size == CGSize(width: 1000, height: 800))
    }

    @Test func queuedImportsAreNotLost() async throws {
        let url = try fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        let first = Task { await session.importImages([url, url], at: CGPoint(x: 999, y: 999)) }
        let second = Task { await session.importImages([url]) }
        await first.value
        await second.value
        #expect(session.document?.layers.count == 3)
        #expect(session.document?.size == CGSize(width: 64, height: 32))
        #expect(session.document?.layers.first?.origin == .zero)
        #expect(!session.isImporting)
    }

    @Test func fileDropProvidersReachImporterInOrder() async throws {
        let first = try fixture(.png)
        let second = try fixture(.jpeg)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let session = EditorSession()
        let providers = [first, second].map { NSItemProvider(item: $0 as NSURL, typeIdentifier: UTType.fileURL.identifier) }
        await ImageFileDrop.importProviders(providers, into: session, at: nil)
        #expect(session.document?.layers.map(\.name) == [first, second].map { $0.deletingPathExtension().lastPathComponent })
        #expect(session.importError == nil)
    }
}
