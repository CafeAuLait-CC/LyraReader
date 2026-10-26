//! The tile plan: what one viewport update wants, at which LOD, in which raster order.
//!
//! ADR 0007 keeps the **cache** in the shell: a cache lookup has to sit next to the draw call,
//! and a per-tile FFI query would put the boundary on the scrolling path. What is portable, and
//! what the shell used to decide in `AppState.reloadVisiblePages`, is the *plan*:
//!
//! * the visible band and the prefetch ring around it;
//! * the rows and columns of every visible page the band covers;
//! * which tiles are wanted (and therefore pinned against eviction);
//! * the order the raster tasks are submitted in.
//!
//! The shell asks for that decision with **one** call per viewport update
//! (`plan_tiles` in `lyra-reader-ffi`), then does the cache lookups, the page-raster choice,
//! the eviction and the rasterization itself. The numbers below are the ones measured in
//! ADR 0007; they live here because this module, not the shell, now chooses the ring.
//!
//! # What the plan keeps from the shell
//!
//! The page placements, the viewport rect, the current LOD, the resolved prefetch settings and
//! an inventory of what the cache already holds are **inputs**. So is the page-tear geometry:
//! a torn page's display block is presentation, and only the shell knows how its two segments
//! map back to page-local Y.

use std::collections::HashMap;

/// Longest prefetch ring, in viewport heights (ADR 0007 shipped 2.5 viewports of *ring* plus
/// the viewport itself).
pub const MAX_PREFETCH_RING_VH: f64 = 2.5;

/// Ring distance below which the band is not shortened further.
///
/// The floor is measured, not chosen: the bench's step scroll recorded the raster time the
/// viewport spent waiting for tiles at a 1.0-viewport ring (p95 0.00 ms, 9 misses over 120
/// steps) and at 0.5 (p95 8.1 ms, 141 misses, worst 120 ms). 0.75 was the shortest ring that
/// measured no worse than 1.0; the shell stored the same number in the same doc comment.
pub const MIN_PREFETCH_RING_VH: f64 = 0.75;

/// Rungs the ring is chosen from, longest first. Coarse on purpose: each rung is a whole row of
/// tiles at ordinary geometries, so a finer ladder buys bytes the band HUD cannot even show.
pub const PREFETCH_RING_LADDER: [f64; 6] = [
    MAX_PREFETCH_RING_VH,
    2.0,
    1.5,
    1.25,
    1.0,
    MIN_PREFETCH_RING_VH,
];

/// Floor of the band's byte target: a reader who shrinks the cache in Settings still gets a
/// band. The default 48 MiB cache gives a third of it (16 MiB), the measured operating point.
pub const PREFETCH_BAND_BUDGET_FLOOR_BYTES: u64 = 8 * 1024 * 1024;

/// Highest pyramid level the planner accepts. The shell builds at most four (`maxLod`); the
/// wider guard keeps the shift in the LOD scale in range for a future shell.
pub const MAX_LOD: u8 = 16;

/// The largest tile edge the planner accepts. A tile's pixels are `edge² × 4` bytes; the guard
/// keeps that product representable and stops a bad caller from constructing a huge `f64`.
pub const MAX_TILE_SIZE_PX: u32 = 32_768;

/// Upper bound on the per-update input lists. These are all shell-owned and bounded by a
/// document's visible band and the cache's own byte budget; the cap only rejects a corrupt or
/// hostile caller before it costs an allocation.
pub const MAX_INPUT_ITEMS: usize = 1 << 18;

/// What class of work a planned tile belongs to.
///
/// The vocabulary is the one the scheduler documents (`docs/03-rendering.md` §4), but this
/// planner emits only the first two: the shell schedules the target LOD's visible tiles and
/// its prefetch ring. Lower-LOD previews are drawn from the cache while a LOD change settles,
/// and thumbnails never go through the tile scheduler — both would be empty variants of the
/// plan, and inventing work for them here would change what the reader sees.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TilePriority {
    /// Intersects the viewport at the target LOD (first in raster order).
    Visible,
    /// The prefetch ring around the viewport, at the target LOD.
    TargetLodPrefetch,
    /// Reserved for a lower-LOD preview task; the shell does not schedule one today.
    OneLodLower,
    /// Reserved for a sidebar thumbnail task; the shell does not schedule one today.
    Thumbnail,
}

/// A rectangle in content points (top-left origin), matching the shell's `CGRect` use.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PlanRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl PlanRect {
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }

    pub fn min_x(self) -> f64 {
        self.x
    }

    pub fn min_y(self) -> f64 {
        self.y
    }

    pub fn max_x(self) -> f64 {
        self.x + self.width
    }

    pub fn max_y(self) -> f64 {
        self.y + self.height
    }

    /// `CGRect.intersects`: both rects must be non-empty and overlap with a positive area.
    ///
    /// `CGRect` treats a zero-width or zero-height rectangle as empty; so does this. The
    /// comparisons are strict, which is what makes an edge exactly on the viewport boundary
    /// "not visible" in the shell too.
    pub fn intersects(self, other: Self) -> bool {
        if self.width <= 0.0 || self.height <= 0.0 || other.width <= 0.0 || other.height <= 0.0 {
            return false;
        }
        self.min_x() < other.max_x()
            && other.min_x() < self.max_x()
            && self.min_y() < other.max_y()
            && other.min_y() < self.max_y()
    }
}

/// One page placement the shell is showing, plus the page-tear offsets its rows need.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PlanPage {
    pub page: u32,
    pub top_pt: f64,
    pub left_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
    /// The page's display top (region-card gaps applied). Only the torn branch of
    /// [`page_local_band`] reads it, exactly like the shell.
    pub display_top_pt: f64,
    /// Page-local Y of an inside-page tear, when one is open on this page.
    pub tear_split_pt: Option<f64>,
    /// Height of the tear's gap, in content points.
    pub tear_gap_pt: f64,
}

/// One cached tile, so the ring's byte estimate can use its real (often cropped) bitmap size.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CachedTile {
    pub page: u32,
    pub lod: u8,
    pub x: u32,
    pub y: u32,
    pub bytes: u64,
}

/// One tile quad the shell drew last update, for the drawer-retention rule.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PriorTile {
    pub page: u32,
    pub lod: u8,
    pub x: u32,
    pub y: u32,
    pub left_pt: f64,
}

/// Everything one viewport update needs to compute its plan.
#[derive(Clone, Debug, PartialEq)]
pub struct PlanRequest {
    /// The visible content rect: what the reader can actually see, in content points.
    pub viewport: PlanRect,
    /// `+1` when the reader is moving down, `-1` when moving up. Only its sign is read: the
    /// ring is asymmetric and points the way the reader scrolls.
    pub scroll_direction: f64,
    /// Viewer scale (`zoomPercent / 100 × calibration`). Only the drawer's covered-column
    /// arithmetic divides by it, exactly like the shell.
    pub zoom: f64,
    /// Tile edge at LOD 0, in device pixels (the shell's `tileSizePx`).
    pub tile_size_px: u32,
    /// The current tile-pyramid level (`2^lod` = raster scale).
    pub lod: u8,
    /// The live cache's byte budget, from which the band's byte target is derived.
    pub cache_budget_bytes: u64,
    /// `LYRA_READER_PREFETCH_BAND_MIB` when it is set (measurement override).
    pub band_budget_override_bytes: Option<u64>,
    /// `LYRA_READER_PREFETCH_RING_VH` when it is set: pins the ring instead of deriving it.
    pub ring_override_vh: Option<f64>,
    /// Columns kept ready beyond the ones on screen (`LYRA_READER_PREFETCH_COLUMNS`).
    pub prefetch_columns: u32,
    /// `LYRA_READER_PREFETCH_ALL_COLUMNS=1`: the pre-change "every column" measurement mode.
    pub want_all_columns: bool,
    /// Width of the open right drawer, in screen points (0 when no drawer is open).
    pub drawer_width_pt: f64,
    /// Whether the drawer is still animating: while it moves, every already-sharp column the
    /// drawer will cover is retained, not only the ones inside the settled width.
    pub right_panel_layout_moving: bool,
    /// The page placements the shell is showing, in reading order.
    pub pages: Vec<PlanPage>,
    /// What the cache holds right now.
    pub cached_tiles: Vec<CachedTile>,
    /// The tile quads the shell drew last update, in drawing order.
    pub prior_tiles: Vec<PriorTile>,
}

/// One page's band, in tile rows and columns.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PlannedPage {
    pub page: u32,
    pub first_column: u32,
    pub last_column: u32,
    pub first_row: u32,
    pub last_row: u32,
}

/// One tile to rasterize, in submission order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PlannedTile {
    pub page: u32,
    pub lod: u8,
    pub x: u32,
    pub y: u32,
    pub priority: TilePriority,
    /// True when the tile is outside the viewport (ring work). Retained drawer columns are
    /// pinned but never scheduled, so they do not appear in the tile list.
    pub prefetch: bool,
}

/// A tile identity without the payload.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct PlannedKey {
    pub page: u32,
    pub lod: u8,
    pub x: u32,
    pub y: u32,
}

/// The batch plan for one viewport update.
#[derive(Clone, Debug, PartialEq)]
pub struct TilePlan {
    /// The LOD the plan was computed for (echoed so the caller cannot pair it with another).
    pub lod: u8,
    /// The chosen ring distance, in viewport heights (the band HUD reports it).
    pub ring_vh: f64,
    /// Every page the band covers, in placement order.
    pub pages: Vec<PlannedPage>,
    /// Every tile of the band, in raster submission order (visible first, then nearest ring).
    pub tiles: Vec<PlannedTile>,
    /// The pinned set: every band tile plus the drawer-retained columns.
    pub pinned: Vec<PlannedKey>,
    /// Prior tile quads kept because an open drawer covers them. Pinned, not scheduled.
    pub retained: Vec<PlannedKey>,
}

/// A band span together with the input page it came from.
#[derive(Clone, Copy)]
struct Span {
    slot: usize,
    page: PlannedPage,
}

/// Computes the plan for one viewport update.
///
/// Returns `None` when the request violates an invariant the shell cannot produce (non-finite
/// geometry, a zero tile edge, an out-of-range LOD, oversized input lists). The shell reports
/// that rather than drawing a fabricated plan: a silent fallback would change what the reader
/// sees on a bug that should be visible.
pub fn plan_tiles(request: &PlanRequest) -> Option<TilePlan> {
    validate(request)?;

    let scale = (1u64 << request.lod) as f64;
    let tile_pt = request.tile_size_px as f64 / scale;
    let full_tile_bytes = (request.tile_size_px as u64)
        .checked_mul(request.tile_size_px as u64)?
        .checked_mul(4)?;

    let cached: HashMap<PlannedKey, u64> = request
        .cached_tiles
        .iter()
        .map(|tile| {
            (
                PlannedKey {
                    page: tile.page,
                    lod: tile.lod,
                    x: tile.x,
                    y: tile.y,
                },
                tile.bytes,
            )
        })
        .collect();

    let ring_vh = choose_ring(request, tile_pt, full_tile_bytes, &cached);
    let spans = band_spans(request, ring_vh, tile_pt);

    let drawer_active = request.drawer_width_pt > 0.0 || request.right_panel_layout_moving;
    let covered_right = request.viewport.max_x()
        + request.drawer_width_pt / request.zoom.max(0.01)
        + (request.prefetch_columns as f64 + 1.0) * tile_pt;

    let mut retained = Vec::new();
    if drawer_active {
        for span in &spans {
            let page = &request.pages[span.slot];
            for prior in &request.prior_tiles {
                if prior.page != page.page
                    || prior.lod != request.lod
                    || prior.y < span.page.first_row
                    || prior.y > span.page.last_row
                    || prior.x <= span.page.last_column
                    || !(request.right_panel_layout_moving || prior.left_pt < covered_right)
                {
                    continue;
                }
                let key = PlannedKey {
                    page: prior.page,
                    lod: prior.lod,
                    x: prior.x,
                    y: prior.y,
                };
                if !retained.contains(&key) {
                    retained.push(key);
                }
            }
        }
    }

    let mut sortable: Vec<(f64, PlannedTile)> = Vec::new();
    let mut pinned: Vec<PlannedKey> = Vec::new();
    for span in &spans {
        let page = &request.pages[span.slot];
        for row in span.page.first_row..=span.page.last_row {
            for column in span.page.first_column..=span.page.last_column {
                let key = PlannedKey {
                    page: page.page,
                    lod: request.lod,
                    x: column,
                    y: row,
                };
                let rect = tile_rect(page, column, row, tile_pt);
                let visible = rect.intersects(request.viewport);
                pinned.push(key);
                sortable.push((
                    distance(request, rect),
                    PlannedTile {
                        page: key.page,
                        lod: key.lod,
                        x: key.x,
                        y: key.y,
                        priority: if visible {
                            TilePriority::Visible
                        } else {
                            TilePriority::TargetLodPrefetch
                        },
                        prefetch: !visible,
                    },
                ));
            }
        }
    }

    // Same order the shell used: visible tiles first, then the ring by distance from the
    // viewport; equal distances keep the band's (page, row, column) insertion order, which is
    // why the sort is stable.
    sortable.sort_by(|a, b| a.1.prefetch.cmp(&b.1.prefetch).then(a.0.total_cmp(&b.0)));
    let tiles = sortable.into_iter().map(|(_, tile)| tile).collect();

    for key in &retained {
        pinned.push(*key);
    }

    Some(TilePlan {
        lod: request.lod,
        ring_vh,
        pages: spans.iter().map(|span| span.page).collect(),
        tiles,
        pinned,
        retained,
    })
}

/// The band's byte target: a third of the cache budget, with the measured 8 MiB floor.
pub fn prefetch_band_budget_bytes(cache_budget_bytes: u64) -> u64 {
    (cache_budget_bytes / 3).max(PREFETCH_BAND_BUDGET_FLOOR_BYTES)
}

/// The page-local Y band a content-space band covers, clipped to the displayed paper.
///
/// This is the shell's `pageLocalBand`: for an untorn page it is the band shifted by the
/// placement top and clipped to the page; for a torn page the two display segments are
/// disjoint in content space, so the band is the union of what each contributes, mapped back
/// to page-local Y before tile rows are named.
pub fn page_local_band(page: &PlanPage, top: f64, bottom: f64) -> Option<(f64, f64)> {
    let height = page.height_pt;
    if !height.is_finite()
        || height <= 1.0
        || !bottom.is_finite()
        || !top.is_finite()
        || bottom <= top
    {
        return None;
    }
    let torn = page
        .tear_split_pt
        .filter(|split| split.is_finite() && page.tear_gap_pt > 0.01);
    let Some(split_pt) = torn else {
        let low = (top - page.top_pt).max(0.0);
        let high = (bottom - page.top_pt).min(height);
        return (high > low).then_some((low, high));
    };

    let page_top = page.display_top_pt;
    let split = split_pt.max(0.01).min(height - 0.01);
    let top_segment = (page_top, page_top + split);
    let bottom_start = page_top + split + page.tear_gap_pt;
    let bottom_segment = (bottom_start, page_top + height + page.tear_gap_pt);

    let mut locals: Vec<f64> = Vec::with_capacity(4);
    let top_low = top.max(top_segment.0);
    let top_high = bottom.min(top_segment.1);
    if top_low < top_high {
        locals.push(top_low - page_top);
        locals.push(top_high - page_top);
    }
    let bottom_low = top.max(bottom_segment.0);
    let bottom_high = bottom.min(bottom_segment.1);
    if bottom_low < bottom_high {
        locals.push(bottom_low - bottom_start + split);
        locals.push(bottom_high - bottom_start + split);
    }

    let low = locals.iter().copied().reduce(f64::min)?;
    let high = locals.iter().copied().reduce(f64::max)?;
    (high > low).then_some((low.max(0.0), high.min(height)))
}

/// The ring above and below the viewport, as distances from the viewport's top edge.
///
/// The split is asymmetric on purpose — most of the ring points the way the reader is scrolling
/// — and the shape ADR 0007 shipped (0.5 above / 2.0 below going down) is kept as the *ratio*
/// for every shorter ring, so shortening the band never changes which side it favours.
pub fn ring_split(ring_vh: f64, scroll_direction: f64) -> (f64, f64) {
    if scroll_direction < 0.0 {
        (
            ring_vh * 2.0 / MAX_PREFETCH_RING_VH,
            1.0 + ring_vh * 0.5 / MAX_PREFETCH_RING_VH,
        )
    } else {
        (
            ring_vh * 0.5 / MAX_PREFETCH_RING_VH,
            1.0 + ring_vh * 2.0 / MAX_PREFETCH_RING_VH,
        )
    }
}

/// One page's covered rows and columns, or `None` when the band misses the page.
fn band_span(
    request: &PlanRequest,
    slot: usize,
    page: &PlanPage,
    ring_vh: f64,
    tile_pt: f64,
) -> Option<Span> {
    let (above, below) = ring_split(ring_vh, request.scroll_direction);
    let top = request.viewport.min_y() - request.viewport.height * above;
    let bottom = request.viewport.min_y() + request.viewport.height * below;

    let rows = (page.height_pt / tile_pt).ceil() as i64;
    let (low, high) = page_local_band(page, top, bottom)?;
    let first_row = (low / tile_pt).floor().max(0.0) as i64;
    let last_row = (((high - 0.001) / tile_pt).floor() as i64).min(rows - 1);
    if first_row > last_row {
        return None;
    }

    let columns = (page.width_pt / tile_pt).ceil() as i64;
    let mut first_column = 0;
    let mut last_column = columns - 1;
    if !request.want_all_columns {
        let visible_first = ((request.viewport.min_x() - page.left_pt) / tile_pt).floor() as i64;
        first_column = visible_first.max(0).min(columns - 1);
        let visible_last = ((request.viewport.max_x() - page.left_pt) / tile_pt).floor() as i64
            + request.prefetch_columns as i64;
        last_column = visible_last.max(first_column).min(columns - 1);
    }

    Some(Span {
        slot,
        page: PlannedPage {
            page: page.page,
            first_column: first_column as u32,
            last_column: last_column as u32,
            first_row: first_row as u32,
            last_row: last_row as u32,
        },
    })
}

fn band_spans(request: &PlanRequest, ring_vh: f64, tile_pt: f64) -> Vec<Span> {
    request
        .pages
        .iter()
        .enumerate()
        .filter_map(|(slot, page)| band_span(request, slot, page, ring_vh, tile_pt))
        .collect()
}

fn choose_ring(
    request: &PlanRequest,
    tile_pt: f64,
    full_tile_bytes: u64,
    cached: &HashMap<PlannedKey, u64>,
) -> f64 {
    if let Some(override_vh) = request.ring_override_vh {
        return override_vh.min(MAX_PREFETCH_RING_VH);
    }
    let budget = request
        .band_budget_override_bytes
        .unwrap_or_else(|| prefetch_band_budget_bytes(request.cache_budget_bytes));
    for rung in PREFETCH_RING_LADDER {
        let mut bytes = 0u64;
        for span in band_spans(request, rung, tile_pt) {
            for row in span.page.first_row..=span.page.last_row {
                for column in span.page.first_column..=span.page.last_column {
                    let key = PlannedKey {
                        page: span.page.page,
                        lod: request.lod,
                        x: column,
                        y: row,
                    };
                    bytes =
                        bytes.saturating_add(cached.get(&key).copied().unwrap_or(full_tile_bytes));
                }
            }
        }
        if bytes <= budget {
            return rung;
        }
    }
    PREFETCH_RING_LADDER[PREFETCH_RING_LADDER.len() - 1]
}

fn tile_rect(page: &PlanPage, column: u32, row: u32, tile_pt: f64) -> PlanRect {
    PlanRect::new(
        page.left_pt + column as f64 * tile_pt,
        page.top_pt + row as f64 * tile_pt,
        tile_pt.min(page.width_pt - column as f64 * tile_pt),
        tile_pt.min(page.height_pt - row as f64 * tile_pt),
    )
}

fn distance(request: &PlanRequest, rect: PlanRect) -> f64 {
    let viewport = request.viewport;
    (viewport.min_y() - rect.min_y() - rect.height)
        .max(rect.min_y() - viewport.min_y() - viewport.height)
        .max(0.0)
}

fn validate(request: &PlanRequest) -> Option<()> {
    let viewport = request.viewport;
    if !viewport.x.is_finite()
        || !viewport.y.is_finite()
        || !viewport.width.is_finite()
        || !viewport.height.is_finite()
        || viewport.width <= 0.0
        || viewport.height <= 0.0
    {
        return None;
    }
    if !request.scroll_direction.is_finite() || !request.zoom.is_finite() {
        return None;
    }
    if request.tile_size_px == 0 || request.tile_size_px > MAX_TILE_SIZE_PX || request.lod > MAX_LOD
    {
        return None;
    }
    if request
        .ring_override_vh
        .is_some_and(|ring| !ring.is_finite() || ring < 0.0)
    {
        return None;
    }
    if request.pages.len() > MAX_INPUT_ITEMS
        || request.cached_tiles.len() > MAX_INPUT_ITEMS
        || request.prior_tiles.len() > MAX_INPUT_ITEMS
    {
        return None;
    }
    for page in &request.pages {
        if !page.top_pt.is_finite()
            || !page.left_pt.is_finite()
            || !page.display_top_pt.is_finite()
            || !page.tear_gap_pt.is_finite()
            || page.tear_gap_pt < 0.0
            || !page.width_pt.is_finite()
            || !page.height_pt.is_finite()
            || page.width_pt <= 0.0
            || page.height_pt <= 0.0
        {
            return None;
        }
        if page.tear_split_pt.is_some_and(|split| !split.is_finite()) {
            return None;
        }
    }
    if request
        .prior_tiles
        .iter()
        .any(|tile| !tile.left_pt.is_finite())
    {
        return None;
    }
    Some(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn page(index: u32) -> PlanPage {
        PlanPage {
            page: index,
            top_pt: index as f64 * 1200.0,
            left_pt: 0.0,
            width_pt: 600.0,
            height_pt: 1200.0,
            display_top_pt: index as f64 * 1200.0,
            tear_split_pt: None,
            tear_gap_pt: 0.0,
        }
    }

    fn request(pages: Vec<PlanPage>) -> PlanRequest {
        PlanRequest {
            viewport: PlanRect::new(0.0, 0.0, 700.0, 500.0),
            scroll_direction: 1.0,
            zoom: 1.0,
            tile_size_px: 512,
            lod: 1,
            cache_budget_bytes: 48 * 1024 * 1024,
            band_budget_override_bytes: None,
            ring_override_vh: None,
            prefetch_columns: 0,
            want_all_columns: false,
            drawer_width_pt: 0.0,
            right_panel_layout_moving: false,
            pages,
            cached_tiles: Vec::new(),
            prior_tiles: Vec::new(),
        }
    }

    fn keys(plan: &TilePlan) -> Vec<(u32, u8, u32, u32)> {
        plan.tiles
            .iter()
            .map(|tile| (tile.page, tile.lod, tile.x, tile.y))
            .collect()
    }

    #[test]
    fn band_contains_every_visible_tile() {
        let request = request(vec![page(0), page(1), page(2)]);
        let plan = plan_tiles(&request).expect("valid plan");
        let tile_pt = 512.0 / 2.0;
        let mut visible = 0;
        for planned in &plan.pages {
            let page = &request.pages[planned.page as usize];
            for row in planned.first_row..=planned.last_row {
                for column in planned.first_column..=planned.last_column {
                    let rect = tile_rect(page, column, row, tile_pt);
                    if !rect.intersects(request.viewport) {
                        continue;
                    }
                    visible += 1;
                    let key = PlannedKey {
                        page: planned.page,
                        lod: request.lod,
                        x: column,
                        y: row,
                    };
                    assert!(
                        plan.pinned.contains(&key),
                        "visible tile {key:?} is not pinned"
                    );
                    assert!(plan.tiles.iter().any(|tile| {
                        tile.page == key.page
                            && tile.x == key.x
                            && tile.y == key.y
                            && tile.priority == TilePriority::Visible
                    }));
                }
            }
        }
        assert!(visible > 0, "fixture must have a visible tile");
        assert!(!plan.tiles[0].prefetch, "visible tiles come first");
    }

    #[test]
    fn ring_ladder_shortens_when_the_band_does_not_fit() {
        let pages = vec![page(0), page(1), page(2)];
        let mut request = request(pages);
        // No cached tiles: each band tile costs 512×512×4 bytes.
        let mut generous = request.clone();
        generous.band_budget_override_bytes = Some(1024 * 1024 * 1024);
        assert_eq!(
            plan_tiles(&generous).expect("generous").ring_vh,
            MAX_PREFETCH_RING_VH
        );

        // One viewport-height ring at LOD 1 is already ~7 MiB; 2 MiB cannot hold it.
        let mut tight = request.clone();
        tight.band_budget_override_bytes = Some(2 * 1024 * 1024);
        let plan = plan_tiles(&tight).expect("tight");
        assert!(plan.ring_vh < MAX_PREFETCH_RING_VH);
        assert!(plan.ring_vh >= MIN_PREFETCH_RING_VH);

        // The ring override wins over the byte budget.
        request.ring_override_vh = Some(1.25);
        assert_eq!(plan_tiles(&request).expect("override").ring_vh, 1.25);
    }

    #[test]
    fn cached_edge_tiles_use_their_real_bytes() {
        // A band whose full-tile estimate is over the budget but whose cached tiles are tiny
        // must keep a longer ring: the estimate is the cached bitmap, not a full tile.
        let mut request = request(vec![page(0)]);
        request.lod = 0;
        request.viewport = PlanRect::new(0.0, 0.0, 600.0, 1200.0);
        request.band_budget_override_bytes = Some(5 * 1024 * 1024);
        let uncached = plan_tiles(&request).expect("uncached");
        request.cached_tiles = vec![CachedTile {
            page: 0,
            lod: 0,
            x: 0,
            y: 0,
            bytes: 4,
        }];
        let cached = plan_tiles(&request).expect("cached");
        assert!(cached.ring_vh >= uncached.ring_vh);
    }

    #[test]
    fn columns_stop_at_reachable_columns() {
        let mut request = request(vec![page(0)]);
        request.lod = 3; // 64 pt tiles → 10 columns, viewport 700 pt wide
        request.viewport = PlanRect::new(0.0, 0.0, 200.0, 500.0);
        let plan = plan_tiles(&request).expect("plan");
        let span = plan.pages[0];
        assert!(span.last_column <= 4, "wanted columns {:?}", span);
        assert_eq!(span.first_column, 0);

        request.want_all_columns = true;
        let plan = plan_tiles(&request).expect("all columns");
        assert_eq!(plan.pages[0].last_column, 9);
    }

    #[test]
    fn ordering_puts_visible_tiles_first_then_nearest_ring() {
        let mut request = request(vec![page(0)]);
        request.lod = 0;
        request.viewport = PlanRect::new(0.0, 500.0, 600.0, 200.0);
        request.band_budget_override_bytes = Some(u64::MAX);
        let plan = plan_tiles(&request).expect("plan");
        let ordered = keys(&plan);
        let first_prefetch = plan
            .tiles
            .iter()
            .position(|tile| tile.prefetch)
            .expect("a ring tile");
        assert!(
            plan.tiles[..first_prefetch]
                .iter()
                .all(|tile| !tile.prefetch)
        );
        assert!(
            plan.tiles[first_prefetch..]
                .iter()
                .all(|tile| tile.prefetch)
        );
        // The nearest ring row is the one directly above or below the visible rows.
        let ring_keys = &ordered[first_prefetch..];
        assert!(
            ring_keys[0].3 == 2 || ring_keys[0].3 == 4,
            "nearest ring row first: {ring_keys:?}"
        );
    }

    #[test]
    fn drawer_retention_pins_the_covered_column() {
        let mut request = request(vec![page(0)]);
        request.lod = 3;
        request.viewport = PlanRect::new(0.0, 0.0, 200.0, 500.0);
        request.drawer_width_pt = 300.0;
        request.prior_tiles = (0..10)
            .map(|x| PriorTile {
                page: 0,
                lod: 3,
                x,
                y: 0,
                left_pt: x as f64 * 64.0,
            })
            .collect();
        let plan = plan_tiles(&request).expect("plan");
        // Columns beyond the band's last column and left of the covered edge are retained.
        let retained: Vec<u32> = plan.retained.iter().map(|key| key.x).collect();
        assert!(!retained.is_empty(), "a covered column is retained");
        for x in &retained {
            assert!(*x > plan.pages[0].last_column);
            assert!(plan.pinned.iter().any(|key| key.x == *x && key.y == 0));
        }
        assert!(
            plan.tiles
                .iter()
                .all(|tile| tile.x <= plan.pages[0].last_column),
            "retained columns are pinned, not scheduled"
        );
    }

    #[test]
    fn page_tear_maps_the_band_back_to_page_rows() {
        let mut torn = page(0);
        torn.tear_split_pt = Some(400.0);
        torn.tear_gap_pt = 200.0;
        torn.display_top_pt = 0.0;
        // The bottom segment starts 200 pt below the paper's nominal top; a band inside that
        // segment must name page-local rows around y = 400, not y = 600.
        let band = page_local_band(&torn, 600.0, 800.0).expect("band");
        assert_eq!(band, (400.0, 600.0));

        // A band in the gap itself names nothing.
        assert_eq!(page_local_band(&torn, 400.0, 600.0), None);
    }

    #[test]
    fn invalid_geometry_is_rejected() {
        let mut nan_viewport = request(vec![page(0)]);
        nan_viewport.viewport.width = f64::NAN;
        assert_eq!(plan_tiles(&nan_viewport), None);

        let mut zero_tile = request(vec![page(0)]);
        zero_tile.tile_size_px = 0;
        assert_eq!(plan_tiles(&zero_tile), None);

        let mut lod_out_of_range = request(vec![page(0)]);
        lod_out_of_range.lod = 17;
        assert_eq!(plan_tiles(&lod_out_of_range), None);
    }

    #[test]
    fn upward_scroll_flips_the_ring() {
        let mut request = request(vec![page(0), page(1)]);
        request.scroll_direction = 1.0;
        let down = plan_tiles(&request).expect("down");
        request.scroll_direction = -1.0;
        let up = plan_tiles(&request).expect("up");
        assert_ne!(keys(&down), keys(&up));
    }
}
