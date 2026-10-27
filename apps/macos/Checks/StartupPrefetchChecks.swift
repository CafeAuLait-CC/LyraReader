import Foundation
import LyraReaderKit

/// A PDF engine that holds the first screen-resolution page raster open until the check lets it
/// finish, and records when the document-wide speculative scans are requested.
///
/// The whole point of the startup gate is an ordering property that a timing benchmark alone
/// cannot keep green: the reference/citation/caption scans must not be requested while the first
/// visible page raster is still in flight. The gate is a pure shell ordering decision, so it is
/// testable with a controlled engine and no real PDFium timing.
@MainActor private final class StartupPrefetchEngine: PreviewEngine {
    private var pendingVisible: CheckedContinuation<PageImage, Error>?
    private var automatic = false
    private(set) var visibleStarted = false
    private(set) var citationsPages: [Int] = []
    private(set) var captionMentionPages: [Int] = []
    private(set) var figuresCalls = 0
    private(set) var referencesCalls = 0

    override func openDocument(at url: URL) throws -> LoadedDocument {
        LoadedDocument(title: "Startup gate fixture", pageCount: 4, url: url,
                       firstPageSize: CGSize(width: 600, height: 800))
    }

    override func renderPage(_ page: Int, scale: CGFloat) async throws -> PageImage {
        // The sidebar thumbnail path supersamples at a scale below 2; it is visible content and
        // must not be blocked by this check. Only the screen-resolution page raster waits.
        if scale < 2 || automatic {
            return image(page: page, scale: scale)
        }
        visibleStarted = true
        return try await withCheckedThrowingContinuation { pendingVisible = $0 }
    }

    private func image(page: Int, scale: CGFloat) -> PageImage {
        let width = max(1, Int(ceil(600 * scale)))
        let height = max(1, Int(ceil(800 * scale)))
        return PageImage(pixelWidth: width, pixelHeight: height,
                         pointSize: CGSize(width: 600, height: 800),
                         bgra: Data(repeating: 255, count: width * height * 4),
                         generation: UInt64(300 + page))
    }

    func finishVisible() {
        automatic = true
        guard let continuation = pendingVisible else { return }
        pendingVisible = nil
        continuation.resume(returning: image(page: 0, scale: 2))
    }

    override func citations(_ page: Int) async throws -> [Citation] {
        citationsPages.append(page)
        return []
    }

    override func captionMentions(page: Int) async throws -> [CaptionMention] {
        captionMentionPages.append(page)
        return []
    }

    override func figures() async throws -> [Figure] {
        figuresCalls += 1
        return []
    }

    override func references() async throws -> [Reference] {
        referencesCalls += 1
        return []
    }

    override func contentHeightPt(gapPt: CGFloat) -> CGFloat { 4 * 800 }
    override func contentWidthPt(gapPt: CGFloat) -> CGFloat { 600 }
    override func pageTopPt(_ index: Int, gapPt: CGFloat) -> CGFloat { CGFloat(index) * 800 }
    override func pageIndex(atScrollYPt y: CGFloat, gapPt: CGFloat) -> Int {
        min(3, max(0, Int(y / 800)))
    }
    override func visiblePages(scrollYPt y: CGFloat, viewportHeightPt h: CGFloat,
                               gapPt: CGFloat, marginPt m: CGFloat) -> [PagePlacement] {
        (0..<4).compactMap { index in
            let top = CGFloat(index) * 800
            guard top + 800 >= y - m, top <= y + h + m else { return nil }
            return PagePlacement(index: index, topPt: top, leftPt: 0, widthPt: 600, heightPt: 800)
        }
    }
}

extension ReaderChecks {
    /// The first visible page raster must be requested before the offscreen reference/citation/
    /// caption scans, and those scans must still start once it finishes. Without the gate this
    /// check fails on the first assertion; it does not depend on how fast any machine is.
    @MainActor static func startupPrefetchChecks(url: URL) async throws {
        let engine = StartupPrefetchEngine()
        defer { engine.finishVisible() }
        let state = AppState(engine: engine, tileCacheBudgetBytes: 48 * 1024 * 1024,
                             preferFullPageRasters: true)
        state.zoomPercent = 100
        state.setViewportSize(CGSize(width: 900, height: 700))
        state.open(url: url)
        try await eventually("the first visible page raster is requested", { engine.visibleStarted })
        require(engine.citationsPages.isEmpty,
                "startup does not scan citations before the first visible raster")
        require(engine.captionMentionPages.isEmpty,
                "startup does not scan caption mentions before the first visible raster")
        require(engine.figuresCalls == 0,
                "startup does not build the caption index before the first visible raster")
        require(engine.referencesCalls == 0,
                "startup does not build the reference list before the first visible raster")

        engine.finishVisible()
        try await eventually("the deferred scans start after the first visible raster", {
            !engine.citationsPages.isEmpty && !engine.captionMentionPages.isEmpty
                && engine.figuresCalls > 0 && engine.referencesCalls > 0
        })
        require(state.pageRasterCacheCount > 0,
                "the visible raster that released the gate is in the page cache")
    }
}
