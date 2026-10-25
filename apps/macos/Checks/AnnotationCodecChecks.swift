import Foundation
import LyraReaderBindings
@testable import LyraReaderKit

// Captures the annotation-codec goldens from the **current** Swift encoder, and (in the normal
// check run) verifies that the Rust codec round-trips them byte-for-byte.
//
// The goldens are the acceptance evidence for audit C2: the cache format must not move when its
// implementation does. `--capture-annotation-codec-goldens <repository-root>` writes them under
// `tests/fixtures/annotation-codec/`; the values are frozen, so the capture command is only run
// when the format itself is deliberately changed.
extension ReaderChecks {
    /// Fixed identities and timestamps: the file's only two nondeterministic inputs.
    enum CodecFixture {
        static let date = Date(timeIntervalSinceReferenceDate: 804_000_000.5)
        static let late = Date(timeIntervalSinceReferenceDate: 804_000_000.123456)
        static let early = Date(timeIntervalSinceReferenceDate: -1_000.25)
        static let folded = Date(timeIntervalSinceReferenceDate: 1_729_876_543.123456)

        static func uuid(_ index: Int) -> UUID {
            UUID(uuidString: String(format: "%08X-1111-4222-8333-%012X", index + 1, index + 1))!
        }

        static func annotation(
            _ index: Int,
            kind: AppState.Annotation.Kind = .highlight,
            page: Int = 0,
            start: Int = 0,
            end: Int = 0,
            color: AnnotationColor = AppState.highlightPalette[0].color,
            note: String = "",
            createdAt: Date = date,
            inkPaths: [[CGPoint]] = [],
            shapeRect: CGRect? = nil,
            lineStart: CGPoint? = nil,
            lineEnd: CGPoint? = nil,
            strokeWidth: CGFloat = 0,
            fontSize: CGFloat = 0,
            fileIdentity: String? = nil,
            fileQuads: [AppState.Annotation.StoredRect]? = nil,
            textAlignment: String? = nil,
            stampStyle: String? = nil,
            imageData: Data? = nil
        ) -> AppState.Annotation {
            AppState.Annotation(
                id: uuid(index),
                kind: kind,
                page: page,
                start: start,
                end: end,
                color: color,
                note: note,
                createdAt: createdAt,
                inkPaths: inkPaths,
                shapeRect: shapeRect,
                lineStart: lineStart,
                lineEnd: lineEnd,
                strokeWidth: strokeWidth,
                fontSize: fontSize,
                fileIdentity: fileIdentity,
                fileQuads: fileQuads,
                textAlignment: textAlignment,
                stampStyle: stampStyle,
                imageData: imageData
            )
        }

        static func bookmark(
            _ index: Int,
            page: Int,
            title: String,
            yPt: CGFloat,
            createdAt: Date = date
        ) -> Bookmark {
            Bookmark(id: uuid(100 + index), page: page, title: title, yPt: yPt, createdAt: createdAt)
        }

        static func entry<Value: Encodable>(_ value: Value) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let text = String(decoding: try encoder.encode([value]), as: UTF8.self)
            return String(text.dropFirst(2).dropLast(2))
        }
    }

    /// One named fixture, as the bytes the current encoder writes.
    @MainActor static func annotationCodecFixtures(root: URL) throws -> [(String, Data)] {
        let palette = AppState.highlightPalette.map(\.color)
        func numbered(_ annotations: [AppState.Annotation], _ bookmarks: [Bookmark] = [])
            -> ([AppState.Annotation], [Bookmark], [AnnotationRecords.Slot])
        {
            var slots: [AnnotationRecords.Slot] = annotations.map { .annotation($0.id) }
            slots.append(contentsOf: bookmarks.map { .bookmark($0.id) })
            return (annotations, bookmarks, slots)
        }

        var goldens: [(String, Data)] = []

        // ── An empty cache ────────────────────────────────────────────────────────────────
        goldens.append((
            "empty.json",
            try AnnotationRecords.encode(annotations: [], bookmarks: [], slots: [])
        ))

        // ── The everyday case: plain highlights, palette and custom colours ──────────────
        let plain = [
            CodecFixture.annotation(0, start: 2, end: 10, color: palette[0], note: "a note"),
            CodecFixture.annotation(1, kind: .underline, page: 0, start: 20, end: 30,
                color: AnnotationColor(red: 0x12, green: 0x34, blue: 0x56, alpha: 0x78),
                note: "", createdAt: CodecFixture.late),
        ]
        let (a, b, s) = numbered(plain)
        goldens.append(("plain-highlights.json",
            try AnnotationRecords.encode(annotations: a, bookmarks: b, slots: s)))

        // ── Every kind the cache can store ──────────────────────────────────────────────
        let everyKind = [
            CodecFixture.annotation(10, start: 0, end: 3, color: palette[1], note: "highlight"),
            CodecFixture.annotation(11, kind: .underline, start: 4, end: 8, color: palette[2],
                note: "underline"),
            CodecFixture.annotation(12, kind: .strikeout, start: 9, end: 12,
                color: AnnotationColor(red: 0xAA, green: 0xBB, blue: 0xCC, alpha: 0xFF),
                note: "strikeout", createdAt: CodecFixture.early),
            CodecFixture.annotation(13, kind: .ink, note: "ink",
                inkPaths: [[CGPoint(x: 10.5, y: 20.25), CGPoint(x: 30, y: 40.5)],
                           [CGPoint(x: 50, y: 60), CGPoint(x: 70, y: 80)]],
                strokeWidth: 2),
            CodecFixture.annotation(14, kind: .square, note: "square",
                shapeRect: CGRect(x: 12.5, y: 22.25, width: 100, height: 50),
                strokeWidth: 1.5),
            CodecFixture.annotation(15, kind: .circle, note: "circle",
                shapeRect: CGRect(x: 200, y: 300, width: 40, height: 80), strokeWidth: 2),
            CodecFixture.annotation(16, kind: .line, note: "line",
                lineStart: CGPoint(x: 5, y: 6), lineEnd: CGPoint(x: 100.5, y: 200.25),
                strokeWidth: 2),
            CodecFixture.annotation(17, kind: .arrow, note: "arrow",
                lineStart: CGPoint(x: -2, y: -3), lineEnd: CGPoint(x: 90.75, y: 120.5),
                strokeWidth: 3),
            CodecFixture.annotation(18, kind: .stickyNote, note: "sticky note",
                createdAt: CodecFixture.late,
                shapeRect: CGRect(x: 400, y: 500, width: 22, height: 22)),
            CodecFixture.annotation(19, kind: .textBox, note: "body text",
                shapeRect: CGRect(x: 50, y: 60, width: 200, height: 100), fontSize: 14,
                fileIdentity: "nm:text-box", textAlignment: "right"),
            CodecFixture.annotation(20, kind: .stamp,
                color: AnnotationColor(red: 0xFF, green: 0, blue: 0, alpha: 0xFF),
                note: "CONFIDENTIAL",
                shapeRect: CGRect(x: 300, y: 400, width: 150, height: 50),
                stampStyle: "confidential"),
            CodecFixture.annotation(21, kind: .signature,
                color: AnnotationColor(red: 0, green: 0, blue: 0, alpha: 255),
                note: "",
                createdAt: CodecFixture.folded,
                shapeRect: CGRect(x: 600, y: 700, width: 100, height: 64),
                stampStyle: "signature", imageData: Data([0, 1, 2, 254, 255])),
        ]
        let (everyAnnotations, everyBookmarks, everySlots) = numbered(everyKind)
        goldens.append(("every-kind.json", try AnnotationRecords.encode(
            annotations: everyAnnotations, bookmarks: everyBookmarks, slots: everySlots)))

        // ── Notes with every escape the cache can carry ──────────────────────────────────
        let escaped = CodecFixture.annotation(30, start: 0, end: 1,
            note: "first line\nsecond line\r\nthird\ttabbed \"quoted\" backslash \\ slash / "
                + "café 中文 😀 \u{0}\u{1}\u{1f}", createdAt: CodecFixture.late,
            fileIdentity: "nm:escaped",
            fileQuads: [AppState.Annotation.StoredRect(x: 1.5, y: 2.25, width: 3, height: 4.5)],
            textAlignment: "center")
        goldens.append(("notes-newlines.json",
            try AnnotationRecords.encode(annotations: [escaped], bookmarks: [],
                slots: [.annotation(escaped.id)])))

        // ── Bookmark titles in every script the encoder can write ────────────────────────
        let unicodeBookmarks = [
            CodecFixture.bookmark(0, page: 0, title: "序章 · 中文标题", yPt: 0),
            CodecFixture.bookmark(1, page: 1, title: "Résumé — naïve", yPt: 12.5,
                createdAt: CodecFixture.late),
            CodecFixture.bookmark(2, page: 2, title: "Emoji 😀 and an em dash —", yPt: 804000000.123456,
                createdAt: CodecFixture.early),
        ]
        let (unicodeAnnotations, unicode, unicodeSlots) = numbered([], unicodeBookmarks)
        goldens.append(("bookmarks-unicode.json", try AnnotationRecords.encode(
            annotations: unicodeAnnotations, bookmarks: unicode, slots: unicodeSlots)))

        // ── Interleaved runs, a deleted entry and a duplicate slot ──────────────────────
        let interleaved = [
            CodecFixture.annotation(40, start: 0, end: 2, note: "first"),
            CodecFixture.annotation(41, start: 3, end: 5, note: "second"),
        ]
        let interleavedBookmarks = [
            CodecFixture.bookmark(2, page: 0, title: "between", yPt: 4.5),
            CodecFixture.bookmark(3, page: 0, title: "after", yPt: 9.75),
        ]
        let deleted = CodecFixture.annotation(42, start: 6, end: 7, note: "deleted")
        let interleavedSlots: [AnnotationRecords.Slot] = [
            .annotation(interleaved[0].id),
            .bookmark(interleavedBookmarks[0].id),
            .annotation(interleaved[1].id),
            .annotation(deleted.id),
            .bookmark(interleavedBookmarks[1].id),
            .annotation(interleaved[0].id),
        ]
        goldens.append(("interleaved-order.json", try AnnotationRecords.encode(
            annotations: interleaved, bookmarks: interleavedBookmarks, slots: interleavedSlots)))

        // ── A record written before `kind` existed (the old-version entry) ──────────────
        let oldEntry = """
{
  "colorIndex" : 0,
  "createdAt" : 804000000,
  "end" : 3,
  "id" : "\(CodecFixture.uuid(50).uuidString)",
  "note" : "written before kinds existed",
  "page" : 0,
  "start" : 0
}
"""
        let oldSource = "[\n\(oldEntry)\n]"
        let oldContents = try AnnotationRecords.decode(Data(oldSource.utf8),
            pageCount: 1_000, paletteCount: palette.count)
        goldens.append(("old-version-record.json", try AnnotationRecords.encode(
            annotations: oldContents.annotations, bookmarks: oldContents.bookmarks,
            slots: oldContents.slots)))

        // ── Entries this version cannot interpret, kept verbatim ─────────────────────────
        let known = CodecFixture.annotation(60, start: 0, end: 4, note: "known entry")
        let knownBody = try CodecFixture.entry(known)
        let futureKind = """
{
  "extraLayer" : {
    "version" : 7
  },
  "id" : "\(CodecFixture.uuid(61).uuidString)",
  "kind" : "futureMark",
  "page" : 0,
  "strokeWidth" : 3
}
"""
        let futureVersion = """
{
  "id" : "\(CodecFixture.uuid(62).uuidString)",
  "kind" : "ink",
  "page" : 0,
  "paths" : [
    [
      { "x" : 1, "y" : 2 },
      { "x" : 3, "y" : 4 }
    ]
  ],
  "strokeWidth" : 2.5,
  "version" : 2
}
"""
        let outOfPalette = """
{
  "colorIndex" : 9,
  "id" : "\(CodecFixture.uuid(63).uuidString)",
  "kind" : "highlight",
  "note" : "from a bigger palette",
  "page" : 0,
  "start" : 0,
  "end" : 1
}
"""
        let unknownField = """
{
  "createdAt" : 804000000,
  "id" : "\(CodecFixture.uuid(64).uuidString)",
  "kind" : "underline",
  "note" : "with a field this version does not know",
  "opacity" : 0.4,
  "page" : 0,
  "start" : 2,
  "end" : 3
}
"""
        let compact = #"{"colorIndex":2,"id":"\#(CodecFixture.uuid(65).uuidString)","kind":"ink","page":99,"strokes":[[1,2],[3,4]]}"#
        let foreignSource = "[\n"
            + [knownBody, futureKind, futureVersion, outOfPalette, unknownField, compact]
                .joined(separator: ",\n")
            + "\n]"
        let foreignContents = try AnnotationRecords.decode(Data(foreignSource.utf8),
            pageCount: 1_000, paletteCount: palette.count)
        goldens.append(("unknown-extra-fields.json", try AnnotationRecords.encode(
            annotations: foreignContents.annotations, bookmarks: foreignContents.bookmarks,
            slots: foreignContents.slots)))

        // ── A new highlight created through the UI, with a pinned identity and clock ────
        goldens.append(("ui-add-highlight.json", try uiCreatedHighlightBytes(root: root)))

        return goldens
    }

    /// The exact bytes a UI-created highlight writes, with identity and clock pinned.
    ///
    /// `addAnnotationFromSelection` is the one creation path the toolbar, the context menu and
    /// the sticky tools all use. The stamp makes the two nondeterministic inputs fixed so the
    /// bytes can be compared with the golden captured from the pre-Rust encoder.
    @MainActor static func uiCreatedHighlightBytes(root: URL) throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-annotation-codec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            AppState.annotationCreationStamp = nil
            try? FileManager.default.removeItem(at: directory)
        }
        let document = directory.appendingPathComponent("ui-add.pdf")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: document)
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        state.newTab(url: document)
        state.jump(to: CodecFixture.annotation(70, start: 2, end: 6))
        AppState.annotationCreationStamp = {
            (id: CodecFixture.uuid(71), createdAt: CodecFixture.date)
        }
        guard state.addAnnotationFromSelection(kind: .highlight) else {
            fatalError("the UI could not create the highlight the codec golden needs")
        }
        return try Data(contentsOf: DocumentEditCache.annotationsURL(for: document))
    }

    /// `LyraReaderChecks <root> --capture-annotation-codec-goldens` — writes the frozen
    /// fixtures. Never part of the normal run; the verify path is `annotationCodecChecks`.
    @MainActor static func captureAnnotationCodecGoldens(root: URL) throws {
        let directory = root.appendingPathComponent("tests/fixtures/annotation-codec")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let goldens = try annotationCodecFixtures(root: root)
        for (name, data) in goldens {
            try data.write(to: directory.appendingPathComponent(name))
        }
        print("captured \(goldens.count) annotation-codec goldens in \(directory.path)")
    }
}

// MARK: - The regression suite

extension ReaderChecks {
    /// Audit C2: the durable annotation cache keeps its bytes while its implementation moves.
    ///
    /// The goldens were captured from the Swift encoder before the Rust codec took over. This
    /// suite drives the production `AnnotationRecords` facade — which after the move is a thin
    /// shell over `lyra-reader-edit` — and requires the same bytes, the same forward-compatible
    /// preservation, the same kind flags and the same validation sentences.
    @MainActor static func annotationCodecChecks(root: URL) async throws {
        let directory = root.appendingPathComponent("tests/fixtures/annotation-codec")
        let palette = AppState.highlightPalette.map(\.color)
        func golden(_ name: String) throws -> Data {
            try Data(contentsOf: directory.appendingPathComponent(name))
        }
        func roundTrip(_ name: String) throws -> (Data, AnnotationRecords.Contents) {
            let bytes = try golden(name)
            let contents = try AnnotationRecords.decode(bytes, pageCount: 1_000,
                paletteCount: palette.count)
            let rewritten = try AnnotationRecords.encode(
                annotations: contents.annotations,
                bookmarks: contents.bookmarks,
                slots: contents.slots)
            return (rewritten, contents)
        }

        // ── 1. Every captured file decodes and re-encodes byte-identically ────────────────
        for name in [
            "empty.json",
            "plain-highlights.json",
            "every-kind.json",
            "notes-newlines.json",
            "bookmarks-unicode.json",
            "old-version-record.json",
            "unknown-extra-fields.json",
            "interleaved-order.json",
            "ui-add-highlight.json",
        ] {
            let (rewritten, contents) = try roundTrip(name)
            let expected = try golden(name)
            require(rewritten == expected,
                    "\(name) decodes through Rust and re-encodes byte-identically")
            if name == "empty.json" {
                require(contents.annotations.isEmpty && contents.bookmarks.isEmpty,
                        "the empty annotation cache is a valid empty array")
            }
        }

        // A genuinely empty (0-byte) file is still the same structural refusal as before;
        // `empty.json` above is the encoder's empty *array*, which round-trips.
        do {
            _ = try AnnotationRecords.decode(Data(), pageCount: 1, paletteCount: palette.count)
            require(false, "a 0-byte annotation cache must be refused")
        } catch {
            require(AnnotationRecords.message(error)
                        == "Invalid annotation records: byte 0: the annotation records must be a JSON array",
                    "a 0-byte annotation cache is refused with the same byte message")
        }

        // ── 2. Forward compatibility: foreign entries keep their exact source text ───────
        let (foreignRewritten, foreign) = try roundTrip("unknown-extra-fields.json")
        require(foreign.preservedCount == 5,
                "five entries this version cannot interpret are preserved (got \(foreign.preservedCount))")
        let foreignText = String(decoding: foreignRewritten, as: UTF8.self)
        for marker in ["\"futureMark\"", "\"extraLayer\"", "\"opacity\" : 0.4",
                       "\"strokes\":[[1,2],[3,4]]", "\"version\" : 2",
                       "\"colorIndex\" : 9"] {
            require(foreignText.contains(marker),
                    "the foreign entry containing \(marker) survives byte-for-byte")
        }
        require(foreign.annotations.count == 1,
                "the one understood entry beside the foreign ones is parsed")
        let foreignSource = try golden("unknown-extra-fields.json")
        require(foreignSource.contains(Data("\"futureMark\"".utf8)),
                "the golden itself still carries the foreign kind")

        // ── 3. The old cache loads through AppState and rewrites byte-identically ───────
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-annotation-codec-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let document = scratch.appendingPathComponent("old-cache.pdf")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: document)
        let recordsURL = DocumentEditCache.annotationsURL(for: document)
        try FileManager.default.createDirectory(
            at: recordsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldBytes = try golden("plain-highlights.json")
        try oldBytes.write(to: recordsURL)
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        state.newTab(url: document)
        require(state.annotations.count == 2, "the old cache loads both annotations")
        guard let first = state.annotations.first else {
            fatalError("the old cache golden needs a first annotation")
        }
        state.removeAnnotation(first.id)
        require(state.annotations.count == 1, "removing an annotation rewrites the cache")
        state.undo()
        require(state.annotations.count == 2, "undo restores the annotation")
        let oldRewritten = try Data(contentsOf: recordsURL)
        require(oldRewritten == oldBytes,
                "the old cache loads, is edited and is rewritten byte-identically")

        // ── 4. A new annotation added through the UI writes the same bytes as before ────
        let uiBytes = try uiCreatedHighlightBytes(root: root)
        let uiGolden = try golden("ui-add-highlight.json")
        require(uiBytes == uiGolden,
                "a highlight added through the UI writes the same annotations.json bytes as before")

        // ── 5. Kind flags match the predicates the Swift enums used to compute ──────────
        typealias KindRow = (
            kind: AppState.Annotation.Kind,
            markup: Bool,
            textMarkup: Bool,
            geometry: Bool,
            note: Bool,
            placed: Bool,
            stampArt: Bool,
            placement: Bool,
            write: AnnotationWriteKind,
            drawing: String,
            version: UInt32
        )
        let rows: [KindRow] = [
            KindRow(kind: .highlight, markup: true, textMarkup: true, geometry: false,
                    note: false, placed: false, stampArt: false, placement: false,
                    write: .highlight, drawing: "markup", version: 0),
            KindRow(kind: .underline, markup: true, textMarkup: true, geometry: false,
                    note: false, placed: false, stampArt: false, placement: false,
                    write: .underline, drawing: "markup", version: 0),
            KindRow(kind: .strikeout, markup: true, textMarkup: true, geometry: false,
                    note: false, placed: false, stampArt: false, placement: false,
                    write: .strikeOut, drawing: "markup", version: 0),
            KindRow(kind: .ink, markup: false, textMarkup: false, geometry: true,
                    note: false, placed: false, stampArt: false, placement: true,
                    write: .ink, drawing: "geometry", version: 1),
            KindRow(kind: .square, markup: false, textMarkup: false, geometry: true,
                    note: false, placed: false, stampArt: false, placement: true,
                    write: .square, drawing: "geometry", version: 1),
            KindRow(kind: .circle, markup: false, textMarkup: false, geometry: true,
                    note: false, placed: false, stampArt: false, placement: true,
                    write: .circle, drawing: "geometry", version: 1),
            KindRow(kind: .line, markup: false, textMarkup: false, geometry: true,
                    note: false, placed: false, stampArt: false, placement: true,
                    write: .line, drawing: "geometry", version: 1),
            KindRow(kind: .arrow, markup: false, textMarkup: false, geometry: true,
                    note: false, placed: false, stampArt: false, placement: true,
                    write: .line, drawing: "geometry", version: 1),
            KindRow(kind: .stickyNote, markup: false, textMarkup: false, geometry: false,
                    note: true, placed: true, stampArt: false, placement: true,
                    write: .note, drawing: "noteIcon", version: 1),
            KindRow(kind: .textBox, markup: false, textMarkup: false, geometry: false,
                    note: true, placed: true, stampArt: false, placement: true,
                    write: .freeText, drawing: "freeText", version: 1),
            KindRow(kind: .stamp, markup: false, textMarkup: false, geometry: false,
                    note: false, placed: false, stampArt: true, placement: true,
                    write: .stamp, drawing: "stamp", version: 1),
            KindRow(kind: .signature, markup: false, textMarkup: false, geometry: false,
                    note: false, placed: false, stampArt: true, placement: true,
                    write: .signature, drawing: "stamp", version: 1),
        ]
        for row in rows {
            let flags = AnnotationRecordRules.flags(for: row.kind)
            require(flags.isMarkup == row.markup,
                    "\(row.kind.rawValue): isMarkup matches the old predicate")
            require(flags.isTextMarkup == row.textMarkup,
                    "\(row.kind.rawValue): isTextMarkup matches the old predicate")
            require(flags.isGeometry == row.geometry,
                    "\(row.kind.rawValue): isGeometry matches the old predicate")
            require(flags.isNote == row.note,
                    "\(row.kind.rawValue): isNote matches the old predicate")
            require(flags.isPlacedText == row.placed,
                    "\(row.kind.rawValue): isPlacedText matches the old predicate")
            require(flags.isStampArtwork == row.stampArt,
                    "\(row.kind.rawValue): isStampArtwork matches the old predicate")
            require(flags.isPlacement == row.placement,
                    "\(row.kind.rawValue): isPlacement matches the old predicate")
            require(row.kind.isGeometry == row.geometry,
                    "\(row.kind.rawValue): an annotation kind is still geometry as before")
            require(row.kind.isTextMarkup == row.textMarkup
                        && row.kind.isPlacedText == row.placed
                        && row.kind.isStampArtwork == row.stampArt
                        && row.kind.isPlacement == row.placement,
                    "\(row.kind.rawValue): the display enum reads the table, not its own switch")
            require(flags.writeKind == row.write,
                    "\(row.kind.rawValue): the write kind is the table's, not a Swift switch")
            require(row.kind.writeKind == row.write,
                    "\(row.kind.rawValue): the model's write kind is the table's")
            require(flags.drawing == row.drawing,
                    "\(row.kind.rawValue): the drawing preset is \(row.drawing)")
            let expectedVersion: UInt32? = row.textMarkup ? nil : row.version
            require(flags.schemaVersion == expectedVersion,
                    "\(row.kind.rawValue): the record schema version matches")
        }
        let squiggly = AnnotationRecordRules.flags(forDocumentKind: "squiggly")
        require(squiggly.isMarkup && !squiggly.isTextMarkup && !squiggly.editable,
                "squiggly is markup but not an editable model")
        require(squiggly.unsupportedReason?.contains("Squiggly") == true,
                "squiggly's refusal names the subtype")
        let text = AnnotationRecordRules.flags(forDocumentKind: "text")
        require(text.isNote && text.writeKind == .note && !text.isMarkup,
                "a PDF /Text annotation is a note with a /Text write kind")
        let freeText = AnnotationRecordRules.flags(forDocumentKind: "freeText")
        require(freeText.isNote && freeText.writeKind == .freeText,
                "a PDF /FreeText annotation is a note with a /FreeText write kind")
        let arrow = AnnotationRecordRules.flags(forDocumentKind: "arrow")
        require(arrow.isGeometry && !arrow.editable,
                "a reported arrow keeps the old 'not editable' answer")
        let other = AnnotationRecordRules.flags(forDocumentKind: "Polygon")
        require(!other.editable && other.drawing == "skipped" && other.writeKind == nil,
                "an unmodelled subtype is skipped and not editable")
        require(other.unsupportedReason?.contains("/Polygon") == true,
                "an unmodelled subtype's refusal names it")

        // The engine's DocumentAnnotation flags are the same answers, not a second policy.
        let readingEngine = try RustEngine()
        _ = try readingEngine.openDocument(
            at: root.appendingPathComponent("tests/fixtures/annotated.pdf"))
        let fileAnnotations = try await readingEngine.annotations()
        require(!fileAnnotations.isEmpty, "the annotated fixture reports file annotations")
        for annotation in fileAnnotations {
            let flags = AnnotationRecordRules.flags(forDocumentKind: annotation.kind)
            require(annotation.isMarkup == flags.isMarkup
                        && annotation.isGeometry == flags.isGeometry
                        && annotation.isNote == flags.isNote,
                    "the engine's \(annotation.kind) flags match the one kind table")
        }
        if let editable = fileAnnotations.first(where: { $0.isMarkup }) {
            require(AppState.documentAnnotationEditability(editable) == .editable,
                    "an editable markup annotation is accepted by the one policy")
        }

        // ── 6. Validation: the same refusals and the same sentences as the writer ───────
        let id = CodecFixture.uuid(80).uuidString
        func annotationMessage(_ annotation: AppState.Annotation,
                               pageCount: Int = 1,
                               existing: [UUID] = []) -> String? {
            AnnotationRecords.validationMessage(for: annotation, pageCount: pageCount,
                existingIDs: existing)
        }
        let pageCase = CodecFixture.annotation(80, page: 1)
        require(annotationMessage(pageCase) ==
                    "annotation \"\(id)\" names page 2, but the document has 1 page(s)",
                "the page bound refuses with the writer's one-based sentence")
        let noteCase = CodecFixture.annotation(80, note: String(repeating: "x", count: 100_001))
        require(annotationMessage(noteCase) ==
                    "annotation \"\(id)\" has more than 100000 bytes of text",
                "the note limit refuses with the writer's sentence")
        let borderCase = CodecFixture.annotation(80, kind: .square,
            shapeRect: CGRect(x: 10, y: 10, width: 20, height: 20), strokeWidth: 201)
        require(annotationMessage(borderCase) ==
                    "annotation \"\(id)\" has a border width outside 0…200 pt",
                "the border-width limit refuses with the writer's sentence")
        let fontCase = CodecFixture.annotation(80, kind: .textBox,
            shapeRect: CGRect(x: 10, y: 10, width: 100, height: 40), fontSize: 0)
        require(annotationMessage(fontCase) ==
                    "annotation \"\(id)\" has a font size outside 1…400 pt",
                "the font-size limit refuses with the writer's sentence")
        let stampCase = CodecFixture.annotation(80, kind: .stamp, note: "   ",
            shapeRect: CGRect(x: 10, y: 10, width: 150, height: 50),
            stampStyle: "approved")
        require(annotationMessage(stampCase) ==
                    "stamp annotation \"\(id)\" has no text",
                "an empty stamp refuses with the writer's sentence")
        let signatureCase = CodecFixture.annotation(80, kind: .signature, note: "words",
            shapeRect: CGRect(x: 10, y: 10, width: 100, height: 64),
            imageData: Data([1, 2, 3]))
        require(annotationMessage(signatureCase) ==
                    "signature annotation \"\(id)\" must not carry text",
                "a signature carrying text refuses with the writer's sentence")
        require(annotationMessage(CodecFixture.annotation(80), existing: [CodecFixture.uuid(80)]) ==
                    "two annotations in one save share the identity \"\(id)\"",
                "a duplicate identity refuses with the writer's sentence")
        require(annotationMessage(CodecFixture.annotation(80)) == nil,
                "a valid annotation still passes the rule set")

        let bookmarkID = CodecFixture.uuid(100).uuidString
        func bookmarkMessage(_ bookmark: Bookmark, pageCount: Int = 1,
                             existing: [UUID] = []) -> String? {
            AnnotationRecords.validationMessage(for: bookmark, pageCount: pageCount,
                existingIDs: existing)
        }
        let longTitle = CodecFixture.bookmark(0, page: 0,
            title: String(repeating: "x", count: 4_097), yPt: 0)
        require(bookmarkMessage(longTitle) ==
                    "bookmark \"\(bookmarkID)\" has a title longer than 4096 bytes",
                "a long bookmark title refuses with the outline writer's sentence")
        let badPage = Bookmark(id: CodecFixture.uuid(100), page: 1, title: "x", yPt: 0)
        require(bookmarkMessage(badPage) ==
                    "bookmark \"\(bookmarkID)\" names page 2, but the document has 1 page(s)",
                "a bookmark page bound refuses with the outline writer's sentence")
        let badY = Bookmark(id: CodecFixture.uuid(100), page: 0, title: "x", yPt: -1)
        require(bookmarkMessage(badY) ==
                    "bookmark \"\(bookmarkID)\" has a Y that is not finite and non-negative",
                "a negative bookmark position refuses with the outline writer's sentence")
        require(bookmarkMessage(CodecFixture.bookmark(0, page: 0, title: "ok", yPt: 0),
                                existing: [CodecFixture.uuid(200)]) == nil,
                "a valid bookmark still passes the rule set")

        // The UI now refuses those inputs at creation, with the same sentence.
        let uiDocument = scratch.appendingPathComponent("ui-validation.pdf")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: uiDocument)
        let uiState = AppState(engine: try RustEngine())
        uiState.setViewportSize(CGSize(width: 700, height: 500))
        uiState.newTab(url: uiDocument)
        AppState.annotationCreationStamp = {
            (id: CodecFixture.uuid(80), createdAt: CodecFixture.date)
        }
        defer { AppState.annotationCreationStamp = nil }
        uiState.jump(to: CodecFixture.annotation(70, start: 2, end: 6))
        require(!uiState.addAnnotationFromSelection(
                    kind: .highlight, note: String(repeating: "x", count: 100_001)),
                "the UI refuses an over-long note at creation")
        require(uiState.lastError == annotationMessage(noteCase),
                "the UI's note refusal is the rule set's exact sentence")
        require(uiState.annotations.isEmpty, "a refused creation writes nothing")
        require(!uiState.addGeometryAnnotation(kind: .square, page: 0,
                    shapeRect: CGRect(x: 10, y: 10, width: 20, height: 20), strokeWidth: 201),
                "the UI refuses a border width the writer would refuse")
        require(uiState.lastError?.hasSuffix("has a border width outside 0…200 pt") == true,
                "the UI's border refusal is the rule set's sentence")
        require(uiState.addGeometryAnnotation(kind: .circle, page: 0,
                    shapeRect: CGRect(x: 10, y: 10, width: 20, height: 20)),
                "the UI still creates a valid shape")
        require(!uiState.addBookmark(onPage: 1, name: "off the document"),
                "the UI refuses a bookmark page outside the document")
        require(uiState.lastError?.hasSuffix("names page 2, but the document has 1 page(s)") == true,
                "the UI's bookmark-page refusal is the outline writer's sentence")
        require(!uiState.addBookmark(onPage: 0, yPt: -1, name: "above the page"),
                "the UI refuses a negative bookmark position")
        require(uiState.lastError?.hasSuffix(
                    "has a Y that is not finite and non-negative") == true,
                "the UI's bookmark-position refusal is the outline writer's sentence")
        require(!uiState.addBookmark(onPage: 0,
                    name: String(repeating: "x", count: 4_097)),
                "the UI refuses a bookmark title the writer would refuse")
        require(uiState.lastError?.hasSuffix("has a title longer than 4096 bytes") == true,
                "the UI's bookmark-title refusal is the outline writer's sentence")

        // The writer refuses the same records with exactly the same sentence.
        let writerDocument = scratch.appendingPathComponent("writer-refusal.pdf")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: writerDocument)
        let writerEngine = try RustEngine()
        _ = try writerEngine.openDocument(at: writerDocument)
        let writerOutput = scratch.appendingPathComponent("writer-refusal-copy.pdf")
        let borderRequest = AnnotationWriteRequest(
            id: id,
            page: 0,
            kind: .square,
            rect: CGRect(x: 10, y: 10, width: 20, height: 20),
            quads: [],
            borderWidthPt: 201,
            color: AppState.highlightPalette[0].color,
            opacity: 1,
            contents: "",
            author: AppState.annotationAuthor,
            modified: AppState.pdfDate(Date()))
        do {
            _ = try await writerEngine.saveAnnotationChanges(
                to: writerOutput, additions: [borderRequest], bookmarks: [], updates: [],
                deletions: [], zoom: 1)
            require(false, "the writer must refuse the border width the rule set refuses")
        } catch {
            require(AnnotationRecords.message(error) == annotationMessage(borderCase),
                    "the writer's border refusal is the rule set's exact sentence")
        }
        let longNoteRequest = AnnotationWriteRequest(
            id: id,
            page: 0,
            kind: .highlight,
            rect: CGRect(x: 10, y: 10, width: 100, height: 20),
            quads: [CGRect(x: 10, y: 10, width: 100, height: 20)],
            color: AppState.highlightPalette[0].color,
            opacity: 1,
            contents: String(repeating: "x", count: 100_001),
            author: AppState.annotationAuthor,
            modified: AppState.pdfDate(Date()))
        do {
            _ = try await writerEngine.saveAnnotationChanges(
                to: writerOutput, additions: [longNoteRequest], bookmarks: [], updates: [],
                deletions: [], zoom: 1)
            require(false, "the writer must refuse the note length the rule set refuses")
        } catch {
            require(AnnotationRecords.message(error) == annotationMessage(noteCase),
                    "the writer's note refusal is the rule set's exact sentence")
        }
        let writerBookmark = Bookmark(id: CodecFixture.uuid(100), page: 0,
            title: String(repeating: "x", count: 4_097), yPt: 0)
        do {
            _ = try await writerEngine.saveAnnotatedCopy(
                to: writerOutput, annotations: [], bookmarks: [writerBookmark], zoom: 1)
            require(false, "the outline writer must refuse the title the rule set refuses")
        } catch {
            require(AnnotationRecords.message(error) == bookmarkMessage(longTitle),
                    "the outline writer's title refusal is the rule set's exact sentence")
        }
    }
}
