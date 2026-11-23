//! A bounded math tree for native presentation. The original response remains
//! the source for copying, persistence, and expressions outside the supported subset.
use std::{iter::Peekable, ops::Range, str::Chars};

const MAX_FORMULA_BYTES: usize = 2048;
const MAX_FORMULAS: usize = 128;
const MAX_DEPTH: usize = 16;
const MAX_GRID_ROWS: usize = 8;
const MAX_GRID_COLUMNS: usize = 8;
const MAX_GRID_CELLS: usize = 48;

#[derive(Debug, PartialEq, Eq)]
pub enum Style {
    Regular,
    Italic,
    Bold,
    Script,
    DoubleStruck,
    Sans,
    Mono,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Node {
    Text(String),
    Row(Vec<Node>),
    Fraction(Box<Node>, Box<Node>),
    Root(Box<Node>),
    Styled(Style, Box<Node>),
    Grid {
        rows: Vec<Vec<Node>>,
        columns: Vec<Alignment>,
        left: &'static str,
        right: &'static str,
    },
    Scripts {
        base: Box<Node>,
        subscript: Option<Box<Node>>,
        superscript: Option<Box<Node>>,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Alignment {
    Left,
    Center,
    Right,
}

pub struct Formula {
    /// UTF-8 byte offsets into the untouched response, including delimiters.
    pub range: Range<usize>,
    pub display: bool,
    pub expression: Option<Node>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Delimiter {
    Parentheses,
    Brackets,
    Dollar,
    DoubleDollar,
}

impl Delimiter {
    fn start(bytes: &[u8]) -> Option<(Self, usize)> {
        match bytes {
            [b'\\', b'(', ..] => Some((Self::Parentheses, 2)),
            [b'\\', b'[', ..] => Some((Self::Brackets, 2)),
            [b'$', b'$', ..] => Some((Self::DoubleDollar, 2)),
            [b'$', next, ..] if !next.is_ascii_whitespace() => Some((Self::Dollar, 1)),
            _ => None,
        }
    }
    fn end(self) -> &'static [u8] {
        match self {
            Self::Parentheses => br"\)",
            Self::Brackets => br"\]",
            Self::Dollar => b"$",
            Self::DoubleDollar => b"$$",
        }
    }
    fn display(self) -> bool {
        matches!(self, Self::Brackets | Self::DoubleDollar)
    }
}

pub fn formulas(text: &str) -> Vec<Formula> {
    let bytes = text.as_bytes();
    let mut output = Vec::new();
    let mut cursor = 0;
    let mut code = 0;
    let mut open: Option<(Delimiter, usize, usize)> = None;
    while cursor < bytes.len() && output.len() < MAX_FORMULAS {
        let rest = &bytes[cursor..];
        if let Some((delimiter, start, content)) = open {
            if rest.starts_with(delimiter.end()) {
                // Every delimiter is ASCII, hence both indices are UTF-8 boundaries.
                let body = &text[content..cursor];
                if delimiter == Delimiter::Dollar && !looks_like_dollar_math(body) {
                    // A currency sign must not consume the opener of the next real formula.
                    open = Delimiter::start(rest)
                        .map(|(kind, length)| (kind, cursor, cursor + length));
                    cursor = open.map_or(cursor + 1, |(_, _, content)| content);
                    continue;
                }
                cursor += delimiter.end().len();
                open = None;
                let expression = (body.len() <= MAX_FORMULA_BYTES)
                    .then(|| parse(body, delimiter.display()))
                    .flatten();
                output.push(Formula {
                    range: start..cursor,
                    display: delimiter.display(),
                    expression,
                });
                continue;
            }
            if delimiter == Delimiter::Dollar && matches!(rest, [b'\\', b'(' | b'[', ..]) {
                // Explicit delimiters take precedence over an unmatched currency sign.
                open = Delimiter::start(rest).map(|(kind, length)| (kind, cursor, cursor + length));
                cursor += 2;
                continue;
            }
            if !delimiter.display() && rest[0] == b'\n' {
                open = None;
            }
        } else if rest[0] == 0x60 {
            // Backtick runs quote code, including fenced examples.
            let count = rest.iter().take_while(|byte| **byte == 0x60).count();
            if code == 0 {
                code = count;
            } else if code == count {
                code = 0;
            }
            cursor += count;
            continue;
        } else if code == 0
            && let Some((delimiter, length)) = Delimiter::start(rest)
        {
            open = Some((delimiter, cursor, cursor + length));
            cursor += length;
            continue;
        }
        cursor += if code == 0 && matches!(rest, [b'\\', b'\\' | b'$' | 0x60, ..]) {
            2
        } else {
            1
        };
    }
    output
}

fn looks_like_dollar_math(body: &str) -> bool {
    let trimmed = body.trim();
    trimmed == body
        && (trimmed.chars().count() == 1 && trimmed.chars().any(char::is_alphabetic)
            || trimmed.bytes().any(|b| b"^_\\=+-*/<>{}".contains(&b)))
}

fn parse(source: &str, display: bool) -> Option<Node> {
    if source.trim().is_empty() {
        return None;
    }
    let normalized = super::render_source(source);
    let mut parser = Parser {
        input: normalized.chars().peekable(),
        display,
    };
    let row = parser.row(0, false)?;
    parser.input.peek().is_none().then_some(row)
}

struct Parser<'a> {
    input: Peekable<Chars<'a>>,
    display: bool,
}

#[derive(PartialEq, Eq)]
enum GridSeparator {
    Cell,
    Row,
    End,
}

impl Parser<'_> {
    fn row(&mut self, depth: usize, grid_cell: bool) -> Option<Node> {
        let mut children = Vec::new();
        self.skip_space();
        while self.input.peek().is_some_and(|&ch| ch != '}') {
            if grid_cell && self.grid_separator().is_some() {
                break;
            }
            let base = self.atom(depth)?;
            self.skip_space();
            let mut subscript = None;
            let mut superscript = None;
            while matches!(self.input.peek(), Some('^' | '_')) {
                if matches!(base, Node::Grid { .. }) {
                    return None;
                }
                let target = if self.input.next()? == '^' {
                    &mut superscript
                } else {
                    &mut subscript
                };
                if target.is_some() {
                    return None;
                }
                *target = Some(Box::new(self.atom(depth + 1)?));
                self.skip_space();
            }
            children.push(if subscript.is_none() && superscript.is_none() {
                base
            } else {
                Node::Scripts {
                    base: Box::new(base),
                    subscript,
                    superscript,
                }
            });
        }
        Some(Node::Row(children))
    }

    fn atom(&mut self, depth: usize) -> Option<Node> {
        if depth >= MAX_DEPTH {
            return None;
        }
        self.skip_space();
        match self.input.next()? {
            '{' => {
                let row = self.row(depth + 1, false)?;
                (self.input.next()? == '}').then_some(row)
            }
            '\\' => self.command(depth),
            '}' | '^' | '_' | '$' | '&' | '\u{60}' => None,
            ch if !ch.is_control() => Some(Node::Text(ch.to_string())),
            _ => None,
        }
    }

    fn command(&mut self, depth: usize) -> Option<Node> {
        if depth >= MAX_DEPTH {
            return None;
        }
        if !self.input.peek()?.is_ascii_alphabetic() {
            let symbol = match self.input.next()? {
                ',' | ';' | ':' | ' ' => "\u{2009}".into(),
                '!' => String::new(),
                ch @ ('{' | '}' | '$' | '%' | '#' | '_' | '&' | '|') => ch.to_string(),
                _ => return None,
            };
            return Some(Node::Text(symbol));
        }
        let mut name = String::new();
        while self.input.peek().is_some_and(char::is_ascii_alphabetic) {
            name.push(self.input.next()?);
        }
        match name.as_str() {
            "frac" | "dfrac" | "tfrac" => {
                let numerator = Box::new(self.atom(depth + 1)?);
                let denominator = Box::new(self.atom(depth + 1)?);
                Some(Node::Fraction(numerator, denominator))
            }
            "sqrt" if self.input.peek() != Some(&'[') => {
                Some(Node::Root(Box::new(self.atom(depth + 1)?)))
            }
            "begin" if self.display && depth == 0 => self.grid(),
            "text" | "operatorname" => self.text_group().map(Node::Text),
            "left" | "right" | "middle" => {
                self.skip_space();
                match self.input.next()? {
                    ch @ ('(' | ')' | '|' | '[' | ']') => Some(Node::Text(ch.to_string())),
                    '.' => Some(Node::Text(String::new())),
                    '\\' => self.command(depth + 1),
                    _ => None,
                }
            }
            name => {
                if let Some(style) = font(name) {
                    Some(Node::Styled(style, Box::new(self.atom(depth + 1)?)))
                } else {
                    glyph(name).map(|symbol| Node::Text(symbol.into()))
                }
            }
        }
    }

    fn skip_space(&mut self) {
        while self.input.peek().is_some_and(|ch| ch.is_whitespace()) {
            self.input.next();
        }
    }

    fn grid_separator(&self) -> Option<GridSeparator> {
        let mut input = self.input.clone();
        match (input.next()?, input.next()) {
            ('&', _) => Some(GridSeparator::Cell),
            ('\\', Some('\\')) => Some(GridSeparator::Row),
            ('\\', Some('e'))
                if input.next() == Some('n')
                    && input.next() == Some('d')
                    && !input.next().is_some_and(|ch| ch.is_ascii_alphabetic()) =>
            {
                Some(GridSeparator::End)
            }
            _ => None,
        }
    }

    fn grid(&mut self) -> Option<Node> {
        let name = self.text_group()?;
        let (left, right) = match name.as_str() {
            "matrix" | "aligned" | "array" => ("", ""),
            "pmatrix" => ("(", ")"),
            "bmatrix" => ("[", "]"),
            "Bmatrix" => ("{", "}"),
            "vmatrix" => ("|", "|"),
            "Vmatrix" => ("‖", "‖"),
            "cases" => ("{", ""),
            _ => return None,
        };
        let fixed_alignment = if name == "array" {
            let labels = self.text_group()?;
            let columns = labels
                .trim()
                .chars()
                .map(|ch| match ch {
                    'l' => Some(Alignment::Left),
                    'c' => Some(Alignment::Center),
                    'r' => Some(Alignment::Right),
                    _ => None,
                })
                .collect::<Option<Vec<_>>>()?;
            if columns.is_empty() || columns.len() > MAX_GRID_COLUMNS {
                return None;
            }
            Some(columns)
        } else {
            None
        };

        let max_columns = fixed_alignment.as_ref().map_or(MAX_GRID_COLUMNS, Vec::len);
        let mut rows = Vec::new();
        let mut row = Vec::new();
        let mut cells = 0;
        loop {
            self.skip_space();
            if self.grid_separator() == Some(GridSeparator::End) && row.is_empty() {
                // A final row break closes the preceding row without adding a blank one.
                break;
            }
            if rows.len() >= MAX_GRID_ROWS || row.len() >= max_columns || cells >= MAX_GRID_CELLS {
                return None;
            }
            row.push(self.row(1, true)?);
            cells += 1;
            match self.grid_separator()? {
                GridSeparator::Cell => {
                    self.input.next();
                }
                GridSeparator::Row => {
                    self.input.next();
                    self.input.next();
                    rows.push(std::mem::take(&mut row));
                }
                GridSeparator::End => {
                    rows.push(row);
                    break;
                }
            }
        }
        for _ in 0..4 {
            self.input.next(); // consume the recognized `\end` command
        }
        if self.text_group()? != name {
            return None;
        }
        let count = rows.iter().map(Vec::len).max()?;
        let columns = fixed_alignment.unwrap_or_else(|| {
            (0..count)
                .map(|column| match name.as_str() {
                    "aligned" if column % 2 == 0 => Alignment::Right,
                    "aligned" | "cases" => Alignment::Left,
                    _ => Alignment::Center,
                })
                .collect()
        });
        Some(Node::Grid {
            rows,
            columns,
            left,
            right,
        })
    }

    fn text_group(&mut self) -> Option<String> {
        self.skip_space();
        if self.input.next()? != '{' {
            return None;
        }
        let mut result = String::new();
        let mut depth = 1;
        while let Some(ch) = self.input.next() {
            match ch {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if depth == 0 {
                        return Some(result);
                    }
                }
                '\\' => {
                    let literal = self.input.next()?;
                    if !matches!(literal, '{' | '}' | '%' | '$' | '_' | '#' | '&' | '\\') {
                        result.push('\\');
                    }
                    result.push(literal);
                }
                _ => result.push(ch),
            }
        }
        None
    }
}

fn font(name: &str) -> Option<Style> {
    Some(match name {
        "mathrm" => Style::Regular,
        "mathit" => Style::Italic,
        "mathbf" | "boldsymbol" => Style::Bold,
        "mathcal" => Style::Script,
        "mathbb" => Style::DoubleStruck,
        "mathsf" => Style::Sans,
        "mathtt" => Style::Mono,
        _ => return None,
    })
}

fn glyph(name: &str) -> Option<&'static str> {
    Some(match name {
        "alpha" => "α",
        "beta" => "β",
        "gamma" => "γ",
        "delta" => "δ",
        "epsilon" => "ϵ",
        "varepsilon" => "ε",
        "zeta" => "ζ",
        "eta" => "η",
        "theta" => "θ",
        "vartheta" => "ϑ",
        "iota" => "ι",
        "kappa" => "κ",
        "lambda" => "λ",
        "mu" => "μ",
        "nu" => "ν",
        "xi" => "ξ",
        "pi" => "π",
        "rho" => "ρ",
        "sigma" => "σ",
        "tau" => "τ",
        "phi" => "ϕ",
        "varphi" => "φ",
        "psi" => "ψ",
        "omega" => "ω",
        "Gamma" => "Γ",
        "Delta" => "Δ",
        "Theta" => "Θ",
        "Lambda" => "Λ",
        "Pi" => "Π",
        "Sigma" => "Σ",
        "Phi" => "Φ",
        "Psi" => "Ψ",
        "Omega" => "Ω",
        "sum" => "∑",
        "prod" => "∏",
        "int" => "∫",
        "infty" => "∞",
        "partial" => "∂",
        "nabla" => "∇",
        "cdot" => " · ",
        "times" => " × ",
        "div" => " ÷ ",
        "pm" => " ± ",
        "neq" | "ne" => " ≠ ",
        "leq" | "le" => " ≤ ",
        "geq" | "ge" => " ≥ ",
        "approx" => " ≈ ",
        "equiv" => " ≡ ",
        "propto" => " ∝ ",
        "in" => " ∈ ",
        "ni" => " ∋ ",
        "notin" => " ∉ ",
        "to" | "rightarrow" => " → ",
        "leftarrow" => " ← ",
        "sin" => "sin",
        "cos" => "cos",
        "tan" => "tan",
        "exp" => "exp",
        "log" => "log",
        "ln" => "ln",
        "lim" => "lim",
        "ldots" | "dots" => "…",
        "quad" => "\u{2002}",
        "qquad" => "\u{2003}",
        "langle" => "⟨",
        "rangle" => "⟩",
        "lvert" | "rvert" => "|",
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formulas_keep_code_currency_unfinished_text_and_utf8_offsets() {
        let text = concat!(
            "🙂 Cost $5, then $x^2$ and $7, then ",
            r"\(\mathcal J_{fit}\)",
            " ",
            "\u{60}",
            r"\(code\)",
            "\u{60}",
            " ",
            r"\[\alpha\]",
            " ",
            r"\(still streaming"
        );
        let items = formulas(text);
        assert_eq!(
            items
                .iter()
                .map(|item| &text[item.range.clone()])
                .collect::<Vec<_>>(),
            [r"$x^2$", r"\(\mathcal J_{fit}\)", r"\[\alpha\]"]
        );
        assert!(items.iter().all(|item| item.expression.is_some()));
        assert!(items[2].display);
    }

    #[test]
    fn formulas_give_exact_fallback_for_unknown_deep_or_oversized_source() {
        let nested = format!(r"\({}x{}\)", "{".repeat(90), "}".repeat(90));
        let large = format!(r"\({}\)", "x".repeat(MAX_FORMULA_BYTES + 1));
        let source = format!(r"\(\begin{{matrix}} a \end{{matrix}}\) {nested} {large}");
        let items = formulas(&source);
        assert_eq!(items.len(), 3);
        assert!(items.iter().all(|item| item.expression.is_none()));
    }

    #[test]
    fn display_grids_keep_cells_delimiters_and_joined_text() {
        let source = r"\[M=\begin{bmatrix}x_1&\text{a & b}\\z&\frac{p}{q}\\\end{bmatrix}\]";
        let result = formulas(source);
        let Some(Node::Row(nodes)) = &result[0].expression else {
            panic!("display formula was not parsed");
        };
        let Some(Node::Grid {
            rows,
            columns,
            left,
            right,
        }) = nodes.last()
        else {
            panic!("display matrix kept no grid");
        };
        assert_eq!((*left, *right), ("[", "]"));
        assert_eq!(columns, &[Alignment::Center, Alignment::Center]);
        assert_eq!(rows.iter().map(Vec::len).collect::<Vec<_>>(), [2, 2]);
        assert_eq!(rows[0][1], Node::Row(vec![Node::Text("a & b".into())]));
    }

    #[test]
    fn malformed_nested_and_oversized_grids_keep_the_whole_formula_as_source() {
        let rows = std::iter::repeat_n("x", MAX_GRID_ROWS + 1)
            .collect::<Vec<_>>()
            .join(r"\\");
        let input = format!(
            r"\[\begin{{matrix}}{rows}\end{{matrix}}\] \[\begin{{pmatrix}}x\end{{matrix}}\] \[\begin{{matrix}}\begin{{matrix}}x\end{{matrix}}\end{{matrix}}\] \[\begin{{array}}{{l|r}}x&y\end{{array}}\]"
        );
        let items = formulas(&input);
        assert_eq!(items.len(), 4);
        assert!(items.iter().all(|item| item.expression.is_none()));
    }
}
