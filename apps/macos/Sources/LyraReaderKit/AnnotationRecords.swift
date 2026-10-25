import Foundation
import LyraReaderBindings

/// Reading and writing the document's annotation records.
///
/// The records are a JSON array of `AppState.Annotation` entries **and user bookmarks**, stored
/// as `annotations.json` in the document cache (`DocumentEditCache`). Every session reads and
/// writes that cache; nothing is read from or written beside the PDF.
///
/// The **format** lives in `lyra-reader-edit::records` and crosses the FFI: classification,
/// key order and pretty printing, Foundation's `Date`/`UUID`/base64 encodings, and the exact
/// text of an entry this version preserves. This file is the shell half — the cache directory,
/// file I/O, and the corruption/backup policy — plus the conversion between the FFI records and
/// the Swift model.
///
/// Both kinds live in one file because they are the reader's marks on one document, and the
/// array's per-entry compatibility rule keeps them safe together:
///
/// * **Forward compatibility.** Records written by a newer LyraReader can hold entries this
///   version cannot draw: an `ink` kind, a `color` value in a shape this version does not
///   know, a field that did not exist yet. Treating those as "the file is invalid" would make
///   an older version refuse the file and, if the reader forced a reset, destroy entries the
///   newer version still needs. Instead the *raw text* of such an entry is kept and written
///   back untouched, so the file round-trips through this version unchanged.
/// * **Bookmarks and older builds.** A bookmark is written with `"kind": "bookmark"`, which
///   no annotation-only build understands. Such a build classifies it as an entry it cannot
///   interpret — before it ever looks at `page` or `title` — and preserves its exact JSON
///   text. That is why bookmarks can share this file without an older build misreading one as
///   a broken highlight: the tag comes first. This build reads those entries back as
///   `Bookmark`; a *newer* build may add bookmark fields, which this version then preserves
///   verbatim in the same way. The compatibility machinery is per entry, so neither direction
///   has to know the other's schema.
/// * **Colour, and why the two encodings exist.** An annotation's colour used to be an index
///   into a four-entry palette (`colorIndex`); it is now an `AnnotationColor` written as
///   `"color": "#RRGGBBAA"`, because a PDF annotated by somebody else carries colours no
///   four-entry palette can express. Both keys are read. Only one is written, and which one is
///   decided by the colour itself (see `lyra-reader-edit::records`):
///
///   | records file | this build | the build that only knows `colorIndex` |
///   | --- | --- | --- |
///   | `colorIndex: 2` | reads it as palette colour 2 — exactly as before | reads it as before |
///   | `color` = a palette colour | writes `colorIndex`, no `color` key | reads and draws it normally |
///   | `color` = any other colour | writes `color`, no `colorIndex` | keeps the entry verbatim |
///
///   The last row is the honest limit: a colour outside that palette cannot be *drawn* by a
///   build whose model has no way to name it. What such a build must not do is lose it or
///   reinterpret it, and it does not — the entry comes back out of an older build unchanged,
///   while its own annotations keep working.
/// * **Fail closed, precisely.** Structural damage — not JSON at all, not an array, an entry
///   without id/page/range, a page outside the document, a duplicate id — is still an error.
///   The caller blocks writes rather than replacing a file it does not understand; the UI
///   then offers the explicit "back up and start fresh" recovery.
enum AnnotationRecords {
    /// Where an entry came from, so the file can be reproduced in its original order.
    enum Slot: Codable {
        /// An entry this version understands; looking it up by id in the current array keeps
        /// edits, undo and redo working without a second copy of the data.
        case annotation(UUID)
        /// A bookmark this version understands; its array order is the reader's order.
        case bookmark(UUID)
        /// Verbatim JSON text of an entry this version does not understand.
        case opaque(String)
    }

    struct Contents {
        var annotations: [AppState.Annotation]
        var bookmarks: [Bookmark]
        var slots: [Slot]

        var preservedCount: Int {
            slots.reduce(0) { count, slot in
                if case .opaque = slot { return count + 1 }
                return count
            }
        }
    }

    enum RecordError: LocalizedError {
        case structure(String)

        var errorDescription: String? {
            switch self {
            case .structure(let detail): return "Invalid annotation records: \(detail)"
            }
        }
    }

    /// A decoding failure as "field 'name' …", used by both the annotation records and the
    /// document-cache metadata so a corrupt file says which field is wrong, not just that it
    /// could not be read.
    static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue)
            return keys.isEmpty ? "the record" : "field '\(keys.joined(separator: "."))'"
        }
        switch error {
        case .keyNotFound(let key, let context):
            let parent = context.codingPath.map(\.stringValue).joined(separator: ".")
            return parent.isEmpty
                ? "field '\(key.stringValue)' is missing"
                : "field '\(parent).\(key.stringValue)' is missing"
        case .typeMismatch(let type, let context):
            return "\(path(context)) has the wrong type (expected \(type))"
        case .valueNotFound(let type, let context):
            return "\(path(context)) has no value (expected \(type))"
        case .dataCorrupted(let context):
            return "\(path(context)) is invalid: \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    /// The reader-facing text of an FFI error, without the binding's reflected enum wrapper.
    static func message(_ error: Error) -> String {
        if let ffi = error as? LyraReaderFfiError {
            switch ffi {
            case .Document(let message, _), .Backend(let message, _),
                 .InvalidArgument(let message, _), .Ai(let message, _, _):
                return message
            }
        }
        return error.localizedDescription
    }

    // MARK: - The codec boundary

    /// The legacy palette, as the Rust decoder needs it to read an older `colorIndex`.
    static func palette() -> [AnnotationRecordColor] {
        AppState.highlightPalette.map {
            AnnotationRecordColor(
                red: $0.color.red,
                green: $0.color.green,
                blue: $0.color.blue,
                alpha: $0.color.alpha
            )
        }
    }

    /// One cached annotation as the FFI record. Public inside the module because the creation
    /// validation uses the same conversion as the encoder.
    static func entry(_ annotation: AppState.Annotation) -> CachedAnnotationRecord {
        CachedAnnotationRecord(
            id: annotation.id.uuidString,
            kind: annotation.kind.rawValue,
            page: Int64(annotation.page),
            start: Int64(annotation.start),
            end: Int64(annotation.end),
            color: AnnotationRecordColor(
                red: annotation.color.red,
                green: annotation.color.green,
                blue: annotation.color.blue,
                alpha: annotation.color.alpha
            ),
            note: annotation.note,
            createdAt: annotation.createdAt.timeIntervalSinceReferenceDate,
            inkPaths: annotation.inkPaths.map { path in
                path.map { AnnotationRecordPoint(x: Double($0.x), y: Double($0.y)) }
            },
            shapeRect: annotation.shapeRect.map {
                AnnotationRecordRect(x: Double($0.minX), y: Double($0.minY),
                                     width: Double($0.width), height: Double($0.height))
            },
            lineStart: annotation.lineStart.map {
                AnnotationRecordPoint(x: Double($0.x), y: Double($0.y))
            },
            lineEnd: annotation.lineEnd.map {
                AnnotationRecordPoint(x: Double($0.x), y: Double($0.y))
            },
            strokeWidth: Double(annotation.strokeWidth),
            fontSize: Double(annotation.fontSize),
            fileIdentity: annotation.fileIdentity,
            fileQuads: annotation.fileQuads?.map {
                AnnotationRecordRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            },
            textAlignment: annotation.textAlignment,
            stampStyle: annotation.stampStyle,
            imageData: annotation.imageData
        )
    }

    static func entry(_ bookmark: Bookmark) -> CachedBookmarkRecord {
        CachedBookmarkRecord(
            id: bookmark.id.uuidString,
            page: Int64(bookmark.page),
            title: bookmark.title,
            yPt: Double(bookmark.yPt),
            createdAt: bookmark.createdAt.timeIntervalSinceReferenceDate
        )
    }

    private static func slot(_ slot: Slot) -> CachedAnnotationSlot {
        switch slot {
        case .annotation(let id): return .annotation(id: id.uuidString)
        case .bookmark(let id): return .bookmark(id: id.uuidString)
        case .opaque(let raw): return .opaque(raw: raw)
        }
    }

    private static func slot(_ record: CachedAnnotationSlot) -> Slot {
        switch record {
        case .annotation(let id):
            return .annotation(UUID(uuidString: id) ?? UUID())
        case .bookmark(let id):
            return .bookmark(UUID(uuidString: id) ?? UUID())
        case .opaque(let raw):
            return .opaque(raw)
        }
    }

    private static func annotation(_ record: CachedAnnotationRecord) throws -> AppState.Annotation {
        guard let id = UUID(uuidString: record.id) else {
            throw RecordError.structure("field 'id' is invalid: expected a UUID string")
        }
        guard let kind = AppState.Annotation.Kind(rawValue: record.kind) else {
            throw RecordError.structure("field 'kind' is invalid: \(record.kind)")
        }
        return AppState.Annotation(
            id: id,
            kind: kind,
            page: Int(record.page),
            start: Int(record.start),
            end: Int(record.end),
            color: AnnotationColor(
                red: record.color.red,
                green: record.color.green,
                blue: record.color.blue,
                alpha: record.color.alpha
            ),
            note: record.note,
            createdAt: Date(timeIntervalSinceReferenceDate: record.createdAt),
            inkPaths: record.inkPaths.map { path in
                path.map { CGPoint(x: $0.x, y: $0.y) }
            },
            shapeRect: record.shapeRect.map {
                CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            },
            lineStart: record.lineStart.map { CGPoint(x: $0.x, y: $0.y) },
            lineEnd: record.lineEnd.map { CGPoint(x: $0.x, y: $0.y) },
            strokeWidth: CGFloat(record.strokeWidth),
            fontSize: CGFloat(record.fontSize),
            fileIdentity: record.fileIdentity,
            fileQuads: record.fileQuads?.map {
                AppState.Annotation.StoredRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            },
            textAlignment: record.textAlignment,
            stampStyle: record.stampStyle,
            imageData: record.imageData
        )
    }

    private static func bookmark(_ record: CachedBookmarkRecord) throws -> Bookmark {
        guard let id = UUID(uuidString: record.id) else {
            throw RecordError.structure("field 'id' is invalid: expected a UUID string")
        }
        return Bookmark(
            id: id,
            page: Int(record.page),
            title: record.title,
            yPt: CGFloat(record.yPt),
            createdAt: Date(timeIntervalSinceReferenceDate: record.createdAt)
        )
    }

    // MARK: - Loading

    /// Decodes through the Rust codec. The file I/O and the corruption/backup policy stay here;
    /// the format — key order, date encoding, which entries this version can interpret — is
    /// `lyra-reader-edit::records`.
    static func decode(_ data: Data, pageCount: Int, paletteCount: Int) throws -> Contents {
        do {
            let palette = Array(palette().prefix(max(0, paletteCount)))
            let decoded = try decodeAnnotationCache(
                data: data,
                pageCount: UInt32(clamping: max(0, pageCount)),
                palette: palette
            )
            return Contents(
                annotations: try decoded.annotations.map(annotation),
                bookmarks: try decoded.bookmarks.map(bookmark),
                slots: decoded.slots.map(slot)
            )
        } catch let error as RecordError {
            throw error
        } catch {
            throw RecordError.structure(message(error))
        }
    }

    // MARK: - Saving

    /// The bytes to write for `annotations` and `bookmarks`, in the annotation cache's original entry
    /// order, with the preserved entries reproduced verbatim.
    static func encode(
        annotations: [AppState.Annotation],
        bookmarks: [Bookmark],
        slots: [Slot]
    ) throws -> Data {
        do {
            return try encodeAnnotationCache(
                annotations: annotations.map(entry),
                bookmarks: bookmarks.map(entry),
                slots: slots.map(slot),
                palette: palette()
            )
        } catch let error as RecordError {
            throw error
        } catch {
            throw RecordError.structure(message(error))
        }
    }

    // MARK: - Creation-time validation

    /// Why the cache would refuse this annotation when the PDF is saved, or `nil` when it is
    /// valid. The shell calls this before it appends a new entry, so the reader is told at
    /// creation with the writer's own sentence.
    static func validationMessage(
        for annotation: AppState.Annotation,
        pageCount: Int,
        existingIDs: [UUID]
    ) -> String? {
        do {
            try validateCachedAnnotation(
                annotation: entry(annotation),
                pageCount: UInt32(clamping: max(0, pageCount)),
                existingIds: existingIDs.map(\.uuidString)
            )
            return nil
        } catch {
            return message(error)
        }
    }

    static func validationMessage(
        for bookmark: Bookmark,
        pageCount: Int,
        existingIDs: [UUID]
    ) -> String? {
        do {
            try validateCachedBookmark(
                bookmark: entry(bookmark),
                pageCount: UInt32(clamping: max(0, pageCount)),
                existingIds: existingIDs.map(\.uuidString)
            )
            return nil
        } catch {
            return message(error)
        }
    }
}
