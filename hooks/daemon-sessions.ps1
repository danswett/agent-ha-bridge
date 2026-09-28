<#
    Bridge daemon: card lifecycle.

    Adopts new sessions, retires ended ones, rebuilds the dashboard, and repairs or
    removes entities that have drifted.

    Part of agent-bridge-daemon.ps1, which dot-sources it into its own scope after
    declaring the shared $script: state; see docs/daemon-split.md.
    Shared state it changes: DaemonDashboardSignature, DaemonGlobalLastPublish,
    DaemonGlobalSignature, DaemonLive, DaemonOnlineLastPublish,
    DaemonPayloadSensorChecked, DaemonPendingRetire, DaemonVerbose.
#>

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

function Sync-DaemonSessions {
    <#
        Brings the published Home Assistant entities in line with the live sessions,
        and streams any new transcript activity.

        One pass, in order: drop sessions that have exited, adopt new ones, update
        known ones, publish this machine's status and heartbeat, rebuild the dashboard
        if what it shows has changed, and retire the previous pass's exited sessions.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State,

        # The live sessions, when the caller has just found them - the main loop does,
        # and scanning twice a pass doubled the cost.
        [hashtable]$Live
    )

    $live = if ($null -ne $Live) { $Live } else { Get-LiveBridgeSessions }
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
        $entry = $State[$session.SessionId]
        if ($null -eq $entry) {
            $entry = Add-DaemonSession -Session $session -Headers $Headers
            if ($null -ne $entry) { $State[$session.SessionId] = $entry }
            continue
        }
        Update-DaemonKnownSession -Session $session -Entry $entry -Headers $Headers -VerboseOn $verbose
    }

    $descriptors = @(Get-DaemonSessionDescriptors -State $State -Headers $Headers)
    $capabilities = Get-DaemonLaunchCapabilities
    Publish-DaemonGlobalStatus -Descriptors $descriptors -Capabilities $capabilities -Headers $Headers
    Publish-DaemonOnlineHeartbeat -Headers $Headers
    $dashboardCurrent = Sync-DaemonDashboard -Descriptors $descriptors -Capabilities $capabilities -Headers $Headers
    Complete-DaemonSessionRetirement -Gone $goneSessions -DashboardCurrent $dashboardCurrent -Headers $Headers
}

function Add-DaemonSession {
    <#
        Adopts a session the daemon has not seen: publishes its entities (or adopts
        ones a hook already published), makes sure the per-field slots and Submit
        button exist, publishes its first status, and returns its state entry - or
        $null when publishing failed, so it is tried again next pass.
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $session = $Session
    $id = $session.SessionId
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
            return $null
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
        # Every call below discards its output: this function returns the state entry,
        # and anything a call emits would be returned with it.
        if ($null -eq $probeField) {
            Clear-CopilotMqttDecisionFields -SessionId $id -SessionName $display.Name `
                -Machine $display.Machine -Headers $Headers | Out-Null
            Write-DaemonLog -Message "provisioned field slots for $($id.Substring(0,8))"
        }

        $probeSubmit = $null
        try { $probeSubmit = Get-HomeAssistantState -EntityId "button.${node}_submit" -Headers $Headers }
        catch { $probeSubmit = $null }
        if ($null -eq $probeSubmit) {
            Publish-CopilotMqttSubmitButton -SessionId $id -SessionName $display.Name `
                -Machine $display.Machine -Headers $Headers | Out-Null
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
        } | Out-Null
        Set-CopilotMqttActivity -SessionId $id -Summary $initialActivity `
            -Detail @{ session = $display.Name; machine = $display.Machine } -Headers $Headers | Out-Null
        # Prime the reply box to empty so the card shows a blank field rather
        # than 'unknown' before the box has ever been used.
        Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers `
            -Data @{ entity_id = "text.${node}_reply"; value = $script:DaemonConfig.ReplyBlankValue } | Out-Null
    }
    catch {
        Write-DaemonLog -Message "initial status publish failed for $id : $($_.Exception.Message)"
    }

    [pscustomobject]@{
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
}

function Update-DaemonKnownSession {
    <#
        One pass for a session already in state: re-resolves a stale name, then streams
        what it has done since the last pass onto its card.
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][hashtable]$Headers,
        [bool]$VerboseOn
    )

    $session = $Session
    $entry = $Entry
    $id = $session.SessionId
    $entryKind = if ($entry.PSObject.Properties.Name -contains 'Kind' -and $entry.Kind) { [string]$entry.Kind } else { 'copilot' }
    # Codex publishes its status from its hooks; what it says - progress notes, the
    # answer, reasoning, tool calls - is read from its rollout, here and in the fast
    # lane (Update-DaemonCodexActivity).
    if ($entryKind -eq 'codex') {
        Update-DaemonCodexActivity -Id $id -Entry $entry -Session $session -Headers $Headers -VerboseOn $VerboseOn
        return
    }

    # Re-resolve a session's name when the stored one is stale. Two cases: a session
    # published before it wrote its workspace file still carries the id fallback -
    # the real task name usually appears within a reconcile or two of the session
    # starting - and a session published by an older build carries no harness prefix
    # at all. Both self-heal on the next reconcile rather than needing the state file
    # to be cleared by hand.
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

    Update-DaemonSessionActivity -Id $id -Entry $entry -Session $session -Headers $Headers -VerboseOn $VerboseOn
}

function Get-DaemonSessionDescriptors {
    <#
        What this machine is running, as the dashboard and the global status sensor
        describe it: every session in state, and the live MCP clients.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Headers
    )

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
}

function Get-DaemonLaunchCapabilities {
    <#
        What this machine's launch card can offer - a profile row, a resume row, an
        agent row - which travels with its global status so that a peer rendering the
        shared dashboard knows which rows to draw for it.
    #>
    $newSessionEnabled = [bool](Get-BridgeSetting 'newSession.enabled' $true)
    $installedLaunchers = @(Get-BridgeAvailableLaunchers)
    $includeProfile = $newSessionEnabled -and $installedLaunchers -contains 'agency'
    # Every agent's sessions can be resumed now, not only Agency's.
    $includeResume = $newSessionEnabled -and $installedLaunchers.Count -gt 0
    $includeAgent = $newSessionEnabled -and $installedLaunchers.Count -gt 1
    @{
        newSession = $newSessionEnabled
        profile    = [bool]$includeProfile
        resume     = [bool]$includeResume
        agent      = [bool]$includeAgent
    }
}

function Publish-DaemonGlobalStatus {
    <#
        Publishes this machine's global status sensor - its sessions and launch
        capabilities - when they change, or periodically as a re-assert.

        Only then, because republishing three retained messages every reconcile - each
        stamped with a fresh 'updated' time that defeats payload equality - was
        needless idle traffic and MQTT churn. The periodic re-assert covers a Home
        Assistant restart dropping retained state.

        It is also this machine's presence marker and the only thing other machines
        read to learn what it is running, which is why the capability flags travel
        with it: a peer has no other way to know whether to draw a profile or resume
        row on this machine's launch card.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Descriptors,
        [Parameter(Mandatory)][hashtable]$Capabilities,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $globalSignature = (($Descriptors | ForEach-Object { "$($_.Node)=$($_.Name)=$($_.Machine)" }) -join '|') +
        "#$($Capabilities.newSession)$($Capabilities.profile)$($Capabilities.resume)$($Capabilities.agent)"
    $globalStale = ([DateTimeOffset]::Now - $script:DaemonGlobalLastPublish).TotalSeconds -ge $script:DaemonConfig.GlobalReassertSeconds
    if ($globalSignature -ne $script:DaemonGlobalSignature -or $globalStale) {
        try {
            Publish-CopilotMqttGlobalStatus -Headers $Headers -Capabilities $Capabilities -Sessions @(
                $Descriptors | ForEach-Object {
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
}

function Publish-DaemonOnlineHeartbeat {
    <#
        Liveness, on its own short cadence. Everything else is retained so that a
        machine which is switched off is still *known*; this is the one signal that
        says it is actually running, so it has to keep arriving. The sensor itself is
        declared at startup, well before this, because an unretained beat that outruns
        its own discovery config is simply dropped.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    if (([DateTimeOffset]::Now - $script:DaemonOnlineLastPublish).TotalSeconds -ge $script:DaemonConfig.OnlineHeartbeatSeconds) {
        try {
            Publish-CopilotMqttMachineHeartbeat -Slug $script:DaemonMachineSlug -Headers $Headers
            $script:DaemonOnlineLastPublish = [DateTimeOffset]::Now
        }
        catch {
            Write-DaemonLog -Message "online heartbeat failed: $($_.Exception.Message)"
        }
    }
}

function Get-DaemonAllDescriptors {
    <#
        Everything every machine is running, so the single shared dashboard shows the
        whole picture rather than only whichever machine rebuilt it last.

        Deduplicated by node because an MCP client is discovered directly by every
        daemon *and* reported in each of their session lists, so it would otherwise
        appear once per machine. The local descriptor wins: it is first-hand.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Descriptors,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Peers
    )

    $seenNodes = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@($Descriptors | ForEach-Object { [string]$_.Node }),
        [StringComparer]::OrdinalIgnoreCase)
    $allDescriptors = @($Descriptors)
    foreach ($peer in $Peers) {
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
    $allDescriptors
}

function Get-DaemonMachineCards {
    <#
        Every registered machine with the launch rows its card should show: this one
        from its own capabilities, the others from what their global status reports.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Capabilities,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Peers
    )

    $machineCards = @(
        [pscustomobject]@{
            Slug = $script:DaemonMachineSlug
            Machine = $script:DaemonMachineName
            IncludeProfile = [bool]$Capabilities.profile
            IncludeResume = [bool]$Capabilities.resume
            IncludeAgent = [bool]$Capabilities.agent
            # This daemon is the one running the code, so it is online by definition -
            # and saying so here means the launch picker is never empty while its own
            # heartbeat sensor is still being created.
            Online = $true
        }
    )
    foreach ($peer in $Peers) {
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
    @($machineCards | Sort-Object -Property Slug)
}

function Repair-DaemonMachinePicker {
    <#
        Moves the machine picker off a machine that has gone.

        Home Assistant sets the selection to 'unknown' when the option it was on is
        removed, and it does so asynchronously - so repairing it as part of the rebuild
        races that and loses. The launch rows are conditional on the selection matching
        a machine name, so an unknown selection renders a dropdown with nothing
        underneath it. Checked on every reconcile instead, off the cached state list,
        so it costs nothing until something actually looks wrong.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$OnlineNames)

    if ($OnlineNames.Count -le 1) { return }
    $selectorId = "input_select.$($script:BridgeMachineSelectorId)"
    $selectorState = ''
    foreach ($snapshotEntry in @($script:DaemonStatesCache)) {
        if ($null -eq $snapshotEntry) { continue }
        if ([string]$snapshotEntry.entity_id -eq $selectorId) {
            $selectorState = [string]$snapshotEntry.state
            break
        }
    }
    if ($selectorState -and $OnlineNames -notcontains $selectorState) {
        try {
            # Re-reads the live state before writing, so a stale snapshot costs a
            # read rather than a needless change under whoever is looking at it.
            if (Repair-BridgeMachineSelection -EntityId $selectorId -Options $OnlineNames) {
                Write-DaemonLog -Message "machine picker was on '$selectorState', which is gone; moved it to $($OnlineNames[0])"
            }
        }
        catch { }
    }
}

function Sync-DaemonDashboard {
    <#
        Rebuilds the shared dashboard when what it shows has changed, and returns
        whether it is now current.

        Only then, because a rebuild replaces the whole Lovelace config and is far
        heavier than a state publish; turn-by-turn activity rides on the per-session
        entities the dashboard already points at. The card header carries the session
        name, so a rename rebuilds it too - a signature of node ids alone would leave
        a renamed session showing its old generic title until the set of sessions
        happened to change. The machine list joins it for the same reason: a machine
        appearing, disappearing or going offline changes the controls even when no
        session did. The served card URL joins it because a card upgrade changes which
        cards the dashboard can use.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Descriptors,
        [Parameter(Mandatory)][hashtable]$Capabilities,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $peers = @(Get-DaemonPeerMachines -Headers $Headers)
    $allDescriptors = @(Get-DaemonAllDescriptors -Descriptors $Descriptors -Peers $peers)
    $machineCards = @(Get-DaemonMachineCards -Capabilities $Capabilities -Peers $peers)

    # Only machines that are actually running can start a session, so the picker lists
    # those. Every registered machine still appears in the machines card, online or
    # not, because a machine you expected to see and cannot is information too.
    $onlineNames = @($machineCards | Where-Object { $_.Online } | ForEach-Object { [string]$_.Machine })
    Repair-DaemonMachinePicker -OnlineNames $onlineNames

    $replyCardUrl = Get-BridgeServedReplyCardUrl
    $signature = (@($allDescriptors | Sort-Object -Property Node | ForEach-Object { "$($_.Node)=$($_.Name)" }) -join '|') +
        '#' + (@($machineCards | ForEach-Object { "$($_.Slug):$($_.IncludeProfile)$($_.IncludeResume)$($_.IncludeAgent):$($_.Online)" }) -join ',') +
        '#' + $replyCardUrl
    if ($signature -ne $script:DaemonDashboardSignature) {
        try {
            [void](Set-CopilotMqttGlobalEntityId)
            $selector = Initialize-BridgeMachineSelector -Machines $onlineNames
            # Discarded: this function returns whether the dashboard is current.
            Save-CopilotSessionDashboard -Sessions @($allDescriptors | Sort-Object -Property Node) `
                -Machines $machineCards -MachineSelector $selector `
                -ReplyCardUrl $replyCardUrl | Out-Null
            $script:DaemonDashboardSignature = $signature
            Write-DaemonLog -Message ("dashboard rebuilt for $($allDescriptors.Count) session(s) across " +
                "$($machineCards.Count) machine(s), $($onlineNames.Count) online")
        }
        catch {
            Write-DaemonLog -Message "dashboard rebuild failed: $($_.Exception.Message)"
        }
    }
    $signature -eq $script:DaemonDashboardSignature
}

function Complete-DaemonSessionRetirement {
    <#
        Retires the previous pass's exited sessions now, and queues this pass's for
        the next one.

        Rebuilding the dashboard first already removed their cards, but a browser holds
        the old Lovelace config until it is pushed the new one - so tearing the entities
        down in the same breath is exactly what made a just-ended session sit there as
        a card full of unknowns. Waiting a pass lets the frontend catch up first, and by
        then nothing is pointing at them.

        Only safe because the startup sweep clears orphans: a daemon that dies between
        the queue and the removal leaves entities behind, and that sweep is what comes
        back for them.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Gone,
        [Parameter(Mandatory)][bool]$DashboardCurrent,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $retirePlan = Update-DaemonRetireQueue -Queued $script:DaemonPendingRetire -Gone $Gone `
        -DashboardCurrent $DashboardCurrent
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
