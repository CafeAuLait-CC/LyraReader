//! Conservative display headings for full bibliography entries.
//!
//! This is the shared production rule used by both native shells. It does not infer trusted
//! bibliographic metadata: entries without an unambiguous author/title sentence boundary keep
//! a neutral UI heading, and their complete original text remains available for copying.

use crate::is_swift_whitespace_or_newline;
use unicode_segmentation::UnicodeSegmentation;

// Unicode 16.0 decimal-digit (Nd) blocks, each containing ten consecutive scalars. The old
// Foundation prefix regex used Unicode \d, not just ASCII digits or the broader numeric class.
const MAX_TITLE_BYTES: usize = 16 * 1024;

const DECIMAL_STARTS: &[u32] = &[
    0x30, 0x660, 0x6F0, 0x7C0, 0x966, 0x9E6, 0xA66, 0xAE6, 0xB66, 0xBE6, 0xC66, 0xCE6, 0xD66,
    0xDE6, 0xE50, 0xED0, 0xF20, 0x1040, 0x1090, 0x17E0, 0x1810, 0x1946, 0x19D0, 0x1A80, 0x1A90,
    0x1B50, 0x1BB0, 0x1C40, 0x1C50, 0xA620, 0xA8D0, 0xA900, 0xA9D0, 0xA9F0, 0xAA50, 0xABF0, 0xFF10,
    0x104A0, 0x10D30, 0x10D40, 0x11066, 0x110F0, 0x11136, 0x111D0, 0x112F0, 0x11450, 0x114D0,
    0x11650, 0x116C0, 0x116D0, 0x116DA, 0x11730, 0x118E0, 0x11950, 0x11BF0, 0x11C50, 0x11D50,
    0x11DA0, 0x11F50, 0x16130, 0x16A60, 0x16AC0, 0x16B50, 0x16D70, 0x1CCF0, 0x1D7CE, 0x1D7D8,
    0x1D7E2, 0x1D7EC, 0x1D7F6, 0x1E140, 0x1E2F0, 0x1E4F0, 0x1E5F1, 0x1E950, 0x1FBF0,
];

fn decimal_digit(character: char) -> bool {
    let scalar = character as u32;
    let index = DECIMAL_STARTS.partition_point(|start| *start <= scalar);
    index > 0 && scalar - DECIMAL_STARTS[index - 1] < 10
}

fn without_numeric_label(raw: &str) -> &str {
    let text = raw.trim_start_matches(char::is_whitespace);
    let digits = text.strip_prefix('[').unwrap_or(text);
    let rest = digits.trim_start_matches(decimal_digit);
    if digits.len() == rest.len() {
        return raw;
    }
    let rest = rest.strip_prefix(']').unwrap_or(rest);
    let rest = rest.strip_prefix('.').unwrap_or(rest);
    let trimmed = rest.trim_start_matches(char::is_whitespace);
    if rest.len() == trimmed.len() {
        raw
    } else {
        trimmed
    }
}

fn initials(token: &str) -> bool {
    !token.is_empty()
        && token.len() % 2 == 1
        && token.bytes().enumerate().all(|(index, byte)| {
            if index % 2 == 0 {
                byte.is_ascii_uppercase()
            } else {
                byte == b'.'
            }
        })
}

/// A title only when two sentence boundaries clearly delimit it, preserving the source bytes.
///
/// Author initials and the existing Foundation rule's common suffixes do not split a sentence.
/// The 400-character limit counts extended grapheme clusters, matching Swift `String.count`.
/// A 16 KiB UTF-8 ceiling also rejects pathological combining sequences before serialization.
/// The input is borrowed and scanned before any output allocation; file-controlled length does
/// not become an intermediate list of all punctuation matches.
pub fn reference_preview_title(raw: &str) -> Option<&str> {
    let text = without_numeric_label(raw);
    let mut first = None;
    for (offset, character) in text.char_indices() {
        if !matches!(character, '.' | '!' | '?') {
            continue;
        }
        let end = offset + character.len_utf8();
        let suffix = &text[end..];
        let final_line_break = matches!(
            suffix,
            "\n" | "\r" | "\r\n" | "\u{85}" | "\u{2028}" | "\u{2029}"
        );
        if !suffix.is_empty()
            && !final_line_break
            && (!suffix.starts_with(char::is_whitespace)
                || suffix.trim_start_matches(char::is_whitespace).is_empty())
        {
            continue;
        }
        let token = text[..offset]
            .rsplit(|ch: char| is_swift_whitespace_or_newline(ch as u32))
            .next()
            .unwrap_or(""); // A split iterator always yields at least the possibly empty token.
        if matches!(token, "Jr" | "Sr" | "Dr" | "Prof" | "vs" | "e.g" | "i.e") || initials(token) {
            continue;
        }
        let Some(start) = first else {
            first = Some(end);
            continue;
        };
        let title =
            text[start..end].trim_matches(|ch: char| is_swift_whitespace_or_newline(ch as u32));
        if title.len() > MAX_TITLE_BYTES
            || title.split_whitespace().take(3).count() < 3
            || title.graphemes(true).take(401).count() > 400
        {
            return None;
        }
        let prefix: String = title
            .chars()
            .take(12)
            .flat_map(char::to_lowercase)
            .collect();
        return (!prefix.starts_with("in ") && !prefix.starts_with("proceedings "))
            .then_some(title);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frozen_native_citation_headings() {
        for (raw, title) in [
            (
                "Yaron Lipman, Ricky T. Q. Chen, Heli Ben-Hamu, Maximilian Nickel, and Matt Le. Flow matching for generative modeling. In International Conference on Learning Representations, 2023.",
                Some("Flow matching for generative modeling."),
            ),
            (
                "[12] A. Author and B. Writer. A useful research title. Journal, 2024.",
                Some("A useful research title."),
            ),
            (
                "12. A. Author. A useful research title. Journal, 2024.",
                Some("A useful research title."),
            ),
            (
                "[١٢]. Dr. A.B. Author Jr. and Prof. C. Writer Sr. Example. A useful research title! Journal, 2024.",
                Some("A useful research title!"),
            ),
            (
                "[１２] A. Author. A title vs. another title? Venue.",
                Some("A title vs. another title?"),
            ),
            ("A. Author. A useful research title.   ", None),
            (
                "A. Author. A useful research title.\n",
                Some("A useful research title."),
            ),
            (
                "A. Author. A useful research title.",
                Some("A useful research title."),
            ),
            ("A. Author. In a conference proceedings. Venue.", None),
            ("A. Author. Proceedings of a conference. Venue.", None),
            ("A. Author. Two words. Venue.", None),
            ("Unstructured citation", None),
            ("", None),
            (
                "A. Author. <b>A useful title</b>. Venue.",
                Some("<b>A useful title</b>."),
            ),
            (
                "A. Author. \u{200b}A useful research title. Venue.",
                Some("A useful research title."),
            ),
        ] {
            assert_eq!(reference_preview_title(raw), title, "{raw:?}");
        }
    }

    #[test]
    fn grapheme_limit_preserves_decomposed_and_joined_characters() {
        let cluster = "e\u{301}";
        let title = format!("A title {}.", cluster.repeat(391));
        assert_eq!(title.graphemes(true).count(), 400);
        let raw = format!("A. Author. {title} Venue.");
        assert_eq!(reference_preview_title(&raw), Some(title.as_str()));
        let long = format!("A. Author. A title {}. Venue.", cluster.repeat(392));
        assert_eq!(reference_preview_title(&long), None);
        let joined = format!("A. Author. A title {}. Venue.", "👩‍🔬".repeat(391));
        assert!(reference_preview_title(&joined).is_some());
        let oversized = format!(
            "A. Author. A title e{}. Venue.",
            "\u{301}".repeat(MAX_TITLE_BYTES)
        );
        assert_eq!(reference_preview_title(&oversized), None);
    }

    #[test]
    fn numeric_label_requires_decimal_digits_and_a_trailing_space() {
        assert_eq!(without_numeric_label("  [١٢]. A. Author."), "A. Author.");
        assert_eq!(without_numeric_label("[²] A. Author."), "[²] A. Author.");
        assert_eq!(without_numeric_label("12.Author."), "12.Author.");
        assert_eq!(
            without_numeric_label("[12]\u{200b}Author."),
            "[12]\u{200b}Author."
        );
        for start in DECIMAL_STARTS {
            assert!(decimal_digit(char::from_u32(*start).unwrap()));
            assert!(decimal_digit(char::from_u32(*start + 9).unwrap()));
        }
    }
}
