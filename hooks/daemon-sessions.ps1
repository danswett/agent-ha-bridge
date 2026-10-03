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
            $reply = Get-DaemonEntityState -EntityId "text.${node}_reply" -Headers $Headers
            if ([string]$reply.state -in @('unknown', 'unavailable')) { $needsRepair = $true }
            if (-not $needsRepair) {
                $dec = Get-DaemonEntityState -EntityId "select.${node}_decision" -Headers $Headers
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

$script:DaemonStaleHelperSeen = @{}

function Clear-DaemonStaleMachineHelper {
    <#
        Deletes a Detailed activity switch whose machine is no longer registered.

        The switch is a Home Assistant helper, not an MQTT entity, so clearing a
        machine's retained topics - which is what the X on its row does, straight from
        the browser - cannot take it with them. Left behind it is a switch named after
        a machine that appears nowhere else, and nothing would ever come back for it.

        A helper has to look stale twice before it goes, and only when the snapshot
        shows machines at all. A machine creates its switch at startup and publishes
        its sensors moments later, and a Home Assistant that has restarted takes a
        while to restore every retained discovery message - so a single snapshot
        showing a helper with no machine proves nothing. Deleting a live machine's
        switch is far worse than leaving a dead one for another reconcile: only its own
        daemon creates it, so it would stay gone until that machine restarted.

        Returns how many were removed.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Machines,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $known = @($Machines | ForEach-Object { [string]$_.Slug } | Where-Object { $_ })
    if ($known.Count -eq 0) { return 0 }

    try { $states = Get-DaemonHomeAssistantStates -Headers $Headers }
    catch { return 0 }

    # The same fail-safe the orphan sweep uses: no machine sensor in the whole list
    # means the picture is incomplete - MQTT not restored yet, most likely - and not
    # that every machine has gone.
    if (-not @($states | Where-Object {
        $null -ne $_ -and [string]$_.entity_id -match '^sensor\.agent_bridge_[a-z0-9_]+_sessions$'
    }).Count) {
        return 0
    }

    $stale = @{}
    $removed = 0
    foreach ($state in @($states)) {
        if ($null -eq $state) { continue }
        # The unscoped helper from before the switch was per-machine is
        # `input_boolean.agent_bridge_detailed_activity`, with no slug between the two
        # halves, so it can never match this and is left where it is.
        if ([string]$state.entity_id -notmatch '^input_boolean\.agent_bridge_(.+)_detailed_activity$') { continue }
        $slug = $Matches[1]
        if ($known -contains $slug) { continue }

        $stale[$slug] = $true
        if (-not $script:DaemonStaleHelperSeen.ContainsKey($slug)) { continue }

        try {
            if (Remove-CopilotVerboseToggle -HelperId "agent_bridge_${slug}_detailed_activity") {
                $removed++
                Write-DaemonLog -Message "removed the Detailed activity switch for $slug, which is no longer registered"
            }
        }
        catch {
            Write-DaemonLog -Message "could not remove the Detailed activity switch for $slug : $($_.Exception.Message)"
        }
    }
    # Only what still looks stale is carried forward, so a machine that came back
    # starts from scratch rather than being one pass from losing its switch.
    $script:DaemonStaleHelperSeen = $stale
    $removed
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
    Publish-DaemonGlobalStatus -Descriptors $descriptors -Capabilities $capabilities `
        -Resumable @($script:DaemonResumeOffered) -Headers $Headers
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

    # A session registering says any launch note about one not registering is out of
    # date, whichever launch wrote it.
    try { Clear-DaemonLaunchNoteOnRegistration -Headers $Headers } catch { }

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

    # Whether the bridge started this session from nothing, asked before the launch
    # record is taken by Get-DaemonSessionTuning below.
    #
    # It decides where in the transcript to start reading. A session the daemon merely
    # found is picked up at the end - everything before that was said without the
    # bridge watching and is not news. But a session the bridge just launched can
    # answer before it is adopted: registering and publishing takes several seconds,
    # and a short prompt is done well inside that. Starting at the end then skips the
    # answer permanently, and the card sits at Idle with nothing in it while the
    # session has already replied - which is what happened to every quick launch, and
    # was hidden until now by test prompts that ran for minutes.
    #
    # A resume is deliberately excluded: its transcript is a conversation that already
    # happened, and reading from the start would replay all of it onto the card.
    $launchRecord = $null
    if ($script:DaemonLaunchedTuning.ContainsKey($id)) { $launchRecord = $script:DaemonLaunchedTuning[$id] }
    $startedFresh = ($null -ne $launchRecord) -and
        -not ($launchRecord.PSObject.Properties['Resumed'] -and $launchRecord.Resumed)

    # What this session was started with, when the bridge started it. A session
    # opened at a keyboard has none, and its card simply shows no settings line
    # rather than guessing at the agent's defaults.
    $tuning = Get-DaemonSessionTuning -SessionId $id -Session $session

    # Who the card is born believing is driving. Without this the first publish
    # carries no driver at all, and a card with no driver reads as human - blue -
    # until the session's next activity update supplies one. For a session that
    # launches and then waits, that update may never come: one launched by an agent
    # sat on the dashboard showing blue indefinitely until it was replied to. The
    # same publish runs when a session is re-adopted, so a daemon restart or a
    # re-prime was blanking the driver of every session it touched.
    $initialDriver = ''
    if ($script:DaemonLaunchDrivers.ContainsKey($id)) {
        # Peeked rather than taken - the block further down takes it, stamps it on the
        # state entry and logs it. Taking it here would silently disable all that.
        $initialDriver = [string]$script:DaemonLaunchDrivers[$id].Driver
    }
    elseif ($alreadyPublished) {
        # Carried over from the card, which outlives the daemon. A session being
        # re-adopted has no launch record - it did not just start, and the record does
        # not survive a restart - so its own published state is the only thing that
        # still knows who was driving it.
        try {
            $priorActivity = Get-HomeAssistantState -EntityId "sensor.${node}_activity" -Headers $Headers
            if ($null -ne $priorActivity -and $priorActivity.PSObject.Properties['attributes'] -and
                $null -ne $priorActivity.attributes -and
                $priorActivity.attributes.PSObject.Properties['driver']) {
                $initialDriver = [string]$priorActivity.attributes.driver
            }
        }
        catch { $initialDriver = '' }
    }
    if ([string]::IsNullOrWhiteSpace($initialDriver)) { $initialDriver = 'human' }

    try {
        Set-CopilotMqttStatus -SessionId $id -Status $initialStatus -Headers $Headers -Attributes (
            Add-DaemonTuningAttributes -Attributes @{
                session = $display.Name
                machine = $display.Machine
                process_id = $session.ProcessId
                updated = [DateTimeOffset]::Now.ToString('o')
            } -Tuning $tuning) | Out-Null
        Set-CopilotMqttActivity -SessionId $id -Summary $initialActivity `
            -Detail @{ session = $display.Name; machine = $display.Machine; driver = $initialDriver } `
            -Headers $Headers | Out-Null
        # Prime the reply box to empty so the card shows a blank field rather
        # than 'unknown' before the box has ever been used.
        Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers `
            -Data @{ entity_id = "text.${node}_reply"; value = $script:DaemonConfig.ReplyBlankValue } | Out-Null
    }
    catch {
        Write-DaemonLog -Message "initial status publish failed for $id : $($_.Exception.Message)"
    }

    $entry = [pscustomobject]@{
        # Where to start reading. A session the bridge started from nothing is read
        # from the beginning, so an answer it gave before it was adopted is still
        # picked up; anything else starts at the transcript's end, since what was
        # said before the daemon saw it is not news and a resumed conversation must
        # not be replayed.
        Offset = if (-not $startedFresh -and [IO.File]::Exists($session.Transcript)) {
            (Get-Item -LiteralPath $session.Transcript).Length
        } else { 0 }
        Name = $display.Name
        Machine = $display.Machine
        Status = $initialStatus
        Kind = $kind
        # Persisted with the rest of the entry, so a card keeps its settings line
        # across a daemon restart - the launch record it came from does not survive.
        Model = [string]$tuning.Model
        Effort = [string]$tuning.Effort
        Context = [string]$tuning.Context
    }

    # A session an agent launched is agent-driven from the moment it appears. The
    # press that started it is long gone by now, so the driver was put aside when the
    # launch registered, under the id it registered with. Taken rather than read, so
    # a later session that happens to reuse the id cannot inherit it.
    if ($script:DaemonLaunchDrivers.ContainsKey($id)) {
        # Pending for the same reason a Submit press is: the first turn of a launched
        # session is the launch itself, and Update-DaemonSessionActivity reads a
        # starting turn as somebody typing unless it is told one is expected. Without
        # this the glow would last until the session's first activity update - seconds.
        Set-DaemonDriverPending -Entry $entry -Driver ([string]$script:DaemonLaunchDrivers[$id].Driver)
        $script:DaemonLaunchDrivers.Remove($id)
        Write-DaemonLog -Message "session $($id.Substring(0,8)) was launched by an agent; showing it as agent-driven"
    }
    elseif ($initialDriver -ne 'human') {
        # Carried over from the card when a session is re-adopted. The entry is built
        # fresh on every restart, so without this the driver read off the card above
        # would be published once and then lost again at the next activity update.
        Set-DaemonSessionProperty -Entry $entry -Name 'Driver' -Value $initialDriver
    }
    $entry
}

function Get-DaemonSessionTuning {
    <#
        The model, effort and context to show for one session at the moment it is
        adopted: what the bridge launched it with, topped up with a model the agent
        has already reported.

        A reported model wins over the launch record for the same reason a transcript
        beats a command line - it is what the session is actually using, including
        after a /model typed into its window. All three agents supply one: Codex names
        it in every hook call, and Copilot and Claude stamp it on every assistant
        message, which Update-DaemonSessionActivity picks up from then on. So a
        session the bridge never launched still ends up showing its model, within a
        turn of the daemon seeing it.

        Effort and context have no such source - they appear in no transcript and no
        agent reports them back - so they can only ever be what the launch asked for,
        and are blank for a session started at a keyboard.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        $Session = $null
    )

    $launched = $null
    try { $launched = Resolve-DaemonLaunchTuning -SessionId $SessionId } catch { }

    $field = { param($Source, $Name)
        if ($null -ne $Source -and $Source.PSObject.Properties[$Name]) { [string]$Source.$Name } else { '' } }

    $model = & $field $launched 'Model'
    $reported = & $field $Session 'Model'
    if ($reported) { $model = $reported }

    [pscustomobject]@{
        Model   = $model
        Effort  = & $field $launched 'Effort'
        Context = & $field $launched 'Context'
    }
}

function Add-DaemonTuningAttributes {
    <#
        Adds the three settings to a status attribute set, leaving out any that are
        empty so the card can tell "not known" from a real value.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Attributes,
        $Tuning = $null
    )

    if ($null -eq $Tuning) { return $Attributes }
    foreach ($pair in @(@('model', 'Model'), @('effort', 'Effort'), @('context', 'Context'))) {
        if (-not $Tuning.PSObject.Properties[$pair[1]]) { continue }
        $value = [string]$Tuning.($pair[1])
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $Attributes[$pair[0]] = $value
    }
    $Attributes
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
    $entryKind = Get-DaemonEntryKind -Entry $entry
    $agent = Get-DaemonAgent -Kind $entryKind
    # An agent that streams its own card (Codex) does so here and in the fast lane.
    if ($agent.KnownActivity) {
        & $agent.KnownActivity $id $entry $session $Headers $VerboseOn
        return
    }

    # Re-resolve the name of an agent whose sessions can be renamed while they run.
    # Copilot's name is whatever its workspace file says, and that changes twice over
    # a session's life: the id fallback gives way to the first prompt once the file is
    # written, and renaming the session replaces that with whatever the user typed.
    # Only comparing it while it still looked generic left a rename showing the old
    # name for as long as the session lasted, so it is compared every pass - one read
    # of a small file, against a reconcile that already talks to Home Assistant.
    # A session of any kind can also be carrying the Copilot id fallback, from a build
    # that published it before its own adapter loaded; that heals here too.
    $needsName = [bool]$agent.RefreshName -or ([string]$entry.Name -match '^Copilot: [0-9a-f]{8}$')
    if ($needsName) {
        $workingDirectory = if ($session.PSObject.Properties.Name -contains 'WorkingDirectory' -and $session.WorkingDirectory) {
            [string]$session.WorkingDirectory
        } else { 'Unknown folder' }
        $refreshed = Get-BridgeSessionDisplay -SessionId $id -Kind $entryKind -WorkingDirectory $workingDirectory
        if ([string]$refreshed.Name -ne [string]$entry.Name) {
            $entry.Name = $refreshed.Name
            try {
                # Discarded like every other publish here: this runs on any rename, and
                # what it emits would otherwise ride out through the reconcile.
                Set-CopilotMqttStatus -SessionId $id -Status ([string]$entry.Status) -Headers $Headers -Attributes @{
                    session = $entry.Name
                    machine = $entry.Machine
                    process_id = $session.ProcessId
                    updated = [DateTimeOffset]::Now.ToString('o')
                } | Out-Null
                # The card reads the name above; this is what carries it to the names
                # Home Assistant itself shows, which are built from the device's.
                Update-CopilotMqttSessionName -SessionId $id -SessionName ([string]$entry.Name) `
                    -Machine ([string]$entry.Machine) -Headers $Headers | Out-Null
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
    # Agency, and at least one profile to choose between. A machine whose Agency has
    # no profiles - a new one, before whatever syncs the config has run there - gets
    # no row rather than one whose only option is a placeholder, and its launches pass
    # no profile, which is what Agency's own base config is for.
    $includeProfile = $newSessionEnabled -and $installedLaunchers -contains 'agency' -and
        @(Get-BridgeAgencyProfiles).Count -gt 0
    # Every agent's sessions can be resumed now, not only Agency's.
    $includeResume = $newSessionEnabled -and $installedLaunchers.Count -gt 0
    $includeAgent = $newSessionEnabled -and $installedLaunchers.Count -gt 1
    @{
        newSession = $newSessionEnabled
        profile    = [bool]$includeProfile
        resume     = [bool]$includeResume
        agent      = [bool]$includeAgent
        # Model, effort and context. Reported separately from the rows above so a
        # peer still running a bridge without those entities does not get three
        # "Entity not found" rows drawn for it on the shared dashboard.
        tuning     = [bool]$newSessionEnabled
        # The allow-all selector, for the same reason: a peer that has not published
        # it yet gets no permissions row rather than one pointing at nothing.
        permissions = [bool]$newSessionEnabled
        # This bridge publishes a Detailed activity switch for itself. Peers read it
        # to decide whether to draw a toggle for this machine; one that does not
        # report it gets no toggle rather than a row pointing at a helper that does
        # not exist.
        detailed   = $true
        # Sessions this machine is willing to let other machines see in their own resume
        # list. Default OFF pending an explicit consent and retention decision: a peer
        # that does not report it publishes nothing, which is also exactly what an older
        # bridge looks like, so neither needs a special case.
        resumeShare = [bool]($newSessionEnabled -and (Test-DaemonSharingEnabled -Name 'newSession.shareResumable'))
        # Installed from a working copy rather than a release. VERSION only moves when
        # a release is cut, so without this a machine running the source and one
        # running the release show the same number while being days apart.
        dev        = [bool](Get-BridgeSetting 'updates.installedFromSource' $false)
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

        The resumable list rides here for the same reason, and joins the signature so
        that a session ending or being reopened republishes rather than waiting out the
        re-assert interval.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Descriptors,
        [Parameter(Mandatory)][hashtable]$Capabilities,
        [AllowEmptyCollection()][object[]]$Resumable = @(),
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $export = @(Get-DaemonResumableExport -Resumable $Resumable)

    # The exported content itself, plus the flags that shape it. An earlier draft bound
    # only id@updated, which meant turning detail off - or sharing off entirely - left
    # the previously published titles and leaves sitting in a retained message until the
    # re-assert interval happened to come round. A privacy change has to take effect when
    # it is made, so what is actually published is what is signed.
    $shareOn = Test-DaemonSharingEnabled -Name 'newSession.shareResumable'
    $detailOn = Test-DaemonSharingEnabled -Name 'newSession.shareResumableDetail'
    $resumeSignature = "share=$shareOn;detail=$detailOn;" + (@($export | ForEach-Object {
        (ConvertTo-Json $_ -Depth 4 -Compress)
    }) -join '|')

    $globalSignature = (($Descriptors | ForEach-Object { "$($_.Node)=$($_.Name)=$($_.Machine)" }) -join '|') +
        "#$($Capabilities.newSession)$($Capabilities.profile)$($Capabilities.resume)$($Capabilities.agent)$($Capabilities.tuning)$($Capabilities.detailed)$($Capabilities.dev)" +
        "#$resumeSignature"
    $globalStale = ([DateTimeOffset]::Now - $script:DaemonGlobalLastPublish).TotalSeconds -ge $script:DaemonConfig.GlobalReassertSeconds
    if ($globalSignature -ne $script:DaemonGlobalSignature -or $globalStale) {
        try {
            Publish-CopilotMqttGlobalStatus -Headers $Headers -Capabilities $Capabilities -Sessions @(
                $Descriptors | ForEach-Object {
                    @{ name = $_.Name; machine = $_.Machine; node = $_.Node; kind = [string]$_.Kind }
                }
            ) -Resumable $export
            $script:DaemonGlobalSignature = $globalSignature
            $script:DaemonGlobalLastPublish = [DateTimeOffset]::Now
        }
        catch {
            Write-DaemonLog -Message "global status publish failed: $($_.Exception.Message)"
        }
    }
}

function Test-DaemonSharingEnabled {
    <#
        Whether a sharing flag is actually set, from a configuration file that can hold
        anything.

        `[bool]` is the wrong tool and was the bug here: in PowerShell every non-empty
        string is true, so `[bool]'false'` is $true and a config holding the *string*
        "false" switched sharing on. The peer side already refused a non-boolean
        resumeShare as "not consent"; the producer was reading its own settings the loose
        way, which is the same mistake pointing outward.

        So: a real boolean is taken as given, a string is parsed as a boolean and only a
        genuine "true" counts, and anything else - a number, a list, a typo - is not
        consent. A consent flag has to fail closed on anything it does not understand.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [bool]$Default = $false
    )

    $raw = Get-BridgeSetting $Name $Default
    if ($raw -is [bool]) { return $raw }
    if ($raw -is [string]) {
        $parsed = $false
        if ([bool]::TryParse($raw.Trim(), [ref]$parsed)) { return $parsed }
    }
    $false
}

function Get-DaemonResumableExport {
    <#
        The resumable entries as they travel to other machines, reduced to the least
        that still identifies a session - and nothing at all when sharing is off.

        Sharing off is a *producer* decision, not a consumer one. An earlier draft only
        withheld the capability flag, which told well-behaved peers to ignore the array
        while still publishing it, retained, for anything else to read. Opting out has to
        stop the data leaving, so this returns empty and the caller publishes that empty
        array, replacing whatever was retained before.

        Deliberately not the local entry even when sharing is on. A summary is the user's
        own prompt text and a folder is an absolute path; publishing either, retained,
        puts it in every peer's reach and in the recorder and backups for as long as those
        are kept. The local dropdown already shows them on the machine they belong to,
        which is not the same decision as broadcasting them to the fleet.

        So the default payload carries no prompt text and no path at all: an id, which is
        needed to resume anything, the agent that owns it, and when it last changed. A
        peer renders "Copilot on DASDESK - 4252da87", enough to choose between sessions
        without describing what they were about.

        'newSession.shareResumableDetail' opts in to a bounded title and the folder's last
        segment - never the path. Both flags default OFF pending an explicit consent and
        retention decision; nothing here is an assertion that publishing even the minimal
        payload has been agreed.

        The whole array is bounded as well as each entry, because this rides a retained
        attribute: a machine with hundreds of sessions must not publish hundreds.
    #>
    param([AllowEmptyCollection()][object[]]$Resumable = @())

    if (-not (Test-DaemonSharingEnabled -Name 'newSession.shareResumable')) { return @() }

    $detail = Test-DaemonSharingEnabled -Name 'newSession.shareResumableDetail'
    # Settings arrive from a config file and may be anything. A non-numeric or negative
    # count must mean "none", not an exception inside the publish path.
    $max = 0
    if (-not [int]::TryParse([string](Get-BridgeSetting 'newSession.resumeCount' 12), [ref]$max)) { $max = 12 }
    if ($max -le 0) { return @() }

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($Resumable)) {
        if ($null -eq $entry) { continue }
        if ($out.Count -ge $max) { break }
        if (-not $entry.PSObject.Properties['SessionId']) { continue }
        $id = [string]$entry.SessionId
        if ([string]::IsNullOrWhiteSpace($id)) { continue }

        $updated = [DateTimeOffset]::MinValue
        if ($entry.PSObject.Properties['Updated'] -and $entry.Updated -is [DateTimeOffset]) { $updated = $entry.Updated }

        $item = @{
            id       = $id
            launcher = if ($entry.PSObject.Properties['Launcher']) { [string]$entry.Launcher } else { '' }
            updated  = $updated.ToString('o')
        }
        if ($detail) {
            $title = ''
            if ($entry.PSObject.Properties['Summary']) { $title = ([string]$entry.Summary -replace '\s+', ' ').Trim() }
            if ($title.Length -gt 48) { $title = $title.Substring(0, 45) + '...' }
            if ($title) { $item['title'] = $title }
            # The leaf only. A full path names a user, a tree and often a customer.
            $folder = ''
            if ($entry.PSObject.Properties['Folder']) { $folder = [string]$entry.Folder }
            if (-not [string]::IsNullOrWhiteSpace($folder)) {
                $item['leaf'] = @($folder.TrimEnd('\', '/') -split '[\\/]')[-1]
            }
        }
        $out.Add($item)
    }

    # Encoded size is what the broker and the recorder actually see, so it is what is
    # measured - not the entry count, which says nothing about the bytes.
    $budget = 0
    if (-not [int]::TryParse([string](Get-BridgeSetting 'newSession.shareResumableMaxBytes' 4096), [ref]$budget)) { $budget = 4096 }
    if ($budget -le 0) { return @() }
    while ($out.Count -gt 0) {
        $encoded = [Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json @($out) -Depth 4 -Compress))
        if ($encoded -le $budget) { break }
        $out.RemoveAt($out.Count - 1)
    }
    @($out)
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

        Each carries the session nodes it is running, too. They are not drawn anywhere;
        they are what the X on an offline machine's row has to clear along with the
        machine's own controls, and only the machine's retained sensor knows them.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Capabilities,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Peers,
        [AllowEmptyCollection()][string[]]$LocalSessionNodes = @()
    )

    $machineCards = @(
        [pscustomobject]@{
            Slug = $script:DaemonMachineSlug
            Machine = $script:DaemonMachineName
            IncludeProfile = [bool]$Capabilities.profile
            IncludeResume = [bool]$Capabilities.resume
            IncludeAgent = [bool]$Capabilities.agent
            # ContainsKey rather than a bare read: a capability set built before the
            # tuning rows existed simply has no such key, and StrictMode throws on it.
            IncludeTuning = [bool]($Capabilities.ContainsKey('tuning') -and $Capabilities.tuning)
            # Same reason again: newer than the tuning rows, so a hand-built set or a
            # peer from before it has no such key.
            IncludePermissions = [bool]($Capabilities.ContainsKey('permissions') -and $Capabilities['permissions'])
            # Same reason - newer than some of the callers that build a capabilities
            # set by hand.
            IncludeDetailed = [bool]($Capabilities.ContainsKey('detailed') -and $Capabilities['detailed'])
            IsDev = [bool]($Capabilities.ContainsKey('dev') -and $Capabilities['dev'])
            # This daemon is the one running the code, so it is online by definition -
            # and saying so here means the launch picker is never empty while its own
            # heartbeat sensor is still being created.
            Online = $true
            SessionNodes = @($LocalSessionNodes)
        }
    )
    foreach ($peer in $Peers) {
        $peerCaps = $peer.Capabilities
        $peerProfile = $false
        $peerResume = $false
        $peerAgent = $false
        $peerTuning = $false
        $peerPermissions = $false
        # A peer on a bridge older than the Detailed activity switch reports nothing
        # here, and gets no toggle. Drawing one anyway is an "Entity not found" box on
        # everyone's dashboard, because the helper only exists on machines that create
        # it - seen live against a peer still on 1.14.6.
        $peerDetailed = $false
        # A peer that says nothing is assumed to be running a release, which is what
        # every machine that has never seen a working copy is.
        $peerDev = $false
        if ($null -ne $peerCaps) {
            try { $peerProfile = [bool]$peerCaps.profile } catch { }
            try { $peerResume = [bool]$peerCaps.resume } catch { }
            try { $peerAgent = [bool]$peerCaps.agent } catch { }
            # Absent on a peer running a bridge from before the tuning rows existed,
            # which then gets a launch card without them rather than three broken rows.
            try { $peerTuning = [bool]$peerCaps.tuning } catch { }
            # Absent on a peer from before the permissions selector, which then keeps
            # using its own newSession.allowAllTools - the old behaviour - rather than
            # showing a row that points at an entity it never published.
            try { $peerPermissions = [bool]$peerCaps.permissions } catch { }
            try { $peerDetailed = [bool]$peerCaps.detailed } catch { }
            try { $peerDev = [bool]$peerCaps.dev } catch { }
        }
        $machineCards += [pscustomobject]@{
            Slug = $peer.Slug
            Machine = $peer.Machine
            IncludeProfile = $peerProfile
            IncludeResume = $peerResume
            IncludeAgent = $peerAgent
            IncludeTuning = $peerTuning
            IncludePermissions = $peerPermissions
            IncludeDetailed = $peerDetailed
            IsDev = $peerDev
            Online = [bool]$peer.Online
            # Whatever it was running when it last reported. For a machine that is gone
            # these are precisely the entities nothing else will ever withdraw.
            #
            # Read through PSObject rather than directly: a peer built by hand - which
            # every older caller and several suites do - has no such property at all,
            # and StrictMode makes reading one a terminating error.
            SessionNodes = @(
                if ($peer.PSObject.Properties['Sessions']) {
                    @($peer.Sessions) | ForEach-Object { [string]$_.node } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                }
            )
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
        Observes accepted shared output on every pass, publishing changes or repairs
        only as the configured writer. A cached local signature is not HA evidence.

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
    $machineCards = @(Get-DaemonMachineCards -Capabilities $Capabilities -Peers $peers `
        -LocalSessionNodes @($Descriptors | ForEach-Object { [string]$_.Node }))

    # Only machines that are actually running can start a session, so the picker lists
    # those. Every registered machine still appears in the machines card, online or
    # not, because a machine you expected to see and cannot is information too.
    $onlineNames = @($machineCards | Where-Object { $_.Online } | ForEach-Object { [string]$_.Machine })
    Repair-DaemonMachinePicker -OnlineNames $onlineNames

    $script:BridgeDashboardObservation = $null
    try {
        $publication = Get-BridgeDashboardPublication
        $script:BridgeDashboardObservation = $publication
        $replyCardUrl = $publication.State.CardUrl
        $selector = if ($onlineNames.Count -gt 1) { "input_select.$($script:BridgeMachineSelectorId)" } else { '' }
        $signature = Get-BridgeDashboardInputSignature -Sessions $allDescriptors -Machines $machineCards `
            -MachineSelector $selector -ReplyCardUrl $replyCardUrl
        if (-not $publication.Verified -or $publication.InputSignature -cne $signature) {
            Assert-BridgePublicationWriter -State $publication.State -Component render -Artifact (Get-BridgeRenderArtifact)
            [void](Set-CopilotMqttGlobalEntityId)
            $selector = Initialize-BridgeMachineSelector -Machines $onlineNames
            Save-CopilotSessionDashboard -Sessions @($allDescriptors | Sort-Object -Property Node) `
                -Machines $machineCards -MachineSelector $selector `
                -ReplyCardUrl $replyCardUrl | Out-Null
            $publication = Get-BridgeDashboardPublication
            $script:BridgeDashboardObservation = $publication
            $signature = Get-BridgeDashboardInputSignature -Sessions $allDescriptors -Machines $machineCards `
                -MachineSelector $selector -ReplyCardUrl $replyCardUrl
            if (-not $publication.Verified -or $publication.InputSignature -cne $signature) {
                throw 'The accepted shared dashboard does not match this reconciliation.'
            }
            Write-DaemonLog -Message ("dashboard rebuilt for $($allDescriptors.Count) session(s) across " +
                "$($machineCards.Count) machine(s), $($onlineNames.Count) online")
        }
        $script:DaemonDashboardSignature = $signature
        try { [void](Clear-DaemonStaleMachineHelper -Machines $machineCards -Headers $Headers) }
        catch { Write-DaemonLog -Message "stale switch sweep failed: $($_.Exception.Message)" }
        return $true
    }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked']) { throw }
        if (-not $_.Exception.Data['BridgePublicationRefused']) { $script:BridgeDashboardObservation = $null }
        Write-DaemonLog -Message "dashboard publication not current: $($_.Exception.Message)"
        return $false
    }
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

    # A non-writer can observe a valid newer renderer with different inputs. Retire
    # only nodes absent from that actual view, rather than waiting for its own save.
    [void]$DashboardCurrent
    $observation = Get-Variable -Name BridgeDashboardObservation -Scope Script -ErrorAction SilentlyContinue
    $verified = $observation -and $observation.Value -and $observation.Value.Verified
    $safe = @()
    $held = @()
    foreach ($queued in @($script:DaemonPendingRetire)) {
        if (-not $queued) { continue }
        $node = Get-CopilotMqttNodeId -SessionId $queued
        if ($verified -and $observation.Value.ReferencedNodes -cnotcontains $node) { $safe += $queued }
        else { $held += $queued }
    }
    $retirePlan = Update-DaemonRetireQueue -Queued $safe -Gone $Gone -DashboardCurrent ([bool]$verified)
    $retirePlan.Queue = @(@($retirePlan.Queue) + $held | Select-Object -Unique)
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
