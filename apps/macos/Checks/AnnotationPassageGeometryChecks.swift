import AppKit
@testable import LyraReaderKit

extension ReaderChecks {
    @MainActor static func annotationPassageGeometryChecks(root: URL) async throws {
        // PDF character order can contain the entire line-number gutter before the title.
        // An adopted mark's synthetic 0...0 range must never quote that first gutter character.
        let titleLines = ["A 🙂 multi-line title", "with visual demonstrations"]
        var chars: [TextChar] = []
        var source = ""
        func append(_ value: String, x: CGFloat, y: CGFloat) {
            var cursor = x
            for scalar in value.unicodeScalars {
                chars.append(TextChar(unicode: scalar.value, xPt: cursor, yPt: y, widthPt: 6, heightPt: 12))
                cursor += 6
            }
            chars.append(TextChar(unicode: 10, xPt: cursor, yPt: y, widthPt: 0, heightPt: 0))
            source += value + "\n"
        }
        for index in 0..<6 { append(String(format: "%03d", index), x: 10, y: 40 + CGFloat(index) * 18) }
        for (index, line) in titleLines.enumerated() { append(line, x: 60, y: 40 + CGFloat(index) * 18) }
        let bodyStart = chars.count
        append("A separate body sentence.", x: 60, y: 160)
        let page = TextPage(page: 0, chars: chars, text: source, hasUnicodeMapError: false)
        let quads = titleLines.enumerated().map { index, line in
            AppState.Annotation.StoredRect(x: 60, y: 40 + Double(index) * 18,
                width: Double(line.unicodeScalars.count) * 6, height: 12)
        }
        let adopted = AppState.Annotation(id: UUID(), page: 0, start: 0, end: 0,
            color: AppState.highlightPalette[0].color, note: "A title comment", createdAt: Date(),
            fileIdentity: "nm:title", fileQuads: quads)
        func excerpt(_ annotation: AppState.Annotation) -> [AnnotationPassage] {
            var maps = [0: AnnotationSentenceMap(page)]
            return AnnotationPassage.build(document: [], own: [annotation], pages: [0: page], maps: &maps)
        }
        let expected = titleLines.joined(separator: " ")
        let passages = excerpt(adopted)
        require(passages.count == 1 && passages[0].text == expected,
                "adopted multiline title quotes its PDF quads, excluding the line-number gutter")
        let styled = passages[0].attributed(appearance: .original)
        require(styled.runs.allSatisfy { $0.backgroundColor != nil },
                "the full Unicode title retains its highlight after geometry-to-text mapping")
        let restored = try JSONDecoder().decode(AppState.Annotation.self, from: JSONEncoder().encode(adopted))
        require(excerpt(restored).first?.text == expected,
                "existing saved annotations with 0...0 and file quads require no migration")
        var missing = adopted
        missing.fileQuads = [.init(x: 500, y: 500, width: 20, height: 12)]
        require(excerpt(missing).isEmpty, "unmapped file quads never fall back to an unrelated character")
        var moved = adopted
        moved.fileQuads = [.init(x: 60, y: 160, width: 180, height: 12)]
        require(excerpt(moved).first?.text.trimmingCharacters(in: .whitespacesAndNewlines) == "A separate body sentence.",
                "changed quad geometry resolves its new text")
        let own = AppState.Annotation(id: UUID(), page: 0, start: bodyStart, end: chars.count - 2,
            color: AppState.highlightPalette[0].color, note: "", createdAt: Date())
        require(excerpt(own).first?.text.trimmingCharacters(in: .whitespacesAndNewlines) == "A separate body sentence.",
                "new range-based annotations keep their existing sentence excerpts")

        let input = root.appendingPathComponent("pdf-samples/with_annotations/review_ashley_du_0904.pdf")
        guard FileManager.default.fileExists(atPath: input.path) else { return }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-title-excerpt-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent(input.lastPathComponent)
        try FileManager.default.copyItem(at: input, to: file)
        let original = try Data(contentsOf: file)
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 1000, height: 900))
        require(state.open(url: file), "the Ashley title-excerpt review copy opens")
        try await eventually("the Ashley annotations are loaded", { !state.documentAnnotations.isEmpty })
        await state.loadAnnotationPassages()
        let title = state.documentAnnotations.filter { $0.page == 0 && $0.hasInlineNote }.min {
            $0.boxes.map(\.yPt).min()! < $1.boxes.map(\.yPt).min()!
        }!
        func documentPassage() -> AnnotationPassage? {
            state.annotationPassages.first { $0.marks.contains { $0.source == .document(title.id) } }
        }
        try await eventually("the title has its extracted passage", { documentPassage() != nil })
        let originalTitle = documentPassage()!.text
        require(originalTitle.lowercased().contains("single-step 3d human motion generation")
                && originalTitle.lowercased().contains("via flow matching") && !originalTitle.contains("000 001"),
                "the actual three-line paper title is extracted before selection")
        require(state.selectDocumentAnnotation(title.id), "the actual title highlight becomes editable")
        let selected = state.annotations.first { $0.fileIdentity == title.id }!
        func selectedPassage(_ current: AppState) -> AnnotationPassage? {
            current.annotationPassages.first { $0.marks.contains { $0.source == .own(selected.id) } }
        }
        require(selectedPassage(state)?.text == originalTitle,
                "selecting the Ashley title preserves its text instead of quoting 000 through 053")
        state.clearSelection()
        require(selectedPassage(state)?.text == originalTitle, "deselection keeps the correct title excerpt")
        let reopened = AppState(engine: try RustEngine())
        reopened.setViewportSize(CGSize(width: 1000, height: 900))
        require(reopened.open(url: file), "the saved adopted-title review reopens")
        await reopened.loadAnnotationPassages()
        try await eventually("the reopened title has its extracted passage", { selectedPassage(reopened) != nil })
        require(selectedPassage(reopened)?.text == originalTitle,
                "reopening an existing adopted title repairs its sidebar text from the stored quads")
        let finalBytes = try Data(contentsOf: file)
        require(finalBytes == original, "excerpt repair leaves the source PDF unchanged")
        print("PASS: annotation excerpts retain actual highlighted text through adoption and reopening")
    }
}
