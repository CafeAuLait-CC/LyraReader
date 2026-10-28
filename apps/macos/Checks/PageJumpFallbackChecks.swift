import AppKit
import Foundation
@testable import LyraReaderKit

extension ReaderChecks {
    @MainActor static func pageJumpFallbackChecks(root: URL) async throws {
        func image(_ generation: UInt64, bytes: Int = 4) -> PageImage {
            PageImage(pixelWidth: 1, pixelHeight: 1, pointSize: CGSize(width: 1, height: 1),
                      bgra: Data(repeating: 255, count: bytes), generation: generation)
        }
        var cache = PageBackdropCache(budgetBytes: 8)
        cache.insert(image(1), for: 1); cache.insert(image(2), for: 2)
        _ = cache.image(for: 1)
        cache.insert(image(3), for: 3)
        require(cache.contains(1) && !cache.contains(2) && cache.contains(3) && cache.usedBytes == 8,
                "preview history stays byte bounded and retains recently revisited pages")
        cache.insert(image(4, bytes: 16), for: 4)
        require(!cache.contains(4) && cache.usedBytes == 8, "an oversized preview cannot exceed its budget")

        _ = NSApplication.shared
        let canvas = MetalCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.contentWidthPt = 600
        canvas.annotationPageFrames = [PagePlacement(index: 50, topPt: 0, leftPt: 0,
                                                      widthPt: 600, heightPt: 800)]
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await eventually("an uncached page submits paper before any raster", {
            canvas.lastAttemptedPaperQuadCount == 1 && canvas.lastAttemptedQuadCount == 1
        })
        require(canvas.pages.isEmpty, "paper fallback queues no document raster or fake content")
        canvas.annotationPageFrames = []
        try await eventually("closing geometry removes the paper too", {
            canvas.lastAttemptedQuadCount == 0 && canvas.lastAttemptedPaperQuadCount == 0
        })

        let state = AppState(engine: try RustEngine())
        state.setDeviceScale(2)
        state.setViewportSize(CGSize(width: 959, height: 715))
        require(state.open(url: root.appendingPathComponent("tests/fixtures/index-past-120.pdf")),
                "long jump fixture opens")
        defer { state.closeTab(0) }
        state.gotoPage(50)
        try await eventually("a visited distant page retains a small preview", {
            state.isScreenPageCached(50) && state.isPageBackdropCached(50)
        })
        state.gotoPage(100)
        try await eventually("a second distant destination becomes sharp", { state.isScreenPageCached(100) })
        require(!state.isScreenPageCached(50), "the old sharp page has left the working set")
        state.gotoPage(50)
        require(state.canvasPages.contains {
            $0.placement.index == PlacementIndex.pageRaster(50) && $0.image.pixelWidth <= 512
                && $0.image.generation & (UInt64(1) << 62) != 0
        }, "revisiting a distant page shows cached content synchronously")
        require(state.pageBackdropCacheUsedBytes <= 8 * 1024 * 1024,
                "preview history retains at most eight MiB")
    }
}
