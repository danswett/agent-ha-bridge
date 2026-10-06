<#
.SYNOPSIS
    Reduces Claude Code transcript lines to the bridge's activity shape.

.DESCRIPTION
    A Claude Code transcript is JSON Lines under ~/.claude/projects/<slug>/<id>.jsonl.
    Each line carries parentUuid, isSidechain, userType, cwd, sessionId, gitBranch,
    type, message, uuid and timestamp, with toolUseResult on tool-result entries and
    isMeta on housekeeping ones. Those field names were read out of the shipping
    claude.exe 2.1.215.

    An assistant message's content is either a plain string or an array of blocks:
    text, thinking, tool_use and tool_result. `thinking` is what makes chain-of-thought
    streaming possible for Claude, the same as reasoningText does for Copilot.

    Output deliberately matches Get-ActivityFromEvents in the daemon:

        @{ Summary; Reasoning; Response; Status; History }

    Note on idle: Claude has no turn-end transcript entry, so idle is not inferred
    here. The Stop hook is the authoritative end-of-turn signal and sets it directly;
    anything appearing in the transcript means the session is working.
#>

Set-StrictMode -Version Latest

function Get-ClaudeContentBlocks {
    <#
        Normalises message.content, which is a bare string for simple messages and an
        array of typed blocks otherwise.
    #>
    param([AllowNull()]$Message)

    if ($null -eq $Message) { return @() }
    if ($Message.PSObject.Properties.Name -notcontains 'content') { return @() }
    $content = $Message.content
    if ($null -eq $content) { return @() }
    if ($content -is [string]) {
        return @([pscustomobject]@{ type = 'text'; text = $content })
    }
    @($content)
}

function Get-ClaudeActivityFromTranscript {
    <#
        Reduces a batch of transcript lines to the current activity plus a short
        rolling history.

        Reasoning is captured regardless of the verbose toggle, matching the daemon:
        capture and display are decoupled so flipping the toggle can reveal the latest
        thinking immediately instead of waiting for the model to think again.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [bool]$VerboseMode = $false
    )

    $summary = $null
    $reasoning = $null
    $response = $null
    $status = $null
    $turnStarted = $false
    $lastActivityAt = $null
    $lastUserAt = $null
    $latest = $null
    $latestIsThinking = $false
    $model = $null
    $history = New-Object System.Collections.Generic.List[string]

    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $entry = try { $line | ConvertFrom-Json } catch { $null }
        if ($null -eq $entry) { continue }

        # Sidechain entries belong to sub-agents, and meta entries are housekeeping;
        # neither is the session's own visible activity.
        if ($entry.PSObject.Properties.Name -contains 'isSidechain' -and $entry.isSidechain) { continue }
        if ($entry.PSObject.Properties.Name -contains 'isMeta' -and $entry.isMeta) { continue }

        $type = [string]$entry.type

        # The newest activity's time, so a caller can tell work that happened after a
        # hook set the status from the tail of the turn that hook just ended.
        if ($type -in @('user', 'assistant') -and $entry.PSObject.Properties['timestamp']) {
            # ConvertFrom-Json turns an ISO timestamp into a DateTime already; anything
            # else is parsed as a string, culture-independently.
            $raw = $entry.timestamp
            $at = [DateTimeOffset]::MinValue
            $parsed = if ($raw -is [datetime]) { $at = [DateTimeOffset]$raw.ToUniversalTime(); $true }
                else {
                    [DateTimeOffset]::TryParse([string]$raw, [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$at)
                }
            if ($parsed -and ($null -eq $lastActivityAt -or $at -gt $lastActivityAt)) { $lastActivityAt = $at }
            if ($parsed -and $type -eq 'user' -and ($null -eq $lastUserAt -or $at -gt $lastUserAt)) { $lastUserAt = $at }
        }

        if ($type -eq 'user') {
            $blocks = Get-ClaudeContentBlocks -Message $entry.message
            $isToolResult = @($blocks | Where-Object { $_.type -eq 'tool_result' }).Count -gt 0
            if (-not $isToolResult) {
                # A new message starts a new turn. Whatever was reasoned or done before
                # it belongs to the previous one, and carrying it over is what left the
                # card showing last turn's reasoning under this turn's status.
                $status = 'working'
                $turnStarted = $true
                $reasoning = $null
                $latest = $null
                $latestIsThinking = $false
                $history.Clear()
                $summary = 'Reading your message'
                $history.Add($summary)
            }
            continue
        }

        if ($type -ne 'assistant') { continue }

        $status = 'working'
        # Which model wrote this message. Claude records it on every assistant entry,
        # so the card can say what a session is running even when the bridge did not
        # start it, and follows a /model typed into the window.
        if ($entry.message.PSObject.Properties['model']) {
            $named = [string]$entry.message.model
            if (-not [string]::IsNullOrWhiteSpace($named)) { $model = $named.Trim() }
        }
        foreach ($block in (Get-ClaudeContentBlocks -Message $entry.message)) {
            switch ([string]$block.type) {
                'tool_use' {
                    $tool = [string]$block.name
                    if (-not [string]::IsNullOrWhiteSpace($tool)) {
                        $summary = "Running: $tool"
                        $history.Add($summary)
                    }
                }
                'thinking' {
                    $text = [string]$block.thinking
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        $reasoning = $text.Trim()
                        $latest = $reasoning
                        $latestIsThinking = $true
                        # Into the trail too when detail is asked for, the same as
                        # Copilot's reasoningText: otherwise a thought is only ever
                        # the newest line and the next one erases it.
                        if ($VerboseMode) {
                            $thought = Get-BridgeThoughtLine -Text $reasoning
                            if ($thought) { $history.Add($thought) }
                        }
                    }
                }
                'text' {
                    $text = [string]$block.text
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        $first = (($text -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
                        if ($first) {
                            $summary = $first.Trim()
                            $history.Add($summary)
                        }
                        $response = $text.Trim()
                        $latest = $response
                        $latestIsThinking = $false
                    }
                }
            }
        }
    }

    [pscustomobject]@{
        Summary     = $summary
        Reasoning   = $reasoning
        Response    = $response
        Status      = $status
        History     = @($history)
        # True when this batch contains the start of a new turn, so the caller drops
        # the reasoning and history it has been carrying from the last one.
        TurnStarted = $turnStarted
        # Time of the newest user or assistant entry in the batch, or $null.
        LastActivityAt = $lastActivityAt
        # Time of the newest user entry - a prompt or a tool result - or $null. Only one
        # of these can start work again once a hook has ended the turn: Claude writes
        # nothing of its own after a turn without one.
        LastUserAt = $lastUserAt
        # The newest message of either kind, and whether it was a thinking summary.
        # Claude Code shows thinking summaries and replies in one stream, so this is
        # what matches the terminal's order; Response alone runs behind it.
        Latest = $latest
        LatestIsThinking = $latestIsThinking
        # The model that wrote the newest message in this batch, or $null when the
        # batch carried none - a batch of user entries alone says nothing about the
        # model, which is not the same as saying it changed.
        Model = $model
    }
}

function Get-ClaudeAskUserState {
    <#
        Whether the session's most recent AskUserQuestion is still waiting for an
        answer, from its transcript.

        The same shape as Get-CopilotAskUserState, which reads Copilot's event format
        and so never found a Claude question at all: the daemon then treated every
        Claude question as not yet started, and neither cleared the card after a
        terminal answer nor delivered one chosen on the dashboard. Here the pair is the
        assistant's tool_use and the user entry carrying the tool_result with the same
        id. ResultContent is the answer text Claude recorded
        ('..."question"="Chosen label"...'), which carries each chosen label verbatim.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$TranscriptPath,

        # The question the card was armed for, from the hook's tool_use_id. The hook
        # fires before Claude writes the question to the transcript, so "the latest
        # question" there is briefly the PREVIOUS one - already answered - and the new
        # card was cleared within seconds of being armed. Naming the question avoids
        # that entirely: it is pending until a result for this id appears.
        [string]$ToolCallId = '',

        # Without an id, only a question asked since this moment counts; until one
        # appears the question is reported as not started, which the daemon waits on.
        [AllowNull()]$Since = $null
    )

    $result = [pscustomobject]@{ Started = $false; Pending = $false; ToolCallId = ''; StartedAt = $null; ResultContent = '' }
    $hasId = -not [string]::IsNullOrWhiteSpace($ToolCallId)
    if ($hasId) {
        $result.Started = $true
        $result.Pending = $true
        $result.ToolCallId = $ToolCallId
    }
    if ([string]::IsNullOrWhiteSpace($TranscriptPath) -or -not (Test-Path -LiteralPath $TranscriptPath)) { return $result }

    $length = (Get-Item -LiteralPath $TranscriptPath).Length
    $tail = Read-ClaudeTranscriptAppend -Path $TranscriptPath -Offset ([Math]::Max(0L, $length - 2MB)) -MaxTailBytes 2MB

    $latestId = ''
    $latestAt = $null
    $idComparer = if ($hasId) { [StringComparer]::Ordinal } else { [StringComparer]::OrdinalIgnoreCase }
    $answers = [Collections.Generic.Dictionary[string, string]]::new($idComparer)
    # A little slack for the clock: the card is armed a moment before Claude stamps
    # the question it belongs to.
    $sinceAt = $null
    if (-not $hasId -and $null -ne $Since -and -not [string]::IsNullOrWhiteSpace([string]$Since)) {
        try { $sinceAt = ([DateTimeOffset]::Parse([string]$Since)).AddSeconds(-10) } catch { $sinceAt = $null }
    }
    foreach ($line in @($tail.Lines)) {
        if ($line -notmatch 'AskUserQuestion|"tool_result"') { continue }
        $entry = try { $line | ConvertFrom-Json } catch { $null }
        # Queue and housekeeping entries can mention the tool by name but carry no
        # message; reading one under StrictMode would throw out of the daemon's pass.
        if ($null -eq $entry -or -not $entry.PSObject.Properties['message']) { continue }
        foreach ($block in (Get-ClaudeContentBlocks -Message $entry.message)) {
            if (-not $block.PSObject.Properties['type']) { continue }
            if ([string]$block.type -eq 'tool_use' -and $block.PSObject.Properties['name'] -and
                [string]$block.name -eq 'AskUserQuestion' -and $block.PSObject.Properties['id']) {
                if ($hasId -and -not [StringComparer]::Ordinal.Equals([string]$block.id, $ToolCallId)) { continue }
                $at = if ($entry.PSObject.Properties['timestamp']) { $entry.timestamp } else { $null }
                if ($null -ne $sinceAt) {
                    # Too old to be the question the card is for.
                    $when = $null
                    if ($at -is [datetime]) { $when = [DateTimeOffset]$at.ToUniversalTime() }
                    elseif ($null -ne $at) { try { $when = [DateTimeOffset]::Parse([string]$at) } catch { } }
                    if ($null -eq $when -or $when -lt $sinceAt) { continue }
                }
                $latestId = [string]$block.id
                $latestAt = $at
            }
            elseif ([string]$block.type -eq 'tool_result' -and $block.PSObject.Properties['tool_use_id']) {
                # Not every result block is text: ToolSearch answers with tool_reference
                # blocks and a screenshot is an image. Reading .text off one of those
                # threw under StrictMode on every pass while any question was pending,
                # which stalled the whole reconcile loop, not just this card.
                $content = if (-not $block.PSObject.Properties['content']) { '' }
                           elseif ($block.content -is [string]) { [string]$block.content }
                           else {
                               (@($block.content) | Where-Object { $null -ne $_ -and $_.PSObject.Properties['text'] } |
                                   ForEach-Object { [string]$_.text }) -join ' '
                           }
                $answers[[string]$block.tool_use_id] = $content
            }
        }
    }

    # A named question exists from the moment its hook fired, whether or not it has
    # reached the transcript yet.
    if ($hasId) { $latestId = $ToolCallId }

    if ([string]::IsNullOrWhiteSpace($latestId)) { return $result }
    $result.Started = $true
    $result.ToolCallId = $latestId
    $result.StartedAt = $latestAt
    $result.Pending = -not $answers.ContainsKey($latestId)
    if (-not $result.Pending) { $result.ResultContent = [string]$answers[$latestId] }
    $result
}

function Read-ClaudeTranscriptAppend {
    <#
        Reads the bytes appended since the last offset.

        Mirrors the daemon's reader: a capped tail so a session that produced a huge
        burst cannot stall the loop, and a reset when the file shrinks, which means it
        was rotated or rewritten.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$Offset = 0,
        [int]$MaxTailBytes = 512000
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Lines = @(); Offset = 0 }
    }

    $length = (Get-Item -LiteralPath $Path).Length
    if ($length -lt $Offset) { $Offset = 0 }
    if ($length -eq $Offset) {
        return [pscustomobject]@{ Lines = @(); Offset = $Offset }
    }

    $start = $Offset
    if (($length - $start) -gt $MaxTailBytes) { $start = $length - $MaxTailBytes }

    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        [void]$stream.Seek($start, 'Begin')
        $buffer = New-Object byte[] ($length - $start)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
    }
    finally {
        $stream.Dispose()
    }

    # A trailing partial line is left for the next pass by rewinding the offset, so a
    # line is never parsed half-written.
    $lines = $text -split "`n"
    $trailing = 0
    if (-not $text.EndsWith("`n") -and $lines.Count -gt 0) {
        $trailing = [Text.Encoding]::UTF8.GetByteCount($lines[-1])
        # When the batch is nothing but a partial line there is no complete line to
        # return; slicing would otherwise hand back the fragment itself.
        $lines = if ($lines.Count -ge 2) { $lines[0..($lines.Count - 2)] } else { @() }
    }

    [pscustomobject]@{
        Lines  = @($lines | Where-Object { $_.Trim() })
        Offset = $length - $trailing
    }
}
