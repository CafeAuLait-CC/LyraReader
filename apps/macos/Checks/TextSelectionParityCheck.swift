import AppKit
import LyraReaderKit
import LyraReaderBindings
import CoreGraphics
import Foundation

// C1 frozen parity fixture. The fixture holds five synthetic pages and 2,500 points. It is
// deliberately independent of any PDF: CI has no corpus, and the tricky rules (gutter boxes,
// cross-column spans, whitespace interpolation, the 35% line-join threshold, extendingSelection
// neighbours, invalid scalars, emission order) must stay pinned even without a sample file.
//
// Modes:
//   `--write-text-selection-parity FILE`  fills the Swift expectation fields (run once, commit)
//   `--check-text-selection-parity FILE`  re-runs the Swift reference and compares every field
//
// The Rust half of the same fixture lives in
// `crates/lyra-reader-ffi/tests/text_selection_parity.rs`; both halves compare against the same
// stored expectations, so a change in either implementation shows up as a fixture failure.
extension ReaderChecks {
    @MainActor static func checkTextSelectionParity(fixture: URL) throws {
        try textSelectionParity(fixture: fixture, writeExpectations: false)
    }

    @MainActor static func writeTextSelectionParity(fixture: URL) throws {
        try textSelectionParity(fixture: fixture, writeExpectations: true)
    }

    /// The selection-cache regression the audit asked for.
    ///
    /// It proves all three synchronous selection entry points never extract a page, that an
    /// evicted or above-budget page falls back to the local Swift model with the same answer,
    /// and that a miss schedules a cheap background warm which later events hit.
    @MainActor static func checkTextSelectionCache(fixtures: URL) async throws {
        let multipage = fixtures.appendingPathComponent("multipage.pdf")
        let longDocument = fixtures.appendingPathComponent("index-past-120.pdf")
        let oversized = fixtures.appendingPathComponent("text-page-oversized.pdf")

        // ── 1. Cold page: a typed miss with no extraction; the loading path still warms ──────
        do {
            let engine = LyraReaderBindings.LyraReaderEngine()
            let document = try engine.openDocument(path: multipage.path, password: nil)
            let empty = document.textPageCacheStats()
            require(
                empty.loads == 0 && empty.entries == 0,
                "a new document has an empty selection cache")
            let size = try document.pageSizePt(page: 0)
            let index = try document.textCharacterIndex(
                page: 0, xPt: size.widthPt / 2, yPt: size.heightPt / 2,
                extendingSelection: false)
            let range = try document.textCharacterRange(
                page: 0, xPt: size.widthPt / 4, yPt: size.heightPt / 4,
                widthPt: 20, heightPt: 20)
            let string = try document.textRangeString(page: 0, start: 0, end: 10)
            let cold = document.textPageCacheStats()
            require(
                index == nil && range == nil && string == nil,
                "a cold synchronous query is a typed not-prepared answer")
            require(
                cold.loads == 0 && cold.entries == 0 && cold.misses == 3,
                "a cold synchronous query never extracts a page")

            // The loading path is the one extractor, and its warm page answers its first event.
            let record = try document.textPage(page: 0)
            let warmed = document.textPageCacheStats()
            require(
                warmed.loads == 1 && warmed.entries == 1,
                "text_page prepares the page with exactly one extraction")
            let local = localTextPage(record)
            let first = try required(record.chars.first, "fixture page has text")
            let point = textPoint(first)
            let warmIndex = try document.textCharacterIndex(
                page: 0, xPt: point.x, yPt: point.y, extendingSelection: false)
            require(
                warmIndex.map(Int.init) == local.characterIndex(at: point),
                "the prepared Rust answer matches the local Swift model")
            require(
                document.textPageCacheStats().loads == warmed.loads,
                "a hit on the prepared page does not extract")

            // The async loading path stays uncached: a second load reads PDFium again.
            _ = try document.textPage(page: 0)
            require(
                document.textPageCacheStats().loads == 2,
                "text_page remains the fresh, uncached loading path")
        }

        // ── 2. Evicted page: all three synchronous entry points are extraction-free ────────
        do {
            let engine = LyraReaderBindings.LyraReaderEngine()
            let document = try engine.openDocument(path: longDocument.path, password: nil)
            let record = try document.textPage(page: 0)
            let local = localTextPage(record)
            let first = try required(record.chars.first, "long fixture page has text")
            let point = textPoint(first)
            let box = CGRect(
                x: first.xPt, y: first.yPt, width: first.widthPt, height: first.heightPt)
            let warmIndex = try required(
                try document.textCharacterIndex(
                    page: 0, xPt: point.x, yPt: point.y, extendingSelection: false
                ).map(Int.init), "prepared index")
            let warmRange = try required(
                try document.textCharacterRange(
                    page: 0, xPt: box.minX, yPt: box.minY,
                    widthPt: box.width, heightPt: box.height), "prepared range")
            let warmString = try required(
                try document.textRangeString(page: 0, start: 0, end: 20), "prepared string")

            for pageNumber in 1...5 {
                _ = try document.textPage(page: UInt32(pageNumber))
            }
            let evicted = document.textPageCacheStats()
            require(
                !evicted.pages.contains(0) && evicted.loads == 6,
                "five more pages evict page 0 from the five-entry cache")

            let missIndex = try document.textCharacterIndex(
                page: 0, xPt: point.x, yPt: point.y, extendingSelection: false)
            let missRange = try document.textCharacterRange(
                page: 0, xPt: box.minX, yPt: box.minY,
                widthPt: box.width, heightPt: box.height)
            let missString = try document.textRangeString(page: 0, start: 0, end: 20)
            let afterMiss = document.textPageCacheStats()
            require(
                missIndex == nil && missRange == nil && missString == nil,
                "an evicted page answers not prepared on all three entry points")
            require(
                afterMiss.loads == evicted.loads && afterMiss.misses == evicted.misses + 3,
                "an evicted synchronous query does not increase the PDFium load counter")
            require(
                afterMiss.pages == evicted.pages,
                "an evicted synchronous query does not disturb the LRU")

            // The local Swift model gives exactly the answers the prepared Rust cache gave.
            require(
                local.characterIndex(at: point) == warmIndex,
                "the local Swift index matches the prepared Rust index")
            let localRange = local.characterRange(in: box)
            require(
                localRange?.lowerBound == Int(warmRange.start)
                    && localRange?.upperBound == Int(warmRange.end),
                "the local Swift range matches the prepared Rust range")
            require(
                local.string(in: 0...20) == warmString,
                "the local Swift string matches the prepared Rust string")
        }

        // ── 3. The interactive wrapper answers from Swift, then warms Rust in the background ─
        do {
            let wrapper = try RustEngine()
            _ = try wrapper.openDocument(at: longDocument)
            let page = try await wrapper.textPage(0)
            let localPage = LyraReaderKit.TextPage(
                page: 0, chars: page.chars, text: page.text,
                hasUnicodeMapError: page.hasUnicodeMapError)
            let first = try required(page.chars.first, "wrapper page has text")
            let point = textPoint(first)
            let box = CGRect(
                x: first.xPt, y: first.yPt, width: first.widthPt, height: first.heightPt)
            let localIndex = localPage.characterIndex(at: point)
            let localRange = try required(
                localPage.characterRange(in: box), "local page range")
            let localString = localPage.string(in: localRange)

            for pageIndex in 1...5 {
                _ = try await wrapper.textPage(pageIndex)
            }
            let evicted = try required(
                wrapper.textPageCacheStats(), "evicted cache stats")
            require(
                !evicted.pages.contains(0) && evicted.loads == 6,
                "the wrapper document evicted page 0")

            let fallbackIndex = page.characterIndex(at: point)
            let fallbackRange = page.characterRange(in: box)
            let fallbackString = fallbackRange.map { page.string(in: $0) }
            require(
                fallbackIndex == localIndex,
                "the evicted wrapper page answers the same index from the local Swift model")
            require(
                fallbackRange == localRange,
                "the evicted wrapper page answers the same range from the local Swift model")
            require(
                fallbackString == localString,
                "the evicted wrapper page answers the same string from the local Swift model")

            // The pointer event did not wait for preparation, but the miss scheduled one warm.
            try await eventually("a miss schedules a background warm of the evicted page") {
                wrapper.textPageCacheStats()?.pages.contains(0) == true
            }
            let warmed = try required(wrapper.textPageCacheStats(), "warmed cache stats")
            require(
                warmed.loads == evicted.loads + 1,
                "the background warm extracts the page exactly once")
            require(
                page.characterIndex(at: point) == localIndex,
                "the warmed page returns the same index")
            require(
                page.characterRange(in: box) == localRange,
                "the warmed page returns the same range")
            require(
                page.string(in: localRange) == localString,
                "the warmed page returns the same string")
            require(
                wrapper.textPageCacheStats()?.loads == warmed.loads,
                "later pointer events use the warmed cache without extracting")
        }

        // ── 4. Oversized page: single-entry exception, still extraction-free ───────────────
        do {
            let engine = LyraReaderBindings.LyraReaderEngine()
            let document = try engine.openDocument(path: oversized.path, password: nil)
            let coldIndex = try document.textCharacterIndex(
                page: 0, xPt: 100, yPt: 100, extendingSelection: false)
            let cold = document.textPageCacheStats()
            require(
                coldIndex == nil && cold.loads == 0 && cold.entries == 0
                    && cold.misses == 1,
                "a cold oversized page is a typed miss with no extraction")
            let record = try document.textPage(page: 0)
            require(
                record.chars.count > 40_000,
                "the synthetic oversized fixture has a large text layer")
            let loaded = document.textPageCacheStats()
            require(
                loaded.entries == 1 && loaded.pages == [UInt32(0)],
                "an above-budget page is retained as the single cache entry")
            require(
                loaded.bytes > loaded.maxBytes,
                "the single-entry exception necessarily exceeds the soft byte ceiling")
            let local = localTextPage(record)
            let first = try required(record.chars.first, "oversized fixture has text")
            let point = textPoint(first)
            let index = try document.textCharacterIndex(
                page: 0, xPt: point.x, yPt: point.y, extendingSelection: false)
            require(
                index.map(Int.init) == local.characterIndex(at: point),
                "the retained oversized page matches the local Swift model")
            require(
                document.textPageCacheStats().loads == loaded.loads,
                "a pointer event on the retained oversized page does not re-extract")

            // A normal page that fits drops the exception instead of being starved by it.
            _ = try document.textPage(page: 1)
            let replaced = document.textPageCacheStats()
            require(
                replaced.entries == 1 && replaced.pages == [UInt32(1)]
                    && replaced.bytes <= replaced.maxBytes,
                "an ordinary page replaces the oversized exception")
            _ = try document.textPage(page: 0)
            let reloaded = document.textPageCacheStats()
            require(
                reloaded.entries == 1 && reloaded.pages == [UInt32(0)]
                    && reloaded.bytes > reloaded.maxBytes,
                "the oversized page becomes the single entry again")

            // A real failure stays an error rather than becoming a miss value.
            let loads = reloaded.loads
            var outOfRange = false
            do {
                _ = try document.textCharacterIndex(
                    page: 2, xPt: 1, yPt: 1, extendingSelection: false)
            } catch {
                outOfRange = true
            }
            require(
                outOfRange,
                "an out-of-range synchronous query is an error, not a not-prepared answer")
            require(
                document.textPageCacheStats().loads == loads,
                "a rejected page does not extract")
        }

        let diagnosticEngine = LyraReaderBindings.LyraReaderEngine()
        let diagnosticDocument = try diagnosticEngine.openDocument(
            path: multipage.path, password: nil)
        _ = try diagnosticDocument.textPage(page: 0)
        let finalStats = diagnosticDocument.textPageCacheStats()
        print(
            "PASS: text-page cache entries=\(finalStats.entries) bytes=\(finalStats.bytes) "
                + "loads=\(finalStats.loads) hits=\(finalStats.hits) "
                + "misses=\(finalStats.misses)")
    }

    /// The Swift page model for a page the loading path returned. This is the parity-tested
    /// fallback the wrapper answers from when a synchronous Rust query is not prepared.
    @MainActor private static func localTextPage(
        _ record: LyraReaderBindings.TextPage
    ) -> LyraReaderKit.TextPage {
        LyraReaderKit.TextPage(
            page: Int(record.page),
            chars: record.chars.map {
                LyraReaderKit.TextChar(
                    unicode: $0.unicode, xPt: CGFloat($0.xPt), yPt: CGFloat($0.yPt),
                    widthPt: CGFloat($0.widthPt), heightPt: CGFloat($0.heightPt))
            },
            text: record.text,
            hasUnicodeMapError: record.hasUnicodeMapError)
    }

    @MainActor private static func textPoint(
        _ character: LyraReaderBindings.TextChar
    ) -> CGPoint {
        CGPoint(
            x: character.xPt + character.widthPt / 2,
            y: character.yPt + character.heightPt / 2)
    }

    @MainActor private static func textPoint(_ character: LyraReaderKit.TextChar) -> CGPoint {
        CGPoint(
            x: character.xPt + character.widthPt / 2,
            y: character.yPt + character.heightPt / 2)
    }

    @MainActor private static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw parityError("FAIL: \(message)") }
        return value
    }

    @MainActor private static func textSelectionParity(fixture: URL, writeExpectations: Bool) throws {
        let data = try Data(contentsOf: fixture)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw parityError("fixture root is not a JSON object")
        }
        guard let rawPages = root["pages"] as? [[String: Any]],
              let rawPoints = root["points"] as? [[String: Any]]
        else {
            throw parityError("fixture needs pages and points arrays")
        }
        guard rawPages.count == 5, rawPoints.count == 2500 else {
            throw parityError(
                "fixture needs 5 pages and 2500 points, got \(rawPages.count)/\(rawPoints.count)")
        }

        var pages: [Int: LyraReaderKit.TextPage] = [:]
        for rawPage in rawPages {
            guard let id = intValue(rawPage["page"]),
                  let rows = rawPage["chars"] as? [[Any]]
            else { throw parityError("page record is malformed") }
            var chars: [LyraReaderKit.TextChar] = []
            chars.reserveCapacity(rows.count)
            for row in rows {
                guard row.count == 5,
                      let unicode = intValue(row[0]),
                      let x = doubleValue(row[1]),
                      let y = doubleValue(row[2]),
                      let width = doubleValue(row[3]),
                      let height = doubleValue(row[4])
                else { throw parityError("character row is not [unicode,x,y,w,h]") }
                guard unicode >= 0, unicode <= 0x10FFFF else {
                    throw parityError("character unicode out of range: \(unicode)")
                }
                chars.append(
                    LyraReaderKit.TextChar(
                        unicode: UInt32(unicode), xPt: CGFloat(x), yPt: CGFloat(y),
                        widthPt: CGFloat(width), heightPt: CGFloat(height)))
            }
            pages[id] = LyraReaderKit.TextPage(
                page: id, chars: chars, text: "", hasUnicodeMapError: false)
        }
        guard pages.count == 5 else { throw parityError("page ids are not 0..<5") }

        var mismatches = 0
        var examples: [String] = []
        func mismatch(_ message: @autoclosure () -> String) {
            mismatches += 1
            if examples.count < 10 { examples.append(message()) }
        }
        func expect(_ actual: Int?, _ stored: Any?, _ label: String, _ point: [String: Any]) {
            guard let stored = intValue(stored) else {
                if actual != nil {
                    mismatch("\(label) point=\(point) stored=nil Swift=\(actual!)")
                }
                return
            }
            if actual != stored {
                mismatch("\(label) point=\(point) stored=\(stored) Swift=\(actual.map(String.init) ?? "nil")")
            }
        }
        var points = rawPoints
        var pointChecks = 0
        for index in points.indices {
            var point = points[index]
            guard let pageID = intValue(point["page"]), let page = pages[pageID],
                  let x = doubleValue(point["x"]), let y = doubleValue(point["y"]),
                  let boxWidth = doubleValue(point["box_w"]),
                  let boxHeight = doubleValue(point["box_h"])
            else { throw parityError("point \(index) is malformed") }
            let location = CGPoint(x: x, y: y)
            let swiftIndex = page.characterIndex(at: location)
            let swiftDrag = page.characterIndex(at: location, extendingSelection: true)
            let box = CGRect(
                x: x - boxWidth / 2, y: y - boxHeight / 2,
                width: boxWidth, height: boxHeight)
            let swiftRange = page.characterRange(in: box)
            let swiftString = swiftRange.map { page.string(in: $0) } ?? ""
            if writeExpectations {
                point["swift_index"] = swiftIndex as Any? ?? NSNull()
                point["swift_drag_index"] = swiftDrag as Any? ?? NSNull()
                point["swift_box_first"] = swiftRange.map { $0.lowerBound } as Any? ?? NSNull()
                point["swift_box_last"] = swiftRange.map { $0.upperBound } as Any? ?? NSNull()
                point["swift_string_hash"] = String(format: "%016llx", stringHash(swiftString))
                point["swift_string_len"] = swiftString.utf8.count
                points[index] = point
            } else {
                expect(swiftIndex, point["swift_index"], "index", point)
                expect(swiftDrag, point["swift_drag_index"], "drag index", point)
                expect(swiftRange?.lowerBound, point["swift_box_first"], "box first", point)
                expect(swiftRange?.upperBound, point["swift_box_last"], "box last", point)
                if let storedHash = point["swift_string_hash"] as? String {
                    let actual = String(format: "%016llx", stringHash(swiftString))
                    if actual != storedHash {
                        mismatch(
                            "string hash point=\(point) stored=\(storedHash) Swift=\(actual)")
                    }
                } else {
                    mismatch("string hash point=\(point) is missing; run --write-text-selection-parity")
                }
                if intValue(point["swift_string_len"]) != swiftString.utf8.count {
                    mismatch(
                        "string length point=\(point) stored=\(intValue(point["swift_string_len"]) ?? -1) Swift=\(swiftString.utf8.count)")
                }
                pointChecks += 1
            }
        }

        var ranges = root["string_ranges"] as? [[String: Any]] ?? []
        var rangeChecks = 0
        for index in ranges.indices {
            var record = ranges[index]
            guard let pageID = intValue(record["page"]), let page = pages[pageID],
                  let start = intValue(record["start"]), let end = intValue(record["end"]),
                  start >= 0, end >= start, end < page.chars.count
            else { throw parityError("string range \(index) is malformed") }
            let text = page.string(in: start...end)
            if writeExpectations {
                record["swift_string_hash"] = String(format: "%016llx", stringHash(text))
                record["swift_string_len"] = text.utf8.count
                ranges[index] = record
            } else {
                if let storedHash = record["swift_string_hash"] as? String {
                    let actual = String(format: "%016llx", stringHash(text))
                    if actual != storedHash {
                        mismatch(
                            "fixed range \(record) stored=\(storedHash) Swift=\(actual)")
                    }
                } else {
                    mismatch("fixed range \(record) is missing; run --write-text-selection-parity")
                }
                if intValue(record["swift_string_len"]) != text.utf8.count {
                    mismatch(
                        "fixed range length \(record) stored=\(intValue(record["swift_string_len"]) ?? -1) Swift=\(text.utf8.count)")
                }
                rangeChecks += 1
            }
        }

        if writeExpectations {
            root["points"] = points
            root["string_ranges"] = ranges
            let output = try JSONSerialization.data(
                withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
            var bytes = output
            bytes.append(0x0A)
            try bytes.write(to: fixture)
            print(
                "PASS: wrote \(points.count) point expectations and \(ranges.count) fixed ranges to \(fixture.path)")
            return
        }

        guard mismatches == 0 else {
            print("C1 parity fixture mismatches: \(mismatches)")
            for example in examples { print("  \(example)") }
            throw parityError(
                "\(mismatches) Swift expectation mismatch(es) in \(fixture.lastPathComponent)")
        }
        print(
            "PASS: \(pointChecks) points and \(rangeChecks) fixed ranges match the frozen Swift expectations")
    }
}

private func parityError(_ message: String) -> NSError {
    NSError(domain: "TextSelectionParity", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private func intValue(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber else { return nil }
    return number.intValue
}

private func doubleValue(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber else { return nil }
    return number.doubleValue
}

/// FNV-1a over UTF-8, the same hash Rust stores. A hash plus the byte length catches a changed
/// space or line break without writing the page text into the fixture.
private func stringHash(_ value: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x100_0000_01b3
    }
    return hash
}
