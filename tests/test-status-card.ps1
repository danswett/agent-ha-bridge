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
# survive - and so do its session entities, which is why removing it has to take them
# with it.
$darkSessionIds = @(
    'e5f6a7b8-1111-2222-3333-444444444444'
    'a1b2c3d4-5555-6666-7777-888888888888'
    'c0ffee00-9999-aaaa-bbbb-cccccccccccc'
)
$darkNodes = @($darkSessionIds | ForEach-Object { Get-CopilotMqttNodeId -SessionId $_ })
foreach ($darkSessionId in $darkSessionIds) {
    Publish-CopilotMqttSession -SessionId $darkSessionId -SessionName 'Claude: old' `
        -Machine $dark.Machine -Headers $headers | Out-Null
}
Publish-CopilotMqttMachineOnlineConfig -Slug $dark.Slug -MachineName $dark.Machine -Headers $headers
Publish-CopilotMqttGlobalStatus -Sessions @($darkNodes | ForEach-Object {
    [pscustomobject]@{ node = $_; name = 'Claude: old' }
}) -Capabilities @{} -Slug $dark.Slug -MachineName $dark.Machine -Headers $headers
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
        an update entity's JSON state becomes its attributes, a machine that has
        published no heartbeat is unavailable because the sensor expires, and an empty
        retained config withdraws the entity it declared.
    #>
    $states = @{}
    # Which entity each config topic declared, so clearing that topic can take the
    # right one away: the empty payload that withdraws it names nothing itself.
    $declared = @{}
    foreach ($message in $script:Published) {
        if ($message.Topic -notmatch '^homeassistant/([a-z_]+)/[^/]+/[^/]+/config$') { continue }
        $domain = $Matches[1]
        if ([string]::IsNullOrEmpty($message.Payload)) {
            if ($declared.ContainsKey($message.Topic)) {
                $states.Remove($declared[$message.Topic])
                $declared.Remove($message.Topic)
            }
            continue
        }
        $config = $message.Payload | ConvertFrom-Json
        if (-not $config.PSObject.Properties['object_id']) { continue }
        $entityId = "$domain.$($config.object_id)"
        $declared[$message.Topic] = $entityId

        $raw = $null
        if ($config.PSObject.Properties['state_topic']) {
            $raw = Get-LastPublishedPayload -Topic ([string]$config.state_topic)
        }
        $state = if ($null -eq $raw) { 'unavailable' } else { [string]$raw }
        $attributes = @{}

        if ($domain -eq 'update' -and -not [string]::IsNullOrWhiteSpace($raw)) {
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
. (Join-Path $PSScriptRoot 'test-dashboard.ps1') -PublicationFixturesOnly
function Invoke-CopilotHaWebSocket {
    param([Parameter(Mandatory)][object[]]$Commands)
    Invoke-TestPublicationCommands -Commands $Commands
}
Initialize-TestPublicationStore
Initialize-TestPublicationAuthority

# Gated on the version the installer reads out of the card file itself, rather than a
# number written down again here.
$cardVersion = Get-BridgeReplyCardFileVersion -SourcePath (Join-Path $PSScriptRoot '..\frontend\agent-bridge-reply-card.js')

$sessions = @(
    [pscustomobject]@{ Node = 'copilot_aaa111bbb222'; Name = 'Copilot: a task'; Machine = $live.Machine; Kind = 'copilot' }
    [pscustomobject]@{ Node = 'copilot_ccc333ddd444'; Name = 'Copilot: another'; Machine = $live.Machine; Kind = 'copilot' }
)
$machines = @(
    [pscustomobject]@{ Slug = $live.Slug; Machine = $live.Machine; Online = $true; IncludeProfile = $false; IncludeResume = $true; IncludeAgent = $true; IncludeDetailed = $true
        SessionNodes = @($sessions | ForEach-Object { $_.Node }) }
    [pscustomobject]@{ Slug = $dark.Slug; Machine = $dark.Machine; Online = $false; IncludeProfile = $false; IncludeResume = $true; IncludeAgent = $false; IncludeDetailed = $false
        SessionNodes = @($darkNodes) }
)
Set-TestPublicationCardUrl -Url "/local/agent-bridge-reply-card.js?v=$cardVersion"
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
        if ($_.PSObject.Properties['install']) { [string]$_.install }
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
    <# What the real card draws, and the service calls the given actions produce. #>
    param(
        [string[]]$Flips = @(),
        [string[]]$Forgets = @(),
        [string[]]$Installs = @(),
        [bool]$Open = $true,
        [hashtable]$States = $null
    )
    $job = @{
        config   = $cardConfig
        states   = $(if ($States) { $States } else { $haStates })
        open     = $Open
        flips    = @($Flips)
        forgets  = @($Forgets)
        installs = @($Installs)
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
Write-Host '--- and the X on a machine that is gone really removes it ---'
# The machine here was renamed. Nothing on it will ever publish under the old name
# again, so its row would read "offline" for good and its session entities would sit
# in Home Assistant with nothing left to withdraw them.
$darkForget = @(@($cardConfig.machines | Where-Object { $_.machine -eq $dark.Machine })[0].forget)

Test-That 'the dashboard hands that row the topics to clear' { $darkForget.Count -gt 0 }
Test-That 'they cover every discovery config the bridge published for it' {
    # The list the card is given and the list the publishers use are two different
    # files; this is what stops one of them growing an entity the other never clears.
    $published = @($script:Published |
        Where-Object { $_.Topic -match "^homeassistant/[a-z_]+/(agent_bridge_$($dark.Slug)|$($darkNodes -join '|'))/[^/]+/config$" } |
        ForEach-Object { $_.Topic } | Sort-Object -Unique)
    $published.Count -gt 0 -and @($published | Where-Object { $darkForget -notcontains $_ }).Count -eq 0
} "missing=[$(@($script:Published | Where-Object { $_.Topic -match "^homeassistant/[a-z_]+/(agent_bridge_$($dark.Slug)|$($darkNodes -join '|'))/[^/]+/config$" } | ForEach-Object { $_.Topic } | Sort-Object -Unique | Where-Object { $darkForget -notcontains $_ }) -join ',')]"
Test-That 'and nothing belonging to the machine that is still running' {
    @($darkForget | Where-Object { $_ -match "$($live.Slug)|$(@($sessions | ForEach-Object { $_.Node }) -join '|')" }).Count -eq 0
}

$removed = Invoke-StatusCard -Forgets @($dark.Machine)
Test-That 'the X was there to press' { @($removed.missing).Count -eq 0 } "missing=[$(@($removed.missing) -join ',')]"
Test-That 'it is offered only on the machine that is not running' {
    # Every row is given the topics - the card decides - but the control only appears
    # on a machine that is not running, where the Detail switch has nothing to do.
    $darkRow = @($removed.rows | Where-Object { $_.machine -eq $dark.Machine })[0]
    $liveRow = @($removed.rows | Where-Object { $_.machine -eq $live.Machine })[0]
    -not $darkRow.forget.hidden -and $liveRow.forget.hidden -and -not $liveRow.detail.hidden
}
Test-That 'the row goes without waiting for the daemon to rebuild the dashboard' {
    @($removed.rows | Where-Object { $_.machine -eq $dark.Machine })[0].gone
}
Test-That 'every call it makes is an emptied, retained publish' {
    @($removed.calls).Count -eq $darkForget.Count -and
    @($removed.calls | Where-Object {
        $_.domain -ne 'mqtt' -or $_.service -ne 'publish' -or $_.data.payload -ne '' -or -not $_.data.retain
    }).Count -eq 0
} "calls=$(@($removed.calls).Count) topics=$($darkForget.Count)"

# Replayed through the same rules Home Assistant applies, which is the real question:
# does pressing it actually make the machine go away?
foreach ($call in @($removed.calls)) {
    $script:Published.Add([pscustomobject]@{ Topic = [string]$call.data.topic; Payload = '' })
}
$afterStates = Get-PublishedHaStates

Test-That 'Home Assistant is left with none of that machine entities' {
    @($afterStates.Keys | Where-Object { $_ -match "agent_bridge_$($dark.Slug)_" }).Count -eq 0
} "left=[$(@($afterStates.Keys | Where-Object { $_ -match "agent_bridge_$($dark.Slug)_" }) -join ',')]"
Test-That 'nor any of the session cards it left behind' {
    @($afterStates.Keys | Where-Object { $_ -match ($darkNodes -join '|') }).Count -eq 0
} "left=[$(@($afterStates.Keys | Where-Object { $_ -match ($darkNodes -join '|') }) -join ',')]"
Test-That 'and the machine that is still running is untouched' {
    $afterStates.ContainsKey("sensor.agent_bridge_$($live.Slug)_sessions") -and
    $afterStates.ContainsKey("binary_sensor.agent_bridge_$($live.Slug)_online") -and
    $afterStates["binary_sensor.agent_bridge_$($live.Slug)_online"].state -eq 'on'
}

# --- 4. the update button, on the row the machine already has ----------------------
#
# Updating a machine meant finding its own card further down the view and then
# watching a spinner that said only that something was happening. On a slow or
# failing update the natural move is to press again or go to a shell, and both made
# things worse (#129). The control sits on the machine's row, appears only when there
# is something to say, and says which stage the updater has actually reached.

$liveUpdate = Get-BridgeMachineEntityId -Domain 'update' -Key 'update' -Slug $live.Slug
$liveInstall = Get-BridgeMachineEntityId -Domain 'button' -Key 'install_update' -Slug $live.Slug
$darkUpdate = Get-BridgeMachineEntityId -Domain 'update' -Key 'update' -Slug $dark.Slug

function New-UpdateStates {
    <#
        The published states with one machine's update entity replaced, so each
        scenario starts from what the bridge really publishes rather than from a
        hand-built world.
    #>
    param(
        [Parameter(Mandatory)][string]$EntityId,
        [Parameter(Mandatory)][string]$State,
        [hashtable]$Attributes = @{}
    )
    $copy = @{}
    foreach ($key in $haStates.Keys) { $copy[$key] = $haStates[$key] }
    $base = @{
        installed_version = '1.19.0'; latest_version = '1.20.0'
        in_progress = $false; update_percentage = $null; stage = ''; stage_detail = ''
    }
    foreach ($key in $Attributes.Keys) { $base[$key] = $Attributes[$key] }
    $copy[$EntityId] = @{ state = $State; attributes = $base }
    $copy
}

function Get-UpdateRow {
    param([Parameter(Mandatory)][object]$Rendered, [Parameter(Mandatory)][string]$Machine)
    @($Rendered.rows | Where-Object { $_.machine -eq $Machine })[0]
}

Write-Host ''
Write-Host '--- the update button is on the machine row, and only when it has to be ---'
Test-That 'the dashboard hands every row its own install button' {
    @($cardConfig.machines | Where-Object { $_.PSObject.Properties['install'] }).Count -eq @($cardConfig.machines).Count
}
Test-That 'each naming the button that machine publishes, and no other' {
    @($cardConfig.machines | Where-Object {
        $slug = if ($_.machine -eq $live.Machine) { $live.Slug } else { $dark.Slug }
        [string]$_.install -ne (Get-BridgeMachineEntityId -Domain 'button' -Key 'install_update' -Slug $slug)
    }).Count -eq 0
}
Test-That 'with nothing to install the row keeps its Detail switch and shows no button' {
    $row = Get-UpdateRow -Rendered $rendered -Machine $live.Machine
    $row.update.hidden -and -not $row.detail.hidden
}

$offered = Invoke-StatusCard -States (New-UpdateStates -EntityId $liveUpdate -State 'on')
Test-That 'an available update names the version it would install' {
    (Get-UpdateRow -Rendered $offered -Machine $live.Machine).update.button.text -eq 'Update to 1.20.0'
} "[$((Get-UpdateRow -Rendered $offered -Machine $live.Machine).update.button.text)]"
Test-That 'and takes the place of the Detail switch rather than crowding the row' {
    $row = Get-UpdateRow -Rendered $offered -Machine $live.Machine
    -not $row.update.hidden -and -not $row.update.button.hidden -and $row.detail.hidden
}
Test-That 'the other machine, with nothing to install, is unaffected' {
    (Get-UpdateRow -Rendered $offered -Machine $dark.Machine).update.hidden
}

$pressed = Invoke-StatusCard -States (New-UpdateStates -EntityId $liveUpdate -State 'on') -Installs @($live.Machine)
Write-Host ''
Write-Host '--- and pressing it starts that machine''s update, and only that one ---'
Test-That 'the button was there to press' { @($pressed.missing).Count -eq 0 } "missing=[$(@($pressed.missing) -join ',')]"
Test-That 'exactly one service call is made' { @($pressed.calls).Count -eq 1 } "calls=$(@($pressed.calls).Count)"
Test-That 'pressing the button this machine publishes, through its own domain' {
    @($pressed.calls)[0].domain -eq 'button' -and @($pressed.calls)[0].service -eq 'press' -and
    @($pressed.calls)[0].data.entity_id -eq $liveInstall
} "[$(@($pressed.calls)[0].domain)/$(@($pressed.calls)[0].service) $(@($pressed.calls)[0].data.entity_id)]"
Test-That 'and it stops offering an update it has already asked for' {
    # The daemon only sees the press on its next maintenance pass, so the entity
    # still says an update is available. Offering again here is what got pressed
    # twice, and a second press is a second installer.
    $row = Get-UpdateRow -Rendered $pressed -Machine $live.Machine
    $row.update.button.hidden -and $row.update.note.text -eq 'Starting'
} "[$((Get-UpdateRow -Rendered $pressed -Machine $live.Machine).update.note.text)]"

Write-Host ''
Write-Host '--- while it runs it says which stage, not that something is happening ---'
$downloading = Invoke-StatusCard -States (New-UpdateStates -EntityId $liveUpdate -State 'on' -Attributes @{
    in_progress = $true; stage = 'downloading'; update_percentage = 42 })
Test-That 'the stage the updater reported is the stage shown' {
    (Get-UpdateRow -Rendered $downloading -Machine $live.Machine).update.note.text -eq 'Downloading 42%'
} "[$((Get-UpdateRow -Rendered $downloading -Machine $live.Machine).update.note.text)]"
Test-That 'with a bar drawn at the proportion it reported' {
    $row = Get-UpdateRow -Rendered $downloading -Machine $live.Machine
    -not $row.update.bar.hidden -and $row.update.bar.width -eq '42%'
} "[$((Get-UpdateRow -Rendered $downloading -Machine $live.Machine).update.bar.width)]"
Test-That 'and nothing to press while it is running' {
    (Get-UpdateRow -Rendered $downloading -Machine $live.Machine).update.button.hidden
}

$installing = Invoke-StatusCard -States (New-UpdateStates -EntityId $liveUpdate -State 'on' -Attributes @{
    in_progress = $true; stage = 'installing' })
Test-That 'a stage with no proportion draws no bar rather than an invented one' {
    $row = Get-UpdateRow -Rendered $installing -Machine $live.Machine
    $row.update.note.text -eq 'Installing' -and $row.update.bar.hidden
} "[$((Get-UpdateRow -Rendered $installing -Machine $live.Machine).update.note.text)]"

# Restarting the daemon is one of the stages, so the machine's liveness sensor
# expires part-way through its own update. An X offering to forget a machine that is
# mid-update is exactly the wrong control at exactly the wrong moment.
$restarting = Invoke-StatusCard -States (New-UpdateStates -EntityId $darkUpdate -State 'on' -Attributes @{
    installed_version = '1.17.1'; in_progress = $true; stage = 'restarting' })
Test-That 'a machine restarting into its update says so instead of offering an X' {
    $row = Get-UpdateRow -Rendered $restarting -Machine $dark.Machine
    -not $row.update.hidden -and $row.update.note.text -eq 'Restarting' -and $row.forget.hidden
} "[$((Get-UpdateRow -Rendered $restarting -Machine $dark.Machine).update.note.text)]"

Write-Host ''
Write-Host '--- and it ends on what happened, not on silence ---'
$done = Invoke-StatusCard -States (New-UpdateStates -EntityId $liveUpdate -State 'off' -Attributes @{
    installed_version = '1.20.0'; stage = 'completed'; stage_detail = 'Updated to 1.20.0' })
Test-That 'a finished update names the version it reached' {
    $row = Get-UpdateRow -Rendered $done -Machine $live.Machine
    $row.update.note.text -eq 'Updated to 1.20.0' -and $row.update.note.tone -eq 'good'
} "[$((Get-UpdateRow -Rendered $done -Machine $live.Machine).update.note.text)]"

$current = Invoke-StatusCard -States (New-UpdateStates -EntityId $liveUpdate -State 'off' -Attributes @{
    latest_version = '1.19.0'; stage = 'current'; stage_detail = 'No newer release found; nothing installed.' })
Test-That 'a release already installed is reported as that, not as a failure' {
    # Conflating the two is #92: a press that found nothing to do looked exactly
    # like a press that broke, and the answer was always to go and read a log.
    $row = Get-UpdateRow -Rendered $current -Machine $live.Machine
    -not $row.update.hidden -and $row.update.note.tone -ne 'bad'
} "tone=[$((Get-UpdateRow -Rendered $current -Machine $live.Machine).update.note.tone)]"

$failed = Invoke-StatusCard -States (New-UpdateStates -EntityId $liveUpdate -State 'on' -Attributes @{
    stage = 'failed'; stage_detail = 'the download was rejected: 403' })
Test-That 'a failure says so, carries why, and can be pressed again' {
    $row = Get-UpdateRow -Rendered $failed -Machine $live.Machine
    -not $row.update.button.hidden -and -not $row.update.button.disabled -and
    $row.update.button.text -eq 'Update failed' -and
    $row.update.button.title -eq 'the download was rejected: 403'
} "[$((Get-UpdateRow -Rendered $failed -Machine $live.Machine).update.button.text)/$((Get-UpdateRow -Rendered $failed -Machine $live.Machine).update.button.title)]"

$unknown = Invoke-StatusCard -States (New-UpdateStates -EntityId $liveUpdate -State 'unavailable' -Attributes @{ latest_version = '' })
Test-That 'a check that failed is not reported as nothing to install' {
    $row = Get-UpdateRow -Rendered $unknown -Machine $live.Machine
    -not $row.update.hidden -and $row.update.note.text -eq 'Update check failed' -and $row.update.button.hidden
} "[$((Get-UpdateRow -Rendered $unknown -Machine $live.Machine).update.note.text)]"

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All status card checks passed' -ForegroundColor Green
