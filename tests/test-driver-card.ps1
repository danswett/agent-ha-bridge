#Requires -Version 7.0
<#
.SYNOPSIS
    The driver reaches the card, on every path that publishes one.

.DESCRIPTION
    1.14.0 added the purple edge for a session an agent is driving, and 1.14.1 fixed
    the two reasons nobody could see it. Both of those were found by hand, because the
    tests only ever covered the two ends of the feature: Get-BridgeDriverFromState
    (a user id maps to 'agent' or 'human', in test-dashboard.ps1) and the Submit press
    recording it (test-stop-session.ps1). Nothing asserted that the value survives as
    far as the card, so a publish path that simply never set it was invisible.

    Codex was exactly that path. It builds its own detail rather than going through the
    shared one, so every Codex card was published with no driver at all and the browser,
    which reads a missing driver as yours, drew it blue however it had been driven - the
    one agent whose glow could never work. The restart prime had the same gap: the
    driver is persisted with the entry, but the card rebuilt from it dropped the value,
    so a restart quietly handed a session an agent was still driving back to you.

    These run the real daemon functions against a real Codex rollout; only Home
    Assistant is replaced, by a recorder.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
. (Join-Path $PSScriptRoot '..\codex\hooks\codex-transcript.ps1')
$script:CodexAdapterLoaded = $true
$script:DaemonConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-driver-card-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $__ok = $false
    try { $__ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($__ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

$script:LastDetail = $null
function Set-CopilotMqttActivity {
    param([string]$SessionId, [string]$Summary, $Detail, [hashtable]$Headers)
    $script:LastDetail = $Detail
}

$rollout = Join-Path ([IO.Path]::GetTempPath()) "driver-card-$([guid]::NewGuid().ToString('N').Substring(0, 8)).jsonl"
function Add-Roll { param([string]$Json) Add-Content -LiteralPath $rollout -Value $Json }
$assistantSays = '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"__TEXT__"}]}}'
$turnStarts = '{"type":"event_msg","payload":{"type":"task_started"}}'

try {
    Set-Content -LiteralPath $rollout -Value '' -NoNewline
    $session = [pscustomobject]@{ SessionId = 'cx'; Transcript = $rollout; Activity = 'Working' }
    $entry = [pscustomobject]@{ Name = 'Codex: x'; Machine = 'M'; Kind = 'codex'; Status = 'working'; Offset = 0L }

    Write-Host '--- a Codex card carries a driver at all ---'
    Add-Roll ($assistantSays -replace '__TEXT__', 'hello')
    Update-DaemonCodexActivity -Id 'cx' -Entry $entry -Session $session -Headers @{} -VerboseOn $true
    Test-That 'the detail has a driver key' { $null -ne $script:LastDetail -and $script:LastDetail.ContainsKey('driver') }
    Test-That 'and with nothing recorded it is yours' { $script:LastDetail['driver'] -eq 'human' }

    Write-Host '--- a reply that came through Home Assistant marks the session ---'
    # What Invoke-DaemonReply records on a Submit press from an agent's account: the
    # driver, and Pending so the turn it is about to start is not read as typed in the
    # terminal and handed straight back.
    Set-DaemonSessionProperty -Entry $entry -Name 'Driver' -Value 'agent'
    Set-DaemonSessionProperty -Entry $entry -Name 'DriverPending' -Value $true
    Add-Roll $turnStarts
    Add-Roll ($assistantSays -replace '__TEXT__', 'working on it')
    Update-DaemonCodexActivity -Id 'cx' -Entry $entry -Session $session -Headers @{} -VerboseOn $true
    Test-That 'the turn it starts is still the agent''s' { $script:LastDetail['driver'] -eq 'agent' } "driver=[$($script:LastDetail['driver'])]"
    Test-That 'and the pending flag is spent, not left to mark the next turn too' { -not $entry.DriverPending }

    Write-Host '--- an arm waits for its turn, not for the next card update ---'
    # Measured on a live 1.28.0 install: a long reply is typed into the console a
    # character at a time, so the card published "Reading your message" for about three
    # minutes before the turn began. That update used to spend the arm, and the turn
    # then read as typed in the terminal - so the card lost the agent's edge at exactly
    # the moment the session got busy, which is when you are looking at it.
    Set-DaemonDriverPending -Entry $entry -Driver 'agent'
    Add-Roll ($assistantSays -replace '__TEXT__', 'reading your message')
    Update-DaemonCodexActivity -Id 'cx' -Entry $entry -Session $session -Headers @{} -VerboseOn $true
    Test-That 'an update carrying no turn leaves the arm alone' { $entry.DriverPending } "pending=[$($entry.DriverPending)]"
    Add-Roll $turnStarts
    Add-Roll ($assistantSays -replace '__TEXT__', 'answering now')
    Update-DaemonCodexActivity -Id 'cx' -Entry $entry -Session $session -Headers @{} -VerboseOn $true
    Test-That 'so the turn it was armed for is still the agent''s' { $script:LastDetail['driver'] -eq 'agent' } "driver=[$($script:LastDetail['driver'])]"
    Test-That 'and only that turn spends it' { -not $entry.DriverPending }

    Write-Host '--- an arm whose turn never came cannot mark a later one ---'
    # A reply can be delivered to a session that is already shutting down, so the turn
    # it was armed for never arrives. Without an expiry the flag would sit there and
    # put the agent's edge on whatever the person typed next, which is the one
    # direction this must never fail in.
    Set-DaemonDriverPending -Entry $entry -Driver 'agent'
    Set-DaemonSessionProperty -Entry $entry -Name 'DriverPendingAt' `
        -Value ([DateTimeOffset]::Now.AddSeconds(-($script:DaemonConfig.DriverArmSeconds + 60)).ToString('o'))
    Add-Roll $turnStarts
    Add-Roll ($assistantSays -replace '__TEXT__', 'you typed this one, much later')
    Update-DaemonCodexActivity -Id 'cx' -Entry $entry -Session $session -Headers @{} -VerboseOn $true
    Test-That 'a stale arm does not mark a turn the person typed' { $script:LastDetail['driver'] -eq 'human' } "driver=[$($script:LastDetail['driver'])]"

    Write-Host '--- typing in the terminal hands it back ---'    Add-Roll $turnStarts
    Add-Roll ($assistantSays -replace '__TEXT__', 'you typed this one')
    Update-DaemonCodexActivity -Id 'cx' -Entry $entry -Session $session -Headers @{} -VerboseOn $true
    Test-That 'a turn starting with no reply behind it is yours again' { $script:LastDetail['driver'] -eq 'human' } "driver=[$($script:LastDetail['driver'])]"

    Write-Host '--- and it stays the agent''s while it works ---'
    Set-DaemonSessionProperty -Entry $entry -Name 'Driver' -Value 'agent'
    Add-Roll ($assistantSays -replace '__TEXT__', 'still going')
    Update-DaemonCodexActivity -Id 'cx' -Entry $entry -Session $session -Headers @{} -VerboseOn $true
    Test-That 'a batch with no new turn does not hand it back' { $script:LastDetail['driver'] -eq 'agent' } "driver=[$($script:LastDetail['driver'])]"
}
finally {
    Remove-Item -LiteralPath $rollout -Force -ErrorAction SilentlyContinue
}

Write-Host '--- a restart restores the driver with the rest of the card ---'
$primed = [pscustomobject]@{ Name = 'Codex: x'; Machine = 'M'; Status = 'working'; LastSummary = 'Running: grep' }
Set-DaemonSessionProperty -Entry $primed -Name 'Driver' -Value 'agent'
$card = Resolve-DaemonPrimedCard -Entry $primed -Status 'working' -VerboseOn $true
Test-That 'a session an agent was driving is still marked after a restart' { $card.Detail['driver'] -eq 'agent' } "driver=[$($card.Detail['driver'])]"

$yours = [pscustomobject]@{ Name = 'Codex: x'; Machine = 'M'; Status = 'working' }
$card = Resolve-DaemonPrimedCard -Entry $yours -Status 'working' -VerboseOn $true
Test-That 'and one with nothing recorded reads as yours' { $card.Detail['driver'] -eq 'human' }

Remove-Item -LiteralPath $script:DaemonConfig.LogFile -Force -ErrorAction SilentlyContinue
if ($script:Failures) { Write-Host "`n$script:Failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "`nAll driver-card checks passed" -ForegroundColor Green
