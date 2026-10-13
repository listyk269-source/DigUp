# Shared build helpers. Dot-source; no installation or elevation is performed here.
#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$script:Manifest = Get-Content (Join-Path $PSScriptRoot 'dependencies.json') -Raw | ConvertFrom-Json
$script:Vendor = Join-Path $script:Repo 'Vendor'

function Invoke-Checked {
    param([Parameter(Mandatory)][string]$Program, [string[]]$Arguments = @())
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed (exit $LASTEXITCODE)." }
}

function Write-BuildPhase {
    param([Parameter(Mandatory)][string]$Message)
    $line = "[$([DateTime]::UtcNow.ToString('o'))] $Message"
    Write-Host $line
    $diagnostics = Join-Path $script:Repo 'build.noindex/windows/diagnostics'
    New-Item -ItemType Directory -Force -Path $diagnostics | Out-Null
    Add-Content -LiteralPath "$diagnostics/phases.log" -Value $line -Encoding utf8NoBOM
}

function Invoke-BoundedNative {
    param(
        [Parameter(Mandatory)][string]$Program,
        [string[]]$Arguments = @(),
        [ValidateRange(1, 7200)][int]$TimeoutSeconds = 600,
        [string]$Phase = 'native process'
    )
    # ArgumentList preserves spaces/Unicode without a shell. Drain both pipes while
    # running so a verbose compiler cannot deadlock on a full redirected pipe.
    $application = (Get-Command $Program -CommandType Application -ErrorAction Stop).Source
    $start = [Diagnostics.ProcessStartInfo]::new($application)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WorkingDirectory = (Get-Location).ProviderPath
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    Write-BuildPhase "START $Phase executable=$application timeout=${TimeoutSeconds}s arguments=$($Arguments | ConvertTo-Json -Compress)"
    $process = $null
    $writer = $null
    $descendants = @()
    try {
        $process = [Diagnostics.Process]::Start($start)
        $process.StandardInput.Close()
        Write-BuildPhase "PID $($process.Id) $Phase"
        $diagnostics = Join-Path $script:Repo 'build.noindex/windows/diagnostics'
        $writer = [IO.StreamWriter]::new("$diagnostics/native-processes.log", $true, [Text.UTF8Encoding]::new($false))
        $writer.AutoFlush = $true
        $streams = @(
            @{ Name = 'stdout'; Reader = $process.StandardOutput; Pending = $process.StandardOutput.ReadLineAsync(); Done = $false },
            @{ Name = 'stderr'; Reader = $process.StandardError; Pending = $process.StandardError.ReadLineAsync(); Done = $false }
        )
        $elapsed = [Diagnostics.Stopwatch]::StartNew()
        $nextHeartbeat = 60
        while (!$process.HasExited -or @($streams | Where-Object { !$_.Done }).Count) {
            foreach ($stream in $streams) {
                for ($lineCount = 0; $lineCount -lt 128 -and !$stream.Done -and $stream.Pending.IsCompleted; $lineCount++) {
                    $line = $stream.Pending.GetAwaiter().GetResult()
                    if ($null -eq $line) { $stream.Done = $true; break }
                    Write-Host $line
                    $writer.WriteLine("[$Phase pid=$($process.Id) $($stream.Name)] $line")
                    $stream.Pending = $stream.Reader.ReadLineAsync()
                }
            }
            if ($elapsed.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                Write-BuildPhase "TIMEOUT $Phase pid=$($process.Id) elapsed=$([int]$elapsed.Elapsed.TotalSeconds)s"
                if ($IsWindows) {
                    try {
                        $all = @(Get-CimInstance Win32_Process -OperationTimeoutSec 5 -ErrorAction Stop)
                        $ids = [Collections.Generic.HashSet[uint32]]::new()
                        $null = $ids.Add([uint32]$process.Id)
                        do {
                            $added = $false
                            foreach ($item in $all) {
                                if ($ids.Contains([uint32]$item.ParentProcessId) -and $ids.Add([uint32]$item.ProcessId)) { $added = $true }
                            }
                        } while ($added)
                        $descendants = @($all | Where-Object { $ids.Contains([uint32]$_.ProcessId) -and $_.ProcessId -ne $process.Id })
                        $all | Where-Object { $ids.Contains([uint32]$_.ProcessId) } |
                            Select-Object ProcessId, ParentProcessId, Name, CommandLine |
                            ConvertTo-Json -Depth 3 | Set-Content -LiteralPath "$diagnostics/timeout-process-tree.json" -Encoding utf8NoBOM
                    } catch {
                        # Restricted developer accounts may not have CIM access;
                        # diagnostics must not hide the original process timeout.
                        Write-BuildPhase "Process-tree query unavailable: $($_.Exception.Message)"
                    }
                }
                throw "$Phase exceeded ${TimeoutSeconds}s (PID $($process.Id)); see build.noindex/windows/diagnostics."
            }
            if ($elapsed.Elapsed.TotalSeconds -ge $nextHeartbeat) {
                Write-BuildPhase "RUNNING $Phase pid=$($process.Id) elapsed=$([int]$elapsed.Elapsed.TotalSeconds)s"
                $nextHeartbeat += 60
            }
            if (!$process.HasExited -or @($streams | Where-Object { !$_.Done }).Count) { Start-Sleep -Milliseconds 25 }
        }
        $process.WaitForExit()
        Write-BuildPhase "END $Phase pid=$($process.Id) exit=$($process.ExitCode) elapsed=$([math]::Round($elapsed.Elapsed.TotalSeconds, 2))s"
        return $process.ExitCode
    } finally {
        try {
            if ($process -and !$process.HasExited) { $process.Kill($true); $null = $process.WaitForExit(10000) }
        } catch [InvalidOperationException] {
            # The process exited between HasExited and Kill.
        } catch [ComponentModel.Win32Exception] {
            Write-BuildPhase "Launcher cleanup unavailable: $($_.Exception.Message)"
        }
        # A launcher may exit while its child still owns a redirected pipe. The
        # timeout snapshot retains those children even after the launcher exits.
        # If CIM is unavailable, Kill(true) still handles a live launcher's tree.
        foreach ($child in $descendants) {
            $remaining = $null
            try {
                $remaining = [Diagnostics.Process]::GetProcessById([int]$child.ProcessId)
                # Match the snapshot's creation time, not just its PID: Windows
                # may reuse a child's PID before cleanup gets to it.
                $sameProcess = [math]::Abs(($remaining.StartTime.ToUniversalTime() - $child.CreationDate.ToUniversalTime()).TotalMilliseconds) -le 1
                if (!$remaining.HasExited -and $sameProcess) {
                    $remaining.Kill($true)
                    $null = $remaining.WaitForExit(10000)
                }
            } catch [ArgumentException] { } # Child already exited during tree cleanup.
              catch [InvalidOperationException] { }
              catch [ComponentModel.Win32Exception] {
                Write-BuildPhase "Child cleanup unavailable: $($_.Exception.Message)"
            } finally {
                if ($remaining) { $remaining.Dispose() }
            }
        }
        if ($writer) { $writer.Dispose() }
        if ($process) { $process.Dispose() }
    }
}

function Invoke-BoundedChecked {
    param([Parameter(Mandatory)][string]$Program, [string[]]$Arguments = @(), [int]$TimeoutSeconds = 600, [string]$Phase = 'native process')
    $exitCode = Invoke-BoundedNative -Program $Program -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds -Phase $Phase
    if ($exitCode -ne 0) { throw "$Phase failed (exit $exitCode)." }
}

function Expand-NativeArchive {
    param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)][string]$Destination)
    # Do not pick GNU tar from PATH: a Windows drive prefix can be treated as a
    # remote host by GNU tar. Windows bsdtar handles drive paths and these formats.
    $tar = Join-Path $env:SystemRoot 'System32/tar.exe'
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Invoke-BoundedChecked $tar @('--version') -TimeoutSeconds 20 -Phase 'Windows bsdtar version'
    Invoke-BoundedChecked $tar @('-xf', $Archive, '-C', $Destination) -TimeoutSeconds 300 -Phase "extract $([IO.Path]::GetFileName($Archive))"
}

function Reset-BuildDirectory {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = [IO.Path]::GetFullPath($Path)
    # Never remove arbitrary paths or the checkout itself, including when called with '..'.
    $allowed = @('Vendor', 'build.noindex', 'shell/src-tauri/resources') | ForEach-Object {
        [IO.Path]::GetFullPath((Join-Path $script:Repo $_)) + [IO.Path]::DirectorySeparatorChar
    }
    if (!($allowed | Where-Object { $resolved.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) })) {
        throw "Refusing to reset directory outside build output: $resolved"
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    New-Item -ItemType Directory -Path $resolved -Force | Out-Null
}

function Get-VerifiedDownload {
    param([Parameter(Mandatory)]$Spec)
    $cache = Join-Path $script:Vendor 'downloads'
    New-Item -ItemType Directory -Force $cache | Out-Null
    $destination = Join-Path $cache $Spec.file
    if (Test-Path -LiteralPath $destination) {
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -eq $Spec.sha256) {
            Write-BuildPhase "Verified cached download: $($Spec.file)"
            return $destination
        }
        Remove-Item -LiteralPath $destination -Force
    }
    $partial = "$destination.partial"
    $curl = Join-Path $env:SystemRoot 'System32/curl.exe'
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        # A partial remains on network errors. curl verifies TLS and resumes via HTTP Range.
        Write-BuildPhase "Downloading $($Spec.file), attempt $attempt/3: $($Spec.url)"
        $exitCode = Invoke-BoundedNative $curl @('--fail', '--location', '--silent', '--show-error', '--retry', '2', '--retry-delay', '2', '--retry-max-time', '120',
            '--connect-timeout', '20', '--max-time', '300', '--speed-time', '60', '--speed-limit', '1024',
            '--continue-at', '-', '--output', $partial, $Spec.url) -TimeoutSeconds 480 -Phase "download $($Spec.file) attempt $attempt"
        if ($exitCode -eq 0 -and (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -eq $Spec.sha256) {
            Move-Item -LiteralPath $partial -Destination $destination -Force
            Write-BuildPhase "Verified downloaded SHA256: $($Spec.file) $($Spec.sha256)"
            return $destination
        }
        if ($exitCode -eq 0 -or $exitCode -eq 33 -or $exitCode -eq 36) {
            # Invalid hash or a server without ranges: repeat the complete download.
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        }
    }
    throw "Download failed verification: $($Spec.file). Retry the command to resume; expected SHA256 $($Spec.sha256)."
}

function Copy-RuntimeDlls {
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
    $files = @(Get-ChildItem -LiteralPath $From -Filter '*.dll' -File)
    if (!$files.Count) { throw "No runtime DLLs found in $From" }
    $files | Copy-Item -Destination $To -Force
}
