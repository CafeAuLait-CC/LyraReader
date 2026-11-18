//! Readable annotation context with source-index and UTF-16 offsets kept distinct.
//! PDF extraction, platform tokenizers, colours and sidebar presentation stay outside this map.
use crate::CharBox;
use lyra_reader_core::Rect;
use std::collections::BTreeMap;
use unicode_segmentation::UnicodeSegmentation;

pub const MAX_PASSAGE_GLYPHS: usize = 65_536;
const MAX_REGIONS: usize = 512;
const MAX_GEOMETRY_WORK: usize = 4 << 20;
const MAX_SENTENCES: usize = 8192;

/// Half-open UTF-16 range in the map's readable text, never a PDF character index.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PassageRange {
    pub start: u32,
    pub end: u32,
}

#[derive(Debug)]
pub struct AnnotationTextMap {
    text: String,
    offsets: BTreeMap<u32, PassageRange>,
    boxes: Vec<(u32, Rect)>,
    byte_offsets: Vec<Option<usize>>,
    sentences: Vec<PassageRange>,
    source_count: u32,
}
fn finite(r: Rect) -> bool {
    [
        r.min_x(),
        r.min_y(),
        r.max_x(),
        r.max_y(),
        r.size.width,
        r.size.height,
    ]
    .iter()
    .all(|v| v.is_finite())
}
impl AnnotationTextMap {
    /// Preserve the native reader's whitespace and paragraph-gap mapping. Invalid/null
    /// scalars do not acquire an offset, and wrapped lines remain in the same paragraph.
    pub fn new(chars: &[CharBox]) -> Result<Self, String> {
        if chars.len() > MAX_PASSAGE_GLYPHS {
            return Err("This page has too much text for annotation context.".into());
        }
        let mut text = String::new();
        let mut offsets = BTreeMap::new();
        let mut boxes = Vec::new();
        let mut position = 0u32;
        let mut previous_space = true;
        let mut line: Option<Rect> = None;
        let mut previous_line: Option<Rect> = None;
        for (index, glyph) in chars.iter().enumerate() {
            if !finite(glyph.rect) {
                return Err("Annotation context contains non-finite text geometry.".into());
            }
            let Some(scalar) = char::from_u32(glyph.unicode).filter(|c| *c != '\0') else {
                continue;
            };
            let index =
                u32::try_from(index).map_err(|_| "The annotation character index is invalid.")?;
            if glyph.rect.size.width > 0. && glyph.rect.size.height > 0. {
                boxes.push((index, glyph.rect));
            }
            if scalar.is_whitespace() {
                if scalar == '\n' || scalar == '\r' {
                    if line.is_some() {
                        previous_line = line;
                    }
                    line = None;
                }
                if !previous_space {
                    text.push(' ');
                    offsets.insert(
                        index,
                        PassageRange {
                            start: position,
                            end: position + 1,
                        },
                    );
                    position += 1;
                }
                previous_space = true;
            } else {
                if let Some(previous) = previous_line.filter(|_| glyph.rect.size.height > 0.) {
                    let threshold =
                        3f64.max(previous.size.height.min(glyph.rect.size.height) * 0.7);
                    if glyph.rect.min_y() - previous.max_y() > threshold
                        || glyph.rect.max_y() < previous.min_y() - threshold
                    {
                        if text.ends_with(' ') {
                            text.pop();
                            position -= 1;
                        }
                        text.push_str("\n\n");
                        position += 2;
                    } else if glyph.rect.min_y() < previous.max_y() {
                        line = Some(previous);
                    }
                }
                previous_line = None;
                if glyph.rect.size.height > 0. {
                    line = Some(line.map_or(glyph.rect, |r| r.union(glyph.rect)));
                }
                text.push(scalar);
                let end = position + scalar.len_utf16() as u32;
                offsets.insert(
                    index,
                    PassageRange {
                        start: position,
                        end,
                    },
                );
                position = end;
                previous_space = false;
            }
        }
        // Counts above bound the text to < 4 * MAX_PASSAGE_GLYPHS UTF-16 units;
        // only scalar boundaries receive a byte offset, protecting surrogate pairs.
        let mut byte_offsets = vec![None; position as usize + 1];
        let mut unit = 0usize;
        for (byte, scalar) in text.char_indices() {
            byte_offsets[unit] = Some(byte);
            unit += scalar.len_utf16();
        }
        byte_offsets[unit] = Some(text.len());
        let mut map = Self {
            text,
            offsets,
            boxes,
            byte_offsets,
            sentences: Vec::new(),
            source_count: chars.len() as u32,
        };
        let mut base = 0u32;
        for paragraph in map.text.split("\n\n") {
            let mut paragraph_units = 0u32;
            for (_, sentence) in paragraph.split_sentence_bound_indices() {
                let units = sentence.encode_utf16().count() as u32;
                if !sentence.trim().is_empty() {
                    let start = base + paragraph_units;
                    map.sentences.push(PassageRange {
                        start,
                        end: start + units,
                    });
                }
                paragraph_units += units;
            }
            base += paragraph_units + 2;
        }
        if map.sentences.is_empty() && !map.text.is_empty() {
            map.sentences.push(PassageRange {
                start: 0,
                end: position,
            });
        }
        Ok(map)
    }
    pub fn source_character_count(&self) -> u32 {
        self.source_count
    }
    pub fn text(&self) -> &str {
        &self.text
    }
    pub fn span_for_indices(&self, indices: &[u32]) -> Result<Option<PassageRange>, String> {
        if indices.len() > MAX_PASSAGE_GLYPHS {
            return Err("The annotation has too many source character indices.".into());
        }
        let mut result: Option<PassageRange> = None;
        for index in indices {
            if let Some(range) = self.offsets.get(index) {
                result = Some(result.map_or(*range, |r| PassageRange {
                    start: r.start.min(range.start),
                    end: r.end.max(range.end),
                }));
            }
        }
        Ok(result)
    }
    pub fn sentences(&self) -> &[PassageRange] {
        &self.sentences
    }
    pub fn span_for_range(&self, start: u32, end: u32) -> Result<Option<PassageRange>, String> {
        if start > end || end > self.source_count {
            return Err("The annotation source range is invalid.".into());
        }
        let mut ranges = self.offsets.range(start..end).map(|(_, r)| *r);
        let Some(first) = ranges.next() else {
            return Ok(None);
        };
        let last = ranges.next_back().unwrap_or(first);
        Ok(Some(PassageRange {
            start: first.start,
            end: last.end,
        }))
    }
    pub fn span_for_regions(&self, regions: &[Rect]) -> Result<Option<PassageRange>, String> {
        if regions.len() > MAX_REGIONS
            || self
                .boxes
                .len()
                .checked_mul(regions.len())
                .is_none_or(|n| n > MAX_GEOMETRY_WORK)
        {
            return Err("Annotation regions exceed the context work budget.".into());
        }
        if regions
            .iter()
            .any(|r| !finite(*r) || r.size.width <= 0. || r.size.height <= 0.)
        {
            return Err("Annotation context contains an invalid region.".into());
        }
        let mut span: Option<PassageRange> = None;
        for (index, glyph) in &self.boxes {
            if !regions.iter().any(|r| {
                let width = (glyph.max_x().min(r.max_x()) - glyph.min_x().max(r.min_x())).max(0.);
                let height = (glyph.max_y().min(r.max_y()) - glyph.min_y().max(r.min_y())).max(0.);
                // Divide first: finite, very large rectangles cannot overflow area products.
                (width / glyph.size.width) * (height / glyph.size.height) > 0.35
            }) {
                continue;
            }
            if let Some(range) = self.offsets.get(index) {
                span = Some(span.map_or(*range, |r| PassageRange {
                    start: r.start.min(range.start),
                    end: r.end.max(range.end),
                }));
            }
        }
        Ok(span)
    }
    pub fn slice(&self, range: PassageRange) -> Result<&str, String> {
        let start = self
            .byte_offsets
            .get(range.start as usize)
            .copied()
            .flatten();
        let end = self.byte_offsets.get(range.end as usize).copied().flatten();
        match (start, end) {
            (Some(start), Some(end)) if start <= end => Ok(&self.text[start..end]),
            _ => Err(
                "The annotation context range splits a Unicode scalar or exceeds the text.".into(),
            ),
        }
    }
    /// Native hosts can supply the system tokenizer's ranges to preserve its behaviour.
    /// Linux uses the existing pinned Unicode segmentation dependency by default.
    pub fn context(
        &self,
        mark: PassageRange,
        sentences: Option<&[PassageRange]>,
    ) -> Result<PassageRange, String> {
        self.slice(mark)?;
        let sentences = sentences.unwrap_or(&self.sentences);
        if sentences.len() > MAX_SENTENCES {
            return Err("The annotation has too many sentence boundaries.".into());
        }
        let mut previous = 0;
        let mut result = mark;
        for sentence in sentences {
            self.slice(*sentence)?;
            if sentence.start < previous || sentence.start >= sentence.end {
                return Err("The annotation sentence boundaries are not ordered.".into());
            }
            previous = sentence.end;
            if sentence.start < mark.end && mark.start < sentence.end {
                result.start = result.start.min(sentence.start);
                result.end = result.end.max(sentence.end);
            }
        }
        Ok(result)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub struct PassageCluster {
    pub span: PassageRange,
    pub indices: Vec<u32>,
}
/// Stable overlap grouping, preserving the source-mark order for equal starts.
pub fn cluster_passages(ranges: &[PassageRange]) -> Result<Vec<PassageCluster>, String> {
    if ranges.len() > 4096 || ranges.iter().any(|r| r.start >= r.end) {
        return Err("The annotation context ranges are invalid or too numerous.".into());
    }
    let mut order = (0..ranges.len()).collect::<Vec<_>>();
    order.sort_by_key(|i| ranges[*i].start);
    let mut result: Vec<PassageCluster> = Vec::new();
    for index in order {
        let next = ranges[index];
        if let Some(last) = result
            .last_mut()
            .filter(|last| last.span.start < next.end && next.start < last.span.end)
        {
            last.span.start = last.span.start.min(next.start);
            last.span.end = last.span.end.max(next.end);
            last.indices.push(index as u32);
        } else {
            result.push(PassageCluster {
                span: next,
                indices: vec![index as u32],
            });
        }
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use lyra_reader_core::Point;
    fn page(lines: &[(&str, f64)]) -> Vec<CharBox> {
        let mut out = Vec::new();
        for (i, (line, y)) in lines.iter().enumerate() {
            if i > 0 {
                out.push(CharBox {
                    unicode: 10,
                    rect: Rect::new(0., 0., 0., 0.),
                    origin: Point::new(0., 0.),
                    font_size: 10.,
                    logical_order: 0,
                });
            }
            for (x, c) in line.chars().enumerate() {
                out.push(CharBox {
                    unicode: c as u32,
                    rect: Rect::new(x as f64 * 10., *y, 10., 10.),
                    origin: Point::new(x as f64 * 10., *y),
                    font_size: 10.,
                    logical_order: 0,
                });
            }
        }
        out
    }
    #[test]
    fn wraps_join_but_paragraphs_and_column_restarts_do_not() {
        let chars = page(&[
            ("First line", 0.),
            ("continues here.", 12.),
            ("New paragraph.", 50.),
            ("New column.", 0.),
        ]);
        let map = AnnotationTextMap::new(&chars).unwrap();
        assert_eq!(
            map.text(),
            "First line continues here.\n\nNew paragraph.\n\nNew column."
        );
        let source = chars.iter().position(|c| c.unicode == 'N' as u32).unwrap() as u32;
        let span = map.span_for_range(source, source + 3).unwrap().unwrap();
        assert_eq!(map.slice(span).unwrap(), "New");
        assert_eq!(
            map.slice(map.context(span, None).unwrap()).unwrap(),
            "New paragraph."
        );
    }
    #[test]
    fn repeated_words_keep_their_source_ranges_and_unicode_scalars() {
        let chars = page(&[("😀same same. Next sentence!", 0.)]);
        let map = AnnotationTextMap::new(&chars).unwrap();
        let first = map.span_for_range(1, 5).unwrap().unwrap();
        let second = map.span_for_range(6, 10).unwrap().unwrap();
        assert_eq!(map.slice(first).unwrap(), "same");
        assert_eq!(map.slice(second).unwrap(), "same");
        assert_ne!(first, second);
        assert_eq!(first.start, 2);
        assert_eq!(second.start, 7);
        assert!(map.slice(PassageRange { start: 1, end: 2 }).is_err());
        let context = map.context(second, None).unwrap();
        assert_eq!(map.slice(context).unwrap().trim(), "😀same same.");
        assert_eq!(map.context(second, Some(&[second])).unwrap(), second);
    }
    #[test]
    fn file_owned_quads_use_strict_area_and_not_a_placeholder_zero_range() {
        let map = AnnotationTextMap::new(&page(&[("ABCD", 0.)])).unwrap();
        assert_eq!(
            map.span_for_regions(&[Rect::new(6.5, 0., 3.5, 10.)])
                .unwrap(),
            None
        );
        assert_eq!(
            map.slice(
                map.span_for_regions(&[Rect::new(26.4, 0., 3.6, 10.)])
                    .unwrap()
                    .unwrap()
            )
            .unwrap(),
            "C"
        );
        assert_eq!(
            map.slice(
                map.span_for_regions(&[Rect::new(0., 0., 10., 10.), Rect::new(30., 0., 10., 10.)])
                    .unwrap()
                    .unwrap()
            )
            .unwrap(),
            "ABCD"
        );
    }
    #[test]
    fn whitespace_invalid_scalars_and_unboxed_text_preserve_mapping_contract() {
        let mut chars = page(&[("  A\t\u{a0}B  ", 0.)]);
        chars.insert(
            0,
            CharBox {
                unicode: 0xd800,
                rect: Rect::new(0., 0., 0., 0.),
                origin: Point::new(0., 0.),
                font_size: 10.,
                logical_order: 0,
            },
        );
        let map = AnnotationTextMap::new(&chars).unwrap();
        assert_eq!(map.text(), "A B ");
        assert_eq!(map.span_for_range(0, 3).unwrap(), None);
        let mut no_box = page(&[("Text", 0.)]);
        no_box
            .iter_mut()
            .for_each(|c| c.rect = Rect::new(0., 0., 0., 0.));
        let map = AnnotationTextMap::new(&no_box).unwrap();
        assert_eq!(map.text(), "Text");
        assert_eq!(
            map.span_for_regions(&[Rect::new(0., 0., 100., 100.)])
                .unwrap(),
            None
        );
    }
    #[test]
    fn unsafe_geometry_and_ranges_report_errors_without_allocating_unbounded_work() {
        let mut chars = page(&[("abc", 0.)]);
        chars[0].rect = Rect::new(f64::NAN, 0., 2., 2.);
        assert!(AnnotationTextMap::new(&chars).is_err());
        let map = AnnotationTextMap::new(&page(&[("Hello. More!", 0.)])).unwrap();
        assert!(map.span_for_range(0, 100).is_err());
        assert!(
            map.span_for_regions(&vec![Rect::new(0., 0., 1., 1.); MAX_REGIONS + 1])
                .is_err()
        );
        assert!(
            map.context(
                PassageRange { start: 0, end: 1 },
                Some(&[
                    PassageRange { start: 7, end: 12 },
                    PassageRange { start: 0, end: 6 }
                ])
            )
            .is_err()
        );
        let mut chars = page(&[("x", 0.)]);
        chars.resize(MAX_PASSAGE_GLYPHS + 1, chars[0]);
        assert!(AnnotationTextMap::new(&chars).is_err());
    }
    #[test]
    fn overlapping_sentence_contexts_merge_stably_but_adjacent_sentences_remain_separate() {
        let result = cluster_passages(&[
            PassageRange { start: 10, end: 20 },
            PassageRange { start: 0, end: 10 },
            PassageRange { start: 12, end: 14 },
            PassageRange { start: 10, end: 18 },
        ])
        .unwrap();
        assert_eq!(
            result,
            vec![
                PassageCluster {
                    span: PassageRange { start: 0, end: 10 },
                    indices: vec![1]
                },
                PassageCluster {
                    span: PassageRange { start: 10, end: 20 },
                    indices: vec![0, 3, 2]
                }
            ]
        );
        assert!(cluster_passages(&[PassageRange { start: 1, end: 0 }]).is_err());
    }
}
