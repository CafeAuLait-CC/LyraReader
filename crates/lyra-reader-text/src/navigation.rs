//! Navigation lists are jump targets, rather than citation/figure preview surfaces.

use lyra_reader_core::RawTextPage;

/// Recognise a contents/list heading, including the running heading on continuation pages.
/// Requiring the entire heading keeps prose such as "The contents of this section" out.
pub fn is_navigation_page(page: &RawTextPage) -> bool {
    page.text.lines().take(8).any(|line| {
        let compact: String = line
            .chars()
            .filter(|c| !c.is_whitespace())
            .flat_map(char::to_lowercase)
            .collect();
        matches!(
            compact.as_str(),
            "contents"
                | "tableofcontents"
                | "listoffigures"
                | "listoftables"
                | "listofalgorithms"
                | "目录"
                | "目次"
                | "图目录"
                | "表目录"
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn contents_and_continued_lists_navigate_but_body_references_do_not() {
        for text in [
            "Table of Contents\nChapter 1 ... 3",
            "TABLE OF CONTENTS\n2.2.4 ... 38",
            "List of Figures\nFigure 1.1 ... 1",
            "目录\n第一章 ... 1",
        ] {
            assert!(is_navigation_page(&crate::test_page(text)));
        }
        for text in [
            "The contents of this section are illustrated in Figure 1.1.",
            "References\n[1] A. Example. Paper title.",
            "1. Introduction\nSee page 12.",
        ] {
            assert!(!is_navigation_page(&crate::test_page(text)));
        }
    }
}
