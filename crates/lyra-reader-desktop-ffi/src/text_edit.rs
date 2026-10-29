//! Persistence adapter for the shared placed-text history group.
use super::*;
use lyra_reader_edit::text_edit::TextEditGroup;

#[derive(Clone)]
pub(super) struct Session {
    token: String,
    id: String,
    pub(super) history: TextEditGroup<Snapshot>,
}

impl Marks {
    pub(super) fn text_edit_command(
        &mut self,
        op: &str,
        r: &Value,
        document: &LyraReaderDocument,
    ) -> Result<Value, String> {
        self.validate_source()?;
        if let Some(error) = &self.error {
            return Err(error.clone());
        }
        if op == "mark_text_begin" {
            if self.text_edit.is_some() {
                return Err("Finish the current placed-text editor first".into());
            }
            let id = string(r, "id")?;
            let entry = self
                .entries
                .iter()
                .find_map(|e| match e {
                    Entry::Known(v) if v["id"] == id && kind(v) == "textBox" => Some(v),
                    _ => None,
                })
                .ok_or("Editable text box not found")?;
            let created = r["created"]
                .as_bool()
                .ok_or("Missing text creation status")?;
            let before_creation = if created {
                let previous = self.undo.last().ok_or("Missing text creation history")?;
                if previous.entries.len().checked_add(1) != Some(self.entries.len())
                    || previous
                        .entries
                        .iter()
                        .any(|e| matches!(e, Entry::Known(v) if v["id"] == id))
                    || self
                        .entries
                        .last()
                        .is_none_or(|e| !matches!(e, Entry::Known(v) if v == entry))
                {
                    return Err("The text box is no longer the most recent creation".into());
                }
                Some(previous.clone())
            } else {
                None
            };
            let mut state = self.state(document)?;
            let token = uuid()?;
            self.text_edit = Some(Session {
                token: token.clone(),
                id,
                history: TextEditGroup::new(self.snapshot(), self.undo.len(), before_creation)?,
            });
            state["text_edit_token"] = json!(token);
            return Ok(state);
        }
        let session = self
            .text_edit
            .clone()
            .ok_or("The placed-text editing session expired")?;
        if string(r, "edit_token")? != session.token || string(r, "id")? != session.id {
            return Err("The placed-text editing session changed. Reopen the editor".into());
        }
        session.history.validate_history(self.undo.len())?;
        match op {
            "mark_text_update" => {
                let patch = r["patch"].as_object().ok_or("Missing text changes")?;
                if patch.is_empty() || patch.keys().any(|k| k != "note" && k != "rect") {
                    return Err("Placed-text editing changes only the text and its box".into());
                }
                self.change(|s| {
                    let entry = s
                        .entries
                        .iter_mut()
                        .find_map(|e| match e {
                            Entry::Known(v) if v["id"] == session.id && kind(v) == "textBox" => {
                                Some(v)
                            }
                            _ => None,
                        })
                        .ok_or("Editable text box not found")?;
                    for (key, value) in patch {
                        entry[key] = value.clone();
                    }
                    if !validate(entry, s.page_count)? {
                        return Err("Unsupported text changes".into());
                    }
                    Ok(())
                })?;
            }
            "mark_text_end" => {
                if r["cancel"]
                    .as_bool()
                    .ok_or("Missing text completion status")?
                {
                    let current = self.snapshot();
                    self.restore(session.history.cancellation_snapshot());
                    if let Err(error) = self.persist() {
                        self.restore(current);
                        if self.session.is_some()
                            && let Err(rollback) = self.persist()
                        {
                            self.error =
                                Some(format!("The editing session needs recovery: {rollback}"));
                        }
                        return Err(error);
                    }
                    session.history.cancel_history(&mut self.undo);
                    self.redo.clear();
                }
                self.text_edit = None;
                Self::trim_history(&mut self.undo);
            }
            _ => return Err("Unsupported text editing command".into()),
        }
        self.state(document)
    }
}
