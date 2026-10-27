import AppKit
import Foundation
import LyraReaderKit

/// Regressions for the two titlebar interactions that are easy to lose because the window draws
/// its own titlebar strip: the system double-click action and dragging a tab to another position
/// or window.
extension ReaderChecks {
    // MARK: - Titlebar double-click

    /// Double-clicking the strip must follow the system preference exactly as a standard titlebar
    /// would: zoom, minimise, or nothing. The check drives the AppKit view that owns the empty
    /// titlebar area with a synthetic double-click, and asserts the window's own state rather than
    /// whether a callback ran, so "performed zoom" and "happened to look zoomed" are not confused.
    @MainActor static func titlebarDoubleClickChecks() {
        require(ReaderTitlebarDoubleClick.preferenceKey == "AppleActionOnDoubleClick",
                "the titlebar action reads the system's AppleActionOnDoubleClick preference")

        // The preference strings are what System Settings writes. An absent key is the platform
        // default (zoom); the values are case-insensitive because defaults can be written by hand.
        require(TitlebarDoubleClickAction(preferenceValue: "Maximize") == .zoom,
                "Maximize means zoom")
        require(TitlebarDoubleClickAction(preferenceValue: "Minimize") == .minimize,
                "Minimize means minimise")
        require(TitlebarDoubleClickAction(preferenceValue: "None") == .none,
                "None means do nothing")
        require(TitlebarDoubleClickAction(preferenceValue: "Zoom") == .zoom,
                "the reader-facing name Zoom is accepted as well as Maximize")
        require(TitlebarDoubleClickAction(preferenceValue: nil) == .zoom,
                "an unset preference keeps macOS's default, zoom")
        require(TitlebarDoubleClickAction(preferenceValue: "not-a-real-value") == .zoom,
                "an unrecognised value falls back to zoom instead of disabling the gesture")

        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 480, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let strip = ReaderTitlebarDragView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        window.contentView = strip
        defer {
            ReaderTitlebarDoubleClick.preferenceOverride = nil
            window.deminiaturize(nil)
            window.orderOut(nil)
        }

        require(strip.mouseDownCanMoveWindow,
                "the titlebar strip still lets AppKit move the window with a drag")
        guard let doubleClick = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 40, y: TabRowLayout.height / 2),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 1
        ) else {
            fatalError("FAIL: could not synthesise a titlebar double-click")
        }
        require(doubleClick.clickCount == 2, "the synthetic event is a double-click")

        // Zoom: the shipped preference is installed through the same override seam the app leaves
        // at nil, then the strip's real mouse handler is called.
        ReaderTitlebarDoubleClick.preferenceOverride = "Maximize"
        require(ReaderTitlebarDoubleClick.action == .zoom,
                "the strip resolves Maximize to zoom")
        strip.mouseDown(with: doubleClick)
        require(window.isZoomed,
                "double-clicking the titlebar strip zooms the window when the preference is Maximize")
        strip.mouseDown(with: doubleClick)
        require(!window.isZoomed,
                "a second double-click restores the window (zoom is a toggle)")

        // None: neither state changes, and the frame does not move.
        ReaderTitlebarDoubleClick.preferenceOverride = "None"
        let frameBeforeNone = window.frame
        require(ReaderTitlebarDoubleClick.action == .none,
                "the strip resolves None to no action")
        strip.mouseDown(with: doubleClick)
        pumpRunLoop(seconds: 0.1)
        require(!window.isZoomed && !window.isMiniaturized,
                "double-clicking with the preference set to None neither zooms nor minimises")
        require(window.frame == frameBeforeNone,
                "double-clicking with the preference set to None does not move the window")

        // Minimise: AppKit performs the miniaturise transition on the next run-loop pass.
        ReaderTitlebarDoubleClick.preferenceOverride = "Minimize"
        require(ReaderTitlebarDoubleClick.action == .minimize,
                "the strip resolves Minimize to minimise")
        strip.mouseDown(with: doubleClick)
        let minimised = pumpRunLoop(until: { window.isMiniaturized }, timeout: 2)
        require(minimised,
                "double-clicking the titlebar strip minimises the window when the preference is Minimize")
        require(!window.isZoomed,
                "minimising through the titlebar does not also zoom the window")
        window.deminiaturize(nil)
        _ = pumpRunLoop(until: { !window.isMiniaturized }, timeout: 2)

        // The real preference is read through the shipped path when no override is installed.
        // Reading it is safe; the check only asserts that the value resolves to a known action.
        ReaderTitlebarDoubleClick.preferenceOverride = nil
        require(TitlebarDoubleClickAction.allCases.contains(ReaderTitlebarDoubleClick.action),
                "the installed system preference resolves to a known titlebar action")

        print("PASS: titlebar double-click preference (zoom / minimise / none)")
    }

    // MARK: - Drag to reorder

    /// Tab 3 dragged before tab 1 must become [3, 1, 2] and be the active tab. The geometry is
    /// driven through `TabDragSession`, the same value the gesture feeds, and the commit path is
    /// the same `AppState.moveTab` the drop calls. The cross-window and tear-off paths are in
    /// ``tabWindowMoveChecks(root:)``.
    @MainActor static func tabDragReorderChecks() {
        let width: CGFloat = 100
        let spacing = TabRowLayout.tabSpacing
        let count = 3

        // Geometry: the gap is chosen by the nearest tab midpoint; the indicator sits in the gap.
        require(TabReorder.insertionIndex(forX: 0, tabWidth: width, spacing: spacing, tabCount: count) == 0,
                "a drop at the strip's leading edge inserts before tab 1")
        require(TabReorder.insertionIndex(forX: width * 0.49, tabWidth: width, spacing: spacing, tabCount: count) == 0,
                "the first half of a tab still targets the gap before it")
        require(TabReorder.insertionIndex(forX: width * 0.51, tabWidth: width, spacing: spacing, tabCount: count) == 1,
                "the second half of tab 1 targets the gap after it")
        // The add button starts at 308 + 4 = 312 pt, so 320 is on it.
        require(TabReorder.insertionIndex(forX: 320,
                                          tabWidth: width, spacing: spacing, tabCount: count) == 3,
                "a drop on the add button targets the gap after the last tab")
        require(TabReorder.contentWidth(tabCount: count, tabWidth: width, spacing: spacing) == 308,
                "three 100 pt tabs with 4 pt gaps occupy 308 pt")
        require(TabReorder.indicatorX(insertionIndex: 0, tabWidth: width, spacing: spacing, tabCount: count) == 0,
                "the indicator for gap 0 is at the strip's leading edge")
        require(TabReorder.indicatorX(insertionIndex: 1, tabWidth: width, spacing: spacing, tabCount: count) == 102,
                "the indicator for gap 1 is centred in the 4 pt gap after tab 1")
        require(TabReorder.indicatorX(insertionIndex: 3, tabWidth: width, spacing: spacing, tabCount: count) == 308,
                "the indicator for the final gap is at the end of the last tab")
        require(TabReorder.destinationIndex(sourceIndex: 2, insertionIndex: 0, tabCount: count) == 0,
                "dragging tab 3 to gap 0 lands at index 0")
        require(TabReorder.destinationIndex(sourceIndex: 2, insertionIndex: 2, tabCount: count) == nil,
                "dropping tab 3 into the gap before itself is a no-op")
        require(TabReorder.destinationIndex(sourceIndex: 2, insertionIndex: 3, tabCount: count) == nil,
                "dropping tab 3 into the gap after itself is a no-op")
        require(TabReorder.destinationIndex(sourceIndex: 0, insertionIndex: 1, tabCount: count) == nil,
                "dropping tab 1 into the gap after itself is a no-op")

        // A real state with three tabs. MockEngine is enough: this check is about order, identity
        // and which document is active, not about rasters.
        let state = AppState(engine: MockEngine())
        let a = URL(fileURLWithPath: "/tmp/lyra-tab-drag-a.pdf")
        let b = URL(fileURLWithPath: "/tmp/lyra-tab-drag-b.pdf")
        let c = URL(fileURLWithPath: "/tmp/lyra-tab-drag-c.pdf")
        state.newTab(url: a)
        state.newTab(url: b)
        state.newTab(url: c)
        require(state.tabs.map(\.url.lastPathComponent) == ["lyra-tab-drag-a.pdf",
                                                             "lyra-tab-drag-b.pdf",
                                                             "lyra-tab-drag-c.pdf"],
                "the three tabs start in opening order [1, 2, 3]")
        require(state.activeTabIndex == 2 && state.document?.url == c,
                "the newest tab is the active one before the drag")
        let tabIDs = state.tabs.map(\.id)

        // Local reordering follows the dragged tab's travel, not the pointer's grab offset.
        // A title, leading padding and trailing inset all swap at exactly half a tab width.
        for tabWidth: CGFloat in [96, 180, 250] {
            let pitch = tabWidth + TabRowLayout.tabSpacing
            for grabX in [CGFloat(2), CGFloat(35), tabWidth - 2] {
                for direction: CGFloat in [-1, 1] {
                    let start = pitch + grabX
                    var short = TabDragSession(sourceIndex: 1, tabCount: 3, tabWidth: tabWidth)
                    for travel in [CGFloat(1), tabWidth / 2 - 1, tabWidth / 2] {
                        let delta = direction * travel
                        let location = CGPoint(x: start + delta, y: 22)
                        short.update(location: location, translation: CGSize(width: delta, height: 0))
                        let expected: Int? = travel < tabWidth / 2 ? nil : (direction < 0 ? 0 : 2)
                        require(short.dropDestination == expected,
                                "local reorder uses half-width travel from every grab position (width \(tabWidth), grab \(grabX), delta \(delta))")
                        short.update(location: location)
                        require(short.dropDestination == expected,
                                "mouse-up preserves the half-width reorder target")
                    }
                    short.update(location: CGPoint(x: start, y: 22))
                    require(short.dropDestination == nil, "returning to the starting point cancels the reorder")
                }
            }
        }

        // Drag tab 3 to the leading edge. The session's numbers are what the indicator shows and
        // what the drop commits, so the check drives the release location through it.
        var drag = TabDragSession(sourceIndex: 2, tabCount: count, tabWidth: width, spacing: spacing)
        drag.update(location: CGPoint(x: 10, y: TabRowLayout.height / 2),
                    translation: CGSize(width: -300, height: 0))
        require(drag.isInsideStrip, "the released pointer is still on the strip")
        require(drag.insertionIndex == 0, "dragging tab 3 to the leading edge targets gap 0")
        require(drag.dropDestination == 0, "the drop lands at index 0")
        require(drag.indicatorX == 0, "the insertion indicator is drawn before tab 1")

        let moved = state.moveTab(from: drag.sourceIndex, toInsertionIndex: drag.insertionIndex)
        require(moved, "the drag commits a reorder")
        require(state.tabs.map(\.url.lastPathComponent) == ["lyra-tab-drag-c.pdf",
                                                             "lyra-tab-drag-a.pdf",
                                                             "lyra-tab-drag-b.pdf"],
                "dragging tab 3 before tab 1 reorders the strip to [3, 1, 2]")
        require(state.tabs.map(\.id) == [tabIDs[2], tabIDs[0], tabIDs[1]],
                "the tabs keep their identities across the reorder (no tab is recreated)")
        require(state.activeTabIndex == 0,
                "the dragged tab is active after the drop")
        require(state.document?.url == c,
                "the dragged tab's document is the one on screen after the drop")

        // The order is the model's order, not a transient drag preview: selecting another tab
        // reads the new array, and the reorder survives that operation.
        state.selectTab(1)
        require(state.tabs.map(\.url.lastPathComponent) == ["lyra-tab-drag-c.pdf",
                                                             "lyra-tab-drag-a.pdf",
                                                             "lyra-tab-drag-b.pdf"],
                "the new order persists after another tab is selected")
        require(state.activeTabIndex == 1 && state.document?.url == a,
                "clicking a tab after the reorder still activates the tab at that position")

        // A release left of the strip's leading edge is outside its own strip; the coordinator
        // treats that as a tear-off, not a local reorder (see the window-move checks).
        var leftOfStrip = TabDragSession(sourceIndex: 2, tabCount: count, tabWidth: width, spacing: spacing)
        leftOfStrip.update(location: CGPoint(x: -1, y: TabRowLayout.height / 2))
        require(!leftOfStrip.isInsideStrip,
                "a release left of the tab strip is outside the strip")

        // The close affordance still closes the tab at its reordered position, and the active
        // document moves to the neighbour.
        state.closeTab(1)
        require(state.tabs.map(\.url.lastPathComponent) == ["lyra-tab-drag-c.pdf",
                                                             "lyra-tab-drag-b.pdf"],
                "closing a tab after the reorder still closes the tab at that position")
        require(state.document?.url == b,
                "closing the active tab shows its neighbour after the reorder")

        print("PASS: tab drag reorder ([3, 1, 2]), activation and close")
    }

    // MARK: - Moving tabs between windows

    /// The drop destinations of a tab drag, and what happens to the emptied window:
    ///
    /// * outside every strip: a new window opens with the same document, the same reading
    ///   position and one tab removed from the source; a source with other tabs stays open, a
    ///   single-tab source closes;
    /// * another window's strip: the tab moves there and is inserted at the drop gap; moving the
    ///   last tab out of a window closes that window;
    /// * back into the strip it came from: the same move, in the other direction, with a target
    ///   that still has a tab so no window closes;
    /// * refused (dirty source tab, duplicate destination): the source window and its tab stay
    ///   exactly where they were.
    ///
    /// The check drives the real `TabDragCoordinator` with registered strip rectangles and real
    /// `NSWindow`s, so the screen-point hit test that decides "another window vs. outside every
    /// window" is exercised, not just the state-level move. The source sessions are attached to
    /// their windows the way `ReaderWindowRoot` attaches them, so closing an emptied window is
    /// asserted on the actual `NSWindow` (closed, not hidden) and the registry, not just on the
    /// tabs array.
    @MainActor static func tabWindowMoveChecks(root: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-tab-window-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        func copyFixture(_ name: String, to fileName: String) throws -> URL {
            let destination = scratch.appendingPathComponent(fileName)
            try fileManager.copyItem(
                at: root.appendingPathComponent("tests/fixtures/\(name)"),
                to: destination
            )
            return destination
        }

        let a = try copyFixture("multipage.pdf", to: "window-a.pdf")
        let b = try copyFixture("outlined.pdf", to: "window-b.pdf")
        let c = try copyFixture("multipage.pdf", to: "window-c.pdf")
        let d = try copyFixture("multipage.pdf", to: "window-d.pdf")

        let registry = ReaderWindowRegistry()
        registry.markReady()
        let sourceState = AppState(engine: try RustEngine())
        sourceState.setViewportSize(CGSize(width: 700, height: 500))
        let sourceSession = ReaderSession(state: sourceState, registry: registry)

        // The drop-zone geometry is normally reported by each tab strip's reporter; the check
        // registers plain views at the same kind of frame, so `target(atScreenPoint:)` exercises
        // the same screen/window/scrolled-content mapping it uses in the app. Two real windows
        // give the coordinator a screen rectangle to hit-test against.
        let sourceWindow = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        // This check closes a window through `performClose`, so AppKit must not release it a
        // second time when it closes: the Swift reference owns it, and an autorelease-pool drain
        // after an over-release would crash the rest of the suite.
        sourceWindow.isReleasedWhenClosed = false
        sourceWindow.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let sourceZone = NSView(frame: NSRect(x: 20, y: 380, width: 500, height: TabRowLayout.height))
        sourceWindow.contentView?.addSubview(sourceZone)
        // The app's real wiring: the session owns the window, installs the close delegate and
        // registers itself. Without this a close would be a no-op in a headless check.
        sourceSession.attach(window: sourceWindow)
        registry.noteFocused(sourceSession)

        let targetWindow = NSWindow(
            contentRect: NSRect(x: 820, y: 80, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        targetWindow.isReleasedWhenClosed = false
        targetWindow.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let targetZone = NSView(frame: NSRect(x: 20, y: 380, width: 500, height: TabRowLayout.height))
        targetWindow.contentView?.addSubview(targetZone)
        sourceWindow.orderFront(nil)
        targetWindow.orderFront(nil)

        let coordinator = TabDragCoordinator.shared
        var tornState: AppState?
        // Every destination state that was given the stand-in target strip. Kept so the defer
        // unregisters each one: the single-tab tear-off creates a second destination after the
        // first one has finished with the strip.
        var tornStates: [AppState] = []
        // Windows and sessions made after the first source closes; cleaned up at the end so the
        // process-wide coordinator and registry keep no drop zones from this check.
        var extraWindows: [NSWindow] = []
        var extraSessions: [ReaderSession] = []
        defer {
            coordinator.endDrag()
            coordinator.tearOff = nil
            coordinator.closeEmptiedSource = nil
            coordinator.unregisterDropZone(for: sourceState)
            for state in tornStates { coordinator.unregisterDropZone(for: state) }
            for session in extraSessions { session.close() }
            for window in extraWindows { window.orderOut(nil) }
            registry.newWindow = nil
            sourceWindow.orderOut(nil)
            targetWindow.orderOut(nil)
        }

        /// Re-registers both strips. The real `TabStrip` re-registers on every SwiftUI update,
        /// so this keeps the test's zone counts in step with the tabs after each move. A source
        /// window that has closed is skipped: its strip is no longer a drop target.
        func registerZones() {
            if sourceSession.window != nil {
                coordinator.registerDropZone(
                    for: sourceState, view: sourceZone,
                    tabWidth: 100, tabCount: sourceState.tabs.count)
            } else {
                coordinator.unregisterDropZone(for: sourceState)
            }
            if let tornState {
                coordinator.registerDropZone(
                    for: tornState, view: targetZone,
                    tabWidth: 100, tabCount: tornState.tabs.count)
            }
        }

        /// A screen point at content `x` of a zone view's strip.
        func point(in zone: NSView, contentX: CGFloat) -> CGPoint {
            guard let window = zone.window else { return .zero }
            let rect = window.convertToScreen(zone.convert(zone.bounds, to: nil))
            return CGPoint(x: rect.minX + contentX, y: rect.midY)
        }
        /// A screen point nowhere near either window.
        let outsideEveryStrip = CGPoint(x: -20_000, y: -20_000)

        // 1. Reorder through the coordinator: over the source strip, the local insertion wins.
        sourceState.newTab(url: a)
        sourceState.newTab(url: b)
        registerZones()
        sourceState.selectTab(0)
        coordinator.beginDrag()
        require(coordinator.finishDrag(
            source: sourceState, sourceIndex: 1, localInsertionIndex: 0,
            screenPoint: point(in: sourceZone, contentX: 0)) == .reordered,
            "a release over the source strip reorders through the coordinator")
        require(sourceState.tabs.map(\.url.lastPathComponent) == ["window-b.pdf", "window-a.pdf"],
                "the coordinator reorder moved tab 2 before tab 1")
        sourceState.moveTab(from: 0, toInsertionIndex: 2)
        require(sourceState.tabs.map(\.url.lastPathComponent) == ["window-a.pdf", "window-b.pdf"],
                "the reorder can be put back for the move checks")
        registerZones()

        // 2. Tear a tab out of a two-tab window. The new window opens with the same document and
        //    reading position; the source keeps its other tab and stays open.
        sourceState.selectTab(1)
        sourceState.gotoPage(1)
        let scrollBeforeTearOff = sourceState.scrollYPt
        require(scrollBeforeTearOff > 0, "the torn-off tab starts scrolled away from the top")
        var createdStates: [AppState] = []
        registry.newWindow = {
            let state = AppState(engine: try! RustEngine())
            state.setViewportSize(CGSize(width: 700, height: 500))
            let session = ReaderSession(state: state, registry: registry)
            createdStates.append(state)
            tornState = state
            tornStates.append(state)
            registry.register(session)
        }
        // The app's own wiring, not a test-local closure: the session installs the registry
        // actions the coordinator calls, including the one that closes an emptied source window.
        sourceSession.installTabDragActions()
        coordinator.beginDrag()
        require(coordinator.finishDrag(
            source: sourceState, sourceIndex: 1, localInsertionIndex: 1,
            screenPoint: outsideEveryStrip) == .toreOff,
            "a release outside every strip tears the tab into a new window")
        require(createdStates.count == 1,
                "the tear-off created exactly one new window")
        guard let torn = tornState else {
            fatalError("FAIL: the tear-off created no state")
        }
        require(torn.tabs.count == 1 && torn.tabs[0].url.lastPathComponent == "window-b.pdf",
                "the new window holds exactly the torn-off tab")
        require(torn.document?.url?.lastPathComponent == "window-b.pdf",
                "the new window shows the same document")
        require(abs(torn.scrollYPt - scrollBeforeTearOff) < 0.5,
                "the new window keeps the reading position (scroll \(torn.scrollYPt) vs \(scrollBeforeTearOff))")
        require(sourceState.tabs.map(\.url.lastPathComponent) == ["window-a.pdf"],
                "the source window no longer has the torn-off tab")
        require(sourceState.document?.url?.lastPathComponent == "window-a.pdf",
                "the source window switched to its remaining tab")
        require(sourceWindow.isVisible && sourceSession.window === sourceWindow
                    && registry.sessions.contains(where: { $0 === sourceSession }),
                "a two-tab source keeps its window open with the remaining tab")
        require(registry.pendingTransferCount == 0,
                "no torn-off tab is left waiting for its window")
        registerZones()

        // 3. Give the torn-off window a second tab, then drag its original tab back: the same
        //    cross-window path in reverse. The target keeps a tab, so no window closes here.
        torn.newTab(url: c)
        registerZones()
        guard let movedBackIndex = torn.tabs.firstIndex(where: {
            $0.url.lastPathComponent == "window-b.pdf"
        }) else {
            fatalError("FAIL: the torn-off tab is not in the target window")
        }
        coordinator.beginDrag()
        require(coordinator.finishDrag(
            source: torn, sourceIndex: movedBackIndex, localInsertionIndex: 0,
            screenPoint: point(in: sourceZone, contentX: 0)) == .moved,
            "dragging the tab back onto the original strip moves it back")
        require(sourceState.tabs.map(\.url.lastPathComponent) == ["window-b.pdf", "window-a.pdf"],
                "the tab returned to the original window at the drop gap")
        require(sourceState.document?.url?.lastPathComponent == "window-b.pdf",
                "the returned document is on screen in the original window")
        require(torn.tabs.map(\.url.lastPathComponent) == ["window-c.pdf"],
                "the target window no longer has the returned tab and keeps its own")
        require(abs(sourceState.scrollYPt - scrollBeforeTearOff) < 0.5,
                "the returned tab keeps its reading position")
        require(allTabURLs(in: [sourceState, torn]).filter { $0 == "window-b.pdf" }.count == 1,
                "the returned document is open in exactly one window")

        // 4. Move the source's last tab onto the other window's strip. The drop succeeds and the
        //    now-empty source window must close through the normal window-close path; the
        //    destination keeps its tab and gains the moved one.
        sourceState.closeTab(0)
        require(sourceState.tabs.map(\.url.lastPathComponent) == ["window-a.pdf"],
                "the source has one tab left for the emptied-window check")
        registerZones()
        sourceState.gotoPage(1)
        let scrollOfA = sourceState.scrollYPt
        require(scrollOfA > 0, "the tab to move is scrolled away from the top")
        let targetTabsBeforeMove = torn.tabs.map(\.url.lastPathComponent)
        let targetSessionsBeforeMove = registry.sessions.count
        coordinator.beginDrag()
        require(coordinator.finishDrag(
            source: sourceState, sourceIndex: 0, localInsertionIndex: 0,
            screenPoint: point(in: targetZone, contentX: 110)) == .moved,
            "a release over another window's strip moves the last tab there")
        require(torn.tabs.map(\.url.lastPathComponent)
                    == targetTabsBeforeMove + ["window-a.pdf"],
                "the moved tab is inserted at the drop gap in the target window")
        require(torn.activeTabIndex == torn.tabs.count - 1
                    && torn.document?.url?.lastPathComponent == "window-a.pdf",
                "the moved tab is active in the target window")
        require(abs(torn.scrollYPt - scrollOfA) < 0.5,
                "the moved tab keeps its reading position")
        require(sourceState.tabs.isEmpty && sourceState.document == nil,
                "the source window gave its last tab up")
        require(!sourceState.contentCloseRequested,
                "the emptied source closes without a Save / Discard prompt")
        require(allTabURLs(in: [sourceState, torn]).filter { $0 == "window-a.pdf" }.count == 1,
                "the moved document is open in exactly one window")
        try await eventually("the emptied source window closes after its last tab moved out", {
            !sourceWindow.isVisible
                && sourceSession.window == nil
                && !registry.sessions.contains(where: { $0 === sourceSession })
        })
        require(registry.sessions.count == targetSessionsBeforeMove - 1,
                "only the emptied source session left the registry")
        require(registry.sessions.contains(where: { $0.state === torn }),
                "the destination window is untouched and still open")
        registerZones()

        // 5. Refused moves leave the source window and its tab intact.
        //
        // 5a. A dirty tab is refused before a window is even asked for.
        let refusedState = AppState(engine: try RustEngine())
        refusedState.setViewportSize(CGSize(width: 700, height: 500))
        let refusedSession = ReaderSession(state: refusedState, registry: registry)
        let refusedWindow = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        refusedWindow.isReleasedWhenClosed = false
        refusedWindow.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        refusedSession.attach(window: refusedWindow)
        refusedWindow.orderFront(nil)
        extraWindows.append(refusedWindow)
        extraSessions.append(refusedSession)
        refusedState.newTab(url: b)
        refusedState.contentTextEditing = true
        let blockedTabs = refusedState.tabs.map(\.url.lastPathComponent)
        let windowsBeforeBlocked = registry.sessions.count
        coordinator.beginDrag()
        let blockedOutcome = coordinator.finishDrag(
            source: refusedState, sourceIndex: 0, localInsertionIndex: 0,
            screenPoint: outsideEveryStrip)
        refusedState.contentTextEditing = false
        guard case let .refused(reason) = blockedOutcome else {
            fatalError("FAIL: moving a dirty tab was not refused: \(blockedOutcome)")
        }
        require(reason.contains("unsaved changes"),
                "the refusal names unsaved changes: \(reason)")
        require(refusedState.tabs.map(\.url.lastPathComponent) == blockedTabs,
                "a refused move leaves the source tab in place")
        require(registry.sessions.count == windowsBeforeBlocked
                    && refusedWindow.isVisible && refusedSession.window === refusedWindow,
                "a refused move creates no window and leaves the source window open")

        // 5b. A destination that already has the document refuses the move: accepting it would
        //     put the same file in two windows. The source window and tab stay exactly as they
        //     were.
        refusedState.newTab(url: a)
        let targetTabsWithDuplicate = torn.tabs.map(\.url.lastPathComponent)
        let sourceTabsWithDuplicate = refusedState.tabs.map(\.url.lastPathComponent)
        coordinator.beginDrag()
        let duplicateOutcome = coordinator.finishDrag(
            source: refusedState, sourceIndex: refusedState.tabs.count - 1,
            localInsertionIndex: 0, screenPoint: point(in: targetZone, contentX: 0))
        guard case let .refused(duplicateReason) = duplicateOutcome else {
            fatalError("FAIL: a duplicate document was not refused: \(duplicateOutcome)")
        }
        require(duplicateReason.contains("already open in the other window"),
                "the duplicate refusal names the other window: \(duplicateReason)")
        require(refusedState.tabs.map(\.url.lastPathComponent) == sourceTabsWithDuplicate,
                "a duplicate refusal leaves the source tab in place")
        require(torn.tabs.map(\.url.lastPathComponent) == targetTabsWithDuplicate,
                "a duplicate refusal leaves the target window unchanged")
        require(refusedWindow.isVisible && refusedSession.window === refusedWindow
                    && registry.sessions.contains(where: { $0 === refusedSession }),
                "a duplicate refusal leaves the source window open")

        // 6. Escape cancels: no order change, no window, no document opened, no window closed.
        let windowsBeforeEscape = registry.sessions.count
        let sourceTabsBeforeEscape = refusedState.tabs.map(\.url.lastPathComponent)
        let targetTabsBeforeEscape = torn.tabs.map(\.url.lastPathComponent)
        let tearOffsBeforeEscape = registry.newWindowRequestCount
        let cancelsBeforeEscape = coordinator.cancelGeneration
        coordinator.beginDrag()
        coordinator.cancelDrag()
        require(coordinator.cancelGeneration == cancelsBeforeEscape + 1,
                "Escape marks the drag cancelled")
        require(coordinator.finishDrag(
            source: refusedState, sourceIndex: 0, localInsertionIndex: 0,
            screenPoint: point(in: targetZone, contentX: 0)) == .cancelled,
            "a cancelled drag commits nothing even over a valid target")
        require(refusedState.tabs.map(\.url.lastPathComponent) == sourceTabsBeforeEscape
                    && torn.tabs.map(\.url.lastPathComponent) == targetTabsBeforeEscape,
                "a cancelled drag changes neither window's tabs")
        require(registry.sessions.count == windowsBeforeEscape
                    && registry.newWindowRequestCount == tearOffsBeforeEscape,
                "a cancelled drag creates no window")
        require(refusedWindow.isVisible, "a cancelled drag closes no window")
        require(!coordinator.isDragging, "the cancelled drag is over")

        // 7. Tear off a single-tab window: the source window closes and the new window gets both
        //    the document and the tab.
        let loneState = AppState(engine: try RustEngine())
        loneState.setViewportSize(CGSize(width: 700, height: 500))
        let loneSession = ReaderSession(state: loneState, registry: registry)
        let loneWindow = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        loneWindow.isReleasedWhenClosed = false
        loneWindow.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        loneSession.attach(window: loneWindow)
        loneWindow.orderFront(nil)
        extraWindows.append(loneWindow)
        extraSessions.append(loneSession)
        loneState.newTab(url: d)
        loneState.gotoPage(1)
        let scrollOfD = loneState.scrollYPt
        require(scrollOfD > 0, "the single tab starts scrolled away from the top")
        let createdBeforeLoneTearOff = createdStates.count
        let sessionsBeforeLoneTearOff = registry.sessions.count
        coordinator.beginDrag()
        require(coordinator.finishDrag(
            source: loneState, sourceIndex: 0, localInsertionIndex: 0,
            screenPoint: outsideEveryStrip) == .toreOff,
            "a release outside every strip tears off the only tab")
        require(createdStates.count == createdBeforeLoneTearOff + 1,
                "the single-tab tear-off created exactly one new window")
        guard let loneDestination = createdStates.last else {
            fatalError("FAIL: the single-tab tear-off created no state")
        }
        require(loneDestination.tabs.count == 1
                    && loneDestination.tabs[0].url.lastPathComponent == "window-d.pdf",
                "the destination holds the torn-off tab")
        require(loneDestination.document?.url?.lastPathComponent == "window-d.pdf",
                "the destination shows the torn-off document")
        require(abs(loneDestination.scrollYPt - scrollOfD) < 0.5,
                "the destination keeps the reading position")
        require(loneState.tabs.isEmpty && loneState.document == nil,
                "the single-tab source gave its tab up")
        require(!loneState.contentCloseRequested,
                "a single-tab tear-off closes the source without a Save / Discard prompt")
        try await eventually("the single-tab source window closes after its last tab tore off", {
            !loneWindow.isVisible
                && loneSession.window == nil
                && !registry.sessions.contains(where: { $0 === loneSession })
        })
        require(registry.sessions.count == sessionsBeforeLoneTearOff,
                "the closed source is replaced by the destination, so one window remains")
        require(registry.sessions.contains(where: { $0.state === loneDestination }),
                "the destination window is registered and open")

        print("PASS: tab tear-off, cross-window move, emptied-source close, "
                + "two-tab keep-open, Escape and refused moves")
    }

    /// Every tab URL, by file name, in a set of window states. Used to prove a moved document is
    /// open in exactly one of them.
    @MainActor private static func allTabURLs(in states: [AppState]) -> [String] {
        states.flatMap { $0.tabs.map(\.url.lastPathComponent) }
    }

    // MARK: - Run-loop helpers

    @MainActor private static func pumpRunLoop(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
    }

    /// Runs the main loop in short slices until `condition` holds or `timeout` elapses. AppKit
    /// performs the miniaturise transition asynchronously, so the assertion waits for the state
    /// the window will settle in rather than the state it has inside `mouseDown`.
    @MainActor private static func pumpRunLoop(
        until condition: () -> Bool,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            _ = RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
