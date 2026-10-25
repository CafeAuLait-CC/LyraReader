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

    /// The three drop destinations of a tab drag:
    ///
    /// * outside every strip: a new window opens with the same document, the same reading
    ///   position and one tab removed from the source;
    /// * another window's strip: the tab moves there and is inserted at the drop gap;
    /// * back into the strip it came from: the same move, in the other direction.
    ///
    /// The check drives the real `TabDragCoordinator` with registered strip rectangles and real
    /// `NSWindow`s, so the screen-point hit test that decides "another window vs. outside every
    /// window" is exercised, not just the state-level move. Escape and a dirty source tab are
    /// asserted to change nothing.
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

        let registry = ReaderWindowRegistry()
        registry.markReady()
        let sourceState = AppState(engine: try RustEngine())
        sourceState.setViewportSize(CGSize(width: 700, height: 500))
        let sourceSession = ReaderSession(state: sourceState, registry: registry)
        registry.register(sourceSession)
        registry.noteFocused(sourceSession)

        // The drop-zone geometry is normally reported by each tab strip's reporter; the check
        // registers plain views at the same kind of frame, so `target(atScreenPoint:)` exercises
        // the same screen/window/scrolled-content mapping it uses in the app. Two real windows
        // give the coordinator a screen rectangle to hit-test against.
        let sourceWindow = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 700, height: 500),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        sourceWindow.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let sourceZone = NSView(frame: NSRect(x: 20, y: 380, width: 500, height: TabRowLayout.height))
        sourceWindow.contentView?.addSubview(sourceZone)

        let targetWindow = NSWindow(
            contentRect: NSRect(x: 820, y: 80, width: 700, height: 500),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        targetWindow.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let targetZone = NSView(frame: NSRect(x: 20, y: 380, width: 500, height: TabRowLayout.height))
        targetWindow.contentView?.addSubview(targetZone)
        sourceWindow.orderFront(nil)
        targetWindow.orderFront(nil)

        let coordinator = TabDragCoordinator.shared
        var tornState: AppState?
        defer {
            coordinator.endDrag()
            coordinator.tearOff = nil
            coordinator.unregisterDropZone(for: sourceState)
            if let tornState { coordinator.unregisterDropZone(for: tornState) }
            registry.newWindow = nil
            sourceWindow.orderOut(nil)
            targetWindow.orderOut(nil)
        }

        /// Re-registers both strips. The real `TabStrip` re-registers on every SwiftUI update,
        /// so this keeps the test's zone counts in step with the tabs after each move.
        func registerZones() {
            coordinator.registerDropZone(
                for: sourceState, view: sourceZone,
                tabWidth: 100, tabCount: sourceState.tabs.count)
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

        // 2. Tear off outside every strip. Keep b active with a non-zero scroll offset so the new
        //    window has a reading position to preserve.
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
            registry.register(session)
        }
        coordinator.tearOff = { transfer, source in
            registry.requestNewWindow(moving: transfer, from: source)
        }
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
        require(registry.pendingTransferCount == 0,
                "no torn-off tab is left waiting for its window")
        registerZones()

        // 3. Move across windows: drag the source's only tab onto the torn-off window's strip, at
        //    the gap after its tab. The document must exist in exactly one window afterwards.
        sourceState.selectTab(0)
        sourceState.gotoPage(1)
        let scrollOfA = sourceState.scrollYPt
        require(scrollOfA > 0, "the tab to move is scrolled away from the top")
        let targetTabsBefore = torn.tabs.map(\.url.lastPathComponent)
        coordinator.beginDrag()
        require(coordinator.finishDrag(
            source: sourceState, sourceIndex: 0, localInsertionIndex: 0,
            screenPoint: point(in: targetZone, contentX: 110)) == .moved,
            "a release over another window's strip moves the tab there")
        require(torn.tabs.map(\.url.lastPathComponent)
                    == [targetTabsBefore[0], "window-a.pdf"],
                "the moved tab is inserted at the drop gap in the target window")
        require(torn.activeTabIndex == 1
                    && torn.document?.url?.lastPathComponent == "window-a.pdf",
                "the moved tab is active in the target window")
        require(abs(torn.scrollYPt - scrollOfA) < 0.5,
                "the moved tab keeps its reading position")
        require(sourceState.tabs.isEmpty && sourceState.document == nil,
                "the source window gave the tab up")
        require(allTabURLs(in: [sourceState, torn]).filter { $0 == "window-a.pdf" }.count == 1,
                "the moved document is open in exactly one window")

        // 4. Drag it back to the original window: the same cross-window path in reverse.
        registerZones()
        guard let movedIndex = torn.tabs.firstIndex(where: {
            $0.url.lastPathComponent == "window-a.pdf"
        }) else {
            fatalError("FAIL: the moved tab is not in the target window")
        }
        coordinator.beginDrag()
        require(coordinator.finishDrag(
            source: torn, sourceIndex: movedIndex, localInsertionIndex: 0,
            screenPoint: point(in: sourceZone, contentX: 0)) == .moved,
            "dragging the tab back onto the original strip moves it back")
        require(sourceState.tabs.map(\.url.lastPathComponent) == ["window-a.pdf"],
                "the tab returned to the original window")
        require(sourceState.document?.url?.lastPathComponent == "window-a.pdf",
                "the returned document is on screen in the original window")
        require(!torn.tabs.contains { $0.url.lastPathComponent == "window-a.pdf" },
                "the target window no longer has the returned tab")
        require(abs(sourceState.scrollYPt - scrollOfA) < 0.5,
                "the returned tab keeps its reading position")
        require(allTabURLs(in: [sourceState, torn]).filter { $0 == "window-a.pdf" }.count == 1,
                "the returned document is open in exactly one window")

        // 5. Escape cancels: no order change, no window, no document opened.
        let windowsBeforeEscape = registry.sessions.count
        let sourceTabsBeforeEscape = sourceState.tabs.map(\.url.lastPathComponent)
        let targetTabsBeforeEscape = torn.tabs.map(\.url.lastPathComponent)
        let tearOffsBeforeEscape = registry.newWindowRequestCount
        let cancelsBeforeEscape = coordinator.cancelGeneration
        coordinator.beginDrag()
        coordinator.cancelDrag()
        require(coordinator.cancelGeneration == cancelsBeforeEscape + 1,
                "Escape marks the drag cancelled")
        require(coordinator.finishDrag(
            source: sourceState, sourceIndex: 0, localInsertionIndex: 0,
            screenPoint: point(in: targetZone, contentX: 0)) == .cancelled,
            "a cancelled drag commits nothing even over a valid target")
        require(sourceState.tabs.map(\.url.lastPathComponent) == sourceTabsBeforeEscape
                    && torn.tabs.map(\.url.lastPathComponent) == targetTabsBeforeEscape,
                "a cancelled drag changes neither window's tabs")
        require(registry.sessions.count == windowsBeforeEscape
                    && registry.newWindowRequestCount == tearOffsBeforeEscape,
                "a cancelled drag creates no window")
        require(!coordinator.isDragging, "the cancelled drag is over")

        // 6. Unsaved changes block the move, with a reason and no window. `contentTextEditing` is
        //    part of `hasUnsavedDocumentChanges`; the same guard covers page, form and annotation
        //    writes. The tab stays in its window.
        sourceState.contentTextEditing = true
        let blockedTabs = sourceState.tabs.map(\.url.lastPathComponent)
        let windowsBeforeBlocked = registry.sessions.count
        coordinator.beginDrag()
        let blockedOutcome = coordinator.finishDrag(
            source: sourceState, sourceIndex: 0, localInsertionIndex: 0,
            screenPoint: outsideEveryStrip)
        sourceState.contentTextEditing = false
        guard case let .refused(reason) = blockedOutcome else {
            fatalError("FAIL: moving a dirty tab was not refused: \(blockedOutcome)")
        }
        require(reason.contains("unsaved changes"),
                "the refusal names unsaved changes: \(reason)")
        require(sourceState.tabs.map(\.url.lastPathComponent) == blockedTabs,
                "a refused move leaves the source tab in place")
        require(registry.sessions.count == windowsBeforeBlocked,
                "a refused move creates no window")

        print("PASS: tab tear-off, cross-window move, move back, Escape cancel and dirty-tab refusal")
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
