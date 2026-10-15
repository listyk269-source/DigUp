# Third-party components in the Windows build

DigUp is MIT licensed; that does not change the licenses of separately distributed
components. The model is **not** embedded in the installer. Dependencies and exact
archive SHA-256 values are in `scripts/windows/dependencies.json` and
`scripts/windows/ffmpeg-dependencies.json`; Cargo dependencies are locked in
`shell/src-tauri/Cargo.lock`. Installed and portable builds contain a
`licenses` directory with the supplied license texts and a Cargo package inventory.

| Component | Version / source | License / handling |
|---|---|---|
| DigUp | this checkout | MIT, `LICENSE` |
| llama.cpp / ggml / mtmd | b11461, `4d756bc72bf00a4aacf410ae15a2d315f3db400d`, https://github.com/ggml-org/llama.cpp | MIT; built from source with `scripts/llama.cpp-no-logits.patch`, CPU and optional Vulkan backends |
| Vulkan-Headers / Vulkan-Hpp | Vulkan SDK 1.4.341.1, headers tag `vulkan-sdk-1.4.341.0`, https://github.com/KhronosGroup/Vulkan-Headers | Apache-2.0; some headers also offer MIT. Original notices, full licenses and representative generated headers are included in `licenses/Vulkan/` |
| SPIRV-Headers | `vulkan-sdk-1.4.341.0`, https://github.com/KhronosGroup/SPIRV-Headers | Khronos MIT-style license; original full notice and the used generated SPIR-V header included in `licenses/Vulkan/` |
| SQLite | amalgamation 3.54.0, https://sqlite.org/2026/sqlite-amalgamation-3540000.zip | Public domain; statically compiled with FTS5 and extension loading disabled |
| stb | `2c980bb59875b0d32144a71867fbdebb2f77cd20`, https://github.com/nothings/stb | MIT or public-domain alternative; original headers and notices included |
| miniz | 3.1.2, https://github.com/richgel999/miniz | MIT; notice in bundled source |
| PDFium package | chromium/8086, https://github.com/bblanchon/pdfium-binaries | Wrapper MIT, PDFium BSD and transitive notices; original `licenses/` included |
| FFmpeg / ffprobe / libav DLLs | 8.1.3, https://ffmpeg.org/releases/ffmpeg-8.1.3.tar.xz | LGPL-2.1-or-later; built locally from unmodified official source with no GPL, nonfree, network protocols or GPU support; replaceable shared DLLs |
| dav1d | 1.5.4, https://code.videolan.org/videolan/dav1d | BSD-2-Clause; software AV1 decoder needed for AVIF images, built from pinned upstream source; BSD, x86inc ISC and upstream patent notices in `licenses/FFmpeg-doc/` |
| Swift runtime | 6.3.3, https://github.com/swiftlang/swift | Apache-2.0 with Runtime Library Exception; Windows runtime also contains third-party support DLLs |
| Tauri / Rust crates | exact versions in Cargo.lock | Individual licenses in `licenses/Rust-packages.json` and `licenses/crates/` |
| Microsoft Visual C++ runtime | app-local x64 CRT from installed VS 2022 redistributables | Microsoft redistribution terms from the licensed build tools; copied only from `VCToolsRedistDir` |
| Microsoft Edge WebView2 | Evergreen runtime supplied by Microsoft | Microsoft WebView2 runtime terms; installer embeds a checksum-pinned, Microsoft-signed bootstrapper which obtains the supported runtime if absent |
| EmbeddingGemma 2 | GGUF revision `bfcd298762cc34d0357ece5ebdd31791a3a374d8`, https://huggingface.co/ggml-org/embeddinggemma-2-GGUF | Apache-2.0 according to the upstream model; downloaded separately with fixed size and SHA-256, upstream acknowledgements in `Resources/Acknowledgements.txt` |

## FFmpeg corresponding source

The build produces `DigUp-FFmpeg-8.1.3-source.zip` alongside the binary artifacts.
It contains the exact FFmpeg and dav1d source archives, SHA-256 manifest, build scripts,
tool versions and build instructions. Distribute this source artifact together
with every Windows binary release and preserve it in mirrors. The only external
codec library is dav1d, whose BSD license is also included in the source artifact.
The LGPL text is installed in `licenses/FFmpeg-LGPL-2.1.txt`.
The configurable upstream source is unchanged and shared DLLs remain replaceable.

## Runtime and crate notice review

Vulkan SDK/glslc and Ninja are build tools and are not included in the application.
The Vulkan backend contains the compiled llama.cpp shaders and header code; its
source/version/hash inventory is `licenses/Vulkan/Vulkan-SOURCES.json`.
The optional `vulkan-1.dll` loader and vendor ICD remain part of the user's graphics
driver installation, not part of DigUp's redistributable. DigUp does not install or
modify GPU drivers.

`Resources/WindowsNotices` contains the original Swift runtime and embedded
Foundation dependency notices, with pinned source URLs and verified text hashes.
Cargo license files are collected from the exact downloaded crate sources and
paired with a package/license inventory. `runtime-inventory.json` records the final
PE imports and file hashes; packaging rejects missing app-local dependencies.
Microsoft's app-local CRT is taken only from the licensed build tools' redistributable
directory. Developer toolchains, debug CRT, certificates, signing keys and model
caches are excluded from the application bundle.

FFmpeg is a separate child process; DigUp does not prevent users replacing its
shared libraries with a compatible build or exercising their LGPL rights. File
contents are processed locally. No cloud inference, telemetry, or registration
service is added by these dependencies.
# Face search components

Optional local face search uses YuNet and SFace weights from OpenCV Zoo revision
`47534e27c9851bb1128ccc0102f1145e27f23f98`. The YuNet model directory declares MIT;
the SFace model directory declares Apache-2.0. Model filenames, sizes, source URLs
and SHA-256 values are pinned in `scripts/windows/face-dependencies.json`. Weights
are downloaded on explicit first use, are not included in the Windows installer,
and are verified before loading. The model-directory license texts are nevertheless
included under `licenses/Faces`.

The Windows face worker uses ONNX Runtime 1.22.1 (MIT) and Microsoft DirectML 1.15.4
(Microsoft Software License Terms for DirectML). Their exact NuGet packages and
native DLL hashes are pinned in the same manifest. Full runtime licenses and
third-party notices are included under `licenses/Faces`; DirectML is redistributed
for Windows use only. ONNX Runtime telemetry is explicitly disabled by the worker.

The Rust face worker dependencies and their license texts are inventoried separately
in `licenses/Faces/Face-worker-crates.json` and `licenses/Faces/crates`. Its source
and lockfile are included in the DigUp source distribution. The application has no
Python/OpenCV installation dependency.

Face smoke tests use NASA image S69-31739, credited to NASA and obtained from the
official NASA image library with a fixed checksum. This public test image is not
bundled with the application and does not imply NASA endorsement.
