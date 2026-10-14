import SwiftUI

/// Shared metrics keep tool switching from changing typography or canvas layout.
enum ToolHeaderStyle {
    static let height: CGFloat = 42
    static let titleFont = Font.system(size: 13, weight: .semibold)
    static let controlFont = Font.system(size: 12)
}

/// Numeric controls share a readable height, alignment, and keyboard-focus outline.
struct ToolNumberFieldStyle: TextFieldStyle {
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).multilineTextAlignment(.trailing).monospacedDigit()
            .focused($focused).padding(.horizontal, 6).frame(height: 26)
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
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minHeight: 26)
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
        font(ToolHeaderStyle.controlFont)
            .controlSize(.regular)
            .frame(height: ToolHeaderStyle.height)
            .fixedSize(horizontal: false, vertical: true)
    }
}
