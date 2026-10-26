import AppKit
import Foundation
import LyraReaderBindings
@testable import LyraReaderKit

// Audit C9: the durable bookmark rules live in `lyra-reader-edit`.
//
// The matrix below is frozen evidence for the move. It drives the same public bookmark
// commands the sidebar and the page-corner flag use and records, after every step:
//
//   * the bookmarks in the reader's order (page, page-local Y, stored title),
//   * the display titles the sidebar shows (the UI fallback is *not* part of the move),
//   * the `.bookmark` slots as they sit in `annotations.json` (A = annotation, Bn = the nth
//     bookmark in the current list, B? = a slot whose bookmark was deleted),
//   * how many cache writes the step caused,
//   * the exact status/alert sentence, or `nil`.
//
// The pre-change transcript was captured on `ee4c863`; the post-change transcript differs only
// in the rows marked "C9" below (limit refusals that used to happen at save time now happen at
// the entry point). Everything else must stay byte-for-byte identical, including the order,
// the pages and Y values, and the exact rejection sentences.
extension ReaderChecks {
    @MainActor static func bookmarkRulesChecks(root: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-bookmark-rules-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        var lines: [String] = []
        let uuidPattern = try NSRegularExpression(
            pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
        func normalized(_ text: String) -> String {
            let range = NSRange(text.startIndex..., in: text)
            return uuidPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "<uuid>")
        }
        func titleSummary(_ title: String) -> String {
            if title.count > 40 {
                return "<\(title.count) chars:\(String(reflecting: String(title.prefix(12))))>"
            }
            return String(reflecting: title)
        }
        func yText(_ value: CGFloat) -> String {
            String(format: "%.2f", Double(value))
        }
        func values(_ state: AppState) -> String {
            "[" + state.bookmarks.map {
                "\($0.page)@\(yText($0.yPt)):\(titleSummary($0.title))"
            }.joined(separator: ", ") + "]"
        }
        func displayValues(_ state: AppState) -> String {
            "[" + state.bookmarks.map { titleSummary($0.displayTitle) }.joined(separator: ", ") + "]"
        }
        /// The cache's entry order, with bookmark slots named by their position in the current
        /// bookmark list. This is the durable order: it is what the encoder writes and what the
        /// outline writer reads.
        func slotPattern(_ state: AppState, document: URL) throws -> String {
            let url = DocumentEditCache.annotationsURL(for: document)
            guard fileManager.fileExists(atPath: url.path) else { return "[]" }
            let contents = try AnnotationRecords.decode(
                Data(contentsOf: url),
                pageCount: state.document?.pageCount ?? 0,
                paletteCount: AppState.highlightPalette.count)
            let positions = Dictionary(uniqueKeysWithValues:
                state.bookmarks.enumerated().map { ($0.element.id, $0.offset) })
            return "[" + contents.slots.map { slot -> String in
                switch slot {
                case .annotation: return "A"
                case .bookmark(let id): return positions[id].map { "B\($0)" } ?? "B?"
                case .opaque: return "O"
                }
            }.joined(separator: ",") + "]"
        }
        func record(
            _ label: String,
            _ state: AppState,
            document: URL,
            writes: Int
        ) throws {
            let error = state.lastError.map(normalized) ?? "nil"
            lines.append(
                "\(label) | order=\(values(state)) | display=\(displayValues(state))"
                    + " | slots=\(try slotPattern(state, document: document))"
                    + " | writes+=\(writes) | error=\(error)")
        }
        func begin(_ state: AppState) {
            state.lastError = nil
            state.statusMessage = ""
        }
        func documentCopy(_ name: String) throws -> URL {
            let url = scratch.appendingPathComponent(name)
            try fileManager.copyItem(
                at: root.appendingPathComponent("tests/fixtures/multipage.pdf"), to: url)
            return url
        }
        func openState(_ url: URL, bookmarks expected: Int? = nil) async throws -> AppState {
            let state = AppState(engine: try RustEngine())
            state.setViewportSize(CGSize(width: 900, height: 600))
            state.open(url: url)
            try await eventually("bookmark matrix: \(url.lastPathComponent) opens", {
                state.document != nil
            })
            if let expected {
                try await eventually("bookmark matrix: \(url.lastPathComponent) has \(expected) bookmarks", {
                    state.bookmarks.count == expected
                })
            }
            return state
        }
        func fixedUUID(_ index: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
        }

        // ── A. Ordering, moves, renames ──────────────────────────────────────────────
        let orderDocument = try documentCopy("order.pdf")
        let state = try await openState(orderDocument)
        guard let pageCount = state.document?.pageCount, pageCount >= 3 else {
            require(false, "the bookmark matrix needs the three-page fixture")
            return
        }

        begin(state)
        var before = state.annotationWriteCount
        require(state.addBookmark(onPage: 0, yPt: 0, name: nil),
                "C9 matrix: add at the top of page 1")
        try record("A1 add page-1 top", state, document: orderDocument,
                   writes: state.annotationWriteCount - before)

        begin(state)
        before = state.annotationWriteCount
        require(state.addBookmark(onPage: 0, yPt: 400, name: "  Later on page 1  "),
                "C9 matrix: add lower on the same page with a padded name")
        try record("A2 add page-1 y400", state, document: orderDocument,
                   writes: state.annotationWriteCount - before)

        begin(state)
        before = state.annotationWriteCount
        require(state.addBookmark(onPage: 0, yPt: 10, name: "Middle"),
                "C9 matrix: add above the previous same-page mark")
        try record("A3 add page-1 y10", state, document: orderDocument,
                   writes: state.annotationWriteCount - before)

        begin(state)
        before = state.annotationWriteCount
        require(state.addBookmark(onPage: pageCount - 1, yPt: 50, name: nil),
                "C9 matrix: add at the last page")
        try record("A4 add last-page", state, document: orderDocument,
                   writes: state.annotationWriteCount - before)

        begin(state)
        before = state.annotationWriteCount
        require(state.addBookmark(onPage: 1, yPt: 5, name: "Back to page 2"),
                "C9 matrix: add an earlier page after later ones")
        try record("A5 add page-2 after page-3", state, document: orderDocument,
                   writes: state.annotationWriteCount - before)

        let firstID = state.bookmarks[0].id
        let lastID = state.bookmarks[4].id
        begin(state)
        before = state.annotationWriteCount
        state.moveBookmark(firstID, by: -1)
        require(state.annotationWriteCount == before,
                "C9 matrix: moving the first bookmark up is a no-op and writes nothing")
        try record("A6 move-first-up (clamped)", state, document: orderDocument,
                   writes: state.annotationWriteCount - before)

        begin(state)
        before = state.annotationWriteCount
        state.moveBookmark(lastID, by: 1)
        require(state.annotationWriteCount == before,
                "C9 matrix: moving the last bookmark down is a no-op and writes nothing")
        try record("A7 move-last-down (clamped)", state, document: orderDocument,
                   writes: state.annotationWriteCount - before)

        begin(state)
        before = state.annotationWriteCount
        state.moveBookmark(state.bookmarks[1].id, by: 1)
        try record("A8 move-second-down", state, document: orderDocument,
                   writes: state.annotationWriteCount - before)

        begin(state)
        before = state.annotationWriteCount
        state.moveBookmark(state.bookmarks[2].id, by: -100)
        try record("A9 move-index-2-to-front", state, document: orderDocument,
                   writes: state.annotationWriteCount - before)

        let renameID = state.bookmarks[0].id
        begin(state)
        before = state.annotationWriteCount
        state.renameBookmark(renameID, to: "")
        try record("A10 rename-empty", state, document: orderDocument,
                   writes: state.annotationWriteCount - before)

        begin(state)
        before = state.annotationWriteCount
        state.renameBookmark(renameID, to: "   ")
        try record("A11 rename-whitespace", state, document: orderDocument,
                   writes: state.annotationWriteCount - before)

        begin(state)
        before = state.annotationWriteCount
        state.renameBookmark(renameID, to: String(repeating: "x", count: 4_097))
        try record("A12 rename-4097-bytes (C9)", state, document: orderDocument,
                   writes: state.annotationWriteCount - before)

        begin(state)
        before = state.annotationWriteCount
        state.renameBookmark(renameID, to: "a\0b")
        try record("A13 rename-NUL (C9)", state, document: orderDocument,
                   writes: state.annotationWriteCount - before)

        begin(state)
        before = state.annotationWriteCount
        state.renameBookmark(renameID, to: "Final name")
        try record("A14 rename-valid", state, document: orderDocument,
                   writes: state.annotationWriteCount - before)

        // ── B. Entries the rule set refuses ───────────────────────────────────────────
        begin(state)
        before = state.annotationWriteCount
        require(!state.addBookmark(onPage: pageCount),
                "C9 matrix: the UI refuses a bookmark page outside the document")
        try record("B1 add-page-out-of-range", state, document: orderDocument,
                   writes: state.annotationWriteCount - before)

        begin(state)
        before = state.annotationWriteCount
        require(!state.addBookmark(onPage: -1), "C9 matrix: the UI refuses a negative page")
        try record("B2 add-negative-page", state, document: orderDocument,
                   writes: state.annotationWriteCount - before)

        begin(state)
        before = state.annotationWriteCount
        require(!state.addBookmark(onPage: 0, yPt: -1),
                "C9 matrix: the UI refuses a negative page-local Y")
        try record("B3 add-negative-y", state, document: orderDocument,
                   writes: state.annotationWriteCount - before)

        begin(state)
        before = state.annotationWriteCount
        require(!state.addBookmark(onPage: 0, yPt: .nan),
                "C9 matrix: the UI refuses a non-finite page-local Y")
        try record("B4 add-nan-y", state, document: orderDocument,
                   writes: state.annotationWriteCount - before)

        begin(state)
        before = state.annotationWriteCount
        require(!state.addBookmark(onPage: 0, name: "a\0b"),
                "C9 matrix: the UI refuses a NUL in a title")
        try record("B5 add-title-NUL", state, document: orderDocument,
                   writes: state.annotationWriteCount - before)

        begin(state)
        before = state.annotationWriteCount
        require(!state.addBookmark(onPage: 0, name: String(repeating: "x", count: 4_097)),
                "C9 matrix: the UI refuses a title over 4096 bytes")
        try record("B6 add-title-4097", state, document: orderDocument,
                   writes: state.annotationWriteCount - before)

        let duplicate = Bookmark(
            id: fixedUUID(500), page: 0, title: "duplicate", yPt: 0,
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let duplicateMessage = AnnotationRecords.validationMessage(
            for: duplicate, pageCount: pageCount, existingIDs: [duplicate.id])
        lines.append("B7 duplicate-identity | error=\(duplicateMessage.map(normalized) ?? "nil")")

        // ── C. The list limit is refused at the entry point (C9) ─────────────────────
        let limitDocument = try documentCopy("limit.pdf")
        let limitSeed = try DocumentEditCache.prepareAnnotations(for: limitDocument)
        let many = (0..<5_000).map { index in
            Bookmark(page: 0, title: "B\(index)", yPt: Double(index % 600),
                     createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(many).write(to: limitSeed)
        let limit = try await openState(limitDocument, bookmarks: 5_000)
        begin(limit)
        before = limit.annotationWriteCount
        let acceptedOverLimit = limit.addBookmark(onPage: 0, name: "over the limit")
        lines.append(
            "C1 add-5001st | accepted=\(acceptedOverLimit) | count=\(limit.bookmarks.count)"
                + " | writes+=\(limit.annotationWriteCount - before)"
                + " | error=\(limit.lastError.map(normalized) ?? "nil")")

        // ── D. The persisted slot order: interleaved with an annotation ──────────────
        let slotDocument = try documentCopy("slots.pdf")
        let slotSeed = try DocumentEditCache.prepareAnnotations(for: slotDocument)
        let seedAnnotation = AppState.Annotation(
            id: fixedUUID(900), kind: .highlight, page: 0, start: 1, end: 5,
            color: AppState.highlightPalette[0].color, note: "seed",
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let one = Bookmark(id: fixedUUID(901), page: 0, title: "One", yPt: 10,
                           createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let two = Bookmark(id: fixedUUID(902), page: 0, title: "Two", yPt: 20,
                           createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        try AnnotationRecords.encode(
            annotations: [seedAnnotation],
            bookmarks: [one, two],
            slots: [.annotation(seedAnnotation.id), .bookmark(one.id), .bookmark(two.id)]
        ).write(to: slotSeed)
        let slots = try await openState(slotDocument, bookmarks: 2)
        try record("D1 seeded A,One,Two", slots, document: slotDocument, writes: 0)

        begin(slots)
        before = slots.annotationWriteCount
        slots.moveBookmark(two.id, by: -1)
        try record("D2 move-Two-up", slots, document: slotDocument,
                   writes: slots.annotationWriteCount - before)

        begin(slots)
        before = slots.annotationWriteCount
        require(slots.addBookmark(onPage: 0, yPt: 30, name: "Three"),
                "C9 matrix: add beside two interleaved bookmarks")
        try record("D3 add-Three", slots, document: slotDocument,
                   writes: slots.annotationWriteCount - before)

        begin(slots)
        before = slots.annotationWriteCount
        slots.removeBookmark(one.id)
        try record("D4 remove-One (slot kept)", slots, document: slotDocument,
                   writes: slots.annotationWriteCount - before)

        begin(slots)
        before = slots.annotationWriteCount
        slots.moveBookmark(slots.bookmarks[1].id, by: -1)
        try record("D5 move-Three-up (slot reused)", slots, document: slotDocument,
                   writes: slots.annotationWriteCount - before)

        let reopened = try await openState(slotDocument, bookmarks: 2)
        try record("D6 reopen", reopened, document: slotDocument, writes: 0)

        for line in lines { print("MATRIX: \(line)") }
        // Captured on ee4c863 and re-checked after C9. The only changed rows are the three
        // marked (C9): an over-limit rename and the 5,001st add are now refused at the entry
        // point instead of being written and refused at save time.
        let expected = [
            "A1 add page-1 top | order=[0@0.00:\"Page 1\"] | display=[\"Page 1\"] | slots=[B0] | writes+=1 | error=nil",
            "A2 add page-1 y400 | order=[0@0.00:\"Page 1\", 0@400.00:\"Later on page 1\"] | display=[\"Page 1\", \"Later on page 1\"] | slots=[B0,B1] | writes+=1 | error=nil",
            "A3 add page-1 y10 | order=[0@0.00:\"Page 1\", 0@400.00:\"Later on page 1\", 0@10.00:\"Middle\"] | display=[\"Page 1\", \"Later on page 1\", \"Middle\"] | slots=[B0,B1,B2] | writes+=1 | error=nil",
            "A4 add last-page | order=[0@0.00:\"Page 1\", 0@400.00:\"Later on page 1\", 0@10.00:\"Middle\", 2@50.00:\"Page 3\"] | display=[\"Page 1\", \"Later on page 1\", \"Middle\", \"Page 3\"] | slots=[B0,B1,B2,B3] | writes+=1 | error=nil",
            "A5 add page-2 after page-3 | order=[0@0.00:\"Page 1\", 0@400.00:\"Later on page 1\", 0@10.00:\"Middle\", 2@50.00:\"Page 3\", 1@5.00:\"Back to page 2\"] | display=[\"Page 1\", \"Later on page 1\", \"Middle\", \"Page 3\", \"Back to page 2\"] | slots=[B0,B1,B2,B3,B4] | writes+=1 | error=nil",
            "A6 move-first-up (clamped) | order=[0@0.00:\"Page 1\", 0@400.00:\"Later on page 1\", 0@10.00:\"Middle\", 2@50.00:\"Page 3\", 1@5.00:\"Back to page 2\"] | display=[\"Page 1\", \"Later on page 1\", \"Middle\", \"Page 3\", \"Back to page 2\"] | slots=[B0,B1,B2,B3,B4] | writes+=0 | error=nil",
            "A7 move-last-down (clamped) | order=[0@0.00:\"Page 1\", 0@400.00:\"Later on page 1\", 0@10.00:\"Middle\", 2@50.00:\"Page 3\", 1@5.00:\"Back to page 2\"] | display=[\"Page 1\", \"Later on page 1\", \"Middle\", \"Page 3\", \"Back to page 2\"] | slots=[B0,B1,B2,B3,B4] | writes+=0 | error=nil",
            "A8 move-second-down | order=[0@0.00:\"Page 1\", 0@10.00:\"Middle\", 0@400.00:\"Later on page 1\", 2@50.00:\"Page 3\", 1@5.00:\"Back to page 2\"] | display=[\"Page 1\", \"Middle\", \"Later on page 1\", \"Page 3\", \"Back to page 2\"] | slots=[B0,B1,B2,B3,B4] | writes+=1 | error=nil",
            "A9 move-index-2-to-front | order=[0@400.00:\"Later on page 1\", 0@0.00:\"Page 1\", 0@10.00:\"Middle\", 2@50.00:\"Page 3\", 1@5.00:\"Back to page 2\"] | display=[\"Later on page 1\", \"Page 1\", \"Middle\", \"Page 3\", \"Back to page 2\"] | slots=[B0,B1,B2,B3,B4] | writes+=1 | error=nil",
            "A10 rename-empty | order=[0@400.00:\"\", 0@0.00:\"Page 1\", 0@10.00:\"Middle\", 2@50.00:\"Page 3\", 1@5.00:\"Back to page 2\"] | display=[\"Page 1\", \"Page 1\", \"Middle\", \"Page 3\", \"Back to page 2\"] | slots=[B0,B1,B2,B3,B4] | writes+=1 | error=nil",
            "A11 rename-whitespace | order=[0@400.00:\"   \", 0@0.00:\"Page 1\", 0@10.00:\"Middle\", 2@50.00:\"Page 3\", 1@5.00:\"Back to page 2\"] | display=[\"Page 1\", \"Page 1\", \"Middle\", \"Page 3\", \"Back to page 2\"] | slots=[B0,B1,B2,B3,B4] | writes+=1 | error=nil",
            "A12 rename-4097-bytes (C9) | order=[0@400.00:\"   \", 0@0.00:\"Page 1\", 0@10.00:\"Middle\", 2@50.00:\"Page 3\", 1@5.00:\"Back to page 2\"] | display=[\"Page 1\", \"Page 1\", \"Middle\", \"Page 3\", \"Back to page 2\"] | slots=[B0,B1,B2,B3,B4] | writes+=0 | error=bookmark \"<uuid>\" has a title longer than 4096 bytes",
            "A13 rename-NUL (C9) | order=[0@400.00:\"   \", 0@0.00:\"Page 1\", 0@10.00:\"Middle\", 2@50.00:\"Page 3\", 1@5.00:\"Back to page 2\"] | display=[\"Page 1\", \"Page 1\", \"Middle\", \"Page 3\", \"Back to page 2\"] | slots=[B0,B1,B2,B3,B4] | writes+=0 | error=bookmark \"<uuid>\" has a NUL in its title",
            "A14 rename-valid | order=[0@400.00:\"Final name\", 0@0.00:\"Page 1\", 0@10.00:\"Middle\", 2@50.00:\"Page 3\", 1@5.00:\"Back to page 2\"] | display=[\"Final name\", \"Page 1\", \"Middle\", \"Page 3\", \"Back to page 2\"] | slots=[B0,B1,B2,B3,B4] | writes+=1 | error=nil",
            "B1 add-page-out-of-range | order=[0@400.00:\"Final name\", 0@0.00:\"Page 1\", 0@10.00:\"Middle\", 2@50.00:\"Page 3\", 1@5.00:\"Back to page 2\"] | display=[\"Final name\", \"Page 1\", \"Middle\", \"Page 3\", \"Back to page 2\"] | slots=[B0,B1,B2,B3,B4] | writes+=0 | error=bookmark \"<uuid>\" names page 4, but the document has 3 page(s)",
            "B2 add-negative-page | order=[0@400.00:\"Final name\", 0@0.00:\"Page 1\", 0@10.00:\"Middle\", 2@50.00:\"Page 3\", 1@5.00:\"Back to page 2\"] | display=[\"Final name\", \"Page 1\", \"Middle\", \"Page 3\", \"Back to page 2\"] | slots=[B0,B1,B2,B3,B4] | writes+=0 | error=bookmark \"<uuid>\" names page 0, but the document has 3 page(s)",
            "B3 add-negative-y | order=[0@400.00:\"Final name\", 0@0.00:\"Page 1\", 0@10.00:\"Middle\", 2@50.00:\"Page 3\", 1@5.00:\"Back to page 2\"] | display=[\"Final name\", \"Page 1\", \"Middle\", \"Page 3\", \"Back to page 2\"] | slots=[B0,B1,B2,B3,B4] | writes+=0 | error=bookmark \"<uuid>\" has a Y that is not finite and non-negative",
            "B4 add-nan-y | order=[0@400.00:\"Final name\", 0@0.00:\"Page 1\", 0@10.00:\"Middle\", 2@50.00:\"Page 3\", 1@5.00:\"Back to page 2\"] | display=[\"Final name\", \"Page 1\", \"Middle\", \"Page 3\", \"Back to page 2\"] | slots=[B0,B1,B2,B3,B4] | writes+=0 | error=bookmark \"<uuid>\" has a Y that is not finite and non-negative",
            "B5 add-title-NUL | order=[0@400.00:\"Final name\", 0@0.00:\"Page 1\", 0@10.00:\"Middle\", 2@50.00:\"Page 3\", 1@5.00:\"Back to page 2\"] | display=[\"Final name\", \"Page 1\", \"Middle\", \"Page 3\", \"Back to page 2\"] | slots=[B0,B1,B2,B3,B4] | writes+=0 | error=bookmark \"<uuid>\" has a NUL in its title",
            "B6 add-title-4097 | order=[0@400.00:\"Final name\", 0@0.00:\"Page 1\", 0@10.00:\"Middle\", 2@50.00:\"Page 3\", 1@5.00:\"Back to page 2\"] | display=[\"Final name\", \"Page 1\", \"Middle\", \"Page 3\", \"Back to page 2\"] | slots=[B0,B1,B2,B3,B4] | writes+=0 | error=bookmark \"<uuid>\" has a title longer than 4096 bytes",
            "B7 duplicate-identity | error=two bookmarks in one save share the identity \"<uuid>\"",
            "C1 add-5001st | accepted=false | count=5000 | writes+=0 | error=5000 bookmarks is the most one save can write",
            "D1 seeded A,One,Two | order=[0@10.00:\"One\", 0@20.00:\"Two\"] | display=[\"One\", \"Two\"] | slots=[A,B0,B1] | writes+=0 | error=nil",
            "D2 move-Two-up | order=[0@20.00:\"Two\", 0@10.00:\"One\"] | display=[\"Two\", \"One\"] | slots=[A,B0,B1] | writes+=1 | error=nil",
            "D3 add-Three | order=[0@20.00:\"Two\", 0@10.00:\"One\", 0@30.00:\"Three\"] | display=[\"Two\", \"One\", \"Three\"] | slots=[A,B0,B1,B2] | writes+=1 | error=nil",
            "D4 remove-One (slot kept) | order=[0@20.00:\"Two\", 0@30.00:\"Three\"] | display=[\"Two\", \"Three\"] | slots=[A,B0,B1] | writes+=1 | error=nil",
            "D5 move-Three-up (slot reused) | order=[0@30.00:\"Three\", 0@20.00:\"Two\"] | display=[\"Three\", \"Two\"] | slots=[A,B0,B1] | writes+=1 | error=nil",
            "D6 reopen | order=[0@30.00:\"Three\", 0@20.00:\"Two\"] | display=[\"Three\", \"Two\"] | slots=[A,B0,B1] | writes+=0 | error=nil",
        ]
        require(lines == expected, "the bookmark matrix still matches the frozen C9 transcript")

        // The Rust unit test covers the same slot matrix; this proves the boundary conversion
        // keeps an annotation that sits between two bookmarks exactly where it was.
        func slotNames(_ slots: [AnnotationRecords.Slot]) -> [String] {
            slots.map { slot in
                switch slot {
                case .annotation(let id): return "A:\(id.uuidString)"
                case .bookmark(let id): return "B:\(id.uuidString)"
                case .opaque: return "O"
                }
            }
        }
        let annotationA = fixedUUID(910)
        let annotationB = fixedUUID(911)
        let bookmarkA = fixedUUID(912)
        let bookmarkB = fixedUUID(913)
        let interleaved: [AnnotationRecords.Slot] = [
            .annotation(annotationA), .bookmark(bookmarkA),
            .annotation(annotationB), .bookmark(bookmarkB),
        ]
        let reordered = AnnotationRecords.slotsAfterBookmarkReorder(
            interleaved, orderedIDs: [bookmarkB, bookmarkA])
        require(slotNames(reordered) == [
            "A:\(annotationA.uuidString)", "B:\(bookmarkB.uuidString)",
            "A:\(annotationB.uuidString)", "B:\(bookmarkA.uuidString)",
        ], "C9 matrix: a bookmark move keeps annotations between their slots")

        // Unicode whitespace is the one input where Swift's trim and Rust's trim could diverge;
        // both trim it, so a blank name still becomes the page label the sidebar shows.
        require(AnnotationRecords.titleForNewBookmark(name: "\u{00A0}\t\n", page: 0) == "Page 1"
                    && AnnotationRecords.titleForNewBookmark(name: " \u{3000}  ", page: 0)
                        == "Page 1",
                "C9 matrix: a whitespace-only name gets the Rust page label")
    }
}
