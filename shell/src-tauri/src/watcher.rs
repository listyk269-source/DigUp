//! Native notifications plus a periodic reconciliation for network/removable folders and lost events.

use notify::{RecursiveMode, Watcher};
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

enum Signal {
    Changed,
    Stop,
}

pub struct FolderWatcher {
    watcher: Option<notify::RecommendedWatcher>,
    sender: Sender<Signal>,
    worker: Option<JoinHandle<()>>,
}

fn reconcile(
    receiver: Receiver<Signal>,
    debounce: Duration,
    interval: Duration,
    changed: impl Fn(),
) {
    let mut deadline = Instant::now() + interval;
    loop {
        match receiver.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(Signal::Stop) | Err(RecvTimeoutError::Disconnected) => return,
            Ok(Signal::Changed) => {
                // Bound a continuous stream too: an import must not defer indexing forever.
                deadline = deadline.min(Instant::now() + debounce);
            }
            Err(RecvTimeoutError::Timeout) => {
                changed();
                deadline = Instant::now() + interval;
            }
        }
    }
}

impl FolderWatcher {
    /// Errors are surfaced once and reconciled by a periodic scan. Dropping the watcher cancels a queued rescan.
    pub fn start(
        folders: &[PathBuf],
        ignore: Option<PathBuf>,
        changed: impl Fn() + Send + 'static,
        warning: impl Fn(&str),
    ) -> FolderWatcher {
        let (sender, receiver) = mpsc::channel();
        let events = sender.clone();
        let watcher = notify::recommended_watcher(move |result: notify::Result<notify::Event>| {
            if let Ok(event) = result {
                if event.kind.is_access() {
                    return;
                }
                let ours = |path: &PathBuf| {
                    ignore
                        .as_ref()
                        .is_some_and(|folder| path.starts_with(folder))
                };
                if !event.paths.is_empty() && event.paths.iter().all(ours) {
                    return;
                }
            }
            // An overflow/error also requires a full reconciliation; do not silently ignore it.
            let _ = events.send(Signal::Changed);
        });
        let mut watcher = watcher.ok();
        if let Some(watcher) = &mut watcher {
            for folder in folders {
                if watcher.watch(folder, RecursiveMode::Recursive).is_err() {
                    warning("A folder can't be watched. Check permissions or reconnect the drive; DigUp retries every minute.");
                }
            }
        } else {
            warning(
                "Live folder notifications are unavailable. DigUp checks for changes every minute.",
            );
        }
        let worker = std::thread::spawn(move || {
            reconcile(
                receiver,
                Duration::from_secs(2),
                Duration::from_secs(60),
                changed,
            )
        });
        FolderWatcher {
            watcher,
            sender,
            worker: Some(worker),
        }
    }
}

impl Drop for FolderWatcher {
    fn drop(&mut self) {
        let _ = self.sender.send(Signal::Stop);
        self.watcher.take();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dropping_cancels_pending_debounce() {
        let (sender, receiver) = mpsc::channel();
        sender.send(Signal::Changed).unwrap();
        sender.send(Signal::Stop).unwrap();
        reconcile(
            receiver,
            Duration::from_millis(10),
            Duration::from_secs(60),
            || panic!("cancelled callback ran"),
        );
    }

    #[test]
    fn periodic_reconciliation_does_not_need_a_native_event() {
        let (sender, receiver) = mpsc::channel();
        let (called, result) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            reconcile(
                receiver,
                Duration::from_millis(1),
                Duration::from_millis(5),
                || {
                    let _ = called.send(());
                },
            )
        });
        result.recv_timeout(Duration::from_secs(2)).unwrap();
        sender.send(Signal::Stop).unwrap();
        worker.join().unwrap();
    }
}
