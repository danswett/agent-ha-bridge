#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for sharing one Home Assistant between several machines.

.DESCRIPTION
    A Home Assistant instance is usually shared: a desktop and a laptop both run the
    bridge and both talk to the same server. Per-session entities were always safe
    because they are keyed by session id, but everything the bridge publishes *once* -
    the new-session controls, the update entity, the session counter - used a fixed
    unique id, so the second machine overwrote the first rather than adding to it.

    Two consequences drove this suite. Pressing Launch ran a session on every machine
    at once, because each daemon watched the same button and kept its own idea of when
    it was last pressed. And uninstalling anywhere deleted the shared dashboard and
    toggle, taking them away from machines that were still running.

    Everything here is offline. The decision helpers are pure, and the Home Assistant
    lookups are exercised through injected state lists rather than a live server.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-mqtt.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-ha-websocket.ps1')

$env:BRIDGE_UNINSTALL_NORUN = '1'
. (Join-Path $PSScriptRoot '..\uninstall.ps1')
Remove-Item Env:\BRIDGE_UNINSTALL_NORUN -ErrorAction SilentlyContinue

$script:Failures = 0
function Test-That {
    # Underscored locals: an assertion scriptblock resolves its free variables in this
    # scope, so a plain $ok here would shadow one the caller set up for it to read.
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $__ok = $false
    try { $__ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($__ok) { Write-Host "  PASS  $Name" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

Write-Host '--- naming a machine ---'

Test-That 'a hostname becomes a safe slug' {
    (Get-BridgeMachineSlug -MachineName 'DSWETT-HOME') -eq 'dswett_home'
}
Test-That 'runs of punctuation collapse to one separator' {
    (Get-BridgeMachineSlug -MachineName 'my..box--01') -eq 'my_box_01'
}
Test-That 'a name that is entirely punctuation still yields something usable' {
    # An empty slug would produce entity ids like sensor.agent_bridge__sessions, which
    # the peer regex would then fail to match, so the machine would be invisible.
    (Get-BridgeMachineSlug -MachineName '---') -eq 'machine'
}
Test-That 'a long name is truncated without a trailing separator' {
    $slug = Get-BridgeMachineSlug -MachineName ('a' * 24 + '-tail')
    $slug.Length -le 24 -and -not $slug.EndsWith('_')
}
Test-That 'the slug only ever contains characters an entity id allows' {
    (Get-BridgeMachineSlug -MachineName 'Böx #2 (lab)') -match '^[a-z0-9_]+$'
}

Write-Host '--- entities are scoped to the machine that publishes them ---'

Test-That 'the launch button carries the machine' {
    (Get-BridgeMachineEntityId -Domain 'button' -Key 'new_session' -Slug 'laptop') -eq 'button.agent_bridge_laptop_new_session'
}
Test-That 'two machines never produce the same id' {
    # This is the whole bug: with a fixed id the second machine overwrote the first,
    # and one press of Launch then started a session on every machine at once.
    (Get-BridgeMachineEntityId -Domain 'button' -Key 'new_session' -Slug 'desktop') -ne
    (Get-BridgeMachineEntityId -Domain 'button' -Key 'new_session' -Slug 'laptop')
}
Test-That 'their command topics differ too' {
    # Home Assistant subscribes each entity to the topic in its discovery payload, so
    # a shared topic would echo one machine's typing into the other's prompt box.
    (Get-CopilotMqttMachineTopicRoot -Slug 'desktop') -ne (Get-CopilotMqttMachineTopicRoot -Slug 'laptop')
}
Test-That 'each machine is its own Home Assistant device' {
    $a = Get-CopilotMqttMachineDevice -Slug 'desktop' -MachineName 'DESKTOP'
    $b = Get-CopilotMqttMachineDevice -Slug 'laptop' -MachineName 'LAPTOP'
    $a.identifiers[0] -ne $b.identifiers[0] -and $a.name -match 'DESKTOP'
}

Write-Host '--- publishing this machine, and reading other machines back ---'

$script:Published = @()
function Publish-CopilotMqttMessage {
    param([string]$Topic, [AllowEmptyString()][string]$Payload, [hashtable]$Headers, [switch]$Retain)
    $script:Published += [pscustomobject]@{ Topic = $Topic; Payload = $Payload; Retained = [bool]$Retain }
}

$script:Published = @()
Publish-CopilotMqttGlobalStatus -Slug 'laptop' -MachineName 'LAPTOP' -Headers @{} `
    -Capabilities @{ newSession = $true; profile = $true; resume = $false } `
    -Sessions @(@{ name = 'Copilot: a'; machine = 'LAPTOP'; node = 'agent_bridge_aaa'; kind = 'copilot' })

$statusConfig = ($script:Published | Where-Object { $_.Topic -match '/sensor/agent_bridge_laptop/sessions/config$' } | Select-Object -First 1)
$statusAttr = ($script:Published | Where-Object { $_.Topic -match '/global/attr$' } | Select-Object -First 1)

Test-That 'the sensor is published under the machine node' { $null -ne $statusConfig }
Test-That 'its unique id is scoped to the machine' { $statusConfig.Payload -match '"unique_id":"agent_bridge_laptop_sessions"' }
Test-That 'the attributes name the machine' { $statusAttr.Payload -match '"machine":"LAPTOP"' }
Test-That 'the attributes carry what its launch card needs' {
    # A peer has no other way to know whether to draw a profile or resume row.
    $attrs = $statusAttr.Payload | ConvertFrom-Json
    $attrs.capabilities.profile -eq $true -and $attrs.capabilities.resume -eq $false
}

# Two machines' sensors as /api/states would return them.
function New-MachineState {
    param([string]$Slug, [string]$Machine, [object[]]$Sessions = @(), [hashtable]$Capabilities = @{})
    [pscustomobject]@{
        entity_id = "sensor.agent_bridge_${Slug}_sessions"
        state = [string]@($Sessions).Count
        attributes = [pscustomobject]@{
            machine = $Machine
            machine_slug = $Slug
            sessions = $Sessions
            capabilities = [pscustomobject]$Capabilities
        }
    }
}

$states = @(
    (New-MachineState -Slug 'desktop' -Machine 'DESKTOP' -Capabilities @{ profile = $true; resume = $true } -Sessions @(
        [pscustomobject]@{ name = 'Copilot: desk work'; machine = 'DESKTOP'; node = 'agent_bridge_d1'; kind = 'copilot' }
    )),
    (New-MachineState -Slug 'laptop' -Machine 'LAPTOP' -Capabilities @{ profile = $false; resume = $false } -Sessions @(
        [pscustomobject]@{ name = 'Claude: lap work'; machine = 'LAPTOP'; node = 'agent_bridge_l1'; kind = 'claude' }
    )),
    # Noise that must not be mistaken for a machine.
    [pscustomobject]@{ entity_id = 'sensor.agent_bridge_d1_status'; state = 'idle'; attributes = [pscustomobject]@{} },
    [pscustomobject]@{ entity_id = 'select.agent_bridge_d1_decision'; state = 'Idle'; attributes = [pscustomobject]@{} },
    [pscustomobject]@{ entity_id = 'sensor.kitchen_temperature'; state = '21'; attributes = [pscustomobject]@{} }
)

$peers = Get-BridgePeerMachine -States $states
Test-That 'both machines are found' { @($peers).Count -eq 2 }
Test-That 'a session entity is not mistaken for a machine' {
    @($peers | Where-Object { $_.Slug -eq 'd1' }).Count -eq 0
}
Test-That 'an unrelated sensor is ignored' {
    @($peers | Where-Object { $_.Machine -match 'kitchen' }).Count -eq 0
}
Test-That 'each carries its friendly machine name' {
    @($peers | Where-Object { $_.Machine -eq 'DESKTOP' }).Count -eq 1
}
Test-That 'each carries what it is running' {
    (@($peers | Where-Object { $_.Slug -eq 'laptop' })[0].Sessions[0].node) -eq 'agent_bridge_l1'
}
Test-That 'an empty state list is not read as one null machine' {
    # @($null) is a one-element array, so an empty result used to be dereferenced.
    @(Get-BridgePeerMachine -States @()).Count -eq 0
}
Test-That 'a sensor with no attributes at all does not throw' {
    $bare = @([pscustomobject]@{ entity_id = 'sensor.agent_bridge_bare_sessions'; state = '0'; attributes = $null })
    $found = @(Get-BridgePeerMachine -States $bare)
    $found.Count -eq 1 -and $found[0].Machine -eq 'bare'
}

Write-Host '--- one dashboard shows every machine ---'

$script:SavedConfig = $null
function Invoke-CopilotHaWebSocket {
    param([Parameter(Mandatory)][object[]]$Commands)
    if ($Commands[0].ContainsKey('config')) { $script:SavedConfig = $Commands[0].config }
    @()
}
$script:BridgeDashboardReady = $true

$machines = @(
    [pscustomobject]@{ Slug = 'desktop'; Machine = 'DESKTOP'; IncludeProfile = $true; IncludeResume = $true }
    [pscustomobject]@{ Slug = 'laptop'; Machine = 'LAPTOP'; IncludeProfile = $false; IncludeResume = $false }
)
$twoMachineSessions = @(
    [pscustomobject]@{ Node = 'agent_bridge_d1'; Name = 'Copilot: desk work'; Machine = 'DESKTOP'; Kind = 'copilot' }
    [pscustomobject]@{ Node = 'agent_bridge_l1'; Name = 'Claude: lap work'; Machine = 'LAPTOP'; Kind = 'claude' }
)
Save-CopilotSessionDashboard -Sessions $twoMachineSessions -Machines $machines `
    -MachineSelector 'input_select.agent_bridge_target_machine'
$cfg = $script:SavedConfig
$cards = @($cfg.views[0].cards)

function Get-CardTitles {
    # Titles can sit one level down now, inside the launch stack.
    @($cards | ForEach-Object {
        if ($_.ContainsKey('title')) { [string]$_['title'] }
        if ($_['type'] -eq 'vertical-stack') {
            $_['cards'] | Where-Object { $_.ContainsKey('title') } | ForEach-Object { [string]$_['title'] }
        }
    })
}
function Get-RowEntity {
    # Rows nest arbitrarily: entities cards, conditionals wrapping them, and stacks
    # wrapping those. Walk it rather than hard-coding the depth.
    param([object]$Card)
    if ($null -eq $Card) { return }
    if ($Card['type'] -eq 'entities') {
        foreach ($row in @($Card['entities'])) {
            if ($null -ne $row -and $row.ContainsKey('entity')) { [string]$row['entity'] }
        }
        return
    }
    if ($Card['type'] -eq 'conditional') { Get-RowEntity -Card $Card['card']; return }
    if ($Card['type'] -eq 'vertical-stack') {
        foreach ($child in @($Card['cards'])) { Get-RowEntity -Card $child }
    }
    # The bridge's own launch card lists each machine's controls instead of rows.
    if ($Card['type'] -eq 'custom:agent-bridge-launch-card') {
        if ($Card['selector']) { [string]$Card['selector'] }
        foreach ($m in @($Card['machines'])) { foreach ($key in @($m.Keys)) { if ($key -ne 'machine') { [string]$m[$key] } } }
    }
}
function Get-LaunchCardCount {
    # A launch card is titled wherever it sits: top level, or in a stack with its note.
    param([object[]]$Cards)
    @($Cards | ForEach-Object {
        if ($_.ContainsKey('title') -and $_['title'] -eq 'Start a new session') { $_ }
        elseif ($_['type'] -eq 'vertical-stack') {
            @($_['cards']) | Where-Object { $_.ContainsKey('title') -and $_['title'] -eq 'Start a new session' }
        }
    }).Count
}
function Get-AllRowEntities { @($cards | ForEach-Object { Get-RowEntity -Card $_ }) }
$rows = Get-AllRowEntities

Test-That 'there is one launch card, not one per machine' {
    @(Get-CardTitles | Where-Object { $_ -eq 'Start a new session' }).Count -eq 1
}
Test-That 'it offers a machine picker' {
    $rows -contains 'input_select.agent_bridge_target_machine'
}
Test-That 'the picker is the first row on the card' {
    # Choosing where to run comes before choosing what to run there.
    $stack = @($cards | Where-Object {
        $_['type'] -eq 'vertical-stack' -and
        @($_['cards'] | Where-Object { $_.ContainsKey('title') -and $_['title'] -eq 'Start a new session' }).Count -gt 0
    })[0]
    [string]$stack['cards'][0]['entities'][0]['entity'] -eq 'input_select.agent_bridge_target_machine'
}
Test-That 'each machine rows are revealed by the picker, not all at once' {
    # Each machine's launch rows; its launch note is a separate conditional card.
    $conds = @($cards | Where-Object { $_['type'] -eq 'vertical-stack' } | ForEach-Object { $_['cards'] } |
        Where-Object { $_['type'] -eq 'conditional' -and $_['card']['type'] -eq 'entities' } |
        ForEach-Object { $_['conditions'][0] })
    @($conds | Where-Object { [string]$_['entity'] -eq 'input_select.agent_bridge_target_machine' }).Count -eq 2 -and
    @($conds | ForEach-Object { [string]$_['state'] }) -contains 'DESKTOP' -and
    @($conds | ForEach-Object { [string]$_['state'] }) -contains 'LAPTOP'
}
Test-That 'Launch still presses the machine own button' {
    # The picker is a display filter. A single shared button is exactly what made one
    # press start a session on every machine at once.
    ($rows -contains 'button.agent_bridge_desktop_new_session') -and
    ($rows -contains 'button.agent_bridge_laptop_new_session')
}
Test-That 'no unscoped launch button survives' {
    $rows -notcontains 'button.agent_bridge_new_session'
}
Test-That 'a machine without Agency gets no profile row' {
    ($rows -contains 'select.agent_bridge_desktop_new_profile') -and
    ($rows -notcontains 'select.agent_bridge_laptop_new_profile')
}
Test-That 'each machine gets its own update row' {
    ($rows -contains 'update.agent_bridge_desktop_update') -and
    ($rows -contains 'update.agent_bridge_laptop_update')
}
Test-That 'the update rows are conditional on that machine having an update' {
    $conds = @($cards | Where-Object { $_['type'] -eq 'conditional' } |
        ForEach-Object { [string]$_['conditions'][0]['entity'] })
    ($conds -contains 'update.agent_bridge_desktop_update') -and
    ($conds -contains 'update.agent_bridge_laptop_update')
}

Write-Host '--- the machines card reports who is around ---'

$machinesCard = @($cards | Where-Object { $_['type'] -eq 'markdown' -and $_['content'] -match '### Machines' })[0]
Test-That 'there is a machines card' { $null -ne $machinesCard }
Test-That 'every registered machine is listed, online or not' {
    $machinesCard.content -match '\*\*DESKTOP\*\*' -and $machinesCard.content -match '\*\*LAPTOP\*\*'
}
Test-That 'status comes from the liveness sensor' {
    $machinesCard.content -match "is_state\('binary_sensor\.agent_bridge_desktop_online','on'\)" -and
    $machinesCard.content -match "is_state\('binary_sensor\.agent_bridge_laptop_online','on'\)"
}
Test-That 'a machine that is not reporting reads as offline' {
    # The sensor is unretained and expires, so anything other than on - including
    # unavailable after the heartbeat stops - has to fall to the offline branch.
    $machinesCard.content -match 'offline'
}
Test-That 'each line carries that machine version and session count' {
    $machinesCard.content -match "state_attr\('update\.agent_bridge_desktop_update','installed_version'\)" -and
    $machinesCard.content -match "states\('sensor\.agent_bridge_laptop_sessions'\)"
}
Test-That 'the summary no longer repeats the versions' {
    $summaryCard = @($cards | Where-Object { $_['type'] -eq 'vertical-stack' } |
        ForEach-Object { $_['cards'] } | Where-Object { $_['type'] -eq 'markdown' })[0]
    $summaryCard.content -notmatch 'installed_version'
}

$summary = @($cards | Where-Object { $_['type'] -eq 'vertical-stack' } |
    ForEach-Object { $_['cards'] } | Where-Object { $_['type'] -eq 'markdown' })[0]

Test-That 'the live count adds the machines together' {
    $summary.content -match "states\('sensor\.agent_bridge_desktop_sessions'\)\|int\(0\) \+ states\('sensor\.agent_bridge_laptop_sessions'\)\|int\(0\)"
}
Test-That 'there is no Detailed activity toggle to share' {
    # It is the detailedActivity setting now, on each machine.
    $rows -notcontains 'input_boolean.agent_bridge_detailed_activity'
}
Test-That 'both machines sessions get a card' {
    $content = ($cfg | ConvertTo-Json -Depth 30)
    $content -match 'desk work' -and $content -match 'lap work'
}
Test-That 'each session card names the machine it is on' {
    $content = ($cfg | ConvertTo-Json -Depth 30)
    $content -match 'DESKTOP' -and $content -match 'LAPTOP'
}

Write-Host '--- an offline machine is listed, but cannot be launched on ---'

$script:SavedConfig = $null
function Invoke-CopilotHaWebSocket {
    param([Parameter(Mandatory)][object[]]$Commands)
    if ($Commands[0].ContainsKey('config')) { $script:SavedConfig = $Commands[0].config }
    @()
}
Save-CopilotSessionDashboard -Sessions $twoMachineSessions -Machines @(
    [pscustomobject]@{ Slug = 'desktop'; Machine = 'DESKTOP'; IncludeProfile = $true; IncludeResume = $true; Online = $true }
    [pscustomobject]@{ Slug = 'laptop'; Machine = 'LAPTOP'; IncludeProfile = $false; IncludeResume = $false; Online = $false }
)
$offCards = @($script:SavedConfig.views[0].cards)
$offRows = @($offCards | ForEach-Object { Get-RowEntity -Card $_ })

Test-That 'the offline machine still appears in the machines card' {
    $card = @($offCards | Where-Object { $_['type'] -eq 'markdown' -and $_['content'] -match '### Machines' })[0]
    $card.content -match '\*\*LAPTOP\*\*'
}
Test-That 'it gets no launch card' {
    # It had one, and with only one machine online there is no picker to tell the two
    # apart - so the dashboard showed two identical "Start a new session" cards, one of
    # which pressed a button nothing was listening to.
    $offRows -notcontains 'button.agent_bridge_laptop_new_session'
}
Test-That 'there is exactly one launch card left' {
    (Get-LaunchCardCount -Cards $offCards) -eq 1
}
Test-That 'and it belongs to the machine that is running' {
    $offRows -contains 'button.agent_bridge_desktop_new_session'
}
Test-That 'it gets no install-update row either' {
    # Pressing it would do nothing: the machine that would act on it is not running.
    $offRows -notcontains 'button.agent_bridge_laptop_install_update'
}
Test-That 'its retained session counter is left out of the live total' {
    # The counter is retained, so it still reads whatever it said when the machine
    # stopped; summing it would report sessions that are not running.
    $summaryCard = @($offCards | Where-Object { $_['type'] -eq 'vertical-stack' } |
        ForEach-Object { $_['cards'] } | Where-Object { $_['type'] -eq 'markdown' })[0]
    $summaryCard.content -match 'agent_bridge_desktop_sessions' -and
    $summaryCard.content -notmatch 'agent_bridge_laptop_sessions'
}

Test-That 'a caller that does not track liveness is treated as all-online' {
    # Keeps older callers and the single-machine path behaving exactly as before.
    $script:SavedConfig = $null
    Save-CopilotSessionDashboard -Sessions $twoMachineSessions -Machines @(
        [pscustomobject]@{ Slug = 'desktop'; Machine = 'DESKTOP'; IncludeProfile = $true; IncludeResume = $true }
        [pscustomobject]@{ Slug = 'laptop'; Machine = 'LAPTOP'; IncludeProfile = $false; IncludeResume = $false }
    )
    $rows2 = @($script:SavedConfig.views[0].cards | ForEach-Object { Get-RowEntity -Card $_ })
    $rows2 -contains 'button.agent_bridge_laptop_new_session'
}

Write-Host '--- a single machine still reads as it did ---'

$script:SavedConfig = $null
Save-CopilotSessionDashboard -Sessions @(
    [pscustomobject]@{ Node = 'agent_bridge_d1'; Name = 'Copilot: solo'; Machine = 'SOLO'; Kind = 'copilot' }
) -Machines @([pscustomobject]@{ Slug = 'solo'; Machine = 'SOLO'; IncludeProfile = $true; IncludeResume = $true })
$soloCards = @($script:SavedConfig.views[0].cards)

Test-That 'the launch card is not suffixed with the machine name' {
    # Naming the machine on a one-machine dashboard is noise, so it only appears once
    # there is something to tell apart.
    (Get-LaunchCardCount -Cards $soloCards) -eq 1
}
Test-That 'a single machine gets no picker' {
    ($script:SavedConfig | ConvertTo-Json -Depth 30) -notmatch 'agent_bridge_target_machine'
}
Test-That 'and no machines card' {
    @($soloCards | Where-Object { $_['type'] -eq 'markdown' -and $_['content'] -match '### Machines' }).Count -eq 0
}
Test-That 'the version is still labelled Bridge rather than the hostname' {
    $md = @($soloCards | Where-Object { $_['type'] -eq 'vertical-stack' } |
        ForEach-Object { $_['cards'] } | Where-Object { $_['type'] -eq 'markdown' })[0]
    $md.content -match '\*\*Bridge\*\*'
}

Write-Host '--- the picker only offers machines that can actually launch ---'

$script:SelectorCalls = @()
function New-WebSocketResult {
    # The real helper hands back one result per command, so the stub has to as well:
    # a bare @() would collapse and the caller's [0] would index past the end.
    param([object]$Value)
    $result = New-Object object[] 1
    $result[0] = $Value
    ,$result
}
function Invoke-CopilotHaWebSocket {
    param([Parameter(Mandatory)][object[]]$Commands)
    $script:SelectorCalls += $Commands[0]
    if ([string]$Commands[0].type -eq 'input_select/list') { return New-WebSocketResult @($script:ExistingSelects) }
    if ([string]$Commands[0].type -eq 'input_select/create') {
        return New-WebSocketResult ([pscustomobject]@{ id = 'agent_bridge_target_machine' })
    }
    New-WebSocketResult @()
}

$script:ExistingSelects = @()
$script:SelectorCalls = @()
# The repair path reads the helper's state and may re-point it, so both sides are
# stubbed; without this the selector tests would reach for a real Home Assistant.
$script:SelectorState = 'DESKTOP'
$script:Selected = @()
function Get-HomeAssistantHeaders { @{ Authorization = 'Bearer test' } }
function Get-HomeAssistantState { param([string]$EntityId, [hashtable]$Headers) [pscustomobject]@{ state = $script:SelectorState } }
function Invoke-HomeAssistantService {
    param([string]$Domain, [string]$Service, [hashtable]$Headers, [hashtable]$Data)
    $script:Selected += [string]$Data.option
}

$id = Initialize-BridgeMachineSelector -Machines @('DESKTOP', 'LAPTOP')
Test-That 'a picker is created when there is a choice to make' {
    $id -eq 'input_select.agent_bridge_target_machine' -and
    @($script:SelectorCalls | Where-Object { $_.type -eq 'input_select/create' }).Count -eq 1
}
Test-That 'it is created with the machines as options' {
    $create = @($script:SelectorCalls | Where-Object { $_.type -eq 'input_select/create' })[0]
    (@($create.options) -join ',') -eq 'DESKTOP,LAPTOP'
}

$script:ExistingSelects = @([pscustomobject]@{ id = 'agent_bridge_target_machine'; options = @('DESKTOP', 'LAPTOP') })
$script:SelectorCalls = @()
[void](Initialize-BridgeMachineSelector -Machines @('DESKTOP', 'LAPTOP'))
Test-That 'an unchanged option list is left alone' {
    # Every daemon runs this, so a needless write would be a write per machine per
    # rebuild, all of them setting the same value.
    @($script:SelectorCalls | Where-Object { $_.type -eq 'input_select/update' }).Count -eq 0
}

$script:SelectorCalls = @()
[void](Initialize-BridgeMachineSelector -Machines @('DESKTOP'))
Test-That 'a machine going offline drops it from the picker' {
    # One machine left means nothing to pick, so the picker is retired rather than
    # left as a control with a single option.
    @($script:SelectorCalls | Where-Object { $_.type -eq 'input_select/delete' }).Count -eq 1
}

$script:ExistingSelects = @()
$script:SelectorCalls = @()
$soloId = Initialize-BridgeMachineSelector -Machines @('DESKTOP')
Test-That 'a lone machine never creates one in the first place' {
    $soloId -eq '' -and @($script:SelectorCalls | Where-Object { $_.type -eq 'input_select/create' }).Count -eq 0
}

$script:ExistingSelects = @()
$script:SelectorCalls = @()
[void](Initialize-BridgeMachineSelector -Machines @('DESKTOP', '', '  ', 'DESKTOP', 'LAPTOP'))
Test-That 'blanks and duplicates never reach the option list' {
    $create = @($script:SelectorCalls | Where-Object { $_.type -eq 'input_select/create' })[0]
    (@($create.options) -join ',') -eq 'DESKTOP,LAPTOP'
}

Write-Host '--- the picker never points at a machine that is gone ---'

$script:ExistingSelects = @([pscustomobject]@{ id = 'agent_bridge_target_machine'; options = @('DESKTOP', 'LAPTOP', 'SERVER') })
$script:SelectorState = 'LAPTOP'
$script:Selected = @()
[void](Initialize-BridgeMachineSelector -Machines @('DESKTOP', 'SERVER'))
Test-That 'losing the selected machine re-points the picker' {
    # Home Assistant sets the state to 'unknown' rather than picking another option -
    # confirmed against a live instance. The launch rows are conditional on the
    # selection matching a machine name, so an unknown selection matches nothing and
    # the card collapses to a dropdown with no Workspace, Profile or Launch under it.
    (@($script:Selected) -join ',') -eq 'DESKTOP'
}

$script:SelectorState = 'unknown'
$script:Selected = @()
[void](Repair-BridgeMachineSelection -EntityId 'input_select.agent_bridge_target_machine' -Options @('DESKTOP', 'SERVER'))
Test-That 'an unknown selection is repaired even when the options did not change' {
    # It can also be left invalid by a Home Assistant restart or a hand edit, so the
    # check runs on every rebuild rather than only after an options update.
    (@($script:Selected) -join ',') -eq 'DESKTOP'
}

$script:SelectorState = 'SERVER'
$script:Selected = @()
[void](Repair-BridgeMachineSelection -EntityId 'input_select.agent_bridge_target_machine' -Options @('DESKTOP', 'SERVER'))
Test-That 'a valid selection is left exactly where it is' {
    # Re-pointing a good selection would yank the picker out from under whoever was
    # about to press Launch, on every rebuild.
    @($script:Selected).Count -eq 0
}

Test-That 'an empty option list repairs nothing rather than erroring' {
    $script:Selected = @()
    (-not (Repair-BridgeMachineSelection -EntityId 'input_select.x' -Options @())) -and
    @($script:Selected).Count -eq 0
}

Write-Host '--- liveness is the one thing not retained ---'

$script:Published = @()
Publish-CopilotMqttMachineOnlineConfig -Slug 'laptop' -MachineName 'LAPTOP' -ExpireAfter 180 -Headers @{}
$onlineConfig = @($script:Published | Where-Object { $_.Topic -match '/binary_sensor/agent_bridge_laptop/online/config$' })[0]

Test-That 'the sensor is published for the machine' { $null -ne $onlineConfig }
Test-That 'it expires, so a machine that stops reporting goes offline on its own' {
    $onlineConfig.Payload -match '"expire_after":180'
}
Test-That 'it is a connectivity sensor' { $onlineConfig.Payload -match '"device_class":"connectivity"' }
Test-That 'the discovery config is retained, so the entity survives a restart' {
    $onlineConfig.Retained
}
Test-That 'declaring the sensor does not also beat' {
    # An unretained beat that outruns its own discovery config is dropped, so the two
    # are split and the config goes out at startup, long before the first beat.
    @($script:Published | Where-Object { $_.Topic -match '/online/state$' }).Count -eq 0
}

$script:Published = @()
Publish-CopilotMqttMachineHeartbeat -Slug 'laptop' -Headers @{}
Test-That 'the beat is not retained' {
    # Retaining it would resurrect a stale "online" for a machine that has since been
    # switched off, every time Home Assistant restarts.
    $state = @($script:Published | Where-Object { $_.Topic -match '/online/state$' })[0]
    $state.Payload -eq 'online' -and -not $state.Retained
}
Test-That 'uninstalling a machine withdraws its liveness sensor too' {
    @(Get-CopilotMqttMachineTopic -Slug 'laptop') -contains 'homeassistant/binary_sensor/agent_bridge_laptop/online/config'
}

$peerStates = @(
    (New-MachineState -Slug 'desktop' -Machine 'DESKTOP'),
    (New-MachineState -Slug 'laptop' -Machine 'LAPTOP'),
    [pscustomobject]@{ entity_id = 'binary_sensor.agent_bridge_desktop_online'; state = 'on'; attributes = [pscustomobject]@{} },
    [pscustomobject]@{ entity_id = 'binary_sensor.agent_bridge_laptop_online'; state = 'unavailable'; attributes = [pscustomobject]@{} }
)
$statusPeers = @(Get-BridgePeerMachine -States $peerStates)
Test-That 'a reporting machine reads as online' {
    @($statusPeers | Where-Object { $_.Slug -eq 'desktop' })[0].Online
}
Test-That 'an expired sensor reads as offline, not online' {
    -not @($statusPeers | Where-Object { $_.Slug -eq 'laptop' })[0].Online
}
Test-That 'a machine with no liveness sensor at all reads as offline' {
    $bare = @((New-MachineState -Slug 'ghost' -Machine 'GHOST'))
    -not @(Get-BridgePeerMachine -States $bare)[0].Online
}

Write-Host '--- withdrawing one machine leaves the others alone ---'

$script:Published = @()
[void](Remove-CopilotMqttMachineEntities -Slug 'laptop' -Headers @{})
$cleared = @($script:Published | Where-Object { $_.Payload -eq '' } | ForEach-Object { $_.Topic })

Test-That 'the machine controls are withdrawn' {
    @($cleared | Where-Object { $_ -match '/agent_bridge_laptop/' }).Count -ge 6
}
Test-That 'its retained state topics go too' {
    @($cleared | Where-Object { $_ -match '/machine/laptop/' }).Count -ge 3
}
Test-That 'nothing belonging to another machine is touched' {
    @($cleared | Where-Object { $_ -match 'desktop' }).Count -eq 0
}
Test-That 'the shared dashboard and toggle are not in the list at all' {
    @($cleared | Where-Object { $_ -match 'detailed_activity|lovelace' }).Count -eq 0
}

$script:Published = @()
[void](Remove-CopilotMqttMachineEntities -Legacy -Headers @{})
$legacy = @($script:Published | ForEach-Object { $_.Topic })
Test-That 'the pre-scoping entities are withdrawn on upgrade' {
    # Published alongside the new ones otherwise, so Home Assistant would show two of
    # everything - and the old launch button would be watched by nobody.
    ($legacy -contains 'homeassistant/button/agent_bridge/new_session/config') -and
    ($legacy -contains 'homeassistant/sensor/agent_bridge_global/sessions/config')
}

Write-Host '--- the orphan sweep never touches a running machine ---'

# The sweep runs at daemon start and clears entities for sessions that are no longer
# live. "Not live here" is not "orphaned" once a Home Assistant is shared, so this is
# the check that a laptop starting up cannot delete the desktop's session cards.
$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
Remove-Item Env:\AGENT_BRIDGE_DAEMON_NORUN -ErrorAction SilentlyContinue

$script:Swept = @()
function Publish-CopilotMqttMessage {
    param([string]$Topic, [AllowEmptyString()][string]$Payload, [hashtable]$Headers, [switch]$Retain)
    if ($Payload -eq '') { $script:Swept += $Topic }
}
function Write-DaemonLog { param([string]$Message) $script:SweepLog += $Message }
$selfSlug = Get-BridgeMachineSlug

# One session live here, one live on a peer, one genuinely abandoned.
$sweepStates = @(
    [pscustomobject]@{ entity_id = "sensor.agent_bridge_${selfSlug}_sessions"; state = '1'
        attributes = [pscustomobject]@{ machine = 'HERE'; machine_slug = $selfSlug
            sessions = @([pscustomobject]@{ node = 'agent_bridge_1111111111111111' }); capabilities = [pscustomobject]@{} } }
    [pscustomobject]@{ entity_id = 'sensor.agent_bridge_peerbox_sessions'; state = '1'
        attributes = [pscustomobject]@{ machine = 'PEERBOX'; machine_slug = 'peerbox'
            sessions = @([pscustomobject]@{ node = 'agent_bridge_2222222222222222' }); capabilities = [pscustomobject]@{} } }
    [pscustomobject]@{ entity_id = 'select.agent_bridge_1111111111111111_decision'; state = 'Idle'; attributes = [pscustomobject]@{} }
    [pscustomobject]@{ entity_id = 'select.agent_bridge_2222222222222222_decision'; state = 'Idle'; attributes = [pscustomobject]@{} }
    [pscustomobject]@{ entity_id = 'select.agent_bridge_3333333333333333_decision'; state = 'Idle'; attributes = [pscustomobject]@{} }
)
$script:DaemonStatesCache = $sweepStates
$script:DaemonStatesCacheAt = [DateTimeOffset]::Now
$script:SweepLog = @()
Clear-CopilotMqttOrphans -Headers @{} -Live @{ '11111111-1111-1111-1111-111111111111' = $true }

Test-That 'the abandoned session is cleared' {
    @($script:Swept | Where-Object { $_ -match 'agent_bridge_3333333333333333' }).Count -ge 1
}
Test-That 'the sweep clears exactly what a clean exit would' {
    # These were two hand-maintained lists and they drifted: the stop button was added
    # to the exit path only, so every swept session left a dead Stop button behind.
    $sweptForOrphan = @($script:Swept | Where-Object { $_ -match 'agent_bridge_3333333333333333' } | Sort-Object)
    $expected = @(@(Get-CopilotMqttSessionDiscoveryTopic -Node 'agent_bridge_3333333333333333') +
                  @(Get-CopilotMqttSessionStateTopic -Node 'agent_bridge_3333333333333333') | Sort-Object)
    ($sweptForOrphan -join '|') -eq ($expected -join '|')
}
Test-That 'the stop button is one of them' {
    @($script:Swept | Where-Object { $_ -match 'agent_bridge_3333333333333333/stop/config$' }).Count -eq 1
}
Test-That 'the retained state goes too, not just the entities' {
    # Withdrawing the discovery config removes the entity but leaves what it last said
    # sitting in the broker forever - a handful of messages per dead session that
    # nothing would ever come back for.
    @($script:Swept | Where-Object { $_ -match 'agent_bridge_3333333333333333/(status/state|activity/attr|available)$' }).Count -eq 3
}
Test-That 'a peer machine live session is left alone' {
    @($script:Swept | Where-Object { $_ -match 'agent_bridge_2222222222222222' }).Count -eq 0
}
Test-That 'this machine own live session is left alone' {
    @($script:Swept | Where-Object { $_ -match 'agent_bridge_1111111111111111' }).Count -eq 0
}
Test-That 'no machine-level sensor is mistaken for an orphaned session' {
    @($script:Swept | Where-Object { $_ -match 'peerbox|sessions/config' }).Count -eq 0
}

# A machine whose name happens to look like a session node.
$script:Swept = @()
$hexStates = @(
    [pscustomobject]@{ entity_id = 'sensor.agent_bridge_abcdef012345_sessions'; state = '0'
        attributes = [pscustomobject]@{ machine = 'abcdef012345'; machine_slug = 'abcdef012345'
            sessions = @(); capabilities = [pscustomobject]@{} } }
    [pscustomobject]@{ entity_id = 'button.agent_bridge_abcdef012345_new_session'; state = 'unknown'; attributes = [pscustomobject]@{} }
)
$script:DaemonStatesCache = $hexStates
$script:DaemonStatesCacheAt = [DateTimeOffset]::Now
Clear-CopilotMqttOrphans -Headers @{} -Live @{}
Test-That 'a hostname shaped like a node id is still recognised as a machine' {
    @($script:Swept).Count -eq 0
}

# The fail-safe: no machine sensors visible means the picture is incomplete.
$script:Swept = @()
$script:SweepLog = @()
$script:DaemonStatesCache = @(
    [pscustomobject]@{ entity_id = 'select.agent_bridge_4444444444444444_decision'; state = 'Idle'; attributes = [pscustomobject]@{} }
)
$script:DaemonStatesCacheAt = [DateTimeOffset]::Now
Clear-CopilotMqttOrphans -Headers @{} -Live @{}
Test-That 'an incomplete picture skips the sweep rather than guessing' {
    # Deleting a running machine's entities is far worse than leaving a dead session
    # a little longer; the sweep runs again on the next start.
    @($script:Swept).Count -eq 0 -and @($script:SweepLog | Where-Object { $_ -match 'skipped' }).Count -eq 1
}

Write-Host '--- holding the window open when Windows owns the console ---'

$script:Prompted = 0
function Read-Host { param([string]$Prompt) $script:Prompted++; '' }

Test-That 'a terminal run is not interrupted by a prompt' {
    # It already has a window that stays put, so pausing there is pure noise.
    $script:PauseOnExit = $false
    $script:Prompted = 0
    [void](Wait-BridgeUninstallExit -Interactive $true)
    $script:Prompted -eq 0
}

Test-That 'the Apps and features run waits before the window closes' {
    # Windows gives that one its own console and closes it the instant the script
    # ends, so every warning - and any outright failure - flashed past unread.
    $script:PauseOnExit = $true
    $script:Prompted = 0
    $paused = Wait-BridgeUninstallExit -Interactive $true
    $paused -and $script:Prompted -eq 1
}

Test-That 'an unattended run never blocks on it' {
    # winget and friends use QuietUninstallString, which omits -Pause - but if one
    # ever reached here, prompting would hang the caller forever rather than inform
    # anyone, so a redirected stdin skips the wait outright.
    $script:PauseOnExit = $true
    $script:Prompted = 0
    $paused = Wait-BridgeUninstallExit -Interactive $false
    (-not $paused) -and $script:Prompted -eq 0
}

$script:PauseOnExit = $false

Write-Host '--- deciding whether shared Home Assistant state may be removed ---'
Test-That 'another machine present keeps the dashboard' {
    $d = Get-BridgeSharedStateDecision -Interactive $false -OtherMachines @('LAPTOP')
    (-not $d.Clear) -and $d.Reason -match 'LAPTOP'
}

Test-That 'the last machine removes it' {
    $d = Get-BridgeSharedStateDecision -Interactive $false -OtherMachines @()
    $d.Clear
}

Test-That 'an unknown peer list keeps it rather than guessing' {
    # $null means the lookup failed. Reading that as "nobody else is here" would delete
    # the dashboard of every other machine on any transient Home Assistant error.
    $d = Get-BridgeSharedStateDecision -Interactive $false -OtherMachines $null
    (-not $d.Clear) -and $d.Reason -match 'could not tell'
}

Test-That 'blank entries in the peer list do not count as machines' {
    $d = Get-BridgeSharedStateDecision -Interactive $false -OtherMachines @('', '   ')
    $d.Clear
}

Test-That '-KeepShared wins over a peer list that says this is the last machine' {
    $d = Get-BridgeSharedStateDecision -KeepShared -Interactive $false -OtherMachines @()
    (-not $d.Clear) -and $d.Reason -eq '-KeepShared'
}

Test-That '-ClearShared wins over a peer that is still running' {
    $d = Get-BridgeSharedStateDecision -ClearShared -Interactive $false -OtherMachines @('LAPTOP')
    $d.Clear -and $d.Reason -eq '-ClearShared'
}

Test-That 'both switches together resolve to the safe one' {
    $d = Get-BridgeSharedStateDecision -ClearShared -KeepShared -Interactive $false -OtherMachines $null
    -not $d.Clear
}

Write-Host '--- falling back to a prompt when the peer list is unknown ---'

Test-That 'a yes at the prompt removes the shared state' {
    $d = Get-BridgeSharedStateDecision -Interactive $true -OtherMachines $null -Prompt { $true }
    $d.Clear -and $d.Reason -match 'prompt'
}

Test-That 'a no at the prompt keeps it' {
    $d = Get-BridgeSharedStateDecision -Interactive $true -OtherMachines $null -Prompt { $false }
    -not $d.Clear
}

Test-That 'a known peer list is never overridden by a prompt' {
    # The prompt would throw if it ran, which is the assertion: detection outranks it.
    $d = Get-BridgeSharedStateDecision -Interactive $true -OtherMachines @('LAPTOP') `
        -Prompt { throw 'the prompt must not run when the answer is known' }
    -not $d.Clear
}

Test-That 'a non-interactive run never prompts' {
    $d = Get-BridgeSharedStateDecision -Interactive $false -OtherMachines $null `
        -Prompt { throw 'a scripted uninstall must not block on a prompt' }
    -not $d.Clear
}

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) test(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All multi-machine tests passed' -ForegroundColor Green