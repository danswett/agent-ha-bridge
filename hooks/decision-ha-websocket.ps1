<#
    Home Assistant WebSocket helpers for the Copilot CLI bridge.

    Kept separate from the dashboard builder because that script runs its rebuild on
    load, so it cannot be dot-sourced just to reuse its socket code.
#>

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
                    catch { }
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

            if ($message.type -ne 'event') { continue }
            $trigger = $message.event.variables.trigger
            $entityId = [string]$trigger.entity_id
            if ([string]::IsNullOrWhiteSpace($entityId)) { continue }

            $newState = [string]$trigger.to_state.state
            if ($IgnoreStates -contains $newState) { continue }

            return [pscustomobject]@{
                EntityId = $entityId
                State = $newState
                Attributes = $trigger.to_state.attributes
            }
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
        @('select', 'new_workspace'),
        @('select', 'new_profile'),
        @('select', 'new_agent'),
        @('select', 'new_model'),
        @('select', 'new_effort'),
        @('select', 'new_context'),
        @('select', 'new_resume'),
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

function Initialize-BridgeDashboard {
    <#
        Makes sure the Lovelace dashboard the bridge writes to actually exists, and
        retires the pre-rename `copilot-decisions` one.

        `lovelace/config/save` only works against a registered dashboard, so a fresh
        install - or the slug change that came with the rename - needs the dashboard
        created first. Runs once per process; the daemon is long-lived, so repeating
        the round trip on every session change would be pure overhead.
    #>
    param([switch]$Force)

    if ($script:BridgeDashboardReady -and -not $Force) { return }

    $target = $script:DecisionBridgeConfig.DashboardUrlPath
    $legacy = 'copilot-decisions'

    try {
        # Invoke-CopilotHaWebSocket already unwraps each command's `result`, so this is
        # the dashboard list itself - indexing into `.result` again would find nothing.
        $dashboards = @((Invoke-CopilotHaWebSocket -Commands @(
            @{ type = 'lovelace/dashboards/list' }
        ))[0])

        if (-not (@($dashboards) | Where-Object { [string]$_.url_path -eq $target })) {
            [void](Invoke-CopilotHaWebSocket -Commands @(
                @{
                    type = 'lovelace/dashboards/create'
                    url_path = $target
                    title = 'Agent Sessions'
                    icon = 'mdi:robot'
                    show_in_sidebar = $true
                    require_admin = $false
                }
            ))
            Write-DecisionBridgeLog "created the '$target' dashboard"
        }

        # Only once the replacement is in place, so a failure part way through never
        # leaves the user with no dashboard at all.
        if ($target -ne $legacy) {
            $stale = @($dashboards) | Where-Object { [string]$_.url_path -eq $legacy } | Select-Object -First 1
            if ($stale) {
                [void](Invoke-CopilotHaWebSocket -Commands @(
                    @{ type = 'lovelace/dashboards/delete'; dashboard_id = $stale.id }
                ))
                Write-DecisionBridgeLog "removed the pre-rename '$legacy' dashboard"
            }
        }

        $script:BridgeDashboardReady = $true
    }
    catch {
        # A save against an existing dashboard still works, so this must never be
        # fatal - the next cycle retries.
        Write-DecisionBridgeLog "dashboard preparation failed: $($_.Exception.Message)"
    }
}

function Test-BridgeActivityCardServed {
    <#
        True when the served reply-card file includes agent-bridge-activity-card (or,
        with -MinimumVersion, whatever element shipped in that version), read from
        the `?v=` cache-buster on its resource URL. The activity card first shipped in
        card version 1.10.0; agent-bridge-session-card in 1.12.0;
        agent-bridge-choices-card in 1.13.0, and its whole-form shape - a labelled
        group of rows per field, replacing the per-field dropdowns - in 1.15.0.
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
        machine can render the whole picture without talking to the others - and every
        machine generates identical content, which is what makes it safe for all of
        them to rebuild it.

        Live count and pending-decision count are rendered as Jinja templates over the
        exact entity ids, so they stay current between rebuilds as turn state and
        armed questions change.
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

        # Resource URL of the reply card, or empty when Home Assistant is not serving
        # it. Empty falls back to the plain text box and Send button: a Lovelace view
        # that references a custom card which does not exist renders an error box
        # where the reply box should be, leaving no way to reply at all.
        [AllowEmptyString()]
        [string]$ReplyCardUrl = ''
    )

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
        $versionParts = @("**Bridge** {{ state_attr('$soloUpdate', 'installed_version') or '?' }}")
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
        $line = "{% if is_state('$onlineEntity','on') %}🟢 **$($_.Machine)** &bull; " +
            "{{ states('$countEntity')|int(0) }} session(s) &bull; " +
            "{{ state_attr('$updateEntity','installed_version') or '?' }}" +
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

    # The update row and its install button only appear when an update exists. A
    # conditional card is used rather than hiding rows inside the entities card,
    # because an entities row has no condition of its own.
    #
    # One per machine: each runs its own copy at its own version, so a single shared
    # row showed whichever machine published last and its install button ran on every
    # machine at once.
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

    # The control panel is a plain card pair at the top of the masonry flow.
    $controlCards = @($agentSessionsCard)
    if ($machinesCard) { $controlCards += $machinesCard }
    $controlCards += $updateCards + $newSessionCards

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
### {% if state_attr('$decisionEntity','question') %}🟡{% elif is_state('$statusEntity','working') %}🟢{% else %}⚪{% endif %} $($session.Name)
*$($session.Machine)* &bull; status: **{% if state_attr('$decisionEntity','question') %}waiting for you{% else %}{% set st = states('$statusEntity') %}{{ 'ended' if st in ['unknown', 'unavailable'] else st }}{% endif %}**{% set act = states('$activityEntity') %}{% set body = state_attr('$activityEntity','response') or '' %}{% if not (body and body.startswith(act.rstrip('.'))) %} &bull; {{ act }}{% endif %}
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
        if (Test-BridgeActivityCardServed -ReplyCardUrl $ReplyCardUrl) {
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

        # Two shapes of reply box, chosen by whether Home Assistant is serving the
        # bridge's own card.
        #
        # The card is much the better of the two: it reads the textarea at the moment
        # Send is pressed, so one press is always enough, it publishes over MQTT so a
        # reply is not limited to the 255 characters an entity state allows, and it
        # can carry pasted images. The text box below is kept as a fallback because a
        # view referencing a custom card that is not installed renders an error box
        # instead of a reply box, which would leave no way to reply at all.
        # The reply box, in two shapes.
        #
        # The card is much the better of the two for an ordinary reply: it reads the
        # textarea at the moment Send is pressed, so one press is always enough, it
        # publishes over MQTT so a reply is not limited to the 255 characters an entity
        # state allows, and it can carry pasted images.
        #
        # It cannot answer a question, though, and that is not a styling detail. A
        # question is answered through the entities - the daemon reads the free-text
        # field from text.<node>_reply and waits for a press on button.<node>_submit -
        # and the card writes neither: its Send publishes an MQTT payload, which the
        # reply path deliberately ignores while a question owns the box. Its Send also
        # returns early on an empty textarea, so a form whose only text field is
        # optional could not be sent at all. The result was a form that looked ready,
        # took every dropdown, and did nothing whatsoever on Send - silently, with not
        # one line in the daemon log, because nothing ever arrived to log.
        #
        # So the entity pair is not only a fallback for a Home Assistant that is not
        # serving the card; it is what is shown whenever a question is armed.
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
        $replyCard = if (-not [string]::IsNullOrWhiteSpace($ReplyCardUrl)) {
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
            'Answer may be wrong - check the terminal'
            'Ending session...', 'Could not end session'
        )
        $sendStatusCard = @{
            type = 'conditional'
            conditions = @(
                @{ condition = 'state'; entity = $activityEntity; state = $sendStates }
            )
            card = @{
                type = 'markdown'
                card_mod = @{ style = $bareChild }
                content = @"
{% set a = states('$activityEntity') %}{% set d = state_attr('$activityEntity','error') %}{% set h = state_attr('$activityEntity','hint') %}{% set w = state_attr('$activityEntity','waiting_on') %}
<span style="font-size:0.9em">{% if 'NOT' in a or 'Could not' in a or 'may be wrong' in a %}⚠️ {% elif 'sent' in a %}✅ {% else %}⏳ {% endif %}**{{ a }}**{% if w %} — {{ w }}{% elif h %} — {{ h }}{% elif d %} — {{ d }}{% endif %}</span>
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
        if (Test-BridgeActivityCardServed -ReplyCardUrl $ReplyCardUrl -MinimumVersion '1.12.0') {
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

    Initialize-BridgeDashboard
    [void](Invoke-CopilotHaWebSocket -Commands @(
        @{
            type = 'lovelace/config/save'
            url_path = $script:DecisionBridgeConfig.DashboardUrlPath
            config = $config
        }
    ))
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


