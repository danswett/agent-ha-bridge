<#
    Bridge daemon: keeping the install current.

    Update checks and their outcome on the dashboard, setting up agents installed
    after the bridge, and handing unused memory back.

    Part of agent-bridge-daemon.ps1, which dot-sources it into its own scope after
    declaring the shared $script: state; see docs/daemon-split.md.
    Shared state it changes: DaemonClientSetup, DaemonRestartRequested,
    DaemonUpdateAvailable, DaemonUpdateLastPress, DaemonUpdatePublished,
    DaemonMemoryTrimmedAt, DaemonUpdateVerdict, DaemonUpdateCheckLastPress,
    DaemonPeerLatestVersion, DaemonPeerLatestChecked, DaemonUpdateEntityIdsPinned,
    DaemonUpdateEntityIdsPinnedAt.
#>

$script:DaemonMemoryTrimmedAt = [DateTimeOffset]::MinValue
$script:DaemonUpdateSignature = ''
$script:DaemonUpdatePendingAttempt = ''

# The installed version this daemon's code came from, recorded on the first check
# rather than when this file is loaded, so loading it for its functions reads nothing.
# See Request-DaemonVersionRestart.
$script:DaemonRunningVersion = ''

# How an attempt ended, when no progress file says - the two outcomes where the
# updater never started and so never wrote one: a release already installed, and a
# launch that failed. Held in memory because neither restarts the daemon.
$script:DaemonUpdateVerdict = $null

# How long a terminal verdict stays on the entity. Long enough to be read by someone
# who pressed the button and looked away, short enough that it is plainly about the
# press they just made rather than one from yesterday.
$script:DaemonUpdateVerdictMinutes = 10

# How stale a progress record may be and still be published. The reader is bound to
# the attempt, but a daemon that restarted mid-update has no attempt id to bind to
# and accepts any - so a file from an update that finished days ago would otherwise
# leave the card reporting it forever.
$script:DaemonUpdateProgressHours = 1

function Set-DaemonUpdateVerdict {
    <# Records how an attempt ended, for the publish that follows. #>
    param(
        [Parameter(Mandatory)][ValidateSet('completed', 'failed', 'current')][string]$Stage,
        [string]$Detail = '',
        # The attempt this verdict is about, where there is one. A verdict that names
        # no attempt is one for a press that never started an updater, and it must not
        # inherit an unrelated record's longer life.
        [string]$AttemptId = '',
        [DateTimeOffset]$At = [DateTimeOffset]::Now
    )
    $script:DaemonUpdateVerdict = [pscustomobject]@{
        Stage = $Stage; Detail = $Detail; AttemptId = $AttemptId; At = $At
    }
    # The verdict is part of what is published, so the last signature no longer
    # describes what the entity should say.
    $script:DaemonUpdateSignature = ''
}

function Get-DaemonUpdateProgress {
    <#
        What to publish as the update's stage: the updater's own progress record while
        there is a current one, and otherwise the verdict of an attempt that never got
        far enough to write one.

        Returns stage/detail/proportion with empty values when neither applies, so the
        caller always publishes something and never retains a stale stage.
    #>
    param([DateTimeOffset]$Now = [DateTimeOffset]::Now)

    $blank = [pscustomobject]@{ Stage = ''; Detail = ''; Proportion = $null }
    $verdict = $script:DaemonUpdateVerdict
    if ($verdict -and ($Now - $verdict.At).TotalHours -gt $script:DaemonUpdateProgressHours) {
        # Past the point where even a progress record would still be published, so
        # there is nothing left on the entity for it to describe.
        $script:DaemonUpdateVerdict = $null
        $verdict = $null
    }

    $progress = $null
    try {
        $progress = Read-BridgeUpdateStage -Path $script:BridgeUpdateConfig.ProgressFile `
            -AttemptId ([string]$script:DaemonUpdatePendingAttempt) `
            -NotBefore $Now.AddHours(-$script:DaemonUpdateProgressHours)
    }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        $progress = $null
    }

    # A verdict lives as long as the record it describes, and only then. Once the
    # daemon has restarted there is no attempt id left to bind the reader with, so an
    # hour-old record from a previous attempt is accepted for any attempt - and
    # without this an "Already current" from a press made seconds ago would borrow
    # that record's hour instead of its own ten minutes. Review on #129.
    $paired = $verdict -and $progress -and $verdict.AttemptId -and
        $verdict.AttemptId -ceq [string]$progress.AttemptId
    $live = [bool]($verdict -and ($paired -or ($Now - $verdict.At).TotalMinutes -le $script:DaemonUpdateVerdictMinutes))
    if ($verdict -and -not $live) { $script:DaemonUpdateVerdict = $null }

    if ($progress) {
        # A verdict for the same ending is the better of the two. The child's terminal
        # stage carries whatever it had to hand, which on success is nothing - its
        # detail is the error string - while the verdict is built from the outcome
        # record and names the version reached or the reason it failed. Taking the
        # child's record first turned "Updated to 1.33.9" back into a bare "Updated"
        # on the very next pass, for the rest of the hour. Review on #129.
        #
        # A verdict paired to this very attempt supersedes any stage of it, terminal
        # or not: the outcome record it was built from is proof the attempt ended,
        # and Write-UpdateStage is best effort by construction - a terminal stage it
        # failed to write would otherwise leave the dashboard reporting "Installing"
        # for an hour after the update had finished. Review on #129.
        #
        # An unpaired verdict only outranks a stage that has itself ended, because
        # nothing then ties the two together: a stage still running is the better
        # evidence of what is happening now.
        if ($live -and ($paired -or $progress.Done)) {
            return [pscustomobject]@{ Stage = [string]$verdict.Stage; Detail = [string]$verdict.Detail; Proportion = $null }
        }
        return [pscustomobject]@{
            Stage      = [string]$progress.Stage
            Detail     = [string]$progress.Detail
            Proportion = $progress.Proportion
        }
    }

    # No record at all, so this is an attempt that never started and the verdict is
    # the only thing that will ever say so. Short-lived on purpose: long enough to be
    # read by someone who pressed and looked away, short enough that it is plainly
    # about the press they just made rather than one from an hour ago.
    if (-not $live) { return $blank }
    [pscustomobject]@{ Stage = [string]$verdict.Stage; Detail = [string]$verdict.Detail; Proportion = $null }
}

function Invoke-DaemonMemoryTrim {
    <#
        Hands memory the garbage collector is holding in reserve back to the system.

        The daemon's live objects are about 30 MB, but each reconcile allocates in a
        burst and .NET keeps what it grew to - 150-180 MB more, measured on DASDESK -
        ready for the next one. DOTNET_GCConserveMemory (set by the supervisor) keeps
        that lower; this returns the rest. It is a full, blocking collection of about
        25 ms, so it runs at most every $IntervalSeconds, and only when the reserve is
        worth it. Returns whether it ran.
    #>
    param(
        [int]$IntervalSeconds = 300,
        [long]$MinimumReserveBytes = 48MB,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now,
        # The collector's own figures, from [GC]::GetGCMemoryInfo(); replaced by tests.
        [scriptblock]$Measure = { $info = [GC]::GetGCMemoryInfo(); [pscustomobject]@{ Committed = $info.TotalCommittedBytes; Heap = $info.HeapSizeBytes } }
    )

    if (($Now - $script:DaemonMemoryTrimmedAt).TotalSeconds -lt $IntervalSeconds) { return $false }
    $memory = & $Measure
    if (($memory.Committed - $memory.Heap) -lt $MinimumReserveBytes) { return $false }
    $script:DaemonMemoryTrimmedAt = $Now
    [GC]::Collect(2, [GCCollectionMode]::Aggressive, $true, $true)
    $true
}

function Request-DaemonVersionRestart {
    <#
        Asks for this daemon to end once a different release has been recorded as
        installed, so the supervisor starts one running it. Returns whether it asked.

        The updater stops the daemon itself, but only one it can identify - and a
        daemon it misses goes on running the release it started with for as long as
        it lives. Every decision that daemon made "for the run" then lasts until the
        machine next reboots: a Mac kept its usage reading frozen for four days across
        an update, still on code from before the fix it had just installed (#201).
        The installer writes the version record after it has copied the hooks, so a
        daemon that ends on seeing it starts again on the new ones.

        Ending is the existing restart path (DaemonRestartRequested), taken once the
        pass is over. A record that cannot be read, or reads as nothing, is not a new
        version - an installer rewriting it is no reason to restart mid-install.
    #>
    $installed = ''
    try { $installed = [string](Get-BridgeInstalledVersion -Refresh) }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($installed)) { return $false }
    if (-not $script:DaemonRunningVersion) {
        $script:DaemonRunningVersion = $installed
        return $false
    }
    if ($installed -ceq $script:DaemonRunningVersion) { return $false }
    if (-not $script:DaemonRestartRequested) {
        $script:DaemonRestartRequested = "run $installed, installed while this daemon was running $($script:DaemonRunningVersion)"
    }
    $true
}

function Invoke-DaemonUpdateOutcome {
    <#
        Announces the result of a self-update.

        The updater has no Home Assistant publishing client loaded. It drops an outcome
        file instead, and whichever daemon runs next turns that into a visible
        notification and the currently recorded installed version. Reading it every
        reconcile - not only at startup - means the announcement fires whether a
        successful update's restart request replaced the daemon or it kept running
        through a failed one.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    $path = $script:DaemonConfig.UpdateOutcomeFile
    $claimed = "$path.$([guid]::NewGuid().ToString('N')).reading"
    if (Test-BridgeTestExecution) { Assert-BridgeTestPath -Path @($path, $claimed) }
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    # Claim atomically, rather than deleting a replacement notice written between
    # read and remove. The foreground parent's per-attempt proof is a different file.
    Assert-BridgeInstallPayload -Root $path -CheckAncestors
    $ownsClaim = $false
    try {
        try {
            [IO.File]::Move($path, $claimed)
            $ownsClaim = $true
        }
        catch [IO.FileNotFoundException] { return $false }
        $outcome = Read-BridgeUpdateOutcome -Path $claimed
        if (([DateTimeOffset]::Now - $outcome.At).TotalHours -gt 6) { return $false }
        if ($script:DaemonUpdatePendingAttempt -eq $outcome.AttemptId) { $script:DaemonUpdatePendingAttempt = '' }
        $installed = Get-BridgeInstalledVersion -Refresh
        # An installer that got as far as recording this release did install it, and
        # `agent-ha-bridge status` straight afterwards reports the new version with
        # every check green. Saying "update failed" of that is what made a successful
        # update look like the thing to retry (#124); the step that failed is still
        # named, and nothing here claims the install is healthy.
        #
        # Judged against what *this* attempt found recorded when it launched, where the
        # outcome says so. Nothing rejects a second press while a child is running, and
        # an unexplained failure is precisely what invites a second press - so two
        # children can target the same release, and the shared installed-version record
        # would otherwise credit the one that failed during download with the other's
        # install. An outcome written before the field existed carries no pre-version;
        # omitting -Before leaves that case behaving as it did. Raised by Codex on #190.
        $reachedArgs = @{ Attempted = [string]$outcome.Version; Recorded = $installed }
        if ($outcome.PSObject.Properties['BeforeVersion'] -and $outcome.BeforeVersion) {
            $reachedArgs['Before'] = [string]$outcome.BeforeVersion
        }
        if ($outcome.PSObject.Properties['RanInstaller'] -and $null -ne $outcome.RanInstaller) {
            $reachedArgs['RanInstaller'] = [bool]$outcome.RanInstaller
        }
        $reachedInstall = -not $outcome.Success -and (Test-BridgeUpdateReachedInstall @reachedArgs)
        # The same verdict the notification carries, on the entity, so the dashboard
        # says how the update ended rather than only that it is no longer running.
        # Worked out before publishing because the publish is what shows it.
        $verdictStage = if ($outcome.Success) { 'completed' } else { 'failed' }
        $verdictDetail = if ($outcome.Success) {
            if ($outcome.Version) { "Updated to $($outcome.Version)" } else { 'Updated' }
        }
        elseif ($reachedInstall) { "Installed $($outcome.Version), but a step after it failed: $($outcome.Error)" }
        else { [string]$outcome.Error }
        Set-DaemonUpdateVerdict -Stage $verdictStage -Detail $verdictDetail -AttemptId ([string]$outcome.AttemptId)
        Publish-CopilotMqttUpdate -InstalledVersion $installed -LatestVersion $outcome.Version `
            -ReleaseUrl $outcome.ReleaseUrl -InProgress:([bool]$script:DaemonUpdatePendingAttempt) `
            -Stage $verdictStage -StageDetail $verdictDetail -Headers $Headers
        [void](Set-CopilotMqttUpdateEntityIds)
        $script:DaemonUpdateAvailable = (ConvertTo-BridgeVersion $outcome.Version) -gt (ConvertTo-BridgeVersion $installed)
        $script:DaemonUpdatePublished = $true
        $script:DaemonUpdateSignature = ''
        if ($outcome.Success) {
            # Matches the updater's own wording, and for the same reason: the child
            # stops the daemon so the supervisor relaunches it, and nothing looks at
            # the install after that. "asked to restart" because Stop-BridgeOwnedRuntime
            # stops a process or finds none - it never starts or waits for the
            # replacement, so a restart is requested, not observed. Review on #152.
            $message = "The bridge updated to **$($outcome.Version)**; currently recorded version: **$installed**. The daemon was asked to restart, so nothing has checked the install since."
            if ($outcome.ReleaseUrl) { $message += " [Release notes]($($outcome.ReleaseUrl))" }
            Invoke-HomeAssistantService -Domain 'persistent_notification' -Service 'create' `
                -Data @{ title = "Bridge installer completed on $($script:DaemonMachineName)"; message = $message; notification_id = "agent_bridge_update_$($script:DaemonMachineSlug)" } `
                -Headers $Headers
            Write-DaemonLog -Message "self-update installer completed for $($outcome.Version); recorded version $installed"
        }
        else {
            $attempt = if ($outcome.Version) { "to $($outcome.Version)" } else { '(target not recorded)' }
            Invoke-HomeAssistantService -Domain 'persistent_notification' -Service 'create' `
                -Data @{
                    title = if ($reachedInstall) { "Bridge updated on $($script:DaemonMachineName), but a later step failed" }
                            else { "Bridge update failed on $($script:DaemonMachineName)" }
                    message = if ($reachedInstall) {
                        "The bridge installed **$($outcome.Version)** and records it, but a step after the install did not finish: $($outcome.Error). Run ``agent-ha-bridge status`` to see what is affected."
                    }
                    else {
                        "The bridge update $attempt did not complete: $($outcome.Error). Currently recorded version: $installed. The installation may be partially changed; no rollback is claimed."
                    }
                    notification_id = "agent_bridge_update_$($script:DaemonMachineSlug)"
                } `
                -Headers $Headers
            Write-DaemonLog -Message $(if ($reachedInstall) {
                "self-update installed $($outcome.Version) but a later step FAILED: $($outcome.Error); recorded version $installed"
            } else { "self-update FAILED for $($outcome.Version): $($outcome.Error); recorded version $installed" })
        }
        return $true
    }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        Write-DaemonLog -Message "update outcome could not be verified or announced: $($_.Exception.Message)"
        $script:DaemonUpdateSignature = ''
        try {
            Publish-CopilotMqttUpdate -InstalledVersion (Get-BridgeInstalledVersion -Refresh) -LatestVersion $null -Headers $Headers
        }
        catch {
            if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
            Write-DaemonLog -Message "could not publish unknown update result: $($_.Exception.Message)"
        }
        return $true
    }
    finally {
        if ($ownsClaim) {
            if (Test-BridgeTestExecution) { Assert-BridgeTestPath -Path $claimed }
            if (Test-Path -LiteralPath $claimed) { Remove-Item -LiteralPath $claimed -Force -ErrorAction Stop }
        }
    }
}

function Confirm-DaemonUpdateEntityIds {
    <#
        Keeps asking Home Assistant to put this machine's update entities on their
        deterministic ids until the check button is actually seen on one.

        Set-CopilotMqttUpdateEntityIds runs inside the publish, and the publish only
        happens when the status signature changes. A Home Assistant that had not yet
        processed the discovery message when the registry was listed has nothing to
        rename, the setter skips it silently, and on a stable install - no new release,
        no stage, nothing moving - the signature never changes again. The button then
        keeps the id Home Assistant built from the device and entity names, while the
        daemon reads and the card presses the one the bridge chose. Both ends correct,
        pointing at different entities, with nothing anywhere saying so. Raised by
        Codex on #224.

        Observation comes from the reconcile snapshot, which already holds every
        agent_bridge_* entity, so confirming costs nothing. Only a confirmed absence
        asks for the rename again, and no more than once a minute, so an entity that
        never appears cannot turn this into a registry walk every fifteen seconds.
    #>
    param([DateTimeOffset]$Now = [DateTimeOffset]::Now)

    if ($script:DaemonUpdateEntityIdsPinned) { return $true }
    # No snapshot is no evidence either way - the startup pass has none - and acting
    # on that would re-pin on every daemon start regardless of whether it was needed.
    if ($null -eq $script:DaemonReconcileStates) { return $false }
    if ($script:DaemonReconcileStates.ContainsKey($script:DaemonEntity.CheckUpdates)) {
        $script:DaemonUpdateEntityIdsPinned = $true
        return $true
    }
    if (($Now - $script:DaemonUpdateEntityIdsPinnedAt).TotalSeconds -lt 60) { return $false }
    $script:DaemonUpdateEntityIdsPinnedAt = $Now
    try { [void](Set-CopilotMqttUpdateEntityIds) }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        Write-DaemonLog -Message "update entity ids could not be pinned: $($_.Exception.Message)"
    }
    $false
}

function Test-DaemonUpdateCheckPress {
    <#
        Whether the Check button has been pressed since this daemon last looked.

        The same press-timestamp mechanism as Install and Submit, and kept separate
        from Install's for the same reason the buttons are separate: Install acts on
        what the last check found, so a press of Check that Install's handler had
        already consumed would be a press that did nothing visible at all.

        A press from before this daemon started is a retained value from an earlier
        run, not an instruction - compared against the start time rather than simply
        ignoring the first value seen, so a press made moments after a restart still
        counts.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    try {
        $button = Get-DaemonEntityState -EntityId $script:DaemonEntity.CheckUpdates -Headers $Headers
        $press = [string]$button.state
        if ($press -in @('unknown', 'unavailable', '')) { return $false }
        if ($press -eq $script:DaemonUpdateCheckLastPress) { return $false }
        $script:DaemonUpdateCheckLastPress = $press

        $pressedAt = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($press, [ref]$pressedAt)) { return $false }
        if ($pressedAt -le $script:DaemonStartedAt) { return $false }

        Write-DaemonLog -Message 'update check requested from Home Assistant'
        return $true
    }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        # The button may not exist yet on a first run. Never a reason to skip the
        # ordinary check that follows.
        Write-DaemonLog -Message "update check button not read: $($_.Exception.Message)"
        return $false
    }
}

function Get-DaemonPeerLatestVersion {
    <#
        The highest release any other machine's update entity is currently reporting,
        or '' when the snapshot holds none.

        Machines publish what they find to retained entities, so one that has already
        seen a new release is saying so where every other machine can read it - the
        same trick Sync-DaemonUsage uses to tell whether another machine is already
        reading the same account (#142). No writer, no authority, no election: it is a
        hint that something has changed, and the only thing this machine does with it
        is go and look for itself.

        Deliberately not adopted as this machine's answer. A peer's version decides
        nothing about what gets installed here - Invoke-BridgeSelfUpdate re-checks
        under -Force before it downloads anything - and a machine reporting a version
        this one cannot verify is a machine to be curious about, not to obey.
    #>

    if ($null -eq $script:DaemonReconcileStates) { return '' }
    $mine = $script:DaemonEntity.Update
    $highest = ''
    foreach ($id in $script:DaemonReconcileStates.Keys) {
        if ($id -eq $mine -or $id -notlike 'update.agent_bridge_*') { continue }
        $entry = $script:DaemonReconcileStates[$id]
        if ($null -eq $entry -or -not $entry.PSObject.Properties['attributes'] -or $null -eq $entry.attributes) { continue }
        if (-not $entry.attributes.PSObject.Properties['latest_version']) { continue }
        $version = [string]$entry.attributes.latest_version
        if ([string]::IsNullOrWhiteSpace($version)) { continue }
        if ([string]::IsNullOrWhiteSpace($highest) -or
            (ConvertTo-BridgeVersion $version) -gt (ConvertTo-BridgeVersion $highest)) {
            $highest = $version
        }
    }
    $highest
}

function Test-DaemonPeerUpdateNotice {
    <#
        Whether a peer is reporting a release this machine has not established yet,
        and this machine has not already looked because of it.

        Looking is cheap - the routine check is a redirect that spends no API
        allowance - but it is not free, and the daemon reconciles every fifteen
        seconds. Remembering which peer version prompted the last look is what keeps
        a peer that is permanently ahead (or simply wrong) from turning that into a
        four-per-minute poll.
    #>

    $peer = Get-DaemonPeerLatestVersion
    if ([string]::IsNullOrWhiteSpace($peer)) { return $false }
    $script:DaemonPeerLatestVersion = $peer
    if ($peer -eq $script:DaemonPeerLatestChecked) { return $false }

    $installed = Get-BridgeInstalledVersion
    $known = Get-BridgeKnownReleaseTag
    if ([string]::IsNullOrWhiteSpace($known)) { $known = $installed }
    if ((ConvertTo-BridgeVersion $peer) -le (ConvertTo-BridgeVersion $known)) { return $false }

    $script:DaemonPeerLatestChecked = $peer
    Write-DaemonLog -Message "another machine reports $peer; checking for a release rather than waiting for the interval"
    $true
}

function Sync-DaemonUpdateStatus {
    <#
        Publishes the bridge's own update status, and acts on a press of the install
        button.

        Both halves are deliberately forgiving: an update check that fails, or a
        GitHub outage, must never disturb a running session. The check itself is
        cached for its configured interval inside Get-BridgeLatestRelease, with a
        shorter retry window when the lookup is unavailable.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    # A pending self-update result is announced regardless of the update-check opt-out:
    # it is the response to the user pressing install, not a background poll.
    $outcomeHandled = Invoke-DaemonUpdateOutcome -Headers $Headers

    # Opting out has to stop the network call, not just hide the result, so this is
    # checked before anything else happens.
    if (-not (Get-BridgeSetting 'updates.checkForUpdates' $true)) { return }

    # Independent of the publish below, which only runs when something changed: a
    # freshly discovered entity that Home Assistant had not registered yet would
    # otherwise keep the id Home Assistant chose for it, for good.
    [void](Confirm-DaemonUpdateEntityIds)

    # Two things mean "look now" rather than "look at the usual time": somebody
    # pressed Check - on this machine's card or, fanned out, on every machine's at
    # once - and another machine reporting a release this one has not established.
    #
    # Both are read before the lookup so that a single press produces a single forced
    # check, and both are evaluated unconditionally: || would skip the peer read on a
    # press and leave the notice to fire again on the following pass.
    $pressed = Test-DaemonUpdateCheckPress -Headers $Headers
    $peerNotice = Test-DaemonPeerUpdateNotice
    $force = $pressed -or $peerNotice

    # What the check found, or what is still true without it. A failed check used to
    # `return` here, which had two consequences that cost an extended debugging
    # session each: the update entity was never published, so it went unavailable with
    # no installed_version and the machine read as dead on the dashboard (#109); and
    # the install-button handling below was never reached, so a press made from Home
    # Assistant was silently discarded and pressing again only burned more of the same
    # rate-limit budget (#92).
    #
    # The installed version is local and is known whatever GitHub says, so there is
    # always something honest to publish.
    $status = $null
    $checkFailure = ''
    try { $status = Get-BridgeUpdateStatus -Force:$force }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        $checkFailure = [string]$_.Exception.Message
        Write-DaemonLog -Message "update check failed: $checkFailure"
    }
    if ($null -eq $status) {
        $status = [pscustomobject]@{
            Installed = (Get-BridgeInstalledVersion -Refresh)
            Latest = $null
            Available = $false
            LookupState = 'Unavailable'
            State = 'Unavailable'
            Detail = if ($checkFailure) { "The latest release could not be established: $checkFailure" }
                     else { 'The latest release could not be established.' }
            Url = "https://github.com/$(Get-BridgeUpdateRepository)/releases"
            Notes = ''
            Zip = ''
        }
    }

    # A press has to answer for itself. Where the check changed something, the publish
    # below says so on its own - but "you are already current" is a result with no
    # state change behind it, and republishing an identical retained payload is not a
    # change Home Assistant shows. Without this, pressing Check on a machine that is
    # up to date is indistinguishable from a button wired to nothing.
    #
    # The verdict mechanism the install button already uses carries it, and clears the
    # signature so the answer is republished either way. Deliberately not 'failed'
    # when the check could not reach GitHub: a refused check is not a failed update,
    # which is the conflation #92 and #124 were both about. That case republishes with
    # the explanation already carried in the notes.
    if ($pressed -and -not $script:DaemonUpdatePendingAttempt) {
        if ($status.State -eq 'Current') {
            Set-DaemonUpdateVerdict -Stage 'current' `
                -Detail "Checked just now; $($status.Installed) is the latest release."
        }
        else { $script:DaemonUpdateSignature = '' }
    }

    # Computed once, before anything can throw, because the press handler below
    # publishes the same two values on its spinner. It used to pass $status.Notes
    # there, which is empty whenever the check failed - so the explanation shown a
    # moment earlier was wiped by the spinner that followed it.
    $latest = $status.Latest
    $notes = if ($status.State -in @('Unavailable', 'NotFound', 'RateLimited')) { $status.Detail } else { $status.Notes }

    try {
        # Read every pass, because the stage changes while nothing else about the
        # update does - and because the daemon restarting mid-update is one of the
        # stages, so this may be the first pass of a daemon that has never seen the
        # attempt start.
        $progress = Get-DaemonUpdateProgress
        $stage = [string]$progress.Stage
        $proportion = $progress.Proportion
        $stageDetail = [string]$progress.Detail
        $signature = @($status.State, $status.Installed, $latest, $status.Url, $notes, $stage, $proportion, $stageDetail) | ConvertTo-Json -Compress
        if (-not $outcomeHandled -and ($signature -cne $script:DaemonUpdateSignature -or -not $script:DaemonUpdatePublished)) {
            Publish-CopilotMqttUpdate -InstalledVersion $status.Installed -LatestVersion $latest `
                -ReleaseUrl $status.Url -ReleaseNotes $notes -InProgress:([bool]$script:DaemonUpdatePendingAttempt) `
                -Stage $stage -Proportion $proportion -StageDetail $stageDetail -Headers $Headers
            [void](Set-CopilotMqttUpdateEntityIds)
            $script:DaemonUpdateSignature = $signature
            $script:DaemonUpdatePublished = $true
            if ($status.Available -ne $script:DaemonUpdateAvailable) {
                $script:DaemonUpdateAvailable = $status.Available
                if ($status.Available) {
                    Write-DaemonLog -Message "update available: $($status.Installed) -> $($status.Latest)"
                }
            }
            if ($status.State -in @('Unavailable', 'NotFound', 'RateLimited')) { Write-DaemonLog -Message $status.Detail }
        }
    }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        # Publishing failed, which says nothing about whether a press is waiting. Going
        # on to read the button is the whole point of not returning here.
        Write-DaemonLog -Message "update status publish failed: $($_.Exception.Message)"
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
        #
        # `checking` rather than a bare spinner: the press has to answer for itself
        # immediately, and checking the release is genuinely what happens next. Any
        # stale verdict goes with it - the press being answered is this one.
        $script:DaemonUpdateVerdict = $null
        try {
            Publish-CopilotMqttUpdate -InstalledVersion $status.Installed -LatestVersion $latest `
                -ReleaseUrl $status.Url -ReleaseNotes $notes -InProgress -Stage 'checking' -Headers $Headers
        }
        catch {
            if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
            Write-DaemonLog -Message "could not show update spinner: $($_.Exception.Message)"
        }

        # Its own try: an update that cannot even be started has to clear the spinner
        # itself. The failure notice further up is driven by the outcome file the
        # updater writes, and a launch that never happened never writes one - so this
        # used to leave the card saying "Installing" until the next self-update, with
        # nothing in the log to say why.
        $result = $null
        try {
            $result = Invoke-BridgeSelfUpdate -Detached
        }
        catch {
            if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
            $result = [pscustomobject]@{ Started = $false; Detail = $_.Exception.Message }
        }
        Write-DaemonLog -Message "self-update: $($result.Detail)"
        if ($result.Started) {
            $script:DaemonUpdatePendingAttempt = $result.AttemptId
        }
        else {
            try {
                $current = $result.PSObject.Properties['State'] -and $result.State -eq 'Current'
                $knownTarget = if ($result.PSObject.Properties['AttemptedVersion']) { $result.AttemptedVersion } else { $null }
                # Nothing started, so nothing will write a progress record - and the
                # one the last attempt left would go on being published as though it
                # described this press. Removing it is what makes the verdict below
                # the only thing speaking for the press just made. Review on #129.
                Remove-BridgeUpdateProgress
                # A release that is already installed is not a failure. Conflating the
                # two is what #92 was: a press that found nothing to do looked exactly
                # like a press that broke.
                Set-DaemonUpdateVerdict -Stage $(if ($current) { 'current' } else { 'failed' }) -Detail ([string]$result.Detail)
                Publish-CopilotMqttUpdate -InstalledVersion (Get-BridgeInstalledVersion -Refresh) -LatestVersion $knownTarget `
                    -Stage $script:DaemonUpdateVerdict.Stage -StageDetail $script:DaemonUpdateVerdict.Detail -Headers $Headers
                $script:DaemonUpdateSignature = ''
                Invoke-HomeAssistantService -Domain 'persistent_notification' -Service 'create' `
                    -Data @{
                        title = if ($current) { "No newer bridge release on $($script:DaemonMachineName)" } else { "Bridge update failed on $($script:DaemonMachineName)" }
                        message         = "The bridge update did not start: $($result.Detail)"
                        notification_id = "agent_bridge_update_$($script:DaemonMachineSlug)"
                    } -Headers $Headers
            }
            catch {
                if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
                Write-DaemonLog -Message "could not clear the update spinner: $($_.Exception.Message)"
            }
        }
    }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        # The button may not exist yet on a first run - but say so rather than losing
        # a real failure, which is how a stuck "Installing" went unexplained.
        Write-DaemonLog -Message "update install check skipped: $($_.Exception.Message)"
    }
}

function Get-DaemonClientAdapterInstalled {
    <# Whether a client's bridge adapter is in place, from the files its installer leaves. #>
    param([Parameter(Mandatory)][ValidateScript({ $null -ne (Get-DaemonAgent -Kind $_).AdapterInstalled })][string]$Client)

    [bool](& (Get-DaemonAgent -Kind $Client).AdapterInstalled)
}

function Get-DaemonClientInstaller {
    <#
        How to install a client's adapter: the installer shipped with the bridge, and
        its arguments - the agent's own (Copilot's, see daemon-agents.ps1), or its
        folder's install-<client>.ps1.
    #>
    param([Parameter(Mandatory)][string]$Client)

    # $script:DaemonInstallerPayload lets a test point this at a fake payload.
    $context = Get-BridgeInstallContext
    $payload = if ($script:DaemonInstallerPayload) { $script:DaemonInstallerPayload } else { Join-Path $context.BridgeHome 'installer' }
    $own = (Get-DaemonAgent -Kind $Client).Installer
    $installer = if ($own) { & $own $payload }
        else { [pscustomobject]@{ Path = Join-Path $payload "$Client\install-$Client.ps1"; Arguments = '' } }
    $installer
}

function Add-DaemonConfiguredClient {
    <#
        Adds a client to `clients` in the bridge config, so later installs and updates
        keep its adapter current. The file is re-read rather than rewritten from memory,
        so nothing changed on disk since the daemon started is lost.
    #>
    param([Parameter(Mandatory)][string]$Client)

    $path = (Get-BridgeInstallContext).ConfigPath
    if (-not (Test-Path -LiteralPath $path)) { return }
    $config = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $clients = @()
    if ($config.PSObject.Properties['clients']) { $clients = @($config.clients | ForEach-Object { [string]$_ }) }
    if ($clients -contains $Client) { return }
    if ($config.PSObject.Properties['clients']) {
        throw "The $Client client is not selected; maintenance cannot enroll it."
    }
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

    # Every agent with an adapter the daemon can set up (see daemon-agents.ps1).
    $selected = Get-BridgeSelectedClients
    if ($null -ne $selected) {
        foreach ($client in @($script:DaemonClientSetup.Keys)) {
            if ($selected -contains $client) { continue }
            $job = $script:DaemonClientSetup[$client]
            if ($job -and -not $job.Done -and $job.Process -and -not $job.Process.HasExited) {
                Stop-BridgeOwnedRuntime -Context (Get-BridgeInstallContext) -Roles "setup-$client"
            }
            [void]$script:DaemonClientSetup.Remove($client)
        }
    }
    $clients = @($script:DaemonAgents.Keys | Where-Object {
        $null -ne (Get-DaemonAgent -Kind $_).AdapterInstalled -and
        ($null -eq $selected -or $selected -contains $_)
    })
    foreach ($client in $clients) {
        $job = $script:DaemonClientSetup[$client]

        if ($null -ne $job) {
            if ($job.Done -or -not $job.Process.HasExited) { continue }
            $job.Done = $true
            $label = Get-BridgeLauncherLabel -Launcher $client
            if ($job.Process.ExitCode -eq 0 -and (Get-DaemonClientAdapterInstalled -Client $client)) {
                try { Add-DaemonConfiguredClient -Client $client } catch { Write-DaemonLog -Message "could not record $client in the config: $($_.Exception.Message)" }
                Write-DaemonLog -Message "set up the $label adapter (log: $($job.Log)); restarting to load it"
                $note = "$label found and set up for the dashboard."
                $setupNote = (Get-DaemonAgent -Kind $client).SetupNote
                $note += if ($setupNote) { & $setupNote } else { ' Restart any running sessions so they pick it up.' }
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

        $installer = Get-DaemonClientInstaller -Client $client
        if (-not (Test-Path -LiteralPath $installer.Path)) { continue }
        $context = Get-BridgeInstallContext
        $target = "-InstallRoot `"$($context.BridgeHome)`""
        if ($context.Isolated) { $target += " -TargetHome `"$($context.Home)`"" }
        $target += ' -RepairOnly'

        $log = Get-BridgeRuntimePath "agent-bridge-setup-$client.log"
        [void][IO.Directory]::CreateDirectory((Split-Path $log -Parent))
        try {
            $setup = @{
                FilePath               = 'pwsh'
                ArgumentList           = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$($installer.Path)`" $target $($installer.Arguments)".TrimEnd()
                PassThru               = $true
                RedirectStandardOutput = $log
                RedirectStandardError  = "$log.err"
                ErrorAction            = 'Stop'
            }
            # Not supported, and refused, off Windows.
            if ($script:BridgeIsWindows) { $setup.WindowStyle = 'Hidden' }
            $process = Start-Process @setup
            $script:DaemonClientSetup[$client] = [pscustomobject]@{ Process = $process; Log = $log; Done = $false }
            Write-DaemonLog -Message "$(Get-BridgeLauncherLabel -Launcher $client) is installed but has no bridge adapter; setting it up (pid $($process.Id))"
        }
        catch {
            $script:DaemonClientSetup[$client] = [pscustomobject]@{ Process = $null; Log = $log; Done = $true }
            Write-DaemonLog -Message "could not start the $client adapter installer: $($_.Exception.Message)"
        }
    }
}
