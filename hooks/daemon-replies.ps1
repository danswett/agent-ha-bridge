<#
    Bridge daemon: dashboard to agent text.

    Delivers what is typed or pasted into a card to its session - images included -
    and confirms it was submitted.

    Part of agent-bridge-daemon.ps1, which dot-sources it into its own scope after
    declaring the shared $script: state; see docs/daemon-split.md.
    It changes no shared state.
#>

function Get-BridgeAttachmentRoot {
    <#
        Where images from the reply card are written before being attached.

        The path must not contain a space. The CLI attaches a file when the prompt
        references it as `@<path>`, and there is no way to quote a path in that
        syntax, so a space would split one attachment into two broken words.
        LOCALAPPDATA normally qualifies, but it sits under the user profile, so a
        user name containing a space would make every attachment unusable - hence
        the fallback to the public profile, which never contains one.
    #>
    $root = ''
    # macOS: beside the bridge's config, or /tmp for a home folder with a space.
    if (-not $script:BridgeIsWindows) {
        $root = Join-Path $HOME '.agent-ha-bridge/attachments'
        if ($root -match '\s') { $root = Join-Path $env:TEMP 'agent-ha-bridge-attachments' }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $root = Join-Path ([string]$env:LOCALAPPDATA) 'agent-ha-bridge\attachments'
    }
    if ([string]::IsNullOrWhiteSpace($root) -or $root -match '\s') {
        $root = Join-Path ([string]$env:PUBLIC) 'agent-ha-bridge\attachments'
    }
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    $root
}

function Get-BridgeReplyPayload {
    <#
        Reads one submission from the reply card's payload sensor.

        Returns $null when there is nothing usable to send.

        The stamp is the card's own timestamp, carried in the sensor state via
        value_template. Comparing it against the last one handled is what makes a
        duplicate delivery impossible - the same contract the Submit button's press
        stamp already uses. The text itself is read from the attributes rather than
        the state because Home Assistant caps a state at 255 characters and does not
        cap attributes, which is the whole reason this entity exists.
    #>
    param([object]$State)

    if ($null -eq $State) { return $null }

    $stamp = ''
    if ($State.PSObject.Properties['state']) { $stamp = [string]$State.state }
    if ([string]::IsNullOrWhiteSpace($stamp) -or $stamp -in @('unknown', 'unavailable')) { return $null }

    $attrs = $null
    if ($State.PSObject.Properties['attributes']) { $attrs = $State.attributes }
    if ($null -eq $attrs) { return $null }

    $text = ''
    if ($attrs.PSObject.Properties['text']) { $text = [string]$attrs.text }

    $images = [System.Collections.Generic.List[object]]::new()
    if ($attrs.PSObject.Properties['images'] -and $null -ne $attrs.images) {
        foreach ($image in @($attrs.images)) {
            if ($null -eq $image) { continue }
            $id = ''
            if ($image.PSObject.Properties['id']) { $id = [string]$image.id }
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            $name = ''
            if ($image.PSObject.Properties['name']) { $name = [string]$image.name }
            $images.Add([pscustomobject]@{ Id = $id; Name = $name })
        }
    }

    # An empty submission is not an error, it is just nothing to do.
    if ([string]::IsNullOrWhiteSpace($text) -and $images.Count -eq 0) { return $null }

    [pscustomobject]@{
        Stamp  = $stamp
        Text   = $text
        Images = $images.ToArray()
    }
}

function New-BridgeAttachmentPrompt {
    <#
        Builds the text that is typed into the CLI for a reply carrying attachments.

        Copilot CLI attaches a file when the prompt references it as `@<path>`, so
        the attachments lead and the typed text follows. A path containing a space
        cannot be expressed that way and is dropped rather than silently corrupting
        the rest of the prompt; Get-BridgeAttachmentRoot exists to make that
        impossible in the first place.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string[]]$Paths = @()
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if ($path -match '\s') { continue }
        $parts.Add("@$path")
    }

    $clean = ([string]$Text).Trim()
    if (-not [string]::IsNullOrWhiteSpace($clean)) { $parts.Add($clean) }

    $parts -join ' '
}

function Save-BridgeReplyAttachment {
    <#
        Downloads one image the reply card uploaded to Home Assistant.

        Returns the local path, or '' if it could not be fetched. The extension is
        taken from the original file name because the CLI decides how to treat an
        attachment from its extension, and falls back to .png - the format anything
        pasted from a clipboard arrives as.
    #>
    param(
        [Parameter(Mandatory)][string]$ImageId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $extension = ''
    try { $extension = [System.IO.Path]::GetExtension($Name) } catch { $extension = '' }
    if ($extension -notin @('.png', '.jpg', '.jpeg', '.gif', '.webp', '.heic', '.heif', '.pdf')) {
        $extension = '.png'
    }

    $safeId = $ImageId -replace '[^0-9a-zA-Z]', ''
    if ([string]::IsNullOrWhiteSpace($safeId)) { return '' }

    $path = Join-Path (Get-BridgeAttachmentRoot) "$safeId$extension"
    $uri = "$($script:DecisionBridgeConfig.HomeAssistantBaseUrl)/api/image/serve/$ImageId/original"

    try {
        Invoke-WebRequest -Uri $uri -Headers $Headers -OutFile $path -UseBasicParsing -ErrorAction Stop | Out-Null
    }
    catch {
        Write-DaemonLog -Message "could not fetch attachment $ImageId : $($_.Exception.Message)"
        return ''
    }

    if (-not (Test-Path -LiteralPath $path)) { return '' }
    $path
}

function Remove-BridgeHomeAssistantImage {
    <#
        Deletes an uploaded image from Home Assistant once it is safely on disk here.

        Best effort: a failure leaves a file in Home Assistant's upload store, which
        is untidy but harmless, and must never stop a reply being delivered.
    #>
    param([Parameter(Mandatory)][string]$ImageId)

    try {
        [void](Invoke-CopilotHaWebSocket -Commands @(@{ type = 'image/delete'; image_id = $ImageId }))
    }
    catch {
        Write-DaemonLog -Message "could not remove uploaded image $ImageId from Home Assistant: $($_.Exception.Message)"
    }
}

function Remove-BridgeStaleAttachment {
    <#
        Clears attachments left behind by previous replies.

        They are only needed until the CLI has read them, which happens within
        seconds of delivery, but deleting immediately would race that read. A day is
        far longer than the CLI needs and keeps the folder from growing without end.
    #>
    param([int]$MaxAgeHours = 24)

    try {
        $cutoff = (Get-Date).AddHours(-$MaxAgeHours)
        $root = Get-BridgeAttachmentRoot
        foreach ($file in @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue)) {
            if ($file.LastWriteTime -lt $cutoff) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch { }
}

function Invoke-PendingReplies {
    <#
        Delivers any reply box that currently holds text.

        The WebSocket watch only sees a reply if the state change fires during its
        active window, so a reply that lands in the gap between windows would be lost.
        Reading the retained value on every reconcile closes that race: the box keeps
        its value until the daemon clears it, so it is always seen within one
        reconcile interval regardless of timing. The push path stays as a latency
        optimization on top of this.

        A per-session hash guards the brief window between delivering a reply and the
        clear taking effect, so the same text is never injected twice.

        For each session: whether the reply box is free (Test-DaemonReplyBoxFree), then
        the reply card's payload (Send-DaemonCardPayload), then the text box and its
        Send button (Send-DaemonReplyBoxText).
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Live
    )

    foreach ($sessionId in @($State.Keys)) {
        if (-not $Live.ContainsKey($sessionId)) { continue }
        if (-not (Test-DaemonReplyBoxFree -SessionId $sessionId -Session $Live[$sessionId] -State $State -Headers $Headers)) { continue }
        $entry = $State[$sessionId]
        if (Send-DaemonCardPayload -SessionId $sessionId -Entry $entry -Headers $Headers) { continue }
        Send-DaemonReplyBoxText -SessionId $sessionId -Entry $entry -Headers $Headers
    }
}

function Test-DaemonReplyBoxFree {
    <#
        Whether a session's reply box is free for a reply, rather than owned by a
        question on its card. Reads the decision card once and decides who owns the
        box; a question card left over from a question already answered is cleared,
        which frees it.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $sessionId = $SessionId
    $node = Get-CopilotMqttNodeId -SessionId $sessionId
    $marker = Get-CopilotDecisionMarker -SessionId $sessionId

    $armedQuestion = ''
    try {
        $decisionState = Get-DaemonEntityState -EntityId "select.${node}_decision" -Headers $Headers
        $armedQuestion = [string]$decisionState.attributes.question
    }
    catch {
        # Unreadable decision state: treat the reply as a continuation, the common case.
    }
    if ([string]::IsNullOrWhiteSpace($armedQuestion)) { return $true }

    if ($null -ne $marker) {
        # A live question owns the reply box - Invoke-PendingDecisions reads it as the
        # free-text field of the form, and reports there if the form is incomplete.
        # Nothing to do here.
        return $false
    }

    # A Codex approval arms the same card through a different marker: its
    # PermissionRequest hook, not ask_user. Only the ask_user marker was looked for
    # here, so a live approval always fell through to the staleness check below, which
    # asks the transcript about an ask_user that was never there, concluded the card
    # was a leftover and tore it down. This runs for every live session on every
    # reconcile, so an approval card was reset to Idle within seconds of appearing,
    # every time: a choice made on the dashboard landed on a selector whose options had
    # just been emptied and was rejected, and the prompt could only be answered in the
    # terminal.
    $approvalMarker = $null
    try {
        $readApproval = (Get-DaemonAgent -Kind ([string]$Session.Kind)).ApprovalMarker
        if ($readApproval) { $approvalMarker = & $readApproval $sessionId }
    }
    catch { }
    if ($null -ne $approvalMarker) { return $false }

    # Armed card with no marker behind it. Either the old blocking router is genuinely
    # waiting on it, or the question was already answered and the card was never torn
    # down - in which case every reply typed here is dropped silently, which is how a
    # session ends up unable to be replied to at all. The transcript settles it.
    $stale = $false
    try {
        $askState = Get-DaemonAskUserState -Session $Session
        $stale = (-not $askState.Pending)
    }
    catch { }

    if (-not $stale) { return $false }

    try {
        Clear-CopilotMqttDecision -SessionId $sessionId `
            -SessionName ([string]$State[$sessionId].Name) `
            -Machine ([string]$State[$sessionId].Machine) -Headers $Headers | Out-Null
        Write-DaemonLog -Message "cleared a stale decision card for $($sessionId.Substring(0,8)) so replies work again"
    }
    catch {
        Write-DaemonLog -Message "could not clear the stale decision card for $sessionId : $($_.Exception.Message)"
        return $false
    }
    $true
}

function Send-DaemonCardPayload {
    <#
        Delivers a new payload from the reply card - text and images - and returns
        whether there was one. It takes precedence over the text box.

        It sends what is on screen at the instant Send is pressed rather than whatever
        Home Assistant last managed to commit, so it needs no arming and no waiting, and
        it can carry images and text of any length.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $sessionId = $SessionId
    $entry = $Entry
    $node = Get-CopilotMqttNodeId -SessionId $sessionId
    $payload = $null
    try {
        $payloadState = Get-DaemonEntityState -EntityId "sensor.${node}_reply_payload" -Headers $Headers
        $payload = Get-BridgeReplyPayload -State $payloadState
    }
    catch {
        # No payload sensor yet (a session published before this existed), or it is
        # unreadable. The text box still works.
    }
    if ($null -eq $payload) { return $false }

    $lastPayload = if ($entry.PSObject.Properties['LastReplyPayloadAt']) { [string]$entry.LastReplyPayloadAt } else { '' }
    if ($payload.Stamp -eq $lastPayload) { return $false }

    # Record the stamp before delivering, not after. Delivery types the reply into the
    # console one character at a time, which is long enough for the next reconcile to
    # see the same payload still sitting there and send it a second time.
    Set-DaemonSessionProperty -Entry $entry -Name 'LastReplyPayloadAt' -Value $payload.Stamp

    try {
        Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Sending...' -Headers $Headers | Out-Null
    }
    catch { }

    $paths = [System.Collections.Generic.List[string]]::new()
    $fetched = [System.Collections.Generic.List[string]]::new()
    foreach ($image in @($payload.Images)) {
        $saved = Save-BridgeReplyAttachment -ImageId $image.Id -Name $image.Name -Headers $Headers
        if (-not [string]::IsNullOrWhiteSpace($saved)) {
            $paths.Add($saved)
            $fetched.Add($image.Id)
        }
    }

    $prompt = New-BridgeAttachmentPrompt -Text $payload.Text -Paths $paths.ToArray()
    if ([string]::IsNullOrWhiteSpace($prompt)) {
        Write-DaemonLog -Message "reply card payload for $($sessionId.Substring(0,8)) had nothing deliverable"
        return $true
    }

    $attachmentNote = if ($paths.Count -gt 0) { " with $($paths.Count) attachment(s)" } else { '' }
    Write-DaemonLog -Message "reply card payload for $($sessionId.Substring(0,8))$attachmentNote"

    Set-DaemonSessionProperty -Entry $entry -Name 'LastReply' -Value $payload.Text
    [void](Invoke-DaemonReply -SessionId $sessionId -Text $prompt -Headers $Headers `
        -DisplayText $payload.Text -ClearReplyBox:$false)

    # Only once it is delivered, so a failed send leaves the image in place to be
    # retried by hand.
    foreach ($id in $fetched) { Remove-BridgeHomeAssistantImage -ImageId $id | Out-Null }
    Remove-BridgeStaleAttachment | Out-Null
    $true
}

function Send-DaemonReplyBoxText {
    <#
        Delivers the text box's reply when its Send button has been pressed - waiting
        a moment, and if need be a few passes, for Home Assistant to commit what was
        typed, and saying so on the card rather than letting a press look ignored.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $sessionId = $SessionId
    $entry = $Entry
    $node = Get-CopilotMqttNodeId -SessionId $sessionId
    $replyEntity = "text.${node}_reply"

    # Read the press first. The old order read the reply box first and bailed on a
    # blank one, which lost the race Home Assistant creates: a text entity commits
    # when it loses focus, and on a phone the tap that commits it *is* the tap on
    # Send. The first read could therefore still see the old, blank value, nothing
    # was sent, and nothing said so - which is why a reply sometimes needed Send
    # pressed twice.
    $press = ''
    try {
        $btn = Get-HomeAssistantState -EntityId "button.${node}_submit" -Headers $Headers
        $press = [string]$btn.state
    }
    catch {
        return
    }
    if ($press -in @('unknown', 'unavailable', '')) { return }

    $lastSubmit = if ($entry.PSObject.Properties['LastSubmitAt']) { [string]$entry.LastSubmitAt } else { '' }
    if ($press -eq $lastSubmit) { return }

    # Who pressed it. The card glows while an agent is driving, and this is the only
    # place that can tell: the press itself carries the account behind it. Pending,
    # because the turn this is about to start would otherwise be read as typed in the
    # terminal and hand the session straight back to the person.
    Set-DaemonSessionProperty -Entry $entry -Name 'Driver' -Value (Get-BridgeDriverFromState -State $btn)
    Set-DaemonSessionProperty -Entry $entry -Name 'DriverPending' -Value $true

    try {
        $replyState = Get-HomeAssistantState -EntityId $replyEntity -Headers $Headers
    }
    catch {
        return
    }
    $value = [string]$replyState.state

    # Give the commit time to land before concluding there is nothing to send.
    #
    # Home Assistant commits a text entity when it loses focus, and the tap that
    # commits it IS the tap on Send. The daemon is woken by the button's own state
    # change, so it reads the box within milliseconds of the press - reliably
    # before the typed value has landed. A single short re-read was not enough:
    # the first Send of a message regularly reported "Nothing to send" and it took
    # a second press to get through.
    #
    # Polling briefly costs nothing when the value is already there, which is the
    # common case on the reconcile sweep.
    $attempts = 0
    while (($attempts -lt $script:DaemonConfig.ReplyCommitAttempts) -and
           ([string]::IsNullOrWhiteSpace($value) -or $value -in @('unknown', 'unavailable'))) {
        $attempts++
        Start-Sleep -Milliseconds $script:DaemonConfig.ReplyCommitWaitMs
        try {
            $replyState = Get-HomeAssistantState -EntityId $replyEntity -Headers $Headers
            $value = [string]$replyState.state
        }
        catch { }
    }

    # Acknowledge the press immediately - a press that produces no visible change
    # for even a second reads as a dead button, which is the other half of why it
    # got pressed twice. Which acknowledgement depends on whether the typed text
    # has actually reached Home Assistant yet, so it happens in each branch below
    # rather than unconditionally here: a blanket 'Sending...' on every pass would
    # overwrite the armed message it is meant to sit alongside.
    if ([string]::IsNullOrWhiteSpace($value) -or $value -in @('unknown', 'unavailable')) {
        # An agent setting the text does so through the API, where the value commits
        # the moment it is set - so an empty box really is empty, and arming would
        # leave "Waiting for your text" on the card for the full ten minutes waiting
        # for a person who is not there. Only a person gets the benefit of the doubt.
        $pressedBy = if ($entry.PSObject.Properties['Driver']) { [string]$entry.Driver } else { 'human' }
        if ($pressedBy -eq 'agent') {
            Set-DaemonSessionProperty -Entry $entry -Name 'LastSubmitAt' -Value $press
            Set-DaemonSessionProperty -Entry $entry -Name 'PendingSubmitAt' -Value ''
            # Nothing was sent, so no agent turn is coming. Leaving this armed would
            # hand the glow to whatever the person types next in the terminal.
            Set-DaemonSessionProperty -Entry $entry -Name 'DriverPending' -Value $false
            try {
                Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Nothing to send' -Headers $Headers
            }
            catch { }
            Write-DaemonLog -Message "send for $($sessionId.Substring(0,8)) had an empty box and came from an agent; not armed"
            return
        }

        # The text is almost certainly on screen - it just is not in Home Assistant
        # yet. A text entity only commits when it loses focus or you press Enter,
        # and pressing Send does neither: Home Assistant's own history showed three
        # presses landing before the box was committed even once. Burning the press
        # here is what forced a second one, so it stays armed instead and fires the
        # moment the value arrives.
        $pendingAt = if ($entry.PSObject.Properties['PendingSubmitAt']) { [string]$entry.PendingSubmitAt } else { '' }
        if ($pendingAt -ne $press) {
            Set-DaemonSessionProperty -Entry $entry -Name 'PendingSubmitAt' -Value $press
            Set-DaemonSessionProperty -Entry $entry -Name 'PendingSubmitSince' -Value ([DateTimeOffset]::Now.ToString('o'))
            try {
                Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Waiting for your text' `
                    -Extra @{ hint = 'Press Enter in the box, or tap outside it, and this sends on its own.' } `
                    -Headers $Headers
            }
            catch { }
            Write-DaemonLog -Message "send armed for $($sessionId.Substring(0,8)); the typed text has not reached Home Assistant yet"
            return
        }

        $since = [DateTimeOffset]::MinValue
        if ($entry.PSObject.Properties['PendingSubmitSince']) {
            try { $since = [DateTimeOffset]::Parse([string]$entry.PendingSubmitSince) } catch { }
        }
        if (([DateTimeOffset]::Now - $since).TotalSeconds -lt $script:DaemonConfig.SubmitArmSeconds) {
            # Still armed; say nothing further and look again next pass.
            return
        }

        # Long enough that the box really was empty. Say so rather than doing
        # nothing: silence here is indistinguishable from a broken button.
        Set-DaemonSessionProperty -Entry $entry -Name 'LastSubmitAt' -Value $press
        Set-DaemonSessionProperty -Entry $entry -Name 'PendingSubmitAt' -Value ''
        try {
            Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Nothing to send' `
                -Extra @{ hint = 'Type a reply first, then press Send.' } -Headers $Headers
        }
        catch { }
        Write-DaemonLog -Message "send for $($sessionId.Substring(0,8)) gave up waiting for the typed text"
        return
    }

    Set-DaemonSessionProperty -Entry $entry -Name 'LastSubmitAt' -Value $press
    Set-DaemonSessionProperty -Entry $entry -Name 'PendingSubmitAt' -Value ''
    Set-DaemonSessionProperty -Entry $entry -Name 'LastReply' -Value $value

    try {
        Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Sending...' -Headers $Headers
    }
    catch { }

    [void](Invoke-DaemonReply -SessionId $sessionId -Text $value -Headers $Headers)
}

function Invoke-DaemonReply {
    <#
        Delivers a dashboard reply into the running CLI and clears the box.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][hashtable]$Headers,
        # What to show on the card. A reply carrying attachments is injected as
        # "@C:\...\shot.png your question", which is not what the user typed and
        # should not be echoed back at them.
        [AllowEmptyString()][string]$DisplayText = '',
        # The reply card does not use the text box, so clearing it would wipe
        # anything left sitting there rather than confirming the send.
        [bool]$ClearReplyBox = $true
    )

    $short = $SessionId.Substring(0, [Math]::Min(8, $SessionId.Length))

    # Claude and Codex leave no inuse.<pid>.lock, so their owning process is passed
    # explicitly from the registration their hooks maintain. Without this the
    # injector falls back to the Copilot-only lock file, finds nothing, and the reply
    # box fails silently - which is worse than not offering one.
    #
    # The live set the last reconcile found already has it. Rescanning every
    # registration and the whole process list here cost a noticeable slice of each
    # send, so that is only the fallback.
    $explicitPid = 0
    $known = if ($script:DaemonLive) { $script:DaemonLive[$SessionId] } else { $null }
    $knownAgent = if ($null -ne $known -and $known.PSObject.Properties['Kind']) { Get-DaemonAgent -Kind ([string]$known.Kind) } else { $null }
    if ($null -ne $knownAgent -and $knownAgent.KnowsProcessId -and
        $known.PSObject.Properties['ProcessId'] -and [int]$known.ProcessId -gt 0 -and
        $null -ne (Get-Process -Id ([int]$known.ProcessId) -ErrorAction SilentlyContinue)) {
        $explicitPid = [int]$known.ProcessId
    }
    foreach ($kind in @($script:DaemonAgents.Keys)) {
        if ($explicitPid -gt 0) { break }
        $agent = Get-DaemonAgent -Kind $kind
        if (-not $agent.KnowsProcessId -or -not $agent.FindSessions) { continue }
        $found = (& $agent.FindSessions)[$SessionId]
        if ($null -ne $found) { $explicitPid = [int]$found.ProcessId }
    }

    # For Claude the transcript shows whether the prompt was really submitted, so the
    # send can be confirmed (Confirm-DaemonClaudeSubmit) rather than assumed.
    $claudeTranscript = ''
    $transcriptBefore = 0L
    if ($null -ne $knownAgent -and $knownAgent.TranscriptConfirmsInput -and $known.PSObject.Properties['Transcript'] -and
        [IO.File]::Exists([string]$known.Transcript)) {
        $claudeTranscript = [string]$known.Transcript
        $transcriptBefore = [IO.FileInfo]::new($claudeTranscript).Length
    }

    $delivery = Send-CopilotSessionPrompt -SessionId $SessionId -Text $Text -ProcessId $explicitPid

    if ($delivery.Delivered -and $claudeTranscript) {
        $waitingOnPrompt = $known.PSObject.Properties['HookStatus'] -and [string]$known.HookStatus -eq 'waiting'
        $confirm = Confirm-DaemonClaudeSubmit -ProcessId ([int]$delivery.ProcessId) -Transcript $claudeTranscript `
            -Offset $transcriptBefore -AllowRetry:(-not $waitingOnPrompt)
        if (-not $confirm.Submitted) {
            $delivery.Delivered = $false
            $delivery.Detail = "typed but not submitted ($($confirm.Detail))"
        }
        elseif ($confirm.Retries -gt 0) {
            $delivery.Detail = "$($delivery.Detail); submitted after $($confirm.Retries) extra Enter(s)"
        }
    }

    if ($delivery.Delivered) {
        Write-DaemonLog -Message "reply delivered to $short (pid $($delivery.ProcessId)): $($delivery.Detail)"
    }
    else {
        Write-DaemonLog -Message "reply delivery FAILED for $short : $($delivery.Detail)"
    }

    # Confirm on the card. The box clearing is the only other signal, and on its own
    # it is ambiguous - a cleared box looks the same whether the reply reached the
    # session or vanished. A failure especially must be visible: the whole point of
    # the reply box is that nobody is watching the terminal.
    try {
        $preview = ($(if ([string]::IsNullOrWhiteSpace($DisplayText)) { $Text } else { $DisplayText }) -replace '\s+', ' ').Trim()
        if ($preview.Length -gt 60) { $preview = $preview.Substring(0, 57) + '...' }
        if ($delivery.Delivered) {
            Set-DaemonTransientActivity -SessionId $SessionId -Summary 'Reply sent' `
                -Extra @{ sent = $preview; at = [DateTimeOffset]::Now.ToString('HH:mm:ss') } -Headers $Headers
        }
        else {
            Set-DaemonTransientActivity -SessionId $SessionId -Summary 'Reply NOT sent' `
                -Extra @{ error = [string]$delivery.Detail; unsent = $preview } -Headers $Headers
        }
    }
    catch { }

    # Clear the box either way, so a failed delivery is not silently resent - but only
    # if it still holds what was just sent. Delivery is not instant (a long reply is
    # typed into the console a character at a time), and clearing unconditionally wiped
    # whatever the user had typed in the meantime. Their next Send then found an empty
    # box and reported "Nothing to send", which is what being unable to queue a
    # follow-up reply looks like from the dashboard.
    #
    # The reply box is an optimistic MQTT text entity with no state topic, so its value
    # is cleared with the text.set_value service, not by publishing to a state topic
    # that nothing is subscribed to.
    try {
        if (-not $ClearReplyBox) { return $delivery.Delivered }

        $node = Get-CopilotMqttNodeId -SessionId $SessionId
        $current = $null
        try {
            $current = [string](Get-HomeAssistantState -EntityId "text.${node}_reply" -Headers $Headers).state
        }
        catch {
            # Unreadable: fall through to the clear, which is the safer default.
        }

        if ($null -eq $current -or $current -eq $Text) {
            Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers -Data @{
                entity_id = "text.${node}_reply"
                value = $script:DaemonConfig.ReplyBlankValue
            }
        }
        else {
            Write-DaemonLog -Message "kept a follow-up reply typed for $short while the previous one was delivering"
        }
    }
    catch {
        # The guard hash still prevents a re-delivery even if the clear fails.
    }

    $delivery.Delivered
}

function Test-DaemonClaudePromptSubmitted {
    <#
        Whether Claude recorded a submitted prompt in the transcript bytes appended
        since Offset: a user message (not a tool result), or, while a turn is running,
        a queue entry for it. Claude writes either at the moment of submission.
    #>
    param(
        [Parameter(Mandatory)][string]$Transcript,
        [long]$Offset = 0
    )

    $append = Read-ClaudeTranscriptAppend -Path $Transcript -Offset $Offset
    foreach ($line in @($append.Lines)) {
        if ($line -match '"type":"queue-operation"' -and $line -match '"operation":"enqueue"') { return $true }
        if ($line -notmatch '"type":"user"') { continue }
        $entry = try { $line | ConvertFrom-Json } catch { $null }
        if ($null -eq $entry -or ($entry.PSObject.Properties['isMeta'] -and $entry.isMeta)) { continue }
        $blocks = Get-ClaudeContentBlocks -Message $entry.message
        if (@($blocks | Where-Object { $_.type -eq 'tool_result' }).Count -eq 0) { return $true }
    }
    $false
}

function Confirm-DaemonClaudeSubmit {
    <#
        Confirms a reply typed into Claude was actually submitted, pressing Enter again
        if it was not.

        Claude Code treats a fast burst of more than a few dozen characters as a paste,
        and an Enter that arrives while it is still settling that paste is absorbed
        rather than submitting. The text then sat in the input box, the card said
        "Reply sent", and it went in only with the next reply - run together with it.
        Short replies were unaffected, which is why it looked intermittent.

        The transcript settles it: a submitted prompt is written at once. If nothing
        arrives, the text is still waiting, so Enter is pressed again, twice at most.
        No retry is made while a permission prompt is pending (AllowRetry off), where
        a stray Enter could accept it.
    #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$Transcript,
        [long]$Offset = 0,
        [switch]$AllowRetry,
        [int]$WaitMs = 1200,
        [int]$MaxRetries = 2
    )

    $result = [pscustomobject]@{ Submitted = $false; Retries = 0; Detail = '' }
    $attempt = 0
    while ($true) {
        $deadline = [DateTimeOffset]::Now.AddMilliseconds($WaitMs)
        while ([DateTimeOffset]::Now -lt $deadline) {
            if (Test-DaemonClaudePromptSubmitted -Transcript $Transcript -Offset $Offset) {
                $result.Submitted = $true
                $result.Retries = $attempt
                return $result
            }
            Start-Sleep -Milliseconds 100
        }

        if (-not $AllowRetry) { $result.Detail = 'no submit seen; not retried while a prompt is pending'; break }
        if ($attempt -ge $MaxRetries) { $result.Detail = "no submit seen after $attempt extra Enter(s)"; break }

        $attempt++
        try {
            $outcome = Invoke-BridgeConsoleSend -ProcessId $ProcessId -Text '' -Submit $true -DelayMs 0
            if (-not ([string]$outcome).StartsWith('ok:')) { $result.Detail = "extra Enter failed: $outcome"; break }
        }
        catch {
            $result.Detail = "extra Enter failed: $($_.Exception.Message)"
            break
        }
    }
    $result.Retries = $attempt
    $result
}

function Resolve-SessionFromReplyEntity {
    param(
        [Parameter(Mandatory)][string]$EntityId,
        [Parameter(Mandatory)][hashtable]$State
    )

    foreach ($sessionId in @($State.Keys)) {
        $node = Get-CopilotMqttNodeId -SessionId $sessionId
        if ($EntityId -eq "text.${node}_reply") { return $sessionId }
    }
    $null
}

function Resolve-DaemonPrimedCard {
    <#
        Builds the (summary, detail) a restart should re-publish for a session from its
        persisted display state, so a restart restores the card rather than blanking
        it. Reasoning is included only when verbose is on, matching the reconcile, and
        a session with no remembered activity falls back to a generic label.
    #>
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][ValidateSet('working', 'waiting', 'idle')][string]$Status,
        [bool]$VerboseOn
    )

    $summary = if ($Entry.PSObject.Properties['LastSummary'] -and -not [string]::IsNullOrWhiteSpace([string]$Entry.LastSummary)) {
        [string]$Entry.LastSummary
    }
    elseif ($Status -eq 'working') { 'Working' } else { 'Idle' }

    $detail = @{
        session = $Entry.Name
        machine = $Entry.Machine
        verbose = $VerboseOn
        updated = [DateTimeOffset]::Now.ToString('o')
    }
    if ($Entry.PSObject.Properties['LastHistory'] -and $Entry.LastHistory) {
        $detail['history'] = @($Entry.LastHistory)
    }
    # Driver is persisted with the entry, so a restart restores the glow rather than
    # quietly handing a session an agent is still driving back to you.
    $detail['driver'] = if ($Entry.PSObject.Properties['Driver'] -and $Entry.Driver) { [string]$Entry.Driver } else { 'human' }
    Add-DaemonCardText -Entry $Entry -Detail $detail -VerboseOn $VerboseOn

    [pscustomobject]@{ Summary = $summary; Detail = $detail }
}
