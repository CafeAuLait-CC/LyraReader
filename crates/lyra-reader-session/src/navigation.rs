//! Back/Forward navigation history: the two stacks a reader's preview jumps fill.
//!
//! This state machine used to live in the macOS shell (`AppState.swift`, the pre-change
//! implementation at `ffc53b9`, lines 2107–2200). It lives here now so a future GTK/WinUI
//! shell reuses the same rules instead of re-deriving them. The shell only feeds the current
//! location in and applies the location handed back.
//!
//! The semantics are deliberate and frozen by the native equivalence check:
//!
//! * [`NavigationHistory::record`] appends the current location to the back stack, **clears**
//!   the forward branch and trims both stacks: a new jump has a new future.
//! * [`NavigationHistory::go_back`] pops the newest back entry, pushes the current location onto
//!   forward and returns the popped target. [`NavigationHistory::go_forward`] is the mirror.
//!   Both return `None` when their stack is empty and change nothing in that case.
//! * trimming drops the **oldest** entries first, so each stack holds at most
//!   [`NAVIGATION_HISTORY_LIMIT`] locations.
//! * [`NavigationHistory::clear`] empties both stacks.
//!
//! Only the preview-jump entry point records history. Page turns, sidebar jumps, tab restores
//! and Back/Forward themselves do not; that is the shell call sites' rule (this type never
//! invents a record), and moving the stacks must not change it.

/// Maximum number of entries kept in each direction.
pub const NAVIGATION_HISTORY_LIMIT: usize = 20;

/// An inclusive character range on one page.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ReaderSelection {
    pub page: u32,
    pub start: u32,
    pub end: u32,
}

/// Where the reader was when a preview jump was recorded.
///
/// `scroll_y_pt` is the exact content offset, not a page number rounded to a page top: a reader
/// halfway down a long page must come back halfway down it. `page` is the 0-based page under the
/// viewport's top edge, kept because the old value carried it.
///
/// The old Swift value also carried the open `ReferencePreview`. It is deliberately **not**
/// here: no code path ever restored it (Back does not reopen a panel the reader has since
/// closed), so dropping the payload cannot change behaviour.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ReaderLocation {
    pub page: u32,
    pub scroll_y_pt: f64,
    pub selection: Option<ReaderSelection>,
}

/// The Back and Forward stacks for one reading session.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct NavigationHistory {
    /// Oldest first. The last element is what Back returns next.
    back: Vec<ReaderLocation>,
    /// Oldest first. The last element is what Forward returns next.
    forward: Vec<ReaderLocation>,
}

impl NavigationHistory {
    /// The back stack, oldest first. The last element is the next Back target.
    pub fn back(&self) -> &[ReaderLocation] {
        &self.back
    }

    /// The forward stack, oldest first. The last element is the next Forward target.
    pub fn forward(&self) -> &[ReaderLocation] {
        &self.forward
    }

    pub fn back_len(&self) -> usize {
        self.back.len()
    }

    pub fn forward_len(&self) -> usize {
        self.forward.len()
    }

    pub fn can_go_back(&self) -> bool {
        !self.back.is_empty()
    }

    pub fn can_go_forward(&self) -> bool {
        !self.forward.is_empty()
    }

    /// Records `location` as the place to return to and drops the stale forward branch.
    pub fn record(&mut self, location: ReaderLocation) {
        self.back.push(location);
        // A new jump has a new future: the branch the reader backed out of is stale.
        self.forward.clear();
        self.trim();
    }

    /// Pops the newest back entry and records `current` as the next Forward target.
    ///
    /// Returns `None` — and leaves both stacks untouched — when there is nowhere to go back to.
    pub fn go_back(&mut self, current: ReaderLocation) -> Option<ReaderLocation> {
        let target = self.back.pop()?;
        self.forward.push(current);
        self.trim();
        Some(target)
    }

    /// Mirror of [`Self::go_back`].
    pub fn go_forward(&mut self, current: ReaderLocation) -> Option<ReaderLocation> {
        let target = self.forward.pop()?;
        self.back.push(current);
        self.trim();
        Some(target)
    }

    /// Empties both stacks. Document close/switch and tab switch both call this.
    pub fn clear(&mut self) {
        self.back.clear();
        self.forward.clear();
    }

    fn trim(&mut self) {
        trim_stack(&mut self.back);
        trim_stack(&mut self.forward);
    }
}

/// Drops the oldest entries until the stack is at the limit.
///
/// The forward trim is structurally unreachable while both stacks share the limit (Forward can
/// only grow by a Back, which shrinks Back below the limit first), but it is kept because the
/// pre-change Swift code trimmed both stacks and this type must stay a faithful replacement for
/// any future caller that adds another entry point.
fn trim_stack(stack: &mut Vec<ReaderLocation>) {
    let excess = stack.len().saturating_sub(NAVIGATION_HISTORY_LIMIT);
    if excess > 0 {
        stack.drain(..excess);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn location(page: u32, scroll_y_pt: f64) -> ReaderLocation {
        ReaderLocation {
            page,
            scroll_y_pt,
            selection: None,
        }
    }

    fn selected(page: u32, start: u32, end: u32) -> Option<ReaderSelection> {
        Some(ReaderSelection { page, start, end })
    }

    #[test]
    fn record_appends_oldest_first_and_clears_the_forward_branch() {
        let mut history = NavigationHistory::default();
        assert!(!history.can_go_back() && !history.can_go_forward());

        let first = location(0, 12.5);
        let second = ReaderLocation {
            page: 1,
            scroll_y_pt: 903.25,
            selection: selected(1, 4, 18),
        };
        history.record(first);
        history.record(second);
        assert_eq!(history.back(), &[first, second]);
        assert!(history.forward().is_empty());

        // Back leaves a forward branch; recording again replaces it.
        let current = location(2, 1800.0);
        assert_eq!(history.go_back(current), Some(second));
        assert_eq!(history.back(), &[first]);
        assert_eq!(history.forward(), &[current]);
        history.record(location(3, 0.0));
        assert!(history.forward().is_empty(), "a new jump drops the future");
        assert_eq!(history.back().len(), 2);
    }

    #[test]
    fn back_then_forward_round_trips_the_exact_contents() {
        let mut history = NavigationHistory::default();
        let first = location(0, 0.0);
        let second = location(1, 701.5);
        let third = ReaderLocation {
            page: 2,
            scroll_y_pt: 1304.75,
            selection: selected(2, 0, 9),
        };
        history.record(first);
        history.record(second);
        history.record(third);

        let current = ReaderLocation {
            page: 3,
            scroll_y_pt: 2000.0,
            selection: selected(3, 2, 5),
        };
        assert_eq!(history.go_back(current), Some(third));
        assert_eq!(history.back(), &[first, second]);
        assert_eq!(history.forward(), &[current]);
        assert_eq!(history.go_forward(third), Some(current));
        assert_eq!(history.back(), &[first, second, third]);
        assert_eq!(history.forward(), &[]);
    }

    #[test]
    fn empty_directions_return_none_and_leave_both_stacks_alone() {
        let mut history = NavigationHistory::default();
        let current = location(4, 100.0);
        assert_eq!(history.go_back(current), None);
        assert_eq!(history.go_forward(current), None);
        assert!(!history.can_go_back() && !history.can_go_forward());

        history.record(location(0, 0.0));
        assert_eq!(history.go_forward(current), None);
        assert_eq!(history.back(), &[location(0, 0.0)]);
        assert!(history.forward().is_empty());

        assert_eq!(history.go_back(current), Some(location(0, 0.0)));
        assert_eq!(history.go_back(current), None);
        assert_eq!(history.forward(), &[current]);
    }

    #[test]
    fn trimming_keeps_the_newest_twenty_and_drops_the_oldest() {
        let mut history = NavigationHistory::default();
        for page in 0..25 {
            history.record(location(page, f64::from(page) * 10.0));
        }
        assert_eq!(history.back_len(), NAVIGATION_HISTORY_LIMIT);
        let kept: Vec<u32> = history.back().iter().map(|entry| entry.page).collect();
        assert_eq!(kept, (5..25).collect::<Vec<_>>());
    }

    #[test]
    fn trimming_a_forward_stack_also_drops_the_oldest_entries() {
        let mut stack: Vec<ReaderLocation> = (0..25).map(|page| location(page, 0.0)).collect();
        trim_stack(&mut stack);
        assert_eq!(stack.len(), NAVIGATION_HISTORY_LIMIT);
        assert_eq!(stack.first().map(|entry| entry.page), Some(5));
        assert_eq!(stack.last().map(|entry| entry.page), Some(24));
    }

    #[test]
    fn clear_empties_both_directions() {
        let mut history = NavigationHistory::default();
        history.record(location(0, 1.0));
        history.record(location(1, 2.0));
        let _ = history.go_back(location(2, 3.0));
        assert!(history.can_go_back() && history.can_go_forward());
        history.clear();
        assert!(!history.can_go_back() && !history.can_go_forward());
        assert!(history.back().is_empty() && history.forward().is_empty());
    }
}
