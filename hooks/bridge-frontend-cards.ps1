#Requires -Version 7.0
<#
.SYNOPSIS
    Checks - and where it safely can, fixes - the frontend cards the dashboard needs.

.DESCRIPTION
    The Agent Sessions dashboard is built from three custom Lovelace cards: card-mod,
    button-card and layout-card. They were a line in the README and nothing more, so a
    machine without them installed cleanly, connected to Home Assistant, reported
    success, and then rendered a dashboard of "Custom element doesn't exist" boxes.
    That is the worst kind of failure: everything says it worked.

    A card needs two separate things to be true, and they fail independently:

      * the JavaScript has to be downloaded to the Home Assistant host, which only
        HACS (or a manual copy) can do - nothing here can write files on that machine;
      * it has to be registered as a Lovelace resource, which is a single WebSocket
        command and therefore something this *can* do.

    So the second half is repaired automatically with -Register: if the file is being
    served but no resource points at it, the resource is created. The first half is
    reported with the exact HACS repository to install.

    Run directly for a readable summary, or with -Json for a machine-readable one.
    Dot-source it to get the functions without running anything.

.PARAMETER Register
    Register any card whose file is served but which has no Lovelace resource.

.PARAMETER Json
    Emit the result as JSON instead of a readable summary.

.PARAMETER Quiet
    Print nothing when every card is already present and registered.

.EXAMPLE
    pwsh -File bridge-frontend-cards.ps1 -Register
#>

[CmdletBinding()]
param(
    [switch]$Register,
    [switch]$Json,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# HACS serves everything it downloads from /hacsfiles/<repository name>/. The file
# name is what the resource URL has to end with, and is what identifies the card
# regardless of where it was installed from.
$script:BridgeFrontendCards = [ordered]@{
    'card-mod' = [ordered]@{
        File       = 'card-mod.js'
        HacsPath   = '/hacsfiles/lovelace-card-mod/card-mod.js'
        Repository = 'thomasloven/lovelace-card-mod'
        Why        = 'styles the session cards'
    }
    'button-card' = [ordered]@{
        File       = 'button-card.js'
        HacsPath   = '/hacsfiles/button-card/button-card.js'
        Repository = 'custom-cards/button-card'
        Why        = 'draws the decision buttons'
    }
    'layout-card' = [ordered]@{
        File       = 'layout-card.js'
        HacsPath   = '/hacsfiles/lovelace-layout-card/layout-card.js'
        Repository = 'thomasloven/lovelace-layout-card'
        Why        = 'arranges the dashboard view'
    }
}

function Test-BridgeCardResourceMatch {
    <#
        Whether a Lovelace resource URL refers to a given card.

        Matched on the file name, not the directory: HACS uses the repository name
        ("lovelace-card-mod"), a manual install might use anything, and every URL
        carries a cache-busting query string. Pure, so the matching is testable.
    #>
    param(
        [AllowEmptyString()][AllowNull()][string]$ResourceUrl,
        [Parameter(Mandatory)][string]$FileName
    )
    $url = ([string]$ResourceUrl)
    if ([string]::IsNullOrWhiteSpace($url)) { return $false }
    # Drop the query string, then compare the last path segment.
    $path = ($url -split '\?')[0]
    $leaf = ($path -split '[/\\]')[-1]
    return ($leaf -eq $FileName)
}

function Get-BridgeFrontendCardStatus {
    <#
        One record per required card: whether a Lovelace resource points at it, and
        whether its file is actually being served.

        -Resources and -FileProbe are injectable so the whole decision can be tested
        without a Home Assistant.
    #>
    param(
        [scriptblock]$Resources,
        [scriptblock]$FileProbe
    )

    if (-not $Resources) {
        $Resources = {
            # The helper already unwraps the per-command result, so this is the list.
            @((Invoke-CopilotHaWebSocket -Commands @(@{ type = 'lovelace/resources' }))[0])
        }
    }
    if (-not $FileProbe) {
        $FileProbe = {
            param($relativeUrl)
            $base = ([string]$script:DecisionBridgeConfig.HomeAssistantBaseUrl).TrimEnd('/')
            try {
                $response = Invoke-WebRequest -Uri "$base$relativeUrl" -TimeoutSec 8 `
                    -SkipHttpErrorCheck -ErrorAction Stop
                return ([int]$response.StatusCode -eq 200)
            }
            catch { return $false }
        }
    }

    $resourceList = @()
    $resourcesRead = $true
    try { $resourceList = @(& $Resources) }
    catch { $resourcesRead = $false }

    $records = @()
    foreach ($name in $script:BridgeFrontendCards.Keys) {
        $card = $script:BridgeFrontendCards[$name]
        $match = @($resourceList | Where-Object {
            # Guarded rather than $_.url: StrictMode makes a missing property a
            # terminating error, and a resource list is whatever Home Assistant has.
            $_ -and $_.PSObject.Properties['url'] -and
            (Test-BridgeCardResourceMatch -ResourceUrl $_.url -FileName $card.File)
        })
        $registered = [bool]($match.Count -gt 0)
        # Only worth asking when it is not already registered: a registered card is
        # working by definition, and every probe is a round trip. A probe that fails
        # means "cannot tell", which is the same outcome as "not there".
        $served = $false
        if (-not $registered) {
            try { $served = [bool](& $FileProbe $card.HacsPath) }
            catch { $served = $false }
        }

        $records += [pscustomobject]@{
            Name          = $name
            File          = $card.File
            HacsPath      = $card.HacsPath
            Repository    = $card.Repository
            Why           = $card.Why
            Registered    = $registered
            Served        = $registered -or $served
            ResourceUrl   = if ($registered) { [string]$match[0].url } else { '' }
            # Downloaded but never added as a resource: the half this can repair.
            NeedsResource = ((-not $registered) -and $served)
        }
    }

    [pscustomobject]@{
        ResourcesRead = $resourcesRead
        Cards         = $records
        Missing       = @($records | Where-Object { -not $_.Served } | Select-Object -Expand Name)
        Unregistered  = @($records | Where-Object { $_.NeedsResource } | Select-Object -Expand Name)
        AllReady      = ($resourcesRead -and -not @($records | Where-Object { -not $_.Registered }))
    }
}

function Register-BridgeFrontendCard {
    <#
        Adds a Lovelace resource for a card whose file is already being served.
        Returns $true when Home Assistant accepted it.

        -Invoker is injectable so the command can be verified without a live instance.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [scriptblock]$Invoker
    )
    if (-not $Invoker) { $Invoker = { param($commands) Invoke-CopilotHaWebSocket -Commands $commands } }
    try {
        [void](& $Invoker @(@{ type = 'lovelace/resources/create'; res_type = 'module'; url = $Url }))
        return $true
    }
    catch { return $false }
}

function Get-BridgeConfigPathCandidate {
    <#
        Where Home Assistant's configuration folder might be reachable from here.

        There is no API for writing a file into Home Assistant's `www` folder, so
        the reply card has to be delivered over a file share. Pure, so the ordering
        can be tested without touching a network.

        An explicitly configured path always wins; the derived share is only a
        convenience for the common HAOS setup, where the Samba add-on exposes the
        configuration folder as \\<host>\config.
    #>
    param(
        [AllowEmptyString()][AllowNull()][string]$Explicit,
        [AllowEmptyString()][AllowNull()][string]$BaseUrl
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { $candidates.Add($Explicit.TrimEnd('\')) }

    if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
        # Not $host: that is a read-only automatic variable and assigning to it throws.
        $hostName = ''
        try { $hostName = ([uri]$BaseUrl).Host } catch { $hostName = '' }
        if (-not [string]::IsNullOrWhiteSpace($hostName)) {
            $candidates.Add("\\$hostName\config")
        }
    }

    $candidates.ToArray()
}

function Get-BridgeReplyCardState {
    <#
        What Home Assistant already has: the registered resource, and whether the
        file behind it is actually being served.

        Both matter, and for different reasons. A registration with no file renders
        an error box on the dashboard; a file with no registration is never loaded.
        Only when both hold is the card usable, which is what lets an install on a
        second machine see that there is nothing to do.

        -Resources and -FileProbe are injectable so this is testable offline.
    #>
    param(
        [scriptblock]$Resources,
        [scriptblock]$FileProbe
    )

    if (-not $Resources) {
        $Resources = { @((Invoke-CopilotHaWebSocket -Commands @(@{ type = 'lovelace/resources' }))[0]) }
    }
    if (-not $FileProbe) {
        $FileProbe = {
            param($relativeUrl)
            $base = ([string]$script:DecisionBridgeConfig.HomeAssistantBaseUrl).TrimEnd('/')
            try {
                $response = Invoke-WebRequest -Uri "$base$relativeUrl" -TimeoutSec 8 `
                    -SkipHttpErrorCheck -ErrorAction Stop
                return ([int]$response.StatusCode -eq 200)
            }
            catch { return $false }
        }
    }

    $state = [pscustomobject]@{
        Registered = $false
        Served     = $false
        Url        = ''
        Version    = ''
        ResourceId = ''
        Readable   = $true
    }

    try {
        foreach ($resource in @(& $Resources)) {
            if ($null -eq $resource) { continue }
            if (-not $resource.PSObject.Properties['url']) { continue }
            $url = [string]$resource.url
            if (-not (Test-BridgeCardResourceMatch -ResourceUrl $url -FileName 'agent-bridge-reply-card.js')) { continue }
            $state.Registered = $true
            $state.Url = $url
            if ($resource.PSObject.Properties['id']) { $state.ResourceId = [string]$resource.id }
            if ($url -match '[?&]v=([^&]+)') { $state.Version = $Matches[1] }
            break
        }
    }
    catch {
        # Unreadable: say so rather than reporting the card as missing, which would
        # send an install off to rewrite a file that is probably already correct.
        $state.Readable = $false
        return $state
    }

    if ($state.Registered) {
        try { $state.Served = [bool](& $FileProbe ($state.Url)) } catch { $state.Served = $false }
    }

    $state
}

function Get-BridgeReplyCardFileVersion {
    <#
        The card's own version, read from its CARD_VERSION constant.

        The resource URL is cache-busted by this rather than by the bridge version,
        so a release that does not touch the card does not invalidate a URL that only
        a machine with config-share access could rewrite. Without that, every bridge
        release would leave share-less machines reporting a stale card forever.
    #>
    param([Parameter(Mandatory)][string]$SourcePath)

    try {
        $text = Get-Content -LiteralPath $SourcePath -Raw -ErrorAction Stop
        if ($text -match "CARD_VERSION\s*=\s*'([^']+)'") { return $Matches[1] }
    }
    catch { }
    ''
}

function Get-BridgeReplyCardUrl {
    <# The Lovelace resource URL for the reply card, cache-busted by version. #>
    param([AllowEmptyString()][AllowNull()][string]$Version)
    $url = '/local/agent-bridge-reply-card.js'
    if (-not [string]::IsNullOrWhiteSpace($Version)) { $url = "${url}?v=$Version" }
    $url
}

function Install-BridgeReplyCard {
    <#
        Makes sure Home Assistant is serving the reply card, copying it into the
        `www` folder over the configuration share only when that is actually needed.

        Home Assistant is shared between machines, so on the second and later
        machines the card is already installed and there is nothing to do. Checking
        that first is what stops a perfectly healthy install reporting a problem and
        asking for a share it does not need.

        Returns a record rather than throwing. A bridge that cannot deliver the card
        is still a working bridge - the dashboard falls back to the plain text box -
        so this must never fail an install.

        Action is one of:
          current   - already installed and up to date; nothing was written
          deployed  - copied and registered
          updated   - copied over an older copy and the resource re-pointed
          kept      - an older copy is in place and the share is unreachable, so the
                      card that is there carries on being used
          missing   - not installed and cannot be delivered
    #>
    param(
        [string]$SourcePath,
        [AllowEmptyString()][AllowNull()][string]$ConfigPath,
        [AllowEmptyString()][AllowNull()][string]$Version,
        [scriptblock]$Invoker,
        [scriptblock]$Resources,
        [scriptblock]$FileProbe
    )

    if ([string]::IsNullOrWhiteSpace($SourcePath)) {
        $SourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'frontend\agent-bridge-reply-card.js'
    }

    # The card carries its own version, which is what the resource URL is keyed on.
    if ([string]::IsNullOrWhiteSpace($Version) -and (Test-Path -LiteralPath $SourcePath)) {
        $Version = Get-BridgeReplyCardFileVersion -SourcePath $SourcePath
    }

    if (-not $Invoker) { $Invoker = { param($commands) Invoke-CopilotHaWebSocket -Commands $commands } }
    if (-not $Resources) {
        $Resources = { @((& $Invoker @(@{ type = 'lovelace/resources' }))[0]) }
    }

    $result = [pscustomobject]@{
        Ok         = $false
        Action     = 'missing'
        Deployed   = $false
        Registered = $false
        Path       = ''
        Url        = (Get-BridgeReplyCardUrl -Version $Version)
        Detail     = ''
    }

    # What Home Assistant already has decides whether the configuration share is
    # touched at all. Home Assistant is shared between machines, so on the second and
    # later machines the card is already there and correct, and an install that went
    # looking for a file share it does not need would report a problem that is not one.
    $state = Get-BridgeReplyCardState -Resources $Resources -FileProbe $FileProbe
    if (-not $state.Readable) {
        $result.Detail = 'could not read the Lovelace resource list'
        return $result
    }

    $present = ($state.Registered -and $state.Served)
    if ($present -and ([string]::IsNullOrWhiteSpace($Version) -or $state.Version -eq $Version)) {
        # Already installed and the right version: touch nothing.
        $result.Registered = $true
        $result.Url = $state.Url
        $result.Ok = $true
        $result.Action = 'current'
        return $result
    }

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        $result.Detail = "card source not found at $SourcePath"
        if ($present) { $result.Ok = $true; $result.Action = 'kept' }
        return $result
    }

    $baseUrl = ''
    try { $baseUrl = [string]$script:DecisionBridgeConfig.HomeAssistantBaseUrl } catch { $baseUrl = '' }

    $target = ''
    foreach ($candidate in (Get-BridgeConfigPathCandidate -Explicit $ConfigPath -BaseUrl $baseUrl)) {
        if (Test-Path -LiteralPath $candidate) { $target = $candidate; break }
    }

    if ([string]::IsNullOrWhiteSpace($target)) {
        if ($present) {
            $result.Ok = $true
            $result.Action = 'kept'
            $result.Detail = "the card already in Home Assistant (v$($state.Version)) is being used; " +
                             'this machine cannot reach the config share to update it'
        }
        else {
            $result.Detail = 'no reachable Home Assistant config folder'
        }
        return $result
    }

    try {
        $www = Join-Path $target 'www'
        if (-not (Test-Path -LiteralPath $www)) {
            New-Item -ItemType Directory -Path $www -Force | Out-Null
        }
        $destination = Join-Path $www 'agent-bridge-reply-card.js'
        Copy-Item -LiteralPath $SourcePath -Destination $destination -Force
        $result.Deployed = $true
        $result.Path = $destination
    }
    catch {
        $result.Detail = "could not copy the card: $($_.Exception.Message)"
        if ($present) { $result.Ok = $true; $result.Action = 'kept' }
        return $result
    }

    # Registering is separate from copying: an upgrade re-copies the file but must
    # update the existing resource rather than adding a second one pointing at the
    # same card with a stale version string.
    try {
        if ($state.Registered -and -not [string]::IsNullOrWhiteSpace($state.ResourceId)) {
            if ($state.Url -ne $result.Url) {
                [void](& $Invoker @(@{
                    type        = 'lovelace/resources/update'
                    resource_id = $state.ResourceId
                    url         = $result.Url
                }))
            }
            $result.Action = 'updated'
        }
        else {
            [void](& $Invoker @(@{ type = 'lovelace/resources/create'; res_type = 'module'; url = $result.Url }))
            $result.Action = 'deployed'
        }
        $result.Registered = $true
        $result.Ok = $true
    }
    catch {
        $result.Detail = "could not register the resource: $($_.Exception.Message)"
        if ($present) { $result.Ok = $true; $result.Action = 'kept' }
    }

    $result
}

# Dot-sourced for the functions alone; a real run never sets this.
if ($env:BRIDGE_FRONTEND_NORUN) { return }

. (Join-Path $PSScriptRoot 'decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot 'decision-mqtt.ps1')
. (Join-Path $PSScriptRoot 'decision-ha-websocket.ps1')

$status = Get-BridgeFrontendCardStatus

if ($Register -and $status.Unregistered) {
    foreach ($card in @($status.Cards | Where-Object { $_.NeedsResource })) {
        if (Register-BridgeFrontendCard -Url $card.HacsPath) {
            Write-Host "    registered $($card.Name) as a Lovelace resource" -ForegroundColor Green
        }
        else {
            Write-Host ("    could not register $($card.Name); add $($card.HacsPath) under " +
                        'Settings > Dashboards > Resources') -ForegroundColor Yellow
        }
    }
    # Re-read so the summary reflects what was just done.
    $status = Get-BridgeFrontendCardStatus
}

if ($Register) {
    # The bridge's own reply card. Unlike the three above it is not a HACS download,
    # so the installer delivers it: there is no Home Assistant API for writing a file
    # into the `www` folder, which leaves the configuration share as the only route.
    #
    # No version is passed: the card is keyed on its own CARD_VERSION, so a bridge
    # release that does not change the card leaves every machine's view of it alone.
    $configShare = Get-BridgeSetting 'homeAssistant.configPath' ''
    $replyCard = Install-BridgeReplyCard -ConfigPath $configShare

    if ($replyCard.Action -eq 'current') {
        if (-not $Quiet) {
            Write-Host '    reply card is already installed in Home Assistant' -ForegroundColor Green
        }
    }
    elseif ($replyCard.Action -eq 'deployed') {
        Write-Host "    reply card installed -> $($replyCard.Path)" -ForegroundColor Green
    }
    elseif ($replyCard.Action -eq 'updated') {
        Write-Host "    reply card updated -> $($replyCard.Path)" -ForegroundColor Green
    }
    elseif ($replyCard.Action -eq 'kept') {
        # Not a problem: the card is installed and working, this machine simply
        # cannot reach the share to write a newer copy. Another machine will.
        Write-Host "    reply card: $($replyCard.Detail)" -ForegroundColor DarkGray
    }
    else {
        Write-Host "    reply card not installed ($($replyCard.Detail))" -ForegroundColor Yellow
        Write-Host ('                 the dashboard falls back to the plain text box; ' +
                    'copy frontend\agent-bridge-reply-card.js into Home Assistant''s') -ForegroundColor DarkGray
        Write-Host ("                 config\www folder and add $($replyCard.Url) under " +
                    'Settings > Dashboards > Resources') -ForegroundColor DarkGray
    }
}

if ($Json) {
    $status | ConvertTo-Json -Depth 6
    return
}

if (-not $status.ResourcesRead) {
    Write-Host '    could not read the Lovelace resource list; skipping the card check' -ForegroundColor Yellow
    return
}

if ($status.AllReady) {
    if (-not $Quiet) { Write-Host '    card-mod, button-card and layout-card are all registered' -ForegroundColor Green }
    return
}

Write-Host ''
Write-Host 'The Agent Sessions dashboard needs three custom cards that are not installed:' -ForegroundColor Yellow
foreach ($card in @($status.Cards | Where-Object { -not $_.Registered })) {
    Write-Host ("    {0,-12} {1}" -f $card.Name, $card.Why)
    Write-Host ("                 HACS > Frontend > $($card.Repository)") -ForegroundColor DarkGray
}
Write-Host ''
Write-Host 'Without them the dashboard renders as "Custom element doesn''t exist" boxes.' -ForegroundColor DarkGray
Write-Host 'Install them in HACS, then run: agent-ha-bridge configure' -ForegroundColor DarkGray
