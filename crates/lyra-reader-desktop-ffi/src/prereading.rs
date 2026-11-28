//! Desktop lifecycle vocabulary adapted to the shared document-reading policy.
use crate::{Buffer, bytes, run};
use lyra_reader_ai::{understanding::needs_prior, workspace::reading_gate};
use serde::Serialize;

const MAX_IDENTIFIER_BYTES: usize = 64;
pub(super) const BUSY: &str = "Document prereading is in progress. Continue when Lyra AI is ready.";

#[derive(Debug, Serialize)]
pub(super) struct Gate {
    valid: bool,
    pub(super) decision: String,
    needs_prior: bool,
}

pub(super) fn inspect(policy: &str, phase: &str, ready: bool, kind: &str) -> Result<Gate, String> {
    // Preview is the desktop lane's consent phase. Starting/stopping retain
    // admission until their worker command publishes the next state.
    let portable = match phase {
        "" | "idle" | "ready" | "failed" => phase,
        "skipped" => "skipped",
        "preparing" | "preview" | "starting" | "stopping" => "preparing",
        "reading" => "reading",
        _ => return Err("Unknown document prereading state.".into()),
    };
    let prior = needs_prior(kind);
    // Summary/translation/note do not consume this preference. They still
    // observe an active analysis even when a future saved policy is unknown.
    let shared = reading_gate(if prior { policy } else { "never" }, portable, ready)?;
    let decision = if shared == "wait" {
        shared
    } else if !prior {
        "ready".into()
    } else if phase == "failed" {
        "paused".into()
    } else {
        shared
    };
    Ok(Gate {
        valid: true,
        decision,
        needs_prior: prior,
    })
}

/// Inspect bounded wire identifiers without document text, I/O or credentials.
/// # Safety
/// Inputs within the 64-byte limit are readable for their stated lengths.
/// Output/error are distinct writable empty buffers, freed once with buffer_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_prereading_gate(
    policy: *const u8,
    policy_len: usize,
    phase: *const u8,
    phase_len: usize,
    ready: bool,
    kind: *const u8,
    kind_len: usize,
    output: *mut Buffer,
    error: *mut Buffer,
) -> bool {
    // SAFETY: the caller retains inputs and distinct outputs; validate lengths
    // before forming any input slice or allocating a serialized result.
    unsafe {
        run(error, || {
            if [policy_len, phase_len, kind_len]
                .into_iter()
                .any(|length| length > MAX_IDENTIFIER_BYTES)
                || output.is_null()
            {
                return Err("Invalid document prereading input.".into());
            }
            let policy = std::str::from_utf8(bytes(policy, policy_len)?)
                .map_err(|_| "Invalid document prereading policy encoding.")?;
            let phase = std::str::from_utf8(bytes(phase, phase_len)?)
                .map_err(|_| "Invalid document prereading state encoding.")?;
            let kind = std::str::from_utf8(bytes(kind, kind_len)?)
                .map_err(|_| "Invalid document prereading task encoding.")?;
            let gate = inspect(policy, phase, ready, kind)?;
            output.write(Buffer::owned(
                serde_json::to_vec(&gate).map_err(|error| error.to_string())?,
            ));
            Ok(())
        })
    }
    .is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn through_abi(policy: &[u8], phase: &[u8], kind: &[u8]) -> Result<serde_json::Value, String> {
        let mut output = Buffer {
            data: std::ptr::null_mut(),
            len: 0,
        };
        let mut error = Buffer {
            data: std::ptr::null_mut(),
            len: 0,
        };
        // SAFETY: slices retain readable inputs and the two live empty outputs
        // are distinct. Returned owned buffers are copied, then freed once.
        unsafe {
            let ok = lyra_reader_desktop_prereading_gate(
                policy.as_ptr(),
                policy.len(),
                phase.as_ptr(),
                phase.len(),
                false,
                kind.as_ptr(),
                kind.len(),
                &mut output,
                &mut error,
            );
            let result = if ok {
                serde_json::from_slice(std::slice::from_raw_parts(output.data, output.len))
                    .map_err(|error| error.to_string())
            } else {
                assert!(output.data.is_null());
                Err(
                    String::from_utf8(std::slice::from_raw_parts(error.data, error.len).to_vec())
                        .unwrap(),
                )
            };
            crate::lyra_reader_desktop_buffer_free(output);
            crate::lyra_reader_desktop_buffer_free(error);
            result
        }
    }

    #[test]
    fn actual_abi_owns_its_result_and_rejects_unknown_or_invalid_encodings() {
        assert_eq!(
            through_abi(b"ask", b"idle", b"question").unwrap(),
            serde_json::json!({"valid":true,"decision":"ask","needs_prior":true})
        );
        assert_eq!(
            through_abi(b"never", b"preview", b"summary").unwrap()["decision"],
            "wait"
        );
        assert!(
            through_abi(b"future", b"idle", b"question")
                .unwrap_err()
                .contains("preference")
        );
        assert!(
            through_abi(&[255], b"idle", b"question")
                .unwrap_err()
                .contains("policy encoding")
        );
        assert!(
            through_abi(b"ask", &[255], b"question")
                .unwrap_err()
                .contains("state encoding")
        );
        assert!(
            through_abi(b"ask", b"idle", &[255])
                .unwrap_err()
                .contains("task encoding")
        );
    }

    #[test]
    fn desktop_lifecycle_preserves_the_shared_policy_and_task_exemptions() {
        for policy in ["ask", "always", "never"] {
            for phase in ["preparing", "preview", "starting", "reading", "stopping"] {
                for kind in ["question", "term", "summary", "translation", "note"] {
                    assert_eq!(inspect(policy, phase, true, kind).unwrap().decision, "wait");
                }
            }
            for kind in ["summary", "translation", "note"] {
                assert_eq!(
                    inspect(policy, "idle", false, kind).unwrap().decision,
                    "ready"
                );
                assert_eq!(
                    inspect(policy, "failed", false, kind).unwrap().decision,
                    "ready"
                );
            }
            assert_eq!(
                inspect(policy, "ready", true, "question").unwrap().decision,
                "ready"
            );
            assert_eq!(
                inspect(policy, "skipped", false, "question")
                    .unwrap()
                    .decision,
                "ready"
            );
            assert_eq!(
                inspect(policy, "failed", false, "question")
                    .unwrap()
                    .decision,
                "paused"
            );
        }
        for kind in ["summary", "translation", "note"] {
            assert_eq!(
                inspect("future", "idle", false, kind).unwrap().decision,
                "ready"
            );
            assert_eq!(
                inspect("future", "preview", false, kind).unwrap().decision,
                "wait"
            );
        }
        assert_eq!(
            inspect("ask", "idle", false, "question").unwrap().decision,
            "ask"
        );
        assert_eq!(
            inspect("always", "idle", false, "question")
                .unwrap()
                .decision,
            "read"
        );
        assert_eq!(
            inspect("never", "idle", false, "question")
                .unwrap()
                .decision,
            "ready"
        );
        assert!(inspect("future", "idle", false, "question").is_err());
        assert!(inspect("never", "future", false, "question").is_err());
    }

    #[test]
    fn oversized_inputs_are_rejected_before_pointer_access() {
        for lengths in [[65, 0, 0], [0, 65, 0], [0, 0, 65]] {
            let mut output = Buffer {
                data: std::ptr::null_mut(),
                len: 0,
            };
            let mut error = Buffer {
                data: std::ptr::null_mut(),
                len: 0,
            };
            // SAFETY: oversized null input must be rejected before access; empty
            // outputs are live, distinct and released once below.
            assert!(!unsafe {
                lyra_reader_desktop_prereading_gate(
                    std::ptr::null(),
                    lengths[0],
                    std::ptr::null(),
                    lengths[1],
                    false,
                    std::ptr::null(),
                    lengths[2],
                    &mut output,
                    &mut error,
                )
            });
            assert!(output.data.is_null());
            // SAFETY: error is the sole owned allocation returned by this call.
            unsafe {
                crate::lyra_reader_desktop_buffer_free(error);
            }
        }
    }
}
