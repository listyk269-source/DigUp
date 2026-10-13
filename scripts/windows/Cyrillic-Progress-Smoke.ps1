#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][string]$Models,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateRange(30,1800)][int]$TimeoutSeconds = 600
)
. "$PSScriptRoot/Common.ps1"
if (!$IsWindows) { throw 'This regression check requires Windows native sparse-file APIs.' }

function New-LargeSparseFixture {
    param([Parameter(Mandatory)][string]$Path)
    if (!('DigUpWindowsSmoke.SparseFile' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace DigUpWindowsSmoke {
    public static class SparseFile {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
            IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DeviceIoControl(SafeFileHandle file, uint code, IntPtr input,
            uint inputBytes, IntPtr output, uint outputBytes, out uint returned, IntPtr overlapped);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetFilePointerEx(SafeFileHandle file, long distance, IntPtr position, uint method);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetEndOfFile(SafeFileHandle file);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileSizeEx(SafeFileHandle file, out long size);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern uint GetCompressedFileSizeW(string path, out uint high);
        public static ulong Create(string path, long size) {
            // CREATE_NEW never overwrites an existing file. Set sparse before extending;
            // no buffers containing the logical multi-GiB file contents are allocated.
            using (var file = CreateFileW(path, 0x40000000, 7, IntPtr.Zero, 1, 0x80, IntPtr.Zero)) {
                if (file.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                uint returned;
                if (!DeviceIoControl(file, 0x000900C4, IntPtr.Zero, 0, IntPtr.Zero, 0, out returned, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error()); // FSCTL_SET_SPARSE
                if (!SetFilePointerEx(file, size, IntPtr.Zero, 0) || !SetEndOfFile(file))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                long actualSize;
                if (!GetFileSizeEx(file, out actualSize)) throw new Win32Exception(Marshal.GetLastWin32Error());
                if (actualSize != size) throw new IOException("Sparse fixture logical length is incorrect.");
                uint high;
                uint low = GetCompressedFileSizeW(path, out high);
                if (low == UInt32.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
                return ((ulong)high << 32) | low;
            }
        }
    }
}
'@
    }
    $logicalBytes = 3L * 1024 * 1024 * 1024
    $allocatedBytes = [DigUpWindowsSmoke.SparseFile]::Create($Path, $logicalBytes)
    $file = Get-Item -LiteralPath $Path
    if ($file.Length -ne $logicalBytes -or $allocatedBytes -ne 0 -or
        !($file.Attributes -band [IO.FileAttributes]::SparseFile)) {
        throw 'The 3 GiB fixture must have its exact logical size and zero allocated data bytes.'
    }
    return [ordered]@{ name = $file.Name; logicalBytes = $logicalBytes; allocatedBytes = $allocatedBytes; sparse = $true }
}

$testRoot = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $testRoot) { throw 'Use a fresh evidence directory; existing evidence is never overwritten.' }
$archivePath = [IO.Path]::GetFullPath($Archive)
$modelsPath = [IO.Path]::GetFullPath($Models)
# Verify the existing model without starting a downloader or changing its directory.
$modelsExpected = @{
    'embeddinggemma-2-Q8_0.gguf' = '2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135'
    'mmproj-embeddinggemma-2-Q8_0.gguf' = 'c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f'
}
foreach ($model in $modelsExpected.GetEnumerator()) {
    if ((Get-FileHash -LiteralPath (Join-Path $modelsPath $model.Key) -Algorithm SHA256).Hash -ne $model.Value) {
        throw "The existing pinned model failed verification: $($model.Key)"
    }
}
New-Item -ItemType Directory -Path $testRoot | Out-Null
$package = Join-Path $testRoot 'Приложение DigUp café 🦊'
[IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $package)
$gui = Join-Path $package 'DigUp.exe'
$cli = Join-Path $package 'helper/digup.exe'
if (!(Test-Path -LiteralPath $gui) -or !(Test-Path -LiteralPath $cli)) { throw 'The actual portable ZIP is missing its GUI/helper.' }
$asciiRoot = Join-Path $testRoot 'first-ascii-folder'
$cyrillicRoot = Join-Path $testRoot 'Добавленная папка Ё café 🦊'
$index = Join-Path $testRoot 'Отдельный индекс'
$settings = Join-Path $testRoot 'Отдельные настройки.json'
$report = Join-Path $testRoot 'gui-report.json'
New-Item -ItemType Directory -Path $asciiRoot, $cyrillicRoot | Out-Null
'The original folder contains an apartment lease for a tenant and two cats. ASCIIINITIAL742.' |
    Set-Content -LiteralPath (Join-Path $asciiRoot 'first-lease.txt') -Encoding utf8NoBOM
'The compiler retry function uses exponential backoff after network errors.' |
    Set-Content -LiteralPath (Join-Path $asciiRoot 'first-software.txt') -Encoding utf8NoBOM
$targetName = 'Космический огород Ё.txt'
'The orbital research station grows fresh tomatoes and vegetables for astronauts in its greenhouse. It recycles water to produce food in space. ORBITCYRILLIC853.' |
    Set-Content -LiteralPath (Join-Path $cyrillicRoot $targetName) -Encoding utf8NoBOM
for ($number = 1; $number -le 10; $number++) {
    "Coastal travel itinerary number $number. A ferry sails to a seaside hotel near the beach and lighthouse. Guests reserve a room for a summer vacation." |
        Set-Content -LiteralPath (Join-Path $cyrillicRoot "Заметка с пробелами $number.md") -Encoding utf8NoBOM
}
'Записка на русском языке: маяк помогает кораблям найти дорогу в гавань. КИРИЛЛИЦА953.' |
    Set-Content -LiteralPath (Join-Path $cyrillicRoot 'Русский текст.md') -Encoding utf8NoBOM
# This is a filename-classification fixture, not a camera RAW sample or decoder test.
# The portable extractor rejects the unsupported CR2 type before decoding its bytes.
$rawFixture = [ordered]@{ name = 'Неподдерживаемый RAW.CR2'; syntheticFilenameOnly = $true; rawDecoderCoverage = $false }
'Synthetic unsupported CR2 filename fixture; these bytes are not a camera RAW image.' |
    Set-Content -LiteralPath (Join-Path $cyrillicRoot $rawFixture.name) -Encoding utf8NoBOM
$rawFixture | ConvertTo-Json | Set-Content -LiteralPath "$testRoot/raw-fixture.json" -Encoding utf8NoBOM
# The pre-fix Windows crawler crashed while reading metadata even for unsupported
# large files. This must be present during the real setup estimate, before indexing.
$sparseFixture = New-LargeSparseFixture -Path (Join-Path $cyrillicRoot 'Большой неподдерживаемый файл.bin')
$sparseFixture | ConvertTo-Json | Set-Content -LiteralPath "$testRoot/sparse-fixture.json" -Encoding utf8NoBOM
$ownedProcesses = [Collections.Generic.List[object]]::new()

function Invoke-IsolatedSmoke {
    param([string]$Program, [string[]]$Arguments, [string]$Label, [string]$InputText)
    $start = [Diagnostics.ProcessStartInfo]::new($Program)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    if ($InputText) {
        $start.RedirectStandardInput = $true
        $start.StandardInputEncoding = [Text.Encoding]::UTF8
    }
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    foreach ($variable in 'DIGUP_WORKER_DIR','DIGUP_BACKENDS','DIGUP_FFMPEG','GGML_BACKEND_PATH','DIGUP_DEVICE','DIGUP_CPU_ONLY') {
        $start.Environment.Remove($variable) | Out-Null
    }
    $start.Environment['PATH'] = "$env:SystemRoot/System32;$env:SystemRoot"
    $start.Environment['DIGUP_MODELS'] = $modelsPath
    $start.Environment['DIGUP_CPU_ONLY'] = '1'
    # Microsoft-supported environment override isolates WebView2's browser profile.
    # --debug-isolated also gives the GUI private logs/data and disables global UI hooks.
    $start.Environment['WEBVIEW2_USER_DATA_FOLDER'] = Join-Path $index '.webview'
    $process = [Diagnostics.Process]::Start($start)
    $evidence = [ordered]@{ label = $Label; pid = $process.Id; startedUtc = [DateTime]::UtcNow.ToString('o') }
    $ownedProcesses.Add($evidence)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    try {
        if ($InputText) { $process.StandardInput.WriteLine($InputText); $process.StandardInput.Close() }
        if (!$process.WaitForExit($TimeoutSeconds * 1000)) { throw "$Label timed out." }
        if (!$stdout.Wait(5000) -or !$stderr.Wait(5000)) { throw "$Label left output handles open." }
        $text = $stdout.GetAwaiter().GetResult()
        $text | Set-Content -LiteralPath "$testRoot/$Label.stdout.txt" -Encoding utf8NoBOM
        $stderr.GetAwaiter().GetResult() | Set-Content -LiteralPath "$testRoot/$Label.stderr.txt" -Encoding utf8NoBOM
        $evidence.exitCode = $process.ExitCode
        if ($process.ExitCode -ne 0) { throw "$Label failed with exit $($process.ExitCode)." }
        return $text
    } finally {
        # Only the exact child process created above may be stopped. Never enumerate
        # or terminate the person's running DigUp installation by process name.
        if (!$process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
        $evidence.finishedUtc = [DateTime]::UtcNow.ToString('o')
        $process.Dispose()
        $ownedProcesses.ToArray() | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$testRoot/owned-processes.json" -Encoding utf8NoBOM
    }
}

$result = [ordered]@{ result = 'running'; realModel = $true; cpuOnly = $true; initialIndexCreatedBy = 'GUI only'
    archiveSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    path = 'System32 and Windows only'; isolatedSettingsIndexWebViewAndLogs = $true
    userInstallationModified = $false; nativeFolderDialogAutomated = $false; sparseFixture = $sparseFixture
    rawFixture = $rawFixture }
try {
    # No CLI indexing: the real setup creates the first index, then opens setup again
    # and selects the Cyrillic root while the same GUI/search worker is running.
    Invoke-IsolatedSmoke $gui @('--index', $index, '--models', $modelsPath, '--settings', $settings,
        '--debug-isolated', '--debug-setup', '--offer', $asciiRoot, '--debug-reconfigure-folder', $cyrillicRoot,
        '--debug-query', 'ORBITCYRILLIC853', '--debug-report', $report, '--debug-quit') 'gui-reconfigure' | Out-Null
    $ui = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    if ($ui.phase -ne 'meaning' -or !(($ui.groups.rows | ForEach-Object { $_ }) -contains $targetName)) {
        throw 'The reconfigured GUI did not find the Cyrillic-root document with semantic search ready.'
    }
    $saved = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
    if (!$saved.setUp -or @($saved.folders).Count -ne 2 -or @($saved.codeRoots).Count -ne 0 -or
        $saved.folders -notcontains $asciiRoot -or $saved.folders -notcontains $cyrillicRoot) {
        throw 'The real setup did not persist both chosen roots.'
    }
    $setupHistory = @($ui.setupHistory)
    if ($setupHistory.Count -ne 2 -or $setupHistory[0].reconfigure -or !$setupHistory[1].reconfigure) {
        throw 'The same GUI process did not complete both real setup forms.'
    }
    foreach ($check in @(@{step=0;path=$asciiRoot;documents=2;images=0;candidates=2},
                        @{step=1;path=$cyrillicRoot;documents=12;images=1;candidates=13})) {
        $rows = @($setupHistory[$check.step].folders | Where-Object path -eq $check.path)
        if ($rows.Count -ne 1 -or !$rows[0].checked -or !$rows[0].estimate.readable -or
            $rows[0].estimate.counts_only -ne $true -or
            $rows[0].estimate.files.doc -ne $check.documents -or !$rows[0].counts -or
            $rows[0].counts -match 'Counting|read folder|Nothing DigUp') {
            throw 'The real setup did not select the expected synthetic folder using counts-only estimation.'
        }
        $images = $rows[0].estimate.files.PSObject.Properties['image']
        $imageCount = if ($images) { [int]$images.Value } else { 0 }
        $candidateCount = 0
        foreach ($kind in $rows[0].estimate.files.PSObject.Properties) { $candidateCount += [int]$kind.Value }
        if ($imageCount -ne $check.images -or $candidateCount -ne $check.candidates) {
            throw 'Counts-only estimation did not include the synthetic RAW image candidate exactly once.'
        }
    }
    if (!$ui.indexing.panelReopened -or $ui.indexing.panelLifecycle -ne 'reloadedWebView') {
        throw 'The smoke did not reload its own WebView document and replay the final progress snapshot to its new listener.'
    }
    $history = @($ui.indexing.engineHistory)
    if (@($history | Where-Object stage -eq 'scanning').Count -lt 2 -or
        !@($history | Where-Object { $_.stage -eq 'indexing' -and $_.unit -eq 'files' -and $_.done -gt 0 -and $_.total -ge $_.done }).Count -or
        $ui.indexing.current.stage -ne 'idle' -or $ui.indexing.current.searchable -ne 14 -or
        $ui.indexing.current.pending -ne 0 -or $ui.indexing.current.failed -ne 1 -or
        $ui.indexing.current.unsupported_raw -ne 1) {
        throw 'Real scan/file/completion progress did not cover both GUI indexing passes.'
    }
    if (!@($history | Where-Object { $_.pending -gt 0 }).Count -or
        !@($history | Where-Object { $_.stage -eq 'indexing' -and $_.failed -eq 1 -and $_.unsupported_raw -eq 1 }).Count) {
        throw 'The running GUI did not receive whole-queue counts and the specific RAW failure before completion.'
    }
    $firstScan = @($history | Where-Object stage -eq 'scanning' | Select-Object -First 1)
    $firstCompleted = @($history | Where-Object { $_.stage -eq 'indexing' -and $_.done -gt 0 } | Select-Object -First 1)
    if ($firstScan.Count -ne 1 -or $firstCompleted.Count -ne 1 -or
        $firstScan[0].revision -ge $firstCompleted[0].revision -or $null -ne $firstScan[0].total) {
        throw 'The GUI did not receive an early scan state with an honestly unknown total.'
    }
    if (!$ui.indexing.visible -or !$ui.indexing.title -or !$ui.indexing.detail) {
        throw 'The reloaded WebView document did not render the current indexing summary.'
    }
    if ($ui.indexing.count -notmatch '\b14 files searchable\b' -or $ui.indexing.count -notmatch '\b0 remaining\b' -or
        $ui.indexing.detail -notmatch '\b1 RAW files? not supported\b' -or
        $ui.indexing.detail -match "files? couldn't be indexed") {
        throw 'The final GUI did not render overall remaining work and the specific RAW reason without counting it twice.'
    }
    if (!@($ui.indexing.history | Where-Object {
        $_.stage -eq 'idle' -and $_.revision -eq $ui.indexing.current.revision -and
        $_.searchable -eq 14 -and $_.pending -eq 0 -and $_.failed -eq 1 -and $_.unsupported_raw -eq 1
    }).Count) {
        throw 'The reloaded WebView listener did not receive the final whole-queue and RAW-failure snapshot.'
    }
    foreach ($snapshot in $history) {
        if ($null -ne $snapshot.total -and $null -ne $snapshot.done -and $snapshot.done -gt $snapshot.total) {
            throw 'The progress report claimed more completed work than its actual phase total.'
        }
    }
    $status = Invoke-IsolatedSmoke $cli @('status', '--index', $index) 'status'
    if ($status -notmatch 'vectors: ([1-9][0-9, ]*) in ([1-9][0-9, ]*) segments') { throw 'GUI stored no real embeddings.' }
    $meaning = @(Invoke-IsolatedSmoke $cli @('search', 'fresh food grown in orbit', '--index', $index, '--json', '--zgate', '-100') 'meaning' | ConvertFrom-Json)
    if (!$meaning.Count -or [IO.Path]::GetFileName($meaning[0].path) -ne $targetName -or !$meaning[0].PSObject.Properties['cosine']) {
        throw 'Real semantic inference did not rank the Cyrillic-path document first.'
    }
    $words = Invoke-IsolatedSmoke $cli @('search-service', $cyrillicRoot, '--index', $index) 'words' '{"id":1,"op":"search","q":"КИРИЛЛИЦА953","meaning":false}'
    $reply = @($words -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json } |
        Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 1 })
    if ($reply.Count -ne 1 -or $reply[0].meaning -or !(@($reply[0].hits) | Where-Object { [IO.Path]::GetFileName($_.path) -eq 'Русский текст.md' -and $_.keyword_rank })) {
        throw 'FTS did not preserve Cyrillic document text.'
    }
    $result.result = 'passed'
    $result.searchable = $ui.indexing.current.searchable
    $result.pending = $ui.indexing.current.pending
    $result.failed = $ui.indexing.current.failed
    $result.unsupported_raw = $ui.indexing.current.unsupported_raw
    $result.countsOnlyEstimates = $true
    $result.rawReasonDisplayed = $true
    $result.checks = @('fresh portable extraction', 'GUI-only initial indexing', 'ASCII to Cyrillic live folder reconfiguration',
        '3 GiB unsupported sparse file survives real GUI folder estimate without data allocation',
        'counts-only GUI estimates and checkbox choices', 'synthetic CR2 filename rejection with specific RAW reason (not decoder coverage)',
        'real scan/file/completion and whole-queue progress', 'reloaded WebView document snapshot replay including RAW failure',
        'persisted folder choices', 'actual CPU embeddings', 'Cyrillic FTS')
} catch {
    $result.result = 'failed'
    $result.error = $_.Exception.Message
    throw
} finally {
    $result.finishedUtc = [DateTime]::UtcNow.ToString('o')
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$testRoot/result.json" -Encoding utf8NoBOM
}
Write-Host "Isolated real Cyrillic/progress smoke passed: $testRoot"
