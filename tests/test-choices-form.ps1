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
function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    # Shaped like Home Assistant's own refusal: it answers 404 for an entity it does
    # not have, and the bridge tells that apart from being unable to read at all.
    if (-not $script:HaStates.Contains($EntityId)) { throw "404 Not Found: no such entity: $EntityId" }
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
      'Not sent - no Send button on this session') |
        ForEach-Object { $emitted -contains $_ } | Where-Object { -not $_ } | Measure-Object |
        ForEach-Object { $_.Count -eq 0 }
} "emitted=[$($emitted -join '|')]"

# The refusals and the two verification warnings must be drawn as warnings; a
# refusal with a success tick is the card saying an answer was sent at the moment it
# is refusing to send it, which is worse than saying nothing.
$warnStates = @(
    'Not sent - answer every field'
    'Not sent - this question takes options'
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
    (@($multiAnswer.Selections) -join '|') -eq 'Auth + Search'
} "selections=[$(@($multiAnswer.Selections) -join '|')]"
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
    (@($defaultedAnswer.Selections) -join '|') -eq 'Auth + Search'
} "selections=[$(@($defaultedAnswer.Selections) -join '|')]"
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