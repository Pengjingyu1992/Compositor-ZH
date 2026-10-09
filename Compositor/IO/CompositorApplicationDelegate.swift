import AppKit
import SwiftUI

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // View › Canvas Only's key is a plain F, and the menu takes a plain letter even while something is being
        // typed. So an F meant for a text field (the palette's search, a layer's name, a number) goes straight to it,
        // before the menu sees it.
        // Escape leaves fullscreen too, once there's nothing in progress for it to cancel first.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  self.session.canvasOnly, self.session.escapeHasNothingToCancel, NSApp.keyWindow === self.projects.window,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
            self.toggleCanvasOnly()
            return nil
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Match the key regardless of Shift so an uppercase letter stays text too.
            guard ShortcutChord(event).key == ShortcutSettings.shared.native("f").key,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let text = NSApp.keyWindow?.firstResponder as? NSText else { return event }
            text.keyDown(with: event)
            return nil
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow,
                      window === self.workspace.window, self.workspace.canvasOnly else { return }
                self.toggleCanvasOnly()
            }
        }
    }

    /// Black over everything but the window's inside in Canvas Only: the screen around it, its rounded corners and the
    /// faint rim macOS draws along a window's edge, which no setting takes away.
    private var canvasOnlyFrame: NSWindow?
    /// The window as it was before Canvas Only (F) took the whole screen, to put it back exactly.
    private var windowBeforeCanvasOnly: (frame: NSRect, transparentTitlebar: Bool, titleVisibility: NSWindow.TitleVisibility,
                                         fullSizeContent: Bool, presentation: NSApplication.PresentationOptions)?

    /// Canvas Only: the canvas alone on black over the whole screen, without panels, bars, the menu bar or the Dock;
    /// again, the window as it was. The window covers the screen itself, at once: macOS's own full screen takes a
    /// second and slides the window into a new space.
    func toggleCanvasOnly() {
        guard let window = projects.window, session.canvasOnly || session.canToggleCanvasOnly else { return }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        if !session.canvasOnly {
            // Already in macOS full screen, it has the screen; only the panels need putting away.
            if window.styleMask.contains(.fullScreen) { window.toolbar?.isVisible = false }
            if !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main {
                windowBeforeCanvasOnly = (window.frame, window.titlebarAppearsTransparent, window.titleVisibility,
                                          window.styleMask.contains(.fullSizeContentView), NSApp.presentationOptions)
                NSApp.presentationOptions = [.hideDock, .hideMenuBar]
                window.toolbar?.isVisible = false
                window.styleMask.insert(.fullSizeContentView)
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                buttons.forEach { window.standardWindowButton($0)?.isHidden = true }
                window.setFrame(screen.frame, display: true, animate: false)
                // Over the window, moving with it, letting every click through to the canvas.
                let frame = canvasOnlyFrame ?? NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                frame.isOpaque = false
                frame.backgroundColor = .clear
                frame.isReleasedWhenClosed = false
                frame.ignoresMouseEvents = true
                frame.hasShadow = false
                frame.setFrame(screen.frame, display: false)
                // The window may stop short of the screen's top, kept clear of the menu bar it hides.
                let inside = window.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY).insetBy(dx: 2, dy: 2)
                frame.contentView = CanvasOnlyFrameView(inside: inside)
                window.addChildWindow(frame, ordered: .above)
                canvasOnlyFrame = frame
            }
            workspace.canvasOnly = true
        } else {
            workspace.canvasOnly = false
            // In order: the window's title bar as it was, then its toolbar, then its size, so the toolbar lays its
            // buttons out beside the window buttons as it did at launch.
            if let before = windowBeforeCanvasOnly {
                NSApp.presentationOptions = before.presentation
                if !before.fullSizeContent { window.styleMask.remove(.fullSizeContentView) }
                window.titlebarAppearsTransparent = before.transparentTitlebar
                window.titleVisibility = before.titleVisibility
                buttons.forEach { window.standardWindowButton($0)?.isHidden = false }
                window.toolbar?.isVisible = true
                window.setFrame(before.frame, display: true, animate: false)
                if let frame = canvasOnlyFrame {
                    window.removeChildWindow(frame)
                    frame.orderOut(nil)
                }
                windowBeforeCanvasOnly = nil
            } else {
                window.toolbar?.isVisible = true
            }
        }
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

/// Canvas Only's black surround: everything black but `inside`, the window's interior with its corners rounded off.
private final class CanvasOnlyFrameView: NSView {
    private let inside: NSRect
    init(inside: NSRect) {
        self.inside = inside
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        let path = NSBezierPath(rect: bounds)
        // Rounder than the window's own corners, so the black reaches into them: past a window's rounded corner
        // there is nothing, and the screen behind showed through.
        path.append(NSBezierPath(roundedRect: inside, xRadius: 26, yRadius: 26))
        path.windingRule = .evenOdd
        path.fill()
    }
}
