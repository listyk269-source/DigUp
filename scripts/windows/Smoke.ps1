#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$Installer,
    [Parameter(Mandatory)][string]$Models,
    [int]$TimeoutSeconds = 600,
    [ValidateSet('cpu', 'gpu')][string]$Device = 'cpu',
    [string]$OutputDirectory
)
. "$PSScriptRoot/Common.ps1"
if (!$OutputDirectory) { $OutputDirectory = "$script:Repo/build.noindex/windows/smoke-$([Guid]::NewGuid().ToString('N'))" }
if ((Test-Path -LiteralPath $OutputDirectory) -and (Get-ChildItem -LiteralPath $OutputDirectory -Force | Select-Object -First 1)) {
    throw 'Smoke evidence requires a new or empty output directory; previous evidence will not be overwritten.'
}
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$testRoot = [IO.Path]::GetFullPath($OutputDirectory)
$install = Join-Path $testRoot 'Installed DigUp'
# Silent NSIS upgrades reuse registry metadata. Never hijack a person's real install.
$existing = @(Get-ItemProperty 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Uninstall/*' -ErrorAction SilentlyContinue |
    Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -eq 'DigUp' })
if ($existing.Count) { throw 'Run installer smoke in a disposable profile with no existing DigUp installation.' }
if (Get-Process 'digup-shell', 'DigUp' -ErrorAction SilentlyContinue) { throw 'Quit the existing DigUp process before installer smoke.' }
$fixture = Join-Path $testRoot 'Документы Unicode café 🦊'
$index = Join-Path $testRoot 'index'
New-Item -ItemType Directory -Force $fixture | Out-Null
$name = 'Космический сад café.txt'
$sample = Join-Path $fixture $name
'The botanical research station grows tomatoes and vegetables on a space station. Its greenhouse recycles water for astronauts. Unique code ORBITGREEN742.' |
    Set-Content -LiteralPath $sample -Encoding utf8NoBOM
'The apartment lease permits two cats. Rent is paid on the first day of each month and a security deposit covers damage.' |
    Set-Content -LiteralPath (Join-Path $fixture 'lease.txt') -Encoding utf8NoBOM
'Our summer vacation itinerary includes a sandy beach, a ferry crossing, and a seaside hotel reservation.' |
    Set-Content -LiteralPath (Join-Path $fixture 'travel.txt') -Encoding utf8NoBOM
'The compiler reports a syntax error. The retry function waits with exponential backoff after an HTTP timeout.' |
    Set-Content -LiteralPath (Join-Path $fixture 'software.txt') -Encoding utf8NoBOM

function Set-SmokeEnvironment {
    param([Diagnostics.ProcessStartInfo]$Start, [switch]$GuiProcess)
    $Start.Environment['PATH'] = "$env:SystemRoot/System32;$env:SystemRoot"
    $Start.Environment['DIGUP_MODELS'] = [IO.Path]::GetFullPath($Models)
    foreach ($variable in @('DIGUP_WORKER_DIR', 'DIGUP_BACKENDS', 'DIGUP_FFMPEG', 'GGML_BACKEND_PATH', 'DIGUP_DEVICE', 'DIGUP_CPU_ONLY')) {
        $Start.Environment.Remove($variable) | Out-Null
    }
    if ($Device -eq 'cpu') { $Start.Environment['DIGUP_CPU_ONLY'] = '1' }
    elseif (!$GuiProcess) { $Start.Environment['DIGUP_DEVICE'] = $Device }
    # GPU GUI runs must obtain their mode only from the real setup form and persisted settings.
}

function Assert-WorkerDevice {
    param([string]$LogName, [string]$EvidenceName)
    $path = Join-Path $index $LogName
    if (!(Test-Path -LiteralPath $path)) { throw "The actual GUI did not produce $LogName." }
    $log = Get-Content -LiteralPath $path -Raw
    $selected = if ($Device -eq 'gpu') { 'Vulkan[0-9]+' } else { 'CPU' }
    if ($log -notmatch "ready in .*device $selected\)") { throw "$LogName did not confirm a ready $Device worker." }
    if ($Device -eq 'gpu' -and $log -notmatch 'offloaded [1-9][0-9]*/[1-9][0-9]* layers to GPU') {
        throw "$LogName did not confirm model layers actually offloaded to the GPU."
    }
    if ($Device -eq 'gpu' -and $log -match 'ready in .*device CPU\)') { throw "$LogName silently used CPU in required GPU mode." }
    if ($Device -eq 'cpu' -and ($log -match 'ready in .*device Vulkan[0-9]+\)' -or
            $log -match 'offloaded [1-9][0-9]*/[1-9][0-9]* layers to GPU')) {
        throw "$LogName used GPU despite the CPU-only baseline override."
    }
    Copy-Item -LiteralPath $path -Destination (Join-Path $testRoot $EvidenceName)
}

function Invoke-SmokeProcess {
    param([string]$Program, [string[]]$Arguments, [string]$Label, [string]$InputText, [string]$NsisDirectory, [switch]$GuiProcess)
    $start = [Diagnostics.ProcessStartInfo]::new($Program)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    if ($InputText) { $start.RedirectStandardInput = $true }
    if ($NsisDirectory) {
        # NSIS alone requires /D= as the unquoted final remainder, including spaces.
        # This goes directly to CreateProcess, never to a command shell.
        if ($NsisDirectory.Contains('"')) { throw 'Invalid installation directory.' }
        $start.Arguments = "/S /D=$NsisDirectory"
    } else { foreach ($arg in $Arguments) { $start.ArgumentList.Add($arg) } }
    Set-SmokeEnvironment $start -GuiProcess:$GuiProcess
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if ($InputText) { $process.StandardInput.WriteLine($InputText); $process.StandardInput.Close() }
    if (!$process.WaitForExit($TimeoutSeconds * 1000)) { $process.Kill($true); throw "$Label timed out." }
    if (!$stdout.Wait(5000) -or !$stderr.Wait(5000)) { throw "$Label left output handles open after exit." }
    $text = $stdout.GetAwaiter().GetResult()
    $text | Set-Content "$testRoot/$Label.stdout.txt" -Encoding utf8NoBOM
    $stderr.GetAwaiter().GetResult() | Set-Content "$testRoot/$Label.stderr.txt" -Encoding utf8NoBOM
    if ($process.ExitCode -ne 0) { throw "$Label failed with exit $($process.ExitCode); inspect $testRoot." }
    return $text
}

function Wait-Keyword {
    param([string]$Query, [string]$ExpectedName, [bool]$Present, [string]$Label)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $request = @{ id = 1; op = 'search'; q = $Query; meaning = $false } | ConvertTo-Json -Compress
        $output = Invoke-SmokeProcess $cli @('search-service', $fixture, '--index', $index) $Label $request
        $reply = @($output -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 1 })
        if ($reply.Count -eq 1) {
            $found = @($reply[0].hits | Where-Object { [IO.Path]::GetFileName($_.path) -eq $ExpectedName }).Count -gt 0
            if ($found -eq $Present) { return }
        }
        if ($watcherProcess.HasExited) { throw 'GUI exited during the live watcher test.' }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "$Label did not converge before the timeout."
}

$installed = $false
try {
    Invoke-SmokeProcess -Program ([IO.Path]::GetFullPath($Installer)) -Arguments @() -Label 'install' -NsisDirectory $install | Out-Null
    $installed = $true
    $cli = Join-Path $install 'helper/digup.exe'
    $gui = Join-Path $install 'digup-shell.exe'
    if (!(Test-Path $gui)) { $gui = Join-Path $install 'DigUp.exe' }
    if (!(Test-Path $cli) -or !(Test-Path $gui)) { throw 'The installer did not deploy the GUI and helper.' }
    Invoke-SmokeProcess $cli @('--help') 'cli-help' | Out-Null
    Invoke-SmokeProcess $cli @('download-model', '--to', $Models) 'verify-model' | Out-Null
    Invoke-SmokeProcess $cli @('index', $fixture, '--index', $index) 'index-first' | Out-Null
    $before = Invoke-SmokeProcess $cli @('status', '--index', $index) 'status-first'
    if ($before -notmatch 'vectors: ([1-9][0-9, ]*) in ([1-9][0-9, ]*) segments') { throw 'No real embeddings were stored.' }
    $counts = $Matches[0]
    # The lowered significance gate accommodates four documents; ranking, a cosine,
    # zero exact query terms and three distractors establish this is real inference.
    $meaning = @(Invoke-SmokeProcess $cli @('search', 'fresh food in orbit', '--index', $index, '--json', '--zgate', '-100') 'search-meaning' | ConvertFrom-Json)
    if (!$meaning.Count -or [IO.Path]::GetFileName($meaning[0].path) -ne $name -or !$meaning[0].PSObject.Properties['cosine']) {
        throw 'Real semantic inference did not rank the space greenhouse ahead of three unrelated documents.'
    }
    $rawWords = Invoke-SmokeProcess $cli @('search-service', $fixture, '--index', $index) 'search-words' '{"id":1,"op":"search","q":"ORBITGREEN742","meaning":false}'
    $wordReply = @($rawWords -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json } |
        Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 1 })
    if ($wordReply.Count -ne 1 -or $wordReply[0].meaning -or !(@($wordReply[0].hits) | Where-Object { [IO.Path]::GetFileName($_.path) -eq $name -and $_.keyword_rank })) {
        throw 'FTS-only query did not find the fixture.'
    }
    Invoke-SmokeProcess $cli @('index', $fixture, '--index', $index) 'index-again' | Out-Null
    $after = Invoke-SmokeProcess $cli @('status', '--index', $index) 'status-again'
    if (!$after.Contains($counts)) { throw 'Reindexing unchanged inputs changed vector/segment counts.' }
    $report = Join-Path $testRoot 'gui-report.json'
    $settings = Join-Path $testRoot 'settings.json'
    # Separate CLI inference evidence from the GUI's subsequent real worker loads.
    foreach ($log in @('worker.log', 'worker-query.log')) {
        if (Test-Path -LiteralPath "$index/$log") { Move-Item -LiteralPath "$index/$log" -Destination "$testRoot/cli-$log" }
    }
    'A telescope observes distant galaxies. This file is indexed only by the installed GUI. GUIINDEX643.' |
        Set-Content -LiteralPath (Join-Path $fixture 'gui-only.txt') -Encoding utf8NoBOM
    $deviceChoice = if ($Device -eq 'gpu') { @('--debug-device', 'gpu') } else { @() }
    $guiArguments = @('--index', $index, '--models', $Models, '--settings', $settings,
        '--debug-setup', '--offer', $fixture, '--debug-query', 'ORBITGREEN742', '--debug-report', $report, '--debug-quit') + $deviceChoice
    Invoke-SmokeProcess $gui $guiArguments 'gui' -GuiProcess | Out-Null
    if (!(Test-Path $report)) { throw 'The actual installed WebView never reported a result.' }
    $ui = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    if ($ui.phase -ne 'meaning' -or !(($ui.groups.rows | ForEach-Object { $_ }) -contains $name)) {
        throw 'Installed GUI did not display the indexed fixture with semantic search ready.'
    }
    $saved = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
    if (!$saved.setUp -or $saved.folders -notcontains $fixture) { throw 'Setup choices did not persist.' }
    if ($ui.devicePreference -ne $Device) { throw 'The GUI used a different processing device preference.' }
    if ($Device -eq 'gpu' -and ($saved.device -ne 'gpu' -or $ui.savedDevice -ne 'gpu' -or $ui.deviceOverridden)) {
        throw 'GPU selection did not persist through the actual setup form, or a launch override bypassed it.'
    }
    Assert-WorkerDevice 'worker.log' 'gui-worker.log'
    Assert-WorkerDevice 'worker-query.log' 'gui-worker-query.log'
    Move-Item -LiteralPath "$index/worker-query.log" -Destination "$testRoot/gui-first-query-original.log"
    Invoke-SmokeProcess $gui @('--index', $index, '--models', $Models, '--settings', $settings,
        '--debug-query', 'ORBITGREEN742', '--debug-report', "$testRoot/gui-restart.json", '--debug-quit') 'gui-restart' -GuiProcess | Out-Null
    $restart = Get-Content "$testRoot/gui-restart.json" -Raw | ConvertFrom-Json
    if ($restart.phase -ne 'meaning' -or !(($restart.groups.rows | ForEach-Object { $_ }) -contains $name)) {
        throw 'Restart did not preserve the working index and settings.'
    }
    if ($restart.devicePreference -ne $Device -or ($Device -eq 'gpu' -and ($restart.savedDevice -ne 'gpu' -or $restart.deviceOverridden))) {
        throw 'Restart did not load the saved processing device.'
    }
    Assert-WorkerDevice 'worker-query.log' 'gui-restart-worker-query.log'
    # Keep the installed GUI alive; only its real notify watcher may update the index.
    $watchStart = [Diagnostics.ProcessStartInfo]::new($gui)
    $watchStart.UseShellExecute = $false
    $watchStart.CreateNoWindow = $true
    $watchStart.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    foreach ($arg in @('--index', $index, '--models', $Models, '--settings', $settings,
        '--debug-query', 'ORBITGREEN742', '--debug-report', "$testRoot/watch-ready.json")) { $watchStart.ArgumentList.Add($arg) }
    Set-SmokeEnvironment $watchStart -GuiProcess
    $watcherProcess = [Diagnostics.Process]::Start($watchStart)
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (!(Test-Path "$testRoot/watch-ready.json")) {
            if ($watcherProcess.HasExited -or [DateTime]::UtcNow -ge $deadline) { throw 'GUI watcher did not become ready.' }
            Start-Sleep -Milliseconds 250
        }
        $addedName = 'Новый документ café.txt'
        $added = Join-Path $fixture $addedName
        'A microscope experiment records the unique observation WATCHADD742.' | Set-Content -LiteralPath $added -Encoding utf8NoBOM
        Wait-Keyword 'WATCHADD742' $addedName $true 'watch-add'
        'The revised microscope experiment records WATCHCHANGE853 instead of the earlier observation.' | Set-Content -LiteralPath $added -Encoding utf8NoBOM
        Wait-Keyword 'WATCHCHANGE853' $addedName $true 'watch-change'
        Wait-Keyword 'WATCHADD742' $addedName $false 'watch-old-text'
        $renamedName = 'Переименованный документ 🦊.txt'
        $renamed = Join-Path $fixture $renamedName
        Move-Item -LiteralPath $added -Destination $renamed
        Wait-Keyword 'WATCHCHANGE853' $renamedName $true 'watch-rename'
        Remove-Item -LiteralPath $renamed
        Wait-Keyword 'WATCHCHANGE853' $renamedName $false 'watch-delete'
        # CLI search reads storage directly, without the GUI's file-existence filter.
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        do {
            $removed = @(Invoke-SmokeProcess $cli @('search', 'WATCHCHANGE853', '--index', $index, '--json') 'watch-delete-storage' | ConvertFrom-Json)
            if (!($removed | Where-Object { [IO.Path]::GetFileName($_.path) -in @($addedName, $renamedName) })) { break }
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Watcher left a deleted record in the index.' }
            Start-Sleep -Seconds 2
        } while ($true)
    } finally {
        if (!$watcherProcess.HasExited) { $watcherProcess.Kill($true); $watcherProcess.WaitForExit() }
    }
    Remove-Item -LiteralPath $sample
    Invoke-SmokeProcess $cli @('index', $fixture, '--index', $index) 'index-deleted' | Out-Null
    $deleted = Invoke-SmokeProcess $cli @('search', 'ORBITGREEN742', '--index', $index, '--json') 'search-deleted' | ConvertFrom-Json
    if (@($deleted) | Where-Object { [IO.Path]::GetFileName($_.path) -eq $name }) { throw 'Deleted fixture remains searchable.' }
    $result = @{ result = 'passed'; device = $Device; os = [Environment]::OSVersion.VersionString; path = 'System32 and Windows only'; realModel = $true;
       checks = @('CLI', 'installed GUI WebView', 'setup', 'Unicode paths', "$Device embeddings", 'actual GUI worker device logs', 'FTS', 'idempotence', 'restart',
           'live watcher add/change/rename/delete', 'delete', 'uninstall') }
} finally {
    if ($installed) {
        $uninstaller = Get-ChildItem -LiteralPath $install -Filter '*uninstall*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($uninstaller) {
            Invoke-SmokeProcess $uninstaller.FullName @('/S') 'uninstall' | Out-Null
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while ((Test-Path -LiteralPath $gui) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250 }
            if ((Test-Path -LiteralPath $gui) -or (Test-Path -LiteralPath $cli)) { throw 'Uninstall left application binaries behind.' }
        }
        else { throw "No uninstaller found in $install" }
    }
}
$result | ConvertTo-Json | Set-Content "$testRoot/result.json" -Encoding utf8NoBOM
Write-Host "Real installer/CLI/GUI smoke passed. Evidence: $testRoot"
