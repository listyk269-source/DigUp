# Local graph investigation

This extends the existing Tauri graph, local Swift search service and model/index formats.
It introduces no cloud API, telemetry, new model weights or database migration. It is a content
exploration tool: a manual confirmation records the operator's decision, not forensic proof.

## State and components

- `graph-state.js` owns pure evidence normalization, review identity, annotation state,
  edge visibility, shortest-path traversal and timeline placement.
- `graph.js` owns the existing finite force layout, SVG geometry, camera, thumbnails and
  expansion. Cards expose real unexpanded counts and `fx`/`fy` pins. Layout work is cached;
  panning, zooming or changing the selection does not restart the layout.
- `graph-tools.js` joins the omnibar, filters, keyboard/context menus, review actions and
  node/edge inspector to those primitives. `graph-investigation.css` extends the incumbent
  graphite/amber/cyan style with a 360px blurred overlay and explicit verification states.
- Rust `investigation.rs` validates and atomically saves annotations beside settings.
  Swift `MatchEvidence.swift`, `Searcher.swift` and `SearchService.swift` supply real evidence.

An edge contains `similarityScore`, `matchTypes` (`visual`, `face`, `audio`, `ocr`, `metadata`),
`evidence` (the protocol's `match_evidence`) and `status` (`unverified`, `confirmed`, `rejected`). Its centered curve badge
shows only reported modality icons and its overall cosine. Dashed unverified and solid green
confirmed lines have text labels in the inspector; rejected lines can be shown explicitly.

## Evidence and capability boundaries

Visual evidence compares indexed image/frame vectors with image/frame vectors. Audio compares
audio vectors only. OCR compares indexed OCR segments only, not arbitrary text. Each channel
uses the seed's matched segment where applicable, otherwise its normalized mean for that channel.
Reported row IDs and locations identify the actual matched fragments. A seed mean has no invented
timestamp. Match views offer seek buttons only when the underlying location exists.

EXIF currently compares an exact nonempty indexed `taken` date. It has no fabricated cosine or
percentage; an equal timestamp alone does not establish common origin. Modality scores are separate
cosines, not calibrated confidence or shares that sum to 100%. The overall ranking retains the
existing stored-vector comparison and may differ from individual channel scores.

`face` is a reserved typed channel, with no analyzer in this build: the Faces chip/context option is
disabled. Objects/faces are marked unavailable. The Windows portable indexer still has no OCR
extraction backend; existing OCR data can be displayed/compared, but this UI does not create it.
No face recognition, object detector, speech transcript, complete EXIF extractor or global provenance
analysis is claimed. Adding these needs a separate local analyzer, license/model decision and fixtures.

The inspector distinguishes evidence loading, a successful response without indexed OCR, and an
error with Retry. SHA-256 is opt-in: the service reads the actual scoped regular file on a background
worker and verifies size/mtime before and after. A changed file requests reindexing. Hashing a large
file can take time; there is no individual hash-cancel button. The UI remains responsive and quitting
stops its helper. No user file is executed or uploaded.

## Read-only search protocol

New operations use the existing scoped local helper protocol and Rust allowlist:

| Operation | Purpose |
| --- | --- |
| `related_counts` | Batch up to 12 files; count real neighbors not in the loaded path set. |
| `file_evidence` | Read indexed metadata and up to ten OCR excerpts of at most 1,000 characters. |
| `media_details` | Compute an actual file hash off the request loop with existing worker slots. |
| `graph_search` | Run a real local text embedding against up to 120 loaded file paths. |

Folder exclusions and the code/non-code index boundary still apply. Path and realpath scope checks
precede file access. Related-count batches reload vectors once, and counts are refreshed after expansion.
They describe the current index; a deleted file may remain counted until normal index reconciliation.
Stale expansion/search responses cannot overwrite a newer view.

Filename search folds Unicode with NFKC/lowercase and dims nonmatches to opacity 0.25. Enter runs
semantic highlighting on the current canvas, independently of the main search cursor. Its raw cosine
cutoff is `max(0.2, 0.85 * bestCanvasCosine)`; the UI reports that cutoff. This heuristic avoids the
main search's statistical gate suppressing a homogeneous neighborhood. It is not an exhaustive global
search or a confidence estimate. Edge minimum similarity remains a separate control (default 0.75).

## Navigation and persistence

Expand-all/by-modality still respects the 120-file graph cap. The shortest path is breadth-first over
expanded visible nodes and the current modality filter, always excluding rejected links even when
they are displayed. It cannot discover a path through unopened parts of the index. Hidden nodes can
be restored. Force layout remains finite rather than a continuously running physics simulation.

Timeline x positions reflect modification dates proportionally; collision lanes separate cards.
Missing dates get a separate area. Explicit pins retain their coordinates in both layouts, so a pinned
card's x position does not imply a date. Switching back restores force positions. Large/dense graphs
require pan/zoom; cyclic edges can cross. Distances in force mode have no quantitative meaning.

`graph-investigation.json` schema version 1 contains typed node and edge annotations. It is separate
from SQLite and capped at 2 MiB, 4,000 node entries and 8,000 review entries. Coordinates must be finite
and bounded. Node keys bind path, code-index scope, indexed mtime and size. Edge reviews additionally
bind model/vector source, both file versions, score, anchors and evidence. Changed evidence becomes
unverified. These keys are not cryptographic content identity: same-size/same-mtime replacement cannot
be ruled out without computing/verifying a hash. Paths are local settings data, not telemetry.

Saves are serialized and atomic; errors remain visibly unsaved with retry. A corrupt or unsupported
annotation file is preserved and cannot be silently overwritten by a failed load. Settings/index data
are unaffected. Annotations persist across refresh/restart; deleting this optional file resets reviews,
pins and hidden-node choices. Back it up with settings if those decisions matter.

## Validation

```powershell
node --test Tests/GraphModelTests.cjs Tests/GraphInvestigationTests.cjs Tests/I18nTests.cjs
./scripts/windows/Build.ps1
./scripts/windows/Graph-Smoke.ps1 -Archive build.noindex/windows/artifacts/DigUp-windows-x64-portable.zip -Models C:/test-models -OutputDirectory C:/test-evidence/graph
./scripts/windows/UI-Features-Smoke.ps1 -Archive build.noindex/windows/artifacts/DigUp-windows-x64-portable.zip -Models C:/test-models -OutputDirectory C:/test-evidence/ui
```

The native UI smoke uses synthetic Unicode folders, actual local inference, valid JPEG EXIF and
real audio/video files. It verifies side-by-side previews, actual channel evidence/time buttons,
positive semantic results, stale-query handling, counts, expansion, hash, review visibility, timeline,
pins and a second process launch. WebView2 captures the isolated application's client area only.
Unit tests cover channel separation, metadata evidence, annotation validation/invalidation, Unicode,
hidden/rejected path traversal and timeline placement. Release smokes do not substitute fake vectors.

Retail Windows 10/11 clean installation, high-DPI/narrow-screen interactions, native outer corners,
driver/vendor coverage and signing still require the release checklist in [windows.md](windows.md).
