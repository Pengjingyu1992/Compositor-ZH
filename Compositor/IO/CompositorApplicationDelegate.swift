import AppKit

final class CompositorApplicationDelegate: NSObject, NSApplicationDelegate {
    let workspace = ProjectWorkspace(recoveryStore: .shared)
    var session: EditorSession { workspace.current.session }
    var projects: ProjectController { workspace.current.controller }
    var showEditor: (() -> Void)?
    /// Opens this edition's releases without replacing it with an upstream binary.
    func checkForUpdates() {
        guard let url = URL(string: "https://github.com/Pengjingyu1992/Compositor-ZH/releases/latest") else { return }
        NSWorkspace.shared.open(url)
    }

    // Finder Open With and Dock drops, including files delivered during launch.
    func application(_ application: NSApplication, open urls: [URL]) {
        // Reopening a window that's already showing makes SwiftUI rebuild it, so the app blinks out and back:
        // only a closed editor is reopened.
        if !application.windows.contains(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix("editor") == true }) {
            if let showEditor { showEditor() }
            // Launched to open a file, SwiftUI makes no window, and the editor that would set `showEditor` never
            // appears. A Dock click's reopen event makes the window, so the app sends itself one once launched.
            else { DispatchQueue.main.async { Self.reopen() } }
        }
        application.activate()
        Task { await workspace.receive(urls) }
    }

    private static func reopen() {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                           targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        _ = try? event.sendEvent(options: .noReply, timeout: 1)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Always dark, alerts and open/save panels included, whatever the Mac is set to.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Slider knobs snap to a click on the track instead of gliding there.
        SliderSnap.install()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showEditor?() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // What's still open (a dialog, a gradient waiting for Apply) is settled by confirmQuit, which beeps if
        // something, a save still running say, has to finish first.
        guard !workspace.isManaging else { return .terminateCancel }
        Task { sender.reply(toApplicationShouldTerminate: await workspace.confirmQuit()) }
        return .terminateLater
    }
}
