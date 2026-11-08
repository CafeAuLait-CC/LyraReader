//! Explicit expectations frozen from macOS InsidePageTearChecks/PaperRevealChecks.
//! These are portable source-contract tests, not a claim that AppKit ran on this host.
use lyra_reader_core::{PageGeometry, Rect, Rotation};
use lyra_reader_session::paper::{
    MAX_PAPER_GEOMETRY_ITEMS, PaperLayout, PaperQuad, TearFallback, paper_reveal_progress,
    plan_tear,
};

fn rect(y: f64, height: f64) -> Rect {
    Rect::new(100.0, y, 220.0, height)
}

fn lines() -> Vec<Rect> {
    [100.0, 300.0, 500.0, 700.0, 1100.0]
        .into_iter()
        .map(|y| Rect::new(100.0, y, 7.0, 11.0))
        .collect()
}

#[test]
fn mac_safe_cuts_do_not_depend_on_the_inserted_gap_height() {
    let glyphs = lines();
    for (selection, expected) in [
        (rect(100.0, 90.0), 190.0),
        (rect(200.0, 105.0), 311.0),
        (rect(1000.0, 100.0), 1100.0),
    ] {
        let plan = plan_tear(1200.0, selection, &glyphs, &[], true);
        assert_eq!(plan.split_pt, Some(expected));
        assert_eq!(plan.fallback, None);
    }
    let figure = Rect::new(40.0, 250.0, 520.0, 350.0);
    let glyphs: Vec<_> = [300.0, 500.0, 700.0]
        .into_iter()
        .map(|y| Rect::new(100.0, y, 7.0, 11.0))
        .collect();
    assert_eq!(
        plan_tear(1200.0, rect(100.0, 200.0), &glyphs, &[figure], true).split_pt,
        Some(711.0)
    );
}

#[test]
fn mac_artwork_and_foot_fallbacks_are_explicit() {
    let selection = Rect::new(10.0, 100.0, 80.0, 100.0);
    let unknown = plan_tear(1200.0, selection, &[], &[], false);
    assert_eq!(unknown.split_pt, None);
    assert_eq!(unknown.fallback, Some(TearFallback::UnindexedArtwork));
    let indexed = Rect::new(0.0, 600.0, 100.0, 100.0);
    assert_eq!(
        plan_tear(1200.0, selection, &[], &[indexed], false).split_pt,
        Some(200.0)
    );
    let at_foot = plan_tear(1200.0, rect(1190.0, 10.0), &lines(), &[], true);
    assert_eq!(at_foot.split_pt, None);
    assert_eq!(at_foot.fallback, None);
    let blocked = plan_tear(
        1200.0,
        selection,
        &[],
        &[Rect::new(0.0, 150.0, 600.0, 1050.0)],
        true,
    );
    assert_eq!(blocked.split_pt, None);
}

#[test]
fn line_bands_merge_superscripts_descenders_and_subpoint_contacts() {
    let glyphs = [
        rect(100.0, 10.0),
        rect(109.5, 10.5),
        rect(120.7, 5.3),
        rect(140.0, 10.0),
    ];
    for boxes in [glyphs.to_vec(), glyphs.into_iter().rev().collect()] {
        assert_eq!(
            plan_tear(1200.0, rect(80.0, 25.0), &boxes, &[], true).split_pt,
            Some(126.0)
        );
    }
    // A zero-advance glyph is not a line candidate, but still prevents cutting through it.
    let zero_width = Rect::new(0.0, 190.0, 0.0, 50.0);
    assert_eq!(
        plan_tear(1200.0, rect(100.0, 100.0), &[zero_width], &[], true).split_pt,
        None
    );
}

#[test]
fn invalid_file_geometry_and_counts_fall_back_before_sorting() {
    for height in [f64::NAN, f64::INFINITY, -2.0, 1.0] {
        assert_eq!(
            plan_tear(height, rect(100.0, 100.0), &[], &[], true).fallback,
            Some(TearFallback::UnknownPageGeometry)
        );
    }
    for selection in [rect(f64::NAN, 10.0), rect(1e308, 1e308), rect(10.0, -1.0)] {
        assert_eq!(
            plan_tear(1200.0, selection, &[], &[], true).fallback,
            Some(TearFallback::InvalidSelection)
        );
    }
    for obstacle in [rect(f64::NAN, 10.0), rect(1e308, 1e308), rect(10.0, -1.0)] {
        for (glyphs, figures) in [(&[obstacle][..], &[][..]), (&[][..], &[obstacle][..])] {
            assert_eq!(
                plan_tear(1200.0, rect(100.0, 100.0), glyphs, figures, true).fallback,
                Some(TearFallback::InvalidContentGeometry)
            );
        }
    }
    let boxes = vec![rect(0.0, 0.0); MAX_PAPER_GEOMETRY_ITEMS];
    assert_eq!(
        plan_tear(1200.0, rect(100.0, 100.0), &boxes, &[rect(0.0, 1.0)], true).fallback,
        Some(TearFallback::GeometryLimit)
    );
}

#[test]
fn dense_page_candidates_are_processed_in_one_sorted_sweep() {
    let glyphs: Vec<_> = (0..65_536)
        .map(|i| Rect::new(0.0, f64::from(i) * 3.0, 1.0, 2.0))
        .collect();
    let block = Rect::new(0.0, 0.0, 100.0, 190_000.0);
    assert_eq!(
        plan_tear(200_000.0, rect(0.0, 1.0), &glyphs, &[block], true).split_pt,
        Some(190_001.0)
    );
}

#[test]
fn mac_segments_and_point_inverse_skip_the_gap() {
    let paper = PaperLayout::new(1200.0, Some(190.0), 300.0).unwrap();
    let [Some(upper), Some(lower)] = paper.segments() else {
        panic!("two segments")
    };
    assert_eq!(
        (upper.source_top_pt, upper.display_top_pt, upper.height_pt),
        (0.0, 0.0, 190.0)
    );
    assert_eq!(
        (lower.source_top_pt, lower.display_top_pt, lower.height_pt),
        (190.0, 490.0, 1010.0)
    );
    assert_eq!(paper.display_y(100.0), Some(100.0));
    assert_eq!(paper.display_y(900.0), Some(1200.0));
    assert_eq!(paper.paper_y(1200.0), Some(900.0));
    for y in [190.0, 290.0, 489.999] {
        assert_eq!(paper.paper_y(y), None);
    }
    assert_eq!(paper.paper_y(490.0), Some(190.0));
    assert_eq!(paper.display_y(-2.0), Some(-2.0));
    assert_eq!(paper.display_y(1300.0), Some(1600.0));
    assert_eq!(paper.paper_y(1600.0), Some(1300.0));
    for y in [f64::NAN, f64::INFINITY] {
        assert_eq!(paper.display_y(y), None);
        assert_eq!(paper.paper_y(y), None);
    }
}

#[test]
fn viewport_mapping_is_paper_local_and_gap_only_demand_is_empty() {
    let paper = PaperLayout::new(1200.0, Some(400.0), 200.0).unwrap();
    for (top, bottom, expected) in [
        (-50.0, 100.0, Some((0.0, 100.0))),
        (410.0, 590.0, None),
        (390.0, 610.0, Some((390.0, 410.0))),
        (800.0, 1000.0, Some((600.0, 800.0))),
        (1300.0, 1500.0, Some((1100.0, 1200.0))),
        (1500.0, 1600.0, None),
    ] {
        assert_eq!(paper.paper_band(top, bottom), expected);
    }
}

#[test]
fn mac_crossing_rectangle_keeps_both_paper_intervals() {
    let paper = PaperLayout::new(1200.0, Some(190.0), 300.0).unwrap();
    let quads = paper
        .quads(PaperQuad {
            target: Rect::new(10.0, 100.0, 100.0, 500.0),
            source: Rect::new(0.0, 0.0, 1.0, 1.0),
        })
        .unwrap();
    assert_eq!(quads.first.target, Rect::new(10.0, 100.0, 100.0, 90.0));
    assert_eq!(
        quads.second.unwrap().target,
        Rect::new(10.0, 490.0, 100.0, 410.0)
    );
    assert_eq!(quads.first.source.size.height, 0.18);
    assert!((quads.second.unwrap().source.size.height - 0.82).abs() < 1e-12);
}

#[test]
fn mac_twelve_row_raster_is_split_without_losing_or_duplicating_source_rows() {
    let paper = PaperLayout::new(12.0, Some(4.0), 3.0).unwrap();
    let pieces = paper
        .quads(PaperQuad {
            target: Rect::new(0.0, 0.0, 8.0, 12.0),
            source: Rect::new(0.0, 0.0, 1.0, 1.0),
        })
        .unwrap();
    assert_eq!(pieces.first.target, Rect::new(0.0, 0.0, 8.0, 4.0));
    assert_eq!(pieces.second.unwrap().target, Rect::new(0.0, 7.0, 8.0, 8.0));
    let mut seen = [false; 12];
    for row in 0..12 {
        let display = if row < 4 { row } else { row + 3 };
        let piece = if row < 4 {
            pieces.first
        } else {
            pieces.second.unwrap()
        };
        let source_y = (piece.source.min_y()
            + (f64::from(display) - piece.target.min_y()) / piece.target.size.height
                * piece.source.size.height)
            * 12.0;
        assert!((source_y - f64::from(row)).abs() < 1e-10);
        assert!(!seen[row as usize]);
        seen[row as usize] = true;
    }
    assert!(seen.into_iter().all(|yes| yes));
    // Cropped tile UVs remain cropped, rather than being reset to the whole image.
    let cropped = paper
        .quads(PaperQuad {
            target: Rect::new(0.0, 2.0, 8.0, 6.0),
            source: Rect::new(0.25, 0.2, 0.5, 0.6),
        })
        .unwrap();
    assert!((cropped.first.source.size.height - 0.2).abs() < 1e-12);
    assert!((cropped.second.unwrap().source.min_y() - 0.4).abs() < 1e-12);
    assert!((cropped.second.unwrap().source.max_y() - 0.8).abs() < 1e-12);
}

#[test]
fn reveal_changes_geometry_only_and_retains_full_size_source_coordinates() {
    let make = |progress| PaperLayout::new(1200.0, Some(190.0), 300.0 * progress).unwrap();
    let bottom = |p| make(p).segments()[1].unwrap();
    assert_eq!(bottom(0.25).display_top_pt, 265.0);
    assert_eq!(
        bottom(0.75).display_top_pt - bottom(0.25).display_top_pt,
        150.0
    );
    assert_eq!(bottom(0.25).height_pt, bottom(0.75).height_pt);
    for (time, expected) in [(-1.0, 0.0), (0.5, 0.5), (2.0, 1.0)] {
        assert_eq!(paper_reveal_progress(time), Some(expected));
    }
    assert_eq!(paper_reveal_progress(f64::NAN), None);
}

#[test]
fn paper_mapping_composes_after_crop_rotate_and_user_unit_without_another_y_flip() {
    for rotation in [
        Rotation::None,
        Rotation::Clockwise90,
        Rotation::Clockwise180,
        Rotation::Clockwise270,
    ] {
        let geometry = PageGeometry::new(
            Rect::new(0.0, 0.0, 700.0, 900.0),
            Rect::new(20.0, 30.0, 600.0, 800.0),
            rotation,
            1.25,
        );
        let transform = geometry.page_to_view(1.0);
        let paper = PaperLayout::new(geometry.view_size(1.0).height, Some(200.0), 83.5).unwrap();
        for y in [31.0, 130.0, 430.0, 829.0] {
            let original = lyra_reader_core::Point::new(110.0, y);
            let view = transform.apply(original);
            for zoom in [1.0, 1.25, 1.5, 2.0] {
                let pixel_y = paper.display_y(view.y).unwrap() * zoom;
                let restored_y = paper.paper_y(pixel_y / zoom).unwrap();
                let restored = transform
                    .inverse()
                    .unwrap()
                    .apply(lyra_reader_core::Point::new(view.x, restored_y));
                assert!((restored.x - original.x).abs() < 1e-9);
                assert!((restored.y - original.y).abs() < 1e-9);
            }
        }
    }
}

#[test]
fn malformed_layouts_quads_and_overflow_are_rejected() {
    for (height, split, gap) in [
        (f64::NAN, Some(1.0), 1.0),
        (1200.0, Some(f64::NAN), 1.0),
        (1200.0, Some(1200.0), 300.0),
        (1200.0, Some(0.0), 300.0),
        (1200.0, Some(190.0), -1.0),
        (1200.0, None, 1.0),
        (1e308, Some(200.0), 1e308),
    ] {
        assert!(PaperLayout::new(height, split, gap).is_err());
    }
    let paper = PaperLayout::new(1200.0, Some(190.0), 300.0).unwrap();
    assert!(
        paper
            .quads(PaperQuad {
                target: rect(0.0, f64::NAN),
                source: rect(0.0, 1.0)
            })
            .is_err()
    );
    assert!(
        paper
            .quads(PaperQuad {
                target: rect(0.0, 1.0),
                source: rect(0.0, -1.0)
            })
            .is_err()
    );
    assert_eq!(paper.paper_band(f64::NEG_INFINITY, 20.0), None);
}

#[test]
fn raw_pointer_sweeps_are_clipped_before_the_gap_is_removed() {
    use lyra_reader_core::{LineSegment, Point};
    let p = Point::new;
    let paper = PaperLayout::new(1200.0, Some(190.0), 300.0).unwrap();
    let out = paper
        .pointer_segments(600.0, p(0.0, 100.0), p(400.0, 700.0))
        .unwrap();
    assert_eq!(
        out,
        [
            Some(LineSegment::new(p(0.0, 100.0), p(60.0, 190.0))),
            Some(LineSegment::new(p(260.0, 190.0), p(400.0, 400.0)))
        ]
    );
    assert_eq!(
        paper
            .pointer_segments(600.0, p(50.0, 200.0), p(50.0, 300.0))
            .unwrap(),
        [None, None]
    );
    assert_eq!(
        paper
            .pointer_segments(600.0, p(-1.0, 100.0), p(-1.0, 1200.0))
            .unwrap(),
        [None, None]
    );
    let reverse = paper
        .pointer_segments(600.0, p(50.0, 1200.0), p(50.0, 100.0))
        .unwrap();
    assert_eq!(
        reverse,
        [
            Some(LineSegment::new(p(50.0, 190.0), p(50.0, 100.0))),
            Some(LineSegment::new(p(50.0, 900.0), p(50.0, 190.0)))
        ]
    );
    for gap in [0.0, 0.005, 0.01] {
        let plain = PaperLayout::new(1200.0, Some(190.0), gap).unwrap();
        assert_eq!(
            plain
                .pointer_segments(600.0, p(50.0, 100.0), p(50.0, 900.0))
                .unwrap(),
            [Some(LineSegment::new(p(50.0, 100.0), p(50.0, 900.0))), None]
        );
    }
    assert!(
        paper
            .pointer_segments(f64::NAN, p(0.0, 0.0), p(1.0, 1.0))
            .is_err()
    );
    assert!(
        paper
            .pointer_segments(600.0, p(-1e308, 0.0), p(1e308, 1.0))
            .is_err()
    );
}

#[test]
fn strict_pointer_hits_do_not_clamp_gaps_or_outside_paper() {
    use lyra_reader_core::Point;
    let p = Point::new;
    let paper = PaperLayout::new(500.0, Some(150.0), 80.0).unwrap();
    for display in [
        p(-0.001, 100.0),
        p(400.0, 100.0),
        p(20.0, -0.001),
        p(20.0, 150.0),
        p(20.0, 229.999),
        p(20.0, 580.0),
    ] {
        assert_eq!(paper.pointer_point(400.0, display).unwrap(), None);
    }
    assert_eq!(
        paper.pointer_point(400.0, p(0.0, 0.0)).unwrap(),
        Some(p(0.0, 0.0))
    );
    assert_eq!(
        paper.pointer_point(400.0, p(20.0, 230.0)).unwrap(),
        Some(p(20.0, 150.0))
    );
    assert_eq!(
        paper.pointer_point(400.0, p(20.0, 579.0)).unwrap(),
        Some(p(20.0, 499.0))
    );
    assert!(paper.pointer_point(f64::NAN, p(0.0, 0.0)).is_err());
    assert!(paper.pointer_point(400.0, p(f64::INFINITY, 0.0)).is_err());
    for gap in [0.0, 0.005, 0.01] {
        let plain = PaperLayout::new(500.0, Some(150.0), gap).unwrap();
        assert_eq!(
            plain.pointer_point(400.0, p(20.0, 150.0)).unwrap(),
            Some(p(20.0, 150.0))
        );
        assert_eq!(plain.pointer_point(400.0, p(20.0, 500.0)).unwrap(), None);
    }
}
