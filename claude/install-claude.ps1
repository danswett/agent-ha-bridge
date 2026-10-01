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
    [string]$InstallRoot,
    [switch]$RepairOnly,
    [switch]$KeepSelection,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
# Windows/macOS differences; on macOS also makes Join-Path accept '\'.
. (Join-Path $PSScriptRoot '../hooks/bridge-platform.ps1')
. (Join-Path $PSScriptRoot '../hooks/bridge-secrets.ps1')

$installContext = Resolve-BridgeInstallContext -TargetHome $TargetHome -BridgeHome $InstallRoot
$claudeHome = $installContext.ClaudeHome
$adapterDir = Join-Path $claudeHome 'ha-bridge'
$settingsPath = Join-Path $claudeHome 'settings.json'
$coreDir = $installContext.HooksDir

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

# The native hook (docs/fast-hooks.md), when the main installer put one in place that
# runs: each hook then starts in tens of milliseconds, not half a second, and falls back
# to its PowerShell script itself whenever the daemon is not running.
. (Join-Path $PSScriptRoot '../hooks/bridge-native-hook.ps1')
$nativeHook = Get-BridgeNativeHookPath -BridgeHome $installContext.BridgeHome

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
                $command = [string]$hook['command']
                $owned = $false
                foreach ($scriptName in @('route-askuserquestion.ps1', 'route-notification.ps1', 'notify-claude-stop.ps1', 'register-claude-session.ps1')) {
                    $scriptPath = [regex]::Escape((Join-Path $adapterDir $scriptName))
                    $launcherPath = [regex]::Escape((Join-Path $adapterDir 'run-hook.cmd'))
                    $nativePath = [regex]::Escape((Join-Path $installContext.BridgeHome 'bin\agent-bridge-hook'))
                    if ($command -match "^`"$launcherPath`"\s+`"$scriptPath`"$" -or
                        $command -match "^[`"']$nativePath(?:\.exe)?[`"']\s+claude\s+(?:ask|stop|notification|register)\s+[`"']$scriptPath[`"']$" -or
                        $command -match "^'[^']*/pwsh'\s+-NoProfile\s+-NonInteractive\s+-File\s+'$scriptPath'$") {
                        $owned = $true
                        break
                    }
                }
                if (-not $owned) { $inner += $hook }
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
        [int]$TimeoutSeconds,

        # The native hook's name for this one (register, stop, ask, notification).
        [string]$NativeName
    )

    if (-not $Settings.ContainsKey('hooks')) { $Settings['hooks'] = @{} }
    $hooks = $Settings['hooks']
    if (-not $hooks.ContainsKey($EventName)) { $hooks[$EventName] = @() }

    $scriptPath = Join-Path $adapterDir $ScriptName
    if ($nativeHook -and $NativeName) {
        # The script stays on the command line as the native hook's fallback.
        $command = if ($script:BridgeIsWindows) { '"{0}" claude {1} "{2}"' -f $nativeHook, $NativeName, $scriptPath }
            else { "'{0}' claude {1} '{2}'" -f $nativeHook, $NativeName, $scriptPath }
    }
    elseif ($script:BridgeIsWindows) {
        $command = '"{0}" "{1}"' -f $hookLauncher, $scriptPath
    }
    else {
        # macOS runs hook commands through sh, so pwsh is named directly - by full path,
        # since a hook's PATH need not include Homebrew.
        $pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
        $command = "'{0}' -NoProfile -NonInteractive -File '{1}'" -f $pwsh, $scriptPath
    }
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

function Remove-BridgeClaudeAdapter {
    if (-not (Test-BridgeAdapterRoot -Directory $adapterDir -Context $installContext)) {
        throw 'The Claude adapter belongs to another installation; its hooks and files were preserved.'
    }
    foreach ($file in @($settingsPath, "$settingsPath.bak")) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $settings = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $before = $settings | ConvertTo-Json -Depth 12
        $after = Remove-BridgeHooks -Settings $settings | ConvertTo-Json -Depth 12
        if ($before -cne $after) { Set-Content -LiteralPath $file -Value $after -Encoding utf8 }
    }
    if (Test-Path -LiteralPath $adapterDir) { Remove-Item -LiteralPath $adapterDir -Recurse -Force }
    if (-not $installContext.Legacy) {
        $stateRoot = Get-BridgeRuntimePath -Name 'agent-bridge-claude' -Context $installContext
        if (Test-Path -LiteralPath $stateRoot) { Remove-Item -LiteralPath $stateRoot -Recurse -Force }
    }
    Set-BridgeAdapterEnrollment -Context $installContext -Client claude -Installed $false -KeepSelection:$KeepSelection
}

if ($env:BRIDGE_INSTALL_NORUN) { return }
if ($RepairOnly -and -not $Uninstall) { Assert-BridgeAdapterSelection -Context $installContext -Client claude }

# ------------------------------------------------------------------ uninstall
if ($Uninstall) {
    Write-Step 'Removing the Claude Code adapter'
    Stop-BridgeOwnedRuntime -Context $installContext
    Remove-BridgeClaudeAdapter
    Write-Step 'Done'
    return
}

# -------------------------------------------------------------------- install
if (-not (Test-Path -LiteralPath (Join-Path $coreDir 'decision-mqtt.ps1'))) {
    throw ("The main bridge is not installed at $coreDir. Run install.ps1 first - the " +
           'Claude adapter reuses its Home Assistant layer, daemon and dashboard.')
}

Write-Step "Installing the adapter into $adapterDir"
Set-BridgeAdapterRoot -Directory $adapterDir -Context $installContext
if (-not (Test-Path -LiteralPath $adapterDir)) {
    New-Item -ItemType Directory -Path $adapterDir -Force | Out-Null
}
Get-ChildItem (Join-Path $PSScriptRoot 'hooks') -File | ForEach-Object {
    Copy-Item $_.FullName $adapterDir -Force
    Write-Host "    $($_.Name)"
}
# The hooks run apart from the core, so they carry their own copy of the
# Windows/macOS layer.
Copy-Item (Join-Path (Split-Path $PSScriptRoot -Parent) 'hooks/bridge-platform.ps1') $adapterDir -Force
Copy-Item (Join-Path (Split-Path $PSScriptRoot -Parent) 'hooks/bridge-install-context.ps1') $adapterDir -Force
Write-Host '    bridge-platform.ps1'

Write-Step "Registering hooks in $settingsPath"
$settings = Remove-BridgeHooks -Settings (Get-Settings)
$settings = Add-BridgeHook -Settings $settings -EventName 'PreToolUse' -Matcher 'AskUserQuestion' `
    -ScriptName 'route-askuserquestion.ps1' -TimeoutSeconds 30 -NativeName 'ask'
# Notification is what carries permission prompts and idle waits, and unlike
# AskUserQuestion it is present in every build.
$settings = Add-BridgeHook -Settings $settings -EventName 'Notification' -Matcher '' `
    -ScriptName 'route-notification.ps1' -TimeoutSeconds 30 -NativeName 'notification'
$settings = Add-BridgeHook -Settings $settings -EventName 'Stop' -Matcher '' `
    -ScriptName 'notify-claude-stop.ps1' -TimeoutSeconds 30 -NativeName 'stop'
# SessionStart makes a session visible the moment it opens rather than after its first
# turn, and is what lets a dashboard launch confirm it started. UserPromptSubmit
# covers a session that was already open when this ran.
$settings = Add-BridgeHook -Settings $settings -EventName 'SessionStart' -Matcher '' `
    -ScriptName 'register-claude-session.ps1' -TimeoutSeconds 15 -NativeName 'register'
$settings = Add-BridgeHook -Settings $settings -EventName 'UserPromptSubmit' -Matcher '' `
    -ScriptName 'register-claude-session.ps1' -TimeoutSeconds 15 -NativeName 'register'
Save-Settings -Settings $settings
Set-BridgeAdapterEnrollment -Context $installContext -Client claude -Installed $true -RepairOnly:$RepairOnly
Write-Host '    PreToolUse (AskUserQuestion), Notification, Stop, SessionStart and UserPromptSubmit registered'
if ($nativeHook) { Write-Host "    through the native hook: $nativeHook" }

Write-Step 'Done'
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Yellow
Write-Host '  1. Restart any running Claude Code sessions so they pick up the hooks.'
Write-Host '  2. The bridge daemon finds Claude sessions on its own; no restart needed.'
Write-Host "     Logs: $(Get-BridgeRuntimeRoot -Context $installContext)"
