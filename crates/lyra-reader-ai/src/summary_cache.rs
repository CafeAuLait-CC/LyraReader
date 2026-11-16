//! Portable summaries.json records. Host I/O owns DocumentId, locks and atomic publication.
//! Existing bytes survive unchanged until a validated explicit successful response is stored.
use lyra_reader_edit::records::parse_array_elements_bounded;
use serde::{Deserialize, Serialize};
use serde_json::{Value, value::RawValue};
use std::collections::BTreeMap;

pub const MAX_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_ENTRIES: usize = 600;
pub const MAX_SUMMARY_BYTES: usize = 512 * 1024;
const MAX_SLOTS: usize = 1024;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub layer: String,
    pub unit: String,
    pub model: String,
    pub language: String,
    pub text_hash: String,
    pub title: String,
    pub page_start: u32,
    pub page_end: u32,
    pub summary: String,
    /// Foundation Date's default reference is 2001-01-01, not Unix epoch.
    pub saved_at: f64,
    /// Optional proof from an actually completed sent plan. Legacy records remain unverified.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_pages: Option<Vec<u32>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_sha256: Option<String>,
}

pub fn language_key(language: &str) -> &str {
    let trimmed = language.trim();
    if trimmed.is_empty() {
        "document"
    } else {
        trimmed
    }
}

fn hash_valid(hash: &str) -> bool {
    hash.len() == 64 && hash.bytes().all(|b| b.is_ascii_hexdigit())
}

impl Entry {
    pub fn validate(&self) -> Result<(), String> {
        let unit_valid = match self.layer.as_str() {
            "abstract" => self.unit == "abstract",
            "sections" => self
                .unit
                .strip_prefix("section:")
                .and_then(|s| s.parse::<u32>().ok())
                .is_some(),
            "pages" => self
                .unit
                .strip_prefix("page:")
                .and_then(|s| s.parse::<u32>().ok())
                .is_some_and(|p| p > 0 && p == self.page_start && p == self.page_end),
            _ => false,
        };
        if !unit_valid
            || self.unit.len() > 64
            || !hash_valid(&self.text_hash)
            || self.model.is_empty()
            || self.model.len() > 4096
            || self.language.is_empty()
            || self.language.len() > 512
            || self.title.len() > 64 * 1024
            || self.summary.len() > MAX_SUMMARY_BYTES
            || self.summary.trim().is_empty()
            || !self.saved_at.is_finite()
            || self.page_start == 0
            || self.page_end < self.page_start
            || self
                .source_pages
                .as_ref()
                .is_some_and(|p| p.len() > 4096 || p.contains(&0))
            || self.source_sha256.as_ref().is_some_and(|s| !hash_valid(s))
        {
            return Err("Invalid or oversized saved summary; original cache was kept".into());
        }
        Ok(())
    }
    fn same_key(&self, other: &Self) -> bool {
        self.layer == other.layer
            && self.unit == other.unit
            && self.model == other.model
            && self.language == other.language
    }
    pub fn verified_pages(&self, sha256: &str, page_count: u32) -> Vec<u32> {
        if self.source_sha256.as_deref() != Some(sha256) {
            return Vec::new();
        }
        self.source_pages
            .as_deref()
            .unwrap_or(&[])
            .iter()
            .copied()
            .filter(|page| *page > 0 && *page <= page_count)
            .collect()
    }
}

#[derive(Clone)]
struct StoredEntry {
    entry: Entry,
    raw: String,
}

#[derive(Clone, Default)]
pub struct Cache {
    entries: Vec<StoredEntry>,
    original: Option<Vec<u8>>,
    pub warning: Option<String>,
}

struct Root(BTreeMap<String, Box<RawValue>>);
impl<'de> Deserialize<'de> for Root {
    fn deserialize<D: serde::Deserializer<'de>>(decoder: D) -> Result<Self, D::Error> {
        struct Visitor;
        impl<'de> serde::de::Visitor<'de> for Visitor {
            type Value = Root;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("a bounded summary cache object")
            }
            fn visit_map<M: serde::de::MapAccess<'de>>(self, mut map: M) -> Result<Root, M::Error> {
                let mut fields = BTreeMap::new();
                while let Some(key) = map.next_key::<String>()? {
                    if fields.len() >= 32 || fields.contains_key(&key) {
                        return Err(serde::de::Error::custom(
                            "Too many or duplicate summary cache fields",
                        ));
                    }
                    fields.insert(key, map.next_value()?);
                }
                Ok(Root(fields))
            }
        }
        decoder.deserialize_map(Visitor)
    }
}

impl Cache {
    pub fn decode(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() > MAX_BYTES {
            return Err("The summary cache exceeds its 8 MiB limit; original data was kept".into());
        }
        let root: Root = serde_json::from_slice(bytes).map_err(|e| {
            format!("The summary cache could not be read; original data was kept: {e}")
        })?;
        let raw = root
            .0
            .get("entries")
            .ok_or("The summary cache has no entries array; original data was kept")?;
        let slots = parse_array_elements_bounded(raw.get().as_bytes(), MAX_SLOTS)
            .map_err(|e| e.to_string())?;
        let mut result = Self {
            entries: Vec::new(),
            original: Some(bytes.to_vec()),
            warning: None,
        };
        let mut protected = root.0.len() != 1;
        for slot in slots {
            // The whole input is already bounded. JSON escapes can make a valid 512 KiB
            // answer larger than one MiB on disk; the decoder must accept its own writer.
            let parsed = serde_json::from_str::<Entry>(&slot);
            if let Ok(entry) = parsed
                && entry.validate().is_ok()
            {
                let value: Value = serde_json::from_str(&slot).map_err(|e| e.to_string())?;
                let fields = [
                    "layer",
                    "unit",
                    "model",
                    "language",
                    "textHash",
                    "title",
                    "pageStart",
                    "pageEnd",
                    "summary",
                    "savedAt",
                    "sourcePages",
                    "sourceSha256",
                ];
                protected |= value
                    .as_object()
                    .is_some_and(|o| o.keys().any(|k| !fields.contains(&k.as_str())));
                result.entries.push(StoredEntry { entry, raw: slot });
            } else {
                protected = true;
            }
        }
        if protected || result.entries.len() > MAX_ENTRIES {
            result.warning = Some("The summary cache contains foreign, unreadable or excess records. Readable summaries remain available; saving is blocked and original bytes were kept".into());
        }
        Ok(result)
    }
    pub fn find(
        &self,
        layer: &str,
        unit: &str,
        model: &str,
        language: &str,
        hash: &str,
    ) -> Option<(&Entry, bool)> {
        let matching = |e: &&Entry| {
            e.layer == layer
                && e.unit == unit
                && e.model == model
                && e.language == language_key(language)
        };
        if let Some(entry) = self
            .entries
            .iter()
            .map(|stored| &stored.entry)
            .filter(matching)
            .find(|e| e.text_hash == hash)
        {
            return Some((entry, true));
        }
        self.entries
            .iter()
            .map(|stored| &stored.entry)
            .filter(matching)
            .reduce(|best, next| {
                if next.saved_at > best.saved_at {
                    next
                } else {
                    best
                }
            })
            .map(|e| (e, false))
    }
    pub fn put(&mut self, entry: Entry) -> Result<(), String> {
        if let Some(warning) = &self.warning {
            return Err(warning.clone());
        }
        entry.validate()?;
        let mut next = self.entries.clone();
        next.retain(|old| !old.entry.same_key(&entry));
        let raw = crate::region_history::foundation_json(
            &serde_json::to_value(&entry).map_err(|e| e.to_string())?,
        )?;
        next.push(StoredEntry { entry, raw });
        if next.len() > MAX_ENTRIES {
            next.sort_by(|a, b| a.entry.saved_at.total_cmp(&b.entry.saved_at));
            next.drain(..next.len() - MAX_ENTRIES);
        }
        let oversized =
            "The completed summary would exceed the 8 MiB cache limit; the previous cache was kept";
        const PREFIX: &[u8] = b"{\"entries\":[";
        let size = next.iter().try_fold(
            PREFIX.len() + 2 + next.len().saturating_sub(1),
            |size, stored| {
                size.checked_add(stored.raw.len())
                    .filter(|n| *n <= MAX_BYTES)
                    .ok_or(oversized)
            },
        )?;
        let mut bytes = Vec::new();
        bytes.try_reserve_exact(size).map_err(
            |_| "The summary cache buffer could not be allocated; the previous cache was kept",
        )?;
        bytes.extend_from_slice(PREFIX);
        for (index, stored) in next.iter().enumerate() {
            if index > 0 {
                bytes.push(b',');
            }
            bytes.extend_from_slice(stored.raw.as_bytes());
        }
        bytes.extend_from_slice(b"]}");
        self.entries = next;
        self.original = Some(bytes);
        Ok(())
    }
    pub fn encode(&self) -> &[u8] {
        self.original.as_deref().unwrap_or(b"{\"entries\":[]}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn entry(unit: u32) -> Entry {
        Entry {
            layer: "pages".into(),
            unit: format!("page:{unit}"),
            model: "synthetic".into(),
            language: "document".into(),
            text_hash: "a".repeat(64),
            title: "α / title".into(),
            page_start: unit,
            page_end: unit,
            summary: "Synthetic / summary".into(),
            saved_at: f64::from(unit),
            source_pages: None,
            source_sha256: None,
        }
    }
    #[test]
    fn escaped_answers_at_the_text_limit_reopen_without_becoming_foreign() {
        let mut cached = entry(1);
        cached.summary = "\u{1}".repeat(MAX_SUMMARY_BYTES);
        let mut cache = Cache::default();
        cache.put(cached.clone()).unwrap();
        assert!(cache.encode().len() > 1024 * 1024);
        let reopened = Cache::decode(cache.encode()).unwrap();
        assert!(reopened.warning.is_none());
        assert_eq!(
            reopened
                .find("pages", "page:1", "synthetic", "", &cached.text_hash)
                .unwrap()
                .0
                .summary,
            cached.summary
        );
    }
    #[test]
    fn sent_document_knowledge_sources_may_extend_beyond_the_summary_unit() {
        let mut cached = entry(1);
        cached.source_pages = Some(vec![1, 3]);
        cached.source_sha256 = Some("b".repeat(64));
        cached.validate().unwrap();
        assert_eq!(cached.verified_pages(&"b".repeat(64), 3), vec![1, 3]);
        assert!(cached.verified_pages(&"a".repeat(64), 3).is_empty());
    }
    #[test]
    fn storing_another_unit_preserves_untouched_legacy_entry_bytes() {
        let raw = serde_json::to_string(&entry(1))
            .unwrap()
            .replace("\"savedAt\":1.0", "\"savedAt\" : 1.000000000e0")
            .replace("Synthetic / summary", "Legacy \\/ summary");
        let original = format!(" {{ \"entries\" : [ {raw} ] }}\n");
        let mut cache = Cache::decode(original.as_bytes()).unwrap();
        assert_eq!(cache.encode(), original.as_bytes());
        cache.put(entry(2)).unwrap();
        assert!(std::str::from_utf8(cache.encode()).unwrap().contains(&raw));
        assert_eq!(
            Cache::decode(cache.encode())
                .unwrap()
                .find("pages", "page:1", "synthetic", "", &"a".repeat(64))
                .unwrap()
                .0
                .summary,
            "Legacy / summary"
        );
    }
    #[test]
    fn the_total_byte_budget_rejects_a_new_entry_without_evicting_previous_answers() {
        let mut cache = Cache::default();
        let mut rejected = false;
        for index in 1..=20 {
            let mut next = entry(index);
            next.summary = "s".repeat(MAX_SUMMARY_BYTES);
            let previous = cache.encode().to_vec();
            match cache.put(next) {
                Ok(()) => assert!(cache.encode().len() <= MAX_BYTES),
                Err(error) => {
                    assert!(error.contains("8 MiB"));
                    assert_eq!(cache.encode(), previous);
                    assert!(
                        cache
                            .find(
                                "pages",
                                &format!("page:{index}"),
                                "synthetic",
                                "",
                                &"a".repeat(64)
                            )
                            .is_none()
                    );
                    rejected = true;
                    break;
                }
            }
        }
        assert!(rejected);
    }
    #[test]
    fn matches_exact_then_latest_stale_and_keeps_other_models_and_languages() {
        let mut c = Cache::default();
        c.put(entry(1)).unwrap();
        assert!(
            c.find("pages", "page:1", "synthetic", "  ", &"a".repeat(64))
                .unwrap()
                .1
        );
        assert!(
            !c.find("pages", "page:1", "synthetic", "document", &"b".repeat(64))
                .unwrap()
                .1
        );
        assert!(
            c.find("pages", "page:1", "other", "", &"a".repeat(64))
                .is_none()
        );
        let mut french = entry(1);
        french.language = "fr".into();
        c.put(french).unwrap();
        assert_eq!(Cache::decode(c.encode()).unwrap().entries.len(), 2);
    }
    #[test]
    fn opaque_root_and_entry_fields_and_unreadable_rows_block_writes_without_losing_readable_data()
    {
        let known = serde_json::to_value(entry(1)).unwrap();
        for raw in [
            serde_json::json!({"entries":[known.clone(),{"future":true}]}),
            serde_json::json!({"entries":[known.clone()],"future":{"x":1e-7}}),
        ] {
            let bytes = serde_json::to_vec(&raw).unwrap();
            let mut c = Cache::decode(&bytes).unwrap();
            assert!(c.warning.is_some());
            assert!(
                c.find("pages", "page:1", "synthetic", "", &"a".repeat(64))
                    .is_some()
            );
            assert!(c.put(entry(2)).is_err());
            assert_eq!(c.encode(), bytes);
        }
        let mut future = known;
        future["foreign"] = serde_json::json!("raw / preserved");
        let bytes = serde_json::to_vec(&serde_json::json!({"entries":[future]})).unwrap();
        let mut c = Cache::decode(&bytes).unwrap();
        assert!(c.put(entry(2)).is_err());
        assert_eq!(c.encode(), bytes);
    }
    #[test]
    fn replacement_and_six_hundred_oldest_eviction_share_the_legacy_four_part_key() {
        let mut c = Cache::default();
        for i in 1..=601 {
            c.put(entry(i)).unwrap();
        }
        assert_eq!(c.entries.len(), 600);
        assert!(
            c.find("pages", "page:1", "synthetic", "", &"a".repeat(64))
                .is_none()
        );
        let mut changed = entry(2);
        changed.text_hash = "b".repeat(64);
        c.put(changed).unwrap();
        assert_eq!(c.entries.len(), 600);
        assert_eq!(
            c.entries
                .iter()
                .filter(|e| e.entry.unit == "page:2")
                .count(),
            1
        );
    }
    #[test]
    fn bounds_and_malformed_data_fail_before_overwriting_the_original() {
        assert!(Cache::decode(&vec![b' '; MAX_BYTES + 1]).is_err());
        assert!(Cache::decode(b"{\"entries\":[").is_err());
        assert!(Cache::decode(b"{\"entries\":[],\"entries\":[]}").is_err());
        let raw = format!(
            "{{\"entries\":[{}]}}",
            vec!["null"; MAX_SLOTS + 1].join(",")
        );
        assert!(Cache::decode(raw.as_bytes()).is_err());
        let mut c = Cache::default();
        c.put(entry(1)).unwrap();
        let before = c.encode().to_vec();
        let mut bad = entry(2);
        bad.summary = "a".repeat(MAX_SUMMARY_BYTES + 1);
        assert!(c.put(bad).is_err());
        assert_eq!(c.encode(), before);
    }
    #[test]
    fn foundation_primitives_and_legacy_missing_provenance_are_not_fabricated() {
        let mut c = Cache::default();
        c.put(entry(1)).unwrap();
        let text = std::str::from_utf8(c.encode()).unwrap();
        assert!(text.contains("Synthetic \\/ summary"));
        assert!(text.contains("\"savedAt\":1"));
        let loaded = Cache::decode(c.encode()).unwrap();
        assert_eq!(loaded.entries[0].entry.saved_at, 1.0);
        assert!(
            loaded.entries[0]
                .entry
                .verified_pages(&"a".repeat(64), 3)
                .is_empty()
        );
        assert_eq!(loaded.encode(), c.encode());
    }
}
