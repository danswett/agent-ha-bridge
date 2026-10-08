<#
    Bridge daemon: what a session is doing, onto its card.

    Reads transcripts and the hooks' registrations, turns them into the card's
    status line, response, reasoning and history, and streams them - including the
    fast lane that runs between reconciles.

    Part of agent-bridge-daemon.ps1, which dot-sources it into its own scope after
    declaring the shared $script: state; see docs/daemon-split.md.
    Shared state it changes: DaemonRegistrationStamps, DaemonTranscriptFailureReported.
#>

function Format-CardText {
    <#
        Truncates card text to a readable preview so a long response or reasoning block
        cannot make one card tower over the others and unbalance the dashboard grid.
        The full text is always available in the terminal.
    #>
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory)][int]$MaxChars
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $trimmed = $Text.Trim()
    if ($trimmed.Length -le $MaxChars) { return $trimmed }
    $trimmed.Substring(0, $MaxChars).TrimEnd() + '…'
}

function Read-BridgeTranscriptAppend {
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$Offset = 0,
        [string]$Kind = 'copilot'
    )

    & (Get-DaemonAgent -Kind $Kind).ReadAppend $Path $Offset
}

function Get-BridgeActivity {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][bool]$VerboseMode,
        [string]$Kind = 'copilot'
    )

    & (Get-DaemonAgent -Kind $Kind).Activity $Lines $VerboseMode
}

function Test-BridgeSessionWorking {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$Kind = 'copilot',
        [string]$Transcript,
        [string]$Status
    )

    [bool](& (Get-DaemonAgent -Kind $Kind).IsWorking $SessionId $Transcript $Status)
}

function ConvertTo-DaemonActivityInstant {
    <# JSON may already have decoded a date; formatting it first loses ticks and Kind. #>
    param([AllowNull()][object]$Value)

    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [datetime]) { return [DateTimeOffset]::new($Value) }
    if ($Value -is [string]) {
        $instant = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($Value, [ref]$instant)) { return $instant }
    }
    $null
}

function Get-DaemonFailedStopRequestTime {
    <# An old stop press is not an error once native activity has recovered the entry. #>
    param([Parameter(Mandatory)]$Entry)

    if ($Entry.PSObject.Properties['Status'] -and [string]$Entry.Status -eq 'error' -and
        $Entry.PSObject.Properties['LastStopAt']) {
        return (ConvertTo-DaemonActivityInstant -Value $Entry.LastStopAt)
    }
    $null
}

function Sync-DaemonHookStatus {
    <#
        Adopts the status a Claude hook last set, once per hook event.

        Hooks publish 'idle' and 'waiting' to Home Assistant themselves; recording
        them here is what lets the transcript loop see the session resume and send
        'working' again. 'working' comes from UserPromptSubmit, which does not talk to
        Home Assistant, so it is published from here.

        Returns when that hook fired, or $null when no hook status is recorded, so the
        caller can ignore transcript lines older than it.
    #>
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    if (-not $Session.PSObject.Properties['HookStatus'] -or [string]::IsNullOrWhiteSpace([string]$Session.HookStatus)) { return $null }
    $at = ConvertTo-DaemonActivityInstant -Value $Session.HookStatusAt
    if ($null -eq $at) { return $null }

    $failedStopAt = Get-DaemonFailedStopRequestTime -Entry $Entry
    if ($null -ne $failedStopAt -and $at -le $failedStopAt) { return $at }

    $seen = if ($Entry.PSObject.Properties['HookStatusAt']) { ConvertTo-DaemonActivityInstant -Value $Entry.HookStatusAt } else { $null }
    if ($null -ne $seen -and $seen -eq $at) { return $at }

    $status = [string]$Session.HookStatus
    if ($status -eq 'working' -and $status -ne [string]$Entry.Status) {
        try {
            Set-CopilotMqttStatus -SessionId $SessionId -Status 'working' -Headers $Headers -Attributes (
                Add-DaemonTuningAttributes -Attributes @{
                    session    = $Entry.Name
                    machine    = $Entry.Machine
                    process_id = $Session.ProcessId
                    updated    = [DateTimeOffset]::Now.ToString('o')
                } -Tuning $Entry)
        }
        catch {
            # Left unmarked, so the next reconcile tries again.
            Write-DaemonLog -Message "status publish failed for $SessionId : $($_.Exception.Message)"
            return $at
        }
    }

    $Entry.Status = $status
    if ($Entry.PSObject.Properties['HookStatusAt']) { $Entry.HookStatusAt = $at.ToString('o') }
    else { $Entry | Add-Member -NotePropertyName HookStatusAt -NotePropertyValue ($at.ToString('o')) -Force }
    $at
}

function Get-DaemonStartupStatus {
    <#
        The status to restore a session with when the daemon starts.

        This used Copilot's lock-file check for every session, which always answers
        'idle' for Claude, so each restart - including every update - turned a busy
        Claude card idle until its transcript or a hook next said otherwise. A long
        tool call writes nothing to the transcript, so that could take minutes.

        Reconcile processes newer native activity before this restore. A failed stop
        still recorded on the entry must survive deriving a status from older work.
        Otherwise a Claude hook is authoritative, with a kind-aware fallback.
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Entry
    )

    if ($null -ne (Get-DaemonFailedStopRequestTime -Entry $Entry)) { return 'error' }

    $kind = Get-DaemonEntryKind -Entry $Entry

    if ((Get-DaemonAgent -Kind $kind).HookStatus -and $Session.PSObject.Properties['HookStatus'] -and
        [string]$Session.HookStatus -in @('working', 'waiting', 'idle')) {
        return [string]$Session.HookStatus
    }

    $sessionStatus = if ($Session.PSObject.Properties.Name -contains 'Status') { [string]$Session.Status } else { '' }
    $transcript = if ($Session.PSObject.Properties.Name -contains 'Transcript') { [string]$Session.Transcript } else { '' }
    if (Test-BridgeSessionWorking -SessionId ([string]$Session.SessionId) -Kind $kind -Transcript $transcript -Status $sessionStatus) {
        return 'working'
    }
    # A session waiting on background agents writes nothing of its own while it waits,
    # so the set the entry carries is the only thing that tells it apart from an idle
    # one. Without this every restart - including every update - said idle, which is
    # exactly the reading this status exists to correct.
    if ((Get-DaemonBackgroundAgentCount -Entry $Entry) -gt 0) { return 'agents' }
    'idle'
}

function Read-TranscriptAppend {
    <#
        Returns transcript lines appended since $Offset, plus the new offset.

        Shared read/write access is required because the CLI keeps the transcript
        open while it writes.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$Offset
    )

    $result = [pscustomobject]@{ Lines = @(); Offset = $Offset }

    $stream = $null
    try {
        $stream = [IO.File]::Open(
            $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite
        )
        # Readable again, so a later failure is news and gets said. Cleared here, at
        # the moment the open succeeds, rather than after the finally: the truncation
        # branch below returns from inside this try, and anything past the finally is
        # skipped for it - which left a recovered transcript still marked as reported,
        # so the next genuine failure would have been swallowed.
        if ($script:DaemonTranscriptFailureReported.ContainsKey($Path)) {
            $script:DaemonTranscriptFailureReported.Remove($Path)
        }
        $length = $stream.Length

        # A shorter file means the session was reset; start over from the end.
        if ($length -lt $Offset) {
            $result.Offset = $length
            return $result
        }
        # Half-written final answers used to be parsed, dropped, and never retried.
        # The shared framer withholds them using byte boundaries, not decoded lengths.
        $append = Read-BridgeTranscriptStream -Stream $stream -Offset $Offset `
            -SnapshotLength $length -MaxTailBytes $script:DaemonConfig.MaxTailBytes
        $result.Lines = @($append.Lines | Where-Object { $_.Trim().StartsWith('{') })
        $result.Offset = $append.Offset
    }
    catch {
        $failure = $_.Exception
        while ($true) {
            if ($failure.Data['BridgeTestWriteBlocked'] -or $failure.Data['BridgeTestNetworkBlocked']) { throw }
            if ($null -eq $failure.InnerException) { break }
            $failure = $failure.InnerException
        }
        if ($failure -isnot [IO.IOException] -and $failure -isnot [UnauthorizedAccessException] -and
            $failure -isnot [System.Security.SecurityException]) { throw }
        # Said once per file until it reads again, the way adapter failures are
        # (Get-DaemonSessionDiscovery's $script:DaemonAdapterFailureReported). Every
        # caller here is in a loop, so an unreadable transcript wrote one identical
        # line per pass for as long as it stayed unreadable - and on 2026-10-07 that
        # was 40,667 of the daemon log's 44,348 lines, which is most of the reason
        # nobody reads it. Repeating it adds nothing: the first line says everything
        # the thousandth does.
        if (-not $script:DaemonTranscriptFailureReported.ContainsKey($Path)) {
            $script:DaemonTranscriptFailureReported[$Path] = $true
            Write-DaemonLog -Message "transcript read failed for '$Path': $($failure.Message)"
        }
        return $result
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }

    $result
}

function Get-BridgeEventField {
    <#
        A field from a transcript event's data, or '' when the event has no such field.

        Not `$parsed.data.field`: the daemon runs under StrictMode, where reading a
        property that is not there throws - and these reads sit inside a catch that
        drops the whole event without a word. Copilot writes assistant messages in
        more than one shape, and only some carry reasoningText: in one real session
        224 of 518 messages had no such field, so nearly half of everything said was
        silently thrown away. The card then showed the last message that happened to
        include thinking, which is why it lagged behind and missed turns' final
        answers while the status said idle.
    #>
    param($Data, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Data) { return '' }
    if (@($Data.PSObject.Properties.Name) -notcontains $Name) { return '' }
    [string]$Data.$Name
}

function Get-ActivityFromEvents {
    <#
        Reduces a batch of transcript events to the current activity.

        Returns the last meaningful event plus a short rolling history, so the Home
        Assistant card shows what the session is doing now and what it just did.

        Reasoning text is always collected; VerboseMode decides only whether it also
        joins the trail. Capture and display are deliberately decoupled so the
        Detailed activity switch can show or hide what is already known without
        waiting for the session to think again.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory)][bool]$VerboseMode
    )

    $summary = $null
    $reasoning = $null
    $response = $null
    $status = $null
    $latest = $null
    $latestIsThinking = $false
    $turnStarted = $false
    $model = $null
    $history = New-Object System.Collections.Generic.List[string]
    $agentsStarted = New-Object System.Collections.Generic.List[string]
    $agentsFinished = New-Object System.Collections.Generic.List[string]

    foreach ($line in $Lines) {
        if ($line -notmatch '"type":"([^"]+)"') { continue }
        $type = $Matches[1]

        if ($type -eq 'subagent.started' -or $type -eq 'subagent.completed') {
            try {
                $parsed = $line | ConvertFrom-Json
                $callId = Get-BridgeEventField -Data $parsed.data -Name 'toolCallId'
                if ([string]::IsNullOrWhiteSpace($callId)) { continue }
                if ($type -eq 'subagent.completed') { [void]$agentsFinished.Add($callId) }
                # Only a background agent outlives the turn that started it. A sync one
                # holds the parent's tool call open, so the session is plainly working
                # and needs nothing said about it.
                elseif ((Get-BridgeEventField -Data $parsed.data -Name 'executionMode') -eq 'background') {
                    [void]$agentsStarted.Add($callId)
                }
            }
            catch { }
            continue
        }

        # A subagent's turns are not the session's; see Test-BridgeSubagentEvent. What
        # it says and the tools it runs still reach the card below, so a delegated job
        # is not a silent one - only the turn bookkeeping is the session's own. Checked
        # inside these three branches rather than per line, so the assistant messages
        # and tool calls that make up most of a transcript pay nothing for it.
        switch ($type) {
            'assistant.turn_start' {
                if (-not (Test-BridgeSubagentEvent -Line $line)) { $status = 'working' }
                continue
            }
            'user.message' {
                # Copilot writes a subagent's task prompt as one of these too, and it is
                # neither your message nor the start of a turn of the session's.
                if (Test-BridgeSubagentEvent -Line $line) { continue }
                $status = 'working'
                $summary = 'Reading your message'
                $history.Add($summary)
                # A new message starts a new turn, exactly as it does for Claude.
                # Without this the caller carried the previous turn's reasoning under
                # this turn's status - and, since the same flag hands a session back to
                # the person, a card an agent had driven once kept its purple edge for
                # the rest of the session however long you typed at the keyboard.
                $turnStarted = $true
                $reasoning = $null
                $latest = $null
                $latestIsThinking = $false
                continue
            }
            'assistant.turn_end' {
                if (-not (Test-BridgeSubagentEvent -Line $line)) { $status = 'idle' }
                continue
            }
        }

        if ($type -eq 'tool.execution_start') {
            try {
                $parsed = $line | ConvertFrom-Json
                $tool = Get-BridgeEventField -Data $parsed.data -Name 'toolName'
                if (-not [string]::IsNullOrWhiteSpace($tool)) {
                    $summary = "Running: $tool"
                    $history.Add($summary)
                }
            }
            catch { }
            continue
        }

        if ($type -eq 'assistant.message') {
            try {
                $parsed = $line | ConvertFrom-Json
                # Which model produced this message. Copilot stamps it on every
                # assistant message, so the card can say what a session is running
                # even when the bridge did not start it - and follows a /model typed
                # into the window, which the launch record never could.
                $named = Get-BridgeEventField -Data $parsed.data -Name 'model'
                if (-not [string]::IsNullOrWhiteSpace($named)) { $model = $named.Trim() }
                # Within one message the thinking comes first and whatever it produced
                # second, so both are recorded in that order and the later one is what
                # the card shows as the newest line.
                #
                # Reasoning is captured unconditionally, regardless of the verbose
                # toggle. Capture and display are deliberately decoupled: the daemon
                # always keeps the latest reasoning in state, and only publishes it to
                # the card when verbose is on. That lets a verbose toggle show or hide
                # the existing reasoning instantly, without waiting for the session to
                # think again.
                $text = Get-BridgeEventField -Data $parsed.data -Name 'reasoningText'
                if (-not [string]::IsNullOrWhiteSpace($text)) {
                    $reasoning = $text.Trim()
                    $latest = $reasoning
                    $latestIsThinking = $true
                    # Into the trail as well as the newest line, when detail is asked
                    # for. Without this a thought was only ever the single newest
                    # thing on the card: every message carries one, most carry
                    # nothing else, and each was overwritten by the next before
                    # anyone saw it - so the trail showed tools and text with all the
                    # reasoning between them missing.
                    if ($VerboseMode) {
                        $thought = Get-BridgeThoughtLine -Text $reasoning
                        if ($thought) { $history.Add($thought) }
                    }
                }
                $content = Get-BridgeEventField -Data $parsed.data -Name 'content'
                if (-not [string]::IsNullOrWhiteSpace($content)) {
                    # The short summary is the first line, for the sensor state (capped
                    # at 255 chars); the full content is kept separately so the card can
                    # render the whole response, not just its opening line.
                    $first = (($content -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
                    if ($first) {
                        $summary = $first.Trim()
                        $history.Add($summary)
                    }
                    $response = $content.Trim()
                    $latest = $response
                    $latestIsThinking = $false
                }
            }
            catch { }
            continue
        }
    }

    [pscustomobject]@{
        Summary = $summary
        Reasoning = $reasoning
        Response = $response
        Status = $status
        History = @($history)
        # The newest line of either kind, and which kind it is. Copilot interleaves
        # thinking-only messages with ones that also carry text, the same shape Claude
        # writes, so a card can show them in the order they happened.
        Latest = $latest
        LatestIsThinking = $latestIsThinking
        # The model that produced the newest message in this batch, or $null when the
        # batch carried none. Only ever moves forward: a batch of tool calls alone
        # says nothing about the model, which is not the same as saying it changed.
        Model = $model
        # True when this batch contains the start of a new turn, so the caller drops
        # the reasoning and history it has been carrying from the last one, and hands
        # the session back to the person who typed it.
        TurnStarted = $turnStarted
        # Background agents this batch started and finished, by the tool call that owns
        # each. The caller keeps the running set across batches, because a background
        # agent routinely outlives the turn - and many reads - that started it.
        AgentsStarted = @($agentsStarted)
        AgentsFinished = @($agentsFinished)
    }
}

function Set-DaemonTransientActivity {
    <#
        Reports something the user just did, without losing what the card was showing.

        Set-CopilotMqttActivity replaces the attribute set, and the header renders the
        last response, the reasoning and the activity history out of those attributes.
        Publishing a bare "Sending..." therefore blanked the response and the
        chain-of-thought until the next transcript update happened to restore them -
        visible as the card emptying and then refilling on every Send.

        Reading the current attributes and merging keeps the card intact while the
        status line underneath reports progress.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Summary,
        [hashtable]$Extra = @{},
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $attributes = @{}
    try {
        $node = Get-CopilotMqttNodeId -SessionId $SessionId
        $current = Get-HomeAssistantState -EntityId "sensor.${node}_activity" -Headers $Headers
        foreach ($property in $current.attributes.PSObject.Properties) {
            # Home Assistant adds these itself; echoing them back is noise.
            if ($property.Name -in @('friendly_name', 'icon', 'device_class', 'unit_of_measurement')) { continue }
            $attributes[$property.Name] = $property.Value
        }
    }
    catch {
        # No current attributes to preserve; publish just the new ones.
    }

    # Status detail from a previous action would otherwise linger beside a new one and
    # describe the wrong thing.
    foreach ($key in @('error', 'hint', 'waiting_on', 'sent', 'unsent', 'recorded', 'answer', 'at')) {
        [void]$attributes.Remove($key)
    }
    foreach ($key in $Extra.Keys) { $attributes[$key] = $Extra[$key] }

    Set-CopilotMqttActivity -SessionId $SessionId -Summary $Summary -Detail $attributes -Headers $Headers
}

function Get-DaemonBackgroundAgentCount {
    <#
        How many background agents a session is still waiting on.

        Not @($Entry.BackgroundAgents).Count. A property that is present but null
        wraps to a one-element array holding $null, so a session that had never
        delegated anything would have read as waiting on one agent - and parked
        itself on a status nothing could then take it out of.
    #>
    param([Parameter(Mandatory)]$Entry)

    if (-not $Entry.PSObject.Properties['BackgroundAgents']) { return 0 }
    $value = $Entry.BackgroundAgents
    if ($null -eq $value) { return 0 }
    @(@($value) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
}

function Update-DaemonBackgroundAgents {
    <#
        Folds a batch's background-agent starts and finishes into the set a session is
        still waiting on, and returns how many are left.

        Kept on the entry rather than in memory, so it survives both the next batch -
        a start and its finish are usually minutes and many reads apart - and a daemon
        restart, which is the one moment a waiting session has nothing else to say for
        itself.

        Ids, not a count. Copilot writes a subagent.completed again for every agent it
        was still tracking when the session shuts down, so counting down would go
        negative and leave a session that had finished three agents looking as though
        it were waiting on agents it never started.
    #>
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)]$Activity
    )

    $running = New-Object System.Collections.Generic.List[string]
    $add = {
        param($Values)
        foreach ($value in @($Values)) {
            $text = [string]$value
            if ($text -and -not $running.Contains($text)) { [void]$running.Add($text) }
        }
    }

    if ($Entry.PSObject.Properties['BackgroundAgents']) { & $add $Entry.BackgroundAgents }
    if ($Activity.PSObject.Properties['AgentsStarted']) { & $add $Activity.AgentsStarted }
    if ($Activity.PSObject.Properties['AgentsFinished']) {
        foreach ($value in @($Activity.AgentsFinished)) { [void]$running.Remove([string]$value) }
    }

    # Written only when there is something to say, or when the session has said
    # something before. Otherwise every Claude, Codex and never-delegating Copilot
    # session on the dashboard would grow an empty list in the state file, and the
    # first pass after an update would rewrite the lot to record nothing.
    if ($running.Count -gt 0 -or $Entry.PSObject.Properties['BackgroundAgents']) {
        Set-DaemonSessionProperty -Entry $Entry -Name 'BackgroundAgents' -Value @($running)
    }
    $running.Count
}

function Update-DaemonSessionActivity {
    <#
        Streams one session's new transcript activity to Home Assistant.

        Shared by the full reconcile and the fast lane (Invoke-DaemonFastActivity),
        which calls it the moment a transcript grows, so both publish exactly the same
        way. Everything it changes lives on the session's own state entry.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$Headers,
        [bool]$VerboseOn = $false
    )

    # Names the body below has always used.
    $id = $Id; $entry = $Entry; $session = $Session; $verbose = $VerboseOn
    $entryKind = Get-DaemonEntryKind -Entry $entry
    $agent = Get-DaemonAgent -Kind $entryKind

    # Claude's hooks set the status directly (idle at Stop, waiting at a
    # notification, working at a new prompt). Adopt it here before reading the
    # transcript, or this loop keeps believing its own stale copy and never
    # republishes 'working' when the session carries on.
    $hookStatusAt = $null
    if ($agent.HookStatus) {
        $hookStatusAt = Sync-DaemonHookStatus -Entry $entry -Session $session -SessionId $id -Headers $Headers
    }

    $append = Read-BridgeTranscriptAppend -Path $session.Transcript -Offset ([long]$entry.Offset) -Kind $entryKind
    $entry.Offset = $append.Offset
    if ($append.Lines.Count -eq 0) { return }

    $activity = Get-BridgeActivity -Lines $append.Lines -VerboseMode $verbose -Kind $entryKind

    # Work written before the hook that stopped the turn is that turn's tail, not
    # a resumption; only activity newer than the hook may flip it back to working.
    #
    # Newer means a new user entry - a prompt, or a tool result - after the hook:
    # Claude writes nothing of its own after a turn ends without one. Comparing any
    # entry's time with the hook's was a race once hooks became fast: the daemon can
    # record the Stop a few milliseconds before Claude writes that turn's final message,
    # and that message then looked like new work, flipping the card back to working.
    $staleTail = $false
    $newStatus = $activity.Status
    if ($null -ne $hookStatusAt -and [string]$entry.Status -in @('idle', 'waiting')) {
        if ($activity.PSObject.Properties['LastUserAt']) {
            $staleTail = ($null -eq $activity.LastUserAt) -or ($activity.LastUserAt -le $hookStatusAt)
            # A tool result on its own - a permission prompt answered - sets no status,
            # and what follows it may arrive in a later read with no user entry of its
            # own. So the user entry is itself the sign that work has resumed.
            if (-not $staleTail) { $newStatus = 'working' }
        }
        elseif ($activity.PSObject.Properties['LastActivityAt']) {
            $staleTail = ($null -eq $activity.LastActivityAt) -or ($activity.LastActivityAt -le $hookStatusAt)
        }
    }

    # Background agents outlive the turn that started them: the session's own turn
    # ends, so the transcript says idle while work it is waiting on is still running.
    # An idle card invites you to close a session that has not finished, so waiting on
    # one gets a status of its own.
    $runningAgents = Update-DaemonBackgroundAgents -Entry $entry -Activity $activity
    if ($runningAgents -gt 0) {
        if ($newStatus -eq 'idle' -or
            ([string]::IsNullOrWhiteSpace($newStatus) -and [string]$entry.Status -eq 'idle')) {
            $newStatus = 'agents'
        }
    }
    elseif ([string]::IsNullOrWhiteSpace($newStatus) -and [string]$entry.Status -eq 'agents') {
        # The last one finished and the session has not spoken yet - it is between the
        # agent's result and its own next turn. Left on 'agents' that is the same lie
        # the other way up, and nothing else would correct it until the session moved.
        $newStatus = 'idle'
    }

    # The model the transcript just named. Recorded before the status publish below,
    # so a batch that changes both spends one publish on the pair.
    $modelChanged = $false
    if ($activity.PSObject.Properties['Model'] -and -not [string]::IsNullOrWhiteSpace($activity.Model)) {
        $seenModel = if ($entry.PSObject.Properties['Model']) { [string]$entry.Model } else { '' }
        if ($seenModel -ne [string]$activity.Model) {
            Set-DaemonSessionProperty -Entry $entry -Name 'Model' -Value ([string]$activity.Model)
            $modelChanged = $true
        }
    }

    if (-not $staleTail -and -not [string]::IsNullOrWhiteSpace($newStatus) -and
        $newStatus -ne [string]$entry.Status) {
        $entry.Status = $newStatus
        try {
            Set-CopilotMqttStatus -SessionId $id -Status $newStatus -Headers $Headers -Attributes (
                Add-DaemonTuningAttributes -Attributes @{
                    session = $entry.Name
                    machine = $entry.Machine
                    process_id = $session.ProcessId
                    updated = [DateTimeOffset]::Now.ToString('o')
                } -Tuning $entry)
            $modelChanged = $false
        }
        catch {
            Write-DaemonLog -Message "status publish failed for $id : $($_.Exception.Message)"
        }
    }
    elseif ($modelChanged) {
        # A model can change without the status doing so - a session already working
        # when the daemon first sees it, or a /model typed mid-turn - and the status
        # attributes are republished wholesale, so the card would otherwise carry the
        # old model until the next time the session happened to go idle.
        #
        # Only from a status Set-CopilotMqttStatus accepts: an entry parked on
        # something else ('ending') is mid-retirement and its card is about to go.
        $current = [string]$entry.Status
        if ($current -in @('working', 'idle', 'waiting', 'agents', 'offline')) {
            try {
                Set-CopilotMqttStatus -SessionId $id -Status $current -Headers $Headers -Attributes (
                    Add-DaemonTuningAttributes -Attributes @{
                        session = $entry.Name
                        machine = $entry.Machine
                        process_id = $session.ProcessId
                        updated = [DateTimeOffset]::Now.ToString('o')
                    } -Tuning $entry)
            }
            catch {
                Write-DaemonLog -Message "model publish failed for $id : $($_.Exception.Message)"
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($activity.Summary) -and
        [string]::IsNullOrWhiteSpace($activity.Reasoning)) {
        return
    }

    # Persist the latest reasoning in session state so it stays on the card across
    # batches that carry no reasoning (a tool call, a plain message), and so the
    # verbose toggle can show it instantly. Capture is unconditional; only display
    # is gated on verbose (below).
    #
    # A batch that starts a new turn drops what was carried from the last one;
    # otherwise the card shows the previous turn's reasoning under the new status.
    $turnStarted = [bool]($activity.PSObject.Properties['TurnStarted'] -and $activity.TurnStarted)
    $lastReasoning = if (-not $turnStarted -and $entry.PSObject.Properties['LastReasoning']) {
        [string]$entry.LastReasoning
    }
    else { '' }
    if (-not [string]::IsNullOrWhiteSpace($activity.Reasoning)) {
        $lastReasoning = $activity.Reasoning
    }
    if ($entry.PSObject.Properties['LastReasoning']) {
        $entry.LastReasoning = $lastReasoning
    }
    else {
        $entry | Add-Member -NotePropertyName LastReasoning -NotePropertyValue $lastReasoning -Force
    }

    # Persist the full text of the last substantive response, likewise, so the
    # card can render the whole answer across later tool-call batches that carry
    # no new content.
    $lastResponse = if ($entry.PSObject.Properties['LastResponse']) {
        [string]$entry.LastResponse
    }
    else { '' }
    if (-not [string]::IsNullOrWhiteSpace($activity.Response)) {
        $lastResponse = $activity.Response
    }
    if ($entry.PSObject.Properties['LastResponse']) {
        $entry.LastResponse = $lastResponse
    }
    else {
        $entry | Add-Member -NotePropertyName LastResponse -NotePropertyValue $lastResponse -Force
    }

    $summary = $activity.Summary
    if ([string]::IsNullOrWhiteSpace($summary)) { $summary = 'Thinking' }
    # Remember the summary so a verbose-toggle refresh can republish the card
    # without needing fresh transcript activity.
    if ($entry.PSObject.Properties['LastSummary']) {
        $entry.LastSummary = $summary
    }
    else {
        $entry | Add-Member -NotePropertyName LastSummary -NotePropertyValue $summary -Force
    }

    $detail = @{
        session = $entry.Name
        machine = $entry.Machine
        verbose = $verbose
        updated = [DateTimeOffset]::Now.ToString('o')
    }
    # Who last drove this session, so the card can show at a glance that it is being
    # driven remotely by an agent rather than by the person looking at it. A turn that
    # starts without a reply coming through Home Assistant was typed in the terminal,
    # which is the person - so a new turn hands it back to them unless the reply path
    # said otherwise.
    #
    # Consumed by the turn it was armed for, not by the next publish of any kind. It
    # used to be cleared unconditionally here, which held only for a Submit press,
    # where the turn starts as the very next thing the daemon sees. A reply delivered
    # through the payload topic is typed in a character at a time, and the activity
    # updates published while that happens ate the arm before the turn arrived - so
    # the turn then read as the person's and the card lost the agent's edge.
    if ($turnStarted) {
        if (-not (Test-DaemonDriverPending -Entry $entry)) {
            Set-DaemonSessionProperty -Entry $entry -Name 'Driver' -Value 'human'
        }
        Set-DaemonSessionProperty -Entry $entry -Name 'DriverPending' -Value $false
    }
    elseif (($entry.PSObject.Properties['DriverPending'] -and $entry.DriverPending) -and
            -not (Test-DaemonDriverPending -Entry $entry)) {
        # Armed so long ago the turn is clearly not coming. Dropped here rather than
        # left for a turn to consume, so it cannot mark one the person typed.
        Set-DaemonSessionProperty -Entry $entry -Name 'DriverPending' -Value $false
    }
    $detail['driver'] = if ($entry.PSObject.Properties['Driver'] -and $entry.Driver) { [string]$entry.Driver } else { 'human' }
    # The history is a rolling trail across batches, not just this batch: the
    # daemon reads the transcript every few seconds, so a single batch usually
    # holds one or two steps and the trail would otherwise never show more.
    $carried = @()
    if (-not $turnStarted -and $entry.PSObject.Properties['LastHistory'] -and $entry.LastHistory) {
        $carried = @($entry.LastHistory | ForEach-Object { [string]$_ })
    }
    # A deeper trail while Detailed activity is on. Almost every message an agent
    # writes carries a thought, so including them fills the trail about twice as fast;
    # at the ordinary depth the actions would scroll off in half the time they do now,
    # which would make turning detail on lose you information as well as add it.
    $depth = if ($verbose -and $script:DaemonConfig.ContainsKey('ActivityHistoryDetailed')) {
        [int]$script:DaemonConfig.ActivityHistoryDetailed
    } else {
        [int]$script:DaemonConfig.ActivityHistory
    }
    $detail['history'] = @(@($carried) + @($activity.History | ForEach-Object { [string]$_ }) |
        Select-Object -Last $depth)
    # Persist the history alongside the summary and reasoning, so a daemon restart
    # can restore the whole card rather than blanking it.
    if ($entry.PSObject.Properties['LastHistory']) { $entry.LastHistory = $detail.history }
    else { $entry | Add-Member -NotePropertyName LastHistory -NotePropertyValue $detail.history -Force }
    # The newest line of either kind, for the agents that interleave thinking with
    # text (see Add-DaemonCardText).
    if ($agent.InlineReasoning) {
        $lastMessage = if (-not $turnStarted -and $entry.PSObject.Properties['LastMessage']) { [string]$entry.LastMessage } else { '' }
        $lastIsThinking = if (-not $turnStarted -and $entry.PSObject.Properties['LastMessageIsThinking']) { [bool]$entry.LastMessageIsThinking } else { $false }
        if ($activity.PSObject.Properties['Latest'] -and -not [string]::IsNullOrWhiteSpace([string]$activity.Latest)) {
            $lastMessage = [string]$activity.Latest
            $lastIsThinking = [bool]$activity.LatestIsThinking
        }
        Set-DaemonSessionProperty -Entry $entry -Name 'LastMessage' -Value $lastMessage
        Set-DaemonSessionProperty -Entry $entry -Name 'LastMessageIsThinking' -Value $lastIsThinking
    }

    Add-DaemonCardText -Entry $entry -Detail $detail -VerboseOn $verbose
    Add-DaemonAnswerStamp -Entry $entry -Detail $detail

    try {
        Set-CopilotMqttActivity -SessionId $id `
            -Summary (Get-DaemonCardSummary -SessionId $id -Summary $summary -Detail $detail) `
            -Detail $detail -Headers $Headers
    }
    catch {
        Write-DaemonLog -Message "activity publish failed for $id : $($_.Exception.Message)"
    }
}

function Sync-DaemonCodexHookStatus {
    <#
        Publishes what a Codex hook recorded in its registration - the status, and the
        status line - when the registration has changed. Returns $true when it did,
        so the card body is republished beside the new status line.

        The prompt and tool-call hooks used to publish this themselves, and the agent
        waits for a hook: about half a second per tool call went on Home Assistant.
        They now only write the registration while the daemon is running (see
        Test-BridgeDaemonAlive), and this picks it up within a tick.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    if (-not $script:CodexAdapterLoaded) { return $false }
    $registration = Join-Path (Get-CodexStateRoot -NoCreate) ((Get-CodexSafeSessionKey -SessionId $Id) + '.json')
    $stamp = try { [IO.File]::GetLastWriteTimeUtc($registration).Ticks }
    catch {
        if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
        Set-DaemonDiscoveryUncertain -Kind codex -Path $registration -SessionId $Id -Code 'StampUnreadable'
        return $false
    }
    $key = "codex:$Id"
    if ($script:DaemonRegistrationStamps.ContainsKey($key) -and $script:DaemonRegistrationStamps[$key] -eq $stamp) { return $false }
    $read = Read-DaemonRegistrationFile -Path $registration -Kind codex -Projection Hook
    if (-not $read.Known) {
        Set-DaemonDiscoveryUncertain -Kind codex -Path $registration -SessionId $Id -Code $read.Diagnostic.Code
        return $false
    }
    $fresh = $read.Record
    $script:DaemonRegistrationStamps[$key] = $read.Stamp
    $failedStopAt = Get-DaemonFailedStopRequestTime -Entry $Entry
    if ($null -ne $failedStopAt) {
        # The first read after restart is not itself new native activity.
        $registeredAt = if ($fresh.PSObject.Properties['Updated']) { ConvertTo-DaemonActivityInstant -Value $fresh.Updated } else { $null }
        if ($null -eq $registeredAt -or $registeredAt -le $failedStopAt) { return $false }
    }
    $status = [string]$fresh.Status
    $activity = [string]$fresh.Activity

    # A new prompt starts the card afresh, as the hook itself used to.
    $lastPrompt = if ($Entry.PSObject.Properties['LastPrompt']) { [string]$Entry.LastPrompt } else { '' }
    if ($activity -like 'Prompt:*' -and $activity -ne $lastPrompt) {
        foreach ($name in @('LastMessage', 'LastReasoning')) { Set-DaemonSessionProperty -Entry $Entry -Name $name -Value '' }
        Set-DaemonSessionProperty -Entry $Entry -Name 'LastMessageIsThinking' -Value $false
        Set-DaemonSessionProperty -Entry $Entry -Name 'LastHistory' -Value @()
    }
    Set-DaemonSessionProperty -Entry $Entry -Name 'LastPrompt' -Value $(if ($activity -like 'Prompt:*') { $activity } else { $lastPrompt })

    if ($status -in @('working', 'idle', 'waiting') -and $status -ne [string]$Entry.Status) {
        try {
            # Codex names its model on every hook call, so the entry follows it rather
            # than staying on whatever the launch asked for - a /model typed into its
            # window then shows on the card.
            if ($fresh.PSObject.Properties['Model'] -and [string]$fresh.Model) { Set-DaemonSessionProperty -Entry $Entry -Name 'Model' -Value ([string]$fresh.Model) }
            Set-CopilotMqttStatus -SessionId $Id -Status $status -Headers $Headers -Attributes (
                Add-DaemonTuningAttributes -Attributes @{
                    session    = $Entry.Name
                    machine    = $Entry.Machine
                    updated    = [DateTimeOffset]::Now.ToString('o')
                    process_id = if ($fresh.PSObject.Properties['ProcessId']) { [int]$fresh.ProcessId } else { 0 }
                } -Tuning $Entry)
            $Entry.Status = $status
        }
        catch {
            if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
            Write-DaemonLog -Message "codex status publish failed for $Id : $($_.Exception.Message)"
        }
    }
    $true
}

function Update-DaemonCodexActivity {
    <#
        Streams a Codex session's rollout to its card: the newest thing it said (its
        progress notes, then the answer, and reasoning summaries when there are any,
        in order, as a Claude card shows them) and its tool calls as the history.

        Only the card body is written; the status line keeps what the hooks last set
        (the registration's activity). What is shown is remembered on the entry, so a
        batch with nothing new - or a hook republishing the status - never blanks it,
        and a new turn starts it afresh.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$Headers,
        [bool]$VerboseOn,

        # Publish even with nothing new in the rollout: the hooks changed the status
        # line, which the card shows with what it already has.
        [switch]$Republish
    )

    # The rollout reader ships with the Codex adapter. Without it there is nothing to
    # read with - and calling it anyway threw, taking the whole pass down with it.
    if (-not $script:CodexAdapterLoaded) { return }

    $append = Read-CodexTranscriptAppend -Path ([string]$Session.Transcript) `
        -Offset ([long]$Entry.Offset) -MaxTailBytes $script:DaemonConfig.MaxTailBytes
    $Entry.Offset = $append.Offset
    if ($append.Lines.Count -eq 0 -and -not $Republish) { return }

    $activity = Get-CodexActivityFromTranscript -Lines $append.Lines -VerboseMode $VerboseOn
    if ($activity.TurnStarted) {
        foreach ($name in @('LastMessage', 'LastReasoning')) { Set-DaemonSessionProperty -Entry $Entry -Name $name -Value '' }
        Set-DaemonSessionProperty -Entry $Entry -Name 'LastMessageIsThinking' -Value $false
        Set-DaemonSessionProperty -Entry $Entry -Name 'LastHistory' -Value @()
    }
    if (-not $Republish -and -not $activity.TurnStarted -and -not $activity.Latest -and @($activity.History).Count -eq 0) { return }

    if ($activity.Latest) {
        Set-DaemonSessionProperty -Entry $Entry -Name 'LastMessage' -Value ([string]$activity.Latest)
        Set-DaemonSessionProperty -Entry $Entry -Name 'LastMessageIsThinking' -Value ([bool]$activity.LatestIsThinking)
    }
    if ($activity.Reasoning) { Set-DaemonSessionProperty -Entry $Entry -Name 'LastReasoning' -Value ([string]$activity.Reasoning) }
    $history = @(@($(if ($Entry.PSObject.Properties['LastHistory']) { $Entry.LastHistory } else { @() })) + @($activity.History) |
        Where-Object { $_ } | Select-Object -Last 8)
    Set-DaemonSessionProperty -Entry $Entry -Name 'LastHistory' -Value $history

    $detail = @{ session = $Entry.Name; machine = $Entry.Machine }
    # Who last drove this session. Codex publishes its own card rather than going
    # through the shared path, so without this its detail carried no driver at all and
    # every Codex card read as yours however it had been driven - the one agent whose
    # glow never worked. Same rule as the shared path: a turn that starts without a
    # reply having just come through Home Assistant was typed in the terminal, which is
    # the person, so it hands the session back to them.
    # Who last drove this session. Codex publishes its own card rather than going
    # through the shared path, so without this its detail carried no driver at all and
    # every Codex card read as yours however it had been driven - the one agent whose
    # glow never worked. Same rule as the shared path, including that the arm belongs
    # to the turn it was armed for rather than to the next publish of any kind.
    if ($activity.TurnStarted) {
        if (-not (Test-DaemonDriverPending -Entry $Entry)) {
            Set-DaemonSessionProperty -Entry $Entry -Name 'Driver' -Value 'human'
        }
        Set-DaemonSessionProperty -Entry $Entry -Name 'DriverPending' -Value $false
    }
    elseif (($Entry.PSObject.Properties['DriverPending'] -and $Entry.DriverPending) -and
            -not (Test-DaemonDriverPending -Entry $Entry)) {
        Set-DaemonSessionProperty -Entry $Entry -Name 'DriverPending' -Value $false
    }
    $detail['driver'] = if ($Entry.PSObject.Properties['Driver'] -and $Entry.Driver) { [string]$Entry.Driver } else { 'human' }
    if ($history.Count) { $detail['history'] = $history }
    $message = if ($Entry.PSObject.Properties['LastMessage']) { [string]$Entry.LastMessage } else { '' }
    $thinking = $Entry.PSObject.Properties['LastMessageIsThinking'] -and [bool]$Entry.LastMessageIsThinking
    # Reasoning is detailed activity: with it off, a card shows only what Codex said.
    if ($message -and ($VerboseOn -or -not $thinking)) {
        if ($message.Length -gt $script:DaemonConfig.ResponseMaxChars) {
            $message = $message.Substring(0, $script:DaemonConfig.ResponseMaxChars).TrimEnd() + "`n`n_(truncated - see terminal)_"
        }
        $detail['response'] = $message
        $detail['response_kind'] = if ($thinking) { 'reasoning' } else { 'text' }
    }

    # The status line as the hooks last set it, read fresh: the live snapshot is up to a
    # reconcile old, and republishing it would put an earlier status back.
    $summary = if ($Session.PSObject.Properties['Activity'] -and $Session.Activity) { [string]$Session.Activity } else { 'Working' }
    try {
        $registration = Join-Path (Get-CodexStateRoot) ((Get-CodexSafeSessionKey -SessionId $Id) + '.json')
        $fresh = [string](Get-Content -LiteralPath $registration -Raw | ConvertFrom-Json).Activity
        if ($fresh) { $summary = $fresh }
    }
    catch { }
    Add-DaemonAnswerStamp -Entry $Entry -Detail $detail
    try { Set-CopilotMqttActivity -SessionId $Id `
            -Summary (Get-DaemonCardSummary -SessionId $Id -Summary $summary -Detail $detail) `
            -Detail $detail -Headers $Headers }
    catch { Write-DaemonLog -Message "codex activity publish failed for $Id : $($_.Exception.Message)" }}

function Add-DaemonAnswerStamp {
    <#
        Carries the identity of the last reply-card publish consumed as an answer into
        an activity update.

        It has to go on every publish, not only the one that reports "Answer sent".
        Set-CopilotMqttActivity replaces the attribute set, so a stamp written once is
        gone again at the next ordinary update - and a card that happened to miss the
        single update carrying it (a suspended tab, a reconnect) would then see a
        question that had cleared with no stamp for its publish, conclude the words
        had been discarded, and put back an answer that was in fact delivered. A
        duplicate answer typed into an arrow-key prompt is its own kind of damage,
        which makes a false restore worse than the loss it guards against (#104).

        Re-derived from the session entry every time, so it is durable by construction
        rather than by luck.
    #>
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][hashtable]$Detail)

    if ($null -eq $Entry -or -not $Entry.PSObject.Properties['LastReplyPayloadAt']) { return }
    $stamp = [string]$Entry.LastReplyPayloadAt
    if (-not [string]::IsNullOrWhiteSpace($stamp)) { $Detail['answer_consumed_at'] = $stamp }
}

function Add-DaemonCardText {
    <#
        Puts the card's main text (and, where it applies, the reasoning expander) into
        an activity update, from a session's remembered state.

        Claude Code and Copilot both show their thinking and their replies in one
        stream, in the order they happen. Showing the last reply as the response and
        the last thought in an expander below it put an older line above a newer one,
        so the card read as out of order against the terminal. With Detailed activity
        on, such a card instead shows the newest line of either kind, and
        `response_kind` says whether it is reasoning. An agent that does not interleave
        the two keeps the separate expander. (Codex is inline as well, but lays its own
        card out in Update-DaemonCodexActivity and never comes through here.)

        Shared by the live update, the verbose toggle and the restart restore, so all
        three lay the card out the same way.
    #>
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][hashtable]$Detail,
        [bool]$VerboseOn
    )

    $inline = [bool](Get-DaemonAgent -Kind (Get-DaemonEntryKind -Entry $Entry)).InlineReasoning
    $shown = if ($Entry.PSObject.Properties['LastResponse']) { [string]$Entry.LastResponse } else { '' }
    $shownKind = 'text'

    if ($inline) {
        $lastMessage = if ($Entry.PSObject.Properties['LastMessage']) { [string]$Entry.LastMessage } else { '' }
        if ($VerboseOn -and -not [string]::IsNullOrWhiteSpace($lastMessage)) {
            $shown = $lastMessage
            if ($Entry.PSObject.Properties['LastMessageIsThinking'] -and [bool]$Entry.LastMessageIsThinking) { $shownKind = 'reasoning' }
        }
    }

    # The card shows the text in full; nothing is split off into a "show more".
    if (-not [string]::IsNullOrWhiteSpace($shown)) {
        if ($shown.Length -gt $script:DaemonConfig.ResponseMaxChars) {
            $shown = $shown.Substring(0, $script:DaemonConfig.ResponseMaxChars).TrimEnd() +
                "`n`n_(truncated - see terminal)_"
        }
        $Detail['response'] = $shown
        $Detail['response_kind'] = $shownKind
    }

    # Claude's and Copilot's reasoning is already inline, in order; repeating it below
    # would put it out of order again.
    $reasoning = if ($Entry.PSObject.Properties['LastReasoning']) { [string]$Entry.LastReasoning } else { '' }
    if ($VerboseOn -and -not $inline -and -not [string]::IsNullOrWhiteSpace($reasoning)) {
        if ($reasoning.Length -gt $script:DaemonConfig.ReasoningMaxChars) {
            $reasoning = $reasoning.Substring(0, $script:DaemonConfig.ReasoningMaxChars).TrimEnd() + '…'
        }
        $Detail['reasoning'] = $reasoning
    }
}

function Invoke-DaemonFastActivity {
    <#
        The fast lane: publishes new transcript activity within one wait tick.

        The full reconcile runs every 15 seconds and makes dozens of Home Assistant
        calls, so streaming only from there left reasoning up to 15 seconds behind the
        terminal. This runs between reconciles, from inside the Home Assistant wait
        (every 100 ms), and costs a file-size check per live session when nothing has
        changed. It works from the live set the last reconcile found; sessions that
        appear or exit are still picked up there.

        For Claude it also watches the hook registration, so a status a hook just set
        (a new prompt's 'working', say) is adopted within a tick rather than a reconcile.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State
    )

    # A session launched from the dashboard is followed up here too, so its
    # registration - or its trust question - is noticed within a second.
    $discovery = Get-Variable -Name DaemonDiscoverySnapshot -Scope Script -ErrorAction SilentlyContinue
    if (-not $discovery -or $null -eq $discovery.Value -or $discovery.Value.Complete) {
        try { Update-DaemonPendingLaunch -Headers $Headers }
        catch {
            if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
        }
    }

    # An End session confirmation nobody made in time, so the card stops asking for a
    # second press within a tick rather than at the next reconcile. Gated on the
    # count: this runs every 100 ms, where even an empty loop over every session costs
    # more than the work it would find.
    if ($script:DaemonStopArmed.Count -gt 0) {
        try { Clear-DaemonExpiredStopArms -Headers $Headers -State $State }
        catch {
            if ($_.Exception.Data['BridgeTestWriteBlocked']) { throw }
            if ($_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
            Write-DaemonLog -Message "end confirmation sweep failed: $($_.Exception.Message)"
        }
    }

    # Hook events the native hook handed over, before streaming, so a registration it
    # carries is in place when the session's activity is read (daemon-hookspool.ps1).
    # Looked at only when due: listing the folder every tick cost more than the tick.
    # Test-DaemonHookSpoolDue, inlined - the call alone was a tenth of an idle tick.
    if (($null -ne $script:DaemonHookSpoolEvents -and $script:DaemonHookSpoolEvents.Count -gt 0) -or
        $script:DaemonHookSpoolAttempts.Count -gt 0 -or
        ([DateTime]::UtcNow - $script:DaemonHookSpoolSweptAt).TotalSeconds -ge $script:DaemonHookSpoolSweepSeconds) {
        try { $null = Invoke-DaemonHookSpool }
        catch {
            if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
            Write-DaemonLog -Message "hook spool failed: $($_.Exception.Message)"
        }
    }

    $live = $script:DaemonLive
    if ($null -eq $live -or $live.Count -eq 0) { return }

    foreach ($id in @($State.Keys)) {
        $entry = $State[$id]
        $session = $live[$id]
        if ($null -eq $entry -or $null -eq $session) { continue }

        $agent = Get-DaemonAgent -Kind (Get-DaemonEntryKind -Entry $entry)
        # An agent that streams its own card (Codex) does so here, in place of the
        # shared path below.
        if ($agent.FastActivity) {
            & $agent.FastActivity $id $entry $session $Headers | Out-Null
            continue
        }

        $changed = $false
        if ($agent.PollRegistration) { $changed = [bool](& $agent.PollRegistration $id $session) }
        if (-not $live.ContainsKey($id)) { continue }

        $transcript = [string]$session.Transcript
        if (-not $changed) {
            if ([string]::IsNullOrWhiteSpace($transcript)) { continue }
            # FileInfo.Length does not throw for a file that is not there. PowerShell
            # turns the getter's FileNotFoundException into $null - even under
            # Set-StrictMode -Version Latest with $ErrorActionPreference 'Stop' - so the
            # catch below never fires for the commonest case it looks like it covers,
            # and $null never equals the offset either. Both guards missed, so every
            # 100 ms tick went on to read a transcript that did not exist: a session
            # between starting and writing its first event logged a read failure about
            # eight times a second, for as long as that lasted. Test the value, not just
            # the throw.
            $length = $null
            try { $length = [IO.FileInfo]::new($transcript).Length } catch { continue }
            if ($null -eq $length) { continue }
            if ([long]$length -eq [long]$entry.Offset) { continue }
        }

        Update-DaemonSessionActivity -Id $id -Entry $entry -Session $session -Headers $Headers -VerboseOn ([bool]$script:DaemonVerbose)
    }
}
