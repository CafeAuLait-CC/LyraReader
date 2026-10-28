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
            let chrome = PageChromeGeometry.rectangles(frames: [page], viewport: canvas.bounds.size,
                contentWidthPt: 595, zoom: 1, scrollYPt: 0)
            require(canvas.pageChromeRectangles == chrome,
                    "resize step \(index) updates paper edges in the same transaction")
        }
        // Zoom and restore use AppKit's real action, including its native animation.
        for _ in 0..<2 {
            window.performZoom(nil)
            try await Task.sleep(for: .milliseconds(450))
            canvas.layoutSubtreeIfNeeded()
            require(canvas.lastAttemptViewportSize == canvas.bounds.size,
                    "native zoom/restore settles with matching pixels and bounds")
        }
        let attempts = canvas.frameAttemptCount
        try await Task.sleep(for: .milliseconds(250))
        require(canvas.frameAttemptCount == attempts,
                "a settled visible resize canvas schedules no permanent frame loop")
    }
}
