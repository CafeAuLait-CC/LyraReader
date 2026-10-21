//! One transient, ordered eraser transaction. Preview and commit share the same splitters.
use super::*;
use lyra_reader_core::Point;
use lyra_reader_session::ink::InkStrokeSplitter;

#[derive(Clone)]
pub(super) struct Gesture {
    token: String,
    source_page: u64,
    page_count: u32,
    targets: Vec<Target>,
}
#[derive(Clone)]
struct Target {
    id: String,
    base: Value,
    file: Option<AnnotationDeleteRecord>,
    splitters: Vec<InkStrokeSplitter>,
    blocked: bool,
    changed: bool,
    refused: bool,
}
fn point(v: &Value) -> Result<Point, String> {
    Ok(Point::new(number(v, "x")?, number(v, "y")?))
}
fn paths(v: &Value) -> Result<Vec<Vec<Point>>, String> {
    v.as_array()
        .ok_or("Missing ink paths")?
        .iter()
        .map(|p| {
            p.as_array()
                .ok_or("Invalid ink path")?
                .iter()
                .map(point)
                .collect()
        })
        .collect()
}
fn attached(a: &AnnotationRecord, note: &str, file: &[AnnotationRecord]) -> bool {
    a.is_reply
        || a.has_popup
        || !note.trim().is_empty()
        || file
            .iter()
            .any(|reply| reply.is_reply && reply.parent_id.as_deref() == Some(&a.id))
}
impl Target {
    fn new(
        base: Value,
        file: Option<&AnnotationRecord>,
        records: &[AnnotationRecord],
        zoom: f64,
    ) -> Result<Self, String> {
        let id = string(&base, "id")?;
        let blocked = file
            .is_some_and(|a| attached(a, base["note"].as_str().unwrap_or(""), records))
            || base["fileIdentity"].is_string() && file.is_none();
        let reach = base["strokeWidth"].as_f64().unwrap_or(2.0).max(0.0) / 2.0 + 8.0 / zoom;
        let splitters = paths(&base["paths"])?
            .into_iter()
            .map(|p| InkStrokeSplitter::new(p, reach))
            .collect();
        Ok(Self {
            id,
            base,
            file: file.map(|a| AnnotationDeleteRecord {
                target: a.id.clone(),
                page: a.page,
            }),
            splitters,
            blocked,
            changed: false,
            refused: false,
        })
    }
    fn survivors(&self) -> Vec<Vec<Point>> {
        self.splitters
            .iter()
            .flat_map(InkStrokeSplitter::surviving_paths)
            .filter(|p| p.len() >= 2)
            .collect()
    }
    fn piece(&self, path: &[Point], id: String) -> Value {
        let mut value = self.base.clone();
        value.as_object_mut().unwrap().remove("fileIdentity");
        value["id"] = json!(id);
        value["paths"] = json!([path
            .iter()
            .map(|p| json!({"x":p.x,"y":p.y}))
            .collect::<Vec<_>>()]);
        value
    }
}
impl Gesture {
    fn update(&mut self, r: &Value) -> Result<Value, String> {
        let segments = r["segments"].as_array().ok_or("Missing eraser segments")?;
        if segments.len() > 512 {
            return Err("Too many eraser samples in one batch".into());
        }
        let segments = segments
            .iter()
            .map(|s| {
                let page = s["page"].as_u64().unwrap_or(self.source_page);
                if page >= u64::from(self.page_count) {
                    return Err("Invalid eraser sample page".into());
                }
                Ok((page, point(&s["from"])?, point(&s["to"])?))
            })
            .collect::<Result<Vec<_>, String>>()?;
        for (page, start, end) in segments {
            for target in &mut self.targets {
                if target.refused || target.base["page"] != page {
                    continue;
                }
                let mut changed = false;
                for split in &mut target.splitters {
                    changed = split.remove(start, end) || changed;
                }
                if changed {
                    if target.blocked {
                        target.refused = true;
                    } else {
                        target.changed = true;
                    }
                }
            }
        }
        let mut hidden = vec![];
        let mut annotations = vec![];
        let mut points = 0;
        for target in &self.targets {
            if !target.changed {
                continue;
            }
            hidden.push(target.id.clone());
            for (i, path) in target.survivors().iter().enumerate() {
                points += path.len();
                if points > 200_000 {
                    return Err(
                        "Cut ink exceeds the preview geometry budget; cancel this gesture".into(),
                    );
                }
                let mut value = target.piece(path, format!("erase-preview:{}:{i}", target.id));
                value["visible"] = json!(true);
                annotations.push(value);
            }
        }
        let refused: Vec<_> = self
            .targets
            .iter()
            .filter(|t| t.refused)
            .map(|t| t.id.clone())
            .collect();
        Ok(
            json!({"token":self.token,"hidden":hidden,"annotations":annotations,"refused":refused,"changed":hidden.len(),"pieces":annotations.len()}),
        )
    }
}
impl Marks {
    pub(super) fn erase_command(
        &mut self,
        op: &str,
        r: &Value,
        document: &LyraReaderDocument,
    ) -> Result<Value, String> {
        let token = string(r, "token")?;
        if token.is_empty() || token.len() > 128 {
            return Err("Invalid eraser gesture token".into());
        }
        if op == "ink_erase_begin" {
            self.erase = None;
            if let Some(error) = &self.error {
                return Err(format!("Sidecar writes are blocked: {error}"));
            }
            let page = r["page"]
                .as_u64()
                .filter(|p| *p < u64::from(self.page_count))
                .ok_or("Invalid eraser page")?;
            let zoom = number(r, "zoom")?;
            if !(0.01..=64.0).contains(&zoom) {
                return Err("Invalid eraser zoom".into());
            }
            let records = document.annotations().map_err(|e| e.to_string())?;
            let mut ignored: HashSet<String> =
                self.deletions.iter().map(|d| d.target.clone()).collect();
            let mut targets = vec![];
            let mut points = 0;
            for entry in &self.entries {
                let Entry::Known(v) = entry else { continue };
                let Some(id) = v["id"].as_str() else { continue };
                // Also cover a sidecar's NM identity after its first PDF save.
                let source = records.iter().find(|a| {
                    v["fileIdentity"] == a.id || a.id == id || a.id == format!("nm:{id}")
                });
                ignored.insert(id.to_string());
                ignored.insert(format!("nm:{id}"));
                if let Some(a) = source {
                    ignored.insert(a.id.clone());
                }
                if kind(v) == "ink" {
                    targets.push(Target::new(v.clone(), source, &records, zoom)?);
                }
            }
            for a in &records {
                if a.kind != "ink"
                    || !a.visible
                    || a.drawing == "skipped"
                    || ignored.contains(&a.id)
                {
                    continue;
                }
                let c = a.color.unwrap_or(AnnotationColorRecord {
                    red: 232,
                    green: 188,
                    blue: 85,
                });
                let color = format!(
                    "#{:02X}{:02X}{:02X}{:02X}",
                    c.red,
                    c.green,
                    c.blue,
                    (a.opacity.unwrap_or(1.0).clamp(0.0, 1.0) * 255.0).round() as u8
                );
                let paths: Vec<_> = a
                    .ink_paths
                    .iter()
                    .map(|path| {
                        path.iter()
                            .map(|p| json!({"x":p.x_pt,"y":p.y_pt}))
                            .collect::<Vec<_>>()
                    })
                    .collect();
                let base = json!({"id":a.id,"kind":"ink","page":a.page,"version":1,"paths":paths,"strokeWidth":a.border_width_pt.unwrap_or(2.0).max(0.1),"note":a.contents.clone().unwrap_or_default(),"color":color,"createdAt":now()});
                targets.push(Target::new(base, Some(a), &records, zoom)?);
            }
            for target in &targets {
                points += paths(&target.base["paths"])?
                    .iter()
                    .map(Vec::len)
                    .sum::<usize>();
            }
            if points > 200_000 {
                return Err("Ink exceeds the eraser geometry budget".into());
            }
            self.erase = Some(Gesture {
                token: token.clone(),
                source_page: page,
                page_count: self.page_count,
                targets,
            });
        }
        if self.erase.as_ref().is_none_or(|g| g.token != token) {
            return if op == "ink_erase_commit" {
                Err("The ink changed during this gesture; no cut was saved".into())
            } else {
                Ok(json!({"token":token,"cancelled":true}))
            };
        }
        match op {
            "ink_erase_cancel" => {
                self.erase = None;
                Ok(json!({"token":token,"cancelled":true}))
            }
            "ink_erase_begin" | "ink_erase_preview" => {
                let result = self.erase.as_mut().unwrap().update(r);
                if result.is_err() {
                    self.erase = None;
                }
                result
            }
            "ink_erase_commit" => {
                // Consume the final pointer batch before constructing the exact same pieces.
                let preview = match self.erase.as_mut().unwrap().update(r) {
                    Ok(v) => v,
                    Err(e) => {
                        self.erase = None;
                        return Err(e);
                    }
                };
                let gesture = self.erase.take().unwrap();
                let changed = preview["changed"].as_u64().unwrap();
                if changed > 0 {
                    self.change(|s| {
                        for target in gesture.targets.into_iter().filter(|t| t.changed) {
                            let mut pieces = vec![];
                            for path in target.survivors() {
                                let mut piece = target.piece(&path, uuid()?);
                                piece["createdAt"] = json!(now());
                                validate(&piece, s.page_count)?;
                                pieces.push(Entry::Known(piece));
                            }
                            if let Some(index) = s
                                .entries
                                .iter()
                                .position(|e| matches!(e,Entry::Known(v) if v["id"]==target.id))
                            {
                                s.entries.splice(index..=index, pieces);
                            } else {
                                s.entries.extend(pieces);
                            }
                            if let Some(deletion) = target.file
                                && !s.deletions.iter().any(|d| d.target == deletion.target)
                            {
                                s.deletions.push(deletion);
                            }
                        }
                        Ok(())
                    })?;
                }
                let mut state = self.state(document)?;
                state["erase_changed"] = json!(changed);
                state["erase_refused"] = preview["refused"].clone();
                state["erase_pieces"] = preview["pieces"].clone();
                state["erase_token"] = json!(token);
                Ok(state)
            }
            _ => Err("Unknown eraser operation".into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn every_review_attachment_is_independently_protected_including_hidden_replies() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/annotated-ink-review.pdf");
        let doc = LyraReaderEngine::new()
            .open_document(path.to_string_lossy().into_owned(), None)
            .unwrap();
        let file = doc.annotations().unwrap();
        let mut bare = file
            .iter()
            .find(|a| a.id == "nm:review-ink-commented")
            .unwrap()
            .clone();
        bare.contents = None;
        bare.has_popup = false;
        bare.is_reply = false;
        bare.parent_id = None;
        assert!(!attached(&bare, "", &[]));
        assert!(attached(&bare, "comment", &[]));
        bare.has_popup = true;
        assert!(attached(&bare, "", &[]));
        bare.has_popup = false;
        let mut reply = file.iter().find(|a| a.is_reply).unwrap().clone();
        reply.visible = false;
        reply.parent_id = Some(bare.id.clone());
        assert!(attached(&bare, "", &[reply.clone()]));
        reply.parent_id = Some("nm:other".into());
        assert!(!attached(&bare, "", &[reply]));
        bare.is_reply = true;
        assert!(attached(&bare, "", &[]));
    }
}
