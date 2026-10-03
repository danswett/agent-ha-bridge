<#
    Bridge daemon: starting and ending sessions.

    The launch card: its controls, a press, the launch or resume, following it up
    (trust question, first message), its notes - and End session.

    Part of agent-bridge-daemon.ps1, which dot-sources it into its own scope after
    declaring the shared $script: state; see docs/daemon-split.md.
    Shared state it changes: DaemonDefaultAgent, DaemonLaunchedTuning,
    DaemonNewSessionLastPress, DaemonNewSessionPublished, DaemonNewSessionSignature,
    DaemonPendingLaunch, DaemonReconcileNow, DaemonResumeCache, DaemonResumeCacheAt,
    DaemonStopArmed.
#>

function Get-DaemonProcessIdentity {
    <#
        What identifies the process a confirmation was armed against, beyond its id.

        A process id alone is not an identity: Windows reuses them, so a session that
        exits and is replaced within the window can present the same number attached
        to a different process. The start time pins it. Returns $null when there is
        nothing to pin - no id, or a process this daemon cannot read - and a $null on
        either side is treated as unverifiable rather than as a match.
    #>
    param([int]$ProcessId = 0)

    if ($ProcessId -le 0) { return $null }
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        return $process.StartTime.ToUniversalTime().Ticks
    }
    catch { return $null }
}

function Set-DaemonStopArm {
    <#
        Arms End session for one session, remembering when, what a second press would
        interrupt, and which process it would interrupt.

        The status is kept here rather than read again when the prompt is republished:
        it is what the user was told the first time, and a session that moved on in
        the meantime would otherwise rewrite the question underneath them.

        The target is kept for a harder reason. A session id outlives the process
        behind it - a session that exits and is resumed keeps its id - so an arm keyed
        on the id alone would let a second press end a process the first press never
        saw. Recorded here and checked before confirming (Test-DaemonStopConfirms).

        The question is also recorded where other processes can see it, so a hook
        publishing its own status line cannot wipe it. That record is display state
        and cannot confirm anything; see Write-BridgeStopPrompt.

        Returns $true only when both the arm and its record are in place.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [AllowEmptyString()][string]$Status = '',
        [int]$ProcessId = 0
    )

    $armedAt = [DateTimeOffset]::Now
    $hint = Get-DaemonStopConfirmHint -Status $Status
    # The record first, and the arm only if it was written. An arm whose projection is
    # missing is consent nothing else can see: the next hook to publish wipes the
    # question from the card while a second press still confirms, which is the whole
    # defect the record exists to close. Failing to arm costs an extra press; arming
    # blind costs the turn.
    if (-not (Write-BridgeStopPrompt -SessionId $SessionId -Hint $hint `
            -Until $armedAt.AddSeconds($script:DaemonConfig.StopConfirmSeconds))) {
        [void]$script:DaemonStopArmed.Remove($SessionId)
        return $false
    }
    $script:DaemonStopArmed[$SessionId] = [pscustomobject]@{
        At        = $armedAt
        Status    = $Status
        Hint      = $hint
        ProcessId = $ProcessId
        Identity  = Get-DaemonProcessIdentity -ProcessId $ProcessId
        # When the lapse note may next be attempted. Only moves when a publish fails,
        # so the ordinary path pays nothing for it.
        RetryAt   = [DateTimeOffset]::MinValue
    }
    $true
}

function Remove-DaemonStopArm {
    <#
        Drops an arm and the question other processes were pinning on its behalf.

        The arm goes whether or not the record can be cleared. A record left behind
        keeps a question on a card until its own expiry, seconds away; an arm left
        behind could stop a session.

        An unreadable store is the awkward case. It cannot be repaired one session at
        a time - see Write-BridgeStopPrompt - and leaving it would hold every session
        at Unknown until the next restart. Clearing it wholesale is safe only once
        nothing is left that could be confirmed against a record that no longer
        exists, so every other arm is dropped first. Those sessions ask again on their
        next press, which is the direction that cannot lose work.
    #>
    param([Parameter(Mandatory)][string]$SessionId)

    [void]$script:DaemonStopArmed.Remove($SessionId)
    if (Write-BridgeStopPrompt -SessionId $SessionId -Until $null) { return }

    if ((Read-BridgeStopPromptStore).State -eq 'Failed') {
        $stranded = @($script:DaemonStopArmed.Keys).Count
        $script:DaemonStopArmed.Clear()
        if (Clear-BridgeStopPromptStore) {
            Write-DaemonLog -Message ("the end prompt store could not be read; cleared it whole and " +
                "disarmed $stranded other session(s), which must be asked again")
            return
        }
    }
    Write-DaemonLog -Message "could not clear the recorded end prompt for $SessionId; it expires on its own"
}

function Clear-DaemonStopPrompts {
    <#
        Drops every recorded question at daemon startup.

        Kept out of this file's load path on purpose. Clearing where the shared state
        is declared meant that merely dot-sourcing the daemon for its functions - which
        hooks and tests do, under AGENT_BRIDGE_DAEMON_NORUN - wiped the records of a
        daemon that was actually running, unpinning live questions on another process's
        cards.

        Nothing this daemon did not arm itself may be left showing, for the same reason
        the in-memory arms are not restored: a question from before a restart has no
        arm behind it and could never be answered. That is what makes clearing the
        whole store safe here and not on a per-session path - there is no consent left
        for it to strand.
    #>
    if (-not (Clear-BridgeStopPromptStore)) {
        Write-DaemonLog -Message 'could not clear the recorded end prompts at startup'
    }
}

function Test-DaemonStopConfirms {
    <#
        Whether this press confirms the arm already held for the session, rather than
        being a first press against a different target.

        Confirms only on positive proof: the arm is inside its window, the process now
        behind the session carries the same id, and that id carries the same process it
        carried when the arm was taken. Anything short of that - a replaced process, a
        reused id, an identity unreadable on either side - is not consent.

        There is deliberately no success-shaped exception for the unverifiable case.
        Treating "unreadable then, unreadable now" as a match would confirm against
        exactly the targets nothing can vouch for, which is the opposite of what the
        comparison is for. A press with no target at all never reaches here; see
        Invoke-PendingStops.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [int]$ProcessId = 0
    )

    if ($ProcessId -le 0) { return $false }
    if (-not (Test-DaemonStopArmed -SessionId $SessionId)) { return $false }
    $arm = $script:DaemonStopArmed[$SessionId]
    if ([int]$arm.ProcessId -ne $ProcessId) { return $false }
    if ($null -eq $arm.Identity) { return $false }
    $now = Get-DaemonProcessIdentity -ProcessId $ProcessId
    if ($null -eq $now) { return $false }
    [long]$arm.Identity -eq [long]$now
}

function Test-DaemonStopArmed {
    <#
        True while a first press of End session is still waiting for the second press
        that confirms it.

        Deliberately does not remove an arm that has run out of time; only
        Clear-DaemonExpiredStopArms does that, and it says so on the card as it goes.
        Removing it here as well would mean whichever of the two looked first
        swallowed the lapse silently, leaving the card asking for a press that no
        longer confirms anything.
    #>
    param([Parameter(Mandatory)][string]$SessionId)

    if (-not $script:DaemonStopArmed.ContainsKey($SessionId)) { return $false }
    $armedAt = ConvertTo-DaemonActivityInstant -Value $script:DaemonStopArmed[$SessionId].At
    if ($null -eq $armedAt) { return $false }
    ([DateTimeOffset]::Now - $armedAt).TotalSeconds -le $script:DaemonConfig.StopConfirmSeconds
}

function Get-DaemonStopConfirmHint {
    <# The line under the confirmation prompt, naming what a second press interrupts. #>
    param([AllowEmptyString()][string]$Status = '')

    $doing = if ([string]::IsNullOrWhiteSpace($Status) -or $Status -eq 'working') { 'this session is still working' }
        elseif ($Status -eq 'waiting') { 'this session is waiting on you' }
        else { "this session is $Status" }
    "$doing - the confirmation lapses in $($script:DaemonConfig.StopConfirmSeconds)s"
}

function Get-DaemonCardSummary {
    <#
        The status line to publish for a session: what it is doing, unless End session
        is armed, in which case the question it is waiting on.

        Pinned rather than published once at the press, because the transcript keeps
        flowing underneath. A batch of tool output arriving a second later replaces the
        activity summary wholesale, which wiped the prompt and left the press looking
        as though it had done nothing - with only ten seconds to notice.

        Only the summary is taken over; the response, the reasoning and the history in
        $Detail stay live, so the card still shows what the session is up to while it
        asks.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Summary,
        [hashtable]$Detail
    )

    if (-not (Test-DaemonStopArmed -SessionId $SessionId)) { return $Summary }
    if ($null -ne $Detail) {
        $Detail['hint'] = Get-DaemonStopConfirmHint -Status ([string]$script:DaemonStopArmed[$SessionId].Status)
    }
    $script:CopilotEndSessionConfirmNote
}

function Clear-DaemonExpiredStopArms {
    <#
        Disarms an End session confirmation nobody made in time, and says so on the
        card.

        The note matters as much as the disarming. A session parked on 'waiting'
        writes no transcript, so nothing else would ever replace the pinned prompt:
        the card would go on asking for a second press that had quietly stopped being
        a confirmation and become a fresh first press.

        So the arm is released only once that note has actually been published. If
        Home Assistant is unreachable at the moment the window expires, dropping the
        arm first would leave the card asking forever with nothing left to retry from
        - and a quiet session produces no later activity to replace it, so recovery
        alone would not fix it. Retried on a backoff rather than every tick, and given
        up only when the session's card goes, which is the one event that makes the
        note pointless.

        Called from the fast lane, so the lapse shows within a tick rather than at the
        next reconcile - a fifteen-second wait on a ten-second window.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State
    )

    $now = [DateTimeOffset]::Now
    foreach ($sessionId in @($script:DaemonStopArmed.Keys)) {
        if (Test-DaemonStopArmed -SessionId $sessionId) { continue }
        $arm = $script:DaemonStopArmed[$sessionId]

        # Nothing left to tell: the session's card has already gone.
        if (-not $State.ContainsKey($sessionId)) {
            Remove-DaemonStopArm -SessionId $sessionId
            continue
        }
        if ($now -lt (ConvertTo-DaemonActivityInstant -Value $arm.RetryAt)) { continue }

        $short = $sessionId.Substring(0, [Math]::Min(8, $sessionId.Length))
        try {
            Set-DaemonTransientActivity -SessionId $sessionId -Summary $script:CopilotEndSessionLapsedNote `
                -Extra @{ hint = "no second press within $($script:DaemonConfig.StopConfirmSeconds)s" } `
                -Headers $Headers
            Remove-DaemonStopArm -SessionId $sessionId
            Write-DaemonLog -Message "end confirmation for $short lapsed; the session is still running"
        }
        catch {
            if ($_.Exception.Data['BridgeTestWriteBlocked']) { throw }
            if ($_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
            $arm.RetryAt = $now.AddSeconds($script:DaemonConfig.StopLapseRetrySeconds)
        }
    }
}

function Invoke-PendingStops {
    <#
        Ends any session whose End button has been pressed.

        Uses the same press-timestamp contract as the Submit and Launch buttons: a
        press from before this daemon started is a retained value from an earlier
        run, and a press already acted on is recorded per session so one press can
        never end two sessions or the same session twice.

        A session that is not idle takes two presses. End sits on the card a tap away
        from Send, and a stray tap that lands mid-turn throws away the turn in flight
        - the transcript survives and the session can be resumed, but what it was
        doing does not come back. So the first press only arms and says so; the second
        press, within StopConfirmSeconds, is the one that ends it. An idle session has
        nothing in flight to lose and still ends on a single press.

        Deliberately enforced here and not as a confirmation dialog on the dashboard
        card. The same button is pressed from a phone, from an automation and by other
        agents, and only the daemon sees all of those; a dialog would guard the one
        surface and leave the rest ending a working session on a single press.

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
            $button = Get-DaemonEntityState -EntityId "button.${node}_stop" -Headers $Headers
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

        # The guard. A session with no status yet is treated as not idle: the daemon
        # has not classified it, so it may well be mid-turn, and asking for a second
        # press is the direction that cannot lose work.
        #
        # A press with no process behind it is let through unguarded, which sounds
        # wrong and is not. Stop-BridgeCopilotSession cannot touch anything without a
        # process id and says so, so nothing can be lost; arming instead would post a
        # question that no second press could ever answer, and leave it on the card.
        #
        # Test-DaemonStopConfirms, not merely "is it armed": a session id outlives the
        # process behind it, so an arm keyed on the id alone let a press confirm
        # against a process the first press never saw. A replaced target, a reused
        # process id or an identity that cannot be vouched for all arm again here
        # rather than stopping.
        #
        # The window is measured from this machine's clock rather than the press
        # timestamp, which is Home Assistant's; the two are usually within
        # milliseconds, but nothing guarantees it and a skewed pair would either arm
        # for no time at all or stay armed long after the card said it had lapsed.
        $status = if ($entry.PSObject.Properties['Status']) { [string]$entry.Status } else { '' }
        if ($processId -gt 0 -and $status -ne 'idle' -and
            -not (Test-DaemonStopConfirms -SessionId $sessionId -ProcessId $processId)) {
            $rearmed = $script:DaemonStopArmed.ContainsKey($sessionId)
            $armed = Set-DaemonStopArm -SessionId $sessionId -Status $status -ProcessId $processId
            Write-DaemonLog -Message ("end requested for $short (pid $processId) while " +
                "$(if ($status) { $status } else { 'unclassified' })" +
                "$(if (-not $armed) { '; could not record the question, so nothing is armed' }
                   elseif ($rearmed) { '; target changed, arming again' }
                   else { '; waiting for a second press' })")
            # Only ask when something can answer. A failed arm leaves no arm, and so no
            # entry for the expiry sweep to lapse: the question would sit on a quiet
            # session's card indefinitely, asking for a press that could confirm
            # nothing. Say that the press could not be acted on instead.
            $summary = $script:CopilotEndSessionConfirmNote
            $extra = @{ hint = (Get-DaemonStopConfirmHint -Status $status) }
            if (-not $armed) {
                $summary = 'Could not end session'
                $extra = @{
                    error = 'the confirmation could not be recorded, so nothing was armed'
                    hint  = 'Press End session again to try again.'
                }
            }
            try {
                Set-DaemonTransientActivity -SessionId $sessionId -Summary $summary `
                    -Extra $extra -Headers $Headers
            }
            catch {
                if ($_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
                if ($armed) {
                    # The card never showed the question, so nothing can answer it. Left
                    # armed, the user's natural retry - pressing again because the first
                    # press looked dead - would be read as the confirmation and stop the
                    # session, which is precisely what this guard exists to prevent.
                    Remove-DaemonStopArm -SessionId $sessionId
                    Write-DaemonLog -Message ("end confirmation for $short could not be shown, " +
                        "disarming: $($_.Exception.Message)")
                }
                else {
                    # Nothing was armed, so there is nothing to disarm; calling the
                    # removal here would start the unreadable-store repair on a press
                    # that never armed anything.
                    Write-DaemonLog -Message ("end failure note for $short could not be shown: " +
                        "$($_.Exception.Message)")
                }
            }
            continue
        }
        Remove-DaemonStopArm -SessionId $sessionId

        Write-DaemonLog -Message "end requested for $short (pid $processId)"

        # Say so on the card straight away: the status reads "ending" while the
        # session closes, instead of carrying on as "working" or "idle" until it has
        # gone.
        # Separately guarded, so a failed status publish cannot also cost the card its
        # "Ending session..." line.
        $entry | Add-Member -NotePropertyName Status -NotePropertyValue 'ending' -Force
        try {
            Set-CopilotMqttStatus -SessionId $sessionId -Status 'ending' -Headers $Headers -Attributes (
                Add-DaemonTuningAttributes -Attributes @{
                    session    = $entry.Name
                    machine    = $entry.Machine
                    process_id = $processId
                    updated    = [DateTimeOffset]::Now.ToString('o')
                } -Tuning $entry)
        }
        catch {
            if ($_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
            Write-DaemonLog -Message "ending status publish failed for $short : $($_.Exception.Message)"
        }
        try {
            Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Ending session...' `
                -Headers $Headers
        }
        catch { }

        $stop = Stop-BridgeCopilotSession -SessionId $sessionId -ProcessId $processId
        $entry.Status = if ($stop.Stopped) { 'ended' } else { 'error' }
        try {
            Set-CopilotMqttStatus -SessionId $sessionId -Status $entry.Status -Headers $Headers -Attributes (
                Add-DaemonTuningAttributes -Attributes @{
                    session = $entry.Name
                    machine = $entry.Machine
                    process_id = $processId
                    updated = [DateTimeOffset]::Now.ToString('o')
                } -Tuning $entry)
        }
        catch {
            if ($_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
            Write-DaemonLog -Message "stop outcome publish failed for $short : $($_.Exception.Message)"
        }
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
            if (-not $script:BridgeIsWindows -and ($launcherPid -gt 0 -or $processId -gt 0)) {
                # macOS: the pid here is the tmux *pane's* - the agent itself - so
                # there is no launcher process to end; killing it is what just
                # happened. The window is a separate Terminal window running `tmux
                # attach`, which returns when tmux tears the session down and then
                # sits there as a dead shell.
                #
                # Two candidates, because the launch record is not always there: a
                # daemon restarted since the launch has lost it, and Codex never had
                # one (it picks its own id after the window is already open). The
                # session's own pid covers both, and differs from the launch pid only
                # when something wraps the CLI. Trying either is safe: the tag is what
                # decides, so a window the bridge did not open is never matched.
                Start-Sleep -Milliseconds 1200
                foreach ($candidate in (@($launcherPid, $processId) | Select-Object -Unique)) {
                    if ([int]$candidate -le 0) { continue }
                    $title = Get-BridgeTerminalWindowTitle -ProcessId ([int]$candidate)
                    if (Close-BridgeTerminalWindow -Title $title) {
                        Write-DaemonLog -Message "closed the terminal window the bridge opened for $short ($title)"
                        break
                    }
                }
            }
            elseif ($launcherPid -gt 0 -and $launcherPid -ne $processId) {
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

function Get-DaemonResumableSessions {
    <#
        The cached list of sessions offered in the resume dropdown.

        Behind this are each agent's session files and, with Agency installed,
        `agency hub list-local-sessions --json`, which on a working machine describes
        hundreds of sessions in half a megabyte and takes over a second. Running that
        every 15 seconds would be a waste, and the list barely changes, so it is
        refreshed on a timer and served from memory in between.

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

    $offered = @(@($script:DaemonResumeCache) | Where-Object {
        -not $live.ContainsKey([string]$_.SessionId) -and
        $_.PSObject.Properties['Folder'] -and
        (Test-BridgeWorkspacePathApproved -Path ([string]$_.Folder))
    })
    # Remembered so the global status publishes exactly what this dropdown offers,
    # rather than recomputing and risking the two drifting apart.
    $script:DaemonResumeOffered = $offered
    $offered
}

function Get-DaemonMergedResumable {
    <#
        The whole resume list this machine offers: its own sessions, then any a peer is
        sharing, each carrying the Label the selector shows.

        This is the only place the two are joined, and it is joined before the list is
        used for anything. The selector is published from it and a press is resolved
        against it, so a merged display and a local-only resolution would produce options
        that match nothing - reported on the card as "no longer resumable", which is both
        wrong and unhelpful.

        A peer being unreadable is not a failure: it means no remote entries this pass.
        The local list is never withheld because a peer scan failed.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Live,
        [hashtable]$Headers = @{}
    )

    $local = @(Get-DaemonResumableSessions -LiveSessionIds @($Live.Keys))

    $remote = @()
    try {
        $peers = @(Get-DaemonPeerMachines -Headers $Headers)
        if ($peers.Count -gt 0) {
            $remote = @(Get-DaemonRemoteResumable -Peers $peers `
                -ExcludeIds @(@($local | ForEach-Object { [string]$_.SessionId }) + @($Live.Keys)))
        }
    }
    catch {
        Write-DaemonLog -Message "peer resumable scan failed: $($_.Exception.Message)"
    }

    # Labels have to be unique: Home Assistant matches a selector's state against its
    # options by exact string, so two identical labels are two sessions that cannot be
    # told apart, and the second would silently resolve to the first.
    $seen = @{}
    foreach ($entry in @($local)) {
        if ($entry.PSObject.Properties['Label']) { $seen[[string]$entry.Label] = $true }
    }
    $labelled = foreach ($entry in @($remote)) {
        $label = Get-DaemonRemoteResumeLabel -Entry $entry
        if ($seen.ContainsKey($label)) { continue }
        $seen[$label] = $true
        $entry | Add-Member -NotePropertyName 'Label' -NotePropertyValue $label -Force -PassThru
    }

    @($local) + @($labelled)
}

function Get-DaemonRemoteResumable {
    <#
        Sessions on other machines, as entries for this machine's resume list.

        Every entry is marked Remote. Choosing one brings its transcript across and
        opens it here under an id of its own; the machine it came from keeps its copy
        untouched. Listing them is most of the value even before that - it answers
        "where did I leave that?" without walking to the other desk.

        Only online peers contribute. A machine that is switched off keeps publishing
        its last list by retention, and offering sessions from a machine that cannot
        answer a request would be showing a list nothing can correct.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Peers,
        [AllowEmptyCollection()][string[]]$ExcludeIds = @()
    )

    $seen = @{}
    foreach ($id in @($ExcludeIds)) {
        if (-not [string]::IsNullOrWhiteSpace($id)) { $seen[[string]$id] = $true }
    }

    $out = foreach ($peer in @($Peers)) {
        if ($null -eq $peer) { continue }
        # Every field here arrives from another machine via JSON, so each is checked
        # rather than assumed. A malformed or truncated peer payload must contribute
        # nothing, not throw inside the reconcile that reads it.
        if (-not $peer.PSObject.Properties['IsSelf'] -or $peer.IsSelf) { continue }
        if (-not $peer.PSObject.Properties['Online'] -or -not $peer.Online) { continue }

        $caps = if ($peer.PSObject.Properties['Capabilities']) { $peer.Capabilities } else { $null }
        # Explicitly $true, not merely truthy: a non-empty string or a non-zero number
        # arriving where a boolean was expected should not read as consent to share.
        $shares = $false
        if ($null -ne $caps -and $caps.PSObject.Properties['resumeShare']) {
            $shares = ($caps.resumeShare -is [bool] -and $caps.resumeShare)
        }
        if (-not $shares) { continue }
        if (-not $peer.PSObject.Properties['Resumable']) { continue }

        foreach ($entry in @($peer.Resumable)) {
            if ($null -eq $entry -or -not $entry.PSObject.Properties['id']) { continue }
            $id = [string]$entry.id
            if ([string]::IsNullOrWhiteSpace($id) -or $seen.ContainsKey($id)) { continue }
            $seen[$id] = $true

            $launcher = ''
            if ($entry.PSObject.Properties['launcher']) { $launcher = [string]$entry.launcher }
            $updated = [DateTimeOffset]::MinValue
            if ($entry.PSObject.Properties['updated']) {
                $parsed = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse([string]$entry.updated, [ref]$parsed)) { $updated = $parsed }
            }
            # Present only when that machine opted into sharing detail; absent is the
            # default and must render sensibly rather than as an empty gap.
            $title = ''
            if ($entry.PSObject.Properties['title']) { $title = [string]$entry.title }
            $leaf = ''
            if ($entry.PSObject.Properties['leaf']) { $leaf = [string]$entry.leaf }

            [pscustomobject]@{
                SessionId = $id
                Launcher  = $launcher
                Summary   = $title
                Folder    = ''          # never published, and never guessed from a leaf
                Leaf      = $leaf
                Updated   = $updated
                Remote    = $true
                Machine   = if ($peer.PSObject.Properties['Machine']) { [string]$peer.Machine } else { '' }
                Slug      = if ($peer.PSObject.Properties['Slug']) { [string]$peer.Slug } else { '' }
            }
        }
    }
    @($out)
}

function Invoke-DaemonTransferRequest {
    <#
        Serves a request from another machine for a session this one holds: bundles the
        transcript, publishes it, and clears the request.

        Read-only with respect to the session. Nothing is renamed, locked or removed, and
        the copy here stays exactly as resumable as it was - the machine asking installs
        what arrives under an id of its own, so the two never contend.

        Refusals are silent on this side on purpose. The requester is the one watching a
        card, and it already fails on its own timeout; logging here and saying nothing
        there is the right split.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$LiveSessionIds,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    # Serving is sharing, and it was not gated at all: this ran on every reconcile
    # regardless of newSession.enabled or either sharing flag, so a machine that had
    # opted out entirely would still hand over a transcript to anything able to publish
    # one retained message. Checked with the strict reader, because [bool]'false' is
    # $true and a config saying "false" must not read as consent.
    if (-not (Test-DaemonSharingEnabled -Name 'newSession.enabled' -Default $true)) { return }
    if (-not (Test-DaemonSharingEnabled -Name 'newSession.shareResumable')) { return }

    $entity = Get-BridgeMachineEntityId -Domain 'sensor' -Key 'transfer_request' -Slug $script:DaemonMachineSlug
    $request = $null
    try { $request = (Get-HomeAssistantState -EntityId $entity -Headers $Headers).attributes } catch { return }
    if ($null -eq $request -or -not $request.PSObject.Properties['session']) { return }

    $session = [string]$request.session
    $correlation = [string]$request.correlation
    if ([string]::IsNullOrWhiteSpace($session) -or [string]::IsNullOrWhiteSpace($correlation)) { return }
    # Retained, so a request already served would be served again every pass.
    if ($correlation -eq $script:DaemonTransferServed) { return }

    # A retained request outlives the daemon that served it: the served-correlation is
    # process-local, so without a freshness window every restart re-sends whatever was
    # last asked for - and an update restarts the daemon.
    $at = [DateTimeOffset]::MinValue
    if ($request.PSObject.Properties['at']) { [void][DateTimeOffset]::TryParse([string]$request.at, [ref]$at) }
    if (([DateTimeOffset]::Now - $at).TotalMinutes -gt 10) {
        $script:DaemonTransferServed = $correlation
        try { Clear-CopilotMqttTransferRequest -Slug $script:DaemonMachineSlug -Headers $Headers } catch { }
        return
    }

    $launcher = if ($request.PSObject.Properties['launcher']) { [string]$request.launcher } else { 'copilot' }
    $requester = if ($request.PSObject.Properties['requester']) { [string]$request.requester } else { '' }
    if ($requester -notmatch '^[a-z0-9_]+$') { return }

    try {
        # Only what this machine actually offered. The approved-workspace filter that
        # decides what is *listed* was not a filter on what could be *taken*: without
        # this, any id present in the agent home could be asked for by name, including
        # sessions from directories deliberately left out of the resume list.
        if (@($script:DaemonResumeOffered | ForEach-Object { [string]$_.SessionId }) -notcontains $session) {
            Write-DaemonLog -Message "transfer refused: $session is not one this machine offers"
            return
        }
        # A session being written to right now would be bundled mid-sentence.
        if (@($LiveSessionIds) -contains $session) {
            Write-DaemonLog -Message "transfer refused: $session is live here"
            return
        }
        $staging = Join-Path ([IO.Path]::GetTempPath()) "bridge-send-$correlation"
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        try {
            $manifest = New-BridgeSessionBundle -SessionId $session -Launcher $launcher -Destination $staging
            $cap = [int](Get-BridgeSetting 'newSession.transferMaxBytes' 26214400)
            if ($manifest.Bytes -gt $cap) {
                Write-DaemonLog -Message "transfer refused: $session is $([int]($manifest.Bytes / 1MB)) MB, over the cap"
                return
            }
            $sent = Send-BridgeSessionBundle -Manifest $manifest -Slug $requester -Correlation $correlation -Headers $Headers
            Write-DaemonLog -Message "sent $session to $requester in $sent chunk(s)"
        }
        finally {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-DaemonLog -Message "transfer failed for ${session}: $($_.Exception.Message)"
    }
    finally {
        $script:DaemonTransferServed = $correlation
        try { Clear-CopilotMqttTransferRequest -Slug $script:DaemonMachineSlug -Headers $Headers } catch { }
    }
}

function Receive-DaemonSessionTransfer {
    <#
        Fetches a session from the machine that holds it and installs it here as a session
        of its own, returning the new id - or $null, having said why on the card.

        Subscribes before asking. Nothing in a transfer is published retained, because a
        retained chunk is redelivered to every reconnecting subscriber and at these sizes
        that is precisely the message that took this fleet's MQTT down; so a sender that
        publishes before anyone is listening is publishing into nothing.

        The digest is checked before a single byte reaches the agent's home. That is the
        guard against the worst outcome available here: Copilot handed `--session-id` for
        a session whose files are absent does not fail, it starts a new empty session
        under that id and exits 0, which the daemon would adopt as a successful resume.
    #>
    param(
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][hashtable]$Headers,
        [int]$TimeoutSeconds = 120
    )

    $session = [string]$Entry.SessionId
    $owner = [string]$Entry.Slug
    $correlation = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $root = Get-BridgeTransferTopic -Slug $script:DaemonMachineSlug -Correlation $correlation
    $staging = Join-Path ([IO.Path]::GetTempPath()) "bridge-recv-$correlation"

    Set-CopilotMqttNewSessionResult -Headers $Headers `
        -Text "Fetching that session from $($Entry.Machine)..." | Out-Null

    try {
        New-Item -ItemType Directory -Path $staging -Force | Out-Null

        # Asked for only once the subscription is actually live. Nothing in a transfer
        # is retained, so a request published first can be answered into a socket that
        # does not exist yet - and the owner would have burned the correlation and
        # cleared the request by the time this started listening.
        $messages = @(Read-BridgeHaMqttSubscription -Topic "$root/#" -TimeoutSeconds $TimeoutSeconds `
            -OnReady {
                Set-CopilotMqttTransferRequest -Slug $owner -SessionId $session -Launcher ([string]$Entry.Launcher) `
                    -Requester $script:DaemonMachineSlug -Correlation $correlation -Headers $Headers
            } `
            -Until {
                param($all)
                $m = @($all) | Where-Object { $_.PSObject.Properties['sha256'] } | Select-Object -First 1
                if ($null -eq $m) { return $false }
                @(@($all) | Where-Object { $_.PSObject.Properties['d'] }).Count -ge [int]$m.chunks
            })

        $manifest = @($messages) | Where-Object { $_.PSObject.Properties['sha256'] } | Select-Object -First 1
        if ($null -eq $manifest) {
            Write-DaemonLog -Message "transfer timed out waiting for $session from $owner"
            Set-CopilotMqttNewSessionResult -Headers $Headers `
                -Text "$($Entry.Machine) did not send that session. It may be busy or offline." | Out-Null
            return $null
        }

        $declared = [int]$manifest.bytes
        # The sender's arithmetic is not trusted - the digest is re-checked for exactly
        # that reason, so the size should not get a free pass. A manifest claiming two
        # gigabytes would otherwise allocate two gigabytes before the incomplete-bundle
        # throw, on nothing more than a peer's say-so.
        $cap = 0
        if (-not [int]::TryParse([string](Get-BridgeSetting 'newSession.transferMaxBytes' 26214400), [ref]$cap)) { $cap = 26214400 }
        if ($declared -le 0 -or $declared -gt $cap) {
            throw "that session is $([int]($declared / 1MB)) MB, which is over the limit for a transfer"
        }

        $bytes = Join-BridgeBundleChunk -Chunks @(@($messages) | Where-Object { $_.PSObject.Properties['d'] }) `
            -TotalBytes $declared -Sha256 ([string]$manifest.sha256)
        $zip = Join-Path $staging 'bundle.zip'
        [IO.File]::WriteAllBytes($zip, $bytes)

        $newId = Install-BridgeSessionBundle -BundlePath $zip -WorkingDirectory $WorkingDirectory -Manifest ([pscustomobject]@{
            SessionId = [string]$manifest.session; Kind = [string]$manifest.kind; Sha256 = [string]$manifest.sha256
        })
        Write-DaemonLog -Message "received $session from $owner and installed it as $newId"
        $newId
    }
    catch {
        Write-DaemonLog -Message "transfer of $session from ${owner} failed: $($_.Exception.Message)"
        Set-CopilotMqttNewSessionResult -Headers $Headers `
            -Text "Could not bring that session over: $($_.Exception.Message)" | Out-Null
        $null
    }
    finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-DaemonRemoteResume {
    <#
        Turns a chosen remote entry into a local session that can actually be launched,
        or $null having refused on the card.

        Every refusal happens before any bytes move, so a request that was never going to
        work does not cost a transfer: the owning machine has to be reachable, the agent
        has to be installed here, and a workspace has to be chosen for it to open in.

        That last one is a departure worth being explicit about. A resume normally reopens
        in its own folder and ignores the Workspace row - but the original folder belongs
        to another machine and usually does not exist here; this fleet alone has sessions
        under rezna, danswett and dswett. So for a session coming from elsewhere the
        Workspace row applies, and the same approved-path check governs it: Home Assistant
        still cannot name a directory the configuration has not approved.
    #>
    param(
        [Parameter(Mandatory)][object]$Entry,
        [AllowEmptyString()][string]$Label,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Workspaces,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Launchers,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $where = if ($Entry.PSObject.Properties['Machine'] -and $Entry.Machine) { [string]$Entry.Machine } else { 'another machine' }

    if (-not (Test-DaemonSharingEnabled -Name 'newSession.transferResumable')) {
        Write-DaemonLog -Message "resume refused: bringing sessions between machines is off"
        Set-CopilotMqttNewSessionResult -Headers $Headers `
            -Text "That session is on $where. Set newSession.transferResumable to bring it here." | Out-Null
        return $null
    }

    $launcher = [string]$Entry.Launcher
    if ($Launchers -notcontains $launcher) {
        $agent = Get-BridgeLauncherLabel -Launcher $launcher
        Write-DaemonLog -Message "resume refused: $agent is not installed here"
        Set-CopilotMqttNewSessionResult -Headers $Headers `
            -Text "$agent is not installed here, so that session cannot be opened." | Out-Null
        return $null
    }

    # Presence of a credential file, which is all the bridge can cheaply know - not proof
    # the token still works. A launch can still fail on authentication afterwards, and
    # says so rather than pretending the resume was at fault.
    $usage = $null
    try { $usage = Get-BridgeLauncherUsage -Launcher $launcher } catch { }
    if ($null -ne $usage -and $usage.PSObject.Properties['SignedIn'] -and -not $usage.SignedIn) {
        $agent = Get-BridgeLauncherLabel -Launcher $launcher
        Write-DaemonLog -Message "resume refused: not signed in to $agent here"
        Set-CopilotMqttNewSessionResult -Headers $Headers `
            -Text "Not signed in to $agent on this machine - sign in, then try again." | Out-Null
        return $null
    }

    # Presence can change between the list being drawn and the button being pressed; a
    # laptop went to sleep in the two minutes between the two while this was being built.
    $online = $false
    try {
        $peer = @(Get-DaemonPeerMachines -Headers $Headers) | Where-Object { [string]$_.Slug -eq [string]$Entry.Slug } | Select-Object -First 1
        $online = ($null -ne $peer -and $peer.Online)
    }
    catch { }
    if (-not $online) {
        Write-DaemonLog -Message "resume refused: $where is not online"
        Set-CopilotMqttNewSessionResult -Headers $Headers `
            -Text "$where is offline, so that session cannot be fetched right now." | Out-Null
        return $null
    }

    $target = Get-DaemonRemoteResumeWorkspace -Workspaces $Workspaces -Headers $Headers
    if (-not $target) {
        Write-DaemonLog -Message 'resume refused: no workspace selected for a transferred session'
        Set-CopilotMqttNewSessionResult -Headers $Headers `
            -Text 'Pick a Workspace for it to open in - a session from another machine has no folder here.' | Out-Null
        return $null
    }

    $newId = Receive-DaemonSessionTransfer -Entry $Entry -WorkingDirectory $target -Headers $Headers
    if (-not $newId) { return $null }

    # A session of its own now, so it resumes exactly like any local one.
    [pscustomobject]@{
        SessionId = $newId
        Launcher  = $launcher
        Summary   = [string]$Entry.Summary
        Folder    = $target
        Updated   = [DateTimeOffset]::Now
    }
}

function Get-DaemonRemoteResumeWorkspace {
    <#
        The approved directory a transferred session should open in, or '' when the
        selector does not name one.

        No silent fallback to the first workspace. A transfer writes a transcript into
        this machine's agent home and opens it somewhere; which directory that is should
        be what the person chose, not whatever happens to sort first because a state read
        failed or the row was never touched.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Workspaces,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $label = ''
    try { $label = [string](Get-HomeAssistantState -EntityId $script:DaemonEntity.NewWorkspace -Headers $Headers).state } catch { return '' }
    if ([string]::IsNullOrWhiteSpace($label) -or $label -in @('unknown', 'unavailable')) { return '' }
    $choice = @($Workspaces) | Where-Object { [string]$_.Label -eq $label } | Select-Object -First 1
    if ($null -eq $choice) { return '' }
    if (-not (Test-BridgeWorkspacePathApproved -Path ([string]$choice.Path))) { return '' }
    [string]$choice.Path
}

function Get-DaemonRemoteResumeLabel {
    <#
        The dropdown label for a session on another machine.

        It names the machine because that is the useful fact: the session can be opened
        here, but doing so brings its transcript across, and someone choosing between
        two similar entries should be able to see which is which. The short id is always
        present - without shared detail it is the only thing distinguishing two entries.
    #>
    param([Parameter(Mandatory)][object]$Entry)

    $short = [string]$Entry.SessionId
    if ($short.Length -gt 8) { $short = $short.Substring(0, 8) }
    $agent = if ($Entry.Launcher) { Get-BridgeLauncherLabel -Launcher ([string]$Entry.Launcher) } else { 'Session' }

    $what = if ($Entry.Summary) { [string]$Entry.Summary } elseif ($Entry.Leaf) { [string]$Entry.Leaf } else { $short }
    $label = "$agent on $($Entry.Machine): $what"
    if ($Entry.Summary -or $Entry.Leaf) { $label = "$label ($short)" }
    if ($label.Length -gt 110) { $label = $label.Substring(0, 107) + '...' }
    $label
}

# Which daemon entity drives each tuning axis. Spelled out rather than derived from
# the axis name: a culture-aware title-case would turn 'model' into something else
# under a Turkish locale, and a silent miss here shows as a selector that never
# leaves 'unknown'.
$script:DaemonTuningEntityKey = @{
    model   = 'NewModel'
    effort  = 'NewEffort'
    context = 'NewContext'
}

function Get-DaemonTuningEntityId {
    <# The selector that carries one tuning axis, or '' for an axis with no entity. #>
    param([Parameter(Mandatory)][string]$Axis)
    if (-not $script:DaemonTuningEntityKey.ContainsKey($Axis)) { return '' }
    [string]$script:DaemonEntity[$script:DaemonTuningEntityKey[$Axis]]
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
        [AllowEmptyCollection()][string[]]$Agents = @(),

        # The whole control set, for the tuning selectors: each has to be driven to
        # the default for the agent its options were built for, which the three lists
        # above do not carry.
        $Controls = $null
    )

    $stale = @('unknown', 'unavailable', '')

    if ($Agents.Count -gt 0) {
        $default = Get-BridgeLauncherLabel -Launcher (Get-BridgeLauncherKind)
        if ($Agents -notcontains $default) { $default = $Agents[0] }
        try {
            # A selection still showing the previous default was never the user's
            # choice, so it follows the default when that moves; one they picked stays.
            $current = [string](Get-HomeAssistantState -EntityId $script:DaemonEntity.NewAgent -Headers $Headers).state
            $untouched = $null -ne $script:DaemonDefaultAgent -and $current -eq $script:DaemonDefaultAgent
            if ($current -in $stale -or $Agents -notcontains $current -or ($untouched -and $current -ne $default)) {
                Invoke-HomeAssistantService -Domain 'select' -Service 'select_option' -Headers $Headers `
                    -Data @{ entity_id = $script:DaemonEntity.NewAgent; option = $default }
            }
            if ($script:DaemonDefaultAgent -ne $default) {
                $script:DaemonDefaultAgent = $default
                try { [System.IO.File]::WriteAllText($script:DaemonDefaultAgentFile, $default) } catch { }
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

    # Model, effort and context. Each is driven to the configured default for the
    # agent whose options are currently published, and re-driven whenever it holds
    # something that agent does not offer - which is exactly what happens on
    # switching agents, since Copilot's models are not Claude's. Left alone otherwise,
    # so a value the user picked survives every reconcile.
    if ($null -ne $Controls -and $Controls.PSObject.Properties['Tuning']) {
        foreach ($axis in @(Get-BridgeTuningAxes)) {
            $options = @($Controls.Tuning[$axis])
            if ($options.Count -eq 0) { continue }
            $entityId = Get-DaemonTuningEntityId -Axis $axis
            if ([string]::IsNullOrWhiteSpace($entityId)) { continue }
            $wanted = Get-BridgeDefaultTuning -Launcher ([string]$Controls.TuningFor) -Axis $axis
            if ($options -notcontains $wanted) { $wanted = $options[0] }
            try {
                # From this pass's snapshot: these three are read on every reconcile
                # and would otherwise be three more HTTP round trips per pass, on a
                # loop whose whole point is to cost one.
                $current = [string](Get-DaemonEntityState -EntityId $entityId -Headers $Headers).state
                if ($current -in $stale -or $options -notcontains $current) {
                    Invoke-HomeAssistantService -Domain 'select' -Service 'select_option' -Headers $Headers `
                        -Data @{ entity_id = $entityId; option = $wanted }
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

    # Permissions open on whatever this machine's newSession.allowAllTools would have
    # done, so the control states the existing behaviour instead of quietly changing
    # it. Only while it holds nothing meaningful - a value someone picked survives
    # every reconcile, exactly like the workspace and the tuning axes.
    try {
        $current = [string](Get-HomeAssistantState -EntityId $script:DaemonEntity.NewPermissions -Headers $Headers).state
        $valid = @(Get-BridgePermissionOptions)
        if ($current -in $stale -or $valid -notcontains $current) {
            $option = Get-BridgePermissionLabel -AllowAllTools ([bool](Get-BridgeSetting 'newSession.allowAllTools' $false))
            Invoke-HomeAssistantService -Domain 'select' -Service 'select_option' -Headers $Headers `
                -Data @{ entity_id = $script:DaemonEntity.NewPermissions; option = $option }
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

        A press is, in order of precedence: the second press that confirms a launched
        Claude session may trust its folder, the first message for a Codex opened
        without one, or a new launch.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$Live
    )

    if (-not (Get-BridgeSetting 'newSession.enabled' $true)) { return }

    $controls = Get-DaemonNewSessionControls -Live $Live -Headers $Headers
    if (-not (Publish-DaemonNewSessionControls -Controls $controls -Headers $Headers)) { return }
    Set-DaemonNewSessionDefaults -Headers $Headers -Workspaces $controls.Workspaces -Profiles $controls.Profiles `
        -Resumable $controls.Resumable -Agents $controls.Agents -Controls $controls

    if (-not (Test-DaemonNewSessionPressed -Headers $Headers)) { return }
    if (Confirm-DaemonPendingTrust -Headers $Headers) { return }
    if (Send-DaemonPendingFirstMessage -Headers $Headers) { return }

    $request = Resolve-DaemonLaunchRequest -Controls $controls -Headers $Headers
    if ($null -eq $request) { return }
    Start-DaemonLaunch -Request $request -Headers $Headers
}

function Get-DaemonNewSessionControls {
    <# What the launch card offers now: workspaces, agents, profiles, resumable sessions. #>
    param(
        [Parameter(Mandatory)][hashtable]$Live,
        [hashtable]$Headers = @{}
    )

    $workspaces = @(Get-BridgeWorkspaceChoices)
    $launcher = Get-BridgeLauncherKind
    $launchers = @(Get-BridgeAvailableLaunchers)
    $agents = @($launchers | ForEach-Object { Get-BridgeLauncherLabel -Launcher $_ })
    # Assigned in two steps deliberately: `$x = if (...) { @(...) } else { @() }`
    # collapses an empty array to $null, and StrictMode then throws on .Count.
    # Profiles are offered whenever Agency is installed, since it can be chosen as the
    # agent at launch time even when it is not the default - and only the ones Agency
    # actually has here, which on a machine that has none is no row at all.
    $profiles = @()
    if ($launchers -contains 'agency') { $profiles = @(Get-BridgeAgencyProfiles) }

    # The model, effort and context lists belong to whichever agent is selected right
    # now, not to the default one: Claude's models are not Copilot's, and offering the
    # wrong set is offering a launch that cannot work. The selector is read here
    # rather than only at press time - unlike the workspace and the prompt, which only
    # matter in combination with a press - because these three change what the card
    # itself shows.
    $tuningFor = Get-DaemonSelectedLauncher -Fallback $launcher -Installed $launchers -Headers $Headers
    $tuning = @{}
    foreach ($axis in @(Get-BridgeTuningAxes)) {
        $tuning[$axis] = @(Get-BridgeTuningOptions -Launcher $tuningFor -Axis $axis)
    }

    [pscustomobject]@{
        Workspaces = $workspaces
        Launcher   = $launcher
        Launchers  = $launchers
        Agents     = $agents
        Profiles   = $profiles
        TuningFor  = $tuningFor
        Tuning     = $tuning
        Resumable  = @(Get-DaemonMergedResumable -Live $Live -Headers $Headers)
    }
}

function Get-DaemonSelectedLauncher {
    <#
        Which agent the card is showing, from its selector - or -Fallback when it has
        not been touched, names something that is not installed, or cannot be read.

        A failure here is never an error: it simply means the default agent, and the
        launch itself re-reads the selector at press time anyway.
    #>
    param(
        [Parameter(Mandatory)][string]$Fallback,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Installed,
        [hashtable]$Headers = @{}
    )

    $label = ''
    try { $label = [string](Get-DaemonEntityState -EntityId $script:DaemonEntity.NewAgent -Headers $Headers).state } catch { }
    if ([string]::IsNullOrWhiteSpace($label) -or $label -in @('unknown', 'unavailable')) { return $Fallback }
    $resolved = Resolve-BridgeLauncher -Label $label
    if ([string]::IsNullOrWhiteSpace($resolved) -or $Installed -notcontains $resolved) { return $Fallback }
    [string]$resolved
}

function Publish-DaemonNewSessionControls {
    <#
        Publishes the launch card's controls when what they offer has changed, so an
        unchanged bridge sends nothing on a normal reconcile. Returns $false when the
        publish failed, and the rest of the pass is skipped.
    #>
    param(
        [Parameter(Mandatory)]$Controls,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $workspaces = $Controls.Workspaces
    $agents = $Controls.Agents
    $profiles = $Controls.Profiles
    $resumable = $Controls.Resumable
    $launcher = $Controls.Launcher
    # The tuning lists belong to the selected agent, so the agent they were built for
    # is part of the signature too: switching from Copilot to Claude has to republish
    # them even in the freak case where the two offer the same number of options.
    $tuningSignature = ''
    if ($Controls.PSObject.Properties['Tuning']) {
        $tuningSignature = '#' + [string]$Controls.TuningFor + '#' +
            ((@(Get-BridgeTuningAxes) | ForEach-Object { "$_=" + (@($Controls.Tuning[$_]) -join ',') }) -join ';')
    }
    $signature = (($workspaces | ForEach-Object { "$($_.Label)=$($_.Path)" }) -join '|') +
        "#$launcher#" + ($agents -join ',') + '#' + ($profiles -join ',') +
        '#' + (($resumable | ForEach-Object { [string]$_.SessionId }) -join ',') + $tuningSignature
    if (-not $script:DaemonNewSessionPublished -or $signature -ne $script:DaemonNewSessionSignature) {
        try {
            $tuning = @{}
            if ($Controls.PSObject.Properties['Tuning']) { $tuning = [hashtable]$Controls.Tuning }
            Publish-CopilotMqttNewSession -Workspaces $workspaces -Profiles $profiles `
                -Resumable $resumable -Agents $agents -Tuning $tuning -Headers $Headers | Out-Null
            [void](Set-CopilotMqttNewSessionEntityIds)
            $script:DaemonNewSessionPublished = $true
            $script:DaemonNewSessionSignature = $signature
            Write-DaemonLog -Message "new-session controls published ($($workspaces.Count) workspace(s), agents: $(if ($agents.Count) { $agents -join ', ' } else { 'none' }), default $launcher$(if ($profiles.Count) { ", profiles: $($profiles -join ', ')" }), $($resumable.Count) resumable)"
        }
        catch {
            Write-DaemonLog -Message "new-session publish failed: $($_.Exception.Message)"
            return $false
        }
    }
    $true
}

function Test-DaemonNewSessionPressed {
    <#
        Whether Launch has been pressed since the last look - and since this daemon
        started: a press from before that is history left in a retained value.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    try {
        $button = Get-HomeAssistantState -EntityId $script:DaemonEntity.NewSession -Headers $Headers
        $press = [string]$button.state
    }
    catch {
        # The button may not exist yet on a first run.
        return $false
    }

    if ($press -in @('unknown', 'unavailable', '')) { return $false }
    if ($press -eq $script:DaemonNewSessionLastPress) { return $false }
    $script:DaemonNewSessionLastPress = $press

    $pressedAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($press, [ref]$pressedAt)) { return $false }
    if ($pressedAt -le $script:DaemonStartedAt) { return $false }

    # Who pressed Launch, kept for the session this press is about to produce. The
    # press is the only thing that carries the account behind it - by the time the
    # session registers, seconds later, there is nothing left to ask. Read here for
    # the same reason a Submit press is read in daemon-replies.ps1.
    $script:DaemonNewSessionPressDriver = Get-BridgeDriverFromState -State $button
    $true
}

function Confirm-DaemonPendingTrust {
    <#
        Takes a press while a launched Claude session is asking whether to trust its
        folder as the user's confirmation, not a request for another session: trusting
        lets Claude read, edit and run files there, so the bridge only ever answers it
        on this deliberate second press. The answer is sent on the next pass, from the
        screen as it is then. Returns whether the press was that.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    $pending = $script:DaemonPendingLaunch
    if ($null -eq $pending -or $null -eq $pending.TrustAskedAt -or $pending.TrustConfirmed) { return $false }
    if (([DateTimeOffset]::Now - $pending.TrustAskedAt).TotalSeconds -gt 120) { return $false }

    $pending.TrustConfirmed = $true
    $pending.LastCheck = [DateTimeOffset]::MinValue
    $agent = Get-BridgeLauncherLabel -Launcher ([string]$pending.Launcher)
    Write-DaemonLog -Message "Launch pressed again: trusting the folder for the $agent session in $($pending.Label)"
    Set-CopilotMqttNewSessionResult -Headers $Headers -Text "Trusting $($pending.Label) for $agent..." | Out-Null
    Update-DaemonPendingLaunch -Headers $Headers | Out-Null
    $true
}

function Get-DaemonLaunchPrompt {
    <#
        The first message the launch card is offering, from whichever of its two
        boxes carries it.

        The card publishes the whole prompt to the payload sensor, whose attribute has
        no length limit; the text entity beside it is what a dashboard running an
        older card still writes, and Home Assistant caps that at 255 characters. The
        payload wins when it has anything in it, so a long handover prompt arrives
        whole instead of cut off mid-sentence.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    try {
        $payload = Get-BridgeReplyPayload -State (Get-HomeAssistantState `
            -EntityId $script:DaemonEntity.NewPromptPayload -Headers $Headers)
        if ($null -ne $payload -and -not [string]::IsNullOrWhiteSpace([string]$payload.Text)) {
            return ([string]$payload.Text).Trim()
        }
    }
    catch {
        # No payload sensor yet (a machine published before this existed), or it is
        # unreadable. The text box still works, within its 255 characters.
    }

    $typed = ''
    try { $typed = [string](Get-HomeAssistantState -EntityId $script:DaemonEntity.NewPrompt -Headers $Headers).state } catch { }
    if ($typed -in @('unknown', 'unavailable')) { $typed = '' }
    $typed.Trim()
}

function Clear-DaemonLaunchPrompt {
    <#
        Empties both prompt boxes once their text has been used, so the next press
        does not silently repeat the last prompt.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    try {
        Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers -Data @{
            entity_id = $script:DaemonEntity.NewPrompt; value = $script:DaemonConfig.ReplyBlankValue
        } | Out-Null
    }
    catch { }
    try { Clear-CopilotMqttNewSessionPrompt -Headers $Headers | Out-Null } catch { }
}

function Send-DaemonPendingFirstMessage {
    <#
        Sends the First message box into a Codex launched without a first message:
        Codex creates its session - and so becomes visible here - only on its first
        message. Only while Codex is still the chosen agent and there is a message to
        send: any other press is a new launch, and the waiting window is left to
        itself. Returns whether the press was dealt with here.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    $pending = $script:DaemonPendingLaunch
    if ($null -eq $pending -or -not $pending.PSObject.Properties['AwaitingFirstMessage'] -or -not $pending.AwaitingFirstMessage) { return $false }

    $first = ''
    $firstAgent = ''
    try { $first = Get-DaemonLaunchPrompt -Headers $Headers } catch { }
    try { $firstAgent = [string](Get-HomeAssistantState -EntityId $script:DaemonEntity.NewAgent -Headers $Headers).state } catch { }
    if ($first -in @('unknown', 'unavailable')) { $first = '' }
    $first = $first.Trim()
    $agent = Get-BridgeLauncherLabel -Launcher ([string]$pending.Launcher)
    if (-not $first -or ($firstAgent -and (Resolve-BridgeLauncher -Label $firstAgent) -ne [string]$pending.Launcher)) {
        Write-DaemonLog -Message "stopped waiting on the $agent in $($pending.Label) for a first message: a new launch was asked for"
        $script:DaemonPendingLaunch = $null
        return $false
    }

    $delivery = Send-CopilotSessionPrompt -SessionId "$($pending.Launcher)-launch" -ProcessId $pending.ProcessId -Text $first
    Write-DaemonLog -Message "first message sent to the $agent launched in $($pending.Label) (pid $($pending.ProcessId)): $($delivery.Detail)"
    if (-not $delivery.Delivered) {
        Set-CopilotMqttNewSessionResult -Headers $Headers -Text "Couldn't send that to $agent ($($delivery.Detail)) - type it in its window." | Out-Null
        return $true
    }
    $pending.AwaitingFirstMessage = $false
    $pending.Since = [DateTimeOffset]::Now
    $pending.LastCheck = [DateTimeOffset]::MinValue
    Set-CopilotMqttNewSessionResult -Headers $Headers -Text "Sending your first message to $agent in $($pending.Label)..." | Out-Null
    Clear-DaemonLaunchPrompt -Headers $Headers
    $true
}

function Resolve-DaemonLaunchRequest {
    <#
        Reads what a press asks for - agent, resume, workspace, prompt, profile - and
        checks it against what is installed and configured. Returns the request, or
        $null when it is refused, having said why on the card: a value arriving from
        Home Assistant never picks an executable or a folder unchecked.
    #>
    param(
        [Parameter(Mandatory)]$Controls,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $workspaces = $Controls.Workspaces
    $launcher = $Controls.Launcher
    $launchers = $Controls.Launchers
    $profiles = $Controls.Profiles
    $resumable = $Controls.Resumable

    if ($workspaces.Count -eq 0) {
        Write-DaemonLog -Message 'new session requested but no workspaces are configured'
        Set-CopilotMqttNewSessionResult -Headers $Headers `
            -Text 'No workspaces configured - add newSession.workspaces to the bridge config' | Out-Null
        return $null
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
            Set-CopilotMqttNewSessionResult -Text "Unknown agent '$agentLabel'" -Headers $Headers | Out-Null
            return $null
        }
        # Nothing is installed: let the launch attempt name what is missing.
        $chosenLauncher = $launcher
    }

    # Resume, if one is selected. The chosen session brings its own agent and working
    # directory: a Claude conversation reopens in Claude whatever the agent selector
    # says, and resuming somewhere other than where it happened would point the agent
    # at the wrong tree. The agent and workspace selectors are therefore ignored for
    # a resume; the profile still applies to an Agency one.
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
                Set-CopilotMqttNewSessionResult -Text "That session is no longer resumable" -Headers $Headers | Out-Null
                return $null
            }
        }
    }
    catch { }
    if ($null -ne $resumeSession) {
        # A session on another machine. Bring it over if we can, and refuse plainly if we
        # cannot - but never fall through to a launch. That matters more than it reads:
        # a remote entry reaching the launcher arrives as `--session-id` with no
        # transcript, and Copilot answers that by silently starting a new empty session
        # under that id and exiting 0, which the daemon then adopts as a resume that
        # worked. The workspace check below cannot be relied on to stop it either, since
        # the same approved path can exist on both machines.
        if ($resumeSession.PSObject.Properties['Remote'] -and $resumeSession.Remote) {
            $transferred = Resolve-DaemonRemoteResume -Entry $resumeSession -Label $resumeLabel `
                -Workspaces $workspaces -Launchers $launchers -Headers $Headers
            if ($null -eq $transferred) { return $null }
            $resumeSession = $transferred
            $resumeLabel = "$resumeLabel (brought over)"
        }
        if (-not $resumeSession.PSObject.Properties['Folder'] -or
            -not (Test-BridgeWorkspacePathApproved -Path ([string]$resumeSession.Folder))) {
            Write-DaemonLog -Message 'resume refused: its working directory is missing or no longer approved'
            Set-CopilotMqttNewSessionResult -Text 'Resume refused: the original directory must exist and be an approved workspace.' -Headers $Headers | Out-Null
            return $null
        }
        # Entries from before a list carried its agent came from Agency.
        $chosenLauncher = if ($resumeSession.PSObject.Properties['Launcher'] -and $resumeSession.Launcher) { [string]$resumeSession.Launcher } else { 'agency' }
        if ($launchers -notcontains $chosenLauncher) {
            $agentName = Get-BridgeLauncherLabel -Launcher $chosenLauncher
            Write-DaemonLog -Message "resume requested for a $agentName session, but $agentName is not installed"
            Set-CopilotMqttNewSessionResult -Text "$agentName is not installed here, so that session can't be resumed" -Headers $Headers | Out-Null
            return $null
        }
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
        Set-CopilotMqttNewSessionResult -Text "Unknown workspace '$label'" -Headers $Headers | Out-Null
        return $null
    }

    $prompt = ''
    try { $prompt = Get-DaemonLaunchPrompt -Headers $Headers } catch { }
    if ($prompt -in @('unknown', 'unavailable')) { $prompt = '' }
    $prompt = $prompt.Trim()

    # Codex creates its session - its id, its session file, its first hook call -
    # only on a first message, so one launched without a prompt ran in a window the
    # bridge could never attach to. It is given a short opening message instead
    # (`newSession.codexStartPrompt`; empty turns this off, and the launch then waits
    # for a first message sent from the card).
    $needsFirst = (Get-BridgeLauncher -Launcher $chosenLauncher).NeedsFirstMessage
    if ($needsFirst -and -not $prompt) {
        $prompt = ([string](Get-BridgeSetting "newSession.${chosenLauncher}StartPrompt" $script:DaemonConfig.CodexStartPrompt)).Trim()
    }

    # The profile only applies under Agency. An untouched selector falls back to the
    # first offered profile, and one this machine's Agency does not have is refused
    # outright rather than passed to a command line - Agency would exit 1 on it
    # before Copilot started, closing the window too fast to read.
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
            Write-DaemonLog -Message "new session requested with unknown profile '$profileLabel' (this machine has: $($profiles -join ', '))"
            # Named, because the reason is almost always that this machine's Agency
            # config is not the one the profile was chosen from.
            Set-CopilotMqttNewSessionResult -Headers $Headers `
                -Text "Unknown profile '$profileLabel' - this machine has $($profiles -join ', ')" | Out-Null
            return $null
        }
    }

    # Model, reasoning effort and context window, each validated against what the
    # agent actually being launched offers. A resume takes them too: they are
    # per-launch options, not properties of the conversation, so reopening a session
    # with a different model is exactly what the selectors are for.
    #
    # An unrecognised value is not refused the way an unknown profile is. These are
    # the one set of selectors whose options change with the agent, so a value left
    # over from a different agent is ordinary rather than suspicious - it means
    # "whatever that agent does by default", which is what an untouched card means
    # anyway.
    $tuning = @{}
    foreach ($axis in @(Get-BridgeTuningAxes)) {
        $entityId = Get-DaemonTuningEntityId -Axis $axis
        $raw = ''
        if ($entityId) {
            try { $raw = [string](Get-HomeAssistantState -EntityId $entityId -Headers $Headers).state } catch { }
        }
        $tuning[$axis] = Resolve-BridgeTuningValue -Launcher $chosenLauncher -Axis $axis -Value $raw
    }

    # Permissions, from the selector rather than from this machine's config, so the
    # person (or agent) pressing Launch decides rather than whichever machine happens
    # to run the session. The config is still the answer when the selector cannot be
    # read - a machine mid-upgrade that has not published it yet, or Home Assistant
    # refusing the read - so behaviour is unchanged until the entity exists.
    $allowAllTools = [bool](Get-BridgeSetting 'newSession.allowAllTools' $false)
    try {
        $permissionState = [string](Get-HomeAssistantState -EntityId $script:DaemonEntity.NewPermissions -Headers $Headers).state
        if ($permissionState -notin @('unknown', 'unavailable', '')) {
            $allowAllTools = Test-BridgePermissionAllowsAll -Value $permissionState
        }
    }
    catch { }

    [pscustomobject]@{
        Launcher      = $chosenLauncher
        Directory     = $directory
        Label         = $label
        Prompt        = $prompt
        AgencyProfile = $agencyProfile
        Model         = [string]$tuning['model']
        Effort        = [string]$tuning['effort']
        Context       = [string]$tuning['context']
        AllowAllTools = $allowAllTools
        ResumeSession = $resumeSession
        ResumeLabel   = $resumeLabel
    }
}

function Start-DaemonLaunch {
    <#
        Launches (or resumes) what Resolve-DaemonLaunchRequest settled on, and sets up
        the follow-up that watches for the session to register.
    #>
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $chosenLauncher = $Request.Launcher
    $directory = $Request.Directory
    $label = $Request.Label
    $prompt = $Request.Prompt
    $agencyProfile = $Request.AgencyProfile
    $resumeSession = $Request.ResumeSession
    $resumeLabel = $Request.ResumeLabel
    $choice = Get-BridgeWorkspaceChoice -Label $label
    if ($null -eq $choice -or [string]::IsNullOrWhiteSpace($directory) -or
        -not (Test-BridgeInstallPath -Left $directory -Right $choice.Path)) {
        Write-DaemonLog -Message 'launch refused: the selected workspace is no longer approved or does not match the request'
        Set-CopilotMqttNewSessionResult -Text 'Launch refused: select a currently configured workspace.' -Headers $Headers | Out-Null
        return
    }
    # Absent on a request built by an older caller or a test, which then launches
    # with whatever the config asks for, exactly as before these existed.
    $prop = { param($Name) if ($Request.PSObject.Properties[$Name]) { [string]$Request.$Name } else { '' } }
    $model = & $prop 'Model'
    $effort = & $prop 'Effort'
    $context = & $prop 'Context'
    # Same defensiveness, but this one decides whether a session runs unattended, so
    # a request that does not carry it falls back to the config rather than to $false
    # - an older caller must keep launching exactly as it did.
    $allowAllTools = if ($Request.PSObject.Properties['AllowAllTools']) {
        [bool]$Request.AllowAllTools
    }
    else { [bool](Get-BridgeSetting 'newSession.allowAllTools' $false) }
    # For the log line and the card note: "gpt-5.4 · xhigh · long_context", or nothing.
    $tuningNote = (@($model, $effort, $context) | Where-Object { $_ }) -join ' / '
    if ($allowAllTools) { $tuningNote = (@($tuningNote, 'allow all') | Where-Object { $_ }) -join ' / ' }

    $worktreeOperation = $null
    $worktreeReservation = $null
    $reservationPath = ''
    try {
        $candidate = if ($null -ne $resumeSession) { [string]$resumeSession.Folder } else { $directory }
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and [System.IO.Directory]::Exists($candidate)) {
            $reservationPath = Get-BridgeWorkspaceManagedWorktree -Path $candidate
        }
        if (($null -eq $resumeSession -and $choice.Isolate) -or $reservationPath) {
            try { $worktreeOperation = Enter-BridgeWorktreeOperation -RepositoryPath $candidate }
            catch {
                Write-DaemonLog -Message "launch refused: $($_.Exception.Message)"
                Set-CopilotMqttNewSessionResult -Text "Launch refused: requested workspace protection failed. $($_.Exception.Message)" -Headers $Headers | Out-Null
                return
            }
        }

        if ($null -ne $resumeSession) {
            $resumeDirectory = [string]$resumeSession.Folder
            if (-not (Test-BridgeWorkspacePathApproved -Path $resumeDirectory)) {
                Write-DaemonLog -Message 'resume refused: the original directory is missing or no longer approved'
                Set-CopilotMqttNewSessionResult -Text 'Resume refused: the original directory must exist and be an approved workspace.' -Headers $Headers | Out-Null
                return
            }
            if ($reservationPath) {
                try { $worktreeReservation = New-BridgeWorktreeLaunchReservation -WorktreePath $reservationPath }
                catch {
                    Write-DaemonLog -Message "resume refused: $($_.Exception.Message)"
                    Set-CopilotMqttNewSessionResult -Text "Resume refused: $($_.Exception.Message)" -Headers $Headers | Out-Null
                    return
                }
            }

            $short = $resumeSession.SessionId.Substring(0, [Math]::Min(8, $resumeSession.SessionId.Length))
            Write-DaemonLog -Message "resume requested for $short ($resumeDirectory)$(if ($agencyProfile) { " profile '$agencyProfile'" })$(if ($tuningNote) { " [$tuningNote]" })"
            Set-CopilotMqttNewSessionResult -Text "Resuming $resumeLabel..." -Headers $Headers | Out-Null

            $launchedAt = [DateTimeOffset]::Now
            $launch = Start-BridgeCopilotSession -WorkingDirectory $resumeDirectory -Prompt $prompt `
                -AgencyProfile $agencyProfile -SessionId ([string]$resumeSession.SessionId) -Launcher $chosenLauncher `
                -Model $model -Effort $effort -Context $context -AllowAllTools:$allowAllTools -Resume
        }
        else {
            $agentName = Get-BridgeLauncherLabel -Launcher $chosenLauncher

            # A workspace marked `isolate` launches in a git worktree of its own, so two
            # sessions in the same repository cannot move each other's HEAD - the failure
            # this whole feature exists to remove. Only a fresh launch: a resume belongs
            # in the directory it was already running in, above.
            $launchDirectory = $directory
            if ($null -ne $choice -and $choice.PSObject.Properties['Isolate'] -and $choice.Isolate) {
                $worktree = [pscustomobject]@{ Path = ''; Isolated = $false; Detail = '' }
                try { $worktree = New-BridgeSessionWorktree -RepositoryPath $directory }
                catch { $worktree.Detail = "worktree creation threw: $($_.Exception.Message)" }
                if (-not $worktree.Isolated -or [string]::IsNullOrWhiteSpace($worktree.Path) -or
                    -not [System.IO.Directory]::Exists($worktree.Path) -or
                    (Test-BridgeInstallPath -Left $worktree.Path -Right $directory)) {
                    $detail = if ($worktree.Detail) { $worktree.Detail } else { 'No separate worktree was provided.' }
                    Write-DaemonLog -Message "launch refused: requested isolation failed: $detail"
                    Set-CopilotMqttNewSessionResult -Text "Launch refused: requested isolation failed. $detail" -Headers $Headers | Out-Null
                    return
                }
                $launchDirectory = $worktree.Path
                $reservationPath = Get-BridgeWorkspaceManagedWorktree -Path $worktree.Path
                if ($worktree.Detail) {
                    Write-DaemonLog -Message "$(if ($worktree.Isolated) { 'worktree' } else { 'no worktree' }): $($worktree.Detail)"
                }
            }
            if ($reservationPath) {
                try { $worktreeReservation = New-BridgeWorktreeLaunchReservation -WorktreePath $reservationPath }
                catch {
                    Write-DaemonLog -Message "launch refused: $($_.Exception.Message)"
                    Set-CopilotMqttNewSessionResult -Text "Launch refused: $($_.Exception.Message)" -Headers $Headers | Out-Null
                    return
                }
            }

            Write-DaemonLog -Message "new $agentName session requested in '$label' ($launchDirectory)$(if ($agencyProfile) { " profile '$agencyProfile'" })$(if ($tuningNote) { " [$tuningNote]" })$(if ($prompt) { " with prompt: $prompt" })"
            Set-CopilotMqttNewSessionResult -Headers $Headers `
                -Text "Starting $agentName in $label$(if ($agencyProfile) { " ($agencyProfile)" })..." | Out-Null

            $launchedAt = [DateTimeOffset]::Now
            $launch = Start-BridgeCopilotSession -WorkingDirectory $launchDirectory -Prompt $prompt `
                -AgencyProfile $agencyProfile -Launcher $chosenLauncher `
                -Model $model -Effort $effort -Context $context -AllowAllTools:$allowAllTools
        }

        if (-not $launch.Launched) {
            Write-DaemonLog -Message "new session launch failed: $($launch.Detail)"
            $protectionNote = if ($null -ne $worktreeReservation) { ' The worktree remains reserved for inspection.' } else { '' }
            Set-CopilotMqttNewSessionResult -Text "Launch failed: $($launch.Detail)$protectionNote" -Headers $Headers | Out-Null
            return
        }

        Write-DaemonLog -Message "new session launched: $($launch.Detail) (session $(if ($launch.SessionId) { $launch.SessionId } else { 'id chosen by the agent' }))"

        # Remember what this session was started with, so its card can say so. The
        # command line is the only record of effort and context - neither appears in a
        # transcript, and no agent reports them back - so if it is not kept here it is
        # gone.
        #
        # Read defensively: what actually started the session is stubbed in tests and
        # replaceable in principle, and a result without these three should cost the card
        # its settings line, not fail a launch that has already happened.
        $launched = { param($Name) if ($launch.PSObject.Properties[$Name]) { [string]$launch.$Name } else { '' } }
        $launchTuning = [pscustomobject]@{
            Model   = & $launched 'Model'
            Effort  = & $launched 'Effort'
            Context = & $launched 'Context'
            At      = $launchedAt
            # Whether this reopened an existing session rather than starting a new one.
            # Adoption reads it to decide where in the transcript to start: a session
            # starting from nothing has its whole transcript read, so a first answer that
            # arrives before the daemon adopts it is still seen, while a resumed one is
            # picked up at the end so its old conversation is not replayed onto the card.
            Resumed = ($null -ne $resumeSession)
        }
        # Copilot, Agency and Claude register under the id the bridge invented, so the
        # record is filed under it straight away. Codex picks its own, so its launch waits
        # under the pending key until Update-DaemonPendingLaunch learns which session it
        # actually produced and moves it across - the same answer, from the same place,
        # that stamps the launch's driver.
        $tuningKey = if ($launch.SessionId) { [string]$launch.SessionId } else { $script:DaemonPendingTuningKey }
        $script:DaemonLaunchedTuning[$tuningKey] = $launchTuning

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
            # Allow all means "launch without permission prompts", and Claude's folder
            # trust dialog is one - the one flag that cannot waive it, because Claude only
            # skips that dialog in non-interactive mode and a bridge window is deliberately
            # interactive. Left needing a second press, an unattended launch simply stops
            # there with nobody at the keyboard, which is the deadlock the setting exists
            # to avoid. The folder is one of the configured workspaces and the choice was
            # made on the press, so the confirmation this stands in for has already
            # happened; an ordinary launch still asks for its second press.
            TrustConfirmed = $allowAllTools
            TrustAnswers   = 0
            # Who pressed Launch, carried from the press to whichever session it produces:
            # a session an agent started should show as agent-driven from the moment it
            # appears, not only once the agent first replies to it.
            Driver         = [string]$script:DaemonNewSessionPressDriver
            # Codex registers only on its first message, so one opened without a prompt
            # waits for it rather than timing out (Update-DaemonPendingLaunch).
            AwaitingFirstMessage = ((Get-BridgeLauncher -Launcher $chosenLauncher).NeedsFirstMessage -and -not $prompt)
            FirstMessageAsked    = $false
            WorktreeReservation  = $worktreeReservation
        }

        # A launch changes what is resumable - the session just started is now live, and
        # a resumed one has to leave the list - so the cache is expired rather than left
        # to age out, and the selector re-primed to "New session" on the next reconcile.
        $script:DaemonResumeCacheAt = [DateTimeOffset]::MinValue
        $script:DaemonNewSessionSignature = ''

        # Clear the prompt box so the next launch starts from a blank field instead of
        # silently reusing the previous prompt. Both boxes: the payload topic is retained,
        # so a long prompt left there would start the next session too.
        if ($prompt) { Clear-DaemonLaunchPrompt -Headers $Headers }
    }
    finally {
        if ($null -ne $worktreeOperation) { $worktreeOperation.Mutex.ReleaseMutex(); $worktreeOperation.Mutex.Dispose() }
    }
}

function Resolve-DaemonLaunchTuning {
    <#
        What a session now being adopted was launched with, or $null when the bridge
        did not launch it.

        Keyed by the id the session actually registered under: an agent that takes
        `--session-id` is filed under it at launch, and one that picks its own
        (Codex) is moved across by Update-DaemonPendingLaunch, which is the one place
        that knows which session a launch produced. Deciding that here as well - by
        age, or by kind - would be a second guess at a question already answered, and
        a wrong one means a session wearing somebody else's settings.

        Taken rather than read, so a later session that happens to reuse an id cannot
        inherit them.
    #>
    param([Parameter(Mandatory)][string]$SessionId)

    if (-not $script:DaemonLaunchedTuning.ContainsKey($SessionId)) { return $null }
    $record = $script:DaemonLaunchedTuning[$SessionId]
    [void]$script:DaemonLaunchedTuning.Remove($SessionId)
    $record
}

function Clear-DaemonStaleLaunchTuning {
    <#
        Drops launch records whose session never appeared - a publish that kept
        failing, a window closed before it registered, or a Codex that never got a
        first message. Without this a record would sit under the pending key for the
        life of the daemon, waiting for an id that never comes, and the next launch
        of that agent would find it there.
    #>
    foreach ($key in @($script:DaemonLaunchedTuning.Keys)) {
        if (([DateTimeOffset]::Now - $script:DaemonLaunchedTuning[$key].At).TotalMinutes -gt 15) {
            [void]$script:DaemonLaunchedTuning.Remove($key)
        }
    }
}

function Test-DaemonLaunchProgressNote {
    <# Whether a launch note is about a launch still being followed, not an outcome. #>
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $t = ([string]$Text).Trim()
    if (-not $t) { return $false }
    # "<Agent> is open in ...", "<Agent> is asking whether to trust ..." and "<Agent> in
    # <folder> is asking you to trust ...", for any agent (see Update-DaemonPendingLaunch);
    # "is still asking" is an outcome, and not matched.
    $t.EndsWith('...') -or $t -like '* is open in *. It appears here after*' -or
        $t -like '* is asking whether to trust *' -or $t -like '* is asking you to trust *'
}

function Clear-DaemonStaleNote {
    <#
        Clears the launch card's note once it is NoteExpirySeconds old. A note says
        what the last press or setup came to; once that is old news it only sits
        there - "setting it up failed" long after it had been fixed. Its age comes
        from Home Assistant's last_changed, so a note left from before a restart is
        caught too. Never while a launch is still being followed up: that note is
        live ("press Launch again to trust this folder").
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    if ($null -ne $script:DaemonPendingLaunch) { return }
    try {
        $state = Get-HomeAssistantState -EntityId $script:DaemonEntity.NewResult -Headers $Headers
        $text = [string]$state.state
        if ([string]::IsNullOrWhiteSpace($text) -or $text -in @('unknown', 'unavailable')) { return }
        $changed = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$state.last_changed, [ref]$changed)) { return }
        if (([DateTimeOffset]::Now - $changed).TotalSeconds -lt $script:DaemonConfig.NoteExpirySeconds) { return }
        Set-CopilotMqttNewSessionResult -Headers $Headers -Text ''
        Write-DaemonLog -Message "cleared the launch note: $text"
    }
    catch { }
}

function Clear-DaemonLaunchNoteOnRegistration {
    <#
        Drops the launch note once a session has actually registered.

        A launch gives up waiting after 90 seconds and leaves "started ... but has not
        registered - check its window". That is short for a first-ever launch, which
        has to sign in and approve the agent's hooks first: seen on a Mac where Codex
        registered three minutes after the note was written, so the note sat there
        insisting the session had not arrived while its own card sat next to it. The
        ten-minute expiry cleared it eventually, long after it had become untrue.

        A session registering is the proof that note is obsolete, whichever launch it
        came from. A launch still being followed keeps its own note: that one is
        current, and Update-DaemonPendingLaunch clears it itself.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    if ($null -ne $script:DaemonPendingLaunch) { return }
    try {
        $state = Get-HomeAssistantState -EntityId $script:DaemonEntity.NewResult -Headers $Headers
        $text = [string]$state.state
        if ([string]::IsNullOrWhiteSpace($text) -or $text -in @('unknown', 'unavailable')) { return }
        Set-CopilotMqttNewSessionResult -Headers $Headers -Text ''
        Write-DaemonLog -Message "cleared the launch note now a session has registered: $text"
    }
    catch { }
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
        if ($p.PSObject.Properties['WorktreeReservation'] -and $null -ne $p.WorktreeReservation) {
            [void](Remove-BridgeWorktreeLaunchReservation -Reservation $p.WorktreeReservation)
        }
        # Stamp the launcher's driver on the session this launch produced, by the id it
        # actually registered under rather than the one it was offered - Codex picks
        # its own. Read from the same check that just said it had registered, so the
        # two can never name different sessions.
        #
        # The settings the launch chose need the same answer for the same reason, so
        # both are taken from one call rather than each guessing separately.
        $pendingTuning = $script:DaemonLaunchedTuning[$script:DaemonPendingTuningKey]
        if ($p.Driver -eq 'agent' -or $null -ne $pendingTuning) {
            $registeredId = Get-BridgeRegisteredSessionId -SessionId $p.SessionId -Launcher $p.Launcher -Since $p.Since
            if (-not [string]::IsNullOrWhiteSpace($registeredId)) {
                # A launch whose session is never adopted - a publish that keeps
                # failing - would otherwise leave its driver here for the life of the
                # daemon, waiting for an id that never comes.
                foreach ($stale in @($script:DaemonLaunchDrivers.Keys)) {
                    if (([DateTimeOffset]::Now - $script:DaemonLaunchDrivers[$stale].At).TotalMinutes -gt 15) {
                        $script:DaemonLaunchDrivers.Remove($stale)
                    }
                }
                if ($p.Driver -eq 'agent') {
                    $script:DaemonLaunchDrivers[$registeredId] = @{ Driver = $p.Driver; At = [DateTimeOffset]::Now }
                }
                # Move the launch's settings onto the id the session really registered
                # under. Only an agent that picks its own id (Codex) is ever waiting
                # here; the rest were filed under their id at launch.
                if ($null -ne $pendingTuning) {
                    [void]$script:DaemonLaunchedTuning.Remove($script:DaemonPendingTuningKey)
                    $script:DaemonLaunchedTuning[$registeredId] = $pendingTuning
                }
            }
        }
        Clear-DaemonStaleLaunchTuning
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

    if ((Get-BridgeLauncher -Launcher $p.Launcher).AnswersTrustPrompt -and $p.ProcessId -gt 0) {
        $selection = Read-BridgeTrustPrompt -ProcessId $p.ProcessId
        if ($selection) {
            if ($p.TrustConfirmed) {
                if ($p.TrustAnswers -lt 3) {
                    $p.TrustAnswers++
                    $sent = Send-BridgeTrustAnswer -ProcessId $p.ProcessId -Selection $selection
                    Write-DaemonLog -Message "answered $agent's trust question for $($p.Label) (highlight was '$selection'): $sent"
                }
            }
            elseif ($null -eq $p.TrustAskedAt) {
                $p.TrustAskedAt = $now
                Write-DaemonLog -Message "$agent in $($p.Label) is asking whether to trust the folder; waiting for a second press"
                Set-CopilotMqttNewSessionResult -Headers $Headers `
                    -Text "$agent is asking whether to trust $($p.Label). Press Launch again within 2 minutes to trust it and start."
            }
            elseif (($now - $p.TrustAskedAt).TotalSeconds -gt 120) {
                & $finish "$agent is still asking whether to trust $($p.Label) - answer it in its window." `
                    "trust confirmation for $($p.Label) expired; left for the window"
            }
            return
        }
    }

    # A question only the agent's window can answer (Codex's hook review) holds the
    # session back from registering. The window is read every couple of seconds until
    # one shows; the note then says what to do, and the launch waits for it.
    $blocking = (Get-BridgeLauncher -Launcher $p.Launcher).BlockingPrompt
    $blocked = $p.PSObject.Properties['BlockedAt'] -and $null -ne $p.BlockedAt
    # Never this process's own: reading a screen attaches to that console and detaches
    # after, which would leave this process with none.
    if ($blocking -and $p.ProcessId -gt 0 -and $p.ProcessId -ne $PID -and -not $blocked -and ($now - $p.Since).TotalSeconds -ge 3) {
        $lastLook = if ($p.PSObject.Properties['ScreenReadAt']) { $p.ScreenReadAt } else { [DateTimeOffset]::MinValue }
        if (($now - $lastLook).TotalSeconds -ge 2) {
            Set-DaemonSessionProperty -Entry $p -Name 'ScreenReadAt' -Value $now
            $note = $null
            try { $note = & $blocking (Read-BridgeConsoleScreen -ProcessId $p.ProcessId) } catch { }
            if ($note) {
                Set-DaemonSessionProperty -Entry $p -Name 'BlockedAt' -Value $now
                $blocked = $true
                Write-DaemonLog -Message "$agent in $($p.Label) is waiting on a question in its window: $note"
                try { Set-CopilotMqttNewSessionResult -Headers $Headers -Text ($note -f $p.Label) } catch { }
            }
        }
    }
    if ($blocked) {
        if (($now - $p.BlockedAt).TotalMinutes -gt 10) {
            & $finish "$agent in $($p.Label) is still waiting on a question in its window - answer it there." `
                "launched $agent (pid $($p.ProcessId)) still blocked after 10 minutes; stopped waiting"
        }
        return
    }

    # A Codex opened without a first message has no session until it gets one. Once
    # its window has had a moment to come up, the note says so and offers to send one
    # from the card; it waits for as long as the window stays open (up to an hour),
    # since there is no session to time out yet.
    if ($p.PSObject.Properties['AwaitingFirstMessage'] -and $p.AwaitingFirstMessage) {
        if (-not $p.FirstMessageAsked -and ($now - $p.Since).TotalSeconds -ge 4) {
            $p.FirstMessageAsked = $true
            Write-DaemonLog -Message "$agent in $($p.Label) is open and waiting for its first message"
            Set-CopilotMqttNewSessionResult -Headers $Headers `
                -Text "$agent is open in $($p.Label). It appears here after its first message: type one under First message and press Launch, or type it in its window."
        }
        if (($now - $p.Since).TotalMinutes -gt 60) {
            & $finish '' "$agent in $($p.Label) never got a first message; stopped waiting"
        }
        return
    }

    $slowNoted = $p.PSObject.Properties['SlowNotePosted'] -and $p.SlowNotePosted
    if (-not $slowNoted -and ($now - $p.Since).TotalSeconds -gt 90) {
        Set-DaemonSessionProperty -Entry $p -Name 'SlowNotePosted' -Value $true
        # Deliberately not "has not registered": a first-ever launch has to sign in and
        # approve hooks first, and this often registers minutes later. Saying it may
        # still be starting keeps the note true when that happens; the session
        # registering clears it (Clear-DaemonLaunchNoteOnRegistration).
        Write-DaemonLog -Message "launched $agent (pid $($p.ProcessId)) has not registered within 90 s; still watching"
        try {
            Set-CopilotMqttNewSessionResult -Headers $Headers `
                -Text "$agent started in $($p.Label) (pid $($p.ProcessId)) and may still be starting - check its window."
        }
        catch { }
    }

    # The launch stays under watch instead of being dropped at 90 seconds.
    #
    # Dropping it stopped the window being read at all, and a trust prompt - Claude's
    # "do you trust the files in this folder?" - often appears after that, or is simply
    # not drawn yet on the first sweep. The two-press flow that answers it then had
    # nothing left to work with, so pressing Launch again was the only way back. Seen
    # exactly that way: a first launch waited the 90 seconds and gave up, and the next
    # one found the prompt in two seconds.
    #
    # The process exiting ends this above, and so does registering; ten minutes is the
    # backstop, as it is for a window already known to be blocked.
    if (($now - $p.Since).TotalMinutes -gt 10) {
        & $finish "$agent in $($p.Label) never registered - check its window." `
            "launched $agent (pid $($p.ProcessId)) did not register within 10 minutes; stopped waiting"
    }
}
