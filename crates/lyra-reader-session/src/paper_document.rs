//! Display-only composition of the authoritative document rows and one region card.
//! The shell owns card identity, document epochs, native controls and animation; this value
//! borrows immutable source geometry and never reads a PDF, schedules tiles or writes state.
use crate::{
    DocumentLayout, PageRow,
    paper::{InvalidPaperGeometry, PaperLayout},
};

/// Remove one display-only conversation interval from a persisted document scroll offset.
/// Unlike page anchors this is a global row offset, including an untorn facing partner.
pub fn unshifted_paper_scroll_y(display_y: f64, gap_top: f64, gap: f64) -> Option<f64> {
    if ![display_y, gap_top, gap, gap_top + gap]
        .iter()
        .all(|value| value.is_finite())
        || display_y < 0.0
        || gap_top < 0.0
        || gap < 0.0
    {
        return None;
    }
    if display_y <= gap_top {
        Some(display_y)
    } else if display_y < gap_top + gap {
        Some(gap_top)
    } else {
        Some(display_y - gap)
    }
}

/// Restore a source scroll offset; an offset at the cut names the conversation's top.
/// The lost position within a display-only conversation is deliberately not reconstructed.
pub fn shifted_paper_scroll_y(source_y: f64, gap_top: f64, gap: f64) -> Option<f64> {
    unshifted_paper_scroll_y(0.0, gap_top, gap)?;
    if !source_y.is_finite() || source_y < 0.0 {
        return None;
    }
    let y = source_y + if source_y > gap_top { gap } else { 0.0 };
    y.is_finite().then_some(y)
}

/// One active card, matching the current reader contract. `None` places it at the row foot.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PaperCard {
    pub page: u32,
    pub split_pt: Option<f64>,
    pub gap_pt: f64,
}

/// Source rows remain unchanged; only the display block grows and later rows move.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PaperDisplayRow {
    pub source: PageRow,
    pub display_top_pt: f64,
    pub display_height_pt: f64,
}

pub struct PaperDocumentLayout<'a> {
    source: &'a DocumentLayout,
    card: Option<PaperCard>,
    card_row: Option<(usize, PageRow)>,
    gap_top_pt: Option<f64>,
}

impl<'a> PaperDocumentLayout<'a> {
    pub fn new(
        source: &'a DocumentLayout,
        card: Option<PaperCard>,
    ) -> Result<Self, InvalidPaperGeometry> {
        if !source.content_height_pt().is_finite()
            || source.content_height_pt() < 0.0
            || !source.content_width_pt().is_finite()
            || source.content_width_pt() < 0.0
            || source.placements().iter().any(|page| {
                ![
                    page.top_pt,
                    page.left_pt,
                    page.width_pt,
                    page.height_pt,
                    page.bottom_pt(),
                ]
                .iter()
                .all(|value| value.is_finite())
                    || page.top_pt < 0.0
                    || page.width_pt <= 0.0
                    || page.height_pt <= 0.0
            })
        {
            return Err(InvalidPaperGeometry);
        }
        let Some(card_value) = card else {
            return Ok(Self {
                source,
                card,
                card_row: None,
                gap_top_pt: None,
            });
        };
        if !card_value.gap_pt.is_finite()
            || card_value.gap_pt < 0.0
            || !(source.content_height_pt() + card_value.gap_pt).is_finite()
        {
            return Err(InvalidPaperGeometry);
        }
        let page = source
            .placement(card_value.page)
            .ok_or(InvalidPaperGeometry)?;
        let index = usize::try_from(card_value.page).map_err(|_| InvalidPaperGeometry)?;
        let row = source
            .rows()
            .enumerate()
            .find(|(_, row)| index >= row.first_page && index < row.first_page + row.page_count)
            .ok_or(InvalidPaperGeometry)?;
        let gap_top = if let Some(split) = card_value.split_pt {
            // The existing shared paper map owns split validation and local transforms.
            PaperLayout::new(page.height_pt, Some(split), card_value.gap_pt)?;
            page.top_pt + split
        } else {
            // A page-foot fallback belongs to the whole row, including an unequal partner.
            row.1.bottom_pt
        };
        if !gap_top.is_finite() || !(gap_top + card_value.gap_pt).is_finite() {
            return Err(InvalidPaperGeometry);
        }
        Ok(Self {
            source,
            card,
            card_row: Some(row),
            gap_top_pt: Some(gap_top),
        })
    }

    pub fn card_row(&self) -> Option<usize> {
        self.card_row.map(|(index, _)| index)
    }
    pub fn gap_top_pt(&self) -> Option<f64> {
        self.gap_top_pt
    }
    pub fn gap_pt(&self) -> f64 {
        self.card.map_or(0.0, |card| card.gap_pt)
    }
    pub fn content_height_pt(&self) -> f64 {
        self.source.content_height_pt() + self.gap_pt()
    }

    pub fn rows(&self) -> impl ExactSizeIterator<Item = PaperDisplayRow> + '_ {
        self.source
            .rows()
            .enumerate()
            .map(|(index, source)| PaperDisplayRow {
                source,
                display_top_pt: source.top_pt
                    + if self.card_row().is_some_and(|owner| index > owner) {
                        self.gap_pt()
                    } else {
                        0.0
                    },
                display_height_pt: source.height_pt
                    + if self.card_row() == Some(index) {
                        self.gap_pt()
                    } else {
                        0.0
                    },
            })
    }

    /// Both facing partners retain their row top; only pages in a later row are shifted.
    pub fn page_top_pt(&self, page: u32) -> Option<f64> {
        let placement = self.source.placement(page)?;
        let index = usize::try_from(page).ok()?;
        let after = self
            .card_row
            .is_some_and(|(_, row)| index >= row.first_page + row.page_count);
        Some(placement.top_pt + if after { self.gap_pt() } else { 0.0 })
    }

    pub fn page_layout(&self, page: u32) -> Result<PaperLayout, InvalidPaperGeometry> {
        let placement = self.source.placement(page).ok_or(InvalidPaperGeometry)?;
        match self
            .card
            .filter(|card| card.page == page && card.split_pt.is_some())
        {
            Some(card) => PaperLayout::new(placement.height_pt, card.split_pt, card.gap_pt),
            None => PaperLayout::new(placement.height_pt, None, 0.0),
        }
    }

    pub fn page_height_pt(&self, page: u32) -> Option<f64> {
        let placement = self.source.placement(page)?;
        let torn = self
            .card
            .is_some_and(|card| card.page == page && card.split_pt.is_some());
        Some(placement.height_pt + if torn { self.gap_pt() } else { 0.0 })
    }

    /// Unclamped page anchors are distinct from strict pointer/region clipping.
    pub fn display_page_y(&self, page: u32, source_y: f64) -> Option<f64> {
        self.page_layout(page)
            .ok()?
            .display_y_at_origin(source_y, self.page_top_pt(page)?)
    }
    pub fn source_page_y(&self, page: u32, display_y: f64) -> Option<f64> {
        self.page_layout(page)
            .ok()?
            .paper_y_at_origin(display_y, self.page_top_pt(page)?)
    }

    /// Persist the scroll that would exist without the card, matching the reader's row-gap
    /// contract. A viewport in conversation space stores the cut/row foot, never a gap offset.
    /// This global reading offset is not a page point and must not be used to author marks.
    pub fn unshifted_scroll_y(&self, display_y: f64) -> Option<f64> {
        unshifted_paper_scroll_y(display_y, self.gap_top_pt.unwrap_or(0.0), self.gap_pt())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::LayoutMode;

    #[test]
    fn fractional_and_large_gaps_round_trip_source_anchors_in_both_layout_modes() {
        for mode in [LayoutMode::Continuous, LayoutMode::Facing] {
            let base = DocumentLayout::new_with_mode(
                [
                    (240.0, 330.25),
                    (500.0, 510.5),
                    (290.0, 720.75),
                    (430.0, 600.0),
                    (260.0, 480.125),
                ],
                12.75,
                mode,
            );
            let original = base.clone();
            for owner in 0..5 {
                let height = base.placement(owner).unwrap().height_pt;
                for split in [0.02, height / 2.0, height - 0.02] {
                    for gap in [0.0, 0.001, 80.25, 1200.5] {
                        let deck = PaperDocumentLayout::new(
                            &base,
                            Some(PaperCard {
                                page: owner,
                                split_pt: Some(split),
                                gap_pt: gap,
                            }),
                        )
                        .unwrap();
                        for page in 0..5 {
                            for y in [
                                0.0,
                                split - 0.01,
                                split,
                                split + 0.01,
                                height,
                                height + 200.0,
                            ] {
                                let display = deck.display_page_y(page, y).unwrap();
                                let restored = deck.source_page_y(page, display).unwrap_or_else(|| panic!("Missing inverse: {mode:?} owner {owner} page {page} split {split} gap {gap} y {y} display {display}"));
                                assert!(
                                    (restored - y).abs() < 1e-9,
                                    "{mode:?} owner {owner} page {page} split {split} gap {gap} y {y}"
                                );
                            }
                        }
                        if gap > 0.01 {
                            let in_gap = deck.gap_top_pt().unwrap() + gap / 2.0;
                            assert_eq!(deck.source_page_y(owner, in_gap), None);
                            assert_eq!(deck.unshifted_scroll_y(in_gap), deck.gap_top_pt());
                        }
                        assert_eq!(base, original);
                    }
                }
            }
        }
    }

    #[test]
    fn continuous_tear_moves_only_lower_paper_and_later_rows() {
        let base = DocumentLayout::new([(100.0, 300.0), (100.0, 400.0), (100.0, 500.0)], 20.0);
        let original = base.clone();
        let deck = PaperDocumentLayout::new(
            &base,
            Some(PaperCard {
                page: 1,
                split_pt: Some(150.0),
                gap_pt: 100.0,
            }),
        )
        .unwrap();
        let rows: Vec<_> = deck.rows().collect();
        assert_eq!(deck.card_row(), Some(1));
        assert_eq!(deck.gap_top_pt(), Some(470.0));
        assert_eq!(
            rows.iter()
                .map(|row| (row.display_top_pt, row.display_height_pt))
                .collect::<Vec<_>>(),
            [(0.0, 320.0), (320.0, 520.0), (840.0, 500.0)]
        );
        assert_eq!(deck.content_height_pt(), 1340.0);
        assert_eq!(deck.display_page_y(1, 100.0), Some(420.0));
        assert_eq!(deck.display_page_y(1, 250.0), Some(670.0));
        assert_eq!(deck.source_page_y(1, 670.0), Some(250.0));
        assert_eq!(deck.source_page_y(1, 520.0), None);
        assert_eq!(deck.unshifted_scroll_y(520.0), Some(470.0));
        assert_eq!(deck.unshifted_scroll_y(600.0), Some(500.0));
        assert_eq!(base, original);
        let closed = PaperDocumentLayout::new(&base, None).unwrap();
        assert_eq!(closed.content_height_pt(), 1240.0);
        assert_eq!(closed.page_top_pt(2), Some(740.0));
    }

    #[test]
    fn unequal_facing_partner_is_not_torn_or_shifted_with_its_owner() {
        let base = DocumentLayout::new_with_mode(
            [
                (100.0, 300.0),
                (100.0, 500.0),
                (100.0, 700.0),
                (100.0, 400.0),
            ],
            20.0,
            LayoutMode::Facing,
        );
        let deck = PaperDocumentLayout::new(
            &base,
            Some(PaperCard {
                page: 1,
                split_pt: Some(250.0),
                gap_pt: 100.0,
            }),
        )
        .unwrap();
        assert_eq!(deck.page_top_pt(1), Some(320.0));
        assert_eq!(deck.page_top_pt(2), Some(320.0));
        assert_eq!(deck.page_top_pt(3), Some(1140.0));
        assert_eq!(deck.display_page_y(1, 400.0), Some(820.0));
        assert_eq!(deck.display_page_y(2, 400.0), Some(720.0));
        assert_eq!(deck.source_page_y(1, 620.0), None);
        assert_eq!(deck.source_page_y(2, 620.0), Some(300.0));
        // Persisted global scroll and an authored point on the untorn partner are distinct.
        assert_eq!(deck.unshifted_scroll_y(620.0), Some(570.0));
        let foot = PaperDocumentLayout::new(
            &base,
            Some(PaperCard {
                page: 1,
                split_pt: None,
                gap_pt: 90.0,
            }),
        )
        .unwrap();
        assert_eq!(foot.gap_top_pt(), Some(1020.0));
        assert_eq!(foot.display_page_y(1, 400.0), Some(720.0));
        assert_eq!(foot.page_top_pt(3), Some(1130.0));
        assert_eq!(foot.unshifted_scroll_y(1060.0), Some(1020.0));
    }

    #[test]
    fn invalid_cards_fail_without_mutating_source_and_zero_gap_is_identity() {
        let base = DocumentLayout::new([(100.0, 300.0)], 12.0);
        for card in [
            PaperCard {
                page: 2,
                split_pt: None,
                gap_pt: 10.0,
            },
            PaperCard {
                page: 0,
                split_pt: Some(f64::NAN),
                gap_pt: 10.0,
            },
            PaperCard {
                page: 0,
                split_pt: Some(400.0),
                gap_pt: 10.0,
            },
            PaperCard {
                page: 0,
                split_pt: None,
                gap_pt: -1.0,
            },
            PaperCard {
                page: 0,
                split_pt: None,
                gap_pt: f64::INFINITY,
            },
        ] {
            assert!(PaperDocumentLayout::new(&base, Some(card)).is_err());
        }
        let deck = PaperDocumentLayout::new(
            &base,
            Some(PaperCard {
                page: 0,
                split_pt: Some(100.0),
                gap_pt: 0.0,
            }),
        )
        .unwrap();
        assert_eq!(deck.display_page_y(0, 200.0), Some(200.0));
        assert_eq!(deck.unshifted_scroll_y(200.0), Some(200.0));
        assert_eq!(deck.unshifted_scroll_y(-1.0), None);
        assert_eq!(deck.unshifted_scroll_y(f64::NAN), None);
        assert_eq!(deck.source_page_y(99, 0.0), None);
        assert_eq!(base.content_height_pt(), 300.0);
    }
}
