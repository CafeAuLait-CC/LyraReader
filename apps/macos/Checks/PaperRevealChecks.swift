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
        try await Task.sleep(for: .milliseconds(200))
        let originalHeight = card.heightViewPt
        let growthTarget = originalHeight + 64
        let beforeGrowthReloads = state.viewportReloadCount
        state.updateRegionCardHeight(cardID: card.id, viewHeight: growthTarget)
        var growthHeights: [CGFloat] = []
        var growthGapErrors: [CGFloat] = []
        var activeGrowthReloads: [Int] = []
        let retarget = growthTarget + 28
        let samplingMilliseconds: Int
        if let value = ProcessInfo.processInfo.environment["LYRA_READER_PAPER_SAMPLE_MS"] {
            guard let parsed = Int(value), (1...50).contains(parsed) else {
                fail("FAIL: LYRA_READER_PAPER_SAMPLE_MS must be between 1 and 50")
            }
            samplingMilliseconds = parsed
        } else { samplingMilliseconds = 8 }
        for sample in 0..<18 {
            try await Task.sleep(for: .milliseconds(samplingMilliseconds))
            let segments = canvas.annotationPageFrames.filter { $0.index == 0 }.sorted { $0.topPt < $1.topPt }
            let paperHeight = canvas.regionCardFrames.first?.height ?? 0
            growthHeights.append(paperHeight)
            if segments.count == 2 {
                growthGapErrors.append(abs((segments[1].topPt - segments[0].topPt - segments[0].heightPt) * canvas.zoom - paperHeight))
            }
            if sample == 2 {
                let beforeRetarget = card.heightViewPt
                require(state.regionHeightMotionTasks[card.id] != nil,
                        "the streamed line arrives during the active height motion")
                state.updateRegionCardHeight(cardID: card.id, viewHeight: retarget)
                require(abs(card.heightViewPt - beforeRetarget) < 0.5,
                        "a new streamed line retargets the active motion without jumping")
            }
            if state.regionHeightMotionTasks[card.id] != nil {
                activeGrowthReloads.append(state.viewportReloadCount - beforeGrowthReloads)
            }
        }
        require(Set(growthHeights.map { Int(($0 * 10).rounded()) }).count > 5
                    && growthHeights.first! < growthTarget - 1,
                "one content-height change produces intermediate paper heights instead of a line-sized jump")
        require(growthGapErrors.count == growthHeights.count && growthGapErrors.allSatisfy { $0 < 0.5 },
                "every growth sample gives the paper and split-page gap the same height")
        // On a busy runner these samples can outlast the motion. Its completion deliberately
        // refreshes the page band once; only active frames must have zero rebuilds.
        require(!activeGrowthReloads.isEmpty && activeGrowthReloads.allSatisfy { $0 == 0 },
                "growth frames reuse page pixels without rebuilding the visible band")
        require(state.viewportReloadCount - beforeGrowthReloads <= 1,
                "a completed growth motion releases at most one page-band rebuild")
        try await eventually("the shared height motion reaches its latest target", {
            state.regionHeightMotionTasks.isEmpty && abs(card.heightViewPt - retarget) < 0.5
        })
        ReaderMotion.reduceMotionOverride = true
        state.updateRegionCardHeight(cardID: card.id, viewHeight: originalHeight)
        require(abs(card.heightViewPt - originalHeight) < 0.5 && state.regionHeightMotionTasks.isEmpty,
                "Reduce Motion applies the target height immediately")
        ReaderMotion.reduceMotionOverride = false
        state.closeRegionCard(id: card.id, keepHistory: true)
        require(state.closingRegionPapers.contains(card.id), "a visible paper closes through its animation lifecycle")
        try await eventually("the closed paper releases its card and animation task", {
            state.regionCards.isEmpty && state.regionPaperMotionTasks.isEmpty && state.regionHeightMotionTasks.isEmpty
        })
        require(state.pageSegments(forPage: 0).count == 1,
                "the completed close restores one continuous page")
    }
}
