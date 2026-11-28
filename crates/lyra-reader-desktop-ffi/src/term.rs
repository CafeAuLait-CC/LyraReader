//! One ephemeral term popover owns one frozen revision and one audited request.
//! No result is archived and the reader's summary/translation request is not borrowed.
use crate::{
    document::{DesktopDocument, chatgpt_account, render_reviewed_plan},
    render_source::RenderSource,
};
use lyra_reader_ffi::api::*;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex, Weak},
};

pub struct TermService {
    // Cancel the request before the frozen PDF and revision lease are retired.
    state: Mutex<State>,
    source: RenderSource,
    audit_root: PathBuf,
    // Observe admission without keeping the owner's background job alive.
    knowledge: Weak<Mutex<crate::knowledge::Knowledge>>,
}

#[derive(Default)]
struct State {
    preview: Option<Value>,
    job: Option<Arc<LyraReaderAiRequest>>,
    sent: bool,
}

fn argument<T: DeserializeOwned>(request: &Value, key: &str) -> Result<T, String> {
    serde_json::from_value(
        request
            .get(key)
            .cloned()
            .ok_or_else(|| format!("Missing term {key}."))?,
    )
    .map_err(|error| format!("Invalid term {key}: {error}"))
}

impl TermService {
    /// Worker-only capture: pin the actual working revision, not the original PDF URL.
    pub fn new(document: &DesktopDocument) -> Result<Self, String> {
        let source = RenderSource::new(document, false)?;
        let audit_root = document
            .marks
            .lock()
            .map_err(|_| "Annotation state is unavailable")?
            .cache_root()
            .map(PathBuf::from)
            .map(Ok)
            .unwrap_or_else(crate::document_cache::default_root)?;
        Ok(Self {
            source,
            audit_root,
            state: Mutex::new(State::default()),
            knowledge: Arc::downgrade(&document.knowledge),
        })
    }

    pub fn command(&self, request: Value) -> Result<Value, String> {
        if matches!(request["op"].as_str(), Some("prepare" | "start"))
            && let Some(knowledge) = self.knowledge.upgrade()
        {
            match knowledge.try_lock() {
                Ok(state) => state.ensure_foreground_ready()?,
                Err(std::sync::TryLockError::WouldBlock) => {
                    return Err(crate::prereading::BUSY.into());
                }
                Err(std::sync::TryLockError::Poisoned(_)) => {
                    return Err("Document reading state is unavailable".into());
                }
            }
        }
        let mut state = self
            .state
            .lock()
            .map_err(|_| "The term request state is unavailable.")?;
        match request["op"].as_str() {
            Some("prepare") => {
                if state.job.as_ref().is_some_and(|job| !job.is_finished()) {
                    return Err(
                        "Stop the current term explanation before preparing another.".into(),
                    );
                }
                state.preview = None;
                state.job = None;
                state.sent = false;
                let input: AiPlanRequestRecord = argument(&request, "request")?;
                if input.action != AiActionRecord::SummarizeDocument
                    || input.selection.is_some()
                    || input.region.is_some()
                    || !input.history.is_empty()
                    || input.document_knowledge
                    || input.document_knowledge_text.is_some()
                    || !input.document_knowledge_pages.is_empty()
                {
                    return Err("A term explanation requires the current document without a selection or extra context.".into());
                }
                let account = chatgpt_account(&request["request"])?;
                let mut preview = render_reviewed_plan(self.source.prepare_term(input), account)?;
                preview["kind"] = json!("reading_term");
                preview["term_token"] = json!(crate::marks::uuid()?);
                preview["term_source_sha256"] = json!(self.source.source_sha256());
                state.preview = Some(preview.clone());
                Ok(preview)
            }
            Some("start") => {
                let preview = state.preview.as_ref().ok_or(
                    "The term preview changed. Prepare and review it again before sending.",
                )?;
                let plan: AiPlanRecord =
                    serde_json::from_value(preview.clone()).map_err(|error| error.to_string())?;
                let submitted: AiPlanRecord = argument(&request, "plan")?;
                // Qt's JSON bridge can encode 0.0 as 0. Compare the typed DTO,
                // while wire_body strings and identity metadata remain exact.
                if [
                    "kind",
                    "term_token",
                    "term_source_sha256",
                    "chatgpt_account",
                ]
                .iter()
                .any(|field| preview.get(*field) != request["plan"].get(*field))
                    || serde_json::to_value(&plan).map_err(|error| error.to_string())?
                        != serde_json::to_value(submitted).map_err(|error| error.to_string())?
                {
                    return Err(
                        "The term preview changed. Prepare and review it again before sending."
                            .into(),
                    );
                }
                if state.sent || state.job.is_some() {
                    return Err("This term preview has already been sent.".into());
                }
                let account = chatgpt_account(preview)?;
                if account != chatgpt_account(&request)? {
                    return Err(
                        "The ChatGPT connection changed. Review the term request again.".into(),
                    );
                }
                // Dispatch only the stored, fully compared typed plan. The native caller cannot
                // swap the body, source pages, endpoint or connection after review.
                let audit =
                    crate::audit::observer(self.audit_root.clone(), plan.action, plan.is_local);
                let job = if account.is_some() {
                    start_chatgpt_request_audited(
                        plan,
                        argument(&request, "chatgpt_access_token")?,
                        audit,
                    )
                } else {
                    start_ai_request_audited(
                        plan,
                        argument(&request, "api_key")?,
                        false,
                        Some(audit),
                    )
                }
                .map_err(|error| error.to_string())?;
                state.job = Some(job);
                state.sent = true;
                Ok(json!(true))
            }
            Some("poll") => {
                let Some(job) = state.job.as_ref() else {
                    return Ok(json!({"events":[],"finished":state.sent}));
                };
                let mut events = job.poll();
                let finished = job.is_finished()
                    || events
                        .iter()
                        .any(|event| matches!(event, AiEventRecord::Error { .. }));
                if finished {
                    events.extend(job.poll());
                }
                let response = json!({"events":events,"finished":finished});
                if finished {
                    state.job = None;
                }
                Ok(response)
            }
            Some("cancel") => {
                if let Some(job) = state.job.take() {
                    job.cancel();
                }
                state.preview = None;
                Ok(json!(true))
            }
            _ => Err("Unknown term explanation operation.".into()),
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
        sync::mpsc,
        thread,
        time::{Duration, Instant},
    };

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let directory = std::env::temp_dir()
                .join(format!("lyra-term-check-{}", crate::marks::uuid().unwrap()));
            fs::create_dir(&directory).unwrap();
            fs::copy(
                PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join("../../tests/fixtures/text-page.pdf"),
                directory.join("fixture.pdf"),
            )
            .unwrap();
            Self(directory)
        }
        fn open(&self) -> DesktopDocument {
            DesktopDocument::open_with_cache_root(
                &self.0.join("fixture.pdf"),
                None,
                Some(&self.0.join("cache")),
            )
            .unwrap()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn settings(base: &str) -> Value {
        json!({"action":"SummarizeDocument","current_page":0,"selection":null,"region":null,
            "question":"LyraReader","language":"English","history":[],"document_knowledge":false,
            "document_knowledge_text":null,"document_knowledge_pages":[],"base_url":base,"model":"synthetic-term",
            "temperature":null,"max_tokens":null,"reasoning_mode":"default","reasoning_encoding":"none"})
    }
    fn prepare(term: &TermService, base: &str) -> Value {
        term.command(json!({"op":"prepare","request":settings(base)}))
            .unwrap()
    }
    #[test]
    fn preview_requires_exact_body_connection_and_uncancelled_owner_before_any_send() {
        let fixture = Fixture::new();
        let doc = fixture.open();
        let term = TermService::new(&doc).unwrap();
        let plan = prepare(&term, "http://127.0.0.1:1/v1");
        assert_eq!(plan["kind"], "reading_term");
        assert_eq!(plan["source_pages"], json!([1]));
        assert!(
            plan["parts"][0]["wire_body"]
                .as_str()
                .unwrap()
                .contains("Requested term: LyraReader")
        );
        for field in ["wire_body", "endpoint", "term_token", "term_source_sha256"] {
            let mut changed = plan.clone();
            if field == "wire_body" {
                changed["parts"][0][field] = json!("substituted body");
            } else {
                changed[field] = json!("changed");
            }
            assert!(
                term.command(json!({"op":"start","plan":changed,"api_key":"local"}))
                    .unwrap_err()
                    .contains("preview changed")
            );
        }
        assert!(
            term.command(
                json!({"op":"start","plan":plan,"chatgpt_account":"another","api_key":"local"})
            )
            .unwrap_err()
            .contains("connection changed")
        );
        term.command(json!({"op":"cancel"})).unwrap();
        assert!(
            term.command(json!({"op":"start","plan":plan,"api_key":"local"}))
                .is_err()
        );
        assert!(!fixture.0.join("cache/Audit/ai-requests.jsonl").exists());
    }
    #[test]
    fn term_capture_keeps_the_working_revision_after_discard_and_parent_close() {
        let fixture = Fixture::new();
        let doc = fixture.open();
        doc.command(json!({"op":"page_stage","operation":{"InsertBlank":{"index":1}}}))
            .unwrap();
        let term = TermService::new(&doc).unwrap();
        let sha = term.source.source_sha256();
        let directory = doc
            .edits
            .lock()
            .unwrap()
            .directory
            .as_ref()
            .unwrap()
            .path
            .clone();
        doc.command(json!({"op":"page_discard"})).unwrap();
        drop(doc);
        assert!(directory.exists());
        let plan = prepare(&term, "http://127.0.0.1:1/v1");
        assert_eq!(plan["term_source_sha256"], sha);
        assert!(
            plan["parts"][0]["wire_body"]
                .as_str()
                .unwrap()
                .contains("LyraReader")
        );
        drop(term);
        assert!(!directory.exists());
    }
    fn server(
        hold: Option<mpsc::Receiver<()>>,
    ) -> (String, mpsc::Receiver<Vec<u8>>, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let (sent, received) = mpsc::channel();
        let task = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut request = Vec::new();
            let (header, length) = loop {
                let mut buffer = [0u8; 2048];
                let count = stream.read(&mut buffer).unwrap();
                assert!(count > 0);
                request.extend_from_slice(&buffer[..count]);
                assert!(request.len() < 1024 * 1024);
                if let Some(end) = request.windows(4).position(|bytes| bytes == b"\r\n\r\n") {
                    let headers = String::from_utf8(request[..end].to_vec()).unwrap();
                    let length = headers
                        .lines()
                        .find_map(|line| {
                            line.split_once(':')
                                .filter(|(key, _)| key.eq_ignore_ascii_case("content-length"))
                                .map(|(_, value)| value.trim().parse::<usize>().unwrap())
                        })
                        .unwrap();
                    break (end + 4, length);
                }
            };
            while request.len() < header + length {
                let mut buffer = [0u8; 2048];
                let count = stream.read(&mut buffer).unwrap();
                assert!(count > 0);
                request.extend_from_slice(&buffer[..count]);
            }
            sent.send(request[header..header + length].to_vec())
                .unwrap();
            let answer=b"data: {\"choices\":[{\"delta\":{\"content\":\"Synthetic explanation [p.1]\"}}]}\n\n";
            let done = b"data: [DONE]\n\n";
            write!(stream,"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",answer.len()+done.len()).unwrap();
            stream.write_all(answer).unwrap();
            stream.flush().unwrap();
            if let Some(hold) = hold {
                hold.recv_timeout(Duration::from_secs(5)).unwrap();
            }
            stream.write_all(done).unwrap();
        });
        (format!("http://{address}/v1"), received, task)
    }
    #[test]
    fn independent_term_stream_matches_preview_and_does_not_cancel_the_main_request() {
        let fixture = Fixture::new();
        let doc = fixture.open();
        let (release, hold) = mpsc::channel();
        let (main_url, main_body, main_server) = server(Some(hold));
        let mut input = settings(&main_url);
        input["action"] = json!("SummarizePage");
        let main = doc
            .command(json!({"op":"ai_preview","request":input}))
            .unwrap();
        doc.command(json!({"op":"ai_start","plan":main,"api_key":"local"}))
            .unwrap();
        main_body.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(doc.ai_running().unwrap());
        let (url, body, term_server) = server(None);
        let term = TermService::new(&doc).unwrap();
        let mut input = settings(&url);
        input["temperature"] = json!(0.0);
        let preview = term
            .command(json!({"op":"prepare","request":input}))
            .unwrap();
        let mut native_roundtrip = preview.clone();
        native_roundtrip["temperature"] = json!(0);
        term.command(json!({"op":"start","plan":native_roundtrip,"api_key":"local"}))
            .unwrap();
        assert_eq!(
            body.recv_timeout(Duration::from_secs(5)).unwrap(),
            preview["parts"][0]["wire_body"]
                .as_str()
                .unwrap()
                .as_bytes()
        );
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut events = Vec::new();
        loop {
            let poll = term.command(json!({"op":"poll"})).unwrap();
            events.extend(poll["events"].as_array().unwrap().iter().cloned());
            if poll["finished"] == true {
                break;
            }
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(5));
        }
        assert!(events.iter().any(|event| event == "Done"));
        assert!(doc.ai_running().unwrap());
        assert!(
            term.command(json!({"op":"start","plan":preview,"api_key":"local"}))
                .is_err()
        );
        term.command(json!({"op":"cancel"})).unwrap();
        drop(term);
        assert!(doc.ai_running().unwrap());
        release.send(()).unwrap();
        main_server.join().unwrap();
        term_server.join().unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut main_events = Vec::new();
        loop {
            // Finished workers can still own their terminal queued event.
            let poll = doc.command(json!({"op":"ai_poll"})).unwrap();
            main_events.extend(poll["events"].as_array().unwrap().iter().cloned());
            if poll["finished"] == true {
                break;
            }
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(5));
        }
        assert!(main_events.iter().any(|event| event == "Done"));
        let audit = fs::read_to_string(fixture.0.join("cache/Audit/ai-requests.jsonl")).unwrap();
        assert_eq!(audit.lines().count(), 2);
        assert!(!audit.contains("LyraReader") && !audit.contains("Synthetic explanation"));
    }
}
