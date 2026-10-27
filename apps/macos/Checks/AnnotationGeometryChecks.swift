import CoreGraphics
import Foundation
@testable import LyraReaderKit

// Freezes the Swift model's `hasValidGeometry` answers before the predicate moves to Rust, then
// requires the FFI-backed property to reproduce every one of them.
//
// The matrix is deliberately made of `AppState.Annotation` values, not of `CachedAnnotationRecord`
// values: the property is what the UI and the cache decoder call, and the point of the change is
// that its name and call sites stay put. `--capture-annotation-geometry-matrix` rewrites the
// fixture from the current implementation; only a deliberate threshold change should run it.
extension ReaderChecks {
    struct AnnotationGeometryCase {
        let name: String
        let annotation: AppState.Annotation
    }

    /// Every case the UI model can express, including the exact thresholds and their neighbours.
    ///
    /// Two kind values cannot appear here because `AppState.Annotation.Kind` does not have them:
    /// `squiggly` (a PDF annotation this build only reads) and an unmodelled `/Subtype`. Rust
    /// answers `false` for both; the UI model cannot construct either.
    @MainActor static func annotationGeometryCases() -> [AnnotationGeometryCase] {
        var cases: [AnnotationGeometryCase] = []
        func add(
            _ name: String,
            kind: AppState.Annotation.Kind,
            note: String = "",
            inkPaths: [[CGPoint]] = [],
            shapeRect: CGRect? = nil,
            lineStart: CGPoint? = nil,
            lineEnd: CGPoint? = nil,
            strokeWidth: CGFloat = 2,
            fontSize: CGFloat = 0,
            imageData: Data? = nil
        ) {
            cases.append(AnnotationGeometryCase(
                name: name,
                annotation: AppState.Annotation(
                    id: UUID(),
                    kind: kind,
                    page: 0,
                    start: 0,
                    end: 0,
                    color: AnnotationColor(red: 0, green: 0, blue: 0, alpha: 255),
                    note: note,
                    createdAt: Date(timeIntervalSinceReferenceDate: 0),
                    inkPaths: inkPaths,
                    shapeRect: shapeRect,
                    lineStart: lineStart,
                    lineEnd: lineEnd,
                    strokeWidth: strokeWidth,
                    fontSize: fontSize,
                    imageData: imageData
                )))
        }

        let p1 = CGPoint(x: 10, y: 10)
        let p2 = CGPoint(x: 20, y: 20)
        let ink = [p1, p2]
        let box = CGRect(x: 10, y: 10, width: 100, height: 50)
        let stampBox = CGRect(x: 10, y: 10, width: 150, height: 50)
        let signatureBox = CGRect(x: 10, y: 10, width: 30, height: 10)
        let end = CGPoint(x: 20, y: 20)

        // ── One valid annotation of every kind ──────────────────────────────────────────
        add("highlight/valid", kind: .highlight, strokeWidth: 0)
        add("underline/valid", kind: .underline, strokeWidth: 0)
        add("strikeout/valid", kind: .strikeout, strokeWidth: 0)
        add("ink/valid", kind: .ink, inkPaths: [ink])
        add("square/valid", kind: .square, shapeRect: CGRect(x: 10, y: 10, width: 20, height: 20))
        add("circle/valid", kind: .circle, shapeRect: CGRect(x: 10, y: 10, width: 20, height: 20))
        add("line/valid", kind: .line, lineStart: p1, lineEnd: end)
        add("arrow/valid", kind: .arrow, lineStart: p1, lineEnd: end)
        add("stickyNote/valid", kind: .stickyNote,
            shapeRect: CGRect(x: 10, y: 10, width: 22, height: 22))
        add("textBox/valid", kind: .textBox, shapeRect: box, strokeWidth: 0, fontSize: 14)
        add("stamp/valid", kind: .stamp, note: "APPROVED", shapeRect: stampBox, strokeWidth: 0)
        add("signature/valid", kind: .signature, shapeRect: signatureBox, strokeWidth: 0,
            imageData: Data([1, 2, 3]))

        // ── The stroke-width guard applies before the kind switch, to every placement kind ──
        let strokeWidths: [(String, CGFloat)] = [
            ("0", 0), ("200", 200), ("200.0001", 200.0001), ("nan", CGFloat.nan), ("negative", -1),
        ]
        for (suffix, width) in strokeWidths {
            add("strokeWidth/\(suffix)/ink", kind: .ink, inkPaths: [ink], strokeWidth: width)
            add("strokeWidth/\(suffix)/square", kind: .square,
                shapeRect: CGRect(x: 10, y: 10, width: 20, height: 20), strokeWidth: width)
            add("strokeWidth/\(suffix)/circle", kind: .circle,
                shapeRect: CGRect(x: 10, y: 10, width: 20, height: 20), strokeWidth: width)
            add("strokeWidth/\(suffix)/line", kind: .line, lineStart: p1, lineEnd: end,
                strokeWidth: width)
            add("strokeWidth/\(suffix)/arrow", kind: .arrow, lineStart: p1, lineEnd: end,
                strokeWidth: width)
            add("strokeWidth/\(suffix)/stickyNote", kind: .stickyNote,
                shapeRect: CGRect(x: 10, y: 10, width: 22, height: 22), strokeWidth: width)
            add("strokeWidth/\(suffix)/textBox", kind: .textBox, shapeRect: box,
                strokeWidth: width, fontSize: 14)
            add("strokeWidth/\(suffix)/stamp", kind: .stamp, note: "APPROVED",
                shapeRect: stampBox, strokeWidth: width)
            add("strokeWidth/\(suffix)/signature", kind: .signature, shapeRect: signatureBox,
                strokeWidth: width, imageData: Data([1, 2, 3]))
        }

        // ── Ink: a stroke needs at least two finite points ──────────────────────────────
        add("ink/empty-paths", kind: .ink, inkPaths: [])
        add("ink/one-point", kind: .ink, inkPaths: [[p1]])
        add("ink/two-points", kind: .ink, inkPaths: [ink])
        add("ink/two-paths", kind: .ink, inkPaths: [ink, [p2, p1]])
        add("ink/two-paths-second-one-point", kind: .ink, inkPaths: [ink, [p2]])
        add("ink/duplicate-two-points", kind: .ink, inkPaths: [[p1, p1]])
        add("ink/nan-x", kind: .ink, inkPaths: [[p1, CGPoint(x: CGFloat.nan, y: 20)]])
        add("ink/infinite-y", kind: .ink, inkPaths: [[p1, CGPoint(x: 20, y: CGFloat.infinity)]])
        add("ink/nan-third-point", kind: .ink,
            inkPaths: [[p1, p2, CGPoint(x: CGFloat.nan, y: 30)]])

        // ── Square/circle: a finite, strictly positive rectangle ────────────────────────
        let rects: [(String, CGRect?)] = [
            ("nil", nil),
            ("0x1", CGRect(x: 0, y: 0, width: 0, height: 1)),
            ("1x0", CGRect(x: 0, y: 0, width: 1, height: 0)),
            ("1x1", CGRect(x: 0, y: 0, width: 1, height: 1)),
            ("negative-width", CGRect(x: 0, y: 0, width: -1, height: 1)),
            ("negative-height", CGRect(x: 0, y: 0, width: 1, height: -1)),
            ("nan-x", CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)),
            ("nan-y", CGRect(x: 0, y: CGFloat.nan, width: 1, height: 1)),
            ("nan-width", CGRect(x: 0, y: 0, width: CGFloat.nan, height: 1)),
            ("nan-height", CGRect(x: 0, y: 0, width: 1, height: CGFloat.nan)),
            ("infinite-width", CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1)),
            ("infinite-height", CGRect(x: 0, y: 0, width: 1, height: CGFloat.infinity)),
            ("negative-origin", CGRect(x: -100, y: -100, width: 10, height: 10)),
        ]
        for (suffix, rect) in rects {
            add("square/\(suffix)", kind: .square, shapeRect: rect)
            add("circle/\(suffix)", kind: .circle, shapeRect: rect)
        }

        // ── Line/arrow: both finite endpoints and an exact `> 0.01` distance ─────────────
        let boundary: CGFloat = 0.01
        let lineVariants: [(String, CGPoint?, CGPoint?)] = [
            ("nil-start", nil, end),
            ("nil-end", p1, nil),
            ("nil-both", nil, nil),
            ("same-point", p1, p1),
            ("distance-exactly-0.01", CGPoint(x: 0, y: 0), CGPoint(x: boundary, y: 0)),
            ("distance-just-under", CGPoint(x: 0, y: 0), CGPoint(x: boundary.nextDown, y: 0)),
            ("distance-just-over", CGPoint(x: 0, y: 0), CGPoint(x: boundary.nextUp, y: 0)),
            ("nan-start-x", CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 10, y: 0)),
            ("infinite-end-y", CGPoint(x: 0, y: 0), CGPoint(x: 10, y: CGFloat.infinity)),
            ("negative-endpoints", CGPoint(x: -20, y: -20), CGPoint(x: -10, y: -10)),
        ]
        for (suffix, start, finish) in lineVariants {
            add("line/\(suffix)", kind: .line, lineStart: start, lineEnd: finish)
            add("arrow/\(suffix)", kind: .arrow, lineStart: start, lineEnd: finish)
        }

        // ── Sticky note: a finite rectangle of at least 1 × 1 ───────────────────────────
        add("stickyNote/nil", kind: .stickyNote, shapeRect: nil)
        add("stickyNote/0.99x1", kind: .stickyNote,
            shapeRect: CGRect(x: 0, y: 0, width: 0.99, height: 1))
        add("stickyNote/1x0.99", kind: .stickyNote,
            shapeRect: CGRect(x: 0, y: 0, width: 1, height: 0.99))
        add("stickyNote/1x1", kind: .stickyNote,
            shapeRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        add("stickyNote/nan-width", kind: .stickyNote,
            shapeRect: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 1))
        add("stickyNote/infinite-height", kind: .stickyNote,
            shapeRect: CGRect(x: 0, y: 0, width: 1, height: CGFloat.infinity))
        add("stickyNote/negative-width", kind: .stickyNote,
            shapeRect: CGRect(x: 0, y: 0, width: -1, height: 1))

        // ── Stamp: rectangle ≥ 12 × 8 and non-blank words ───────────────────────────────
        add("stamp/12x8", kind: .stamp, note: "S",
            shapeRect: CGRect(x: 0, y: 0, width: 12, height: 8))
        add("stamp/11.999x8", kind: .stamp, note: "S",
            shapeRect: CGRect(x: 0, y: 0, width: 11.999, height: 8))
        add("stamp/12x7.999", kind: .stamp, note: "S",
            shapeRect: CGRect(x: 0, y: 0, width: 12, height: 7.999))
        add("stamp/empty-note", kind: .stamp, note: "",
            shapeRect: CGRect(x: 0, y: 0, width: 12, height: 8))
        add("stamp/space-note", kind: .stamp, note: " ",
            shapeRect: CGRect(x: 0, y: 0, width: 12, height: 8))
        add("stamp/newline-tab-note", kind: .stamp, note: "\n\t",
            shapeRect: CGRect(x: 0, y: 0, width: 12, height: 8))
        add("stamp/nbsp-note", kind: .stamp, note: "\u{00A0}",
            shapeRect: CGRect(x: 0, y: 0, width: 12, height: 8))
        add("stamp/padded-note", kind: .stamp, note: " X ",
            shapeRect: CGRect(x: 0, y: 0, width: 12, height: 8))
        add("stamp/nil-rect", kind: .stamp, note: "S", shapeRect: nil)
        add("stamp/nan-width", kind: .stamp, note: "S",
            shapeRect: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 8))
        add("stamp/empty-image-does-not-matter", kind: .stamp, note: "S",
            shapeRect: CGRect(x: 0, y: 0, width: 12, height: 8), imageData: Data())

        // ── Image signature: rectangle ≥ 6 × 6 and non-empty picture ────────────────────
        add("signature/6x6", kind: .signature,
            shapeRect: CGRect(x: 0, y: 0, width: 6, height: 6), imageData: Data([0]))
        add("signature/5.999x6", kind: .signature,
            shapeRect: CGRect(x: 0, y: 0, width: 5.999, height: 6), imageData: Data([0]))
        add("signature/6x5.999", kind: .signature,
            shapeRect: CGRect(x: 0, y: 0, width: 6, height: 5.999), imageData: Data([0]))
        add("signature/nil-image", kind: .signature,
            shapeRect: CGRect(x: 0, y: 0, width: 6, height: 6), imageData: nil)
        add("signature/empty-image", kind: .signature,
            shapeRect: CGRect(x: 0, y: 0, width: 6, height: 6), imageData: Data())
        add("signature/nil-rect", kind: .signature, shapeRect: nil, imageData: Data([0]))
        add("signature/nan-height", kind: .signature,
            shapeRect: CGRect(x: 0, y: 0, width: 6, height: CGFloat.nan), imageData: Data([0]))
        add("signature/ignores-note", kind: .signature, note: "ignored",
            shapeRect: CGRect(x: 0, y: 0, width: 6, height: 6), imageData: Data([0]))

        // ── Text box: rectangle ≥ 24 × 24 and font size 1…400 ───────────────────────────
        add("textBox/24x24", kind: .textBox,
            shapeRect: CGRect(x: 0, y: 0, width: 24, height: 24), fontSize: 14)
        add("textBox/23.999x24", kind: .textBox,
            shapeRect: CGRect(x: 0, y: 0, width: 23.999, height: 24), fontSize: 14)
        add("textBox/24x23.999", kind: .textBox,
            shapeRect: CGRect(x: 0, y: 0, width: 24, height: 23.999), fontSize: 14)
        add("textBox/font-1", kind: .textBox,
            shapeRect: CGRect(x: 0, y: 0, width: 24, height: 24), fontSize: 1)
        add("textBox/font-400", kind: .textBox,
            shapeRect: CGRect(x: 0, y: 0, width: 24, height: 24), fontSize: 400)
        add("textBox/font-0.999", kind: .textBox,
            shapeRect: CGRect(x: 0, y: 0, width: 24, height: 24), fontSize: 0.999)
        add("textBox/font-400.0001", kind: .textBox,
            shapeRect: CGRect(x: 0, y: 0, width: 24, height: 24), fontSize: 400.0001)
        add("textBox/font-nan", kind: .textBox,
            shapeRect: CGRect(x: 0, y: 0, width: 24, height: 24), fontSize: CGFloat.nan)
        add("textBox/font-infinite", kind: .textBox,
            shapeRect: CGRect(x: 0, y: 0, width: 24, height: 24), fontSize: CGFloat.infinity)
        add("textBox/nil-rect", kind: .textBox, shapeRect: nil, fontSize: 14)
        add("textBox/nan-x", kind: .textBox,
            shapeRect: CGRect(x: CGFloat.nan, y: 0, width: 24, height: 24), fontSize: 14)
        add("textBox/23x23", kind: .textBox,
            shapeRect: CGRect(x: 0, y: 0, width: 23, height: 23), fontSize: 14)

        // ── Text markup is never a geometry annotation ──────────────────────────────────
        add("highlight/strokeWidth-nan", kind: .highlight, strokeWidth: CGFloat.nan)
        add("underline/large-range", kind: .underline, strokeWidth: 0)

        return cases
    }

    /// The frozen answer for every case above, captured before the property moved to Rust.
    @MainActor static func annotationGeometryMatrix(root: URL) throws -> [(String, Bool)] {
        let url = root.appendingPathComponent("tests/fixtures/annotation-geometry-matrix.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Bool(String(parts[1])) else {
                throw NSError(domain: "LyraReaderChecks", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "annotation geometry matrix line is not 'name=true|false': \(line)",
                ])
            }
            return (String(parts[0]), value)
        }
    }

    @MainActor static func annotationGeometryChecks(root: URL) throws {
        let frozen = try annotationGeometryMatrix(root: root)
        let cases = annotationGeometryCases()
        let actual = cases.map { ($0.name, $0.annotation.hasValidGeometry) }
        require(Set(cases.map(\.name)).count == cases.count,
                "annotation geometry matrix case names are unique")
        guard actual.count == frozen.count else {
            fatalError("FAIL: annotation geometry matrix has \(actual.count) cases, frozen file has \(frozen.count)")
        }
        var mismatches: [String] = []
        for (actualCase, frozenCase) in zip(actual, frozen) {
            if actualCase != frozenCase {
                mismatches.append("\(actualCase.0): got \(actualCase.1), frozen \(frozenCase.1)")
            }
        }
        require(mismatches.isEmpty,
                "the annotation geometry matrix reproduces all \(frozen.count) frozen Swift→Bool answers"
                    + (mismatches.isEmpty ? "" : " (first: \(mismatches[0]))"))
    }

    /// Rewrites the frozen matrix from the current implementation. Only run when the predicate
    /// itself is deliberately changed; the normal checks read the file and must not move it.
    @MainActor static func captureAnnotationGeometryMatrix(root: URL) throws {
        let lines = annotationGeometryCases().map { "\($0.name)=\($0.annotation.hasValidGeometry)" }
        let text = lines.joined(separator: "\n") + "\n"
        let url = root.appendingPathComponent("tests/fixtures/annotation-geometry-matrix.txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        print("Captured \(lines.count) annotation geometry cases to \(url.path)")
    }
}
