# =============================================================================
# env_health_check.ps1 - UE environment capability probe (generalized)
#
# Purpose: Probe configurable automation-channel endpoints (IDE build channel,
#          in-engine MCP channel, desktop automation channel, ...), check
#          UnrealEditor / IDE processes and listening ports, and inspect the
#          .uproject for an engine MCP plugin entry.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\env_health_check.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\env_health_check.ps1 -ProjectPath "F:/MyProject"
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\env_health_check.ps1 -Endpoints "IDE=127.0.0.1:64482/stream,ENGINE=127.0.0.1:8000/mcp,DESKTOP=127.0.0.1:3939/mcp"
#
# Endpoints format: comma-separated NAME=host:port/path pairs.
# Default endpoints below are the common trio (RiderMCP / engine native MCP
# plugin / Workbench-style desktop tool). Rename or re-point them freely for
# your environment; the discipline (probe BEFORE use, report to user) is what
# matters, not the specific ports.
#
# Exit codes: 0=all online  1=partial  2=all unreachable
# =============================================================================

param(
    [string]$ProjectPath = "",
    [int]$TimeoutMs = 5000,
    [string]$OutFile = "",
    # Comma-separated NAME=host:port/path pairs; empty = use defaults.
    [string]$Endpoints = ""
)

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"

$Lines = New-Object System.Collections.Generic.List[string]
$Down = 0

# ---------- Default endpoints (name=host:port/path) ----------
if ([string]::IsNullOrWhiteSpace($Endpoints)) {
    $Endpoints = "IDE_BUILD=127.0.0.1:64482/stream,ENGINE_MCP=127.0.0.1:8000/mcp,DESKTOP=127.0.0.1:3939/mcp"
}

# ---------- Probe one endpoint, return "NAME|URL|HTTP_CODE" ----------
function Probe([string]$Name, [string]$Url) {
    $code = 0
    try {
        $r = Invoke-WebRequest -Uri $Url -Method GET -TimeoutSec ($TimeoutMs / 1000) -UseBasicParsing
        $code = [int]$r.StatusCode
    } catch {
        # 405 = server online but rejects GET (normal for MCP HTTP endpoint)
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $code = [int]$_.Exception.Response.StatusCode
        }
    }
    return ($Name + "|" + $Url + "|" + $code)
}

# ---------- Parse endpoint list ----------
$epList = @()
foreach ($item in $Endpoints.Split(",")) {
    $t = $item.Trim()
    if (-not $t) { continue }
    $eq = $t.IndexOf("=")
    if ($eq -gt 0) {
        $epList += ,@($t.Substring(0, $eq), ("http://" + $t.Substring($eq + 1)))
    } else {
        $epList += ,@($t, ("http://" + $t))
    }
}

# ---------- Probe all endpoints ----------
$eps = @()
foreach ($e in $epList) { $eps += (Probe $e[0] $e[1]) }

$Lines.Add("=================================================")
$Lines.Add(" UnrealVibeEngineering - Environment Health Check")
$Lines.Add(" " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$Lines.Add("=================================================")
$Lines.Add("")
$Lines.Add("--- Automation channel endpoints ---")
$Lines.Add("  (405 = server online, rejects GET; 000/unreachable = DOWN)")
$Total = 0
$Online = 0
foreach ($e in $eps) {
    $parts = $e.Split('|')
    $name = $parts[0]; $url = $parts[1]; $code = [int]$parts[2]
    $Total++
    $isOnline = ($code -ge 200 -and $code -lt 500)
    if ($isOnline) { $Online++ } else { $Down++ }
    $state = if ($isOnline) { "ONLINE" } else { "DOWN" }
    $codeStr = if ($code -eq 0) { "unreachable" } else { "HTTP $code" }
    $Lines.Add(("  {0,-14} {1,-38} {2,-13} {3}" -f $name, $url, $codeStr, $state))
}

# ---------- Key processes ----------
$Lines.Add("")
$Lines.Add("--- Processes ---")
$procs = Get-Process -Name "UnrealEditor","UnrealEditor-Cmd","rider64","Rider.Backend","devenv" -ErrorAction SilentlyContinue
if ($procs) {
    foreach ($p in $procs) {
        $memMB = [math]::Round($p.WorkingSet64 / 1MB)
        $Lines.Add(("  {0,-22} PID={1,-8} MemMB={2}" -f $p.Name, $p.Id, $memMB))
    }
} else {
    $Lines.Add("  (no UnrealEditor / IDE processes found)")
}

# ---------- Listening ports (derived from endpoint list) ----------
$Lines.Add("")
$Lines.Add("--- Listening Ports ---")
$ports = @()
foreach ($e in $epList) {
    if ($e[1] -match ":(\d+)") { $ports += [int]$Matches[1] }
}
$ports = $ports | Sort-Object -Unique
foreach ($p in $ports) {
    $listening = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
    if ($listening) {
        $pidStr = ($listening.OwningProcess | Select-Object -Unique) -join ','
        $Lines.Add(("  {0,-6} LISTENING  (PID {1})" -f $p, $pidStr))
    } else {
        $Lines.Add(("  {0,-6} not listening" -f $p))
    }
}

# ---------- Project path ----------
if ($ProjectPath) {
    $Lines.Add("")
    $Lines.Add("--- Project ---")
    $uproj = Get-ChildItem -Path $ProjectPath -Filter *.uproject -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($uproj) {
        $Lines.Add("  uproject: " + $uproj.FullName)
        # Check whether a native engine MCP plugin is enabled in .uproject.
        # Known native plugin name: ModelContextProtocol (UE 5.x). Community
        # MCP plugin names can be added here as needed.
        try {
            $uprojJson = Get-Content -Path $uproj.FullName -Raw | ConvertFrom-Json
            $mcpFound = $false
            $mcpEnabled = $false
            $toolsetsFound = $false
            $toolsetsEnabled = $false
            if ($uprojJson.Plugins) {
                foreach ($pl in $uprojJson.Plugins) {
                    $pn = [string]$pl.Name
                    if ($pn -eq "ModelContextProtocol") {
                        $mcpFound = $true
                        $Lines.Add(("  plugin entry: {0} enabled={1}" -f $pn, $pl.Enabled))
                        if ($pl.Enabled) { $mcpEnabled = $true }
                    }
                    # Toolsets provider: without AllToolsets the server runs but
                    # list_toolsets is empty (no SlateInspectorToolset etc.).
                    if ($pn -eq "AllToolsets") {
                        $toolsetsFound = $true
                        $Lines.Add(("  plugin entry: {0} enabled={1}" -f $pn, $pl.Enabled))
                        if ($pl.Enabled) { $toolsetsEnabled = $true }
                    }
                }
            }
            if ($mcpEnabled) {
                $Lines.Add("  Engine MCP plugin: ENABLED in .uproject")
            } elseif ($mcpFound) {
                $Lines.Add("  Engine MCP plugin: present but DISABLED in .uproject")
            } else {
                $Lines.Add("  Engine MCP plugin: NOT present in .uproject (ask user whether to enable; if declined, skip in-engine tests and use desktop channel + logs)")
            }
            if ($mcpEnabled -and -not $toolsetsEnabled) {
                $Lines.Add("  Toolsets plugin (AllToolsets): NOT ENABLED in .uproject (server will run but toolsets like SlateInspectorToolset are MISSING; ask user to enable AllToolsets, see MCP_CHANNELS.md 6.3)")
            } elseif ($toolsetsEnabled) {
                $Lines.Add("  Toolsets plugin (AllToolsets): ENABLED in .uproject")
            }
        } catch {
            $Lines.Add("  (could not parse .uproject plugin list)")
        }
        $pluginsDir = Get-ChildItem -Path $ProjectPath -Filter "Plugins" -Directory -ErrorAction SilentlyContinue
        if ($pluginsDir) {
            $Lines.Add("  Plugins dir: " + $pluginsDir.FullName)
        } else {
            $Lines.Add("  Plugins dir: NONE (native engine plugin only)")
        }
    } else {
        $Lines.Add("  no .uproject found at $ProjectPath")
    }
}

# ---------- Summary ----------
$Lines.Add("")
$Lines.Add("--- Summary ---")
if ($Down -eq 0) {
    $Lines.Add("  ALL channels online ($Online/$Total)")
} else {
    $Lines.Add(("  {0}/{1} online, {2} down" -f $Online, $Total, $Down))
    $Lines.Add("  REMINDER (timing discipline): during an active COMPILE the engine")
    $Lines.Add("  channel being down is NORMAL - do not conclude 'unavailable/degraded'")
    $Lines.Add("  from a probe taken before the engine was (re)started with new binaries.")
}

# ---------- Output ----------
$text = $Lines -join [Environment]::NewLine
if ($OutFile) {
    Set-Content -Path $OutFile -Value $text -Encoding UTF8
    Write-Output ("Report written to: " + $OutFile)
} else {
    Write-Output $text
}

if ($Down -eq $Total) { exit 2 }
if ($Down -gt 0) { exit 1 }
exit 0
