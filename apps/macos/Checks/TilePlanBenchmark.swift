import AppKit
import CryptoKit
import Foundation
import LyraReaderKit

/// ADR 0007 bench: four viewport workloads measured on the same scheduler path.
///
/// The shell's cache and rasterizer are unchanged by audit C5; what moves is the decision. So
/// this harness measures exactly the quantities that decision can influence — raster count,
/// cache hits/misses, evictions and the pinned band's peak bytes — plus the process's CPU
/// footprint, which is where a larger band would show up. It runs *one* scenario per process so
/// `/usr/bin/time -l` gives a clean peak; the command and conditions go in the PR description.
///
/// It is a measurement, not a check: nothing here asserts, it reports one JSON object.
///
/// Usage: LyraReaderChecks --measure-tile-plan <scenario> [root]
///   scenarios: normal-scroll-100, deep-zoom-400, zoom-round-trip, floating-preview
extension ReaderChecks {
    @MainActor static func measureTilePlan(scenario: String, root: URL) async throws {
        // The measurement corpus is local (a real paper, not a committed fixture), so the path
        // is supplied by the environment rather than named here.
        guard let benchPath = ProcessInfo.processInfo.environment["LYRA_READER_BENCH_PDF"],
              !benchPath.isEmpty else {
            FileHandle.standardError.write(Data("tile-plan bench: set LYRA_READER_BENCH_PDF\n".utf8))
            exit(2)
        }
        let pdf = URL(fileURLWithPath: benchPath)
        guard FileManager.default.fileExists(atPath: pdf.path) else {
            FileHandle.standardError.write(Data("tile-plan bench: the PDF does not exist\n".utf8))
            exit(2)
        }
        let steps: Int
        let zoom: Int
        let stepScreenPoints: CGFloat
        switch scenario {
        case "normal-scroll-100":
            steps = 40
            zoom = 100
            stepScreenPoints = 374
        case "deep-zoom-400":
            steps = 40
            zoom = 400
            stepScreenPoints = 300
        case "zoom-round-trip", "floating-preview":
            steps = 0
            zoom = 100
            stepScreenPoints = 374
        default:
            FileHandle.standardError.write(Data("tile-plan bench: unknown scenario \(scenario)\n".utf8))
            exit(2)
        }

        let engine = try RustEngine()
        let state = AppState(engine: engine, tileCacheBudgetBytes: 48 * 1024 * 1024,
                             preferFullPageRasters: false)
        state.setDeviceScale(2)
        state.setViewportSize(CGSize(width: 959, height: 715))
        guard state.open(url: pdf) else {
            FileHandle.standardError.write(Data("tile-plan bench: the PDF did not open\n".utf8))
            exit(3)
        }
        state.gotoPage(0)
        try await settleTilePlan(state)

        let startFootprint = tilePlanFootprintBytes()
        var peakFootprint = startFootprint
        func sample() { peakFootprint = max(peakFootprint, tilePlanFootprintBytes()) }

        state.zoomPercent = zoom
        state.reloadVisiblePages()
        try await settleTilePlan(state)
        sample()

        switch scenario {
        case "normal-scroll-100", "deep-zoom-400":
            for _ in 0..<steps {
                state.scroll(byScreenPoints: stepScreenPoints)
                try await settleTilePlan(state)
                sample()
            }
        case "zoom-round-trip":
            for percent in [400, 100, 400, 100] {
                state.zoomPercent = percent
                state.reloadVisiblePages()
                try await settleTilePlan(state)
                sample()
            }
        case "floating-preview":
            _ = state.openReferencePreview(page: 3, title: "bench", from: "bench", kind: .page)
            try await Task.sleep(for: .milliseconds(500))
            for _ in 0..<20 {
                state.scroll(byScreenPoints: stepScreenPoints)
                try await settleTilePlan(state)
                sample()
            }
        default:
            break
        }

        let stats = state.tileCacheSnapshot
        let digest = SHA256.hash(data: try Data(contentsOf: pdf, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        let result: [String: Any] = [
            "scenario": scenario,
            "pdf_sha256": digest,
            "pdf_pages": state.document?.pageCount ?? 0,
            "engine": engine.version,
            "viewport_pt": "959x715",
            "device_scale": 2,
            "build": "debug",
            "cache_budget_bytes": state.tileCacheBudgetBytes,
            "band_budget_override_bytes": state.prefetchBandBudgetOverrideBytes ?? 0,
            "band_budget_rule": "max(8 MiB, cache_budget / 3) unless overridden",
            "zoom_percent": zoom,
            "steps": steps,
            "step_screen_points": Double(stepScreenPoints),
            "raster_count": state.tileRasterCount,
            "request_count": state.tileRequestCount,
            "hits": stats.hits,
            "misses": stats.misses,
            "insertions": stats.insertions,
            "evictions": stats.evictions,
            "evicted_bytes": stats.evictedBytes,
            "peak_tile_bytes": state.tileCachePeakBytes,
            "final_tile_bytes": state.tileCacheUsedBytes,
            "final_tile_count": state.tileCacheTileCount,
            "start_footprint_bytes": startFootprint,
            "peak_footprint_bytes": peakFootprint,
            "footprint_scope": "CPU phys_footprint; excludes the GPU device and window surfaces "
                + "(ADR 0007: ~330 MiB floor)",
        ]
        let data = try JSONSerialization.data(withJSONObject: result,
                                              options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        state.closeReferencePreview()
    }

    /// The process's physical footprint, in bytes (`TASK_VM_INFO`), or 0 if the kernel refuses.
    @MainActor private static func tilePlanFootprintBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// Waits until the tile raster and cache counters have been still long enough to cover a
    /// slow real-page raster (the measured worst case is ~200 ms). The scheduler's queues are
    /// private; "nothing changed for 400 ms" is the observable settle.
    @MainActor private static func settleTilePlan(_ state: AppState) async throws {
        var lastRasters = -1
        var lastCount = -1
        var quiet = 0
        for _ in 0..<1_500 {
            try await Task.sleep(for: .milliseconds(20))
            let rasters = state.tileRasterCount
            let count = state.tileCacheTileCount
            if rasters == lastRasters && count == lastCount {
                quiet += 1
                if quiet >= 20 { return }
            } else {
                quiet = 0
                lastRasters = rasters
                lastCount = count
            }
        }
        FileHandle.standardError.write(Data("tile-plan bench: the scheduler never settled\n".utf8))
        exit(4)
    }
}
