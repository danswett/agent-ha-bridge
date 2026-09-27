#Requires -Version 7.0
<#
.SYNOPSIS
    Tests the Claude Code transcript reducer and tailing reader.

.DESCRIPTION
    Uses a fixture whose entry shape matches the shipping tool's own transcript
    schema. Needs no Home Assistant and no Claude session.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\claude-transcript.ps1')

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($ok) { Write-Host "  PASS  $Name" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

$fixture = Join-Path $PSScriptRoot '..\fixtures\transcript.jsonl'
$lines = @(Get-Content $fixture | Where-Object { $_.Trim() })

Write-Host '--- reducing a whole transcript ---'
$activity = Get-ClaudeActivityFromTranscript -Lines $lines
Test-That 'the session reads as working' { $activity.Status -eq 'working' } $activity.Status
Test-That 'the last assistant text becomes the summary' {
    $activity.Summary -eq 'Done. Uploads now retry three times with exponential backoff.'
} $activity.Summary
Test-That 'the full response is kept, not just its first line' {
    $activity.Response -match 'Only idempotent verbs'
}
Test-That 'thinking is captured as reasoning' {
    $activity.Reasoning -match 'no backoff'
} $activity.Reasoning
Test-That 'a user message appears in the history' { $activity.History -contains 'Reading your message' }
Test-That 'a tool call appears in the history' { $activity.History -contains 'Running: Read' }

Write-Host '--- entries that must be ignored ---'
Test-That 'a sidechain tool call is excluded' {
    $activity.History -notcontains 'Running: SubagentOnlyTool'
}
Test-That 'a meta entry does not count as a user message' {
    @($activity.History | Where-Object { $_ -eq 'Reading your message' }).Count -eq 1
} "$(@($activity.History | Where-Object { $_ -eq 'Reading your message' }).Count)"
Test-That 'a tool result is not treated as a user message' {
    # Four user-ish entries exist but only one is a real prompt.
    @($activity.History | Where-Object { $_ -eq 'Reading your message' }).Count -eq 1
}

Write-Host '--- content shapes ---'
Test-That 'a string content body is handled' {
    $line = '{"type":"assistant","message":{"role":"assistant","content":"plain string"}}'
    (Get-ClaudeActivityFromTranscript -Lines @($line)).Summary -eq 'plain string'
}
Test-That 'an entry with no content does not throw' {
    $line = '{"type":"assistant","message":{"role":"assistant"}}'
    $null -eq (Get-ClaudeActivityFromTranscript -Lines @($line)).Summary
}
Test-That 'malformed lines are skipped' {
    (Get-ClaudeActivityFromTranscript -Lines @('{bad', '')).Status -eq $null
}
Test-That 'an empty batch yields nothing' {
    $result = Get-ClaudeActivityFromTranscript -Lines @()
    $null -eq $result.Status -and $result.History.Count -eq 0
}

Write-Host '--- tailing reader ---'
$temp = Join-Path ([IO.Path]::GetTempPath()) "claude-transcript-$([guid]::NewGuid().ToString('N').Substring(0,8)).jsonl"
try {
    Copy-Item $fixture $temp
    $first = Read-ClaudeTranscriptAppend -Path $temp -Offset 0
    Test-That 'a first read returns every line' { $first.Lines.Count -eq $lines.Count } "$($first.Lines.Count) of $($lines.Count)"
    Test-That 'the offset advances to the end' { $first.Offset -eq (Get-Item $temp).Length }

    $second = Read-ClaudeTranscriptAppend -Path $temp -Offset $first.Offset
    Test-That 'a second read with no new data returns nothing' { $second.Lines.Count -eq 0 }

    Add-Content -LiteralPath $temp -Value '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Bash","input":{}}]}}'
    $third = Read-ClaudeTranscriptAppend -Path $temp -Offset $second.Offset
    Test-That 'only the appended line is returned' { $third.Lines.Count -eq 1 } "$($third.Lines.Count)"
    Test-That 'the appended line reduces correctly' {
        (Get-ClaudeActivityFromTranscript -Lines $third.Lines).Summary -eq 'Running: Bash'
    }

    # A half-written final line must be withheld until it is complete.
    [IO.File]::AppendAllText($temp, '{"type":"assistant","message":{"role":"assis')
    $partial = Read-ClaudeTranscriptAppend -Path $temp -Offset $third.Offset
    Test-That 'a partial trailing line is withheld' { $partial.Lines.Count -eq 0 } "$($partial.Lines.Count)"
    [IO.File]::AppendAllText($temp, ('tant","content":"finished"}}' + "`n"))
    $completed = Read-ClaudeTranscriptAppend -Path $temp -Offset $partial.Offset
    Test-That 'it is delivered once complete' { $completed.Lines.Count -eq 1 } "$($completed.Lines.Count)"

    Set-Content -LiteralPath $temp -Value '{"type":"user","message":{"role":"user","content":"restarted"}}'
    $shrunk = Read-ClaudeTranscriptAppend -Path $temp -Offset 999999
    Test-That 'a shrinking file resets the offset' { $shrunk.Lines.Count -eq 1 } "$($shrunk.Lines.Count)"

    Test-That 'a missing file is handled' {
        (Read-ClaudeTranscriptAppend -Path (Join-Path $temp 'nope.jsonl')).Lines.Count -eq 0
    }
}
finally {
    Remove-Item $temp -Force -ErrorAction SilentlyContinue
}

Write-Host '--- the real transcript shape ---'
# Entry types and envelope fields here were taken from a live Claude Code session:
# queue-operation, attachment, atis-latch, last-prompt, ai-title and system all
# appear alongside the user/assistant entries and must be ignored.
$realLines = @(Get-Content (Join-Path $PSScriptRoot '..\fixtures\transcript-real-shape.jsonl') | Where-Object { $_.Trim() })
$real = Get-ClaudeActivityFromTranscript -Lines $realLines
Test-That 'the response survives all the noise entry types' {
    $real.Summary -eq 'sample.txt contains a single line reading "hello from the scratch file."'
} $real.Summary
Test-That 'thinking is picked up from the real envelope' { $real.Reasoning -match 'read the file' } $real.Reasoning
Test-That 'the tool call is recorded' { $real.History -contains 'Running: Read' }
Test-That 'exactly one user prompt is counted' {
    @($real.History | Where-Object { $_ -eq 'Reading your message' }).Count -eq 1
} "$(@($real.History | Where-Object { $_ -eq 'Reading your message' }).Count)"
Test-That 'attachment and system entries add nothing' { $real.History.Count -eq 3 } "$($real.History.Count)"

Write-Host ''
Write-Host '--- a new message starts a new turn ---'

function New-Line {
    param([string]$Type, [object]$Content)
    @{ type = $Type; message = @{ role = $Type; content = $Content } } | ConvertTo-Json -Depth 8 -Compress
}
$endOfTurn = @(
    (New-Line 'assistant' @(@{ type = 'thinking'; thinking = 'old reasoning' }))
    (New-Line 'assistant' @(@{ type = 'tool_use'; name = 'Edit'; input = @{} }))
)
$nextTurn = @(
    (New-Line 'user' 'the next question')
    (New-Line 'assistant' @(@{ type = 'tool_use'; name = 'Read'; input = @{} }))
)

$carryOn = Get-ClaudeActivityFromTranscript -Lines $endOfTurn
Test-That 'a batch with no new message is not a new turn' { -not $carryOn.TurnStarted }

$turn = Get-ClaudeActivityFromTranscript -Lines @($endOfTurn + $nextTurn)
Test-That 'a batch with a new message marks a new turn' { $turn.TurnStarted }
Test-That 'reasoning from before the message is dropped' { [string]::IsNullOrEmpty($turn.Reasoning) } $turn.Reasoning
Test-That 'history starts from the message' {
    ($turn.History -join ',') -eq 'Reading your message,Running: Read'
} ($turn.History -join ',')

Write-Host ''
Write-Host '--- when the newest activity happened ---'

$stamped = @(
    (@{ type = 'assistant'; timestamp = '2026-09-27T07:00:00.000Z'; message = @{ content = @(@{ type = 'text'; text = 'a' }) } } | ConvertTo-Json -Depth 8 -Compress)
    (@{ type = 'attachment'; timestamp = '2026-09-27T09:00:00.000Z' } | ConvertTo-Json -Compress)
    (@{ type = 'assistant'; timestamp = '2026-09-27T07:05:00.000Z'; message = @{ content = @(@{ type = 'text'; text = 'b' }) } } | ConvertTo-Json -Depth 8 -Compress)
)
$timed = Get-ClaudeActivityFromTranscript -Lines $stamped
Test-That 'the newest user or assistant entry is reported' {
    $timed.LastActivityAt -eq [DateTimeOffset]'2026-09-27T07:05:00Z'
} "$($timed.LastActivityAt)"
Test-That 'housekeeping entries do not count as activity' { $timed.LastActivityAt -lt [DateTimeOffset]'2026-09-27T09:00:00Z' }
Test-That 'a batch with no timestamps reports none' { $null -eq (Get-ClaudeActivityFromTranscript -Lines $endOfTurn).LastActivityAt }

Write-Host ''
Write-Host '--- the newest line, in terminal order ---'

# Claude Code shows thinking summaries and replies in one stream. The card follows
# the newest of either kind, or it reads as out of order against the terminal.
$thenThought = Get-ClaudeActivityFromTranscript -Lines @(
    (New-Line 'assistant' @(@{ type = 'text'; text = 'a reply' }))
    (New-Line 'assistant' @(@{ type = 'thinking'; thinking = 'a later thought' }))
)
Test-That 'a thought after a reply is the newest line' {
    $thenThought.Latest -eq 'a later thought' -and $thenThought.LatestIsThinking
}
Test-That 'while the reply is still kept as the response' { $thenThought.Response -eq 'a reply' }

$thenReply = Get-ClaudeActivityFromTranscript -Lines @(
    (New-Line 'assistant' @(@{ type = 'thinking'; thinking = 'a thought' }))
    (New-Line 'assistant' @(@{ type = 'text'; text = 'the reply' }))
)
Test-That 'a reply after a thought is the newest line' { $thenReply.Latest -eq 'the reply' -and -not $thenReply.LatestIsThinking }

$empty = Get-ClaudeActivityFromTranscript -Lines @((New-Line 'assistant' @(@{ type = 'thinking'; thinking = '' })))
Test-That 'an empty thinking block is not a line' { $null -eq $empty.Latest }

$newTurn = Get-ClaudeActivityFromTranscript -Lines @(
    (New-Line 'assistant' @(@{ type = 'thinking'; thinking = 'last turn' }))
    (New-Line 'user' 'next question')
)
Test-That 'a new message clears the newest line' { $null -eq $newTurn.Latest }

$toolResult = New-Line 'user' @(@{ type = 'tool_result'; tool_use_id = 'x'; content = 'ok' })
Test-That 'a tool result is not a new turn' {
    -not (Get-ClaudeActivityFromTranscript -Lines @($endOfTurn + $toolResult)).TurnStarted
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) test(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All tests passed' -ForegroundColor Green
