import AppKit
import Foundation
import LyraReaderKit
import SwiftUI

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

    /// The open seed must cover every page the canvas can show, not a fixed count.
    ///
    /// Facing pages put two thumbnails in the same viewport row. The check restores into the
    /// first spread (pages 2–3) and asserts the no-argument `loadThumbnails()` call at open
    /// rasterizes both visible pages and neither the cover nor the next spread.
    @MainActor static func thumbnailFacingSeedChecks(root: URL) async throws {
        let source = root.appendingPathComponent("tests/fixtures/mixed-paper.pdf")
        require(FileManager.default.fileExists(atPath: source.path),
                "thumbnail-facing fixture exists")
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-thumbnail-facing-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let copy = temporary.appendingPathComponent("document.pdf")
        try FileManager.default.copyItem(at: source, to: copy)
        let viewport = CGSize(width: 1400, height: 700)
        let positionKey = "readingPosition:" + copy.path
        defer { UserDefaults.standard.removeObject(forKey: positionKey) }

        // Find the scroll offset of the first spread with a throwaway state: page 0 is a
        // centred cover, pages 1–2 are the first facing pair.
        let probe = AppState(engine: try RustEngine())
        probe.setViewportSize(viewport)
        require(probe.open(url: copy), "thumbnail-facing probe opens")
        // Let the probe's own open-time thumbnail finish before the trace is enabled; otherwise
        // its late completion is captured as a second raster of the same page.
        try await eventually("the probe's on-screen thumbnail finishes", { probe.thumbnails[0] != nil })
        probe.setLayoutMode(.facing)
        probe.gotoPage(1)
        let spreadOffset = probe.scrollYPt
        require(spreadOffset > 0, "the facing spread starts below the cover")
        // Commit the probe's debounced position save now so its task cannot rewrite the key
        // after this check removes it.
        _ = probe.flushPendingPositionSave()
        UserDefaults.standard.set(Double(spreadOffset), forKey: positionKey)

        let collector = ThumbnailTraceCollector()
        PerfTrace.setEnabled(true)
        PerfTrace.setCapture { collector.append($0) }
        defer {
            PerfTrace.setEnabled(false)
            PerfTrace.setCapture(nil)
        }

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(viewport)
        state.setLayoutMode(.facing)
        require(state.open(url: copy), "thumbnail-facing fixture opens into the saved spread")
        try await eventually("both pages of the facing spread have thumbnails", {
            state.thumbnails[1] != nil && state.thumbnails[2] != nil
        })
        try await Task.sleep(for: .milliseconds(400))
        let seeded = collector.donePages.sorted()
        require(seeded == [1, 2],
                "a facing spread seeds both visible pages and no more, got \(seeded)")
        require(state.thumbnails[0] == nil && state.thumbnails[3] == nil,
                "the cover and the next spread stay unrequested at open")
    }

    /// Page overview is a multi-column grid, not the single-column strip. Scroll it hard to the
    /// last row and require every visible cell there to have drawn a real thumbnail.
    @MainActor static func thumbnailOverviewChecks(root: URL) async throws {
        let source = root.appendingPathComponent("tests/fixtures/index-past-120.pdf")
        require(FileManager.default.fileExists(atPath: source.path),
                "thumbnail-overview fixture exists")
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-thumbnail-overview-\(UUID())")
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
        state.setViewportSize(CGSize(width: 1200, height: 800))
        require(state.open(url: copy), "thumbnail-overview fixture opens")

        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1200, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered,
                              defer: false)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        let host = NSHostingView(rootView: SidebarView(state: state, pageOverview: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity))
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.makeKeyAndOrderFront(nil)

        func nativeScrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { nativeScrollViews(in: $0) }
        }
        try await eventually("page overview lays out its grid", {
            host.layoutSubtreeIfNeeded()
            return !nativeScrollViews(in: host).isEmpty
        })
        try await eventually("the first overview row shows real thumbnails", {
            (0..<5).allSatisfy { state.thumbnails[$0] != nil }
        })
        try await Task.sleep(for: .milliseconds(300))

        // Five columns at 1200 pt (28 pt padding, 196 pt minimum cell, 28 pt spacing); the last
        // row of 130 pages is 125…129. Jump straight there: a fast overview scroll must fill
        // every cell the grid builds, with no blank placeholders left behind.
        guard let scroll = nativeScrollViews(in: host).first,
              let documentView = scroll.documentView else {
            fatalError("FAIL: page overview has no scroll view to drive")
        }
        let bottom = documentView.isFlipped
            ? max(0, documentView.frame.height - scroll.contentView.bounds.height)
            : 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        try await eventually("the last overview row shows real thumbnails", {
            (125...129).allSatisfy { state.thumbnails[$0] != nil }
        })
        try await Task.sleep(for: .milliseconds(300))
        let done = collector.donePages
        for page in 0..<5 {
            require(done.filter { $0 == page }.count == 1,
                    "overview page \(page + 1) rasterizes exactly once (got \(done))")
        }
        for page in 125...129 {
            require(done.filter { $0 == page }.count == 1,
                    "overview page \(page + 1) rasterizes exactly once after the jump")
        }
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
