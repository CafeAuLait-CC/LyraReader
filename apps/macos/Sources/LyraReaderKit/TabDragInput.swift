import AppKit
import SwiftUI

/// A tab owns its entire pointer surface, including transparent padding. AppKit must not
/// reinterpret the whitespace as a window drag, or cancel a SwiftUI gesture at the titlebar.
struct TabDragInput: NSViewRepresentable {
    let state: AppState
    let tabID: UUID
    let changed: (TabDragSession?) -> Void

    func makeNSView(context: Context) -> TabDragInputView { TabDragInputView() }
    func updateNSView(_ view: TabDragInputView, context: Context) {
        view.state = state
        view.tabID = tabID
        view.changed = changed
    }
}

@MainActor
final class TabDragInputView: NSView {
    weak var state: AppState?
    var tabID: UUID?
    var changed: ((TabDragSession?) -> Void)?
    private var press: CGPoint?
    private var pressedTabID: UUID?
    private var session: TabDragSession?
    private let coordinator = TabDragCoordinator.shared

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // The native input overlay leaves the real SwiftUI close button reachable.
        let close = CGRect(x: bounds.width - TabRowLayout.closeButtonTrailingInset
                           - TabRowLayout.closeButtonWidth,
                           y: (bounds.height - TabRowLayout.contentHeight) / 2,
                           width: TabRowLayout.closeButtonWidth, height: TabRowLayout.contentHeight)
        return close.contains(local) ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        guard let state, let tabID, state.tabs.contains(where: { $0.id == tabID }), let window else { return }
        if coordinator.isDragging { coordinator.cancelDrag(); coordinator.endDrag() }
        press = window.convertPoint(toScreen: event.locationInWindow)
        pressedTabID = tabID
        session = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press, let state, let window, let id = pressedTabID,
              let index = state.tabs.firstIndex(where: { $0.id == id }) else { return }
        let screen = window.convertPoint(toScreen: event.locationInWindow)
        let delta = CGSize(width: screen.x - press.x, height: press.y - screen.y)
        guard session != nil || hypot(delta.width, delta.height) >= 3 else { return }
        if session == nil {
            coordinator.beginDrag()
            coordinator.beginFeedback(title: state.tabs[index].title,
                sourceFrame: window.convertToScreen(convert(bounds, to: nil)),
                pressPoint: press, appearance: window.effectiveAppearance)
            session = TabDragSession(sourceIndex: index, tabCount: state.tabs.count, tabWidth: bounds.width)
        }
        guard coordinator.isDragging, !coordinator.isCancelled,
              let local = coordinator.localLocation(atScreenPoint: screen, in: state) else { return }
        session?.update(location: local, translation: delta)
        changed?(session)
        coordinator.updateHover(screenPoint: screen, source: state)
        coordinator.updateFeedback(screenPoint: screen, source: state)
    }

    override func mouseUp(with event: NSEvent) {
        let wasDrag = session != nil
        let id = pressedTabID
        press = nil
        pressedTabID = nil
        defer { session = nil; changed?(nil) }
        guard let state, let window, let id,
              let index = state.tabs.firstIndex(where: { $0.id == id }) else {
            if wasDrag { coordinator.endDrag() }
            return
        }
        guard wasDrag else { state.selectTab(index); return }
        // A cancel monitor may have consumed Escape and ended tracking before this mouse-up.
        guard coordinator.isDragging, !coordinator.isCancelled else { coordinator.endDrag(); return }
        let screen = window.convertPoint(toScreen: event.locationInWindow)
        if let local = coordinator.localLocation(atScreenPoint: screen, in: state) {
            session?.update(location: local)
        }
        withAnimation(ReaderMotion.secondaryRowAnimation) {
            _ = coordinator.finishDrag(source: state, sourceIndex: index,
                localInsertionIndex: session?.insertionIndex ?? index, screenPoint: screen)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, press != nil {
            press = nil; pressedTabID = nil; session = nil
            coordinator.cancelDrag(); coordinator.endDrag(); changed?(nil)
        }
        super.viewWillMove(toWindow: newWindow)
    }
}
