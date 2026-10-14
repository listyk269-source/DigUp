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
$fixture = Join-Path $testRoot 'Документы для графа Ё'
$outside = Join-Path $testRoot 'Excluded folder'
$index = Join-Path $testRoot 'Private index'
$settings = Join-Path $testRoot 'settings.json'
New-Item -ItemType Directory -Path $fixture,$outside | Out-Null
for ($number = 1; $number -le 24; $number++) {
    "GRAPH742. Coastal lighthouse log number $number. Fishing boats follow the harbor beacon through fog." |
        Set-Content -LiteralPath (Join-Path $fixture ("Заметка café {0:D3}.txt" -f $number)) -Encoding utf8NoBOM
}
'GRAPH742. Coastal lighthouse log. Fishing boats follow the harbor beacon through fog.' |
    Set-Content -LiteralPath (Join-Path $outside 'Excluded.txt') -Encoding utf8NoBOM
@{setUp=$true; folders=@($fixture); codeRoots=@(); skipped=@(); skipTypes=@(); device='cpu'} |
    ConvertTo-Json | Set-Content -LiteralPath $settings -Encoding utf8NoBOM
function Private-StartInfo([string]$Program, [string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($Program)
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.Encoding]::UTF8; $start.StandardErrorEncoding=[Text.Encoding]::UTF8
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
$cli=Join-Path $package 'helper/digup.exe'; $gui=Join-Path $package 'DigUp.exe'
Run-Private $cli @('index',$fixture,$outside,'--index',$index) 'index'
foreach ($pass in 'first','restart') {
    $report=Join-Path $testRoot "gui-$pass.json"
    Run-Private $gui @('--index',$index,'--models',$modelsPath,'--settings',$settings,'--debug-isolated',
        '--debug-graph','--debug-query','GRAPH742','--debug-report',$report,'--debug-quit') "gui-$pass"
    $ui=Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    $g=$ui.graph
    if ($ui.error -or $g.error -or !$g.visible -or $g.loading -or $g.first.files -ne 7 -or $g.first.links -ne 6 -or
        $g.trace.Count -ne 2 -or $g.drawnNodes -ne $g.files -or $g.drawnLinks -ne $g.links -or
        $g.files -gt 13 -or $g.links -le $g.first.links -or @($g.nodes.path | Sort-Object -Unique).Count -ne $g.files -or
        @($g.nodes | Where-Object path -Match 'Excluded.txt').Count -or
        @($g.edges | Where-Object { $_.cosine -lt 0.55 -or $_.cosine -gt 1 }).Count) {
        throw "Actual WebView graph failed to expand real selected-folder vectors without duplicates ($pass)."
    }
    $g.first.svg | Set-Content -LiteralPath "$testRoot/graph-$pass-initial.svg" -Encoding utf8NoBOM
    $g.svg | Set-Content -LiteralPath "$testRoot/graph-$pass-expanded.svg" -Encoding utf8NoBOM
}
# Exercise the same real vector index while explicitly pointing at a nonexistent model directory.
$start=Private-StartInfo $cli @('search-service',$fixture,'--restrict-roots','--index',$index)
$start.Environment['DIGUP_MODELS']=Join-Path $testRoot 'No model available'
$process=[Diagnostics.Process]::Start($start); $stderr=$process.StandardError.ReadToEndAsync()
$script:graphRequestId=0
function Ask-Graph([hashtable]$Request) {
    $script:graphRequestId++; $Request['id']=$script:graphRequestId
    $process.StandardInput.WriteLine(($Request | ConvertTo-Json -Compress)); $process.StandardInput.Flush()
    do {
        $pending=$process.StandardOutput.ReadLineAsync()
        if (!$pending.Wait(30000) -or !$pending.Result) { throw 'Graph protocol timed out or exited.' }
        $reply=$pending.Result | ConvertFrom-Json
    } while (!$reply.PSObject.Properties['id'] -or $reply.id -ne $script:graphRequestId)
    return $reply
}
try {
    $path=$ui.graph.first.nodes[0].path
    $before=Ask-Graph @{op='search_page';q='GRAPH742';meaning=$false;limit=6}
    $first=Ask-Graph @{op='related_files';path=$path;limit=6;minimum_cosine=0.55}
    $next=Ask-Graph @{op='related_files';path=$path;offset=6;limit=6;minimum_cosine=0.55}
    $searchPage=Ask-Graph @{op='search_page';cursor=$before.cursor;offset=6;limit=6}
    $status=Ask-Graph @{op='status'}
    if (!$first.ok -or !$next.ok -or $first.total -ne 23 -or $first.hits.Count -ne 6 -or $next.hits.Count -ne 6 -or
        @(@($first.hits.path)+@($next.hits.path) | Sort-Object -Unique).Count -ne 12 -or $status.encoder -ne 'stopped' -or
        $searchPage.hits.Count -ne 6) { throw 'Stored-vector graph/model independence or original search cursor failed.' }
    $noFolders=Ask-Graph @{op='folders';roots=@()}
    $denied=Ask-Graph @{op='related_files';path=$path}
    if (!$noFolders.ok -or $denied.ok) { throw 'Removed folder remained accessible through the graph.' }
    @{first=$first;next=$next;status=$status;denied=$denied} | ConvertTo-Json -Depth 12 |
        Set-Content -LiteralPath "$testRoot/model-free-protocol.json" -Encoding utf8NoBOM
    $process.StandardInput.Close()
    if (!$process.WaitForExit(15000) -or $process.ExitCode) { throw 'Graph helper did not exit normally.' }
} finally {
    if (!$process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
    if ($stderr.Wait(5000)) { $stderr.Result | Set-Content -LiteralPath "$testRoot/model-free.stderr.txt" -Encoding utf8NoBOM }
    $process.Dispose()
}
@{result='passed';realModel=$true;storedVectorGraph=$true;requiresModelForGraph=$false;userInstallationModified=$false;
    archiveSha256=(Get-FileHash -LiteralPath $Archive).Hash.ToLowerInvariant();
    checks=@('real WebView DOM graph click','neighbor expansion','cosine links and unique files','selected-folder exclusion',
        'restart','Unicode/spaces','neighbor pagination','graph with no model present','search cursor survives graph',
        'removed folders denied','PATH only System32/Windows')} | ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath "$testRoot/result.json" -Encoding utf8NoBOM
Write-Host "Actual packaged GUI and model-free stored-vector graph passed: $testRoot"
