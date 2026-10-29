import AppKit
@testable import LyraReaderKit

/// Native regression for the P0 measurement layer (`LYRA_READER_PERF_TRACE=1`).
///
/// Drives a synthetic wheel scroll through the real `AppState` + `MetalCanvasView` model, the
/// same path `scripts/measure-perf-trace.py` uses, then asserts:
///
/// 1. the trace carries `input`, `viewport`, `tile`, `frame` and `sharp` records;
/// 2. every timing is finite and non-negative, a presented frame never reports 0 as its
///    presentation time, and the event order is consistent (input sequence, viewport sequence,
///    tile enqueue → start → done → drawn, sharp after its input and after its viewport plan);
/// 3. running the identical scenario with the trace **off** produces no perf records and leaves
///    the tile-cache counters and the final canvas page list identical — instrumentation must not
///    perturb behaviour.
///
/// Both scenarios open their own copy of the committed `multipage.pdf` fixture through the real
/// Rust engine, with the same viewport and one identical scroll step from a settled start.
extension ReaderChecks {
    @MainActor static func perfTraceChecks(root: URL) async throws {
        try await perfTraceInstanceChecks(root: root)
        let fixture = root.appendingPathComponent("tests/fixtures/multipage.pdf")
        require(FileManager.default.fileExists(atPath: fixture.path),
                "perf trace: multipage fixture exists")
        let traced = try await runPerfTraceScenario(fixture: fixture, tracing: true)
        let plain = try await runPerfTraceScenario(fixture: fixture, tracing: false)

        // ── the record kinds the later optimization work depends on ──────────────
        let records = traced.records
        let kinds = Set(records.compactMap { $0["kind"] as? String })
        for required in ["input", "viewport", "tile", "frame", "sharp"] {
            require(kinds.contains(required), "perf trace contains \(required) records")
        }
        require(plain.lines.isEmpty, "turning the trace off emits no perf records")

        // ── every recorded timing is real (finite, non-negative) ────────────────
        func number(_ record: [String: Any], _ key: String) -> Double? {
            (record[key] as? NSNumber)?.doubleValue
        }
        for record in records {
            let kind = record["kind"] as? String ?? "?"
            guard let time = number(record, "time") else {
                fatalError("FAIL: perf trace \(kind) record has no numeric time")
            }
            require(time.isFinite && time >= 0, "perf trace \(kind) time is finite and non-negative")
            for key in ["wait_ms", "exec_ms"] where record[key] != nil {
                guard let value = number(record, key) else {
                    fatalError("FAIL: perf trace \(kind).\(key) is not numeric")
                }
                require(value.isFinite && value >= 0, "perf trace \(kind).\(key) is non-negative")
            }
        }

        // A presented frame's timestamp is either a positive host time or the literal
        // "unavailable" with a reason — never 0 silently standing in for "not measured".
        let frames = records.filter { $0["kind"] as? String == "frame" }
        for frame in frames {
            if let presented = frame["presented_time"] as? NSNumber {
                require(presented.doubleValue > 0,
                        "a presented frame's Metal timestamp is positive, never 0")
            } else {
                require(frame["presented_time"] as? String == "unavailable",
                        "an unavailable presentation time is the string unavailable")
                require((frame["presented_reason"] as? String)?.isEmpty == false,
                        "an unavailable presentation time names its reason")
            }
        }
        require(frames.contains { (($0["quads"] as? NSNumber)?.intValue ?? 0) > 0 },
                "the scoped trace includes a frame with actual document pixels")
        require(frames.allSatisfy { ($0["quads"] as? NSNumber) != nil },
                "frame records carry a quad count")
        // The content-source metric joins a presented frame to the page list it drew through
        // `content_seq`; a frame that carries quads must also say whether any of them are real
        // page bitmaps (page_quads) and which commit produced them.
        require(frames.allSatisfy {
            let pageQuads = ($0["page_quads"] as? NSNumber)?.intValue ?? -1
            let quads = ($0["quads"] as? NSNumber)?.intValue ?? -1
            return pageQuads >= 0 && quads >= 0 && pageQuads <= quads
        }, "frame records carry page quads bounded by the submitted quad count")
        require(frames.allSatisfy { ($0["content_seq"] as? NSNumber) != nil },
                "frame records carry the content commit they drew")

        // ── consistent order ────────────────────────────────────────────────────
        let inputs = records.filter { $0["kind"] as? String == "input" }
        var lastInputSeq = -1.0
        var lastInputTime = -Double.infinity
        for input in inputs {
            guard let seq = number(input, "seq"), let time = number(input, "time") else {
                fatalError("FAIL: input record lacks seq/time")
            }
            require(seq > lastInputSeq, "input seq increases")
            require(time >= lastInputTime, "input times are non-decreasing")
            lastInputSeq = seq
            lastInputTime = time
        }
        let viewports = records.filter { $0["kind"] as? String == "viewport" }
        var lastViewportSeq = -1.0
        var lastViewportTime = -Double.infinity
        for viewport in viewports {
            guard let seq = number(viewport, "seq"), let time = number(viewport, "time") else {
                fatalError("FAIL: viewport record lacks seq/time")
            }
            require(seq > lastViewportSeq, "viewport seq increases")
            require(time >= lastViewportTime, "viewport times are non-decreasing")
            lastViewportSeq = seq
            lastViewportTime = time
        }
        let viewportTimes = Dictionary(uniqueKeysWithValues: viewports.compactMap { viewport in
            number(viewport, "seq").map { (Int($0), viewport) }
        })
        let inputBySeq = Dictionary(uniqueKeysWithValues: inputs.compactMap { input in
            number(input, "seq").map { (Int($0), input) }
        })

        // Tile lifecycle: for one raster key, enqueue precedes start precedes done precedes drawn.
        // Page rasters and thumbnails share `(page, lod, x, y)` across generations, so only the
        // pyramid-tile lifecycle is ordered here; their records are still covered by the timing
        // checks above.
        var tileTimes: [String: [String: Double]] = [:]
        for tile in records where tile["kind"] as? String == "tile" {
            guard tile["source"] as? String == "tile" else { continue }
            let key = "\(tile["page"] ?? -1)/\(tile["lod"] ?? -1)/\(tile["x"] ?? -1)/\(tile["y"] ?? -1)"
            let phase = tile["phase"] as? String ?? "?"
            guard let time = number(tile, "time") else { continue }
            tileTimes[key, default: [:]][phase] = max(time, tileTimes[key]?[phase] ?? -.infinity)
        }
        for (key, phases) in tileTimes {
            if let enqueue = phases["enqueue"], let start = phases["start"] {
                require(enqueue <= start, "tile \(key): enqueue precedes start")
            }
            if let start = phases["start"], let done = phases["done"] {
                require(start <= done, "tile \(key): start precedes done")
            }
            if let done = phases["done"], let drawn = phases["drawn"] {
                require(done <= drawn, "tile \(key): done precedes drawn")
            }
        }

        // Sharp is committed only after a real input and after the viewport plan it confirms.
        // The first-open sharp has no input yet (`after_input_seq` is absent), which is expected:
        // first_sharp_ms is measured from launch/open, not from a scroll.
        let sharps = records.filter { $0["kind"] as? String == "sharp" }
        require(!sharps.isEmpty, "perf trace contains at least one sharp commit")
        var correlatedSharps = 0
        for sharp in sharps {
            guard let time = number(sharp, "time"),
                  let viewportSeq = number(sharp, "viewport_seq"),
                  let offset = number(sharp, "offset_pt") else {
                fatalError("FAIL: sharp record lacks its correlation fields")
            }
            guard let viewport = viewportTimes[Int(viewportSeq)],
                  let viewportTime = number(viewport, "time") else {
                fatalError("FAIL: sharp names a viewport seq that is not in the trace")
            }
            require(viewportTime <= time, "sharp follows the viewport plan it confirms")
            if let afterInputSeq = number(sharp, "after_input_seq") {
                correlatedSharps += 1
                guard let input = inputBySeq[Int(afterInputSeq)],
                      let inputTime = number(input, "time") else {
                    fatalError("FAIL: sharp names an input seq that is not in the trace")
                }
                require(inputTime <= time, "sharp follows the input it attributes itself to")
                // The resting offset the sharp reports is the offset the last input aimed at;
                // the measurement harness pairs them the same way.
                if let destination = number(input, "destination_pt") {
                    require(abs(destination - offset) <= 0.6,
                            "sharp offset matches the destination of its last input")
                }
            }
            let sources = sharp["sources"] as? [String] ?? []
            require(!sources.isEmpty && sources.allSatisfy { $0 == "tile" || $0 == "page-raster" },
                    "sharp sources are only sharp sources, never previews/thumbnails")
            require((sharp["pages"] as? [Any])?.count == sources.count,
                    "sharp names one source per visible page")
        }
        require(correlatedSharps > 0, "a sharp commit follows the synthetic scroll input")

        // Every committed page list also carries its content classification, aligned with its
        // pages. Sharp pages use only the two sharp sources; a lower-quality fallback is named
        // rather than silently counted as sharp, and `none` means the canvas had only paper.
        let contents = records.filter { $0["kind"] as? String == "content" }
        require(!contents.isEmpty, "perf trace contains content classifications")
        let allowedSources: Set<String> = ["tile", "page-raster", "preview", "history",
                                           "thumbnail", "previous-tile", "previous-raster",
                                           "partial-tile", "none"]
        for content in contents {
            let pages = content["pages"] as? [Any] ?? []
            let sources = content["sources"] as? [String] ?? []
            require(pages.count == sources.count,
                    "content names one source per on-screen page")
            require(sources.allSatisfy { allowedSources.contains($0) },
                    "content sources use the documented source vocabulary")
            let anchor = content["anchor_page"] as? NSNumber
            require(anchor != nil, "content names the anchor page")
            let anchorSource = content["anchor_source"] as? String
            require(anchorSource == "none" || sources.contains(anchorSource ?? ""),
                    "content anchor source is the anchor page's own source")
        }
        let contentsBySeq = Dictionary(uniqueKeysWithValues: contents.compactMap { content in
            number(content, "content_seq").map { (Int($0), content) }
        })
        var correlatedContentFrames = 0
        for frame in frames {
            guard let seq = number(frame, "content_seq"), seq > 0 else { continue }
            guard let content = contentsBySeq[Int(seq)],
                  let contentTime = number(content, "time"),
                  let frameTime = number(frame, "time") else {
                fatalError("FAIL: frame names content_seq \(Int(seq)) that has no content record")
            }
            require(contentTime <= frameTime,
                    "content commit precedes the frame that drew it")
            correlatedContentFrames += 1
        }
        require(correlatedContentFrames > 0,
                "a frame is correlated with the page list it drew")
        require(frames.contains { $0["presented"] as? Bool == true }
                    || frames.contains { $0["presented"] as? Bool == false },
                "the canvas submitted at least one frame (presented or occluded)")

        // ── trace off must not perturb the cache or what is drawn ───────────────
        require(traced.counters.insertions == plain.counters.insertions,
                "tile-cache insertions are identical with the trace off")
        require(traced.counters.tileRasterCount == plain.counters.tileRasterCount,
                "rasterized tile count is identical with the trace off")
        require(traced.counters.tileCount == plain.counters.tileCount,
                "final tile-cache tile count is identical with the trace off")
        require(traced.counters.usedBytes == plain.counters.usedBytes,
                "final tile-cache bytes are identical with the trace off")
        require(traced.counters.pageRasterCount == plain.counters.pageRasterCount,
                "whole-page raster count is identical with the trace off")
        require(traced.counters.evictions == plain.counters.evictions,
                "tile-cache evictions are identical with the trace off")
        require(traced.canvasFingerprint == plain.canvasFingerprint,
                "the final drawn page list is identical with the trace off")
    }

    @MainActor private static func perfTraceInstanceChecks(root: URL) async throws {
        let collector = PerfTraceCollector()
        PerfTrace.setEnabled(true)
        PerfTrace.setCapture { collector.append($0) }
        let first = AppState(engine: try RustEngine())
        let second = AppState(engine: try RustEngine())
        defer {
            first.closeTab(0); second.closeTab(0)
            PerfTrace.setEnabled(false); PerfTrace.setCapture(nil)
        }
        let source = root.appendingPathComponent("tests/fixtures/multipage.pdf")
        require(first.open(url: source) && second.open(url: source), "two trace instances open")
        first.reloadVisiblePages(); second.reloadVisiblePages()
        let records = collector.lines.compactMap(parsePerfRecord)
        let viewports = records.filter { $0["kind"] as? String == "viewport" }
        let instances = Set(viewports.compactMap { $0["instance"] as? String })
        require(first.perfTraceInstanceID != second.perfTraceInstanceID && instances.count == 2,
                "overlapping per-window sequences carry distinct instance identities")
        for state in [first, second] {
            let owned = viewports.filter { $0["instance"] as? String == state.perfTraceInstanceID }
            let sequences = owned.compactMap { ($0["seq"] as? NSNumber)?.uint64Value }
            require(!sequences.isEmpty && zip(sequences, sequences.dropFirst()).allSatisfy { $0 < $1 },
                    "viewport sequences remain ordered within their owning instance")
        }
    }

    private struct PerfScenarioCounters {
        let insertions: Int
        let evictions: Int
        let tileRasterCount: Int
        let tileCount: Int
        let usedBytes: Int
        let pageRasterCount: Int
    }

    private struct PerfScenarioResult {
        let records: [[String: Any]]
        let lines: [String]
        let counters: PerfScenarioCounters
        let canvasFingerprint: [String]
    }

    /// One scripted scenario: fresh document copy, real engine, real canvas, one settled start,
    /// one identical wheel step, one settled end. Returns only observations.
    @MainActor
    private static func runPerfTraceScenario(fixture: URL, tracing: Bool) async throws -> PerfScenarioResult {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-perf-trace-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let copy = temporary.appendingPathComponent("document.pdf")
        try FileManager.default.copyItem(at: fixture, to: copy)

        let collector = PerfTraceCollector()
        PerfTrace.setEnabled(tracing)
        PerfTrace.setCapture({ collector.append($0) })
        defer {
            PerfTrace.setEnabled(false)
            PerfTrace.setCapture(nil)
        }

        let state = AppState(engine: try RustEngine(), preferFullPageRasters: false)
        state.setViewportSize(CGSize(width: 700, height: 500))
        guard state.open(url: copy) else {
            fatalError("FAIL: perf trace scenario could not open the fixture")
        }

        _ = NSApplication.shared
        let frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered,
                              defer: false)
        defer { window.orderOut(nil); window.contentView = nil; state.closeTab(0) }
        let view = MetalCanvasView(frame: frame)
        state.attachedCanvas = view
        view.modelCommitSnapshot = { CanvasModelCommit(state: state) }
        view.onScroll = { delta in state.scroll(byScreenPoints: delta) }
        view.onViewportSize = { size in state.setViewportSize(size) }
        view.interactionSnapshot = { (state.canvasPages, state.scrollYPt, state.zoomFactor) }
        view.perfStampProvider = { state.perfViewportStamp }
        view.onFailure = { fatalError("perf trace canvas regression: \($0)") }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        view.applyModelCommit()
        NSApplication.shared.activate(ignoringOtherApps: true)

        try await waitForSettledCanvas(state: state, view: view, requiringSharp: tracing)
        let start = state.scrollYPt
        // One wheel event, exactly as the measurement harness delivers it, then a full stop.
        state.scroll(byScreenPoints: 480)
        require(state.scrollYPt > start, "perf trace scenario scrolls forward")
        try await waitForSettledCanvas(state: state, view: view, requiringSharp: tracing)

        let stats = state.tileCacheSnapshot
        return PerfScenarioResult(
            records: collector.lines.compactMap(parsePerfRecord).filter {
                // Other windows may still complete work while this scenario is recording.
                // Engine stages have no window model; retain their numerical timing checks.
                $0["instance"] == nil || $0["instance"] as? String == state.perfTraceInstanceID
            },
            lines: collector.lines,
            counters: PerfScenarioCounters(
                insertions: stats.insertions,
                evictions: stats.evictions,
                tileRasterCount: state.tileRasterCount,
                tileCount: state.tileCacheTileCount,
                usedBytes: state.tileCacheUsedBytes,
                pageRasterCount: state.pageRasterCount),
            canvasFingerprint: canvasFingerprint(state.canvasPages))
    }

    /// Waits until no tile is queued or in flight and the observable state has stopped changing
    /// for several samples (page previews are not part of `scheduledTileWork`, so their effect on
    /// `pageRasterCount` is what the stability window catches). `requiringSharp` additionally
    /// requires a committed sharp viewport, which only the traced run can report.
    @MainActor
    private static func waitForSettledCanvas(state: AppState, view: MetalCanvasView,
                                             requiringSharp: Bool) async throws {
        var lastSignature = ""
        var stableSamples = 0
        for _ in 0..<800 {
            let work = state.scheduledTileWork
            let sharp = state.perfViewportStamp.token > 0
            let signature = "\(work.queued)/\(work.inFlight)/\(state.canvasPages.count)/"
                + "\(state.tileRasterCount)/\(state.pageRasterCount)/\(sharp)/\(view.frameAttemptCount)"
            let canvasReady = !state.canvasPages.isEmpty && view.frameAttemptCount > 0
            let sharpReady = !requiringSharp || sharp
            if work.queued == 0 && work.inFlight == 0 && canvasReady && sharpReady
                && signature == lastSignature {
                stableSamples += 1
                if stableSamples >= 8 { return }
            } else {
                stableSamples = 0
            }
            lastSignature = signature
            try await Task.sleep(for: .milliseconds(25))
        }
        fatalError("TIMEOUT: perf trace canvas did not settle (tracing=\(PerfTrace.enabled))")
    }

    /// Placement + bitmap identity of every drawn quad, in draw order. Raster generations are
    /// deliberately excluded: they are engine sequence numbers, not rendering identity.
    @MainActor
    private static func canvasFingerprint(_ pages: [CanvasPage]) -> [String] {
        pages.map { page in
            let p = page.placement
            return String(
                format: "%d/%.2f/%.2f/%.2f/%.2f/%.2f/%.2f/%d/%d/%d/%.3f/%.3f/%.3f/%.3f",
                p.index, Double(p.topPt), Double(p.leftPt), Double(p.widthPt), Double(p.heightPt),
                Double(p.sourceTopPt), Double(p.sourceHeightPt),
                page.image.pixelWidth, page.image.pixelHeight, Int(page.blend.rawValue),
                Double(page.source.minX), Double(page.source.minY),
                Double(page.source.width), Double(page.source.height))
        }
    }

    private static func parsePerfRecord(_ line: String) -> [String: Any]? {
        guard line.hasPrefix(PerfTrace.prefix) else { return nil }
        let body = String(line.dropFirst(PerfTrace.prefix.count))
        return (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
    }
}

/// Thread-safe sink: frame records are emitted from Metal's presentation callback, which is not
/// the main actor; the check reads the collected lines after the canvas has gone quiet.
private final class PerfTraceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
