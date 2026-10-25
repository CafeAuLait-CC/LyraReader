import AppKit
import Darwin
import Foundation
import LyraReaderBindings
import LyraReaderKit

// Opt-in measurement (`LyraReaderChecks --bench-hit-test dataset.jsonl`). Not registered as a
// regression suite: it prints numbers and changes nothing. The Rust half writes the dataset
// (`cargo run -p lyra-reader-ffi --release --example hit_bench -- --out …`), so both languages
// run on exactly the same page boxes and points.
//
// What is timed:
//   * `TextPage.characterIndex` for a drag (`extendingSelection: true`) and a press (default),
//     at the 100% and 200% point groups;
//   * `SelectionLine.build`, i.e. building a `TextPage` from already-extracted characters
//     (once per page load in the app, not once per event);
//   * the synchronous UniFFI `LyraReaderDocument.text_page` call (path A's re-read) on the same
//     points, plus a cheap `pageCount()` call as the bare FFI round-trip;
//   * the parity comparison against the Rust results embedded in the dataset.

extension ReaderChecks {
    @MainActor static func hitTestBenchmark(dataset: URL) throws {
        let data = try String(contentsOf: dataset, encoding: .utf8)
        let benchmark = try BenchmarkDataset(data)
        print("Swift / Rust selection benchmark")
        print(
            "pages=\(benchmark.pages.count) timing_per_zoom=\(benchmark.timing100.count)/"
                + "\(benchmark.timing200.count) parity=\(benchmark.parity.count)")

        for id in benchmark.pages.keys.sorted() {
            let page = benchmark.pages[id]!
            print(
                "  page[\(id)] \(page.label) p\(page.pageIndex) chars=\(page.text.chars.count) "
                    + "size=\(fmt(page.width))x\(fmt(page.height)) pt")
        }

        // ── Swift hit-test: the interactive path with the cached TextPage ──────────────────
        var sink: Int = 0
        for (group, points) in [("100% zoom", benchmark.timing100), ("200% zoom", benchmark.timing200)] {
            for drag in [true, false] {
                var samples: [Double] = []
                samples.reserveCapacity(points.count)
                for point in points {
                    let page = benchmark.pages[point.page]!
                    let origin = mach_absolute_time()
                    let index = page.text.characterIndex(
                        at: CGPoint(x: point.x, y: point.y), extendingSelection: drag)
                    let elapsed = microseconds(mach_absolute_time() - origin)
                    sink &+= index ?? -1
                    samples.append(elapsed)
                }
                let stats = BenchmarkStats(samples)
                print(
                    "Swift characterIndex \(drag ? "drag" : "press") \(group): "
                        + stats.line)
            }
        }

        // ── SelectionLine.build: once per page load in the app ────────────────────────────
        var buildSamples: [Double] = []
        for id in benchmark.pages.keys.sorted() {
            let page = benchmark.pages[id]!
            for _ in 0..<40 {
                let origin = mach_absolute_time()
                let rebuilt = LyraReaderKit.TextPage(
                    page: page.text.page, chars: page.text.chars, text: "",
                    hasUnicodeMapError: false)
                let elapsed = microseconds(mach_absolute_time() - origin)
                sink &+= rebuilt.chars.count
                buildSamples.append(elapsed)
            }
        }
        print("Swift SelectionLine.build (per TextPage): \(BenchmarkStats(buildSamples).line)")

        // ── Path A from the shell: the synchronous UniFFI call that re-reads the page ─────
        let engine = LyraReaderBindings.LyraReaderEngine()
        var documents: [Int: LyraReaderBindings.LyraReaderDocument] = [:]
        var paths: [Int: (path: String, pageIndex: Int)] = [:]
        for (id, page) in benchmark.pages {
            documents[id] = try engine.openDocument(path: page.path, password: nil)
            paths[id] = (page.path, page.pageIndex)
        }
        for (group, points) in [("100% zoom", benchmark.timing100), ("200% zoom", benchmark.timing200)] {
            var samples: [Double] = []
            samples.reserveCapacity(points.count)
            for point in points {
                guard let document = documents[point.page], let info = paths[point.page] else {
                    continue
                }
                let origin = mach_absolute_time()
                let text = try document.textPage(page: UInt32(info.pageIndex))
                let elapsed = microseconds(mach_absolute_time() - origin)
                sink &+= text.chars.count
                samples.append(elapsed)
            }
            print("Swift FFI text_page path A (uncached) \(group): \(BenchmarkStats(samples).line)")
        }
        var ffiOverhead: [Double] = []
        if let document = documents[benchmark.pages.keys.sorted().first ?? 0] {
            for _ in 0..<benchmark.timing100.count {
                let origin = mach_absolute_time()
                let count = document.pageCount()
                let elapsed = microseconds(mach_absolute_time() - origin)
                sink &+= Int(count)
                ffiOverhead.append(elapsed)
            }
        }
        print("Swift FFI pageCount round-trip (overhead proxy): \(BenchmarkStats(ffiOverhead).line)")

        // ── Parity: the same points and boxes the Rust half measured ───────────────────────
        var indexExactDiff = 0
        var indexNearestDiff = 0
        var boxSetDiff = 0
        var boxRangeDiff = 0
        var coverageVsIntersection = 0
        var coverageVsRust = 0
        var coverageVsRustSpan = 0
        var nearEdgeMismatches = 0
        var indexMismatches = 0
        var swiftNil = 0
        var rustExactNil = 0
        var indexExamples: [String] = []
        var nearestExamples: [String] = []
        var boxExamples: [String] = []
        for point in benchmark.parity {
            let page = benchmark.pages[point.page]!
            let location = CGPoint(x: point.x, y: point.y)
            let swiftIndex = page.text.characterIndex(at: location)
            let box = CGRect(
                x: point.x - point.boxWidth / 2, y: point.y - point.boxHeight / 2,
                width: point.boxWidth, height: point.boxHeight)
            let swiftRange = page.text.characterRange(in: box)
            let swiftInfo = rangeInfo(swiftRange)
            let coverage = coverageRange(in: box, chars: page.text.chars, threshold: 0.35)
            let coverageInfo = rangeInfo(coverage)

            if swiftIndex == nil { swiftNil += 1 }
            if point.rustExact == nil { rustExactNil += 1 }
            if swiftIndex != point.rustExact {
                indexExactDiff += 1
                indexMismatches += 1
                if isNearGlyphEdge(location, chars: page.text.chars, tolerance: 2.0) {
                    nearEdgeMismatches += 1
                }
                if indexExamples.count < 6 {
                    indexExamples.append(
                        String(
                            format: "    point p%d (%.2f, %.2f) Swift=%d Rust exact=%d nearest=%d",
                            point.page, point.x, point.y, swiftIndex ?? -1,
                            point.rustExact ?? -1, point.rustNearest ?? -1))
                }
            }
            if swiftIndex != point.rustNearest {
                indexNearestDiff += 1
                if nearestExamples.count < 6 {
                    nearestExamples.append(
                        String(
                            format: "    point p%d (%.2f, %.2f) Swift=%d Rust nearest=%d exact=%d",
                            point.page, point.x, point.y, swiftIndex ?? -1,
                            point.rustNearest ?? -1, point.rustExact ?? -1))
                }
            }
            let rustHash = point.rustBoxHash ?? 0
            let rustSpan: RangeInfo
            if let first = point.rustBoxFirst, let last = point.rustBoxLast {
                rustSpan = rangeInfo(first...last)
            } else {
                rustSpan = rangeInfo(nil)
            }
            if swiftInfo.hash != rustHash {
                boxSetDiff += 1
                if boxExamples.count < 6 {
                    boxExamples.append(
                        String(
                            format:
                                "    point p%d (%.2f, %.2f) box %.1fx%.1f Swift=%d…%d (%d) "
                                + "Rust=%d…%d (%d) coverage=%d…%d",
                            point.page, point.x, point.y, point.boxWidth, point.boxHeight,
                            swiftInfo.first ?? -1, swiftInfo.last ?? -1, swiftInfo.count,
                            point.rustBoxFirst ?? -1, point.rustBoxLast ?? -1,
                            point.rustBoxCount ?? 0, coverageInfo.first ?? -1,
                            coverageInfo.last ?? -1))
                }
            }
            if swiftInfo.hash != rustSpan.hash {
                boxRangeDiff += 1
            }
            if coverageInfo.hash != swiftInfo.hash {
                coverageVsIntersection += 1
            }
            if coverageInfo.hash != rustHash {
                coverageVsRust += 1
            }
            if coverageInfo.hash != rustSpan.hash {
                coverageVsRustSpan += 1
            }
        }
        let total = benchmark.parity.count
        print("Parity (n=\(total), 5 pages):")
        print(percentLine("closest index vs Rust exact containment", indexExactDiff, total))
        print(percentLine("closest index vs Rust nearest-glyph reference", indexNearestDiff, total))
        print(percentLine("box→character range (Swift characterRange vs Rust first…last)",
                          boxRangeDiff, total))
        print(percentLine("box→character set (Swift range vs Rust one-rect-per-char intersection)",
                          boxSetDiff, total))
        print(percentLine("box→set: Swift >35% coverage vs characterRange", coverageVsIntersection, total))
        print(percentLine("box→set: Swift >35% coverage vs Rust first…last", coverageVsRustSpan, total))
        print(percentLine("box→set: Swift >35% coverage vs Rust per-char intersection", coverageVsRust, total))
        if indexMismatches > 0 {
            print(
                "Of \(indexMismatches) exact-index mismatches, \(nearEdgeMismatches) "
                    + "(\(pct(nearEdgeMismatches, indexMismatches))%) are within 2 pt of a glyph edge")
        }
        print("Swift index nil=\(swiftNil)/\(total)  Rust exact nil=\(rustExactNil)/\(total)")
        if !indexExamples.isEmpty {
            print("Index mismatch examples:")
            for line in indexExamples { print(line) }
        }
        if !nearestExamples.isEmpty {
            print("Nearest-index mismatch examples:")
            for line in nearestExamples { print(line) }
        }
        if !boxExamples.isEmpty {
            print("Box mismatch examples:")
            for line in boxExamples { print(line) }
        }
        if sink == Int.min { print(sink) } // keep the timed results observable
        print("Swift results: benchmark complete")
    }
}

// ── Dataset ──────────────────────────────────────────────────────────────────────────────────

private struct BenchmarkDataset {
    struct Page {
        let label: String
        let path: String
        let pageIndex: Int
        let width: Double
        let height: Double
        let text: LyraReaderKit.TextPage
    }

    struct Point: Decodable {
        let page: Int
        let x: Double
        let y: Double
        let boxWidth: Double
        let boxHeight: Double
        let rustExact: Int?
        let rustNearest: Int?
        let rustBoxFirst: Int?
        let rustBoxLast: Int?
        let rustBoxCount: Int?
        let rustBoxHash: UInt64?

        enum CodingKeys: String, CodingKey {
            case page, x, y
            case boxWidth = "box_w"
            case boxHeight = "box_h"
            case rustExact = "rust_exact"
            case rustNearest = "rust_nearest"
            case rustBoxFirst = "rust_box_first"
            case rustBoxLast = "rust_box_last"
            case rustBoxCount = "rust_box_count"
            case rustBoxHash = "rust_box_hash"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            page = try values.decode(Int.self, forKey: .page)
            x = try values.decode(Double.self, forKey: .x)
            y = try values.decode(Double.self, forKey: .y)
            boxWidth = try values.decode(Double.self, forKey: .boxWidth)
            boxHeight = try values.decode(Double.self, forKey: .boxHeight)
            rustExact = try values.decodeIfPresent(Int.self, forKey: .rustExact)
            rustNearest = try values.decodeIfPresent(Int.self, forKey: .rustNearest)
            rustBoxFirst = try values.decodeIfPresent(Int.self, forKey: .rustBoxFirst)
            rustBoxLast = try values.decodeIfPresent(Int.self, forKey: .rustBoxLast)
            rustBoxCount = try values.decodeIfPresent(Int.self, forKey: .rustBoxCount)
            let hash = try values.decodeIfPresent(String.self, forKey: .rustBoxHash)
            rustBoxHash = hash.flatMap { UInt64($0, radix: 16) }
        }
    }

    let pages: [Int: Page]
    var timing100: [Point] = []
    var timing200: [Point] = []
    var parity: [Point] = []

    init(_ data: String) throws {
        var pages: [Int: Page] = [:]
        let decoder = JSONDecoder()
        for line in data.split(separator: "\n") {
            let raw = Data(line.utf8)
            guard let kind = try? decoder.decode(Kind.self, from: raw).kind else { continue }
            if kind == "page" {
                let record = try decoder.decode(PageRecord.self, from: raw)
                let chars = try record.chars.map { values -> LyraReaderKit.TextChar in
                    guard values.count == 5 else {
                        throw BenchmarkError.message("page character is not [unicode,x,y,w,h]")
                    }
                    return LyraReaderKit.TextChar(
                        unicode: UInt32(values[0]), xPt: CGFloat(values[1]),
                        yPt: CGFloat(values[2]), widthPt: CGFloat(values[3]),
                        heightPt: CGFloat(values[4]))
                }
                pages[record.page] = Page(
                    label: record.label, path: record.path, pageIndex: record.pageIndex,
                    width: record.widthPt, height: record.heightPt,
                    text: LyraReaderKit.TextPage(
                        page: record.page, chars: chars, text: "", hasUnicodeMapError: false))
            } else if kind == "point" {
                let point = try decoder.decode(Point.self, from: raw)
                let group = try decoder.decode(PointGroup.self, from: raw).group
                switch group {
                case "timing100": timing100.append(point)
                case "timing200": timing200.append(point)
                default: parity.append(point)
                }
            }
        }
        guard pages.count >= 1, timing100.count >= 2000, timing200.count >= 2000,
            parity.count >= 500
        else {
            throw BenchmarkError.message(
                "dataset needs >=1 page, >=2000 points per zoom and >=500 parity points")
        }
        self.pages = pages
    }
}

private enum BenchmarkError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let message): message }
    }
}

private struct Kind: Decodable { let kind: String }
private struct PointGroup: Decodable { let group: String }
private struct PageRecord: Decodable {
    let page: Int
    let label: String
    let path: String
    let pageIndex: Int
    let widthPt: Double
    let heightPt: Double
    let chars: [[Double]]
    enum CodingKeys: String, CodingKey {
        case page, label, path, chars
        case pageIndex = "page_index"
        case widthPt = "width_pt"
        case heightPt = "height_pt"
    }
}

// ── Statistics ──────────────────────────────────────────────────────────────────────────────

private struct BenchmarkStats {
    let n: Int
    let mean: Double
    let p50: Double
    let p95: Double
    let max: Double
    let min: Double

    init(_ values: [Double]) {
        let sorted = values.sorted()
        n = sorted.count
        mean = n == 0 ? 0 : sorted.reduce(0, +) / Double(n)
        p50 = percentile(sorted, 0.50)
        p95 = percentile(sorted, 0.95)
        max = sorted.last ?? 0
        min = sorted.first ?? 0
    }

    var line: String {
        String(
            format: "n=%-5d mean=%8.2f p50=%8.2f p95=%8.2f max=%9.2f min=%8.2f µs",
            n, mean, p50, p95, max, min)
    }
}

private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let rank = max(1, Int((fraction * Double(sorted.count)).rounded(.up)))
    return sorted[min(rank, sorted.count) - 1]
}

private func fmt(_ value: Double) -> String { String(format: "%.1f", value) }

private func pct(_ part: Int, _ total: Int) -> String {
    total == 0 ? "0.00" : String(format: "%.2f", 100.0 * Double(part) / Double(total))
}

private func percentLine(_ label: String, _ part: Int, _ total: Int) -> String {
    "  \(label): \(part)/\(total) = \(pct(part, total))%"
}

// ── Ranges, hashing, geometry ───────────────────────────────────────────────────────────────

private struct RangeInfo {
    let first: Int?
    let last: Int?
    let count: Int
    let hash: UInt64
}

private let fnvOffset: UInt64 = 0xcbf2_9ce4_8422_2325
private let fnvPrime: UInt64 = 0x100_0000_01b3

private func rangeInfo(_ range: ClosedRange<Int>?) -> RangeInfo {
    guard let range else { return RangeInfo(first: nil, last: nil, count: 0, hash: fnvOffset) }
    var hash = fnvOffset
    for index in range {
        var value = UInt32(index).littleEndian
        withUnsafeBytes(of: &value) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* fnvPrime
            }
        }
    }
    return RangeInfo(
        first: range.lowerBound, last: range.upperBound, count: range.count, hash: hash)
}

/// The `AnnotationSentenceMap` box rule: a character counts when more than 35% of its box is
/// inside the annotation box. Reimplemented here because the map's entry point takes a
/// `DocumentAnnotation`, which only the engine can build; the predicate is copied exactly.
private func coverageRange(in box: CGRect, chars: [LyraReaderKit.TextChar], threshold: CGFloat)
    -> ClosedRange<Int>?
{
    var first: Int?
    var last: Int?
    for (index, character) in chars.enumerated() {
        let rect = CGRect(
            x: character.xPt, y: character.yPt,
            width: character.widthPt, height: character.heightPt)
        guard rect.width > 0, rect.height > 0 else { continue }
        let overlap = rect.intersection(box)
        guard !overlap.isNull, overlap.width * overlap.height > rect.width * rect.height * threshold
        else { continue }
        first = first ?? index
        last = index
    }
    guard let first, let last, first <= last else { return nil }
    return first...last
}

/// True when the point is within `tolerance` of the border of any glyph box (inside or outside).
/// Used to judge whether parity differences live only at glyph edges.
private func isNearGlyphEdge(_ point: CGPoint, chars: [LyraReaderKit.TextChar], tolerance: CGFloat)
    -> Bool
{
    for character in chars where character.widthPt > 0 && character.heightPt > 0 {
        let minX = character.xPt
        let maxX = character.xPt + character.widthPt
        let minY = character.yPt
        let maxY = character.yPt + character.heightPt
        let edge: CGFloat
        if point.x >= minX, point.x <= maxX, point.y >= minY, point.y <= maxY {
            edge = min(
                min(point.x - minX, maxX - point.x),
                min(point.y - minY, maxY - point.y))
        } else {
            let dx = max(max(minX - point.x, 0), point.x - maxX)
            let dy = max(max(minY - point.y, 0), point.y - maxY)
            edge = max(dx, dy)
        }
        if edge <= tolerance { return true }
    }
    return false
}

private let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

private func microseconds(_ ticks: UInt64) -> Double {
    Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1000.0
}
