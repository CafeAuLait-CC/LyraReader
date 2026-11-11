import AppKit
import LyraReaderKit
import SwiftUI

/// Main-thread flags for AppKit's asynchronous fullscreen transition.
///
/// `styleMask.contains(.fullScreen)` flips during the transition, so toggling back at that moment
/// is refused with "not in fullscreen state". The window's own notifications mark the real end.
@MainActor
private final class ViewportFullscreenTransition {
    var entered = false
    var exited = false
}

/// Fits undersized pages in documents of any length, through state and real-window events.
extension ReaderChecks {
    /// Deterministic policy scenarios, plus the real-window resize/fullscreen scenario.
    ///
    /// The window scenario attempts fullscreen; a runner whose window server refuses the
    /// transition records a NOTE and leaves the resize path as the evidence for that run.
    @MainActor static func viewportFitChecks(
        singlePage source: URL,
        multipage multipageSource: URL
    ) async throws {
        let fixtures = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-viewport-fit-\(UUID())")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtures) }
        let singlePage = fixtures.appendingPathComponent("single.pdf")
        let multipage = fixtures.appendingPathComponent("multi.pdf")
        try FileManager.default.copyItem(at: source, to: singlePage)
        try FileManager.default.copyItem(at: multipageSource, to: multipage)

        try ordinaryEdgeChecks(singlePage: singlePage, multipage: multipage)
        try await singlePageResizeChecks(fixture: singlePage)
        try await multiPageResizeChecks(fixture: multipage)
        try fittedTabChecks(singlePage: singlePage, multipage: multipage)
        try await windowResizeChecks(multipage: multipage)
    }

    /// The document edges keep the preset inset in view points at every ordinary zoom.
    @MainActor
    private static func requireDocumentEdges(_ state: AppState, viewport: CGSize) {
        state.scroll(toFraction: 0)
        guard let first = state.canvasPageFrames.first(where: { $0.index == 0 }) else {
            fatalError("FAIL: document top has no first-page frame")
        }
        let top = (first.topPt - state.scrollYPt) * state.zoomFactor
        require(abs(top - AppState.zoomPresetInsetPt) < 0.1,
                "ordinary document top leaves the screen-space inset (\(top))")
        require(state.scrollYPt == 0 && state.scrollFraction == 0,
                "ordinary top padding is content with a zero scroll origin")
        state.scrollByWheelStep(-1_000_000)
        require(state.scrollYPt == 0, "wheel scrolling stops at the padded top")
        state.scroll(toFraction: 1)
        guard let last = state.canvasPageFrames.first(where: { $0.index == (state.document?.pageCount ?? 1) - 1 }) else {
            fatalError("FAIL: document bottom has no last-page frame")
        }
        let bottom = viewport.height - (last.topPt + last.heightPt - state.scrollYPt) * state.zoomFactor
        require(bottom >= AppState.zoomPresetInsetPt - 0.1,
                "ordinary document bottom retains at least the inset (\(bottom))")
        if state.hasScrollableContent {
            require(abs(bottom - AppState.zoomPresetInsetPt) < 0.1 && abs(state.scrollFraction - 1) < 1e-9,
                    "the scrollbar reaches the padded document bottom exactly")
        }
        let parked = state.scrollYPt
        state.scrollByWheelStep(1_000_000)
        require(abs(state.scrollYPt - parked) < 0.01, "wheel scrolling stops at the padded bottom")
        state.gotoPage(0)
        require(state.scrollYPt == 0, "Go to first page preserves the top inset")
        state.scroll(toFraction: 1)
    }

    @MainActor
    private static func ordinaryEdgeChecks(singlePage: URL, multipage: URL) throws {
        for height: CGFloat in [500, 1350] {
            for density: CGFloat in [380, 720, 1080] {
                let viewport = CGSize(width: 800, height: height)
                let calibration = DisplayCalibration.resolve(logicalWidthPt: density, physicalWidthMm: 254)
                for mode: ReaderLayoutMode in [.continuous, .facing] {
                    let state = AppState(engine: try RustEngine())
                    state.setViewportSize(viewport)
                    state.setDisplayCalibration(calibration)
                    require(state.newTab(url: multipage), "ordinary edge fixture opens")
                    state.setLayoutMode(mode)
                    for zoom in [25, 100, 250] {
                        state.zoomActual()
                        while state.zoomPercent > zoom { state.zoomOut() }
                        while state.zoomPercent < zoom { state.zoomIn() }
                        requireDocumentEdges(state, viewport: viewport)
                    }
                    state.zoomFitWidth()
                    requireDocumentEdges(state, viewport: viewport)
                }
            }
            let single = AppState(engine: try RustEngine())
            single.setViewportSize(CGSize(width: 800, height: height))
            require(single.open(url: singlePage), "ordinary single-page fixture opens")
            single.zoomActual()
            requireDocumentEdges(single, viewport: CGSize(width: 800, height: height))
        }

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 800, height: 500))
        require(state.open(url: multipage), "ordinary saved-position fixture opens")
        state.zoomActual()
        state.gotoPage(1)
        state.scroll(byScreenPoints: 123)
        let canonical = state.scrollYPt - AppState.zoomPresetInsetPt / state.zoomFactor
        require(state.flushPendingPositionSave(), "ordinary position saves")
        let key = "readingPosition:" + multipage.path
        require(abs(UserDefaults.standard.double(forKey: key) - canonical) < 0.1,
                "saved ordinary position excludes view-dependent edge padding")
        let restored = AppState(engine: try RustEngine())
        restored.setViewportSize(CGSize(width: 800, height: 500))
        restored.setDisplayCalibration(DisplayCalibration.resolve(logicalWidthPt: 1080, physicalWidthMm: 254))
        require(restored.open(url: multipage), "ordinary saved position reopens at another display density")
        require(abs(restored.scrollYPt - AppState.zoomPresetInsetPt / restored.zoomFactor - canonical) < 0.1,
                "restored position keeps the same paper point across display densities")
    }

    /// Assert the actual drawing transform, including first/last page clamps and adjacent paper.
    @MainActor
    private static func requireFittedPage(_ state: AppState, page: Int, viewport: CGSize) {
        let frames = state.canvasPageFrames
        guard let frame = frames.first(where: { $0.index == page }) else {
            fatalError("FAIL: fitted page has no canvas frame")
        }
        let top = (frame.topPt - state.scrollYPt) * state.zoomFactor
        let bottom = top + frame.heightPt * state.zoomFactor
        require(top >= AppState.zoomPresetInsetPt - 0.1, "Fit Page leaves space above the paper (\(top))")
        require(viewport.height - bottom >= AppState.zoomPresetInsetPt - 0.1,
                "Fit Page leaves space below the paper (\(viewport.height - bottom))")
        require(abs(top - (viewport.height - bottom)) < 0.5, "Fit Page balances the vertical space")
        require(frame.widthPt * state.zoomFactor <= viewport.width - 2 * AppState.zoomPresetInsetPt + 0.5,
                "Fit Page includes the complete width")
        require(state.currentPage == page + 1, "the leading blank belongs to fitted page \(page + 1), got \(state.currentPage)")
        for other in frames where abs(other.topPt - frame.topPt) > 0.5 {
            let otherTop = (other.topPt - state.scrollYPt) * state.zoomFactor
            let otherBottom = otherTop + other.heightPt * state.zoomFactor
            require(otherBottom <= 0.5 || otherTop >= viewport.height - 0.5,
                    "Fit Page excludes adjacent paper slivers (page \(other.index), \(otherTop)...\(otherBottom))")
        }
    }

    @MainActor
    private static func singlePageResizeChecks(fixture: URL) async throws {
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.newTab(url: fixture), "single-page fit fixture opens")
        let viewport = CGSize(width: 760, height: 900)
        state.setViewportSize(viewport)
        require(state.zoomPercent == 104, "single-page resize adopts the floored fit")
        requireFittedPage(state, page: 0, viewport: viewport)
        // The fitted blank above the first page is content-space padding, not a negative scroll
        // origin. A negative `scrollYPt` would put the scrollbar and the saved position out of
        // range, so the first page is the case that proves the sign.
        require(state.scrollYPt >= 0, "Fit Page keeps the offset non-negative on the first page")
        state.setViewportSize(CGSize(width: 760, height: 899.4))
        requireFittedPage(state, page: 0, viewport: CGSize(width: 760, height: 899.4))
        require(state.scrollYPt >= 0, "a height nudge keeps the fitted offset non-negative")
        let offset = state.scrollYPt
        state.zoomFitPage()
        require(abs(state.scrollYPt - offset) < 0.01, "explicit Fit Page and resize agree")
        state.zoomOut()
        require(state.zoomPercent == 94, "manual zoom-out remains available")
        state.setViewportSize(CGSize(width: 760, height: 901))
        require(state.zoomPercent == 105, "a later height change re-fits")
        state.zoomIn()
        state.setViewportSize(CGSize(width: 760, height: 850))
        require(state.zoomPercent == 115, "an above-fit zoom survives shrinking")
    }

    @MainActor
    private static func multiPageResizeChecks(fixture: URL) async throws {
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.newTab(url: fixture), "multi-page fit fixture opens")
        let viewport = CGSize(width: 760, height: 900)
        for page in 0..<3 {
            state.zoomActual()
            state.gotoPage(page)
            state.zoomFitPage()
            requireFittedPage(state, page: page, viewport: CGSize(width: 700, height: 500))
            require(state.scrollYPt >= 0, "Fit Page keeps page \(page + 1)'s offset non-negative")
            let offset = state.scrollYPt
            let percent = state.zoomPercent
            state.zoomFitPage()
            require(state.zoomPercent == percent && abs(state.scrollYPt - offset) < 0.01,
                    "Fit Page is idempotent on page \(page + 1)")
        }
        // The previous implementation explicitly kept 25% for multi-page documents.
        state.zoomActual()
        state.gotoPage(1)
        while state.zoomPercent > AppState.minimumZoomPercent { state.zoomOut() }
        state.setViewportSize(viewport)
        require(state.zoomPercent == 104, "multi-page resize replaces undersized zoom")
        // Zooming out can change the current page before the resize; the fit must keep that page.
        requireFittedPage(state, page: state.currentPage - 1, viewport: viewport)
        require(state.scrollYPt >= 0, "a multi-page resize keeps the fitted offset non-negative")
        let fitted = state.zoomPercent
        state.zoomOut()
        state.setViewportSize(CGSize(width: 800, height: 900))
        require(state.zoomPercent == fitted - 10, "width-only panel movement leaves manual zoom alone")
        state.setViewportSize(CGSize(width: 800, height: 901))
        require(state.zoomPercent == 105, "a subsequent height change re-fits a multi-page document")
        requireFittedPage(state, page: state.currentPage - 1, viewport: CGSize(width: 800, height: 901))
        // A zero preferred page gap must not reintroduce neighboring paper.
        state.setPageGap(0)
        for page in 0..<3 {
            state.gotoPage(page)
            state.zoomFitPage()
            requireFittedPage(state, page: page, viewport: CGSize(width: 800, height: 901))
        }
        state.gotoPage(1)
        state.zoomFitPage()
        let fittedScroll = state.scrollYPt
        state.setPageGap(state.pageGapPt)
        state.setLayoutMode(state.layoutMode)
        require(abs(state.scrollYPt - fittedScroll) < 0.01, "unchanged preferences preserve fitted spacing")
        requireFittedPage(state, page: 1, viewport: CGSize(width: 800, height: 901))
        let anchorViewY: CGFloat = 300
        let oldFrame = state.canvasPageFrames.first { $0.index == 1 }!
        let localY = anchorViewY / state.zoomFactor + state.scrollYPt - oldFrame.topPt
        require(state.zoomByPinch(0.1, anchorViewY: anchorViewY), "pinch zoom leaves Fit Page")
        let newFrame = state.canvasPageFrames.first { $0.index == 1 }!
        let newLocalY = anchorViewY / state.zoomFactor + state.scrollYPt - newFrame.topPt
        require(abs(localY - newLocalY) < 0.5, "leaving fitted spacing preserves the point under the pointer")
        state.setLayoutMode(.facing)
        state.gotoPage(1)
        state.zoomFitPage()
        requireFittedPage(state, page: 1, viewport: CGSize(width: 800, height: 901))
        let row = state.canvasPageFrames.filter { $0.index == 1 || $0.index == 2 }
        let width = (row.map { $0.leftPt + $0.widthPt }.max() ?? 0) - (row.map(\.leftPt).min() ?? 0)
        require(width * state.zoomFactor <= 800 - 2 * AppState.zoomPresetInsetPt + 0.5,
                "the full facing spread fits horizontally")
    }

    @MainActor
    private static func fittedTabChecks(singlePage: URL, multipage: URL) throws {
        let state = AppState(engine: try RustEngine())
        let viewport = CGSize(width: 800, height: 900)
        state.setViewportSize(viewport)
        require(state.newTab(url: multipage), "fitted tab opens")
        state.gotoPage(1)
        state.zoomFitPage()
        requireFittedPage(state, page: 1, viewport: viewport)
        state.jumpFromPreview(to: 2)
        require(state.goBack(), "Back returns from a fitted-page jump")
        requireFittedPage(state, page: 1, viewport: viewport)
        state.scroll(toFraction: 0)
        requireFittedPage(state, page: 0, viewport: viewport)
        require(state.scrollYPt >= 0, "the fitted top of the document is offset zero or more")
        state.scroll(toFraction: 1)
        requireFittedPage(state, page: 2, viewport: viewport)
        require(state.scrollYPt >= 0, "the fitted end of the document is offset zero or more")
        require(state.flushPendingPositionSave(), "fitted reading position saves")
        let key = "readingPosition:" + multipage.path
        let saved = UserDefaults.standard.double(forKey: key)
        let expected = state.engine.pageTopPt(2, gapPt: state.pageGapPt)
        require(abs(saved - expected) < 0.5, "saved position excludes temporary fitted-row gaps")
        defer { UserDefaults.standard.removeObject(forKey: key) }
        require(state.newTab(url: singlePage), "a second tab opens after Fit Page")
        state.selectTab(0)
        requireFittedPage(state, page: 2, viewport: viewport)
        state.selectTab(1)
        state.zoomOut()
        let manual = state.zoomPercent
        state.selectTab(0)
        require(state.zoomPercent == manual, "returning to a fitted tab keeps the current manual zoom")
        require(abs(state.contentHeightPt - 2550 - 2 * AppState.zoomPresetInsetPt / state.zoomFactor) < 0.5,
                "a fitted tab restores ordinary edge padding at the current zoom")
    }

    /// Real AppKit layout → `HorizontalDocumentViewport.onViewport` → `AppState.setViewportSize`.
    ///
    /// This is the resize/fullscreen evidence. It does not call `setViewportSize` itself: an
    /// actual `NSWindow` frame resize and an actual `toggleFullScreen` drive the same callback the
    /// window server drives. A runner that refuses the fullscreen transition falls back to the
    /// resize half with a NOTE, rather than failing on an unavailable window-server feature.
    @MainActor
    private static func windowResizeChecks(multipage: URL) async throws {
        _ = NSApplication.shared
        // The check runner is a command-line process, so its default activation policy is
        // `.prohibited`, and AppKit refuses fullscreen for such an application. The shipping app
        // is `.regular`; adopt that policy for this suite, restoring the previous one on exit, so
        // the fullscreen half tests the same window-server path.
        let previousPolicy = NSRunningApplication.current.activationPolicy
        _ = NSApplication.shared.setActivationPolicy(.regular)
        defer { _ = NSApplication.shared.setActivationPolicy(previousPolicy) }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let state = AppState(engine: try RustEngine())
        let panels = ReferencePreviewPanelController()
        let host = NSHostingView(rootView: ReaderWindow(
            state: state,
            opener: DocumentOpenCoordinator(state: state),
            previewPanels: panels))
        let window = NSWindow(
            contentRect: CGRect(x: 80, y: 80, width: 900, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer {
            window.orderOut(nil)
            window.contentView = nil
            panels.close()
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)

        var canvas: MetalCanvasView?
        try await eventually("viewport fit: the window canvas attaches", {
            canvas = firstCanvas(in: host)
            return (canvas?.hasAttachedSurface == true) && (canvas?.bounds.height ?? 0) > 100
        })
        guard let canvas else { fatalError("FAIL: viewport fit found no canvas") }

        // The CI runner's 38 ppi virtual display scales a page to 0.5278×, a geometry a
        // developer's 1.5× display never reaches. Pin that factor after the canvas has reported
        // the real screen so the resize path below is the same hard case on every machine; a
        // later screen notification is a no-op because the canvas already reported that screen.
        state.setDisplayCalibration(DisplayCalibration(factor: 0.5278))

        // The document opens at the settled canvas height, where a 842 pt page does not blank.
        guard state.open(url: multipage) else {
            fatalError("FAIL: viewport fit could not open \(multipage.lastPathComponent) in a window")
        }
        try await Task.sleep(for: .milliseconds(250))
        // The canvas reports the real display calibration. On a 38 ppi virtual CI display the
        // 100% page is only 444 logical points tall, so opening a 582 pt canvas may already have
        // auto-fitted; on a 72 ppi display it is 842 pt and 100% stays. Do not assume either:
        // zoom to the reader's minimum, which is below the fit for every usable window, then let
        // the real resize below re-apply Fit Page.
        var zoomOutSteps = 0
        while state.zoomPercent > AppState.minimumZoomPercent && zoomOutSteps < 40 {
            state.zoomOut()
            zoomOutSteps += 1
        }
        let initialZoom = state.zoomPercent
        require(initialZoom == AppState.minimumZoomPercent,
                "viewport fit: window document can be zoomed out to the minimum "
                    + "(got \(initialZoom)%, took \(zoomOutSteps) steps)")

        // A real frame resize. A CI display can clamp the window's height, and a size that is
        // already clamped to the screen changes nothing — the fitted percentage would then keep
        // the 25% chosen above and the assertion below would fail on the runner while passing on
        // a developer display. Shrink first to a size well below the screen limit, then grow to
        // the largest size the screen allows, so the height always increases by a real amount.
        let visible = window.screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let maxWidth = max(600, min(900, visible.width - 40))
        let maxHeight = max(420, min(1000, visible.height - 40))
        let smallHeight = max(300, maxHeight - 240)
        let canvasBeforeShrink = canvas.bounds.height
        window.setContentSize(CGSize(width: maxWidth, height: smallHeight))
        window.contentView?.layoutSubtreeIfNeeded()
        var settle = 0
        while canvas.bounds.height >= canvasBeforeShrink && settle < 40 {
            try await Task.sleep(for: .milliseconds(25))
            settle += 1
        }
        window.setContentSize(CGSize(width: maxWidth, height: maxHeight))
        window.contentView?.layoutSubtreeIfNeeded()
        var resizeWait = 0
        while state.zoomPercent <= initialZoom && resizeWait < 200 {
            try await Task.sleep(for: .milliseconds(25))
            resizeWait += 1
        }
        require(state.zoomPercent > initialZoom,
                "viewport fit: real window resize reaches the state (zoom \(state.zoomPercent)%, "
                    + "canvas \(canvas.bounds.size))")
        try await Task.sleep(for: .milliseconds(250))
        let grownZoom = state.zoomPercent
        let canvasHeight = canvas.bounds.height
        let pageHeight = state.document?.firstPageSize.height ?? 0
        let shownPageHeight = pageHeight * state.zoomFactor
        requireFittedPage(state, page: state.currentPage - 1, viewport: canvas.bounds.size)
        require(shownPageHeight <= canvasHeight - 2 * 8 + 2,
                "viewport fit: window resize fits the page into the canvas (\(shownPageHeight) pt of \(canvasHeight))")
        // A fitted first page must not park the offset above the document origin. On the CI
        // runner the grow can be clamped by a small screen, so the subsequent shrink may not
        // change the viewport at all; this assertion catches the fitted state itself.
        require(state.scrollYPt >= 0, "viewport fit: fitted window offset stays non-negative")

        // Shrinking back to the smaller real window size must keep the percentage (the fit is
        // now lower than the grown fit).
        window.setContentSize(CGSize(width: maxWidth, height: smallHeight))
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        require(state.zoomPercent == grownZoom,
                "viewport fit: shrinking a real window does not undo the fitted percentage "
                    + "(got \(state.zoomPercent)%, want \(grownZoom)%)")
        require(state.scrollYPt >= 0, "viewport fit: shrinking a real window keeps the offset in range")

        // Fullscreen is a real viewport-height change too. This environment has a window server,
        // so the transition can be attempted; on a runner that refuses fullscreen the check
        // falls back to the resize evidence above and states the gap instead of failing on an
        // unavailable window-server feature.
        while state.zoomPercent > AppState.minimumZoomPercent { state.zoomOut() }
        let preFullscreenZoom = state.zoomPercent
        let transition = ViewportFullscreenTransition()
        let center = NotificationCenter.default
        let enterObserver = center.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
        ) { _ in MainActor.assumeIsolated { transition.entered = true } }
        let exitObserver = center.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { _ in MainActor.assumeIsolated { transition.exited = true } }
        defer {
            center.removeObserver(enterObserver)
            center.removeObserver(exitObserver)
        }
        try await holdForScreenshot("before-fullscreen")
        window.toggleFullScreen(nil)
        var fullscreenWait = 0
        while !transition.entered && fullscreenWait < 300 {
            try await Task.sleep(for: .milliseconds(25))
            fullscreenWait += 1
        }
        guard transition.entered else {
            FileHandle.standardError.write(Data(
                "viewport-fit-note: fullscreen was not granted in this environment; only the resize path ran\n".utf8))
            return
        }
        var fullscreenSettle = 0
        while state.zoomPercent <= preFullscreenZoom && fullscreenSettle < 240 {
            try await Task.sleep(for: .milliseconds(25))
            fullscreenSettle += 1
        }
        let fullscreenZoom = state.zoomPercent
        require(fullscreenZoom > preFullscreenZoom,
                "viewport fit: entering fullscreen re-fits a page that leaves blank space "
                    + "(zoom \(fullscreenZoom)%, was \(preFullscreenZoom)%, canvas \(canvas.bounds.size))")
        requireFittedPage(state, page: state.currentPage - 1, viewport: canvas.bounds.size)
        let fullscreenPageHeight = pageHeight * state.zoomFactor
        require(fullscreenPageHeight <= canvas.bounds.height - 2 * 8 + 2,
                "viewport fit: entering fullscreen fits the page (\(fullscreenPageHeight) pt of \(canvas.bounds.height))")
        try await holdForScreenshot("fullscreen")

        window.toggleFullScreen(nil)
        var exitWait = 0
        while !transition.exited && exitWait < 300 {
            try await Task.sleep(for: .milliseconds(25))
            exitWait += 1
        }
        require(transition.exited, "viewport fit: exiting fullscreen returns to the window")
        try await Task.sleep(for: .milliseconds(300))
        require(state.zoomPercent == fullscreenZoom,
                "viewport fit: exiting fullscreen keeps the fitted percentage "
                    + "(got \(state.zoomPercent)%, want \(fullscreenZoom)%)")
        require(state.scrollYPt >= 0, "viewport fit: exiting fullscreen keeps the offset in range")

        // Multi-page evidence in the same real window: a taller frame must keep the percentage
        // and tighten the scroll range, with the first page at the top and the last page at the
        // bottom. The screenshot holds are inert unless the evidence env var is set.
        guard state.newTab(url: multipage), let many = state.document else {
            fatalError("FAIL: viewport fit could not open the multi-page fixture in a window")
        }
        require(many.pageCount == 3, "viewport fit: window multi-page fixture has three pages")
        state.zoomActual()
        for _ in 0..<15 { state.zoomIn() }
        let manyZoom = state.zoomPercent
        state.gotoPage(0)
        window.setContentSize(CGSize(width: 900, height: 1000))
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        require(state.zoomPercent == manyZoom, "viewport fit: the multi-page window keeps an above-fit zoom through a resize")
        require(state.scrollYPt == 0, "viewport fit: the multi-page window is top-aligned after a resize")
        try await holdForScreenshot("multi-top")
        state.gotoPage(2)
        state.scroll(byScreenPoints: 100_000)
        try await Task.sleep(for: .milliseconds(300))
        // `scrollYPt` is in content points; the canvas height is in view points.
        let expectedBottom = max(0, state.contentHeightPt - canvas.bounds.height / state.zoomFactor)
        require(abs(state.scrollYPt - expectedBottom) < 0.5,
                "viewport fit: the multi-page window reaches the padded canvas bottom "
                    + "(offset \(state.scrollYPt), want \(expectedBottom), canvas \(canvas.bounds.size))")
        requireDocumentEdges(state, viewport: canvas.bounds.size)
        try await holdForScreenshot("multi-bottom")
    }

    /// Screenshot evidence hook. The check is fast; a human or an external `screencapture`
    /// needs a moment on the frame the request names. Nothing is written by the check itself and
    /// the hold is inert unless `LYRA_READER_VIEWPORT_FIT_HOLD_MS` is set.
    @MainActor
    private static func holdForScreenshot(_ phase: String) async throws {
        guard let raw = ProcessInfo.processInfo.environment["LYRA_READER_VIEWPORT_FIT_HOLD_MS"],
              let milliseconds = Int(raw), milliseconds > 0 else { return }
        FileHandle.standardError.write(Data("viewport-fit-hold: \(phase)\n".utf8))
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    @MainActor
    private static func firstCanvas(in view: NSView) -> MetalCanvasView? {
        if let canvas = view as? MetalCanvasView { return canvas }
        for subview in view.subviews {
            if let canvas = firstCanvas(in: subview) { return canvas }
        }
        return nil
    }
}
