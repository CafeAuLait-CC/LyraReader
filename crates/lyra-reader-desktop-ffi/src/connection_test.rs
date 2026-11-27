//! Document-free Settings probe. The shared builder owns the fixed ping and wire body.
use crate::{Buffer, bytes, run};
use lyra_reader_ffi::api::{
    AiErrorCode, AiEventRecord, AiFailureRecord, AiPlanRecord, AiWireTransport,
    LyraReaderAiRequest, LyraReaderFfiError, build_ai_connection_test_plan, render_ai_plan,
    start_ai_request_audited,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    ptr,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Instant,
};

// This control plane accepts only endpoint/model/key strings, never document payloads.
const MAX_COMMAND_BYTES: usize = 128 * 1024;

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Command {
    Prepare { base_url: String, model: String },
    Start { api_key: String },
    Poll,
}

struct State {
    plan: Option<AiPlanRecord>,
    request: Option<Arc<LyraReaderAiRequest>>,
    phase: &'static str,
    started: Option<Instant>,
    elapsed_ms: u64,
    message: Option<String>,
    code: Option<AiErrorCode>,
    failure: Option<AiFailureRecord>,
}
impl Default for State {
    fn default() -> Self {
        Self {
            plan: None,
            request: None,
            phase: "idle",
            started: None,
            elapsed_ms: 0,
            message: None,
            code: None,
            failure: None,
        }
    }
}
impl State {
    fn snapshot(&self) -> Value {
        json!({"phase":self.phase,"model":self.plan.as_ref().map(|p|&p.model),
            "plan":if self.phase=="preview" {self.plan.as_ref()} else {None},
            "elapsed_ms":self.elapsed_ms,"message":self.message,"code":self.code,"failure":self.failure})
    }
    fn fail(&mut self, error: LyraReaderFfiError) {
        let (message, code) = match error {
            LyraReaderFfiError::Ai { message, code, .. } => (message, code),
            LyraReaderFfiError::InvalidArgument { message, .. } => {
                (message, AiErrorCode::InvalidSettings)
            }
            LyraReaderFfiError::Document { message, .. }
            | LyraReaderFfiError::Backend { message, .. } => (message, AiErrorCode::Other),
        };
        self.phase = "failed";
        self.message = Some(message);
        self.code = Some(code);
    }
    fn finish_time(&mut self) -> Result<(), String> {
        if let Some(started) = self.started.take() {
            self.elapsed_ms = u64::try_from(started.elapsed().as_millis())
                .map_err(|_| "The connection test duration is not representable")?;
        }
        Ok(())
    }
    fn cancel(&mut self) {
        if let Some(request) = self.request.take() {
            request.cancel();
        }
        self.phase = "idle";
        self.message = None;
        self.code = None;
        self.failure = None;
    }
}

#[derive(Default)]
pub struct Service {
    cancelled: AtomicBool,
    state: Mutex<State>,
}
impl Drop for Service {
    fn drop(&mut self) {
        self.cancel();
    }
}
impl Service {
    fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        // Never wait for a worker command on the UI thread. An in-flight command
        // checks this flag before releasing its state; the request's Drop also cancels.
        if let Ok(mut state) = self.state.try_lock() {
            state.cancel();
        }
    }
    fn command(&self, input: Value) -> Result<Value, String> {
        let command: Command =
            serde_json::from_value(input).map_err(|_| "The connection test command is invalid.")?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| "The connection test state is unavailable")?;
        if self.cancelled.load(Ordering::SeqCst) {
            state.cancel();
            return Err("The connection test was cancelled.".into());
        }
        let result: Result<(), String> = (|| {
            match command {
                Command::Prepare { base_url, model } => {
                    if state.plan.is_some() {
                        return Err(
                            "Create a new connection test before changing its settings.".into()
                        );
                    }
                    match build_ai_connection_test_plan(base_url, model)
                        .and_then(|plan| render_ai_plan(plan, AiWireTransport::ChatCompletions))
                    {
                        Ok(plan) => {
                            state.plan = Some(plan);
                            state.phase = "preview";
                        }
                        Err(error) => state.fail(error),
                    }
                }
                Command::Start { api_key } => {
                    if state.phase != "preview" {
                        return Err("Prepare the connection test before starting it.".into());
                    }
                    let plan = state.plan.clone().ok_or("The connection test is missing")?;
                    let audit = crate::audit::connection_test_observer(
                        crate::document_cache::default_root()?,
                        plan.is_local,
                    );
                    state.started = Some(Instant::now());
                    match start_ai_request_audited(plan, api_key, false, Some(audit)) {
                        Ok(request) => {
                            state.request = Some(request);
                            state.phase = "running";
                        }
                        Err(error) => {
                            state.fail(error);
                            state.finish_time()?;
                        }
                    }
                }
                Command::Poll => {
                    if let Some(request) = state.request.clone() {
                        let mut events = request.poll();
                        let finished = request.is_finished();
                        if finished {
                            // Drain again after observing completion: its terminal event can
                            // have been queued between the first drain and the finished flag.
                            events.extend(request.poll());
                        }
                        for event in events {
                            match event {
                                AiEventRecord::Done => {
                                    state.phase = "success";
                                    break;
                                }
                                AiEventRecord::Error {
                                    message,
                                    cancelled,
                                    failure,
                                    code,
                                } => {
                                    state.phase = if cancelled { "idle" } else { "failed" };
                                    state.message = (!cancelled).then_some(message);
                                    state.code = Some(code);
                                    state.failure = Some(failure);
                                    break;
                                }
                                _ => {} // The probe does not retain answers, reasoning or usage.
                            }
                        }
                        if finished && state.phase == "running" {
                            state.phase = "failed";
                            state.message = Some("The AI request ended without a result.".into());
                            state.code = Some(AiErrorCode::Protocol);
                        }
                        if state.phase != "running" {
                            state.finish_time()?;
                            state.request = None;
                        }
                    }
                }
            }
            Ok(())
        })();
        if self.cancelled.load(Ordering::SeqCst) {
            state.cancel();
        }
        result?;
        Ok(state.snapshot())
    }
}

/// # Safety
/// Error is null or a writable empty Buffer. Free the unique returned service once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_connection_test_new(
    error: *mut Buffer,
) -> *mut Service {
    // SAFETY: the caller provides the documented error buffer; no native pointer is retained.
    unsafe { run(error, || Ok(Box::into_raw(Box::new(Service::default())))) }
        .unwrap_or(ptr::null_mut())
}

/// # Safety
/// Service is null or alive/aligned for the duration of this nonblocking cancellation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_connection_test_cancel(service: *const Service) {
    // SAFETY: the owner retains the service throughout this synchronous borrow.
    if let Some(service) = unsafe { service.as_ref() } {
        service.cancel();
    }
}

/// # Safety
/// Service is null or its unique owner, with no command/cancel borrows outstanding.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_connection_test_free(service: *mut Service) {
    if !service.is_null() {
        // SAFETY: ownership is returned once after all synchronous borrows have ended.
        drop(unsafe { Box::from_raw(service) });
    }
}

/// Worker-only control plane; never accepts a document handle or arbitrary prompt/plan.
/// # Safety
/// Service is alive/aligned; input addresses its readable length. Output/error are
/// distinct writable empty buffers, each freed once with buffer_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_connection_test_command(
    service: *const Service,
    input: *const u8,
    length: usize,
    output: *mut Buffer,
    error: *mut Buffer,
) -> bool {
    // SAFETY: the caller retains all owners and satisfies the documented slice/buffer contracts.
    unsafe {
        run(error, || {
            if length > MAX_COMMAND_BYTES || output.is_null() {
                return Err("The connection test input or output is invalid.".into());
            }
            let service = service.as_ref().ok_or("The connection test is closed.")?;
            let request = serde_json::from_slice(bytes(input, length)?)
                .map_err(|_| "The connection test command is invalid.")?;
            output.write(Buffer::owned(
                serde_json::to_vec(&service.command(request)?).map_err(|e| e.to_string())?,
            ));
            Ok(())
        })
        .is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn c_boundary_checks_lengths_nulls_and_unique_buffer_ownership() {
        // SAFETY: a null error buffer is allowed; the returned service has one owner.
        let service = unsafe { lyra_reader_desktop_connection_test_new(ptr::null_mut()) };
        assert!(!service.is_null());
        for (owner, input, length) in [
            (service.cast_const(), ptr::null(), MAX_COMMAND_BYTES + 1),
            (service.cast_const(), ptr::null(), 1),
            (ptr::null(), ptr::null(), 0),
        ] {
            let mut output = Buffer {
                data: ptr::null_mut(),
                len: 0,
            };
            let mut error = Buffer {
                data: ptr::null_mut(),
                len: 0,
            };
            // SAFETY: invalid slices/handles are deliberately rejected before access;
            // both outputs are live, empty and distinct throughout the call.
            assert!(!unsafe {
                lyra_reader_desktop_connection_test_command(
                    owner,
                    input,
                    length,
                    &mut output,
                    &mut error,
                )
            });
            assert!(output.data.is_null());
            assert!(!error.data.is_null());
            // SAFETY: retire the unique error allocation returned above once.
            unsafe { crate::lyra_reader_desktop_buffer_free(error) };
        }
        // SAFETY: service remains alive, then its unique ownership is returned once.
        unsafe {
            lyra_reader_desktop_connection_test_cancel(service);
            lyra_reader_desktop_connection_test_free(service);
            lyra_reader_desktop_connection_test_free(ptr::null_mut());
        }
    }

    fn prepared() -> (Service, Value) {
        let service = Service::default();
        let state = service.command(json!({"op":"prepare","base_url":"http://127.0.0.1:1/v1","model":"synthetic-probe"})).unwrap();
        (service, state)
    }
    #[test]
    fn fixed_probe_reuses_the_shared_plan_without_document_or_network() {
        let (_, state) = prepared();
        assert_eq!(state["phase"], "preview");
        let plan = &state["plan"];
        let expected = render_ai_plan(
            build_ai_connection_test_plan("http://127.0.0.1:1/v1".into(), "synthetic-probe".into())
                .unwrap(),
            AiWireTransport::ChatCompletions,
        )
        .unwrap();
        assert_eq!(*plan, serde_json::to_value(expected).unwrap());
        let body: Value =
            serde_json::from_str(plan["parts"][0]["wire_body"].as_str().unwrap()).unwrap();
        assert_eq!(body["max_tokens"], 16);
        assert_eq!(body["messages"][1]["content"], "ping");
        assert!(body.get("temperature").is_none());
        assert!(plan["source_pages"].as_array().unwrap().is_empty());
        assert!(plan["sources"].as_array().unwrap().is_empty());
        assert_eq!(plan["history_turns"], 0);
    }
    #[test]
    fn invalid_settings_missing_keys_and_cancel_never_start_a_worker() {
        let service = Service::default();
        let state = service
            .command(json!({"op":"prepare","base_url":"invalid","model":"synthetic-probe"}))
            .unwrap();
        assert_eq!(state["phase"], "failed");
        assert!(service.state.lock().unwrap().request.is_none());
        let (service, _) = prepared();
        let missing = service.command(json!({"op":"start","api_key":""})).unwrap();
        assert_eq!(missing["phase"], "failed");
        assert_eq!(missing["code"], "Unauthorized");
        assert!(service.state.lock().unwrap().request.is_none());
        let (service, _) = prepared();
        service.cancel();
        assert!(
            service
                .command(json!({"op":"start","api_key":"synthetic"}))
                .is_err()
        );
        assert!(service.state.lock().unwrap().request.is_none());
    }
    #[test]
    fn native_caller_cannot_inject_a_plan_document_or_prompt() {
        for key in [
            "plan", "document", "question", "history", "region", "api_key",
        ] {
            let service = Service::default();
            let mut input = json!({"op":"prepare","base_url":"http://127.0.0.1:1/v1","model":"synthetic-probe"});
            input[key] = json!("PRIVATE_SYNTHETIC_MARKER");
            let error = service.command(input).unwrap_err();
            assert!(!error.contains("PRIVATE_SYNTHETIC_MARKER"));
            assert!(service.state.lock().unwrap().request.is_none());
        }
    }
}
