#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][string]$Models,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$People,
    [string]$DevelopmentGui,
    [string]$DevelopmentHelper
)
. "$PSScriptRoot/Common.ps1"
$testRoot = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $testRoot) { throw 'Use a fresh evidence directory.' }
$modelsPath = [IO.Path]::GetFullPath($Models)
New-Item -ItemType Directory -Path $testRoot | Out-Null
$package = Join-Path $testRoot 'Приложение café'
[IO.Compression.ZipFile]::ExtractToDirectory([IO.Path]::GetFullPath($Archive),$package)
$fixtureSpec = [pscustomobject]@{file='face-nasa-S69-31739.jpg';url='https://images-assets.nasa.gov/image/S69-31739/S69-31739~orig.jpg';sha256='ba9ccc7c8accc044ebe71fbe402255d45f4cb0fec67f2c9afbfb4ed71d671784'}
$fixturePhoto = Get-VerifiedDownload $fixtureSpec
$fixture = Join-Path $testRoot 'Фото лица Ё café'
$index = Join-Path $testRoot 'Private index'
$settings = Join-Path $testRoot 'settings.json'
New-Item -ItemType Directory -Path $fixture | Out-Null
Copy-Item -LiteralPath $fixturePhoto -Destination "$fixture/FACE742 crew.jpg"
# Public fixture pixels are unchanged. Add a minimal camera DateTimeOriginal APP1 segment to copies,
# then give them recent mtimes: this exercises actual EXIF extraction rather than injecting DB replies.
function Write-FixtureCaptureDate([string]$Path, [string]$Date) {
    $bytes=[IO.File]::ReadAllBytes($Path)
    $stream=[IO.MemoryStream]::new(); $writer=[IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([Text.Encoding]::ASCII.GetBytes("Exif`0`0II")); $writer.Write([uint16]42); $writer.Write([uint32]8)
        $writer.Write([uint16]1); $writer.Write([uint16]0x8769); $writer.Write([uint16]4); $writer.Write([uint32]1); $writer.Write([uint32]26); $writer.Write([uint32]0)
        $writer.Write([uint16]1); $writer.Write([uint16]0x9003); $writer.Write([uint16]2); $writer.Write([uint32]20); $writer.Write([uint32]44); $writer.Write([uint32]0)
        $writer.Write([Text.Encoding]::ASCII.GetBytes($Date+"`0")); $writer.Flush(); $payload=$stream.ToArray()
        $length=$payload.Length+2
        $segment=[byte[]]@(255,216,255,225,($length -shr 8),($length -band 255)) + $payload + $bytes[2..($bytes.Length-1)]
        [IO.File]::WriteAllBytes($Path,$segment)
    } finally { $writer.Dispose(); $stream.Dispose() }
}
$fixtureDate = [DateTime]::new(2022,1,1,0,0,0,[DateTimeKind]::Utc)
[IO.File]::SetLastWriteTimeUtc("$fixture/FACE742 crew.jpg", $fixtureDate)
for ($number=1; $number -le 42; $number++) {
    $photoPath = Join-Path $fixture ('FACE742 Снимок {0:D2}.jpg' -f $number)
    Copy-Item -LiteralPath $fixturePhoto -Destination $photoPath
    Write-FixtureCaptureDate $photoPath ('{0}:02:{1:D2} 12:00:00' -f (2000+(($number-1)%4)), (1+[int][math]::Floor(($number-1)/4)))
    [IO.File]::SetLastWriteTimeUtc($photoPath, $fixtureDate.AddDays($number))
}
$cli = Join-Path $package 'helper/digup.exe'
$gui = Join-Path $package 'DigUp.exe'
if ($DevelopmentHelper) {
    Copy-Item -LiteralPath ([IO.Path]::GetFullPath($DevelopmentHelper)) -Destination $cli -Force
    Copy-Item "$script:Vendor/faces/bin" "$package/helper/faces" -Recurse -Force
}
if ($DevelopmentGui) { $gui = [IO.Path]::GetFullPath($DevelopmentGui) }
function Private-StartInfo([string]$Program, [string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($Program)
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.StandardInputEncoding=[Text.UTF8Encoding]::new($false)
    $start.StandardOutputEncoding=[Text.Encoding]::UTF8; $start.StandardErrorEncoding=[Text.Encoding]::UTF8
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    foreach ($variable in 'DIGUP_WORKER_DIR','DIGUP_BACKENDS','DIGUP_FFMPEG','GGML_BACKEND_PATH','DIGUP_DEVICE','DIGUP_FACE_WORKER','DIGUP_FACE_DISABLE_GPU','DIGUP_FACE_GPU_DEVICE') {
        $start.Environment.Remove($variable) | Out-Null
    }
    $start.Environment['PATH']="$env:SystemRoot/System32;$env:SystemRoot"
    $start.Environment['DIGUP_MODELS']=$modelsPath
    # The semantic index is CPU-only; the face smoke separately exercises Auto and reports its actual backend.
    $start.Environment.Remove('DIGUP_CPU_ONLY') | Out-Null
    $start.Environment['WEBVIEW2_USER_DATA_FOLDER']=Join-Path $index '.webview'
    return $start
}
function Run-Private([string]$Program, [string[]]$Arguments, [string]$Label, [int]$TimeoutSeconds=900) {
    $process = [Diagnostics.Process]::Start((Private-StartInfo $Program $Arguments))
    try {
        $process.StandardInput.Close()
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutSeconds*1000)) { throw "$Label exceeded $TimeoutSeconds seconds." }
        if (!$stdout.Wait(5000) -or !$stderr.Wait(5000)) { throw "$Label left output handles open." }
        $stdout.Result | Set-Content -LiteralPath "$testRoot/$Label.stdout.txt" -Encoding utf8NoBOM
        $stderr.Result | Set-Content -LiteralPath "$testRoot/$Label.stderr.txt" -Encoding utf8NoBOM
        if ($process.ExitCode) { throw "$Label failed with exit $($process.ExitCode)." }
    } finally { if (!$process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }; $process.Dispose() }
}
# Black until 2 seconds, followed by the real crew photograph: a match must have a genuine nonzero timestamp.
# Media Foundation supplies a real H.264 encoder on the Windows build/test host.
# This avoids depending on an optional MPEG4 Part 2 WebView decoder or adding a
# patent-encumbered encoder to the application's LGPL FFmpeg package.
& "$PSScriptRoot/New-FaceVideoFixture.ps1" -Image $fixturePhoto -Output "$fixture/FACE742 Видео после двух секунд.mp4" -BuildDirectory "$testRoot/video-tools"
Run-Private $cli @('index',$fixture,'--index',$index,'--device','cpu') 'semantic-index'
@{folders=@($fixture);codeRoots=@();skipped=@();skipTypes=@();setUp=$true;language='ru';device='cpu';faceDevice='auto'} |
    ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $settings -Encoding utf8NoBOM
$passes = if ($People) { @('first','restart','verify') } else { @('first','restart') }
foreach ($pass in $passes) {
    $report=Join-Path $testRoot "gui-$pass.json"
    $arguments=@('--index',$index,'--models',$modelsPath,'--settings',$settings,'--debug-isolated',
        '--debug-faces','--debug-query','FACE742','--debug-report',$report,'--debug-quit','--helper',$cli)
    if ($People) { $arguments += '--debug-people' }
    Run-Private $gui $arguments "gui-$pass"
    $ui=Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    if ($ui.error) { throw "Actual face UI failed ($pass): $($ui.error); inspect $report" }
    $f=$ui.features.faces
    if ($f.index.state -ne 'completed' -or $f.index.failed -ne 0 -or $f.faceChoices -lt 3 -or $f.boxes -lt 3 -or
        $f.firstPage -ne 40 -or $f.matches.Count -ne $f.total -or $f.total -le 40 -or !$f.selectionRacePreserved -or
        @($f.matches.face_id | Sort-Object -Unique).Count -ne $f.total -or
        @($f.matches | Where-Object { $_.cosine -lt 0.363 -or $_.cosine -gt 1.00001 }).Count -or
        $f.video.loc -le 0 -or [Math]::Abs($f.video.currentTime-$f.video.loc) -gt .25 -or !$f.graph.faceMode -or
        @($f.graph.edges | Where-Object { 'face' -in $_.matchTypes }).Count -lt 1) {
        throw "Actual face selection/matches/progress/timeline/graph checks failed ($pass)."
    }
    if ($f.index.device -notin @('cpu','gpu') -or ($f.index.device -eq 'cpu' -and !$f.index.fallback_reason)) {
        throw 'Auto face mode must report GPU or an explicit CPU fallback reason.'
    }
    foreach ($phase in @('faces-select','faces-matches','faces-video')) {
        $capture=Join-Path $index "capture-$phase.png"
        $bytes=[IO.File]::ReadAllBytes($capture)
        if ($bytes.Length -lt 24 -or [Convert]::ToHexString($bytes[0..7]) -ne '89504E470D0A1A0A') { throw 'Invalid native face PNG.' }
        Copy-Item -LiteralPath $capture -Destination "$testRoot/capture-$pass-$phase.png"
    }
    if ($People) {
        $peopleReport = $ui.features.people
        if (!$peopleReport -or !$peopleReport.passed) { throw "Actual People workflow failed ($pass)." }
        if ($peopleReport.phase -ne $pass) { throw "People persistence phase mismatch ($pass)." }
        $album=$peopleReport.albumAccess
        $gallery=$peopleReport.gallery
        $filters=$peopleReport.galleryFilters
        if (!$peopleReport.period.passed -or !$peopleReport.workspace.passed) { throw 'Actual year-range/EXIF or workspace navigation checks failed.' }
        if (!$filters -or !$filters.newestSorted -or !$filters.oldestSorted -or !$filters.photoOnly -or !$filters.videoOnly -or
            !$filters.filteredViewer -or !$filters.rapidSwitch -or !$filters.preferencesPersisted -or !$filters.datesVisible -or !$filters.accessibleMetadata -or
            $filters.photos -le 40 -or $filters.distinctDates -le 1) { throw 'Actual date/media gallery filtering, paging or preference persistence failed.' }
        if (!$gallery -or $gallery.mode -ne 'gallery' -or !$gallery.wholeImage -or !$gallery.arrowLoadedNextPage -or !$gallery.offscreenDeferred -or $gallery.visibleDecoded -le 0 -or
            !$gallery.repeatedVideoFramesGrouped -or !$gallery.escapeRestoresFocus -or $gallery.uniqueFiles -ne $gallery.total -or $gallery.loaded -ne $gallery.total) {
            throw 'Actual labelled gallery must show whole media, group files and navigate all pages with focus restoration.'
        }
        if (!$album -or !$album.offscreenDeferred -or !$album.rowRetainedOnCheck -or !$album.automaticPageBeyond40 -or
            !$album.laterThumbnailDecoded -or !$album.cacheProbeDecoded -or $album.cacheProbeReused -ne ($pass -ne 'first') -or $album.loaded -ne $album.total) {
            throw 'Actual labelled album must retain rows, defer offscreen previews, and scroll past 40 to every observation.'
        }
        if ($pass -eq 'first' -and ($peopleReport.bulkLoadedBefore -ne 40 -or $peopleReport.bulkTotalMatches -le 40 -or
            !$peopleReport.bulkAssignedBeyondLoaded -or $peopleReport.excludedCount -ne 1 -or !$peopleReport.exclusionUndo -or
            !$peopleReport.selectiveUndo -or !$peopleReport.renameUndo)) { throw 'Actual bulk/exclusion/rename/undo checks failed.' }
        if ($pass -eq 'restart' -and (!$peopleReport.suggestionsNotAutoAssigned -or !$peopleReport.acceptedNew -or !$peopleReport.rejectedNew)) {
            throw 'New media must remain suggestions until an explicit label decision.'
        }
        if ($pass -eq 'restart' -and (!$peopleReport.suggestionsCapturedBeforeDecision -or $peopleReport.suggestionCapturedTotal -ne 2)) {
            throw 'The native suggestion capture must show both genuine new proposals before decisions.'
        }
        if ($pass -eq 'verify' -and !$peopleReport.persistenceVerified) { throw 'Accepted/rejected labels did not survive restart.' }
        $peopleCaptures=@('people-assigned','people-suggestions','people-rename','people-gallery','people-gallery-viewer','people-gallery-filtered','people-gallery-videos','people-period','people-period-compact','workspace-settings','workspace-search','workspace-graph')
        if($pass -eq 'first') { $peopleCaptures += 'people-period-hero' }
        foreach ($phase in $peopleCaptures) {
            $capture = Join-Path $index "capture-$phase.png"
            $bytes = [IO.File]::ReadAllBytes($capture)
            if ($bytes.Length -lt 24 -or [Convert]::ToHexString($bytes[0..7]) -ne '89504E470D0A1A0A') { throw 'Invalid native People PNG.' }
            Copy-Item -LiteralPath $capture -Destination "$testRoot/capture-$pass-$phase.png"
        }
        if ($pass -eq 'first') {
            # New media enters through the real ordinary index; the next GUI pass
            # performs actual face backfill. Existing labels must remain manual.
            foreach ($number in 1..2) {
                Copy-Item -LiteralPath $fixturePhoto -Destination (Join-Path $fixture ('FACE742 Новый файл {0:D2}.jpg' -f $number))
            }
            Run-Private $cli @('index',$fixture,'--index',$index,'--device','cpu') 'new-media-index'
        }
    }
}
$saved=Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
if ($saved.faceDevice -ne 'auto' -or $saved.device -ne 'cpu' -or $saved.folders[0] -ne $fixture) { throw 'Face preference altered existing settings.' }
@{result='passed';realModels=$true;people=[bool]$People;developmentGui=[bool]$DevelopmentGui;developmentHelper=[bool]$DevelopmentHelper;
    userInstallationModified=$false;archiveSha256=(Get-FileHash -LiteralPath $Archive).Hash.ToLowerInvariant();
    checks=@('real YuNet/SFace','three selectable faces','bbox/crop previews','40 then all actual face observations',
        'stale selection ignored','real video timestamp and seek','first launch and restart','backfill progress',
        'actual GPU or explicit CPU fallback','independent persisted face preference','real face graph evidence',
        'Unicode/spaces','PATH only System32/Windows','native WebView PNG captures')} |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$testRoot/result.json" -Encoding utf8NoBOM
Write-Host "Actual packaged face search passed: $testRoot"
