import AppKit
import CoreGraphics
import SwiftUI
@testable import LyraReaderKit

/// The window-ownership checks for the 44 pt tab row.
///
/// The native titlebar can move asynchronously even when a tab input receives the gesture and
/// reports `mouseDownCanMoveWindow == false`. Direct input calls and a `performDrag` override
/// cannot observe that Window Server path. Assert that native movement is disabled before any
/// press, and that the row is at the actual window top. This check hosts a `.fullSizeContentView`
/// window configured by `ReaderSession`, with `ReaderTitlebarLayout` attached and an
/// `NSHostingView` containing the real `TabStrip`, and dispatches presses through `window.sendEvent`.
///
/// The positive control is the explicit `ReaderWindowDragArea`: `performDrag(with:)` hands the
/// actual move to the Window Server and returns immediately, so a headless check cannot observe a
/// moved frame. The check therefore records both the window's `performDrag(with:)` call (the same
/// explicit call the real window receives) and `ReaderTitlebarDragView.mouseDownHook`
/// (a test-only seam that says the explicit drag area received the press). All other regions must
/// produce neither.
extension ReaderChecks {
    /// A window that records AppKit's decision to hand a press to the Window Server.
    final class DragRecordingWindow: NSWindow {
        private(set) var dragEvents: [NSPoint] = []
        override func performDrag(with event: NSEvent) { dragEvents.append(event.locationInWindow) }
        func resetDrags() { dragEvents.removeAll() }
    }

    @MainActor static func tabHitRegionChecks() async throws {
        // The check records every failing point before it traps, so its PASS/FAIL summary must not
        // sit in a redirected stdout's buffer when the process exits on the final `fatalError`.
        setvbuf(stdout, nil, _IONBF, 0)
        _ = NSApplication.shared
        let coordinator = TabDragCoordinator.shared
        let registry = ReaderWindowRegistry()
        registry.markReady()
        let previousMotion = ReaderMotion.reduceMotionOverride
        ReaderMotion.reduceMotionOverride = false
        let hook = TabHitHookCounter()
        ReaderTitlebarDragView.mouseDownHook = { hook.count += 1 }
        var states: [AppState] = []
        var sessions: [ReaderSession] = []
        var windows: [NSWindow] = []
        defer {
            ReaderTitlebarDragView.mouseDownHook = nil
            ReaderTitlebarDoubleClick.preferenceOverride = nil
            ReaderMotion.reduceMotionOverride = previousMotion
            coordinator.endDrag(); coordinator.tearOff = nil; coordinator.closeEmptiedSource = nil
            registry.newWindow = nil
            for state in states { coordinator.unregisterDropZone(for: state) }
            for session in sessions { session.close() }
            for window in windows { window.orderOut(nil) }
        }
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
            if !condition { failures.append(message()) }
        }
        func inputs(_ root: NSView) -> [TabDragInputView] {
            (root as? TabDragInputView).map { [$0] } ?? root.subviews.flatMap { inputs($0) }
        }
        func dragView(_ root: NSView) -> ReaderTitlebarDragView? {
            if let view = root as? ReaderTitlebarDragView { return view }
            for subview in root.subviews { if let found = dragView(subview) { return found } }
            return nil
        }
        func firstScrollView(_ root: NSView) -> NSScrollView? {
            if let view = root as? NSScrollView { return view }
            for subview in root.subviews { if let found = firstScrollView(subview) { return found } }
            return nil
        }
        func frameInWindow(_ view: NSView) -> CGRect { view.convert(view.bounds, to: nil) }
        func pump(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }
        /// `NSView.hitTest` takes the point in the receiver's superview coordinates. The hosting
        /// view is flipped, so passing a converted local point would test the row mirrored.
        func hitTest(_ host: NSView, windowPoint: NSPoint) -> NSView? {
            let local = host.convert(windowPoint, from: nil)
            return host.hitTest(host.convert(local, to: host.superview))
        }
        func makeWindow(tabs: Int) -> (AppState, DragRecordingWindow, NSHostingView<AnyView>) {
            let state = AppState(engine: MockEngine())
            for index in 0..<tabs {
                state.newTab(url: URL(fileURLWithPath: "/tmp/lyra-hit-\(index)-\(UUID()).pdf"))
            }
            // The window ReaderSession is configured against: a titled window with the content
            // under a transparent titlebar. `ReaderTitlebarLayout` is what extends the native
            // titlebar container over the whole 44 pt row.
            let window = DragRecordingWindow(
                contentRect: CGRect(x: 80, y: 240, width: 900, height: 200),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: AnyView(VStack(spacing: 0) {
                TabStrip(state: state)
                    .padding(.leading, TabRowLayout.tabStripLeadingInset)
                    .background(LyraReaderTheme.tabbarBg)
                Spacer(minLength: 0)
            }.ignoresSafeArea(.container, edges: .top)))
            window.contentView = host
            let session = ReaderSession(state: state, registry: registry)
            session.attach(window: window)
            states.append(state); sessions.append(session); windows.append(window)
            window.orderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            return (state, window, host)
        }
        func alignTitlebar(_ window: NSWindow, _ host: NSView) {
            let align = ReaderTitlebarLayout(window: window)
            align.alignNow()
            host.layoutSubtreeIfNeeded()
        }
        /// A press through the window. Returns whether AppKit requested a window drag, whether the
        /// explicit titlebar drag view received the press, and whether the frame moved.
        func press(_ window: DragRecordingWindow, at point: NSPoint) -> (drags: Int, hook: Int, moved: Bool) {
            window.resetDrags()
            hook.count = 0
            let before = window.frame
            window.sendEvent(tabHitEvent(.leftMouseDown, at: point, in: window))
            window.sendEvent(tabHitEvent(.leftMouseUp, at: point, in: window))
            return (window.dragEvents.count, hook.count, window.frame != before)
        }
        func hitDescription(_ hit: NSView?) -> String {
            guard let hit else { return "no view" }
            return "\(type(of: hit)) canMove=\(hit.mouseDownCanMoveWindow)"
        }
        /// The tab's close cell in window coordinates.
        func closeRect(_ tab: CGRect) -> CGRect {
            CGRect(x: tab.maxX - TabRowLayout.closeButtonTrailingInset - TabRowLayout.closeButtonWidth,
                   y: tab.minY + (tab.height - TabRowLayout.contentHeight) / 2,
                   width: TabRowLayout.closeButtonWidth, height: TabRowLayout.contentHeight)
        }
        /// The `+` button in window coordinates. It follows the last tab by one 4 pt gap.
        func plusRect(_ tab: CGRect) -> CGRect {
            CGRect(x: tab.maxX + TabRowLayout.tabSpacing,
                   y: tab.minY + (tab.height - TabRowLayout.plusButtonSize) / 2,
                   width: TabRowLayout.plusButtonSize, height: TabRowLayout.plusButtonSize)
        }

        for tabCount in [1, 3, 8] {
            let failuresBefore = failures.count
            let (state, window, host) = makeWindow(tabs: tabCount)
            alignTitlebar(window, host)
            let hostedInputs = inputs(host).sorted { frameInWindow($0).minX < frameInWindow($1).minX }
            guard hostedInputs.count == tabCount else {
                fatalError("FAIL: \(tabCount) tabs host \(hostedInputs.count) tab input views")
            }
            let tabFrames = hostedInputs.map(frameInWindow)
            let row = tabFrames.dropFirst().reduce(tabFrames[0]) { $0.union($1) }
            let rowMid = row.midY
            expect(abs(row.maxY - host.convert(host.bounds, to: nil).maxY) < 1,
                   "the tab row is flush with the window top, as in ReaderWindowRoot (row \(row), host \(host.convert(host.bounds, to: nil)))")
            let stripStart = TabRowLayout.tabStripLeadingInset
            let stripEnd = window.contentView!.bounds.width
            guard let drag = dragView(host) else { fatalError("FAIL: the explicit window-drag area is missing") }
            let dragRect = frameInWindow(drag)
            guard let scroll = firstScrollView(host) else {
                fatalError("FAIL: the tab strip is not backed by an NSScrollView (tabs=\(tabCount))")
            }
            // The scroll view's frame is the visible tab viewport. A tab input's NSView frame can
            // extend behind the trailing drag area when the content is wider than the viewport;
            // only the intersection is visually part of the tab.
            let viewport = frameInWindow(scroll)
            let visibleTabFrames = tabFrames.map { $0.intersection(viewport) }

            // The production titlebar configuration, including the layout that extends the native
            // titlebar over the row under test.
            expect(window.styleMask.contains(.fullSizeContentView),
                   "the check window is a full-size-content window (tabs=\(tabCount))")
            expect(window.titlebarAppearsTransparent,
                   "the titlebar is transparent (tabs=\(tabCount))")
            expect(window.titleVisibility == .hidden,
                   "the title is hidden (tabs=\(tabCount))")
            expect(window.titlebarSeparatorStyle == .none,
                   "the titlebar separator is off (tabs=\(tabCount))")
            expect(!window.isMovable,
                   "native titlebar movement is disabled before a tab press; Window Server must not move the upper tab region (tabs=\(tabCount))")
            expect(window.standardWindowButton(.closeButton)?.superview?.frame.height == TabRowLayout.height,
                   "ReaderTitlebarLayout extends the native titlebar over the 44 pt row (tabs=\(tabCount))")
            expect(abs(dragRect.minX - viewport.maxX - 6) <= 1,
                   "the explicit drag area begins 6 pt after the tab viewport (drag \(dragRect.minX), viewport \(viewport.maxX), tabs=\(tabCount))")
            expect(dragRect.width >= 24,
                   "the explicit drag area keeps its 24 pt minimum (tabs=\(tabCount))")

            // Every point of every tab rectangle is owned by the tab input, not by the window.
            for (index, tab) in visibleTabFrames.enumerated() {
                guard !tab.isNull, tab.width > 1 else { continue }
                for y in [tab.minY + 2, rowMid, tab.maxY - 8, tab.maxY - 2] {
                    let hit = hitTest(host, windowPoint: NSPoint(x: tab.midX, y: y))
                    expect(hit is TabDragInputView,
                           "the title of tab \(index) at y=\(y - tab.minY) is a tab input, got \(hitDescription(hit)) (tabs=\(tabCount))")
                }
            }

            var probes: [(String, NSPoint)] = []
            for (index, tab) in tabFrames.enumerated() {
                let visible = visibleTabFrames[index]
                guard !visible.isNull, visible.width > 1 else { continue }
                for y in [tab.minY + 2, rowMid, tab.maxY - 8, tab.maxY - 2] {
                    probes.append(("tab \(index) title", NSPoint(x: visible.midX, y: y)))
                    if tab.minX >= viewport.minX - 0.5 {
                        probes.append(("tab \(index) leading padding", NSPoint(x: tab.minX + 2, y: y)))
                    }
                    if tab.maxX <= viewport.maxX + 0.5 {
                        probes.append(("tab \(index) trailing inset", NSPoint(x: tab.maxX - 2, y: y)))
                    }
                }
            }
            for index in 0..<(tabFrames.count - 1) {
                let gap = (tabFrames[index].maxX + tabFrames[index + 1].minX) / 2
                guard gap >= viewport.minX, gap <= viewport.maxX else { continue }
                for y in [row.minY + 2, rowMid, row.maxY - 8, row.maxY - 2] {
                    probes.append(("\(TabRowLayout.tabSpacing) pt gap after tab \(index)",
                                   NSPoint(x: gap, y: y)))
                }
            }
            let plus = plusRect(tabFrames.last!)
            if plus.minX >= viewport.minX, plus.maxX <= viewport.maxX {
                for y in [row.minY + 2, rowMid, row.maxY - 8, row.maxY - 2] {
                    probes.append(("tab-to-plus gap", NSPoint(x: tabFrames.last!.maxX + 1, y: y)))
                }
            }
            for y in [row.minY + 2, rowMid, row.maxY - 8, row.maxY - 2] {
                probes.append(("strip leading padding", NSPoint(x: stripStart + TabRowLayout.tabStripHorizontalPadding / 2, y: y)))
                probes.append(("strip trailing padding", NSPoint(x: stripEnd - TabRowLayout.tabStripHorizontalPadding + 1, y: y)))
                probes.append(("scroll-to-drag-area gap", NSPoint(x: dragRect.minX - 3, y: y)))
            }

            for (name, point) in probes {
                guard point.x >= stripStart, point.x <= stripEnd else { continue }
                // At the actual window top, the 2 pt probe is in AppKit's resize border.
                // Its synchronous hysteresis loop needs physical input, so only hit-test it.
                // The right corner's resize target also extends into the 8 pt upper probe;
                // elsewhere upper, centre and bottom probes dispatch complete presses.
                if point.y > row.maxY - 5
                    || (name == "strip trailing padding" && point.y > rowMid + 1) { continue }
                let hit = hitTest(host, windowPoint: point)
                let result = press(window, at: point)
                expect(result.drags == 0,
                       "\(name) at x=\(point.x) y=\(point.y - row.minY) must not start a window drag; hit \(hitDescription(hit)), drags=\(result.drags) (tabs=\(tabCount))")
                expect(result.hook == 0,
                       "\(name) at x=\(point.x) must not reach the explicit window-drag view (tabs=\(tabCount))")
                expect(!(hit is ReaderTitlebarDragView),
                       "\(name) at x=\(point.x) must not be hit-tested as the explicit window-drag view (tabs=\(tabCount))")
                expect(hit?.mouseDownCanMoveWindow != true,
                       "\(name) at x=\(point.x) must not be a view AppKit treats as window background; got \(hitDescription(hit)) (tabs=\(tabCount))")
                expect(!result.moved,
                       "\(name) at x=\(point.x) must not move the check window (tabs=\(tabCount))")
            }

            // The positive control, in two steps.
            //
            // 1. A press in the explicit drag area must reach its own handler even in a non-key
            //    window. Native titlebar movement is disabled, so background dragging cannot
            //    substitute for the explicit performDrag call.
            // 2. Drive that view's real `mouseDown` to prove its hook fires and it asks AppKit for
            //    the drag. That is the same handler a key window's press reaches.
            let dragPoint = NSPoint(x: dragRect.midX, y: rowMid)
            hook.count = 0
            window.resetDrags()
            window.sendEvent(tabHitEvent(.leftMouseDown, at: dragPoint, in: window))
            window.sendEvent(tabHitEvent(.leftMouseUp, at: dragPoint, in: window))
            let windowDispatchedDrag = window.dragEvents.count >= 1
            print("  positive control: window-dispatched explicit drag area asks for a window drag: "
                  + "\(windowDispatchedDrag) (tabs=\(tabCount))")
            expect(windowDispatchedDrag,
                   "positive control: a window-dispatched press in the explicit drag area starts the window drag (tabs=\(tabCount))")
            expect(hook.count == 1 && !window.isMovable,
                   "the explicit drag view accepts the first press without re-enabling automatic titlebar movement (tabs=\(tabCount))")

            hook.count = 0
            window.resetDrags()
            drag.mouseDown(with: tabHitEvent(.leftMouseDown, at: dragPoint, in: window))
            expect(hook.count == 1 && window.dragEvents.count >= 1,
                   "positive control: the explicit drag view's own press handler starts the window drag (drags=\(window.dragEvents.count), hook=\(hook.count), tabs=\(tabCount))")
            expect(drag.mouseDownCanMoveWindow,
                   "the explicit drag area still advertises an AppKit window drag (tabs=\(tabCount))")

            var closeTargetFrame = tabFrames[0]
            var closeTargetIndex = 0
            if tabCount == 8 {
                guard let document = scroll.documentView else {
                    fatalError("FAIL: the 8-tab scroll view has no document view")
                }
                expect(document.frame.width > scroll.contentView.bounds.width + 1,
                       "8 tabs overflow the visible strip (content \(document.frame.width) > clip \(scroll.contentView.bounds.width))")
                // A two-finger horizontal scroll over a guarded 4 pt gap must still scroll the
                // strip; the guard owns the pointer, not the scroll gesture.
                let scrollGap = (tabFrames[0].maxX + tabFrames[1].minX) / 2
                let scrollHit = hitTest(host, windowPoint: NSPoint(x: scrollGap, y: rowMid))
                expect(scrollHit?.mouseDownCanMoveWindow == false
                            && !(scrollHit is ReaderTitlebarDragView),
                       "the gap used for the scroll test is owned by a non-movable view; got \(hitDescription(scrollHit))")
                let beforeScrollX = scroll.contentView.bounds.origin.x
                if let scrollEvent = tabHitScrollEvent(deltaX: -60) {
                    scrollHit?.scrollWheel(with: scrollEvent)
                    pump(0.1)
                }
                let afterScrollX = scroll.contentView.bounds.origin.x
                expect(abs(afterScrollX - beforeScrollX) > 1,
                       "horizontal scrolling over a 4 pt gap scrolls the 8-tab strip (before \(beforeScrollX), after \(afterScrollX))")
                let offset = NSPoint(x: document.frame.width - scroll.contentView.bounds.width, y: 0)
                scroll.contentView.scroll(to: offset)
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded()
                let scrolled = inputs(host).sorted { frameInWindow($0).minX < frameInWindow($1).minX }
                let scrolledFrames = scrolled.map(frameInWindow)
                expect(scrolledFrames[0].minX < tabFrames[0].minX,
                       "scrolling the overflowing strip moves the first tab left (before \(tabFrames[0].minX), after \(scrolledFrames[0].minX))")
                let scrolledRow = scrolledFrames.dropFirst().reduce(scrolledFrames[0]) { $0.union($1) }
                let scrolledViewport = frameInWindow(scroll)
                for index in 0..<(scrolledFrames.count - 1) {
                    let gap = (scrolledFrames[index].maxX + scrolledFrames[index + 1].minX) / 2
                    guard gap >= scrolledViewport.minX, gap <= scrolledViewport.maxX else { continue }
                    let point = NSPoint(x: gap, y: scrolledRow.midY)
                    let hit = hitTest(host, windowPoint: point)
                    let result = press(window, at: point)
                    expect(result.drags == 0,
                           "the \(TabRowLayout.tabSpacing) pt gap after scrolled tab \(index) at x=\(gap) must not start a window drag; hit \(hitDescription(hit)), drags=\(result.drags)")
                    expect(result.hook == 0,
                           "the gap after scrolled tab \(index) must not reach the explicit window-drag view")
                    expect(hit?.mouseDownCanMoveWindow != true,
                           "the gap after scrolled tab \(index) must not be a window-background view; got \(hitDescription(hit))")
                }
                // The plus button is on screen after the scroll; it still opens the importer
                // without starting a window drag.
                state.showFileImporter = false
                let scrolledPlus = plusRect(scrolledFrames.last!)
                if scrolledPlus.midX <= stripEnd {
                    let plusResult = press(window, at: NSPoint(x: scrolledPlus.midX, y: scrolledRow.midY))
                    expect(plusResult.drags == 0 && plusResult.hook == 0,
                           "the scrolled + button opens the importer without a window drag")
                    expect(state.showFileImporter, "the scrolled + button still opens the importer")
                    state.showFileImporter = false
                }
                // The last tab's trailing 4 pt inset is only visible once the strip is scrolled;
                // it must start the tab drag, not the window drag.
                if let index = scrolledFrames.lastIndex(where: {
                    $0.maxX <= scrolledViewport.maxX + 0.5 && $0.minX >= scrolledViewport.minX - 0.5
                }) {
                    let tab = scrolledFrames[index]
                    for y in [tab.minY + 2, scrolledRow.midY, tab.maxY - 8] {
                        let point = NSPoint(x: tab.maxX - 2, y: y)
                        let hit = hitTest(host, windowPoint: point)
                        let result = press(window, at: point)
                        expect(result.drags == 0 && result.hook == 0,
                               "the trailing 4 pt inset of scrolled tab \(index) at x=\(point.x) must not start a window drag (drags=\(result.drags))")
                        expect(hit?.mouseDownCanMoveWindow != true && !(hit is ReaderTitlebarDragView),
                               "the trailing 4 pt inset of scrolled tab \(index) must be owned by the tab input; got \(hitDescription(hit))")
                    }
                }
                // Close a tab whose close cell is fully visible after the scroll.
                let visibleCloseIndex = scrolledFrames.firstIndex(where: {
                    closeRect($0).minX >= scrolledViewport.minX && closeRect($0).maxX <= scrolledViewport.maxX
                })
                expect(visibleCloseIndex != nil,
                       "the scrolled 8-tab strip has a fully visible close button")
                if let index = visibleCloseIndex {
                    closeTargetFrame = scrolledFrames[index]
                    closeTargetIndex = index
                }
            }

            // The + button: a real press opens the importer and never moves the window. In the
            // 8-tab case this is checked after scrolling, where the button is on screen.
            if tabCount != 8 {
                state.showFileImporter = false
                let plusPoint = NSPoint(x: plus.midX, y: plus.midY)
                let plusResult = press(window, at: plusPoint)
                expect(plusResult.drags == 0 && plusResult.hook == 0,
                       "a press on the + button does not start a window drag (tabs=\(tabCount))")
                expect(state.showFileImporter,
                       "a window-dispatched click on the + button opens the importer (tabs=\(tabCount))")
                state.showFileImporter = false
            }

            // The close button is a real SwiftUI control above the tab input: a window-dispatched
            // click must close the tab, not move the window. Closing changes the tab widths, so
            // this is the last interaction on this window.
            let close = closeRect(closeTargetFrame)
            let beforeClose = state.tabs.map(\.id)
            let closedID = beforeClose[closeTargetIndex]
            let closeResult = press(window, at: NSPoint(x: close.midX, y: close.midY))
            expect(closeResult.drags == 0 && closeResult.hook == 0,
                   "a press on the close button does not start a window drag (tabs=\(tabCount))")
            expect(state.tabs.count == beforeClose.count - 1
                        && !state.tabs.contains(where: { $0.id == closedID }),
                   "a window-dispatched click on the close button closes its tab (tabs=\(tabCount))")

            if failures.count == failuresBefore {
                print("PASS: tab hit regions for \(tabCount) tabs (row y=\(row.minY)...\(row.maxY), "
                      + "tabs \(tabFrames.map { Int($0.minX.rounded()) }))")
            }
        }

        // Guarded whitespace keeps the system titlebar double-click action while a single press
        // there is still swallowed. A separate window keeps the zoom out of the tab probes above.
        let failuresBeforeDoubleClick = failures.count
        let (_, titlebarWindow, titlebarHost) = makeWindow(tabs: 3)
        alignTitlebar(titlebarWindow, titlebarHost)
        let titlebarFrames = inputs(titlebarHost)
            .sorted { frameInWindow($0).minX < frameInWindow($1).minX }
            .map(frameInWindow)
        let titlebarMidY = titlebarFrames[0].midY
        let titlebarGap = NSPoint(
            x: (titlebarFrames[0].maxX + titlebarFrames[1].minX) / 2, y: titlebarMidY)
        let titlebarPadding = NSPoint(
            x: TabRowLayout.tabStripLeadingInset + TabRowLayout.tabStripHorizontalPadding / 2,
            y: titlebarMidY)
        ReaderTitlebarDoubleClick.preferenceOverride = "Maximize"
        for (name, point) in [("inter-tab gap", titlebarGap),
                              ("strip leading padding", titlebarPadding)] {
            if titlebarWindow.isZoomed { titlebarWindow.performZoom(nil); pump(0.05) }
            let hit = hitTest(titlebarHost, windowPoint: point)
            expect(hit?.mouseDownCanMoveWindow == false && !(hit is ReaderTitlebarDragView),
                   "\(name) is owned by a non-movable tab-strip view; got \(hitDescription(hit))")
            let before = titlebarWindow.frame
            let single = press(titlebarWindow, at: point)
            expect(single.drags == 0 && single.hook == 0 && !single.moved
                        && titlebarWindow.frame == before && !titlebarWindow.isZoomed,
                   "a single press in the \(name) neither moves nor zooms the window")
            titlebarWindow.resetDrags()
            hook.count = 0
            titlebarWindow.sendEvent(tabHitEvent(.leftMouseDown, at: point, in: titlebarWindow, clickCount: 2))
            titlebarWindow.sendEvent(tabHitEvent(.leftMouseUp, at: point, in: titlebarWindow, clickCount: 2))
            expect(titlebarWindow.isZoomed,
                   "a double-click in the \(name) performs the Maximize titlebar action")
            expect(titlebarWindow.dragEvents.isEmpty && hook.count == 0,
                   "a double-click in the \(name) does not start a window drag")
        }
        if titlebarWindow.isZoomed { titlebarWindow.performZoom(nil); pump(0.05) }
        ReaderTitlebarDoubleClick.preferenceOverride = "None"
        let beforeNone = titlebarWindow.frame
        titlebarWindow.resetDrags()
        titlebarWindow.sendEvent(tabHitEvent(.leftMouseDown, at: titlebarGap, in: titlebarWindow, clickCount: 2))
        titlebarWindow.sendEvent(tabHitEvent(.leftMouseUp, at: titlebarGap, in: titlebarWindow, clickCount: 2))
        expect(!titlebarWindow.isZoomed && !titlebarWindow.isMiniaturized
                    && titlebarWindow.frame == beforeNone && titlebarWindow.dragEvents.isEmpty,
               "the None preference makes a gap double-click inert")
        ReaderTitlebarDoubleClick.preferenceOverride = nil
        if failures.count == failuresBeforeDoubleClick {
            print("PASS: gap and padding double-clicks keep the titlebar action; single presses stay swallowed")
        }

        // The same reorder through a press that starts on the title and one that starts on the
        // tab's trailing padding. The press goes through the window; AppKit does not deliver a
        // synthetic `leftMouseDragged` to the input in this headless harness, so the drag and
        // release are sent to the input view that received the press (the same native handlers
        // `TabPointerChecks` drives).
        func reorder(startingAt padding: Bool) -> Bool {
            let (state, window, host) = makeWindow(tabs: 3)
            alignTitlebar(window, host)
            coordinator.endDrag()
            state.selectTab(0)
            let order = inputs(host).sorted { frameInWindow($0).minX < frameInWindow($1).minX }
            guard order.count == 3 else { return false }
            let ids = state.tabs.map(\.id)
            let source = order[2]
            let sourceFrame = frameInWindow(source)
            let targetFrame = frameInWindow(order[0])
            let start = NSPoint(
                x: padding ? sourceFrame.maxX - 2 : sourceFrame.midX,
                y: sourceFrame.midY)
            let target = NSPoint(x: targetFrame.minX + 4, y: targetFrame.midY)
            window.resetDrags()
            hook.count = 0
            window.sendEvent(tabHitEvent(.leftMouseDown, at: start, in: window))
            let pressMoved = window.dragEvents.count != 0 || hook.count != 0
            source.mouseDragged(with: tabHitEvent(.leftMouseDragged, at: target, in: window))
            source.mouseUp(with: tabHitEvent(.leftMouseUp, at: target, in: window))
            let reordered = state.tabs.map(\.id) == [ids[2], ids[0], ids[1]]
            if !reordered || pressMoved {
                print("FAIL: reorder from \(padding ? "padding" : "title") "
                      + "reordered=\(reordered) windowDrag=\(pressMoved) order=\(state.tabs.map { String($0.id.uuidString.prefix(4)) })")
            }
            return reordered && !pressMoved
        }
        expect(reorder(startingAt: false), "a tab drag starting on the title reorders without moving the window")
        expect(reorder(startingAt: true), "a tab drag starting on the trailing padding reorders exactly like the title")

        if !failures.isEmpty {
            for failure in failures { print("FAIL: \(failure)") }
            fatalError("FAIL: \(failures.count) tab hit-region assertion(s) failed")
        }
        print("PASS: tabs, gaps and strip padding never start a window drag; the explicit drag area does; "
              + "close, + and both reorder origins still work")
    }

    @MainActor static func tabHitEvent(
        _ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clickCount: Int = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1,
            clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    @MainActor static func tabHitScrollEvent(deltaX: CGFloat) -> NSEvent? {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
            wheel1: 0, wheel2: Int32(deltaX), wheel3: 0) else { return nil }
        return NSEvent(cgEvent: event)
    }
}

/// The test-only seam in ``ReaderTitlebarDragView`` increments this box.
private final class TabHitHookCounter: @unchecked Sendable {
    var count = 0
}
