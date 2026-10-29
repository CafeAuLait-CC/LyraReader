//! One native placed-text editing session, independent of a shell's snapshot format.
//! Durable writes may be coalesced independently; history keeps one pre-edit snapshot.

#[derive(Clone)]
pub struct TextEditGroup<S> {
    before: S,
    cancel: S,
    depth: usize,
    cancel_depth: usize,
}

impl<S: Clone> TextEditGroup<S> {
    pub fn new(before: S, depth: usize, before_creation: Option<S>) -> Result<Self, String> {
        let cancel_depth = if before_creation.is_some() {
            depth
                .checked_sub(1)
                .ok_or("Missing text creation history")?
        } else {
            depth
        };
        Ok(Self {
            cancel: before_creation.unwrap_or_else(|| before.clone()),
            before,
            depth,
            cancel_depth,
        })
    }

    pub fn validate_history(&self, length: usize) -> Result<(), String> {
        if length < self.depth || length.saturating_sub(self.depth) > 1 {
            return Err("The annotation changed outside this text editing session".into());
        }
        Ok(())
    }

    /// Call only after the new annotation state has been written successfully.
    pub fn record(&self, history: &mut Vec<S>) {
        history.truncate(self.depth);
        history.push(self.before.clone());
    }

    pub fn cancellation_snapshot(&self) -> S {
        self.cancel.clone()
    }

    /// Call only after the cancellation snapshot has been written successfully.
    pub fn cancel_history(&self, history: &mut Vec<S>) {
        history.truncate(self.cancel_depth);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn many_flushes_are_one_edit_and_cancel_new_text_drops_creation() {
        let group = TextEditGroup::new("date", 1, Some("empty")).unwrap();
        let mut history = vec!["empty"];
        for _ in 0..5 {
            group.validate_history(history.len()).unwrap();
            group.record(&mut history);
            assert_eq!(history, vec!["empty", "date"]);
        }
        assert_eq!(group.cancellation_snapshot(), "empty");
        group.cancel_history(&mut history);
        assert!(history.is_empty());
    }

    #[test]
    fn existing_edit_keeps_earlier_history_and_rejects_interleaved_edits() {
        let group = TextEditGroup::new("before", 1, None).unwrap();
        let mut history = vec!["earlier"];
        group.record(&mut history);
        assert_eq!(group.cancellation_snapshot(), "before");
        assert!(group.validate_history(0).is_err());
        assert!(group.validate_history(3).is_err());
        group.cancel_history(&mut history);
        assert_eq!(history, vec!["earlier"]);
        assert!(TextEditGroup::new("before", 0, Some("empty")).is_err());
    }
}
