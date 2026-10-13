#requires -Version 7.2
param(
    [string]$Destination,
    [ValidateSet('cl', 'clang-cl')][string]$Compiler = 'clang-cl',
    [ValidateRange(1, 64)][int]$Jobs = 8
)
. "$PSScriptRoot/Common.ps1"
if (!$IsWindows) { throw 'This recipe builds Windows x64 FFmpeg. Use upstream recipes on other platforms.' }
if (!(Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    throw 'Run from an x64 MSVC developer shell (Visual Studio 2019 16.8 or newer; CI uses VS 2022).'
}
if (!(Get-Command "$Compiler.exe" -ErrorAction SilentlyContinue)) {
    throw "Compiler $Compiler is missing. Use Swift's pinned LLVM tools, or pass -Compiler cl with English MSVC resources installed."
}
$ffmpegManifest = Get-Content (Join-Path $PSScriptRoot 'ffmpeg-dependencies.json') -Raw | ConvertFrom-Json
$compilerVersion = if ($Compiler -eq 'clang-cl') {
    & clang-cl.exe --version | Where-Object { $_ -notmatch '^InstalledDir:' }
} else {
    (Get-Item (Get-Command cl.exe).Source).VersionInfo.FileVersion
}
if ($Compiler -eq 'clang-cl' -and ($compilerVersion | Out-String) -notmatch ("clang version " + [regex]::Escape($ffmpegManifest.clangVersion))) {
    throw "Expected clang-cl $($ffmpegManifest.clangVersion) from Swift 6.3.3. Check PATH ordering."
}
$buildRoot = Join-Path $script:Repo 'build.noindex/ffmpeg'
$toolsRoot = Join-Path $buildRoot 'tools'
$sourceRoot = Join-Path $buildRoot "ffmpeg-$($ffmpegManifest.source.version)"
$dav1dSource = Join-Path $buildRoot "dav1d-$($ffmpegManifest.dav1d.version)"
$dav1dObjects = Join-Path $buildRoot 'dav1d-objects'
$pythonRoot = Join-Path $toolsRoot "python-$($ffmpegManifest.python.version)"
$mesonRoot = Join-Path $toolsRoot "meson-$($ffmpegManifest.meson.version)"
$ninjaRoot = Join-Path $toolsRoot "ninja-$($ffmpegManifest.ninja.version)"
$objectRoot = Join-Path $buildRoot 'objects'
if (!$Destination) { $Destination = Join-Path $script:Vendor 'ffmpeg-own' }
$Destination = [IO.Path]::GetFullPath($Destination)
if (!$Destination.StartsWith(([IO.Path]::GetFullPath($script:Vendor) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'FFmpeg output must be a subdirectory of Vendor.'
}
$gitCommand = (Get-Command git.exe -ErrorAction Stop).Source
$gitRoot = Split-Path (Split-Path $gitCommand -Parent) -Parent
$bash = Join-Path $gitRoot 'usr/bin/bash.exe'
if (!(Test-Path -LiteralPath $bash)) {
    $bash = Join-Path $env:ProgramFiles 'Git/usr/bin/bash.exe'
}
if (!(Test-Path -LiteralPath $bash)) { throw 'Install Git for Windows (including Git Bash) before building FFmpeg.' }

$sourceArchive = Get-VerifiedDownload $ffmpegManifest.source
$makeArchive = Get-VerifiedDownload $ffmpegManifest.make
$nasmArchive = Get-VerifiedDownload $ffmpegManifest.nasm
$dav1dArchive = Get-VerifiedDownload $ffmpegManifest.dav1d
$pythonArchive = Get-VerifiedDownload $ffmpegManifest.python
$mesonArchive = Get-VerifiedDownload $ffmpegManifest.meson
$ninjaArchive = Get-VerifiedDownload $ffmpegManifest.ninja
$pkgconfArchive = Get-VerifiedDownload $ffmpegManifest.pkgconf
New-Item -ItemType Directory -Force -Path $buildRoot, $toolsRoot, $objectRoot | Out-Null
if (!(Test-Path -LiteralPath "$toolsRoot/usr/bin/make.exe")) {
    Expand-NativeArchive $makeArchive $toolsRoot
}
if (!(Test-Path -LiteralPath "$toolsRoot/nasm/nasm-2.16.03/nasm.exe")) {
    Expand-NativeArchive $nasmArchive "$toolsRoot/nasm"
}
if (!(Test-Path -LiteralPath "$sourceRoot/configure")) {
    Expand-NativeArchive $sourceArchive $buildRoot
}
if (!(Test-Path -LiteralPath "$dav1dSource/meson.build")) {
    Expand-NativeArchive $dav1dArchive $buildRoot
}
if (!(Test-Path -LiteralPath "$pythonRoot/python.exe")) {
    Expand-NativeArchive $pythonArchive $pythonRoot
}
if (!(Test-Path -LiteralPath "$mesonRoot/meson.py")) {
    Expand-NativeArchive $mesonArchive $toolsRoot
}
if (!(Test-Path -LiteralPath "$ninjaRoot/ninja.exe")) {
    Expand-NativeArchive $ninjaArchive $ninjaRoot
}
if (!(Test-Path -LiteralPath "$toolsRoot/usr/bin/pkgconf.exe")) {
    Expand-NativeArchive $pkgconfArchive $toolsRoot
}
# Embedded Python ignores PYTHONPATH; explicitly add only the pinned Meson source tree.
@('python313.zip', '.', $mesonRoot) | Set-Content -LiteralPath "$pythonRoot/python313._pth" -Encoding utf8NoBOM
Write-BuildPhase 'START reset FFmpeg/dav1d output directories'
Reset-BuildDirectory $Destination
Reset-BuildDirectory $dav1dObjects
Write-BuildPhase 'END reset FFmpeg/dav1d output directories'
$nativeFile = Join-Path $buildRoot 'dav1d-native.ini'
$compilerPath = (Get-Command "$Compiler.exe").Source.Replace('\', '/')
@("[binaries]", "c = '$compilerPath'", "c_ld = '$(if ($Compiler -eq 'clang-cl') { 'lld-link' } else { 'link' })'") |
    Set-Content -LiteralPath $nativeFile -Encoding utf8NoBOM
$savedPath = $env:PATH
try {
    $env:PATH = "$pythonRoot;$ninjaRoot;$toolsRoot/nasm/nasm-2.16.03;$savedPath"
    Invoke-BoundedChecked "$pythonRoot/python.exe" @('-u', "$mesonRoot/meson.py", 'setup', $dav1dObjects, $dav1dSource,
        '--native-file', $nativeFile, '--prefix', $Destination, '--libdir', 'lib', '--backend', 'ninja',
        '--buildtype', 'release', '--default-library', 'shared', '--wrap-mode', 'nodownload', '-Db_vscrt=md',
        '-Denable_tools=false', '-Denable_tests=false', '-Denable_examples=false', '-Denable_docs=false') -TimeoutSeconds 300 -Phase 'dav1d Meson setup'
    Invoke-BoundedChecked "$ninjaRoot/ninja.exe" @('-C', $dav1dObjects, '-j', [string]$Jobs) -TimeoutSeconds 900 -Phase 'dav1d Ninja build'
    Invoke-BoundedChecked "$pythonRoot/python.exe" @('-u', "$mesonRoot/meson.py", 'install', '-C', $dav1dObjects, '--no-rebuild') -TimeoutSeconds 120 -Phase 'dav1d Meson install'
} finally { $env:PATH = $savedPath }
$env:DIGUP_FFMPEG_SOURCE = $sourceRoot
$env:DIGUP_FFMPEG_BUILD = $objectRoot
$env:DIGUP_FFMPEG_DESTINATION = $Destination
$env:DIGUP_FFMPEG_TOOLS = $toolsRoot
$env:DIGUP_FFMPEG_MSVC = Split-Path (Get-Command cl.exe -ErrorAction Stop).Source -Parent
$env:DIGUP_FFMPEG_JOBS = [string]$Jobs
$env:DIGUP_FFMPEG_CC = "$Compiler.exe"
$env:DIGUP_FFMPEG_LD = if ($Compiler -eq 'clang-cl') { 'lld-link.exe' } else { 'link.exe' }
$buildScript = Join-Path $PSScriptRoot 'build-ffmpeg.sh'
Invoke-BoundedChecked $bash @('--noprofile', '--norc', $buildScript) -TimeoutSeconds 1800 -Phase 'FFmpeg configure/build/install'

New-Item -ItemType Directory -Force -Path "$Destination/doc", "$Destination/source" | Out-Null
Copy-Item -LiteralPath "$sourceRoot/COPYING.LGPLv2.1" -Destination "$Destination/LICENSE.txt"
Copy-Item -LiteralPath "$Destination/LICENSE.txt" -Destination "$Destination/source/LICENSE.txt"
Copy-Item -LiteralPath $sourceArchive -Destination "$Destination/source"
Copy-Item -LiteralPath $dav1dArchive -Destination "$Destination/source"
Copy-Item -LiteralPath "$dav1dSource/COPYING" -Destination "$Destination/doc/dav1d-BSD-2-Clause.txt"
Copy-Item -LiteralPath "$dav1dSource/COPYING" -Destination "$Destination/source/dav1d-BSD-2-Clause.txt"
Copy-Item -LiteralPath "$dav1dSource/doc/PATENTS" -Destination "$Destination/doc/dav1d-PATENTS.txt"
Copy-Item -LiteralPath "$dav1dSource/doc/PATENTS" -Destination "$Destination/source/dav1d-PATENTS.txt"
# Both pinned projects use x264's ISC-licensed assembly macros; retain their complete notice with the binaries.
Get-Content -LiteralPath "$dav1dSource/src/ext/x86/x86inc.asm" -TotalCount 22 |
    Set-Content -LiteralPath "$Destination/doc/x86inc-ISC.txt" -Encoding utf8NoBOM
Copy-Item -LiteralPath "$Destination/doc/x86inc-ISC.txt" -Destination "$Destination/source/x86inc-ISC.txt"
foreach ($recipe in @('Build-FFmpeg.ps1', 'build-ffmpeg.sh', 'ffmpeg-dependencies.json', 'Common.ps1', 'dependencies.json')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $recipe) -Destination "$Destination/source"
}
@'
FFmpeg for DigUp: unmodified upstream source, dynamically linked LGPL-2.1-or-later build.

The accompanying release source ZIP is a self-contained minimal build tree: the
exact upstream archive is in Vendor/downloads, and the PowerShell/Bash recipes and
its SHA-256 are in scripts/windows/ffmpeg-dependencies.json. No patches were applied.
The build output also keeps a flat copy of the archive and recipes under source/.
No GPL, nonfree, networking or GPU acceleration are enabled. The sole external codec
is the BSD-2-Clause dav1d library, built from the included source for software AV1/AVIF
decoding. Its replaceable DLL is installed beside FFmpeg; see dav1d-BSD-2-Clause.txt.
The bundled x86 assembly macros carry the notice in x86inc-ISC.txt. The upstream
AV1 patent notice is included as dav1d-PATENTS.txt.
Python, Meson, Ninja, pkgconf, GNU Make and NASM are isolated build tools only;
they are not part of the installed runtime and do not require system installation.

To rebuild on Windows x64:
1. Extract the accompanying source ZIP and change to its root directory. A DigUp
   checkout at the release's recorded source commit can also be used. The ZIP is
   complete for this FFmpeg build; it does not require a full DigUp checkout.
2. Install Git for Windows, PowerShell 7, pinned Swift 6.3.3 (clang-cl/lld-link) and Visual Studio 2022 C++ Build Tools + Windows SDK.
3. Open an x64 MSVC developer shell, remaining in the extracted tree's root.
4. Add Swift's Toolchains/6.3.3+Asserts/usr/bin to PATH, then run:
   pwsh -File scripts/windows/Build-FFmpeg.ps1 -Destination Vendor/ffmpeg -Jobs 8
   The default compiler is Swift's LLVM clang-cl with the MSVC ABI. To use Microsoft's
   compiler instead, pass -Compiler cl (its English language pack is needed by configure).
The script checks every download's SHA-256, then runs the exact configure command in
build-ffmpeg.sh and GNU Make. Its output includes replaceable DLLs and ffmpeg/ffprobe.
The bundled FFmpeg and dav1d source archives are reused from Vendor/downloads.
Build tools are downloaded with pinned hashes on the first build. Meson builds
dav1d with the same compiler before FFmpeg configures with --enable-libdav1d.
Build outputs may differ byte-for-byte across MSVC/Windows SDK revisions; CI controls
the hosted runner family and records the compiler versions with the release checksums.

The source package is distributed alongside DigUp's Windows binaries; preserve both
when redistributing. FFmpeg source is available under LGPL-2.1-or-later; see LICENSE.txt.
Official build instructions: https://ffmpeg.org/platform.html#Microsoft-Visual-C_002b_002b-or-Intel-C_002b_002b-Compiler-for-Windows
License information: https://ffmpeg.org/legal.html
'@ | Set-Content -LiteralPath "$Destination/doc/BUILDING.txt" -Encoding utf8NoBOM
Copy-Item -LiteralPath "$Destination/doc/BUILDING.txt" -Destination "$Destination/source/BUILDING.txt"
@{
    sourceVersion = $ffmpegManifest.source.version
    sourceSha256 = $ffmpegManifest.source.sha256
    dav1dVersion = $ffmpegManifest.dav1d.version
    dav1dSha256 = $ffmpegManifest.dav1d.sha256
    pythonVersion = $ffmpegManifest.python.version
    mesonVersion = $ffmpegManifest.meson.version
    ninjaVersion = $ffmpegManifest.ninja.version
    pkgconfVersion = $ffmpegManifest.pkgconf.version
    compiler = $Compiler
    compilerVersion = @($compilerVersion)
    msvcToolsVersion = $env:VCToolsVersion
    windowsSdkVersion = $env:WindowsSDKVersion
    makeVersion = $ffmpegManifest.make.version
    nasmVersion = $ffmpegManifest.nasm.version
} | ConvertTo-Json | Set-Content -LiteralPath "$Destination/source/BUILD-VERSIONS.json" -Encoding utf8NoBOM
Invoke-Checked "$Destination/bin/ffmpeg.exe" @('-hide_banner', '-version')
Invoke-Checked "$Destination/bin/ffprobe.exe" @('-hide_banner', '-version')
$decoders = (& "$Destination/bin/ffmpeg.exe" -hide_banner -decoders 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $decoders -notmatch '\blibdav1d\b') {
    throw 'FFmpeg lacks the required software AV1 decoder (libdav1d); AVIF would require unavailable hardware.'
}
$license = (& "$Destination/bin/ffmpeg.exe" -hide_banner -L 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $license -notmatch 'Lesser General Public License') { throw 'FFmpeg did not identify an LGPL build.' }
Write-Host "Native LGPL FFmpeg is ready in $Destination. Publish its source/ directory with the binaries."
