#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for measuring the native hook's fallbacks (Get-BridgeHookStats,
    Format-BridgeHookStats in hooks/bridge-native-hook.ps1).

.DESCRIPTION
    Builds the log the native hook writes - one JSON line per run - by hand, including
    a rotated .1 file, runs outside the window and lines that are not JSON, and checks
    the counts, the fallback rate, the reasons and the waits that come out.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\bridge-platform.ps1')
. (Join-Path $PSScriptRoot '..\hooks\bridge-native-hook.ps1')

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

$root = Join-Path ([IO.Path]::GetTempPath()) "hook-stats-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $root | Out-Null
$logPath = Join-Path $root 'agent-bridge-hook.log'
$clock = [DateTimeOffset]::Parse('2026-09-28T12:00:00Z')
function New-Run { param([double]$HoursAgo, [string]$Agent, [string]$Hook, [string]$Path, [string]$Reason = '', [int]$Ms)
    $run = [ordered]@{ at = $clock.AddHours(-$HoursAgo).ToString('o'); agent = $Agent; hook = $Hook; path = $Path; ms = $Ms }
    if ($Reason) { $run.reason = $Reason }
    $run | ConvertTo-Json -Compress
}

try {
    Write-Host '--- nothing logged yet ---'
    $empty = Get-BridgeHookStats -LogPath $logPath -Now $clock
    Test-That 'no log counts as no runs' { $empty.Total -eq 0 -and $empty.FallbackRate -eq 0 }
    Test-That 'and says so' { (Format-BridgeHookStats -Stats $empty) -eq 'no runs in the last 24 h' }

    Write-Host '--- a day of runs ---'
    # The rotated log holds the older half.
    Set-Content -LiteralPath "$logPath.1" -Value @(
        New-Run 30 claude stop spool '' 20            # outside the 24 h window
        New-Run 20 claude stop spool '' 30
        New-Run 19 codex hook fallback 'daemon heartbeat 300s old' 400
    )
    Set-Content -LiteralPath $logPath -Value @(
        New-Run 10 codex hook spool '' 35
        New-Run 9 codex hook fallback 'daemon heartbeat 75s old' 420
        New-Run 8 claude register fallback 'no daemon heartbeat' 390
        New-Run 7 copilot ask_user reply 'unusable event' 15
        'not json at all'
        New-Run 6 claude stop fallback 'spool failed: access denied' 410
        New-Run 5 claude stop spool '' 40
        New-Run 4 codex hook spool '' 38
        New-Run -1 codex hook spool '' 50              # in the future: a clock skew, ignored
    )
    $stats = Get-BridgeHookStats -LogPath $logPath -Now $clock -Hours 24
    Test-That 'runs in the window are counted, from both files' { $stats.Total -eq 9 } "total $($stats.Total)"
    Test-That 'by path' { $stats.Spooled -eq 4 -and $stats.Fallback -eq 4 -and $stats.ReplyOnly -eq 1 }
    Test-That 'the fallback rate is every run not spooled' { $stats.NotSpooled -eq 5 -and $stats.FallbackRate -eq [Math]::Round(5 / 9, 4) }
    Test-That 'reasons differing only by a number are counted together' { $stats.ByReason['daemon heartbeat Ns old'] -eq 2 }
    Test-That 'a failed spool is one reason, whatever its error' { $stats.ByReason['spool failed'] -eq 1 }
    Test-That 'the commonest reason comes first' { @($stats.ByReason.Keys)[0] -eq 'daemon heartbeat Ns old' }
    Test-That 'each hook has its own count' { $stats.ByHook['codex/hook'].Total -eq 4 -and $stats.ByHook['codex/hook'].NotSpooled -eq 2 }
    Test-That 'typical waits, overall and for fallbacks' { $stats.SpoolMedianMs -eq 38 -and $stats.FallbackMedianMs -eq 410 -and $stats.P95Ms -eq 420 }

    $line = Format-BridgeHookStats -Stats $stats
    Test-That 'the status line gives the rate and the reasons' {
        $line -match '^9 runs in the last 24 h, 5 not spooled \(55\.6%\): daemon heartbeat Ns old x2' -and $line -match 'fallbacks 410 ms'
    } $line

    $recent = Get-BridgeHookStats -LogPath $logPath -Now $clock -Hours 6
    Test-That 'a shorter window counts only its runs' { $recent.Total -eq 3 -and $recent.NotSpooled -eq 1 } "total $($recent.Total)"
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All hook stats checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
