import AppKit
import SwiftUI

/// AppKit scroll positions belong to the native presentation, independent of request state.
struct AIReadingScrollMemory: NSViewRepresentable {
    let key: String
    let reading: AIReadingModel
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {
        view.configure(key: key, reading: reading)
    }
    static func dismantleNSView(_ view: Marker, coordinator: ()) { view.detach() }

    final class Marker: NSView {
        private var key: String?
        private var observer: NSObjectProtocol?
        private weak var reading: AIReadingModel?
        private weak var scroll: NSScrollView?
        func configure(key: String, reading: AIReadingModel) {
            guard self.key != key || scroll == nil else { return }
            detach(); self.key = key; self.reading = reading
            Task { @MainActor [weak self] in
                guard let self, self.key == key, let scroll = self.enclosingScrollView else { return }
                self.scroll = scroll
                // A legacy scrollbar keeps its gutter even when the result is short. Scope
                // changes must not move the selector labels as the content starts scrolling.
                scroll.autohidesScrollers = false
                if let origin = reading.scrollPositions[key] {
                    scroll.contentView.scroll(to: origin)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                scroll.contentView.postsBoundsChangedNotifications = true
                self.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                    object: scroll.contentView, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.remember() }
                }
            }
        }
        private func remember() {
            guard let key, let scroll else { return }
            reading?.scrollPositions[key] = scroll.contentView.bounds.origin
        }
        func detach() {
            remember()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil; scroll = nil
        }
    }
}
