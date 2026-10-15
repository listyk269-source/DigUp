//! Local user annotations, separate from computed evidence and the search database.
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, path::Path};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EdgeStatus {
    #[default]
    Unverified,
    Confirmed,
    Rejected,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct NodeAnnotation {
    pub hidden: bool,
    pub pinned: Option<Point>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Investigation {
    pub schema_version: u32,
    pub nodes: BTreeMap<String, NodeAnnotation>,
    pub edges: BTreeMap<String, EdgeStatus>,
}

impl Default for Investigation {
    fn default() -> Self {
        Self {
            schema_version: 1,
            nodes: BTreeMap::new(),
            edges: BTreeMap::new(),
        }
    }
}

impl Investigation {
    fn validate(&self) -> Result<(), String> {
        if self.schema_version != 1 || self.nodes.len() > 4000 || self.edges.len() > 8000 {
            return Err("Unsupported or oversized investigation state".into());
        }
        for key in self.nodes.keys().chain(self.edges.keys()) {
            if key.len() > 262144 {
                return Err("Invalid investigation identity".into());
            }
        }
        for node in self.nodes.values() {
            if let Some(point) = &node.pinned {
                if !point.x.is_finite()
                    || !point.y.is_finite()
                    || point.x.abs() > 1e8
                    || point.y.abs() > 1e8
                {
                    return Err("Invalid pinned coordinates".into());
                }
            }
        }
        Ok(())
    }

    pub fn load(path: &Path) -> Result<Self, String> {
        if !path.exists() {
            return Ok(Self::default());
        }
        let file = std::fs::File::open(path).map_err(|_| "Could not read graph annotations")?;
        if file
            .metadata()
            .map_err(|_| "Could not inspect graph annotations")?
            .len()
            > 2 * 1024 * 1024
        {
            return Err("Graph annotations exceed the size limit".into());
        }
        let state: Self = serde_json::from_reader(file)
            .map_err(|_| "Graph annotations are damaged; the original file was preserved")?;
        state.validate()?;
        Ok(state)
    }

    /// Caller serializes writes. The original survives failed validation/serialization and a partial temporary write.
    pub fn save(&self, path: &Path) -> Result<(), String> {
        self.validate()?;
        let bytes = serde_json::to_vec(self).map_err(|_| "Could not encode graph annotations")?;
        if bytes.len() > 2 * 1024 * 1024 {
            return Err("Graph annotations exceed the size limit".into());
        }
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|_| "Could not create graph annotations")?;
        }
        let temporary = path.with_extension("json.new");
        std::fs::write(&temporary, bytes).map_err(|_| "Could not write graph annotations")?;
        std::fs::rename(temporary, path)
            .map_err(|_| "Could not replace graph annotations".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn annotations_round_trip_replace_and_preserve_corrupt_original() {
        let folder = std::env::temp_dir().join(format!(
            "digup-investigation-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let path = folder.join("Граф café/annotations.json");
        let mut state = Investigation::default();
        state.nodes.insert(
            "Фото/日本語".into(),
            NodeAnnotation {
                hidden: false,
                pinned: Some(Point { x: -23.5, y: 42.0 }),
            },
        );
        state.edges.insert("pair".into(), EdgeStatus::Confirmed);
        state.save(&path).unwrap();
        state.edges.insert("pair".into(), EdgeStatus::Rejected);
        state.save(&path).unwrap();
        let loaded = Investigation::load(&path).unwrap();
        assert_eq!(loaded.edges["pair"], EdgeStatus::Rejected);
        assert_eq!(
            loaded.nodes["Фото/日本語"].pinned.as_ref().unwrap().x,
            -23.5
        );
        std::fs::write(&path, b"broken").unwrap();
        assert!(Investigation::load(&path).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"broken");
        std::fs::remove_dir_all(folder).unwrap();
    }
    #[test]
    fn unsupported_versions_statuses_and_nonfinite_coordinates_fail() {
        let mut state = Investigation {
            schema_version: 2,
            ..Default::default()
        };
        assert!(state.validate().is_err());
        state.schema_version = 1;
        state.nodes.insert(
            "x".into(),
            NodeAnnotation {
                hidden: false,
                pinned: Some(Point {
                    x: f64::NAN,
                    y: 0.0,
                }),
            },
        );
        assert!(state.validate().is_err());
        assert!(serde_json::from_str::<EdgeStatus>("\"automatic-confirmed\"").is_err());
    }
}
