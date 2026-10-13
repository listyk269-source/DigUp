#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][string]$Models,
    [string]$OutputDirectory,
    [int]$TimeoutSeconds = 600
)
. "$PSScriptRoot/Common.ps1"
if (!$OutputDirectory) { $OutputDirectory = "$script:Repo/build.noindex/windows/portable-smoke-$([Guid]::NewGuid().ToString('N'))" }
$testRoot = [IO.Path]::GetFullPath($OutputDirectory)
$package = Join-Path $testRoot 'Распаковано DigUp café 🦊'
if (Test-Path -LiteralPath $package) { throw 'Use a fresh output directory for the portable extraction check.' }
if (Get-Process 'digup-shell', 'DigUp' -ErrorAction SilentlyContinue) { throw 'Quit DigUp before the portable GUI smoke.' }
New-Item -ItemType Directory -Force $testRoot | Out-Null
[IO.Compression.ZipFile]::ExtractToDirectory([IO.Path]::GetFullPath($Archive), $package)
$fixture = Join-Path $testRoot 'Документы'
New-Item -ItemType Directory -Force $fixture | Out-Null
$name = 'Морской маяк café.txt'
'The coastal lighthouse guides fishing boats safely through the fog. HARBORPORTABLE742 is its beacon log identifier.' |
    Set-Content -LiteralPath (Join-Path $fixture $name) -Encoding utf8NoBOM
$index = Join-Path $testRoot 'index'
$settings = Join-Path $testRoot 'settings.json'
$report = Join-Path $testRoot 'gui-report.json'

function Invoke-PortableProcess {
    param([string]$Program, [string[]]$Arguments, [string]$Label)
    $start = [Diagnostics.ProcessStartInfo]::new($Program)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($arg in $Arguments) { $start.ArgumentList.Add($arg) }
    $start.Environment['PATH'] = "$env:SystemRoot/System32;$env:SystemRoot"
    $start.Environment['DIGUP_MODELS'] = [IO.Path]::GetFullPath($Models)
    $start.Environment['DIGUP_CPU_ONLY'] = '1'
    foreach ($variable in @('DIGUP_WORKER_DIR', 'DIGUP_BACKENDS', 'DIGUP_FFMPEG')) { $start.Environment.Remove($variable) | Out-Null }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutSeconds * 1000)) { $process.Kill($true); throw "$Label timed out." }
        if (!$stdout.Wait(5000) -or !$stderr.Wait(5000)) { throw "$Label left output handles open." }
        $text = $stdout.GetAwaiter().GetResult()
        $text | Set-Content -LiteralPath "$testRoot/$Label.stdout.txt" -Encoding utf8NoBOM
        $stderr.GetAwaiter().GetResult() | Set-Content -LiteralPath "$testRoot/$Label.stderr.txt" -Encoding utf8NoBOM
        if ($process.ExitCode -ne 0) { throw "$Label failed (exit $($process.ExitCode)); inspect $testRoot." }
        return $text
    } finally {
        if (!$process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}

$cli = Join-Path $package 'helper/digup.exe'
$gui = Join-Path $package 'DigUp.exe'
Invoke-PortableProcess $cli @('--help') 'cli-help' | Out-Null
Invoke-PortableProcess $cli @('download-model', '--to', $Models) 'verify-model' | Out-Null
Invoke-PortableProcess $cli @('index', $fixture, '--index', $index) 'index' | Out-Null
$status = Invoke-PortableProcess $cli @('status', '--index', $index) 'status'
if ($status -notmatch 'vectors: ([1-9][0-9, ]*) in ([1-9][0-9, ]*) segments') { throw 'The extracted portable CLI stored no actual embeddings.' }
Invoke-PortableProcess $gui @('--index', $index, '--models', $Models, '--settings', $settings,
    '--debug-setup', '--offer', $fixture, '--debug-query', 'HARBORPORTABLE742', '--debug-report', $report, '--debug-quit') 'gui' | Out-Null
if (!(Test-Path -LiteralPath $report)) { throw 'The extracted portable GUI produced no real WebView result.' }
$ui = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
if ($ui.phase -ne 'meaning' -or !(($ui.groups.rows | ForEach-Object { $_ }) -contains $name)) {
    throw 'The extracted portable GUI did not display the indexed fixture with semantic search ready.'
}
$saved = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
if (!$saved.setUp -or $saved.folders -notcontains $fixture) { throw 'Portable setup did not persist the chosen folder.' }
@{
    result = 'passed'; realModel = $true; cpuOnly = $true; path = 'System32 and Windows only'
    archiveSha256 = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
    checks = @('actual release ZIP extraction', 'Unicode application directory', 'CLI', 'CPU embeddings', 'GUI WebView setup and search')
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$testRoot/result.json" -Encoding utf8NoBOM
Write-Host "Extracted portable CLI/GUI smoke passed. Evidence: $testRoot"
