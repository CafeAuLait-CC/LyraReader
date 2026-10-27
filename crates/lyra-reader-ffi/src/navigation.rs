//! Back/Forward navigation history as a UniFFI control-plane object.
//!
//! The state machine lives in `lyra-reader-session::navigation`; this module is only the FFI
//! edge. One object owns the two stacks, accepts the reader's current location, and returns the
//! location Back/Forward resolved to. The macOS shell keeps `@Published` mirrors of
//! [`LyraReaderNavigationHistory::snapshot`] for SwiftUI, but never decides push/clear/trim/swap
//! itself.
//!
//! `ReaderLocationRecord` deliberately has no `preview` field. The old Swift value carried the
//! open `ReferencePreview`, but no code path ever restored it (Back does not reopen a panel), so
//! dropping the payload cannot change behaviour.

use std::sync::{Arc, Mutex, MutexGuard};

use lyra_reader_session::navigation::{
    NAVIGATION_HISTORY_LIMIT, NavigationHistory, ReaderLocation, ReaderSelection,
};

/// An inclusive character range on one page, as it crosses the FFI.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ReaderSelectionRecord {
    pub page: u32,
    pub start: u32,
    pub end: u32,
}

/// Where the reader was. `scroll_y_pt` is the exact content offset, not a page top.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct ReaderLocationRecord {
    /// 0-based, the page under the viewport's top edge.
    pub page: u32,
    /// Content offset in points, exactly as the shell held it.
    pub scroll_y_pt: f64,
    pub selection: Option<ReaderSelectionRecord>,
}

impl ReaderLocationRecord {
    fn into_location(self) -> ReaderLocation {
        ReaderLocation {
            page: self.page,
            scroll_y_pt: self.scroll_y_pt,
            selection: self.selection.map(|selection| ReaderSelection {
                page: selection.page,
                start: selection.start,
                end: selection.end,
            }),
        }
    }

    fn from_location(location: ReaderLocation) -> Self {
        Self {
            page: location.page,
            scroll_y_pt: location.scroll_y_pt,
            selection: location.selection.map(|selection| ReaderSelectionRecord {
                page: selection.page,
                start: selection.start,
                end: selection.end,
            }),
        }
    }
}

/// Both stacks in one consistent snapshot, for the shell's published mirrors.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct NavigationHistorySnapshotRecord {
    /// Oldest first; the last element is the next Back target.
    pub back: Vec<ReaderLocationRecord>,
    /// Oldest first; the last element is the next Forward target.
    pub forward: Vec<ReaderLocationRecord>,
}

/// The Back/Forward stacks for one reading session.
#[derive(uniffi::Object)]
pub struct LyraReaderNavigationHistory {
    inner: Mutex<NavigationHistory>,
}

impl LyraReaderNavigationHistory {
    /// Acquires the two stacks, resetting them if an earlier panic poisoned the lock.
    ///
    /// The critical sections only push, pop, drain and clear vectors of immutable value records;
    /// they cannot panic, so poisoning is unreachable through this object. If it ever happened,
    /// the navigation history is disposable UI state: losing it is the same state document close
    /// already produces, and `Back` then behaves exactly as in a freshly opened document. Failing
    /// the reader's `Back` with an error they cannot act on would be worse than the empty state.
    /// This is the documented lock-poisoning exception for rebuildable/disposable state; every
    /// durable lock in the engine still fails fast through `lyra_reader_core::sync::lock`.
    fn history(&self) -> MutexGuard<'_, NavigationHistory> {
        self.inner.lock().unwrap_or_else(|poisoned| {
            let mut history = poisoned.into_inner();
            history.clear();
            history
        })
    }
}

#[uniffi::export]
impl LyraReaderNavigationHistory {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(NavigationHistory::default()),
        })
    }

    /// Records `location` as the place to return to and drops the stale forward branch.
    pub fn record(&self, location: ReaderLocationRecord) {
        self.history().record(location.into_location());
    }

    /// Pops the newest back entry, records `current` as the next Forward target and returns the
    /// location to apply. `None` when there is nowhere to go back to.
    pub fn go_back(&self, current: ReaderLocationRecord) -> Option<ReaderLocationRecord> {
        self.history()
            .go_back(current.into_location())
            .map(ReaderLocationRecord::from_location)
    }

    /// Mirror of [`Self::go_back`].
    pub fn go_forward(&self, current: ReaderLocationRecord) -> Option<ReaderLocationRecord> {
        self.history()
            .go_forward(current.into_location())
            .map(ReaderLocationRecord::from_location)
    }

    /// Empties both stacks.
    pub fn clear(&self) {
        self.history().clear();
    }

    /// The two stacks, oldest first in each.
    pub fn snapshot(&self) -> NavigationHistorySnapshotRecord {
        let history = self.history();
        NavigationHistorySnapshotRecord {
            back: history
                .back()
                .iter()
                .copied()
                .map(ReaderLocationRecord::from_location)
                .collect(),
            forward: history
                .forward()
                .iter()
                .copied()
                .map(ReaderLocationRecord::from_location)
                .collect(),
        }
    }
}

/// How many entries each direction keeps; the shell reads it instead of hard-coding 20.
#[uniffi::export]
pub fn navigation_history_limit() -> u32 {
    NAVIGATION_HISTORY_LIMIT as u32
}
