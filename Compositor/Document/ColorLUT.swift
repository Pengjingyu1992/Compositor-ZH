import AppKit
import UniformTypeIdentifiers

nonisolated enum LUTSpace: String, CaseIterable, Sendable { case sRGB = "Encoded sRGB", linear = "Linear sRGB" }
nonisolated struct ColorLUTSettings: Equatable, Sendable {
    var table: ColorLUT?
    var strength: Double = 100
    var space: LUTSpace = .sRGB
    func apply(_ image: CGImage) throws -> CGImage {
        guard let table else { return image }
        let amount = ImageAdjustmentPixels.clamp(strength, 0...100, 100) / 100
        guard amount > 0 else { return image }
        return try PosterColorPixels.map(image) { r, g, b in
            let original = [r, g, b]
            func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            func encoded(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(max(0, v), 1 / 2.4) - 0.055 }
            let input = space == .linear ? original.map(linear) : original
            let result = table.sample(input)
            func channel(_ i: Int) -> Double { original[i] * (1 - amount) + (space == .linear ? encoded(result[i]) : result[i]) * amount }
            return (channel(0), channel(1), channel(2))
        }
    }
}

/// Adobe .cube ordering: red changes fastest, then green, then blue.
nonisolated struct ColorLUT: Equatable, Sendable {
    let name: String
    let size: Int
    let is1D: Bool
    let minimum: [Double]
    let maximum: [Double]
    let values: [[Double]]
    static func parse(_ data: Data, name: String) throws -> Self {
        guard data.count <= 16 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw ProjectError.invalid }
        var size: Int?, one = false, minimum = [0.0, 0, 0], maximum = [1.0, 1, 1], values: [[Double]] = []
        var headers = Set<String>()
        for source in text.split(whereSeparator: \.isNewline) {
            let line = source.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let words = line.split(whereSeparator: \.isWhitespace)
            guard let first = words.first else { continue }
            switch first {
            case "TITLE": guard values.isEmpty else { throw ProjectError.invalid }; continue
            case "LUT_1D_SIZE", "LUT_3D_SIZE":
                guard values.isEmpty, size == nil, words.count == 2, let count = Int(words[1]), (2...(first == "LUT_1D_SIZE" ? 65536 : 65)).contains(count) else { throw ProjectError.invalid }
                size = count; one = first == "LUT_1D_SIZE"
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard values.isEmpty, headers.insert(String(first)).inserted, words.count == 4 else { throw ProjectError.invalid }
                let numbers = words.dropFirst().compactMap { Double($0) }
                guard numbers.count == 3, numbers.allSatisfy({ $0.isFinite && abs($0) <= 16 }) else { throw ProjectError.invalid }
                if first == "DOMAIN_MIN" { minimum = numbers } else { maximum = numbers }
            default:
                guard let size, values.count < (one ? size : size * size * size) else { throw ProjectError.invalid }
                let numbers = words.compactMap { Double($0) }
                guard numbers.count == 3, words.count == 3, numbers.allSatisfy({ $0.isFinite && abs($0) <= 16 }) else { throw ProjectError.invalid }
                values.append(numbers)
            }
        }
        guard let size, values.count == (one ? size : size * size * size), zip(minimum, maximum).allSatisfy({ $0 < $1 }) else { throw ProjectError.invalid }
        return Self(name: name, size: size, is1D: one, minimum: minimum, maximum: maximum, values: values)
    }
    func sample(_ color: [Double]) -> [Double] {
        let p = (0..<3).map { min(Double(size - 1), max(0, (color[$0] - minimum[$0]) / (maximum[$0] - minimum[$0]) * Double(size - 1))) }
        let low = p.map { Int(floor($0)) }, high = low.map { min(size - 1, $0 + 1) }
        let weight = (0..<3).map { p[$0] - Double(low[$0]) }
        if is1D { return (0..<3).map { values[low[$0]][$0] * (1 - weight[$0]) + values[high[$0]][$0] * weight[$0] } }
        var result = [0.0, 0, 0]
        for z in 0...1 { for y in 0...1 { for x in 0...1 {
            let index = (x == 0 ? low[0] : high[0]) + size * ((y == 0 ? low[1] : high[1]) + size * (z == 0 ? low[2] : high[2]))
            let w = (x == 0 ? 1 - weight[0] : weight[0]) * (y == 0 ? 1 - weight[1] : weight[1]) * (z == 0 ? 1 - weight[2] : weight[2])
            for c in 0..<3 { result[c] += values[index][c] * w }
        } } }
        return result
    }
}

extension EditorSession {
    func importColorLUT() {
        guard let edit = filterEdit, edit.kind == .colorLUT else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .plainText]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { [weak self, weak edit] response in
            guard let self, let edit, self.filterEdit === edit else { return }
            defer { FloatingPanelController.refocus(NSUserInterfaceItemIdentifier("filterPanel")) }
            guard response == .OK, let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 16 * 1024 * 1024 else { throw ProjectError.tooLarge }
                let table = try ColorLUT.parse(Data(contentsOf: url), name: url.lastPathComponent)
                var settings = edit.settings; settings.colorLUT.table = table
                self.updateFilter(settings, preview: edit.preview)
            } catch { self.brushError = error.localizedDescription }
        }
    }
}
