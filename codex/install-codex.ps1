<#
.SYNOPSIS
    Installs the Codex CLI adapter for the Copilot <-> Home Assistant bridge.

.DESCRIPTION
    Codex loads third-party hooks from plugins, so the adapter is packaged as one and
    registered through a local marketplace - the mechanism Codex supports for plugins
    that do not come from a catalogue.

    The main bridge must already be installed: this reuses its Home Assistant layer,
    its daemon and its dashboard.

    After installing you must **trust the hooks once**, in Codex itself. This is not
    optional and not something the installer can do for you: an untrusted Codex hook
    is skipped in complete silence, with no error and no log entry, which looks
    exactly like a broken install. Start Codex once and approve the prompt.

.PARAMETER TargetHome
    Install into this directory instead of $HOME. For testing without touching a real
    setup.

.PARAMETER Uninstall
    Remove the plugin, the marketplace registration and the adapter.
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
$bridgeRoot = Join-Path $installContext.BridgeHome 'codex-bridge'
$marketplaceName = 'agent-ha-bridge'
$pluginName = 'agent-ha-bridge'
$pluginRoot = Join-Path $bridgeRoot "plugins\$pluginName"
$coreDir = $installContext.HooksDir
$ownerFile = Join-Path $installContext.CodexHome 'agent-ha-bridge-owner.json'
$legacyBridgeRoot = Join-Path $installContext.CopilotHome 'codex-bridge'

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }

function Get-CodexExecutable {
    $command = Get-Command codex -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    if (-not $script:BridgeIsWindows) {
        foreach ($candidate in @('/opt/homebrew/bin/codex', '/usr/local/bin/codex', (Join-Path $HOME '.local/bin/codex'))) {
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
        return $null
    }
    # npm does not always create a shim on Windows, so fall back to the vendored binary.
    $vendored = Join-Path $env:APPDATA 'npm\node_modules\@openai\codex\vendor\x86_64-pc-windows-msvc\bin\codex.exe'
    if (Test-Path -LiteralPath $vendored) { return $vendored }
    $null
}

$codex = Get-CodexExecutable

function Invoke-BridgeCodexCommand {
    param([Parameter(Mandatory)][string[]]$Arguments)
    if (-not $codex) { throw 'Codex CLI is unavailable; its registration could not be verified and the adapter was preserved.' }
    $previousHome = $env:CODEX_HOME
    $previousConfig = $env:AGENT_HA_BRIDGE_CONFIG
    Push-Location $installContext.Home
    try {
        $env:CODEX_HOME = $installContext.CodexHome
        $env:AGENT_HA_BRIDGE_CONFIG = $installContext.ConfigPath
        $output = & $codex @Arguments 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "Codex registration command failed (exit $LASTEXITCODE); no further adapter cleanup was performed." }
        $output
    }
    finally {
        $env:CODEX_HOME = $previousHome
        $env:AGENT_HA_BRIDGE_CONFIG = $previousConfig
        Pop-Location
    }
}

function Get-BridgeCodexMarketplace {
    $owner = Read-BridgeInstallRecord -Path $ownerFile
    if ($owner -and (-not $owner['bridgeHome'] -or
        -not (Test-BridgeInstallPath ([string]$owner['bridgeHome']) $installContext.BridgeHome))) {
        throw 'This Codex home is registered to another bridge installation.'
    }
    $listing = Invoke-BridgeCodexCommand -Arguments @('plugin', 'marketplace', 'list', '--json') | ConvertFrom-Json
    if (-not $listing -or -not $listing.PSObject.Properties['marketplaces']) {
        throw 'Codex did not return a readable marketplace listing; its registrations were not changed.'
    }
    $matches = @($listing.marketplaces | Where-Object { $_.name -eq $marketplaceName })
    if ($matches.Count -gt 1) { throw 'The bridge marketplace name is ambiguous; its registrations were not changed.' }
    if ($matches.Count -eq 0) { return $null }
    if (-not $matches[0].PSObject.Properties['root'] -or
        (-not (Test-BridgeInstallPath ([string]$matches[0].root) $bridgeRoot) -and
         (-not $installContext.LegacyLayout -or -not (Test-BridgeInstallPath ([string]$matches[0].root) $legacyBridgeRoot)))) {
        throw 'The named Codex marketplace belongs to another installation; it was preserved.'
    }
    $matches[0]
}

function Remove-BridgeCodexAdapter {
    $record = Read-BridgeInstallRecord -Path $installContext.MetadataPath
    $recorded = $record -and $record.Contains('adapters') -and @($record['adapters']) -contains 'codex'
    if (-not (Test-Path -LiteralPath $bridgeRoot) -and -not (Test-Path -LiteralPath $ownerFile) -and
        -not $recorded -and (-not $installContext.LegacyLayout -or -not (Test-Path -LiteralPath $legacyBridgeRoot))) {
        Set-BridgeAdapterEnrollment -Context $installContext -Client codex -Installed $false -KeepSelection:$KeepSelection
        return
    }
    $marketplace = Get-BridgeCodexMarketplace
    $owner = Read-BridgeInstallRecord -Path $ownerFile
    if (-not $marketplace -and -not $owner) {
        throw 'Codex registration ownership is unknown; the adapter was preserved for a verified cleanup.'
    }
    [void](Invoke-BridgeCodexCommand -Arguments @('plugin', 'remove', "$pluginName@$marketplaceName"))
    if ($marketplace) { [void](Invoke-BridgeCodexCommand -Arguments @('plugin', 'marketplace', 'remove', $marketplaceName)) }
    if ($marketplace -and (Test-BridgeInstallPath ([string]$marketplace.root) $legacyBridgeRoot) -and
        (Test-Path -LiteralPath $legacyBridgeRoot)) {
        Remove-Item -LiteralPath $legacyBridgeRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $bridgeRoot) { Remove-Item -LiteralPath $bridgeRoot -Recurse -Force }
    if (Test-Path -LiteralPath $ownerFile) { Remove-Item -LiteralPath $ownerFile -Force }
    if (-not $installContext.Legacy) {
        $stateRoot = Get-BridgeRuntimePath -Name 'agent-bridge-codex' -Context $installContext
        if (Test-Path -LiteralPath $stateRoot) { Remove-Item -LiteralPath $stateRoot -Recurse -Force }
    }
    Set-BridgeAdapterEnrollment -Context $installContext -Client codex -Installed $false -KeepSelection:$KeepSelection
}

if ($env:BRIDGE_INSTALL_NORUN) { return }
if ($RepairOnly -and -not $Uninstall) { Assert-BridgeAdapterSelection -Context $installContext -Client codex }

# ------------------------------------------------------------------ uninstall
if ($Uninstall) {
    Write-Step 'Removing the Codex adapter'
    Stop-BridgeOwnedRuntime -Context $installContext
    Remove-BridgeCodexAdapter
    Write-Step 'Done'
    Write-Host 'Trust entries under [hooks.state] in the Codex config are left alone;' -ForegroundColor Yellow
    Write-Host 'they are harmless and Codex prunes them itself.' -ForegroundColor Yellow
    return
}

# -------------------------------------------------------------------- install
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ is required (found $($PSVersionTable.PSVersion))."
}
if (-not (Test-Path -LiteralPath (Join-Path $coreDir 'decision-mqtt.ps1'))) {
    throw ("The main bridge is not installed at $coreDir. Run install.ps1 first - the " +
           'Codex adapter reuses its Home Assistant layer, daemon and dashboard.')
}
if (-not $codex) {
    throw 'Codex CLI was not found. Install it with: npm install -g @openai/codex'
}
$existingMarketplace = Get-BridgeCodexMarketplace

Write-Step "Installing the adapter into $pluginRoot"
New-Item -ItemType Directory -Path (Join-Path $pluginRoot '.codex-plugin') -Force | Out-Null
$hooksTarget = Join-Path $pluginRoot 'hooks'
New-Item -ItemType Directory -Path $hooksTarget -Force | Out-Null
Set-BridgeAdapterRoot -Directory $hooksTarget -Context $installContext
Get-ChildItem (Join-Path $PSScriptRoot 'hooks') -File | ForEach-Object {
    Copy-Item $_.FullName $hooksTarget -Force
    Write-Host "    $($_.Name)"
}
# The hooks run apart from the core, so they carry their own copy of the
# Windows/macOS layer.
Copy-Item (Join-Path (Split-Path $PSScriptRoot -Parent) 'hooks/bridge-platform.ps1') $hooksTarget -Force
Copy-Item (Join-Path (Split-Path $PSScriptRoot -Parent) 'hooks/bridge-install-context.ps1') $hooksTarget -Force
Write-Host '    bridge-platform.ps1'

$versionFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'VERSION'
$version = if (Test-Path -LiteralPath $versionFile) { (Get-Content -LiteralPath $versionFile -Raw).Trim() } else { '1.0.0' }

[ordered]@{
    name        = $pluginName
    version     = $version
    description = 'Answer Codex prompts from Home Assistant.'
    hooks       = './hooks.json'
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $pluginRoot '.codex-plugin\plugin.json') -Encoding UTF8

# The command must NOT be shell-quoted. A quoted executable path fails with
# "hook exited with code 1"; the same command unquoted runs fine. pwsh is resolved
# from PATH for the same reason - its installed path contains a space.
$hookScript = Join-Path $hooksTarget 'codex-bridge-hook.ps1'
if ($hookScript -match '\s') {
    Write-Warning ("The adapter path contains a space ($hookScript). Codex cannot quote " +
                   'hook commands, so hooks may fail. Install under a path without spaces.')
}
$command = "pwsh -NoProfile -ExecutionPolicy Bypass -File $hookScript"
# macOS: by full path, since the hook's PATH need not include Homebrew. It has no space
# there (/opt/homebrew/bin/pwsh), so it needs no quoting either.
if (-not $script:BridgeIsWindows) {
    $pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    if ($pwsh -notmatch '\s') { $command = "$pwsh -NoProfile -File $hookScript" }
}

# The native hook (docs/fast-hooks.md), when the main installer put one in place that
# runs: a hook - one on every tool call - then takes tens of milliseconds, not half a
# second, and falls back to the script itself whenever the daemon is not running. Unquoted
# like the rest, so only from a path without a space. Changing the command makes Codex
# ask for the hooks to be trusted again, once.
. (Join-Path $PSScriptRoot '../hooks/bridge-native-hook.ps1')
$nativeHook = Get-BridgeNativeHookPath -BridgeHome $installContext.BridgeHome
$usesNativeHook = $nativeHook -and $nativeHook -notmatch '\s' -and $hookScript -notmatch '\s'
if ($usesNativeHook) { $command = "$nativeHook codex hook $hookScript" }

$events = [ordered]@{}
# SessionEnd is clamped to a 3 second timeout by Codex, which the hook accounts for.
# PermissionRequest runs before Codex shows its own approval UI; the hook writes
# nothing to stdout, which Codex reads as "no decision", so the terminal prompt still
# appears and the dashboard becomes a second way to answer rather than a replacement.
foreach ($eventName in @('SessionStart', 'UserPromptSubmit', 'PermissionRequest', 'PreToolUse', 'Stop', 'SessionEnd')) {
    $events[$eventName] = @(
        [ordered]@{ hooks = @([ordered]@{ type = 'command'; command = $command; timeout = 20 }) }
    )
}
[ordered]@{
    description = 'Copilot Home Assistant bridge'
    hooks       = $events
} | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $pluginRoot 'hooks.json') -Encoding UTF8
if ($usesNativeHook) { Write-Host "    hooks run through the native hook: $nativeHook" }

Write-Step 'Registering the local marketplace'
$marketplaceDir = Join-Path $bridgeRoot '.agents\plugins'
New-Item -ItemType Directory -Path $marketplaceDir -Force | Out-Null
[ordered]@{
    name      = $marketplaceName
    interface = [ordered]@{ displayName = 'Copilot HA bridge' }
    plugins   = @(
        [ordered]@{
            name     = $pluginName
            source   = [ordered]@{ source = 'local'; path = "./plugins/$pluginName" }
            policy   = [ordered]@{ installation = 'AVAILABLE'; authentication = 'ON_USE' }
            category = 'Productivity'
        }
    )
} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $marketplaceDir 'marketplace.json') -Encoding UTF8

if ($existingMarketplace) {
    [void](Invoke-BridgeCodexCommand -Arguments @('plugin', 'remove', "$pluginName@$marketplaceName"))
    [void](Invoke-BridgeCodexCommand -Arguments @('plugin', 'marketplace', 'remove', $marketplaceName))
}
[void](Invoke-BridgeCodexCommand -Arguments @('plugin', 'marketplace', 'add', $bridgeRoot))
Write-Host "    $marketplaceName"

Write-Step 'Installing the plugin'
[void](Invoke-BridgeCodexCommand -Arguments @('plugin', 'add', "$pluginName@$marketplaceName"))
if ($existingMarketplace -and (Test-BridgeInstallPath ([string]$existingMarketplace.root) $legacyBridgeRoot) -and
    (Test-Path -LiteralPath $legacyBridgeRoot)) {
    Remove-Item -LiteralPath $legacyBridgeRoot -Recurse -Force
}
[void][IO.Directory]::CreateDirectory($installContext.CodexHome)
@{ bridgeHome = $installContext.BridgeHome } | ConvertTo-Json | Set-Content -LiteralPath $ownerFile -Encoding utf8
Set-BridgeAdapterEnrollment -Context $installContext -Client codex -Installed $true -RepairOnly:$RepairOnly
Write-Host "    $pluginName@$marketplaceName"

Write-Step 'Done'
Write-Host ''
Write-Host 'One more step - this one matters:' -ForegroundColor Yellow
Write-Host '  Start Codex once and approve the hook trust prompt.' -ForegroundColor Yellow
Write-Host '  Until you do, Codex skips these hooks silently: no error, no log line,' -ForegroundColor Yellow
Write-Host '  which looks exactly like a broken install.' -ForegroundColor Yellow
Write-Host ''
Write-Host "Logs: $(Get-BridgeRuntimePath -Name 'agent-decision-bridge.log' -Context $installContext)"
