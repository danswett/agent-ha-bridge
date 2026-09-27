<#
.SYNOPSIS
    Installs the Claude Code adapter for the Copilot <-> Home Assistant bridge.

.DESCRIPTION
    Copies the adapter into ~/.claude/ha-bridge and registers its hooks in
    ~/.claude/settings.json:

      * PreToolUse, matching AskUserQuestion, to mirror questions to Home Assistant
      * Notification, to surface permission prompts and idle waits
      * Stop, to mark the turn idle and push the response preview
      * SessionStart and UserPromptSubmit, to register the session immediately

    The main bridge must already be installed: the adapter reuses its Home Assistant
    layer, its daemon and its dashboard.

    Existing settings are merged, never replaced, and re-running is safe.

.PARAMETER TargetHome
    Install into this directory instead of $HOME. For testing without touching a real
    setup; $HOME is read-only in PowerShell so it cannot be redirected otherwise.

.PARAMETER Uninstall
    Remove the adapter and its hook registrations.
#>

[CmdletBinding()]
param(
    [string]$TargetHome,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$installHome = if ($TargetHome) { $TargetHome } else { $HOME }
$claudeHome = Join-Path $installHome '.claude'
$adapterDir = Join-Path $claudeHome 'ha-bridge'
$settingsPath = Join-Path $claudeHome 'settings.json'
$coreDir = Join-Path $installHome '.agent-ha-bridge\hooks'

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ is required (found $($PSVersionTable.PSVersion))."
}

# Hooks run through run-hook.cmd rather than naming pwsh directly. Claude Code runs
# hook commands under Git Bash on Windows, and there is no pwsh path that works there
# reliably: the Store build's versioned folder vanishes on its next update, its
# execution alias cannot be executed by Bash at all ("Permission denied"), and a bare
# `pwsh` only resolves to a runnable file when Claude happened to be started from that
# same PowerShell. Every one of those fails silently, because the hooks exit 0 by
# design. cmd resolves pwsh the way Windows does, whichever way it was installed.
$hookLauncher = Join-Path $adapterDir 'run-hook.cmd'

function Get-Settings {
    if (-not (Test-Path -LiteralPath $settingsPath)) { return @{} }
    $raw = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
    # -AsHashtable keeps this a mutable map; an ordered dictionary would not expose
    # ContainsKey, and a PSCustomObject would need rebuilding to merge into.
    $raw | ConvertFrom-Json -AsHashtable
}

function Save-Settings {
    param([hashtable]$Settings)
    if (-not (Test-Path -LiteralPath $claudeHome)) {
        New-Item -ItemType Directory -Path $claudeHome -Force | Out-Null
    }
    if (Test-Path -LiteralPath $settingsPath) {
        Copy-Item $settingsPath "$settingsPath.bak" -Force
    }
    $Settings | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
}

function Remove-BridgeHooks {
    <#
        Strips only this bridge's entries, matched by the adapter path, so hooks added
        by anything else survive.
    #>
    param([hashtable]$Settings)

    if (-not $Settings.ContainsKey('hooks')) { return $Settings }
    $hooks = $Settings['hooks']

    foreach ($eventName in @($hooks.Keys)) {
        $kept = @()
        foreach ($matcherEntry in @($hooks[$eventName])) {
            $inner = @()
            foreach ($hook in @($matcherEntry['hooks'])) {
                if ([string]$hook['command'] -notmatch 'ha-bridge') { $inner += $hook }
            }
            if ($inner.Count -gt 0) {
                $matcherEntry['hooks'] = $inner
                $kept += $matcherEntry
            }
        }
        if ($kept.Count -gt 0) { $hooks[$eventName] = $kept } else { $hooks.Remove($eventName) }
    }

    if ($hooks.Count -eq 0) { $Settings.Remove('hooks') } else { $Settings['hooks'] = $hooks }
    $Settings
}

function Add-BridgeHook {
    param(
        [hashtable]$Settings,
        [string]$EventName,
        [string]$Matcher,
        [string]$ScriptName,
        [int]$TimeoutSeconds
    )

    if (-not $Settings.ContainsKey('hooks')) { $Settings['hooks'] = @{} }
    $hooks = $Settings['hooks']
    if (-not $hooks.ContainsKey($EventName)) { $hooks[$EventName] = @() }

    $command = '"{0}" "{1}"' -f $hookLauncher, (Join-Path $adapterDir $ScriptName)
    $entry = [ordered]@{
        matcher = $Matcher
        hooks   = @(
            [ordered]@{
                type    = 'command'
                command = $command
                timeout = $TimeoutSeconds
            }
        )
    }

    $hooks[$EventName] = @($hooks[$EventName]) + $entry
    $Settings
}

# ------------------------------------------------------------------ uninstall
if ($Uninstall) {
    Write-Step 'Removing the Claude Code adapter'
    if (Test-Path -LiteralPath $settingsPath) {
        Save-Settings -Settings (Remove-BridgeHooks -Settings (Get-Settings))
        Write-Host '    hook registrations removed'
    }
    if (Test-Path -LiteralPath $adapterDir) {
        Remove-Item -LiteralPath $adapterDir -Recurse -Force
        Write-Host '    adapter removed'
    }
    # The session registry lives in the real %TEMP%, which -TargetHome does not
    # redirect, so a sandboxed uninstall must not touch it: it holds the live
    # registrations of every Claude session actually running on this machine.
    $stateRoot = Join-Path $env:TEMP 'agent-bridge-claude'
    if (-not $TargetHome -and (Test-Path -LiteralPath $stateRoot)) { Remove-Item -LiteralPath $stateRoot -Recurse -Force }
    Write-Step 'Done'
    return
}

# -------------------------------------------------------------------- install
if (-not (Test-Path -LiteralPath (Join-Path $coreDir 'decision-mqtt.ps1'))) {
    throw ("The main bridge is not installed at $coreDir. Run install.ps1 first - the " +
           'Claude adapter reuses its Home Assistant layer, daemon and dashboard.')
}

Write-Step "Installing the adapter into $adapterDir"
if (-not (Test-Path -LiteralPath $adapterDir)) {
    New-Item -ItemType Directory -Path $adapterDir -Force | Out-Null
}
Get-ChildItem (Join-Path $PSScriptRoot 'hooks') -File | ForEach-Object {
    Copy-Item $_.FullName $adapterDir -Force
    Write-Host "    $($_.Name)"
}

Write-Step "Registering hooks in $settingsPath"
$settings = Remove-BridgeHooks -Settings (Get-Settings)
$settings = Add-BridgeHook -Settings $settings -EventName 'PreToolUse' -Matcher 'AskUserQuestion' `
    -ScriptName 'route-askuserquestion.ps1' -TimeoutSeconds 30
# Notification is what carries permission prompts and idle waits, and unlike
# AskUserQuestion it is present in every build.
$settings = Add-BridgeHook -Settings $settings -EventName 'Notification' -Matcher '' `
    -ScriptName 'route-notification.ps1' -TimeoutSeconds 30
$settings = Add-BridgeHook -Settings $settings -EventName 'Stop' -Matcher '' `
    -ScriptName 'notify-claude-stop.ps1' -TimeoutSeconds 30
# SessionStart makes a session visible the moment it opens rather than after its first
# turn, and is what lets a dashboard launch confirm it started. UserPromptSubmit
# covers a session that was already open when this ran.
$settings = Add-BridgeHook -Settings $settings -EventName 'SessionStart' -Matcher '' `
    -ScriptName 'register-claude-session.ps1' -TimeoutSeconds 15
$settings = Add-BridgeHook -Settings $settings -EventName 'UserPromptSubmit' -Matcher '' `
    -ScriptName 'register-claude-session.ps1' -TimeoutSeconds 15
Save-Settings -Settings $settings
Write-Host '    PreToolUse (AskUserQuestion), Notification, Stop, SessionStart and UserPromptSubmit registered'

Write-Step 'Done'
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Yellow
Write-Host '  1. Restart any running Claude Code sessions so they pick up the hooks.'
Write-Host '  2. The bridge daemon finds Claude sessions on its own; no restart needed.'
Write-Host "     Logs: `$env:TEMP\agent-decision-bridge.log and agent-bridge-daemon.log"
