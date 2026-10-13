#requires -Version 7.2
param(
    [Parameter(Mandatory)][Alias('PackageDir')][string]$PackageDirectory,
    [Parameter(Mandatory)][string]$Models,
    [Alias('OutputDir')][string]$OutputDirectory,
    [string]$RepoRoot = (Join-Path $PSScriptRoot '../..'),
    [ValidateRange(30, 3600)][int]$TimeoutSeconds = 600,
    [switch]$NoGpuRequired
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (!$IsWindows) { throw 'This packaged runtime smoke requires Windows.' }
$repo = [IO.Path]::GetFullPath($RepoRoot)
$package = [IO.Path]::GetFullPath($PackageDirectory)
$modelsFolder = [IO.Path]::GetFullPath($Models)
if (!$OutputDirectory) { $OutputDirectory = "$repo/build.noindex/windows/gpu-smoke-$([Guid]::NewGuid().ToString('N'))" }
$testRoot = [IO.Path]::GetFullPath($OutputDirectory)
if ((Test-Path -LiteralPath $testRoot) -and @(Get-ChildItem -LiteralPath $testRoot -Force).Count) {
    throw 'OutputDirectory must be new or empty; smoke evidence is never overwritten.'
}
$runtime = Join-Path $package 'helper'
$referenceFolder = Join-Path $repo 'Tests/LlamaRuntimeTests/Reference'
$modelNames = @('embeddinggemma-2-Q8_0.gguf', 'mmproj-embeddinggemma-2-Q8_0.gguf')
foreach ($path in @("$runtime/digup.exe", "$referenceFolder/vectors.json", "$referenceFolder/photo.jpg",
        "$referenceFolder/screen.png", "$referenceFolder/speech.wav") + @($modelNames | ForEach-Object { "$modelsFolder/$_" })) {
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required input missing: $path" }
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$reference = Get-Content -LiteralPath "$referenceFolder/vectors.json" -Raw | ConvertFrom-Json -AsHashtable
$agreement = 0.999
$utf8 = [Text.UTF8Encoding]::new($false)

function Protect-Log([string]$Text) {
    # Fixtures are public, but absolute model/build paths can contain a person's account name.
    foreach ($pair in @(@($testRoot, '<evidence>'), @($package, '<package>'), @($modelsFolder, '<models>'),
            @($repo, '<repo>'), @($env:USERPROFILE, '<profile>'))) {
        if ($pair[0]) {
            $Text = $Text.Replace($pair[0], $pair[1]).Replace($pair[0].Replace('\', '/'), $pair[1])
        }
    }
    return $Text
}

function Read-WorkerReply($Worker) {
    $pending = $Worker.Process.StandardOutput.ReadLineAsync()
    if (!$pending.Wait($TimeoutSeconds * 1000)) { throw "$($Worker.Label): protocol response timed out." }
    $line = $pending.GetAwaiter().GetResult()
    if ($null -eq $line) { throw "$($Worker.Label): worker closed stdout before its reply." }
    $Worker.Stdout.WriteLine((Protect-Log $line))
    return ($line | ConvertFrom-Json -AsHashtable)
}

function Send-WorkerRequest($Worker, [hashtable]$Request) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $Worker.Process.StandardInput.WriteLine(($Request | ConvertTo-Json -Depth 6 -Compress))
    $Worker.Process.StandardInput.Flush()
    $reply = Read-WorkerReply $Worker
    if (!$reply.ContainsKey('id') -or $reply.id -ne $Request.id) { throw "$($Worker.Label): mismatched response id." }
    if (!$reply.ContainsKey('ok') -or !$reply.ok) { throw "$($Worker.Label): request $($Request.op) failed: $($reply.error)" }
    $Worker.Durations.Add([ordered]@{ op = $Request.op; id = $Request.id; seconds = $timer.Elapsed.TotalSeconds })
    return $reply
}

function Start-GpuWorker([string]$RuntimeDirectory, [string]$Device, [string]$Label,
                         [switch]$TextOnly, [switch]$CpuOverride) {
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $RuntimeDirectory 'digup.exe'))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.WorkingDirectory = $testRoot
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardInputEncoding = $utf8
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    foreach ($argument in @('worker', '--device', $Device)) { $start.ArgumentList.Add($argument) }
    if ($TextOnly) { $start.ArgumentList.Add('--text-only') }
    # Only child environments change: CPU_ONLY and every ambient backend/driver override are restored by design.
    foreach ($key in @($start.Environment.Keys)) {
        if ($key -match '^(DIGUP_|GGML_|LLAMA_|MTMD_|VK_|VULKAN_|CUDA_|HIP_|ROCR_|HSA_)' -or
            $key -in @('LD_LIBRARY_PATH', 'DYLD_LIBRARY_PATH', 'OMP_NUM_THREADS')) {
            $null = $start.Environment.Remove($key)
        }
    }
    $start.Environment['PATH'] = "$RuntimeDirectory;$env:SystemRoot/System32"
    $start.Environment['DIGUP_MODELS'] = $modelsFolder
    $start.Environment['DIGUP_BACKENDS'] = $RuntimeDirectory
    if ($CpuOverride) { $start.Environment['DIGUP_CPU_ONLY'] = '1' }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($start)
    return @{
        Process = $process; Label = $Label; Timer = $timer
        Stderr = $process.StandardError.ReadToEndAsync()
        Stdout = [IO.StreamWriter]::new("$testRoot/$Label.stdout.jsonl", $false, $utf8)
        Durations = [Collections.Generic.List[object]]::new()
    }
}

function Close-GpuWorker($Worker) {
    try {
        if (!$Worker.Process.HasExited) {
            $Worker.Process.Kill($true)
            if (!$Worker.Process.WaitForExit(5000)) { throw "$($Worker.Label): worker did not terminate." }
        }
        if (!$Worker.Stderr.Wait(5000)) { throw "$($Worker.Label): stderr remained open after process exit." }
        $stderr = $Worker.Stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText("$testRoot/$($Worker.Label).stderr.txt", (Protect-Log $stderr), $utf8)
    } finally {
        $Worker.Stdout.Dispose()
        $Worker.Process.Dispose()
    }
}

function Read-VectorRows([hashtable]$Reply, [string[]]$Names) {
    if ($Reply.dim -ne 768 -or $Reply.count -ne $Names.Count -or @($Reply.errors).Count -ne $Names.Count) {
        throw 'Embedding reply has an unexpected dimension, row count or errors array.'
    }
    if (@($Reply.errors | Where-Object { $null -ne $_ }).Count) { throw 'An input failed to embed.' }
    $bytes = [Convert]::FromBase64String($Reply.vectors)
    if ($bytes.Length -ne $Names.Count * 768 * 4 -or ![BitConverter]::IsLittleEndian) {
        throw 'The float32 little-endian vector payload has an unexpected size or host byte order.'
    }
    $rows = @{}
    for ($row = 0; $row -lt $Names.Count; $row++) {
        $vector = [float[]]::new(768)
        $norm = 0.0
        for ($column = 0; $column -lt 768; $column++) {
            $value = [BitConverter]::ToSingle($bytes, ($row * 768 + $column) * 4)
            if (![float]::IsFinite($value)) { throw "$($Names[$row]): vector contains non-finite values." }
            $vector[$column] = $value
            $norm += [double]$value * [double]$value
        }
        if ($norm -le 0) { throw "$($Names[$row]): vector is zero." }
        $rows[$Names[$row]] = $vector
    }
    return $rows
}

function Get-Cosine($First, $Second) {
    if ($First.Count -ne 768 -or $Second.Count -ne 768) { throw 'Reference/vector dimension is not 768.' }
    $dot = 0.0; $a = 0.0; $b = 0.0
    for ($i = 0; $i -lt 768; $i++) {
        if (![double]::IsFinite([double]$First[$i]) -or ![double]::IsFinite([double]$Second[$i])) {
            throw 'Comparison contains non-finite values.'
        }
        $dot += [double]$First[$i] * [double]$Second[$i]
        $a += [double]$First[$i] * [double]$First[$i]
        $b += [double]$Second[$i] * [double]$Second[$i]
    }
    if ($a -le 0 -or $b -le 0) { throw 'Comparison contains a zero vector.' }
    return $dot / [Math]::Sqrt($a * $b)
}

function Invoke-VectorWorker([string]$RuntimeDirectory, [string]$Device, [string]$Label,
                             [switch]$TextOnly, [switch]$CpuOverride, [switch]$ExpectCpu) {
    Write-Host "[$([DateTime]::UtcNow.ToString('o'))] ${Label}: real worker --device $Device"
    $worker = Start-GpuWorker $RuntimeDirectory $Device $Label -TextOnly:$TextOnly -CpuOverride:$CpuOverride
    try {
        $ready = Read-WorkerReply $worker
        if (!$ready.ready) { throw "$Label failed to prepare its model: $($ready.error)" }
        $initializationSeconds = $worker.Timer.Elapsed.TotalSeconds
        $info = $ready.info
        if (!$info.ContainsKey('device') -or [string]::IsNullOrWhiteSpace($info.device)) { throw "$Label omitted info.device." }
        if (($ExpectCpu -and $info.device -ne 'CPU') -or (!$ExpectCpu -and $info.device -eq 'CPU')) {
            throw "$Label selected unexpected device $($info.device)."
        }
        if ($info.dim -ne 768 -or [bool]$info.text_only -ne [bool]$TextOnly) { throw "$Label has unexpected model information." }
        $reported = (Send-WorkerRequest $worker @{ id = 1; op = 'info' }).info
        if ($reported.device -ne $info.device -or $reported.runtime -ne $info.runtime) { throw "$Label changed its device/runtime report." }
        if ($info.runtime -ne "llama.cpp-vectors$($reference.vector_version)") { throw "$Label vector version differs from checked-in references." }
        $requests = @(@{ id = 2; op = 'text'; inputs = @('task: search result | query: payment declined error'); names = @('query') })
        if (!$TextOnly) {
            $long = (1..60 | ForEach-Object {
                "Note ${_}: the review moved to room $($_ % 7 + 2) because the projector in the main hall failed again, and the team agreed to send the slides the night before."
            }) -join ' '
            $requests[0].inputs = @('task: search result | query: payment declined error',
                'task: search result | query: ইলিশ মাছ রান্না', 'task: search result | query: متى تغلق المكتبة',
                'title: Tokyo itinerary | text: Flight to Tokyo Haneda on November 3. Then the train to Kamakura to see the Great Buddha, and back for dinner in Shibuya.',
                "title: none | text: $long")
            $requests[0].names = @('query', 'query-bn', 'query-ar', 'document', 'document-long')
            $requests += @(
                @{ id = 3; op = 'image'; inputs = @("$referenceFolder/screen.png"); budget = 280; names = @('screen-280') },
                @{ id = 4; op = 'image'; inputs = @("$referenceFolder/photo.jpg"); budget = 140; names = @('photo-140') },
                @{ id = 5; op = 'image'; inputs = @("$referenceFolder/photo.jpg"); budget = 70; names = @('frame-70') },
                @{ id = 6; op = 'audio'; inputs = @("$referenceFolder/speech.wav"); names = @('speech') }
            )
        }
        $vectors = @{}
        $agreements = [ordered]@{}
        foreach ($request in $requests) {
            $names = $request.names
            $request.Remove('names')
            $rows = Read-VectorRows (Send-WorkerRequest $worker $request) $names
            foreach ($name in $names) {
                $vectors[$name] = $rows[$name]
                if (!$reference.vectors.ContainsKey($name)) { throw "Missing checked-in reference $name." }
                $cosine = Get-Cosine $rows[$name] $reference.vectors[$name]
                if ($cosine -lt $agreement) { throw "$Label $name differs from reference: cosine=$cosine, required=$agreement." }
                $agreements[$name] = $cosine
            }
        }
        $null = Send-WorkerRequest $worker @{ id = 99; op = 'quit' }
        $worker.Process.StandardInput.Close()
        if (!$worker.Process.WaitForExit(5000) -or $worker.Process.ExitCode -ne 0) { throw "$Label did not exit cleanly after quit." }
        return @{
            Vectors = $vectors
            Evidence = [ordered]@{ device = $info.device; info = $info; referenceCosines = $agreements
                initializationSeconds = $initializationSeconds; totalSeconds = $worker.Timer.Elapsed.TotalSeconds
                operations = $worker.Durations.ToArray(); requestedDevice = $Device; cpuOnlyOverride = [bool]$CpuOverride }
        }
    } finally { Close-GpuWorker $worker }
}

function Assert-GpuUnavailable([string]$RuntimeDirectory) {
    $worker = Start-GpuWorker $RuntimeDirectory 'gpu' 'gpu-unavailable' -TextOnly
    try {
        $reply = Read-WorkerReply $worker
        if ($reply.ready -or !$reply.ContainsKey('error') -or $reply.error -notmatch 'no supported GPU backend') {
            throw 'Forced GPU mode did not report an explicit unavailable-backend error.'
        }
        $worker.Process.StandardInput.Close()
        if (!$worker.Process.WaitForExit(5000) -or $worker.Process.ExitCode -eq 0) {
            throw 'Forced GPU without a backend did not exit with a failure status.'
        }
        return [ordered]@{ ready = $false; error = $reply.error; exitCode = $worker.Process.ExitCode
            seconds = $worker.Timer.Elapsed.TotalSeconds }
    } finally { Close-GpuWorker $worker }
}

$result = [ordered]@{ result = 'running'; startedUtc = [DateTime]::UtcNow.ToString('o')
    mode = $(if ($NoGpuRequired) { 'cpu-and-device-policy' } else { 'cpu-gpu-reference-comparison' })
    minimumCosine = $agreement; pathPolicy = 'runtime directory and System32 only'; ambientOverridesCleared = $true
    parentEnvironmentModified = $false; checks = [ordered]@{} }
try {
    $machine = [ordered]@{ os = [Environment]::OSVersion.VersionString; architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        logicalProcessors = [Environment]::ProcessorCount }
    try {
        $machine.cpu = @(Get-CimInstance Win32_Processor -OperationTimeoutSec 10 | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
        $machine.graphics = @(Get-CimInstance Win32_VideoController -OperationTimeoutSec 10 |
            Select-Object Name, AdapterCompatibility, DriverVersion, DriverDate, VideoProcessor)
    } catch { $machine.metadataNote = 'CIM CPU/driver metadata unavailable; runtime device evidence is still required.' }
    $machine | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$testRoot/machine.json" -Encoding utf8NoBOM
    $hashes = [Collections.Generic.List[object]]::new()
    foreach ($entry in @(@{ Root = $runtime; Prefix = 'runtime'; Files = @(Get-ChildItem -LiteralPath $runtime -File | Where-Object { $_.Extension -in '.dll', '.exe' }) },
            @{ Root = $referenceFolder; Prefix = 'reference'; Files = @(Get-ChildItem -LiteralPath $referenceFolder -File) },
            @{ Root = $modelsFolder; Prefix = 'models'; Files = @($modelNames | ForEach-Object { Get-Item -LiteralPath "$modelsFolder/$_" }) })) {
        foreach ($file in $entry.Files) {
            $hashes.Add([ordered]@{ name = "$($entry.Prefix)/$($file.Name)"; bytes = $file.Length
                sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() })
        }
    }
    $hashes | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$testRoot/input-checksums.json" -Encoding utf8NoBOM
    if (!$NoGpuRequired) {
        $cpu = Invoke-VectorWorker $runtime 'cpu' 'cpu' -ExpectCpu
        $gpu = Invoke-VectorWorker $runtime 'gpu' 'gpu'
        $result.checks.cpu = $cpu.Evidence
        $result.checks.gpu = $gpu.Evidence
        $result.checks.cpuGpuCosines = [ordered]@{}
        foreach ($name in $cpu.Vectors.Keys) {
            $cosine = Get-Cosine $cpu.Vectors[$name] $gpu.Vectors[$name]
            if ($cosine -lt $agreement) { throw "$name CPU/GPU disagreement: cosine=$cosine, required=$agreement." }
            $result.checks.cpuGpuCosines[$name] = $cosine
        }
        $gpuLog = Get-Content -LiteralPath "$testRoot/gpu.stderr.txt" -Raw
        if ($gpuLog -notmatch 'offloaded [1-9][0-9]*/[1-9][0-9]* layers') { throw 'GPU worker did not log actual layer offload.' }
        $result.checks.positiveGpuLayerOffload = $true
    }
    # Isolate a copy under evidence, never remove a backend from the input package or a user's installation.
    # Keeping only CPU ggml plugins makes these real policy tests work even on a GPU-equipped CI host.
    $cpuRuntime = Join-Path $testRoot 'cpu-runtime'
    New-Item -ItemType Directory -Path $cpuRuntime | Out-Null
    $cpuFiles = @(Get-ChildItem -LiteralPath $runtime -File | Where-Object {
        ($_.Name -eq 'digup.exe' -or $_.Extension -eq '.dll') -and
        ($_.Name -notlike 'ggml-*.dll' -or $_.Name -eq 'ggml-base.dll' -or $_.Name -like 'ggml-cpu*.dll')
    })
    if (!@($cpuFiles | Where-Object { $_.Name -like 'ggml-cpu*.dll' }).Count) { throw 'Package has no CPU backend DLL.' }
    foreach ($file in $cpuFiles) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $cpuRuntime $file.Name) }
    $result.checks.isolatedCpuRuntimeFiles = @($cpuFiles.Name | Sort-Object)
    $auto = Invoke-VectorWorker $cpuRuntime 'auto' 'auto-without-gpu' -TextOnly -ExpectCpu
    $result.checks.autoWithoutGpuBackend = $auto.Evidence
    $result.checks.forcedGpuWithoutBackend = Assert-GpuUnavailable $cpuRuntime
    $override = Invoke-VectorWorker $cpuRuntime 'gpu' 'cpu-only-override' -TextOnly -CpuOverride -ExpectCpu
    $result.checks.cpuOnlyOverridesForcedGpu = $override.Evidence
    $result.result = 'passed'
} catch {
    $result.result = 'failed'
    $result.error = Protect-Log $_.Exception.Message
    throw
} finally {
    $result.finishedUtc = [DateTime]::UtcNow.ToString('o')
    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath "$testRoot/result.json" -Encoding utf8NoBOM
}
Write-Host "GPU/device-policy smoke passed. Evidence: $testRoot"
