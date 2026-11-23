//! Document-owned in-place translation: canonical previews, bounded audited jobs and atomic cache I/O.
use crate::document::{DesktopDocument, chatgpt_account};
use crate::document_cache::{DocumentCache, atomic_write, read_optional_bounded};
use crate::summary_batch::Scope;
use lyra_reader_ai::translation::{
    Cache, Entry, MAX_ANSWER_BYTES, MAX_BYTES, MAX_CONCURRENT, PROMPT_VERSION, cache_key,
};
use lyra_reader_core::Rect;
use lyra_reader_ffi::{api::*, translation::TranslationTargetRecord};
use serde::Serialize;
use serde_json::{Value, json};
use std::{
    path::PathBuf,
    sync::{Arc, Weak},
};

pub(crate) fn append_warning(report: &mut Value, error: String) {
    if !report.is_object() {
        *report = json!({});
    }
    let message =
        format!("The PDF operation completed, but its translation cache needs attention: {error}");
    report["cache_cleanup_error"] = json!(match report["cache_cleanup_error"].as_str() {
        Some(previous) => format!("{previous}. {message}"),
        None => message,
    });
}

mod revisions;
pub(crate) use revisions::RevisionChange;

const FILE: &str = "translations.json";

#[derive(Default)]
struct Store {
    override_path: Option<PathBuf>,
    protection: Option<String>,
    path: Option<PathBuf>,
    baseline: Option<Vec<u8>>,
    cache: Cache,
    error: Option<String>,
    source_error: Option<String>,
}
impl Store {
    fn load(&mut self, location: &DocumentCache) -> Result<(), String> {
        let path = self
            .override_path
            .clone()
            .unwrap_or_else(|| location.directory.join(FILE));
        let bytes = read_optional_bounded(&path, MAX_BYTES as u64)?;
        if self.path.as_ref() == Some(&path) {
            if bytes != self.baseline {
                return Err("The translation cache changed outside this window. Reopen before saving translations; both versions were kept.".into());
            }
            return Ok(());
        }
        let (cache, error) = match bytes.as_deref() {
            Some(bytes) => match Cache::decode(bytes) {
                Ok(cache) => (cache, None),
                Err(error) => (Cache::default(), Some(error)),
            },
            None => (Cache::default(), None),
        };
        self.path = Some(path);
        self.baseline = bytes;
        self.cache = cache;
        self.error = error;
        Ok(())
    }
    fn warning(&self) -> Option<String> {
        self.protection
            .as_ref()
            .or(self.source_error.as_ref())
            .or(self.error.as_ref())
            .or(self.cache.warning.as_ref())
            .cloned()
    }
    fn put(&mut self, location: &DocumentCache, entry: Entry) -> Result<(), String> {
        if let Some(error) = self.protection.as_ref().or(self.source_error.as_ref()) {
            return Err(error.clone());
        }
        location.validate_pdf_source()?;
        self.load(location)?;
        if let Some(error) = &self.error {
            return Err(error.clone());
        }
        let mut next = self.cache.clone();
        next.put(entry)?;
        let path = self
            .path
            .as_ref()
            .ok_or("The translation cache is not loaded.")?;
        let _lease = crate::document_cache::lock_translation_cache(
            path.parent()
                .ok_or("The translation cache has no directory.")?,
        )?;
        location.validate_pdf_source()?;
        if read_optional_bounded(path, MAX_BYTES as u64)? != self.baseline {
            return Err(
                "The translation cache changed before publication; the original was kept.".into(),
            );
        }
        if let Some(previous) = &self.baseline {
            atomic_write(&path.with_extension("previous.json"), previous)?;
        }
        atomic_write(path, next.encode())?;
        self.baseline = Some(next.encode().to_vec());
        self.cache = next;
        Ok(())
    }
}

#[derive(Clone, Copy, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
enum State {
    Prepared,
    Queued,
    Sending,
    Ready,
    Failed,
    Cancelled,
}
#[derive(Clone, Serialize)]
struct RowView {
    id: String,
    view_key: String,
    language: String,
    model: String,
    target: TranslationTargetRecord,
    state: State,
    translated_text: String,
    error: Option<String>,
    cache_warning: Option<String>,
    cached: bool,
}
struct Row {
    view: RowView,
    entry: Entry,
    plan: Option<AiPlanRecord>,
    job: Option<Arc<LyraReaderAiRequest>>,
    done: bool,
    limited: bool,
}
impl Drop for Row {
    fn drop(&mut self) {
        if let Some(job) = &self.job {
            job.cancel();
        }
    }
}

pub(crate) struct Translations {
    base_path: Option<PathBuf>,
    base_baseline: Option<Vec<u8>>,
    session_lease: Option<Arc<crate::session::SessionDirectory>>,
    scope: Arc<Scope>,
    id: u64,
    token: String,
    account: Option<String>,
    source: Weak<LyraReaderDocument>,
    rows: Vec<Row>,
    store: Store,
    running: bool,
    notice: Option<String>,
    key: Option<String>,
    audit_root: Option<PathBuf>,
}
impl Translations {
    pub(crate) fn new(scope: Arc<Scope>) -> Self {
        Self {
            base_path: None,
            base_baseline: None,
            session_lease: None,
            scope,
            id: 0,
            token: String::new(),
            account: None,
            source: Weak::new(),
            rows: Vec::new(),
            store: Store::default(),
            running: false,
            notice: None,
            key: None,
            audit_root: None,
        }
    }
    pub(crate) fn running(&self) -> bool {
        self.running
    }
    fn display_warning(&self) -> Option<String> {
        self.store.warning().or_else(|| self.notice.clone())
    }
    fn snapshot(&mut self) -> Value {
        let value = json!({"token":self.token,"running":self.running,"rows":self.rows.iter().map(|r|&r.view).collect::<Vec<_>>(),"max_concurrent":MAX_CONCURRENT,"cache_warning":self.display_warning()});
        // The native shell retains completed overlays. Deliver full answers once, rather
        // than reserializing every completed 512 KiB answer on every streaming poll.
        for row in &mut self.rows {
            if row.view.state == State::Ready {
                row.view.translated_text.clear();
            }
        }
        value
    }
    fn prepare(
        &mut self,
        document: &Arc<LyraReaderDocument>,
        mut request: AiPlanRequestRecord,
        account: Option<String>,
        location: &DocumentCache,
    ) -> Result<Value, String> {
        if self.running {
            return Err("Stop the current translation before preparing another.".into());
        }
        self.rows.clear();
        self.token.clear();
        self.account = None;
        self.source = Weak::new();
        self.id = self.scope.begin()?;
        let selection = request
            .selection
            .ok_or("Select text to translate in place.")?;
        if !document.text_page_prepared(selection.page) {
            document
                .text_page(selection.page)
                .map_err(|e| e.to_string())?;
        }
        let targets = document
            .text_translation_targets(selection.page, selection.start, selection.end)
            .map_err(|e| e.to_string())?
            .ok_or("The translation text page is not prepared.")?;
        if targets.is_empty() {
            return Err("The selection has no text to translate.".into());
        }
        request.action = AiActionRecord::TranslateSelection;
        request.document_knowledge = false;
        request.document_knowledge_text = None;
        request.document_knowledge_pages.clear();
        if account.is_some() {
            request.base_url = "https://api.openai.com/v1".into();
            request.reasoning_mode = "default".into();
            request.reasoning_encoding = "none".into();
        }
        let language = request
            .language
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or("English")
            .to_owned();
        request.language = Some(language.clone());
        let warning = self
            .capture_base(location)
            .err()
            .or_else(|| self.store.load(location).err())
            .or_else(|| self.store.warning());
        let mut first = None;
        let mut parts = Vec::new();
        let mut previews = Vec::new();
        let mut estimated = 0u64;
        for target in targets {
            request.selection = Some(AiSelectionRecord {
                page: target.page,
                start: target.start,
                end: target.end,
            });
            let plan = document
                .prepare_inplace_translation_plan(request.clone())
                .and_then(|plan| {
                    if account.is_some() {
                        render_chatgpt_plan(plan)
                    } else {
                        render_ai_plan(plan, AiWireTransport::ChatCompletions)
                    }
                })
                .map_err(|e| e.to_string())?;
            if plan.parts.len() != 1 {
                return Err("One translation target must produce exactly one request.".into());
            }
            let rect = Rect::new(
                target.rect.x_pt,
                target.rect.y_pt,
                target.rect.width_pt,
                target.rect.height_pt,
            );
            let key = cache_key(
                &target.source_text,
                target.page,
                rect,
                &language,
                &plan.model,
                PROMPT_VERSION,
            )?;
            let cached = if self.store.protection.is_none()
                && self.store.source_error.is_none()
                && self.store.error.is_none()
            {
                self.store.cache.get(&key).cloned()
            } else {
                None
            };
            let entry = cached.clone().unwrap_or_else(|| Entry {
                key: key.clone(),
                page: target.page,
                x: rect.min_x(),
                y: rect.min_y(),
                width: rect.size.width,
                height: rect.size.height,
                source_text: target.source_text.clone(),
                translated_text: String::new(),
                language: language.clone(),
                model: plan.model.clone(),
                prompt_version: PROMPT_VERSION.into(),
                range_start: Some(target.start),
                range_end: Some(target.end),
                is_block: target.is_block,
                created_at: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
            });
            let view = RowView {
                id: key.clone(),
                view_key: cache_key(
                    &entry.source_text,
                    0,
                    entry.rect(),
                    &entry.language,
                    &entry.model,
                    &entry.prompt_version,
                )?,
                language: entry.language.clone(),
                model: entry.model.clone(),
                target,
                state: if cached.is_some() {
                    State::Ready
                } else {
                    State::Prepared
                },
                translated_text: entry.translated_text.clone(),
                error: None,
                cache_warning: warning.clone(),
                cached: cached.is_some(),
            };
            if cached.is_none() {
                estimated = estimated
                    .checked_add(plan.estimated_tokens)
                    .ok_or("The translation token estimate overflowed.")?;
                previews.push(json!({"id":key,"title":format!("Passage {}",previews.len()+1),"page_span":format!("Page {}",entry.page+1),"part_index":parts.len()}));
                parts.extend(plan.parts.clone());
                if first.is_none() {
                    first = Some(plan.clone());
                }
            }
            self.rows.push(Row {
                view,
                entry,
                plan: cached.is_none().then_some(plan),
                job: None,
                done: false,
                limited: false,
            });
        }
        self.token = crate::marks::uuid()?;
        self.source = Arc::downgrade(document);
        let envelope = if let Some(mut plan) = first {
            plan.parts = parts;
            plan.estimated_tokens = estimated;
            let mut value = serde_json::to_value(plan).map_err(|e| e.to_string())?;
            if let Some(account) = &account {
                value["chatgpt_account"] = json!(account);
            }
            value["kind"] = json!("inplace_translation");
            value["token"] = json!(self.token);
            value["translation_rows"] = json!(previews);
            Some(value)
        } else {
            None
        };
        self.account = if envelope.is_some() { account } else { None };
        Ok(json!({"plan":envelope,"translation":self.snapshot()}))
    }
    fn start(
        &mut self,
        document: &Arc<LyraReaderDocument>,
        token: &str,
        account: Option<&str>,
        credential: Option<&str>,
        root: PathBuf,
    ) -> Result<Value, String> {
        if self.running {
            return Err("This translation is already running.".into());
        }
        if token.is_empty()
            || token != self.token
            || self.scope.cancelled(self.id)
            || !self.source.ptr_eq(&Arc::downgrade(document))
        {
            return Err(
                "The translation preview changed or was cancelled. Preview again before sending."
                    .into(),
            );
        }
        if account != self.account.as_deref() {
            return Err("The ChatGPT connection changed. Preview the translation again.".into());
        }
        let key = credential.ok_or(if account.is_some() {
            "Sign in to ChatGPT before starting the translation."
        } else {
            "Missing API key."
        })?;
        for row in &mut self.rows {
            if row.view.state == State::Prepared {
                row.view.state = State::Queued;
            }
        }
        self.key = Some(key.to_owned());
        self.audit_root = Some(root);
        self.running = true;
        self.schedule()?;
        Ok(self.snapshot())
    }
    fn schedule(&mut self) -> Result<(), String> {
        if self.scope.cancelled(self.id) {
            self.stop();
            return Ok(());
        }
        while self.rows.iter().filter(|r| r.job.is_some()).count() < MAX_CONCURRENT {
            if self.scope.cancelled(self.id) {
                self.stop();
                break;
            }
            let Some(row) = self.rows.iter_mut().find(|r| r.view.state == State::Queued) else {
                break;
            };
            let plan = row
                .plan
                .take()
                .ok_or("The prepared translation is unavailable.")?;
            let key = self
                .key
                .as_ref()
                .ok_or("Translation credentials are unavailable.")?;
            let root = self
                .audit_root
                .as_ref()
                .ok_or("The translation audit directory is unavailable.")?;
            let observer = crate::audit::observer(root.clone(), plan.action, plan.is_local);
            let job = if self.account.is_some() {
                start_chatgpt_request_audited(plan, key.clone(), observer)
            } else {
                start_ai_request_audited(plan, key.clone(), false, Some(observer))
            };
            match job {
                Ok(job) => {
                    row.job = Some(job);
                    row.view.state = State::Sending;
                }
                Err(error) => {
                    row.view.state = State::Failed;
                    row.view.error = Some(error.to_string());
                }
            }
        }
        self.running = self
            .rows
            .iter()
            .any(|r| r.job.is_some() || r.view.state == State::Queued);
        if !self.running {
            self.key = None;
            self.audit_root = None;
        }
        Ok(())
    }
    fn stop(&mut self) {
        for row in &mut self.rows {
            if let Some(job) = &row.job {
                job.cancel();
            }
            if matches!(
                row.view.state,
                State::Queued | State::Sending | State::Prepared
            ) {
                row.view.state = State::Cancelled;
                row.plan = None;
            }
        }
        self.key = None;
        self.audit_root = None;
        self.running = self.rows.iter().any(|row| row.job.is_some());
    }
    fn poll(
        &mut self,
        document: &Arc<LyraReaderDocument>,
        token: &str,
        location: &DocumentCache,
    ) -> Result<Value, String> {
        if token != self.token {
            return Err("This translation response belongs to an earlier preview.".into());
        }
        if !self.source.ptr_eq(&Arc::downgrade(document)) {
            self.scope.cancel();
        }
        if self.scope.cancelled(self.id) {
            self.stop();
        }
        for row in &mut self.rows {
            let Some(job) = &row.job else {
                continue;
            };
            let finished = job.is_finished();
            let events = job.poll();
            for event in events {
                match event {
                    AiEventRecord::Delta { text } if !row.limited => {
                        if row
                            .view
                            .translated_text
                            .len()
                            .checked_add(text.len())
                            .is_some_and(|n| n <= MAX_ANSWER_BYTES)
                        {
                            row.view.translated_text.push_str(&text);
                        } else {
                            row.limited = true;
                            row.view.error = Some(
                                "The translation exceeds the 512 KiB limit; it was not cached."
                                    .into(),
                            );
                            job.cancel();
                        }
                    }
                    AiEventRecord::Done => row.done = true,
                    AiEventRecord::Error {
                        message, cancelled, ..
                    } => {
                        row.view.error = Some(message);
                        row.view.state = if cancelled {
                            State::Cancelled
                        } else {
                            State::Failed
                        };
                    }
                    _ => {}
                }
            }
            if finished {
                row.job = None;
                if row.view.state == State::Sending
                    && row.done
                    && !row.limited
                    && !row.view.translated_text.trim().is_empty()
                {
                    row.view.state = State::Ready;
                    row.entry.translated_text = row.view.translated_text.clone();
                    row.entry.created_at =
                        chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
                    if self.scope.cancelled(self.id) {
                        row.view.state = State::Cancelled;
                        continue;
                    }
                    match self.store.put(location, row.entry.clone()) {
                        Ok(()) => {
                            row.view.cached = true;
                            if self.store.override_path.is_none() {
                                self.base_path = Some(location.directory.join(FILE));
                                self.base_baseline = self.store.baseline.clone();
                            }
                        }
                        Err(error) => row.view.cache_warning = Some(error),
                    }
                } else if row.view.state == State::Sending {
                    row.view.state = State::Failed;
                    row.view.error.get_or_insert(
                        "The request ended without a complete translation; nothing was cached."
                            .into(),
                    );
                }
            }
        }
        self.schedule()?;
        Ok(self.snapshot())
    }
    fn inspect(
        &mut self,
        document: &Arc<LyraReaderDocument>,
        page: u32,
        location: &DocumentCache,
    ) -> Result<Value, String> {
        lyra_reader_core::checked_page_index(page, document.page_count(), |p| {
            lyra_reader_core::page_out_of_range_message(p, document.page_count())
        })?;
        self.capture_base(location)?;
        self.store.load(location)?;
        if let Some(error) = &self.store.protection {
            return Ok(json!({"entries":[],"cache_warning":error}));
        }
        if let Some(error) = self
            .store
            .source_error
            .as_ref()
            .or(self.store.error.as_ref())
        {
            return Ok(json!({"entries":[],"cache_warning":error}));
        }
        let entries = self
            .store
            .cache
            .entries_for_page(page)?
            .into_iter()
            .cloned()
            .collect::<Vec<_>>();
        if entries.is_empty() {
            return Ok(json!({"entries":[],"cache_warning":self.display_warning()}));
        }
        if !document.text_page_prepared(page) {
            document.text_page(page).map_err(|e| e.to_string())?;
        }
        let blocks = document
            .text_translation_blocks(page)
            .map_err(|e| e.to_string())?
            .ok_or("The translation page is not prepared.")?;
        let characters = document
            .prepared_selection_text_page(page)
            .map_err(|e| e.to_string())?
            .ok_or("The translation page was evicted during validation.")?
            .chars()
            .len();
        let mut valid = Vec::new();
        let mut stale = 0usize;
        for entry in entries {
            let matches = |t: &&TranslationTargetRecord| {
                t.source_text == entry.source_text
                    && (t.rect.x_pt - entry.x).abs() < 1.5
                    && (t.rect.y_pt - entry.y).abs() < 1.5
                    && (t.rect.width_pt - entry.width).abs() < 1.5
                    && (t.rect.height_pt - entry.height).abs() < 1.5
            };
            let target = if entry.is_block {
                blocks.iter().find(matches).cloned()
            } else if let Some((start, end)) = entry.range_start.zip(entry.range_end) {
                if start > end || end as usize >= characters {
                    stale += 1;
                    continue;
                }
                let targets = document
                    .text_translation_targets(page, start, end)
                    .map_err(|e| e.to_string())?
                    .ok_or("The translation page was evicted during validation.")?;
                targets.iter().find(matches).cloned()
            } else {
                None
            };
            if let Some(target) = target {
                let view_key = cache_key(
                    &entry.source_text,
                    0,
                    entry.rect(),
                    &entry.language,
                    &entry.model,
                    &entry.prompt_version,
                )?;
                valid.push(json!({"entry":entry,"target":target,"view_key":view_key}));
            } else {
                stale += 1;
            }
        }
        // A working revision may still be undone. Hide invalid overlays without destroying
        // the original cache; its source- and geometry-derived identities cannot be reused.
        Ok(json!({"entries":valid,"stale":stale,"cache_warning":self.display_warning()}))
    }
}

impl DesktopDocument {
    pub(crate) fn request_translation_cancel(&self) {
        self.translation_scope.cancel();
    }
    pub(crate) fn translations_running(&self) -> Result<bool, String> {
        Ok(self
            .translations
            .lock()
            .map_err(|_| "Translation state is unavailable.")?
            .running())
    }
    pub(crate) fn translation_command(&self, op: &str, r: &Value) -> Result<Value, String> {
        let document = self.active()?;
        if matches!(op, "translation_prepare" | "translation_start")
            && (self.ai_running()? || self.summary_running()?)
        {
            return Err(
                "Stop the current response before preparing or sending an in-place translation."
                    .into(),
            );
        }
        // Match the established edit -> active identity -> marks -> store lock order.
        let _edits = self
            .edits
            .lock()
            .map_err(|_| "Page-edit state is unavailable.")?;
        if !Arc::ptr_eq(&self.active()?, &document) {
            return Err("The document changed before the translation operation.".into());
        }
        let marks = self
            .marks
            .lock()
            .map_err(|_| "Annotation state is unavailable.")?;
        let location = marks.cache_location()?;
        let mut translations = self
            .translations
            .lock()
            .map_err(|_| "Translation state is unavailable.")?;
        if matches!(
            op,
            "translation_prepare" | "translation_inspect" | "translation_start"
        ) {
            translations.store.source_error = marks.validate_source().err();
        }
        match op {
            "translation_prepare" => translations.prepare(
                &document,
                crate::region::request(r["request"].clone())?,
                chatgpt_account(&r["request"])?.map(str::to_owned),
                location,
            ),
            "translation_start" => {
                location.validate_pdf_source()?;
                let account = chatgpt_account(r)?;
                let field = if account.is_some() {
                    "chatgpt_access_token"
                } else {
                    "api_key"
                };
                translations.start(
                    &document,
                    r["token"].as_str().ok_or("Missing translation token.")?,
                    account,
                    r[field].as_str(),
                    location.root.clone(),
                )
            }
            "translation_poll" => translations.poll(
                &document,
                r["token"].as_str().ok_or("Missing translation token.")?,
                location,
            ),
            "translation_cancel" => {
                let token = r["token"].as_str().ok_or("Missing translation token.")?;
                // A queued cleanup may arrive after a newer preview. Its token owns
                // only the earlier scope and must not cancel the current admission.
                if token != translations.token {
                    return Ok(json!({"cancelled":false,"obsolete":true}));
                }
                self.translation_scope.cancel();
                translations.poll(&document, token, location)
            }
            "translation_inspect" => translations.inspect(
                &document,
                u32::try_from(r["page"].as_u64().ok_or("Missing translation page.")?)
                    .map_err(|_| "Invalid translation page.")?,
                location,
            ),
            _ => Err("Unknown translation operation.".into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        io::{Read, Write},
        net::TcpListener,
        sync::{
            Mutex,
            atomic::{AtomicBool, AtomicUsize, Ordering},
        },
        thread,
        time::{Duration, Instant},
    };
    struct Fixture {
        root: PathBuf,
        document: DesktopDocument,
        cache: DocumentCache,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "lyra-translation-{}",
                crate::marks::uuid().unwrap()
            ));
            fs::create_dir(&root).unwrap();
            let path = root.join("synthetic.pdf");
            let mut stream = "BT /F1 12 Tf 40 720 Td ".to_owned();
            for i in 0..6 {
                stream.push_str(&format!(
                    "(Synthetic paragraph {i} for translation.) Tj 0 -50 Td "
                ));
            }
            stream.push_str("ET");
            let objects=["<< /Type /Catalog /Pages 2 0 R >>".into(),"<< /Type /Pages /Kids [3 0 R] /Count 1 >>".into(),"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>".into(),"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".into(),format!("<< /Length {} >>\nstream\n{stream}\nendstream",stream.len())];
            let mut pdf = "%PDF-1.7\n".to_owned();
            let mut offsets = Vec::new();
            for (i, object) in objects.iter().enumerate() {
                offsets.push(pdf.len());
                pdf.push_str(&format!("{} 0 obj\n{object}\nendobj\n", i + 1));
            }
            let xref = pdf.len();
            pdf.push_str("xref\n0 6\n0000000000 65535 f \n");
            for offset in offsets {
                pdf.push_str(&format!("{offset:010} 00000 n \n"));
            }
            pdf.push_str(&format!(
                "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n"
            ));
            fs::write(&path, pdf).unwrap();
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
        fn copied(name: &str) -> Self {
            let root = std::env::temp_dir().join(format!(
                "lyra-translation-revisions-{}",
                crate::marks::uuid().unwrap()
            ));
            fs::create_dir(&root).unwrap();
            let path = root.join("synthetic.pdf");
            fs::copy(
                PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join("../../tests/fixtures")
                    .join(name),
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
        fn request(&self, base: &str) -> Value {
            let page = self.document.active().unwrap().text_page(0).unwrap();
            json!({"action":"TranslateSelection","base_url":base,"model":"synthetic","language":"French","current_page":0,"selection":{"page":0,"start":0,"end":page.chars.len()-1},"region":null,"question":null,"history":[],"temperature":null,"max_tokens":null,"reasoning_mode":"default","reasoning_encoding":"none","document_knowledge":false,"document_knowledge_text":null,"document_knowledge_pages":[]})
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
    struct Server {
        url: String,
        bodies: Arc<Mutex<Vec<Vec<u8>>>>,
        peak: Arc<AtomicUsize>,
        stop: Arc<AtomicBool>,
        worker: Option<thread::JoinHandle<()>>,
    }
    impl Server {
        fn new(delay: Duration, complete: bool) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            listener.set_nonblocking(true).unwrap();
            let url = format!("http://{}/v1", listener.local_addr().unwrap());
            let bodies = Arc::new(Mutex::new(Vec::new()));
            let peak = Arc::new(AtomicUsize::new(0));
            let active = Arc::new(AtomicUsize::new(0));
            let stop = Arc::new(AtomicBool::new(false));
            let (b, p, a, s) = (bodies.clone(), peak.clone(), active, stop.clone());
            let worker = thread::spawn(move || {
                let mut children = Vec::new();
                while !s.load(Ordering::SeqCst) {
                    match listener.accept() {
                        Ok((mut socket, _)) => {
                            let (b, p, a, s) = (b.clone(), p.clone(), a.clone(), s.clone());
                            children.push(thread::spawn(move||{
                    socket.set_read_timeout(Some(Duration::from_secs(3))).unwrap();let mut bytes=Vec::new();let mut buffer=[0;4096];let header_end=loop {let n=socket.read(&mut buffer).unwrap();assert!(n>0);bytes.extend_from_slice(&buffer[..n]);if let Some(i)=bytes.windows(4).position(|v|v==b"\r\n\r\n"){break i+4;}assert!(bytes.len()<65536);};
                    let header=std::str::from_utf8(&bytes[..header_end]).unwrap();let count=header.lines().find_map(|l|l.split_once(':').filter(|(name,_)|name.eq_ignore_ascii_case("content-length")).map(|(_,v)|v.trim().parse::<usize>().unwrap())).unwrap();assert!(count<1024*1024);
                    while bytes.len()-header_end<count {let n=socket.read(&mut buffer).unwrap();assert!(n>0);bytes.extend_from_slice(&buffer[..n]);}
                    b.lock().unwrap().push(bytes[header_end..header_end+count].to_vec());let now=a.fetch_add(1,Ordering::SeqCst)+1;p.fetch_max(now,Ordering::SeqCst);
                    let begun=Instant::now();while begun.elapsed()<delay && !s.load(Ordering::SeqCst){thread::sleep(Duration::from_millis(5));}
                    let done=if complete {"data: [DONE]\n\n"}else{""};let body=format!("data: {{\"choices\":[{{\"delta\":{{\"content\":\"Synthetic complete translation\"}}}}]}}\n\n{done}");let response=format!("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len());let _=socket.write_all(response.as_bytes());a.fetch_sub(1,Ordering::SeqCst);
                }));
                        }
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(2))
                        }
                        Err(e) => panic!("loopback accept: {e}"),
                    }
                }
                for child in children {
                    child.join().unwrap();
                }
            });
            Self {
                url,
                bodies,
                peak,
                stop,
                worker: Some(worker),
            }
        }
    }
    impl Drop for Server {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::SeqCst);
            self.worker.take().unwrap().join().unwrap();
        }
    }
    fn wait(doc: &DesktopDocument, token: &Value) -> Value {
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            let state = doc
                .command(json!({"op":"translation_poll","token":token}))
                .unwrap();
            if state["running"] == false {
                return state;
            }
            assert!(
                Instant::now() < deadline,
                "translation did not finish: {state}"
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn seed(fixture: &Fixture) -> Vec<u8> {
        let document = fixture.document.active().unwrap();
        let mut cache = Cache::default();
        for page in 0..document.page_count() {
            let text = document.text_page(page).unwrap();
            let target = document
                .text_translation_targets(page, 0, text.chars.len() as u32 - 1)
                .unwrap()
                .unwrap()
                .remove(0);
            let rect = Rect::new(
                target.rect.x_pt,
                target.rect.y_pt,
                target.rect.width_pt,
                target.rect.height_pt,
            );
            cache
                .put(Entry {
                    key: cache_key(
                        &target.source_text,
                        page,
                        rect,
                        "French",
                        "synthetic",
                        PROMPT_VERSION,
                    )
                    .unwrap(),
                    page,
                    x: rect.min_x(),
                    y: rect.min_y(),
                    width: rect.size.width,
                    height: rect.size.height,
                    source_text: target.source_text,
                    translated_text: format!("SAVED_{page}"),
                    language: "French".into(),
                    model: "synthetic".into(),
                    prompt_version: PROMPT_VERSION.into(),
                    range_start: Some(target.start),
                    range_end: Some(target.end),
                    is_block: target.is_block,
                    created_at: "2026-11-18T00:00:00Z".into(),
                })
                .unwrap();
        }
        let bytes = cache.encode().to_vec();
        fs::write(fixture.cache.directory.join(FILE), &bytes).unwrap();
        bytes
    }
    fn saved_text(doc: &DesktopDocument, page: u32) -> Vec<String> {
        doc.command(json!({"op":"translation_inspect","page":page}))
            .unwrap()["entries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v["entry"]["translatedText"].as_str().unwrap().to_owned())
            .collect()
    }
    #[test]
    fn publishing_a_translation_snapshot_preserves_an_external_cache_deletion() {
        let fixture = Fixture::new();
        let original = seed(&fixture);
        let mut translations = fixture.document.translations.lock().unwrap();
        let snapshot = translations.save_snapshot(&fixture.cache).unwrap().unwrap();
        let path = fixture.cache.directory.join(FILE);
        fs::remove_file(&path).unwrap();
        let error = translations
            .publish_snapshot(&fixture.cache, Some(&snapshot))
            .unwrap_err();
        assert!(error.contains("destination translations changed"));
        assert!(
            !path.exists(),
            "An external deletion must not be silently undone"
        );
        let recovery = fs::read_dir(&fixture.cache.directory)
            .unwrap()
            .filter_map(Result::ok)
            .find(|e| {
                e.file_name()
                    .to_string_lossy()
                    .starts_with("translations.recovery-")
            })
            .unwrap();
        assert_eq!(fs::read(recovery.path()).unwrap(), original);
    }
    #[test]
    fn revision_cache_follows_move_delete_undo_redo_and_verified_save_without_touching_the_base() {
        let fixture = Fixture::copied("multipage.pdf");
        let original = seed(&fixture);
        let doc = &fixture.document;
        assert_eq!(saved_text(doc, 0), vec!["SAVED_0"]);
        let before_view = doc
            .command(json!({"op":"translation_inspect","page":0}))
            .unwrap()["entries"][0]["view_key"]
            .as_str()
            .unwrap()
            .to_owned();
        assert_eq!(before_view.len(), 64);
        let moved = doc
            .command(json!({"op":"page_stage","operation":{"Move":{"pages":[0],"destination":2}}}))
            .unwrap();
        assert!(moved["report"]["cache_cleanup_error"].is_null(), "{moved}");
        assert_eq!(saved_text(doc, 2), vec!["SAVED_0"]);
        assert_eq!(
            doc.command(json!({"op":"translation_inspect","page":2}))
                .unwrap()["entries"][0]["view_key"],
            before_view
        );
        let path = doc
            .translations
            .lock()
            .unwrap()
            .store
            .override_path
            .clone()
            .unwrap();
        assert!(path.exists());
        assert_eq!(
            fs::read(fixture.cache.directory.join(FILE)).unwrap(),
            original
        );
        doc.command(json!({"op":"page_undo"})).unwrap();
        assert_eq!(saved_text(doc, 0), vec!["SAVED_0"]);
        doc.command(json!({"op":"page_redo"})).unwrap();
        assert_eq!(saved_text(doc, 2), vec!["SAVED_0"]);
        doc.command(json!({"op":"page_stage","operation":{"Delete":{"pages":[0]}}}))
            .unwrap();
        assert_eq!(saved_text(doc, 1), vec!["SAVED_0"]);
        assert_eq!(saved_text(doc, 0), vec!["SAVED_2"]);
        let saved = doc.command(json!({"op":"document_save"})).unwrap();
        assert!(saved["report"]["cache_cleanup_error"].is_null(), "{saved}");
        assert_eq!(doc.active().unwrap().page_count(), 2);
        assert_eq!(saved_text(doc, 1), vec!["SAVED_0"]);
        assert_eq!(
            fs::read(fixture.cache.directory.join(FILE)).unwrap(),
            original
        );
        let reopened = DesktopDocument::open_with_cache_root(
            &fixture.cache.document,
            None,
            Some(&fixture.root.join("cache")),
        )
        .unwrap();
        assert_eq!(saved_text(&reopened, 1), vec!["SAVED_0"]);
        assert_eq!(saved_text(&reopened, 0), vec!["SAVED_2"]);
    }
    #[test]
    fn rotation_invalidates_only_that_revision_and_new_working_answers_survive_redo_and_save_as() {
        let fixture = Fixture::copied("multipage.pdf");
        let original = seed(&fixture);
        let pdf = fs::read(&fixture.cache.document).unwrap();
        let doc = &fixture.document;
        doc.command(
            json!({"op":"page_stage","operation":{"Rotate":{"pages":[0],"quarter_turns":1}}}),
        )
        .unwrap();
        assert!(saved_text(doc, 0).is_empty());
        assert_eq!(saved_text(doc, 1), vec!["SAVED_1"]);
        {
            let mut translations = doc.translations.lock().unwrap();
            let mut entry = translations
                .store
                .cache
                .entries()
                .find(|e| e.page == 1)
                .unwrap()
                .clone();
            entry.translated_text = "SAVED_WORKING_REVISION".into();
            translations.store.put(&fixture.cache, entry).unwrap();
        }
        doc.command(json!({"op":"page_undo"})).unwrap();
        assert_eq!(saved_text(doc, 0), vec!["SAVED_0"]);
        assert_eq!(saved_text(doc, 1), vec!["SAVED_1"]);
        doc.command(json!({"op":"page_redo"})).unwrap();
        assert_eq!(saved_text(doc, 1), vec!["SAVED_WORKING_REVISION"]);
        let destination = fixture.root.join("derived.pdf");
        let copy = doc
            .command(json!({"op":"save_document_copy","destination":destination}))
            .unwrap();
        assert!(copy["cache_cleanup_error"].is_null(), "{copy}");
        let reopened = DesktopDocument::open_with_cache_root(
            &destination,
            None,
            Some(&fixture.root.join("cache")),
        )
        .unwrap();
        assert_eq!(saved_text(&reopened, 1), vec!["SAVED_WORKING_REVISION"]);
        assert!(saved_text(&reopened, 0).is_empty());
        assert_eq!(fs::read(&fixture.cache.document).unwrap(), pdf);
        assert_eq!(
            fs::read(fixture.cache.directory.join(FILE)).unwrap(),
            original
        );
    }
    #[test]
    fn an_unreadable_working_cache_does_not_turn_a_saved_pdf_into_a_failure_or_get_deleted() {
        let fixture = Fixture::copied("multipage.pdf");
        seed(&fixture);
        let doc = &fixture.document;
        doc.command(
            json!({"op":"page_stage","operation":{"Rotate":{"pages":[0],"quarter_turns":1}}}),
        )
        .unwrap();
        let path = doc
            .translations
            .lock()
            .unwrap()
            .store
            .override_path
            .clone()
            .unwrap();
        fs::write(&path, b"foreign revision cache bytes").unwrap();
        let saved = doc.command(json!({"op":"document_save"})).unwrap();
        assert!(
            saved["report"]["cache_cleanup_error"]
                .as_str()
                .unwrap()
                .contains("recovery files were kept")
        );
        assert_eq!(doc.active().unwrap().page_rotations().unwrap()[0], 1);
        assert_eq!(fs::read(&path).unwrap(), b"foreign revision cache bytes");
        doc.translations.lock().unwrap().session_lease = None;
        assert_eq!(fs::read(&path).unwrap(), b"foreign revision cache bytes");
    }

    #[test]
    #[ignore = "subprocess fixture, executed by translation_cache_survives_process_exit_and_recovery"]
    fn translation_cache_crash_fixture() {
        let root = PathBuf::from(
            std::env::var_os("LYRA_READER_TRANSLATION_CRASH_ROOT")
                .expect("parent supplies an isolated scratch directory"),
        );
        let doc = DesktopDocument::open_with_cache_root(
            &root.join("synthetic.pdf"),
            None,
            Some(&root.join("cache")),
        )
        .unwrap();
        doc.command(json!({"op":"page_stage","operation":{"Move":{"pages":[0],"destination":2}}}))
            .unwrap();
        assert_eq!(saved_text(&doc, 2), vec!["SAVED_0"]);
        let location = doc.marks.lock().unwrap().cache_location().unwrap().clone();
        {
            let mut translations = doc.translations.lock().unwrap();
            let mut entry = translations
                .store
                .cache
                .entries()
                .find(|e| e.page == 2)
                .unwrap()
                .clone();
            entry.translated_text = "SURVIVED_PROCESS_EXIT".into();
            translations.store.put(&location, entry).unwrap();
        }
        // Deliberately bypass Rust destructors; OS locks are released by process exit.
        std::process::exit(0);
    }
    #[test]
    fn translation_cache_survives_process_exit_and_recovery() {
        let fixture = Fixture::copied("multipage.pdf");
        let original = seed(&fixture);
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "translation::tests::translation_cache_crash_fixture",
                "--ignored",
                "--nocapture",
            ])
            .env("LYRA_READER_TRANSLATION_CRASH_ROOT", &fixture.root)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let restored = DesktopDocument::open_with_cache_root(
            &fixture.cache.document,
            None,
            Some(&fixture.root.join("cache")),
        )
        .unwrap();
        assert_ne!(
            restored.active().unwrap().path(),
            fixture.cache.document.to_string_lossy()
        );
        assert_eq!(saved_text(&restored, 2), vec!["SURVIVED_PROCESS_EXIT"]);
        assert_eq!(saved_text(&restored, 0), vec!["SAVED_1"]);
        assert_eq!(
            fs::read(fixture.cache.directory.join(FILE)).unwrap(),
            original
        );
        restored.command(json!({"op":"document_discard"})).unwrap();
        assert_eq!(saved_text(&restored, 0), vec!["SAVED_0"]);
    }
    #[test]
    fn revision_cache_garbage_collection_follows_retained_pdf_history() {
        let fixture = Fixture::copied("multipage.pdf");
        seed(&fixture);
        let doc = &fixture.document;
        for _ in 0..38 {
            doc.command(
                json!({"op":"page_stage","operation":{"Move":{"pages":[0],"destination":2}}}),
            )
            .unwrap();
        }
        let translations = doc.translations.lock().unwrap();
        let directory = &translations.session_lease.as_ref().unwrap().path;
        let files = fs::read_dir(directory)
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| {
                p.file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with("lyra-translations-")
                    && p.extension().is_some_and(|s| s == "json")
            })
            .collect::<Vec<_>>();
        assert!(!files.is_empty());
        assert!(
            files.len() <= 33,
            "unreachable revision cache files were retained: {}",
            files.len()
        );
    }

    #[test]
    fn chatgpt_inplace_translation_freezes_each_payload_and_rejects_other_credentials() {
        let f = Fixture::new();
        let mut request = f.request("http://127.0.0.1:1/v1");
        request["chatgpt_account"] = json!("synthetic-translation-account");
        let preview = f
            .document
            .command(json!({"op":"translation_prepare","request":request}))
            .unwrap();
        let plan = &preview["plan"];
        assert_eq!(plan["chatgpt_account"], "synthetic-translation-account");
        assert_eq!(
            plan["endpoint"],
            lyra_reader_ai::openai::CHATGPT_RESPONSES_ENDPOINT
        );
        let parts = plan["parts"].as_array().unwrap();
        assert!(parts.len() > 1);
        for part in parts {
            let wire: Value = serde_json::from_str(part["wire_body"].as_str().unwrap()).unwrap();
            assert_eq!(wire["store"], false);
            assert!(wire["input"].is_array());
        }
        let mut start = json!({"op":"translation_start","token":plan["token"],
            "chatgpt_account":"other-account","api_key":"synthetic-api-key"});
        assert!(
            f.document
                .command(start.clone())
                .unwrap_err()
                .contains("connection changed")
        );
        start["chatgpt_account"] = json!("synthetic-translation-account");
        assert!(
            f.document
                .command(start)
                .unwrap_err()
                .contains("Sign in to ChatGPT")
        );
        let stopped = f
            .document
            .command(json!({"op":"translation_cancel","token":plan["token"]}))
            .unwrap();
        assert_eq!(stopped["running"], false);
        assert!(!f.cache.directory.join(FILE).exists());
    }
    #[test]
    fn translation_preview_and_cancel_admission_do_not_send_or_create_a_cache() {
        let fixture = Fixture::new();
        let request = fixture.request("http://127.0.0.1:9/v1");
        let original = fs::read(&fixture.cache.document).unwrap();
        let preview = fixture
            .document
            .command(json!({"op":"translation_prepare","request":request}))
            .unwrap();
        assert_eq!(preview["plan"]["parts"].as_array().unwrap().len(), 6);
        assert_eq!(preview["translation"]["rows"].as_array().unwrap().len(), 6);
        assert!(!fixture.cache.directory.join(FILE).exists());
        fixture.document.request_translation_cancel();
        assert!(fixture.document.command(json!({"op":"translation_start","token":preview["plan"]["token"],"api_key":"synthetic"})).is_err());
        assert_eq!(fs::read(&fixture.cache.document).unwrap(), original);
    }
    #[test]
    fn obsolete_translation_cleanup_does_not_cancel_a_new_preview() {
        let fixture = Fixture::new();
        let server = Server::new(Duration::from_millis(20), true);
        let request = fixture.request(&server.url);
        let old = fixture
            .document
            .command(json!({"op":"translation_prepare","request":request}))
            .unwrap();
        let next = fixture
            .document
            .command(json!({"op":"translation_prepare","request":request}))
            .unwrap();
        assert_ne!(old["plan"]["token"], next["plan"]["token"]);
        let cleanup = fixture
            .document
            .command(json!({"op":"translation_cancel","token":old["plan"]["token"]}))
            .unwrap();
        assert_eq!(cleanup["obsolete"], true);
        assert!(server.bodies.lock().unwrap().is_empty());
        let token = &next["plan"]["token"];
        fixture
            .document
            .command(json!({"op":"translation_start","token":token,"api_key":"synthetic"}))
            .unwrap();
        let state = wait(&fixture.document, token);
        assert!(
            state["rows"]
                .as_array()
                .unwrap()
                .iter()
                .all(|row| row["state"] == "ready")
        );
        assert_eq!(server.bodies.lock().unwrap().len(), 6);
    }
    #[test]
    fn translation_bodies_match_previews_three_jobs_complete_and_reopen_without_http() {
        let fixture = Fixture::new();
        let server = Server::new(Duration::from_millis(160), true);
        let request = fixture.request(&server.url);
        let preview = fixture
            .document
            .command(json!({"op":"translation_prepare","request":request}))
            .unwrap();
        assert!(server.bodies.lock().unwrap().is_empty());
        let token = &preview["plan"]["token"];
        fixture
            .document
            .command(json!({"op":"translation_start","token":token,"api_key":"synthetic"}))
            .unwrap();
        let state = wait(&fixture.document, token);
        assert!(
            state["rows"]
                .as_array()
                .unwrap()
                .iter()
                .all(|r| r["state"] == "ready" && r["cached"] == true),
            "{state}"
        );
        assert_eq!(server.peak.load(Ordering::SeqCst), 3);
        let actual = server.bodies.lock().unwrap().clone();
        assert_eq!(actual.len(), 6);
        for part in preview["plan"]["parts"].as_array().unwrap() {
            let expected = part["wire_body"].as_str().unwrap().as_bytes();
            assert!(actual.iter().any(|body| body == expected));
        }
        let cache = Cache::decode(&fs::read(fixture.cache.directory.join(FILE)).unwrap()).unwrap();
        assert_eq!(cache.entries().count(), 6);
        let reopened = DesktopDocument::open_with_cache_root(
            &fixture.cache.document,
            None,
            Some(&fixture.root.join("cache")),
        )
        .unwrap();
        let inspect = reopened
            .command(json!({"op":"translation_inspect","page":0}))
            .unwrap();
        assert_eq!(inspect["entries"].as_array().unwrap().len(), 6);
        let hit = reopened
            .command(json!({"op":"translation_prepare","request":fixture.request(&server.url)}))
            .unwrap();
        assert!(hit["plan"].is_null());
        assert_eq!(server.bodies.lock().unwrap().len(), 6);
        let audit = fs::read_to_string(fixture.cache.root.join("Audit/ai-requests.jsonl")).unwrap();
        assert_eq!(audit.lines().count(), 6);
        assert!(!audit.contains("Synthetic paragraph"));
    }
    #[test]
    fn cancellation_drains_active_jobs_without_starting_queued_or_caching_partial_answers() {
        let fixture = Fixture::new();
        let server = Server::new(Duration::from_secs(2), true);
        let preview = fixture
            .document
            .command(json!({"op":"translation_prepare","request":fixture.request(&server.url)}))
            .unwrap();
        let token = &preview["plan"]["token"];
        fixture
            .document
            .command(json!({"op":"translation_start","token":token,"api_key":"synthetic"}))
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        while server.bodies.lock().unwrap().len() < 3 {
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(5));
        }
        fixture.document.request_translation_cancel();
        let state = wait(&fixture.document, token);
        assert!(
            state["rows"]
                .as_array()
                .unwrap()
                .iter()
                .all(|r| r["state"] == "cancelled")
        );
        assert_eq!(server.bodies.lock().unwrap().len(), 3);
        assert!(!fixture.cache.directory.join(FILE).exists());
    }
    #[test]
    fn cache_external_changes_corruption_and_writer_lease_preserve_original_data() {
        let fixture = Fixture::new();
        fixture.document.command(json!({"op":"translation_prepare","request":fixture.request("http://127.0.0.1:9/v1")})).unwrap();
        let mut store = fixture.document.translations.lock().unwrap();
        let mut entry = store.rows[0].entry.clone();
        entry.translated_text = "complete".into();
        let lock = crate::document_cache::lock_translation_cache(&fixture.cache.directory).unwrap();
        assert!(store.store.put(&fixture.cache, entry.clone()).is_err());
        assert!(!fixture.cache.directory.join(FILE).exists());
        fs2::FileExt::unlock(&lock).unwrap();
        store.store.put(&fixture.cache, entry.clone()).unwrap();
        let bytes = fs::read(fixture.cache.directory.join(FILE)).unwrap();
        fs::write(fixture.cache.directory.join(FILE), b"foreign bytes").unwrap();
        assert!(store.store.put(&fixture.cache, entry).is_err());
        assert_eq!(
            fs::read(fixture.cache.directory.join(FILE)).unwrap(),
            b"foreign bytes"
        );
        assert!(!bytes.is_empty());
        drop(store);
        let reopened = DesktopDocument::open_with_cache_root(
            &fixture.cache.document,
            None,
            Some(&fixture.root.join("cache")),
        )
        .unwrap();
        let inspection = reopened
            .command(json!({"op":"translation_inspect","page":0}))
            .unwrap();
        assert!(inspection["cache_warning"].is_string());
        assert!(inspection["entries"].as_array().unwrap().is_empty());
        assert_eq!(
            fs::read(fixture.cache.directory.join(FILE)).unwrap(),
            b"foreign bytes"
        );
    }
}
