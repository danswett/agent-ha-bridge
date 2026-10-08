#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for answering questions from the dashboard (hooks/daemon-decisions.ps1).

.DESCRIPTION
    Invoke-PendingDecisions decides, for each session with a question pending, whether
    its card holds an answer to deliver. It had no direct test; its steps are separate
    functions now and are checked here against a stand-in Home Assistant: a table of
    entity states. Nothing is typed into any session.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
$script:DaemonConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-daemon-decisions-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

$headers = @{ Authorization = 'Bearer test' }
$sid = '11111111-0000-4000-8000-000000000001'
$node = Get-CopilotMqttNodeId -SessionId $sid

# Home Assistant, as a table of entity states; a missing entity throws, as a 404 does.
# Home Assistant's own answer for an entity it does not have, as a status rather than
# as wording: the bridge reads absence off the status code, never off a message.
function New-TestHaNotFound {
    param([Parameter(Mandatory)][string]$EntityId)
    $notFound = [InvalidOperationException]::new("Response status code does not indicate success: 404 (Not Found). [$EntityId]")
    $notFound.Data['BridgeHttpStatus'] = 404
    $notFound
}
$script:Ha = @{}
function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    if (-not $script:Ha.ContainsKey($EntityId)) { throw (New-TestHaNotFound -EntityId $EntityId) }
    $v = $script:Ha[$EntityId]
    if ($v -is [pscustomobject]) { return $v }
    [pscustomobject]@{ state = [string]$v; attributes = [pscustomobject]@{ question = 'Pick' } }
}
$script:Transient = @()
function Set-DaemonTransientActivity { param($SessionId, $Summary, $Extra, $Headers) $script:Transient += $Summary; 'emitted' }
function Write-DaemonLog { param([string]$Message) }

$armedAt = [DateTimeOffset]::Now.AddMinutes(-2)
# The baseline is what the card already held when the question was armed. Everything
# after that is "has this changed", never "is this newer" - the payload stamp comes
# from a browser and armedAt from the daemon, so ordering them compares two unrelated
# clocks. It lives in a file of its own per question, so these seed real ones rather
# than putting fields on the marker that nothing reads any more.
function Set-Baseline {
    param(
        [Parameter(Mandatory)][string]$DecisionId,
        [ValidateSet('present', 'absent', 'unknown')][string]$PayloadState = 'absent',
        [AllowEmptyString()][string]$PayloadValue = '',
        [ValidateSet('present', 'absent', 'unknown')][string]$SubmitState = 'absent',
        [AllowEmptyString()][string]$SubmitValue = ''
    )
    $path = Get-CopilotDecisionBaselinePath -SessionId $script:sid -DecisionId $DecisionId
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    $ok = Set-CopilotDecisionMarkerBaseline -SessionId $script:sid -DecisionId $DecisionId `
        -PayloadState $PayloadState -PayloadValue $PayloadValue `
        -SubmitState $SubmitState -SubmitValue $SubmitValue
    if (-not $ok) { throw "could not seed a baseline for $DecisionId" }
}

$oldPress = $armedAt.AddMinutes(-1).ToString('o')
$form = [pscustomobject]@{
    mode = 'form'; decisionId = 'd1'; question = 'Pick'; armedAt = $armedAt.ToString('o'); choices = @(); injectedAnswer = ''
    fields = @(
        [pscustomobject]@{ Label = 'Colour'; Options = @('Red', 'Blue') }
        [pscustomobject]@{ Label = 'Size'; Options = @('S', 'L') }
        [pscustomobject]@{ Label = 'Notes'; Options = @(); IsText = $true }
    )
}
Set-Baseline -DecisionId 'd1' -SubmitState 'present' -SubmitValue $oldPress
$state = @{ $sid = [pscustomobject]@{ Name = 'Claude: x'; Machine = 'M'; LastReply = '' } }
function Set-Form { param($Colour, $Size, $Notes, $Submit, $Decision = 'Awaiting answer...')
    $script:Ha = @{
        "select.${node}_decision" = $Decision
        "select.${node}_f1" = $Colour
        "select.${node}_f2" = $Size
        "text.${node}_reply" = $Notes
        "button.${node}_submit" = $Submit
    }
}

Write-Host '--- a multi-field form ---'
Set-Form -Colour 'Blue' -Size 'L' -Notes ' ' -Submit $armedAt.AddMinutes(1).ToString('o')
$r = Read-DaemonFormAnswer -SessionId $sid -Marker $form -State $state -Headers $headers
Test-That 'every field chosen and Send pressed since arming sends it' { $r.Answer -eq 'Blue + L + ' -and (@($r.Selections) -join '|') -eq 'Blue|L|' }
Test-That 'an empty free-text field is a valid answer' { @($r.Selections).Count -eq 3 }
Test-That 'the press is consumed, so it is not also read as a Send' { $state[$sid].LastSubmitAt -eq $script:Ha["button.${node}_submit"] }
Test-That 'what a call emits never joins the result' { $r -is [pscustomobject] }

Set-Form -Colour 'Blue' -Size 'L' -Notes '' -Submit $oldPress
Test-That 'the press the question was armed against is not a new one' { (Read-DaemonFormAnswer -SessionId $sid -Marker $form -State $state -Headers $headers).Answer -eq '' }

# A Send button whose clock ran ahead of the daemon's used to be the only thing that
# mattered; now only the identity does, so a press that merely looks older still counts.
Set-Form -Colour 'Blue' -Size 'L' -Notes '' -Submit $armedAt.AddHours(-9).ToString('o')
Test-That 'a press is read by what it is, not by whether its clock looks new' {
    (Read-DaemonFormAnswer -SessionId $sid -Marker $form -State $state -Headers $headers).Answer -eq 'Blue + L + '
}

$script:Transient = @()
Set-Form -Colour 'Blue' -Size 'L' -Notes '' -Submit $armedAt.AddMinutes(1).ToString('o')
$script:Ha.Remove("button.${node}_submit")
Test-That 'no Send button means nothing is sent, rather than a submit invented from a filled form' {
    (Read-DaemonFormAnswer -SessionId $sid -Marker $form -State $state -Headers $headers).Answer -eq ''
}
Test-That 'and the card says so rather than the form looking ignored' {
    $script:Transient -contains 'Not sent - no Send button on this session'
} ($script:Transient -join '|')

$script:Transient = @()
Set-Form -Colour 'Blue' -Size 'Choose...' -Notes '' -Submit $armedAt.AddMinutes(1).ToString('o')
Test-That 'a half-filled form is not sent' { (Read-DaemonFormAnswer -SessionId $sid -Marker $form -State $state -Headers $headers).Answer -eq '' }
Test-That 'and the card says so, rather than the button looking broken' { $script:Transient -contains 'Not sent - answer every field' }
# The early press stays different from the arm-time snapshot for ever, so it used to
# send the form the moment the last field was ticked - the tap became the send.
$earlyPress = $armedAt.AddMinutes(1).ToString('o')
Set-Form -Colour 'Blue' -Size 'L' -Notes '' -Submit $earlyPress
Test-That 'finishing the form after an early Send does not send it' {
    (Read-DaemonFormAnswer -SessionId $sid -Marker $form -State $state -Headers $headers).Answer -eq ''
}
Set-Form -Colour 'Blue' -Size 'L' -Notes '' -Submit $armedAt.AddMinutes(2).ToString('o')
Test-That 'pressing Send again then does' {
    (Read-DaemonFormAnswer -SessionId $sid -Marker $form -State $state -Headers $headers).Answer -eq 'Blue + L + '
}

Set-Form -Colour 'Choose...' -Size 'Choose...' -Notes '' -Submit 'unknown' -Decision 'Cancel request'
Test-That 'Cancel on the main selector cancels the form' { (Read-DaemonFormAnswer -SessionId $sid -Marker $form -State $state -Headers $headers).Answer -eq 'Cancel request' }

Write-Host '--- a single choice, and a free-text answer ---'
# Markers as Write-CopilotDecisionMarker writes them, plus the baselines the daemon
# records when it first sees the question.
$choice = [pscustomobject]@{
    mode = 'multiple_choice'; decisionId = 'd2'; question = 'Pick'; fields = @(); choices = @('Yes', 'No')
    injectedAnswer = ''; armedAt = $armedAt.ToString('o')
}
Set-Baseline -DecisionId 'd2' -SubmitState 'present' -SubmitValue $oldPress
$script:Ha = @{ "select.${node}_decision" = 'Yes'; "button.${node}_submit" = $oldPress }
Test-That 'a tapped choice on its own is not an answer, because nothing has been sent' {
    (Read-DaemonDecisionAnswer -SessionId $sid -Marker $choice -State $state -Headers $headers).Answer -eq ''
}
$script:Ha["button.${node}_submit"] = $armedAt.AddMinutes(1).ToString('o')
Test-That 'a choice is read from the selector once Send has been pressed' {
    $x = Read-DaemonDecisionAnswer -SessionId $sid -Marker $choice -State $state -Headers $headers
    $x.Answer -eq 'Yes' -and $x.IsChoice
}
$script:Ha = @{ "select.${node}_decision" = 'Cancel request'; "button.${node}_submit" = $oldPress }
Test-That 'Cancel still withdraws without a Send, because it is not an answer' {
    (Read-DaemonDecisionAnswer -SessionId $sid -Marker $choice -State $state -Headers $headers).Answer -eq 'Cancel request'
}
$script:Ha = @{ "select.${node}_decision" = 'Awaiting answer...'; "button.${node}_submit" = $oldPress }
Test-That 'the placeholder is not an answer' { (Read-DaemonDecisionAnswer -SessionId $sid -Marker $choice -State $state -Headers $headers).Answer -eq '' }

# A press made before anything was tapped stays different from the arm-time snapshot
# for ever, so the first option tapped after it used to send itself with no second
# press. The form path had this fixed; the selector carries its own choices and never
# goes near that path, so it needed the same treatment.
$script:Transient = @()
$script:Ha["button.${node}_submit"] = $armedAt.AddMinutes(3).ToString('o')
Test-That 'Send pressed with nothing chosen sends nothing' {
    (Read-DaemonDecisionAnswer -SessionId $sid -Marker $choice -State $state -Headers $headers).Answer -eq ''
}
Test-That 'and the card says so, rather than the button looking broken' {
    $script:Transient -contains 'Not sent - choose an option'
} ($script:Transient -join '|')
$spentAtChoice = @($script:Transient).Count
[void](Read-DaemonDecisionAnswer -SessionId $sid -Marker $choice -State $state -Headers $headers)
Test-That 'and is told once, not at every pass over the question' {
    @($script:Transient).Count -eq $spentAtChoice
} ($script:Transient -join '|')
$script:Ha["select.${node}_decision"] = 'Yes'
Test-That 'tapping an option after that early Send does not send it' {
    (Read-DaemonDecisionAnswer -SessionId $sid -Marker $choice -State $state -Headers $headers).Answer -eq ''
}
$script:Ha["button.${node}_submit"] = $armedAt.AddMinutes(4).ToString('o')
Test-That 'pressing Send again then sends it' {
    (Read-DaemonDecisionAnswer -SessionId $sid -Marker $choice -State $state -Headers $headers).Answer -eq 'Yes'
}
# The spent press belongs to the question it was made at. A new question arriving while
# the button still reads that press must not find it already spent.
$next = [pscustomobject]@{
    mode = 'multiple_choice'; decisionId = 'd2b'; question = 'Pick'; fields = @(); choices = @('Yes', 'No')
    injectedAnswer = ''; armedAt = $armedAt.ToString('o')
}
Set-Baseline -DecisionId 'd2b' -SubmitState 'present' -SubmitValue $oldPress
$script:Ha = @{ "select.${node}_decision" = 'Yes'; "button.${node}_submit" = $armedAt.AddMinutes(3).ToString('o') }
Test-That 'a press spent at one question is not spent at the next' {
    (Read-DaemonDecisionAnswer -SessionId $sid -Marker $next -State $state -Headers $headers).Answer -eq 'Yes'
}
$free = [pscustomobject]@{
    mode = 'freeform'; decisionId = 'd3'; question = 'Why?'; fields = @(); choices = @()
    injectedAnswer = ''; armedAt = $armedAt.ToString('o')
}
Set-Baseline -DecisionId 'd3'
$script:Ha = @{ "text.${node}_reply" = 'Because.' }
Test-That 'a freeform answer is read from the reply box' { (Read-DaemonDecisionAnswer -SessionId $sid -Marker $free -State $state -Headers $headers).Answer -eq 'Because.' }
$script:Ha = @{ "text.${node}_reply" = ' ' }
Test-That 'the blank the box is parked on is not an answer' { (Read-DaemonDecisionAnswer -SessionId $sid -Marker $free -State $state -Headers $headers).Answer -eq '' }
# Home Assistant's own answer for an entity it does not have, as a status rather than
# as wording: the bridge reads absence off the status code, never off a message.
function New-TestHaNotFound {
    param([Parameter(Mandatory)][string]$EntityId)
    $notFound = [InvalidOperationException]::new("Response status code does not indicate success: 404 (Not Found). [$EntityId]")
    $notFound.Data['BridgeHttpStatus'] = 404
    $notFound
}
$script:Ha = @{}
Test-That 'an unreadable card gives nothing, rather than a guess' { $null -eq (Read-DaemonDecisionAnswer -SessionId $sid -Marker $free -State $state -Headers $headers) }

Write-Host '--- the retained reply payload is identity, not a clock ---'
function New-PayloadState { param([string]$Stamp, [string]$Text)
    [pscustomobject]@{ state = $Stamp; attributes = [pscustomobject]@{ text = $Text; images = @(); files = @() } }
}
# A browser running ahead of the daemon leaves a payload that looks newer than the
# question. Ordering the two used to let it answer the next question with whatever was
# last said to the session.
$stale = [pscustomobject]@{
    mode = 'freeform'; decisionId = 'd4'; question = 'Why?'; fields = @(); choices = @()
    injectedAnswer = ''; armedAt = $armedAt.ToString('o')
}
Set-Baseline -DecisionId 'd4' -PayloadState 'present' -PayloadValue 'stamp-from-the-last-reply'
$script:Ha = @{
    "text.${node}_reply" = ' '
    "sensor.${node}_reply_payload" = New-PayloadState -Stamp 'stamp-from-the-last-reply' -Text 'an answer to the last question'
}
Test-That 'a payload the question was armed against never answers it, however its clock reads' {
    (Read-DaemonDecisionAnswer -SessionId $sid -Marker $stale -State $state -Headers $headers).Answer -eq ''
}
# And the other way round: a browser running behind leaves a stamp that looks old,
# which used to leave the question waiting for ever.
$script:Ha["sensor.${node}_reply_payload"] = New-PayloadState -Stamp '1999-01-01T00:00:00.000Z' -Text 'typed just now'
$fresh = Read-DaemonDecisionAnswer -SessionId $sid -Marker $stale -State $state -Headers $headers
Test-That 'anything that has changed since is the answer, even dated in the last century' {
    $fresh.Answer -eq 'typed just now' -and $fresh.PayloadStamp -eq '1999-01-01T00:00:00.000Z'
} "answer=[$($fresh.Answer)]"
Test-That 'a question with no baseline yet reads nothing off the card at all' {
    $noBase = [pscustomobject]@{
        mode = 'freeform'; decisionId = 'd5'; question = 'Why?'; fields = @(); choices = @()
        injectedAnswer = ''; armedAt = $armedAt.ToString('o')
    }
    (Read-DaemonDecisionCardText -SessionId $sid -Marker $noBase -Headers $headers).Text -eq ''
}

# Send answer publishes the reply box and then submits, and that publish is a round
# trip. A question answered from the terminal or another dashboard inside it leaves
# words tagged for a question that has gone - and because any new text payload submits
# a complete form, the replacement would otherwise be answered with them.
function New-TaggedPayloadState {
    param([string]$Stamp, [string]$Text, [string]$DecisionId)
    [pscustomobject]@{
        state = $Stamp
        attributes = [pscustomobject]@{ text = $Text; images = @(); files = @(); decision_id = $DecisionId }
    }
}
$script:Ha["sensor.${node}_reply_payload"] = New-TaggedPayloadState -Stamp 'tagged-for-a-ghost' -Text 'meant for the last one' -DecisionId 'd-gone'
Test-That 'words tagged for a question that has gone never answer the one now armed' {
    (Read-DaemonDecisionCardText -SessionId $sid -Marker $stale -Headers $headers).Text -eq ''
}
$script:Ha["sensor.${node}_reply_payload"] = New-TaggedPayloadState -Stamp 'tagged-for-this' -Text 'meant for this one' -DecisionId 'd4'
Test-That 'and words tagged for this question still do' {
    (Read-DaemonDecisionCardText -SessionId $sid -Marker $stale -Headers $headers).Text -eq 'meant for this one'
}
# The reply card's own Send carries no tag, and nor does any card before 1.26.0, so an
# untagged payload is not a mismatch.
$script:Ha["sensor.${node}_reply_payload"] = New-PayloadState -Stamp 'untagged' -Text 'typed in the box'
Test-That 'an untagged payload is still read, so the reply box and older cards keep working' {
    (Read-DaemonDecisionCardText -SessionId $sid -Marker $stale -Headers $headers).Text -eq 'typed in the box'
}

Write-Host '--- the baseline belongs to one question, and is written once ---'
# A session of its own: the last check here clears everything belonging to it, and
# the questions the rest of this suite answers must survive that.
$casSid = '11111111-0000-4000-8000-0000000000ca'
# It used to live on the marker: read it, add to it, write the whole thing back.
# That is not compare-and-swap however carefully it checks first - a replacement
# question written in between is destroyed by it, and reading the file back
# afterwards reports success because what comes back is what was just written over
# the top.
Test-That 'a second establishment of the same question leaves the first exactly as it was' {
    $first = Set-CopilotDecisionMarkerBaseline -SessionId $casSid -DecisionId 'cas' `
        -PayloadState 'present' -PayloadValue 'first' -SubmitState 'absent' -SubmitValue ''
    $second = Set-CopilotDecisionMarkerBaseline -SessionId $casSid -DecisionId 'cas' `
        -PayloadState 'present' -PayloadValue 'second' -SubmitState 'absent' -SubmitValue ''
    $kept = Get-CopilotDecisionMarkerBaseline -SessionId $casSid -Channel 'payload' `
        -Marker ([pscustomobject]@{ decisionId = 'cas' })
    $first -and $second -and $kept.Value -ceq 'first'
}
Test-That 'and a replacement question gets its own, rather than overwriting it' {
    [void](Set-CopilotDecisionMarkerBaseline -SessionId $casSid -DecisionId 'cas-next' `
        -PayloadState 'present' -PayloadValue 'next' -SubmitState 'absent' -SubmitValue '')
    $old = Get-CopilotDecisionMarkerBaseline -SessionId $casSid -Channel 'payload' -Marker ([pscustomobject]@{ decisionId = 'cas' })
    $new = Get-CopilotDecisionMarkerBaseline -SessionId $casSid -Channel 'payload' -Marker ([pscustomobject]@{ decisionId = 'cas-next' })
    $old.Value -ceq 'first' -and $new.Value -ceq 'next'
}
Test-That 'a baseline is never read against a question it was not recorded for' {
    (Get-CopilotDecisionMarkerBaseline -SessionId $casSid -Channel 'payload' `
        -Marker ([pscustomobject]@{ decisionId = 'never-armed' })).State -eq 'unknown'
}
Test-That 'a question with no id has no baseline, rather than sharing one' {
    (Set-CopilotDecisionMarkerBaseline -SessionId $casSid -DecisionId '' `
        -PayloadState 'absent' -PayloadValue '' -SubmitState 'absent' -SubmitValue '') -eq $false
}
Test-That 'nothing is readable without being told which session it belongs to' {
    (Get-CopilotDecisionMarkerBaseline -Marker ([pscustomobject]@{ decisionId = 'cas' }) -Channel 'payload').State -eq 'unknown'
}
Test-That 'retiring a question takes its own baseline with it' {
    Remove-CopilotDecisionMarker -SessionId $casSid -DecisionId 'cas'
    -not (Test-CopilotDecisionBaselineRecorded -SessionId $casSid -DecisionId 'cas')
}
# A replacement question may already have been armed and recorded its own. Sweeping
# every baseline for the session would delete it, and the new question would then
# adopt whatever the card happens to hold as "what was always there" - losing an
# answer typed in between.
Test-That 'and leaves a replacement question''s baseline alone' {
    Test-CopilotDecisionBaselineRecorded -SessionId $casSid -DecisionId 'cas-next'
}
Test-That 'and another session''s alone' {
    Test-CopilotDecisionBaselineRecorded -SessionId $sid -DecisionId 'd4'
}
# A record that exists but cannot be read back is not a record. Because it is
# write-once, treating it as one would leave the question unanswerable for ever.
Test-That 'a half-written record is not a baseline, and is replaced rather than trusted' {
    $path = Get-CopilotDecisionBaselinePath -SessionId $casSid -DecisionId 'cas-torn'
    [IO.File]::WriteAllText($path, '{"decisionId":"cas-torn","payl')
    $before = Test-CopilotDecisionBaselineRecorded -SessionId $casSid -DecisionId 'cas-torn'
    $wrote = Set-CopilotDecisionMarkerBaseline -SessionId $casSid -DecisionId 'cas-torn' `
        -PayloadState 'absent' -PayloadValue '' -SubmitState 'absent' -SubmitValue ''
    -not $before -and $wrote -and (Test-CopilotDecisionBaselineRecorded -SessionId $casSid -DecisionId 'cas-torn')
}
Test-That 'a record naming a different question is never read against this one' {
    $path = Get-CopilotDecisionBaselinePath -SessionId $casSid -DecisionId 'cas-wrong'
    [IO.File]::WriteAllText($path, '{"decisionId":"somebody-else","payload":{"state":"absent","value":""},"submit":{"state":"absent","value":""}}')
    -not (Test-CopilotDecisionBaselineRecorded -SessionId $casSid -DecisionId 'cas-wrong')
}
# The value is half the record. A channel recorded as holding something, with nothing
# recorded, compares equal to an empty slot for ever - so a real answer arriving later
# never reads as a change, and the question waits for ever.
Test-That 'a record whose value does not match its state is not a baseline' {
    $bad = @(
        '{"decisionId":"cas-value","payload":{"state":"present"},"submit":{"state":"absent","value":""}}'
        '{"decisionId":"cas-value","payload":{"state":"present","value":""},"submit":{"state":"absent","value":""}}'
        '{"decisionId":"cas-value","payload":{"state":"present","value":null},"submit":{"state":"absent","value":""}}'
        '{"decisionId":"cas-value","payload":{"state":"absent","value":"something"},"submit":{"state":"absent","value":""}}'
        '{"decisionId":"cas-value","payload":{"state":"absent","value":""},"submit":{"state":"present"}}'
    )
    $path = Get-CopilotDecisionBaselinePath -SessionId $casSid -DecisionId 'cas-value'
    $accepted = @()
    foreach ($json in $bad) {
        [IO.File]::WriteAllText($path, $json)
        if (Test-CopilotDecisionBaselineRecorded -SessionId $casSid -DecisionId 'cas-value') { $accepted += $json }
    }
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    $accepted.Count -eq 0
}
Test-That 'and a complete one is' {
    $path = Get-CopilotDecisionBaselinePath -SessionId $casSid -DecisionId 'cas-good'
    [IO.File]::WriteAllText($path, '{"decisionId":"cas-good","payload":{"state":"present","value":"stamp"},"submit":{"state":"absent","value":""}}')
    Test-CopilotDecisionBaselineRecorded -SessionId $casSid -DecisionId 'cas-good'
}
# Retiring a whole session is the one case where no replacement question can exist, so
# it is the one case that may sweep everything - and it has to be asked for by name.
Test-That 'retiring a session clears every baseline it recorded' {
    [void](Set-CopilotDecisionMarkerBaseline -SessionId $casSid -DecisionId 'gone-a' `
        -PayloadState 'present' -PayloadValue 'a' -SubmitState 'absent' -SubmitValue '')
    [void](Set-CopilotDecisionMarkerBaseline -SessionId $casSid -DecisionId 'gone-b' `
        -PayloadState 'present' -PayloadValue 'b' -SubmitState 'absent' -SubmitValue '')
    Remove-CopilotDecisionMarker -SessionId $casSid -AllBaselines
    -not (Test-CopilotDecisionBaselineRecorded -SessionId $casSid -DecisionId 'gone-a') -and
    -not (Test-CopilotDecisionBaselineRecorded -SessionId $casSid -DecisionId 'gone-b')
}
Test-That 'and still leaves another session''s alone' {
    Test-CopilotDecisionBaselineRecorded -SessionId $sid -DecisionId 'd4'
}

# 'absent' and 'unknown' are not the same answer. A channel nobody could read must
# never compare as changed: a retained old payload becoming readable again would
# otherwise be taken for something freshly typed.
Test-That 'a channel that could not be read when armed never reads as changed' {
    -not (Test-DaemonChannelChanged `
        -Baseline ([pscustomobject]@{ State = 'unknown'; Value = '' }) `
        -Current ([pscustomobject]@{ State = 'present'; Value = 'something' }))
}
Test-That 'but one that was determinately empty does, once something arrives' {
    Test-DaemonChannelChanged `
        -Baseline ([pscustomobject]@{ State = 'absent'; Value = '' }) `
        -Current ([pscustomobject]@{ State = 'present'; Value = 'something' })
}
Test-That 'and a channel that has gone unreadable is not a change either' {
    -not (Test-DaemonChannelChanged `
        -Baseline ([pscustomobject]@{ State = 'present'; Value = 'old' }) `
        -Current ([pscustomobject]@{ State = 'unknown'; Value = '' }))
}
Test-That 'a button that is simply there and never pressed is not missing' {
    $script:Ha = @{ "button.${node}_x" = 'unknown' }
    $seen = Get-DaemonDecisionChannelState -EntityId "button.${node}_x" -Headers $headers
    $seen.State -eq 'absent' -and $seen.Exists
}
Test-That 'one that is not on the card at all is' {
    # Home Assistant's own answer for an entity it does not have, as a status rather than
# as wording: the bridge reads absence off the status code, never off a message.
function New-TestHaNotFound {
    param([Parameter(Mandatory)][string]$EntityId)
    $notFound = [InvalidOperationException]::new("Response status code does not indicate success: 404 (Not Found). [$EntityId]")
    $notFound.Data['BridgeHttpStatus'] = 404
    $notFound
}
$script:Ha = @{}
    $seen = Get-DaemonDecisionChannelState -EntityId "button.${node}_x" -Headers $headers
    $seen.State -eq 'absent' -and -not $seen.Exists
}
Test-That 'and one whose integration has not come back yet is neither' {
    $script:Ha = @{ "button.${node}_x" = 'unavailable' }
    $seen = Get-DaemonDecisionChannelState -EntityId "button.${node}_x" -Headers $headers
    $seen.State -eq 'unknown' -and $seen.Exists
}

Write-Host '--- a refused test-boundary operation is not a missing answer ---'
# Absorbing this would turn "a suite tried to reach a real Home Assistant" into a quiet
# "nothing has been answered", and the suite would pass for exactly the wrong reason.
function Get-HomeAssistantState { param([string]$EntityId, [hashtable]$Headers)
    $blocked = [InvalidOperationException]::new('A test suite tried to reach a real Home Assistant.')
    $blocked.Data['BridgeTestNetworkBlocked'] = $true
    throw $blocked
}
Test-That 'the card-text reader propagates a marked guard rather than returning empty' {
    $threw = $false
    try { [void](Read-DaemonDecisionCardText -SessionId $sid -Marker $stale -Headers $headers) }
    catch { $threw = [bool]$_.Exception.Data['BridgeTestNetworkBlocked'] }
    $threw
}
Test-That 'and so does the answer reader that encloses it' {
    $threw = $false
    try { [void](Read-DaemonDecisionAnswer -SessionId $sid -Marker $stale -State $state -Headers $headers) }
    catch { $threw = [bool]$_.Exception.Data['BridgeTestNetworkBlocked'] }
    $threw
}
# Wrapped, which is how it really arrives: the guard throws inside something that
# catches and rethrows with context, so only the outer exception carries no mark.
# Looking at that one alone turned a refused network call into a quiet "nothing has
# been answered" and the suite passed for exactly the wrong reason.
function Get-HomeAssistantState { param([string]$EntityId, [hashtable]$Headers)
    $blocked = [InvalidOperationException]::new('A test suite tried to reach a real Home Assistant.')
    $blocked.Data['BridgeTestNetworkBlocked'] = $true
    throw [InvalidOperationException]::new('could not read the card', $blocked)
}
Test-That 'a guard wrapped in an ordinary failure is still a guard, not an empty answer' {
    $threw = $false
    try { [void](Read-DaemonDecisionCardText -SessionId $sid -Marker $stale -Headers $headers) }
    catch { $threw = $null -ne $_.Exception.InnerException -and [bool]$_.Exception.InnerException.Data['BridgeTestNetworkBlocked'] }
    $threw
}
Test-That 'and the Send check refuses rather than reading an unreadable button as unpressed' {
    $threw = $false
    try { [void](Test-DaemonSendPressed -SessionId $sid -Marker $stale -Headers $headers) }
    catch { $threw = $null -ne $_.Exception.InnerException -and [bool]$_.Exception.InnerException.Data['BridgeTestNetworkBlocked'] }
    $threw
}
Test-That 'and so does establishing a baseline, rather than recording one nobody could read' {
    $threw = $false
    $unseen = [pscustomobject]@{ mode = 'freeform'; decisionId = 'd-guard'; question = 'Why?'; fields = @(); choices = @() }
    try { [void](Confirm-DaemonDecisionBaseline -SessionId $sid -Marker $unseen -Headers $headers) }
    catch { $threw = $null -ne $_.Exception.InnerException -and [bool]$_.Exception.InnerException.Data['BridgeTestNetworkBlocked'] }
    $threw
}
function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    if (-not $script:Ha.ContainsKey($EntityId)) { throw (New-TestHaNotFound -EntityId $EntityId) }
    $v = $script:Ha[$EntityId]
    if ($v -is [pscustomobject]) { return $v }
    [pscustomobject]@{ state = [string]$v; attributes = [pscustomobject]@{ question = 'Pick' } }
}

Write-Host '--- one attempt at a question, and never a second ---'
# Typing into the console and recording "answered" are two writes. A daemon that stops
# between them leaves a marker saying nothing happened while the terminal may already
# have the answer, and the next pass used to read the card and type it again.
$attemptSid = '11111111-0000-4000-8000-0000000000a7'
Test-That 'claiming is the file''s creation, so only the first claim wins' {
    $first = New-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a1' -Answer 'Yes'
    $second = New-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a1' -Answer 'No'
    $kept = Get-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a1'
    $first -and -not $second -and [string]$kept.answer -ceq 'Yes' -and [string]$kept.state -ceq 'claimed'
}
Test-That 'a claim on its own does not settle the question, because nothing was typed' {
    -not (Test-CopilotDecisionAttemptSettled -SessionId $attemptSid -DecisionId 'a1').Settled
}
Test-That 'once it is being typed the question is settled, and says why' {
    [void](Set-CopilotDecisionAttemptState -SessionId $attemptSid -DecisionId 'a1' -State 'injecting')
    $s = Test-CopilotDecisionAttemptSettled -SessionId $attemptSid -DecisionId 'a1'
    $s.Settled -and $s.State -ceq 'injecting' -and $s.Reason -match 'did not finish'
}
# This is the crash: stopped after the keys began and before anything was recorded.
Test-That 'a question left mid-typing is never released for another go' {
    $null -eq (Set-CopilotDecisionAttemptState -SessionId $attemptSid -DecisionId 'a1' -State 'rejected') -and
    (Test-CopilotDecisionAttemptSettled -SessionId $attemptSid -DecisionId 'a1').Settled
}
Test-That 'but it can be resolved either way' {
    $null -ne (Set-CopilotDecisionAttemptState -SessionId $attemptSid -DecisionId 'a1' -State 'unknown') -and
    (Test-CopilotDecisionAttemptSettled -SessionId $attemptSid -DecisionId 'a1').Reason -match 'may already have reached'
}
Test-That 'and once it is unknown it stays unknown rather than being retried' {
    $null -eq (Set-CopilotDecisionAttemptState -SessionId $attemptSid -DecisionId 'a1' -State 'injecting') -and
    $null -eq (Set-CopilotDecisionAttemptState -SessionId $attemptSid -DecisionId 'a1' -State 'rejected')
}
Test-That 'a failure that never reached the keyboard leaves the question answerable' {
    [void](New-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a2' -Answer 'Yes')
    $null -ne (Set-CopilotDecisionAttemptState -SessionId $attemptSid -DecisionId 'a2' -State 'rejected') -and
    -not (Test-CopilotDecisionAttemptSettled -SessionId $attemptSid -DecisionId 'a2').Settled
}
Test-That 'a delivered question is settled' {
    [void](New-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a3' -Answer 'Yes')
    [void](Set-CopilotDecisionAttemptState -SessionId $attemptSid -DecisionId 'a3' -State 'injecting')
    [void](Set-CopilotDecisionAttemptState -SessionId $attemptSid -DecisionId 'a3' -State 'delivered')
    (Test-CopilotDecisionAttemptSettled -SessionId $attemptSid -DecisionId 'a3').Reason -match 'already been answered'
}
Test-That 'a question nobody has attempted is not settled' {
    -not (Test-CopilotDecisionAttemptSettled -SessionId $attemptSid -DecisionId 'never').Settled
}
Test-That 'releasing from mid-typing needs the injector''s own word that nothing was written' {
    [void](New-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a7' -Answer 'Yes')
    [void](Set-CopilotDecisionAttemptState -SessionId $attemptSid -DecisionId 'a7' -State 'injecting')
    $null -eq (Set-CopilotDecisionAttemptState -SessionId $attemptSid -DecisionId 'a7' -State 'rejected') -and
    $null -ne (Set-CopilotDecisionAttemptState -SessionId $attemptSid -DecisionId 'a7' -State 'rejected' -NothingWritten)
}
Test-That 'the barrier hands back the claim''s own answer, not the caller''s' {
    [void](New-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a8' -Answer 'what was claimed' -Selections @('#1'))
    $started = Start-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a8'
    $started.Started -and $started.Answer -ceq 'what was claimed' -and (@($started.Selections) -join '|') -eq '#1'
}
Test-That 'and a second pass cannot win the barrier behind the first' {
    (Start-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a8').Started -eq $false
}
# A rejection says nothing was typed, so the question is answerable again - but the
# record is exactly what stops that, since no new claim can be made while one exists
# and the barrier only ever moves a claim to injecting. Left behind by a daemon that
# stopped before deleting it, or by the rejection taken when a claimed question turns
# out to have changed, it made the question permanently unanswerable in silence.
Test-That 'a rejected record left behind blocks the barrier, which is why it is released' {
    [void](New-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a9' -Answer 'Yes')
    [void](Set-CopilotDecisionAttemptState -SessionId $attemptSid -DecisionId 'a9' -State 'rejected')
    (Start-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a9').Started -eq $false
}
Test-That 'releasing it lets the question be claimed and answered again' {
    (Remove-CopilotDecisionRejectedAttempt -SessionId $attemptSid -DecisionId 'a9') -and
    $null -eq (Get-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a9') -and
    (New-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a9' -Answer 'No') -and
    (Start-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a9').Answer -ceq 'No'
}
Test-That 'but a claim somebody may be acting on is never released' {
    [void](New-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a10' -Answer 'Yes')
    -not (Remove-CopilotDecisionRejectedAttempt -SessionId $attemptSid -DecisionId 'a10') -and
    $null -ne (Get-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a10')
}
Test-That 'nor is one whose answer may already have reached the terminal' {
    [void](Set-CopilotDecisionAttemptState -SessionId $attemptSid -DecisionId 'a10' -State 'injecting')
    [void](Set-CopilotDecisionAttemptState -SessionId $attemptSid -DecisionId 'a10' -State 'unknown')
    -not (Remove-CopilotDecisionRejectedAttempt -SessionId $attemptSid -DecisionId 'a10') -and
    (Test-CopilotDecisionAttemptSettled -SessionId $attemptSid -DecisionId 'a10').Settled
}
Test-That 'and a question with no record at all needs no releasing' {
    Remove-CopilotDecisionRejectedAttempt -SessionId $attemptSid -DecisionId 'a11'
}

Write-Host '--- the dispatcher itself, against a ledger on disk ---'
# Not the helpers in isolation: the thing that decides whether keys are typed is
# Invoke-DaemonDecisionAnswer, and every hole found in review was in how it used them
# rather than in what they did.
$dispSid = '11111111-0000-4000-8000-0000000000d1'
$script:Typed = [Collections.Generic.List[object]]::new()
$script:Outcome = @{ Delivered = $true; Detail = 'ok:form'; Wrote = $true }
function Send-CopilotSessionForm { param($SessionId, $Fields, $Selections, $ProcessId)
    $script:Typed.Add([pscustomobject]@{ Route = 'form'; Selections = @($Selections) })
    [pscustomobject]@{ Delivered = $script:Outcome.Delivered; ProcessId = 42; Detail = $script:Outcome.Detail; Wrote = $script:Outcome.Wrote }
}
function Send-CopilotSessionChoice { param($SessionId, $Text, $ChoiceCount, $ProcessId)
    $script:Typed.Add([pscustomobject]@{ Route = 'choice'; Text = $Text })
    [pscustomobject]@{ Delivered = $script:Outcome.Delivered; ProcessId = 42; Detail = $script:Outcome.Detail; Wrote = $script:Outcome.Wrote }
}
function Send-CopilotSessionPrompt { param($SessionId, $Text, $ProcessId)
    $script:Typed.Add([pscustomobject]@{ Route = 'prompt'; Text = $Text })
    [pscustomobject]@{ Delivered = $script:Outcome.Delivered; ProcessId = 42; Detail = $script:Outcome.Detail; Wrote = $script:Outcome.Wrote }
}
function Get-DaemonSessionProcessId { param($SessionId) 42 }
function Complete-DaemonClaudeAnswer { param($SessionId, $Delivery, $Marker) $Delivery }
function Set-CopilotDecisionMarkerInjected { param($SessionId, $Answer, $Selections) }
$dispMarker = [pscustomobject]@{
    decisionId = 'disp1'; mode = 'multiple_choice'; choices = @(); fields = @(
        [pscustomobject]@{ Label = 'F'; Options = @('Auth', 'Billing'); IsText = $false })
}
# The record may legitimately be gone - a released question has none - so reading it
# for a failure message must not itself throw under StrictMode.
function Get-DispState {
    $a = Get-CopilotDecisionAttempt -SessionId $dispSid -DecisionId 'disp1'
    if ($null -eq $a) { '<no attempt>' } else { [string]$a.state }
}
function Invoke-Dispatch { param([string]$Answer = 'Auth', [string[]]$Sel = @('Auth'))
    Invoke-DaemonDecisionAnswer -SessionId $dispSid -Marker $dispMarker -Answer $Answer `
        -IsChoice $true -Selections $Sel -State @{} -Headers $headers
}

$script:Ha = @{}
Test-That 'a clean answer is typed once and the attempt records that it landed' {
    $script:Typed.Clear()
    $ok = Invoke-Dispatch
    $a = Get-CopilotDecisionAttempt -SessionId $dispSid -DecisionId 'disp1'
    $ok -and $script:Typed.Count -eq 1 -and [string]$a.state -ceq 'delivered'
} "typed=$($script:Typed.Count) state=$(Get-DispState)"
Test-That 'and asking again types nothing at all' {
    $script:Typed.Clear()
    $again = Invoke-Dispatch
    -not $again -and $script:Typed.Count -eq 0
} "typed=$($script:Typed.Count)"

# The crash: a record left mid-typing by a daemon that stopped.
Remove-CopilotDecisionMarker -SessionId $dispSid -DecisionId 'disp1'
[void](New-CopilotDecisionAttempt -SessionId $dispSid -DecisionId 'disp1' -Answer 'Auth' -Selections @('Auth') `
    -IsChoice $true -FieldShape (Get-CopilotDecisionFieldShape -Fields @($dispMarker.fields)))
[void](Set-CopilotDecisionAttemptState -SessionId $dispSid -DecisionId 'disp1' -State 'injecting')
Test-That 'a question left mid-typing by a stopped daemon is never typed at again' {
    $script:Typed.Clear()
    $r = Invoke-Dispatch
    -not $r -and $script:Typed.Count -eq 0
} "typed=$($script:Typed.Count)"
Test-That 'and the card says it was already answered rather than going quiet' {
    $script:Transient -contains 'Answer NOT sent'
} ($script:Transient -join '|')

# A claim left behind without keys: the next pass must type what was CLAIMED.
Remove-CopilotDecisionMarker -SessionId $dispSid -DecisionId 'disp1'
[void](New-CopilotDecisionAttempt -SessionId $dispSid -DecisionId 'disp1' -Answer 'Billing' -Selections @('Billing') `
    -IsChoice $true -FieldShape (Get-CopilotDecisionFieldShape -Fields @($dispMarker.fields)))
Test-That 'a claim left without keys is honoured, and its own answer is the one typed' {
    $script:Typed.Clear()
    [void](Invoke-Dispatch -Answer 'Auth' -Sel @('Auth'))
    $script:Typed.Count -eq 1 -and (@($script:Typed[0].Selections) -join '|') -eq 'Billing'
} "typed=[$(@($script:Typed | ForEach-Object { @($_.Selections) -join ',' }) -join '|')]"

# A failure that reached the keyboard must not release the question.
Remove-CopilotDecisionMarker -SessionId $dispSid -DecisionId 'disp1'
$script:Outcome = @{ Delivered = $false; Detail = 'no live process for session'; Wrote = $true }
Test-That 'a failure that wrote something leaves the question settled, whatever the failure says' {
    $script:Typed.Clear()
    [void](Invoke-Dispatch)
    $a = Get-CopilotDecisionAttempt -SessionId $dispSid -DecisionId 'disp1'
    [string]$a.state -ceq 'unknown' -and (Test-CopilotDecisionAttemptSettled -SessionId $dispSid -DecisionId 'disp1').Settled
} "state=$(Get-DispState)"
Test-That 'and it is not typed at again on the next pass' {
    $script:Typed.Clear()
    [void](Invoke-Dispatch)
    $script:Typed.Count -eq 0
} "typed=$($script:Typed.Count)"

# A failure that never reached the keyboard stays retryable, as it is today.
Remove-CopilotDecisionMarker -SessionId $dispSid -DecisionId 'disp1'
$script:Outcome = @{ Delivered = $false; Detail = 'no live process for session'; Wrote = $false }
Test-That 'a failure that wrote nothing releases the question for another go' {
    $script:Typed.Clear()
    [void](Invoke-Dispatch)
    # Two routes, because a form that never wrote still falls back to the text one.
    $null -eq (Get-CopilotDecisionAttempt -SessionId $dispSid -DecisionId 'disp1') -and $script:Typed.Count -eq 2
} "state=$(Get-DispState)"
Test-That 'and the next pass really does try again' {
    $script:Typed.Clear()
    [void](Invoke-Dispatch)
    $script:Typed.Count -eq 2
} "state=$(Get-DispState)"

# The same rejection, but the record outlived it - a daemon that stopped between the
# transition and the delete, or a delete that failed. The question was answerable and
# nothing had been typed, yet nothing could ever claim it again: the barrier only moves
# a claim to injecting, so every later pass lost it in silence.
Remove-CopilotDecisionMarker -SessionId $dispSid -DecisionId 'disp1'
$script:Outcome = @{ Delivered = $true; Detail = 'ok:form'; Wrote = $true }
[void](New-CopilotDecisionAttempt -SessionId $dispSid -DecisionId 'disp1' -Answer 'Auth' -Selections @('Auth') `
    -IsChoice $true -FieldShape (Get-CopilotDecisionFieldShape -Fields @($dispMarker.fields)))
[void](Set-CopilotDecisionAttemptState -SessionId $dispSid -DecisionId 'disp1' -State 'rejected')
Test-That 'a rejected record left behind does not strand the question for ever' {
    $script:Typed.Clear()
    $r = Invoke-Dispatch -Answer 'Billing' -Sel @('Billing')
    $r -and $script:Typed.Count -eq 1
} "typed=$($script:Typed.Count) state=$(Get-DispState)"
Test-That 'and what it types is the answer on the card now, not the rejected one' {
    (@($script:Typed[0].Selections) -join '|') -eq 'Billing'
} "typed=[$(@($script:Typed | ForEach-Object { @($_.Selections) -join ',' }) -join '|')]"

# The partial form: it wrote, it failed, and the text route must not type on top.
Remove-CopilotDecisionMarker -SessionId $dispSid -DecisionId 'disp1'
$script:Outcome = @{ Delivered = $false; Detail = 'field0:write-failed'; Wrote = $true }
Test-That 'a form that failed after writing does not fall back and type a second answer' {
    $script:Typed.Clear()
    [void](Invoke-Dispatch)
    $script:Typed.Count -eq 1 -and $script:Typed[0].Route -ceq 'form'
} "routes=[$(@($script:Typed | ForEach-Object { $_.Route }) -join '|')]"
Test-That 'and the uncertainty it created is kept' {
    (Get-DispState) -ceq 'unknown'
}
# But a form that never wrote still falls back, which is how a mixed form is answered.
Remove-CopilotDecisionMarker -SessionId $dispSid -DecisionId 'disp1'
$script:Outcome = @{ Delivered = $false; Detail = 'field/selection mismatch (1/0)'; Wrote = $false }
Test-That 'a form that never wrote still falls back to the text route' {
    $script:Typed.Clear()
    [void](Invoke-Dispatch)
    (@($script:Typed | ForEach-Object { $_.Route }) -join '|') -eq 'form|choice'
} "routes=[$(@($script:Typed | ForEach-Object { $_.Route }) -join '|')]"

Remove-CopilotDecisionMarker -SessionId $dispSid -DecisionId 'disp1'
$script:Outcome = @{ Delivered = $true; Detail = 'ok:form'; Wrote = $true }
Test-That 'a question with no id is never typed at, rather than slipping past unprotected' {
    $script:Typed.Clear()
    $noId = [pscustomobject]@{ decisionId = ''; mode = 'multiple_choice'; choices = @(); fields = @($dispMarker.fields) }
    $r = Invoke-DaemonDecisionAnswer -SessionId $dispSid -Marker $noId -Answer 'Auth' `
        -IsChoice $true -Selections @('Auth') -State @{} -Headers $headers
    -not $r -and $script:Typed.Count -eq 0
} "typed=$($script:Typed.Count)"

# A claim is a whole execution, not a set of words. Resuming one with another call's
# context would type the claimed answer down a route the claim never chose, or mark a
# publish spent that it never used.
Remove-CopilotDecisionMarker -SessionId $dispSid -DecisionId 'disp1'
Test-That 'a claim carries the route and the publish it was made for, not just the words' {
    [void](New-CopilotDecisionAttempt -SessionId $dispSid -DecisionId 'disp1' -Answer 'typed words' `
        -Selections @() -IsChoice $true -IsFreeText $true -PayloadStamp 'stamp-A' `
        -FieldShape (Get-CopilotDecisionFieldShape -Fields @($dispMarker.fields)))
    $script:Typed.Clear()
    # The caller arrives with a different route and a different publish entirely.
    [void](Invoke-DaemonDecisionAnswer -SessionId $dispSid -Marker $dispMarker -Answer 'Auth' `
        -IsChoice $true -IsFreeText $false -Selections @('Auth') -PayloadStamp 'stamp-B' `
        -State @{} -Headers $headers)
    # It must do what the claim said: the typed-words route, with the claim's words.
    $script:Typed.Count -eq 1 -and $script:Typed[0].Route -ceq 'choice' -and $script:Typed[0].Text -ceq 'typed words'
} "typed=[$(@($script:Typed | ForEach-Object { "$($_.Route):$($_.Text)" }) -join '|')]"

Remove-CopilotDecisionMarker -SessionId $dispSid -DecisionId 'disp1'
Test-That 'a claim made against different fields is refused rather than walked' {
    $otherShape = [pscustomobject]@{ decisionId = 'disp1'; mode = 'multiple_choice'; choices = @(); fields = @(
        [pscustomobject]@{ Label = 'Different'; Options = @('X', 'Y'); IsText = $false }) }
    [void](New-CopilotDecisionAttempt -SessionId $dispSid -DecisionId 'disp1' -Answer 'X' `
        -Selections @('X') -IsChoice $true -FieldShape (Get-CopilotDecisionFieldShape -Fields @($otherShape.fields)))
    $script:Typed.Clear()
    $r = Invoke-Dispatch
    -not $r -and $script:Typed.Count -eq 0
} "typed=$($script:Typed.Count)"
Test-That 'and that refusal releases it, because nothing was typed' {
    $null -eq (Get-CopilotDecisionAttempt -SessionId $dispSid -DecisionId 'disp1') -or
    (Get-DispState) -ceq 'rejected'
} "state=$(Get-DispState)"

Write-Host '--- the barrier returns the record it changed, not one read beforehand ---'
# Reading the claim first and acting on that is a different record if the claim is
# replaced in between: the transition would move the NEW claim to injecting while the
# caller typed the OLD claim's answer, so the ledger and the keyboard would disagree.
Test-That 'the barrier hands back the record its own transition wrote' {
    $abaSid = '11111111-0000-4000-8000-0000000000ba'
    [void](New-CopilotDecisionAttempt -SessionId $abaSid -DecisionId 'aba' -Answer 'the claim that was there' -Selections @('#1'))
    $started = Start-CopilotDecisionAttempt -SessionId $abaSid -DecisionId 'aba'
    $after = Get-CopilotDecisionAttempt -SessionId $abaSid -DecisionId 'aba'
    # What came back and what is on disk are the same record, in the same state.
    $started.Started -and $started.Answer -ceq [string]$after.answer -and [string]$after.state -ceq 'injecting'
}
Test-That 'and a replaced claim is answered with its own words, never the previous one''s' {
    $abaSid = '11111111-0000-4000-8000-0000000000bb'
    [void](New-CopilotDecisionAttempt -SessionId $abaSid -DecisionId 'aba' -Answer 'first claim')
    # Replaced between a read and a transition, which is the window that mattered.
    Remove-Item -LiteralPath (Get-CopilotDecisionAttemptPath -SessionId $abaSid -DecisionId 'aba') -Force
    [void](New-CopilotDecisionAttempt -SessionId $abaSid -DecisionId 'aba' -Answer 'second claim')
    (Start-CopilotDecisionAttempt -SessionId $abaSid -DecisionId 'aba').Answer -ceq 'second claim'
}

Write-Host '--- the real senders say whether they reached the keyboard ---'
# The dispatcher decides whether a question may be answered again on this one fact, so
# it is checked against the actual senders rather than against stubs of them. They were
# stubbed above for the dispatcher tests, so the real ones are loaded back first - the
# file declares no parameters, so dot-sourcing it rebinds nothing.
. (Join-Path $PSScriptRoot '..\hooks\decision-inject.ps1')
$script:ConsoleWrites = 0
function Invoke-BridgeConsoleSend { param($ProcessId, $Text, $Submit, $DelayMs) $script:ConsoleWrites++; 'ok:sent' }
function Invoke-BridgeConsoleChoice { param($ProcessId, $DownCount, $Text, $StepDelayMs) $script:ConsoleWrites++; 'ok:choice' }
function Get-CopilotSessionProcessId { param($SessionId) 4242 }
Test-That 'a prompt that reaches the console says it wrote' {
    $script:ConsoleWrites = 0
    $d = Send-CopilotSessionPrompt -SessionId $sid -Text 'hello' -ProcessId 4242
    $d.Wrote -and $d.Delivered -and $script:ConsoleWrites -eq 1
} "writes=$($script:ConsoleWrites)"
Test-That 'and one refused before the console says it did not' {
    $script:ConsoleWrites = 0
    $d = Send-CopilotSessionPrompt -SessionId $sid -Text '   ' -ProcessId 4242
    -not $d.Wrote -and -not $d.Delivered -and $script:ConsoleWrites -eq 0
}
Test-That 'a choice that reaches the console says it wrote' {
    $script:ConsoleWrites = 0
    $d = Send-CopilotSessionChoice -SessionId $sid -Text 'other words' -ChoiceCount 2 -ProcessId 4242
    $d.Wrote -and $script:ConsoleWrites -eq 1
}
Test-That 'a form that reaches the console says it wrote' {
    $script:ConsoleWrites = 0
    $f = @([pscustomobject]@{ Label = 'F'; Options = @('A', 'B'); IsText = $false })
    $d = Send-CopilotSessionForm -SessionId $sid -Fields $f -Selections @('B') -ProcessId 4242
    $d.Wrote -and $script:ConsoleWrites -ge 1
} "writes=$($script:ConsoleWrites)"
Test-That 'and a form refused before the console says it did not' {
    # One field, no selection for it: the mismatch the sender refuses before writing.
    $script:ConsoleWrites = 0
    $f = @(
        [pscustomobject]@{ Label = 'F'; Options = @('A', 'B'); IsText = $false }
        [pscustomobject]@{ Label = 'G'; Options = @('C', 'D'); IsText = $false })
    $d = Send-CopilotSessionForm -SessionId $sid -Fields $f -Selections @('B') -ProcessId 4242
    -not $d.Wrote -and -not $d.Delivered -and $script:ConsoleWrites -eq 0
} "detail=$((Send-CopilotSessionForm -SessionId $sid -Fields @([pscustomobject]@{ Label='F'; Options=@('A','B'); IsText=$false }, [pscustomobject]@{ Label='G'; Options=@('C','D'); IsText=$false }) -Selections @('B') -ProcessId 4242).Detail)"

# A failure with a live target pid used to read as written whatever it was, so a console
# that could not even be attached settled the attempt as 'unknown' and the question was
# never retried, though nothing had been typed. Only the outcomes a transport returns
# ahead of its first write may say otherwise; a failure part-way still reads as written.
foreach ($before in 'attach-failed:1341', 'conin-failed:5', 'init-failed:compile', 'no-tmux', 'not-in-tmux') {
    $script:SendOutcome = $before
    function Invoke-BridgeConsoleSend { param($ProcessId, $Text, $Submit, $DelayMs) $script:ConsoleWrites++; $script:SendOutcome }
    function Invoke-BridgeConsoleChoice { param($ProcessId, $DownCount, $Text, $StepDelayMs) $script:ConsoleWrites++; $script:SendOutcome }
    Test-That "a prompt that failed with $before says nothing was written" {
        $d = Send-CopilotSessionPrompt -SessionId $sid -Text 'hello' -ProcessId 4242
        -not $d.Wrote -and -not $d.Delivered
    }
    Test-That "and so does a choice, and the first write of a form" {
        $c = Send-CopilotSessionChoice -SessionId $sid -Text 'other words' -ChoiceCount 2 -ProcessId 4242
        $f = Send-CopilotSessionForm -SessionId $sid -ProcessId 4242 `
            -Fields @([pscustomobject]@{ Label = 'F'; Options = @('A', 'B'); IsText = $false }) -Selections @('B')
        -not $c.Wrote -and -not $f.Wrote
    }
}
foreach ($midway in 'write-failed:6', 'partial:3/10', 'enter-failed:6', 'down-failed:6') {
    $script:SendOutcome = $midway
    Test-That "a prompt that failed with $midway still says it may have written" {
        (Send-CopilotSessionPrompt -SessionId $sid -Text 'hello' -ProcessId 4242).Wrote
    }
}
$script:FormSends = 0
Test-That 'a form whose later field could not attach still says it wrote, because the earlier one landed' {
    $script:FormSends = 0
    function Invoke-BridgeConsoleSend {
        param($ProcessId, $Text, $Submit, $DelayMs)
        $script:FormSends++
        if ($script:FormSends -eq 1) { 'ok:sent' } else { 'attach-failed:1341' }
    }
    $f = @(
        [pscustomobject]@{ Label = 'F'; Options = @('A', 'B'); IsText = $false }
        [pscustomobject]@{ Label = 'G'; Options = @('C', 'D'); IsText = $false })
    $d = Send-CopilotSessionForm -SessionId $sid -Fields $f -Selections @('B', 'D') -ProcessId 4242
    $d.Wrote -and -not $d.Delivered -and $script:FormSends -eq 2
} "sends=$($script:FormSends)"
Test-That 'an exception from the transport still reads as possibly written' {
    function Invoke-BridgeConsoleSend { param($ProcessId, $Text, $Submit, $DelayMs) throw 'console went away' }
    $d = Send-CopilotSessionPrompt -SessionId $sid -Text 'hello' -ProcessId 4242
    $d.Wrote -and -not $d.Delivered
}
function Invoke-BridgeConsoleSend { param($ProcessId, $Text, $Submit, $DelayMs) $script:ConsoleWrites++; 'ok:sent' }
function Invoke-BridgeConsoleChoice { param($ProcessId, $DownCount, $Text, $StepDelayMs) $script:ConsoleWrites++; 'ok:choice' }

# A transition used to truncate the record and rewrite it through the same handle, so a
# daemon killed between the two left the only record of the attempt empty - unreadable,
# never answerable again, and not recreatable because the file still existed. It is now
# staged and renamed into place under a lock beside the record.
Test-That 'a transition replaces the record whole, and leaves nothing beside it' {
    [void](New-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'atomic1' -Answer 'Yes')
    $path = Get-CopilotDecisionAttemptPath -SessionId $attemptSid -DecisionId 'atomic1'
    $moved = Set-CopilotDecisionAttemptState -SessionId $attemptSid -DecisionId 'atomic1' -State 'injecting'
    # Not -Filter "<name>.*": on Windows that pattern matches the record's own name too.
    $leaf = Split-Path $path -Leaf
    $left = @(Get-ChildItem -LiteralPath (Split-Path $path -Parent) | Where-Object { $_.Name -ne $leaf -and $_.Name.StartsWith("$leaf.") })
    $null -ne $moved -and [string](Get-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'atomic1').state -ceq 'injecting' -and $left.Count -eq 0
}

Test-That 'a caller that cannot take the lock loses the transition, and the record is untouched' {
    [void](New-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'atomic2' -Answer 'Yes')
    $path = Get-CopilotDecisionAttemptPath -SessionId $attemptSid -DecisionId 'atomic2'
    $before = [IO.File]::ReadAllText($path)
    $held = [IO.FileStream]::new("$path.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 1, [IO.FileOptions]::DeleteOnClose)
    try { $moved = Set-CopilotDecisionAttemptState -SessionId $attemptSid -DecisionId 'atomic2' -State 'injecting' }
    finally { $held.Dispose() }
    $null -eq $moved -and [IO.File]::ReadAllText($path) -ceq $before
}
Test-That 'and once the lock is free the same transition goes through' {
    $null -ne (Set-CopilotDecisionAttemptState -SessionId $attemptSid -DecisionId 'atomic2' -State 'injecting')
}
Test-That 'the record on disk is always a complete record' {
    $path = Get-CopilotDecisionAttemptPath -SessionId $attemptSid -DecisionId 'atomic2'
    [void](Set-CopilotDecisionAttemptState -SessionId $attemptSid -DecisionId 'atomic2' -State 'delivered' -Detail ('x' * 10))
    $null -ne (ConvertFrom-Json ([IO.File]::ReadAllText($path)))
}

Test-That 'an attempt is never read against a different question' {
    $path = Get-CopilotDecisionAttemptPath -SessionId $attemptSid -DecisionId 'a4'
    [IO.File]::WriteAllText($path, '{"decisionId":"somebody-else","state":"injecting"}')
    $null -eq (Get-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a4') -and
    -not (Test-CopilotDecisionAttemptSettled -SessionId $attemptSid -DecisionId 'a4').Settled
}
Test-That 'retiring a question takes its attempt with it, so the next one starts clean' {
    [void](New-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a5' -Answer 'Yes')
    [void](Set-CopilotDecisionAttemptState -SessionId $attemptSid -DecisionId 'a5' -State 'injecting')
    Remove-CopilotDecisionMarker -SessionId $attemptSid -DecisionId 'a5'
    $null -eq (Get-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a5')
}
Test-That 'and retiring the session takes every attempt it left' {
    [void](New-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a6' -Answer 'Yes')
    Remove-CopilotDecisionMarker -SessionId $attemptSid -AllBaselines
    $null -eq (Get-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a6') -and
    $null -eq (Get-CopilotDecisionAttempt -SessionId $attemptSid -DecisionId 'a3')
}

Write-Host '--- one pass over the pending questions ---'
$script:Injected = @(); $script:Cleared = @(); $script:Removed = @()
$script:Marker = $null
$script:Ask = @{ Started = $true; Pending = $true }
function Get-CopilotDecisionMarker { param($SessionId) $script:Marker }
function Get-DaemonAskUserState { param($Session, $Marker) [pscustomobject]@{ Started = $script:Ask.Started; Pending = $script:Ask.Pending; ResultContent = '' } }
function Invoke-DaemonDecisionAnswer { param($SessionId, $Marker, $Answer, $IsChoice, $IsFreeText, $Selections, $PayloadStamp, $State, $Headers) $script:Injected += $Answer; $true }
function Clear-CopilotMqttDecision { param($SessionId, $SessionName, $Machine, $Headers) $script:Cleared += $SessionId; 'emitted' }
function Invoke-HomeAssistantService { param($Domain, $Service, $Headers, $Data) }
function Remove-CopilotDecisionMarker { param($SessionId) $script:Removed += $SessionId }
function Set-CopilotMqttDecision { param($SessionId, $SessionName, $Machine, $Question, $Choices, $Fields, $DecisionId, $Headers) $script:Rearmed = $true }
$live = @{ $sid = [pscustomobject]@{ SessionId = $sid } }

$script:Marker = $choice
# With the Send press on the card, because nothing is answered without one now.
$script:Ha = @{
    "select.${node}_decision" = 'No'
    "button.${node}_submit" = $armedAt.AddMinutes(1).ToString('o')
}
Invoke-PendingDecisions -Headers $headers -State $state -Live $live
Test-That 'a pending question with an answer on its card is answered' { ($script:Injected -join ',') -eq 'No' }

$script:Injected = @()
$script:Ha = @{ "select.${node}_decision" = 'No' }
Invoke-PendingDecisions -Headers $headers -State $state -Live $live
Test-That 'the same answer with no Send behind it is not injected' { $script:Injected.Count -eq 0 }

$script:Injected = @()
$script:Ha = @{
    "select.${node}_decision" = 'No'
    "button.${node}_submit" = $armedAt.AddMinutes(1).ToString('o')
}
$script:Marker = [pscustomobject]@{ mode = 'multiple_choice'; decisionId = 'd2'; question = 'Pick'; fields = @(); choices = @('Yes', 'No'); injectedAnswer = 'No' }
Invoke-PendingDecisions -Headers $headers -State $state -Live $live
Test-That 'an answer already sent is not sent again' { $script:Injected.Count -eq 0 }

$script:Marker = $choice
$script:Ask = @{ Started = $false; Pending = $true }
Invoke-PendingDecisions -Headers $headers -State $state -Live $live
Test-That 'nothing is sent before the question has started' { $script:Injected.Count -eq 0 }

$script:Ask = @{ Started = $true; Pending = $true }
$script:Marker = [pscustomobject]@{ mode = 'form'; decisionId = 'd4'; question = 'Big'; fields = @(); choices = @(); terminalOnly = $true; injectedAnswer = '' }
Invoke-PendingDecisions -Headers $headers -State $state -Live $live
Test-That 'a question only the terminal can answer is never typed into' { $script:Injected.Count -eq 0 }

$script:Marker = $choice
$script:Ha = @{ "select.${node}_decision" = [pscustomobject]@{ state = 'Idle'; attributes = [pscustomobject]@{ question = '' } } }
$script:Rearmed = $false
Invoke-PendingDecisions -Headers $headers -State $state -Live $live
Test-That 'a card the hook could not arm is armed from the marker' { $script:Rearmed }

$script:Ask = @{ Started = $true; Pending = $false }
Invoke-PendingDecisions -Headers $headers -State $state -Live $live
Test-That 'an answered question has its card cleared and its marker removed' { $script:Cleared -contains $sid -and $script:Removed -contains $sid }

Write-Host ''
Write-Host '--- re-arming a card from its marker, when the card is idle ---'
# Confirm-DaemonDecisionArmed exists to notice a card that is not armed and arm it from
# the marker, for a question whose hook could not reach Home Assistant. It decided that
# by reading the selector's `question` attribute - but an idle selector has no such
# attribute, and reading a missing property throws under StrictMode. So the read threw,
# the catch logged "marker re-arm check failed", and the one case the function exists
# for was the one it never handled. The fixtures above all supply a question attribute,
# which is more generous than Home Assistant is.
$script:Rearmed = $false
$script:RearmLog = @()
function Set-CopilotMqttDecision { param($SessionId, $SessionName, $Machine, $Question, $Choices, $Fields, $DecisionId, $Headers) $script:Rearmed = $true; 'shown' }
function Write-DaemonLog { param([string]$Message) $script:RearmLog += $Message }
$rearmState = @{ $sid = [pscustomobject]@{ Name = 'Copilot: x'; Machine = 'M' } }
$rearmMarker = [pscustomobject]@{ question = 'Which branch?'; choices = @('a', 'b'); fields = @(); decisionId = 'd9' }

$script:Ha = @{ "select.${node}_decision" = [pscustomobject]@{ state = 'Idle'; attributes = [pscustomobject]@{ options = @('Idle'); friendly_name = 'Decision' } } }
Confirm-DaemonDecisionArmed -SessionId $sid -Marker $rearmMarker -State $rearmState -Headers $headers
Test-That 'an idle card with no question attribute is armed from the marker' { $script:Rearmed }
Test-That 'and that is not reported as a failed check' {
    @($script:RearmLog | Where-Object { $_ -like 'marker re-arm check failed*' }).Count -eq 0
}

$script:Rearmed = $false
$script:Ha = @{ "select.${node}_decision" = [pscustomobject]@{ state = 'Awaiting answer...'; attributes = [pscustomobject]@{ question = 'Which branch?' } } }
Confirm-DaemonDecisionArmed -SessionId $sid -Marker $rearmMarker -State $rearmState -Headers $headers
Test-That 'a card already showing the question is left alone' { -not $script:Rearmed }

$script:Rearmed = $false
$script:RearmLog = @()
$script:Ha = @{}
Confirm-DaemonDecisionArmed -SessionId $sid -Marker $rearmMarker -State $rearmState -Headers $headers
Test-That 'a card that truly cannot be read is still reported rather than armed blindly' {
    -not $script:Rearmed -and @($script:RearmLog | Where-Object { $_ -like 'marker re-arm check failed*' }).Count -eq 1
}

Remove-Item -LiteralPath $script:DaemonConfig.LogFile -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All daemon decision checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
