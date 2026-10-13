#requires -Version 7.2
param([int]$Jobs = [Math]::Max(1, [Environment]::ProcessorCount - 1))
. "$PSScriptRoot/Common.ps1"
Set-Location $script:Repo
$source = "$script:Vendor/llama.cpp"
$build = "$script:Vendor/llama-windows-build"
$out = "$script:Vendor/llama"
$cmake = "$script:Vendor/cmake/bin/cmake.exe"
if (!(Test-Path $cmake)) { throw 'Run scripts/windows/Fetch-Vendor.ps1 first.' }
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
Invoke-Checked $cmake @('-S', $source, '-B', $build, '-G', 'Visual Studio 17 2022', '-A', 'x64',
    '-DBUILD_SHARED_LIBS=ON', '-DGGML_BACKEND_DL=ON', '-DGGML_CPU_ALL_VARIANTS=ON', '-DGGML_NATIVE=OFF',
    '-DGGML_CUDA=OFF', '-DGGML_VULKAN=OFF', '-DGGML_METAL=OFF', '-DGGML_OPENMP=OFF',
    '-DLLAMA_BUILD_MTMD=ON', '-DLLAMA_BUILD_COMMON=OFF', '-DLLAMA_BUILD_TOOLS=OFF', '-DLLAMA_BUILD_SERVER=OFF',
    '-DLLAMA_BUILD_EXAMPLES=OFF', '-DLLAMA_BUILD_TESTS=OFF', '-DLLAMA_BUILD_APP=OFF', '-DLLAMA_BUILD_UI=OFF',
    '-DLLAMA_OPENSSL=OFF', '-DLLAMA_CURL=OFF')
Invoke-Checked $cmake @('--build', $build, '--config', 'Release', '--parallel', "$Jobs")
Reset-BuildDirectory $out
New-Item -ItemType Directory -Force "$out/lib", "$out/include" | Out-Null
Get-ChildItem "$build/bin/Release/*.dll" | Copy-Item -Destination "$out/lib"
foreach ($name in @('llama.lib', 'mtmd.lib', 'ggml.lib', 'ggml-base.lib')) {
    $lib = Get-ChildItem -LiteralPath $build -Filter $name -Recurse -File | Select-Object -First 1
    if (!$lib) { throw "Build did not produce $name" }
    Copy-Item -LiteralPath $lib.FullName -Destination "$out/lib"
}
Copy-Item "$source/include/llama.h", "$source/ggml/include/*.h", "$source/tools/mtmd/mtmd.h", "$source/tools/mtmd/mtmd-helper.h" "$out/include"
"#define LLAMA_BUILD_TAG `"$($script:Manifest.llama.tag)`"" | Set-Content "$out/include/llama-build.h" -Encoding utf8NoBOM
"$($script:Manifest.llama.commit) cpu $((Get-FileHash $patch).Hash)" | Set-Content "$out/BUILD"
