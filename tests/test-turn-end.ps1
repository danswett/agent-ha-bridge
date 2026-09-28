#Requires -Version 7.0
<#
.SYNOPSIS
    The end of a Claude turn stays idle: Update-DaemonSessionActivity's stale-tail rule.

.DESCRIPTION
    Replays what happened on 2026-09-27 at 23:50: the Stop hook, handed to the daemon by
    the native hook, recorded the session idle a few milliseconds before Claude wrote
    that turn's final message to its transcript (followed by its stop_hook_summary and
    turn_duration lines). The final message then looked like new work, and the card
    flipped straight back to "working" for as long as the session sat idle.

    Only a new user entry - a prompt, or a tool result - may start work again once a
    hook has ended the turn. The real transcript reader and the real daemon function
    run here; only Home Assistant is replaced, by a recorder.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
. (Join-Path $PSScriptRoot '..\claude\hooks\claude-transcript.ps1')
$script:ClaudeAdapterLoaded = $true
$script:DaemonConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-turn-end-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

$script:Published = @()
function Set-CopilotMqttStatus { param([string]$SessionId, [string]$Status, [hashtable]$Headers, [hashtable]$Attributes) $script:Published += $Status }
function Set-CopilotMqttActivity { param([string]$SessionId, [string]$Summary, $Detail, [hashtable]$Headers) }

$transcript = Join-Path ([IO.Path]::GetTempPath()) "turn-end-$([guid]::NewGuid().ToString('N').Substring(0, 8)).jsonl"
function Add-Line { param([string]$At, [string]$Json) Add-Content -LiteralPath $transcript -Value ($Json -replace '__AT__', $At) }

# The hook recorded the end of the turn at 06:50:01.340 - 9 ms before the final message.
$stopAt = '2026-09-28T06:50:01.340Z'
$session = [pscustomobject]@{ SessionId = 's'; Transcript = $transcript; ProcessId = 1; HookStatus = 'idle'; HookStatusAt = $stopAt }
$entry = [pscustomobject]@{ Name = 'Claude: x'; Machine = 'M'; Kind = 'claude'; Status = 'working'; Offset = 0L }

try {
    Set-Content -LiteralPath $transcript -Value '' -NoNewline
    Write-Host '--- the end of a turn ---'
    Add-Line '2026-09-28T06:50:01.335Z' '{"type":"assistant","timestamp":"__AT__","message":{"content":[{"type":"thinking","thinking":"wrapping up"}]}}'
    Add-Line '2026-09-28T06:50:01.349Z' '{"type":"assistant","timestamp":"__AT__","message":{"content":[{"type":"text","text":"Yes, it is."}]}}'
    Add-Line '2026-09-28T06:50:01.462Z' '{"type":"system","subtype":"stop_hook_summary","timestamp":"__AT__"}'
    Add-Line '2026-09-28T06:50:01.473Z' '{"type":"system","subtype":"turn_duration","timestamp":"__AT__"}'

    Update-DaemonSessionActivity -Id 's' -Entry $entry -Session $session -Headers @{} -VerboseOn $true
    Test-That 'the Stop is adopted: the session is idle' { $entry.Status -eq 'idle' }
    Test-That 'and the final message, written just after it, does not make it working again' {
        $script:Published -notcontains 'working'
    } ($script:Published -join ',')
    Test-That 'the final message still reaches the card' { $entry.LastMessage -eq 'Yes, it is.' }

    Write-Host '--- work resuming ---'
    $script:Published = @()
    Add-Line '2026-09-28T06:51:12.900Z' '{"type":"user","timestamp":"__AT__","message":{"content":"next question"}}'
    Update-DaemonSessionActivity -Id 's' -Entry $entry -Session $session -Headers @{} -VerboseOn $true
    Test-That 'a new prompt makes it working' { $entry.Status -eq 'working' -and ($script:Published -join ',') -eq 'working' } ($script:Published -join ',')

    Write-Host '--- a permission prompt answered in the terminal ---'
    $session.HookStatus = 'waiting'; $session.HookStatusAt = '2026-09-28T06:52:00.000Z'
    $script:Published = @()
    Add-Line '2026-09-28T06:51:59.990Z' '{"type":"assistant","timestamp":"__AT__","message":{"content":[{"type":"tool_use","name":"Bash","id":"t1","input":{}}]}}'
    Update-DaemonSessionActivity -Id 's' -Entry $entry -Session $session -Headers @{} -VerboseOn $true
    Test-That 'waiting on the prompt, the tool call that asked stays waiting' { $entry.Status -eq 'waiting' -and $script:Published -notcontains 'working' } ($script:Published -join ',')
    $script:Published = @()
    Add-Line '2026-09-28T06:52:05.000Z' '{"type":"user","timestamp":"__AT__","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}'
    Update-DaemonSessionActivity -Id 's' -Entry $entry -Session $session -Headers @{} -VerboseOn $true
    Test-That 'once approved, the tool result alone makes it working' { $entry.Status -eq 'working' -and ($script:Published -join ',') -eq 'working' } ($script:Published -join ',')
    # What follows arrives in a later read, with no user entry of its own.
    $script:Published = @()
    Add-Line '2026-09-28T06:52:06.000Z' '{"type":"assistant","timestamp":"__AT__","message":{"content":[{"type":"text","text":"done"}]}}'
    Update-DaemonSessionActivity -Id 's' -Entry $entry -Session $session -Headers @{} -VerboseOn $true
    Test-That 'and it stays working as the turn carries on' { $entry.Status -eq 'working' -and $script:Published -notcontains 'waiting' }

    Write-Host '--- the reader ---'
    $read = Get-ClaudeActivityFromTranscript -Lines @(
        '{"type":"user","timestamp":"2026-09-28T06:00:00Z","message":{"content":"q"}}'
        '{"type":"assistant","timestamp":"2026-09-28T06:00:05Z","message":{"content":[{"type":"text","text":"a"}]}}'
    )
    Test-That 'LastUserAt is the newest user entry, not the newest of any' {
        $read.LastUserAt -eq [DateTimeOffset]'2026-09-28T06:00:00Z' -and $read.LastActivityAt -eq [DateTimeOffset]'2026-09-28T06:00:05Z'
    }
    Test-That 'a batch with no user entry has none' {
        $null -eq (Get-ClaudeActivityFromTranscript -Lines @('{"type":"assistant","timestamp":"2026-09-28T06:00:05Z","message":{"content":[{"type":"text","text":"a"}]}}')).LastUserAt
    }
}
finally {
    Remove-Item -LiteralPath $transcript, $script:DaemonConfig.LogFile -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All turn-end checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
