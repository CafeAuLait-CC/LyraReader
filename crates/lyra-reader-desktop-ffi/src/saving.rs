//! Native-shell save composition through the existing verified Rust PDF writers.
use crate::session::SessionDirectory;
use lyra_reader_ffi::api::*;
use serde_json::{Value, json};
use std::{fs, path::Path, sync::Arc};

pub(super) struct PreparedSave {
    pub document: Arc<LyraReaderDocument>,
    pub form_report: Value,
    _directory: Option<SessionDirectory>,
}
pub(super) fn check_revision(document: &LyraReaderDocument, request: &Value) -> Result<(), String> {
    if let Some(expected) = request.get("expected_revision") {
        let expected = expected.as_str().ok_or("Invalid save revision")?;
        if expected != document.path() {
            return Err("The document changed while the save panel was open. Review the changes and choose Save again.".into());
        }
    }
    Ok(())
}

pub(super) fn prepare(
    document: &Arc<LyraReaderDocument>,
    cache: &Path,
    request: &Value,
    password: Option<String>,
) -> Result<PreparedSave, String> {
    check_revision(document, request)?;
    let values: Vec<FormFieldValueRecord> = match request.get("forms") {
        Some(value) => serde_json::from_value(value.clone()).map_err(|e| e.to_string())?,
        None => Vec::new(),
    };
    if values.is_empty() {
        return Ok(PreparedSave {
            document: Arc::clone(document),
            form_report: Value::Null,
            _directory: None,
        });
    }
    let path = cache.join(format!("save-{}", crate::marks::uuid()?));
    let mut options = fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        options.mode(0o700);
    }
    options.create(&path).map_err(|e| e.to_string())?;
    let directory = SessionDirectory::temporary(path);
    let destination = directory
        .path
        .join("filled.pdf")
        .to_string_lossy()
        .into_owned();
    let report = document
        .save_filled_form_copy(destination.clone(), values)
        .map_err(|e| e.to_string())?;
    let document = LyraReaderEngine::new()
        .open_document(destination, password)
        .map_err(|e| e.to_string())?;
    Ok(PreparedSave {
        document,
        form_report: json!(report),
        _directory: Some(directory),
    })
}
