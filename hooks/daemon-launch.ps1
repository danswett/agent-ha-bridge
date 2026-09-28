<#
    Bridge daemon: starting and ending sessions.

    The launch card: its controls, a press, the launch or resume, following it up
    (trust question, first message), its notes - and End session.

    Part of agent-bridge-daemon.ps1, which dot-sources it into its own scope after
    declaring the shared $script: state; see docs/daemon-split.md.
    Shared state it changes: DaemonDefaultAgent, DaemonNewSessionLastPress,
    DaemonNewSessionPublished, DaemonNewSessionSignature, DaemonPendingLaunch,
    DaemonReconcileNow, DaemonResumeCache, DaemonResumeCacheAt.
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
            $button = Get-HomeAssistantState -EntityId "button.${node}_stop" -Headers $Headers
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
            Set-CopilotMqttStatus -SessionId $sessionId -Status 'ending' -Headers $Headers -Attributes @{
                session    = $entry.Name
                machine    = $entry.Machine
                process_id = $processId
                updated    = [DateTimeOffset]::Now.ToString('o')
            }
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
            if ($launcherPid -gt 0 -and $launcherPid -ne $processId) {
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
        [AllowEmptyCollection()][string[]]$Agents = @()
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

    $controls = Get-DaemonNewSessionControls -Live $Live
    if (-not (Publish-DaemonNewSessionControls -Controls $controls -Headers $Headers)) { return }
    Set-DaemonNewSessionDefaults -Headers $Headers -Workspaces $controls.Workspaces -Profiles $controls.Profiles `
        -Resumable $controls.Resumable -Agents $controls.Agents

    if (-not (Test-DaemonNewSessionPressed -Headers $Headers)) { return }
    if (Confirm-DaemonPendingTrust -Headers $Headers) { return }
    if (Send-DaemonPendingFirstMessage -Headers $Headers) { return }

    $request = Resolve-DaemonLaunchRequest -Controls $controls -Headers $Headers
    if ($null -eq $request) { return }
    Start-DaemonLaunch -Request $request -Headers $Headers
}

function Get-DaemonNewSessionControls {
    <# What the launch card offers now: workspaces, agents, profiles, resumable sessions. #>
    param([Parameter(Mandatory)][hashtable]$Live)

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

    [pscustomobject]@{
        Workspaces = $workspaces
        Launcher   = $launcher
        Launchers  = $launchers
        Agents     = $agents
        Profiles   = $profiles
        Resumable  = @(Get-DaemonResumableSessions -LiveSessionIds @($Live.Keys))
    }
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
    $signature = (($workspaces | ForEach-Object { "$($_.Label)=$($_.Path)" }) -join '|') +
        "#$launcher#" + ($agents -join ',') + '#' + ($profiles -join ',') +
        '#' + (($resumable | ForEach-Object { [string]$_.SessionId }) -join ',')
    if (-not $script:DaemonNewSessionPublished -or $signature -ne $script:DaemonNewSessionSignature) {
        try {
            Publish-CopilotMqttNewSession -Workspaces $workspaces -Profiles $profiles `
                -Resumable $resumable -Agents $agents -Headers $Headers | Out-Null
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
    $pressedAt -gt $script:DaemonStartedAt
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
    try { $first = [string](Get-HomeAssistantState -EntityId $script:DaemonEntity.NewPrompt -Headers $Headers).state } catch { }
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
    try {
        Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers -Data @{
            entity_id = $script:DaemonEntity.NewPrompt; value = $script:DaemonConfig.ReplyBlankValue
        } | Out-Null
    }
    catch { }
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
    try {
        $promptState = Get-HomeAssistantState -EntityId $script:DaemonEntity.NewPrompt -Headers $Headers
        $prompt = [string]$promptState.state
    }
    catch { }
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

    [pscustomobject]@{
        Launcher      = $chosenLauncher
        Directory     = $directory
        Label         = $label
        Prompt        = $prompt
        AgencyProfile = $agencyProfile
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

    if ($null -ne $resumeSession) {
        $resumeDirectory = [string]$resumeSession.Folder
        if ([string]::IsNullOrWhiteSpace($resumeDirectory) -or -not [System.IO.Directory]::Exists($resumeDirectory)) {
            # The folder it ran in has gone. Falling back to the selected workspace
            # keeps the resume possible rather than failing outright.
            $resumeDirectory = $directory
        }

        $short = $resumeSession.SessionId.Substring(0, [Math]::Min(8, $resumeSession.SessionId.Length))
        Write-DaemonLog -Message "resume requested for $short ($resumeDirectory)$(if ($agencyProfile) { " profile '$agencyProfile'" })"
        Set-CopilotMqttNewSessionResult -Text "Resuming $resumeLabel..." -Headers $Headers | Out-Null

        $launchedAt = [DateTimeOffset]::Now
        $launch = Start-BridgeCopilotSession -WorkingDirectory $resumeDirectory -Prompt $prompt `
            -AgencyProfile $agencyProfile -SessionId ([string]$resumeSession.SessionId) -Launcher $chosenLauncher -Resume
    }
    else {
        $agentName = Get-BridgeLauncherLabel -Launcher $chosenLauncher
        Write-DaemonLog -Message "new $agentName session requested in '$label' ($directory)$(if ($agencyProfile) { " profile '$agencyProfile'" })$(if ($prompt) { " with prompt: $prompt" })"
        Set-CopilotMqttNewSessionResult -Headers $Headers `
            -Text "Starting $agentName in $label$(if ($agencyProfile) { " ($agencyProfile)" })..." | Out-Null

        $launchedAt = [DateTimeOffset]::Now
        $launch = Start-BridgeCopilotSession -WorkingDirectory $directory -Prompt $prompt `
            -AgencyProfile $agencyProfile -Launcher $chosenLauncher
    }

    if (-not $launch.Launched) {
        Write-DaemonLog -Message "new session launch failed: $($launch.Detail)"
        Set-CopilotMqttNewSessionResult -Text "Launch failed: $($launch.Detail)" -Headers $Headers | Out-Null
        return
    }

    Write-DaemonLog -Message "new session launched: $($launch.Detail) (session $(if ($launch.SessionId) { $launch.SessionId } else { 'id chosen by the agent' }))"

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
        TrustConfirmed = $false
        TrustAnswers   = 0
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
    # silently reusing the previous prompt.
    if ($prompt) {
        try {
            Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers -Data @{
                entity_id = $script:DaemonEntity.NewPrompt
                value     = $script:DaemonConfig.ReplyBlankValue
            } | Out-Null
        }
        catch {
            Write-DaemonLog -Message "could not clear the new-session prompt: $($_.Exception.Message)"
        }
    }
}

function Test-DaemonLaunchProgressNote {
    <# Whether a launch note is about a launch still being followed, not an outcome. #>
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $t = ([string]$Text).Trim()
    if (-not $t) { return $false }
    # "<Agent> is open in ..." and "<Agent> is asking whether to trust ...", for any agent
    # (see Update-DaemonPendingLaunch); "is still asking" is an outcome, and not matched.
    $t.EndsWith('...') -or $t -like '* is open in *. It appears here after*' -or $t -like '* is asking whether to trust *'
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

    if (($now - $p.Since).TotalSeconds -gt 90) {
        & $finish "$agent started in $($p.Label) (pid $($p.ProcessId)) but has not registered - check its window." `
            "launched $agent (pid $($p.ProcessId)) did not register within 90 s"
    }
}
