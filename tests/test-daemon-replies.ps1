#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for delivering replies from the dashboard (hooks/daemon-replies.ps1): who
    owns the reply box, and the reply card's payload.

.DESCRIPTION
    The text box and its Send button are covered by test-stop-session.ps1. These cover
    the rest of Invoke-PendingReplies, split out as its own functions: a question on
    the card owning the box (and a stale one being cleared), and a payload from the
    reply card - delivered once, recorded before delivery, its images tidied after.
    Home Assistant is a table of entity states; nothing is typed anywhere.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
$script:DaemonConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-daemon-replies-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

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
$session = [pscustomobject]@{ SessionId = $sid }
$state = @{ $sid = [pscustomobject]@{ Name = 'Claude: x'; Machine = 'M' } }

$script:Ha = @{}
function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    if (-not $script:Ha.ContainsKey($EntityId)) { throw "404 $EntityId" }
    $script:Ha[$EntityId]
}
$script:Marker = $null
$script:Pending = $true
$script:Cleared = 0
function Get-CopilotDecisionMarker { param($SessionId) $script:Marker }
function Get-DaemonAskUserState { param($Session, $Marker) [pscustomobject]@{ Pending = $script:Pending } }
function Clear-CopilotMqttDecision { param($SessionId, $SessionName, $Machine, $Headers) $script:Cleared++; 'emitted' }
function Write-DaemonLog { param([string]$Message) }
function Set-DaemonTransientActivity { param($SessionId, $Summary, $Extra, $Headers) 'emitted' }

Write-Host '--- who owns the reply box ---'
$script:Ha = @{ "select.${node}_decision" = [pscustomobject]@{ state = 'Idle'; attributes = [pscustomobject]@{ question = '' } } }
Test-That 'with no question on the card, replies may use it' { (Test-DaemonReplyBoxFree -SessionId $sid -Session $session -State $state -Headers $headers) -eq $true }
$script:Ha["select.${node}_decision"] = [pscustomobject]@{ state = 'Awaiting answer...'; attributes = [pscustomobject]@{ question = 'Pick one' } }
$script:Marker = [pscustomobject]@{ decisionId = 'd1' }
Test-That 'a live question owns it' { (Test-DaemonReplyBoxFree -SessionId $sid -Session $session -State $state -Headers $headers) -eq $false }
$script:Marker = $null
$script:Pending = $true
Test-That 'a question card with no marker but still pending keeps it too' { (Test-DaemonReplyBoxFree -SessionId $sid -Session $session -State $state -Headers $headers) -eq $false }
$script:Pending = $false
Test-That 'a card left over from an answered question is cleared, freeing it' {
    ((Test-DaemonReplyBoxFree -SessionId $sid -Session $session -State $state -Headers $headers) -eq $true) -and $script:Cleared -eq 1
}
$script:Ha = @{}
Test-That 'an unreadable card is treated as free - a reply is the common case' { (Test-DaemonReplyBoxFree -SessionId $sid -Session $session -State $state -Headers $headers) -eq $true }

Write-Host '--- a Codex approval owns the card too ---'
# It arms the same selector, but through its PermissionRequest hook rather than
# ask_user, so Get-CopilotDecisionMarker returns nothing for it. Only that marker was
# checked, so a live approval fell through to the staleness check - which asks the
# transcript about an ask_user that never existed, always answers "not pending", and
# tore the card down. This runs for every live session on every reconcile, so the
# dropdown was reset to Idle within seconds of appearing and a pick made on it was
# rejected against an emptied option list: the prompt could only be answered in the
# terminal.
$script:ApprovalMarker = $null
function Get-DaemonAgent { param($Kind) [pscustomobject]@{ ApprovalMarker = { param($id) $script:ApprovalMarker } } }
$codexSession = [pscustomobject]@{ SessionId = $sid; Kind = 'codex' }
$script:Ha = @{ "select.${node}_decision" =
    [pscustomobject]@{ state = 'Awaiting answer...'; attributes = [pscustomobject]@{ question = 'Approve agent-ha-bridge restart?' } } }
$script:Marker = $null
$script:Pending = $false
$script:ApprovalMarker = [pscustomobject]@{ decisionId = 'a1' }
$clearedBefore = $script:Cleared
Test-That 'a live Codex approval owns the card' {
    (Test-DaemonReplyBoxFree -SessionId $sid -Session $codexSession -State $state -Headers $headers) -eq $false
}
Test-That 'and it is not torn down as a stale card' { $script:Cleared -eq $clearedBefore } "cleared $($script:Cleared - $clearedBefore) time(s)"
$script:ApprovalMarker = $null
Test-That 'once the approval is gone the card is cleared as before' {
    ((Test-DaemonReplyBoxFree -SessionId $sid -Session $codexSession -State $state -Headers $headers) -eq $true) -and
        $script:Cleared -eq ($clearedBefore + 1)
}
Remove-Item function:Get-DaemonAgent
$script:Ha = @{}

Write-Host '--- a payload from the reply card ---'
$script:Replies = @(); $script:Removed = @(); $script:Saved = @()
function Invoke-DaemonReply { param($SessionId, $Text, $Headers, $DisplayText, [switch]$ClearReplyBox) $script:Replies += [pscustomobject]@{ Text = $Text; StampAtDelivery = $state[$sid].LastReplyPayloadAt }; $true }
function Save-BridgeReplyAttachment { param($ImageId, $Name, $Headers) $script:Saved += $ImageId; "C:\att\$ImageId.png" }
function Remove-BridgeHomeAssistantImage { param($ImageId) $script:Removed += $ImageId; 'emitted' }
function Remove-BridgeStaleAttachment { 'emitted' }
function Set-Payload { param([string]$Stamp, [string]$Text, [object[]]$Images = @())
    $script:Ha = @{ "sensor.${node}_reply_payload" = [pscustomobject]@{ state = $Stamp; attributes = [pscustomobject]@{ text = $Text; images = $Images } } }
}
function Get-BridgeReplyPayload { param($State)
    if ($null -eq $State -or -not $State.state) { return $null }
    [pscustomobject]@{ Stamp = [string]$State.state; Text = [string]$State.attributes.text
        Images = @($State.attributes.images | ForEach-Object { [pscustomobject]@{ Id = $_; Name = "$_.png" } }) }
}

$entry = $state[$sid]
Set-Payload -Stamp 't1' -Text 'look at this' -Images @('img1')
$handled = Send-DaemonCardPayload -SessionId $sid -Entry $entry -Headers $headers
Test-That 'a new payload is delivered' { $handled -eq $true -and $script:Replies.Count -eq 1 }
Test-That 'with its image attached to the prompt' { $script:Replies[0].Text -match '@C:\\att\\img1\.png' -and $script:Replies[0].Text -match 'look at this' }
Test-That 'its stamp is recorded before delivery, so a slow send is not repeated' { $script:Replies[0].StampAtDelivery -eq 't1' }
Test-That 'and the image is removed from Home Assistant once delivered' { ($script:Removed -join ',') -eq 'img1' }
Test-That 'what a call emits never joins the result' { $handled -is [bool] }

$script:Replies = @()
Test-That 'the same payload is not delivered twice' { (Send-DaemonCardPayload -SessionId $sid -Entry $entry -Headers $headers) -eq $false -and $script:Replies.Count -eq 0 }
$script:Ha = @{}
Test-That 'no payload sensor leaves the text box to do its job' { (Send-DaemonCardPayload -SessionId $sid -Entry $entry -Headers $headers) -eq $false }

Remove-Item -LiteralPath $script:DaemonConfig.LogFile -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All daemon reply checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
