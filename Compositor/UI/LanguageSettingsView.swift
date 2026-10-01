import SwiftUI

struct LanguageSettingsView: View {
    var settings: LanguageSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Language").font(.title3.weight(.semibold))
            Picker("Interface Language", selection: Binding(get: { settings.selectedLanguage },
                                                            set: { settings.select($0) })) {
                ForEach(InterfaceLanguage.allCases) { language in
                    Text(verbatim: language.title).tag(language)
                }
            }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("interfaceLanguage")
            Text("Changes take effect after reopening the app. Save your work before quitting.")
                .font(.caption).foregroundStyle(.secondary)
            if settings.selectedLanguage != settings.activeLanguage {
                Label("Language preference saved.", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
            .padding(24).frame(width: 380, alignment: .leading)
    }
}
