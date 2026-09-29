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
$script:RealTail = ${function:Get-CopilotTranscriptTailLines}
$script:Reads = 0
function Get-CopilotTranscriptTailLines {
    param([Parameter(Mandatory)][string]$Path, [int]$MaxBytes = 4194304)
    $script:Reads++
    & $script:RealTail -Path $Path -MaxBytes $MaxBytes
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
