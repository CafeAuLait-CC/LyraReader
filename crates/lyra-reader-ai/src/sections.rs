//! Outline → layered-summary section planning.
//!
//! The shell used to derive the section layer's page ranges and titles from the outline
//! (`AISummaryModel.swift`, `AISummarySections.sections`). The plan is domain logic: it decides
//! which outline entries are structure, fills a missing destination from its neighbours, numbers
//! the rows and falls back to fixed page ranges when there is no outline. Keeping it here lets the
//! Rust summary builder and the shell speak about the same rows without a second implementation.
//!
//! The rules are a straight port, including the places that look surprising:
//!
//! * reader bookmarks are excluded — they are marks, not document structure;
//! * an entry without its own destination starts where its first descendant does, or where the
//!   previous destination was when nothing follows;
//! * a section ends at the page before the next entry that starts on a later page, so leaf
//!   sections on one page overlap (the outline says both start there);
//! * an outline with no usable destination anywhere falls back to ten-page ranges.
//!
//! Page numbers here are 1-based and inclusive (`link_page` is 0-based), matching
//! [`crate::SummaryUnitRequest`].

/// Pages per fallback section when the document has no usable outline. Ten pages is one compact
/// request and keeps the section layer navigable for a scanned or outline-less paper.
pub const FALLBACK_PAGES_PER_SECTION: u32 = 10;

/// One outline entry as the shell's flattened sidebar model holds it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SummaryOutlineEntry {
    pub title: String,
    /// Target page (0-based), when the destination resolves to one.
    pub page: Option<u32>,
    /// Nesting level; 0 is a top-level entry.
    pub depth: u32,
    /// The cached bookmark's UUID when this entry belongs to the reader's own saved subtree.
    pub bookmark_id: Option<String>,
    /// True for the top-level `My bookmarks` node the reader wrote.
    pub is_bookmark_subtree: bool,
}

/// One section row: what the panel shows and what its request asks for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SummarySection {
    /// Row title, including the outline number when there is one ("2.1 Method").
    pub title: String,
    /// Outline number when the row came from an outline; empty for fallback rows.
    pub number: String,
    pub depth: u32,
    /// 1-based, inclusive.
    pub page_start: u32,
    /// 1-based, inclusive.
    pub page_end: u32,
    /// 0-based page a click on this row opens.
    pub link_page: u32,
}

/// One numbered outline row. Numbering is depth-first: `1`, `1.1`, `1.1.1`, then `2`, `2.1`, …
fn numbered_rows<'a>(
    entries: &[&'a SummaryOutlineEntry],
) -> Vec<(String, &'a SummaryOutlineEntry)> {
    let mut counters: Vec<u32> = Vec::new();
    let mut rows = Vec::with_capacity(entries.len());
    for entry in entries {
        let depth = entry.depth as usize;
        while counters.len() <= depth {
            counters.push(0);
        }
        counters[depth] += 1;
        if counters.len() > depth + 1 {
            counters.truncate(depth + 1);
        }
        let number = counters
            .iter()
            .map(u32::to_string)
            .collect::<Vec<_>>()
            .join(".");
        rows.push((number, *entry));
    }
    rows
}

fn fallback_title(start: u32, end: u32) -> String {
    if start == end {
        format!("Page {start}")
    } else {
        format!("Pages {start}-{end}")
    }
}

fn fallback_sections(page_count: u32) -> Vec<SummarySection> {
    let mut sections = Vec::new();
    let mut start = 1u32;
    while start <= page_count {
        let end = start
            .saturating_add(FALLBACK_PAGES_PER_SECTION.saturating_sub(1))
            .min(page_count);
        sections.push(SummarySection {
            title: fallback_title(start, end),
            number: String::new(),
            depth: 0,
            page_start: start,
            page_end: end,
            link_page: start - 1,
        });
        start = end.saturating_add(1);
    }
    sections
}

/// Turn a flattened outline into section page ranges.
pub fn plan_summary_sections(
    outline: &[SummaryOutlineEntry],
    page_count: u32,
) -> Vec<SummarySection> {
    if page_count == 0 {
        return Vec::new();
    }
    let usable: Vec<&SummaryOutlineEntry> = outline
        .iter()
        .filter(|entry| entry.bookmark_id.is_none() && !entry.is_bookmark_subtree)
        .collect();
    let rows = numbered_rows(&usable);
    if rows.is_empty() {
        return fallback_sections(page_count);
    }

    let mut resolved: Vec<Option<u32>> = rows
        .iter()
        .map(|(_, entry)| entry.page.filter(|page| *page < page_count))
        .collect();
    // Fill a missing destination from the next entry that has one; if none follows, use the
    // previous destination so the entry still points somewhere sensible.
    for index in 0..resolved.len() {
        if resolved[index].is_some() {
            continue;
        }
        if let Some(next) = resolved[index + 1..].iter().find_map(|value| *value) {
            resolved[index] = Some(next);
        } else if index > 0 {
            resolved[index] = resolved[..index].iter().rev().find_map(|value| *value);
        }
    }
    if resolved.iter().all(Option::is_none) {
        return fallback_sections(page_count);
    }

    let mut sections = Vec::new();
    for index in 0..rows.len() {
        let Some(start) = resolved[index] else {
            continue;
        };
        let next_later = resolved[index + 1..]
            .iter()
            .filter_map(|value| *value)
            .find(|page| *page > start);
        let end = next_later
            .map(|page| (page - 1).min(page_count - 1))
            .unwrap_or(page_count - 1);
        let (number, entry) = &rows[index];
        let title = if number.is_empty() {
            entry.title.clone()
        } else {
            format!("{number} {}", entry.title)
        };
        sections.push(SummarySection {
            title,
            number: number.clone(),
            depth: entry.depth,
            page_start: start + 1,
            page_end: end.max(start) + 1,
            link_page: start,
        });
    }
    sections
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(title: &str, page: Option<u32>, depth: u32) -> SummaryOutlineEntry {
        SummaryOutlineEntry {
            title: title.to_string(),
            page,
            depth,
            bookmark_id: None,
            is_bookmark_subtree: false,
        }
    }

    #[test]
    fn no_outline_falls_back_to_ten_page_ranges() {
        let sections = plan_summary_sections(&[], 120);
        assert_eq!(sections.len(), 12);
        assert_eq!(sections[0].title, "Pages 1-10");
        assert_eq!((sections[0].page_start, sections[0].page_end), (1, 10));
        assert_eq!(sections[11].title, "Pages 111-120");
        assert_eq!((sections[11].page_start, sections[11].page_end), (111, 120));
        assert_eq!(sections[11].link_page, 110);
        assert!(sections.iter().all(|section| section.number.is_empty()));
        assert_eq!(
            plan_summary_sections(&[], 1)
                .into_iter()
                .map(|section| section.title)
                .collect::<Vec<_>>(),
            vec!["Page 1"]
        );
        assert!(plan_summary_sections(&[], 0).is_empty());
    }

    #[test]
    fn numbering_fills_missing_destinations_and_overlaps_same_page_leaves() {
        let outline = vec![
            entry("Chapter One", Some(0), 0),
            entry("Background", None, 1),
            entry("Prior work", Some(1), 2),
            entry("Chapter Two", None, 0),
            entry("Method", None, 1),
            entry("Detail", Some(2), 2),
            entry("Setup", None, 1),
        ];
        let sections = plan_summary_sections(&outline, 3);
        assert_eq!(
            sections
                .iter()
                .map(|section| (section.title.as_str(), section.page_start, section.page_end))
                .collect::<Vec<_>>(),
            vec![
                ("1 Chapter One", 1, 1),
                ("1.1 Background", 2, 2),
                ("1.1.1 Prior work", 2, 2),
                ("2 Chapter Two", 3, 3),
                ("2.1 Method", 3, 3),
                ("2.1.1 Detail", 3, 3),
                ("2.2 Setup", 3, 3),
            ]
        );
        assert_eq!(
            sections
                .iter()
                .map(|section| section.number.as_str())
                .collect::<Vec<_>>(),
            vec!["1", "1.1", "1.1.1", "2", "2.1", "2.1.1", "2.2"]
        );
    }

    #[test]
    fn trailing_entries_without_a_destination_reuse_the_previous_page() {
        let outline = vec![entry("One", Some(0), 0), entry("Two", None, 0)];
        let sections = plan_summary_sections(&outline, 3);
        assert_eq!(sections.len(), 2);
        assert_eq!((sections[0].page_start, sections[0].page_end), (1, 3));
        assert_eq!((sections[1].page_start, sections[1].page_end), (1, 3));
        assert_eq!(sections[1].link_page, 0);
    }

    #[test]
    fn reader_bookmarks_are_not_document_structure() {
        let mut bookmark = entry("My bookmarks", None, 0);
        bookmark.is_bookmark_subtree = true;
        let mut child = entry("Saved place", Some(1), 1);
        child.bookmark_id = Some("id".to_string());
        let sections = plan_summary_sections(&[bookmark, child], 2);
        assert_eq!(sections.len(), 1);
        assert_eq!(sections[0].title, "Pages 1-2");
        assert_eq!(sections[0].number, "");
    }

    #[test]
    fn out_of_range_destinations_fall_back_instead_of_naming_a_missing_page() {
        let outline = vec![entry("Only", Some(9), 0)];
        let sections = plan_summary_sections(&outline, 2);
        assert_eq!(sections.len(), 1);
        assert_eq!(sections[0].title, "Pages 1-2");
        assert_eq!((sections[0].page_start, sections[0].page_end), (1, 2));
    }
}
