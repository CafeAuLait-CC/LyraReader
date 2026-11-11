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

        try await singlePageResizeChecks(fixture: singlePage)
        try await multiPageResizeChecks(fixture: multipage)
        try fittedTabChecks(singlePage: singlePage, multipage: multipage)
        try await windowResizeChecks(multipage: multipage)
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
        state.setViewportSize(CGSize(width: 760, height: 899.4))
        requireFittedPage(state, page: 0, viewport: CGSize(width: 760, height: 899.4))
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
        state.scroll(toFraction: 1)
        requireFittedPage(state, page: 2, viewport: viewport)
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
        require(abs(state.contentHeightPt - 2550) < 0.5,
                "a fitted tab discards spacing calculated at a different zoom")
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
            return canvas?.bounds.height ?? 0 > 100
        })
        guard let canvas else { fatalError("FAIL: viewport fit found no canvas") }

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

        // A real frame resize. The grown window leaves a ~853 pt canvas here (less on a small
        // display); Fit Page is always above the 25% the reader chose.
        window.setContentSize(CGSize(width: 900, height: 1000))
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

        // Shrinking back to a real window size must keep the percentage (the fit is now lower).
        window.setContentSize(CGSize(width: 900, height: 700))
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
                "viewport fit: the multi-page window puts the last page at the canvas bottom "
                    + "(offset \(state.scrollYPt), want \(expectedBottom), canvas \(canvas.bounds.size))")
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
