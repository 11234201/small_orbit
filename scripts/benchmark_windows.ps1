param([int]$Runs = 3)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Use PowerShell 7 for this developer benchmark.' }
if ($Runs -lt 1 -or $Runs -gt 10) { throw 'Runs must be 1-10.' }
$projectRoot = Split-Path -Parent $PSScriptRoot
$pubspec = Get-Content -LiteralPath (Join-Path $projectRoot 'src/small_orbit/pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\+\d+\s*$') { throw 'Invalid version' }
$releaseVersion = $Matches[1]
$executable = Join-Path $projectRoot "dist/small_orbit-$releaseVersion-windows-x64/small_orbit.exe"
if (-not (Test-Path -LiteralPath $executable)) { throw 'Package the Windows release first.' }
if (Get-Process small_orbit -ErrorAction SilentlyContinue) { throw 'Close existing Small Orbit instances before this isolated measurement.' }
$runStamp = (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [Guid]::NewGuid().ToString('N').Substring(0,8)
$probeRoot = Join-Path $projectRoot ".qa_data/windows_probe_$runStamp"
$results = [Collections.Generic.List[object]]::new()
$priorDataDirectory = $env:SMALL_ORBIT_DATA_DIR
$priorDiagnostics = $env:SMALL_ORBIT_DIAGNOSTICS
try {
    foreach ($count in @(0, 100, 1000)) {
        for ($run = 1; $run -le $Runs; $run++) {
            $dataDirectory = Join-Path $probeRoot "tasks_${count}_run_$run"
            New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null
            $tasks = @()
            for ($i = 0; $i -lt $count; $i++) {
                $tasks += @{ id = "probe_$i"; title = "测试小事 $i"; createdAt = '2026-11-10T00:00:00.000Z'; date = $null; reminderMinute = $null; repeat = 'none'; importance = 2; urgency = 2; records = @{} }
            }
            $payload = @{ settings = @{ display = 'bubbles'; motion = 'opening'; paused = $false; reduceMotion = $false; remindersEnabled = $false }; tasks = $tasks } | ConvertTo-Json -Depth 12 -Compress
            $digest = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($payload))
            $encoded = @{ format = 'small-orbit'; version = 1; savedAt = '2026-11-10T00:00:00.000Z'; payload = $payload; sha256 = [Convert]::ToHexString($digest).ToLowerInvariant() } | ConvertTo-Json -Compress
            [IO.File]::WriteAllText((Join-Path $dataDirectory 'tasks.json'), $encoded, [Text.UTF8Encoding]::new($false))
            $env:SMALL_ORBIT_DATA_DIR = $dataDirectory
            $env:SMALL_ORBIT_DIAGNOSTICS = '1'
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $launchAtUtc = [DateTime]::UtcNow
            $process = Start-Process -FilePath $executable -WorkingDirectory (Split-Path $executable) -WindowStyle Hidden -PassThru
            $launchCallMs = $watch.Elapsed.TotalMilliseconds
            try {
                $readyPath = Join-Path $dataDirectory 'readiness.json'
                while (-not (Test-Path -LiteralPath $readyPath)) {
                    $process.Refresh()
                    if ($process.HasExited -or $watch.Elapsed.TotalSeconds -gt 30) { throw "Startup marker unavailable for $count tasks, run $run" }
                    Start-Sleep -Milliseconds 25
                }
                $launchMs = $watch.Elapsed.TotalMilliseconds
                $marker = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
                # PowerShell 7.5 converts JSON ISO strings to DateTime already.
                # Parsing that object as a string would drop its Utc Kind.
                $readyUtc = if ($marker.readyAtUtc -is [DateTime]) {
                    $marker.readyAtUtc.ToUniversalTime()
                } else { [DateTimeOffset]::Parse([string]$marker.readyAtUtc).UtcDateTime }
                $markerTimestampMs = ($readyUtc - $launchAtUtc).TotalMilliseconds
                if ($markerTimestampMs -lt 0 -or $markerTimestampMs -gt ($launchMs + 1000)) { throw 'Startup clock comparison is inconsistent; discard this timing sample.' }
                Start-Sleep -Seconds 2
                $process.Refresh()
                $cpuStart = $process.TotalProcessorTime.TotalMilliseconds
                $idleWatch = [Diagnostics.Stopwatch]::StartNew()
                Start-Sleep -Seconds 2
                $process.Refresh()
                $cpuPercent = 100 * ($process.TotalProcessorTime.TotalMilliseconds - $cpuStart) / $idleWatch.Elapsed.TotalMilliseconds
                $memoryMb = $process.WorkingSet64 / 1MB
                if (-not $process.WaitForExit(12000)) { throw 'Diagnostic app did not finish its graceful exit.' }
                if ($process.ExitCode -ne 0) { throw "Diagnostic process failed with $($process.ExitCode)" }
                $results.Add([pscustomobject]@{ tasks = $count; run = $run; launchAtUtc = $launchAtUtc.ToString('O'); readyAtUtc = $readyUtc.ToString('O'); launchToMarkerMs = [math]::Round($launchMs, 2); launchCallMs = [math]::Round($launchCallMs, 2); markerTimestampMs = [math]::Round($markerTimestampMs, 2); dartDataReadyMs = $marker.dataReadyMs; dartFirstFrameMs = $marker.firstFrameMs; hiddenCpuPercentOfOneCore = [math]::Round($cpuPercent, 3); workingSetMb = [math]::Round($memoryMb, 2); exitCode = $process.ExitCode })
                Write-Output "Measured $count tasks, run $run; graceful exit succeeded."
            } finally {
                $process.Refresh()
                if (-not $process.HasExited) {
                    $owned = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
                    if ($owned -and $owned.Path -eq $executable) { Stop-Process -Id $owned.Id }
                }
            }
        }
    }
} finally {
    if ($null -eq $priorDataDirectory) { Remove-Item Env:SMALL_ORBIT_DATA_DIR -ErrorAction SilentlyContinue } else { $env:SMALL_ORBIT_DATA_DIR = $priorDataDirectory }
    if ($null -eq $priorDiagnostics) { Remove-Item Env:SMALL_ORBIT_DIAGNOSTICS -ErrorAction SilentlyContinue } else { $env:SMALL_ORBIT_DIAGNOSTICS = $priorDiagnostics }
    $output = Join-Path $projectRoot "logs/windows_probe_$releaseVersion.json"
    @{ version = $releaseVersion; os = [Environment]::OSVersion.VersionString; logicalProcessors = [Environment]::ProcessorCount; note = 'Sequential ordinary launches with warm filesystem caches, hidden window. markerTimestampMs compares UTC start time to Dart first-frame marker timestamp; launchToMarkerMs includes Start-Process overhead and 25ms polling. Not cold-cache or visible interaction. CPU sampled seconds 2-4 after marker detection.'; samples = @($results.ToArray()); dataRoot = $probeRoot } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $output
}
