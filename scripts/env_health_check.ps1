# =============================================================================
# UE environment capability probe.
#
# Endpoints: comma-separated NAME=url or NAME=host:port/path.
# ExpectedStatus: semicolon-separated NAME=code|code.
# Exit codes: 0=all endpoints match expected status, 1=partial/unexpected,
#             2=all unreachable, 3=invalid input or report write failure.
# =============================================================================
param(
    [string]$ProjectPath = "",
    [int]$TimeoutMs = 5000,
    [string]$OutFile = "",
    [string]$Endpoints = "",
    [string]$ExpectedStatus = "",
    [switch]$AllowRemote
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ($TimeoutMs -lt 100 -or $TimeoutMs -gt 60000) {
    [Console]::Error.WriteLine("TimeoutMs must be between 100 and 60000.")
    exit 3
}

if ([string]::IsNullOrWhiteSpace($Endpoints)) {
    $Endpoints = "IDE_BUILD=http://127.0.0.1:64482/stream,ENGINE_MCP=http://127.0.0.1:8000/mcp,DESKTOP=http://127.0.0.1:3939/mcp"
}
if ([string]::IsNullOrWhiteSpace($ExpectedStatus)) {
    $ExpectedStatus = "IDE_BUILD=200;ENGINE_MCP=200|405;DESKTOP=405"
}

function Fail-Input {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 3
}

trap {
    [Console]::Error.WriteLine("Health-check infrastructure failure: " + $_.Exception.Message)
    exit 3
}

function Parse-ExpectedStatus {
    param([string]$Value)
    $map = @{}
    foreach ($item in $Value.Split(";")) {
        $text = $item.Trim()
        if (-not $text) { continue }
        $parts = $text.Split("=", 2)
        if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0])) {
            Fail-Input ("Invalid ExpectedStatus entry: " + $text)
        }
        $codes = @()
        foreach ($codeText in $parts[1].Split("|")) {
            $code = 0
            if (-not [int]::TryParse($codeText, [ref]$code) -or $code -lt 100 -or $code -gt 599) {
                Fail-Input ("Invalid HTTP status code in ExpectedStatus: " + $codeText)
            }
            $codes += $code
        }
        if ($codes.Count -eq 0) { Fail-Input ("ExpectedStatus has no codes for " + $parts[0]) }
        $map[$parts[0].Trim()] = @($codes)
    }
    return $map
}

function Test-LoopbackHost {
    param([string]$HostName)
    if ($HostName -eq "localhost") { return $true }
    $address = $null
    if ([System.Net.IPAddress]::TryParse($HostName, [ref]$address)) {
        return [System.Net.IPAddress]::IsLoopback($address)
    }
    return $false
}

function Parse-Endpoints {
    param([string]$Value, $ExpectedMap)
    $result = @()
    foreach ($item in $Value.Split(",")) {
        $text = $item.Trim()
        if (-not $text) { continue }
        $parts = $text.Split("=", 2)
        if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
            Fail-Input ("Invalid endpoint entry: " + $text)
        }
        $name = $parts[0].Trim()
        $urlText = $parts[1].Trim()
        if ($urlText -notmatch "^https?://") { $urlText = "http://" + $urlText }
        try { $uri = [Uri]$urlText } catch { Fail-Input ("Invalid endpoint URL: " + $urlText) }
        if (-not $uri.IsAbsoluteUri -or ($uri.Scheme -ne "http" -and $uri.Scheme -ne "https") -or -not $uri.Host) {
            Fail-Input ("Endpoint must be an absolute HTTP(S) URL: " + $urlText)
        }
        if (-not [string]::IsNullOrWhiteSpace($uri.UserInfo) -or -not [string]::IsNullOrWhiteSpace($uri.Query) -or -not [string]::IsNullOrWhiteSpace($uri.Fragment)) {
            Fail-Input ("Endpoint URLs must not contain credentials, query strings, or fragments: " + $name)
        }
        $isLoopback = Test-LoopbackHost $uri.Host
        if (-not $isLoopback -and -not $AllowRemote) {
            Fail-Input ("Remote endpoint is disabled by default: " + $uri.Host + ". Use -AllowRemote only after explicit authorization.")
        }
        if (-not $isLoopback -and $uri.Scheme -ne "https") {
            Fail-Input ("Remote endpoints must use HTTPS: " + $name)
        }
        if (-not $ExpectedMap.ContainsKey($name)) {
            Fail-Input ("No expected status configured for endpoint: " + $name)
        }
        $result += [PSCustomObject]@{ Name = $name; Url = $uri.AbsoluteUri; Uri = $uri; Expected = @($ExpectedMap[$name]) }
    }
    if ($result.Count -eq 0) { Fail-Input "No endpoints configured." }
    return @($result)
}

function Probe-Endpoint {
    param($Endpoint)
    $code = 0
    $errorText = ""
    $response = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($Endpoint.Url)
        $request.Method = "GET"
        $request.Timeout = $TimeoutMs
        $request.ReadWriteTimeout = $TimeoutMs
        $request.AllowAutoRedirect = $false
        $request.KeepAlive = $false
        $response = $request.GetResponse()
        $code = [int]$response.StatusCode
    } catch [System.Net.WebException] {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $response = $_.Exception.Response
            $code = [int]$response.StatusCode
        } else {
            $errorText = $_.Exception.Message
        }
    } catch {
        $errorText = $_.Exception.Message
    } finally {
        if ($null -ne $response) { $response.Close() }
    }
    $matches = $Endpoint.Expected -contains $code
    $state = if ($matches) { "EXPECTED" } elseif ($code -eq 0) { "UNREACHABLE" } else { "HTTP_UNEXPECTED" }
    return [PSCustomObject]@{ Name = $Endpoint.Name; Url = $Endpoint.Url; Code = $code; Expected = $Endpoint.Expected; State = $state; Error = $errorText }
}

function Read-RiderProjectFromConfig {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $json.mcpServers) { return "(RiderMCP entry missing)" }
        foreach ($property in $json.mcpServers.PSObject.Properties) {
            $entry = $property.Value
            $url = [string]$entry.url
            if ($property.Name -ieq "RiderMCP" -or $url -match ":64482/") {
                if ($entry.headers -and $entry.headers.IJ_MCP_SERVER_PROJECT_PATH) {
                    return [string]$entry.headers.IJ_MCP_SERVER_PROJECT_PATH
                }
                return "(IJ_MCP_SERVER_PROJECT_PATH missing)"
            }
        }
        return "(RiderMCP entry missing)"
    } catch {
        return "(invalid JSON: $($_.Exception.Message))"
    }
}

$expectedMap = Parse-ExpectedStatus $ExpectedStatus
$endpointList = Parse-Endpoints $Endpoints $expectedMap
$results = @($endpointList | ForEach-Object { Probe-Endpoint $_ })
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("=================================================")
$lines.Add(" ue-engineering-loop - Environment Health Check")
$lines.Add(" " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
$lines.Add("=================================================")
$lines.Add("")
$lines.Add("--- Endpoint layers: HTTP probe only ---")
$lines.Add("  EXPECTED means the HTTP status matched this endpoint's configured contract.")
$lines.Add("  It does NOT prove MCP handshake or tool availability; perform a read-only tool call next.")

$matched = 0
$unreachable = 0
foreach ($result in $results) {
    if ($result.State -eq "EXPECTED") { $matched++ }
    if ($result.State -eq "UNREACHABLE") { $unreachable++ }
    $codeText = if ($result.Code -eq 0) { "unreachable" } else { "HTTP " + $result.Code }
    $expectedText = ($result.Expected -join "/")
    $lines.Add(("  {0,-14} {1,-38} {2,-14} expected={3,-9} {4}" -f $result.Name, $result.Url, $codeText, $expectedText, $result.State))
    if ($result.Error) { $lines.Add(("    detail: " + $result.Error)) }
}

$lines.Add("")
$lines.Add("--- Processes ---")
$processes = @(Get-Process -Name "UnrealEditor","UnrealEditor-Cmd","rider64","Rider.Backend","devenv" -ErrorAction SilentlyContinue)
if ($processes.Count -eq 0) {
    $lines.Add("  (no UnrealEditor / IDE processes found)")
} else {
    foreach ($process in $processes) {
        $memMB = [Math]::Round($process.WorkingSet64 / 1MB)
        $lines.Add(("  {0,-22} PID={1,-8} MemMB={2}" -f $process.Name, $process.Id, $memMB))
    }
}

$lines.Add("")
$lines.Add("--- Listening Ports ---")
$getNetTcp = Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue
foreach ($port in @($endpointList | ForEach-Object { $_.Uri.Port } | Sort-Object -Unique)) {
    if (-not $getNetTcp) {
        $lines.Add(("  {0,-6} NOT CHECKED (Get-NetTCPConnection unavailable)" -f $port))
        continue
    }
    $listeners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
    if ($listeners.Count -gt 0) {
        $owners = ($listeners.OwningProcess | Sort-Object -Unique) -join ","
        $lines.Add(("  {0,-6} LISTENING (PID {1})" -f $port, $owners))
    } else {
        $lines.Add(("  {0,-6} not listening" -f $port))
    }
}

$lines.Add("")
$lines.Add("--- MCP config project-path drift ---")
$workbuddyConfig = Join-Path $HOME ".workbuddy\mcp.json"
$codebuddyConfig = Join-Path $HOME ".codebuddy\mcp.json"
$wbProject = Read-RiderProjectFromConfig $workbuddyConfig
$cbProject = Read-RiderProjectFromConfig $codebuddyConfig
$lines.Add(("  .workbuddy: " + $(if ($null -eq $wbProject) { "(file missing)" } else { $wbProject })))
$lines.Add(("  .codebuddy : " + $(if ($null -eq $cbProject) { "(file missing)" } else { $cbProject })))
if ($null -ne $wbProject -and $null -ne $cbProject -and $wbProject -ne $cbProject) {
    $lines.Add("  DRIFT: Rider project paths differ. Calls must pass the actual project path explicitly.")
}

$ProjectCheckFailed = $false
if ($ProjectPath) {
    $lines.Add("")
    $lines.Add("--- Project ---")
    try {
        $resolvedProject = (Resolve-Path -LiteralPath $ProjectPath -ErrorAction Stop).Path
        $uprojectFiles = @(Get-ChildItem -LiteralPath $resolvedProject -Filter "*.uproject" -File -ErrorAction Stop)
        if ($uprojectFiles.Count -ne 1) { throw ("expected exactly one .uproject directly under project path; found " + $uprojectFiles.Count) }
        $uproj = $uprojectFiles[0]
        $lines.Add("  uproject: " + $uproj.FullName)
        $json = Get-Content -LiteralPath $uproj.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $pluginStates = @{}
        foreach ($plugin in @($json.Plugins)) { $pluginStates[[string]$plugin.Name] = [bool]$plugin.Enabled }
        foreach ($name in @("ModelContextProtocol", "AllToolsets")) {
            if ($pluginStates.ContainsKey($name)) {
                $lines.Add(("  plugin {0}: enabled={1}" -f $name, $pluginStates[$name]))
            } else {
                $lines.Add(("  plugin {0}: no .uproject entry" -f $name))
            }
        }
        $lines.Add("  Plugin state changes require user authorization; absence is not auto-fixed.")
    } catch {
        $ProjectCheckFailed = $true
        $lines.Add("  PROJECT CHECK ERROR: " + $_.Exception.Message)
    }
}

$lines.Add("")
$lines.Add("--- Summary ---")
$lines.Add(("  HTTP contract matches: {0}/{1}; unreachable: {2}" -f $matched, $results.Count, $unreachable))
$lines.Add("  Next: perform MCP initialize + one read-only tool call before declaring a channel usable.")
$lines.Add("  During compile, ENGINE_MCP being down is expected and must not trigger degradation conclusions.")

$text = $lines -join [Environment]::NewLine
if ($OutFile) {
    $temp = $null
    try {
        $target = [System.IO.Path]::GetFullPath($OutFile)
        $parent = Split-Path -Parent $target
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $temp = $target + ".tmp_" + [Guid]::NewGuid().ToString("N")
        Set-Content -LiteralPath $temp -Value $text -Encoding UTF8 -NoNewline
        Move-Item -LiteralPath $temp -Destination $target -Force
        Write-Output ("Report written to: " + $target)
    } catch {
        [Console]::Error.WriteLine("Failed to write report: " + $_.Exception.Message)
        exit 3
    } finally {
        if ($temp -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-Output $text
}

if ($ProjectCheckFailed) { exit 3 }
if ($matched -eq $results.Count) { exit 0 }
if ($unreachable -eq $results.Count) { exit 2 }
exit 1
