#Requires -Version 7.0
<#
.SYNOPSIS
    Tests that the daemon adopts the status Claude's hooks set.

.DESCRIPTION
    Claude's Stop and Notification hooks publish 'idle' and 'waiting' straight to
    Home Assistant. The daemon used to keep its own copy at 'working', so it never
    published 'working' again when the session carried on: a card stuck on
    'waiting' while the agent worked, with no glow. These cover the adoption, the
    publish on a new prompt, and that the tail of a finished turn is not mistaken
    for a resumption.

    Nothing here contacts Home Assistant.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
$script:DaemonConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-hook-status-$([guid]::NewGuid().ToString('N').Substring(0,8)).log"

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($ok) { Write-Host "  PASS  $Name" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

$script:Published = @()
$script:PublishFails = $false
function Set-CopilotMqttStatus {
    param([string]$SessionId, [string]$Status, [hashtable]$Headers, [hashtable]$Attributes)
    if ($script:PublishFails) { throw 'broker down' }
    $script:Published += $Status
}

$headers = @{ Authorization = 'Bearer test' }
function New-Entry { param([string]$Status) [pscustomobject]@{ Name = 'Claude: x'; Machine = 'M'; Status = $Status } }
function New-Session {
    param([string]$Status, [string]$At)
    [pscustomobject]@{ ProcessId = 1; HookStatus = $Status; HookStatusAt = $At }
}

Write-Host ''
Write-Host '--- adopting what a hook set ---'

$entry = New-Entry 'working'
$at = Sync-DaemonHookStatus -Entry $entry -Session (New-Session 'waiting' '2026-09-27T07:00:00Z') -SessionId 's' -Headers $headers
Test-That 'a notification moves the daemon off working' { $entry.Status -eq 'waiting' }
Test-That 'without republishing what the hook already sent' { $script:Published.Count -eq 0 }
Test-That 'and reports when the hook fired' { $at -eq [DateTimeOffset]'2026-09-27T07:00:00Z' }

$script:Published = @()
$entry = New-Entry 'idle'
$null = Sync-DaemonHookStatus -Entry $entry -Session (New-Session 'working' '2026-09-27T07:01:00Z') -SessionId 's' -Headers $headers
Test-That 'a new prompt publishes working, which no hook does itself' {
    $entry.Status -eq 'working' -and ($script:Published -join ',') -eq 'working'
}

$script:Published = @()
$null = Sync-DaemonHookStatus -Entry $entry -Session (New-Session 'working' '2026-09-27T07:01:00Z') -SessionId 's' -Headers $headers
Test-That 'the same hook event is acted on only once' { $script:Published.Count -eq 0 }

$script:PublishFails = $true
$entry = New-Entry 'idle'
$null = Sync-DaemonHookStatus -Entry $entry -Session (New-Session 'working' '2026-09-27T07:02:00Z') -SessionId 's' -Headers $headers
Test-That 'a failed publish is left to retry' { $entry.Status -eq 'idle' -and -not $entry.PSObject.Properties['HookStatusAt'] }
$script:PublishFails = $false
$null = Sync-DaemonHookStatus -Entry $entry -Session (New-Session 'working' '2026-09-27T07:02:00Z') -SessionId 's' -Headers $headers
Test-That 'and the retry succeeds' { $entry.Status -eq 'working' }

$entry = New-Entry 'working'
Test-That 'no recorded hook status changes nothing' {
    ($null -eq (Sync-DaemonHookStatus -Entry $entry -Session (New-Session '' '') -SessionId 's' -Headers $headers)) -and
    $entry.Status -eq 'working'
}
Test-That 'an older registration without hook fields is tolerated' {
    $null -eq (Sync-DaemonHookStatus -Entry $entry -Session ([pscustomobject]@{ ProcessId = 1 }) -SessionId 's' -Headers $headers)
}

Remove-Item -LiteralPath $script:DaemonConfig.LogFile -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) test(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'all hook status checks passed' -ForegroundColor Green
