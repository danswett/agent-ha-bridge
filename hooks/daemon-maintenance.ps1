<#
    Bridge daemon: keeping the install current.

    Update checks and their outcome on the dashboard, and setting up agents
    installed after the bridge.

    Part of agent-bridge-daemon.ps1, which dot-sources it into its own scope after
    declaring the shared $script: state; see docs/daemon-split.md.
    Shared state it changes: DaemonClientSetup, DaemonRestartRequested,
    DaemonUpdateAvailable, DaemonUpdateLastPress, DaemonUpdatePublished.
#>

function Invoke-DaemonUpdateOutcome {
    <#
        Announces the result of a self-update.

        The updater runs detached, with none of the bridge's modules or Home Assistant
        config loaded, so it cannot publish cleanly itself. It drops a small outcome
        file instead, and whichever daemon runs next turns that into a visible
        notification and an authoritative update-entity state. Reading it every
        reconcile - not only at startup - means the announcement fires whether the
        daemon was restarted by a successful update or kept running through a failed
        one.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    $path = $script:DaemonConfig.UpdateOutcomeFile
    if (-not (Test-Path -LiteralPath $path)) { return }

    $outcome = $null
    try { $outcome = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $outcome = $null }
    # A malformed or unreadable marker must not wedge the daemon: drop it and move on.
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($null -eq $outcome) { return }

    # Ignore a marker from long ago - a machine that was off for a week should not pop
    # a surprise notification when it wakes.
    try {
        if ($outcome.PSObject.Properties.Name -contains 'at' -and $outcome.at) {
            if (([DateTimeOffset]::Now - [DateTimeOffset]::Parse([string]$outcome.at)).TotalHours -gt 6) { return }
        }
    }
    catch { }

    $success = ($outcome.PSObject.Properties.Name -contains 'success' -and $outcome.success)
    $version = if ($outcome.PSObject.Properties.Name -contains 'version') { [string]$outcome.version } else { '' }
    $url = if ($outcome.PSObject.Properties.Name -contains 'releaseUrl') { [string]$outcome.releaseUrl } else { '' }

    try {
        if ($success) {
            # Authoritative "up to date" using the version actually installed, so the
            # entity is correct even on a daemon whose cached config is still stale.
            Publish-CopilotMqttUpdate -InstalledVersion $version -LatestVersion $version `
                -ReleaseUrl $url -Headers $Headers
            [void](Set-CopilotMqttUpdateEntityIds)
            $script:DaemonUpdateAvailable = $false
            $script:DaemonUpdatePublished = $true
            $message = "The Home Assistant bridge updated to **$version**."
            if ($url) { $message += " [Release notes]($url)" }
            Invoke-HomeAssistantService -Domain 'persistent_notification' -Service 'create' `
                -Data @{ title = "Bridge updated on $($script:DaemonMachineName)"; message = $message; notification_id = "agent_bridge_update_$($script:DaemonMachineSlug)" } `
                -Headers $Headers
            Write-DaemonLog -Message "self-update announced: updated to $version"
        }
        else {
            $err = if ($outcome.PSObject.Properties.Name -contains 'error') { [string]$outcome.error } else { 'unknown error' }
            # Clear the spinner, but leave the update showing as available so it can be
            # retried.
            $installed = (Get-BridgeUpdateStatus).Installed
            $latest = if ($version) { $version } else { $installed }
            Publish-CopilotMqttUpdate -InstalledVersion $installed -LatestVersion $latest -Headers $Headers
            Invoke-HomeAssistantService -Domain 'persistent_notification' -Service 'create' `
                -Data @{ title = "Bridge update failed on $($script:DaemonMachineName)"; message = "The bridge update did not complete: $err"; notification_id = "agent_bridge_update_$($script:DaemonMachineSlug)" } `
                -Headers $Headers
            Write-DaemonLog -Message "self-update announced: FAILED ($err)"
        }
    }
    catch {
        Write-DaemonLog -Message "update outcome announce failed: $($_.Exception.Message)"
    }
}

function Sync-DaemonUpdateStatus {
    <#
        Publishes the bridge's own update status, and acts on a press of the install
        button.

        Both halves are deliberately forgiving: an update check that fails, or a
        GitHub outage, must never disturb a running session. The check itself is
        cached for a day inside Get-BridgeLatestRelease, so calling this on every
        reconcile costs nothing.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    # A pending self-update result is announced regardless of the update-check opt-out:
    # it is the response to the user pressing install, not a background poll.
    Invoke-DaemonUpdateOutcome -Headers $Headers

    # Opting out has to stop the network call, not just hide the result, so this is
    # checked before anything else happens.
    if (-not (Get-BridgeSetting 'updates.checkForUpdates' $true)) { return }

    try {
        $status = Get-BridgeUpdateStatus
        $latest = if ($status.Available) { $status.Latest } else { $status.Installed }

        if ($status.Available -ne $script:DaemonUpdateAvailable -or -not $script:DaemonUpdatePublished) {
            Publish-CopilotMqttUpdate -InstalledVersion $status.Installed -LatestVersion $latest `
                -ReleaseUrl $status.Url -ReleaseNotes $status.Notes -Headers $Headers
            [void](Set-CopilotMqttUpdateEntityIds)
            $script:DaemonUpdatePublished = $true
            if ($status.Available -ne $script:DaemonUpdateAvailable) {
                $script:DaemonUpdateAvailable = $status.Available
                if ($status.Available) {
                    Write-DaemonLog -Message "update available: $($status.Installed) -> $($status.Latest)"
                }
            }
        }
    }
    catch {
        Write-DaemonLog -Message "update check failed: $($_.Exception.Message)"
        return
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
                -ReleaseUrl $status.Url -ReleaseNotes $status.Notes -InProgress -Headers $Headers
        }
        catch {
            Write-DaemonLog -Message "could not show update spinner: $($_.Exception.Message)"
        }
        $result = Invoke-BridgeSelfUpdate -Detached
        Write-DaemonLog -Message "self-update: $($result.Detail)"
    }
    catch {
        # The button may not exist yet on a first run.
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
    $payload = if ($script:DaemonInstallerPayload) { $script:DaemonInstallerPayload } else { Join-Path $HOME '.agent-ha-bridge\installer' }
    $own = (Get-DaemonAgent -Kind $Client).Installer
    if ($own) { return & $own $payload }
    [pscustomobject]@{ Path = Join-Path $payload "$Client\install-$Client.ps1"; Arguments = '' }
}

function Add-DaemonConfiguredClient {
    <#
        Adds a client to `clients` in the bridge config, so later installs and updates
        keep its adapter current. The file is re-read rather than rewritten from memory,
        so nothing changed on disk since the daemon started is lost.
    #>
    param([Parameter(Mandatory)][string]$Client)

    $path = Join-Path $HOME '.agent-ha-bridge\config.json'
    if (-not (Test-Path -LiteralPath $path)) { return }
    $config = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $clients = @()
    if ($config.PSObject.Properties['clients']) { $clients = @($config.clients | ForEach-Object { [string]$_ }) }
    if ($clients -contains $Client) { return }
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
    $clients = @($script:DaemonAgents.Keys | Where-Object { $null -ne (Get-DaemonAgent -Kind $_).AdapterInstalled })
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

        $log = Join-Path $env:TEMP "agent-bridge-setup-$client.log"
        try {
            $setup = @{
                FilePath               = 'pwsh'
                ArgumentList           = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$($installer.Path)`" $($installer.Arguments)".TrimEnd()
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
