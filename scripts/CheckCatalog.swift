import Foundation

@main struct CheckCatalog {
    static func main() throws {
        var checked = 0
        var failed: [String] = []
        for path in CommandLine.arguments.dropFirst() {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
            let strings = object["strings"] as! [String: [String: Any]]
            for (key, entry) in strings {
                guard let locales = entry["localizations"] as? [String: [String: Any]],
                      let unit = locales["zh-Hans"]?["stringUnit"] as? [String: String],
                      let value = unit["value"] else { failed.append("Missing Chinese translation: \(key)"); continue }
                checked += 1
                if !LocalizationFormatSignature.isCompatible(source: key, translation: value) {
                    failed.append("Incompatible format: \(key) -> \(value)")
                }
            }
        }
        for failure in failed.sorted() { print(failure) }
        print("Checked \(checked) translations, \(failed.count) failures.")
        if !failed.isEmpty { exit(1) }
    }
}
