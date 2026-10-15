#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][string]$Models,
    [Parameter(Mandatory)][string]$OutputDirectory
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
        if (!$process.WaitForExit(300000)) { throw "$Label exceeded 300 seconds." }
        if (!$stdout.Wait(5000) -or !$stderr.Wait(5000)) { throw "$Label left output handles open." }
        $stdout.Result | Set-Content -LiteralPath "$testRoot/$Label.stdout.txt" -Encoding utf8NoBOM
        $stderr.Result | Set-Content -LiteralPath "$testRoot/$Label.stderr.txt" -Encoding utf8NoBOM
        if ($process.ExitCode) { throw "$Label failed with exit $($process.ExitCode)." }
    } finally { if (!$process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }; $process.Dispose() }
}

$gui=Join-Path $package 'DigUp.exe'
foreach ($pass in 'first','restart') {
    $report=Join-Path $testRoot "gui-$pass.json"
    $arguments=@('--index',$index,'--models',$modelsPath,'--settings',$settings,'--debug-isolated',
        '--debug-ui-features','--debug-query','UIFEATURE742','--debug-report',$report,'--debug-quit')
    if ($pass -eq 'first') { $arguments+=@('--debug-setup','--offer',$fixture) }
    Run-Private $gui $arguments "gui-$pass"
    $ui=Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    $f=$ui.features
    if ($ui.error -or $ui.savedLanguage -ne 'ru' -or $ui.language -ne 'ru' -or $f.initial.lang -ne 'ru' -or
        $f.english.action -ne 'Find similar' -or $f.russian.action -ne 'Найти похожие' -or
        'Documents' -notin $f.english.groups -or 'Документы' -notin $f.russian.groups -or
        $f.english.indexLabel -ne 'Index' -or $f.russian.indexLabel -ne 'Индекс' -or
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
@{result='passed';realModel=$true;userInstallationModified=$false;
    archiveSha256=(Get-FileHash -LiteralPath $Archive).Hash.ToLowerInvariant();
    checks=@('setup Russian selector','RU/EN/RU live DOM','restart language persistence','queries and selected paths unchanged',
        'real graph text preview','real graph image preview','Find similar from graph and result',
        '40 then all similar files via Show more','no duplicate files or seed in neighbors','Back to original query',
        'bounded inspector layout','rounded native/web corner policy','Unicode/spaces','System32/Windows PATH only')} |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$testRoot/result.json" -Encoding utf8NoBOM
Write-Host "Actual packaged UI refinements passed: $testRoot"
