//! Bounded typed control DTOs for the shared density-grid planner. No PDF or I/O.
use lyra_reader_render::{grid, plan::PlanRect};
// Compile-time ABI invariant: the native version 2 header fixes 96 slots per page.
const _: () = assert!(grid::MAX_PAGE_TILES == 96);

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
impl From<Rect> for PlanRect {
    fn from(r: Rect) -> Self {
        Self::new(r.x, r.y, r.width, r.height)
    }
}
impl From<PlanRect> for Rect {
    fn from(r: PlanRect) -> Self {
        Self {
            x: r.x,
            y: r.y,
            width: r.width,
            height: r.height,
        }
    }
}
/// Density kind 0 is an explicit tier, kind 1 is a surface scale/pixel budget.
/// Reserved must remain zero. All geometry is page-local top-left PDF points.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Request {
    pub page: u32,
    pub density_kind: u32,
    pub tier: i32,
    pub reserved: u32,
    pub width: f64,
    pub height: f64,
    pub visible: Rect,
    pub required_scale: f64,
    pub resident_bytes: u64,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Tile {
    pub column: u32,
    pub row: u32,
    pub target: Rect,
    pub render: Rect,
}
impl Tile {
    // Only unused tail slots have zero geometry; tile_count excludes them.
    const UNUSED: Self = Self {
        column: 0,
        row: 0,
        target: Rect {
            x: 0.0,
            y: 0.0,
            width: 0.0,
            height: 0.0,
        },
        render: Rect {
            x: 0.0,
            y: 0.0,
            width: 0.0,
            height: 0.0,
        },
    };
}
#[repr(C)]
pub struct PagePlan {
    pub page: u32,
    pub tier: i32,
    pub scale: f64,
    pub tile_count: usize,
    pub tiles: [Tile; grid::MAX_PAGE_TILES],
}
#[repr(C)]
pub struct Batch {
    pub plans: *mut PagePlan,
    pub len: usize,
}
impl Batch {
    pub fn empty() -> Self {
        Self {
            plans: std::ptr::null_mut(),
            len: 0,
        }
    }
    pub fn owned(plans: Vec<PagePlan>) -> Self {
        if plans.is_empty() {
            return Self::empty();
        }
        let len = plans.len();
        Self {
            plans: Box::into_raw(plans.into_boxed_slice()).cast::<PagePlan>(),
            len,
        }
    }
}

pub fn query(requests: &[Request]) -> Result<Vec<PagePlan>, String> {
    if requests.len() > grid::MAX_BATCH_PAGES {
        return Err(grid::GridError::TooManyPages.to_string());
    }
    let pages = requests
        .iter()
        .map(|p| {
            if p.reserved != 0 {
                return Err("Tile planning reserved flags must be zero".to_string());
            }
            let density = match p.density_kind {
                0 => grid::Density::Tier(p.tier),
                1 => grid::Density::Surface {
                    required_scale: p.required_scale,
                    resident_bytes: p.resident_bytes,
                },
                _ => return Err("Unknown tile density mode".to_string()),
            };
            Ok(grid::GridPageRequest {
                page: p.page,
                width: p.width,
                height: p.height,
                visible: p.visible.into(),
                density,
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    let plans = grid::plan_density_batch(&pages).map_err(|e| e.to_string())?;
    Ok(plans
        .into_iter()
        .map(|p| {
            let mut tiles = [Tile::UNUSED; grid::MAX_PAGE_TILES];
            let tile_count = p.tiles.len();
            // The shared planner caps each page before allocation/enumeration.
            for (slot, t) in tiles.iter_mut().zip(p.tiles) {
                *slot = Tile {
                    column: t.column,
                    row: t.row,
                    target: t.target.into(),
                    render: t.render.into(),
                };
            }
            PagePlan {
                page: p.page,
                tier: p.tier,
                scale: p.scale,
                tile_count,
                tiles,
            }
        })
        .collect())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    pub(crate) fn request() -> Request {
        Request {
            page: 0,
            density_kind: 0,
            tier: 4,
            reserved: 0,
            width: 595.0,
            height: 842.0,
            visible: Rect {
                x: 0.0,
                y: 0.0,
                width: 256.0,
                height: 256.0,
            },
            required_scale: 0.0,
            resident_bytes: 0,
        }
    }
    #[test]
    fn mixed_page_batch_preserves_tiers_and_rejects_partial_success() {
        let first = request();
        let mut second = first;
        second.page = 7;
        second.tier = -3;
        let response = query(&[first, second]).unwrap();
        assert_eq!(response[0].tile_count, 1);
        assert_eq!(response[1].tier, -3);
        assert_eq!(response[0].tiles[0].target.width, 256.0);
        second.width = f64::NAN;
        assert!(query(&[first, second]).is_err());
        second = first;
        second.density_kind = 2;
        assert!(query(&[second]).is_err());
        second = first;
        second.reserved = 1;
        assert!(query(&[second]).is_err());
        assert!(query(&[]).unwrap().is_empty());
    }
}
