#Requires -Version 7.0
<#
.SYNOPSIS
    End-to-end wiring test for the Agent sessions card.

.DESCRIPTION
    The dashboard generator and the card are written in different languages and each
    has tests of its own - which is exactly how a card and the view that builds it
    once stayed broken through the middle while both ends passed. This runs the real
    card, under node, against the config Save-CopilotSessionDashboard really
    generated and the entity states the bridge's own MQTT publishers really produce.

    Nothing here touches Home Assistant: the publishes are captured and replayed
    through the same discovery rules Home Assistant applies to them.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-mqtt.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-ha-websocket.ps1')
# Its guard, so dot-sourcing it gives the functions without running the card check -
# which talks to Home Assistant and re-sources the files above, undoing every stub.
$env:BRIDGE_FRONTEND_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\bridge-frontend-cards.ps1')
$script:DecisionBridgeConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-status-card-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $__ok = $false
    try { $__ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($__ok) { Write-Host "  PASS  $Name" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

# --- 1. what the bridge publishes -------------------------------------------------

$script:Published = [System.Collections.Generic.List[object]]::new()
function Publish-CopilotMqttMessage {
    param([string]$Topic, [string]$Payload, [hashtable]$Headers, [switch]$Retain)
    $script:Published.Add([pscustomobject]@{ Topic = $Topic; Payload = $Payload })
}

$headers = @{ Authorization = 'Bearer test' }
$live = @{ Slug = 'dswett_home'; Machine = 'DSWETT-HOME' }
$dark = @{ Slug = 'dans_mbp'; Machine = 'Dans-MBP' }

Publish-CopilotMqttMachineOnlineConfig -Slug $live.Slug -MachineName $live.Machine -Headers $headers
Publish-CopilotMqttMachineHeartbeat -Slug $live.Slug -Headers $headers
Publish-CopilotMqttGlobalStatus -Sessions @(
    [pscustomobject]@{ node = 'copilot_aaa111bbb222'; name = 'Copilot: a task' }
    [pscustomobject]@{ node = 'copilot_ccc333ddd444'; name = 'Copilot: another' }
) -Capabilities @{ detailed = $true } -Slug $live.Slug -MachineName $live.Machine -Headers $headers
Publish-CopilotMqttUpdate -InstalledVersion '1.19.0' -LatestVersion '1.19.0' -Slug $live.Slug -Headers $headers

# The dark machine registered once and was then switched off. Its retained sensors
# survive - and its session count is one of them, still reading 3.
Publish-CopilotMqttMachineOnlineConfig -Slug $dark.Slug -MachineName $dark.Machine -Headers $headers
Publish-CopilotMqttGlobalStatus -Sessions @(
    [pscustomobject]@{ node = 'claude_eee555fff666'; name = 'Claude: old' }
    [pscustomobject]@{ node = 'claude_ggg777hhh888'; name = 'Claude: older' }
    [pscustomobject]@{ node = 'claude_iii999jjj000'; name = 'Claude: oldest' }
) -Capabilities @{} -Slug $dark.Slug -MachineName $dark.Machine -Headers $headers
Publish-CopilotMqttUpdate -InstalledVersion '1.17.1' -LatestVersion '1.17.1' -Slug $dark.Slug -Headers $headers

function Get-LastPublishedPayload {
    <# The last payload published to a topic, or $null when nothing ever was. #>
    param([string]$Topic)
    if ([string]::IsNullOrWhiteSpace($Topic)) { return $null }
    $match = @($script:Published | Where-Object { $_.Topic -eq $Topic }) | Select-Object -Last 1
    if ($null -eq $match) { return $null }
    [string]$match.Payload
}

function Get-PublishedHaStates {
    <#
        The entity states Home Assistant would hold, built from the discovery configs
        and state payloads just captured - the same rules it applies: the entity id
        comes from domain plus object_id, payload_on/payload_off map a binary sensor,
        an update entity's JSON state becomes its attributes, and a machine that has
        published no heartbeat is unavailable because the sensor expires.
    #>
    $states = @{}
    foreach ($message in $script:Published) {
        if ($message.Topic -notmatch '^homeassistant/([a-z_]+)/[^/]+/[^/]+/config$') { continue }
        $domain = $Matches[1]
        $config = $message.Payload | ConvertFrom-Json
        if (-not $config.PSObject.Properties['object_id']) { continue }
        $entityId = "$domain.$($config.object_id)"

        $raw = $null
        if ($config.PSObject.Properties['state_topic']) {
            $raw = Get-LastPublishedPayload -Topic ([string]$config.state_topic)
        }
        $state = if ($null -eq $raw) { 'unavailable' } else { [string]$raw }
        $attributes = @{}

        if ($domain -eq 'update' -and $null -ne $raw) {
            $body = $raw | ConvertFrom-Json
            foreach ($property in $body.PSObject.Properties) { $attributes[$property.Name] = $property.Value }
            $state = if ([string]$body.installed_version -ne [string]$body.latest_version) { 'on' } else { 'off' }
        }
        elseif ($config.PSObject.Properties['payload_on'] -and $state -eq [string]$config.payload_on) { $state = 'on' }
        elseif ($config.PSObject.Properties['payload_off'] -and $state -eq [string]$config.payload_off) { $state = 'off' }

        if ($config.PSObject.Properties['json_attributes_topic']) {
            $attrRaw = Get-LastPublishedPayload -Topic ([string]$config.json_attributes_topic)
            if ($attrRaw) {
                $body = $attrRaw | ConvertFrom-Json
                foreach ($property in $body.PSObject.Properties) { $attributes[$property.Name] = $property.Value }
            }
        }
        $states[$entityId] = @{ state = $state; attributes = $attributes }
    }
    $states
}

$haStates = Get-PublishedHaStates

Write-Host '--- the machines the bridge published ---'
Test-That 'the live machine is online' {
    $haStates["binary_sensor.agent_bridge_$($live.Slug)_online"].state -eq 'on'
} "[$($haStates["binary_sensor.agent_bridge_$($live.Slug)_online"].state)]"
Test-That 'and the one that was switched off has expired' {
    $haStates["binary_sensor.agent_bridge_$($dark.Slug)_online"].state -eq 'unavailable'
}
Test-That 'both still carry a retained session count' {
    $haStates["sensor.agent_bridge_$($live.Slug)_sessions"].state -eq '2' -and
    $haStates["sensor.agent_bridge_$($dark.Slug)_sessions"].state -eq '3'
}
Test-That 'and a version to report' {
    $haStates["update.agent_bridge_$($live.Slug)_update"].attributes['installed_version'] -eq '1.19.0'
}

# The Detailed activity switch is a Home Assistant helper created over the websocket
# rather than an MQTT entity, so it is added here the way the daemon names it - the
# same helper both the daemon and the dashboard resolve through.
$detailedEntity = Get-BridgeMachineEntityId -Domain 'input_boolean' -Key 'detailed_activity' -Slug $live.Slug
$haStates[$detailedEntity] = @{ state = 'off'; attributes = @{} }

# --- 2. the card config the dashboard really generates ----------------------------

$script:SavedConfig = $null
function Invoke-CopilotHaWebSocket {
    param([Parameter(Mandatory)][object[]]$Commands)
    $script:SavedConfig = $Commands[0].config
    @()
}

# Gated on the version the installer reads out of the card file itself, rather than a
# number written down again here.
$cardVersion = Get-BridgeReplyCardFileVersion -SourcePath (Join-Path $PSScriptRoot '..\frontend\agent-bridge-reply-card.js')

$sessions = @(
    [pscustomobject]@{ Node = 'copilot_aaa111bbb222'; Name = 'Copilot: a task'; Machine = $live.Machine; Kind = 'copilot' }
    [pscustomobject]@{ Node = 'copilot_ccc333ddd444'; Name = 'Copilot: another'; Machine = $live.Machine; Kind = 'copilot' }
)
$machines = @(
    [pscustomobject]@{ Slug = $live.Slug; Machine = $live.Machine; Online = $true; IncludeProfile = $false; IncludeResume = $true; IncludeAgent = $true; IncludeDetailed = $true }
    [pscustomobject]@{ Slug = $dark.Slug; Machine = $dark.Machine; Online = $false; IncludeProfile = $false; IncludeResume = $true; IncludeAgent = $false; IncludeDetailed = $false }
)
Save-CopilotSessionDashboard -Sessions $sessions -Machines $machines `
    -MachineSelector 'input_select.agent_bridge_launch_machine' `
    -ReplyCardUrl "/local/agent-bridge-reply-card.js?v=$cardVersion"

$dashboard = $script:SavedConfig | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
$cardConfig = @($dashboard.views[0].cards | Where-Object { $_.type -eq 'custom:agent-bridge-status-card' })[0]

Write-Host ''
Write-Host '--- the dashboard hands the card real entities ---'
Test-That 'the generated view carries a status card' { $null -ne $cardConfig }
Test-That 'every entity it reads is one the bridge actually publishes' {
    $wanted = @($cardConfig.machines | ForEach-Object {
        [string]$_.online; [string]$_.sessions; [string]$_.version
        if ($_.PSObject.Properties['detailed']) { [string]$_.detailed }
    })
    @($wanted | Where-Object { -not $haStates.ContainsKey($_) }).Count -eq 0
} "unpublished=[$(@(@($cardConfig.machines | ForEach-Object { [string]$_.online; [string]$_.sessions; [string]$_.version }) | Where-Object { -not $haStates.ContainsKey($_) }) -join ',')]"
Test-That 'and every decision it counts belongs to a live session' {
    (@($cardConfig.decisions) | Sort-Object) -join ',' -eq (@($sessions | ForEach-Object { "select.$($_.Node)_decision" }) | Sort-Object) -join ','
} "[$(@($cardConfig.decisions) -join ',')]"

# One session is waiting on an answer, the other is not.
$haStates["select.$($sessions[0].Node)_decision"] = @{ state = 'Awaiting answer...'; attributes = @{ question = 'Ship it?' } }
$haStates["select.$($sessions[1].Node)_decision"] = @{ state = 'Idle'; attributes = @{} }

# --- 3. the real card, on that config and those states ----------------------------

$driver = Join-Path $PSScriptRoot '..\frontend\test\drive-status-card.js'
$nodeExe = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $nodeExe) {
    # Skipping would let the whole chain rot unnoticed, which is the failure this
    # suite exists to prevent.
    Write-Host '  FAIL  node is required to run the card' -ForegroundColor Red
    exit 1
}

function Invoke-StatusCard {
    <# What the real card draws, and the service calls the given flips produce. #>
    param([string[]]$Flips = @(), [bool]$Open = $true)
    $job = @{
        config = $cardConfig
        states = $haStates
        open   = $Open
        flips  = @($Flips)
    } | ConvertTo-Json -Depth 20 -Compress
    $out = $job | & $nodeExe.Source $driver
    if ($LASTEXITCODE -ne 0) { throw "the card driver exited with $LASTEXITCODE" }
    $out | ConvertFrom-Json
}

$rendered = Invoke-StatusCard

Write-Host ''
Write-Host '--- and the card reads them the way the dashboard meant ---'
Test-That 'the folded line counts only what is running and what is waiting' {
    $rendered.summary -eq "Live sessions: 2 $([char]0x00b7) Pending decisions: 1"
} "[$($rendered.summary)]"
Test-That 'the machine that was switched off does not add its retained 3 to that' {
    $rendered.summary -notmatch 'Live sessions: 5'
}
Test-That 'a question waiting on you colours the line' { $rendered.waiting }
Test-That 'the live machine reports its sessions and its version' {
    @($rendered.rows | Where-Object { $_.machine -eq $live.Machine })[0].meta -eq "2 sessions $([char]0x00b7) 1.19.0"
} "[$(@($rendered.rows | Where-Object { $_.machine -eq $live.Machine })[0].meta)]"
Test-That 'and is marked online' { @($rendered.rows | Where-Object { $_.machine -eq $live.Machine })[0].online }
Test-That 'the one that was switched off says just that' {
    @($rendered.rows | Where-Object { $_.machine -eq $dark.Machine })[0].meta -eq 'offline'
}
Test-That 'the machine that can have a Detail switch has one' {
    $null -ne @($rendered.rows | Where-Object { $_.machine -eq $live.Machine })[0].toggle
}
Test-That 'and it opens on what the helper is actually holding' {
    @($rendered.rows | Where-Object { $_.machine -eq $live.Machine })[0].toggle.checked -eq $false
}
Test-That 'a machine whose bridge is too old for one is given none' {
    $null -eq @($rendered.rows | Where-Object { $_.machine -eq $dark.Machine })[0].toggle
}
Test-That 'folded, the machines are out of the way' { (Invoke-StatusCard -Open $false).hidden }

$flipped = Invoke-StatusCard -Flips @($live.Machine)
Write-Host ''
Write-Host '--- and a flicked switch reaches the helper the daemon polls ---'
Test-That 'nothing the flips asked for was missing' { @($flipped.missing).Count -eq 0 } "missing=[$(@($flipped.missing) -join ',')]"
Test-That 'exactly one service call is made' { @($flipped.calls).Count -eq 1 } "calls=$(@($flipped.calls).Count)"
Test-That 'on the helper this machine names, and no other' {
    @($flipped.calls)[0].data.entity_id -eq $detailedEntity
} "[$(@($flipped.calls)[0].data.entity_id)] wanted [$detailedEntity]"
Test-That 'through that helper''s own domain' {
    @($flipped.calls)[0].domain -eq 'input_boolean' -and @($flipped.calls)[0].service -eq 'toggle'
}
Test-That 'and the switch ends up where the helper did' {
    @($flipped.rows | Where-Object { $_.machine -eq $live.Machine })[0].toggle.checked -eq $true
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All status card checks passed' -ForegroundColor Green
