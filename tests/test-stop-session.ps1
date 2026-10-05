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
[void](Set-DaemonStopArm -SessionId $sid -Status 'working')
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
[void](Set-DaemonStopArm -SessionId $sid -Status 'waiting')
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
# Cold imports do not belong inside a ten-second prompt precondition. The child
# becomes ready first; neither its final parent timestamp nor a reused output file
# proves what its real store consumer saw.
. (Join-Path $PSScriptRoot 'runner-support.ps1')

function Get-StopFixturePathIdentity {
    param([Parameter(Mandatory)][string]$Path)
    $canonical = ConvertTo-BridgeInstallPath $Path
    if ($IsWindows) { $canonical = $canonical.ToLowerInvariant() }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical)))
}

function Get-StopFixtureContextIdentity {
    $context = Get-BridgeInstallContext
    @{
        Home = Get-StopFixturePathIdentity $context.Home
        Config = Get-StopFixturePathIdentity $context.ConfigPath
        Runtime = Get-StopFixturePathIdentity (Get-BridgeRuntimeRoot -Context $context)
        Store = Get-StopFixturePathIdentity (Get-BridgeStopPromptPath)
    }
}

function Write-StopFixtureRecord {
    param([string]$Path, [string]$Invocation, [string]$Kind, [Collections.IDictionary]$Data)
    Assert-BridgeTestPath -Path @($Path, "$Path.pending")
    $json = @{ Schema = 'stop-prompt-1'; Invocation = $Invocation; Kind = $Kind; Data = $Data } |
        ConvertTo-Json -Depth 12 -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    if ($bytes.Length -gt 16384) { throw 'Stop fixture metadata exceeds its byte bound.' }
    $file = [IO.File]::Open("$Path.pending", [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $file.Write($bytes, 0, $bytes.Length); $file.Flush($true) }
    finally { $file.Dispose() }
    [IO.File]::Move("$Path.pending", $Path)
}

function Read-StopFixtureRecord {
    param([string]$Path, [string]$Invocation, [string]$Kind)
    Assert-BridgeTestPath -Path $Path
    $bytes = [byte[]]::new(16385)
    $count = 0
    $file = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        while ($count -lt $bytes.Length) {
            $read = $file.Read($bytes, $count, $bytes.Length - $count)
            if ($read -eq 0) { break }
            $count += $read
        }
    }
    finally { $file.Dispose() }
    if ($count -eq 0 -or $count -gt 16384) { throw 'Stop fixture metadata is empty or oversized.' }
    $record = [Text.UTF8Encoding]::new($false, $true).GetString($bytes, 0, $count) | ConvertFrom-Json -AsHashtable
    if ($record -isnot [Collections.IDictionary] -or $record.Count -ne 4 -or
        $record['Schema'] -cne 'stop-prompt-1' -or $record['Invocation'] -cne $Invocation -or
        $record['Kind'] -cne $Kind -or $record['Data'] -isnot [Collections.IDictionary]) {
        throw 'Stop fixture metadata does not belong to this invocation and stage.'
    }
    $data = $record['Data']
    $fields = switch ($Kind) {
        'Ready' { @('Scenario', 'Context', 'DaemonAbsent', 'ProcessId', 'BirthUtcTicks', 'ReadyUtcTicks') }
        'Release' { @('Scenario') }
        'Result' {
            @('Scenario', 'Phase', 'Context', 'DaemonAbsent', 'PathCalls', 'StoreCalls', 'ConsumerCalls', 'StatusCalls',
                'ActivityCalls', 'StoreIdentity', 'StoreState', 'KeyPresent', 'UntilUtcTicks', 'ConsumerBeforeUtcTicks',
                'ConsumerAfterUtcTicks', 'ConsumerState', 'SessionMatches', 'Summaries', 'Events', 'ObservationError',
                'ErrorType', 'WriteGuard', 'NetworkGuard')
        }
        default { throw 'Stop fixture metadata kind is unsupported.' }
    }
    if (@(Compare-Object $fields @($data.Keys) -CaseSensitive).Count -or $data.Scenario -cnotin @('Armed', 'Cleared')) {
        throw 'Stop fixture metadata fields are invalid.'
    }
    if ($Kind -ne 'Release') {
        if ($data.DaemonAbsent -isnot [bool]) { throw 'Stop fixture daemon observation is invalid.' }
        if ($null -ne $data.Context) {
            if ($data.Context -isnot [Collections.IDictionary] -or
                @(Compare-Object @('Home', 'Config', 'Runtime', 'Store') @($data.Context.Keys) -CaseSensitive).Count) {
                throw 'Stop fixture context identity is invalid.'
            }
            foreach ($value in $data.Context.Values) {
                if ($value -isnot [string] -or $value -cnotmatch '^[A-F0-9]{64}$') { throw 'Stop fixture context hash is invalid.' }
            }
        }
        foreach ($key in @($data.Keys | Where-Object { $_ -like '*UtcTicks' })) {
            if ($null -ne $data[$key] -and ($data[$key] -isnot [string] -or $data[$key] -cnotmatch '^[0-9]{1,19}$')) {
                throw 'Stop fixture timestamp representation is invalid.'
            }
        }
    }
    if ($Kind -eq 'Ready' -and ($null -eq $data.Context -or
        ($data.ProcessId -isnot [int] -and $data.ProcessId -isnot [long]) -or $data.ProcessId -le 0)) {
        throw 'Stop fixture READY identity is invalid.'
    }
    if ($Kind -eq 'Result') {
        if ($data.Phase -cnotin @('Imports', 'Ready', 'WaitingRelease', 'Publishing', 'Complete') -or
            $data.WriteGuard -isnot [bool] -or $data.NetworkGuard -isnot [bool] -or $data.SessionMatches -isnot [bool] -or
            ($null -ne $data.KeyPresent -and $data.KeyPresent -isnot [bool]) -or
            ($null -ne $data.StoreIdentity -and $data.StoreIdentity -cnotmatch '^[A-F0-9]{64}$') -or
            ($null -ne $data.StoreState -and $data.StoreState -cnotin @('Empty', 'Ok', 'Failed')) -or
            ($null -ne $data.ConsumerState -and $data.ConsumerState -cnotin @('Prompt', 'None', 'Unknown')) -or
            ($null -ne $data.ObservationError -and $data.ObservationError -cnotin
                @('PathIdentity', 'UntilType', 'StoreShape', 'ConsumerShape', 'UnexpectedSummary')) -or
            ($null -ne $data.ErrorType -and ($data.ErrorType.Length -gt 256 -or $data.ErrorType -cnotmatch '^System\.[A-Za-z.]+Exception$'))) {
            throw 'Stop fixture result classifications are invalid.'
        }
        foreach ($key in @('PathCalls', 'StoreCalls', 'ConsumerCalls', 'StatusCalls', 'ActivityCalls')) {
            if (($data[$key] -isnot [int] -and $data[$key] -isnot [long]) -or $data[$key] -lt 0 -or $data[$key] -gt 16) {
                throw 'Stop fixture call count is invalid.'
            }
        }
        if ($data.Summaries -isnot [array] -or $data.Summaries.Count -gt 16 -or
            @($data.Summaries | Where-Object { $_ -isnot [string] -or $_ -cnotin
                @('Press End session again to end it', 'Needs your permission') }).Count -or
            $data.Events -isnot [array] -or $data.Events.Count -gt 96 -or
            @($data.Events | Where-Object { $_ -isnot [string] -or $_ -cnotin
                @('Status', 'ConsumerEnter', 'Path', 'Store', 'ConsumerExit', 'Activity') }).Count) {
            throw 'Stop fixture bounded publication observations are invalid.'
        }
    }
    $data
}

function Receive-StopFixtureOutput {
    param([hashtable]$Streams)
    foreach ($capture in $Streams.Values) {
        while ($null -ne $capture.Pending -and $capture.Pending.IsCompleted) {
            $completed = $capture.Pending
            $capture.Pending = $null
            $count = $completed.GetAwaiter().GetResult()
            if ($count -eq 0) { $capture.Ended = $true; break }
            $capture.ObservedBytes += $count
            $retained = [Math]::Min($count, 32768 - [int]$capture.Bytes.Length)
            if ($retained -gt 0) { $capture.Bytes.Write($capture.Buffer, 0, $retained) }
            if ($capture.ObservedBytes -gt 32768) {
                $capture.Overflow = $true
                throw 'Stop fixture child stream exceeded32768 bytes; it is not a successful truncated result.'
            }
            $capture.Pending = $capture.Source.ReadAsync($capture.Buffer, 0, $capture.Buffer.Length)
        }
    }
}

function Invoke-StopFixturePublisher {
    param(
        [Parameter(Mandatory)][ValidateSet('Armed', 'Cleared')][string]$Scenario,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][hashtable]$Headers
    )
    $invocation = [guid]::NewGuid().ToString('N')
    $root = Join-Path $env:TEMP "stop-prompt-$invocation"
    Assert-BridgeTestPath -Path $root
    if (Test-Path -LiteralPath $root) { throw 'The fresh stop fixture root already exists.' }
    $rootCreated = $false
    $childFile = Join-Path $root 'child.ps1'
    $readyFile = Join-Path $root 'ready.json'
    $releaseFile = Join-Path $root 'release.json'
    $resultFile = Join-Path $root 'result.json'
    $process = [Diagnostics.Process]::new()
    $heldHandle = $null
    $streams = @{}
    $watch = [Diagnostics.Stopwatch]::new()
    $primaryFailure = $null
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    $cleanupFailures = [Collections.Generic.List[object]]::new()
    $probe = [ordered]@{
        Scenario = $Scenario; Invocation = $invocation; Stage = 'Preparing'
        ProcessStarted = $false; ProcessId = $null; BirthUtcTicks = $null; ExitObserved = $false; ExitCode = $null
        ExitUtcTicks = $null; LifecycleMilliseconds = $null
        ParentContext = $null; Ready = $null; ReadyObserved = $false
        ReadyUtcTicks = $null; ReadyObservedUtcTicks = $null; ContextMatches = $false
        ArmSucceeded = $null; ArmUtcTicks = $null; ParentUntilUtcTicks = $null; ClearObserved = $null
        ReleaseUtcTicks = $null; Child = $null; ErrorType = $null; WriteGuard = $false; NetworkGuard = $false
        ForcedCleanup = $false; CleanupIdentity = 'NotNeeded'; CleanupErrors = @(); Streams = @{}; FixtureFilesRemoved = $false
    }
    try {
        [void][IO.Directory]::CreateDirectory($root)
        $rootCreated = $true
        $expectedContext = Get-StopFixtureContextIdentity
        $probe.ParentContext = $expectedContext
        $childText = @'
param(
    [Parameter(Mandatory, Position=0)][string]$FixtureRepository,
    [Parameter(Mandatory, Position=1)][string]$FixtureRoot,
    [Parameter(Mandatory, Position=2)][string]$FixtureInvocation,
    [Parameter(Mandatory, Position=3)][ValidateSet('Armed','Cleared')][string]$FixtureScenario,
    [Parameter(Mandatory, Position=4)][string]$FixtureSession
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
'@
        foreach ($helper in @('Get-StopFixturePathIdentity', 'Get-StopFixtureContextIdentity',
            'Write-StopFixtureRecord', 'Read-StopFixtureRecord')) {
            $childText += "`nfunction $helper {`n$((Get-Command -Name $helper -CommandType Function).Definition)`n}`n"
        }
        $childText += @'
$script:StopFixture = @{
    Scenario = $FixtureScenario; Phase = 'Imports'; Context = $null; DaemonAbsent = $false
    PathCalls = 0; StoreCalls = 0; ConsumerCalls = 0; StatusCalls = 0; ActivityCalls = 0
    StoreIdentity = $null; StoreState = $null; KeyPresent = $null; UntilUtcTicks = $null
    ConsumerBeforeUtcTicks = $null; ConsumerAfterUtcTicks = $null; ConsumerState = $null
    SessionMatches = $true; Summaries = @(); Events = @(); ObservationError = $null
    ErrorType = $null; WriteGuard = $false; NetworkGuard = $false
}
try {
    . (Join-Path $FixtureRepository 'hooks\decision-bridge-common.ps1')
    . (Join-Path $FixtureRepository 'hooks\decision-mqtt.ps1')
    . (Join-Path $FixtureRepository 'hooks\bridge-adapter.ps1')
    Assert-BridgeTestPath -Path $FixtureRoot
    Assert-BridgeTestEnvironment -Required
    $script:StopFixture.DaemonAbsent = -not [bool](Get-Command Get-DaemonCardSummary -CommandType Function -ErrorAction Ignore)
    if (-not $script:StopFixture.DaemonAbsent) { throw 'Stop fixture child unexpectedly loaded daemon state.' }
    $script:StopFixture.Context = Get-StopFixtureContextIdentity
    $script:StopOriginalPath = (Get-Command Get-BridgeStopPromptPath -CommandType Function).ScriptBlock
    $script:StopOriginalStore = (Get-Command Read-BridgeStopPromptStore -CommandType Function).ScriptBlock
    $script:StopOriginalConsumer = (Get-Command Get-BridgeStopPrompt -CommandType Function).ScriptBlock
    function Get-BridgeStopPromptPath {
        $script:StopFixture.PathCalls++
        $actualPath = & $script:StopOriginalPath
        try { $script:StopFixture.StoreIdentity = Get-StopFixturePathIdentity $actualPath }
        catch { $script:StopFixture.ObservationError = 'PathIdentity'; throw }
        $script:StopFixture.Events += 'Path'
        return $actualPath
    }
    function Read-BridgeStopPromptStore {
        $script:StopFixture.StoreCalls++
        $actualStore = & $script:StopOriginalStore
        $script:StopFixture.Events += 'Store'
        if ($actualStore -is [Collections.IDictionary] -and $actualStore.Contains('State') -and
            $actualStore.Contains('Prompts') -and $actualStore.Prompts -is [Collections.IDictionary]) {
            $script:StopFixture.StoreState = [string]$actualStore.State
            $script:StopFixture.KeyPresent = $actualStore.Prompts.ContainsKey($FixtureSession)
            if ($script:StopFixture.KeyPresent) {
                $until = $actualStore.Prompts[$FixtureSession].Until
                if ($until -is [DateTimeOffset]) { $script:StopFixture.UntilUtcTicks = [string]$until.UtcDateTime.Ticks }
                else { $script:StopFixture.ObservationError = 'UntilType' }
            }
        }
        else { $script:StopFixture.ObservationError = 'StoreShape' }
        return $actualStore
    }
    function Get-BridgeStopPrompt {
        param([Parameter(Mandatory)][string]$SessionId)
        $script:StopFixture.ConsumerCalls++
        $script:StopFixture.SessionMatches = $script:StopFixture.SessionMatches -and ($SessionId -ceq $FixtureSession)
        $script:StopFixture.ConsumerBeforeUtcTicks = [string][DateTimeOffset]::Now.UtcDateTime.Ticks
        $script:StopFixture.Events += 'ConsumerEnter'
        try {
            $actualPrompt = & $script:StopOriginalConsumer @PSBoundParameters
            if ($actualPrompt -is [Collections.IDictionary] -and $actualPrompt.Contains('State')) {
                $script:StopFixture.ConsumerState = [string]$actualPrompt.State
            }
            else { $script:StopFixture.ObservationError = 'ConsumerShape' }
            return $actualPrompt
        }
        finally {
            $script:StopFixture.ConsumerAfterUtcTicks = [string][DateTimeOffset]::Now.UtcDateTime.Ticks
            $script:StopFixture.Events += 'ConsumerExit'
        }
    }
    function Set-CopilotMqttStatus {
        param($SessionId, $Status, $Headers, $Attributes)
        $script:StopFixture.StatusCalls++
        $script:StopFixture.SessionMatches = $script:StopFixture.SessionMatches -and ($SessionId -ceq $FixtureSession)
        $script:StopFixture.Events += 'Status'
    }
    function Set-CopilotMqttActivity {
        param($SessionId, $Summary, $Detail, $Headers)
        $script:StopFixture.ActivityCalls++
        $script:StopFixture.SessionMatches = $script:StopFixture.SessionMatches -and ($SessionId -ceq $FixtureSession)
        if ($Summary -cnotin @('Press End session again to end it', 'Needs your permission')) {
            $script:StopFixture.ObservationError = 'UnexpectedSummary'
            throw 'Stop fixture received an unexpected synthetic summary.'
        }
        $script:StopFixture.Summaries += [string]$Summary
        $script:StopFixture.Events += 'Activity'
    }
    $self = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $ready = @{
            Scenario = $FixtureScenario; Context = $script:StopFixture.Context; DaemonAbsent = $script:StopFixture.DaemonAbsent
            ProcessId = $self.Id; BirthUtcTicks = [string]$self.StartTime.ToUniversalTime().Ticks
            ReadyUtcTicks = [string][DateTimeOffset]::Now.UtcDateTime.Ticks
        }
    }
    finally { $self.Dispose() }
    $script:StopFixture.Phase = 'Ready'
    Write-StopFixtureRecord -Path (Join-Path $FixtureRoot 'ready.json') -Invocation $FixtureInvocation -Kind Ready -Data $ready
    $releaseWatch = [Diagnostics.Stopwatch]::StartNew()
    $script:StopFixture.Phase = 'WaitingRelease'
    while (-not [IO.File]::Exists((Join-Path $FixtureRoot 'release.json'))) {
        if ($releaseWatch.ElapsedMilliseconds -ge 15000) { throw 'Stop fixture release was not observed within15 seconds.' }
        Start-Sleep -Milliseconds 20
    }
    $release = Read-StopFixtureRecord -Path (Join-Path $FixtureRoot 'release.json') -Invocation $FixtureInvocation -Kind Release
    if ($release.Scenario -cne $FixtureScenario) { throw 'Stop fixture release scenario differs.' }
    $script:StopFixture.Phase = 'Publishing'
    Publish-BridgeSessionStatus -SessionId $FixtureSession -SessionName 'S' -Machine 'M' -Status 'waiting' `
        -Activity 'Needs your permission' -Headers @{}
    if ($script:StopFixture.ObservationError) { throw 'Stop fixture observation failed; no behavioral success is claimed.' }
    $script:StopFixture.Phase = 'Complete'
}
catch {
    $script:StopFixture.ErrorType = $_.Exception.GetType().FullName
    $cause = $_.Exception
    while ($null -ne $cause) {
        if ($cause.Data['BridgeTestWriteBlocked']) { $script:StopFixture.WriteGuard = $true }
        if ($cause.Data['BridgeTestNetworkBlocked']) { $script:StopFixture.NetworkGuard = $true }
        $cause = $cause.InnerException
    }
    throw
}
finally {
    Write-StopFixtureRecord -Path (Join-Path $FixtureRoot 'result.json') -Invocation $FixtureInvocation -Kind Result -Data $script:StopFixture
}
exit 0
'@
        Assert-BridgeTestPath -Path $childFile
        [IO.File]::WriteAllText($childFile, $childText, [Text.UTF8Encoding]::new($false))
        $process.StartInfo = New-BridgeTestProcessStartInfo -ScriptPath $childFile -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT `
            -ScriptArguments @($script:BridgeTestRepository, $root, $invocation, $Scenario, $SessionId)
        $probe.Stage = 'Starting'
        $watch.Start()
        $probe.ProcessStarted = $process.Start()
        if (-not $probe.ProcessStarted) { throw 'Stop fixture child did not start.' }
        $probe.ProcessId = $process.Id
        $heldHandle = $process.SafeHandle
        $probe.BirthUtcTicks = [string]$process.StartTime.ToUniversalTime().Ticks
        $process.StandardInput.Close()
        foreach ($streamName in @('Stdout', 'Stderr')) {
            $source = if ($streamName -eq 'Stdout') { $process.StandardOutput.BaseStream } else { $process.StandardError.BaseStream }
            $capture = @{
                Source = $source; Buffer = [byte[]]::new(4096); Bytes = [IO.MemoryStream]::new()
                Pending = $null; ObservedBytes = 0L; Ended = $false; Overflow = $false
            }
            $capture.Pending = $source.ReadAsync($capture.Buffer, 0, $capture.Buffer.Length)
            $streams[$streamName] = $capture
        }
        $probe.Stage = 'WaitingReady'
        while (-not [IO.File]::Exists($readyFile)) {
            Receive-StopFixtureOutput $streams
            if ($process.HasExited) { throw 'Stop fixture child exited before READY.' }
            if ($watch.ElapsedMilliseconds -ge 30000) { throw 'Stop fixture READY exceeded30 seconds.' }
            [void]$process.WaitForExit(20)
        }
        $ready = Read-StopFixtureRecord -Path $readyFile -Invocation $invocation -Kind Ready
        $probe.Ready = $ready
        if ($watch.ElapsedMilliseconds -ge 30000 -or $ready.Scenario -cne $Scenario -or $ready.ProcessId -ne $probe.ProcessId -or
            $ready.BirthUtcTicks -cne $probe.BirthUtcTicks -or $ready.DaemonAbsent -ne $true -or $process.HasExited) {
            throw 'Stop fixture READY is not from the live owned daemon-free child.'
        }
        foreach ($key in @('Home', 'Config', 'Runtime', 'Store')) {
            if ($ready.Context[$key] -cne $expectedContext[$key]) { throw 'Stop fixture child context or store differs.' }
        }
        $readyTicks = 0L
        if (-not [long]::TryParse([string]$ready.ReadyUtcTicks, [ref]$readyTicks) -or
            $readyTicks -lt [long]$probe.BirthUtcTicks) {
            throw 'Stop fixture READY timestamp is unavailable.'
        }
        $probe.ReadyUtcTicks = [string]$readyTicks
        $probe.ReadyObservedUtcTicks = [string][DateTimeOffset]::Now.UtcDateTime.Ticks
        if ($readyTicks -gt [long]$probe.ReadyObservedUtcTicks) { throw 'Stop fixture READY clock ordering is invalid.' }
        $probe.ReadyObserved = $true
        $probe.ContextMatches = $true
        $probe.Stage = 'SettingPrecondition'
        if ($Scenario -eq 'Armed') {
            if ($script:DaemonConfig.StopConfirmSeconds -ne 10) { throw 'The production confirmation window changed.' }
            $script:DaemonStopArmed = @{}
            $armResult = Set-DaemonStopArm -SessionId $SessionId -Status 'working' -ProcessId 0
            if ($armResult -isnot [bool]) { throw 'Stop fixture armer returned an ambiguous outcome.' }
            $probe.ArmSucceeded = $armResult
            if (-not $probe.ArmSucceeded) { throw 'Stop fixture could not establish the real arm.' }
            $probe.ArmUtcTicks = [string]$script:DaemonStopArmed[$SessionId].At.UtcDateTime.Ticks
            $store = Read-BridgeStopPromptStore
            if ($store.State -cne 'Ok' -or -not $store.Prompts.ContainsKey($SessionId)) { throw 'Stop fixture arm has no readable record.' }
            $probe.ParentUntilUtcTicks = [string]$store.Prompts[$SessionId].Until.UtcDateTime.Ticks
            if ([long]$probe.ArmUtcTicks -lt [long]$probe.ReadyObservedUtcTicks) { throw 'Stop fixture arm did not follow READY.' }
            $script:Activity = @()
            Publish-BridgeSessionStatus -SessionId $SessionId -SessionName 'S' -Machine 'M' -Status 'waiting' `
                -Activity 'Needs your permission' -Headers $Headers
            Test-That 'an adapter publication cannot wipe the question either' {
                $script:Activity[-1] -eq $script:CopilotEndSessionConfirmNote
            }
            if ($script:Activity[-1] -ne $script:CopilotEndSessionConfirmNote) { throw 'Stop fixture in-process precondition failed.' }
        }
        else {
            Remove-DaemonStopArm -SessionId $SessionId
            $store = Read-BridgeStopPromptStore
            $probe.ClearObserved = $store.State -cin @('Empty', 'Ok') -and -not $store.Prompts.ContainsKey($SessionId)
            if (-not $probe.ClearObserved) { throw 'Stop fixture real clear was not observed.' }
        }
        $probe.ReleaseUtcTicks = [string][DateTimeOffset]::Now.UtcDateTime.Ticks
        if ([long]$probe.ReleaseUtcTicks -lt [long]$probe.ReadyObservedUtcTicks -or
            ($Scenario -eq 'Armed' -and ([long]$probe.ReleaseUtcTicks -lt [long]$probe.ArmUtcTicks -or
                [long]$probe.ReleaseUtcTicks -ge [long]$probe.ParentUntilUtcTicks))) {
            throw 'Stop fixture precondition elapsed or its clock moved before release.'
        }
        $probe.Stage = 'WaitingExit'
        Write-StopFixtureRecord -Path $releaseFile -Invocation $invocation -Kind Release -Data @{ Scenario = $Scenario }
        while (-not $process.HasExited) {
            Receive-StopFixtureOutput $streams
            if ($watch.ElapsedMilliseconds -ge 45000) { throw 'Stop fixture child exceeded its45-second lifecycle.' }
            [void]$process.WaitForExit(20)
        }
        $probe.ExitObserved = $true
        $probe.ExitCode = [int]$process.ExitCode
        $probe.ExitUtcTicks = [string]$process.ExitTime.ToUniversalTime().Ticks
        $probe.LifecycleMilliseconds = $watch.ElapsedMilliseconds
        if ($probe.LifecycleMilliseconds -ge 45000) { throw 'Stop fixture observed completion outside its lifecycle bound.' }
        $probe.Stage = 'ReadingResult'
        if ([IO.File]::Exists($resultFile)) {
            $probe.Child = Read-StopFixtureRecord -Path $resultFile -Invocation $invocation -Kind Result
        }
        if ($probe.ExitCode -ne 0 -or $null -eq $probe.Child) { throw 'Stop fixture requires a real zero exit and a fresh result.' }
        $child = $probe.Child
        if ($null -eq $child.Context) { throw 'Stop fixture completed result has no context identity.' }
        foreach ($key in @('Home', 'Config', 'Runtime', 'Store')) {
            if ($child.Context[$key] -cne $expectedContext[$key]) { throw 'Stop fixture completed context differs.' }
        }
        if ($child.Scenario -cne $Scenario -or $child.Phase -cne 'Complete' -or -not $child.DaemonAbsent -or
            $child.ErrorType -or $child.ObservationError -or $child.WriteGuard -or $child.NetworkGuard -or
            -not $child.SessionMatches -or $child.PathCalls -ne 1 -or $child.StoreCalls -ne 1 -or
            $child.ConsumerCalls -ne 1 -or $child.StatusCalls -ne 1 -or $child.ActivityCalls -ne 1 -or
            @($child.Summaries).Count -ne 1 -or $child.StoreIdentity -cne $expectedContext.Store -or
            ($child.Events -join ',') -cne 'Status,ConsumerEnter,Path,Store,ConsumerExit,Activity') {
            throw 'Stop fixture did not observe one unchanged real consumer and publication.'
        }
        $beforeTicks = 0L; $afterTicks = 0L
        if (-not [long]::TryParse([string]$child.ConsumerBeforeUtcTicks, [ref]$beforeTicks) -or
            -not [long]::TryParse([string]$child.ConsumerAfterUtcTicks, [ref]$afterTicks) -or
            $beforeTicks -lt [long]$probe.ReleaseUtcTicks -or $afterTicks -lt $beforeTicks) {
            throw 'Stop fixture consumer clock observation is missing or nonmonotonic.'
        }
        if ($Scenario -eq 'Armed') {
            $untilTicks = 0L
            if ($child.StoreState -cne 'Ok' -or $child.KeyPresent -ne $true -or $child.ConsumerState -cne 'Prompt' -or
                -not [long]::TryParse([string]$child.UntilUtcTicks, [ref]$untilTicks) -or
                $child.UntilUtcTicks -cne $probe.ParentUntilUtcTicks -or $afterTicks -ge $untilTicks) {
                throw 'Stop fixture positive consumer was not proven wholly inside the actual live-record window.'
            }
        }
        elseif ($child.StoreState -cnotin @('Empty', 'Ok') -or $child.KeyPresent -ne $false -or
            $null -ne $child.UntilUtcTicks -or $child.ConsumerState -cne 'None') {
            throw 'Stop fixture cleared consumer did not observe actual None.'
        }
        $probe.Stage = 'Complete'
    }
    catch {
        $primaryFailure = $_
        $probe.ErrorType = $_.Exception.GetType().FullName
        $cause = $_.Exception
        while ($null -ne $cause) {
            if ($cause.Data['BridgeTestWriteBlocked']) { $probe.WriteGuard = $true }
            if ($cause.Data['BridgeTestNetworkBlocked']) { $probe.NetworkGuard = $true }
            $cause = $cause.InnerException
        }
    }
    finally {
        if ($probe.ProcessStarted) {
            try {
                $probe.CleanupIdentity = 'Inspecting'
                if (-not $process.HasExited) {
                    $cleanupBirth = 0L
                    if ($null -eq $heldHandle -or $heldHandle.IsInvalid -or $heldHandle.IsClosed -or
                        $probe.ProcessId -isnot [int] -or $probe.ProcessId -le 0 -or $process.Id -ne $probe.ProcessId -or
                        $probe.BirthUtcTicks -isnot [string] -or $probe.BirthUtcTicks -cnotmatch '^[1-9][0-9]{0,18}$' -or
                        -not [long]::TryParse($probe.BirthUtcTicks, [ref]$cleanupBirth) -or
                        $cleanupBirth -gt [datetime]::MaxValue.Ticks -or
                        $process.StartTime.ToUniversalTime().Ticks -ne $cleanupBirth) {
                        $probe.CleanupIdentity = 'Refused'
                        throw 'Stop fixture PID cleanup requires a valid held handle, PID and observed matching full birth.'
                    }
                    $probe.CleanupIdentity = 'Verified'
                    $probe.ForcedCleanup = $true
                    Microsoft.PowerShell.Management\Stop-Process -Id $probe.ProcessId -Force -ErrorAction Stop
                    if (-not $process.WaitForExit(5000)) { throw 'Stop fixture owned child did not exit during bounded cleanup.' }
                }
                else { $probe.CleanupIdentity = 'AlreadyExited' }
                $probe.ExitObserved = $true
                $probe.ExitCode = [int]$process.ExitCode
                $probe.ExitUtcTicks = [string]$process.ExitTime.ToUniversalTime().Ticks
            }
            catch {
                if ($probe.CleanupIdentity -eq 'Inspecting') { $probe.CleanupIdentity = 'Unavailable' }
                $cleanupFailures.Add($_)
                $cleanupErrors.Add('OwnedProcess:' + $_.Exception.GetType().FullName)
            }
        }
        $drain = [Diagnostics.Stopwatch]::StartNew()
        try {
            while (@($streams.Values | Where-Object { -not $_.Ended }).Count -and $drain.ElapsedMilliseconds -lt 5000) {
                Receive-StopFixtureOutput $streams
                if (@($streams.Values | Where-Object { -not $_.Ended }).Count) { Start-Sleep -Milliseconds 10 }
            }
            if (@($streams.Values | Where-Object { -not $_.Ended }).Count) { throw 'Stop fixture streams did not finish draining.' }
        }
        catch {
            $cleanupFailures.Add($_)
            $cleanupErrors.Add('Streams:' + $_.Exception.GetType().FullName)
        }
        if ($probe.ExitObserved -and $null -eq $probe.Child -and [IO.File]::Exists($resultFile)) {
            try { $probe.Child = Read-StopFixtureRecord -Path $resultFile -Invocation $invocation -Kind Result }
            catch {
                $cleanupFailures.Add($_)
                $cleanupErrors.Add('ResultRecord:' + $_.Exception.GetType().FullName)
            }
        }
        if ($null -ne $probe.Child) {
            if ($probe.Child.WriteGuard) { $probe.WriteGuard = $true }
            if ($probe.Child.NetworkGuard) { $probe.NetworkGuard = $true }
        }
        # Child errors can contain paths. Retain bounded byte counts/hashes with the
        # actual exit and safe observations, rather than echoing those streams.
        foreach ($streamName in $streams.Keys) {
            $capture = $streams[$streamName]
            $probe.Streams[$streamName] = @{
                ObservedBytes = $capture.ObservedBytes; RetainedBytes = $capture.Bytes.Length; Complete = $capture.Ended
                Overflow = $capture.Overflow; Sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($capture.Bytes.ToArray()))
            }
            try { $capture.Source.Dispose(); $capture.Bytes.Dispose() }
            catch {
                $cleanupFailures.Add($_)
                $cleanupErrors.Add('StreamDispose:' + $_.Exception.GetType().FullName)
            }
        }
        try { $process.Dispose() }
        catch {
            $cleanupFailures.Add($_)
            $cleanupErrors.Add('ProcessDispose:' + $_.Exception.GetType().FullName)
        }
        $watch.Stop()
        if ($rootCreated) {
            foreach ($path in @($childFile, $readyFile, "$readyFile.pending", $releaseFile, "$releaseFile.pending", $resultFile, "$resultFile.pending")) {
                try {
                    Assert-BridgeTestPath -Path $path
                    if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
                }
                catch {
                    $cleanupFailures.Add($_)
                    $cleanupErrors.Add('Files:' + $_.Exception.GetType().FullName)
                }
            }
            try {
                Assert-BridgeTestPath -Path $root
                [IO.Directory]::Delete($root, $false)
                $probe.FixtureFilesRemoved = $true
            }
            catch {
                $cleanupFailures.Add($_)
                $cleanupErrors.Add('Directory:' + $_.Exception.GetType().FullName)
            }
        }
        else { $probe.FixtureFilesRemoved = $true }
        foreach ($failure in $cleanupFailures) {
            $cause = $failure.Exception
            while ($null -ne $cause) {
                if ($cause.Data['BridgeTestWriteBlocked']) { $probe.WriteGuard = $true }
                if ($cause.Data['BridgeTestNetworkBlocked']) { $probe.NetworkGuard = $true }
                $cause = $cause.InnerException
            }
        }
        $probe.CleanupErrors = $cleanupErrors.ToArray()
        $json = $probe | ConvertTo-Json -Depth 12 -Compress
        if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 16384) { throw 'Stop fixture reporting exceeded its metadata bound.' }
        Write-Host ('STOP_PROMPT_FIXTURE ' + $json)
    }
    if ($null -eq $primaryFailure -and $cleanupFailures.Count) { $primaryFailure = $cleanupFailures[0] }
    if ($null -ne $primaryFailure) {
        if ($probe.WriteGuard) { $primaryFailure.Exception.Data['BridgeTestWriteBlocked'] = $true }
        if ($probe.NetworkGuard) { $primaryFailure.Exception.Data['BridgeTestNetworkBlocked'] = $true }
        throw $primaryFailure
    }
    if ($cleanupErrors.Count -or $probe.ForcedCleanup -or -not $probe.ExitObserved -or $probe.ExitCode -ne 0) {
        throw 'Stop fixture cleanup or native completion failed; no behavioral success is claimed.'
    }
    [pscustomobject]$probe
}

# Not Get-Process: it is mocked above, and the unchanged later probes need the real executable.
$pwshPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$armedPublisher = Invoke-StopFixturePublisher -Scenario Armed -SessionId $sid -Headers $headers
Test-That 'a separate hook process cannot wipe it either' {
    $armedPublisher.Child.Summaries[0] -eq $script:CopilotEndSessionConfirmNote
}
$clearedPublisher = Invoke-StopFixturePublisher -Scenario Cleared -SessionId $sid -Headers $headers
Test-That 'and with none recorded it publishes what it always did' {
    $clearedPublisher.Child.Summaries[0] -eq 'Needs your permission'
}

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
[void](Set-DaemonStopArm -SessionId $sid -Status 'waiting' -ProcessId 41001)
$script:DaemonStopArmed[$sid].At = [DateTimeOffset]::Now.AddSeconds(-($script:DaemonConfig.StopConfirmSeconds + 1))
$script:Activity = @()
Clear-DaemonExpiredStopArms -Headers $headers -State @{}
Test-That 'a retired card releases the arm with nothing published' {
    $script:DaemonStopArmed.Count -eq 0 -and $script:Activity.Count -eq 0
}
$script:ActivityThrows = $false

Write-Host ''
Write-Host '--- the shared prompt store fails closed ---'
# The store is what stops a publisher in another process wiping a visible question.
# Every case below drives the real store and the real callers; none substitutes a
# store result.

$promptPath = Get-BridgeStopPromptPath
Remove-Item -LiteralPath $promptPath -Force -ErrorAction SilentlyContinue

# An arm whose record cannot be written is consent nobody else can see. A directory
# in the file's place is a real, unmockable write failure.
$script:DaemonStopArmed = @{}
[void][IO.Directory]::CreateDirectory($promptPath)
Test-That 'a record that cannot be written refuses the arm' {
    (Set-DaemonStopArm -SessionId $sid -Status 'working' -ProcessId 41001) -eq $false
}
Test-That 'and leaves nothing armed to confirm against' { $script:DaemonStopArmed.Count -eq 0 }
$script:ProcStarts = @{ 41001 = $epoch }
$ctx = Reset-PressTest -Press '2026-06-01T12:00:00+00:00' -Status 'working'
$script:Activity = @()
Invoke-TargetPress -Press '2026-06-01T12:00:00+00:00' -ProcessId 41001 -Context $ctx
Invoke-TargetPress -Press '2026-06-01T12:00:04+00:00' -ProcessId 41001 -Context $ctx
Test-That 'so two presses through the real handler still stop nothing' { $script:Stopped.Count -eq 0 }
# Asking would be worse than saying nothing. There is no arm, so no expiry sweep entry
# and nothing that will ever lapse the question - on a quiet session it would sit there
# asking for a press that could never be accepted.
Test-That 'and the card is told the press could not be acted on' {
    $script:Activity[-1] -eq 'Could not end session'
}
Test-That 'rather than being asked to confirm something that is not armed' {
    $script:Activity -notcontains $script:CopilotEndSessionConfirmNote
}
$script:Activity = @()
Clear-DaemonExpiredStopArms -Headers $headers -State $ctx.State
Test-That 'a press that never armed leaves no lapse to publish' { $script:Activity.Count -eq 0 }
Remove-Item -LiteralPath $promptPath -Recurse -Force -ErrorAction SilentlyContinue

# A document that cannot be read is not a document that says nothing.
Set-Content -LiteralPath $promptPath -Value '{"a":{"until":' -Encoding utf8
Test-That 'a truncated document reads as a failure, not as empty' {
    (Read-BridgeStopPromptStore).State -eq 'Failed'
}
Test-That 'and a lookup says it does not know' { (Get-BridgeStopPrompt -SessionId $sid).State -eq 'Unknown' }
Test-That 'a record is refused rather than blindly overwriting the others' {
    (Write-BridgeStopPrompt -SessionId $sid -Until ([datetimeoffset]::Now.AddSeconds(10))) -eq $false
}
foreach ($shape in @('null', '[1,2]', '"text"', '{"a":"notanobject"}', '{"a":{"until":"not-a-time"}}')) {
    Set-Content -LiteralPath $promptPath -Value $shape -Encoding utf8
    Test-That "a document holding $shape is rejected rather than throwing" {
        (Read-BridgeStopPromptStore).State -eq 'Failed' -and
        (Get-BridgeStopPrompt -SessionId $sid).State -eq 'Unknown'
    }
}
Test-That 'a per-session clear is refused too, rather than deleting the whole store' {
    # It used to be honoured, on the grounds that removing the document repairs it.
    # But a per-session clear removes the whole file, and the other sessions recorded
    # in it keep their arms - so their questions were unpinned while a second press
    # could still confirm them.
    (Write-BridgeStopPrompt -SessionId $sid -Until $null) -eq $false -and (Test-Path -LiteralPath $promptPath)
}
Test-That 'and whole-store repair is what removes it' {
    (Clear-BridgeStopPromptStore) -eq $true -and -not (Test-Path -LiteralPath $promptPath)
}

# Two sessions, one store. Repair by deletion while another session's arm is still
# live is the cross-writer defect arriving through the repair itself: that session can
# still confirm a second press, but nothing is left pinning its question, so the next
# standalone publisher writes straight over it.
$sidB = 'cccccccc-1111-2222-3333-444444444444'
$script:ProcStarts = @{ 41001 = $epoch; 41002 = $epoch }
$script:DaemonStopArmed = @{}
[void](Set-DaemonStopArm -SessionId $sid -Status 'working' -ProcessId 41001)
[void](Set-DaemonStopArm -SessionId $sidB -Status 'working' -ProcessId 41002)
Test-That 'two sessions can hold questions at the same time' {
    (Get-BridgeStopPrompt -SessionId $sid).State -eq 'Prompt' -and
    (Get-BridgeStopPrompt -SessionId $sidB).State -eq 'Prompt'
}
Remove-DaemonStopArm -SessionId $sid
Test-That 'a healthy clear of one leaves the other asking' {
    (Get-BridgeStopPrompt -SessionId $sid).State -eq 'None' -and
    (Get-BridgeStopPrompt -SessionId $sidB).State -eq 'Prompt' -and
    $script:DaemonStopArmed.ContainsKey($sidB)
}

# The same pair, with the document corrupted underneath them.
[void](Set-DaemonStopArm -SessionId $sid -Status 'working' -ProcessId 41001)
Set-Content -LiteralPath $promptPath -Value '{"a":{"until":' -Encoding utf8
Remove-DaemonStopArm -SessionId $sid
Test-That 'clearing one session never leaves another armed with no question recorded' {
    -not ((Get-BridgeStopPrompt -SessionId $sidB).State -eq 'None' -and
          $script:DaemonStopArmed.ContainsKey($sidB))
}
Test-That 'repairing an unreadable store disarms the consent it would strand' {
    $script:DaemonStopArmed.Count -eq 0 -and -not (Test-Path -LiteralPath $promptPath)
}
Test-That 'so that session asks again rather than confirming' {
    (Test-DaemonStopConfirms -SessionId $sidB -ProcessId 41002) -eq $false
}
$script:DaemonStopArmed = @{}
$script:ProcStarts = @{ 41001 = $epoch }

# A reader in another process must never see a half-written document.
$script:DaemonStopArmed = @{}
Test-That 'arming records the question' {
    (Set-DaemonStopArm -SessionId $sid -Status 'working' -ProcessId 41001) -eq $true
}
Test-That 'a published record is complete and parseable to a competing reader' {
    (Get-Content -LiteralPath $promptPath -Raw).Trim().EndsWith('}') -and
    (Read-BridgeStopPromptStore).State -eq 'Ok'
}
Test-That 'no temporary file is left beside it' { -not (Test-Path -LiteralPath "$promptPath.pending") }
Test-That 'and that reader sees the question' { (Get-BridgeStopPrompt -SessionId $sid).State -eq 'Prompt' }

# What a hook in its own process does with each answer, through the real publisher.
$childOut2 = Join-Path ([IO.Path]::GetTempPath()) "stop-store-$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
$childScript2 = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
. '$((Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1'))'
. '$((Join-Path $PSScriptRoot '..\hooks\decision-mqtt.ps1'))'
. '$((Join-Path $PSScriptRoot '..\hooks\bridge-adapter.ps1'))'
function Set-CopilotMqttStatus { param(`$SessionId, `$Status, `$Headers, `$Attributes) }
function Set-CopilotMqttActivity {
    param(`$SessionId, `$Summary, `$Detail, `$Headers)
    Add-Content -LiteralPath '$childOut2' -Value `$Summary -Encoding utf8
}
Publish-BridgeSessionStatus -SessionId '$sid' -SessionName 'S' -Machine 'M' -Status 'waiting' ``
    -Activity 'Needs your permission' -Headers @{}
"@
$childFile2 = Join-Path ([IO.Path]::GetTempPath()) "stop-store-child-$([guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
Set-Content -LiteralPath $childFile2 -Value $childScript2 -Encoding utf8
Set-Content -LiteralPath $promptPath -Value '{"a":{"until":' -Encoding utf8
& $pwshPath -NoProfile -File $childFile2 2>&1 | Out-Null
Test-That 'an unreadable store makes a hook withhold the line rather than wipe it' {
    -not (Test-Path -LiteralPath $childOut2)
}
Remove-Item -LiteralPath $promptPath -Force -ErrorAction SilentlyContinue
& $pwshPath -NoProfile -File $childFile2 2>&1 | Out-Null
Test-That 'while a genuinely absent store publishes normally' {
    (Get-Content -LiteralPath $childOut2 -Raw).Trim() -eq 'Needs your permission'
}
Remove-Item -LiteralPath $childFile2, $childOut2 -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '--- loading the daemon for its functions leaves a running one alone ---'
# The clearing loop used to sit where the shared state is declared, which runs on
# every dot-source. A hook or a test loading the daemon under NORUN therefore unpinned
# the questions of the daemon that was actually running.
$script:DaemonStopArmed = @{}
[void](Set-DaemonStopArm -SessionId $sid -Status 'working' -ProcessId 41001)
$norunProbe = Join-Path ([IO.Path]::GetTempPath()) "stop-norun-$([guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
Set-Content -LiteralPath $norunProbe -Encoding utf8 -Value @"
`$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. '$((Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1'))'
"@
& $pwshPath -NoProfile -File $norunProbe 2>&1 | Out-Null
Test-That 'a NORUN load preserves records it did not create' {
    (Get-BridgeStopPrompt -SessionId $sid).State -eq 'Prompt'
}
Clear-DaemonStopPrompts
Test-That 'and actual startup is what clears them' {
    (Get-BridgeStopPrompt -SessionId $sid).State -eq 'None' -and -not (Test-Path -LiteralPath $promptPath)
}
Test-That 'an unreadable store is repaired at startup rather than left' {
    Set-Content -LiteralPath $promptPath -Value '{"a":{"until":' -Encoding utf8
    Clear-DaemonStopPrompts
    -not (Test-Path -LiteralPath $promptPath)
}
Remove-Item -LiteralPath $norunProbe -Force -ErrorAction SilentlyContinue
$script:DaemonStopArmed = @{}

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
