//! A replayable view of the existing index-service events. Counts describe the current
//! pass (files, or parts of long files), never an estimated percentage of all work.
use serde::Serialize;
use serde_json::Value;

#[derive(Clone, Debug, Serialize)]
pub struct IndexStatus {
    pub revision: u64,
    pub stage: String,
    pub done: Option<u64>,
    pub total: Option<u64>,
    pub unit: &'static str,
    pub code: bool,
    pub searchable: Option<u64>,
    pub failed: Option<u64>,
    pub skipped: Option<u64>,
    pub unavailable: u64,
    pub message: Option<String>,
    #[serde(skip)]
    unavailable_by_index: [u64; 2],
}

impl Default for IndexStatus {
    fn default() -> Self {
        Self {
            revision: 0,
            stage: "starting".into(),
            done: None,
            total: None,
            unit: "files",
            code: false,
            searchable: None,
            failed: None,
            skipped: None,
            unavailable: 0,
            message: None,
            unavailable_by_index: [0; 2],
        }
    }
}

impl IndexStatus {
    pub fn phase(&mut self, stage: &str, message: Option<String>) {
        self.stage = stage.into();
        self.message = message;
        if stage != "paused" {
            self.done = None;
            self.total = None;
        }
        self.revision += 1;
    }

    pub fn observe(&mut self, event: &Value) -> bool {
        let kind = event["event"].as_str().unwrap_or_default();
        // stop() can still deliver a final file/exit event. Keep the explicit paused state.
        if self.stage == "paused" {
            return false;
        }
        match kind {
            "scanning" | "indexing" | "reading-rest" | "file" | "rest" => {
                self.stage = match kind {
                    "scanning" => "scanning",
                    "reading-rest" | "rest" => "rest",
                    _ => "indexing",
                }
                .into();
                self.code = event["code"].as_bool().unwrap_or(false);
                self.unit = if self.stage == "rest" {
                    "parts"
                } else {
                    "files"
                };
                self.done = event["done"].as_u64();
                self.total = event["total"].as_u64();
                if kind == "scanning" {
                    self.message = None;
                    // The helper reports availability separately, only when it changes after
                    // its initial snapshot. A new scan does not imply that an offline root returned.
                }
                if event["state"] == "failed" {
                    self.message = Some(
                        "A file couldn't be indexed. Other files can still be searched.".into(),
                    );
                }
            }
            "sync" => {
                // This is the end of a crawl, not a completed embedding pass.
                self.stage = "indexing".into();
                self.done = None;
                self.total = None;
                self.code = event["code"].as_bool().unwrap_or(false);
                self.unit = "files";
                self.counts(event);
            }
            "idle" => {
                self.stage = "idle".into();
                self.done = None;
                self.total = None;
                self.counts(event);
            }
            "waiting" => self.phase("waiting", Some("Waiting for the model.".into())),
            "missing" => {
                let count =
                    |name: &str| event[name].as_array().map_or(0, |items| items.len() as u64);
                self.unavailable_by_index[usize::from(event["code"] == true)] =
                    count("folders") + count("unreadable");
                self.unavailable = self.unavailable_by_index.iter().sum();
            }
            "error" => self.phase(
                "error",
                Some(
                    event["message"]
                        .as_str()
                        .unwrap_or(
                            "Indexing failed. Check folder access and the processing device.",
                        )
                        .into(),
                ),
            ),
            "exit" => {
                // Exit is also emitted after idle or a reported error; it is not success itself.
                if matches!(
                    self.stage.as_str(),
                    "idle" | "error" | "waiting" | "stopped" | "no-folders"
                ) {
                    return false;
                }
                self.phase("stopped", Some("Indexing stopped before completion. Choose Index Now / Resume in the tray to try again.".into()));
            }
            _ => return false,
        }
        self.revision += 1;
        true
    }

    fn counts(&mut self, event: &Value) {
        let combined = |name: &str| {
            let main = event[name].as_u64();
            let code = event[format!("code_{name}")].as_u64();
            (main.is_some() || code.is_some()).then(|| main.unwrap_or(0) + code.unwrap_or(0))
        };
        self.searchable = combined("searchable");
        self.failed = combined("failed");
        self.skipped = combined("skipped");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn progress_preserves_real_units_and_unknown_totals() {
        let mut status = IndexStatus::default();
        status.observe(&json!({"event":"scanning", "code":true}));
        assert_eq!(status.total, None);
        status.observe(&json!({"event":"file", "done":2, "total":8, "code":true}));
        assert_eq!(
            (status.done, status.total, status.unit, status.code),
            (Some(2), Some(8), "files", true)
        );
        status.observe(&json!({"event":"reading-rest"}));
        assert_eq!((status.total, status.unit), (None, "parts"));
        status.observe(&json!({"event":"rest", "done":3, "total":17}));
        assert_eq!(
            (status.done, status.total, status.unit),
            (Some(3), Some(17), "parts")
        );
    }

    #[test]
    fn completed_snapshot_keeps_code_counts_and_problems_after_exit() {
        let mut status = IndexStatus::default();
        status.observe(&json!({"event":"missing", "folders":["D:/offline"], "unreadable":[]}));
        status.observe(&json!({"event":"idle", "searchable":2, "code_searchable":5, "failed":1, "code_failed":2, "skipped":4}));
        let revision = status.revision;
        assert!(!status.observe(&json!({"event":"exit"})));
        assert_eq!(
            (
                status.searchable,
                status.failed,
                status.skipped,
                status.unavailable
            ),
            (Some(7), Some(3), Some(4), 1)
        );
        assert_eq!(status.revision, revision);
        status.observe(&json!({"event":"missing", "folders":[], "unreadable":[]}));
        assert_eq!(status.unavailable, 0);
    }

    #[test]
    fn paused_and_failed_are_not_reported_as_success_when_helper_exits() {
        let mut status = IndexStatus::default();
        status.phase("paused", None);
        assert!(!status.observe(&json!({"event":"file", "done":1,"total":1})));
        assert!(!status.observe(&json!({"event":"exit"})));
        assert_eq!(status.stage, "paused");
        status.phase("starting", None);
        status.observe(&json!({"event":"error","message":"No GPU available"}));
        status.observe(&json!({"event":"exit"}));
        assert_eq!(status.stage, "error");
        assert_eq!(status.message.as_deref(), Some("No GPU available"));
        status.phase("starting", None);
        status.observe(&json!({"event":"exit"}));
        assert_eq!(status.stage, "stopped");
    }

    #[test]
    fn repeated_scans_keep_unavailable_roots_until_availability_changes() {
        let mut status = IndexStatus::default();
        status.observe(&json!({"event":"scanning"}));
        status.observe(&json!({"event":"missing", "folders":["D:/offline"], "unreadable":[]}));
        status.observe(&json!({"event":"idle", "searchable":2}));
        assert_eq!(status.unavailable, 1);
        status.observe(&json!({"event":"scanning"}));
        status.observe(&json!({"event":"sync", "searchable":2}));
        status.observe(&json!({"event":"idle", "searchable":2}));
        assert_eq!(status.unavailable, 1);
        // Reconnection, removing that root, or a new helper's initial snapshot clears it.
        status.observe(&json!({"event":"missing", "folders":[], "unreadable":[]}));
        assert_eq!(status.unavailable, 0);
    }

    #[test]
    fn replacement_helper_clears_missing_roots_in_both_indexes() {
        let mut status = IndexStatus::default();
        status.observe(&json!({"event":"missing", "folders":["D:/offline"], "unreadable":[]}));
        status.observe(&json!({"event":"missing", "code":true, "folders":["E:/offline-code"], "unreadable":[]}));
        status.observe(&json!({"event":"idle", "searchable":2}));
        assert_eq!(status.unavailable, 2);
        // A replacement helper has no code roots, then scans a readable main root.
        status.observe(&json!({"event":"missing", "code":true, "folders":[], "unreadable":[]}));
        assert_eq!(status.unavailable, 1);
        status.observe(&json!({"event":"scanning"}));
        assert_eq!(status.unavailable, 1);
        status.observe(&json!({"event":"missing", "folders":[], "unreadable":[]}));
        status.observe(&json!({"event":"idle", "searchable":2}));
        assert_eq!(status.unavailable, 0);
    }
}
