<#
    Bridge daemon: what a session is doing, onto its card.

    Reads transcripts and the hooks' registrations, turns them into the card's
    status line, response, reasoning and history, and streams them - including the
    fast lane that runs between reconciles.

    Part of agent-bridge-daemon.ps1, which dot-sources it into its own scope after
    declaring the shared $script: state; see docs/daemon-split.md.
    Shared state it changes: DaemonRegistrationStamps.
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
    $at = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Session.HookStatusAt, [ref]$at)) { return $null }

    $seen = if ($Entry.PSObject.Properties['HookStatusAt']) { [string]$Entry.HookStatusAt } else { '' }
    if ($seen -eq [string]$Session.HookStatusAt) { return $at }

    $status = [string]$Session.HookStatus
    if ($status -eq 'working' -and $status -ne [string]$Entry.Status) {
        try {
            Set-CopilotMqttStatus -SessionId $SessionId -Status 'working' -Headers $Headers -Attributes @{
                session    = $Entry.Name
                machine    = $Entry.Machine
                process_id = $Session.ProcessId
                updated    = [DateTimeOffset]::Now.ToString('o')
            }
        }
        catch {
            # Left unmarked, so the next reconcile tries again.
            Write-DaemonLog -Message "status publish failed for $SessionId : $($_.Exception.Message)"
            return $at
        }
    }

    $Entry.Status = $status
    if ($Entry.PSObject.Properties['HookStatusAt']) { $Entry.HookStatusAt = [string]$Session.HookStatusAt }
    else { $Entry | Add-Member -NotePropertyName HookStatusAt -NotePropertyValue ([string]$Session.HookStatusAt) -Force }
    $at
}

function Get-DaemonStartupStatus {
    <#
        The status to restore a session with when the daemon starts.

        This used Copilot's lock-file check for every session, which always answers
        'idle' for Claude, so each restart - including every update - turned a busy
        Claude card idle until its transcript or a hook next said otherwise. A long
        tool call writes nothing to the transcript, so that could take minutes.

        A Claude hook's recorded status is authoritative when there is one; anything
        else goes through the kind-aware check.
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Entry
    )

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
        $length = $stream.Length

        # A shorter file means the session was reset; start over from the end.
        if ($length -lt $Offset) {
            $result.Offset = $length
            return $result
        }
        if ($length -eq $Offset) { return $result }

        $start = $Offset
        if (($length - $start) -gt $script:DaemonConfig.MaxTailBytes) {
            $start = $length - $script:DaemonConfig.MaxTailBytes
        }

        [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false))
        $text = $reader.ReadToEnd()

        $result.Offset = $length
        $result.Lines = @(
            ($text -split "`n") | Where-Object { $_.Trim().StartsWith('{') }
        )
    }
    catch {
        return $result
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }

    $result
}

function Get-ActivityFromEvents {
    <#
        Reduces a batch of transcript events to the current activity.

        Returns the last meaningful event plus a short rolling history, so the Home
        Assistant card shows what the session is doing now and what it just did.
        Reasoning text is only collected when verbose streaming is on.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory)][bool]$VerboseMode
    )

    $summary = $null
    $reasoning = $null
    $response = $null
    $status = $null
    $history = New-Object System.Collections.Generic.List[string]

    foreach ($line in $Lines) {
        if ($line -notmatch '"type":"([^"]+)"') { continue }
        $type = $Matches[1]

        switch ($type) {
            'assistant.turn_start' { $status = 'working'; continue }
            'user.message' { $status = 'working'; $summary = 'Reading your message'; $history.Add($summary); continue }
            'assistant.turn_end' { $status = 'idle'; continue }
        }

        if ($type -eq 'tool.execution_start') {
            try {
                $parsed = $line | ConvertFrom-Json
                $tool = [string]$parsed.data.toolName
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
                $content = [string]$parsed.data.content
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
                }
                # Reasoning is captured unconditionally, regardless of the verbose
                # toggle. Capture and display are deliberately decoupled: the daemon
                # always keeps the latest reasoning in state, and only publishes it to
                # the card when verbose is on. That lets a verbose toggle show or hide
                # the existing reasoning instantly, without waiting for the session to
                # think again.
                $text = [string]$parsed.data.reasoningText
                if (-not [string]::IsNullOrWhiteSpace($text)) { $reasoning = $text.Trim() }
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

    if (-not $staleTail -and -not [string]::IsNullOrWhiteSpace($newStatus) -and
        $newStatus -ne [string]$entry.Status) {
        $entry.Status = $newStatus
        try {
            Set-CopilotMqttStatus -SessionId $id -Status $newStatus -Headers $Headers -Attributes @{
                session = $entry.Name
                machine = $entry.Machine
                process_id = $session.ProcessId
                updated = [DateTimeOffset]::Now.ToString('o')
            }
        }
        catch {
            Write-DaemonLog -Message "status publish failed for $id : $($_.Exception.Message)"
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
    # The history is a rolling trail across batches, not just this batch: the
    # daemon reads the transcript every few seconds, so a single batch usually
    # holds one or two steps and the trail would otherwise never show more.
    $carried = @()
    if (-not $turnStarted -and $entry.PSObject.Properties['LastHistory'] -and $entry.LastHistory) {
        $carried = @($entry.LastHistory | ForEach-Object { [string]$_ })
    }
    $detail['history'] = @(@($carried) + @($activity.History | ForEach-Object { [string]$_ }) |
        Select-Object -Last $script:DaemonConfig.ActivityHistory)
    # Persist the history alongside the summary and reasoning, so a daemon restart
    # can restore the whole card rather than blanking it.
    if ($entry.PSObject.Properties['LastHistory']) { $entry.LastHistory = $detail.history }
    else { $entry | Add-Member -NotePropertyName LastHistory -NotePropertyValue $detail.history -Force }
    # The newest line of either kind, for Claude (see Add-DaemonCardText).
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

    try {
        Set-CopilotMqttActivity -SessionId $id -Summary $summary -Detail $detail -Headers $Headers
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
    $registration = Join-Path (Get-CodexStateRoot) ((Get-CodexSafeSessionKey -SessionId $Id) + '.json')
    $stamp = [IO.File]::GetLastWriteTimeUtc($registration).Ticks
    $key = "codex:$Id"
    if ($script:DaemonRegistrationStamps.ContainsKey($key) -and $script:DaemonRegistrationStamps[$key] -eq $stamp) { return $false }
    $script:DaemonRegistrationStamps[$key] = $stamp

    $fresh = try { Get-Content -LiteralPath $registration -Raw | ConvertFrom-Json } catch { $null }
    if ($null -eq $fresh) { return $false }
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
            Set-CopilotMqttStatus -SessionId $Id -Status $status -Headers $Headers -Attributes @{
                session    = $Entry.Name
                machine    = $Entry.Machine
                updated    = [DateTimeOffset]::Now.ToString('o')
                model      = [string]$fresh.Model
                process_id = [int]($fresh.ProcessId ?? 0)
            }
            $Entry.Status = $status
        }
        catch { Write-DaemonLog -Message "codex status publish failed for $Id : $($_.Exception.Message)" }
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

    $activity = Get-CodexActivityFromTranscript -Lines $append.Lines
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
    try { Set-CopilotMqttActivity -SessionId $Id -Summary $summary -Detail $detail -Headers $Headers }
    catch { Write-DaemonLog -Message "codex activity publish failed for $Id : $($_.Exception.Message)" }
}

function Add-DaemonCardText {
    <#
        Puts the card's main text (and, where it applies, the reasoning expander) into
        an activity update, from a session's remembered state.

        Claude Code shows its thinking summaries and its replies in one stream, in the
        order they happen. Showing the last reply as the response and the last thought
        in an expander below it put an older line above a newer one, so the card read as
        out of order against the terminal. With Detailed activity on, a Claude card
        instead shows the newest line of either kind, and `response_kind` says whether
        it is reasoning. Other agents keep the separate expander.

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

    # Claude's reasoning is already inline, in order; repeating it below would put it
    # out of order again.
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
    try { Update-DaemonPendingLaunch -Headers $Headers } catch { }

    # Hook events the native hook handed over, before streaming, so a registration it
    # carries is in place when the session's activity is read (daemon-hookspool.ps1).
    # Looked at only when due: listing the folder every tick cost more than the tick.
    # Test-DaemonHookSpoolDue, inlined - the call alone was a tenth of an idle tick.
    if (($null -ne $script:DaemonHookSpoolEvents -and $script:DaemonHookSpoolEvents.Count -gt 0) -or
        $script:DaemonHookSpoolAttempts.Count -gt 0 -or
        ([DateTime]::UtcNow - $script:DaemonHookSpoolSweptAt).TotalSeconds -ge $script:DaemonHookSpoolSweepSeconds) {
        try { $null = Invoke-DaemonHookSpool } catch { Write-DaemonLog -Message "hook spool failed: $($_.Exception.Message)" }
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

        $transcript = [string]$session.Transcript
        if (-not $changed) {
            if ([string]::IsNullOrWhiteSpace($transcript)) { continue }
            $length = 0L
            try { $length = [IO.FileInfo]::new($transcript).Length } catch { continue }
            if ($length -eq [long]$entry.Offset) { continue }
        }

        Update-DaemonSessionActivity -Id $id -Entry $entry -Session $session -Headers $Headers -VerboseOn ([bool]$script:DaemonVerbose)
    }
}
