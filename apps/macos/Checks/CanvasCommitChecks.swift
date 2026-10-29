import AppKit
import LyraReaderKit
import SwiftUI

/// Regression for the presentation path: a model commit must draw its frame through the wheel
/// handler's `syncInteraction`/`renderFrame` path *inside the commit*, not after the SwiftUI
/// publish and `updateNSView` hop.
///
/// The investigations (`build/experiments/`, sibling worktree) measured 6.6-15.8 ms for that hop
/// plus 5.5-13.9 ms for the canvas's coalesced main-queue job after the page list was already
/// sharp. The check here is structural rather than a latency measurement, so it does not depend
/// on the machine's load: it counts the frames handed to the engine before and after
/// `AppState.reloadVisiblePages()` returns. With direct invalidation the count advances
/// synchronously; with the old path it could not, because only a later run-loop turn publishes
/// the SwiftUI state.
///
/// The same scenario asserts the three properties the fix must not trade away:
///
/// 1. the frame drawn by the commit carries the commit's sharp stamp (trace on);
/// 2. the page chrome was updated with the same page geometry and scroll offset as the paper,
///    inside `renderFrame`'s CATransaction;
/// 3. the SwiftUI update that follows is a no-op for the canvas (no second frame), and a commit
///    that changes nothing visible submits nothing.
///
/// It runs once with the perf trace on and once with it off: the direct path must not be gated by
/// the measurement layer.
extension ReaderChecks {
    @MainActor static func canvasCommitChecks(source: URL) async throws {
        let fixtures = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-canvas-commit-\(UUID())")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtures) }
        let fixture = fixtures.appendingPathComponent("page.pdf")
        try FileManager.default.copyItem(at: source, to: fixture)
        try await runCanvasCommitScenario(fixture: fixture, tracing: true)
        try await runCanvasCommitScenario(fixture: fixture, tracing: false)
    }

    /// One scenario: a real `ReaderWindow` around a real engine and canvas. The zoom is forced
    /// to a fit-width/overflow state because a headless or virtual display's calibration can
    /// otherwise make the whole page fit and leave no vertical range; then one scroll changes
    /// only the viewport offset (the single-page fixture needs no new raster at that zoom), and
    /// one commit changes nothing.
    @MainActor
    private static func runCanvasCommitScenario(fixture: URL, tracing: Bool) async throws {
        let collector = CanvasCommitTraceCollector()
        PerfTrace.setEnabled(tracing)
        PerfTrace.setCapture(tracing ? { collector.append($0) } : nil)
        defer {
            PerfTrace.setEnabled(false)
            PerfTrace.setCapture(nil)
        }

        _ = NSApplication.shared
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 900, height: 600))
        let panels = ReferencePreviewPanelController()
        let host = NSHostingView(rootView: ReaderWindow(
            state: state,
            opener: DocumentOpenCoordinator(state: state),
            previewPanels: panels))
        let window = NSWindow(
            contentRect: CGRect(x: 40, y: 90, width: 900, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer {
            window.orderOut(nil)
            panels.close()
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)

        guard state.open(url: fixture) else {
            fatalError("FAIL: canvas commit scenario could not open \(fixture.lastPathComponent)")
        }

        func findCanvas(_ view: NSView) -> MetalCanvasView? {
            if let canvas = view as? MetalCanvasView { return canvas }
            for subview in view.subviews {
                if let canvas = findCanvas(subview) { return canvas }
            }
            return nil
        }

        let mode = tracing ? "traced" : "plain"
        try await eventuallyExplaining(
            "\(mode): the reader canvas attaches and reaches a settled frame",
            {
                let canvas = findCanvas(host)
                let work = state.scheduledTileWork
                return "visible=\(window.occlusionState.contains(.visible)) "
                    + "canvas=\(canvas != nil) surface=\(canvas?.hasAttachedSurface == true) "
                    + "attempts=\(canvas?.frameAttemptCount ?? 0) pages=\(state.canvasPages.count) "
                    + "work=\(work.queued)/\(work.inFlight) token=\(state.perfViewportStamp.token)"
            },
            {
                guard let canvas = findCanvas(host), canvas.hasAttachedSurface,
                      canvas.frameAttemptCount > 0, !state.canvasPages.isEmpty,
                      state.scheduledTileWork.queued == 0,
                      state.scheduledTileWork.inFlight == 0
                else { return false }
                return tracing ? state.perfViewportStamp.token > 0 : true
            })
        guard let canvas = findCanvas(host) else {
            fatalError("FAIL: the reader window never built its Metal canvas")
        }
        try await waitForQuiescentCanvas(state: state, canvas: canvas)

        // The opening zoom is 100% of the display's calibration, and a headless/virtual runner
        // can report a calibration low enough that the whole page fits the window. The check
        // needs a vertical scroll range, not a particular percentage: fit the page to the canvas
        // width first (a portrait page on a landscape canvas must overflow vertically at
        // fit-width), and only step the zoom up if this window's aspect still fits the page.
        state.zoomFitWidth()
        for _ in 0..<30 where !state.hasScrollableContent {
            state.zoomIn()
        }
        require(state.hasScrollableContent,
                "\(mode): the scenario window has a vertical scroll range at "
                    + "\(state.zoomPercent)% (content \(Int(state.contentHeightPt)) pt, "
                    + "canvas \(Int(canvas.bounds.height)) pt high)")
        // Start the measured scroll from the top, so "scroll by 96 pt" cannot already be clamped
        // at the end of the document.
        state.scroll(toFraction: 0)
        try await waitForQuiescentCanvas(state: state, canvas: canvas)

        // ── one commit, drawn before `reloadVisiblePages` returns ─────────────
        let attemptsBefore = canvas.frameAttemptCount
        let presentedBefore = canvas.submittedFrameCount
        let chromeBefore = canvas.pageChromeRectangles
        let tokenBefore = state.perfViewportStamp.token
        let offsetBefore = state.scrollYPt
        state.scroll(byScreenPoints: 96)
        require(state.scrollYPt > offsetBefore + 0.01, "\(mode): the commit scrolls the page")
        require(canvas.frameAttemptCount == attemptsBefore + 1,
                "\(mode): the model commit submits exactly one frame before returning")

        let commitStamp = state.perfViewportStamp
        if tracing {
            require(commitStamp.token > tokenBefore,
                    "\(mode): the commit publishes a new sharp stamp")
            require(canvas.lastAttemptStamp.token == commitStamp.token,
                    "\(mode): the submitted frame carries the commit's sharp token")
        }

        // The page chrome is written only by `PageChromeOverlayView.update`, which
        // `renderFrame` calls after beginning its CATransaction. It is read here before the
        // SwiftUI pass, so equality with the model's geometry proves the direct frame moved the
        // chrome with the paper in the same transaction. The same `PageChromeGeometry` call
        // feeds both sides.
        let expectedChrome = PageChromeGeometry.rectangles(
            frames: state.canvasPageSegments,
            viewport: canvas.bounds.size,
            contentWidthPt: state.contentWidthPt,
            zoom: state.zoomFactor,
            scrollYPt: state.scrollYPt)
        require(canvas.pageChromeRectangles == expectedChrome,
                "\(mode): the page chrome uses the same commit geometry as the frame")
        require(canvas.pageChromeRectangles != chromeBefore,
                "\(mode): the committed frame moved the chrome with the paper")
        // The engine draws the paper in device pixels; AppKit draws its chrome in points. The
        // layer's contentsScale is the only thing joining the two spaces, so assert it and then
        // compare the paper quad's rectangle (pixels / layer scale) with the chrome rectangle.
        let windowScale = window.backingScaleFactor
        let layerScale = (canvas.layer as? CAMetalLayer)?.contentsScale ?? 0
        require(abs(layerScale - windowScale) < 1e-9,
                "\(mode): the drawable maps its pixels to the window's backing scale")
        if let paper = state.canvasPages.first(where: { $0.placement.index < 0 }) {
            let placement = paper.placement
            let offsetX = max(0, (canvas.bounds.width * windowScale
                                  - state.contentWidthPt * state.zoomFactor * windowScale) / 2)
            let pixels = CanvasGeometry.pageRectInDevicePixels(
                pageTopPt: placement.topPt, pageLeftPt: placement.leftPt,
                widthPt: placement.widthPt, heightPt: placement.heightPt,
                scrollYPt: state.scrollYPt, zoom: state.zoomFactor,
                backingScale: windowScale, contentOffsetXPx: offsetX)
            let points = CGRect(x: pixels.minX / layerScale, y: pixels.minY / layerScale,
                                width: pixels.width / layerScale,
                                height: pixels.height / layerScale)
            if let chrome = expectedChrome.first {
                require(abs(points.minX - chrome.minX) < 0.5
                            && abs(points.minY - chrome.minY) < 0.5
                            && abs(points.width - chrome.width) < 0.5,
                        "\(mode): the paper and its chrome occupy the same rectangle")
            }
        }

        // The SwiftUI publish arrives after the commit. If the frame presented, nothing about
        // the following update may submit another one. If the window is occluded, wgpu skips
        // the draw and the canvas retries the *same* commit at its low rate; those attempts
        // must all carry this commit's stamp rather than drawing a different one.
        let presentedImmediately = canvas.submittedFrameCount - presentedBefore
        try await Task.sleep(for: .milliseconds(400))
        if presentedImmediately == 1 {
            require(canvas.frameAttemptCount == attemptsBefore + 1,
                    "\(mode): the SwiftUI update after the commit does not submit a second frame")
        } else {
            require(canvas.lastAttemptStamp.token == commitStamp.token,
                    "\(mode): a skipped frame retries the same commit, not another one")
        }

        // The frame record is written from Metal's presentation callback, later than the
        // synchronous attempt above; require the commit's token to reach the trace at all and
        // the record to name the page list the canvas actually submitted.
        if tracing {
            func sharpTime() -> Double {
                collector.records.compactMap { record -> Double? in
                    guard record["kind"] as? String == "sharp",
                          (record["token"] as? NSNumber)?.uint64Value == commitStamp.token
                    else { return nil }
                    return (record["time"] as? NSNumber)?.doubleValue
                }.max() ?? 0
            }
            try await eventually("\(mode): a traced frame carries the commit's sharp token", {
                !collector.frames(token: commitStamp.token, since: sharpTime()).isEmpty
            })
            let frames = collector.frames(token: commitStamp.token, since: sharpTime())
            require(!frames.isEmpty,
                    "\(mode): the commit's submitted frame names the sharp stamp in the trace")
            if let submitted = frames.min(by: {
                (($0["time"] as? NSNumber)?.doubleValue ?? 0)
                    < (($1["time"] as? NSNumber)?.doubleValue ?? 0)
            }) {
                require((submitted["quads"] as? NSNumber)?.intValue == canvas.lastAttemptedQuadCount,
                        "\(mode): the traced frame draws the committed page list")
            }
        }

        // ── a commit with no visible change submits nothing ──────────────────
        try await waitForQuiescentCanvas(state: state, canvas: canvas)
        let attemptsBeforeNoop = canvas.frameAttemptCount
        state.reloadVisiblePages()
        require(canvas.frameAttemptCount == attemptsBeforeNoop,
                "\(mode): a commit with no visible change submits no frame")
        try await Task.sleep(for: .milliseconds(350))
        require(canvas.frameAttemptCount == attemptsBeforeNoop,
                "\(mode): the SwiftUI update for a no-op commit submits no frame either")
    }

    /// Waits until no tile work is queued or in flight, no page raster has just replaced its
    /// preview, and the frame counter has been stable for several samples, so the action under
    /// test starts from a canvas that is not already drawing an earlier commit (the zoom in this
    /// scenario starts a new screen-resolution raster).
    @MainActor
    private static func waitForQuiescentCanvas(state: AppState, canvas: MetalCanvasView) async throws {
        var lastSignature = ""
        var stableSamples = 0
        for _ in 0..<400 {
            let work = state.scheduledTileWork
            let signature = "\(work.queued)/\(work.inFlight)/\(canvas.frameAttemptCount)/"
                + "\(state.canvasPages.count)/\(state.pageRasterCount)/\(state.tileRasterCount)"
            if work.queued == 0 && work.inFlight == 0 && signature == lastSignature {
                stableSamples += 1
                if stableSamples >= 8 { return }
            } else {
                stableSamples = 0
            }
            lastSignature = signature
            try await Task.sleep(for: .milliseconds(25))
        }
        fatalError("TIMEOUT: canvas commit scenario did not settle "
            + "(tracing=\(PerfTrace.enabled), attempts=\(canvas.frameAttemptCount))")
    }
}

/// Thread-safe sink: frame records are appended from Metal's presentation callback, which is not
/// the main actor. The check reads them only after the scenario has gone quiet.
private final class CanvasCommitTraceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String: Any]] = []

    func append(_ line: String) {
        guard line.hasPrefix(PerfTrace.prefix) else { return }
        let body = line.dropFirst(PerfTrace.prefix.count)
        guard let record = (try? JSONSerialization.jsonObject(with: Data(body.utf8)))
            as? [String: Any]
        else { return }
        lock.lock()
        storage.append(record)
        lock.unlock()
    }

    var records: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Frame records carrying one sharp token at or after `since`, in collection order.
    func frames(token: UInt64, since: Double) -> [[String: Any]] {
        records.filter { record in
            guard record["kind"] as? String == "frame",
                  (record["token"] as? NSNumber)?.uint64Value == token,
                  let time = (record["time"] as? NSNumber)?.doubleValue
            else { return false }
            return time >= since
        }
    }
}
