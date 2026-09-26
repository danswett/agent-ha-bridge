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
    $script:Published += [pscustomobject]@{ Topic = $Topic; Payload = $Payload }
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
Save-CopilotSessionDashboard -Sessions $twoMachineSessions -Machines $machines
$cfg = $script:SavedConfig
$cards = @($cfg.views[0].cards)

function Get-CardTitles { @($cards | Where-Object { $_.ContainsKey('title') } | ForEach-Object { [string]$_['title'] }) }
function Get-AllRowEntities {
    # Rows live at three depths: directly on an entities card, inside a conditional's
    # card, and inside the summary's vertical-stack.
    @($cards | ForEach-Object {
        if ($_['type'] -eq 'entities') { $_['entities'] }
        elseif ($_['type'] -eq 'conditional') { $_['card']['entities'] }
        elseif ($_['type'] -eq 'vertical-stack') {
            $_['cards'] | Where-Object { $_['type'] -eq 'entities' } | ForEach-Object { $_['entities'] }
        }
    } | Where-Object { $null -ne $_ -and $_.ContainsKey('entity') } | ForEach-Object { [string]$_['entity'] })
}
$rows = Get-AllRowEntities

Test-That 'there is a launch card for each machine' {
    $titles = Get-CardTitles
    ($titles -contains 'Start a new session on DESKTOP') -and ($titles -contains 'Start a new session on LAPTOP')
}
Test-That 'each launch card presses only its own machine' {
    ($rows -contains 'button.agent_bridge_desktop_new_session') -and
    ($rows -contains 'button.agent_bridge_laptop_new_session')
}
Test-That 'no unscoped launch button survives' {
    # The one every daemon used to watch, which made a single press launch everywhere.
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

$summary = @($cards | Where-Object { $_['type'] -eq 'vertical-stack' } |
    ForEach-Object { $_['cards'] } | Where-Object { $_['type'] -eq 'markdown' })[0]

Test-That 'the live count adds the machines together' {
    $summary.content -match "states\('sensor\.agent_bridge_desktop_sessions'\)\|int\(0\) \+ states\('sensor\.agent_bridge_laptop_sessions'\)\|int\(0\)"
}
Test-That 'each machine version is listed by name' {
    $summary.content -match '\*\*DESKTOP\*\*' -and $summary.content -match '\*\*LAPTOP\*\*'
}
Test-That 'the shared Detailed activity toggle stays shared' {
    # It is a display preference, not a property of a machine, so it is deliberately
    # the one bridge-level control that is not scoped.
    $rows -contains 'input_boolean.agent_bridge_detailed_activity'
}
Test-That 'both machines sessions get a card' {
    $content = ($cfg | ConvertTo-Json -Depth 30)
    $content -match 'desk work' -and $content -match 'lap work'
}
Test-That 'each session card names the machine it is on' {
    $content = ($cfg | ConvertTo-Json -Depth 30)
    $content -match 'DESKTOP' -and $content -match 'LAPTOP'
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
    @($soloCards | Where-Object { $_.ContainsKey('title') -and $_['title'] -eq 'Start a new session' }).Count -eq 1
}
Test-That 'the version is still labelled Bridge rather than the hostname' {
    $md = @($soloCards | Where-Object { $_['type'] -eq 'vertical-stack' } |
        ForEach-Object { $_['cards'] } | Where-Object { $_['type'] -eq 'markdown' })[0]
    $md.content -match '\*\*Bridge\*\*'
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