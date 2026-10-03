<#
    Shared configuration and helpers for the AI coding agent <-> Home Assistant bridge.

    Machine-specific settings live in the bridge's own root rather than under
    ~/.copilot, which belongs to the Copilot CLI - it parses every *.json under
    ~/.copilot/hooks as a hook definition and logs a startup error for anything that is
    not one. Resolution order:

        1. $env:AGENT_HA_BRIDGE_CONFIG              (explicit override)
        2. ~/.agent-ha-bridge/config.json           (what install.ps1 writes)
        3. $env:COPILOT_HA_BRIDGE_CONFIG            (pre-rename override)
        4. ~/.copilot/copilot-ha-bridge.config.json (pre-rename location)

    The last two keep a not-yet-migrated install working; install.ps1 moves the file
    to its new home on upgrade.

    Everything in the file is optional; anything absent falls back to the defaults
    below. See config.example.json in the repository root.
#>

# Windows/macOS differences (the temporary folder, process lookups, tmux), first so
# everything below can rely on them.
. (Join-Path $PSScriptRoot 'bridge-platform.ps1')
. (Join-Path $PSScriptRoot 'bridge-test-guard.ps1')

# The three per-launch settings the dashboard can set on a new session, in the order
# it shows them. Kept here, with the rest of the shared vocabulary, because three
# separate layers need the same names: session-launch.ps1 turns a value into command
# line flags, decision-mqtt.ps1 publishes a selector per axis, and
# decision-ha-websocket.ps1 draws a row per axis.
#
# Three axes rather than one combined "quality" knob because the agents treat them as
# independent: a long context costs nothing in thinking time, and a high effort costs
# nothing in context.
#
#   Label   shown on the launch card
#   Icon    its selector's icon
$script:BridgeTuningAxes = [ordered]@{
    model   = @{ Label = 'Model';   Icon = 'mdi:chip' }
    effort  = @{ Label = 'Effort';  Icon = 'mdi:speedometer' }
    context = @{ Label = 'Context'; Icon = 'mdi:arrow-expand-horizontal' }
}

# The option every axis opens on: launch without passing the flag at all, so the agent
# uses whatever it has persisted. An MQTT select cannot hold an empty value, so "don't
# pass anything" has to be an option like any other, and it is deliberately first so an
# untouched card launches exactly as it did before this existed.
$script:BridgeTuningDefaultOption = 'Agent default'

# Whether a launched session may act without stopping to ask. Published as a selector
# beside the tuning axes rather than read only from the launching machine's config,
# because the machine that runs the session is not always the one choosing: a session
# started on a Mac from a Windows dashboard silently took the Mac's
# newSession.allowAllTools, which the person pressing Launch could neither see nor
# change.
#
# Two named options rather than a switch entity: every other launch control is a
# select, so the launch card fills and reads this one with the code it already has.
# 'Ask permission' is first, so an untouched card is the cautious one.
$script:BridgePermissionAskOption = 'Ask permission'
$script:BridgePermissionAllowOption = 'Allow all'

function Get-BridgePermissionOptions {
    <# Both options, cautious one first - which is also the selector's default. #>
    @($script:BridgePermissionAskOption, $script:BridgePermissionAllowOption)
}

function Get-BridgePermissionLabel {
    <# The option that stands for a given allow-all setting. #>
    param([bool]$AllowAllTools)
    if ($AllowAllTools) { return $script:BridgePermissionAllowOption }
    $script:BridgePermissionAskOption
}

function Test-BridgePermissionAllowsAll {
    <#
        Whether a selector value means "launch without permission prompts".

        Only the exact 'Allow all' option does, case included. Anything else - unknown,
        unavailable, a value from an older bridge, an empty entity on a machine that
        has not published the selector yet - reads as asking, so the failure mode of
        every unclear case is a session that stops to ask rather than one handed
        blanket approval nobody chose. -ceq rather than -eq for the same reason: the
        options are published by Get-BridgePermissionOptions and come back exactly as
        sent, so a differently-cased value did not come from this control, and erring
        towards asking costs a prompt while erring the other way costs the safeguard.
    #>
    param([AllowEmptyString()][AllowNull()][string]$Value)
    ([string]$Value).Trim() -ceq $script:BridgePermissionAllowOption
}

function Get-BridgeTuningAxes {
    <# The axis keys, in display order. #>
    @($script:BridgeTuningAxes.Keys | ForEach-Object { [string]$_ })
}

function Get-BridgeTuningAxisLabel {
    param([Parameter(Mandatory)][string]$Axis)
    if ($script:BridgeTuningAxes.Contains($Axis)) { return [string]$script:BridgeTuningAxes[$Axis].Label }
    $Axis
}

function Get-BridgeTuningAxisIcon {
    param([Parameter(Mandatory)][string]$Axis)
    if ($script:BridgeTuningAxes.Contains($Axis)) { return [string]$script:BridgeTuningAxes[$Axis].Icon }
    'mdi:tune'
}

function Get-BridgeUserConfig {
    $context = Resolve-BridgeInstallContext -EntryDirectory $PSScriptRoot
    $path = $context.ConfigPath
    if (-not (Test-Path -LiteralPath $path)) {
        if ($context.ExplicitConfig -or $context.Recorded -or -not $context.Legacy) { throw "The selected bridge configuration is missing: $path" }
        return $null
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($raw)) { return ($raw | ConvertFrom-Json) }
        throw 'Empty configuration.'
    }
    catch {
        throw "Agent HA bridge config at '$path' could not be read as JSON."
    }
}

$script:BridgeInstallContext = Resolve-BridgeInstallContext -EntryDirectory $PSScriptRoot
$script:BridgeUserConfig = Get-BridgeUserConfig

function Get-BridgeSetting {
    <#
        Reads a dotted path out of the user config, returning $Default when the file,
        the section or the value is absent.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        $Default = $null
    )

    $node = $script:BridgeUserConfig
    if ($null -eq $node) { return $Default }
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $node) { return $Default }
        $prop = $node.PSObject.Properties[$part]
        if ($null -eq $prop) { return $Default }
        $node = $prop.Value
    }
    if ($null -eq $node) { return $Default }
    if ($node -is [string] -and [string]::IsNullOrWhiteSpace($node)) { return $Default }
    $node
}

$script:DecisionBridgeConfig = @{
    # --- machine specific, overridable from the config file -------------------
    HomeAssistantBaseUrl = (Get-BridgeSetting 'homeAssistant.baseUrl' 'http://homeassistant.local:8123')
    HomeAssistantToken = (Get-BridgeSetting 'homeAssistant.token' '')
    HomeAssistantTokenEnvVar = (Get-BridgeSetting 'homeAssistant.tokenEnvVar' 'AGENT_HA_TOKEN')
    # The token an *agent* drives the bridge with, which is a different account from
    # the one above - see Get-BridgeAgentToken.
    HomeAssistantAgentToken = (Get-BridgeSetting 'homeAssistant.agentToken' '')
    HomeAssistantAgentTokenEnvVar = (Get-BridgeSetting 'homeAssistant.agentTokenEnvVar' 'AGENT_HA_AGENT_TOKEN')
    SessionStateRoot = (Get-BridgeSetting 'copilot.sessionStateRoot' (Join-Path $script:BridgeInstallContext.CopilotHome 'session-state'))
    DashboardUrlPath = (Get-BridgeSetting 'dashboard.urlPath' 'agent-decisions')
    DashboardPath = ('/' + (Get-BridgeSetting 'dashboard.urlPath' 'agent-decisions') + '/decision')
    # Notifications are optional. `service` is any HA notify-style service, e.g.
    # notify.notify, notify.mobile_app_pixel, or ticker.notify.
    NotifyEnabled = [bool](Get-BridgeSetting 'notifications.enabled' $false)
    NotifyService = (Get-BridgeSetting 'notifications.service' 'notify.notify')
    TickerCategory = (Get-BridgeSetting 'notifications.tickerCategory' '')

    # --- behaviour, rarely changed -------------------------------------------
    DecisionQuestionMaxChars = 6000
    DecisionChoiceMaxChars = 600
    ResponsePlaceholder = 'Select an answer...'
    CancelOption = 'Cancel request'
    LogFile = (Get-BridgeRuntimePath 'agent-decision-bridge.log')
    HttpRetryCount = 4
    HttpRetryInitialDelayMs = 400
    # How long the ask_user wait tolerates an unreachable Home Assistant before it
    # gives up. A restart of Home Assistant takes well under this.
    WaitTransientFailureGraceMinutes = 5
}

if ($script:BridgeInstallContext.Isolated -and
    -not (Test-BridgeInstallDescendant $script:DecisionBridgeConfig.SessionStateRoot $script:BridgeInstallContext.Home)) {
    throw 'An isolated installation cannot read session state outside its target home.'
}

# How long to stay away from Home Assistant after it rejects the bridge's credentials,
# and how far that grows while it keeps rejecting them.
#
# Home Assistant bans an IP after `login_attempts_threshold` failed logins (10 by
# default), and a successful login resets its count - so what is dangerous is not one
# rejection but a steady stream of them with no success in between, which is exactly
# what a daemon reconciling every 15 seconds produces. Six calls a cycle sits four
# short of the threshold; anything else on the machine failing auth at the same time
# closes the gap. Backing off is the whole mitigation: while the bridge says nothing,
# the count cannot rise.
$script:BridgeAuthBackoffSteps = @(60, 300, 900)
$script:BridgeAuthBackoffUntil = $null
$script:BridgeAuthBackoffStep = -1

function Get-BridgeAuthTime {
    # A single clock for the hold-off, replaceable by deterministic regression tests.
    [DateTimeOffset]::Now
}

function Get-BridgeAuthBackoffSeconds {
    <#
        Seconds left before the bridge should speak to Home Assistant again, or 0 when
        it may. Reading it after the window has passed clears it.
    #>
    if ($null -eq $script:BridgeAuthBackoffUntil) { return 0 }
    $left = ($script:BridgeAuthBackoffUntil - (Get-BridgeAuthTime)).TotalSeconds
    if ($left -le 0) {
        $script:BridgeAuthBackoffUntil = $null
        return 0
    }
    [int][Math]::Ceiling($left)
}

function Register-BridgeAuthRejected {
    <#
        Records that Home Assistant refused the bridge's credentials, and holds every
        further call off for a growing window.

        Says so in the log, once per window rather than once per call, and names the
        ban explicitly: the daemon used to report nothing but `403 (Forbidden)` over
        and over, which reads like a bad token and is not one. The distinction matters
        because the remedies are opposites - a token is replaced, a ban is cleared -
        and because an IP ban survives restarting Home Assistant, which is the first
        thing anyone tries.
    #>
    param(
        [AllowEmptyString()][string]$Detail = '',

        # A refusal at the HTTP layer rather than a refused token: Home Assistant
        # answers a banned address before it ever looks at credentials.
        [switch]$Banned
    )

    # Already holding off; do not let a burst of six calls push the window out six
    # times, and do not log six times either.
    if ((Get-BridgeAuthBackoffSeconds) -gt 0) { return }

    if ($script:BridgeAuthBackoffStep -lt ($script:BridgeAuthBackoffSteps.Count - 1)) {
        $script:BridgeAuthBackoffStep++
    }
    $seconds = $script:BridgeAuthBackoffSteps[$script:BridgeAuthBackoffStep]
    $script:BridgeAuthBackoffUntil = (Get-BridgeAuthTime).AddSeconds($seconds)

    $what = if ($Banned) {
        'Home Assistant refused this machine outright, which is what it does to a banned address'
    }
    else {
        "Home Assistant rejected the bridge's token"
    }
    $tail = if ($Banned) {
        'A ban is written to /config/ip_bans.yaml and read back at startup, so restarting Home Assistant does not lift it - the file has to be emptied.'
    }
    else {
        'Repeating a rejected login is what gets an IP banned, so nothing more will be sent until then.'
    }
    $suffix = if ([string]::IsNullOrWhiteSpace($Detail)) { '' } else { " ($Detail)" }
    Write-BridgeAuthBackoffLog -Message "$what$suffix. Holding off for ${seconds}s. $tail"
}

function Register-BridgeAuthAccepted {
    <#
        Home Assistant accepted the bridge again, which also resets its own count of
        failed logins - so the window and its growth start over.
    #>
    if ($null -eq $script:BridgeAuthBackoffUntil -and $script:BridgeAuthBackoffStep -lt 0) { return }
    if ($null -ne $script:BridgeAuthBackoffUntil) {
        Write-BridgeAuthBackoffLog -Message 'Home Assistant accepted the bridge again.'
    }
    $script:BridgeAuthBackoffUntil = $null
    $script:BridgeAuthBackoffStep = -1
}

function Write-BridgeAuthBackoffLog {
    <#
        The daemon's log when there is one, the bridge log otherwise - so this is seen
        wherever it happens without the library having to know who loaded it.
    #>
    param([Parameter(Mandatory)][string]$Message)

    try {
        $daemonLog = Get-Command Write-DaemonLog -ErrorAction SilentlyContinue
        if ($daemonLog) { & $daemonLog -Message $Message; return }
        Write-DecisionBridgeLog -Message $Message
    }
    catch { }
}

function Assert-BridgeAuthAllowed {
    <#
        Refuses a call while the bridge is holding off, without touching the network -
        the point being that Home Assistant never sees it and its failed-login count
        stays where it is.
    #>
    $left = Get-BridgeAuthBackoffSeconds
    if ($left -gt 0) {
        throw [UnauthorizedAccessException]::new(
            "Home Assistant rejected the bridge's credentials; not retrying for ${left}s.")
    }
}

function Test-BridgeAuthRejection {
    <#
        Whether a failed request was refused for who the bridge is, rather than for
        anything retrying could fix. 401 is a rejected token; Home Assistant answers a
        banned address with 403.

        Returns '' for anything else, 'token' or 'banned' otherwise.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $response = $null
    if ($ErrorRecord.Exception.PSObject.Properties['Response']) {
        $response = $ErrorRecord.Exception.Response
    }
    $status = 0
    if ($null -ne $response) {
        try { $status = [int]$response.StatusCode } catch { $status = 0 }
    }
    if ($status -eq 0) {
        # A WebSocket upgrade refused before it is established carries its status in
        # the message rather than in a Response.
        $message = [string]$ErrorRecord.Exception.Message
        if ($message -match "status code '(\d{3})'") { $status = [int]$Matches[1] }
    }

    switch ($status) {
        401 { 'token' }
        403 { 'banned' }
        default { '' }
    }
}

function Test-DecisionTransientHttpError {
    <#
        True for the failures a Home Assistant restart produces - connection refused,
        timeouts, DNS blips and 5xx - as opposed to a real error like a bad token or a
        missing entity, which retrying cannot fix.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    # Not every exception carries a Response: a connection that was refused outright -
    # exactly what a restarting Home Assistant produces - throws without one. Reading
    # it unguarded under Set-StrictMode -Version Latest threw "The property 'Response'
    # cannot be found on this object" from inside the very check meant to say "retry
    # this", so the caller treated a restart as a permanent failure.
    $response = $null
    if ($ErrorRecord.Exception.PSObject.Properties['Response']) {
        $response = $ErrorRecord.Exception.Response
    }
    if ($null -ne $response) {
        $status = 0
        try { $status = [int]$response.StatusCode } catch { $status = 0 }
        if ($status -ge 500 -or $status -eq 429) { return $true }
        if ($status -gt 0) { return $false }
    }

    $message = [string]$ErrorRecord.Exception.Message
    foreach ($pattern in @(
        'actively refused',
        'Unable to connect',
        'timed out',
        'HttpClient\.Timeout',
        'The operation has timed out',
        'Unable to read data from the transport connection',
        'The underlying connection was closed',
        'An existing connection was forcibly closed',
        'No such host is known'
    )) {
        if ($message -match $pattern) { return $true }
    }

    $false
}

# No deadline unless a caller sets one. This must be initialised rather than left
# undefined: under Set-StrictMode -Version Latest, reading an unset variable throws,
# which would make every caller that does not set a budget - the daemon included -
# fail inside the retry layer.
$script:DecisionBridgeDeadline = $null

function Test-HomeAssistantReachable {    <#
        Cheap liveness probe, used by hooks before they commit to any Home Assistant
        work.

        A flat budget cannot serve both cases: the healthy publish path legitimately
        takes many seconds (discovery, a registry rename over WebSocket, then arming),
        while an unreachable host must not cost more than a moment because a PreToolUse
        hook runs before the native prompt appears. Probing first separates them - a
        host that is gone is detected in about a second, and only a host that answers
        earns the longer budget.

        Deliberately single-shot with no retry: this is a reachability question, not a
        request worth salvaging.
    #>
    param([int]$TimeoutSec = 2)

    # Answered recently - by the daemon's last pass or another hook - so no new probe:
    # it cost every hook about 100 ms, which Claude and Codex wait for.
    try {
        $age = ([DateTime]::UtcNow - [IO.File]::GetLastWriteTimeUtc((Get-BridgeReachableMarker))).TotalSeconds
        if ($age -ge 0 -and $age -lt $script:BridgeReachableFreshSeconds) { return $true }
    }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked']) { throw }
    }

    $uri = "$($script:DecisionBridgeConfig.HomeAssistantBaseUrl)/api/"
    Assert-BridgeHttpAllowed -Uri $uri
    try {
        $null = Invoke-RestMethod -Uri $uri `
            -Headers (Get-HomeAssistantHeaders) -TimeoutSec $TimeoutSec
        Set-BridgeHomeAssistantReachable
        return $true
    }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked']) { throw }
        return $false
    }
}

# How long a successful contact with Home Assistant vouches for it. The daemon renews
# it every 15-second pass, so a hook almost never probes; kept short, because a hook
# that trusts a stale answer spends its budget on a host that has gone.
$script:BridgeReachableFreshSeconds = 20

function Get-BridgeReachableMarker { Get-BridgeRuntimePath 'agent-bridge-ha-reachable' }

function Set-BridgeHomeAssistantReachable {
    <# Records that Home Assistant just answered. Best effort. #>
    try { [IO.File]::WriteAllText((Get-BridgeReachableMarker), [DateTimeOffset]::Now.ToString('o')) }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked']) { throw }
    }
}

function Get-BridgeDaemonHeartbeat { Get-BridgeRuntimePath 'agent-bridge-daemon.heartbeat' }

function Set-BridgeDaemonAlive {
    <# The daemon's heartbeat, written each pass. Best effort. #>
    try {
        [void][IO.Directory]::CreateDirectory((Get-BridgeRuntimeRoot))
        [IO.File]::WriteAllText((Get-BridgeDaemonHeartbeat), [string]$PID)
    }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked']) { throw }
    }
}

function Get-BridgeDaemonPid {
    <#
        The running daemon's process id, taken from the heartbeat it writes each pass.

        Finding it by command line instead costs 272 ms on Windows: CommandLine lives
        only on Win32_Process, and filtering that walks every process on the machine.
        The daemon already records its own pid, so the scan is only needed when that
        record is missing, stale, or points at something that is no longer it.

        Returns 0 when the heartbeat cannot answer, and the caller falls back to the
        scan rather than reporting the daemon as stopped.
    #>
    try {
        $path = Get-BridgeDaemonHeartbeat
        if (([DateTime]::UtcNow - [IO.File]::GetLastWriteTimeUtc($path)).TotalSeconds -ge 60) { return 0 }
        $id = 0
        if (-not [int]::TryParse(([IO.File]::ReadAllText($path)).Trim(), [ref]$id)) { return 0 }
        if ($id -le 0) { return 0 }
        $proc = Get-BridgeRuntimeProcess -ProcessId $id -Context (Get-BridgeInstallContext) -Role daemon
        if ($null -eq $proc) { return 0 }
        $id
    }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked']) { throw }
        0
    }
}

function Test-BridgeDaemonAlive {
    <#
        Whether the daemon has completed a pass in the last minute - so a hook can leave
        publishing to it rather than make the agent wait on Home Assistant. A stopped
        daemon goes stale, and the hooks go back to publishing themselves.
    #>
    # AGENT_BRIDGE_HOOKS_PUBLISH makes hooks publish regardless, for tests that run
    # them against Home Assistant beside a running daemon.
    if ($env:AGENT_BRIDGE_HOOKS_PUBLISH) { return $false }
    try { ([DateTime]::UtcNow - [IO.File]::GetLastWriteTimeUtc((Get-BridgeDaemonHeartbeat))).TotalSeconds -lt 60 }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked']) { throw }
        $false
    }
}

function Set-DecisionBridgeDeadline {
    <#
        Bounds how long the Home Assistant calls in this process may take in total.

        The retry layer exists so a blip cannot break a live question, but in a hook
        that resilience becomes latency: with Home Assistant unreachable the routers
        took 19-34 seconds, and a PreToolUse hook that slow delays the very prompt the
        bridge promises never to block. Hooks therefore set a hard budget and fail open
        the moment it is spent; the daemon, which has time, sets none.

        Pass 0 to clear it.
    #>
    param([Parameter(Mandatory)][int]$Seconds)

    $script:DecisionBridgeDeadline = if ($Seconds -gt 0) {
        [DateTimeOffset]::Now.AddSeconds($Seconds)
    } else { $null }
}

function Get-DecisionBridgeRemainingSeconds {
    if ($null -eq $script:DecisionBridgeDeadline) { return [double]::PositiveInfinity }
    [Math]::Max(0, ($script:DecisionBridgeDeadline - [DateTimeOffset]::Now).TotalSeconds)
}

$script:BridgeHttpSession = $null

function Get-BridgeHttpSession {
    <#
        One WebRequestSession shared by every call this process makes.

        Invoke-RestMethod builds a fresh session for each call it is not given one,
        and with it a fresh connection pool, so every request paid a new TCP connect
        and a full TLS handshake. On the LAN that is a few milliseconds and invisible,
        which is why it went unnoticed; over a Cloudflare tunnel it was measured at
        60-75 ms a call against 23-26 ms once the connection is reused, on a daemon
        that makes roughly eight calls every fifteen seconds.

        Holding the session is what keeps the connection alive between calls. A
        connection dropped in the meantime - Home Assistant restarting, a tunnel
        reconnecting - surfaces as a transient error, which is precisely what the
        retry loop below already exists to absorb.
    #>
    if ($null -eq $script:BridgeHttpSession) {
        $script:BridgeHttpSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    }
    $script:BridgeHttpSession
}

function Test-BridgeHttpSessionSupported {
    <#
        Whether the Invoke-RestMethod in scope can be handed a WebSession.

        Suites replace it with stubs, and those stubs declare their own parameters -
        test-decision-retry.ps1 uses a bare param(), test-http-guard.ps1 names six.
        Splatting WebSession at either is a binding error, so a change meant to save
        a TLS handshake would instead have failed every suite that drives this retry
        layer. Only the real cmdlet is given one; a stub is called exactly as before.
    #>
    if (-not $script:BridgeUnderTestSuite) { return $true }
    $sender = Get-Command -Name 'Invoke-RestMethod' -ErrorAction SilentlyContinue
    [bool]($sender -and $sender.CommandType -eq [Management.Automation.CommandTypes]::Cmdlet)
}

function Invoke-DecisionHttpRequest {
    <#
        Wraps Invoke-RestMethod with bounded exponential backoff.

        Without this a single transient failure - a Home Assistant restart, a Wi-Fi
        blip - propagated out of the eight hour ask_user wait, the hook failed open,
        and the CLI re-prompted the same question while the dashboard card was still
        live. Two answer paths for one question.

        When a deadline is set the retries are also bounded by wall clock, and each
        request's own timeout is clamped to what is left, so the caller can never
        overrun its budget waiting on a host that is simply gone.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Parameters,

        [int]$RetryCount = $script:DecisionBridgeConfig.HttpRetryCount
    )

    Assert-BridgeHttpAllowed -Uri ([string]$Parameters['Uri'])
    Assert-BridgeAuthAllowed

    $delayMs = $script:DecisionBridgeConfig.HttpRetryInitialDelayMs
    for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
        $remaining = Get-DecisionBridgeRemainingSeconds
        if ($remaining -le 0) {
            throw [TimeoutException]::new('Home Assistant budget for this hook is spent.')
        }

        # Copied rather than mutated: callers hold one parameter hashtable and reuse it
        # across calls, so both the clamped timeout and the shared session below would
        # otherwise leak back into theirs.
        $call = @{} + $Parameters
        if ([double]::IsFinite($remaining)) {
            $requested = if ($call.ContainsKey('TimeoutSec')) { [int]$call['TimeoutSec'] } else { 15 }
            $call['TimeoutSec'] = [Math]::Max(1, [Math]::Min($requested, [int][Math]::Floor($remaining)))
        }
        if (-not $call.ContainsKey('WebSession') -and (Test-BridgeHttpSessionSupported)) {
            $call['WebSession'] = Get-BridgeHttpSession
        }

        try {
            $answer = Invoke-RestMethod @call
            Register-BridgeAuthAccepted
            return $answer
        }
        catch {
            # A refusal of the bridge itself is never retried, and stops the next call
            # being made at all: repeating a rejected login is precisely what takes a
            # machine from "one failure" to banned.
            $rejection = Test-BridgeAuthRejection -ErrorRecord $_
            if ($rejection) {
                Register-BridgeAuthRejected -Detail ([string]$Parameters['Uri']) -Banned:($rejection -eq 'banned')
                throw
            }
            $isLast = $attempt -ge $RetryCount
            if ($isLast -or -not (Test-DecisionTransientHttpError -ErrorRecord $_)) {
                throw
            }
            # No point sleeping into a deadline that will already have passed.
            if ((Get-DecisionBridgeRemainingSeconds) * 1000 -le $delayMs) {
                throw [TimeoutException]::new('Home Assistant budget for this hook is spent.')
            }
            Start-Sleep -Milliseconds $delayMs
            $delayMs = [Math]::Min($delayMs * 2, 5000)
        }
    }
}

function Write-DecisionBridgeLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    $timestamp = [DateTimeOffset]::Now.ToString('o')
    Add-Content -LiteralPath $script:DecisionBridgeConfig.LogFile -Value "$timestamp $Message"
}

function Split-CardText {
    <#
        Splits long card text into a short preview and the remainder, breaking on a
        paragraph boundary (then a sentence, then a word) rather than mid-word, so the
        dashboard's expandable "show more" never cuts through the middle of a word.

        Returns a hashtable with Preview and Rest. When the text is already short, Rest
        is empty and the whole text is the preview.
    #>
    param(
        [AllowNull()][string]$Text,
        [int]$TargetChars = 260
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @{ Preview = ''; Rest = '' }
    }
    $t = ($Text -replace "`r`n", "`n").Trim()
    if ($t.Length -le $TargetChars) {
        return @{ Preview = $t; Rest = '' }
    }

    $split = Split-CardTextCore -Text $t -TargetChars $TargetChars

    # A split that lands inside a fenced code block leaves the preview holding an
    # unclosed ``` fence, so everything after it - including the <details> markup the
    # card wraps the remainder in - renders as literal code. Close the fence at the end
    # of the preview and reopen it at the start of the remainder so both halves are
    # valid markdown on their own.
    $fenceCount = ([regex]::Matches($split.Preview, '(?m)^\s*```')).Count
    if ($fenceCount % 2 -eq 1) {
        $fence = '```'
        $split.Preview = $split.Preview.TrimEnd() + "`n" + $fence
        if (-not [string]::IsNullOrWhiteSpace($split.Rest)) {
            $split.Rest = $fence + "`n" + $split.Rest
        }
    }

    $split
}

function Split-CardTextCore {
    <#
        The paragraph/sentence/word boundary search behind Split-CardText. Kept
        separate so the fence-balancing above can post-process its result.
    #>
    param(
        [AllowNull()][string]$Text,
        [int]$TargetChars = 260
    )

    $t = $Text

    # Prefer whole paragraphs: keep adding paragraphs to the preview while they fit
    # under the target (with a little slack), so the break lands between paragraphs.
    $paragraphs = @(
        [regex]::Split($t, "`n\s*`n") | ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' }
    )
    $slack = 140
    if ($paragraphs.Count -gt 1) {
        $preview = ''
        $restList = New-Object System.Collections.Generic.List[string]
        $filling = $true
        foreach ($p in $paragraphs) {
            if ($filling) {
                if ($preview -eq '') {
                    $preview = $p
                }
                elseif (($preview.Length + 2 + $p.Length) -le ($TargetChars + $slack)) {
                    $preview = "$preview`n`n$p"
                }
                else {
                    $filling = $false
                    $restList.Add($p)
                }
            }
            else {
                $restList.Add($p)
            }
        }
        if ($restList.Count -gt 0) {
            return @{ Preview = $preview.Trim(); Rest = ($restList -join "`n`n").Trim() }
        }
        # One big paragraph absorbed everything; fall through to break it below.
        $t = $preview
    }

    # A single long paragraph: break at the last sentence end, else the last space,
    # within a window around the target, so no word is split.
    $windowEnd = [Math]::Min($t.Length, $TargetChars + $slack)
    $window = $t.Substring(0, $windowEnd)
    $floor = [Math]::Max(1, $TargetChars - $slack)

    $cut = -1
    foreach ($m in [regex]::Matches($window, '[.!?]["'')\]]?\s')) {
        if ($m.Index + 1 -ge $floor) { $cut = $m.Index + $m.Length; break }
    }
    if ($cut -lt 0) {
        $sp = $window.LastIndexOf(' ')
        if ($sp -ge $floor) { $cut = $sp }
    }
    if ($cut -lt 0) { $cut = $TargetChars }

    @{ Preview = $t.Substring(0, $cut).Trim(); Rest = $t.Substring($cut).Trim() }
}

function Repair-DecisionTextEncoding {
    param(
        [AllowNull()]
        [string]$Text
    )

    if (
        [string]::IsNullOrEmpty($Text) -or
        $Text -notmatch 'ΓÇ|Γé|├|┬|ÔÇ'
    ) {
        return $Text
    }

    try {
        $bytes = [Text.Encoding]::GetEncoding(437).GetBytes($Text)
        $decoded = [Text.Encoding]::UTF8.GetString($bytes)
        if ($decoded.Contains([char]0xFFFD)) {
            return $Text
        }
        return $decoded
    }
    catch {
        return $Text
    }
}

function ConvertFrom-DecisionChoiceList {
    <#
        Parses a leaked `choices` payload, which arrives as the JSON array literal the
        model meant to pass as a real argument. Falls back to scanning complete quoted
        strings when the array is unterminated, because a tool call cut off mid-write
        is exactly the case this recovers from.
    #>
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $start = $Text.IndexOf('[')
    if ($start -lt 0) {
        return @()
    }
    $payload = $Text.Substring($start)

    $end = $payload.LastIndexOf(']')
    if ($end -gt 0) {
        try {
            # Windows PowerShell 5.1 emits a parsed JSON array as a single nested
            # object rather than unrolling it, so flatten one level explicitly.
            $parsed = $payload.Substring(0, $end + 1) | ConvertFrom-Json
            $items = New-Object System.Collections.Generic.List[string]
            foreach ($entry in @($parsed)) {
                if ($entry -is [System.Collections.IEnumerable] -and $entry -isnot [string]) {
                    foreach ($inner in $entry) {
                        $items.Add([string]$inner)
                    }
                }
                else {
                    $items.Add([string]$entry)
                }
            }

            $items = @($items | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($items.Count -gt 0) {
                return $items
            }
        }
        catch {
            # Malformed JSON falls through to the lenient scan below.
        }
    }

    $quoted = [regex]::Matches($payload, '"((?:[^"\\]|\\.)*)"')
    $recovered = foreach ($item in $quoted) {
        $value = $item.Groups[1].Value
        try {
            [string]("`"$value`"" | ConvertFrom-Json)
        }
        catch {
            $value -replace '\\"', '"' -replace '\\\\', '\'
        }
    }

    @($recovered | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function ConvertFrom-DecisionRequestedSchema {
    <#
        Derives a choice list from an `ask_user` `requestedSchema`.

        Current Copilot CLI builds pass `message` + `requestedSchema` (a JSON Schema
        form) instead of the older `question` + `choices` pair. Without this the bridge
        found no `choices`, published a free-text box for what was really a multiple
        choice, and — because it also found no `question` — titled the card
        "Copilot CLI needs your input."

        The dashboard renders one question with one option list, so only a
        single-field form can become choice buttons. Multi-field forms and free-text
        fields deliberately return nothing and stay freeform.
    #>
    param(
        [AllowNull()]
        [psobject]$Schema
    )

    if ($null -eq $Schema) { return @() }
    $properties = $Schema.properties
    if ($null -eq $properties) { return @() }

    $names = @($properties.PSObject.Properties.Name)
    if ($names.Count -ne 1) { return @() }

    @(Get-DecisionSchemaFieldOptions -Field $properties.($names[0]))
}

function ConvertFrom-DecisionJson {
    <# Decision values are JSON values, not inferred dates. Keep container shape,
       including null and singleton array entries, on supported PowerShell versions. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)

    $textReader = [IO.StringReader]::new($Json)
    $reader = [Newtonsoft.Json.JsonTextReader]::new($textReader)
    try {
        $reader.DateParseHandling = [Newtonsoft.Json.DateParseHandling]::None
        $reader.MaxDepth = 64
        $settings = [Newtonsoft.Json.Linq.JsonLoadSettings]::new()
        $settings.DuplicatePropertyNameHandling = [Newtonsoft.Json.Linq.DuplicatePropertyNameHandling]::Error
        $token = [Newtonsoft.Json.Linq.JToken]::ReadFrom($reader, $settings)
        while ($reader.Read()) {
            if ($reader.TokenType -ne [Newtonsoft.Json.JsonToken]::Comment) {
                throw [IO.InvalidDataException]::new('Unexpected trailing decision JSON.')
            }
        }
        $convert = {
            param([Newtonsoft.Json.Linq.JToken]$Item)
            switch ($Item.get_Type().ToString()) {
                'Object' {
                    $properties = [ordered]@{}
                    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                    foreach ($property in $Item.Properties()) {
                        $name = $property.get_Name()
                        if ([string]::IsNullOrEmpty($name) -or -not $names.Add($name)) {
                            throw [IO.InvalidDataException]::new('Decision JSON has an ambiguous property name.')
                        }
                        $properties[$name] = & $convert ($property.get_Value())
                    }
                    return [pscustomobject]$properties
                }
                'Array' {
                    $items = [object[]]::new($Item.get_Count())
                    for ($index = 0; $index -lt $Item.get_Count(); $index++) {
                        $items[$index] = & $convert ($Item.get_Item($index))
                    }
                    return ,$items
                }
                'String' { return [string]$Item.get_Value() }
                'Boolean' { return [bool]$Item.get_Value() }
                'Integer' { return $Item.get_Value() }
                'Float' {
                    $number = $Item.get_Value()
                    if ([double]::IsNaN([double]$number) -or [double]::IsInfinity([double]$number)) {
                        throw [IO.InvalidDataException]::new('Decision JSON has a non-finite number.')
                    }
                    return $number
                }
                'Null' { return $null }
                default { throw [IO.InvalidDataException]::new('Unsupported decision JSON token.') }
            }
        }
        $value = & $convert $token
        return ,$value
    }
    finally {
        $reader.Dispose()
        $textReader.Dispose()
    }
}

function ConvertFrom-DecisionSchemaText {
    <#
        Parses a `requestedSchema` payload that leaked into the question string as raw
        text, including the common case where the tool call was cut off mid-write and
        the JSON is unterminated. Unbalanced braces and brackets are closed off before
        parsing, which is enough to recover the option list from a truncated form.
    #>
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $start = $Text.IndexOf('{')
    if ($start -lt 0) { return $null }
    $payload = $Text.Substring($start)

    # Walk the payload tracking string state so closers inside strings are ignored.
    $stack = New-Object System.Collections.Generic.Stack[char]
    $inString = $false
    $escaped = $false
    $lastSafe = -1
    for ($i = 0; $i -lt $payload.Length; $i++) {
        $ch = $payload[$i]
        if ($escaped) { $escaped = $false; continue }
        if ($ch -eq '\') { if ($inString) { $escaped = $true }; continue }
        if ($ch -eq '"') { $inString = -not $inString; continue }
        if ($inString) { continue }

        switch ($ch) {
            '{' { $stack.Push('}') }
            '[' { $stack.Push(']') }
            '}' { if ($stack.Count -gt 0) { [void]$stack.Pop() } }
            ']' { if ($stack.Count -gt 0) { [void]$stack.Pop() } }
        }
        if ($stack.Count -eq 0) { $lastSafe = $i }
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($lastSafe -ge 0) {
        $candidates.Add($payload.Substring(0, $lastSafe + 1))
    }
    if ($stack.Count -gt 0) {
        # Trim a dangling partial token, then close every open container.
        $trimmed = $payload.TrimEnd()
        $trimmed = $trimmed -replace '(?s),\s*"[^"]*"?\s*:?\s*$', ''
        $trimmed = $trimmed -replace '(?s),\s*$', ''
        if ($inString) { $trimmed += '"' }
        $closers = ($stack.ToArray() -join '')
        $candidates.Add($trimmed + $closers)
    }

    foreach ($candidate in $candidates) {
        try {
            $parsed = ConvertFrom-DecisionJson -Json $candidate
            if ($null -ne $parsed) { return $parsed }
        }
        catch {
            continue
        }
    }

    $null
}

function Get-DecisionSchemaFieldChoices {
    <#
        The choices of a single JSON-Schema field as Label/Value pairs, or an empty
        array for free text.

        Both halves matter, and they are read here together so they cannot drift
        apart. The label is what the card shows and what the injector counts arrow
        presses towards; the value is what the schema actually carries - the `const`
        of a `oneOf` entry, the `enum` entry behind an `enumNames` label, `true` or
        `false` for a checkbox.

        The two are usually the same string, which is why the difference went unseen
        for so long. It only shows when a form is written the richer way, and then it
        matters: the CLI records an answer by value ("release=cut_now"), never by
        label ("Cut the release now"). A checker that knows only labels calls every
        such answer a mismatch.

        Returns ordered Label/Value/Id records. Unrepresentable labels are rejected,
        never shortened or removed: either would change native option identity.
    #>
    param(
        [AllowNull()]
        [psobject]$Field
    )

    if ($null -eq $Field) { return @() }
    $choices = [System.Collections.Generic.List[object]]::new()

    $labelsSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $reserved = @('Idle', 'Awaiting answer...', 'Choose...', 'Cancel request', 'unknown', 'unavailable')
    $has = {
        param($Object, [string]$Name)
        ($null -ne $Object) -and ($null -ne $Object.PSObject.Properties[$Name])
    }
    $add = {
        param([AllowNull()]$Value, [AllowEmptyString()][string]$Title)
        if ($null -ne $Value -and [Type]::GetTypeCode($Value.GetType()).ToString() -notin
            @('String', 'Boolean', 'SByte', 'Byte', 'Int16', 'UInt16', 'Int32', 'UInt32', 'Int64', 'UInt64', 'Single', 'Double', 'Decimal')) {
            throw [IO.InvalidDataException]::new('A decision option must retain a supported JSON scalar value.')
        }
        $label = $Title
        if ([string]::IsNullOrWhiteSpace($label)) {
            $label = if ($Value -is [string]) { $Value } else { ConvertTo-Json -InputObject $Value -Compress }
        }
        if ([string]::IsNullOrWhiteSpace($label) -or $label.Length -gt 250 -or
            $label -cne $label.Trim() -or $label -match '[\x00-\x1f\x7f]' -or
            $label -in $reserved -or -not $labelsSeen.Add($label)) {
            throw [IO.InvalidDataException]::new('Decision option labels must be distinct, non-reserved, and fit the selector without truncation.')
        }
        $choices.Add([pscustomobject]@{ Label = $label; Value = $Value; Id = "option-$($choices.Count)" })
    }
    $addEntry = {
        param($Entry)
        $title = if (& $has $Entry 'title') { [string]$Entry.title } else { '' }
        $value = if (& $has $Entry 'const') { $Entry.const } else { $title }
        & $add $value $title
    }

    if (& $has $Field 'enum') {
        $values = @($Field.enum)
        $labels = @()
        if (& $has $Field 'enumNames') { $labels = @($Field.enumNames) }
        for ($index = 0; $index -lt $values.Count; $index++) {
            $label = if ($index -lt $labels.Count) { [string]$labels[$index] } else { '' }
            & $add $values[$index] $label
        }
        return @($choices.ToArray())
    }

    if (& $has $Field 'oneOf') {
        foreach ($option in @($Field.oneOf)) { & $addEntry $option }
        return @($choices.ToArray())
    }

    if (& $has $Field 'items') {
        if (& $has $Field.items 'enum') {
            foreach ($entry in @($Field.items.enum)) {
                & $add $entry ''
            }
            return @($choices.ToArray())
        }
        if (& $has $Field.items 'anyOf') {
            foreach ($option in @($Field.items.anyOf)) { & $addEntry $option }
            return @($choices.ToArray())
        }
        return @()
    }

    # A checkbox is shown as Yes/No but recorded as the JSON literal.
    if ((& $has $Field 'type') -and [string]$Field.type -eq 'boolean') {
        & $add $true 'Yes'
        & $add $false 'No'
        return @($choices.ToArray())
    }

    @()
}

function Get-DecisionSchemaFieldOptions {
    <#
        Option labels for a single JSON-Schema field, or an empty array for free text.
    #>
    param(
        [AllowNull()]
        [psobject]$Field
    )

    @(Get-DecisionSchemaFieldChoices -Field $Field | ForEach-Object { [string]$_.Label })
}

function Format-DecisionSchemaOutline {
    <#
        Renders a multi-field form as readable text to append to the question.

        A card shows one question with one option list, so a multi-field form cannot
        become buttons. It used to publish a bare text box with no hint of what the
        options were, which is unanswerable from a phone. Spelling the fields and
        their options out in the question body keeps the freeform answer while making
        it obvious what can be typed.
    #>
    param(
        [AllowNull()]
        [psobject]$Schema
    )

    if ($null -eq $Schema -or $null -eq $Schema.properties) { return '' }
    $names = @($Schema.properties.PSObject.Properties.Name)
    if ($names.Count -le 1) { return '' }

    $lines = New-Object System.Collections.Generic.List[string]
    $fieldNumber = 0
    foreach ($name in $names) {
        $field = $Schema.properties.$name
        $label = [string]$field.title
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $name }
        $fieldNumber++

        $options = @(Get-DecisionSchemaFieldOptions -Field $field)
        if ($options.Count -gt 0) {
            $lines.Add("$fieldNumber. $label")
            $default = [string]$field.default
            foreach ($option in $options) {
                $marker = if (
                    -not [string]::IsNullOrWhiteSpace($default) -and
                    $option -eq $default
                ) { ' (default)' } else { '' }
                $lines.Add("   - $option$marker")
            }
        }
        else {
            $lines.Add("$fieldNumber. $label (free text)")
        }
    }

    if ($lines.Count -eq 0) { return '' }
    "Answer these in one message:`n" + ($lines -join "`n")
}

function Test-DecisionFieldIsText {
    <#
        True when a captured field is a free-text box rather than an option list.

        A field with no options is one the user types into. Recorded explicitly rather
        than inferred from an empty Options list everywhere, because that emptiness
        used to mean "unanswerable" and the distinction now matters.
    #>
    param([AllowNull()][object]$Field)

    if ($null -eq $Field) { return $false }
    if ($Field.PSObject.Properties['IsText']) { return [bool]$Field.IsText }
    return (@($Field.Options).Count -eq 0)
}

# The most subset entries a multi-select field's dropdown may carry. Claude's schema
# allows 2-4 options, which is 3, 7 or 15 subsets; anything beyond that is refused
# rather than published as a dropdown nobody could scroll.
$script:DecisionMultiSelectMaxChoices = 15
$script:DecisionMultiSelectSeparator = ' + '

function Test-DecisionFieldIsMultiSelect {
    <#
        True when a field lets the user pick several of its options at once.

        Claude's AskUserQuestion sets multiSelect per question. The bridge's dropdowns
        are single-choice, so such a field is offered as the list of combinations
        instead (Get-DecisionMultiSelectChoices).
    #>
    param([AllowNull()][object]$Field)

    if ($null -eq $Field) { return $false }
    if (-not $Field.PSObject.Properties['MultiSelect']) { return $false }
    [bool]$Field.MultiSelect
}

function Get-DecisionMultiSelectChoices {
    <#
        The combinations a multi-select field offers, as dropdown labels: every
        non-empty subset of its options, single picks first, then pairs, and so on,
        each in the field's own option order.

        A Home Assistant select holds one value, so this is how "choose any of these"
        reaches a card at all. The daemon turns the chosen label back into the
        individual options with Resolve-DecisionMultiSelectChoice; the two are
        generated by the same code so they cannot drift.

        Returns an empty list when the field cannot be offered this way - too many
        options, or labels so long that truncation would make two subsets identical -
        which leaves the question to the terminal.
    #>
    param(
        [AllowNull()][object]$Field,
        [int]$MaxChoices = $script:DecisionMultiSelectMaxChoices
    )

    $options = @($Field.Options | ForEach-Object { [string]$_ })
    $count = $options.Count
    if ($count -lt 2) { return @() }
    # 2^count - 1 subsets; the shift is safe because the count is checked first.
    if ($count -gt 20 -or ([Math]::Pow(2, $count) - 1) -gt $MaxChoices) { return @() }

    $labels = New-Object System.Collections.Generic.List[string]
    for ($size = 1; $size -le $count; $size++) {
        for ($mask = 1; $mask -lt (1 -shl $count); $mask++) {
            $bits = 0
            for ($b = 0; $b -lt $count; $b++) { if ($mask -band (1 -shl $b)) { $bits++ } }
            if ($bits -ne $size) { continue }
            $picked = for ($b = 0; $b -lt $count; $b++) { if ($mask -band (1 -shl $b)) { $options[$b] } }
            $labels.Add(($picked -join $script:DecisionMultiSelectSeparator))
        }
    }

    # A label the card would truncate can collide with another, and then the daemon
    # cannot tell which combination was chosen. Refuse rather than guess.
    foreach ($label in $labels) { if ($label.Length -gt 200) { return @() } }
    if (@($labels | Select-Object -Unique).Count -ne $labels.Count) { return @() }
    $labels.ToArray()
}

function Resolve-DecisionMultiSelectChoice {
    <#
        The individual options behind a combination label chosen on the card, in the
        field's own order, or an empty list when the label is not one of its
        combinations.

        Deliberately not a split on the separator: an option label may contain it, and
        splitting would silently pick the wrong options. The combination list is
        regenerated and matched whole.
    #>
    param(
        [AllowNull()][object]$Field,
        [AllowEmptyString()][string]$Choice
    )

    if ([string]::IsNullOrWhiteSpace($Choice)) { return @() }
    $options = @($Field.Options | ForEach-Object { [string]$_ })
    $count = $options.Count
    foreach ($label in @(Get-DecisionMultiSelectChoices -Field $Field)) {
        if ($label -ne $Choice) { continue }
        $picked = New-Object System.Collections.Generic.List[string]
        for ($size = 1; $size -le $count; $size++) {
            for ($mask = 1; $mask -lt (1 -shl $count); $mask++) {
                $bits = 0
                for ($b = 0; $b -lt $count; $b++) { if ($mask -band (1 -shl $b)) { $bits++ } }
                if ($bits -ne $size) { continue }
                $these = for ($b = 0; $b -lt $count; $b++) { if ($mask -band (1 -shl $b)) { $options[$b] } }
                if (($these -join $script:DecisionMultiSelectSeparator) -eq $Choice) {
                    foreach ($t in $these) { $picked.Add([string]$t) }
                    return $picked.ToArray()
                }
            }
        }
    }
    @()
}

function Test-DecisionFieldsAnswerable {
    <#
        Whether a captured field set can actually be answered from Home Assistant.

        Answerable means every field maps to a control on the card: a dropdown per
        choice field, and the existing Reply box for a free-text field. That allows at
        most one text field, and no more fields than the card publishes dropdowns for.

        Anything else has to be answered at the terminal. Saying so is the point - the
        bridge used to publish a plain text box for these, and typing into the live
        arrow-key prompt discarded the answer silently.
    #>
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Fields,
        [int]$MaxFields = 4
    )

    $list = @($Fields)
    if ($list.Count -eq 0 -or $list.Count -gt $MaxFields) { return $false }
    $textCount = @($list | Where-Object { Test-DecisionFieldIsText -Field $_ }).Count
    ($textCount -le 1)
}

function Get-DecisionSchemaFields {
    <#
        Returns the per-field definitions of a requestedSchema, in order.

        The native ask_user prompt renders a multi-field form as tabbed sections -
        "tab next" moves between fields, each with its own arrow-key option list or
        text entry. To answer such a form by injection the bridge needs each field in
        order, so it can compute how many Down presses select a given option, or know
        to type instead.

        Free-text fields are included and flagged, not discarded. Discarding them used
        to throw away the entire form - a single free-text field among four dropdowns
        left the card with no options at all, and the resulting free-text answer was
        swallowed by the live prompt.

        Names, typed values, option identities and defaults survive the marker.
        DefaultIndex is the initial scalar focus, not the dashboard placeholder.
    #>
    param(
        [AllowNull()][psobject]$Schema
    )

    if ($null -eq $Schema -or -not $Schema.PSObject.Properties['properties'] -or $null -eq $Schema.properties) { return @() }
    $names = @($Schema.properties.PSObject.Properties.Name)
    if ($names.Count -eq 0) { return @() }

    $fields = @()
    $labelsSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $names) {
        $field = $Schema.properties.$name
        $label = if ($field.PSObject.Properties['title']) { [string]$field.title } else { '' }
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $name }
        if (-not $labelsSeen.Add($label)) {
            throw [IO.InvalidDataException]::new('Decision field labels must identify distinct fields.')
        }
        $choices = @(Get-DecisionSchemaFieldChoices -Field $field)
        $values = [object[]]::new($choices.Count)
        for ($index = 0; $index -lt $choices.Count; $index++) { $values[$index] = $choices[$index].Value }
        $hasDefault = $null -ne $field.PSObject.Properties['default']
        $default = if ($hasDefault) { ,$field.default } else { $null }
        $defaultIndex = 0
        $isArray = $field.PSObject.Properties['type'] -and [string]$field.type -eq 'array'
        if ($hasDefault -and $choices.Count -gt 0 -and -not $isArray) {
            $key = ConvertTo-Json -InputObject $default -Depth 32 -Compress
            $matches = @(
                for ($index = 0; $index -lt $values.Count; $index++) {
                    if ([StringComparer]::Ordinal.Equals($key, (ConvertTo-Json -InputObject $values[$index] -Depth 32 -Compress))) { $index }
                }
            )
            if ($matches.Count -ne 1) {
                throw [IO.InvalidDataException]::new('A scalar decision default must identify exactly one option.')
            }
            $defaultIndex = $matches[0]
        }
        $fields += [pscustomobject]@{
            Name         = $name
            Label        = $label
            Options      = @($choices | ForEach-Object { [string]$_.Label })
            Values       = $values
            OptionIds    = @($choices | ForEach-Object { [string]$_.Id })
            HasDefault   = $hasDefault
            Default      = $default
            DefaultIndex = $defaultIndex
            IsText       = ($choices.Count -eq 0)
        }
    }
    @($fields)
}

function Get-DecisionSchemaCombos {
    <#
        Turns a small multi-field form into a flat list of combined choices, so it can
        be answered with buttons instead of a free-text outline.

        A form with two fields - say Visibility (Public/Private) and Push (Yes/No) -
        becomes the cartesian product of their options: "Public + Yes", "Public + No",
        "Private + Yes", "Private + No". The user taps one button that answers every
        field at once, and the mapping back to per-field values is carried alongside so
        the answer can be reported to the model in full.

        Returns $null when the form is not suited to this: a single field (handled as a
        plain choice), any free-text field, or a product large enough that the button
        list would be unwieldy.
    #>
    param(
        [AllowNull()]
        [psobject]$Schema,

        [int]$MaxCombos = 12
    )

    if ($null -eq $Schema -or $null -eq $Schema.properties) { return $null }
    $names = @($Schema.properties.PSObject.Properties.Name)
    if ($names.Count -lt 2) { return $null }

    $fields = @()
    $product = 1
    foreach ($name in $names) {
        $field = $Schema.properties.$name
        $label = [string]$field.title
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $name }
        $options = @(Get-DecisionSchemaFieldOptions -Field $field)
        if ($options.Count -eq 0) { return $null }
        $fields += [pscustomobject]@{ Label = $label; Options = $options }
        $product *= $options.Count
    }
    if ($product -lt 2 -or $product -gt $MaxCombos) { return $null }

    # Iteratively expand the cartesian product. Each combo carries an ordered map of
    # field label to chosen option, and a joined display label for the button.
    $combos = @([pscustomobject]@{ Label = ''; Values = [ordered]@{} })
    foreach ($field in $fields) {
        $next = @()
        foreach ($combo in $combos) {
            foreach ($option in $field.Options) {
                $values = [ordered]@{}
                foreach ($k in $combo.Values.Keys) { $values[$k] = $combo.Values[$k] }
                $values[$field.Label] = $option
                $label = if ([string]::IsNullOrEmpty($combo.Label)) { $option } else { "$($combo.Label) + $option" }
                $next += [pscustomobject]@{ Label = $label; Values = $values }
            }
        }
        $combos = $next
    }

    @($combos)
}

function Repair-DecisionToolArguments {
    <#
        Normalises `ask_user` arguments, recovering the multiple-choice case from a
        malformed tool call.

        When the model fails to terminate the tool-call markup, the closing tag and
        every later parameter are swallowed into the `question` string:

            question = "Real question?</question>\n<parameter name=""choices"">[""A"",""B""]"

        `choices` then never arrives as an argument, so the bridge would publish a
        free-text box for what is really a multiple choice, with raw markup showing in
        the card. Splitting the question at the leak and parsing the trailing payload
        restores the intended choice buttons. Real arguments always win over recovered
        ones.

        A small multi-field form is turned into combined choice buttons (the cartesian
        product of its fields) rather than a free-text outline, and the per-field
        breakdown of each combo is returned in `Combos` so the selected button can be
        reported to the model field by field.
    #>
    param(
        [AllowNull()]
        [psobject]$ToolArgs
    )

    $question = ''
    $choices = @()
    $combos = @()
    $fields = @()
    $terminalOnly = $false

    if ($null -ne $ToolArgs) {
        # Current Copilot CLI ask_user passes `message`; older builds passed `question`.
        $rawQuestion = [string]$ToolArgs.message
        if ([string]::IsNullOrWhiteSpace($rawQuestion)) {
            $rawQuestion = [string]$ToolArgs.question
        }
        $question = Repair-DecisionTextEncoding -Text $rawQuestion

        if ($null -ne $ToolArgs.choices) {
            if ($ToolArgs.choices -is [string]) {
                # A choice list handed over as a JSON string rather than an array.
                $choices = @(ConvertFrom-DecisionChoiceList -Text ([string]$ToolArgs.choices))
                if ($choices.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($ToolArgs.choices)) {
                    $choices = @([string]$ToolArgs.choices)
                }
            }
            else {
                $choices = @(
                    $ToolArgs.choices |
                        ForEach-Object { [string]$_ } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                )
            }
            $choices = @($choices | ForEach-Object { Repair-DecisionTextEncoding -Text $_ })
        }

        # An explicit `choices` argument always wins; otherwise derive the options
        # from the modern `requestedSchema` form.
        if ($choices.Count -eq 0 -and $null -ne $ToolArgs.requestedSchema) {
            $schema = $ToolArgs.requestedSchema
            if ($schema -is [string]) {
                $schema = ConvertFrom-DecisionSchemaText -Text ([string]$schema)
            }
            $schemaChoices = @(ConvertFrom-DecisionRequestedSchema -Schema $schema)
            if ($schemaChoices.Count -gt 0) {
                $choices = @(
                    $schemaChoices | ForEach-Object { Repair-DecisionTextEncoding -Text $_ }
                )
                $fields = @(Get-DecisionSchemaFields -Schema $schema)
            }
            else {
                # A multi-field form is published as one dropdown per field, so the
                # combined cartesian list is no longer used for display - it only
                # remains as the text fallback. Capture the fields; leave $choices
                # empty so nothing flattens into a single unreadable list.
                $schemaFields = Get-DecisionSchemaFields -Schema $schema
                if (@($schemaFields).Count -gt 1 -and (Test-DecisionFieldsAnswerable -Fields $schemaFields)) {
                    $fields = @($schemaFields)
                }
                else {
                    $outline = Format-DecisionSchemaOutline -Schema $schema
                    if (-not [string]::IsNullOrWhiteSpace($outline)) {
                        $question = "$question`n`n$outline"
                    }
                    # A multi-field prompt the card cannot drive must be flagged, not
                    # quietly turned into a text box. The native prompt is an
                    # arrow-key form, and typed characters sent to it are discarded -
                    # the answer disappears and the prompt keeps waiting.
                    if (@($schemaFields).Count -gt 1) { $terminalOnly = $true }
                }
            }
        }
    }

    # Only a closing tag for the question/message parameter, or a `choices` /
    # `requestedSchema` parameter opener, counts as a leak. Matching a bare
    # `<parameter` would truncate any question that merely mentions one.
    $recovered = $false
    if (-not [string]::IsNullOrWhiteSpace($question)) {
        $leakIndex = -1
        foreach ($pattern in @(
            '(?is)</(?:\w+:)?question\s*>',
            '(?is)</(?:\w+:)?message\s*>',
            '(?is)<(?:\w+:)?parameter\s+name\s*=\s*(?:"|'')?choices(?:"|'')?\s*>',
            '(?is)<(?:\w+:)?parameter\s+name\s*=\s*(?:"|'')?requestedSchema(?:"|'')?\s*>'
        )) {
            $match = [regex]::Match($question, $pattern)
            if ($match.Success -and ($leakIndex -lt 0 -or $match.Index -lt $leakIndex)) {
                $leakIndex = $match.Index
            }
        }

        if ($leakIndex -ge 0) {
            $leaked = $question.Substring($leakIndex)
            $question = $question.Substring(0, $leakIndex).TrimEnd()

            if ($choices.Count -eq 0) {
                $block = [regex]::Match(
                    $leaked,
                    '(?is)<(?:\w+:)?parameter\s+name\s*=\s*(?:"|'')?choices(?:"|'')?\s*>(.*)'
                )
                if ($block.Success) {
                    $payload = $block.Groups[1].Value
                    $close = [regex]::Match($payload, '(?is)</(?:\w+:)?parameter\s*>')
                    if ($close.Success) {
                        $payload = $payload.Substring(0, $close.Index)
                    }
                    $choices = @(
                        ConvertFrom-DecisionChoiceList -Text $payload |
                            ForEach-Object { Repair-DecisionTextEncoding -Text $_ }
                    )
                    $recovered = $choices.Count -gt 0
                }
            }

            # The current ask_user shape leaks `requestedSchema`, not `choices`. This
            # was the gap that made a malformed modern tool call publish a free-text
            # box with raw markup instead of the intended buttons.
            if ($choices.Count -eq 0) {
                $block = [regex]::Match(
                    $leaked,
                    '(?is)<(?:\w+:)?parameter\s+name\s*=\s*(?:"|'')?requestedSchema(?:"|'')?\s*>(.*)'
                )
                if ($block.Success) {
                    $payload = $block.Groups[1].Value
                    $close = [regex]::Match($payload, '(?is)</(?:\w+:)?parameter\s*>')
                    if ($close.Success) {
                        $payload = $payload.Substring(0, $close.Index)
                    }
                    $schema = ConvertFrom-DecisionSchemaText -Text $payload
                    if ($null -ne $schema) {
                        $schemaChoices = @(
                            ConvertFrom-DecisionRequestedSchema -Schema $schema
                        )
                        if ($schemaChoices.Count -gt 0) {
                            $choices = @(
                                $schemaChoices |
                                    ForEach-Object { Repair-DecisionTextEncoding -Text $_ }
                            )
                            $recovered = $true
                        }
                        else {
                            $comboList = Get-DecisionSchemaCombos -Schema $schema
                            if ($null -ne $comboList -and @($comboList).Count -gt 0) {
                                $combos = @($comboList)
                                $choices = @(
                                    $combos | ForEach-Object { Repair-DecisionTextEncoding -Text $_.Label }
                                )
                                $recovered = $true
                            }
                            else {
                                $outline = Format-DecisionSchemaOutline -Schema $schema
                                if (-not [string]::IsNullOrWhiteSpace($outline)) {
                                    $question = "$question`n`n$outline"
                                    $recovered = $true
                                }
                            }
                        }
                    }
                }
            }

            # Strip stray closers the truncated call left in the question itself.
            $question = (
                $question -replace
                    '(?is)</?(?:\w+:)?(?:question|message|parameter|invoke|function_calls|antml:\w+)[^>]*>',
                    ''
            ).Trim()
        }
    }

    if ([string]::IsNullOrWhiteSpace($question)) {
        $question = 'Copilot CLI needs your input.'
    }

    [pscustomobject]@{
        Question = $question
        Choices = @($choices)
        Combos = @($combos)
        Fields = @($fields)
        TerminalOnly = $terminalOnly
        Recovered = $recovered
    }
}

function Get-BridgeStateUserId {
    <#
        The Home Assistant user behind a state change, or '' when there is none.

        Every state Home Assistant returns carries a context, and a service call made
        by a person through the dashboard, or by a token through the API, records that
        account's id in it. StrictMode makes the nested reads throw when a state has no
        context at all, so each step is checked rather than assumed.
    #>
    param($State)

    if ($null -eq $State) { return '' }
    if (@($State.PSObject.Properties.Name) -notcontains 'context') { return '' }
    $context = $State.context
    if ($null -eq $context) { return '' }
    if (@($context.PSObject.Properties.Name) -notcontains 'user_id') { return '' }
    [string]$context.user_id
}

function Test-BridgeAgentUserId {
    <#
        Whether a Home Assistant user is an agent driving sessions remotely.

        An agent driving a session does exactly what a person does - set the reply
        text, press Submit - so the two arrive as identical service calls and nothing
        within them tells one from the other. Giving the agent its own Home Assistant
        account is what makes the difference visible: the user id on the press becomes
        the only honest signal there is, and the logbook starts attributing those
        actions to the agent rather than to you.

        Configured as homeAssistant.agentUserIds. With none configured nothing is ever
        an agent, which is the right default - better no glow at all than a wrong one.
    #>
    param([AllowEmptyString()][AllowNull()][string]$UserId)

    if ([string]::IsNullOrWhiteSpace($UserId)) { return $false }
    $configured = @(@(Get-BridgeSetting 'homeAssistant.agentUserIds' @()) |
        ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($configured.Count -eq 0) { return $false }
    $configured -contains $UserId.Trim()
}

function Get-BridgeAgentToken {
    <#
        The token an agent drives the bridge with, or '' when none is configured.

        Deliberately not the same account as homeAssistant.token. The daemon, the
        hooks, the dashboard provisioning and the MCP server all act for you and keep
        using that one; this is the token handed to the environment of every session
        the bridge launches, so that when an agent goes on to drive another session -
        a reply, a launch - it arrives under the agent's own account.

        Only where the bridge reads the account back, which is why the MCP server is
        not on that list: it publishes a question and waits, pressing nothing. It also
        provisions - entity ids and its dashboard - and those are admin-only, so
        giving it this token would force the agent account to be an administrator,
        which is exactly what a separate account exists to avoid.

        This is the missing half of Test-BridgeAgentUserId. An id in agentUserIds can
        only ever match if something actually presses with that account's token, and
        until this existed there was nowhere for such a token to live: the bridge held
        exactly one, yours, and handed it to everything. So every press an agent made
        was read as yours - correctly - and the purple edge could not appear at all.

        Configured as homeAssistant.agentToken, or the environment variable named by
        homeAssistant.agentTokenEnvVar (default AGENT_HA_AGENT_TOKEN), so it need not
        be written to a file.
    #>
    $token = [string]$script:DecisionBridgeConfig.HomeAssistantAgentToken
    if (-not [string]::IsNullOrWhiteSpace($token)) { return $token.Trim() }

    $envVar = [string]$script:DecisionBridgeConfig.HomeAssistantAgentTokenEnvVar
    if ([string]::IsNullOrWhiteSpace($envVar)) { return '' }
    $fromEnv = [string][Environment]::GetEnvironmentVariable($envVar)
    if ([string]::IsNullOrWhiteSpace($fromEnv)) { return '' }
    $fromEnv.Trim()
}

function Get-BridgeAgentTokenEnvironment {
    <#
        The environment variable a launched session carries so the agent inside it
        drives the bridge as itself, or $null when no agent token is configured.

        A launched session is where this matters most: it is the one most likely to go
        on and drive another session, and it has no other way to learn that the agent
        account exists. Windows children inherit the launcher's environment; tmux keeps
        its own, so the macOS path has to pass it explicitly - the same reason PATH is
        passed there.
    #>
    $token = Get-BridgeAgentToken
    if (-not $token) { return $null }
    $name = [string]$script:DecisionBridgeConfig.HomeAssistantAgentTokenEnvVar
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    [pscustomobject]@{ Name = $name.Trim(); Value = $token }
}

function Get-BridgeAgentIdentityWarning {
    <#
        Why a session an agent drives can never be marked as such, or '' when it can.

        The two halves are configured separately and are inert apart, which is exactly
        the failure this reports. agentUserIds says which account counts as an agent;
        agentToken is what lets an agent actually act as that account. With an id and
        no token, every press an agent makes still carries your account and is read as
        yours; with a token and no id, the agent's own account is not recognised. Both
        leave the purple edge permanently off.

        Nothing fails in either case - no error, no log line, a dashboard that simply
        never lights up - so this has to be said out loud rather than discovered. Both
        empty is the documented default of marking nothing, and is not a warning.
    #>
    $ids = @(@(Get-BridgeSetting 'homeAssistant.agentUserIds' @()) |
        ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    $hasToken = -not [string]::IsNullOrWhiteSpace((Get-BridgeAgentToken))

    if ($ids.Count -eq 0 -and -not $hasToken) { return '' }
    if ($ids.Count -gt 0 -and $hasToken) { return '' }
    if ($ids.Count -gt 0) {
        return 'homeAssistant.agentUserIds is set but homeAssistant.agentToken is not, so an agent still drives the bridge as you and no session is ever marked agent-driven.'
    }
    'homeAssistant.agentToken is set but homeAssistant.agentUserIds is empty, so the agent account is never recognised and no session is ever marked agent-driven.'
}

function Get-BridgeThoughtLine {
    <#
        A thought reduced to one line for the activity trail.

        The trail is a list on a phone, so a thought joins it the way the agent's own
        text does - first line only, trimmed - rather than as the paragraphs it
        usually is. It is prefixed rather than left bare because the trail mixes
        kinds: "Running: view" is something the agent did and a thought is something
        it considered, and a reader needs to tell them apart at a glance.

        Returns '' for nothing worth showing, so a caller can skip it.
    #>
    param(
        [AllowEmptyString()][AllowNull()][string]$Text,
        [int]$MaxChars = 120
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $first = (($Text -replace "`r", '') -split "`n" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($first)) { return '' }

    # Reasoning usually opens with its own heading - "**Checking the config**" or
    # "## Checking the config" - which is the best one-line summary there is, but only
    # once its markup is off.
    $line = $first.Trim()
    $line = $line -replace '^\s*#{1,6}\s+', ''
    $line = $line -replace '^\*\*(.+?)\*\*\s*$', '$1'
    $line = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($line)) { return '' }

    if ($line.Length -gt $MaxChars) {
        $line = $line.Substring(0, [Math]::Max(1, $MaxChars - 1)).TrimEnd() +([char]0x2026)
    }
    "Thinking: $line"
}

function Get-BridgeDriverFromState {
    <# 'agent' or 'human', from the context on the state that carried the input. #>
    param($State)

    if (Test-BridgeAgentUserId -UserId (Get-BridgeStateUserId -State $State)) { return 'agent' }
    'human'
}

function Get-HomeAssistantHeaders {
    <#
        Resolves the Home Assistant long-lived access token.

        Order: the config file's homeAssistant.token, then the environment variable it
        names in homeAssistant.tokenEnvVar (default AGENT_HA_TOKEN), then the
        pre-rename COPILOT_HA_TOKEN so an existing environment keeps working. The token
        is never stored in the repository - config.json is gitignored.
    #>
    $token = [string]$script:DecisionBridgeConfig.HomeAssistantToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        $envVar = [string]$script:DecisionBridgeConfig.HomeAssistantTokenEnvVar
        if (-not [string]::IsNullOrWhiteSpace($envVar)) {
            $token = [string][Environment]::GetEnvironmentVariable($envVar)
        }
    }
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = [string][Environment]::GetEnvironmentVariable('COPILOT_HA_TOKEN')
    }
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw ("No Home Assistant token. Set homeAssistant.token in the bridge config " +
            "or the $($script:DecisionBridgeConfig.HomeAssistantTokenEnvVar) environment variable.")
    }

    @{ Authorization = "Bearer $token" }
}

function Assert-HomeAssistantServiceTarget {
    <#
        Refuses a service call that selects anything other than one named entity.

        On 2026-10-02 a script meant to press a single session's stop button built its
        target by filtering GET /api/states down to that one button and then taking an
        entity id out of the result. The selection collapsed: the POST that followed
        carried thousands of entity ids instead of one, and Home Assistant pressed
        every button among them. 166 buttons fired at 22:45:23 PT - the whole UniFi
        fleet rebooted mid-request, PoE camera ports power-cycled, and vacuum
        consumable counters, ERV totals and bed-presence calibrations were reset. The
        call then returned 502, which read as a transient failure, so the identical
        command ran again three minutes later and did it a second time.

        The exact reason that filter collapsed is NOT established: the obvious
        candidate - Invoke-RestMethod handing a JSON array to the pipeline as a single
        object - does not reproduce, because it enumerates under both PowerShell 7.6.6
        and Windows PowerShell 5.1 (checked against the live state list, 5,068
        entities, both shells). So this guard deliberately does not encode one idiom.
        It checks the only thing that actually mattered: the shape of what was about to
        be sent.

        Nothing in this repository legitimately targets more than one entity - every
        caller passes a scalar entity id, or no target at all - so the safe shape is
        made the only allowed shape, and a collapsed selection throws here instead of
        becoming a house-wide side effect.

        entity_id is the only selector accepted, and only ever one of them. 'all' is
        rejected by name because Home Assistant still honours it as "every entity in
        the domain". device_id, area_id, label_id and floor_id are refused outright
        rather than counted: Home Assistant expands each of them to *every* matching
        entity, so a single scalar area_id presses every button in that area. Counting
        selector values would wave that straight through. An entity_id in both the body
        and target is refused for the same reason - the two are a union, not a choice.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Data
    )

    $containers = @($Data)
    if ($Data.ContainsKey('target')) {
        $target = $Data['target']
        if ($target -is [hashtable]) { $containers += $target }
        elseif ($null -ne $target) {
            throw ('Home Assistant service call has a target that is not a hashtable, ' +
                'so what it selects cannot be checked. Pass target as a hashtable.')
        }
    }

    $named = 0
    foreach ($container in $containers) {
        foreach ($key in @('device_id', 'area_id', 'label_id', 'floor_id')) {
            if ($container.ContainsKey($key)) {
                throw ("Home Assistant service call selects by $key, which Home Assistant " +
                    'expands to every matching entity. Name a single entity_id instead.')
            }
        }

        if (-not $container.ContainsKey('entity_id')) { continue }
        $named++
        $value = $container['entity_id']

        # A one-element array is how a caller spells "just this one", so unwrap it
        # rather than failing a selection that is already safe.
        if ($value -isnot [string] -and $null -ne $value) {
            $items = @($value)
            if ($items.Count -eq 1) { $value = $items[0] }
            else {
                throw ("Home Assistant service call selects $($items.Count) values as entity_id. " +
                    'Name exactly one; a service call is not a way to fan out. ' +
                    'A collapsed pipeline filter is the usual cause.')
            }
        }

        if ($null -eq $value -or $value -isnot [string]) {
            throw 'Home Assistant service call has an entity_id that is not a single string.'
        }

        $id = $value.Trim()
        if ($id -eq '') { throw 'Home Assistant service call has an empty entity_id.' }
        if ($id -eq 'all') {
            throw ("Home Assistant service call uses entity_id 'all', which targets every " +
                'entity in the domain. Name the one entity instead.')
        }
        if ($id -match '[,\s]') {
            throw ("Home Assistant service call passes a list as entity_id ('$id'). " +
                'Name exactly one entity.')
        }
        if ($id -notmatch '^[^.\s,]+\.[^.\s,]+$') {
            throw "Home Assistant service call has a malformed entity_id ('$id')."
        }
    }

    if ($named -gt 1) {
        throw ('Home Assistant service call names an entity_id in both the body and ' +
            'target, which selects both. Name exactly one entity.')
    }
}

function Invoke-HomeAssistantService {
    param(
        [Parameter(Mandatory)]
        [string]$Domain,

        [Parameter(Mandatory)]
        [string]$Service,

        [Parameter(Mandatory)]
        [hashtable]$Data,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [ValidateRange(1, 60)]
        [int]$TimeoutSec = 15
    )

    # Checked before the request is built, so a fan-out never reaches the wire.
    Assert-HomeAssistantServiceTarget -Data $Data

    $uri = "$($script:DecisionBridgeConfig.HomeAssistantBaseUrl)/api/services/$Domain/$Service"
    # Send raw UTF-8 bytes: Windows PowerShell 5.1 encodes a string body with the
    # default codepage unless the charset is spelled out, which corrupts non-ASCII
    # payloads and makes Home Assistant reject the request with a 500.
    $payload = [Text.Encoding]::UTF8.GetBytes(($Data | ConvertTo-Json -Depth 10 -Compress))
    Invoke-DecisionHttpRequest -Parameters @{
        Method = 'Post'
        Uri = $uri
        Headers = $Headers
        ContentType = 'application/json; charset=utf-8'
        Body = $payload
        TimeoutSec = $TimeoutSec
    } | Out-Null
}

function Get-HomeAssistantState {
    param(
        [Parameter(Mandatory)]
        [string]$EntityId,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [ValidateRange(1, 60)]
        [int]$TimeoutSec = 15
    )

    $uri = "$($script:DecisionBridgeConfig.HomeAssistantBaseUrl)/api/states/$EntityId"
    Invoke-DecisionHttpRequest -Parameters @{
        Method = 'Get'
        Uri = $uri
        Headers = $Headers
        TimeoutSec = $TimeoutSec
    }
}



function Remove-CopilotTemplateMarkup {
    <#
        Neutralises Home Assistant template syntax in text that will be interpolated
        into a Lovelace template.

        Session display names are not trusted input: a Copilot session is named after
        its task, and a Claude session after its working directory, so a repository or
        folder called "{{ states('device_tracker.me') }}" would otherwise be rendered
        as a template by Home Assistant. That was confirmed against a live instance -
        the injected expression evaluated and read real entity state - so anything
        session-derived is sanitised here before it can reach a card, a notification
        or a device name.

        The delimiters are broken with a zero-width space rather than stripped, so the
        text still reads correctly while being inert.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $zws = [char]0x200B
    $Text -replace '\{\{', "{$zws{" -replace '\{%', "{$zws%" -replace '\{#', "{$zws#"
}

function Get-CopilotSessionDisplay {
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory
    )

    # Prefixed to match the Claude and Codex adapters, so a shared dashboard shows at
    # a glance which front end each card belongs to.
    $name = "Copilot: $($SessionId.Substring(0, [Math]::Min(8, $SessionId.Length)))"
    # Resolve the session directory through the filesystem-safe key, never the raw id:
    # a crafted id must not be able to walk out of the session-state root and read an
    # arbitrary workspace.yaml.
    $safeKey = Get-CopilotSafeSessionKey -SessionId $SessionId
    $workspacePath = Join-Path (
        Join-Path $script:DecisionBridgeConfig.SessionStateRoot $safeKey
    ) 'workspace.yaml'

    if (Test-Path -LiteralPath $workspacePath) {
        $nameMatch = Select-String -LiteralPath $workspacePath -Encoding UTF8 `
            -Pattern '^name:\s*(.+)$' | Select-Object -First 1
        if ($nameMatch) {
            $parsedName = $nameMatch.Matches.Groups[1].Value.Trim().Trim('"', "'")
            if (-not [string]::IsNullOrWhiteSpace($parsedName)) {
                $name = "Copilot: $parsedName"
            }
        }

    }

    $machine = [Environment]::MachineName

    # A session nobody has renamed is named after its first prompt, which can run to
    # hundreds of characters and turns the card header into a wall of text. Capped the
    # way the Claude and Codex adapters cap theirs, and before sanitising so the cut
    # cannot leave a live delimiter behind.
    if ($name.Length -gt 120) { $name = $name.Substring(0, 117) + '...' }

    # The name comes from the session's own workspace file, which is named after the
    # task, so treat it as untrusted before it reaches a template.
    $name = Remove-CopilotTemplateMarkup -Text $name

    $label = "$name - $machine"
    if ($label.Length -gt 255) {
        $label = $label.Substring(0, 252) + '...'
    }

    [pscustomobject]@{
        Name = $name
        Machine = $machine
        WorkingDirectory = $WorkingDirectory
        Label = $label
    }
}


function Get-BridgeMachineSlug {
    <#
        A stable, entity-id-safe name for this machine.

        Several machines routinely share one Home Assistant, and everything the bridge
        publishes once per machine - the update entity, the new-session controls, the
        session counter - needs an id that is unique to the machine publishing it.
        Before this they used fixed ids, so the second machine silently overwrote the
        first rather than appearing alongside it.

        Home Assistant object ids allow only lowercase letters, digits and
        underscores, so anything else collapses to a single underscore. The result is
        also parsed back out of entity ids to discover which machines are present, so
        it must never contain a character that would confuse that split.
    #>
    param([string]$MachineName = [Environment]::MachineName)

    $clean = ([string]$MachineName).ToLowerInvariant() -replace '[^a-z0-9]+', '_'
    $clean = $clean.Trim('_')
    # NetBIOS names cap at 15 characters, so this only bites on a long DNS-style name;
    # the trailing trim keeps a truncation from ending on the separator.
    if ($clean.Length -gt 24) { $clean = $clean.Substring(0, 24).Trim('_') }
    if ([string]::IsNullOrWhiteSpace($clean)) { return 'machine' }
    $clean
}

function Get-CopilotSafeSessionKey {
    <#
        A filesystem-safe key for a session id.

        Session ids arrive in hook payloads and are used to build paths, so a value
        containing separators or traversal segments must not be able to escape the
        directory it belongs in. Real ids are UUIDs and pass through unchanged.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$SessionId)

    $clean = ($SessionId -replace '[^a-zA-Z0-9._-]', '')
    $clean = $clean.TrimStart('.')
    if ([string]::IsNullOrWhiteSpace($clean)) { return 'unknown' }
    if ($clean.Length -gt 96) { $clean = $clean.Substring(0, 96) }
    $clean
}

function Get-CopilotDecisionMarkerPath {
    <#
        Resolves the pending-decision marker for a session.

        Copilot sessions keep it beside their session state. Other front ends - Claude
        Code, for instance - have no such folder, so those fall back to a bridge-owned
        directory. All three marker helpers go through here, so the hook that writes a
        marker and the daemon that consumes it always agree on the location.
    #>
    param([Parameter(Mandatory)][string]$SessionId)

    $key = Get-CopilotSafeSessionKey -SessionId $SessionId
    $sessionDirectory = Join-Path $script:DecisionBridgeConfig.SessionStateRoot $key
    if (Test-Path -LiteralPath $sessionDirectory) {
        return Join-Path $sessionDirectory 'agent-pending-decision.json'
    }

    $fallback = Join-Path (Get-BridgeRuntimePath 'copilot-bridge-markers') $key
    if (-not (Test-Path -LiteralPath $fallback)) {
        New-Item -ItemType Directory -Path $fallback -Force | Out-Null
    }
    Join-Path $fallback 'agent-pending-decision.json'
}

function Write-CopilotDecisionMarker {
    <#
        Records that an ask_user is in flight for a session. Written by the
        non-blocking hook and consumed by the daemon: its existence is the gate that
        says "a decision is awaiting input", and it carries the choice/combo mapping
        the daemon needs to inject a selected option and to clear the card on
        completion. Deleted by the daemon once the ask_user completes.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$DecisionId,
        [AllowEmptyString()][string]$Question = '',
        [string[]]$Choices = @(),
        [AllowNull()][object[]]$Combos = @(),
        [AllowNull()][object[]]$Fields = @(),
        [switch]$TerminalOnly,
        [Parameter(Mandatory)][ValidateSet('freeform', 'multiple_choice')][string]$Mode,

        # The agent's own id for this question (Claude's tool_use_id), so its answer
        # is matched to this card and not to an earlier question in the transcript.
        [string]$ToolCallId = ''
    )

    $marker = @{
        decisionId = $DecisionId
        toolCallId = $ToolCallId
        question = $Question
        choices = @($Choices)
        combos = @($Combos)
        fields = @($Fields)
        # The daemon refuses to inject when this is set: the native prompt is a form
        # the card cannot drive, and text sent to it would be silently discarded.
        terminalOnly = [bool]$TerminalOnly
        mode = $Mode
        armedAt = [DateTimeOffset]::Now.ToString('o')
        injectedAnswer = ''
    }
    $path = Get-CopilotDecisionMarkerPath -SessionId $SessionId
    $json = $marker | ConvertTo-Json -Depth 8 -Compress
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
}

function Read-DecisionMarkerFile {
    <# Only absence establishes no owner. Other consumers retain diagnosed
       best-effort reads; ownership callers explicitly require readable state. #>
    param([Parameter(Mandatory)][string]$Path, [switch]$RequireReadable)

    try {
        $raw = [IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($raw)) { throw [IO.InvalidDataException]::new('Empty marker.') }
        $marker = ConvertFrom-DecisionJson -Json $raw
        if ($marker -isnot [System.Management.Automation.PSCustomObject]) {
            throw [IO.InvalidDataException]::new('Marker is not a JSON object.')
        }
        return $marker
    }
    catch [IO.FileNotFoundException] { return $null }
    catch [IO.DirectoryNotFoundException] { return $null }
    catch {
        $message = "Local decision marker is unreadable: $Path"
        if ($RequireReadable) { throw [IO.InvalidDataException]::new($message, $_.Exception) }
        Write-DecisionBridgeLog -Message $message
        return $null
    }
}

function Get-CopilotDecisionMarker {
    param([Parameter(Mandatory)][string]$SessionId, [switch]$RequireReadable)
    Read-DecisionMarkerFile -Path (Get-CopilotDecisionMarkerPath -SessionId $SessionId) -RequireReadable:$RequireReadable
}

function Set-CopilotDecisionMarkerInjected {
    <#
        Records the answer the daemon has already injected, so the same HA answer is
        never injected twice while the ask_user is still (briefly) shown as pending.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Answer,

        # The per-field option labels that were driven into the prompt, kept so the
        # recorded answer can be checked against them once the tool completes.
        [AllowNull()][AllowEmptyCollection()][string[]]$Selections = @()
    )
    $marker = Get-CopilotDecisionMarker -SessionId $SessionId
    if ($null -eq $marker) { return }
    $path = Get-CopilotDecisionMarkerPath -SessionId $SessionId
    $obj = @{}
    foreach ($p in $marker.PSObject.Properties) { $obj[$p.Name] = $p.Value }
    $obj['injectedAnswer'] = $Answer
    $obj['injectedSelections'] = @($Selections)
    Set-Content -LiteralPath $path -Value ($obj | ConvertTo-Json -Depth 8 -Compress) -Encoding UTF8
}

function Remove-CopilotDecisionMarker {
    param([Parameter(Mandatory)][string]$SessionId)
    $path = Get-CopilotDecisionMarkerPath -SessionId $SessionId
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

# Answers already read out of a transcript, keyed by its path, each with the length
# and write time they were read at (see Get-CopilotAskUserState).
$script:CopilotAskUserStateCache = @{}

function Get-CopilotAskUserState {
    <#
        Inspects the transcript for the most recent ask_user tool call and reports
        whether it is still awaiting input.

        The pair (tool.execution_start with toolName=ask_user) → (tool.execution_complete
        with the same toolCallId) is the authoritative "answered" signal, regardless of
        whether the answer came from the terminal or from an injected Home Assistant
        reply. Returns:
          Started   - $true if an ask_user start was found
          Pending   - $true if that start has no matching complete yet
          ToolCallId- the id of the most recent ask_user
          StartedAt - its timestamp
    #>
    param(
        [Parameter(Mandatory)][string]$TranscriptPath
    )

    $result = [pscustomobject]@{ Started = $false; Pending = $false; ToolCallId = ''; StartedAt = $null; ResultContent = '' }

    # A transcript is append-only, so the same length means the same events, and the
    # answer to "is this question still waiting?" cannot have changed. Parsing it
    # again costs 93 ms of the daemon's reconcile, paid per armed question per pass -
    # and a question sits armed for as long as it takes someone to look at their
    # phone.
    #
    # The stamp carries the write time as well as the length. The length alone would
    # miss a transcript replaced by another of exactly the same size, which is
    # unlikely rather than impossible, and the pair costs the same single stat call.
    $stamp = ''
    try {
        $info = [IO.FileInfo]::new($TranscriptPath)
        if ($info.Exists) { $stamp = "$($info.Length):$($info.LastWriteTimeUtc.Ticks)" }
    }
    catch { }

    if ($stamp) {
        $hit = $script:CopilotAskUserStateCache[$TranscriptPath]
        if ($null -ne $hit -and [string]$hit.Stamp -eq $stamp) {
            # A copy, never the stored object: handing the same instance to every
            # caller would let one of them edit what the next one reads.
            return $hit.Result.PSObject.Copy()
        }
    }

    # Records what was read, so the next pass over an unchanged transcript is a stat
    # call. Used for every outcome, including "no question here" - that answer costs
    # the same full parse to reach as any other.
    $remember = {
        param($Answer)
        if ($stamp) {
            # The daemon outlives every session it watches, so this would otherwise
            # grow an entry per transcript forever. Emptying it costs one parse per
            # session still being watched, which is rare enough not to matter.
            if ($script:CopilotAskUserStateCache.Count -ge 64) { $script:CopilotAskUserStateCache.Clear() }
            $script:CopilotAskUserStateCache[$TranscriptPath] = @{ Stamp = $stamp; Result = $Answer.PSObject.Copy() }
        }
        $Answer
    }

    $lines = @(Get-CopilotTranscriptTailLines -Path $TranscriptPath)
    if ($lines.Count -eq 0) { return $result }

    # Walk forward, tracking the latest ask_user start and the set of completed ids.
    $latestStartId = ''
    $latestStartAt = $null
    $completed = @{}
    $results = @{}
    foreach ($line in $lines) {
        if ($line -notmatch '"type":"tool\.execution_(start|complete)"') { continue }
        try {
            $o = $line | ConvertFrom-Json
        }
        catch { continue }

        if ($o.type -eq 'tool.execution_start' -and [string]$o.data.toolName -eq 'ask_user') {
            $latestStartId = [string]$o.data.toolCallId
            $latestStartAt = $o.timestamp
        }
        elseif ($o.type -eq 'tool.execution_complete') {
            $cid = [string]$o.data.toolCallId
            if (-not [string]::IsNullOrWhiteSpace($cid)) {
                $completed[$cid] = $true
                # Keep the answer the CLI actually recorded, so an injected form can be
                # checked against it. An arrow-key selection that lands one option
                # short is otherwise indistinguishable from a correct one, and answers
                # with the wrong choice in the user's name.
                #
                # A tool call that FAILED carries `error` instead of `result`. Reaching
                # straight through `.result.content` makes StrictMode throw, and that
                # terminating error kills the daemon's entire reconcile loop - so one
                # unrelated failed tool anywhere in the transcript tail leaves every
                # armed card unanswerable.
                $content = ''
                $data = $o.data
                if ($null -ne $data -and $data.PSObject.Properties.Name -contains 'result') {
                    $res = $data.result
                    if ($null -ne $res -and $res.PSObject.Properties.Name -contains 'content') {
                        $content = [string]$res.content
                    }
                }
                $results[$cid] = $content
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($latestStartId)) { return (& $remember $result) }
    $result.Started = $true
    $result.ToolCallId = $latestStartId
    $result.StartedAt = $latestStartAt
    $result.Pending = -not $completed.ContainsKey($latestStartId)
    if ($results.ContainsKey($latestStartId)) { $result.ResultContent = [string]$results[$latestStartId] }
    & $remember $result
}

function Test-CopilotAnswerMatchesSelections {
    <#
        Verifies choice identities within their own fields, never by substring.
        Structured JSON preserves scalar types and compares text fields literally.
        Known text encodings verify choices only, when each observed label/value maps
        to one option unambiguously; legacy free-text rendering may reformat input.

        Detailed returns Matched, Mismatch or Unconfirmed. Missing/unsupported data
        is not a match and is not evidence for overriding a terminal answer. Legacy
        markers without field names retain unambiguous label-based addressing.
    #>
    param(
        [AllowNull()][AllowEmptyString()][object]$ResultContent,
        [AllowNull()][AllowEmptyCollection()][object[]]$Fields,
        [AllowNull()][AllowEmptyCollection()][string[]]$Selections,
        [switch]$Detailed
    )

    $finish = {
        param([string]$Status)
        if ($Detailed) { [pscustomobject]@{ Status = $Status } }
        else { $Status -ceq 'Matched' }
    }
    $fieldList = @($Fields)
    $selectionList = @($Selections)
    if ($fieldList.Count -eq 0 -or $selectionList.Count -ne $fieldList.Count -or $null -eq $ResultContent) {
        return (& $finish 'Unconfirmed')
    }

    $answers = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $textMode = $false
    $singleValue = $false
    $content = $ResultContent
    if ($content -is [string]) {
        $text = $content.Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return (& $finish 'Unconfirmed') }
        if ($text.StartsWith('{', [StringComparison]::Ordinal)) {
            try { $content = ConvertFrom-DecisionJson -Json $text }
            catch { return (& $finish 'Unconfirmed') }
        }
        else {
            $textMode = $true
            $nativeSingle = $text.StartsWith('User responded: ', [StringComparison]::Ordinal)
            if ($nativeSingle) { $text = $text.Substring('User responded: '.Length) }
            elseif ($text.StartsWith('User has answered your questions: ', [StringComparison]::Ordinal)) {
                $text = $text.Substring('User has answered your questions: '.Length)
                $suffix = ". You can now continue with the user's answers in mind."
                if ($text.EndsWith($suffix, [StringComparison]::Ordinal)) { $text = $text.Substring(0, $text.Length - $suffix.Length) }
            }
            elseif ($text.StartsWith('Your questions have been answered: ', [StringComparison]::Ordinal)) {
                $text = $text.Substring('Your questions have been answered: '.Length)
                if ($text.EndsWith('".', [StringComparison]::Ordinal)) { $text = $text.Substring(0, $text.Length - 1) }
            }
            if ($nativeSingle -and $fieldList.Count -eq 1 -and -not $text.Contains('=')) {
                $singleValue = $true
                $answers.Add('', $text)
            }
            else {
                $pair = [regex]'\G\s*(?<key>"(?:[^"\\]|\\.)*"|[^=,"]+?)\s*=\s*(?<value>"(?:[^"\\]|\\.)*"|[^,"]*)\s*(?:,\s*|$)'
                $offset = 0
                while ($offset -lt $text.Length) {
                    $match = $pair.Match($text, $offset)
                    if (-not $match.Success -or $match.Length -eq 0) { return (& $finish 'Unconfirmed') }
                    $key = $match.Groups['key'].Value.Trim()
                    $value = $match.Groups['value'].Value.Trim()
                    try {
                        if ($key.StartsWith('"')) { $key = ConvertFrom-DecisionJson -Json $key }
                        if ($value.StartsWith('"')) { $value = ConvertFrom-DecisionJson -Json $value }
                    }
                    catch { return (& $finish 'Unconfirmed') }
                    if ($answers.ContainsKey($key)) { return (& $finish 'Unconfirmed') }
                    $answers.Add($key, $value)
                    $offset += $match.Length
                }
            }
        }
    }

    if (-not $textMode) {
        if ($content -is [Collections.IDictionary]) {
            foreach ($key in $content.Keys) {
                if ($key -isnot [string] -or $answers.ContainsKey($key)) { return (& $finish 'Unconfirmed') }
                $answers.Add($key, $content[$key])
            }
        }
        elseif ($content -is [pscustomobject]) {
            foreach ($property in $content.PSObject.Properties) { $answers.Add($property.Name, $property.Value) }
        }
        else { return (& $finish 'Unconfirmed') }
    }
    if ($answers.Count -ne $fieldList.Count) { return (& $finish 'Unconfirmed') }

    $scalarKey = {
        param([AllowNull()]$Value)
        if ($null -ne $Value -and [Type]::GetTypeCode($Value.GetType()).ToString() -notin
            @('String', 'Boolean', 'SByte', 'Byte', 'Int16', 'UInt16', 'Int32', 'UInt32', 'Int64', 'UInt64', 'Single', 'Double', 'Decimal')) { return $null }
        ConvertTo-Json -InputObject $Value -Compress
    }
    $consumed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $verified = 0
    $mismatch = $false
    for ($i = 0; $i -lt $fieldList.Count; $i++) {
        $field = $fieldList[$i]
        if ($null -eq $field) { return (& $finish 'Unconfirmed') }
        $key = ''
        if (-not $singleValue) {
            $name = if ($field.PSObject.Properties['Name']) { [string]$field.Name }
                    elseif ($field.PSObject.Properties['Title']) { [string]$field.Title }
                    else { [string]$field.Label }
            $comparer = if ($field.PSObject.Properties['Name'] -or $field.PSObject.Properties['Title']) {
                [StringComparer]::Ordinal
            } else { [StringComparer]::OrdinalIgnoreCase }
            $keys = @($answers.Keys | Where-Object { $comparer.Equals($_, $name) })
            if ($keys.Count -ne 1) { return (& $finish 'Unconfirmed') }
            $key = $keys[0]
        }
        if (-not $consumed.Add($key)) { return (& $finish 'Unconfirmed') }
        if (Test-DecisionFieldIsText -Field $field) {
            if ($textMode) { continue }
            if ($answers[$key] -isnot [string]) { return (& $finish 'Unconfirmed') }
            if (-not [StringComparer]::Ordinal.Equals($answers[$key], $selectionList[$i])) { $mismatch = $true }
            $verified++
            continue
        }

        $multi = Test-DecisionFieldIsMultiSelect -Field $field
        $options = @($field.Options)
        $wanted = if ($multi) { @(Resolve-DecisionMultiSelectChoice -Field $field -Choice $selectionList[$i]) }
                  else { @($selectionList[$i]) }
        $expected = [Collections.Generic.HashSet[int]]::new()
        foreach ($option in $wanted) {
            $index = [Array]::IndexOf($options, $option)
            if ($index -lt 0 -or -not $expected.Add($index)) { return (& $finish 'Unconfirmed') }
        }
        if ($expected.Count -eq 0) { return (& $finish 'Unconfirmed') }
        $identities = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
        for ($index = 0; $index -lt $options.Count; $index++) {
            try { $value = Get-DecisionFieldOptionValue -Field $field -Option $options[$index] }
            catch { return (& $finish 'Unconfirmed') }
            $valueKey = & $scalarKey $value
            if ($null -eq $valueKey) { return (& $finish 'Unconfirmed') }
            $encodings = @($valueKey)
            if ($textMode) {
                $spelling = if ($value -is [string]) { $value } else { $valueKey }
                $encodings = @([string]$options[$index], $spelling)
                # Delimiters, quoting and trimmed whitespace can encode two different
                # answers identically. Only structured results can resolve these.
                if (@($encodings | Where-Object { $_ -match '[,="]' -or $_ -cne $_.Trim() }).Count -gt 0) {
                    return (& $finish 'Unconfirmed')
                }
            }
            foreach ($encoding in $encodings) {
                if ($identities.ContainsKey($encoding) -and $identities[$encoding] -ne $index) {
                    $identities[$encoding] = -1
                }
                else { $identities[$encoding] = $index }
            }
        }
        $actualValue = $answers[$key]
        $parts = [object[]]::new(1)
        if ($multi -and $textMode) { $parts = @(([string]$actualValue).Split(',') | ForEach-Object { $_.Trim() }) }
        elseif ($multi -and $actualValue -is [array]) { $parts = @($actualValue) }
        elseif (-not $multi) { $parts[0] = $actualValue }
        else { return (& $finish 'Unconfirmed') }
        $actual = [Collections.Generic.HashSet[int]]::new()
        foreach ($part in $parts) {
            $encoding = if ($textMode) { [string]$part } else { & $scalarKey $part }
            if ($null -eq $encoding -or -not $identities.ContainsKey($encoding) -or
                $identities[$encoding] -lt 0 -or -not $actual.Add($identities[$encoding])) { return (& $finish 'Unconfirmed') }
        }
        if (-not $actual.SetEquals($expected)) { $mismatch = $true }
        $verified++
    }
    if ($verified -eq 0) { return (& $finish 'Unconfirmed') }
    if ($mismatch) { return (& $finish 'Mismatch') }
    & $finish 'Matched'
}

function Get-DecisionFieldOptionValue {
    <#
        The typed value at an exact, unique option position. Older markers without
        Values use their labels; an invalid mapping is never guessed.
    #>
    param(
        [AllowNull()][object]$Field,
        [AllowEmptyString()][string]$Option
    )

    if ($null -eq $Field) { throw [IO.InvalidDataException]::new('Missing decision field.') }
    $options = @($Field.Options)
    $values = $options
    if ($Field.PSObject.Properties['Values']) { $values = @($Field.Values) }
    if ($options.Count -ne $values.Count) { throw [IO.InvalidDataException]::new('Decision option and value counts differ.') }
    $found = -1
    for ($i = 0; $i -lt $options.Count; $i++) {
        if ([StringComparer]::Ordinal.Equals([string]$options[$i], $Option)) {
            if ($found -ge 0) { throw [IO.InvalidDataException]::new('Ambiguous decision option.') }
            $found = $i
        }
    }
    if ($found -lt 0) { throw [IO.InvalidDataException]::new('Unknown decision option.') }
    return ,$values[$found]
}

function Get-CopilotTranscriptTailLines {
    <#
        `Get-Content -Tail` walks a transcript backwards line by line and takes over
        twenty seconds on a multi-megabyte events.jsonl, which is long enough to blow
        the agentStop hook timeout. Seeking to a byte offset and decoding forward is
        effectively instant.

        Seeking can land mid-character or mid-line, so the first line of a partial
        read is discarded.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [int]$MaxBytes = 4194304
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $stream = $null
    $partial = $false
    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite
        )
        $start = [Math]::Max(0, $stream.Length - $MaxBytes)
        $partial = $start -gt 0
        if ($partial) {
            [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        }
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false))
        $text = $reader.ReadToEnd()
    }
    catch {
        return @()
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    $lines = @(($text -replace "`r", '') -split "`n")
    if ($partial -and $lines.Count -gt 1) {
        $lines = @($lines[1..($lines.Count - 1)])
    }
    $lines
}

function Test-CopilotSessionWorking {
    param(
        [Parameter(Mandatory)]
        [string]$SessionId
    )

    $safeKey = Get-CopilotSafeSessionKey -SessionId $SessionId
    $eventsPath = Join-Path (
        Join-Path $script:DecisionBridgeConfig.SessionStateRoot $safeKey
    ) 'events.jsonl'
    if (-not (Test-Path -LiteralPath $eventsPath)) {
        return $false
    }

    $turnState = $null
    $lines = @(Get-CopilotTranscriptTailLines -Path $eventsPath)
    foreach ($line in $lines) {
        if ($line.StartsWith('{"type":"assistant.turn_start"')) {
            $turnState = 'working'
        }
        elseif ($line.StartsWith('{"type":"assistant.turn_end"')) {
            $turnState = 'idle'
        }
    }

    if ($null -eq $turnState) {
        foreach ($line in (Get-Content -LiteralPath $eventsPath)) {
            if ($line.StartsWith('{"type":"assistant.turn_start"')) {
                $turnState = 'working'
            }
            elseif ($line.StartsWith('{"type":"assistant.turn_end"')) {
                $turnState = 'idle'
            }
        }
    }

    $turnState -eq 'working'
}










function Send-BridgeNotification {
    <#
        Sends an out-of-band notification, if one is configured.

        `notifications.service` is any Home Assistant notify-style service, so this
        works with notify.notify, a mobile app notifier, or a custom integration. The
        extra Ticker-specific fields are only sent to a ticker.* service, because a
        standard notify service rejects unknown keys.

        A notification failure is logged and swallowed: the decision is already on the
        dashboard, and losing the push must not fail the ask_user.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    if (-not $script:DecisionBridgeConfig.NotifyEnabled) { return }
    $service = [string]$script:DecisionBridgeConfig.NotifyService
    $parts = $service.Split('.')
    if ($parts.Count -ne 2) {
        Write-DecisionBridgeLog -Message "notifications.service '$service' is not domain.service; skipping"
        return
    }

    $data = @{ title = $Title; message = $Message }
    if ($parts[0] -eq 'ticker') {
        $data['category'] = $script:DecisionBridgeConfig.TickerCategory
        $data['actions'] = 'none'
        $data['navigate_to'] = $script:DecisionBridgeConfig.DashboardPath
        $data['expiration'] = 8
    }

    try {
        Invoke-HomeAssistantService -Domain $parts[0] -Service $parts[1] -Headers $Headers -Data $data
    }
    catch {
        Write-DecisionBridgeLog -Message "notification via $service failed: $($_.Exception.Message)"
    }
}










