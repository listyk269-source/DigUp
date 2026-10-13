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
            Write-Host "Verified cached download: $($Spec.file)"
            return $destination
        }
        Remove-Item -LiteralPath $destination -Force
    }
    $partial = "$destination.partial"
    $curl = Join-Path $env:SystemRoot 'System32/curl.exe'
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        # A partial remains on network errors. curl verifies TLS and resumes via HTTP Range.
        Write-Host "Downloading $($Spec.file), attempt $attempt/3: $($Spec.url)"
        & $curl --fail --location --silent --show-error --retry 2 --retry-delay 2 --retry-max-time 120 `
            --connect-timeout 20 --max-time 300 --speed-time 60 --speed-limit 1024 `
            --continue-at - --output $partial $Spec.url
        if ($LASTEXITCODE -eq 0 -and (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -eq $Spec.sha256) {
            Move-Item -LiteralPath $partial -Destination $destination -Force
            return $destination
        }
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 33 -or $LASTEXITCODE -eq 36) {
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
