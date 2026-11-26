//! Convert portable math nodes to the Qt rich-text subset. The provider can supply
//! characters only; every tag and property is chosen by this adapter.
use crate::{Buffer, bytes, run};
use lyra_reader_ai::math::inline::{Alignment, Node, Style, formulas};
use serde::Serialize;

const MAX_RESPONSE_BYTES: usize = 128 * 1024;

#[derive(Serialize)]
struct MarkupSpan {
    start: usize,
    end: usize,
    markup: String,
    // Presentation metadata only; existing UTF-16 ranges and markup remain
    // unchanged. Callers must not infer parse success from displayed text.
    rendered: bool,
    display: bool,
    source: String,
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
            let body = text[formula.content_range.clone()].to_owned();
            let end = start + source.encode_utf16().count();
            previous_byte = formula.range.end;
            previous_utf16 = end;
            let rendered = formula.expression.is_some();
            let mut markup = String::new();
            if let Some(expression) = formula.expression {
                if formula.display {
                    write_display(&expression, &mut markup);
                } else {
                    write_node(&expression, None, &mut markup);
                }
            } else {
                for ch in source.chars() {
                    escape(ch, &mut markup);
                }
            }
            MarkupSpan {
                start,
                end,
                markup,
                rendered,
                display: formula.display,
                source: body,
            }
        })
        .collect()
}

fn write_display(node: &Node, markup: &mut String) {
    if let Node::Row(children) = node {
        if let [Node::Fraction(numerator, denominator)] = children.as_slice() {
            // Native tables are already block elements. No extra blank lines are
            // needed, and the rule inherits the native document foreground.
            markup.push_str(
                r#"<table align="center" cellspacing="0" cellpadding="1"><tr><td align="center">"#,
            );
            write_node(numerator, None, markup);
            markup.push_str(r#"</td></tr><tr><td><hr /></td></tr><tr><td align="center">"#);
            write_node(denominator, None, markup);
            markup.push_str("</td></tr></table>");
            return;
        }
        let mut grids = children
            .iter()
            .enumerate()
            .filter(|(_, child)| matches!(child, Node::Grid { .. }));
        if let Some((
            index,
            Node::Grid {
                rows,
                columns,
                left,
                right,
            },
        )) = grids.next()
            && grids.next().is_none()
        {
            // Keep an adjacent expression such as A= aligned with the grid itself.
            write_grid(
                rows,
                columns,
                left,
                right,
                &children[..index],
                &children[index + 1..],
                markup,
            );
            return;
        }
    }
    markup.push_str("<br/>");
    write_node(node, None, markup);
    markup.push_str("<br/>");
}

fn write_grid(
    rows: &[Vec<Node>],
    columns: &[Alignment],
    left: &str,
    right: &str,
    prefix: &[Node],
    suffix: &[Node],
    markup: &mut String,
) {
    fn row_span(rows: usize, markup: &mut String) {
        markup.push_str(r#"<td align="center" valign="middle" rowspan=""#);
        markup.push_str(&rows.to_string());
        markup.push_str(r#"">"#);
    }

    fn enclosure(glyph: &str, rows: usize, markup: &mut String) {
        if glyph.is_empty() {
            return;
        }
        row_span(rows, markup);
        markup.push_str(r#"<span style="font-size:"#);
        markup.push_str(&(12 + 12 * rows).to_string());
        markup.push_str(r#"px">"#);
        markup.push_str(glyph);
        markup.push_str("</span></td>");
    }

    fn side(nodes: &[Node], rows: usize, markup: &mut String) {
        if nodes.is_empty() {
            return;
        }
        row_span(rows, markup);
        for node in nodes {
            write_node(node, None, markup);
        }
        markup.push_str("</td>");
    }

    markup.push_str(r#"<table align="center" cellspacing="0" cellpadding="3">"#);
    for (index, row) in rows.iter().enumerate() {
        markup.push_str("<tr>");
        if index == 0 {
            side(prefix, rows.len(), markup);
            enclosure(left, rows.len(), markup);
        }
        for (column, alignment) in columns.iter().enumerate() {
            markup.push_str(match alignment {
                Alignment::Left => r#"<td align="left" valign="middle">"#,
                Alignment::Center => r#"<td align="center" valign="middle">"#,
                Alignment::Right => r#"<td align="right" valign="middle">"#,
            });
            if let Some(node) = row.get(column) {
                write_node(node, None, markup);
            }
            markup.push_str("</td>");
        }
        if index == 0 {
            enclosure(right, rows.len(), markup);
            side(suffix, rows.len(), markup);
        }
        markup.push_str("</tr>");
    }
    markup.push_str("</table>");
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
        Node::Grid {
            rows,
            columns,
            left,
            right,
        } => write_grid(rows, columns, left, right, &[], &[], markup),
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

    #[test]
    fn presentation_status_is_explicit_without_changing_fallback_bytes() {
        let text = "🙂 \\(x^2\\) \\[\\unsupported{<img src=x>}\\] \\(\\unsupported{a}\\)";
        let value = serde_json::to_value(spans(text)).unwrap();
        let values = value.as_array().unwrap();
        assert_eq!(values.len(), 3);
        assert_eq!(values[0]["rendered"], true);
        assert_eq!(values[0]["display"], false);
        assert_eq!(values[1]["rendered"], false);
        assert_eq!(values[1]["display"], true);
        assert_eq!(values[2]["rendered"], false);
        assert_eq!(values[2]["display"], false);
        assert_eq!(values[0]["source"], "x^2");
        assert_eq!(values[1]["source"], r"\unsupported{<img src=x>}");
        assert_eq!(values[2]["source"], r"\unsupported{a}");
        assert_eq!(values[1]["markup"], r"\[\unsupported{&lt;img src=x&gt;}\]");
        assert_eq!(values[1]["start"], 11);
        // Equal-looking text cannot serve as a success discriminator.
        let identity = serde_json::to_value(spans(r"\(x\)")).unwrap();
        assert_eq!(identity[0]["rendered"], true);
        assert_eq!(identity[0]["markup"], "x");
    }

    #[test]
    fn source_metadata_retains_the_unmodified_body_without_using_it_as_markup() {
        let text = "🙂 \\[\r\n\\unsupported{<b> é 中文}\r\n\\]";
        let values = spans(text);
        assert_eq!(values.len(), 1);
        assert_eq!(values[0].source, "\r\n\\unsupported{<b> é 中文}\r\n");
        assert!(!values[0].rendered);
        assert!(values[0].markup.contains("&lt;b&gt;"));
        assert!(!values[0].markup.contains("<b>"));
    }

    #[test]
    fn display_math_stack_and_grid_only_use_adapter_selected_markup() {
        let text = r"\[\frac{\alpha}{\beta}\] \[\begin{pmatrix}x&\text{<img src=x>}\\y&z\end{pmatrix}\] \(\frac{u}{v}\)";
        let spans = spans(text);
        assert_eq!(spans.len(), 3);
        assert!(spans[0].markup.contains("<tr><td><hr /></td></tr>"));
        assert!(spans[1].markup.contains("rowspan=\"2\""));
        assert!(spans[1].markup.contains("&lt;img src=x&gt;"));
        assert!(!spans[1].markup.contains("<img"));
        assert_eq!(spans[2].markup, "<sup>u</sup>⁄<sub>v</sub>");
    }
}
