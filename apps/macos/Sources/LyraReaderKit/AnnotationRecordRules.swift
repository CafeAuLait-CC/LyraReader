import CoreGraphics
import Foundation
import LyraReaderBindings

/// The durable annotation model's limits, defaults, clamps and kind table.
///
/// Every value here comes from `lyra-reader-edit` (`kind`, `rules`, `records`) through the FFI.
/// The Swift side keeps only the UI vocabulary: `AppState.Annotation.Kind` still names the marks
/// the toolbar offers, but it no longer decides what they *mean* — `isGeometry`, `isTextMarkup`,
/// `isPlacement` and the write-request mapping are lookups in one Rust table.
enum AnnotationRecordRules {
    /// The one rule/default table (audit C2). Read once; the values are compile-time constants in
    /// Rust, so a second read could not differ.
    static let limits = annotationRules()

    /// The kind table, keyed by the cache's `"kind"` value (`highlight` … `signature`).
    static let kindFlagsByRecordKind: [String: AnnotationKindFlagsRecord] = {
        var flags: [String: AnnotationKindFlagsRecord] = [:]
        for record in annotationKindFlags() {
            if let kind = record.recordKind {
                flags[kind] = record
            }
        }
        return flags
    }()

    /// The flags of one kind the shell can create and store.
    static func flags(for kind: AppState.Annotation.Kind) -> AnnotationKindFlagsRecord {
        guard let flags = kindFlagsByRecordKind[kind.rawValue] else {
            // The table and the enum are generated from the same model; a missing row is a
            // programming error, not a document condition. Fail loudly in a check run rather
            // than silently treating a mark as `skipped`.
            preconditionFailure("no annotation kind flags for \(kind.rawValue)")
        }
        return flags
    }

    /// The write request a kind becomes, or `nil` for a kind this build cannot write.
    static func writeKind(for kind: AppState.Annotation.Kind) -> AnnotationWriteKind? {
        flags(for: kind).writeKind
    }

    /// The flags of a kind the engine reports for an annotation inside a PDF (`text`, `freeText`,
    /// `squiggly`, or a subtype this build does not model). Used by the checks and by callers that
    /// only have the file's kind string.
    static func flags(forDocumentKind kind: String) -> AnnotationKindFlagsRecord {
        documentAnnotationKindFlags(kind: kind)
    }

    static func clampOpacity(_ value: Double) -> Double {
        clampAnnotationOpacity(opacity: value)
    }

    static func clampBorderWidth(_ value: Double) -> Double {
        clampAnnotationBorderWidth(width: value)
    }

    static func clampFontSize(_ value: Double) -> Double {
        clampAnnotationFontSize(size: value)
    }
}
