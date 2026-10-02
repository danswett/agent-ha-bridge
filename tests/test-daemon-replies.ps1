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

Write-Host '--- who sent a payload, which MQTT cannot say for itself ---'
# A Submit press commits through a service call and Home Assistant records the account
# on it. This arrives over MQTT, where a published state carries no context at all, so
# the only thing that can say is the payload.
Test-That 'a payload that marks itself as the agent is read as the agent' {
    $p = Get-BridgeReplyPayload -State ([pscustomobject]@{ state = 'd1'; attributes = [pscustomobject]@{ text = 'hi'; driver = 'agent' } })
    $p.Driver -eq 'agent'
}
Test-That 'the reply card marks nothing, and a person is what that means' {
    $p = Get-BridgeReplyPayload -State ([pscustomobject]@{ state = 'd2'; attributes = [pscustomobject]@{ text = 'hi' } })
    $p.Driver -eq 'human'
}
Test-That 'and anything other than the one word it knows is a person too' {
    $p = Get-BridgeReplyPayload -State ([pscustomobject]@{ state = 'd3'; attributes = [pscustomobject]@{ text = 'hi'; driver = 'AGENT ' } })
    $p.Driver -eq 'human'
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
$script:DeliverResult = $true
function Invoke-DaemonReply { param($SessionId, $Text, $Headers, $DisplayText, [switch]$ClearReplyBox)
    $script:Replies += [pscustomobject]@{ Text = $Text; StampAtDelivery = $state[$sid].LastReplyPayloadAt }
    # The real one writes to the card on its way through, so it emits before returning.
    'emitted'
    $script:DeliverResult }
function Save-BridgeReplyAttachment { param($ImageId, $Name, $Headers) $script:Saved += $ImageId; "C:\att\$ImageId.png" }
function Save-BridgeReplyFile { param($Name, $Base64, $MaxBytes) $script:Wrote += $Name; "C:\att\$Name" }
function Remove-BridgeHomeAssistantImage { param($ImageId) $script:Removed += $ImageId; 'emitted' }
function Remove-BridgeStaleAttachment { 'emitted' }
function Set-Payload { param([string]$Stamp, [string]$Text, [object[]]$Images = @(), [object[]]$Files = @(), [string]$Driver = '')
    $attrs = [pscustomobject]@{ text = $Text; images = $Images; files = $Files }
    if ($Driver) { $attrs | Add-Member -NotePropertyName driver -NotePropertyValue $Driver }
    $script:Ha = @{ "sensor.${node}_reply_payload" = [pscustomobject]@{ state = $Stamp; attributes = $attrs } }
}
function Get-BridgeReplyPayload { param($State)
    if ($null -eq $State -or -not $State.state) { return $null }
    $drv = 'human'
    if ($State.attributes.PSObject.Properties['driver'] -and $State.attributes.driver) { $drv = [string]$State.attributes.driver }
    [pscustomobject]@{ Stamp = [string]$State.state; Text = [string]$State.attributes.text; Driver = $drv
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

Write-Host '--- a payload hands the session to whoever sent it ---'
# A reply longer than the text box's 255 characters is the only kind that comes this
# way, and agents send long replies. Delivering one without saying who sent it left the
# next turn to be read as somebody typing in the terminal, so a session an agent was
# driving went back to showing as the person's the moment it started answering.
$script:Replies = @()
Set-Payload -Stamp 'd10' -Text 'a long one from an agent' -Driver 'agent'
[void](Send-DaemonCardPayload -SessionId $sid -Entry $entry -Headers $headers)
Test-That 'an agent payload marks the session as the agent' { $entry.Driver -eq 'agent' } $(if ($entry.PSObject.Properties['Driver']) { $entry.Driver })
Test-That 'and arms the turn it is about to start, so it is not handed straight back' { $entry.DriverPending -eq $true }

Set-Payload -Stamp 'd11' -Text 'and one typed on the dashboard'
[void](Send-DaemonCardPayload -SessionId $sid -Entry $entry -Headers $headers)
Test-That 'a reply typed on the card hands it back to the person' { $entry.Driver -eq 'human' } $(if ($entry.PSObject.Properties['Driver']) { $entry.Driver })

# Armed but nothing sent is the case that would show a person's turn with the agent's
# edge: no agent turn is coming, so the next thing typed in the terminal consumes it.
$script:Replies = @(); $script:DeliverResult = $false
Set-DaemonSessionProperty -Entry $entry -Name 'DriverPending' -Value $true
Set-Payload -Stamp 'd12' -Text 'this one does not land' -Driver 'agent'
[void](Send-DaemonCardPayload -SessionId $sid -Entry $entry -Headers $headers)
Test-That 'a delivery that fails disarms it again' { $entry.DriverPending -eq $false } "pending=$($entry.DriverPending)"

$script:DeliverResult = $true
$script:Replies = @()
Set-DaemonSessionProperty -Entry $entry -Name 'DriverPending' -Value $true
Set-Payload -Stamp 'd13' -Text '' -Driver 'agent'
[void](Send-DaemonCardPayload -SessionId $sid -Entry $entry -Headers $headers)
Test-That 'and a payload with nothing deliverable disarms it too' {
    $entry.DriverPending -eq $false -and $script:Replies.Count -eq 0
} "pending=$($entry.DriverPending) replies=$($script:Replies.Count)"

# A delivery is normally instant - 0.3s for every reply on one machine across a day,
# including one of 5,914 characters - but it is not guaranteed to be: one that day took
# 721 seconds while injection was failing and retrying. Timing the arm from before that
# would expire it while the reply was still going in.
$script:Replies = @()
Set-Payload -Stamp 'd14' -Text 'a slow one' -Driver 'agent'
$script:DeliverStamp = $null
function Invoke-DaemonReply { param($SessionId, $Text, $Headers, $DisplayText, [switch]$ClearReplyBox)
    # Stand in for a delivery that took longer than the arm's whole window.
    Set-DaemonSessionProperty -Entry $state[$sid] -Name 'DriverPendingAt' `
        -Value ([DateTimeOffset]::Now.AddSeconds(-($script:DaemonConfig.DriverArmSeconds + 120)).ToString('o'))
    $script:Replies += [pscustomobject]@{ Text = $Text; StampAtDelivery = $state[$sid].LastReplyPayloadAt }
    'emitted'
    $true }
[void](Send-DaemonCardPayload -SessionId $sid -Entry $entry -Headers $headers)
Test-That 'an arm outlives a delivery that took longer than its own window' {
    Test-DaemonDriverPending -Entry $entry
} "pendingAt=$($entry.DriverPendingAt)"

Write-Host ''
Write-Host '--- an agent''s Send press does not cancel the payload it just sent ---'
# The pattern every agent follows is: publish the payload, then press Send. The payload
# is delivered on its own the moment it lands, so the press that follows finds the box
# empty - and that emptiness was read as "nothing was sent", which disarmed. Live on
# 2026-10-02: a 2,234-character reply went in at 08:57:39, the press cleared the arm six
# seconds later, and the turn it produced at 08:58:50 was published as the person's. An
# idle session starts its turn before the press arrives and keeps the edge, which is why
# this only shows when the session being written to is busy, and why it survived both
# earlier attempts at the blue-instead-of-purple bug.
$script:DaemonConfig.ReplyCommitAttempts = 0
function Get-BridgeDriverFromState { param($State) 'agent' }
function Invoke-HomeAssistantService { param($Domain, $Service, $Headers, $Data) 'emitted' }
function Invoke-DaemonReply {
    param($SessionId, $Text, $Headers, $DisplayText, [switch]$ClearReplyBox)
    $script:Replies += [pscustomobject]@{ Text = $Text }
    $true
}
function Set-PressFixture {
    param([string]$Press, [string]$Box = ' ')
    $script:Ha["button.${node}_submit"] = [pscustomobject]@{ state = $Press; attributes = [pscustomobject]@{} }
    $script:Ha["text.${node}_reply"] = [pscustomobject]@{ state = $Box; attributes = [pscustomobject]@{} }
}

$pressEntry = [pscustomobject]@{ Name = 'Claude: x'; Machine = 'M' }
$script:Replies = @()
Set-Payload -Stamp 'p1' -Text 'a long one from an agent' -Driver 'agent'
[void](Send-DaemonCardPayload -SessionId $sid -Entry $pressEntry -Headers $headers)
Test-That 'the payload is delivered and the turn armed' {
    $pressEntry.DriverPending -eq $true -and $script:Replies.Count -eq 1
} "pending=$($pressEntry.DriverPending) replies=$($script:Replies.Count)"
Test-That 'and the delivery is stamped, so a press arriving after it can be recognised' {
    $pressEntry.PSObject.Properties['LastPayloadDeliveredAt'] -and $pressEntry.LastPayloadDeliveredAt
}

Set-PressFixture -Press '2026-10-02T15:57:45+00:00'
[void](Send-DaemonReplyBoxText -SessionId $sid -Entry $pressEntry -Headers $headers)
Test-That 'the redundant press sends nothing a second time' { $script:Replies.Count -eq 1 } "replies=$($script:Replies.Count)"
Test-That 'the arm survives it, so the turn it produces is still the agent''s' {
    $pressEntry.DriverPending -eq $true
} "pending=$($pressEntry.DriverPending)"
Test-That 'and the press is still recorded as spent, so it is not reprocessed' {
    [string]$pressEntry.LastSubmitAt -eq '2026-10-02T15:57:45+00:00' -and [string]$pressEntry.PendingSubmitAt -eq ''
}

# Without a payload behind it the old behaviour has to stand: an arm nothing will ever
# consume would put the agent's edge on whatever the person types next.
$bare = [pscustomobject]@{ Name = 'Claude: x'; Machine = 'M' }
Set-DaemonDriverPending -Entry $bare -Driver 'agent'
Set-PressFixture -Press '2026-10-02T16:00:00+00:00'
[void](Send-DaemonReplyBoxText -SessionId $sid -Entry $bare -Headers $headers)
Test-That 'an empty press with no payload behind it still disarms' {
    -not $bare.DriverPending
} "pending=$($bare.DriverPending)"

$stale = [pscustomobject]@{ Name = 'Claude: x'; Machine = 'M' }
Set-DaemonDriverPending -Entry $stale -Driver 'agent'
Set-DaemonSessionProperty -Entry $stale -Name 'LastPayloadDeliveredAt' `
    -Value ([DateTimeOffset]::Now.AddSeconds(-($script:DaemonConfig.DriverArmSeconds + 60)).ToString('o'))
Set-PressFixture -Press '2026-10-02T16:05:00+00:00'
[void](Send-DaemonReplyBoxText -SessionId $sid -Entry $stale -Headers $headers)
Test-That 'and a payload older than the arm''s own window cannot keep it alive' {
    -not $stale.DriverPending
} "pending=$($stale.DriverPending)"

Test-That 'a session that has never had a payload reports none just delivered' {
    -not (Test-DaemonPayloadJustDelivered -Entry ([pscustomobject]@{ Name = 'Claude: x' }))
}

# The hole a recency test leaves on its own, reproduced through the real handler: the
# press arms BEFORE it reads the box, so a payload whose arm its turn had already
# consumed came back as a fresh agent arm - false before the press, true after it -
# for a message that was already accounted for. Nothing would then consume it except
# the next thing the person typed, which is the one direction this must never fail in.
$consumed = [pscustomobject]@{ Name = 'Claude: x'; Machine = 'M' }
$script:Replies = @()
Set-Payload -Stamp 'p2' -Text 'a long one from an agent' -Driver 'agent'
[void](Send-DaemonCardPayload -SessionId $sid -Entry $consumed -Headers $headers)
# The turn it was armed for arrives and spends it, exactly as daemon-activity does.
Set-DaemonSessionProperty -Entry $consumed -Name 'DriverPending' -Value $false
Test-That 'the arm really is spent before the press' { -not (Test-DaemonDriverPending -Entry $consumed) }
Set-PressFixture -Press '2026-10-02T16:10:00+00:00'
[void](Send-DaemonReplyBoxText -SessionId $sid -Entry $consumed -Headers $headers)
Test-That 'a press after a payload whose turn already came does not re-arm it' {
    -not $consumed.DriverPending
} "pending=$($consumed.DriverPending)"

# Same shape, but the recent payload was the person's. Preserving an arm here would
# put the agent's edge on a turn the dashboard typed.
$humanPayload = [pscustomobject]@{ Name = 'Claude: x'; Machine = 'M' }
$script:Replies = @()
Set-Payload -Stamp 'p3' -Text 'and one typed on the dashboard'
[void](Send-DaemonCardPayload -SessionId $sid -Entry $humanPayload -Headers $headers)
Test-That 'a human payload arms as the person' {
    $humanPayload.DriverPending -eq $true -and $humanPayload.Driver -eq 'human'
} "driver=$($humanPayload.Driver)"
Set-PressFixture -Press '2026-10-02T16:15:00+00:00'
[void](Send-DaemonReplyBoxText -SessionId $sid -Entry $humanPayload -Headers $headers)
Test-That 'an agent''s empty press does not claim a payload the person sent' {
    -not $humanPayload.DriverPending
} "pending=$($humanPayload.DriverPending) driver=$($humanPayload.Driver)"

# A press that arrives late must preserve the arm without extending it, or repeated
# presses would keep an arm alive indefinitely past the window that bounds it.
$late = [pscustomobject]@{ Name = 'Claude: x'; Machine = 'M' }
$script:Replies = @()
Set-Payload -Stamp 'p4' -Text 'a long one from an agent' -Driver 'agent'
[void](Send-DaemonCardPayload -SessionId $sid -Entry $late -Headers $headers)
$armedAt = ([DateTimeOffset]::Now.AddSeconds(-60)).ToString('o')
Set-DaemonSessionProperty -Entry $late -Name 'DriverPendingAt' -Value $armedAt
Set-PressFixture -Press '2026-10-02T16:20:00+00:00'
[void](Send-DaemonReplyBoxText -SessionId $sid -Entry $late -Headers $headers)
Test-That 'a late redundant press keeps the arm it found' { $late.DriverPending -eq $true }
Test-That 'and does not restart its clock' {
    [string]$late.DriverPendingAt -eq $armedAt
} "at=$($late.DriverPendingAt) expected=$armedAt"

Remove-Item -LiteralPath $script:DaemonConfig.LogFile -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All daemon reply checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
