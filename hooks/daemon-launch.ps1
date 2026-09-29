<#
    Bridge daemon: starting and ending sessions.

    The launch card: its controls, a press, the launch or resume, following it up
    (trust question, first message), its notes - and End session.

    Part of agent-bridge-daemon.ps1, which dot-sources it into its own scope after
    declaring the shared $script: state; see docs/daemon-split.md.
    Shared state it changes: DaemonDefaultAgent, DaemonLaunchedTuning,
    DaemonNewSessionLastPress, DaemonNewSessionPublished, DaemonNewSessionSignature,
    DaemonPendingLaunch, DaemonReconcileNow, DaemonResumeCache, DaemonResumeCacheAt.
#>

function Invoke-PendingStops {
    <#
        Ends any session whose End button has been pressed.

        Uses the same press-timestamp contract as the Submit and Launch buttons: a
        press from before this daemon started is a retained value from an earlier
        run, and a press already acted on is recorded per session so one press can
        never end two sessions or the same session twice.

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
        Write-DaemonLog -Message "end requested for $short (pid $processId)"

        # Say so on the card straight away: the status reads "ending" while the
        # session closes, instead of carrying on as "working" or "idle" until it has
        # gone.
        # Separately guarded, so a failed status publish cannot also cost the card its
        # "Ending session..." line.
        try {
            Set-CopilotMqttStatus -SessionId $sessionId -Status 'ending' -Headers $Headers -Attributes (
                Add-DaemonTuningAttributes -Attributes @{
                    session    = $entry.Name
                    machine    = $entry.Machine
                    process_id = $processId
                    updated    = [DateTimeOffset]::Now.ToString('o')
                } -Tuning $entry)
            $entry.Status = 'ending'
        }
        catch { }
        try {
            Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Ending session...' `
                -Headers $Headers
        }
        catch { }

        $stop = Stop-BridgeCopilotSession -SessionId $sessionId -ProcessId $processId
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

    @(@($script:DaemonResumeCache) | Where-Object { -not $live.ContainsKey([string]$_.SessionId) })
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
    # agent at launch time even when it is not the default.
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
        Resumable  = @(Get-DaemonResumableSessions -LiveSessionIds @($Live.Keys))
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
    # first configured profile, and an unrecognised one is refused outright rather
    # than passed to a command line.
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
            Write-DaemonLog -Message "new session requested with unknown profile '$profileLabel'"
            Set-CopilotMqttNewSessionResult -Text "Unknown profile '$profileLabel'" -Headers $Headers | Out-Null
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

    if ($null -ne $resumeSession) {
        $resumeDirectory = [string]$resumeSession.Folder
        if ([string]::IsNullOrWhiteSpace($resumeDirectory) -or -not [System.IO.Directory]::Exists($resumeDirectory)) {
            # The folder it ran in has gone. Falling back to the selected workspace
            # keeps the resume possible rather than failing outright.
            $resumeDirectory = $directory
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
        $choice = Get-BridgeWorkspaceChoice -Label $label
        if ($null -ne $choice -and $choice.PSObject.Properties['Isolate'] -and $choice.Isolate) {
            $worktree = [pscustomobject]@{ Path = $directory; Isolated = $false; Detail = '' }
            try { $worktree = New-BridgeSessionWorktree -RepositoryPath $directory }
            catch { $worktree.Detail = "worktree creation threw: $($_.Exception.Message)" }
            if ($worktree.Isolated) { $launchDirectory = $worktree.Path }
            if ($worktree.Detail) {
                Write-DaemonLog -Message "$(if ($worktree.Isolated) { 'worktree' } else { 'no worktree' }): $($worktree.Detail)"
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
        Set-CopilotMqttNewSessionResult -Text "Launch failed: $($launch.Detail)" -Headers $Headers | Out-Null
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
