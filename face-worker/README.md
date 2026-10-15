# DigUp face worker

An isolated, long-lived local inference process. It runs the official YuNet and
SFace ONNX models through ONNX Runtime. It does not download models, contact a
service, identify names, execute media, or access the search database.

Build from the repository root with the pinned Rust toolchain:

```powershell
cargo test --manifest-path face-worker/Cargo.toml --locked
cargo clippy --manifest-path face-worker/Cargo.toml --all-targets --locked -- -D warnings
cargo build --release --manifest-path face-worker/Cargo.toml --locked
```

The application supplies absolute `--models` and `--runtime` paths:

```text
digup-face-worker --models ABSOLUTE_MODEL_DIR --runtime ABSOLUTE_ONNXRUNTIME_LIBRARY --device auto
```

On Windows, runtime DLL dependencies are searched only in the explicitly added
packaged runtime directory, application directory and system directories; current
directory and user PATH are excluded. The packaged runtime is ONNX Runtime 1.22.1
with DirectML 1.15.4. The `ort` binding is locked at 2.0.0-rc.10 (ORT API 1.22).
No Python, OpenCV installation or compiler is needed on the user's machine.

Both model SHA-256 values are embedded and verified before loading:

| Model | SHA-256 |
|---|---|
| `face_detection_yunet_2023mar.onnx` | `8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4` |
| `face_recognition_sface_2021dec.onnx` | `0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79` |

Weights are from OpenCV Zoo commit
`47534e27c9851bb1128ccc0102f1145e27f23f98`.
Their licenses and the runtime notices are maintained by the parent packaging
pipeline. Weights are separate, verified first-use downloads, not hidden installer
payloads.

## Protocol

UTF-8 JSONL on stdin/stdout. Startup emits `{ "event":"ready", "ok":true,
"model_id":..., "dimension":128, "device":"cpu"|"gpu",
"backend":"cpu"|"directml", "fallback_reason":null|... }`.
Requests have an integer or string `id`. Supported operations:

```json
{"id":1,"op":"info"}
{"id":2,"op":"analyze","path":"C:\\prepared\\frame.png","max_faces":32}
{"id":3,"op":"quit"}
```

Every accepted request receives its own `id`, `ok` and data or a plain error.
Analysis adds image width/height and `faces`. A face contains normalized `bbox`
`[x,y,width,height]`, ten normalized five-point `landmarks`, detector `score`, a
size/detection-based heuristic `quality`, and an L2-normalized 128-dimensional
`embedding`. Quality and cosine are not identity probabilities. The stable model
ID `yunet-2023mar-sface-2021dec-rgbraw-align112-v1` binds the pinned weights and
preprocessing revision, independently of the execution device.

The host supplies prepared, orientation-correct JPEG/PNG files; video decoding,
sampling, cancellation, timestamps and database persistence remain with the host.
The worker itself writes no crops or embeddings to disk. Prepared input is capped
at 64 MiB, 8192 per axis and 16 megapixels; decoder allocation is bounded. Request
lines are capped at 16 KiB, NMS candidates at 5000, results at 32 faces per frame.
Malformed/unsupported files return errors without terminating the loop. Killing
this owned helper cancels a pending native inference without blocking the GUI.

`auto` and `gpu` attempt DirectML, with explicit provider registration failure.
Any initialization or inference error recreates both sessions on CPU and retries
once. `device` then reports CPU and `fallback_reason` is nonempty. This reports the
selected provider, not an assertion that every individual model operator ran on
GPU. Sequential execution and memory-pattern-disabled sessions satisfy DirectML
requirements. `DIGUP_CPU_ONLY=1` always wins. `DIGUP_FACE_DISABLE_GPU=1` disables
DirectML with a visible CPU fallback reason and is useful for driver diagnosis and
testing the real CPU fallback path. ONNX Runtime telemetry is explicitly disabled.
`DIGUP_FACE_GPU_DEVICE=0..31` selects a DirectML adapter index for machines with
multiple GPUs (default 0). An unavailable adapter follows the same CPU fallback
path as a failed provider initialization; `info.gpu_device_index` reports the
selected index only while GPU inference is active.

The real-model integration test requires the official NASA S69-31739 JPEG and
checks its pinned SHA-256 before use. It checks three distinct faces, CPU/GPU
agreement, actual unavailable-adapter fallback, explicit CPU override, Unicode
paths, blank/corrupt images, bounded protocol recovery and normalized geometry:

```powershell
python face-worker/tests/native_smoke.py --worker face-worker/target/release/digup-face-worker.exe --models ABSOLUTE_MODEL_DIR --runtime ABSOLUTE_ONNXRUNTIME_DLL --image ABSOLUTE_CREW_JPEG --output ABSOLUTE_REPORT_JSON --require-gpu
```

Omit `--require-gpu` for a CPU-only CI host; the report records the actual selected
device and fallback reason. Removing the packaged DirectML DLL alone may still
permit GPU inference through the signed system DirectML DLL; that case is
reported rather than falsely counted as a missing-provider test.

## Preprocessing provenance

The postprocessing follows the official
[YuNet decoder](https://github.com/opencv/opencv/blob/4.13.0/modules/objdetect/src/face_detect.cpp):
strides 8/16/32, `sqrt(clamp(cls)*clamp(obj))`, grid-relative boxes and landmarks,
exponentiated box dimensions and IoU NMS. This implementation resizes aspect-ratio
preserving into a 640×640 black padded input, uses raw planar BGR, and maps every
result back to the original prepared image. Detector threshold is 0.75, NMS 0.3;
boxes smaller than 12 pixels are discarded.

The five-point canonical coordinates, 112×112 alignment and raw planar RGB input
follow the official
[SFace feature implementation](https://github.com/opencv/opencv/blob/4.13.0/modules/objdetect/src/face_recognize.cpp).
The orientation-preserving least-squares similarity is fitted in native Rust;
inverse bilinear sampling uses a constant black border. SFace's graph performs
normalization internally: applying an additional 1/128 pixel normalization would
produce incompatible embeddings. Tiny floating-point and resampling differences
from OpenCV are expected; matching thresholds must be measured on real fixtures.
