import SwiftUI
import AppKit

/// Neutral chrome adapts without changing document pixels or proof colors.
@MainActor enum EditorTheme {
    static func adaptive(dark: CGFloat, light: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, alpha: 1)
        })
    }
    static let workspaceBackground = Color(nsColor: .underPageBackgroundColor)
    static let optionsBackground = Color(nsColor: .windowBackgroundColor)
    static let navigatorBackground = Color(nsColor: .controlBackgroundColor)
    static let previewBackground = Color(nsColor: .underPageBackgroundColor)
    static let selectedToolFill = Color.accentColor
    static let selectedToolBorder = Color.accentColor
    enum Metrics {
        static let toolHeaderHeight: CGFloat = 40
        static let toolRailWidth: CGFloat = 52
        static let toolButtonSize: CGFloat = 32
    }
    enum Typography {
        static let toolTitle = Font.system(size: 11, weight: .semibold)
        static let toolControl = Font.system(size: 11)
    }
}

nonisolated enum InterfaceAppearance: String, CaseIterable {
    case system, light, dark
    var scheme: ColorScheme? { self == .system ? nil : self == .dark ? .dark : .light }
}

/// AppKit panels inherit this setting too, including windows created after it changes.
@MainActor enum ApplicationAppearance {
    static func apply(_ preference: String = UserDefaults.standard.string(forKey: "interface.appearance") ?? "system") {
        switch InterfaceAppearance(rawValue: preference) ?? .system {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
