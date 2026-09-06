# =============================================================================
# Engine PID tracker — snapshot / diff / cleanup
#
# WHY: never kill by process name (that would kill the USER's editor instance).
# Instead: record a baseline before launch, diff after launch, and clean up
# ONLY the PIDs that appeared in between (i.e. the ones AI started).
#
# Usage:
#   engine_pid_tracker.ps1 -Action snapshot -ProjectPath "<uproject dir>"
#   engine_pid_tracker.ps1 -Action diff     -ProjectPath "<uproject dir>"
#   engine_pid_tracker.ps1 -Action cleanup  -ProjectPath "<uproject dir>"
#
# ★ -ProjectPath is STRONGLY RECOMMENDED (see "CROSS-PROJECT SAFETY" below).
#
# CROSS-PROJECT SAFETY (fixed 2026-09, review finding P0-3):
#   The baseline is keyed by project. If you snapshot in project A and then
#   diff/cleanup in project B, project B's editor PIDs would NOT be in A's
#   baseline -> they would be classified as "AI-owned" -> KILLED. That is
#   exactly the "never kill the user's editor" failure this script exists to
#   prevent. Now:
#     - the baseline file name is suffixed with a project key, and
#     - the baseline records the project path, and
#     - diff/cleanup REFUSE to act when the recorded project differs from
#       the -ProjectPath you pass (fail-closed, never kill on ambiguity).
#
# State files are written next to this script and removed on cleanup.
# =============================================================================
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("snapshot", "diff", "cleanup")]
    [string]$Action,

    # Project directory (the dir containing the .uproject). Recommended: it
    # isolates baselines per project and enables the mismatch guard.
    [string]$ProjectPath = "",

    [string]$ProcessName = "UnrealEditor",

    # Leave empty to auto-resolve (see below). $PSScriptRoot is NOT filled in
    # under every invocation style, so we resolve defensively.
    [string]$StateDir = ""
)

# ---------------------------------------------------------------------------
# Resolve the state directory defensively
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($StateDir)) {
    if ($PSScriptRoot) {
        $StateDir = $PSScriptRoot
    } elseif ($MyInvocation.MyCommand.Path) {
        $StateDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        $StateDir = (Get-Location).Path
    }
}

# ---------------------------------------------------------------------------
# Resolve + normalize the project key
# ---------------------------------------------------------------------------
$projectKey = "global"
$projectLabel = "(none)"
if (-not [string]::IsNullOrWhiteSpace($ProjectPath)) {
    try {
        $full = (Resolve-Path -Path $ProjectPath -ErrorAction Stop).Path
        $projectLabel = $full
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($full.ToLowerInvariant())
        $hash = [System.BitConverter]::ToString($md5.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant()
        $projectKey = $hash.Substring(0, 8)
    } catch {
        Write-Host ("WARN: could not resolve ProjectPath '{0}' ({1}); using global key." -f $ProjectPath, $_.Exception.Message)
        $projectKey = "global"
        $projectLabel = "(unresolved)"
    }
}

$baselineFile = Join-Path $StateDir (".engine_baseline_" + $projectKey + ".json")
$ownedFile    = Join-Path $StateDir (".engine_ai_owned_" + $projectKey + ".json")

function Get-EnginePids {
    @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
}

# Read a baseline and enforce that it belongs to the project we are acting on.
function Read-BaselineChecked {
    param([string]$Path, [string]$Key, [string]$Label)

    if (-not (Test-Path $Path)) { return $null }

    $state = Get-Content $Path -Raw | ConvertFrom-Json
    $recordedKey = if ($state.PSObject.Properties.Name -contains "projectKey") { [string]$state.projectKey } else { "" }

    # Legacy baselines (written before keying existed) carry no projectKey.
    # Fail closed: refuse to use them rather than risk a cross-project kill.
    if ([string]::IsNullOrWhiteSpace($recordedKey)) {
        Write-Host "ERROR: this baseline predates project keying (no projectKey recorded)."
        Write-Host "       Refusing to use it (a stale/global baseline could kill the wrong editor)."
        Write-Host ("       Delete it and re-snapshot:  " + $Path)
        exit 1
    }

    if ($recordedKey -ne $Key) {
        Write-Host "ERROR: baseline project mismatch — refusing to act (fail-closed)."
        Write-Host ("       baseline belongs to : " + [string]$state.project)
        Write-Host ("       you are acting on   : " + $Label)
        Write-Host "       A baseline from another project must never be used to classify PIDs."
        exit 1
    }

    return $state
}

switch ($Action) {
    "snapshot" {
        $pids = Get-EnginePids
        @{
            timestamp  = (Get-Date).ToString("o")
            process    = $ProcessName
            project    = $projectLabel
            projectKey = $projectKey
            baseline   = @($pids)
        } | ConvertTo-Json | Set-Content -Path $baselineFile -Encoding UTF8

        Write-Host ("SNAPSHOT: project = " + $projectLabel)
        Write-Host ("          baseline = [" + ($pids -join ", ") + "]  (these are NOT AI-owned)")
        if ($projectKey -eq "global") {
            Write-Host "WARN: no -ProjectPath given; baseline is GLOBAL. Cross-project use may misclassify PIDs."
        }
    }

    "diff" {
        if (-not (Test-Path $baselineFile)) {
            Write-Host "ERROR: no baseline for this project. Run 'snapshot' BEFORE launching the engine."
            Write-Host ("       expected: " + $baselineFile)
            exit 1
        }
        $state = Read-BaselineChecked -Path $baselineFile -Key $projectKey -Label $projectLabel
        # @(...) guards against ConvertFrom-Json unwrapping a single-element array.
        $base = @($state.baseline)
        $now  = Get-EnginePids
        $mine = @($now | Where-Object { $base -notcontains $_ })
        Write-Host ("now = [" + ($now -join ", ") + "]")
        Write-Host ("AI-owned = [" + ($mine -join ", ") + "]")
        @($mine) | ConvertTo-Json | Set-Content -Path $ownedFile -Encoding UTF8
    }

    "cleanup" {
        if (-not (Test-Path $baselineFile)) {
            Write-Host "ERROR: no baseline found — REFUSING to kill by process name."
            exit 1
        }
        $state = Read-BaselineChecked -Path $baselineFile -Key $projectKey -Label $projectLabel
        $base = @($state.baseline)
        $now  = Get-EnginePids
        $mine = @($now | Where-Object { $base -notcontains $_ })

        if ($mine.Count -eq 0) {
            Write-Host "CLEANUP: no AI-owned processes to kill."
        } else {
            foreach ($p in $mine) {
                Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
                Write-Host ("CLEANUP: killed AI-owned PID " + $p)
            }
        }

        Start-Sleep -Seconds 2
        $left = Get-EnginePids
        Write-Host ("Remaining (should be user-owned only) = [" + ($left -join ", ") + "]")

        # Orphan scan
        foreach ($name in @("ShaderCompileWorker", "UbaAgent", "CrashReportClientEditor", "UnrealVersionSelector")) {
            $x = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
            if ($x.Count -gt 0) {
                Write-Host ("ORPHAN: {0} x{1} (PIDs: {2})" -f $name, $x.Count, ($x.Id -join ","))
            }
        }

        Remove-Item $baselineFile -ErrorAction SilentlyContinue
        Remove-Item $ownedFile    -ErrorAction SilentlyContinue
        Write-Host "CLEANUP: tracking state reset."
    }
}
