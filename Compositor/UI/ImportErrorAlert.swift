import AppKit
import SwiftUI

/// A native sheet avoids SwiftUI adding a second default button to an import failure.
struct ImportErrorAlert: NSViewRepresentable {
    @Binding var message: String?

    func makeNSView(context: Context) -> ImportErrorAlertView { ImportErrorAlertView() }
    func updateNSView(_ view: ImportErrorAlertView, context: Context) {
        view.message = $message
        DispatchQueue.main.async { [weak view] in view?.presentIfNeeded() }
    }
    static func dismantleNSView(_ view: ImportErrorAlertView, coordinator: ()) {
        if let alert = view.alert, let parent = alert.window.sheetParent { parent.endSheet(alert.window) }
    }
}

final class ImportErrorAlertView: NSView {
    var message: Binding<String?>?
    private(set) var alert: NSAlert?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.presentIfNeeded() }
    }

    func presentIfNeeded() {
        guard alert == nil, let window, let text = message?.wrappedValue else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("Import couldn’t finish")
        alert.informativeText = text
        alert.addButton(withTitle: L10n.text("OK"))
        self.alert = alert
        alert.beginSheetModal(for: window) { [weak self] _ in
            guard let self else { return }
            if self.message?.wrappedValue == text { self.message?.wrappedValue = nil }
            self.alert = nil
            DispatchQueue.main.async { [weak self] in self?.presentIfNeeded() }
        }
    }
}
