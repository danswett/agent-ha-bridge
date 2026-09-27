#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the dashboard's frontend card check.

.DESCRIPTION
    The Agent Sessions dashboard is drawn with card-mod, button-card and layout-card.
    They were a line in the README and nothing else: a machine without them installed
    cleanly, connected, reported success, and then rendered a dashboard of "Custom
    element doesn't exist" boxes.

    A card needs two independent things to be true - the file downloaded to the Home
    Assistant host, and a Lovelace resource pointing at it - and the second is a single
    WebSocket command, so the installer repairs that half itself.

    Nothing here touches Home Assistant: the resource list and the file probe are both
    injected. bridge-frontend-cards.ps1 is dot-sourced with BRIDGE_FRONTEND_NORUN set
    so its functions load without it running or loading the runtime layer.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:BRIDGE_FRONTEND_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\bridge-frontend-cards.ps1')
Remove-Item Env:\BRIDGE_FRONTEND_NORUN -ErrorAction SilentlyContinue

$script:Failures = 0
function Test-That {
    # The locals are underscored because an assertion scriptblock resolves its free
    # variables in this scope: a plain $ok here silently shadows an $ok the caller set
    # up for the assertion to read.
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $__ok = $false
    try { $__ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($__ok) { Write-Host "  PASS  $Name" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

function New-Resource { param([string]$Url) [pscustomobject]@{ url = $Url; type = 'module'; id = 'x' } }

# The real shapes, taken from a live instance: HACS names the directory after the
# repository and appends a cache-busting tag.
$hacsResources = @(
    (New-Resource '/hacsfiles/lovelace-card-mod/card-mod.js?hacstag=190927524421'),
    (New-Resource '/hacsfiles/button-card/button-card.js?hacstag=146194325701'),
    (New-Resource '/hacsfiles/lovelace-layout-card/layout-card.js?hacstag=156434866247'),
    (New-Resource '/hacsfiles/bar-card/bar-card.js?hacstag=163363577320'),
    (New-Resource '/local/gsd-icons.js')
)

Write-Host '--- matching a resource URL to a card ---'
Test-That 'a HACS URL with a cache tag matches' {
    Test-BridgeCardResourceMatch -ResourceUrl '/hacsfiles/lovelace-card-mod/card-mod.js?hacstag=19' -FileName 'card-mod.js'
}
Test-That 'the directory name is irrelevant, only the file matters' {
    Test-BridgeCardResourceMatch -ResourceUrl '/local/anywhere/card-mod.js' -FileName 'card-mod.js'
}
Test-That 'a plain URL with no query matches' {
    Test-BridgeCardResourceMatch -ResourceUrl '/hacsfiles/button-card/button-card.js' -FileName 'button-card.js'
}
Test-That 'a different card does not match' {
    -not (Test-BridgeCardResourceMatch -ResourceUrl '/hacsfiles/bar-card/bar-card.js' -FileName 'card-mod.js')
}
Test-That 'a substring is not a match - bar-card is not button-card' {
    -not (Test-BridgeCardResourceMatch -ResourceUrl '/hacsfiles/bar-card/bar-card.js' -FileName 'card.js')
}
Test-That 'card-mod.js does not match a card-mod-theme file' {
    -not (Test-BridgeCardResourceMatch -ResourceUrl '/hacsfiles/x/card-mod-theme.js' -FileName 'card-mod.js')
}
Test-That 'an empty URL does not match' {
    -not (Test-BridgeCardResourceMatch -ResourceUrl '' -FileName 'card-mod.js')
}
Test-That 'a null URL does not match' {
    -not (Test-BridgeCardResourceMatch -ResourceUrl $null -FileName 'card-mod.js')
}

Write-Host '--- every required card registered ---'
$script:Probes = 0
$status = Get-BridgeFrontendCardStatus -Resources { $hacsResources } `
    -FileProbe { param($u) $script:Probes++; $true }
Test-That 'it reports everything ready' { $status.AllReady }
Test-That 'nothing is missing' { @($status.Missing).Count -eq 0 }
Test-That 'nothing needs registering' { @($status.Unregistered).Count -eq 0 }
Test-That 'all three cards are accounted for' { @($status.Cards).Count -eq 3 }
Test-That 'a registered card is not probed over HTTP - it is working by definition' {
    $script:Probes -eq 0
}
Test-That 'the matched resource URL is reported back' {
    (@($status.Cards | Where-Object { $_.Name -eq 'card-mod' })[0].ResourceUrl) -match 'hacstag'
}

Write-Host '--- downloaded but never registered: the half this can repair ---'
$partial = @($hacsResources | Where-Object { $_.url -notmatch 'layout-card' })
$status = Get-BridgeFrontendCardStatus -Resources { $partial } -FileProbe { param($u) $true }
Test-That 'it is not reported as ready' { -not $status.AllReady }
Test-That 'the card is flagged as needing a resource' { $status.Unregistered -contains 'layout-card' }
Test-That 'it is not reported as missing, because the file is there' {
    @($status.Missing).Count -eq 0
}
Test-That 'the other two are left alone' { @($status.Unregistered).Count -eq 1 }

Write-Host '--- not downloaded at all: only HACS can fix that ---'
$status = Get-BridgeFrontendCardStatus -Resources { @() } -FileProbe { param($u) $false }
Test-That 'it is not reported as ready' { -not $status.AllReady }
Test-That 'all three are missing' { @($status.Missing).Count -eq 3 }
Test-That 'none is claimed to be repairable' { @($status.Unregistered).Count -eq 0 }
Test-That 'each carries the HACS repository to install' {
    @($status.Cards | Where-Object { $_.Repository -match '^[\w.-]+/[\w.-]+$' }).Count -eq 3
}
Test-That 'each explains what it is for' {
    @($status.Cards | Where-Object { $_.Why }).Count -eq 3
}

Write-Host '--- Home Assistant unreachable ---'
$status = Get-BridgeFrontendCardStatus -Resources { throw 'connection refused' } -FileProbe { param($u) $false }
Test-That 'it reports that the resource list could not be read' { -not $status.ResourcesRead }
Test-That 'it does not claim everything is ready' { -not $status.AllReady }
Test-That 'it does not throw' { $null -ne $status }

Write-Host '--- an odd resource list does not take the check down ---'
Test-That 'a resource with no url property is skipped, not fatal' {
    # StrictMode makes a missing property a terminating error, and the resource list
    # is whatever that Home Assistant happens to hold.
    $odd = @([pscustomobject]@{ type = 'module' }, (New-Resource '/hacsfiles/lovelace-card-mod/card-mod.js'))
    $result = Get-BridgeFrontendCardStatus -Resources { $odd } -FileProbe { param($u) $false }
    @($result.Cards | Where-Object { $_.Name -eq 'card-mod' })[0].Registered
}
Test-That 'a null entry is skipped too' {
    $odd = @($null, (New-Resource '/hacsfiles/button-card/button-card.js'))
    $result = Get-BridgeFrontendCardStatus -Resources { $odd } -FileProbe { param($u) $false }
    @($result.Cards | Where-Object { $_.Name -eq 'button-card' })[0].Registered
}
Test-That 'an empty resource list is handled' {
    $null -ne (Get-BridgeFrontendCardStatus -Resources { @() } -FileProbe { param($u) $false })
}
Test-That 'a file probe that throws does not take the check down' {
    $result = Get-BridgeFrontendCardStatus -Resources { @() } -FileProbe { param($u) throw 'timeout' }
    @($result.Missing).Count -eq 3
}

Write-Host '--- registering a resource ---'
$script:Sent = $null
$ok = Register-BridgeFrontendCard -Url '/hacsfiles/lovelace-layout-card/layout-card.js' `
    -Invoker { param($commands) $script:Sent = $commands; @('ok') }
Test-That 'it reports success' { $ok }
Test-That 'it sends lovelace/resources/create' { $script:Sent[0].type -eq 'lovelace/resources/create' }
Test-That 'it registers the card as a module' { $script:Sent[0].res_type -eq 'module' }
Test-That 'it registers the URL it was given' {
    $script:Sent[0].url -eq '/hacsfiles/lovelace-layout-card/layout-card.js'
}
Test-That 'a rejected command is reported, not thrown' {
    -not (Register-BridgeFrontendCard -Url '/x.js' -Invoker { throw 'not allowed in YAML mode' })
}

Write-Host '--- the catalogue matches what the dashboard actually uses ---'
Test-That 'the three cards the README requires are the three checked' {
    (@($script:BridgeFrontendCards.Keys) -join ',') -eq 'card-mod,button-card,layout-card'
}
Test-That 'every card has a HACS path under /hacsfiles/' {
    @($script:BridgeFrontendCards.Keys | Where-Object {
        $script:BridgeFrontendCards[$_].HacsPath -notmatch '^/hacsfiles/'
    }).Count -eq 0
}
Test-That 'every HACS path ends with the file name used for matching' {
    @($script:BridgeFrontendCards.Keys | Where-Object {
        -not (Test-BridgeCardResourceMatch -ResourceUrl $script:BridgeFrontendCards[$_].HacsPath `
                -FileName $script:BridgeFrontendCards[$_].File)
    }).Count -eq 0
}
Test-That 'the README still names all three, so the docs cannot drift' {
    $readme = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\README.md') -Raw
    @($script:BridgeFrontendCards.Keys | Where-Object { $readme -notmatch [regex]::Escape($_) }).Count -eq 0
}
Test-That 'the uninstaller knows to remove the checker' {
    (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\uninstall.ps1') -Raw) -match 'bridge-frontend-cards\.ps1'
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
