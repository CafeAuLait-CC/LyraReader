import Foundation
import LyraReaderKit

extension ReaderChecks {
    /// The linked click path, including chapter labels, vector crops, equations, and a numeric
    /// citation longer than the old scanner limit. The PDF contains only synthetic content.
    @MainActor static func chapterPreviewChecks(root: URL) async throws {
        let engine = try RustEngine()
        let state = AppState(engine: engine)
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.open(url: root.appendingPathComponent("tests/fixtures/chapter-previews.pdf")),
                "the chapter preview fixture opens")
        let figures = try await engine.figures()
        func figure(_ kind: String, _ label: String) -> Figure {
            guard let found = figures.first(where: { $0.kind == kind && $0.label == label }) else {
                fatalError("Missing indexed \(kind) \(label)")
            }
            return found
        }
        let first = figure("Figure", "1.1")
        require(first.page == 1 && first.heightPt < 140,
                "the chapter figure excludes its running header and preceding paragraph")
        require(first.yPt <= 842 - 607.5 && first.yPt > 842 - 620,
                "the crop includes the complete nested transformed vector artwork")
        require(first.xPt + first.widthPt >= 450,
                "a short chapter caption still includes the right-hand panel")
        let appendix = figure("Figure", "A.4")
        require(appendix.page == 1 && appendix.heightPt < 180,
                "the appendix figure excludes its heading and neighboring paragraphs")
        require(appendix.xPt + appendix.widthPt >= 420,
                "a short appendix caption still includes both panels")
        let equation = figure("Equation", "A.38")
        require(equation.page == 2 && equation.heightPt > 25 && equation.heightPt < 50,
                "the equation crop includes both lines and excludes the neighboring equation")
        require(equation.yPt > 842 - 680 && equation.yPt + equation.heightPt < 842 - 620,
                "the equation crop excludes the introductory and following prose")

        let mentions = try await engine.captionMentions(page: 0)
        require(Set(mentions.map(\.label)) == Set(["1.1", "A.4", "A.38", "A.39"]),
                "chapter, appendix, and parenthesized equation mentions keep their full labels")
        let placement = engine.visiblePages(scrollYPt: 0, viewportHeightPt: 500,
                                             gapPt: state.pageGapPt, marginPt: 0).first!
        try await eventually("the fixture's source links load", {
            state.link(at: CGPoint(x: placement.leftPt + 120, y: placement.topPt + 112)) != nil
        })
        for mention in mentions {
            let point = CGPoint(x: placement.leftPt + mention.xPt + mention.widthPt - 2,
                                y: placement.topPt + mention.yPt + mention.heightPt / 2)
            require(state.followLink(at: point), "the internal link for \(mention.title) is followed")
            try await eventually("the first click opens the crop for \(mention.title)", {
                state.referencePreview?.title == mention.title && state.referencePreview?.kind == .figure
                    && !state.referencePreviewLoading && !state.referencePreviewPages.isEmpty
            })
            require((state.referencePreview?.region?.height ?? 1000) < 180,
                    "the linked \(mention.title) uses its local region rather than a full page")
            state.closeReferencePreview()
        }
        let citations = try await engine.citations(0)
        guard let group = citations.first(where: { $0.labels.count == 6 }) else {
            fatalError("The long numeric citation was not detected")
        }
        let point = CGPoint(x: placement.leftPt + group.xPt + group.widthPt - 3,
                            y: placement.topPt + group.yPt + group.heightPt / 2)
        require(state.followLink(at: point), "the last label in a long citation follows its PDF link")
        try await eventually("the long group opens all six entries as text", {
            state.referencePreview?.kind == .reference && state.referencePreview?.entries.count == 6
        })
        require(state.referencePreviewPages.isEmpty,
                "a long multi-citation leaves no reference-page screenshot behind")
        state.closeReferencePreview()
        print("PASS: chapter and appendix figures, numbered equations, and long citations resolve through linked clicks")
    }
}
