//! DigUp's helper processes, which do all the work: `digup search-service` answers the panel (a JSON request per line
//! in, the reply on a line out with the request's id; lines without an id are events), and `digup index-service` keeps
//! the index current (commands in, events out) and exits when it's done. Sources/digup has both protocols.

use crate::process::HelperProcess;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::process::{ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::oneshot;

type EventSink = Arc<dyn Fn(Value) + Send + Sync>;

/// How a helper is started.
#[derive(Clone)]
pub struct Launch {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
    /// Where its standard error goes (llama.cpp and the helper write their warnings there).
    pub log: Option<PathBuf>,
    /// Work in the background (indexing, the download): below the person's own programs for the processor.
    pub background: bool,
}

impl Launch {
    pub fn command(&self) -> Result<Command, String> {
        if !self.program.is_absolute() || !self.program.is_file() {
            return Err("DigUp's helper is missing. Reinstall DigUp, or pass --helper with the complete path to digup.".into());
        }
        if std::env::current_exe()
            .ok()
            .and_then(|path| path.canonicalize().ok())
            == self.program.canonicalize().ok()
        {
            return Err(
                "The helper points to the DigUp GUI. Install digup in the helper directory.".into(),
            );
        }
        let mut command = Command::new(&self.program);
        command
            .args(&self.args)
            .envs(self.env.iter().map(|(key, value)| (key, value)))
            .env_remove("GGML_BACKEND_PATH")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(
                match self
                    .log
                    .as_ref()
                    .and_then(|path| OpenOptions::new().create(true).append(true).open(path).ok())
                {
                    Some(file) => Stdio::from(file),
                    None => Stdio::null(),
                },
            );
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            crate::resources::validate_packaged_runtime(&self.program)?;
            // Runtime tools live beside the helper. An installed app must not pick up another FFmpeg, a development
            // Python worker, or an unrelated llama backend from the caller's environment.
            let runtime = self
                .program
                .parent()
                .expect("absolute program has a parent");
            if crate::resources::is_packaged_helper(&self.program) {
                command
                    .env("DIGUP_FFMPEG", runtime)
                    .env("DIGUP_BACKENDS", runtime)
                    .env_remove("DIGUP_WORKER_DIR");
                let mut paths = vec![runtime.to_path_buf()];
                if let Some(windows) = std::env::var_os("SystemRoot") {
                    paths.push(PathBuf::from(windows).join("System32"));
                }
                command.env(
                    "PATH",
                    std::env::join_paths(paths).map_err(|error| error.to_string())?,
                );
            }
            // CREATE_NO_WINDOW (no console flashes up), and BELOW_NORMAL_PRIORITY_CLASS for background work.
            command.creation_flags(0x0800_0000 | if self.background { 0x0000_4000 } else { 0 });
        }
        #[cfg(unix)]
        if self.background {
            use std::os::unix::process::CommandExt;
            // SAFETY: nice() only changes the new process's own priority, between fork and exec.
            unsafe {
                command.pre_exec(|| {
                    libc::nice(10);
                    Ok(())
                });
            }
        }
        Ok(command)
    }

    fn spawn(&self) -> Result<(HelperProcess, ChildStdin, ChildStdout), String> {
        let child = self.command()?.spawn().map_err(|error| {
            format!("DigUp's helper couldn't start: {error}. Reinstall DigUp if a runtime DLL is missing.")
        })?;
        let mut child = HelperProcess::new(child)?;
        let stdin = child.stdin.take().ok_or("no stdin")?;
        let stdout = child.stdout.take().ok_or("no stdout")?;
        Ok((child, stdin, stdout))
    }

    pub fn output(&self) -> Result<(std::process::ExitStatus, Vec<u8>), String> {
        let (mut child, stdin, mut stdout) = self.spawn()?;
        drop(stdin);
        let mut output = Vec::new();
        stdout
            .read_to_end(&mut output)
            .map_err(|error| error.to_string())?;
        let status = child.wait().map_err(|error| error.to_string())?;
        Ok((status, output))
    }
}

/// Asks the process to stop (`farewell` on stdin, then stdin closed), and ends it if it hasn't within two seconds.
fn stop(mut child: HelperProcess, mut stdin: ChildStdin, farewell: &str) {
    // A stalled helper may no longer read stdin. Do not let a full pipe defeat the two-second shutdown deadline.
    let farewell = farewell.to_owned();
    std::thread::spawn(move || {
        let _ = writeln!(stdin, "{farewell}").and_then(|_| stdin.flush());
    });
    for _ in 0..40 {
        if matches!(child.try_wait(), Ok(Some(_))) {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let _ = child.kill();
    let _ = child.wait();
}

/// `digup search-service`: started on the first request, and again after it died.
pub struct SearchService {
    launch: Mutex<Launch>,
    running: Mutex<Option<Searching>>,
    next_id: AtomicU64,
    closed: AtomicBool,
    on_event: EventSink,
}

struct Searching {
    child: HelperProcess,
    stdin: ChildStdin,
    /// Replies still to come, by request id. Each process has its own, so one that dies fails only its own requests.
    pending: Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>>,
}

impl SearchService {
    pub fn new(launch: Launch, on_event: impl Fn(Value) + Send + Sync + 'static) -> SearchService {
        SearchService {
            launch: Mutex::new(launch),
            running: Mutex::new(None),
            next_id: AtomicU64::new(1),
            closed: AtomicBool::new(false),
            on_event: Arc::new(on_event),
        }
    }

    /// Keep restart arguments current; a changed device environment needs a fresh model process.
    /// May wait for the old helper to stop: call outside the UI thread.
    pub fn configure(&self, arguments: Vec<String>, environment: Vec<(String, String)>) {
        // Match send's lock order. No request can start the old configuration during replacement.
        let mut running = self.running.lock().unwrap();
        let mut launch = self.launch.lock().unwrap();
        let restart = launch.env != environment;
        launch.args = arguments;
        launch.env = environment;
        if restart {
            if let Some(searching) = running.take() {
                for (_, sender) in searching.pending.lock().unwrap().drain() {
                    let _ = sender.send(json!({"ok": false, "error": "The processing device changed. Please search again."}));
                }
                stop(
                    searching.child,
                    searching.stdin,
                    &json!({"op": "quit"}).to_string(),
                );
            }
        }
    }

    /// Sends a request and waits for its reply.
    pub async fn ask(&self, mut request: Value) -> Result<Value, String> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        request["id"] = json!(id);
        let reply = self.send(id, &request)?;
        let reply = match tokio::time::timeout(Duration::from_secs(120), reply).await {
            Ok(reply) => reply.map_err(|_| {
                "DigUp's helper stopped. A runtime DLL may be missing; check the installation."
                    .to_string()
            })?,
            Err(_) => {
                if let Some(searching) = self.running.lock().unwrap().as_mut() {
                    searching.pending.lock().unwrap().remove(&id);
                }
                return Err("The search helper took too long. Try again, or restart DigUp.".into());
            }
        };
        match reply.get("ok") {
            Some(Value::Bool(false)) => Err(reply["error"]
                .as_str()
                .unwrap_or("the helper failed")
                .to_string()),
            _ => Ok(reply),
        }
    }

    fn send(&self, id: u64, request: &Value) -> Result<oneshot::Receiver<Value>, String> {
        let mut running = self.running.lock().unwrap();
        if self.closed.load(Ordering::SeqCst) {
            return Err("DigUp is shutting down".into());
        }
        if let Some(searching) = running.as_mut() {
            if !matches!(searching.child.try_wait(), Ok(None)) {
                *running = None;
            }
        }
        if running.is_none() {
            *running = Some(self.start()?);
        }
        let searching = running.as_mut().unwrap();
        let (sender, receiver) = oneshot::channel();
        searching.pending.lock().unwrap().insert(id, sender);
        if let Err(error) =
            writeln!(searching.stdin, "{request}").and_then(|_| searching.stdin.flush())
        {
            searching.pending.lock().unwrap().remove(&id);
            let _ = searching.child.kill();
            let _ = searching.child.wait();
            searching.pending.lock().unwrap().clear();
            *running = None;
            return Err(format!("DigUp's helper isn't answering: {error}"));
        }
        Ok(receiver)
    }

    fn start(&self) -> Result<Searching, String> {
        let (child, stdin, stdout) = self.launch.lock().unwrap().spawn()?;
        let pending: Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>> = Arc::default();
        let (replies, on_event) = (pending.clone(), self.on_event.clone());
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                let Ok(message) = serde_json::from_str::<Value>(&line) else {
                    continue;
                };
                match message.get("id").and_then(Value::as_u64) {
                    Some(id) => {
                        if let Some(sender) = replies.lock().unwrap().remove(&id) {
                            let _ = sender.send(message);
                        }
                    }
                    None => on_event(message),
                }
            }
            // Gone: its waiting requests fail (their senders drop here), and the next request starts another.
            replies.lock().unwrap().clear();
            on_event(json!({"event": "exit"}));
        });
        Ok(Searching {
            child,
            stdin,
            pending,
        })
    }

    pub fn stop(&self) {
        self.closed.store(true, Ordering::SeqCst);
        if let Some(searching) = self.running.lock().unwrap().take() {
            searching.pending.lock().unwrap().clear();
            stop(
                searching.child,
                searching.stdin,
                &json!({"op": "quit"}).to_string(),
            );
        }
    }
}

impl Drop for SearchService {
    fn drop(&mut self) {
        self.stop();
    }
}

/// `digup index-service`: syncs the index with the folders, indexes what's new, and exits once it's done. `run` starts
/// it, asks the running one to sync again, or, when the folders changed (another launch), starts it over with them.
pub struct IndexService {
    running: Mutex<Option<Indexing>>,
    closed: AtomicBool,
    /// Events from a helper being stopped must not overwrite its replacement's progress.
    generation: Arc<AtomicU64>,
    on_event: EventSink,
}

struct Indexing {
    child: HelperProcess,
    stdin: ChildStdin,
    launch: Launch,
}

impl Drop for IndexService {
    fn drop(&mut self) {
        self.stop();
    }
}

impl IndexService {
    pub fn new(on_event: impl Fn(Value) + Send + Sync + 'static) -> IndexService {
        IndexService {
            running: Mutex::new(None),
            closed: AtomicBool::new(false),
            generation: Arc::new(AtomicU64::new(0)),
            on_event: Arc::new(on_event),
        }
    }

    pub fn run(&self, launch: &Launch) -> Result<(), String> {
        let mut running = self.running.lock().unwrap();
        if self.closed.load(Ordering::SeqCst) {
            return Err("DigUp is shutting down".into());
        }
        if let Some(indexing) = running.as_mut() {
            if matches!(indexing.child.try_wait(), Ok(None)) {
                if indexing.launch.args == launch.args && indexing.launch.env == launch.env {
                    return writeln!(indexing.stdin, "sync")
                        .and_then(|_| indexing.stdin.flush())
                        .map_err(|error| error.to_string());
                }
                self.generation.fetch_add(1, Ordering::SeqCst);
                let indexing = running.take().unwrap();
                stop(indexing.child, indexing.stdin, "stop");
            }
        }
        let current = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let (child, stdin, stdout) = launch.spawn()?;
        let on_event = self.on_event.clone();
        let generation = self.generation.clone();
        std::thread::spawn(move || {
            let mut settled = false;
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if generation.load(Ordering::SeqCst) != current {
                    return;
                }
                if let Ok(event) = serde_json::from_str::<Value>(&line) {
                    match event["event"].as_str().unwrap_or_default() {
                        "idle" | "error" | "exit" => settled = true,
                        "scanning" | "sync" | "indexing" | "file" | "reading-rest" | "rest" => {
                            settled = false;
                        }
                        _ => {}
                    }
                    on_event(event);
                }
            }
            if generation.load(Ordering::SeqCst) != current {
                return;
            }
            if !settled {
                on_event(json!({
                    "event": "error", "fatal": true, "unexpectedExit": true,
                    "message": "The index helper stopped unexpectedly. Check the index log, folder access and runtime installation, then try indexing again."
                }));
            }
            on_event(json!({"event": "exit"}));
        });
        *running = Some(Indexing {
            child,
            stdin,
            launch: launch.clone(),
        });
        Ok(())
    }

    pub fn stop(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
        if let Some(indexing) = self.running.lock().unwrap().take() {
            stop(indexing.child, indexing.stdin, "stop");
        }
    }

    pub fn close(&self) {
        self.closed.store(true, Ordering::SeqCst);
        self.stop();
    }
}

impl Drop for ModelDownload {
    fn drop(&mut self) {
        self.stop();
    }
}

/// `digup download-model`: the model files, from the Hugging Face cache or downloaded with resume, each checked. One at
/// a time; `run` again while it runs does nothing. Its events ("progress", "done", "error"…) go to `on_event`.
pub struct ModelDownload {
    running: Mutex<Option<HelperProcess>>,
    closed: AtomicBool,
    on_event: EventSink,
}

impl ModelDownload {
    pub fn new(on_event: impl Fn(Value) + Send + Sync + 'static) -> ModelDownload {
        ModelDownload {
            running: Mutex::new(None),
            closed: AtomicBool::new(false),
            on_event: Arc::new(on_event),
        }
    }

    pub fn run(&self, launch: &Launch) -> Result<(), String> {
        let mut running = self.running.lock().unwrap();
        if self.closed.load(Ordering::SeqCst) {
            return Err("DigUp is shutting down".into());
        }
        if let Some(child) = running.as_mut() {
            if matches!(child.try_wait(), Ok(None)) {
                return Ok(());
            }
        }
        let (child, stdin, stdout) = launch.spawn()?;
        drop(stdin);
        let on_event = self.on_event.clone();
        std::thread::spawn(move || {
            let mut ended = false;
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if let Ok(event) = serde_json::from_str::<Value>(&line) {
                    ended |= event["event"] == "done" || event["event"] == "error";
                    on_event(event);
                }
            }
            if !ended {
                on_event(
                    json!({"event": "error", "message": "The model helper stopped unexpectedly. Check the model log, retry the download, or reinstall DigUp if a runtime DLL is missing."}),
                );
            }
        });
        *running = Some(child);
        Ok(())
    }

    pub fn stop(&self) {
        self.closed.store(true, Ordering::SeqCst);
        if let Some(mut child) = self.running.lock().unwrap().take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn launch(program: PathBuf) -> Launch {
        Launch {
            program,
            args: Vec::new(),
            env: Vec::new(),
            log: None,
            background: false,
        }
    }

    #[test]
    fn helper_never_falls_back_to_path() {
        assert!(launch("digup".into())
            .command()
            .unwrap_err()
            .contains("missing"));
    }

    #[test]
    fn helper_rejects_the_running_gui() {
        assert!(launch(std::env::current_exe().unwrap())
            .command()
            .unwrap_err()
            .contains("GUI"));
    }

    #[test]
    fn helper_device_environment_never_loads_an_injected_backend() {
        let directory =
            std::env::temp_dir().join(format!("digup-device-env-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let program = directory.join("test-helper.exe");
        std::fs::write(&program, []).unwrap();
        let mut configured = launch(program);
        configured.env = vec![
            ("DIGUP_DEVICE".into(), "gpu".into()),
            ("GGML_BACKEND_PATH".into(), "unexpected-backend.dll".into()),
        ];
        let command = configured.command().unwrap();
        let env: HashMap<_, _> = command.get_envs().collect();
        assert_eq!(
            env.get(std::ffi::OsStr::new("DIGUP_DEVICE")),
            Some(&Some(std::ffi::OsStr::new("gpu")))
        );
        assert_eq!(
            env.get(std::ffi::OsStr::new("GGML_BACKEND_PATH")),
            Some(&None)
        );
        // No assignment/removal: the parent's CPU-only override remains inherited.
        assert!(!env.contains_key(std::ffi::OsStr::new("DIGUP_CPU_ONLY")));
        std::fs::remove_dir_all(directory).unwrap();
    }

    // A real child process speaking the helper protocol, for lifecycle tests only.
    #[test]
    fn device_test_process() {
        if std::env::var("DIGUP_TEST_DEVICE_PROCESS").as_deref() != Ok("1") {
            return;
        }
        let device = std::env::var("DIGUP_DEVICE").unwrap();
        let pid = std::process::id();
        println!(
            "{}",
            json!({"event": "device", "device": device, "pid": pid})
        );
        if let Ok(action) = std::env::var("DIGUP_TEST_INDEX_EXIT") {
            if action != "before-idle" {
                println!("{}", json!({"event": "idle", "searchable": 3}));
            }
            if action != "after-idle" {
                println!("{}", json!({"event": "scanning"}));
                std::process::exit(23);
            }
            return;
        }
        for line in std::io::stdin().lock().lines() {
            let line = line.unwrap();
            if line == "stop" {
                // An old helper may have already queued its terminal event when replacement starts.
                println!("{}", json!({"event": "idle", "staleStop": true}));
                break;
            }
            if line == "sync" {
                println!(
                    "{}",
                    json!({"event": "device", "device": device, "pid": pid})
                );
                continue;
            }
            let request: Value = serde_json::from_str(&line).unwrap();
            if request["op"] == "quit" {
                break;
            }
            println!(
                "{}",
                json!({"id": request["id"], "device": device, "pid": pid})
            );
        }
    }

    fn device_process(test: &str) -> (PathBuf, Launch) {
        let directory =
            std::env::temp_dir().join(format!("digup-device-{test}-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let program = directory.join(if cfg!(windows) { "child.exe" } else { "child" });
        std::fs::copy(std::env::current_exe().unwrap(), &program).unwrap();
        let mut configured = launch(program);
        configured.args = [
            "--exact",
            "helper::tests::device_test_process",
            "--nocapture",
        ]
        .map(str::to_string)
        .into();
        configured.env = vec![
            ("DIGUP_TEST_DEVICE_PROCESS".into(), "1".into()),
            ("DIGUP_DEVICE".into(), "cpu".into()),
        ];
        (directory, configured)
    }

    #[test]
    fn changing_device_restarts_search_without_closing_the_service() {
        let (directory, mut launch) = device_process("search");
        let service = SearchService::new(launch.clone(), |_| {});
        let cpu = tauri::async_runtime::block_on(service.ask(json!({"op": "status"}))).unwrap();
        assert_eq!(cpu["device"], "cpu");
        service.configure(launch.args.clone(), launch.env.clone());
        let same = tauri::async_runtime::block_on(service.ask(json!({"op": "status"}))).unwrap();
        assert_eq!(cpu["pid"], same["pid"]);
        launch.env[1].1 = "gpu".into();
        service.configure(launch.args.clone(), launch.env);
        let gpu = tauri::async_runtime::block_on(service.ask(json!({"op": "status"}))).unwrap();
        assert_eq!(gpu["device"], "gpu");
        assert_ne!(cpu["pid"], gpu["pid"]);
        service.stop();
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn changing_device_restarts_indexer_even_when_folders_are_unchanged() {
        let (directory, mut launch) = device_process("index");
        let (events, received) = std::sync::mpsc::channel();
        let service = IndexService::new(move |event| {
            if event["event"] == "device" {
                let _ = events.send(event);
            }
        });
        service.run(&launch).unwrap();
        let cpu = received.recv_timeout(Duration::from_secs(10)).unwrap();
        assert_eq!(cpu["device"], "cpu");
        service.run(&launch).unwrap();
        let same = received.recv_timeout(Duration::from_secs(10)).unwrap();
        assert_eq!(cpu["pid"], same["pid"]);
        launch.env[1].1 = "gpu".into();
        service.run(&launch).unwrap();
        let gpu = received.recv_timeout(Duration::from_secs(10)).unwrap();
        assert_eq!(gpu["device"], "gpu");
        assert_ne!(cpu["pid"], gpu["pid"]);
        service.stop();
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn shutdown_prevents_restarting_indexer() {
        let service = IndexService::new(|_| {});
        service.close();
        assert_eq!(
            service.run(&launch("missing".into())).unwrap_err(),
            "DigUp is shutting down"
        );
    }

    #[test]
    fn indexer_reports_unexpected_eof_and_preserves_normal_idle_exit() {
        for action in ["before-idle", "after-idle", "idle-then-work"] {
            let (directory, mut launch) = device_process(&format!("eof-{action}"));
            launch
                .env
                .push(("DIGUP_TEST_INDEX_EXIT".into(), action.into()));
            let (events, received) = std::sync::mpsc::channel();
            let service = IndexService::new(move |event| {
                let _ = events.send(event);
            });
            service.run(&launch).unwrap();
            let mut errors = Vec::new();
            loop {
                let event = received.recv_timeout(Duration::from_secs(10)).unwrap();
                if event["event"] == "error" {
                    errors.push(event.clone());
                }
                if event["event"] == "exit" {
                    break;
                }
            }
            if action == "after-idle" {
                assert!(
                    errors.is_empty(),
                    "normal idle must not be reported as a crash"
                );
            } else {
                assert_eq!(errors.len(), 1);
                assert_eq!(errors[0]["unexpectedExit"], true);
                assert_eq!(errors[0]["fatal"], true);
            }
            service.stop();
            std::fs::remove_dir_all(directory).unwrap();
        }
    }

    #[test]
    fn stopped_indexer_does_not_publish_stale_terminal_events() {
        let (directory, launch) = device_process("stale-stop");
        let (events, received) = std::sync::mpsc::channel();
        let service = IndexService::new(move |event| {
            let _ = events.send(event);
        });
        service.run(&launch).unwrap();
        assert_eq!(
            received.recv_timeout(Duration::from_secs(10)).unwrap()["event"],
            "device"
        );
        service.stop();
        drop(service);
        assert_eq!(
            received.recv_timeout(Duration::from_secs(10)),
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected)
        );
        std::fs::remove_dir_all(directory).unwrap();
    }
}
