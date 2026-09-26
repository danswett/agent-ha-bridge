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

.PARAMETER TargetHome
    Uninstall from this directory's .agent-ha-bridge instead of $HOME's. Intended for
    testing; it also skips the machine-wide steps (scheduled task, process termination).
#>

[CmdletBinding()]
param(
    [switch]$KeepConfig,
    [switch]$ClearEntities,
    [switch]$ClearShared,
    [switch]$KeepShared,
    [string]$TargetHome
)

$ErrorActionPreference = 'Stop'

$installHome = if ($TargetHome) { $TargetHome } else { $HOME }
$copilotHome = Join-Path $installHome '.copilot'
$arpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AgentHaBridge' +
          $(if ($TargetHome) { '_Sandbox' } else { '' })
$bridgeHome = Join-Path $installHome '.agent-ha-bridge'
$hooksDir = Join-Path $bridgeHome 'hooks'
$hookConfigPath = Join-Path $copilotHome 'hooks\decision-notifier.json'
$legacySkillDir = Join-Path $copilotHome 'skills\decision-notifier'
$configPath = Join-Path $bridgeHome 'config.json'
$taskName = 'AgentBridgeDaemon'
# Pre-rename artefacts, removed too so an upgrade-then-uninstall leaves nothing.
$legacyTaskName = 'CopilotBridgeDaemon'
$legacyHooksDir = Join-Path $copilotHome 'hooks'
$legacyConfigPath = Join-Path $copilotHome 'copilot-ha-bridge.config.json'
$legacyBridgeHome = Join-Path $copilotHome 'copilot-ha-bridge'
$legacyArpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\CopilotHaBridge' +
                $(if ($TargetHome) { '_Sandbox' } else { '' })

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

# Tests dot-source this script with BRIDGE_UNINSTALL_NORUN set to load the helpers
# above without removing anything.
if ($env:BRIDGE_UNINSTALL_NORUN) { return }

# Entities first: this needs the hooks and config that the rest of the script removes.
if ($ClearEntities -and $TargetHome) {
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

if ($TargetHome) {
    Write-Step 'Skipping the scheduled task and process cleanup (-TargetHome)'
}
else {
    Write-Step "Removing the '$taskName' scheduled task"
    foreach ($name in @($taskName, $legacyTaskName)) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            Write-Host "    removed $name"
        }
        else {
            Write-Host "    $name not registered"
        }
    }

    Write-Step 'Stopping any running daemon or supervisor'
    foreach ($proc in Get-Process pwsh -ErrorAction SilentlyContinue) {
        try {
            $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)").CommandLine
            if ($cmd -match '(agent|copilot)-bridge-(daemon|supervisor)\.ps1') {
                Stop-Process -Id $proc.Id -Force
                Write-Host "    stopped pid $($proc.Id)"
            }
        }
        catch { }
    }
}

Write-Step 'Removing hook scripts'
$files = @(
    'decision-bridge-common.ps1', 'decision-mqtt.ps1', 'decision-ha-websocket.ps1',
    'decision-inject.ps1', 'agent-bridge-daemon.ps1', 'agent-bridge-supervisor.ps1',
    'agent-bridge-launch.vbs', 'route-ask-user-v3.ps1', 'notify-agent-response.ps1',
    'notify-home-assistant.ps1', 'bridge-adapter.ps1', 'bridge-update.ps1',
    'bridge-frontend-cards.ps1', 'session-launch.ps1', 'VERSION'
)
foreach ($name in $files) {
    $path = Join-Path $hooksDir $name
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force; Write-Host "    $name" }
}

# The Copilot CLI's hook definition is the one bridge file outside the bridge root.
if (Test-Path -LiteralPath $hookConfigPath) {
    Remove-Item -LiteralPath $hookConfigPath -Force
    Write-Host "    $hookConfigPath"
}

if (Test-Path -LiteralPath $legacySkillDir) {
    Write-Step 'Removing the obsolete decision-notifier skill'
    Remove-Item -LiteralPath $legacySkillDir -Recurse -Force
}

# Anything a pre-rename install left in ~/.copilot.
foreach ($name in @(
    'decision-bridge-common.ps1', 'decision-mqtt.ps1', 'decision-ha-websocket.ps1',
    'decision-inject.ps1', 'bridge-adapter.ps1', 'bridge-update.ps1', 'session-launch.ps1',
    'copilot-bridge-daemon.ps1', 'copilot-bridge-supervisor.ps1', 'copilot-bridge-launch.vbs',
    'route-ask-user-v3.ps1', 'notify-agent-response.ps1', 'notify-home-assistant.ps1', 'VERSION')) {
    $path = Join-Path $legacyHooksDir $name
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Write-Host "    $path"
    }
}
foreach ($path in @($legacyConfigPath, "$legacyConfigPath.bak", $legacyBridgeHome)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "    $path"
    }
}
if (Test-Path -LiteralPath $legacyArpKey) {
    Remove-Item -LiteralPath $legacyArpKey -Recurse -Force -ErrorAction SilentlyContinue
}

$mcpDir = Join-Path $bridgeHome 'mcp'
if (Test-Path -LiteralPath $mcpDir) {
    Write-Step 'Removing the MCP server'
    Remove-Item -LiteralPath $mcpDir -Recurse -Force
    # The Claude Desktop registration (and any other MCP client's) is left in place;
    # remove it with `mcp/install-mcp.ps1 -Uninstall`, the same way the Claude and
    # Codex client registrations are their own installers' job.
    Write-Host '    (run mcp/install-mcp.ps1 -Uninstall to also remove it from Claude Desktop)'
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

if ($TargetHome) {
    # A sandbox install never put itself on PATH, so there is nothing to undo and the
    # real install's entry must not be touched.
    Write-Step 'Leaving PATH alone (-TargetHome)'
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

if (-not $KeepConfig -and (Test-Path -LiteralPath $configPath)) {
    Write-Step 'Removing the bridge config (it holds your token)'
    Remove-Item -LiteralPath $configPath -Force
    # The install-time backup holds the same token.
    if (Test-Path -LiteralPath "$configPath.bak") { Remove-Item -LiteralPath "$configPath.bak" -Force }
}

if (Test-Path -LiteralPath $arpKey) {
    Write-Step 'Removing the Apps & features entry'
    Remove-Item -LiteralPath $arpKey -Recurse -Force
}

# Last, because this script usually runs from here via the uninstall entry. Deleting
# the folder while it executes is fine on Windows: the file stays open until the
# process exits.
if (Test-Path -LiteralPath $bridgeHome) {
    if ($KeepConfig) {
        # The config lives in this folder, so clear it out item by item instead.
        Write-Step 'Removing the bridge root (keeping the config)'
        Get-ChildItem -LiteralPath $bridgeHome -Force |
            Where-Object { $_.FullName -ne $configPath -and $_.FullName -ne "$configPath.bak" } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
    else {
        Write-Step 'Removing the bridge root'
        Remove-Item -LiteralPath $bridgeHome -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Step 'Done'
Write-Host 'Restart any running agent CLI sessions to drop the hooks.' -ForegroundColor Yellow