<#
.SYNOPSIS
    Checks for a newer release of the bridge and installs it.

.DESCRIPTION
    Installs are a clone plus install.ps1, so this is how you move to a new version
    without doing that by hand. It asks GitHub for the newest release, compares it
    with the version recorded at install time, and - with your agreement - downloads
    and installs it.

    Your configuration is preserved: the installer reads the existing config, backs it
    up, and writes it back with only what you pass on the command line changed.

    The daemon performs the same check a few times a day and surfaces the result as a
    Home Assistant `update` entity, so you normally learn about a new version there
    rather than by running this.

.PARAMETER Check
    Report what is available and exit without installing anything.

.PARAMETER Force
    Install the newest release even if it is not newer than what is installed. Use to
    repair a damaged install.

.PARAMETER Yes
    Skip the confirmation prompt.

.EXAMPLE
    .\update.ps1 -Check

.EXAMPLE
    .\update.ps1 -Yes
#>

[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Force,
    [switch]$Yes,
    [string]$TargetHome,
    [string]$InstallRoot
)

$ErrorActionPreference = 'Stop'

$bootstrapHooks = Join-Path $PSScriptRoot 'hooks'
. (Join-Path $bootstrapHooks 'bridge-platform.ps1')
$updateContext = Resolve-BridgeInstallContext -TargetHome $TargetHome -BridgeHome $InstallRoot -EntryDirectory $PSScriptRoot
$hooksDir = $updateContext.HooksDir
if (-not (Test-Path -LiteralPath (Join-Path $hooksDir 'bridge-update.ps1'))) { $hooksDir = $bootstrapHooks }
$previousConfig = $env:AGENT_HA_BRIDGE_CONFIG
try {
    $env:AGENT_HA_BRIDGE_CONFIG = $updateContext.ConfigPath
    . (Join-Path $hooksDir 'decision-bridge-common.ps1')
    . (Join-Path $hooksDir 'bridge-update.ps1')
}
finally { $env:AGENT_HA_BRIDGE_CONFIG = $previousConfig }

Write-Host '==> Checking for updates' -ForegroundColor Cyan
$status = Get-BridgeUpdateStatus -Force

Write-Host "    repository : $(Get-BridgeUpdateRepository)"
Write-Host "    installed  : $($status.Installed)"
Write-Host "    latest     : $(if ($status.Latest) { $status.Latest } else { 'not established' })"

if (-not $status.PSObject.Properties['State']) {
    Write-Host '    this older update helper cannot establish lookup status; nothing will be installed' -ForegroundColor Red
    exit 1
}
if ($status.State -in @('Unavailable', 'NotFound')) {
    Write-Host "    $($status.Detail)" -ForegroundColor Yellow
    exit 1
}
if ($Check) {
    Write-Host "    $($status.State); check only, nothing installed."
    return
}
if ($status.State -eq 'Current' -and -not $Force) {
    Write-Host '    no newer release found; nothing installed' -ForegroundColor Green
    return
}

if ($status.Notes) {
    Write-Host ''
    Write-Host 'Release notes:' -ForegroundColor Cyan
    ($status.Notes -split "`n") | Select-Object -First 20 | ForEach-Object { "    $_" }
}
Write-Host ''
Write-Host "    $($status.Url)"
Write-Host ''

if (-not $Yes) {
    $answer = Read-Host "Install $($status.Latest) now? [y/N]"
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host 'Nothing changed.'
        return
    }
}

Write-Host '==> Installing' -ForegroundColor Cyan
# Not detached: run in the foreground so the outcome is visible. The daemon uses the
# detached path instead, because the installer restarts the task it runs under.
$result = Invoke-BridgeSelfUpdate -Force:$Force -InstallRoot $updateContext.BridgeHome -TargetHome $(if ($updateContext.Isolated) { $updateContext.Home } else { '' })
Write-Host "    $($result.Detail)"
if ($result.State -eq 'Current') { return }
Write-Host ''
Write-Host "Log: $(Get-BridgeRuntimePath -Name 'agent-bridge-update.log' -Context $updateContext)"
if ($result.Success -isnot [bool] -or -not $result.Success -or $result.State -ne 'Completed') {
    exit 1
}
Write-Host 'Restart any running Copilot or Claude sessions to pick up the new hooks.' -ForegroundColor Yellow
