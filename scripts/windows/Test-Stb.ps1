#requires -Version 7.2
. "$PSScriptRoot/Common.ps1"
if (!$IsWindows) { throw 'The native STB handle-inheritance regression test requires Windows.' }
Set-Location $script:Repo
$testDirectory = Join-Path $script:Repo 'build.noindex/windows/stb-test'
New-Item -ItemType Directory -Force $testDirectory | Out-Null
$executable = Join-Path $testDirectory 'stb-handles.exe'
# PATH may contain the same toolchain with both slash forms; preserve its first match.
$compiler = (Get-Command clang-cl.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
Invoke-BoundedChecked $compiler @('/nologo', '/MD', '/O1', '/wd4996',
    "/I$script:Vendor/stb/include", "$script:Repo/Tests/CStbWindows/HandleInheritance.c",
    "/Fe$executable", "/Fo$testDirectory/stb-handles.obj") -TimeoutSeconds 120 -Phase 'compile STB handle regression'
Invoke-BoundedChecked $executable @("$testDirectory/кириллица preview.png") -TimeoutSeconds 30 -Phase 'STB non-inherited reader and writer handles'
