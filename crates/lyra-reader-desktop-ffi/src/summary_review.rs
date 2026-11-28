//! Native ownership of an explicitly requested whole-document Summary review.
use crate::{analysis_cache::AnalysisRun, document::DesktopDocument};
use lyra_reader_ffi::api::{AiActionRecord, AiPlanRecord, AiReadingOptionsRecord};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

pub(super) struct SummaryReview {
    pub(super) owner: String,
    source: String,
    plan: Option<[u8; 32]>,
    pub(super) run: Option<AnalysisRun>,
    pub(super) started: bool,
}

fn plan_key(value: &Value) -> Result<[u8; 32], String> {
    let plan: AiPlanRecord = serde_json::from_value(value.clone()).map_err(|e| e.to_string())?;
    if plan.action != AiActionRecord::SummarizeDocument
        || !matches!(
            value["kind"].as_str(),
            Some("reading_summary" | "summary_synthesis")
        )
    {
        return Err("This preview is not an owned document summary.".into());
    }
    // Typed plan serialization normalizes native/Qt numeric representations.
    // These additional fields affect capture/routing but never the wire body.
    let key = json!({"plan":plan,"kind":value["kind"],"style":value["reading_style"],
        "capture":value["summary_capture"],"account":value["chatgpt_account"]});
    Ok(Sha256::digest(serde_json::to_vec(&key).map_err(|e| e.to_string())?).into())
}

impl SummaryReview {
    pub(super) fn owner(&self, value: &Value, source: &str) -> Result<bool, String> {
        Ok(
            value["summary_review"].as_str() == Some(self.owner.as_str())
                && self.source == source
                && self.plan == Some(plan_key(value)?),
        )
    }

    pub(super) fn update_plan(&mut self, plan: &mut Value) -> Result<(), String> {
        self.plan = Some(plan_key(plan)?);
        plan["summary_review"] = json!(self.owner);
        Ok(())
    }
}

impl DesktopDocument {
    pub(super) fn prepare_summary_review(&self, mut request: Value) -> Result<Value, String> {
        let owner = request["owner"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 64)
            .ok_or("Invalid document summary review identity.")?
            .to_owned();
        let input = crate::region::request(request["request"].clone())?;
        let options: AiReadingOptionsRecord =
            serde_json::from_value(request["reading"].clone()).map_err(|e| e.to_string())?;
        if input.action != AiActionRecord::SummarizeDocument
            || input.selection.is_some()
            || options.kind != "summary"
        {
            return Err("Only a whole-document summary can own this analysis.".into());
        }
        let source = self.active()?;
        let hash = source.document_identity().sha256;
        {
            let mut state = self
                .knowledge
                .lock()
                .map_err(|_| "Document reading state is unavailable")?;
            state.ensure_foreground_ready()?;
            state.begin_summary_review(SummaryReview {
                owner: owner.clone(),
                source: hash,
                plan: None,
                run: None,
                started: false,
            });
        }
        // Publish preparing before fingerprint/cache/plan work; the mutex remains
        // available for cancellation and fast, nonblocking foreground admission.
        let prepared = (|| {
            // A matching local result needs no analysis lock or provider. The
            // normal builder below still reports protected-cache read failures.
            if request["reading"]["force"].as_bool() != Some(true)
                && let Ok(Some(cached)) = self.cached_document_summary(
                    &source,
                    input.language.as_deref().unwrap_or(""),
                    &options.detail,
                )
            {
                let mut state = self
                    .knowledge
                    .lock()
                    .map_err(|_| "Document reading state is unavailable")?;
                if !state
                    .summary_review
                    .as_ref()
                    .is_some_and(|review| review.owner == owner)
                {
                    return Err("The document summary review was cancelled.".into());
                }
                state.finish_summary_review(&owner);
                return Ok(
                    json!({"plan":{"saved_summary":cached},"understanding":state.summary_status()?}),
                );
            }
            let run = self.with_reading_cache(&source, true, |cache, fingerprint| {
                AnalysisRun::begin(
                    cache,
                    fingerprint,
                    input.language.as_deref().unwrap_or("").to_owned(),
                    options.detail.clone(),
                )
            })?;
            {
                let mut state = self
                    .knowledge
                    .lock()
                    .map_err(|_| "Document reading state is unavailable")?;
                let review = state
                    .summary_review
                    .as_mut()
                    .filter(|review| review.owner == owner)
                    .ok_or("The document summary review was cancelled.")?;
                review.run = Some(run);
            }
            request["op"] = json!("ai_preview");
            let mut plan = self.command_inner(request, true)?;
            let mut state = self
                .knowledge
                .lock()
                .map_err(|_| "Document reading state is unavailable")?;
            let Some(review) = state.summary_review.as_mut().filter(|r| r.owner == owner) else {
                return Err("The document summary review was cancelled.".into());
            };
            if plan.get("saved_summary").is_some() {
                state.finish_summary_review(&owner);
            } else {
                review.update_plan(&mut plan)?;
            }
            Ok(json!({"plan":plan,"understanding":state.summary_status()?}))
        })();
        if prepared.is_err() {
            self.knowledge
                .lock()
                .map_err(|_| "Document reading state is unavailable")?
                .finish_summary_review(&owner);
        }
        prepared
    }

    pub(super) fn cancel_summary_review(&self, owner: &str) -> Result<Value, String> {
        let mut state = self
            .knowledge
            .lock()
            .map_err(|_| "Document reading state is unavailable")?;
        if state
            .summary_review
            .as_ref()
            .is_some_and(|r| r.owner == owner && !r.started)
        {
            state.finish_summary_review(owner);
            *self
                .pending_summary
                .lock()
                .map_err(|_| "Summary source state is unavailable")? = None;
        }
        state.summary_status()
    }

    pub(super) fn owned_summary_start(&self, plan: &Value) -> Result<bool, String> {
        if plan.get("summary_review").is_none() {
            return Ok(false);
        }
        let state = self
            .knowledge
            .lock()
            .map_err(|_| "Document reading state is unavailable")?;
        if let Some(review) = &state.summary_review
            && review.owner(plan, &self.active()?.document_identity().sha256)?
            && (!review.started || plan["kind"] == "summary_synthesis")
        {
            Ok(true)
        } else {
            Err("The document summary review changed. Prepare it again before sending.".into())
        }
    }

    pub(super) fn take_summary_run(&self, plan: &Value) -> Result<AnalysisRun, String> {
        let source = self.active()?;
        // Retaining the preview's lease does not replace the final disk/source
        // validation performed by the ordinary Summary capture at send time.
        self.with_reading_cache(&source, true, |_, _| Ok(()))?;
        let mut state = self
            .knowledge
            .lock()
            .map_err(|_| "Document reading state is unavailable")?;
        let review = state
            .summary_review
            .as_mut()
            .ok_or("The document summary no longer owns its analysis.")?;
        if !review.owner(plan, &self.active()?.document_identity().sha256)? {
            return Err("The document summary preview changed.".into());
        }
        let run = review
            .run
            .take()
            .ok_or("The document analysis is already sending.")?;
        review.started = true;
        state.summary_reading();
        Ok(run)
    }

    pub(super) fn finish_summary_owner(&self, owner: Option<&str>) -> Result<Value, String> {
        let mut state = self
            .knowledge
            .lock()
            .map_err(|_| "Document reading state is unavailable")?;
        if let Some(owner) = owner {
            state.finish_summary_review(owner);
        }
        state.summary_status()
    }
}
