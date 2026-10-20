//! The native shells share the macOS sidecar format, including verbatim future entries.
use lyra_reader_ffi::api::*;
use serde_json::{Value, json, value::RawValue};
use std::{
    collections::HashSet,
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
const MAX_SIDECAR_BYTES: usize = 16 * 1024 * 1024;
const MAX_HISTORY_BYTES: usize = 32 * 1024 * 1024;
static WRITES: std::sync::Mutex<()> = std::sync::Mutex::new(());

const ANNOTATION_KEYS: &[&str] = &[
    "id",
    "kind",
    "page",
    "start",
    "end",
    "color",
    "colorIndex",
    "note",
    "createdAt",
    "version",
    "paths",
    "rect",
    "lineStart",
    "lineEnd",
    "strokeWidth",
    "fontSize",
    "fileIdentity",
    "quads",
    "textAlignment",
    "stampStyle",
    "image",
];
const BOOKMARK_KEYS: &[&str] = &["id", "kind", "page", "title", "yPt", "createdAt"];
const LEGACY_COLORS: [&str; 8] = [
    "#FFD84066",
    "#70D06066",
    "#60A0F066",
    "#E070B066",
    "#FFA04066",
    "#A080F066",
    "#40C0C066",
    "#9098A066",
];
const KINDS: &[&str] = &[
    "highlight",
    "underline",
    "strikeout",
    "ink",
    "square",
    "circle",
    "line",
    "arrow",
    "stickyNote",
    "textBox",
    "stamp",
    "signature",
];

#[derive(Clone)]
enum Entry {
    Known(Value),
    Opaque(Box<RawValue>),
}
#[derive(Clone)]
struct Snapshot {
    embedded_bookmarks: HashSet<String>,
    bytes: usize,
    entries: Vec<Entry>,
    deletions: Vec<AnnotationDeleteRecord>,
}
#[derive(Clone)]
pub struct Marks {
    embedded_bookmarks: HashSet<String>,
    path: PathBuf,
    baseline: Option<Vec<u8>>,
    entries: Vec<Entry>,
    deletions: Vec<AnnotationDeleteRecord>,
    undo: Vec<Snapshot>,
    redo: Vec<Snapshot>,
    pub error: Option<String>,
    page_count: u32,
}
pub struct Payload {
    pub annotations: Vec<WriteAnnotationRecord>,
    pub bookmarks: Vec<WriteBookmarkRecord>,
    pub updates: Vec<AnnotationUpdateRecord>,
    pub deletions: Vec<AnnotationDeleteRecord>,
    pub ids: HashSet<String>,
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
        - 978_307_200.0
}
pub(super) fn uuid() -> Result<String, String> {
    let mut b = [0u8; 16];
    getrandom::fill(&mut b).map_err(|e| e.to_string())?;
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    Ok(format!(
        "{:02X}{:02X}{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}",
        b[0],
        b[1],
        b[2],
        b[3],
        b[4],
        b[5],
        b[6],
        b[7],
        b[8],
        b[9],
        b[10],
        b[11],
        b[12],
        b[13],
        b[14],
        b[15]
    ))
}
fn valid_uuid(s: &str) -> bool {
    s.len() == 36
        && s.bytes().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == b'-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}
fn number(v: &Value, k: &str) -> Result<f64, String> {
    v[k].as_f64()
        .filter(|x| x.is_finite())
        .ok_or_else(|| format!("Invalid {k}"))
}
fn string(v: &Value, k: &str) -> Result<String, String> {
    v[k].as_str()
        .map(str::to_string)
        .ok_or_else(|| format!("Missing {k}"))
}
fn rect(v: &Value) -> Result<(), String> {
    number(v, "x")?;
    number(v, "y")?;
    if number(v, "width")? <= 0.0 || number(v, "height")? <= 0.0 {
        return Err("Invalid annotation rectangle".into());
    }
    Ok(())
}
fn point(v: &Value) -> Result<(), String> {
    number(v, "x")?;
    number(v, "y")?;
    Ok(())
}
fn color(v: &Value) -> Option<String> {
    if let Some(s) = v["color"].as_str().filter(|s| {
        s.len() == 9 && s.starts_with('#') && s[1..].bytes().all(|c| c.is_ascii_hexdigit())
    }) {
        return Some(s.to_uppercase());
    }
    v["colorIndex"]
        .as_u64()
        .and_then(|i| LEGACY_COLORS.get(i as usize))
        .map(|s| s.to_string())
}
fn kind(v: &Value) -> &str {
    v["kind"].as_str().unwrap_or("highlight")
}
fn validate(v: &Value, pages: u32) -> Result<bool, String> {
    let object = v.as_object().ok_or("Sidecar entry is not an object")?;
    let k = kind(v);
    let keys = if k == "bookmark" {
        BOOKMARK_KEYS
    } else {
        ANNOTATION_KEYS
    };
    if object.keys().any(|key| !keys.contains(&key.as_str())) {
        return Ok(false);
    }
    if k != "bookmark" {
        if !KINDS.contains(&k) || color(v).is_none() {
            return Ok(false);
        }
        let geometry = [
            "ink",
            "square",
            "circle",
            "line",
            "arrow",
            "stickyNote",
            "textBox",
            "stamp",
            "signature",
        ]
        .contains(&k);
        if geometry && v["version"].as_u64() != Some(1) || !geometry && v.get("version").is_some() {
            return Ok(false);
        }
    }
    if !valid_uuid(&string(v, "id")?) {
        return Err("Invalid sidecar identity".into());
    }
    if v["page"]
        .as_u64()
        .filter(|p| *p < u64::from(pages))
        .is_none()
    {
        return Err("Sidecar page is outside the document".into());
    }
    number(v, "createdAt")?;
    if k == "bookmark" {
        string(v, "title")?;
        if number(v, "yPt")? < 0.0 {
            return Err("Invalid bookmark position".into());
        }
        return Ok(true);
    }
    string(v, "note")?;
    match k {
        "highlight" | "underline" | "strikeout" => {
            if v["start"].as_u64().is_none()
                || v["end"].as_u64().is_none()
                || v["end"].as_u64() < v["start"].as_u64()
            {
                return Err("Invalid text annotation range".into());
            }
        }
        "ink" => {
            let paths = v["paths"].as_array().ok_or("Missing ink paths")?;
            if paths.is_empty() {
                return Err("Empty ink paths".into());
            }
            for path in paths {
                let points = path.as_array().ok_or("Invalid ink path")?;
                if points.len() < 2 {
                    return Err("An ink path needs two points".into());
                }
                for p in points {
                    point(p)?
                }
            }
            if number(v, "strokeWidth")? <= 0.0 {
                return Err("Invalid stroke width".into());
            }
        }
        "square" | "circle" => {
            rect(&v["rect"])?;
            if number(v, "strokeWidth")? <= 0.0 {
                return Err("Invalid stroke width".into());
            }
        }
        "line" | "arrow" => {
            point(&v["lineStart"])?;
            point(&v["lineEnd"])?;
            if number(v, "strokeWidth")? <= 0.0 {
                return Err("Invalid stroke width".into());
            }
        }
        "stickyNote" | "textBox" => {
            rect(&v["rect"])?;
            number(v, "fontSize")?;
        }
        "stamp" => {
            rect(&v["rect"])?;
            if string(v, "note")?.trim().is_empty() {
                return Err("A stamp needs text".into());
            }
            if !matches!(
                v["stampStyle"].as_str().unwrap_or("custom"),
                "approved" | "reviewed" | "draft" | "confidential" | "date" | "custom"
            ) {
                return Ok(false);
            }
        }
        "signature" => {
            rect(&v["rect"])?;
            if !string(v, "note")?.is_empty() {
                return Err("A signature image cannot carry stamp text".into());
            }
            crate::artwork::dimensions(&string(v, "image")?)?;
        }
        _ => {}
    }
    if let Some(quads) = v.get("quads") {
        for q in quads.as_array().ok_or("Invalid quads")? {
            rect(q)?
        }
    }
    Ok(true)
}

impl Marks {
    pub fn can_stage(&self, operation: &PageOperationRecord) -> Result<(), String> {
        if let Some(error) = &self.error {
            return Err(error.clone());
        }
        if self.entries.iter().any(|e| matches!(e, Entry::Opaque(_))) {
            return Err("The sidecar contains entries from another version whose pages cannot be remapped safely. Page editing is disabled.".into());
        }
        let rotating = match operation {
            PageOperationRecord::Rotate { pages, .. }
            | PageOperationRecord::SetRotation { pages, .. } => Some(pages),
            _ => None,
        };
        if let Some(pages) = rotating
            && self.entries.iter().any(|e| {
                matches!(e,Entry::Known(v)
                if pages.contains(&(v["page"].as_u64().unwrap_or(u64::MAX) as u32))
                && !v["id"].as_str().is_some_and(|id| self.embedded_bookmarks.contains(id)))
            })
        {
            return Err("These pages have sidecar annotations or bookmarks. Save the marks inside the PDF before rotating, so their text positions cannot move to different words.".into());
        }
        Ok(())
    }
    pub fn validate_export(&self, remapping: bool) -> Result<(), String> {
        if let Some(error) = &self.error {
            return Err(format!("The annotation sidecar cannot be read: {error}"));
        }
        if remapping && self.entries.iter().any(|e| matches!(e, Entry::Opaque(_))) {
            return Err(
                "The sidecar contains unknown entries whose pages cannot be remapped safely".into(),
            );
        }
        if !self.deletions.is_empty() {
            return Err(
                "Write pending file annotation deletions to a PDF before merging or splitting"
                    .into(),
            );
        }
        Ok(())
    }
    pub fn appended_copy(
        &self,
        path: &Path,
        old: &LyraReaderDocument,
        new: &LyraReaderDocument,
    ) -> Result<Self, String> {
        let map: Vec<_> = (0..old.page_count()).map(Some).collect();
        self.copy_with_map(path, &map, old, new, true)
    }
    pub fn staging_copy(
        &self,
        path: &Path,
        map: &[Option<u32>],
        old: &LyraReaderDocument,
        new: &LyraReaderDocument,
    ) -> Result<Self, String> {
        self.copy_with_map(path, map, old, new, false)
    }
    fn copy_with_map(
        &self,
        path: &Path,
        map: &[Option<u32>],
        old: &LyraReaderDocument,
        new: &LyraReaderDocument,
        allow_opaque: bool,
    ) -> Result<Self, String> {
        let old_file = old.annotations().map_err(|e| e.to_string())?;
        let new_file = new.annotations().map_err(|e| e.to_string())?;
        let identity = |id: &str, page: u32, new_page: u32| -> Result<String, String> {
            if !id.starts_with("fp:") {
                return Ok(id.to_string());
            }
            let list: Vec<_> = old_file.iter().filter(|a| a.page == page).collect();
            let index = list
                .iter()
                .position(|a| a.id == id)
                .ok_or("An adopted annotation is missing from the source")?;
            let new_list: Vec<_> = new_file.iter().filter(|a| a.page == new_page).collect();
            let a = list[index];
            let b = new_list
                .get(index)
                .ok_or("An adopted annotation is missing from the edited page")?;
            if a.kind != b.kind || a.contents != b.contents {
                return Err(
                    "An adopted annotation could not be matched safely after the page edit".into(),
                );
            }
            Ok(b.id.clone())
        };
        let mut result = self.clone();
        result.path = PathBuf::from(format!("{}.lyra-reader-annotations.json", path.display()));
        result.baseline = None;
        result.page_count = new.page_count();
        result.undo.clear();
        result.redo.clear();
        let mut entries = vec![];
        for entry in &self.entries {
            let Entry::Known(v) = entry else {
                if allow_opaque {
                    entries.push(entry.clone());
                    continue;
                }
                return Err("Unsupported sidecar entry".into());
            };
            if v["id"]
                .as_str()
                .is_some_and(|id| self.embedded_bookmarks.contains(id))
            {
                continue; // Reload embedded destinations from the transformed outline below.
            }
            let mut v = v.clone();
            let page = v["page"].as_u64().unwrap() as u32;
            if let Some(Some(next)) = map.get(page as usize) {
                v["page"] = json!(next);
                if let Some(id) = v["fileIdentity"].as_str() {
                    v["fileIdentity"] = json!(identity(id, page, *next)?);
                }
                entries.push(Entry::Known(v));
            }
        }
        result.entries = entries;
        result.embedded_bookmarks.clear();
        result.seed_bookmarks(new)?;
        result.deletions = self
            .deletions
            .iter()
            .filter_map(|d| {
                map.get(d.page as usize)
                    .copied()
                    .flatten()
                    .map(|page| (d, page))
            })
            .map(|(d, page)| {
                Ok(AnnotationDeleteRecord {
                    target: identity(&d.target, d.page, page)?,
                    page,
                })
            })
            .collect::<Result<_, String>>()?;
        result.persist()?;
        Ok(result)
    }
    pub fn clear_redo(&mut self) {
        self.redo.clear();
    }
    pub fn publish_page_revision<T>(
        &self,
        original: &Self,
        publish: impl FnOnce() -> Result<T, String>,
    ) -> Result<(T, Self, Option<PathBuf>), String> {
        let mut prepared = self.clone();
        prepared.path = original
            .path
            .with_extension(format!("json.prepared-{}", uuid()?));
        prepared.baseline = None;
        prepared.persist()?;
        let _write_guard = WRITES.lock().map_err(|_| "Sidecar writer is unavailable")?;
        let current = if original.path.exists() {
            Some(fs::read(&original.path).map_err(|e| e.to_string())?)
        } else {
            None
        };
        if current != original.baseline {
            let _ = fs::remove_file(&prepared.path);
            return Err("The original sidecar changed during page editing. The original PDF was not replaced.".into());
        }
        let backup = if let Some(bytes) = current {
            let path = original
                .path
                .with_extension(format!("json.page-backup-{}", uuid()?));
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options.open(&path).map_err(|e| e.to_string())?;
            file.set_permissions(
                fs::metadata(&original.path)
                    .map_err(|e| e.to_string())?
                    .permissions(),
            )
            .map_err(|e| e.to_string())?;
            file.write_all(&bytes)
                .and_then(|_| file.sync_all())
                .map_err(|e| e.to_string())?;
            if fs::read(&path).map_err(|e| e.to_string())? != bytes {
                return Err("Sidecar backup verification failed".into());
            }
            Some(path)
        } else {
            None
        };
        let report = match publish() {
            Ok(report) => report,
            Err(error) => {
                let _ = fs::remove_file(&prepared.path);
                return Err(error);
            }
        };
        let mut result = self.clone();
        result.path = original.path.clone();
        result.baseline = prepared.baseline.clone();
        result.undo.clear();
        result.redo.clear();
        if let Err(error) = fs::rename(&prepared.path, &original.path) {
            result.error = Some(format!(
                "The PDF was saved, but the remapped sidecar could not be published: {error}. Recovery data: {}",
                prepared.path.display()
            ));
        }
        Ok((report, result, backup))
    }
    pub fn payload(&self, document: &LyraReaderDocument) -> Result<Payload, String> {
        if let Some(error) = &self.error {
            return Err(format!("Sidecar writes are blocked: {error}"));
        }
        let file = document.annotations().map_err(|e| e.to_string())?;
        let mut result = Payload {
            annotations: vec![],
            bookmarks: vec![],
            updates: vec![],
            deletions: self.deletions.clone(),
            ids: HashSet::new(),
        };
        for entry in &self.entries {
            let Entry::Known(v) = entry else { continue };
            let id = string(v, "id")?;
            result.ids.insert(id.clone());
            if kind(v) == "bookmark" {
                result.bookmarks.push(WriteBookmarkRecord {
                    id,
                    page: v["page"].as_u64().unwrap() as u32,
                    title: string(v, "title")?,
                    y_pt: number(v, "yPt")?,
                });
                continue;
            }
            let quads = Self::quads(v, document)?;
            let read_point = |value: &Value| -> Result<AnnotationPoint, String> {
                Ok(AnnotationPoint {
                    x_pt: number(value, "x")?,
                    y_pt: number(value, "y")?,
                })
            };
            let paths: Vec<Vec<AnnotationPoint>> = if let Some(paths) = v["paths"].as_array() {
                paths
                    .iter()
                    .map(|path| {
                        path.as_array()
                            .ok_or("Invalid path".to_string())?
                            .iter()
                            .map(read_point)
                            .collect()
                    })
                    .collect::<Result<_, String>>()?
            } else {
                vec![]
            };
            let line_start = v.get("lineStart").map(read_point).transpose()?;
            let line_end = v.get("lineEnd").map(read_point).transpose()?;
            let mut bounds = if let Some(r) = v.get("rect") {
                AnnotationQuad {
                    x_pt: number(r, "x")?,
                    y_pt: number(r, "y")?,
                    width_pt: number(r, "width")?,
                    height_pt: number(r, "height")?,
                }
            } else if let Some(q) = quads.first() {
                *q
            } else {
                let points: Vec<_> = paths
                    .iter()
                    .flatten()
                    .chain(line_start.iter())
                    .chain(line_end.iter())
                    .collect();
                if points.is_empty() {
                    return Err("Annotation has no geometry".into());
                }
                let left = points.iter().map(|p| p.x_pt).fold(f64::INFINITY, f64::min);
                let top = points.iter().map(|p| p.y_pt).fold(f64::INFINITY, f64::min);
                let right = points
                    .iter()
                    .map(|p| p.x_pt)
                    .fold(f64::NEG_INFINITY, f64::max);
                let bottom = points
                    .iter()
                    .map(|p| p.y_pt)
                    .fold(f64::NEG_INFINITY, f64::max);
                AnnotationQuad {
                    x_pt: left,
                    y_pt: top,
                    width_pt: (right - left).max(0.1),
                    height_pt: (bottom - top).max(0.1),
                }
            };
            for q in &quads {
                let right = (bounds.x_pt + bounds.width_pt).max(q.x_pt + q.width_pt);
                let bottom = (bounds.y_pt + bounds.height_pt).max(q.y_pt + q.height_pt);
                bounds.x_pt = bounds.x_pt.min(q.x_pt);
                bounds.y_pt = bounds.y_pt.min(q.y_pt);
                bounds.width_pt = right - bounds.x_pt;
                bounds.height_pt = bottom - bounds.y_pt;
            }
            let c = color(v).ok_or("Invalid annotation colour")?;
            let component =
                |offset| u8::from_str_radix(&c[offset..offset + 2], 16).map_err(|e| e.to_string());
            let write_kind = match kind(v) {
                "highlight" => AnnotationWriteKind::Highlight,
                "underline" => AnnotationWriteKind::Underline,
                "strikeout" => AnnotationWriteKind::StrikeOut,
                "stickyNote" => AnnotationWriteKind::Note,
                "textBox" => AnnotationWriteKind::FreeText,
                "ink" => AnnotationWriteKind::Ink,
                "square" => AnnotationWriteKind::Square,
                "circle" => AnnotationWriteKind::Circle,
                "stamp" => AnnotationWriteKind::Stamp,
                "signature" => AnnotationWriteKind::Signature,
                _ => AnnotationWriteKind::Line,
            };
            let (signature_width, signature_height, signature_rgba) = if kind(v) == "signature" {
                crate::artwork::pixels(&string(v, "image")?)?
            } else {
                (0, 0, Vec::new())
            };
            let annotation = WriteAnnotationRecord {
                id: id.clone(),
                page: v["page"].as_u64().unwrap() as u32,
                kind: write_kind,
                rect: bounds,
                quads,
                ink_paths: paths,
                line_start,
                line_end,
                line_arrow: kind(v) == "arrow",
                border_width_pt: v["strokeWidth"].as_f64().unwrap_or(1.0),
                color: AnnotationColorRecord {
                    red: component(1)?,
                    green: component(3)?,
                    blue: component(5)?,
                },
                opacity: f64::from(component(7)?) / 255.0,
                contents: string(v, "note")?,
                author: String::new(),
                modified: chrono::Utc::now().format("D:%Y%m%d%H%M%SZ").to_string(),
                font_size_pt: v["fontSize"].as_f64().unwrap_or(14.0),
                text_alignment: v["textAlignment"].as_str().unwrap_or("left").to_string(),
                stamp_style: v["stampStyle"].as_str().unwrap_or("custom").into(),
                signature_width,
                signature_height,
                signature_rgba,
            };
            let target = v["fileIdentity"].as_str().map(str::to_string).or_else(|| {
                file.iter()
                    .find(|a| a.id == format!("nm:{id}"))
                    .map(|a| a.id.clone())
            });
            if let Some(target) = target {
                let assign_name = target.starts_with("fp:").then(|| id.clone());
                result.updates.push(AnnotationUpdateRecord {
                    target,
                    annotation,
                    assign_name,
                });
            } else {
                result.annotations.push(annotation);
            }
        }
        Ok(result)
    }
    pub fn clear_saved(&mut self, ids: &HashSet<String>) -> Result<(), String> {
        let old = self.snapshot();
        self.entries.retain(
            |e| !matches!(e,Entry::Known(v)if v["id"].as_str().is_some_and(|id|ids.contains(id))),
        );
        self.deletions.clear();
        if let Err(error) = self.persist() {
            self.restore(old);
            return Err(error);
        }
        self.undo.clear();
        self.redo.clear();
        Ok(())
    }
    pub fn seed_bookmarks(&mut self, document: &LyraReaderDocument) -> Result<(), String> {
        if self.error.is_some() {
            return Ok(());
        }
        let mut identities = HashSet::new();
        for entry in &self.entries {
            let value = match entry {
                Entry::Known(v) => v.clone(),
                Entry::Opaque(raw) => serde_json::from_str(raw.get()).map_err(|e| e.to_string())?,
            };
            if let Some(id) = value["id"].as_str() {
                identities.insert(id.to_uppercase());
            }
        }
        for outline in document.outline().map_err(|e| e.to_string())? {
            if let (Some(id), Some(page)) = (outline.bookmark_id, outline.page)
                && valid_uuid(&id)
            {
                let y = outline.y_pt.unwrap_or(0.0);
                if identities.insert(id.to_uppercase()) {
                    self.entries.push(Entry::Known(json!({"id":id,"kind":"bookmark","page":page,"title":outline.title,"yPt":y,"createdAt":now()})));
                    self.embedded_bookmarks.insert(id);
                } else if let Some(Entry::Known(v)) = self.entries.iter().find(|e|
                    matches!(e,Entry::Known(v) if v["id"].as_str().is_some_and(|s| s.eq_ignore_ascii_case(&id))))
                    && kind(v) == "bookmark" && v["page"] == page && v["title"] == outline.title
                    && v["yPt"].as_f64().is_some_and(|old| (old-y).abs() < 0.01)
                {
                    self.embedded_bookmarks.insert(v["id"].as_str().unwrap().to_string());
                }
            }
        }
        Ok(())
    }
    pub fn load(document: &Path, page_count: u32) -> Self {
        let current = PathBuf::from(format!(
            "{}.lyra-reader-annotations.json",
            document.display()
        ));
        let legacy = PathBuf::from(format!("{}.aris-annotations.json", document.display()));
        let path = if !current.exists() && legacy.exists() {
            legacy
        } else {
            current
        };
        let mut result = Self {
            embedded_bookmarks: HashSet::new(),
            path,
            baseline: None,
            entries: vec![],
            deletions: vec![],
            undo: vec![],
            redo: vec![],
            error: None,
            page_count,
        };
        let parsed = (|| -> Result<(), String> {
            if !result.path.exists() {
                return Ok(());
            }
            if fs::metadata(&result.path).map_err(|e| e.to_string())?.len()
                > MAX_SIDECAR_BYTES as u64
            {
                return Err("Sidecar exceeds the 16 MiB limit".into());
            }
            let bytes = fs::read(&result.path).map_err(|e| e.to_string())?;
            let raw: Vec<Box<RawValue>> = serde_json::from_slice(&bytes)
                .map_err(|e| format!("Invalid annotation sidecar: {e}"))?;
            let mut ids = HashSet::new();
            for entry in raw {
                let value: Value = serde_json::from_str(entry.get()).map_err(|e| e.to_string())?;
                if validate(&value, page_count)? {
                    let identity = string(&value, "id")?.to_uppercase();
                    if !ids.insert(identity) {
                        return Err("Duplicate sidecar identity".into());
                    }
                    result.entries.push(Entry::Known(value));
                } else {
                    result.entries.push(Entry::Opaque(entry))
                }
            }
            result.baseline = Some(bytes);
            Ok(())
        })();
        if let Err(error) = parsed {
            result.entries.clear();
            result.error = Some(error)
        }
        result
    }
    pub fn page_snapshot(&self) -> Self {
        let mut result = self.clone();
        result.undo.clear();
        result.redo.clear();
        result
    }
    pub fn storage_bytes(&self) -> usize {
        self.entries
            .iter()
            .map(|e| match e {
                Entry::Known(v) => serde_json::to_vec(v).map_or(0, |b| b.len()),
                Entry::Opaque(v) => v.get().len(),
            })
            .sum::<usize>()
            + self
                .deletions
                .iter()
                .map(|d| d.target.len() + 32)
                .sum::<usize>()
    }
    fn trim_history(history: &mut Vec<Snapshot>) {
        let mut bytes = history.iter().map(|s| s.bytes).sum::<usize>();
        while history.len() > 1 && (history.len() > 200 || bytes > MAX_HISTORY_BYTES) {
            bytes = bytes.saturating_sub(history.remove(0).bytes);
        }
    }
    fn snapshot(&self) -> Snapshot {
        Snapshot {
            embedded_bookmarks: self.embedded_bookmarks.clone(),
            bytes: self.storage_bytes(),
            entries: self.entries.clone(),
            deletions: self.deletions.clone(),
        }
    }
    fn restore(&mut self, s: Snapshot) {
        self.embedded_bookmarks = s.embedded_bookmarks;
        self.entries = s.entries;
        self.deletions = s.deletions;
    }
    fn persist(&mut self) -> Result<(), String> {
        let _write_guard = WRITES.lock().map_err(|_| "Sidecar writer is unavailable")?;
        if let Some(error) = &self.error {
            return Err(format!("Sidecar writes are blocked: {error}"));
        }
        let current = if self.path.exists() {
            Some(fs::read(&self.path).map_err(|e| e.to_string())?)
        } else {
            None
        };
        if current != self.baseline {
            return Err(
                "The sidecar changed outside this window. Reopen the document before saving."
                    .into(),
            );
        }
        let elements = self
            .entries
            .iter()
            .map(|e| match e {
                Entry::Known(v) => serde_json::to_string(v).unwrap(),
                Entry::Opaque(raw) => raw.get().to_string(),
            })
            .collect::<Vec<_>>();
        let bytes = format!("[\n{}\n]\n", elements.join(",\n")).into_bytes();
        if bytes.len() > MAX_SIDECAR_BYTES {
            return Err("Sidecar exceeds the 16 MiB limit; this change was not saved".into());
        }
        if self.baseline.as_ref() == Some(&bytes) {
            return Ok(());
        }
        let temporary = self.path.with_extension(format!("json.{}.tmp", uuid()?));
        let result = (|| -> Result<(), String> {
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options.open(&temporary).map_err(|e| e.to_string())?;
            if let Ok(metadata) = fs::metadata(&self.path) {
                file.set_permissions(metadata.permissions())
                    .map_err(|e| e.to_string())?
            }
            file.write_all(&bytes)
                .and_then(|_| file.sync_all())
                .map_err(|e| e.to_string())?;
            fs::rename(&temporary, &self.path).map_err(|e| e.to_string())?;
            if let Some(parent) = self.path.parent()
                && let Ok(directory) = fs::File::open(parent)
            {
                let _ = directory.sync_all();
            }
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result?;
        self.baseline = Some(bytes);
        Ok(())
    }
    fn change(&mut self, task: impl FnOnce(&mut Self) -> Result<(), String>) -> Result<(), String> {
        if let Some(error) = &self.error {
            return Err(error.clone());
        }
        let old = self.snapshot();
        if let Err(error) = task(self).and_then(|_| self.persist()) {
            self.restore(old);
            return Err(error);
        }
        self.undo.push(old);
        self.redo.clear();
        Self::trim_history(&mut self.undo);
        Ok(())
    }
    pub fn state(&self, document: &LyraReaderDocument) -> Result<Value, String> {
        let file = document.annotations().map_err(|e| e.to_string())?;
        let mut own = vec![];
        let mut bookmarks = vec![];
        for entry in &self.entries {
            if let Entry::Known(v) = entry {
                if kind(v) == "bookmark" {
                    bookmarks.push(v.clone())
                } else {
                    own.push(self.display(v, document)?);
                }
            }
        }
        let mut adopted: HashSet<String> = own
            .iter()
            .filter_map(|v| v["fileIdentity"].as_str().map(str::to_string))
            .chain(
                own.iter()
                    .filter_map(|v| v["id"].as_str().map(str::to_string)),
            )
            .collect();
        for v in &own {
            if let Some(id) = v["id"].as_str() {
                adopted.insert(format!("nm:{id}"));
            }
        }
        // The writer removes a deleted parent's entire /IRT descendant chain.
        // Mirror that closure in the staged UI, including replies to replies.
        let mut children = std::collections::HashMap::<&str, Vec<&str>>::new();
        for a in &file {
            if a.is_reply
                && let Some(parent) = a.parent_id.as_deref()
            {
                children.entry(parent).or_default().push(a.id.as_str());
            }
        }
        let mut deleted: HashSet<&str> = self.deletions.iter().map(|d| d.target.as_str()).collect();
        let mut pending: Vec<&str> = deleted.iter().copied().collect();
        while let Some(parent) = pending.pop() {
            if let Some(replies) = children.get(parent) {
                for &reply in replies {
                    if deleted.insert(reply) {
                        pending.push(reply);
                    }
                }
            }
        }
        let removed: HashSet<String> = deleted.into_iter().map(str::to_owned).collect();
        let file: Vec<_> = file
            .into_iter()
            .filter(|a| !adopted.contains(&a.id) && !removed.contains(&a.id))
            .collect();
        let file = crate::artwork::annotations(file)?;
        Ok(
            json!({"annotations":own,"file_annotations":file,"bookmarks":bookmarks,"can_undo":!self.undo.is_empty(),"can_redo":!self.redo.is_empty(),"preserved":self.entries.iter().filter(|e|matches!(e,Entry::Opaque(_))).count(),"error":self.error,"path":self.path,"pdf_dirty":!own.is_empty()||!self.deletions.is_empty(),"pending_deletions":self.deletions.len()}),
        )
    }
    fn display(&self, v: &Value, document: &LyraReaderDocument) -> Result<Value, String> {
        let mut value = v.clone();
        let c = color(v).ok_or("Invalid annotation colour")?;
        value["color"] = Value::String(c);
        value["quads"] =
            serde_json::to_value(Self::quads(v, document)?).map_err(|e| e.to_string())?;
        Ok(value)
    }
    fn quads(v: &Value, document: &LyraReaderDocument) -> Result<Vec<AnnotationQuad>, String> {
        if let Some(quads) = v["quads"].as_array() {
            return quads
                .iter()
                .map(|r| {
                    Ok(AnnotationQuad {
                        x_pt: number(r, "x")?,
                        y_pt: number(r, "y")?,
                        width_pt: number(r, "width")?,
                        height_pt: number(r, "height")?,
                    })
                })
                .collect();
        }
        if !["highlight", "underline", "strikeout"].contains(&kind(v)) {
            return Ok(vec![]);
        }
        let page = document
            .text_page(v["page"].as_u64().unwrap() as u32)
            .map_err(|e| e.to_string())?;
        let start = v["start"].as_u64().unwrap() as usize;
        let end = v["end"].as_u64().unwrap() as usize;
        if end >= page.chars.len() {
            return Err("Annotation text range is outside the page. Writes are blocked.".into());
        }
        Ok(page.chars[start..=end]
            .iter()
            .filter(|c| c.width_pt > 0.0 && c.height_pt > 0.0)
            .map(|c| AnnotationQuad {
                x_pt: c.x_pt,
                y_pt: c.y_pt,
                width_pt: c.width_pt,
                height_pt: c.height_pt,
            })
            .collect())
    }
    pub fn command(
        &mut self,
        op: &str,
        r: &Value,
        document: &LyraReaderDocument,
    ) -> Result<Value, String> {
        let mut selected_id = None;
        match op {
            "marks" => {}
            "mark_create" => {
                let mut entry = r["entry"].clone();
                entry["id"] = json!(uuid()?);
                selected_id = entry["id"].as_str().map(str::to_string);
                entry["createdAt"] = json!(now());
                if !validate(&entry, self.page_count)? {
                    return Err("Unsupported annotation schema".into());
                }
                Self::quads(&entry, document)?;
                self.change(|s| {
                    s.entries.push(Entry::Known(entry));
                    Ok(())
                })?;
            }
            "bookmark_create" => {
                let entry = json!({"id":uuid()?,"kind":"bookmark","page":r["page"],"title":r["title"],"yPt":r.get("yPt").cloned().unwrap_or(json!(0)),"createdAt":now()});
                validate(&entry, self.page_count)?;
                self.change(|s| {
                    s.entries.push(Entry::Known(entry));
                    Ok(())
                })?;
            }
            "mark_update" | "bookmark_update" => {
                let id = string(r, "id")?;
                let patch = r["patch"]
                    .as_object()
                    .ok_or("Missing annotation changes")?
                    .clone();
                self.change(|s| {
                    s.embedded_bookmarks.remove(&id);
                    let v = s
                        .entries
                        .iter_mut()
                        .find_map(|e| match e {
                            Entry::Known(v) if v["id"] == id => Some(v),
                            _ => None,
                        })
                        .ok_or("Annotation not found")?;
                    for (k, value) in patch {
                        if k == "id" || k == "createdAt" {
                            return Err("Annotation identity is immutable".into());
                        }
                        v[k] = value;
                    }
                    if !validate(v, s.page_count)? {
                        return Err("Unsupported annotation changes".into());
                    }
                    Self::quads(v, document)?;
                    Ok(())
                })?;
            }
            "mark_delete" | "bookmark_delete" => {
                let id = string(r, "id")?;
                let file = document.annotations().map_err(|e| e.to_string())?;
                self.change(|s| {
                    let target = s.entries.iter().find_map(|e| match e {
                        Entry::Known(v) if v["id"] == id => v["fileIdentity"]
                            .as_str()
                            .map(str::to_string)
                            .or_else(|| {
                                file.iter()
                                    .find(|a| a.id == format!("nm:{id}"))
                                    .map(|a| a.id.clone())
                            })
                            .map(|target| AnnotationDeleteRecord {
                                target,
                                page: v["page"].as_u64().unwrap_or(0) as u32,
                            }),
                        _ => None,
                    });
                    if let Some(deletion) = target {
                        s.deletions.push(deletion);
                    }
                    let before = s.entries.len();
                    s.entries
                        .retain(|e| !matches!(e,Entry::Known(v)if v["id"]==id));
                    if s.entries.len() == before {
                        return Err("Annotation not found".into());
                    }
                    Ok(())
                })?;
            }
            "bookmark_move" => {
                let id = string(r, "id")?;
                let delta = r["delta"].as_i64().ok_or("Invalid bookmark move")?;
                self.change(|s| {
                    let positions: Vec<_> = s
                        .entries
                        .iter()
                        .enumerate()
                        .filter_map(|(i, e)| {
                            if matches!(e,Entry::Known(v)if kind(v)=="bookmark") {
                                Some(i)
                            } else {
                                None
                            }
                        })
                        .collect();
                    let index = positions
                        .iter()
                        .position(|i| matches!(&s.entries[*i],Entry::Known(v)if v["id"]==id))
                        .ok_or("Bookmark not found")?;
                    let next = (index as i64 + delta).clamp(0, positions.len() as i64 - 1) as usize;
                    s.entries.swap(positions[index], positions[next]);
                    Ok(())
                })?;
            }
            "marks_undo" | "marks_redo" => {
                let previous = if op == "marks_undo" {
                    self.undo.pop()
                } else {
                    self.redo.pop()
                }
                .ok_or("No change to undo")?;
                let current = self.snapshot();
                self.restore(previous.clone());
                if let Err(e) = self.persist() {
                    self.restore(current);
                    if op == "marks_undo" {
                        self.undo.push(previous)
                    } else {
                        self.redo.push(previous)
                    }
                    return Err(e);
                }
                if op == "marks_undo" {
                    self.redo.push(current)
                } else {
                    self.undo.push(current)
                }
                Self::trim_history(&mut self.undo);
                Self::trim_history(&mut self.redo);
            }
            "file_delete" => {
                let id = string(r, "id")?;
                let records = document.annotations().map_err(|e| e.to_string())?;
                let record = records
                    .iter()
                    .find(|a| a.id == id)
                    .ok_or("File annotation not found")?;
                if record.is_reply {
                    return Err(
                        "Edit or delete the annotation at the top of this reply thread".into(),
                    );
                }
                let deletion = AnnotationDeleteRecord {
                    target: id,
                    page: record.page,
                };
                self.change(|s| {
                    if !s.deletions.iter().any(|d| d.target == deletion.target) {
                        s.deletions.push(deletion)
                    }
                    Ok(())
                })?;
            }
            "marks_erase" => {
                let ids: Vec<String> =
                    serde_json::from_value(r["ids"].clone()).map_err(|e| e.to_string())?;
                let file = document.annotations().map_err(|e| e.to_string())?;
                self.change(|s| {
                    for id in ids {
                        let own = s.entries.iter().position(
                            |e| matches!(e,Entry::Known(v)if v["id"]==id && kind(v)=="ink"),
                        );
                        if let Some(index) = own {
                            if let Entry::Known(v) = &s.entries[index]
                                && let Some(target) = v["fileIdentity"].as_str()
                            {
                                s.deletions.push(AnnotationDeleteRecord {
                                    target: target.to_string(),
                                    page: v["page"].as_u64().unwrap() as u32,
                                });
                            }
                            s.entries.remove(index);
                        } else if let Some(a) = file
                            .iter()
                            .find(|a| a.id == id && a.kind == "ink" && !a.is_reply && a.visible)
                        {
                            if !s.deletions.iter().any(|d| d.target == id) {
                                s.deletions.push(AnnotationDeleteRecord {
                                    target: id,
                                    page: a.page,
                                });
                            }
                        } else {
                            return Err("Only whole ink strokes can be erased".into());
                        }
                    }
                    Ok(())
                })?;
            }
            "file_adopt" => {
                let id = string(r, "id")?;
                let records = document.annotations().map_err(|e| e.to_string())?;
                let a = records
                    .iter()
                    .find(|a| a.id == id)
                    .ok_or("File annotation not found")?;
                if a.is_reply {
                    return Err(
                        "Replies stay attached to their thread and cannot be adopted separately"
                            .into(),
                    );
                }
                if !a.visible || a.drawing == "skipped" {
                    return Err("This file annotation is hidden or not drawn".into());
                }
                let k = match a.kind.as_str() {
                    "stamp"
                        if a.stamp.as_ref().is_some_and(|s| {
                            s.text.as_deref().is_some_and(|t| !t.trim().is_empty())
                        }) =>
                    {
                        "stamp"
                    }
                    "stamp" if a.stamp.as_ref().is_some_and(|s| !s.image.is_empty()) => "signature",
                    "line" if a.line_arrow => "arrow",
                    "text" => "stickyNote",
                    "freeText" => "textBox",
                    kind if KINDS.contains(&kind) => kind,
                    _ => {
                        return Err(
                            "This annotation kind can be deleted but cannot be edited".into()
                        );
                    }
                };
                let existing = self.entries.iter().find_map(|e| match e {
                    Entry::Known(v) if v["fileIdentity"] == id => {
                        v["id"].as_str().map(str::to_string)
                    }
                    _ => None,
                });
                let selected = if let Some(existing) = existing {
                    existing
                } else {
                    let identity = uuid()?;
                    let c = a.color.unwrap_or(AnnotationColorRecord {
                        red: 232,
                        green: 188,
                        blue: 85,
                    });
                    let mut entry = json!({"id":identity,"kind":k,"page":a.page,"note":a.contents.clone().unwrap_or_default(),"createdAt":now(),"color":format!("#{:02X}{:02X}{:02X}{:02X}",c.red,c.green,c.blue,(a.opacity.unwrap_or(1.0).clamp(0.0,1.0)*255.0).round()as u8),"fileIdentity":id});
                    let p = |v: &AnnotationPoint| json!({"x":v.x_pt,"y":v.y_pt});
                    match k {
                        "highlight" | "underline" | "strikeout" => {
                            entry["start"] = json!(0);
                            entry["end"] = json!(0);
                            let quads = if a.quads.is_empty() {
                                vec![AnnotationQuad {
                                    x_pt: a.x_pt,
                                    y_pt: a.y_pt,
                                    width_pt: a.width_pt,
                                    height_pt: a.height_pt,
                                }]
                            } else {
                                a.quads.clone()
                            };
                            entry["quads"]=json!(quads.iter().map(|q|json!({"x":q.x_pt,"y":q.y_pt,"width":q.width_pt,"height":q.height_pt})).collect::<Vec<_>>());
                        }
                        "ink" => {
                            entry["version"] = json!(1);
                            entry["paths"] = json!(
                                a.ink_paths
                                    .iter()
                                    .map(|path| path.iter().map(p).collect::<Vec<_>>())
                                    .collect::<Vec<_>>()
                            );
                            entry["strokeWidth"] = json!(a.border_width_pt.unwrap_or(2.0).max(0.1));
                        }
                        "line" | "arrow" => {
                            entry["version"] = json!(1);
                            entry["lineStart"] =
                                a.line_start.as_ref().map(p).ok_or("Missing line start")?;
                            entry["lineEnd"] =
                                a.line_end.as_ref().map(p).ok_or("Missing line end")?;
                            entry["strokeWidth"] = json!(a.border_width_pt.unwrap_or(2.0).max(0.1));
                        }
                        _ => {
                            entry["version"] = json!(1);
                            entry["rect"] = json!({"x":a.x_pt,"y":a.y_pt,"width":a.width_pt.max(1.0),"height":a.height_pt.max(1.0)});
                            if k == "stickyNote" || k == "textBox" {
                                entry["fontSize"] = json!(a.font_size_pt.unwrap_or(14.0));
                                entry["textAlignment"] = json!(a.alignment);
                            } else if k == "stamp" {
                                let stamp = a.stamp.as_ref().ok_or("Missing stamp artwork")?;
                                entry["note"] = json!(stamp.text.clone().unwrap_or_default());
                                entry["stampStyle"] = json!(match stamp.style.as_str() {
                                    "approved" | "reviewed" | "draft" | "confidential" | "date" =>
                                        stamp.style.as_str(),
                                    _ => "custom",
                                });
                            } else if k == "signature" {
                                let stamp = a.stamp.as_ref().ok_or("Missing signature artwork")?;
                                entry["note"] = json!("");
                                entry["stampStyle"] = json!("signature");
                                entry["image"] = json!(crate::artwork::encode(&stamp.image));
                            } else {
                                entry["strokeWidth"] =
                                    json!(a.border_width_pt.unwrap_or(2.0).max(0.1));
                            }
                        }
                    }
                    if !validate(&entry, self.page_count)? {
                        return Err("Unsupported file annotation geometry".into());
                    }
                    self.change(|s| {
                        s.entries.push(Entry::Known(entry));
                        Ok(())
                    })?;
                    identity
                };
                let mut state = self.state(document)?;
                state["selected_id"] = json!(selected);
                return Ok(state);
            }
            "marks_recover" => {
                let bytes = fs::read(&self.path).map_err(|e| e.to_string())?;
                let backup = self.path.with_extension(format!("json.backup-{}", uuid()?));
                fs::copy(&self.path, &backup).map_err(|e| e.to_string())?;
                if fs::read(&backup).map_err(|e| e.to_string())? != bytes {
                    return Err("Sidecar backup verification failed".into());
                }
                self.error = None;
                self.baseline = Some(bytes);
                self.entries.clear();
                self.deletions.clear();
                self.embedded_bookmarks.clear();
                self.undo.clear();
                self.redo.clear();
                self.persist()?;
            }
            _ => return Err("Unknown mark operation".into()),
        }
        let mut state = self.state(document)?;
        if let Some(id) = selected_id {
            state["selected_id"] = json!(id);
        }
        Ok(state)
    }
}
