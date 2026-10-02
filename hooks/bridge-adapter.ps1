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

function Read-BridgeStopPrompts {
    <# The recorded prompts, or an empty map. Never throws: this is display state. #>
    $path = try { Get-BridgeStopPromptPath } catch { return @{} }
    if (-not (Test-Path -LiteralPath $path)) { return @{} }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable) }
    catch { return @{} }
}

function Write-BridgeStopPrompt {
    <#
        Records, or clears, that one session is showing the End session question.

        Deliberately display state and nothing more. The question is pinned by every
        process that publishes activity, but only the daemon holds the arm that can
        answer it, and this file is never consulted when deciding whether a press
        confirms. So a stale file can at worst leave a prompt on a card for a few
        seconds; it can never stop a session.

        That separation is the point. Publish-BridgeSessionStatus also runs inside
        standalone hook processes - a Claude Notification is the case that found this -
        which have no daemon state at all, and were publishing their own status line
        straight over the question while the session was still armed.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [AllowNull()][object]$Until = $null,
        [AllowEmptyString()][string]$Hint = ''
    )

    try {
        $path = Get-BridgeStopPromptPath
        $prompts = Read-BridgeStopPrompts
        if ($null -eq $Until) { [void]$prompts.Remove($SessionId) }
        else { $prompts[$SessionId] = @{ until = ([datetimeoffset]$Until).ToString('o'); hint = $Hint } }
        if ($prompts.Count -eq 0) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            return
        }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
        Set-Content -LiteralPath $path -Value ($prompts | ConvertTo-Json -Depth 4 -Compress) -Encoding utf8
    }
    catch {
        # A card that misses the question is better than a hook that fails because of it.
    }
}

function Get-BridgeStopPrompt {
    <#
        The End session question one session is showing, or $null.

        Expiry is carried in the record rather than inferred, so a file left behind by
        a daemon that died stops pinning anything of its own accord.
    #>
    param([Parameter(Mandatory)][string]$SessionId)

    $prompts = Read-BridgeStopPrompts
    if (-not $prompts.ContainsKey($SessionId)) { return $null }
    $entry = $prompts[$SessionId]
    $until = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$entry.until, [ref]$until)) { return $null }
    if ([datetimeoffset]::Now -gt $until) { return $null }
    $entry
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
        $summary = $Activity
        if (Get-Command -Name Get-DaemonCardSummary -CommandType Function -ErrorAction Ignore) {
            $summary = Get-DaemonCardSummary -SessionId $SessionId -Summary $summary -Detail $detail
        }
        else {
            $prompt = Get-BridgeStopPrompt -SessionId $SessionId
            if ($null -ne $prompt) {
                $summary = $script:CopilotEndSessionConfirmNote
                $detail['hint'] = [string]$prompt.hint
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
