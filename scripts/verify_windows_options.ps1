param([string]$Executable)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $Executable) {
    $pubspec = Get-Content (Join-Path $projectRoot 'src/small_orbit/pubspec.yaml') -Raw
    if ($pubspec -notmatch '(?m)^version:\s*([^+\s]+)\+\d+\s*$') { throw 'Invalid version' }
    $Executable = Join-Path $projectRoot "dist/small_orbit-$($Matches[1])-windows-x64/small_orbit.exe"
}
$Executable = (Resolve-Path -LiteralPath $Executable).Path
if (Get-Process small_orbit -ErrorAction SilentlyContinue) { throw 'An existing Small Orbit process is running; keep it untouched and defer this isolated check.' }
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class OrbitOptionsProbe {
    public delegate bool EnumCallback(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumCallback callback, IntPtr parameter);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr window, StringBuilder text, int length);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    public static IntPtr Find(uint processId) {
        IntPtr result = IntPtr.Zero;
        EnumWindows((window, parameter) => {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner != processId) return true;
            var name = new StringBuilder(256);
            GetClassName(window, name, name.Capacity);
            if (name.ToString() != "FLUTTER_RUNNER_WIN32_WINDOW") return true;
            result = window;
            return false;
        }, IntPtr.Zero);
        return result;
    }
}
'@
$runStamp = (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [Guid]::NewGuid().ToString('N').Substring(0,8)
$probeRoot = Join-Path $projectRoot ".qa_data/windows_options_$runStamp"
$priorDataDirectory = $env:SMALL_ORBIT_DATA_DIR
$priorDiagnostics = $env:SMALL_ORBIT_DIAGNOSTICS
try {
    foreach ($pinned in @(0, 1)) {
        $dataDirectory = Join-Path $probeRoot "pin_$pinned"
        New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null
        $preference = Join-Path $dataDirectory 'window_options-v1.txt'
        [IO.File]::WriteAllText($preference, "2 $pinned $pinned 100`n", [Text.UTF8Encoding]::new($false))
        $env:SMALL_ORBIT_DATA_DIR = $dataDirectory
        $env:SMALL_ORBIT_DIAGNOSTICS = '1'
        $process = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) -WindowStyle Hidden -PassThru
        try {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $ready = Join-Path $dataDirectory 'readiness.json'
            while (-not (Test-Path -LiteralPath $ready)) {
                $process.Refresh()
                if ($process.HasExited -or $watch.Elapsed.TotalSeconds -gt 30) { throw 'Diagnostic startup did not finish' }
                Start-Sleep -Milliseconds 25
            }
            $window = [OrbitOptionsProbe]::Find([uint32]$process.Id)
            if ($window -eq [IntPtr]::Zero) { throw 'Owned Flutter window not found' }
            for ($cycle = 0; $cycle -lt 3; $cycle++) {
                if ($cycle -gt 0) {
                    $outsideX = [OrbitOptionsProbe]::GetSystemMetrics(76) - 4000
                    $outsideY = [OrbitOptionsProbe]::GetSystemMetrics(77) - 4000
                    if (-not [OrbitOptionsProbe]::SetWindowPos($window, [IntPtr]::Zero, $outsideX, $outsideY, 0, 0, 0x15)) { throw 'Could not place isolated window offscreen' }
                    [void][OrbitOptionsProbe]::ShowWindow($window, 4)
                    Start-Sleep -Milliseconds 200
                }
                $top = ([OrbitOptionsProbe]::GetWindowLongPtr($window, -20).ToInt64() -band 8) -ne 0
                $caption = ([OrbitOptionsProbe]::GetWindowLongPtr($window, -16).ToInt64() -band 0xC00000) -eq 0xC00000
                if ($top -ne ($pinned -eq 1) -or $caption -ne ($pinned -eq 0)) { throw "Native option mismatch: pin=$pinned cycle=$cycle top=$top caption=$caption" }
                if ([OrbitOptionsProbe]::GetForegroundWindow() -eq $window) { throw 'Diagnostic window unexpectedly activated' }
                [void][OrbitOptionsProbe]::ShowWindow($window, 0)
                Start-Sleep -Milliseconds 100
            }
            if (-not $process.WaitForExit(12000) -or $process.ExitCode -ne 0) { throw 'Diagnostic app did not exit cleanly' }
            $saved = (Get-Content -LiteralPath $preference -Raw).Trim()
            if ($saved -ne "2 $pinned $pinned 100") { throw 'Window preferences changed unexpectedly' }
            Write-Output "PASS: Release pin=$pinned, caption, two hide/show cycles, non-activation, persisted options and graceful exit"
        } finally {
            $process.Refresh()
            if (-not $process.HasExited) {
                $owned = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
                if ($owned -and $owned.Path -eq $Executable) { Stop-Process -Id $owned.Id }
            }
        }
    }
    Write-Output "Isolated data: $probeRoot"
} finally {
    if ($null -eq $priorDataDirectory) { Remove-Item Env:SMALL_ORBIT_DATA_DIR -ErrorAction SilentlyContinue } else { $env:SMALL_ORBIT_DATA_DIR = $priorDataDirectory }
    if ($null -eq $priorDiagnostics) { Remove-Item Env:SMALL_ORBIT_DIAGNOSTICS -ErrorAction SilentlyContinue } else { $env:SMALL_ORBIT_DIAGNOSTICS = $priorDiagnostics }
}
