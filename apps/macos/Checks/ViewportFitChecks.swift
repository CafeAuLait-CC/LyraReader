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

/// The user-visible resize policy (`feat/viewport-fit-on-resize`).
///
/// A real viewport-height change (window resize or fullscreen) means two different things:
///
/// * a **single-page** document whose page is shorter than the new viewport adopts **Fit Page**,
///   so the page does not float above a band of blank canvas;
/// * a **multi-page** document never changes its percentage. Only the scroll range is tightened:
///   the first page's top edge sits at the viewport top at offset 0, and the clamp puts the last
///   page's bottom edge at the viewport bottom at the maximum offset. A document shorter than
///   the viewport stays top-aligned instead of being centred.
///
/// The decision is `lyra-reader-session`'s (through the FFI); these checks drive the shell's real
/// `setViewportSize` path, which is what the canvas calls after layout. A second scenario drives
/// the same path through a real `ReaderWindow`, a real `NSWindow` frame resize and a real
/// fullscreen transition, so the AppKit-layout → callback → policy wiring is covered, not just
/// the state method.
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
        try await windowResizeChecks(singlePage: singlePage, multipage: multipage)
    }

    /// A4 at 100% is 842 pt tall. With calibration 1 (the uncalibrated check convention) the
    /// fixture page is shorter than a 900 pt viewport but taller than a 500 pt one, so the two
    /// heights give the blank→fit and filled→unchanged cases without guessing at screen density.
    @MainActor
    private static func singlePageResizeChecks(fixture: URL) async throws {
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        guard state.newTab(url: fixture), let document = state.document else {
            fatalError("FAIL: viewport fit could not open the single-page fixture")
        }
        require(document.pageCount == 1, "viewport fit: single-page fixture has one page")
        let pageHeight = document.firstPageSize.height
        require(abs(pageHeight - 842) < 0.5, "viewport fit: single-page fixture is A4 (\(pageHeight) pt)")

        // 500 → 900 is the vertical change a resize/fullscreen transition reports. Fit Page is
        // (900 − 2 × 8) / 842 × 100 = 104.988… → 104 (floor, as for the Fit Page command).
        state.setViewportSize(CGSize(width: 760, height: 900))
        require(state.zoomPercent == 104,
                "viewport fit: a blank single page adopts Fit Page on a taller viewport (got \(state.zoomPercent)%)")
        require(state.scrollYPt == 0, "viewport fit: the fitted single page is top-aligned")
        let shownPageHeight = pageHeight * state.zoomFactor
        require(shownPageHeight <= CGFloat(900 - 2 * 8) + 0.5,
                "viewport fit: Fit Page keeps the page inside the preset inset (\(shownPageHeight) pt of 900)")
        // Flooring can leave at most one percentage step of extra blank below the inset.
        require(shownPageHeight > CGFloat(900 - 2 * 8) - pageHeight / 100 - 0.5,
                "viewport fit: the adopted percentage is the floored fit, not an arbitrary zoom")

        // A manual zoom-out below the fit is stable until the next real viewport change; that
        // change asks the policy again and re-fits. 94 < (901 − 16) / 842 × 100 = 105.106… → 105.
        state.zoomOut()
        require(state.zoomPercent == 94, "viewport fit: manual zoom-out reaches 94% (got \(state.zoomPercent)%)")
        state.setViewportSize(CGSize(width: 760, height: 901))
        require(state.zoomPercent == 105,
                "viewport fit: manual zoom-out + resize re-applies Fit Page (got \(state.zoomPercent)%)")
        require(state.scrollYPt == 0, "viewport fit: the re-fitted page is top-aligned")

        // At the fit value the preset's own 16 pt of blank is intentional; another resize must
        // not shrink the reader to the same value. 105 is still the fit at 902 pt.
        state.setViewportSize(CGSize(width: 760, height: 902))
        require(state.zoomPercent == 105,
                "viewport fit: a resize at the fit value keeps the percentage (got \(state.zoomPercent)%)")

        // A zoom above the fit is never pulled back down by a resize.
        state.zoomIn() // 115
        state.setViewportSize(CGSize(width: 760, height: 903))
        require(state.zoomPercent == 115,
                "viewport fit: a zoom above the fit is not shrunk on resize (got \(state.zoomPercent)%)")

        // A width-only viewport change is what the sidebar and inspector produce. It must not
        // re-fit even though it goes through the same `setViewportSize` entry point.
        let beforePanelZoom = state.zoomPercent
        let beforePanelScroll = state.scrollYPt
        state.setViewportSize(CGSize(width: 1000, height: 903), canvasWidth: 800)
        require(state.zoomPercent == beforePanelZoom && state.scrollYPt == beforePanelScroll,
                "viewport fit: sidebar/inspector width-only changes do not re-fit or scroll")

        // Exiting fullscreen shrinks the viewport: a fitted page is above the new fit (57% at
        // 500 pt), so the percentage stays. The fitted page still clamps into the new range.
        state.setViewportSize(CGSize(width: 1000, height: 500))
        require(state.zoomPercent == 115,
                "viewport fit: shrinking the viewport does not zoom a page that is already above the fit")
        require(state.scrollYPt >= 0, "viewport fit: a shrunk single page never scrolls above its top")
    }

    @MainActor
    private static func multiPageResizeChecks(fixture: URL) async throws {
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        guard state.newTab(url: fixture), let document = state.document else {
            fatalError("FAIL: viewport fit could not open the multi-page fixture")
        }
        require(document.pageCount == 3, "viewport fit: multi-page fixture has three pages")
        require(state.zoomPercent == 100, "viewport fit: multi-page document opens at 100%")
        // Three A4 pages with the default 12 pt gap: 3 × 842 + 2 × 12 = 2550 pt.
        require(abs(state.contentHeightPt - 2550) < 0.5,
                "viewport fit: multi-page content height is 2550 pt (got \(state.contentHeightPt))")

        // At the bottom, growing the viewport must keep 100% and move the offset to the new
        // maximum: last page bottom at the viewport bottom.
        state.gotoPage(2)
        state.scroll(byScreenPoints: 100_000)
        require(abs(state.scrollYPt - 2050) < 0.5,
                "viewport fit: multi-page reaches the 500 pt viewport bottom (got \(state.scrollYPt))")
        state.setViewportSize(CGSize(width: 760, height: 900))
        require(state.zoomPercent == 100,
                "viewport fit: multi-page keeps its percentage on a taller viewport (got \(state.zoomPercent)%)")
        require(abs(state.scrollYPt - 1650) < 0.5,
                "viewport fit: multi-page clamps to the new bottom, last page at the viewport bottom "
                    + "(got \(state.scrollYPt), want 1650)")
        require(state.scrollYPt <= max(0, state.contentHeightPt - 900) + 0.5,
                "viewport fit: multi-page never leaves scrollable blank after the last page")

        // At the top, growing the viewport must leave offset 0: first page top at viewport top.
        state.gotoPage(0)
        state.setViewportSize(CGSize(width: 800, height: 1000))
        require(state.zoomPercent == 100 && state.scrollYPt == 0,
                "viewport fit: multi-page stays top-aligned at the first page top "
                    + "(zoom \(state.zoomPercent)%, offset \(state.scrollYPt))")

        // Content shorter than the viewport: offset 0, blank only after the last page, never a
        // centred document.
        state.setViewportSize(CGSize(width: 800, height: 3000))
        require(state.zoomPercent == 100, "viewport fit: a short multi-page document keeps 100%")
        require(state.scrollYPt == 0,
                "viewport fit: a short multi-page document is top-aligned, not centred (got \(state.scrollYPt))")

        // The blank case that re-fits a one-page document must still not touch a multi-page one.
        for _ in 0..<8 { state.zoomOut() } // 100 → 25
        require(state.zoomPercent == 25, "viewport fit: multi-page manual zoom-out reaches 25%")
        state.setViewportSize(CGSize(width: 800, height: 3200))
        require(state.zoomPercent == 25,
                "viewport fit: multi-page keeps 25% even with blank below the last page")
        require(state.scrollYPt == 0,
                "viewport fit: the short multi-page document stays top-aligned at 25%")
    }

    /// Real AppKit layout → `HorizontalDocumentViewport.onViewport` → `AppState.setViewportSize`.
    ///
    /// This is the resize/fullscreen evidence. It does not call `setViewportSize` itself: an
    /// actual `NSWindow` frame resize and an actual `toggleFullScreen` drive the same callback the
    /// window server drives. A runner that refuses the fullscreen transition falls back to the
    /// resize half with a NOTE, rather than failing on an unavailable window-server feature.
    @MainActor
    private static func windowResizeChecks(singlePage: URL, multipage: URL) async throws {
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
        guard state.open(url: singlePage) else {
            fatalError("FAIL: viewport fit could not open \(singlePage.lastPathComponent) in a window")
        }
        try await Task.sleep(for: .milliseconds(250))
        // The check display leaves a 900×700 window a ~610 pt canvas, so the A4 page is taller
        // than the viewport at 100%. Zoom out to 50%: the page now leaves vertical blank at 50%
        // inside the enlarged window below, which is exactly what the resize policy re-fits.
        // (50% stays below the fit even on a short CI display; the grown canvas only has to exceed
        // 437 pt for the policy to fire.)
        for _ in 0..<5 { state.zoomOut() }
        let initialZoom = state.zoomPercent
        require(initialZoom == 50, "viewport fit: window document can be zoomed out to 50%")

        // A real frame resize. The grown window leaves a ~853 pt canvas on this display; Fit Page
        // is (853 − 16) / 842 × 100 = 99.4… → 99, above the 50% the reader chose.
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
        require(state.scrollYPt == 0, "viewport fit: window resize leaves the fitted page top-aligned")
        require(shownPageHeight <= canvasHeight - 2 * 8 + 2,
                "viewport fit: window resize fits the page into the canvas (\(shownPageHeight) pt of \(canvasHeight))")
        require(shownPageHeight > canvasHeight - 2 * 8 - pageHeight / 100 - 2,
                "viewport fit: window resize adopts the floored fit for the real canvas height")

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
        let preFullscreenZoom = state.zoomPercent
        let preFullscreenHeight = canvas.bounds.height
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
        while (canvas.bounds.height < preFullscreenHeight + 40
                || state.zoomPercent <= preFullscreenZoom) && fullscreenSettle < 240 {
            try await Task.sleep(for: .milliseconds(25))
            fullscreenSettle += 1
        }
        let fullscreenZoom = state.zoomPercent
        require(fullscreenZoom > preFullscreenZoom,
                "viewport fit: entering fullscreen re-fits a page that leaves blank space "
                    + "(zoom \(fullscreenZoom)%, was \(preFullscreenZoom)%, canvas \(canvas.bounds.size))")
        require(state.scrollYPt == 0, "viewport fit: the fullscreen-fit page is top-aligned")
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
        state.gotoPage(0)
        window.setContentSize(CGSize(width: 900, height: 1000))
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        require(state.zoomPercent == 100, "viewport fit: the multi-page window keeps 100% through a resize")
        require(state.scrollYPt == 0, "viewport fit: the multi-page window is top-aligned after a resize")
        try await holdForScreenshot("multi-top")
        state.gotoPage(2)
        state.scroll(byScreenPoints: 100_000)
        try await Task.sleep(for: .milliseconds(300))
        let expectedBottom = max(0, state.contentHeightPt * state.zoomFactor - canvas.bounds.height)
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
