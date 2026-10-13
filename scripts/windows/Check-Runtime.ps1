#requires -Version 7.2
param([Parameter(Mandatory)][string]$PackageDirectory)
$ErrorActionPreference = 'Stop'
$package = [IO.Path]::GetFullPath($PackageDirectory)
$dumpbin = (Get-Command dumpbin.exe -ErrorAction Stop).Source
$system = [Environment]::GetFolderPath('System')
$files = @(Get-ChildItem -LiteralPath $package -File -Recurse | Where-Object Extension -In '.exe', '.dll')
if (!$files.Count) { throw 'The package contains no executables or DLLs.' }
$inventory = foreach ($file in $files) {
    $lines = & $dumpbin /nologo /dependents $file.FullName
    if ($LASTEXITCODE) { throw "Cannot inspect imports: $($file.Name)" }
    $imports = @($lines | ForEach-Object {
        if ($_ -match '^\s+([A-Za-z0-9_.+-]+\.dll)\s*$') { $Matches[1] }
    } | Sort-Object -Unique)
    foreach ($import in $imports) {
        # Windows API-set contracts resolve through the OS loader, not a disk file.
        if ($import -match '^(api|ext)-ms-win-') { continue }
        if (!(Test-Path -LiteralPath (Join-Path $file.DirectoryName $import)) -and
            !(Test-Path -LiteralPath (Join-Path $system $import))) {
            throw "Unpackaged runtime dependency: $($file.Name) -> $import"
        }
        # A build machine may have vendor DLLs in System32. Only explicit OS DLLs may rely on it.
        if ($import -match '^(swift|Foundation|_Foundation|BlocksRuntime|dispatch|llama|mtmd|ggml|pdfium|avcodec|avformat|avutil|avfilter|swresample|swscale|vcruntime|msvcp|concrt)' -and
            !(Test-Path -LiteralPath (Join-Path $file.DirectoryName $import))) {
            throw "Application runtime must be app-local: $($file.Name) -> $import"
        }
    }
    [ordered]@{
        file = [IO.Path]::GetRelativePath($package, $file.FullName)
        bytes = $file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        imports = $imports
    }
}
$inventory | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $package 'runtime-inventory.json') -Encoding utf8NoBOM
Write-Host "Validated imports for $($files.Count) native files; runtime-inventory.json records their hashes."
