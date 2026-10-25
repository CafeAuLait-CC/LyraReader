import AppKit
import Combine
import Foundation
import SwiftUI

/// A window's tab strip as a drop target, in screen coordinates.
public struct TabDropTarget {
    public let state: AppState
    /// The gap in the target window's order, in `0...target.tabs.count`.
    public let insertionIndex: Int

    public init(state: AppState, insertionIndex: Int) {
        self.state = state
        self.insertionIndex = insertionIndex
    }
}

/// What a released tab drag did.
public enum TabDragOutcome: Equatable {
    /// Escape ended the drag; nothing changed.
    case cancelled
    /// The tab moved inside its own strip.
    case reordered
    /// The tab moved to another window's strip.
    case moved
    /// The tab was dropped outside every strip and opened in a new window.
    case toreOff
    /// The drop was valid but the order does not change (e.g. dropped on either side of itself).
    case nothing
    /// The move was refused; the string is the reason shown to the reader.
    case refused(String)
}

/// The process-wide owner of a tab drag in progress.
///
/// A tab drag is the one gesture that has to look outside its own window: dropping on another
/// window's strip moves the tab there, and dropping on no strip at all tears the tab off into a
/// new window. SwiftUI's `DragGesture` keeps receiving events while the pointer is outside the
/// source view, so the gesture asks this coordinator what is under the pointer (from
/// `NSEvent.mouseLocation`) and the coordinator answers from the drop zones each `TabStrip`
/// registers.
///
/// It also owns the escape key. A cancelled drag must not commit the last on-strip position, so a
/// local key monitor marks the drag cancelled; the gesture checks that mark before deciding.
@MainActor
public final class TabDragCoordinator: ObservableObject {
    public static let shared = TabDragCoordinator()

    /// Asks the app for a reader window containing the prepared tab. Installed by
    /// ``ReaderWindowRoot`` and backed by ``ReaderWindowRegistry/requestNewWindow(moving:from:)``.
    /// `nil` (checks, or a build without window creation) refuses the tear-off with a sentence.
    public var tearOff: ((TabTransfer, AppState) -> Bool)?

    /// Closes a source window after a drop on another window's strip moved its last tab out.
    /// Installed next to ``tearOff`` and backed by
    /// ``ReaderWindowRegistry/closeWindowAfterTabMove(from:)``; only called after ``TabMove``
    /// reports success, so a refused move never closes the window that still owns its tab.
    public var closeEmptiedSource: ((AppState) -> Void)?

    /// The strip the pointer is over while a drag is in flight, unless it is the source strip
    /// (the source draws its own local insertion indicator). Published so the target strip can
    /// show the same indicator before the drop.
    @Published public private(set) var hover: TabDropTarget?

    /// Incremented when Escape cancels the drag. Tab strips observe it to clear the drag preview
    /// even when SwiftUI does not deliver an `onEnded` callback for the cancelled gesture.
    @Published public private(set) var cancelGeneration = 0

    public private(set) var isDragging = false
    public private(set) var isCancelled = false

    private struct Zone {
        weak var state: AppState?
        weak var view: NSView?
        var tabWidth: CGFloat
        var tabCount: Int
        var spacing: CGFloat
    }

    private var zones: [ObjectIdentifier: Zone] = [:]
    private var escapeMonitor: Any?
    /// Installed on cancel: if SwiftUI does not deliver `onEnded` for a cancelled gesture, the
    /// mouse-up still ends the coordinator's drag so the next drag starts clean.
    private var mouseUpMonitor: Any?

    public init() {}

    // MARK: - Drop zones

    /// Registers (or updates) a window's tab strip. `view` is a zero-effect reporter whose bounds
    /// are the strip's content rectangle, so its frame follows horizontal scrolling and window
    /// moves without the coordinator knowing anything about SwiftUI layout.
    public func registerDropZone(
        for state: AppState,
        view: NSView,
        tabWidth: CGFloat,
        tabCount: Int,
        spacing: CGFloat = TabRowLayout.tabSpacing
    ) {
        zones[ObjectIdentifier(state)] = Zone(
            state: state,
            view: view,
            tabWidth: tabWidth,
            tabCount: tabCount,
            spacing: spacing
        )
    }

    public func unregisterDropZone(for state: AppState) {
        zones.removeValue(forKey: ObjectIdentifier(state))
        if hover?.state === state { hover = nil }
    }

    /// The frontmost registered strip under a screen point, with the insertion gap nearest the
    /// pointer. A hidden window, or a strip whose view has left its window, is not a target.
    public func target(atScreenPoint point: CGPoint) -> TabDropTarget? {
        var best: (window: NSWindow, target: TabDropTarget)?
        for zone in zones.values {
            guard let state = zone.state, let view = zone.view, let window = view.window,
                  window.isVisible else { continue }
            let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
            // The strip's reporting view spans the full (possibly scrolled) content, which can be
            // wider than the window and clipped by the ScrollView. Intersect with the window so a
            // point outside the window never counts; use the unclipped origin for the x mapping so
            // a scrolled strip still maps to the same gap.
            let visible = rect.intersection(window.frame)
            guard !visible.isNull, visible.contains(point) else { continue }
            if let best, best.window.orderedIndex <= window.orderedIndex { continue }
            let insertion = TabReorder.insertionIndex(
                forX: point.x - rect.minX,
                tabWidth: zone.tabWidth,
                spacing: zone.spacing,
                tabCount: zone.tabCount
            )
            best = (window, TabDropTarget(state: state, insertionIndex: insertion))
        }
        return best?.target
    }

    // MARK: - Drag lifecycle

    public func beginDrag() {
        guard !isDragging else { return }
        isDragging = true
        isCancelled = false
        installEscapeMonitor()
    }

    /// Escape: remember that the gesture must not commit, and clear the indicators now. The
    /// monitor is removed here so Escape goes back to its normal meaning even if the mouse-up
    /// never reaches the cancelled gesture.
    public func cancelDrag() {
        guard isDragging else { return }
        isCancelled = true
        hover = nil
        cancelGeneration &+= 1
        removeEscapeMonitor()
        installMouseUpMonitor()
    }

    public func endDrag() {
        isDragging = false
        isCancelled = false
        hover = nil
        removeEscapeMonitor()
        removeMouseUpMonitor()
    }

    /// Tracks the strip under the pointer for the target window's insertion indicator. The source
    /// strip keeps its local `TabDragSession` indicator instead, so it is not published here.
    public func updateHover(screenPoint: CGPoint, source: AppState) {
        guard isDragging, !isCancelled else {
            if hover != nil { hover = nil }
            return
        }
        let target = target(atScreenPoint: screenPoint)
        let next = target?.state === source ? nil : target
        if next?.state !== hover?.state || next?.insertionIndex != hover?.insertionIndex {
            hover = next
        }
    }

    // MARK: - Drop

    /// Resolves a released drag. This is the only place a drop mutates windows, so the guess "is
    /// the pointer over a strip?" and the side effect cannot disagree.
    ///
    /// - over the source strip: reorder at `localInsertionIndex`;
    /// - over another window's strip: move the tab there at that strip's insertion index, and
    ///   close the source window if that was its last tab;
    /// - over no strip at all: tear the tab off into a new window.
    @discardableResult
    public func finishDrag(
        source: AppState,
        sourceIndex: Int,
        localInsertionIndex: Int,
        screenPoint: CGPoint
    ) -> TabDragOutcome {
        defer { endDrag() }
        if isCancelled { return .cancelled }
        guard source.tabs.indices.contains(sourceIndex) else { return .nothing }

        if let target = target(atScreenPoint: screenPoint) {
            if target.state === source {
                return source.moveTab(
                    from: sourceIndex, toInsertionIndex: localInsertionIndex) ? .reordered : .nothing
            }
            if TabMove.move(
                from: source, tabAtIndex: sourceIndex,
                to: target.state, insertionIndex: target.insertionIndex
            ) {
                closeEmptiedSourceIfNeeded(source)
                return .moved
            }
            return .refused(source.lastError ?? "The tab could not be moved to the other window.")
        }

        guard let transfer = source.prepareTabTransfer(at: sourceIndex) else {
            return .refused(source.lastError ?? "The tab could not be moved.")
        }
        guard let tearOff else {
            let reason = "LyraReader can’t open a new window right now, so the tab was not moved."
            source.reportTabTransferFailure(reason)
            return .refused(reason)
        }
        if tearOff(transfer, source) { return .toreOff }
        return .refused(source.lastError ?? "The new window could not be created.")
    }

    /// The cross-window move is complete and the source has no tabs left: the window goes with
    /// them. Called only after ``TabMove`` succeeded, so a refused or failed move changes nothing.
    private func closeEmptiedSourceIfNeeded(_ source: AppState) {
        guard source.tabs.isEmpty else { return }
        closeEmptiedSource?(source)
    }

    // MARK: - Escape

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        // The AppKit event monitor runs on the main thread; the closure is declared here and
        // AppKit calls it inside the main run loop, so the actor-isolated state is safe to touch.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.isDragging, event.keyCode == 53 else { return event }
            self.cancelDrag()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        guard let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
    }

    private func installMouseUpMonitor() {
        guard mouseUpMonitor == nil else { return }
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.endDrag()
            return event
        }
    }

    private func removeMouseUpMonitor() {
        guard let mouseUpMonitor else { return }
        NSEvent.removeMonitor(mouseUpMonitor)
        self.mouseUpMonitor = nil
    }
}

/// Reports a tab strip's content rectangle to ``TabDragCoordinator``. The view has no drawing and
/// refuses hit testing; its only job is to give the coordinator a frame that follows SwiftUI
/// layout, horizontal scrolling and window movement.
struct TabDropZoneReporter: NSViewRepresentable {
    let state: AppState
    let tabWidth: CGFloat
    let tabCount: Int

    func makeNSView(context: Context) -> NSView {
        let view = ZoneView()
        view.appState = state
        register(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ZoneView)?.appState = state
        register(nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        guard let view = nsView as? ZoneView, let state = view.appState else { return }
        TabDragCoordinator.shared.unregisterDropZone(for: state)
    }

    private func register(_ view: NSView) {
        TabDragCoordinator.shared.registerDropZone(
            for: state, view: view, tabWidth: tabWidth, tabCount: tabCount)
    }

    final class ZoneView: NSView {
        weak var appState: AppState?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window == nil, let appState else { return }
            TabDragCoordinator.shared.unregisterDropZone(for: appState)
        }
    }
}
