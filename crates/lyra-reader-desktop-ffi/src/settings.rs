//! Settings presentation uses the same reasoning parameter as the request builder.
use crate::{Buffer, bytes, run};
use lyra_reader_ai::{
    AiError,
    chat::{ReasoningEncoding, ReasoningMode, inspect_reasoning},
};
use serde::Serialize;
use serde_json::Value;

const MAX_IDENTIFIER_BYTES: usize = 64;

#[derive(Serialize)]
struct Inspection {
    valid: bool,
    field: Option<String>,
    value: Option<Value>,
    code: Option<&'static str>,
    message: String,
}

impl Inspection {
    fn invalid(message: String) -> Self {
        Self {
            valid: false,
            field: None,
            value: None,
            code: Some("invalid_settings"),
            message,
        }
    }
}

fn inspect(mode: &str, encoding: &str) -> Result<Inspection, String> {
    let Some(mode) = ReasoningMode::from_wire(mode) else {
        return Ok(Inspection::invalid(
            "Unrecognized reasoning control. Choose a supported value.".into(),
        ));
    };
    let Some(encoding) = ReasoningEncoding::from_wire(encoding) else {
        return Ok(Inspection::invalid(
            "Unrecognized reasoning encoding. Choose a supported value.".into(),
        ));
    };
    match inspect_reasoning(mode, encoding) {
        Ok(field) => Ok(Inspection {
            valid: true,
            field: field.as_ref().map(|f| f.field.clone()),
            value: field.map(|f| f.value),
            code: None,
            message: String::new(),
        }),
        Err(AiError::InvalidSettings(message)) => Ok(Inspection::invalid(message)),
        Err(error) => Err(error.to_string()),
    }
}

/// Inspect two wire identifiers without document text, network access or storage.
/// # Safety
/// Inputs within the 64-byte limit are readable for their stated lengths;
/// oversized inputs are rejected without access. Output/error are distinct,
/// writable empty buffers and are freed once with buffer_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_inspect_reasoning(
    mode: *const u8,
    mode_len: usize,
    encoding: *const u8,
    encoding_len: usize,
    output: *mut Buffer,
    error: *mut Buffer,
) -> bool {
    // SAFETY: the caller retains both input buffers and the distinct outputs.
    // Reject lengths before forming any slice or allocating an inspection.
    unsafe {
        run(error, || {
            if mode_len > MAX_IDENTIFIER_BYTES
                || encoding_len > MAX_IDENTIFIER_BYTES
                || output.is_null()
            {
                return Err("Invalid reasoning inspection input.".into());
            }
            let mode = std::str::from_utf8(bytes(mode, mode_len)?)
                .map_err(|_| "Invalid reasoning control encoding.")?;
            let encoding = std::str::from_utf8(bytes(encoding, encoding_len)?)
                .map_err(|_| "Invalid reasoning field encoding.")?;
            let inspection = inspect(mode, encoding)?;
            output.write(Buffer::owned(
                serde_json::to_vec(&inspection).map_err(|e| e.to_string())?,
            ));
            Ok(())
        })
    }
    .is_some()
}

#[cfg(test)]
mod tests {
    use super::*;
    use lyra_reader_ai::{ChatSettings, PromptPlanRequest, build_prompt_plan};

    #[test]
    fn inspection_matches_the_actual_request_for_every_reasoning_combination() {
        for mode in ["default", "off", "low", "high", "max"] {
            for encoding in [
                "none",
                "thinking",
                "reasoning_effort",
                "output_config",
                "reasoning.effort",
            ] {
                let shown = inspect(mode, encoding).unwrap();
                let actual = build_prompt_plan(PromptPlanRequest {
                    prompt: "Synthetic settings check".into(),
                    image: None,
                    stream: true,
                    settings: ChatSettings {
                        base_url: "http://127.0.0.1:9/v1".into(),
                        model: "synthetic".into(),
                        reasoning_mode: ReasoningMode::from_wire(mode).unwrap(),
                        reasoning_encoding: ReasoningEncoding::from_wire(encoding).unwrap(),
                        ..ChatSettings::default()
                    },
                });
                match actual {
                    Ok(plan) => {
                        assert!(shown.valid, "{mode}/{encoding}");
                        let body: Value =
                            serde_json::from_str(&plan.chat_completions_body(&plan.parts[0]))
                                .unwrap();
                        for key in ["thinking", "reasoning_effort", "output_config", "reasoning"] {
                            assert_eq!(
                                body.get(key),
                                if shown.field.as_deref() == Some(key) {
                                    shown.value.as_ref()
                                } else {
                                    None
                                },
                                "{mode}/{encoding}/{key}"
                            );
                        }
                    }
                    Err(AiError::InvalidSettings(message)) => {
                        assert!(!shown.valid);
                        assert_eq!(shown.code, Some("invalid_settings"));
                        assert_eq!(shown.message, message);
                        assert!(shown.field.is_none() && shown.value.is_none());
                    }
                    Err(error) => panic!("Unexpected synthetic plan error: {error}"),
                }
            }
        }
        assert!(!inspect("future-mode", "none").unwrap().valid);
        assert!(!inspect("default", "future-encoding").unwrap().valid);
    }

    #[test]
    fn inspection_boundary_validates_before_reading_and_leaves_output_untouched() {
        for (mode, len) in [
            (std::ptr::dangling::<u8>(), MAX_IDENTIFIER_BYTES + 1),
            (std::ptr::null(), 1),
        ] {
            let mut output = Buffer {
                data: std::ptr::null_mut(),
                len: 0,
            };
            let mut error = Buffer {
                data: std::ptr::null_mut(),
                len: 0,
            };
            // SAFETY: oversized input is rejected before dereference; null input
            // is rejected by bytes. The valid encoding and outputs remain live.
            assert!(!unsafe {
                lyra_reader_desktop_inspect_reasoning(
                    mode,
                    len,
                    b"none".as_ptr(),
                    4,
                    &mut output,
                    &mut error,
                )
            });
            assert!(output.data.is_null());
            assert_eq!(output.len, 0);
            assert!(!error.data.is_null());
            // SAFETY: error is the unique allocation returned above.
            unsafe { crate::lyra_reader_desktop_buffer_free(error) };
        }
    }
}
