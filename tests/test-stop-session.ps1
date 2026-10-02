#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for ending a session from Home Assistant.

.DESCRIPTION
    The bridge could start a session remotely but not stop one, so a session that
    went wrong could only be dealt with at the keyboard - and sessions accumulated.

    These cover the two halves without touching Home Assistant or killing anything:

      * Stop-BridgeCopilotSession - graceful `/exit` first, terminate only if the
        process outlives the grace period, and honest reporting either way.
      * Invoke-PendingStops - the press-timestamp contract shared with the Submit and
        Launch buttons: one press acts once, a retained press from a previous run is
        ignored, and a session that is not live is never touched.
      * The confirmation a session that is not idle asks for: one press arms and says
        so, a second within the window ends it, and a confirmation nobody makes in
        time lapses rather than leaving the card asking.
      * That the confirmation is bound to the process it was armed against, that a
        question the card never showed cannot be answered, and that no other activity
        writer can wipe it while it stands.
      * The stop button is published, cleared with the rest of the session, and
        carries a deterministic entity id.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')

$script:DaemonConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-stop-session-$([guid]::NewGuid().ToString('N').Substring(0,8)).log"
$testLogFile = $script:DaemonConfig.LogFile
$headers = @{ Authorization = '******' }

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

# --- Stop-BridgeCopilotSession ---------------------------------------------------

Write-Host '--- stopping a session ---'

$script:Injected = @()
$script:InjectResult = $true
function Send-CopilotSessionPrompt {
    param([string]$SessionId, [string]$Text, [switch]$NoSubmit, [int]$SubmitDelayMs = 300, [int]$ProcessId = 0)
    $script:Injected += [pscustomobject]@{ SessionId = $SessionId; Text = $Text; ProcessId = $ProcessId }
    [pscustomobject]@{ Delivered = $script:InjectResult; ProcessId = $ProcessId; Detail = if ($script:InjectResult) { 'ok:5' } else { 'attach-failed:5' } }
}

# Process liveness is modelled rather than scripted: the process is alive until it
# either exits on its own after N probes (the graceful case) or is terminated, which
# is what makes the post-terminate confirmation meaningful.
$script:Probes = 0
$script:ExitsAfterProbes = 0
$script:ProcKilled = $false
$script:Killed = @()
function Get-Process {
    param([int]$Id, [string]$Name, [switch]$ErrorAction)
    $script:Probes++
    if ($script:ProcKilled) { return $null }
    if ($script:ExitsAfterProbes -gt 0 -and $script:Probes -ge $script:ExitsAfterProbes) { return $null }
    [pscustomobject]@{ Id = $Id }
}
function Stop-Process {
    param([int]$Id, [switch]$Force, [string]$ErrorAction)
    $script:Killed += $Id
    $script:ProcKilled = $true
}

function Reset-StopMocks {
    param([int]$ExitsAfterProbes = 0, [bool]$Inject = $true, [bool]$StartsDead = $false)
    $script:Injected = @()
    $script:Killed = @()
    $script:InjectResult = $Inject
    $script:Probes = 0
    $script:ProcKilled = $StartsDead
    $script:ExitsAfterProbes = $ExitsAfterProbes
}

# Exits on its own at the second probe: the graceful path.
Reset-StopMocks -ExitsAfterProbes 2
$r = Stop-BridgeCopilotSession -SessionId 'sess-1' -ProcessId 1234 -GraceSeconds 3
Test-That 'a graceful stop reports success' { $r.Stopped }
Test-That 'it was not forced' { -not $r.Forced }
Test-That 'it typed /exit into the session' { $script:Injected[0].Text -eq '/exit' }
Test-That 'it targeted the right process' { $script:Injected[0].ProcessId -eq 1234 }
Test-That 'nothing was killed' { $script:Killed.Count -eq 0 }

# Never exits on its own: falls through to termination, which then makes it gone.
Reset-StopMocks
$r = Stop-BridgeCopilotSession -SessionId 'sess-2' -ProcessId 2345 -GraceSeconds 1
Test-That 'a stubborn session is terminated' { $r.Stopped -and $r.Forced }
Test-That 'the right pid was terminated' { $script:Killed -contains 2345 }
Test-That 'the detail says it was terminated' { $r.Detail -match 'terminated' }

# Already gone before the stop even starts.
Reset-StopMocks -StartsDead $true
$r = Stop-BridgeCopilotSession -SessionId 'sess-3' -ProcessId 3456
Test-That 'an already-exited session reports success' { $r.Stopped }
Test-That 'and is not injected into' { $script:Injected.Count -eq 0 }
Test-That 'and is not killed' { $script:Killed.Count -eq 0 }

# No pid to work with.
Reset-StopMocks
$r = Stop-BridgeCopilotSession -SessionId 'sess-4' -ProcessId 0
Test-That 'a missing process id fails cleanly' { -not $r.Stopped -and $r.Detail -match 'no process id' }

# Injection fails, so the terminate path still has to run.
Reset-StopMocks -Inject $false
$r = Stop-BridgeCopilotSession -SessionId 'sess-5' -ProcessId 5678 -GraceSeconds 1
Test-That 'a failed /exit still ends the session' { $r.Stopped -and $r.Forced }
Test-That 'and the failure is reported' { $r.Detail -match 'terminated' }

# --- Invoke-PendingStops ---------------------------------------------------------

Write-Host ''
Write-Host '--- press handling ---'

$script:HaStates = @{}
$script:Stopped = @()
$script:Activity = @()

function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    if (-not $script:HaStates.ContainsKey($EntityId)) { throw "no such entity $EntityId" }
    [pscustomobject]@{ state = $script:HaStates[$EntityId] }
}
function Stop-BridgeCopilotSession {
    param([string]$SessionId, [int]$ProcessId, [int]$GraceSeconds = 12)
    $script:Stopped += [pscustomobject]@{ SessionId = $SessionId; ProcessId = $ProcessId }
    [pscustomobject]@{ Stopped = $true; Forced = $false; Detail = 'exited cleanly' }
}
function Set-CopilotMqttActivity {
    param([string]$SessionId, [string]$Summary, $Detail, [hashtable]$Headers)
    $script:Activity += $Summary
    $script:ActivityDetail = $Detail
}

$node = Get-CopilotMqttNodeId -SessionId 'aaaaaaaa-1111-2222-3333-444444444444'
$sid = 'aaaaaaaa-1111-2222-3333-444444444444'

function Reset-PressTest {
    # Status defaults to idle: the press-timestamp checks below are about the press,
    # not about the confirmation a session that is still working asks for.
    param([string]$Press, [bool]$Live = $true, [string]$Status = 'idle')
    $script:Stopped = @()
    $script:Activity = @()
    $script:ActivityDetail = $null
    $script:DaemonStopArmed = @{}
    $script:DaemonStartedAt = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z')
    $script:HaStates = @{ "button.${node}_stop" = $Press }
    $entry = [pscustomobject]@{ Name = 'S'; Offset = 0 }
    if ($Status) { $entry | Add-Member -NotePropertyName Status -NotePropertyValue $Status }
    $state = @{ $sid = $entry }
    $liveSet = @{}
    if ($Live) {
        $liveSet[$sid] = [pscustomobject]@{ SessionId = $sid; ProcessId = 999 }
    }
    @{ State = $state; Live = $liveSet }
}

$ctx = Reset-PressTest -Press '2026-06-01T12:00:00+00:00'
Invoke-PendingStops -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'a fresh press ends an idle session' { $script:Stopped.Count -eq 1 }
Test-That 'it passes the live process id' { $script:Stopped[0].ProcessId -eq 999 }
Test-That 'it shows progress on the card' { ($script:Activity -join ' ') -match 'Ending' }

# Same press again must not act twice.
Invoke-PendingStops -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'the same press does not end it twice' { $script:Stopped.Count -eq 1 }

$ctx = Reset-PressTest -Press '2025-01-01T00:00:00+00:00'
Invoke-PendingStops -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'a press from before the daemon started is ignored' { $script:Stopped.Count -eq 0 }

$ctx = Reset-PressTest -Press 'unknown'
Invoke-PendingStops -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'an unknown button state is ignored' { $script:Stopped.Count -eq 0 }

$ctx = Reset-PressTest -Press '2026-06-01T12:00:00+00:00' -Live $false
Invoke-PendingStops -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'a session that is not live is never stopped' { $script:Stopped.Count -eq 0 }

# A session published before the stop button existed has no such entity yet.
$ctx = Reset-PressTest -Press '2026-06-01T12:00:00+00:00'
$script:HaStates = @{}
Invoke-PendingStops -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'a missing stop button is survived' { $script:Stopped.Count -eq 0 }

# --- the confirmation ------------------------------------------------------------

# From here on the process behind a session has a readable identity, because that is
# what an ordinary live session has. Get-Process is replaced rather than extended:
# the earlier mock models liveness for Stop-BridgeCopilotSession and carries no start
# time, and a target that cannot be vouched for is now deliberately unconfirmable.
$epoch = [datetime]::Parse('2026-06-01T00:00:00Z')
$script:ProcStarts = @{ 999 = $epoch }
function Get-Process {
    param([int]$Id, [string]$Name, [switch]$ErrorAction)
    if (-not $script:ProcStarts.ContainsKey($Id)) { throw "no process $Id" }
    [pscustomobject]@{ Id = $Id; StartTime = $script:ProcStarts[$Id] }
}

Write-Host ''
Write-Host '--- a session that is not idle takes two presses ---'
# End sits a tap away from Send on the card, and a stray tap mid-turn throws away the
# turn in flight. The transcript survives and the session resumes, but what it was
# doing does not come back.

$ctx = Reset-PressTest -Press '2026-06-01T12:00:00+00:00' -Status 'working'
Invoke-PendingStops -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'one press does not end a working session' { $script:Stopped.Count -eq 0 }
Test-That 'the card asks for a second press' {
    $script:Activity[-1] -eq $script:CopilotEndSessionConfirmNote
}
Test-That 'and says what the second press would interrupt' {
    "$($script:ActivityDetail.hint)" -match 'still working'
}
Test-That 'the session is left alone, not marked ending' { [string]$ctx.State[$sid].Status -eq 'working' }

# The second press is a different press, so the press-stamp contract sees it.
$script:HaStates["button.${node}_stop"] = '2026-06-01T12:00:04+00:00'
Invoke-PendingStops -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'a second press within the window ends it' { $script:Stopped.Count -eq 1 }
Test-That 'and the confirmation is spent, not left armed' { $script:DaemonStopArmed.Count -eq 0 }

# A session the daemon has not classified yet may well be mid-turn, so it is guarded
# too: asking for a second press is the direction that cannot lose work.
$ctx = Reset-PressTest -Press '2026-06-01T12:00:00+00:00' -Status ''
Invoke-PendingStops -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'a session with no status yet is guarded as well' { $script:Stopped.Count -eq 0 }
Test-That 'and is described honestly rather than guessed at' {
    "$($script:ActivityDetail.hint)" -match 'still working'
}

Write-Host ''
Write-Host '--- a confirmation nobody makes in time lapses ---'

$ctx = Reset-PressTest -Press '2026-06-01T12:00:00+00:00' -Status 'waiting'
Invoke-PendingStops -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'a waiting session is guarded too' { $script:Stopped.Count -eq 0 }
Test-That 'and the prompt names what it is waiting on' {
    "$($script:ActivityDetail.hint)" -match 'waiting on you'
}

# Backdated rather than slept through: the window is the daemon's own clock.
$script:DaemonStopArmed[$sid].At = [DateTimeOffset]::Now.AddSeconds(-($script:DaemonConfig.StopConfirmSeconds + 1))
Test-That 'it no longer reads as armed' { -not (Test-DaemonStopArmed -SessionId $sid) }
Clear-DaemonExpiredStopArms -Headers $headers -State $ctx.State
Test-That 'the sweep disarms it' { $script:DaemonStopArmed.Count -eq 0 }
Test-That 'and the card says so rather than going on asking' {
    $script:Activity[-1] -eq $script:CopilotEndSessionLapsedNote
}
# A card left asking for a second press would be asking for something that had
# quietly stopped confirming anything and become a fresh first press.
$script:HaStates["button.${node}_stop"] = '2026-06-01T12:00:30+00:00'
Invoke-PendingStops -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'a press after it lapsed arms again rather than ending' { $script:Stopped.Count -eq 0 }
Test-That 'and asks once more' { $script:Activity[-1] -eq $script:CopilotEndSessionConfirmNote }

# A session that has gone while armed must not be reported on; its card is already
# being retired.
Set-DaemonStopArm -SessionId $sid -Status 'working'
$script:DaemonStopArmed[$sid].At = [DateTimeOffset]::Now.AddMinutes(-5)
$script:Activity = @()
Clear-DaemonExpiredStopArms -Headers $headers -State @{}
Test-That 'a session that has gone is still disarmed' { $script:DaemonStopArmed.Count -eq 0 }
Test-That 'but nothing is published to its retired card' { $script:Activity.Count -eq 0 }

Write-Host ''
Write-Host '--- the prompt stays up while the transcript keeps flowing ---'
# Ten seconds is not long to notice a line that the next batch of tool output would
# otherwise wipe, which made the press look as though it had done nothing.

$script:DaemonStopArmed = @{}
Set-DaemonStopArm -SessionId $sid -Status 'waiting'
# Not $detail: Test-That declares a [string]$Detail parameter, and a script block it
# runs resolves the name in *its* scope, so the hashtable would arrive as ''.
$cardDetail = @{ response = 'half a sentence' }
Test-That 'the status line is taken over while armed' {
    (Get-DaemonCardSummary -SessionId $sid -Summary 'Running: grep' -Detail $cardDetail) -eq $script:CopilotEndSessionConfirmNote
}
Test-That 'the rest of the card stays live underneath' { $cardDetail.response -eq 'half a sentence' }
Test-That 'and the prompt carries its own hint' { "$($cardDetail.hint)" -match 'lapses in' }
# The status the user was told about at the press, not whatever the session has moved
# on to since: rewriting the question underneath them would be worse than slightly
# stale.
Test-That 'the hint keeps saying what the press was answered about' {
    "$($cardDetail.hint)" -match 'waiting on you'
}

$script:DaemonStopArmed = @{}
Test-That 'an unarmed session reports what it is doing, as before' {
    (Get-DaemonCardSummary -SessionId $sid -Summary 'Running: grep' -Detail @{}) -eq 'Running: grep'
}

# Every activity writer has to go through that guard, not only the daemon's
# transcript streamers. A Claude Notification publishes its own status line straight
# through Publish-BridgeSessionStatus, and arriving inside the window it replaced the
# question while the session was still armed - so a user who read the vanished prompt
# as a dead tap pressed again and ended the turn.
function Set-CopilotMqttStatus {
    param([string]$SessionId, [string]$Status, [hashtable]$Headers, [hashtable]$Attributes)
}
$script:DaemonStopArmed = @{}
Set-DaemonStopArm -SessionId $sid -Status 'working' -ProcessId 0
$script:Activity = @()
Publish-BridgeSessionStatus -SessionId $sid -SessionName 'S' -Machine 'M' -Status 'waiting' `
    -Activity 'Needs your permission' -Headers $headers
Test-That 'an adapter publication cannot wipe the question either' {
    $script:Activity[-1] -eq $script:CopilotEndSessionConfirmNote
}

# The case the in-process check cannot reach: a standalone Claude hook has neither
# Get-DaemonCardSummary nor the daemon's in-memory arm, and was publishing its raw
# activity straight over the question. Run in a real child process with only the
# adapter loaded, so the daemon-free route is the one actually exercised.
$childOut = Join-Path ([IO.Path]::GetTempPath()) "stop-prompt-$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
$childScript = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
. '$((Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1'))'
. '$((Join-Path $PSScriptRoot '..\hooks\decision-mqtt.ps1'))'
. '$((Join-Path $PSScriptRoot '..\hooks\bridge-adapter.ps1'))'
function Set-CopilotMqttStatus { param(`$SessionId, `$Status, `$Headers, `$Attributes) }
function Set-CopilotMqttActivity {
    param(`$SessionId, `$Summary, `$Detail, `$Headers)
    Set-Content -LiteralPath '$childOut' -Value `$Summary -Encoding utf8
}
`$daemonLoaded = [bool](Get-Command -Name Get-DaemonCardSummary -CommandType Function -ErrorAction Ignore)
if (`$daemonLoaded) { throw 'the child must not have daemon state' }
Publish-BridgeSessionStatus -SessionId '$sid' -SessionName 'S' -Machine 'M' -Status 'waiting' ``
    -Activity 'Needs your permission' -Headers @{}
"@
$childFile = Join-Path ([IO.Path]::GetTempPath()) "stop-prompt-child-$([guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
Set-Content -LiteralPath $childFile -Value $childScript -Encoding utf8
# Not Get-Process: it is mocked above, and this needs the real executable.
$pwshPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
& $pwshPath -NoProfile -File $childFile 2>&1 | Out-Null
Test-That 'a separate hook process cannot wipe it either' {
    (Get-Content -LiteralPath $childOut -Raw).Trim() -eq $script:CopilotEndSessionConfirmNote
}
# And without a recorded question it publishes exactly what it always did.
Remove-DaemonStopArm -SessionId $sid
& $pwshPath -NoProfile -File $childFile 2>&1 | Out-Null
Test-That 'and with none recorded it publishes what it always did' {
    (Get-Content -LiteralPath $childOut -Raw).Trim() -eq 'Needs your permission'
}
Remove-Item -LiteralPath $childFile, $childOut -Force -ErrorAction SilentlyContinue

$script:DaemonStopArmed = @{}
$script:Activity = @()
Publish-BridgeSessionStatus -SessionId $sid -SessionName 'S' -Machine 'M' -Status 'waiting' `
    -Activity 'Needs your permission' -Headers $headers
Test-That 'and an unarmed session publishes exactly what it used to' {
    $script:Activity[-1] -eq 'Needs your permission'
}

Write-Host ''
Write-Host '--- a confirmation is bound to the process it was armed against ---'
# A session id outlives the process behind it: a session that exits and is resumed
# keeps its id. Armed on the id alone, a second press confirmed against a process the
# first press never saw - reproduced as one stop of the replacement pid.

$script:ProcStarts = @{}
function Invoke-TargetPress {
    param([string]$Press, [int]$ProcessId, [hashtable]$Context)
    $script:HaStates["button.${node}_stop"] = $Press
    $Context.Live[$sid].ProcessId = $ProcessId
    Invoke-PendingStops -Headers $headers -State $Context.State -Live $Context.Live
}

# Control: the same process throughout really does confirm.
$script:ProcStarts = @{ 41001 = $epoch }
$ctx = Reset-PressTest -Press '2026-06-01T12:00:00+00:00' -Status 'working'
$ctx.Live[$sid] | Add-Member -NotePropertyName ProcessId -NotePropertyValue 41001 -Force
Invoke-TargetPress -Press '2026-06-01T12:00:00+00:00' -ProcessId 41001 -Context $ctx
Invoke-TargetPress -Press '2026-06-01T12:00:04+00:00' -ProcessId 41001 -Context $ctx
Test-That 'an unchanged target confirms and stops exactly that process' {
    $script:Stopped.Count -eq 1 -and $script:Stopped[0].ProcessId -eq 41001
}

# The reported failure: the session is replaced between the two presses.
$script:ProcStarts = @{ 41001 = $epoch; 41002 = $epoch.AddMinutes(1) }
$ctx = Reset-PressTest -Press '2026-06-01T12:00:00+00:00' -Status 'working'
Invoke-TargetPress -Press '2026-06-01T12:00:00+00:00' -ProcessId 41001 -Context $ctx
Invoke-TargetPress -Press '2026-06-01T12:00:04+00:00' -ProcessId 41002 -Context $ctx
Test-That 'a replaced process is never stopped by the first press_s confirmation' { $script:Stopped.Count -eq 0 }
Test-That 'it asks again, against the new target' {
    $script:Activity[-1] -eq $script:CopilotEndSessionConfirmNote -and
    [int]$script:DaemonStopArmed[$sid].ProcessId -eq 41002
}
# And the re-armed question is answerable, so the guard does not become a trap.
Invoke-TargetPress -Press '2026-06-01T12:00:08+00:00' -ProcessId 41002 -Context $ctx
Test-That 'a second press against the new target confirms normally' {
    $script:Stopped.Count -eq 1 -and $script:Stopped[0].ProcessId -eq 41002
}

# Windows reuses process ids, so the number alone is not an identity.
$script:ProcStarts = @{ 41001 = $epoch }
$ctx = Reset-PressTest -Press '2026-06-01T12:00:00+00:00' -Status 'working'
Invoke-TargetPress -Press '2026-06-01T12:00:00+00:00' -ProcessId 41001 -Context $ctx
$script:ProcStarts = @{ 41001 = $epoch.AddMinutes(5) }
Invoke-TargetPress -Press '2026-06-01T12:00:04+00:00' -ProcessId 41001 -Context $ctx
Test-That 'a reused process id is not the process that was armed' { $script:Stopped.Count -eq 0 }

# Armed before the daemon knew the pid, confirmed after it learned one. There is no
# arm to inherit now - a press with no process never takes one - so what must hold is
# that the press which does have a target still has to ask.
$script:ProcStarts = @{ 41002 = $epoch }
$ctx = Reset-PressTest -Press '2026-06-01T12:00:00+00:00' -Status 'working'
Invoke-TargetPress -Press '2026-06-01T12:00:00+00:00' -ProcessId 0 -Context $ctx
$stoppedWithNoTarget = $script:Stopped.Count
Invoke-TargetPress -Press '2026-06-01T12:00:04+00:00' -ProcessId 41002 -Context $ctx
Test-That 'a press with no target leaves nothing for a real one to inherit' {
    $script:Stopped.Count -eq $stoppedWithNoTarget -and
    $script:Activity[-1] -eq $script:CopilotEndSessionConfirmNote
}

# Readable when armed, unreadable when confirmed: unverifiable is not consent.
$script:ProcStarts = @{ 41001 = $epoch }
$ctx = Reset-PressTest -Press '2026-06-01T12:00:00+00:00' -Status 'working'
Invoke-TargetPress -Press '2026-06-01T12:00:00+00:00' -ProcessId 41001 -Context $ctx
$script:ProcStarts = @{}
Invoke-TargetPress -Press '2026-06-01T12:00:04+00:00' -ProcessId 41001 -Context $ctx
Test-That 'an identity that can no longer be read is not consent' { $script:Stopped.Count -eq 0 }

# Unreadable on BOTH presses. Treating that as a match would confirm against exactly
# the targets nothing can vouch for - the same positive pid can be a different
# process each time - so there is no success-shaped exception for it.
$script:ProcStarts = @{}
$ctx = Reset-PressTest -Press '2026-06-01T12:00:00+00:00' -Status 'working'
Invoke-TargetPress -Press '2026-06-01T12:00:00+00:00' -ProcessId 41001 -Context $ctx
Invoke-TargetPress -Press '2026-06-01T12:00:04+00:00' -ProcessId 41001 -Context $ctx
Test-That 'an identity unreadable on both presses never confirms' { $script:Stopped.Count -eq 0 }
Test-That 'and it is the real handler refusing, not a stubbed comparison' {
    $null -eq $script:DaemonStopArmed[$sid].Identity -and $script:Activity[-1] -eq $script:CopilotEndSessionConfirmNote
}

# No process at all is a different thing from an unverifiable one. Nothing can be
# lost - the stop reports 'no process id' and touches nothing - and arming would post
# a question no second press could ever answer, then leave it on the card.
$script:ProcStarts = @{}
$ctx = Reset-PressTest -Press '2026-06-01T12:00:00+00:00' -Status 'working'
Invoke-TargetPress -Press '2026-06-01T12:00:00+00:00' -ProcessId 0 -Context $ctx
Test-That 'a press with no process arms nothing' { $script:DaemonStopArmed.Count -eq 0 }
Test-That 'and is answered honestly rather than silently' {
    $script:Stopped.Count -eq 1 -and $script:Stopped[0].ProcessId -eq 0
}
Invoke-TargetPress -Press '2026-06-01T12:00:04+00:00' -ProcessId 0 -Context $ctx
Test-That 'so a second such press cannot inherit a confirmation' {
    $script:Stopped.Count -eq 2 -and $script:DaemonStopArmed.Count -eq 0
}

Write-Host ''
Write-Host '--- a question the card never showed cannot be answered ---'
# Left armed after a failed publish, the user_s natural retry - pressing again
# because the first press looked dead - was read as the confirmation.

$script:ActivityThrows = $false
function Set-CopilotMqttActivity {
    param([string]$SessionId, [string]$Summary, $Detail, [hashtable]$Headers)
    if ($script:ActivityThrows) { throw 'Home Assistant is unreachable' }
    $script:Activity += $Summary
    $script:ActivityDetail = $Detail
}

$script:ProcStarts = @{ 41001 = $epoch }
$ctx = Reset-PressTest -Press '2026-06-01T12:00:00+00:00' -Status 'working'
$script:ActivityThrows = $true
Invoke-TargetPress -Press '2026-06-01T12:00:00+00:00' -ProcessId 41001 -Context $ctx
Test-That 'a prompt that could not be published disarms' { $script:DaemonStopArmed.Count -eq 0 }
$script:ActivityThrows = $false
Invoke-TargetPress -Press '2026-06-01T12:00:04+00:00' -ProcessId 41001 -Context $ctx
Test-That 'so the retry asks rather than ending the session' { $script:Stopped.Count -eq 0 }
Test-That 'and the question is shown this time' {
    $script:Activity[-1] -eq $script:CopilotEndSessionConfirmNote
}

Write-Host ''
Write-Host '--- the lapse note is not lost to an outage ---'
# The arm is released only once the card has been told, or a session would be left
# asking for a press that no longer confirms anything with nothing left to retry.

$ctx = Reset-PressTest -Press '2026-06-01T12:00:00+00:00' -Status 'waiting'
Invoke-TargetPress -Press '2026-06-01T12:00:00+00:00' -ProcessId 41001 -Context $ctx
$script:DaemonStopArmed[$sid].At = [DateTimeOffset]::Now.AddSeconds(-($script:DaemonConfig.StopConfirmSeconds + 1))
$script:ActivityThrows = $true
Clear-DaemonExpiredStopArms -Headers $headers -State $ctx.State
Test-That 'a lapse that could not be published keeps the arm to retry from' {
    $script:DaemonStopArmed.Count -eq 1
}
$script:ActivityThrows = $false
$script:DaemonStopArmed[$sid].RetryAt = [DateTimeOffset]::Now.AddSeconds(-1)
Clear-DaemonExpiredStopArms -Headers $headers -State $ctx.State
Test-That 'the retry publishes it and releases the arm' {
    $script:DaemonStopArmed.Count -eq 0 -and $script:Activity[-1] -eq $script:CopilotEndSessionLapsedNote
}

# A quiet session - waiting, writing no transcript - produces nothing that would
# replace the question on its own, so giving up on the note after a while would leave
# the card asking for a press that confirms nothing, with no retry state left and
# recovery unable to fix it. The arm is held until the note actually lands.
$ctx = Reset-PressTest -Press '2026-06-01T12:00:00+00:00' -Status 'waiting'
Invoke-TargetPress -Press '2026-06-01T12:00:00+00:00' -ProcessId 41001 -Context $ctx
$script:DaemonStopArmed[$sid].At = [DateTimeOffset]::Now.AddSeconds(-($script:DaemonConfig.StopConfirmSeconds + 1))
$script:ActivityThrows = $true
foreach ($sweep in 1..6) {
    $script:DaemonStopArmed[$sid].RetryAt = [DateTimeOffset]::Now.AddSeconds(-1)
    Clear-DaemonExpiredStopArms -Headers $headers -State $ctx.State
}
Test-That 'a long outage never abandons a quiet session_s lapse note' {
    $script:DaemonStopArmed.Count -eq 1
}
$script:ActivityThrows = $false
$script:DaemonStopArmed[$sid].RetryAt = [DateTimeOffset]::Now.AddSeconds(-1)
Clear-DaemonExpiredStopArms -Headers $headers -State $ctx.State
Test-That 'and recovery still replaces the question on its card' {
    $script:DaemonStopArmed.Count -eq 0 -and $script:Activity[-1] -eq $script:CopilotEndSessionLapsedNote
}
# The one event that does make the note pointless is the card going away.
Set-DaemonStopArm -SessionId $sid -Status 'waiting' -ProcessId 41001
$script:DaemonStopArmed[$sid].At = [DateTimeOffset]::Now.AddSeconds(-($script:DaemonConfig.StopConfirmSeconds + 1))
$script:Activity = @()
Clear-DaemonExpiredStopArms -Headers $headers -State @{}
Test-That 'a retired card releases the arm with nothing published' {
    $script:DaemonStopArmed.Count -eq 0 -and $script:Activity.Count -eq 0
}
$script:ActivityThrows = $false

# --- discovery payloads ----------------------------------------------------------

Write-Host ''
Write-Host '--- the stop button is published and cleaned up ---'

$script:MqttMsgs = @()
function Publish-CopilotMqttMessage {
    param([string]$Topic, [AllowEmptyString()][string]$Payload, [hashtable]$Headers, [switch]$Retain)
    $script:MqttMsgs += [pscustomobject]@{ Topic = $Topic; Payload = $Payload }
}

$script:MqttMsgs = @()
[void](Publish-CopilotMqttSession -SessionId 'aaaaaaaa-1111-2222-3333-444444444444' -SessionName 'S' -Machine 'M' -Headers $headers)
$stopCfg = ($script:MqttMsgs | Where-Object { $_.Topic -match "/button/$node/stop/config$" } | Select-Object -First 1)
Test-That 'a stop button is published for the session' { $null -ne $stopCfg }
Test-That 'it has a node-scoped unique id' { $stopCfg.Payload -match "`"unique_id`":`"${node}_stop`"" }
Test-That 'it is named End session' { $stopCfg.Payload -match '"name":"End session"' }
Test-That 'it carries the session availability topic' { $stopCfg.Payload -match '"availability"' }

Write-Host ''
Write-Host '--- the device is named as the session is, once ---'
# The session name already carries its harness prefix, so prefixing again here is what
# produced devices called "Copilot: Copilot: 6fcbab0c" - and, on a Claude session,
# "Copilot: Claude: repo".
$script:MqttMsgs = @()
[void](Publish-CopilotMqttSession -SessionId 'aaaaaaaa-1111-2222-3333-444444444444' -SessionName 'Copilot: my task' -Machine 'M' -Headers $headers)
$statusCfg = ($script:MqttMsgs | Where-Object { $_.Topic -match "/sensor/$node/status/config$" } | Select-Object -First 1)
Test-That 'the device takes the session name verbatim' { $statusCfg.Payload -match '"name":"Copilot: my task"' }
Test-That 'and is not prefixed a second time' { $statusCfg.Payload -notmatch 'Copilot: Copilot:' }
$script:MqttMsgs = @()
[void](Publish-CopilotMqttSession -SessionId 'aaaaaaaa-1111-2222-3333-444444444444' -SessionName 'Claude: repo' -Machine 'M' -Headers $headers)
Test-That 'another agent''s session keeps its own prefix' {
    ($script:MqttMsgs | Where-Object { $_.Topic -match "/sensor/$node/status/config$" }).Payload -match '"name":"Claude: repo"'
}

Write-Host ''
Write-Host '--- renaming a session renames its device, and touches nothing else ---'
$script:MqttMsgs = @()
Update-CopilotMqttSessionName -SessionId 'aaaaaaaa-1111-2222-3333-444444444444' `
    -SessionName 'Copilot: agent-ha-bridge' -Machine 'M' -Headers $headers
$renamed = @($script:MqttMsgs | Where-Object { $_.Topic -match "/sensor/$node/(status|activity)/config$" })
Test-That 'both sensors are republished' { $renamed.Count -eq 2 }
Test-That 'under the new name' { @($renamed | Where-Object { $_.Payload -match '"name":"Copilot: agent-ha-bridge"' }).Count -eq 2 }
Test-That 'retained, or the rename would not stick' { @($script:MqttMsgs).Count -eq 2 }
# Republishing an optimistic entity resets it, which would blank a question mid-flight.
Test-That 'no select, text or button is republished' {
    @($script:MqttMsgs | Where-Object { $_.Topic -match '/(select|text|button)/' }).Count -eq 0
}
Test-That 'the sensors keep their state topics, so the card does not blank' {
    @($renamed | Where-Object { $_.Payload -match '"state_topic"' }).Count -eq 2
}
Test-That 'and the rename returns nothing to its caller' {
    $null -eq (Update-CopilotMqttSessionName -SessionId 'aaaaaaaa-1111-2222-3333-444444444444' `
        -SessionName 'Copilot: agent-ha-bridge' -Machine 'M' -Headers $headers)
}

$script:MqttMsgs = @()
Remove-CopilotMqttSession -SessionId 'aaaaaaaa-1111-2222-3333-444444444444' -Headers $headers
$cleared = ($script:MqttMsgs | Where-Object { $_.Topic -match "/button/$node/stop/config$" } | Select-Object -First 1)
Test-That 'retiring a session clears the stop button too' { $null -ne $cleared -and $cleared.Payload -eq '' }

Write-Host ''
Write-Host '--- reporting what Send did must not empty the card ---'
# Set-CopilotMqttActivity replaces the whole attribute set, and the card header renders
# the last response and the reasoning out of those attributes. Publishing a bare
# "Sending..." therefore blanked both until the next transcript update happened to
# restore them - visible as the card emptying and refilling on every Send.
$script:PublishedSummary = ''
$script:PublishedDetail = $null
$script:CurrentAttributes = [pscustomobject]@{
    response      = 'the last thing the agent said'
    reasoning     = 'its chain of thought'
    history       = 'earlier activity'
    friendly_name = 'Activity'
    icon          = 'mdi:robot'
    hint          = 'stale hint from a previous action'
}

function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    [pscustomobject]@{ state = 'Idle'; attributes = $script:CurrentAttributes }
}
function Set-CopilotMqttActivity {
    param([string]$SessionId, [string]$Summary, $Detail, [hashtable]$Headers)
    $script:PublishedSummary = $Summary
    $script:PublishedDetail = $Detail
}

Set-DaemonTransientActivity -SessionId 'dddddddd-1111-2222-3333-444444444444' `
    -Summary 'Sending...' -Headers $headers

Test-That 'the status itself is published' { $script:PublishedSummary -eq 'Sending...' }
Test-That 'the last response survives' {
    $script:PublishedDetail['response'] -eq 'the last thing the agent said'
}
Test-That 'and so does the reasoning the card renders' {
    $script:PublishedDetail['reasoning'] -eq 'its chain of thought' -and
    $script:PublishedDetail['history'] -eq 'earlier activity'
}
Test-That 'stale detail from a previous action is dropped' {
    -not $script:PublishedDetail.ContainsKey('hint')
}
Test-That "Home Assistant's own attributes are not echoed back" {
    -not $script:PublishedDetail.ContainsKey('friendly_name') -and
    -not $script:PublishedDetail.ContainsKey('icon')
}

Set-DaemonTransientActivity -SessionId 'dddddddd-1111-2222-3333-444444444444' `
    -Summary 'Reply sent' -Extra @{ sent = 'hello' } -Headers $headers
Test-That 'new detail is carried alongside what was preserved' {
    $script:PublishedDetail['sent'] -eq 'hello' -and
    $script:PublishedDetail['response'] -eq 'the last thing the agent said'
}

Write-Host ''
Write-Host '--- a mis-delivered answer is corrected, not just logged ---'
# A warning on the card is not enough: the agent carries straight on from the wrong
# answer, and the next activity update overwrites the warning within seconds.
$correctionFields = @(
    [pscustomobject]@{ Label = 'Glow';  Options = @('Amber', 'Blue', 'No glow'); IsText = $false }
    [pscustomobject]@{ Label = 'Notes'; Options = @();                           IsText = $true }
)

$msg = Get-DaemonAnswerCorrection -Fields $correctionFields -Selections @('No glow', '')
Test-That 'it says the recorded answer is wrong' { $msg -match 'WRONG' -and $msg -match 'Disregard' }
Test-That 'it names the field and the value actually chosen' { $msg -match 'Glow : No glow' }
Test-That 'and marks an empty field as blank rather than dropping it' { $msg -match 'Notes : \(left blank\)' }
Test-That 'it survives having no fields at all' {
    $null -ne (Get-DaemonAnswerCorrection -Fields @() -Selections @())
}

Write-Host ''
Write-Host '--- a follow-up typed while a reply is delivering must survive ---'
# The failure this catches: delivery is not instant - a long reply is typed into the
# console a character at a time - and the box was cleared unconditionally afterwards.
# A follow-up typed in that window was wiped, and the next Send reported "Nothing to
# send". Seen live: ok:460 delivered, then an empty box 11 seconds later.
$script:ClearCalls = @()
$script:BoxValue = ''
$script:Activity = @()

function Get-LiveClaudeSessions { @{} }
function Get-LiveCodexSessions { @{} }
function Set-DaemonTransientActivity {
    param([string]$SessionId, [string]$Summary, $Extra, [hashtable]$Headers)
    $script:Activity += $Summary
}
function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    [pscustomobject]@{ state = $script:BoxValue; attributes = [pscustomobject]@{ question = '' } }
}
function Invoke-HomeAssistantService {
    param([string]$Domain, [string]$Service, [hashtable]$Headers, [hashtable]$Data)
    $script:ClearCalls += [pscustomobject]@{ EntityId = $Data.entity_id; Value = $Data.value }
}

$replySession = 'cccccccc-1111-2222-3333-444444444444'

$script:InjectResult = $true
$script:BoxValue = 'the message that was just sent'
$script:ClearCalls = @()
[void](Invoke-DaemonReply -SessionId $replySession -Text 'the message that was just sent' -Headers $headers)
Test-That 'the box is cleared when it still holds what was sent' {
    $script:ClearCalls.Count -eq 1 -and $script:ClearCalls[0].Value -eq $script:DaemonConfig.ReplyBlankValue
}

$script:BoxValue = 'a follow-up typed while the first was delivering'
$script:ClearCalls = @()
[void](Invoke-DaemonReply -SessionId $replySession -Text 'the message that was just sent' -Headers $headers)
Test-That 'but a follow-up typed in the meantime is left alone' { $script:ClearCalls.Count -eq 0 }

$script:BoxValue = 'the message that was just sent'
$script:ClearCalls = @()
$script:InjectResult = $false
[void](Invoke-DaemonReply -SessionId $replySession -Text 'the message that was just sent' -Headers $headers)
Test-That 'a failed delivery still clears, so it is not silently resent' {
    $script:ClearCalls.Count -eq 1
}
$script:InjectResult = $true

Write-Host ''
Write-Host '--- Send always says something ---'
# A press that produces no visible change reads as a dead button, which is why it
# was getting pressed twice. Every press now ends in a visible outcome.
$script:Activity = @()
$script:Replies = @()
$script:HaStates = @{}

$script:PressUserId = ''
function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    if (-not $script:HaStates.ContainsKey($EntityId)) { throw "no such entity $EntityId" }
    [pscustomobject]@{
        state = $script:HaStates[$EntityId]
        attributes = [pscustomobject]@{ question = '' }
        # Home Assistant records the account behind every press; it is what tells an
        # agent driving the session from the person looking at it.
        context = [pscustomobject]@{ id = 'c1'; parent_id = $null; user_id = $script:PressUserId }
    }
}
function Set-CopilotMqttActivity {
    param([string]$SessionId, [string]$Summary, $Detail, [hashtable]$Headers)
    $script:Activity += $Summary
}
function Invoke-DaemonReply {
    param([string]$SessionId, [string]$Text, [hashtable]$Headers)
    $script:Replies += $Text
}
function Get-CopilotDecisionMarker { param([string]$SessionId) $null }

$replyNode = Get-CopilotMqttNodeId -SessionId 'bbbbbbbb-1111-2222-3333-444444444444'
function Reset-SendTest {
    param([string]$Press, [string]$Reply, [string]$UserId = '')
    $script:Activity = @()
    $script:Replies = @()
    $script:PressUserId = $UserId
    $script:HaStates = @{
        "button.${replyNode}_submit"   = $Press
        "text.${replyNode}_reply"      = $Reply
        "select.${replyNode}_decision" = 'Idle'
    }
    $state = @{ 'bbbbbbbb-1111-2222-3333-444444444444' = [pscustomobject]@{ Name = 'S'; Offset = 0 } }
    $live = @{ 'bbbbbbbb-1111-2222-3333-444444444444' = [pscustomobject]@{ SessionId = 'bbbbbbbb-1111-2222-3333-444444444444'; ProcessId = 5 } }
    @{ State = $state; Live = $live }
}

$ctx = Reset-SendTest -Press '2026-06-01T12:00:00+00:00' -Reply 'hello there'
Invoke-PendingReplies -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'a press with text sends it' { $script:Replies -contains 'hello there' }
Test-That 'and acknowledges the press immediately' { $script:Activity -contains 'Sending...' }

Invoke-PendingReplies -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'the same press does not send twice' { $script:Replies.Count -eq 1 }

$ctx = Reset-SendTest -Press '2026-06-01T12:05:00+00:00' -Reply ' '
Invoke-PendingReplies -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'a press with an empty box sends nothing' { $script:Replies.Count -eq 0 }
Test-That 'but still reports why, rather than looking dead' {
    # Not "Nothing to send" any more: the text is almost always on screen and simply
    # has not reached Home Assistant, because pressing Send does not commit the field.
    # Saying it is empty was both wrong and useless; this says what to do instead.
    $script:Activity -contains 'Waiting for your text'
}
Test-That 'and the press is kept rather than spent' {
    # Burning it here is what forced a second press: by the time the value arrived,
    # the press that was meant to send it had already been consumed.
    [string]$ctx.State['bbbbbbbb-1111-2222-3333-444444444444'].PendingSubmitAt -eq '2026-06-01T12:05:00+00:00'
}

Write-Host ''
Write-Host '--- an agent''s empty box really is empty ---'
# Arming exists for a person: their text is usually on screen and simply has not been
# committed to Home Assistant yet. An agent sets the value through the API, where it
# commits at once - so waiting ten minutes for text that is never coming just leaves
# "Waiting for your text" sitting on the card. Seen for real, from a test press.
function Get-BridgeSetting { param($Path, $Default) if ($Path -eq 'homeAssistant.agentUserIds') { return @('agent-user') } $Default }

$ctx = Reset-SendTest -Press '2026-06-01T13:00:00+00:00' -Reply ' ' -UserId 'agent-user'
Invoke-PendingReplies -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'an agent''s empty press still sends nothing' { $script:Replies.Count -eq 0 }
Test-That 'it is told the box was empty, not asked to type' {
    ($script:Activity -contains 'Nothing to send') -and ($script:Activity -notcontains 'Waiting for your text')
} ($script:Activity -join '|')
Test-That 'and the press is spent, so nothing stays armed' {
    $entry = $ctx.State['bbbbbbbb-1111-2222-3333-444444444444']
    [string]$entry.PendingSubmitAt -eq '' -and [string]$entry.LastSubmitAt -eq '2026-06-01T13:00:00+00:00'
}
Test-That 'the session is marked as agent-driven all the same' {
    [string]$ctx.State['bbbbbbbb-1111-2222-3333-444444444444'].Driver -eq 'agent'
}
Test-That 'but the next terminal turn is not stolen by the glow' {
    # Nothing was sent, so no agent turn is coming; leaving this armed would keep
    # the purple glow on whatever the person types next at the keyboard.
    -not $ctx.State['bbbbbbbb-1111-2222-3333-444444444444'].DriverPending
}

$ctx = Reset-SendTest -Press '2026-06-01T13:05:00+00:00' -Reply ' ' -UserId 'someone-else'
Invoke-PendingReplies -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'a person still gets the benefit of the doubt' {
    $script:Activity -contains 'Waiting for your text'
} ($script:Activity -join '|')
Test-That 'and their press is still kept' {
    [string]$ctx.State['bbbbbbbb-1111-2222-3333-444444444444'].PendingSubmitAt -eq '2026-06-01T13:05:00+00:00'
}

Write-Host ''
Write-Host '--- an armed press fires as soon as the text arrives ---'
# The real sequence, from Home Assistant's own history: three presses landed at
# 19:55:06, :14 and :15 while the box still held its blank sentinel, and the typed
# value was not committed until 19:55:48. Every one of those presses was spent on
# nothing, which is exactly what "I have to press Send more than once" is.
$ctx = Reset-SendTest -Press '2026-06-01T14:00:00+00:00' -Reply ' '
Invoke-PendingReplies -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'the first press sends nothing yet' { $script:Replies.Count -eq 0 }

# The user taps outside the box; Home Assistant finally commits it.
$script:HaStates["text.${replyNode}_reply"] = 'the reply that was on screen all along'
Invoke-PendingReplies -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'the commit sends it without a second press' {
    $script:Replies -contains 'the reply that was on screen all along'
}
Test-That 'and it is sent exactly once' { $script:Replies.Count -eq 1 }

Invoke-PendingReplies -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'the armed press is spent once it has fired' { $script:Replies.Count -eq 1 }

# A box that is genuinely empty must still give up rather than staying armed forever.
$ctx = Reset-SendTest -Press '2026-06-01T14:30:00+00:00' -Reply ' '
Invoke-PendingReplies -Headers $headers -State $ctx.State -Live $ctx.Live
$ctx.State['bbbbbbbb-1111-2222-3333-444444444444'].PendingSubmitSince =
    ([DateTimeOffset]::Now.AddSeconds(-($script:DaemonConfig.SubmitArmSeconds + 5))).ToString('o')
Invoke-PendingReplies -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'an expired arm reports nothing to send' { $script:Activity -contains 'Nothing to send' }
Test-That 'and stops re-reporting once it has given up' {
    $before = $script:Activity.Count
    Invoke-PendingReplies -Headers $headers -State $ctx.State -Live $ctx.Live
    $script:Activity.Count -eq $before
}

$ctx = Reset-SendTest -Press 'unknown' -Reply 'text'
Invoke-PendingReplies -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'an unpressed button sends nothing and says nothing' {
    $script:Replies.Count -eq 0 -and $script:Activity.Count -eq 0
}

Remove-Item -LiteralPath $testLogFile -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '--- a value committed just after the press is still sent ---'
# Home Assistant commits a text entity when it loses focus, and the tap that commits
# it IS the tap on Send. The daemon is woken by the button's own state change, so it
# reads the box before the typed value lands - and a single short re-read meant the
# first Send of a message reported "Nothing to send" and needed pressing twice.
$script:ReadCount = 0
$script:LateValue = 'typed just before pressing Send'
$script:BlankReads = 3

function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    if ($EntityId -match '_reply$') {
        $script:ReadCount++
        $v = if ($script:ReadCount -le $script:BlankReads) { ' ' } else { $script:LateValue }
        return [pscustomobject]@{ state = $v; attributes = [pscustomobject]@{ question = '' } }
    }
    if (-not $script:HaStates.ContainsKey($EntityId)) { throw "no such entity $EntityId" }
    [pscustomobject]@{ state = $script:HaStates[$EntityId]; attributes = [pscustomobject]@{ question = '' } }
}

# Keep the test fast; the ratio of attempts to blank reads is what matters.
$script:DaemonConfig.ReplyCommitWaitMs = 1

$ctx = Reset-SendTest -Press '2026-06-01T13:00:00+00:00' -Reply ' '
$script:ReadCount = 0
Invoke-PendingReplies -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'a late commit is picked up rather than reported as empty' {
    $script:Replies -contains $script:LateValue
}
Test-That 'and it is not reported as nothing to send' {
    $script:Activity -notcontains 'Nothing to send'
}

# A box that never fills must still give up and say so, rather than polling forever.
$script:BlankReads = 999
$ctx = Reset-SendTest -Press '2026-06-01T13:05:00+00:00' -Reply ' '
$script:ReadCount = 0
Invoke-PendingReplies -Headers $headers -State $ctx.State -Live $ctx.Live
$ctx.State['bbbbbbbb-1111-2222-3333-444444444444'].PendingSubmitSince =
    ([DateTimeOffset]::Now.AddSeconds(-($script:DaemonConfig.SubmitArmSeconds + 5))).ToString('o')
$script:ReadCount = 0
Invoke-PendingReplies -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'a genuinely empty box still reports nothing to send' {
    $script:Activity -contains 'Nothing to send'
}
Test-That 'and it stops after the configured number of attempts' {
    $script:ReadCount -le ($script:DaemonConfig.ReplyCommitAttempts + 1)
}

Write-Host ''
Write-Host '--- a just-ended session does not leave a card full of unknowns ---'
# Rebuilding the dashboard removes the card, but a browser keeps rendering the config
# it already has until Home Assistant pushes the new one. Removing the entities in the
# same breath is what left the ended session on screen with every row unknown.
$plan = Update-DaemonRetireQueue -Queued @() -Gone @('s1') -DashboardCurrent $true
Test-That 'an exited session is not retired in the same pass as its card' {
    @($plan.Retire).Count -eq 0 -and (@($plan.Queue) -join ',') -eq 's1'
}

$plan = Update-DaemonRetireQueue -Queued @('s1') -Gone @() -DashboardCurrent $true
Test-That 'it is retired on the next pass, once the frontend has caught up' {
    (@($plan.Retire) -join ',') -eq 's1' -and @($plan.Queue).Count -eq 0
}

$plan = Update-DaemonRetireQueue -Queued @('s1') -Gone @('s2') -DashboardCurrent $true
Test-That 'each pass retires the previous one and queues its own' {
    (@($plan.Retire) -join ',') -eq 's1' -and (@($plan.Queue) -join ',') -eq 's2'
}

$plan = Update-DaemonRetireQueue -Queued @('s1') -Gone @('s2') -DashboardCurrent $false
Test-That 'a failed rebuild retires nothing at all' {
    # Their cards may still be on screen, and pulling entities out from under a live
    # card is the exact thing this ordering exists to prevent.
    @($plan.Retire).Count -eq 0
}
Test-That 'and carries everything forward instead of dropping it' {
    (@($plan.Queue | Sort-Object) -join ',') -eq 's1,s2'
}

$plan = Update-DaemonRetireQueue -Queued @('s1') -Gone @('s1') -DashboardCurrent $false
Test-That 'a session held over twice is not queued twice' {
    @($plan.Queue).Count -eq 1
}

$plan = Update-DaemonRetireQueue -Queued $null -Gone $null -DashboardCurrent $true
Test-That 'empty queues are handled without erroring' {
    @($plan.Retire).Count -eq 0 -and @($plan.Queue).Count -eq 0
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
