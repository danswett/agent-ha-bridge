#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the daemon's main loop (Start-BridgeDaemon): what it watches, what it
    acts on at once, and the reconcile pass.

.DESCRIPTION
    The loop's steps are separate functions now and are checked here with every Home
    Assistant call and every piece of work replaced by a recorder. Nothing is typed
    anywhere and no daemon runs.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
$script:DaemonConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-daemon-loop-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

$headers = @{ Authorization = 'Bearer test' }
$sid = '11111111-0000-4000-8000-000000000001'
$node = Get-CopilotMqttNodeId -SessionId $sid
$state = @{ $sid = [pscustomobject]@{ Name = 'Claude: x'; Machine = 'M' } }
$script:DaemonLive = @{}

$script:Calls = [System.Collections.Generic.List[string]]::new()
function Write-DaemonLog { param([string]$Message) $script:Calls.Add("log:$Message") }
foreach ($name in 'Invoke-PendingReplies', 'Invoke-PendingStops', 'Sync-DaemonNewSession',
    'Sync-DaemonSessions', 'Repair-CopilotSessionEntities', 'Invoke-DaemonFastActivity', 'Invoke-PendingDecisions',
    'Invoke-PendingCodexApprovals', 'Sync-DaemonUpdateStatus', 'Sync-DaemonClients', 'Clear-DaemonStaleNote',
    'Write-DaemonState', 'Set-BridgeHomeAssistantReachable', 'Set-BridgeDaemonAlive') {
    Set-Item -Path "function:script:$name" -Value ([scriptblock]::Create("`$script:Calls.Add('$name')"))
}
function Get-LiveBridgeSessions {
    param([switch]$AsObservation, [hashtable]$State)
    $script:Calls.Add('Get-LiveBridgeSessions')
    if ($AsObservation) { return New-DaemonDiscoverySnapshot -Live @{} -State $State -Complete }
    @{}
}
$script:DaemonDiscoverySnapshot = New-DaemonDiscoverySnapshot -Live $script:DaemonLive -State $state -Complete

Write-Host '--- what the loop watches ---'
$watch = Get-DaemonWatchEntities -State $state
Test-That 'each session''s reply, payload, question, Send and End controls' {
    $want = "text.${node}_reply", "select.${node}_decision", "button.${node}_submit", "sensor.${node}_reply_payload", "button.${node}_stop"
    @($want | Where-Object { $watch -notcontains $_ }).Count -eq 0
}
Test-That 'and Launch' { $watch -contains $script:DaemonEntity.NewSession }
Test-That 'with no sessions, still Launch' { $w = @(Get-DaemonWatchEntities -State @{}); $w.Count -eq 1 -and $w[0] -eq $script:DaemonEntity.NewSession }

Write-Host '--- what is acted on at once ---'
function Get-HitCalls { param([string]$EntityId)
    $script:Calls.Clear()
    Invoke-DaemonHit -Hit ([pscustomobject]@{ EntityId = $EntityId }) -Headers $headers -State $state
    @($script:Calls)
}
Test-That 'a reply box change delivers replies' { (Get-HitCalls "text.${node}_reply") -join ',' -eq 'Invoke-PendingReplies' }
Test-That 'a reply card payload does too' { (Get-HitCalls "sensor.${node}_reply_payload") -join ',' -eq 'Invoke-PendingReplies' }
Test-That 'and a Send press' { (Get-HitCalls "button.${node}_submit") -join ',' -eq 'Invoke-PendingReplies' }
Test-That 'End session ends it' { (Get-HitCalls "button.${node}_stop") -join ',' -eq 'Invoke-PendingStops' }
Test-That 'Launch launches' { (Get-HitCalls $script:DaemonEntity.NewSession) -join ',' -eq 'Sync-DaemonNewSession' }
Test-That 'a question selector waits for the reconcile' { @(Get-HitCalls "select.${node}_decision").Count -eq 0 }
Test-That 'no change, nothing' { $script:Calls.Clear(); Invoke-DaemonHit -Hit $null -Headers $headers -State $state; $script:Calls.Count -eq 0 }
function Invoke-PendingReplies { throw 'boom' }
Test-That 'a failed delivery is logged, not thrown out of the loop' { ((Get-HitCalls "text.${node}_reply") -join ',') -match 'log:reply delivery failed: boom' }
function Invoke-PendingReplies { $script:Calls.Add('Invoke-PendingReplies') }

Write-Host '--- waiting ---'
$script:ReconcileSeconds = 15
function Wait-CopilotHaStateChange { param($EntityIds, $TimeoutSeconds, $OnTick, $TickMilliseconds)
    $script:TickResult = & $OnTick
    [pscustomobject]@{ EntityId = $EntityIds[0] }
}
$script:DaemonReconcileNow = $true
$script:DaemonWatchFailures = 3
$hit = Wait-DaemonChange -Headers $headers -State $state -WatchEntities @('text.a')
Test-That 'a change is returned' { $hit.EntityId -eq 'text.a' }
Test-That 'the fast lane runs during the wait and can end it early' { $script:TickResult -eq $true }
Test-That 'a working watch resets the failure count' { $script:DaemonWatchFailures -eq 0 }
function Wait-CopilotHaStateChange { param($EntityIds, $TimeoutSeconds, $OnTick, $TickMilliseconds) throw 'socket closed' }
function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) $script:Slept = $Seconds }
$script:DaemonWatchFailures = 2
$hit = Wait-DaemonChange -Headers $headers -State $state -WatchEntities @('text.a')
Test-That 'a failed watch returns nothing' { $null -eq $hit }
Test-That 'and backs off longer each time' { $script:DaemonWatchFailures -eq 3 -and $script:Slept -eq 8 }
$script:DaemonWatchFailures = 20
$null = Wait-DaemonChange -Headers $headers -State $state -WatchEntities @('text.a')
Test-That 'up to a minute' { $script:Slept -eq 60 }

Write-Host '--- what arrives on the socket ---'
# Parsed from JSON rather than built as objects: the shapes below are what Home
# Assistant actually sends, and the bug this covers is only reachable through a
# field that is literally null in the message.
function New-TriggerMessage { param([string]$Json) $Json | ConvertFrom-Json }
$changed = New-TriggerMessage '{"type":"event","event":{"variables":{"trigger":{"platform":"state","entity_id":"button.agent_bridge_x_stop","to_state":{"entity_id":"button.agent_bridge_x_stop","state":"Pressed","attributes":{"friendly_name":"Stop"}}}}}}'
$hit = Get-BridgeStateTriggerHit -Message $changed -IgnoreStates @('unknown', 'unavailable', '')
Test-That 'a state change is reported with its entity, state and attributes' {
    $hit.EntityId -ceq 'button.agent_bridge_x_stop' -and $hit.State -ceq 'Pressed' -and
    $hit.Attributes.friendly_name -ceq 'Stop'
}
$placeholder = New-TriggerMessage '{"type":"event","event":{"variables":{"trigger":{"entity_id":"sensor.a","to_state":{"state":"unavailable"}}}}}'
Test-That 'a placeholder state is not a change worth waking for' {
    $null -eq (Get-BridgeStateTriggerHit -Message $placeholder -IgnoreStates @('unknown', 'unavailable', ''))
}
# The live failure on 2026-10-07. A session's entities were torn down while it was
# still working; Home Assistant reports a removal through the same state trigger,
# with to_state null. Reading .state off that threw out of the whole wait, where the
# daemon's only catch cannot tell a message it did not expect from a socket that has
# dropped - so it logged "watch failed", slept 2s, then 4s, then 8s, and ignored
# every press on the dashboard while nothing at all was wrong with the connection.
$removed = New-TriggerMessage '{"type":"event","event":{"variables":{"trigger":{"entity_id":"sensor.agent_bridge_x_status","from_state":{"state":"working"},"to_state":null}}}}'
Test-That 'an entity being removed is not a change, and is not a socket failure either' {
    $null -eq (Get-BridgeStateTriggerHit -Message $removed -IgnoreStates @('unknown', 'unavailable', ''))
}
Test-That 'a message that is not a trigger event is ignored rather than read' {
    $null -eq (Get-BridgeStateTriggerHit -Message (New-TriggerMessage '{"type":"result","success":true}')) -and
    $null -eq (Get-BridgeStateTriggerHit -Message (New-TriggerMessage '{"type":"event","event":{}}')) -and
    $null -eq (Get-BridgeStateTriggerHit -Message $null)
}

Write-Host '--- the reconcile ---'
$script:Calls.Clear()
Invoke-DaemonReconcile -Headers $headers -State $state
Test-That 'sessions are synced before anything is delivered to them' { $script:Calls.IndexOf('Sync-DaemonSessions') -lt $script:Calls.IndexOf('Invoke-PendingReplies') }
Test-That 'activity streams between the slow steps' { @($script:Calls | Where-Object { $_ -eq 'Invoke-DaemonFastActivity' }).Count -eq 4 }
Test-That 'the daemon marks itself alive last' { $script:Calls[$script:Calls.Count - 1] -eq 'Set-BridgeDaemonAlive' }
function Sync-DaemonSessions { throw 'ha down' }
$script:Calls.Clear()
Invoke-DaemonReconcile -Headers $headers -State $state
Test-That 'a failed pass is logged and does not mark the daemon alive' {
    ($script:Calls -join ',') -match 'log:reconcile failed: ha down' -and $script:Calls -notcontains 'Set-BridgeDaemonAlive'
}

Remove-Item -LiteralPath $script:DaemonConfig.LogFile -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All daemon loop checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
