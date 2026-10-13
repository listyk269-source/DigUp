# Dot-source after installing Swift and the VS 2022 Desktop development with C++ workload.
#requires -Version 7.2
. "$PSScriptRoot/Common.ps1"
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
if (!(Test-Path $vswhere)) { throw 'Install Visual Studio 2022 Build Tools with the C++ workload first.' }
$vs = & $vswhere -latest -version '[17.0,18.0)' -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$vs) { throw 'Visual Studio 2022 C++ tools were not found.' }
$devShell = Join-Path $vs 'Common7/Tools/Microsoft.VisualStudio.DevShell.dll'
Import-Module $devShell
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
$swiftRoots = @("$env:LOCALAPPDATA/Programs/Swift", "${env:ProgramFiles}/Swift")
$existingSwift = Get-Command swift.exe -ErrorAction SilentlyContinue
if ($existingSwift -and $existingSwift.Source -match '^(.*)[\\/]Toolchains[\\/]') { $swiftRoots += $Matches[1] }
$swiftRoot = $swiftRoots | Where-Object { Test-Path "$_/Toolchains/$($script:Manifest.tools.swift)+Asserts/usr/bin/swift.exe" } | Select-Object -First 1
if (!$swiftRoot) { throw "Install Swift $($script:Manifest.tools.swift) first." }
$env:SDKROOT = "$swiftRoot/Platforms/$($script:Manifest.tools.swift)/Windows.platform/Developer/SDKs/Windows.sdk"
$env:DIGUP_SWIFT_RUNTIME = "$swiftRoot/Runtimes/$($script:Manifest.tools.swift)/usr/bin"
$env:PATH = "$swiftRoot/Toolchains/$($script:Manifest.tools.swift)+Asserts/usr/bin;$env:DIGUP_SWIFT_RUNTIME;$env:PATH"
