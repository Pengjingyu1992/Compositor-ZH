import AppKit
import SwiftUI

/// The tool rail scrolls when it overflows without showing or reserving space
/// for a macOS scroller, even when the system setting always shows scroll bars.
struct IndicatorlessScrollView<Content: View>: NSViewRepresentable {
    var scrollTarget: Int? = nil
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> Container {
        Container(rootView: content())
    }

    func updateNSView(_ view: Container, context: Context) {
        view.host.rootView = content()
        view.host.invalidateIntrinsicContentSize()
        let changed = view.scrollTarget != scrollTarget
        view.scrollTarget = scrollTarget
        view.updateDocumentSize()
        if changed { view.revealTarget() }
    }

    final class Container: NSScrollView {
        let host: NSHostingView<Content>
        var scrollTarget: Int?
        private var lastViewportSize = NSSize.zero

        init(rootView: Content) {
            host = NSHostingView(rootView: rootView)
            super.init(frame: .zero)
            drawsBackground = false
            borderType = .noBorder
            hasVerticalScroller = false
            hasHorizontalScroller = false
            horizontalScrollElasticity = .none
            documentView = host
            updateDocumentSize()
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            updateDocumentSize()
            if contentView.bounds.size != lastViewportSize {
                lastViewportSize = contentView.bounds.size
                revealTarget()
            }
        }

        func revealTarget() {
            guard let index = scrollTarget else { return }
            let top = CGFloat(index) * 36 + 10
            let y = host.isFlipped ? top : host.bounds.height - top - 32
            host.scrollToVisible(NSRect(x: 0, y: max(0, y), width: host.bounds.width, height: 32))
        }
        func updateDocumentSize() {
            let height = host.fittingSize.height
            let size = NSSize(width: max(1, contentView.bounds.width), height: height)
            if host.frame.size != size { host.setFrameSize(size) }
            verticalScrollElasticity = height > contentView.bounds.height + 1 ? .allowed : .none
        }
    }
}
