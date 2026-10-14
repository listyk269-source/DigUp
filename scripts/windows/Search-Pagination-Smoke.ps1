#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][string]$Models,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateRange(30,1800)][int]$TimeoutSeconds = 600
)
. "$PSScriptRoot/Common.ps1"
$testRoot = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $testRoot) { throw 'Use a fresh evidence directory.' }
$modelsPath = [IO.Path]::GetFullPath($Models)
$expectedModels = @{
    'embeddinggemma-2-Q8_0.gguf' = '2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135'
    'mmproj-embeddinggemma-2-Q8_0.gguf' = 'c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f'
}
foreach ($model in $expectedModels.GetEnumerator()) {
    if ((Get-FileHash -LiteralPath (Join-Path $modelsPath $model.Key)).Hash -ne $model.Value) {
        throw "Model verification failed: $($model.Key)"
    }
}
New-Item -ItemType Directory -Path $testRoot | Out-Null
$package = Join-Path $testRoot 'Приложение café 🦊'
[IO.Compression.ZipFile]::ExtractToDirectory([IO.Path]::GetFullPath($Archive), $package)
$fixture = Join-Path $testRoot 'Документы с пробелами Ё'
$index = Join-Path $testRoot 'Private index'
$settings = Join-Path $testRoot 'settings.json'
New-Item -ItemType Directory -Path $fixture | Out-Null
for ($number = 1; $number -le 145; $number++) {
    "PAGINATION742. Coastal lighthouse log number $number. Fishing boats follow the harbor beacon through fog." |
        Set-Content -LiteralPath (Join-Path $fixture ("Заметка café {0:D3}.txt" -f $number)) -Encoding utf8NoBOM
}
# Filename classification only, not a RAW decoder test.
'Unsupported camera RAW fixture' | Set-Content -LiteralPath (Join-Path $fixture 'Unsupported.CR2') -Encoding utf8NoBOM
'Corrupt JPEG fixture' | Set-Content -LiteralPath (Join-Path $fixture 'Broken.jpg') -Encoding utf8NoBOM
@{setUp=$true; folders=@($fixture); codeRoots=@(); skipped=@(); skipTypes=@(); device='cpu'} |
    ConvertTo-Json | Set-Content -LiteralPath $settings -Encoding utf8NoBOM
function Invoke-PrivateProcess {
    param([string]$Program, [string[]]$Arguments, [string]$Label)
    $start = [Diagnostics.ProcessStartInfo]::new($Program)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    foreach ($variable in 'DIGUP_WORKER_DIR','DIGUP_BACKENDS','DIGUP_FFMPEG','GGML_BACKEND_PATH','DIGUP_DEVICE') {
        $start.Environment.Remove($variable) | Out-Null
    }
    $start.Environment['PATH'] = "$env:SystemRoot/System32;$env:SystemRoot"
    $start.Environment['DIGUP_MODELS'] = $modelsPath
    $start.Environment['DIGUP_CPU_ONLY'] = '1'
    $start.Environment['WEBVIEW2_USER_DATA_FOLDER'] = Join-Path $index '.webview'
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutSeconds * 1000)) { throw "$Label timed out." }
        if (!$stdout.Wait(5000) -or !$stderr.Wait(5000)) { throw "$Label left output handles open." }
        $stdout.GetAwaiter().GetResult() | Set-Content -LiteralPath "$testRoot/$Label.stdout.txt" -Encoding utf8NoBOM
        $stderr.GetAwaiter().GetResult() | Set-Content -LiteralPath "$testRoot/$Label.stderr.txt" -Encoding utf8NoBOM
        if ($process.ExitCode -ne 0) { throw "$Label failed: exit $($process.ExitCode)." }
    } finally {
        # Never stop the user's installation by process name.
        if (!$process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
        $process.Dispose()
    }
}
$cli = Join-Path $package 'helper/digup.exe'
$gui = Join-Path $package 'DigUp.exe'
Invoke-PrivateProcess $cli @('index',$fixture,'--index',$index) 'index'
foreach ($pass in 'first','restart') {
    $report = Join-Path $testRoot "gui-$pass.json"
    Invoke-PrivateProcess $gui @('--index',$index,'--models',$modelsPath,'--settings',$settings,
        '--debug-isolated','--debug-load-all','--debug-query','PAGINATION742','--debug-report',$report,'--debug-quit') "gui-$pass"
    $ui = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    $pages = @($ui.pagination.pages)
    if ($ui.error -or $ui.pagination.error -or $ui.phase -ne 'meaning' -or $ui.pagination.loaded -ne 145 -or
        $ui.pagination.total -ne 145 -or $ui.pagination.hasMore -or $ui.pagination.buttonVisible -or
        @($ui.pagination.paths | Sort-Object -Unique).Count -ne 145 -or $pages.Count -ne 4 -or
        ($pages.loaded -join ',') -ne '40,80,120,145' -or $pages[0].renderedRows -le 6 -or $pages[-1].renderedRows -ne 145) {
        throw "Real GUI pagination did not reach every fixture without duplicates ($pass)."
    }
    $files = @($ui.overview.data.indexes | Where-Object name -eq 'files')
    if (!$ui.overview.visible -or $files.Count -ne 1 -or $files[0].by_kind_and_state.doc.done -ne 145 -or
        $files[0].by_kind_and_state.image.failed -ne 2 -or $files[0].unsupported_raw -ne 1 -or
        $files[0].vectors -lt 145 -or $files[0].bytes -le 0 -or @($files[0].recent).Count -ne 6 -or
        $ui.overview.totals -notmatch 'Searchable files145' -or $ui.overview.totals -notmatch 'Other failed files1') {
        throw "Real GUI statistics disagree with the actual fixture index ($pass)."
    }
}
@{result='passed'; realModel=$true; cpuOnly=$true; userInstallationModified=$false;
    archiveSha256=(Get-FileHash -LiteralPath $Archive).Hash.ToLowerInvariant();
    checks=@('145 real indexed documents','40/80/120/145 via Show more DOM clicks','no six-file group cap',
        'all unique results','actual WebView overview','RAW and other failure counts','restart preserves index and pages',
        'Unicode/spaces','System32/Windows PATH only')} | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath "$testRoot/result.json" -Encoding utf8NoBOM
Write-Host "Actual packaged GUI pagination and index overview passed: $testRoot"
