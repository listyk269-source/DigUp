#!/usr/bin/env bash
# Run by Build-FFmpeg.ps1 from an x64 MSVC developer environment. No user file is evaluated here.
set -euo pipefail
export PATH="/usr/bin:$PATH"
source_dir=$(cygpath -u "$DIGUP_FFMPEG_SOURCE")
build_dir=$(cygpath -u "$DIGUP_FFMPEG_BUILD")
destination=$(cygpath -u "$DIGUP_FFMPEG_DESTINATION")
tool_dir=$(cygpath -u "$DIGUP_FFMPEG_TOOLS")
msvc_dir=$(cygpath -u "$DIGUP_FFMPEG_MSVC")
# MSVC link.exe must win over Git's unrelated Unix link.exe.
export PATH="$msvc_dir:$tool_dir/usr/bin:$tool_dir/nasm/nasm-2.16.03:$PATH"
export PKG_CONFIG_PATH="$destination/lib/pkgconfig"
# Do not discover codecs from the host environment. Only the pinned dav1d built beside FFmpeg is enabled.
export PKG_CONFIG_LIBDIR="$destination/lib/pkgconfig"
cd "$build_dir"
"$source_dir/configure" \
  --prefix="$destination" --toolchain=msvc --arch=x86_64 --target-os=win32 \
  --cc="$DIGUP_FFMPEG_CC" --ld="$DIGUP_FFMPEG_LD" \
  --enable-shared --disable-static --disable-autodetect --enable-libdav1d \
  --pkg-config="$tool_dir/usr/bin/pkgconf.exe" \
  --disable-gpl --disable-nonfree --disable-version3 \
  --disable-network --disable-hwaccels --disable-ffplay --disable-doc --disable-debug
make -r -j"${DIGUP_FFMPEG_JOBS:-8}"
make -r install
