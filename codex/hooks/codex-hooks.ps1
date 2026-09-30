<#
    What the Codex hook does, as a function.

    codex-bridge-hook.ps1 reads the event and calls Invoke-CodexHook. The daemon calls it
    too, for events the native hook spooled to it (see docs/fast-hooks.md), so both
    paths run the same code.

    Needs codex-session.ps1 and the bridge core (decision-bridge-common, decision-mqtt,
    decision-ha-websocket, bridge-adapter) loaded. Writes nothing to stdout; the caller
    fails open.
#>

function Invoke-CodexHook {
    <#
        One event, dispatched on hook_event_name:

          SessionStart      publish the session's card
          UserPromptSubmit  mark it working, show the prompt
          PreToolUse        show the running tool; surface a command awaiting approval
          Stop              mark it idle, publish the reply, push a notification
          SessionEnd        retire the card

        -Ancestors is the process chain the native hook recorded, nearest first; a hook
        script passes none, and the owning window is found by walking up from itself.
    #>
    param([Parameter(Mandatory)]$HookEvent, [int[]]$Ancestors = @())

    $sessionId = [string]$HookEvent.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { return }
    $eventName = [string]$HookEvent.hook_event_name
    $workingDirectory = [string]$HookEvent.cwd

    # Later local lifecycle events revoke an approval even if discovery, the daemon
    # fast path or Home Assistant is unavailable.
    $approvalRemoved = $false
    if ($eventName -in @('SessionStart', 'UserPromptSubmit', 'PreToolUse', 'Stop', 'SessionEnd')) {
        $approvalRemoved = Remove-CodexApprovalMarker -SessionId $sessionId
    }

    $field = {
        param([string]$Name)
        if ($HookEvent.PSObject.Properties.Name -contains $Name) { return [string]$HookEvent.$Name }
        ''
    }

    # Work out what this event means for the card before touching the network.
    $status = ''
    $activity = ''
    $response = ''
    $activityDetail = $null
    $pendingApproval = $false
    switch ($eventName) {
        'SessionStart' { $status = 'idle'; $activity = 'Session started' }
        'UserPromptSubmit' {
            $status = 'working'
            $prompt = & $field 'prompt'
            if ($prompt.Length -gt 160) { $prompt = $prompt.Substring(0, 157) + '...' }
            $activity = if ($prompt) { "Prompt: $prompt" } else { 'Working' }
        }
        'PermissionRequest' {
            # Codex runs this before showing its own approval UI, and an empty stdout
            # means "no decision", so the terminal prompt still appears. The card is
            # therefore a second way to answer rather than a replacement, which is the
            # same dual-input arrangement the Copilot bridge uses for ask_user.
            $status = 'waiting'
            $pendingApproval = $true
            $tool = & $field 'tool_name'
            $activity = "Needs approval: $tool"
            if ($HookEvent.PSObject.Properties.Name -contains 'tool_input' -and
                $HookEvent.tool_input -and
                $HookEvent.tool_input.PSObject.Properties['command']) {
                $command = [string]$HookEvent.tool_input.command
                if ($command.Length -gt 300) { $command = $command.Substring(0, 297) + '...' }
                if ($command) { $activity = "Needs approval: $command" }
            }
        }
        'PreToolUse' {
            $status = 'working'
            $tool = & $field 'tool_name'
            $activity = if ($tool) { "Running: $tool" } else { 'Running a tool' }
            # A command is the one tool detail worth showing: it is what you would
            # want to see before approving something from a phone.
            if ($HookEvent.PSObject.Properties.Name -contains 'tool_input' -and
                $HookEvent.tool_input -and
                $HookEvent.tool_input.PSObject.Properties['command']) {
                $command = [string]$HookEvent.tool_input.command
                if ($command.Length -gt 200) { $command = $command.Substring(0, 197) + '...' }
                if ($command) { $activity = "$activity - $command" }
            }
        }
        'Stop' {
            $status = 'idle'
            $response = & $field 'last_assistant_message'
            # The status line is a state, cut at 255 characters, so it gets the first
            # line; the reply itself goes to the card as `response`, shown in full.
            # Published as the status line alone, a long reply was cut off with no way
            # to read the rest.
            $activity = 'Idle'
            if ($response) {
                $first = @($response -split '\r?\n' | Where-Object { $_.Trim() })[0]
                $activity = if ($first.Length -gt 200) { $first.Substring(0, 197) + '...' } else { $first }
                $shown = $response.Trim()
                if ($shown.Length -gt 6000) { $shown = $shown.Substring(0, 6000).TrimEnd() + "`n`n_(truncated - see terminal)_" }
                $activityDetail = @{ response = $shown; response_kind = 'text' }
            }
        }
        'SessionEnd' { $status = 'ended' }
        default { return }
    }

    $decisionId = ''
    $question = $activity
    if ($pendingApproval) {
        $requestId = & $field 'tool_use_id'
        $current = Get-CodexApprovalMarker -SessionId $sessionId
        if ($requestId -and $null -ne $current -and $current.PSObject.Properties['ToolCallId'] -and
            [string]$current.ToolCallId -ceq $requestId) {
            Write-DecisionBridgeLog -Message "ignored repeated codex approval hook for $sessionId"
            return
        }
        [void](Remove-CodexApprovalMarker -SessionId $sessionId)
        $decisionId = "$(Get-CopilotMqttNodeId -SessionId $sessionId)-$([guid]::NewGuid().ToString('N'))"
        Write-CodexApprovalMarker -SessionId $sessionId -DecisionId $decisionId -Question $question `
            -ToolCallId $requestId -ToolName (& $field 'tool_name') -TurnId (& $field 'turn_id')
    }

    # The window this session runs in, which replies are typed into. -Ancestors only
    # when there is a chain, so an older codex-session.ps1 is never handed a parameter
    # it does not know.
    $ownerPid = if (@($Ancestors).Count -gt 0) { Get-CodexOwningProcessId -SessionId $sessionId -Ancestors $Ancestors }
        else { Get-CodexOwningProcessId -SessionId $sessionId }

    # Local state first, so a Home Assistant outage cannot lose the session record.
    Write-CodexSessionRegistration -SessionId $sessionId `
        -TranscriptPath (& $field 'transcript_path') `
        -WorkingDirectory $workingDirectory `
        -Model (& $field 'model') `
        -Status $status -Activity $activity `
        -ProcessId $ownerPid `
        -Ended:($eventName -eq 'SessionEnd') | Out-Null

    Write-DecisionBridgeLog -Message (
        "codex ${eventName}: session=$($sessionId.Substring(0,[Math]::Min(8,$sessionId.Length))) status=$status"
    )

    # A hook must never wait on the network; the daemon reconciles whatever a miss
    # leaves behind. SessionEnd is special: Codex clamps it to three seconds, not
    # enough to retire a session's entities without leaving a card behind, so the
    # registration above is already marked ended and the daemon retires it on the next
    # reconcile.
    if ($eventName -eq 'SessionEnd') { return }

    # A prompt or a tool call is published by the daemon, from the registration just
    # written, within a tenth of a second - while Codex, which waits for every hook,
    # carries on. Publishing here cost about half a second a tool call. Only while the
    # daemon is running: otherwise nothing else would publish it.
    if ($eventName -in @('UserPromptSubmit', 'PreToolUse') -and (Test-BridgeDaemonAlive)) { return }

    $headers = Enter-BridgeAdapterSession
    if (-not $headers) { return }
    $display = Get-CodexSessionDisplay -SessionId $sessionId -WorkingDirectory $workingDirectory

    [void](Confirm-BridgeSessionEntities -SessionId $sessionId -SessionName $display.Name `
        -Machine $display.Machine -Headers $headers)

    # A new prompt starts the card afresh; every other event keeps what it shows - the
    # reasoning the daemon streams, the reply - and changes the status line.
    Publish-BridgeSessionStatus -SessionId $sessionId -SessionName $display.Name `
        -Machine $display.Machine -Headers $headers -Status $status -Activity $activity `
        -ExtraAttributes @{ model = (& $field 'model'); process_id = $ownerPid } `
        -PreserveActivityDetail:($eventName -notin @('UserPromptSubmit', 'SessionStart')) `
        -ActivityDetail $activityDetail | Out-Null

    if ($pendingApproval) {
        # Arm the selector so the command can be approved from the dashboard. The
        # marker is the daemon's gate: while it exists, an answer on the card is
        # delivered into the session's own approval prompt.
        $choices = @('Approve', 'Deny')
        if (-not (& $field 'tool_use_id')) {
            $choices = @()
            $question += "`n`nAnswer in the terminal: this client did not identify the approval request."
        }
        Set-CopilotMqttDecision -SessionId $sessionId -SessionName $display.Name `
            -Machine $display.Machine -Question $question -Choices $choices `
            -Fields @() -DecisionId $decisionId -Headers $headers | Out-Null
        Send-BridgeNotification -Title (Format-BridgeNotificationTitle "Approval needed: $($display.Name)") `
            -Message $question -Headers $headers | Out-Null
    }
    elseif ($approvalRemoved) {
        # Whatever was awaiting approval has been answered - in the terminal or on the
        # dashboard - because the tool is now running or the turn has finished.
        try {
            Clear-CopilotMqttDecision -SessionId $sessionId -SessionName $display.Name `
                -Machine $display.Machine -Headers $headers | Out-Null
        }
        catch { Write-DecisionBridgeLog -Message "codex approval card clear failed: $($_.Exception.Message)" }
    }

    if ($eventName -eq 'Stop') {
        Send-BridgeResponseNotification -SessionName $display.Name -Response $response -Headers $headers | Out-Null
    }
}
