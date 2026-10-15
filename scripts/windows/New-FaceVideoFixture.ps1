[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Image,
    [Parameter(Mandatory = $true)][string]$Output,
    [string]$BuildDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskRepository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$taskImage = (Resolve-Path -LiteralPath $Image).Path
$taskOutput = [IO.Path]::GetFullPath($Output)
if (Test-Path -LiteralPath $taskOutput) { throw 'Fixture output already exists. Choose a fresh output file.' }
$taskParent = [IO.Path]::GetDirectoryName($taskOutput)
New-Item -ItemType Directory -Path $taskParent -Force | Out-Null
if (-not $BuildDirectory) { $BuildDirectory = Join-Path $taskParent 'face-video-tools' }
$taskBuild = [IO.Path]::GetFullPath($BuildDirectory)
New-Item -ItemType Directory -Path $taskBuild -Force | Out-Null

# This is a build/test helper. Users of the installed app do not need MSVC.
$taskCompiler = Get-Command cl.exe -ErrorAction SilentlyContinue
if (-not $taskCompiler) {
    $taskVsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (-not (Test-Path -LiteralPath $taskVsWhere)) { throw 'MSVC is required to build the test fixture generator.' }
    $taskInstallations = & $taskVsWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $taskInstallations) { throw 'Visual Studio C++ Build Tools were not found.' }
    $taskVsRoot = [string]($taskInstallations | Select-Object -First 1)
    $taskVcvars = Join-Path $taskVsRoot 'VC/Auxiliary/Build/vcvars64.bat'
    if (-not (Test-Path -LiteralPath $taskVcvars)) { throw 'The x64 MSVC environment script was not found.' }
    # The one command here contains only a resolved installation path, not media
    # paths or user input. All compilation and fixture arguments use arrays below.
    & $env:ComSpec /d /c "call `"$taskVcvars`" >nul && set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process') }
    }
    if ($LASTEXITCODE -ne 0) { throw 'The x64 MSVC environment could not be initialized.' }
    $taskCompiler = Get-Command cl.exe -ErrorAction Stop
}
$taskProgram = Join-Path $taskBuild 'FaceVideoFixture.exe'
$taskObject = Join-Path $taskBuild 'FaceVideoFixture.obj'
$taskSource = Join-Path $PSScriptRoot 'FaceVideoFixture.cpp'
$taskCompilerArguments = @('/nologo', '/std:c++17', '/EHsc', '/W4', '/WX', '/O2', '/MT', '/utf-8',
    '/DUNICODE', '/D_UNICODE', "/Fo$taskObject", "/Fe$taskProgram", $taskSource,
    '/link', 'ole32.lib', 'windowscodecs.lib', 'mf.lib', 'mfplat.lib', 'mfreadwrite.lib', 'mfuuid.lib')
& $taskCompiler.Source @taskCompilerArguments
if ($LASTEXITCODE -ne 0) { throw 'The Media Foundation fixture generator did not compile.' }
& $taskProgram $taskImage $taskOutput
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $taskOutput)) { throw 'The H.264 face video fixture could not be generated.' }
$taskProbe = Join-Path $taskRepository 'Vendor/ffmpeg/bin/ffprobe.exe'
if (-not (Test-Path -LiteralPath $taskProbe)) { throw 'The pinned packaged ffprobe is required to verify the fixture.' }
$taskJson = & $taskProbe '-v' 'error' '-protocol_whitelist' 'file,pipe' '-select_streams' 'v:0' '-show_entries' 'stream=codec_name,width,height,r_frame_rate,nb_frames:format=duration' '-of' 'json' $taskOutput
if ($LASTEXITCODE -ne 0) { throw 'The generated fixture could not be inspected with ffprobe.' }
$taskInfo = ($taskJson -join "`n") | ConvertFrom-Json
$taskVideo = $taskInfo.streams | Select-Object -First 1
if ($taskVideo.codec_name -ne 'h264' -or $taskVideo.width -ne 960 -or $taskVideo.height -ne 754 -or
    $taskVideo.r_frame_rate -ne '5/1' -or [int]$taskVideo.nb_frames -ne 30 -or
    [math]::Abs([double]$taskInfo.format.duration - 6) -gt 0.05) {
    throw 'The generated fixture does not match the required H.264/960x754/5fps/6second test contract.'
}
$taskEvidence = [ordered]@{
    passed = $true
    generator = 'Windows WIC + Media Foundation H264; test-only /MT native helper'
    input_sha256 = (Get-FileHash -LiteralPath $taskImage -Algorithm SHA256).Hash.ToLowerInvariant()
    output_sha256 = (Get-FileHash -LiteralPath $taskOutput -Algorithm SHA256).Hash.ToLowerInvariant()
    codec = $taskVideo.codec_name
    width = $taskVideo.width
    height = $taskVideo.height
    frame_rate = $taskVideo.r_frame_rate
    frames = [int]$taskVideo.nb_frames
    duration = [double]$taskInfo.format.duration
    black_first_seconds = 2
    image_after_seconds = 2
}
$taskEvidence | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$taskOutput.json" -Encoding utf8
$taskEvidence | ConvertTo-Json -Depth 4
