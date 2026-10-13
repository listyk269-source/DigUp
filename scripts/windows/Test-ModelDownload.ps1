#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$Cli,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [int]$TimeoutSeconds = 900
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $root) { throw 'Use a new output directory; existing model downloads are never removed.' }
New-Item -ItemType Directory -Path $root | Out-Null
$models = Join-Path $root 'models'
function Start-Download([string]$label) {
    $start = [Diagnostics.ProcessStartInfo]::new([IO.Path]::GetFullPath($Cli))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($arg in @('download-model', '--to', $models)) { $start.ArgumentList.Add($arg) }
    $start.Environment['PATH'] = "$env:SystemRoot/System32;$env:SystemRoot"
    # Force the real pinned HTTPS transfer instead of taking a developer's Hugging Face cache.
    $start.Environment['HF_HUB_CACHE'] = Join-Path $root 'empty-cache'
    $process = [Diagnostics.Process]::Start($start)
    @{ process = $process; stdout = $process.StandardOutput.ReadToEndAsync(); stderr = $process.StandardError.ReadToEndAsync(); label = $label }
}
function Save-Download($run) {
    $run.stdout.GetAwaiter().GetResult() | Set-Content "$root/$($run.label).stdout.jsonl" -Encoding utf8NoBOM
    $run.stderr.GetAwaiter().GetResult() | Set-Content "$root/$($run.label).stderr.txt" -Encoding utf8NoBOM
}
$first = Start-Download 'interrupted'
try {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $partial = Join-Path $models 'embeddinggemma-2-Q8_0.gguf.partial'
    do {
        if ($first.process.HasExited) { throw 'Download ended before interruption could be tested.' }
        if ([DateTime]::UtcNow -gt $deadline) { throw 'The real download did not produce a partial file in time.' }
        Start-Sleep -Milliseconds 50
        $bytes = if (Test-Path -LiteralPath $partial) { (Get-Item -LiteralPath $partial).Length } else { 0 }
    } while ($bytes -lt 4MB)
} finally {
    if (!$first.process.HasExited) { $first.process.Kill($true); $first.process.WaitForExit() }
    Save-Download $first
}
$preserved = (Get-Item -LiteralPath $partial).Length
if ($preserved -le 0 -or $preserved -ge 309855456) { throw 'No incomplete text model remained for the resume test.' }
$second = Start-Download 'resumed'
try {
    if (!$second.process.WaitForExit($TimeoutSeconds * 1000)) { throw 'Resumed model download timed out.' }
    if ($second.process.ExitCode -ne 0) { throw "Resumed download failed ($($second.process.ExitCode))." }
} finally {
    if (!$second.process.HasExited) { $second.process.Kill($true); $second.process.WaitForExit() }
    Save-Download $second
}
$expected = @{
    'embeddinggemma-2-Q8_0.gguf' = '2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135'
    'mmproj-embeddinggemma-2-Q8_0.gguf' = 'c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f'
}
foreach ($name in $expected.Keys) {
    if ((Get-FileHash -LiteralPath (Join-Path $models $name)).Hash -ne $expected[$name]) { throw "Wrong model checksum: $name" }
    if (Test-Path -LiteralPath (Join-Path $models "$name.partial")) { throw "Partial remains after success: $name" }
}
@{ result = 'passed'; interruptedBytes = $preserved; realHttps = $true; sha256 = $expected } |
    ConvertTo-Json | Set-Content "$root/result.json" -Encoding utf8NoBOM
Write-Host "Real pinned HTTPS model download resumed successfully from $preserved bytes."
