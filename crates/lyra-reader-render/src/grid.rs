//! Shared bounded grid enumeration, with explicit legacy and half-open boundaries.
//! Cache residency, job ownership and GPU uploads remain in the platform shell.
use crate::plan::PlanRect;
use std::fmt;

pub const MIN_DENSITY_TIER: i32 = -24;
pub const MAX_DENSITY_TIER: i32 = 28;
pub const MAX_PAGE_TILES: usize = 96;
pub const MAX_BATCH_PAGES: usize = 128;
pub(crate) const MAX_GRID_COORDINATE: f64 = 2_147_483_645.0;
pub(crate) const MAX_LEGACY_TILES: usize = 1 << 18;

#[derive(Clone, Copy)]
pub(crate) enum UpperEdge {
    HalfOpen,
    Inclusive,
    Inset(f64),
}
#[derive(Clone, Copy)]
pub(crate) struct AxisSpan {
    pub first: u32,
    pub last: u32,
}

/// `clamp_outside` preserves the legacy drawer's nearest-column behaviour. A
/// half-open viewport instead rejects a band that never intersects the paper.
pub(crate) fn axis_span(
    start: f64,
    end: f64,
    extent: f64,
    edge: f64,
    upper: UpperEdge,
    clamp_outside: bool,
    extra: u32,
) -> Option<AxisSpan> {
    if ![start, end, extent, edge].iter().all(|v| v.is_finite())
        || extent <= 0.0
        || edge <= 0.0
        || end <= start
    {
        return None;
    }
    let cells = (extent / edge).ceil();
    if !cells.is_finite() || !(1.0..=MAX_GRID_COORDINATE).contains(&cells) {
        return None;
    }
    if !clamp_outside && (start >= extent || end <= 0.0) {
        return None;
    }
    let mut first = (start / edge).floor().max(0.0);
    if clamp_outside {
        first = first.min(cells - 1.0);
    }
    let mut last = match upper {
        UpperEdge::HalfOpen => (end / edge).ceil() - 1.0,
        UpperEdge::Inclusive => (end / edge).floor() + f64::from(extra),
        UpperEdge::Inset(inset) => ((end - inset) / edge).floor(),
    };
    if clamp_outside {
        last = last.max(first);
    }
    last = last.min(cells - 1.0);
    if !first.is_finite()
        || !last.is_finite()
        || first > last
        || first > MAX_GRID_COORDINATE
        || last < 0.0
    {
        return None;
    }
    // Both values are finite, integral, non-negative and within the coordinate cap.
    Some(AxisSpan {
        first: first as u32,
        last: last as u32,
    })
}
pub(crate) fn coordinates(x: AxisSpan, y: AxisSpan) -> impl Iterator<Item = (u32, u32)> {
    (y.first..=y.last).flat_map(move |row| (x.first..=x.last).map(move |column| (column, row)))
}
pub(crate) fn count(x: AxisSpan, y: AxisSpan) -> Option<usize> {
    let columns = u64::from(x.last)
        .checked_sub(u64::from(x.first))?
        .checked_add(1)?;
    let rows = u64::from(y.last)
        .checked_sub(u64::from(y.first))?
        .checked_add(1)?;
    usize::try_from(columns.checked_mul(rows)?).ok()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GridError {
    InvalidGeometry,
    InvalidBudget,
    TooManyPages,
    TooManyTiles,
}
impl fmt::Display for GridError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::InvalidGeometry => "Tile planning requires finite bounded geometry",
            Self::InvalidBudget => "Tile planning requires a valid resident pixel budget",
            Self::TooManyPages => "Tile planning exceeds its page batch limit",
            Self::TooManyTiles => "Tile planning exceeds its bounded tile capacity",
        })
    }
}
impl std::error::Error for GridError {}
#[derive(Clone, Copy, Debug)]
pub enum Density {
    /// Explicit tier used by cache consumers and deterministic fixtures.
    Tier(i32),
    /// Actual zoom × backing scale and this surface's resident-pixel allocation.
    Surface {
        required_scale: f64,
        resident_bytes: u64,
    },
}
/// Page-local top-left geometry in PDF points; density is relative to 72 dpi.
#[derive(Clone, Copy, Debug)]
pub struct GridPageRequest {
    pub page: u32,
    pub width: f64,
    pub height: f64,
    pub visible: PlanRect,
    pub density: Density,
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GridTile {
    pub column: u32,
    pub row: u32,
    pub target: PlanRect,
    pub render: PlanRect,
}
#[derive(Clone, Debug, PartialEq)]
pub struct GridPagePlan {
    pub page: u32,
    pub tier: i32,
    pub scale: f64,
    pub tiles: Vec<GridTile>,
}

fn density_scale(tier: i32) -> f64 {
    (f64::from(tier) / 4.0).exp2()
}
fn visible_count(view: PlanRect, edge: f64) -> f64 {
    ((view.max_x() / edge).ceil() - (view.x / edge).floor())
        * ((view.max_y() / edge).ceil() - (view.y / edge).floor())
}
fn clipped(rect: PlanRect, width: f64, height: f64) -> PlanRect {
    let x = rect.x.max(0.0);
    let y = rect.y.max(0.0);
    PlanRect::new(
        x,
        y,
        rect.max_x().min(width) - x,
        rect.max_y().min(height) - y,
    )
}
fn plan_page(request: &GridPageRequest) -> Result<GridPagePlan, GridError> {
    let r = request.visible;
    if ![
        request.width,
        request.height,
        r.x,
        r.y,
        r.width,
        r.height,
        r.max_x(),
        r.max_y(),
    ]
    .iter()
    .all(|v| v.is_finite())
        || request.width <= 0.0
        || request.height <= 0.0
    {
        return Err(GridError::InvalidGeometry);
    }
    let (mut tier, budget) = match request.density {
        Density::Tier(tier) => (tier.clamp(MIN_DENSITY_TIER, MAX_DENSITY_TIER), None),
        Density::Surface {
            required_scale,
            resident_bytes,
        } => {
            if !required_scale.is_finite() || required_scale <= 0.0 {
                return Err(GridError::InvalidGeometry);
            }
            if resident_bytes < 2 * 1024 * 1024 {
                return Err(GridError::InvalidBudget);
            }
            let tier = (required_scale.log2() * 4.0)
                .ceil()
                .clamp(f64::from(MIN_DENSITY_TIER), f64::from(MAX_DENSITY_TIER))
                as i32;
            (
                tier,
                Some(resident_bytes - resident_bytes.min(4 * 1024 * 1024).min(resident_bytes / 4)),
            )
        }
    };
    let view = clipped(r, request.width, request.height);
    if r.width <= 0.0 || r.height <= 0.0 || view.width <= 0.0 || view.height <= 0.0 {
        return Ok(GridPagePlan {
            page: request.page,
            tier,
            scale: density_scale(tier),
            tiles: vec![],
        });
    }
    // Keep the existing per-surface pixel reserve before applying the page's tile cap.
    if let Some(bytes) = budget {
        while tier > MIN_DENSITY_TIER
            && visible_count(view, 512.0 / density_scale(tier)) * 515.0 * 515.0 * 4.0 > bytes as f64
        {
            tier -= 1;
        }
    }
    while tier > MIN_DENSITY_TIER
        && visible_count(view, 512.0 / density_scale(tier)) > MAX_PAGE_TILES as f64
    {
        tier -= 1;
    }
    let scale = density_scale(tier);
    let edge = 512.0 / scale;
    let x = axis_span(
        view.x,
        view.max_x(),
        request.width,
        edge,
        UpperEdge::HalfOpen,
        false,
        0,
    )
    .ok_or(GridError::InvalidGeometry)?;
    let y = axis_span(
        view.y,
        view.max_y(),
        request.height,
        edge,
        UpperEdge::HalfOpen,
        false,
        0,
    )
    .ok_or(GridError::InvalidGeometry)?;
    let count = count(x, y).ok_or(GridError::TooManyTiles)?;
    if count > MAX_PAGE_TILES {
        return Err(GridError::TooManyTiles);
    }
    let mut tiles = Vec::with_capacity(count);
    for (column, row) in coordinates(x, y) {
        let target = clipped(
            PlanRect::new(f64::from(column) * edge, f64::from(row) * edge, edge, edge),
            request.width,
            request.height,
        );
        let bleed = 1.0 / scale;
        let render = clipped(
            PlanRect::new(
                target.x - bleed,
                target.y - bleed,
                target.width + 2.0 * bleed,
                target.height + 2.0 * bleed,
            ),
            request.width,
            request.height,
        );
        tiles.push(GridTile {
            column,
            row,
            target,
            render,
        });
    }
    // Equal-distance submissions now have an explicit row/column tie order. The
    // previous shell std::sort left those ties unspecified; density/coverage is unchanged.
    let distance = |tile: &GridTile| {
        let rect = tile.target;
        (rect.x + rect.width / 2.0 - view.x - view.width / 2.0)
            .hypot(rect.y + rect.height / 2.0 - view.y - view.height / 2.0)
    };
    tiles.sort_by(|a, b| distance(a).total_cmp(&distance(b)));
    Ok(GridPagePlan {
        page: request.page,
        tier,
        scale,
        tiles,
    })
}

/// One bounded control-plane call returns complete page-local plans. No cache or
/// raster work occurs here; any error rejects the batch rather than returning partial work.
pub fn plan_density_batch(requests: &[GridPageRequest]) -> Result<Vec<GridPagePlan>, GridError> {
    if requests.len() > MAX_BATCH_PAGES {
        return Err(GridError::TooManyPages);
    }
    requests.iter().map(plan_page).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request() -> GridPageRequest {
        GridPageRequest {
            page: 0,
            width: 595.0,
            height: 842.0,
            visible: PlanRect::new(0.0, 0.0, 256.0, 256.0),
            density: Density::Tier(4),
        }
    }
    #[test]
    fn half_open_boundaries_and_legacy_edges_are_explicit() {
        let a = axis_span(0.0, 256.0, 595.0, 256.0, UpperEdge::HalfOpen, false, 0).unwrap();
        assert_eq!((a.first, a.last), (0, 0));
        let b = axis_span(0.0, 256.0, 595.0, 256.0, UpperEdge::Inclusive, true, 0).unwrap();
        assert_eq!((b.first, b.last), (0, 1));
        let plan = plan_density_batch(&[request()]).unwrap();
        assert_eq!(plan[0].tiles.len(), 1);
        let mut crossing = request();
        crossing.visible = PlanRect::new(255.9999, 255.9999, 0.0002, 0.0002);
        assert_eq!(plan_density_batch(&[crossing]).unwrap()[0].tiles.len(), 4);
    }
    #[test]
    fn quarters_negative_tiers_caps_and_surface_budget_are_preserved() {
        let mut r = request();
        r.visible = PlanRect::new(0.0, 0.0, 595.0, 842.0);
        r.density = Density::Tier(28);
        let p = plan_density_batch(&[r]).unwrap();
        assert!(p[0].tier < 28 && p[0].tiles.len() <= 96);
        r.density = Density::Tier(-3);
        let p = plan_density_batch(&[r]).unwrap();
        assert_eq!(p[0].scale, (-0.75_f64).exp2());
        r.density = Density::Surface {
            required_scale: 4.0,
            resident_bytes: 2 * 1024 * 1024,
        };
        let p = plan_density_batch(&[r]).unwrap();
        assert!(p[0].tier < 8);
        for t in &p[0].tiles {
            assert!(
                t.render.x >= 0.0
                    && t.render.y >= 0.0
                    && t.render.max_x() <= r.width
                    && t.render.max_y() <= r.height
            );
        }
    }
    #[test]
    fn resident_policy_matches_frozen_surface_examples() {
        for (scale, bytes, expected) in [
            (0.25, 2 * 1024 * 1024, -8),
            (1.0, 2 * 1024 * 1024, -3),
            (4.0, 2 * 1024 * 1024, -3),
            (4.0, 16 * 1024 * 1024, 3),
            (4.0, 64 * 1024 * 1024, 8),
            (1.4, 64 * 1024 * 1024, 2),
        ] {
            let mut r = request();
            r.visible = PlanRect::new(0.0, 0.0, 595.0, 842.0);
            r.density = Density::Surface {
                required_scale: scale,
                resident_bytes: bytes,
            };
            assert_eq!(plan_density_batch(&[r]).unwrap()[0].tier, expected);
        }
    }

    #[test]
    fn equal_distance_submissions_keep_row_major_ties() {
        let mut r = request();
        r.visible = PlanRect::new(0.0, 0.0, 512.0, 512.0);
        let p = plan_density_batch(&[r]).unwrap();
        assert_eq!(
            p[0].tiles
                .iter()
                .map(|t| (t.column, t.row))
                .collect::<Vec<_>>(),
            vec![(0, 0), (1, 0), (0, 1), (1, 1)]
        );
    }

    #[test]
    fn invalid_or_huge_work_is_rejected_before_enumeration() {
        let mut r = request();
        r.width = f64::NAN;
        assert_eq!(plan_density_batch(&[r]), Err(GridError::InvalidGeometry));
        r = request();
        r.width = 1e300;
        r.height = 1e300;
        r.visible = PlanRect::new(0.0, 0.0, 1e300, 1e300);
        assert!(plan_density_batch(&[r]).is_err());
        assert_eq!(
            plan_density_batch(&vec![request(); MAX_BATCH_PAGES + 1]),
            Err(GridError::TooManyPages)
        );
        r = request();
        r.density = Density::Surface {
            required_scale: 1.0,
            resident_bytes: 0,
        };
        assert_eq!(plan_density_batch(&[r]), Err(GridError::InvalidBudget));
        r = request();
        r.visible = PlanRect::new(1000.0, 0.0, 10.0, 10.0);
        assert!(plan_density_batch(&[r]).unwrap()[0].tiles.is_empty());
    }
}
