#requires -Version 7.2
param([switch]$SkipTests)
. "$PSScriptRoot/Common.ps1"
if (!$IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') { throw 'Windows x64 is required.' }
$faceManifest = Get-Content "$PSScriptRoot/face-dependencies.json" -Raw | ConvertFrom-Json
$faceRoot = Join-Path $script:Vendor 'faces'
$faceBin = Join-Path $faceRoot 'bin'
$faceLicenses = Join-Path $faceRoot 'licenses'
New-Item -ItemType Directory -Force $faceBin,$faceLicenses | Out-Null

function Expand-FaceEntry([string]$Archive, [string]$Entry, [string]$Destination) {
    # Exact archive entries only: never extract untrusted archive paths into the checkout.
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $item = $zip.GetEntry($Entry)
        if (!$item) { throw "Pinned face runtime archive is missing $Entry" }
        $temporary = "$Destination.new"
        [IO.Compression.ZipFileExtensions]::ExtractToFile($item,$temporary,$true)
        if ((Test-Path -LiteralPath $Destination) -and
            (Get-FileHash -LiteralPath $Destination).Hash -eq (Get-FileHash -LiteralPath $temporary).Hash) {
            Remove-Item -LiteralPath $temporary -Force
        } else { Move-Item -LiteralPath $temporary -Destination $Destination -Force }
    } finally { $zip.Dispose() }
}

$ort = Get-VerifiedDownload $faceManifest.downloads.onnxRuntime
$dml = Get-VerifiedDownload $faceManifest.downloads.directML
foreach ($name in @('onnxruntime.dll','onnxruntime_providers_shared.dll')) {
    Expand-FaceEntry $ort "runtimes/win-x64/native/$name" "$faceBin/$name"
}
Expand-FaceEntry $dml 'bin/x64-win/DirectML.dll' "$faceBin/DirectML.dll"
foreach ($runtime in $faceManifest.runtime) {
    if ((Get-FileHash -LiteralPath "$faceBin/$($runtime.name)").Hash -ne $runtime.sha256) {
        throw "Face runtime extracted bytes differ: $($runtime.name)"
    }
}
Expand-FaceEntry $ort 'LICENSE' "$faceLicenses/ONNX-Runtime-MIT.txt"
Expand-FaceEntry $ort 'ThirdPartyNotices.txt' "$faceLicenses/ONNX-Runtime-ThirdPartyNotices.txt"
Expand-FaceEntry $dml 'LICENSE.txt' "$faceLicenses/DirectML-LICENSE.txt"
Expand-FaceEntry $dml 'LICENSE-CODE.txt' "$faceLicenses/DirectML-CODE-MIT.txt"
Expand-FaceEntry $dml 'ThirdPartyNotices.txt' "$faceLicenses/DirectML-ThirdPartyNotices.txt"
foreach ($license in @($faceManifest.downloads.yunetLicense,$faceManifest.downloads.sfaceLicense)) {
    Copy-Item -LiteralPath (Get-VerifiedDownload $license) -Destination "$faceLicenses/$($license.file)" -Force
}
Copy-Item -LiteralPath "$PSScriptRoot/face-dependencies.json" -Destination $faceLicenses -Force

Push-Location "$script:Repo/face-worker"
try {
    Invoke-Checked cargo @('fmt','--all','--','--check')
    if (!$SkipTests) {
        Invoke-Checked cargo @('clippy','--locked','--all-targets','--','-D','warnings')
        Invoke-Checked cargo @('test','--locked')
    }
    Invoke-Checked cargo @('build','--release','--locked')
    $metadata = & cargo metadata --locked --format-version 1 | ConvertFrom-Json
    if ($LASTEXITCODE) { throw 'Face worker Cargo metadata failed.' }
    Copy-Item -LiteralPath "$($metadata.target_directory)/release/digup-face-worker.exe" -Destination $faceBin -Force
    $metadata.packages | Select-Object name,version,license,repository | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath "$faceLicenses/Face-worker-crates.json" -Encoding utf8NoBOM
    foreach ($crate in $metadata.packages) {
        $crateRoot = Split-Path $crate.manifest_path
        $notices = @(Get-ChildItem -LiteralPath $crateRoot -File | Where-Object Name -Match '^(LICENSE|LICENCE|COPYING|NOTICE|COPYRIGHT)')
        if ($notices.Count) {
            $destination = "$faceLicenses/crates/$($crate.name)-$($crate.version)"
            New-Item -ItemType Directory -Force $destination | Out-Null
            $notices | Copy-Item -Destination $destination -Force
        }
    }
} finally { Pop-Location }
if (!$env:VCToolsRedistDir) { throw 'Use the VS 2022 x64 build environment.' }
$faceCRT = @(Get-ChildItem "$env:VCToolsRedistDir/x64" -Directory -Filter 'Microsoft.VC*.CRT')
if ($faceCRT.Count -ne 1) { throw 'Cannot locate app-local face worker VC runtime.' }
Copy-RuntimeDlls $faceCRT[0].FullName $faceBin
if ($env:DIGUP_CERT_THUMBPRINT) { & "$PSScriptRoot/Sign.ps1" -Path "$faceBin/digup-face-worker.exe" }
Write-Host "Built pinned YuNet/SFace worker and app-local CPU/DirectML runtime: $faceBin"
