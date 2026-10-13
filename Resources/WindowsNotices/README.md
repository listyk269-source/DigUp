# Windows runtime notices

Original, unedited upstream license/notice texts are retained here. `sources.json`
records the exact source URL and SHA-256 of each text; packaging copies this entire
directory. The files are excluded from Git newline conversion to preserve their hashes.

Swift, Foundation, Foundation ICU, and libdispatch texts come from the
`swift-6.3.3-RELEASE` tag. Swift's Windows build embeds curl, libxml2, zlib and Brotli
in its Foundation libraries. Their versions, and swift-collections, are pinned by
the `release/6.3` scheme in
[Swift's release checkout configuration](https://github.com/swiftlang/swift/blob/swift-6.3.3-RELEASE/utils/update_checkout/update-checkout-config.json).
The compilation recipe is
[utils/build.ps1](https://github.com/swiftlang/swift/blob/swift-6.3.3-RELEASE/utils/build.ps1).
Foundation ICU's version header identifies ICU 76.1; both the Swift wrapper license
and ICU's full third-party notices are included.

This directory concerns the runtime DLLs, not the entire compiler installation.
FFmpeg's exact source archive and build recipe, PDFium's supplied transitive
licenses, Rust crate licenses, and the project's existing acknowledgements are
packaged separately. Microsoft's redistributable files are copied only from the
licensed VS build tools' `VCToolsRedistDir`; Windows system DLLs and developer
toolchain executables are not distributed.
