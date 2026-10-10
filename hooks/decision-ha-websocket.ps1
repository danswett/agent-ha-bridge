<#
    Home Assistant WebSocket helpers for the Copilot CLI bridge.

    Kept separate from the dashboard builder because that script runs its rebuild on
    load, so it cannot be dot-sourced just to reuse its socket code.
#>

. (Join-Path $PSScriptRoot 'bridge-secrets.ps1')
# 1.7.0, not 1.6.0: a session waiting on a background command it started publishes
# 'shell', and the custom activity and session cards are now drawn only for a browser
# served card 1.32.0 or newer, because every older one renders it as the bare word
# under an idle-grey frame (#151). Below that the generated markdown header and stack
# are the fallback, and both were taught the status. All of it changes what
# Save-CopilotSessionDashboard renders, so the fence needs a version to move to.
#
# 1.6.0, not 1.5.0: the machine rows in the Agent sessions dropdown now carry each
# machine's own install button, and the standalone update card is drawn only for a
# browser served a card older than 1.31.0 (#129). Both change what
# Save-CopilotSessionDashboard renders, so the fence needs a version to move to.
#
# 1.5.0, not 1.4.0: the same trap as below, walked into a second time by #131, which
# gave the choices card an activity sensor to watch so a form's typed answer is held
# until the daemon confirms it was used (#104). That changed what
# Save-CopilotSessionDashboard renders while the version stayed at 1.4.0, so from
# 2026-10-08T08:13 every publication on an already-fenced machine was refused -
# "Equal render versions have conflicting content" - and the shared dashboard froze
# with peers showing no sessions. The tests cover the fence, not the pairing of a
# renderer change with a bump, so nothing failed; it is the diff that has to say it.
#
# 1.4.0, not 1.3.0: Save-CopilotSessionDashboard is one of the helpers
# Get-BridgeRenderArtifact fingerprints, and it now hands the choices card the reply
# box's topic so Send answer can publish what was typed before submitting (#93).
# Left at 1.3.0 the fence sees a new hash at the same version, which is the
# definition of a conflict there - so on any installation already fenced at the old
# renderer, publication is refused and the fix can never reach the dashboard without
# an operator pin nobody should have to take.
$script:BridgeDashboardRenderVersion = '1.7.0'
$script:BridgeDashboardObservation = $null

function Invoke-CopilotHaWebSocket {
    <#
        Runs a list of WebSocket commands against Home Assistant and returns one
        result per command, in order.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable[]]$Commands,

        [int]$TimeoutSeconds = 60
    )
    # Same token resolution as the REST helpers: config file, then environment.
    $token = (Get-HomeAssistantHeaders).Authorization -replace '^Bearer ', ''

    $wsUri = [Uri](
        ($script:DecisionBridgeConfig.HomeAssistantBaseUrl -replace '^http', 'ws').TrimEnd('/') +
        '/api/websocket'
    )

    Assert-BridgeHttpAllowed -Uri $wsUri -Transport WebSocket
    $socket = [Net.WebSockets.ClientWebSocket]::new()
    $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    $results = @()
    Assert-BridgeAuthAllowed
    try {
        try {
            [void]$socket.ConnectAsync($wsUri, $cancel.Token).GetAwaiter().GetResult()
        }
        catch {
            # A banned address is refused here, before the socket exists and before
            # any token is offered, so it is only ever visible as the upgrade's status
            # code.
            $rejection = Test-BridgeAuthRejection -ErrorRecord $_
            if ($rejection) { Register-BridgeAuthRejected -Detail '/api/websocket' -Banned:($rejection -eq 'banned') }
            throw
        }

        $receive = {
            $buffer = [ArraySegment[byte]]::new([byte[]]::new(65536))
            $text = [Text.StringBuilder]::new()
            do {
                $result = $socket.ReceiveAsync($buffer, $cancel.Token).GetAwaiter().GetResult()
                [void]$text.Append(
                    [Text.Encoding]::UTF8.GetString($buffer.Array, 0, $result.Count)
                )
            } while (-not $result.EndOfMessage)
            $text.ToString() | ConvertFrom-Json
        }

        $send = {
            param($payload)
            $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 40 -Compress))
            [void]$socket.SendAsync(
                [ArraySegment[byte]]::new($bytes),
                [Net.WebSockets.WebSocketMessageType]::Text, $true, $cancel.Token
            ).GetAwaiter().GetResult()
        }

        $hello = & $receive
        if ($hello.type -ne 'auth_required') {
            throw "Unexpected Home Assistant WebSocket greeting: $($hello.type)"
        }
        & $send @{ type = 'auth'; access_token = $token }
        $auth = & $receive
        if ($auth.type -ne 'auth_ok') {
            # This is the call Home Assistant counts towards a ban. Saying nothing
            # for a while is the only thing that stops the count rising.
            Register-BridgeAuthRejected -Detail '/api/websocket'
            throw 'Home Assistant WebSocket authentication failed.'
        }
        Register-BridgeAuthAccepted

        $id = 0
        foreach ($command in $Commands) {
            $id++
            $command['id'] = $id
            & $send $command
            $reply = & $receive
            while ($reply.type -ne 'result' -or $reply.id -ne $id) {
                $reply = & $receive
            }
            if (-not $reply.success) {
                throw "WebSocket command '$($command.type)' failed: $($reply.error | ConvertTo-Json -Compress)"
            }
            $results += , $reply.result
        }
    }
    finally {
        if ($socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
            try {
                [void]$socket.CloseAsync(
                    [Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', $cancel.Token
                ).GetAwaiter().GetResult()
            }
            catch {
                # A close failure does not invalidate results already received.
            }
        }
        $socket.Dispose()
        $cancel.Dispose()
    }

    # -NoEnumerate keeps the outer result array intact. Without it PowerShell unrolls
    # it, so a single command returning a list (for example the entity registry)
    # comes back as thousands of top-level items and indexing [0] yields one entry
    # rather than the list.
    Write-Output -NoEnumerate $results
}

function Get-BridgeStateTriggerHit {
    <#
        The change a subscribe_trigger message describes, or $null if it describes
        nothing this wait should act on.

        Separated from the receive loop because everything that can go wrong here is
        about the shape of a message rather than about the socket, and the loop cannot
        be reached without one.

        Home Assistant reports a watched entity being *removed* through this same
        state trigger, as a hit whose to_state is null. Reading .state off that is a
        PropertyNotFoundException under Set-StrictMode -Version Latest, and it was
        thrown out of the entire wait - where the daemon's only catch treats any throw
        as a dropped socket. So a session's entities being torn down was logged as
        "watch failed", counted towards the reconnect backoff and slept off for 2s,
        then 4s, then 8s, up to a minute, with nothing wrong with the connection and
        every button press on the dashboard ignored meanwhile. Seen live on 2026-10-07,
        where the throw is timestamped in the same second as the teardown that caused it.

        A removal is skipped rather than returned. Every consumer of a hit reads it as
        a press - Invoke-DaemonHit dispatches on the entity id suffix - and an entity
        that has just ceased to exist must not be delivered as a reply or a stop. The
        scheduled reconcile is what notices it has gone, and it is now reached on time
        rather than after a backoff.
    #>
    param(
        [AllowNull()]$Message,
        [AllowEmptyCollection()][string[]]$IgnoreStates = @()
    )

    # By name throughout: this is parsed from whatever arrived on the socket, and a
    # field that is simply not there is the ordinary case rather than the odd one.
    if ($null -eq $Message -or $null -eq $Message.PSObject.Properties['type'] -or
        [string]$Message.type -cne 'event') { return $null }
    if ($null -eq $Message.PSObject.Properties['event']) { return $null }
    $payload = $Message.event
    if ($null -eq $payload -or $null -eq $payload.PSObject.Properties['variables']) { return $null }
    $variables = $payload.variables
    if ($null -eq $variables -or $null -eq $variables.PSObject.Properties['trigger']) { return $null }
    $trigger = $variables.trigger
    if ($null -eq $trigger -or $null -eq $trigger.PSObject.Properties['entity_id']) { return $null }

    $entityId = [string]$trigger.entity_id
    if ([string]::IsNullOrWhiteSpace($entityId)) { return $null }

    if ($null -eq $trigger.PSObject.Properties['to_state']) { return $null }
    $toState = $trigger.to_state
    if ($null -eq $toState -or $null -eq $toState.PSObject.Properties['state']) { return $null }

    $newState = [string]$toState.state
    if ($IgnoreStates -contains $newState) { return $null }

    $attributes = $null
    if ($null -ne $toState.PSObject.Properties['attributes']) { $attributes = $toState.attributes }

    [pscustomobject]@{
        EntityId = $entityId
        State = $newState
        Attributes = $attributes
    }
}

function Wait-CopilotHaStateChange {
    <#
        Blocks until one of the watched entities changes to a state other than the
        ignored placeholders, and returns that entity id and state.

        This uses a server-side state trigger scoped to the watched entities, so Home
        Assistant only sends a message when one of them actually changes. An earlier
        version subscribed to every `state_changed` event and filtered client side,
        which on this instance meant decoding hundreds of unrelated MQTT sensor
        updates per second and burned the CPU. The trigger form sits genuinely idle
        between hits.

        Returns $null on timeout. A dropped socket also returns $null so the caller
        can decide whether to reconnect rather than having the failure thrown into
        the middle of a decision wait.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$EntityIds,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds,

        [string[]]$IgnoreStates = @('unknown', 'unavailable', ''),

        # Run every TickMilliseconds while waiting. The daemon streams transcript
        # activity from here, so it reaches Home Assistant within a tick instead of
        # after the whole wait. The pending receive is polled, never cancelled:
        # cancelling a WebSocket receive aborts the socket.
        [scriptblock]$OnTick,

        [ValidateRange(20, 5000)]
        [int]$TickMilliseconds = 100
    )
    # Same token resolution as the REST helpers: config file, then environment.
    $token = (Get-HomeAssistantHeaders).Authorization -replace '^Bearer ', ''
    $wsUri = [Uri](
        ($script:DecisionBridgeConfig.HomeAssistantBaseUrl -replace '^http', 'ws').TrimEnd('/') +
        '/api/websocket'
    )

    Assert-BridgeHttpAllowed -Uri $wsUri -Transport WebSocket
    $socket = [Net.WebSockets.ClientWebSocket]::new()
    $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds + 15))
    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)

    Assert-BridgeAuthAllowed
    try {
        try {
            [void]$socket.ConnectAsync($wsUri, $cancel.Token).GetAwaiter().GetResult()
        }
        catch {
            # A banned address is refused at the upgrade, before any token is offered.
            $rejection = Test-BridgeAuthRejection -ErrorRecord $_
            if ($rejection) { Register-BridgeAuthRejected -Detail '/api/websocket' -Banned:($rejection -eq 'banned') }
            throw
        }

        $receive = {
            param([int]$WaitSeconds)
            $buffer = [ArraySegment[byte]]::new([byte[]]::new(65536))
            $text = [Text.StringBuilder]::new()
            $perCall = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($WaitSeconds))
            try {
                do {
                    $result = $socket.ReceiveAsync($buffer, $perCall.Token).GetAwaiter().GetResult()
                    [void]$text.Append(
                        [Text.Encoding]::UTF8.GetString($buffer.Array, 0, $result.Count)
                    )
                } while (-not $result.EndOfMessage)
            }
            finally {
                $perCall.Dispose()
            }
            $text.ToString() | ConvertFrom-Json
        }

        $send = {
            param($payload)
            $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 40 -Compress))
            [void]$socket.SendAsync(
                [ArraySegment[byte]]::new($bytes),
                [Net.WebSockets.WebSocketMessageType]::Text, $true, $cancel.Token
            ).GetAwaiter().GetResult()
        }

        $hello = & $receive 30
        if ($hello.type -ne 'auth_required') {
            throw "Unexpected Home Assistant WebSocket greeting: $($hello.type)"
        }
        & $send @{ type = 'auth'; access_token = $token }
        $auth = & $receive 30
        if ($auth.type -ne 'auth_ok') {
            # The watch reconnects on every failure, so without this it offers the
            # same rejected token every cycle - six a reconcile while Home Assistant
            # was starting, against a ban threshold of ten.
            Register-BridgeAuthRejected -Detail '/api/websocket'
            throw 'Home Assistant WebSocket authentication failed.'
        }
        Register-BridgeAuthAccepted

        & $send @{
            type = 'subscribe_trigger'
            id = 1
            trigger = @{ platform = 'state'; entity_id = @($EntityIds) }
        }
        [void](& $receive 30)

        $frame = [byte[]]::new(65536)
        $pending = $null
        $text = [Text.StringBuilder]::new()

        while ([DateTimeOffset]::Now -lt $deadline) {
            # One receive stays outstanding across ticks; it is only replaced once it
            # has completed.
            if ($null -eq $pending) {
                $pending = $socket.ReceiveAsync([ArraySegment[byte]]::new($frame), $cancel.Token)
            }

            $remainingMs = [int][Math]::Max(1, ($deadline - [DateTimeOffset]::Now).TotalMilliseconds)
            $waitMs = if ($OnTick) { [Math]::Min($TickMilliseconds, $remainingMs) } else { $remainingMs }

            $arrived = $false
            try { $arrived = $pending.Wait($waitMs) }
            catch {
                # The receive faulted: the socket dropped. Let the caller reconnect.
                return $null
            }

            if (-not $arrived) {
                if ($OnTick) {
                    # A fault in the tick must not end the wait or drop the socket. Its
                    # output is captured, never emitted - it would otherwise come back
                    # as part of this function's result - and a final $true asks for
                    # the wait to end now (the daemon uses it to reconcile at once).
                    $stop = $false
                    try {
                        $ticked = @(& $OnTick)
                        if ($ticked.Count -gt 0) { $last = $ticked[-1]; $stop = ($last -is [bool] -and $last) }
                    }
                    catch {
                        if ($_.Exception.Data['BridgeTestWriteBlocked']) { throw }
                    }
                    if ($stop) { return $null }
                }
                continue
            }

            $result = $pending.Result
            $pending = $null
            if ($result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { return $null }
            [void]$text.Append([Text.Encoding]::UTF8.GetString($frame, 0, $result.Count))
            if (-not $result.EndOfMessage) { continue }

            $raw = $text.ToString()
            [void]$text.Clear()
            try { $message = $raw | ConvertFrom-Json } catch { continue }

            $hit = Get-BridgeStateTriggerHit -Message $message -IgnoreStates $IgnoreStates
            if ($null -eq $hit) { continue }
            return $hit
        }

        $null
    }
    finally {
        if ($socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
            try {
                [void]$socket.CloseAsync(
                    [Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', $cancel.Token
                ).GetAwaiter().GetResult()
            }
            catch {
                # Closing is best effort.
            }
        }
        $socket.Dispose()
        $cancel.Dispose()
    }
}

function Resolve-CopilotMqttEntityIds {
    <#
        Maps the bridge's MQTT unique_ids to the entity_ids Home Assistant actually
        assigned.

        Home Assistant derives an MQTT entity_id from the device name plus the entity
        name and ignores `object_id`, so a session named "Bridge Test" produced
        `select.copilot_bridge_test_decision` rather than the node-based id the bridge
        predicted. Predicting the id from the session name would break the moment a
        session is renamed, so the registry is the source of truth.

        Returns a hashtable keyed Decision/Reply/ReplyPayload/Status/Activity. Missing
        entries mean discovery has not registered yet.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId
    )

    $node = Get-CopilotMqttNodeId -SessionId $SessionId
    $wanted = @{
        "${node}_decision" = 'Decision'
        "${node}_reply" = 'Reply'
        "${node}_reply_payload" = 'ReplyPayload'
        "${node}_status" = 'Status'
        "${node}_activity" = 'Activity'
    }
    for ($i = 1; $i -le 4; $i++) { $wanted["${node}_f$i"] = "Field$i" }
    $wanted["${node}_submit"] = 'Submit'
    $wanted["${node}_stop"] = 'Stop'

    $registry = @(
        (Invoke-CopilotHaWebSocket -Commands @(@{ type = 'config/entity_registry/list' }))[0]
    )

    $map = @{}
    foreach ($entry in $registry) {
        $uniqueId = [string]$entry.unique_id
        if ($wanted.ContainsKey($uniqueId)) {
            $map[$wanted[$uniqueId]] = [string]$entry.entity_id
        }
    }

    $map
}

function Set-CopilotMqttGlobalEntityId {
    <#
        Forces this machine's session-count sensor onto its deterministic id. Home
        Assistant derives the id from device name plus entity name and ignores
        object_id, so the sensor first appears as sensor.ai_agent_bridge_desktop_sessions;
        rename it once so the dashboard, the peer lookup and any templates can rely on
        sensor.agent_bridge_<machine>_sessions.
    #>
    param([string]$Slug)
    if (-not $Slug) { $Slug = Get-BridgeMachineSlug }

    Set-CopilotMqttMachineEntityId -Wanted @{
        "agent_bridge_${Slug}_sessions" = Get-CopilotMqttGlobalEntityId -Slug $Slug
    }
}

function Initialize-CopilotVerboseToggle {
    <#
        Ensures input_boolean.agent_bridge_detailed_activity exists, without ever resetting
        its value.

        The dashboard's Detailed activity control targets this helper, but nothing
        else creates it, so a fresh install would render an "Entity not found" row.
        There is no config flow to hang this off — the bridge is a set of Windows
        scripts, not a Home Assistant integration — so it self-provisions here
        instead, using the input_boolean collection API over the WebSocket.

        Home Assistant restores a storage-backed input_boolean across a restart: a
        toggle left On reads On again once the core comes back (verified against a
        real core restart). The bridge's only job is therefore to make sure the helper
        exists — it must never recreate one that already exists, because a
        delete+create resets the state to Off and silently discards the user's choice.

        That is the bug this function used to cause. When the daemon (re)starts while
        Home Assistant is still booting, the helper is already in storage (so
        input_boolean/list returns it) but its state has not materialised yet. The old
        code read that transient no-state as "broken" and recreated the helper — which
        is exactly what flipped the toggle off after a restart. It never deletes a
        stored helper now; the state reappears on its own once Home Assistant finishes
        starting.

        Home Assistant slugifies the helper name into the id, so the name below must
        stay in sync with $DaemonConfig.VerboseToggle.

        Returns $true when the helper exists afterwards.
    #>
    param(
        [string]$HelperId = 'agent_bridge_detailed_activity',
        # Home Assistant slugifies this into the helper id, so the two must stay in
        # step: change one and you get a second helper rather than a renamed one.
        [string]$Name = 'Agent Bridge Detailed Activity',
        [string]$Icon = 'mdi:brain',
        # Shown on the dashboard and anywhere else Home Assistant names the entity.
        [string]$DisplayName = 'Detailed activity',
        # The pre-rename helper, migrated once and then removed.
        [string]$LegacyHelperId = 'copilot_cli_live_verbose'
    )

    # Applied on both paths below - an existing helper and a freshly created one -
    # because an install that predates this still carries the old display name.
    $applyDisplayName = {
        try {
            $registry = (Invoke-CopilotHaWebSocket -Commands @(@{ type = 'config/entity_registry/list' }))[0]
            $entry = @($registry) | Where-Object { [string]$_.entity_id -eq "input_boolean.$HelperId" } | Select-Object -First 1
            if ($entry -and [string]$entry.name -ne $DisplayName) {
                [void](Invoke-CopilotHaWebSocket -Commands @(@{
                    type      = 'config/entity_registry/update'
                    entity_id = "input_boolean.$HelperId"
                    name      = $DisplayName
                }))
            }
        }
        catch {
            # A cosmetic rename is never worth failing provisioning over.
        }
    }

    try {
        $existing = (Invoke-CopilotHaWebSocket -Commands @(@{ type = 'input_boolean/list' }))[0]
        $hasCurrent = [bool](@($existing) | Where-Object { [string]$_.id -eq $HelperId })
        $legacy = @($existing) | Where-Object { [string]$_.id -eq $LegacyHelperId } | Select-Object -First 1

        # One-time migration off the pre-rename helper. The value has to be carried
        # across by hand: creating the new helper gives it the default Off, and simply
        # deleting the old one would throw away a deliberate choice. That is the same
        # silent reset this function already exists to prevent, so it is read first
        # and re-applied after.
        if ($null -ne $legacy) {
            $wasOn = $false
            try {
                $legacyState = Get-HomeAssistantState -EntityId "input_boolean.$LegacyHelperId" -Headers (Get-HomeAssistantHeaders)
                $wasOn = ([string]$legacyState.state -eq 'on')
            }
            catch {
                # Unreadable old state: treat as off rather than guessing on.
            }

            if (-not $hasCurrent) {
                $migrated = (Invoke-CopilotHaWebSocket -Commands @(@{
                    type = 'input_boolean/create'; name = $Name; icon = $Icon
                }))[0]
                if ([string]$migrated.id -ne $HelperId) {
                    Write-Warning "Migrated toggle came back as '$($migrated.id)', expected '$HelperId'; leaving the old helper in place."
                    return $false
                }
                $hasCurrent = $true
            }

            if ($wasOn -and (Test-CopilotHelperHasState -EntityId "input_boolean.$HelperId")) {
                try {
                    Invoke-HomeAssistantService -Domain 'input_boolean' -Service 'turn_on' `
                        -Headers (Get-HomeAssistantHeaders) -Data @{ entity_id = "input_boolean.$HelperId" }
                }
                catch {
                    Write-Warning "Could not carry the toggle's On state across the rename; set it again on the dashboard."
                }
            }

            try {
                [void](Invoke-CopilotHaWebSocket -Commands @(@{
                    type = 'input_boolean/delete'; input_boolean_id = $LegacyHelperId
                }))
            }
            catch { }

            & $applyDisplayName
            return $true
        }

        if ($hasCurrent) {
            # The helper is in storage. Never delete it: its value - including one Home
            # Assistant restored across a restart - must be preserved. A missing state
            # here means Home Assistant is still starting, not that the helper is
            # broken; it will materialise on its own, so leave it untouched.
            if (-not (Test-CopilotHelperHasState -EntityId "input_boolean.$HelperId")) {
                Write-Warning "Verbose toggle is in storage but has no state yet; leaving it in place (it appears once Home Assistant finishes starting)."
            }
            & $applyDisplayName
            return $true
        }

        # Genuinely absent from storage, so create it. A brand-new install starts Off,
        # which is the right default.
        $created = (Invoke-CopilotHaWebSocket -Commands @(@{
            type = 'input_boolean/create'
            name = $Name
            icon = $Icon
        }))[0]

        # A slug mismatch almost always means the helper already existed and Home
        # Assistant de-duplicated the id - typically because the list above came back
        # transiently empty during boot. Remove the stray rather than leaving litter,
        # and trust the original helper (whose value is intact).
        if ([string]$created.id -ne $HelperId) {
            Write-Warning "Created verbose toggle as '$($created.id)', expected '$HelperId'; removing the stray and keeping the existing helper."
            try {
                [void](Invoke-CopilotHaWebSocket -Commands @(@{
                    type = 'input_boolean/delete'; input_boolean_id = [string]$created.id
                }))
            }
            catch { }
            return $true
        }
        if (-not (Test-CopilotHelperHasState -EntityId "input_boolean.$HelperId")) { return $false }

        # Give it a harness-agnostic display name without renaming the helper itself:
        # the entity_id is derived from the helper's name, and the dashboard and the
        # daemon both address it as input_boolean.agent_bridge_detailed_activity.
        & $applyDisplayName

        return $true
    }
    catch {
        Write-Warning "Could not ensure the verbose toggle: $($_.Exception.Message)"
        return $false
    }
}

function Test-CopilotHelperHasState {
    <#
        True when the entity is present in the state machine. A helper can exist in
        storage and in the entity registry yet have no state, which renders on a
        dashboard as an unavailable row.
    #>
    param([Parameter(Mandatory)][string]$EntityId)

    foreach ($attempt in 1..5) {
        Start-Sleep -Milliseconds 800
        try {
            # A missing entity is a 404, which the retry layer treats as permanent and
            # rethrows immediately, so this stays fast.
            $state = Get-HomeAssistantState -EntityId $EntityId -Headers (Get-HomeAssistantHeaders)
            if ($null -ne $state -and $state.state) { return $true }
        }
        catch { }
    }
    return $false
}

function Remove-CopilotVerboseToggle {
    <#
        Deletes the verbose toggle helper. Used by uninstall so the bridge does not
        leave a dead control behind in Home Assistant.
    #>
    param([string]$HelperId = 'agent_bridge_detailed_activity')

    $existing = (Invoke-CopilotHaWebSocket -Commands @(@{ type = 'input_boolean/list' }))[0]
    if (-not (@($existing) | Where-Object { [string]$_.id -eq $HelperId })) { return $false }
    [void](Invoke-CopilotHaWebSocket -Commands @(@{
        type = 'input_boolean/delete'
        input_boolean_id = $HelperId
    }))
    return $true
}

function Set-CopilotMqttMachineEntityId {
    <#
        Forces a set of this machine's MQTT entities onto deterministic entity ids.

        Home Assistant builds an MQTT entity id from the device name plus the entity
        name and ignores object_id, so everything here first appears as
        update.ai_agent_bridge_desktop_update and friends. The daemon reads several of
        them by id on every reconcile and the generated dashboard references them in
        templates, so they have to be predictable.

        Takes a unique_id -> entity_id map rather than owning a list, because four
        different groups need exactly this and each maintaining its own copy of the
        registry walk was three copies too many.
    #>
    param([Parameter(Mandatory)][hashtable]$Wanted)

    $registry = (Invoke-CopilotHaWebSocket -Commands @(@{ type = 'config/entity_registry/list' }))[0]
    $byUniqueId = @{}
    foreach ($entry in @($registry)) {
        if ($entry.unique_id) { $byUniqueId[[string]$entry.unique_id] = $entry }
    }

    $changed = $false
    foreach ($uniqueId in $Wanted.Keys) {
        $entry = $byUniqueId[$uniqueId]
        if ($null -eq $entry) { continue }
        if ([string]$entry.entity_id -eq $Wanted[$uniqueId]) { continue }
        [void](Invoke-CopilotHaWebSocket -Commands @(@{
            type          = 'config/entity_registry/update'
            entity_id     = [string]$entry.entity_id
            new_entity_id = $Wanted[$uniqueId]
        }))
        $changed = $true
    }
    $changed
}

function Set-CopilotMqttOnlineEntityId {
    <# The liveness sensor, which the machine list and the launch picker both key on. #>
    param([string]$Slug)
    if (-not $Slug) { $Slug = Get-BridgeMachineSlug }
    Set-CopilotMqttMachineEntityId -Wanted @{
        "agent_bridge_${Slug}_online" = Get-BridgeMachineEntityId -Domain 'binary_sensor' -Key 'online' -Slug $Slug
    }
}

function Set-CopilotMqttUpdateEntityIds {
    <#
        Forces the update entity and its install button onto deterministic ids.

        Home Assistant builds an MQTT entity id from the device name plus the entity
        name, so these first appear as update.agent_bridge_desktop_bridge_update and
        button.agent_bridge_desktop_install_bridge_update. The daemon reads the button
        by id on every reconcile, so it has to be predictable.

        Scoped to the machine, because each machine runs its own copy at its own
        version - a shared update entity showed whichever machine published last and
        its install button ran on all of them at once.
    #>
    param([string]$Slug)
    if (-not $Slug) { $Slug = Get-BridgeMachineSlug }

    $wanted = @{
        "agent_bridge_${Slug}_update"         = Get-BridgeMachineEntityId -Domain 'update' -Key 'update' -Slug $Slug
        "agent_bridge_${Slug}_install_update" = Get-BridgeMachineEntityId -Domain 'button' -Key 'install_update' -Slug $Slug
    }
    Set-CopilotMqttMachineEntityId -Wanted $wanted
}

function Set-CopilotMqttUsageEntityIds {
    <#
        Forces the per-client usage sensors onto deterministic ids.

        Same reason as the update entities, and measured on a live instance before this
        existed: the sensors arrived as sensor.ai_agent_bridge_dswett_home_github_copilot_usage,
        built from the device name plus the entity name, while the generated dashboard
        hands the card sensor.agent_bridge_dswett_home_usage_copilot. Both ends were
        correct and the card drew nothing.
    #>
    param([string]$Slug, [AllowEmptyCollection()][string[]]$Clients = @('copilot', 'claude', 'codex'))

    if (-not $Slug) { $Slug = Get-BridgeMachineSlug }
    $wanted = @{}
    foreach ($client in @($Clients)) {
        $wanted["agent_bridge_${Slug}_usage_$client"] =
            Get-BridgeMachineEntityId -Domain 'sensor' -Key "usage_$client" -Slug $Slug
    }
    if ($wanted.Count -eq 0) { return $false }
    Set-CopilotMqttMachineEntityId -Wanted $wanted
}

function Set-CopilotMqttNewSessionEntityIds {
    <#
        Forces the new-session controls onto deterministic ids.

        Same reason as the update entities: Home Assistant builds an MQTT entity id
        from device name plus entity name and ignores object_id, so these would
        otherwise appear as text.agent_bridge_desktop_new_session_prompt and friends.
        The daemon reads all four by id on every reconcile, and the generated
        dashboard references them literally, so they have to be predictable.

        Scoped to the machine, because these are the controls that launch a session on
        it. While they were shared, every daemon watched the same button with its own
        idea of when it was last pressed, so one press started a session on every
        machine at once.
    #>
    param([string]$Slug)
    if (-not $Slug) { $Slug = Get-BridgeMachineSlug }

    $wanted = @{}
    foreach ($pair in @(
        @('text',   'new_prompt'),
        @('sensor', 'new_prompt_payload'),
        @('select', 'new_workspace'),
        @('select', 'new_profile'),
        @('select', 'new_agent'),
        @('select', 'new_model'),
        @('select', 'new_effort'),
        @('select', 'new_context'),
        @('select', 'new_resume'),
        @('select', 'new_permissions'),
        @('sensor', 'transfer_request'),
        @('button', 'new_session'),
        @('sensor', 'new_session_result')
    )) {
        $wanted["agent_bridge_${Slug}_$($pair[1])"] =
            Get-BridgeMachineEntityId -Domain $pair[0] -Key $pair[1] -Slug $Slug
    }
    Set-CopilotMqttMachineEntityId -Wanted $wanted
}

$script:BridgeMachineSelectorId = 'agent_bridge_target_machine'

function Initialize-BridgeMachineSelector {
    <#
        Keeps the "which machine" picker in step with the machines that are online.

        The launch controls stay per-machine - that is what stops one press launching
        everywhere - so this helper never launches anything and no daemon reads it.
        It exists purely so the dashboard can show one launch card instead of one per
        machine: each machine's rows sit behind a conditional card keyed on this
        selection.

        Every daemon computes the same option list from the same sensors, so they all
        converge on the same value and the update is skipped when nothing changed.

        Returns the helper's entity id, or '' when there is nothing to pick between.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Machines,

        [string]$HelperId = $script:BridgeMachineSelectorId
    )

    $options = @($Machines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $entityId = "input_select.$HelperId"

    try {
        $existing = @((Invoke-CopilotHaWebSocket -Commands @(@{ type = 'input_select/list' }))[0]) |
            Where-Object { [string]$_.id -eq $HelperId } | Select-Object -First 1

        # One machine needs no picker. Don't create one, and retire one left over from
        # when there were more, so the dashboard does not keep a dead control.
        if ($options.Count -lt 2) {
            if ($existing) {
                [void](Invoke-CopilotHaWebSocket -Commands @(@{
                    type = 'input_select/delete'; input_select_id = $HelperId
                }))
            }
            return ''
        }

        if (-not $existing) {
            $created = (Invoke-CopilotHaWebSocket -Commands @(@{
                type = 'input_select/create'
                name = 'Agent bridge target machine'
                icon = 'mdi:desktop-tower-monitor'
                options = $options
            }))[0]
            # A slug mismatch means Home Assistant de-duplicated the id against a
            # helper that was already there, so keep that one and drop the stray.
            if ([string]$created.id -ne $HelperId) {
                try {
                    [void](Invoke-CopilotHaWebSocket -Commands @(@{
                        type = 'input_select/delete'; input_select_id = [string]$created.id
                    }))
                }
                catch { }
            }
            return $entityId
        }

        $current = @($existing.options)
        if (($current -join '|') -ne ($options -join '|')) {
            [void](Invoke-CopilotHaWebSocket -Commands @(@{
                type = 'input_select/update'
                input_select_id = $HelperId
                name = 'Agent bridge target machine'
                icon = 'mdi:desktop-tower-monitor'
                options = $options
            }))
            # Home Assistant recalculates the selection asynchronously after an options
            # change, and repairing before that lands is simply overwritten by it. The
            # daemon re-checks on every reconcile regardless, so this only shortens the
            # window rather than being the thing relied on.
            Start-Sleep -Milliseconds 1500
        }

        [void](Repair-BridgeMachineSelection -EntityId $entityId -Options $options)
        return $entityId
    }
    catch {
        Write-DecisionBridgeLog "machine selector update failed: $($_.Exception.Message)"
        return ''
    }
}

function Repair-BridgeMachineSelection {
    <#
        Puts the picker back on a machine that still exists.

        Home Assistant does not re-point a selection when the option it was on is
        removed - it sets the state to 'unknown', confirmed against a live instance.
        The launch rows are conditional on the selection matching a machine name, so
        an unknown selection matches nothing and the card collapses to a lone dropdown
        with no workspace, profile or Launch beneath it.

        Checked on every rebuild rather than only after an options change, because the
        state can also be left invalid by a Home Assistant restart or by editing the
        helper by hand.
    #>
    param(
        [Parameter(Mandatory)][string]$EntityId,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Options
    )

    if ($Options.Count -eq 0) { return $false }
    try {
        $state = [string](Get-HomeAssistantState -EntityId $EntityId -Headers (Get-HomeAssistantHeaders)).state
        if ($Options -contains $state) { return $false }
        Invoke-HomeAssistantService -Domain 'input_select' -Service 'select_option' `
            -Headers (Get-HomeAssistantHeaders) `
            -Data @{ entity_id = $EntityId; option = $Options[0] } | Out-Null
        return $true
    }
    catch {
        Write-DecisionBridgeLog "machine selection repair failed: $($_.Exception.Message)"
        return $false
    }
}

function Remove-BridgeMachineSelector {
    <# Drops the picker. Used by uninstall when the last machine goes. #>
    param([string]$HelperId = $script:BridgeMachineSelectorId)

    $existing = @((Invoke-CopilotHaWebSocket -Commands @(@{ type = 'input_select/list' }))[0]) |
        Where-Object { [string]$_.id -eq $HelperId } | Select-Object -First 1
    if (-not $existing) { return $false }
    [void](Invoke-CopilotHaWebSocket -Commands @(@{
        type = 'input_select/delete'; input_select_id = $HelperId
    }))
    return $true
}

$script:BridgeDashboardReady = $false

function ConvertTo-BridgePublicationJson {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return 'null' }
    # Pipeline-decorated strings can also satisfy "-is [pscustomobject]". Treat
    # primitives first or Sort-Object turns a node string into {"Length":...}.
    if ($Value -is [string] -or $Value -is [ValueType]) {
        return ConvertTo-Json -InputObject $Value -Compress -Depth 10
    }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
        $keys = if ($Value -is [System.Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
        $keys = [string[]]$keys
        [array]::Sort($keys, [StringComparer]::Ordinal)
        $members = foreach ($key in $keys) {
            if ($Value -is [System.Collections.IDictionary]) { $item = $Value[$key] }
            else { $item = $Value.$key }
            ($key | ConvertTo-Json -Compress) + ':' + (ConvertTo-BridgePublicationJson $item)
        }
        return '{' + ($members -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = foreach ($item in $Value) { ConvertTo-BridgePublicationJson $item }
        return '[' + ($items -join ',') + ']'
    }
    ConvertTo-Json -InputObject $Value -Compress -Depth 10
}

function Get-BridgePublicationHash {
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function Get-BridgeRenderArtifact {
    $source = @(
        foreach ($name in @('Save-CopilotSessionDashboard', 'Test-BridgeActivityCardServed', 'Get-BridgeDashboardInputSignature', 'ConvertTo-BridgePublicationJson')) {
            (Get-Command $name).ScriptBlock.ToString().Replace("`r`n", "`n")
        }
    ) -join "`n"
    @{
        version = $script:BridgeDashboardRenderVersion
        hash = Get-BridgePublicationHash $source
    }
}

function Assert-BridgePublicationArtifact {
    param([Parameter(Mandatory)]$Artifact)
    if ($Artifact -isnot [System.Collections.IDictionary] -or
        $Artifact.Count -ne 2 -or -not $Artifact.Contains('version') -or -not $Artifact.Contains('hash') -or
        $Artifact.version -isnot [string] -or $Artifact.version -cnotmatch '^\d+\.\d+\.\d+(\.\d+)?$' -or
        $Artifact.hash -isnot [string] -or $Artifact.hash -cnotmatch '^[a-f0-9]{64}$') {
        throw 'Publication artifact requires an exact numeric version and SHA256 content hash.'
    }
    $parsed = $null
    if (-not [version]::TryParse($Artifact.version, [ref]$parsed)) { throw 'Invalid publication artifact version.' }
}

function Get-BridgePublicationTarget {
    <# Inspect these exact targets before passing them to the one-shot policy operation. #>
    param([string]$CardSourcePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'frontend\agent-bridge-reply-card.js'))
    $card = @{
        version = Get-BridgeReplyCardFileVersion -SourcePath $CardSourcePath
        hash = (Get-FileHash -LiteralPath $CardSourcePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    }
    Assert-BridgePublicationArtifact $card
    @{ card = $card; render = Get-BridgeRenderArtifact }
}

function Get-BridgeRegisteredCardArtifact {
    param([Parameter(Mandatory)][string]$Url)
    if ($Url -notmatch '[?&]v=(\d+\.\d+\.\d+(?:\.\d+)?)(?:&|$)') {
        throw 'The registered card version is unknown; inspect and restore a versioned resource before migration.'
    }
    $versionText = $Matches[1]
    $version = $null
    if (-not [version]::TryParse($versionText, [ref]$version)) { throw 'The registered card version is malformed.' }
    $hash = $null
    if ($Url.StartsWith('data:', [StringComparison]::Ordinal)) {
        $prefix = 'data:text/javascript;base64,'
        $fragment = $Url.IndexOf('#', [StringComparison]::Ordinal)
        if (-not $Url.StartsWith($prefix, [StringComparison]::Ordinal) -or $fragment -le $prefix.Length) {
            throw 'The registered inline card is malformed.'
        }
        $bytes = [Convert]::FromBase64String($Url.Substring($prefix.Length, $fragment - $prefix.Length))
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        if ($text -notmatch "CARD_VERSION\s*=\s*'([^']+)'" -or $Matches[1] -cne $versionText) {
            throw 'The registered card content and declared version conflict.'
        }
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
    @{ version = $versionText; hash = $hash }
}

function Get-BridgePinnedCardFailure {
    param([Parameter(Mandatory)]$State)
    if (-not $State.Policy -or $State.Policy.mode -cne 'pin') { return '' }
    if ([string]::IsNullOrWhiteSpace($State.CardUrl)) {
        return 'Pinned card is missing; repair required with the exact pinned artifact before the dashboard can be current.'
    }
    try { $registered = Get-BridgeRegisteredCardArtifact -Url $State.CardUrl }
    catch {
        if ($_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        return "Pinned card cannot be verified; repair required: $($_.Exception.Message)"
    }
    if (-not $registered.hash) {
        return 'Pinned card content cannot be verified from a version-only file URL; repair required with the exact pinned inline artifact.'
    }
    if ($registered.version -cne $State.Policy.card.version -or $registered.hash -cne $State.Policy.card.hash) {
        return "Pinned card version/content does not match the exact $($State.Policy.card.version) target; repair required before the dashboard can be current."
    }
    ''
}

function Assert-BridgePublicationPolicy {
    param([Parameter(Mandatory)]$Policy)
    $keys = @('protocol', 'authority', 'writer', 'generation', 'dashboard', 'mode', 'card', 'render', 'highCard', 'highRender', 'legacyCard')
    if ($Policy -isnot [System.Collections.IDictionary] -or
        @($keys | Where-Object { -not $Policy.Contains($_) }).Count -or $Policy.Count -ne $keys.Count) {
        throw 'Malformed publication policy; restore the known policy rather than bootstrapping over it.'
    }
    if (($Policy.protocol -isnot [int] -and $Policy.protocol -isnot [long]) -or $Policy.protocol -ne 1) {
        throw 'Unsupported publication fencing protocol.'
    }
    foreach ($key in @('authority', 'writer')) {
        if ($Policy[$key] -isnot [string] -or $Policy[$key] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$') {
            throw "Invalid publication $key identity."
        }
    }
    if (($Policy.generation -isnot [int] -and $Policy.generation -isnot [long]) -or
        $Policy.generation -lt 1 -or $Policy.generation -gt [int]::MaxValue -or
        $Policy.dashboard -isnot [string] -or $Policy.dashboard -cne $script:DecisionBridgeConfig.DashboardUrlPath -or
        $Policy.mode -isnot [string] -or $Policy.mode -cnotin @('advance', 'pin') -or $Policy.legacyCard -isnot [string] -or
        ($Policy.legacyCard -and $Policy.legacyCard -cnotmatch '^[a-f0-9]{64}$')) {
        throw 'Invalid publication generation, dashboard, mode or migration target.'
    }
    foreach ($component in @('card', 'render')) {
        $high = if ($component -eq 'card') { 'highCard' } else { 'highRender' }
        Assert-BridgePublicationArtifact $Policy[$component]
        Assert-BridgePublicationArtifact $Policy[$high]
        if ([version]$Policy[$component].version -gt [version]$Policy[$high].version -or
            ($Policy.mode -ceq 'advance' -and
             (ConvertTo-BridgePublicationJson $Policy[$component]) -cne (ConvertTo-BridgePublicationJson $Policy[$high]))) {
            throw 'Publication high-water fence is inconsistent with its target.'
        }
    }
}

function Get-BridgePublicationSettings {
    $value = Get-BridgeSetting 'dashboard.publication' $null
    if ($null -eq $value) {
        throw 'Publication is not configured. Choose a designated writer and explicitly bootstrap or migrate with Set-BridgePublicationPolicy.'
    }
    $settings = $value | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
    if ($settings -isnot [System.Collections.IDictionary]) { throw 'dashboard.publication must be an explicit configuration object.' }
    foreach ($key in @('authority', 'participant', 'writer')) {
        if (-not $settings.Contains($key) -or $settings[$key] -isnot [string] -or
            $settings[$key] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$') {
            throw "Configure an explicit dashboard.publication.$key; publication identities are never inferred."
        }
    }
    if (-not $settings.Contains('generation') -or
        ($settings.generation -isnot [int] -and $settings.generation -isnot [long]) -or
        $settings.generation -lt 1 -or $settings.generation -gt [int]::MaxValue) {
        throw 'Configure an explicit positive integer dashboard.publication.generation.'
    }
    $settings
}

function Get-BridgePublicationReceiptPath {
    $endpoint = [uri]$script:DecisionBridgeConfig.HomeAssistantBaseUrl
    if (-not $endpoint.IsAbsoluteUri -or $endpoint.Scheme -notin @('http', 'https')) { throw 'Publication requires a valid configured HA HTTP authority.' }
    $key = "$($endpoint.AbsoluteUri.TrimEnd('/'))|$($script:DecisionBridgeConfig.DashboardUrlPath)"
    Get-BridgeRuntimePath -Name ("publication-" + (Get-BridgePublicationHash $key).Substring(0, 24) + '.json')
}

function Assert-BridgePublicationProgress {
    param([Parameter(Mandatory)]$Previous, [Parameter(Mandatory)]$Current)
    Assert-BridgePublicationPolicy $Previous
    Assert-BridgePublicationPolicy $Current
    if ($Previous.authority -cne $Current.authority -or $Current.generation -lt $Previous.generation) {
        throw 'Publication authority or generation conflicts with this installation''s established receipt.'
    }
    if ($Current.generation -eq $Previous.generation -and
        ($Current.writer -cne $Previous.writer -or $Current.mode -cne $Previous.mode)) {
        throw 'Changing the publication writer or rollback mode requires a new explicit generation.'
    }
    foreach ($component in @('card', 'render')) {
        $high = if ($component -eq 'card') { 'highCard' } else { 'highRender' }
        $comparison = ([version]$Current[$high].version).CompareTo([version]$Previous[$high].version)
        if ($comparison -lt 0 -or ($comparison -eq 0 -and $Current[$high].hash -cne $Previous[$high].hash)) {
            throw 'Publication high-water version/content conflicts with the established receipt.'
        }
        if ($Current.generation -eq $Previous.generation) {
            $comparison = ([version]$Current[$component].version).CompareTo([version]$Previous[$component].version)
            if (($Current.mode -ceq 'pin' -and
                 (ConvertTo-BridgePublicationJson $Current[$component]) -cne (ConvertTo-BridgePublicationJson $Previous[$component])) -or
                $comparison -lt 0 -or ($comparison -eq 0 -and $Current[$component].hash -cne $Previous[$component].hash)) {
                throw 'Publication target changed without bounded rollback authority.'
            }
        }
    }
}

function Save-BridgePublicationReceipt {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Policy)
    $path = Get-BridgePublicationReceiptPath
    $text = ConvertTo-BridgePublicationJson $Policy
    # This local mutex serializes receipts only. It is not an HA/distributed lease.
    $mutexKey = if ($IsWindows) { $path.ToLowerInvariant() } else { $path }
    $mutex = [Threading.Mutex]::new($false, ('AgentBridgePublication_' + (Get-BridgePublicationHash $mutexKey)))
    $held = $false
    $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        try { $held = $mutex.WaitOne(5000) }
        catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Publication receipt is busy; no shared write is authorized.' }
        $previous = Read-BridgeInstallRecord -Path $path
        if ($previous) {
            Assert-BridgePublicationProgress -Previous $previous -Current $Policy
            if ((ConvertTo-BridgePublicationJson $previous) -ceq $text) { return }
        }
        Write-BridgeSecretFile -Path $temporary -Content $text
        [IO.File]::Move($temporary, $path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Read-BridgePublicationState {
    param([scriptblock]$Invoker, [scriptblock]$Resources)
    if (-not $Invoker) { $Invoker = { param($commands) Invoke-CopilotHaWebSocket -Commands $commands } }
    $read = {
        param([hashtable]$command)
        $responses = & $Invoker @($command)
        if ($responses -isnot [array] -or $responses.Count -ne 1) { throw "Malformed HA result for $($command.type); it is not absence." }
        return , $responses[0]
    }
    if ($Resources) { $resourceList = @(& $Resources) }
    else { $resourceList = & $read @{ type = 'lovelace/resources' } }
    $dashboards = & $read @{ type = 'lovelace/dashboards/list' }
    if ($resourceList -isnot [array] -or $dashboards -isnot [array]) { throw 'Unreadable HA publication inventory; it is not absence.' }
    $policyResources = @()
    $cardResources = @()
    foreach ($resource in $resourceList) {
        if (-not $resource -or -not $resource.PSObject.Properties['url'] -or $resource.url -isnot [string]) {
            throw 'Malformed HA resource inventory; refusing publication.'
        }
        if ($resource.url -match '#agent-bridge-publication-policy\.js(?:\?|$)') { $policyResources += $resource }
        $named = if ($resource.url.StartsWith('data:') -and $resource.url.Contains('#')) { $resource.url.Split('#')[-1] } else { $resource.url }
        if ((($named -split '\?')[0] -split '[/\\]')[-1] -ceq 'agent-bridge-reply-card.js') { $cardResources += $resource }
    }
    if ($policyResources.Count -gt 1 -or $cardResources.Count -gt 1) { throw 'Multiple publication/card resources make writer ownership ambiguous.' }
    foreach ($owned in @($policyResources) + @($cardResources)) {
        if (-not $owned.PSObject.Properties['id'] -or $owned.id -isnot [string] -or -not $owned.id -or
            -not $owned.PSObject.Properties['type'] -or $owned.type -isnot [string] -or $owned.type -cne 'module') {
            throw 'Bridge resources require unambiguous storage-mode module registrations.'
        }
    }
    foreach ($dashboard in $dashboards) {
        if (-not $dashboard -or -not $dashboard.PSObject.Properties['url_path'] -or
            $dashboard.url_path -isnot [string] -or -not $dashboard.PSObject.Properties['id'] -or
            $dashboard.id -isnot [string] -or -not $dashboard.id) {
            throw 'Malformed HA dashboard inventory; it is not absence.'
        }
    }
    $target = @($dashboards | Where-Object { $_.url_path -ceq $script:DecisionBridgeConfig.DashboardUrlPath })
    if ($target.Count -gt 1) { throw 'Multiple target dashboards make publication ambiguous.' }
    $config = $null
    if ($target.Count) {
        try {
            $raw = & $read @{ type = 'lovelace/config'; url_path = $script:DecisionBridgeConfig.DashboardUrlPath }
            if ($null -eq $raw -or ($raw -isnot [pscustomobject] -and $raw -isnot [System.Collections.IDictionary])) {
                throw 'Malformed dashboard config read; it is not a missing view.'
            }
            $config = $raw | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
        }
        catch {
            $failure = $_
            $prefix = "WebSocket command 'lovelace/config' failed: "
            if (-not $failure.Exception.Message.StartsWith($prefix, [StringComparison]::Ordinal)) { throw }
            try { $detail = $failure.Exception.Message.Substring($prefix.Length) | ConvertFrom-Json -AsHashtable }
            catch { throw $failure }
            if ($detail -isnot [System.Collections.IDictionary] -or -not $detail.Contains('code') -or $detail.code -cne 'config_not_found') { throw $failure }
        }
    }
    $receipt = Read-BridgeInstallRecord -Path (Get-BridgePublicationReceiptPath)
    $policy = $null
    $policyResource = $null
    if ($policyResources.Count) {
        $policyResource = $policyResources[0]
        $prefix = 'data:text/javascript;base64,ZXhwb3J0IHt9Ow==#agent-bridge-publication-policy.js?policy='
        if (-not $policyResource.url.StartsWith($prefix, [StringComparison]::Ordinal)) { throw 'Malformed publication policy resource; restore the established policy.' }
        $payload = $policyResource.url.Substring($prefix.Length)
        if ($payload.Length -gt 16384) { throw 'Publication policy exceeds its bounded format.' }
        $policy = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json -AsHashtable -Depth 10
        Assert-BridgePublicationPolicy $policy
        if ($receipt) { Assert-BridgePublicationProgress -Previous $receipt -Current $policy }
        Save-BridgePublicationReceipt $policy
    }
    elseif ($receipt -or ($config -and $config.Contains('agent_bridge_publication'))) {
        throw 'Publication policy was lost after establishment. Restore the known policy resource/receipt; do not bootstrap or reset its fences.'
    }
    $card = if ($cardResources.Count) { $cardResources[0] } else { $null }
    $cardUrl = if ($card) { [string]$card.url } else { '' }
    $legacy = [bool]($card -or @($dashboards | Where-Object { $_.url_path -cin @($script:DecisionBridgeConfig.DashboardUrlPath, 'copilot-decisions') }).Count)
    [pscustomobject]@{
        Policy = $policy; PolicyResource = $policyResource; CardResource = $card; CardUrl = $cardUrl
        Dashboards = $dashboards; DashboardExists = [bool]$target.Count; Config = $config
        Kind = $(if ($policy) { 'established' } elseif ($legacy) { 'legacy' } else { 'empty' })
    }
}

function Assert-BridgePublicationWriter {
    param([Parameter(Mandatory)]$State, [ValidateSet('card', 'render')][string]$Component, $Artifact)
    try {
        if (-not $State.Policy) {
            if ($State.Kind -ceq 'legacy') {
                throw 'Publication migration required: preserve the unfenced dashboard/card, configure a designated writer, then explicitly run Set-BridgePublicationPolicy.'
            }
            throw 'Publication bootstrap required: configure a designated writer and explicitly run Set-BridgePublicationPolicy after successful absence reads.'
        }
        if ($Component -ceq 'render') {
            $cardFailure = Get-BridgePinnedCardFailure -State $State
            if ($cardFailure) { throw $cardFailure }
        }
        $settings = Get-BridgePublicationSettings
        if ($settings.authority -cne $State.Policy.authority -or $settings.writer -cne $State.Policy.writer -or
            $settings.generation -ne $State.Policy.generation -or $settings.participant -cne $State.Policy.writer) {
            throw 'This participant is not the configured writer for the established publication authority/generation.'
        }
        if ($Component) {
            Assert-BridgePublicationArtifact $Artifact
            $target = $State.Policy[$Component]
            $comparison = ([version]$Artifact.version).CompareTo([version]$target.version)
            if ($State.Policy.mode -ceq 'pin') {
                # Numeric aliases must not relabel an exact pin before receipt validation.
                if ($Artifact.version -cne $target.version -or $Artifact.hash -cne $target.hash) { throw 'Authorized rollback pins an exact publication target; automatic writers cannot leave that pin.' }
            }
            elseif ($comparison -lt 0) { throw "An older $Component cannot cross the publication version fence." }
            elseif ($comparison -eq 0 -and $Artifact.hash -cne $target.hash) { throw "Equal $Component versions have conflicting content; bump the version or explicitly authorize a pinned generation." }
        }
    }
    catch {
        $_.Exception.Data['BridgePublicationRefused'] = $true
        throw
    }
}

function New-BridgePublicationResourceCommand {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Policy, $Resource)
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-BridgePublicationJson $Policy)))
    $command = @{
        type = 'lovelace/resources/create'; res_type = 'module'
        url = 'data:text/javascript;base64,ZXhwb3J0IHt9Ow==#agent-bridge-publication-policy.js?policy=' + $payload
    }
    if ($Resource) { $command.type = 'lovelace/resources/update'; $command.resource_id = [string]$Resource.id }
    $command
}

function Update-BridgePublicationFence {
    param([ValidateSet('card', 'render')][Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Artifact, [scriptblock]$Invoker)
    if (-not $Invoker) { $Invoker = { param($commands) Invoke-CopilotHaWebSocket -Commands $commands } }
    $state = Read-BridgePublicationState -Invoker $Invoker
    Assert-BridgePublicationWriter -State $state -Component $Component -Artifact $Artifact
    if ((ConvertTo-BridgePublicationJson $state.Policy[$Component]) -cne (ConvertTo-BridgePublicationJson $Artifact)) {
        $next = (ConvertTo-BridgePublicationJson $state.Policy) | ConvertFrom-Json -AsHashtable
        $next[$Component] = $Artifact
        $next[$(if ($Component -ceq 'card') { 'highCard' } else { 'highRender' })] = $Artifact
        [void](& $Invoker @((New-BridgePublicationResourceCommand -Policy $next -Resource $state.PolicyResource)))
        $state = Read-BridgePublicationState -Invoker $Invoker
        if ((ConvertTo-BridgePublicationJson $state.Policy) -cne (ConvertTo-BridgePublicationJson $next)) {
            throw 'Publication fence write was not confirmed; no artifact write is authorized.'
        }
    }
    $state
}

function Set-BridgePublicationPolicy {
    <#
        One-shot operator action, never called by automatic publication. Target is
        an explicitly inspected Get-BridgePublicationTarget result. Generation is
        configured locally and must be exactly ExpectedGeneration + 1. An existing
        policy additionally requires its exact Get-BridgePublicationHash digest.
        Stop the designated writer while changing policy; this is not an atomic HA lease.
    #>
    param(
        [Parameter(Mandatory)][ValidateRange(0, 2147483646)][int]$ExpectedGeneration,
        [Parameter(Mandatory)][string]$ExpectedPolicyHash,
        [Parameter(Mandatory)][hashtable]$Target,
        [ValidateSet('advance', 'pin')][string]$Mode = 'advance',
        [scriptblock]$Invoker
    )
    if (-not $Invoker) { $Invoker = { param($commands) Invoke-CopilotHaWebSocket -Commands $commands } }
    $settings = Get-BridgePublicationSettings
    if ($settings.participant -cne $settings.writer -or $settings.generation -ne ($ExpectedGeneration + 1)) {
        throw 'Explicit policy action requires the designated local writer and exactly the next configured generation.'
    }
    if ($Target.Count -ne 2 -or -not $Target.ContainsKey('card') -or -not $Target.ContainsKey('render')) {
        throw 'Supply explicit card and render targets, each with version and content hash.'
    }
    Assert-BridgePublicationArtifact $Target.card
    Assert-BridgePublicationArtifact $Target.render
    $state = Read-BridgePublicationState -Invoker $Invoker
    if ($state.Policy) {
        if ($state.Policy.authority -cne $settings.authority -or $state.Policy.generation -ne $ExpectedGeneration -or
            (Get-BridgePublicationHash (ConvertTo-BridgePublicationJson $state.Policy)) -cne $ExpectedPolicyHash) {
            throw 'The expected publication authority/generation/content no longer matches; no policy change was sent.'
        }
        $highCard = $state.Policy.highCard
        $highRender = $state.Policy.highRender
    }
    else {
        if ($ExpectedGeneration -ne 0 -or $ExpectedPolicyHash -cne 'absent') { throw 'Bootstrap requires explicit expected generation zero and policy hash absent.' }
        $highCard = $Target.card
        $highRender = $Target.render
    }
    if ($state.CardUrl) {
        $registered = Get-BridgeRegisteredCardArtifact -Url $state.CardUrl
        $comparison = ([version]$registered.version).CompareTo([version]$highCard.version)
        if ($registered.hash) {
            if ($comparison -gt 0) { $highCard = $registered }
            elseif ($comparison -eq 0 -and $registered.hash -cne $highCard.hash -and $Mode -ceq 'advance') {
                throw 'The observed equal-version card content conflicts; an explicit pinned generation is required.'
            }
        }
        elseif ($comparison -gt 0) {
            throw 'An older target cannot establish a rollback fence for an opaque newer file resource; migrate its known version first.'
        }
    }
    $next = @{
        protocol = 1; authority = $settings.authority; writer = $settings.writer
        generation = $settings.generation; dashboard = $script:DecisionBridgeConfig.DashboardUrlPath
        mode = $Mode; card = $Target.card; render = $Target.render
        highCard = $highCard; highRender = $highRender
        legacyCard = $(if ($state.CardUrl) { Get-BridgePublicationHash $state.CardUrl } else { '' })
    }
    foreach ($component in @('card', 'render')) {
        $high = if ($component -ceq 'card') { 'highCard' } else { 'highRender' }
        $comparison = ([version]$Target[$component].version).CompareTo([version]$next[$high].version)
        if ($Mode -ceq 'advance' -and ($comparison -lt 0 -or
            ($comparison -eq 0 -and $Target[$component].hash -cne $next[$high].hash))) {
            throw 'An older or conflicting target requires an explicit pinned rollback generation.'
        }
        if ($comparison -gt 0) { $next[$high] = $Target[$component] }
    }
    Assert-BridgePublicationPolicy $next
    [void](& $Invoker @((New-BridgePublicationResourceCommand -Policy $next -Resource $state.PolicyResource)))
    $confirmed = Read-BridgePublicationState -Invoker $Invoker
    if ((ConvertTo-BridgePublicationJson $confirmed.Policy) -cne (ConvertTo-BridgePublicationJson $next)) { throw 'Explicit publication policy was not confirmed.' }
    $confirmed.Policy
}

function Get-BridgeDashboardInputSignature {
    param([AllowEmptyCollection()][object[]]$Sessions, [AllowEmptyCollection()][object[]]$Machines,
        [AllowEmptyString()][string]$MachineSelector, [AllowEmptyString()][string]$ReplyCardUrl)
    $sessionInputs = @($Sessions | Sort-Object Node | ForEach-Object {
        $entry = $_
        $item = @{}
        foreach ($key in @('Node', 'Name', 'Machine', 'Kind')) {
            $item[$key] = if ($entry.PSObject.Properties[$key]) { [string]$entry.$key } else { '' }
        }
        $item
    })
    $machineInputs = @($Machines | Sort-Object Slug | ForEach-Object {
        $entry = $_
        $item = @{ Slug = [string]$entry.Slug; Machine = [string]$entry.Machine }
        foreach ($key in @('IncludeProfile', 'IncludeResume', 'IncludeAgent', 'IncludeTuning', 'IncludePermissions', 'IncludeDetailed', 'IsDev', 'Online')) {
            $item[$key] = if ($entry.PSObject.Properties[$key]) { [bool]$entry.$key } else { $key -ceq 'Online' }
        }
        $item.SessionNodes = if ($entry.PSObject.Properties['SessionNodes']) { @($entry.SessionNodes | Sort-Object) } else { @() }
        $item
    })
    Get-BridgePublicationHash (ConvertTo-BridgePublicationJson @{
        sessions = $sessionInputs; machines = $machineInputs; selector = $MachineSelector; cardUrl = $ReplyCardUrl
    })
}

function Get-BridgeDashboardPublication {
    $state = Read-BridgePublicationState
    $result = [pscustomobject]@{ State = $state; Verified = $false; InputSignature = ''; ReferencedNodes = @(); Reason = 'missing policy or published receipt' }
    $cardFailure = Get-BridgePinnedCardFailure -State $state
    if ($cardFailure) { $result.Reason = $cardFailure; return $result }
    if (-not $state.Policy -or -not $state.Config -or -not $state.Config.Contains('agent_bridge_publication')) { return $result }
    $receipt = $state.Config['agent_bridge_publication']
    if ($receipt -isnot [System.Collections.IDictionary]) { throw 'Malformed dashboard publication receipt.' }
    foreach ($key in @('protocol', 'authority', 'generation', 'writer', 'render', 'inputHash', 'contentHash', 'cardUrlHash', 'renderedNodes')) {
        if (-not $receipt.Contains($key)) { throw 'Incomplete dashboard publication receipt.' }
    }
    if (($receipt.protocol -isnot [int] -and $receipt.protocol -isnot [long]) -or $receipt.protocol -ne 1 -or
        ($receipt.generation -isnot [int] -and $receipt.generation -isnot [long]) -or
        $receipt.authority -isnot [string] -or $receipt.writer -isnot [string] -or
        $receipt.renderedNodes -isnot [array] -or
        @($receipt.renderedNodes | Where-Object { $_ -isnot [string] -or $_ -cnotmatch '^[A-Za-z0-9_-]+$' }).Count) {
        throw 'Malformed dashboard publication receipt types.'
    }
    foreach ($key in @('inputHash', 'contentHash', 'cardUrlHash')) {
        if ($receipt[$key] -isnot [string] -or $receipt[$key] -cnotmatch '^[a-f0-9]{64}$') { throw 'Malformed dashboard publication receipt hash.' }
    }
    Assert-BridgePublicationArtifact $receipt.render
    $sealed = (ConvertTo-BridgePublicationJson $state.Config) | ConvertFrom-Json -AsHashtable -Depth 100
    [void]$sealed.agent_bridge_publication.Remove('contentHash')
    if ($receipt.authority -cne $state.Policy.authority -or $receipt.generation -ne $state.Policy.generation -or $receipt.writer -cne $state.Policy.writer) {
        $result.Reason = 'published authority/generation does not match policy'
    }
    elseif ((ConvertTo-BridgePublicationJson $receipt.render) -cne (ConvertTo-BridgePublicationJson $state.Policy.render)) {
        $result.Reason = 'published renderer does not match policy'
    }
    elseif ($receipt.cardUrlHash -cne (Get-BridgePublicationHash $state.CardUrl)) { $result.Reason = 'served card changed' }
    elseif ($receipt.contentHash -cne (Get-BridgePublicationHash (ConvertTo-BridgePublicationJson $sealed))) {
        $result.Reason = 'published content/receipt digest mismatch'
    }
    else { $result.Verified = $true; $result.Reason = '' }
    if ($result.Verified) {
        $result.InputSignature = $receipt.inputHash
        $result.ReferencedNodes = @($receipt.renderedNodes)
    }
    $result
}

function Remove-BridgeLegacyDashboard {
    $publication = Get-BridgeDashboardPublication
    Assert-BridgePublicationWriter -State $publication.State -Component render -Artifact (Get-BridgeRenderArtifact)
    if (-not $publication.Verified) { throw 'Legacy cleanup requires an actually published and verified replacement.' }
    if ($script:DecisionBridgeConfig.DashboardUrlPath -ceq 'copilot-decisions') { return }
    foreach ($legacy in @($publication.State.Dashboards | Where-Object { $_.url_path -ceq 'copilot-decisions' })) {
        [void](Invoke-CopilotHaWebSocket -Commands @(@{ type = 'lovelace/dashboards/delete'; dashboard_id = [string]$legacy.id }))
        Write-DecisionBridgeLog "removed the pre-rename 'copilot-decisions' dashboard after verified publication"
    }
}

function Initialize-BridgeDashboard {
    <#
        Makes sure the Lovelace dashboard the bridge writes to actually exists, and
        checks the actual publication authority, including for manual callers.

        `lovelace/config/save` only works against a registered dashboard, so a fresh
        install - or the slug change that came with the rename - needs the dashboard
        created first. Cached readiness cannot prove it still exists after deletion.
        Legacy cleanup happens only after Save verifies the replacement's contents.
    #>
    param([switch]$Force)

    # Force remains a compatibility parameter, never an authority/version bypass.
    [void]$Force
    $state = Update-BridgePublicationFence -Component render -Artifact (Get-BridgeRenderArtifact)
    $target = $script:DecisionBridgeConfig.DashboardUrlPath
    if (-not $state.DashboardExists) {
        [void](Invoke-CopilotHaWebSocket -Commands @(@{
            type = 'lovelace/dashboards/create'; url_path = $target; title = 'Agent Sessions'
            icon = 'mdi:robot'; show_in_sidebar = $true; require_admin = $false
        }))
        Write-DecisionBridgeLog "created the '$target' dashboard"
    }
    $script:BridgeDashboardReady = $true
}

function Test-BridgeActivityCardServed {
    <#
        True when the served reply-card file includes agent-bridge-activity-card (or,
        with -MinimumVersion, whatever element shipped in that version), read from
        the `?v=` cache-buster on its resource URL. The activity card first shipped in
        card version 1.10.0; agent-bridge-session-card in 1.12.0;
        agent-bridge-choices-card in 1.13.0, its whole-form shape - a labelled
        group of rows per field, replacing the per-field dropdowns - in 1.15.0, and
        agent-bridge-status-card in 1.19.0.
    #>
    param(
        [AllowEmptyString()][AllowNull()][string]$ReplyCardUrl,
        [string]$MinimumVersion = '1.10.0'
    )

    if ([string]::IsNullOrWhiteSpace($ReplyCardUrl)) { return $false }
    if ($ReplyCardUrl -notmatch '[?&]v=([0-9]+(\.[0-9]+){1,3})') { return $false }
    $served = $null
    if (-not [version]::TryParse($Matches[1], [ref]$served)) { return $false }
    $served -ge [version]$MinimumVersion
}

$script:BridgeReplyCardUrlCache = ''
$script:BridgeReplyCardUrlCachedAt = [datetime]::MinValue

function Get-BridgeServedReplyCardUrl {
    <#
        The reply card's resource URL if Home Assistant will serve it, otherwise ''.

        Read from the registered Lovelace resources rather than by fetching the file.
        The resource list is what actually decides whether a browser loads the card:
        a file sitting in www that was never registered is not usable, and rendering
        the card in that case produces an error box where the reply box should be.

        Matching is on the file name so a version query string or a different install
        location still counts. Cached because this sits on the dashboard rebuild path
        and installing the card is not something that happens mid-session.
    #>
    param(
        [scriptblock]$Resources,
        [int]$CacheSeconds = 300
    )

    if ($CacheSeconds -gt 0 -and
        ((Get-Date) - $script:BridgeReplyCardUrlCachedAt).TotalSeconds -lt $CacheSeconds) {
        return $script:BridgeReplyCardUrlCache
    }

    if (-not $Resources) {
        $Resources = { @((Invoke-CopilotHaWebSocket -Commands @(@{ type = 'lovelace/resources' }))[0]) }
    }

    $found = ''
    $readFailed = $false
    try {
        foreach ($resource in @(& $Resources)) {
            if ($null -eq $resource) { continue }
            if (-not $resource.PSObject.Properties['url']) { continue }
            $url = [string]$resource.url
            if ([string]::IsNullOrWhiteSpace($url)) { continue }
            # An inline card names itself in its fragment; its base64 body can
            # contain slashes, so only the fragment is looked at.
            $named = if ($url.StartsWith('data:') -and $url.Contains('#')) { $url.Substring($url.LastIndexOf('#') + 1) } else { $url }
            $leaf = ((($named -split '\?')[0]) -split '[/\\]')[-1]
            if ($leaf -eq 'agent-bridge-reply-card.js') { $found = $url; break }
        }
    }
    catch {
        $readFailed = $true
    }

    # A read that failed says nothing about whether the card is registered, and Home
    # Assistant restarting is exactly when it fails. Answering '' there - and then
    # caching it - rebuilt the dashboard without the session, activity and launch
    # cards for the length of the cache, so every restart visibly downgraded it to the
    # pre-card layout. The last answer that was actually read is kept instead, and the
    # cache stamp is left alone so the next pass tries again rather than waiting it out.
    # A successful read that finds nothing is different, and still means no card.
    if ($readFailed) { return $script:BridgeReplyCardUrlCache }

    $script:BridgeReplyCardUrlCache = $found
    $script:BridgeReplyCardUrlCachedAt = Get-Date
    $found
}

function Save-CopilotSessionDashboard {
    <#
        Regenerates the agent-decisions dashboard for the per-session MQTT model.

        The dashboard is fully generated from the live session list, so it is rebuilt
        whenever a session appears or exits rather than hand-edited. It has a control
        section (the session summary with its detailed-activity toggle, an update row
        and a launch card per machine) and one card per live session showing status,
        activity, the decision selector and the reply box.

        There is one dashboard however many machines are running, and it shows all of
        them. Each machine publishes what it is running to a sensor of its own, so any
        machine can render the whole picture without talking to the others. Only the
        explicitly configured writer may publish it; peers observe accepted output.

        Live count and pending-decision count are rendered as Jinja templates over the
        exact entity ids, so they stay current between rebuilds as turn state and
        armed questions change. From card 1.19.0 the status card counts them itself,
        which also picks up a machine that came online since the last rebuild.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Sessions,

        [string]$VerboseToggle = 'input_boolean.agent_bridge_detailed_activity',

        # Every machine to render controls for: Slug, Machine, and whether its launch
        # card carries the profile and resume rows. Empty means the local machine only,
        # taking those two from the switches below.
        [AllowEmptyCollection()]
        [object[]]$Machines = @(),

        # The input_select that chooses which machine the launch card is showing. Empty
        # means there is nothing to pick between, so the card is rendered directly.
        [AllowEmptyString()]
        [string]$MachineSelector = '',

        # Whether to show the Agency profile row on the new-session card.
        [switch]$IncludeProfile,

        # Whether to show the resume row on the new-session card.
        [switch]$IncludeResume,

        # Whether to show the agent row - worth it only when there is a choice.
        [switch]$IncludeAgent,

        # Whether to show the model, effort and context rows.
        [switch]$IncludeTuning,

        # Whether to show the permissions row.
        [switch]$IncludePermissions,

        # Resource URL of the reply card, or empty when Home Assistant is not serving
        # it. Empty falls back to the plain text box and Send button: a Lovelace view
        # that references a custom card which does not exist renders an error box
        # where the reply box should be, leaving no way to reply at all.
        [AllowEmptyString()]
        [string]$ReplyCardUrl = ''
    )

    $publication = Update-BridgePublicationFence -Component render -Artifact (Get-BridgeRenderArtifact)
    if (-not $PSBoundParameters.ContainsKey('ReplyCardUrl')) { $ReplyCardUrl = $publication.CardUrl }
    elseif ($ReplyCardUrl -cne $publication.CardUrl) { throw 'The served card changed; retry against the actual registered resource before rendering.' }

    $decisionEntities = @($Sessions | ForEach-Object { "select.$($_.Node)_decision" })
    $decisionList = ($decisionEntities | ForEach-Object { "'$_'" }) -join ','

    # No machine list means the caller is the only machine, so build the one entry the
    # rest of this function works from. Every control below is derived from this list,
    # so a one-machine dashboard and a five-machine one take exactly the same path.
    $machineList = @($Machines)
    if ($machineList.Count -eq 0) {
        $machineList = @([pscustomobject]@{
            Slug = Get-BridgeMachineSlug
            Machine = [Environment]::MachineName
            IncludeProfile = [bool]$IncludeProfile
            IncludeResume = [bool]$IncludeResume
            IncludeAgent = [bool]$IncludeAgent
            IncludeTuning = [bool]$IncludeTuning
            IncludePermissions = [bool]$IncludePermissions
        })
    }
    $multiMachine = $machineList.Count -gt 1

    # Only a machine that is actually running can launch anything, answer anything, or
    # install an update, so the controls are built from the online subset while the
    # machine list itself stays complete. A caller that does not track liveness - an
    # older one, or a test - is treated as all-online, which is the previous behaviour.
    $onlineList = @($machineList | Where-Object {
        $_.PSObject.Properties.Name -notcontains 'Online' -or $_.Online
    })
    if ($onlineList.Count -eq 0) { $onlineList = @($machineList) }

    $countEntities = @($onlineList | ForEach-Object {
        Get-BridgeMachineEntityId -Domain 'sensor' -Key 'sessions' -Slug $_.Slug
    })
    # int(0) on every term, so one machine whose sensor is briefly unavailable reads as
    # zero rather than turning the whole sum into an error string.
    $liveTemplate = '{{ ' + (($countEntities | ForEach-Object { "states('$_')|int(0)" }) -join ' + ') + ' }}'

    $pendingTemplate = "{% set dc = [$decisionList] %}{{ dc | map('states') | reject('in',['Idle','unavailable','unknown','']) | list | count }}"

    # The installed version comes from each machine's update entity, which its daemon
    # always publishes, so the card shows what is running without another moving part.
    # With one machine that is the whole story; with several, each machine's version
    # and liveness belong together on its own line, so the summary keeps just the
    # counts and the machines get a card of their own below.
    $versionParts = @()
    if (-not $multiMachine) {
        $soloUpdate = Get-BridgeMachineEntityId -Domain 'update' -Key 'update' -Slug $onlineList[0].Slug
        # Marked here too: a single-machine install is exactly where nobody has another
        # version to compare against and notice the difference.
        $soloDev = if ($onlineList[0].PSObject.Properties['IsDev'] -and $onlineList[0].IsDev) { ' (dev)' } else { '' }
        $versionParts = @("**Bridge** {{ state_attr('$soloUpdate', 'installed_version') or '?' }}$soloDev")
    }

    $summaryLine = "**Live sessions:** $liveTemplate &bull; **Pending decisions:** $pendingTemplate"
    if ($versionParts.Count) { $summaryLine += " &bull; $($versionParts -join ' &bull; ')" }

    $controlMarkdown = @{
        type = 'markdown'
        content = @(
            '## Agent sessions'
            ''
            $summaryLine
        ) -join "`n"
    }

    # The summary card. It carried the Detailed activity toggle too, until that became
    # the `detailedActivity` setting: folding session cards does what the toggle was
    # for, and it never changed how often anything is published. Still a stack, the
    # shape the machine-summary rows are added to.
    $agentSessionsCard = @{
        type = 'vertical-stack'
        cards = @($controlMarkdown)
    }

    # Every machine that has ever registered, live or not, with its status and version,
    # and its Detailed activity switch beside it. A machine's entities are retained, so
    # one that is switched off stays listed - and knowing a machine exists but is
    # currently off is exactly what you want when a session you expected to see is not
    # there.
    #
    # One row per machine rather than a block of text and a separate list of switches:
    # the switch belongs to the machine it is named after, and a list somewhere else
    # makes you match names up by eye. A machine running a bridge older than the switch
    # reports no capability for it and gets text alone - drawing the row anyway put an
    # "Entity not found" box on everyone's dashboard.
    $machineRows = @($machineList | ForEach-Object {
        $onlineEntity = Get-BridgeMachineEntityId -Domain 'binary_sensor' -Key 'online' -Slug $_.Slug
        $updateEntity = Get-BridgeMachineEntityId -Domain 'update' -Key 'update' -Slug $_.Slug
        $countEntity = Get-BridgeMachineEntityId -Domain 'sensor' -Key 'sessions' -Slug $_.Slug
        # The liveness sensor is not retained and expires, so "not on" covers both
        # a machine that reported offline and one that simply stopped reporting.
        #
        # "(dev)" marks a machine installed from a working copy. VERSION only moves
        # when a release is cut, so two machines days apart in features otherwise read
        # as the same number - which is how one of them came to look up to date while
        # missing a feature entirely.
        $devSuffix = if ($_.PSObject.Properties['IsDev'] -and $_.IsDev) { ' (dev)' } else { '' }
        $line = "{% if is_state('$onlineEntity','on') %}🟢 **$($_.Machine)** &bull; " +
            "{{ states('$countEntity')|int(0) }} session(s) &bull; " +
            "{{ state_attr('$updateEntity','installed_version') or '?' }}$devSuffix" +
            "{% else %}⚪ **$($_.Machine)** &bull; offline{% endif %}"
        $text = @{ type = 'markdown'; content = $line }

        if ($_.PSObject.Properties['IncludeDetailed'] -and $_.IncludeDetailed) {
            @{
                type = 'horizontal-stack'
                cards = @(
                    $text
                    @{
                        type = 'entities'
                        entities = @(@{
                            entity = (Get-BridgeMachineEntityId -Domain 'input_boolean' -Key 'detailed_activity' -Slug $_.Slug)
                            name = 'Detail'
                        })
                    }
                )
            }
        }
        else { $text }
    })
    $machinesCard = $null
    if ($machineRows.Count -gt 0) {
        $machinesCard = @{
            type = 'vertical-stack'
            cards = @(@{ type = 'markdown'; content = '### Machines' }) + $machineRows
        }
    }

    # From card 1.19.0 the summary and the machines list are one card that folds, in
    # the shape of the launch card below: the counts on the line you always see, and
    # a row per machine with its Detail switch behind a chevron. As two markdown
    # cards they took a third of a phone screen to say "three sessions, nothing
    # waiting", and the switches sat in a list you had to match up to names by eye.
    $statusCard = $null
    if (Test-BridgeActivityCardServed -ReplyCardUrl $ReplyCardUrl -MinimumVersion '1.19.0') {
        # From card 1.20.0 an offline machine's row carries an X, and pressing it
        # clears these topics from the browser. A machine that was renamed or reimaged
        # never comes back to withdraw its own entities, so its row would otherwise sit
        # there as "offline" for good. Sent as the topics themselves rather than
        # anything the card works out for itself: the two lists they come from are the
        # ones an uninstall walks, and a rule restated in JavaScript is a rule that
        # drifts.
        $canForget = Test-BridgeActivityCardServed -ReplyCardUrl $ReplyCardUrl -MinimumVersion '1.20.0'
        # From card 1.31.0 the machine's row carries its own update button, in place of
        # the Detail switch and only while there is an update to install or one running
        # (#129). Updating a machine meant finding its own card lower down the view and
        # then watching a spinner that said only that something was happening.
        $canUpdate = Test-BridgeActivityCardServed -ReplyCardUrl $ReplyCardUrl -MinimumVersion '1.31.0'
        $statusCard = [ordered]@{
            type      = 'custom:agent-bridge-status-card'
            title     = 'Agent sessions'
            decisions = @($decisionEntities)
            # Every machine that has ever registered, live or not - the card decides
            # what to show from the liveness entity, so a machine going offline does
            # not need the dashboard rebuilt to read as offline.
            machines  = @($machineList | ForEach-Object {
                $entry = [ordered]@{
                    machine  = [string]$_.Machine
                    online   = Get-BridgeMachineEntityId -Domain 'binary_sensor' -Key 'online' -Slug $_.Slug
                    sessions = Get-BridgeMachineEntityId -Domain 'sensor' -Key 'sessions' -Slug $_.Slug
                    version  = Get-BridgeMachineEntityId -Domain 'update' -Key 'update' -Slug $_.Slug
                }
                if ($_.PSObject.Properties['IncludeDetailed'] -and $_.IncludeDetailed) {
                    $entry.detailed = Get-BridgeMachineEntityId -Domain 'input_boolean' -Key 'detailed_activity' -Slug $_.Slug
                }
                # The version entity above already carries the stage and the versions;
                # only the press has nowhere else to come from. Given for every machine,
                # live or not, because the card decides from the entity whether there is
                # anything to press - and a machine whose row says offline because its
                # own daemon is mid-restart is one that may well have an update running.
                if ($canUpdate) {
                    $entry.install = Get-BridgeMachineEntityId -Domain 'button' -Key 'install_update' -Slug $_.Slug
                }
                if ($_.PSObject.Properties['IsDev'] -and $_.IsDev) { $entry.dev = $true }
                if ($canForget) {
                    $nodes = @()
                    if ($_.PSObject.Properties['SessionNodes']) { $nodes = @($_.SessionNodes) }
                    $entry.forget = @(Get-BridgeMachineForgetTopic -Slug $_.Slug -SessionNodes $nodes)
                }
                $entry
            })
        }
    }

    # The allowance each agent has left, from card 1.25.0. Every machine's usage
    # sensors are listed rather than only this machine's, because the card reconciles
    # them by account: a figure that belongs to a login rather than to a computer
    # would otherwise appear once per computer signed in to it.
    $usageCards = @()
    $usageFallbackCards = @()
    $usageEntities = @($machineList | ForEach-Object {
        $slug = $_.Slug
        foreach ($client in @('copilot', 'claude', 'codex')) {
            Get-BridgeMachineEntityId -Domain 'sensor' -Key "usage_$client" -Slug $slug
        }
    })
    if ($usageEntities.Count -gt 0) {
        if (Test-BridgeActivityCardServed -ReplyCardUrl $ReplyCardUrl -MinimumVersion '1.25.0') {
            $usageCards = @([ordered]@{
                type     = 'custom:agent-bridge-usage-card'
                title    = 'Agent usage'
                entities = @($usageEntities)
            })
        }
        else {
            # An older card drops config keys it does not know, so the gate above must
            # fall back to a standard card rather than to the same card with fewer
            # rows. A conditional keeps it off the dashboard entirely until a sensor
            # exists, because an entities card draws "Entity not found" for each one.
            # Rows are objects, not bare ids: everything else the generator emits is
            # shaped that way, and the helpers that walk a generated view expect it.
            #
            # It goes last rather than first. The real card earns the top of the view
            # by folding to one line; nine entity rows would push the session controls
            # off a phone screen on exactly the machines least able to afford it.
            $usageFallbackCards = @(@{
                type = 'conditional'
                conditions = @(@{ entity = $usageEntities[0]; state_not = 'unavailable' })
                card = @{
                    type = 'entities'
                    title = 'Agent usage'
                    entities = @($usageEntities | ForEach-Object { @{ entity = $_ } })
                }
            })
        }
    }

    # The update row and its install button only appear when an update exists. A
    # conditional card is used rather than hiding rows inside the entities card,
    # because an entities row has no condition of its own.
    #
    # One per machine: each runs its own copy at its own version, so a single shared
    # row showed whichever machine published last and its install button ran on every
    # machine at once.
    #
    # From card 1.31.0 this moves into the machine's own row in the Agent sessions
    # dropdown, where the machine already is, so it is drawn here only for a browser
    # served an older card. Both at once would offer the same press in two places and
    # the lower one would still be a spinner.
    $updateCards = @()
    if (-not ($statusCard -and $canUpdate)) {
        $updateCards = @($onlineList | ForEach-Object {
            $updateEntity = Get-BridgeMachineEntityId -Domain 'update' -Key 'update' -Slug $_.Slug
            $installEntity = Get-BridgeMachineEntityId -Domain 'button' -Key 'install_update' -Slug $_.Slug
            $title = if ($multiMachine) { "Bridge update available on $($_.Machine)" } else { 'Bridge update available' }
            @{
                type = 'conditional'
                conditions = @(@{ entity = $updateEntity; state = 'on' })
                card = @{
                    type = 'entities'
                    title = $title
                    entities = @(
                        @{ entity = $updateEntity; name = 'Version' }
                        @{ entity = $installEntity; name = 'Install now' }
                    )
                }
            }
        })
    }

    # Starting a new session. Placed with the controls rather than among the session
    # cards because it belongs to the bridge, not to any one session, and it stays
    # visible when nothing is running at all - which is exactly when it is needed.
    #
    # With several machines this reads as one card with a machine picker at the top,
    # but the rows underneath are still each machine's own entities, revealed by a
    # conditional card keyed on the picker. The picker is a display filter and nothing
    # more: no daemon reads it, and Launch presses the selected machine's own button.
    # A single shared button is precisely what made one press start a session
    # everywhere at once.
    $newSessionCards = @($onlineList | ForEach-Object {
        $slug = $_.Slug
        $rows = @()
        # Resume first: it decides whether the rows under it even apply. Defaults to
        # "New session", so the common case reads top-to-bottom as a fresh launch.
        if ($_.IncludeResume) {
            $rows += @{ entity = (Get-BridgeMachineEntityId -Domain 'select' -Key 'new_resume' -Slug $slug); name = 'Resume' }
        }
        $rows += @{ entity = (Get-BridgeMachineEntityId -Domain 'select' -Key 'new_workspace' -Slug $slug); name = 'Workspace' }
        # A peer running an older bridge reports no agent capability at all.
        if ($_.PSObject.Properties['IncludeAgent'] -and $_.IncludeAgent) {
            $rows += @{ entity = (Get-BridgeMachineEntityId -Domain 'select' -Key 'new_agent' -Slug $slug); name = 'Agent' }
        }
        # The profile row is only meaningful when Agency is installed, so it is left
        # out entirely rather than shown as a control that does nothing. It applies
        # only when Agency is the chosen agent.
        if ($_.IncludeProfile) {
            $rows += @{ entity = (Get-BridgeMachineEntityId -Domain 'select' -Key 'new_profile' -Slug $slug); name = 'Profile' }
        }
        # Model, effort and context. Below the agent because their options belong to
        # whichever agent is selected: choosing the agent is what decides what these
        # three can offer, so reading top-to-bottom is also the order to set them in.
        if ($_.PSObject.Properties['IncludeTuning'] -and $_.IncludeTuning) {
            foreach ($axis in @(Get-BridgeTuningAxes)) {
                $rows += @{
                    entity = (Get-BridgeMachineEntityId -Domain 'select' -Key "new_$axis" -Slug $slug)
                    name   = Get-BridgeTuningAxisLabel -Axis $axis
                }
            }
        }
        # Permissions last of the settings: it applies whatever else is chosen, and it
        # is the one worth reading immediately before pressing Launch.
        if ($_.PSObject.Properties['IncludePermissions'] -and $_.IncludePermissions) {
            $rows += @{
                entity = (Get-BridgeMachineEntityId -Domain 'select' -Key 'new_permissions' -Slug $slug)
                name   = 'Permissions'
            }
        }
        # The optional first message. It had been dropped as an input nobody reached
        # for, but Codex creates no session until it gets one - without it a Codex
        # launch runs in a window the dashboard can never see - and for any agent it
        # starts the work straight away.
        $rows += @{ entity = (Get-BridgeMachineEntityId -Domain 'text' -Key 'new_prompt' -Slug $slug); name = 'First message' }
        # Launch sits directly under the inputs, because they all carry a default and
        # a launch therefore needs no input at all - open the card, press Launch. What
        # the press led to shows in the note right under this card.
        $rows += @{ entity = (Get-BridgeMachineEntityId -Domain 'button' -Key 'new_session' -Slug $slug); name = 'Launch' }

        $card = @{
            type = 'entities'
            title = 'Start a new session'
            show_header_toggle = $false
            entities = $rows
        }

        # What the last press is waiting on, shown only while there is something to
        # say: "press Launch again to trust this folder", a launch in progress, or a
        # failure. A successful launch clears it, since the new session card says the
        # rest. Without this, a press that needed a second press looked like it had
        # done nothing at all.
        $resultEntity = Get-BridgeMachineEntityId -Domain 'sensor' -Key 'new_session_result' -Slug $slug
        $noteConditions = @(
            @{ entity = $resultEntity; state_not = '' }
            @{ entity = $resultEntity; state_not = 'unknown' }
            @{ entity = $resultEntity; state_not = 'unavailable' }
        )
        if ($MachineSelector) { $noteConditions = @(@{ entity = $MachineSelector; state = $_.Machine }) + $noteConditions }
        $note = @{
            type = 'conditional'
            conditions = $noteConditions
            card = @{ type = 'markdown'; content = "{{ states('$resultEntity') }}" }
        }

        # One stack, so the note always sits right under the Launch button. As two
        # top-level cards the masonry layout was free to put the note in another
        # column entirely, and a press looked like it had done nothing.
        if (-not $MachineSelector) { return @{ type = 'vertical-stack'; cards = @($card, $note) } }

        # Titles live on the outer card only; a conditional card with a titled child
        # would repeat the heading for whichever machine is selected.
        $card.Remove('title')
        @{
            type = 'conditional'
            conditions = @(@{ entity = $MachineSelector; state = $_.Machine })
            card = $card
        }
        $note
    })

    if ($MachineSelector) {
        # The picker and the rows it reveals are one card, so choosing a machine and
        # launching on it read as a single action rather than two unrelated controls.
        $newSessionCards = @(@{
            type = 'vertical-stack'
            cards = @(
                @{
                    type = 'entities'
                    title = 'Start a new session'
                    show_header_toggle = $false
                    entities = @(@{ entity = $MachineSelector; name = 'Machine' })
                }
            ) + $newSessionCards
        })
    }

    # From card 1.12.0 the bridge draws the launch card itself: one compact row of
    # agent, workspace and Launch, with resume, profile and a first message behind an
    # expander, the note right under the button, and a machine picker when there is
    # more than one. The entities card above gave every selector a full-height row,
    # so launching took a screenful. It is still built above for older cards.
    if (Test-BridgeActivityCardServed -ReplyCardUrl $ReplyCardUrl -MinimumVersion '1.12.0') {
        # The model, effort and context rows arrived with card 1.16.0. An older card
        # ignores keys it does not know, so handing them over would look like it
        # worked while the rows never appeared; gating them says plainly that this
        # dashboard has no tuning rows until the card that draws them is served.
        $tuningCard = Test-BridgeActivityCardServed -ReplyCardUrl $ReplyCardUrl -MinimumVersion '1.16.0'
        # The permissions row arrived with card 1.17.0, and is gated for the same
        # reason: an older card would silently drop the key, leaving a dashboard that
        # looks like it offers the choice and does not.
        $permissionsCard = Test-BridgeActivityCardServed -ReplyCardUrl $ReplyCardUrl -MinimumVersion '1.17.0'
        # The long prompt arrived with card 1.18.0. An older card writes the text
        # entity, which Home Assistant caps at 255 characters; a card that knows this
        # topic publishes the whole thing instead. Gated the same way, so an old card
        # is never handed a key it would drop.
        $promptPayloadCard = Test-BridgeActivityCardServed -ReplyCardUrl $ReplyCardUrl -MinimumVersion '1.18.0'
        $launchMachines = @($onlineList | ForEach-Object {
            $slug = $_.Slug
            $entry = [ordered]@{
                machine   = [string]$_.Machine
                workspace = Get-BridgeMachineEntityId -Domain 'select' -Key 'new_workspace' -Slug $slug
                prompt    = Get-BridgeMachineEntityId -Domain 'text' -Key 'new_prompt' -Slug $slug
                launch    = Get-BridgeMachineEntityId -Domain 'button' -Key 'new_session' -Slug $slug
                result    = Get-BridgeMachineEntityId -Domain 'sensor' -Key 'new_session_result' -Slug $slug
            }
            if ($_.IncludeResume) { $entry.resume = Get-BridgeMachineEntityId -Domain 'select' -Key 'new_resume' -Slug $slug }
            if ($_.PSObject.Properties['IncludeAgent'] -and $_.IncludeAgent) {
                $entry.agent = Get-BridgeMachineEntityId -Domain 'select' -Key 'new_agent' -Slug $slug
            }
            if ($_.IncludeProfile) { $entry.profile = Get-BridgeMachineEntityId -Domain 'select' -Key 'new_profile' -Slug $slug }
            if ($tuningCard -and $_.PSObject.Properties['IncludeTuning'] -and $_.IncludeTuning) {
                foreach ($axis in @(Get-BridgeTuningAxes)) {
                    $entry[$axis] = Get-BridgeMachineEntityId -Domain 'select' -Key "new_$axis" -Slug $slug
                }
            }
            if ($permissionsCard -and $_.PSObject.Properties['IncludePermissions'] -and $_.IncludePermissions) {
                $entry.permissions = Get-BridgeMachineEntityId -Domain 'select' -Key 'new_permissions' -Slug $slug
            }
            if ($promptPayloadCard) {
                $entry.promptTopic = "$(Get-CopilotMqttMachineTopicRoot -Slug $slug)/newsession/promptpayload"
            }
            $entry
        })
        $launchCard = [ordered]@{
            type     = 'custom:agent-bridge-launch-card'
            title    = 'Start a new session'
            machines = $launchMachines
        }
        if ($MachineSelector) { $launchCard.selector = $MachineSelector }
        $newSessionCards = @($launchCard)
    }

    # The control panel is a plain card pair at the top of the masonry flow, with the
    # allowances above it: what is left to spend decides whether to start anything at
    # all, so it is read before the session list rather than after it.
    $controlCards = @($usageCards)
    if ($statusCard) { $controlCards += $statusCard }
    else {
        $controlCards += $agentSessionsCard
        if ($machinesCard) { $controlCards += $machinesCard }
    }
    $controlCards += $updateCards + $newSessionCards + $usageFallbackCards

    $sessionSections = foreach ($session in $Sessions) {
        $node = $session.Node

        # An MCP client publishes only a decision, a reply and a status - it never
        # sees a transcript, so there is no activity, no per-field dropdowns and no
        # submit button. Rendering it with the full template would produce six
        # "Entity not found" rows, so it gets a reduced card instead.
        $isMcp = ($session.PSObject.Properties.Name -contains 'Kind' -and [string]$session.Kind -eq 'mcp')
        if ($isMcp) {
            @{
                type = 'grid'
                square = $false
                columns = 1
                cards = @(
                    @{
                        type = 'markdown'
                        content = "### 🔌 $($session.Name)`n*MCP client* &bull; {{ states('sensor.${node}_status') }}"
                    }
                    @{
                        type = 'entities'
                        entities = @(
                            @{ entity = "select.${node}_decision"; name = 'Answer' }
                            @{ entity = "text.${node}_reply"; name = 'Reply' }
                        )
                    }
                )
            }
            continue
        }

        $statusEntity = "sensor.${node}_status"
        $activityEntity = "sensor.${node}_activity"
        $decisionEntity = "select.${node}_decision"
        $replyEntity = "text.${node}_reply"

        # The whole session is one card, not five stacked ones. The border, background
        # and state glow live on the stack; every child is stripped bare and the
        # inter-card margins collapsed, so they read as sections of one surface.
        # `overflow: hidden` keeps the children's square corners inside the rounded
        # outer edge.
        $sessionCardStyle = @"
:host {
  display: block;
  border-radius: var(--ha-card-border-radius, 12px);
  background: var(--ha-card-background, var(--card-background-color, #fff));
  overflow: hidden;
  padding: 4px 12px 10px 12px;
  box-sizing: border-box;
  {% if state_attr('$decisionEntity','question') %}
  border: 1px solid var(--warning-color);
  animation: cpwait 1.6s ease-in-out infinite;
  {% elif is_state('$statusEntity','working') %}
  border: 1px solid var(--primary-color);
  animation: cpwork 1.6s ease-in-out infinite;
  {% elif is_state('$statusEntity','agents') or is_state('$statusEntity','shell') %}
  /* Waiting on background agents, or on a command it started and has not collected:
     live, but not the session's own work, so the edge is steady rather than
     breathing. */
  border: 1px solid var(--primary-color);
  box-shadow: none;
  animation: none;
  {% else %}
  border: 1px solid var(--divider-color);
  box-shadow: none;
  animation: none;
  {% endif %}
  transition: border 0.4s ease;
}
/* Collapse the 8px the stack puts between children, so the sections butt together
   as one surface instead of floating apart. */
#root > * {
  margin-top: 0 !important;
  margin-bottom: 0 !important;
}
@keyframes cpwork {
  0%   { box-shadow: 0 0 6px 0px var(--primary-color); }
  50%  { box-shadow: 0 0 16px 2px var(--primary-color); }
  100% { box-shadow: 0 0 6px 0px var(--primary-color); }
}
@keyframes cpwait {
  0%   { box-shadow: 0 0 6px 0px var(--warning-color); }
  50%  { box-shadow: 0 0 18px 3px var(--warning-color); }
  100% { box-shadow: 0 0 6px 0px var(--warning-color); }
}
"@

        # Every child is transparent now - the stack above provides the one surface
        # they all sit on. Without this each card draws its own background and the
        # column goes back to looking like separate cards.
        $bareChild = @"
ha-card {
  border: none !important;
  box-shadow: none !important;
  background: none !important;
  margin: 0 !important;
  padding: 0 !important;
  width: 100%;
}
.card-content { padding: 0 !important; }
"@

        # The Answer and per-field dropdowns are styled to line up with the reply box
        # below them. They carried a leading icon, which indented the row, and let the
        # control hug the right edge - the exact opposite of the reply box, which
        # starts hard against the card's left edge and fills the width. Dropping the
        # icon aligns the left edges; stretching the select makes both controls span
        # the same area.
        #
        # The label is kept, unlike the reply box's: with several dropdowns stacked,
        # the field name is the only thing telling them apart.
        $selectRow = @{
            '.' = ':host { --mdc-icon-size: 0px; }'
            'hui-generic-entity-row$' = @'
state-badge { display: none !important; }
.info { flex: 0 1 auto; margin-right: 12px; }
'@
        }
        $selectRowCard = @"
$bareChild
ha-select, mwc-select { width: 100%; }
"@

        # The collapsed card always carries the whole thing: the full question when one
        # is waiting, otherwise the full text of the last response. The expander holds
        # only supporting detail - the model's reasoning when Detailed activity is on, and
        # the recent activity trail - so opening it is never required to read what was
        # actually asked or answered. Both are shown together: Claude records a thinking
        # summary only now and then, so reasoning can sit minutes behind a burst of tool
        # calls, and hiding the trail behind it made a busy session look stalled.
        $header = @{
            type = 'markdown'
            card_mod = @{ style = $bareChild }
            content = @"
### {% if state_attr('$decisionEntity','question') %}🟡{% elif is_state('$statusEntity','working') %}🟢{% elif is_state('$statusEntity','agents') or is_state('$statusEntity','shell') %}🔵{% else %}⚪{% endif %} $($session.Name)
*$($session.Machine)* &bull; status: **{% if state_attr('$decisionEntity','question') %}waiting for you{% else %}{% set st = states('$statusEntity') %}{% if st in ['unknown', 'unavailable'] %}ended{% elif st == 'agents' %}waiting for background agents{% elif st == 'shell' %}waiting for background commands{% else %}{{ st }}{% endif %}{% endif %}**{% set act = states('$activityEntity') %}{% set body = state_attr('$activityEntity','response') or '' %}{% if not (body and body.startswith(act.rstrip('.'))) %} &bull; {{ act }}{% endif %}
{% set q = state_attr('$decisionEntity','question') %}{% set resp = state_attr('$activityEntity','response') %}{% if q %}

---
**Waiting on you:**

{{ q }}{% elif resp %}

{% if state_attr('$activityEntity','response_kind') == 'reasoning' %}🧠 {% endif %}{{ resp }}{% endif %}
{% set r = state_attr('$activityEntity','reasoning') %}{% set hist = state_attr('$activityEntity','history') %}{% if r %}<details><summary><em>🧠 reasoning</em></summary>

{{ r }}
</details>{% endif %}{% if hist %}<details><summary><em>recent activity</em></summary>

{% for h in hist[-8:] %}- {{ h }}
{% endfor %}
</details>{% endif %}
"@
        }

        # The markdown header re-renders its whole template on every attribute change,
        # which snaps an open expander shut and jumps the page while reasoning streams.
        # The activity card updates in place instead. It ships in the reply card's file,
        # so it is used only when Home Assistant serves a copy new enough to have it -
        # a view naming a custom element that does not exist renders an error box.
        #
        # 1.32.0, not 1.10.0: from here the header has to be able to say a session is
        # waiting on a background command (#151). A card served between 1.10 and 1.31
        # has no branch for it and falls through to printing the bare status, so the
        # one session that must not look idle reads 'shell' under an idle-grey dot.
        # The markdown below does know it, so for that window it is the better header -
        # which is the whole point of keeping it as the fallback.
        if (Test-BridgeActivityCardServed -ReplyCardUrl $ReplyCardUrl -MinimumVersion '1.32.0') {
            $header = @{
                type     = 'custom:agent-bridge-activity-card'
                card_mod = @{ style = $bareChild }
                name     = [string]$session.Name
                machine  = [string]$session.Machine
                status   = $statusEntity
                activity = $activityEntity
                decision = $decisionEntity
            }
        }

        # The Answer control is shown only while a question is actually waiting. The
        # selector is optimistic, so the bridge drives its state to 'Awaiting answer...'
        # when arming and 'Idle' when clearing; keying off that state is what makes the
        # control appear exactly when it is usable. (An earlier version also excluded
        # 'Awaiting answer...', which hid the dropdown precisely when it was needed.)
        # On a single-field question this selector *is* the answer. On a multi-field
        # one the answer comes from the per-field dropdowns below and this carries
        # only "Cancel request" - so labelling it "Answer" made it read as one more
        # question to fill in, sitting right where the last field should be. The two
        # cases are split by whether the first field slot is carrying options.
        # The rows come from the custom card when Home Assistant serves a build that
        # has it; the dropdown stays as the fallback. Home Assistant's own select
        # sizes its menu to the longest option and will not wrap, so on a phone a
        # question whose answers are sentences ran off the right edge unreadable.
        #
        # From card 1.15.0 the same card answers the whole form: it is handed the
        # field selectors as well, renders a labelled group of rows per armed field,
        # and the split above goes away - so does the separate cancel button, which
        # the card draws as its own quiet row. The fields are handed over in slot
        # order, which is what lines each group up with the field_<n>_label attribute
        # carrying its heading and with the slot Read-DaemonFormAnswer reads.
        $formCard = Test-BridgeActivityCardServed -ReplyCardUrl $ReplyCardUrl -MinimumVersion '1.15.0'
        # From 1.22.0 the card also draws a multi-select field as checkboxes and owns
        # Send answer, which is what lets the reply box below stay the reply card even
        # while a question is waiting (see $replyCard).
        $cardOwnsSend = Test-BridgeActivityCardServed -ReplyCardUrl $ReplyCardUrl -MinimumVersion '1.22.0'
        # From 1.30.0 the reply card watches the activity sensor to learn whether the
        # answer it published was the one the daemon used. Gated on that exact version
        # rather than folded into $cardOwnsSend: a 1.22.0-1.29.0 card silently drops a
        # config key it does not know, so handing it one it cannot act on would look
        # like the feature was shipped while nothing watched anything.
        $cardWatchesAnswers = Test-BridgeActivityCardServed -ReplyCardUrl $ReplyCardUrl -MinimumVersion '1.30.0'
        $answerInner = @{
            type = 'entities'
            show_header_toggle = $false
            card_mod = @{ style = $selectRowCard }
            entities = @(@{ entity = $decisionEntity; name = 'Answer'; card_mod = @{ style = $selectRow } })
        }
        if (Test-BridgeActivityCardServed -ReplyCardUrl $ReplyCardUrl -MinimumVersion '1.13.0') {
            $answerInner = @{
                type     = 'custom:agent-bridge-choices-card'
                card_mod = @{ style = $bareChild }
                decision = $decisionEntity
            }
            if ($formCard) {
                $answerInner.fields = @(
                    1..$script:CopilotMqttMaxFields | ForEach-Object { Get-CopilotMqttFieldEntityId -Node $node -Index $_ }
                )
            }
            if ($cardOwnsSend) { $answerInner.submit = "button.${node}_submit" }
            # From 1.27.0 Send answer publishes the reply box before submitting, so a
            # mixed form no longer reaches the session with its typed field dropped
            # (#93). The topic is the only name both cards share, and is how the
            # choices card finds the reply card beside it.
            #
            # 1.27.0 and not 1.26.0: #98 had already shipped a different card as
            # 1.26.0, and handing this key to that one would say the machinery is
            # there when none of it is - the card would drop the key in silence and
            # go on losing typed fields. An older card does not know the key either,
            # and ignores it.
            if (Test-BridgeActivityCardServed -ReplyCardUrl $ReplyCardUrl -MinimumVersion '1.27.0') {
                $answerInner.reply_topic = (Get-CopilotMqttReplyPayloadTopic -Node $node)
            }
        }
        $answerConditions = @(
            @{ condition = 'state'; entity = $decisionEntity; state_not = 'Idle' }
            @{ condition = 'state'; entity = $decisionEntity; state_not = 'unknown' }
            @{ condition = 'state'; entity = $decisionEntity; state_not = 'unavailable' }
        )
        if (-not $formCard) {
            $answerConditions += @{ condition = 'state'; entity = "select.${node}_f1"; state = 'Idle' }
        }
        $answerCard = @{
            type = 'conditional'
            conditions = $answerConditions
            card = $answerInner
        }

        # On a multi-field question the per-field dropdowns carry the answer and the
        # main selector holds only "Cancel request" - so rendering it as another
        # dropdown put a third thing to fill in exactly where the last field should
        # be. Relabelling it was not enough: it was still a select you could open, and
        # it still read as a question. It is a button here instead, sitting with End
        # session as the secondary action it actually is.
        #
        # With the form card served this is left out entirely: the card already draws
        # 'Cancel request' as its own quiet row, and both together is two cancels.
        $cancelCard = @{
            type = 'conditional'
            conditions = @(
                @{ condition = 'state'; entity = $decisionEntity; state_not = 'Idle' }
                @{ condition = 'state'; entity = $decisionEntity; state_not = 'unknown' }
                @{ condition = 'state'; entity = $decisionEntity; state_not = 'unavailable' }
                @{ condition = 'state'; entity = "select.${node}_f1"; state_not = 'Idle' }
                @{ condition = 'state'; entity = "select.${node}_f1"; state_not = 'unknown' }
                @{ condition = 'state'; entity = "select.${node}_f1"; state_not = 'unavailable' }
            )
            card = @{
                type = 'custom:button-card'
                name = 'Cancel this request'
                icon = 'mdi:close-circle-outline'
                show_state = $false
                tap_action = @{
                    action = 'perform-action'
                    perform_action = 'select.select_option'
                    target = @{ entity_id = $decisionEntity }
                    data = @{ option = 'Cancel request' }
                }
                styles = @{
                    card = @(
                        @{ background = 'none' }
                        @{ border = 'none' }
                        @{ 'box-shadow' = 'none' }
                        @{ height = 'auto' }
                        @{ padding = '6px 0 0 0' }
                    )
                    grid = @(
                        @{ 'grid-template-areas' = '"i n"' }
                        @{ 'grid-template-columns' = 'min-content auto' }
                        @{ 'grid-template-rows' = 'auto' }
                        @{ 'justify-items' = 'start' }
                        @{ 'align-items' = 'center' }
                        @{ 'grid-gap' = '6px' }
                    )
                    img_cell = @(
                        @{ 'justify-self' = 'start' }
                        @{ margin = '0' }
                        @{ padding = '0' }
                    )
                    icon = @(
                        @{ color = 'var(--secondary-text-color)' }
                        @{ width = '17px' }
                    )
                    name = @(
                        @{ 'font-size' = '12px' }
                        @{ color = 'var(--secondary-text-color)' }
                        @{ 'justify-self' = 'start' }
                        @{ 'text-align' = 'left' }
                    )
                }
            }
        }

        # A multi-field question publishes one dropdown per field. Each is shown only
        # while it actually carries options (its state is not 'Idle'), so a question
        # with two fields shows exactly two dropdowns and the unused slots stay hidden.
        # The name is deliberately omitted: an entities card's `name` is not templated,
        # so a Jinja expression there renders as literal text. The bridge instead sets
        # each dropdown's MQTT name to the field's own label, and the card inherits it.
        #
        # These are the dropdowns the form card replaces, so with it served there are
        # none: a native select commits on blur, so answering one meant tapping the
        # option, tapping away and only then pressing Send, and it sizes its menu to
        # the longest option without wrapping, so sentence-length answers were cut off
        # on a phone. The card's rows do neither.
        $fieldCards = if ($formCard) { @() } else {
            foreach ($fi in 1..$script:CopilotMqttMaxFields) {
                $fe = Get-CopilotMqttFieldEntityId -Node $node -Index $fi
                @{
                    type = 'conditional'
                    conditions = @(
                        @{ condition = 'state'; entity = $fe; state_not = 'Idle' }
                        @{ condition = 'state'; entity = $fe; state_not = 'unknown' }
                        @{ condition = 'state'; entity = $fe; state_not = 'unavailable' }
                    )
                    card = @{
                        type = 'entities'
                        show_header_toggle = $false
                        card_mod = @{ style = $selectRowCard }
                        entities = @(@{ entity = $fe; card_mod = @{ style = $selectRow } })
                    }
                }
            }
        }

        # Reply box and Send side by side as one control. layout-card's grid gives an
        # exact "text fills the row, button is a fixed 56px column" split - a
        # horizontal-stack splits 50/50, which left a huge button beside a cramped
        # field. Each child is styled directly with card-mod rather than trying to
        # pierce the stack from its parent, which is what failed before.
        #
        # Send is what commits a reply. Home Assistant commits a text entity as soon as
        # the field loses focus, so acting on the value alone fired the moment you
        # clicked away - easy to trigger by accident and impossible to take back.
        # The row's leading icon and the card's own padding pushed the text field well
        # right of the card above it, and made the pair sit lower than the button.
        # Dropping both lines the field's left edge up with the cards above and lets
        # align-items centre the two controls against each other.
        #
        # The icon lives inside hui-generic-entity-row's shadow root, so it needs
        # card-mod's map form with a "$" suffixed selector to reach it - plain CSS in a
        # style string cannot pierce a shadow boundary.
        $bare = @"
ha-card {
  border: none;
  box-shadow: none;
  background: none;
  margin: 0;
  width: 100%;
  padding: 0;
}
.card-content { padding: 0 !important; }
"@
        $noIcon = @{
            '.' = ':host { --mdc-icon-size: 0px; }'
            'hui-generic-entity-row$' = 'state-badge { display: none !important; } .info { display: none !important; }'
        }

        # The reply box, in two shapes, chosen by which card Home Assistant serves.
        #
        # The card is much the better of the two: it reads the textarea at the moment
        # Send is pressed, so one press is always enough, it publishes over MQTT so a
        # reply is not limited to the 255 characters an entity state allows, and it
        # can carry pasted images. The text box below is kept as a fallback because a
        # view referencing a custom card that is not installed renders an error box
        # instead of a reply box, which would leave no way to reply at all.
        #
        # Until card 1.22.0 the entity pair was also what every armed question got,
        # and that was not a styling detail. A question was answered through the
        # entities - the daemon read the free-text field from text.<node>_reply and
        # waited for a press on button.<node>_submit - and the card wrote neither: its
        # Send publishes an MQTT payload, which the reply path deliberately ignores
        # while a question owns the box. Its Send also returns early on an empty
        # textarea, so a form whose only text field is optional could not be sent at
        # all. The result was a form that looked ready, took every dropdown, and did
        # nothing whatsoever on Send - silently, with not one line in the daemon log,
        # because nothing ever arrived to log.
        #
        # Both halves of that are now fixed on the daemon side, so from 1.22.0 this is
        # a fallback for an old card and nothing else.
        $fallbackReplyCard = @{
            type = 'custom:layout-card'
            # The layout card draws its own surface. That went unnoticed while every
            # sibling had one too, but against a single shared background it is the
            # one element still rendering as a separate card - so it is stripped like
            # the rest.
            card_mod = @{ style = $bareChild }
            layout_type = 'custom:grid-layout'
            layout = @{
                'grid-template-columns' = '1fr 56px'
                'grid-gap' = '0px'
                # align-items centres the pair vertically; justify-items must stay
                # stretch or the text field shrinks to its content width and floats in
                # the middle of the row instead of filling it.
                'align-items' = 'center'
                'justify-items' = 'stretch'
                margin = '6px 0 0 0'
            }
            cards = @(
                @{
                    type = 'entities'
                    show_header_toggle = $false
                    card_mod = @{ style = $bare }
                    entities = @(@{
                        entity = $replyEntity
                        name = 'Reply / continue'
                        card_mod = @{ style = $noIcon }
                    })
                }
                @{
                    type = 'custom:button-card'
                    entity = "button.${node}_submit"
                    icon = 'mdi:send'
                    show_name = $false
                    show_state = $false
                    size = '22px'
                    tap_action = @{ action = 'toggle' }
                    styles = @{
                        card = @(
                            @{ height = '48px' }
                            @{ width = '48px' }
                            @{ border = 'none' }
                            @{ 'box-shadow' = 'none' }
                            @{ background = 'none' }
                            @{ padding = '0' }
                        )
                        # button-card lays its contents out on an internal grid that
                        # still reserves a row for the (hidden) name, which floats the
                        # icon above the card's true centre. Collapsing the grid to a
                        # single centred cell puts it in the middle.
                        grid = @(
                            @{ 'grid-template-areas' = '"i"' }
                            @{ 'grid-template-rows' = '1fr' }
                            @{ 'grid-template-columns' = '1fr' }
                            @{ 'place-items' = 'center' }
                        )
                        img_cell = @(
                            @{ 'align-self' = 'center' }
                            @{ 'justify-self' = 'center' }
                            @{ margin = '0' }
                            @{ padding = '0' }
                        )
                        icon = @(@{ color = 'var(--primary-color)' })
                    }
                }
            )
        }

        # With the card served, the two swap on whether a question is waiting: the card
        # for ordinary replies, the entity pair for anything that has to be answered.
        # Without it, the pair is all there is and is always shown.
        #
        # From card 1.22.0 there is no swap. Both halves of why there had to be one
        # are gone: the daemon now reads a question's free text off the reply card's
        # own payload (Read-DaemonDecisionCardText), and Send answer moved onto the
        # choices card, so nothing is left that only the entity pair could do. What
        # replaced it is the box the rest of the session card uses - one that reads
        # the textarea at the moment Send is pressed, is not capped at 255 characters,
        # and does not need the question cleared before it works.
        $replyCard = if ($cardOwnsSend) {
            $card = @{
                type = 'custom:agent-bridge-reply-card'
                card_mod = @{ style = $bareChild }
                name = ''
                topic = (Get-CopilotMqttReplyPayloadTopic -Node $node)
                placeholder = 'Reply, or type an answer...'
            }
            # Watched only to learn the fate of an answer published for a form: the
            # daemon names the payload it consumed in answer_consumed_at, and without
            # somewhere to read that the card cannot tell a delivered answer from one
            # discarded by a race it reported as sent (#104).
            if ($cardWatchesAnswers) { $card.activity = "sensor.${node}_activity" }
            @($card)
        }
        elseif (-not [string]::IsNullOrWhiteSpace($ReplyCardUrl)) {
            @(
                @{
                    type = 'conditional'
                    conditions = @(
                        @{ condition = 'state'; entity = $decisionEntity; state = @('Idle', 'unknown', 'unavailable') }
                    )
                    card = @{
                        type = 'custom:agent-bridge-reply-card'
                        card_mod = @{ style = $bareChild }
                        # Empty so the card draws no header of its own; the session card
                        # already has one.
                        name = ''
                        topic = (Get-CopilotMqttReplyPayloadTopic -Node $node)
                        placeholder = 'Reply or continue...'
                    }
                }
                @{
                    type = 'conditional'
                    conditions = @(
                        @{ condition = 'state'; entity = $decisionEntity; state_not = 'Idle' }
                        @{ condition = 'state'; entity = $decisionEntity; state_not = 'unknown' }
                        @{ condition = 'state'; entity = $decisionEntity; state_not = 'unavailable' }
                    )
                    card = $fallbackReplyCard
                }
            )
        }
        else { $fallbackReplyCard }

        # Send feedback belongs next to Send, not in the header. The header is the
        # first thing to scroll out of view on a card carrying a long response, which
        # is precisely when a "Sending..." or "Reply NOT sent" needs to be seen.
        #
        # A conditional card rather than an always-present line: it appears only while
        # the activity is reporting on something the user just did, so it does not add
        # a permanently empty row to every card.
        $sendStates = @(
            'Sending...', 'Sending answer...', 'Nothing to send', 'Waiting for your text'
            'Reply sent', 'Reply NOT sent'
            'Answer sent', 'Answer NOT sent'
            'Not sent - answer every field'
            'Not sent - choose an option'
            'Not sent - this question takes options'
            'Not sent - no Send button on this session'
            'Answer may be wrong - check the terminal'
            # The two the completion check emits. They were produced and never listed,
            # so the one line that sits beside Send - the line still on screen once a
            # long response has scrolled the header away - stayed empty for exactly the
            # two outcomes worth reading. The header did show them, so this was never
            # wholly silent, but the actionable place was.
            'Answer differs - check the terminal'
            'Answer unconfirmed - check the terminal'
            'Ending session...', 'Could not end session'
            # End session asking for its second press, and giving up on one. Taken from
            # the constants the daemon publishes rather than written out again here: a
            # string that matches all but exactly renders as nothing at all, silently.
            $script:CopilotEndSessionConfirmNote, $script:CopilotEndSessionLapsedNote
        )
        $sendStatusCard = @{
            type = 'conditional'
            conditions = @(
                @{ condition = 'state'; entity = $activityEntity; state = $sendStates }
            )
            card = @{
                type = 'markdown'
                card_mod = @{ style = $bareChild }
                # The glyph is chosen from the state, and it used to be chosen badly:
                # it looked for an uppercase NOT and then for a lowercase 'sent', so
                # every "Not sent - ..." refusal matched the second test and was drawn
                # with a success tick. The card said a thing had been sent, in green,
                # at the moment it was refusing to send it. Refusals are matched on
                # their actual prefix now, and the two verification warnings by name.
                content = @"
{% set a = states('$activityEntity') %}{% set d = state_attr('$activityEntity','error') %}{% set h = state_attr('$activityEntity','hint') %}{% set w = state_attr('$activityEntity','waiting_on') %}
<span style="font-size:0.9em">{% if a == '$($script:CopilotEndSessionConfirmNote)' or a.startswith('Not sent') or 'NOT' in a or 'Could not' in a or 'may be wrong' in a or a == 'Answer differs - check the terminal' or a == 'Answer unconfirmed - check the terminal' %}⚠️ {% elif 'sent' in a %}✅ {% else %}⏳ {% endif %}**{{ a }}**{% if w %} — {{ w }}{% elif h %} — {{ h }}{% elif d %} — {{ d }}{% endif %}</span>
"@
            }
        }

        # Ending the session, as a footer action rather than another control in the
        # stack of controls.
        #
        # It used to be a full-width row directly beneath the reply box, which put it
        # immediately under Send - the one button you tap most, and the one you least
        # want to miss. Send sits at the right edge of the row above, so End is pinned
        # to the left and rendered small and muted: furthest from Send, and clearly
        # secondary to everything above it.
        #
        # The hairline above it does double duty - it separates End from Send, and it
        # closes the card off as a footer, which is what makes the whole thing read as
        # one unit rather than a column that simply stops.
        $stopCard = @{
            type = 'custom:button-card'
            entity = "button.${node}_stop"
            name = 'End session'
            icon = 'mdi:stop-circle-outline'
            show_state = $false
            tap_action = @{ action = 'toggle' }
            styles = @{
                card = @(
                    @{ background = 'none' }
                    @{ border = 'none' }
                    @{ 'border-top' = '1px solid var(--divider-color)' }
                    @{ 'border-radius' = '0' }
                    @{ 'box-shadow' = 'none' }
                    @{ height = 'auto' }
                    @{ padding = '8px 0 0 0' }
                    @{ 'margin-top' = '10px' }
                )
                # Icon and label on one left-aligned row. Without collapsing
                # button-card's default grid the label stacks under the icon and
                # centres itself, which reads as a primary action rather than a
                # footer link.
                grid = @(
                    @{ 'grid-template-areas' = '"i n"' }
                    @{ 'grid-template-columns' = 'min-content auto' }
                    @{ 'grid-template-rows' = 'auto' }
                    @{ 'justify-items' = 'start' }
                    @{ 'align-items' = 'center' }
                    @{ 'grid-gap' = '6px' }
                )
                img_cell = @(
                    @{ 'justify-self' = 'start' }
                    @{ margin = '0' }
                    @{ padding = '0' }
                )
                icon = @(
                    @{ color = 'var(--secondary-text-color)' }
                    @{ width = '17px' }
                )
                name = @(
                    @{ 'font-size' = '12px' }
                    @{ color = 'var(--secondary-text-color)' }
                    @{ 'justify-self' = 'start' }
                    @{ 'text-align' = 'left' }
                )
            }
        }

        # Each session is one stack of its own cards. In a masonry view these stacks
        # are packed into columns by height rather than aligned into rows, which is
        # what stops one tall session from leaving dead space under every shorter card
        # beside it.
        #
        # The bridge's own session card draws the frame and glow when the served card
        # file has it. The card-mod-styled vertical-stack it replaces lost them on a
        # hard refresh whenever the stack was built before card-mod loaded; it remains
        # only for a Home Assistant still serving an older card.
        # $replyCard is two cards when the custom one is served, so it is concatenated
        # rather than dropped into the list: inside an array literal it would stay a
        # nested array and serialise as one, which Lovelace renders as nothing at all.
        # What this session was started with, as a footer line: "gpt-5.4 · xhigh ·
        # long_context". Only the settings that are known are shown, and a session
        # the bridge did not start knows none, so its card carries no line at all
        # rather than a row of blanks or a guess at the agent's defaults.
        #
        # Rendered from the status sensor's attributes rather than from the dashboard
        # build, because the dashboard is only rebuilt when the session list changes -
        # a model swapped mid-session would otherwise keep showing the old one.
        $settingsTemplate = @"
{% set bits = [state_attr('$statusEntity','model'), state_attr('$statusEntity','effort'), state_attr('$statusEntity','context')] | select('string') | reject('eq','') | list %}{% if bits %}<span style="font-size:0.8em;color:var(--secondary-text-color)">{{ bits | join(' &bull; ') }}</span>{% endif %}
"@
        $settingsCard = @{
            type = 'markdown'
            card_mod = @{ style = $bareChild }
            content = $settingsTemplate
        }

        # Directly above End session's hairline, so the card reads: what the agent
        # said, then what it is doing, then quietly what it is doing it with.
        $footerCards = if ($formCard) { @($sendStatusCard, $settingsCard, $stopCard) }
            else { @($sendStatusCard, $cancelCard, $settingsCard, $stopCard) }
        $sessionCards = @($header) + @($fieldCards) + @($answerCard) + @($replyCard) + $footerCards
        # 1.32.0, not 1.12.0: the frame is drawn by the card's own code from the status
        # it reads, and a card served between 1.12 and 1.31 has no 'shell' in it - so a
        # session waiting on a background command gets the idle divider, the one
        # reading this status exists to prevent (#151). The stack below takes its edge
        # from the generated card_mod instead, which does know it.
        if (Test-BridgeActivityCardServed -ReplyCardUrl $ReplyCardUrl -MinimumVersion '1.32.0') {
            @{
                type     = 'custom:agent-bridge-session-card'
                status   = $statusEntity
                decision = $decisionEntity
                # The driver rides on the activity sensor's attributes, so the frame
                # cannot know who is driving without being told where to look. It was
                # never given this, and the card treats a missing activity entity as
                # 'human' - the safe default - so the purple edge could not appear on
                # any dashboard, whatever the daemon published. The card's own test
                # sets status, decision and activity by hand, so it passed the whole
                # time the view that builds it was handing over only two of the three.
                activity = $activityEntity
                cards    = $sessionCards
            }
        }
        else {
            @{
                type = 'vertical-stack'
                card_mod = @{ style = $sessionCardStyle }
                cards = $sessionCards
            }
        }
    }

    $sessionSections = @($sessionSections)
    if ($sessionSections.Count -eq 0) {
        $sessionSections = @(@{
            type = 'markdown'
            content = 'No live agent sessions right now.'
        })
    }

    # A masonry view, not a sections view. The sections view lays its sections out on a
    # CSS grid that aligns them into rows, so a single tall session card left a column
    # of dead space under every shorter card beside it. Masonry packs cards into
    # columns by height instead, so cards of very different lengths - which is normal
    # here, since a card carries a whole response - sit flush against each other.
    $config = @{
        title = 'Agent Sessions'
        views = @(@{
            title = 'Sessions'
            path = 'decision'
            type = 'masonry'
            cards = @($controlCards) + $sessionSections
        })
    }

    $inputSignature = Get-BridgeDashboardInputSignature -Sessions $Sessions -Machines $machineList `
        -MachineSelector $MachineSelector -ReplyCardUrl $ReplyCardUrl
    $config['agent_bridge_publication'] = @{
        protocol = 1; authority = $publication.Policy.authority; generation = $publication.Policy.generation
        writer = $publication.Policy.writer; render = Get-BridgeRenderArtifact; inputHash = $inputSignature
        cardUrlHash = Get-BridgePublicationHash $ReplyCardUrl
        # Protocol 1 binds the rendered session set as well as the view. Text in a
        # session's display name must not keep an unrelated retired entity alive.
        renderedNodes = @($Sessions | ForEach-Object { [string]$_.Node } | Sort-Object -Unique)
    }
    $config.agent_bridge_publication['contentHash'] = Get-BridgePublicationHash (ConvertTo-BridgePublicationJson $config)
    Initialize-BridgeDashboard
    [void](Invoke-CopilotHaWebSocket -Commands @(
        @{
            type = 'lovelace/config/save'
            url_path = $script:DecisionBridgeConfig.DashboardUrlPath
            config = $config
        }
    ))
    $confirmed = Get-BridgeDashboardPublication
    if (-not $confirmed.Verified -or $confirmed.InputSignature -cne $inputSignature) {
        throw "Dashboard publication was not confirmed by its actual stored content ($($confirmed.Reason)); it is not current."
    }
    Remove-BridgeLegacyDashboard
}

function Set-CopilotMqttEntityIds {
    <#
        Forces the bridge's MQTT entities onto deterministic, node-based entity_ids.

        Without this the ids follow the session's display name, so renaming a session
        would silently move every entity and strand any dashboard card pointing at
        the old id.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId
    )

    $node = Get-CopilotMqttNodeId -SessionId $SessionId
    $current = Resolve-CopilotMqttEntityIds -SessionId $SessionId

    $targets = @{
        Decision = "select.${node}_decision"
        Reply = "text.${node}_reply"
        ReplyPayload = "sensor.${node}_reply_payload"
        Status = "sensor.${node}_status"
        Activity = "sensor.${node}_activity"
    }
    # Per-field dropdowns for multi-field questions share the same treatment.
    for ($i = 1; $i -le 4; $i++) { $targets["Field$i"] = "select.${node}_f$i" }
    $targets['Submit'] = "button.${node}_submit"
    $targets['Stop'] = "button.${node}_stop"

    $commands = @()
    foreach ($key in @($targets.Keys)) {
        if (-not $current.ContainsKey($key)) { continue }
        if ($current[$key] -eq $targets[$key]) { continue }
        $commands += @{
            type = 'config/entity_registry/update'
            entity_id = $current[$key]
            new_entity_id = $targets[$key]
        }
    }

    if ($commands.Count -gt 0) {
        [void](Invoke-CopilotHaWebSocket -Commands $commands)
    }

    $targets
}
