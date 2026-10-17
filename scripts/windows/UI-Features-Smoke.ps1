#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][string]$Models,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$DevelopmentGui,
    [string]$DevelopmentHelper
)
. "$PSScriptRoot/Common.ps1"
$testRoot = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $testRoot) { throw 'Use a fresh evidence directory.' }
$modelsPath = [IO.Path]::GetFullPath($Models)
foreach ($item in @(@('embeddinggemma-2-Q8_0.gguf','2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135'),
    @('mmproj-embeddinggemma-2-Q8_0.gguf','c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f'))) {
    if ((Get-FileHash -LiteralPath (Join-Path $modelsPath $item[0])).Hash -ne $item[1]) { throw 'Model hash mismatch.' }
}
New-Item -ItemType Directory -Path $testRoot | Out-Null
$package = Join-Path $testRoot 'Приложение café'
[IO.Compression.ZipFile]::ExtractToDirectory([IO.Path]::GetFullPath($Archive), $package)
$cli = Join-Path $package 'helper/digup.exe'
if ($DevelopmentHelper) { Copy-Item -LiteralPath ([IO.Path]::GetFullPath($DevelopmentHelper)) -Destination $cli -Force }

$fixture = Join-Path $testRoot 'Документы для UI Ё'
$index = Join-Path $testRoot 'Private index'
$settings = Join-Path $testRoot 'settings.json'
New-Item -ItemType Directory -Path $fixture | Out-Null
for ($number = 1; $number -le 48; $number++) {
    "UIFEATURE742. Coastal lighthouse log number $number. Fishing boats follow the harbor beacon through fog." |
        Set-Content -LiteralPath (Join-Path $fixture ("Заметка café {0:D3}.txt" -f $number)) -Encoding utf8NoBOM
}
Copy-Item -LiteralPath "$script:Repo/Tests/LlamaRuntimeTests/Reference/photo.jpg" -Destination (Join-Path $fixture 'UIFEATURE742-preview.jpg')
function Private-StartInfo([string]$Program, [string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($Program)
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.Encoding]::UTF8; $start.StandardErrorEncoding=[Text.Encoding]::UTF8
    $start.StandardInputEncoding=[Text.UTF8Encoding]::new($false)
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    foreach ($variable in 'DIGUP_WORKER_DIR','DIGUP_BACKENDS','DIGUP_FFMPEG','GGML_BACKEND_PATH','DIGUP_DEVICE') { $start.Environment.Remove($variable) | Out-Null }
    $start.Environment['PATH']="$env:SystemRoot/System32;$env:SystemRoot"
    $start.Environment['DIGUP_MODELS']=$modelsPath; $start.Environment['DIGUP_CPU_ONLY']='1'
    $start.Environment['WEBVIEW2_USER_DATA_FOLDER']=Join-Path $index '.webview'
    return $start
}
function Run-Private([string]$Program, [string[]]$Arguments, [string]$Label) {
    $process = [Diagnostics.Process]::Start((Private-StartInfo $Program $Arguments))
    try {
        $process.StandardInput.Close()
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(900000)) { throw "$Label exceeded 900 seconds." }
        if (!$stdout.Wait(5000) -or !$stderr.Wait(5000)) { throw "$Label left output handles open." }
        $stdout.Result | Set-Content -LiteralPath "$testRoot/$Label.stdout.txt" -Encoding utf8NoBOM
        $stderr.Result | Set-Content -LiteralPath "$testRoot/$Label.stderr.txt" -Encoding utf8NoBOM
        if ($process.ExitCode) { throw "$Label failed with exit $($process.ExitCode)." }
    } finally { if (!$process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }; $process.Dispose() }
}

for ($number=1; $number -le 5; $number++) {
    Copy-Item -LiteralPath "$script:Repo/Tests/LlamaRuntimeTests/Reference/photo.jpg" -Destination (Join-Path $fixture "UIFEATURE742-IMG_2018_000$number.jpg")
}
$periodPhoto=Get-VerifiedDownload ([pscustomobject]@{file='face-nasa-S69-31739.jpg';url='https://images-assets.nasa.gov/image/S69-31739/S69-31739~orig.jpg';sha256='ba9ccc7c8accc044ebe71fbe402255d45f4cb0fec67f2c9afbfb4ed71d671784'})
for ($number=1; $number -le 43; $number++) {
    Copy-Item -LiteralPath $periodPhoto -Destination (Join-Path $fixture ('UIFEATURE742-period-{0:D3}.jpg' -f $number))
}
# Genuine JPEG EXIF DateTimeOriginal, written only to disposable fixtures. No extractor is mocked.
foreach ($photo in Get-ChildItem -LiteralPath $fixture -Filter '*.jpg') {
    $tiff=[IO.MemoryStream]::new(); $writer=[IO.BinaryWriter]::new($tiff)
    $writer.Write([byte[]](0x49,0x49)); $writer.Write([uint16]42); $writer.Write([uint32]8)
    $writer.Write([uint16]1); $writer.Write([uint16]0x8769); $writer.Write([uint16]4); $writer.Write([uint32]1); $writer.Write([uint32]26); $writer.Write([uint32]0)
    $writer.Write([uint16]1); $writer.Write([uint16]0x9003); $writer.Write([uint16]2); $writer.Write([uint32]20); $writer.Write([uint32]44); $writer.Write([uint32]0)
    $year=if($photo.Name -match 'period-(\d+)'){2000+(([int]$Matches[1]-1)%4)}else{2026}
    $writer.Write([Text.Encoding]::ASCII.GetBytes("${year}:10:15 12:34:56`0")); $writer.Flush()
    $payload=[byte[]]([Text.Encoding]::ASCII.GetBytes("Exif`0`0") + $tiff.ToArray()); $writer.Dispose(); $tiff.Dispose()
    $original=[IO.File]::ReadAllBytes($photo.FullName); $length=$payload.Length+2
    [IO.File]::WriteAllBytes($photo.FullName,[byte[]](@(0xff,0xd8,0xff,0xe1,($length -shr 8),($length -band 255)) + $payload + $original[2..($original.Length-1)]))
}
Run-Private (Join-Path $package 'helper/ffmpeg.exe') @('-v','error','-nostdin','-y','-loop','1','-framerate','1',
    '-i',"$script:Repo/Tests/LlamaRuntimeTests/Reference/photo.jpg",'-f','lavfi','-i','sine=frequency=440:duration=2',
    '-t','2','-c:v','mpeg4','-q:v','4','-pix_fmt','yuv420p','-c:a','aac','-shortest',
    (Join-Path $fixture 'UIFEATURE742-preview.mp4')) 'fixture-video'
for ($number=1; $number -le 3; $number++) { Copy-Item -LiteralPath (Join-Path $fixture 'UIFEATURE742-preview.mp4') -Destination (Join-Path $fixture "UIFEATURE742-VID_2019_000$number.mp4") }
$date=[DateTime]::new(2026,10,1,12,0,0,[DateTimeKind]::Utc); $ordinal=0
foreach ($media in Get-ChildItem -LiteralPath $fixture -File | Where-Object Extension -in '.jpg','.mp4' | Sort-Object Name) {
    [IO.File]::SetLastWriteTimeUtc($media.FullName,$date.AddDays($ordinal)); $ordinal++
}
$gui=Join-Path $package 'DigUp.exe'
if ($DevelopmentGui) { $gui=[IO.Path]::GetFullPath($DevelopmentGui) }
foreach ($pass in 'first','restart') {
    $report=Join-Path $testRoot "gui-$pass.json"
    $arguments=@('--index',$index,'--models',$modelsPath,'--settings',$settings,'--debug-isolated',
        '--debug-ui-features','--debug-query','UIFEATURE742','--debug-report',$report,'--debug-quit','--helper',$cli)
    if ($pass -eq 'first' ) { $arguments+=@('--debug-setup','--offer',$fixture) }
    Run-Private $gui $arguments "gui-$pass"
    $ui=Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    if ($ui.error) { throw "Native UI scenario failed ($pass): $($ui.error); inspect $report" }
    $f=$ui.features
    $o=$f.osint
    if ($o.comparison.mode -ne 'edge' -or $o.comparison.previewCount -ne 2 -or $o.confirmed -ne 'confirmed' -or
        !$o.rejectedHidden -or !$o.rejectedVisible -or $o.unverified -ne 'unverified' -or !$o.visualOnly -or !$o.faceControlTruthful -or
        !$o.hidden -or !$o.restored -or $o.semantic.error -or $o.semantic.resultCount -lt 1 -or !$o.staleQueryIgnored -or $o.pathNodes.Count -lt 2 -or
        $o.expandAll.after -le $o.expandAll.before -or $o.expandAll.pageHasMore -or $o.final.inspectorWidth -ne 360 -or
        @($o.initial.counts | Where-Object unexpandedCount -gt 0).Count -lt 1 -or
        @($o.filenameFilter | Where-Object opacity -eq '0.25').Count -lt 1 -or
        @($o.filenameFilter | Where-Object opacity -eq '1').Count -lt 1 -or
        $o.audioAnalysis.mode -ne 'edge' -or $o.audioAnalysis.timeButtons -lt 2 -or
        @($o.audioAnalysis.evidence | Where-Object type -eq 'audio').Count -lt 1 -or
        $o.timeline.pinned.x -ne $o.pinned.x -or $o.timeline.pinned.y -ne $o.pinned.y -or
        $o.hash -ne (Get-FileHash -LiteralPath $f.image.nodes[0].path).Hash.ToLowerInvariant() -or
        @($o.saved.edges.PSObject.Properties | Where-Object Value -eq 'confirmed').Count -lt 1) {
        throw "Real investigation controls/evidence/local persistence failed ($pass)."
    }
    if ($pass -eq 'restart' -and ($o.initialStatus -ne 'confirmed' -or !$o.initialPin)) { throw 'Review status/pin did not survive restart.' }
    if(!$f.searchPeriod.passed) { throw "Actual ordinary search year rail failed ($pass)." }
    foreach ($phase in 'comparison','timeline','context','search-period','search-period-compact') {
        Copy-Item -LiteralPath (Join-Path $index "capture-$phase.png") -Destination "$testRoot/capture-$pass-$phase.png"
    }
    foreach ($graph in @($f.graph, $f.image)) {
        $stage=$graph.stageBounds; $map=$graph.minimapBounds
        foreach ($card in $graph.cardBounds) {
            if ($card.left -lt $stage.left + 24 -or $card.right -gt $stage.right - 24 -or
                $card.top -lt $stage.top + 24 -or $card.bottom -gt $stage.bottom - 24 -or
                !($card.right + 16 -le $map.left -or $card.bottom + 16 -le $map.top)) {
                throw "Initial graph cards lack perimeter/minimap clearance ($pass)."
            }
        }
    }
    foreach ($phase in 'documents','media') {
        $capture=if ($phase -eq 'documents') { $f.documentsCapture.path } else { $f.mediaCapture.path }
        if ([IO.Path]::GetFullPath($capture) -ne (Join-Path $index "capture-$phase.png")) { throw 'Unexpected native capture path.' }
        $bytes=[IO.File]::ReadAllBytes($capture)
        if ($bytes.Length -lt 24 -or [Convert]::ToHexString($bytes[0..7]) -ne '89504E470D0A1A0A') { throw 'Invalid WebView PNG capture.' }
        Copy-Item -LiteralPath $capture -Destination "$testRoot/capture-$pass-$phase.png"
    }
    if ($f.controls.initialZoom -ne 0.75 -or $f.controls.zoomIn -le 0.75 -or $f.controls.sliderZoom -ne 0.75 -or
        $f.controls.zoomLabel -ne '75%' -or !$f.controls.inspectorRestored -or $f.controls.collapsedWidth -le $f.controls.beforeWidth -or
        ([Math]::Abs($f.controls.minimapCenter.x) + [Math]::Abs($f.controls.minimapCenter.y)) -lt 10 -or
        [Math]::Abs($f.controls.centered.x) -gt 0.01 -or [Math]::Abs($f.controls.centered.y) -gt 0.01 -or
        $f.graph.labels.Count -ne $f.graph.links -or $f.graph.minimapNodes -ne $f.graph.files -or
        @($f.image.thumbnails | Where-Object loaded -eq $true).Count -lt 2 -or
        @($f.image.nodes | Where-Object kind -eq 'video').Count -lt 1) { throw 'Native graph camera/minimap/thumbnails/inspector controls failed.' }
    if ($ui.error -or $ui.savedLanguage -ne 'ru' -or $ui.language -ne 'ru' -or $f.initial.lang -ne 'ru' -or
        $f.english.action -ne 'Find similar' -or $f.russian.action -ne 'Найти похожие' -or
        'Documents' -notin $f.english.groups -or 'Документы' -notin $f.russian.groups -or
        [string]::IsNullOrWhiteSpace($f.english.indexLabel) -or [string]::IsNullOrWhiteSpace($f.russian.indexLabel) -or
        $f.english.indexLabel -match '[А-Яа-яЁё]' -or $f.russian.indexLabel -notmatch '[А-Яа-яЁё]' -or
        $f.english.indexLabel -eq $f.russian.indexLabel -or
        $f.englishAgain.action -ne 'Find similar' -or $f.final.action -ne 'Найти похожие' -or
        $f.english.query -ne $f.russian.query -or $f.english.selected -ne $f.russian.selected -or
        !$f.graph.visible -or $f.graph.error -or $f.graph.preview.tag -ne 'DIV' -or $f.graph.preview.text -notmatch 'UIFEATURE742' -or
        $f.image.error -or !$f.image.preview.loaded -or $f.image.preview.tag -ne 'IMG' -or
        $f.similarFirst.loaded -ne 40 -or $f.similarAll.loaded -lt 47 -or $f.similarAll.loaded -ne $f.similarAll.total -or
        $f.similarAll.error -or @($f.similarAll.paths | Sort-Object -Unique).Count -ne $f.similarAll.loaded -or
        $f.similarAll.seed -in $f.similarAll.paths -or @($f.similarAll.cosine | Where-Object { $_ -lt 0.55 -or $_ -gt 1 }).Count -or
        !$f.fromResult.total -or $f.fromResult.seed -eq $f.fromResult.selected -or $f.back.query -ne 'UIFEATURE742') {
        throw "Actual WebView language/preview/similar-files scenario failed ($pass); inspect $report."
    }
    if ($pass -eq 'first' -and ($ui.setupHistory[-1].language -ne 'ru' -or $ui.setupHistory[-1].startLabel -ne 'Сохранение…')) {
        throw 'Setup did not apply Russian through its real selector before saving folders.'
    }
    foreach ($rect in $f.graph.bounds) {
        if ($rect.height -lt 80 -or $rect.bottom -gt $f.graph.viewport.windowHeight + 1) { throw "Graph inspector is clipped ($pass)." }
    }
    if ($ui.appearance.panelRadius -ne '8px' -or ([Environment]::OSVersion.Version.Build -ge 22000 -and $ui.nativeCornerPreference -ne 2)) {
        throw 'Rounded native/web corner policy is missing.'
    }
    $f.graph.svg | Set-Content -LiteralPath "$testRoot/graph-$pass-ru.svg" -Encoding utf8NoBOM
}
$saved=Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
if ($saved.language -ne 'ru' -or $saved.folders.Count -ne 1 -or $saved.folders[0] -ne $fixture -or !$saved.setUp) {
    throw 'Language persistence damaged setup or folders.'
}
@{result='passed';realModel=$true;userInstallationModified=$false;developmentGui=[bool]$DevelopmentGui;developmentHelper=[bool]$DevelopmentHelper;
    archiveSha256=(Get-FileHash -LiteralPath $Archive).Hash.ToLowerInvariant();
    checks=@('setup Russian selector','RU/EN/RU live DOM','restart language persistence','queries and selected paths unchanged',
        'real graph text preview','real graph image preview','Find similar from graph and result',
        '40 then all similar files via Show more','no duplicate files or seed in neighbors','Back to original query',
        'ordinary search inclusive EXIF year rail before pagination','43 real photographs across pages','empty-query date browsing without encoder','photo/video filters','invalid/empty/reset/slider ranges','search period persistence across restart','stale filtered replies ignored','compact and wide search period controls',
        '360px overlay inspector','real visual/EXIF channel evidence','side-by-side real previews','confirm/reject/unverify','rejected-link visibility',
        'persist reviews and pins across restart','real unexpanded counts','node context menu expand-all/hide/restore','real audio modality pivot and time buttons','shortest expanded path','filename dimming','positive real semantic graph search','stale semantic replies ignored','face control follows real analyzer availability','timeline keeps pinned coordinates','actual SHA-256',
        'bounded inspector layout','75% initial camera','perimeter and minimap card clearance','native WebView PNG captures','actual minimap click and recenter','zoom slider','collapsible inspector','real image and video card thumbnails','cosine labels','rounded native/web corner policy','Unicode/spaces','System32/Windows PATH only')} |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$testRoot/result.json" -Encoding utf8NoBOM
Write-Host "Actual packaged UI refinements passed: $testRoot"
