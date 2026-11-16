//! Bounded native batch ownership over the shared summary planner and audited transport.
//! The UI owns displayed text; this adapter retains canonical unsent plans and live handles.
use crate::summary::{Units, prepare_layer, unit_span};
use lyra_reader_ffi::api::*;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    path::PathBuf,
    sync::{
        Arc, Weak,
        atomic::{AtomicU64, Ordering},
    },
};

static NEXT_SCOPE: AtomicU64 = AtomicU64::new(1);
#[derive(Default)]
pub(crate) struct Scope {
    latest: AtomicU64,
    cancelled_through: AtomicU64,
}
impl Scope {
    fn begin(&self) -> Result<u64, String> {
        // Keep the workspace MSRV; the newer atomic try_update API is not required.
        let mut current = NEXT_SCOPE.load(Ordering::SeqCst);
        let id = loop {
            let next = current
                .checked_add(1)
                .ok_or("Summary request identities are exhausted. Restart the application.")?;
            match NEXT_SCOPE.compare_exchange(current, next, Ordering::SeqCst, Ordering::SeqCst) {
                Ok(_) => break current,
                Err(observed) => current = observed,
            }
        };
        self.latest.store(id, Ordering::SeqCst);
        Ok(id)
    }
    pub(crate) fn cancel(&self) {
        self.cancelled_through
            .fetch_max(self.latest.load(Ordering::SeqCst), Ordering::SeqCst);
    }
    fn cancelled(&self, id: u64) -> bool {
        id <= self.cancelled_through.load(Ordering::SeqCst)
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PrepareRequest {
    layer: AiSummaryLayerRecord,
    #[serde(default)]
    offset: u32,
    #[serde(default)]
    index: Option<u32>,
}

#[derive(Clone, Copy, PartialEq, Serialize)]
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
struct Provenance {
    action: AiActionRecord,
    source_pages: Vec<u32>,
    sources: Vec<AiSourceRecord>,
}

#[derive(Clone, Serialize)]
struct RowView {
    id: String,
    layer: AiSummaryLayerRecord,
    index: u32,
    title: String,
    page_span: String,
    note: Option<String>,
    link_page: Option<u32>,
    state: State,
    error: Option<String>,
    requested: bool,
    requestable: bool,
    unit_language: String,
    model: String,
    response_plan: Option<Provenance>,
}

struct Row {
    view: RowView,
    plan: Option<AiPlanRecord>,
    fingerprint: Option<[u8; 32]>,
    job: Option<Arc<LyraReaderAiRequest>>,
    done_received: bool,
}

struct Prepared {
    scope: u64,
    token: String,
    source: Weak<LyraReaderDocument>,
    rows: Vec<Row>,
    append: bool,
    concurrency: usize,
}

#[derive(Serialize)]
struct Delivery {
    id: String,
    events: Vec<AiEventRecord>,
}

pub(crate) struct Batch {
    scope: Arc<Scope>,
    active_scope: u64,
    prepared: Option<Prepared>,
    source: Weak<LyraReaderDocument>,
    rows: Vec<Row>,
    token: String,
    // Present only between explicit Send and completion/cancellation. Never serialized.
    key: Option<String>,
    audit_root: Option<PathBuf>,
    concurrency: usize,
    running: bool,
}

impl Drop for Batch {
    fn drop(&mut self) {
        for row in &self.rows {
            if let Some(job) = &row.job {
                job.cancel();
            }
        }
    }
}

impl Batch {
    pub(crate) fn new(scope: Arc<Scope>) -> Self {
        Self {
            scope,
            active_scope: 0,
            prepared: None,
            source: Weak::new(),
            rows: Vec::new(),
            token: String::new(),
            key: None,
            audit_root: None,
            concurrency: 0,
            running: false,
        }
    }
    pub(crate) fn is_running(&self) -> bool {
        self.running
    }

    pub(crate) fn prepare(
        &mut self,
        document: &Arc<LyraReaderDocument>,
        request: PrepareRequest,
        settings: AiPlanRequestRecord,
    ) -> Result<Value, String> {
        if self.running {
            return Err("Stop the current summary batch before preparing another.".into());
        }
        self.prepared = None;
        let scope = self.scope.begin()?;
        let units = Units::new(document, request.layer)?;
        let total = units.len()?;
        if request.offset >= total {
            return Err("This summary batch is outside the layer.".into());
        }
        let limits = ai_summary_limits();
        if limits.max_requests_per_batch == 0 || limits.max_concurrent_requests == 0 {
            return Err("The summary bounds are unavailable.".into());
        }
        let mut descriptors = Vec::new();
        let append = request.index.is_some();
        if let Some(index) = request.index {
            let row = units.row(index)?;
            if !self.source.ptr_eq(&Arc::downgrade(document))
                || !self.rows.iter().any(|old| old.view.id == row.id)
            {
                return Err("This summary result is no longer in the current batch. Preview the layer again.".into());
            }
            descriptors.push(row);
        } else {
            let count = limits.max_requests_per_batch.min(total - request.offset);
            for index in request.offset
                ..request
                    .offset
                    .checked_add(count)
                    .ok_or("The summary range overflowed.")?
            {
                descriptors.push(units.row(index)?);
            }
        }
        let language = match &settings.language {
            Some(language) => language.trim().to_owned(),
            None => String::new(),
        };
        let model = settings.model.clone();
        let mut result = prepare_layer(
            document,
            request.layer,
            descriptors.iter().map(|row| row.unit.clone()).collect(),
            settings,
        )?;
        if result.units.len() != descriptors.len() {
            return Err("The summary planner returned an unexpected unit count.".into());
        }
        if self.scope.cancelled(scope) {
            return Err("Summary preparation was cancelled.".into());
        }
        let concurrency = usize::try_from(result.max_concurrent_requests)
            .map_err(|_| "Invalid summary concurrency.")?;
        if concurrency == 0
            || result.max_requests_per_batch != limits.max_requests_per_batch
            || result.max_concurrent_requests != limits.max_concurrent_requests
        {
            return Err("The summary planner returned inconsistent bounds.".into());
        }
        let source_matches = self.source.ptr_eq(&Arc::downgrade(document));
        let mut rows = Vec::new();
        let mut first_plan = None;
        let mut parts = Vec::new();
        let mut estimated_tokens = 0u64;
        let mut preview_rows = Vec::new();
        let mut source_pages = BTreeSet::new();
        let mut sources = Vec::new();
        for (descriptor, unit) in descriptors.into_iter().zip(result.units.drain(..)) {
            if unit.index != descriptor.unit.index || unit.kind != request.layer {
                return Err("The summary planner returned another unit.".into());
            }
            let span = unit_span(&unit, units.page_count);
            let plan = unit
                .plan
                .map(|plan| render_ai_plan(plan, AiWireTransport::ChatCompletions))
                .transpose()
                .map_err(|error| error.to_string())?;
            if plan.as_ref().is_some_and(|plan| plan.parts.len() != 1) {
                return Err("Each summary row must contain exactly one request.".into());
            }
            let fingerprint = match &plan {
                Some(plan) => Some(
                    Sha256::digest(serde_json::to_vec(plan).map_err(|error| error.to_string())?)
                        .into(),
                ),
                None => None,
            };
            let ready = !append
                && source_matches
                && self.rows.iter().any(|old| {
                    old.view.id == descriptor.id
                        && old.view.state == State::Ready
                        && old.fingerprint == fingerprint
                });
            let requested = plan.is_some() && !ready;
            let state = if ready {
                State::Ready
            } else if plan.is_some() {
                State::Prepared
            } else {
                State::Failed
            };
            let provenance = plan.as_ref().map(|plan| Provenance {
                action: plan.action,
                source_pages: plan.source_pages.clone(),
                sources: plan.sources.clone(),
            });
            let view = RowView {
                id: descriptor.id,
                layer: request.layer,
                index: unit.index,
                title: unit.title,
                page_span: span,
                note: unit.note,
                link_page: descriptor.link_page,
                state,
                error: unit.error,
                requested,
                requestable: plan.is_some(),
                unit_language: language.clone(),
                model: model.clone(),
                response_plan: provenance,
            };
            if let Some(plan) = plan.as_ref().filter(|_| requested) {
                if first_plan.is_none() {
                    first_plan = Some(plan.clone());
                }
                estimated_tokens = estimated_tokens
                    .checked_add(plan.estimated_tokens)
                    .ok_or("The summary token estimate overflowed.")?;
                preview_rows.push(json!({"id":view.id,"title":view.title,"page_span":view.page_span,"part_index":parts.len()}));
                parts.extend(plan.parts.clone());
                source_pages.extend(plan.source_pages.iter().copied());
                sources.extend(plan.sources.clone());
            }
            rows.push(Row {
                view,
                plan: if requested { plan } else { None },
                fingerprint,
                job: None,
                done_received: false,
            });
        }
        let mut bytes = [0u8; 16];
        getrandom::fill(&mut bytes)
            .map_err(|error| format!("Could not create a summary request identity: {error}"))?;
        let token = bytes
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        let envelope = if let Some(mut plan) = first_plan {
            plan.parts = parts;
            plan.estimated_tokens = estimated_tokens;
            plan.source_pages = source_pages.into_iter().collect();
            plan.sources = sources;
            plan.note = Some(result.note.clone());
            let mut value = serde_json::to_value(plan).map_err(|error| error.to_string())?;
            let object = value.as_object_mut().ok_or("Invalid summary preview.")?;
            object.insert("kind".into(), json!("summary_batch"));
            object.insert("token".into(), json!(token));
            object.insert("summary_rows".into(), json!(preview_rows));
            object.insert("append".into(), json!(append));
            Some(value)
        } else {
            None
        };
        let output = json!({"plan":envelope,"rows":rows.iter().map(|row| &row.view).collect::<Vec<_>>(),"limits":limits,"layer":request.layer,"offset":request.offset,"total":total,"note":result.note,"append":append});
        if envelope.is_some() {
            self.prepared = Some(Prepared {
                scope,
                token,
                source: Arc::downgrade(document),
                rows,
                append,
                concurrency,
            });
        }
        Ok(output)
    }

    pub(crate) fn start(
        &mut self,
        document: &Arc<LyraReaderDocument>,
        token: &str,
        key: String,
        audit_root: PathBuf,
    ) -> Result<Value, String> {
        if self.running {
            return Err("This summary batch is already running.".into());
        }
        let prepared = self
            .prepared
            .as_ref()
            .ok_or("Preview the summary batch before sending.")?;
        if prepared.token != token {
            return Err("The summary preview changed. Preview it again before sending.".into());
        }
        if self.scope.cancelled(prepared.scope) {
            self.prepared = None;
            return Err(
                "The summary preview was cancelled. Preview it again before sending.".into(),
            );
        }
        if !prepared.source.ptr_eq(&Arc::downgrade(document)) {
            self.prepared = None;
            return Err("The document changed. Preview the summary batch again.".into());
        }
        let prepared = self
            .prepared
            .take()
            .ok_or("The summary preview is unavailable.")?;
        if prepared.append {
            for row in &mut self.rows {
                row.view.requested = false;
            }
            for row in prepared.rows {
                let old = self
                    .rows
                    .iter_mut()
                    .find(|old| old.view.id == row.view.id)
                    .ok_or("The summary retry row disappeared.")?;
                *old = row;
            }
        } else {
            self.rows = prepared.rows;
        }
        for row in &mut self.rows {
            if row.view.requested {
                row.view.state = State::Queued;
            }
        }
        self.source = prepared.source;
        self.active_scope = prepared.scope;
        self.token = token.to_owned();
        self.concurrency = prepared.concurrency;
        self.key = Some(key);
        self.audit_root = Some(audit_root);
        self.running = true;
        self.schedule()?;
        self.snapshot(Vec::new())
    }

    fn schedule(&mut self) -> Result<(), String> {
        while self.rows.iter().filter(|row| row.job.is_some()).count() < self.concurrency {
            if self.scope.cancelled(self.active_scope) {
                // Keep live handles until cancellation drains their final events. A completed
                // row must survive a cancel racing with the last transport event.
                for row in &mut self.rows {
                    if row.view.state == State::Queued {
                        row.view.state = State::Cancelled;
                        row.plan = None;
                    }
                }
                self.key = None;
                self.audit_root = None;
                break;
            }
            let Some(row) = self
                .rows
                .iter_mut()
                .find(|row| row.view.state == State::Queued)
            else {
                break;
            };
            let Some(plan) = row.plan.take() else {
                row.view.state = State::Failed;
                row.view.error = Some("The prepared row is unavailable. Preview it again.".into());
                continue;
            };
            let key = self
                .key
                .as_ref()
                .ok_or("The summary request credentials are unavailable.")?;
            let root = self
                .audit_root
                .as_ref()
                .ok_or("The summary audit directory is unavailable.")?;
            let observer = crate::audit::observer(root.clone(), plan.action, plan.is_local);
            match start_ai_request_audited(plan, key.clone(), false, Some(observer)) {
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
            .any(|row| row.job.is_some() || row.view.state == State::Queued);
        if !self.running {
            self.key = None;
            self.audit_root = None;
        }
        Ok(())
    }

    fn drain(row: &mut Row) -> Vec<AiEventRecord> {
        let Some(job) = &row.job else {
            return Vec::new();
        };
        // Observe completion before draining: a finished worker has already queued its last event.
        let finished = job.is_finished();
        let events = job.poll();
        for event in &events {
            match event {
                AiEventRecord::Done => row.done_received = true,
                AiEventRecord::Error {
                    message, cancelled, ..
                } => {
                    row.view.state = if *cancelled {
                        State::Cancelled
                    } else {
                        State::Failed
                    };
                    row.view.error = Some(message.clone());
                }
                _ => {}
            }
        }
        if finished {
            if row.view.state == State::Sending {
                row.view.state = if row.done_received {
                    State::Ready
                } else {
                    State::Failed
                };
                if !row.done_received {
                    row.view.error = Some("The response ended without a completion event.".into());
                }
            }
            row.job = None;
        }
        events
    }

    pub(crate) fn poll(
        &mut self,
        document: &Arc<LyraReaderDocument>,
        token: &str,
    ) -> Result<Value, String> {
        if self.token.is_empty() || self.token != token {
            return Err("This summary batch is no longer active.".into());
        }
        if !self.source.ptr_eq(&Arc::downgrade(document)) || self.scope.cancelled(self.active_scope)
        {
            return self.cancel(token);
        }
        let mut deliveries = Vec::new();
        for row in &mut self.rows {
            let events = Self::drain(row);
            if !events.is_empty() {
                deliveries.push(Delivery {
                    id: row.view.id.clone(),
                    events,
                });
            }
        }
        if self.running {
            self.schedule()?;
        }
        self.snapshot(deliveries)
    }

    pub(crate) fn cancel(&mut self, token: &str) -> Result<Value, String> {
        if self
            .prepared
            .as_ref()
            .is_some_and(|prepared| prepared.token == token)
        {
            self.prepared = None;
        }
        if self.token != token {
            return Ok(json!({"cancelled":false}));
        }
        let mut deliveries = Vec::new();
        for row in &mut self.rows {
            let events = Self::drain(row);
            if !events.is_empty() {
                deliveries.push(Delivery {
                    id: row.view.id.clone(),
                    events,
                });
            }
        }
        self.stop_jobs();
        self.snapshot(deliveries)
    }

    fn stop_jobs(&mut self) {
        for row in &mut self.rows {
            if let Some(job) = row.job.take() {
                job.cancel();
            }
            if row.view.state == State::Sending && row.done_received {
                row.view.state = State::Ready;
            } else if row.view.state == State::Sending || row.view.state == State::Queued {
                row.view.state = State::Cancelled;
            }
            row.plan = None;
        }
        self.key = None;
        self.audit_root = None;
        self.running = false;
    }

    fn snapshot(&self, deliveries: Vec<Delivery>) -> Result<Value, String> {
        let total = self.rows.iter().filter(|row| row.view.requested).count();
        let finished = self
            .rows
            .iter()
            .filter(|row| {
                row.view.requested
                    && matches!(
                        row.view.state,
                        State::Ready | State::Failed | State::Cancelled
                    )
            })
            .count();
        let count = |state| {
            self.rows
                .iter()
                .filter(|row| row.view.requested && row.view.state == state)
                .count()
        };
        let ready = count(State::Ready);
        let failed = count(State::Failed);
        let cancelled = count(State::Cancelled);
        let rejected = self.rows.iter().filter(|row| !row.view.requestable).count();
        let phase = if self.running {
            "running"
        } else if cancelled > 0 {
            "cancelled"
        } else if failed > 0 || rejected > 0 {
            if ready > 0 { "partial" } else { "failed" }
        } else {
            "finished"
        };
        Ok(
            json!({"token":self.token,"rows":self.rows.iter().map(|row| &row.view).collect::<Vec<_>>(),"deliveries":deliveries,"running":self.running,"total":total,"finished":finished,"active":self.rows.iter().filter(|row| row.job.is_some()).count(),"ready":ready,"failed":failed,"cancelled":cancelled,"rejected":rejected,"phase":phase}),
        )
    }
}
