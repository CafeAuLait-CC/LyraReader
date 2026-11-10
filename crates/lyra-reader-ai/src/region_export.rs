//! Bounded, offline reading-note exports. Rendering never reads or writes a file.
use crate::region_history::{AnswerState, Entry, MAX_ENTRIES, MAX_HISTORY_BYTES};
use chrono::{DateTime, SecondsFormat};
use lyra_reader_edit::records::base64_decode;
use std::fmt::Write;

pub struct ExportImage {
    pub name: String,
    pub png: Vec<u8>,
}
pub struct ExportDocument {
    pub markdown: String,
    pub images: Vec<ExportImage>,
    pub omitted: usize,
}

/// A portable sibling name, independent of a localized document title or absolute path.
pub fn image_folder(stem: &str) -> Result<String, String> {
    if stem.len() > 4096 {
        return Err("The export filename is too long".into());
    }
    let mut name = String::new();
    for ch in stem.chars() {
        let safe = ch.is_ascii_alphanumeric() || ch == '_' || ch == '.';
        if safe {
            name.push(ch);
        } else if !name.is_empty() && !name.ends_with('-') {
            name.push('-');
        }
        if name.len() >= 64 {
            break;
        }
    }
    let name = name.trim_matches(['-', '.']);
    Ok(format!(
        "{}-images",
        if name.is_empty() {
            "reading-notes"
        } else {
            name
        }
    ))
}

fn iso_date(seconds_since_2001: f64) -> Result<String, String> {
    let seconds = (seconds_since_2001 + 978_307_200.0).floor();
    if !seconds.is_finite() || seconds < i64::MIN as f64 || seconds >= i64::MAX as f64 {
        return Err("A reading-note date is outside the export range".into());
    }
    DateTime::from_timestamp(seconds as i64, 0)
        .map(|date| date.to_rfc3339_opts(SecondsFormat::Secs, true))
        .ok_or_else(|| "A reading-note date is outside the export range".into())
}

fn state_label(state: AnswerState) -> &'static str {
    match state {
        AnswerState::Finished => "finished",
        AnswerState::Cancelled => "cancelled",
        AnswerState::Failed => "failed",
        AnswerState::Empty => "empty",
    }
}

struct Markdown {
    text: String,
    limit: usize,
}
impl Write for Markdown {
    fn write_str(&mut self, text: &str) -> std::fmt::Result {
        if self
            .text
            .len()
            .checked_add(text.len())
            .is_none_or(|n| n > self.limit)
        {
            return Err(std::fmt::Error);
        }
        self.text.push_str(text);
        Ok(())
    }
}
fn bounded(error: std::fmt::Error) -> String {
    format!("Reading-note export exceeds the 64 MiB output limit: {error}")
}
fn single_line(text: &str) -> String {
    text.replace(
        [
            '\r', '\n', '\u{b}', '\u{c}', '\u{85}', '\u{2028}', '\u{2029}',
        ],
        " ",
    )
    .trim()
    .to_owned()
}
fn question(text: &str, output: &mut Markdown) -> Result<(), String> {
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    for (index, line) in normalized.split('\n').enumerate() {
        if index > 0 {
            output.write_char('\n').map_err(bounded)?;
        }
        let line = line.trim();
        if line.starts_with(['#', '>', '-', '+', '*', '|', '`']) {
            output.write_char('\\').map_err(bounded)?;
        } else {
            let digits = line.bytes().take_while(u8::is_ascii_digit).count();
            if digits > 0
                && matches!(line.as_bytes().get(digits), Some(b'.' | b')'))
                && line[digits + 1..].starts_with(char::is_whitespace)
            {
                output.write_char('\\').map_err(bounded)?;
            }
        }
        for ch in line.chars() {
            match ch {
                '<' => output.write_str("&lt;"),
                '>' => output.write_str("&gt;"),
                _ => output.write_char(ch),
            }
            .map_err(bounded)?;
        }
    }
    Ok(())
}

/// Render saved records only. Unknown records are counted by the storage owner, not discarded.
/// Markdown and decoded images share one output budget; no image is re-rasterized or recoloured.
pub fn render(
    title: &str,
    file_name: &str,
    entries: &[Entry],
    foreign: usize,
    exported_at: f64,
    folder: &str,
) -> Result<ExportDocument, String> {
    if entries.len() > MAX_ENTRIES
        || title.len() > 4096
        || file_name.len() > 4096
        || folder.is_empty()
        || folder.len() > 80
        || !folder
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
        || matches!(folder, "." | "..")
    {
        return Err("Invalid reading-note export metadata or record count".into());
    }
    let mut answered = Vec::new();
    for entry in entries {
        entry.validate()?;
        if entry.has_answer() {
            answered.push(entry);
        }
    }
    if answered.is_empty() {
        return Err(
            "There are no saved region conversations with an answer or reading note to export"
                .into(),
        );
    }
    answered.sort_by(|a, b| {
        if a.created_at == b.created_at {
            std::cmp::Ordering::Equal
        } else {
            a.created_at.total_cmp(&b.created_at)
        }
    });
    let omitted = entries.len() - answered.len();
    let mut images = Vec::new();
    let mut image_bytes = 0usize;
    for (index, entry) in answered.iter().enumerate() {
        let png = base64_decode(&entry.attachment.png).ok_or("Invalid saved PNG encoding")?;
        image_bytes = image_bytes
            .checked_add(png.len())
            .filter(|n| *n <= MAX_HISTORY_BYTES)
            .ok_or("Reading-note images exceed the 64 MiB output limit")?;
        images.push(ExportImage {
            name: format!("region-{:02}.png", index + 1),
            png,
        });
    }
    let mut out = Markdown {
        text: String::new(),
        limit: MAX_HISTORY_BYTES - image_bytes,
    };
    let title = single_line(title)
        .replace('#', "\\#")
        .replace('<', "&lt;")
        .replace('>', "&gt;");
    let file = single_line(file_name).replace('`', "'");
    write!(out, "# Reading notes — {title}\n\n- **Document:** `{file}`\n- **Exported:** {}\n- **Conversations:** {}\n", iso_date(exported_at)?, answered.len()).map_err(bounded)?;
    if omitted > 0 {
        writeln!(out, "- **Omitted:** {omitted} conversations with no answer").map_err(bounded)?;
    }
    if foreign > 0 {
        writeln!(out, "- **Unavailable:** {foreign} unreadable or unsupported saved records; originals were kept").map_err(bounded)?;
    }
    write!(out, "\nExported from LyraReader. Original region captures are in `{folder}/` beside this document. Images use relative links, not embedded image data.\n\n## Contents\n\n").map_err(bounded)?;
    for (index, entry) in answered.iter().enumerate() {
        writeln!(
            out,
            "{}. [Page {} · Region {}](#{}-page-{})",
            index + 1,
            u64::from(entry.attachment.page) + 1,
            index + 1,
            index + 1,
            u64::from(entry.attachment.page) + 1
        )
        .map_err(bounded)?;
    }
    for (index, entry) in answered.iter().enumerate() {
        let n = index + 1;
        write!(
            out,
            "\n## {n}. Page {}\n\n",
            u64::from(entry.attachment.page) + 1
        )
        .map_err(bounded)?;
        if entry.state != AnswerState::Finished {
            write!(
                out,
                "**Status:** {}; any answer below may be partial.\n\n",
                state_label(entry.state)
            )
            .map_err(bounded)?;
        }
        write!(out, "![Selected region {n} on page {}]({folder}/{})\n\n**Page:** {} · **Region:** {:.0} × {:.0} pt · **Asked:** {}\n\n", u64::from(entry.attachment.page)+1, images[index].name, u64::from(entry.attachment.page)+1, entry.attachment.rect[1][0].round(), entry.attachment.rect[1][1].round(), iso_date(entry.created_at)?).map_err(bounded)?;
        if !entry.knowledge_note.is_empty() {
            write!(
                out,
                "### Reading note\n\n{}\n\n",
                entry.knowledge_note.trim()
            )
            .map_err(bounded)?;
        }
        for (turn_index, turn) in entry.display_turns().enumerate() {
            write!(out, "### Turn {}\n\n**Question**\n\n", turn_index + 1).map_err(bounded)?;
            question(turn.question, &mut out)?;
            write!(out, "\n\n**Answer**\n\n{}\n\n", turn.answer.trim()).map_err(bounded)?;
            if turn.state != AnswerState::Finished {
                write!(
                    out,
                    "*{}; this turn may be partial.*\n\n",
                    state_label(turn.state)
                )
                .map_err(bounded)?;
            }
        }
        out.write_str("Page markers in saved answers are retained as text; this export creates no verified PDF navigation links.\n\n").map_err(bounded)?;
    }
    Ok(ExportDocument {
        markdown: out.text,
        images,
        omitted,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::region_history::History;
    fn sample() -> Entry {
        History::decode(include_bytes!(
            "../../../tests/fixtures/region-history/legacy-synthetic.json"
        ))
        .unwrap()
        .entries()
        .next()
        .unwrap()
        .clone()
    }
    #[test]
    fn export_preserves_images_legacy_turns_and_literal_questions() {
        let mut entry = sample();
        entry.question = "# literal <tag>\r\n1. not a list".into();
        let image = base64_decode(&entry.attachment.png).unwrap();
        let mut empty = entry.clone();
        empty.id = "00000002-1111-4222-8333-000000000002".into();
        empty.question.clear();
        empty.answer.clear();
        empty.knowledge_note.clear();
        let out = render(
            "Title\n#<tag>",
            "file`name.pdf",
            &[entry, empty],
            2,
            0.,
            "notes-images",
        )
        .unwrap();
        assert!(out.markdown.contains("2001-01-01T00:00:00Z"));
        assert!(
            out.markdown
                .contains("\\# literal &lt;tag&gt;\n\\1. not a list")
        );
        assert!(out.markdown.contains("**Omitted:** 1"));
        assert!(out.markdown.contains("**Unavailable:** 2"));
        assert!(!out.markdown.contains("data:image"));
        assert!(!out.markdown.contains("<tag>"));
        assert_eq!(out.images.len(), 1);
        assert_eq!(out.images[0].png, image);
        assert_eq!(out.omitted, 1);
    }
    #[test]
    fn export_refuses_bad_metadata_dates_and_all_unanswered_records() {
        let mut entry = sample();
        for folder in ["../elsewhere", ".", "..", "a/b", "a%20b"] {
            assert!(render("t", "f", &[entry.clone()], 0, 0., folder).is_err());
        }
        assert!(render("t", "f", &[entry.clone()], 0, f64::NAN, "images").is_err());
        entry.created_at = f64::MAX;
        assert!(render("t", "f", &[entry.clone()], 0, 0., "images").is_err());
        entry = sample();
        entry.knowledge_note.clear();
        entry.question.clear();
        assert!(render("t", "f", &[entry], 0, 0., "images").is_err());
        assert_eq!(image_folder("../研究 Notes * a").unwrap(), "Notes-a-images");
        let mut entry = sample();
        entry.attachment.page = u32::MAX;
        assert!(
            render("t", "f", &[entry], 0, 0., "images")
                .unwrap()
                .markdown
                .contains("4294967296")
        );
    }
    #[test]
    fn markdown_budget_is_checked_before_growth() {
        let mut out = Markdown {
            text: "abc".into(),
            limit: 4,
        };
        assert!(out.write_str("de").is_err());
        assert_eq!(out.text, "abc");
        assert!(out.write_char('α').is_err());
        assert_eq!(out.text, "abc");
    }
    #[test]
    fn exports_oldest_first_all_turns_and_marks_partial_answers() {
        let newer = sample();
        let mut older = sample();
        older.id = "00000002-1111-4222-8333-000000000002".into();
        older.created_at -= 10.;
        older.state = AnswerState::Cancelled;
        for (index, state) in [AnswerState::Cancelled, AnswerState::Finished]
            .into_iter()
            .enumerate()
        {
            older.turns.push(crate::region_history::Turn {
                id: format!("10000000-1111-4222-8333-{:012}", index + 1),
                question: format!("Question {}", index + 1),
                answer: format!("Explicit saved turn {}", index + 1),
                state,
                error: None,
                created_at: older.created_at,
                source_pages: None,
            });
        }
        let out = render("t", "f", &[newer, older], 0, 0., "images").unwrap();
        let first = out.markdown.find("Explicit saved turn 1").unwrap();
        let second = out.markdown.find("Explicit saved turn 2").unwrap();
        let legacy = out
            .markdown
            .find("An unverified legacy page marker")
            .unwrap();
        assert!(first < second && second < legacy);
        assert!(out.markdown.contains("cancelled; this turn may be partial"));
        assert_eq!(out.images.len(), 2);
    }
}
