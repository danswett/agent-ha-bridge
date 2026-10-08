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
# What the marketplace and plugin were called before the rename. The bridge removed
# the directory and left these registered, which is a state Codex cannot recover from
# on its own: see Remove-BridgeCodexLegacyRegistration.
$legacyMarketplaceName = 'copilot-ha-bridge'
$legacyPluginName = 'copilot-ha-bridge'
$codexConfigFile = Join-Path $installContext.CodexHome 'config.toml'

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }

function Get-CodexExecutable {
    $command = Get-Command codex -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    if (-not $script:BridgeIsWindows) {
        # The same places the launcher's Find-BridgeUnixCommand looks. They drifted:
        # MacPorts installs to /opt/local/bin, which the launcher knew about and this
        # did not, so on a MacPorts machine the installer reported Codex as missing
        # and skipped registering the adapter - while the launcher went on finding
        # the CLI and starting sessions that had no bridge adapter to report through
        # (#125).
        foreach ($candidate in @('/opt/homebrew/bin/codex', '/usr/local/bin/codex', '/opt/local/bin/codex',
                (Join-Path $HOME '.local/bin/codex'), (Join-Path $HOME '.npm-global/bin/codex'),
                (Join-Path $HOME '.bun/bin/codex'))) {
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

function Get-BridgeCodexLegacyRegistration {
    <#        That this Codex home belongs to this installation. Read from the owner file, so
        The legacy marketplace and plugin registration, when this Codex still carries
        one and it is ours to remove: { Text, Present, Owned, Source }.

        Ours means the recorded source is the directory this installer used to put the
        adapter in, or a directory that is no longer there at all. A marketplace of
        that name pointing somewhere else belongs to something else and is left alone.
    #>
    if (-not (Test-Path -LiteralPath $codexConfigFile)) {
        return [pscustomobject]@{ Text = ''; Present = $false; Owned = $false; Source = '' }
    }
    $text = Get-Content -LiteralPath $codexConfigFile -Raw -ErrorAction Stop
    $pattern = '(?m)^\[marketplaces\.' + [regex]::Escape($legacyMarketplaceName) + '\]\s*$'
    if ($text -notmatch $pattern) {
        return [pscustomobject]@{ Text = $text; Present = $false; Owned = $false; Source = '' }
    }
    # The source line belongs to the block that follows the header, so read only as
    # far as the next section rather than the first source= anywhere in the file.
    $start = [regex]::Match($text, $pattern).Index
    $rest = $text.Substring($start)
    $next = [regex]::Match($rest.Substring(1), '(?m)^\[')
    $block = if ($next.Success) { $rest.Substring(0, $next.Index + 1) } else { $rest }
    $source = ''
    $sourceMatch = [regex]::Match($block, "(?m)^\s*source\s*=\s*['`"](.*?)['`"]\s*$")
    if ($sourceMatch.Success) { $source = $sourceMatch.Groups[1].Value }
    # Codex records the extended-length form on Windows; the bridge's own paths never
    # carry it, so comparing without stripping it never matches.
    $plain = $source -replace '^\\\\\?\\', ''
    $owned = $false
    if ($plain) {
        $owned = (Test-BridgeInstallPath $plain $legacyBridgeRoot) -or -not (Test-Path -LiteralPath $plain)
    }
    [pscustomobject]@{ Text = $text; Present = $true; Owned = $owned; Source = $plain }
}

function Remove-BridgeCodexTomlSection {
    <# One TOML section and its body, from its header to the next one. #>
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Header)

    $pattern = '(?m)^' + [regex]::Escape($Header) + '\s*$'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $Text }
    $rest = $Text.Substring($match.Index)
    $next = [regex]::Match($rest.Substring(1), '(?m)^\[')
    $length = if ($next.Success) { $next.Index + 1 } else { $rest.Length }
    $Text.Remove($match.Index, $length)
}

function Remove-BridgeCodexLegacyRegistration {
    <#
        Takes the pre-rename marketplace and plugin registration out of Codex.

        The installer used to delete the legacy adapter directory and leave it
        registered. Codex loads every configured marketplace, so that one dead entry
        failed the whole plugin subsystem:

            Error: failed to load marketplace(s):
            - `copilot-ha-bridge` at ...\.copilot\codex-bridge: marketplace root does
              not contain a supported manifest

        which broke every `codex plugin` command - including the ones this installer
        needs, so each run reported "Codex registration command failed (exit 1)" after
        installing correctly, and `agent-ha-bridge update` exited non-zero on a healthy
        install. Worse, plugin hooks could no longer be resolved, so Codex sessions
        stopped registering and simply never appeared on the dashboard.

        It is self-perpetuating: the entry breaks the very commands that would remove
        it. So the supported commands are tried first, and the config file is rewritten
        only when they could not do it - which, once this state is reached, is always.
    #>
    $legacy = Get-BridgeCodexLegacyRegistration
    if (-not $legacy.Present) { return }
    if (-not $legacy.Owned) {
        Write-Host "    left '$legacyMarketplaceName' alone: it points at $($legacy.Source)" -ForegroundColor Yellow
        return
    }

    Write-Step "Removing the pre-rename '$legacyMarketplaceName' registration"
    foreach ($arguments in @(
            @('plugin', 'remove', "$legacyPluginName@$legacyMarketplaceName"),
            @('plugin', 'marketplace', 'remove', $legacyMarketplaceName))) {
        # Failure is expected and survivable here - the config rewrite below is the
        # fallback - but a test guard is not an ordinary failure and must propagate
        # rather than become a quiet fallback that looks like it worked.
        try { [void](Invoke-BridgeCodexCommand -Arguments $arguments) }
        catch {
            if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
        }
    }

    $after = Get-BridgeCodexLegacyRegistration
    if (-not $after.Present) {
        Write-Host '    removed' -ForegroundColor Green
        return
    }
    # Codex could not do it, because this is the state that stops it doing anything.
    $text = $after.Text
    $text = Remove-BridgeCodexTomlSection -Text $text -Header "[marketplaces.$legacyMarketplaceName]"
    $text = Remove-BridgeCodexTomlSection -Text $text -Header "[plugins.`"$legacyPluginName@$legacyMarketplaceName`"]"
    if ($text -eq $after.Text) { return }
    Copy-Item -LiteralPath $codexConfigFile -Destination "$codexConfigFile.agent-ha-bridge.bak" -Force
    Set-Content -LiteralPath $codexConfigFile -Value $text -Encoding utf8 -NoNewline
    Write-Host "    removed from config.toml (backup: $(Split-Path "$codexConfigFile.agent-ha-bridge.bak" -Leaf))" -ForegroundColor Green
}

function Assert-BridgeCodexOwnership {
    <#        That this Codex home belongs to this installation. Read from the owner file, so
        it still holds when the Codex CLI cannot be reached - the adapter files can then
        be refreshed safely without asking Codex anything.
    #>
    $owner = Read-BridgeInstallRecord -Path $ownerFile
    if ($owner -and (-not $owner['bridgeHome'] -or
        -not (Test-BridgeInstallPath ([string]$owner['bridgeHome']) $installContext.BridgeHome))) {
        throw 'This Codex home is registered to another bridge installation.'
    }
}

function Get-BridgeCodexMarketplace {
    Assert-BridgeCodexOwnership
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

# Before anything asks Codex a question, and before the uninstall branch below: a
# stale pre-rename registration makes every plugin command fail, so uninstalling on
# the very machines this repairs would fail too - Remove-BridgeCodexAdapter asks Codex
# to deregister. Cleanup runs without the CLI if it has to, by rewriting config.toml,
# so it belongs ahead of the Codex-not-found guard as well.
Remove-BridgeCodexLegacyRegistration

# ------------------------------------------------------------------ uninstall
if ($Uninstall) {
    Write-Step 'Removing the Codex adapter'
    Set-BridgeAdapterEnrollment -Context $installContext -Client codex -Installed $false -KeepSelection:$KeepSelection -KeepAdapterRecord
    Stop-BridgeOwnedRuntime -Context $installContext -Roles setup-codex
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
Assert-BridgeCodexOwnership

# The adapter files go in before anything that needs the Codex CLI. These are what the
# daemon dot-sources, so a release that moves the core must not be able to leave the
# previous copy behind: on 2026-10-06 a stale marketplace registration made
# `codex plugin marketplace list` exit 1, this script threw before reaching the copy,
# install.ps1 only warned - and the 9/30 bridge-platform.ps1 left in place shadowed the
# core's, removing -AsObservation and killing session discovery for every adapter, not
# just Codex. Registration still needs the CLI, and still fails loudly below.
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

if (-not $codex) {
    throw 'Codex CLI was not found. Install it with: npm install -g @openai/codex'
}
$existingMarketplace = Get-BridgeCodexMarketplace

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
