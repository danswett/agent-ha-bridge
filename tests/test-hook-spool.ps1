#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the daemon's hook spool (hooks/daemon-hookspool.ps1).

.DESCRIPTION
    Events are dropped into a temporary spool folder as the native hook writes them,
    and the hook functions are replaced by recorders, so these check only how the
    daemon takes them: in order, each to its function with its recorded ancestors,
    under the strict mode its script uses, without leaking a hook's HTTP deadline, and
    retrying a failure once before dropping it.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
$script:DaemonConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-hook-spool-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

$spool = Join-Path ([IO.Path]::GetTempPath()) "spool-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$script:DaemonHookSpoolDirectory = $spool
$script:Logged = @()
function Write-DaemonLog { param([string]$Message) $script:Logged += $Message }

function Add-Spooled { param([string]$Name, [string]$Agent, [string]$Hook, [int[]]$Ancestors = @(), $HookEvent = @{ session_id = 's' })
    New-Item -ItemType Directory -Force -Path $spool | Out-Null
    $body = @{ v = 1; agent = $Agent; hook = $Hook; ancestors = $Ancestors; receivedAt = [DateTimeOffset]::Now.ToString('o'); event = $HookEvent } | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Join-Path $spool $Name), $body)
}

$script:Calls = @()
function Invoke-ClaudeStopHook { param($HookEvent, [int[]]$Ancestors) $script:Calls += "stop:$($HookEvent.session_id):$($Ancestors -join '>')"; 'output that must be discarded' }
function Invoke-ClaudeRegisterHook { param($HookEvent, [int[]]$Ancestors) $script:Calls += "register:$($HookEvent.session_id)" }
function Invoke-CodexHook { param($HookEvent, [int[]]$Ancestors) $script:Calls += "codex:$($HookEvent.hook_event_name)" }

Write-Host '--- nothing waiting ---'
Test-That 'no spool folder costs nothing' { (Invoke-DaemonHookSpool) -eq 0 }

Write-Host '--- taking events ---'
Add-Spooled -Name '0002.json' -Agent 'claude' -Hook 'stop' -Ancestors @(20, 30) -HookEvent @{ session_id = 'b' }
Add-Spooled -Name '0001.json' -Agent 'claude' -Hook 'register' -HookEvent @{ session_id = 'a' }
Add-Spooled -Name '0003.json' -Agent 'codex' -Hook 'hook' -HookEvent @{ session_id = 'c'; hook_event_name = 'PreToolUse' }
[IO.File]::WriteAllText((Join-Path $spool '0000.json.tmp'), '{ half written')
$handled = Invoke-DaemonHookSpool
Test-That 'every complete event is handled' { $handled -eq 3 }
Test-That 'in the order they were written' { ($script:Calls -join ',') -eq 'register:a,stop:b:20>30,codex:PreToolUse' }
Test-That 'each file is removed once handled' { @(Get-ChildItem $spool -Filter '*.json').Count -eq 0 }
Test-That 'a file still being written is left alone' { Test-Path (Join-Path $spool '0000.json.tmp') }

Write-Host '--- how each runs ---'
function Invoke-CopilotPermissionHook { param($HookEvent) $script:Seen = [string]$HookEvent.missing_field }
$script:Seen = 'unset'
Add-Spooled -Name '0010.json' -Agent 'copilot' -Hook 'permission'
Test-That 'Copilot''s hooks run without strict mode, as their scripts do' { (Invoke-DaemonHookSpool) -eq 1 -and $script:Seen -eq '' }
function Invoke-ClaudeNotificationHook { param($HookEvent, [int[]]$Ancestors) $null = $HookEvent.missing_field }
Add-Spooled -Name '0011.json' -Agent 'claude' -Hook 'notification'
Test-That 'Claude''s run under strict mode, as their scripts do' { (Invoke-DaemonHookSpool) -eq 0 }
$null = Invoke-DaemonHookSpool
Test-That 'and strict mode here is untouched either way' { try { $null = ([pscustomobject]@{}).nothing; $false } catch { $true } }

Set-DecisionBridgeDeadline -Seconds 0
function Invoke-ClaudeAskHook { param($HookEvent, [int[]]$Ancestors) Set-DecisionBridgeDeadline -Seconds 45 }
Add-Spooled -Name '0020.json' -Agent 'claude' -Hook 'ask'
$null = Invoke-DaemonHookSpool
Test-That 'a hook''s HTTP deadline does not outlive it' { $null -eq $script:DecisionBridgeDeadline }

Write-Host '--- failures ---'
$script:Logged = @()
function Invoke-ClaudeStopHook { param($HookEvent, [int[]]$Ancestors) throw 'Home Assistant said no' }
Add-Spooled -Name '0030.json' -Agent 'claude' -Hook 'stop'
$null = Invoke-DaemonHookSpool
Test-That 'a failed event is kept for one more try' { Test-Path (Join-Path $spool '0030.json') }
$null = Invoke-DaemonHookSpool
Test-That 'then dropped, and logged' { -not (Test-Path (Join-Path $spool '0030.json')) -and ($script:Logged -join "`n") -match 'dropped spooled hook 0030\.json after 2 attempts: Home Assistant said no' }
Add-Spooled -Name '0031.json' -Agent 'gemini' -Hook 'stop'
$null = Invoke-DaemonHookSpool; $null = Invoke-DaemonHookSpool
Test-That 'an event for an unknown hook is dropped too' { -not (Test-Path (Join-Path $spool '0031.json')) -and ($script:Logged -join "`n") -match 'no handler for gemini/stop' }
[IO.File]::WriteAllText((Join-Path $spool '0032.json'), 'not json')
$null = Invoke-DaemonHookSpool; $null = Invoke-DaemonHookSpool
Test-That 'and a file that is not JSON' { -not (Test-Path (Join-Path $spool '0032.json')) }

Write-Host '--- the fast lane ---'
function Update-DaemonPendingLaunch { param($Headers) }
$script:DaemonLive = @{}
$script:Calls = @()
$script:DaemonHookSpoolSweptAt = [DateTime]::MinValue
Add-Spooled -Name '0040.json' -Agent 'claude' -Hook 'register' -HookEvent @{ session_id = 'new' }
Invoke-DaemonFastActivity -Headers @{} -State @{} | Out-Null
Test-That 'the fast lane takes spooled events even before any session is live' { ($script:Calls -join ',') -eq 'register:new' }

Write-Host '--- noticing new events ---'
Test-That 'just after a sweep, with nothing queued, the spool is not looked at' { -not (Test-DaemonHookSpoolDue) }
Start-DaemonHookSpoolWatcher
Test-That 'the watcher starts' { $null -ne $script:DaemonHookSpoolWatcher }
$null = Invoke-DaemonHookSpool
$temp = Join-Path $spool '0050.json.tmp'
[IO.File]::WriteAllText($temp, (@{ v = 1; agent = 'claude'; hook = 'register'; ancestors = @(); event = @{ session_id = 'watched' } } | ConvertTo-Json))
[IO.File]::Move($temp, (Join-Path $spool '0050.json'))
$waited = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-DaemonHookSpoolDue) -and $waited.ElapsedMilliseconds -lt 1500) { [Threading.Thread]::Sleep(5) }
# macOS delivers file events later than Windows; the sweep is the backstop there.
Test-That 'a file the native hook renames into place is noticed at once' { Test-DaemonHookSpoolDue } "after $($waited.ElapsedMilliseconds) ms"
$script:Calls = @()
$null = Invoke-DaemonHookSpool
Test-That 'and handled' { ($script:Calls -join ',') -eq 'register:watched' }
Test-That 'after which nothing is queued' { -not (Test-DaemonHookSpoolDue) }
$script:DaemonHookSpoolSweptAt = [DateTime]::UtcNow.AddSeconds(-3)
Test-That 'the sweep comes round anyway, in case a notification was missed' { Test-DaemonHookSpoolDue }
Get-EventSubscriber | Where-Object SourceIdentifier -like 'agent-bridge-spool-*' | Unregister-Event
$script:DaemonHookSpoolWatcher.Dispose()

Remove-Item -LiteralPath $spool -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $script:DaemonConfig.LogFile -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All hook spool checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
