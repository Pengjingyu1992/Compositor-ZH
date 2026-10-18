import SwiftUI

/// Semantic foundation. Values preserve the installed appearance in this batch.
@MainActor enum EditorTheme {
    static let workspaceBackground = Color(white: 0.14)
    static let navigatorBackground = Color(white: 0.11)
    static let previewBackground = Color(white: 0.12)
    static let selectedToolFill = Color.white.opacity(0.12)
    static let selectedToolBorder = Color.white.opacity(0.14)

    enum Metrics {
        static let toolHeaderHeight: CGFloat = 42
        static let toolRailWidth: CGFloat = 56
        static let toolButtonSize: CGFloat = 36
    }

    enum Typography {
        static let toolTitle = Font.system(size: 13, weight: .semibold)
        static let toolControl = Font.system(size: 12)
    }
}
