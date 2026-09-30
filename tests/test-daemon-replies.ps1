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

Write-Host '--- a file attachment that is not an image ---'
# Images go up to Home Assistant and are fetched back by id. /api/image/upload runs
# what it is handed through an image decoder and answers 400 for a document, so a .md
# arrives as bytes inside the payload and is written out here instead.
$script:AttachRoot = Join-Path ([IO.Path]::GetTempPath()) "test-daemon-attach-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $script:AttachRoot -Force | Out-Null
function Get-BridgeAttachmentRoot { $script:AttachRoot }

$plan = "# plan`nchoose B"
$planB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($plan))
function New-PayloadState { param([string]$Stamp, [string]$Text, [object[]]$Files)
    [pscustomobject]@{ state = $Stamp; attributes = [pscustomobject]@{ text = $Text; files = $Files } }
}

Test-That 'the payload carries a file alongside the text' {
    $p = Get-BridgeReplyPayload -State (New-PayloadState -Stamp 'f1' -Text 'thoughts?' -Files @([pscustomobject]@{ name = 'plan.md'; b64 = $planB64 }))
    $p.Files.Count -eq 1 -and $p.Files[0].Name -eq 'plan.md' -and $p.Files[0].Base64 -eq $planB64
}
Test-That 'a file with no bytes is not carried at all' {
    $p = Get-BridgeReplyPayload -State (New-PayloadState -Stamp 'f2' -Text 'x' -Files @([pscustomobject]@{ name = 'e.md'; b64 = '' }))
    $p.Files.Count -eq 0
}
Test-That 'a file on its own, with no text, is still a submission' {
    $null -ne (Get-BridgeReplyPayload -State (New-PayloadState -Stamp 'f3' -Text '' -Files @([pscustomobject]@{ name = 'p.md'; b64 = $planB64 })))
}
Test-That 'and a payload from a card too old to send files still reads' {
    $p = Get-BridgeReplyPayload -State ([pscustomobject]@{ state = 'f4'; attributes = [pscustomobject]@{ text = 'hello' } })
    $null -ne $p -and $p.Files.Count -eq 0
}

Write-Host '--- a file name that has to be safe to hand the CLI ---'
# The CLI references an attachment as `@<path>`, which has no quoting, so a space
# would split one attachment into two broken words. The name comes from a browser, so
# a separator or a `..` in it would put the file outside the attachment root.
Test-That 'a space cannot survive into a name the @path syntax must carry' {
    (Get-BridgeAttachmentFileName -Name 'my notes.md') -notmatch '\s'
}
Test-That 'the extension does survive, because the CLI reads the kind from it' {
    (Get-BridgeAttachmentFileName -Name 'my notes.md').EndsWith('.md')
}
Test-That 'a directory the browser sent is dropped' {
    (Get-BridgeAttachmentFileName -Name 'C:\Users\x\plan.md') -eq 'plan.md'
}
Test-That 'and so is a traversal' {
    (Get-BridgeAttachmentFileName -Name '../../../etc/passwd') -eq 'passwd'
}
Test-That 'a name that is only punctuation still yields a usable one' {
    (Get-BridgeAttachmentFileName -Name '...') -eq 'attachment'
} (Get-BridgeAttachmentFileName -Name '...')
Test-That 'an empty name does too' { (Get-BridgeAttachmentFileName -Name '') -eq 'attachment' }

Write-Host '--- writing an inline attachment to disk ---'
$written = Save-BridgeReplyFile -Name 'my plan.md' -Base64 $planB64
Test-That 'it lands under the attachment root' { $written.StartsWith($script:AttachRoot) } $written
Test-That 'carrying the bytes it was sent' { (Get-Content -LiteralPath $written -Raw) -match 'choose B' }
Test-That 'under a name the @path syntax can carry' { (Split-Path -Leaf $written) -notmatch '\s' } $written
Test-That 'two replies sending the same name do not overwrite each other' {
    $a = Save-BridgeReplyFile -Name 'plan.md' -Base64 $planB64
    $b = Save-BridgeReplyFile -Name 'plan.md' -Base64 $planB64
    $a -ne $b -and (Test-Path -LiteralPath $a) -and (Test-Path -LiteralPath $b)
}
Test-That 'something that is not base64 is refused rather than written' {
    (Save-BridgeReplyFile -Name 'x.md' -Base64 'not base64 at all!!') -eq ''
}
Test-That 'and so is a file past the limit, whatever the card let through' {
    (Save-BridgeReplyFile -Name 'big.bin' -Base64 ([Convert]::ToBase64String([byte[]]::new(300000)))) -eq ''
}
Remove-Item -LiteralPath $script:AttachRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host '--- a payload from the reply card ---'
$script:Replies = @(); $script:Removed = @(); $script:Saved = @(); $script:Wrote = @()
function Invoke-DaemonReply { param($SessionId, $Text, $Headers, $DisplayText, [switch]$ClearReplyBox) $script:Replies += [pscustomobject]@{ Text = $Text; StampAtDelivery = $state[$sid].LastReplyPayloadAt }; $true }
function Save-BridgeReplyAttachment { param($ImageId, $Name, $Headers) $script:Saved += $ImageId; "C:\att\$ImageId.png" }
function Save-BridgeReplyFile { param($Name, $Base64, $MaxBytes) $script:Wrote += $Name; "C:\att\$Name" }
function Remove-BridgeHomeAssistantImage { param($ImageId) $script:Removed += $ImageId; 'emitted' }
function Remove-BridgeStaleAttachment { 'emitted' }
function Set-Payload { param([string]$Stamp, [string]$Text, [object[]]$Images = @(), [object[]]$Files = @())
    $script:Ha = @{ "sensor.${node}_reply_payload" = [pscustomobject]@{ state = $Stamp; attributes = [pscustomobject]@{ text = $Text; images = $Images; files = $Files } } }
}
function Get-BridgeReplyPayload { param($State)
    if ($null -eq $State -or -not $State.state) { return $null }
    [pscustomobject]@{ Stamp = [string]$State.state; Text = [string]$State.attributes.text
        Images = @($State.attributes.images | ForEach-Object { [pscustomobject]@{ Id = $_; Name = "$_.png" } })
        Files = @($State.attributes.files | ForEach-Object { [pscustomobject]@{ Name = $_; Base64 = 'Yg==' } }) }
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

$script:Replies = @(); $script:Removed = @()
Set-Payload -Stamp 't2' -Text 'read this' -Files @('plan.md')
$handled = Send-DaemonCardPayload -SessionId $sid -Entry $entry -Headers $headers
Test-That 'a payload carrying a file delivers it as an attachment too' {
    $handled -eq $true -and $script:Replies.Count -eq 1 -and $script:Replies[0].Text -match '@C:\\att\\plan\.md'
} $(if ($script:Replies.Count) { $script:Replies[0].Text })
Test-That 'the file is written out rather than fetched from Home Assistant' {
    ($script:Wrote -join ',') -eq 'plan.md' -and $script:Removed.Count -eq 0
}

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
