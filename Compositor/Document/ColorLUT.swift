import AppKit
import UniformTypeIdentifiers

nonisolated enum LUTSpace: String, Codable, CaseIterable, Sendable { case sRGB = "Encoded sRGB", linear = "Linear sRGB" }
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
        let last = Double(size - 1)
        var low = [Int](repeating: 0, count: 3)
        var high = low
        var weight = [Double](repeating: 0, count: 3)
        for c in 0..<3 {
            let span: Double = maximum[c] - minimum[c]
            let position: Double = (color[c] - minimum[c]) / span * last
            let bounded: Double = min(last, max(0, position))
            low[c] = Int(floor(bounded)); high[c] = min(size - 1, low[c] + 1)
            weight[c] = bounded - Double(low[c])
        }
        var result = [Double](repeating: 0, count: 3)
        if is1D {
            for c in 0..<3 {
                let lower: Double = values[low[c]][c] * (1 - weight[c])
                let upper: Double = values[high[c]][c] * weight[c]
                result[c] = lower + upper
            }
            return result
        }
        for z in 0...1 { for y in 0...1 { for x in 0...1 {
            let ix = x == 0 ? low[0] : high[0], iy = y == 0 ? low[1] : high[1], iz = z == 0 ? low[2] : high[2]
            let index = ix + size * (iy + size * iz)
            let wx: Double = x == 0 ? 1 - weight[0] : weight[0]
            let wy: Double = y == 0 ? 1 - weight[1] : weight[1]
            let wz: Double = z == 0 ? 1 - weight[2] : weight[2]
            let w: Double = wx * wy * wz
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
