#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for Copilot's transcript reader (Get-ActivityFromEvents) and the card it
    produces.

.DESCRIPTION
    Copilot writes its thinking as `assistant.message` events of its own, interleaved
    with the ones that also carry text - the same shape Claude writes, and the reason
    its card can show them in the order they happened rather than putting the last
    thought in an expander under an older reply.

    Measured on a real session before this was written: of 88 assistant messages, 36
    carried reasoning alone, 20 carried reasoning and text together, and 4 carried text
    alone. Both shapes are covered below.

    The real parser and the real daemon function run here; Home Assistant is a
    recorder, and nothing leaves the machine.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
$script:DaemonConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-copilot-activity-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $__ok = $false
    try { $__ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($__ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

# Events as Copilot writes them; only the fields the reader looks at are filled in.
function New-Thought { param([string]$Text) (@{ type = 'assistant.message'; data = @{ reasoningText = $Text } } | ConvertTo-Json -Depth 5 -Compress) }
function New-Reply { param([string]$Text, [string]$Thought = '') (@{ type = 'assistant.message'; data = @{ content = $Text; reasoningText = $Thought } } | ConvertTo-Json -Depth 5 -Compress) }
function New-Tool { param([string]$Name) (@{ type = 'tool.execution_start'; data = @{ toolName = $Name } } | ConvertTo-Json -Depth 5 -Compress) }
function New-ReplyFrom { param([string]$Text, [string]$Model) (@{ type = 'assistant.message'; data = @{ content = $Text; model = $Model } } | ConvertTo-Json -Depth 5 -Compress) }

Write-Host '--- which model is writing ---'
# Copilot stamps the model on every assistant message. Reading it here is what lets a
# session's card say what it is running without the bridge having launched it - the
# launch record, which is the only source for effort and context, covers nothing that
# was started at a keyboard.
$activity = Get-ActivityFromEvents -Lines @((New-ReplyFrom 'done' 'claude-opus-5')) -VerboseMode $true
Test-That 'the model on an assistant message is picked up' { $activity.Model -eq 'claude-opus-5' }
$activity = Get-ActivityFromEvents -Lines @(
    (New-ReplyFrom 'first' 'gpt-5.4'), (New-Tool 'shell'), (New-ReplyFrom 'second' 'claude-opus-5')) -VerboseMode $true
Test-That 'the newest one in the batch wins, so a /model mid-turn is followed' { $activity.Model -eq 'claude-opus-5' }
# Absence is not a change. A batch of tool calls says nothing about the model, and
# treating that as "no model" would blank the card's settings line every few seconds.
$activity = Get-ActivityFromEvents -Lines @((New-Tool 'shell'), (New-Thought 'hmm')) -VerboseMode $true
Test-That 'a batch with no assistant message reports no model, not an empty one' {
    [string]::IsNullOrEmpty([string]$activity.Model)
}
$activity = Get-ActivityFromEvents -Lines @((New-Reply 'no model field here')) -VerboseMode $true
Test-That 'a message from an older CLI that names none is handled' {
    [string]::IsNullOrEmpty([string]$activity.Model)
}

Write-Host '--- the newest line of either kind ---'
$activity = Get-ActivityFromEvents -Lines @((New-Thought 'I should look at the config first')) -VerboseMode $true
Test-That 'a thinking-only message is the newest line' { $activity.Latest -eq 'I should look at the config first' }
Test-That 'and is marked as thinking' { $activity.LatestIsThinking }
Test-That 'it is still captured as reasoning, for an agent that shows an expander' { $activity.Reasoning -eq 'I should look at the config first' }
Test-That 'and is not mistaken for a response' { [string]::IsNullOrEmpty([string]$activity.Response) }

$activity = Get-ActivityFromEvents -Lines @((New-Reply 'Here is the result.' 'the thought behind it')) -VerboseMode $true
Test-That 'within one message the text wins, because the thinking came first' { $activity.Latest -eq 'Here is the result.' }
Test-That 'so it is not marked as thinking' { -not $activity.LatestIsThinking }
Test-That 'the thinking is still captured' { $activity.Reasoning -eq 'the thought behind it' }
Test-That 'and the response is the full text' { $activity.Response -eq 'Here is the result.' }

Write-Host '--- across a batch, in order ---'
$batch = @(
    '{"type":"assistant.turn_start"}'
    (New-Thought 'first thought')
    (New-Tool 'grep')
    (New-Reply 'the answer' 'second thought')
    (New-Tool 'edit')
    (New-Thought 'a last thought')
)
$activity = Get-ActivityFromEvents -Lines $batch -VerboseMode $true
Test-That 'the last thought wins over the earlier reply' { $activity.Latest -eq 'a last thought' -and $activity.LatestIsThinking }
Test-That 'the reply is still remembered as the response' { $activity.Response -eq 'the answer' }
Test-That 'the summary is the last tool call, which is what the status line shows' { $activity.Summary -eq 'Running: edit' }

# With detail on, a thought is a step in the trail like any other, in the order it
# happened. Before this the trail held tools and text only: every message carries a
# thought and most carry nothing else, so the reasoning between the steps - which is
# most of what the agent did - was never shown and could not be recovered.
Test-That 'the trail interleaves thinking with what was done' {
    (@($activity.History) -join '|') -eq
        'Thinking: first thought|Running: grep|Thinking: second thought|the answer|Running: edit|Thinking: a last thought'
} (@($activity.History) -join '|')

# And is unchanged without it, which is what the switch is for.
$plain = Get-ActivityFromEvents -Lines $batch -VerboseMode $false
Test-That 'without detail the trail holds only what was done' {
    (@($plain.History) -join '|') -eq 'Running: grep|the answer|Running: edit'
} (@($plain.History) -join '|')
Test-That 'though the thinking is still captured either way' { $plain.Reasoning -eq 'a last thought' }

Write-Host '--- a thought is reduced to one line for the trail ---'
# The trail is a list on a phone; reasoning is paragraphs.
Test-That 'only the first line is taken' {
    (Get-BridgeThoughtLine -Text "Checking the config`n`nThen the rest of it") -eq 'Thinking: Checking the config'
}
Test-That 'a markdown heading loses its markup' {
    (Get-BridgeThoughtLine -Text '**Weighing the options**') -eq 'Thinking: Weighing the options'
}
Test-That 'and a hash heading too' {
    (Get-BridgeThoughtLine -Text '## Weighing the options') -eq 'Thinking: Weighing the options'
}
Test-That 'a long line is cut rather than filling the card' {
    $long = Get-BridgeThoughtLine -Text ('x' * 400)
    $long.Length -lt 140 -and $long.EndsWith([char]0x2026)
} (Get-BridgeThoughtLine -Text ('x' * 400))
Test-That 'nothing worth showing gives nothing' { (Get-BridgeThoughtLine -Text "   `n  ") -eq '' }

$activity = Get-ActivityFromEvents -Lines @((New-Thought 'thinking'), (New-Reply 'and then speaking')) -VerboseMode $true
Test-That 'a reply after a thought wins' { $activity.Latest -eq 'and then speaking' -and -not $activity.LatestIsThinking }

Write-Host '--- nothing to say ---'
Write-Host '--- a new turn is noticed, as it is for Claude and Codex ---'
# Copilot's reducer was the only one that never reported this, so for a Copilot session
# the caller believed no turn ever started. Two things rode on that: the reasoning and
# history carried from the previous turn were never dropped, and - since the same flag
# is what hands a session back to the person at the keyboard - a card an agent had
# driven once kept its purple edge for the rest of the session.
$activity = Get-ActivityFromEvents -Lines @('{"type":"user.message"}') -VerboseMode $true
Test-That 'a user message starts a new turn' { $activity.TurnStarted }

$activity = Get-ActivityFromEvents -Lines @((New-Thought 'still going'), (New-Tool 'grep')) -VerboseMode $true
Test-That 'a batch with no user message does not' { -not $activity.TurnStarted }

$activity = Get-ActivityFromEvents -Lines @(
    (New-Thought 'last turn''s thinking')
    '{"type":"user.message"}'
) -VerboseMode $true
Test-That 'thinking from before the new message is dropped, not carried into it' {
    [string]::IsNullOrEmpty([string]$activity.Reasoning) -and [string]::IsNullOrEmpty([string]$activity.Latest)
} "reasoning=[$($activity.Reasoning)] latest=[$($activity.Latest)]"
Test-That 'and the new turn is still reported' { $activity.TurnStarted }

$activity = Get-ActivityFromEvents -Lines @(
    '{"type":"user.message"}'
    (New-Thought 'this turn''s thinking')
) -VerboseMode $true
Test-That 'thinking after the new message is kept' { $activity.Latest -eq "this turn's thinking" }

$activity = Get-ActivityFromEvents -Lines @((New-Tool 'grep')) -VerboseMode $true
Test-That 'a batch of only tool calls has no newest line' { [string]::IsNullOrEmpty([string]$activity.Latest) }
Test-That 'and is not marked as thinking' { -not $activity.LatestIsThinking }
$activity = Get-ActivityFromEvents -Lines @('not json at all', '{"type":"assistant.message"}') -VerboseMode $true
Test-That 'a malformed line does not throw' { [string]::IsNullOrEmpty([string]$activity.Latest) }

Write-Host '--- what reaches the card ---'
# Everything that would reach Home Assistant is stood in for.
$script:Published = $null
$script:StatusPublishes = @()
function Set-CopilotMqttActivity { param($SessionId, $Summary, $Detail, $Headers) $script:Published = $Detail }
function Set-CopilotMqttStatus { param($SessionId, $Status, $Headers, $Attributes) $script:StatusPublishes += [pscustomobject]@{ Status = $Status; Attributes = $Attributes } }
function Write-DaemonLog { param([string]$Message) }

$transcript = Join-Path ([IO.Path]::GetTempPath()) "copilot-activity-$([guid]::NewGuid().ToString('N')).jsonl"
$entry = [pscustomobject]@{ Offset = 0; Name = 'Copilot: task'; Machine = 'DESK'; Status = 'working'; Kind = 'copilot' }
$session = [pscustomobject]@{ SessionId = 's'; Transcript = $transcript; ProcessId = 1 }
function Step { param([string[]]$Lines, [bool]$Verbose = $true)
    Add-Content -LiteralPath $transcript -Value $Lines -Encoding utf8
    Update-DaemonSessionActivity -Id 'cccccccc-1111-2222-3333-444444444444' -Entry $entry -Session $session -Headers @{} -VerboseOn $Verbose
}
try {
    Step -Lines @((New-Thought 'weighing the options'))
    Test-That 'a thought is shown inline, as the card body' { $script:Published['response'] -eq 'weighing the options' }
    Test-That 'and marked so the card renders it as thinking' { $script:Published['response_kind'] -eq 'reasoning' }
    Test-That 'with no expander repeating it below' { -not $script:Published.ContainsKey('reasoning') }

    Step -Lines @((New-Reply 'Here is what I found.' 'one more thought'))
    Test-That 'a reply then replaces it' { $script:Published['response'] -eq 'Here is what I found.' -and $script:Published['response_kind'] -eq 'text' }

    Step -Lines @((New-Tool 'grep'))
    Test-That 'a tool call leaves the last line in place rather than blanking the card' { $script:Published['response'] -eq 'Here is what I found.' }

    # Detailed activity off: thinking is withheld and the last answer stands.
    Step -Lines @((New-Thought 'a private thought')) -Verbose $false
    Test-That 'with Detailed activity off the thinking is not published' {
        $script:Published['response'] -eq 'Here is what I found.' -and -not $script:Published.ContainsKey('reasoning')
    }
    Test-That 'but it is still captured, so the toggle can show it at once' { $entry.LastMessage -eq 'a private thought' }
    # What the toggle republishes: the same layout function, off the same state, with
    # no fresh transcript activity to wait for.
    $toggled = @{}
    Add-DaemonCardText -Entry $entry -Detail $toggled -VerboseOn $true
    Test-That 'and turning it back on shows it without waiting for more thinking' {
        $toggled['response'] -eq 'a private thought' -and $toggled['response_kind'] -eq 'reasoning'
    }

    # The model reaches the card's settings line through the status attributes, which
    # are republished wholesale. The status only changes at the edges of a turn, so a
    # model learned mid-turn needs a publish of its own - without it the line stayed
    # blank for a session that was already working when the daemon first saw it.
    $script:StatusPublishes = @()
    Step -Lines @((New-ReplyFrom 'from a named model' 'claude-opus-5'))
    Test-That 'a model learned from the transcript is recorded on the session' { $entry.Model -eq 'claude-opus-5' }
    Test-That 'and published even though the status did not change' {
        @($script:StatusPublishes).Count -eq 1 -and $script:StatusPublishes[-1].Attributes['model'] -eq 'claude-opus-5'
    } "publishes=$(@($script:StatusPublishes).Count)"
    Test-That 'at the status it already had, not a made-up one' { $script:StatusPublishes[-1].Status -eq 'working' }

    $script:StatusPublishes = @()
    Step -Lines @((New-ReplyFrom 'same model again' 'claude-opus-5'))
    Test-That 'the same model again publishes nothing, so an idle session stays quiet' {
        @($script:StatusPublishes).Count -eq 0
    } "publishes=$(@($script:StatusPublishes).Count)"

    $script:StatusPublishes = @()
    Step -Lines @((New-Tool 'grep'))
    Test-That 'and a batch naming no model does not blank the one already shown' {
        $entry.Model -eq 'claude-opus-5' -and @($script:StatusPublishes).Count -eq 0
    }

    $script:StatusPublishes = @()
    Step -Lines @((New-ReplyFrom 'switched' 'gpt-5.4'))
    Test-That 'a /model typed into the window is followed' {
        $entry.Model -eq 'gpt-5.4' -and $script:StatusPublishes[-1].Attributes['model'] -eq 'gpt-5.4'
    }
}
finally {
    Remove-Item -LiteralPath $transcript -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:DaemonConfig.LogFile -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '--- the shapes Copilot actually writes ---'
# Counted from one real session's events.jsonl: 518 assistant messages in three
# shapes, and 224 of them carry no reasoningText at all. Reading that field directly
# throws under StrictMode, inside a catch, so those 224 were dropped in silence - the
# card kept whatever the last message with thinking in it had said.
$shapeWithReasoning = '{"type":"assistant.message","data":{"apiCallId":"a","content":"with thinking","interactionId":"i","messageId":"m","model":"x","originatingMessageId":"o","reasoningBlocks":[],"reasoningOpaque":"z","reasoningText":"the thought","rte":1,"toolRequests":[],"turnId":"t"}}'
$shapeNoReasoning = '{"type":"assistant.message","data":{"apiCallId":"a","content":"the final answer","interactionId":"i","messageId":"m","model":"x","originatingMessageId":"o","rte":1,"toolRequests":[],"turnId":"t"}}'
$shapeMinimal = '{"type":"assistant.message","data":{"content":"a short one","messageId":"m","toolRequests":[]}}'

$withReasoning = Get-ActivityFromEvents -Lines @($shapeWithReasoning) -VerboseMode $false
Test-That 'a message carrying thinking still works' {
    $withReasoning.Latest -eq 'with thinking' -and $withReasoning.Reasoning -eq 'the thought'
} "$($withReasoning.Latest)"

$noReasoning = Get-ActivityFromEvents -Lines @($shapeNoReasoning) -VerboseMode $false
Test-That 'a message with no reasoningText is not thrown away' {
    $noReasoning.Latest -eq 'the final answer'
} "$($noReasoning.Latest)"
Test-That 'and is published as the response' { $noReasoning.Response -eq 'the final answer' } "$($noReasoning.Response)"
Test-That 'and is not mistaken for thinking' { -not $noReasoning.LatestIsThinking }

$minimal = Get-ActivityFromEvents -Lines @($shapeMinimal) -VerboseMode $false
Test-That 'the shortest shape is read too' { $minimal.Latest -eq 'a short one' } "$($minimal.Latest)"

Test-That 'a later answer without thinking beats an earlier one with it' {
    (Get-ActivityFromEvents -Lines @($shapeWithReasoning, $shapeNoReasoning) -VerboseMode $false).Latest -eq 'the final answer'
}
Test-That 'a tool call with no toolName does not drop the batch' {
    $mixed = Get-ActivityFromEvents -Lines @('{"type":"tool.execution_start","data":{"nothing":1}}', $shapeNoReasoning) -VerboseMode $false
    $mixed.Latest -eq 'the final answer'
}
Test-That 'an event with no data at all is survivable' {
    $bare = Get-ActivityFromEvents -Lines @('{"type":"assistant.message"}', $shapeMinimal) -VerboseMode $false
    $bare.Latest -eq 'a short one'
}

Write-Host ''
Write-Host '--- a message still being written is not lost ---'
# The bug this covers: the reader advanced the offset past a half-written final line
# and handed it to the parser anyway. ConvertFrom-Json threw, the throw was swallowed,
# and the message was never read again - so a turn's final answer never reached the
# card, which sat on the previous line while the status said idle.
$tailFile = Join-Path ([IO.Path]::GetTempPath()) ("copilot-tail-" + [Guid]::NewGuid().ToString('N') + '.jsonl')
try {
    $whole = '{"type":"assistant.message","data":{"content":"first"}}' + "`n"
    [IO.File]::WriteAllText($tailFile, $whole)
    $firstRead = Read-TranscriptAppend -Path $tailFile -Offset 0
    Test-That 'a complete line is read' { @($firstRead.Lines).Count -eq 1 } "$(@($firstRead.Lines).Count)"

    # The second message, flushed in two parts - what the fast lane sees every 100 ms.
    $half = '{"type":"assistant.message","data":{"content":"the final ans'
    [IO.File]::AppendAllText($tailFile, $half)
    $partial = Read-TranscriptAppend -Path $tailFile -Offset $firstRead.Offset
    Test-That 'a half-written line is withheld, not parsed' { @($partial.Lines).Count -eq 0 } "$(@($partial.Lines).Count)"
    Test-That 'and the offset does not move past it' { $partial.Offset -eq $firstRead.Offset } "$($partial.Offset) vs $($firstRead.Offset)"

    [IO.File]::AppendAllText($tailFile, 'wer"}}' + "`n")
    $complete = Read-TranscriptAppend -Path $tailFile -Offset $partial.Offset
    Test-That 'once complete it is read, whole' {
        @($complete.Lines).Count -eq 1 -and $complete.Lines[0] -match 'the final answer'
    } "$(@($complete.Lines).Count)"
    $reduced = Get-ActivityFromEvents -Lines @($complete.Lines) -VerboseMode $false
    Test-That 'so the turn''s last answer is what the card would show' {
        $reduced.Latest -eq 'the final answer'
    } "$($reduced.Latest)"
    Test-That 'and nothing is read twice' {
        @((Read-TranscriptAppend -Path $tailFile -Offset $complete.Offset).Lines).Count -eq 0
    }
}
finally {
    Remove-Item -LiteralPath $tailFile -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All Copilot activity checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
