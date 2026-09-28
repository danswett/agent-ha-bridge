#Requires -Version 7.0
<#
.SYNOPSIS
    The native hook (hook/, Go) and the daemon's spool (daemon-hookspool.ps1), together.

.DESCRIPTION
    Runs the real agent-bridge-hook binary with a Claude event, the way Claude runs it,
    into a temporary TEMP with a fresh daemon heartbeat, then lets the daemon's spool
    code handle what it wrote - which calls the real Invoke-ClaudeRegisterHook. Checks
    the reply, the time the agent waits, and the registration that results.

    The binary comes from AGENT_BRIDGE_HOOK_BIN, or hook/agent-bridge-hook(.exe) after
    `go build` in hook/. Without one the checks are skipped: CI builds it first.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$binary = $env:AGENT_BRIDGE_HOOK_BIN
if (-not $binary) {
    $name = if ($IsWindows) { 'agent-bridge-hook.exe' } else { 'agent-bridge-hook' }
    $binary = Join-Path $PSScriptRoot "..\hook\$name"
}
if (-not (Test-Path -LiteralPath $binary)) {
    Write-Host "SKIP  no native hook binary at $binary (go build in hook/ first)" -ForegroundColor Yellow
    exit 0
}

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

# A private TEMP, for both the binary and the daemon code, so nothing reaches the
# real bridge on this machine.
$temp = Join-Path ([IO.Path]::GetTempPath()) "native-hook-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $temp | Out-Null
$savedTemp = $env:TEMP
$env:TEMP = $temp
$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
. (Join-Path $PSScriptRoot '..\claude\hooks\claude-ask-parser.ps1')
. (Join-Path $PSScriptRoot '..\claude\hooks\claude-session.ps1')
. (Join-Path $PSScriptRoot '..\claude\hooks\claude-hooks.ps1')
$script:DaemonHookSpoolDirectory = Join-Path $temp 'agent-bridge-spool'
$script:DaemonConfig.LogFile = Join-Path $temp 'daemon.log'

try {
    Write-Host '--- with the daemon running ---'
    [IO.File]::WriteAllText((Join-Path $temp 'agent-bridge-daemon.heartbeat'), '1')
    $sessionId = "00000000-0000-4000-8000-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
    $hookEvent = @{ session_id = $sessionId; transcript_path = (Join-Path $temp 't.jsonl'); cwd = $temp; hook_event_name = 'UserPromptSubmit'; prompt = 'hi' } | ConvertTo-Json -Compress

    $times = foreach ($i in 1..5) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $reply = $hookEvent | & $binary claude register 'unused-fallback.ps1'
        $watch.Elapsed.TotalMilliseconds
    }
    $median = @($times | Sort-Object)[2]
    Test-That 'Claude''s hook replies with nothing' { [string]::IsNullOrEmpty(($reply | Out-String).Trim()) }
    Test-That "the agent waits under 100 ms (median $([int]$median) ms)" { $median -lt 100 }
    Test-That 'each run leaves one complete spool file' {
        @(Get-ChildItem $script:DaemonHookSpoolDirectory -Filter '*.json').Count -eq 5 -and
        @(Get-ChildItem $script:DaemonHookSpoolDirectory -Filter '*.tmp').Count -eq 0
    }
    $first = Get-ChildItem $script:DaemonHookSpoolDirectory -Filter '*.json' | Sort-Object Name | Select-Object -First 1 |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json }
    Test-That 'with this shell among the recorded ancestors' { @($first.ancestors) -contains $PID }

    $handled = Invoke-DaemonHookSpool
    Test-That 'the daemon handles all of them' { $handled -eq 5 }
    $registration = Join-Path $temp "agent-bridge-claude\$sessionId.json"
    Test-That 'and the session is registered, working' {
        (Test-Path -LiteralPath $registration) -and (Get-Content -LiteralPath $registration -Raw | ConvertFrom-Json).HookStatus -eq 'working'
    }

    Write-Host '--- with the daemon stopped ---'
    (Get-Item (Join-Path $temp 'agent-bridge-daemon.heartbeat')).LastWriteTime = (Get-Date).AddMinutes(-5)
    $fallback = Join-Path $temp 'fallback.ps1'
    Set-Content -LiteralPath $fallback -Value '$in = [Console]::In.ReadToEnd(); Write-Output "fallback saw $(($in | ConvertFrom-Json).hook_event_name)"'
    $reply = $hookEvent | & $binary claude register $fallback
    Test-That 'the PowerShell hook runs instead, with the same event' { ($reply | Out-String).Trim() -eq 'fallback saw UserPromptSubmit' }
    Test-That 'and nothing is spooled for a daemon that is not there' { @(Get-ChildItem $script:DaemonHookSpoolDirectory -Filter '*.json').Count -eq 0 }

    $reply = '{"toolArgs":{}}' | & $binary copilot ask_user (Join-Path $temp 'no-such-script.ps1')
    Test-That 'a Copilot reply survives a fallback that cannot run' { ($reply | Out-String).Trim() -eq '{"permissionDecision":"allow"}' }
    Test-That 'and the hook always exits 0' { $LASTEXITCODE -eq 0 }
}
finally {
    $env:TEMP = $savedTemp
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All native hook checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
