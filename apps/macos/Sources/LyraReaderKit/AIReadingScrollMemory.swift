import AppKit
import SwiftUI

@MainActor enum AIReadingScrollMetrics {
    static let horizontalInset: CGFloat = 18
    static var gutterWidth: CGFloat { NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) }
    static var initialAdditionalInset: CGFloat { NSScroller.preferredScrollerStyle == .overlay ? gutterWidth : 0 }
}

/// AppKit scroll positions belong to the native presentation, independent of request state.
struct AIReadingScrollMemory: NSViewRepresentable {
    let key: String
    let reading: AIReadingModel
    var onGutterChange: ((CGFloat) -> Void)? = nil
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {
        view.configure(key: key, reading: reading, onGutterChange: onGutterChange)
    }
    static func dismantleNSView(_ view: Marker, coordinator: ()) { view.detach() }

    final class Marker: NSView {
        private var key: String?
        private var observers: [NSObjectProtocol] = []
        private var onGutterChange: ((CGFloat) -> Void)?
        private var lastGutter: CGFloat?
        private weak var reading: AIReadingModel?
        private weak var scroll: NSScrollView?
        private var updatePending = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleUpdate() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { unbindScroll() } else { scheduleUpdate() }
        }
        override func layout() { super.layout(); scheduleUpdate() }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance(); scheduleUpdate()
        }
        func configure(key: String, reading: AIReadingModel, onGutterChange: ((CGFloat) -> Void)?) {
            if self.key != key { unbindScroll() }
            self.key = key; self.reading = reading
            self.onGutterChange = onGutterChange
            scheduleUpdate()
        }
        private func scheduleUpdate() {
            guard !updatePending else { return }; updatePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.updatePending = false
                self.attach()
            }
        }
        private func attach() {
            guard window != nil, let key, let reading, let enclosing = enclosingScrollView else { return }
            // Reserve the same native lane independently of content length. The themed
            // scroller paints only the panel background when its range is empty.
            if !enclosing.hasVerticalScroller { enclosing.hasVerticalScroller = true }
            if enclosing.autohidesScrollers { enclosing.autohidesScrollers = false }
            if scroll !== enclosing {
                unbindScroll(); scroll = enclosing
                // A new timeline starts at its top; only a matching timeline restores an offset.
                enclosing.contentView.scroll(to: reading.scrollPositions[key] ?? .zero)
                enclosing.reflectScrolledClipView(enclosing.contentView)
                enclosing.contentView.postsBoundsChangedNotifications = true
                enclosing.contentView.postsFrameChangedNotifications = true
                for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name,
                        object: enclosing.contentView, queue: .main) { [weak self] _ in
                        Task { @MainActor [weak self] in self?.remember(); self?.scheduleUpdate() }
                    })
                }
            }
            reportGutter()
        }
        private func reportGutter() {
            guard let scroll, scroll.bounds.width > 0, scroll.contentView.bounds.width > 0 else { return }
            // SwiftUI can replace its native scroller during layout. Style the containing
            // scroll view again after resize instead of leaving a system-colored empty track.
            LyraReaderSidebarScroller.install(on: scroll, trackColor: LyraReaderTheme.panelBgColor,
                                             hidesInactiveTrack: true)
            // Overlay scrollers consume no layout width. Reserve the same total gutter
            // as legacy scrollers, using actual native geometry rather than a style guess.
            let native = max(0, scroll.bounds.width - scroll.contentView.bounds.width)
            let additional = max(0, AIReadingScrollMetrics.gutterWidth - native)
            if lastGutter != additional { lastGutter = additional; onGutterChange?(additional) }
        }
        private func remember() {
            guard let key, let scroll else { return }
            reading?.scrollPositions[key] = scroll.contentView.bounds.origin
        }
        func detach() {
            unbindScroll(); key = nil; reading = nil; onGutterChange = nil
        }
        private func unbindScroll() {
            remember()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []; scroll = nil; lastGutter = nil
        }
    }
}
