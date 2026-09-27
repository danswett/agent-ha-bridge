<#
    Copilot CLI bridge daemon.

    One long-running process that owns every always-on concern of the Home Assistant
    bridge, so the CLI hooks no longer have to:

      - Reconciles live sessions. Each live session gets its own set of Home
        Assistant entities published through MQTT discovery, and they are torn down
        when the session exits.
      - Streams live activity from each session transcript, at a verbosity the user
        controls from Home Assistant.
      - Delivers a reply typed on the dashboard straight into the running CLI by
        writing to its console input buffer.

    Why a daemon at all: the old design did this work inside blocking hooks. Blocking
    the agentStop hook to carry a reply back made the CLI queue anything typed in the
    terminal, which deadlocked against the very signal the hook was waiting for. The
    workaround - only arm the reply box on turns longer than three minutes - disabled
    the feature almost entirely (21 of 22 turns skipped in the bridge log). Delivering
    by console injection from an outside process means no turn ever has to be held
    open, so the reply box can be offered on every finished turn.

    The daemon is deliberately not required for `ask_user`. That path must be
    synchronous, so the hook still blocks - but it now waits on a WebSocket push
    rather than polling, and the daemon is not in its critical path.
#>

[CmdletBinding()]
param(
    [int]$ReconcileSeconds = 15,
    [switch]$RunOnce
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot 'decision-mqtt.ps1')
. (Join-Path $PSScriptRoot 'decision-ha-websocket.ps1')
. (Join-Path $PSScriptRoot 'decision-inject.ps1')
. (Join-Path $PSScriptRoot 'bridge-update.ps1')
. (Join-Path $PSScriptRoot 'session-launch.ps1')

# This machine's own per-machine entities, resolved once. One Home Assistant is
# normally shared between machines, so every one of these is scoped to the machine
# that publishes it - reading the unscoped id would mean acting on whichever machine
# happened to write it last, which is exactly how a single press of Launch used to
# start a session everywhere at once.
$script:DaemonMachineSlug = Get-BridgeMachineSlug
$script:DaemonMachineName = [Environment]::MachineName
$script:DaemonEntity = @{
    Sessions      = Get-BridgeMachineEntityId -Domain 'sensor' -Key 'sessions'          -Slug $script:DaemonMachineSlug
    Update        = Get-BridgeMachineEntityId -Domain 'update' -Key 'update'            -Slug $script:DaemonMachineSlug
    InstallUpdate = Get-BridgeMachineEntityId -Domain 'button' -Key 'install_update'    -Slug $script:DaemonMachineSlug
    NewPrompt     = Get-BridgeMachineEntityId -Domain 'text'   -Key 'new_prompt'        -Slug $script:DaemonMachineSlug
    NewWorkspace  = Get-BridgeMachineEntityId -Domain 'select' -Key 'new_workspace'     -Slug $script:DaemonMachineSlug
    NewProfile    = Get-BridgeMachineEntityId -Domain 'select' -Key 'new_profile'       -Slug $script:DaemonMachineSlug
    NewAgent      = Get-BridgeMachineEntityId -Domain 'select' -Key 'new_agent'         -Slug $script:DaemonMachineSlug
    NewResume     = Get-BridgeMachineEntityId -Domain 'select' -Key 'new_resume'        -Slug $script:DaemonMachineSlug
    NewSession    = Get-BridgeMachineEntityId -Domain 'button' -Key 'new_session'       -Slug $script:DaemonMachineSlug
    NewResult     = Get-BridgeMachineEntityId -Domain 'sensor' -Key 'new_session_result' -Slug $script:DaemonMachineSlug
    Online        = Get-BridgeMachineEntityId -Domain 'binary_sensor' -Key 'online'      -Slug $script:DaemonMachineSlug
}

$script:DaemonConfig = @{
    MutexName = 'Local\AgentBridgeDaemon'
    VerboseToggle = 'input_boolean.agent_bridge_detailed_activity'
    LogFile = (Join-Path $env:TEMP 'agent-bridge-daemon.log')
    StateFile = (Join-Path $env:TEMP 'agent-bridge-daemon-state.json')
    # Written by the self-updater when an install finishes, read by whichever daemon
    # is running next, so a press of the install button ends in a visible
    # "updated to X" (or a failure) notification.
    UpdateOutcomeFile = (Join-Path $env:TEMP 'agent-bridge-update-outcome.json')
    # Written once the pre-rename entities have been swept, so the sweep does not
    # repeat on every daemon start.
    LegacyCleanupMarker = (Join-Path $env:TEMP 'agent-bridge-legacy-cleanup.json')
    # The same, for the entities that predate being scoped to a machine.
    UnscopedCleanupMarker = (Join-Path $env:TEMP 'agent-bridge-unscoped-cleanup.json')
    # Cap how much transcript is read in one pass, so a session that produced a huge
    # burst cannot stall the loop.
    MaxTailBytes = 512000
    ActivityHistory = 12
    ResponseMaxChars = 6000
    ReasoningMaxChars = 4000
    # Re-publish the global status at least this often even when the live set is
    # unchanged, so a Home Assistant restart that drops retained values re-establishes
    # the count within a bounded window. Between re-asserts an unchanged set is silent.
    GlobalReassertSeconds = 300
    # The liveness heartbeat and how long Home Assistant waits before calling a
    # machine offline. Three missed beats, so a single slow reconcile does not make a
    # running machine flicker out of the launch picker.
    OnlineHeartbeatSeconds = 60
    OnlineExpireSeconds = 180
    # MCP-client presence changes slowly and only affects rendering (the MCP server
    # owns its own decision entities), so its full /api/states discovery scan is cached
    # for this long rather than repeated on every reconcile.
    McpScanCacheSeconds = 60
    # Home Assistant renders a text entity holding "" as the literal "(empty value)".
    # A single space renders as a genuinely blank field instead, so the reply box looks
    # ready to type in. Everything that reads the box treats whitespace as empty.
    ReplyBlankValue = ' '
    # The resumable-session list comes from an Agency call that reads every session
    # on the machine, so it is cached for this long instead of being repeated on
    # every reconcile.
    # How long to keep polling the reply box after Send is pressed, waiting for Home
    # Assistant to commit what was typed. Six attempts at 500ms covers the commit
    # comfortably while costing nothing when the value is already there.
    ReplyCommitAttempts = 6
    ReplyCommitWaitMs = 500
    # How long a press of Send stays armed while the typed text has still not reached
    # Home Assistant. Clicking Send does not commit the text field - confirmed from
    # Home Assistant's own history, where three presses landed before the box was ever
    # committed - so the press waits for the value instead of being spent on nothing.
    #
    # Ten minutes, not ninety seconds. Ninety was measured against real use and lost:
    # a press armed at 20:26:16 expired at 20:27:49, and the reply went out on a second
    # press at 20:34 - exactly the double press this is meant to remove. Pressing Send
    # is deliberate, so honouring it later is right; what must not happen is a reply
    # going out that Send was never pressed for at all.
    SubmitArmSeconds = 600
    ResumeCacheSeconds = 180
    # How soon to retry after a fetch that failed or came back empty, rather than
    # waiting out the full interval with a list known to be wrong.
    ResumeRetrySeconds = 20
}

# Session-set signature of the last dashboard rebuild, so the dashboard is only
# regenerated when a session appears or exits, not on every reconcile.
$script:DaemonDashboardSignature = $null

# The fast lane's view between reconciles (see Invoke-DaemonFastActivity): the live
# sessions and verbose setting the last reconcile saw, and the last-seen write time of
# each Claude registration.
$script:DaemonLive = @{}
$script:DaemonVerbose = $false
$script:DaemonRegistrationStamps = @{}

# The session the last Launch press started, followed until it registers (see
# Update-DaemonPendingLaunch), and a request for a reconcile now rather than at the
# end of the interval, so a newly registered session's card appears straight away.
$script:DaemonPendingLaunch = $null
$script:DaemonReconcileNow = $false

# Adapter installs started for agents installed after the bridge (Sync-DaemonClients),
# and why the daemon should restart once the pass is done - to load a new adapter.
$script:DaemonClientSetup = @{}
$script:DaemonRestartRequested = ''

# Sessions whose reply-payload sensor has been checked this run, so the probe costs
# one Home Assistant read per session rather than one per reconcile.
$script:DaemonPayloadSensorChecked = @{}

# Serialised state of the last successful state-file write, so an idle daemon skips
# rewriting identical JSON every reconcile. Initialised for StrictMode.
$script:DaemonStateLastWritten = $null

# Content signature and timestamp of the last global-status publish, so the three
# global MQTT messages are only re-sent when the live set changes or a re-assert
# interval elapses, instead of on every reconcile. Initialised for StrictMode.
$script:DaemonGlobalSignature = $null
$script:DaemonGlobalLastPublish = [DateTimeOffset]::MinValue
$script:DaemonOnlineLastPublish = [DateTimeOffset]::MinValue

# Short-lived cache of the MCP-client discovery scan (a full /api/states read) and
# a consecutive-failure counter for the WebSocket watch backoff. Initialised for
# StrictMode.
$script:DaemonMcpCache = $null
$script:DaemonMcpCacheAt = [DateTimeOffset]::MinValue
# One /api/states read serves both the MCP scan and the peer-machine scan, so adding
# cross-machine discovery costs no extra HTTP traffic.
$script:DaemonStatesCache = $null
$script:DaemonStatesCacheAt = [DateTimeOffset]::MinValue
$script:DaemonPeerCache = $null
# Sessions whose cards have been removed from the dashboard but whose entities are
# held back a pass, so the frontend has time to stop pointing at them.
$script:DaemonPendingRetire = @()
$script:DaemonWatchFailures = 0

# Update-check state. Initialised here rather than left undefined because the daemon
# runs under StrictMode, where reading an unset variable throws.
$script:DaemonUpdateAvailable = $false
$script:DaemonUpdatePublished = $false
$script:DaemonUpdateLastPress = ''

# New-session control state. The workspace signature is tracked so the discovery
# payload is only re-published when the configured list actually changes, rather
# than on every reconcile. Initialised for StrictMode, as above.
$script:DaemonNewSessionPublished = $false
$script:DaemonNewSessionSignature = ''
$script:DaemonNewSessionLastPress = ''

# Cached resumable-session list. The Agency query behind it returns hundreds of
# sessions and takes over a second, so it is refreshed on a timer rather than on
# every reconcile. Initialised for StrictMode, as above.
$script:DaemonResumeCache = @()
$script:DaemonResumeCacheAt = [DateTimeOffset]::MinValue

# Decisions already reported as terminal-only, so the daemon says it once per
# question instead of on every reconcile. Initialised for StrictMode.
$script:DaemonTerminalOnlyWarned = @{}

# Launcher process per session the bridge started itself, so End can close the
# console it opened. A window the user opened is deliberately never touched - that
# terminal is theirs. Not persisted: after a daemon restart the association is gone
# and the window is simply left alone, which is the safe direction to fail.
$script:DaemonLaunchedPids = @{}

# Anything the dashboard reports as happening before this is a leftover from a
# previous run rather than something the user just did.
$script:DaemonStartedAt = [DateTimeOffset]::Now

function Write-DaemonLog {
    param([Parameter(Mandatory)][string]$Message)

    $line = "$([DateTimeOffset]::Now.ToString('o')) $Message"
    try {
        Add-Content -LiteralPath $script:DaemonConfig.LogFile -Value $line
    }
    catch {
        # Logging must never take the daemon down.
    }
}

function Format-CardText {
    <#
        Truncates card text to a readable preview so a long response or reasoning block
        cannot make one card tower over the others and unbalance the dashboard grid.
        The full text is always available in the terminal.
    #>
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory)][int]$MaxChars
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $trimmed = $Text.Trim()
    if ($trimmed.Length -le $MaxChars) { return $trimmed }
    $trimmed.Substring(0, $MaxChars).TrimEnd() + '…'
}

function Get-LiveCopilotSessions {
    <#
        Live sessions, keyed by session id, resolved from the `inuse.<pid>.lock` files
        that the CLI maintains. A lock whose process is gone is stale and skipped.

        Built to stay cheap even with hundreds of historical session directories on
        disk (this machine has ~480). The live Copilot pids are fetched once up front,
        directory and lock enumeration go through the .NET APIs rather than the
        PowerShell provider, and no per-lock Get-Process call is made. An earlier
        version cost about 1.9 seconds per call and, run every few seconds, pinned a
        third of a CPU core on its own.
    #>
    $root = $script:DecisionBridgeConfig.SessionStateRoot
    if (-not [IO.Directory]::Exists($root)) { return @{} }

    # One process snapshot; membership is then a hash lookup per lock.
    $livePids = @{}
    foreach ($process in @(Get-Process -Name 'copilot' -ErrorAction SilentlyContinue)) {
        $livePids[$process.Id] = $true
    }
    if ($livePids.Count -eq 0) { return @{} }

    $candidates = @()
    foreach ($dir in [IO.Directory]::EnumerateDirectories($root)) {
        $processId = $null
        foreach ($lock in [IO.Directory]::EnumerateFiles($dir, 'inuse.*.lock')) {
            $name = [IO.Path]::GetFileName($lock)
            if ($name -notmatch '^inuse\.(\d+)\.lock$') { continue }
            $candidatePid = [int]$Matches[1]
            if ($livePids.ContainsKey($candidatePid)) { $processId = $candidatePid; break }
        }
        if ($null -eq $processId) { continue }

        $transcript = [IO.Path]::Combine($dir, 'events.jsonl')

        # A session that has not taken its first turn has no transcript yet. It is
        # still a real, live session, so it is included rather than skipped: the card
        # shows it as idle and, more usefully, its reply box can start the
        # conversation from Home Assistant. Streaming begins on its own once the
        # transcript appears.
        $hasTranscript = [IO.File]::Exists($transcript)

        $candidates += [pscustomobject]@{
            SessionId = [IO.Path]::GetFileName($dir)
            ProcessId = $processId
            Transcript = $transcript
            HasTranscript = $hasTranscript
            # A missing file reports a 1601 sentinel, which naturally loses the
            # per-pid tie-break below to any session that has actually written one.
            LastWrite = if ($hasTranscript) { [IO.File]::GetLastWriteTimeUtc($transcript) } else { [DateTime]::MinValue }
            Kind = 'copilot'
        }
    }

    # One CLI process owns exactly one live session. A process that resumed a
    # different session leaves the old `inuse.<pid>.lock` behind, so the same pid can
    # appear under several session directories. Publishing all of them would create
    # phantom sessions in Home Assistant and, worse, deliver a reply meant for one
    # session into whichever session shares the pid. Keep only the most recently
    # written transcript for each pid.
    $live = @{}
    foreach ($group in ($candidates | Group-Object -Property ProcessId)) {
        $winner = $group.Group | Sort-Object LastWrite -Descending | Select-Object -First 1
        $live[$winner.SessionId] = $winner
    }

    $live
}

# ---------------------------------------------------------------- front ends
# Sessions carry a Kind so the daemon can serve more than one CLI. Everything
# Copilot-specific stays on the 'copilot' path unchanged; 'claude' sessions are
# discovered, streamed and answered through the helpers below. The Claude adapter is
# optional - when it is not installed, these degrade to returning nothing.

$script:ClaudeAdapterLoaded = $false
$claudeHooks = Join-Path $HOME '.claude\ha-bridge'
if (Test-Path -LiteralPath (Join-Path $claudeHooks 'claude-session.ps1')) {
    try {
        . (Join-Path $claudeHooks 'claude-session.ps1')
        . (Join-Path $claudeHooks 'claude-transcript.ps1')
        $script:ClaudeAdapterLoaded = $true
    }
    catch {
        $script:ClaudeAdapterLoaded = $false
    }
}

$script:CodexAdapterLoaded = $false
$codexHooks = Join-Path $HOME '.agent-ha-bridge\codex-bridge\plugins\agent-ha-bridge\hooks'
if (Test-Path -LiteralPath (Join-Path $codexHooks 'codex-session.ps1')) {
    try {
        . (Join-Path $codexHooks 'codex-session.ps1')
        . (Join-Path $codexHooks 'codex-transcript.ps1')
        $script:CodexAdapterLoaded = $true
    }
    catch {
        $script:CodexAdapterLoaded = $false
    }
}

function Get-LiveCodexSessions {
    <#
        Live Codex sessions, from the registrations its hooks write.

        Codex needs no transcript tailing: its hooks report every prompt, tool call
        and reply directly, and the hook records the resulting status and activity in
        the registration. The daemon therefore publishes what the registration already
        says rather than deriving it.

        Liveness is authoritative here in a way it is not for the others, because
        Codex fires an explicit SessionEnd.
    #>
    if (-not $script:CodexAdapterLoaded) { return @{} }

    $live = @{}
    foreach ($registration in @(Get-CodexSessionRegistrations)) {
        if (-not $registration.IsLive) { continue }
        $live[$registration.SessionId] = [pscustomobject]@{
            SessionId        = $registration.SessionId
            ProcessId        = $registration.ProcessId
            Transcript       = $registration.TranscriptPath
            WorkingDirectory = $registration.WorkingDirectory
            Status           = $registration.Status
            Activity         = $registration.Activity
            LastWrite        = [DateTime]::UtcNow
            Kind             = 'codex'
        }
    }
    $live
}

function Get-DaemonHomeAssistantStates {
    <#
        Every Home Assistant state, cached for a short while.

        Two scans need the full state list - MCP clients and peer machines - and both
        change slowly, so they share one read rather than each paying for an O(all
        entities) fetch on every reconcile. Failure throws; each caller decides whether
        to fall back to its own last known good set.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    if ($null -ne $script:DaemonStatesCache -and
        ([DateTimeOffset]::Now - $script:DaemonStatesCacheAt).TotalSeconds -lt $script:DaemonConfig.McpScanCacheSeconds) {
        return ,$script:DaemonStatesCache
    }

    $states = Invoke-DecisionHttpRequest -Parameters @{
        Method = 'Get'
        Uri = "$($script:DecisionBridgeConfig.HomeAssistantBaseUrl)/api/states"
        Headers = $Headers
        TimeoutSec = 15
    }
    $script:DaemonStatesCache = @($states)
    $script:DaemonStatesCacheAt = [DateTimeOffset]::Now
    # Comma-wrapped: an empty array returned bare unrolls to nothing, and the caller's
    # @($result) then yields a one-element array holding $null, which every consumer
    # here would dereference.
    ,$script:DaemonStatesCache
}

function Get-DaemonPeerMachines {
    <#
        The other machines running the bridge against this Home Assistant, with
        whatever each is currently running.

        This is what makes one dashboard able to show every machine. Discovery is
        one-directional and needs no agreement between machines: each publishes a
        retained sensor describing itself, and everyone else simply reads it.

        A failed scan falls back to the last known set rather than to none, so a
        transient Home Assistant error does not make every other machine's sessions
        blink out of the dashboard and back in.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    try { $states = Get-DaemonHomeAssistantStates -Headers $Headers }
    catch {
        if ($null -ne $script:DaemonPeerCache) { return $script:DaemonPeerCache }
        return @()
    }

    $peers = @(Get-BridgePeerMachine -States $states -ExcludeSelf)
    $script:DaemonPeerCache = $peers
    $peers
}

function Get-LiveMcpSessions {
    <#
        Live MCP clients, discovered from their Home Assistant entities.

        The MCP server is a separate process on any operating system, so there is no
        registration file or process to inspect. Its entities are the only evidence it
        exists - and they are sufficient, because it publishes them on connect and
        withdraws them on disconnect, so presence is liveness.

        These sessions are deliberately thin. An MCP server never sees a transcript
        and cannot originate a turn, so it publishes a decision, a reply and a status
        and nothing else; the dashboard renders them with a reduced card for that
        reason.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    # Serve the cached scan while it is fresh. MCP presence changes slowly and only
    # affects the global count and dashboard card - the MCP server publishes and
    # withdraws its own decision entities - so a short TTL avoids a full O(all HA
    # entities) /api/states read on every reconcile.
    #
    # That TTL now lives on the shared state snapshot, which the peer-machine scan
    # reads too, so both get one HTTP round trip between them. Re-parsing the snapshot
    # each call is cheap and keeps the two from drifting: a private freshness gate here
    # as well could expire while the snapshot behind it was still warm, so the "fresh"
    # scan would have re-read nothing.
    $live = @{}
    try {
        $states = Get-DaemonHomeAssistantStates -Headers $Headers
    }
    catch {
        # Show the last known set on a transient scan failure rather than flapping the
        # count to zero; a still-expired cache is retried on the next reconcile.
        if ($null -ne $script:DaemonMcpCache) { return $script:DaemonMcpCache }
        return $live
    }

    foreach ($state in @($states)) {
        if ($null -eq $state) { continue }
        $entityId = [string]$state.entity_id
        if ($entityId -notmatch '^select\.(mcp_[a-z0-9]+)_decision$') { continue }
        $node = $Matches[1]

        $name = [string]$state.attributes.friendly_name
        if ([string]::IsNullOrWhiteSpace($name)) { $name = 'MCP client' }
        # The friendly name is "<device> Decision"; the device is the useful part.
        $name = ($name -replace '\s+Decision$', '')
        if (Get-Command Remove-CopilotTemplateMarkup -ErrorAction SilentlyContinue) {
            $name = Remove-CopilotTemplateMarkup -Text $name
        }

        # The node doubles as the id: these sessions are addressed only by entity.
        $live[$node] = [pscustomobject]@{
            SessionId  = $node
            ProcessId  = 0
            Transcript = ''
            Node       = $node
            Name       = $name
            LastWrite  = [DateTime]::UtcNow
            Kind       = 'mcp'
        }
    }
    $script:DaemonMcpCache = $live
    $script:DaemonMcpCacheAt = [DateTimeOffset]::Now
    $live
}

function Get-LiveBridgeSessions {
    <# Every live session across the front ends the bridge supports. #>
    $live = Get-LiveCopilotSessions
    foreach ($entry in (Get-LiveClaudeSessions).GetEnumerator()) {
        $live[$entry.Key] = $entry.Value
    }
    foreach ($entry in (Get-LiveCodexSessions).GetEnumerator()) {
        $live[$entry.Key] = $entry.Value
    }
    $live
}

function Get-LiveClaudeSessions {
    <#
        Live Claude Code sessions, from the registrations its hooks write.

        Claude has no inuse.<pid>.lock, so liveness is the recorded pid still being a
        running claude process - established in Get-ClaudeSessionRegistrations.
    #>
    if (-not $script:ClaudeAdapterLoaded) { return @{} }

    $live = @{}
    foreach ($registration in @(Get-ClaudeSessionRegistrations)) {
        if (-not $registration.IsLive) { continue }
        # Claude creates the transcript only when the first message is sent, so a
        # session just started - from the dashboard, typically - has none yet. It is
        # live all the same, and requiring the file hid it until someone typed in it.
        # Everything that reads the transcript treats a missing file as no activity.
        $transcript = [string]$registration.TranscriptPath
        if ([string]::IsNullOrWhiteSpace($transcript)) { continue }

        $live[$registration.SessionId] = [pscustomobject]@{
            SessionId        = $registration.SessionId
            ProcessId        = $registration.ProcessId
            Transcript       = $transcript
            WorkingDirectory = $registration.WorkingDirectory
            LastWrite        = [IO.File]::GetLastWriteTimeUtc($transcript)
            Kind             = 'claude'
            # The status the last hook set, and when (see Sync-DaemonHookStatus).
            HookStatus       = [string]$registration.HookStatus
            HookStatusAt     = [string]$registration.HookStatusAt
        }
    }
    $live
}

function Get-BridgeSessionDisplay {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$Kind = 'copilot',
        [string]$WorkingDirectory = 'Unknown folder'
    )

    if ($Kind -eq 'claude' -and $script:ClaudeAdapterLoaded) {
        return Get-ClaudeSessionDisplay -SessionId $SessionId -WorkingDirectory $WorkingDirectory
    }
    if ($Kind -eq 'codex' -and $script:CodexAdapterLoaded) {
        return Get-CodexSessionDisplay -SessionId $SessionId -WorkingDirectory $WorkingDirectory
    }
    Get-CopilotSessionDisplay -SessionId $SessionId -WorkingDirectory $WorkingDirectory
}

function Read-BridgeTranscriptAppend {
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$Offset = 0,
        [string]$Kind = 'copilot'
    )

    if ($Kind -eq 'claude' -and $script:ClaudeAdapterLoaded) {
        return Read-ClaudeTranscriptAppend -Path $Path -Offset $Offset `
            -MaxTailBytes $script:DaemonConfig.MaxTailBytes
    }
    Read-TranscriptAppend -Path $Path -Offset $Offset
}

function Get-BridgeActivity {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][bool]$VerboseMode,
        [string]$Kind = 'copilot'
    )

    if ($Kind -eq 'claude' -and $script:ClaudeAdapterLoaded) {
        return Get-ClaudeActivityFromTranscript -Lines $Lines -VerboseMode $VerboseMode
    }
    Get-ActivityFromEvents -Lines $Lines -VerboseMode $VerboseMode
}

function Test-BridgeSessionWorking {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$Kind = 'copilot',
        [string]$Transcript,
        [string]$Status
    )

    # Codex reports its own status: a turn begins at UserPromptSubmit and ends at
    # Stop, both of which the hook records, so there is nothing to infer.
    if ($Kind -eq 'codex') { return ($Status -eq 'working') }

    if ($Kind -ne 'claude') { return Test-CopilotSessionWorking -SessionId $SessionId }
    if (-not $script:ClaudeAdapterLoaded -or -not $Transcript) { return $false }
    # Claude writes no turn-end entry, so freshness is the best available signal at
    # adoption time; the Stop hook corrects it authoritatively at the next turn end.
    try {
        return ([DateTime]::UtcNow - [IO.File]::GetLastWriteTimeUtc($Transcript)).TotalSeconds -lt 20
    }
    catch { return $false }
}

function Sync-DaemonHookStatus {
    <#
        Adopts the status a Claude hook last set, once per hook event.

        Hooks publish 'idle' and 'waiting' to Home Assistant themselves; recording
        them here is what lets the transcript loop see the session resume and send
        'working' again. 'working' comes from UserPromptSubmit, which does not talk to
        Home Assistant, so it is published from here.

        Returns when that hook fired, or $null when no hook status is recorded, so the
        caller can ignore transcript lines older than it.
    #>
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    if (-not $Session.PSObject.Properties['HookStatus'] -or [string]::IsNullOrWhiteSpace([string]$Session.HookStatus)) { return $null }
    $at = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Session.HookStatusAt, [ref]$at)) { return $null }

    $seen = if ($Entry.PSObject.Properties['HookStatusAt']) { [string]$Entry.HookStatusAt } else { '' }
    if ($seen -eq [string]$Session.HookStatusAt) { return $at }

    $status = [string]$Session.HookStatus
    if ($status -eq 'working' -and $status -ne [string]$Entry.Status) {
        try {
            Set-CopilotMqttStatus -SessionId $SessionId -Status 'working' -Headers $Headers -Attributes @{
                session    = $Entry.Name
                machine    = $Entry.Machine
                process_id = $Session.ProcessId
                updated    = [DateTimeOffset]::Now.ToString('o')
            }
        }
        catch {
            # Left unmarked, so the next reconcile tries again.
            Write-DaemonLog -Message "status publish failed for $SessionId : $($_.Exception.Message)"
            return $at
        }
    }

    $Entry.Status = $status
    if ($Entry.PSObject.Properties['HookStatusAt']) { $Entry.HookStatusAt = [string]$Session.HookStatusAt }
    else { $Entry | Add-Member -NotePropertyName HookStatusAt -NotePropertyValue ([string]$Session.HookStatusAt) -Force }
    $at
}

function Get-DaemonStartupStatus {
    <#
        The status to restore a session with when the daemon starts.

        This used Copilot's lock-file check for every session, which always answers
        'idle' for Claude, so each restart - including every update - turned a busy
        Claude card idle until its transcript or a hook next said otherwise. A long
        tool call writes nothing to the transcript, so that could take minutes.

        A Claude hook's recorded status is authoritative when there is one; anything
        else goes through the kind-aware check.
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Entry
    )

    $kind = if ($Entry.PSObject.Properties.Name -contains 'Kind' -and $Entry.Kind) { [string]$Entry.Kind } else { 'copilot' }

    if ($kind -eq 'claude' -and $Session.PSObject.Properties['HookStatus'] -and
        [string]$Session.HookStatus -in @('working', 'waiting', 'idle')) {
        return [string]$Session.HookStatus
    }

    $sessionStatus = if ($Session.PSObject.Properties.Name -contains 'Status') { [string]$Session.Status } else { '' }
    $transcript = if ($Session.PSObject.Properties.Name -contains 'Transcript') { [string]$Session.Transcript } else { '' }
    if (Test-BridgeSessionWorking -SessionId ([string]$Session.SessionId) -Kind $kind -Transcript $transcript -Status $sessionStatus) {
        return 'working'
    }
    'idle'
}

function Read-DaemonStateFile {
    <#
        Parses one state file into a hashtable. Returns @{} for an empty file (a
        legitimately empty state) and $null when the file cannot be read or parsed,
        so the caller can distinguish "no sessions" from "corrupt" and fall back to
        the last-good backup rather than discarding every persisted card.
    #>
    param([Parameter(Mandatory)][string]$Path)

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $parsed = $raw | ConvertFrom-Json
        $state = @{}
        foreach ($property in $parsed.PSObject.Properties) {
            $state[$property.Name] = $property.Value
        }
        return $state
    }
    catch {
        return $null
    }
}

function Read-DaemonState {
    $stateFile = $script:DaemonConfig.StateFile
    if (-not (Test-Path -LiteralPath $stateFile)) {
        return @{}
    }

    $state = Read-DaemonStateFile -Path $stateFile
    if ($null -ne $state) { return $state }

    # The primary file exists but is unreadable or malformed - most likely a write
    # was interrupted by a crash or power loss. Recover the last-good backup instead
    # of silently starting empty, which would blank every session's restored card.
    $backup = "$stateFile.bak"
    if (Test-Path -LiteralPath $backup) {
        Write-DaemonLog -Message "state file is corrupt; restoring from backup '$backup'"
        $state = Read-DaemonStateFile -Path $backup
        if ($null -ne $state) { return $state }
    }
    Write-DaemonLog -Message "state file '$stateFile' is corrupt and no usable backup exists; starting from empty state"
    return @{}
}

function Write-DaemonState {
    param([Parameter(Mandatory)][hashtable]$State)

    try {
        $json = $State | ConvertTo-Json -Depth 8 -Compress
    }
    catch {
        Write-DaemonLog -Message "state serialize failed: $($_.Exception.Message)"
        return
    }

    # Skip the write when nothing changed, so an idle daemon is not serialising and
    # rewriting the same JSON to disk on every reconcile (flash wear and idle I/O).
    if ($json -eq $script:DaemonStateLastWritten) { return }

    $stateFile = $script:DaemonConfig.StateFile
    $temp = "$stateFile.tmp"
    try {
        # Deliberately .NET file APIs rather than Set-Content/Copy-Item.
        #
        # Reply injection calls FreeConsole/AttachConsole, and after that cycle the
        # daemon no longer has a usable console. Any cmdlet that emits a progress
        # record then throws from the host itself - "The handle is invalid. 0x6 ...
        # while getting console output buffer information" - and because that is a
        # host exception, not an error record, -ErrorAction SilentlyContinue does not
        # suppress it. Copy-Item reports progress, so from the first injection onward
        # every single save failed and the state file silently stopped advancing.
        # The .NET equivalents have no progress stream and no host dependency.
        [System.IO.File]::WriteAllText($temp, $json, [System.Text.UTF8Encoding]::new($false))
        # Preserve the current good file as a backup, then atomically replace the
        # target by rename. A crash can therefore only ever leave a stale-but-valid
        # target plus a partial .tmp, never a truncated target with no fallback.
        if ([System.IO.File]::Exists($stateFile)) {
            try { [System.IO.File]::Copy($stateFile, "$stateFile.bak", $true) } catch { }
        }
        [System.IO.File]::Move($temp, $stateFile, $true)
        $script:DaemonStateLastWritten = $json
    }
    catch {
        Write-DaemonLog -Message "state save failed: $($_.Exception.Message)"
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Test-VerboseStreaming {
    param([Parameter(Mandatory)][hashtable]$Headers)

    try {
        $state = Get-HomeAssistantState -EntityId $script:DaemonConfig.VerboseToggle -Headers $Headers
        return ([string]$state.state -eq 'on')
    }
    catch {
        # Default to quiet if the toggle cannot be read, rather than flooding.
        return $false
    }
}

function Read-TranscriptAppend {
    <#
        Returns transcript lines appended since $Offset, plus the new offset.

        Shared read/write access is required because the CLI keeps the transcript
        open while it writes.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$Offset
    )

    $result = [pscustomobject]@{ Lines = @(); Offset = $Offset }

    $stream = $null
    try {
        $stream = [IO.File]::Open(
            $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite
        )
        $length = $stream.Length

        # A shorter file means the session was reset; start over from the end.
        if ($length -lt $Offset) {
            $result.Offset = $length
            return $result
        }
        if ($length -eq $Offset) { return $result }

        $start = $Offset
        if (($length - $start) -gt $script:DaemonConfig.MaxTailBytes) {
            $start = $length - $script:DaemonConfig.MaxTailBytes
        }

        [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false))
        $text = $reader.ReadToEnd()

        $result.Offset = $length
        $result.Lines = @(
            ($text -split "`n") | Where-Object { $_.Trim().StartsWith('{') }
        )
    }
    catch {
        return $result
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }

    $result
}

function Get-ActivityFromEvents {
    <#
        Reduces a batch of transcript events to the current activity.

        Returns the last meaningful event plus a short rolling history, so the Home
        Assistant card shows what the session is doing now and what it just did.
        Reasoning text is only collected when verbose streaming is on.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory)][bool]$VerboseMode
    )

    $summary = $null
    $reasoning = $null
    $response = $null
    $status = $null
    $history = New-Object System.Collections.Generic.List[string]

    foreach ($line in $Lines) {
        if ($line -notmatch '"type":"([^"]+)"') { continue }
        $type = $Matches[1]

        switch ($type) {
            'assistant.turn_start' { $status = 'working'; continue }
            'user.message' { $status = 'working'; $summary = 'Reading your message'; $history.Add($summary); continue }
            'assistant.turn_end' { $status = 'idle'; continue }
        }

        if ($type -eq 'tool.execution_start') {
            try {
                $parsed = $line | ConvertFrom-Json
                $tool = [string]$parsed.data.toolName
                if (-not [string]::IsNullOrWhiteSpace($tool)) {
                    $summary = "Running: $tool"
                    $history.Add($summary)
                }
            }
            catch { }
            continue
        }

        if ($type -eq 'assistant.message') {
            try {
                $parsed = $line | ConvertFrom-Json
                $content = [string]$parsed.data.content
                if (-not [string]::IsNullOrWhiteSpace($content)) {
                    # The short summary is the first line, for the sensor state (capped
                    # at 255 chars); the full content is kept separately so the card can
                    # render the whole response, not just its opening line.
                    $first = (($content -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
                    if ($first) {
                        $summary = $first.Trim()
                        $history.Add($summary)
                    }
                    $response = $content.Trim()
                }
                # Reasoning is captured unconditionally, regardless of the verbose
                # toggle. Capture and display are deliberately decoupled: the daemon
                # always keeps the latest reasoning in state, and only publishes it to
                # the card when verbose is on. That lets a verbose toggle show or hide
                # the existing reasoning instantly, without waiting for the session to
                # think again.
                $text = [string]$parsed.data.reasoningText
                if (-not [string]::IsNullOrWhiteSpace($text)) { $reasoning = $text.Trim() }
            }
            catch { }
            continue
        }
    }

    [pscustomobject]@{
        Summary = $summary
        Reasoning = $reasoning
        Response = $response
        Status = $status
        History = @($history)
    }
}

function Set-DaemonTransientActivity {
    <#
        Reports something the user just did, without losing what the card was showing.

        Set-CopilotMqttActivity replaces the attribute set, and the header renders the
        last response, the reasoning and the activity history out of those attributes.
        Publishing a bare "Sending..." therefore blanked the response and the
        chain-of-thought until the next transcript update happened to restore them -
        visible as the card emptying and then refilling on every Send.

        Reading the current attributes and merging keeps the card intact while the
        status line underneath reports progress.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Summary,
        [hashtable]$Extra = @{},
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $attributes = @{}
    try {
        $node = Get-CopilotMqttNodeId -SessionId $SessionId
        $current = Get-HomeAssistantState -EntityId "sensor.${node}_activity" -Headers $Headers
        foreach ($property in $current.attributes.PSObject.Properties) {
            # Home Assistant adds these itself; echoing them back is noise.
            if ($property.Name -in @('friendly_name', 'icon', 'device_class', 'unit_of_measurement')) { continue }
            $attributes[$property.Name] = $property.Value
        }
    }
    catch {
        # No current attributes to preserve; publish just the new ones.
    }

    # Status detail from a previous action would otherwise linger beside a new one and
    # describe the wrong thing.
    foreach ($key in @('error', 'hint', 'waiting_on', 'sent', 'unsent', 'recorded', 'answer', 'at')) {
        [void]$attributes.Remove($key)
    }
    foreach ($key in $Extra.Keys) { $attributes[$key] = $Extra[$key] }

    Set-CopilotMqttActivity -SessionId $SessionId -Summary $Summary -Detail $attributes -Headers $Headers
}

function Get-BridgeAttachmentRoot {
    <#
        Where images from the reply card are written before being attached.

        The path must not contain a space. The CLI attaches a file when the prompt
        references it as `@<path>`, and there is no way to quote a path in that
        syntax, so a space would split one attachment into two broken words.
        LOCALAPPDATA normally qualifies, but it sits under the user profile, so a
        user name containing a space would make every attachment unusable - hence
        the fallback to the public profile, which never contains one.
    #>
    $root = ''
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $root = Join-Path ([string]$env:LOCALAPPDATA) 'agent-ha-bridge\attachments'
    }
    if ([string]::IsNullOrWhiteSpace($root) -or $root -match '\s') {
        $root = Join-Path ([string]$env:PUBLIC) 'agent-ha-bridge\attachments'
    }
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    $root
}

function Get-BridgeReplyPayload {
    <#
        Reads one submission from the reply card's payload sensor.

        Returns $null when there is nothing usable to send.

        The stamp is the card's own timestamp, carried in the sensor state via
        value_template. Comparing it against the last one handled is what makes a
        duplicate delivery impossible - the same contract the Submit button's press
        stamp already uses. The text itself is read from the attributes rather than
        the state because Home Assistant caps a state at 255 characters and does not
        cap attributes, which is the whole reason this entity exists.
    #>
    param([object]$State)

    if ($null -eq $State) { return $null }

    $stamp = ''
    if ($State.PSObject.Properties['state']) { $stamp = [string]$State.state }
    if ([string]::IsNullOrWhiteSpace($stamp) -or $stamp -in @('unknown', 'unavailable')) { return $null }

    $attrs = $null
    if ($State.PSObject.Properties['attributes']) { $attrs = $State.attributes }
    if ($null -eq $attrs) { return $null }

    $text = ''
    if ($attrs.PSObject.Properties['text']) { $text = [string]$attrs.text }

    $images = [System.Collections.Generic.List[object]]::new()
    if ($attrs.PSObject.Properties['images'] -and $null -ne $attrs.images) {
        foreach ($image in @($attrs.images)) {
            if ($null -eq $image) { continue }
            $id = ''
            if ($image.PSObject.Properties['id']) { $id = [string]$image.id }
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            $name = ''
            if ($image.PSObject.Properties['name']) { $name = [string]$image.name }
            $images.Add([pscustomobject]@{ Id = $id; Name = $name })
        }
    }

    # An empty submission is not an error, it is just nothing to do.
    if ([string]::IsNullOrWhiteSpace($text) -and $images.Count -eq 0) { return $null }

    [pscustomobject]@{
        Stamp  = $stamp
        Text   = $text
        Images = $images.ToArray()
    }
}

function New-BridgeAttachmentPrompt {
    <#
        Builds the text that is typed into the CLI for a reply carrying attachments.

        Copilot CLI attaches a file when the prompt references it as `@<path>`, so
        the attachments lead and the typed text follows. A path containing a space
        cannot be expressed that way and is dropped rather than silently corrupting
        the rest of the prompt; Get-BridgeAttachmentRoot exists to make that
        impossible in the first place.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string[]]$Paths = @()
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if ($path -match '\s') { continue }
        $parts.Add("@$path")
    }

    $clean = ([string]$Text).Trim()
    if (-not [string]::IsNullOrWhiteSpace($clean)) { $parts.Add($clean) }

    $parts -join ' '
}

function Save-BridgeReplyAttachment {
    <#
        Downloads one image the reply card uploaded to Home Assistant.

        Returns the local path, or '' if it could not be fetched. The extension is
        taken from the original file name because the CLI decides how to treat an
        attachment from its extension, and falls back to .png - the format anything
        pasted from a clipboard arrives as.
    #>
    param(
        [Parameter(Mandatory)][string]$ImageId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $extension = ''
    try { $extension = [System.IO.Path]::GetExtension($Name) } catch { $extension = '' }
    if ($extension -notin @('.png', '.jpg', '.jpeg', '.gif', '.webp', '.heic', '.heif', '.pdf')) {
        $extension = '.png'
    }

    $safeId = $ImageId -replace '[^0-9a-zA-Z]', ''
    if ([string]::IsNullOrWhiteSpace($safeId)) { return '' }

    $path = Join-Path (Get-BridgeAttachmentRoot) "$safeId$extension"
    $uri = "$($script:DecisionBridgeConfig.HomeAssistantBaseUrl)/api/image/serve/$ImageId/original"

    try {
        Invoke-WebRequest -Uri $uri -Headers $Headers -OutFile $path -UseBasicParsing -ErrorAction Stop | Out-Null
    }
    catch {
        Write-DaemonLog -Message "could not fetch attachment $ImageId : $($_.Exception.Message)"
        return ''
    }

    if (-not (Test-Path -LiteralPath $path)) { return '' }
    $path
}

function Remove-BridgeHomeAssistantImage {
    <#
        Deletes an uploaded image from Home Assistant once it is safely on disk here.

        Best effort: a failure leaves a file in Home Assistant's upload store, which
        is untidy but harmless, and must never stop a reply being delivered.
    #>
    param([Parameter(Mandatory)][string]$ImageId)

    try {
        [void](Invoke-CopilotHaWebSocket -Commands @(@{ type = 'image/delete'; image_id = $ImageId }))
    }
    catch {
        Write-DaemonLog -Message "could not remove uploaded image $ImageId from Home Assistant: $($_.Exception.Message)"
    }
}

function Remove-BridgeStaleAttachment {
    <#
        Clears attachments left behind by previous replies.

        They are only needed until the CLI has read them, which happens within
        seconds of delivery, but deleting immediately would race that read. A day is
        far longer than the CLI needs and keeps the folder from growing without end.
    #>
    param([int]$MaxAgeHours = 24)

    try {
        $cutoff = (Get-Date).AddHours(-$MaxAgeHours)
        $root = Get-BridgeAttachmentRoot
        foreach ($file in @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue)) {
            if ($file.LastWriteTime -lt $cutoff) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch { }
}

function Invoke-PendingReplies {
    <#
        Delivers any reply box that currently holds text.

        The WebSocket watch only sees a reply if the state change fires during its
        active window, so a reply that lands in the gap between windows would be lost.
        Reading the retained value on every reconcile closes that race: the box keeps
        its value until the daemon clears it, so it is always seen within one
        reconcile interval regardless of timing. The push path stays as a latency
        optimization on top of this.

        A per-session hash guards the brief window between delivering a reply and the
        clear taking effect, so the same text is never injected twice.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Live
    )

    foreach ($sessionId in @($State.Keys)) {
        if (-not $Live.ContainsKey($sessionId)) { continue }

        $session = $Live[$sessionId]
        $node = Get-CopilotMqttNodeId -SessionId $sessionId
        $replyEntity = "text.${node}_reply"
        $marker = Get-CopilotDecisionMarker -SessionId $sessionId

        # Read the decision card once and decide who owns the reply box.
        $armedQuestion = ''
        try {
            $decisionState = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
            $armedQuestion = [string]$decisionState.attributes.question
        }
        catch {
            # Unreadable decision state: treat the reply as a continuation, the common case.
        }

        if (-not [string]::IsNullOrWhiteSpace($armedQuestion)) {
            if ($null -ne $marker) {
                # A live question owns the reply box - Invoke-PendingDecisions reads it
                # as the free-text field of the form, and reports there if the form is
                # incomplete. Nothing to do here.
                continue
            }

            # Armed card with no marker behind it. Either the old blocking router is
            # genuinely waiting on it, or the question was already answered and the
            # card was never torn down - in which case every reply typed here is
            # dropped silently, which is how a session ends up unable to be replied to
            # at all. The transcript settles it.
            $stale = $false
            try {
                $askState = Get-DaemonAskUserState -Session $session
                $stale = (-not $askState.Pending)
            }
            catch { }

            if (-not $stale) { continue }

            try {
                Clear-CopilotMqttDecision -SessionId $sessionId `
                    -SessionName ([string]$State[$sessionId].Name) `
                    -Machine ([string]$State[$sessionId].Machine) -Headers $Headers
                Write-DaemonLog -Message "cleared a stale decision card for $($sessionId.Substring(0,8)) so replies work again"
            }
            catch {
                Write-DaemonLog -Message "could not clear the stale decision card for $sessionId : $($_.Exception.Message)"
                continue
            }
        }

        $entry = $State[$sessionId]

        # The reply card delivers here, and takes precedence over the text box below.
        #
        # It sends what is on screen at the instant Send is pressed rather than
        # whatever Home Assistant last managed to commit, so it needs no arming and
        # no waiting, and it can carry images and text of any length.
        $payload = $null
        try {
            $payloadState = Get-HomeAssistantState -EntityId "sensor.${node}_reply_payload" -Headers $Headers
            $payload = Get-BridgeReplyPayload -State $payloadState
        }
        catch {
            # No payload sensor yet (a session published before this existed), or it
            # is unreadable. The text box below still works.
        }

        if ($null -ne $payload) {
            $lastPayload = if ($entry.PSObject.Properties['LastReplyPayloadAt']) { [string]$entry.LastReplyPayloadAt } else { '' }
            if ($payload.Stamp -ne $lastPayload) {
                # Record the stamp before delivering, not after. Delivery types the
                # reply into the console one character at a time, which is long enough
                # for the next reconcile to see the same payload still sitting there
                # and send it a second time.
                Set-DaemonSessionProperty -Entry $entry -Name 'LastReplyPayloadAt' -Value $payload.Stamp

                try {
                    Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Sending...' -Headers $Headers
                }
                catch { }

                $paths = [System.Collections.Generic.List[string]]::new()
                $fetched = [System.Collections.Generic.List[string]]::new()
                foreach ($image in @($payload.Images)) {
                    $saved = Save-BridgeReplyAttachment -ImageId $image.Id -Name $image.Name -Headers $Headers
                    if (-not [string]::IsNullOrWhiteSpace($saved)) {
                        $paths.Add($saved)
                        $fetched.Add($image.Id)
                    }
                }

                $prompt = New-BridgeAttachmentPrompt -Text $payload.Text -Paths $paths.ToArray()
                if ([string]::IsNullOrWhiteSpace($prompt)) {
                    Write-DaemonLog -Message "reply card payload for $($sessionId.Substring(0,8)) had nothing deliverable"
                    continue
                }

                $attachmentNote = if ($paths.Count -gt 0) { " with $($paths.Count) attachment(s)" } else { '' }
                Write-DaemonLog -Message "reply card payload for $($sessionId.Substring(0,8))$attachmentNote"

                Set-DaemonSessionProperty -Entry $entry -Name 'LastReply' -Value $payload.Text
                [void](Invoke-DaemonReply -SessionId $sessionId -Text $prompt -Headers $Headers `
                    -DisplayText $payload.Text -ClearReplyBox:$false)

                # Only once it is delivered, so a failed send leaves the image in place
                # to be retried by hand.
                foreach ($id in $fetched) { Remove-BridgeHomeAssistantImage -ImageId $id }
                Remove-BridgeStaleAttachment
                continue
            }
        }

        # Read the press first. The old order read the reply box first and bailed on a
        # blank one, which lost the race Home Assistant creates: a text entity commits
        # when it loses focus, and on a phone the tap that commits it *is* the tap on
        # Send. The first read could therefore still see the old, blank value, nothing
        # was sent, and nothing said so - which is why a reply sometimes needed Send
        # pressed twice.
        $press = ''
        try {
            $btn = Get-HomeAssistantState -EntityId "button.${node}_submit" -Headers $Headers
            $press = [string]$btn.state
        }
        catch {
            continue
        }
        if ($press -in @('unknown', 'unavailable', '')) { continue }

        $lastSubmit = if ($entry.PSObject.Properties['LastSubmitAt']) { [string]$entry.LastSubmitAt } else { '' }
        if ($press -eq $lastSubmit) { continue }

        try {
            $replyState = Get-HomeAssistantState -EntityId $replyEntity -Headers $Headers
        }
        catch {
            continue
        }
        $value = [string]$replyState.state

        # Give the commit time to land before concluding there is nothing to send.
        #
        # Home Assistant commits a text entity when it loses focus, and the tap that
        # commits it IS the tap on Send. The daemon is woken by the button's own state
        # change, so it reads the box within milliseconds of the press - reliably
        # before the typed value has landed. A single short re-read was not enough:
        # the first Send of a message regularly reported "Nothing to send" and it took
        # a second press to get through.
        #
        # Polling briefly costs nothing when the value is already there, which is the
        # common case on the reconcile sweep.
        $attempts = 0
        while (($attempts -lt $script:DaemonConfig.ReplyCommitAttempts) -and
               ([string]::IsNullOrWhiteSpace($value) -or $value -in @('unknown', 'unavailable'))) {
            $attempts++
            Start-Sleep -Milliseconds $script:DaemonConfig.ReplyCommitWaitMs
            try {
                $replyState = Get-HomeAssistantState -EntityId $replyEntity -Headers $Headers
                $value = [string]$replyState.state
            }
            catch { }
        }

        # Acknowledge the press immediately - a press that produces no visible change
        # for even a second reads as a dead button, which is the other half of why it
        # got pressed twice. Which acknowledgement depends on whether the typed text
        # has actually reached Home Assistant yet, so it happens in each branch below
        # rather than unconditionally here: a blanket 'Sending...' on every pass would
        # overwrite the armed message it is meant to sit alongside.
        if ([string]::IsNullOrWhiteSpace($value) -or $value -in @('unknown', 'unavailable')) {
            # The text is almost certainly on screen - it just is not in Home Assistant
            # yet. A text entity only commits when it loses focus or you press Enter,
            # and pressing Send does neither: Home Assistant's own history showed three
            # presses landing before the box was committed even once. Burning the press
            # here is what forced a second one, so it stays armed instead and fires the
            # moment the value arrives.
            $pendingAt = if ($entry.PSObject.Properties['PendingSubmitAt']) { [string]$entry.PendingSubmitAt } else { '' }
            if ($pendingAt -ne $press) {
                Set-DaemonSessionProperty -Entry $entry -Name 'PendingSubmitAt' -Value $press
                Set-DaemonSessionProperty -Entry $entry -Name 'PendingSubmitSince' -Value ([DateTimeOffset]::Now.ToString('o'))
                try {
                    Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Waiting for your text' `
                        -Extra @{ hint = 'Press Enter in the box, or tap outside it, and this sends on its own.' } `
                        -Headers $Headers
                }
                catch { }
                Write-DaemonLog -Message "send armed for $($sessionId.Substring(0,8)); the typed text has not reached Home Assistant yet"
                continue
            }

            $since = [DateTimeOffset]::MinValue
            if ($entry.PSObject.Properties['PendingSubmitSince']) {
                try { $since = [DateTimeOffset]::Parse([string]$entry.PendingSubmitSince) } catch { }
            }
            if (([DateTimeOffset]::Now - $since).TotalSeconds -lt $script:DaemonConfig.SubmitArmSeconds) {
                # Still armed; say nothing further and look again next pass.
                continue
            }

            # Long enough that the box really was empty. Say so rather than doing
            # nothing: silence here is indistinguishable from a broken button.
            Set-DaemonSessionProperty -Entry $entry -Name 'LastSubmitAt' -Value $press
            Set-DaemonSessionProperty -Entry $entry -Name 'PendingSubmitAt' -Value ''
            try {
                Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Nothing to send' `
                    -Extra @{ hint = 'Type a reply first, then press Send.' } -Headers $Headers
            }
            catch { }
            Write-DaemonLog -Message "send for $($sessionId.Substring(0,8)) gave up waiting for the typed text"
            continue
        }

        Set-DaemonSessionProperty -Entry $entry -Name 'LastSubmitAt' -Value $press
        Set-DaemonSessionProperty -Entry $entry -Name 'PendingSubmitAt' -Value ''
        Set-DaemonSessionProperty -Entry $entry -Name 'LastReply' -Value $value

        try {
            Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Sending...' -Headers $Headers
        }
        catch { }

        [void](Invoke-DaemonReply -SessionId $sessionId -Text $value -Headers $Headers)
    }
}

function Set-DaemonSessionProperty {
    <# Adds or updates a note property on a persisted session entry. #>
    param(
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][AllowNull()][object]$Value
    )
    if ($Entry.PSObject.Properties[$Name]) { $Entry.$Name = $Value }
    else { $Entry | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

function Repair-CopilotSessionEntities {
    <#
        Restores the optimistic entities after a Home Assistant restart.

        The decision selector, the per-field dropdowns and the reply box are optimistic
        MQTT entities: they deliberately have no state topic, so their value sticks the
        moment it is set rather than waiting for a device to echo it back. The cost is
        that Home Assistant has nothing to restore them from on restart, and they all
        come back as `unknown` - the reply boxes show "unknown" instead of being blank,
        and an armed question loses its placeholder.

        The retained discovery configs survive, so the entities themselves reappear;
        only their state needs re-driving. The reply box is used as the sentinel (one
        cheap read per session per reconcile); when it is unknown the session's
        optimistic entities are re-primed, re-arming a live question from its marker so
        a decision that was waiting when Home Assistant went down is still answerable.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Live
    )

    foreach ($sessionId in @($State.Keys)) {
        if (-not $Live.ContainsKey($sessionId)) { continue }
        $node = Get-CopilotMqttNodeId -SessionId $sessionId

        # Sessions that were already running when the reply card arrived have no
        # payload sensor, yet the dashboard shows them the card regardless. Anything
        # typed into it would publish to a topic nothing subscribes to and be lost
        # without a word, so provision the sensor onto them here.
        #
        # Checked once per session per daemon run rather than every reconcile: the
        # answer cannot change underneath us, and this is a Home Assistant read per
        # live session.
        if (-not $script:DaemonPayloadSensorChecked.ContainsKey($sessionId)) {
            $script:DaemonPayloadSensorChecked[$sessionId] = $true
            try {
                $payloadProbe = $null
                try { $payloadProbe = Get-HomeAssistantState -EntityId "sensor.${node}_reply_payload" -Headers $Headers }
                catch { $payloadProbe = $null }
                if ($null -eq $payloadProbe) {
                    $payloadEntry = $State[$sessionId]
                    Publish-CopilotMqttReplyPayloadSensor -SessionId $sessionId `
                        -SessionName ([string]$payloadEntry.Name) -Machine ([string]$payloadEntry.Machine) `
                        -Headers $Headers
                    # Home Assistant derives the entity id from the device and entity
                    # names and ignores object_id, so without this the sensor lands as
                    # sensor.copilot_<session title>_reply_payload and the daemon's
                    # read of sensor.<node>_reply_payload finds nothing.
                    Start-Sleep -Milliseconds 1500
                    [void](Set-CopilotMqttEntityIds -SessionId $sessionId)
                    Write-DaemonLog -Message "provisioned reply payload sensor for $($sessionId.Substring(0,8))"
                }
            }
            catch {
                Write-DaemonLog -Message "could not provision the reply payload sensor for $sessionId : $($_.Exception.Message)"
            }
        }

        $needsRepair = $false
        try {
            # Check both optimistic entities: a session whose reply box happens to hold
            # a value can still have an unknown decision selector, so keying off the
            # reply box alone would leave that session unrepaired.
            $reply = Get-HomeAssistantState -EntityId "text.${node}_reply" -Headers $Headers
            if ([string]$reply.state -in @('unknown', 'unavailable')) { $needsRepair = $true }
            if (-not $needsRepair) {
                $dec = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
                if ([string]$dec.state -in @('unknown', 'unavailable')) { $needsRepair = $true }
            }
        }
        catch {
            continue
        }
        if (-not $needsRepair) { continue }

        $entry = $State[$sessionId]
        $name = [string]$entry.Name
        $machine = [string]$entry.Machine
        $marker = Get-CopilotDecisionMarker -SessionId $sessionId

        try {
            Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers `
                -Data @{ entity_id = "text.${node}_reply"; value = $script:DaemonConfig.ReplyBlankValue }

            if ($null -ne $marker) {
                # A question was live when Home Assistant went away - put it back.
                Set-CopilotMqttDecision -SessionId $sessionId -SessionName $name -Machine $machine `
                    -Question ([string]$marker.question) -Choices @($marker.choices) `
                    -Fields @($marker.fields) -DecisionId ([string]$marker.decisionId) -Headers $Headers | Out-Null
                Write-DaemonLog -Message "re-armed live decision for $($sessionId.Substring(0,8)) after Home Assistant restart"
            }
            else {
                Clear-CopilotMqttDecision -SessionId $sessionId -SessionName $name `
                    -Machine $machine -Headers $Headers
                Write-DaemonLog -Message "re-primed optimistic entities for $($sessionId.Substring(0,8)) after Home Assistant restart"
            }
        }
        catch {
            Write-DaemonLog -Message "entity repair failed for $sessionId : $($_.Exception.Message)"
        }
    }
}

function Invoke-PendingDecisions {
    <#
        Feeds Home Assistant answers into a live ask_user prompt, and clears the card
        when the ask_user is answered by either input.

        This is the Home-Assistant half of dual-input ask_user. The non-blocking hook
        arms the card and writes a marker; the native terminal prompt is answerable the
        whole time. For each session with a marker:

          - If the transcript shows the ask_user already completed (answered in the
            terminal, or by a previous injection), clear the card, blank the reply box
            and delete the marker.

          - If the ask_user is still pending and Home Assistant holds an answer that has
            not been injected yet, inject it into the native prompt. A freeform answer
            (reply box) is typed in as text; a choice (selector) is handled by the
            choice-injection strategy. Pending-ness is re-checked immediately before
            injecting so a terminal answer that just landed is never double-answered.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Live
    )

    foreach ($sessionId in @($State.Keys)) {
        if (-not $Live.ContainsKey($sessionId)) { continue }
        $marker = Get-CopilotDecisionMarker -SessionId $sessionId
        if ($null -eq $marker) { continue }

        $session = $Live[$sessionId]
        $node = Get-CopilotMqttNodeId -SessionId $sessionId
        $askState = Get-DaemonAskUserState -Session $session -Marker $marker

        # The hook writes the marker just before the tool runs, so the start event may
        # not be in the transcript yet. Wait a cycle rather than acting on a stale one.
        if (-not $askState.Started) { continue }

        if (-not $askState.Pending) {
            # Answered by whichever input got there first. Before tearing the card
            # down, check that an injected selection is the one the CLI recorded.
            #
            # The injector drives an arrow-key list by index, so a dropped keystroke
            # selects the neighbouring option and the prompt reports it as the user's
            # choice. Nothing downstream can tell - it is a confident wrong answer in
            # the user's name - so it has to be caught here and said out loud.
            try {
                $injected = @($marker.injectedSelections)
                if ($injected.Count -gt 0 -and -not (Test-CopilotAnswerMatchesSelections `
                        -ResultContent ([string]$askState.ResultContent) `
                        -Fields @($marker.fields) -Selections $injected)) {
                    Write-DaemonLog -Message "MISMATCH for $($sessionId.Substring(0,8)): sent [$($injected -join ' | ')] but the CLI recorded something else"
                    Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Answer may be wrong - check the terminal' `
                        -Extra @{ sent = ($injected -join ' | '); recorded = ([string]$askState.ResultContent) } -Headers $Headers

                    # Saying it on the card is not enough: the agent carries straight on
                    # from the wrong answer, and the warning is overwritten by its next
                    # activity update within seconds. So tell the session itself. Typed
                    # text is the one delivery path that is reliable here - it is how
                    # every reply is sent - which makes this correction land even though
                    # the keystrokes that caused the problem did not.
                    try {
                        $correction = Get-DaemonAnswerCorrection -Fields @($marker.fields) -Selections $injected
                        $fix = Send-CopilotSessionPrompt -SessionId $sessionId -Text $correction `
                            -ProcessId (Get-DaemonSessionProcessId -SessionId $sessionId)
                        if ($fix.Delivered) {
                            Write-DaemonLog -Message "sent a correction to $($sessionId.Substring(0,8)) with what was actually chosen"
                        }
                        else {
                            Write-DaemonLog -Message "could not correct $($sessionId.Substring(0,8)): $($fix.Detail)"
                        }
                    }
                    catch {
                        Write-DaemonLog -Message "correction failed for $sessionId : $($_.Exception.Message)"
                    }
                }
            }
            catch { }

            try {
                Clear-CopilotMqttDecision -SessionId $sessionId `
                    -SessionName ([string]$State[$sessionId].Name) `
                    -Machine ([string]$State[$sessionId].Machine) -Headers $Headers
                Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers `
                    -Data @{ entity_id = "text.${node}_reply"; value = $script:DaemonConfig.ReplyBlankValue }
            }
            catch {
                Write-DaemonLog -Message "decision clear failed for $sessionId : $($_.Exception.Message)"
            }
            Remove-CopilotDecisionMarker -SessionId $sessionId
            $entry = $State[$sessionId]
            if ($entry.PSObject.Properties['LastReply']) { $entry.LastReply = '' }
            Write-DaemonLog -Message "decision answered (either input); cleared card for $($sessionId.Substring(0,8))"
            continue
        }

        # Pending: is there a Home Assistant answer to inject?
        $answer = ''
        $selections = @()
        $isChoice = ([string]$marker.mode -eq 'multiple_choice')
        $markerFields = @($marker.fields)
        $isMultiField = $markerFields.Count -gt 1
        $terminalOnly = $false
        if ($marker.PSObject.Properties['terminalOnly']) { $terminalOnly = [bool]$marker.terminalOnly }

        # A hook whose Home Assistant work was cut short by its deadline leaves a
        # marker with no card behind it. Arm it here so an outage during the hook does
        # not silently cost the question its dashboard card.
        #
        # Armed-ness is read from the question attribute, not the option count. A
        # freeform question legitimately publishes a single-option selector, so
        # counting options treated every freeform card as unarmed and re-published it
        # on every reconcile - observed as the same line repeating every 18 seconds for
        # minutes on end, each one resetting the card the user was looking at.
        try {
            $armed = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
            if ([string]::IsNullOrWhiteSpace([string]$armed.attributes.question)) {
                Set-CopilotMqttDecision -SessionId $sessionId `
                    -SessionName ([string]$State[$sessionId].Name) `
                    -Machine ([string]$State[$sessionId].Machine) `
                    -Question ([string]$marker.question) `
                    -Choices @($marker.choices) -Fields $markerFields `
                    -DecisionId ([string]$marker.decisionId) -Headers $Headers | Out-Null
                Write-DaemonLog -Message "armed card from marker for $($sessionId.Substring(0,8)) (hook could not reach Home Assistant)"
            }
        }
        catch {
            Write-DaemonLog -Message "marker re-arm check failed for $sessionId : $($_.Exception.Message)"
        }

        # Some prompts cannot be driven from the dashboard at all - more fields than
        # it publishes dropdowns for, or more than one free-text field. The native
        # prompt is an arrow-key form, and characters typed at it are discarded, so
        # injecting anything here would lose the answer and leave the prompt waiting.
        # The card says to answer in the terminal; this makes sure nothing is sent.
        if ($terminalOnly) {
            $decisionKey = [string]$marker.decisionId
            if (-not $script:DaemonTerminalOnlyWarned.ContainsKey($decisionKey)) {
                $script:DaemonTerminalOnlyWarned[$decisionKey] = $true
                Write-DaemonLog -Message "decision for $($sessionId.Substring(0,8)) must be answered in the terminal; not injecting"
            }
            continue
        }

        try {
            if ($isMultiField) {
                # One dropdown per field. Cancel still rides on the main selector, and
                # the answer is only complete once every field has been chosen - a
                # half-filled form must not be injected.
                $sel = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
                if ([string]$sel.state -eq 'Cancel request') {
                    $answer = 'Cancel request'
                }
                else {
                    $picked = @()
                    $missingChoice = $false
                    for ($fi = 1; $fi -le $markerFields.Count; $fi++) {
                        $markerField = $markerFields[$fi - 1]

                        # A free-text field has no dropdown - it is answered in the
                        # Reply box, which is what makes a mixed form answerable at
                        # all. Its slot is collapsed, so read the box instead.
                        #
                        # An empty box is a valid answer. A free-text field is usually
                        # the optional "anything else?" one, and requiring it refused
                        # perfectly good submissions: every dropdown chosen, nothing to
                        # add, Send rejected. The prompt accepts an empty field the
                        # same way the terminal does - by committing it untouched.
                        if (Test-DecisionFieldIsText -Field $markerField) {
                            $v = ''
                            try {
                                $rep = Get-HomeAssistantState -EntityId "text.${node}_reply" -Headers $Headers
                                $v = [string]$rep.state
                            }
                            catch { }
                            if ([string]::IsNullOrWhiteSpace($v) -or $v -in @('unknown', 'unavailable')) { $v = '' }
                            $picked += $v
                            continue
                        }

                        $fs = Get-HomeAssistantState `
                            -EntityId (Get-CopilotMqttFieldEntityId -Node $node -Index $fi) -Headers $Headers
                        $v = [string]$fs.state
                        if ($v -in @('Choose...', 'Idle', 'unknown', 'unavailable', '')) {
                            $missingChoice = $true
                            break
                        }
                        $picked += $v
                    }
                    if ($missingChoice) { $picked = @() }

                    # Every field chosen is not enough: a multi-field answer is only
                    # sent when Submit is pressed, so selections can be reviewed and
                    # changed first. An MQTT button's state is the timestamp of its
                    # last press, so a press counts only if it is newer than the moment
                    # this question was armed - otherwise a press left over from a
                    # previous question would fire this one instantly.
                    $submitted = $false
                    $pressIsNew = $false
                    $pressedAt = ''
                    try {
                        $btn = Get-HomeAssistantState -EntityId "button.${node}_submit" -Headers $Headers
                        $pressedAt = [string]$btn.state
                        if ($pressedAt -notin @('unknown', 'unavailable', '')) {
                            $armedAt = [datetimeoffset][string]$marker.armedAt
                            $pressIsNew = ([datetimeoffset]$pressedAt) -gt $armedAt
                        }
                    }
                    catch {
                        # No button (older session): fall back to submitting as soon as
                        # every field is chosen rather than hanging.
                        $pressIsNew = ($picked.Count -eq $markerFields.Count)
                    }

                    if ($pressIsNew -and $picked.Count -ne $markerFields.Count) {
                        # Pressed with something still unanswered. Saying which is
                        # missing is the difference between a button that looks broken
                        # and one that is waiting on you.
                        $missing = @()
                        for ($fi = 0; $fi -lt $markerFields.Count; $fi++) {
                            if ($fi -lt $picked.Count) { continue }
                            $missing += [string]$markerFields[$fi].Label
                        }
                        try {
                            Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Not sent - answer every field' `
                                -Extra @{ waiting_on = ($missing -join ', ') } -Headers $Headers
                        }
                        catch { }
                        Write-DaemonLog -Message "submit pressed for $($sessionId.Substring(0,8)) with fields still unanswered"
                    }

                    if ($pressIsNew -and $picked.Count -eq $markerFields.Count) {
                        $submitted = $true
                        if (-not [string]::IsNullOrWhiteSpace($pressedAt)) {
                            # Consume the press so the same one cannot also be read as
                            # a Send for the reply box afterwards.
                            $entry = $State[$sessionId]
                            if ($entry.PSObject.Properties['LastSubmitAt']) { $entry.LastSubmitAt = $pressedAt }
                            else { $entry | Add-Member -NotePropertyName LastSubmitAt -NotePropertyValue $pressedAt -Force }
                        }
                        # Acknowledge the press before the injection, which takes a
                        # noticeable moment for a multi-field form.
                        try {
                            Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Sending answer...' `
                                -Extra @{ answer = ($picked -join ' + ') } -Headers $Headers
                        }
                        catch { }
                    }

                    if ($submitted) {
                        $selections = @($picked)
                        $answer = ($picked -join ' + ')
                    }
                }
            }
            elseif ($isChoice) {
                $sel = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
                $s = [string]$sel.state
                if ($s -notin @('Idle', 'Awaiting answer...', 'unknown', 'unavailable', '')) { $answer = $s }
            }
            else {
                $rep = Get-HomeAssistantState -EntityId "text.${node}_reply" -Headers $Headers
                $r = [string]$rep.state
                # Whitespace is the blank sentinel the reply box is parked on, not an
                # answer, so it must not be injected.
                if (-not [string]::IsNullOrWhiteSpace($r) -and
                    $r -notin @('unknown', 'unavailable')) { $answer = $r }
            }
        }
        catch {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($answer)) { continue }
        if ($answer -eq [string]$marker.injectedAnswer) { continue }

        # Re-verify the ask_user is still pending right before injecting, so a terminal
        # answer that landed in the last second is never double-answered.
        $recheck = Get-DaemonAskUserState -Session $session -Marker $marker
        if (-not $recheck.Pending) { continue }

        [void](Invoke-DaemonDecisionAnswer -SessionId $sessionId -Marker $marker `
            -Answer $answer -IsChoice $isChoice -Selections $selections -Headers $Headers)
    }
}

function Get-DaemonAskUserState {
    <#
        Whether a session's question is still waiting, from its transcript, in the
        format its agent writes. Copilot's reader cannot see a Claude question at all,
        which left every Claude card armed forever and its dropdown doing nothing.
    #>
    param(
        [Parameter(Mandatory)]$Session,

        # The pending-decision marker, when there is one: it names the question the
        # card is for, so a Claude card is judged by its own question's answer rather
        # than by whichever question the transcript happens to show last.
        [AllowNull()]$Marker = $null
    )

    $kind = if ($Session.PSObject.Properties['Kind'] -and $Session.Kind) { [string]$Session.Kind } else { 'copilot' }
    if ($kind -eq 'claude' -and $script:ClaudeAdapterLoaded) {
        $toolCallId = ''
        $since = $null
        if ($null -ne $Marker) {
            if ($Marker.PSObject.Properties['toolCallId']) { $toolCallId = [string]$Marker.toolCallId }
            if ($Marker.PSObject.Properties['armedAt']) { $since = [string]$Marker.armedAt }
        }
        return Get-ClaudeAskUserState -TranscriptPath ([string]$Session.Transcript) -ToolCallId $toolCallId -Since $since
    }
    Get-CopilotAskUserState -TranscriptPath ([string]$Session.Transcript)
}

function Get-DaemonSessionProcessId {
    <#
        The owning process of a Claude or Codex session, from the live set, or 0 for a
        Copilot session, which the injector finds by its lock file.
    #>
    param([Parameter(Mandatory)][string]$SessionId)

    $known = if ($script:DaemonLive) { $script:DaemonLive[$SessionId] } else { $null }
    if ($null -ne $known -and $known.PSObject.Properties['Kind'] -and [string]$known.Kind -in @('claude', 'codex') -and
        $known.PSObject.Properties['ProcessId'] -and [int]$known.ProcessId -gt 0) {
        return [int]$known.ProcessId
    }
    0
}

function Complete-DaemonClaudeAnswer {
    <#
        Makes sure an answer driven into a Claude question was submitted.

        The option is chosen by arrow keys and Enter, but Claude can finish on a review
        screen that needs one more Enter. If the question is still pending once the keys
        have had time to land, Enter is pressed once, and the result is reported as
        delivered only when the transcript shows the question answered. Other agents
        are returned unchanged.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$Delivery,
        [AllowNull()]$Marker = $null,
        [int]$WaitMs = 1500
    )

    $session = if ($script:DaemonLive) { $script:DaemonLive[$SessionId] } else { $null }
    if ($null -eq $session -or -not $session.PSObject.Properties['Kind'] -or [string]$session.Kind -ne 'claude') { return $Delivery }

    $answered = {
        $deadline = [DateTimeOffset]::Now.AddMilliseconds($WaitMs)
        while ([DateTimeOffset]::Now -lt $deadline) {
            if (-not (Get-DaemonAskUserState -Session $session -Marker $Marker).Pending) { return $true }
            Start-Sleep -Milliseconds 150
        }
        $false
    }

    if (& $answered) { return $Delivery }

    try {
        Initialize-CopilotConsoleInjector
        [void][CopilotCli.ConsoleInjector]::Send([uint32]$Delivery.ProcessId, '', $true, 0)
    }
    catch { }

    if (& $answered) {
        $Delivery.Detail = "$($Delivery.Detail); submitted with an extra Enter"
        return $Delivery
    }

    $Delivery.Delivered = $false
    $Delivery.Detail = "keys sent but the question is still waiting ($($Delivery.Detail))"
    $Delivery
}

function Invoke-DaemonDecisionAnswer {
    <#
        Injects a single Home Assistant answer into a live ask_user prompt. Freeform
        answers are typed as text; choices are handled by the choice-injection
        strategy. Marks the marker as injected on success so it is not repeated, and
        blanks the Home Assistant input field.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][object]$Marker,
        [Parameter(Mandatory)][string]$Answer,
        [Parameter(Mandatory)][bool]$IsChoice,
        [AllowEmptyCollection()][string[]]$Selections = @(),
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $short = $SessionId.Substring(0, [Math]::Min(8, $SessionId.Length))
    $node = Get-CopilotMqttNodeId -SessionId $SessionId
    # Claude and Codex leave no lock file for the injector to find their process by.
    $processId = Get-DaemonSessionProcessId -SessionId $SessionId

    if ($IsChoice) {
        # The native prompt is one arrow-key option list per field (tabbed when there
        # is more than one). Selecting by index returns the schema's real value for
        # each field, so prefer that; the per-field "Other (type your answer)" text
        # path is only a fallback when the option cannot be located.
        $fields = @($Marker.fields)
        $sel = @($Selections)
        if ($sel.Count -eq 0 -and $fields.Count -eq 1) {
            # Single-field choice: the selector's value is the field's option.
            $sel = @($Answer)
        }

        $delivery = $null
        if ($fields.Count -gt 0 -and $sel.Count -eq $fields.Count) {
            $delivery = Send-CopilotSessionForm -SessionId $SessionId -Fields $fields -Selections $sel -ProcessId $processId
        }
        if ($null -eq $delivery -or -not $delivery.Delivered) {
            if ($null -ne $delivery) {
                Write-DaemonLog -Message "form injection unavailable for $short ($($delivery.Detail)); falling back to text"
            }
            $delivery = Send-CopilotSessionChoice -SessionId $SessionId -Text $Answer `
                -ChoiceCount (@($Marker.choices).Count) -ProcessId $processId
        }
    }
    else {
        $delivery = Send-CopilotSessionPrompt -SessionId $SessionId -Text $Answer -ProcessId $processId
    }

    # Claude may end on a review screen after the last question's option is chosen, so
    # a question still pending once the keys have landed gets one Enter to submit it.
    if ($delivery.Delivered) {
        $delivery = Complete-DaemonClaudeAnswer -SessionId $SessionId -Delivery $delivery -Marker $Marker
    }

    if ($delivery.Delivered) {
        Set-CopilotDecisionMarkerInjected -SessionId $SessionId -Answer $Answer -Selections @($Selections)
        try {
            Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers `
                -Data @{ entity_id = "text.${node}_reply"; value = $script:DaemonConfig.ReplyBlankValue }
        }
        catch { }
        try {
            $shown = ($Answer -replace '\s+', ' ').Trim()
            if ($shown.Length -gt 60) { $shown = $shown.Substring(0, 57) + '...' }
            Set-DaemonTransientActivity -SessionId $SessionId -Summary 'Answer sent' `
                -Extra @{ answer = $shown; at = [DateTimeOffset]::Now.ToString('HH:mm:ss') } -Headers $Headers
        }
        catch { }
        Write-DaemonLog -Message "decision answer injected to $short (pid $($delivery.ProcessId)): $($delivery.Detail)"
    }
    else {
        try {
            Set-DaemonTransientActivity -SessionId $SessionId -Summary 'Answer NOT sent' `
                -Extra @{ error = [string]$delivery.Detail } -Headers $Headers
        }
        catch { }
        Write-DaemonLog -Message "decision answer injection FAILED for $short : $($delivery.Detail)"
    }
    $delivery.Delivered
}

function Clear-CopilotMqttOrphans {
    <#
        Removes published entities for sessions that are no longer live.

        A daemon that is killed rather than shut down cleanly, or a session that exits
        while no daemon is running, leaves its retained MQTT discovery configs in the
        broker with nothing to retire them. On startup the daemon reconciles the full
        published set against the live sessions and clears anything orphaned, so the
        dashboard never accumulates dead sessions across daemon restarts.

        Orphans are matched by node id: every published entity id is
        `<component>.agent_bridge_<node>_<object>`, and the live node ids are computed
        from the live sessions.

        "Not live here" is not the same as orphaned, though, and that is the whole
        difficulty. One Home Assistant is normally shared, so most published sessions
        belong to some other machine and are perfectly alive. Nodes claimed by a peer
        are therefore excluded, and when the peer list could not be read the sweep is
        skipped entirely rather than run on a partial picture - deleting a running
        machine's session entities is far worse than leaving a dead one a while longer,
        and the sweep runs again on the next start.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$Live
    )

    $liveNodes = @{}
    foreach ($sessionId in $Live.Keys) {
        $liveNodes[(Get-CopilotMqttNodeId -SessionId $sessionId)] = $true
    }

    try {
        $states = Get-DaemonHomeAssistantStates -Headers $Headers
    }
    catch {
        Write-DaemonLog -Message "orphan sweep skipped: $($_.Exception.Message)"
        return
    }

    # Every machine, including this one, so a machine-level node is never mistaken for
    # a session and peers' sessions are left alone.
    $peers = @(Get-BridgePeerMachine -States $states)
    if ($peers.Count -eq 0) {
        Write-DaemonLog -Message 'orphan sweep skipped: no machine sensors visible yet'
        return
    }
    foreach ($peer in $peers) {
        $liveNodes[(Get-CopilotMqttMachineNode -Slug $peer.Slug)] = $true
        if ($peer.IsSelf) { continue }
        foreach ($remote in @($peer.Sessions)) {
            $node = [string]$remote.node
            if ($node) { $liveNodes[$node] = $true }
        }
    }

    $orphanNodes = @{}
    foreach ($state in @($states)) {
        if ($null -eq $state) { continue }
        if ([string]$state.entity_id -notmatch '^(?:select|sensor|text|button)\.(agent_bridge_[0-9a-z]{12,})_') {
            continue
        }
        $node = $Matches[1]
        if (-not $liveNodes.ContainsKey($node)) { $orphanNodes[$node] = $true }
    }

    foreach ($node in $orphanNodes.Keys) {
        foreach ($topic in @(
            (Get-CopilotMqttSessionDiscoveryTopic -Node $node) +
            (Get-CopilotMqttSessionStateTopic -Node $node)
        )) {
            try {
                Publish-CopilotMqttMessage -Topic $topic -Payload '' -Headers $Headers -Retain
            }
            catch {
                # Best effort; a missed one is caught on the next startup sweep.
            }
        }
        Write-DaemonLog -Message "cleared orphaned entities for node $node"
    }
}

function Invoke-DaemonUpdateOutcome {
    <#
        Announces the result of a self-update.

        The updater runs detached, with none of the bridge's modules or Home Assistant
        config loaded, so it cannot publish cleanly itself. It drops a small outcome
        file instead, and whichever daemon runs next turns that into a visible
        notification and an authoritative update-entity state. Reading it every
        reconcile - not only at startup - means the announcement fires whether the
        daemon was restarted by a successful update or kept running through a failed
        one.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    $path = $script:DaemonConfig.UpdateOutcomeFile
    if (-not (Test-Path -LiteralPath $path)) { return }

    $outcome = $null
    try { $outcome = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $outcome = $null }
    # A malformed or unreadable marker must not wedge the daemon: drop it and move on.
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($null -eq $outcome) { return }

    # Ignore a marker from long ago - a machine that was off for a week should not pop
    # a surprise notification when it wakes.
    try {
        if ($outcome.PSObject.Properties.Name -contains 'at' -and $outcome.at) {
            if (([DateTimeOffset]::Now - [DateTimeOffset]::Parse([string]$outcome.at)).TotalHours -gt 6) { return }
        }
    }
    catch { }

    $success = ($outcome.PSObject.Properties.Name -contains 'success' -and $outcome.success)
    $version = if ($outcome.PSObject.Properties.Name -contains 'version') { [string]$outcome.version } else { '' }
    $url = if ($outcome.PSObject.Properties.Name -contains 'releaseUrl') { [string]$outcome.releaseUrl } else { '' }

    try {
        if ($success) {
            # Authoritative "up to date" using the version actually installed, so the
            # entity is correct even on a daemon whose cached config is still stale.
            Publish-CopilotMqttUpdate -InstalledVersion $version -LatestVersion $version `
                -ReleaseUrl $url -Headers $Headers
            [void](Set-CopilotMqttUpdateEntityIds)
            $script:DaemonUpdateAvailable = $false
            $script:DaemonUpdatePublished = $true
            $message = "The Home Assistant bridge updated to **$version**."
            if ($url) { $message += " [Release notes]($url)" }
            Invoke-HomeAssistantService -Domain 'persistent_notification' -Service 'create' `
                -Data @{ title = "Bridge updated on $($script:DaemonMachineName)"; message = $message; notification_id = "agent_bridge_update_$($script:DaemonMachineSlug)" } `
                -Headers $Headers
            Write-DaemonLog -Message "self-update announced: updated to $version"
        }
        else {
            $err = if ($outcome.PSObject.Properties.Name -contains 'error') { [string]$outcome.error } else { 'unknown error' }
            # Clear the spinner, but leave the update showing as available so it can be
            # retried.
            $installed = (Get-BridgeUpdateStatus).Installed
            $latest = if ($version) { $version } else { $installed }
            Publish-CopilotMqttUpdate -InstalledVersion $installed -LatestVersion $latest -Headers $Headers
            Invoke-HomeAssistantService -Domain 'persistent_notification' -Service 'create' `
                -Data @{ title = "Bridge update failed on $($script:DaemonMachineName)"; message = "The bridge update did not complete: $err"; notification_id = "agent_bridge_update_$($script:DaemonMachineSlug)" } `
                -Headers $Headers
            Write-DaemonLog -Message "self-update announced: FAILED ($err)"
        }
    }
    catch {
        Write-DaemonLog -Message "update outcome announce failed: $($_.Exception.Message)"
    }
}

function Invoke-PendingStops {
    <#
        Ends any session whose End button has been pressed.

        Uses the same press-timestamp contract as the Submit and Launch buttons: a
        press from before this daemon started is a retained value from an earlier
        run, and a press already acted on is recorded per session so one press can
        never end two sessions or the same session twice.

        Ending is graceful - `/exit` typed into the console - so the CLI writes its
        transcript and releases its lock. The session therefore stays resumable, and
        the next reconcile retires its entities the same way a session that exited at
        the keyboard would be.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Live
    )

    foreach ($sessionId in @($State.Keys)) {
        if (-not $Live.ContainsKey($sessionId)) { continue }

        $node = Get-CopilotMqttNodeId -SessionId $sessionId
        $press = ''
        try {
            $button = Get-HomeAssistantState -EntityId "button.${node}_stop" -Headers $Headers
            $press = [string]$button.state
        }
        catch {
            # The button does not exist yet for sessions published before it existed;
            # the next reconcile provisions it.
            continue
        }

        if ($press -in @('unknown', 'unavailable', '')) { continue }

        $entry = $State[$sessionId]
        $lastStop = if ($entry.PSObject.Properties['LastStopAt']) { [string]$entry.LastStopAt } else { '' }
        if ($press -eq $lastStop) { continue }

        if ($entry.PSObject.Properties['LastStopAt']) { $entry.LastStopAt = $press }
        else { $entry | Add-Member -NotePropertyName LastStopAt -NotePropertyValue $press -Force }

        $pressedAt = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($press, [ref]$pressedAt)) { continue }
        if ($pressedAt -le $script:DaemonStartedAt) { continue }

        $session = $Live[$sessionId]
        $processId = 0
        if ($session.PSObject.Properties['ProcessId'] -and $session.ProcessId) { $processId = [int]$session.ProcessId }

        $short = $sessionId.Substring(0, [Math]::Min(8, $sessionId.Length))
        Write-DaemonLog -Message "end requested for $short (pid $processId)"

        # Say so on the card straight away: the status reads "ending" while the
        # session closes, instead of carrying on as "working" or "idle" until it has
        # gone.
        # Separately guarded, so a failed status publish cannot also cost the card its
        # "Ending session..." line.
        try {
            Set-CopilotMqttStatus -SessionId $sessionId -Status 'ending' -Headers $Headers -Attributes @{
                session    = $entry.Name
                machine    = $entry.Machine
                process_id = $processId
                updated    = [DateTimeOffset]::Now.ToString('o')
            }
            $entry.Status = 'ending'
        }
        catch { }
        try {
            Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Ending session...' `
                -Headers $Headers
        }
        catch { }

        $stop = Stop-BridgeCopilotSession -SessionId $sessionId -ProcessId $processId
        if ($stop.Stopped) {
            Write-DaemonLog -Message "ended $short : $($stop.Detail)"
            # Retire it now rather than on the next pass, so the card goes when the
            # session does.
            $script:DaemonReconcileNow = $true

            # Close the console the bridge opened for this session. The CLI exiting
            # does not always take its launcher with it - Agency wraps the CLI, so the
            # wrapper can outlive it and leave an empty window sitting there needing a
            # second exit typed into it.
            #
            # Only ever applied to a process the bridge started itself. A terminal the
            # user opened is theirs, and closing it would throw away whatever else is
            # in that window.
            $launcherPid = 0
            if ($script:DaemonLaunchedPids.ContainsKey($sessionId)) {
                $launcherPid = [int]$script:DaemonLaunchedPids[$sessionId]
            }
            if ($launcherPid -gt 0 -and $launcherPid -ne $processId) {
                Start-Sleep -Milliseconds 1200
                $launcher = Get-Process -Id $launcherPid -ErrorAction SilentlyContinue
                if ($null -ne $launcher) {
                    try {
                        Stop-Process -Id $launcherPid -Force -ErrorAction Stop
                        Write-DaemonLog -Message "closed the window the bridge opened for $short (pid $launcherPid)"
                    }
                    catch {
                        Write-DaemonLog -Message "could not close the window for $short : $($_.Exception.Message)"
                    }
                }
            }
            [void]$script:DaemonLaunchedPids.Remove($sessionId)
        }
        else {
            Write-DaemonLog -Message "could not end $short : $($stop.Detail)"
            try {
                Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Could not end session' `
                    -Extra @{ error = [string]$stop.Detail } -Headers $Headers
            }
            catch { }
        }
    }
}

function Sync-DaemonUpdateStatus {
    <#
        Publishes the bridge's own update status, and acts on a press of the install
        button.

        Both halves are deliberately forgiving: an update check that fails, or a
        GitHub outage, must never disturb a running session. The check itself is
        cached for a day inside Get-BridgeLatestRelease, so calling this on every
        reconcile costs nothing.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    # A pending self-update result is announced regardless of the update-check opt-out:
    # it is the response to the user pressing install, not a background poll.
    Invoke-DaemonUpdateOutcome -Headers $Headers

    # Opting out has to stop the network call, not just hide the result, so this is
    # checked before anything else happens.
    if (-not (Get-BridgeSetting 'updates.checkForUpdates' $true)) { return }

    try {
        $status = Get-BridgeUpdateStatus
        $latest = if ($status.Available) { $status.Latest } else { $status.Installed }

        if ($status.Available -ne $script:DaemonUpdateAvailable -or -not $script:DaemonUpdatePublished) {
            Publish-CopilotMqttUpdate -InstalledVersion $status.Installed -LatestVersion $latest `
                -ReleaseUrl $status.Url -ReleaseNotes $status.Notes -Headers $Headers
            [void](Set-CopilotMqttUpdateEntityIds)
            $script:DaemonUpdatePublished = $true
            if ($status.Available -ne $script:DaemonUpdateAvailable) {
                $script:DaemonUpdateAvailable = $status.Available
                if ($status.Available) {
                    Write-DaemonLog -Message "update available: $($status.Installed) -> $($status.Latest)"
                }
            }
        }
    }
    catch {
        Write-DaemonLog -Message "update check failed: $($_.Exception.Message)"
        return
    }

    # The install button is a press timestamp, like the per-session Submit button.
    # A press from before this daemon started is history - a retained value from an
    # earlier run - while anything newer is a real instruction. Comparing against the
    # start time rather than simply ignoring the first value seen means a press made
    # moments after a restart still counts, instead of being silently swallowed.
    try {
        $button = Get-HomeAssistantState -EntityId $script:DaemonEntity.InstallUpdate -Headers $Headers
        $press = [string]$button.state
        if ($press -in @('unknown', 'unavailable', '')) { return }
        if ($press -eq $script:DaemonUpdateLastPress) { return }
        $script:DaemonUpdateLastPress = $press

        $pressedAt = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($press, [ref]$pressedAt)) { return }
        if ($pressedAt -le $script:DaemonStartedAt) { return }

        Write-DaemonLog -Message 'install update requested from Home Assistant'
        # Spinner up front. The retained in_progress=true outlives the daemon that the
        # updater is about to restart, and the next daemon clears it.
        try {
            Publish-CopilotMqttUpdate -InstalledVersion $status.Installed -LatestVersion $latest `
                -ReleaseUrl $status.Url -ReleaseNotes $status.Notes -InProgress -Headers $Headers
        }
        catch {
            Write-DaemonLog -Message "could not show update spinner: $($_.Exception.Message)"
        }
        $result = Invoke-BridgeSelfUpdate -Detached
        Write-DaemonLog -Message "self-update: $($result.Detail)"
    }
    catch {
        # The button may not exist yet on a first run.
    }
}

function Get-DaemonResumableSessions {
    <#
        The cached list of sessions offered in the resume dropdown.

        Behind this is `agency hub list-local-sessions --json`, which on a working
        machine describes hundreds of sessions in half a megabyte and takes over a
        second. Running that every 15 seconds would be a waste, and the list barely
        changes, so it is refreshed on a timer and served from memory in between.

        Live sessions are excluded every time, from the current live set rather than
        from the cache, so a session that has just started cannot be offered for
        resume while it is still running - two CLIs sharing one transcript would
        corrupt it.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$LiveSessionIds,
        [switch]$Force
    )

    $age = ([DateTimeOffset]::Now - $script:DaemonResumeCacheAt).TotalSeconds
    if ($Force.IsPresent -or $age -ge $script:DaemonConfig.ResumeCacheSeconds) {
        try {
            $fetched = @(Get-BridgeResumableSessions)

            # An empty result is treated as a failed fetch, not as truth, whenever a
            # previous fetch found something. Launching a session spawns Agency, and a
            # `hub list-local-sessions` running at that moment comes back with
            # nothing - which was then cached as authoritative for the full interval,
            # emptying the resume dropdown for minutes at a time. A machine that had
            # sessions a moment ago still has them.
            if ($fetched.Count -eq 0 -and @($script:DaemonResumeCache).Count -gt 0) {
                $script:DaemonResumeCacheAt = [DateTimeOffset]::Now.AddSeconds(
                    -$script:DaemonConfig.ResumeCacheSeconds + $script:DaemonConfig.ResumeRetrySeconds)
                Write-DaemonLog -Message 'resumable session list came back empty; keeping the previous one and retrying shortly'
            }
            else {
                $script:DaemonResumeCache = $fetched
                $script:DaemonResumeCacheAt = [DateTimeOffset]::Now
            }
        }
        catch {
            Write-DaemonLog -Message "resumable session list failed: $($_.Exception.Message)"
            $script:DaemonResumeCacheAt = [DateTimeOffset]::Now.AddSeconds(
                -$script:DaemonConfig.ResumeCacheSeconds + $script:DaemonConfig.ResumeRetrySeconds)
        }
    }

    $live = @{}
    foreach ($id in @($LiveSessionIds)) {
        if (-not [string]::IsNullOrWhiteSpace($id)) { $live[[string]$id] = $true }
    }

    @(@($script:DaemonResumeCache) | Where-Object { -not $live.ContainsKey([string]$_.SessionId) })
}

function Set-DaemonNewSessionDefaults {
    <#
        Keeps the new-session selectors showing a usable default.

        They are optimistic MQTT entities, so Home Assistant has nothing to restore
        them from: they read `unknown` when first created and again after every
        restart. Left alone, the card opens on "unknown" and pressing Launch looks
        like it is guessing. Driving them to the configured default makes the whole
        flow one button press, and re-driving whenever they fall back to `unknown`
        repairs them after a Home Assistant restart - the same approach
        Repair-CopilotSessionEntities takes for the per-session entities.

        A value the user has actually chosen is never overwritten; only `unknown`,
        `unavailable`, and options that no longer exist are replaced.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Workspaces,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Profiles,
        [AllowEmptyCollection()][object[]]$Resumable = @(),
        [AllowEmptyCollection()][string[]]$Agents = @()
    )

    $stale = @('unknown', 'unavailable', '')

    if ($Agents.Count -gt 0) {
        $default = Get-BridgeLauncherLabel -Launcher (Get-BridgeLauncherKind)
        if ($Agents -notcontains $default) { $default = $Agents[0] }
        try {
            $current = [string](Get-HomeAssistantState -EntityId $script:DaemonEntity.NewAgent -Headers $Headers).state
            if ($current -in $stale -or $Agents -notcontains $current) {
                Invoke-HomeAssistantService -Domain 'select' -Service 'select_option' -Headers $Headers `
                    -Data @{ entity_id = $script:DaemonEntity.NewAgent; option = $default }
            }
        }
        catch { }
    }

    if ($Workspaces.Count -gt 0) {
        $default = Get-BridgeDefaultWorkspaceLabel
        if (-not [string]::IsNullOrWhiteSpace($default)) {
            try {
                $current = [string](Get-HomeAssistantState -EntityId $script:DaemonEntity.NewWorkspace -Headers $Headers).state
                $valid = @($Workspaces | ForEach-Object { [string]$_.Label })
                if ($current -in $stale -or $valid -notcontains $current) {
                    Invoke-HomeAssistantService -Domain 'select' -Service 'select_option' -Headers $Headers `
                        -Data @{ entity_id = $script:DaemonEntity.NewWorkspace; option = $default }
                }
            }
            catch { }
        }
    }

    if ($Profiles.Count -gt 0) {
        $default = Get-BridgeDefaultAgencyProfile
        if (-not [string]::IsNullOrWhiteSpace($default)) {
            try {
                $current = [string](Get-HomeAssistantState -EntityId $script:DaemonEntity.NewProfile -Headers $Headers).state
                if ($current -in $stale -or $Profiles -notcontains $current) {
                    Invoke-HomeAssistantService -Domain 'select' -Service 'select_option' -Headers $Headers `
                        -Data @{ entity_id = $script:DaemonEntity.NewProfile; option = $default }
                }
            }
            catch { }
        }
    }

    # The prompt is optional, so it should look empty and inviting rather than
    # reading "unknown" as though something were wrong.
    try {
        $current = [string](Get-HomeAssistantState -EntityId $script:DaemonEntity.NewPrompt -Headers $Headers).state
        if ($current -in @('unknown', 'unavailable')) {
            Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers `
                -Data @{ entity_id = $script:DaemonEntity.NewPrompt; value = $script:DaemonConfig.ReplyBlankValue }
        }
    }
    catch { }

    # Resume defaults to "New session" and is reset there whenever the selected
    # session drops off the list, so a stale pick can never launch something
    # unexpected on the next press.
    try {
        $current = [string](Get-HomeAssistantState -EntityId $script:DaemonEntity.NewResume -Headers $Headers).state
        $valid = @($script:CopilotMqttNewSessionOption) + @($Resumable | ForEach-Object { [string]$_.Label })
        if ($current -in $stale -or $valid -notcontains $current) {
            Invoke-HomeAssistantService -Domain 'select' -Service 'select_option' -Headers $Headers `
                -Data @{ entity_id = $script:DaemonEntity.NewResume; option = $script:CopilotMqttNewSessionOption }
        }
    }
    catch { }
}

function Sync-DaemonNewSession {
    <#
        Publishes the new-session controls, and acts on a press of the launch button.

        Modelled directly on Sync-DaemonUpdateStatus, including the press-timestamp
        handling: a press from before this daemon started is history left in a
        retained value, while anything newer is a real instruction. Comparing against
        the start time rather than simply swallowing the first value seen means a
        press made moments after a restart still counts.

        The prompt, workspace, profile and resume choice are read at press time, not
        watched, because they only matter in combination with a press.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$Live
    )

    if (-not (Get-BridgeSetting 'newSession.enabled' $true)) { return }

    $workspaces = @(Get-BridgeWorkspaceChoices)
    $launcher = Get-BridgeLauncherKind
    $launchers = @(Get-BridgeAvailableLaunchers)
    $agents = @($launchers | ForEach-Object { Get-BridgeLauncherLabel -Launcher $_ })
    # Assigned in two steps deliberately: `$x = if (...) { @(...) } else { @() }`
    # collapses an empty array to $null, and StrictMode then throws on .Count.
    # Profiles are offered whenever Agency is installed, since it can be chosen as the
    # agent at launch time even when it is not the default.
    $profiles = @()
    if ($launchers -contains 'agency') { $profiles = @(Get-BridgeAgencyProfiles) }

    $resumable = @(Get-DaemonResumableSessions -LiveSessionIds @($Live.Keys))

    # Re-publish only when the configured list changes, so an unchanged bridge sends
    # nothing on a normal reconcile.
    $signature = (($workspaces | ForEach-Object { "$($_.Label)=$($_.Path)" }) -join '|') +
        "#$launcher#" + ($agents -join ',') + '#' + ($profiles -join ',') +
        '#' + (($resumable | ForEach-Object { [string]$_.SessionId }) -join ',')
    if (-not $script:DaemonNewSessionPublished -or $signature -ne $script:DaemonNewSessionSignature) {
        try {
            Publish-CopilotMqttNewSession -Workspaces $workspaces -Profiles $profiles `
                -Resumable $resumable -Agents $agents -Headers $Headers
            [void](Set-CopilotMqttNewSessionEntityIds)
            $script:DaemonNewSessionPublished = $true
            $script:DaemonNewSessionSignature = $signature
            Write-DaemonLog -Message "new-session controls published ($($workspaces.Count) workspace(s), agents: $(if ($agents.Count) { $agents -join ', ' } else { 'none' }), default $launcher$(if ($profiles.Count) { ", profiles: $($profiles -join ', ')" }), $($resumable.Count) resumable)"
        }
        catch {
            Write-DaemonLog -Message "new-session publish failed: $($_.Exception.Message)"
            return
        }
    }

    Set-DaemonNewSessionDefaults -Headers $Headers -Workspaces $workspaces -Profiles $profiles `
        -Resumable $resumable -Agents $agents

    try {
        $button = Get-HomeAssistantState -EntityId $script:DaemonEntity.NewSession -Headers $Headers
        $press = [string]$button.state
    }
    catch {
        # The button may not exist yet on a first run.
        return
    }

    if ($press -in @('unknown', 'unavailable', '')) { return }
    if ($press -eq $script:DaemonNewSessionLastPress) { return }
    $script:DaemonNewSessionLastPress = $press

    $pressedAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($press, [ref]$pressedAt)) { return }
    if ($pressedAt -le $script:DaemonStartedAt) { return }

    # A press while a launched Claude session is asking whether to trust its folder
    # is the user's confirmation, not a request for another session: trusting lets
    # Claude read, edit and run files there, so the bridge only ever answers it on
    # this deliberate second press. The answer is sent on the next pass, from the
    # screen as it is then.
    $pending = $script:DaemonPendingLaunch
    if ($null -ne $pending -and $null -ne $pending.TrustAskedAt -and -not $pending.TrustConfirmed) {
        if (([DateTimeOffset]::Now - $pending.TrustAskedAt).TotalSeconds -le 120) {
            $pending.TrustConfirmed = $true
            $pending.LastCheck = [DateTimeOffset]::MinValue
            Write-DaemonLog -Message "Launch pressed again: trusting the folder for the Claude session in $($pending.Label)"
            Set-CopilotMqttNewSessionResult -Headers $Headers -Text "Trusting $($pending.Label) for Claude..."
            Update-DaemonPendingLaunch -Headers $Headers
            return
        }
    }

    if ($workspaces.Count -eq 0) {
        Write-DaemonLog -Message 'new session requested but no workspaces are configured'
        Set-CopilotMqttNewSessionResult -Headers $Headers `
            -Text 'No workspaces configured - add newSession.workspaces to the bridge config'
        return
    }

    # The agent. An untouched selector means the default; anything else must name an
    # installed agent, or the launch is refused rather than guessed at.
    $agentLabel = ''
    try { $agentLabel = [string](Get-HomeAssistantState -EntityId $script:DaemonEntity.NewAgent -Headers $Headers).state }
    catch { }
    if ($agentLabel -in @('unknown', 'unavailable', '') -or [string]::IsNullOrWhiteSpace($agentLabel)) {
        $agentLabel = Get-BridgeLauncherLabel -Launcher $launcher
    }
    $chosenLauncher = Resolve-BridgeLauncher -Label $agentLabel
    if ([string]::IsNullOrWhiteSpace($chosenLauncher)) {
        if ($launchers.Count -gt 0) {
            Write-DaemonLog -Message "new session requested with unknown agent '$agentLabel'"
            Set-CopilotMqttNewSessionResult -Text "Unknown agent '$agentLabel'" -Headers $Headers
            return
        }
        # Nothing is installed: let the launch attempt name what is missing.
        $chosenLauncher = $launcher
    }

    $label = ''
    try {
        $selected = Get-HomeAssistantState -EntityId $script:DaemonEntity.NewWorkspace -Headers $Headers
        $label = [string]$selected.state
    }
    catch { }

    # An untouched optimistic select reads as unknown, which should mean "the
    # configured default" rather than an error the user has to go and fix on a phone.
    if ($label -in @('unknown', 'unavailable', '') -or [string]::IsNullOrWhiteSpace($label)) {
        $label = Get-BridgeDefaultWorkspaceLabel
    }

    $directory = Resolve-BridgeWorkspacePath -Label $label
    if ([string]::IsNullOrWhiteSpace($directory)) {
        Write-DaemonLog -Message "new session requested for unknown workspace '$label'"
        Set-CopilotMqttNewSessionResult -Text "Unknown workspace '$label'" -Headers $Headers
        return
    }

    $prompt = ''
    try {
        $promptState = Get-HomeAssistantState -EntityId $script:DaemonEntity.NewPrompt -Headers $Headers
        $prompt = [string]$promptState.state
    }
    catch { }
    if ($prompt -in @('unknown', 'unavailable')) { $prompt = '' }
    $prompt = $prompt.Trim()

    # The profile only applies under Agency. An untouched selector falls back to the
    # first configured profile, and an unrecognised one is refused outright rather
    # than passed to a command line.
    $agencyProfile = ''
    if ($chosenLauncher -eq 'agency' -and $profiles.Count -gt 0) {
        $profileLabel = ''
        try {
            $profileState = Get-HomeAssistantState -EntityId $script:DaemonEntity.NewProfile -Headers $Headers
            $profileLabel = [string]$profileState.state
        }
        catch { }

        if ($profileLabel -in @('unknown', 'unavailable', '') -or [string]::IsNullOrWhiteSpace($profileLabel)) {
            $profileLabel = Get-BridgeDefaultAgencyProfile
        }

        $agencyProfile = Resolve-BridgeAgencyProfile -Name $profileLabel
        if ([string]::IsNullOrWhiteSpace($agencyProfile)) {
            Write-DaemonLog -Message "new session requested with unknown profile '$profileLabel'"
            Set-CopilotMqttNewSessionResult -Text "Unknown profile '$profileLabel'" -Headers $Headers
            return
        }
    }

    # Resume, if one is selected. The chosen session brings its own working
    # directory: resuming a conversation somewhere other than where it happened
    # would point the agent at the wrong tree. The workspace selector is therefore
    # ignored for a resume, and only the profile still applies.
    $resumeSession = $null
    $resumeLabel = ''
    try {
        $resumeState = Get-HomeAssistantState -EntityId $script:DaemonEntity.NewResume -Headers $Headers
        $resumeLabel = [string]$resumeState.state
        if (-not [string]::IsNullOrWhiteSpace($resumeLabel) -and
            $resumeLabel -notin @('unknown', 'unavailable', $script:CopilotMqttNewSessionOption)) {
            $resumeSession = @($resumable) | Where-Object { $_.Label -eq $resumeLabel } | Select-Object -First 1
            if ($null -eq $resumeSession) {
                Write-DaemonLog -Message "resume requested for unknown session '$resumeLabel'"
                Set-CopilotMqttNewSessionResult -Text "That session is no longer resumable" -Headers $Headers
                return
            }
        }
    }
    catch { }

    if ($null -ne $resumeSession) {
        $resumeDirectory = [string]$resumeSession.Folder
        if ([string]::IsNullOrWhiteSpace($resumeDirectory) -or -not [System.IO.Directory]::Exists($resumeDirectory)) {
            # The folder it ran in has gone. Falling back to the selected workspace
            # keeps the resume possible rather than failing outright.
            $resumeDirectory = $directory
        }

        # The resume list comes from Agency and holds Copilot sessions, so a resume
        # always goes through Agency whichever agent is selected for new sessions.
        $chosenLauncher = 'agency'
        $short = $resumeSession.SessionId.Substring(0, [Math]::Min(8, $resumeSession.SessionId.Length))
        Write-DaemonLog -Message "resume requested for $short ($resumeDirectory)$(if ($agencyProfile) { " profile '$agencyProfile'" })"
        Set-CopilotMqttNewSessionResult -Text "Resuming $resumeLabel..." -Headers $Headers

        $launchedAt = [DateTimeOffset]::Now
        $launch = Start-BridgeCopilotSession -WorkingDirectory $resumeDirectory -Prompt $prompt `
            -AgencyProfile $agencyProfile -SessionId ([string]$resumeSession.SessionId) -Launcher $chosenLauncher -Resume
    }
    else {
        $agentName = Get-BridgeLauncherLabel -Launcher $chosenLauncher
        Write-DaemonLog -Message "new $agentName session requested in '$label' ($directory)$(if ($agencyProfile) { " profile '$agencyProfile'" })$(if ($prompt) { " with prompt: $prompt" })"
        Set-CopilotMqttNewSessionResult -Headers $Headers `
            -Text "Starting $agentName in $label$(if ($agencyProfile) { " ($agencyProfile)" })..."

        $launchedAt = [DateTimeOffset]::Now
        $launch = Start-BridgeCopilotSession -WorkingDirectory $directory -Prompt $prompt `
            -AgencyProfile $agencyProfile -Launcher $chosenLauncher
    }

    if (-not $launch.Launched) {
        Write-DaemonLog -Message "new session launch failed: $($launch.Detail)"
        Set-CopilotMqttNewSessionResult -Text "Launch failed: $($launch.Detail)" -Headers $Headers
        return
    }

    Write-DaemonLog -Message "new session launched: $($launch.Detail) (session $(if ($launch.SessionId) { $launch.SessionId } else { 'id chosen by the agent' }))"

    # Remember the process the bridge started, so End session can close the console
    # window it opened rather than leaving an empty terminal behind. Codex picks its
    # own id, so there is nothing to key it by.
    if ($launch.ProcessId -gt 0 -and $launch.SessionId) {
        $script:DaemonLaunchedPids[[string]$launch.SessionId] = [int]$launch.ProcessId
    }

    $verb = if ($null -ne $resumeSession) { 'Resumed' } else { 'Started' }
    $where = if ($null -ne $resumeSession) {
        if ($agencyProfile) { "$resumeLabel ($agencyProfile)" } else { [string]$resumeLabel }
    }
    elseif ($agencyProfile) { "$label ($agencyProfile)" }
    else { $label }

    # The process id only proves something started; the session registering proves
    # it got far enough to be adopted. That is followed up on each pass of the loop
    # (Update-DaemonPendingLaunch) rather than waited for here: waiting stalled the
    # whole daemon - replies, streaming, everything - for up to 25 seconds per launch.
    $script:DaemonPendingLaunch = [pscustomobject]@{
        SessionId      = [string]$launch.SessionId
        ProcessId      = [int]$launch.ProcessId
        Launcher       = $chosenLauncher
        Label          = [string]$where
        Verb           = $verb
        Since          = $launchedAt
        LastCheck      = [DateTimeOffset]::MinValue
        TrustAskedAt   = $null
        TrustConfirmed = $false
        TrustAnswers   = 0
    }

    # A launch changes what is resumable - the session just started is now live, and
    # a resumed one has to leave the list - so the cache is expired rather than left
    # to age out, and the selector re-primed to "New session" on the next reconcile.
    $script:DaemonResumeCacheAt = [DateTimeOffset]::MinValue
    $script:DaemonNewSessionSignature = ''

    # Clear the prompt box so the next launch starts from a blank field instead of
    # silently reusing the previous prompt.
    if ($prompt) {
        try {
            Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers -Data @{
                entity_id = $script:DaemonEntity.NewPrompt
                value     = $script:DaemonConfig.ReplyBlankValue
            }
        }
        catch {
            Write-DaemonLog -Message "could not clear the new-session prompt: $($_.Exception.Message)"
        }
    }
}

function Invoke-DaemonLegacyCleanup {
    <#
        Sweeps the entities published under the pre-rename ids, once.

        Two things have to happen together, which is why they live in one function.
        The old retained discovery configs are cleared, and the live sessions are
        dropped from persisted state.

        The second is not optional. Clearing a live session's topics deletes its
        entities, but the state file still records it as published, and
        Sync-DaemonSessions only publishes sessions it has never seen - so the
        session would be left with the old entities gone and no new ones created.
        Dropping the entry makes the next reconcile treat it as new. Nothing is
        re-streamed, because that path starts the offset at the transcript's current
        length.

        Returns the number of topics cleared, or -1 when the sweep has already run.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$Live,
        [Parameter(Mandatory)][hashtable]$State
    )

    if (Test-Path -LiteralPath $script:DaemonConfig.LegacyCleanupMarker) { return -1 }

    $cleared = Clear-CopilotLegacyMqttEntities -Headers $Headers -SessionIds @($Live.Keys)

    $readopted = 0
    foreach ($sessionId in @($Live.Keys)) {
        if ($State.ContainsKey($sessionId)) { [void]$State.Remove($sessionId); $readopted++ }
    }

    [System.IO.File]::WriteAllText(
        $script:DaemonConfig.LegacyCleanupMarker,
        (@{ at = [DateTimeOffset]::Now.ToString('o'); cleared = $cleared } | ConvertTo-Json -Compress))
    Write-DaemonLog -Message "legacy entity cleanup: cleared $cleared retained topic(s), re-publishing $readopted live session(s)"

    $cleared
}

function Invoke-DaemonUnscopedEntityCleanup {
    <#
        Withdraws the bridge-level entities from before they were scoped to a machine,
        once.

        An upgraded install has retained discovery configs under a single fixed
        `agent_bridge` node - the update entity, the install button, the launch
        controls and the session counter. The machine-scoped ones are published
        alongside them, so without this sweep Home Assistant shows two of everything,
        and the old launch button is the worse half: no daemon watches it any more, so
        pressing it silently does nothing.

        Returns the number of topics cleared, or -1 when the sweep has already run.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    if (Test-Path -LiteralPath $script:DaemonConfig.UnscopedCleanupMarker) { return -1 }

    $cleared = Remove-CopilotMqttMachineEntities -Legacy -Headers $Headers

    [System.IO.File]::WriteAllText(
        $script:DaemonConfig.UnscopedCleanupMarker,
        (@{ at = [DateTimeOffset]::Now.ToString('o'); cleared = $cleared } | ConvertTo-Json -Compress))
    Write-DaemonLog -Message "unscoped entity cleanup: cleared $cleared retained topic(s)"

    $cleared
}

function Update-DaemonSessionActivity {
    <#
        Streams one session's new transcript activity to Home Assistant.

        Shared by the full reconcile and the fast lane (Invoke-DaemonFastActivity),
        which calls it the moment a transcript grows, so both publish exactly the same
        way. Everything it changes lives on the session's own state entry.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$Headers,
        [bool]$VerboseOn = $false
    )

    # Names the body below has always used.
    $id = $Id; $entry = $Entry; $session = $Session; $verbose = $VerboseOn
    $entryKind = if ($entry.PSObject.Properties.Name -contains 'Kind' -and $entry.Kind) { [string]$entry.Kind } else { 'copilot' }

    # Claude's hooks set the status directly (idle at Stop, waiting at a
    # notification, working at a new prompt). Adopt it here before reading the
    # transcript, or this loop keeps believing its own stale copy and never
    # republishes 'working' when the session carries on.
    $hookStatusAt = $null
    if ($entryKind -eq 'claude') {
        $hookStatusAt = Sync-DaemonHookStatus -Entry $entry -Session $session -SessionId $id -Headers $Headers
    }

    $append = Read-BridgeTranscriptAppend -Path $session.Transcript -Offset ([long]$entry.Offset) -Kind $entryKind
    $entry.Offset = $append.Offset
    if ($append.Lines.Count -eq 0) { return }

    $activity = Get-BridgeActivity -Lines $append.Lines -VerboseMode $verbose -Kind $entryKind

    # Work written before the hook that stopped the turn is that turn's tail, not
    # a resumption; only activity newer than the hook may flip it back to working.
    $staleTail = $false
    if ($null -ne $hookStatusAt -and [string]$entry.Status -in @('idle', 'waiting') -and
        $activity.PSObject.Properties['LastActivityAt']) {
        $staleTail = ($null -eq $activity.LastActivityAt) -or ($activity.LastActivityAt -le $hookStatusAt)
    }

    if (-not $staleTail -and -not [string]::IsNullOrWhiteSpace($activity.Status) -and
        $activity.Status -ne [string]$entry.Status) {
        $entry.Status = $activity.Status
        try {
            Set-CopilotMqttStatus -SessionId $id -Status $activity.Status -Headers $Headers -Attributes @{
                session = $entry.Name
                machine = $entry.Machine
                process_id = $session.ProcessId
                updated = [DateTimeOffset]::Now.ToString('o')
            }
        }
        catch {
            Write-DaemonLog -Message "status publish failed for $id : $($_.Exception.Message)"
        }
    }

    if ([string]::IsNullOrWhiteSpace($activity.Summary) -and
        [string]::IsNullOrWhiteSpace($activity.Reasoning)) {
        return
    }

    # Persist the latest reasoning in session state so it stays on the card across
    # batches that carry no reasoning (a tool call, a plain message), and so the
    # verbose toggle can show it instantly. Capture is unconditional; only display
    # is gated on verbose (below).
    #
    # A batch that starts a new turn drops what was carried from the last one;
    # otherwise the card shows the previous turn's reasoning under the new status.
    $turnStarted = [bool]($activity.PSObject.Properties['TurnStarted'] -and $activity.TurnStarted)
    $lastReasoning = if (-not $turnStarted -and $entry.PSObject.Properties['LastReasoning']) {
        [string]$entry.LastReasoning
    }
    else { '' }
    if (-not [string]::IsNullOrWhiteSpace($activity.Reasoning)) {
        $lastReasoning = $activity.Reasoning
    }
    if ($entry.PSObject.Properties['LastReasoning']) {
        $entry.LastReasoning = $lastReasoning
    }
    else {
        $entry | Add-Member -NotePropertyName LastReasoning -NotePropertyValue $lastReasoning -Force
    }

    # Persist the full text of the last substantive response, likewise, so the
    # card can render the whole answer across later tool-call batches that carry
    # no new content.
    $lastResponse = if ($entry.PSObject.Properties['LastResponse']) {
        [string]$entry.LastResponse
    }
    else { '' }
    if (-not [string]::IsNullOrWhiteSpace($activity.Response)) {
        $lastResponse = $activity.Response
    }
    if ($entry.PSObject.Properties['LastResponse']) {
        $entry.LastResponse = $lastResponse
    }
    else {
        $entry | Add-Member -NotePropertyName LastResponse -NotePropertyValue $lastResponse -Force
    }

    $summary = $activity.Summary
    if ([string]::IsNullOrWhiteSpace($summary)) { $summary = 'Thinking' }
    # Remember the summary so a verbose-toggle refresh can republish the card
    # without needing fresh transcript activity.
    if ($entry.PSObject.Properties['LastSummary']) {
        $entry.LastSummary = $summary
    }
    else {
        $entry | Add-Member -NotePropertyName LastSummary -NotePropertyValue $summary -Force
    }

    $detail = @{
        session = $entry.Name
        machine = $entry.Machine
        verbose = $verbose
        updated = [DateTimeOffset]::Now.ToString('o')
    }
    # The history is a rolling trail across batches, not just this batch: the
    # daemon reads the transcript every few seconds, so a single batch usually
    # holds one or two steps and the trail would otherwise never show more.
    $carried = @()
    if (-not $turnStarted -and $entry.PSObject.Properties['LastHistory'] -and $entry.LastHistory) {
        $carried = @($entry.LastHistory | ForEach-Object { [string]$_ })
    }
    $detail['history'] = @(@($carried) + @($activity.History | ForEach-Object { [string]$_ }) |
        Select-Object -Last $script:DaemonConfig.ActivityHistory)
    # Persist the history alongside the summary and reasoning, so a daemon restart
    # can restore the whole card rather than blanking it.
    if ($entry.PSObject.Properties['LastHistory']) { $entry.LastHistory = $detail.history }
    else { $entry | Add-Member -NotePropertyName LastHistory -NotePropertyValue $detail.history -Force }
    # The newest line of either kind, for Claude (see Add-DaemonCardText).
    if ($entryKind -eq 'claude') {
        $lastMessage = if (-not $turnStarted -and $entry.PSObject.Properties['LastMessage']) { [string]$entry.LastMessage } else { '' }
        $lastIsThinking = if (-not $turnStarted -and $entry.PSObject.Properties['LastMessageIsThinking']) { [bool]$entry.LastMessageIsThinking } else { $false }
        if ($activity.PSObject.Properties['Latest'] -and -not [string]::IsNullOrWhiteSpace([string]$activity.Latest)) {
            $lastMessage = [string]$activity.Latest
            $lastIsThinking = [bool]$activity.LatestIsThinking
        }
        Set-DaemonSessionProperty -Entry $entry -Name 'LastMessage' -Value $lastMessage
        Set-DaemonSessionProperty -Entry $entry -Name 'LastMessageIsThinking' -Value $lastIsThinking
    }

    Add-DaemonCardText -Entry $entry -Detail $detail -VerboseOn $verbose

    try {
        Set-CopilotMqttActivity -SessionId $id -Summary $summary -Detail $detail -Headers $Headers
    }
    catch {
        Write-DaemonLog -Message "activity publish failed for $id : $($_.Exception.Message)"
    }
}

function Add-DaemonCardText {
    <#
        Puts the card's main text (and, where it applies, the reasoning expander) into
        an activity update, from a session's remembered state.

        Claude Code shows its thinking summaries and its replies in one stream, in the
        order they happen. Showing the last reply as the response and the last thought
        in an expander below it put an older line above a newer one, so the card read as
        out of order against the terminal. With Detailed activity on, a Claude card
        instead shows the newest line of either kind, and `response_kind` says whether
        it is reasoning. Other agents keep the separate expander.

        Shared by the live update, the verbose toggle and the restart restore, so all
        three lay the card out the same way.
    #>
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][hashtable]$Detail,
        [bool]$VerboseOn
    )

    $kind = if ($Entry.PSObject.Properties.Name -contains 'Kind' -and $Entry.Kind) { [string]$Entry.Kind } else { 'copilot' }
    $shown = if ($Entry.PSObject.Properties['LastResponse']) { [string]$Entry.LastResponse } else { '' }
    $shownKind = 'text'

    if ($kind -eq 'claude') {
        $lastMessage = if ($Entry.PSObject.Properties['LastMessage']) { [string]$Entry.LastMessage } else { '' }
        if ($VerboseOn -and -not [string]::IsNullOrWhiteSpace($lastMessage)) {
            $shown = $lastMessage
            if ($Entry.PSObject.Properties['LastMessageIsThinking'] -and [bool]$Entry.LastMessageIsThinking) { $shownKind = 'reasoning' }
        }
    }

    # The card shows the text in full; nothing is split off into a "show more".
    if (-not [string]::IsNullOrWhiteSpace($shown)) {
        if ($shown.Length -gt $script:DaemonConfig.ResponseMaxChars) {
            $shown = $shown.Substring(0, $script:DaemonConfig.ResponseMaxChars).TrimEnd() +
                "`n`n_(truncated - see terminal)_"
        }
        $Detail['response'] = $shown
        $Detail['response_kind'] = $shownKind
    }

    # Claude's reasoning is already inline, in order; repeating it below would put it
    # out of order again.
    $reasoning = if ($Entry.PSObject.Properties['LastReasoning']) { [string]$Entry.LastReasoning } else { '' }
    if ($VerboseOn -and $kind -ne 'claude' -and -not [string]::IsNullOrWhiteSpace($reasoning)) {
        if ($reasoning.Length -gt $script:DaemonConfig.ReasoningMaxChars) {
            $reasoning = $reasoning.Substring(0, $script:DaemonConfig.ReasoningMaxChars).TrimEnd() + '…'
        }
        $Detail['reasoning'] = $reasoning
    }
}

function Get-DaemonClientAdapterInstalled {
    <# Whether a client's bridge adapter is in place, from the files its installer leaves. #>
    param([Parameter(Mandatory)][ValidateSet('claude', 'codex')][string]$Client)

    switch ($Client) {
        'claude' { return Test-Path -LiteralPath (Join-Path $HOME '.claude\ha-bridge\claude-session.ps1') }
        'codex'  { return Test-Path -LiteralPath (Join-Path $HOME '.agent-ha-bridge\codex-bridge\plugins\agent-ha-bridge\hooks\codex-session.ps1') }
    }
}

function Add-DaemonConfiguredClient {
    <#
        Adds a client to `clients` in the bridge config, so later installs and updates
        keep its adapter current. The file is re-read rather than rewritten from memory,
        so nothing changed on disk since the daemon started is lost.
    #>
    param([Parameter(Mandatory)][string]$Client)

    $path = Join-Path $HOME '.agent-ha-bridge\config.json'
    if (-not (Test-Path -LiteralPath $path)) { return }
    $config = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $clients = @()
    if ($config.PSObject.Properties['clients']) { $clients = @($config.clients | ForEach-Object { [string]$_ }) }
    if ($clients -contains $Client) { return }
    $clients += $Client
    if ($config.PSObject.Properties['clients']) { $config.clients = @($clients) }
    else { $config | Add-Member -NotePropertyName 'clients' -NotePropertyValue @($clients) -Force }
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding UTF8
    $script:BridgeUserConfig = $config
}

function Sync-DaemonClients {
    <#
        Sets up the bridge for a coding agent installed after the bridge was.

        Launching an agent from the dashboard only needs the agent on PATH, but showing
        its sessions, streaming them and answering them needs its adapter - hooks the
        agent runs - which used to mean re-running the installer by hand. Now an agent
        that is installed but has no adapter gets one: its installer, shipped with the
        bridge, runs in the background; the agent joins `clients` so updates keep it
        current; the launch note says what happened; and the daemon restarts to load
        the adapter.

        Codex additionally asks, inside Codex, for its hooks to be trusted once. That is
        Codex's own safety check and is left to the user; the note says so.

        Off with `autoConfigureClients: false`. Tried once per client per daemon run,
        so a failing installer is not retried in a loop.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    if (-not [bool](Get-BridgeSetting 'autoConfigureClients' $true)) { return }

    foreach ($client in @('claude', 'codex')) {
        $job = $script:DaemonClientSetup[$client]

        if ($null -ne $job) {
            if ($job.Done -or -not $job.Process.HasExited) { continue }
            $job.Done = $true
            $label = Get-BridgeLauncherLabel -Launcher $client
            if ($job.Process.ExitCode -eq 0 -and (Get-DaemonClientAdapterInstalled -Client $client)) {
                try { Add-DaemonConfiguredClient -Client $client } catch { Write-DaemonLog -Message "could not record $client in the config: $($_.Exception.Message)" }
                Write-DaemonLog -Message "set up the $label adapter (log: $($job.Log)); restarting to load it"
                $note = "$label found and set up for the dashboard."
                if ($client -eq 'codex') { $note += ' Open Codex once and approve the agent-ha-bridge hooks so its sessions show here.' }
                else { $note += ' Restart any running sessions so they pick it up.' }
                try { Set-CopilotMqttNewSessionResult -Headers $Headers -Text $note } catch { }
                $script:DaemonRestartRequested = "load the $label adapter"
            }
            else {
                Write-DaemonLog -Message "setting up the $label adapter failed (exit $($job.Process.ExitCode)); see $($job.Log)"
                try { Set-CopilotMqttNewSessionResult -Headers $Headers -Text "$label was found but setting it up failed - run agent-ha-bridge configure." } catch { }
            }
            continue
        }

        if (-not (Get-BridgeLauncherPath -Launcher $client)) { continue }
        if (Get-DaemonClientAdapterInstalled -Client $client) {
            # Adapter present but not listed - installed by hand - so just record it.
            $listed = @(Get-BridgeSetting 'clients' @()) -contains $client
            if (-not $listed) { try { Add-DaemonConfiguredClient -Client $client } catch { } }
            continue
        }

        $installer = Join-Path $HOME ".agent-ha-bridge\installer\$client\install-$client.ps1"
        if (-not (Test-Path -LiteralPath $installer)) { continue }

        $log = Join-Path $env:TEMP "agent-bridge-setup-$client.log"
        try {
            $process = Start-Process -FilePath 'pwsh' `
                -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$installer`"" `
                -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err" -ErrorAction Stop
            $script:DaemonClientSetup[$client] = [pscustomobject]@{ Process = $process; Log = $log; Done = $false }
            Write-DaemonLog -Message "$(Get-BridgeLauncherLabel -Launcher $client) is installed but has no bridge adapter; setting it up (pid $($process.Id))"
        }
        catch {
            $script:DaemonClientSetup[$client] = [pscustomobject]@{ Process = $null; Log = $log; Done = $true }
            Write-DaemonLog -Message "could not start the $client adapter installer: $($_.Exception.Message)"
        }
    }
}

function Update-DaemonPendingLaunch {
    <#
        Follows a session launched from the dashboard until it registers, a pass at a
        time, so the daemon never stalls waiting on it.

        Claude may stop at "Do you trust this folder?" before it registers - and before
        its SessionStart hook runs - where nobody at the dashboard can see it. Whether
        it will ask cannot be predicted reliably from its config, so the session's
        screen is read instead. When the question shows, the launch note asks for a
        second press of Launch within two minutes; that press sets TrustConfirmed, and
        the answer is sent from whatever the screen shows then (see
        Send-BridgeTrustAnswer). Checked at most every 700 ms.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    $p = $script:DaemonPendingLaunch
    if ($null -eq $p) { return }
    $now = [DateTimeOffset]::Now
    if (($now - $p.LastCheck).TotalMilliseconds -lt 700) { return }
    $p.LastCheck = $now
    $agent = Get-BridgeLauncherLabel -Launcher $p.Launcher
    $finish = { param([string]$Note, [string]$Log)
        $script:DaemonPendingLaunch = $null
        Write-DaemonLog -Message $Log
        try { Set-CopilotMqttNewSessionResult -Headers $Headers -Text $Note } catch { }
    }

    if (Test-BridgeSessionRegistered -SessionId $p.SessionId -Launcher $p.Launcher -Since $p.Since) {
        # The session's own card is the confirmation, so the note is cleared, and a
        # reconcile is asked for now so the card appears without waiting the interval.
        $script:DaemonReconcileNow = $true
        & $finish '' ("$($p.Verb) $agent in $($p.Label); registered after {0:N1} s" -f ($now - $p.Since).TotalSeconds)
        return
    }

    if ($p.ProcessId -gt 0 -and $null -eq (Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue)) {
        & $finish "$agent in $($p.Label) closed before it started." "launched $agent (pid $($p.ProcessId)) exited before registering"
        return
    }

    if ($p.Launcher -eq 'claude' -and $p.ProcessId -gt 0) {
        $selection = Read-BridgeTrustPrompt -ProcessId $p.ProcessId
        if ($selection) {
            if ($p.TrustConfirmed) {
                if ($p.TrustAnswers -lt 3) {
                    $p.TrustAnswers++
                    $sent = Send-BridgeTrustAnswer -ProcessId $p.ProcessId -Selection $selection
                    Write-DaemonLog -Message "answered Claude's trust question for $($p.Label) (highlight was '$selection'): $sent"
                }
            }
            elseif ($null -eq $p.TrustAskedAt) {
                $p.TrustAskedAt = $now
                Write-DaemonLog -Message "Claude in $($p.Label) is asking whether to trust the folder; waiting for a second press"
                Set-CopilotMqttNewSessionResult -Headers $Headers `
                    -Text "Claude is asking whether to trust $($p.Label). Press Launch again within 2 minutes to trust it and start."
            }
            elseif (($now - $p.TrustAskedAt).TotalSeconds -gt 120) {
                & $finish "Claude is still asking whether to trust $($p.Label) - answer it in its window." `
                    "trust confirmation for $($p.Label) expired; left for the window"
            }
            return
        }
    }

    if (($now - $p.Since).TotalSeconds -gt 90) {
        & $finish "$agent started in $($p.Label) (pid $($p.ProcessId)) but has not registered - check its window." `
            "launched $agent (pid $($p.ProcessId)) did not register within 90 s"
    }
}

function Invoke-DaemonFastActivity {
    <#
        The fast lane: publishes new transcript activity within one wait tick.

        The full reconcile runs every 15 seconds and makes dozens of Home Assistant
        calls, so streaming only from there left reasoning up to 15 seconds behind the
        terminal. This runs between reconciles, from inside the Home Assistant wait
        (every 100 ms), and costs a file-size check per live session when nothing has
        changed. It works from the live set the last reconcile found; sessions that
        appear or exit are still picked up there.

        For Claude it also watches the hook registration, so a status a hook just set
        (a new prompt's 'working', say) is adopted within a tick rather than a reconcile.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State
    )

    # A session launched from the dashboard is followed up here too, so its
    # registration - or its trust question - is noticed within a second.
    try { Update-DaemonPendingLaunch -Headers $Headers } catch { }

    $live = $script:DaemonLive
    if ($null -eq $live -or $live.Count -eq 0) { return }

    foreach ($id in @($State.Keys)) {
        $entry = $State[$id]
        $session = $live[$id]
        if ($null -eq $entry -or $null -eq $session) { continue }

        $kind = if ($entry.PSObject.Properties.Name -contains 'Kind' -and $entry.Kind) { [string]$entry.Kind } else { 'copilot' }
        # Codex reports its activity from its hooks, sooner than a transcript could.
        if ($kind -eq 'codex') { continue }

        $changed = $false

        if ($kind -eq 'claude' -and $script:ClaudeAdapterLoaded) {
            $registration = Join-Path $env:TEMP "agent-bridge-claude\$(Get-ClaudeSafeSessionKey -SessionId $id).json"
            $stamp = [IO.File]::GetLastWriteTimeUtc($registration).Ticks
            if (-not $script:DaemonRegistrationStamps.ContainsKey($id) -or $script:DaemonRegistrationStamps[$id] -ne $stamp) {
                $script:DaemonRegistrationStamps[$id] = $stamp
                try {
                    $fresh = Get-Content -LiteralPath $registration -Raw | ConvertFrom-Json
                    foreach ($field in @('HookStatus', 'HookStatusAt')) {
                        if ($fresh.PSObject.Properties[$field]) {
                            $session | Add-Member -NotePropertyName $field -NotePropertyValue ([string]$fresh.$field) -Force
                        }
                    }
                    $changed = $true
                }
                catch { }
            }
        }

        $transcript = [string]$session.Transcript
        if (-not $changed) {
            if ([string]::IsNullOrWhiteSpace($transcript)) { continue }
            $length = 0L
            try { $length = [IO.FileInfo]::new($transcript).Length } catch { continue }
            if ($length -eq [long]$entry.Offset) { continue }
        }

        Update-DaemonSessionActivity -Id $id -Entry $entry -Session $session -Headers $Headers -VerboseOn ([bool]$script:DaemonVerbose)
    }
}

function Sync-DaemonSessions {
    <#
        Brings the published Home Assistant entities in line with the live sessions,
        and streams any new transcript activity.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State
    )

    $live = Get-LiveBridgeSessions
    $verbose = Test-VerboseStreaming -Headers $Headers
    # The fast lane streams between reconciles from this snapshot.
    $script:DaemonLive = $live
    $script:DaemonVerbose = $verbose

    # Note sessions that have exited, and drop them from state now, but defer removing
    # their Home Assistant entities until after the dashboard has been rebuilt without
    # them (below). Removing the entities first leaves the still-present card pointing
    # at dead entities, which renders as "Entity not found" until the rebuild catches
    # up. Rebuilding first means the card is gone before the entities are.
    $goneSessions = @()
    foreach ($known in @($State.Keys)) {
        if ($live.ContainsKey($known)) { continue }
        $goneSessions += $known
        $State.Remove($known)
    }

    foreach ($session in $live.Values) {
        $id = $session.SessionId
        $entry = $State[$id]

        if ($null -eq $entry) {
            $kind = if ($session.PSObject.Properties.Name -contains 'Kind') { [string]$session.Kind } else { 'copilot' }
            $workingDirectory = if ($session.PSObject.Properties.Name -contains 'WorkingDirectory' -and $session.WorkingDirectory) {
                [string]$session.WorkingDirectory
            } else { 'Unknown folder' }
            $display = Get-BridgeSessionDisplay -SessionId $id -Kind $kind -WorkingDirectory $workingDirectory
            $node = Get-CopilotMqttNodeId -SessionId $id

            # Only publish the entity set if it does not already exist. The ask_user
            # router publishes a session's entities on demand and then arms its
            # decision selector; a blind re-publish here would reset that selector to
            # Idle and blank a live question. When the entities already exist, adopt
            # the session into state without touching them.
            $alreadyPublished = $false
            try {
                $probe = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
                $alreadyPublished = ($null -ne $probe -and [string]$probe.state -notin @('unavailable', ''))
            }
            catch {
                $alreadyPublished = $false
            }

            if (-not $alreadyPublished) {
                try {
                    Publish-CopilotMqttSession -SessionId $id -SessionName $display.Name `
                        -Machine $display.Machine -Headers $Headers | Out-Null
                    # Discovery needs a moment to register before the ids can be forced.
                    Start-Sleep -Milliseconds 1500
                    [void](Set-CopilotMqttEntityIds -SessionId $id)
                    Write-DaemonLog -Message "published session $($id.Substring(0,8)) as '$($display.Name)'"
                }
                catch {
                    Write-DaemonLog -Message "publish failed for $id : $($_.Exception.Message)"
                    continue
                }
            }
            else {
                Write-DaemonLog -Message "adopted existing session $($id.Substring(0,8)) as '$($display.Name)'"
            }

            # Ensure the per-field dropdown slots and the Submit button exist for every
            # session, including adopted ones and sessions published before either was
            # introduced. The dashboard's cards reference them unconditionally, so a
            # missing entity renders an "Entity not found" box on the session card.
            try {
                $probeField = $null
                try { $probeField = Get-HomeAssistantState -EntityId "select.${node}_f1" -Headers $Headers }
                catch { $probeField = $null }
                if ($null -eq $probeField) {
                    Clear-CopilotMqttDecisionFields -SessionId $id -SessionName $display.Name `
                        -Machine $display.Machine -Headers $Headers
                    Write-DaemonLog -Message "provisioned field slots for $($id.Substring(0,8))"
                }

                $probeSubmit = $null
                try { $probeSubmit = Get-HomeAssistantState -EntityId "button.${node}_submit" -Headers $Headers }
                catch { $probeSubmit = $null }
                if ($null -eq $probeSubmit) {
                    Publish-CopilotMqttSubmitButton -SessionId $id -SessionName $display.Name `
                        -Machine $display.Machine -Headers $Headers
                    Write-DaemonLog -Message "provisioned submit button for $($id.Substring(0,8))"
                }
            }
            catch {
                Write-DaemonLog -Message "provisioning failed for $id : $($_.Exception.Message)"
            }

            $sessionStatus = if ($session.PSObject.Properties.Name -contains 'Status') { [string]$session.Status } else { '' }
            $initialStatus = if (Test-BridgeSessionWorking -SessionId $id -Kind $kind -Transcript $session.Transcript -Status $sessionStatus) { 'working' } else { 'idle' }
            $initialActivity = if ($session.PSObject.Properties.Name -contains 'Activity' -and $session.Activity) {
                # Codex hooks record the real activity - the prompt, the running tool,
                # the reply - so a placeholder would be a downgrade.
                [string]$session.Activity
            } elseif ($initialStatus -eq 'working') { 'Working' } else { 'Idle' }
            try {
                Set-CopilotMqttStatus -SessionId $id -Status $initialStatus -Headers $Headers -Attributes @{
                    session = $display.Name
                    machine = $display.Machine
                    process_id = $session.ProcessId
                    updated = [DateTimeOffset]::Now.ToString('o')
                }
                Set-CopilotMqttActivity -SessionId $id -Summary $initialActivity `
                    -Detail @{ session = $display.Name; machine = $display.Machine } -Headers $Headers
                    # Prime the reply box to empty so the card shows a blank field rather
                    # than 'unknown' before the box has ever been used.
                    Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers `
                        -Data @{ entity_id = "text.${node}_reply"; value = $script:DaemonConfig.ReplyBlankValue }
            }
            catch {
                Write-DaemonLog -Message "initial status publish failed for $id : $($_.Exception.Message)"
            }

            $entry = [pscustomobject]@{
                # A session with no transcript yet starts at offset 0, so the first
                # bytes it writes are picked up rather than skipped.
                Offset = if ([IO.File]::Exists($session.Transcript)) {
                    (Get-Item -LiteralPath $session.Transcript).Length
                } else { 0 }
                Name = $display.Name
                Machine = $display.Machine
                Status = $initialStatus
                Kind = $kind
            }
            $State[$id] = $entry
            continue
        }

        $entryKind = if ($entry.PSObject.Properties.Name -contains 'Kind' -and $entry.Kind) { [string]$entry.Kind } else { 'copilot' }
        # Codex publishes its own status, activity and response from its hooks, which
        # report them sooner than a transcript tail could. The rollout is read for one
        # thing only - reasoning - and only while verbose streaming is on.
        if ($entryKind -eq 'codex') {
            if (-not $verbose) { continue }
            $append = Read-CodexTranscriptAppend -Path ([string]$session.Transcript) `
                -Offset ([long]$entry.Offset) -MaxTailBytes $script:DaemonConfig.MaxTailBytes
            $entry.Offset = $append.Offset
            if ($append.Lines.Count -eq 0) { continue }

            $reasoning = Get-CodexReasoningFromTranscript -Lines $append.Lines
            if (-not [string]::IsNullOrWhiteSpace($reasoning)) {
                $capped = $reasoning
                if ($capped.Length -gt $script:DaemonConfig.ReasoningMaxChars) {
                    $capped = $capped.Substring(0, $script:DaemonConfig.ReasoningMaxChars).TrimEnd() + '…'
                }
                try {
                    # The activity label itself still comes from the hooks; this only
                    # adds the reasoning attribute the card's expander reads.
                    Set-CopilotMqttActivity -SessionId $id `
                        -Summary $(if ($session.PSObject.Properties.Name -contains 'Activity' -and $session.Activity) { [string]$session.Activity } else { 'Working' }) `
                        -Detail @{
                            session   = $entry.Name
                            machine   = $entry.Machine
                            reasoning = $capped
                        } -Headers $Headers
                }
                catch {
                    Write-DaemonLog -Message "codex reasoning publish failed for $id : $($_.Exception.Message)"
                }
            }
            continue
        }

        # A session published before it wrote its workspace file only had a generic
        # name to go on. Names are otherwise resolved once, so re-resolve while the
        # stored one is still the fallback; the real task name usually appears within
        # a reconcile or two of the session starting.
        # Re-resolve a session's name when the stored one is stale. Two cases: a
        # session published before it wrote its workspace file still carries the id
        # fallback, and a session published by an older build carries no harness
        # prefix at all. Both self-heal on the next reconcile rather than needing the
        # state file to be cleared by hand.
        $needsName = ($entryKind -eq 'copilot' -and [string]$entry.Name -notmatch '^Copilot: ') -or
                     ([string]$entry.Name -match '^Copilot: [0-9a-f]{8}$')
        if ($needsName) {
            $workingDirectory = if ($session.PSObject.Properties.Name -contains 'WorkingDirectory' -and $session.WorkingDirectory) {
                [string]$session.WorkingDirectory
            } else { 'Unknown folder' }
            $refreshed = Get-BridgeSessionDisplay -SessionId $id -Kind $entryKind -WorkingDirectory $workingDirectory
            if ([string]$refreshed.Name -ne [string]$entry.Name) {
                $entry.Name = $refreshed.Name
                try {
                    Set-CopilotMqttStatus -SessionId $id -Status ([string]$entry.Status) -Headers $Headers -Attributes @{
                        session = $entry.Name
                        machine = $entry.Machine
                        process_id = $session.ProcessId
                        updated = [DateTimeOffset]::Now.ToString('o')
                    }
                }
                catch { }
                Write-DaemonLog -Message "renamed $($id.Substring(0,8)) to '$($entry.Name)'"
            }
        }

        Update-DaemonSessionActivity -Id $id -Entry $entry -Session $session -Headers $Headers -VerboseOn $verbose
    }

    # Keep the global count sensor and the dashboard in step with the live set. The
    # dashboard is only rebuilt when the set of sessions actually changes, because a
    # rebuild replaces the whole Lovelace config and is far heavier than a state
    # publish; turn-by-turn activity rides on the per-session entities the dashboard
    # already points at.
    $descriptors = @(
        foreach ($id in ($State.Keys | Sort-Object)) {
            $entry = $State[$id]
            [pscustomobject]@{
                Node = Get-CopilotMqttNodeId -SessionId $id
                Name = $entry.Name
                Machine = $entry.Machine
                Kind = if ($entry.PSObject.Properties.Name -contains 'Kind' -and $entry.Kind) { [string]$entry.Kind } else { 'copilot' }
            }
        }
        # MCP clients join here and nowhere else. They are deliberately kept out of
        # $State and out of Get-LiveBridgeSessions: the MCP server owns those entities
        # and withdraws them itself, so a daemon that adopted them would eventually
        # "retire" a live client's entities out from under it. Rendering is the only
        # thing the daemon should do with them.
        foreach ($mcp in (Get-LiveMcpSessions -Headers $Headers).Values) {
            [pscustomobject]@{
                Node = $mcp.Node
                Name = $mcp.Name
                Machine = ''
                Kind = 'mcp'
            }
        }
    )

    # The global count sensor only needs re-publishing when the live set (names,
    # machines, nodes) changes, or periodically as a re-assert against a Home
    # Assistant restart dropping retained state. Republishing three retained messages
    # every reconcile - each stamped with a fresh 'updated' time that defeats payload
    # equality - was needless idle traffic and MQTT churn.
    #
    # It is also this machine's presence marker and the only thing other machines read
    # to learn what it is running, so the capability flags travel with it: a peer has
    # no other way to know whether to draw a profile or resume row on this machine's
    # launch card.
    $newSessionEnabled = [bool](Get-BridgeSetting 'newSession.enabled' $true)
    $installedLaunchers = @(Get-BridgeAvailableLaunchers)
    $includeProfile = $newSessionEnabled -and $installedLaunchers -contains 'agency'
    $includeResume = $newSessionEnabled -and $installedLaunchers -contains 'agency'
    $includeAgent = $newSessionEnabled -and $installedLaunchers.Count -gt 1
    $capabilities = @{
        newSession = $newSessionEnabled
        profile    = [bool]$includeProfile
        resume     = [bool]$includeResume
        agent      = [bool]$includeAgent
    }

    $globalSignature = (($descriptors | ForEach-Object { "$($_.Node)=$($_.Name)=$($_.Machine)" }) -join '|') +
        "#$($capabilities.newSession)$($capabilities.profile)$($capabilities.resume)$($capabilities.agent)"
    $globalStale = ([DateTimeOffset]::Now - $script:DaemonGlobalLastPublish).TotalSeconds -ge $script:DaemonConfig.GlobalReassertSeconds
    if ($globalSignature -ne $script:DaemonGlobalSignature -or $globalStale) {
        try {
            Publish-CopilotMqttGlobalStatus -Headers $Headers -Capabilities $capabilities -Sessions @(
                $descriptors | ForEach-Object {
                    @{ name = $_.Name; machine = $_.Machine; node = $_.Node; kind = [string]$_.Kind }
                }
            )
            $script:DaemonGlobalSignature = $globalSignature
            $script:DaemonGlobalLastPublish = [DateTimeOffset]::Now
        }
        catch {
            Write-DaemonLog -Message "global status publish failed: $($_.Exception.Message)"
        }
    }

    # Liveness, on its own short cadence. Everything above is retained so that a
    # machine which is switched off is still *known*; this is the one signal that says
    # it is actually running, so it has to keep arriving. The sensor itself is declared
    # at startup, well before this, because an unretained beat that outruns its own
    # discovery config is simply dropped.
    if (([DateTimeOffset]::Now - $script:DaemonOnlineLastPublish).TotalSeconds -ge $script:DaemonConfig.OnlineHeartbeatSeconds) {
        try {
            Publish-CopilotMqttMachineHeartbeat -Slug $script:DaemonMachineSlug -Headers $Headers
            $script:DaemonOnlineLastPublish = [DateTimeOffset]::Now
        }
        catch {
            Write-DaemonLog -Message "online heartbeat failed: $($_.Exception.Message)"
        }
    }

    # Everything every machine is running, so the single shared dashboard shows the
    # whole picture rather than only whichever machine rebuilt it last.
    #
    # Deduplicated by node because an MCP client is discovered directly by every
    # daemon *and* reported in each of their session lists, so it would otherwise
    # appear once per machine. The local descriptor wins: it is first-hand.
    $peers = @(Get-DaemonPeerMachines -Headers $Headers)
    $seenNodes = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@($descriptors | ForEach-Object { [string]$_.Node }),
        [StringComparer]::OrdinalIgnoreCase)
    $allDescriptors = @($descriptors)
    foreach ($peer in $peers) {
        # A machine that is not running has no live sessions. Its entities are retained,
        # so the ones it had when it stopped are still there and would otherwise render
        # as live cards showing whatever they last said - a session frozen mid-answer,
        # with a reply box that goes nowhere.
        if (-not $peer.Online) { continue }
        foreach ($remote in @($peer.Sessions)) {
            $node = [string]$remote.node
            if ([string]::IsNullOrWhiteSpace($node)) { continue }
            if (-not $seenNodes.Add($node)) { continue }
            $allDescriptors += [pscustomobject]@{
                Node = $node
                Name = [string]$remote.name
                Machine = $(if ([string]$remote.machine) { [string]$remote.machine } else { $peer.Machine })
                Kind = [string]$remote.kind
            }
        }
    }

    $machineCards = @(
        [pscustomobject]@{
            Slug = $script:DaemonMachineSlug
            Machine = $script:DaemonMachineName
            IncludeProfile = [bool]$includeProfile
            IncludeResume = [bool]$includeResume
            IncludeAgent = [bool]$includeAgent
            # This daemon is the one running the code, so it is online by definition -
            # and saying so here means the launch picker is never empty while its own
            # heartbeat sensor is still being created.
            Online = $true
        }
    )
    foreach ($peer in $peers) {
        $peerCaps = $peer.Capabilities
        $peerProfile = $false
        $peerResume = $false
        $peerAgent = $false
        if ($null -ne $peerCaps) {
            try { $peerProfile = [bool]$peerCaps.profile } catch { }
            try { $peerResume = [bool]$peerCaps.resume } catch { }
            try { $peerAgent = [bool]$peerCaps.agent } catch { }
        }
        $machineCards += [pscustomobject]@{
            Slug = $peer.Slug
            Machine = $peer.Machine
            IncludeProfile = $peerProfile
            IncludeResume = $peerResume
            IncludeAgent = $peerAgent
            Online = [bool]$peer.Online
        }
    }
    # Stable order, so two machines rebuilding independently generate byte-identical
    # dashboards and neither keeps overwriting the other's ordering.
    $machineCards = @($machineCards | Sort-Object -Property Slug)

    # Only machines that are actually running can start a session, so the picker lists
    # those. Every registered machine still appears in the machines card, online or
    # not, because a machine you expected to see and cannot is information too.
    $onlineNames = @($machineCards | Where-Object { $_.Online } | ForEach-Object { [string]$_.Machine })

    # The picker can end up pointing at a machine that has gone. Home Assistant sets
    # the selection to 'unknown' when the option it was on is removed, and it does so
    # asynchronously - so repairing it as part of the rebuild races that and loses.
    # The launch rows are conditional on the selection matching a machine name, so an
    # unknown selection renders a dropdown with nothing underneath it.
    #
    # Checked here on every reconcile instead, off the cached state list, so it costs
    # nothing until something actually looks wrong.
    if ($onlineNames.Count -gt 1) {
        $selectorId = "input_select.$($script:BridgeMachineSelectorId)"
        $selectorState = ''
        # Deliberately not $state: this function takes a [hashtable]$State parameter,
        # PowerShell variable names are case-insensitive, and assigning a state object
        # to a typed parameter is a hard failure - it crash-looped the daemon.
        foreach ($snapshotEntry in @($script:DaemonStatesCache)) {
            if ($null -eq $snapshotEntry) { continue }
            if ([string]$snapshotEntry.entity_id -eq $selectorId) {
                $selectorState = [string]$snapshotEntry.state
                break
            }
        }
        if ($selectorState -and $onlineNames -notcontains $selectorState) {
            try {
                # Re-reads the live state before writing, so a stale snapshot costs a
                # read rather than a needless change under whoever is looking at it.
                if (Repair-BridgeMachineSelection -EntityId $selectorId -Options $onlineNames) {
                    Write-DaemonLog -Message "machine picker was on '$selectorState', which is gone; moved it to $($onlineNames[0])"
                }
            }
            catch { }
        }
    }

    # The card header carries the session name, so a rename has to rebuild the
    # dashboard too - a signature of node ids alone would leave a renamed session
    # showing its old generic title until the set of sessions happened to change. The
    # machine list joins it for the same reason: a machine appearing, disappearing or
    # going offline changes the controls even when no session did. The served card
    # URL joins it because a card upgrade changes which cards the dashboard can use.
    $replyCardUrl = Get-BridgeServedReplyCardUrl
    $signature = (@($allDescriptors | Sort-Object -Property Node | ForEach-Object { "$($_.Node)=$($_.Name)" }) -join '|') +
        '#' + (@($machineCards | ForEach-Object { "$($_.Slug):$($_.IncludeProfile)$($_.IncludeResume)$($_.IncludeAgent):$($_.Online)" }) -join ',') +
        '#' + $replyCardUrl
    if ($signature -ne $script:DaemonDashboardSignature) {
        try {
            [void](Set-CopilotMqttGlobalEntityId)
            $selector = Initialize-BridgeMachineSelector -Machines $onlineNames
            Save-CopilotSessionDashboard -Sessions @($allDescriptors | Sort-Object -Property Node) `
                -Machines $machineCards -MachineSelector $selector `
                -ReplyCardUrl $replyCardUrl
            $script:DaemonDashboardSignature = $signature
            Write-DaemonLog -Message ("dashboard rebuilt for $($allDescriptors.Count) session(s) across " +
                "$($machineCards.Count) machine(s), $($onlineNames.Count) online")
        }
        catch {
            Write-DaemonLog -Message "dashboard rebuild failed: $($_.Exception.Message)"
        }
    }

    # Retire the previous pass's exited sessions now, and queue this pass's for the
    # next one.
    #
    # Rebuilding the dashboard first already removed their cards, but a browser holds
    # the old Lovelace config until it is pushed the new one - so tearing the entities
    # down in the same breath is exactly what made a just-ended session sit there as a
    # card full of unknowns. Waiting a pass lets the frontend catch up first, and by
    # then nothing is pointing at them.
    #
    # Only safe because the startup sweep clears orphans: a daemon that dies between
    # the queue and the removal leaves entities behind, and that sweep is what comes
    # back for them.
    $retirePlan = Update-DaemonRetireQueue -Queued $script:DaemonPendingRetire -Gone $goneSessions `
        -DashboardCurrent ($signature -eq $script:DaemonDashboardSignature)
    $script:DaemonPendingRetire = @($retirePlan.Queue)
    foreach ($known in @($retirePlan.Retire)) {
        try {
            Remove-CopilotMqttSession -SessionId $known -Headers $Headers
            Remove-CopilotDecisionMarker -SessionId $known
            Write-DaemonLog -Message "retired session $($known.Substring(0, [Math]::Min(8, $known.Length)))"
        }
        catch {
            Write-DaemonLog -Message "retire failed for $known : $($_.Exception.Message)"
        }
    }
}

function Update-DaemonRetireQueue {
    <#
        Decides which exited sessions may have their entities removed now.

        Removal trails the dashboard rebuild by one pass. The rebuild takes their cards
        away, but a browser keeps rendering the config it already has until Home
        Assistant pushes the new one, so removing the entities immediately is what left
        a just-ended session on screen as a card full of unknowns.

        When the rebuild did not land, nothing is retired and everything is carried
        forward: their cards may still be on screen, and pulling the entities out from
        under a live card is the very thing this ordering exists to prevent.
    #>
    param(
        [AllowEmptyCollection()][AllowNull()][string[]]$Queued,
        [AllowEmptyCollection()][AllowNull()][string[]]$Gone,
        [bool]$DashboardCurrent
    )

    if (-not $DashboardCurrent) {
        return [pscustomobject]@{
            Retire = @()
            Queue = @(@($Queued) + @($Gone) | Where-Object { $_ } | Select-Object -Unique)
        }
    }
    [pscustomobject]@{
        Retire = @(@($Queued) | Where-Object { $_ })
        Queue = @(@($Gone) | Where-Object { $_ } | Select-Object -Unique)
    }
}

function Update-SessionsForVerbose {
    <#
        Immediately republishes every session's activity to show or hide its reasoning
        the instant the Detailed activity toggle changes, without waiting for the session to
        produce fresh transcript activity. Reasoning is kept in state regardless of the
        toggle, so turning verbose on re-reveals the last captured reasoning at once and
        turning it off hides it at once.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][bool]$VerboseOn
    )

    foreach ($id in @($State.Keys)) {
        $entry = $State[$id]
        $summary = if ($entry.PSObject.Properties['LastSummary'] -and
            -not [string]::IsNullOrWhiteSpace($entry.LastSummary)) {
            [string]$entry.LastSummary
        }
        elseif ([string]$entry.Status -eq 'working') { 'Working' }
        else { 'Idle' }

        $detail = @{
            session = $entry.Name
            machine = $entry.Machine
            verbose = $VerboseOn
            updated = [DateTimeOffset]::Now.ToString('o')
        }
        if ($entry.PSObject.Properties['LastHistory'] -and $entry.LastHistory) {
            $detail['history'] = @($entry.LastHistory)
        }
        Add-DaemonCardText -Entry $entry -Detail $detail -VerboseOn $VerboseOn

        try {
            Set-CopilotMqttActivity -SessionId $id -Summary $summary -Detail $detail -Headers $Headers
        }
        catch {
            Write-DaemonLog -Message "verbose refresh failed for $id : $($_.Exception.Message)"
        }
    }
}

function Invoke-PendingCodexApprovals {
    <#
        Delivers a dashboard answer into a Codex approval prompt.

        Codex runs its PermissionRequest hook before showing its own approval UI, and
        a hook that writes nothing to stdout returns "no decision", so the terminal
        prompt appears as usual. That makes the card a second input rather than a
        replacement: whichever is used first wins, exactly as with Copilot's ask_user.

        The marker written by the hook is the gate. It is removed by the next hook
        event for that session - a tool starting, or the turn ending - because either
        proves the prompt is no longer waiting.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Live
    )

    if (-not $script:CodexAdapterLoaded) { return }

    foreach ($sessionId in @($Live.Keys)) {
        $session = $Live[$sessionId]
        if ([string]$session.Kind -ne 'codex') { continue }

        $marker = Get-CodexApprovalMarker -SessionId $sessionId
        if ($null -eq $marker) { continue }

        $node = Get-CopilotMqttNodeId -SessionId $sessionId
        $choice = ''
        try {
            $selector = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
            $choice = [string]$selector.state
        }
        catch { continue }

        if ($choice -notin @('Approve', 'Deny')) { continue }

        # Codex's approval prompt is a keyboard UI, so the answer is typed into the
        # session the same way a reply is. Approve sends y, deny sends n, which is
        # what its prompt accepts.
        $keystroke = if ($choice -eq 'Approve') { 'y' } else { 'n' }
        $short = $sessionId.Substring(0, [Math]::Min(8, $sessionId.Length))
        $delivery = Send-CopilotSessionPrompt -SessionId $sessionId -Text $keystroke `
            -ProcessId ([int]$session.ProcessId)

        if ($delivery.Delivered) {
            Write-DaemonLog -Message "codex approval '$choice' delivered to $short (pid $($delivery.ProcessId))"
        }
        else {
            Write-DaemonLog -Message "codex approval delivery FAILED for $short : $($delivery.Detail)"
        }

        # Clear either way, so a failed delivery is not resent on every reconcile.
        # The hook clears the marker itself once the prompt is genuinely answered.
        try {
            Clear-CopilotMqttDecision -SessionId $sessionId `
                -SessionName ([string]$State[$sessionId].Name) `
                -Machine ([string]$State[$sessionId].Machine) -Headers $Headers
        }
        catch { }
    }
}

function Get-DaemonAnswerCorrection {
    <#
        Composes the message sent to a session whose answer was delivered wrongly.

        The prompt is driven by arrow keys, and a keystroke that fails to register - or
        registers twice - selects a different option and the CLI records it as the
        user's choice. Nothing downstream can tell, so the agent proceeds confidently
        on an answer the user never gave.

        Naming both what was chosen and what to ignore matters: a bare restatement
        reads like a new instruction, and the agent has no reason to connect it to the
        question it just had answered.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Fields,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Selections
    )

    $lines = for ($i = 0; $i -lt $Fields.Count -and $i -lt $Selections.Count; $i++) {
        $label = [string]$Fields[$i].Label
        $value = [string]$Selections[$i]
        if ([string]::IsNullOrWhiteSpace($value)) { $value = '(left blank)' }
        "  - $label : $value"
    }

    @(
        'Correction from the Home Assistant bridge: the answer just recorded for your'
        'last question is WRONG - it was mis-delivered to the prompt, not chosen by me.'
        'Disregard it. What I actually selected was:'
        ''
        ($lines -join "`n")
        ''
        'Please continue using these values.'
    ) -join "`n"
}

function Invoke-DaemonReply {
    <#
        Delivers a dashboard reply into the running CLI and clears the box.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][hashtable]$Headers,
        # What to show on the card. A reply carrying attachments is injected as
        # "@C:\...\shot.png your question", which is not what the user typed and
        # should not be echoed back at them.
        [AllowEmptyString()][string]$DisplayText = '',
        # The reply card does not use the text box, so clearing it would wipe
        # anything left sitting there rather than confirming the send.
        [bool]$ClearReplyBox = $true
    )

    $short = $SessionId.Substring(0, [Math]::Min(8, $SessionId.Length))

    # Claude and Codex leave no inuse.<pid>.lock, so their owning process is passed
    # explicitly from the registration their hooks maintain. Without this the
    # injector falls back to the Copilot-only lock file, finds nothing, and the reply
    # box fails silently - which is worse than not offering one.
    #
    # The live set the last reconcile found already has it. Rescanning every
    # registration and the whole process list here cost a noticeable slice of each
    # send, so that is only the fallback.
    $explicitPid = 0
    $known = if ($script:DaemonLive) { $script:DaemonLive[$SessionId] } else { $null }
    if ($null -ne $known -and $known.PSObject.Properties['Kind'] -and [string]$known.Kind -in @('claude', 'codex') -and
        $known.PSObject.Properties['ProcessId'] -and [int]$known.ProcessId -gt 0 -and
        $null -ne (Get-Process -Id ([int]$known.ProcessId) -ErrorAction SilentlyContinue)) {
        $explicitPid = [int]$known.ProcessId
    }
    if ($explicitPid -le 0) {
        $claudeSession = (Get-LiveClaudeSessions)[$SessionId]
        if ($null -ne $claudeSession) { $explicitPid = [int]$claudeSession.ProcessId }
    }
    if ($explicitPid -le 0) {
        $codexSession = (Get-LiveCodexSessions)[$SessionId]
        if ($null -ne $codexSession) { $explicitPid = [int]$codexSession.ProcessId }
    }

    # For Claude the transcript shows whether the prompt was really submitted, so the
    # send can be confirmed (Confirm-DaemonClaudeSubmit) rather than assumed.
    $claudeTranscript = ''
    $transcriptBefore = 0L
    if ($null -ne $known -and [string]$known.Kind -eq 'claude' -and $known.PSObject.Properties['Transcript'] -and
        [IO.File]::Exists([string]$known.Transcript)) {
        $claudeTranscript = [string]$known.Transcript
        $transcriptBefore = [IO.FileInfo]::new($claudeTranscript).Length
    }

    $delivery = Send-CopilotSessionPrompt -SessionId $SessionId -Text $Text -ProcessId $explicitPid

    if ($delivery.Delivered -and $claudeTranscript) {
        $waitingOnPrompt = $known.PSObject.Properties['HookStatus'] -and [string]$known.HookStatus -eq 'waiting'
        $confirm = Confirm-DaemonClaudeSubmit -ProcessId ([int]$delivery.ProcessId) -Transcript $claudeTranscript `
            -Offset $transcriptBefore -AllowRetry:(-not $waitingOnPrompt)
        if (-not $confirm.Submitted) {
            $delivery.Delivered = $false
            $delivery.Detail = "typed but not submitted ($($confirm.Detail))"
        }
        elseif ($confirm.Retries -gt 0) {
            $delivery.Detail = "$($delivery.Detail); submitted after $($confirm.Retries) extra Enter(s)"
        }
    }

    if ($delivery.Delivered) {
        Write-DaemonLog -Message "reply delivered to $short (pid $($delivery.ProcessId)): $($delivery.Detail)"
    }
    else {
        Write-DaemonLog -Message "reply delivery FAILED for $short : $($delivery.Detail)"
    }

    # Confirm on the card. The box clearing is the only other signal, and on its own
    # it is ambiguous - a cleared box looks the same whether the reply reached the
    # session or vanished. A failure especially must be visible: the whole point of
    # the reply box is that nobody is watching the terminal.
    try {
        $preview = ($(if ([string]::IsNullOrWhiteSpace($DisplayText)) { $Text } else { $DisplayText }) -replace '\s+', ' ').Trim()
        if ($preview.Length -gt 60) { $preview = $preview.Substring(0, 57) + '...' }
        if ($delivery.Delivered) {
            Set-DaemonTransientActivity -SessionId $SessionId -Summary 'Reply sent' `
                -Extra @{ sent = $preview; at = [DateTimeOffset]::Now.ToString('HH:mm:ss') } -Headers $Headers
        }
        else {
            Set-DaemonTransientActivity -SessionId $SessionId -Summary 'Reply NOT sent' `
                -Extra @{ error = [string]$delivery.Detail; unsent = $preview } -Headers $Headers
        }
    }
    catch { }

    # Clear the box either way, so a failed delivery is not silently resent - but only
    # if it still holds what was just sent. Delivery is not instant (a long reply is
    # typed into the console a character at a time), and clearing unconditionally wiped
    # whatever the user had typed in the meantime. Their next Send then found an empty
    # box and reported "Nothing to send", which is what being unable to queue a
    # follow-up reply looks like from the dashboard.
    #
    # The reply box is an optimistic MQTT text entity with no state topic, so its value
    # is cleared with the text.set_value service, not by publishing to a state topic
    # that nothing is subscribed to.
    try {
        if (-not $ClearReplyBox) { return $delivery.Delivered }

        $node = Get-CopilotMqttNodeId -SessionId $SessionId
        $current = $null
        try {
            $current = [string](Get-HomeAssistantState -EntityId "text.${node}_reply" -Headers $Headers).state
        }
        catch {
            # Unreadable: fall through to the clear, which is the safer default.
        }

        if ($null -eq $current -or $current -eq $Text) {
            Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers -Data @{
                entity_id = "text.${node}_reply"
                value = $script:DaemonConfig.ReplyBlankValue
            }
        }
        else {
            Write-DaemonLog -Message "kept a follow-up reply typed for $short while the previous one was delivering"
        }
    }
    catch {
        # The guard hash still prevents a re-delivery even if the clear fails.
    }

    $delivery.Delivered
}

function Test-DaemonClaudePromptSubmitted {
    <#
        Whether Claude recorded a submitted prompt in the transcript bytes appended
        since Offset: a user message (not a tool result), or, while a turn is running,
        a queue entry for it. Claude writes either at the moment of submission.
    #>
    param(
        [Parameter(Mandatory)][string]$Transcript,
        [long]$Offset = 0
    )

    $append = Read-ClaudeTranscriptAppend -Path $Transcript -Offset $Offset
    foreach ($line in @($append.Lines)) {
        if ($line -match '"type":"queue-operation"' -and $line -match '"operation":"enqueue"') { return $true }
        if ($line -notmatch '"type":"user"') { continue }
        $entry = try { $line | ConvertFrom-Json } catch { $null }
        if ($null -eq $entry -or ($entry.PSObject.Properties['isMeta'] -and $entry.isMeta)) { continue }
        $blocks = Get-ClaudeContentBlocks -Message $entry.message
        if (@($blocks | Where-Object { $_.type -eq 'tool_result' }).Count -eq 0) { return $true }
    }
    $false
}

function Confirm-DaemonClaudeSubmit {
    <#
        Confirms a reply typed into Claude was actually submitted, pressing Enter again
        if it was not.

        Claude Code treats a fast burst of more than a few dozen characters as a paste,
        and an Enter that arrives while it is still settling that paste is absorbed
        rather than submitting. The text then sat in the input box, the card said
        "Reply sent", and it went in only with the next reply - run together with it.
        Short replies were unaffected, which is why it looked intermittent.

        The transcript settles it: a submitted prompt is written at once. If nothing
        arrives, the text is still waiting, so Enter is pressed again, twice at most.
        No retry is made while a permission prompt is pending (AllowRetry off), where
        a stray Enter could accept it.
    #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$Transcript,
        [long]$Offset = 0,
        [switch]$AllowRetry,
        [int]$WaitMs = 1200,
        [int]$MaxRetries = 2
    )

    $result = [pscustomobject]@{ Submitted = $false; Retries = 0; Detail = '' }
    $attempt = 0
    while ($true) {
        $deadline = [DateTimeOffset]::Now.AddMilliseconds($WaitMs)
        while ([DateTimeOffset]::Now -lt $deadline) {
            if (Test-DaemonClaudePromptSubmitted -Transcript $Transcript -Offset $Offset) {
                $result.Submitted = $true
                $result.Retries = $attempt
                return $result
            }
            Start-Sleep -Milliseconds 100
        }

        if (-not $AllowRetry) { $result.Detail = 'no submit seen; not retried while a prompt is pending'; break }
        if ($attempt -ge $MaxRetries) { $result.Detail = "no submit seen after $attempt extra Enter(s)"; break }

        $attempt++
        try {
            Initialize-CopilotConsoleInjector
            $outcome = [CopilotCli.ConsoleInjector]::Send([uint32]$ProcessId, '', $true, 0)
            if (-not ([string]$outcome).StartsWith('ok:')) { $result.Detail = "extra Enter failed: $outcome"; break }
        }
        catch {
            $result.Detail = "extra Enter failed: $($_.Exception.Message)"
            break
        }
    }
    $result.Retries = $attempt
    $result
}

function Resolve-SessionFromReplyEntity {
    param(
        [Parameter(Mandatory)][string]$EntityId,
        [Parameter(Mandatory)][hashtable]$State
    )

    foreach ($sessionId in @($State.Keys)) {
        $node = Get-CopilotMqttNodeId -SessionId $sessionId
        if ($EntityId -eq "text.${node}_reply") { return $sessionId }
    }
    $null
}

function Resolve-DaemonPrimedCard {
    <#
        Builds the (summary, detail) a restart should re-publish for a session from its
        persisted display state, so a restart restores the card rather than blanking
        it. Reasoning is included only when verbose is on, matching the reconcile, and
        a session with no remembered activity falls back to a generic label.
    #>
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][ValidateSet('working', 'waiting', 'idle')][string]$Status,
        [bool]$VerboseOn
    )

    $summary = if ($Entry.PSObject.Properties['LastSummary'] -and -not [string]::IsNullOrWhiteSpace([string]$Entry.LastSummary)) {
        [string]$Entry.LastSummary
    }
    elseif ($Status -eq 'working') { 'Working' } else { 'Idle' }

    $detail = @{
        session = $Entry.Name
        machine = $Entry.Machine
        verbose = $VerboseOn
        updated = [DateTimeOffset]::Now.ToString('o')
    }
    if ($Entry.PSObject.Properties['LastHistory'] -and $Entry.LastHistory) {
        $detail['history'] = @($Entry.LastHistory)
    }
    Add-DaemonCardText -Entry $Entry -Detail $detail -VerboseOn $VerboseOn

    [pscustomobject]@{ Summary = $summary; Detail = $detail }
}

function Start-BridgeDaemon {
    $headers = Get-HomeAssistantHeaders
    $state = Read-DaemonState

    # Deliberately no pruning here. Sync-DaemonSessions retires anything that is no
    # longer live, which both removes its Home Assistant entities and drops it from
    # state. Pruning first would discard the record while leaving the published
    # entities behind as orphans.
    $live = Get-LiveBridgeSessions
    # Seed the fast lane, so streaming starts now rather than after the first reconcile.
    $script:DaemonLive = $live

    Write-DaemonLog -Message "daemon starting (pid $PID), $($live.Count) live session(s)"

    # Compile the console injector now rather than on the first reply. The compile
    # takes about 650 ms, which the first reply after every start used to wait for.
    try { Initialize-CopilotConsoleInjector } catch { }

    # Provision the dashboard's Detailed activity helper before anything renders it.
    if (Initialize-CopilotVerboseToggle) {
        Write-DaemonLog -Message "verbose toggle ready ($($script:DaemonConfig.VerboseToggle))"
    }
    else {
        Write-DaemonLog -Message 'verbose toggle unavailable; streaming defaults to quiet'
    }

    # Sweep the entities published under the old `copilot_cli_*` / `copilot_<hex>`
    # ids. Retained discovery configs outlive a rename, so without this the renamed
    # entities appear alongside their unavailable predecessors rather than replacing
    # them. Self-guarding, and a no-op once it has run.
    try {
        [void](Invoke-DaemonLegacyCleanup -Headers $headers -Live $live -State $state)
    }
    catch {
        Write-DaemonLog -Message "legacy entity cleanup failed: $($_.Exception.Message)"
    }

    # And the entities from before they were scoped to a machine, which would
    # otherwise sit next to the new ones as a second, dead set of controls.
    try {
        [void](Invoke-DaemonUnscopedEntityCleanup -Headers $headers)
    }
    catch {
        Write-DaemonLog -Message "unscoped entity cleanup failed: $($_.Exception.Message)"
    }

    # Declare the liveness sensor now, not on the first heartbeat. The beat is
    # deliberately unretained, so one that reaches Home Assistant before this config
    # has been processed is dropped - and the machine then reads offline for a whole
    # heartbeat interval starting from the moment its daemon came up.
    try {
        Publish-CopilotMqttMachineOnlineConfig -Headers $headers `
            -ExpireAfter $script:DaemonConfig.OnlineExpireSeconds
        [void](Set-CopilotMqttOnlineEntityId)
    }
    catch {
        Write-DaemonLog -Message "online sensor setup failed: $($_.Exception.Message)"
    }

    Clear-CopilotMqttOrphans -Headers $headers -Live $live

    # Prime every live session's status and activity up front. Persisted state makes
    # a session "already known", so the first reconcile skips the new-session branch
    # that sets these; without priming, an idle session that produced no new
    # transcript activity would sit at 'unknown' on the dashboard after a restart.
    # This is a handful of publishes once per daemon start, so it is done
    # unconditionally rather than guarded.
    Sync-DaemonSessions -Headers $headers -State $state
    # Reasoning is only shown while the verbose toggle is on, matching the reconcile,
    # so read it once for the restore below.
    $primeVerbose = Test-VerboseStreaming -Headers $headers
    foreach ($session in $live.Values) {
        $sid = $session.SessionId
        $entry = $state[$sid]
        if ($null -eq $entry) { continue }
        $node = Get-CopilotMqttNodeId -SessionId $sid
        $status = Get-DaemonStartupStatus -Session $session -Entry $entry

        # Provision entities added after this session was first published. A session
        # already recorded in state never goes through Sync-DaemonSessions' publish
        # branch again, so an upgrade that introduces a new per-session entity would
        # otherwise leave every running session without it until it exited. Done once
        # per daemon start - which is exactly when an upgrade lands - rather than on
        # every reconcile, to keep the steady-state request count unchanged.
        try {
            $probeStop = $null
            try { $probeStop = Get-HomeAssistantState -EntityId "button.${node}_stop" -Headers $headers }
            catch { $probeStop = $null }
            if ($null -eq $probeStop) {
                Publish-CopilotMqttSession -SessionId $sid -SessionName ([string]$entry.Name) `
                    -Machine ([string]$entry.Machine) -Headers $headers | Out-Null
                Start-Sleep -Milliseconds 1200
                [void](Set-CopilotMqttEntityIds -SessionId $sid)
                Write-DaemonLog -Message "provisioned end button for $($sid.Substring(0,8))"
            }
        }
        catch {
            Write-DaemonLog -Message "end-button provisioning failed for $sid : $($_.Exception.Message)"
        }

        # Restore the card from persisted display state rather than blanking it. A
        # restart - including the one an update triggers - must not wipe the summary,
        # the reasoning, the last response, or the history the card was showing.
        $card = Resolve-DaemonPrimedCard -Entry $entry -Status $status -VerboseOn $primeVerbose

        try {
            Set-CopilotMqttStatus -SessionId $sid -Status $status -Headers $headers -Attributes @{
                session = $entry.Name
                machine = $entry.Machine
                process_id = $session.ProcessId
                updated = [DateTimeOffset]::Now.ToString('o')
            }
            Set-CopilotMqttActivity -SessionId $sid -Summary $card.Summary -Detail $card.Detail -Headers $headers
            # Prime the reply box to empty so the card shows a blank field, not
            # 'unknown', for sessions restored from persisted state.
            Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $headers `
                -Data @{ entity_id = "text.${node}_reply"; value = $script:DaemonConfig.ReplyBlankValue }
            $entry.Status = $status
        }
        catch {
            Write-DaemonLog -Message "status prime failed for $sid : $($_.Exception.Message)"
        }
    }
    Repair-CopilotSessionEntities -Headers $headers -State $state -Live $live
    Invoke-PendingDecisions -Headers $headers -State $state -Live $live
    Invoke-PendingReplies -Headers $headers -State $state -Live $live
    Invoke-PendingCodexApprovals -Headers $headers -State $state -Live $live
    Invoke-PendingStops -Headers $headers -State $state -Live $live
    Sync-DaemonUpdateStatus -Headers $headers
    Sync-DaemonNewSession -Headers $headers -Live $live
    Write-DaemonState -State $state

    if ($RunOnce) {
        Write-DaemonLog -Message 'run-once complete'
        return
    }

    $lastReconcile = [DateTimeOffset]::Now

    while ($true) {
        # Watch every live session's reply box and decision selector, plus the Live
        # Verbose toggle. The subscription returns the instant Home Assistant pushes a
        # change, so an answer is injected and a verbose toggle reflected immediately.
        # Both are also backed by the authoritative sweep in the reconcile below, which
        # catches anything that lands between watch windows.
        $watchEntities = @(
            foreach ($sessionId in @($state.Keys)) {
                $node = Get-CopilotMqttNodeId -SessionId $sessionId
                "text.${node}_reply"
                "select.${node}_decision"
                "button.${node}_submit"
                # The reply card publishes here rather than to the text box. Left out,
                # a card reply waited for the 15-second reconcile to be noticed.
                "sensor.${node}_reply_payload"
                # End session, likewise: left out, a press sat unnoticed for up to 15 s.
                "button.${node}_stop"
            }
        ) + @($script:DaemonConfig.VerboseToggle)

        $hit = $null
        try {
            # The fast lane runs on every tick of the wait, on this thread, so it
            # shares state with the reconcile without any locking. A plain script
            # block, not a closure: GetNewClosure() would run it in a new module scope
            # that cannot see this script's functions.
            # It returns $true to end the wait early when a reconcile is wanted now.
            $fastLane = { Invoke-DaemonFastActivity -Headers $headers -State $state | Out-Null; [bool]$script:DaemonReconcileNow }
            $hit = Wait-CopilotHaStateChange -EntityIds $watchEntities `
                -TimeoutSeconds $ReconcileSeconds -OnTick $fastLane -TickMilliseconds 100
            $script:DaemonWatchFailures = 0
        }
        catch {
            # A normal timeout returns $null and is not an error; only a genuine
            # connection failure lands here. Back off exponentially (capped) so a
            # Home Assistant outage does not spin a tight reconnect loop.
            $script:DaemonWatchFailures++
            $backoff = [int][Math]::Min(2 * [Math]::Pow(2, $script:DaemonWatchFailures - 1), 60)
            Write-DaemonLog -Message "watch failed (attempt $($script:DaemonWatchFailures)): $($_.Exception.Message); retrying in ${backoff}s"
            Start-Sleep -Seconds $backoff
        }

        # A verbose toggle change refreshes every card's reasoning at once, without
        # waiting for the periodic reconcile or fresh transcript activity.
        if ($null -ne $hit -and $hit.EntityId -eq $script:DaemonConfig.VerboseToggle) {
            $script:DaemonVerbose = ($hit.State -eq 'on')
            try {
                Update-SessionsForVerbose -Headers $headers -State $state `
                    -VerboseOn ($hit.State -eq 'on')
            }
            catch {
                Write-DaemonLog -Message "verbose refresh failed: $($_.Exception.Message)"
            }
        }

        # A reply from the dashboard is delivered before anything else. The reconcile
        # below would get to it too, but only after a string of unrelated Home
        # Assistant calls. The payload stamp and submit press are recorded before
        # delivery, so the reconcile's own pass cannot send it a second time.
        if ($null -ne $hit -and $hit.EntityId -match '_(reply|reply_payload|submit)$') {
            try {
                Invoke-PendingReplies -Headers $headers -State $state -Live $script:DaemonLive
            }
            catch {
                Write-DaemonLog -Message "reply delivery failed: $($_.Exception.Message)"
            }
        }

        # End session is acted on before the reconcile below, not inside it: the
        # reconcile then finds the session gone and drops its card in the same pass.
        # Inside the reconcile the stop came after the check for exited sessions, so
        # the card stayed up until the next pass.
        if ($null -ne $hit -and $hit.EntityId -match '_stop$') {
            try {
                Invoke-PendingStops -Headers $headers -State $state -Live $script:DaemonLive
            }
            catch {
                Write-DaemonLog -Message "end session failed: $($_.Exception.Message)"
            }
        }

        # A push hit only shortcuts latency; the sweep in the reconcile does the
        # authoritative delivery, so both paths funnel through the same guarded code.
        if (([DateTimeOffset]::Now - $lastReconcile).TotalSeconds -ge $ReconcileSeconds -or
            $null -ne $hit -or $script:DaemonReconcileNow) {
            $script:DaemonReconcileNow = $false
            try {
                # The reconcile makes a string of Home Assistant calls, and a
                # transcript write that lands during it would otherwise wait for all of
                # them. The fast lane between steps costs a file-size check per session
                # when nothing changed.
                $live = Get-LiveBridgeSessions
                Sync-DaemonSessions -Headers $headers -State $state
                Repair-CopilotSessionEntities -Headers $headers -State $state -Live $live
                Invoke-DaemonFastActivity -Headers $headers -State $state
                Invoke-PendingDecisions -Headers $headers -State $state -Live $live
                Invoke-PendingReplies -Headers $headers -State $state -Live $live
                Invoke-DaemonFastActivity -Headers $headers -State $state
                Invoke-PendingCodexApprovals -Headers $headers -State $state -Live $live
                Invoke-PendingStops -Headers $headers -State $state -Live $live
                Invoke-DaemonFastActivity -Headers $headers -State $state
                Sync-DaemonUpdateStatus -Headers $headers
                Sync-DaemonNewSession -Headers $headers -Live $live
                Sync-DaemonClients -Headers $headers
                Invoke-DaemonFastActivity -Headers $headers -State $state
                Write-DaemonState -State $state
            }
            catch {
                Write-DaemonLog -Message "reconcile failed: $($_.Exception.Message)"
            }
            $lastReconcile = [DateTimeOffset]::Now

            # A newly installed adapter is only loaded at startup, so the daemon ends
            # here and the supervisor starts it again a few seconds later. State was
            # just written, so the new daemon carries straight on.
            if ($script:DaemonRestartRequested) {
                Write-DaemonLog -Message "restarting to $($script:DaemonRestartRequested)"
                return
            }
        }
    }
}

# A second daemon would publish duplicate activity and race on reply delivery.
# Tests dot-source this file with AGENT_BRIDGE_DAEMON_NORUN set to load the
# functions without starting the daemon; the supervisor never sets it, so a real
# launch is unaffected.
if (-not $env:AGENT_BRIDGE_DAEMON_NORUN) {
    $mutex = [Threading.Mutex]::new($false, $script:DaemonConfig.MutexName)
    $owned = $false
    try {
        $owned = $mutex.WaitOne([TimeSpan]::FromSeconds(2))
        if (-not $owned) {
            Write-DaemonLog -Message 'another daemon instance is already running; exiting'
            return
        }
        Start-BridgeDaemon
    }
    catch {
        Write-DaemonLog -Message "daemon crashed: $($_.Exception.Message)"
        throw
    }
    finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}



