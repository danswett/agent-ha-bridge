#Requires -Version 7.0
<#
    Publishes the new permissions selector under a throwaway machine slug, checks that
    Home Assistant really creates it with the options the daemon assumes, drives a
    selection through it, then removes it again.

    Not a unit test: 1.14.1 and 1.14.4 were both features that passed their tests and
    could not appear in a browser, so the discovery payload is worth proving against a
    real instance. A scratch slug and a device of its own mean no live machine's
    entities are touched.

    The entity is found by diffing the select list rather than by predicting its id.
    Home Assistant builds an MQTT entity id from device name plus entity name, ignores
    object_id, and then *keeps the first id it assigned* even when the device is
    renamed later - so the id a fresh publish produces is not something to guess at.
    The daemon renames these afterwards (Set-CopilotMqttNewSessionEntityIds), which
    has not happened here.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This one deliberately talks to the real instance - that is the whole point of it -
# so it opts past the guard that stops unit tests doing so by accident.
$env:BRIDGE_ALLOW_TEST_HTTP = '1'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-mqtt.ps1')

$slug = 'bridge_live_check'
$headers = Get-HomeAssistantHeaders
$base = $script:DecisionBridgeConfig.HomeAssistantBaseUrl.TrimEnd('/')
$node = Get-CopilotMqttMachineNode -Slug $slug
$prefix = $script:CopilotMqttConfig.DiscoveryPrefix
$topic = "$prefix/select/$node/new_permissions/config"

$failures = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:failures++ }
}

function Get-SelectIds {
    @((Invoke-RestMethod -Uri "$base/api/states" -Headers $headers -TimeoutSec 20) |
        Where-Object { $_.entity_id -like 'select.*' } | ForEach-Object { [string]$_.entity_id })
}

function Get-State {
    param([string]$Id)
    try { Invoke-RestMethod -Uri "$base/api/states/$Id" -Headers $headers -TimeoutSec 15 } catch { $null }
}

$before = Get-SelectIds
Write-Host "publishing $topic ($($before.Count) selects before)"

$payload = @{
    name          = 'New session permissions'
    unique_id     = "agent_bridge_${slug}_new_permissions"
    object_id     = "agent_bridge_${slug}_new_permissions"
    command_topic = "$(Get-CopilotMqttMachineTopicRoot -Slug $slug)/newsession/permissions/set"
    options       = @(Get-BridgePermissionOptions)
    icon          = 'mdi:shield-key-outline'
    device        = @{
        name         = 'AI Agent Bridge (Live Check)'
        manufacturer = 'AI CLI bridge'
        identifiers  = @("agent_bridge_$slug")
    }
}
Publish-CopilotMqttMessage -Topic $topic -Payload ($payload | ConvertTo-Json -Depth 8 -Compress) -Headers $headers -Retain

try {
    $created = @()
    for ($i = 0; $i -lt 20 -and $created.Count -eq 0; $i++) {
        Start-Sleep -Milliseconds 500
        $created = @(Get-SelectIds | Where-Object { $before -notcontains $_ })
    }

    Check 'Home Assistant accepted the discovery payload and created one entity' ($created.Count -eq 1) ($created -join ', ')
    if ($created.Count -eq 1) {
        $id = $created[0]
        $state = Get-State -Id $id
        Write-Host "    created as $id = '$($state.state)'"

        $options = @($state.attributes.options)
        Check 'it offers exactly the two options the bridge publishes' `
            (($options -join '|') -eq 'Ask permission|Allow all') ($options -join '|')
        Check 'and the cautious one is first, so an untouched card is the cautious one' `
            ($options[0] -eq 'Ask permission')

        # What the daemon reads back is what Test-BridgePermissionAllowsAll judges, so
        # drive it through Home Assistant and read the real state, not the payload.
        Invoke-HomeAssistantService -Domain 'select' -Service 'select_option' -Headers $headers `
            -Data @{ entity_id = $id; option = 'Allow all' } | Out-Null
        Start-Sleep -Milliseconds 1200
        $after = Get-State -Id $id
        Check 'a selection round-trips through Home Assistant with its casing intact' `
            ([string]$after.state -ceq 'Allow all') ([string]$after.state)
        Check 'and the daemon reads that as waiving permissions' `
            ([bool](Test-BridgePermissionAllowsAll -Value ([string]$after.state)))

        Invoke-HomeAssistantService -Domain 'select' -Service 'select_option' -Headers $headers `
            -Data @{ entity_id = $id; option = 'Ask permission' } | Out-Null
        Start-Sleep -Milliseconds 1200
        $back = Get-State -Id $id
        Check 'the other option reads as asking' `
            (-not (Test-BridgePermissionAllowsAll -Value ([string]$back.state))) ([string]$back.state)
    }
}
finally {
    Write-Host 'removing the scratch entity'
    Publish-CopilotMqttMessage -Topic $topic -Payload '' -Headers $headers -Retain
    $left = @('still there')
    for ($i = 0; $i -lt 10 -and $left.Count -gt 0; $i++) {
        Start-Sleep -Seconds 1
        $left = @(Get-SelectIds | Where-Object { $before -notcontains $_ })
    }
    Check 'the scratch entity is gone and the select list is back as it was' ($left.Count -eq 0) ($left -join ', ')
}

if ($failures -gt 0) { Write-Host "`n$failures failed" -ForegroundColor Red; exit 1 }
Write-Host "`nall passed" -ForegroundColor Green
