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

    This file is the entry point: configuration, the shared $script: state, logging,
    the state file and the main loop. The work itself is in its parts, loaded below
    into this same scope (docs/daemon-split.md):

      daemon-discovery.ps1    which sessions are live
      daemon-activity.ps1     what a session is doing, onto its card
      daemon-sessions.ps1     card lifecycle
      daemon-replies.ps1      dashboard to agent text
      daemon-decisions.ps1    questions and approvals
      daemon-launch.ps1       starting and ending sessions
      daemon-maintenance.ps1  keeping the install current
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
. (Join-Path $PSScriptRoot 'bridge-pairing.ps1')
. (Join-Path $PSScriptRoot 'bridge-pairing-io.ps1')
# What the hooks do, for events the native hook spools here (daemon-hookspool.ps1).
. (Join-Path $PSScriptRoot 'bridge-adapter.ps1')
. (Join-Path $PSScriptRoot 'copilot-hooks.ps1')

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
    NewPromptPayload = Get-BridgeMachineEntityId -Domain 'sensor' -Key 'new_prompt_payload' -Slug $script:DaemonMachineSlug
    NewWorkspace  = Get-BridgeMachineEntityId -Domain 'select' -Key 'new_workspace'     -Slug $script:DaemonMachineSlug
    NewProfile    = Get-BridgeMachineEntityId -Domain 'select' -Key 'new_profile'       -Slug $script:DaemonMachineSlug
    NewAgent      = Get-BridgeMachineEntityId -Domain 'select' -Key 'new_agent'         -Slug $script:DaemonMachineSlug
    NewModel      = Get-BridgeMachineEntityId -Domain 'select' -Key 'new_model'         -Slug $script:DaemonMachineSlug
    NewEffort     = Get-BridgeMachineEntityId -Domain 'select' -Key 'new_effort'        -Slug $script:DaemonMachineSlug
    NewContext    = Get-BridgeMachineEntityId -Domain 'select' -Key 'new_context'       -Slug $script:DaemonMachineSlug
    NewResume     = Get-BridgeMachineEntityId -Domain 'select' -Key 'new_resume'        -Slug $script:DaemonMachineSlug
    NewPermissions = Get-BridgeMachineEntityId -Domain 'select' -Key 'new_permissions'  -Slug $script:DaemonMachineSlug
    NewSession    = Get-BridgeMachineEntityId -Domain 'button' -Key 'new_session'       -Slug $script:DaemonMachineSlug
    NewResult     = Get-BridgeMachineEntityId -Domain 'sensor' -Key 'new_session_result' -Slug $script:DaemonMachineSlug
    Online        = Get-BridgeMachineEntityId -Domain 'binary_sensor' -Key 'online'      -Slug $script:DaemonMachineSlug
}

$script:DaemonConfig = @{
    MutexName = 'Local\' + $script:BridgeInstallContext.TaskName
    # Per machine, so one machine can be watched in detail while the others are not.
    # Home Assistant slugifies a helper's name into its id, so the name is built from
    # the same slug the entity id is, and the id itself comes from
    # Get-BridgeMachineEntityId - which exists so a reader and a writer cannot drift.
    VerboseHelperId = "agent_bridge_${script:DaemonMachineSlug}_detailed_activity"
    VerboseHelperName = "Agent Bridge $($script:DaemonMachineSlug -replace '_', ' ') Detailed Activity"
    VerboseToggle = (Get-BridgeMachineEntityId -Domain 'input_boolean' -Key 'detailed_activity' -Slug $script:DaemonMachineSlug)
    LogFile = (Get-BridgeRuntimePath 'agent-bridge-daemon.log')
    StateFile = (Get-BridgeRuntimePath 'agent-bridge-daemon-state.json')
    # Written by the self-updater when an install finishes, read by whichever daemon
    # is running next, so a press of the install button ends in a visible
    # "updated to X" (or a failure) notification.
    UpdateOutcomeFile = (Get-BridgeRuntimePath 'agent-bridge-update-outcome.json')
    # Written once the pre-rename entities have been swept, so the sweep does not
    # repeat on every daemon start.
    LegacyCleanupMarker = (Get-BridgeRuntimePath 'agent-bridge-legacy-cleanup.json')
    # The same, for the entities that predate being scoped to a machine.
    UnscopedCleanupMarker = (Get-BridgeRuntimePath 'agent-bridge-unscoped-cleanup.json')
    # Cap how much transcript is read in one pass, so a session that produced a huge
    # burst cannot stall the loop.
    MaxTailBytes = 512000
    ActivityHistory = 12
    # The trail while Detailed activity is on, where thoughts join the actions and
    # roughly double how fast it fills.
    ActivityHistoryDetailed = 24
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
    # How long to wait before trying again to rebuild a live session's entities after
    # Home Assistant answered that they are not there. A publish Home Assistant never
    # acts on would otherwise be repeated every reconcile for as long as the session
    # runs; a minute heals a torn-down card promptly without becoming a loop.
    EntityRestoreSeconds = 60
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
    # How long a session stays armed as agent-driven while the turn it was armed for
    # has not started. Delivery types a reply into the console a character at a time,
    # so there are usually a few activity updates in between - the arm has to outlive
    # those. Ten minutes for the same reason the Send arm is: honouring it late is
    # right, attributing a turn nobody drove is not.
    DriverArmSeconds = 600
    # How long a first press of End session stays armed, waiting for the second press
    # that confirms it. Only a session that is not idle is guarded this way; see
    # Invoke-PendingStops for why one press is not enough.
    StopConfirmSeconds = 10
    # How long to wait before retrying the note that says the confirmation lapsed,
    # when Home Assistant could not be reached at the moment it did. The arm is only
    # released once that note lands: a quiet session produces no later activity, so
    # giving up would leave the card asking for a press that confirms nothing, and
    # recovery alone would never clear it.
    StopLapseRetrySeconds = 2
    ResumeCacheSeconds = 180
    # How soon to retry after a fetch that failed or came back empty, rather than
    # waiting out the full interval with a list known to be wrong.
    ResumeRetrySeconds = 20
    # How long a launch-card note (a failed launch, an agent set up) stays before it
    # is cleared. Nothing else removes one, so without this it stayed indefinitely.
    NoteExpirySeconds = 600
    # The first message a Codex launched without one is given, so that it creates
    # its session and can be attached (see Sync-DaemonNewSession).
    CodexStartPrompt = 'Reply with one short line saying you are ready, then wait for my next message.'
}

# Session-set signature of the last dashboard rebuild, so the dashboard is only
# regenerated when a session appears or exits, not on every reconcile.
$script:DaemonDashboardSignature = $null

# The fast lane's view between reconciles (see Invoke-DaemonFastActivity): the live
# sessions and verbose setting the last reconcile saw, and the last-seen write time of
# each Claude registration.
$script:DaemonLive = @{}
$script:DaemonDiscoverySnapshot = $null
$script:DaemonOwnerCatalogue = @{}
$script:DaemonSessionCleanupPending = @{}
$script:DaemonVerbose = $false
$script:DaemonRegistrationStamps = @{}

# The session the last Launch press started, followed until it registers (see
# Update-DaemonPendingLaunch), and a request for a reconcile now rather than at the
# end of the interval, so a newly registered session's card appears straight away.
$script:DaemonPendingLaunch = $null
$script:DaemonReconcileNow = $false

# Who pressed Launch, and the driver waiting for the session that press produced. The
# press carries the account behind it and the session does not exist yet, so the
# answer is held here between the two (Test-DaemonNewSessionPressed, Add-DaemonSession).
$script:DaemonNewSessionPressDriver = ''
$script:DaemonLaunchDrivers = @{}

# Adapter installs started for agents installed after the bridge (Sync-DaemonClients),
# and why the daemon should restart once the pass is done - to load a new adapter.
$script:DaemonClientSetup = @{}
$script:DaemonRestartRequested = ''
# The agent last published as the dashboard's default, kept across restarts so a
# selection still showing it can be told apart from one the user made.
$script:DaemonDefaultAgentFile = Get-BridgeRuntimePath 'agent-bridge-default-agent.txt'
$script:DaemonDefaultAgent = $null
try { $script:DaemonDefaultAgent = ([System.IO.File]::ReadAllText($script:DaemonDefaultAgentFile)).Trim() } catch { }

# Sessions whose reply-payload sensor has been checked this run, so the probe costs
# one Home Assistant read per session rather than one per reconcile.
$script:DaemonPayloadSensorChecked = @{}

# When each live session's missing entities were last rebuilt, and how many times, so
# a republish Home Assistant never acts on is spaced out and reported once rather than
# repeated every reconcile. Cleared for a session as soon as its entity is seen back.
$script:DaemonEntityRestore = @{}

# Transcripts whose read failure has already been reported, keyed by path, so an
# unreadable one is described once rather than once per pass. Cleared when it reads
# again, so a later failure is still news.
$script:DaemonTranscriptFailureReported = @{}

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

# What the resume dropdown last actually offered - the cache above after the live and
# approved-workspace filters. Published so other machines can show these sessions too,
# and kept here rather than recomputed so the list a peer sees is exactly the list this
# machine's own dropdown shows. Initialised for StrictMode, as above.
$script:DaemonResumeOffered = @()

# The last transfer request this machine served. The request is retained so the owning
# machine finds it whenever its next pass comes round, which also means it is still there
# on the pass after that - without this it would be served again every reconcile.
$script:DaemonTransferServed = ''

# Decisions already reported as terminal-only, so the daemon says it once per
# question instead of on every reconcile. Initialised for StrictMode.
$script:DaemonTerminalOnlyWarned = @{}

# Launcher process per session the bridge started itself, so End can close the
# console it opened. A window the user opened is deliberately never touched - that
# terminal is theirs. Not persisted: after a daemon restart the association is gone
# and the window is simply left alone, which is the safe direction to fail.
$script:DaemonLaunchedPids = @{}

# Model, reasoning effort and context window per session the bridge launched, keyed
# by session id - and under DaemonPendingTuningKey for an agent that picks its own
# id (Codex), until Update-DaemonPendingLaunch learns which session the launch
# produced and moves the record onto that id.
#
# The command line is the only record: effort and context appear in no transcript and
# no agent reports them back, so what is not kept here cannot be shown anywhere. Once
# a session is adopted its settings move onto the persisted state entry, which is why
# this itself is not persisted - a daemon restart mid-launch simply leaves the new
# card without the line, rather than showing settings from the wrong launch.
$script:DaemonLaunchedTuning = @{}
$script:DaemonPendingTuningKey = '(pending)'

# Sessions whose End button has been pressed once and is waiting for the second
# press that confirms it, keyed by session id, holding the moment it was armed.
#
# In memory and never persisted, deliberately: a daemon that restarts between the
# two presses must come back disarmed. Coming back still armed would turn the next
# press - made after a restart, possibly minutes later - into a confirmation of
# something the user had long since given up on.
#
# The question those arms put on a card is recorded on disk so that hook processes
# publishing their own status line do not wipe it. That record cannot confirm
# anything, and is cleared by Clear-DaemonStopPrompts at actual startup - not here,
# because this runs whenever the file is dot-sourced for its functions, and clearing
# from there wiped a running daemon's records from under it.
$script:DaemonStopArmed = @{}

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

# ---------------------------------------------------------------- front ends
# Sessions carry a Kind so the daemon can serve more than one CLI. Everything
# Copilot-specific stays on the 'copilot' path unchanged; 'claude' sessions are
# discovered, streamed and answered through the helpers below. The Claude adapter is
# optional - when it is not installed, these degrade to returning nothing.

$script:ClaudeAdapterLoaded = $false
$configuredClients = Get-BridgeSelectedClients
$claudeHooks = Join-Path $script:BridgeInstallContext.ClaudeHome 'ha-bridge'
if (($null -eq $configuredClients -or $configuredClients -contains 'claude') -and
    (Test-BridgeAdapterRoot -Directory $claudeHooks -Context $script:BridgeInstallContext) -and
    (Test-Path -LiteralPath (Join-Path $claudeHooks 'claude-session.ps1'))) {
    try {
        . (Join-Path $claudeHooks 'claude-session.ps1')
        . (Join-Path $claudeHooks 'claude-transcript.ps1')
        $script:ClaudeAdapterLoaded = $true
    }
    catch {
        $script:ClaudeAdapterLoaded = $false
    }
    # The hook bodies, for spooled events. Apart from the adapter itself, so an adapter
    # from before they existed still loads.
    if ($script:ClaudeAdapterLoaded -and (Test-Path -LiteralPath (Join-Path $claudeHooks 'claude-hooks.ps1'))) {
        try {
            . (Join-Path $claudeHooks 'claude-ask-parser.ps1')
            . (Join-Path $claudeHooks 'claude-hooks.ps1')
        }
        catch { }
    }
}

$script:CodexAdapterLoaded = $false
$codexHooks = Join-Path $script:BridgeInstallContext.BridgeHome 'codex-bridge\plugins\agent-ha-bridge\hooks'
if (($null -eq $configuredClients -or $configuredClients -contains 'codex') -and
    (Test-BridgeAdapterRoot -Directory $codexHooks -Context $script:BridgeInstallContext) -and
    (Test-Path -LiteralPath (Join-Path $codexHooks 'codex-session.ps1'))) {
    try {
        . (Join-Path $codexHooks 'codex-session.ps1')
        . (Join-Path $codexHooks 'codex-transcript.ps1')
        $script:CodexAdapterLoaded = $true
    }
    catch {
        $script:CodexAdapterLoaded = $false
    }
    if ($script:CodexAdapterLoaded -and (Test-Path -LiteralPath (Join-Path $codexHooks 'codex-hooks.ps1'))) {
        try { . (Join-Path $codexHooks 'codex-hooks.ps1') } catch { }
    }
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
    <#
        Whether cards carry the model's reasoning, each tool call, and the agent's
        thinking in the activity trail.

        This was a dashboard toggle, then a `detailedActivity` setting, and is a
        switch again - per machine. The reason it came back is that what it controls
        grew: it used to decide only how much an update carried, which folding the
        session cards had already made bearable. It now also decides whether thinking
        joins the trail, and since almost every message an agent writes carries a
        thought, that roughly doubles how fast the trail fills and halves how far back
        it reaches. That is a judgement about the phone you are holding, so it belongs
        somewhere you can reach from it.

        The setting is the default for a machine whose switch does not exist yet - a
        first run, or a headless install - so nothing changes for one that never sees
        the dashboard. An unreachable Home Assistant falls back to it too, rather than
        quietly turning detail off.
    #>
    param([hashtable]$Headers)

    $fallback = [bool](Get-BridgeSetting 'detailedActivity' $true)
    $entityId = [string]$script:DaemonConfig.VerboseToggle
    if ([string]::IsNullOrWhiteSpace($entityId)) { return $fallback }

    try {
        $headers = if ($Headers) { $Headers } else { Get-HomeAssistantHeaders }
        $state = Get-DaemonEntityState -EntityId $entityId -Headers $headers
        $value = [string]$state.state
        if ($value -eq 'on') { return $true }
        if ($value -eq 'off') { return $false }
    }
    catch { }
    $fallback
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

function Set-DaemonDriverPending {
    <#
        Marks a session as about to take a turn on someone's behalf.

        Stamped as well as flagged. The flag is consumed by the turn it was armed for,
        and nothing guarantees that turn ever arrives - a reply can be delivered to a
        session that is already shutting down. Left armed forever, the next thing the
        person typed in the terminal would wear the agent's edge, which is the one
        direction this is meant never to fail in.
    #>
    param(
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Driver
    )
    Set-DaemonSessionProperty -Entry $Entry -Name 'Driver' -Value $Driver
    Set-DaemonSessionProperty -Entry $Entry -Name 'DriverPending' -Value $true
    Set-DaemonSessionProperty -Entry $Entry -Name 'DriverPendingAt' -Value ([DateTimeOffset]::Now.ToString('o'))
}

function Update-DaemonDriverPendingStamp {
    <#
        Restarts an arm's clock, for when the text it was armed for has only just gone
        in.

        A session is armed before delivery, because the turn must not be able to start
        between the two. Delivery is normally instant - measured at 0.3s across every
        reply on one machine for a day, including one of 5,914 characters - but it is
        not guaranteed to be: one delivery that day took 721 seconds while injection
        was failing and retrying. Timing the arm from before that would have expired it
        while the reply was still going in, and the turn it produced would then have
        read as typed in the terminal. So the window measures from when the text landed
        rather than from when it was picked up.
    #>
    param([Parameter(Mandatory)][object]$Entry)

    if (-not ($Entry.PSObject.Properties['DriverPending'] -and $Entry.DriverPending)) { return }
    Set-DaemonSessionProperty -Entry $Entry -Name 'DriverPendingAt' -Value ([DateTimeOffset]::Now.ToString('o'))
}

function Test-DaemonPayloadJustDelivered {
    <#
        Whether a reply payload went into this session recently enough that a Send
        press arriving now could be that same message's redundant second half.

        An agent publishes the payload and then presses Send, but the payload is
        delivered on its own as soon as it lands, so the press finds an empty box.
        Treating that as "nothing to send" and disarming threw away the attribution
        for a message that had in fact just gone.

        Necessary but NOT sufficient on its own: the caller must also establish that
        the arm was outstanding before the press, or a payload already accounted for
        by its own turn gets a fresh arm manufactured from this timestamp.

        Measured against the arm's own window: past that, the turn the payload was for
        is not coming, and keeping the arm would hand the edge to whoever types next.
    #>
    param([Parameter(Mandatory)][object]$Entry)

    if (-not ($Entry.PSObject.Properties['LastPayloadDeliveredAt'] -and $Entry.LastPayloadDeliveredAt)) {
        return $false
    }
    try { $since = [DateTimeOffset]::Parse([string]$Entry.LastPayloadDeliveredAt) }
    catch { return $false }
    ([DateTimeOffset]::Now - $since).TotalSeconds -lt $script:DaemonConfig.DriverArmSeconds
}

function Test-DaemonDriverPending {
    <#
        Whether a session is still armed: flagged, and not so long ago that the turn
        it was armed for is clearly never coming.
    #>
    param([Parameter(Mandatory)][object]$Entry)

    if (-not ($Entry.PSObject.Properties['DriverPending'] -and $Entry.DriverPending)) { return $false }
    # An arm from before this property existed has no stamp. Treating that as expired
    # would silently drop the attribution of every session carried across the upgrade,
    # so it is honoured once and cleared by the turn that consumes it.
    if (-not ($Entry.PSObject.Properties['DriverPendingAt'] -and $Entry.DriverPendingAt)) { return $true }
    try { $since = [DateTimeOffset]::Parse([string]$Entry.DriverPendingAt) }
    catch { return $true }
    ([DateTimeOffset]::Now - $since).TotalSeconds -lt $script:DaemonConfig.DriverArmSeconds
}

function Invoke-DaemonStartupSessionCleanup {
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State,
        [AllowNull()]$Discovery,
        [Parameter(Mandatory)][ValidateSet('Legacy', 'Orphans')][string]$Phase
    )
    if (-not (Test-DaemonDiscoveryContext -Snapshot $Discovery) -or -not $Discovery.Complete) {
        $script:DaemonSessionCleanupPending[$Phase] = $true
        Write-DaemonLog -Message "startup session cleanup deferred ($Phase): ownership observation is incomplete"
        return $false
    }
    if ($Phase -eq 'Legacy') {
        [void](Invoke-DaemonLegacyCleanup -Headers $Headers -Live $Discovery.Live -State $State)
    }
    else {
        if (-not (Clear-CopilotMqttOrphans -Headers $Headers -Live $Discovery.Live -Discovery $Discovery)) {
            $script:DaemonSessionCleanupPending[$Phase] = $true
            return $false
        }
    }
    [void]$script:DaemonSessionCleanupPending.Remove($Phase)
    $true
}

function Initialize-DaemonStartup {
    # Once per start, before the first pass: tidy what an earlier daemon or an older
    # bridge left behind, and get ready for the first reply.
    param([hashtable]$Headers, [hashtable]$State, [hashtable]$Live, [AllowNull()]$Discovery = $null)
    $headers = $Headers
    $state = $State
    $live = $Live

    # The collector setting the supervisor passes (Invoke-DaemonMemoryTrim), so a daemon
    # holding too much memory can be told apart from one that never got it.
    $gcConserve = if ($env:DOTNET_GCConserveMemory) { $env:DOTNET_GCConserveMemory } else { 'unset' }
    Write-DaemonLog -Message "daemon starting (pid $PID), $($live.Count) live session(s); GC conserve-memory $gcConserve"

    # A launch being followed does not survive a restart, so a note about one in
    # progress ("Starting...", "Codex is open in...", "press Launch again to trust")
    # would otherwise stay up with nothing left to clear it. Other notes - an agent
    # just set up, which restarts the daemon on purpose - are left to expire.
    try {
        $note = [string](Get-HomeAssistantState -EntityId $script:DaemonEntity.NewResult -Headers $headers).state
        if (Test-DaemonLaunchProgressNote -Text $note) {
            Set-CopilotMqttNewSessionResult -Headers $headers -Text ''
            Write-DaemonLog -Message "cleared a launch note left from before the restart: $note"
        }
    }
    catch { }

    # Compile the console injector now rather than on the first reply. The compile
    # takes about 650 ms, which the first reply after every start used to wait for.
    try { Initialize-CopilotConsoleInjector } catch { }

    # Hear about hook events the native hook spools, rather than listing the folder on
    # every tick (daemon-hookspool.ps1).
    Start-DaemonHookSpoolWatcher

    # Detailed activity decides how much each card update carries, and now also whether
    # the agent's thinking joins the activity trail. That is a choice about the phone
    # you are reading it on, so it is a switch again rather than a setting in a file on
    # each machine: per machine, because one of them may be doing something you want to
    # watch closely while the others are not.
    #
    # The setting stays as the default for a machine whose helper does not exist yet,
    # which keeps a headless or first-run install behaving exactly as before.
    try {
        if (Initialize-CopilotVerboseToggle -HelperId $script:DaemonConfig.VerboseHelperId `
                -Name $script:DaemonConfig.VerboseHelperName `
                -DisplayName "Detailed activity ($script:DaemonMachineName)" `
                -LegacyHelperId 'agent_bridge_detailed_activity') {
            Write-DaemonLog -Message "Detailed activity switch ready: $($script:DaemonConfig.VerboseToggle)"
        }
    }
    catch { Write-DaemonLog -Message "could not provision the Detailed activity switch: $($_.Exception.Message)" }

    $script:DaemonVerbose = Test-VerboseStreaming

    # Sweep the entities published under the old `copilot_cli_*` / `copilot_<hex>`
    # ids. Retained discovery configs outlive a rename, so without this the renamed
    # entities appear alongside their unavailable predecessors rather than replacing
    # them. Self-guarding, and a no-op once it has run.
    try {
        [void](Invoke-DaemonStartupSessionCleanup -Headers $headers -State $state -Discovery $Discovery -Phase Legacy)
    }
    catch {
        if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
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

    [void](Invoke-DaemonStartupSessionCleanup -Headers $headers -State $state -Discovery $Discovery -Phase Orphans)
}

function Restore-DaemonSessionCards {
    # Prime every live session's status and activity up front. Persisted state makes
    # a session "already known", so the first reconcile skips the new-session branch
    # that sets these; without priming, an idle session that produced no new
    # transcript activity would sit at 'unknown' on the dashboard after a restart.
    # This is a handful of publishes once per daemon start, so it is done
    # unconditionally rather than guarded.
    param([hashtable]$Headers, [hashtable]$State, [hashtable]$Live, [AllowNull()]$Discovery = $null)
    $headers = $Headers
    $state = $State
    if ($null -eq $Discovery) { $Discovery = Get-LiveBridgeSessions -AsObservation -State $state }
    $live = $Discovery.Live

    Sync-DaemonSessions -Headers $headers -State $state -Live $live -Discovery $Discovery
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
}

function Get-DaemonWatchEntities {
    # Watch every live session's reply box and decision selector, plus the Live
    # Verbose toggle. The subscription returns the instant Home Assistant pushes a
    # change, so an answer is injected and a verbose toggle reflected immediately.
    # Both are also backed by the authoritative sweep in the reconcile below, which
    # catches anything that lands between watch windows.
    param([hashtable]$State)
    $watchEntities = @(
        foreach ($sessionId in @($State.Keys)) {
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
    ) +
        # Launch too: left out, a press sat unnoticed for up to 15 s with nothing
        # on the card to say it had been seen.
        @($script:DaemonEntity.NewSession)
    , $watchEntities
}

function Wait-DaemonChange {
    # Waits for a watched entity to change, or for the reconcile interval to pass,
    # streaming activity meanwhile. Returns the change, or $null.
    param([hashtable]$Headers, [hashtable]$State, [string[]]$WatchEntities)
    $headers = $Headers
    $state = $State

    $hit = $null
    try {
        # The fast lane runs on every tick of the wait, on this thread, so it
        # shares state with the reconcile without any locking. A plain script
        # block, not a closure: GetNewClosure() would run it in a new module scope
        # that cannot see this script's functions.
        # It returns $true to end the wait early when a reconcile is wanted now.
        $fastLane = { Invoke-DaemonFastActivity -Headers $headers -State $state | Out-Null; [bool]$script:DaemonReconcileNow }
        $hit = Wait-CopilotHaStateChange -EntityIds $WatchEntities `
            -TimeoutSeconds $ReconcileSeconds -OnTick $fastLane -TickMilliseconds 100
        $script:DaemonWatchFailures = 0
    }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked']) { throw }
        # A normal timeout returns $null and is not an error; only a genuine
        # connection failure lands here. Back off exponentially (capped) so a
        # Home Assistant outage does not spin a tight reconnect loop.
        $script:DaemonWatchFailures++
        $backoff = [int][Math]::Min(2 * [Math]::Pow(2, $script:DaemonWatchFailures - 1), 60)
        Write-DaemonLog -Message "watch failed (attempt $($script:DaemonWatchFailures)): $($_.Exception.Message); retrying in ${backoff}s"
        Start-Sleep -Seconds $backoff
    }
    $hit
}

function Invoke-DaemonHit {
    # Acts at once on a press that should not wait for the reconcile.
    param($Hit, [hashtable]$Headers, [hashtable]$State)
    $hit = $Hit
    $headers = $Headers
    $state = $State
    if ($null -eq $hit) { return }

    # A reply from the dashboard is delivered before anything else. The reconcile
    # below would get to it too, but only after a string of unrelated Home
    # Assistant calls. The payload stamp and submit press are recorded before
    # delivery, so the reconcile's own pass cannot send it a second time.
    if ($hit.EntityId -match '_(reply|reply_payload|submit)$') {
        try {
            Invoke-PendingReplies -Headers $headers -State $state -Live $script:DaemonLive
        }
        catch {
            if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
            Write-DaemonLog -Message "reply delivery failed: $($_.Exception.Message)"
        }
    }

    # End session is acted on before the reconcile below, not inside it: the
    # reconcile then finds the session gone and drops its card in the same pass.
    # Inside the reconcile the stop came after the check for exited sessions, so
    # the card stayed up until the next pass.
    if ($hit.EntityId -match '_stop$') {
        try {
            Invoke-PendingStops -Headers $headers -State $state -Live $script:DaemonLive
        }
        catch {
            if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
            Write-DaemonLog -Message "end session failed: $($_.Exception.Message)"
        }
    }

    # Launch, likewise at once: its "Starting..." note is the feedback that the
    # press landed, and waiting for the next reconcile left it up to 15 s late.
    if ($hit.EntityId -eq $script:DaemonEntity.NewSession) {
        try {
            if ($null -eq $script:DaemonDiscoverySnapshot -or -not $script:DaemonDiscoverySnapshot.Complete) {
                Set-CopilotMqttNewSessionResult -Headers $headers -Text 'Session discovery is incomplete; launch is temporarily held.'
                return
            }
            $liveNow = if ($script:DaemonLive -is [hashtable]) { $script:DaemonLive } else { @{} }
            Sync-DaemonNewSession -Headers $headers -Live $liveNow
        }
        catch {
            if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
            Write-DaemonLog -Message "launch failed: $($_.Exception.Message)"
        }
    }
}

function Invoke-DaemonReconcile {
    # One authoritative pass over everything the daemon keeps in step.
    param([hashtable]$Headers, [hashtable]$State)
    $headers = $Headers
    $state = $State
    try {
        # The reconcile makes a string of Home Assistant calls, and a
        # transcript write that lands during it would otherwise wait for all of
        # them. The fast lane between steps costs a file-size check per session
        # when nothing changed.
        #
        # One read of every bridge entity up front, which the per-session checks
        # below answer from instead of asking for each one (Set-DaemonReconcileSnapshot).
        # It is cleared at the end of the pass rather than left to age, so nothing
        # outside a reconcile can read a value from one.
        Set-DaemonReconcileSnapshot -Headers $headers
        $discovery = Get-LiveBridgeSessions -AsObservation -State $state
        $live = $discovery.Live
        foreach ($phase in @('Legacy', 'Orphans')) {
            if ($script:DaemonSessionCleanupPending.ContainsKey($phase)) {
                [void](Invoke-DaemonStartupSessionCleanup -Headers $headers -State $state -Discovery $discovery -Phase $phase)
            }
        }
        Sync-DaemonSessions -Headers $headers -State $state -Live $live -Discovery $discovery
        Repair-CopilotSessionEntities -Headers $headers -State $state -Live $live
        Invoke-DaemonFastActivity -Headers $headers -State $state
        Invoke-PendingDecisions -Headers $headers -State $state -Live $live
        Invoke-PendingReplies -Headers $headers -State $state -Live $live
        Invoke-DaemonFastActivity -Headers $headers -State $state
        Invoke-PendingCodexApprovals -Headers $headers -State $state -Live $live
        Invoke-PendingStops -Headers $headers -State $state -Live $live
        Invoke-DaemonFastActivity -Headers $headers -State $state
        Sync-DaemonUpdateStatus -Headers $headers
        if ($discovery.Complete) { Sync-DaemonNewSession -Headers $headers -Live $live }
        Sync-DaemonClients -Headers $headers
        [void](Sync-DaemonUsage -Headers $headers)
        Clear-DaemonStaleNote -Headers $headers
        Invoke-DaemonFastActivity -Headers $headers -State $state
        Write-DaemonState -State $state
        # A pass that got this far talked to Home Assistant, so hooks can skip
        # their own reachability probe for a while (Test-HomeAssistantReachable),
        # and it is alive to publish what they record (Test-BridgeDaemonAlive).
        Set-BridgeHomeAssistantReachable
        Set-BridgeDaemonAlive
    }
    catch {
        if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
        Write-DaemonLog -Message "reconcile failed: $($_.Exception.Message)"
    }
    finally {
        # In finally so a pass that threw halfway does not leave its snapshot behind
        # for the tick path to read.
        Clear-DaemonReconcileSnapshot
    }
}

function Start-BridgeDaemon {
    $headers = Get-HomeAssistantHeaders
    $state = Read-DaemonState

    # Questions recorded by a previous daemon. Cleared here rather than where the
    # shared state is declared, so that loading this file for its functions cannot
    # unpin a running daemon's prompts.
    Clear-DaemonStopPrompts

    # Deliberately no pruning here. Sync-DaemonSessions retires anything that is no
    # longer live, which both removes its Home Assistant entities and drops it from
    # state. Pruning first would discard the record while leaving the published
    # entities behind as orphans.
    $discovery = Get-LiveBridgeSessions -AsObservation -State $state
    $live = $discovery.Live
    # Seed the fast lane, so streaming starts now rather than after the first reconcile.
    $script:DaemonLive = $live
    $script:DaemonDiscoverySnapshot = $discovery

    Initialize-DaemonStartup -Headers $headers -State $state -Live $live -Discovery $discovery
    Restore-DaemonSessionCards -Headers $headers -State $state -Live $live -Discovery $discovery
    Repair-CopilotSessionEntities -Headers $headers -State $state -Live $live
    Invoke-PendingDecisions -Headers $headers -State $state -Live $live
    Invoke-PendingReplies -Headers $headers -State $state -Live $live
    Invoke-PendingCodexApprovals -Headers $headers -State $state -Live $live
    Invoke-PendingStops -Headers $headers -State $state -Live $live
    Sync-DaemonUpdateStatus -Headers $headers
    if ($discovery.Complete) { Sync-DaemonNewSession -Headers $headers -Live $live }
    Write-DaemonState -State $state

    if ($RunOnce) {
        Write-DaemonLog -Message 'run-once complete'
        return
    }

    $lastReconcile = [DateTimeOffset]::Now

    while ($true) {
        $watchEntities = Get-DaemonWatchEntities -State $state
        $hit = Wait-DaemonChange -Headers $headers -State $state -WatchEntities $watchEntities
        Invoke-DaemonHit -Hit $hit -Headers $headers -State $state

        # A push hit only shortcuts latency; the sweep in the reconcile does the
        # authoritative delivery, so both paths funnel through the same guarded code.
        if (([DateTimeOffset]::Now - $lastReconcile).TotalSeconds -ge $ReconcileSeconds -or
            $null -ne $hit -or $script:DaemonReconcileNow) {
            $script:DaemonReconcileNow = $false
            Invoke-DaemonReconcile -Headers $headers -State $state
            $lastReconcile = [DateTimeOffset]::Now
            # Straight after the reconcile, when the collector holds most in reserve.
            try { $null = Invoke-DaemonMemoryTrim } catch { }

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

# The daemon's parts, each responsible for one area (see docs/daemon-split.md).
# Dot-sourced into this scope, so the $script: state declared above is shared.
. (Join-Path $PSScriptRoot 'daemon-agents.ps1')
. (Join-Path $PSScriptRoot 'daemon-discovery.ps1')
. (Join-Path $PSScriptRoot 'daemon-activity.ps1')
. (Join-Path $PSScriptRoot 'daemon-sessions.ps1')
. (Join-Path $PSScriptRoot 'daemon-replies.ps1')
. (Join-Path $PSScriptRoot 'daemon-decisions.ps1')
. (Join-Path $PSScriptRoot 'daemon-launch.ps1')
. (Join-Path $PSScriptRoot 'daemon-maintenance.ps1')
. (Join-Path $PSScriptRoot 'daemon-usage.ps1')
. (Join-Path $PSScriptRoot 'daemon-hookspool.ps1')


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
        Register-BridgeRuntimeProcess -Context $script:BridgeInstallContext -Role daemon
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
