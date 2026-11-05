//! Shared printed labels for captions, mentions, and numbered equations.

/// A number, dotted chapter number, or appendix-prefixed number. A trailing sentence period
/// stays outside the label; `3.1` must never resolve as `3`.
pub(crate) fn label_len(chars: &[char]) -> Option<usize> {
    let mut end = 0;
    if chars.first().is_some_and(char::is_ascii_uppercase) {
        end = 1;
        if chars.get(end) == Some(&'.') {
            end += 1;
        }
    }
    let digits = end;
    while chars.get(end).is_some_and(char::is_ascii_digit) {
        end += 1;
    }
    if end == digits {
        return None;
    }
    while chars.get(end) == Some(&'.') && chars.get(end + 1).is_some_and(char::is_ascii_digit) {
        end += 1;
        while chars.get(end).is_some_and(char::is_ascii_digit) {
            end += 1;
        }
    }
    Some(end)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn labels_preserve_chapters_and_appendices_without_sentence_punctuation() {
        for (text, expected) in [
            ("1.1:", "1.1"),
            ("A.4.", "A.4"),
            ("S12 shows", "S12"),
            ("3.", "3"),
        ] {
            let chars: Vec<_> = text.chars().collect();
            assert_eq!(
                chars[..label_len(&chars).unwrap()]
                    .iter()
                    .collect::<String>(),
                expected
            );
        }
        for text in ["A.", "", "alpha", ".12"] {
            assert!(label_len(&text.chars().collect::<Vec<_>>()).is_none());
        }
    }
}
