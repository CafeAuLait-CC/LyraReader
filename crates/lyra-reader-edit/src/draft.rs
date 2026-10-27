//! Pending annotation state and clean-baseline comparison, shared by native shells.
//!
//! The four established fields match the macOS `changes.json` shape. `recordsCommit`
//! is an optional write-ahead record for shells that publish records and state together.
//! Unknown metadata fields pass through; durable annotation bytes remain a separate string.
use serde_json::{Map, Value, json};

#[derive(Clone, Debug, PartialEq)]
pub struct CleanSnapshot {
    pub annotations: Vec<Value>,
    pub bookmarks: Vec<Value>,
    extra: Map<String, Value>,
}
impl CleanSnapshot {
    pub fn new(annotations: Vec<Value>, bookmarks: Vec<Value>) -> Self {
        Self {
            annotations,
            bookmarks,
            extra: Map::new(),
        }
    }
    fn decode(value: &Value) -> Result<Self, String> {
        let mut extra = value
            .as_object()
            .cloned()
            .ok_or("Invalid clean annotation snapshot")?;
        let annotations = extra
            .remove("annotations")
            .and_then(|v| v.as_array().cloned())
            .ok_or("Missing clean annotations")?;
        let bookmarks = extra
            .remove("bookmarks")
            .and_then(|v| v.as_array().cloned())
            .ok_or("Missing clean bookmarks")?;
        Ok(Self {
            annotations,
            bookmarks,
            extra,
        })
    }
    fn value(&self) -> Value {
        let mut value = self.extra.clone();
        value.insert("annotations".into(), json!(self.annotations));
        value.insert("bookmarks".into(), json!(self.bookmarks));
        Value::Object(value)
    }
    pub fn matches(&self, current: &Self) -> bool {
        self.annotations == current.annotations && self.bookmarks == current.bookmarks
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Deletion {
    pub identity: String,
    pub page: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RecordsCommit {
    pub records: String,
    pub sha256: String,
    pub previous_sha256: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PendingState {
    pub dirty: bool,
    pub deletions: Vec<Deletion>,
    pub erased_ink: Vec<String>,
    pub clean: Option<CleanSnapshot>,
    pub commit: Option<RecordsCommit>,
    extra: Map<String, Value>,
}
impl PendingState {
    pub fn new(dirty: bool, clean: Option<CleanSnapshot>) -> Self {
        Self {
            dirty,
            clean,
            deletions: Vec::new(),
            erased_ink: Vec::new(),
            commit: None,
            extra: Map::new(),
        }
    }
    pub fn refresh(&mut self, current: &CleanSnapshot) {
        self.dirty = self
            .clean
            .as_ref()
            .is_none_or(|clean| !clean.matches(current))
            || !self.deletions.is_empty()
            || !self.erased_ink.is_empty();
    }
    pub fn mark_clean(&mut self, current: CleanSnapshot) {
        self.dirty = false;
        self.clean = Some(current);
        self.deletions.clear();
        self.erased_ink.clear();
    }
    pub fn decode(bytes: &[u8], page_count: u32) -> Result<Self, String> {
        let value: Value = serde_json::from_slice(bytes)
            .map_err(|e| format!("Invalid pending annotation state: {e}"))?;
        let mut extra = value
            .as_object()
            .cloned()
            .ok_or("Pending annotation state must be an object")?;
        let dirty = extra
            .remove("dirty")
            .and_then(|v| v.as_bool())
            .ok_or("Missing annotation dirty state")?;
        let deletions = extra
            .remove("deletions")
            .and_then(|v| v.as_array().cloned())
            .ok_or("Missing pending deletions")?
            .into_iter()
            .map(|v| {
                let object = v.as_object().ok_or("Invalid pending deletion")?;
                if object.keys().any(|k| k != "identity" && k != "page") {
                    return Err("Unsupported pending deletion fields".into());
                }
                let identity = v["identity"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .ok_or("Missing pending deletion identity")?
                    .to_string();
                let page = v["page"]
                    .as_u64()
                    .and_then(|p| u32::try_from(p).ok())
                    .filter(|p| *p < page_count)
                    .ok_or("Invalid pending deletion page")?;
                Ok(Deletion { identity, page })
            })
            .collect::<Result<Vec<_>, String>>()?;
        let erased_ink = extra
            .remove("erasedInk")
            .and_then(|v| v.as_array().cloned())
            .ok_or("Missing pending ink state")?
            .into_iter()
            .map(|v| {
                v.as_str()
                    .and_then(crate::records::normalize_uuid)
                    .ok_or_else(|| "Invalid pending ink identity".to_string())
            })
            .collect::<Result<Vec<_>, _>>()?;
        let clean = match extra.remove("cleanSnapshot") {
            Some(Value::Null) | None => None,
            Some(v) => Some(CleanSnapshot::decode(&v)?),
        };
        let commit = match extra.remove("recordsCommit") {
            None => None,
            Some(v) => {
                let object = v.as_object().ok_or("Invalid annotation records commit")?;
                if object
                    .keys()
                    .any(|k| !["records", "sha256", "previousSha256"].contains(&k.as_str()))
                {
                    return Err("Unsupported annotation records commit".into());
                }
                let records = v["records"]
                    .as_str()
                    .ok_or("Missing committed annotation records")?
                    .to_string();
                let sha256 = hash(v.get("sha256"))?;
                let previous_sha256 = match v.get("previousSha256") {
                    Some(Value::Null) | None => None,
                    value => Some(hash(value)?),
                };
                Some(RecordsCommit {
                    records,
                    sha256,
                    previous_sha256,
                })
            }
        };
        Ok(Self {
            dirty,
            deletions,
            erased_ink,
            clean,
            commit,
            extra,
        })
    }
    pub fn encode(&self) -> Result<Vec<u8>, String> {
        let mut value = self.extra.clone();
        value.insert("dirty".into(), json!(self.dirty));
        value.insert(
            "deletions".into(),
            json!(
                self.deletions
                    .iter()
                    .map(|d| json!({"identity":d.identity,"page":d.page}))
                    .collect::<Vec<_>>()
            ),
        );
        value.insert("erasedInk".into(), json!(self.erased_ink));
        if let Some(clean) = &self.clean {
            value.insert("cleanSnapshot".into(), clean.value());
        } else {
            value.remove("cleanSnapshot");
        }
        if let Some(commit) = &self.commit {
            value.insert("recordsCommit".into(),json!({"records":commit.records,"sha256":commit.sha256,"previousSha256":commit.previous_sha256}));
        } else {
            value.remove("recordsCommit");
        }
        serde_json::to_vec(&value).map_err(|e| e.to_string())
    }
}
fn hash(value: Option<&Value>) -> Result<String, String> {
    value
        .and_then(Value::as_str)
        .filter(|s| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit()))
        .map(|s| s.to_ascii_lowercase())
        .ok_or_else(|| "Invalid annotation records digest".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn foundation_pending_shape_round_trips_and_preserves_future_metadata() {
        let bytes=br#"{"dirty":true,"deletions":[{"identity":"nm:test","page":0}],"erasedInk":["00112233-4455-6677-8899-AABBCCDDEEFF"],"cleanSnapshot":{"annotations":[],"bookmarks":[],"future":2},"future":{"keep":true}}"#;
        let state = PendingState::decode(bytes, 1).unwrap();
        let value: Value = serde_json::from_slice(&state.encode().unwrap()).unwrap();
        assert_eq!(value, serde_json::from_slice::<Value>(bytes).unwrap());
        assert_eq!(
            PendingState::decode(&state.encode().unwrap(), 1).unwrap(),
            state
        );
    }
    #[test]
    fn dirty_is_independent_of_history_depth_and_detects_last_bookmark_removal_and_order() {
        let (a, b) = (json!({"id":"a"}), json!({"id":"b"}));
        let clean = CleanSnapshot::new(vec![], vec![a.clone(), b.clone()]);
        let mut state = PendingState::new(false, Some(clean.clone()));
        state.refresh(&CleanSnapshot::new(vec![], vec![b.clone(), a.clone()]));
        assert!(state.dirty);
        state.refresh(&CleanSnapshot::new(vec![], vec![]));
        assert!(state.dirty);
        state.refresh(&clean);
        assert!(!state.dirty);
        state.deletions.push(Deletion {
            identity: "nm:deleted".into(),
            page: 0,
        });
        state.refresh(&clean);
        assert!(state.dirty);
        let mut legacy = PendingState::new(true, None);
        legacy.refresh(&CleanSnapshot::new(vec![], vec![]));
        assert!(legacy.dirty);
    }
    #[test]
    fn malformed_pending_fields_fail_without_defaulting_to_clean() {
        for input in [
            r#"{}"#,
            r#"{"dirty":false,"deletions":[{"identity":"x","page":4294967296}],"erasedInk":[]}"#,
            r#"{"dirty":false,"deletions":[],"erasedInk":["bad"]}"#,
        ] {
            assert!(PendingState::decode(input.as_bytes(), 2).is_err());
        }
    }
}
