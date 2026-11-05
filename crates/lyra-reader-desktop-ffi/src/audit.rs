//! Per-HTTP-attempt metadata only. No provider-controlled strings, document identifiers,
//! filenames, URLs, model names, prompts, answers, image bytes or credentials enter this file.
use fs2::FileExt;
use lyra_reader_ai::{
    AiError,
    openai::{RequestAudit, RequestFailure, RequestOutcome},
};
use lyra_reader_ffi::api::AiActionRecord;
use serde::{Deserialize, Serialize};
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
fn update(
    directory: &Path,
    change: impl FnOnce(&mut Vec<Record>) -> Result<(), AiError>,
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
    FileExt::lock_exclusive(&lock).map_err(|_| failure())?; // The handle releases its cross-process lock on every exit.
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
    for line in bytes.split(|c| *c == b'\n').filter(|l| !l.is_empty()) {
        let record: Record = serde_json::from_slice(line).map_err(|_| failure())?;
        if record.version != 1 || !valid_id(&record.id) || records.len() >= MAX_RECORDS {
            return Err(failure());
        }
        records.push(record);
    }
    change(&mut records)?;
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
