//! Per-HTTP-attempt metadata only. No provider-controlled strings, document identifiers,
//! filenames, URLs, model names, prompts, answers, image bytes or credentials enter this file.
use fs2::FileExt;
use lyra_reader_ai::{
    AiError,
    openai::{RequestAudit, RequestFailure, RequestOutcome},
};
use lyra_reader_ffi::api::AiActionRecord;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Instant,
};

const MAX_RECORDS: usize = 500;
const MAX_BYTES: usize = 256 * 1024;
#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Action {
    Summarise,
    SelectionQuestion,
    Translation,
    DocumentChat,
    RegionQuestion,
    SummaryLayer,
}
#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Outcome {
    InProgress,
    Sent,
    Failed,
    Cancelled,
}
#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Code {
    HttpError,
    Unauthorized,
    RateLimited,
    Offline,
    LocalServer,
    Unreachable,
    Timeout,
    Protocol,
    Settings,
    Other,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    version: u32,
    id: String,
    at_unix_ms: i64,
    action: Action,
    local: bool,
    outcome: Outcome,
    code: Option<Code>,
    http_status: Option<u16>,
    duration_ms: u64,
}
struct Pending {
    id: String,
    started: Instant,
}
struct Audit {
    directory: PathBuf,
    action: Action,
    local: bool,
    pending: Mutex<Option<Pending>>,
}

fn failure() -> AiError {
    AiError::Other("The local AI audit trail is unavailable or unreadable. Existing records were preserved; check the application cache before sending again.".into())
}
fn valid_id(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == b'-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}
fn read_records(directory: &Path) -> Result<(Vec<Record>, Vec<u8>), AiError> {
    let path = directory.join("ai-requests.jsonl");
    if directory.is_symlink() || path.is_symlink() || directory.join("audit.lock").is_symlink() {
        return Err(failure());
    }
    let mut bytes = Vec::new();
    match fs::File::open(&path) {
        Ok(mut file) => {
            if file.metadata().map_err(|_| failure())?.len() > MAX_BYTES as u64 {
                return Err(failure());
            }
            file.by_ref()
                .take(MAX_BYTES as u64 + 1)
                .read_to_end(&mut bytes)
                .map_err(|_| failure())?;
            if bytes.len() > MAX_BYTES || (!bytes.is_empty() && !bytes.ends_with(b"\n")) {
                return Err(failure());
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err(failure()),
    }
    let mut records = Vec::new();
    let mut ids = HashSet::new();
    for line in bytes.split(|c| *c == b'\n').filter(|l| !l.is_empty()) {
        let record: Record = serde_json::from_slice(line).map_err(|_| failure())?;
        if record.version != 1
            || !valid_id(&record.id)
            || !ids.insert(record.id.to_ascii_lowercase())
            || records.len() >= MAX_RECORDS
        {
            return Err(failure());
        }
        records.push(record);
    }
    Ok((records, bytes))
}
fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// A metadata-only snapshot reads the existing file without creating a directory or lock.
fn snapshot(root: &Path) -> Result<Value, AiError> {
    let (mut records, bytes) = read_records(&root.join("Audit"))?;
    records.reverse();
    Ok(
        json!({"version":1,"records":records,"fingerprint":digest(&bytes),"max_records":MAX_RECORDS,"max_bytes":MAX_BYTES}),
    )
}
/// Additive global control-plane operations; no document, PDFium call or provider is involved.
pub(super) fn query(root: &Path, request: &Value) -> Result<Value, String> {
    let op = request["op"].as_str().ok_or("Invalid audit operation")?;
    match op {
        "audit_records" => snapshot(root).map_err(|e| e.to_string()),
        "audit_clear" => {
            let expected = request["fingerprint"]
                .as_str()
                .filter(|s| s.len() == 64 && s.bytes().all(|c| c.is_ascii_hexdigit()))
                .ok_or("Review the current audit snapshot before clearing it")?;
            mutate(&root.join("Audit"),false,|rows,bytes|{
                if digest(bytes)!=expected{return Err(AiError::Other("The audit trail changed. Refresh and review it before clearing; no entries were removed.".into()));}
                rows.clear();Ok(())
            }).map_err(|e|e.to_string())?;
            snapshot(root).map_err(|e| e.to_string())
        }
        _ => Err("Unknown audit operation".into()),
    }
}

fn update(
    directory: &Path,
    change: impl FnOnce(&mut Vec<Record>) -> Result<(), AiError>,
) -> Result<(), AiError> {
    mutate(directory, true, |rows, _| change(rows))
}
fn mutate(
    directory: &Path,
    wait: bool,
    change: impl FnOnce(&mut Vec<Record>, &[u8]) -> Result<(), AiError>,
) -> Result<(), AiError> {
    if directory.is_symlink() {
        return Err(failure());
    }
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(directory).map_err(|_| failure())?;
    let path = directory.join("ai-requests.jsonl");
    let lock_path = directory.join("audit.lock");
    if path.is_symlink() || lock_path.is_symlink() {
        return Err(failure());
    }
    let mut options = fs::OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let lock = options.open(lock_path).map_err(|_| failure())?;
    if wait {
        FileExt::lock_exclusive(&lock).map_err(|_| failure())?;
    } else {
        // A normal writer may be finishing a rename. Allow a short, bounded worker-side
        // wait, then refuse rather than hanging a UI command behind another process.
        let started = Instant::now();
        loop {
            match FileExt::try_lock_exclusive(&lock) {
                Ok(()) => break,
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                    ) =>
                {
                    if started.elapsed() >= std::time::Duration::from_millis(50) {
                        return Err(AiError::Other(
                            "Another process is updating the audit trail. Refresh and try again."
                                .into(),
                        ));
                    }
                    std::thread::sleep(std::time::Duration::from_millis(5));
                }
                Err(_) => return Err(failure()),
            }
        }
    } // The handle releases its cross-process lock on every exit.
    let (mut records, original) = read_records(directory)?;
    change(&mut records, &original)?;
    while records.len() > MAX_RECORDS {
        records.remove(0);
    }
    let mut bytes = Vec::new();
    for record in &records {
        serde_json::to_writer(&mut bytes, record).map_err(|_| failure())?;
        bytes.push(b'\n');
    }
    while bytes.len() > MAX_BYTES && !records.is_empty() {
        records.remove(0);
        let first = bytes.iter().position(|c| *c == b'\n').ok_or_else(failure)?;
        bytes.drain(..=first);
    }
    crate::document_cache::atomic_write(&path, &bytes).map_err(|_| failure())
}
pub fn observer(root: PathBuf, action: AiActionRecord, local: bool) -> Arc<dyn RequestAudit> {
    let action = match action {
        AiActionRecord::SummarizePage
        | AiActionRecord::SummarizeDocument
        | AiActionRecord::SummarizeSelection => Action::Summarise,
        AiActionRecord::AskSelection => Action::SelectionQuestion,
        AiActionRecord::TranslateSelection => Action::Translation,
        AiActionRecord::DocumentChat => Action::DocumentChat,
        AiActionRecord::RegionQuestion => Action::RegionQuestion,
        AiActionRecord::SummarizeAbstract
        | AiActionRecord::SummarizeSection
        | AiActionRecord::SummarizePageLine => Action::SummaryLayer,
    };
    Arc::new(Audit {
        directory: root.join("Audit"),
        action,
        local,
        pending: Mutex::new(None),
    })
}
impl RequestAudit for Audit {
    fn started(&self) -> Result<(), AiError> {
        let mut pending = self.pending.lock().map_err(|_| failure())?;
        if pending.is_some() {
            return Err(failure());
        }
        let id = crate::marks::uuid().map_err(|_| failure())?;
        update(&self.directory, |rows| {
            rows.push(Record {
                version: 1,
                id: id.clone(),
                at_unix_ms: chrono::Utc::now().timestamp_millis(),
                action: self.action,
                local: self.local,
                outcome: Outcome::InProgress,
                code: None,
                http_status: None,
                duration_ms: 0,
            });
            Ok(())
        })?;
        *pending = Some(Pending {
            id,
            started: Instant::now(),
        });
        Ok(())
    }
    fn finished(&self, outcome: RequestOutcome) -> Result<(), AiError> {
        let mut pending = self.pending.lock().map_err(|_| failure())?;
        let Some(current) = pending.as_ref() else {
            return Ok(());
        };
        let duration =
            u64::try_from(current.started.elapsed().as_millis()).map_err(|_| failure())?;
        update(&self.directory, |rows| {
            // A long-running attempt may have rotated out. Finishing it must not revive it.
            if let Some(row) = rows.iter_mut().find(|r| r.id == current.id) {
                row.duration_ms = duration;
                match outcome {
                    RequestOutcome::Sent => row.outcome = Outcome::Sent,
                    RequestOutcome::Cancelled => row.outcome = Outcome::Cancelled,
                    RequestOutcome::HttpError(status) => {
                        row.outcome = Outcome::Failed;
                        row.code = Some(Code::HttpError);
                        row.http_status = Some(status);
                    }
                    RequestOutcome::Failed(code) => {
                        row.outcome = Outcome::Failed;
                        row.code = Some(match code {
                            RequestFailure::Unauthorized => Code::Unauthorized,
                            RequestFailure::RateLimited => Code::RateLimited,
                            RequestFailure::Offline => Code::Offline,
                            RequestFailure::LocalServer => Code::LocalServer,
                            RequestFailure::Unreachable => Code::Unreachable,
                            RequestFailure::Timeout => Code::Timeout,
                            RequestFailure::Protocol => Code::Protocol,
                            RequestFailure::Settings => Code::Settings,
                            RequestFailure::Other => Code::Other,
                        });
                    }
                }
            }
            Ok(())
        })?;
        *pending = None;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn snapshots_are_read_only_and_clear_requires_the_exact_reviewed_metadata() {
        let root = std::env::temp_dir().join(format!(
            "lyra-reader-audit-view-{}",
            crate::marks::uuid().unwrap()
        ));
        fs::create_dir(&root).unwrap();
        let empty = query(&root, &serde_json::json!({"op":"audit_records"})).unwrap();
        assert_eq!(empty["records"].as_array().unwrap().len(), 0);
        assert!(!root.join("Audit").exists());
        let audit = observer(root.clone(), AiActionRecord::RegionQuestion, true);
        audit.started().unwrap();
        audit.finished(RequestOutcome::HttpError(400)).unwrap();
        let path = root.join("Audit/ai-requests.jsonl");
        let before = fs::read(&path).unwrap();
        let first = query(&root, &serde_json::json!({"op":"audit_records"})).unwrap();
        assert_eq!(fs::read(&path).unwrap(), before);
        assert_eq!(first["records"][0]["http_status"], 400);
        audit.started().unwrap();
        audit.finished(RequestOutcome::Cancelled).unwrap();
        let two = fs::read(&path).unwrap();
        assert!(
            query(
                &root,
                &serde_json::json!({"op":"audit_clear","fingerprint":first["fingerprint"]})
            )
            .unwrap_err()
            .contains("changed")
        );
        assert_eq!(fs::read(&path).unwrap(), two);
        let current = query(&root, &serde_json::json!({"op":"audit_records"})).unwrap();
        let clear = query(
            &root,
            &serde_json::json!({"op":"audit_clear","fingerprint":current["fingerprint"]}),
        )
        .unwrap();
        assert!(clear["records"].as_array().unwrap().is_empty());
        assert!(fs::read(&path).unwrap().is_empty());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn corrupt_or_duplicate_metadata_is_never_cleared_or_reinterpreted_as_empty() {
        let root = std::env::temp_dir().join(format!(
            "lyra-reader-audit-corrupt-{}",
            crate::marks::uuid().unwrap()
        ));
        let audit = observer(root.clone(), AiActionRecord::DocumentChat, false);
        audit.started().unwrap();
        audit.finished(RequestOutcome::Sent).unwrap();
        let path = root.join("Audit/ai-requests.jsonl");
        let good = fs::read(&path).unwrap();
        for bad in [
            b"incomplete metadata".to_vec(),
            [good.clone(), good.clone()].concat(),
            vec![b'x'; MAX_BYTES + 1],
        ] {
            fs::write(&path, &bad).unwrap();
            assert!(query(&root, &serde_json::json!({"op":"audit_records"})).is_err());
            assert!(
                query(
                    &root,
                    &serde_json::json!({"op":"audit_clear","fingerprint":digest(&bad)})
                )
                .is_err()
            );
            assert_eq!(fs::read(&path).unwrap(), bad);
        }
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn explicitly_cleared_inflight_records_are_not_revived_on_completion() {
        let root = std::env::temp_dir().join(format!(
            "lyra-reader-audit-clear-live-{}",
            crate::marks::uuid().unwrap()
        ));
        let audit = observer(root.clone(), AiActionRecord::AskSelection, true);
        audit.started().unwrap();
        let view = query(&root, &serde_json::json!({"op":"audit_records"})).unwrap();
        query(
            &root,
            &serde_json::json!({"op":"audit_clear","fingerprint":view["fingerprint"]}),
        )
        .unwrap();
        audit.finished(RequestOutcome::Sent).unwrap();
        assert!(
            query(&root, &serde_json::json!({"op":"audit_records"})).unwrap()["records"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn document_free_global_commands_run_in_an_isolated_process() {
        let root = std::env::temp_dir().join(format!(
            "lyra-reader-audit-global-{}",
            crate::marks::uuid().unwrap()
        ));
        fs::create_dir(&root).unwrap();
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "audit::tests::document_free_global_command_worker",
                "--ignored",
                "--nocapture",
            ])
            .env("LYRA_READER_DOCUMENT_CACHE_DIR", &root)
            .env("LYRA_READER_AUDIT_GLOBAL_WORKER", "1")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stdout)
        );
        assert!(!root.join("Audit").exists());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    #[ignore = "launched only by the parent with its isolated cache root"]
    fn document_free_global_command_worker() {
        if std::env::var("LYRA_READER_AUDIT_GLOBAL_WORKER")
            .ok()
            .as_deref()
            != Some("1")
        {
            return;
        }
        let input = serde_json::to_vec(&serde_json::json!({"op":"audit_records"})).unwrap();
        let mut output = crate::Buffer {
            data: std::ptr::null_mut(),
            len: 0,
        };
        let mut error = crate::Buffer {
            data: std::ptr::null_mut(),
            len: 0,
        };
        // SAFETY: only the documented global query uses a null document. Input owns its
        // stated bytes and both buffers are unique writable empty values until freed below.
        unsafe {
            assert!(crate::lyra_reader_desktop_command(
                std::ptr::null(),
                input.as_ptr(),
                input.len(),
                &mut output,
                &mut error
            ));
            let decoded: serde_json::Value =
                serde_json::from_slice(std::slice::from_raw_parts(output.data, output.len))
                    .unwrap();
            assert_eq!(decoded["result"]["version"], 1);
            assert!(decoded["result"]["records"].as_array().unwrap().is_empty());
            crate::lyra_reader_desktop_buffer_free(output);
            crate::lyra_reader_desktop_buffer_free(error);
        }
    }
    #[test]
    fn records_rotate_atomically_and_corruption_blocks_requests_without_overwriting() {
        let root = std::env::temp_dir().join(format!(
            "lyra-reader-audit-{}",
            crate::marks::uuid().unwrap()
        ));
        let audit = observer(root.clone(), AiActionRecord::RegionQuestion, true);
        for _ in 0..503 {
            audit.started().unwrap();
            audit.finished(RequestOutcome::Sent).unwrap();
        }
        let path = root.join("Audit/ai-requests.jsonl");
        let bytes = fs::read(&path).unwrap();
        assert!(bytes.len() <= MAX_BYTES);
        assert_eq!(
            bytes
                .split(|c| *c == b'\n')
                .filter(|l| !l.is_empty())
                .count(),
            MAX_RECORDS
        );
        fs::write(&path, b"{bad metadata\n").unwrap();
        assert!(audit.started().is_err());
        assert_eq!(fs::read(&path).unwrap(), b"{bad metadata\n");
        fs::write(&path, vec![0; MAX_BYTES + 1]).unwrap();
        assert!(audit.started().is_err());
        assert_eq!(fs::metadata(&path).unwrap().len(), MAX_BYTES as u64 + 1);
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn independent_jobs_serialize_their_updates_without_losing_records() {
        let root = std::env::temp_dir().join(format!(
            "lyra-reader-audit-{}",
            crate::marks::uuid().unwrap()
        ));
        std::thread::scope(|scope| {
            for _ in 0..4 {
                let root = root.clone();
                scope.spawn(move || {
                    let audit = observer(root, AiActionRecord::DocumentChat, true);
                    for _ in 0..8 {
                        audit.started().unwrap();
                        audit.finished(RequestOutcome::Cancelled).unwrap();
                    }
                });
            }
        });
        let bytes = fs::read(root.join("Audit/ai-requests.jsonl")).unwrap();
        let rows: Vec<Record> = bytes
            .split(|c| *c == b'\n')
            .filter(|l| !l.is_empty())
            .map(|l| serde_json::from_slice(l).unwrap())
            .collect();
        assert_eq!(rows.len(), 32);
        assert!(rows.iter().all(|r| matches!(r.outcome, Outcome::Cancelled)));
        let mut children = Vec::new();
        for _ in 0..4 {
            children.push(
                std::process::Command::new(std::env::current_exe().unwrap())
                    .args([
                        "--ignored",
                        "--exact",
                        "audit::tests::process_worker_writes_metadata",
                    ])
                    .env("LYRA_READER_AUDIT_FIXTURE_ROOT", &root)
                    .stdout(std::process::Stdio::piped())
                    .stderr(std::process::Stdio::piped())
                    .spawn()
                    .unwrap(),
            );
        }
        for child in children {
            let result = child.wait_with_output().unwrap();
            assert!(
                result.status.success(),
                "{}",
                String::from_utf8_lossy(&result.stderr)
            );
        }
        let bytes = fs::read(root.join("Audit/ai-requests.jsonl")).unwrap();
        let rows: Vec<Record> = bytes
            .split(|c| *c == b'\n')
            .filter(|l| !l.is_empty())
            .map(|l| serde_json::from_slice(l).unwrap())
            .collect();
        assert_eq!(rows.len(), 96);
        assert!(rows.iter().all(|r| matches!(r.outcome, Outcome::Cancelled)));
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    #[ignore = "subprocess fixture executed by the multi-process audit regression"]
    fn process_worker_writes_metadata() {
        let root = PathBuf::from(
            std::env::var_os("LYRA_READER_AUDIT_FIXTURE_ROOT").expect("parent-owned scratch"),
        );
        assert!(
            root.is_absolute()
                && root
                    .file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with("lyra-reader-audit-")
        );
        let audit = observer(root, AiActionRecord::DocumentChat, true);
        for _ in 0..16 {
            audit.started().unwrap();
            audit.finished(RequestOutcome::Cancelled).unwrap();
        }
    }
}
