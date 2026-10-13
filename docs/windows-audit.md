# Windows audit baseline

Inspected on 2026-10-13 against upstream `main` at
`f9b8106ffb8308b4f48b76149d270f7c2e6b4918` (also verified with `git ls-remote`).
Read README, CONTRIBUTING, MIT LICENSE, Package.swift, shell Cargo.lock/Tauri configuration,
portable adapters, tests, all current workflows, open issues, and open pull requests.

## Existing implementation retained

- The shared indexing/search engine and `digup` CLI are Swift. `Package.swift` already selects portable Windows/Linux
  SQLite/FTS5, stb, miniz, PDFium, and shared llama.cpp targets with platform guards.
- Rust/Tauri `shell/` already provides the panel, tray, global shortcut, folder setup, helper protocol, previews,
  and a filesystem watcher. Its frontend is plain bundled HTML/CSS/JavaScript.
- Model revision, sizes, SHA-256 values, range downloads and retry logic already exist. The model is not an installer asset.
- EmbeddingGemma 2, document/image/PDF/media/code extractors, SQLite migrations, vectors, and keyword search already exist.
- The macOS UI and Sparkle updater remain platform-specific. The Tauri shell has no updater.
- The only workflow on this `main` is Homebrew publication. Recent CI runs belong to unmerged contributions.

## Confirmed blockers and fixes in this branch

| Baseline evidence | Consequence | Change |
|---|---|---|
| No Windows build/installer workflow | No reproducible deployed-runtime validation | Pinned native dependency manifest, PowerShell build, per-user NSIS, portable archive, checksum and real-model smoke workflow |
| Helper lookup falls back beside GUI | Windows case-insensitive `DigUp.exe`/`digup.exe` collision | Separate `helper/` resource directory; validate helper identity; never use user PATH |
| Portable FFmpeg lookup can fall back to PATH | Works only on developer machines, uncertain executable selected | Absolute bundled runtime lookup; clear missing-runtime diagnostics |
| Watcher errors are discarded | Network/removable directories can stop updating | Visible warning and periodic reconciliation with cancellable watcher |
| Failed recursive traversal is indistinguishable from missing files | Temporary loss of access can delete index rows | Preserve records under unavailable paths; retain actual delete reconciliation |
| File IDs may be zero on network storage | Unrelated files may be misidentified as renames | Do not match unknown file IDs |
| Model completeness checks only existence | A truncated final file appears ready | Validate size/type; explicit download/repair verifies full SHA-256 |
| Helper lifetime is independent of GUI | Indexer/decoder can survive exit | Windows Job Object process-tree ownership and bounded graceful shutdown |
| Git repository configuration may enable fsmonitor commands | Indexing can execute a repository-controlled hook | Disable Git fsmonitor for read-only file enumeration |
| Unbounded archive document text | Corrupt ZIP member can exhaust memory | Bound decompressed DOCX/ODT XML size |

## Related upstream work

- [Issue #1: Windows](https://github.com/ARahim3/DigUp/issues/1): maintainer plans Windows support.
- [PR #18: Windows port](https://github.com/ARahim3/DigUp/pull/18) at `5c5c1f3ae2b4346353e34704b4783956d1ae8c4f`:
  a separate C#/WPF engine/UI. It is not the Tauri shell already present in main and is not copied into this branch.
- [#11 dependency pins](https://github.com/ARahim3/DigUp/issues/11),
  [#14 Unicode folder identity](https://github.com/ARahim3/DigUp/issues/14),
  [#22 helper lifetime](https://github.com/ARahim3/DigUp/issues/22),
  [#23 repeated rescans](https://github.com/ARahim3/DigUp/issues/23),
  [#25 model download](https://github.com/ARahim3/DigUp/issues/25),
  [#44 CI](https://github.com/ARahim3/DigUp/issues/44) inform validation. This branch does not claim to close these
  issues across all platforms or incorporate their separate PRs.

CONTRIBUTING asks for an issue and maintainer agreement before an upstream PR. Local work was explicitly requested
by the user; no upstream issue, comment or PR has been posted. The existing Windows discussion should be referenced
when the owner reviews the prepared PR text. MIT notices remain intact.
