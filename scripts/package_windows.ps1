$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$pubspec = Get-Content -LiteralPath (Join-Path $projectRoot 'src/small_orbit/pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\+(\d+)\s*$') { throw 'Invalid pubspec version: expected name+build' }
$releaseVersion = $Matches[1]
$buildNumber = $Matches[2]
$releaseDirectory = Join-Path $projectRoot 'src/small_orbit/build/windows/x64/runner/Release'
$distDirectory = Join-Path $projectRoot 'dist'
$bundleDirectory = Join-Path $distDirectory "small_orbit-$releaseVersion-windows-x64"
if (-not (Test-Path -LiteralPath (Join-Path $releaseDirectory 'small_orbit.exe'))) { throw 'Build the Windows app first.' }
$binaryVersion = (Get-Item -LiteralPath (Join-Path $releaseDirectory 'small_orbit.exe')).VersionInfo.ProductVersion
if ($binaryVersion -ne "$releaseVersion+$buildNumber") { throw "Build version $binaryVersion differs from pubspec; rebuild before packaging." }
New-Item -ItemType Directory -Force -Path $bundleDirectory | Out-Null
Copy-Item -Path (Join-Path $releaseDirectory '*') -Destination $bundleDirectory -Recurse -Force
$vswhere = 'C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe'
$vsRoot = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$redistRoot = Join-Path $vsRoot 'VC/Redist/MSVC'
$versionDirectory = Get-ChildItem -LiteralPath $redistRoot -Directory | Where-Object Name -Match '^\d+\.\d+\.\d+$' | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
$crtDirectory = Get-ChildItem -LiteralPath (Join-Path $versionDirectory.FullName 'x64') -Directory | Where-Object Name -Match '^Microsoft\.VC\d+\.CRT$' | Select-Object -First 1
if (-not $crtDirectory) { throw 'Visual C++ redistribution runtime is unavailable.' }
Copy-Item -Path (Join-Path $crtDirectory.FullName '*.dll') -Destination $bundleDirectory -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'docs/user_guide.md') -Destination (Join-Path $bundleDirectory '使用说明.md') -Force
$archive = Join-Path $distDirectory "small_orbit-$releaseVersion-windows-x64.zip"
Compress-Archive -Path $bundleDirectory -DestinationPath $archive -Force
Get-FileHash -LiteralPath $archive -Algorithm SHA256 | Select-Object Path,Hash
