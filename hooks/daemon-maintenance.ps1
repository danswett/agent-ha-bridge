<#
    Bridge daemon: keeping the install current.

    Update checks and their outcome on the dashboard, setting up agents installed
    after the bridge, and handing unused memory back.

    Part of agent-bridge-daemon.ps1, which dot-sources it into its own scope after
    declaring the shared $script: state; see docs/daemon-split.md.
    Shared state it changes: DaemonClientSetup, DaemonRestartRequested,
    DaemonUpdateAvailable, DaemonUpdateLastPress, DaemonUpdatePublished,
    DaemonMemoryTrimmedAt.
#>

$script:DaemonMemoryTrimmedAt = [DateTimeOffset]::MinValue
$script:DaemonUpdateSignature = ''
$script:DaemonUpdatePendingAttempt = ''

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

function Invoke-DaemonUpdateOutcome {
    <#
        Announces the result of a self-update.

        The updater has no Home Assistant publishing client loaded. It drops an outcome
        file instead, and whichever daemon runs next turns that into a visible
        notification and the currently recorded installed version. Reading it every
        reconcile - not only at startup - means the announcement fires whether the
        daemon was restarted by a successful update or kept running through a failed
        one.
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
        Publish-CopilotMqttUpdate -InstalledVersion $installed -LatestVersion $outcome.Version `
            -ReleaseUrl $outcome.ReleaseUrl -InProgress:([bool]$script:DaemonUpdatePendingAttempt) -Headers $Headers
        [void](Set-CopilotMqttUpdateEntityIds)
        $script:DaemonUpdateAvailable = (ConvertTo-BridgeVersion $outcome.Version) -gt (ConvertTo-BridgeVersion $installed)
        $script:DaemonUpdatePublished = $true
        $script:DaemonUpdateSignature = ''
        if ($outcome.Success) {
            $message = "The bridge updated to **$($outcome.Version)**; currently recorded version: **$installed**. The daemon was restarted, so health after that restart is not certified by this result."
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
                    title = "Bridge update failed on $($script:DaemonMachineName)"
                    message = "The bridge update $attempt did not complete: $($outcome.Error). Currently recorded version: $installed. The installation may be partially changed; no rollback is claimed."
                    notification_id = "agent_bridge_update_$($script:DaemonMachineSlug)"
                } `
                -Headers $Headers
            Write-DaemonLog -Message "self-update FAILED for $($outcome.Version): $($outcome.Error); recorded version $installed"
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
    try { $status = Get-BridgeUpdateStatus }
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

    # Computed once, before anything can throw, because the press handler below
    # publishes the same two values on its spinner. It used to pass $status.Notes
    # there, which is empty whenever the check failed - so the explanation shown a
    # moment earlier was wiped by the spinner that followed it.
    $latest = $status.Latest
    $notes = if ($status.State -in @('Unavailable', 'NotFound', 'RateLimited')) { $status.Detail } else { $status.Notes }

    try {
        $signature = @($status.State, $status.Installed, $latest, $status.Url, $notes) | ConvertTo-Json -Compress
        if (-not $outcomeHandled -and ($signature -cne $script:DaemonUpdateSignature -or -not $script:DaemonUpdatePublished)) {
            Publish-CopilotMqttUpdate -InstalledVersion $status.Installed -LatestVersion $latest `
                -ReleaseUrl $status.Url -ReleaseNotes $notes -InProgress:([bool]$script:DaemonUpdatePendingAttempt) -Headers $Headers
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
        try {
            Publish-CopilotMqttUpdate -InstalledVersion $status.Installed -LatestVersion $latest `
                -ReleaseUrl $status.Url -ReleaseNotes $notes -InProgress -Headers $Headers
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
                Publish-CopilotMqttUpdate -InstalledVersion (Get-BridgeInstalledVersion -Refresh) -LatestVersion $knownTarget -Headers $Headers
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
