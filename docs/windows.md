# Windows x64 build and release verification

The Windows app uses the existing Swift engine and `digup` CLI behind the existing
Rust/Tauri shell. These instructions do not replace the macOS app or Linux build.
The initial Windows target is Windows 10 **22H2** and Windows 11, x64, CPU-only.
GPU backends and the Windows updater are separate work; neither is advertised as
working by this build. ARM64 Windows is not a supported release target here.

## Status and evidence

`scripts/windows/Build.ps1` is the build entry point. `.github/workflows/windows.yml`
builds, tests, installs, exercises real inference and the installed WebView, then
uninstalls. A workflow definition is not evidence that GitHub Actions has passed:
attach its successful run URL and the clean-machine checklist below to a release.
The PATH-isolated smoke on a developer/CI host is **not** a clean-VM test.

## Build from a clean checkout

Install Git, PowerShell 7.2 or newer, Visual Studio **2022** Build Tools with the
Desktop development with C++ workload and Windows SDK, Swift **6.3.3**, and rustup.
The Swift installer URL and its SHA-256 are pinned in
`scripts/windows/dependencies.json`. The workflow downloads/verifies that installer.
VS and Windows SDK are controlled by the `windows-2022` runner image; record the
runner image, compiler and SDK versions with any public release. Builds are
repeatable from pinned source inputs; they are not claimed to be byte-identical
across changing Microsoft runner images or Authenticode timestamps.

No Node, npm, pnpm, or frontend package installation is needed: the existing shell
serves checked-in HTML/CSS/JavaScript. Do not introduce a second frontend toolchain.

In PowerShell, from the checkout:

```powershell
rustup toolchain install 1.95.0 --profile minimal --component rustfmt --component clippy
rustup default 1.95.0
cargo install tauri-cli --version 2.12.2 --locked
. ./scripts/windows/Enter-Environment.ps1
./scripts/windows/Build.ps1 -Jobs 4
```

The environment script only changes the current PowerShell process. It locates
VS 2022 and the pinned Swift installation. An explicit alternative runtime location
can be passed with `-SwiftRuntimeDirectory C:/path/to/runtime/usr/bin`.

The build downloads checksum-pinned SQLite, stb, miniz, PDFium and CMake into
`Vendor/`, verifies the existing pinned llama.cpp commit and patch, builds all CPU
variants with GPU/OpenMP/network components disabled, builds FFmpeg 8.1.3 from its
official source using pinned Make/NASM/Swift LLVM tools, and runs Swift tests, Rust
format checking, Clippy and Rust tests. It builds the release CLI and Tauri GUI,
embeds the CLI's `asInvoker`/long-path manifest, and stages runtime DLLs beside the
helper. Use `-SkipVendor` only when the pinned vendor build is already available;
`-SkipTests` is a local diagnostic option, never a release sign-off.

Outputs:

- `build.noindex/windows/artifacts/*-setup.exe`: per-user NSIS installer.
- `build.noindex/windows/artifacts/DigUp-windows-x64-portable.zip`: unpacked app,
  CLI in `helper/`, and the same runtime dependencies and notices.
- `build.noindex/windows/artifacts/DigUp-FFmpeg-8.1.3-source.zip`: corresponding
  FFmpeg source, license, pinned build recipes and compiler version record; preserve
  this artifact alongside the binaries when redistributing.
- `build.noindex/windows/artifacts/SHA256SUMS.txt`: SHA-256 of every release artifact.

NSIS is chosen because Tauri supports a current-user installation without an
administrator prompt. MSI is not produced by this first implementation. Application
binaries and DLLs are installed together; no manual DLL copying or user PATH entry
is required. WebView2 Evergreen is required by Tauri. If absent, the installer uses
an embedded, checksum-pinned and signature-verified Microsoft bootstrapper; that
first installation needs a network connection to Microsoft's runtime service.

Downloads use `.partial` files, HTTP Range, retry, and an expected SHA-256 before
publication. A checksum mismatch is never ignored or replaced with `latest`.

## Use, model, and offline operation

Install without elevation. Launch DigUp, choose folders in setup and let its model
download finish. The model is deliberately excluded from the installer. Existing
model download code pins the GGUF revision, sizes and SHA-256, supports resume and
retry, and can reuse verified cached files. No Hugging Face token, registration,
subscription, or cloud inference service is required for this model.

The model and index live under `%LOCALAPPDATA%/DigUp` (models in `Models`, index in
`index`); shell settings live under `%APPDATA%/com.abdurrahim.DigUp`. With WebView2 and
models in place, the baseline search/index path works offline. The Windows build
does not install an updater or make macOS Sparkle requests.

Open the search panel with **Ctrl+Shift+Space**, or from the tray. The tray offers
settings and quit. Starting at login is opt-in, stored in the current user's Run
key, and removed on uninstall. Results open through the Windows default handler;
opening a PDF at a page or media at a timestamp depends on the receiving application.
Preview inside DigUp is the portable place to inspect the matching passage/page/time.

CLI examples from an unpacked portable build:

```powershell
./helper/digup.exe download-model
./helper/digup.exe index 'D:/Документы с пробелами'
./helper/digup.exe search 'greenhouse aboard a space station' --json
./helper/digup.exe status
```

The `DIGUP_MODELS` environment variable overrides the model directory;
`DIGUP_CPU_ONLY=1` explicitly requests CPU inference. `--index` selects a separate
index directory for tests. Keep personal document paths out of bug reports: inspect
logs before sharing, as existing extraction errors and query logs can contain names
or queries. Do not share the index database itself.

## Automated verification

```powershell
. ./scripts/windows/Enter-Environment.ps1
swift test
cargo fmt --manifest-path shell/src-tauri/Cargo.toml --all -- --check
cargo clippy --manifest-path shell/src-tauri/Cargo.toml --locked --all-targets -- -D warnings
cargo test --manifest-path shell/src-tauri/Cargo.toml --locked
$installer = Get-ChildItem build.noindex/windows/artifacts/*-setup.exe | Select-Object -First 1
./scripts/windows/Smoke.ps1 -Installer $installer.FullName -Models "$PWD/build.noindex/windows/models"
./scripts/windows/Media-Smoke.ps1 -PackageDirectory "$PWD/build.noindex/windows/package" -Models "$PWD/build.noindex/windows/models"
./scripts/windows/Test-ModelDownload.ps1 -Cli "$PWD/build.noindex/windows/package/helper/digup.exe" -OutputDirectory "$PWD/build.noindex/windows/download-resume-check"
```

For direct `swift test`, DLLs must be available beside the test executable or in the
**process-local** PATH just as `Build.ps1` arranges (`Vendor/llama/lib`,
`Vendor/pdfium/bin`, `Vendor/ffmpeg/bin`, Swift runtime). End-user binaries do not
depend on that developer setup.

The smoke script uses synthetic documents only, clears child PATH to Windows system
directories, removes any reference worker override, forces CPU inference and uses
the actual installed CLI, actual model, SQLite/FTS and WebView. It checks:

- CLI launch; real semantic top ranking against three unrelated documents; an
  independent FTS-only request; unchanged input leaves vector/segment counts stable.
- Cyrillic, spaces, accented characters and emoji in folders/filenames.
- Setup through the real WebView, search results reported by frontend code, saved
  settings and index reuse after restarting the actual GUI.
- Add, change, rename and delete while the GUI's real filesystem watcher runs;
  removal from storage as well as from the displayed results.
- Uninstall and absence of installed app/helper binaries.

JSON reports and captured stdout/stderr are stored in
`build.noindex/windows/smoke-<id>` (or the explicit `-OutputDirectory`). A report with
`result: passed` is only written after functional checks. An uninstall failure
still makes the command fail. No test substitutes fake vectors for release smoke.
`Test-ModelDownload.ps1` interrupts an actual transfer in a fresh download directory,
resumes it, then verifies both full model hashes. It needs network access and about
865 MB of downloads, so it is an explicit release check rather than a repeated
download on every CI run.
`Media-Smoke.ps1` creates synthetic PDF, DOCX, ODT, source, image, audio and video
fixtures, exercises actual local extractors and model inference, checks a page-2
PDF hit and rejects deliberately damaged files. It also checks that a source file
containing a side effect is indexed without ever being executed.

## Diagnostics and removal

The portable engine has no OCR backend yet. Screenshots and scanned PDF pages can
have visual embeddings, but text that exists only in pixels is not added to FTS.
Text-bearing PDFs preserve their page numbers; audio/video search preserves the
matching time. The app does not supply a speech transcript. RAW camera formats,
SVG rendering and tiled TIFF images are not supported on this path. JPEG/PNG,
PDF text, DOCX, ODT, WAV and MP4 have real fixtures in `Media-Smoke.ps1`; other
containers/codecs depend on the bundled FFmpeg build and are not all individually
certified by that smoke. Damaged or unsupported files are reported as failed,
without stopping indexing of the remaining files.

If setup reports a missing model, use Retry or run `helper/digup.exe download-model`.
Check available disk space and the selected model directory. If a DLL or FFmpeg
cannot be loaded, reinstall the complete bundle; do not download an arbitrary DLL
from a search result. `helper/digup.exe --help` with a clean PATH is the first
diagnostic for app-local runtime completeness. Missing access to a folder should
be resolved by choosing an accessible folder, without elevating DigUp.

Use Windows Settings → Apps → DigUp → Uninstall. Models, settings and indexes are
retained to allow reinstalling; after quitting DigUp, remove the two user-data
directories above if complete removal is desired. A portable build is removed by
deleting its unpacked folder and, optionally, those user-data directories.

## Signing and updates

Unsigned pull requests and test branches build normally. For a signed build, supply
GitHub Secrets `WINDOWS_CERTIFICATE_PFX` (base64 PFX) and
`WINDOWS_CERTIFICATE_PASSWORD`. The workflow imports it into the ephemeral runner's
current-user certificate store, passes only its thumbprint to `Sign.ps1`, signs
the CLI, Tauri executable and installer with SHA-256/timestamping, verifies those
signatures, then removes the certificate and temporary PFX. No key is checked in.
Hardware/cloud signing services can replace `Sign.ps1` without changing the app.

Windows automatic updates are **not implemented**. The macOS Sparkle appcast cannot
serve as a Windows updater. A later change needs Tauri updater keys, endpoints,
signed update artifacts, rollback/version checks and an update smoke test.

## Clean-machine release checklist

Run the following on both a clean Windows 10 22H2 x64 VM and a clean Windows 11 x64
VM. Record OS build, user privilege level, artifact SHA-256 and result. Hosted
`windows-2022` is Windows Server and does not replace these two desktop checks.

- [ ] Standard (non-administrator) user; no Swift/Rust/Node, FFmpeg, llama.cpp, or
  added build-tool directories in PATH. Test with WebView2 absent and present.
- [ ] Installer installs/launches/uninstalls with no manual dependency copying.
- [ ] First-run model download completes; interrupt it, retry, and verify checksum
  enforcement using a damaged partial file in a disposable profile.
- [ ] Choose a folder with TXT/Markdown, source code (enabled), DOCX, ODT, PDF,
  images, audio and video; meaning and exact-word queries return expected files.
- [ ] Damaged files are skipped/reported without a crash; document files are never
  executed; there is no document-upload traffic.
- [ ] Tray, hotkey, pause/resume/cancel, quit during indexing and optional login
  startup work; quit leaves no indexing/FFmpeg/worker processes behind.
- [ ] Restart and app upgrade retain folders/settings/index; use a copy of an
  earlier database to confirm migration and record its before/after counts.
- [ ] Add/change/rename/delete converge; folders with Cyrillic, spaces, emoji,
  combining Unicode and paths beyond 260 characters work with default OS policy.
- [ ] Disconnect/reconnect a chosen removable drive and an SMB share; unavailable
  roots do not cause the existing index to be pruned as if files were deleted.
- [ ] Open files in default applications; document exactly which viewers support
  page/time seeking. An unsupported viewer still opens the original file.
- [ ] Disable networking after installing WebView2 and obtaining the model. Launch,
  index, search and restart remain usable in CPU-only mode.
- [ ] Verify Authenticode with the release certificate, and inspect SmartScreen
  behavior; absence of a warning is not guaranteed by a fresh certificate alone.
- [ ] Complete the corresponding-source and runtime license inventory review in
  `THIRD_PARTY_NOTICES.md`, publish required source artifacts alongside binaries.

Do not mark release readiness until this checklist and the workflow have evidence.
