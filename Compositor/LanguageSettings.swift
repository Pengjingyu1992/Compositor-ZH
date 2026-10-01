import SwiftUI

nonisolated enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese
    case english

    var id: String { rawValue }
    var title: String { self == .simplifiedChinese ? "简体中文" : "English" }
    var localizationCode: String { self == .simplifiedChinese ? "zh-Hans" : "en" }

    init?(localizationCode: String) {
        guard let language = Self.allCases.first(where: { $0.localizationCode == localizationCode }) else { return nil }
        self = language
    }
}

@MainActor @Observable
final class LanguageSettings {
    private(set) var selectedLanguage: InterfaceLanguage
    let activeLanguage: InterfaceLanguage
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        activeLanguage = bundle.preferredLocalizations.first.flatMap(InterfaceLanguage.init(localizationCode:)) ?? .english
        selectedLanguage = defaults.stringArray(forKey: "AppleLanguages")?.first.flatMap(InterfaceLanguage.init(localizationCode:))
            ?? activeLanguage
    }

    func select(_ language: InterfaceLanguage) {
        guard language != selectedLanguage else { return }
        defaults.set([language.localizationCode], forKey: "AppleLanguages")
        selectedLanguage = language
    }
}
