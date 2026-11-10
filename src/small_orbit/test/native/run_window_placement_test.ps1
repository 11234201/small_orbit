$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
$nativeBuildDirectory = Join-Path $projectRoot '.build_cache/windows_native_test'
$testDataDirectory = Join-Path $projectRoot '.qa_data/windows_native_test'
$ephemeral = Join-Path $projectRoot 'src/small_orbit/windows/flutter/ephemeral'
$runner = Join-Path $projectRoot 'src/small_orbit/windows/runner'
if (-not (Test-Path -LiteralPath (Join-Path $ephemeral 'flutter_windows.dll.lib'))) {
    throw 'Prepare the existing Windows Flutter build first; this test does not download dependencies.'
}
New-Item -ItemType Directory -Force -Path $nativeBuildDirectory, $testDataDirectory | Out-Null
$vsRoot = & 'C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe' -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsRoot) { throw 'MSVC C++ tools are required for this Windows-specific test.' }
$vcvars = Join-Path $vsRoot 'VC/Auxiliary/Build/vcvars64.bat'
$buildScript = @"
@echo off
call "$vcvars" >nul
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /DUNICODE /D_UNICODE /DNOMINMAX /utf-8 /I"$ephemeral" /I"$runner" /FeWindowPlacementTest.exe "$PSScriptRoot/WindowPlacementTest.cpp" "$runner/WindowPlacement.cpp" /link "$ephemeral/flutter_windows.dll.lib" user32.lib shell32.lib
exit /b %errorlevel%
"@
$buildScriptPath = Join-Path $nativeBuildDirectory 'build.cmd'
[IO.File]::WriteAllText($buildScriptPath, $buildScript, [Text.Encoding]::Default)
$previousPath = $env:PATH
Push-Location $nativeBuildDirectory
try {
    & $buildScriptPath
    if ($LASTEXITCODE -ne 0) { throw 'Window placement native compilation failed' }
    $env:PATH = "$ephemeral;$previousPath"
    & (Join-Path $nativeBuildDirectory 'WindowPlacementTest.exe') $testDataDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Window placement native test failed' }
} finally {
    $env:PATH = $previousPath
    Pop-Location
}
