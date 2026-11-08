//! Frozen legacy batch decisions, including ordering and drawer/tear retention.
use lyra_reader_render::plan::*;
use serde_json::{Value, json};

pub fn captures() -> Value {
    let mut cases = Vec::new();
    for facing in [false, true] {
        for lod in [0, 1, 3, 4] {
            for step in [0, 1, 2, 3] {
                let page = |i: u32| PlanPage {
                    page: i,
                    top_pt: f64::from(if facing { i / 2 } else { i }) * 1200.0,
                    left_pt: if facing && i % 2 == 1 { 600.0 } else { 0.0 },
                    width_pt: 600.0,
                    height_pt: 1200.0,
                    display_top_pt: f64::from(if facing { i / 2 } else { i }) * 1200.0,
                    tear_split_pt: (step == 3 && i == 2).then_some(400.0),
                    tear_gap_pt: if step == 3 && i == 2 { 160.0 } else { 0.0 },
                };
                let request = PlanRequest {
                    viewport: PlanRect::new(
                        if step == 2 { 256.0 } else { 0.0 },
                        f64::from(step) * 374.0,
                        if facing { 1100.0 } else { 512.0 },
                        640.0,
                    ),
                    scroll_direction: if step == 2 { -1.0 } else { 1.0 },
                    zoom: 1.375,
                    tile_size_px: 512,
                    lod,
                    cache_budget_bytes: 48 * 1024 * 1024,
                    band_budget_override_bytes: (step == 1).then_some(8 * 1024 * 1024),
                    ring_override_vh: (step == 2).then_some(0.0),
                    prefetch_columns: u32::from(step == 1),
                    want_all_columns: step == 3,
                    drawer_width_pt: if step >= 2 { 280.0 } else { 0.0 },
                    right_panel_layout_moving: step == 3,
                    pages: (0..6).map(page).collect(),
                    cached_tiles: vec![CachedTile {
                        page: 0,
                        lod,
                        x: 0,
                        y: 0,
                        bytes: 48,
                    }],
                    prior_tiles: vec![
                        PriorTile {
                            page: 0,
                            lod,
                            x: 5,
                            y: 0,
                            left_pt: 600.0,
                        },
                        PriorTile {
                            page: 1,
                            lod,
                            x: 4,
                            y: 2,
                            left_pt: 700.0,
                        },
                    ],
                };
                let plan = plan_tiles(&request).expect("finite bounded legacy request");
                let key = |k: &PlannedKey| json!([k.page, k.lod, k.x, k.y]);
                cases.push(json!({"facing":facing,"lod":lod,"step":step,"ring":plan.ring_vh,
                    "pages":plan.pages.iter().map(|p|json!([p.page,p.first_column,p.last_column,p.first_row,p.last_row])).collect::<Vec<_>>(),
                    "tiles":plan.tiles.iter().map(|t|json!([t.page,t.lod,t.x,t.y,t.prefetch,format!("{:?}",t.priority)])).collect::<Vec<_>>(),
                    "pinned":plan.pinned.iter().map(key).collect::<Vec<_>>(),"retained":plan.retained.iter().map(key).collect::<Vec<_>>()}));
            }
        }
    }
    json!({"schema":1,"cases":cases})
}

#[test]
fn legacy_batch_decisions_match_the_pre_change_freeze() {
    let expected: Value = serde_json::from_str(include_str!(
        "../../../tests/fixtures/tile-plan/shared-plans.json"
    ))
    .expect("public frozen fixture");
    assert_eq!(captures(), expected);
}
