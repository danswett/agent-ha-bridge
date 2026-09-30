#Requires -Version 7.0
<#
.SYNOPSIS
    Tests the generated Home Assistant dashboard config.

.DESCRIPTION
    Save-CopilotSessionDashboard builds the whole Lovelace config from the live session
    list. These assert the parts that are easy to get wrong and that users see: the
    dashboard title, the view tab, the control card's live/version summary, and that a
    live session produces a card. The Home Assistant save is mocked, so nothing here
    touches a real instance.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-mqtt.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-ha-websocket.ps1')
# The failures these checks provoke on purpose went into the machine's real bridge log,
# where they buried real ones.
$script:DecisionBridgeConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-dashboard-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($ok) { Write-Host "  PASS  $Name" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

# Capture the config that would be saved instead of sending it to Home Assistant.
$script:SavedUrlPath = $null
$script:SavedConfig = $null
function Invoke-CopilotHaWebSocket {
    param([Parameter(Mandatory)][object[]]$Commands)
    $script:SavedUrlPath = $Commands[0].url_path
    $script:SavedConfig = $Commands[0].config
    @()
}

Write-Host '--- the dashboard is titled and routed correctly ---'
# Per-machine entity ids, derived rather than hard-coded so the suite passes on any
# machine including a CI runner. Without a -Machines list the dashboard renders the
# local machine alone, which is the single-machine case these tests cover.
$slug = Get-BridgeMachineSlug
$sessions = @(
    [pscustomobject]@{ Node = 'copilot_abc123def456'; Name = 'Copilot: my task'; Machine = 'BOX'; Kind = 'copilot' }
)
Save-CopilotSessionDashboard -Sessions $sessions
$cfg = $script:SavedConfig

Test-That 'the dashboard title is Agent Sessions' { $cfg.title -eq 'Agent Sessions' }
Test-That 'the view tab is titled Sessions' { $cfg.views[0].title -eq 'Sessions' }
Test-That 'the view path stays decision (URL slug unchanged)' { $cfg.views[0].path -eq 'decision' }
Test-That 'it is saved to the agent-decisions slug' { $script:SavedUrlPath -eq $script:DecisionBridgeConfig.DashboardUrlPath }

Write-Host '--- the control card summarises sessions and the installed version ---'
# The summary and its toggle are one stacked card now, so the markdown lives a level
# down rather than directly among the view's cards.
$agentCard = @($cfg.views[0].cards | Where-Object {
    $_.type -eq 'vertical-stack' -and @($_.cards | Where-Object { $_.type -eq 'markdown' -and $_.content -match 'Agent sessions' }).Count -gt 0
})[0]
Test-That 'the agent sessions card exists' { $null -ne $agentCard }
$control = @($agentCard.cards | Where-Object { $_.type -eq 'markdown' })[0]
Test-That 'the control markdown card exists' { $null -ne $control }
Test-That 'it shows the live session count' {
    # Summed across machines with int(0) on each term, so one machine's sensor being
    # briefly unavailable reads as zero rather than breaking the whole template.
    $control.content.Contains("states('sensor.agent_bridge_${slug}_sessions')|int(0)")
}
Test-That 'it shows the installed bridge version from the update entity' {
    $control.content.Contains("state_attr('update.agent_bridge_${slug}_update', 'installed_version')") -and
    $control.content.Contains('**Bridge**')
}

Write-Host '--- detailed activity is a setting, not a card ---'
# Folding session cards does what the toggle was for, and the toggle never changed how
# often anything is published, so it no longer takes a card of its own.
$toggleRows = @($agentCard.cards | Where-Object { $_.type -eq 'entities' } | ForEach-Object { $_.entities })
Test-That 'no Detailed activity toggle is drawn' {
    @($toggleRows | Where-Object { $_.entity -eq 'input_boolean.agent_bridge_detailed_activity' }).Count -eq 0 -and
        (($script:SavedConfig | ConvertTo-Json -Depth 40) -notmatch 'agent_bridge_detailed_activity')
}
Test-That 'and the summary no longer points at one' { $control.content -notmatch 'Detailed activity' }
Write-Host '--- the duplicate session counter is gone ---'
# The count is printed in the markdown above, so a sensor row repeating it was noise.
$allRows = @($cfg.views[0].cards | ForEach-Object {
    if ($_.type -eq 'vertical-stack') { $_.cards | Where-Object { $_.type -eq 'entities' } | ForEach-Object { $_.entities } }
    elseif ($_.type -eq 'entities') { $_.entities }
})
Test-That 'no card repeats the live-session sensor as a row' {
    @($allRows | Where-Object { $_.entity -eq "sensor.agent_bridge_${slug}_sessions" }).Count -eq 0
}
Test-That 'there is no longer a standalone toggle card beside the summary' {
    @($cfg.views[0].cards | Where-Object {
        $_.type -eq 'entities' -and @($_.entities | Where-Object { $_.entity -eq 'input_boolean.agent_bridge_detailed_activity' }).Count -gt 0
    }).Count -eq 0
}

Write-Host '--- from card 1.19.0 the summary and the machines are one folding card ---'
# Two markdown cards took a third of a phone screen to say "three sessions, nothing
# waiting", and the Detail switches sat in a list you had to match to machine names
# by eye. One card that folds says the same in a line, and puts each switch on the
# row of the machine it belongs to.
$twoMachines = @(
    [pscustomobject]@{ Slug = 'dswett_home'; Machine = 'DSWETT-HOME'; Online = $true; IncludeProfile = $false; IncludeResume = $true; IncludeAgent = $true; IncludeDetailed = $true }
    [pscustomobject]@{ Slug = 'dans_mbp'; Machine = 'Dans-MBP'; Online = $false; IncludeProfile = $false; IncludeResume = $true; IncludeAgent = $false; IncludeDetailed = $false }
)
Save-CopilotSessionDashboard -Sessions $sessions -Machines $twoMachines -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.19.0'
$status = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'custom:agent-bridge-status-card' })[0]
Test-That 'the status card is generated' { $null -ne $status }
Test-That 'it lists every machine that has registered, offline ones included' {
    (@($status['machines'] | ForEach-Object { [string]$_['machine'] }) -join ',') -eq 'DSWETT-HOME,Dans-MBP'
}
Test-That 'each with the entities it reads liveness, sessions and version from' {
    $m = @($status['machines'])[0]
    $m['online'] -eq 'binary_sensor.agent_bridge_dswett_home_online' -and
    $m['sessions'] -eq 'sensor.agent_bridge_dswett_home_sessions' -and
    $m['version'] -eq 'update.agent_bridge_dswett_home_update'
}
Test-That 'the Detail switch travels with the machine it belongs to' {
    @($status['machines'])[0]['detailed'] -eq 'input_boolean.agent_bridge_dswett_home_detailed_activity'
}
# The bug this guards: a peer on an older bridge has no such helper, so pointing a
# switch at one put an "Entity not found" box on everyone's dashboard.
Test-That 'and a machine that cannot have one is handed no entity for it' {
    -not @($status['machines'])[1].Contains('detailed')
}
Test-That 'it is given every session decision to count pending answers from' {
    @($status['decisions']) -contains 'select.copilot_abc123def456_decision'
}
Test-That 'the two markdown cards it replaces are gone, not left beside it' {
    $json = $script:SavedConfig | ConvertTo-Json -Depth 40 -Compress
    $json -notmatch '## Agent sessions' -and $json -notmatch '### Machines'
}
Test-That 'and it is the first card on the view' {
    [string]@($script:SavedConfig.views[0].cards)[0]['type'] -eq 'custom:agent-bridge-status-card'
}
Test-That 'a machine running a working copy is marked for the card to say so' {
    $dev = @([pscustomobject]@{ Slug = 'buildbox'; Machine = 'BUILDBOX'; Online = $true; IncludeProfile = $false; IncludeResume = $false; IncludeAgent = $false; IncludeDetailed = $true; IsDev = $true })
    Save-CopilotSessionDashboard -Sessions $sessions -Machines $dev -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.19.0'
    $card = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'custom:agent-bridge-status-card' })[0]
    [bool]@($card['machines'])[0]['dev']
}
Test-That 'a card that predates the X is given no topics to clear with it' {
    # An older card drops config keys it does not know without a word, so the rows
    # would look fine while the X was never there to press.
    -not @($status['machines'])[1].Contains('forget')
}

Write-Host '--- from card 1.20.0 a machine that is gone can be removed from the row ---'
# A machine that was renamed or reimaged never publishes under its old name again, so
# nothing it left behind would ever be withdrawn and its row read "offline" for good.
$forgetful = @(
    [pscustomobject]@{ Slug = 'dswett_home'; Machine = 'DSWETT-HOME'; Online = $true; IncludeProfile = $false; IncludeResume = $true; IncludeAgent = $true; IncludeDetailed = $true
        SessionNodes = @('agent_bridge_abcdef0123456789') }
    [pscustomobject]@{ Slug = 'old_name'; Machine = 'OLD-NAME'; Online = $false; IncludeProfile = $false; IncludeResume = $false; IncludeAgent = $false; IncludeDetailed = $false }
)
Save-CopilotSessionDashboard -Sessions $sessions -Machines $forgetful -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.20.0'
$forgetStatus = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'custom:agent-bridge-status-card' })[0]
Test-That 'every machine is handed the topics that removing it would clear' {
    @($forgetStatus['machines'] | Where-Object { @($_['forget']).Count -gt 0 }).Count -eq 2
}
Test-That 'they are that machine own controls, and nobody else' {
    $topics = @(@($forgetStatus['machines'])[1]['forget'])
    ($topics -contains 'homeassistant/sensor/agent_bridge_old_name/sessions/config') -and
    ($topics -contains 'homeassistant/binary_sensor/agent_bridge_old_name/online/config') -and
    @($topics | Where-Object { $_ -match 'dswett_home' }).Count -eq 0
}
Test-That 'a machine running sessions has those cleared with it' {
    # Its session entities are retained too, and with the machine gone nothing else
    # would ever come back for them.
    $topics = @(@($forgetStatus['machines'])[0]['forget'])
    @($topics | Where-Object { $_ -match 'agent_bridge_abcdef0123456789' }).Count -ge 2
}

Write-Host '--- an older served card keeps the pair it knows how to draw ---'
Save-CopilotSessionDashboard -Sessions $sessions -Machines $twoMachines -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.18.0'
$oldStatusJson = $script:SavedConfig | ConvertTo-Json -Depth 40 -Compress
Test-That 'no status card is drawn for it' { $oldStatusJson -notmatch 'agent-bridge-status-card' }
Test-That 'so the summary is still there' { $oldStatusJson -match '## Agent sessions' }
Test-That 'and so is the Machines card' { $oldStatusJson -match '### Machines' }

Write-Host '--- a live session produces a card ---'
Test-That 'the control cards plus a session card are present' { @($cfg.views[0].cards).Count -ge 3 }

Write-Host '--- the session renders as one card, not a stack of loose ones ---'
$sessionCard = @($cfg.views[0].cards | Where-Object {
    $_.type -eq 'vertical-stack' -and @($_.cards | Where-Object { $_.type -eq 'markdown' -and $_.content -match 'my task' }).Count -gt 0
})[0]
Test-That 'the session card exists' { $null -ne $sessionCard }
Test-That 'the stack itself carries the border and background' {
    $sessionCard.card_mod.style -match ':host' -and
    $sessionCard.card_mod.style -match 'background' -and
    $sessionCard.card_mod.style -match 'border'
}
Test-That 'the state glow moved onto the stack' {
    $sessionCard.card_mod.style -match 'cpwait' -and $sessionCard.card_mod.style -match 'cpwork'
}
Test-That 'the gaps between sections are collapsed' {
    $sessionCard.card_mod.style -match 'margin-top:\s*0'
}
$sessionHeader = @($sessionCard.cards | Where-Object { $_.type -eq 'markdown' })[0]
Test-That 'the header no longer draws its own border' {
    $sessionHeader.card_mod.style -match 'border:\s*none'
}
Test-That 'the header no longer owns the glow' {
    $sessionHeader.card_mod.style -notmatch 'cpwait'
}
Test-That 'every inner card is transparent so one surface shows through' {
    $inner = @($sessionCard.cards | Where-Object { $_.type -in @('markdown', 'conditional') })
    $opaque = foreach ($c in $inner) {
        $target = if ($c.type -eq 'conditional') { $c.card } else { $c }
        if ("$($target.type)" -eq 'custom:button-card') {
            # A button-card carries its own styles block rather than card-mod.
            if (@($target.styles.card | Where-Object { $_.ContainsKey('background') -and $_['background'] -eq 'none' }).Count -eq 0) { $target }
        }
        elseif ("$($target.card_mod.style)" -notmatch 'background:\s*none') { $target }
    }
    @($opaque).Count -eq 0
}

Write-Host '--- the decision row says what it actually does ---'
# On a multi-field question the per-field dropdowns carry the answer and this selector
# offers only "Cancel request". Rendered as a dropdown it was a third thing to fill in,
# sitting exactly where the last field should have been - reported from the dashboard
# as "still three things to fill in" even after it had been relabelled.
$answerRow = @($sessionCard.cards | Where-Object {
    $_.type -eq 'conditional' -and $_.card.type -eq 'entities' -and
    "$($_.card.entities[0].entity)" -match '_decision$'
})[0]
$cancelRow = @($sessionCard.cards | Where-Object {
    $_.type -eq 'conditional' -and $_.card.type -eq 'custom:button-card' -and
    "$($_.card.name)" -eq 'Cancel this request'
})[0]

Test-That 'the answer dropdown is still there for a single-field question' {
    $null -ne $answerRow -and $answerRow.card.entities[0].name -eq 'Answer'
}
Test-That 'cancelling is a button, not another dropdown to fill in' {
    $null -ne $cancelRow
}
Test-That 'and it actually cancels when tapped' {
    "$($cancelRow.card.tap_action.perform_action)" -eq 'select.select_option' -and
    "$($cancelRow.card.tap_action.data.option)" -eq 'Cancel request'
}
Test-That 'Answer shows only when no field dropdown is in play' {
    @($answerRow.conditions | Where-Object {
        "$($_.entity)" -match '_f1$' -and "$($_.state)" -eq 'Idle'
    }).Count -eq 1
}
Test-That 'Cancel shows only when a field dropdown is in play' {
    @($cancelRow.conditions | Where-Object {
        "$($_.entity)" -match '_f1$' -and "$($_.state_not)" -eq 'Idle'
    }).Count -eq 1
}
Test-That 'so the two can never appear together' {
    $a = @($answerRow.conditions | Where-Object { "$($_.entity)" -match '_f1$' })[0]
    $c = @($cancelRow.conditions | Where-Object { "$($_.entity)" -match '_f1$' })[0]
    "$($a.entity)" -eq "$($c.entity)" -and "$($a.state)" -eq 'Idle' -and "$($c.state_not)" -eq 'Idle'
}
Test-That 'cancel sits with End session, not among the questions' {
    $idx = 0; $cancelIdx = -1; $replyIdx = -1
    foreach ($c in $sessionCard.cards) {
        if ($c.type -eq 'custom:layout-card') { $replyIdx = $idx }
        if ($c.type -eq 'conditional' -and $c.card.type -eq 'custom:button-card') { $cancelIdx = $idx }
        $idx++
    }
    $cancelIdx -gt $replyIdx -and $replyIdx -ge 0
}

Write-Host '--- End session is a footer, well away from Send ---'
$stop = $sessionCard.cards[-1]
Test-That 'End session is the last thing on the card' { $stop.entity -match '_stop$' }
Test-That 'send feedback sits next to Send, not in the header' {
    # The header is the first thing to scroll away on a long card, which is exactly
    # when "Sending..." or "NOT sent" needs to be visible.
    $idx = 0
    $statusIdx = -1
    $replyIdx = -1
    foreach ($c in $sessionCard.cards) {
        if ($c.type -eq 'custom:layout-card') { $replyIdx = $idx }
        if ($c.type -eq 'conditional' -and $c.card.type -eq 'markdown' -and
            "$($c.conditions[0].entity)" -match '_activity$') { $statusIdx = $idx }
        $idx++
    }
    $statusIdx -gt $replyIdx -and $replyIdx -ge 0
}
Test-That 'it only shows while reporting on something you just did' {
    $status = @($sessionCard.cards | Where-Object { $_.type -eq 'conditional' -and $_.card.type -eq 'markdown' })[0]
    @($status.conditions[0].state) -contains 'Sending...' -and @($status.conditions[0].state) -contains 'Reply NOT sent'
}
Test-That 'it is separated by a hairline rather than butting up to Send' {
    @($stop.styles.card | Where-Object { $_.ContainsKey('border-top') }).Count -gt 0
}
Test-That 'it is left-aligned, unlike the right-aligned Send button' {
    @($stop.styles.grid | Where-Object { $_.ContainsKey('justify-items') -and $_['justify-items'] -eq 'start' }).Count -gt 0
}
Test-That 'it is rendered muted rather than as a primary action' {
    @($stop.styles.name | Where-Object { $_.ContainsKey('color') -and $_['color'] -match 'secondary-text-color' }).Count -gt 0
}

# What a session was started with, quietly, at the bottom of its card. Rendered from
# the status sensor's attributes rather than baked in at build time, because the
# dashboard is only rebuilt when the session list changes - a model swapped
# mid-session would otherwise keep showing the one it started on.
$settings = @($sessionCard.cards | Where-Object {
    $_.type -eq 'markdown' -and "$($_.content)" -match "state_attr\('sensor\.copilot_abc123def456_status','model'\)"
})[0]
Test-That 'the card says what the session is running with' { $null -ne $settings }
Test-That 'all three settings are shown, not just the model' {
    "$($settings.content)" -match "'effort'" -and "$($settings.content)" -match "'context'"
}
# A session started at a keyboard has none of these, and a row of blanks - or a guess
# at the agent's defaults - would be worse than saying nothing.
Test-That 'a session with none of them shows no line at all' {
    "$($settings.content)" -match 'if bits'
}
Test-That 'it sits at the bottom, just above End session' {
    $idx = 0; $settingsIdx = -1
    foreach ($c in $sessionCard.cards) {
        if ($c.type -eq 'markdown' -and "$($c.content)" -match "_status','model'") { $settingsIdx = $idx }
        $idx++
    }
    $settingsIdx -eq $sessionCard.cards.Count - 2
}
Test-That 'Send and End are not in the same row' {
    $replyRow = @($sessionCard.cards | Where-Object { $_.type -eq 'custom:layout-card' })[0]
    $inRow = @($replyRow.cards | ForEach-Object { if ($_.ContainsKey('entity')) { [string]$_['entity'] } else { '' } })
    ($inRow -join ' ') -notmatch '_stop'
}
Test-That 'Send is still in the reply row' {
    $replyRow = @($sessionCard.cards | Where-Object { $_.type -eq 'custom:layout-card' })[0]
    $inRow = @($replyRow.cards | ForEach-Object { if ($_.ContainsKey('entity')) { [string]$_['entity'] } else { '' } })
    ($inRow -join ' ') -match '_submit'
}

Write-Host ''
Write-Host '--- a free-text field leaves no empty dropdown behind ---'
# A text field is answered through the reply box, not a dropdown, so its slot is
# published with only the 'Idle' option. It was still *started* on 'Choose...', a value
# not in its own option list, so the dashboard's "hide while Idle" condition failed and
# a blank dropdown appeared between the real ones.
$script:FieldStarts = @{}
$script:FieldOptions = @{}
function Publish-CopilotMqttMessage {
    param([string]$Topic, [string]$Payload, [hashtable]$Headers, [switch]$Retain)
    if ($Topic -match '/select/[^/]+/(f\d)/config$') {
        $script:FieldOptions[$Matches[1]] = ($Payload | ConvertFrom-Json).options
    }
}
function Invoke-HomeAssistantService {
    param([string]$Domain, [string]$Service, [hashtable]$Headers, [hashtable]$Data)
    if ("$($Data.entity_id)" -match '_(f\d)$') { $script:FieldStarts[$Matches[1]] = [string]$Data.option }
}
function Set-CopilotMqttEntityIds { param([string]$SessionId) }

$mixedFields = @(
    [pscustomobject]@{ Label = 'Glow';  Options = @('Amber', 'Blue'); IsText = $false }
    [pscustomobject]@{ Label = 'Notes'; Options = @();                IsText = $true }
    [pscustomobject]@{ Label = 'Pick';  Options = @('One', 'Two');    IsText = $false }
)
Publish-CopilotMqttDecisionFields -SessionId 'abc123de-f456-7890-abcd-ef1234567890' `
    -SessionName 'S' -Machine 'BOX' -Fields $mixedFields -Headers @{ Authorization = '******' }

Test-That 'the two choice fields start on Choose...' {
    $script:FieldStarts['f1'] -eq 'Choose...' -and $script:FieldStarts['f3'] -eq 'Choose...'
}
Test-That 'the free-text slot is parked on Idle, like an unused one' {
    $script:FieldStarts['f2'] -eq 'Idle' -and $script:FieldStarts['f4'] -eq 'Idle'
}
Test-That 'and its starting value is one of its own options' {
    @($script:FieldOptions['f2']) -contains $script:FieldStarts['f2']
}
Test-That 'the choice slots still carry their real options' {
    @($script:FieldOptions['f1']) -contains 'Amber' -and @($script:FieldOptions['f3']) -contains 'Two'
}

# A multi-select field cannot be offered as its bare options: a Home Assistant select
# holds one value, so picking one would quietly answer "choose any" with exactly one.
# Its dropdown carries the combinations instead.
$script:FieldOptions = @{}; $script:FieldStarts = @{}
$msFields = @(
    [pscustomobject]@{ Label = 'Envs';  Options = @('Staging', 'Production'); IsText = $false; MultiSelect = $true }
    [pscustomobject]@{ Label = 'Pick';  Options = @('One', 'Two');            IsText = $false }
)
Publish-CopilotMqttDecisionFields -SessionId 'abc123de-f456-7890-abcd-ef1234567890' `
    -SessionName 'S' -Machine 'BOX' -Fields $msFields -Headers @{ Authorization = '******' }

Test-That 'a multi-select slot lists every combination' {
    (@($script:FieldOptions['f1']) -join ' / ') -eq 'Choose... / Staging / Production / Staging + Production'
} (@($script:FieldOptions['f1']) -join ' / ')
Test-That 'a single-select slot beside it is unchanged' {
    (@($script:FieldOptions['f2']) -join ' / ') -eq 'Choose... / One / Two'
} (@($script:FieldOptions['f2']) -join ' / ')
Test-That 'and it still starts on Choose...' { $script:FieldStarts['f1'] -eq 'Choose...' }

Write-Host ''
Write-Host '--- the new-session card is only what a launch needs ---'
# The card exists to be one press: every selector carries a default. The first
# message is back, optional: Codex creates no session until it has one. The launch
# note sits in the same stack, right under Launch, so a press never looks ignored.
Save-CopilotSessionDashboard -Sessions $sessions -IncludeProfile -IncludeResume
$launchStack = @($script:SavedConfig.views[0].cards | Where-Object {
    $_['type'] -eq 'vertical-stack' -and @($_['cards'] | Where-Object { $_.ContainsKey('title') -and $_['title'] -eq 'Start a new session' }).Count -gt 0
})[0]
$newCard = @($launchStack['cards'] | Where-Object { $_.ContainsKey('title') -and $_['title'] -eq 'Start a new session' })[0]
$newRows = @($newCard.entities | ForEach-Object {
    if ($_.ContainsKey('entity')) { [string]$_['entity'] } else { '' }
})

Test-That 'the card is still generated' { $null -ne $newCard }
Test-That 'it keeps the selectors and Launch' {
    ($newRows -contains "select.agent_bridge_${slug}_new_resume") -and
    ($newRows -contains "select.agent_bridge_${slug}_new_workspace") -and
    ($newRows -contains "select.agent_bridge_${slug}_new_profile") -and
    ($newRows -contains "button.agent_bridge_${slug}_new_session")
}
Test-That 'the last-launch result is not a row' {
    $newRows -notcontains "sensor.agent_bridge_${slug}_new_session_result"
}
Test-That 'an optional first message is offered' {
    $newRows -contains "text.agent_bridge_${slug}_new_prompt"
}
Test-That 'Launch is the last thing on the card' { $newRows[-1] -eq "button.agent_bridge_${slug}_new_session" }
Test-That 'the launch note sits right under the card, only when there is something to say' {
    $note = @($launchStack['cards'] | Where-Object {
        $_['type'] -eq 'conditional' -and $_['card']['type'] -eq 'markdown' -and
        [string]$_['card']['content'] -match 'new_session_result'
    })[0]
    $null -ne $note -and
    @($note['conditions'] | ForEach-Object { [string]$_['state_not'] }) -contains '' -and
    @($note['conditions'] | ForEach-Object { [string]$_['state_not'] }) -contains 'unknown'
}

# From card 1.12.0 the bridge draws a compact launch card of its own.
Save-CopilotSessionDashboard -Sessions $sessions -IncludeProfile -IncludeResume -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.12.0'
$compact = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'custom:agent-bridge-launch-card' })
Test-That 'a served 1.12.0 card gets the compact launch card' { $compact.Count -eq 1 }
Test-That 'which carries every control of the machine' {
    $m = @($compact[0]['machines'])[0]
    $m['launch'] -eq "button.agent_bridge_${slug}_new_session" -and $m['prompt'] -eq "text.agent_bridge_${slug}_new_prompt" -and
        $m['result'] -eq "sensor.agent_bridge_${slug}_new_session_result" -and $m['workspace'] -eq "select.agent_bridge_${slug}_new_workspace"
}
Test-That 'and no separate launch cards are left beside it' {
    @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'vertical-stack' -and ($_ | ConvertTo-Json -Depth 20) -match 'new_session_result' }).Count -eq 0
}
Save-CopilotSessionDashboard -Sessions $sessions -IncludeProfile -IncludeResume
Test-That 'there is no agent row when there is nothing to choose between' {
    $newRows -notcontains "select.agent_bridge_${slug}_new_agent"
}

Save-CopilotSessionDashboard -Sessions $sessions -IncludeAgent
$newCard = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'vertical-stack' } | ForEach-Object { $_['cards'] } |
    Where-Object { $_.ContainsKey('title') -and $_['title'] -eq 'Start a new session' })[0]
$agentRows = @($newCard.entities | ForEach-Object { if ($_.ContainsKey('entity')) { [string]$_['entity'] } else { '' } })
Test-That 'with several agents installed the agent row is shown' {
    $agentRows -contains "select.agent_bridge_${slug}_new_agent"
}
Test-That 'the agent row sits under the workspace' {
    $agentRows.IndexOf("select.agent_bridge_${slug}_new_agent") -eq $agentRows.IndexOf("select.agent_bridge_${slug}_new_workspace") + 1
}

# Model, effort and context. Reported as a capability of their own, so a peer still
# running a bridge without those entities gets a launch card without the rows rather
# than three "Entity not found" boxes.
Save-CopilotSessionDashboard -Sessions $sessions -IncludeAgent -IncludeTuning
$tunedCard = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'vertical-stack' } | ForEach-Object { $_['cards'] } |
    Where-Object { $_.ContainsKey('title') -and $_['title'] -eq 'Start a new session' })[0]
$tunedRows = @($tunedCard.entities | ForEach-Object { if ($_.ContainsKey('entity')) { [string]$_['entity'] } else { '' } })
Test-That 'the tuning rows are shown when the machine has them' {
    @('model', 'effort', 'context') | ForEach-Object { $tunedRows -contains "select.agent_bridge_${slug}_new_$_" } |
        Where-Object { -not $_ } | Measure-Object | ForEach-Object { $_.Count -eq 0 }
}
# Their options belong to whichever agent is selected, so choosing the agent is what
# decides what they can offer: reading top-to-bottom is also the order to set them in.
Test-That 'and sit below the agent that decides what they offer' {
    $tunedRows.IndexOf("select.agent_bridge_${slug}_new_model") -gt $tunedRows.IndexOf("select.agent_bridge_${slug}_new_agent")
}
Test-That 'Launch is still the last thing on the card' {
    $tunedRows[-1] -eq "button.agent_bridge_${slug}_new_session"
}
Test-That 'a machine without them gets no tuning rows at all' {
    @('model', 'effort', 'context') | ForEach-Object { $agentRows -contains "select.agent_bridge_${slug}_new_$_" } |
        Where-Object { $_ } | Measure-Object | ForEach-Object { $_.Count -eq 0 }
}

# The compact card draws them itself, and only from 1.16.0 - an older card silently
# ignores keys it does not know, which would look like the rows had simply vanished.
Save-CopilotSessionDashboard -Sessions $sessions -IncludeAgent -IncludeTuning -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.16.0'
$tunedCompact = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'custom:agent-bridge-launch-card' })[0]
Test-That 'the compact card is handed all three tuning entities' {
    $m = @($tunedCompact['machines'])[0]
    $m['model'] -eq "select.agent_bridge_${slug}_new_model" -and
    $m['effort'] -eq "select.agent_bridge_${slug}_new_effort" -and
    $m['context'] -eq "select.agent_bridge_${slug}_new_context"
}
Save-CopilotSessionDashboard -Sessions $sessions -IncludeAgent -IncludeTuning -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.15.0'
$oldCompact = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'custom:agent-bridge-launch-card' })[0]
Test-That 'a card too old to draw them is not handed them' {
    -not @($oldCompact['machines'])[0].Contains('model')
}

# Permissions. The machine that runs the session is not always the one choosing, so
# the row has to reach the dashboard the peer draws - the row and the card entry were
# both added at once, and each fails invisibly on its own.
Save-CopilotSessionDashboard -Sessions $sessions -IncludeAgent -IncludeTuning -IncludePermissions
$permCard = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'vertical-stack' } | ForEach-Object { $_['cards'] } |
    Where-Object { $_.ContainsKey('title') -and $_['title'] -eq 'Start a new session' })[0]
$permRows = @($permCard.entities | ForEach-Object { if ($_.ContainsKey('entity')) { [string]$_['entity'] } else { '' } })
Test-That 'the permissions row is shown when the machine offers it' {
    $permRows -contains "select.agent_bridge_${slug}_new_permissions"
}
Test-That 'it sits below the settings it applies to, and above Launch' {
    $permRows.IndexOf("select.agent_bridge_${slug}_new_permissions") -gt $permRows.IndexOf("select.agent_bridge_${slug}_new_model") -and
    $permRows.IndexOf("select.agent_bridge_${slug}_new_permissions") -lt $permRows.IndexOf("button.agent_bridge_${slug}_new_session")
}
Test-That 'a machine that does not offer it gets no such row' {
    $tunedRows -notcontains "select.agent_bridge_${slug}_new_permissions"
}

Save-CopilotSessionDashboard -Sessions $sessions -IncludeAgent -IncludeTuning -IncludePermissions -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.17.0'
$permCompact = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'custom:agent-bridge-launch-card' })[0]
Test-That 'the compact card is handed the permissions entity' {
    @($permCompact['machines'])[0]['permissions'] -eq "select.agent_bridge_${slug}_new_permissions"
} ([string](@($permCompact['machines'])[0]['permissions']))
Save-CopilotSessionDashboard -Sessions $sessions -IncludeAgent -IncludeTuning -IncludePermissions -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.16.0'
$preCompact = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'custom:agent-bridge-launch-card' })[0]
Test-That 'and a card too old to draw it is not, so it is never silently dropped' {
    -not @($preCompact['machines'])[0].Contains('permissions')
}

# The long first message arrived with 1.18.0. A card that knows the topic publishes
# the whole prompt there; an older one writes the text entity, which Home Assistant
# caps at 255 characters.
Save-CopilotSessionDashboard -Sessions $sessions -IncludeAgent -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.18.0'
$promptCompact = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'custom:agent-bridge-launch-card' })[0]
Test-That 'a 1.18.0 card is told where to publish a long first message' {
    @($promptCompact['machines'])[0]['promptTopic'] -match 'newsession/promptpayload$'
} ([string](@($promptCompact['machines'])[0]['promptTopic']))
Test-That 'and still gets the text entity, so it has something to fall back on' {
    @($promptCompact['machines'])[0]['prompt'] -eq "text.agent_bridge_${slug}_new_prompt"
}
Save-CopilotSessionDashboard -Sessions $sessions -IncludeAgent -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.17.0'
$oldPromptCompact = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'custom:agent-bridge-launch-card' })[0]
Test-That 'a 1.17.0 card is not handed a key it would drop' {
    -not @($oldPromptCompact['machines'])[0].Contains('promptTopic')
}

Write-Host ''
Write-Host '--- the session header updates in place when the card supports it ---'
# The markdown header re-renders wholesale on every attribute change, collapsing the
# reasoning expander while it streams. The activity card ships in the reply card's
# file from 1.10.0, and naming it against an older served copy would render an error.
function Get-SavedJson { $script:SavedConfig | ConvertTo-Json -Depth 40 -Compress }

Save-CopilotSessionDashboard -Sessions $sessions -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.10.0'
Test-That 'a served 1.10.0 card gets the in-place activity header' { (Get-SavedJson) -match 'custom:agent-bridge-activity-card' }
Test-That 'the header is pointed at the session entities' {
    (Get-SavedJson) -match [regex]::Escape("sensor.$($sessions[0].Node)_activity")
}

Save-CopilotSessionDashboard -Sessions $sessions -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.9.2'
Test-That 'an older served card keeps the markdown header' { (Get-SavedJson) -notmatch 'custom:agent-bridge-activity-card' }

Save-CopilotSessionDashboard -Sessions $sessions
Test-That 'no served card keeps the markdown header' { (Get-SavedJson) -notmatch 'custom:agent-bridge-activity-card' }

Test-That 'the version gate reads the cache-buster' {
    (Test-BridgeActivityCardServed -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.10.1') -and
    (Test-BridgeActivityCardServed -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=2.0') -and
    -not (Test-BridgeActivityCardServed -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.9.9') -and
    -not (Test-BridgeActivityCardServed -ReplyCardUrl '/local/agent-bridge-reply-card.js')
}

Write-Host ''
Write-Host '--- the session frame does not depend on card-mod loading first ---'
# A card-mod-styled vertical-stack lost its outline, background and glow on a hard
# refresh whenever it was built before card-mod loaded. From 1.12.0 the bridge's own
# card draws them.
Save-CopilotSessionDashboard -Sessions $sessions -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.12.0'
$framed = $script:SavedConfig | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
$sessionCard = @($framed.views[0].cards | Where-Object { $_.type -eq 'custom:agent-bridge-session-card' }) | Select-Object -First 1
Test-That 'a served 1.12.0 card frames each session with the session card' { $null -ne $sessionCard }
Test-That 'which watches the session status and decision for its glow' {
    $sessionCard.status -eq "sensor.$($sessions[0].Node)_status" -and $sessionCard.decision -eq "select.$($sessions[0].Node)_decision"
}
# The driver is an attribute of the activity sensor, so a frame not given that entity
# reads every session as yours and can never show the purple edge - which is exactly
# what shipped, on every dashboard, for three releases. The card's own test supplies
# all three keys itself, so nothing failed while the view handed over only two.
Test-That 'and the activity entity, without which the agent glow can never fire' {
    $sessionCard.activity -eq "sensor.$($sessions[0].Node)_activity"
} "activity=[$(if ($sessionCard.PSObject.Properties['activity']) { $sessionCard.activity } else { '<missing>' })]"
Test-That 'and holds the session sections' { @($sessionCard.cards | Where-Object { $_.type -eq 'custom:agent-bridge-activity-card' }).Count -eq 1 }

# A question is answered through the entities: the daemon reads the free-text field
# from text.<node>_reply and waits for a press on button.<node>_submit. The reply card
# writes neither - its Send publishes an MQTT payload, which the reply path ignores
# while a question owns the box, and it returns early on an empty textarea. So a form
# under the card took every dropdown and did nothing at all on Send, silently and with
# nothing in the daemon log. The pair has to come back while a question is armed.
$decEntity = "select.$($sessions[0].Node)_decision"
$cardWhenFree = @($sessionCard.cards | Where-Object {
    $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'custom:agent-bridge-reply-card' })
$pairWhenAsked = @($sessionCard.cards | Where-Object {
    $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'custom:layout-card' })
Test-That 'the reply card is shown only while no question is waiting' {
    $cardWhenFree.Count -eq 1 -and
        @($cardWhenFree[0].conditions | Where-Object { $_.entity -eq $decEntity -and @($_.state) -contains 'Idle' }).Count -eq 1
} "found $($cardWhenFree.Count)"
Test-That 'and the entity pair, which can actually answer one, takes over when it is' {
    $pairWhenAsked.Count -eq 1 -and
        @($pairWhenAsked[0].conditions | Where-Object { $_.entity -eq $decEntity -and "$($_.state_not)" -eq 'Idle' }).Count -eq 1
} "found $($pairWhenAsked.Count)"
Save-CopilotSessionDashboard -Sessions $sessions -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.11.3'
Test-That 'an older served card keeps the styled stack' { (Get-SavedJson) -notmatch 'agent-bridge-session-card' }

Write-Host ''
Write-Host '--- a waiting question is answered by rows, not a dropdown ---'
# Home Assistant's select sizes its menu to the longest option and will not wrap, so on
# a phone a question whose answers are sentences ran off the edge of the screen.
Save-CopilotSessionDashboard -Sessions $sessions -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.13.0'
$rowsCard = $script:SavedConfig | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
$rowsSession = @($rowsCard.views[0].cards | Where-Object { $_.type -eq 'custom:agent-bridge-session-card' }) | Select-Object -First 1
$answer = @($rowsSession.cards | Where-Object {
    $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'custom:agent-bridge-choices-card'
})[0]
Test-That 'a served 1.13.0 card answers with the choices card' { $null -ne $answer }
Test-That 'pointed at the session''s decision entity' { $answer.card.decision -eq "select.$($sessions[0].Node)_decision" }
Test-That 'it is transparent like every other section' { "$($answer.card.card_mod.style)" -match 'background:\s*none' }
Test-That 'and still only while no field dropdown is in play' {
    @($answer.conditions | Where-Object { "$($_.entity)" -match '_f1$' -and "$($_.state)" -eq 'Idle' }).Count -eq 1
}
Test-That 'the dropdown row is gone with it' {
    @($rowsSession.cards | Where-Object {
        $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'entities' -and
        "$($_.card.entities[0].entity)" -match '_decision$'
    }).Count -eq 0
}
Save-CopilotSessionDashboard -Sessions $sessions -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.12.3'
Test-That 'an older served card keeps the dropdown, not an error box' {
    (Get-SavedJson) -notmatch 'agent-bridge-choices-card'
}

Write-Host ''
Write-Host '--- and from 1.15.0 the same card answers the whole form ---'
# A form used to render as one native dropdown per field. A native select commits on
# blur, so an answer needed a tap away and then Send, and it sizes its menu to the
# longest option without wrapping, so sentence-length answers were cut off on a phone.
# The card draws a labelled group of rows per field instead - but only if the view
# actually hands it the field entities, which is the link this pins down.
Save-CopilotSessionDashboard -Sessions $sessions -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.15.0'
$formDash = $script:SavedConfig | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
$formSession = @($formDash.views[0].cards | Where-Object { $_.type -eq 'custom:agent-bridge-session-card' }) | Select-Object -First 1
$formAnswer = @($formSession.cards | Where-Object {
    $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'custom:agent-bridge-choices-card'
})[0]
$node = $sessions[0].Node
Test-That 'the choices card is handed the field entities' {
    $null -ne $formAnswer -and $formAnswer.card.PSObject.Properties['fields']
} "fields=[$(if ($null -ne $formAnswer -and $formAnswer.card.PSObject.Properties['fields']) { @($formAnswer.card.fields) -join ',' } else { '<missing>' })]"
# The ids themselves, not just their presence: the card sets these entities and
# Read-DaemonFormAnswer reads them, so a rename on either side is a form that takes
# every tap and delivers nothing. Both sides are asked the same helper.
Test-That 'and they are exactly the slots the daemon reads, in slot order' {
    $expected = @(1..4 | ForEach-Object { Get-CopilotMqttFieldEntityId -Node $node -Index $_ })
    (@($formAnswer.card.fields) -join ',') -eq ($expected -join ',')
} "fields=[$(@($formAnswer.card.fields) -join ',')]"
Test-That 'the answer card no longer hides itself when a field is in play' {
    @($formAnswer.conditions | Where-Object { "$($_.entity)" -match '_f\d$' }).Count -eq 0
}
Test-That 'the per-field dropdowns it replaces are gone' {
    @($formSession.cards | Where-Object {
        $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'entities' -and
        "$($_.card.entities[0].entity)" -match '_f\d$'
    }).Count -eq 0
}
Test-That 'and so is the separate cancel button, which the card draws as a row' {
    @($formSession.cards | Where-Object {
        $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'custom:button-card' -and
        "$($_.card.name)" -eq 'Cancel this request'
    }).Count -eq 0
}
Test-That 'the entity pair still takes over the reply box while a question is armed' {
    @($formSession.cards | Where-Object {
        $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'custom:layout-card'
    }).Count -eq 1
}
Test-That 'End session is still the last thing on the card' {
    "$($formSession.cards[-1].entity)" -match '_stop$'
}
Save-CopilotSessionDashboard -Sessions $sessions -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.14.5'
$oldDash = $script:SavedConfig | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
$oldSession = @($oldDash.views[0].cards | Where-Object { $_.type -eq 'custom:agent-bridge-session-card' }) | Select-Object -First 1
Test-That 'a card served before 1.15.0 keeps its dropdowns rather than an empty form' {
    @($oldSession.cards | Where-Object {
        $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'entities' -and
        "$($_.card.entities[0].entity)" -match '_f\d$'
    }).Count -eq 4
}
Test-That 'and is handed no fields it would not know what to do with' {
    $old = @($oldSession.cards | Where-Object {
        $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'custom:agent-bridge-choices-card'
    })[0]
    $null -ne $old -and -not $old.card.PSObject.Properties['fields']
}

Write-Host '--- the dashboard is provisioned before it is written to ---'
# Invoke-CopilotHaWebSocket hands back each command's `result` already unwrapped, so
# a caller that reaches for `.result` again finds nothing and silently creates no
# dashboard - which left the daemon logging config_not_found on every rebuild.
$script:SentCommands = @()
function Invoke-CopilotHaWebSocket {
    param([Parameter(Mandatory)][object[]]$Commands)
    $script:SentCommands += $Commands[0]
    if ($Commands[0].type -eq 'lovelace/dashboards/list') {
        # Shaped the way the real helper returns it: the list itself, not a wrapper.
        return , @(
            [pscustomobject]@{ url_path = 'copilot-decisions'; id = 'old-id'; title = 'Agent Sessions' }
            [pscustomobject]@{ url_path = 'lovelace'; id = 'home-id'; title = 'Home' }
        )
    }
    @()
}

$script:BridgeDashboardReady = $false
Initialize-BridgeDashboard

$created = @($script:SentCommands | Where-Object { $_.type -eq 'lovelace/dashboards/create' })
$deleted = @($script:SentCommands | Where-Object { $_.type -eq 'lovelace/dashboards/delete' })

Test-That 'the target dashboard is created when it is missing' { $created.Count -eq 1 }
Test-That 'it is created at the configured slug' {
    $created[0].url_path -eq $script:DecisionBridgeConfig.DashboardUrlPath
}
Test-That 'it is created as Agent Sessions' { $created[0].title -eq 'Agent Sessions' }
Test-That 'it is shown in the sidebar' { $created[0].show_in_sidebar }
Test-That 'the pre-rename dashboard is removed' { $deleted.Count -eq 1 }
Test-That 'it is removed by id, not by slug' { $deleted[0].dashboard_id -eq 'old-id' }
Test-That 'the replacement is created before the old one is deleted' {
    $types = @($script:SentCommands | ForEach-Object { $_.type })
    [array]::IndexOf($types, 'lovelace/dashboards/create') -lt [array]::IndexOf($types, 'lovelace/dashboards/delete')
}
Test-That 'an unrelated dashboard is left alone' {
    -not (@($deleted | Where-Object { $_.dashboard_id -eq 'home-id' }).Count)
}

Write-Host '--- provisioning happens once, not on every rebuild ---'
$script:SentCommands = @()
Initialize-BridgeDashboard
Test-That 'a second call makes no further round trips' { $script:SentCommands.Count -eq 0 }

Write-Host '--- an existing dashboard is left as it is ---'
$script:SentCommands = @()
$script:BridgeDashboardReady = $false
function Invoke-CopilotHaWebSocket {
    param([Parameter(Mandatory)][object[]]$Commands)
    $script:SentCommands += $Commands[0]
    if ($Commands[0].type -eq 'lovelace/dashboards/list') {
        return , @([pscustomobject]@{
            url_path = $script:DecisionBridgeConfig.DashboardUrlPath; id = 'cur'; title = 'Agent Sessions'
        })
    }
    @()
}
Initialize-BridgeDashboard
Test-That 'nothing is created when the dashboard already exists' {
    -not (@($script:SentCommands | Where-Object { $_.type -eq 'lovelace/dashboards/create' }).Count)
}
Test-That 'nothing is deleted when there is no pre-rename dashboard' {
    -not (@($script:SentCommands | Where-Object { $_.type -eq 'lovelace/dashboards/delete' }).Count)
}

Write-Host ''
Write-Host '--- who is driving a session ---'
# An agent driving a session sets the reply text and presses Submit, exactly as the
# dashboard does for a person, so the two arrive as identical service calls. The Home
# Assistant account behind the press is the only thing that differs - and only if the
# agent has an account of its own, which is why this is configured, never guessed.
function New-PressState {
    param([AllowEmptyString()][AllowNull()][string]$UserId, [switch]$NoContext)
    if ($NoContext) { return [pscustomobject]@{ entity_id = 'button.x'; state = 'ts' } }
    [pscustomobject]@{
        entity_id = 'button.x'; state = 'ts'
        context = [pscustomobject]@{ id = 'abc'; parent_id = $null; user_id = $UserId }
    }
}
$script:AgentIds = @()
function Get-BridgeSetting {
    param($Path, $Default)
    if ($Path -eq 'homeAssistant.agentUserIds') { return $script:AgentIds }
    $Default
}

Test-That 'the user is read off the press' {
    (Get-BridgeStateUserId -State (New-PressState -UserId 'user-1')) -eq 'user-1'
}
Test-That 'a state with no context at all is handled, not thrown on' {
    (Get-BridgeStateUserId -State (New-PressState -NoContext)) -eq ''
}
Test-That 'and so is no state' { (Get-BridgeStateUserId -State $null) -eq '' }

$script:AgentIds = @()
Test-That 'with no agent configured, nothing is an agent' { -not (Test-BridgeAgentUserId -UserId 'user-1') }
Test-That 'so a session reads as yours' {
    (Get-BridgeDriverFromState -State (New-PressState -UserId 'user-1')) -eq 'human'
}

$script:AgentIds = @('agent-user')
Test-That 'the configured agent is recognised' { Test-BridgeAgentUserId -UserId 'agent-user' }
Test-That 'anyone else is not' { -not (Test-BridgeAgentUserId -UserId 'user-1') }
Test-That 'a press from the agent marks the session agent-driven' {
    (Get-BridgeDriverFromState -State (New-PressState -UserId 'agent-user')) -eq 'agent'
}
Test-That 'a press from you does not' {
    (Get-BridgeDriverFromState -State (New-PressState -UserId 'user-1')) -eq 'human'
}
Test-That 'a press carrying no user - an automation, say - is not an agent' {
    (Get-BridgeDriverFromState -State (New-PressState -UserId '')) -eq 'human'
}
$script:AgentIds = @('  agent-user  ')
Test-That 'whitespace around a configured id does not stop it matching' {
    Test-BridgeAgentUserId -UserId 'agent-user'
}
$script:AgentIds = @('', '   ')
Test-That 'and a blank entry never matches a blank user' { -not (Test-BridgeAgentUserId -UserId '') }

Remove-Item -LiteralPath $script:DecisionBridgeConfig.LogFile -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
