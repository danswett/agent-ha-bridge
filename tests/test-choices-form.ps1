#Requires -Version 7.0
<#
.SYNOPSIS
    Follows a multi-field answer the whole way: dashboard -> card -> entities -> daemon.

.DESCRIPTION
    Every bug in the last five releases sat in the wiring between two tested ends. The
    card's own suite sets its entities by hand and passed all eight glow checks on a
    config the dashboard never produced; the driver had a test for mapping a user id
    and one for recording the press, and none for the value reaching the card.

    So nothing here is written out by hand in the middle. It:

      1. arms a real two-field question through Set-CopilotMqttDecision, capturing the
         entity ids, options and labels the bridge actually publishes;
      2. builds the real dashboard with Save-CopilotSessionDashboard and takes the
         choices card's config out of it;
      3. runs the real card (frontend/test/drive-choices-card.js) on that config and
         those states, tapping the rows for the answers a person would pick;
      4. applies the select_option calls the card made to the entity states, and asks
         the real Read-DaemonFormAnswer what the form now says.

    A rename anywhere along that chain - a slot the view does not hand over, an id the
    card sets that the daemon does not read - fails here even though both ends pass.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-mqtt.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-ha-websocket.ps1')
. (Join-Path $PSScriptRoot '..\hooks\daemon-decisions.ps1')
# The injector too, so the last link - the keystrokes a read answer turns into - is
# checked against the same field definitions the card and the daemon just used.
. (Join-Path $PSScriptRoot '..\hooks\decision-inject.ps1')
# Its guard, so dot-sourcing it gives the functions without running the card check -
# which talks to Home Assistant and re-sources the files above, undoing every stub.
$env:BRIDGE_FRONTEND_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\bridge-frontend-cards.ps1')
$script:DecisionBridgeConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-choices-form-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

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

function Write-DaemonLog { param([string]$Message) }
function Set-DaemonTransientActivity { param($SessionId, $Summary, $Extra, $Headers) }

# Every door out to Home Assistant is closed before anything runs, not beside the
# call that needs it. An early draft stubbed this one halfway down and dot-sourced
# bridge-frontend-cards.ps1 without its NORUN guard, so a test suite opened real
# WebSocket connections to the live instance - which is how a machine gets itself
# IP-banned by its own tests.
$script:SavedConfig = $null
. (Join-Path $PSScriptRoot 'test-dashboard.ps1') -PublicationFixturesOnly
function Invoke-CopilotHaWebSocket {
    param([Parameter(Mandatory)][object[]]$Commands)
    Invoke-TestPublicationCommands -Commands $Commands
}
function Invoke-HomeAssistantApi { param($Path, $Method, $Body, $Headers) throw 'no network in this suite' }
Initialize-TestPublicationStore
Initialize-TestPublicationAuthority

# --- 1. what the bridge publishes for a real two-field question -------------------

$sessionId = 'abc123de-f456-7890-abcd-ef1234567890'
$node = Get-CopilotMqttNodeId -SessionId $sessionId
$headers = @{ Authorization = '******' }

# Entity states as Home Assistant would hold them, filled in from the discovery
# payloads and the starting values the bridge publishes. Nothing is invented here.
$script:HaStates = @{}
# Home Assistant's own answer for an entity it does not have, as a status rather than
# as wording: the bridge reads absence off the status code, never off a message, so a
# stand-in that only says "404" in words would not be saying it at all.
function New-TestHaNotFound {
    param([Parameter(Mandatory)][string]$EntityId)
    $notFound = [InvalidOperationException]::new("Response status code does not indicate success: 404 (Not Found). [$EntityId]")
    $notFound.Data['BridgeHttpStatus'] = 404
    $notFound
}
function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    # Shaped like Home Assistant's own refusal: it answers 404 for an entity it does
    # not have, and the bridge tells that apart from being unable to read at all.
    if (-not $script:HaStates.Contains($EntityId)) { throw (New-TestHaNotFound -EntityId $EntityId) }
    $entry = $script:HaStates[$EntityId]
    # An object, not the dictionary it is stored in: Home Assistant's own JSON parses
    # to one, and the daemon reads attributes the way it reads every other entity's.
    [pscustomobject]@{ entity_id = $EntityId; state = [string]$entry.state; attributes = [pscustomobject]$entry.attributes }
}
function Publish-CopilotMqttMessage {
    param([string]$Topic, [string]$Payload, [hashtable]$Headers, [switch]$Retain)
    if ($Topic -match '/select/[^/]+/(decision|f\d)/config$') {
        $slot = $Matches[1]
        $config = $Payload | ConvertFrom-Json
        $entityId = if ($slot -eq 'decision') { "select.${node}_decision" } else { "select.${node}_$slot" }
        $script:HaStates[$entityId] = [ordered]@{
            state = 'unknown'
            attributes = [ordered]@{
                options = @($config.options)
                # Home Assistant builds an MQTT entity's friendly_name from the device
                # name and the entity name, which is why the card cannot use it as a
                # field heading and reads the decision attributes instead.
                friendly_name = "$($config.device.name) $($config.name)"
            }
        }
        return
    }
    if ($Topic -match '/decision/attr$') {
        $attrs = $Payload | ConvertFrom-Json
        $target = $script:HaStates["select.${node}_decision"]
        if ($null -ne $target) {
            foreach ($p in $attrs.PSObject.Properties) { $target.attributes[$p.Name] = $p.Value }
        }
    }
}
function Invoke-HomeAssistantService {
    param([string]$Domain, [string]$Service, [hashtable]$Headers, [hashtable]$Data)
    $entityId = [string]$Data.entity_id
    if ($script:HaStates.Contains($entityId)) { $script:HaStates[$entityId].state = [string]$Data.option }
}
function Set-CopilotMqttEntityIds { param([string]$SessionId) }
function Start-Sleep { param([int]$Milliseconds, [int]$Seconds) }

$fields = @(
    [pscustomobject]@{ Label = 'Approach'; Options = @('Rewrite it', 'Patch it in place (Recommended)'); IsText = $false }
    [pscustomobject]@{ Label = 'When';     Options = @('Now', 'After the release');                     IsText = $false }
    [pscustomobject]@{ Label = 'Notes';    Options = @();                                               IsText = $true }
)

# The baseline is what the answer channels already held when a question was armed;
# everything after it is "has this changed". It is a write-once file per question, so
# a scenario that needs the card to have been holding something states it here rather
# than putting fields on the marker, which nothing reads any more.
function Set-Baseline {
    param(
        [Parameter(Mandatory)][string]$DecisionId,
        [ValidateSet('present', 'absent', 'unknown')][string]$PayloadState = 'absent',
        [AllowEmptyString()][string]$PayloadValue = '',
        [ValidateSet('present', 'absent', 'unknown')][string]$SubmitState = 'absent',
        [AllowEmptyString()][string]$SubmitValue = ''
    )
    $path = Get-CopilotDecisionBaselinePath -SessionId $script:sessionId -DecisionId $DecisionId
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    $ok = Set-CopilotDecisionMarkerBaseline -SessionId $script:sessionId -DecisionId $DecisionId `
        -PayloadState $PayloadState -PayloadValue $PayloadValue `
        -SubmitState $SubmitState -SubmitValue $SubmitValue
    if (-not $ok) { throw "could not seed a baseline for $DecisionId" }
}

$armedAt = [DateTimeOffset]::Now.AddSeconds(-5)
Set-CopilotMqttDecision -SessionId $sessionId -SessionName 'Copilot: a task' -Machine 'BOX' `
    -Question 'How should this land?' -Choices @() -Fields $fields `
    -DecisionId 'd1' -Headers $headers | Out-Null

Write-Host '--- what the answer channels held is read before the question is shown ---'
# The snapshot used to be taken after the question was published, so an answer sent in
# the gap was recorded as "what was already there" and never accepted, while the card
# said it had gone. Recorded here in a scope of its own, so the stubs go with it.
$script:Order = [Collections.Generic.List[string]]::new()
Test-That 'both answer channels are read before anything about the question is published' {
    $script:Order = [Collections.Generic.List[string]]::new()
    function Get-CopilotDecisionChannelObservation {
        param($EntityId, $Headers)
        $script:Order.Add("read $EntityId")
        [pscustomobject]@{ State = 'absent'; Value = '' }
    }
    function Publish-CopilotMqttMessage {
        param([string]$Topic, [string]$Payload, [hashtable]$Headers, [switch]$Retain)
        $script:Order.Add("publish $Topic")
    }
    Set-CopilotMqttDecision -SessionId '0dd0e000-0000-4000-8000-0000000000aa' -SessionName 'Copilot: order' `
        -Machine 'BOX' -Question 'Which?' -Choices @() -Fields $fields -DecisionId 'order-check' -Headers $headers | Out-Null
    $first = $script:Order.FindIndex([Predicate[string]]{ param($s) $s -like 'publish *' })
    $reads = @($script:Order | Where-Object { $_ -like 'read *' })
    $first -eq 2 -and $reads.Count -eq 2 -and
        $reads[0] -like '*_reply_payload' -and $reads[1] -like '*_submit'
} "order: $(@($script:Order | Select-Object -First 4) -join ' | ')"

# A question shown without a snapshot can never tell an answer from what was there, so it
# is not shown at all until the snapshot can be taken; the daemon retries both.
$script:Published = 0
Test-That 'a question whose answer channels cannot be read is not shown' {
    function Get-CopilotDecisionChannelObservation { param($EntityId, $Headers) [pscustomobject]@{ State = 'unknown'; Value = '' } }
    function Publish-CopilotMqttMessage { param([string]$Topic, [string]$Payload, [hashtable]$Headers, [switch]$Retain) $script:Published++ }
    $shown = Set-CopilotMqttDecision -SessionId '0dd0e000-1111-4000-8000-0000000000bb' -SessionName 'Copilot: unread' `
        -Machine 'BOX' -Question 'Which?' -Choices @() -Fields $fields -DecisionId 'unreadable' -Headers $headers
    $null -eq $shown -and $script:Published -eq 0
} "published=$($script:Published)"
$script:Published = 0
$script:TapAttrs = @()
Test-That 'but one nothing would re-arm can still be shown when asked to' {
    function Get-CopilotDecisionChannelObservation { param($EntityId, $Headers) [pscustomobject]@{ State = 'unknown'; Value = '' } }
    function Publish-CopilotMqttMessage { param([string]$Topic, [string]$Payload, [hashtable]$Headers, [switch]$Retain)
        $script:Published++
        if ($Topic -match '/decision/attr$') { $script:TapAttrs += ($Payload | ConvertFrom-Json) }
    }
    $shown = Set-CopilotMqttDecision -SessionId '0dd0e000-2222-4000-8000-0000000000cc' -SessionName 'Codex: approve' `
        -Machine 'BOX' -Question 'Run it?' -Choices @('Approve', 'Deny') -Fields @() -DecisionId 'approval' -Headers $headers `
        -PublishWithoutBaseline -AnswerOnTap
    $null -ne $shown -and $script:Published -gt 0
} "published=$($script:Published)"
# The card draws Send from this attribute alone. Without it an approval showed a Send
# the daemon never reads - it acts on Approve or Deny the moment it sees either - so
# the tap somebody made meaning to review it first had already approved the command.
Test-That 'and it says the tap is the answer, so no Send is drawn beside it' {
    $a = @($script:TapAttrs)
    $a.Count -eq 1 -and $null -ne $a[0].PSObject.Properties['answer_on_tap'] -and [bool]$a[0].answer_on_tap
} "attrs=[$(@($script:TapAttrs) | ForEach-Object { $_.PSObject.Properties.Name -join ',' })]"

Write-Host '--- the question the bridge armed ---'
Test-That 'the decision selector carries only Cancel, so the fields are the answer' {
    (@($script:HaStates["select.${node}_decision"].attributes.options) -join ',') -eq 'Awaiting answer...,Cancel request'
} "[$(@($script:HaStates["select.${node}_decision"].attributes.options) -join ',')]"
Test-That 'each choice field carries its own options' {
    @($script:HaStates["select.${node}_f1"].attributes.options) -contains 'Patch it in place (Recommended)' -and
    @($script:HaStates["select.${node}_f2"].attributes.options) -contains 'After the release'
}
Test-That 'and the headings ride on the decision attributes' {
    $a = $script:HaStates["select.${node}_decision"].attributes
    $a['field_1_label'] -eq 'Approach' -and $a['field_2_label'] -eq 'When'
}
Test-That 'an ordinary question says nothing about taps, so it keeps its Send' {
    -not $script:HaStates["select.${node}_decision"].attributes.Contains('answer_on_tap')
} "[$(@($script:HaStates["select.${node}_decision"].attributes.Keys) -join ',')]"

# --- 2. the card config the dashboard really generates ----------------------------

# The dashboard gates the form shape on the card version Home Assistant is actually
# serving, which the installer reads out of the file's own CARD_VERSION - so that is
# what this asks for too, rather than a number written down again here.
$cardVersion = Get-BridgeReplyCardFileVersion -SourcePath (Join-Path $PSScriptRoot '..\frontend\agent-bridge-reply-card.js')

Set-TestPublicationCardUrl -Url "/local/agent-bridge-reply-card.js?v=$cardVersion"
Save-CopilotSessionDashboard `
    -Sessions @([pscustomobject]@{ Node = $node; Name = 'Copilot: a task'; Machine = 'BOX'; Kind = 'copilot' }) `
    -ReplyCardUrl "/local/agent-bridge-reply-card.js?v=$cardVersion"

$dashboard = $script:SavedConfig | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
$sessionCard = @($dashboard.views[0].cards | Where-Object { $_.type -eq 'custom:agent-bridge-session-card' })[0]
$cardConfig = @($sessionCard.cards | Where-Object {
    $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'custom:agent-bridge-choices-card'
})[0].card

Write-Host ''
Write-Host '--- the dashboard hands the card the form ---'
Test-That 'the generated view carries a choices card' { $null -ne $cardConfig }
Test-That 'with the field entities on it, not only the decision' {
    $cardConfig.PSObject.Properties['fields'] -and @($cardConfig.fields).Count -eq $script:CopilotMqttMaxFields
} "fields=[$(if ($null -ne $cardConfig -and $cardConfig.PSObject.Properties['fields']) { @($cardConfig.fields) -join ',' } else { '<missing>' })]"
Test-That 'and every one of them is an entity the bridge actually published' {
    @(@($cardConfig.fields) | Where-Object { -not $script:HaStates.Contains([string]$_) }).Count -eq 0
} "published=[$(($script:HaStates.Keys | Sort-Object) -join ',')]"
Test-That 'and the submit button, because Send answer is the card''s row now' {
    $cardConfig.PSObject.Properties['submit'] -and [string]$cardConfig.submit -eq "button.${node}_submit"
} "submit=[$(if ($null -ne $cardConfig -and $cardConfig.PSObject.Properties['submit']) { $cardConfig.submit } else { '<missing>' })]"
# Send answer presses the submit entity and publishes nothing of its own, so without
# the reply box's topic it submitted a mixed form with the free-text field empty -
# and an empty free-text field is a valid answer, so the typed words were simply
# dropped (#93). The topic is the only name the two cards share.
Test-That 'and the reply box''s topic, which is how Send answer reaches what was typed' {
    $cardConfig.PSObject.Properties['reply_topic'] -and
        [string]$cardConfig.reply_topic -eq (Get-CopilotMqttReplyPayloadTopic -Node $node)
} "reply_topic=[$(if ($null -ne $cardConfig -and $cardConfig.PSObject.Properties['reply_topic']) { $cardConfig.reply_topic } else { '<missing>' })]"

# The reply box stops being swapped out the moment a question arrives. That swap
# existed because the daemon could not read the card's payload while a question was
# armed; now it can, so what is on screen is the same box as the rest of the session.
$replyCards = @($sessionCard.cards | Where-Object { "$($_.type)" -eq 'custom:agent-bridge-reply-card' })
Test-That 'the reply box is the reply card, armed question or not' {
    $replyCards.Count -eq 1
} "types=[$(@($sessionCard.cards | ForEach-Object { if ($_.type -eq 'conditional') { "conditional($($_.card.type))" } else { $_.type } }) -join '|')]"
Test-That 'and the old entity row with a button beside it is gone' {
    @($sessionCard.cards | Where-Object { "$($_.type)" -eq 'custom:layout-card' }).Count -eq 0 -and
    @($sessionCard.cards | Where-Object { $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'custom:layout-card' }).Count -eq 0
}

# The other side of the same gate. An older card has neither Send answer nor the
# checkbox rows, so it must still get the pair it knows how to use - an ungated
# change here looks right on this machine and silently leaves one running an older
# card with no way to send a form at all.
Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.21.1'
Save-CopilotSessionDashboard `
    -Sessions @([pscustomobject]@{ Node = $node; Name = 'Copilot: a task'; Machine = 'BOX'; Kind = 'copilot' }) `
    -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.21.1'
$oldDash = $script:SavedConfig | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
$oldCard = @($oldDash.views[0].cards | Where-Object { $_.type -eq 'custom:agent-bridge-session-card' })[0]
$oldChoices = @($oldCard.cards | Where-Object {
    $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'custom:agent-bridge-choices-card'
})[0].card

Test-That 'an older card is not handed a submit entity it would ignore' {
    -not $oldChoices.PSObject.Properties['submit']
}
Test-That 'and keeps the entity pair for whenever a question is armed' {
    @($oldCard.cards | Where-Object { $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'custom:layout-card' }).Count -eq 1
} "types=[$(@($oldCard.cards | ForEach-Object { if ($_.type -eq 'conditional') { "conditional($($_.card.type))" } else { $_.type } }) -join '|')]"

# The reply-topic gate is its own boundary, one version further on. #98 shipped a
# 1.26.0 card with none of this machinery, and a card that does not know a config key
# drops it silently - so handing reply_topic to that one looks like it worked here
# while that machine goes on losing typed fields.
Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.26.0'
Save-CopilotSessionDashboard `
    -Sessions @([pscustomobject]@{ Node = $node; Name = 'Copilot: a task'; Machine = 'BOX'; Kind = 'copilot' }) `
    -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.26.0'
$preTopicDash = $script:SavedConfig | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
$preTopicCard = @($preTopicDash.views[0].cards | Where-Object { $_.type -eq 'custom:agent-bridge-session-card' })[0]
$preTopicChoices = @($preTopicCard.cards | Where-Object {
    $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'custom:agent-bridge-choices-card'
})[0].card

Test-That 'a card from before the reply topic is not handed one' {
    -not $preTopicChoices.PSObject.Properties['reply_topic']
} "reply_topic=[$(if ($preTopicChoices.PSObject.Properties['reply_topic']) { $preTopicChoices.reply_topic } else { '<absent>' })]"
Test-That 'but still gets the submit entity it does understand' {
    $preTopicChoices.PSObject.Properties['submit'] -and [string]$preTopicChoices.submit -eq "button.${node}_submit"
}

# --- 2b. the line beside Send, on the dashboard the bridge really generates --------

Write-Host ''
Write-Host '--- and the line beside Send says what actually happened ---'
# The footer is a conditional card: it appears only while the activity sensor is
# reporting on something just done, and the state has to be in its list by exact
# string or the row renders as nothing at all. Every refusal the daemon can emit is
# checked against the generated dashboard rather than against a copy written here,
# because a string that matches all but exactly fails silently.
function Get-SendFooter {
    param([Parameter(Mandatory)]$SessionCard)
    # Found by what makes it the send footer - a conditional markdown card keyed on
    # the activity sensor - rather than by anything it says. Looking for one of the
    # strings under test would make the search pass and fail with the fix, so a
    # regression would read as "the footer is missing" instead of as itself.
    $found = @($SessionCard.cards | Where-Object {
        $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'markdown' -and
        @($_.conditions | Where-Object {
            "$($_.entity)" -like '*_activity' -and @($_.state) -contains 'Sending...'
        }).Count -eq 1
    })
    if ($found.Count -eq 0) { return $null }
    $found[0]
}

# What the daemon actually publishes, taken from its own call sites rather than
# retyped: a notice that is not in the list is a notice nobody sees.
$daemonSource = Get-Content (Join-Path $PSScriptRoot '..\hooks\daemon-decisions.ps1') -Raw
$emitted = @([regex]::Matches($daemonSource, "-Summary\s+'([^']+)'") |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
Test-That 'the daemon really does emit the refusals this checks for' {
    @('Not sent - answer every field', 'Not sent - this question takes options',
      'Not sent - choose an option', 'Not sent - no Send button on this session') |
        ForEach-Object { $emitted -contains $_ } | Where-Object { -not $_ } | Measure-Object |
        ForEach-Object { $_.Count -eq 0 }
} "emitted=[$($emitted -join '|')]"

# The refusals and the two verification warnings must be drawn as warnings; a
# refusal with a success tick is the card saying an answer was sent at the moment it
# is refusing to send it, which is worse than saying nothing.
$warnStates = @(
    'Not sent - answer every field'
    'Not sent - this question takes options'
    'Not sent - choose an option'
    'Not sent - no Send button on this session'
    'Answer differs - check the terminal'
    'Answer unconfirmed - check the terminal'
    'Answer NOT sent'
    'Reply NOT sent'
)
$successStates = @('Answer sent', 'Reply sent')
$progressStates = @('Sending...', 'Sending answer...')

# Jinja as Home Assistant evaluates it: the glyph is picked by a chain of tests on
# the state string, so the classification is checked by running that chain rather
# than by looking for the strings in it.
function Get-FooterGlyph {
    param([Parameter(Mandatory)][string]$Content, [Parameter(Mandatory)][AllowEmptyString()][string]$State)
    # @() first: one matching line comes back as a bare string, and indexing [0] into
    # a string hands back its first character - which then parses as nothing at all.
    $body = @($Content -split "`n" | Where-Object { $_ -match '\{%\s*if' })[0]
    if ($null -eq $body) { return '<no branch>' }
    $branch = [regex]::Match($body, '\{%\s*if\s+(?<if>.*?)\s*%\}(?<a>[^{]*)\{%\s*elif\s+(?<elif>.*?)\s*%\}(?<b>[^{]*)\{%\s*else\s*%\}(?<c>[^{]*)\{%\s*endif\s*%\}')
    if (-not $branch.Success) { return '<unparsed>' }
    function Test-JinjaExpression {
        param([string]$Expression, [string]$Value)
        foreach ($term in ($Expression -split '\s+or\s+')) {
            $t = $term.Trim()
            if ($t -match "^a\s*==\s*'(?<v>.*)'$") { if ($Value -ceq $Matches['v']) { return $true }; continue }
            if ($t -match "^a\.startswith\('(?<v>.*)'\)$") { if ($Value.StartsWith($Matches['v'], [StringComparison]::Ordinal)) { return $true }; continue }
            if ($t -match "^'(?<v>.*)'\s+in\s+a$") { if ($Value.Contains($Matches['v'])) { return $true }; continue }
            throw "unhandled footer condition: $t"
        }
        $false
    }
    if (Test-JinjaExpression -Expression $branch.Groups['if'].Value -Value $State) { return $branch.Groups['a'].Value.Trim() }
    if (Test-JinjaExpression -Expression $branch.Groups['elif'].Value -Value $State) { return $branch.Groups['b'].Value.Trim() }
    $branch.Groups['c'].Value.Trim()
}

foreach ($shape in @(
    @{ Label = 'the current card'; Card = $sessionCard }
    @{ Label = 'an older card';    Card = $oldCard }
)) {
    $footer = Get-SendFooter -SessionCard $shape.Card
    Test-That "$($shape.Label) still gets the line beside Send" { $null -ne $footer }
    if ($null -eq $footer) { continue }
    $allowed = @($footer.conditions[0].state | ForEach-Object { [string]$_ })
    $content = [string]$footer.card.content

    $unlisted = @(@($warnStates + $successStates + $progressStates) | Where-Object { $allowed -notcontains $_ })
    Test-That "$($shape.Label) lists every outcome, so none of them renders as an empty row" {
        $unlisted.Count -eq 0
    } "missing=[$($unlisted -join '|')]"

    $mislabelled = @($warnStates | Where-Object { (Get-FooterGlyph -Content $content -State $_) -ne ([char]0x26A0 + [string][char]0xFE0F) })
    Test-That "$($shape.Label) draws a refusal as a warning, never with a success tick" {
        $mislabelled.Count -eq 0
    } "mislabelled=[$(@($warnStates | ForEach-Object { "$_=>$(Get-FooterGlyph -Content $content -State $_)" }) -join '|')]"

    Test-That "$($shape.Label) still ticks what really was sent" {
        @($successStates | Where-Object { (Get-FooterGlyph -Content $content -State $_) -ne [string][char]0x2705 }).Count -eq 0
    } "glyphs=[$(@($successStates | ForEach-Object { "$_=>$(Get-FooterGlyph -Content $content -State $_)" }) -join '|')]"
    Test-That "$($shape.Label) still shows work in progress as waiting" {
        @($progressStates | Where-Object { (Get-FooterGlyph -Content $content -State $_) -ne [string][char]0x23F3 }).Count -eq 0
    } "glyphs=[$(@($progressStates | ForEach-Object { "$_=>$(Get-FooterGlyph -Content $content -State $_)" }) -join '|')]"
    Test-That "$($shape.Label) draws ending the session as waiting, not as sent" {
        (Get-FooterGlyph -Content $content -State 'Ending session...') -eq [string][char]0x23F3
    } "glyph=[$(Get-FooterGlyph -Content $content -State 'Ending session...')]"
}

# Back to the version under test for everything below.
Set-TestPublicationCardUrl -Url "/local/agent-bridge-reply-card.js?v=$cardVersion"
Save-CopilotSessionDashboard `
    -Sessions @([pscustomobject]@{ Node = $node; Name = 'Copilot: a task'; Machine = 'BOX'; Kind = 'copilot' }) `
    -ReplyCardUrl "/local/agent-bridge-reply-card.js?v=$cardVersion"

# --- 3. the real card, on that config and those states ----------------------------

$driver = Join-Path $PSScriptRoot '..\frontend\test\drive-choices-card.js'
$node_exe = (Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $node_exe) {
    # Skipping would let the whole chain rot unnoticed, which is the failure this
    # suite exists to prevent.
    Write-Host '  FAIL  node is required to run the card' -ForegroundColor Red
    exit 1
}

function Invoke-ChoicesCard {
    <# The rows the real card draws, and the service calls the given taps produce. #>
    # Allowed to be empty: what the card draws before anything is tapped is itself
    # worth asserting, and a question that arrives with rows already ticked has
    # nothing to tap at all.
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Taps)
    $config = @{ decision = [string]$cardConfig.decision; fields = @(@($cardConfig.fields) | ForEach-Object { [string]$_ }) }
    # Forwarded rather than written out: Send answer only exists because the view
    # hands the card a submit entity, and a view that stopped doing so has to fail
    # here rather than quietly leave a form with no way to send it.
    if ($cardConfig.PSObject.Properties['submit']) { $config.submit = [string]$cardConfig.submit }
    $job = @{
        config = $config
        states = $script:HaStates
        taps   = @($Taps)
    } | ConvertTo-Json -Depth 20 -Compress
    $out = $job | & $node_exe.Source $driver
    if ($LASTEXITCODE -ne 0) { throw "the card driver exited with $LASTEXITCODE" }
    $out | ConvertFrom-Json
}

$rendered = Invoke-ChoicesCard -Taps @('Patch it in place (Recommended)', 'After the release')

Write-Host ''
Write-Host '--- and the card draws it as a form ---'
Test-That 'nothing the taps asked for was missing from the rows' {
    @($rendered.missing).Count -eq 0
} "missing=[$(@($rendered.missing) -join ',')]"
Test-That 'the form is visible' { -not $rendered.hidden }
Test-That 'each field is a labelled group of its own' {
    (@($rendered.rows | Where-Object { @($_.classes) -contains 'label' } | ForEach-Object { $_.text }) -join '|') -eq 'Approach|When'
} "rows=[$(@($rendered.rows | ForEach-Object { $_.text }) -join '|')]"
Test-That 'the free-text field has no group, because it is answered in the Reply box' {
    @($rendered.rows | Where-Object { $_.text -eq 'Notes' }).Count -eq 0
}
Test-That 'cancelling is the quiet row at the bottom' {
    @($rendered.rows)[-1].text -eq 'Cancel request' -and @(@($rendered.rows)[-1].classes) -contains 'cancel'
}
Test-That 'and what has been picked stays marked while the rest is filled in' {
    (@($rendered.rows | Where-Object { @($_.classes) -contains 'chosen' } | ForEach-Object { $_.text }) -join '|') -eq
        'Patch it in place (Recommended)|After the release'
} "chosen=[$(@($rendered.rows | Where-Object { @($_.classes) -contains 'chosen' } | ForEach-Object { $_.text }) -join '|')]"

# --- 4. what the daemon reads back ------------------------------------------------

Write-Host ''
Write-Host '--- and the daemon reads the answer off those same entities ---'
Test-That 'both taps landed on a select_option call' {
    @($rendered.calls).Count -eq 2 -and
    @(@($rendered.calls) | Where-Object { $_.domain -eq 'select' -and $_.service -eq 'select_option' }).Count -eq 2
} "calls=[$(@($rendered.calls) | ForEach-Object { "$($_.data.entity_id)=$($_.data.option)" })]"

# Apply exactly what the card sent, then ask the daemon. The entity ids are the card's
# own - if it set something the daemon does not read, the answer comes back empty.
foreach ($call in @($rendered.calls)) {
    $entityId = [string]$call.data.entity_id
    if (-not $script:HaStates.Contains($entityId)) { $script:HaStates[$entityId] = [ordered]@{ state = ''; attributes = @{} } }
    $script:HaStates[$entityId].state = [string]$call.data.option
}
$script:HaStates["text.${node}_reply"] = [ordered]@{ state = 'nothing to add'; attributes = @{} }
$script:HaStates["button.${node}_submit"] = [ordered]@{ state = [DateTimeOffset]::Now.ToString('o'); attributes = @{} }

$marker = [pscustomobject]@{
    decisionId      = 'd1'
    mode            = 'multiple_choice'
    armedAt         = $armedAt.ToString('o')
    fields          = $fields
}
$state = @{ $sessionId = [pscustomobject]@{ Name = 'Copilot: a task'; Machine = 'BOX'; LastSubmitAt = '' } }
$answer = Read-DaemonFormAnswer -SessionId $sessionId -Marker $marker -State $state -Headers $headers

Test-That 'the form reads as complete and submitted' {
    -not [string]::IsNullOrWhiteSpace($answer.Answer)
} "answer=[$($answer.Answer)]"
Test-That 'and its selections are exactly what was tapped, field by field' {
    (@($answer.Selections) -join '|') -eq 'Patch it in place (Recommended)|After the release|nothing to add'
} "selections=[$(@($answer.Selections) -join '|')]"

# The other half of the same wire: a field left alone must not be readable as answered.
$script:HaStates["select.${node}_f2"].state = 'Choose...'
$partial = Read-DaemonFormAnswer -SessionId $sessionId -Marker $marker -State $state -Headers $headers
Test-That 'a form with a field still untouched sends nothing' {
    [string]::IsNullOrWhiteSpace($partial.Answer)
} "answer=[$($partial.Answer)]"

# And cancelling, which rides on the main selector rather than a field.
$script:HaStates["select.${node}_f2"].state = 'After the release'
$cancelled = Invoke-ChoicesCard -Taps @('Cancel request')
foreach ($call in @($cancelled.calls)) {
    $script:HaStates[[string]$call.data.entity_id].state = [string]$call.data.option
}
Test-That 'the cancel row sets the decision selector, not a field' {
    @($cancelled.calls).Count -eq 1 -and [string]@($cancelled.calls)[0].data.entity_id -eq "select.${node}_decision"
} "calls=[$(@($cancelled.calls) | ForEach-Object { "$($_.data.entity_id)=$($_.data.option)" })]"
$withdrawn = Read-DaemonFormAnswer -SessionId $sessionId -Marker $marker -State $state -Headers $headers
Test-That 'and the daemon reads that as the request being withdrawn' {
    $withdrawn.Answer -eq 'Cancel request'
} "answer=[$($withdrawn.Answer)]"

# --- 5. one choice, and the Send that every answer now needs --------------------

Write-Host ''
Write-Host '--- a single choice is a field like any other, and waits for Send ---'
# It used to ride on the main selector and go the instant it was tapped, so the
# dashboard behaved two ways for one gesture: this question sent itself, the form
# beside it waited. A tap is also the easiest thing to do by accident on a phone, and
# there was nothing to undo it with.
$script:HaStates = @{}
$oneField = @([pscustomobject]@{ Label = 'Database'; Options = @('PostgreSQL', 'SQLite'); IsText = $false })
$armedOne = [DateTimeOffset]::Now.AddSeconds(-5)
Set-CopilotMqttDecision -SessionId $sessionId -SessionName 'Copilot: a task' -Machine 'BOX' `
    -Question 'Which database?' -Choices @('PostgreSQL', 'SQLite') -Fields $oneField `
    -DecisionId 'd2' -Headers $headers | Out-Null

Test-That 'the one option list is published as a field, not on the main selector' {
    (@($script:HaStates["select.${node}_f1"].attributes.options) -join ',') -eq 'Choose...,PostgreSQL,SQLite' -and
    (@($script:HaStates["select.${node}_decision"].attributes.options) -join ',') -eq 'Awaiting answer...,Cancel request'
} "f1=[$(@($script:HaStates["select.${node}_f1"].attributes.options) -join ',')] decision=[$(@($script:HaStates["select.${node}_decision"].attributes.options) -join ',')]"

$single = Invoke-ChoicesCard -Taps @('SQLite')
Test-That 'tapping an option sets the field, not the decision selector' {
    @($single.calls).Count -eq 1 -and
    [string]@($single.calls)[0].data.entity_id -eq "select.${node}_f1" -and
    [string]@($single.calls)[0].data.option -eq 'SQLite'
} "calls=[$(@($single.calls) | ForEach-Object { "$($_.data.entity_id)=$($_.data.option)" })]"
Test-That 'and the card offers Send answer, because nothing sends itself now' {
    @($single.rows | Where-Object { $_.text -eq 'Send answer' }).Count -eq 1
} "rows=[$(@($single.rows | ForEach-Object { $_.text }) -join '|')]"

foreach ($call in @($single.calls)) { $script:HaStates[[string]$call.data.entity_id].state = [string]$call.data.option }
$script:HaStates["text.${node}_reply"] = [ordered]@{ state = ' '; attributes = @{} }
$script:HaStates["button.${node}_submit"] = [ordered]@{ state = $armedOne.ToString('o'); attributes = @{} }
$oneMarker = [pscustomobject]@{ decisionId = 'd2'; mode = 'multiple_choice'; armedAt = $armedOne.ToString('o'); fields = $oneField }
Set-Baseline -DecisionId 'd2' -SubmitState 'present' -SubmitValue $armedOne.ToString('o')
$oneState = @{ $sessionId = [pscustomobject]@{ Name = 'Copilot: a task'; Machine = 'BOX'; LastSubmitAt = '' } }

Test-That 'a chosen option on its own is not an answer yet' {
    [string]::IsNullOrWhiteSpace((Read-DaemonDecisionAnswer -SessionId $sessionId -Marker $oneMarker -State $oneState -Headers $headers).Answer)
}

$pressed = Invoke-ChoicesCard -Taps @('Send answer')
Test-That 'Send answer presses the submit button the daemon waits on' {
    @($pressed.calls).Count -eq 1 -and
    [string]@($pressed.calls)[0].domain -eq 'button' -and
    [string]@($pressed.calls)[0].service -eq 'press' -and
    [string]@($pressed.calls)[0].data.entity_id -eq "button.${node}_submit"
} "calls=[$(@($pressed.calls) | ForEach-Object { "$($_.domain).$($_.service) $($_.data.entity_id)" })]"

$script:HaStates["button.${node}_submit"].state = [DateTimeOffset]::Now.ToString('o')
$oneAnswer = Read-DaemonDecisionAnswer -SessionId $sessionId -Marker $oneMarker -State $oneState -Headers $headers
Test-That 'and then the daemon reads exactly the option that was tapped' {
    $oneAnswer.Answer -eq 'SQLite' -and (@($oneAnswer.Selections) -join '|') -eq 'SQLite' -and -not $oneAnswer.IsFreeText
} "answer=[$($oneAnswer.Answer)] selections=[$(@($oneAnswer.Selections) -join '|')]"

# --- 6. a question that takes several options -----------------------------------

Write-Host ''
Write-Host '--- and a multi-select question takes as many as you like ---'
$script:HaStates = @{}
$multiField = @([pscustomobject]@{
    Label = 'Features'; Options = @('Auth', 'Billing', 'Search'); IsText = $false
    MultiSelect = $true; MultiSelectStyle = 'space-toggle'; DefaultIndexes = @()
})
$armedMulti = [DateTimeOffset]::Now.AddSeconds(-5)
Set-CopilotMqttDecision -SessionId $sessionId -SessionName 'Copilot: a task' -Machine 'BOX' `
    -Question 'Which features?' -Choices @('Auth', 'Billing', 'Search') -Fields $multiField `
    -DecisionId 'd3' -Headers $headers | Out-Null

Test-That 'the slot enumerates every combination, because a select holds one value' {
    $offered = @($script:HaStates["select.${node}_f1"].attributes.options)
    # Both carriers: the options written out for any card up to 1.22.0, then the same
    # subsets as positions for 1.23.0 and later, which is what lets a question whose
    # options are ordinary sentences be answered here at all.
    ($offered -join ',') -eq
        ('Choose...,Auth,Billing,Search,Auth + Billing,Auth + Search,Billing + Search,Auth + Billing + Search,' +
         '#1,#2,#3,#1,2,#1,3,#2,3,#1,2,3')
} "f1=[$(@($script:HaStates["select.${node}_f1"].attributes.options) -join ',')]"
Test-That 'and the card is told the slot will take positions' {
    $script:HaStates["select.${node}_decision"].attributes['field_1_codes'] -eq $true
} "attrs=[$(@($script:HaStates["select.${node}_decision"].attributes.Keys) -join ',')]"
Test-That 'and the options themselves ride on the attributes for the card to draw' {
    $a = $script:HaStates["select.${node}_decision"].attributes
    $a['field_1_multi'] -and (@($a['field_1_options']) -join ',') -eq 'Auth,Billing,Search' -and
    $a['field_1_separator'] -eq ' + '
} "attrs=[$(@($script:HaStates["select.${node}_decision"].attributes.Keys) -join ',')]"

$multi = Invoke-ChoicesCard -Taps @('Auth', 'Search')
Test-That 'the card draws the options, not the combinations' {
    (@($multi.rows | Where-Object { $_.tag -eq 'BUTTON' } | ForEach-Object { $_.text }) -join '|') -eq
        'Auth|Billing|Search|Send answer|Cancel request'
} "rows=[$(@($multi.rows | ForEach-Object { $_.text }) -join '|')]"
Test-That 'and says on the heading that more than one may be ticked' {
    @($multi.rows | Where-Object { @($_.classes) -contains 'label' } | ForEach-Object { $_.text }) -contains 'Features (pick any)'
} "labels=[$(@($multi.rows | Where-Object { @($_.classes) -contains 'label' } | ForEach-Object { $_.text }) -join '|')]"
Test-That 'two taps leave the slot holding both, not just the last one' {
    [string]@($multi.calls)[-1].data.option -eq '#1,3'
} "calls=[$(@($multi.calls) | ForEach-Object { "$($_.data.entity_id)=$($_.data.option)" })]"
Test-That 'and both rows stay ticked while the choice is still being made' {
    (@($multi.rows | Where-Object { @($_.classes) -contains 'chosen' } | ForEach-Object { $_.text }) -join '|') -eq 'Auth|Search'
} "chosen=[$(@($multi.rows | Where-Object { @($_.classes) -contains 'chosen' } | ForEach-Object { $_.text }) -join '|')]"

foreach ($call in @($multi.calls)) { $script:HaStates[[string]$call.data.entity_id].state = [string]$call.data.option }
$untick = Invoke-ChoicesCard -Taps @('Auth')
Test-That 'tapping a ticked option unticks it rather than sending it' {
    [string]@($untick.calls)[-1].data.option -eq '#3'
} "calls=[$(@($untick.calls) | ForEach-Object { "$($_.data.entity_id)=$($_.data.option)" })]"
$script:HaStates["select.${node}_f1"].state = '#1,3'

$script:HaStates["text.${node}_reply"] = [ordered]@{ state = ' '; attributes = @{} }
$script:HaStates["button.${node}_submit"] = [ordered]@{ state = [DateTimeOffset]::Now.ToString('o'); attributes = @{} }
$multiMarker = [pscustomobject]@{ decisionId = 'd3'; mode = 'multiple_choice'; armedAt = $armedMulti.ToString('o'); fields = $multiField }
Set-Baseline -DecisionId 'd3'
$multiState = @{ $sessionId = [pscustomobject]@{ Name = 'Copilot: a task'; Machine = 'BOX'; LastSubmitAt = '' } }
$multiAnswer = Read-DaemonDecisionAnswer -SessionId $sessionId -Marker $multiMarker -State $multiState -Headers $headers

Test-That 'the daemon reads both options back off that one slot' {
    # The selection is what the slot held, not how it reads: a field can offer an
    # option that reads exactly like two others joined, and deriving one from the
    # other sent the wrong rows.
    (@($multiAnswer.Selections) -join '|') -eq '#1,3' -and $multiAnswer.Answer -ceq 'Auth + Search'
} "selections=[$(@($multiAnswer.Selections) -join '|')] answer=[$($multiAnswer.Answer)]"
Test-That 'and the keystrokes tick exactly those two rows, with no walk to a Submit' {
    $esc = [string][char]27
    @(Get-BridgeFormPayloads -Fields $multiField -Selections @($multiAnswer.Selections))[0].Payload -eq
        (' ' + ($esc + '[B') + ($esc + '[B') + ' ')
} ((@(Get-BridgeFormPayloads -Fields $multiField -Selections @($multiAnswer.Selections))[0].Payload) -replace [regex]::Escape([string][char]27), '<esc>')

# --- 6b. a question whose schema already has rows ticked ------------------------

Write-Host ''
Write-Host '--- a question that arrives with options already chosen ---'
# The native prompt shows a schema default already checked, and the card used to
# start empty regardless - a state the session was not in, and one that could only
# be got back to by ticking the whole set again by hand.
$script:HaStates = @{}
$defaultedField = @([pscustomobject]@{
    Label = 'Features'; Options = @('Auth', 'Billing', 'Search'); IsText = $false
    MultiSelect = $true; MultiSelectStyle = 'space-toggle'; DefaultIndexes = @(0, 2)
})
Set-CopilotMqttDecision -SessionId $sessionId -SessionName 'Copilot: a task' -Machine 'BOX' `
    -Question 'Which features?' -Choices @('Auth', 'Billing', 'Search') -Fields $defaultedField `
    -DecisionId 'd3b' -Headers $headers | Out-Null

Test-That 'the slot starts on exactly the set the terminal already has ticked' {
    [string]$script:HaStates["select.${node}_f1"].state -eq '#1,3'
} "state=[$($script:HaStates["select.${node}_f1"].state)]"
$defaulted = Invoke-ChoicesCard -Taps @()
Test-That 'so the card shows those rows ticked, rather than an empty list' {
    (@($defaulted.rows | Where-Object { @($_.classes) -contains 'chosen' } | ForEach-Object { $_.text }) -join '|') -eq 'Auth|Search'
} "chosen=[$(@($defaulted.rows | Where-Object { @($_.classes) -contains 'chosen' } | ForEach-Object { $_.text }) -join '|')]"
Test-That 'and it still takes an explicit Send, exactly like every other question' {
    @($defaulted.calls).Count -eq 0 -and @($defaulted.rows | Where-Object { $_.text -eq 'Send answer' }).Count -eq 1
} "calls=[$(@($defaulted.calls).Count)] rows=[$(@($defaulted.rows | ForEach-Object { $_.text }) -join '|')]"

# Accepting the defaults unchanged has to reach the terminal as no keystrokes at
# all: those rows are already ticked there, and toggling them would turn them off.
$script:HaStates["text.${node}_reply"] = [ordered]@{ state = ' '; attributes = @{} }
$script:HaStates["button.${node}_submit"] = [ordered]@{ state = [DateTimeOffset]::Now.ToString('o'); attributes = @{} }
$defaultedMarker = [pscustomobject]@{ decisionId = 'd3b'; mode = 'multiple_choice'; armedAt = $armedMulti.ToString('o'); fields = $defaultedField }
Set-Baseline -DecisionId 'd3b'
$defaultedState = @{ $sessionId = [pscustomobject]@{ Name = 'Copilot: a task'; Machine = 'BOX'; LastSubmitAt = '' } }
$defaultedAnswer = Read-DaemonDecisionAnswer -SessionId $sessionId -Marker $defaultedMarker -State $defaultedState -Headers $headers
Test-That 'the daemon reads the default set as the answer once Send is pressed' {
    (@($defaultedAnswer.Selections) -join '|') -eq '#1,3' -and $defaultedAnswer.Answer -ceq 'Auth + Search'
} "selections=[$(@($defaultedAnswer.Selections) -join '|')] answer=[$($defaultedAnswer.Answer)]"
Test-That 'and sending it untouched types nothing, because the rows are already ticked' {
    @(Get-BridgeFormPayloads -Fields $defaultedField -Selections @($defaultedAnswer.Selections))[0].Payload -eq ''
} ((@(Get-BridgeFormPayloads -Fields $defaultedField -Selections @($defaultedAnswer.Selections))[0].Payload) -replace [regex]::Escape([string][char]27), '<esc>')

# A field whose combinations were too many to offer has none to start on, so it has
# to stay on the placeholder rather than hold a value its dropdown never carried.
$script:HaStates = @{}
$hugeField = @([pscustomobject]@{
    Label = 'Features'; Options = @(1..8 | ForEach-Object { "Option $_" }); IsText = $false
    MultiSelect = $true; MultiSelectStyle = 'space-toggle'; DefaultIndexes = @(0, 1)
})
Set-CopilotMqttDecision -SessionId $sessionId -SessionName 'Copilot: a task' -Machine 'BOX' `
    -Question 'Which features?' -Choices @() -Fields $hugeField `
    -DecisionId 'd3c' -Headers $headers | Out-Null
Test-That 'a field with too many combinations to list starts on the placeholder, not on a value it never offered' {
    $state = [string]$script:HaStates["select.${node}_f1"].state
    $state -eq 'Choose...' -or @($script:HaStates["select.${node}_f1"].attributes.options) -contains $state
} "state=[$($script:HaStates["select.${node}_f1"].state)] options=$(@($script:HaStates["select.${node}_f1"].attributes.options).Count)"

# An option written like a position disables that carrier for the whole field, but the
# code generated for the default was still tried - and 'A' plus 'B' generates '#1,2',
# which is on the list as the third option's own label. The slot opened holding that
# option, the card drew it ticked, and Send submitted an answer nobody chose.
$script:HaStates = @{}
$literalCodeField = @([pscustomobject]@{
    Label = 'Rows'; Options = @('A', 'B', '#1,2'); IsText = $false
    MultiSelect = $true; MultiSelectStyle = 'space-toggle'; DefaultIndexes = @(0, 1)
})
Set-CopilotMqttDecision -SessionId $sessionId -SessionName 'Copilot: a task' -Machine 'BOX' `
    -Question 'Which rows?' -Choices @() -Fields $literalCodeField `
    -DecisionId 'd3d' -Headers $headers | Out-Null
Test-That 'a field that cannot carry positions starts on the words, not on an option that reads like one' {
    [string]$script:HaStates["select.${node}_f1"].state -ceq 'A + B'
} "state=[$($script:HaStates["select.${node}_f1"].state)]"
Test-That 'so what it starts on really does mean those two rows' {
    (@(Resolve-DecisionMultiSelectChoice -Field $literalCodeField[0] `
        -Choice ([string]$script:HaStates["select.${node}_f1"].state)) -join '|') -eq 'A|B'
} "resolves=[$(@(Resolve-DecisionMultiSelectChoice -Field $literalCodeField[0] -Choice ([string]$script:HaStates["select.${node}_f1"].state)) -join '|')]"

# --- 6c. the question that actually failed on the dashboard ---------------------

Write-Host ''
Write-Host '--- six ordinarily-worded options, the whole way through ---'
# 2026-10-05: six plainly-worded follow-ups, nothing unusual about any of them. The
# slot had to hold the answer as those options written out and joined, which came to
# 350 characters against a 255-character select entry, so the bridge offered nothing
# and the dashboard said to answer in the terminal. This follows the same question
# from publish to keystrokes.
$script:HaStates = @{}
$realOptions = @(
    'Restore this VM to release 1.32.2 now',
    'Leave the branch installed so I can keep testing',
    'Investigate why the dashboard stopped re-rendering at 19:30',
    'Fix the Scout headless copilot.exe being counted as a CLI session',
    'Commit the correction work and report to the coordinator',
    'Raise the diverged release line (v1.32.2 vs main) with the coordinator')
$realField = @([pscustomobject]@{
    Label = 'Follow-ups'; Options = $realOptions; IsText = $false
    MultiSelect = $true; MultiSelectStyle = 'space-toggle'; DefaultIndexes = @()
})
$armedReal = [DateTimeOffset]::Now.AddSeconds(-5)
Set-CopilotMqttDecision -SessionId $sessionId -SessionName 'Copilot: a task' -Machine 'BOX' `
    -Question 'Which follow-ups do you want?' -Choices @() -Fields $realField `
    -DecisionId 'd6' -Headers $headers | Out-Null

Test-That 'the question is published as a field rather than refused' {
    $offered = @($script:HaStates["select.${node}_f1"].attributes.options)
    $offered.Count -eq 64 -and $offered[0] -ceq 'Choose...'
} "offered=$(@($script:HaStates["select.${node}_f1"].attributes.options).Count)"
Test-That 'and every entry stays short, however long the options were written' {
    $offered = @($script:HaStates["select.${node}_f1"].attributes.options)
    ($offered | Measure-Object -Property Length -Maximum).Maximum -le 32
} "longest=$((@($script:HaStates["select.${node}_f1"].attributes.options) | Measure-Object -Property Length -Maximum).Maximum) joined=$(($realOptions -join ' + ').Length)"

$realCard = Invoke-ChoicesCard -Taps @($realOptions[0], $realOptions[2], $realOptions[5])
Test-That 'the card draws the options themselves, in full, not the combinations' {
    (@($realCard.rows | Where-Object { $_.tag -eq 'BUTTON' } | ForEach-Object { $_.text }) -join '|') -eq
        (($realOptions -join '|') + '|Send answer|Cancel request')
} "rows=[$(@($realCard.rows | ForEach-Object { $_.text }) -join '|')]"
Test-That 'three ticks leave the slot holding all three, as positions' {
    [string]@($realCard.calls)[-1].data.option -eq '#1,3,6'
} "calls=[$(@($realCard.calls) | ForEach-Object { $_.data.option })]"
Test-That 'and all three stay ticked while the choice is still being made' {
    (@($realCard.rows | Where-Object { @($_.classes) -contains 'chosen' } | ForEach-Object { $_.text }) -join '|') -eq
        (@($realOptions[0], $realOptions[2], $realOptions[5]) -join '|')
} "chosen=[$(@($realCard.rows | Where-Object { @($_.classes) -contains 'chosen' } | ForEach-Object { $_.text }) -join '|')]"

foreach ($call in @($realCard.calls)) { $script:HaStates[[string]$call.data.entity_id].state = [string]$call.data.option }
$script:HaStates["text.${node}_reply"] = [ordered]@{ state = ' '; attributes = @{} }
$script:HaStates["button.${node}_submit"] = [ordered]@{ state = [DateTimeOffset]::Now.ToString('o'); attributes = @{} }
$realMarker = [pscustomobject]@{ decisionId = 'd6'; mode = 'multiple_choice'; armedAt = $armedReal.ToString('o'); fields = $realField }
Set-Baseline -DecisionId 'd6'
$realState = @{ $sessionId = [pscustomobject]@{ Name = 'Copilot: a task'; Machine = 'BOX'; LastSubmitAt = '' } }
$realAnswer = Read-DaemonDecisionAnswer -SessionId $sessionId -Marker $realMarker -State $realState -Headers $headers

Test-That 'the daemon reads it back as the options themselves, not as positions' {
    $realAnswer.Answer -ceq (@($realOptions[0], $realOptions[2], $realOptions[5]) -join ' + ')
} "answer=[$($realAnswer.Answer)]"
Test-That 'and the keystrokes tick exactly those three rows' {
    $esc = [string][char]27
    @(Get-BridgeFormPayloads -Fields $realField -Selections @($realAnswer.Selections))[0].Payload -eq
        (' ' + ($esc + '[B') + ($esc + '[B') + ' ' + ($esc + '[B') + ($esc + '[B') + ($esc + '[B') + ' ')
} ((@(Get-BridgeFormPayloads -Fields $realField -Selections @($realAnswer.Selections))[0].Payload) -replace [regex]::Escape([string][char]27), '<esc>')

# A slot holding something that decodes to nothing is not an answer. Reading it as one
# would send a set nobody picked.
$script:HaStates["select.${node}_f1"].state = '#9,99'
Test-That 'a slot holding positions this field does not have is read as unanswered' {
    [string]::IsNullOrWhiteSpace((Read-DaemonDecisionAnswer -SessionId $sessionId -Marker $realMarker -State $realState -Headers $headers).Answer)
}

# --- 6d. released cards, against what the bridge publishes today ------------------

Write-Host ''
Write-Host '--- the cards that are actually out there still work ---'
# Asserting that an older card keeps working is cheap. This takes the real file out of
# the released tag and drives it against the real published option list, with Home
# Assistant's own refusal of a value outside that list enforced - which is the failure
# an ungated change would cause.
$releasedDriver = Join-Path $PSScriptRoot '..\frontend\test\drive-released-card.js'
$releasedDir = Join-Path ([IO.Path]::GetTempPath()) "bridge-released-cards-$([guid]::NewGuid().ToString('N').Substring(0,8))"
[void](New-Item -ItemType Directory -Force -Path $releasedDir)
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$released = [ordered]@{}
foreach ($spec in @(
    @{ Name = '1.21.1'; Ref = 'v1.32.2' }   # the card in the latest release
    @{ Name = '1.22.0'; Ref = '1e67436' }   # this branch's published head
)) {
    $out = Join-Path $releasedDir "card-$($spec.Name).js"
    $text = & git -C $repoRoot show "$($spec.Ref):frontend/agent-bridge-reply-card.js" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $text) { continue }
    [IO.File]::WriteAllText($out, ($text -join "`n"), [Text.UTF8Encoding]::new($false))
    $released[$spec.Name] = $out
}
if ($released.Count -lt 2) {
    Write-Host "  SKIP  released card files are not reachable from this checkout" -ForegroundColor Yellow
}
else {
    function Invoke-ReleasedCard {
        param(
            [Parameter(Mandatory)][string]$CardPath,
            [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Taps
        )
        $config = @{ decision = [string]$cardConfig.decision; fields = @(@($cardConfig.fields) | ForEach-Object { [string]$_ }) }
        if ($cardConfig.PSObject.Properties['submit']) { $config.submit = [string]$cardConfig.submit }
        $job = @{ card = $CardPath; config = $config; states = $script:HaStates; taps = @($Taps) } |
            ConvertTo-Json -Depth 40 -Compress
        # stdout only. Anything the runtime says about an older card goes to stderr and
        # would otherwise be spliced into the middle of the JSON.
        $result = $job | & $node_exe $releasedDriver
        $text = ($result -join '')
        if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{ threw = 'the driver wrote nothing' } }
        try { $text | ConvertFrom-Json }
        catch { [pscustomobject]@{ threw = "unparsable driver output: $($text.Substring(0, [Math]::Min(120, $text.Length)))" } }
    }

    # Short options: both carriers are published, so an older card writes the words and
    # Home Assistant takes them.
    $script:HaStates = @{}
    Set-CopilotMqttDecision -SessionId $sessionId -SessionName 'Copilot: a task' -Machine 'BOX' `
        -Question 'Which features?' -Choices @('Auth', 'Billing', 'Search') -Fields $multiField `
        -DecisionId 'd7' -Headers $headers | Out-Null

    # Never $name here: Test-That declares a $Name parameter, PowerShell resolves
    # variables case-insensitively up the scope it is called from, so inside a
    # condition $name is the test's own title. These checks compared a card version
    # against a sentence and failed while every part of them read as true.
    foreach ($cardName in @($released.Keys)) {
        $run = Invoke-ReleasedCard -CardPath $released[$cardName] -Taps @('Auth', 'Search')
        Test-That "card $cardName loads and draws this question" {
            [string]$run.version -eq $cardName -and [string]::IsNullOrEmpty([string]$run.threw) -and -not $run.hidden -and
            @($run.missing).Count -eq 0 -and @($run.rows | Where-Object { $_.tag -eq 'BUTTON' }).Count -gt 0
        } "version=[$($run.version)] threw=[$($run.threw)] hidden=[$($run.hidden)] missing=[$(@($run.missing) -join ',')] rows=[$(@($run.rows | ForEach-Object { $_.text }) -join '|')]"
        Test-That "card $cardName writes a value Home Assistant accepts" {
            @($run.calls).Count -gt 0 -and @(@($run.calls) | Where-Object { $_.rejected }).Count -eq 0
        } "calls=[$(@($run.calls) | ForEach-Object { "$($_.data.option)$(if ($_.rejected) { '!REJECTED' })" })]"
        # 1.21.1 predates multi-select entirely: it draws the combinations as plain
        # rows and a tap picks one, so two taps leave the second. That is the bug this
        # branch exists to fix, and it is recorded here rather than wished away - what
        # matters is that it still writes something the bridge accepts rather than
        # breaking on a list it has never seen.
        $expected = if ($cardName -eq '1.21.1') { 'Search' } else { 'Auth|Search' }
        Test-That "card $cardName resolves to $expected" {
            $last = @($run.calls)[-1]
            (@(Resolve-DecisionMultiSelectChoice -Field $multiField[0] -Choice ([string]$last.data.option)) -join '|') -eq $expected
        } "last=[$(@($run.calls)[-1].data.option)]"
    }

    # Long options, where the written-out form is too long to be an entry at all, so
    # positions are the only carrier. The two older cards behave differently and both
    # are recorded rather than assumed:
    #
    # 1.21.1 knows nothing of multi-select and draws the slot's own entries, which here
    # are the positions - so it shows '#1', '#2' and so on, which mean nothing to a
    # person. It is not wrong, and anything it writes still decodes correctly; it is
    # simply unreadable. Before this change the question did not reach the dashboard at
    # all, so this is a gain with a rough edge, and the edge is written down.
    #
    # 1.22.0 does know multi-select, draws the real options, and writes them joined -
    # which is not on the list, so Home Assistant refuses it and the slot stays put.
    $script:HaStates = @{}
    Set-CopilotMqttDecision -SessionId $sessionId -SessionName 'Copilot: a task' -Machine 'BOX' `
        -Question 'Which follow-ups do you want?' -Choices @() -Fields $realField `
        -DecisionId 'd8' -Headers $headers | Out-Null

    $old = Invoke-ReleasedCard -CardPath $released['1.21.1'] -Taps @('#1')
    Test-That 'card 1.21.1 draws the positions themselves, because it has no idea what they stand for' {
        [string]::IsNullOrEmpty([string]$old.threw) -and -not $old.hidden -and
        @($old.missing).Count -eq 0 -and
        @($old.rows | Where-Object { $_.tag -eq 'BUTTON' -and $_.text -eq '#1' }).Count -eq 1
    } "threw=[$($old.threw)] missing=[$(@($old.missing) -join ',')] rows=[$(@($old.rows | ForEach-Object { $_.text }) -join '|')]"
    Test-That 'and what it writes is accepted and still means the right option' {
        @($old.calls).Count -eq 1 -and -not @($old.calls)[0].rejected -and
        (@(Resolve-DecisionMultiSelectChoice -Field $realField[0] -Choice ([string]@($old.calls)[0].data.option)) -join '|') -ceq $realOptions[0]
    } "calls=[$(@($old.calls) | ForEach-Object { "$($_.data.option)$(if ($_.rejected) { '!REJECTED' })" })]"

    $script:HaStates = @{}
    Set-CopilotMqttDecision -SessionId $sessionId -SessionName 'Copilot: a task' -Machine 'BOX' `
        -Question 'Which follow-ups do you want?' -Choices @() -Fields $realField `
        -DecisionId 'd8b' -Headers $headers | Out-Null

    $mid = Invoke-ReleasedCard -CardPath $released['1.22.0'] -Taps @($realOptions[0], $realOptions[2])
    Test-That 'card 1.22.0 draws the real options, because the bridge publishes them beside the slot' {
        [string]::IsNullOrEmpty([string]$mid.threw) -and -not $mid.hidden -and @($mid.missing).Count -eq 0
    } "threw=[$($mid.threw)] missing=[$(@($mid.missing) -join ',')]"
    Test-That 'but cannot answer it, and is refused rather than half-stored' {
        @($mid.calls).Count -gt 0 -and @(@($mid.calls) | Where-Object { -not $_.rejected }).Count -eq 0
    } "calls=[$(@($mid.calls) | ForEach-Object { "$($_.data.option.Substring(0,[Math]::Min(20,$_.data.option.Length)))$(if ($_.rejected) { '!REJECTED' })" })]"
    Test-That 'and leaves the slot on its placeholder, so the daemon reads it unanswered' {
        [string]$script:HaStates["select.${node}_f1"].state -eq 'Choose...'
    } "state=[$($script:HaStates["select.${node}_f1"].state)]"

    Remove-Item -LiteralPath $releasedDir -Recurse -Force -ErrorAction SilentlyContinue
}

# A field whose own options are written like positions keeps the words as its only
# carrier, so the two can never be confused. It still has to be fully answerable.
Write-Host ''
Write-Host '--- a field whose options look like positions ---'
$script:HaStates = @{}
# 'X' first, deliberately. With options '#1','#2',... position 1 and the option named
# '#1' are the same string, so a decoder that read the label as a position agreed by
# accident and the bug hid. Here position 1 is 'X' and the second option is '#1', so
# the two readings disagree and anything that confuses them shows up.
$hashField = @([pscustomobject]@{
    Label = 'Tickets'; Options = @('X', '#1', 'Something else'); IsText = $false
    MultiSelect = $true; MultiSelectStyle = 'space-toggle'; DefaultIndexes = @(1)
})
Set-CopilotMqttDecision -SessionId $sessionId -SessionName 'Copilot: a task' -Machine 'BOX' `
    -Question 'Which tickets?' -Choices @() -Fields $hashField `
    -DecisionId 'd9' -Headers $headers | Out-Null

Test-That 'it is offered the written-out form only, never positions' {
    $offered = @($script:HaStates["select.${node}_f1"].attributes.options)
    ($offered -join ',') -eq 'Choose...,X,#1,Something else,X + #1,X + Something else,#1 + Something else,X + #1 + Something else'
} "offered=[$(@($script:HaStates["select.${node}_f1"].attributes.options) -join ',')]"
Test-That 'and the card is not told to write positions' {
    -not $script:HaStates["select.${node}_decision"].attributes.Contains('field_1_codes')
} "attrs=[$(@($script:HaStates["select.${node}_decision"].attributes.Keys) -join ',')]"
# The default still has to arrive ticked, which means falling back to the written-out
# start value because this field has no position form to use.
Test-That 'its schema default still opens ticked, through the written-out form' {
    [string]$script:HaStates["select.${node}_f1"].state -eq '#1'
} "state=[$($script:HaStates["select.${node}_f1"].state)]"

$hashCard = Invoke-ChoicesCard -Taps @('Something else')
Test-That 'the card draws the options themselves and composes on the default' {
    [string]@($hashCard.calls)[-1].data.option -eq '#1 + Something else'
} "calls=[$(@($hashCard.calls) | ForEach-Object { $_.data.option })]"

foreach ($call in @($hashCard.calls)) { $script:HaStates[[string]$call.data.entity_id].state = [string]$call.data.option }
$script:HaStates["text.${node}_reply"] = [ordered]@{ state = ' '; attributes = @{} }
$script:HaStates["button.${node}_submit"] = [ordered]@{ state = [DateTimeOffset]::Now.ToString('o'); attributes = @{} }
$hashMarker = [pscustomobject]@{ decisionId = 'd9'; mode = 'multiple_choice'; armedAt = $armedMulti.ToString('o'); fields = $hashField }
Set-Baseline -DecisionId 'd9'
$hashState = @{ $sessionId = [pscustomobject]@{ Name = 'Copilot: a task'; Machine = 'BOX'; LastSubmitAt = '' } }
$hashAnswer = Read-DaemonDecisionAnswer -SessionId $sessionId -Marker $hashMarker -State $hashState -Headers $headers
Test-That 'and the daemon reads exactly those two back, with the words as the selection' {
    (@($hashAnswer.Selections) -join '|') -eq '#1 + Something else' -and $hashAnswer.Answer -ceq '#1 + Something else'
} "selections=[$(@($hashAnswer.Selections) -join '|')] answer=[$($hashAnswer.Answer)]"
Test-That 'and the keystrokes tick the second and third rows' {
    $esc = [string][char]27
    @(Get-BridgeFormPayloads -Fields $hashField -Selections @($hashAnswer.Selections))[0].Payload -eq
        ($esc + '[B') + ($esc + '[B') + ' '
} ((@(Get-BridgeFormPayloads -Fields $hashField -Selections @($hashAnswer.Selections))[0].Payload) -replace [regex]::Escape([string][char]27), '<esc>')

# --- 7. the words typed at a choice question ------------------------------------

Write-Host ''
Write-Host '--- and words typed in the reply box answer through "Other" ---'
# The box was on screen, Send worked, and the daemon read only the selector - so the
# words went nowhere and nothing anywhere said so.
$script:HaStates = @{}
Set-CopilotMqttDecision -SessionId $sessionId -SessionName 'Copilot: a task' -Machine 'BOX' `
    -Question 'Which database?' -Choices @('PostgreSQL', 'SQLite') -Fields $oneField `
    -DecisionId 'd4' -Headers $headers | Out-Null
$armedText = [DateTimeOffset]::Now.AddSeconds(-5)
$script:HaStates["text.${node}_reply"] = [ordered]@{ state = ' '; attributes = @{} }
$script:HaStates["button.${node}_submit"] = [ordered]@{ state = $armedText.ToString('o'); attributes = @{} }
$script:HaStates["sensor.${node}_reply_payload"] = [ordered]@{
    state = [DateTimeOffset]::Now.ToString('o')
    # An object, not a dictionary: this is what Home Assistant's own JSON parses to,
    # and the daemon reads it the way it reads every other entity's attributes.
    attributes = [pscustomobject]@{ text = 'DuckDB, actually'; images = @(); files = @() }
}
$textMarker = [pscustomobject]@{ decisionId = 'd4'; mode = 'multiple_choice'; armedAt = $armedText.ToString('o'); fields = $oneField }
Set-Baseline -DecisionId 'd4' -PayloadState 'present' -PayloadValue 'what-the-card-held-when-this-was-armed' `
    -SubmitState 'present' -SubmitValue $armedText.ToString('o')
$textState = @{ $sessionId = [pscustomobject]@{ Name = 'Copilot: a task'; Machine = 'BOX'; LastSubmitAt = '' } }
$typed = Read-DaemonDecisionAnswer -SessionId $sessionId -Marker $textMarker -State $textState -Headers $headers

Test-That 'what was typed is the answer, and is marked as typed rather than chosen' {
    $typed.Answer -eq 'DuckDB, actually' -and $typed.IsFreeText -and $typed.IsChoice
} "answer=[$($typed.Answer)] freeText=[$($typed.IsFreeText)]"
Test-That 'and the publish it came from is named, so it is not sent twice' {
    -not [string]::IsNullOrWhiteSpace($typed.PayloadStamp)
}

# A payload the question was armed against belongs to the reply path, not to this
# question - whatever its clock says.
$script:HaStates["sensor.${node}_reply_payload"].state = 'what-the-card-held-when-this-was-armed'
Test-That 'something the question was armed against is not its answer' {
    [string]::IsNullOrWhiteSpace((Read-DaemonDecisionAnswer -SessionId $sessionId -Marker $textMarker -State $textState -Headers $headers).Answer)
}

# An attachment cannot be typed into an arrow-key prompt, and consuming it here would
# destroy it; the reply path stages and delivers it once the question has gone.
$script:HaStates["sensor.${node}_reply_payload"].state = [DateTimeOffset]::Now.ToString('o')
$script:HaStates["sensor.${node}_reply_payload"].attributes.images = @([pscustomobject]@{ id = 'i1'; name = 'shot.png' })
Test-That 'a reply carrying an image is left alone rather than half-delivered' {
    [string]::IsNullOrWhiteSpace((Read-DaemonDecisionAnswer -SessionId $sessionId -Marker $textMarker -State $textState -Headers $headers).Answer)
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green