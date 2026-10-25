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

    /// The cache check the task requires: a second pointer event on the same page must not enter
    /// PDFium again. The counters live in the document cache, so this uses the FFI handle
    /// directly (the interactive Swift wrapper makes exactly these calls).
    @MainActor static func checkTextSelectionCache(fixture: URL) throws {
        let engine = LyraReaderBindings.LyraReaderEngine()
        let document = try engine.openDocument(path: fixture.path, password: nil)

        // A page the shell has loaded (textPage) answers its first pointer event without a read.
        _ = try document.textPage(page: 0)
        let warmed = document.textPageCacheStats()
        require(warmed.entries >= 1, "loading a text page fills the selection cache")
        let size = try document.pageSizePt(page: 0)
        _ = try document.textCharacterIndex(
            page: 0, xPt: size.widthPt / 2, yPt: size.heightPt / 2, extendingSelection: false)
        let afterWarmHit = document.textPageCacheStats()
        require(
            afterWarmHit.loads == warmed.loads,
            "a hit on a preloaded page does not read PDFium")

        // A page nobody loaded yet pays one read, then none.
        let beforeMiss = document.textPageCacheStats()
        _ = try document.textCharacterIndex(
            page: 1, xPt: size.widthPt / 2, yPt: size.heightPt / 2, extendingSelection: false)
        let afterMiss = document.textPageCacheStats()
        require(afterMiss.loads == beforeMiss.loads + 1, "the first hit loads the page once")
        _ = try document.textCharacterIndex(
            page: 1, xPt: size.widthPt / 2, yPt: size.heightPt / 2, extendingSelection: true)
        let afterSecondHit = document.textPageCacheStats()
        require(
            afterSecondHit.loads == afterMiss.loads,
            "the second hit on the same page does not re-enter PDFium")
        require(afterSecondHit.hits > afterMiss.hits, "the second hit is counted as a cache hit")
        require(
            afterSecondHit.entries <= afterSecondHit.maxEntries,
            "cache entries are bounded")
        require(
            afterSecondHit.bytes <= afterSecondHit.maxBytes,
            "cache bytes are under the budget")
        print(
            "PASS: text-page cache entries=\(afterSecondHit.entries) bytes=\(afterSecondHit.bytes) "
                + "loads=\(afterSecondHit.loads) hits=\(afterSecondHit.hits)")
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
