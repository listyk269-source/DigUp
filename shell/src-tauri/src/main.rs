// DigUp's shell for Windows and Linux (tried out on the Mac first): the tray icon, the hotkey, the search panel and the
// setup window. The work is DigUp's helper, `digup`, run as processes speaking JSON lines (helper.rs): `search-service`
// answers the panel, `index-service` keeps the index current, `download-model` fetches the model, `estimate` sizes up
// folders. The Mac app (Sources/DigUpApp) is the reference for behavior.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod autostart;
mod capture;
mod helper;
mod index_status;
mod investigation;
mod options;
mod process;
mod resources;
mod settings;
mod watcher;

use helper::{Estimates, IndexService, Launch, ModelDownload, SearchService};
use index_status::IndexStatus;
use options::{Options, DEFAULT_HOTKEY};
use serde_json::{json, Value};
use settings::{Device, Language, Settings};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{
    AppHandle, Emitter, LogicalSize, Manager, PhysicalPosition, State, WebviewUrl,
    WebviewWindowBuilder, WindowEvent, Wry,
};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};
use tauri_plugin_opener::OpenerExt;
use watcher::FolderWatcher;

const PANEL_WIDTH: f64 = 780.0;
const FIELD_HEIGHT: f64 = 56.0;

#[tauri::command]
async fn graph_annotations(
    shell: State<'_, Arc<Shell>>,
) -> Result<investigation::Investigation, String> {
    let shell = shell.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let _guard = shell.configuration.lock().unwrap();
        investigation::Investigation::load(
            &shell
                .settings_path
                .with_file_name("graph-investigation.json"),
        )
    })
    .await
    .map_err(|error| error.to_string())?
}

#[tauri::command]
async fn save_graph_annotations(
    shell: State<'_, Arc<Shell>>,
    state: investigation::Investigation,
) -> Result<(), String> {
    let shell = shell.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let _guard = shell.configuration.lock().unwrap();
        state.save(
            &shell
                .settings_path
                .with_file_name("graph-investigation.json"),
        )
    })
    .await
    .map_err(|error| error.to_string())?
}

/// What the commands and events share.
struct Shell {
    options: Options,
    settings: Mutex<Settings>,
    /// Serializes applying settings with watcher-triggered helper launches, outside the UI thread.
    configuration: Mutex<()>,
    settings_path: PathBuf,
    search: SearchService,
    index: IndexService,
    model: ModelDownload,
    estimates: Estimates,
    /// The model for the setup window and the tray: {"state": "checking|downloading|waiting|ready|failed", …}.
    model_state: Mutex<Value>,
    watcher: Mutex<Option<FolderWatcher>>,
    /// The tray menu's first line: what's going on.
    status: Mutex<Option<MenuItem<Wry>>>,
    tray_labels: Mutex<Vec<(MenuItem<Wry>, String, String)>>,
    /// Replayed when a webview starts or is shown after indexing has already begun.
    index_status: Mutex<IndexStatus>,
    /// When the search service last reloaded the index (while indexing, at most every few seconds).
    reloaded: Mutex<Instant>,
    /// Debug runs with setup: the panel's query waits until the first index is in.
    debug_query_sent: AtomicBool,
    debug_reconfigure_started: AtomicBool,
    debug_reconfigure_done: AtomicBool,
    debug_panel_reopened: AtomicBool,
    debug_setup_history: Mutex<Vec<Value>>,
    debug_index_history: Mutex<Vec<Value>>,
    indexing_paused: AtomicBool,
    shutting_down: AtomicBool,
    logs: PathBuf,
}

impl Shell {
    /// The folders searched: the launch arguments' in dev runs, else the settings'.
    fn folders(&self) -> Vec<String> {
        if !self.options.roots.is_empty() {
            return self
                .options
                .roots
                .iter()
                .map(|root| root.display().to_string())
                .collect();
        }
        self.settings.lock().unwrap().folders.clone()
    }

    fn is_set_up(&self) -> bool {
        !self.options.roots.is_empty()
            || !self.options.code_roots.is_empty()
            || self.settings.lock().unwrap().set_up
    }

    fn code_roots(&self) -> Vec<String> {
        if !self.options.code_roots.is_empty() {
            return self
                .options
                .code_roots
                .iter()
                .map(|root| root.display().to_string())
                .collect();
        }
        self.settings.lock().unwrap().code_roots.clone()
    }

    fn all_folders(&self) -> Vec<String> {
        let mut folders = self.folders();
        folders.extend(self.code_roots());
        folders.sort();
        folders.dedup();
        folders
    }

    fn hotkey(&self) -> String {
        let chosen = self.settings.lock().unwrap().hotkey.clone();
        self.options.hotkey.clone().unwrap_or(if chosen.is_empty() {
            DEFAULT_HOTKEY.to_string()
        } else {
            chosen
        })
    }

    /// A background helper (indexing, the download), below the person's own programs for the processor.
    fn launch(&self, args: Vec<String>, log: &str) -> Launch {
        Launch {
            program: self.options.helper.clone(),
            args,
            env: self
                .options
                .helper_environment(self.settings.lock().unwrap().device),
            log: Some(self.logs.join(log)),
            background: true,
        }
    }

    fn index_arguments(&self) -> Vec<String> {
        self.options
            .index
            .iter()
            .flat_map(|index| ["--index".to_string(), index.display().to_string()])
            .collect()
    }

    /// `index-service` for the folders as they are now.
    fn index_launch(&self) -> Launch {
        let settings = self.settings.lock().unwrap().clone();
        let mut args = vec!["index-service".to_string(), "--backfill".to_string()];
        args.extend(self.index_arguments());
        for folder in &settings.skipped {
            args.extend(["--exclude".to_string(), folder.clone()]);
        }
        for extension in &settings.skip_types {
            args.extend(["--exclude-ext".to_string(), extension.clone()]);
        }
        for folder in self.code_roots() {
            args.extend(["--code-root".to_string(), folder]);
        }
        args.extend(self.folders());
        self.launch(args, "index.log")
    }

    fn model_ready(&self) -> bool {
        self.model_state.lock().unwrap()["state"] == "ready"
    }
}

// MARK: Commands

/// The panel's questions for `search-service`.
#[tauri::command]
async fn ask(shell: State<'_, Arc<Shell>>, request: Value) -> Result<Value, String> {
    let op = request
        .get("op")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if ![
        "search",
        "search_page",
        "related_files",
        "embed_ahead",
        "text",
        "render",
        "prewarm",
        "status",
        "index_stats",
    ]
    .contains(&op)
    {
        return Err(format!("not a question the panel asks: {op}"));
    }
    shell.search.ask(request).await
}

#[tauri::command]
fn index_status(shell: State<'_, Arc<Shell>>) -> IndexStatus {
    shell.index_status.lock().unwrap().clone()
}

#[tauri::command]
fn language(shell: State<'_, Arc<Shell>>) -> Language {
    shell.settings.lock().unwrap().language
}

#[tauri::command]
fn set_language(
    app: AppHandle,
    shell: State<'_, Arc<Shell>>,
    language: Language,
) -> Result<(), String> {
    // Serialize with setup/device saves. Publish only after the atomic settings write succeeded.
    {
        let _configuration = shell.configuration.lock().unwrap();
        let mut settings = shell.settings.lock().unwrap();
        let mut updated = settings.clone();
        updated.language = language;
        updated
            .save(&shell.settings_path)
            .map_err(|e| e.to_string())?;
        *settings = updated;
    }
    for (item, en, ru) in shell.tray_labels.lock().unwrap().iter() {
        let _ = item.set_text(language.text(en, ru));
    }
    if let Some(window) = app.get_webview_window("setup") {
        let _ = window.set_title(language.text("Set Up DigUp", "Настройка DigUp"));
    }
    set_status(&app, "Index status is shown in the search panel");
    let _ = app.emit("language-changed", language);
    Ok(())
}

/// Setup shows file counts only; detailed estimates also probe media durations and PDF pages unnecessarily.
#[tauri::command]
async fn estimate(
    shell: State<'_, Arc<Shell>>,
    folders: Vec<String>,
) -> Result<Option<Vec<Value>>, String> {
    let mut args = vec![
        "estimate".to_string(),
        "--json".to_string(),
        "--counts-only".to_string(),
    ];
    args.extend(shell.index_arguments());
    args.extend(folders.clone());
    let launch = shell.launch(args, "estimate.log");
    let shell = shell.inner().clone();
    let generation = shell.estimates.request();
    tauri::async_runtime::spawn_blocking(move || {
        let Some((status, output)) = shell.estimates.output(generation, &launch)? else {
            return Ok(None);
        };
        if !status.success() {
            return Err(format!("DigUp couldn't count these folders ({status}). Check folder access and the installed runtime DLLs."));
        }
        associate_estimates(&output, &folders).map(Some)
    })
    .await
    .map_err(|error| error.to_string())?
}

/// `estimate --json` emits one line per input, in order, including unreadable folders.
/// The returned folder can use a canonical Windows/8.3 spelling; keep the UI's original key.
fn associate_estimates(output: &[u8], folders: &[String]) -> Result<Vec<Value>, String> {
    let mut answers: Vec<Value> = String::from_utf8_lossy(output)
        .lines()
        .map(serde_json::from_str)
        .collect::<Result<_, _>>()
        .map_err(|_| "DigUp returned an invalid folder estimate".to_string())?;
    if answers.len() != folders.len() || answers.iter().any(|answer| !answer.is_object()) {
        return Err("DigUp didn't report an estimate for every chosen folder".into());
    }
    for (answer, folder) in answers.iter_mut().zip(folders) {
        answer["requestedFolder"] = json!(folder);
    }
    Ok(answers)
}

/// What the setup window starts from: the folders it offers, the hotkey, the model, the folders already chosen.
#[tauri::command]
fn setup_info(app: AppHandle, shell: State<'_, Arc<Shell>>) -> Value {
    let mut offered: Vec<PathBuf> = match &shell.options.offered {
        Some(folders) => folders.clone(),
        None => {
            let paths = app.path();
            [
                paths.document_dir(),
                paths.picture_dir(),
                paths.video_dir(),
                paths.audio_dir(),
                paths.desktop_dir(),
                paths.download_dir(),
            ]
            .into_iter()
            .filter_map(Result::ok)
            .filter(|folder| folder.is_dir())
            .collect()
        }
    };
    let reconfigure = shell.debug_reconfigure_started.load(Ordering::SeqCst);
    if reconfigure {
        if let Some(folder) = &shell.options.debug_reconfigure_folder {
            offered.push(folder.clone());
        }
    }
    json!({
        "offered": offered.iter().map(|folder| folder.display().to_string()).collect::<Vec<_>>(),
        "chosen": shell.folders(),
        "codeRoots": shell.code_roots(),
        "hotkey": shortcut_text(&shell.hotkey()),
        "model": shell.model_state.lock().unwrap().clone(),
        "auto": shell.options.debug_setup,
        "language": shell.settings.lock().unwrap().language,
        "debugUiFeatures": shell.options.debug_ui_features,
        "debugDevice": shell.options.debug_device,
        "debugReconfigure": reconfigure,
        "autostart": autostart::enabled(),
        "autostartSupported": cfg!(windows),
        "device": shell.options.effective_device(shell.settings.lock().unwrap().device),
        "deviceOverridden": shell.options.device_is_overridden(),
    })
}

/// Folders chosen in the system's folder picker (none when it's cancelled).
#[tauri::command]
async fn pick_folders(app: AppHandle) -> Vec<String> {
    let (sender, receiver) = tokio::sync::oneshot::channel();
    app.dialog()
        .file()
        .set_title(
            app.state::<Arc<Shell>>()
                .settings
                .lock()
                .unwrap()
                .language
                .text("Add Folders", "Добавить папки"),
        )
        .pick_folders(move |folders| {
            let _ = sender.send(folders);
        });
    let picked = receiver.await.ok().flatten().unwrap_or_default();
    picked
        .into_iter()
        .filter_map(|folder| folder.into_path().ok())
        .map(|path| path.display().to_string())
        .collect()
}

/// Setup's last step: the folders are saved and indexing starts (once the model is in).
#[tauri::command]
async fn finish_setup(
    app: AppHandle,
    shell: State<'_, Arc<Shell>>,
    folders: Vec<String>,
    code_roots: Option<Vec<String>>,
    launch_at_login: Option<bool>,
    device: Option<Device>,
) -> Result<(), String> {
    let shell = shell.inner().clone();
    let apply = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let _configuration = shell.configuration.lock().unwrap();
        if shell.shutting_down.load(Ordering::SeqCst) {
            return Err("DigUp is shutting down".to_string());
        }
        shell.estimates.cancel();
        let was_enabled = autostart::enabled();
        if let Some(enabled) = launch_at_login {
            autostart::set(enabled)?;
        }
        let mut settings = shell.settings.lock().unwrap();
        let mut updated = settings.clone();
        updated.folders = folders;
        if let Some(code_roots) = code_roots {
            updated.code_roots = code_roots;
        }
        if !shell.options.device_is_overridden() {
            if let Some(device) = device {
                updated.device = device;
            }
        }
        let device_changed = updated.device != settings.device;
        updated.set_up = true;
        if let Err(error) = updated.save(&shell.settings_path) {
            if launch_at_login.is_some() {
                let _ = autostart::set(was_enabled);
            }
            return Err(format!("Can't save the settings: {error}"));
        }
        *settings = updated;
        drop(settings);
        if shell.debug_reconfigure_started.load(Ordering::SeqCst) {
            shell.debug_reconfigure_done.store(true, Ordering::SeqCst);
        }
        if device_changed {
            shell.index.stop();
        }
        apply_folders(&apply);
        Ok(())
    })
    .await
    .map_err(|error| error.to_string())??;
    if let Some(window) = app.get_webview_window("setup") {
        let _ = window.close();
    }
    if !app.state::<Arc<Shell>>().options.debug_setup {
        show_panel(&app);
    }
    Ok(())
}

/// Opens a result in its default app.
#[tauri::command]
fn open_path(app: AppHandle, path: String) -> Result<(), String> {
    hide_panel(app.clone());
    app.opener()
        .open_path(path, None::<&str>)
        .map_err(|error| error.to_string())
}

/// Shows a result in the file manager, selected.
#[tauri::command]
fn reveal(app: AppHandle, path: String) -> Result<(), String> {
    hide_panel(app.clone());
    app.opener()
        .reveal_item_in_dir(path)
        .map_err(|error| error.to_string())
}

#[tauri::command]
fn hide_panel(app: AppHandle) {
    if let Some(panel) = app.get_webview_window("panel") {
        let _ = panel.hide();
    }
}

#[tauri::command]
fn retry_model(app: AppHandle) {
    start_model_download(&app);
}

/// The panel grows to show results and shrinks back to its field.
#[tauri::command]
fn panel_height(app: AppHandle, height: f64, graph: Option<bool>) {
    if let Some(panel) = app.get_webview_window("panel") {
        let shell = app.state::<Arc<Shell>>();
        // A canonical native WebView viewport makes isolated visual checks independent
        // of a CI runner's virtual desktop size. Normal windows still fit their monitor.
        let smoke_viewport = shell.options.debug_isolated
            && shell.options.debug_ui_features
            && graph.unwrap_or(false);
        let monitor = panel.current_monitor().ok().flatten();
        let scale = monitor
            .as_ref()
            .map(|screen| screen.scale_factor())
            .unwrap_or(1.0);
        let maximum_height = if smoke_viewport {
            None
        } else {
            monitor.as_ref()
        }
        .map(|screen| screen.work_area().size.height as f64 / scale - 24.0)
        .unwrap_or(900.0)
        .max(FIELD_HEIGHT);
        let maximum_width = if smoke_viewport {
            None
        } else {
            monitor.as_ref()
        }
        .map(|screen| screen.work_area().size.width as f64 / scale - 24.0)
        .unwrap_or(1280.0)
        .max(320.0);
        let actual = height.clamp(FIELD_HEIGHT, 900.0).min(maximum_height);
        let width = (if graph.unwrap_or(false) {
            1280.0_f64
        } else {
            PANEL_WIDTH
        })
        .min(maximum_width);
        let previous_size = panel.outer_size().ok();
        let _ = panel.set_size(LogicalSize::new(width, actual));
        if let (Some(screen), Ok(position)) = (monitor, panel.outer_position()) {
            let work = screen.work_area();
            let bottom = work.position.y + work.size.height as i32 - (actual * scale).ceil() as i32;
            let right = work.position.x + work.size.width as i32 - (width * scale).ceil() as i32;
            let centered = previous_size
                .map(|old| position.x + (old.width as i32 - (width * scale) as i32) / 2)
                .unwrap_or(position.x);
            let x = centered.clamp(work.position.x, right.max(work.position.x));
            let y = position
                .y
                .clamp(work.position.y, bottom.max(work.position.y));
            let _ = panel.set_position(PhysicalPosition::new(x, y));
        }
    }
}

/// Debug runs: the query the panel types in when it loads (with setup, it comes later as a "debug-query" event).
#[tauri::command]
async fn debug_query(shell: State<'_, Arc<Shell>>) -> Result<Option<String>, String> {
    if shell.options.debug_setup && !shell.debug_panel_reopened.load(Ordering::SeqCst) {
        return Ok(None);
    }
    if shell.debug_panel_reopened.load(Ordering::SeqCst) {
        let _ = shell.search.ask(json!({"op": "reload"})).await;
    }
    Ok(shell.options.debug_query.clone())
}

#[tauri::command]
fn debug_search_options(shell: State<'_, Arc<Shell>>) -> Value {
    json!({"loadAll": shell.options.debug_load_all, "graph": shell.options.debug_graph, "features": shell.options.debug_ui_features})
}

#[tauri::command]
fn debug_setup_snapshot(shell: State<'_, Arc<Shell>>, report: Value) {
    if shell.options.debug_setup {
        shell.debug_setup_history.lock().unwrap().push(report);
    }
}

/// Native pixels of the test WebView only; no desktop capture and no arbitrary destination.
#[tauri::command]
async fn debug_capture(
    app: AppHandle,
    shell: State<'_, Arc<Shell>>,
    label: String,
) -> Result<Value, String> {
    if !shell.options.debug_isolated
        || !shell.options.debug_ui_features
        || !["documents", "media", "comparison", "timeline", "context"].contains(&label.as_str())
    {
        return Err(
            "Native capture requires the isolated UI feature smoke and a known phase".into(),
        );
    }
    let path = shell
        .options
        .index
        .as_ref()
        .ok_or("Missing isolated index")?
        .join(format!("capture-{label}.png"));
    let window = app.get_webview_window("panel").ok_or("Missing panel")?;
    capture::webview_png(window, path.clone()).await?;
    Ok(json!({"path": path}))
}

/// Debug runs: what the page showed for the debug query, printed (and the shell quits, if asked).
#[tauri::command]
fn debug_report(app: AppHandle, shell: State<'_, Arc<Shell>>, mut report: Value) {
    #[cfg(windows)]
    {
        report["nativeCornerRegionRounded"] = json!(app
            .get_webview_window("panel")
            .and_then(|window| panel_corner_region(&window)));
        report["nativeCornerPreference"] = json!(app
            .get_webview_window("panel")
            .and_then(|window| panel_corner_preference(&window)));
    }
    let saved_device = shell.settings.lock().unwrap().device;
    report["savedLanguage"] = json!(shell.settings.lock().unwrap().language);
    report["savedDevice"] = json!(saved_device);
    report["devicePreference"] = json!(shell.options.effective_device(saved_device));
    report["deviceOverridden"] = json!(shell.options.device_is_overridden());
    report["setupHistory"] = json!(shell.debug_setup_history.lock().unwrap().clone());
    report["indexing"]["engineHistory"] = json!(shell.debug_index_history.lock().unwrap().clone());
    report["indexing"]["panelReopened"] = json!(shell.debug_panel_reopened.load(Ordering::SeqCst));
    report["indexing"]["panelLifecycle"] =
        json!(if shell.debug_panel_reopened.load(Ordering::SeqCst) {
            "reloadedWebView"
        } else {
            "originalWebView"
        });
    println!("{report}");
    if let Some(path) = &shell.options.debug_report {
        if std::fs::write(path, report.to_string()).is_err() {
            app.exit(2);
            return;
        }
    }
    if shell.options.debug_quit {
        quit(&app);
    }
}

/// Guarded smoke diagnostics must survive a failure before the page can submit its report.
fn debug_failure(app: &AppHandle, step: &str, error: &str) {
    let shell = app.state::<Arc<Shell>>();
    if shell.options.debug_isolated {
        if let Some(path) = &shell.options.debug_report {
            let _ = std::fs::write(
                path.with_extension("failure.json"),
                json!({"result": "failed", "step": step, "error": error}).to_string(),
            );
        }
    }
    app.exit(2);
}

fn main() {
    #[cfg(windows)]
    {
        use windows_sys::Win32::System::Diagnostics::Debug::{
            GetErrorMode, SetErrorMode, SEM_FAILCRITICALERRORS,
        };
        // SAFETY: initialize once, before creating threads. Helpers inherit this mode; loader failures are reported
        // through our protocol/error handling instead of blocking behind a Windows critical-error message box.
        unsafe {
            SetErrorMode(GetErrorMode() | SEM_FAILCRITICALERRORS);
        }
    }
    let options = match Options::from_args() {
        Ok(options) => options,
        Err(error) => {
            eprintln!("digup-shell: {error}");
            std::process::exit(2);
        }
    };
    let mut builder = tauri::Builder::default();
    if !options.debug_isolated {
        builder = builder.plugin(tauri_plugin_single_instance::init(|app, _, _| {
            show_panel(app)
        }));
    }
    let app = builder
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, _, event| {
                    if event.state == ShortcutState::Pressed {
                        toggle_panel(app);
                    }
                })
                .build(),
        )
        .setup(move |app| setup(app, options))
        .invoke_handler(tauri::generate_handler![
            ask,
            index_status,
            language,
            set_language,
            estimate,
            setup_info,
            pick_folders,
            finish_setup,
            open_path,
            reveal,
            hide_panel,
            panel_height,
            debug_query,
            debug_search_options,
            debug_report,
            debug_capture,
            graph_annotations,
            save_graph_annotations,
            debug_setup_snapshot,
            retry_model
        ])
        .build(tauri::generate_context!())
        .expect("DigUp couldn't start");
    app.run(|app, event| match event {
        tauri::RunEvent::Exit => stop_helpers(app),
        // Closing the setup window isn't quitting: DigUp lives in the tray.
        tauri::RunEvent::ExitRequested {
            code: None, api, ..
        } => api.prevent_exit(),
        _ => {}
    });
}

fn setup(app: &mut tauri::App, mut options: Options) -> Result<(), Box<dyn std::error::Error>> {
    #[cfg(target_os = "macos")]
    app.set_activation_policy(tauri::ActivationPolicy::Accessory); // the menu bar only, no Dock icon

    let handle = app.handle().clone();
    options.helper = resources::resolve_helper(
        options.helper_explicit.then_some(options.helper.as_path()),
        &std::env::current_exe()?,
        app.path().resource_dir().ok().as_deref(),
    );
    let logs = if options.debug_isolated {
        options
            .index
            .as_ref()
            .expect("validated isolated index")
            .join("shell-logs")
    } else {
        app.path().app_log_dir()?
    };
    std::fs::create_dir_all(&logs)?;
    let settings_path = match &options.settings {
        Some(path) => path.clone(),
        None => app.path().app_config_dir()?.join("settings.json"),
    };
    let settings = Settings::load(&settings_path);
    let roots: Vec<String> = if options.roots.is_empty() {
        settings.folders.clone()
    } else {
        options
            .roots
            .iter()
            .map(|root| root.display().to_string())
            .collect()
    };
    let mut search_args = vec!["search-service".to_string(), "--restrict-roots".to_string()];
    search_args.extend(
        options
            .index
            .iter()
            .flat_map(|index| ["--index".to_string(), index.display().to_string()]),
    );
    search_args.extend(roots);
    let code_roots: Vec<String> = if options.code_roots.is_empty() {
        settings.code_roots.clone()
    } else {
        options
            .code_roots
            .iter()
            .map(|root| root.display().to_string())
            .collect()
    };
    for folder in &code_roots {
        search_args.extend(["--code-root".to_string(), folder.clone()]);
    }
    let search = SearchService::new(
        Launch {
            program: options.helper.clone(),
            args: search_args,
            env: options.helper_environment(settings.device),
            log: Some(logs.join("search.log")),
            background: false, // it answers typing
        },
        {
            let app = handle.clone();
            move |event| search_event(&app, event)
        },
    );
    let index = IndexService::new({
        let app = handle.clone();
        move |event| index_event(&app, event)
    });
    let model = ModelDownload::new({
        let app = handle.clone();
        move |event| model_event(&app, event)
    });
    // Previews show files from the chosen folders (and the helper's renders, once it says where the index is).
    for root in settings.folders.iter().chain(code_roots.iter()) {
        let _ = app.asset_protocol_scope().allow_directory(root, true);
    }
    for root in &options.roots {
        let _ = app.asset_protocol_scope().allow_directory(root, true);
    }
    let shell = Arc::new(Shell {
        options,
        settings: Mutex::new(settings),
        configuration: Mutex::new(()),
        settings_path,
        search,
        index,
        model,
        estimates: Estimates::default(),
        model_state: Mutex::new(json!({"state": "checking"})),
        watcher: Mutex::new(None),
        status: Mutex::new(None),
        tray_labels: Mutex::new(Vec::new()),
        index_status: Mutex::new(IndexStatus::default()),
        reloaded: Mutex::new(Instant::now()),
        debug_query_sent: AtomicBool::new(false),
        debug_reconfigure_started: AtomicBool::new(false),
        debug_reconfigure_done: AtomicBool::new(false),
        debug_panel_reopened: AtomicBool::new(false),
        debug_setup_history: Mutex::new(Vec::new()),
        debug_index_history: Mutex::new(Vec::new()),
        indexing_paused: AtomicBool::new(false),
        shutting_down: AtomicBool::new(false),
        logs,
    });
    app.manage(shell.clone());

    make_panel(&handle)?;
    // No tray (a session without a taskbar, a Linux desktop without one): the hotkey and the panel still work.
    if !shell.options.debug_isolated {
        if let Err(error) = make_tray(&handle, &shell) {
            eprintln!("digup-shell: no tray icon: {error}");
        }
        let hotkey = shell.hotkey();
        if let Err(error) = app.global_shortcut().register(hotkey.as_str()) {
            set_status(
                &handle,
                &format!("The shortcut {} is taken", shortcut_text(&hotkey)),
            );
            eprintln!("digup-shell: can't use {hotkey} as the shortcut: {error}");
        }
    }

    // The search service starts now (the first search is then quick); the model is checked (and fetched if it's
    // missing: on first launch that runs while setup is open, as on the Mac); indexing waits for both.
    let warm = shell.clone();
    tauri::async_runtime::spawn(async move {
        let _ = warm.search.ask(json!({"op": "status"})).await;
    });
    start_model_download(&handle);
    if shell.is_set_up() {
        watch_folders(&handle);
    } else {
        show_setup(&handle)?;
    }
    if shell.options.debug_show {
        show_panel(&handle);
    }
    Ok(())
}

fn start_model_download(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    if shell.shutting_down.load(Ordering::SeqCst) {
        return;
    }
    let mut download = vec!["download-model".to_string()];
    if let Some(models) = &shell.options.models {
        download.extend(["--to".to_string(), models.display().to_string()]);
    }
    *shell.model_state.lock().unwrap() = json!({"state": "checking"});
    let _ = app.emit("model", json!({"state": "checking"}));
    if let Err(error) = shell.model.run(&shell.launch(download, "model.log")) {
        model_event(app, json!({"event": "error", "message": error}));
    }
}

/// After setup or a change of folders: the search service, the watcher and indexing follow the new folders.
fn apply_folders(app: &AppHandle) {
    let _ = app.emit("search-scope-changed", ());
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let folders = shell.folders();
    let code_roots = shell.code_roots();
    let (skipped, types) = {
        let settings = shell.settings.lock().unwrap();
        (settings.skipped.clone(), settings.skip_types.clone())
    };
    let mut search_args = vec!["search-service".to_string(), "--restrict-roots".to_string()];
    search_args.extend(shell.index_arguments());
    for folder in &code_roots {
        search_args.extend(["--code-root".to_string(), folder.clone()]);
    }
    for folder in &skipped {
        search_args.extend(["--exclude".to_string(), folder.clone()]);
    }
    for extension in &types {
        search_args.extend(["--exclude-ext".to_string(), extension.clone()]);
    }
    search_args.extend(folders.clone());
    let environment = shell
        .options
        .helper_environment(shell.settings.lock().unwrap().device);
    shell.search.configure(search_args, environment);
    for folder in folders.iter().chain(code_roots.iter()) {
        let _ = app.asset_protocol_scope().allow_directory(folder, true);
    }
    let search = shell.clone();
    tauri::async_runtime::spawn(async move {
        let _ = search
            .search
            .ask(json!({"op": "folders", "roots": folders, "skipped": skipped, "types": types, "code_roots": code_roots}))
            .await;
    });
    watch_folders(app);
}

/// Watches the folders, and indexes them now when the model is in.
fn watch_folders(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let folders: Vec<PathBuf> = shell.all_folders().iter().map(PathBuf::from).collect();
    // Stop the previous subscription even when the last selected folder was removed.
    shell.watcher.lock().unwrap().take();
    if folders.is_empty() {
        let shell = shell.clone();
        tauri::async_runtime::spawn_blocking(move || shell.index.stop());
        set_status(app, "No folders chosen yet");
        set_index_phase(app, "no-folders", None);
        return;
    }
    let changed = {
        let app = app.clone();
        move || run_index(&app)
    };
    *shell.watcher.lock().unwrap() = Some(FolderWatcher::start(
        &folders,
        shell.options.index_folder(),
        changed,
        |warning| {
            set_status(app, warning);
            let shell = app.state::<Arc<Shell>>();
            let mut status = shell.index_status.lock().unwrap();
            status.message = Some(warning.into());
            status.revision += 1;
            let _ = app.emit("index-status", status.clone());
        },
    ));
    run_index(app);
}

/// Has the index helper sync and index, once there's a model and a folder.
fn run_index(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    if !shell.is_set_up() || shell.all_folders().is_empty() || !shell.model_ready() {
        return;
    }
    let app = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let _configuration = shell.configuration.lock().unwrap();
        if shell.indexing_paused.load(Ordering::SeqCst)
            || shell.shutting_down.load(Ordering::SeqCst)
        {
            return;
        }
        if let Err(error) = shell.index.run(&shell.index_launch()) {
            set_status(&app, &format!("Indexing couldn't start: {error}"));
            set_index_phase(
                &app,
                "error",
                Some(format!("Indexing couldn't start: {error}")),
            );
        }
    });
}

fn stop_helpers(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>();
    shell.shutting_down.store(true, Ordering::SeqCst);
    shell.watcher.lock().unwrap().take();
    shell.estimates.close();
    shell.model.stop();
    shell.index.close();
    shell.search.stop();
}

fn quit(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>();
    if shell.shutting_down.swap(true, Ordering::SeqCst) {
        return;
    }
    let app = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        stop_helpers(&app);
        app.exit(0);
    });
}

// MARK: Windows

#[cfg(windows)]
fn round_panel_corners(window: &tauri::WebviewWindow) {
    use windows_sys::Win32::Graphics::{
        Dwm::{DwmSetWindowAttribute, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND},
        Gdi::{CreateRoundRectRgn, DeleteObject, SetWindowRgn},
    };
    if let Ok(hwnd) = window.hwnd() {
        // DWM clips the opaque WebView itself on Windows 11: no second transparent frame.
        // SAFETY: live HWND and an i32 read only for this call.
        let result = unsafe {
            DwmSetWindowAttribute(
                hwnd.0,
                DWMWA_WINDOW_CORNER_PREFERENCE as u32,
                (&DWMWCP_ROUND as *const i32).cast(),
                std::mem::size_of::<i32>() as u32,
            )
        };
        if result < 0 {
            // Windows 10 fallback. Region coordinates are physical pixels; recompute on size/DPI changes.
            if let (Ok(size), Ok(scale)) = (window.outer_size(), window.scale_factor()) {
                let diameter = (16.0 * scale).round() as i32;
                // SAFETY: owned GDI region. On success Windows owns it, on failure we delete it.
                unsafe {
                    let region = CreateRoundRectRgn(
                        0,
                        0,
                        size.width as i32 + 1,
                        size.height as i32 + 1,
                        diameter,
                        diameter,
                    );
                    if !region.is_null() && SetWindowRgn(hwnd.0, region, 1) == 0 {
                        DeleteObject(region);
                    }
                }
            }
        }
    }
}

#[cfg(windows)]
fn panel_corner_region(window: &tauri::WebviewWindow) -> Option<bool> {
    use windows_sys::Win32::Graphics::Gdi::{
        CreateRectRgn, DeleteObject, GetWindowRgn, PtInRegion,
    };
    let hwnd = window.hwnd().ok()?;
    let size = window.outer_size().ok()?;
    // SAFETY: a private GDI region receives the window region's copy and is always released here.
    unsafe {
        let region = CreateRectRgn(0, 0, 0, 0);
        if region.is_null() {
            return None;
        }
        let kind = GetWindowRgn(hwnd.0, region);
        let rounded = kind > 0
            && PtInRegion(region, 0, 0) == 0
            && PtInRegion(region, size.width as i32 / 2, size.height as i32 / 2) != 0
            && PtInRegion(region, size.width as i32 - 1, size.height as i32 - 1) == 0;
        DeleteObject(region);
        (kind > 0).then_some(rounded)
    }
}

#[cfg(windows)]
fn panel_corner_preference(window: &tauri::WebviewWindow) -> Option<i32> {
    use windows_sys::Win32::Graphics::Dwm::{
        DwmGetWindowAttribute, DWMWA_WINDOW_CORNER_PREFERENCE,
    };
    let hwnd = window.hwnd().ok()?;
    let mut preference = 0i32;
    // SAFETY: the live HWND and writable i32 remain valid for the duration of this call.
    let result = unsafe {
        DwmGetWindowAttribute(
            hwnd.0,
            DWMWA_WINDOW_CORNER_PREFERENCE as u32,
            (&mut preference as *mut i32).cast(),
            std::mem::size_of::<i32>() as u32,
        )
    };
    (result >= 0).then_some(preference)
}

fn make_panel(app: &AppHandle) -> tauri::Result<()> {
    let mut builder = WebviewWindowBuilder::new(app, "panel", WebviewUrl::App("index.html".into()));
    let shell = app.state::<Arc<Shell>>();
    if shell.options.debug_isolated {
        builder = builder.data_directory(shell.options.index.as_ref().unwrap().join(".webview"));
    }
    let panel = builder
        .title("DigUp")
        .inner_size(PANEL_WIDTH, FIELD_HEIGHT)
        .decorations(false)
        .transparent(!cfg!(windows))
        .shadow(true)
        .resizable(false)
        .maximizable(false)
        .minimizable(false)
        .always_on_top(true)
        .visible_on_all_workspaces(true)
        .skip_taskbar(true)
        .visible(false)
        .build()?;
    #[cfg(windows)]
    round_panel_corners(&panel);
    let app = app.clone();
    panel.on_window_event(move |event| {
        #[cfg(windows)]
        if matches!(
            event,
            WindowEvent::Resized(_) | WindowEvent::ScaleFactorChanged { .. }
        ) {
            if let Some(window) = app.get_webview_window("panel") {
                round_panel_corners(&window);
            }
        }
        // Like Spotlight: it steps away when you click elsewhere.
        if let WindowEvent::Focused(false) = event {
            if !app.state::<Arc<Shell>>().options.debug_show {
                hide_panel(app.clone());
            }
        }
    });
    Ok(())
}

fn show_panel(app: &AppHandle) {
    if !app.state::<Arc<Shell>>().is_set_up() {
        let _ = show_setup(app);
        return;
    }
    let Some(panel) = app.get_webview_window("panel") else {
        return;
    };
    // On the screen with the pointer, centered, a fifth of the way down.
    if let Ok(pointer) = app.cursor_position() {
        if let Ok(Some(screen)) = app.monitor_from_point(pointer.x, pointer.y) {
            let logical_width = panel
                .inner_size()
                .map(|size| size.width as f64 / panel.scale_factor().unwrap_or(1.0))
                .unwrap_or(PANEL_WIDTH);
            let width = (logical_width * screen.scale_factor()) as i32;
            let x = screen.position().x + (screen.size().width as i32 - width) / 2;
            let y = screen.position().y + (screen.size().height as f64 * 0.2) as i32;
            let _ = panel.set_position(PhysicalPosition::new(x, y));
        }
    }
    let _ = panel.show();
    let _ = panel.set_focus();
    let _ = panel.emit("panel-shown", ());
}

fn toggle_panel(app: &AppHandle) {
    match app.get_webview_window("panel") {
        Some(panel) if panel.is_visible().unwrap_or(false) => hide_panel(app.clone()),
        _ => show_panel(app),
    }
}

/// The setup window (first launch, and Choose Folders… later). Debug runs that click through it keep it hidden.
fn show_setup(app: &AppHandle) -> tauri::Result<()> {
    if let Some(window) = app.get_webview_window("setup") {
        let _ = window.show();
        let _ = window.set_focus();
        return Ok(());
    }
    let hidden = app.state::<Arc<Shell>>().options.debug_setup;
    let mut builder = WebviewWindowBuilder::new(app, "setup", WebviewUrl::App("setup.html".into()));
    let shell = app.state::<Arc<Shell>>();
    if shell.options.debug_isolated {
        builder = builder.data_directory(shell.options.index.as_ref().unwrap().join(".webview"));
    }
    let window = builder
        .title(
            shell
                .settings
                .lock()
                .unwrap()
                .language
                .text("Set Up DigUp", "Настройка DigUp"),
        )
        .inner_size(720.0, 600.0)
        .resizable(false)
        .maximizable(false)
        .center()
        .visible(!hidden)
        .build()?;
    let shell = shell.inner().clone();
    window.on_window_event(move |event| {
        if matches!(event, WindowEvent::Destroyed) {
            let generation = shell.estimates.request();
            let shell = shell.clone();
            tauri::async_runtime::spawn_blocking(move || shell.estimates.cancel_before(generation));
        }
    });
    Ok(())
}

/// "CommandOrControl+Shift+Space" as people read it here: "Ctrl+Shift+Space", or "⇧⌘Space" on a Mac.
fn shortcut_text(accelerator: &str) -> String {
    let parts: Vec<&str> = accelerator.split('+').collect();
    if cfg!(target_os = "macos") {
        let mut text = String::new();
        for (name, sign) in [
            ("Ctrl", "⌃"),
            ("Control", "⌃"),
            ("Alt", "⌥"),
            ("Option", "⌥"),
            ("Shift", "⇧"),
            ("CommandOrControl", "⌘"),
            ("CmdOrCtrl", "⌘"),
            ("Cmd", "⌘"),
            ("Command", "⌘"),
            ("Super", "⌘"),
        ] {
            if parts.iter().any(|part| part.eq_ignore_ascii_case(name)) && !text.contains(sign) {
                text.push_str(sign);
            }
        }
        return text + parts.last().copied().unwrap_or_default();
    }
    parts
        .iter()
        .map(|part| match *part {
            "CommandOrControl" | "CmdOrCtrl" | "Control" => "Ctrl",
            "Super" => "Win",
            other => other,
        })
        .collect::<Vec<_>>()
        .join("+")
}

// MARK: The tray

fn make_tray(app: &AppHandle, shell: &Arc<Shell>) -> tauri::Result<()> {
    let status = MenuItem::with_id(app, "status", "Starting…", false, None::<&str>)?;
    let search = MenuItem::with_id(
        app,
        "search",
        "Search…",
        true,
        Some(shell.hotkey().as_str()),
    )?;
    let folders = MenuItem::with_id(app, "folders", "Choose Folders…", true, None::<&str>)?;
    let index = MenuItem::with_id(app, "index", "Index Now / Resume", true, None::<&str>)?;
    let pause = MenuItem::with_id(app, "pause", "Pause Indexing", true, None::<&str>)?;
    let model = MenuItem::with_id(app, "model", "Retry Model Download", true, None::<&str>)?;
    let quit_item = MenuItem::with_id(app, "quit", "Quit DigUp", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;
    let menu = Menu::with_items(
        app,
        &[
            &status,
            &separator,
            &search,
            &folders,
            &index,
            &pause,
            &model,
            &PredefinedMenuItem::separator(app)?,
            &quit_item,
        ],
    )?;
    *shell.tray_labels.lock().unwrap() = vec![
        (search.clone(), "Search…".into(), "Поиск…".into()),
        (
            folders.clone(),
            "Choose Folders…".into(),
            "Выбрать папки…".into(),
        ),
        (
            index.clone(),
            "Index Now / Resume".into(),
            "Индексировать / Продолжить".into(),
        ),
        (
            pause.clone(),
            "Pause Indexing".into(),
            "Приостановить индексацию".into(),
        ),
        (
            model.clone(),
            "Retry Model Download".into(),
            "Повторить загрузку модели".into(),
        ),
        (
            quit_item.clone(),
            "Quit DigUp".into(),
            "Выйти из DigUp".into(),
        ),
    ];
    for (item, en, ru) in shell.tray_labels.lock().unwrap().iter() {
        item.set_text(shell.settings.lock().unwrap().language.text(en, ru))?;
    }
    // A Mac's menu bar takes a template (it colors it); trays elsewhere show the app's own small icon.
    #[cfg(target_os = "macos")]
    let icon = tauri::include_image!("icons/tray-template.png");
    #[cfg(not(target_os = "macos"))]
    let icon = tauri::include_image!("icons/tray.png");
    TrayIconBuilder::with_id("digup")
        .icon(icon)
        .icon_as_template(cfg!(target_os = "macos"))
        .tooltip("DigUp")
        .menu(&menu)
        .show_menu_on_left_click(cfg!(target_os = "macos"))
        .on_menu_event(|app, event| match event.id().as_ref() {
            "search" => show_panel(app),
            "folders" => {
                let _ = show_setup(app);
            }
            "index" => {
                let shell = app.state::<Arc<Shell>>();
                shell.indexing_paused.store(false, Ordering::SeqCst);
                if shell.all_folders().is_empty() {
                    set_index_phase(app, "no-folders", None);
                } else if shell.model_ready() {
                    set_index_phase(app, "starting", None);
                } else {
                    set_index_phase(app, "waiting", Some("The model is not ready. Choose Retry Model Download in the tray if the download failed.".into()));
                }
                run_index(app);
            }
            "pause" => {
                let shell = app.state::<Arc<Shell>>().inner().clone();
                shell.indexing_paused.store(true, Ordering::SeqCst);
                set_index_phase(app, "paused", None);
                let app = app.clone();
                tauri::async_runtime::spawn_blocking(move || {
                    shell.index.stop();
                    set_status(
                        &app,
                        "Indexing paused — choose Index Now / Resume to continue",
                    );
                });
            }
            "model" => start_model_download(app),
            "quit" => quit(app),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            // Windows and Linux: a click opens the panel, the menu is on the other button.
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                if !cfg!(target_os = "macos") {
                    toggle_panel(tray.app_handle());
                }
            }
        })
        .build(app)?;
    *shell.status.lock().unwrap() = Some(status);
    Ok(())
}

fn set_status(app: &AppHandle, text: &str) {
    let shell = app.state::<Arc<Shell>>();
    let language = shell.settings.lock().unwrap().language;
    let russian = match shell.index_status.lock().unwrap().stage.as_str() {
        "starting" => "Подготовка индекса…",
        "scanning" => "Сканирование папок…",
        "indexing" => "Индексация файлов…",
        "rest" => "Чтение длинных файлов…",
        "idle" => "Индекс обновлён",
        "paused" => "Индексация приостановлена",
        "waiting" => "Ожидание модели",
        "no-folders" => "Папки не выбраны",
        _ => "Проверьте состояние индекса в окне поиска",
    };
    if let Some(status) = shell.status.lock().unwrap().as_ref() {
        let _ = status.set_text(language.text(text, russian));
    }
    let _ = app.emit("status", text);
}

fn set_index_phase(app: &AppHandle, stage: &str, message: Option<String>) {
    let shell = app.state::<Arc<Shell>>();
    let mut status = shell.index_status.lock().unwrap();
    status.phase(stage, message);
    let _ = app.emit("index-status", status.clone());
}

// MARK: The helpers' events

fn search_event(app: &AppHandle, event: Value) {
    if cfg!(debug_assertions) {
        println!("search: {event}");
    }
    if event["event"] == "ready" {
        if let Some(index) = event["index"].as_str() {
            let _ = app
                .asset_protocol_scope()
                .allow_directory(Path::new(index).join("previews"), false);
        }
    }
    let _ = app.emit("helper", json!({"from": "search", "event": event}));
}

fn index_event(app: &AppHandle, event: Value) {
    if cfg!(debug_assertions) {
        println!("index: {event}");
    }
    let count = |key: &str| event[key].as_u64().unwrap_or(0);
    {
        let shell = app.state::<Arc<Shell>>();
        let mut status = shell.index_status.lock().unwrap();
        if status.observe(&event) {
            if shell.options.debug_report.is_some() {
                let mut history = shell.debug_index_history.lock().unwrap();
                if history.len() == 64 {
                    history.remove(0);
                }
                history.push(json!(status.clone()));
            }
            let _ = app.emit("index-status", status.clone());
        }
    }
    match event["event"].as_str().unwrap_or_default() {
        "scanning" => set_status(app, "Scanning folders…"),
        "indexing" => set_status(app, "Preparing to index files…"),
        "reading-rest" => set_status(app, "Reading the rest of long files…"),
        "file" => {
            set_status(
                app,
                &format!("Indexing {} of {}", count("done"), count("total")),
            );
            reload(app, false);
        }
        "rest" => {
            set_status(
                app,
                &format!("Reading the rest of {} long files", count("files")),
            );
            reload(app, false);
        }
        "idle" => {
            set_status(
                app,
                &format!(
                    "Up to date · {} files",
                    count("searchable") + count("code_searchable")
                ),
            );
            reload(app, true);
            // A debug run through setup searches once the first index is in.
            let shell = app.state::<Arc<Shell>>();
            if shell.options.debug_reconfigure_folder.is_some() {
                if !shell.debug_reconfigure_started.swap(true, Ordering::SeqCst) {
                    let app = app.clone();
                    let dispatch = app.clone();
                    let _ = dispatch.run_on_main_thread(move || {
                        let _ = show_setup(&app);
                    });
                    return;
                }
                if !shell.debug_reconfigure_done.load(Ordering::SeqCst) {
                    return;
                }
                if !shell.debug_panel_reopened.swap(true, Ordering::SeqCst) {
                    let app = app.clone();
                    let dispatch = app.clone();
                    if dispatch
                        .run_on_main_thread(move || {
                            // Reload creates a fresh JavaScript document and listeners. Destroying
                            // then immediately recreating a window races Tauri's asynchronous label removal.
                            match app.get_webview_window("panel") {
                                Some(panel) if panel.reload().is_ok() => {}
                                Some(_) => debug_failure(
                                    &app,
                                    "reload-panel",
                                    "The WebView document could not reload.",
                                ),
                                None => debug_failure(
                                    &app,
                                    "reload-panel",
                                    "The debug panel was not available.",
                                ),
                            }
                        })
                        .is_err()
                    {
                        debug_failure(
                            &dispatch,
                            "dispatch-panel-reload",
                            "The panel reload could not be scheduled.",
                        );
                    }
                    return;
                }
            }
            if let Some(query) = &shell.options.debug_query {
                if shell.options.debug_setup && !shell.debug_query_sent.swap(true, Ordering::SeqCst)
                {
                    let (app, shell, query) = (app.clone(), shell.inner().clone(), query.clone());
                    tauri::async_runtime::spawn(async move {
                        let _ = shell.search.ask(json!({"op": "reload"})).await;
                        let _ = app.emit_to("panel", "debug-query", query);
                    });
                }
            }
        }
        "waiting" => set_status(app, "Waiting for the model"),
        "error" => set_status(
            app,
            &format!("Indexing: {}", event["message"].as_str().unwrap_or("error")),
        ),
        "exit" => reload(app, true),
        _ => {}
    }
    let _ = app.emit("helper", json!({"from": "index", "event": event}));
}

fn model_event(app: &AppHandle, event: Value) {
    if cfg!(debug_assertions) && event["event"] != "progress" {
        println!("model: {event}");
    }
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let state = match event["event"].as_str().unwrap_or_default() {
        "progress" => {
            let (bytes, total) = (
                event["all_bytes"].as_f64().unwrap_or(0.0),
                event["all_total"].as_f64().unwrap_or(1.0),
            );
            set_status(
                app,
                &format!(
                    "Downloading the model · {:.0}%",
                    100.0 * bytes / total.max(1.0)
                ),
            );
            json!({"state": "downloading", "bytes": bytes, "total": total})
        }
        "file" => json!({"state": "downloading", "from": event["from"]}),
        "verifying" => json!({"state": "checking"}),
        "waiting" => json!({"state": "waiting"}),
        "retry" => json!({"state": "downloading", "problem": event["message"]}),
        "done" => json!({"state": "ready"}),
        "error" => {
            set_status(app, "The model couldn't download");
            json!({"state": "failed", "message": event["message"]})
        }
        _ => return,
    };
    let ready = state["state"] == "ready";
    *shell.model_state.lock().unwrap() = state.clone();
    let _ = app.emit("model", state);
    if !ready && !shell.indexing_paused.load(Ordering::SeqCst) {
        let model = shell.model_state.lock().unwrap().clone();
        let message = match model["state"].as_str() {
            Some("failed") => format!(
                "The model couldn't download: {}. Retry Model Download in the tray.",
                model["message"].as_str().unwrap_or("unknown error")
            ),
            Some("downloading") => "Downloading the model before indexing can start…".into(),
            Some("waiting") => "Waiting for the network to download the model…".into(),
            _ => "Checking the model before indexing can start…".into(),
        };
        set_index_phase(
            app,
            if model["state"] == "failed" {
                "error"
            } else {
                "waiting"
            },
            Some(message),
        );
    }
    if ready {
        if shell.all_folders().is_empty() {
            set_status(app, "No folders chosen yet");
            set_index_phase(app, "no-folders", None);
        } else if !shell.indexing_paused.load(Ordering::SeqCst) {
            set_index_phase(app, "starting", None);
        }
        run_index(app);
    }
}

/// Has the search service read the index again: at once when indexing settles, else at most every three seconds.
fn reload(app: &AppHandle, now: bool) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    if shell.shutting_down.load(Ordering::SeqCst) {
        return;
    }
    {
        let mut reloaded = shell.reloaded.lock().unwrap();
        if !now && reloaded.elapsed() < Duration::from_secs(3) {
            return;
        }
        *reloaded = Instant::now();
    }
    tauri::async_runtime::spawn(async move {
        let reply = shell.search.ask(json!({"op": "reload"})).await;
        if cfg!(debug_assertions) {
            println!("search: reload {reply:?}");
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn estimates_keep_requested_unicode_and_alias_keys() {
        let requested = vec![
            r"\\?\C:\DOCUME~1\Кириллица 🚀".to_string(),
            "D:/Other folder".into(),
        ];
        let output = concat!(
            "{\"folder\":\"C:/Documents/Кириллица 🚀\",\"readable\":true,\"files\":{\"doc\":3}}\n",
            "{\"folder\":\"D:/Other folder\",\"readable\":false}\n"
        );
        let answers = associate_estimates(output.as_bytes(), &requested).unwrap();
        assert_eq!(answers[0]["requestedFolder"], requested[0]);
        assert_eq!(answers[0]["files"]["doc"], 3);
        assert_eq!(answers[1]["requestedFolder"], requested[1]);
        assert_eq!(answers[1]["readable"], false);
        assert!(associate_estimates(b"{}\n", &requested).is_err());
        assert!(associate_estimates(b"not JSON\n{}\n", &requested).is_err());
    }
}
