param([switch]$SkipPub)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$flutter = Join-Path $projectRoot '.toolchain/flutter/bin/flutter.bat'
if (-not (Test-Path -LiteralPath $flutter)) { throw 'Prepare the scoped Windows Flutter SDK first; see docs/build.md.' }
$env:CI = 'true'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:PUB_HOSTED_URL = 'https://pub.dev'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:PUB_CACHE = Join-Path $projectRoot '.toolchain/pub_cache'
$appDirectory = Join-Path $projectRoot 'src/small_orbit'
Push-Location $appDirectory
try {
    if (-not $SkipPub) {
        $pubOutput = & $flutter pub get 2>&1
        $pubExit = $LASTEXITCODE
        $pubOutput | Write-Output
        if ($pubExit -ne 0 -and ($pubOutput -join "`n") -match 'requires symlink support') {
            $plugins = Get-Content -LiteralPath '.flutter-plugins-dependencies' -Raw | ConvertFrom-Json
            $linkRoot = Join-Path $appDirectory 'windows/flutter/ephemeral/.plugin_symlinks'
            New-Item -ItemType Directory -Force -Path $linkRoot | Out-Null
            $cacheRoot = [IO.Path]::GetFullPath($env:PUB_CACHE).TrimEnd('\') + '\'
            foreach ($plugin in $plugins.plugins.windows) {
                $targetPath = (Resolve-Path -LiteralPath $plugin.path).Path
                if (-not $targetPath.StartsWith($cacheRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Plugin target is outside this project cache.' }
                $linkPath = Join-Path $linkRoot $plugin.name
                if (-not (Test-Path -LiteralPath $linkPath)) {
                    New-Item -ItemType Junction -Path $linkPath -Target $targetPath | Out-Null
                }
            }
            & $flutter pub get
            $pubExit = $LASTEXITCODE
        }
        if ($pubExit -ne 0) { throw 'flutter pub get failed' }
    }
    & $flutter build windows --release --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Windows release build failed' }
} finally { Pop-Location }
