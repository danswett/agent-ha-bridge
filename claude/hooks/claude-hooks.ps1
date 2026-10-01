<#
    What each Claude Code hook does, as functions.

    The hook scripts (register-claude-session.ps1, notify-claude-stop.ps1,
    route-askuserquestion.ps1, route-notification.ps1) read the event and call these.
    The daemon calls them too, for events the native hook spooled to it (see
    docs/fast-hooks.md), so both paths run the same code.

    -Ancestors is the process chain the native hook recorded, nearest first. A hook
    script passes none, and the owning process is found by walking up from itself.

    None of these write to stdout or throw on purpose: the caller fails open. They need
    claude-ask-parser.ps1 and claude-session.ps1 loaded, and all but the first the
    bridge core (decision-bridge-common, decision-mqtt, decision-ha-websocket,
    bridge-adapter) and, for Stop, claude-transcript.ps1.
#>

function Invoke-ClaudeRegisterHook {
    <#
        SessionStart and UserPromptSubmit: registers the session as soon as it exists.

        The daemon discovers Claude sessions only from the registrations hooks write, and
        before this the only writers were Stop, Notification and PreToolUse - so a
        session stayed invisible until its first turn ended, and a session launched from
        the dashboard could never be confirmed as started. SessionStart closes that gap;
        UserPromptSubmit covers a session that was already open when the adapter was
        installed.
    #>
    param([Parameter(Mandatory)]$HookEvent, [int[]]$Ancestors = @())

    $sessionId = [string]$HookEvent.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { return }

    # At SessionStart the transcript may not have been written yet, so the path Claude
    # reports is kept as-is rather than verified and discarded.
    $transcriptPath = [string]$HookEvent.transcript_path
    if ([string]::IsNullOrWhiteSpace($transcriptPath)) {
        $transcriptPath = Resolve-ClaudeTranscriptPath -SessionId $sessionId
    }

    # A submitted prompt is the start of a turn, so it records 'working'; that is what
    # lifts the card out of 'idle' or 'waiting' straight away. SessionStart records
    # no status, leaving whatever the daemon infers.
    $status = if ([string]$HookEvent.hook_event_name -eq 'UserPromptSubmit') { 'working' } else { '' }

    Write-ClaudeSessionRegistration -SessionId $sessionId -TranscriptPath $transcriptPath `
        -WorkingDirectory ([string]$HookEvent.cwd) -ProcessId (Get-ClaudeOwningProcessId -Ancestors $Ancestors) -Status $status | Out-Null
}

function Invoke-ClaudeStopHook {
    <#
        Stop: Claude has no turn-end entry in its transcript, so this is the
        authoritative end-of-turn signal. It marks the session idle, refreshes the
        session registration so the daemon still considers it live, and sends the
        optional out-of-band push with a preview of the response.

        The dashboard card already carries the full response - the daemon streams it
        from the transcript - so only a preview is pushed.
    #>
    param([Parameter(Mandatory)]$HookEvent, [int[]]$Ancestors = @())

    $sessionId = [string]$HookEvent.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { return }

    $transcriptPath = Resolve-ClaudeTranscriptPath -SessionId $sessionId `
        -KnownPath ([string]$HookEvent.transcript_path)

    # Keeps the registration fresh, and recovers the owning pid if an earlier event
    # could not resolve it.
    Write-ClaudeSessionRegistration -SessionId $sessionId -TranscriptPath $transcriptPath `
        -WorkingDirectory ([string]$HookEvent.cwd) -ProcessId (Get-ClaudeOwningProcessId -Ancestors $Ancestors) -Status 'idle' | Out-Null

    # The turn has already ended, so a miss here costs nothing - the daemon reconciles
    # it. Enter-BridgeAdapterSession returns headers when reachable, or $null when not.
    $headers = Enter-BridgeAdapterSession
    if (-not $headers) { return }
    $display = Get-ClaudeSessionDisplay -SessionId $sessionId -WorkingDirectory ([string]$HookEvent.cwd)

    # Only touch entities that already exist. A turn can end in a session that never
    # asked anything, and publishing a card for it here would create clutter the
    # daemon is responsible for.
    $node = Get-CopilotMqttNodeId -SessionId $sessionId
    $exists = Test-BridgeSessionEntityPresent -EntityId "sensor.${node}_status" -Headers $headers

    $response = $null
    # Claude hands the finished reply to the Stop hook directly as
    # last_assistant_message - confirmed on a real session - which is both cheaper and
    # more accurate than re-reading the transcript. The transcript stays as a fallback
    # for older builds that do not send it.
    if ($HookEvent.PSObject.Properties.Name -contains 'last_assistant_message' -and
        -not [string]::IsNullOrWhiteSpace([string]$HookEvent.last_assistant_message)) {
        $response = ([string]$HookEvent.last_assistant_message).Trim()
    }
    elseif ($transcriptPath) {
        $tail = Read-ClaudeTranscriptAppend -Path $transcriptPath -Offset 0
        $activity = Get-ClaudeActivityFromTranscript -Lines $tail.Lines
        $response = $activity.Response
    }

    # Status only. The daemon streams the finished reply onto the card from the
    # transcript within a tick; publishing it here as well replaced the card's
    # attributes with a bare set - emptying its body until something republished it -
    # and put the whole reply in the status line.
    if ($exists) {
        Publish-BridgeSessionStatus -SessionId $sessionId -SessionName $display.Name `
            -Machine $display.Machine -Headers $headers -Status 'idle' | Out-Null
    }

    Send-BridgeResponseNotification -SessionName $display.Name -Response ([string]$response) -Headers $headers | Out-Null

    Write-DecisionBridgeLog -Message (
        "claude Stop: session=$($sessionId.Substring(0,[Math]::Min(8,$sessionId.Length))) " +
        "entities=$exists responseChars=$(($response ?? '').Length)"
    )
}

function Invoke-ClaudeAskHook {
    <#
        PreToolUse for AskUserQuestion - dual-input, non-blocking. When Claude asks a
        question this:
          1. Records the session, its transcript and its owning pid.
          2. Ensures the session's Home Assistant entities exist.
          3. Arms the decision card with the question and its options.
          4. Sends an optional push notification.
          5. Writes a pending-decision marker for the daemon.
        and leaves Claude's own prompt untouched.

        Answering works the same way as the Copilot bridge: the terminal prompt remains
        the source of truth, and the daemon injects a Home Assistant answer into that
        same prompt. Whichever is used first wins.
    #>
    param([Parameter(Mandatory)]$HookEvent, [int[]]$Ancestors = @())

    if ([string]$HookEvent.tool_name -ne 'AskUserQuestion') { return }

    $sessionId = [string]$HookEvent.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = "claude-$PID" }
    $workingDirectory = [string]$HookEvent.cwd

    $parsed = ConvertFrom-ClaudeAskUserQuestion -ToolInput $HookEvent.tool_input
    $question = $parsed.Question
    $choices = @($parsed.Choices)
    $fields = @($parsed.Fields)
    $mode = if ($choices.Count -gt 0 -or $fields.Count -gt 0) { 'multiple_choice' } else { 'freeform' }

    $owningPid = Get-ClaudeOwningProcessId -Ancestors $Ancestors
    Write-ClaudeSessionRegistration -SessionId $sessionId `
        -TranscriptPath (Resolve-ClaudeTranscriptPath -SessionId $sessionId -KnownPath ([string]$HookEvent.transcript_path)) `
        -WorkingDirectory $workingDirectory -ProcessId $owningPid | Out-Null

    $decisionId = "$(Get-CopilotMqttNodeId -SessionId $sessionId)-$([DateTimeOffset]::Now.ToUnixTimeMilliseconds())"

    # Local state first, before anything that can block. If Home Assistant is slow or
    # down, the hook still returns promptly and the daemon arms the card from this
    # marker once it can reach Home Assistant again.
    # The marker carries a field even for a single question, so the daemon answers it
    # by index. A multi-select question, or one with more questions than the card has
    # dropdowns for, cannot be driven by keystroke and is left to the terminal.
    $markerFields = @($parsed.MarkerFields)
    # A multi-select question is answerable from the card as the list of combinations
    # its options make (Get-DecisionMultiSelectChoices), and delivered by typing each
    # chosen option's number at the prompt. Only one that makes more combinations than
    # a dropdown can list is left to the terminal.
    $terminalOnly = ($mode -eq 'multiple_choice' -and $markerFields.Count -eq 0)
    $tooManyCombinations = $false
    foreach ($markerField in $markerFields) {
        if ((Test-DecisionFieldIsMultiSelect -Field $markerField) -and
            @(Get-DecisionMultiSelectChoices -Field $markerField).Count -eq 0) {
            $tooManyCombinations = $true
        }
    }
    if ($tooManyCombinations) { $terminalOnly = $true }
    $toolUseId = if ($HookEvent.PSObject.Properties['tool_use_id'] -and $HookEvent.tool_use_id -is [string]) {
        $HookEvent.tool_use_id
    } else { '' }

    # A prompt the daemon refuses to drive must offer no control that pretends to
    # drive it. This published the full set of dropdowns regardless, so a multi-select
    # question armed a card that looked completely answerable: both fields were
    # chosen, Send was pressed six times over half an hour, and the daemon dropped
    # every press at its terminal-only check without a word on the card. The options
    # move into the question text - as Copilot's side already does - so the card still
    # shows what is being asked, and nothing on it claims to be able to answer.
    $asked = "choices=$($choices.Count) fields=$($fields.Count)"
    if ($terminalOnly) {
        $reason = if ($tooManyCombinations) { 'it offers more combinations than the dashboard can list' } else { '' }
        $question = Add-ClaudeTerminalOnlyNotice -Question $question -Fields $markerFields -Reason $reason
        $choices = @()
        $fields = @()
        $markerFields = @()
    }
    elseif ($choices.Count -gt 0 -and $markerFields.Count -eq 1 -and
            (Test-DecisionFieldIsMultiSelect -Field $markerFields[0])) {
        # One multi-select question shows a single dropdown, so its combinations go on
        # that dropdown rather than the bare options - picking one option there would
        # quietly answer a "choose any" question with exactly one.
        $choices = @(Get-DecisionMultiSelectChoices -Field $markerFields[0])
    }

    [void](Get-DecisionSchemaFieldChoices -Field ([pscustomobject]@{ enum = $choices }))
    foreach ($markerField in $markerFields) {
        [void](Get-DecisionSchemaFieldChoices -Field ([pscustomobject]@{ enum = @($markerField.Options) }))
    }
    Write-CopilotDecisionMarker -SessionId $sessionId -DecisionId $decisionId `
        -Question $question -Choices $choices -Combos @() -Fields $markerFields -Mode $mode `
        -TerminalOnly:$terminalOnly -ToolCallId $toolUseId | Out-Null

    Write-DecisionBridgeLog -Message (
        "claude AskUserQuestion: session=$($sessionId.Substring(0,[Math]::Min(8,$sessionId.Length))) " +
        "pid=$owningPid $asked mode=$mode " +
        "toolUseId=$(if ($toolUseId) { 'yes' } else { 'no' }) terminalOnly=$terminalOnly"
    )

    # A hook must never wait on the network; the daemon reconciles whatever a miss
    # leaves behind. Enter-BridgeAdapterSession probes, sets the deadline and returns
    # headers when Home Assistant is reachable, or $null when it is not.
    $headers = Enter-BridgeAdapterSession
    if (-not $headers) { return }
    $display = Get-ClaudeSessionDisplay -SessionId $sessionId -WorkingDirectory $workingDirectory
    $node = Get-CopilotMqttNodeId -SessionId $sessionId

    [void](Confirm-BridgeSessionEntities -SessionId $sessionId -SessionName $display.Name `
        -Machine $display.Machine -Headers $headers -ProbeEntity "select.${node}_decision")

    Set-CopilotMqttDecision -SessionId $sessionId -SessionName $display.Name `
        -Machine $display.Machine -Question $question -Choices $choices `
        -Fields $fields -DecisionId $decisionId -Headers $headers | Out-Null

    $numbered = ''
    if ($choices.Count -gt 0) {
        $lines = for ($i = 0; $i -lt $choices.Count; $i++) { "$($i + 1). $($choices[$i])" }
        $numbered = ($lines -join "`n") + "`n"
    }

    $body = @(
        "Session: $($display.Name)"
        "Machine: $($display.Machine)"
        ''
        $question
        ''
        $numbered
        $(if ($terminalOnly) { 'Answer this one in the terminal.' } else { 'Answer in the terminal or on the dashboard.' })
    ) -join "`n"
    if ($body.Length -gt 950) { $body = $body.Substring(0, 947) + '...' }

    Send-BridgeNotification -Title (Format-BridgeNotificationTitle $display.Name) -Message $body -Headers $headers | Out-Null
}

function Invoke-ClaudeNotificationHook {
    <#
        Notification: Claude fires this when it wants the user - most usefully when a
        tool needs permission, or when a prompt has been sitting unanswered - and the
        event carries a `message` describing what it needs.

        This matters because AskUserQuestion is not exposed in every Claude build.
        Notification is: the card shows that the session is blocked and on what, a push
        goes out, and the reply box is there to answer with. Claude's own prompt stays
        the source of truth.
    #>
    param([Parameter(Mandatory)]$HookEvent, [int[]]$Ancestors = @())

    $sessionId = [string]$HookEvent.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { return }

    # Only a notification Claude is actually blocked on marks the session waiting.
    # The idle reminder after a finished turn just keeps the registration fresh; the
    # card stays idle, and no push goes out for it.
    if (-not (Test-ClaudeNotificationNeedsUser -Event $HookEvent)) {
        Write-ClaudeSessionRegistration -SessionId $sessionId `
            -TranscriptPath (Resolve-ClaudeTranscriptPath -SessionId $sessionId -KnownPath ([string]$HookEvent.transcript_path)) `
            -WorkingDirectory ([string]$HookEvent.cwd) -ProcessId (Get-ClaudeOwningProcessId -Ancestors $Ancestors) | Out-Null
        return
    }

    $message = [string]$HookEvent.message
    if ([string]::IsNullOrWhiteSpace($message)) { $message = 'Claude is waiting for you.' }
    if ($message.Length -gt 600) { $message = $message.Substring(0, 597) + '...' }

    $owningPid = Get-ClaudeOwningProcessId -Ancestors $Ancestors
    Write-ClaudeSessionRegistration -SessionId $sessionId `
        -TranscriptPath (Resolve-ClaudeTranscriptPath -SessionId $sessionId -KnownPath ([string]$HookEvent.transcript_path)) `
        -WorkingDirectory ([string]$HookEvent.cwd) -ProcessId $owningPid -Status 'waiting' | Out-Null

    # A notification must never delay Claude; the daemon reconciles whatever a miss
    # leaves behind. A notification can be the first thing a session ever does, so the
    # entities are published on demand rather than waiting for the daemon's reconcile.
    $headers = Enter-BridgeAdapterSession
    if (-not $headers) { return }
    $display = Get-ClaudeSessionDisplay -SessionId $sessionId -WorkingDirectory ([string]$HookEvent.cwd)

    [void](Confirm-BridgeSessionEntities -SessionId $sessionId -SessionName $display.Name `
        -Machine $display.Machine -Headers $headers)

    Publish-BridgeSessionStatus -SessionId $sessionId -SessionName $display.Name `
        -Machine $display.Machine -Headers $headers -Status 'waiting' -Activity $message `
        -ExtraAttributes @{ message = $message } -PreserveActivityDetail | Out-Null

    $body = @(
        "Session: $($display.Name)"
        "Machine: $($display.Machine)"
        ''
        $message
        ''
        'Answer in the terminal, or try the Reply box on the dashboard.'
    ) -join "`n"
    $title = Format-BridgeNotificationTitle "Waiting: $($display.Name)"
    Send-BridgeNotification -Title $title -Message $body -Headers $headers | Out-Null

    Write-DecisionBridgeLog -Message (
        "claude Notification: session=$($sessionId.Substring(0,[Math]::Min(8,$sessionId.Length))) " +
        "pid=$owningPid chars=$($message.Length)"
    )
}
