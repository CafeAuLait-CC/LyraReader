import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - The metric definitions this trace exists to make measurable

/// Environment-gated performance trace (`LYRA_READER_PERF_TRACE=1`).
///
/// Every line is JSON under the `lyra-reader-perf-trace: ` prefix, the same stderr family as the
/// older `lyra-reader-scroll-trace: ` diagnostics, so one log can carry both without a parser
/// having to guess. Emitting is opt-in and every call site checks ``enabled`` before building a
/// payload: with the variable unset the cost is one predictable branch per event site (the tile
/// counters are guarded the same way), and no JSON, string, lock or timer is created.
///
/// # Why these numbers
///
/// The CLI bench's "viewport waiting" is the sum of raster time for visible-missing tiles inside
/// one scroll step; every step finishes its own work before the next starts. That number contains
/// no queue wait, no upload, no composite and no present, and the app's default path at ordinary
/// zoom is a single screen-resolution page raster that `TilePlanBenchmark` disables. Neither can
/// answer the question the performance work is judged by:
///
/// * **time from the last scroll input to the moment the whole visible viewport is at its target
///   sharpness** (``sharp`` events, then ``PerfTrace/frame(presented:...)`` for the presented
///   frame), and
/// * for a first open, **first present** and **first fully sharp**.
///
/// # "Sharp" — the exact definition
///
/// A viewport is sharp when every page it shows is covered at the current target sharpness by a
/// source that was **drawn** (it is in the canvas page list committed for the next frame), and no
/// preview or thumbnail is standing in for any part of it:
///
/// * **tile path** — every visible tile at the current target LOD (`AppState.rasterLod`, the
///   smallest pyramid level whose scale covers `zoom × deviceScale`) is in the tile cache and is
///   part of the drawn page list. A tile from an older LOD, a half-row, a missing column, or a
///   page-raster backdrop used because a row is incomplete is **not** sharp.
/// * **full-page path** — the drawn page raster's pixel size is at least
///   `zoomFactor × deviceScale` (`AppState.isScreenPageCached`); a 1× preview or a sidebar
///   thumbnail is never sharp, at any zoom.
///
/// A `sharp` record is emitted when a committed page list reaches that state. It is a
/// **model-level** commit: it says the pixels the next frame will draw are all sharp, not that a
/// display presented them. The matching presented frame is found through `PerfViewportStamp.token`
/// (the canvas copies the token into its `frame` record); without a display link, or when Metal
/// reports a zero host time, that correlation is reported as `unavailable` rather than
/// substituted with the commit time.
///
/// # Record kinds
///
/// | kind | when | key fields |
/// | --- | --- | --- |
/// | `launch` | app entry, or the first `AppState` in a check | `time` |
/// | `document` | open started / opened / closed | `phase`, `epoch`, `pages` |
/// | `input` | a scroll input landed | `seq`, `source`, `phase`, `offset_pt`, `delta_pt`, `destination_pt`, `epoch` |
/// | `viewport` | one committed visible-band plan | `seq`, `offset_pt`, `path`, `lod`, `visible_pages`, `viewport`, `sharp`, `visible_misses`, `queued_tiles`, `wanted_tiles`, `page_rasters`, `content_version` |
/// | `tile` | raster lifecycle for one unit | `phase` (`enqueue`/`start`/`done`/`failed`/`drawn`), `source` (`tile`/`page-raster`/`thumbnail`/`preview`), `page`, `lod`, `x`, `y`, `wait_ms`, `exec_ms`, `bytes`, `scale`, `detail` (`thumbnail` + `drawn` + `detail: sidebar` is a strip cell, not the canvas backdrop) |
/// | `queue` | one queued task finished | `category` (`tile`/`page-raster`/`thumbnail`/`text`/`index`), `wait_ms`, `exec_ms`, `page` |
/// | `frame` | a frame reached a terminal state | `presented`, `presented_time` (host seconds or `"unavailable"`), `presented_reason`, `time` (submit), `surface`, `sequence`, `token`, `epoch`, `quads`, `tile_quads`, `cpu_us`, `upload_ms`, `frame_index` |
/// | `sharp` | committed page list is fully sharp | `token`, `viewport_seq`, `offset_pt`, `path`, `lod`, `pages`, `sources`, `epoch`, `content_version`, `after_input_seq` (absent on the first open) |
/// | `raster` | a raster classification moved | `class` (`first`/`repeat-after-eviction`/`upload-after-cache-hit`), `source`, `page`, `lod`, `x`, `y`, `generation` |
/// | `stage` | one split of the raster/frame path | `name` (`raster_dispatch`/`raster_core`/`raster_resume_scheduled`/`raster_resumed`/`image_copy`/`thumbnail_downsample`/`upload`), `source`, `page`, `generation`, `ms`, `queue_wait_ms`, `scale` |
/// | `memory` | 1 Hz (`sample`), scroll idle (`scroll_stop`), quit (`terminate`), document close (`document_close_before`, `document_close`) | `phase`, `rss_bytes`, `tile_cache_bytes`, `page_raster_bytes`, `thumbnail_bytes`, `tile_count`, `page_raster_count`, `peak_bytes`, `evictions` |
/// | `summary` | document close | `rastered_tiles`, `drawn_tiles`, `first_rasters`, `repeat_after_eviction`, `prefetch_rastered_never_drawn`, `upload_after_cache_hit`, `evictions`, `content_version` |
///
/// The t0 question is explicit: `first_present_ms` / `first_sharp_ms` in the harness are measured
/// from the `launch` record (the earliest point the app instruments), and `document(open_start)`
/// is emitted separately for a per-open measurement. A `quit` does not close a document, so the
/// close records come from the real close paths (`document_close_*` + `summary`); `terminate` is
/// the last live sample when the process is asked to quit with the document still open.
///
/// `presented_time` is **never** 0 substituted for "unknown": Metal's zero timestamp means the
/// machine did not report presentation (display asleep, window occluded), so it is written as the
/// string `"unavailable"` next to a `presented_reason`.
///
/// Classifications are counted in the tile layer:
/// * `first` — the first raster of `(document version, page, LOD, x, y)`;
/// * `repeat-after-eviction` — the same content rasterised a second time after the cache dropped
///   it: the thrash signal;
/// * `upload-after-cache-hit` — the canvas uploaded a texture whose CPU image was already in the
///   tile cache (a re-upload with no re-raster);
/// * `prefetch-never-drawn` — counted at close: rasterised while only planned as prefetch and
///   never part of a drawn page list.
public enum PerfTrace {
    /// Prefix of every record. The parser keys on it; the scroll trace keeps its own prefix.
    public static let prefix = "lyra-reader-perf-trace: "
    /// The environment variable that opts in. Any value other than `1` leaves the trace off.
    public static let environmentVariable = "LYRA_READER_PERF_TRACE"

    // Written at process start from the environment, and by a native check between quiescent
    // phases only (all canvas frames drained, no raster task in flight). Reads on the display
    // thread (the presented handler) are the only off-main access; the value is a Bool, so a
    // reader either sees the check's final value or the launch value, never a torn one.
    nonisolated(unsafe) private static var enabledStorage =
        ProcessInfo.processInfo.environment[environmentVariable] == "1"
    // A check installs a capture instead of writing to stderr, so it can assert on the exact
    // lines a harness would parse without redirecting the process's own diagnostics.
    nonisolated(unsafe) private static var captureStorage: ((String) -> Void)?
    // One launch marker per process: emitted from the app entry point, or from the first
    // `AppState` when the shell is embedded in a check.
    nonisolated(unsafe) private static var launchReported = false

    /// Whether the trace is emitting. The hot paths test this before building any payload.
    public static var enabled: Bool { enabledStorage }

    /// The monotonic clock every record uses: seconds since boot, the same clock the existing
    /// scroll trace and Metal's presentation timestamps use.
    public static var now: Double { ProcessInfo.processInfo.systemUptime }

    /// Turns the trace on or off at runtime. Called once from a check between quiescent phases;
    /// nothing in the app calls it after launch.
    public static func setEnabled(_ enabled: Bool) { enabledStorage = enabled }

    /// Routes finished lines to `capture` (including the prefix) instead of stderr. `nil` writes
    /// to stderr again.
    public static func setCapture(_ capture: ((String) -> Void)?) { captureStorage = capture }

    /// Canvas-side classification counter: a texture was uploaded for a CPU image that had been
    /// uploaded before (a re-upload, not a re-raster). Process-wide, because the canvas has no
    /// document handle: a multi-window run interleaves its windows' uploads in the close
    /// summary. Mutated only on the main actor by the canvas; read by the document-close summary.
    nonisolated(unsafe) public private(set) static var uploadsAfterCacheHit = 0

    /// Records one `upload-after-cache-hit` classification (main actor only).
    public static func noteUploadAfterCacheHit() { uploadsAfterCacheHit += 1 }

    /// Starts a new document's classification window (main actor only).
    public static func resetUploadsAfterCacheHit() { uploadsAfterCacheHit = 0 }

    /// One value in a JSON record. Finite numbers only; anything the machine could not measure is
    /// ``unavailable`` and serialises as the string `"unavailable"`, not as 0.
    public enum Value {
        case int(Int)
        case double(Double)
        case string(String)
        case bool(Bool)
        case null
        case intArray([Int])
        case stringArray([String])
        case unavailable
    }

    /// Emits one record. `time` is added automatically unless the caller supplies it.
    public static func event(_ kind: String, _ fields: [String: Value], instance: String? = nil) {
        guard enabledStorage else { return }
        var json = "{\"kind\":\"\(escape(kind))\",\"time\":"
        json += serialize(fields["time"] ?? .double(now))
        if let instance { json += ",\"instance\":\"\(escape(instance))\"" }
        for key in fields.keys.sorted() where key != "time" {
            json += ",\"\(escape(key))\":"
            json += serialize(fields[key]!)
        }
        json += "}"
        emitLine(json)
    }

    // MARK: - Typed records (the schema)

    /// The first trace record of a process, emitted once. The app calls it from its entry point
    /// so `first_present_ms` / `first_sharp_ms` start as early as the trace can observe; a check
    /// that enables the trace later gets the marker from the first `AppState` it builds.
    public static func reportLaunchOnce() {
        guard enabledStorage, !launchReported else { return }
        launchReported = true
        event("launch", [:])
    }

    /// The document lifecycle. `pages` is unknown at `open_start` and filled in at `opened`.
    public static func document(instance: String? = nil, phase: String, epoch: UInt64, pages: Int? = nil, detail: String? = nil) {
        guard enabledStorage else { return }
        var fields: [String: Value] = ["phase": .string(phase), "epoch": .int(Int(epoch))]
        if let pages { fields["pages"] = .int(pages) }
        if let detail { fields["detail"] = .string(detail) }
        event("document", fields, instance: instance)
    }

    /// A scroll input that moved (or aimed to move) the content offset.
    ///
    /// `seq` is a monotonic input number, `source` names the input path (`wheel`, `keyboard`,
    /// `fraction`, `scrollbar`) and `epoch` is the document epoch the input belongs to.
    public static func input(instance: String? = nil, seq: UInt64, source: String, phase: String, offsetPt: CGFloat,
                             deltaPt: CGFloat, destinationPt: CGFloat?, epoch: UInt64) {
        guard enabledStorage else { return }
        var fields: [String: Value] = [
            "seq": .int(Int(seq)),
            "source": .string(source),
            "phase": .string(phase),
            "offset_pt": .double(Double(offsetPt)),
            "delta_pt": .double(Double(deltaPt)),
            "epoch": .int(Int(epoch)),
        ]
        if let destinationPt {
            fields["destination_pt"] = .double(Double(destinationPt))
        } else {
            fields["destination_pt"] = .unavailable
        }
        event("input", fields, instance: instance)
    }

    /// The committed visible-band plan for one `reloadVisiblePages` pass. `seq` is the viewport
    /// sequence number (monotonic per reader instance); `path` is the page's drawing path.
    public static func viewport(instance: String? = nil, seq: UInt64, epoch: UInt64, contentVersion: UInt64,
                                offsetPt: CGFloat, path: String, lod: UInt8,
                                visiblePages: [Int], viewport: CGRect, sharp: Bool,
                                visibleMisses: Int, queuedTiles: Int, wantedTiles: Int,
                                pageRasters: Int) {
        guard enabledStorage else { return }
        event("viewport", [
            "seq": .int(Int(seq)),
            "epoch": .int(Int(epoch)),
            "content_version": .int(Int(contentVersion)),
            "offset_pt": .double(Double(offsetPt)),
            "path": .string(path),
            "lod": .int(Int(lod)),
            "visible_pages": .intArray(visiblePages),
            "viewport": .string(String(format: "%.2f,%.2f,%.2f,%.2f",
                                       Double(viewport.minX), Double(viewport.minY),
                                       Double(viewport.width), Double(viewport.height))),
            "sharp": .bool(sharp),
            "visible_misses": .int(visibleMisses),
            "queued_tiles": .int(queuedTiles),
            "wanted_tiles": .int(wantedTiles),
            "page_rasters": .int(pageRasters),
        ], instance: instance)
    }

    /// One raster unit's lifecycle. `lod`/`x`/`y` are 0 for whole-page sources (they have no
    /// pyramid position); `scale` keeps their real resolution visible next to them.
    public static func tile(instance: String? = nil, phase: String, source: String, page: Int, lod: Int, x: Int, y: Int,
                            epoch: UInt64, contentVersion: UInt64, offsetPt: CGFloat,
                            waitMs: Double? = nil, execMs: Double? = nil, bytes: Int? = nil,
                            scale: CGFloat? = nil, detail: String? = nil) {
        guard enabledStorage else { return }
        var fields: [String: Value] = [
            "phase": .string(phase),
            "source": .string(source),
            "page": .int(page),
            "lod": .int(lod),
            "x": .int(x),
            "y": .int(y),
            "epoch": .int(Int(epoch)),
            "content_version": .int(Int(contentVersion)),
            "offset_pt": .double(Double(offsetPt)),
        ]
        if let waitMs { fields["wait_ms"] = .double(waitMs) }
        if let execMs { fields["exec_ms"] = .double(execMs) }
        if let bytes { fields["bytes"] = .int(bytes) }
        if let scale { fields["scale"] = .double(Double(scale)) }
        if let detail { fields["detail"] = .string(detail) }
        event("tile", fields, instance: instance)
    }

    /// One queued task: `wait_ms` is enqueue → start (time spent behind other work), `exec_ms`
    /// is start → the task folded its result into the shell. For engine calls `exec_ms` includes
    /// the main-actor resumption after the async raster finished, so it is **task latency, not
    /// pure raster time**: the engine's own `lyra-reader-raster:` lines carry the raster figure.
    /// Emitted at completion, so a task still waiting when the document closes has no record and
    /// is never counted as zero.
    public static func queue(instance: String? = nil, category: String, page: Int?, waitMs: Double, execMs: Double,
                             epoch: UInt64, detail: String? = nil) {
        guard enabledStorage else { return }
        var fields: [String: Value] = [
            "category": .string(category),
            "wait_ms": .double(waitMs),
            "exec_ms": .double(execMs),
            "epoch": .int(Int(epoch)),
        ]
        if let page { fields["page"] = .int(page) }
        if let detail { fields["detail"] = .string(detail) }
        event("queue", fields, instance: instance)
    }

    /// One stage inside a raster/frame path, for attributing latency the `queue` record alone
    /// cannot split. Names in use:
    ///
    /// * `raster_dispatch` — engine method entry (the shell task resumed) → the work running on
    ///   the engine's serial raster queue. `ms` is that dispatch wait.
    /// * `raster_core` — the Rust/PDFium raster call itself. `ms` is the real rasterisation time.
    /// * `raster_resume_scheduled` — emitted by the engine immediately *before* resuming the
    ///   awaiting task. No `ms`; the gap to `raster_resumed` is the main-actor wait.
    /// * `raster_resumed` — the shell task resumed after the await. Page raster and tile tasks
    ///   emit it before touching the result, so the gap is observable in the trace order.
    /// * `image_copy` — the tile result cropped into its placement bitmap (`TileImage.pageImage`).
    /// * `thumbnail_downsample` — the CGImage reduction of a sidebar thumbnail.
    /// * `upload` — one texture upload (`lyra_reader_gpu_upload_texture`), measured per page quad.
    ///
    /// A stage that does not exist on a path is simply absent. In particular the whole-page
    /// raster path has no decode/colour-conversion stage: the FFI hands back BGRA bytes that go
    /// straight to the GPU, and this trace does not invent an empty one.
    public static func stage(_ name: String, instance: String? = nil, source: String, page: Int? = nil,
                             generation: UInt64? = nil, milliseconds: Double? = nil,
                             queueWaitMs: Double? = nil, scale: Double? = nil,
                             epoch: UInt64? = nil, detail: String? = nil,
                             at time: Double? = nil) {
        guard enabledStorage else { return }
        var fields: [String: Value] = [
            "name": .string(name),
            "source": .string(source),
        ]
        if let page { fields["page"] = .int(page) }
        if let generation { fields["generation"] = .int(Int(generation)) }
        if let milliseconds { fields["ms"] = .double(milliseconds) }
        if let queueWaitMs { fields["queue_wait_ms"] = .double(queueWaitMs) }
        if let scale { fields["scale"] = .double(scale) }
        if let epoch { fields["epoch"] = .int(Int(epoch)) }
        if let detail { fields["detail"] = .string(detail) }
        if let time { fields["time"] = .double(time) }
        event("stage", fields, instance: instance)
    }

    /// A raster classification transition (counted in the tile layer / canvas, see the type doc).
    public static func raster(instance: String? = nil, classification: String, source: String, page: Int, lod: Int,
                              x: Int, y: Int, generation: UInt64?, epoch: UInt64,
                              contentVersion: UInt64) {
        guard enabledStorage else { return }
        var fields: [String: Value] = [
            "class": .string(classification),
            "source": .string(source),
            "page": .int(page),
            "lod": .int(lod),
            "x": .int(x),
            "y": .int(y),
            "epoch": .int(Int(epoch)),
            "content_version": .int(Int(contentVersion)),
        ]
        if let generation { fields["generation"] = .int(Int(generation)) }
        event("raster", fields, instance: instance)
    }

    /// A presented (or deliberately not presented) frame.
    ///
    /// `presentedTime` is Metal's host presentation timestamp when the machine reported one.
    /// `nil` is written as `"unavailable"` with `reason`; this function has no code path that
    /// substitutes 0. `submitTime` is the CPU submission uptime and is always measurable.
    public static func frame(presented: Bool, presentedTime: Double?, reason: String?,
                             submitTime: Double, surface: UInt64, sequence: UInt64,
                             stamp: PerfViewportStamp, cpuUs: UInt64, quads: Int,
                             tileQuads: Int, frameIndex: UInt64, uploadMs: Double? = nil, paperQuads: Int = 0) {
        guard enabledStorage else { return }
        var fields: [String: Value] = [
            "presented": .bool(presented),
            "surface": .int(Int(surface)),
            "sequence": .int(Int(sequence)),
            "token": .int(Int(stamp.token)),
            "epoch": .int(Int(stamp.epoch)),
            "content_version": .int(Int(stamp.contentVersion)),
            "path": .string(stamp.path),
            "lod": .int(Int(stamp.lod)),
            "offset_pt": .double(Double(stamp.offsetPt)),
            "cpu_us": .int(Int(cpuUs)),
            "quads": .int(quads),
            "paper_quads": .int(paperQuads),
            "document_quads": .int(max(0, quads - paperQuads)),
            "tile_quads": .int(tileQuads),
            "frame_index": .int(Int(frameIndex)),
        ]
        if let uploadMs { fields["upload_ms"] = .double(uploadMs) }
        fields["time"] = .double(submitTime)
        if presented, let presentedTime, presentedTime.isFinite, presentedTime > 0 {
            fields["presented_time"] = .double(presentedTime)
        } else {
            fields["presented_time"] = .unavailable
            fields["presented_reason"] = .string(reason ?? "presentation timestamp unavailable")
        }
        event("frame", fields, instance: stamp.instance)
    }

    /// The committed page list became fully sharp. `sources` names which sharp source each
    /// visible page used (`page-raster` or `tile`); previews and thumbnails are never listed.
    public static func sharp(instance: String? = nil, token: UInt64, viewportSeq: UInt64, epoch: UInt64,
                             contentVersion: UInt64, offsetPt: CGFloat, path: String, lod: UInt8,
                             pages: [Int], sources: [String], afterInputSeq: UInt64?) {
        guard enabledStorage else { return }
        var fields: [String: Value] = [
            "token": .int(Int(token)),
            "viewport_seq": .int(Int(viewportSeq)),
            "epoch": .int(Int(epoch)),
            "content_version": .int(Int(contentVersion)),
            "offset_pt": .double(Double(offsetPt)),
            "path": .string(path),
            "lod": .int(Int(lod)),
            "pages": .intArray(pages),
            "sources": .stringArray(sources),
        ]
        if let afterInputSeq { fields["after_input_seq"] = .int(Int(afterInputSeq)) }
        event("sharp", fields, instance: instance)
    }

    /// One RSS / cache memory sample. `rssBytes` is nil when the kernel call failed, which is
    /// reported as `"unavailable"` rather than as a zero-memory process.
    public static func memory(instance: String? = nil, phase: String, rssBytes: UInt64?, tileCacheBytes: Int,
                              pageRasterBytes: Int, thumbnailBytes: Int, tileCount: Int,
                              pageRasterCount: Int, peakBytes: Int, evictions: Int,
                              epoch: UInt64, backdropBytes: Int = 0) {
        guard enabledStorage else { return }
        var fields: [String: Value] = [
            "phase": .string(phase),
            "epoch": .int(Int(epoch)),
            "tile_cache_bytes": .int(tileCacheBytes),
            "page_raster_bytes": .int(pageRasterBytes),
            "thumbnail_bytes": .int(thumbnailBytes),
            "page_backdrop_bytes": .int(backdropBytes),
            "tile_count": .int(tileCount),
            "page_raster_count": .int(pageRasterCount),
            "peak_bytes": .int(peakBytes),
            "evictions": .int(evictions),
        ]
        if let rssBytes {
            fields["rss_bytes"] = .int(Int(rssBytes))
        } else {
            fields["rss_bytes"] = .unavailable
        }
        event("memory", fields, instance: instance)
    }

    /// The raster-classification counters for the document that is closing.
    public static func summary(instance: String? = nil, epoch: UInt64, contentVersion: UInt64, rasteredTiles: Int,
                               drawnTiles: Int, firstRasters: Int, repeatsAfterEviction: Int,
                               prefetchRasteredNeverDrawn: Int, uploadsAfterCacheHit: Int,
                               evictions: Int) {
        guard enabledStorage else { return }
        event("summary", [
            "epoch": .int(Int(epoch)),
            "content_version": .int(Int(contentVersion)),
            "rastered_tiles": .int(rasteredTiles),
            "drawn_tiles": .int(drawnTiles),
            "first_rasters": .int(firstRasters),
            "repeat_after_eviction": .int(repeatsAfterEviction),
            "prefetch_rastered_never_drawn": .int(prefetchRasteredNeverDrawn),
            "upload_after_cache_hit": .int(uploadsAfterCacheHit),
            "evictions": .int(evictions),
        ], instance: instance)
    }

    // MARK: - Kernel memory

    /// Current resident set size of this process in bytes, or nil when `task_info` fails.
    ///
    /// `getrusage().ru_maxrss` is the **peak**, not the curve, and the RGiff measurement needs the
    /// curve. This asks the kernel for the live figure instead of reading a proxy.
    public static func residentBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
        #else
        return nil
        #endif
    }

    // MARK: - Serialisation

    private static func emitLine(_ json: String) {
        let line = prefix + json + "\n"
        if let captureStorage {
            captureStorage(line)
            return
        }
        FileHandle.standardError.write(Data(line.utf8))
    }

    private static func serialize(_ value: Value) -> String {
        switch value {
        case .int(let value):
            return String(value)
        case .double(let value):
            // JSON has no NaN/Infinity; a non-finite measurement is "unavailable", never a
            // number a reader could mistake for a real reading.
            guard value.isFinite else { return "\"unavailable\"" }
            return String(format: "%.6f", value)
        case .string(let value):
            return "\"\(escape(value))\""
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        case .intArray(let values):
            return "[" + values.map(String.init).joined(separator: ",") + "]"
        case .stringArray(let values):
            return "[" + values.map { "\"\(escape($0))\"" }.joined(separator: ",") + "]"
        case .unavailable:
            return "\"unavailable\""
        }
    }

    private static func escape(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
}

/// What the canvas knows about the viewport it is drawing, copied with the page list so a frame
/// record can be tied back to the `sharp` commit that produced those pixels.
///
/// `token` is 0 until the first fully sharp commit. The canvas reads the stamp when it acquires a
/// drawable, which happens inside the same main-actor turn that draws `pages`, so a frame can
/// only carry the stamp of the page list it actually submitted.
public struct PerfViewportStamp: Sendable, Equatable {
    public var instance: String
    public var token: UInt64
    public var epoch: UInt64
    /// The document's content version (bumped whenever the caches are deliberately emptied), so
    /// a canvas-side classification can be tied to the raster set it belongs to.
    public var contentVersion: UInt64
    /// `page-raster` or `tile` — the path the committed band used.
    public var path: String
    public var lod: UInt8
    public var offsetPt: CGFloat

    public init(instance: String = "", token: UInt64 = 0, epoch: UInt64 = 0, contentVersion: UInt64 = 0,
                path: String = "unknown", lod: UInt8 = 0, offsetPt: CGFloat = 0) {
        self.instance = instance
        self.token = token
        self.epoch = epoch
        self.contentVersion = contentVersion
        self.path = path
        self.lod = lod
        self.offsetPt = offsetPt
    }
}
