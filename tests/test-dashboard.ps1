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
Test-That 'and holds the session sections' { @($sessionCard.cards | Where-Object { $_.type -eq 'custom:agent-bridge-activity-card' }).Count -eq 1 }
Save-CopilotSessionDashboard -Sessions $sessions -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.11.3'
Test-That 'an older served card keeps the styled stack' { (Get-SavedJson) -notmatch 'agent-bridge-session-card' }

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
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
