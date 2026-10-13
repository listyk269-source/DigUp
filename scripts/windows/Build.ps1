#requires -Version 7.2
param(
    [string]$SwiftRuntimeDirectory = $env:DIGUP_SWIFT_RUNTIME,
    [switch]$SkipVendor,
    [switch]$SkipTests,
    [int]$Jobs = [Math]::Max(1, [Environment]::ProcessorCount - 1)
)
. "$PSScriptRoot/Common.ps1"
Set-Location $script:Repo
if (!$IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') { throw 'Windows x64 is required.' }
$swiftVersion = (& swift --version) -join ' '
if ($LASTEXITCODE -ne 0 -or $swiftVersion -notmatch [regex]::Escape("Swift version $($script:Manifest.tools.swift)")) {
    throw "Expected Swift $($script:Manifest.tools.swift); found $swiftVersion"
}
$rustVersion = & rustc --version
if ($LASTEXITCODE -ne 0 -or $rustVersion -notmatch "^rustc $([regex]::Escape($script:Manifest.tools.rust)) ") {
    throw "Expected Rust $($script:Manifest.tools.rust); found $rustVersion"
}
$tauriVersion = (& cargo tauri --version) -join ' '
if ($LASTEXITCODE -ne 0 -or $tauriVersion -notmatch [regex]::Escape($script:Manifest.tools.tauriCli)) {
    throw "Install the pinned CLI: cargo install tauri-cli --version $($script:Manifest.tools.tauriCli) --locked"
}
if (!$SkipVendor) {
    & "$PSScriptRoot/Fetch-Vendor.ps1"
    & "$PSScriptRoot/Build-Llama.ps1" -Jobs $Jobs
    & "$PSScriptRoot/Build-FFmpeg.ps1" -Destination "$script:Vendor/ffmpeg" -Jobs $Jobs
}
if (!$SwiftRuntimeDirectory) {
    $candidates = @(Get-ChildItem @("${env:ProgramFiles}/Swift/Runtimes/$($script:Manifest.tools.swift)",
        "$env:LOCALAPPDATA/Programs/Swift/Runtimes/$($script:Manifest.tools.swift)") -Filter swiftCore.dll -Recurse -ErrorAction SilentlyContinue)
    if ($candidates.Count -eq 1) { $SwiftRuntimeDirectory = $candidates[0].DirectoryName }
}
if (!$SwiftRuntimeDirectory -or !(Test-Path "$SwiftRuntimeDirectory/swiftCore.dll")) {
    throw 'Pass -SwiftRuntimeDirectory (or DIGUP_SWIFT_RUNTIME) containing the pinned Swift runtime DLLs.'
}
# Build/test processes need native libraries before packaging. Never alter the machine PATH.
$originalPath = $env:PATH
$originalCpuOnly = $env:DIGUP_CPU_ONLY
try {
    $env:DIGUP_CPU_ONLY = '1'
    $env:PATH = "$script:Vendor/llama/lib;$script:Vendor/pdfium/bin;$script:Vendor/ffmpeg/bin;$SwiftRuntimeDirectory;$originalPath"
    # Embed while linking: post-link mt.exe can corrupt Swift's PE/DWARF layout.
    Invoke-Checked swift @('build', '-c', 'release', '--product', 'digup', '--jobs', "$Jobs",
        '-Xlinker', '/MANIFEST:EMBED', '-Xlinker', "/MANIFESTINPUT:$PSScriptRoot/cli.manifest")
    if (!$SkipTests) { Invoke-Checked swift @('test', '--jobs', "$Jobs") }
    $swiftBin = (& swift build -c release --show-bin-path | Select-Object -Last 1).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot locate the Swift output.' }
    $package = "$script:Repo/build.noindex/windows/package"
    Reset-BuildDirectory $package
    $helper = "$package/helper"
    $licenses = "$package/licenses"
    New-Item -ItemType Directory -Force $helper, $licenses | Out-Null
    Copy-Item "$swiftBin/digup.exe" $helper
    Copy-RuntimeDlls "$script:Vendor/llama/lib" $helper
    Copy-RuntimeDlls "$script:Vendor/pdfium/bin" $helper
    Copy-RuntimeDlls "$script:Vendor/ffmpeg/bin" $helper
    Copy-RuntimeDlls $SwiftRuntimeDirectory $helper
    Copy-Item "$script:Vendor/ffmpeg/bin/ffmpeg.exe", "$script:Vendor/ffmpeg/bin/ffprobe.exe" $helper
    # App-local VC runtimes remove a dependency on an elevated VC redistributable install.
    if (!$env:VCToolsRedistDir) { throw 'Use a VS 2022 x64 Native Tools environment (VCToolsRedistDir is absent).' }
    $crt = @(Get-ChildItem "$env:VCToolsRedistDir/x64" -Directory -Filter 'Microsoft.VC*.CRT')
    if ($crt.Count -ne 1) { throw 'Cannot uniquely locate the MSVC x64 redistributable CRT.' }
    Copy-RuntimeDlls $crt[0].FullName $helper
    Copy-RuntimeDlls $crt[0].FullName $package
    Copy-Item "$script:Repo/LICENSE", "$script:Repo/THIRD_PARTY_NOTICES.md", "$PSScriptRoot/dependencies.json" $licenses
    @{
        sourceCommit = (& git rev-parse HEAD)
        workingTreeDirty = [bool](& git status --porcelain)
        swift = $swiftVersion
        rust = $rustVersion
        tauriCli = $tauriVersion
        cmake = (& "$script:Vendor/cmake/bin/cmake.exe" --version | Select-Object -First 1)
        msvc = (Get-Item (Get-Command cl.exe).Source).VersionInfo.FileVersion
        windowsSdk = $env:WindowsSDKVersion
        buildOS = [Environment]::OSVersion.VersionString
        runnerImage = $env:ImageVersion
    } | ConvertTo-Json | Set-Content "$licenses/BUILD-VERSIONS.json" -Encoding utf8NoBOM
    Copy-Item "$script:Repo/Resources/Acknowledgements.txt" $licenses
    if (Test-Path "$script:Repo/Resources/WindowsNotices") { Copy-Item "$script:Repo/Resources/WindowsNotices" "$licenses/WindowsNotices" -Recurse }
    Copy-Item "$script:Vendor/llama.cpp/LICENSE" "$licenses/llama.cpp-MIT.txt"
    Copy-Item "$script:Vendor/ffmpeg/LICENSE.txt" "$licenses/FFmpeg-LGPL-2.1.txt"
    Copy-Item "$script:Vendor/ffmpeg/doc" "$licenses/FFmpeg-doc" -Recurse
    if (!(Test-Path "$script:Vendor/ffmpeg/source/ffmpeg-8.1.3.tar.xz")) { throw 'Native FFmpeg corresponding source is missing; run Build-FFmpeg.ps1.' }
    Copy-Item "$script:Vendor/miniz/miniz.c" "$licenses/miniz-source-and-license.c"
    Copy-Item "$script:Vendor/stb/include/*.h" $licenses
    if (Test-Path "$script:Vendor/pdfium/LICENSE") { Copy-Item "$script:Vendor/pdfium/LICENSE" "$licenses/PDFium-LICENSE.txt" }
    if (Test-Path "$script:Vendor/pdfium/licenses") { Copy-Item "$script:Vendor/pdfium/licenses" "$licenses/PDFium" -Recurse }
    Push-Location "$script:Repo/shell/src-tauri"
    try {
        Invoke-Checked cargo @('fmt', '--all', '--', '--check')
        if (!$SkipTests) {
            Invoke-Checked cargo @('clippy', '--locked', '--all-targets', '--', '-D', 'warnings')
            Invoke-Checked cargo @('test', '--locked')
        }
        $metadata = (& cargo metadata --locked --format-version 1 | ConvertFrom-Json)
        if ($LASTEXITCODE -ne 0) { throw 'cargo metadata failed.' }
        $metadata.packages | Select-Object name, version, license, repository | ConvertTo-Json -Depth 5 |
            Set-Content "$licenses/Rust-packages.json" -Encoding utf8NoBOM
        foreach ($crate in $metadata.packages) {
            $crateDir = Split-Path $crate.manifest_path
            $texts = @(Get-ChildItem -LiteralPath $crateDir -File | Where-Object Name -Match '^(LICENSE|LICENCE|COPYING|NOTICE|COPYRIGHT)')
            if ($texts.Count) {
                $dest = "$licenses/crates/$($crate.name)-$($crate.version)"
                New-Item -ItemType Directory -Force $dest | Out-Null
                $texts | Copy-Item -Destination $dest
            }
        }
        if ($env:DIGUP_CERT_THUMBPRINT) { & "$PSScriptRoot/Sign.ps1" -Path "$helper/digup.exe" }
        # Embed exact, Microsoft-signed bytes; the default install-time URL floats.
        $bootstrapper = Get-VerifiedDownload $script:Manifest.downloads.webviewBootstrapper
        $signature = Get-AuthenticodeSignature -LiteralPath $bootstrapper
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'CN=Microsoft Corporation,') {
            throw 'WebView2 bootstrapper does not have a valid Microsoft signature.'
        }
        $tauriTools = Join-Path $metadata.target_directory '.tauri'
        New-Item -ItemType Directory -Force $tauriTools | Out-Null
        Copy-Item -LiteralPath $bootstrapper -Destination "$tauriTools/MicrosoftEdgeWebview2Setup.exe" -Force
        $windows = @{
            nsis = @{ installMode = 'currentUser'; installerHooks = '../../scripts/windows/nsis-hooks.nsh' }
            webviewInstallMode = @{ type = 'embedBootstrapper'; silent = $true }
        }
        if ($env:DIGUP_CERT_THUMBPRINT) {
            $windows.signCommand = @{ cmd = 'pwsh'; args = @('-NoProfile', '-File', "$PSScriptRoot/Sign.ps1", '%1') }
        }
        $resources = @{
            '../../build.noindex/windows/package/helper/' = 'helper/'
            '../../build.noindex/windows/package/licenses/' = 'licenses/'
        }
        foreach ($dll in Get-ChildItem -LiteralPath $package -Filter '*.dll') {
            $resources["../../build.noindex/windows/package/$($dll.Name)"] = $dll.Name
        }
        $config = @{ bundle = @{ targets = @('nsis'); resources = $resources; windows = $windows; useLocalToolsDir = $true } }
        $configFile = "$script:Repo/build.noindex/windows/tauri.windows.generated.json"
        $config | ConvertTo-Json -Depth 12 | Set-Content $configFile -Encoding utf8NoBOM
        Invoke-Checked cargo @('tauri', 'build', '--config', $configFile, '--bundles', 'nsis', '--', '--locked')
    } finally { Pop-Location }
    Copy-Item "$script:Repo/shell/src-tauri/target/release/digup-shell.exe" "$package/DigUp.exe"
    & "$PSScriptRoot/Check-Runtime.ps1" -PackageDirectory $package
    $output = "$script:Repo/build.noindex/windows/artifacts"
    Reset-BuildDirectory $output
    Copy-Item "$script:Repo/shell/src-tauri/target/release/bundle/nsis/*-setup.exe" $output
    # ZIP timestamps cannot represent Unix epoch values used by some crate archives.
    Get-ChildItem -LiteralPath $package -File -Recurse | Where-Object LastWriteTimeUtc -LT ([DateTime]'1980-01-01Z') |
        ForEach-Object { $_.LastWriteTimeUtc = [DateTime]'1980-01-01Z' }
    Compress-Archive -Path "$package/*" -DestinationPath "$output/DigUp-windows-x64-portable.zip"
    Compress-Archive -Path "$script:Vendor/ffmpeg/source/*" -DestinationPath "$output/DigUp-FFmpeg-8.1.3-source.zip"
    Get-ChildItem -LiteralPath $output -File | Sort-Object Name | ForEach-Object {
        "$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())  $($_.Name)"
    } | Set-Content "$output/SHA256SUMS.txt" -Encoding ascii
    Write-Host "Built artifacts: $output"
} finally { $env:PATH = $originalPath; $env:DIGUP_CPU_ONLY = $originalCpuOnly }
