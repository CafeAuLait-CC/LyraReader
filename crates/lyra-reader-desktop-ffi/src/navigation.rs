//! Typed native viewport payload over the shared history transitions. No PDF or I/O.
use lyra_reader_session::navigation::{NAVIGATION_HISTORY_LIMIT, NavigationHistory};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Mutex;

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Selection {
    page: u32,
    start: u32,
    end: u32,
}
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Anchor {
    page: u32,
    y: f64,
}
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Location {
    page: u32,
    anchor: Option<Anchor>,
    offset_pt: f64,
    x_pt: f64,
    zoom_percent: f64,
    fitting: bool,
    fit_preset: Preset,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    fitted_page: bool,
    selection: Option<Selection>,
}
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
enum Preset {
    Width,
    Page,
}
impl Location {
    fn validate(&self) -> Result<(), String> {
        if ![self.offset_pt, self.x_pt, self.zoom_percent]
            .iter()
            .all(|n| n.is_finite())
            // Only representation noise at shared-policy endpoints is tolerated;
            // the exact stored percentage is never rounded to an integer.
            || self.zoom_percent < f64::from(lyra_reader_session::MIN_ZOOM_PERCENT)-1e-9
            || self.zoom_percent > f64::from(lyra_reader_session::MAX_ZOOM_PERCENT)+1e-9
            || self.anchor.as_ref().is_some_and(|a| !a.y.is_finite())
        {
            return Err(
                "Navigation requires finite viewport geometry and a supported percentage".into(),
            );
        }
        // A backward drag legitimately has start > end; preserve that selection exactly.
        Ok(())
    }
}
#[derive(Default)]
pub struct History {
    inner: Mutex<NavigationHistory<Location>>,
}
impl History {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn query(&self, request: Value) -> Result<Value, String> {
        let op = request["op"]
            .as_str()
            .ok_or("Missing navigation operation")?;
        let location = if matches!(op, "record" | "back" | "forward") {
            let location: Location = serde_json::from_value(request["location"].clone())
                .map_err(|e| format!("Invalid navigation location: {e}"))?;
            location.validate()?;
            Some(location)
        } else {
            None
        };
        let mut history = lyra_reader_core::sync::lock(&self.inner).map_err(|e| e.to_string())?;
        let target = match (op, location) {
            ("record", Some(location)) => {
                history.record(location);
                None
            }
            ("back", Some(location)) => history.go_back(location),
            ("forward", Some(location)) => history.go_forward(location),
            ("clear", None) => {
                history.clear();
                None
            }
            ("snapshot", None) => None,
            _ => return Err("Unknown navigation operation".into()),
        };
        Ok(
            json!({"target":target,"state":{"back":history.back(),"forward":history.forward(),"limit":NAVIGATION_HISTORY_LIMIT}}),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn location(page: u32) -> Value {
        json!({"page":page,"anchor":{"page":page,"y":73.25},"offsetPt":975.5,"xPt":-43.125,"zoomPercent":137.5,"fitting":false,"fitPreset":"page","selection":{"page":page,"start":19,"end":4}})
    }
    #[test]
    fn native_payload_round_trips_through_the_shared_twenty_entry_history() {
        let history = History::new();
        for page in 0..25 {
            history
                .query(json!({"op":"record","location":location(page)}))
                .unwrap();
        }
        let snapshot = history.query(json!({"op":"snapshot"})).unwrap();
        assert_eq!(snapshot["state"]["limit"], 20);
        assert_eq!(snapshot["state"]["back"].as_array().unwrap().len(), 20);
        assert_eq!(snapshot["state"]["back"][0], location(5));
        let back = history
            .query(json!({"op":"back","location":location(30)}))
            .unwrap();
        assert_eq!(back["target"], location(24));
        assert_eq!(
            history
                .query(json!({"op":"forward","location":location(24)}))
                .unwrap()["target"],
            location(30)
        );
        history
            .query(json!({"op":"back","location":location(30)}))
            .unwrap();
        assert!(
            history
                .query(json!({"op":"record","location":location(40)}))
                .unwrap()["state"]["forward"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        let cleared = history.query(json!({"op":"clear"})).unwrap();
        assert!(cleared["state"]["back"].as_array().unwrap().is_empty());
        assert!(
            history
                .query(json!({"op":"back","location":location(0)}))
                .unwrap()["target"]
                .is_null()
        );
    }
    #[test]
    fn fitted_presentation_intent_is_retained_without_persisting_viewport_padding() {
        let history = History::new();
        let mut fitted = location(4);
        fitted["fittedPage"] = json!(true);
        history
            .query(json!({"op":"record","location":fitted}))
            .unwrap();
        assert_eq!(
            history
                .query(json!({"op":"back","location":location(9)}))
                .unwrap()["target"],
            fitted
        );
    }
    #[test]
    fn invalid_native_locations_leave_both_stacks_unchanged() {
        let history = History::new();
        history
            .query(json!({"op":"record","location":location(2)}))
            .unwrap();
        let before = history.query(json!({"op":"snapshot"})).unwrap();
        for key in ["zoomPercent", "offsetPt", "xPt"] {
            let mut invalid = location(3);
            invalid[key] = Value::Null;
            assert!(
                history
                    .query(json!({"op":"back","location":invalid}))
                    .is_err()
            );
            assert_eq!(history.query(json!({"op":"snapshot"})).unwrap(), before);
        }
        let mut invalid = location(3);
        invalid["zoomPercent"] = json!(0);
        assert!(
            history
                .query(json!({"op":"record","location":invalid}))
                .is_err()
        );
        assert_eq!(history.query(json!({"op":"snapshot"})).unwrap(), before);
    }
}
