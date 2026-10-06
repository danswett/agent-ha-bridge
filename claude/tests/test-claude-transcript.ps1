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

. (Join-Path $PSScriptRoot '..\..\hooks\decision-bridge-common.ps1')
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

# Thinking joins the trail only when Detailed activity is on. Without it the trail
# showed what Claude did and never what it was weighing, and the newest thought was
# erased by the next one before anyone could read it.
Test-That 'without detail, thinking stays out of the trail' {
    -not @($activity.History | Where-Object { $_ -like 'Thinking:*' })
} (@($activity.History) -join ' | ')
$detailed = Get-ClaudeActivityFromTranscript -Lines $lines -VerboseMode $true
Test-That 'with detail, the thinking is a step in the trail' {
    @($detailed.History | Where-Object { $_ -like 'Thinking:*' }).Count -gt 0
} (@($detailed.History) -join ' | ')
Test-That 'and what it did is still there beside it' {
    $detailed.History -contains 'Running: Read'
}

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

Write-Host '--- which model is writing ---'
# Claude records the model on every assistant entry. Reading it is what lets a
# session's card say what it is running without the bridge having launched it: the
# launch record, the only source for effort and context, covers nothing started at a
# keyboard.
Test-That 'the model on an assistant entry is picked up' { $activity.Model -eq 'claude-opus-4' } $activity.Model
Test-That 'the newest one wins, so a /model mid-session is followed' {
    $later = '{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-5","content":[{"type":"text","text":"ok"}]}}'
    (Get-ClaudeActivityFromTranscript -Lines (@($lines) + @($later))).Model -eq 'claude-sonnet-5'
}
# Absence is not a change. A batch of user entries says nothing about the model, and
# treating that as "no model" would blank the card's settings line every few seconds.
Test-That 'a batch with no assistant entry reports no model' {
    $user = '{"type":"user","message":{"role":"user","content":"hello"}}'
    [string]::IsNullOrEmpty([string](Get-ClaudeActivityFromTranscript -Lines @($user)).Model)
}
Test-That 'an entry naming no model does not blank it either' {
    $none = '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}'
    [string]::IsNullOrEmpty([string](Get-ClaudeActivityFromTranscript -Lines @($none)).Model)
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

Write-Host ''
Write-Host '--- is a question still waiting? ---'

# The daemon used Copilot's reader here, which never found a Claude question, so a
# Claude card stayed armed forever and a dashboard answer was never delivered.
$qFile = Join-Path ([IO.Path]::GetTempPath()) "ask-$([guid]::NewGuid().ToString('N').Substring(0,8)).jsonl"
Set-Content -LiteralPath $qFile -Value @(
    (New-Line 'assistant' @(@{ type = 'tool_use'; id = 'ask1'; name = 'AskUserQuestion'; input = @{ questions = @() } }))
    '{"type":"queue-operation","operation":"enqueue","content":"mentions AskUserQuestion but has no message"}'
)
$q = Get-ClaudeAskUserState -TranscriptPath $qFile
Test-That 'an unanswered question is started and pending' { $q.Started -and $q.Pending -and $q.ToolCallId -eq 'ask1' }
Test-That 'an entry with no message does not throw' { $q.Started }

Add-Content -LiteralPath $qFile -Value (New-Line 'user' @(@{ type = 'tool_result'; tool_use_id = 'ask1'; content = 'Your questions have been answered: "Which?"="SQLite".' }))
$q = Get-ClaudeAskUserState -TranscriptPath $qFile
Test-That 'its answer ends the wait' { $q.Started -and -not $q.Pending }
Test-That 'and carries the chosen label for the mismatch check' { $q.ResultContent -like '*"SQLite"*' }
Test-That 'the established Claude result envelope verifies through the real transcript reader' {
    $field = [pscustomobject]@{ Name = 'Which?'; Label = 'Database'; Options = @('PostgreSQL', 'SQLite'); IsText = $false }
    (Test-CopilotAnswerMatchesSelections -ResultContent $q.ResultContent -Fields @($field) `
        -Selections @('SQLite') -Detailed).Status -ceq 'Matched'
}

Add-Content -LiteralPath $qFile -Value (New-Line 'assistant' @(@{ type = 'tool_use'; id = 'ask2'; name = 'AskUserQuestion'; input = @{ questions = @() } }))
$q = Get-ClaudeAskUserState -TranscriptPath $qFile
Test-That 'a later question is the one that counts' { $q.ToolCallId -eq 'ask2' -and $q.Pending }
Test-That 'a missing transcript is simply not started' { -not (Get-ClaudeAskUserState -TranscriptPath 'C:\nope\none.jsonl').Started }

# The hook fires before Claude writes the new question, so for a moment the latest
# question in the transcript is the previous, answered one. Judging the card by it
# cleared a brand-new card within seconds. A card judges its own question.
Add-Content -LiteralPath $qFile -Value (New-Line 'user' @(@{ type = 'tool_result'; tool_use_id = 'ask2'; content = 'answered' }))
$q = Get-ClaudeAskUserState -TranscriptPath $qFile -ToolCallId 'ask3-not-written-yet'
Test-That 'a named question not yet in the transcript is pending, not answered' { $q.Started -and $q.Pending -and $q.ToolCallId -eq 'ask3-not-written-yet' }
$q = Get-ClaudeAskUserState -TranscriptPath $qFile -Since ([DateTimeOffset]::Now.AddMinutes(5).ToString('o'))
Test-That 'without an id, an older answered question does not count' { -not $q.Started }
Add-Content -LiteralPath $qFile -Value (New-Line 'user' @(@{ type = 'tool_result'; tool_use_id = 'ask3-not-written-yet'; content = '"Q"="Banana"' }))
$q = Get-ClaudeAskUserState -TranscriptPath $qFile -ToolCallId 'ask3-not-written-yet'
Test-That 'and it is answered once its own result appears' { -not $q.Pending -and $q.ResultContent -like '*Banana*' }
Test-That 'a supplied native ID remains pending before its transcript exists' {
    $pending = Get-ClaudeAskUserState -TranscriptPath (Join-Path ([IO.Path]::GetTempPath()) 'not-written-yet.jsonl') -ToolCallId 'native-known'
    $pending.Started -and $pending.Pending -and $pending.ToolCallId -ceq 'native-known' -and $null -eq $pending.StartedAt
}
Set-Content -LiteralPath $qFile -Value @(
    '{"type":"assistant","timestamp":"2030-01-02T10:00:00Z","message":{"content":[{"type":"tool_use","id":"Ask-Sensitive","name":"AskUserQuestion"}]}}'
    '{"type":"assistant","timestamp":"2030-01-02T11:00:00Z","message":{"content":[{"type":"tool_use","id":"unrelated-newer","name":"AskUserQuestion"}]}}'
    (New-Line 'user' @(@{ type = 'tool_result'; tool_use_id = 'ask-sensitive'; content = 'wrong case' }))
)
$q = Get-ClaudeAskUserState -TranscriptPath $qFile -ToolCallId 'Ask-Sensitive' -Since '2030-01-03T10:00:00Z'
Test-That 'a supplied ID is ordinal, not satisfied by a differently cased result' { $q.Started -and $q.Pending -and $q.ResultContent -ceq '' }
Test-That 'an explicit ID uses its own start time rather than an unrelated latest question or Since filter' {
    [DateTimeOffset]$q.StartedAt -eq [DateTimeOffset]'2030-01-02T10:00:00Z'
}
Add-Content -LiteralPath $qFile -Value (New-Line 'user' @(@{ type = 'tool_result'; tool_use_id = 'Ask-Sensitive'; content = '"Which?"="SQLite"' }))
$q = Get-ClaudeAskUserState -TranscriptPath $qFile -ToolCallId 'Ask-Sensitive'
Test-That 'only the matching supplied native ID completes that question' {
    $q.Started -and -not $q.Pending -and $q.ResultContent -ceq '"Which?"="SQLite"'
}
$q = Get-ClaudeAskUserState -TranscriptPath $qFile
Test-That 'without a native ID the established latest-question fallback still applies' {
    $q.Started -and $q.Pending -and $q.ToolCallId -ceq 'unrelated-newer'
}

# A ToolSearch result is a list of tool_reference blocks with no text. One anywhere in
# the tail threw out of every daemon pass while a question waited, so the card stayed
# armed after its answer and nothing else on the machine reconciled either.
Set-Content -LiteralPath $qFile -Value @(
    (New-Line 'assistant' @(@{ type = 'tool_use'; id = 'search1'; name = 'ToolSearch'; input = @{ query = 'select:Monitor' } }))
    (New-Line 'user' @(@{ type = 'tool_result'; tool_use_id = 'search1'; content = @(@{ type = 'tool_reference'; tool_name = 'Monitor' }) }))
    (New-Line 'user' @(@{ type = 'tool_result'; tool_use_id = 'shot1'; content = @(@{ type = 'image'; source = @{ type = 'base64'; data = 'AA==' } }, @{ type = 'text'; text = 'a caption' }) }))
    (New-Line 'assistant' @(@{ type = 'tool_use'; id = 'ask4'; name = 'AskUserQuestion'; input = @{ questions = @() } }))
)
$q = Get-ClaudeAskUserState -TranscriptPath $qFile
Test-That 'a result made of tool references does not stop a question being found' { $q.Started -and $q.Pending -and $q.ToolCallId -ceq 'ask4' }
Add-Content -LiteralPath $qFile -Value (New-Line 'user' @(@{ type = 'tool_result'; tool_use_id = 'ask4'; content = @(@{ type = 'text'; text = '"Which?"="SQLite"' }) }))
$q = Get-ClaudeAskUserState -TranscriptPath $qFile
Test-That 'and the answer after it still ends the wait' { -not $q.Pending -and $q.ResultContent -ceq '"Which?"="SQLite"' }
Remove-Item -LiteralPath $qFile -Force -ErrorAction SilentlyContinue

$toolResult =New-Line 'user' @(@{ type = 'tool_result'; tool_use_id = 'x'; content = 'ok' })
Test-That 'a tool result is not a new turn' {
    -not (Get-ClaudeActivityFromTranscript -Lines @($endOfTurn + $toolResult)).TurnStarted
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) test(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All tests passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
