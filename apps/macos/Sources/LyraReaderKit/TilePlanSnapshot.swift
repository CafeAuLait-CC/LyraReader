import Foundation

/// What one viewport update asked the tile scheduler to do.
///
/// This is the observation point the tile-plan migration freezes: the suite
/// `TilePlanFixtureChecks` captures it from the shell's own code **before** the decision moves
/// to `lyra-reader-render`, stores the bytes under `tests/fixtures/tile-plan/`, and then requires
/// the Rust plan the shell consumes to reproduce exactly the same values. It is read-only
/// observation — the plan itself is what schedules, rasterizes and draws.
public struct TilePlanSnapshot: Equatable, Sendable {
    /// One page's band, in tile rows and columns.
    public struct Page: Equatable, Sendable {
        public let page: Int
        public let firstColumn: Int
        public let lastColumn: Int
        public let firstRow: Int
        public let lastRow: Int

        public init(page: Int, firstColumn: Int, lastColumn: Int,
                    firstRow: Int, lastRow: Int) {
            self.page = page
            self.firstColumn = firstColumn
            self.lastColumn = lastColumn
            self.firstRow = firstRow
            self.lastRow = lastRow
        }
    }

    /// One tile the update queued for rasterization, in submission order.
    public struct Tile: Equatable, Sendable {
        public let key: TileKey
        /// True when the tile lies outside the viewport (prefetch-ring work).
        public let prefetch: Bool

        public init(key: TileKey, prefetch: Bool) {
            self.key = key
            self.prefetch = prefetch
        }
    }

    /// The current pyramid level.
    public let lod: UInt8
    /// The chosen prefetch-ring distance, in viewport heights.
    public let ringVh: CGFloat
    /// Every page the band covers, in placement order.
    public let pages: [Page]
    /// The pinned set (band tiles plus drawer-retained columns), sorted for stable comparison.
    public let pinned: [TileKey]
    /// Tiles queued for rasterization, in submission order.
    public let scheduled: [Tile]

    public init(lod: UInt8, ringVh: CGFloat, pages: [Page], pinned: [TileKey], scheduled: [Tile]) {
        self.lod = lod
        self.ringVh = ringVh
        self.pages = pages
        self.pinned = pinned
        self.scheduled = scheduled
    }
}
