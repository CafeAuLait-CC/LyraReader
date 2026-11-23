use std::sync::Arc;

use serde::Deserialize;
use serde_json::{Value, value::RawValue};

use crate::chat::ChatPlan;
use crate::provider::AiError;

use super::{
    CancellationToken, RequestAudit, ResponseStream, RunEvent, SseDecoder, SseFrame,
    StreamDiagnostics, Transport, assemble_request_spec, header_value, redact_error,
    response_usage, run_audited_transport, validate_api_key,
};

pub const CHATGPT_RESPONSES_ENDPOINT: &str = "https://api.openai.com/v1/responses";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReviewedResponseBody<'a> {
    model: String,
    stream: bool,
    store: bool,
    #[serde(borrow)]
    input: &'a RawValue,
}

/// Send only the reviewed Responses bytes. The plan token never reaches an
/// API-key provider or a user-configured endpoint.
pub fn run_chatgpt_plan_audited(
    plan: &ChatPlan,
    access_token: &str,
    cancel: &CancellationToken,
    emit: &mut dyn FnMut(RunEvent),
    audit: Arc<dyn RequestAudit>,
) -> Result<(), AiError> {
    run_audited_transport(cancel, emit, audit, |transport, output| {
        run_with_transport(plan, access_token, transport, cancel, output)
    })
}

fn run_with_transport(
    plan: &ChatPlan,
    access_token: &str,
    transport: &dyn Transport,
    cancel: &CancellationToken,
    emit: &mut dyn FnMut(RunEvent),
) -> Result<(), AiError> {
    validate_api_key(access_token)?;
    if plan.is_local || plan.endpoint != CHATGPT_RESPONSES_ENDPOINT || plan.parts.is_empty() {
        return Err(AiError::InvalidSettings(
            "Preview the request for the ChatGPT plan connection before sending.".into(),
        ));
    }
    let reviewed = plan
        .parts
        .iter()
        .map(|part| {
            let error = || {
                AiError::InvalidSettings(
                    "The ChatGPT Responses preview is invalid. Nothing was sent.".into(),
                )
            };
            let body = part.wire_body.as_deref().ok_or_else(error)?;
            let decoded: ReviewedResponseBody<'_> =
                serde_json::from_str(body).map_err(|_| error())?;
            if decoded.model != plan.model
                || !decoded.stream
                || decoded.store
                || !decoded.input.get().trim_start().starts_with('[')
            {
                return Err(error());
            }
            Ok(body)
        })
        .collect::<Result<Vec<_>, _>>()?;

    for (part, body) in plan.parts.iter().zip(reviewed) {
        cancel.check()?;
        emit(RunEvent::PartStarted {
            index: part.index,
            total: part.total,
            label: part.label.clone(),
        });
        let spec = assemble_request_spec(plan, access_token, body.as_bytes().to_vec());
        // Redact even when a transport includes the request in its failure message.
        let response = transport
            .execute(&spec, cancel)
            .map_err(|error| redact_error(error, access_token))?;
        read_stream(response, cancel, emit).map_err(|error| redact_error(error, access_token))?;
    }
    cancel.check()?;
    emit(RunEvent::Done);
    Ok(())
}

fn read_stream(
    mut response: Box<dyn ResponseStream>,
    cancel: &CancellationToken,
    emit: &mut dyn FnMut(RunEvent),
) -> Result<(), AiError> {
    let status = response.status();
    match status {
        401 => return Err(AiError::Unauthorized),
        429 => return Err(AiError::RateLimited),
        200..=299 => {}
        _ => {
            return Err(AiError::HttpStatus(format!(
                "ChatGPT returned HTTP {status}."
            )));
        }
    }
    let content_type = header_value(response.headers(), "content-type").unwrap_or_default();
    if !content_type
        .to_ascii_lowercase()
        .starts_with("text/event-stream")
    {
        return Err(AiError::Protocol(
            "ChatGPT did not return a Responses event stream.".into(),
        ));
    }

    let mut decoder = SseDecoder::new();
    let mut stats = StreamDiagnostics {
        http_status: status,
        content_shape: "none".into(),
        ..Default::default()
    };
    while let Some(chunk) = response.next_chunk()? {
        cancel.check()?;
        stats.bytes = stats.bytes.saturating_add(chunk.len() as u64);
        for frame in decoder.push(&chunk)? {
            cancel.check()?;
            stats.frames = stats.frames.saturating_add(1);
            let SseFrame::Data(data) = frame else {
                break;
            };
            stats.data_frames = stats.data_frames.saturating_add(1);
            if handle_event(&data, emit, &mut stats)? {
                emit(RunEvent::Diagnostics(stats));
                return Ok(());
            }
        }
        if decoder.is_done() {
            break;
        }
    }
    cancel.check()?;
    Err(AiError::Protocol(
        "The ChatGPT stream ended before completion. The partial answer is kept.".into(),
    ))
}

fn handle_event(
    data: &str,
    emit: &mut dyn FnMut(RunEvent),
    stats: &mut StreamDiagnostics,
) -> Result<bool, AiError> {
    let bad_event = || AiError::Protocol("ChatGPT returned a malformed Responses event.".into());
    let value: Value = serde_json::from_str(data).map_err(|_| bad_event())?;
    let event_type = value["type"].as_str().ok_or_else(bad_event)?;
    match event_type {
        "response.output_text.delta" | "response.refusal.delta" => {
            let text = value["delta"].as_str().ok_or_else(bad_event)?;
            if !text.is_empty() {
                stats.note_shape("string");
                stats.content_frames = stats.content_frames.saturating_add(1);
                emit(RunEvent::Delta(text.to_owned()));
            }
        }
        "response.reasoning_summary_text.delta" => {
            let text = value["delta"].as_str().ok_or_else(bad_event)?;
            if !text.is_empty() {
                stats.reasoning_frames = stats.reasoning_frames.saturating_add(1);
                emit(RunEvent::ReasoningDelta(text.to_owned()));
            }
        }
        "response.completed" => {
            let response = &value["response"];
            if !response.is_object()
                || response["status"]
                    .as_str()
                    .is_some_and(|status| status != "completed")
            {
                return Err(bad_event());
            }
            if let Some(usage) = response_usage(response) {
                stats.usage_frames = stats.usage_frames.saturating_add(1);
                stats.merge_usage(usage);
                emit(RunEvent::Usage(usage));
            }
            return Ok(true);
        }
        "response.failed" | "response.incomplete" | "error" => {
            let code = value["response"]["error"]["code"]
                .as_str()
                .or_else(|| value["error"]["code"].as_str())
                .or_else(|| value["code"].as_str());
            let failure = match code {
                Some("subscription_sharing_usage_limit_exceeded") => AiError::RateLimited,
                Some("subscription_sharing_usage_unavailable") => AiError::Unauthorized,
                _ => AiError::Other(
                    "ChatGPT returned an incomplete answer. The partial answer is kept.".into(),
                ),
            };
            return Err(failure);
        }
        _ => {}
    }
    Ok(false)
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;
    use crate::chat::{
        ChatSettings, ChatTransport, ReasoningEncoding, ReasoningMode, build_connection_test_plan,
    };
    use crate::openai::RequestSpec;

    struct Reply {
        bytes: Option<Vec<u8>>,
        headers: Vec<(String, String)>,
    }

    impl ResponseStream for Reply {
        fn status(&self) -> u16 {
            200
        }
        fn reason(&self) -> &str {
            "OK"
        }
        fn headers(&self) -> &[(String, String)] {
            &self.headers
        }
        fn next_chunk(&mut self) -> Result<Option<Vec<u8>>, AiError> {
            Ok(self.bytes.take())
        }
    }

    struct Playback {
        answer: &'static str,
        requests: Mutex<Vec<(String, Vec<u8>)>>,
    }

    impl Playback {
        fn new(answer: &'static str) -> Self {
            Self {
                answer,
                requests: Mutex::new(Vec::new()),
            }
        }
    }

    impl Transport for Playback {
        fn execute(
            &self,
            spec: &RequestSpec,
            _cancel: &CancellationToken,
        ) -> Result<Box<dyn ResponseStream>, AiError> {
            assert!(!spec.is_local);
            assert!(
                spec.headers
                    .iter()
                    .any(|(name, value)| name == "Authorization"
                        && value == "Bearer synthetic-access")
            );
            self.requests
                .lock()
                .unwrap()
                .push((spec.url.clone(), spec.body.clone()));
            Ok(Box::new(Reply {
                bytes: Some(self.answer.as_bytes().to_vec()),
                headers: vec![("content-type".into(), "text/event-stream".into())],
            }))
        }
    }

    fn review() -> ChatPlan {
        let mut plan = build_connection_test_plan(ChatSettings {
            base_url: "https://api.openai.com/v1".into(),
            model: "chatgpt-test".into(),
            temperature: None,
            max_tokens: None,
            reasoning_mode: ReasoningMode::Default,
            reasoning_encoding: ReasoningEncoding::None,
        })
        .unwrap();
        plan.endpoint = CHATGPT_RESPONSES_ENDPOINT.into();
        plan.rendered(ChatTransport::Responses)
    }

    #[test]
    fn responses_sends_exact_review_and_separates_usage_and_reasoning() {
        let plan = review();
        let mock = Playback::new(concat!(
            "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"thinking\"}\n\n",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"answer\"}\n\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":5,\"output_tokens\":7}}}\n\n",
        ));
        let mut observed = Vec::new();
        run_with_transport(
            &plan,
            "synthetic-access",
            &mock,
            &CancellationToken::new(),
            &mut |event| observed.push(event),
        )
        .unwrap();
        let calls = mock.requests.lock().unwrap();
        assert_eq!(
            calls.as_slice(),
            [(
                CHATGPT_RESPONSES_ENDPOINT.into(),
                plan.parts[0]
                    .wire_body
                    .as_ref()
                    .unwrap()
                    .as_bytes()
                    .to_vec()
            )]
        );
        assert!(observed.contains(&RunEvent::Delta("answer".into())));
        assert!(observed.contains(&RunEvent::ReasoningDelta("thinking".into())));
        assert!(observed.iter().any(|event|matches!(event,RunEvent::Usage(usage) if usage.prompt_tokens==Some(5) && usage.completion_tokens==Some(7))));
        assert_eq!(observed.last(), Some(&RunEvent::Done));
    }

    #[test]
    fn responses_rejects_redirected_or_incompatible_review_before_network() {
        let mut plan = review();
        let mock = Playback::new("");
        plan.endpoint = "https://untrusted.example.invalid/v1/responses".into();
        assert!(
            run_with_transport(
                &plan,
                "synthetic-access",
                &mock,
                &CancellationToken::new(),
                &mut |_| {}
            )
            .is_err()
        );
        plan.endpoint = CHATGPT_RESPONSES_ENDPOINT.into();
        plan = plan.rendered(ChatTransport::ChatCompletions);
        assert!(
            run_with_transport(
                &plan,
                "synthetic-access",
                &mock,
                &CancellationToken::new(),
                &mut |_| {}
            )
            .is_err()
        );
        assert!(mock.requests.lock().unwrap().is_empty());
    }

    #[test]
    fn responses_never_promotes_partial_or_incomplete_events() {
        let plan = review();
        let mock = Playback::new(concat!(
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n",
            "data: [DONE]\n\n",
        ));
        let mut seen = Vec::new();
        let outcome = run_with_transport(
            &plan,
            "synthetic-access",
            &mock,
            &CancellationToken::new(),
            &mut |event| seen.push(event),
        );
        assert!(matches!(outcome, Err(AiError::Protocol(_))));
        assert!(seen.contains(&RunEvent::Delta("partial".into())));
        assert!(!seen.contains(&RunEvent::Done));
        let limit = Playback::new(
            "data: {\"type\":\"error\",\"code\":\"subscription_sharing_usage_limit_exceeded\"}\n\n",
        );
        assert!(matches!(
            run_with_transport(
                &plan,
                "synthetic-access",
                &limit,
                &CancellationToken::new(),
                &mut |_| {}
            ),
            Err(AiError::RateLimited)
        ));
    }
}
