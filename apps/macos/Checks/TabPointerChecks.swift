import AppKit
import SwiftUI
@testable import LyraReaderKit

extension ReaderChecks {
    /// Real hosted hit surfaces and mouse events cover the part model-only drag tests miss.
    @MainActor static func tabPointerChecks() async throws {
        _ = NSApplication.shared
        let coordinator = TabDragCoordinator.shared
        let registry = ReaderWindowRegistry()
        registry.markReady()
        var states: [AppState] = []
        var sessions: [ReaderSession] = []
        var windows: [NSWindow] = []
        var hosts: [NSHostingView<AnyView>] = []
        let previousMotion = ReaderMotion.reduceMotionOverride
        ReaderMotion.reduceMotionOverride = false
        defer {
            coordinator.endDrag(); coordinator.tearOff = nil; coordinator.closeEmptiedSource = nil
            registry.newWindow = nil
            for state in states { coordinator.unregisterDropZone(for: state) }
            for session in sessions { session.close() }
            for window in windows { window.orderOut(nil) }
            ReaderMotion.reduceMotionOverride = previousMotion
        }

        func makeWindow(x: CGFloat, urls: [URL]) -> AppState {
            let state = AppState(engine: MockEngine())
            for url in urls { state.newTab(url: url) }
            let window = NSWindow(contentRect: CGRect(x: x, y: 250, width: 800, height: 150),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            let host = NSHostingView(rootView: AnyView(VStack(spacing: 0) {
                TabStrip(state: state).padding(.leading, TabRowLayout.tabStripLeadingInset)
                Spacer(minLength: 0)
            }.ignoresSafeArea(.container, edges: .top)))
            window.contentView = host
            let session = ReaderSession(state: state, registry: registry)
            session.attach(window: window)
            states.append(state); sessions.append(session); windows.append(window); hosts.append(host)
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            return state
        }
        func inputs(_ root: NSView) -> [TabDragInputView] {
            (root as? TabDragInputView).map { [$0] } ?? root.subviews.flatMap { inputs($0) }
        }
        func surface(_ id: UUID, host: NSView) async throws -> TabDragInputView {
            try await eventually("the actual tab input surface is hosted") {
                host.layoutSubtreeIfNeeded()
                return inputs(host).contains {
                    guard $0.tabID == id, $0.bounds.width > 90 else { return false }
                    guard let state = $0.state else { return false }
                    let ordered = inputs(host).sorted {
                        host.convert($0.bounds, from: $0).minX < host.convert($1.bounds, from: $1).minX
                    }
                    guard ordered.compactMap(\.tabID) == state.tabs.map(\.id) else { return false }
                    let point = host.convert(CGPoint(x: 35, y: 22), from: $0)
                    return host.hitTest(host.convert(point, to: host.superview)) === $0
                }
            }
            return inputs(host).first { $0.tabID == id }!
        }
        func point(_ view: NSView, x: CGFloat) -> CGPoint {
            view.window!.convertPoint(toScreen: view.convert(CGPoint(x: x, y: 22), to: nil))
        }
        func event(_ type: NSEvent.EventType, view: NSView, screen: CGPoint) -> NSEvent {
            let window = view.window!
            return NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: screen),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        func drag(_ view: TabDragInputView, from start: CGPoint, to end: CGPoint, release: Bool = true) {
            view.mouseDown(with: event(.leftMouseDown, view: view, screen: start))
            view.mouseDragged(with: event(.leftMouseDragged, view: view, screen: end))
            if release { view.mouseUp(with: event(.leftMouseUp, view: view, screen: end)) }
        }
        let urls = (0..<4).map { URL(fileURLWithPath: "/tmp/lyra-pointer-\(UUID())-\($0).pdf") }
        let source = makeWindow(x: 100, urls: Array(urls.prefix(3)))
        sessions[0].installTabDragActions()
        let ids = source.tabs.map(\.id)
        let sourceFrame = windows[0].frame
        let third = try await surface(ids[2], host: hosts[0])
        for x in [CGFloat(35), third.bounds.width - 40, third.bounds.width - 2] {
            let local = CGPoint(x: x, y: 22)
            let inHost = hosts[0].convert(local, from: third)
            let hit = hosts[0].hitTest(hosts[0].convert(inHost, to: hosts[0].superview))
            require(hit === third,
                    "title, blank padding and trailing inset hit the same native tab input (x \(x))")
        }
        let closePoint = CGPoint(x: third.bounds.width - 15, y: 22)
        require(third.hitTest(third.convert(closePoint, to: third.superview)) == nil,
                "the real close button remains outside the tab drag surface")
        require(!third.mouseDownCanMoveWindow, "tab whitespace cannot start an AppKit window drag")
        let first = try await surface(ids[0], host: hosts[0])
        let clickStart = point(first, x: first.bounds.width - 40)
        drag(first, from: clickStart, to: CGPoint(x: clickStart.x + 1, y: clickStart.y))
        require(source.activeTabIndex == 0 && source.tabs.map(\.id) == ids,
                "a padding click with slight pointer movement selects without starting a drag")
        drag(third, from: point(third, x: 35), to: point(first, x: 8))
        require(source.tabs.map(\.id) == [ids[2], ids[0], ids[1]],
                "dragging the title through actual mouse handlers reorders tabs")
        require(windows[0].frame == sourceFrame, "reordering from the title does not move the window")

        let movedThird = try await surface(ids[2], host: hosts[0])
        let last = try await surface(ids[1], host: hosts[0])
        drag(movedThird, from: point(movedThird, x: movedThird.bounds.width - 40),
             to: point(last, x: last.bounds.width - 2))
        require(source.tabs.map(\.id) == ids, "dragging blank tab padding reorders by the same rules")
        require(windows[0].frame == sourceFrame, "dragging tab padding never drags the window")

        let target = makeWindow(x: 1050, urls: [urls[3]])
        let targetTab = try await surface(target.tabs[0].id, host: hosts[1])
        let moving = try await surface(ids[0], host: hosts[0])
        let crossPoint = point(targetTab, x: targetTab.bounds.width - 2)
        drag(moving, from: point(moving, x: moving.bounds.width - 40), to: crossPoint, release: false)
        require(coordinator.hover?.state === target, "a real drag highlights the other window's insertion gap")
        require(coordinator.feedbackFrame != nil && !sourceFrame.intersects(coordinator.feedbackFrame!),
                "the floating tab preview remains visible outside its source window")
        moving.mouseUp(with: event(.leftMouseUp, view: moving, screen: crossPoint))
        require(!source.containsTab(id: ids[0]) && target.containsTab(id: ids[0]),
                "a padding-originated drag moves exactly one tab to the other window")

        // Cancel a real pointer drag; mouse-up after Escape must not become a tear-off.
        let cancelling = try await surface(ids[1], host: hosts[0])
        let outside = CGPoint(x: 500, y: 100)
        let beforeCancel = source.tabs.map(\.id)
        drag(cancelling, from: point(cancelling, x: 35), to: outside, release: false)
        require(coordinator.feedbackFrame != nil, "a prospective new window has visible drag feedback")
        coordinator.cancelDrag()
        cancelling.mouseUp(with: event(.leftMouseUp, view: cancelling, screen: outside))
        require(source.tabs.map(\.id) == beforeCancel && !coordinator.isDragging,
                "Escape followed by mouse-up preserves tabs and ends the pointer gesture")
        require(coordinator.feedbackFrame == nil, "Escape clears the floating preview")

        var newState: AppState?
        registry.newWindow = { newState = makeWindow(x: 500, urls: []) }
        source.closeTab(0)
        let onlyID = source.tabs[0].id
        let only = try await surface(onlyID, host: hosts[0])
        drag(only, from: point(only, x: only.bounds.width - 40), to: outside)
        require(source.tabs.isEmpty && newState?.containsTab(id: onlyID) == true,
                "dragging the last tab's blank area opens it in a new window")
        require(!windows[0].isVisible && sessions[0].window == nil,
                "the last-tab pointer tear-off closes the emptied source window")
        require(coordinator.feedbackFrame == nil && !coordinator.isDragging,
                "a completed tear-off leaves no drag state or preview")

        ReaderMotion.reduceMotionOverride = true
        coordinator.beginDrag()
        coordinator.beginFeedback(title: "Reduced motion", sourceFrame: CGRect(x: 100, y: 100, width: 200, height: 44),
            pressPoint: CGPoint(x: 120, y: 122), appearance: NSAppearance(named: .aqua)!)
        coordinator.updateFeedback(screenPoint: outside, source: source)
        require(coordinator.feedbackFrame != nil, "Reduce Motion retains essential pointer feedback")
        coordinator.cancelDrag(); coordinator.endDrag()
        require(coordinator.feedbackFrame == nil, "Reduce Motion clears feedback without a return animation")

        // A scrolled content reporter can extend behind the viewport's neighbours. It must not
        // turn the clipped portion, or a hidden strip, into a target in another part of the row.
        let clip = NSClipView(frame: CGRect(x: 20, y: 30, width: 100, height: 44))
        let documentView = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 44))
        clip.documentView = documentView
        hosts[1].addSubview(clip)
        coordinator.registerDropZone(for: target, view: documentView, tabWidth: 96, tabCount: 5)
        let visiblePoint = windows[1].convertPoint(toScreen: clip.convert(CGPoint(x: 50, y: 22), to: nil))
        let clippedPoint = windows[1].convertPoint(toScreen: clip.convert(CGPoint(x: 150, y: 22), to: nil))
        require(coordinator.target(atScreenPoint: visiblePoint)?.state === target,
                "the visible part of a horizontally clipped strip accepts a drop")
        require(coordinator.target(atScreenPoint: clippedPoint) == nil,
                "clipped tab content cannot accept a drop behind its viewport neighbours")
        clip.isHidden = true
        require(coordinator.target(atScreenPoint: visiblePoint) == nil,
                "a hidden strip cannot capture a cross-window tab drop")
    }
}
