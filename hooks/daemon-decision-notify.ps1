<#
    Bridge daemon: answering a question from the notification itself.

    A question already reaches the phone as a notification, but answering it meant
    opening the dashboard. Home Assistant's companion app supports action buttons on
    an ordinary notification, so the options can be the buttons: tap one and the
    answer goes into the waiting prompt without the app ever being opened.

    Why this lives in the daemon rather than in the hooks. Each client arms its own
    questions - Copilot in copilot-hooks.ps1, Claude in claude-hooks.ps1, Codex in
    codex-hooks.ps1 - but all three write the same decision marker, and the daemon is
    the one place that sees every pending question, for every agent, on every pass.
    Sending from here covers all of them once, and the send is naturally tied to the
    sweep that already knows when a question has been answered and the notification
    should be withdrawn.

    What comes back. Tapping a button fires `mobile_app_notification_action`. The
    `action_data` sent with the notification is echoed back in that event on iOS,
    which is what carries the session and decision identity: an entity id cannot be
    used instead, because the node id in it is sanitised and truncated and there is
    no way back from it to a session id.

    The answer is not delivered by a path of its own. It is handed to
    Invoke-DaemonDecisionAnswer, the same function the dashboard's answers go
    through, so the attempt claiming, the double-answer guard, the terminal-only
    refusal and the verification all apply unchanged. A tapped button is just another
    input to the question, exactly as the native prompt and the card already are.

    Part of agent-bridge-daemon.ps1, which dot-sources it into its own scope after
    declaring the shared $script: state; see docs/daemon-split.md.
    Shared state it changes: DaemonAnswerButtonSent.
#>

# Which questions have already been sent to a phone, so a question is not re-notified
# on every pass. Keyed by decision id; the value is when it went out.
if (-not (Get-Variable -Name DaemonAnswerButtonSent -Scope Script -ErrorAction SilentlyContinue)) {
    $script:DaemonAnswerButtonSent = @{}
}

# Taps that have arrived but not yet been acted on.
#
# This queue is the whole reason the listener exists. The daemon's entity watch opens
# a socket, waits, and disposes it before each reconcile - which is harmless for a
# state change, because the state is still in Home Assistant for the next sweep to
# read. An event is not like that. It is delivered once, to whoever is subscribed at
# that instant, and leaves nothing behind. A tap landing while the reconcile ran was
# therefore lost outright, with the notification still sitting on the phone looking
# as though nothing had happened.
#
# So the subscription is held permanently by a thread of its own and taps are queued.
# Draining can then be as late as it likes; what matters is that nothing is dropped.
if (-not (Get-Variable -Name DaemonAnswerButtonQueue -Scope Script -ErrorAction SilentlyContinue)) {
    $script:DaemonAnswerButtonQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
}
if (-not (Get-Variable -Name DaemonAnswerButtonListener -Scope Script -ErrorAction SilentlyContinue)) {
    $script:DaemonAnswerButtonListener = $null
}

function Get-DaemonAnswerButtonListenerScript {
    <#
        The listener's body, kept separate so its shape can be inspected by a test
        without a socket.

        It is deliberately self-contained and uses only .NET types: it runs in its own
        runspace, where none of the bridge's functions or configuration exist. It never
        cancels an outstanding receive - cancelling one aborts the socket, which is the
        trap that made an earlier hand-rolled listener go deaf after its first idle
        period - and it reconnects on any failure rather than ending.
    #>
    {
        param($Uri, $Token, $Queue, $Stop)

        while (-not $Stop.IsCancellationRequested) {
            $socket = $null
            try {
                $socket = [Net.WebSockets.ClientWebSocket]::new()
                $socket.ConnectAsync([Uri]$Uri, $Stop.Token).GetAwaiter().GetResult()

                $frame = [byte[]]::new(65536)
                $text = [Text.StringBuilder]::new()
                $pending = $null
                $authed = $false

                $send = {
                    param($payload)
                    $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 8 -Compress))
                    $socket.SendAsync([ArraySegment[byte]]::new($bytes),
                        [Net.WebSockets.WebSocketMessageType]::Text, $true, $Stop.Token).GetAwaiter().GetResult()
                }

                while (-not $Stop.IsCancellationRequested -and $socket.State -eq 'Open') {
                    if ($null -eq $pending) {
                        $pending = $socket.ReceiveAsync([ArraySegment[byte]]::new($frame), $Stop.Token)
                    }
                    # Polled, never cancelled.
                    if (-not $pending.Wait(500)) { continue }
                    $result = $pending.Result
                    $pending = $null
                    [void]$text.Append([Text.Encoding]::UTF8.GetString($frame, 0, $result.Count))
                    if (-not $result.EndOfMessage) { continue }
                    $raw = $text.ToString()
                    [void]$text.Clear()

                    $message = $null
                    try { $message = $raw | ConvertFrom-Json } catch { continue }
                    if ($null -eq $message -or -not $message.PSObject.Properties['type']) { continue }

                    switch ([string]$message.type) {
                        'auth_required' { & $send @{ type = 'auth'; access_token = $Token } }
                        'auth_ok' {
                            if (-not $authed) {
                                $authed = $true
                                & $send @{ id = 1; type = 'subscribe_events'; event_type = 'mobile_app_notification_action' }
                            }
                        }
                        'event' {
                            if ($message.PSObject.Properties['event'] -and
                                $message.event.PSObject.Properties['data']) {
                                $Queue.Enqueue(($message.event.data | ConvertTo-Json -Depth 8 -Compress))
                            }
                        }
                    }
                }
            }
            catch { }
            finally {
                if ($null -ne $socket) { try { $socket.Dispose() } catch { } }
            }
            # A dropped socket must not become a spin. The notification is still on the
            # phone throughout, so a tap during the gap can simply be made again.
            if (-not $Stop.IsCancellationRequested) { Start-Sleep -Seconds 3 }
        }
    }
}

function Start-DaemonAnswerButtonListener {
    <#
        Holds the notification-action subscription for as long as the daemon runs.

        Started only when answer buttons are actually configured: an unused
        subscription is a message stream to decode for nothing.
    #>
    if (-not $script:DecisionBridgeConfig.AnswerButtonsEnabled) { return $false }
    if (@($script:DecisionBridgeConfig.AnswerButtonServices).Count -eq 0) { return $false }
    if ($null -ne $script:DaemonAnswerButtonListener) { return $true }

    $uri = ($script:DecisionBridgeConfig.HomeAssistantBaseUrl -replace '^http', 'ws').TrimEnd('/') + '/api/websocket'
    # The same boundary the rest of the bridge goes through, evaluated here rather
    # than inside the runspace, where the test guard does not exist.
    Assert-BridgeHttpAllowed -Uri $uri -Transport WebSocket
    $token = (Get-HomeAssistantHeaders).Authorization -replace '^Bearer ', ''

    try {
        $stop = [Threading.CancellationTokenSource]::new()
        $runspace = [RunspaceFactory]::CreateRunspace()
        $runspace.Open()
        $shell = [PowerShell]::Create()
        $shell.Runspace = $runspace
        [void]$shell.AddScript((Get-DaemonAnswerButtonListenerScript)).
            AddArgument($uri).AddArgument($token).
            AddArgument($script:DaemonAnswerButtonQueue).AddArgument($stop)
        $handle = $shell.BeginInvoke()
        $script:DaemonAnswerButtonListener = [pscustomobject]@{
            Shell = $shell; Runspace = $runspace; Stop = $stop; Handle = $handle
        }
        Write-DaemonLog -Message 'answer button listener started'
        return $true
    }
    catch {
        Write-DaemonLog -Message "answer button listener failed to start: $($_.Exception.Message)"
        $script:DaemonAnswerButtonListener = $null
        return $false
    }
}

function Stop-DaemonAnswerButtonListener {
    <# Ends the listener with the daemon that owns it. #>
    $listener = $script:DaemonAnswerButtonListener
    if ($null -eq $listener) { return }
    $script:DaemonAnswerButtonListener = $null
    try { $listener.Stop.Cancel() } catch { }
    try { [void]$listener.Shell.Stop() } catch { }
    try { $listener.Shell.Dispose() } catch { }
    try { $listener.Runspace.Dispose() } catch { }
    try { $listener.Stop.Dispose() } catch { }
}

function Invoke-DaemonAnswerButtonQueue {
    <#
        Acts on every tap the listener has collected.

        Called from the wait's fast lane and again after each reconcile, so a tap is
        acted on within a tick while idle and is still never missed during a pass that
        takes seconds.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Live
    )

    $handled = 0
    $raw = ''
    while ($script:DaemonAnswerButtonQueue.TryDequeue([ref]$raw)) {
        try {
            $data = $raw | ConvertFrom-Json
            if (Invoke-DaemonAnswerButton -EventData $data -State $State -Live $Live -Headers $Headers) {
                $handled++
            }
        }
        catch {
            if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
            Write-DaemonLog -Message "answer button event failed: $($_.Exception.Message)"
        }
    }
    $handled
}

function Get-BridgeAnswerButtonTag {
    <# The notification this question owns, so answering it can withdraw it. #>
    param([Parameter(Mandatory)][string]$SessionId)
    "bridge_decision_$(Get-CopilotMqttNodeId -SessionId $SessionId)"
}

function Get-BridgeAnswerButtonOptions {
    <#
        The option labels a question can be answered with by tapping, or an empty list
        when it cannot be.

        Three questions get no buttons, and each for a reason that would otherwise
        produce a button that silently does nothing:

          - A terminal-only question. The daemon refuses to inject one at all, so a
            button offering to answer it would be a lie.
          - A question with more than one field. One tap cannot express a value for
            each slot, and injecting a partial answer would leave the prompt waiting
            mid-form.
          - A freeform question. There is nothing to choose; it gets the text action
            instead (Get-BridgeAnswerButtonActions).
    #>
    param([Parameter(Mandatory)]$Marker)

    if ($Marker.PSObject.Properties['terminalOnly'] -and [bool]$Marker.terminalOnly) { return @() }
    if ([string]$Marker.mode -ne 'multiple_choice') { return @() }

    $fields = @()
    if ($Marker.PSObject.Properties['fields']) { $fields = @($Marker.fields | Where-Object { $null -ne $_ }) }
    if ($fields.Count -gt 1) { return @() }

    # A flat `choices` list is what a simple question carries; a single structured
    # field carries its labels in Options instead. Claude populates both, so choices
    # is preferred and the field is the fallback rather than the other way round.
    $choices = @()
    if ($Marker.PSObject.Properties['choices']) {
        $choices = @($Marker.choices | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($choices.Count -eq 0 -and $fields.Count -eq 1) {
        $field = $fields[0]
        $isText = $field.PSObject.Properties['IsText'] -and [bool]$field.IsText
        if (-not $isText -and $field.PSObject.Properties['Options']) {
            $choices = @($field.Options | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    }

    # The CLI renders its own trailing "Other (type your answer)" entry, and that is
    # not a declared option, so it does not normally reach here. An agent that spells
    # one out in its own option list would otherwise get two buttons meaning the same
    # thing - that label, which selects a literal answer, beside the text action that
    # actually opens a box. Dropped, because the text action is the one that works.
    @($choices | Where-Object { [string]$_ -notmatch '^\s*other\s*\(type your answer\)\s*$' })
}

function Get-BridgeAnswerButtonActions {
    <#
        The notification's buttons.

        iOS tolerates about ten before its own list starts misbehaving, and a phone
        showing ten buttons is not better than one showing the few that matter, so the
        list is capped and the overflow is left to the dashboard. The text action is
        always offered: every Copilot option list ends in "Other (type your answer)",
        so words are a real answer to a choice question too, and it is the only way to
        answer a freeform one.
    #>
    param(
        [Parameter(Mandatory)]$Marker,
        [Parameter(Mandatory)][string]$DecisionId,
        [AllowEmptyCollection()][AllowNull()][string[]]$Options = @(),
        [int]$MaxButtons = 6
    )

    # @($null).Count is 1, so a null list would otherwise ask for a button at $null[0].
    if ($null -eq $Options) { $Options = @() }

    # Short, stable, and unique to this question: actions are shared across every
    # notification on the device, so a fixed identifier would let an old notification
    # answer a new question.
    $key = ($DecisionId -replace '[^a-zA-Z0-9]', '')
    if ($key.Length -gt 12) { $key = $key.Substring($key.Length - 12) }

    $actions = [System.Collections.Generic.List[object]]::new()
    $limit = [Math]::Max(0, [Math]::Min($MaxButtons, @($Options).Count))
    for ($i = 0; $i -lt $limit; $i++) {
        $label = [string]$Options[$i]
        $actions.Add(@{
            action = "BRIDGE_${key}_$i"
            title  = Get-BridgeAnswerButtonTitle -Text $label
        })
    }

    # A form is answered slot by slot at an arrow-key prompt, and characters typed at
    # one are discarded. Offering a text box for it would take an answer, deliver it
    # as free text for a multiple_choice marker, and submit a partial or wrong form -
    # so a form gets no text action either, and is left to the card or the terminal.
    $fields = @()
    if ($Marker.PSObject.Properties['fields']) { $fields = @($Marker.fields | Where-Object { $null -ne $_ }) }
    $isForm = $fields.Count -gt 1

    $terminalOnly = $Marker.PSObject.Properties['terminalOnly'] -and [bool]$Marker.terminalOnly
    if (-not $terminalOnly -and -not $isForm) {
        $actions.Add(@{
            action               = "BRIDGE_${key}_text"
            title                = 'Type an answer'
            behavior             = 'textInput'
            textInputButtonTitle = 'Send'
            textInputPlaceholder = 'Your answer'
        })
    }

    @($actions)
}

function Get-BridgeAnswerButtonTitle {
    <#
        A button label short enough to read on a Lock Screen.

        Option labels are written for a terminal and can carry a parenthetical
        explanation - "(Recommended) Open the PR and wait for CI" - which iOS
        truncates in the middle of the button. The leading marker is kept, because it
        is the part that says which one to pick.
    #>
    param([AllowEmptyString()][AllowNull()][string]$Text, [int]$MaxLength = 30)

    $flat = (([string]$Text) -replace '\s+', ' ').Trim()
    if ($flat.Length -le $MaxLength) { return $flat }
    $cut = $flat.Substring(0, $MaxLength)
    $space = $cut.LastIndexOf(' ')
    if ($space -ge [int]($MaxLength * 0.5)) { $cut = $cut.Substring(0, $space) }
    $cut.TrimEnd(' ', ',', '.', ';', ':') + '...'
}

function Get-BridgeAnswerButtonPayload {
    <#
        The notification body: an ordinary one, which is why it looks native, plus the
        buttons and the identity echoed back when one is tapped.

        An icon and a background colour make iOS render it as a *communication*
        notification - the rounded-avatar style messaging apps use, with `title` as
        the sender. That is why the title is the session name: the question then
        arrives looking like the session itself saying something, which is both more
        legible on a Lock Screen and unmistakably not an ordinary alert.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)]$Marker,
        [AllowEmptyCollection()][object[]]$Actions = @(),
        [string]$DashboardUrlPath = 'agent-decisions',
        [string]$MachineName = '',
        [string]$Icon = 'mdi:chat-question',
        [string]$IconColor = '#FFFFFF',
        [string]$Color = '#FF9F0A',
        [string]$InterruptionLevel = 'time-sensitive'
    )

    $question = (([string]$Marker.question) -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($question)) { $question = 'This session is waiting for an answer.' }

    $data = @{
        tag         = Get-BridgeAnswerButtonTag -SessionId $SessionId
        url         = "/$DashboardUrlPath/decision"
        actions     = @($Actions | Where-Object { $null -ne $_ })
        # Several questions at once stack under one heading instead of scattering.
        group       = 'agent-bridge'
        action_data = @{
            bridge   = 'decision'
            session  = $SessionId
            decision = [string]$Marker.decisionId
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Icon)) {
        $data['notification_icon'] = $Icon
        $data['notification_icon_color'] = $IconColor
        $data['color'] = $Color
    }
    if (-not [string]::IsNullOrWhiteSpace($InterruptionLevel)) {
        $data['interruption-level'] = $InterruptionLevel
    }
    # Which machine is asking, which the title cannot say without crowding out the
    # session name it needs to carry.
    if (-not [string]::IsNullOrWhiteSpace($MachineName)) {
        $data['subtitle'] = "$MachineName - waiting on you"
    }

    @{
        title   = $SessionName
        message = $question
        data    = $data
    }
}

function Send-BridgeAnswerButtonNotification {
    <#
        Sends one already-built payload to every configured phone. A failure against
        one is logged and swallowed so the rest still get it: the question is already
        on the dashboard and in the terminal, and losing the push must not fail it.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Payload,
        [Parameter(Mandatory)][hashtable]$Headers,
        [string[]]$Services = @($script:DecisionBridgeConfig.AnswerButtonServices)
    )

    $sent = 0
    foreach ($service in @($Services)) {
        $name = [string]$service
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $parts = $name.Split('.')
        if ($parts.Count -ne 2) {
            Write-DaemonLog -Message "answerButtons.services entry '$name' is not domain.service; skipping"
            continue
        }
        try {
            Invoke-HomeAssistantService -Domain $parts[0] -Service $parts[1] -Headers $Headers -Data $Payload | Out-Null
            $sent++
        }
        catch {
            if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
            Write-DaemonLog -Message "answer buttons via $name failed: $($_.Exception.Message)"
        }
    }
    $sent
}

function Sync-DaemonAnswerButtons {
    <#
        Puts a newly pending question on the phone, once.

        Called from the decision sweep for each question that is armed and still
        waiting, so a question that was answered earlier in the same pass is never
        notified.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$Marker,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    if (-not $script:DecisionBridgeConfig.AnswerButtonsEnabled) { return }
    if (@($script:DecisionBridgeConfig.AnswerButtonServices).Count -eq 0) { return }

    $decisionId = [string]$Marker.decisionId
    if ([string]::IsNullOrWhiteSpace($decisionId)) { return }
    if ($script:DaemonAnswerButtonSent.ContainsKey($decisionId)) { return }

    try {
        $name = ''
        if ($State.ContainsKey($SessionId) -and $null -ne $State[$SessionId] -and
            $State[$SessionId].PSObject.Properties['Name']) {
            $name = [string]$State[$SessionId].Name
        }
        if ([string]::IsNullOrWhiteSpace($name)) { $name = 'Agent session' }

        # Wrapped, because a form or freeform question has no options and the bare
        # empty array comes back as $null. Unwrapped, every such question failed with
        # "Cannot index into a null array" and never reached the phone at all. The
        # actions need the same: none came back as $null, which put a null action in
        # the payload and then threw on .Count after the send, so the question was
        # never recorded as sent and would have been re-sent on every pass.
        $options = @(Get-BridgeAnswerButtonOptions -Marker $Marker)
        $actions = @(Get-BridgeAnswerButtonActions -Marker $Marker -DecisionId $decisionId `
            -Options $options -MaxButtons ([int]$script:DecisionBridgeConfig.AnswerButtonMax))
        $payload = Get-BridgeAnswerButtonPayload -SessionId $SessionId -SessionName $name -Marker $Marker `
            -Actions $actions -DashboardUrlPath ([string]$script:DecisionBridgeConfig.DashboardUrlPath) `
            -MachineName $script:DaemonMachineName `
            -Icon ([string]$script:DecisionBridgeConfig.AnswerButtonIcon) `
            -IconColor ([string]$script:DecisionBridgeConfig.AnswerButtonIconColor) `
            -Color ([string]$script:DecisionBridgeConfig.AnswerButtonColor) `
            -InterruptionLevel ([string]$script:DecisionBridgeConfig.AnswerButtonInterruption)

        $sent = Send-BridgeAnswerButtonNotification -Payload $payload -Headers $Headers
        if ($sent -gt 0) {
            # Recorded even though it is only a de-duplication key, because a question
            # re-notified on every 15-second pass is worse than one not notified.
            $script:DaemonAnswerButtonSent[$decisionId] = [DateTimeOffset]::Now
            Write-DaemonLog -Message "answer buttons sent for $($SessionId.Substring(0,8)) ($($actions.Count) action(s))"
        }
    }
    catch {
        if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
        Write-DaemonLog -Message "answer buttons failed for $SessionId : $($_.Exception.Message)"
    }
}

function Clear-DaemonAnswerButtons {
    <#
        Withdraws the notification for a question that is no longer waiting.

        Without this an answered question keeps a notification offering buttons that
        would be refused if tapped, which reads as the bridge having lost the answer.

        `Forget` is deliberately separate from withdrawing. Injection does not wait for
        the transcript to confirm the answer, and the loop reconciles immediately
        afterwards - so for a client whose injector returns early, the very next sweep
        can still see the question as pending. Dropping the de-duplication entry at the
        same time as the notification therefore re-sent the question that had just been
        answered. Only Complete-DaemonAnsweredDecision, which runs once the question is
        actually finished, forgets it.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [AllowNull()]$Marker,
        [Parameter(Mandatory)][hashtable]$Headers,
        [switch]$Forget
    )

    if (-not $script:DecisionBridgeConfig.AnswerButtonsEnabled) { return }
    if (@($script:DecisionBridgeConfig.AnswerButtonServices).Count -eq 0) { return }

    $decisionId = ''
    if ($null -ne $Marker -and $Marker.PSObject.Properties['decisionId']) { $decisionId = [string]$Marker.decisionId }

    try {
        $payload = @{
            message = 'clear_notification'
            data    = @{ tag = (Get-BridgeAnswerButtonTag -SessionId $SessionId) }
        }
        [void](Send-BridgeAnswerButtonNotification -Payload $payload -Headers $Headers)
    }
    catch {
        if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
        Write-DaemonLog -Message "answer button clear failed for $SessionId : $($_.Exception.Message)"
    }
    finally {
        if ($Forget -and $decisionId) { $script:DaemonAnswerButtonSent.Remove($decisionId) }
    }
}

function Get-BridgeAnswerButtonChoice {
    <#
        What a tapped button means, as { SessionId, DecisionId, Index, ReplyText }, or
        $null when the event is not one of ours.

        Read from `action_data` rather than parsed out of the action string. The
        string is only a uniqueness token; the identity has to survive being echoed
        through the phone, and an entity id could not carry it because a node id
        cannot be turned back into a session id.
    #>
    param([AllowNull()]$EventData)

    if ($null -eq $EventData) { return $null }
    if (-not $EventData.PSObject.Properties['action_data']) { return $null }
    $data = $EventData.action_data
    if ($null -eq $data -or -not $data.PSObject.Properties['bridge']) { return $null }
    if ([string]$data.bridge -ne 'decision') { return $null }
    if (-not $data.PSObject.Properties['session'] -or -not $data.PSObject.Properties['decision']) { return $null }

    $sessionId = [string]$data.session
    $decisionId = [string]$data.decision
    if ([string]::IsNullOrWhiteSpace($sessionId) -or [string]::IsNullOrWhiteSpace($decisionId)) { return $null }

    $reply = ''
    if ($EventData.PSObject.Properties['reply_text']) { $reply = [string]$EventData.reply_text }

    # The index is the one thing taken from the action string, because it is per
    # button rather than per notification and action_data is shared by all of them.
    $index = -1
    if ($EventData.PSObject.Properties['action']) {
        $action = [string]$EventData.action
        if ($action -match '_(\d+)$') { $index = [int]$Matches[1] }
    }

    [pscustomobject]@{
        SessionId  = $sessionId
        DecisionId = $decisionId
        Index      = $index
        ReplyText  = $reply
    }
}

function Invoke-DaemonAnswerButton {
    <#
        Delivers an answer tapped on a phone into the waiting prompt.

        Everything that makes this safe is borrowed rather than reimplemented: the
        question must still be pending, and the delivery goes through
        Invoke-DaemonDecisionAnswer, which claims the attempt and refuses a second
        one. A button tapped twice, or tapped after the question was answered in the
        terminal, is therefore refused rather than typed again.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$EventData,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Live,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $choice = Get-BridgeAnswerButtonChoice -EventData $EventData
    if ($null -eq $choice) { return $false }

    $sessionId = $choice.SessionId
    if (-not $Live.ContainsKey($sessionId)) {
        Write-DaemonLog -Message "answer button for a session that is no longer live; ignored"
        return $false
    }

    $marker = Get-CopilotDecisionMarker -SessionId $sessionId
    if ($null -eq $marker) {
        Write-DaemonLog -Message "answer button arrived after the question was answered; ignored"
        return $false
    }
    # The notification outlives the question it was sent for, so a button tapped from
    # a stale one must not answer whatever is being asked now.
    if ([string]$marker.decisionId -ne $choice.DecisionId) {
        Write-DaemonLog -Message "answer button is for an earlier question; ignored"
        return $false
    }

    $askState = Get-DaemonAskUserState -Session $Live[$sessionId] -Marker $marker
    if (-not $askState.Started -or -not $askState.Pending) {
        Write-DaemonLog -Message "answer button for a question already answered; ignored"
        Clear-DaemonAnswerButtons -SessionId $sessionId -Marker $marker -Headers $Headers
        return $false
    }

    $isChoice = ([string]$marker.mode -eq 'multiple_choice')
    $answer = ''
    $isFreeText = $false
    $selections = @()

    if (-not [string]::IsNullOrWhiteSpace($choice.ReplyText)) {
        $answer = $choice.ReplyText.Trim()
        # Typed at a choice question, the words go in through the prompt's own "Other"
        # entry rather than being hunted for in an option list they were never in.
        $isFreeText = $true
    }
    else {
        $options = @(Get-BridgeAnswerButtonOptions -Marker $marker)
        if ($choice.Index -lt 0 -or $choice.Index -ge $options.Count) {
            Write-DaemonLog -Message "answer button names no option this question has; ignored"
            return $false
        }
        $answer = [string]$options[$choice.Index]
        if ($isChoice) { $selections = @($answer) }
    }

    if ([string]::IsNullOrWhiteSpace($answer)) { return $false }

    $delivered = Invoke-DaemonDecisionAnswer -SessionId $sessionId -Marker $marker `
        -Answer $answer -IsChoice $isChoice -IsFreeText $isFreeText `
        -Selections $selections -State $State -Headers $Headers

    if ($delivered) {
        Write-DaemonLog -Message "answered from a phone for $($sessionId.Substring(0,8))"
        Clear-DaemonAnswerButtons -SessionId $sessionId -Marker $marker -Headers $Headers
    }
    [bool]$delivered
}
