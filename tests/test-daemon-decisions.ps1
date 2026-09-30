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
$script:Ha = @{}
$script:CardId = 'd1'
$script:SelectionAt = [DateTimeOffset]::Now.ToString('o')
function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    if (-not $script:Ha.ContainsKey($EntityId)) { throw "404 $EntityId" }
    $v = $script:Ha[$EntityId]
    if ($v -is [pscustomobject]) { return $v }
    [pscustomobject]@{
        state = [string]$v; last_changed = $script:SelectionAt
        attributes = [pscustomobject]@{ question = 'Pick'; decision_id = $script:CardId }
    }
}
$script:Transient = @()
function Set-DaemonTransientActivity { param($SessionId, $Summary, $Extra, $Headers) $script:Transient += $Summary; 'emitted' }
function Write-DaemonLog { param([string]$Message) }

$armedAt = [DateTimeOffset]::Now.AddMinutes(-2)
$form = [pscustomobject]@{
    mode = 'form'; decisionId = 'd1'; question = 'Pick'; armedAt = $armedAt.ToString('o'); choices = @(); injectedAnswer = ''
    fields = @(
        [pscustomobject]@{ Label = 'Colour'; Options = @('Red', 'Blue') }
        [pscustomobject]@{ Label = 'Size'; Options = @('S', 'L') }
        [pscustomobject]@{ Label = 'Notes'; Options = @(); IsText = $true }
    )
}
$state = @{ $sid = [pscustomobject]@{ Name = 'Claude: x'; Machine = 'M'; LastReply = '' } }
function Set-Form { param($Colour, $Size, $Notes, $Submit, $Decision = 'Awaiting answer...')
    $script:CardId = 'd1'
    $state[$sid] | Add-Member -NotePropertyName LastSubmitAt -NotePropertyValue '' -Force
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
Test-That 'every field chosen and Submit pressed after arming sends it' { $r.Answer -eq 'Blue + L + ' -and (@($r.Selections) -join '|') -eq 'Blue|L|' }
Test-That 'an empty free-text field is a valid answer' { @($r.Selections).Count -eq 3 }
Test-That 'the press is consumed, so it is not also read as a Send' { $state[$sid].LastSubmitAt -eq $script:Ha["button.${node}_submit"] }
Test-That 'what a call emits never joins the result' { $r -is [pscustomobject] }
Test-That 'the same submit press cannot send the form twice' {
    (Read-DaemonFormAnswer -SessionId $sid -Marker $form -State $state -Headers $headers).Answer -eq ''
}

Set-Form -Colour 'Blue' -Size 'L' -Notes '' -Submit $armedAt.AddMinutes(-1).ToString('o')
Test-That 'a press from before the question was armed does not count' { (Read-DaemonFormAnswer -SessionId $sid -Marker $form -State $state -Headers $headers).Answer -eq '' }

$script:Transient = @()
Set-Form -Colour 'Blue' -Size 'Choose...' -Notes '' -Submit $armedAt.AddMinutes(1).ToString('o')
Test-That 'a half-filled form is not sent' { (Read-DaemonFormAnswer -SessionId $sid -Marker $form -State $state -Headers $headers).Answer -eq '' }
Test-That 'and the card says so, rather than the button looking broken' { $script:Transient -contains 'Not sent - answer every field' }

Set-Form -Colour 'Choose...' -Size 'Choose...' -Notes '' -Submit 'unknown' -Decision 'Cancel request'
Test-That 'Cancel on the main selector cancels the form' { (Read-DaemonFormAnswer -SessionId $sid -Marker $form -State $state -Headers $headers).Answer -eq 'Cancel request' }

Write-Host '--- a single choice, and a free-text answer ---'
# Markers as Write-CopilotDecisionMarker writes them: injectedAnswer is always there.
$choice = [pscustomobject]@{ mode = 'multiple_choice'; decisionId = 'd2'; toolCallId = 'native'; armedAt = $armedAt.ToString('o'); question = 'Pick'; fields = @(); choices = @('Yes', 'No'); injectedAnswer = '' }
$script:CardId = 'd2'
$script:Ha = @{ "select.${node}_decision" = 'Yes' }
Test-That 'a choice is read from the selector' { $x = Read-DaemonDecisionAnswer -SessionId $sid -Marker $choice -State $state -Headers $headers; $x.Answer -eq 'Yes' -and $x.IsChoice }
$script:Ha = @{ "select.${node}_decision" = 'Awaiting answer...' }
Test-That 'the placeholder is not an answer' { (Read-DaemonDecisionAnswer -SessionId $sid -Marker $choice -State $state -Headers $headers).Answer -eq '' }
$free = [pscustomobject]@{ mode = 'freeform'; decisionId = 'd3'; armedAt = $armedAt.ToString('o'); question = 'Why?'; fields = @(); choices = @(); injectedAnswer = '' }
$script:CardId = 'd3'
$script:Ha = @{ "select.${node}_decision" = 'Awaiting answer...'; "text.${node}_reply" = 'Because.' }
Test-That 'a freeform answer is read from the reply box' { (Read-DaemonDecisionAnswer -SessionId $sid -Marker $free -State $state -Headers $headers).Answer -eq 'Because.' }
$script:Ha = @{ "select.${node}_decision" = 'Awaiting answer...'; "text.${node}_reply" = ' ' }
Test-That 'the blank the box is parked on is not an answer' { (Read-DaemonDecisionAnswer -SessionId $sid -Marker $free -State $state -Headers $headers).Answer -eq '' }
$script:Ha = @{}
Test-That 'an unreadable card gives nothing, rather than a guess' { $null -eq (Read-DaemonDecisionAnswer -SessionId $sid -Marker $free -State $state -Headers $headers) }

Write-Host '--- one pass over the pending questions ---'
$script:Injected = @(); $script:Cleared = @(); $script:Removed = @()
$script:Marker = $null
$script:Ask = @{ Started = $true; Pending = $true }
function Get-CopilotDecisionMarker { param($SessionId) $script:Marker }
function Get-DaemonAskUserState { param($Session, $Marker) [pscustomobject]@{ Started = $script:Ask.Started; Pending = $script:Ask.Pending; CanAnswer = ($script:Ask.Started -and $script:Ask.Pending); ToolCallId = 'native'; ResultContent = '' } }
function Invoke-DaemonDecisionAnswer { param($SessionId, $Marker, $Answer, $IsChoice, $Selections, $Headers) $script:Injected += $Answer; $true }
function Clear-CopilotMqttDecision { param($SessionId, $SessionName, $Machine, $Headers) $script:Cleared += $SessionId; 'emitted' }
function Invoke-HomeAssistantService { param($Domain, $Service, $Headers, $Data) }
function Remove-CopilotDecisionMarker {
    param($SessionId, $DecisionId, [switch]$PassThru)
    $removed = $null -ne $script:Marker -and $script:Marker.decisionId -ceq $DecisionId
    if ($removed) { $script:Removed += $SessionId; $script:Marker = $null }
    if ($PassThru) { $removed }
}
function Set-CopilotMqttDecision { param($SessionId, $SessionName, $Machine, $Question, $Choices, $Fields, $DecisionId, $Headers) $script:Rearmed = $true }
$live = @{ $sid = [pscustomobject]@{ SessionId = $sid } }

$script:Marker = $choice
$script:CardId = 'd2'
$script:Ha = @{ "select.${node}_decision" = 'No' }
Invoke-PendingDecisions -Headers $headers -State $state -Live $live
Test-That 'a pending question with an answer on its card is answered' { ($script:Injected -join ',') -eq 'No' }

$script:Injected = @()
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
$script:Ha = @{ "select.${node}_decision" = 'No' }
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
