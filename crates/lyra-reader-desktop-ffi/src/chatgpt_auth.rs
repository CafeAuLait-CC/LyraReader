use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::sync::{Arc, Mutex};
use std::thread;

use lyra_reader_ai::chatgpt_sign_in::{
    CatalogModel, ClientId, Credential, LoopbackAuthorization, Registration, exchange, models,
    refresh, revoke,
};
use lyra_reader_ai::openai::CancellationToken;
use serde::{Deserialize, Serialize};

use crate::{Buffer, bytes, run};

const MAX_CONFIGURATION: usize = 2048;

pub struct DesktopChatGptAuth {
    cancel: CancellationToken,
    state: Arc<Mutex<State>>,
}

enum State {
    Pending,
    Ready(Vec<u8>),
    Failed(WorkerFailure),
    Consumed,
}

struct WorkerFailure {
    message: String,
    retry_registration: Option<ClientId>,
}

impl From<String> for WorkerFailure {
    fn from(message: String) -> Self {
        Self {
            message,
            retry_registration: None,
        }
    }
}

fn start_worker(
    work: impl FnOnce(&CancellationToken) -> Result<Vec<u8>, WorkerFailure> + Send + 'static,
) -> Result<Box<DesktopChatGptAuth>, String> {
    let handle = Box::new(DesktopChatGptAuth {
        cancel: CancellationToken::new(),
        state: Arc::new(Mutex::new(State::Pending)),
    });
    let cancel = handle.cancel.clone();
    let state = Arc::clone(&handle.state);
    thread::Builder::new()
        .name("lyra-chatgpt-account".into())
        .spawn(move || {
            let result = catch_unwind(AssertUnwindSafe(|| work(&cancel)));
            let complete = match result {
                Ok(Ok(data)) => State::Ready(data),
                Ok(Err(error)) => State::Failed(error),
                Err(_) => State::Failed("The ChatGPT account worker stopped.".to_owned().into()),
            };
            if let Ok(mut state) = state.lock() {
                *state = complete;
            }
        })
        .map_err(|_| "Could not start the ChatGPT account worker.")?;
    Ok(handle)
}

impl Drop for DesktopChatGptAuth {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Configuration {
    host_id: String,
    client_id: Option<String>,
    email_hint: Option<String>,
    expected_subject: Option<String>,
}

#[derive(Serialize)]
struct SignInResult<'a> {
    client_id: &'a str,
    subject: &'a str,
    email: Option<&'a str>,
    credential: &'a Credential,
    models: &'a [CatalogModel],
    warning: Option<&'a str>,
}

/// Bind the browser callback and start one worker. Returns a system-browser URL.
/// # Safety
/// Input is len readable bytes. Browser URL and error are distinct writable
/// empty buffers, each released once by the caller. The returned handle is
/// owned by the caller and may only be destroyed when no FFI call borrows it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_chatgpt_auth_begin(
    data: *const u8,
    len: usize,
    browser_url: *mut Buffer,
    error: *mut Buffer,
) -> *mut DesktopChatGptAuth {
    // SAFETY: the caller keeps the input and distinct output buffers valid for the call.
    unsafe {
        run(error, || {
            if len > MAX_CONFIGURATION || browser_url.is_null() {
                return Err("Invalid ChatGPT sign-in configuration.".into());
            }
            let config: Configuration = serde_json::from_slice(bytes(data, len)?)
                .map_err(|_| "Invalid ChatGPT sign-in configuration.")?;
            let issued = config
                .client_id
                .as_deref()
                .map(ClientId::parse)
                .transpose()
                .map_err(|error| error.to_string())?;
            let registration = match issued.as_ref() {
                Some(issued_id) => Registration::Reuse {
                    issued_id,
                    email: config.email_hint.as_deref(),
                },
                None => Registration::New,
            };
            let (callback, url) = LoopbackAuthorization::begin(&config.host_id, registration)
                .map_err(|error| error.to_string())?;
            let handle = start_worker(move |cancel| {
                let grant = callback.wait(cancel).map_err(|error| error.to_string())?;
                let retry_registration = config
                    .expected_subject
                    .is_none()
                    .then(|| grant.client().clone());
                let sign_in = exchange(grant, cancel).map_err(|error| WorkerFailure {
                    message: error.to_string(),
                    retry_registration,
                })?;
                if config
                    .expected_subject
                    .as_deref()
                    .is_some_and(|subject| subject != sign_in.identity.subject)
                {
                    return Err(
                        "The signed-in account does not match the selected connection."
                            .to_owned()
                            .into(),
                    );
                }
                let (models, warning) = match models(&sign_in.credential, cancel) {
                    Ok(items) if items.is_empty() => (
                        items,
                        Some("No eligible models were returned for this account.".into()),
                    ),
                    Ok(items) => (items, None),
                    Err(error) => (
                        Vec::new(),
                        Some(format!(
                            "Signed in. Could not load the ChatGPT model catalog: {error}"
                        )),
                    ),
                };
                serde_json::to_vec(&SignInResult {
                    client_id: sign_in.client_id.as_str(),
                    subject: &sign_in.identity.subject,
                    email: sign_in.identity.email.as_deref(),
                    credential: &sign_in.credential,
                    models: &models,
                    warning: warning.as_deref(),
                })
                .map_err(|_| {
                    "Could not encode the ChatGPT sign-in result."
                        .to_owned()
                        .into()
                })
            })?;
            browser_url.write(Buffer::owned(url.into_bytes()));
            Ok(Box::into_raw(handle))
        })
    }
    .unwrap_or(ptr::null_mut())
}

#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case")]
enum SessionOperation {
    Models {
        client_id: String,
        credential: Credential,
    },
    Refresh {
        client_id: String,
        credential: Credential,
    },
    Revoke {
        client_id: String,
        credential: Credential,
    },
}

/// Start a user-authorized catalog read, refresh or revocation using the system vault.
/// # Safety
/// Input has len readable bytes. Error is a distinct writable empty buffer. The
/// caller frees the returned handle and every owned buffer once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_chatgpt_session_begin(
    data: *const u8,
    len: usize,
    error: *mut Buffer,
) -> *mut DesktopChatGptAuth {
    // SAFETY: the caller owns the readable input and the writable error slot for this call.
    unsafe {
        run(error, || {
            if len > 256 * 1024 {
                return Err("Invalid ChatGPT session record.".into());
            }
            let action: SessionOperation = serde_json::from_slice(bytes(data, len)?)
                .map_err(|_| "Invalid ChatGPT session record.")?;
            let handle = start_worker(move |cancel| {
                let result = match action {
                    SessionOperation::Models {
                        client_id,
                        credential,
                    } => {
                        let client =
                            ClientId::parse(&client_id).map_err(|error| error.to_string())?;
                        let now = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .map_err(|_| "Could not read the session clock.".to_owned())?
                            .as_secs();
                        let renew_before = now
                            .checked_add(45)
                            .ok_or_else(|| "The session clock is out of range.".to_owned())?;
                        let credential = if credential.expires_at_unix() <= renew_before {
                            refresh(&client, credential, cancel)
                                .map_err(|error| error.to_string())?
                        } else {
                            credential
                        };
                        let (catalog, warning) = match models(&credential, cancel) {
                            Ok(items) => (Some(items), None),
                            Err(error) => (None, Some(error.to_string())),
                        };
                        // Return a rotated credential even when the catalog fails. The
                        // platform must save it before publishing the catalog or warning.
                        serde_json::to_vec(&serde_json::json!({
                            "credential":credential,"models":catalog,"warning":warning
                        }))
                    }
                    SessionOperation::Refresh {
                        client_id,
                        credential,
                    } => {
                        let client =
                            ClientId::parse(&client_id).map_err(|error| error.to_string())?;
                        let credential = refresh(&client, credential, cancel)
                            .map_err(|error| error.to_string())?;
                        serde_json::to_vec(&credential)
                    }
                    SessionOperation::Revoke {
                        client_id,
                        credential,
                    } => {
                        let client =
                            ClientId::parse(&client_id).map_err(|error| error.to_string())?;
                        let confirmed = revoke(&client, &credential, cancel).is_ok();
                        serde_json::to_vec(&serde_json::json!({"revoked":confirmed}))
                    }
                };
                result.map_err(|_| {
                    "Could not encode the ChatGPT session result."
                        .to_owned()
                        .into()
                })
            })?;
            Ok(Box::into_raw(handle))
        })
    }
    .unwrap_or(ptr::null_mut())
}

/// Poll the worker without doing I/O. Status 0 is pending, 1 is ready, and
/// 2 is failure. Each result is consumed once. A ready result can contain
/// vault material. A sign-in failure may return the issued registration ID
/// so the next explicit attempt can reuse it without treating it as signed in.
/// # Safety
/// Handle remains live. Output and error are distinct writable empty buffers.
/// Each returned allocation must be freed once and never logged.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_chatgpt_auth_poll(
    auth: *const DesktopChatGptAuth,
    output: *mut Buffer,
    error: *mut Buffer,
) -> u32 {
    // SAFETY: the caller keeps the handle alive and owns both writable buffer slots.
    unsafe {
        run(error, || {
            let auth = auth
                .as_ref()
                .ok_or("No ChatGPT sign-in attempt is active.")?;
            if output.is_null() {
                return Err("Missing ChatGPT sign-in result buffer.".into());
            }
            let mut state = auth
                .state
                .lock()
                .map_err(|_| "ChatGPT sign-in state is unavailable.")?;
            if matches!(*state, State::Pending) {
                return Ok(0);
            }
            match std::mem::replace(&mut *state, State::Consumed) {
                State::Ready(bytes) if !auth.cancel.is_cancelled() => {
                    output.write(Buffer::owned(bytes));
                    Ok(1)
                }
                State::Failed(failure) if !auth.cancel.is_cancelled() => {
                    if let Some(registration) = failure.retry_registration {
                        output.write(Buffer::owned(registration.as_str().as_bytes().to_vec()));
                    }
                    Err(failure.message)
                }
                State::Failed(_) => Err("Sign-in cancelled.".into()),
                State::Ready(_) => Err("Sign-in cancelled.".into()),
                State::Consumed | State::Pending => {
                    Err("This ChatGPT sign-in attempt has ended.".into())
                }
            }
        })
    }
    .unwrap_or(2)
}

/// Stop the worker and release its handle. The worker cannot access that allocation.
/// # Safety
/// Handle is null or the one live owned allocation from auth_begin. No callers
/// may continue to access it after this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_chatgpt_auth_free(auth: *mut DesktopChatGptAuth) {
    if !auth.is_null() {
        // SAFETY: this is the caller's unique owned allocation, released once.
        drop(unsafe { Box::from_raw(auth) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failed_exchange_only_exposes_registration_once_for_the_next_attempt() {
        let failure = WorkerFailure {
            message: "Synthetic exchange rejected".into(),
            retry_registration: Some(ClientId::parse("oaiapp_synthetic").unwrap()),
        };
        let handle = DesktopChatGptAuth {
            cancel: CancellationToken::new(),
            state: Arc::new(Mutex::new(State::Failed(failure))),
        };
        let empty_buffer = || Buffer {
            data: ptr::null_mut(),
            len: 0,
        };
        let mut result = empty_buffer();
        let mut error = empty_buffer();
        // SAFETY: The stack handle and two independent output slots stay live for both polls.
        unsafe {
            let status = lyra_reader_desktop_chatgpt_auth_poll(&handle, &mut result, &mut error);
            assert_eq!(status, 2);
            assert_eq!(bytes(result.data, result.len).unwrap(), b"oaiapp_synthetic");
            assert_eq!(
                bytes(error.data, error.len).unwrap(),
                b"Synthetic exchange rejected"
            );
            crate::lyra_reader_desktop_buffer_free(result);
            crate::lyra_reader_desktop_buffer_free(error);
            let mut result = empty_buffer();
            let mut error = empty_buffer();
            assert_eq!(
                lyra_reader_desktop_chatgpt_auth_poll(&handle, &mut result, &mut error),
                2
            );
            assert_eq!(result.len, 0);
            crate::lyra_reader_desktop_buffer_free(error);
        }
    }
}
