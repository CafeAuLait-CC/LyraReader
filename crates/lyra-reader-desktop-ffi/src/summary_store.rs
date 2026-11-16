//! Document-owned summary I/O. Shared Rust owns format, matching, bounds and eviction.
use crate::document::DesktopDocument;
use crate::document_cache::{DocumentCache, atomic_write, read_optional_bounded};
use lyra_reader_ai::summary_cache::{Cache, Entry, MAX_BYTES, MAX_SUMMARY_BYTES, language_key};
use lyra_reader_ffi::api::*;
use serde_json::{Value, json};
use std::{
    path::PathBuf,
    sync::{Arc, Weak},
};

pub(crate) const FILE: &str = "summaries.json";

#[derive(Default)]
pub(crate) struct Store {
    path: Option<PathBuf>,
    baseline: Option<Vec<u8>>,
    cache: Cache,
    error: Option<String>,
    source_error: Option<String>,
    prepared: Option<Capture>,
    active: Option<Capture>,
}

#[derive(Clone)]
pub(crate) struct Capture {
    source: Weak<LyraReaderDocument>,
    plan: Vec<u8>,
    entry: Entry,
    done: bool,
    failed: bool,
    limited: bool,
}
impl Capture {
    pub(crate) fn new(
        document: &Arc<LyraReaderDocument>,
        row: &crate::summary::Row,
        unit: &AiSummaryUnitRecord,
        language: &str,
        plan: &AiPlanRecord,
    ) -> Result<Self, String> {
        let layer = match unit.kind {
            AiSummaryLayerRecord::Abstract => "abstract",
            AiSummaryLayerRecord::Section => "sections",
            AiSummaryLayerRecord::Page => "pages",
        };
        Ok(Self {
            source: Arc::downgrade(document),
            plan: serde_json::to_vec(plan).map_err(|e| e.to_string())?,
            entry: Entry {
                layer: layer.into(),
                unit: row.id.clone(),
                model: plan.model.clone(),
                language: language_key(language).into(),
                text_hash: unit.text_hash.clone(),
                title: unit.title.clone(),
                page_start: unit.page_start,
                page_end: unit.covered_page_end,
                summary: String::new(),
                saved_at: 0.0,
                source_pages: Some(plan.source_pages.clone()),
                source_sha256: Some(document.document_identity().sha256),
            },
            done: false,
            failed: false,
            limited: false,
        })
    }
    pub(crate) fn observe(&mut self, events: &[AiEventRecord]) {
        for event in events {
            match event {
                AiEventRecord::Delta { text } if !self.limited => {
                    if self
                        .entry
                        .summary
                        .len()
                        .checked_add(text.len())
                        .is_some_and(|n| n <= MAX_SUMMARY_BYTES)
                    {
                        self.entry.summary.push_str(text);
                    } else {
                        self.limited = true;
                        self.entry.summary.clear();
                    }
                }
                AiEventRecord::Done => self.done = true,
                AiEventRecord::Error { .. } => self.failed = true,
                _ => {}
            }
        }
    }
    pub(crate) fn finish(
        mut self,
        document: &Arc<LyraReaderDocument>,
        store: &mut Store,
        cache: &DocumentCache,
    ) -> Result<bool, String> {
        if !self.done || self.failed {
            return Ok(false);
        }
        if !self.source.ptr_eq(&Arc::downgrade(document)) {
            return Err(
                "The completed summary belongs to an earlier document revision; it was not cached"
                    .into(),
            );
        }
        if self.limited {
            return Err("The summary completed but exceeds the 512 KiB per-row cache limit; the previous cache was kept".into());
        }
        self.entry.saved_at = crate::region_store::now();
        store.save(cache, self.entry)?;
        Ok(true)
    }
}

impl Store {
    pub(crate) fn load(&mut self, cache: &DocumentCache) -> Result<(), String> {
        let path = cache.directory.join(FILE);
        let bytes = read_optional_bounded(&path, MAX_BYTES as u64)?;
        if self.path.as_ref() == Some(&path) {
            if bytes != self.baseline {
                return Err("The summary cache changed outside this window. Reopen the document before saving summaries; both versions were kept".into());
            }
            return Ok(());
        }
        let (decoded, error) = match bytes.as_deref() {
            Some(bytes) => match Cache::decode(bytes) {
                Ok(cache) => (cache, None),
                Err(e) => (Cache::default(), Some(e)),
            },
            None => (Cache::default(), None),
        };
        self.path = Some(path);
        self.baseline = bytes;
        self.cache = decoded;
        self.error = error;
        Ok(())
    }
    pub(crate) fn warning(&self) -> Option<String> {
        self.source_error
            .as_ref()
            .or(self.error.as_ref())
            .or(self.cache.warning.as_ref())
            .cloned()
    }
    pub(crate) fn cached_entry(
        &self,
        layer: &str,
        unit: &str,
        model: &str,
        language: &str,
        hash: &str,
    ) -> Option<(Entry, bool)> {
        if self.source_error.is_some() || self.error.is_some() {
            return None;
        }
        self.cache
            .find(layer, unit, model, language, hash)
            .map(|(entry, exact)| (entry.clone(), exact))
    }
    pub(crate) fn save(&mut self, cache: &DocumentCache, entry: Entry) -> Result<(), String> {
        if let Some(error) = &self.source_error {
            return Err(error.clone());
        }
        cache.validate_pdf_source()?;
        self.load(cache)?;
        if let Some(error) = &self.error {
            return Err(error.clone());
        }
        let mut next = self.cache.clone();
        next.put(entry)?;
        let _lease = crate::document_cache::lock_summary_cache(&cache.directory)?;
        let path = self
            .path
            .as_ref()
            .ok_or("The summary cache is not loaded")?;
        if read_optional_bounded(path, MAX_BYTES as u64)? != self.baseline {
            return Err(
                "The summary cache changed before publication; the original file was kept".into(),
            );
        }
        if let Some(previous) = &self.baseline {
            atomic_write(&cache.directory.join("summaries.previous.json"), previous)?;
        }
        atomic_write(path, next.encode())?;
        self.baseline = Some(next.encode().to_vec());
        self.cache = next;
        Ok(())
    }
    pub(crate) fn prepare(&mut self, capture: Capture, cache: &DocumentCache) -> Option<String> {
        let warning = self
            .load(cache)
            .err()
            .or_else(|| self.source_error.clone())
            .or_else(|| self.error.clone())
            .or_else(|| self.cache.warning.clone());
        self.prepared = Some(capture);
        warning
    }
    pub(crate) fn has_active(&self) -> bool {
        self.active.is_some()
    }
    pub(crate) fn clear_active(&mut self) {
        self.active = None;
    }
    pub(crate) fn start(
        &mut self,
        document: &Arc<LyraReaderDocument>,
        plan: &AiPlanRecord,
    ) -> Result<(), String> {
        self.active = None;
        if let Some(capture) = self.prepared.as_ref()
            && capture.source.ptr_eq(&Arc::downgrade(document))
            && capture.plan == serde_json::to_vec(plan).map_err(|e| e.to_string())?
        {
            self.active = Some(capture.clone());
        }
        Ok(())
    }
    pub(crate) fn poll(
        &mut self,
        cache: &DocumentCache,
        document: &Arc<LyraReaderDocument>,
        events: &[AiEventRecord],
        finished: bool,
    ) -> Option<String> {
        if let Some(capture) = self.active.as_mut() {
            capture.observe(events);
        }
        if finished && let Some(capture) = self.active.take() {
            return capture.finish(document, self, cache).err();
        }
        None
    }
}

impl DesktopDocument {
    pub(crate) fn cached_summary(
        &self,
        document: &Arc<LyraReaderDocument>,
        request: &Value,
    ) -> Result<Value, String> {
        #[derive(serde::Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Request {
            layer: AiSummaryLayerRecord,
            index: u32,
            model: String,
            language: String,
        }
        let mut r: Request =
            serde_json::from_value(request["request"].clone()).map_err(|e| e.to_string())?;
        r.model = lyra_reader_ai::validate_model(&r.model).map_err(|e| e.to_string())?;
        if r.model.is_empty() || r.model.len() > 4096 || r.language.len() > 512 {
            return Err(
                "Choose a model and valid summary language before opening saved summaries".into(),
            );
        }
        let inspection = crate::summary::inspect(
            document,
            crate::summary::InspectRequest {
                layer: r.layer,
                index: r.index,
            },
        )?;
        let id = inspection["id"]
            .as_str()
            .ok_or("The summary identity is unavailable")?;
        let hash = inspection["fingerprint"]["text_hash"]
            .as_str()
            .ok_or("The summary fingerprint is unavailable")?;
        let layer = match r.layer {
            AiSummaryLayerRecord::Abstract => "abstract",
            AiSummaryLayerRecord::Section => "sections",
            AiSummaryLayerRecord::Page => "pages",
        };
        self.with_summary_store(document,true,|store,cache| {
            store.load(cache)?;
            let found=store.cache.find(layer,id,&r.model,&r.language,hash);
            let (entry,exact)=found.map(|(e,exact)|(Some(e),exact)).unwrap_or((None,false));
            let pages=entry.filter(|_|exact && store.source_error.is_none()).map(|e|e.verified_pages(&document.document_identity().sha256,document.page_count())).unwrap_or_default();
            Ok(json!({"id":id,"entry":entry,"exact":exact,"source_pages":pages,"page_span":inspection["page_span"],"cache_warning":store.warning()}))
        })
    }
    pub(crate) fn with_summary_store<T>(
        &self,
        document: &Arc<LyraReaderDocument>,
        validate_source: bool,
        f: impl FnOnce(&mut Store, &DocumentCache) -> Result<T, String>,
    ) -> Result<T, String> {
        let _edits = self
            .edits
            .lock()
            .map_err(|_| "Page-edit state is unavailable")?;
        if !Arc::ptr_eq(&self.active()?, document) {
            return Err("The document changed before the summary cache operation".into());
        }
        let marks = self
            .marks
            .lock()
            .map_err(|_| "Annotation state is unavailable")?;
        let mut store = self
            .summaries
            .lock()
            .map_err(|_| "Summary cache state is unavailable")?;
        // Streaming polls only drain in-memory events. Hash the PDF at explicit cache reads
        // and again immediately before a completed row is published, not every 60 ms.
        if validate_source {
            store.source_error = marks.validate_source().err();
        }
        f(&mut store, marks.cache_location()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use fs2::FileExt;
    use std::fs;
    struct Fixture {
        root: PathBuf,
        document: DesktopDocument,
        cache: DocumentCache,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "lyra-summary-store-{}",
                crate::marks::uuid().unwrap()
            ));
            fs::create_dir(&root).unwrap();
            let path = root.join("synthetic.pdf");
            fs::copy(
                PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join("../../tests/fixtures/text-page.pdf"),
                &path,
            )
            .unwrap();
            let document =
                DesktopDocument::open_with_cache_root(&path, None, Some(&root.join("cache")))
                    .unwrap();
            let cache = document
                .marks
                .lock()
                .unwrap()
                .cache_location()
                .unwrap()
                .clone();
            Self {
                root,
                document,
                cache,
            }
        }
        fn entry(&self) -> Entry {
            let settings = json!({"action":"SummarizePage","base_url":"http://127.0.0.1:9/v1","model":"synthetic","language":null,"current_page":0,"selection":null,"region":null,"question":null,"history":[],"temperature":null,"max_tokens":null,"reasoning_mode":"default","reasoning_encoding":"none","document_knowledge":false,"document_knowledge_text":null,"document_knowledge_pages":[]});
            self.document.command(json!({"op":"ai_summary_prepare","unit":{"layer":"Page","index":0},"request":settings})).unwrap();
            let mut entry = self
                .document
                .summaries
                .lock()
                .unwrap()
                .prepared
                .as_ref()
                .unwrap()
                .entry
                .clone();
            entry.summary = "SYNTHETIC_COMPLETE".into();
            entry.saved_at = 804000000.5;
            entry
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            // Only this fixture's unique scratch is disposable.
            let _ = fs::remove_dir_all(&self.root);
        }
    }
    #[test]
    fn completed_rows_reopen_locally_with_the_shared_fingerprint_and_no_pdf_changes() {
        let f = Fixture::new();
        let original = fs::read(&f.cache.document).unwrap();
        let entry = f.entry();
        let mut store = Store::default();
        store.save(&f.cache, entry).unwrap();
        let reopened =
            DesktopDocument::open_with_cache_root(&f.cache.document, None, Some(&f.cache.root))
                .unwrap();
        let result=reopened.command(json!({"op":"ai_summary_cached","request":{"layer":"Page","index":0,"model":" synthetic ","language":" "}})).unwrap();
        assert_eq!(result["entry"]["summary"], "SYNTHETIC_COMPLETE");
        assert_eq!(result["exact"], true);
        assert_eq!(result["source_pages"], json!([1]));
        assert_eq!(fs::read(&f.cache.document).unwrap(), original);
        let result=reopened.command(json!({"op":"ai_summary_cached","request":{"layer":"Page","index":0,"model":"other","language":""}})).unwrap();
        assert!(result["entry"].is_null());
    }
    #[test]
    fn partial_failed_and_oversized_answers_never_replace_a_completed_cache() {
        let f = Fixture::new();
        let entry = f.entry();
        let mut store = Store::default();
        store.save(&f.cache, entry).unwrap();
        let before = fs::read(f.cache.directory.join(FILE)).unwrap();
        let source = f.document.active().unwrap();
        for mode in 0..3 {
            let mut capture = f
                .document
                .summaries
                .lock()
                .unwrap()
                .prepared
                .as_ref()
                .unwrap()
                .clone();
            capture.observe(&[AiEventRecord::Delta {
                text: "PARTIAL".into(),
            }]);
            if mode == 1 {
                capture.failed = true;
                capture.observe(&[AiEventRecord::Done]);
            }
            if mode == 2 {
                capture.observe(&[
                    AiEventRecord::Delta {
                        text: "a".repeat(MAX_SUMMARY_BYTES + 1),
                    },
                    AiEventRecord::Done,
                ]);
            }
            let result = capture.finish(&source, &mut store, &f.cache);
            if mode == 2 {
                assert!(result.is_err());
            } else {
                assert!(!result.unwrap());
            }
            assert_eq!(fs::read(f.cache.directory.join(FILE)).unwrap(), before);
        }
    }
    #[test]
    fn corrupt_and_foreign_files_remain_byte_identical_and_report_cache_warnings() {
        for bytes in [
            b"{bad cache".as_slice(),
            b"{\"entries\":[],\"future\":{\"number\":1e-07}}".as_slice(),
        ] {
            let f = Fixture::new();
            let entry = f.entry();
            let path = f.cache.directory.join(FILE);
            fs::write(&path, bytes).unwrap();
            let mut store = Store::default();
            assert!(store.save(&f.cache, entry).is_err());
            assert_eq!(fs::read(&path).unwrap(), bytes);
            let reopened =
                DesktopDocument::open_with_cache_root(&f.cache.document, None, Some(&f.cache.root))
                    .unwrap();
            let read=reopened.command(json!({"op":"ai_summary_cached","request":{"layer":"Page","index":0,"model":"synthetic","language":""}})).unwrap();
            assert!(read["cache_warning"].is_string());
            assert_eq!(fs::read(&path).unwrap(), bytes);
        }
    }
    #[test]
    fn a_changed_pdf_is_rejected_at_completed_cache_publication() {
        let fixture = Fixture::new();
        let entry = fixture.entry();
        let mut bytes = fs::read(&fixture.cache.document).unwrap();
        bytes.extend_from_slice(b"\n% external synthetic revision\n");
        fs::write(&fixture.cache.document, bytes).unwrap();
        let mut store = Store::default();
        assert!(
            store
                .save(&fixture.cache, entry)
                .unwrap_err()
                .contains("changed outside")
        );
        assert!(!fixture.cache.directory.join(FILE).exists());
    }
    #[test]
    fn external_writes_and_another_window_lock_protect_the_existing_cache() {
        let f = Fixture::new();
        let entry = f.entry();
        let mut store = Store::default();
        store.save(&f.cache, entry.clone()).unwrap();
        let path = f.cache.directory.join(FILE);
        let external = fs::read(&path)
            .unwrap()
            .into_iter()
            .chain(*b"\n")
            .collect::<Vec<_>>();
        fs::write(&path, &external).unwrap();
        assert!(
            store
                .save(&f.cache, entry.clone())
                .unwrap_err()
                .contains("changed outside")
        );
        assert_eq!(fs::read(&path).unwrap(), external);
        let mut fresh = Store::default();
        fresh.load(&f.cache).unwrap();
        let lock = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(f.cache.directory.join(".summaries.lock"))
            .unwrap();
        FileExt::lock_exclusive(&lock).unwrap();
        assert!(
            fresh
                .save(&f.cache, entry)
                .unwrap_err()
                .contains("Another window")
        );
        assert_eq!(fs::read(&path).unwrap(), external);
    }
    #[test]
    fn successful_replacement_keeps_a_verified_previous_file_and_stale_answers_have_no_links() {
        let f = Fixture::new();
        let mut entry = f.entry();
        let mut store = Store::default();
        store.save(&f.cache, entry.clone()).unwrap();
        let before = fs::read(f.cache.directory.join(FILE)).unwrap();
        entry.text_hash = "b".repeat(64);
        entry.summary = "SYNTHETIC_OLDER_TEXT".into();
        store.save(&f.cache, entry).unwrap();
        assert_eq!(
            fs::read(f.cache.directory.join("summaries.previous.json")).unwrap(),
            before
        );
        let reopened =
            DesktopDocument::open_with_cache_root(&f.cache.document, None, Some(&f.cache.root))
                .unwrap();
        let read=reopened.command(json!({"op":"ai_summary_cached","request":{"layer":"Page","index":0,"model":"synthetic","language":""}})).unwrap();
        assert_eq!(read["exact"], false);
        assert_eq!(read["entry"]["summary"], "SYNTHETIC_OLDER_TEXT");
        assert_eq!(read["source_pages"], json!([]));
    }
}
