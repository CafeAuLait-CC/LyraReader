#if DEBUG
import AppKit
import CoreGraphics
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
            guard mutation == nil || ["scale", "chrome"].contains(mutation) else {
                throw CaptureError("Visual mutation must be scale or chrome")
            }
            options = Options(fixture: fixture, output: output, language: language,
                              appearance: appearance, mutation: mutation)
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
                "lyrareader.didMigratePreferences": true
            ], forName: UserDefaults.argumentDomain)
            AppState.recordsRecentDocuments = false
            AppState.usesDocumentKnowledge = false
            AppState.usesStoredReadingLayoutPreferences = false
            AppState.usesStoredSidebarTab = false
            AppState.usesStoredSidePanelPreferences = false
            ReaderMotion.reduceMotionOverride = true
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
        var environment: [String: Any] = [:]
        var fullScreenTransitionCompleted = false
        var capturedWindowFrame = CGRect.zero
        var capturedContentRect = CGRect.zero

        init(options: Options) { self.options = options }

        func wait(_ description: String, until condition: () -> Bool) async throws {
            for _ in 0..<800 {
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
              try await wait("visible current PDF frame after layout and canvas replacement") {
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
                scale: window.backingScaleFactor, displayID: CGDirectDisplayID(number.uint32Value))
            capturedWindowFrame = result.frame
            capturedContentRect = result.contentRect
            return result.image
        }

        // Keep ScreenCaptureKit's non-Sendable snapshot/filter objects on its nonisolated
        // async executor. Only immutable CGImage pixels cross back to the main actor.
        nonisolated static func captureOwnWindow(windowID: CGWindowID, scale: CGFloat, displayID: CGDirectDisplayID) async throws -> WindowImage {
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

        func snapshot(_ id: String, state: AppState, window: NSWindow) async throws {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
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
            guard let paper = canvas.pageChromeRectangles.first,
                  let layer = canvas.layer as? CAMetalLayer else { throw CaptureError("Missing native paper chrome") }
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
                    window.makeKeyAndOrderFront(nil)
                    NSApplication.shared.activate(ignoringOtherApps: true)
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
                for (name, sourceX, sourceY) in [("red", CGFloat(33), CGFloat(30)),
                    ("blue", CGFloat(579), CGFloat(30)), ("green", CGFloat(33), CGFloat(762)),
                    ("orange", CGFloat(579), CGFloat(762))] {
                    let point = CGPoint(x: canvasLeft + paper.minX + sourceX * state.zoomFactor,
                                        y: canvasTop + paper.minY + sourceY * state.zoomFactor)
                    let x = Int((point.x * scale).rounded())
                    let y = Int((point.y * scale).rounded())
                    let visible = CGRect(x: canvasLeft, y: canvasTop, width: bounds.width, height: bounds.height).contains(point)
                        && x >= 0 && x < image.width && y >= 0 && y < image.height
                    if name == "red" { mx = x; my = y }
                    guard visible else { continue }
                    let offset = (y * image.width + x) * 4
                    let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                    let matches: Bool
                    switch name {
                    case "red": matches = r > 180 && g < 90 && b < 90
                    case "blue": matches = b > 180 && r < 90 && g < 140
                    case "green": matches = g > 120 && r < 100 && b < 140
                    default: matches = r > 180 && g >= 100 && g < 220 && b < 100
                    }
                    markerChecks.append(["name": name, "pixel": [x, y], "rgb": [r, g, b], "match": matches])
                }
                markerVisible = markerChecks.contains { $0["name"] as? String == "red" }
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
                "active_application": NSApplication.shared.isActive, "key_window": window.isKeyWindow,
                "canvas_points": [canvasLeft, canvasTop, bounds.width, bounds.height],
                "canvas_window_points": [bounds.minX, bounds.minY, bounds.width, bounds.height],
                "window_frame_points": [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height],
                "captured_window_frame_points": [capturedWindowFrame.minX, capturedWindowFrame.minY,
                    capturedWindowFrame.width, capturedWindowFrame.height],
                "captured_content_rect_points": [capturedContentRect.minX, capturedContentRect.minY,
                    capturedContentRect.width, capturedContentRect.height],
                "paper_points": [paper.minX, paper.minY, paper.width, paper.height],
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
                "marker_pixel": [mx, my], "registration_markers": markerChecks, "fullscreen": window.styleMask.contains(.fullScreen)
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
            guard state.open(url: options.fixture) else { throw CaptureError("Cannot open synthetic visual fixture") }
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
            state.zoomActual()
            state.scroll(toFraction: 0)
            try await snapshot("01-default-100", state: state, window: window)
            window.setContentSize(CGSize(width: 1200, height: 800))
            try await snapshot("02-fixed-100", state: state, window: window)
            state.sidebarVisible = true
            try await snapshot("03-sidebar-open", state: state, window: window)
            state.sidebarVisible = false
            try await snapshot("04-sidebar-restored", state: state, window: window)
            window.setContentSize(CGSize(width: 960, height: 640))
            try await snapshot("05-resize-small", state: state, window: window)
            window.setContentSize(CGSize(width: 1200, height: 800))
            try await snapshot("06-resize-restored", state: state, window: window)
            state.zoomFitWidth()
            state.scroll(toFraction: 0)
            try await snapshot("07-fit-width", state: state, window: window)
            state.zoomIn()
            state.zoomIn()
            state.scroll(toFraction: 0)
            try await snapshot("08-zoom-in", state: state, window: window)
            state.zoomActual()
            state.scroll(toFraction: 0)
            try await snapshot("09-zoom-restored", state: state, window: window)
            try await fullScreen(window: window, entering: true)
            try await snapshot("10-fullscreen", state: state, window: window)
            try await fullScreen(window: window, entering: false)
            try await snapshot("11-fullscreen-restored", state: state, window: window)
            try await nativeChromeProbe(state: state, window: window)
        }

        func writeManifest(error: String?) throws {
            var report: [String: Any] = [
                "schema_version": 1, "status": error == nil ? "candidate" : "failed",
                "environment": environment, "captures": captures,
                "mutation": options.mutation as Any? ?? NSNull()
            ]
            if let error { report["error"] = error }
            let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try bytes.write(to: options.output.appendingPathComponent("capture.json"), options: .atomic)
        }
    }
}
#endif
