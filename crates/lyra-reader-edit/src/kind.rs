//! The one annotation-kind taxonomy.
//!
//! The durable annotation cache (`annotations.json`), the PDF's own annotation reader, the
//! shell's write request and PDFium's writer each had their own name for the same handful of
//! marks: `stickyNote` in the cache is `/Text` in the file and `note` in a write request;
//! `textBox` is `/FreeText` and `freeText`; an `arrow` is a `/Line` with a head. Every place
//! that asked "is this markup?", "is it a placed box?", "can it be edited?" or "which write
//! kind does it become?" re-derived the answer with its own `switch`.
//!
//! This module states the table once. [`AnnotationKind`] is the union of every vocabulary;
//! [`AnnotationKind::flags`] is the answer a caller needs; and the two conversion functions
//! ([`AnnotationKind::from_record_kind`], [`AnnotationKind::from_document_kind`]) are where this
//! table turns a name into a kind.
//!
//! The kind half of each predicate is stated once, here. `lyra-reader-ffi` mirrors the vocabulary
//! across UniFFI ([`WriteKind`] is re-declared there as `AnnotationWriteKind`, because uniffi
//! exports the enums of the crate that derives them) and projects [`AnnotationKind::RECORD_KINDS`]
//! row by row through `annotation_kind_flags()`; the shell's `AppState.Annotation.Kind` is the
//! display vocabulary, so it decodes a cache name and draws the mark but reads every predicate
//! from that projection.
//!
//! # Adding a kind
//!
//! A cache kind is one edit here: a variant, its name in [`AnnotationKind::record_name`] and
//! [`AnnotationKind::from_record_kind`], a [`AnnotationKind::flags`] row, and an entry in
//! [`AnnotationKind::RECORD_KINDS`]. A kind this build only reads from a PDF (the way `squiggly`
//! is) needs [`AnnotationKind::from_document_kind`] and [`AnnotationKind::document_name`] instead
//! of the cache names. A new *write* kind also adds a [`WriteKind`] variant; the exhaustive
//! conversion in `lyra-reader-ffi` then fails to compile until its arm is added. The shell adds
//! its `Kind` case and its drawing arm, and `AnnotationCodecChecks` fails if the table and that
//! enum stop naming the same cache kinds.
//!
//! The flags deliberately preserve today's answers, including two asymmetries that are part of
//! the current behaviour rather than accidents to fix here:
//!
//! * `squiggly` is markup (and drawn as markup) but the shell has no editable model for it;
//! * a `/Line` carrying an arrowhead is reported to the shell as `arrow`, which the shell does
//!   not list as editable. This table keeps that answer; changing it would be a visible change.

/// Every kind the durable model, the PDF reader and the writer can name.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum AnnotationKind {
    Highlight,
    Underline,
    Strikeout,
    Squiggly,
    Ink,
    Square,
    Circle,
    Line,
    /// A line whose `/LE` (or `/Subj`) names an arrowhead. The PDF subtype is still `/Line`.
    Arrow,
    /// A `/Text` sticky note; `stickyNote` in the annotation cache.
    StickyNote,
    /// A `/FreeText` box; `textBox` in the annotation cache.
    TextBox,
    /// A `/Stamp` badge carrying words and/or a picture.
    Stamp,
    /// A `/Stamp` whose appearance is an image signature.
    Signature,
    /// A subtype this build does not model; the PDF's own name is carried with it.
    Other(String),
}

/// The write kind a shell request becomes in the PDF.
///
/// This mirrors the FFI enum field-for-field. It lives here so the taxonomy can name the write
/// kind without the edit crate depending on the FFI crate.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WriteKind {
    Highlight,
    Underline,
    StrikeOut,
    Squiggly,
    Note,
    FreeText,
    Ink,
    Square,
    Circle,
    Line,
    Stamp,
    Signature,
}

impl WriteKind {
    /// The variant name used by the FFI enum, so a binding generator and this table cannot
    /// disagree about spelling.
    pub fn ffi_name(self) -> &'static str {
        match self {
            Self::Highlight => "highlight",
            Self::Underline => "underline",
            Self::StrikeOut => "strikeOut",
            Self::Squiggly => "squiggly",
            Self::Note => "note",
            Self::FreeText => "freeText",
            Self::Ink => "ink",
            Self::Square => "square",
            Self::Circle => "circle",
            Self::Line => "line",
            Self::Stamp => "stamp",
            Self::Signature => "signature",
        }
    }
}

/// What a reader should put on the page for one annotation.
///
/// The same five drawn values the engine reports across the FFI, plus `Skipped`. Stating it in
/// the taxonomy lets the shell's kind table and the engine's per-file classification agree by
/// construction.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Drawing {
    /// A tinted box per quad (the four text-markup kinds).
    Markup,
    /// A `/Text` sticky-note icon.
    NoteIcon,
    /// A `/FreeText` annotation's own text.
    FreeText,
    /// A stroked path drawn from page-space geometry.
    Geometry,
    /// A stamp badge, from its words or its picture.
    Stamp,
    /// Nothing is drawn.
    Skipped,
}

impl Drawing {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Markup => "markup",
            Self::NoteIcon => "noteIcon",
            Self::FreeText => "freeText",
            Self::Geometry => "geometry",
            Self::Stamp => "stamp",
            Self::Skipped => "skipped",
        }
    }
}

/// Everything a caller may ask a kind about.
///
/// `is_markup` is the reader's display predicate (it includes `squiggly`, which is drawn as a
/// mark). `is_text_markup` is the shell's creation predicate (the three kinds a selection can
/// become). They are separate on purpose: `squiggly` is the fourth markup kind in a PDF but is
/// not a tool this build offers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KindFlags {
    pub is_markup: bool,
    pub is_text_markup: bool,
    pub is_geometry: bool,
    pub is_note: bool,
    pub is_placed_text: bool,
    pub is_stamp_artwork: bool,
    pub is_placement: bool,
    pub drawing: Drawing,
    pub write_kind: Option<WriteKind>,
    /// The version the annotation cache writes for this kind; `None` for the text-markup kinds,
    /// which carry no version at all.
    pub schema_version: Option<u32>,
    /// Whether this kind can be an entry in the durable annotation cache.
    pub in_records: bool,
}

impl AnnotationKind {
    /// Every kind the durable annotation cache can store, in the table's order.
    ///
    /// This is the table's key set: the cache's `"kind"` names, the shell's
    /// `AppState.Annotation.Kind` cases and the rows `annotation_kind_flags()` exports are the
    /// same list. A kind this build only reads from a PDF (`squiggly`, an unmodelled subtype) is
    /// deliberately absent: it has no cache entry and no write request.
    pub const RECORD_KINDS: &'static [AnnotationKind] = &[
        Self::Highlight,
        Self::Underline,
        Self::Strikeout,
        Self::Ink,
        Self::Square,
        Self::Circle,
        Self::Line,
        Self::Arrow,
        Self::StickyNote,
        Self::TextBox,
        Self::Stamp,
        Self::Signature,
    ];

    /// The name the annotation cache stores in `"kind"`, or `None` when the kind is not a cache
    /// kind (a `squiggly` and an unknown PDF subtype are read from a PDF, not written by this
    /// reader).
    pub fn record_name(&self) -> Option<&'static str> {
        match self {
            Self::Highlight => Some("highlight"),
            Self::Underline => Some("underline"),
            Self::Strikeout => Some("strikeout"),
            Self::Ink => Some("ink"),
            Self::Square => Some("square"),
            Self::Circle => Some("circle"),
            Self::Line => Some("line"),
            Self::Arrow => Some("arrow"),
            Self::StickyNote => Some("stickyNote"),
            Self::TextBox => Some("textBox"),
            Self::Stamp => Some("stamp"),
            Self::Signature => Some("signature"),
            Self::Squiggly | Self::Other(_) => None,
        }
    }

    /// Parses the annotation cache's `"kind"` value. Unknown names are not cache kinds.
    pub fn from_record_kind(name: &str) -> Option<Self> {
        Some(match name {
            "highlight" => Self::Highlight,
            "underline" => Self::Underline,
            "strikeout" => Self::Strikeout,
            "ink" => Self::Ink,
            "square" => Self::Square,
            "circle" => Self::Circle,
            "line" => Self::Line,
            "arrow" => Self::Arrow,
            "stickyNote" => Self::StickyNote,
            "textBox" => Self::TextBox,
            "stamp" => Self::Stamp,
            "signature" => Self::Signature,
            _ => return None,
        })
    }

    /// Parses the kind string the engine reports for an annotation inside a PDF.
    ///
    /// Anything this build does not model becomes [`Self::Other`], carrying the PDF's own name,
    /// so a caller can still say which subtype it was instead of pretending it was a highlight.
    pub fn from_document_kind(name: &str) -> Self {
        match name {
            "highlight" => Self::Highlight,
            "underline" => Self::Underline,
            "strikeout" => Self::Strikeout,
            "squiggly" => Self::Squiggly,
            "ink" => Self::Ink,
            "square" => Self::Square,
            "circle" => Self::Circle,
            "line" => Self::Line,
            "arrow" => Self::Arrow,
            "text" => Self::StickyNote,
            "freeText" => Self::TextBox,
            "stamp" => Self::Stamp,
            other => Self::Other(other.to_string()),
        }
    }

    /// The name the engine reports for this kind (`text` and `freeText` for placed text).
    pub fn document_name(&self) -> &str {
        match self {
            Self::Highlight => "highlight",
            Self::Underline => "underline",
            Self::Strikeout => "strikeout",
            Self::Squiggly => "squiggly",
            Self::Ink => "ink",
            Self::Square => "square",
            Self::Circle => "circle",
            Self::Line => "line",
            Self::Arrow => "arrow",
            Self::StickyNote => "text",
            Self::TextBox => "freeText",
            Self::Stamp => "stamp",
            Self::Signature => "stamp",
            Self::Other(name) => name,
        }
    }

    /// The flags every caller derives from a kind.
    pub fn flags(&self) -> KindFlags {
        match self {
            Self::Highlight => KindFlags {
                is_markup: true,
                is_text_markup: true,
                is_geometry: false,
                is_note: false,
                is_placed_text: false,
                is_stamp_artwork: false,
                is_placement: false,
                drawing: Drawing::Markup,
                write_kind: Some(WriteKind::Highlight),
                schema_version: None,
                in_records: true,
            },
            Self::Underline => KindFlags {
                is_markup: true,
                is_text_markup: true,
                drawing: Drawing::Markup,
                write_kind: Some(WriteKind::Underline),
                in_records: true,
                ..Self::Highlight.flags()
            },
            Self::Strikeout => KindFlags {
                is_markup: true,
                is_text_markup: true,
                drawing: Drawing::Markup,
                write_kind: Some(WriteKind::StrikeOut),
                in_records: true,
                ..Self::Highlight.flags()
            },
            Self::Squiggly => KindFlags {
                is_markup: true,
                is_text_markup: false,
                is_geometry: false,
                is_note: false,
                is_placed_text: false,
                is_stamp_artwork: false,
                is_placement: false,
                drawing: Drawing::Markup,
                write_kind: Some(WriteKind::Squiggly),
                schema_version: None,
                in_records: false,
            },
            Self::Ink => KindFlags {
                is_markup: false,
                is_text_markup: false,
                is_geometry: true,
                is_note: false,
                is_placed_text: false,
                is_stamp_artwork: false,
                is_placement: true,
                drawing: Drawing::Geometry,
                write_kind: Some(WriteKind::Ink),
                schema_version: Some(1),
                in_records: true,
            },
            Self::Square => KindFlags {
                is_geometry: true,
                is_placement: true,
                drawing: Drawing::Geometry,
                write_kind: Some(WriteKind::Square),
                schema_version: Some(1),
                in_records: true,
                ..Self::Ink.flags()
            },
            Self::Circle => KindFlags {
                is_geometry: true,
                is_placement: true,
                drawing: Drawing::Geometry,
                write_kind: Some(WriteKind::Circle),
                schema_version: Some(1),
                in_records: true,
                ..Self::Ink.flags()
            },
            Self::Line => KindFlags {
                is_geometry: true,
                is_placement: true,
                drawing: Drawing::Geometry,
                write_kind: Some(WriteKind::Line),
                schema_version: Some(1),
                in_records: true,
                ..Self::Ink.flags()
            },
            Self::Arrow => KindFlags {
                is_geometry: true,
                is_placement: true,
                drawing: Drawing::Geometry,
                write_kind: Some(WriteKind::Line),
                schema_version: Some(1),
                in_records: true,
                ..Self::Ink.flags()
            },
            Self::StickyNote => KindFlags {
                is_markup: false,
                is_text_markup: false,
                is_geometry: false,
                is_note: true,
                is_placed_text: true,
                is_stamp_artwork: false,
                is_placement: true,
                drawing: Drawing::NoteIcon,
                write_kind: Some(WriteKind::Note),
                schema_version: Some(1),
                in_records: true,
            },
            Self::TextBox => KindFlags {
                is_note: true,
                is_placed_text: true,
                is_placement: true,
                drawing: Drawing::FreeText,
                write_kind: Some(WriteKind::FreeText),
                schema_version: Some(1),
                in_records: true,
                ..Self::StickyNote.flags()
            },
            Self::Stamp => KindFlags {
                is_markup: false,
                is_text_markup: false,
                is_geometry: false,
                is_note: false,
                is_placed_text: false,
                is_stamp_artwork: true,
                is_placement: true,
                drawing: Drawing::Stamp,
                write_kind: Some(WriteKind::Stamp),
                schema_version: Some(1),
                in_records: true,
            },
            Self::Signature => KindFlags {
                is_stamp_artwork: true,
                is_placement: true,
                drawing: Drawing::Stamp,
                write_kind: Some(WriteKind::Signature),
                schema_version: Some(1),
                in_records: true,
                ..Self::Stamp.flags()
            },
            Self::Other(_) => KindFlags {
                is_markup: false,
                is_text_markup: false,
                is_geometry: false,
                is_note: false,
                is_placed_text: false,
                is_stamp_artwork: false,
                is_placement: false,
                drawing: Drawing::Skipped,
                write_kind: None,
                schema_version: None,
                in_records: false,
            },
        }
    }

    /// Whether the file's annotation can be moved, resized, recoloured or deleted here, with the
    /// reason when it cannot.
    ///
    /// This is only the kind half of the policy. The other half depends on the instance: a reply,
    /// a hidden annotation, an ink entry with no strokes, a line with no endpoints, a stamp whose
    /// picture would not decode, or an annotation the reader does not draw. The caller applies
    /// those in the order the shell always has, using the same strings.
    pub fn kind_editability(&self) -> (bool, Option<String>) {
        match self {
            Self::Squiggly => (
                false,
                Some(
                    "LyraReader has no editable model for /Squiggly; editing it would have to \
                     change the mark's subtype."
                        .to_string(),
                ),
            ),
            Self::Other(name) => (
                false,
                Some(format!(
                    "LyraReader has no editable model for a /{name} annotation yet."
                )),
            ),
            // The shell has never listed an arrow (a `/Line` with a head) as editable: the
            // engine reports it as `arrow` and the editability switch only names `line`.
            // Keeping that answer is part of "no visible change"; see this module's header.
            Self::Arrow => (
                false,
                Some("LyraReader has no editable model for a /arrow annotation yet.".to_string()),
            ),
            _ => (true, None),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The golden cache-kind names, so the table and the wire vocabulary cannot move alone.
    const GOLDEN_RECORD_KINDS: &[(&str, AnnotationKind)] = &[
        ("highlight", AnnotationKind::Highlight),
        ("underline", AnnotationKind::Underline),
        ("strikeout", AnnotationKind::Strikeout),
        ("ink", AnnotationKind::Ink),
        ("square", AnnotationKind::Square),
        ("circle", AnnotationKind::Circle),
        ("line", AnnotationKind::Line),
        ("arrow", AnnotationKind::Arrow),
        ("stickyNote", AnnotationKind::StickyNote),
        ("textBox", AnnotationKind::TextBox),
        ("stamp", AnnotationKind::Stamp),
        ("signature", AnnotationKind::Signature),
    ];

    #[test]
    fn record_kind_names_round_trip() {
        for (name, kind) in GOLDEN_RECORD_KINDS {
            assert_eq!(kind.record_name(), Some(*name));
            assert_eq!(AnnotationKind::from_record_kind(name).as_ref(), Some(kind));
        }
        assert_eq!(AnnotationKind::from_record_kind("squiggly"), None);
        assert_eq!(AnnotationKind::from_record_kind("futureMark"), None);
    }

    #[test]
    fn record_kinds_is_the_table_key_set() {
        // The public list is what the flags rows and the FFI projection are keyed by. Comparing
        // it with the golden names forces both to move for a new kind; the shell check then
        // forces `AppState.Annotation.Kind`.
        let listed: Vec<Option<&str>> = AnnotationKind::RECORD_KINDS
            .iter()
            .map(AnnotationKind::record_name)
            .collect();
        let golden: Vec<Option<&str>> = GOLDEN_RECORD_KINDS
            .iter()
            .map(|(name, _)| Some(*name))
            .collect();
        assert_eq!(listed, golden);
        for kind in AnnotationKind::RECORD_KINDS {
            assert!(
                kind.flags().in_records,
                "{kind:?} is listed as a cache kind but its flags say it is not"
            );
            let name = kind.record_name().expect("a cache kind has a name");
            assert_eq!(
                AnnotationKind::from_record_kind(name),
                Some(kind.clone()),
                "{kind:?}"
            );
        }
        // A read-only kind is not a cache kind, in either direction.
        for kind in [
            AnnotationKind::Squiggly,
            AnnotationKind::Other("Polygon".into()),
        ] {
            assert!(!AnnotationKind::RECORD_KINDS.contains(&kind), "{kind:?}");
            assert!(kind.record_name().is_none(), "{kind:?}");
        }
    }

    #[test]
    fn document_kind_names_round_trip() {
        for (name, kind) in [
            ("highlight", AnnotationKind::Highlight),
            ("underline", AnnotationKind::Underline),
            ("strikeout", AnnotationKind::Strikeout),
            ("squiggly", AnnotationKind::Squiggly),
            ("text", AnnotationKind::StickyNote),
            ("freeText", AnnotationKind::TextBox),
            ("ink", AnnotationKind::Ink),
            ("square", AnnotationKind::Square),
            ("circle", AnnotationKind::Circle),
            ("line", AnnotationKind::Line),
            ("arrow", AnnotationKind::Arrow),
            ("stamp", AnnotationKind::Stamp),
        ] {
            assert_eq!(AnnotationKind::from_document_kind(name), kind);
            assert_eq!(kind.document_name(), name);
        }
        let other = AnnotationKind::from_document_kind("Ink");
        assert_eq!(other, AnnotationKind::Other("Ink".to_string()));
        assert_eq!(other.document_name(), "Ink");
        assert_eq!(other.flags().drawing, Drawing::Skipped);
    }

    /// The flags the shell computed before this table existed, for every kind.
    ///
    /// `(isMarkup, isGeometry, isNote, isPlacedText, isStampArtwork, isPlacement, drawing)`
    #[test]
    fn kind_flags_match_the_swift_predicates() {
        let expected: &[(AnnotationKind, [bool; 6], Drawing)] = &[
            (
                AnnotationKind::Highlight,
                [true, false, false, false, false, false],
                Drawing::Markup,
            ),
            (
                AnnotationKind::Underline,
                [true, false, false, false, false, false],
                Drawing::Markup,
            ),
            (
                AnnotationKind::Strikeout,
                [true, false, false, false, false, false],
                Drawing::Markup,
            ),
            (
                AnnotationKind::Squiggly,
                [true, false, false, false, false, false],
                Drawing::Markup,
            ),
            (
                AnnotationKind::Ink,
                [false, true, false, false, false, true],
                Drawing::Geometry,
            ),
            (
                AnnotationKind::Square,
                [false, true, false, false, false, true],
                Drawing::Geometry,
            ),
            (
                AnnotationKind::Circle,
                [false, true, false, false, false, true],
                Drawing::Geometry,
            ),
            (
                AnnotationKind::Line,
                [false, true, false, false, false, true],
                Drawing::Geometry,
            ),
            (
                AnnotationKind::Arrow,
                [false, true, false, false, false, true],
                Drawing::Geometry,
            ),
            (
                AnnotationKind::StickyNote,
                [false, false, true, true, false, true],
                Drawing::NoteIcon,
            ),
            (
                AnnotationKind::TextBox,
                [false, false, true, true, false, true],
                Drawing::FreeText,
            ),
            (
                AnnotationKind::Stamp,
                [false, false, false, false, true, true],
                Drawing::Stamp,
            ),
            (
                AnnotationKind::Signature,
                [false, false, false, false, true, true],
                Drawing::Stamp,
            ),
            (
                AnnotationKind::Other("Polygon".into()),
                [false, false, false, false, false, false],
                Drawing::Skipped,
            ),
        ];
        for (kind, flags, drawing) in expected {
            let actual = kind.flags();
            assert_eq!(
                [
                    actual.is_markup,
                    actual.is_geometry,
                    actual.is_note,
                    actual.is_placed_text,
                    actual.is_stamp_artwork,
                    actual.is_placement
                ],
                *flags,
                "{kind:?}"
            );
            assert_eq!(actual.drawing, *drawing, "{kind:?}");
        }
    }

    #[test]
    fn write_kinds_cover_every_creatable_record_kind() {
        for (_, kind) in GOLDEN_RECORD_KINDS {
            assert!(kind.flags().write_kind.is_some(), "{kind:?}");
        }
        for kind in [AnnotationKind::Squiggly, AnnotationKind::Other("X".into())] {
            let _ = kind.flags().write_kind; // squiggly has one, unknown does not
        }
        assert_eq!(
            AnnotationKind::StickyNote.flags().write_kind,
            Some(WriteKind::Note)
        );
        assert_eq!(
            AnnotationKind::TextBox.flags().write_kind,
            Some(WriteKind::FreeText)
        );
        assert_eq!(
            AnnotationKind::Arrow.flags().write_kind,
            Some(WriteKind::Line)
        );
        assert_eq!(
            AnnotationKind::Squiggly.flags().write_kind,
            Some(WriteKind::Squiggly)
        );
        assert_eq!(AnnotationKind::Other("X".into()).flags().write_kind, None);
    }

    #[test]
    fn editability_matches_the_swift_policy() {
        for (_, kind) in GOLDEN_RECORD_KINDS {
            let (editable, reason) = kind.kind_editability();
            let expected = *kind != AnnotationKind::Arrow;
            assert_eq!(editable, expected, "{kind:?}");
            assert_eq!(reason.is_some(), !expected, "{kind:?}");
        }
        let (editable, reason) = AnnotationKind::Squiggly.kind_editability();
        assert!(!editable);
        assert_eq!(
            reason.as_deref(),
            Some(
                "LyraReader has no editable model for /Squiggly; editing it would have to \
                 change the mark's subtype."
            )
        );
        let (editable, reason) = AnnotationKind::Other("Polygon".into()).kind_editability();
        assert!(!editable);
        assert_eq!(
            reason.as_deref(),
            Some("LyraReader has no editable model for a /Polygon annotation yet.")
        );
    }
}
