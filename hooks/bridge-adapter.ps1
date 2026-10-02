<#
.SYNOPSIS
    Client-neutral adapter orchestration for the Home Assistant bridge.

.DESCRIPTION
    The Copilot, Claude and Codex hooks all translate a front-end event into the same
    handful of Home Assistant operations: gate on reachability, make sure the session's
    entities exist, publish a status and activity, and push a notification. That
    orchestration used to be copy-pasted into every hook, so a fix to the timeout, the
    entity-adoption dance, or the notification shape had to be made in several places.

    These functions are that shared orchestration. An adapter is now responsible only
    for the client-specific parts - parsing its event schema, discovering its
    transcript and owning process, and mapping an event to a status/activity - and
    calls into here for everything that is the same across front ends.

    Depends on decision-bridge-common.ps1 (reachability, headers, deadline,
    notifications) and decision-mqtt.ps1 (entity publish/status/activity). Callers that
    use Confirm-BridgeSessionEntities must also have decision-ha-websocket.ps1 loaded,
    because publishing a new session resolves its entity ids over the WebSocket.
#>

# Deliberately no top-level Set-StrictMode: this library is dot-sourced into hook
# scripts, and Set-StrictMode leaks into the dot-sourcing scope. The Copilot hooks
# (route-ask-user-v3, notify-agent-response) are not written under StrictMode, so
# forcing it on them changes their behaviour. The functions below are strict-safe
# regardless, and the test suite dot-sources them under StrictMode to keep them so.

function Enter-BridgeAdapterSession {
    <#
        The reachability gate every adapter runs before touching Home Assistant.

        Returns the request headers when Home Assistant is reachable, having set the
        per-hook deadline; returns $null when it is not, so the caller can exit
        silently and let the daemon catch up. A hook must never wait on the network,
        which is why the probe is short and a miss is not an error.
    #>
    param(
        [int]$ProbeTimeoutSec = 2,
        [int]$DeadlineSeconds = 45
    )

    if (-not (Test-HomeAssistantReachable -TimeoutSec $ProbeTimeoutSec)) {
        Write-DecisionBridgeLog -Message 'Home Assistant unreachable; skipping (the daemon will catch up)'
        return $null
    }
    Set-DecisionBridgeDeadline -Seconds $DeadlineSeconds
    Get-HomeAssistantHeaders
}

function Test-BridgeSessionEntityPresent {
    <#
        True when a session entity already exists in Home Assistant. Used to decide
        whether to publish a session on demand, and to touch only existing entities
        from a turn-end hook. An unreadable state is treated as absent.
    #>
    param(
        [Parameter(Mandatory)][string]$EntityId,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    try {
        $probe = Get-HomeAssistantState -EntityId $EntityId -Headers $Headers
        return ($null -ne $probe -and [string]$probe.state -notin @('unavailable', ''))
    }
    catch {
        return $false
    }
}

function Confirm-BridgeSessionEntities {
    <#
        Ensures a session's entities exist, publishing them on demand when they do not.

        A hook can be the first thing a session ever does - a notification, an
        ask_user - so waiting for the daemon's reconcile would delay exactly the alert
        that matters. Publishing here fills that gap; the short sleep lets Home
        Assistant register the discovery config before the ids are pinned.

        Returns $true when the entities already existed (nothing was published).
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)][string]$Machine,
        [Parameter(Mandatory)][hashtable]$Headers,
        # Which entity to probe for existence. Defaults to the status sensor; the
        # ask_user router probes the decision selector instead.
        [string]$ProbeEntity
    )

    $node = Get-CopilotMqttNodeId -SessionId $SessionId
    if ([string]::IsNullOrWhiteSpace($ProbeEntity)) { $ProbeEntity = "sensor.${node}_status" }

    $exists = Test-BridgeSessionEntityPresent -EntityId $ProbeEntity -Headers $Headers
    if (-not $exists) {
        Publish-CopilotMqttSession -SessionId $SessionId -SessionName $SessionName `
            -Machine $Machine -Headers $Headers | Out-Null
        Start-Sleep -Milliseconds 1500
        [void](Set-CopilotMqttEntityIds -SessionId $SessionId)
    }
    $exists
}

function Get-BridgeStopPromptPath {
    <# Where the daemon records which sessions are currently showing the End session question. #>
    Get-BridgeRuntimePath 'agent-bridge-stop-prompt.json'
}

function Read-BridgeStopPromptStore {
    <#
        The recorded prompts, as { State; Prompts }.

        State is 'Empty' when there is definitively nothing recorded, 'Ok' when the
        document was read and validated, and 'Failed' when it exists but could not be
        read or did not hold what it should.

        The three are kept apart deliberately. Collapsing a read failure into "nothing
        recorded" is what let a publisher treat an unreadable store as an absent
        question and write over one that was on screen - the same cross-writer defect
        the store exists to close, arriving through the store itself.

        The shape is validated rather than trusted: a document holding null, an array
        or a string answers neither .Keys nor .ContainsKey, and reached the hook as an
        exception on a path that must not throw.
    #>
    $path = try { Get-BridgeStopPromptPath } catch { return @{ State = 'Failed'; Prompts = @{} } }
    if (-not (Test-Path -LiteralPath $path)) { return @{ State = 'Empty'; Prompts = @{} } }

    $parsed = $null
    try { $parsed = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable }
    catch { return @{ State = 'Failed'; Prompts = @{} } }
    if ($parsed -isnot [System.Collections.IDictionary]) { return @{ State = 'Failed'; Prompts = @{} } }

    $prompts = @{}
    foreach ($key in @($parsed.Keys)) {
        if ($key -isnot [string] -or [string]::IsNullOrWhiteSpace($key)) { return @{ State = 'Failed'; Prompts = @{} } }
        $entry = $parsed[$key]
        if ($entry -isnot [System.Collections.IDictionary] -or -not $entry.Contains('until')) {
            return @{ State = 'Failed'; Prompts = @{} }
        }
        $until = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse([string]$entry['until'], [ref]$until)) {
            return @{ State = 'Failed'; Prompts = @{} }
        }
        $hint = if ($entry.Contains('hint')) { [string]$entry['hint'] } else { '' }
        $prompts[$key] = @{ Until = $until; Hint = $hint }
    }
    @{ State = 'Ok'; Prompts = $prompts }
}

function Write-BridgeStopPrompt {
    <#
        Records, or clears, that one session is showing the End session question.
        Returns $true only when the store now says what it was asked to say.

        The caller must honour that answer. An arm held in memory whose record could
        not be written is consent that no other publisher can see, so the next hook to
        publish wipes the question while a second press still confirms - which is
        exactly the defect this store closes. Set-DaemonStopArm therefore refuses to
        arm when this fails.

        Published atomically, through a temporary file and a replacing move, because a
        reader in another process can otherwise observe a half-written document.

        On an unreadable store both a record and a clear are refused. Rewriting would
        drop the entries that could not be parsed. Clearing used to be honoured, on the
        grounds that removing the document repairs it - but a per-session clear fell
        through to the whole-file delete below and took every other session's question
        with it, while their arms stayed live in the daemon. A standalone publisher
        then overwrote a question a second press could still confirm: the very
        cross-writer defect this store exists to close, arriving through the repair.
        Repair is Clear-BridgeStopPromptStore, and belongs to the daemon, which is the
        only thing that can invalidate the consent such a repair would strand.

        Deliberately display state and nothing more. The question is pinned by every
        process that publishes activity, but only the daemon holds the arm that can
        answer it, and this file is never consulted when deciding whether a press
        confirms. A record that outlives its daemon can at worst leave a prompt on a
        card until its own expiry; it can never stop a session.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [AllowNull()][object]$Until = $null,
        [AllowEmptyString()][string]$Hint = ''
    )

    $tmp = $null
    try {
        $path = Get-BridgeStopPromptPath
        $tmp = "$path.pending"
        $store = Read-BridgeStopPromptStore
        if ($store.State -eq 'Failed') { return $false }

        $prompts = @{}
        if ($store.State -eq 'Ok') {
            foreach ($key in @($store.Prompts.Keys)) {
                $prompts[$key] = @{ until = $store.Prompts[$key].Until.ToString('o'); hint = $store.Prompts[$key].Hint }
            }
        }
        if ($null -eq $Until) { [void]$prompts.Remove($SessionId) }
        else { $prompts[$SessionId] = @{ until = ([datetimeoffset]$Until).ToString('o'); hint = $Hint } }

        if ($prompts.Count -eq 0) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
            return $true
        }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
        Set-Content -LiteralPath $tmp -Value ($prompts | ConvertTo-Json -Depth 4 -Compress) -Encoding utf8 -ErrorAction Stop
        [IO.File]::Move($tmp, $path, $true)
        $true
    }
    catch {
        if ($null -ne $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        $false
    }
}

function Clear-BridgeStopPromptStore {
    <#
        Removes the whole prompt store, and returns whether it is now gone.

        The only way to repair a document that cannot be read: a per-session clear
        refuses to touch it, because removing one key means rewriting entries it
        cannot parse, and deleting it outright would unpin questions belonging to arms
        that are still live.

        So this invalidates every recorded question at once, and its callers must have
        invalidated the matching consent first. Both do: daemon startup restores no
        arms at all, and the repair path in Remove-DaemonStopArm drops every arm it
        holds before calling this.
    #>
    try {
        $path = Get-BridgeStopPromptPath
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
        Remove-Item -LiteralPath "$path.pending" -Force -ErrorAction SilentlyContinue
        $true
    }
    catch { $false }
}

function Get-BridgeStopPrompt {
    <#
        The End session question one session is showing, as { State; Hint }.

        State is 'Prompt' when one is recorded and still live, 'None' when the store
        definitively holds none, and 'Unknown' when it could not be read. A caller
        that would overwrite the status line must not treat 'Unknown' as 'None'.

        Expiry is carried in the record rather than inferred, so a file left behind by
        a daemon that died stops pinning anything of its own accord.
    #>
    param([Parameter(Mandatory)][string]$SessionId)

    $store = Read-BridgeStopPromptStore
    if ($store.State -eq 'Failed') { return @{ State = 'Unknown'; Hint = '' } }
    if (-not $store.Prompts.ContainsKey($SessionId)) { return @{ State = 'None'; Hint = '' } }
    $entry = $store.Prompts[$SessionId]
    if ([datetimeoffset]::Now -gt $entry.Until) { return @{ State = 'None'; Hint = '' } }
    @{ State = 'Prompt'; Hint = $entry.Hint }
}

function Publish-BridgeSessionStatus {
    <#
        Publishes a session's status and, when given, its activity, with the standard
        session/machine/updated attributes every adapter uses. Extra status attributes
        (a Codex model and pid, a Claude notification message) are merged in.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)][string]$Machine,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][string]$Status,
        [string]$Activity,
        [hashtable]$ExtraAttributes,

        # Keep the activity attributes already published - the response, history and
        # reasoning the card body is drawn from - and change only the status line.
        # Without it the activity is replaced by session and machine alone, which
        # empties the card for an adapter whose daemon streams the body.
        [switch]$PreserveActivityDetail,

        # Activity attributes to set on top - a Codex reply as `response`, which the
        # card shows in full where the 255-character status line cannot.
        [hashtable]$ActivityDetail
    )

    $attributes = @{
        session = $SessionName
        machine = $Machine
        updated = [DateTimeOffset]::Now.ToString('o')
    }
    if ($ExtraAttributes) {
        foreach ($key in $ExtraAttributes.Keys) { $attributes[$key] = $ExtraAttributes[$key] }
    }

    Set-CopilotMqttStatus -SessionId $SessionId -Status $Status -Headers $Headers -Attributes $attributes
    if (-not [string]::IsNullOrWhiteSpace($Activity)) {
        $detail = @{}
        if ($PreserveActivityDetail) {
            try {
                $node = Get-CopilotMqttNodeId -SessionId $SessionId
                $current = Get-HomeAssistantState -EntityId "sensor.${node}_activity" -Headers $Headers
                foreach ($property in $current.attributes.PSObject.Properties) {
                    # Home Assistant adds these itself; echoing them back is noise.
                    if ($property.Name -in @('friendly_name', 'icon', 'device_class', 'unit_of_measurement')) { continue }
                    $detail[$property.Name] = $property.Value
                }
            }
            catch {
                # Nothing published yet: there is nothing to preserve.
            }
        }
        if ($ActivityDetail) {
            foreach ($key in $ActivityDetail.Keys) { $detail[$key] = $ActivityDetail[$key] }
        }
        $detail['session'] = $SessionName
        $detail['machine'] = $Machine
        # Every activity writer goes through the arm guard, not just the daemon's
        # transcript streamers. A Claude Notification publishes its own status line
        # straight through here, and arriving inside the confirmation window it
        # replaced the End session question while the session was still armed -
        # leaving a user who read the vanished prompt as a dead tap to press again and
        # end the turn.
        #
        # Two routes because there are two kinds of caller. Inside the daemon the arm
        # itself is in memory and authoritative. A standalone hook process has no
        # daemon state at all, so it reads the recorded prompt instead - display state
        # only, which cannot answer the question, only keep showing it.
        #
        # A store that cannot be read is not an absent question. Publishing over one
        # that is on screen is how a user comes to press End a second time, so an
        # unreadable store withholds this activity update entirely and leaves whatever
        # the card is showing; the status above is published either way.
        $summary = $Activity
        if (Get-Command -Name Get-DaemonCardSummary -CommandType Function -ErrorAction Ignore) {
            $summary = Get-DaemonCardSummary -SessionId $SessionId -Summary $summary -Detail $detail
        }
        else {
            $prompt = Get-BridgeStopPrompt -SessionId $SessionId
            if ($prompt.State -eq 'Unknown') {
                Write-DecisionBridgeLog -Message ("stop prompt store unreadable; holding back the activity " +
                    "line for $SessionId rather than risking writing over a confirmation")
                return
            }
            if ($prompt.State -eq 'Prompt') {
                $summary = $script:CopilotEndSessionConfirmNote
                $detail['hint'] = [string]$prompt.Hint
            }
        }
        Set-CopilotMqttActivity -SessionId $SessionId -Summary $summary -Detail $detail -Headers $Headers
    }
}

function Format-BridgeNotificationTitle {
    <# Caps a notification title to the length the notifier accepts. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Title)

    if ($Title.Length -gt 190) { return $Title.Substring(0, 187) + '...' }
    $Title
}

function Send-BridgeResponseNotification {
    <#
        Pushes the out-of-band preview of a finished response. The dashboard card
        carries the full text - the daemon streams it - so only a capped preview is
        sent, and nothing is sent for an empty response. The title prefix and dashboard
        label default to the wording the Claude and Codex adapters use; the Copilot
        hook overrides them for its own phrasing.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Response,
        [Parameter(Mandatory)][hashtable]$Headers,
        [string]$TitlePrefix = 'Response',
        [string]$DashboardLabel = 'the dashboard'
    )

    if ([string]::IsNullOrWhiteSpace($Response)) { return }

    $preview = $Response
    if ($preview.Length -gt 880) {
        $preview = $preview.Substring(0, 880).TrimEnd() + "...`n`nFull response is on $DashboardLabel."
    }
    Send-BridgeNotification -Title (Format-BridgeNotificationTitle "${TitlePrefix}: $SessionName") `
        -Message $preview -Headers $Headers
}
