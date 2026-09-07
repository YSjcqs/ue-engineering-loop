# =============================================================================
# Engine PID tracker — snapshot / register / diff / cleanup
#
# Safety model:
#   - snapshot records a diagnostic baseline only. A PID that appears after the
#     snapshot is merely a CANDIDATE; time-of-appearance does not prove ownership.
#   - register records the exact PID returned by the launcher together with
#     process identity (name, executable, start time, command line, project).
#   - cleanup acts ONLY on explicitly registered records and re-validates every
#     identity field before requesting termination.
#
# Usage:
#   $runId = (& .\engine_pid_tracker.ps1 -Action snapshot -ProjectPath "<project>") |
#            Select-String '^RUN_ID=' | ForEach-Object { $_.Line.Split('=')[1] }
#   # Launch the editor and capture the exact PID from Start-Process -PassThru.
#   .\engine_pid_tracker.ps1 -Action register -ProjectPath "<project>" -RunId $runId -Pid $proc.Id
#   .\engine_pid_tracker.ps1 -Action diff     -ProjectPath "<project>" -RunId $runId
#   .\engine_pid_tracker.ps1 -Action cleanup  -ProjectPath "<project>" -RunId $runId
#   # Add -Force only after explicit authorization when graceful close fails.
#
# Exit codes: 0=success, 1=invalid/missing state, 2=identity mismatch,
#             3=state/lock/cleanup infrastructure failure, 4=invalid arguments.
# =============================================================================
param(
    [string]$Action = "",

    [string]$ProjectPath = "",

    [string]$RunId = "",

    [Alias("Pid")]
    [int]$ProcessId = 0,

    [string]$ProcessName = "UnrealEditor",

    [string]$StateDir = "",

    [switch]$AllowUnverifiedProjectAssociation,

    [switch]$Force,

    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

function Fail {
    param([string]$Message, [int]$Code = 1)
    [Console]::Error.WriteLine($Message)
    exit $Code
}

if (-not $SelfTest -and @("snapshot", "register", "diff", "cleanup") -notcontains $Action) {
    Fail ("Invalid Action: " + $Action) 4
}
if (-not $SelfTest -and $ProcessName -notmatch "^[A-Za-z0-9_.-]+$") {
    Fail ("Invalid ProcessName: " + $ProcessName) 4
}

trap {
    [Console]::Error.WriteLine("PID tracker infrastructure failure: " + $_.Exception.Message)
    exit 3
}

function Normalize-RunId {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    if ($Value -notmatch "^[A-Za-z0-9-]{8,64}$") {
        Fail "RunId must contain 8-64 letters, digits, or hyphens." 4
    }
    return $Value.ToLowerInvariant()
}

function Get-ProcessIdentity {
    param([int]$ProcessId)
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $cim = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $ProcessId) -ErrorAction Stop
        $startUtc = $process.StartTime.ToUniversalTime().ToString("o")
        $exe = [string]$cim.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($exe)) { $exe = [string]$process.Path }
        return [PSCustomObject]@{
            process     = $process
            pid         = $ProcessId
            processName = [string]$process.ProcessName
            executable  = $exe
            startUtc    = $startUtc
            commandLine = [string]$cim.CommandLine
        }
    } catch {
        return $null
    }
}

function Test-ProjectAssociation {
    param($Identity, [string]$ProjectDirectory, [string]$UprojectPath)
    $cmd = [string]$Identity.commandLine
    if ([string]::IsNullOrWhiteSpace($cmd)) { return $false }
    $normalizedCmd = $cmd.Replace("\", "/")
    $normalizedUproject = $UprojectPath.Replace("\", "/")
    $pattern = '(?i)(?:^|[\s"])' + [Regex]::Escape($normalizedUproject) + '(?=$|[\s"])'
    return [Regex]::IsMatch($normalizedCmd, $pattern)
}

if ($SelfTest) {
    $cases = @(
        @{ Name = "exact quoted path"; Cmd = 'UnrealEditor.exe "C:/Game/Foo/Foo.uproject"'; Project = "C:/Game/Foo"; Uproject = "C:/Game/Foo/Foo.uproject"; Want = $true },
        @{ Name = "exact unquoted path"; Cmd = "UnrealEditor.exe C:/Game/Foo/Foo.uproject -game"; Project = "C:/Game/Foo"; Uproject = "C:/Game/Foo/Foo.uproject"; Want = $true },
        @{ Name = "prefix collision"; Cmd = 'UnrealEditor.exe "C:/Game/FooBar/FooBar.uproject"'; Project = "C:/Game/Foo"; Uproject = "C:/Game/Foo/Foo.uproject"; Want = $false },
        @{ Name = "missing command line"; Cmd = ""; Project = "C:/Game/Foo"; Uproject = "C:/Game/Foo/Foo.uproject"; Want = $false }
    )
    $failed = 0
    foreach ($case in $cases) {
        $identity = [PSCustomObject]@{ commandLine = $case.Cmd }
        $got = Test-ProjectAssociation -Identity $identity -ProjectDirectory $case.Project -UprojectPath $case.Uproject
        $status = if ($got -eq $case.Want) { "PASS" } else { "FAIL" }
        if ($status -eq "FAIL") { $failed++ }
        Write-Output ("[{0}] {1}: got={2}, want={3}" -f $status, $case.Name, $got, $case.Want)
    }
    if ($failed -gt 0) { exit 1 }
    Write-Output ("SelfTest passed: " + $cases.Count + " cases")
    exit 0
}

function Read-State {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail ("State file not found: " + $Path) 1
    }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Fail ("State file is unreadable: " + $Path + " (" + $_.Exception.Message + ")") 1
    }
}

function Assert-StateIdentity {
    param($State, [string]$ExpectedProjectKey, [string]$ExpectedRunId, [string]$ExpectedProject, [string]$ExpectedUproject, [string]$ExpectedProcessName)
    if ([int]$State.schemaVersion -ne 2 -or
        [string]$State.projectKey -ne $ExpectedProjectKey -or
        [string]$State.runId -ne $ExpectedRunId -or
        [string]$State.project -ne $ExpectedProject -or
        [string]$State.uproject -ne $ExpectedUproject -or
        [string]$State.processName -ne $ExpectedProcessName) {
        Fail "State schema or identity mismatch; refusing action." 2
    }
}

function Write-StateAtomic {
    param([string]$Path, $State)
    $tmp = $Path + ".tmp_" + [Guid]::NewGuid().ToString("N")
    try {
        $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8 -NoNewline
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

try {
    $resolvedProject = (Resolve-Path -LiteralPath $ProjectPath -ErrorAction Stop).Path
} catch {
    Fail ("ProjectPath cannot be resolved; refusing to use a global fallback: " + $ProjectPath) 4
}

$uprojectFiles = @(Get-ChildItem -LiteralPath $resolvedProject -Filter "*.uproject" -File -ErrorAction Stop)
if ($uprojectFiles.Count -ne 1) {
    Fail ("Expected exactly one .uproject directly under " + $resolvedProject + "; found " + $uprojectFiles.Count) 4
}
$uproject = $uprojectFiles[0]

if ([string]::IsNullOrWhiteSpace($StateDir)) {
    $base = [Environment]::GetFolderPath("LocalApplicationData")
    if ([string]::IsNullOrWhiteSpace($base)) { Fail "LOCALAPPDATA is unavailable." 4 }
    $StateDir = Join-Path $base "ue-engineering-loop\process-state"
}
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
$resolvedStateDir = (Resolve-Path -LiteralPath $StateDir -ErrorAction Stop).Path

$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($resolvedProject.ToLowerInvariant())
    $projectKey = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant().Substring(0, 16)
} finally {
    $sha.Dispose()
}

$RunId = Normalize-RunId $RunId
if ($Action -eq "snapshot" -and -not $RunId) { $RunId = [Guid]::NewGuid().ToString("N") }
if ($Action -ne "snapshot" -and -not $RunId) { Fail "RunId is required for register, diff, and cleanup." 4 }

$stateFile = Join-Path $resolvedStateDir ("run_" + $projectKey + "_" + $RunId + ".json")
$mutexName = "Local\ue-engineering-loop-pid-state-" + $projectKey + "-" + $RunId
$createdNew = $false
$mutex = [System.Threading.Mutex]::new($false, $mutexName, [ref]$createdNew)
$lockHeld = $false
$fileLock = $null
try {
    try {
        $lockHeld = $mutex.WaitOne(5000, $false)
    } catch [System.Threading.AbandonedMutexException] {
        $lockHeld = $true
    }
    if (-not $lockHeld) { Fail "Could not acquire PID state lock within 5 seconds." 3 }
    try {
        $fileLock = [System.IO.File]::Open(($stateFile + ".lock"), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch {
        Fail ("Could not acquire cross-session PID state lock: " + $_.Exception.Message) 3
    }

switch ($Action) {
    "snapshot" {
        if (Test-Path -LiteralPath $stateFile) {
            Fail ("RunId already exists; refusing to overwrite state: " + $RunId) 3
        }
        $baseline = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        $state = [ordered]@{
            schemaVersion = 2
            runId         = $RunId
            createdUtc    = (Get-Date).ToUniversalTime().ToString("o")
            project       = $resolvedProject
            uproject      = $uproject.FullName
            projectKey    = $projectKey
            processName   = $ProcessName
            baselinePids  = $baseline
            registered    = @()
        }
        Write-StateAtomic -Path $stateFile -State $state
        Write-Output ("RUN_ID=" + $RunId)
        Write-Output ("SNAPSHOT: baseline candidates = [" + ($baseline -join ", ") + "]")
        Write-Output ("STATE_FILE=" + $stateFile)
        exit 0
    }

    "register" {
        if ($ProcessId -le 0) { Fail "ProcessId (alias: Pid) is required for register and must be positive." 4 }
        $state = Read-State $stateFile
        Assert-StateIdentity -State $state -ExpectedProjectKey $projectKey -ExpectedRunId $RunId -ExpectedProject $resolvedProject -ExpectedUproject $uproject.FullName -ExpectedProcessName $ProcessName
        $identity = Get-ProcessIdentity $ProcessId
        if (-not $identity) { Fail ("PID " + $ProcessId + " does not exist or cannot be inspected.") 2 }
        if ($identity.processName -ne $ProcessName) {
            Fail ("PID " + $ProcessId + " is '" + $identity.processName + "', expected '" + $ProcessName + "'.") 2
        }
        $associated = Test-ProjectAssociation -Identity $identity -ProjectDirectory $resolvedProject -UprojectPath $uproject.FullName
        if (-not $associated -and -not $AllowUnverifiedProjectAssociation) {
            Fail ("PID " + $ProcessId + " command line does not identify this project. Refusing registration; pass -AllowUnverifiedProjectAssociation only after manual verification.") 2
        }
        $records = @($state.registered)
        if (@($records | Where-Object { [int]$_.pid -eq $ProcessId }).Count -gt 0) {
            Write-Output ("REGISTER: PID " + $ProcessId + " already recorded.")
            exit 0
        }
        $record = [ordered]@{
            pid                        = $identity.pid
            processName                = $identity.processName
            executable                 = $identity.executable
            startUtc                   = $identity.startUtc
            commandLine                = $identity.commandLine
            projectAssociationVerified = $associated
            registeredUtc              = (Get-Date).ToUniversalTime().ToString("o")
        }
        $state.registered = @($records + [PSCustomObject]$record)
        Write-StateAtomic -Path $stateFile -State $state
        Write-Output ("REGISTER: PID " + $ProcessId + " recorded for run " + $RunId + ".")
        exit 0
    }

    "diff" {
        $state = Read-State $stateFile
        Assert-StateIdentity -State $state -ExpectedProjectKey $projectKey -ExpectedRunId $RunId -ExpectedProject $resolvedProject -ExpectedUproject $uproject.FullName -ExpectedProcessName $ProcessName
        $baseline = @($state.baselinePids | ForEach-Object { [int]$_ })
        $now = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        $candidates = @($now | Where-Object { $baseline -notcontains $_ })
        $registered = @($state.registered | ForEach-Object { [int]$_.pid })
        Write-Output ("NOW=[" + ($now -join ", ") + "]")
        Write-Output ("CANDIDATES_NOT_OWNERSHIP_PROOF=[" + ($candidates -join ", ") + "]")
        Write-Output ("REGISTERED_OWNED=[" + ($registered -join ", ") + "]")
        exit 0
    }

    "cleanup" {
        $state = Read-State $stateFile
        Assert-StateIdentity -State $state -ExpectedProjectKey $projectKey -ExpectedRunId $RunId -ExpectedProject $resolvedProject -ExpectedUproject $uproject.FullName -ExpectedProcessName $ProcessName
        $records = @($state.registered)
        if ($records.Count -eq 0) {
            Write-Output "CLEANUP: no explicitly registered processes. Nothing was terminated."
            Remove-Item -LiteralPath $stateFile -Force
            exit 0
        }

        $remaining = New-Object System.Collections.Generic.List[object]
        $hadMismatch = $false
        foreach ($record in $records) {
            $existing = Get-Process -Id ([int]$record.pid) -ErrorAction SilentlyContinue
            if (-not $existing) {
                Write-Output ("CLEANUP: PID " + $record.pid + " already exited.")
                continue
            }
            $current = Get-ProcessIdentity ([int]$record.pid)
            if (-not $current) {
                Write-Warning ("CLEANUP: PID " + $record.pid + " exists but identity inspection failed; retaining record and refusing termination.")
                $remaining.Add($record)
                $hadMismatch = $true
                continue
            }
            $sameName = ([string]$current.processName -eq [string]$record.processName)
            $sameExe = ([string]$current.executable -eq [string]$record.executable)
            $sameStart = ([string]$current.startUtc -eq [string]$record.startUtc)
            $sameCommandLine = ([string]$current.commandLine -eq [string]$record.commandLine)
            $projectStillMatches = Test-ProjectAssociation -Identity $current -ProjectDirectory $resolvedProject -UprojectPath $uproject.FullName
            $registeredVerified = [bool]$record.projectAssociationVerified
            $projectOk = $projectStillMatches -or ((-not $registeredVerified) -and $AllowUnverifiedProjectAssociation)
            if (-not ($sameName -and $sameExe -and $sameStart -and $sameCommandLine -and $projectOk)) {
                Write-Warning ("CLEANUP: PID " + $record.pid + " identity or project association changed; refusing termination.")
                $remaining.Add($record)
                $hadMismatch = $true
                continue
            }

            $process = $current.process
            $closed = $false
            if ($process.MainWindowHandle -ne 0) {
                $closed = $process.CloseMainWindow()
                if ($closed) { $closed = $process.WaitForExit(10000) }
            }
            if (-not $closed) {
                if ($Force) {
                    try {
                        $process.Kill()
                        $closed = $process.WaitForExit(10000)
                    } catch {
                        Write-Warning ("CLEANUP: registered process handle could not be terminated: " + $_.Exception.Message)
                        $closed = $false
                    }
                } else {
                    Write-Warning ("CLEANUP: PID " + $record.pid + " did not exit gracefully. Re-run with -Force only after explicit authorization.")
                }
            }
            if ($closed) {
                Write-Output ("CLEANUP: stopped registered PID " + $record.pid + ".")
            } else {
                $remaining.Add($record)
            }
        }

        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $stateFile -Force
            Write-Output "CLEANUP: complete; run state removed."
            exit 0
        }

        $state.registered = @($remaining)
        Write-StateAtomic -Path $stateFile -State $state
        Write-Warning ("CLEANUP: incomplete; " + $remaining.Count + " verified record(s) remain in state.")
        if ($hadMismatch) { exit 2 }
        exit 3
    }
}
} finally {
    if ($null -ne $fileLock) {
        $fileLock.Dispose()
        Remove-Item -LiteralPath ($stateFile + ".lock") -Force -ErrorAction SilentlyContinue
    }
    if ($lockHeld) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    $mutex.Dispose()
}
