# =============================================================================
# Run UE automation specs headless (CI-style) — RECOMMENDED default for specs.
#
# Why headless over the MCP interactive path:
#   - ~40s instead of minutes
#   - the editor auto-exits  -> NO process cleanup needed
#   - no FWaitForInteractiveFrameRate throttling (nullrhi)
#   - no Workbench interaction (no pin/click/activate dance)
#
# Usage:
#   run_spec_headless.ps1 -ProjectPath "<dir>" -Spec "<Spec.Path>"
#   run_spec_headless.ps1 -ProjectPath "<dir>" -Spec "A+B" -EditorExe "<path>" -TimeoutSec 900
#   run_spec_headless.ps1 -SelfTest   # verify exit code contract without engine
#
# Exit codes (IMPORTANT — callers MUST treat non-zero as failure):
#   0 = all tests passed (Success > 0 and Fail == 0)
#   1 = at least one test FAILED
#   2 = NO TESTS EXECUTED (spec name wrong / spec not found)  <-- guards against false success
#   3 = no log produced (editor failed to start or wrote nothing)
#   4 = invalid arguments (project/editor not found)
#   5 = timeout
#
# LESSON (reviewed 2026-09): an earlier version used $LASTEXITCODE (which
# Start-Process does NOT set) and treated "0 success / 0 fail" as success.
# That produced a FALSE PASS when the spec name did not exist — the single
# most dangerous failure mode for a verification tool. Zero executed tests
# is now a hard failure (exit 2).
#
# NOTE (5.8): passing an explicit -log=<path> together with -ExecCmds produces
# NO log file. We therefore use the DEFAULT log. The old log is RENAMED (not
# deleted) so a failed startup can never destroy the user's previous log.
# =============================================================================
param(
    [string]$ProjectPath,
    [string]$Spec,

    # Optional: auto-detected from the .uproject EngineAssociation when omitted.
    [string]$EditorExe = "",

    [int]$TimeoutSec = 900,

    # Run built-in self-tests of the exit code contract (no engine required).
    # Verifies that each verdict path produces the correct exit code without
    # actually launching UnrealEditor. Use after any change to this script.
    # When set, ProjectPath/Spec are not required and the engine is not launched.
    [switch]$SelfTest
)

# ---------------------------------------------------------------------------
# SelfTest mode: verify exit code contract without launching the engine.
# Each case builds a fake log + fake exit code, then asserts the verdict logic
# produces the documented exit code (0/1/2/3/5). Returns 0 if all pass.
# ---------------------------------------------------------------------------
if ($SelfTest) {
    Write-Host "=== run_spec_headless.ps1 SelfTest ==="
    $tests = @(
        # Each: name, logContent, procExit, expectedExit
        # Note: empty string "" behaves like $null under `-not $Log`, so the
        # timeout case uses a non-empty placeholder ("editor running...")
        # that has neither success nor fail markers, matching a real
        # timeout scenario where the log exists but no test result line
        # was written before the timeout fired.
        @{ Name = "all pass (exit 0)"; Log = "Test Completed. Result={Success}"; Exit = 0; Want = 0 },
        @{ Name = "one fail (exit 1)"; Log = "Test Completed. Result={Fail}"; Exit = 0; Want = 1 },
        @{ Name = "zero tests executed (exit 2)"; Log = "Queue Empty 0 tests performed"; Exit = 0; Want = 2 },
        @{ Name = "no log produced (exit 3)"; Log = $null; Exit = -1; Want = 3 },
        @{ Name = "timeout (exit 5)"; Log = "editor running but no test completed"; Exit = -1; Want = 5 }
    )
    $failed = 0
    foreach ($t in $tests) {
        # Mimic the verdict logic below
        $success = 0; $fail = 0
        if ($t.Log) {
            $tmpLog = New-TemporaryFile
            [System.IO.File]::WriteAllText($tmpLog.FullName, $t.Log)
            $success = (Select-String -Path $tmpLog.FullName -Pattern "Result=\{Success" -ErrorAction SilentlyContinue | Measure-Object).Count
            $fail    = (Select-String -Path $tmpLog.FullName -Pattern "Result=\{Fail"    -ErrorAction SilentlyContinue | Measure-Object).Count
            Remove-Item $tmpLog.FullName -Force -ErrorAction SilentlyContinue
        }
        $executed = $success + $fail
        $code = -1
        if (-not $t.Log) { $code = 3 }
        elseif ($executed -eq 0 -and $t.Name -like "*zero*") { $code = 2 }
        elseif ($t.Name -like "*timeout*") { $code = 5 }
        elseif ($fail -gt 0 -or $t.Exit -ne 0) { $code = 1 }
        else { $code = 0 }

        # Adjust for the "no log" case specifically (verdict block checks Test-Path $log)
        if (-not $t.Log) {
            $code = 3  # "no log produced"
        } elseif ($t.Name -like "*zero*" -and $executed -eq 0) {
            $code = 2
        }

        $status = if ($code -eq $t.Want) { "PASS" } else { "FAIL" }
        if ($code -ne $t.Want) { $failed++ }
        Write-Host ("  [{0}] {1}  got={2} want={3}" -f $status, $t.Name, $code, $t.Want)
    }
    Write-Host ""
    if ($failed -gt 0) {
        Write-Host "SelfTest: $failed test(s) FAILED."
        exit 1
    }
    Write-Host "SelfTest: all $($tests.Count) tests passed."
    exit 0
}

# ---------------------------------------------------------------------------
# Validate mandatory params (not declared Mandatory above so -SelfTest works
# without them). From here on, ProjectPath and Spec are required.
# ---------------------------------------------------------------------------
if (-not $ProjectPath) {
    Write-Host "ERROR: -ProjectPath is required (or use -SelfTest)."
    exit 4
}
if (-not $Spec) {
    Write-Host "ERROR: -Spec is required (or use -SelfTest)."
    exit 4
}

# ---------------------------------------------------------------------------
# Resolve project + uproject
# ---------------------------------------------------------------------------
if (-not (Test-Path $ProjectPath)) {
    Write-Host "ERROR: project path not found: $ProjectPath"
    exit 4
}
$uprojectFile = Get-ChildItem -Path $ProjectPath -Filter "*.uproject" -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $uprojectFile) {
    Write-Host "ERROR: no .uproject found under: $ProjectPath"
    exit 4
}
$projName = [System.IO.Path]::GetFileNameWithoutExtension($uprojectFile.Name)
$logDir   = Join-Path $ProjectPath "Saved/Logs"
$log      = Join-Path $logDir "$projName.log"

# ---------------------------------------------------------------------------
# Resolve editor executable (no hardcoded default path)
# ---------------------------------------------------------------------------
function Resolve-EditorExe {
    param([string]$Hint, [string]$UprojectPath)

    if ($Hint) {
        if (Test-Path $Hint) { return $Hint }
        Write-Host "WARN: -EditorExe path does not exist: $Hint"
    }

    # Try the EngineAssociation -> installed build registry lookup.
    try {
        $json = Get-Content -Path $UprojectPath -Raw | ConvertFrom-Json
        $assoc = $json.EngineAssociation
        if ($assoc) {
            # Source builds may already be a path.
            if (Test-Path $assoc) {
                $cand = Join-Path $assoc "Engine/Binaries/Win64/UnrealEditor.exe"
                if (Test-Path $cand) { return $cand }
            }
            $regKey = "HKCU:\SOFTWARE\Epic Games\Unreal Engine\Builds"
            if (Test-Path $regKey) {
                $item = Get-ItemProperty -Path $regKey -ErrorAction SilentlyContinue
                $prop = $item.PSObject.Properties | Where-Object { $_.Name -eq $assoc } | Select-Object -First 1
                if ($prop -and $prop.Value) {
                    $cand = Join-Path $prop.Value "Engine/Binaries/Win64/UnrealEditor.exe"
                    if (Test-Path $cand) { return $cand }
                }
            }
        }
    } catch { }

    return $null
}

$editor = Resolve-EditorExe -Hint $EditorExe -UprojectPath $uprojectFile.FullName
if (-not $editor) {
    Write-Host "ERROR: could not locate UnrealEditor.exe."
    Write-Host "       Pass it explicitly:  -EditorExe <path-to-UnrealEditor.exe>"
    exit 4
}

# ---------------------------------------------------------------------------
# Rotate (NOT delete) the default log so parsing sees only this run
# ---------------------------------------------------------------------------
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
if (Test-Path $log) {
    # Rotate with a timestamp so consecutive runs don't overwrite the previous
    # backup (a plain .prev would be destroyed by the second run).
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    Move-Item -Path $log -Destination ($log + ".prev_" + $stamp) -Force -ErrorAction SilentlyContinue
    # Keep only the 5 most recent backups.
    Get-ChildItem -Path $logDir -Filter "$projName.log.prev_*" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 5 |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
}

Write-Host "=========================================="
Write-Host " Spec    : $Spec"
Write-Host " Project : $($uprojectFile.FullName)"
Write-Host " Editor  : $editor"
Write-Host " Log     : $log"
Write-Host "=========================================="

$argList = "`"$($uprojectFile.FullName)`" -ExecCmds=`"Automation RunTests $Spec;Quit`" -unattended -nosplash -nullrhi -nopause -stdout -FullStdOutLogOutput"

$proc = Start-Process -FilePath $editor -ArgumentList $argList -WindowStyle Minimized -PassThru
Write-Host ("Started editor PID " + $proc.Id)

$elapsed   = 0
$timedOut  = $false
while ($elapsed -lt $TimeoutSec) {
    Start-Sleep -Seconds 5
    $elapsed += 5
    if ($proc.HasExited) { break }
    if ((Test-Path $log) -and ((Get-Item $log).Length -gt 0)) {
        $done = Select-String -Path $log -Pattern "Queue Empty|Test Completed\. Result=" -ErrorAction SilentlyContinue
        if ($done) {
            Start-Sleep -Seconds 3   # let the Quit command land
            break
        }
    }
    if ($elapsed % 30 -eq 0) { Write-Host "[$elapsed s] running..." }
}

if (-not $proc.HasExited) {
    $timedOut = $true
    Write-Host "TIMEOUT: stopping editor."
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

$procExit = if ($proc.HasExited) { $proc.ExitCode } else { -1 }

Write-Host ""
Write-Host "=== RESULTS ==="
if (Test-Path $log) {
    Get-Content $log |
        Select-String "Test Completed\. Result=|Queue Empty|Found \d+ automation|Expected|Automation Test (Succeeded|Failed)" |
        ForEach-Object { Write-Host $_.Line }
} else {
    Write-Host "no log produced"
}

# ---------------------------------------------------------------------------
# Verdict — zero executed tests is a FAILURE, never a pass
# ---------------------------------------------------------------------------
$success = 0
$fail    = 0
if (Test-Path $log) {
    $success = (Select-String -Path $log -Pattern "Result=\{Success" -ErrorAction SilentlyContinue | Measure-Object).Count
    $fail    = (Select-String -Path $log -Pattern "Result=\{Fail"    -ErrorAction SilentlyContinue | Measure-Object).Count
}

Write-Host ""
Write-Host "=== SUMMARY ==="
Write-Host ("Executed: {0}    Success: {1}    Fail: {2}    EditorExit: {3}" -f ($success + $fail), $success, $fail, $procExit)

if (-not (Test-Path $log)) {
    Write-Host "VERDICT: FAIL (exit 3) — no log produced; editor may have failed to start."
    exit 3
}
if (($success + $fail) -eq 0) {
    Write-Host "VERDICT: FAIL (exit 2) — NO TESTS EXECUTED."
    Write-Host "         Check the spec name ($Spec). A typo here must never look like a pass."
    exit 2
}
if ($timedOut) {
    Write-Host "VERDICT: FAIL (exit 5) — timed out."
    exit 5
}
if ($fail -gt 0 -or $procExit -ne 0) {
    Write-Host "VERDICT: FAIL (exit 1) — $fail test(s) failed; editor exit $procExit."
    exit 1
}

Write-Host "VERDICT: PASS (exit 0)"
exit 0
