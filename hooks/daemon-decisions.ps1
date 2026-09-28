<#
    Bridge daemon: questions and approvals.

    Arms question cards, delivers the answers chosen on them into the session's own
    prompt, and does the same for Codex approvals.

    Part of agent-bridge-daemon.ps1, which dot-sources it into its own scope after
    declaring the shared $script: state; see docs/daemon-split.md.
    Shared state it changes: DaemonTerminalOnlyWarned.
#>

function Invoke-PendingDecisions {
    <#
        Feeds Home Assistant answers into a live ask_user prompt, and clears the card
        when the ask_user is answered by either input.

        This is the Home-Assistant half of dual-input ask_user. The non-blocking hook
        arms the card and writes a marker; the native terminal prompt is answerable the
        whole time. For each session with a marker:

          - If the transcript shows the ask_user already completed (answered in the
            terminal, or by a previous injection), clear the card, blank the reply box
            and delete the marker (Complete-DaemonAnsweredDecision).

          - If the ask_user is still pending and Home Assistant holds an answer that has
            not been injected yet (Read-DaemonDecisionAnswer), inject it into the native
            prompt. A freeform answer (reply box) is typed in as text; a choice
            (selector) is handled by the choice-injection strategy. Pending-ness is
            re-checked immediately before injecting so a terminal answer that just
            landed is never double-answered.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Live
    )

    foreach ($sessionId in @($State.Keys)) {
        if (-not $Live.ContainsKey($sessionId)) { continue }
        $marker = Get-CopilotDecisionMarker -SessionId $sessionId
        if ($null -eq $marker) { continue }

        $session = $Live[$sessionId]
        $askState = Get-DaemonAskUserState -Session $session -Marker $marker

        # The hook writes the marker just before the tool runs, so the start event may
        # not be in the transcript yet. Wait a cycle rather than acting on a stale one.
        if (-not $askState.Started) { continue }

        if (-not $askState.Pending) {
            Complete-DaemonAnsweredDecision -SessionId $sessionId -Marker $marker -AskState $askState -State $State -Headers $Headers
            continue
        }

        Confirm-DaemonDecisionArmed -SessionId $sessionId -Marker $marker -State $State -Headers $Headers

        # Some prompts cannot be driven from the dashboard at all - more fields than
        # it publishes dropdowns for, or more than one free-text field. The native
        # prompt is an arrow-key form, and characters typed at it are discarded, so
        # injecting anything here would lose the answer and leave the prompt waiting.
        # The card says to answer in the terminal; this makes sure nothing is sent.
        $terminalOnly = $false
        if ($marker.PSObject.Properties['terminalOnly']) { $terminalOnly = [bool]$marker.terminalOnly }
        if ($terminalOnly) {
            $decisionKey = [string]$marker.decisionId
            if (-not $script:DaemonTerminalOnlyWarned.ContainsKey($decisionKey)) {
                $script:DaemonTerminalOnlyWarned[$decisionKey] = $true
                Write-DaemonLog -Message "decision for $($sessionId.Substring(0,8)) must be answered in the terminal; not injecting"
            }
            continue
        }

        $read = Read-DaemonDecisionAnswer -SessionId $sessionId -Marker $marker -State $State -Headers $Headers
        if ($null -eq $read -or [string]::IsNullOrWhiteSpace($read.Answer)) { continue }
        if ($read.Answer -eq [string]$marker.injectedAnswer) { continue }

        # Re-verify the ask_user is still pending right before injecting, so a terminal
        # answer that landed in the last second is never double-answered.
        $recheck = Get-DaemonAskUserState -Session $session -Marker $marker
        if (-not $recheck.Pending) { continue }

        [void](Invoke-DaemonDecisionAnswer -SessionId $sessionId -Marker $marker `
            -Answer $read.Answer -IsChoice $read.IsChoice -Selections $read.Selections -Headers $Headers)
    }
}

function Complete-DaemonAnsweredDecision {
    <#
        Tidies up after a question answered by either input: checks that an injected
        selection is what the CLI recorded - and says so, to the card and the session,
        when it is not - then clears the card, blanks the reply box and removes the
        marker.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$Marker,
        [Parameter(Mandatory)]$AskState,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $sessionId = $SessionId
    $marker = $Marker
    $askState = $AskState
    $node = Get-CopilotMqttNodeId -SessionId $sessionId

    # Before tearing the card down, check that an injected selection is the one the
    # CLI recorded.
    #
    # The injector drives an arrow-key list by index, so a dropped keystroke selects
    # the neighbouring option and the prompt reports it as the user's choice. Nothing
    # downstream can tell - it is a confident wrong answer in the user's name - so it
    # has to be caught here and said out loud.
    try {
        $injected = @($marker.injectedSelections)
        if ($injected.Count -gt 0 -and -not (Test-CopilotAnswerMatchesSelections `
                -ResultContent ([string]$askState.ResultContent) `
                -Fields @($marker.fields) -Selections $injected)) {
            Write-DaemonLog -Message "MISMATCH for $($sessionId.Substring(0,8)): sent [$($injected -join ' | ')] but the CLI recorded something else"
            Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Answer may be wrong - check the terminal' `
                -Extra @{ sent = ($injected -join ' | '); recorded = ([string]$askState.ResultContent) } -Headers $Headers | Out-Null

            # Saying it on the card is not enough: the agent carries straight on from
            # the wrong answer, and the warning is overwritten by its next activity
            # update within seconds. So tell the session itself. Typed text is the one
            # delivery path that is reliable here - it is how every reply is sent -
            # which makes this correction land even though the keystrokes that caused
            # the problem did not.
            try {
                $correction = Get-DaemonAnswerCorrection -Fields @($marker.fields) -Selections $injected
                $fix = Send-CopilotSessionPrompt -SessionId $sessionId -Text $correction `
                    -ProcessId (Get-DaemonSessionProcessId -SessionId $sessionId)
                if ($fix.Delivered) {
                    Write-DaemonLog -Message "sent a correction to $($sessionId.Substring(0,8)) with what was actually chosen"
                }
                else {
                    Write-DaemonLog -Message "could not correct $($sessionId.Substring(0,8)): $($fix.Detail)"
                }
            }
            catch {
                Write-DaemonLog -Message "correction failed for $sessionId : $($_.Exception.Message)"
            }
        }
    }
    catch { }

    try {
        Clear-CopilotMqttDecision -SessionId $sessionId `
            -SessionName ([string]$State[$sessionId].Name) `
            -Machine ([string]$State[$sessionId].Machine) -Headers $Headers | Out-Null
        Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers `
            -Data @{ entity_id = "text.${node}_reply"; value = $script:DaemonConfig.ReplyBlankValue } | Out-Null
    }
    catch {
        Write-DaemonLog -Message "decision clear failed for $sessionId : $($_.Exception.Message)"
    }
    Remove-CopilotDecisionMarker -SessionId $sessionId
    $entry = $State[$sessionId]
    if ($entry.PSObject.Properties['LastReply']) { $entry.LastReply = '' }
    Write-DaemonLog -Message "decision answered (either input); cleared card for $($sessionId.Substring(0,8))"
}

function Confirm-DaemonDecisionArmed {
    <#
        Arms a question's card from its marker when the card is not armed.

        A hook whose Home Assistant work was cut short by its deadline leaves a marker
        with no card behind it, so an outage during the hook would otherwise silently
        cost the question its dashboard card.

        Armed-ness is read from the question attribute, not the option count. A
        freeform question legitimately publishes a single-option selector, so counting
        options treated every freeform card as unarmed and re-published it on every
        reconcile - observed as the same line repeating every 18 seconds for minutes on
        end, each one resetting the card the user was looking at.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$Marker,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $node = Get-CopilotMqttNodeId -SessionId $SessionId
    try {
        $armed = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
        if ([string]::IsNullOrWhiteSpace([string]$armed.attributes.question)) {
            Set-CopilotMqttDecision -SessionId $SessionId `
                -SessionName ([string]$State[$SessionId].Name) `
                -Machine ([string]$State[$SessionId].Machine) `
                -Question ([string]$Marker.question) `
                -Choices @($Marker.choices) -Fields @($Marker.fields) `
                -DecisionId ([string]$Marker.decisionId) -Headers $Headers | Out-Null
            Write-DaemonLog -Message "armed card from marker for $($SessionId.Substring(0,8)) (hook could not reach Home Assistant)"
        }
    }
    catch {
        Write-DaemonLog -Message "marker re-arm check failed for $SessionId : $($_.Exception.Message)"
    }
}

function Read-DaemonDecisionAnswer {
    <#
        What the card holds as the answer to a pending question, as
        { Answer, Selections, IsChoice }: a submitted form (Read-DaemonFormAnswer), the
        selector's choice, or the reply box's text. Answer is '' when there is nothing
        to send yet; $null when the card could not be read.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$Marker,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $node = Get-CopilotMqttNodeId -SessionId $SessionId
    $isChoice = ([string]$Marker.mode -eq 'multiple_choice')
    $answer = ''
    $selections = @()
    try {
        if (@($Marker.fields).Count -gt 1) {
            $form = Read-DaemonFormAnswer -SessionId $SessionId -Marker $Marker -State $State -Headers $Headers
            $answer = $form.Answer
            $selections = @($form.Selections)
        }
        elseif ($isChoice) {
            $sel = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
            $s = [string]$sel.state
            if ($s -notin @('Idle', 'Awaiting answer...', 'unknown', 'unavailable', '')) { $answer = $s }
        }
        else {
            $rep = Get-HomeAssistantState -EntityId "text.${node}_reply" -Headers $Headers
            $r = [string]$rep.state
            # Whitespace is the blank sentinel the reply box is parked on, not an
            # answer, so it must not be injected.
            if (-not [string]::IsNullOrWhiteSpace($r) -and
                $r -notin @('unknown', 'unavailable')) { $answer = $r }
        }
    }
    catch {
        return $null
    }
    [pscustomobject]@{ Answer = $answer; Selections = $selections; IsChoice = $isChoice }
}

function Read-DaemonFormAnswer {
    <#
        A multi-field form's answer, as { Answer, Selections }, once it has been
        submitted with every field chosen; Answer is '' until then.

        One dropdown per field. Cancel still rides on the main selector, and the answer
        is only complete once every field has been chosen - a half-filled form must not
        be injected.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$Marker,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $sessionId = $SessionId
    $marker = $Marker
    $node = Get-CopilotMqttNodeId -SessionId $sessionId
    $markerFields = @($marker.fields)
    $answer = ''
    $selections = @()

    $sel = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
    if ([string]$sel.state -eq 'Cancel request') {
        return [pscustomobject]@{ Answer = 'Cancel request'; Selections = @() }
    }

    $picked = @()
    $missingChoice = $false
    for ($fi = 1; $fi -le $markerFields.Count; $fi++) {
        $markerField = $markerFields[$fi - 1]

        # A free-text field has no dropdown - it is answered in the Reply box, which
        # is what makes a mixed form answerable at all. Its slot is collapsed, so read
        # the box instead.
        #
        # An empty box is a valid answer. A free-text field is usually the optional
        # "anything else?" one, and requiring it refused perfectly good submissions:
        # every dropdown chosen, nothing to add, Send rejected. The prompt accepts an
        # empty field the same way the terminal does - by committing it untouched.
        if (Test-DecisionFieldIsText -Field $markerField) {
            $v = ''
            try {
                $rep = Get-HomeAssistantState -EntityId "text.${node}_reply" -Headers $Headers
                $v = [string]$rep.state
            }
            catch { }
            if ([string]::IsNullOrWhiteSpace($v) -or $v -in @('unknown', 'unavailable')) { $v = '' }
            $picked += $v
            continue
        }

        $fs = Get-HomeAssistantState `
            -EntityId (Get-CopilotMqttFieldEntityId -Node $node -Index $fi) -Headers $Headers
        $v = [string]$fs.state
        if ($v -in @('Choose...', 'Idle', 'unknown', 'unavailable', '')) {
            $missingChoice = $true
            break
        }
        $picked += $v
    }
    if ($missingChoice) { $picked = @() }

    # Every field chosen is not enough: a multi-field answer is only sent when Submit
    # is pressed, so selections can be reviewed and changed first. An MQTT button's
    # state is the timestamp of its last press, so a press counts only if it is newer
    # than the moment this question was armed - otherwise a press left over from a
    # previous question would fire this one instantly.
    $submitted = $false
    $pressIsNew = $false
    $pressedAt = ''
    try {
        $btn = Get-HomeAssistantState -EntityId "button.${node}_submit" -Headers $Headers
        $pressedAt = [string]$btn.state
        if ($pressedAt -notin @('unknown', 'unavailable', '')) {
            $armedAt = [datetimeoffset][string]$marker.armedAt
            $pressIsNew = ([datetimeoffset]$pressedAt) -gt $armedAt
        }
    }
    catch {
        # No button (older session): fall back to submitting as soon as every field is
        # chosen rather than hanging.
        $pressIsNew = ($picked.Count -eq $markerFields.Count)
    }

    if ($pressIsNew -and $picked.Count -ne $markerFields.Count) {
        # Pressed with something still unanswered. Saying which is missing is the
        # difference between a button that looks broken and one that is waiting on you.
        $missing = @()
        for ($fi = 0; $fi -lt $markerFields.Count; $fi++) {
            if ($fi -lt $picked.Count) { continue }
            $missing += [string]$markerFields[$fi].Label
        }
        try {
            Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Not sent - answer every field' `
                -Extra @{ waiting_on = ($missing -join ', ') } -Headers $Headers | Out-Null
        }
        catch { }
        Write-DaemonLog -Message "submit pressed for $($sessionId.Substring(0,8)) with fields still unanswered"
    }

    if ($pressIsNew -and $picked.Count -eq $markerFields.Count) {
        $submitted = $true
        if (-not [string]::IsNullOrWhiteSpace($pressedAt)) {
            # Consume the press so the same one cannot also be read as a Send for the
            # reply box afterwards.
            $entry = $State[$sessionId]
            if ($entry.PSObject.Properties['LastSubmitAt']) { $entry.LastSubmitAt = $pressedAt }
            else { $entry | Add-Member -NotePropertyName LastSubmitAt -NotePropertyValue $pressedAt -Force }
        }
        # Acknowledge the press before the injection, which takes a noticeable moment
        # for a multi-field form.
        try {
            Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Sending answer...' `
                -Extra @{ answer = ($picked -join ' + ') } -Headers $Headers | Out-Null
        }
        catch { }
    }

    if ($submitted) {
        $selections = @($picked)
        $answer = ($picked -join ' + ')
    }
    [pscustomobject]@{ Answer = $answer; Selections = $selections }
}

function Get-DaemonAskUserState {
    <#
        Whether a session's question is still waiting, from its transcript, in the
        format its agent writes. Copilot's reader cannot see a Claude question at all,
        which left every Claude card armed forever and its dropdown doing nothing.
    #>
    param(
        [Parameter(Mandatory)]$Session,

        # The pending-decision marker, when there is one: it names the question the
        # card is for, so a Claude card is judged by its own question's answer rather
        # than by whichever question the transcript happens to show last.
        [AllowNull()]$Marker = $null
    )

    & (Get-DaemonAgent -Kind (Get-DaemonEntryKind -Entry $Session)).AskUserState $Session $Marker
}

function Complete-DaemonClaudeAnswer {
    <#
        Makes sure an answer driven into a Claude question was submitted.

        The option is chosen by arrow keys and Enter, but Claude can finish on a review
        screen that needs one more Enter. If the question is still pending once the keys
        have had time to land, Enter is pressed once, and the result is reported as
        delivered only when the transcript shows the question answered. Agents whose
        transcript cannot show that (TranscriptConfirmsInput) are returned unchanged.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$Delivery,
        [AllowNull()]$Marker = $null,
        [int]$WaitMs = 1500
    )

    $session = if ($script:DaemonLive) { $script:DaemonLive[$SessionId] } else { $null }
    if ($null -eq $session -or -not $session.PSObject.Properties['Kind'] -or
        -not (Get-DaemonAgent -Kind ([string]$session.Kind)).TranscriptConfirmsInput) { return $Delivery }

    $answered = {
        $deadline = [DateTimeOffset]::Now.AddMilliseconds($WaitMs)
        while ([DateTimeOffset]::Now -lt $deadline) {
            if (-not (Get-DaemonAskUserState -Session $session -Marker $Marker).Pending) { return $true }
            Start-Sleep -Milliseconds 150
        }
        $false
    }

    if (& $answered) { return $Delivery }

    try {
        [void](Invoke-BridgeConsoleSend -ProcessId ([int]$Delivery.ProcessId) -Text '' -Submit $true -DelayMs 0)
    }
    catch { }

    if (& $answered) {
        $Delivery.Detail = "$($Delivery.Detail); submitted with an extra Enter"
        return $Delivery
    }

    $Delivery.Delivered = $false
    $Delivery.Detail = "keys sent but the question is still waiting ($($Delivery.Detail))"
    $Delivery
}

function Invoke-DaemonDecisionAnswer {
    <#
        Injects a single Home Assistant answer into a live ask_user prompt. Freeform
        answers are typed as text; choices are handled by the choice-injection
        strategy. Marks the marker as injected on success so it is not repeated, and
        blanks the Home Assistant input field.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][object]$Marker,
        [Parameter(Mandatory)][string]$Answer,
        [Parameter(Mandatory)][bool]$IsChoice,
        [AllowEmptyCollection()][string[]]$Selections = @(),
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $short = $SessionId.Substring(0, [Math]::Min(8, $SessionId.Length))
    $node = Get-CopilotMqttNodeId -SessionId $SessionId
    # Claude and Codex leave no lock file for the injector to find their process by.
    $processId = Get-DaemonSessionProcessId -SessionId $SessionId

    if ($IsChoice) {
        # The native prompt is one arrow-key option list per field (tabbed when there
        # is more than one). Selecting by index returns the schema's real value for
        # each field, so prefer that; the per-field "Other (type your answer)" text
        # path is only a fallback when the option cannot be located.
        $fields = @($Marker.fields)
        $sel = @($Selections)
        if ($sel.Count -eq 0 -and $fields.Count -eq 1) {
            # Single-field choice: the selector's value is the field's option.
            $sel = @($Answer)
        }

        $delivery = $null
        if ($fields.Count -gt 0 -and $sel.Count -eq $fields.Count) {
            $delivery = Send-CopilotSessionForm -SessionId $SessionId -Fields $fields -Selections $sel -ProcessId $processId
        }
        if ($null -eq $delivery -or -not $delivery.Delivered) {
            if ($null -ne $delivery) {
                Write-DaemonLog -Message "form injection unavailable for $short ($($delivery.Detail)); falling back to text"
            }
            $delivery = Send-CopilotSessionChoice -SessionId $SessionId -Text $Answer `
                -ChoiceCount (@($Marker.choices).Count) -ProcessId $processId
        }
    }
    else {
        $delivery = Send-CopilotSessionPrompt -SessionId $SessionId -Text $Answer -ProcessId $processId
    }

    # Claude may end on a review screen after the last question's option is chosen, so
    # a question still pending once the keys have landed gets one Enter to submit it.
    if ($delivery.Delivered) {
        $delivery = Complete-DaemonClaudeAnswer -SessionId $SessionId -Delivery $delivery -Marker $Marker
    }

    if ($delivery.Delivered) {
        Set-CopilotDecisionMarkerInjected -SessionId $SessionId -Answer $Answer -Selections @($Selections)
        try {
            Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers `
                -Data @{ entity_id = "text.${node}_reply"; value = $script:DaemonConfig.ReplyBlankValue }
        }
        catch { }
        try {
            $shown = ($Answer -replace '\s+', ' ').Trim()
            if ($shown.Length -gt 60) { $shown = $shown.Substring(0, 57) + '...' }
            Set-DaemonTransientActivity -SessionId $SessionId -Summary 'Answer sent' `
                -Extra @{ answer = $shown; at = [DateTimeOffset]::Now.ToString('HH:mm:ss') } -Headers $Headers
        }
        catch { }
        Write-DaemonLog -Message "decision answer injected to $short (pid $($delivery.ProcessId)): $($delivery.Detail)"
    }
    else {
        try {
            Set-DaemonTransientActivity -SessionId $SessionId -Summary 'Answer NOT sent' `
                -Extra @{ error = [string]$delivery.Detail } -Headers $Headers
        }
        catch { }
        Write-DaemonLog -Message "decision answer injection FAILED for $short : $($delivery.Detail)"
    }
    $delivery.Delivered
}

function Invoke-PendingCodexApprovals {
    <#
        Delivers a dashboard answer into a Codex approval prompt.

        Codex runs its PermissionRequest hook before showing its own approval UI, and
        a hook that writes nothing to stdout returns "no decision", so the terminal
        prompt appears as usual. That makes the card a second input rather than a
        replacement: whichever is used first wins, exactly as with Copilot's ask_user.

        The marker written by the hook is the gate. It is removed by the next hook
        event for that session - a tool starting, or the turn ending - because either
        proves the prompt is no longer waiting.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Live
    )

    foreach ($sessionId in @($Live.Keys)) {
        $session = $Live[$sessionId]
        # Only an agent whose hook records approvals (Codex) has any to answer.
        $readMarker = (Get-DaemonAgent -Kind ([string]$session.Kind)).ApprovalMarker
        if (-not $readMarker) { continue }

        $marker = & $readMarker $sessionId
        if ($null -eq $marker) { continue }

        $node = Get-CopilotMqttNodeId -SessionId $sessionId
        $choice = ''
        try {
            $selector = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
            $choice = [string]$selector.state
        }
        catch { continue }

        if ($choice -notin @('Approve', 'Deny')) { continue }

        # Codex's approval prompt is a keyboard UI, so the answer is typed into the
        # session the same way a reply is. Approve sends y, deny sends n, which is
        # what its prompt accepts.
        $keystroke = if ($choice -eq 'Approve') { 'y' } else { 'n' }
        $short = $sessionId.Substring(0, [Math]::Min(8, $sessionId.Length))
        $delivery = Send-CopilotSessionPrompt -SessionId $sessionId -Text $keystroke `
            -ProcessId ([int]$session.ProcessId)

        if ($delivery.Delivered) {
            Write-DaemonLog -Message "codex approval '$choice' delivered to $short (pid $($delivery.ProcessId))"
        }
        else {
            Write-DaemonLog -Message "codex approval delivery FAILED for $short : $($delivery.Detail)"
        }

        # Clear either way, so a failed delivery is not resent on every reconcile.
        # The hook clears the marker itself once the prompt is genuinely answered.
        try {
            Clear-CopilotMqttDecision -SessionId $sessionId `
                -SessionName ([string]$State[$sessionId].Name) `
                -Machine ([string]$State[$sessionId].Machine) -Headers $Headers
        }
        catch { }
    }
}

function Get-DaemonAnswerCorrection {
    <#
        Composes the message sent to a session whose answer was delivered wrongly.

        The prompt is driven by arrow keys, and a keystroke that fails to register - or
        registers twice - selects a different option and the CLI records it as the
        user's choice. Nothing downstream can tell, so the agent proceeds confidently
        on an answer the user never gave.

        Naming both what was chosen and what to ignore matters: a bare restatement
        reads like a new instruction, and the agent has no reason to connect it to the
        question it just had answered.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Fields,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Selections
    )

    $lines = for ($i = 0; $i -lt $Fields.Count -and $i -lt $Selections.Count; $i++) {
        $label = [string]$Fields[$i].Label
        $value = [string]$Selections[$i]
        if ([string]::IsNullOrWhiteSpace($value)) { $value = '(left blank)' }
        "  - $label : $value"
    }

    @(
        'Correction from the Home Assistant bridge: the answer just recorded for your'
        'last question is WRONG - it was mis-delivered to the prompt, not chosen by me.'
        'Disregard it. What I actually selected was:'
        ''
        ($lines -join "`n")
        ''
        'Please continue using these values.'
    ) -join "`n"
}
