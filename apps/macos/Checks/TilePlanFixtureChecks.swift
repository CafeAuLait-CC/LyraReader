import Foundation
import LyraReaderKit

/// A deterministic engine for the tile-plan fixtures: ten 600×1200 pt pages, contiguous or
/// arranged as facing spreads, and tiles that are always exactly `tileSize × tileSize` pixels
/// so the cache's byte accounting is predictable.
///
/// It has no PDF and no text: the fixtures exercise the scheduler's decision, not rasterization.
@MainActor private final class TilePlanFixtureEngine: PreviewEngine {
    private(set) var tileRasters = 0
    var facing = false
    private let pageWidth: CGFloat = 600
    private let pageHeight: CGFloat = 1200

    override func openDocument(at url: URL) throws -> LoadedDocument {
        LoadedDocument(title: "tile-plan fixture", pageCount: 10, url: url,
                       firstPageSize: CGSize(width: pageWidth, height: pageHeight))
    }

    override func renderPage(_ page: Int, scale: CGFloat) async throws -> PageImage {
        PageImage(pixelWidth: 1, pixelHeight: 1,
                  pointSize: CGSize(width: pageWidth, height: pageHeight),
                  bgra: Data([255, 255, 255, 255]), generation: UInt64(700 + page))
    }

    override func rasterizeTile(page: Int, lod: UInt8, tileX: Int, tileY: Int,
                                tileSize: Int) async throws -> TileImage {
        tileRasters += 1
        return TileImage(page: page, lod: lod, tileX: tileX, tileY: tileY, sizePx: tileSize,
                         bgra: Data(repeating: 200, count: tileSize * tileSize * 4),
                         generation: UInt64(9000 + page * 100 + tileY * 10 + tileX))
    }

    private var rowHeight: CGFloat { pageHeight }

    override func contentHeightPt(gapPt _: CGFloat) -> CGFloat {
        facing ? 5 * rowHeight : 10 * pageHeight
    }

    override func contentWidthPt(gapPt _: CGFloat) -> CGFloat {
        facing ? 2 * pageWidth : pageWidth
    }

    override func visiblePages(scrollYPt: CGFloat, viewportHeightPt: CGFloat,
                               gapPt _: CGFloat, marginPt: CGFloat) -> [PagePlacement] {
        if facing {
            return (0..<5).flatMap { row -> [PagePlacement] in
                let top = CGFloat(row) * rowHeight
                guard top + rowHeight >= scrollYPt - marginPt,
                      top <= scrollYPt + viewportHeightPt + marginPt else { return [] }
                return [PagePlacement(index: row * 2, topPt: top, leftPt: 0,
                                      widthPt: pageWidth, heightPt: pageHeight),
                        PagePlacement(index: row * 2 + 1, topPt: top, leftPt: pageWidth,
                                      widthPt: pageWidth, heightPt: pageHeight)]
            }
        }
        return (0..<10).compactMap { page in
            let top = CGFloat(page) * pageHeight
            guard top + pageHeight >= scrollYPt - marginPt,
                  top <= scrollYPt + viewportHeightPt + marginPt else { return nil }
            return PagePlacement(index: page, topPt: top, leftPt: 0,
                                 widthPt: pageWidth, heightPt: pageHeight)
        }
    }

    override func pageIndex(atScrollYPt scrollYPt: CGFloat, gapPt _: CGFloat) -> Int {
        let row = min(9, max(0, Int(scrollYPt / pageHeight)))
        return facing ? row * 2 : row
    }

    override func pageTopPt(_ index: Int, gapPt _: CGFloat) -> CGFloat {
        return facing ? CGFloat(index / 2) * rowHeight : CGFloat(index) * pageHeight
    }
}

extension ReaderChecks {
    private static let tilePlanFixtureDirectory = "tests/fixtures/tile-plan"
    private static let tilePlanFixtureFile = "plans.json"

    /// The scripted viewport updates whose plans are frozen.
    private enum TilePlanScenario: String, CaseIterable {
        case normalScroll = "normal-scroll"
        case deepZoom400 = "deep-zoom-400"
        case zoomRoundTrip = "zoom-round-trip"
        case floatingPreview = "floating-preview"
        case facingSpread = "facing-spread"

        var facing: Bool { self == .facingSpread }
        var viewport: CGSize { self == .facingSpread ? CGSize(width: 1100, height: 700)
                                                     : CGSize(width: 900, height: 640) }
    }

    @MainActor static func captureTilePlanFixtures(root: URL) async throws {
        let object = try await tilePlanFixtureObject(url: root)
        let data = try fixtureBytes(object)
        let directory = root.appendingPathComponent(tilePlanFixtureDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(tilePlanFixtureFile), options: .atomic)
        print("Captured \(data.count) bytes of tile-plan fixtures")
    }

    /// The tile-plan equivalence check (audit C5).
    ///
    /// `tests/fixtures/tile-plan/plans.json` was captured from the shell's own scheduler before
    /// the decision moved to `lyra-reader-render`. It freezes, for every scripted viewport
    /// update: the LOD, the chosen prefetch ring, every page's band rows and columns, the pinned
    /// set and the raster submission order with each tile's prefetch flag. The check rebuilds
    /// the same scenarios through the current code and requires the bytes to match exactly; a
    /// re-capture must reproduce the frozen bytes.
    @MainActor static func tilePlanFixtureChecks(root: URL) async throws {
        let directory = root.appendingPathComponent(tilePlanFixtureDirectory)
        let golden = try Data(contentsOf: directory.appendingPathComponent(tilePlanFixtureFile))
        let actual = try fixtureBytes(try await tilePlanFixtureObject(url: root))
        require(actual == golden,
                "the tile plan matches its pre-change freeze"
                + (actual == golden ? "" : " (\(actual.count) vs \(golden.count) bytes)"))
        print("Tile-plan equivalence check passed")
    }

    private static func fixtureBytes(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        return data
    }

    @MainActor private static func tilePlanFixtureObject(url: URL) async throws -> [String: Any] {
        var scenarios: [[String: Any]] = []
        for scenario in TilePlanScenario.allCases {
            scenarios.append([
                "name": scenario.rawValue,
                "steps": try await tilePlanSteps(scenario: scenario, url: url),
            ])
        }
        return ["schema": 1, "scenarios": scenarios]
    }

    @MainActor private static func tilePlanSteps(scenario: TilePlanScenario,
                                                 url: URL) async throws -> [[String: Any]] {
        let engine = TilePlanFixtureEngine()
        engine.facing = scenario.facing
        // A cache large enough that no eviction can make the *set* of cached tiles depend on
        // the order two concurrent rasters finish in; the ring's byte decision still has real
        // cached bitmaps to read. The band target is a measurement override (the same knob as
        // `LYRA_READER_PREFETCH_BAND_MIB`) so the ladder is exercised at a fixed, small budget.
        let state = AppState(engine: engine, tileCacheBudgetBytes: 256 * 1024 * 1024,
                             preferFullPageRasters: false)
        state.prefetchBandBudgetOverrideBytes = 24 * 1024 * 1024
        state.setDeviceScale(2)
        state.setViewportSize(scenario.viewport)
        guard state.open(url: url) else {
            fatalError("FAIL: tile-plan fixture opens")
        }
        state.gotoPage(0)

        var steps: [(String, @MainActor (AppState) async throws -> Void)] = []
        switch scenario {
        case .normalScroll:
            steps = [
                ("start", { $0.reloadVisiblePages() }),
                ("scroll-down-374", { $0.scroll(byScreenPoints: 374) }),
                ("scroll-down-375", { $0.scroll(byScreenPoints: 375) }),
                ("scroll-down-600", { $0.scroll(byScreenPoints: 600) }),
                ("scroll-up-374", { $0.scroll(byScreenPoints: -374) }),
                ("jump-fraction-0.4", { $0.scroll(toFraction: 0.4) }),
            ]
        case .deepZoom400:
            steps = [
                ("zoom-400", {
                    $0.zoomPercent = 400
                    $0.reloadVisiblePages()
                }),
                ("scroll-down-374", { $0.scroll(byScreenPoints: 374) }),
                ("scroll-down-374-again", { $0.scroll(byScreenPoints: 374) }),
                ("scroll-up-374", { $0.scroll(byScreenPoints: -374) }),
            ]
        case .zoomRoundTrip:
            steps = [
                ("page-3", { $0.gotoPage(2) }),
                ("zoom-400", {
                    $0.zoomPercent = 400
                    $0.reloadVisiblePages()
                }),
                ("zoom-100", {
                    $0.zoomPercent = 100
                    $0.reloadVisiblePages()
                }),
                ("zoom-200", {
                    $0.zoomPercent = 200
                    $0.reloadVisiblePages()
                }),
                ("zoom-400-again", {
                    $0.zoomPercent = 400
                    $0.reloadVisiblePages()
                }),
            ]
        case .floatingPreview:
            steps = [
                ("open-reference-preview", { state in
                    _ = state.openReferencePreview(page: 2, title: "fixture", from: "fixture",
                                                   kind: .page)
                    try await Task.sleep(for: .milliseconds(150))
                }),
                ("scroll-down-374", { $0.scroll(byScreenPoints: 374) }),
                ("scroll-down-374-again", { $0.scroll(byScreenPoints: 374) }),
                ("scroll-up-748", { $0.scroll(byScreenPoints: -748) }),
            ]
        case .facingSpread:
            steps = [
                ("start", { $0.reloadVisiblePages() }),
                ("scroll-down-374", { $0.scroll(byScreenPoints: 374) }),
                ("scroll-down-600", { $0.scroll(byScreenPoints: 600) }),
                ("scroll-up-374", { $0.scroll(byScreenPoints: -374) }),
                ("zoom-70-centred", {
                    $0.zoomPercent = 70
                    $0.reloadVisiblePages()
                }),
                ("zoom-140", {
                    $0.zoomPercent = 140
                    $0.reloadVisiblePages()
                }),
            ]
        }

        var captured: [[String: Any]] = []
        for (label, action) in steps {
            await quiesceTileRasters(engine)
            try await action(state)
            guard let plan = state.lastTilePlan else {
                fatalError("FAIL: \(scenario.rawValue)/\(label) produced no tile plan")
            }
            captured.append(encodeTilePlan(plan, label: label))
        }
        state.closeReferencePreview()
        return captured
    }

    private static func encodeTilePlan(_ plan: TilePlanSnapshot, label: String) -> [String: Any] {
        [
            "label": label,
            "lod": Int(plan.lod),
            "ringVh": Double(plan.ringVh),
            "pages": plan.pages.map { page in
                [
                    "page": page.page,
                    "firstColumn": page.firstColumn,
                    "lastColumn": page.lastColumn,
                    "firstRow": page.firstRow,
                    "lastRow": page.lastRow,
                ]
            },
            "pinned": plan.pinned.map { key in
                ["page": key.page, "lod": Int(key.lod), "x": key.x, "y": key.y]
            },
            "scheduled": plan.scheduled.map { tile in
                [
                    "page": tile.key.page,
                    "lod": Int(tile.key.lod),
                    "x": tile.key.x,
                    "y": tile.key.y,
                    "prefetch": tile.prefetch,
                ]
            },
        ]
    }

    /// Waits until the fixture engine's tile rasters have been still for a while: the
    /// scheduler's queues are private, and "the cache has settled" is exactly "no new raster".
    @MainActor private static func quiesceTileRasters(_ engine: TilePlanFixtureEngine) async {
        var last = -1
        var quiet = 0
        for _ in 0..<400 {
            try? await Task.sleep(for: .milliseconds(20))
            if engine.tileRasters == last {
                quiet += 1
                if quiet >= 5 { return }
            } else {
                quiet = 0
                last = engine.tileRasters
            }
        }
        fatalError("TIMEOUT: the tile-plan fixture never settled")
    }
}
