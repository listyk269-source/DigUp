# Local face search (YuNet + SFace)

Face search is an opt-in layer for indexed photographs/screenshots and video. Select a face in a
photograph or sampled frame to search for similar face observations in the selected folders.
It does not discover a person's name, connect to an online identity database, or infer attributes.
Manual link confirmation records the user's assessment; it is not proof of identity.

## Use

1. Finish normal indexing of the chosen folders. Open **Faces** in the search header, or the face
   action below an image/video preview. The graph's face action opens the same selector.
2. Choose **Auto**, **CPU**, or **GPU** for face inference. This preference is saved independently
   of the EmbeddingGemma device. Auto/GPU can fall back to CPU with a visible reason.
3. Start face indexing. First use downloads about 39 MB of pinned YuNet/SFace weights, verifies
   their SHA-256, and retains partial transfers for retry/resume. Weights are not in the installer.
   Once the models and application dependencies are present, inference and search work offline.
4. The progress panel reports files, failed files, extracted faces and video frames. Pause/cancel
   stops the owned inference/decoder processes. Resume skips completed, unchanged files; an
   interrupted file is processed again. Previous good file observations survive failed replacement.
5. Select one of the outlined faces or its thumbnail. **Show more** loads additional observations.
   Video matches include a sampled time and an internal player. **Show in graph** projects actual
   face comparisons into the existing graph, with a separate model source and face evidence.

New or changed media need another incremental face-index run after the normal index catches up.
Removing a file or excluding its folder prevents it from being returned. Unavailable/removable roots
do not cause their existing face data to be silently erased. There is no automatic name assignment.
The local [People section](people.md) adds user-assigned labels, bulk review, corrections, undo and
unconfirmed suggestions for new media using this existing face index.

## Models, runtime and CPU fallback

The exact OpenCV Zoo revision, filenames, sizes, SHA-256 and model licenses are recorded in
`scripts/windows/face-dependencies.json`. YuNet detects faces and five landmarks; SFace compares
aligned 112 x 112 face crops, producing normalized 128-dimensional vectors.

The standalone Rust `digup-face-worker` uses pinned ONNX Runtime 1.22.1. Windows GPU inference
uses DirectML 1.15.4; initialization or execution failure recreates both sessions on CPU and retries.
The interface reports the actual device and fallback reason. A selected GPU provider does not mean
every individual graph operator executed on the GPU. No speedup on every image/device is promised.
`DIGUP_CPU_ONLY=1` overrides every preference. `DIGUP_FACE_DISABLE_GPU=1` is a diagnostic CPU
fallback switch; `DIGUP_FACE_GPU_DEVICE` selects a DirectML adapter index from 0 to 31.

The Windows package includes the worker, ONNX Runtime, DirectML and VC runtime DLLs beside each
other under `helper/faces`. Runtime loading excludes the current directory and user PATH. The
worker has no Python dependency and disables ONNX Runtime telemetry before creating sessions.
The application sends no media/embeddings to a remote service. Downloading model/runtime files is
the only feature-specific network operation. Microsoft runtime/model notices are under `licenses/Faces`.

## Storage and consistency

`face-index.sqlite` sits beside the existing index. The semantic SQLite schema and its 768-dimensional
EmbeddingGemma vectors are unchanged. Face jobs and observations bind exact indexed file version,
model/preprocessing revision and sampling configuration. Each file is published atomically; video
observations stream through a job-private staging file rather than accumulating in RAM.

Search compares only compatible 128-dimensional vectors, checks current file versions and folder
scope, and pages actual face observations. Multiple observations of a video may appear at different
times. The graph deduplicates file cards and keeps the matched face/time as its evidence. Live index
changes invalidate page revisions; the UI restarts the ranking explicitly rather than mixing snapshots.

The sidecar contains face descriptors, locations and file paths. It stays local and uses the same
OS account permissions as the ordinary index; no additional database encryption is implemented.
After quitting DigUp, removing `face-index.sqlite` and its SQLite WAL/SHM companions resets this layer.
Temporary prepared frames/staging are removed on normal completion/cancellation; a forced process or
system crash may leave `face-scratch-*` folders in the index directory. Remove them only after quitting
all DigUp instances. Normal index/settings and original media need not be deleted.

## Accuracy and limits

- Cosine values and detector scores are not identity probabilities. The UI starts at 0.50; the lower
  0.363 option comes from the OpenCV example. Neither certifies accuracy for your archive.
  The semantic graph's 0.75 threshold is separate. Check difficult matches visually.
- Video uses uniform sampling (default every 2 seconds, configurable from 0.25 to 60 seconds),
  independently of semantic scene deduplication. A face appearing between sampled frames can be missed.
  Matches retain the decoder's actual frame timestamp, including variable frame rate video.
  Internal playback depends on Windows/WebView media codecs; unsupported originals retain their
  matching frame and an **Open** action for an external player.
- Prepared media have a maximum side of 1600 pixels. Small, blurred, occluded or profile faces may
  be missed or mismatched. At most 32 detections per sampled image/frame are retained. The native
  worker also bounds input bytes, pixels, request lines and NMS candidates.
- No automatic identity naming, unsupervised face clustering, liveness checks, face enhancement, internet search, or face-based
  OCR/object extraction is included. No accuracy claims beyond the recorded fixtures are made.
- Windows includes the packaged CPU/DirectML runtime. The optional face worker can be built on other
  platforms with an appropriate ONNX Runtime library; macOS/Linux execution is not certified by the
  Windows checks. Existing non-face features remain available without a face worker/model.

## Build and verify

Use pinned prerequisites from [windows.md](windows.md). The normal `Build.ps1` invokes
`Build-Faces.ps1`, which downloads hash-pinned runtime packages/notices, runs worker fmt/clippy/tests,
builds its release executable and bundles app-local dependencies. It never downloads face weights
into the installer.

```powershell
. ./scripts/windows/Enter-Environment.ps1
./scripts/windows/Build.ps1 -Jobs 4
node --test Tests/GraphModelTests.cjs Tests/GraphInvestigationTests.cjs Tests/FaceStateTests.cjs Tests/I18nTests.cjs
./scripts/windows/Faces-Smoke.ps1 -Archive build.noindex/windows/artifacts/DigUp-windows-x64-portable.zip -Models C:/test-models -OutputDirectory C:/test-evidence/faces
```

The smoke uses the official NASA S69-31739 crew image, downloaded by a fixed URL/SHA-256 and credited
to NASA. It creates a private Unicode fixture directory with photographs and a real video whose faces
first appear after two seconds. A test-only MSVC/WIC/Media Foundation helper creates real H.264;
neither the generator nor MSVC is required by the installed app. It runs real inference in the packaged WebView, selects among three
faces, loads more than 40 actual matches, seeks a nonzero video time, opens real face graph evidence,
restarts and checks settings. Child PATH contains only Windows system directories. No face responses,
vectors, detections or media players are mocked. Development overrides are marked in its result and
cannot stand in for a final packaged smoke.

`face-worker/tests/native_smoke.py` additionally compares actual CPU/GPU inference when hardware is
available and checks real CPU fallback, blank/corrupt images, Unicode and protocol bounds. The test
driver's Python is not shipped or required to use DigUp. CPU-only CI must record fallback honestly;
it does not certify a GPU vendor. Retail Windows 10/11 installation, driver coverage, signing and
outer-window/high-DPI checks remain part of the [release checklist](windows.md#clean-machine-release-checklist).
