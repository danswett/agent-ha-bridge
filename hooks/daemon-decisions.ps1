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

        # What the card already held when this question arrived. Until that is known,
        # nothing on it can be told apart from an answer, so nothing is read as one.
        if (-not (Confirm-DaemonDecisionBaseline -SessionId $sessionId -Marker $marker -Headers $Headers)) { continue }

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
            -Answer $read.Answer -IsChoice $read.IsChoice -IsFreeText $read.IsFreeText `
            -Selections $read.Selections -PayloadStamp $read.PayloadStamp `
            -State $State -Headers $Headers)
    }
}

function Complete-DaemonAnsweredDecision {
    <#
        Tidies up after a question answered by either input: checks that an injected
        selection is what the CLI recorded, reports uncertainty or a mismatch without
        overwriting the terminal answer, then clears the card and removes the marker.
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

    # A differing result can also be a competing terminal answer. Report it, but do
    # not type a correction that turns an uncertain input attempt into user intent.
    try {
        $injected = @()
        if ($marker.PSObject.Properties['injectedSelections']) { $injected = @($marker.injectedSelections) }
        if ($injected.Count -gt 0) {
            $content = if ($askState.PSObject.Properties['ResultContent']) { $askState.ResultContent } else { $null }
            $verification = Test-CopilotAnswerMatchesSelections -ResultContent $content `
                -Fields @($marker.fields) -Selections $injected -Detailed
            if ($verification.Status -ceq 'Mismatch') {
                Write-DaemonLog -Message "MISMATCH for $($sessionId.Substring(0,8)); terminal result retained"
                Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Answer differs - check the terminal' `
                    -Extra @{ sent = ($injected -join ' | '); verification = 'Mismatch' } -Headers $Headers | Out-Null
            }
            elseif ($verification.Status -ceq 'Unconfirmed') {
                Write-DaemonLog -Message "answer unconfirmed for $($sessionId.Substring(0,8)); terminal result retained"
                Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Answer unconfirmed - check the terminal' `
                    -Extra @{ verification = 'Unconfirmed' } -Headers $Headers | Out-Null
            }
        }
    }
    catch { Write-DaemonLog -Message "decision verification unavailable for $sessionId : $($_.Exception.Message)" }

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

function Test-DaemonDecisionUsesFields {
    <#
        Whether a question is answered through its field slots rather than the main
        selector.

        Read off the card rather than re-derived: Set-CopilotMqttDecision publishes
        multi_field beside the question, from the same decision that put the controls
        on screen, so this cannot disagree with what is there. The marker's own field
        list is not that decision - Claude's parser keeps a field in the marker for
        the keystrokes while publishing its options on the main selector - and reading
        it instead would send the daemon looking at a slot that was never armed.

        The marker is only the fallback, for a card armed before the attribute existed.
    #>
    param(
        [Parameter(Mandatory)]$Marker,
        [AllowNull()]$DecisionState
    )

    $attrs = if ($null -ne $DecisionState -and $DecisionState.PSObject.Properties['attributes']) {
        $DecisionState.attributes
    } else { $null }
    if ($null -ne $attrs -and $attrs.PSObject.Properties['multi_field']) { return [bool]$attrs.multi_field }
    @($Marker.fields).Count -gt 1
}

function Test-DaemonMarkedGuardError {
    <#
        Whether an error is the test boundary refusing a forbidden operation rather
        than an ordinary failure. The shared check, under the daemon's own name for
        its call sites; it walks the whole exception chain, because a guard thrown
        inside something that wraps it still has to come back out.
    #>
    param([Parameter(Mandatory)]$ErrorRecord)
    Test-DecisionMarkedGuardError -ErrorRecord $ErrorRecord
}

function Get-DaemonDecisionChannelState {
    <#
        What one of a question's input channels holds right now, as
        { State; Value; Snapshot }. See Get-CopilotDecisionChannelObservation for why
        'absent' and 'unknown' are kept apart and why a single snapshot carries both
        an identity and the body that goes with it.
    #>
    param(
        [Parameter(Mandatory)][string]$EntityId,
        [Parameter(Mandatory)][hashtable]$Headers
    )
    Get-CopilotDecisionChannelObservation -EntityId $EntityId -Headers $Headers
}

function Confirm-DaemonDecisionBaseline {
    <#
        Whether this question has a baseline recorded - what its answer channels
        already held when it was armed - so that everything afterwards is "has this
        changed", never "is this newer".

        Normally there already is one: the hook records it as it arms the question,
        which is the boundary that matters, because an answer given between arming
        and the first daemon sweep would otherwise be read later and adopted as
        "what was already there". This establishes one only for a question armed
        before that existed, or by a hook that could not reach Home Assistant.

        It is a file of its own, created atomically and named for the question, so
        establishing it twice is a no-op and a replacement question cannot disturb
        it. Returns $false when there is none and one could not be established, and
        then nothing is read as an answer this pass: an unreadable card is not
        consent.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$Marker,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $decisionId = if ($null -ne $Marker -and $Marker.PSObject.Properties['decisionId']) { [string]$Marker.decisionId } else { '' }
    $node = Get-CopilotMqttNodeId -SessionId $SessionId
    $result = Initialize-CopilotDecisionBaseline -SessionId $SessionId -DecisionId $decisionId `
        -PayloadEntityId "sensor.${node}_reply_payload" -SubmitEntityId "button.${node}_submit" -Headers $Headers
    if (-not $result.Recorded) {
        Write-DaemonLog -Message "no baseline for $($SessionId.Substring(0,8)): $($result.Reason); not reading an answer this pass"
        return $false
    }
    $true
}

function Test-DaemonChannelChanged {
    <#
        Whether a channel now holds something that is determinately not what it held
        when the question was armed.

        Only present-and-different counts. Every other combination is refused on
        purpose: unknown either side means nobody can tell, and absent-now means
        whatever was there has gone rather than that something new has arrived.
    #>
    param(
        [Parameter(Mandatory)]$Baseline,
        [Parameter(Mandatory)]$Current
    )

    if ($Current.State -ne 'present') { return $false }
    if ($Baseline.State -eq 'unknown') { return $false }
    if ($Baseline.State -eq 'absent') { return $true }
    -not [StringComparer]::Ordinal.Equals([string]$Current.Value, [string]$Baseline.Value)
}

function Test-DaemonSendPressed {
    <#
        Whether Send has actually been pressed for this question, as
        { Pressed, Readable, Exists, At }.

        Pressed means the button's press stamp is determinately not the one recorded
        when the question was armed - never that it looks newer, because the stamp is
        Home Assistant's clock and the baseline could have come from anywhere.

        Readable and Exists are separate on purpose. A button that is not on this
        session's card at all is worth saying out loud; one that is there and has
        simply never been pressed is not, and nor is one that could not be read this
        pass. Collapsing them would print "no Send button on this session" at a card
        that has one.

        A missing or unreadable button is never Pressed. It used to fall back to
        "submit as soon as every field is chosen", which manufactures a submission out
        of somebody part-way through filling a form in and is precisely what "every
        answer needs Send" must not do.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$Marker,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $node = Get-CopilotMqttNodeId -SessionId $SessionId
    $current = Get-DaemonDecisionChannelState -EntityId "button.${node}_submit" -Headers $Headers
    if ($current.State -eq 'unknown') {
        return [pscustomobject]@{ Pressed = $false; Readable = $false; Exists = $current.Exists; At = '' }
    }

    $baseline = Get-CopilotDecisionMarkerBaseline -Marker $Marker -Channel 'submit' -SessionId $SessionId
    $pressed = Test-DaemonChannelChanged -Baseline $baseline -Current $current
    [pscustomobject]@{ Pressed = $pressed; Readable = $true; Exists = $current.Exists; At = $current.Value }
}

function Read-DaemonDecisionCardText {
    <#
        Text the reply card published as an answer to the question now armed, with the
        identity of that publish, or empty when there is none.

        The reply card is the box every other part of a session card uses, and until
        card 1.22.0 the dashboard swapped it out for a plain entity row the moment a
        question arrived - because the daemon only ever read the selector. So on a
        choice question, whose native prompt always offers "Other (type your answer)",
        a typed answer went nowhere: the box was on screen, Send worked, and nothing
        anywhere recorded that the words had been thrown away.

        Only a payload determinately different from the one recorded when the question
        was armed counts. Anything still matching the baseline belongs to the reply
        path, which delivers it once the card clears.

        The identity and the words come out of one snapshot. Reading them one after
        the other let a publish landing in between pair this message's identity with
        the previous message's words - and the identity is what gets marked consumed,
        so the wrong answer would have been submitted and recorded as delivered.

        A payload carrying attachments is left alone entirely. An image cannot be
        typed into an arrow-key prompt, and consuming it here would destroy it; the
        reply path stages and delivers it properly once the question is gone.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$Marker,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $node = Get-CopilotMqttNodeId -SessionId $SessionId
    $empty = [pscustomobject]@{ Text = ''; Stamp = '' }

    $baseline = Get-CopilotDecisionMarkerBaseline -Marker $Marker -Channel 'payload' -SessionId $SessionId
    if ($baseline.State -eq 'unknown') { return $empty }

    $current = Get-DaemonDecisionChannelState -EntityId "sensor.${node}_reply_payload" -Headers $Headers
    if (-not (Test-DaemonChannelChanged -Baseline $baseline -Current $current)) { return $empty }

    $state = $current.Snapshot
    $attrs = if ($null -ne $state -and $state.PSObject.Properties['attributes']) { $state.attributes } else { $null }
    if ($null -eq $attrs) { return $empty }
    foreach ($name in @('images', 'files')) {
        if ($attrs.PSObject.Properties[$name] -and @($attrs.$name).Count -gt 0) { return $empty }
    }
    $text = if ($attrs.PSObject.Properties['text']) { [string]$attrs.text } else { '' }
    if ([string]::IsNullOrWhiteSpace($text)) { return $empty }
    [pscustomobject]@{ Text = $text; Stamp = $current.Value }
}

function Read-DaemonDecisionAnswer {
    <#
        What the card holds as the answer to a pending question, as
        { Answer, Selections, IsChoice, IsFreeText, PayloadStamp }: a submitted form
        (Read-DaemonFormAnswer), the selector's choice, text typed into the reply card,
        or the reply box's text. Answer is '' when there is nothing to send yet; $null
        when the card could not be read.

        IsFreeText says the answer was typed rather than chosen, so a choice question
        answered in words is delivered through the prompt's own "Other" entry rather
        than hunted for in an option list it was never in.
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
    $isFreeText = $false
    $stamp = ''
    # Which controls the card is showing is read from the card, but a card that
    # cannot be read must not cost a freeform question its answer - the reply box is
    # answered without the selector having anything to do with it. So the failure is
    # kept and only raised on the path that genuinely needs the selector.
    $sel = $null
    $selError = $null
    try { $sel = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers }
    catch { $selError = $_ }
    try {
        if (Test-DaemonDecisionUsesFields -Marker $Marker -DecisionState $sel) {
            if ($null -ne $selError) { throw $selError }
            $form = Read-DaemonFormAnswer -SessionId $SessionId -Marker $Marker -State $State -Headers $Headers
            $answer = $form.Answer
            $selections = @($form.Selections)
            $stamp = [string]$form.PayloadStamp
            if ($form.PSObject.Properties['IsFreeText']) { $isFreeText = [bool]$form.IsFreeText }
        }
        elseif ($isChoice) {
            if ($null -ne $selError) { throw $selError }
            $s = [string]$sel.state
            if ($s -eq 'Cancel request') { $answer = $s }
            elseif ($s -notin @('Idle', 'Awaiting answer...', 'unknown', 'unavailable', '')) {
                # A selector carrying its own choices - a legacy `choices` argument,
                # a lone Claude question - still needs Send, the same as a field does.
                # Cancel above is the one exception: withdrawing a question is a
                # deliberate act in itself, not an answer waiting to be confirmed.
                $send = Test-DaemonSendPressed -SessionId $SessionId -Marker $Marker -Headers $Headers
                if ($send.Pressed) { $answer = $s }
            }
            else {
                # Nothing tapped, but something typed. Every Copilot option list ends
                # in "Other (type your answer)", so words are a real answer here. The
                # reply card only publishes when its own Send is pressed, so the
                # payload's arrival is itself the explicit send.
                $card = Read-DaemonDecisionCardText -SessionId $SessionId -Marker $Marker -Headers $Headers
                if (-not [string]::IsNullOrWhiteSpace($card.Text)) {
                    $answer = $card.Text
                    $isFreeText = $true
                    $stamp = $card.Stamp
                }
            }
        }
        else {
            $card = Read-DaemonDecisionCardText -SessionId $SessionId -Marker $Marker -Headers $Headers
            if (-not [string]::IsNullOrWhiteSpace($card.Text)) {
                $answer = $card.Text
                $stamp = $card.Stamp
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
    }
    catch {
        # A refused test-boundary operation is not an unreadable card. Absorbing it
        # here would turn "this suite tried to reach a real Home Assistant" into a
        # quiet "no answer yet", and the suite would pass for the wrong reason.
        if (Test-DaemonMarkedGuardError -ErrorRecord $_) { throw }
        return $null
    }
    [pscustomobject]@{
        Answer       = $answer
        Selections   = $selections
        IsChoice     = $isChoice
        IsFreeText   = $isFreeText
        PayloadStamp = $stamp
    }
}

function Read-DaemonFormAnswer {
    <#
        A multi-field form's answer, as { Answer, Selections, PayloadStamp,
        IsFreeText }, once it has been submitted with every field chosen; Answer is ''
        until then.

        One dropdown per field. Cancel still rides on the main selector, and the answer
        is only complete once every field has been chosen - a half-filled form must not
        be injected. PayloadStamp names the reply-card publish a free-text field was
        taken from, so it can be marked used after delivery rather than before, and
        IsFreeText says a lone choice was answered in words through the prompt's own
        "Other (type your answer)" entry instead of by tapping an option.
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
        return [pscustomobject]@{ Answer = 'Cancel request'; Selections = @(); PayloadStamp = ''; IsFreeText = $false }
    }

    # Typed into the reply card since this question was armed, if anything was. It is
    # both the free-text field's value and - because pressing Send is how a person
    # says they are done - a submit in its own right.
    $card = Read-DaemonDecisionCardText -SessionId $sessionId -Marker $marker -Headers $Headers
    $takesText = @($markerFields | Where-Object { Test-DecisionFieldIsText -Field $_ }).Count -gt 0

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
            if (-not [string]::IsNullOrWhiteSpace($card.Text)) { $v = $card.Text }
            else {
                try {
                    $rep = Get-HomeAssistantState -EntityId "text.${node}_reply" -Headers $Headers
                    $v = [string]$rep.state
                }
                catch {
                    if (Test-DaemonMarkedGuardError -ErrorRecord $_) { throw }
                }
                if ([string]::IsNullOrWhiteSpace($v) -or $v -in @('unknown', 'unavailable')) { $v = '' }
            }
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
        # A multi-select slot may be holding the answer as positions rather than as
        # words - that is what lets a question whose options are ordinary sentences be
        # answered here at all. Everything downstream, from the recorded answer to the
        # keystrokes, works in words, so it is turned back into them here and nowhere
        # else. A slot holding something that is neither reads as unanswered rather
        # than as a guess.
        if (Test-DecisionFieldIsMultiSelect -Field $markerField) {
            $indexes = @(Resolve-DecisionMultiSelectIndexes -Field $markerField -Value $v)
            if ($indexes.Count -eq 0) {
                $missingChoice = $true
                break
            }
            $v = Get-DecisionMultiSelectLabel -Field $markerField -Indexes ([int[]]$indexes)
        }
        $picked += $v
    }
    if ($missingChoice) { $picked = @() }

    # A single choice answered in words rather than by tapping. Every Copilot option
    # list ends in "Other (type your answer)", and that entry is the one place words
    # can get into an arrow-key prompt - so this is a real answer, and pressing Send
    # on the reply card is how it is committed.
    #
    # Not offered for a multi-select field: its "Other" row sits in a checkbox list,
    # where Enter accepts whatever is ticked rather than opening a text box, and that
    # has not been seen happen. Guessing would record an answer nobody gave.
    if ($markerFields.Count -eq 1 -and -not $takesText -and $missingChoice -and
        -not (Test-DecisionFieldIsMultiSelect -Field $markerFields[0]) -and
        -not [string]::IsNullOrWhiteSpace($card.Text)) {
        try {
            Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Sending answer...' `
                -Extra @{ answer = $card.Text } -Headers $Headers | Out-Null
        }
        catch {
            if (Test-DaemonMarkedGuardError -ErrorRecord $_) { throw }
        }
        return [pscustomobject]@{
            Answer = $card.Text; Selections = @(); PayloadStamp = $card.Stamp; IsFreeText = $true
        }
    }

    # Every field chosen is not enough: an answer is only sent when Send is pressed,
    # so selections can be reviewed and changed first. The press is identified against
    # the one recorded when the question was armed, not ordered against a clock, and a
    # missing or unreadable button is never a press - it used to fall back to
    # "submitted as soon as every field is chosen", which turns somebody filling a
    # form in into somebody sending it.
    $submitted = $false
    $send = Test-DaemonSendPressed -SessionId $sessionId -Marker $marker -Headers $Headers
    $pressIsNew = $send.Pressed
    $pressedAt = $send.At

    # Nothing to press. Said out loud once, because a card that cannot send looks
    # exactly like one being ignored. A button that is there and has merely never
    # been pressed is not this, and nor is one that could not be read this pass -
    # the first is the normal state of every unanswered question, the second is
    # transient and will be readable again.
    if ($send.Readable -and -not $send.Exists) {
        $entry = $State[$sessionId]
        $toldKey = "missing:$([string]$marker.decisionId)"
        $toldAt = if ($entry.PSObject.Properties['LastSendNoticeAt']) { [string]$entry.LastSendNoticeAt } else { '' }
        if ($toldAt -ne $toldKey) {
            if ($entry.PSObject.Properties['LastSendNoticeAt']) { $entry.LastSendNoticeAt = $toldKey }
            else { $entry | Add-Member -NotePropertyName LastSendNoticeAt -NotePropertyValue $toldKey -Force }
            try {
                Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Not sent - no Send button on this session' `
                    -Extra @{ answer_in = 'the terminal' } -Headers $Headers | Out-Null
            }
            catch {
                if (Test-DaemonMarkedGuardError -ErrorRecord $_) { throw }
            }
            Write-DaemonLog -Message "no Send button for $($sessionId.Substring(0,8)); nothing will be injected from the card"
        }
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

    # Words typed at a question that cannot take them - a form with no free-text
    # field, or a single choice that has already been tapped. Said out loud once per
    # publish rather than swallowed: silently dropping what somebody typed is the
    # whole bug this work exists to fix, and it is no better when the words cannot
    # be used.
    if (-not [string]::IsNullOrWhiteSpace($card.Text) -and -not $takesText) {
        $entry = $State[$sessionId]
        $toldAt = if ($entry.PSObject.Properties['LastDecisionTextNoticeAt']) { [string]$entry.LastDecisionTextNoticeAt } else { '' }
        if ($toldAt -ne $card.Stamp) {
            if ($entry.PSObject.Properties['LastDecisionTextNoticeAt']) { $entry.LastDecisionTextNoticeAt = $card.Stamp }
            else { $entry | Add-Member -NotePropertyName LastDecisionTextNoticeAt -NotePropertyValue $card.Stamp -Force }
            try {
                Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Not sent - this question takes options' `
                    -Extra @{ typed = $card.Text } -Headers $Headers | Out-Null
            }
            catch {
                if (Test-DaemonMarkedGuardError -ErrorRecord $_) { throw }
            }
            Write-DaemonLog -Message "reply card text for $($sessionId.Substring(0,8)) is not answerable by this question"
        }
    }

    # Send on the reply card submits too, but only a complete form: an incomplete one
    # already has its own "answer every field" report, and a payload stays fresh for
    # as long as it sits there, so counting it would repeat that every reconcile.
    $cardSubmits = ($takesText -and -not [string]::IsNullOrWhiteSpace($card.Stamp))
    if (($pressIsNew -or $cardSubmits) -and $picked.Count -eq $markerFields.Count) {
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
    # The stamp travels with the answer so the payload is marked as used only once it
    # has actually reached the prompt; a failed injection must leave it to be retried.
    $stamp = if ($submitted -and $cardSubmits) { [string]$card.Stamp } else { '' }
    [pscustomobject]@{ Answer = $answer; Selections = $selections; PayloadStamp = $stamp; IsFreeText = $false }
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
        strategy. On success, records the answer and the selections actually used by
        form delivery for completion verification, then blanks the Home Assistant input.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][object]$Marker,
        [Parameter(Mandatory)][string]$Answer,
        [Parameter(Mandatory)][bool]$IsChoice,
        [bool]$IsFreeText = $false,
        [AllowEmptyCollection()][string[]]$Selections = @(),

        # The reply-card publish this answer was typed in, marked as used once it has
        # landed so the reply path does not deliver the same words a second time.
        [AllowEmptyString()][string]$PayloadStamp = '',
        [AllowNull()][hashtable]$State = $null,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $short = $SessionId.Substring(0, [Math]::Min(8, $SessionId.Length))
    $node = Get-CopilotMqttNodeId -SessionId $SessionId
    # Claude and Codex leave no lock file for the injector to find their process by.
    $processId = Get-DaemonSessionProcessId -SessionId $SessionId
    $deliveredSelections = @()

    if ($IsChoice -and $IsFreeText) {
        # Typed, not chosen. The prompt's own "Other (type your answer)" entry is the
        # only way words get into an arrow-key option list, and hunting for the text
        # among the options would simply fail - it was never one of them.
        $delivery = Send-CopilotSessionChoice -SessionId $SessionId -Text $Answer `
            -ChoiceCount (@($Marker.choices).Count) -ProcessId $processId
    }
    elseif ($IsChoice) {
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
            if ($null -ne $delivery -and $delivery.Delivered) {
                # The single selector supplied Answer, not Selections. Keep the
                # effective form input, never infer it later from the recorded result.
                $deliveredSelections = @($sel)
            }
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
        Set-CopilotDecisionMarkerInjected -SessionId $SessionId -Answer $Answer -Selections $deliveredSelections
        # Mark the reply-card publish used only now. Recorded under the same name the
        # reply path reads, so the words that answered a question are never delivered
        # again as a fresh reply once the card clears.
        if (-not [string]::IsNullOrWhiteSpace($PayloadStamp) -and $null -ne $State -and $State.ContainsKey($SessionId)) {
            $entry = $State[$SessionId]
            if ($entry.PSObject.Properties['LastReplyPayloadAt']) { $entry.LastReplyPayloadAt = $PayloadStamp }
            else { $entry | Add-Member -NotePropertyName LastReplyPayloadAt -NotePropertyValue $PayloadStamp -Force }
        }
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

        $short = $sessionId.Substring(0, [Math]::Min(8, $sessionId.Length))
        try { $marker = & $readMarker $sessionId $true }
        catch {
            Write-DaemonLog -Message "codex approval state unavailable for $short; no input attempted: $($_.Exception.Message)"
            continue
        }
        if ($null -eq $marker) { continue }
        $generation = if ($marker.PSObject.Properties['DecisionId'] -and $marker.DecisionId -is [string]) {
            $marker.DecisionId
        } else { '' }
        if ([string]::IsNullOrWhiteSpace($generation)) {
            Write-DaemonLog -Message "codex approval has no readable generation for $short; no input attempted"
            continue
        }

        $node = Get-CopilotMqttNodeId -SessionId $sessionId
        $choice = ''
        try {
            $selector = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
            $choice = [string]$selector.state
            $cardGeneration = if ($selector.PSObject.Properties['attributes'] -and
                $selector.attributes.PSObject.Properties['decision_id'] -and
                $selector.attributes.decision_id -is [string]) { $selector.attributes.decision_id } else { '' }
        }
        catch {
            Write-DaemonLog -Message "codex approval card unavailable for $short; no input attempted: $($_.Exception.Message)"
            continue
        }

        if ($choice -notin @('Approve', 'Deny')) { continue }
        if (-not [StringComparer]::Ordinal.Equals($generation, $cardGeneration)) {
            Write-DaemonLog -Message "codex approval card generation does not match $short; no input attempted"
            continue
        }
        try {
            if (-not (Set-CodexApprovalAttempt -SessionId $sessionId -DecisionId $generation -Choice $choice)) {
                Write-DaemonLog -Message "codex approval generation changed or was already attempted for $short; not replaying"
                continue
            }
        }
        catch {
            Write-DaemonLog -Message "codex approval attempt could not be persisted for $short; no input attempted: $($_.Exception.Message)"
            continue
        }

        # Codex's approval prompt is a keyboard UI, so the answer is typed into the
        # session the same way a reply is. Approve sends y, deny sends n, which is
        # what its prompt accepts.
        $keystroke = if ($choice -eq 'Approve') { 'y' } else { 'n' }
        try {
            $delivery = Send-CopilotSessionPrompt -SessionId $sessionId -Text $keystroke `
                -ProcessId ([int]$session.ProcessId)
            if ($null -ne $delivery -and $delivery.Delivered) {
                Write-DaemonLog -Message "codex approval input attempted for $short; native approval is not confirmed"
            }
            else {
                Write-DaemonLog -Message "codex approval input attempt FAILED or uncertain for $short; not replaying"
            }
        }
        catch {
            Write-DaemonLog -Message "codex approval input attempt FAILED or uncertain for $short; not replaying: $($_.Exception.Message)"
        }

        # Clearing is cosmetic, not the replay barrier. Keep attempted ownership
        # until native lifecycle evidence retires it, and never clear replacement B.
        try {
            $current = Get-CodexApprovalMarker -SessionId $sessionId -RequireReadable
            if ($null -eq $current -or -not [StringComparer]::Ordinal.Equals([string]$current.DecisionId, $generation)) { continue }
            $card = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
            if (-not $card.PSObject.Properties['attributes'] -or
                -not $card.attributes.PSObject.Properties['decision_id'] -or
                -not [StringComparer]::Ordinal.Equals([string]$card.attributes.decision_id, $generation)) { continue }
            Clear-CopilotMqttDecision -SessionId $sessionId `
                -SessionName ([string]$State[$sessionId].Name) `
                -Machine ([string]$State[$sessionId].Machine) -Headers $Headers
        }
        catch {
            Write-DaemonLog -Message "codex approval card cleanup failed for $short; durable attempt remains: $($_.Exception.Message)"
        }
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
