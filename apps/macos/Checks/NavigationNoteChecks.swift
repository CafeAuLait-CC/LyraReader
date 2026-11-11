import Foundation
import LyraReaderKit

extension ReaderChecks {
    @MainActor static func navigationNoteChecks(root: URL) async throws {
        let engine = try RustEngine()
        let state = AppState(engine: engine)
        state.setViewportSize(CGSize(width: 900, height: 600))
        require(state.open(url: root.appendingPathComponent("tests/fixtures/navigation-notes.pdf")),
                "the synthetic navigation and note fixture opens")
        let links = try await engine.links(0)
        require(links.count == 2 && links.allSatisfy(\.navigation),
                "contents links carry the direct navigation policy from Rust")
        for link in links {
            state.gotoPage(0)
            let page = state.canvasPageFrames.first!
            let point = CGPoint(x: page.leftPt + link.xPt + link.widthPt / 2,
                                y: page.topPt + link.yPt + link.heightPt / 2)
            try await eventually("the contents link becomes clickable", { state.link(at: point) != nil })
            require(state.followLink(at: point), "the contents page number follows its destination")
            require(state.currentPage - 1 == link.page && state.referencePreview == nil,
                    "a contents click navigates without opening a page preview")
            require(state.goBack() && state.currentPage == 1, "Back returns to the contents page")
        }
        state.gotoPage(1)
        try await eventually("the document annotations load", { state.documentAnnotations.count == 4 })
        try await eventually("the clipped standalone note reaches the canvas", {
            state.canvasPages.contains { $0.placement.index == PlacementIndex.documentNote(3) }
        })
        let reply = state.documentAnnotations.first { $0.contents == "Reply in the discussion" }!
        require(reply.isReply && reply.parentID != nil && state.documentNotes.contains { $0.id == reply.id },
                "the off-page reply remains available in its review discussion")
        require(!state.canvasPages.contains { [PlacementIndex.documentNote(1), PlacementIndex.documentNote(2)]
            .contains($0.placement.index) }, "reply placeholders and off-page notes draw no page-gap icons")
        let note = state.canvasPages.first { $0.placement.index == PlacementIndex.documentNote(3) }!
        let page = state.canvasPageFrames.first { $0.index == 1 }!
        require(note.placement.leftPt >= page.leftPt
                && note.placement.leftPt + note.placement.widthPt <= page.leftPt + page.widthPt,
                "a partially off-page note is clipped to its own paper")
        require(note.source.width < 0.5, "clipping crops the glyph instead of squeezing its complete image")
        print("PASS: contents links navigate directly and off-page review replies leave no stray icons")
    }
}
