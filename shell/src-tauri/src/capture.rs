//! Captures only the app's own WebView for an explicitly isolated release smoke.
//! Never captures desktop pixels or writes to a caller-provided arbitrary file.
use std::path::PathBuf;

#[cfg(not(windows))]
pub async fn webview_png(_window: tauri::WebviewWindow, _path: PathBuf) -> Result<(), String> {
    Err("Native WebView capture is available on Windows only".into())
}

#[cfg(windows)]
pub async fn webview_png(window: tauri::WebviewWindow, path: PathBuf) -> Result<(), String> {
    use std::os::windows::ffi::OsStrExt;
    use std::sync::{Arc, Mutex};
    use webview2_com::{
        CapturePreviewCompletedHandler,
        Microsoft::Web::WebView2::Win32::COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG,
    };
    use windows::{
        core::PCWSTR,
        Win32::{
            System::Com::{STGC_DEFAULT, STGM_CREATE, STGM_SHARE_EXCLUSIVE, STGM_WRITE},
            UI::Shell::SHCreateStreamOnFileEx,
        },
    };
    let (sender, receiver) = tokio::sync::oneshot::channel();
    let sender = Arc::new(Mutex::new(Some(sender)));
    let dispatch = sender.clone();
    window
        .with_webview(move |view| {
            let start = || -> windows::core::Result<()> {
                let wide: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
                // SAFETY: an owned NUL-terminated path, fixed flags; stream and WebView COM objects stay on their UI thread.
                unsafe {
                    let stream = SHCreateStreamOnFileEx(
                        PCWSTR(wide.as_ptr()),
                        (STGM_CREATE | STGM_WRITE | STGM_SHARE_EXCLUSIVE).0,
                        0x80,
                        true,
                        None,
                    )?;
                    let keep_alive = stream.clone();
                    let completed = sender.clone();
                    let handler = CapturePreviewCompletedHandler::create(Box::new(move |result| {
                        let result = result
                            .and_then(|()| keep_alive.Commit(STGC_DEFAULT))
                            .map_err(|error| error.to_string());
                        drop(keep_alive);
                        if let Some(sender) = completed.lock().unwrap().take() {
                            let _ = sender.send(result);
                        }
                        Ok(())
                    }));
                    view.controller().CoreWebView2()?.CapturePreview(
                        COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG,
                        &stream,
                        &handler,
                    )?;
                }
                Ok(())
            };
            if let Err(error) = start() {
                if let Some(sender) = dispatch.lock().unwrap().take() {
                    let _ = sender.send(Err(error.to_string()));
                }
            }
        })
        .map_err(|error| error.to_string())?;
    tokio::time::timeout(std::time::Duration::from_secs(15), receiver)
        .await
        .map_err(|_| "Native WebView capture timed out")?
        .map_err(|_| "Native WebView capture was cancelled")?
}
