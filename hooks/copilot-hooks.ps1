<#
    What each Copilot CLI hook does, as functions.

    The hook scripts (route-ask-user-v3.ps1, notify-agent-response.ps1,
    notify-home-assistant.ps1) read the event, call these and print their fixed reply.
    The daemon can call them too, for events spooled to it (see docs/fast-hooks.md).

    None of these write to stdout; the caller prints the reply Copilot expects and
    fails open. They need decision-bridge-common.ps1 loaded, and the first two
    bridge-adapter.ps1, the first decision-mqtt.ps1 and decision-ha-websocket.ps1.
#>

function Get-CopilotMixedFormHint {
    <#
        What to tell someone answering a form that mixes dropdowns with a free-text
        field. On a current card the dashboard draws two send controls, and only one
        of them carries the typed words:

          Send (reply card)   publishes the textarea, and that publish submits a
                              complete form on its own - Read-DaemonFormAnswer's
                              $cardSubmits. One press, text included.
          Send answer         presses the submit entity and nothing else. The
                              textarea is never published, so Read-DaemonFormAnswer
                              finds no payload, falls back to text.<node>_reply,
                              which the card does not write, and submits the form
                              with that field empty - an empty free-text field being
                              a valid answer. The typed words are gone.

        So this points at Send and warns off Send answer by name. On cards before
        1.22.0 there is no Send answer: the generator draws one icon-only button
        beside the "Reply / continue" row, the text lives in text.<node>_reply, and
        the warning is simply moot.

        Reversed once, on 2026-10-07, on the reasoning that "Send answer" must be the
        committing control because it is the one labelled for it. It is not, and the
        review that caught it was right: naming the wrong button here does not merely
        misdirect, it loses what was typed.

        An instruction is mitigation, not a guard. The fix is for Send answer to
        publish the textarea before pressing submit, which is a card change - new
        CARD_VERSION, gated in the generator, both shapes tested - and is tracked
        on #93.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Label)
    "*Type **$Label** in the Reply box, choose the rest above, then press **Send** " +
        "beside the box. Not **Send answer** - it submits without your text.*"
}

function Invoke-CopilotAskUserHook {
    <#
        preToolUse for ask_user - dual-input, non-blocking:
          1. Writes a pending-decision marker before any network work.
          2. Ensures this session's Home Assistant entities exist.
          3. Arms this session's MQTT decision card with the question and choices.
          4. Sends an optional push notification.
        The caller then returns `allow` at once, so the native terminal prompt appears.

        Why non-blocking: the previous router blocked until Home Assistant returned an
        answer, then denied the tool with that answer. Blocking froze the terminal:
        anything typed there was queued by the CLI behind the blocked hook, so you could
        only answer from Home Assistant, never the terminal. Worse, the daemon also
        injects Home Assistant replies, so the two raced and an answer could be both
        denied by the hook and injected into the console.

        Now the native terminal prompt is the single source of truth, and Home Assistant
        is a second input device: the daemon watches the card and, while the ask_user is
        still pending, injects the answer into the same prompt. Whichever is used first
        wins; the transcript's matching tool.execution_complete is the authoritative
        "answered" signal, and the daemon clears the card on it.
    #>
    param([Parameter(Mandatory)]$HookEvent)

    # Fields read only when present, so an event missing one reads the same under
    # strict mode (the daemon's tests) as without it (the hook).
    $field = { param($Object, [string]$Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } }

    $toolArgs = & $field $HookEvent 'toolArgs'
    if ($null -eq $toolArgs) { $toolArgs = & $field $HookEvent 'tool_input' }
    if ($toolArgs -is [string]) { $toolArgs = ConvertFrom-DecisionJson -Json $toolArgs }
    if ($null -ne (& $field $toolArgs 'arguments')) {
        $toolArgs = $toolArgs.arguments
        if ($toolArgs -is [string]) { $toolArgs = ConvertFrom-DecisionJson -Json $toolArgs }
    }

    $explicitChoices = @()
    $rawChoices = & $field $toolArgs 'choices'
    if ($rawChoices -is [array]) {
        $explicitChoices = @(Get-DecisionSchemaFieldChoices -Field ([pscustomobject]@{ enum = $rawChoices }))
    }
    $parsed = Repair-DecisionToolArguments -ToolArgs $toolArgs
    $question = $parsed.Question
    $choices = @($parsed.Choices)
    $combos = @($parsed.Combos)
    $fields = @($parsed.Fields)
    if ($explicitChoices.Count -gt 0) { $choices = @($explicitChoices | ForEach-Object { $_.Label }) }
    elseif ($fields.Count -eq 1 -and $choices.Count -gt 0) { $choices = @($fields[0].Options) }
    [void](Get-DecisionSchemaFieldChoices -Field ([pscustomobject]@{ enum = $choices }))
    $terminalOnly = [bool]$parsed.TerminalOnly
    $mode = if ($choices.Count -gt 0 -or $fields.Count -gt 0) { 'multiple_choice' } else { 'freeform' }

    # Say so on the card rather than offering a box that cannot work. The native
    # prompt here is an arrow-key form the dashboard cannot drive, and anything typed
    # at it is discarded, so the honest thing is to send the user to the terminal.
    if ($terminalOnly) {
        $question = "$question`n`n**This one has to be answered in the terminal** - it has more fields than the dashboard can drive, so a reply typed here would not reach the prompt."
    }
    else {
        # A mixed form answers its dropdowns from the field selectors and its one
        # free-text field from the Reply box, so say which is which - otherwise the
        # box looks like an unrelated "continue the conversation" field.
        $textField = @($fields | Where-Object { Test-DecisionFieldIsText -Field $_ }) | Select-Object -First 1
        if ($null -ne $textField) {
            $question = "$question`n`n$(Get-CopilotMixedFormHint -Label ([string]$textField.Label))"
        }
    }

    $argKeys = if ($null -ne $toolArgs) {
        (@($toolArgs.PSObject.Properties.Name) -join ',')
    }
    else { '<none>' }
    Write-DecisionBridgeLog -Message (
        "ask_user parsed (v3): argKeys=[$argKeys] choices=$($choices.Count) fields=$($fields.Count) mode=$mode terminalOnly=$terminalOnly questionChars=$($question.Length)"
    )

    $sessionId = [string](& $field $HookEvent 'sessionId')
    if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = "unknown-$PID" }
    $workingDirectory = [string](& $field $HookEvent 'cwd')
    if ([string]::IsNullOrWhiteSpace($workingDirectory)) { $workingDirectory = 'Unknown folder' }

    $node = Get-CopilotMqttNodeId -SessionId $sessionId
    $decisionId = "$($node)-$(& $field $HookEvent 'timestamp')"

    # The marker is the daemon's gate: while it exists and the transcript shows the
    # ask_user still pending, the daemon injects a Home Assistant answer and clears the
    # card on completion. It also carries the combo mapping so a multi-field choice can
    # be reported field by field. Persist before even the reachability probe, so an
    # outage leaves the daemon a request to re-arm.
    Write-CopilotDecisionMarker -SessionId $sessionId -DecisionId $decisionId `
        -Question $question -Choices $choices -Combos $combos -Fields $fields `
        -TerminalOnly:$terminalOnly -Mode $mode | Out-Null

    # This hook runs before the native prompt appears; it must never wait on the
    # network. Enter-BridgeAdapterSession probes, sets the deadline and returns headers
    # when Home Assistant is reachable, or $null when it is not.
    $headers = Enter-BridgeAdapterSession
    if (-not $headers) { return }
    $display = Get-CopilotSessionDisplay -SessionId $sessionId -WorkingDirectory $workingDirectory

    # Ensure this session's entities exist. The daemon publishes them within a
    # reconcile interval of session start, but an ask_user in the first seconds of a
    # brand-new session may beat it, so publish on demand and force deterministic ids.
    [void](Confirm-BridgeSessionEntities -SessionId $sessionId -SessionName $display.Name `
        -Machine $display.Machine -Headers $headers -ProbeEntity "select.${node}_decision")

    Set-CopilotMqttDecision -SessionId $sessionId -SessionName $display.Name `
        -Machine $display.Machine -Question $question -Choices $choices `
        -Fields $fields -DecisionId $decisionId -Headers $headers | Out-Null

    # Notify. Both paths (terminal and Home Assistant) are now open.
    if ($choices.Count -gt 0) {
        $numbered = for ($i = 0; $i -lt $choices.Count; $i++) { "$($i + 1). $($choices[$i])" }
        $body = @(
            "Session: $($display.Name)"
            "Machine: $($display.Machine)"
            ''
            $question
            ''
            ($numbered -join "`n")
            ''
            'Answer in the terminal or on the Agent Sessions dashboard.'
        ) -join "`n"
    }
    else {
        $body = @(
            "Session: $($display.Name)"
            "Machine: $($display.Machine)"
            ''
            $question
            ''
            'Answer in the terminal or in the Reply box on the Agent Sessions dashboard.'
        ) -join "`n"
    }
    if ($body.Length -gt 950) { $body = $body.Substring(0, 947) + '...' }
    $title = Format-BridgeNotificationTitle "Copilot: $($display.Name)"
    Send-BridgeNotification -Title $title -Message $body -Headers $headers | Out-Null
}

function Invoke-CopilotAgentStopHook {
    <#
        agentStop: mirrors a completed Copilot turn to Home Assistant as a notification.

        The session card on the dashboard already carries the full response - the bridge
        daemon streams it there from the transcript - so this only sends the optional
        out-of-band push, and is a no-op when notifications are disabled.

        It is deliberately non-blocking. An earlier design held the turn open here to
        carry a dashboard reply back as the next prompt, which deadlocked: while the
        hook blocks, the CLI queues anything typed in the terminal, so the escape signal
        it was waiting for could never arrive. Continuation is now the daemon's job,
        delivered by writing to the session's console.
    #>
    param([Parameter(Mandatory)]$HookEvent)

    $sessionId = [string]$HookEvent.sessionId
    $transcriptPath = [string]$HookEvent.transcriptPath
    if (
        [string]::IsNullOrWhiteSpace($transcriptPath) -or
        -not (Test-Path -LiteralPath $transcriptPath)
    ) {
        $transcriptPath = Join-Path (
            Join-Path $script:DecisionBridgeConfig.SessionStateRoot $sessionId
        ) 'events.jsonl'
    }
    if (-not (Test-Path -LiteralPath $transcriptPath)) { return }

    # Last assistant message with content is the response that just finished.
    $response = $null
    foreach ($line in @(Get-CopilotTranscriptTailLines -Path $transcriptPath)) {
        if (-not $line.StartsWith('{"type":"assistant.message"')) { continue }
        try {
            $content = [string]($line | ConvertFrom-Json).data.content
            if (-not [string]::IsNullOrWhiteSpace($content)) { $response = $content.Trim() }
        }
        catch { continue }
    }
    if ([string]::IsNullOrWhiteSpace($response)) { return }

    $display = Get-CopilotSessionDisplay -SessionId $sessionId -WorkingDirectory ([string]$HookEvent.cwd)

    Send-BridgeResponseNotification -SessionName $display.Name -Response $response `
        -Headers (Get-HomeAssistantHeaders) -TitlePrefix 'Copilot response' `
        -DashboardLabel 'the Agent Sessions dashboard' | Out-Null
}

function Invoke-CopilotPermissionHook {
    <#
        notification (permission_prompt): mirrors a Copilot permission prompt to Home
        Assistant as a one-way alert. It is purely informational - the prompt is still
        answered in the terminal.
    #>
    param([Parameter(Mandatory)]$HookEvent)

    $title = [string]$HookEvent.title
    $message = [string]$HookEvent.message

    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = if ($HookEvent.notification_type -eq 'permission_prompt') {
            'Copilot permission needed'
        }
        else {
            'Copilot decision needed'
        }
    }
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = 'Copilot CLI is waiting for your input.'
    }

    # Send-BridgeNotification is a no-op when notifications are disabled in the config.
    Send-BridgeNotification -Title $title -Message $message -Headers (Get-HomeAssistantHeaders) | Out-Null
}
