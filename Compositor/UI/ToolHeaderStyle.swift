import SwiftUI

/// A single compact row shared by the tool headers.
struct ToolControlsRow<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content
    var body: some View { HStack(spacing: spacing) { content() } }
}

/// Keep control groups intact and reachable when a window is narrower than the row.
struct ToolControlsScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView(.horizontal) {
            content().fixedSize(horizontal: true, vertical: false).padding(.vertical, 4)
        }.scrollIndicators(.automatic)
    }
}

private struct ToolHeaderBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.font(ToolHeaderStyle.controlFont).controlSize(.small)
            .frame(height: ToolHeaderStyle.height)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Shared metrics keep tool switching from changing typography or canvas layout.
enum ToolHeaderStyle {
    static let height = EditorTheme.Metrics.toolHeaderHeight
    static let titleFont = EditorTheme.Typography.toolTitle
    static let controlFont = EditorTheme.Typography.toolControl
}

/// Numeric controls share a readable height, alignment, and keyboard-focus outline.
struct ToolNumberFieldStyle: TextFieldStyle {
    var height: CGFloat = 26
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).multilineTextAlignment(.trailing).monospacedDigit()
            .focused($focused).padding(.horizontal, 6).frame(height: height)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focused ? Color.accentColor : .primary.opacity(0.12))
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.5)
    }
}

struct ToolChoiceStyle: ButtonStyle {
    var selected = false
    var height: CGFloat = 26
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minHeight: height)
            .background(selected ? Color.accentColor.opacity(0.20) : .primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.075 : 0.035),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.75) : .primary.opacity(0.12))
            }
            .contentShape(RoundedRectangle(cornerRadius: 6)).opacity(isEnabled ? 1 : 0.5)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Keeps a unit ("%", "px") tight against its field so the two read as one value,
    /// regardless of the wider spacing between controls in a bar.
    func unitSuffix(_ unit: String) -> some View {
        HStack(spacing: 2) {
            self
            Text(unit)
        }
    }

    /// Lets a field without a separate label use its unit as the drag target.
    func unitSuffix<Value: BinaryFloatingPoint>(_ unit: String, scrubValue: Binding<Value>,
                                                sensitivity: Value, range: ClosedRange<Value>, step: Value? = nil) -> some View {
        HStack(spacing: 2) {
            self
            Text(unit).scrubbable(sensitivity: sensitivity, value: scrubValue, range: range, step: step)
        }
    }

    func unitSuffix(_ unit: String, scrubValue: Binding<Int>, sensitivity: Double,
                    range: ClosedRange<Int>) -> some View {
        HStack(spacing: 2) {
            self
            Text(unit).scrubbable(sensitivity: sensitivity, value: scrubValue, range: range)
        }
    }

    func toolHeaderBar() -> some View {
        modifier(ToolHeaderBarModifier())
    }
}
