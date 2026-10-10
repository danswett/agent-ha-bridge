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

Write-Host ''
Write-Host "--- a subagent's events are not the session's ---"
# Copilot writes everything its subagents do into the session's own events.jsonl -
# their task prompts, their turns, their tool calls - stamped with a top-level
# agentId. Counted on a real transcript: of 7,381 events, all 571 a subagent produced
# carried it and none of the other 6,810 did. Reading them as the session's is what
# made a background agent's last turn_end leave the card saying idle.
function New-BackgroundAgent {
    param([string]$Call, [string]$Mode = 'background')
    (@{ type = 'subagent.started'; agentId = 'sub-1'
        data = @{ toolCallId = $Call; agentDisplayName = 'review'; executionMode = $Mode } } |
        ConvertTo-Json -Depth 5 -Compress)
}
function New-AgentFinished {
    param([string]$Call)
    (@{ type = 'subagent.completed'; agentId = 'sub-1'; data = @{ toolCallId = $Call } } |
        ConvertTo-Json -Depth 5 -Compress)
}
function New-SubagentEvent {
    param([string]$Type, [string]$Call = 'toolu_a')
    (@{ type = $Type; agentId = 'sub-1'; data = @{ parentToolCallId = $Call } } |
        ConvertTo-Json -Depth 5 -Compress)
}

$activity = Get-ActivityFromEvents -Lines @((New-BackgroundAgent 'toolu_a')) -VerboseMode $false
Test-That 'a background agent is reported by the tool call that started it' {
    (@($activity.AgentsStarted) -join ',') -eq 'toolu_a'
} (@($activity.AgentsStarted) -join ',')
# A sync agent holds the parent's tool call open, so the session is plainly working
# and the transcript never claims otherwise; only a background one outlives the turn.
$activity = Get-ActivityFromEvents -Lines @((New-BackgroundAgent 'toolu_b' 'sync')) -VerboseMode $false
Test-That 'a sync agent is not, because the turn it belongs to is still open' {
    @($activity.AgentsStarted).Count -eq 0
}
$activity = Get-ActivityFromEvents -Lines @((New-AgentFinished 'toolu_a')) -VerboseMode $false
Test-That 'and a finish names the same tool call' { (@($activity.AgentsFinished) -join ',') -eq 'toolu_a' }

$activity = Get-ActivityFromEvents -Lines @((New-SubagentEvent 'assistant.turn_start')) -VerboseMode $false
Test-That 'an agent starting a turn of its own does not say the session is working' {
    [string]::IsNullOrEmpty([string]$activity.Status)
} "$($activity.Status)"
$activity = Get-ActivityFromEvents -Lines @((New-SubagentEvent 'assistant.turn_end')) -VerboseMode $false
Test-That 'and ending one does not say the session has gone idle' {
    [string]::IsNullOrEmpty([string]$activity.Status)
} "$($activity.Status)"
$activity = Get-ActivityFromEvents -Lines @((New-SubagentEvent 'user.message')) -VerboseMode $false
Test-That 'the task it was handed is not a turn you typed' { -not $activity.TurnStarted }

# The cheap check in front of the parse is a containment test, so a message that
# happens to mention the field must still be read as the session's own.
$quoting = (@{ type = 'user.message'; data = @{ content = 'what is "agentId" for?' } } |
    ConvertTo-Json -Depth 5 -Compress)
$activity = Get-ActivityFromEvents -Lines @($quoting) -VerboseMode $false
Test-That 'a message merely quoting agentId is still yours' { $activity.TurnStarted }

Write-Host ''
Write-Host '--- the status the publisher is asked for ---'
# Publishing is wrapped in a catch that logs and swallows, so a status the publisher
# rejects fails quietly: the card keeps whatever it last said, which here is the idle
# reading this whole status exists to replace. Stubbed at the transport, so the real
# parameter contract is the thing under test and nothing leaves the machine.
$script:MqttPayloads = @()
function Publish-CopilotMqttMessage { param($Topic, $Payload, $Headers, [switch]$Retain) $script:MqttPayloads += [string]$Payload }
Set-CopilotMqttStatus -SessionId 'eeeeeeee-1111-2222-3333-444444444444' -Status 'agents' `
    -Headers @{} -Attributes @{ background_agents = 2 }
Test-That 'a session waiting on background agents is a status it accepts' {
    $script:MqttPayloads -contains 'agents'
} ($script:MqttPayloads -join '|')
# The same check for this change's own status, and the one that would have caught it
# being missing: every test below stubs the publisher, so a status it refuses looks
# perfectly healthy there while in production the card never moves off idle.
$script:MqttPayloads = @()
Set-CopilotMqttStatus -SessionId 'eeeeeeee-1111-2222-3333-444444444444' -Status 'shell' `
    -Headers @{} -Attributes @{ background_shells = 2 }
Test-That 'and so is one waiting on background commands' {
    $script:MqttPayloads -contains 'shell'
} ($script:MqttPayloads -join '|')

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
Write-Host '--- waiting for background agents is not idle ---'
<#
    A background agent outlives the turn that started it. The session's own turn ends,
    the transcript says idle, and the card then invites you to close a session whose
    work is still running - which is how a review that had been going for ten minutes
    was thrown away. Waiting on one is a status of its own, kept on the entry because
    a start and its finish are minutes and many reads apart.
#>
$agentLog = Join-Path ([IO.Path]::GetTempPath()) "copilot-agents-$([guid]::NewGuid().ToString('N')).jsonl"
$agentId = 'dddddddd-1111-2222-3333-444444444444'
$agentEntry = [pscustomobject]@{ Offset = 0; Name = 'Copilot: review'; Machine = 'DESK'; Status = 'working'; Kind = 'copilot' }
$agentSession = [pscustomobject]@{ SessionId = $agentId; Transcript = $agentLog; ProcessId = 1 }
function StepAgents {
    param([string[]]$Lines)
    Add-Content -LiteralPath $agentLog -Value $Lines -Encoding utf8
    Update-DaemonSessionActivity -Id $agentId -Entry $agentEntry -Session $agentSession -Headers @{} -VerboseOn $false
}
try {
    $script:StatusPublishes = @()
    StepAgents -Lines @((New-Tool 'task'), (New-BackgroundAgent 'toolu_a'), '{"type":"assistant.turn_end"}')
    Test-That 'a turn ending with an agent still running does not read as idle' { $agentEntry.Status -eq 'agents' } "$($agentEntry.Status)"
    Test-That 'and that is what reaches the card' { $script:StatusPublishes[-1].Status -eq 'agents' }
    Test-That 'with how many, so the card need not say "some"' {
        $script:StatusPublishes[-1].Attributes['background_agents'] -eq 1
    }

    $script:StatusPublishes = @()
    StepAgents -Lines @((New-SubagentEvent 'assistant.turn_start'), (New-SubagentEvent 'assistant.turn_end'))
    Test-That 'the agent working away leaves the session where it was' {
        $agentEntry.Status -eq 'agents' -and @($script:StatusPublishes).Count -eq 0
    } "$($agentEntry.Status), publishes=$(@($script:StatusPublishes).Count)"

    StepAgents -Lines @((New-BackgroundAgent 'toolu_b'))
    Test-That 'a second agent joins the first rather than replacing it' {
        @($agentEntry.BackgroundAgents).Count -eq 2
    } (@($agentEntry.BackgroundAgents) -join ',')

    StepAgents -Lines @((New-AgentFinished 'toolu_a'))
    Test-That 'one finishing leaves the session waiting on the other' { $agentEntry.Status -eq 'agents' }

    $script:StatusPublishes = @()
    StepAgents -Lines @((New-AgentFinished 'toolu_b'))
    Test-That 'the last one finishing hands the session back to idle' { $agentEntry.Status -eq 'idle' } "$($agentEntry.Status)"
    Test-That 'and says so, rather than leaving the card waiting on nothing' {
        $script:StatusPublishes[-1].Status -eq 'idle'
    }

    # Copilot writes a completion again for every agent it was still tracking when the
    # session shuts down. Counting down instead of tracking ids went negative here, and
    # a session that had finished three agents looked like it was waiting on one.
    StepAgents -Lines @((New-AgentFinished 'toolu_a'), (New-AgentFinished 'toolu_b'))
    Test-That 'a completion written twice at shutdown leaves no phantom agent' {
        $agentEntry.Status -eq 'idle' -and @($agentEntry.BackgroundAgents).Count -eq 0
    } "$($agentEntry.Status), outstanding=$(@($agentEntry.BackgroundAgents).Count)"

    StepAgents -Lines @((New-BackgroundAgent 'toolu_c'), '{"type":"assistant.turn_end"}')
    Test-That 'and a restart finds it waiting, not idle' {
        (Get-DaemonStartupStatus -Session $agentSession -Entry $agentEntry) -eq 'agents'
    } (Get-DaemonStartupStatus -Session $agentSession -Entry $agentEntry)

    # The StrictMode trap this count exists for: a property that is there but null
    # wraps to a one-element array holding $null, so a session that had never
    # delegated anything read as waiting on one agent it could never be rid of.
    Test-That 'a session carrying no agents at all is waiting on none' {
        (Get-DaemonBackgroundAgentCount -Entry ([pscustomobject]@{ BackgroundAgents = $null })) -eq 0
    }
    Test-That 'and neither is one from before the bridge tracked them' {
        (Get-DaemonBackgroundAgentCount -Entry ([pscustomobject]@{ Status = 'idle' })) -eq 0
    }

    # Adoption and restart ask the transcript directly whether a turn is open, which
    # is a second place a background agent's turns could be mistaken for the
    # session's - and one that would have masked the new status with 'working'.
    $root = Join-Path ([IO.Path]::GetTempPath()) "copilot-root-$([guid]::NewGuid().ToString('N'))"
    $events = Join-Path (Join-Path $root (Get-CopilotSafeSessionKey -SessionId $agentId)) 'events.jsonl'
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $events) -Force)
    $savedRoot = $script:DecisionBridgeConfig.SessionStateRoot
    try {
        $script:DecisionBridgeConfig.SessionStateRoot = $root
        Set-Content -LiteralPath $events -Encoding utf8 -Value @(
            '{"type":"assistant.turn_start"}'
            '{"type":"assistant.turn_end"}'
            (New-SubagentEvent 'assistant.turn_start')
        )
        Test-That 'an agent''s open turn does not make the session working' {
            -not (Test-CopilotSessionWorking -SessionId $agentId)
        }
        Add-Content -LiteralPath $events -Encoding utf8 -Value '{"type":"assistant.turn_start"}'
        Test-That 'while the session opening one of its own still does' {
            Test-CopilotSessionWorking -SessionId $agentId
        }
    }
    finally {
        $script:DecisionBridgeConfig.SessionStateRoot = $savedRoot
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
finally {
    Remove-Item -LiteralPath $agentLog -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '--- waiting for a background command is not idle either ---'
<#
    A backgrounded shell leaves no subagent pair to count. The async call returns a
    shell id and completes at once, assistant.turn_end follows, and the command runs
    on outside anything the turn bookkeeping records - so a session sat idle on the
    dashboard for half an hour with a CI watch under it (#151).

    The markers are the tool's own, taken from a real transcript: a sync command that
    outruns its wait is backgrounded too and says so only in its result, which is how
    130 of this session's shells arrived against 46 started explicitly async.
#>
function New-ShellResult {
    param([string]$Content)
    ([ordered]@{ type = 'tool.execution_complete'
        data = [ordered]@{ toolCallId = 'toolu_s'; toolName = 'powershell'; result = [ordered]@{ content = $Content } } } |
        ConvertTo-Json -Depth 6 -Compress)
}
function New-ShellStarted { param([string]$Id) New-ShellResult "<command started in background with shellId: $Id>" }
function New-ShellStillRunning { param([string]$Id) New-ShellResult "<command with shellId: $Id is still running after 240 seconds. The command is still running.>" }
function New-ShellCollected { param([string]$Id) New-ShellResult "output here`n<shellId: $Id completed with exit code 0>" }
# Ordered deliberately. The reducer reads the event type from the first "type" in the
# line, exactly as Copilot writes it; an unordered hashtable put the nested
# shell_completed first and the event was read as that instead.
function New-ShellNotified {
    param([string]$Id)
    ([ordered]@{ type = 'system.notification'
        data = [ordered]@{ content = "Shell command (shellId: $Id) has completed successfully."
                  kind = [ordered]@{ type = 'shell_completed'; shellId = $Id; exitCode = 0 } } } |
        ConvertTo-Json -Depth 6 -Compress)
}

$activity = Get-ActivityFromEvents -Lines @((New-ShellStarted 'ci164')) -VerboseMode $false
Test-That 'a command put into the background is reported by its shell id' {
    (@($activity.ShellsStarted) -join ',') -eq 'ci164'
} (@($activity.ShellsStarted) -join ',')
# The case that matters most in practice, and the one a check on the requested mode
# would miss: the command asked to run synchronously and outran its wait.
$activity = Get-ActivityFromEvents -Lines @((New-ShellStillRunning 'fullsuite')) -VerboseMode $false
Test-That 'a sync command that outran its wait is backgrounded too' {
    (@($activity.ShellsStarted) -join ',') -eq 'fullsuite'
} (@($activity.ShellsStarted) -join ',')
$activity = Get-ActivityFromEvents -Lines @((New-ShellCollected 'ci164')) -VerboseMode $false
Test-That 'collecting one names the same shell as finished' {
    (@($activity.ShellsFinished) -join ',') -eq 'ci164'
} (@($activity.ShellsFinished) -join ',')
$activity = Get-ActivityFromEvents -Lines @((New-ShellNotified 'ci164')) -VerboseMode $false
Test-That 'and so does the notification that it ended' {
    (@($activity.ShellsFinished) -join ',') -eq 'ci164'
} (@($activity.ShellsFinished) -join ',')

# Text that merely mentions a marker is not a command. This file, the issue that asked
# for the feature and any command that prints its own output back all quote one, and
# unanchored matching turned every mention into a shell: a quoted start invented one
# that no completion could ever settle, and a quoted finish cleared a real one.
$activity = Get-ActivityFromEvents -Lines @(
    (New-ShellResult 'grep found: "<command started in background with shellId: phantom>" in the docs')) -VerboseMode $false
Test-That 'a command that merely prints a start marker starts nothing' {
    @($activity.ShellsStarted).Count -eq 0
} (@($activity.ShellsStarted) -join ',')
$activity = Get-ActivityFromEvents -Lines @(
    (New-ShellResult '| 3 | <shellId: ci164 completed with exit code 0> | sample |')) -VerboseMode $false
Test-That 'and one quoting a finish does not settle a command still running' {
    @($activity.ShellsFinished).Count -eq 0
} (@($activity.ShellsFinished) -join ',')

$shellLog = Join-Path ([IO.Path]::GetTempPath()) "copilot-shells-$([guid]::NewGuid().ToString('N')).jsonl"
$shellSessionId = 'cccccccc-1111-2222-3333-444444444444'
$shellEntry = [pscustomobject]@{ Offset = 0; Name = 'Copilot: build'; Machine = 'DESK'; Status = 'working'; Kind = 'copilot' }
$shellSession = [pscustomobject]@{ SessionId = $shellSessionId; Transcript = $shellLog; ProcessId = 1 }
function StepShells {
    param([string[]]$Lines)
    Add-Content -LiteralPath $shellLog -Value $Lines -Encoding utf8
    Update-DaemonSessionActivity -Id $shellSessionId -Entry $shellEntry -Session $shellSession -Headers @{} -VerboseOn $false
}
try {
    $script:StatusPublishes = @()
    StepShells -Lines @((New-ShellStarted 'ci164'), '{"type":"assistant.turn_end"}')
    Test-That 'a turn ending with a command still running does not read as idle' {
        $shellEntry.Status -eq 'shell'
    } "$($shellEntry.Status)"
    Test-That 'and that is what reaches the card' { $script:StatusPublishes[-1].Status -eq 'shell' }
    Test-That 'with how many, so the card need not say "some"' {
        $script:StatusPublishes[-1].Attributes['background_shells'] -eq 1
    }

    $script:StatusPublishes = @()
    StepShells -Lines @((New-ShellStillRunning 'fullsuite'))
    Test-That 'a second command joins the first rather than replacing it' {
        @($shellEntry.BackgroundShells).Count -eq 2
    } (@($shellEntry.BackgroundShells) -join ',')
    # The status string does not move from 'shell' when a second one starts, and the
    # publisher only runs when something moves - so the card went on saying one command
    # while two were running, until the session next changed for an unrelated reason.
    Test-That 'and the card is told, though the status itself did not change' {
        $script:StatusPublishes.Count -ge 1 -and
        $script:StatusPublishes[-1].Attributes['background_shells'] -eq 2
    } "publishes=$($script:StatusPublishes.Count)"
    # Reading one back while it is still going is not news; it must not be counted
    # twice, or a watched command would inflate the number on the card every poll.
    StepShells -Lines @((New-ShellStillRunning 'fullsuite'))
    Test-That 'and reading it again does not count it twice' {
        @($shellEntry.BackgroundShells).Count -eq 2
    } (@($shellEntry.BackgroundShells) -join ',')

    StepShells -Lines @((New-ShellNotified 'ci164'))
    Test-That 'one finishing leaves the session waiting on the other' { $shellEntry.Status -eq 'shell' }

    $script:StatusPublishes = @()
    StepShells -Lines @((New-ShellCollected 'fullsuite'))
    Test-That 'the last one finishing hands the session back to idle' {
        $shellEntry.Status -eq 'idle'
    } "$($shellEntry.Status)"
    Test-That 'and says so, rather than leaving the card waiting on nothing' {
        $script:StatusPublishes[-1].Status -eq 'idle'
    }

    StepShells -Lines @((New-ShellStarted 'rel137'), '{"type":"assistant.turn_end"}')
    Test-That 'and a restart finds it waiting, not idle' {
        (Get-DaemonStartupStatus -Session $shellSession -Entry $shellEntry) -eq 'shell'
    } (Get-DaemonStartupStatus -Session $shellSession -Entry $shellEntry)

    # Copilot's /resume and its session picker switch sessions inside the same CLI
    # process, which still owns whatever it backgrounded. Treating every resume as a
    # new process threw away live work and put the session back to reading idle.
    StepShells -Lines @('{"type":"session.resume"}')
    Test-That 'a resume inside the same process keeps the commands it still owns' {
        $shellEntry.Status -eq 'shell' -and @($shellEntry.BackgroundShells).Count -eq 1
    } "$($shellEntry.Status), outstanding=$(@($shellEntry.BackgroundShells).Count)"

    # A shell belongs to the process that started it. After this machine rebooted
    # mid-session, seven shells were still listed against a process that no longer
    # existed - and nothing in the transcript would ever have settled them, so the
    # session would have read as busy for the rest of its life.
    $restarted = [pscustomobject]@{ SessionId = $shellSessionId; Transcript = $shellLog; ProcessId = 4242 }
    Add-Content -LiteralPath $shellLog -Value @('{"type":"assistant.turn_end"}') -Encoding utf8
    Update-DaemonSessionActivity -Id $shellSessionId -Entry $shellEntry -Session $restarted -Headers @{} -VerboseOn $false
    Test-That 'but a new process owns none of the dead one''s commands' {
        $shellEntry.Status -eq 'idle' -and @($shellEntry.BackgroundShells).Count -eq 0
    } "$($shellEntry.Status), outstanding=$(@($shellEntry.BackgroundShells).Count)"

    Test-That 'a session carrying no commands at all is waiting on none' {
        (Get-DaemonBackgroundShellCount -Entry ([pscustomobject]@{ BackgroundShells = $null })) -eq 0
    }
    Test-That 'and neither is one from before the bridge tracked them' {
        (Get-DaemonBackgroundShellCount -Entry ([pscustomobject]@{ Status = 'idle' })) -eq 0
    }
}
finally {
    Remove-Item -LiteralPath $shellLog -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '--- a session whose transcript is not there yet ---'
# On 2026-10-07 a session between starting and writing its first event logged a read
# failure about eight times a second. The fast lane runs on every 100 ms tick of the
# Home Assistant wait and is supposed to skip a session whose transcript has not
# changed, but both of its guards missed a file that does not exist: FileInfo.Length
# yields $null rather than throwing, so the catch never fired, and $null never equalled
# the offset either. 40,667 of that day's 44,348 daemon log lines were this.
$script:TranscriptScratch = Join-Path ([IO.Path]::GetTempPath()) "fastlane-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $script:TranscriptScratch -Force | Out-Null
try {
    $missing = Join-Path $script:TranscriptScratch 'not-written-yet.jsonl'
    $present = Join-Path $script:TranscriptScratch 'written.jsonl'
    [IO.File]::WriteAllText($present, (New-Reply -Text 'hello') + "`n")

    Test-That 'FileInfo.Length answers nothing rather than throwing for a file that is not there' {
        $probe = $null
        $threw = $false
        try { $probe = [IO.FileInfo]::new($missing).Length } catch { $threw = $true }
        -not $threw -and $null -eq $probe
    }

    $script:FastStreamed = @()
    $script:FastLog = @()
    function Update-DaemonSessionActivity { param($Id, $Entry, $Session, $Headers, $VerboseOn) $script:FastStreamed += $Id }
    function Update-DaemonPendingLaunch { param($Headers) }
    function Invoke-DaemonHookSpool { }
    function Write-DaemonLog { param([string]$Message) $script:FastLog += $Message }
    $script:DaemonStopArmed = @{}
    $script:DaemonHookSpoolEvents = @()
    $script:DaemonHookSpoolAttempts = @{}
    $script:DaemonHookSpoolSweptAt = [DateTime]::UtcNow
    $script:DaemonVerbose = $false
    $script:DaemonDiscoverySnapshot = $null

    function Invoke-FastLane {
        param([string]$Transcript, [long]$Offset)
        $id = '77777777-0000-4000-8000-000000000077'
        $script:FastStreamed = @(); $script:FastLog = @()
        $entry = [pscustomobject]@{ Name = 'Copilot: fixture'; Machine = 'DESK'; Status = 'working'; Kind = 'copilot'; Offset = $Offset }
        $script:DaemonLive = @{ $id = [pscustomobject]@{ SessionId = $id; Kind = 'copilot'; Transcript = $Transcript; ProcessId = 1 } }
        Invoke-DaemonFastActivity -Headers @{ Authorization = '******' } -State @{ $id = $entry }
        $id
    }

    $id = Invoke-FastLane -Transcript $missing -Offset 0
    Test-That 'the fast lane skips a session whose transcript has not been written yet' { $script:FastStreamed -notcontains $id }
    Test-That 'so a tick costs no read failure at all, let alone one per tick' { $script:FastLog.Count -eq 0 }

    $id = Invoke-FastLane -Transcript $present -Offset ([IO.FileInfo]::new($present).Length)
    Test-That 'and still skips one whose transcript has not grown' { $script:FastStreamed -notcontains $id }

    $id = Invoke-FastLane -Transcript $present -Offset 0
    Test-That 'but streams one that has' { $script:FastStreamed -contains $id }

    Write-Host ''
    Write-Host '--- an unreadable transcript is described once, not once per pass ---'
    $script:DaemonTranscriptFailureReported = @{}
    $script:FastLog = @()
    [void](Read-TranscriptAppend -Path $missing -Offset 0)
    Test-That 'the first failure is reported' {
        @($script:FastLog | Where-Object { $_ -like "transcript read failed for '$missing'*" }).Count -eq 1
    }
    [void](Read-TranscriptAppend -Path $missing -Offset 0)
    [void](Read-TranscriptAppend -Path $missing -Offset 0)
    Test-That 'and repeating it says nothing further, because the first line said it all' {
        @($script:FastLog | Where-Object { $_ -like "transcript read failed for '$missing'*" }).Count -eq 1
    }
    Test-That 'a different transcript is still reported on its own' {
        $other = Join-Path $script:TranscriptScratch 'another-missing.jsonl'
        [void](Read-TranscriptAppend -Path $other -Offset 0)
        @($script:FastLog | Where-Object { $_ -like "transcript read failed for '$other'*" }).Count -eq 1
    }
    # Reading again is what makes a later failure news; without this a transcript that
    # recovered and then broke a second time would never be mentioned again.
    [void](Read-TranscriptAppend -Path $present -Offset 0)
    $script:FastLog = @()
    [IO.File]::Delete($present)
    [void](Read-TranscriptAppend -Path $present -Offset 0)
    Test-That 'a transcript that read again and then failed is reported afresh' {
        @($script:FastLog | Where-Object { $_ -like "transcript read failed for '$present'*" }).Count -eq 1
    }

    # Recovery has to count even when the read takes the truncation branch, which
    # returns from inside the try and so never reaches anything placed after the
    # finally. A session that was reset writes a shorter file than the saved offset,
    # which is exactly that branch - and leaving the path marked as reported there
    # swallowed the next genuine failure.
    $reset = Join-Path $script:TranscriptScratch 'reset.jsonl'
    $script:DaemonTranscriptFailureReported = @{}
    $script:FastLog = @()
    [void](Read-TranscriptAppend -Path $reset -Offset 0)
    Test-That 'a transcript that is not there yet is reported once before it appears' {
        @($script:FastLog | Where-Object { $_ -like "transcript read failed for '$reset'*" }).Count -eq 1
    }
    [IO.File]::WriteAllText($reset, "x`n")
    $short = Read-TranscriptAppend -Path $reset -Offset 9999
    Test-That 'and a file shorter than the saved offset rewinds rather than reading' { $short.Offset -eq 2 }
    $script:FastLog = @()
    [IO.File]::Delete($reset)
    [void](Read-TranscriptAppend -Path $reset -Offset 0)
    Test-That 'a recovery through that branch still clears the report, so the next failure is said' {
        @($script:FastLog | Where-Object { $_ -like "transcript read failed for '$reset'*" }).Count -eq 1
    }
}
finally {
    Remove-Item -LiteralPath $script:TranscriptScratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All Copilot activity checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
