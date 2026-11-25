use std::sync::Arc;

use serde::Deserialize;
use serde_json::{Value, value::RawValue};

use crate::chat::ChatPlan;
use crate::provider::AiError;

use super::{
    CancellationToken, RequestAudit, ResponseStream, RunEvent, SseDecoder, SseFrame,
    StreamDiagnostics, Transport, assemble_request_spec, header_value, read_error_body,
    redact_error, response_usage, run_audited_transport, validate_api_key,
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
        read_stream(response, part.image.is_some(), cancel, emit)
            .map_err(|error| redact_error(error, access_token))?;
    }
    cancel.check()?;
    emit(RunEvent::Done);
    Ok(())
}

fn read_stream(
    mut response: Box<dyn ResponseStream>,
    carrying_image: bool,
    cancel: &CancellationToken,
    emit: &mut dyn FnMut(RunEvent),
) -> Result<(), AiError> {
    let status = response.status();
    if !(200..=299).contains(&status) && status != 401 && status != 429 {
        let body = read_error_body(&mut *response, cancel)?;
        if let Ok(value) = serde_json::from_str::<Value>(&body)
            && let Some(error) = value["error"]["code"]
                .as_str()
                .and_then(subscription_failure)
        {
            return Err(error);
        }
    }
    match status {
        401 => return Err(AiError::Unauthorized),
        429 => return Err(AiError::RateLimited),
        403 if carrying_image => {
            return Err(AiError::HttpStatus(
                "ChatGPT plan usage did not authorize the region image (HTTP 403). Check the plan and LyraReader’s permission in ChatGPT Settings.".into(),
            ));
        }
        400 | 413 | 415 | 422 if carrying_image => {
            return Err(AiError::HttpStatus(format!(
                "ChatGPT declined the region image (HTTP {status}). Choose a model that accepts images and preview the question again."
            )));
        }
        200..=299 => {}
        _ => {
            return Err(AiError::HttpStatus(format!(
                "ChatGPT returned HTTP {status}."
            )));
        }
    }
    // Validate the body framing as well as its label. Some direct-route replies
    // carry a generic MIME type; a valid Responses SSE stream still has to reach
    // response.completed. JSON, HTML and interrupted streams never mean success.
    let first = stream_preamble(&mut *response, cancel)?;

    let mut decoder = SseDecoder::new();
    let mut stats = StreamDiagnostics {
        http_status: status,
        content_shape: "none".into(),
        ..Default::default()
    };
    let mut first = Some(first);
    while let Some(chunk) = match first.take() {
        Some(bytes) => Some(bytes),
        None => response.next_chunk()?,
    } {
        cancel.check()?;
        stats.bytes = stats.bytes.saturating_add(chunk.len() as u64);
        for frame in decoder.push(&chunk)? {
            cancel.check()?;
            stats.frames = stats.frames.saturating_add(1);
            let SseFrame::Data(data) = frame else {
                break;
            };
            stats.data_frames = stats.data_frames.saturating_add(1);
            if handle_event(&data, carrying_image, emit, &mut stats)? {
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

fn subscription_failure(code: &str) -> Option<AiError> {
    match code {
        "subscription_sharing_usage_limit_exceeded" => Some(AiError::RateLimited),
        "subscription_sharing_usage_unavailable" | "subscription_sharing_user_unavailable" => Some(AiError::Other(
            "ChatGPT plan usage is temporarily unavailable. Your sign-in is kept. Retry later.".into())),
        "subscription_sharing_user_not_eligible" => Some(AiError::Other(
            "ChatGPT plan usage is unavailable for this account or workspace. Check the plan and workspace policy.".into())),
        "subscription_sharing_unsupported_capability" => Some(AiError::Other(
            "The selected ChatGPT model or input is unsupported for plan usage. Change the model or input and preview again.".into())),
        "subscription_sharing_route_not_supported" | "chatpass_v2_scope_not_authorized" | "chatpass_v2_invalid_authorization_context" => Some(AiError::Other(
            "ChatGPT did not authorize this integration or request route. Check the app’s plan-usage permission.".into())),
        "subscription_sharing_invalid_user" => Some(AiError::Unauthorized),
        _ => None,
    }
}

fn stream_preamble(
    response: &mut dyn ResponseStream,
    cancel: &CancellationToken,
) -> Result<Vec<u8>, AiError> {
    let mut prefix = Vec::new();
    const FIELDS: [&[u8]; 5] = [b"data:", b"event:", b":", b"id:", b"retry:"];
    loop {
        cancel.check()?;
        let Some(chunk) = response.next_chunk()? else {
            break;
        };
        // Match the existing SSE decoder's allocation limit before buffering.
        if prefix
            .len()
            .checked_add(chunk.len())
            .is_none_or(|len| len > 1024 * 1024)
        {
            return Err(AiError::Protocol(
                "The ChatGPT response preamble exceeded 1 MiB.".into(),
            ));
        }
        prefix.extend_from_slice(&chunk);
        let body = prefix.strip_prefix(b"\xef\xbb\xbf").unwrap_or(&prefix);
        let start = body
            .iter()
            .position(|byte| !byte.is_ascii_whitespace())
            .unwrap_or(body.len());
        let body = &body[start..];
        if FIELDS.iter().any(|field| body.starts_with(field)) {
            return Ok(body.to_vec());
        }
        if prefix.len() <= 1024
            && (body.is_empty()
                || FIELDS.iter().any(|field| field.starts_with(body))
                || b"\xef\xbb\xbf".starts_with(&prefix))
        {
            continue;
        }
        // Read only a bounded diagnostic body. Provider text can include private
        // request content, so expose recognized codes and shape, never raw text.
        const LIMIT: usize = 64 * 1024;
        prefix.truncate(LIMIT);
        while prefix.len() < LIMIT {
            cancel.check()?;
            let Some(chunk) = response.next_chunk()? else {
                break;
            };
            let remaining = LIMIT - prefix.len();
            prefix.extend_from_slice(&chunk[..chunk.len().min(remaining)]);
        }
        if let Ok(value) = serde_json::from_slice::<Value>(&prefix) {
            if let Some(error) = value["error"]["code"]
                .as_str()
                .and_then(subscription_failure)
            {
                return Err(error);
            }
            return Err(AiError::Protocol(format!(
                "ChatGPT returned JSON instead of a Responses event stream (HTTP {}). Preview again and retry. No completed answer was received.",
                response.status()
            )));
        }
        break;
    }
    let kind = match header_value(response.headers(), "content-type")
        .unwrap_or("")
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
    {
        "text/html" => "HTML",
        "application/json" => "invalid JSON",
        "text/plain" => "plain text",
        "" => "an unlabelled body",
        _ => "an unexpected body",
    };
    Err(AiError::Protocol(format!(
        "ChatGPT returned {kind} instead of a Responses event stream (HTTP {}). No completed answer was received.",
        response.status()
    )))
}

fn handle_event(
    data: &str,
    carrying_image: bool,
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
            let failure = match code.and_then(subscription_failure) {
                Some(error) => error,
                None if carrying_image && event_type != "response.incomplete" => AiError::Other(
                    "ChatGPT could not complete the request with the region image. Check whether the model accepts images and preview again. The partial answer is kept.".into(),
                ),
                None => AiError::Other(
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
        ChatImage, ChatSettings, ChatTransport, ReasoningEncoding, ReasoningMode,
        build_connection_test_plan,
    };
    use crate::openai::RequestSpec;

    struct Reply {
        status: u16,
        bytes: Option<Vec<u8>>,
        headers: Vec<(String, String)>,
    }

    impl ResponseStream for Reply {
        fn status(&self) -> u16 {
            self.status
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
        status: u16,
        answer: &'static str,
        requests: Mutex<Vec<(String, Vec<u8>)>>,
    }

    impl Playback {
        fn new(answer: &'static str) -> Self {
            Self {
                status: 200,
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
                status: self.status,
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
    fn responses_validate_events_even_with_missing_or_generic_mime() {
        let wire = concat!(
            "event: response.output_text.delta\n",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"answer\"}\n\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
        );
        for mime in [
            None,
            Some("application/json"),
            Some("text/plain"),
            Some(" Text/Event-Stream ; charset=utf-8"),
        ] {
            let reply = Reply {
                status: 200,
                bytes: Some(wire.as_bytes().to_vec()),
                headers: mime
                    .map(|mime| vec![("content-type".into(), mime.into())])
                    .unwrap_or_default(),
            };
            let mut events = Vec::new();
            read_stream(
                Box::new(reply),
                false,
                &CancellationToken::new(),
                &mut |event| events.push(event),
            )
            .unwrap();
            assert!(events.contains(&RunEvent::Delta("answer".into())));
        }
    }

    #[test]
    fn responses_sniff_split_bom_and_fields_without_losing_first_event() {
        struct Chunks(std::collections::VecDeque<Vec<u8>>);
        impl ResponseStream for Chunks {
            fn status(&self) -> u16 {
                200
            }
            fn reason(&self) -> &str {
                "OK"
            }
            fn headers(&self) -> &[(String, String)] {
                &[]
            }
            fn next_chunk(&mut self) -> Result<Option<Vec<u8>>, AiError> {
                Ok(self.0.pop_front())
            }
        }
        let wire = concat!(
            "\u{feff}event: response.created\n",
            "data: {\"type\":\"response.created\"}\n\n",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"answer\"}\n\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
        );
        for size in [1, 2, 3, 7, 8192] {
            let reply = Chunks(
                wire.as_bytes()
                    .chunks(size)
                    .map(|chunk| chunk.to_vec())
                    .collect(),
            );
            let mut events = Vec::new();
            read_stream(
                Box::new(reply),
                false,
                &CancellationToken::new(),
                &mut |event| events.push(event),
            )
            .unwrap();
            assert_eq!(
                events
                    .iter()
                    .filter(|event| matches!(event,RunEvent::Delta(text) if text=="answer"))
                    .count(),
                1
            );
        }
    }

    #[test]
    fn responses_never_accept_json_html_or_done_without_completed() {
        for (mime, body) in [
            (
                "application/json",
                "{\"status\":\"completed\",\"output_text\":\"PRIVATE_BODY\"}",
            ),
            ("text/html", "<html>PRIVATE_BODY</html>"),
            ("text/event-stream", "data: [DONE]\n\n"),
            (
                "text/plain",
                "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n",
            ),
        ] {
            let reply = Reply {
                status: 200,
                bytes: Some(body.as_bytes().to_vec()),
                headers: vec![("content-type".into(), mime.into())],
            };
            let mut events = Vec::new();
            let error = read_stream(
                Box::new(reply),
                false,
                &CancellationToken::new(),
                &mut |event| events.push(event),
            )
            .unwrap_err();
            assert!(!error.to_string().contains("PRIVATE_BODY"));
            assert!(!events.contains(&RunEvent::Done));
        }
    }

    #[test]
    fn responses_preserve_sign_in_on_temporarily_unavailable_usage() {
        for status in [200, 503] {
            let reply=Reply {status,bytes:Some(br#"{"error":{"code":"subscription_sharing_usage_unavailable","message":"PRIVATE_BODY"}}"#.to_vec()),headers:vec![("content-type".into(),"application/json".into())]};
            let error = read_stream(
                Box::new(reply),
                false,
                &CancellationToken::new(),
                &mut |_| {},
            )
            .unwrap_err();
            assert!(matches!(error, AiError::Other(_)));
            assert!(error.to_string().contains("temporarily unavailable"));
            assert!(!error.to_string().contains("PRIVATE_BODY"));
        }
        let reply=Reply {status:200,bytes:Some(b"data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_unavailable\"}}}\n\n".to_vec()),headers:Vec::new()};
        assert!(matches!(
            read_stream(
                Box::new(reply),
                false,
                &CancellationToken::new(),
                &mut |_| {}
            ),
            Err(AiError::Other(_))
        ));
    }

    #[test]
    fn responses_preamble_is_bounded_and_cancellable() {
        let reply = Reply {
            status: 200,
            bytes: Some(vec![b' '; 1024 * 1024 + 1]),
            headers: Vec::new(),
        };
        assert!(matches!(
            read_stream(
                Box::new(reply),
                false,
                &CancellationToken::new(),
                &mut |_| {}
            ),
            Err(AiError::Protocol(_))
        ));
        let cancel = CancellationToken::new();
        cancel.cancel();
        let reply = Reply {
            status: 200,
            bytes: Some(b"data: [DONE]\n\n".to_vec()),
            headers: Vec::new(),
        };
        assert!(matches!(
            read_stream(Box::new(reply), false, &cancel, &mut |_| {}),
            Err(AiError::Cancelled)
        ));
    }

    #[test]
    fn a_declined_image_never_retries_with_text_only() {
        let mut plan = review();
        plan.parts[0].image = Some(ChatImage {
            width_px: 1,
            height_px: 1,
            png: vec![0x89, b'P', b'N', b'G', 1, 2, 3, 4],
        });
        plan = plan.rendered(ChatTransport::Responses);
        let wire = plan.parts[0].wire_body.as_deref().unwrap();
        assert!(wire.contains("input_image"));
        let mut mock = Playback::new("");
        mock.status = 415;
        let mut events = Vec::new();
        let result = run_with_transport(
            &plan,
            "synthetic-access",
            &mock,
            &CancellationToken::new(),
            &mut |event| events.push(event),
        );
        assert!(
            matches!(result, Err(AiError::HttpStatus(message)) if message.contains("region image"))
        );
        let requests = mock.requests.lock().unwrap();
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].1.as_slice(), wire.as_bytes());
        assert!(!events.contains(&RunEvent::Done));
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
