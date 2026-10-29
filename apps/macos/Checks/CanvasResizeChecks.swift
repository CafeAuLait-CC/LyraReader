import AppKit
import QuartzCore
import LyraReaderKit

extension ReaderChecks {
    @MainActor static func canvasResizeChecks() async throws {
        _ = NSApplication.shared
        let canvas = MetalCanvasView(frame: CGRect(x: 0, y: 0, width: 720, height: 520))
        let page = PagePlacement(index: 0, topPt: 0, leftPt: 0, widthPt: 595, heightPt: 842)
        canvas.contentWidthPt = 595
        canvas.annotationPageFrames = [page]
        canvas.pages = [CanvasPage(placement: page, image: PageImage(pixelWidth: 1, pixelHeight: 1,
            pointSize: CGSize(width: 595, height: 842), bgra: Data([255, 255, 255, 255]), generation: 1))]
        canvas.onFailure = { fatalError("resize surface: \($0)") }
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = canvas; window.makeKeyAndOrderFront(nil); window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        try await eventually("resize canvas has a surface and a frame", {
            canvas.hasAttachedSurface && canvas.frameAttemptCount > 0
        })
        require(canvas.layerContentsPlacement == .topLeft,
                "a retained drawable is anchored without independent-axis stretching")
        require((canvas.layer as? CAMetalLayer)?.presentsWithTransaction == true,
                "resizing retains atomic presentation with native page edges")
        // The paper is drawn in backing pixels while the edge/shadow chrome is drawn in points.
        // A CAMetalLayer defaults its contentsScale to 1.0; without the window scale the
        // drawable's pixels are presented as points and the paper is twice the size of its
        // chrome on a Retina display. This is the invariant that keeps the two in one space.
        require(abs(((canvas.layer as? CAMetalLayer)?.contentsScale ?? 0)
                    - window.backingScaleFactor) < 1e-9,
                "the drawable maps its pixels to the window's backing scale")
        let points = [CGSize(width: 900, height: 600), CGSize(width: 1240, height: 710),
                      CGSize(width: 1450, height: 880), CGSize(width: 1100, height: 720),
                      CGSize(width: 760, height: 540)]
        for (index, size) in points.enumerated() {
            let before = canvas.frameAttemptCount
            window.setContentSize(size)
            canvas.layoutSubtreeIfNeeded()
            require(canvas.frameAttemptCount > before,
                    "resize step \(index) submits before layout returns")
            require(canvas.lastAttemptViewportSize == canvas.bounds.size,
                    "resize step \(index) uses the current logical viewport")
            let scale = window.backingScaleFactor
            let expectedPixels = CGSize(width: (canvas.bounds.width * scale).rounded(),
                                        height: (canvas.bounds.height * scale).rounded())
            require(canvas.lastAttemptDrawableSize == expectedPixels,
                    "resize step \(index) uses a matching device-pixel drawable")
            let layerScale = (canvas.layer as? CAMetalLayer)?.contentsScale ?? 0
            require(abs(layerScale - scale) < 1e-9,
                    "resize step \(index) maps drawable pixels to points with the window scale")
            let chrome = PageChromeGeometry.rectangles(frames: [page], viewport: canvas.bounds.size,
                contentWidthPt: 595, zoom: 1, scrollYPt: 0)
            require(canvas.pageChromeRectangles == chrome,
                    "resize step \(index) updates paper edges in the same transaction")
            // Compare the paper's rectangle, converted from the drawable's pixels to points
            // with the layer's actual scale, against the chrome rectangle. A 1.0 contentsScale
            // leaves the paper at twice this rectangle while the chrome stays put.
            let offsetX = max(0, (canvas.bounds.width * scale - 595 * scale) / 2)
            let paperPixels = CanvasGeometry.pageRectInDevicePixels(
                pageTopPt: 0, pageLeftPt: 0, widthPt: 595, heightPt: 842,
                scrollYPt: 0, zoom: 1, backingScale: scale, contentOffsetXPx: offsetX)
            guard let paperChrome = canvas.pageChromeRectangles.first else {
                fatalError("FAIL: resize step \(index) drew no page chrome")
            }
            let paperPoints = CGRect(x: paperPixels.minX / layerScale,
                                     y: paperPixels.minY / layerScale,
                                     width: paperPixels.width / layerScale,
                                     height: paperPixels.height / layerScale)
            require(abs(paperPoints.minX - paperChrome.minX) < 0.5
                        && abs(paperPoints.minY - paperChrome.minY) < 0.5
                        && abs(paperPoints.width - paperChrome.width) < 0.5,
                    "resize step \(index) draws the paper and its chrome in one coordinate space")
        }
        // Zoom and restore use AppKit's real action, including its native animation.
        for _ in 0..<2 {
            window.performZoom(nil)
            try await Task.sleep(for: .milliseconds(450))
            canvas.layoutSubtreeIfNeeded()
            require(canvas.lastAttemptViewportSize == canvas.bounds.size,
                    "native zoom/restore settles with matching pixels and bounds")
            require(abs(((canvas.layer as? CAMetalLayer)?.contentsScale ?? 0)
                        - window.backingScaleFactor) < 1e-9,
                    "native zoom/restore keeps the drawable on the window scale")
        }
        let attempts = canvas.frameAttemptCount
        try await Task.sleep(for: .milliseconds(250))
        require(canvas.frameAttemptCount == attempts,
                "a settled visible resize canvas schedules no permanent frame loop")
    }
}
