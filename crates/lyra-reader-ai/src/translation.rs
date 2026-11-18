//! Portable in-place translation identities and the existing translations.json format.
//! The host owns source verification, advisory locks, backups and atomic publication.
use lyra_reader_core::Rect;
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

pub const PROMPT_VERSION: &str = "inplace-translation-v1";
pub const MAX_CONCURRENT: usize = 3;
pub const MAX_ENTRIES: usize = 2000;
pub const MAX_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_ANSWER_BYTES: usize = 512 * 1024;
// Keep a separate byte admission bound in addition to the planner scalar-count limit.
pub const MAX_SOURCE_BYTES: usize = 512 * 1024;

fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

pub fn cache_key(
    source: &str,
    page: u32,
    rect: Rect,
    language: &str,
    model: &str,
    version: &str,
) -> Result<String, String> {
    if source.is_empty()
        || source.len() > MAX_SOURCE_BYTES
        || language.trim().is_empty()
        || language.len() > 512
        || model.trim().is_empty()
        || model.len() > 4096
        || version.is_empty()
        || version.len() > 128
        || rect.size.width <= 0.0
        || rect.size.height <= 0.0
    {
        return Err("The translation cache identity is invalid or oversized.".into());
    }
    let mut coordinates = Vec::with_capacity(4);
    for value in [
        rect.min_x(),
        rect.min_y(),
        rect.size.width,
        rect.size.height,
    ] {
        let rounded = (value * 100.0).round();
        // Leave a representable margin below i64::MAX: its f64 conversion rounds upward.
        if !rounded.is_finite() || rounded.abs() > (i64::MAX - 4096) as f64 {
            return Err(
                "The translation rectangle cannot be represented in hundredths of a point.".into(),
            );
        }
        coordinates.push(rounded as i64); // Finite and in range, checked above.
    }
    if !rect.max_x().is_finite() || !rect.max_y().is_finite() {
        return Err("The translation rectangle overflows.".into());
    }
    let source_hash = digest(source.as_bytes());
    let canonical = [
        source_hash,
        page.to_string(),
        coordinates[0].to_string(),
        coordinates[1].to_string(),
        coordinates[2].to_string(),
        coordinates[3].to_string(),
        language.into(),
        model.into(),
        version.into(),
    ]
    .join("\u{1f}");
    Ok(digest(canonical.as_bytes()))
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub key: String,
    pub page: u32,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub source_text: String,
    pub translated_text: String,
    pub language: String,
    pub model: String,
    pub prompt_version: String,
    pub range_start: Option<u32>,
    pub range_end: Option<u32>,
    pub is_block: bool,
    pub created_at: String,
}
impl Entry {
    pub fn rect(&self) -> Rect {
        Rect::new(self.x, self.y, self.width, self.height)
    }
    pub fn validate(&self) -> Result<(), String> {
        if self.translated_text.trim().is_empty()
            || self.translated_text.len() > MAX_ANSWER_BYTES
            || self.source_text.trim().is_empty()
            || self.created_at.len() > 128
            || chrono::DateTime::parse_from_rfc3339(&self.created_at).is_err()
            || self.range_start.is_some() != self.range_end.is_some()
            || self
                .range_start
                .zip(self.range_end)
                .is_some_and(|(lo, hi)| lo > hi)
            || cache_key(
                &self.source_text,
                self.page,
                self.rect(),
                &self.language,
                &self.model,
                &self.prompt_version,
            )? != self.key
        {
            return Err("Invalid saved translation; the original cache was kept.".into());
        }
        Ok(())
    }
}

struct Fields<const N: usize>(BTreeMap<String, Box<RawValue>>);
impl<'de, const N: usize> Deserialize<'de> for Fields<N> {
    fn deserialize<D: serde::Deserializer<'de>>(decoder: D) -> Result<Self, D::Error> {
        struct Visitor<const N: usize>;
        impl<'de, const N: usize> serde::de::Visitor<'de> for Visitor<N> {
            type Value = Fields<N>;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("a bounded translation object")
            }
            fn visit_map<M: serde::de::MapAccess<'de>>(
                self,
                mut map: M,
            ) -> Result<Self::Value, M::Error> {
                let mut values = BTreeMap::new();
                while let Some(key) = map.next_key::<String>()? {
                    if values.len() >= N || values.contains_key(&key) {
                        return Err(serde::de::Error::custom(
                            "Too many or duplicate translation fields",
                        ));
                    }
                    values.insert(key, map.next_value()?);
                }
                Ok(Fields(values))
            }
        }
        decoder.deserialize_map(Visitor::<N>)
    }
}

#[derive(Clone, Default)]
pub struct Cache {
    entries: BTreeMap<String, (Entry, String)>,
    original: Option<Vec<u8>>,
    pub warning: Option<String>,
}
impl Cache {
    pub fn decode(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() > MAX_BYTES {
            return Err("The translation cache exceeds 8 MiB; original data was kept.".into());
        }
        let root: Fields<32> = serde_json::from_slice(bytes).map_err(|e| {
            format!("The translation cache could not be read; original data was kept: {e}")
        })?;
        let version = root
            .0
            .get("version")
            .ok_or("The translation cache has no version")?;
        let supported = serde_json::from_str::<u32>(version.get()).ok() == Some(1);
        let raw = root
            .0
            .get("entries")
            .ok_or("The translation cache has no entries dictionary")?;
        let slots: Fields<2048> = serde_json::from_str(raw.get()).map_err(|e| {
            format!("The translation entries could not be read; original data was kept: {e}")
        })?;
        let mut result = Self {
            original: Some(bytes.to_vec()),
            ..Default::default()
        };
        let mut protected = !supported || root.0.len() != 2;
        if supported {
            for (key, raw) in slots.0 {
                if let Ok(entry) = serde_json::from_str::<Entry>(raw.get())
                    && key == entry.key
                    && entry.validate().is_ok()
                {
                    let Ok(fields) = serde_json::from_str::<Fields<32>>(raw.get()) else {
                        protected = true;
                        continue;
                    };
                    let known = [
                        "key",
                        "page",
                        "x",
                        "y",
                        "width",
                        "height",
                        "sourceText",
                        "translatedText",
                        "language",
                        "model",
                        "promptVersion",
                        "rangeStart",
                        "rangeEnd",
                        "isBlock",
                        "createdAt",
                    ];
                    protected |= fields.0.keys().any(|k| !known.contains(&k.as_str()));
                    result.entries.insert(key, (entry, raw.get().into()));
                } else {
                    protected = true;
                }
            }
        }
        if protected || result.entries.len() > MAX_ENTRIES {
            result.warning=Some("The translation cache contains an unknown version, foreign fields, unreadable or excess entries. Readable entries remain available; saving is blocked and original bytes were kept.".into());
        }
        Ok(result)
    }
    pub fn get(&self, key: &str) -> Option<&Entry> {
        self.entries.get(key).map(|e| &e.0)
    }
    pub fn entries(&self) -> impl Iterator<Item = &Entry> {
        self.entries.values().map(|e| &e.0)
    }
    pub fn entries_for_page(&self, page: u32) -> Result<Vec<&Entry>, String> {
        let mut entries = self
            .entries
            .values()
            .filter(|(e, _)| e.page == page)
            .map(|(e, _)| {
                chrono::DateTime::parse_from_rfc3339(&e.created_at)
                    .map(|date| (date, e))
                    .map_err(|error| error.to_string())
            })
            .collect::<Result<Vec<_>, _>>()?;
        entries.sort_by(|(a, ea), (b, eb)| a.cmp(b).then(ea.key.cmp(&eb.key)));
        Ok(entries.into_iter().map(|(_, entry)| entry).collect())
    }
    pub fn put(&mut self, entry: Entry) -> Result<(), String> {
        if let Some(warning) = &self.warning {
            return Err(warning.clone());
        }
        entry.validate()?;
        let mut next = self.entries.clone();
        let raw = crate::region_history::foundation_json(
            &serde_json::to_value(&entry).map_err(|e| e.to_string())?,
        )?;
        next.insert(entry.key.clone(), (entry, raw));
        if next.len() > MAX_ENTRIES {
            let mut oldest = next
                .iter()
                .map(|(key, (e, _))| {
                    (
                        chrono::DateTime::parse_from_rfc3339(&e.created_at)
                            .map_err(|e| e.to_string()),
                        key.clone(),
                    )
                })
                .collect::<Vec<_>>();
            let mut dated = Vec::with_capacity(oldest.len());
            for (date, key) in oldest.drain(..) {
                dated.push((date?, key));
            }
            dated.sort();
            for (_, key) in dated.into_iter().take(next.len() - MAX_ENTRIES) {
                next.remove(&key);
            }
        }
        self.publish(next)
    }
    /// Project readable entries into a new immutable page revision. The caller retains the
    /// original cache as the undo snapshot. Unknown records remain read-only and byte-preserved.
    pub fn projected(
        &self,
        page_map: &[Option<u32>],
        rotated: &[u32],
        output_pages: u32,
    ) -> Result<Self, String> {
        if page_map.len() > 1 << 20 || rotated.len() > 1 << 20 || output_pages == 0 {
            return Err("The translation page projection exceeds its bounds.".into());
        }
        let mapped = page_map
            .iter()
            .flatten()
            .copied()
            .collect::<std::collections::BTreeSet<_>>();
        if mapped.len() != page_map.iter().flatten().count()
            || mapped.iter().any(|p| *p >= output_pages)
        {
            return Err("The translation page projection is not a valid page map.".into());
        }
        let rotated = rotated
            .iter()
            .copied()
            .collect::<std::collections::BTreeSet<_>>();
        let mut entries = BTreeMap::new();
        for (entry, raw) in self.entries.values() {
            if rotated.contains(&entry.page) {
                continue;
            }
            let Some(page) = page_map.get(entry.page as usize).copied().flatten() else {
                continue;
            };
            let mut entry = entry.clone();
            let raw = if page == entry.page {
                raw.clone()
            } else {
                entry.page = page;
                entry.key = cache_key(
                    &entry.source_text,
                    page,
                    entry.rect(),
                    &entry.language,
                    &entry.model,
                    &entry.prompt_version,
                )?;
                crate::region_history::foundation_json(
                    &serde_json::to_value(&entry).map_err(|e| e.to_string())?,
                )?
            };
            entries.insert(entry.key.clone(), (entry, raw));
        }
        let mut result = Self {
            entries,
            original: self.original.clone(),
            warning: self.warning.clone(),
        };
        if result.warning.is_none() {
            result.publish(result.entries.clone())?;
        }
        Ok(result)
    }
    pub fn remove(&mut self, keys: &[String]) -> Result<(), String> {
        if let Some(warning) = &self.warning {
            return Err(warning.clone());
        }
        let mut next = self.entries.clone();
        for key in keys {
            next.remove(key);
        }
        self.publish(next)
    }
    fn publish(&mut self, next: BTreeMap<String, (Entry, String)>) -> Result<(), String> {
        let prefix = b"{\"entries\":{";
        let suffix = b"},\"version\":1}";
        let mut encoded = Vec::with_capacity(next.len());
        let mut size = prefix.len() + suffix.len() + next.len().saturating_sub(1);
        for (key, (_, raw)) in &next {
            let quoted = lyra_reader_edit::records::render_string(key);
            size=size.checked_add(quoted.len()).and_then(|n|n.checked_add(raw.len())).and_then(|n|n.checked_add(1))
                .filter(|n|*n<=MAX_BYTES).ok_or("The completed translation would exceed the 8 MiB cache budget; previous data was kept.")?;
            encoded.push((quoted, raw));
        }
        let mut bytes = Vec::new();
        bytes
            .try_reserve_exact(size)
            .map_err(|_| "The translation cache buffer could not be allocated")?;
        bytes.extend_from_slice(prefix);
        for (i, (key, raw)) in encoded.into_iter().enumerate() {
            if i > 0 {
                bytes.push(b',');
            }
            bytes.extend_from_slice(key.as_bytes());
            bytes.push(b':');
            bytes.extend_from_slice(raw.as_bytes());
        }
        bytes.extend_from_slice(suffix);
        self.entries = next;
        self.original = Some(bytes);
        Ok(())
    }
    pub fn encode(&self) -> &[u8] {
        self.original
            .as_deref()
            .unwrap_or(b"{\"entries\":{},\"version\":1}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    fn entry(text: &str) -> Entry {
        let rect = Rect::new(10.25, 20.5, 120.0, 32.0);
        Entry {
            key: cache_key(text, 0, rect, "French", "synthetic", PROMPT_VERSION).unwrap(),
            page: 0,
            x: rect.min_x(),
            y: rect.min_y(),
            width: rect.size.width,
            height: rect.size.height,
            source_text: text.into(),
            translated_text: "Texte synthétique".into(),
            language: "French".into(),
            model: "synthetic".into(),
            prompt_version: PROMPT_VERSION.into(),
            range_start: Some(0),
            range_end: Some(9),
            is_block: true,
            created_at: "2026-11-18T00:00:00Z".into(),
        }
    }
    #[test]
    fn restored_models_are_ordered_by_actual_time_instead_of_date_spelling() {
        let mut earlier = entry("same source");
        earlier.created_at = "2026-11-18T10:00:00+14:00".into();
        let mut later = earlier.clone();
        later.model = "another model".into();
        later.created_at = "2026-11-18T00:00:00Z".into();
        later.key = cache_key(
            &later.source_text,
            later.page,
            later.rect(),
            &later.language,
            &later.model,
            &later.prompt_version,
        )
        .unwrap();
        let mut cache = Cache::default();
        cache.put(earlier.clone()).unwrap();
        cache.put(later.clone()).unwrap();
        assert_eq!(cache.entries_for_page(0).unwrap(), vec![&earlier, &later]);
    }
    #[test]
    fn revision_projection_remaps_keys_drops_rotations_and_keeps_the_undo_bytes() {
        let mut cache = Cache::default();
        let first = entry("first");
        let mut second = entry("second");
        second.page = 1;
        second.key = cache_key(
            &second.source_text,
            1,
            second.rect(),
            &second.language,
            &second.model,
            &second.prompt_version,
        )
        .unwrap();
        cache.put(first.clone()).unwrap();
        cache.put(second.clone()).unwrap();
        let before = cache.encode().to_vec();
        let moved = cache.projected(&[Some(2), Some(0)], &[], 3).unwrap();
        let keys = moved
            .entries()
            .map(|e| (e.page, e.source_text.clone()))
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(keys, [(2, "first".into()), (0, "second".into())].into());
        assert!(moved.get(&first.key).is_none());
        assert_eq!(cache.encode(), before);
        let rotated = cache.projected(&[Some(0), Some(1)], &[0], 2).unwrap();
        assert_eq!(rotated.entries().count(), 1);
        assert!(rotated.get(&second.key).is_some());
        assert!(cache.projected(&[Some(0), Some(0)], &[], 2).is_err());
    }

    #[test]
    fn canonical_identity_matches_frozen_utf8_sha256_vectors() {
        // Independently computed canonical SHA-256 vectors; not a Foundation whole-file golden.
        assert_eq!(
            cache_key(
                "text\r\n α  β",
                0,
                Rect::new(10.25, 20.5, 120.0, 32.0),
                "French",
                "synthetic",
                PROMPT_VERSION
            )
            .unwrap(),
            "214446b280e7f756985fd75261493b396c1ae6628cb6533ea43352819ef43492"
        );
        assert_eq!(
            cache_key(
                "中文 e\u{301}\n👨\u{200d}👩",
                7,
                Rect::new(-1.25, 0.0, 12.35, 7.0),
                "日本語",
                "model/α",
                PROMPT_VERSION
            )
            .unwrap(),
            "f5a2b8fa5cf150038ef964d2c92cf1c6e030015ca572c099a3d5b5450ae7cb78"
        );
    }
    #[test]
    fn excess_bytes_and_foreign_entry_do_not_hide_other_readable_entries() {
        assert!(Cache::decode(&vec![b' '; MAX_BYTES + 1]).is_err());
        let good = entry("readable");
        let bad = entry("foreign");
        let mut foreign = serde_json::to_value(&bad).unwrap();
        foreign["future"] = Value::from("keep");
        let bytes=serde_json::to_vec(&serde_json::json!({"version":1,"entries":{good.key.clone():good,bad.key.clone():foreign,"damaged":{"not":"an entry"}}})).unwrap();
        let mut cache = Cache::decode(&bytes).unwrap();
        assert_eq!(cache.entries().count(), 2);
        assert!(cache.warning.is_some());
        assert!(cache.remove(&[bad.key]).is_err());
        assert_eq!(cache.encode(), bytes);
    }
    #[test]
    fn oldest_eviction_respects_fractional_creation_times_and_total_byte_budget() {
        let mut entries = serde_json::Map::new();
        for i in 0..MAX_ENTRIES {
            let mut e = entry(&format!("synthetic {i}"));
            e.created_at = format!("2026-11-18T00:00:00.{i:06}Z");
            entries.insert(e.key.clone(), serde_json::to_value(e).unwrap());
        }
        let bytes =
            serde_json::to_vec(&serde_json::json!({"entries":entries,"version":1})).unwrap();
        let mut cache = Cache::decode(&bytes).unwrap();
        let mut new = entry("latest");
        new.created_at = "2026-11-19T00:00:00Z".into();
        cache.put(new.clone()).unwrap();
        assert_eq!(cache.entries().count(), MAX_ENTRIES);
        assert!(cache.get(&entry("synthetic 0").key).is_none());
        assert!(cache.get(&new.key).is_some());
        let mut cache = Cache::default();
        let mut big = entry("large");
        big.translated_text = "x".repeat(MAX_ANSWER_BYTES);
        for i in 0..15 {
            let mut e = big.clone();
            e.source_text = format!("large {i}");
            e.key = cache_key(
                &e.source_text,
                e.page,
                e.rect(),
                &e.language,
                &e.model,
                &e.prompt_version,
            )
            .unwrap();
            cache.put(e).unwrap();
        }
        let before = cache.encode().to_vec();
        big.source_text = "over budget".into();
        big.key = cache_key(
            &big.source_text,
            big.page,
            big.rect(),
            &big.language,
            &big.model,
            &big.prompt_version,
        )
        .unwrap();
        assert!(cache.put(big).is_err());
        assert_eq!(cache.encode(), before);
    }

    #[test]
    fn identity_tracks_exact_source_geometry_page_language_model_and_prompt() {
        let e = entry("text\r\n α  β");
        let key = e.key.clone();
        assert_ne!(key, entry("text\n α β").key);
        for (page, r, language, model, version) in [
            (1, e.rect(), "French", "synthetic", PROMPT_VERSION),
            (
                0,
                Rect::new(10.27, 20.5, 120.0, 32.0),
                "French",
                "synthetic",
                PROMPT_VERSION,
            ),
            (0, e.rect(), "English", "synthetic", PROMPT_VERSION),
            (0, e.rect(), "French", "other", PROMPT_VERSION),
            (0, e.rect(), "French", "synthetic", "v2"),
        ] {
            assert_ne!(
                key,
                cache_key(&e.source_text, page, r, language, model, version).unwrap()
            );
        }
        assert_eq!(
            key,
            cache_key(
                &e.source_text,
                0,
                Rect::new(10.250001, 20.5, 120.0, 32.0),
                "French",
                "synthetic",
                PROMPT_VERSION
            )
            .unwrap()
        );
        for n in [f64::NAN, f64::INFINITY, f64::MAX] {
            assert!(
                cache_key(
                    "text",
                    0,
                    Rect::new(n, 0.0, 1.0, 1.0),
                    "French",
                    "synthetic",
                    PROMPT_VERSION
                )
                .is_err()
            );
        }
    }
    #[test]
    fn untouched_legacy_bytes_and_other_model_entries_survive_a_new_completion() {
        let e = entry("synthetic old text");
        let raw = serde_json::to_string_pretty(&e).unwrap();
        let bytes = format!("{{\"entries\":{{\"{}\":{raw}}},\"version\":1}}", e.key).into_bytes();
        let mut cache = Cache::decode(&bytes).unwrap();
        assert_eq!(cache.encode(), bytes);
        cache.put(entry("new synthetic text")).unwrap();
        assert!(std::str::from_utf8(cache.encode()).unwrap().contains(&raw));
        let reopened = Cache::decode(cache.encode()).unwrap();
        assert_eq!(reopened.entries().count(), 2);
        assert_eq!(reopened.get(&e.key), Some(&e));
    }
    #[test]
    fn unknown_version_fields_and_damaged_entries_protect_original_bytes() {
        let e = entry("synthetic text");
        let mut v = serde_json::json!({"version":1,"entries":{e.key.clone():e}});
        v["future"] = Value::Bool(true);
        let bytes = serde_json::to_vec(&v).unwrap();
        let mut cache = Cache::decode(&bytes).unwrap();
        assert!(
            cache
                .get(v["entries"].as_object().unwrap().keys().next().unwrap())
                .is_some()
        );
        assert!(cache.put(entry("another")).is_err());
        assert_eq!(cache.encode(), bytes);
        v["version"] = Value::from(2);
        let bytes = serde_json::to_vec(&v).unwrap();
        let cache = Cache::decode(&bytes).unwrap();
        assert_eq!(cache.entries().count(), 0);
        assert!(cache.warning.is_some());
        assert_eq!(cache.encode(), bytes);
        assert!(Cache::decode(br#"{"version":1,"version":1,"entries":{}}"#).is_err());
    }
    #[test]
    fn invalid_completed_data_never_replaces_a_previous_answer() {
        let mut cache = Cache::default();
        let mut e = entry("text");
        cache.put(e.clone()).unwrap();
        let before = cache.encode().to_vec();
        e.translated_text = String::new();
        assert!(cache.put(e.clone()).is_err());
        assert_eq!(cache.encode(), before);
        e.translated_text = "x".repeat(MAX_ANSWER_BYTES + 1);
        assert!(cache.put(e).is_err());
        assert_eq!(cache.encode(), before);
    }
}
