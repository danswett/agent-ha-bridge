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
Test-That 'and the trail holds both tools and the reply' { (@($activity.History) -join '|') -eq 'the answer|Running: grep|Running: edit' -or @($activity.History).Count -eq 3 }

$activity = Get-ActivityFromEvents -Lines @((New-Thought 'thinking'), (New-Reply 'and then speaking')) -VerboseMode $true
Test-That 'a reply after a thought wins' { $activity.Latest -eq 'and then speaking' -and -not $activity.LatestIsThinking }

Write-Host '--- nothing to say ---'
$activity = Get-ActivityFromEvents -Lines @((New-Tool 'grep')) -VerboseMode $true
Test-That 'a batch of only tool calls has no newest line' { [string]::IsNullOrEmpty([string]$activity.Latest) }
Test-That 'and is not marked as thinking' { -not $activity.LatestIsThinking }
$activity = Get-ActivityFromEvents -Lines @('not json at all', '{"type":"assistant.message"}') -VerboseMode $true
Test-That 'a malformed line does not throw' { [string]::IsNullOrEmpty([string]$activity.Latest) }

Write-Host '--- what reaches the card ---'
# Everything that would reach Home Assistant is stood in for.
$script:Published = $null
function Set-CopilotMqttActivity { param($SessionId, $Summary, $Detail, $Headers) $script:Published = $Detail }
function Set-CopilotMqttStatus { param($SessionId, $Status, $Headers, $Attributes) }
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
}
finally {
    Remove-Item -LiteralPath $transcript -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:DaemonConfig.LogFile -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All Copilot activity checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
