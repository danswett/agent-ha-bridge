<#
.SYNOPSIS
    Reduces a Codex rollout transcript to the reasoning the hooks cannot provide.

.DESCRIPTION
    The Codex hooks carry everything the card normally needs - the prompt, each tool
    call, the final reply - so this exists for one thing only: chain-of-thought.

    A rollout lives at the `transcript_path` every hook reports:

        ~/.codex/sessions/<yyyy>/<MM>/<dd>/rollout-<timestamp>-<session_id>.jsonl

    Each line is `{timestamp, ordinal, type, payload}`. Reasoning is written twice per
    turn, in both of the rollout's streams, and this reads either:

        event_msg     -> payload.type = "item_completed"
                      -> item.type = "Reasoning", item.summary_text = [ "..." ]

        response_item -> payload.type = "reasoning"
                      -> payload.summary = [ { type = "summary_text", text = "..." } ]

    Note the casing difference between the two - `Reasoning` in the event stream,
    `reasoning` in the durable record.

    What this yields is the model's *summary* of its reasoning, not raw
    chain-of-thought: `raw_content` is empty and `encrypted_content` is opaque by
    design. That is the same class of content the other adapters stream.

    Reasoning is off unless the user opts in. `reasoning_effort` was null in 25 of 26
    rollouts captured on 0.155.0-alpha.6, and a turn that does not reason produces no
    items and zero `reasoning_output_tokens`. Its absence is therefore normal and must
    never look like a fault - the card is simply exactly as it was. Users who want the
    stream need `model_reasoning_effort` set.
#>

Set-StrictMode -Version Latest

function Get-CodexReasoningFromTranscript {
    <#
        Returns the most recent reasoning text in a batch of rollout lines, or $null.

        Only reasoning is extracted. Status, activity and the final response all come
        from hooks, which report them sooner and more reliably than a transcript tail.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines
    )

    $reasoning = $null
    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # Cheap pre-filter: most lines are messages or token counts. -notmatch is
        # case-insensitive, so this keeps both spellings.
        if ($line -notmatch 'reasoning') { continue }

        $entry = try { $line | ConvertFrom-Json } catch { $null }
        if ($null -eq $entry) { continue }

        $payload = $entry.payload
        if ($null -eq $payload) { continue }
        $payloadProps = $payload.PSObject.Properties.Name

        $text = ''
        $entryType = [string]$entry.type

        if ($entryType -eq 'event_msg' -and $payloadProps -contains 'item') {
            $item = $payload.item
            if ($null -eq $item) { continue }
            $itemProps = $item.PSObject.Properties.Name
            if ($itemProps -notcontains 'type' -or [string]$item.type -ne 'Reasoning') { continue }

            if ($itemProps -contains 'summary_text') {
                $text = (@($item.summary_text) | ForEach-Object { [string]$_ }) -join "`n"
            }
            # Tolerated fallbacks: the protocol also describes a flat ReasoningItem,
            # and raw_content is populated for models that expose it.
            elseif ($itemProps -contains 'text') {
                $text = [string]$item.text
            }
            elseif ($itemProps -contains 'raw_content') {
                $text = (@($item.raw_content) | ForEach-Object {
                    if ($_ -is [string]) { $_ }
                    elseif ($_.PSObject.Properties.Name -contains 'text') { [string]$_.text }
                }) -join "`n"
            }
        }
        elseif ($entryType -eq 'response_item' -and $payloadProps -contains 'type' -and
                [string]$payload.type -eq 'reasoning' -and $payloadProps -contains 'summary') {
            $text = (@($payload.summary) | ForEach-Object {
                if ($_ -is [string]) { $_ }
                elseif ($_.PSObject.Properties.Name -contains 'text') { [string]$_.text }
            }) -join "`n"
        }
        else { continue }

        if (-not [string]::IsNullOrWhiteSpace($text)) { $reasoning = $text.Trim() }
    }

    $reasoning
}

function Get-CodexActivityFromTranscript {
    <#
        What a batch of rollout lines adds to the card, as
        { TurnStarted, Latest, LatestIsThinking, Reasoning, History }.

        Latest is the newest thing Codex said, in order: its progress notes while it
        works (assistant messages with phase "commentary"), then the final answer, and
        reasoning summaries when the model writes them - so the card reads like the
        terminal, as a Claude card does. History is the tool calls. TurnStarted marks
        a new turn in the batch, and everything returned is from after it.

        The hooks alone gave the card nothing but a status line until the turn ended,
        and the reply only then.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

    $result = [pscustomobject]@{ TurnStarted = $false; Latest = ''; LatestIsThinking = $false; Reasoning = ''; History = @() }
    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # Cheap pre-filter: token counts and world state are most of a rollout.
        if ($line -notmatch '"type":"(task_started|message|reasoning|custom_tool_call|function_call|local_shell_call|web_search_call)"') { continue }
        $entry = try { $line | ConvertFrom-Json } catch { $null }
        if ($null -eq $entry -or -not $entry.PSObject.Properties['payload'] -or $null -eq $entry.payload) { continue }
        $payload = $entry.payload
        $kind = if ($payload.PSObject.Properties['type']) { [string]$payload.type } else { '' }

        if ([string]$entry.type -eq 'event_msg') {
            if ($kind -eq 'task_started') {
                $result.TurnStarted = $true
                $result.Latest = ''; $result.LatestIsThinking = $false; $result.Reasoning = ''; $result.History = @()
            }
            continue
        }
        if ([string]$entry.type -ne 'response_item') { continue }

        switch ($kind) {
            'message' {
                if (-not $payload.PSObject.Properties['role'] -or [string]$payload.role -ne 'assistant') { break }
                $text = (@($payload.content) | Where-Object {
                    $_ -and $_.PSObject.Properties['text'] -and (-not $_.PSObject.Properties['type'] -or [string]$_.type -eq 'output_text')
                } | ForEach-Object { [string]$_.text }) -join "`n"
                if (-not [string]::IsNullOrWhiteSpace($text)) { $result.Latest = $text.Trim(); $result.LatestIsThinking = $false }
            }
            'reasoning' {
                # Encrypted unless model_reasoning_summary asks for a summary.
                if (-not $payload.PSObject.Properties['summary']) { break }
                $text = (@($payload.summary) | ForEach-Object {
                    if ($_ -is [string]) { $_ } elseif ($_ -and $_.PSObject.Properties['text']) { [string]$_.text }
                }) -join "`n"
                if (-not [string]::IsNullOrWhiteSpace($text)) {
                    $result.Reasoning = $text.Trim(); $result.Latest = $text.Trim(); $result.LatestIsThinking = $true
                }
            }
            default {
                $name = if ($payload.PSObject.Properties['name'] -and $payload.name) { [string]$payload.name }
                    elseif ($kind -eq 'local_shell_call') { 'shell' } elseif ($kind -eq 'web_search_call') { 'web search' } else { $kind }
                $result.History = @($result.History) + "Ran: $name"
            }
        }
    }
    $result
}

function Read-CodexTranscriptAppend {
    <#
        Reads the bytes appended since the last offset.

        Mirrors the other adapters' readers: a capped tail so a burst cannot stall the
        loop, a reset when the file shrinks, and a partial trailing line withheld until
        it is complete so a half-written line is never parsed.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [long]$Offset = 0,
        [int]$MaxTailBytes = 512000
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Lines = @(); Offset = 0 }
    }

    $length = (Get-Item -LiteralPath $Path).Length
    if ($length -lt $Offset) { $Offset = 0 }
    if ($length -eq $Offset) { return [pscustomobject]@{ Lines = @(); Offset = $Offset } }

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

    $lines = $text -split "`n"
    $trailing = 0
    if (-not $text.EndsWith("`n") -and $lines.Count -gt 0) {
        $trailing = [Text.Encoding]::UTF8.GetByteCount($lines[-1])
        $lines = if ($lines.Count -ge 2) { $lines[0..($lines.Count - 2)] } else { @() }
    }

    [pscustomobject]@{
        Lines  = @($lines | Where-Object { $_.Trim() })
        Offset = $length - $trailing
    }
}
