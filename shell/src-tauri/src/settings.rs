//! What the person chose: the folders DigUp searches, what it skips in them, the hotkey, and whether setup is done. A
//! JSON file in the app's config folder (%APPDATA%\com.abdurrahim.DigUp on Windows, ~/.config/com.abdurrahim.DigUp on
//! Linux). Launch arguments (`--roots`, `--hotkey`) stand in for it in dev runs.

use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    /// The folders searched and kept indexed.
    pub folders: Vec<String>,
    /// Source-code folders are indexed separately and searched with the `code:` prefix.
    pub code_roots: Vec<String>,
    /// Folders inside them that aren't (`FolderSelection` in the engine).
    pub skipped: Vec<String>,
    /// File extensions left out ("heic", "txt").
    pub skip_types: Vec<String>,
    /// The panel's hotkey (Tauri's accelerator form); empty: the default.
    pub hotkey: String,
    /// Onboarding is done: the shell starts in the tray.
    pub set_up: bool,
}

impl Settings {
    /// The file's settings, or the defaults when there's none (or it can't be read).
    pub fn load(path: &Path) -> Settings {
        std::fs::read(path)
            .ok()
            .and_then(|data| serde_json::from_slice(&data).ok())
            .unwrap_or_default()
    }

    /// Written whole to a temporary file first, so a crash never leaves half of it.
    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(folder) = path.parent() {
            std::fs::create_dir_all(folder)?;
        }
        let temporary = path.with_extension("json.new");
        std::fs::write(&temporary, serde_json::to_vec_pretty(self)?)?;
        std::fs::rename(temporary, path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saves_unicode_and_replaces_existing_settings() {
        let temporary = std::env::temp_dir().join(format!(
            "digup-settings-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let path = temporary
            .join("Настройки с пробелами 🚀")
            .join("settings.json");
        let mut settings = Settings {
            folders: vec!["C:/Документы/日本語 🚀".into()],
            code_roots: vec!["C:/Исходный код/日本語 🚀".into()],
            ..Default::default()
        };
        settings.save(&path).unwrap();
        settings.set_up = true;
        settings.save(&path).unwrap();
        let loaded = Settings::load(&path);
        assert_eq!(loaded.folders, settings.folders);
        assert_eq!(loaded.code_roots, settings.code_roots);
        assert!(loaded.set_up);
        assert!(!path.with_extension("json.new").exists());
        std::fs::remove_dir_all(temporary).unwrap();
    }

    #[test]
    fn older_settings_get_defaults_for_missing_fields() {
        let settings: Settings =
            serde_json::from_str(r#"{"folders":["/Documents"],"setUp":true}"#).unwrap();
        assert!(settings.set_up);
        assert!(settings.skip_types.is_empty());
        assert!(settings.hotkey.is_empty());
        assert!(settings.code_roots.is_empty());
    }
}
