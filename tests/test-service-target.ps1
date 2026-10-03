#Requires -Version 7.0
<#
.SYNOPSIS
    A Home Assistant service call may name exactly one entity.

.DESCRIPTION
    On 2026-10-02 a script meant to press one session's stop button filtered
    GET /api/states down to that button and sent an entity id from the result. The
    selection collapsed: the POST carried thousands of ids instead of one, and Home
    Assistant pressed every button among them - 166 at 22:45:23 PT, confirmed in the
    logbook against the bridge's agent account.

    The whole UniFi fleet rebooted while the request was still open, PoE camera ports
    power-cycled, and vacuum consumable counters, ERV totals and bed-presence
    calibrations were reset. The call then returned 502, which looked like a transient
    blip, so the identical command ran again three minutes later.

    The exact cause of the collapse is not established - Invoke-RestMethod enumerates
    under both PowerShell 7.6.6 and Windows PowerShell 5.1, so the obvious explanation
    does not reproduce. That is precisely why these checks are about *shape* rather
    than about one idiom: what the bridge will and will not let through to the wire,
    whatever produced it.

    Nothing here reaches the network. The HTTP transport is stubbed, and the checks
    assert it was never entered for a refused call.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
$script:DecisionBridgeConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-service-target-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $__ok = $false
    try { $__ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($__ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

# Defined before anything calls it: a stub written below its caller is still out of
# scope at the call, which is how a suite once reached the live house.
$script:Sent = 0
function Invoke-DecisionHttpRequest { param($Parameters) $script:Sent++ }

$headers = @{ Authorization = 'Bearer test-only' }

function Test-Refusal {
    param([hashtable]$Data)
    $before = $script:Sent
    try {
        Invoke-HomeAssistantService -Domain 'button' -Service 'press' -Headers $headers -Data $Data
        return @{ Refused = $false; Sent = ($script:Sent - $before) }
    }
    catch {
        return @{ Refused = $true; Message = $_.Exception.Message; Sent = ($script:Sent - $before) }
    }
}

Write-Host '--- one named entity is the allowed shape ---'

Test-That 'a single entity id goes through' {
    $r = Test-Refusal -Data @{ entity_id = 'button.agent_bridge_abc123_stop' }
    -not $r.Refused -and $r.Sent -eq 1
}
Test-That 'a one-element list still means that one entity' {
    $r = Test-Refusal -Data @{ entity_id = @('button.agent_bridge_abc123_stop') }
    -not $r.Refused -and $r.Sent -eq 1
}
Test-That 'a call that names no entity at all is left alone' {
    # persistent_notification.create and mqtt.publish have no target and must keep working.
    $r = Test-Refusal -Data @{ title = 'Bridge updated'; message = 'hello' }
    -not $r.Refused -and $r.Sent -eq 1
}
Test-That 'an entity named inside target is accepted the same way' {
    $r = Test-Refusal -Data @{ target = @{ entity_id = 'text.agent_bridge_abc123_reply' }; value = '' }
    -not $r.Refused -and $r.Sent -eq 1
}

Write-Host ''
Write-Host '--- the 2026-10-02 fan-out is refused ---'

Test-That 'the collapsed pipeline filter cannot reach the wire' {
    # Exactly the shape that pressed 250 buttons: every id the state list returned.
    $everything = @(1..5108 | ForEach-Object { "button.entity_$_" })
    $r = Test-Refusal -Data @{ entity_id = $everything }
    $r.Refused -and $r.Sent -eq 0
}
Test-That 'and it says how many it was about to select' {
    $r = Test-Refusal -Data @{ entity_id = @('button.a', 'button.b', 'button.c') }
    $r.Message -match 'selects 3 values'
}
Test-That 'two entities are no more allowed than five thousand' {
    $r = Test-Refusal -Data @{ entity_id = @('button.a', 'button.b') }
    $r.Refused -and $r.Sent -eq 0
}

Write-Host ''
Write-Host '--- and so is every other way of meaning "everything" ---'

Test-That "entity_id 'all' is refused by name" {
    $r = Test-Refusal -Data @{ entity_id = 'all' }
    $r.Refused -and $r.Sent -eq 0 -and $r.Message -match 'every entity in the domain'
}
Test-That 'the check is not fooled by capitals or padding' {
    $r = Test-Refusal -Data @{ entity_id = '  ALL  ' }
    $r.Refused -and $r.Sent -eq 0
}
Test-That 'a comma-separated list in one string is refused' {
    $r = Test-Refusal -Data @{ entity_id = 'button.a,button.b' }
    $r.Refused -and $r.Sent -eq 0
}
Write-Host ''
Write-Host '--- a selector that expands is refused however few values it has ---'

Test-That 'one area id is still every button in that area' {
    # Codex caught this on PR #62: counting selector values waved it straight through.
    $r = Test-Refusal -Data @{ target = @{ area_id = 'living_room' } }
    $r.Refused -and $r.Sent -eq 0 -and $r.Message -match 'every matching entity'
}
Test-That 'one device id is still every entity on that device' {
    $r = Test-Refusal -Data @{ target = @{ device_id = 'abc123' } }
    $r.Refused -and $r.Sent -eq 0
}
Test-That 'a label selects everything wearing it' {
    $r = Test-Refusal -Data @{ target = @{ label_id = 'lights' } }
    $r.Refused -and $r.Sent -eq 0
}
Test-That 'a floor selects everything on it' {
    $r = Test-Refusal -Data @{ target = @{ floor_id = 'upstairs' } }
    $r.Refused -and $r.Sent -eq 0
}
Test-That 'an expanding selector in the body is refused too, not just in target' {
    $r = Test-Refusal -Data @{ area_id = 'living_room' }
    $r.Refused -and $r.Sent -eq 0
}
Test-That 'a valid entity id does not excuse an area id beside it' {
    $r = Test-Refusal -Data @{ entity_id = 'button.a_b'; target = @{ area_id = 'living_room' } }
    $r.Refused -and $r.Sent -eq 0
}
Test-That 'naming an entity in both the body and target selects both, so it is refused' {
    $r = Test-Refusal -Data @{ entity_id = 'button.a_b'; target = @{ entity_id = 'button.c_d' } }
    $r.Refused -and $r.Sent -eq 0 -and $r.Message -match 'both the body and target'
}
Test-That 'several device ids are refused too' {
    $r = Test-Refusal -Data @{ target = @{ device_id = @('d1', 'd2') } }
    $r.Refused -and $r.Sent -eq 0
}

Write-Host ''
Write-Host '--- a target that cannot be read is not assumed safe ---'

Test-That 'an empty entity id is refused rather than sent' {
    $r = Test-Refusal -Data @{ entity_id = '   ' }
    $r.Refused -and $r.Sent -eq 0
}
Test-That 'a null entity id is refused' {
    $r = Test-Refusal -Data @{ entity_id = $null }
    $r.Refused -and $r.Sent -eq 0
}
Test-That 'an id with no domain is refused' {
    $r = Test-Refusal -Data @{ entity_id = 'agent_bridge_abc123_stop' }
    $r.Refused -and $r.Sent -eq 0 -and $r.Message -match 'malformed'
}
Test-That 'a target the bridge cannot inspect is refused, not waved through' {
    $r = Test-Refusal -Data @{ target = 'button.a' }
    $r.Refused -and $r.Sent -eq 0
}

Remove-Item -LiteralPath $script:DecisionBridgeConfig.LogFile -Force -ErrorAction SilentlyContinue
if ($script:Failures) { Write-Host "`n$script:Failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "`nAll service-target checks passed" -ForegroundColor Green
