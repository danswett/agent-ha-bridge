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
            re-checked immediately before injecting to reject a terminal answer
            already recorded. This is not an atomic native-UI input protocol.
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
        if (-not $askState.PSObject.Properties['CanAnswer'] -or -not $askState.CanAnswer) { continue }

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
        if (($marker.PSObject.Properties['deliveryAttempted'] -and $marker.deliveryAttempted) -or
            -not [string]::IsNullOrEmpty([string]$marker.injectedAnswer)) { continue }

        # Re-verify the ask_user is still pending right before injecting, so a terminal
        # answer that landed in the last second is never double-answered.
        $recheck = Get-DaemonAskUserState -Session $session -Marker $marker
        $current = Get-CopilotDecisionMarker -SessionId $sessionId
        if (-not $recheck.Pending -or -not $recheck.CanAnswer -or $null -eq $current -or
            [string]$current.decisionId -cne [string]$marker.decisionId) { continue }

        [void](Invoke-DaemonDecisionAnswer -SessionId $sessionId -Marker $marker `
            -Answer $read.Answer -IsChoice $read.IsChoice -Selections $read.Selections -Headers $Headers)
    }
}

function Complete-DaemonAnsweredDecision {
    <#
        Revokes a completed generation locally, clears its card, and reports whether
        the native result confirms the dashboard selection. Never overrides a
        potentially competing terminal answer with an automatic correction.
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
    # Revoke locally before I/O, and never delete a replacement question's marker.
    if (-not (Remove-CopilotDecisionMarker -SessionId $sessionId -DecisionId ([string]$marker.decisionId) -PassThru)) { return }

    try {
        $card = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
        if ((Test-DaemonDecisionCard -Card $card -Marker $marker) -and
            $null -eq (Get-CopilotDecisionMarker -SessionId $sessionId)) {
            Clear-CopilotMqttDecision -SessionId $sessionId `
                -SessionName ([string]$State[$sessionId].Name) `
                -Machine ([string]$State[$sessionId].Machine) -Headers $Headers | Out-Null
            Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers `
                -Data @{ entity_id = "text.${node}_reply"; value = $script:DaemonConfig.ReplyBlankValue } | Out-Null
        }
    }
    catch {
        if ($_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        Write-DaemonLog -Message "decision clear failed for $sessionId : $($_.Exception.Message)"
    }
    $injected = @()
    if ($marker.PSObject.Properties['injectedSelections']) { $injected = @($marker.injectedSelections) }
    $attempted = [bool]($marker.PSObject.Properties['deliveryAttempted'] -and $marker.deliveryAttempted)
    $withdrawn = [string]$marker.mode -eq 'multiple_choice' -and [string]$marker.injectedAnswer -ceq 'Cancel request'
    if (-not $withdrawn -and ($attempted -or $injected.Count -gt 0)) {
        $verification = Get-CopilotAnswerVerification -ResultContent $askState.ResultContent `
            -Fields @($marker.fields) -Selections $injected
        Write-DaemonLog -Message "decision result for $sessionId : $verification"
        if ($verification -ne 'Match') {
            # A terminal answer may have won the race. Neither an unknown result nor
            # a proven difference authorizes overruling that human with a correction.
            $summary = if ($verification -eq 'Mismatch') { 'Recorded answer differs - check the terminal' }
                else { 'Answer not verified - check the terminal' }
            try {
                Set-DaemonTransientActivity -SessionId $sessionId -Summary $summary `
                    -Extra @{ verification = $verification } -Headers $Headers | Out-Null
            }
            catch {
                if ($_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
                Write-DaemonLog -Message "decision verification notice failed for $sessionId : $($_.Exception.Message)"
            }
        }
    }
    $entry = $State[$sessionId]
    if ($entry.PSObject.Properties['LastReply']) { $entry.LastReply = '' }
    Write-DaemonLog -Message "decision completed (either input); invalidated local request for $sessionId"
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
        $armed = $null
        try { $armed = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers }
        catch {
            if ($_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
            Write-DaemonLog -Message "decision card unavailable for $SessionId; attempting recovery from its marker"
        }
        $current = Get-CopilotDecisionMarker -SessionId $SessionId
        if ($null -eq $current -or [string]$current.decisionId -cne [string]$Marker.decisionId) { return }
        if (-not (Test-DaemonDecisionCard -Card $armed -Marker $Marker)) {
            $terminalOnly = [bool]($Marker.PSObject.Properties['terminalOnly'] -and $Marker.terminalOnly)
            Set-CopilotMqttDecision -SessionId $SessionId `
                -SessionName ([string]$State[$SessionId].Name) `
                -Machine ([string]$State[$SessionId].Machine) `
                -Question ([string]$Marker.question) `
                -Choices @($Marker.choices) -Fields @($Marker.fields) `
                -DecisionId ([string]$Marker.decisionId) -Headers $Headers -TerminalOnly:$terminalOnly | Out-Null
            Write-DaemonLog -Message "armed card from marker for $($SessionId.Substring(0,8)) (hook could not reach Home Assistant)"
        }
    }
    catch {
        if ($_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        Write-DaemonLog -Message "marker re-arm check failed for $SessionId : $($_.Exception.Message)"
    }
}

function Test-DaemonDecisionCard {
    param([AllowNull()]$Card, [Parameter(Mandatory)]$Marker)

    if ($null -eq $Card -or -not $Card.PSObject.Properties['attributes'] -or $null -eq $Card.attributes) { return $false }
    $attributes = $Card.attributes
    $id = if ($attributes -is [Collections.IDictionary]) { [string]$attributes['decision_id'] }
        elseif ($attributes.PSObject.Properties['decision_id']) { [string]$attributes.decision_id }
        else { '' }
    $id -and $id -ceq [string]$Marker.decisionId
}

function Test-DaemonDecisionSelectionTime {
    param([AllowNull()]$Selection, [Parameter(Mandatory)]$Marker)

    if ($null -eq $Selection -or -not $Selection.PSObject.Properties['last_changed']) { return $false }
    $armed = if ($Marker.PSObject.Properties['armedAt']) { $Marker.armedAt }
        elseif ($Marker.PSObject.Properties['Created']) { $Marker.Created }
        else { $null }
    $armedAt = ConvertTo-DecisionInstant -Value $armed
    $changedAt = ConvertTo-DecisionInstant -Value $Selection.last_changed
    if ($null -eq $armedAt -or $null -eq $changedAt) { return $false }
    $changedAt -gt $armedAt
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
        $sel = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
        if (-not (Test-DaemonDecisionCard -Card $sel -Marker $Marker)) { return $null }
        if (@($Marker.fields).Count -gt 1) {
            $form = Read-DaemonFormAnswer -SessionId $SessionId -Marker $Marker -State $State -Headers $Headers
            $answer = $form.Answer
            $selections = @($form.Selections)
        }
        elseif ($isChoice) {
            $s = [string]$sel.state
            if ((Test-DaemonDecisionSelectionTime -Selection $sel -Marker $Marker) -and
                (@($Marker.choices) -ccontains $s -or $s -ceq 'Cancel request')) { $answer = $s }
        }
        else {
            $rep = Get-HomeAssistantState -EntityId "text.${node}_reply" -Headers $Headers
            $r = [string]$rep.state
            # Whitespace is the blank sentinel the reply box is parked on, not an
            # answer, so it must not be injected.
            if (-not [string]::IsNullOrWhiteSpace($r) -and
                $r -notin @('unknown', 'unavailable') -and
                (Test-DaemonDecisionSelectionTime -Selection $rep -Marker $Marker)) { $answer = $r }
        }
    }
    catch {
        if ($_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        Write-DaemonLog -Message "decision answer read failed for $SessionId : $($_.Exception.Message)"
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
    if (-not (Test-DaemonDecisionCard -Card $sel -Marker $marker)) {
        return [pscustomobject]@{ Answer = ''; Selections = @() }
    }
    if ([string]$sel.state -ceq 'Cancel request' -and (Test-DaemonDecisionSelectionTime -Selection $sel -Marker $marker)) {
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
            $rep = Get-HomeAssistantState -EntityId "text.${node}_reply" -Headers $Headers
            $v = [string]$rep.state
            if ($v -in @('unknown', 'unavailable') -or
                (-not [string]::IsNullOrWhiteSpace($v) -and -not (Test-DaemonDecisionSelectionTime -Selection $rep -Marker $marker))) {
                $missingChoice = $true; break
            }
            if ([string]::IsNullOrWhiteSpace($v)) { $v = '' }
            if (-not $v -and $markerField.PSObject.Properties['Required'] -and $markerField.Required) {
                $missingChoice = $true; break
            }
            $picked += $v
            continue
        }

        $fs = Get-HomeAssistantState `
            -EntityId (Get-CopilotMqttFieldEntityId -Node $node -Index $fi) -Headers $Headers
        $v = [string]$fs.state
        $options = if (Test-DecisionFieldIsMultiSelect -Field $markerField) { @(Get-DecisionMultiSelectChoices -Field $markerField) }
            else { @($markerField.Options) }
        if ($options -cnotcontains $v -or -not (Test-DaemonDecisionSelectionTime -Selection $fs -Marker $marker)) {
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
            $armedAt = ConvertTo-DecisionInstant -Value $marker.armedAt
            $last = if ($State[$sessionId].PSObject.Properties['LastSubmitAt']) { [string]$State[$sessionId].LastSubmitAt } else { '' }
            $pressInstant = ConvertTo-DecisionInstant -Value $pressedAt
            $pressIsNew = $null -ne $armedAt -and $null -ne $pressInstant -and $pressInstant -gt $armedAt -and $pressedAt -cne $last
        }
    }
    catch {
        if ($_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        Write-DaemonLog -Message "decision submit not confirmed for $sessionId : $($_.Exception.Message)"
        $pressIsNew = $false
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

        Keys written are not an answer. Observe the matching result without guessing
        whether another Enter would submit a review screen or accept a default. Agents whose
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

    $deadline = [DateTimeOffset]::Now.AddMilliseconds($WaitMs)
    while ([DateTimeOffset]::Now -lt $deadline) {
        $state = Get-DaemonAskUserState -Session $session -Marker $Marker
        if ($state.Started -and -not $state.Pending -and $null -ne $Marker -and
            [string]$state.ToolCallId -ceq [string]$Marker.toolCallId) { return $Delivery }
        Start-Sleep -Milliseconds 150
    }

    $Delivery.Delivered = $false
    $Delivery.Detail = "keys sent; native answer unconfirmed, check the terminal ($($Delivery.Detail))"
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
    $session = $script:DaemonLive[$SessionId]
    $current = Get-CopilotDecisionMarker -SessionId $SessionId
    if ($null -eq $session -or $null -eq $current -or
        [string]$current.decisionId -cne [string]$Marker.decisionId -or
        -not $Marker.PSObject.Properties['toolCallId'] -or -not $Marker.toolCallId -or
        ($Marker.PSObject.Properties['terminalOnly'] -and $Marker.terminalOnly)) {
        Write-DaemonLog -Message "decision not sent for $short : request is no longer actionable"
        return $false
    }
    $request = Get-DaemonAskUserState -Session $session -Marker $Marker
    if (-not $request.Started -or -not $request.Pending -or -not $request.CanAnswer) {
        Write-DaemonLog -Message "decision not sent for $short : native request is not uniquely pending"
        return $false
    }
    $fields = @($Marker.fields)
    $sel = @($Selections)
    if ($sel.Count -eq 0 -and $fields.Count -eq 1) { $sel = @($Answer) }
    $withdrawn = $IsChoice -and $Answer -ceq 'Cancel request'
    if (-not $withdrawn -and
        (($fields.Count -gt 0 -and ($sel.Count -ne $fields.Count -or -not (Test-DecisionFieldsAnswerable -Fields $fields))) -or
        ($IsChoice -and $fields.Count -eq 0 -and @($Marker.choices) -cnotcontains $Answer))) {
        Write-DaemonLog -Message "decision not sent for $short : answer does not map to this request"
        return $false
    }
    # Persist the one-shot claim before any console write. Even a partial write or a
    # daemon restart must not replay keys into whatever UI appears next.
    if (-not (Set-CopilotDecisionMarkerInjected -SessionId $SessionId -DecisionId ([string]$Marker.decisionId) `
        -Answer $Answer -Selections $sel)) { return $false }
    if ($withdrawn) {
        Write-DaemonLog -Message "dashboard request withdrawn for $short; native prompt left untouched"
        Set-DaemonTransientActivity -SessionId $SessionId -Summary 'Dashboard answer withdrawn - use the terminal' -Headers $Headers | Out-Null
        return $false
    }

    if ($IsChoice) {
        # The native prompt is one arrow-key option list per field (tabbed when there
        # is more than one). Selecting by index returns the schema's real value for
        # each field. The legacy single-list path is separate, never a retry after
        # an unknown or partial form delivery.
        if ($fields.Count -gt 0 -and $sel.Count -eq $fields.Count) {
            $stillCurrent = {
                $latest = Get-CopilotDecisionMarker -SessionId $SessionId
                if ($null -eq $latest -or [string]$latest.decisionId -cne [string]$Marker.decisionId) { return $false }
                $native = Get-DaemonAskUserState -Session $session -Marker $Marker
                $native.Started -and $native.Pending -and $native.CanAnswer
            }
            $delivery = Send-CopilotSessionForm -SessionId $SessionId -Fields $fields -Selections $sel `
                -ProcessId $processId -StillCurrent $stillCurrent
        }
        else {
            $delivery = Send-CopilotSessionChoice -SessionId $SessionId -Text $Answer `
                -ChoiceCount (@($Marker.choices).Count) -ProcessId $processId
        }
    }
    else {
        $delivery = Send-CopilotSessionPrompt -SessionId $SessionId -Text $Answer -ProcessId $processId
    }

    # Observation only: never try extra keys or another delivery strategy after an
    # ambiguous/partial console write.
    if ($delivery.Delivered) {
        $delivery = Complete-DaemonClaudeAnswer -SessionId $SessionId -Delivery $delivery -Marker $Marker
    }

    $current = Get-CopilotDecisionMarker -SessionId $SessionId
    if ($null -eq $current -or [string]$current.decisionId -cne [string]$Marker.decisionId) {
        Write-DaemonLog -Message "decision generation changed after input for $short; leaving the newer card untouched"
        return $delivery.Delivered
    }

    if ($delivery.Delivered) {
        try {
            Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers `
                -Data @{ entity_id = "text.${node}_reply"; value = $script:DaemonConfig.ReplyBlankValue }
        }
        catch { }
        try {
            $shown = ($Answer -replace '\s+', ' ').Trim()
            if ($shown.Length -gt 60) { $shown = $shown.Substring(0, 57) + '...' }
            Set-DaemonTransientActivity -SessionId $SessionId -Summary 'Answer sent - awaiting result verification' `
                -Extra @{ answer = $shown; at = [DateTimeOffset]::Now.ToString('HH:mm:ss') } -Headers $Headers
        }
        catch { }
        Write-DaemonLog -Message "decision answer injected to $short (pid $($delivery.ProcessId)): $($delivery.Detail)"
    }
    else {
        try {
            Set-DaemonTransientActivity -SessionId $SessionId -Summary 'Answer not confirmed - check the terminal' `
                -Extra @{ error = [string]$delivery.Detail } -Headers $Headers
        }
        catch { }
        Write-DaemonLog -Message "decision answer not confirmed for $short : $($delivery.Detail)"
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
        if (-not $State.ContainsKey($sessionId)) { continue }
        if ($null -ne $marker -and (-not $marker.PSObject.Properties['DecisionId'] -or -not $marker.DecisionId)) {
            Write-DaemonLog -Message "codex approval marker has no generation for $sessionId; no input is authorized"
            continue
        }

        $node = Get-CopilotMqttNodeId -SessionId $sessionId
        $choice = ''
        $selector = $null
        try {
            $selector = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
            $choice = [string]$selector.state
        }
        catch {
            if ($_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
            Write-DaemonLog -Message "codex approval card unavailable for $sessionId; keeping its local request"
        }

        if ($null -eq $marker) {
            # The fast hook revoked the local request, even when it could not clear HA.
            if ($null -ne $selector -and $selector.PSObject.Properties['attributes'] -and $selector.attributes.PSObject.Properties['decision_id'] -and
                $selector.attributes.decision_id -and $null -eq (& $readMarker $sessionId)) {
                try {
                    Clear-CopilotMqttDecision -SessionId $sessionId -SessionName ([string]$State[$sessionId].Name) `
                        -Machine ([string]$State[$sessionId].Machine) -Headers $Headers | Out-Null
                }
                catch {
                    if ($_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
                    Write-DaemonLog -Message "revoked codex card clear failed for $sessionId : $($_.Exception.Message)"
                }
            }
            continue
        }
        if ($marker.PSObject.Properties['DeliveryAttempted'] -and $marker.DeliveryAttempted) { continue }
        $identified = [bool]($marker.PSObject.Properties['ToolCallId'] -and $marker.ToolCallId)
        if (-not (Test-DaemonDecisionCard -Card $selector -Marker $marker)) {
            $current = & $readMarker $sessionId
            if ($null -eq $current -or [string]$current.DecisionId -cne [string]$marker.DecisionId) { continue }
            $choices = @()
            $question = [string]$marker.Question
            if ($identified) { $choices = @('Approve', 'Deny') }
            else { $question += "`n`nAnswer in the terminal: this client did not identify the approval request." }
            try {
                Set-CopilotMqttDecision -SessionId $sessionId -SessionName ([string]$State[$sessionId].Name) `
                    -Machine ([string]$State[$sessionId].Machine) -Question $question `
                    -Choices $choices -Fields @() -DecisionId ([string]$marker.DecisionId) -Headers $Headers -TerminalOnly:(-not $identified) | Out-Null
            }
            catch {
                if ($_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
                Write-DaemonLog -Message "codex approval recovery failed for $sessionId : $($_.Exception.Message)"
            }
            continue
        }
        if (-not $identified) { continue }
        if ($choice -cnotin @('Approve', 'Deny') -or -not (Test-DaemonDecisionSelectionTime -Selection $selector -Marker $marker)) { continue }
        if ($session.PSObject.Properties['Status'] -and $session.Status -ne 'waiting') { continue }
        if (-not (Set-CodexApprovalMarkerAttempted -SessionId $sessionId -DecisionId ([string]$marker.DecisionId) -Answer $choice)) { continue }

        # Codex's approval prompt is a keyboard UI, so the answer is typed into the
        # session the same way a reply is. Approve sends y, deny sends n, which is
        # what its prompt accepts.
        $keystroke = if ($choice -eq 'Approve') { 'y' } else { 'n' }
        $short = $sessionId.Substring(0, [Math]::Min(8, $sessionId.Length))
        $delivery = Send-CopilotSessionPrompt -SessionId $sessionId -Text $keystroke `
            -ProcessId ([int]$session.ProcessId)

        if ($delivery.Delivered) {
            Write-DaemonLog -Message "codex approval input sent to $short; native outcome is not confirmed (pid $($delivery.ProcessId))"
        }
        else {
            Write-DaemonLog -Message "codex approval delivery FAILED for $short : $($delivery.Detail)"
        }

        # Clear either way, so a failed delivery is not resent on every reconcile.
        # The hook clears the marker itself once the prompt is genuinely answered.
        try {
            $current = & $readMarker $sessionId
            if ($null -ne $current -and [string]$current.DecisionId -ceq [string]$marker.DecisionId) {
                Clear-CopilotMqttDecision -SessionId $sessionId `
                    -SessionName ([string]$State[$sessionId].Name) `
                    -Machine ([string]$State[$sessionId].Machine) -Headers $Headers | Out-Null
            }
            Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Approval input attempted - verify in the terminal' -Headers $Headers | Out-Null
        }
        catch {
            if ($_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
            Write-DaemonLog -Message "codex approval card update failed for $sessionId : $($_.Exception.Message)"
        }
    }
}

function Get-DaemonAnswerCorrection {
    <#
        Legacy correction formatter. The daemon no longer sends this automatically:
        a different recorded answer can be a legitimate competing terminal answer.

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
