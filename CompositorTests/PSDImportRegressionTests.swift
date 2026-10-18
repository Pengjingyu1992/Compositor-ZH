import AppKit
import ImageIO
import UniformTypeIdentifiers
#if !PSD_IMPORT_CLT_CHECKS
import Testing
@testable import Compositor
#endif

@MainActor enum PSDImportRegressionChecks {
    struct Result { var checks = 0; var failures: [String] = [] }
    private struct Fixture: Decodable {
        let name: String
        let depth: Int
        let planes: [String: [UInt8]]
    }

    static func run(fixtures: URL, output: URL, realFile: URL? = nil) async throws -> Result {
        var result = Result()
        func check(_ name: String, _ value: Bool) {
            result.checks += 1
            if !value { result.failures.append(name); print("FAIL: \(name)") }
        }
        func rejected(_ name: String, _ operation: () throws -> Void) {
            do { try operation(); check(name, false) } catch { check(name, true) }
        }
        let cases = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: fixtures.appendingPathComponent("expected.json")))
        for fixture in cases {
            let url = fixtures.appendingPathComponent(fixture.name)
            let bytes = try Data(contentsOf: url)
            let document = try PSDReader.read(bytes)
            check("\(fixture.name) dimensions and depth", document.width == 3 && document.height == 2 && document.sourceDepth == fixture.depth)
            check("\(fixture.name) layer retained", document.layers.count == 1 && document.layers.first?.name == "Fixture")
            guard let layer = document.layers.first, let image = layer.image, let mask = layer.mask else {
                check("\(fixture.name) channels present", false); continue
            }
            let rgba = Array(image.dataProvider!.data! as Data)
            let planes = fixture.planes
            let expected = (0..<6).flatMap { pixel -> [UInt8] in
                let a = planes["-1"]![pixel]
                return ["0", "1", "2"].map { UInt8((UInt16(planes[$0]![pixel]) * UInt16(a) + 127) / 255) } + [a]
            }
            check("\(fixture.name) RGB and alpha", rgba == expected)
            check("\(fixture.name) mask", Array(mask.dataProvider!.data! as Data) == planes["-2"]!)
            check("\(fixture.name) opacity", abs(layer.opacity - 191.0 / 255) < 0.00001)
            let imported = try PSDDocumentBuilder.makeImport(document)
            check("\(fixture.name) conversion notice", imported.conversions.count == (fixture.depth == 16 ? 1 : 0))
            for compression in 0..<4 {
                let channel = try Data(contentsOf: fixtures.appendingPathComponent("channel-\(fixture.depth)-\(compression).\(url.pathExtension).bin"))
                let cropped = try PSDChannelCoder.decode(compression: compression, width: 3, height: 2, data: channel,
                    largeDocument: url.pathExtension == "psb", crop: PSDCrop(x: 1, y: 1, width: 2, height: 1), depth: fixture.depth)
                check("\(fixture.name) crop \(compression)", cropped == Array(planes["0"]![4...5]))
            }
            rejected("\(fixture.name) truncated section") { _ = try PSDReader.read(Data(bytes.prefix(100))) }
        }
        let zip = try Data(contentsOf: fixtures.appendingPathComponent("channel-8-2.psd.bin"))
        rejected("truncated ZIP checksum") { _ = try PSDChannelCoder.decode(compression: 2, width: 3, height: 2, data: zip.dropLast()) }
        var corrupt = zip; corrupt[corrupt.count - 1] ^= 1
        rejected("corrupt ZIP checksum") { _ = try PSDChannelCoder.decode(compression: 2, width: 3, height: 2, data: corrupt) }
        rejected("trailing ZIP data") { _ = try PSDChannelCoder.decode(compression: 2, width: 3, height: 2, data: zip + Data([0])) }
        let excess = try Data(contentsOf: fixtures.appendingPathComponent("excess-zip.bin"))
        rejected("excess ZIP output") { _ = try PSDChannelCoder.decode(compression: 2, width: 3, height: 2, data: excess) }
        rejected("ZIP dimensions budget") { _ = try PSDChannelCoder.decode(compression: 2, width: 300_001, height: 1, data: zip) }
        rejected("invalid negative crop") { _ = try PSDChannelCoder.decode(compression: 2, width: 3, height: 2, data: zip, crop: PSDCrop(x: -1, y: 0, width: 1, height: 1)) }
        let fixture = fixtures.appendingPathComponent("rgb-16-3-global.psd")
        let session = EditorSession()
        var notices: [PSDConversion] = []
        session.confirmConversions = { items in notices = items; return false }
        let revision = session.history.currentRevision
        await session.importImages([fixture])
        check("decline conversion leaves empty canvas", session.document == nil && session.history.currentRevision == revision && !session.canUndo)
        check("decline conversion reports depth", notices.count == 1 && session.importError == nil)
        session.confirmConversions = { _ in true }
        await session.importImages([fixture])
        check("accept creates layered canvas", session.document?.layers.count == 1 && session.document?.size == CGSize(width: 3, height: 2) && session.importError == nil)
        check("import makes one undo step", session.canUndo)
        session.undo()
        check("undo restores empty canvas", session.document == nil && session.canRedo)
        let flattened = EditorSession()
        flattened.confirmConversions = { items in notices = items; return false }
        notices = []
        await flattened.importImages([fixtures.appendingPathComponent("layerless16.psd")])
        check("layerless 16-bit import also asks", notices.count == 1 && flattened.document == nil && flattened.importError == nil)
        flattened.confirmConversions = { _ in true }
        await flattened.importImages([fixtures.appendingPathComponent("layerless16.psd")])
        check("layerless import succeeds after approval", flattened.document?.layers.count == 1 && flattened.importError == nil)
        if let realFile {
            let original = try Data(contentsOf: realFile)
            let parsed = try PSDReader.read(original)
            check("reported PSD reads all four layers", parsed.sourceDepth == 16 && parsed.layers.count == 4)
            let actual = EditorSession()
            actual.confirmConversions = { _ in true }
            await actual.importImages([realFile])
            check("reported PSD imports successfully", actual.importError == nil && actual.document?.layers.count == parsed.layers.count)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for (index, layer) in parsed.layers.enumerated() {
                if let image = layer.image {
                    let file = output.appendingPathComponent("decoded-layer-\(index).png")
                    let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
                    CGImageDestinationAddImage(destination, image, nil)
                    check("reported PSD layer \(index) exported", CGImageDestinationFinalize(destination))
                }
            }
            try await ImageExporter.shared.exportPNG(actual.projectSnapshot()!, to: output.appendingPathComponent("imported.png"))
            check("reported PSD original unchanged", try Data(contentsOf: realFile) == original)
            print("Reported PSD: \(parsed.width) × \(parsed.height), \(parsed.layers.count) layers, import and PNG export completed")
        }
        return result
    }
}

#if !PSD_IMPORT_CLT_CHECKS
struct PSDImportRegressionTests {
    @Test func sixteenBitRawEndpoints() throws {
        // This raw test fixes the conversion endpoints independently of ZIP or fixture generation.
        let data = Data([0, 0, 0x80, 0, 0xff, 0xff])
        #expect(try PSDChannelCoder.decode(compression: 0, width: 3, height: 1, data: data, depth: 16) == [0, 128, 255])
    }
}
#endif
