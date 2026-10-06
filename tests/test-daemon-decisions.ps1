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

Remove-Item -LiteralPath $script:DaemonConfig.LogFile -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All daemon decision checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
