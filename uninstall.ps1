<#
.SYNOPSIS
    Removes the AI coding agent <-> Home Assistant bridge.

.DESCRIPTION
    Stops and unregisters the scheduled task, removes the hook scripts and hook
    definitions, and optionally deletes the bridge config (which holds your token).

    Home Assistant entities are published through retained MQTT discovery messages, so
    -ClearEntities clears them; without it they linger until manually removed.

    One Home Assistant can serve several machines, and some of what the bridge creates
    there is shared by all of them - the dashboard and the Detailed activity toggle.
    Removing this machine never removes those unless it is the last one, because doing
    so would take the dashboard away from machines that are still running.

.PARAMETER KeepConfig
    Leave the bridge config in place, so a later re-install keeps your settings.

.PARAMETER ClearEntities
    Clear the retained MQTT discovery topics so Home Assistant drops this machine's
    entities. Requires the config to still be present.

.PARAMETER ClearShared
    Also remove the state shared with every other machine: the dashboard and the
    Detailed activity toggle. Only do this when no other machine uses this Home
    Assistant, or you will remove their dashboard too.

.PARAMETER KeepShared
    Never remove the shared dashboard or toggle, even when this looks like the last
    machine. Useful when another machine is simply switched off rather than gone.

.PARAMETER Pause
    Wait for a keypress before closing. Set on the Apps & features entry, because
    Windows launches that in a console of its own that vanishes the moment the script
    ends - taking every warning, and any failure, with it.

.PARAMETER TargetHome
    Uninstall from this directory's .agent-ha-bridge instead of $HOME's. Intended for
    testing; it skips shared services and PATH changes but still stops this root's
    verified runtime before cleanup.

.PARAMETER TestRegistryId
    The unique registry namespace passed to a disposable test install. Requires
    -TargetHome and does not make this safe to run on a shared host.
#>

[CmdletBinding()]
param(
    [switch]$KeepConfig,
    [switch]$ClearEntities,
    [switch]$ClearShared,
    [switch]$KeepShared,
    [switch]$Pause,
    [string]$TargetHome,
    [string]$InstallRoot,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$TestRegistryId
)

$ErrorActionPreference = 'Stop'
if ($TestRegistryId -and -not $TargetHome) { throw '-TestRegistryId requires -TargetHome.' }
$testRegistrySuffix = if ($TestRegistryId) { "_$TestRegistryId" } else { '' }

# Held at script scope because the trap below cannot see the parameter directly.
$script:PauseOnExit = [bool]$Pause

function Wait-BridgeUninstallExit {
    <#
        Holds the window open so whatever just happened can actually be read.

        Skipped when stdin is redirected: a scripted or piped run has nobody to press
        a key, and blocking there would hang an unattended uninstall rather than
        informing anyone.
    #>
    param(
        [string]$Message = 'Press Enter to close this window',
        [AllowNull()][object]$Interactive
    )
    if (-not $script:PauseOnExit) { return $false }
    if ($null -eq $Interactive) { $Interactive = Test-BridgeUninstallInteractive }
    if (-not $Interactive) { return $false }
    Write-Host ''
    [void](Read-Host $Message)
    return $true
}

# A failure is exactly when the window must not vanish, so the pause is wired to the
# error path as well as the normal one. `break` re-throws, so a run without -Pause
# behaves precisely as it did before.
trap {
    if ($script:PauseOnExit) {
        Write-Host ''
        Write-Host "Uninstall failed: $($_.Exception.Message)" -ForegroundColor Red
        [void](Wait-BridgeUninstallExit)
        exit 1
    }
    break
}

# Windows/macOS differences; on macOS also makes Join-Path accept '\'. Beside this
# script in both the repository and an install.
$platform = Join-Path (Join-Path $PSScriptRoot 'hooks') 'bridge-platform.ps1'
if (Test-Path -LiteralPath $platform) { . $platform } else { $script:BridgeIsWindows = [bool]$IsWindows }

$installContext = Resolve-BridgeInstallContext -TargetHome $TargetHome -BridgeHome $InstallRoot -EntryDirectory $PSScriptRoot
$installHome = $installContext.Home
$copilotHome = $installContext.CopilotHome
if (-not $TestRegistryId -and $installContext.TestRegistryId) { $TestRegistryId = $installContext.TestRegistryId }
if ($TestRegistryId -and $installContext.Recorded -and $TestRegistryId -ne $installContext.TestRegistryId) {
    throw 'The test registry namespace does not match this installation.'
}
$testRegistrySuffix = if ($TestRegistryId) { "_$TestRegistryId" } else { '' }
$arpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AgentHaBridge' +
$(if ($TestRegistryId) { "_Sandbox$testRegistrySuffix" } elseif ($installContext.Id) { "_$($installContext.Id)" } else { '' })
$bridgeHome = $installContext.BridgeHome
$hooksDir = Join-Path $bridgeHome 'hooks'
$hookConfigPath = Join-Path $copilotHome 'hooks\decision-notifier.json'
$agentInstructionsPath = Join-Path $copilotHome 'instructions\agent-ha-bridge.instructions.md'
$legacySkillDir = Join-Path $copilotHome 'skills\decision-notifier'
$configPath = $installContext.ConfigPath
$devBoxTaskName = 'AgentBridgeDevBoxKeepAwake'
# Pre-rename artefacts, removed too so an upgrade-then-uninstall leaves nothing.
$legacyHooksDir = Join-Path $copilotHome 'hooks'
$legacyConfigPath = Join-Path $copilotHome 'copilot-ha-bridge.config.json'
$legacyBridgeHome = Join-Path $copilotHome 'copilot-ha-bridge'
$legacyArpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\CopilotHaBridge' +
$(if ($TargetHome) { "_Sandbox$testRegistrySuffix" } else { '' })

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }

function Test-BridgeUninstallInteractive {
    <# False when stdin is redirected, so a scripted uninstall never blocks on a prompt. #>
    try { return -not [Console]::IsInputRedirected } catch { return $false }
}

function Read-BridgeUninstallYesNo {
    <# A y/N prompt that defaults to no, because the risky answer here is yes. #>
    param([Parameter(Mandatory)][string]$Question)
    $answer = Read-Host "$Question [y/N]"
    return ([string]$answer).Trim().ToLowerInvariant() -in @('y', 'yes')
}

function Get-BridgeSharedStateDecision {
    <#
        Decides whether this uninstall may remove the state that every machine shares -
        the generated dashboard and the Detailed activity toggle.

        One Home Assistant commonly serves several machines. Before this, uninstalling
        anywhere deleted the dashboard and the toggle outright, so tidying up a laptop
        took the dashboard away from the desktop that was still running. The remaining
        daemons do recreate both, but only on their next reconcile, so there was a
        window where Home Assistant showed nothing.

        The rule, in order:

          * an explicit switch always wins, in either direction;
          * a known list of other machines means leave the shared state alone;
          * a known *empty* list means this is the last machine, so clean up fully;
          * an unknown list falls back to asking, and to keeping when nobody can answer.

        $OtherMachines is deliberately nullable, and $null means "could not tell" rather
        than "none" - a failed lookup must never be read as permission to delete.
    #>
    param(
        [switch]$ClearShared,
        [switch]$KeepShared,
        [bool]$Interactive,
        [AllowNull()][string[]]$OtherMachines,
        [scriptblock]$Prompt
    )

    if ($KeepShared -and $ClearShared) {
        return [pscustomobject]@{ Clear = $false; Reason = '-KeepShared and -ClearShared were both given, so the safe one wins' }
    }
    if ($KeepShared) { return [pscustomobject]@{ Clear = $false; Reason = '-KeepShared' } }
    if ($ClearShared) { return [pscustomobject]@{ Clear = $true; Reason = '-ClearShared' } }

    if ($null -ne $OtherMachines) {
        $others = @($OtherMachines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($others.Count -gt 0) {
            return [pscustomobject]@{
                Clear = $false
                Reason = "still in use by $($others -join ', ')"
            }
        }
        return [pscustomobject]@{ Clear = $true; Reason = 'this is the only machine using this Home Assistant' }
    }

    if ($Interactive -and $Prompt) {
        if (& $Prompt) { return [pscustomobject]@{ Clear = $true; Reason = 'confirmed at the prompt' } }
        return [pscustomobject]@{ Clear = $false; Reason = 'declined at the prompt' }
    }

    return [pscustomobject]@{
        Clear = $false
        Reason = 'could not tell whether another machine shares this Home Assistant'
    }
}

function Remove-BridgeOwnedInstallationFiles {
    param([Parameter(Mandatory)]$Context, [switch]$KeepConfig)
    if ($Context.Recorded) {
        $record = Read-BridgeInstallRecord -Path $Context.MetadataPath
        if (-not $record -or [string]$record['id'] -cne $Context.Id -or
            -not (Test-BridgeInstallPath ([string]$record['bridgeHome']) $Context.BridgeHome)) {
            throw 'Installation ownership changed; no payload cleanup was authorized.'
        }
        foreach ($relative in @('hooks', 'bin', 'installer', 'frontend', 'cache', 'runtime')) {
            $path = Join-Path $Context.BridgeHome $relative
            if (-not (Test-Path -LiteralPath $path)) { continue }
            if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "An owned payload path was replaced by a link; it was preserved: $path"
            }
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
    else {
        Write-Warning 'Unattributed legacy payload directories and shared temporary data were preserved.'
    }
    if (-not $KeepConfig) {
        foreach ($file in @($Context.ConfigPath, "$($Context.ConfigPath).bak", $Context.MetadataPath)) {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        }
    }
    $uninstaller = Join-Path $Context.BridgeHome 'uninstall.ps1'
    if (Test-Path -LiteralPath $uninstaller) { Remove-Item -LiteralPath $uninstaller -Force }
    if ((Test-Path -LiteralPath $Context.BridgeHome) -and
        -not @(Get-ChildItem -LiteralPath $Context.BridgeHome -Force).Count) {
        Remove-Item -LiteralPath $Context.BridgeHome -Force
    }
}

function Remove-BridgeInstalledAdapters {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Payload)
    $paths = @{
        claude = Join-Path $Context.ClaudeHome 'ha-bridge'
        codex = Join-Path $Context.BridgeHome 'codex-bridge'
        mcp = Join-Path $Context.BridgeHome 'mcp'
    }
    $record = Read-BridgeInstallRecord -Path $Context.MetadataPath
    $recordedAdapters = @(if ($record -and $record.Contains('adapters')) { $record['adapters'] })
    foreach ($client in @('claude', 'codex', 'mcp')) {
        $legacyPath = if ($Context.LegacyLayout -and $client -in @('codex', 'mcp')) {
            Join-Path $Context.CopilotHome $(if ($client -eq 'codex') { 'codex-bridge' } else { 'mcp' })
        } else { '' }
        if (-not (Test-Path -LiteralPath $paths[$client]) -and $recordedAdapters -notcontains $client -and
            (-not $legacyPath -or -not (Test-Path -LiteralPath $legacyPath))) { continue }
        $setup = Join-Path $Payload "$client\install-$client.ps1"
        if (-not (Test-Path -LiteralPath $setup)) {
            throw "The $client cleanup helper is unavailable. Restore the installer payload before uninstalling."
        }
        $arguments = @{ InstallRoot = $Context.BridgeHome; Uninstall = $true; KeepSelection = $true }
        if ($Context.Isolated) { $arguments.TargetHome = $Context.Home }
        & $setup @arguments
    }
}

function Invoke-BridgeUninstall {
    param([string]$AdapterPayloadRoot)

    Stop-BridgeOwnedService -Context $installContext -Remove
    Stop-BridgeOwnedRuntime -Context $installContext

    # Keep the helpers until after entity and adapter cleanup, but stop their writer first.
    if ($ClearEntities -and $installContext.Isolated) {
        # Entities, the verbose toggle and the dashboard live in the shared Home Assistant
        # instance, not under the install root. Clearing them from a sandbox uninstall
        # would wipe the real install's dashboard, so it is refused outright.
        Write-Warning ('Ignoring -ClearEntities because -TargetHome is set: Home Assistant ' +
            'entities are global and would belong to the real install.')
    }
    elseif ($ClearEntities) {
        Write-Step 'Clearing Home Assistant entities'
        try {
            . (Join-Path $hooksDir 'decision-bridge-common.ps1')
            . (Join-Path $hooksDir 'decision-mqtt.ps1')
            . (Join-Path $hooksDir 'decision-ha-websocket.ps1')
            $headers = Get-HomeAssistantHeaders
            $root = $script:DecisionBridgeConfig.SessionStateRoot
            if (Test-Path -LiteralPath $root) {
                Get-ChildItem -LiteralPath $root -Directory | ForEach-Object {
                    try { Remove-CopilotMqttSession -SessionId $_.Name -Headers $headers } catch { }
                }
                foreach ($client in @('claude', 'codex')) {
                    $registry = Get-BridgeRuntimePath -Name "agent-bridge-$client" -Context $installContext
                    if (-not (Test-Path -LiteralPath $registry)) { continue }
                    foreach ($file in Get-ChildItem -LiteralPath $registry -Filter '*.json' -File) {
                        if ($file.Name -like '*.approval.json') { continue }
                        $entry = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
                        if ($entry.PSObject.Properties['SessionId'] -and $entry.SessionId) {
                            Remove-CopilotMqttSession -SessionId ([string]$entry.SessionId) -Headers $headers | Out-Null
                        }
                    }
                }
            }
            Write-Host '    session entities cleared'

            # The update entity, the launch controls and the session counter belong to this
            # machine alone, so they go with it and every other machine's stay put.
            try {
                $count = Remove-CopilotMqttMachineEntities -Headers $headers
                Write-Host "    cleared $count topic(s) for $([Environment]::MachineName)"
            }
            catch { Write-Warning "Could not clear this machine's entities: $($_.Exception.Message)" }

            # The dashboard and the toggle belong to the Home Assistant instance, not to
            # this machine, so whether they may go depends on who else is still using it.
            $otherMachines = $null
            try {
                if (Get-Command Get-BridgePeerMachine -ErrorAction SilentlyContinue) {
                    $otherMachines = @(Get-BridgePeerMachine -Headers $headers -ExcludeSelf |
                            ForEach-Object { [string]$_.Machine })
                }
            }
            catch {
                # Leave it unknown: a failed lookup must not read as "nobody else is here".
                $otherMachines = $null
            }

            $decision = Get-BridgeSharedStateDecision `
                -ClearShared:$ClearShared -KeepShared:$KeepShared `
                -Interactive (Test-BridgeUninstallInteractive) `
                -OtherMachines $otherMachines `
                -Prompt {
                Write-Host ''
                Write-Host '    The dashboard and the Detailed activity toggle are shared by every' -ForegroundColor Yellow
                Write-Host '    machine that talks to this Home Assistant.' -ForegroundColor Yellow
                Read-BridgeUninstallYesNo '    Remove them too (only if this is your last machine)?'
            }

            if (-not $decision.Clear) {
                Write-Host "    keeping the shared dashboard and toggle - $($decision.Reason)"
            }
            else {
                Write-Host "    removing the shared dashboard and toggle - $($decision.Reason)"
                try {
                    if (Remove-CopilotVerboseToggle) { Write-Host '    removed the Detailed activity toggle' }
                }
                catch { Write-Warning "Could not remove the verbose toggle: $($_.Exception.Message)" }

                try {
                    if (Get-Command Remove-BridgeMachineSelector -ErrorAction SilentlyContinue) {
                        if (Remove-BridgeMachineSelector) { Write-Host '    removed the machine picker' }
                    }
                }
                catch { Write-Warning "Could not remove the machine picker: $($_.Exception.Message)" }

                $urlPath = $script:DecisionBridgeConfig.DashboardUrlPath
                try {
                    if ($urlPath) {
                        [void](Invoke-CopilotHaWebSocket -Commands @(@{
                                    type = 'lovelace/config/delete'; url_path = $urlPath
                                }))
                        Write-Host "    removed the '$urlPath' dashboard view"
                    }
                }
                catch {
                    # Already absent is the desired end state, not a failure.
                    if ($_.Exception.Message -match 'config_not_found') {
                        Write-Host "    dashboard '$urlPath' already absent"
                    }
                    else {
                        Write-Warning "Could not remove the dashboard: $($_.Exception.Message)"
                    }
                }
            }
        }
        catch {
            Write-Warning "Could not clear entities: $($_.Exception.Message)"
        }
    }
    # Reported only when it exists: a machine that was never a Dev Box should not be
    # told about a task it never had.
    if (Get-ScheduledTask -TaskName $devBoxTaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $devBoxTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $devBoxTaskName -Confirm:$false
        Write-Host "    removed $devBoxTaskName"
    }

    $adapterPayload = if ($AdapterPayloadRoot) { $AdapterPayloadRoot }
    elseif (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'claude\install-claude.ps1')) { $PSScriptRoot }
    else { Join-Path $bridgeHome 'installer' }
    Remove-BridgeInstalledAdapters -Context $installContext -Payload $adapterPayload

    if (-not $installContext.Legacy) {
        . (Join-Path $hooksDir 'daemon-replies.ps1')
        $script:BridgeInstallContext = $installContext
        $attachments = Get-BridgeAttachmentRoot -NoCreate
        if ((Split-Path $attachments -Leaf) -cne "install-$($installContext.Id)") { throw 'Attachment ownership could not be established.' }
        if (Test-Path -LiteralPath $attachments) {
            if ((Get-Item -LiteralPath $attachments -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'The attachment directory was replaced by a link; it was preserved.'
            }
            Remove-Item -LiteralPath $attachments -Recurse -Force
        }
    }

    Write-Step 'Removing hook scripts'
    $files = @(
        'decision-bridge-common.ps1', 'decision-mqtt.ps1', 'decision-ha-websocket.ps1',
        'decision-inject.ps1', 'agent-bridge-daemon.ps1', 'agent-bridge-supervisor.ps1',
        'agent-bridge-launch.vbs', 'route-ask-user-v3.ps1', 'notify-agent-response.ps1',
        'notify-home-assistant.ps1', 'bridge-adapter.ps1', 'bridge-update.ps1',
        'bridge-frontend-cards.ps1', 'session-launch.ps1', 'bridge-platform.ps1', 'bridge-install-context.ps1', 'bridge-test-guard.ps1', 'bridge-secrets.ps1', 'VERSION',
        'copilot-hooks.ps1', 'bridge-native-hook.ps1', 'daemon-agents.ps1', 'daemon-discovery.ps1', 'daemon-activity.ps1', 'daemon-sessions.ps1', 'daemon-replies.ps1',
        'daemon-decisions.ps1', 'daemon-launch.ps1', 'daemon-maintenance.ps1', 'daemon-hookspool.ps1'
    )
    foreach ($name in $files) {
        $path = Join-Path $hooksDir $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force; Write-Host "    $name" }
    }

    # The two bridge files outside the bridge root: the Copilot CLI's hook definition, and
    # the instructions it reads globally. Leaving the latter behind would keep telling every
    # session how to drive a bridge that is no longer installed.
    if (Test-Path -LiteralPath $hookConfigPath) {
        $hookConfig = Get-Content -LiteralPath $hookConfigPath -Raw | ConvertFrom-Json -AsHashtable
        $hookConfig = Remove-BridgeCopilotHookEntries -Config $hookConfig -Context $installContext
        if ($hookConfig.ContainsKey('hooks') -or @($hookConfig.Keys | Where-Object { $_ -ne 'version' }).Count) {
            $hookConfig | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $hookConfigPath -Encoding utf8
        }
        else { Remove-Item -LiteralPath $hookConfigPath -Force }
        Write-Host "    $hookConfigPath"
    }
    if ((Test-Path -LiteralPath $agentInstructionsPath) -and
        [IO.File]::ReadAllText($agentInstructionsPath).StartsWith("<!-- agent-ha-bridge-owner:$($installContext.Id) -->")) {
        Remove-Item -LiteralPath $agentInstructionsPath -Force
        Write-Host "    $agentInstructionsPath"
        # Only if the bridge's file was the only thing in there.
        $instructionsDir = Split-Path -Parent $agentInstructionsPath
        if (-not (Get-ChildItem -LiteralPath $instructionsDir -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $instructionsDir -Force -ErrorAction SilentlyContinue
        }
    }

    if ($installContext.LegacyLayout -and (Test-Path -LiteralPath $legacySkillDir)) {
        Write-Step 'Removing the obsolete decision-notifier skill'
        Remove-Item -LiteralPath $legacySkillDir -Recurse -Force
    }

    # Anything a pre-rename install left in ~/.copilot.
    if ($installContext.LegacyLayout) {
        foreach ($name in @(
            'decision-bridge-common.ps1', 'decision-mqtt.ps1', 'decision-ha-websocket.ps1',
            'decision-inject.ps1', 'bridge-adapter.ps1', 'bridge-update.ps1', 'session-launch.ps1',
            'copilot-bridge-daemon.ps1', 'copilot-bridge-supervisor.ps1', 'copilot-bridge-launch.vbs',
            'route-ask-user-v3.ps1', 'notify-agent-response.ps1', 'notify-home-assistant.ps1', 'VERSION')) {
            $path = Join-Path $legacyHooksDir $name
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force
                Write-Host "    $path"
            }
        }
        $legacyPaths = @($legacyBridgeHome)
        if (-not $KeepConfig -or -not (Test-BridgeInstallPath $configPath $legacyConfigPath)) {
            $legacyPaths += @($legacyConfigPath, "$legacyConfigPath.bak")
        }
        foreach ($path in $legacyPaths) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Recurse -Force
                Write-Host "    $path"
            }
        }
    }
    elseif ((Test-Path -LiteralPath $legacyConfigPath) -or (Test-Path -LiteralPath $legacyBridgeHome)) {
        Write-Warning 'Unattributed pre-rename files and configuration were preserved; this installation does not own that legacy layout.'
    }
    if ($script:BridgeIsWindows -and (-not $installContext.Isolated -or $TestRegistryId) -and
        (Test-Path -LiteralPath $legacyArpKey) -and
        (Test-BridgeUninstallEntryOwnership -Path $legacyArpKey -Context $installContext -Legacy)) {
        Remove-Item -LiteralPath $legacyArpKey -Recurse -Force -ErrorAction SilentlyContinue
    }

    $mcpDir = Join-Path $bridgeHome 'mcp'
    if (Test-Path -LiteralPath $mcpDir) {
        Write-Step 'Removing the MCP server'
        Remove-Item -LiteralPath $mcpDir -Recurse -Force
    }

    # The bridge root goes at the end of this script, but the PATH entry pointing into it
    # is stored elsewhere and would survive as a dead entry.
    $binDir = Join-Path $bridgeHome 'bin'

    function Remove-BridgePathRegistration {
        <#
        Drops the bridge's bin directory from the user PATH, reusing the installer's
        own helpers so adding and removing always agree on what counts as the same
        entry.

        The dot-source happens inside this function on purpose: install.ps1 assigns
        $TargetHome, $bridgeHome, $configPath and friends at its script level, and
        dot-sourcing it at the caller's scope would rebind them mid-uninstall.
    #>
        param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$InstallerPath)
        $env:BRIDGE_INSTALL_NORUN = '1'
        try {
            . $InstallerPath
            if (Register-BridgePathEntry -Directory $Directory -Remove) {
                Send-BridgeEnvironmentChange
                return $true
            }
            return $false
        }
        finally { Remove-Item Env:\BRIDGE_INSTALL_NORUN -ErrorAction SilentlyContinue }
    }

    if ($installContext.Isolated) {
        # A sandbox install never put itself on PATH, so there is nothing to undo and the
        # real install's entry must not be touched.
        Write-Step 'Leaving PATH alone (-TargetHome)'
    }
    elseif (-not $script:BridgeIsWindows) {
        # The line the installer marked in the shell profiles.
        Write-Step 'Removing agent-ha-bridge from your PATH'
        foreach ($name in @('.zprofile', '.bash_profile', '.bash_login', '.profile')) {
            $file = Join-Path $installHome $name
            if (-not (Test-Path -LiteralPath $file)) { continue }
            $lines = @(Get-Content -LiteralPath $file)
            $kept = @($lines | Where-Object { $_ -notmatch '# agent-ha-bridge$' })
            if ($kept.Count -ne $lines.Count) {
                Set-Content -LiteralPath $file -Value $kept
                Write-Host "    removed from ~/$name"
            }
        }
    }
    else {
        Write-Step 'Removing agent-ha-bridge from your PATH'
        $installerCopy = Join-Path $bridgeHome 'installer\install.ps1'
        if (-not (Test-Path -LiteralPath $installerCopy)) { $installerCopy = Join-Path $PSScriptRoot 'install.ps1' }
        try {
            if (Test-Path -LiteralPath $installerCopy) {
                if (Remove-BridgePathRegistration -Directory $binDir -InstallerPath $installerCopy) {
                    Write-Host "    removed $binDir"
                }
                else { Write-Host "    $binDir was not on the user PATH" }
            }
            else {
                Write-Host "    no installer copy found; remove $binDir from PATH by hand if it is there" -ForegroundColor Yellow
            }
        }
        catch { Write-Warning "Could not update PATH: $($_.Exception.Message)" }
    }

    if (-not $KeepConfig) {
        Write-Step 'Removing the bridge config (it holds your token)'
        if (Test-Path -LiteralPath $configPath) { Remove-Item -LiteralPath $configPath -Force }
        # The install-time backup holds the same token.
        if (Test-Path -LiteralPath "$configPath.bak") { Remove-Item -LiteralPath "$configPath.bak" -Force }
    }

    if ($script:BridgeIsWindows -and (-not $installContext.Isolated -or $TestRegistryId) -and
        (Test-Path -LiteralPath $arpKey) -and
        (Test-BridgeUninstallEntryOwnership -Path $arpKey -Context $installContext)) {
        Write-Step 'Removing the Apps & features entry'
        Remove-Item -LiteralPath $arpKey -Recurse -Force
    }

    # Last, because this script usually runs from here via the uninstall entry. Deleting
    # the folder while it executes is fine on Windows: the file stays open until the
    # process exits.
    Remove-BridgeOwnedInstallationFiles -Context $installContext -KeepConfig:$KeepConfig

    Write-Step 'Done'
    Write-Host 'Restart any running agent CLI sessions to drop the hooks.' -ForegroundColor Yellow
    [void](Wait-BridgeUninstallExit)
}

if ($env:BRIDGE_UNINSTALL_NORUN) { return }
Invoke-BridgeUninstall