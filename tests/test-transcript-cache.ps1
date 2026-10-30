#Requires -Version 7.0
<#
.SYNOPSIS
    An unchanged transcript is not read twice, and a changed one always is.

.DESCRIPTION
    Working out whether a question is still waiting means parsing the tail of the
    session's transcript, which costs 93 ms. The daemon does it for every armed
    question on every pass, and a question stays armed for as long as it takes someone
    to look at their phone - so the same four megabytes are parsed to the same answer
    every fifteen seconds, for minutes.

    A transcript is append-only, so an unchanged length is proof the answer cannot have
    changed. The saving is easy; the danger is entirely in what it costs to get wrong.
    A stale answer here does not slow anything down, it says a live question has been
    answered - which tears the card off the phone mid-question - or that an answered one
    is still waiting, which re-injects an answer into a session that has moved on.

    So these assert both halves against the real reader and a real file on disk: that a
    second look at an untouched transcript does not read it, proved by counting the
    reads rather than by timing them, and that every way the file can change is noticed
    - appended to, answered, replaced by one of exactly the same length, and gone.

    And that a question is found wherever it is (#259). The reader used to look at the
    last four megabytes only, and a question answered in a burst bigger than that was
    never seen to be answered: its card said "waiting for you" until it was cleared by
    hand. So every byte is read once, and a grown transcript is read from where the
    last read got to - never from the start again.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
$script:DecisionBridgeConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-transcript-cache-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $__ok = $false
    try { $__ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($__ok) { Write-Host "  PASS  $Name" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

# Counting the reads, not timing them. A timing assertion would pass on a machine that
# happened to be fast and fail on one that was busy, and neither outcome would say
# whether the file was opened.
$script:RealScan = ${function:Update-CopilotAskUserScan}
$script:Reads = 0
$script:ReadFrom = @()
function Update-CopilotAskUserScan {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Scan, [Parameter(Mandatory)][long]$Through)
    $script:Reads++
    $script:ReadFrom += [long]$Scan.Through
    & $script:RealScan -Path $Path -Scan $Scan -Through $Through
}

$dir = Join-Path ([IO.Path]::GetTempPath()) "transcript-cache-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$transcript = Join-Path $dir 'events.jsonl'

function Add-Event {
    param([Parameter(Mandatory)][string]$Line)
    Add-Content -LiteralPath $transcript -Value $Line -Encoding UTF8
    # Windows file times are coarse enough that two writes in the same millisecond
    # share one; the length still differs, which is the half that always changes on an
    # append.
    Start-Sleep -Milliseconds 20
}

try {
    $start = '{"type":"tool.execution_start","timestamp":"2026-09-28T21:00:00Z","data":{"toolName":"ask_user","toolCallId":"call-1"}}'
    $done = '{"type":"tool.execution_complete","timestamp":"2026-09-28T21:01:00Z","data":{"toolCallId":"call-1","result":{"content":"User responded: release=cut_now"}}}'

    Write-Host "`n--- a question that is still waiting ---"
    Add-Event $start

    $script:Reads = 0
    $first = Get-CopilotAskUserState -TranscriptPath $transcript
    Test-That 'the question is found' { $first.Started -and $first.ToolCallId -eq 'call-1' }
    Test-That 'and reads as still waiting' { $first.Pending }
    Test-That 'which took a read' { $script:Reads -eq 1 }

    $script:Reads = 0
    $again = Get-CopilotAskUserState -TranscriptPath $transcript
    Test-That 'asking again gives the same answer' { $again.Pending -and $again.ToolCallId -eq 'call-1' }
    Test-That 'without reading the transcript again' { $script:Reads -eq 0 } "read $($script:Reads) time(s)"

    # The answer handed back must not be the stored one, or a caller that writes to it
    # rewrites what every later caller is told.
    $again.Pending = $false
    $third = Get-CopilotAskUserState -TranscriptPath $transcript
    Test-That 'and a caller editing its answer does not change the next one' { $third.Pending }

    Write-Host "`n--- the question is answered ---"
    Add-Event $done
    $script:Reads = 0
    $after = Get-CopilotAskUserState -TranscriptPath $transcript
    Test-That 'the transcript is read again once it grows' { $script:Reads -eq 1 }
    Test-That 'and the question now reads as answered' { -not $after.Pending }
    Test-That 'with what the CLI recorded' { $after.ResultContent -eq 'User responded: release=cut_now' }

    $script:Reads = 0
    Test-That 'the answered state is remembered too' {
        $r = Get-CopilotAskUserState -TranscriptPath $transcript
        (-not $r.Pending) -and $script:Reads -eq 0
    }

    Write-Host "`n--- a transcript that changes without growing ---"
    # The length alone would call this unchanged. It is the case the write time is
    # carried for, and the one where a wrong answer is worst: a different session's
    # question, reported under this one's name.
    $sameLength = Get-Content -LiteralPath $transcript -Raw -Encoding UTF8
    $swapped = $sameLength.Replace('call-1', 'call-2')
    Test-That 'the replacement really is the same length' { $swapped.Length -eq $sameLength.Length }
    Start-Sleep -Milliseconds 20
    [IO.File]::WriteAllText($transcript, $swapped)
    $script:Reads = 0
    $rewritten = Get-CopilotAskUserState -TranscriptPath $transcript
    Test-That 'a rewritten transcript is read again' { $script:Reads -eq 1 }
    Test-That 'and the new question is the one reported' { $rewritten.ToolCallId -eq 'call-2' }

    Write-Host "`n--- a transcript with no question in it ---"
    # This answer costs the same full parse to reach as any other, so it is remembered
    # too - a session that has never asked anything is the common case.
    $empty = Join-Path $dir 'quiet.jsonl'
    Set-Content -LiteralPath $empty -Value '{"type":"tool.execution_start","timestamp":"2026-09-28T21:00:00Z","data":{"toolName":"view","toolCallId":"v1"}}' -Encoding UTF8
    $script:Reads = 0
    Test-That 'no question is found' { -not (Get-CopilotAskUserState -TranscriptPath $empty).Started }
    Test-That 'which took a read' { $script:Reads -eq 1 }
    $script:Reads = 0
    Test-That 'and is not looked for again' {
        (-not (Get-CopilotAskUserState -TranscriptPath $empty).Started) -and $script:Reads -eq 0
    }

    Write-Host "`n--- a transcript that is not there ---"
    $script:Reads = 0
    $missing = Get-CopilotAskUserState -TranscriptPath (Join-Path $dir 'gone.jsonl')
    Test-That 'reads as no question, not as an error' { -not $missing.Started }

    Write-Host "`n--- a question answered in a burst bigger than any window ---"
    # The shape of 2026-10-30: background agents wrote 5.5 MB beside a waiting
    # question, and the answer arrived followed by 7.1 MB more. Both the start and its
    # completion were behind the old four-megabyte window by then, so the question read
    # as never asked and the card was never cleared.
    $burst = Join-Path $dir 'burst.jsonl'
    $filler = '{"type":"assistant.message","data":{"content":"' + ('x' * 10000) + '","agentId":"bg"}}'
    function Add-Burst {
        param([Parameter(Mandatory)][string]$Path, [string[]]$Before = @(), [int]$Fillers = 0, [string[]]$After = @())
        $writer = [IO.StreamWriter]::new($Path, $true, [Text.UTF8Encoding]::new($false))
        try {
            foreach ($line in $Before) { $writer.Write($line + "`n") }
            for ($i = 0; $i -lt $Fillers; $i++) { $writer.Write($filler + "`n") }
            foreach ($line in $After) { $writer.Write($line + "`n") }
        }
        finally { $writer.Dispose() }
        Start-Sleep -Milliseconds 20
    }
    $askStart = '{"type":"tool.execution_start","timestamp":"2026-10-30T07:58:41Z","data":{"toolName":"ask_user","toolCallId":"toolu_burst"}}'
    $askDone = '{"type":"tool.execution_complete","timestamp":"2026-10-30T16:32:09Z","data":{"toolCallId":"toolu_burst","success":true,"result":{"content":"User responded: fix-both"}}}'
    Add-Burst -Path $burst -Before @('{"type":"session.start","data":{"sessionId":"burst"}}', $askStart) -Fillers 550
    $script:Reads = 0; $script:ReadFrom = @()
    $waiting = Get-CopilotAskUserState -TranscriptPath $burst
    Test-That 'a question with 5.5 MB written after it is still found' { $waiting.Started -and $waiting.ToolCallId -eq 'toolu_burst' } "started=$($waiting.Started)"
    Test-That 'and still reads as waiting' { $waiting.Pending }
    $firstEnd = (Get-Item -LiteralPath $burst).Length

    Add-Burst -Path $burst -Before @($askDone) -Fillers 710
    $script:ReadFrom = @()
    $answered = Get-CopilotAskUserState -TranscriptPath $burst
    Test-That 'its answer is found under a 7.1 MB burst' { $answered.Started -and -not $answered.Pending } "started=$($answered.Started) pending=$($answered.Pending)"
    Test-That 'with what the CLI recorded' { $answered.ResultContent -eq 'User responded: fix-both' } $answered.ResultContent
    # The whole file is read once. A pass after that reads what is new, however much
    # of it there is - a 268 MB transcript reread every pass would stall the daemon.
    Test-That 'and only the new bytes were read to find it' { @($script:ReadFrom).Count -eq 1 -and $script:ReadFrom[0] -eq $firstEnd } "from=$($script:ReadFrom -join ',') expected=$firstEnd"

    Write-Host "`n--- a question its prompt went away under ---"
    # Nothing will ever complete these, and a card left armed on one offers an answer
    # to a prompt that is no longer there.
    foreach ($ending in @(
            @{ Name = 'an abort'; Line = '{"type":"abort","data":{"reason":"user"}}' },
            @{ Name = 'the session shutting down'; Line = '{"type":"session.shutdown","data":{}}' })) {
        $ended = Join-Path $dir "ended-$([guid]::NewGuid().ToString('N').Substring(0, 6)).jsonl"
        Add-Burst -Path $ended -Before @($askStart)
        Test-That "a question is waiting before $($ending.Name)" { (Get-CopilotAskUserState -TranscriptPath $ended).Pending }
        Add-Burst -Path $ended -Before @($ending.Line)
        Test-That "and $($ending.Name) ends it" { -not (Get-CopilotAskUserState -TranscriptPath $ended).Pending }
    }
    $sub = Join-Path $dir 'subagent-abort.jsonl'
    Add-Burst -Path $sub -Before @($askStart, '{"type":"abort","agentId":"bg","data":{}}')
    Test-That 'but a subagent aborting leaves the session''s question waiting' { (Get-CopilotAskUserState -TranscriptPath $sub).Pending }

    Write-Host "`n--- a transcript replaced by a longer one ---"
    # Growth alone would continue the old scan into a different session's file.
    $grown = Join-Path $dir 'grown.jsonl'
    Add-Burst -Path $grown -Before @('{"type":"session.start","data":{"sessionId":"one"}}', $askStart)
    Test-That 'the first session''s question is found' { (Get-CopilotAskUserState -TranscriptPath $grown).ToolCallId -eq 'toolu_burst' }
    [IO.File]::WriteAllText($grown, ('{"type":"session.start","data":{"sessionId":"two"}}' + "`n" +
            $start.Replace('call-1', 'call-9') + "`n" + ('{"type":"assistant.turn_end"}' + "`n") * 20))
    $other = Get-CopilotAskUserState -TranscriptPath $grown
    Test-That 'the replacement''s own question is the one reported' { $other.ToolCallId -eq 'call-9' -and $other.Pending } $other.ToolCallId

    Write-Host "`n--- a daemon that restarts while a question waits ---"
    # The question remembers where it started, on its marker, so a new daemon reads on
    # from there rather than through the whole session again. Read through the
    # daemon's own reader, so what it writes is what it later reads back.
    . (Join-Path $PSScriptRoot '..\hooks\daemon-decisions.ps1')
    $sid = 'aaaaaaaa-2590-4000-8000-000000000259'
    $restart = Join-Path $dir 'restart.jsonl'
    Add-Burst -Path $restart -Before @('{"type":"session.start","data":{"sessionId":"restart"}}') -Fillers 300 -After @($askStart)
    Add-Burst -Path $restart -Fillers 100
    Write-CopilotDecisionMarker -SessionId $sid -DecisionId 'd-259' -Mode freeform
    $live = [pscustomobject]@{ SessionId = $sid; Transcript = $restart }
    $markerBytes = [IO.File]::ReadAllText((Get-CopilotDecisionMarkerPath -SessionId $sid))
    $script:CopilotAskUserStateCache.Clear()
    $seen = Get-DaemonCopilotAskUserState -Session $live -Marker (Get-CopilotDecisionMarker -SessionId $sid)
    $remembered = Get-CopilotDecisionAskHint -SessionId $sid -DecisionId 'd-259'
    Test-That 'a waiting question is found' { $seen.Pending -and $seen.ToolCallId -eq 'toolu_burst' }
    Test-That 'and which question it is is remembered for that decision' { $null -ne $remembered -and $remembered.ToolCallId -eq 'toolu_burst' }
    Test-That 'with where its start line begins: past the session''s start, not past the question''s' {
        $remembered.From -gt 0 -and $remembered.From -eq [IO.File]::ReadAllText($restart).IndexOf($askStart)
    } "from=$(if ($remembered) { $remembered.From })"
    # Rewriting the marker to remember it could overwrite the next question, armed by
    # the hook between the read and the write.
    Test-That 'without the marker itself being rewritten' {
        [IO.File]::ReadAllText((Get-CopilotDecisionMarkerPath -SessionId $sid)) -ceq $markerBytes
    }

    # The restart: nothing read is remembered in memory any more.
    $script:CopilotAskUserStateCache.Clear()
    Add-Burst -Path $restart -Before @($askDone) -Fillers 50
    $script:ReadFrom = @()
    $after = Get-DaemonCopilotAskUserState -Session $live -Marker (Get-CopilotDecisionMarker -SessionId $sid)
    Test-That 'the new daemon pairs the answer with it' { $after.Started -and -not $after.Pending -and $after.ToolCallId -eq 'toolu_burst' }
    Test-That 'reading from where the question started, not the whole session' {
        @($script:ReadFrom).Count -eq 1 -and $script:ReadFrom[0] -eq $remembered.From
    } "from=$($script:ReadFrom -join ',')"

    # A place to start that is wrong - past the question - costs a second read, never
    # the answer.
    $script:CopilotAskUserStateCache.Clear()
    $script:ReadFrom = @()
    $wrong = Get-CopilotAskUserState -TranscriptPath $restart -From ((Get-Item -LiteralPath $restart).Length - 100)
    Test-That 'a wrong place to start still finds the question' { $wrong.Started -and $wrong.ToolCallId -eq 'toolu_burst' -and -not $wrong.Pending }
    Test-That 'by reading the transcript from its start after all' { $script:ReadFrom[-1] -eq 0 } ($script:ReadFrom -join ',')

    Write-Host "`n--- the cache cannot grow without bound ---"
    # The daemon outlives every session it watches.
    $script:CopilotAskUserStateCache.Clear()
    1..70 | ForEach-Object {
        $p = Join-Path $dir "many-$_.jsonl"
        Set-Content -LiteralPath $p -Value $start -Encoding UTF8
        $null = Get-CopilotAskUserState -TranscriptPath $p
    }
    Test-That 'it stays bounded across many sessions' { $script:CopilotAskUserStateCache.Count -le 64 } `
        "held $($script:CopilotAskUserStateCache.Count)"
    Test-That 'and still answers correctly afterwards' {
        (Get-CopilotAskUserState -TranscriptPath (Join-Path $dir 'many-70.jsonl')).Pending
    }
}
finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0) {
    Write-Host "`n$($script:Failures) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall passed" -ForegroundColor Green
