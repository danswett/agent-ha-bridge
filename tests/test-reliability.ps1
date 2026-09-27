#Requires -Version 7.0
<#
.SYNOPSIS
    Reliability regression tests for the bridge.

.DESCRIPTION
    Covers the behaviours that keep a bridge fault from becoming a CLI fault:

      * the request budget, which stops a hook waiting on an unreachable Home
        Assistant. Before it existed the routers took 19-34 seconds with the host
        down, and a PreToolUse hook that slow delays the very prompt the bridge
        promises never to block.
      * StrictMode safety of that budget. The deadline must be initialised, because
        reading an unset variable throws and would take the retry layer - and the
        daemon with it - down.
      * the stale-registration prune, without which the daemon's per-reconcile cost
        grows for every Claude session ever started.

    Needs no Home Assistant.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\claude\hooks\claude-session.ps1')

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

Write-Host '--- the request budget under StrictMode ---'
Test-That 'no deadline set means no limit' {
    (Get-DecisionBridgeRemainingSeconds) -eq [double]::PositiveInfinity
}
Test-That 'a deadline is honoured' {
    Set-DecisionBridgeDeadline -Seconds 5
    $remaining = Get-DecisionBridgeRemainingSeconds
    $remaining -gt 4 -and $remaining -le 5
}
Test-That 'a deadline can be cleared' {
    Set-DecisionBridgeDeadline -Seconds 0
    (Get-DecisionBridgeRemainingSeconds) -eq [double]::PositiveInfinity
}

Write-Host '--- a spent budget stops the retry loop ---'
Set-DecisionBridgeDeadline -Seconds 1
Start-Sleep -Milliseconds 1200
$elapsed = Measure-Command {
    try {
        # An address that black-holes traffic: without the budget this would retry
        # for tens of seconds.
        Invoke-DecisionHttpRequest -Parameters @{
            Method = 'Get'; Uri = 'http://192.0.2.99:8123/api/'; TimeoutSec = 30
        }
    }
    catch { }
}
Test-That 'a spent budget fails immediately' { $elapsed.TotalSeconds -lt 2 } "$([math]::Round($elapsed.TotalSeconds,2))s"

Write-Host '--- a live budget is not exceeded ---'
Set-DecisionBridgeDeadline -Seconds 3
$elapsed = Measure-Command {
    try {
        Invoke-DecisionHttpRequest -Parameters @{
            Method = 'Get'; Uri = 'http://192.0.2.99:8123/api/'; TimeoutSec = 30
        }
    }
    catch { }
}
Test-That 'a 3s budget is respected despite a 30s request timeout' {
    $elapsed.TotalSeconds -lt 6
} "$([math]::Round($elapsed.TotalSeconds,2))s"
Set-DecisionBridgeDeadline -Seconds 0

Write-Host '--- reachability probe ---'
Test-That 'an unreachable host is detected quickly' {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $result = Test-HomeAssistantReachable -TimeoutSec 2
    $sw.Stop()
    (-not $result) -or $sw.Elapsed.TotalSeconds -lt 4
}

Write-Host '--- stale Claude registrations are pruned ---'
$root = Get-ClaudeStateRoot
$seeded = @()
try {
    foreach ($i in 1..25) {
        $id = [guid]::NewGuid().ToString()
        $seeded += $id
        [pscustomobject]@{
            SessionId = $id; ProcessId = (900000 + $i); TranscriptPath = 'C:\nope.jsonl'
            WorkingDirectory = 'C:\x'; Updated = [DateTimeOffset]::Now.AddDays(-3).ToString('o')
        } | ConvertTo-Json | Set-Content (Join-Path $root "$id.json") -Encoding UTF8
    }
    $before = @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File).Count
    # Only the entries seeded here: the registry is the real one, and a Claude session
    # running on this machine - including the one running these tests - is live in it.
    $live = @(Get-ClaudeSessionRegistrations | Where-Object { $seeded -contains $_.SessionId })
    $after = @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File).Count

    Test-That 'dead registrations are not reported as live' { $live.Count -eq 0 } "$($live.Count)"
    Test-That 'dead registrations are deleted' { $after -lt $before } "$before -> $after"

    # A fresh registration with no resolvable process must survive: the hook may have
    # written it moments ago while the parent walk failed.
    $fresh = [guid]::NewGuid().ToString()
    $seeded += $fresh
    [pscustomobject]@{
        SessionId = $fresh; ProcessId = 0; TranscriptPath = 'C:\nope.jsonl'
        WorkingDirectory = 'C:\x'; Updated = [DateTimeOffset]::Now.ToString('o')
    } | ConvertTo-Json | Set-Content (Join-Path $root "$fresh.json") -Encoding UTF8
    [void](Get-ClaudeSessionRegistrations)
    Test-That 'a fresh registration is not pruned' {
        Test-Path -LiteralPath (Join-Path $root "$fresh.json")
    }

    # A session whose process is still running is live however long it has been quiet.
    # A registration last refreshed hours ago - a session waiting out a usage limit -
    # used to be retired while it was still open. A copy of ping.exe named claude.exe
    # stands in for the running session, since only the process name is checked.
    $fakeDir = Join-Path ([IO.Path]::GetTempPath()) "fake-claude-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $fakeDir -Force | Out-Null
    # macOS: a copy of sleep, named claude, plays the same part.
    if ($script:BridgeIsWindows) {
        $fakeExe = Join-Path $fakeDir 'claude.exe'
        Copy-Item (Join-Path $env:WINDIR 'System32\PING.EXE') $fakeExe
        $fake = Start-Process -FilePath $fakeExe -ArgumentList '-n 30 127.0.0.1' -WindowStyle Hidden -PassThru
    }
    else {
        $fakeExe = Join-Path $fakeDir 'claude'
        Copy-Item '/bin/sleep' $fakeExe
        $fake = Start-Process -FilePath $fakeExe -ArgumentList '30' -PassThru
    }
    try {
        $idle = [guid]::NewGuid().ToString()
        $seeded += $idle
        [pscustomobject]@{
            SessionId = $idle; ProcessId = $fake.Id; TranscriptPath = 'C:\nope.jsonl'
            WorkingDirectory = 'C:\x'; Updated = [DateTimeOffset]::Now.AddDays(-3).ToString('o')
        } | ConvertTo-Json | Set-Content (Join-Path $root "$idle.json") -Encoding UTF8

        $found = @(Get-ClaudeSessionRegistrations | Where-Object { $_.SessionId -eq $idle })
        Test-That 'an idle session whose process is running stays live' { $found.Count -eq 1 -and $found[0].IsLive }
        Test-That 'and its registration is kept' { Test-Path -LiteralPath (Join-Path $root "$idle.json") }
    }
    finally {
        Stop-Process -Id $fake.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300
        Remove-Item -LiteralPath $fakeDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
finally {
    foreach ($id in $seeded) { Remove-Item (Join-Path $root "$id.json") -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) test(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All tests passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
