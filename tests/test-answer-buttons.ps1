#Requires -Version 7.0
<#
.SYNOPSIS
    A question can be answered from the notification itself.

.DESCRIPTION
    The dangerous failures here are the quiet ones: a button that appears to work and
    answers nothing, or one that answers the wrong question.

    A notification outlives the question it was sent for. iOS keeps it until it is
    withdrawn or swiped away, so a button tapped from a stale notification arrives
    long after that question was answered - possibly while a different one is waiting
    on the same session. Several checks below are about refusing those taps rather
    than delivering them.

    The identity that makes refusing possible travels in `action_data`, which iOS
    echoes back with the event. The payload in these checks is the real one captured
    from a physical iPhone on 2026-10-10, not an invented shape, because the whole
    mechanism depends on what the phone actually returns.

    Nothing here reaches Home Assistant or a terminal. The service call and the
    injection are stubbed, and the checks assert what each was asked to do.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repository = Split-Path -Parent $PSScriptRoot

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $__ok = $false
    try { $__ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($__ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

# Defined before the implementation is loaded: a stub written below the code it is
# meant to intercept is still out of scope at the call.
$script:Sent = [System.Collections.Generic.List[object]]::new()
function Invoke-HomeAssistantService {
    param($Domain, $Service, $Headers, $Data, $TimeoutSec)
    $script:Sent.Add([pscustomobject]@{ Service = $Service; Data = $Data })
}
function Write-DaemonLog { param([string]$Message) }
function Test-BridgeObservationGuardFailure { param($ErrorRecord) $false }
function Get-CopilotMqttNodeId { param([string]$SessionId) ($SessionId -replace '[^a-zA-Z0-9]', '').Substring(0, 16) }

$script:Markers = @{}
function Get-CopilotDecisionMarker {
    param([Parameter(Mandatory)][string]$SessionId, [switch]$RequireReadable)
    if ($script:Markers.ContainsKey($SessionId)) { return $script:Markers[$SessionId] }
    $null
}

$script:AskPending = $true
function Get-DaemonAskUserState {
    param($Session, $Marker)
    [pscustomobject]@{ Started = $true; Pending = $script:AskPending }
}

$script:Injected = [System.Collections.Generic.List[object]]::new()
$script:InjectResult = $true
function Invoke-DaemonDecisionAnswer {
    param($SessionId, $Marker, $Answer, $IsChoice, $IsFreeText, $Selections, $PayloadStamp, $State, $Headers)
    $script:Injected.Add([pscustomobject]@{
        SessionId = $SessionId; Answer = $Answer; IsChoice = $IsChoice
        IsFreeText = $IsFreeText; Selections = @($Selections)
    })
    $script:InjectResult
}

$script:DecisionBridgeConfig = @{
    AnswerButtonsEnabled     = $true
    AnswerButtonServices     = @('notify.mobile_app_test')
    AnswerButtonMax          = 6
    AnswerButtonIcon         = 'mdi:chat-question'
    AnswerButtonIconColor    = '#FFFFFF'
    AnswerButtonColor        = '#FF9F0A'
    AnswerButtonInterruption = 'time-sensitive'
    DashboardUrlPath         = 'agent-decisions'
}
$script:DaemonMachineName = 'TESTBOX'

. (Join-Path $repository 'hooks\daemon-decision-notify.ps1')

# Loaded on its own, by name, rather than dot-sourcing the whole websocket file:
# this suite is about what a tapped button means, not about connecting to anything.
$wsAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repository 'hooks\decision-ha-websocket.ps1'), [ref]$null, [ref]$null)
$hitFunction = $wsAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-BridgeStateTriggerHit'
}, $true)
if (-not $hitFunction) { throw 'The actual trigger-hit parser is missing.' }
. ([scriptblock]::Create($hitFunction.Extent.Text))

$headers = @{ Authorization = '******' }
$session = 'a92623ed40334467b5d0342e27557c09'

function New-TestMarker {
    param(
        [string]$DecisionId = 'd1',
        [string]$Question = 'Open the pull request now, or hold for a review first?',
        [string[]]$Choices = @('Open the PR now', 'Hold for review'),
        [object[]]$Fields = @(),
        [string]$Mode = 'multiple_choice',
        [bool]$TerminalOnly = $false
    )
    [pscustomobject]@{
        decisionId = $DecisionId; question = $Question; choices = @($Choices)
        combos = @(); fields = @($Fields); mode = $Mode; terminalOnly = $TerminalOnly
    }
}

function Reset-TestWorld {
    $script:Sent.Clear()
    $script:Injected.Clear()
    $script:Markers = @{}
    $script:AskPending = $true
    $script:InjectResult = $true
    $script:DaemonAnswerButtonSent.Clear()
}

Write-Host '--- the options become the buttons ---'

Test-That 'each choice is offered as its own button' {
    $options = Get-BridgeAnswerButtonOptions -Marker (New-TestMarker)
    $options.Count -eq 2 -and $options[0] -eq 'Open the PR now'
}

Test-That 'a single structured field offers its options instead' {
    $field = [pscustomobject]@{ Label = 'Branch'; Options = @('main', 'develop'); IsText = $false }
    $m = New-TestMarker -Choices @() -Fields @($field)
    $options = @(Get-BridgeAnswerButtonOptions -Marker $m)
    $options.Count -eq 2 -and $options[1] -eq 'develop'
}

Test-That 'a form with several fields offers no choice buttons at all' {
    # One tap cannot fill in more than one slot, and a partial answer would leave the
    # prompt waiting halfway through its form.
    $a = [pscustomobject]@{ Label = 'A'; Options = @('x'); IsText = $false }
    $b = [pscustomobject]@{ Label = 'B'; Options = @('y'); IsText = $false }
    @(Get-BridgeAnswerButtonOptions -Marker (New-TestMarker -Choices @() -Fields @($a, $b))).Count -eq 0
}

Test-That 'a question that must be answered in the terminal offers nothing' {
    # The daemon refuses to inject one of these, so a button would be a lie.
    $m = New-TestMarker -TerminalOnly $true
    $actions = @(Get-BridgeAnswerButtonActions -Marker $m -DecisionId 'd1' -Options @(Get-BridgeAnswerButtonOptions -Marker $m))
    $actions.Count -eq 0
}

Test-That 'a freeform question offers only the text action' {
    $m = New-TestMarker -Choices @() -Mode 'freeform'
    $actions = @(Get-BridgeAnswerButtonActions -Marker $m -DecisionId 'd1' -Options @(Get-BridgeAnswerButtonOptions -Marker $m))
    $actions.Count -eq 1 -and $actions[0].behavior -eq 'textInput'
}

Test-That 'words are offered as an answer to a choice question too' {
    # Every Copilot option list ends in "Other (type your answer)".
    $m = New-TestMarker
    $actions = @(Get-BridgeAnswerButtonActions -Marker $m -DecisionId 'd1' -Options @(Get-BridgeAnswerButtonOptions -Marker $m))
    $actions.Count -eq 3 -and $actions[2].behavior -eq 'textInput'
}

Test-That 'more options than will fit are capped rather than shown badly' {
    $many = @(1..20 | ForEach-Object { "Option $_" })
    $m = New-TestMarker -Choices $many
    $actions = @(Get-BridgeAnswerButtonActions -Marker $m -DecisionId 'd1' -Options $many -MaxButtons 4)
    # Four choices plus the text action.
    $actions.Count -eq 5
}

Test-That 'a label written for a terminal is shortened for a button' {
    (Get-BridgeAnswerButtonTitle -Text '(Recommended) Open the pull request and wait for CI').Length -le 33
}

Test-That 'each question gets action identifiers of its own' {
    # Actions are shared across every notification on the device, so a fixed
    # identifier would let an old notification answer a new question.
    $one = @(Get-BridgeAnswerButtonActions -Marker (New-TestMarker -DecisionId 'aaa') -DecisionId 'aaa' -Options @('x'))
    $two = @(Get-BridgeAnswerButtonActions -Marker (New-TestMarker -DecisionId 'bbb') -DecisionId 'bbb' -Options @('x'))
    $one[0].action -ne $two[0].action
}

Write-Host ''
Write-Host '--- the notification carries the identity that comes back ---'

Test-That 'the session and decision ride along in action_data' {
    # An entity id could not be used: a node id is sanitised and truncated, and there
    # is no way back from one to a session id.
    Reset-TestWorld
    $m = New-TestMarker
    $p = Get-BridgeAnswerButtonPayload -SessionId $session -SessionName 'bridge' -Marker $m `
        -Actions @(Get-BridgeAnswerButtonActions -Marker $m -DecisionId 'd1' -Options @('a'))
    $p.data.action_data.session -eq $session -and $p.data.action_data.decision -eq 'd1'
}

Test-That 'the question is the body and the session is the title' {
    $m = New-TestMarker
    $p = Get-BridgeAnswerButtonPayload -SessionId $session -SessionName 'bridge' -Marker $m
    $p.title -eq 'bridge' -and $p.message -eq $m.question
}

Test-That 'tapping the notification itself opens the decision view' {
    $p = Get-BridgeAnswerButtonPayload -SessionId $session -SessionName 'bridge' -Marker (New-TestMarker)
    $p.data.url -eq '/agent-decisions/decision'
}

Write-Host ''
Write-Host '--- and it is styled as the session speaking, not as a stock alert ---'

Test-That 'an icon and a background colour make it a communication notification' {
    # Without these iOS shows the Home Assistant app icon and nothing distinguishes a
    # question from any other alert the house sends.
    $p = Get-BridgeAnswerButtonPayload -SessionId $session -SessionName 'bridge' -Marker (New-TestMarker) `
        -Icon 'mdi:chat-question' -IconColor '#FFFFFF' -Color '#FF9F0A'
    $p.data.notification_icon -eq 'mdi:chat-question' -and
        $p.data.notification_icon_color -eq '#FFFFFF' -and $p.data.color -eq '#FF9F0A'
}

Test-That 'the session name is the sender, so the question reads as coming from it' {
    $p = Get-BridgeAnswerButtonPayload -SessionId $session -SessionName 'agent-ha-bridge' -Marker (New-TestMarker)
    $p.title -eq 'agent-ha-bridge'
}

Test-That 'the machine is named in the subtitle rather than crowding the title' {
    $p = Get-BridgeAnswerButtonPayload -SessionId $session -SessionName 'bridge' -Marker (New-TestMarker) -MachineName 'DSWETT-HOME'
    $p.data.subtitle -match 'DSWETT-HOME'
}

Test-That 'a blocked session is time-sensitive, so Focus does not hide it' {
    $p = Get-BridgeAnswerButtonPayload -SessionId $session -SessionName 'bridge' -Marker (New-TestMarker) `
        -InterruptionLevel 'time-sensitive'
    $p.data.'interruption-level' -eq 'time-sensitive'
}

Test-That 'the level can be turned down without touching the code' {
    $p = Get-BridgeAnswerButtonPayload -SessionId $session -SessionName 'bridge' -Marker (New-TestMarker) `
        -InterruptionLevel 'passive'
    $p.data.'interruption-level' -eq 'passive'
}

Test-That 'several questions stack under one heading' {
    $p = Get-BridgeAnswerButtonPayload -SessionId $session -SessionName 'bridge' -Marker (New-TestMarker)
    $p.data.group -eq 'agent-bridge'
}

Test-That 'clearing the icon leaves a plain notification rather than a broken one' {
    # An empty icon must not send an empty notification_icon, which iOS would render
    # as a communication notification with no avatar at all.
    $p = Get-BridgeAnswerButtonPayload -SessionId $session -SessionName 'bridge' -Marker (New-TestMarker) -Icon ''
    -not $p.data.ContainsKey('notification_icon')
}

Write-Host ''
Write-Host '--- a real tap from a real phone is understood ---'

# Captured from a physical iPhone on 2026-10-10 against this exact payload builder.
$realTap = '{"action":"BRIDGE_robe433e5b50_0","action_data":{"bridge":"decision","decision":"probe-433e5b50","session":"a92623ed40334467b5d0342e27557c09"}}' | ConvertFrom-Json

Test-That 'the captured event names its session, question and option' {
    $c = Get-BridgeAnswerButtonChoice -EventData $realTap
    $null -ne $c -and $c.SessionId -eq $session -and $c.DecisionId -eq 'probe-433e5b50' -and $c.Index -eq 0
}

Test-That "another integration's notification action is not mistaken for ours" {
    $other = '{"action":"ALARM","action_data":{"entity_id":"light.test"}}' | ConvertFrom-Json
    $null -eq (Get-BridgeAnswerButtonChoice -EventData $other)
}

Test-That 'an action with no data at all is ignored rather than guessed at' {
    $bare = '{"action":"SILENCE"}' | ConvertFrom-Json
    $null -eq (Get-BridgeAnswerButtonChoice -EventData $bare)
}

Test-That 'typed text is carried back with the event' {
    $typed = '{"action":"BRIDGE_abc_text","reply_text":"use develop","action_data":{"bridge":"decision","decision":"d1","session":"s1"}}' | ConvertFrom-Json
    (Get-BridgeAnswerButtonChoice -EventData $typed).ReplyText -eq 'use develop'
}

# Also captured from the same physical iPhone, using the notification's text action.
# Kept beside the button payload because the two differ in exactly the way that
# matters: this one ends in _text, so the option index must decline to match it.
$realTyped = ('{"action":"style-448cdd14_text","action_data":{"bridge":"decision",' +
    '"decision":"style-448cdd14","session":"probe"},"reply_text":"Yes"}') | ConvertFrom-Json

Test-That 'a typed reply from the phone is read as words, not as an option number' {
    $c = Get-BridgeAnswerButtonChoice -EventData $realTyped
    $c.ReplyText -eq 'Yes' -and $c.Index -eq -1
}

Write-Host ''
Write-Host '--- and it answers the waiting question ---'

Test-That 'the chosen option is delivered into the prompt' {
    Reset-TestWorld
    $script:Markers[$session] = New-TestMarker -DecisionId 'probe-433e5b50'
    $live = @{ $session = [pscustomobject]@{ Id = $session } }
    [void](Invoke-DaemonAnswerButton -EventData $realTap -State @{} -Live $live -Headers $headers)
    $script:Injected.Count -eq 1 -and $script:Injected[0].Answer -eq 'Open the PR now'
}

Test-That 'it is delivered as a choice, not as typed words' {
    $script:Injected[0].IsChoice -eq $true -and $script:Injected[0].IsFreeText -eq $false
}

Test-That 'answering withdraws the notification' {
    # Left up, it would keep offering buttons that are now refused, which reads as
    # the answer having been lost.
    @($script:Sent | Where-Object { $_.Data.message -eq 'clear_notification' }).Count -ge 1
}

Test-That 'typed words are delivered as free text instead' {
    Reset-TestWorld
    $script:Markers[$session] = New-TestMarker -DecisionId 'd1'
    $live = @{ $session = [pscustomobject]@{ Id = $session } }
    $typed = ('{"action":"BRIDGE_abc_text","reply_text":"neither, rebase first","action_data":' +
        '{"bridge":"decision","decision":"d1","session":"' + $session + '"}}') | ConvertFrom-Json
    [void](Invoke-DaemonAnswerButton -EventData $typed -State @{} -Live $live -Headers $headers)
    $script:Injected.Count -eq 1 -and $script:Injected[0].IsFreeText -eq $true -and
        $script:Injected[0].Answer -eq 'neither, rebase first'
}

Write-Host ''
Write-Host '--- a tap that should not answer anything does not ---'

Test-That 'a button tapped from a stale notification answers nothing' {
    # The notification for an earlier question is still on the phone; the session is
    # now being asked something else entirely.
    Reset-TestWorld
    $script:Markers[$session] = New-TestMarker -DecisionId 'a-different-question'
    $live = @{ $session = [pscustomobject]@{ Id = $session } }
    [void](Invoke-DaemonAnswerButton -EventData $realTap -State @{} -Live $live -Headers $headers)
    $script:Injected.Count -eq 0
}

Test-That 'a tap for a question already answered answers nothing' {
    Reset-TestWorld
    $script:Markers[$session] = New-TestMarker -DecisionId 'probe-433e5b50'
    $script:AskPending = $false
    $live = @{ $session = [pscustomobject]@{ Id = $session } }
    [void](Invoke-DaemonAnswerButton -EventData $realTap -State @{} -Live $live -Headers $headers)
    $script:Injected.Count -eq 0
}

Test-That 'a tap for a session that has exited answers nothing' {
    Reset-TestWorld
    $script:Markers[$session] = New-TestMarker -DecisionId 'probe-433e5b50'
    [void](Invoke-DaemonAnswerButton -EventData $realTap -State @{} -Live @{} -Headers $headers)
    $script:Injected.Count -eq 0
}

Test-That 'a tap naming an option the question does not have answers nothing' {
    Reset-TestWorld
    $script:Markers[$session] = New-TestMarker -DecisionId 'd1' -Choices @('only one')
    $live = @{ $session = [pscustomobject]@{ Id = $session } }
    $oob = ('{"action":"BRIDGE_abc_7","action_data":{"bridge":"decision","decision":"d1","session":"' +
        $session + '"}}') | ConvertFrom-Json
    [void](Invoke-DaemonAnswerButton -EventData $oob -State @{} -Live $live -Headers $headers)
    $script:Injected.Count -eq 0
}

Write-Host ''
Write-Host '--- a question is offered once, and only when asked for ---'

Test-That 'a pending question is sent to the phone' {
    Reset-TestWorld
    $m = New-TestMarker -DecisionId 'd-new'
    $state = @{ $session = [pscustomobject]@{ Name = 'bridge'; Status = 'idle' } }
    Sync-DaemonAnswerButtons -SessionId $session -Marker $m -State $state -Headers $headers
    $script:Sent.Count -eq 1 -and $script:Sent[0].Data.title -eq 'bridge'
}

Test-That 'and is not sent again on every pass' {
    # A question re-notified every fifteen seconds is worse than one not notified.
    $m = New-TestMarker -DecisionId 'd-new'
    $state = @{ $session = [pscustomobject]@{ Name = 'bridge'; Status = 'idle' } }
    Sync-DaemonAnswerButtons -SessionId $session -Marker $m -State $state -Headers $headers
    Sync-DaemonAnswerButtons -SessionId $session -Marker $m -State $state -Headers $headers
    $script:Sent.Count -eq 1
}

Test-That 'nothing is sent when the feature is switched off' {
    Reset-TestWorld
    $script:DecisionBridgeConfig.AnswerButtonsEnabled = $false
    $state = @{ $session = [pscustomobject]@{ Name = 'bridge'; Status = 'idle' } }
    Sync-DaemonAnswerButtons -SessionId $session -Marker (New-TestMarker -DecisionId 'd-off') -State $state -Headers $headers
    $script:DecisionBridgeConfig.AnswerButtonsEnabled = $true
    $script:Sent.Count -eq 0
}

Test-That 'nothing is sent when no phone has been named' {
    Reset-TestWorld
    $script:DecisionBridgeConfig.AnswerButtonServices = @()
    $state = @{ $session = [pscustomobject]@{ Name = 'bridge'; Status = 'idle' } }
    Sync-DaemonAnswerButtons -SessionId $session -Marker (New-TestMarker -DecisionId 'd-none') -State $state -Headers $headers
    $script:DecisionBridgeConfig.AnswerButtonServices = @('notify.mobile_app_test')
    $script:Sent.Count -eq 0
}

Write-Host ''
Write-Host '--- the socket tells an event apart from a state change ---'

Test-That 'an event trigger is reported as an event, with its data' {
    $message = ('{"type":"event","event":{"variables":{"trigger":{"platform":"event","event":' +
        '{"event_type":"mobile_app_notification_action","data":{"action":"BRIDGE_x_0"}}}}}}') | ConvertFrom-Json
    $hit = Get-BridgeStateTriggerHit -Message $message
    $null -ne $hit -and $hit.Kind -ceq 'Event' -and $hit.EventType -ceq 'mobile_app_notification_action'
}

Test-That 'and carries no entity id, so the press dispatch cannot match it' {
    $message = ('{"type":"event","event":{"variables":{"trigger":{"platform":"event","event":' +
        '{"event_type":"mobile_app_notification_action","data":{"action":"BRIDGE_x_0"}}}}}}') | ConvertFrom-Json
    $hit = Get-BridgeStateTriggerHit -Message $message
    [string]$hit.EntityId -eq '' -and -not ([string]$hit.EntityId -match '_(reply|submit|stop)$')
}

Test-That 'an ordinary state change is still reported as one' {
    $message = ('{"type":"event","event":{"variables":{"trigger":{"entity_id":"button.abc_stop",' +
        '"to_state":{"state":"2026-10-10T12:00:00+00:00"}}}}}') | ConvertFrom-Json
    $hit = Get-BridgeStateTriggerHit -Message $message
    $null -ne $hit -and $hit.Kind -ceq 'State' -and $hit.EntityId -eq 'button.abc_stop'
}

Test-That 'an entity being removed is still skipped rather than thrown' {
    # The 2026-10-07 trap: reading .state off a null to_state was thrown out of the
    # whole wait and counted as a dropped socket.
    $message = '{"type":"event","event":{"variables":{"trigger":{"entity_id":"button.abc_stop","to_state":null}}}}' | ConvertFrom-Json
    $null -eq (Get-BridgeStateTriggerHit -Message $message)
}

Write-Host ''
Write-Host '--- several questions at once stay separate ---'

Test-That 'each session gets a notification of its own, not one replacing the other' {
    # The tag is what iOS identifies a notification by, so a shared one would mean the
    # second session silently replaced the first session's question on the phone.
    Reset-TestWorld
    $other = 'bbbbbbbb11112222333344445555cccc'
    $state = @{
        $session = [pscustomobject]@{ Name = 'bridge'; Status = 'idle' }
        $other   = [pscustomobject]@{ Name = 'other-session'; Status = 'idle' }
    }
    Sync-DaemonAnswerButtons -SessionId $session -Marker (New-TestMarker -DecisionId 'd-a') -State $state -Headers $headers
    Sync-DaemonAnswerButtons -SessionId $other -Marker (New-TestMarker -DecisionId 'd-b') -State $state -Headers $headers
    $tags = @($script:Sent | ForEach-Object { $_.Data.data.tag })
    $script:Sent.Count -eq 2 -and $tags[0] -ne $tags[1]
}

Test-That 'and each is titled with the session that is asking' {
    $titles = @($script:Sent | ForEach-Object { $_.Data.title })
    $titles -contains 'bridge' -and $titles -contains 'other-session'
}

Test-That 'the same session asking again replaces its own notification' {
    # A second question on one session must not stack up behind the first.
    Reset-TestWorld
    $state = @{ $session = [pscustomobject]@{ Name = 'bridge'; Status = 'idle' } }
    Sync-DaemonAnswerButtons -SessionId $session -Marker (New-TestMarker -DecisionId 'd-first') -State $state -Headers $headers
    Sync-DaemonAnswerButtons -SessionId $session -Marker (New-TestMarker -DecisionId 'd-second') -State $state -Headers $headers
    $tags = @($script:Sent | ForEach-Object { $_.Data.data.tag })
    $script:Sent.Count -eq 2 -and $tags[0] -eq $tags[1]
}

Test-That 'a tap answers the session it came from, not whichever asked most recently' {
    Reset-TestWorld
    $other = 'bbbbbbbb11112222333344445555cccc'
    $script:Markers[$session] = New-TestMarker -DecisionId 'probe-433e5b50' -Choices @('Open the PR now', 'Hold for review')
    $script:Markers[$other] = New-TestMarker -DecisionId 'd-b' -Choices @('Something else entirely')
    $live = @{
        $session = [pscustomobject]@{ Id = $session }
        $other   = [pscustomobject]@{ Id = $other }
    }
    [void](Invoke-DaemonAnswerButton -EventData $realTap -State @{} -Live $live -Headers $headers)
    $script:Injected.Count -eq 1 -and $script:Injected[0].SessionId -eq $session -and
        $script:Injected[0].Answer -eq 'Open the PR now'
}

Test-That 'answering one question leaves the other still waiting on the phone' {
    # Only the answered session's tag is withdrawn.
    $cleared = @($script:Sent | Where-Object { $_.Data.message -eq 'clear_notification' } |
        ForEach-Object { $_.Data.data.tag })
    $mine = "bridge_decision_$(Get-CopilotMqttNodeId -SessionId $session)"
    $theirs = "bridge_decision_$(Get-CopilotMqttNodeId -SessionId 'bbbbbbbb11112222333344445555cccc')"
    ($cleared -contains $mine) -and -not ($cleared -contains $theirs)
}

Test-That 'answering on one phone withdraws the question from every phone' {
    # Otherwise the question goes on being offered on the iPad after it was answered
    # on the phone, and tapping it there is refused for no visible reason.
    Reset-TestWorld
    $script:DecisionBridgeConfig.AnswerButtonServices = @('notify.mobile_app_a', 'notify.mobile_app_b')
    $script:Markers[$session] = New-TestMarker -DecisionId 'probe-433e5b50'
    $live = @{ $session = [pscustomobject]@{ Id = $session } }
    [void](Invoke-DaemonAnswerButton -EventData $realTap -State @{} -Live $live -Headers $headers)
    $script:DecisionBridgeConfig.AnswerButtonServices = @('notify.mobile_app_test')
    @($script:Sent | Where-Object { $_.Data.message -eq 'clear_notification' }).Count -eq 2
}

if ($script:Failures) { Write-Host "`n$script:Failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "`nAll answer button checks passed" -ForegroundColor Green
