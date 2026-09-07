# =============================================================================
# Run UE automation specs headless (CI-style).
#
# Exit codes:
#   0 = all discovered tests passed and queue completed
#   1 = one or more tests failed, or editor exited non-zero
#   2 = no tests executed
#   3 = no current-run log produced
#   4 = invalid arguments / project / editor
#   5 = timeout (takes precedence over missing log or zero executed tests)
#   6 = runner infrastructure failure (lock, launch, rotation, missing terminator)
# =============================================================================
param(
    [string]$ProjectPath,
    [string]$Spec,
    [string]$EditorExe = "",
    [int]$TimeoutSec = 900,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

if ($TimeoutSec -lt 10 -or $TimeoutSec -gt 86400) {
    [Console]::Error.WriteLine("TimeoutSec must be between 10 and 86400.")
    exit 4
}

trap {
    [Console]::Error.WriteLine("Headless runner infrastructure failure: " + $_.Exception.Message)
    exit 6
}

function Get-RunVerdict {
    param(
        [string]$LogPath,
        [bool]$TimedOut,
        [int]$ProcessExit
    )

    if ($TimedOut) {
        return [PSCustomObject]@{ Code = 5; Success = 0; Fail = 0; Executed = 0; QueueComplete = $false; Reason = "timeout" }
    }
    if ($ProcessExit -ne 0) {
        return [PSCustomObject]@{ Code = 1; Success = 0; Fail = 0; Executed = 0; QueueComplete = $false; Reason = ("editor exited non-zero: " + $ProcessExit) }
    }
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
        return [PSCustomObject]@{ Code = 3; Success = 0; Fail = 0; Executed = 0; QueueComplete = $false; Reason = "no current-run log" }
    }

    $success = (Select-String -LiteralPath $LogPath -Pattern "Result=\{Success" -ErrorAction SilentlyContinue | Measure-Object).Count
    $fail = (Select-String -LiteralPath $LogPath -Pattern "Result=\{Fail" -ErrorAction SilentlyContinue | Measure-Object).Count
    $executed = $success + $fail
    $queueLine = Select-String -LiteralPath $LogPath -Pattern "Queue Empty\s+(\d+)\s+tests? performed" -AllMatches -ErrorAction SilentlyContinue | Select-Object -Last 1
    $queueComplete = $null -ne $queueLine
    $reportedExecuted = if ($queueComplete) { [int]$queueLine.Matches[0].Groups[1].Value } else { -1 }

    if ($executed -eq 0) {
        return [PSCustomObject]@{ Code = 2; Success = $success; Fail = $fail; Executed = $executed; QueueComplete = $queueComplete; Reason = "no tests executed" }
    }
    if (-not $queueComplete) {
        return [PSCustomObject]@{ Code = 6; Success = $success; Fail = $fail; Executed = $executed; QueueComplete = $false; Reason = "missing queue completion marker" }
    }
    if ($reportedExecuted -ne $executed) {
        return [PSCustomObject]@{ Code = 6; Success = $success; Fail = $fail; Executed = $executed; QueueComplete = $true; Reason = ("queue count mismatch: reported=" + $reportedExecuted + ", parsed=" + $executed) }
    }
    if ($fail -gt 0 -or $ProcessExit -ne 0) {
        return [PSCustomObject]@{ Code = 1; Success = $success; Fail = $fail; Executed = $executed; QueueComplete = $true; Reason = "test or editor failure" }
    }
    return [PSCustomObject]@{ Code = 0; Success = $success; Fail = $fail; Executed = $executed; QueueComplete = $true; Reason = "all tests passed" }
}

function Invoke-SelfTest {
    $cases = @(
        @{ Name = "all pass"; Content = "Test Completed. Result={Success}`nQueue Empty 1 tests performed"; TimedOut = $false; Exit = 0; Want = 0 },
        @{ Name = "multiple pass"; Content = "Test Completed. Result={Success}`nTest Completed. Result={Success}`nQueue Empty 2 tests performed"; TimedOut = $false; Exit = 0; Want = 0 },
        @{ Name = "one fail"; Content = "Test Completed. Result={Success}`nTest Completed. Result={Fail}`nQueue Empty 2 tests performed"; TimedOut = $false; Exit = 0; Want = 1 },
        @{ Name = "zero tests"; Content = "Queue Empty 0 tests performed"; TimedOut = $false; Exit = 0; Want = 2 },
        @{ Name = "no log"; Content = $null; TimedOut = $false; Exit = 0; Want = 3 },
        @{ Name = "editor nonzero without log"; Content = $null; TimedOut = $false; Exit = 7; Want = 1 },
        @{ Name = "timeout without log"; Content = $null; TimedOut = $true; Exit = -1; Want = 5 },
        @{ Name = "timeout with partial test"; Content = "Test Completed. Result={Success}"; TimedOut = $true; Exit = -1; Want = 5 },
        @{ Name = "missing queue marker"; Content = "Test Completed. Result={Success}"; TimedOut = $false; Exit = 0; Want = 6 },
        @{ Name = "queue count mismatch"; Content = "Test Completed. Result={Success}`nQueue Empty 9 tests performed"; TimedOut = $false; Exit = 0; Want = 6 },
        @{ Name = "editor nonzero"; Content = "Test Completed. Result={Success}`nQueue Empty 1 tests performed"; TimedOut = $false; Exit = 1; Want = 1 }
    )

    Write-Output "=== run_spec_headless.ps1 SelfTest ==="
    $failed = 0
    foreach ($case in $cases) {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ("ue_loop_verdict_" + [Guid]::NewGuid().ToString("N") + ".log")
        try {
            if ($null -ne $case.Content) { [System.IO.File]::WriteAllText($path, [string]$case.Content) }
            $result = Get-RunVerdict -LogPath $path -TimedOut $case.TimedOut -ProcessExit $case.Exit
            $status = if ($result.Code -eq $case.Want) { "PASS" } else { "FAIL" }
            if ($status -eq "FAIL") { $failed++ }
            Write-Output ("[{0}] {1}: got={2}, want={3}" -f $status, $case.Name, $result.Code, $case.Want)
        } finally {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
    }
    if ($failed -gt 0) { [Console]::Error.WriteLine("SelfTest failed: " + $failed); return 1 }
    Write-Output ("SelfTest passed: " + $cases.Count + " cases")
    return 0
}

if ($SelfTest) { exit (Invoke-SelfTest) }

if ([string]::IsNullOrWhiteSpace($ProjectPath)) { [Console]::Error.WriteLine("-ProjectPath is required."); exit 4 }
if ([string]::IsNullOrWhiteSpace($Spec)) { [Console]::Error.WriteLine("-Spec is required."); exit 4 }
if ($Spec -notmatch "^[A-Za-z0-9_.+*? -]+$") {
    [Console]::Error.WriteLine("-Spec contains unsupported characters. Quotes, semicolons, and line breaks are forbidden.")
    exit 4
}

try {
    $resolvedProject = (Resolve-Path -LiteralPath $ProjectPath -ErrorAction Stop).Path
} catch {
    [Console]::Error.WriteLine("Project path not found: " + $ProjectPath)
    exit 4
}
try {
    $uprojectFiles = @(Get-ChildItem -LiteralPath $resolvedProject -Filter "*.uproject" -File -ErrorAction Stop)
} catch {
    [Console]::Error.WriteLine("Could not enumerate .uproject files: " + $_.Exception.Message)
    exit 4
}
if ($uprojectFiles.Count -ne 1) {
    [Console]::Error.WriteLine("Expected exactly one .uproject directly under " + $resolvedProject + "; found " + $uprojectFiles.Count)
    exit 4
}
$uprojectFile = $uprojectFiles[0]
$projName = [System.IO.Path]::GetFileNameWithoutExtension($uprojectFile.Name)
$runId = [Guid]::NewGuid().ToString("N")
$logDir = Join-Path $resolvedProject "Saved\Logs\Automation"
$log = Join-Path $logDir ($projName + "-" + $runId + ".log")

function Resolve-EditorExe {
    param([string]$Hint, [string]$UprojectPath)
    if ($Hint) {
        if (Test-Path -LiteralPath $Hint -PathType Leaf) { return (Resolve-Path -LiteralPath $Hint).Path }
        return $null
    }
    try {
        $json = Get-Content -LiteralPath $UprojectPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $assoc = [string]$json.EngineAssociation
        if ($assoc -and (Test-Path -LiteralPath $assoc -PathType Container)) {
            $candidate = Join-Path $assoc "Engine\Binaries\Win64\UnrealEditor.exe"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
        }
        if ($assoc) {
            $regKey = "HKCU:\SOFTWARE\Epic Games\Unreal Engine\Builds"
            if (Test-Path $regKey) {
                $item = Get-ItemProperty -Path $regKey -ErrorAction Stop
                $property = $item.PSObject.Properties | Where-Object { $_.Name -eq $assoc } | Select-Object -First 1
                if ($property -and $property.Value) {
                    $candidate = Join-Path ([string]$property.Value) "Engine\Binaries\Win64\UnrealEditor.exe"
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
                }
            }
        }
    } catch { }
    return $null
}

$editor = Resolve-EditorExe -Hint $EditorExe -UprojectPath $uprojectFile.FullName
if (-not $editor) { [Console]::Error.WriteLine("Could not locate UnrealEditor.exe; pass -EditorExe explicitly."); exit 4 }

function Get-ExistingEditors {
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name LIKE 'UnrealEditor%.exe'" -ErrorAction Stop | ForEach-Object { [int]$_.ProcessId })
    } catch {
        return @(-1)
    }
}

$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($resolvedProject.ToLowerInvariant())
    $hash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant().Substring(0, 16)
} finally {
    $sha.Dispose()
}
$mutexName = "Local\ue-engineering-loop-headless-" + $hash
$createdNew = $false
$mutex = [System.Threading.Mutex]::new($false, $mutexName, [ref]$createdNew)
$lockHeld = $false
$leaseStream = $null
$proc = $null
try {
    try {
        $lockHeld = $mutex.WaitOne(0, $false)
    } catch [System.Threading.AbandonedMutexException] {
        $lockHeld = $true
    }
    if (-not $lockHeld) { [Console]::Error.WriteLine("Another headless run is active for this project."); exit 6 }

    $leaseDir = Join-Path $resolvedProject "Saved\Locks"
    New-Item -ItemType Directory -Path $leaseDir -Force | Out-Null
    $leasePath = Join-Path $leaseDir "ue-engineering-loop-headless.lock"
    try {
        $leaseStream = [System.IO.File]::Open($leasePath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $leaseStream.SetLength(0)
        $leaseBytes = [System.Text.Encoding]::UTF8.GetBytes(("pid=" + $PID + ";started=" + (Get-Date).ToUniversalTime().ToString("o")))
        $leaseStream.Write($leaseBytes, 0, $leaseBytes.Length)
        $leaseStream.Flush()
    } catch {
        [Console]::Error.WriteLine("Could not acquire project lease: " + $_.Exception.Message)
        exit 6
    }

    $existing = @(Get-ExistingEditors)
    if ($existing.Count -gt 0) {
        [Console]::Error.WriteLine("Existing or uninspectable UnrealEditor process detected (PID: " + ($existing -join ",") + "). Headless runner requires an exclusive machine-level Editor lease.")
        exit 6
    }

    try {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    } catch {
        [Console]::Error.WriteLine("Could not create log directory: " + $_.Exception.Message)
        exit 6
    }
    if (Test-Path -LiteralPath $log) {
        [Console]::Error.WriteLine("Unique run log already exists; refusing ambiguous evidence: " + $log)
        exit 6
    }

    Write-Output "=========================================="
    Write-Output ("Spec    : " + $Spec)
    Write-Output ("Project : " + $uprojectFile.FullName)
    Write-Output ("Editor  : " + $editor)
    Write-Output ("Log     : " + $log)
    Write-Output "=========================================="

    $argList = @(
        ('"' + $uprojectFile.FullName + '"'),
        ('-ExecCmds="Automation RunTests ' + $Spec + ';Quit"'),
        ('-abslog="' + $log + '"'),
        ("-UEEngineeringRunId=" + $runId),
        "-unattended", "-nosplash", "-nullrhi", "-nopause", "-stdout", "-FullStdOutLogOutput"
    )
    try {
        $proc = Start-Process -FilePath $editor -ArgumentList $argList -WindowStyle Minimized -PassThru -ErrorAction Stop
    } catch {
        [Console]::Error.WriteLine("Failed to start UnrealEditor: " + $_.Exception.Message)
        exit 6
    }
    Write-Output ("Started editor PID " + $proc.Id)

    $elapsed = 0
    $timedOut = $false
    $queueObserved = $false
    $runnerFailureReason = ""
    while ($elapsed -lt $TimeoutSec) {
        Start-Sleep -Seconds 5
        $elapsed += 5
        $proc.Refresh()
        if ($proc.HasExited) { break }
        $otherEditors = @(Get-ExistingEditors | Where-Object { $_ -ne $proc.Id })
        if ($otherEditors.Count -gt 0) {
            $runnerFailureReason = "another or uninspectable UnrealEditor appeared during this run; machine-level Editor exclusivity was lost"
            break
        }
        if (-not $queueObserved -and (Test-Path -LiteralPath $log -PathType Leaf)) {
            $queueObserved = $null -ne (Select-String -LiteralPath $log -Pattern "Queue Empty\s+\d+\s+tests? performed" -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($queueObserved) { Write-Output ("[" + $elapsed + "s] queue completed; waiting for editor exit...") }
        }
        if ($elapsed % 30 -eq 0 -and -not $queueObserved) { Write-Output ("[" + $elapsed + "s] tests running...") }
    }

    $proc.Refresh()
    if (-not $proc.HasExited -and $runnerFailureReason) {
        Write-Warning ($runnerFailureReason + "; stopping only the original process handle.")
        try { $proc.Kill(); $null = $proc.WaitForExit(10000) } catch { }
    } elseif (-not $proc.HasExited) {
        $timedOut = $true
        Write-Warning ("Timeout after " + $TimeoutSec + " seconds; stopping only the original editor process handle.")
        try { $proc.Kill(); $null = $proc.WaitForExit(10000) } catch { }
    }
    $proc.Refresh()
    $procExit = if ($proc.HasExited) { $proc.ExitCode } else { -1 }
    $finalOtherEditors = @(Get-ExistingEditors | Where-Object { $_ -ne $proc.Id })
    if (-not $runnerFailureReason -and $finalOtherEditors.Count -gt 0) {
        $runnerFailureReason = "another or uninspectable UnrealEditor exists after this run; evidence ownership is ambiguous"
    }

    Write-Output ""
    Write-Output "=== RESULTS ==="
    if (Test-Path -LiteralPath $log -PathType Leaf) {
        Get-Content -LiteralPath $log |
            Select-String "Test Completed\. Result=|Queue Empty|Found \d+ automation|Expected|Automation Test (Succeeded|Failed)" |
            ForEach-Object { Write-Output $_.Line }
    } else {
        Write-Output "no current-run log produced"
    }

    if ($runnerFailureReason) {
        $verdict = [PSCustomObject]@{ Code = 6; Success = 0; Fail = 0; Executed = 0; QueueComplete = $false; Reason = $runnerFailureReason }
    } else {
        $verdict = Get-RunVerdict -LogPath $log -TimedOut $timedOut -ProcessExit $procExit
    }
    Write-Output ""
    Write-Output "=== SUMMARY ==="
    Write-Output ("Executed: {0} Success: {1} Fail: {2} QueueComplete: {3} EditorExit: {4}" -f $verdict.Executed, $verdict.Success, $verdict.Fail, $verdict.QueueComplete, $procExit)
    if ($verdict.Code -eq 0) { Write-Output "VERDICT: PASS (exit 0)" }
    else { [Console]::Error.WriteLine("VERDICT: FAIL (exit " + $verdict.Code + ") - " + $verdict.Reason) }
    exit $verdict.Code
} finally {
    if ($null -ne $proc) {
        try {
            $proc.Refresh()
            if (-not $proc.HasExited) {
                [Console]::Error.WriteLine("Runner cleanup: launched editor is still active; closing the original process handle before releasing the lease.")
                $closed = $false
                if ($proc.MainWindowHandle -ne 0) {
                    $closed = $proc.CloseMainWindow()
                    if ($closed) { $closed = $proc.WaitForExit(10000) }
                }
                if (-not $closed) {
                    $proc.Kill()
                    $closed = $proc.WaitForExit(10000)
                }
                if (-not $closed) { [Console]::Error.WriteLine("Runner cleanup failed; residual PID: " + $proc.Id) }
            }
        } catch {
            [Console]::Error.WriteLine("Runner cleanup failed; residual PID may remain: " + $proc.Id + " (" + $_.Exception.Message + ")")
        }
    }
    if ($null -ne $leaseStream) {
        try {
            $leaseStream.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
            $leaseStream.SetLength(0)
            $inactive = [System.Text.Encoding]::UTF8.GetBytes(("inactive=" + (Get-Date).ToUniversalTime().ToString("o")))
            $leaseStream.Write($inactive, 0, $inactive.Length)
            $leaseStream.Flush()
        } catch { }
        $leaseStream.Dispose()
    }
    if ($lockHeld) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    $mutex.Dispose()
}
