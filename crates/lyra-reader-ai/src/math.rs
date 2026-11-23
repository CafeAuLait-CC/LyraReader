//! Portable compatibility rules for mathematics returned by reading assistants.

#[path = "math_inline.rs"]
pub mod inline;

pub const OUTPUT_GUIDANCE: &str = r"Use \( ... \) for inline mathematics and \[ ... \] on separate lines for display mathematics. Do not put mathematics in backticks or fenced code blocks. Brace LaTeX command arguments explicitly, for example \mathcal{L}, \frac{a}{b}, and \text{label}.";

/// Canonicalize font arguments and equation tags for the native math subset.
/// The caller retains the original source for copying and fallback. Existing font/text arguments,
/// escaped control symbols, unknown commands and incomplete expressions stay intact.
/// This is a single streaming pass with constant auxiliary state, without recursive parsing.
pub fn render_source(source: &str) -> String {
    let mut input = source.char_indices().peekable();
    let mut output = String::new();
    while let Some((_, ch)) = input.next() {
        let command_output_start = output.len();
        output.push(ch);
        if ch != '\\' {
            continue;
        }
        let Some(&(start, next)) = input.peek() else {
            break;
        };
        if !next.is_ascii_alphabetic() {
            // A control symbol consumes its following character: a row break must not turn
            // its second slash into the start of a font command.
            input.next();
            output.push(next);
            continue;
        }
        let mut end = start;
        while let Some(&(index, ch)) = input.peek() {
            if !ch.is_ascii_alphabetic() {
                break;
            }
            input.next();
            end = index + ch.len_utf8();
        }
        // Both offsets came from char_indices and therefore name UTF-8 boundaries.
        let command = &source[start..end];
        output.push_str(command);
        if command == "tag" {
            let starred = input.peek().is_some_and(|(_, ch)| *ch == '*');
            if starred {
                input.next();
                output.push('*');
            }
            while let Some(&(_, ch)) = input.peek() {
                if !ch.is_whitespace() {
                    break;
                }
                input.next();
                output.push(ch);
            }
            if let Some(&(group_start, '{')) = input.peek() {
                if let Some(group_end) = consume_braced_group(&mut input) {
                    // Keep the complete label as a math group. Unknown commands in it
                    // still reach the renderer's diagnostic instead of being discarded.
                    output.truncate(command_output_start);
                    output.push_str(if starred { r"\quad" } else { r"\quad(" });
                    output.push_str(&source[group_start..group_end]);
                    if !starred {
                        output.push(')');
                    }
                } else {
                    output.push_str(&source[group_start..]);
                }
            }
            continue;
        }
        let font = matches!(
            command,
            "mathcal"
                | "mathbb"
                | "mathsf"
                | "mathtt"
                | "mathbf"
                | "mathrm"
                | "mathit"
                | "boldsymbol"
        );
        if font || matches!(command, "text" | "operatorname") {
            while let Some(&(_, ch)) = input.peek() {
                if !ch.is_whitespace() {
                    break;
                }
                input.next();
                output.push(ch);
            }
        }
        let has_group = input.peek().is_some_and(|(_, ch)| *ch == '{');
        if font
            && let Some(&(_, ch)) = input.peek()
            && ch.is_alphanumeric()
        {
            input.next();
            output.push('{');
            output.push(ch);
            output.push('}');
        }
        if has_group
            && (font || matches!(command, "text" | "operatorname"))
            && let Some(&(group_start, _)) = input.peek()
        {
            // An unclosed group keeps its complete suffix for the native diagnostic.
            let group_end = consume_braced_group(&mut input).unwrap_or(source.len());
            output.push_str(&source[group_start..group_end]);
        }
    }
    output
}

/// The caller has checked for an opening brace. All returned offsets are UTF-8
/// boundaries from char_indices; group depth is bounded by the source's length.
fn consume_braced_group(
    input: &mut std::iter::Peekable<std::str::CharIndices<'_>>,
) -> Option<usize> {
    let (_, opening) = input.next()?;
    if opening != '{' {
        return None;
    }
    let mut depth = 1usize;
    while let Some((index, ch)) = input.next() {
        match ch {
            '\\' => {
                input.next();
            }
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(index + ch.len_utf8());
                }
            }
            _ => {}
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::render_source;

    #[test]
    fn unbraced_font_arguments_keep_scripts_and_other_math() {
        assert_eq!(
            render_source(r"\mathcal J_{\text{all}} = \mathcal J_{\text{fit}} + \mu\mathbf v"),
            r"\mathcal {J}_{\text{all}} = \mathcal {J}_{\text{fit}} + \mu\mathbf {v}"
        );
        assert_eq!(
            render_source("\\mathsf α + \\mathrm 21"),
            "\\mathsf {α} + \\mathrm {2}1"
        );
    }

    #[test]
    fn braced_arguments_and_literal_text_are_unchanged() {
        for source in [
            r"\mathcal{J}_{i} + \frac{a}{b}",
            r"\mathbf{\mathcal J} + \mathcal{K}",
            r"\text{literal \mathcal J and escaped \{ braces \}}",
            r"\operatorname{code \mathbf x}",
            r"\\mathcal J",
            r"\unknown J",
        ] {
            assert_eq!(render_source(source), source);
        }
    }

    #[test]
    fn incomplete_and_invalid_arguments_remain_diagnosable() {
        for source in [
            r"\mathcal",
            r"\mathcal ",
            r"\mathcal_2",
            r"\mathcal{J",
            r"\text{unclosed",
            "\\",
        ] {
            assert_eq!(render_source(source), source);
        }
        let nested = format!("\\text{{{}{}}}", "{".repeat(10_000), "}".repeat(10_000));
        assert_eq!(render_source(&nested), nested);
    }

    #[test]
    fn equation_tags_keep_their_labels_without_requiring_an_amsmath_command() {
        for (source, expected) in [
            (
                r"c_k = W_c u_k + e_{\tau}(\tau_k). \tag{3}",
                r"c_k = W_c u_k + e_{\tau}(\tau_k). \quad({3})",
            ),
            (r"x=1\tag{A.2}", r"x=1\quad({A.2})"),
            (r"x=1\tag*{A.2}", r"x=1\quad{A.2}"),
            ("x=1\\tag \n{三}", r"x=1\quad({三})"),
            (r"x=1\tag{\text{A.2}}", r"x=1\quad({\text{A.2}})"),
            (r"x=1\tag{\unknown{3}}", r"x=1\quad({\unknown{3}})"),
        ] {
            assert_eq!(render_source(source), expected);
            assert_eq!(render_source(expected), expected);
        }
    }

    #[test]
    fn literal_escaped_and_malformed_tags_are_not_silently_removed() {
        for source in [
            r"\text{literal \tag{3}}",
            r"\operatorname{literal \tag{3}}",
            r"\\tag{3}",
            r"\tagged{3}",
            r"x=1\tag",
            r"x=1\tag* ",
            r"x=1\tag{3",
            r"x=1\tag*{A.2",
            r"x=1\tag\{3\}",
            r"x=1\tag{\{3\}",
        ] {
            assert_eq!(render_source(source), source);
        }
        let nested = format!("\\tag{{{}{}}}", "{".repeat(10_000), "}".repeat(10_000));
        assert_eq!(render_source(&nested), format!("\\quad({})", &nested[4..]));
    }
}
