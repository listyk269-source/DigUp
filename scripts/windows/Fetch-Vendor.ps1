#requires -Version 7.2
. "$PSScriptRoot/Common.ps1"
if (!$IsWindows) { throw 'This entry point vendors Windows x64 libraries. Other platforms use scripts/fetch-vendor.sh.' }
Set-Location $script:Repo
$tmp = Join-Path $script:Vendor 'windows-fetch'
Reset-BuildDirectory $tmp

$sqlite = Get-VerifiedDownload $script:Manifest.downloads.sqlite
Expand-Archive -LiteralPath $sqlite -DestinationPath "$tmp/sqlite"
New-Item -ItemType Directory -Force "$script:Vendor/sqlite/include" | Out-Null
Get-ChildItem "$tmp/sqlite/*/sqlite3.c" | Copy-Item -Destination "$script:Vendor/sqlite"
Get-ChildItem "$tmp/sqlite/*/sqlite3.h" | Copy-Item -Destination "$script:Vendor/sqlite/include"

New-Item -ItemType Directory -Force "$script:Vendor/stb/include" | Out-Null
foreach ($name in @('stbImage', 'stbWrite', 'stbResize')) {
    Copy-Item -LiteralPath (Get-VerifiedDownload $script:Manifest.downloads.$name) -Destination "$script:Vendor/stb/include"
}
@'
#define STB_IMAGE_IMPLEMENTATION
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb_image.h"
#include "stb_image_write.h"
#include "stb_image_resize2.h"
'@ | Set-Content "$script:Vendor/stb/stb.c" -Encoding utf8NoBOM

Expand-Archive -LiteralPath (Get-VerifiedDownload $script:Manifest.downloads.miniz) -DestinationPath "$tmp/miniz"
New-Item -ItemType Directory -Force "$script:Vendor/miniz/include" | Out-Null
Copy-Item "$tmp/miniz/miniz.c" "$script:Vendor/miniz"
Copy-Item "$tmp/miniz/*.h" "$script:Vendor/miniz/include"

Reset-BuildDirectory "$script:Vendor/pdfium"
Expand-NativeArchive (Get-VerifiedDownload $script:Manifest.downloads.pdfium) "$script:Vendor/pdfium"
Copy-Item "$script:Vendor/pdfium/lib/pdfium.dll.lib" "$script:Vendor/pdfium/lib/pdfium.lib"

# Expand-NativeArchive bootstrapped the same pinned CMake used by Build-Llama.
Write-Host 'Verified Windows dependencies are ready in Vendor/.'
