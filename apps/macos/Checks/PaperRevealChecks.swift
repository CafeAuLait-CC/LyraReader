import AppKit
import Foundation
@testable import LyraReaderKit

extension ReaderChecks {
    @MainActor static func paperRevealChecks(root: URL) async throws {
        let oldMotion = ReaderMotion.reduceMotionOverride
        ReaderMotion.reduceMotionOverride = true
        defer { ReaderMotion.reduceMotionOverride = oldMotion }
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 900, height: 700))
        require(state.open(url: root.appendingPathComponent("tests/fixtures/text-page.pdf")),
                "paper motion fixture opens")
        await state.createRegionCard(page: 0, rect: CGRect(x: 60, y: 60, width: 300, height: 140))
        guard let card = state.regionCards.first else { fatalError("Missing paper motion card") }
        let canvas = MetalCanvasView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        canvas.configureRegionCards(state: state)
        canvas.modelCommitSnapshot = { CanvasModelCommit(state: state) }
        state.attachedCanvas = canvas
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; state.cancelRegionPaperMotions() }
        try await eventually("paper motion canvas is attached", { canvas.hasAttachedSurface })

        let fullGap = state.regionGapHeightPt(card)
        let rebuilds = state.viewportReloadCount
        let requests = state.tileRequestCount
        let rasters = state.tileRasterCount
        state.setRegionPaperProgress(card.id, 0.25)
        let quarter = state.pageSegments(forPage: 0)
        require(abs(state.regionGapHeightPt(card) - fullGap * 0.25) < 0.01,
                "quarter-open paper reserves exactly a quarter of its gap")
        require(abs((canvas.regionCardFrames.first?.height ?? 0) - card.heightViewPt * 0.25) < 0.5,
                "the native paper clip follows the same intermediate progress")
        state.setRegionPaperProgress(card.id, 0.75)
        let threeQuarters = state.pageSegments(forPage: 0)
        require(quarter.count == 2 && threeQuarters.count == 2
                && abs(threeQuarters[1].topPt - quarter[1].topPt - fullGap * 0.5) < 0.1,
                "the lower paper segment follows the opening gap without scaling its pixels")
        require(state.viewportReloadCount == rebuilds && state.tileRequestCount == requests
                && state.tileRasterCount == rasters,
                "animation steps reuse the page pixels without planning or raster work")
        state.setRegionPaperProgress(card.id, 1)
        require(PaperRevealCurve.value(-1) == 0 && PaperRevealCurve.value(0.5) == 0.5
                && PaperRevealCurve.value(2) == 1, "paper easing is bounded with a stable midpoint")
        require(ReaderMotion.paperAnimation == nil && !state.beginRegionPaperReveal(UUID()),
                "Reduce Motion skips both paper transitions and animation tasks")
        ReaderMotion.reduceMotionOverride = false
        state.closeRegionCard(id: card.id, keepHistory: true)
        require(state.closingRegionPapers.contains(card.id), "a visible paper closes through its animation lifecycle")
        try await eventually("the closed paper releases its card and animation task", {
            state.regionCards.isEmpty && state.regionPaperMotionTasks.isEmpty
        })
        require(state.pageSegments(forPage: 0).count == 1,
                "the completed close restores one continuous page")
    }
}
