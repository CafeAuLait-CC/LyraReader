import Foundation
import LyraReaderKit

extension ReaderChecks {
    /// Opening a document must rasterize only the thumbnails the interface can show.
    ///
    /// The regression this guards: the open path used to batch pages 0..<24 through the serial
    /// PDFium queue while the lazy strip drew only the handful of cells it built. This opens a
    /// six-page fixture with a viewport that shows one page and no hosted strip (the canvas seed
    /// only), then makes the requests the strip's visible cells make while scrolling down and
    /// back. It asserts the on-screen-only seed, one raster per demanded page, and no repeat when
    /// the strip returns to the top.
    @MainActor static func thumbnailDemandChecks(root: URL) async throws {
        let source = root.appendingPathComponent("tests/fixtures/mixed-paper.pdf")
        require(FileManager.default.fileExists(atPath: source.path),
                "thumbnail-demand fixture exists")
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-thumbnail-demand-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let copy = temporary.appendingPathComponent("document.pdf")
        try FileManager.default.copyItem(at: source, to: copy)

        let collector = ThumbnailTraceCollector()
        PerfTrace.setEnabled(true)
        PerfTrace.setCapture { collector.append($0) }
        defer {
            PerfTrace.setEnabled(false)
            PerfTrace.setCapture(nil)
        }

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.open(url: copy), "thumbnail-demand fixture opens")
        try await eventually("the visible page's thumbnail is ready", { state.thumbnails[0] != nil })
        try await Task.sleep(for: .milliseconds(400))
        let seeded = collector.donePages
        require(seeded == [0],
                "open rasterizes only the page the canvas can show, got \(seeded)")
        require((1..<6).allSatisfy { state.thumbnails[$0] == nil },
                "pages outside the viewport have no thumbnail at open")

        // One row at a time, exactly what the lazy grid builds while the strip scrolls down.
        // Each request is the cell's `onAppear`; the page plus its prefetch row must rasterize.
        for page in 1...4 {
            state.loadThumbnails(page: page)
            try await eventually("scrolling to page \(page + 1) rasterizes it",
                                 { state.thumbnails[page] != nil })
        }
        try await eventually("the last prefetch row is ready", { state.thumbnails[5] != nil })
        try await Task.sleep(for: .milliseconds(300))
        let scrolled = collector.donePages
        require(scrolled == [0, 1, 2, 3, 4, 5],
                "each page rasterizes exactly once while scrolling down, got \(scrolled)")

        // Scrolling back to the top reuses the cache: no second raster of any page.
        state.loadThumbnails(page: 0)
        try await Task.sleep(for: .milliseconds(400))
        let after = collector.donePages
        require(after == scrolled,
                "scrolling back regenerates nothing (still \(after.count) rasters)")
        require(Set(after).count == after.count, "no page is rasterized twice")
    }
}

/// Thread-safe sink for the trace lines this check emits. Thumbnail completions are folded on
/// the main actor but the collector is also called from frame paths, so it takes a lock.
private final class ThumbnailTraceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    private var records: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return storage.compactMap { line in
            guard line.hasPrefix(PerfTrace.prefix) else { return nil }
            let body = String(line.dropFirst(PerfTrace.prefix.count))
            return (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        }
    }

    /// Pages whose thumbnail raster completed, in trace order.
    var donePages: [Int] {
        records.compactMap { record -> Int? in
            guard record["kind"] as? String == "tile",
                  record["phase"] as? String == "done",
                  record["source"] as? String == "thumbnail" else { return nil }
            return (record["page"] as? NSNumber)?.intValue
        }
    }
}
