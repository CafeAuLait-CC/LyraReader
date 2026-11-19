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
        func configure(key: String, reading: AIReadingModel, onGutterChange: ((CGFloat) -> Void)?) {
            self.onGutterChange = onGutterChange
            guard self.key != key || scroll == nil else { return }
            detach(); self.key = key; self.reading = reading
            Task { @MainActor [weak self] in
                guard let self, self.key == key, let scroll = self.enclosingScrollView else { return }
                self.scroll = scroll
                // A legacy scrollbar keeps its gutter even when the result is short. Scope
                // changes must not move the selector labels as the content starts scrolling.
                scroll.autohidesScrollers = false
                // A new timeline starts at its top; only a matching timeline restores an offset.
                scroll.contentView.scroll(to: reading.scrollPositions[key] ?? .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                scroll.contentView.postsBoundsChangedNotifications = true
                scroll.contentView.postsFrameChangedNotifications = true
                for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                    self.observers.append(NotificationCenter.default.addObserver(forName: name,
                        object: scroll.contentView, queue: .main) { [weak self] _ in
                        Task { @MainActor [weak self] in self?.remember(); self?.reportGutter() }
                    })
                }
                self.reportGutter()
            }
        }
        private func reportGutter() {
            guard let scroll, scroll.bounds.width > 0, scroll.contentView.bounds.width > 0 else { return }
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
            remember()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []; scroll = nil; lastGutter = nil
        }
    }
}
