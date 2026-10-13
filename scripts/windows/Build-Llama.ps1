#requires -Version 7.2
param(
    [int]$Jobs = [Math]::Max(1, [Environment]::ProcessorCount - 1),
    [switch]$CpuOnly,
    [string]$Destination
)
. "$PSScriptRoot/Common.ps1"
Set-Location $script:Repo
$source = "$script:Vendor/llama.cpp"
$backend = if ($CpuOnly) { 'cpu' } else { 'vulkan' }
$build = "$script:Vendor/llama-ninja-$backend-build"
$out = if ($Destination) { [IO.Path]::GetFullPath($Destination, $script:Repo) } else { "$script:Vendor/llama" }
$cmake = "$script:Vendor/cmake/bin/cmake.exe"
if (!(Test-Path $cmake)) { throw 'Run scripts/windows/Fetch-Vendor.ps1 first.' }
$ninjaDirectory = "$script:Vendor/ninja"
Reset-BuildDirectory $ninjaDirectory
Expand-NativeArchive (Get-VerifiedDownload $script:Manifest.downloads.ninja) $ninjaDirectory
if (!(Test-Path "$source/.git")) {
    Invoke-Checked git @('-c', 'core.autocrlf=false', 'clone', '--no-checkout', '--filter=blob:none', $script:Manifest.llama.url, $source)
}
Invoke-Checked git @('-C', $source, 'fetch', '--depth', '1', 'origin', $script:Manifest.llama.commit)
$head = & git -C $source rev-parse HEAD 2>$null
if ($head -ne $script:Manifest.llama.commit) {
    Invoke-Checked git @('-C', $source, 'checkout', '--detach', $script:Manifest.llama.commit)
}
$patch = Join-Path $script:Repo 'scripts/llama.cpp-no-logits.patch'
& git -C $source apply --check $patch 2>$null
if ($LASTEXITCODE -eq 0) { Invoke-Checked git @('-C', $source, 'apply', $patch) }
else { Invoke-Checked git @('-C', $source, 'apply', '--reverse', '--check', $patch) }
$vulkanArgs = @('-DGGML_VULKAN=OFF')
$sdk = $null
if (!$CpuOnly) {
    # The core payload is embedded in the SHA-pinned installer. copy_only avoids
    # installing drivers/layers, changing the registry or changing the user's PATH.
    $sdkArchive = Get-VerifiedDownload $script:Manifest.downloads.vulkanSdk
    $sdk = "$script:Vendor/vulkan-sdk-$($script:Manifest.tools.vulkanSdk)"
    # Restrict Qt Installer Framework to an empty local repository: only the
    # checksummed embedded core is installed, never optional online packages.
    $metadata = "$script:Vendor/vulkan-offline-metadata"
    Reset-BuildDirectory $metadata
    [IO.File]::WriteAllText("$metadata/Updates.xml", '<?xml version="1.0"?><Updates/>')
    $metadataUri = ([Uri]([IO.Path]::GetFullPath($metadata) + '/')).AbsoluteUri
    Reset-BuildDirectory $sdk
    Invoke-BoundedChecked $sdkArchive @('--root', $sdk, '--set-temp-repository', $metadataUri,
        '--cache-path', "$metadata/cache", '--accept-licenses', '--default-answer',
        '--confirm-command', 'install', 'com.lunarg.vulkan.core', 'copy_only=1') `
        -TimeoutSeconds 600 -Phase 'copy-only pinned Vulkan SDK'
    foreach ($required in @('Bin/glslc.exe', 'Lib/vulkan-1.lib', 'Include/vulkan/vulkan.hpp',
            'Include/spirv-headers/spirv.hpp', 'Lib/cmake/SPIRV-Headers/SPIRV-HeadersConfig.cmake')) {
        if (!(Test-Path -LiteralPath "$sdk/$required")) { throw "Vulkan SDK is missing $required" }
    }
    Invoke-BoundedChecked "$sdk/Bin/glslc.exe" @('--version') -TimeoutSeconds 20 -Phase 'pinned glslc version'
    $vulkanArgs = @('-DGGML_VULKAN=ON', "-DVulkan_INCLUDE_DIR=$sdk/Include", "-DVulkan_LIBRARY=$sdk/Lib/vulkan-1.lib",
        "-DVulkan_GLSLC_EXECUTABLE=$sdk/Bin/glslc.exe", "-DSPIRV-Headers_DIR=$sdk/Lib/cmake/SPIRV-Headers")
}
$compiler = (Get-Command cl.exe -ErrorAction Stop).Source
$configure = @('-S', $source, '-B', $build, '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release',
    "-DCMAKE_MAKE_PROGRAM=$ninjaDirectory/ninja.exe", "-DCMAKE_C_COMPILER=$compiler", "-DCMAKE_CXX_COMPILER=$compiler",
    '-DBUILD_SHARED_LIBS=ON', '-DGGML_BACKEND_DL=ON', '-DGGML_CPU_ALL_VARIANTS=ON', '-DGGML_NATIVE=OFF',
    '-DGGML_CUDA=OFF', '-DGGML_METAL=OFF', '-DGGML_OPENMP=OFF',
    '-DLLAMA_BUILD_MTMD=ON', '-DLLAMA_BUILD_COMMON=OFF', '-DLLAMA_BUILD_TOOLS=OFF', '-DLLAMA_BUILD_SERVER=OFF',
    '-DLLAMA_BUILD_EXAMPLES=OFF', '-DLLAMA_BUILD_TESTS=OFF', '-DLLAMA_BUILD_APP=OFF', '-DLLAMA_BUILD_UI=OFF',
    '-DLLAMA_OPENSSL=OFF', '-DLLAMA_CURL=OFF') + $vulkanArgs
# Ninja avoids MSBuild FileTracker's MAX_PATH limit inside upstream's deeply
# nested shader-generator sub-build. Its ExternalProject inherits this generator
# and needs the same pinned ninja on the process PATH; restore it before returning.
$originalPath = $env:PATH
try {
    $env:PATH = "$ninjaDirectory;$originalPath"
    Invoke-BoundedChecked $cmake $configure -TimeoutSeconds 300 -Phase "configure llama CPU/$backend"
    Invoke-BoundedChecked $cmake @('--build', $build, '--config', 'Release', '--parallel', "$Jobs") `
        -TimeoutSeconds 3600 -Phase "build llama CPU/$backend"
} finally { $env:PATH = $originalPath }
Reset-BuildDirectory $out
New-Item -ItemType Directory -Force "$out/lib", "$out/include" | Out-Null
Get-ChildItem "$build/bin/*.dll" | Copy-Item -Destination "$out/lib"
foreach ($name in @('llama.lib', 'mtmd.lib', 'ggml.lib', 'ggml-base.lib')) {
    $lib = Get-ChildItem -LiteralPath $build -Filter $name -Recurse -File | Select-Object -First 1
    if (!$lib) { throw "Build did not produce $name" }
    Copy-Item -LiteralPath $lib.FullName -Destination "$out/lib"
}
Copy-Item "$source/include/llama.h", "$source/ggml/include/*.h", "$source/tools/mtmd/mtmd.h", "$source/tools/mtmd/mtmd-helper.h" "$out/include"
"#define LLAMA_BUILD_TAG `"$($script:Manifest.llama.tag)`"" | Set-Content "$out/include/llama-build.h" -Encoding utf8NoBOM
if (!$CpuOnly) {
    if (!(Test-Path "$out/lib/ggml-vulkan.dll")) { throw 'The Vulkan build did not produce ggml-vulkan.dll.' }
    New-Item -ItemType Directory -Force "$out/licenses" | Out-Null
    foreach ($notice in @('vulkanHeadersLicense', 'vulkanApacheLicense', 'vulkanMitLicense', 'spirvHeadersLicense')) {
        Copy-Item -LiteralPath (Get-VerifiedDownload $script:Manifest.downloads.$notice) -Destination "$out/licenses"
    }
    # Keep the exact generated header copyright notices next to their full licenses.
    Copy-Item "$sdk/Include/vulkan/vulkan_core.h", "$sdk/Include/vulkan/vulkan.hpp", `
        "$sdk/Include/spirv-headers/spirv.hpp" "$out/licenses"
    [ordered]@{ sdk = $script:Manifest.tools.vulkanSdk; archive = $script:Manifest.downloads.vulkanSdk;
        runtime = 'ggml-vulkan.dll'; optionalDriverDependency = 'vulkan-1.dll (provided by the GPU vendor driver)';
        minimumVulkan = '1.2'; notices = @('vulkanHeadersLicense', 'vulkanApacheLicense', 'vulkanMitLicense', 'spirvHeadersLicense') |
            ForEach-Object { $script:Manifest.downloads.$_ }
    } | ConvertTo-Json -Depth 5 | Set-Content "$out/licenses/Vulkan-SOURCES.json" -Encoding utf8NoBOM
}
$builtBackends = if ($CpuOnly) { 'cpu' } else { 'cpu+vulkan' }
"$($script:Manifest.llama.commit) $builtBackends $((Get-FileHash $patch).Hash)" | Set-Content "$out/BUILD"
