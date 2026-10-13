//! What the person chose: the folders DigUp searches, what it skips in them, the hotkey, and whether setup is done. A
//! JSON file in the app's config folder (%APPDATA%\com.abdurrahim.DigUp on Windows, ~/.config/com.abdurrahim.DigUp on
//! Linux). Launch arguments (`--roots`, `--hotkey`) stand in for it in dev runs.

use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Device {
    #[default]
    Auto,
    Cpu,
    Gpu,
}

impl Device {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Cpu => "cpu",
            Self::Gpu => "gpu",
        }
    }
}

impl std::str::FromStr for Device {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "auto" => Ok(Self::Auto),
            "cpu" => Ok(Self::Cpu),
            "gpu" => Ok(Self::Gpu),
            _ => Err("Device must be auto, cpu, or gpu".into()),
        }
    }
}

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
    /// Inference device preference; Auto can fall back to CPU when a GPU cannot start.
    pub device: Device,
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
        settings.device = Device::Gpu;
        settings.save(&path).unwrap();
        let loaded = Settings::load(&path);
        assert_eq!(loaded.folders, settings.folders);
        assert_eq!(loaded.code_roots, settings.code_roots);
        assert!(loaded.set_up);
        assert_eq!(loaded.device, Device::Gpu);
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
        assert_eq!(settings.device, Device::Auto);
    }

    #[test]
    fn device_values_round_trip() {
        for device in [Device::Auto, Device::Cpu, Device::Gpu] {
            let encoded = serde_json::to_string(&device).unwrap();
            assert_eq!(encoded, format!("\"{}\"", device.as_str()));
            assert_eq!(serde_json::from_str::<Device>(&encoded).unwrap(), device);
        }
        assert!("cuda".parse::<Device>().is_err());
    }
}
