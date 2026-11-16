//! Portable compatibility rules for mathematics returned by reading assistants.

pub const OUTPUT_GUIDANCE: &str = r"Use \( ... \) for inline mathematics and \[ ... \] on separate lines for display mathematics. Do not put mathematics in backticks or fenced code blocks. Brace LaTeX command arguments explicitly, for example \mathcal{L}, \frac{a}{b}, and \text{label}.";

/// Canonicalize plain single-character font arguments for renderers requiring braces.
/// The caller retains the original source for copying and fallback. Existing font/text arguments,
/// escaped control symbols, unknown commands and incomplete expressions stay intact.
/// This is a single streaming pass with constant auxiliary state, without recursive parsing.
pub fn render_source(source: &str) -> String {
    let mut input = source.char_indices().peekable();
    let mut output = String::new();
    while let Some((_, ch)) = input.next() {
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
        if has_group && (font || matches!(command, "text" | "operatorname")) {
            let mut depth = 0usize;
            while let Some((_, ch)) = input.next() {
                output.push(ch);
                match ch {
                    '\\' => {
                        if let Some((_, escaped)) = input.next() {
                            output.push(escaped);
                        }
                    }
                    '{' => depth += 1,
                    '}' => {
                        depth -= 1;
                        if depth == 0 {
                            break;
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    output
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
}
