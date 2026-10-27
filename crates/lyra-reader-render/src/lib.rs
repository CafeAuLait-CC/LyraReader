//! Render planning layer (**no GPU code**): turns one viewport update into the tiles the shell
//! should rasterize, at which LOD and in which order.
//!
//! [`plan::plan_tiles`] is the production entry point: one request returns the visible and
//! prefetched tiles, their priority and the columns to retain. The shell owns the hot path — the
//! tile cache, texture upload, per-frame submission and cancellation (ADR-0007) — so this crate
//! holds no scheduler or task queue. [`cache::TileCache`] is a historical sketch, not the shipping
//! cache (see that module's documentation).
//!
//! ```text
//! viewport request ──▶ plan_tiles() ──▶ tiles + LOD + priority + retain columns
//! ```

pub mod cache;
pub mod plan;
pub mod tile;

pub use cache::{CacheEntry, CacheStats, TileCache};
pub use plan::{
    CachedTile, MAX_PREFETCH_RING_VH, MIN_PREFETCH_RING_VH, PREFETCH_RING_LADDER, PlanPage,
    PlanRect, PlanRequest, PlannedKey, PlannedPage, PlannedTile, PriorTile, TilePlan, TilePriority,
    plan_tiles,
};
pub use tile::{
    LOD_DOWNGRADE_FACTOR, LOD_UPGRADE_FACTOR, Lod, RenderPriority, RenderRequest, TileKey,
    gesture_lod, select_lod, tile_dims, visible_tiles,
};

/// Texture identity (allocated by `lyra-reader-gpu`; the scheduling layer only holds an opaque handle).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct TextureId(pub u32);

/// Render statistics (for the HUD and tuning, see `docs/03-rendering.md` §11).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct RenderStats {
    pub frames: u64,
    pub tiles_rasterized: u64,
    pub tiles_uploaded: u64,
    pub last_frame_ms: f32,
    pub average_frame_ms: f32,
    pub cache: CacheStats,
}
