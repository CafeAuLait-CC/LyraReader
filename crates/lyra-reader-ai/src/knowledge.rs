//! Portable completed-reading format and bounded multipart answer accounting.
use crate::chat::{ChatTransport, MergePart, MergePlanRequest, build_merge_plan};
use crate::{AiError, CancellationToken, ChatPlan, ChatSettings, RunEvent};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

pub const MAX_READING_BYTES: usize = 8 * 1024 * 1024;

/// Matches the native document-knowledge-v1.json record. `read_at` uses Foundation's
/// seconds since 2001, rather than Unix seconds. Hosts must retain the original bytes
/// when a reading contains fields they do not own.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentReading {
    pub version: u32,
    pub source_hash: String,
    pub summary: String,
    pub pages: Vec<u32>,
    pub model: String,
    pub read_at: f64,
    #[serde(flatten)]
    pub unknown: BTreeMap<String, Value>,
}

impl DocumentReading {
    pub fn decode(bytes: &[u8], page_count: u32) -> Result<Self, String> {
        if bytes.len() > MAX_READING_BYTES {
            return Err("The saved document reading exceeds its 8 MiB limit; it was kept".into());
        }
        let record: Self = serde_json::from_slice(bytes).map_err(|e| {
            format!("The saved document reading could not be read; it was kept: {e}")
        })?;
        record.validate(page_count)?;
        Ok(record)
    }

    pub fn validate(&self, page_count: u32) -> Result<(), String> {
        if self.version != 1 {
            return Err(
                "The saved document reading has an unsupported version; it was kept".into(),
            );
        }
        if self.source_hash.len() != 64
            || !self.source_hash.bytes().all(|c| c.is_ascii_hexdigit())
            || self.summary.trim().is_empty()
            || self.summary.len() > MAX_READING_BYTES
            || self.model.trim().is_empty()
            || !self.read_at.is_finite()
            || self.pages.is_empty()
            || self.pages.len() > page_count as usize
            || self.pages.iter().any(|p| *p == 0 || *p > page_count)
            || self.pages.windows(2).any(|p| p[0] >= p[1])
        {
            return Err("The saved document reading is incomplete or invalid; it was kept".into());
        }
        Ok(())
    }

    pub fn encode(&self, page_count: u32) -> Result<Vec<u8>, String> {
        self.validate(page_count)?;
        // JSON escaping can expand source text sixfold. Bound every write before growing
        // the output buffer, rather than serialising an oversized record and checking later.
        struct Bounded(Vec<u8>);
        impl std::io::Write for Bounded {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                if self
                    .0
                    .len()
                    .checked_add(bytes.len())
                    .is_none_or(|n| n > MAX_READING_BYTES)
                {
                    return Err(std::io::Error::other(
                        "The completed document reading exceeds its 8 MiB cache limit",
                    ));
                }
                self.0.extend_from_slice(bytes);
                Ok(bytes.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let mut output = Bounded(Vec::new());
        serde_json::to_writer(&mut output, self).map_err(|e| e.to_string())?;
        Ok(output.0)
    }
}

/// A reading is reusable only after every part has a nonempty answer and the
/// transport reports completion. Partial, cancelled and token-limited work is not knowledge.
#[derive(Default)]
pub struct ReadingAnswers {
    answers: Vec<String>,
    current: Option<usize>,
    bytes: usize,
    done: bool,
    failed: bool,
}

impl ReadingAnswers {
    pub fn new(parts: usize) -> Result<Self, String> {
        if !(1..=4096).contains(&parts) {
            return Err("The document reading has an invalid request count".into());
        }
        Ok(Self {
            answers: vec![String::new(); parts],
            ..Self::default()
        })
    }

    pub fn begin(&mut self, index: u32) -> Result<(), String> {
        let index = usize::try_from(index).map_err(|e| e.to_string())?;
        if self.done
            || index >= self.answers.len()
            || self.current.is_some_and(|previous| index != previous + 1)
            || (self.current.is_none() && index != 0)
        {
            self.failed = true;
            return Err("The document reading returned requests out of order".into());
        }
        self.current = Some(index);
        Ok(())
    }

    pub fn append(&mut self, text: &str, reasoning: bool) -> Result<(), String> {
        if self.done {
            self.failed = true;
            return Err("The document reading returned text after completion".into());
        }
        let Some(index) = self.current else {
            self.failed = true;
            return Err("The document reading returned text before a request".into());
        };
        let next = self
            .bytes
            .checked_add(text.len())
            .filter(|n| *n <= MAX_READING_BYTES);
        let Some(next) = next else {
            self.failed = true;
            return Err("Document reading exceeded its 8 MiB answer budget".into());
        };
        self.bytes = next;
        if !reasoning {
            self.answers[index].push_str(text);
        }
        Ok(())
    }

    pub fn complete(&mut self) {
        self.done = true;
    }
    pub fn fail(&mut self) {
        self.failed = true;
    }
    pub fn completed_parts(&self) -> usize {
        self.answers
            .iter()
            .enumerate()
            .filter(|(i, s)| !s.trim().is_empty() && (self.done || Some(*i) != self.current))
            .count()
    }
    pub fn finish(&self) -> Result<&[String], String> {
        if !self.done
            || self.failed
            || self.answers.is_empty()
            || self.answers.iter().any(|s| s.trim().is_empty())
        {
            return Err(
                "The document reading did not finish every request; no reading was saved".into(),
            );
        }
        Ok(&self.answers)
    }
}

pub enum ReadingUpdate {
    Parts {
        completed: usize,
        total: usize,
    },
    /// Materialised before the consolidation is sent. The background-reading consent
    /// covers this disclosed extra step, and the viewer can inspect its exact bodies.
    Combining {
        payloads: Vec<String>,
    },
}

fn collect(
    plan: &ChatPlan,
    cancel: &CancellationToken,
    run: &mut impl FnMut(&ChatPlan, &mut dyn FnMut(RunEvent)) -> Result<(), AiError>,
    progress: &mut dyn FnMut(ReadingUpdate),
) -> Result<Vec<String>, AiError> {
    let mut answers = ReadingAnswers::new(plan.parts.len()).map_err(AiError::Protocol)?;
    let mut failure = None;
    let outcome = run(plan, &mut |event| {
        let result = match event {
            RunEvent::PartStarted { index, .. } => answers.begin(index),
            RunEvent::Delta(text) => answers.append(&text, false),
            RunEvent::ReasoningDelta(text) => answers.append(&text, true),
            RunEvent::Done => {
                answers.complete();
                Ok(())
            }
            RunEvent::Diagnostics(diagnostics)
                if diagnostics.finish_reason.as_deref() == Some("length") =>
            {
                answers.fail();
                Err(
                    "Document reading reached the provider's token limit; no reading was saved"
                        .into(),
                )
            }
            _ => Ok(()),
        };
        if failure.is_none() {
            failure = result.err();
        }
        if failure.is_some() {
            cancel.cancel();
        }
        progress(ReadingUpdate::Parts {
            completed: answers.completed_parts(),
            total: plan.parts.len(),
        });
    });
    if let Some(error) = failure {
        return Err(AiError::Protocol(error));
    }
    outcome?;
    Ok(answers.finish().map_err(AiError::Protocol)?.to_vec())
}

/// Execute the consented, optional reading independently of foreground questions. A runner
/// owns transport, auditing, cancellation and the in-memory credential; this policy owns
/// multipart completeness and consolidation. Nothing partial is returned as reusable context.
pub fn run_document_reading(
    plan: &ChatPlan,
    settings: ChatSettings,
    transport: ChatTransport,
    cancel: &CancellationToken,
    mut run: impl FnMut(&ChatPlan, &mut dyn FnMut(RunEvent)) -> Result<(), AiError>,
    progress: &mut dyn FnMut(ReadingUpdate),
) -> Result<String, AiError> {
    let answers = collect(plan, cancel, &mut run, progress)?;
    if answers.len() == 1 {
        return Ok(answers[0].clone());
    }
    let parts = plan
        .parts
        .iter()
        .zip(answers)
        .map(|(part, summary)| {
            Ok(MergePart {
                index: part
                    .index
                    .checked_add(1)
                    .ok_or_else(|| AiError::Protocol("Reading part index overflow".into()))?,
                total: part.total,
                pages: part.pages.clone(),
                summary,
            })
        })
        .collect::<Result<Vec<_>, AiError>>()?;
    let merge = build_merge_plan(MergePlanRequest {
        document_title: plan.document_title.clone(),
        settings,
        parts,
        document_knowledge: None,
    })?
    .rendered(transport);
    let payloads = merge
        .parts
        .iter()
        .map(|part| {
            part.wire_body
                .clone()
                .ok_or_else(|| AiError::Protocol("The consolidation preview is missing".into()))
        })
        .collect::<Result<Vec<_>, _>>()?;
    progress(ReadingUpdate::Combining { payloads });
    cancel.check()?;
    let merged = collect(&merge, cancel, &mut run, &mut |_| {})?;
    merged
        .into_iter()
        .next()
        .ok_or_else(|| AiError::Protocol("The consolidation returned no answer".into()))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn record() -> DocumentReading {
        DocumentReading {
            version: 1,
            source_hash: "ab".repeat(32),
            summary: "Synthetic understanding [p.1]".into(),
            pages: vec![1, 2],
            model: "mock".into(),
            read_at: 12.5,
            unknown: BTreeMap::from([("future".into(), serde_json::json!({"keep":true}))]),
        }
    }
    fn long_plan() -> (ChatPlan, ChatSettings) {
        let settings = ChatSettings {
            base_url: "http://127.0.0.1:1/v1".into(),
            model: "synthetic".into(),
            temperature: None,
            max_tokens: None,
            reasoning_mode: crate::chat::ReasoningMode::Default,
            reasoning_encoding: crate::chat::ReasoningEncoding::None,
        };
        let plan = crate::build_document_knowledge_plan(crate::PlanRequest {
            action: crate::Action::SummarizeDocument,
            document_title: "Public synthetic reading".into(),
            page_count: 1,
            current_page: 0,
            selection: None,
            question: None,
            language: None,
            pages: vec![crate::PageText {
                page: 0,
                text: "Synthetic source. ".repeat(2000),
                chars: vec![],
            }],
            settings: settings.clone(),
            document_knowledge: None,
        })
        .unwrap()
        .rendered(ChatTransport::ChatCompletions);
        assert!(plan.parts.len() > 1);
        (plan, settings)
    }
    #[test]
    fn consolidation_is_previewed_before_the_exact_materialised_body_runs() {
        use std::cell::RefCell;
        let (plan, settings) = long_plan();
        let previews = RefCell::new(Vec::new());
        let calls = RefCell::new(0);
        let answer = run_document_reading(
            &plan,
            settings,
            ChatTransport::ChatCompletions,
            &CancellationToken::new(),
            |next, emit| {
                *calls.borrow_mut() += 1;
                if *calls.borrow() == 2 {
                    assert_eq!(
                        previews.borrow().as_slice(),
                        &next
                            .parts
                            .iter()
                            .map(|p| p.wire_body.clone().unwrap())
                            .collect::<Vec<_>>()
                    );
                }
                for p in &next.parts {
                    emit(RunEvent::PartStarted {
                        index: p.index,
                        total: p.total,
                        label: p.label.clone(),
                    });
                    emit(RunEvent::Delta("Synthetic completed reading [p.1]".into()));
                }
                emit(RunEvent::Done);
                Ok(())
            },
            &mut |event| {
                if let ReadingUpdate::Combining { payloads } = event {
                    *previews.borrow_mut() = payloads;
                }
            },
        )
        .unwrap();
        assert_eq!(*calls.borrow(), 2);
        assert_eq!(answer, "Synthetic completed reading [p.1]");
    }
    #[test]
    fn incomplete_parts_and_cancellation_never_start_consolidation() {
        let (plan, settings) = long_plan();
        let mut calls = 0;
        assert!(
            run_document_reading(
                &plan,
                settings.clone(),
                ChatTransport::ChatCompletions,
                &CancellationToken::new(),
                |_, emit| {
                    calls += 1;
                    emit(RunEvent::PartStarted {
                        index: 0,
                        total: 2,
                        label: "synthetic".into(),
                    });
                    emit(RunEvent::Delta("partial".into()));
                    Ok(())
                },
                &mut |_| {}
            )
            .is_err()
        );
        assert_eq!(calls, 1);
        let cancel = CancellationToken::new();
        let mut calls = 0;
        let result = run_document_reading(
            &plan,
            settings,
            ChatTransport::ChatCompletions,
            &cancel,
            |p, emit| {
                calls += 1;
                for part in &p.parts {
                    emit(RunEvent::PartStarted {
                        index: part.index,
                        total: part.total,
                        label: part.label.clone(),
                    });
                    emit(RunEvent::Delta("complete".into()));
                }
                emit(RunEvent::Done);
                Ok(())
            },
            &mut |event| {
                if matches!(event, ReadingUpdate::Combining { .. }) {
                    cancel.cancel()
                }
            },
        );
        assert!(matches!(result, Err(AiError::Cancelled)));
        assert_eq!(calls, 1);
    }
    #[test]
    fn native_shape_and_unknown_fields_survive() {
        let bytes = record().encode(2).unwrap();
        let value: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(value["readAt"], 12.5);
        assert_eq!(value["sourceHash"], "ab".repeat(32));
        let next = DocumentReading::decode(&bytes, 2).unwrap();
        assert_eq!(next.unknown["future"]["keep"], true);
    }
    #[test]
    fn malformed_and_future_records_are_never_empty_successes() {
        for input in [b"{}".as_slice(), b"not JSON", b"[]"] {
            assert!(DocumentReading::decode(input, 2).is_err());
        }
        let mut r = record();
        r.version = 2;
        assert!(r.encode(2).is_err());
        r.version = 1;
        r.pages = vec![0];
        assert!(r.encode(2).is_err());
        r.pages = vec![1, 1];
        assert!(r.encode(2).is_err());
        r.pages = vec![1, 3];
        assert!(r.encode(2).is_err());
        r.pages = vec![1];
        r.read_at = f64::INFINITY;
        assert!(r.encode(2).is_err());
    }
    #[test]
    fn completion_and_every_part_are_required() {
        let mut a = ReadingAnswers::new(2).unwrap();
        a.begin(0).unwrap();
        a.append("first", false).unwrap();
        assert!(a.finish().is_err());
        a.begin(1).unwrap();
        a.append("thinking", true).unwrap();
        a.complete();
        assert!(a.finish().is_err());
        assert!(a.append("second", false).is_err());
        let mut a = ReadingAnswers::new(1).unwrap();
        a.begin(0).unwrap();
        a.append("answer", false).unwrap();
        a.complete();
        assert_eq!(a.finish().unwrap(), ["answer"]);
        a.fail();
        assert!(a.finish().is_err());
    }
    #[test]
    fn out_of_order_and_oversized_output_stays_failed() {
        assert!(ReadingAnswers::new(0).is_err());
        let mut a = ReadingAnswers::new(1).unwrap();
        assert!(a.begin(1).is_err());
        let mut a = ReadingAnswers::new(1).unwrap();
        a.begin(0).unwrap();
        assert!(a.append(&"x".repeat(MAX_READING_BYTES + 1), false).is_err());
        a.complete();
        assert!(a.finish().is_err());
    }
    #[test]
    fn encoded_json_expansion_is_bounded_before_output_growth() {
        let mut r = record();
        r.summary = "\u{0001}".repeat(MAX_READING_BYTES / 2);
        assert!(r.encode(2).unwrap_err().contains("8 MiB"));
    }
}
