//! Session layer: a **platform-independent reading state machine**.
//!
//! This is the second anti-corruption layer for "port later without rewriting" (`docs/adr/0001`): scroll anchoring, zoom math,
//! layout, page turning, and navigation history all live here; the Swift/GTK/WinUI shells do only two things —
//! **translate UI events into [`Command`]s** and **render [`Event`]s into widgets**.
//!
//! Task mapping: T1.8 (viewport/layout/anchoring), T2.8 (history), T1.4 (scroll approach decision).
//!
//! The navigation-history state machine is in [`navigation`]; the shell drives it through the
//! FFI object `LyraReaderNavigationHistory` and keeps only published mirrors of the stacks.

pub mod command;
pub mod ink;
pub mod layout;
pub mod navigation;
pub mod viewport;

pub use command::{Anchor, Command, Event, Layout, Zoom};
pub use layout::{DocumentLayout, LayoutMode, PagePlacement};
pub use navigation::{
    NAVIGATION_HISTORY_LIMIT, NavigationHistory, ReaderLocation, ReaderSelection,
};
pub use viewport::{
    MAX_ZOOM_PERCENT, MIN_ZOOM_PERCENT, Viewport, ZOOM_PRESET_INSET_PT, ZoomRequest, clamp_scroll,
    resolve_zoom_percent,
};
