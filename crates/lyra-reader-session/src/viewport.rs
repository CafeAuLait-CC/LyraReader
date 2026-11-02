//! Viewport and zoom math.
//!
//! # The one zoom/fit policy
//!
//! The reader's zoom is an **integer percentage**. That is a product decision, not an
//! implementation detail: the toolbar, the fit presets and the pointer gestures all show and
//! store the same number, so a preset can never produce "124.7%" that the toolbar then rounds
//! somewhere else. The resolved policy therefore lives here, in the platform-independent
//! session crate, and the shell asks for it through the FFI rather than keeping a second copy.
//!
//! The values are the shipping macOS reader's: 25–400%, an 8 pt inset per side for the Fit
//! Width and Fit Page presets (16 pt of total viewport width/height), and floor rounding for a
//! fit (rounding up would put a sliver of the page outside a viewport that has no horizontal
//! scrolling). `calibration` is the display's physical-density factor; `100%` means "actual
//! size" on the current screen, so a fit divides by it.
//!
//! Zoom anchoring rules (`docs/04-ui-ux.md` §3):
//!
//! 1. Pinch zoom: **the page point under the cursor stays fixed**;
//! 2. Keyboard zoom: the viewport center stays fixed;
//! 3. Fit width + window resize: the topmost visible page and the relative position within that page stay fixed.
//!
//! Only the *resolution* lives here. Anchoring is applied by the shell against
//! [`clamp_scroll`], which this module also owns so there is one scroll range.

use crate::command::{Layout, Zoom};
use lyra_reader_core::{Point, Rect, Size};

/// Lowest zoom the reader offers, in whole percent.
pub const MIN_ZOOM_PERCENT: u32 = 25;
/// Highest zoom the reader offers, in whole percent.
pub const MAX_ZOOM_PERCENT: u32 = 400;
/// Inset the Fit Width / Fit Page presets leave on **each** side, in points.
pub const ZOOM_PRESET_INSET_PT: f64 = 8.0;

/// What the caller is asking the zoom policy to resolve.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ZoomRequest {
    /// A step from the current percentage (`delta` may be negative), used by the toolbar and
    /// by pointer gestures.
    Step { percent: u32, delta: i32 },
    /// Fit the page's width into the viewport width, leaving the preset inset per side.
    FitWidth,
    /// Fit the page's height into the viewport height, leaving the preset inset per side.
    ///
    /// This is the shipping "Fit Page" preset: it fits the height only, because width is what
    /// Fit Width is for and the page remains vertically scrollable when it is smaller than
    /// the window.
    FitPage,
}

/// Viewport state (the source of truth is the engine; the host is only a controlled view).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Viewport {
    /// Position of the scrolled content's top-left corner in View Space.
    pub scroll: Point,
    /// Viewport size (pt).
    pub view_size: Size,
    /// Zoom mode requested by the user.
    pub zoom: Zoom,
    /// Resolved effective zoom percentage (computed by [`resolve_zoom_percent`]) as a factor:
    /// `percent / 100 × calibration`.
    pub zoom_factor: f64,
    pub layout: Layout,
    /// Screen scale (Retina = 2.0).
    pub backing_scale: f64,
    /// Page gap (pt).
    pub page_gap: f64,
}

impl Default for Viewport {
    fn default() -> Self {
        Self {
            scroll: Point::new(0.0, 0.0),
            view_size: Size::new(1024.0, 768.0),
            zoom: Zoom::default(),
            zoom_factor: 1.0,
            layout: Layout::default(),
            backing_scale: 2.0,
            page_gap: 12.0,
        }
    }
}

impl Viewport {
    /// Viewport rectangle (View Space).
    pub fn visible_rect(&self) -> Rect {
        Rect::new(
            self.scroll.x,
            self.scroll.y,
            self.view_size.width,
            self.view_size.height,
        )
    }

    /// Scale required for rasterization: device pixels / PDF pt (= zoom × backingScale).
    pub fn device_scale(&self) -> f64 {
        self.zoom_factor * self.backing_scale
    }
}

/// Resolve a zoom request to the reader's **integer percentage**.
///
/// `page` is the page (or spread row) size in view-space points at 100%; `viewport` is the
/// viewport size in points; `calibration` is the display's physical-density factor (`1.0` for
/// the uncalibrated convention). Returns `None` when a fit has no usable geometry — a zero or
/// non-finite page/viewport/calibration, or a viewport not wider/taller than the inset.
///
/// The arithmetic matches the shipping shell's formula exactly: subtract `2 × 8 pt`, divide by
/// the calibrated content size, multiply by 100, floor, then clamp to 25…400. Flooring happens
/// before the clamp, so a tiny viewport floors to 0 and then becomes 25, exactly as before.
pub fn resolve_zoom_percent(
    request: ZoomRequest,
    page: Size,
    viewport: Size,
    calibration: f64,
) -> Option<u32> {
    match request {
        ZoomRequest::Step { percent, delta } => {
            let stepped = i64::from(percent) + i64::from(delta);
            Some(stepped.clamp(i64::from(MIN_ZOOM_PERCENT), i64::from(MAX_ZOOM_PERCENT)) as u32)
        }
        ZoomRequest::FitWidth => fit_percent(page.width, viewport.width, calibration),
        ZoomRequest::FitPage => fit_percent(page.height, viewport.height, calibration),
    }
}

fn fit_percent(content_pt: f64, viewport_pt: f64, calibration: f64) -> Option<u32> {
    let available = viewport_pt - 2.0 * ZOOM_PRESET_INSET_PT;
    if !(content_pt.is_finite() && content_pt > 0.0)
        || !(available.is_finite() && available > 0.0)
        || !(calibration.is_finite() && calibration > 0.0)
    {
        return None;
    }
    let percent = available / (content_pt * calibration) * 100.0;
    if !percent.is_finite() {
        return None;
    }
    // Clamp before the integer conversion so an extreme viewport cannot overflow the cast.
    if percent >= f64::from(MAX_ZOOM_PERCENT) {
        return Some(MAX_ZOOM_PERCENT);
    }
    if percent <= f64::from(MIN_ZOOM_PERCENT) {
        return Some(MIN_ZOOM_PERCENT);
    }
    Some(percent.floor() as u32)
}

/// Clamp a scroll offset into `0 … max(0, content_height − viewport_height)`.
///
/// This is the shell's only scroll clamp. Keeping it beside the zoom policy means the two
/// numbers a resize/zoom step must agree on (the content height and the visible height) have
/// one implementation instead of one per call site.
pub fn clamp_scroll(offset: f64, content_height: f64, viewport_height: f64) -> f64 {
    let maximum = (content_height - viewport_height).max(0.0);
    offset.clamp(0.0, maximum)
}

/// The Fit Page percentage a real viewport-height change should adopt, when it should adopt one.
///
/// **Scope.** Only a single-page document changes its zoom on a resize or a fullscreen
/// transition. A multi-page document keeps the reader's percentage: re-fitting the current page
/// of a 200-page paper on every window drag would throw away the reading position, and the scroll
/// range already becomes tight via [`clamp_scroll`] (top edge at the viewport top, last page's
/// bottom at the viewport bottom). A facing spread is a multi-page document too — its row count
/// is smaller than its page count, but the percentage still belongs to the reader.
///
/// **When.** The current percentage must be *below* the fit value. That means the page at the
/// current zoom is shorter than the viewport minus the preset inset, which is exactly the case
/// where re-fitting removes blank space. At or above the fit value the function returns `None`:
/// shrinking to the fit would only add the preset's own blank (the fit leaves 8 pt per side) and
/// would override a zoom the reader chose. A manual zoom-out after an automatic fit is therefore
/// stable until the next real viewport change, which asks this function again.
///
/// The fit arithmetic is [`resolve_zoom_percent`]'s (8 pt inset per side, 25–400 clamp, floor);
/// this function must not grow a second formula.
pub fn fit_page_on_viewport_change(
    page_count: u32,
    current_percent: u32,
    page_height_pt: f64,
    viewport_height_pt: f64,
    calibration: f64,
) -> Option<u32> {
    if page_count != 1 {
        return None;
    }
    // FitPage reads the height axis; the width values are unused but must be finite for
    // `fit_percent`'s shared validation, so pass the same height on both axes.
    let fit = resolve_zoom_percent(
        ZoomRequest::FitPage,
        Size::new(page_height_pt, page_height_pt),
        Size::new(viewport_height_pt, viewport_height_pt),
        calibration,
    )?;
    (current_percent < fit).then_some(fit)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn a4() -> Size {
        Size::new(595.0, 842.0)
    }

    fn viewport() -> Size {
        Size::new(1000.0, 800.0)
    }

    fn step(percent: u32, delta: i32) -> Option<u32> {
        resolve_zoom_percent(ZoomRequest::Step { percent, delta }, a4(), viewport(), 1.0)
    }

    #[test]
    fn steps_clamp_at_25_and_400() {
        assert_eq!(step(100, 10), Some(110));
        assert_eq!(step(95, 10), Some(105));
        assert_eq!(step(390, 10), Some(400));
        assert_eq!(step(400, 10), Some(400));
        assert_eq!(step(30, -10), Some(25));
        assert_eq!(step(25, -10), Some(25));
        assert_eq!(step(37, 10), Some(47), "odd zoom steps are not rounded");
        assert_eq!(step(37, -10), Some(27));
    }

    #[test]
    fn fit_width_uses_the_preset_inset_and_floors() {
        // (1000 - 16) / 595 × 100 = 165.378… → 165
        assert_eq!(
            resolve_zoom_percent(ZoomRequest::FitWidth, a4(), viewport(), 1.0),
            Some(165)
        );
        // A 1.507 calibration divides the physical size: 984 / (595 × 1.507) × 100 = 109.72…
        assert_eq!(
            resolve_zoom_percent(ZoomRequest::FitWidth, a4(), viewport(), 1.507),
            Some(109)
        );
    }

    #[test]
    fn fit_page_uses_the_height_axis() {
        // (800 - 16) / 842 × 100 = 93.11…
        assert_eq!(
            resolve_zoom_percent(ZoomRequest::FitPage, a4(), viewport(), 1.0),
            Some(93)
        );
        assert_eq!(
            resolve_zoom_percent(
                ZoomRequest::FitPage,
                Size::new(595.0, 1000.0),
                viewport(),
                1.0
            ),
            Some(78)
        );
    }

    #[test]
    fn a_fit_that_would_round_up_is_floored() {
        // 1120×800 viewport: (1120 - 16) / 595 × 100 = 185.546… → 185
        assert_eq!(
            resolve_zoom_percent(
                ZoomRequest::FitWidth,
                Size::new(595.0, 842.0),
                Size::new(1120.0, 800.0),
                1.0
            ),
            Some(185)
        );
    }

    #[test]
    fn a_fit_clamps_to_the_reader_range() {
        assert_eq!(
            resolve_zoom_percent(
                ZoomRequest::FitWidth,
                Size::new(1.0, 1.0),
                Size::new(100_000.0, 1000.0),
                1.0
            ),
            Some(MAX_ZOOM_PERCENT)
        );
        assert_eq!(
            resolve_zoom_percent(
                ZoomRequest::FitWidth,
                Size::new(100_000.0, 842.0),
                viewport(),
                1.0
            ),
            Some(MIN_ZOOM_PERCENT)
        );
    }

    #[test]
    fn a_fit_without_usable_geometry_returns_none() {
        let no = |page: Size, view: Size, calibration: f64| {
            resolve_zoom_percent(ZoomRequest::FitWidth, page, view, calibration)
        };
        assert_eq!(no(Size::new(0.0, 842.0), viewport(), 1.0), None);
        assert_eq!(no(a4(), Size::new(10.0, 800.0), 1.0), None);
        assert_eq!(no(a4(), viewport(), 0.0), None);
        assert_eq!(no(a4(), viewport(), f64::NAN), None);
        assert_eq!(
            resolve_zoom_percent(ZoomRequest::FitWidth, a4(), Size::new(f64::NAN, 800.0), 1.0),
            None
        );
    }

    #[test]
    fn clamp_scroll_matches_the_shell_range() {
        assert_eq!(clamp_scroll(-5.0, 1000.0, 300.0), 0.0);
        assert_eq!(clamp_scroll(500.0, 1000.0, 300.0), 500.0);
        assert_eq!(clamp_scroll(9999.0, 1000.0, 300.0), 700.0);
        assert_eq!(clamp_scroll(9999.0, 200.0, 300.0), 0.0);
        assert_eq!(clamp_scroll(120.0, 0.0, 0.0), 0.0);
    }

    #[test]
    fn a_blank_single_page_adopts_the_fit_page_percent() {
        // A4 at 100% is 842 pt tall inside a 900 pt viewport: 58 pt of blank below it.
        // The fit is (900 - 16) / 842 × 100 = 104.988… → 104.
        assert_eq!(
            fit_page_on_viewport_change(1, 100, 842.0, 900.0, 1.0),
            Some(104)
        );
        // A taller-than-viewport page at the same percentage leaves no blank and must stay.
        assert_eq!(fit_page_on_viewport_change(1, 100, 842.0, 800.0, 1.0), None);
    }

    #[test]
    fn a_filled_or_zoomed_single_page_keeps_its_percent() {
        // 93 is exactly the fit for an 800 pt viewport; at the fit value the preset's 16 pt of
        // blank is intentional and is not a reason to shrink to the same value again.
        assert_eq!(fit_page_on_viewport_change(1, 93, 842.0, 800.0, 1.0), None);
        assert_eq!(fit_page_on_viewport_change(1, 104, 842.0, 900.0, 1.0), None);
        assert_eq!(fit_page_on_viewport_change(1, 250, 842.0, 900.0, 1.0), None);
        // 100 > 99 (the fit for 850 pt) even though 842 < 850: the reader is above the fit
        // value, and the second rule ("already at or above the fit") wins over the 8 pt edge.
        assert_eq!(fit_page_on_viewport_change(1, 100, 842.0, 850.0, 1.0), None);
    }

    #[test]
    fn a_multi_page_document_never_changes_zoom_on_a_viewport_change() {
        // The same blank geometry that fits a one-page document (viewport 900) must not touch
        // a three-page paper, and a facing spread (two pages per row) is still multi-page.
        for page_count in [2, 3, 200] {
            assert_eq!(
                fit_page_on_viewport_change(page_count, 100, 842.0, 900.0, 1.0),
                None
            );
            assert_eq!(
                fit_page_on_viewport_change(page_count, 50, 842.0, 2000.0, 1.0),
                None
            );
        }
        assert_eq!(fit_page_on_viewport_change(2, 100, 842.0, 900.0, 1.5), None);
    }

    #[test]
    fn a_facing_spread_keeps_its_percent() {
        // Facing layout puts two pages in a row, but the document still has a page count; the
        // policy only ever participates for page_count == 1. A cover/verso pair is not a
        // single-page document even though the row looks like one tall page.
        assert_eq!(fit_page_on_viewport_change(2, 100, 842.0, 900.0, 1.0), None);
        assert_eq!(fit_page_on_viewport_change(2, 50, 842.0, 2000.0, 1.0), None);
        // No document (page_count 0) is not a single page either.
        assert_eq!(fit_page_on_viewport_change(0, 100, 842.0, 900.0, 1.0), None);
    }

    #[test]
    fn the_resize_fit_uses_the_min_and_max_clamps() {
        // 884 / (10 × 1) × 100 is far past 400: the preset clamps to 400, so a 399% reader is
        // below the fit and adopts it, while 400% is at the fit and stays.
        assert_eq!(
            fit_page_on_viewport_change(1, 399, 10.0, 1000.0, 1.0),
            Some(MAX_ZOOM_PERCENT)
        );
        assert_eq!(fit_page_on_viewport_change(1, 400, 10.0, 1000.0, 1.0), None);
        // A page taller than any percentage can fit clamps to 25; 24 is below it.
        assert_eq!(
            fit_page_on_viewport_change(1, 24, 100_000.0, 900.0, 1.0),
            Some(MIN_ZOOM_PERCENT)
        );
        assert_eq!(
            fit_page_on_viewport_change(1, 25, 100_000.0, 900.0, 1.0),
            None
        );
    }

    #[test]
    fn the_resize_fit_returns_none_for_invalid_geometry() {
        let no = |page_height: f64, viewport_height: f64, calibration: f64| {
            fit_page_on_viewport_change(1, 50, page_height, viewport_height, calibration)
        };
        assert_eq!(no(0.0, 900.0, 1.0), None);
        assert_eq!(no(f64::NAN, 900.0, 1.0), None);
        assert_eq!(no(f64::INFINITY, 900.0, 1.0), None);
        assert_eq!(no(-842.0, 900.0, 1.0), None);
        assert_eq!(no(842.0, 16.0, 1.0), None);
        assert_eq!(no(842.0, 0.0, 1.0), None);
        assert_eq!(no(842.0, f64::NAN, 1.0), None);
        assert_eq!(no(842.0, 900.0, 0.0), None);
        assert_eq!(no(842.0, 900.0, f64::NAN), None);
    }

    #[test]
    fn the_resize_fit_does_not_duplicate_the_preset_formula() {
        for viewport_height in [200.0, 500.0, 800.0, 900.0, 1200.0, 4000.0] {
            let preset = resolve_zoom_percent(
                ZoomRequest::FitPage,
                Size::new(595.0, 842.0),
                Size::new(1000.0, viewport_height),
                1.0,
            )
            .unwrap();
            // One percent below the preset is always below the fit; the function must return
            // exactly the preset value, not a recomputed approximation of it.
            if preset > MIN_ZOOM_PERCENT {
                assert_eq!(
                    fit_page_on_viewport_change(1, preset - 1, 842.0, viewport_height, 1.0),
                    Some(preset),
                    "viewport {viewport_height}"
                );
            }
            assert_eq!(
                fit_page_on_viewport_change(1, preset, 842.0, viewport_height, 1.0),
                None,
                "viewport {viewport_height}"
            );
        }
    }

    #[test]
    fn device_scale_multiplies_backing_scale() {
        let v = Viewport {
            zoom_factor: 1.5,
            backing_scale: 2.0,
            ..Viewport::default()
        };
        assert!((v.device_scale() - 3.0).abs() < 1e-9);
    }
}
