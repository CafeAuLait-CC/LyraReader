//! Optional reading lane. The portable AI policy owns multipart completeness and
//! consolidation. Provider I/O never occupies the foreground assistant's handle.
use crate::document::DesktopDocument;
use crate::document_cache::{DocumentCache, atomic_write, read_optional_bounded};
use fs2::FileExt;
use lyra_reader_ai::chat::{ChatTransport, ReasoningEncoding, ReasoningMode};
use lyra_reader_ai::{
    CancellationToken, ChatSettings,
    knowledge::{DocumentReading, ReadingUpdate, run_document_reading},
};
use lyra_reader_ffi::api::*;
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs,
    sync::{Arc, Mutex},
};

const FILE: &str = "document-knowledge-v1.json";
fn read_cache(path: &std::path::Path) -> Result<Option<Vec<u8>>, String> {
    read_optional_bounded(path, lyra_reader_ai::knowledge::MAX_READING_BYTES as u64)
}
#[derive(Default)]
struct Progress {
    completed: usize,
    total: usize,
    merge_payloads: Vec<String>,
    result: Option<Result<String, String>>,
}
struct ReadingJob {
    cancel: CancellationToken,
    progress: Arc<Mutex<Progress>>,
}
impl Drop for ReadingJob {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}

pub(super) struct Knowledge {
    token: String,
    phase: &'static str,
    plan: Option<AiPlanRecord>,
    settings: Option<ChatSettings>,
    source_hash: String,
    cache: Option<DocumentCache>,
    baseline: Option<Vec<u8>>,
    cache_error: Option<String>,
    record: Option<DocumentReading>,
    job: Option<ReadingJob>,
    message: Option<String>,
    merge_payloads: Vec<String>,
}
impl Default for Knowledge {
    fn default() -> Self {
        Self {
            token: String::new(),
            phase: "idle",
            plan: None,
            settings: None,
            source_hash: String::new(),
            cache: None,
            baseline: None,
            cache_error: None,
            record: None,
            job: None,
            message: None,
            merge_payloads: Vec::new(),
        }
    }
}
impl Knowledge {
    fn view(&self) -> Result<Value, String> {
        self.status(true)
    }
    fn status(&self, include_plan: bool) -> Result<Value, String> {
        let mut result = json!({"phase":self.phase,"token":self.token,"ready":self.record.is_some(),"message":self.message,"cache_warning":self.cache_error,"merge_payloads":self.merge_payloads});
        if include_plan {
            result["plan"] = serde_json::to_value(&self.plan).map_err(|e| e.to_string())?;
        }
        if let Some(job) = &self.job {
            let p = job
                .progress
                .lock()
                .map_err(|_| "Document reading progress is unavailable")?;
            result["completed"] = json!(p.completed);
            result["total"] = json!(p.total);
            result["merge_payloads"] = json!(p.merge_payloads);
        }
        Ok(result)
    }
    fn cancel(&mut self, invalidate: bool) -> Result<(), String> {
        self.token = crate::marks::uuid()?;
        self.job = None;
        self.plan = None;
        self.settings = None;
        self.phase = "idle";
        self.merge_payloads.clear();
        self.message = Some("Document reading stopped. You can keep using Lyra without it.".into());
        if invalidate {
            self.record = None;
            self.cache = None;
            self.source_hash.clear();
        }
        Ok(())
    }
}
fn current_hash(document: &LyraReaderDocument) -> Result<String, String> {
    let current = document_identity_for_path(document.path()).map_err(|e| e.to_string())?;
    if current.sha256 != document.document_identity().sha256 {
        return Err(
            "The PDF changed outside LyraReader. Reopen it before reading the document.".into(),
        );
    }
    Ok(current.sha256)
}
impl DesktopDocument {
    pub(super) fn invalidate_reading(&self) -> Result<(), String> {
        self.knowledge
            .lock()
            .map_err(|_| "Document reading state is unavailable")?
            .cancel(true)
    }
    pub(super) fn enrich_reading(
        &self,
        request: &mut AiPlanRequestRecord,
        hash: &str,
    ) -> Result<(), String> {
        if request.action == AiActionRecord::TranslateSelection {
            return Ok(());
        }
        // Generated context is optional. In particular, final hash/cache I/O must not
        // delay a foreground question. Busy state means this preview proceeds with its
        // own sources; poisoned state remains an actual, diagnosable error.
        let state = match self.knowledge.try_lock() {
            Ok(state) => state,
            Err(std::sync::TryLockError::WouldBlock) => return Ok(()),
            Err(std::sync::TryLockError::Poisoned(_)) => {
                return Err("Document reading state is unavailable".into());
            }
        };
        if let Some(record) = state.record.as_ref().filter(|r| r.source_hash == hash) {
            request.document_knowledge_text = Some(record.summary.clone());
            request.document_knowledge_pages = record.pages.clone();
        }
        Ok(())
    }
    fn reading_context(&self) -> Result<(Arc<LyraReaderDocument>, DocumentCache), String> {
        let _edits = self
            .edits
            .lock()
            .map_err(|_| "Page-edit state is unavailable")?;
        let marks = self
            .marks
            .lock()
            .map_err(|_| "Annotation state is unavailable")?;
        Ok((self.active()?, marks.cache_location()?.clone()))
    }
    fn prepare_reading(&self, request: Option<AiPlanRequestRecord>) -> Result<Value, String> {
        let token = crate::marks::uuid()?;
        {
            let mut state = self
                .knowledge
                .lock()
                .map_err(|_| "Document reading state is unavailable")?;
            if state.job.is_some() {
                return Err("Stop the current document reading before preparing another.".into());
            }
            *state = Knowledge {
                token: token.clone(),
                phase: "preparing",
                ..Knowledge::default()
            };
        }
        // Hash/cache/text work is outside the state mutex. Foreground questions obtain an
        // empty prior immediately while this optional plan is prepared, with no provider wait.
        let prepared = (|| {
            let (active, cache) = self.reading_context()?;
            // Opening already computed this identity. A cache miss at open must not scan
            // every PDF byte again or extract text. Explicit preview verifies the path afresh.
            let hash = if request.is_some() {
                current_hash(&active)?
            } else {
                active.document_identity().sha256
            };
            let baseline = read_cache(&cache.directory.join(FILE))?;
            let decoded = baseline
                .as_ref()
                .map(|b| DocumentReading::decode(b, active.page_count()))
                .transpose();
            let (record, cache_error) = match decoded {
                Ok(record) => (record.filter(|r| r.source_hash == hash), None),
                Err(error) => (None, Some(error)),
            };
            let (plan, settings) = if record.is_none() {
                if let Some(mut request) = request {
                    request.action = AiActionRecord::SummarizeDocument;
                    request.document_knowledge = true;
                    request.document_knowledge_text = None;
                    request.document_knowledge_pages.clear();
                    let plan = render_ai_plan(
                        active
                            .prepare_ai_plan(request.clone())
                            .map_err(|e| e.to_string())?,
                        AiWireTransport::ChatCompletions,
                    )
                    .map_err(|e| e.to_string())?;
                    let settings = ChatSettings {
                        base_url: plan.base_url.clone(),
                        model: plan.model.clone(),
                        temperature: plan.temperature.map(|n| n as f32),
                        max_tokens: plan.max_tokens,
                        reasoning_mode: ReasoningMode::from_wire(&request.reasoning_mode)
                            .ok_or("Unknown document reading reasoning mode")?,
                        reasoning_encoding: ReasoningEncoding::from_wire(
                            &request.reasoning_encoding,
                        )
                        .ok_or("Unknown document reading reasoning encoding")?,
                    };
                    (Some(plan), Some(settings))
                } else {
                    (None, None)
                }
            } else {
                (None, None)
            };
            if self.active()?.document_identity().sha256 != hash {
                return Err(
                    "The PDF changed while the reading preview was prepared. Preview again.".into(),
                );
            }
            Ok::<_, String>((cache, hash, baseline, record, cache_error, plan, settings))
        })();
        let mut state = self
            .knowledge
            .lock()
            .map_err(|_| "Document reading state is unavailable")?;
        if state.token != token {
            return Err("The document reading preview was cancelled or superseded.".into());
        }
        match prepared {
            Ok((cache, hash, baseline, record, error, plan, settings)) => {
                state.phase = if record.is_some() {
                    "ready"
                } else if plan.is_some() {
                    "preview"
                } else {
                    "idle"
                };
                state.cache = Some(cache);
                state.source_hash = hash;
                state.baseline = baseline;
                state.record = record;
                state.cache_error = error;
                state.plan = plan;
                state.settings = settings;
            }
            Err(error) => {
                state.phase = "failed";
                state.message = Some(error);
            }
        }
        state.view()
    }
    fn start_reading(&self, r: &Value) -> Result<Value, String> {
        let active = self.active()?;
        let hash = current_hash(&active)?;
        let mut state = self
            .knowledge
            .lock()
            .map_err(|_| "Document reading state is unavailable")?;
        let expected = r.get("plan").ok_or("Missing document reading plan")?;
        if state.phase != "preview"
            || state.source_hash != hash
            || r["token"].as_str() != Some(&state.token)
            || serde_json::to_value(&state.plan).map_err(|e| e.to_string())? != *expected
        {
            return Err(
                "The document reading preview changed. Preview before reading again.".into(),
            );
        }
        let key = r["api_key"]
            .as_str()
            .filter(|s| !s.is_empty() && !s.chars().any(char::is_control))
            .ok_or("A valid API key is required to start document reading")?
            .to_owned();
        let plan = state
            .plan
            .clone()
            .ok_or("The document reading preview is missing")?;
        let chat = chat_plan_from_record(plan.clone()).map_err(|e| e.to_string())?;
        let settings = state
            .settings
            .clone()
            .ok_or("Document reading settings are missing")?;
        let cache = state
            .cache
            .as_ref()
            .ok_or("Document reading cache is not loaded")?;
        let audit = crate::audit::observer(cache.root.clone(), plan.action, plan.is_local);
        let cancel = CancellationToken::new();
        let worker_cancel = cancel.clone();
        let progress = Arc::new(Mutex::new(Progress {
            total: plan.parts.len(),
            ..Progress::default()
        }));
        let worker_progress = Arc::clone(&progress);
        std::thread::Builder::new()
            .name("lyra-document-reading".into())
            .spawn(move || {
                // The credential lives in this worker only, including the consented consolidation.
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    run_document_reading(
                        &chat,
                        settings,
                        ChatTransport::ChatCompletions,
                        &worker_cancel,
                        |plan, emit| {
                            worker_cancel.check()?;
                            lyra_reader_ai::openai::run_plan_audited(
                                plan,
                                &key,
                                &worker_cancel,
                                emit,
                                Arc::clone(&audit),
                            )
                        },
                        &mut |update| match worker_progress.lock() {
                            Ok(mut p) => match update {
                                ReadingUpdate::Parts { completed, total } => {
                                    p.completed = completed;
                                    p.total = total
                                }
                                ReadingUpdate::Combining { payloads } => {
                                    p.merge_payloads = payloads
                                }
                            },
                            Err(_) => worker_cancel.cancel(),
                        },
                    )
                }));
                let result = match outcome {
                    Ok(result) => {
                        result.map_err(|e| lyra_reader_ai::redact_error(e, &key).to_string())
                    }
                    Err(_) => Err("The document reading worker stopped unexpectedly.".into()),
                };
                if let Ok(mut p) = worker_progress.lock() {
                    p.result = Some(result);
                }
                // Poisoned progress is reported by the next poll; partial data is never reused.
            })
            .map_err(|e| e.to_string())?;
        state.job = Some(ReadingJob { cancel, progress });
        state.phase = "reading";
        state.message = None;
        state.view()
    }
    fn finish_reading(&self, state: &mut Knowledge, summary: String) -> Result<(), String> {
        let active = self.active()?;
        if current_hash(&active)? != state.source_hash {
            return Err("The PDF changed during document reading. No reading was saved.".into());
        }
        let plan = state
            .plan
            .as_ref()
            .ok_or("The completed reading has no source plan")?;
        let previous = state
            .baseline
            .as_ref()
            .and_then(|b| DocumentReading::decode(b, active.page_count()).ok());
        // A corrupt baseline is already recorded as cache_error, so it cannot be overwritten.
        let record = DocumentReading {
            version: 1,
            source_hash: state.source_hash.clone(),
            summary,
            pages: plan.source_pages.clone(),
            model: plan.model.clone(),
            read_at: chrono::Utc::now().timestamp_millis() as f64 / 1000.0 - 978_307_200.0,
            unknown: match previous {
                Some(record) => record.unknown,
                None => BTreeMap::new(),
            },
        };
        record.validate(active.page_count())?;
        let saved = self.persist_reading(state, &record, active.page_count());
        state.record = Some(record);
        state.phase = "ready";
        state.message = Some("Document reading is ready. New questions can use it.".into());
        if let Err(error) = saved {
            state.cache_error = Some(error);
            state.message =
                Some("Document reading is ready, but could not be saved for next time.".into());
        }
        Ok(())
    }
    fn poll_reading(&self) -> Result<Value, String> {
        let mut state = self
            .knowledge
            .lock()
            .map_err(|_| "Document reading state is unavailable")?;
        let finished = if let Some(job) = &state.job {
            job.progress
                .lock()
                .map_err(|_| "Document reading progress is unavailable")?
                .result
                .take()
        } else {
            None
        };
        if let Some(outcome) = finished {
            if let Some(job) = &state.job {
                let payloads = job
                    .progress
                    .lock()
                    .map_err(|_| "Document reading progress is unavailable")?
                    .merge_payloads
                    .clone();
                state.merge_payloads = payloads;
            }
            state.job = None;
            let result = outcome.and_then(|summary| self.finish_reading(&mut state, summary));
            if let Err(error) = result {
                state.phase = "failed";
                state.message = Some(error);
            }
        }
        state.status(false)
    }
    fn persist_reading(
        &self,
        state: &Knowledge,
        record: &DocumentReading,
        pages: u32,
    ) -> Result<(), String> {
        if let Some(error) = &state.cache_error {
            return Err(error.clone());
        }
        let cache = state
            .cache
            .as_ref()
            .ok_or("Document reading cache is unavailable")?;
        cache.validate_pdf_source()?;
        let mut options = fs::OpenOptions::new();
        options.create(true).truncate(false).read(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let lock = options
            .open(cache.directory.join(".document-reading.lock"))
            .map_err(|e| e.to_string())?;
        FileExt::try_lock_exclusive(&lock)
            .map_err(|e| format!("Another window is saving document reading. Try again: {e}"))?;
        let path = cache.directory.join(FILE);
        if state.baseline.as_ref().is_some_and(|bytes| {
            DocumentReading::decode(bytes, pages).is_ok_and(|r| !r.unknown.is_empty())
        }) {
            return Err("The previous reading contains fields this version does not own. Its exact file was kept; the new reading is available in this window only.".into());
        }
        if read_cache(&path)? != state.baseline {
            return Err("The saved document reading changed outside this window. The file was kept and the new reading remains in this window; reopen before replacing the cache.".into());
        }
        if let Some(previous) = &state.baseline {
            atomic_write(
                &cache.directory.join("document-knowledge-v1.previous.json"),
                previous,
            )?;
        }
        atomic_write(&path, &record.encode(pages)?)
    }
    pub(super) fn knowledge_command(&self, op: &str, r: &Value) -> Result<Value, String> {
        match op {
            "knowledge_load" => self.prepare_reading(None),
            "knowledge_prepare" => {
                self.prepare_reading(Some(crate::region::request(r["request"].clone())?))
            }
            "knowledge_start" => self.start_reading(r),
            "knowledge_poll" => self.poll_reading(),
            "knowledge_cancel" => {
                let mut s = self
                    .knowledge
                    .lock()
                    .map_err(|_| "Document reading state is unavailable")?;
                s.cancel(false)?;
                s.view()
            }
            _ => Err("Unknown document reading operation".into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    struct Fixture {
        root: PathBuf,
        path: PathBuf,
        doc: DesktopDocument,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "lyra-reading-check-{}",
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
            let doc = DesktopDocument::open_with_cache_root(&path, None, Some(&root.join("cache")))
                .unwrap();
            Self { root, path, doc }
        }
        fn file(&self) -> PathBuf {
            self.doc
                .marks
                .lock()
                .unwrap()
                .cache_location()
                .unwrap()
                .directory
                .join(FILE)
        }
        fn record(&self) -> DocumentReading {
            DocumentReading {
                version: 1,
                source_hash: self.doc.active().unwrap().document_identity().sha256,
                summary: "SYNTHETIC_SHARED_READING [p.1]".into(),
                pages: vec![1],
                model: "mock".into(),
                read_at: 1234.5,
                unknown: BTreeMap::new(),
            }
        }
        fn prepare(&self) -> Value {
            self.doc
                .command(json!({"op":"knowledge_prepare","request":input()}))
                .unwrap()
        }
        // Only cache publication is injected here; Qt's loopback tests exercise the real runner.
        fn publish(&self) -> Value {
            let mut s = self.doc.knowledge.lock().unwrap();
            assert_eq!(s.phase, "preview");
            s.job = Some(ReadingJob {
                cancel: CancellationToken::new(),
                progress: Arc::new(Mutex::new(Progress {
                    result: Some(Ok("COMPLETE_SYNTHETIC_READING [p.1]".into())),
                    ..Progress::default()
                })),
            });
            s.phase = "reading";
            drop(s);
            self.doc.command(json!({"op":"knowledge_poll"})).unwrap()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
    fn input() -> Value {
        json!({"action":"SummarizePage","document_knowledge":false,"current_page":0,"selection":null,"question":null,"language":null,"history":[],"region":null,"base_url":"http://127.0.0.1:1/v1","model":"mock","temperature":null,"max_tokens":null,"reasoning_mode":"default","reasoning_encoding":"none","document_knowledge_text":null,"document_knowledge_pages":[]})
    }
    #[test]
    fn cache_hit_is_network_free_unchanged_and_enriches_only_new_eligible_previews() {
        let f = Fixture::new();
        let mut record = f.record();
        record
            .unknown
            .insert("foreign".into(), json!({"keep":true}));
        let bytes = record.encode(1).unwrap();
        fs::write(f.file(), &bytes).unwrap();
        let loaded = f.doc.command(json!({"op":"knowledge_load"})).unwrap();
        assert_eq!(loaded["phase"], "ready");
        assert!(loaded["plan"].is_null());
        assert_eq!(fs::read(f.file()).unwrap(), bytes);
        let preview = f
            .doc
            .command(json!({"op":"ai_preview","request":input()}))
            .unwrap();
        assert!(
            preview["parts"][0]["wire_body"]
                .as_str()
                .unwrap()
                .contains("SYNTHETIC_SHARED_READING")
        );
        let mut translation = input();
        translation["action"] = json!("TranslateSelection");
        translation["language"] = json!("French");
        translation["selection"] = json!({"page":0,"start":0,"end":3});
        let translated = f
            .doc
            .command(json!({"op":"ai_preview","request":translation}))
            .unwrap();
        assert!(
            !translated["parts"][0]["wire_body"]
                .as_str()
                .unwrap()
                .contains("SYNTHETIC_SHARED_READING")
        );
        assert_eq!(fs::read(f.file()).unwrap(), bytes);
    }
    #[test]
    fn valid_completion_publishes_and_reopens_without_another_plan() {
        let f = Fixture::new();
        let preview = f.prepare();
        assert_eq!(preview["phase"], "preview");
        assert!(!f.file().exists());
        assert_eq!(f.publish()["phase"], "ready");
        let bytes = fs::read(f.file()).unwrap();
        let record = DocumentReading::decode(&bytes, 1).unwrap();
        assert_eq!(record.summary, "COMPLETE_SYNTHETIC_READING [p.1]");
        let reopened =
            DesktopDocument::open_with_cache_root(&f.path, None, Some(&f.root.join("cache")))
                .unwrap();
        let loaded = reopened.command(json!({"op":"knowledge_load"})).unwrap();
        assert_eq!(loaded["phase"], "ready");
        assert!(loaded["plan"].is_null());
        assert_eq!(fs::read(f.file()).unwrap(), bytes);
    }
    #[test]
    fn corrupt_foreign_and_concurrently_modified_files_are_not_overwritten() {
        for case in ["corrupt", "unknown", "concurrent"] {
            let f = Fixture::new();
            let before = if case == "unknown" {
                let mut r = f.record();
                r.source_hash = "ab".repeat(32);
                r.unknown.insert("foreign".into(), json!([1, 2, 3]));
                r.encode(1).unwrap()
            } else {
                b"foreign exact bytes".to_vec()
            };
            if case != "concurrent" {
                fs::write(f.file(), &before).unwrap();
            }
            assert_eq!(f.prepare()["phase"], "preview");
            if case == "concurrent" {
                fs::write(f.file(), &before).unwrap();
            }
            let done = f.publish();
            assert_eq!(done["phase"], "ready");
            assert!(
                done["cache_warning"]
                    .as_str()
                    .is_some_and(|s| !s.is_empty())
            );
            assert_eq!(fs::read(f.file()).unwrap(), before);
        }
    }
    #[test]
    fn changed_source_and_stopped_epochs_cannot_publish_or_start_stale_plans() {
        let f = Fixture::new();
        let preview = f.prepare();
        let token = CancellationToken::new();
        f.doc.knowledge.lock().unwrap().job = Some(ReadingJob {
            cancel: token.clone(),
            progress: Arc::new(Mutex::new(Progress::default())),
        });
        f.doc.command(json!({"op":"knowledge_cancel"})).unwrap();
        assert!(token.is_cancelled());
        assert!(f.doc.command(json!({"op":"knowledge_start","plan":preview["plan"],"token":preview["token"],"api_key":"local"})).unwrap_err().contains("preview changed"));
        assert!(!f.file().exists());
        assert_eq!(f.prepare()["phase"], "preview");
        let mut source = fs::read(&f.path).unwrap();
        source.extend_from_slice(b"\n% external synthetic edit\n");
        fs::write(&f.path, source).unwrap();
        assert_eq!(f.publish()["phase"], "failed");
        assert!(!f.file().exists());
    }
    #[test]
    fn oversized_cache_is_rejected_without_reading_or_replacing_its_payload() {
        let f = Fixture::new();
        let file = fs::File::create(f.file()).unwrap();
        let length = lyra_reader_ai::knowledge::MAX_READING_BYTES as u64 + 1;
        file.set_len(length).unwrap();
        drop(file);
        let state = f.prepare();
        assert_eq!(state["phase"], "failed");
        assert!(state["message"].as_str().unwrap().contains("8 MiB"));
        assert_eq!(fs::metadata(f.file()).unwrap().len(), length);
        assert!(
            f.doc
                .command(json!({"op":"ai_preview","request":input()}))
                .is_ok()
        );
    }
    #[test]
    fn save_migration_keeps_an_existing_destination_reading_instead_of_overwriting_it() {
        let f = Fixture::new();
        assert_eq!(f.prepare()["phase"], "preview");
        assert_eq!(f.publish()["phase"], "ready");
        let cache = f
            .doc
            .marks
            .lock()
            .unwrap()
            .cache_location()
            .unwrap()
            .clone();
        let old = fs::read(f.file()).unwrap();
        let mut saved = fs::read(&f.path).unwrap();
        saved.extend_from_slice(b"\n% synthetic saved revision\n");
        fs::write(&f.path, &saved).unwrap();
        let next = DocumentCache::open(&f.path, &cache.root).unwrap();
        assert_ne!(next.directory, cache.directory);
        let destination = next.directory.join(FILE);
        let foreign = b"unowned exact destination cache bytes";
        fs::write(&destination, foreign).unwrap();
        let result = cache.after_save();
        assert_eq!(fs::read(destination).unwrap(), foreign);
        assert!(
            result
                .err()
                .expect("the destination conflict must be reported")
                .contains("destination document reading")
        );
        assert_eq!(fs::read(f.file()).unwrap(), old);
        assert_eq!(fs::read(&f.path).unwrap(), saved);
    }
    #[test]
    fn foreground_preview_does_not_wait_for_optional_reading_state_io() {
        use std::{sync::mpsc, time::Duration};
        let f = Arc::new(Fixture::new());
        let hash = f.doc.active().unwrap().document_identity().sha256;
        let guard = f.doc.knowledge.lock().unwrap();
        let worker = Arc::clone(&f);
        let (tx, rx) = mpsc::channel();
        let join = std::thread::spawn(move || {
            let mut request = crate::region::request(input()).unwrap();
            let result = worker.doc.enrich_reading(&mut request, &hash);
            tx.send(result.is_ok() && request.document_knowledge_text.is_none())
                .unwrap();
        });
        let response = rx.recv_timeout(Duration::from_secs(1));
        drop(guard);
        join.join().unwrap();
        assert_eq!(response, Ok(true));
    }
}
