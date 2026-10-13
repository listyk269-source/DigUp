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
New-Item -ItemType Directory -Force -Path $buildRoot, $toolsRoot, $objectRoot | Out-Null
if (!(Test-Path -LiteralPath "$toolsRoot/usr/bin/make.exe")) {
    Invoke-Checked tar @('-xf', $makeArchive, '-C', $toolsRoot)
}
if (!(Test-Path -LiteralPath "$toolsRoot/nasm/nasm-2.16.03/nasm.exe")) {
    Expand-Archive -LiteralPath $nasmArchive -DestinationPath "$toolsRoot/nasm" -Force
}
if (!(Test-Path -LiteralPath "$sourceRoot/configure")) {
    Invoke-Checked tar @('-xf', $sourceArchive, '-C', $buildRoot)
}
Reset-BuildDirectory $Destination
$env:DIGUP_FFMPEG_SOURCE = $sourceRoot
$env:DIGUP_FFMPEG_BUILD = $objectRoot
$env:DIGUP_FFMPEG_DESTINATION = $Destination
$env:DIGUP_FFMPEG_TOOLS = $toolsRoot
$env:DIGUP_FFMPEG_MSVC = Split-Path (Get-Command cl.exe -ErrorAction Stop).Source -Parent
$env:DIGUP_FFMPEG_JOBS = [string]$Jobs
$env:DIGUP_FFMPEG_CC = "$Compiler.exe"
$env:DIGUP_FFMPEG_LD = if ($Compiler -eq 'clang-cl') { 'lld-link.exe' } else { 'link.exe' }
$buildScript = Join-Path $PSScriptRoot 'build-ffmpeg.sh'
Invoke-Checked $bash @('--noprofile', '--norc', $buildScript)

New-Item -ItemType Directory -Force -Path "$Destination/doc", "$Destination/source" | Out-Null
Copy-Item -LiteralPath "$sourceRoot/COPYING.LGPLv2.1" -Destination "$Destination/LICENSE.txt"
Copy-Item -LiteralPath "$Destination/LICENSE.txt" -Destination "$Destination/source/LICENSE.txt"
Copy-Item -LiteralPath $sourceArchive -Destination "$Destination/source"
foreach ($recipe in @('Build-FFmpeg.ps1', 'build-ffmpeg.sh', 'ffmpeg-dependencies.json', 'Common.ps1', 'dependencies.json')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $recipe) -Destination "$Destination/source"
}
@'
FFmpeg for DigUp: unmodified upstream source, dynamically linked LGPL-2.1-or-later build.

The accompanying release source ZIP is a self-contained minimal build tree: the
exact upstream archive is in Vendor/downloads, and the PowerShell/Bash recipes and
its SHA-256 are in scripts/windows/ffmpeg-dependencies.json. No patches were applied.
The build output also keeps a flat copy of the archive and recipes under source/.
No GPL, nonfree, external codec libraries, networking or GPU acceleration are enabled.
GNU Make and NASM are build tools only; they are not part of the installed runtime.

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
The bundled source archive is reused from Vendor/downloads. GNU Make and NASM are
downloaded with pinned hashes on the first build; they are not runtime dependencies.
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
    compiler = $Compiler
    compilerVersion = @($compilerVersion)
    msvcToolsVersion = $env:VCToolsVersion
    windowsSdkVersion = $env:WindowsSDKVersion
    makeVersion = $ffmpegManifest.make.version
    nasmVersion = $ffmpegManifest.nasm.version
} | ConvertTo-Json | Set-Content -LiteralPath "$Destination/source/BUILD-VERSIONS.json" -Encoding utf8NoBOM
Invoke-Checked "$Destination/bin/ffmpeg.exe" @('-hide_banner', '-version')
Invoke-Checked "$Destination/bin/ffprobe.exe" @('-hide_banner', '-version')
$license = (& "$Destination/bin/ffmpeg.exe" -hide_banner -L 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $license -notmatch 'Lesser General Public License') { throw 'FFmpeg did not identify an LGPL build.' }
Write-Host "Native LGPL FFmpeg is ready in $Destination. Publish its source/ directory with the binaries."
