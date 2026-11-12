#if DEBUG
import AppKit
import CoreGraphics
import CoreVideo
import ImageIO
import LyraReaderKit
import Metal
import QuartzCore
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Opt-in driver for the packaged debug application. The launcher gives it a separate bundle
/// identity and scratch caches; normal launches and release builds never enter this path.
@MainActor
enum PaperVisualCapture {
    private struct Options {
        let fixture: URL
        let output: URL
        let language: String
        let appearance: String
        let suite: String
        let mutation: String?
    }

    private static var options: Options?
    private static var started = false

    static func prepareIfRequested() -> Bool {
        guard let requestPath = ProcessInfo.processInfo.environment["LYRA_READER_VISUAL_REQUEST"] else { return false }
        do {
            let requestURL = URL(fileURLWithPath: requestPath)
            let size = try requestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size, size > 0, size < 16_384,
                  let request = try JSONSerialization.jsonObject(with: Data(contentsOf: requestURL)) as? [String: String]
            else { throw CaptureError("Invalid visual capture request") }
            func argument(_ name: String) throws -> String {
                guard let value = request[name], !value.isEmpty else {
                    throw CaptureError("Missing argument: \(name)")
                }
                return value
            }
            guard Bundle.main.bundleIdentifier?.hasPrefix("com.lyrareader.visual-checks.") == true else {
                throw CaptureError("Visual capture requires the launcher's isolated application bundle")
            }
            let fixture = URL(fileURLWithPath: try argument("fixture")).standardizedFileURL
            let output = URL(fileURLWithPath: try argument("output")).standardizedFileURL
            let language = try argument("language")
            let appearance = try argument("appearance")
            guard ["en", "zh-Hans"].contains(language), ["light", "dark"].contains(appearance),
                  FileManager.default.fileExists(atPath: fixture.path),
                  FileManager.default.fileExists(atPath: output.path) else {
                throw CaptureError("Invalid language, appearance, fixture, or output directory")
            }
            let mutation = request["mutation"]
            let suite = request["suite"] ?? "paper"
            guard ["paper", "reader-shell", "toolbar-inspectors"].contains(suite), mutation == nil || suite == "paper" else {
                throw CaptureError("Unsupported capture suite or mutation")
            }
            guard mutation == nil || ["scale", "chrome"].contains(mutation) else {
                throw CaptureError("Visual mutation must be scale or chrome")
            }
            options = Options(fixture: fixture, output: output, language: language,
                              appearance: appearance, suite: suite, mutation: mutation)
            try Data(String(ProcessInfo.processInfo.processIdentifier).utf8)
                .write(to: output.appendingPathComponent("capture.pid"), options: .atomic)
            // LaunchServices can inherit launchd hooks rather than the launcher's environment.
            // Remove all production test/network hooks before constructing the first AppState.
            for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("LYRA_READER_") {
                unsetenv(key)
            }
            UserDefaults.standard.setVolatileDomain([
                "AppleLanguages": [language], "AppleLocale": language == "en" ? "en_US" : "zh_CN",
                ReadingAppearanceStore.preferenceKey: "original",
                // Keep the real Home view deterministic and prevent fallback to private system recents.
                "lyrareader.recentDocuments": Data("[]".utf8),
                "lyrareader.didMigratePreferences": true
            ], forName: UserDefaults.argumentDomain)
            AppState.recordsRecentDocuments = false
            AppState.usesDocumentKnowledge = false
            AppState.usesStoredReadingLayoutPreferences = false
            AppState.usesStoredSidebarTab = false
            AppState.usesStoredSidePanelPreferences = false
            ReaderMotion.reduceMotionOverride = true
            if suite == "toolbar-inspectors" {
                guard let utc = TimeZone(secondsFromGMT: 0) else {
                    throw CaptureError("UTC is unavailable for the date preview fixture")
                }
                FillSignDateFormat.previewClockOverride = (Date(timeIntervalSince1970: 946_728_000), utc)
            }
            for (key, directory) in [
                ("LYRA_READER_DOCUMENT_CACHE_DIR", "Documents"),
                ("LYRA_READER_INDEX_CACHE_DIR", "Indexes"),
                ("LYRA_READER_AI_AUDIT_DIR", "Audit")
            ] {
                setenv(key, output.appendingPathComponent("scratch/\(directory)").path, 1)
            }
            setenv("LYRA_READER_INDEX_CACHE", "disabled", 1)
            PerfTrace.setEnabled(true)
            NSApplication.shared.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
            return true
        } catch {
            FileHandle.standardError.write(Data("visual-capture: \(error)\n".utf8))
            exit(2)
        }
    }

    static func startIfRequested(registry: ReaderWindowRegistry) {
        guard let options, !started else { return }
        started = true
        Task { @MainActor in
            guard #available(macOS 14.4, *) else {
                FileHandle.standardError.write(Data("visual-capture requires macOS 14.4 or later\n".utf8))
                exit(2)
            }
            let run = Run(options: options)
            do {
                try await run.capture(registry: registry)
                try run.writeManifest(error: nil)
                exit(0)
            } catch {
                do { try run.writeManifest(error: String(describing: error)) }
                catch { FileHandle.standardError.write(Data("visual-capture report: \(error)\n".utf8)) }
                FileHandle.standardError.write(Data("visual-capture: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    private struct CaptureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private struct WindowImage: Sendable {
        let image: CGImage
        let frame: CGRect
        let contentRect: CGRect
    }

    /// Metal invokes the sink off the main actor. Every access to the one stored frame index
    /// is protected by this lock; no AppKit object is retained by the sink.
    private final class PresentedFrames: @unchecked Sendable {
        private let lock = NSLock()
        private var latest: [UInt64: UInt64] = [:]

        func append(_ line: String) {
            guard line.hasPrefix(PerfTrace.prefix),
                  let object = try? JSONSerialization.jsonObject(
                    with: Data(line.dropFirst(PerfTrace.prefix.count).utf8)),
                  let record = object as? [String: Any], record["kind"] as? String == "frame",
                  let time = record["presented_time"] as? NSNumber, time.doubleValue > 0,
                  let index = record["frame_index"] as? NSNumber,
                  let surface = record["surface"] as? NSNumber else { return }
            lock.lock()
            latest[surface.uint64Value] = max(latest[surface.uint64Value] ?? 0, index.uint64Value)
            lock.unlock()
        }

        func contains(_ index: UInt64, surface: UInt64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let presented = latest[surface] else { return false }
            return index > 0 && presented >= index
        }
    }

    @available(macOS 14.4, *)
    @MainActor
    private final class Run {
        let options: Options
        let frames = PresentedFrames()
        var captures: [[String: Any]] = []
        var deferredCaptures: [[String: Any]] = []
        var environment: [String: Any] = [:]
        var fullScreenTransitionCompleted = false
        var capturedWindowFrame = CGRect.zero
        var capturedContentRect = CGRect.zero

        init(options: Options) { self.options = options }

        func focus(window: NSWindow) {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        func wait(_ description: String, attempts: Int = 800, until condition: () -> Bool) async throws {
            for _ in 0..<attempts {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw CaptureError("Timed out: \(description)")
        }

        func canvas(in view: NSView) -> MetalCanvasView? {
            if let canvas = view as? MetalCanvasView { return canvas }
            return view.subviews.lazy.compactMap { self.canvas(in: $0) }.first
        }

        func settle(state: AppState, window: NSWindow) async throws -> MetalCanvasView {
            var previous = ""
            var samples = 0
            var settledCanvas: MetalCanvasView?
            var diagnostic = "no canvas"
            do {
              try await wait("visible current PDF frame after layout and canvas replacement", attempts: 2400) {
                guard NSApplication.shared.isActive && window.isKeyWindow else {
                    self.focus(window: window)
                    samples = 0
                    diagnostic = "active=\(NSApplication.shared.isActive) key=\(window.isKeyWindow)"
                    return false
                }
                window.contentView?.layoutSubtreeIfNeeded()
                guard let content = window.contentView, let canvas = self.canvas(in: content),
                      canvas === state.attachedCanvas, canvas.window === window else { return false }
                let work = state.scheduledTileWork
                let signature = "\(canvas.presentationSurfaceID)/\(window.frame)/\(canvas.bounds)/\(canvas.frameAttemptCount)/"
                    + "\(state.zoomFactor)/\(state.scrollYPt)/\(state.pageRasterCount)/\(state.tileRasterCount)"
                let ready = NSApplication.shared.isActive && window.isKeyWindow
                    && window.occlusionState.contains(.visible) && canvas.hasAttachedSurface
                    && !state.canvasPages.isEmpty && !state.isScrolling && !state.isDraggingScrollIndicator
                    && work.queued == 0 && work.inFlight == 0
                    && canvas.visualSubmittedViewportSize == canvas.bounds.size
                    && abs(canvas.visualSubmittedZoom - state.zoomFactor) < 1e-9
                    && abs(canvas.visualSubmittedScrollYPt - state.scrollYPt) < 1e-9
                    && canvas.visualSubmittedStamp.epoch == state.perfViewportStamp.epoch
                    && canvas.visualSubmittedStamp.contentVersion == state.perfViewportStamp.contentVersion
                diagnostic = "visible=\(window.occlusionState.contains(.visible)) "
                    + "surface=\(canvas.presentationSurfaceID) frame=\(canvas.frameAttemptCount) "
                    + "accepted=\(canvas.visualSubmittedFrameIndex) "
                    + "presented=\(frames.contains(canvas.visualSubmittedFrameIndex, surface: canvas.presentationSurfaceID)) "
                    + "acceptedViewport=\(canvas.visualSubmittedViewportSize) "
                    + "zoom=\(canvas.visualSubmittedZoom)/\(state.zoomFactor) "
                    + "offset=\(canvas.visualSubmittedScrollYPt)/\(state.scrollYPt) "
                    + "epoch=\(canvas.visualSubmittedStamp.epoch)/\(state.perfViewportStamp.epoch) "
                    + "version=\(canvas.visualSubmittedStamp.contentVersion)/\(state.perfViewportStamp.contentVersion) "
                    + "bounds=\(canvas.bounds) work=\(work.queued)/\(work.inFlight)"
                samples = ready && signature == previous ? samples + 1 : 0
                previous = signature
                settledCanvas = canvas
                return samples >= 6
              }
            } catch {
                throw CaptureError("\(error); \(diagnostic)")
            }
            guard let settledCanvas else { throw CaptureError("Settled canvas is missing") }
            return settledCanvas
        }

        func screenshot(window: NSWindow) async throws -> CGImage {
            guard let number = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { throw CaptureError("Own window has no display") }
            let result = try await Self.captureOwnWindow(windowID: CGWindowID(window.windowNumber),
                scale: window.backingScaleFactor, displayID: CGDirectDisplayID(number.uint32Value),
                sRGB: options.suite == "toolbar-inspectors")
            capturedWindowFrame = result.frame
            capturedContentRect = result.contentRect
            return result.image
        }

        // Keep ScreenCaptureKit's non-Sendable snapshot/filter objects on its nonisolated
        // async executor. Only immutable CGImage pixels cross back to the main actor.
        nonisolated static func captureOwnWindow(windowID: CGWindowID, scale: CGFloat,
            displayID: CGDirectDisplayID, sRGB: Bool) async throws -> WindowImage {
            let available = try await SCShareableContent.currentProcess
            guard let ownWindow = available.windows.first(where: {
                $0.windowID == windowID
                    && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
            }) else { throw CaptureError("The application's own window is unavailable for capture") }
            guard let display = available.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError("Own window display is unavailable to the capture process")
            }
            // Include exactly this process-owned window. Desktop, Dock, menu bar and every
            // other application's windows are excluded before the display is sampled.
            let filter = SCContentFilter(display: display, including: [ownWindow])
            filter.includeMenuBar = false
            let width = Int((ownWindow.frame.width * scale).rounded())
            let height = Int((ownWindow.frame.height * scale).rounded())
            guard width > 0, height > 0, width <= 16384, height <= 16384,
                  width <= 32_000_000 / height else { throw CaptureError("Capture dimensions exceed the limit") }
            let configuration = SCStreamConfiguration()
            configuration.width = width
            configuration.height = height
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.ignoreShadowsDisplay = true
            configuration.sourceRect = CGRect(x: ownWindow.frame.minX - display.frame.minX,
                y: ownWindow.frame.minY - display.frame.minY, width: ownWindow.frame.width, height: ownWindow.frame.height)
            configuration.captureResolution = .best
            configuration.scalesToFit = false
            if sRGB {
                // Request the comparison space from WindowServer instead of converting the
                // display's color space after its pixels have already been quantized.
                configuration.colorSpaceName = CGColorSpace.sRGB
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
            }
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard image.width == width, image.height == height else {
                throw CaptureError("System capture changed the requested native pixel dimensions")
            }
            return WindowImage(image: image, frame: ownWindow.frame, contentRect: filter.contentRect)
        }

        func write(_ image: CGImage, name: String) throws {
            let url = options.output.appendingPathComponent(name)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { throw CaptureError("Cannot create PNG destination") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CaptureError("Cannot finish PNG") }
        }

        func rgba(_ image: CGImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let success = bytes.withUnsafeMutableBytes { storage -> Bool in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                    let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
                else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard success else { throw CaptureError("Cannot normalize capture pixels") }
            return bytes
        }

        enum PaperExpectation { case none, topEdge, bottomEdge, fitted }

        func snapshot(_ id: String, state: AppState, window: NSWindow, identity: String? = nil,
                      expectation: PaperExpectation = .none, requiredMarker: String = "red") async throws {
            focus(window: window)
            let liveCanvas: MetalCanvasView
            do { liveCanvas = try await settle(state: state, window: window) }
            catch {
                // Best-effort evidence only; failure to settle remains fatal either way.
                if let diagnostic = try? await screenshot(window: window) {
                    try write(diagnostic, name: "failed-\(id).png")
                }
                throw error
            }
            let canvas = liveCanvas
            let visiblePapers = canvas.pageChromeRectangles.filter { $0.intersects(canvas.bounds) }
            guard let paper = visiblePapers.first,
                  let layer = canvas.layer as? CAMetalLayer else { throw CaptureError("Missing native paper chrome") }
            let top = paper.minY, bottom = canvas.bounds.height - paper.maxY
            switch expectation {
            case .none: break
            case .topEdge:
                guard abs(top - 8) <= 0.5 else { throw CaptureError("Document top padding differs in \(id): \(top)") }
            case .bottomEdge:
                guard abs(bottom - 8) <= 0.5 else { throw CaptureError("Document bottom padding differs in \(id): \(bottom)") }
            case .fitted:
                guard visiblePapers.count == 1, top >= 7.5, bottom >= 7.5, abs(top - bottom) <= 0.5,
                      paper.minX >= 7.5, canvas.bounds.width - paper.maxX >= 7.5 else {
                    throw CaptureError("Fit Page padding or neighboring paper differs in \(id): top=\(top) bottom=\(bottom)")
                }
            }
            let scale = window.backingScaleFactor
            guard abs(layer.contentsScale - scale) < 0.0001 else {
                throw CaptureError("Drawable-to-point scale does not match the window")
            }
            // Deliberate opt-in mutations reproduce a compositor mapping failure or move only
            // the native chrome. Their captures are evidence of failure, never valid baselines.
            let beforeMutation = options.mutation == nil ? nil : try rgba(await screenshot(window: window))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if options.mutation == "scale" { layer.contentsScale = scale / 2 }
            let chrome = canvas.subviews.first { $0 is PageChromeOverlayView }
            if options.mutation == "chrome", let chrome { chrome.frame.origin.x += 24 }
            CATransaction.commit()
            CATransaction.flush()
            let bounds = canvas.convert(canvas.bounds, to: nil)
            // Inspectors clip an anchored drawing surface rather than shrink it. A fixture
            // marker behind that clip is not visible PDF content and must not be read as UI.
            let visibleCanvas = canvas.visibleRect.intersection(canvas.bounds)
            guard let primary = NSScreen.screens.first else { throw CaptureError("No primary screen coordinate origin") }
            let screenBounds = window.convertToScreen(bounds)
            var capturedImage: CGImage?
            var pixels: [UInt8] = []
            var markerVisible = false
            var markerChecks: [[String: Any]] = []
            var mx = 0
            var my = 0
            var canvasLeft: CGFloat = 0
            var canvasTop: CGFloat = 0
            var previousPixels: [UInt8]?
            var stableSamples = 0
            // A successful GPU submission can precede the compositor's updated window image.
            // Wait for known fixture pixels at the current transform, rather than a fixed sleep
            // or a presentation timestamp that the OS may not provide for full-screen windows.
            for _ in 0..<80 {
                guard NSApplication.shared.isActive && window.isKeyWindow else {
                    focus(window: window)
                    stableSamples = 0
                    previousPixels = nil
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                let image = try await screenshot(window: window)
                capturedImage = image
                pixels = try rgba(image)
                canvasLeft = screenBounds.minX - capturedWindowFrame.minX
                canvasTop = primary.frame.maxY - screenBounds.maxY - capturedWindowFrame.minY
                markerChecks = []
                var sources = [("red", CGFloat(33), CGFloat(30)),
                    ("blue", CGFloat(579), CGFloat(30)), ("green", CGFloat(33), CGFloat(762)),
                    ("orange", CGFloat(579), CGFloat(762))]
                if let identity { sources.append((identity, 306, 90)) }
                for (name, sourceX, sourceY) in sources {
                    let point = CGPoint(x: canvasLeft + paper.minX + sourceX * state.zoomFactor,
                                        y: canvasTop + paper.minY + sourceY * state.zoomFactor)
                    let x = Int((point.x * scale).rounded())
                    let y = Int((point.y * scale).rounded())
                    let localPoint = CGPoint(x: paper.minX + sourceX * state.zoomFactor,
                                             y: paper.minY + sourceY * state.zoomFactor)
                    let visible = visibleCanvas.contains(localPoint)
                        && x >= 0 && x < image.width && y >= 0 && y < image.height
                    if name == requiredMarker { mx = x; my = y }
                    guard visible else { continue }
                    let offset = (y * image.width + x) * 4
                    let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                    let matches: Bool
                    switch name {
                    case "red": matches = r > 180 && g < 90 && b < 90
                    case "blue": matches = b > 180 && r < 90 && g < 140
                    case "green": matches = g > 120 && r < 100 && b < 140
                    case "magenta": matches = r > 180 && b > 180 && g < 90
                    case "cyan": matches = g > 180 && b > 180 && r < 90
                    case "yellow": matches = r > 180 && g > 180 && b < 90
                    default: matches = r > 180 && g >= 100 && g < 220 && b < 100
                    }
                    markerChecks.append(["name": name, "pixel": [x, y], "rgb": [r, g, b], "match": matches])
                }
                markerVisible = markerChecks.contains { $0["name"] as? String == requiredMarker }
                    && markerChecks.allSatisfy { $0["match"] as? Bool == true }
                let mutationVisible = beforeMutation.map { $0 != pixels } ?? true
                stableSamples = markerVisible && mutationVisible && previousPixels == pixels ? stableSamples + 1 : 0
                previousPixels = pixels
                if stableSamples >= 3 { break }
                // Native indicators can fade after model/GPU work has finished. Require stable
                // compositor pixels as well as registration, without masking any image region.
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let image = capturedImage else { throw CaptureError("No window image was captured") }
            try write(image, name: "\(id).png")
            captures.append([
                "id": id, "file": "\(id).png", "pixel_width": image.width, "pixel_height": image.height,
                "window_points": [window.frame.width, window.frame.height],
                "tab_count": state.tabs.count, "active_tab_index": state.activeTabIndex as Any? ?? NSNull(),
                "active_application": NSApplication.shared.isActive, "key_window": window.isKeyWindow,
                "canvas_points": [canvasLeft, canvasTop, bounds.width, bounds.height],
                "canvas_window_points": [bounds.minX, bounds.minY, bounds.width, bounds.height],
                "visible_canvas_local_points": [visibleCanvas.minX, visibleCanvas.minY,
                    visibleCanvas.width, visibleCanvas.height],
                "window_frame_points": [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height],
                "captured_window_frame_points": [capturedWindowFrame.minX, capturedWindowFrame.minY,
                    capturedWindowFrame.width, capturedWindowFrame.height],
                "captured_content_rect_points": [capturedContentRect.minX, capturedContentRect.minY,
                    capturedContentRect.width, capturedContentRect.height],
                "paper_points": [paper.minX, paper.minY, paper.width, paper.height],
                "paper_margins_points": [paper.minX, top, canvas.bounds.width - paper.maxX, bottom],
                "visible_paper_count": visiblePapers.count, "page_index": state.currentPage - 1,
                "backing_scale": scale, "layer_scale": layer.contentsScale,
                "layer_drawable_size": [layer.drawableSize.width, layer.drawableSize.height],
                "submitted_drawable_size": [canvas.lastAttemptDrawableSize.width, canvas.lastAttemptDrawableSize.height],
                "layer_frame": [layer.frame.minX, layer.frame.minY, layer.frame.width, layer.frame.height],
                "layer_bounds": [layer.bounds.minX, layer.bounds.minY, layer.bounds.width, layer.bounds.height],
                "layer_presentation_frame": layer.presentation().map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? [],
                "zoom_percent": state.zoomPercent, "calibration": state.displayCalibration.factor,
                "frame_index": canvas.visualSubmittedFrameIndex, "gpu_marker_visible": markerVisible,
                "surface": canvas.presentationSurfaceID,
                "metal_presentation_timestamp_available": frames.contains(
                    canvas.visualSubmittedFrameIndex, surface: canvas.presentationSurfaceID),
                "verification": "current-window-compositor-pixels",
                "marker_pixel": [mx, my], "required_registration_marker": requiredMarker,
                "registration_markers": markerChecks, "fullscreen": window.styleMask.contains(.fullScreen)
            ])
            guard markerVisible else { throw CaptureError("GPU registration marker is missing or misaligned in \(id)") }
            guard stableSamples >= 3 else { throw CaptureError("Window compositor pixels did not stabilize in \(id)") }
            if options.mutation != nil { throw CaptureError("Deliberate visual mutation: \(options.mutation ?? "unknown")") }
        }

        func nativeChromeProbe(state: AppState, window: NSWindow) async throws {
            state.zoomFitWidth()
            state.scroll(toFraction: 0)
            let canvas = try await settle(state: state, window: window)
            guard let paper = canvas.pageChromeRectangles.first, let primary = NSScreen.screens.first else {
                throw CaptureError("Missing chrome probe geometry")
            }
            let image = try await screenshot(window: window)
            try write(image, name: "probe-with-native-chrome.png")
            let pixels = try rgba(image)
            let bounds = canvas.convert(canvas.bounds, to: nil)
            let screenBounds = window.convertToScreen(bounds)
            let canvasLeft = screenBounds.minX - capturedWindowFrame.minX
            let canvasTop = primary.frame.maxY - screenBounds.maxY - capturedWindowFrame.minY
            let scale = window.backingScaleFactor
            let chrome = canvas.subviews.first { $0 is PageChromeOverlayView }
            guard let chrome else { throw CaptureError("Native page chrome view is missing") }
            guard let chromeLayer = chrome.layer else { throw CaptureError("Native chrome layer is missing") }
            let opacity = chromeLayer.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            chromeLayer.opacity = 0
            CATransaction.commit()
            CATransaction.flush()
            let without = try await screenshot(window: window)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            chromeLayer.opacity = opacity
            CATransaction.commit()
            CATransaction.flush()
            try write(without, name: "probe-without-native-chrome.png")
            let hiddenPixels = try rgba(without)
            guard hiddenPixels.count == pixels.count else { throw CaptureError("Chrome probe changed capture size") }
            var changed = 0
            let pageLeft = Int((canvasLeft + paper.minX) * scale)
            let pageTop = Int((canvasTop + paper.minY) * scale)
            let pageRight = Int((canvasLeft + paper.maxX) * scale)
            let pageBottom = Int((canvasTop + paper.maxY) * scale)
            let band = Int(ceil(4 * scale))
            for y in max(0, pageTop - band)..<min(image.height, pageBottom + band) {
                for x in max(0, pageLeft - band)..<min(image.width, pageRight + band) {
                    guard abs(x - pageLeft) <= band || abs(x - pageRight) <= band
                        || abs(y - pageTop) <= band || abs(y - pageBottom) <= band else { continue }
                    let offset = (y * image.width + x) * 4
                    if (0..<3).contains(where: { abs(Int(pixels[offset + $0]) - Int(hiddenPixels[offset + $0])) > 2 }) {
                        changed += 1
                    }
                }
            }
            environment["native_chrome_probe_changed_pixels"] = changed
            guard changed >= 20 else { throw CaptureError("Capture did not include the native paper chrome") }
        }

        func homeSnapshot(_ id: String, state: AppState, window: NSWindow) async throws {
            focus(window: window)
            try await wait("empty production reader home", attempts: 2400) {
                guard NSApplication.shared.isActive && window.isKeyWindow else {
                    self.focus(window: window)
                    return false
                }
                window.contentView?.layoutSubtreeIfNeeded()
                guard let content = window.contentView, let canvas = self.canvas(in: content) else { return false }
                return state.document == nil && state.tabs.isEmpty && state.canvasPages.isEmpty
                    && canvas.lastSubmittedQuadCount == 0 && window.occlusionState.contains(.visible)
            }
            guard RecentDocumentStore.shared.entries.isEmpty else {
                throw CaptureError("Home capture must not contain recent documents")
            }
            var previous: [UInt8]?
            var stable = 0
            for _ in 0..<80 {
                guard NSApplication.shared.isActive && window.isKeyWindow else {
                    focus(window: window)
                    stable = 0
                    previous = nil
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                let image = try await screenshot(window: window)
                let pixels = try rgba(image)
                stable = previous == pixels ? stable + 1 : 0
                previous = pixels
                if stable >= 3 {
                    guard state.document == nil && state.tabs.isEmpty else {
                        throw CaptureError("Home changed while capturing")
                    }
                    var colors = Set<Int>()
                    for offset in stride(from: 0, to: pixels.count, by: 4 * 997) {
                        colors.insert(Int(pixels[offset]) << 16 | Int(pixels[offset + 1]) << 8 | Int(pixels[offset + 2]))
                    }
                    guard colors.count >= 16 else { throw CaptureError("Home image is blank or uniform") }
                    try write(image, name: "\(id).png")
                    captures.append([
                        "id": id, "file": "\(id).png", "pixel_width": image.width, "pixel_height": image.height,
                        "window_points": [window.frame.width, window.frame.height],
                        "backing_scale": window.backingScaleFactor, "calibration": state.displayCalibration.factor,
                        "zoom_percent": state.zoomPercent, "tab_count": 0,
                        "active_application": NSApplication.shared.isActive, "key_window": window.isKeyWindow,
                        "verification": "stable-native-home-with-zero-page-quads"
                    ])
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw CaptureError("Home compositor pixels did not stabilize")
        }

        func captureReaderShell(state: AppState, window: NSWindow) async throws {
            try await homeSnapshot("01-home-empty", state: state, window: window)
            let names = Array("abcdefgh").map { "reader-\($0).pdf" }
            let colors = ["magenta", "cyan", "yellow"]
            func open(_ index: Int) throws {
                let url = options.fixture.deletingLastPathComponent().appendingPathComponent(names[index])
                guard state.openDocumentInTab(url) else { throw CaptureError("Cannot open reader fixture") }
                state.zoomActual()
                state.scroll(toFraction: 0)
            }
            func shot(_ id: String, active: Int, count: Int, source: Int) async throws {
                func correctDocument() -> Bool {
                    state.activeTabIndex == active && state.tabs.count == count
                        && state.document?.url?.lastPathComponent == names[source]
                }
                guard correctDocument() else { throw CaptureError("Wrong tab or document before \(id)") }
                try await snapshot(id, state: state, window: window, identity: colors[source % colors.count])
                guard correctDocument() else { throw CaptureError("Tab changed while capturing \(id)") }
            }
            try open(0)
            try await shot("02-one-tab", active: 0, count: 1, source: 0)
            try open(1)
            try open(2)
            try await shot("03-three-tabs", active: 2, count: 3, source: 2)
            for index in 3..<8 { try open(index) }
            try await shot("04-eight-tabs", active: 7, count: 8, source: 7)
            state.selectTab(0)
            try await shot("05-first-tab-active", active: 0, count: 8, source: 0)
            window.setContentSize(CGSize(width: 960, height: 640))
            try await shot("06-narrow-eight-tabs", active: 0, count: 8, source: 0)
            window.setContentSize(CGSize(width: 1200, height: 800))
            try await shot("07-window-restored", active: 0, count: 8, source: 0)
            state.closeTab(0)
            try await shot("08-close-active-tab", active: 0, count: 7, source: 1)
            while state.tabs.count > 1 {
                let count = state.tabs.count
                state.closeTab(count - 1)
                guard state.tabs.count == count - 1 else { throw CaptureError("Fixture tab refused to close") }
            }
            try await shot("09-last-tab", active: 0, count: 1, source: 1)
            state.closeTab(0)
            try await homeSnapshot("10-return-home", state: state, window: window)
        }

        func chromeRect(_ kind: ReaderChromeMarkerView.Kind, window: NSWindow) -> CGRect? {
            func find(_ view: NSView) -> ReaderChromeMarkerView? {
                if let marker = view as? ReaderChromeMarkerView, marker.kind == kind { return marker }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            guard let host = window.contentView, let marker = find(host) else { return nil }
            return host.convert(marker.bounds, from: marker)
        }

        enum Inspector { case none, edit, fill }

        func toolbarChrome(state: AppState, window: NSWindow, row: SecondaryRow?,
                           inspector: Inspector) async throws -> [String: Any] {
            let rows = row.map { [$0] } ?? []
            guard state.openSecondaryRows == rows, !state.rightPanelVisible,
                  !state.performancePanelVisible, !state.searchSidebarVisible,
                  state.contentEditInspectorVisible == (inspector == .edit),
                  state.fillSignInspectorVisible == (inspector == .fill) else {
                throw CaptureError("Toolbar or inspector ownership differs for \(rows)")
            }
            let expectedHeight = row == nil ? CGFloat.zero : ReaderChrome.secondaryToolbarHeightPt
            let expectedEdit = inspector == .edit ? ReaderChrome.editingPanelWidthPt : 0
            let expectedFill = inspector == .fill ? ReaderChrome.editingPanelWidthPt : 0
            let expectedLeading = state.sidebarVisible && state.document != nil ? ReaderChrome.sidebarTotalWidthPt : 0
            var measured: [String: Any] = [:]
            do {
                try await wait("secondary row and inspector native geometry") {
                    window.contentView?.layoutSubtreeIfNeeded()
                    guard let host = window.contentView,
                          let slot = self.chromeRect(.secondaryRowSlot, window: window),
                          let edit = self.chromeRect(.editingInspectorSlot, window: window),
                          let fill = self.chromeRect(.fillSignInspectorSlot, window: window) else { return false }
                    measured = ["open_rows": state.openSecondaryRows.map(\.rawValue),
                        "row_slot_points": [slot.minX, slot.minY, slot.width, slot.height],
                        "edit_inspector_width": edit.width, "fill_inspector_width": fill.width,
                        "assistant_visible": state.rightPanelVisible,
                        "annotation_tool": String(describing: state.annotationTool),
                        "content_tool": state.contentEditTool,
                        "fill_tool": state.armedFillSignTool?.rawValue as Any? ?? NSNull()]
                    guard abs(slot.height - expectedHeight) < 0.5,
                          abs(edit.width - expectedEdit) < 0.5,
                          abs(fill.width - expectedFill) < 0.5 else { return false }
                    if row != nil {
                        guard let toolbar = self.chromeRect(.secondaryToolbar, window: window),
                              abs(toolbar.height - ReaderChrome.secondaryToolbarHeightPt) < 0.5,
                              abs(toolbar.minX - expectedLeading) < 0.5,
                              abs(toolbar.maxX - (host.bounds.maxX - expectedEdit - expectedFill)) < 0.5
                        else { return false }
                        measured["row_content_points"] = [toolbar.minX, toolbar.minY, toolbar.width, toolbar.height]
                    }
                    return true
                }
            } catch { throw CaptureError("\(error); chrome=\(measured)") }
            return measured
        }

        func captureToolbarInspectors(state: AppState, window: NSWindow) async throws {
            environment["date_preview_clock"] = "2000-01-01T12:00:00Z; UTC"
            environment["capture_color_space"] = "sRGB; 8-bit BGRA; SDR"
            window.setContentSize(CGSize(width: 1200, height: 800))
            guard state.openDocumentInTab(options.fixture) else { throw CaptureError("Cannot open toolbar fixture") }
            state.zoomActual()
            state.scroll(toFraction: 0)
            func shot(_ id: String, row: SecondaryRow? = nil, inspector: Inspector = .none,
                      annotation: AnnotationTool = .select, content: String = "select",
                      fill: FillSignTool? = nil) async throws {
                guard state.annotationTool == annotation, state.contentEditTool == content,
                      state.armedFillSignTool == fill else { throw CaptureError("Wrong armed tool before \(id)") }
                _ = try await toolbarChrome(state: state, window: window, row: row, inspector: inspector)
                try await snapshot(id, state: state, window: window)
                let chrome = try await toolbarChrome(state: state, window: window, row: row, inspector: inspector)
                guard state.annotationTool == annotation, state.contentEditTool == content,
                      state.armedFillSignTool == fill, !captures.isEmpty else {
                    throw CaptureError("Tool changed while capturing \(id)")
                }
                captures[captures.count - 1]["tool_chrome"] = chrome
            }
            try await shot("01-document-idle")
            state.toggleAnnotationTools()
            try await shot("02-annotate-row", row: .annotations)
            state.toggleAnnotationTool(.highlight)
            try await shot("03-highlight-armed", row: .annotations, annotation: .highlight)
            state.toggleAnnotationTool(.note)
            try await shot("04-note-armed", row: .annotations, annotation: .note)
            state.toggleAnnotationTool(.note)
            try await shot("05-annotate-disarmed", row: .annotations)
            state.toggleContentEditing()
            try await shot("06-edit-row", row: .contentEdit)
            state.selectContentTool("text")
            try await shot("07-edit-text-inspector", row: .contentEdit, inspector: .edit, content: "text")
            state.selectContentTool("link")
            try await shot("08-edit-link-inspector", row: .contentEdit, inspector: .edit, content: "link")
            guard state.cancelContentTool() else { throw CaptureError("Edit tool did not clear") }
            try await shot("09-edit-tool-cleared", row: .contentEdit)
            state.toggleFillAndSign()
            try await shot("10-fill-sign-row", row: .fillAndSign)
            let tools: [(FillSignTool, String, AnnotationTool)] = [
                (.text, "11-fill-text-inspector", .textBox), (.signature, "12-signature-inspector", .select),
                (.date, "13-date-inspector", .select), (.checkmark, "14-checkmark-inspector", .select),
                (.cross, "15-cross-inspector", .select), (.stamp, "16-stamp-inspector", .stamp),
                (.image, "17-image-inspector", .select)
            ]
            for (tool, id, annotation) in tools {
                state.selectFillSignTool(tool)
                try await shot(id, row: .fillAndSign, inspector: .fill, annotation: annotation, fill: tool)
            }
            state.clearFillSignTool()
            try await shot("18-fill-tool-cleared", row: .fillAndSign)
            state.toggleExport()
            try await shot("reference-export-row", row: .export)
            guard var reference = captures.popLast() else { throw CaptureError("Export reference is missing") }
            reference["deferred_reason"] = "Export subtools are not finalized; geometry is checked, appearance is not a baseline."
            deferredCaptures.append(reference)
            state.toggleAITools()
            try await shot("19-lyra-row", row: .lyra)
            // Exercise the actual assistant drawer without freezing its unfinished contents.
            state.toggleRightPanel()
            _ = try await settle(state: state, window: window)
            guard state.rightPanelVisible else { throw CaptureError("Assistant did not open before Edit") }
            state.toggleContentEditing()
            state.selectContentTool("text")
            try await shot("20-edit-after-assistant", row: .contentEdit, inspector: .edit, content: "text")
            state.toggleRightPanel()
            _ = try await settle(state: state, window: window)
            guard state.rightPanelVisible else { throw CaptureError("Assistant did not open before Fill & Sign") }
            state.toggleFillAndSign()
            state.selectFillSignTool(.signature)
            try await shot("21-fill-after-assistant", row: .fillAndSign, inspector: .fill, fill: .signature)
            state.sidebarVisible = true
            try await shot("22-sidebar-with-inspector", row: .fillAndSign, inspector: .fill, fill: .signature)
            window.setContentSize(CGSize(width: 960, height: 640))
            try await shot("23-narrow-with-inspector", row: .fillAndSign, inspector: .fill, fill: .signature)
            window.setContentSize(CGSize(width: 1200, height: 800))
            state.sidebarVisible = false
            try await shot("24-inspector-window-restored", row: .fillAndSign, inspector: .fill, fill: .signature)
            state.toggleFillAndSign()
            try await shot("25-rows-closed-restored")
            state.closeTab(0)
            try await homeSnapshot("26-home-no-document", state: state, window: window)
            let chrome = try await toolbarChrome(state: state, window: window, row: nil, inspector: .none)
            captures[captures.count - 1]["tool_chrome"] = chrome
        }

        func fullScreen(window: NSWindow, entering: Bool) async throws {
            fullScreenTransitionCompleted = false
            let name = entering ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification
            let observer = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fullScreenTransitionCompleted = true }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            window.toggleFullScreen(nil)
            try await wait(entering ? "enter full screen" : "exit full screen") {
                fullScreenTransitionCompleted && window.styleMask.contains(.fullScreen) == entering
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        func capture(registry: ReaderWindowRegistry) async throws {
            PerfTrace.setCapture { [frames] line in frames.append(line) }
            try await wait("production reader window") { registry.sessions.first?.window?.contentView != nil }
            guard let session = registry.sessions.first, let window = session.window,
                  let content = window.contentView else { throw CaptureError("Reader window is missing") }
            try await wait("production Metal canvas") { self.canvas(in: content) != nil }
            guard let canvas = canvas(in: content) else { throw CaptureError("Metal canvas is missing") }
            let state = session.state
            state.sidebarVisible = false
            window.setFrameOrigin(CGPoint(x: 80, y: 100))
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApplication.shared.activate(ignoringOtherApps: true)
            environment = [
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "language": options.language, "appearance": options.appearance,
                "locale": Locale.current.identifier,
                "system_font": NSFont.systemFont(ofSize: 14).fontName,
                "gpu": (canvas.layer as? CAMetalLayer)?.device?.name ?? "unavailable",
                "capture": "ScreenCaptureKit.currentProcess.ownWindowInDisplay", "source": "packaged-debug-application",
                "bundle_identifier": Bundle.main.bundleIdentifier ?? "unavailable",
                "screen_points": window.screen.map { [$0.frame.width, $0.frame.height] } ?? [],
                "source_fixture": options.fixture.lastPathComponent,
                "baseline_status": "unreviewed"
            ]
            if let screen = window.screen, let width = DisplayCalibration.physicalWidthMm(of: screen) {
                environment["physical_width_mm"] = width
            }
            if let number = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let display = CGDirectDisplayID(number.uint32Value)
                guard let mode = CGDisplayCopyDisplayMode(display) else {
                    throw CaptureError("Display mode is unavailable")
                }
                environment["display_mode_points"] = [mode.width, mode.height]
                environment["display_backing_pixels"] = [mode.pixelWidth, mode.pixelHeight]
            }
            if options.suite == "reader-shell" {
                try await captureReaderShell(state: state, window: window)
                return
            }
            if options.suite == "toolbar-inspectors" {
                try await captureToolbarInspectors(state: state, window: window)
                return
            }
            guard state.open(url: options.fixture) else { throw CaptureError("Cannot open synthetic visual fixture") }
            state.zoomActual()
            state.scroll(toFraction: 0)
            try await snapshot("01-default-100", state: state, window: window, expectation: .topEdge)
            window.setContentSize(CGSize(width: 1200, height: 800))
            try await snapshot("02-fixed-100", state: state, window: window, expectation: .topEdge)
            state.sidebarVisible = true
            try await snapshot("03-sidebar-open", state: state, window: window, expectation: .topEdge)
            state.sidebarVisible = false
            try await snapshot("04-sidebar-restored", state: state, window: window, expectation: .topEdge)
            window.setContentSize(CGSize(width: 960, height: 640))
            try await snapshot("05-resize-small", state: state, window: window, expectation: .topEdge)
            window.setContentSize(CGSize(width: 1200, height: 800))
            try await snapshot("06-resize-restored", state: state, window: window, expectation: .topEdge)
            state.zoomFitWidth()
            state.scroll(toFraction: 0)
            try await snapshot("07-fit-width", state: state, window: window, expectation: .topEdge)
            state.zoomIn()
            state.zoomIn()
            state.scroll(toFraction: 0)
            try await snapshot("08-zoom-in", state: state, window: window, expectation: .topEdge)
            state.zoomActual()
            state.scroll(toFraction: 0)
            try await snapshot("09-zoom-restored", state: state, window: window, expectation: .topEdge)
            try await fullScreen(window: window, entering: true)
            try await snapshot("10-fullscreen", state: state, window: window, expectation: .fitted)
            try await fullScreen(window: window, entering: false)
            try await snapshot("11-fullscreen-restored", state: state, window: window, expectation: .topEdge)
            state.zoomFitPage()
            try await snapshot("12-fit-page-window", state: state, window: window, expectation: .fitted)
            let multipage = options.fixture.deletingLastPathComponent().appendingPathComponent("paper-multipage.pdf")
            guard state.open(url: multipage), state.document?.pageCount == 3 else {
                throw CaptureError("Cannot open three-page visual fixture")
            }
            // A zero preferred gap exercises the fitted spacing that excludes neighboring paper.
            state.setPageGap(0)
            for (page, id, identity) in [(0, "13-fit-page-first", "magenta"),
                                       (1, "14-fit-page-middle", "cyan"),
                                       (2, "15-fit-page-last", "yellow")] {
                state.gotoPage(page)
                state.zoomFitPage()
                try await snapshot(id, state: state, window: window, identity: identity, expectation: .fitted)
                guard state.currentPage == page + 1 else { throw CaptureError("Wrong fitted page in \(id)") }
            }
            state.zoomActual()
            state.scroll(toFraction: 1)
            try await snapshot("16-document-end-100", state: state, window: window,
                               expectation: .bottomEdge, requiredMarker: "green")
            try await nativeChromeProbe(state: state, window: window)
        }

        func writeManifest(error: String?) throws {
            var report: [String: Any] = [
                "schema_version": 1, "status": error == nil ? "candidate" : "failed",
                "suite": options.suite,
                "environment": environment, "captures": captures,
                "mutation": options.mutation as Any? ?? NSNull()
            ]
            if let error { report["error"] = error }
            if !deferredCaptures.isEmpty { report["deferred_captures"] = deferredCaptures }
            let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try bytes.write(to: options.output.appendingPathComponent("capture.json"), options: .atomic)
        }
    }
}
#endif
