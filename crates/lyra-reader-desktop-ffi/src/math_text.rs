//! Convert portable math nodes to the Qt rich-text subset. The provider can supply
//! characters only; every tag and property is chosen by this adapter.
use crate::{Buffer, bytes, run};
use lyra_reader_ai::math::inline::{Node, Style, formulas};
use serde::Serialize;

const MAX_RESPONSE_BYTES: usize = 128 * 1024;

#[derive(Serialize)]
struct MarkupSpan {
    start: usize,
    end: usize,
    markup: String,
}

fn spans(text: &str) -> Vec<MarkupSpan> {
    let mut previous_byte = 0;
    let mut previous_utf16 = 0;
    formulas(text)
        .into_iter()
        .map(|formula| {
            let start = previous_utf16
                + text[previous_byte..formula.range.start]
                    .encode_utf16()
                    .count();
            let source = &text[formula.range.clone()];
            let end = start + source.encode_utf16().count();
            previous_byte = formula.range.end;
            previous_utf16 = end;
            let mut markup = String::new();
            if let Some(expression) = formula.expression {
                if formula.display {
                    markup.push_str("<br/>");
                }
                write_node(&expression, None, &mut markup);
                if formula.display {
                    markup.push_str("<br/>");
                }
            } else {
                for ch in source.chars() {
                    escape(ch, &mut markup);
                }
            }
            MarkupSpan { start, end, markup }
        })
        .collect()
}

fn escape(ch: char, markup: &mut String) {
    match ch {
        '&' => markup.push_str("&amp;"),
        '<' => markup.push_str("&lt;"),
        '>' => markup.push_str("&gt;"),
        '\n' => markup.push_str("<br/>"),
        ch => markup.push(ch),
    }
}

fn write_node(node: &Node, alphabet: Option<&Style>, markup: &mut String) {
    match node {
        Node::Text(text) => {
            for ch in text.chars() {
                let ch = alphabet
                    .and_then(|style| styled_letter(style, ch))
                    .unwrap_or(ch);
                escape(ch, markup);
            }
        }
        Node::Row(nodes) => {
            for node in nodes {
                write_node(node, alphabet, markup);
            }
        }
        Node::Fraction(numerator, denominator) => {
            markup.push_str("<sup>");
            write_node(numerator, alphabet, markup);
            markup.push_str("</sup>⁄<sub>");
            write_node(denominator, alphabet, markup);
            markup.push_str("</sub>");
        }
        Node::Root(value) => {
            markup.push_str("√(");
            write_node(value, alphabet, markup);
            markup.push(')');
        }
        Node::Styled(style @ (Style::Script | Style::DoubleStruck), value) => {
            // These alphabets are encoded with Unicode's mathematical letterforms.
            write_node(value, Some(style), markup);
        }
        Node::Styled(style, value) => {
            let (open, close) = match style {
                Style::Regular => ("<span style=\"font-style:normal\">", "</span>"),
                Style::Italic => ("<i>", "</i>"),
                Style::Bold => ("<b>", "</b>"),
                Style::Mono => ("<tt>", "</tt>"),
                Style::Sans => ("<span style=\"font-family:sans-serif\">", "</span>"),
                Style::Script | Style::DoubleStruck => ("", ""),
            };
            markup.push_str(open);
            write_node(value, None, markup);
            markup.push_str(close);
        }
        Node::Scripts {
            base,
            subscript,
            superscript,
        } => {
            write_node(base, alphabet, markup);
            if let Some(subscript) = subscript {
                markup.push_str("<sub>");
                write_node(subscript, alphabet, markup);
                markup.push_str("</sub>");
            }
            if let Some(superscript) = superscript {
                markup.push_str("<sup>");
                write_node(superscript, alphabet, markup);
                markup.push_str("</sup>");
            }
        }
    }
}

fn styled_letter(style: &Style, ch: char) -> Option<char> {
    const SCRIPT_UPPER: &str = "𝒜ℬ𝒞𝒟ℰℱ𝒢ℋℐ𝒥𝒦ℒℳ𝒩𝒪𝒫𝒬ℛ𝒮𝒯𝒰𝒱𝒲𝒳𝒴𝒵";
    const SCRIPT_LOWER: &str = "𝒶𝒷𝒸𝒹ℯ𝒻ℊ𝒽𝒾𝒿𝓀𝓁𝓂𝓃ℴ𝓅𝓆𝓇𝓈𝓉𝓊𝓋𝓌𝓍𝓎𝓏";
    const DOUBLE_UPPER: &str = "𝔸𝔹ℂ𝔻𝔼𝔽𝔾ℍ𝕀𝕁𝕂𝕃𝕄ℕ𝕆ℙℚℝ𝕊𝕋𝕌𝕍𝕎𝕏𝕐ℤ";
    match (style, ch) {
        (Style::Script, 'A'..='Z') => SCRIPT_UPPER.chars().nth((ch as u32 - 'A' as u32) as usize),
        (Style::Script, 'a'..='z') => SCRIPT_LOWER.chars().nth((ch as u32 - 'a' as u32) as usize),
        (Style::DoubleStruck, 'A'..='Z') => {
            DOUBLE_UPPER.chars().nth((ch as u32 - 'A' as u32) as usize)
        }
        (Style::DoubleStruck, 'a'..='z') => char::from_u32(0x1D552 + (ch as u32 - 'a' as u32)),
        (Style::DoubleStruck, '0'..='9') => char::from_u32(0x1D7D8 + (ch as u32 - '0' as u32)),
        _ => None,
    }
}

/// Format complete bounded math spans without opening documents or accessing the network.
/// Output is JSON with UTF-16 offsets for the native text field.
/// # Safety
/// Text addresses length readable bytes. Output and error are distinct, empty, aligned,
/// writable Buffer slots, each freed once by the caller.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_math_markup(
    text: *const u8,
    length: usize,
    output: *mut Buffer,
    error: *mut Buffer,
) -> bool {
    // SAFETY: the caller owns the disjoint slots and borrowed input. The size bound
    // is applied before the slice, tokenization, or allocating output.
    unsafe {
        run(error, || {
            if output.is_null() || length > MAX_RESPONSE_BYTES {
                return Err("The response exceeds the native mathematics display limit.".into());
            }
            let text = std::str::from_utf8(bytes(text, length)?).map_err(|e| e.to_string())?;
            let result = serde_json::to_vec(&spans(text)).map_err(|e| e.to_string())?;
            output.write(Buffer::owned(result));
            Ok(())
        })
    }
    .is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markup_respects_utf16_offsets_escapes_text_and_keeps_native_scripts() {
        let text = r"🙂 \(\mathcal J_{fit}=\frac{\alpha}{\beta}\) \[\text{<img src=x>}\tag{3}\]";
        let spans = spans(text);
        assert_eq!(spans.len(), 2);
        assert_eq!(spans[0].start, 3);
        assert_eq!(spans[0].markup, "𝒥<sub>fit</sub>=<sup>α</sup>⁄<sub>β</sub>");
        assert!(spans[1].markup.contains("&lt;img src=x&gt;"));
        assert!(spans[1].markup.contains("(3)"));
        let original: Vec<_> = text.encode_utf16().collect();
        assert_eq!(
            String::from_utf16(&original[spans[0].start..spans[0].end]).unwrap(),
            r"\(\mathcal J_{fit}=\frac{\alpha}{\beta}\)"
        );
    }
}
