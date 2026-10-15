//! What the shell is told at launch. The folders and the hotkey come from the command line until onboarding and the
//! settings window exist.

use crate::settings::Device;
use std::path::PathBuf;

/// The panel's hotkey unless told otherwise: ⇧⌘Space on a Mac (the Mac app's), Ctrl+Shift+Space elsewhere.
pub const DEFAULT_HOTKEY: &str = "CommandOrControl+Shift+Space";

pub struct Options {
    /// DigUp's helper, `digup` (default: beside this program, where the installers put it).
    pub helper: PathBuf,
    pub helper_explicit: bool,
    /// The index folder. None: the helper's own default (%LOCALAPPDATA%\DigUp\index on Windows,
    /// ~/.local/share/digup/index on Linux).
    pub index: Option<PathBuf>,
    /// Where the model files are (DIGUP_MODELS for the helpers); None: the helper looks where it always does.
    pub models: Option<PathBuf>,
    /// Explicit CLI/environment device selection, ahead of the saved preference.
    pub device: Option<Device>,
    /// The legacy CPU-only environment override always wins, including over --device.
    pub cpu_only: bool,
    /// The folders to search and keep indexed, instead of the settings' (dev runs; setup is then skipped).
    pub roots: Vec<PathBuf>,
    pub code_roots: Vec<PathBuf>,
    /// The hotkey, instead of the settings'.
    pub hotkey: Option<String>,
    /// The settings file, instead of the one in the app's config folder (a fresh first launch in tests).
    pub settings: Option<PathBuf>,
    /// The folders setup offers, instead of the usual ones (Documents, Pictures…): dev runs never offer real folders.
    pub offered: Option<Vec<PathBuf>>,
    /// Debug runs: setup clicks through by itself (all offered folders, the default hotkey).
    pub debug_setup: bool,
    /// Smoke runs: choose this device through the real setup form, without a launch override.
    pub debug_device: Option<Device>,
    /// Debug runs: the panel types this query in when it loads and reports what it showed (`debug_report`), hidden
    /// unless `debug_show`: a panel on screen takes the keyboard.
    pub debug_query: Option<String>,
    /// Debug runs: quit once the report is in.
    pub debug_quit: bool,
    /// A machine-readable smoke result, also available in release builds without a console.
    pub debug_report: Option<PathBuf>,
    /// Debug runs: show the panel at launch and keep it up when it loses focus.
    pub debug_show: bool,
    /// Explicit smoke isolation: no shared single-instance endpoint, tray, hotkey or WebView profile.
    pub debug_isolated: bool,
    /// A second real setup pass adds this folder before the debug query.
    pub debug_reconfigure_folder: Option<PathBuf>,
    /// Isolated release smoke: click through every search page and open the real index overview.
    pub debug_load_all: bool,
    /// Isolated release smoke: explore a real stored-vector neighborhood through the graph's DOM controls.
    pub debug_graph: bool,
    pub debug_ui_features: bool,
    pub debug_faces: bool,
    pub debug_people: bool,
    pub debug_auto_faces: bool,
}

impl Options {
    pub fn from_args() -> Result<Options, String> {
        Self::from_arguments(
            std::env::args().skip(1),
            std::env::var("DIGUP_DEVICE").ok().as_deref(),
            std::env::var("DIGUP_CPU_ONLY").ok().as_deref(),
        )
    }

    fn from_arguments(
        mut args: impl Iterator<Item = String>,
        device_env: Option<&str>,
        cpu_env: Option<&str>,
    ) -> Result<Options, String> {
        let mut options = Options {
            helper: PathBuf::new(),
            helper_explicit: false,
            index: None,
            models: None,
            device: None,
            cpu_only: cpu_env == Some("1"),
            roots: Vec::new(),
            code_roots: Vec::new(),
            hotkey: None,
            settings: None,
            offered: None,
            debug_setup: false,
            debug_device: None,
            debug_query: None,
            debug_quit: false,
            debug_report: None,
            debug_show: false,
            debug_isolated: false,
            debug_reconfigure_folder: None,
            debug_load_all: false,
            debug_graph: false,
            debug_ui_features: false,
            debug_faces: false,
            debug_people: false,
            debug_auto_faces: false,
        };
        while let Some(arg) = args.next() {
            let mut value = || args.next().ok_or_else(|| format!("{arg} needs a value"));
            match arg.as_str() {
                "--helper" => {
                    options.helper = value()?.into();
                    options.helper_explicit = true;
                }
                "--index" => options.index = Some(value()?.into()),
                "--models" => options.models = Some(value()?.into()),
                "--device" => options.device = Some(value()?.parse()?),
                // Separated as PATH is: ":" here, ";" on Windows.
                "--roots" => options.roots = std::env::split_paths(&value()?).collect(),
                "--code-root" => options.code_roots.push(value()?.into()),
                "--hotkey" => options.hotkey = Some(value()?),
                "--settings" => options.settings = Some(value()?.into()),
                "--offer" => options.offered = Some(std::env::split_paths(&value()?).collect()),
                "--debug-setup" => options.debug_setup = true,
                "--debug-device" => options.debug_device = Some(value()?.parse()?),
                "--debug-query" => options.debug_query = Some(value()?),
                "--debug-quit" => options.debug_quit = true,
                "--debug-report" => options.debug_report = Some(value()?.into()),
                "--debug-show" => options.debug_show = true,
                "--debug-isolated" => options.debug_isolated = true,
                "--debug-reconfigure-folder" => {
                    options.debug_reconfigure_folder = Some(value()?.into())
                }
                "--debug-load-all" => options.debug_load_all = true,
                "--debug-graph" => options.debug_graph = true,
                "--debug-ui-features" => options.debug_ui_features = true,
                "--debug-faces" => options.debug_faces = true,
                "--debug-people" => options.debug_people = true,
                "--debug-auto-faces" => options.debug_auto_faces = true,
                _ => return Err(format!("unknown argument {arg}")),
            }
        }
        if options.device.is_none() && !options.cpu_only {
            options.device = device_env.map(str::parse).transpose()?;
        }
        if options.debug_device.is_some() && !options.debug_setup {
            return Err("--debug-device requires --debug-setup".into());
        }
        if options.debug_isolated
            && [&options.index, &options.settings, &options.debug_report]
                .into_iter()
                .any(|path| !path.as_ref().is_some_and(|path| path.is_absolute()))
        {
            return Err("--debug-isolated requires explicit absolute --index, --settings and --debug-report paths".into());
        }
        if let Some(folder) = &options.debug_reconfigure_folder {
            if !options.debug_isolated || !options.debug_setup || !folder.is_absolute() {
                return Err("--debug-reconfigure-folder requires --debug-isolated, --debug-setup and an absolute folder path".into());
            }
        }
        if options.debug_load_all && !options.debug_isolated {
            return Err("--debug-load-all requires --debug-isolated".into());
        }
        if options.debug_ui_features && !options.debug_isolated {
            return Err("--debug-ui-features requires --debug-isolated".into());
        }
        if options.debug_faces && !options.debug_isolated {
            return Err("--debug-faces requires --debug-isolated".into());
        }
        if options.debug_people && !options.debug_isolated {
            return Err("--debug-people requires --debug-isolated".into());
        }
        if options.debug_auto_faces && !options.debug_isolated {
            return Err("--debug-auto-faces requires --debug-isolated".into());
        }
        if options.debug_graph && !options.debug_isolated {
            return Err("--debug-graph requires --debug-isolated".into());
        }
        // On a Mac the shell is only tried out: the helper's default index there is the Mac app's.
        if cfg!(target_os = "macos") && options.index.is_none() {
            return Err("pass --index: on a Mac the default index belongs to the DigUp app".into());
        }
        Ok(options)
    }
}

impl Options {
    pub fn effective_device(&self, saved: Device) -> Device {
        if self.cpu_only {
            Device::Cpu
        } else {
            self.device.unwrap_or(saved)
        }
    }

    pub fn device_is_overridden(&self) -> bool {
        self.cpu_only || self.device.is_some()
    }

    pub fn helper_environment(&self, saved: Device) -> Vec<(String, String)> {
        let mut env = vec![(
            "DIGUP_DEVICE".into(),
            self.effective_device(saved).as_str().into(),
        )];
        if let Some(models) = &self.models {
            env.push(("DIGUP_MODELS".into(), models.display().to_string()));
        }
        env
    }

    /// The index folder the helpers use: the one given, else the helper's default (which the watcher must pass over).
    pub fn index_folder(&self) -> Option<PathBuf> {
        if self.index.is_some() {
            return self.index.clone();
        }
        if cfg!(windows) {
            return std::env::var_os("LOCALAPPDATA")
                .map(|local| PathBuf::from(local).join("DigUp").join("index"));
        }
        let data = std::env::var_os("XDG_DATA_HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share"))
            });
        data.map(|data| data.join("digup").join("index"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str], device: Option<&str>, cpu: Option<&str>) -> Result<Options, String> {
        let args = ["--index", "test-index"]
            .into_iter()
            .chain(args.iter().copied());
        Options::from_arguments(args.map(str::to_string), device, cpu)
    }

    #[test]
    fn device_precedence_preserves_cpu_override_and_saved_default() {
        assert_eq!(
            parse(&[], None, None)
                .unwrap()
                .effective_device(Device::Gpu),
            Device::Gpu
        );
        assert_eq!(
            parse(&[], Some("cpu"), None)
                .unwrap()
                .effective_device(Device::Gpu),
            Device::Cpu
        );
        assert_eq!(
            parse(&["--device", "gpu"], Some("cpu"), None)
                .unwrap()
                .effective_device(Device::Auto),
            Device::Gpu
        );
        let forced = parse(&["--device", "gpu"], Some("gpu"), Some("1")).unwrap();
        assert_eq!(forced.effective_device(Device::Gpu), Device::Cpu);
        assert_eq!(
            forced.helper_environment(Device::Gpu),
            vec![("DIGUP_DEVICE".into(), "cpu".into())]
        );
        assert!(forced.device_is_overridden());
        assert_eq!(
            parse(&[], Some("invalid"), Some("1"))
                .unwrap()
                .effective_device(Device::Gpu),
            Device::Cpu
        );
        assert!(!parse(&[], None, Some("0")).unwrap().device_is_overridden());
    }

    #[test]
    fn invalid_device_reports_allowed_values() {
        assert!(parse(&["--device", "cuda"], None, None)
            .err()
            .unwrap()
            .contains("auto, cpu, or gpu"));
        assert!(parse(&[], Some("invalid"), None).is_err());
        assert!(parse(&["--device"], None, None).is_err());
    }

    #[test]
    fn debug_device_selects_setup_without_overriding_saved_settings() {
        let options = parse(&["--debug-setup", "--debug-device", "gpu"], None, None).unwrap();
        assert_eq!(options.debug_device, Some(Device::Gpu));
        assert!(!options.device_is_overridden());
        assert_eq!(options.effective_device(Device::Auto), Device::Auto);
        assert!(parse(&["--debug-device", "gpu"], None, None).is_err());
    }

    #[test]
    fn isolated_smoke_requires_private_explicit_paths() {
        assert!(parse(&["--debug-isolated"], None, None).is_err());
        assert!(parse(&["--debug-load-all"], None, None).is_err());
        assert!(parse(&["--debug-graph"], None, None).is_err());
        assert!(parse(&["--debug-ui-features"], None, None).is_err());
        assert!(parse(&["--debug-faces"], None, None).is_err());
        assert!(parse(&["--debug-people"], None, None).is_err());
        assert!(parse(&["--debug-auto-faces"], None, None).is_err());
        assert!(parse(&["--debug-reconfigure-folder", "relative"], None, None).is_err());
        let root = std::env::temp_dir().join("DigUp test кириллица");
        let args = [
            "--debug-isolated".to_string(),
            "--debug-setup".into(),
            "--index".into(),
            root.join("index").display().to_string(),
            "--settings".into(),
            root.join("settings.json").display().to_string(),
            "--debug-report".into(),
            root.join("report.json").display().to_string(),
            "--debug-reconfigure-folder".into(),
            root.join("Документы").display().to_string(),
        ];
        let options = Options::from_arguments(args.into_iter(), None, None).unwrap();
        assert!(options.debug_isolated);
        assert_eq!(
            options.debug_reconfigure_folder,
            Some(root.join("Документы"))
        );
    }
}
