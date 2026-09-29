#Requires -Version 7.0
<#
.SYNOPSIS
    Integration test for the Codex adapter against a real Home Assistant.

.DESCRIPTION
    Drives codex-bridge-hook.ps1 with the recorded hook fixtures - fed on stdin
    exactly as Codex feeds them - and checks that the session card publishes, that the
    status and activity track the event, and that an approval arms the decision
    selector. This is the Codex counterpart to the Claude integration test, and it
    exercises the shared adapter orchestration (bridge-adapter.ps1) end to end.

    Requires the main bridge to be installed (the shared Home Assistant layer, and now
    bridge-adapter.ps1, live in ~/.agent-ha-bridge/hooks). Creates entities and removes them
    again. Not part of CI because it needs a real Home Assistant.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# This suite means to use a real Home Assistant, which the guard in
# decision-bridge-common.ps1 otherwise refuses for anything under a tests directory.
$env:BRIDGE_ALLOW_TEST_HTTP = '1'
# The hooks run here against Home Assistant beside a running daemon, which would
# otherwise publish their prompt and tool-call updates for them - and this test
# session is not one it follows.
$env:AGENT_BRIDGE_HOOKS_PUBLISH = '1'

$core = Join-Path $HOME '.agent-ha-bridge\hooks'
if (-not (Test-Path -LiteralPath (Join-Path $core 'bridge-adapter.ps1'))) {
    Write-Host 'The main bridge (with bridge-adapter.ps1) is not installed; run install.ps1 first.' -ForegroundColor Yellow
    exit 2
}

. (Join-Path $core 'decision-bridge-common.ps1')
. (Join-Path $core 'decision-mqtt.ps1')
. (Join-Path $core 'decision-ha-websocket.ps1')
. (Join-Path $PSScriptRoot '..\hooks\codex-session.ps1')

$hook = Join-Path $PSScriptRoot '..\hooks\codex-bridge-hook.ps1'
$fixtures = Join-Path $PSScriptRoot '..\fixtures'
$headers = Get-HomeAssistantHeaders

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($ok) { Write-Host "  PASS  $Name$(if ($Detail) { " - $Detail" })" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

function Invoke-Hook {
    param([string]$FixtureName)
    $raw = Get-Content (Join-Path $fixtures $FixtureName) -Raw
    $output = $raw | & pwsh -NoProfile -File $hook 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String).Trim() }
}

$sessionId = '01a0cab3-a184-7642-80af-56b9235d6a58'
$node = Get-CopilotMqttNodeId -SessionId $sessionId
$statusEntity = "sensor.${node}_status"

function Get-StatusState {
    try { [string](Get-HomeAssistantState -EntityId $statusEntity -Headers $headers).state } catch { '' }
}

try {
    Write-Host '--- SessionStart publishes the card as idle ---'
    $r = Invoke-Hook 'sessionstart.json'
    Test-That 'the hook exits 0 silently' { $r.ExitCode -eq 0 -and $r.Output -eq '' } "exit $($r.ExitCode)"
    # Home Assistant creates the entities from MQTT discovery in its own time, so wait
    # for them rather than a fixed pause, which was sometimes too short.
    $deadline = (Get-Date).AddSeconds(6)
    while ((Get-StatusState) -ne 'idle' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    Test-That 'the status sensor exists and reads idle' { (Get-StatusState) -eq 'idle' } (Get-StatusState)

    Write-Host '--- PreToolUse shows the running command ---'
    $r = Invoke-Hook 'pretooluse.json'
    Test-That 'the hook exits 0' { $r.ExitCode -eq 0 }
    Test-That 'the status reads working' { (Get-StatusState) -eq 'working' } (Get-StatusState)
    $act = try { (Get-HomeAssistantState -EntityId "sensor.${node}_activity" -Headers $headers).state } catch { '' }
    Test-That 'the activity names the running tool' { ([string]$act) -match 'Running: Bash' } ([string]$act)

    Write-Host '--- Stop marks the turn idle and previews the reply ---'
    $r = Invoke-Hook 'stop.json'
    Test-That 'the Stop hook exits 0' { $r.ExitCode -eq 0 }
    Test-That 'the session goes idle' { (Get-StatusState) -eq 'idle' } (Get-StatusState)
    # The reply goes to the card whole, as `response`: published as the status line
    # alone it was cut at 255 characters with no way to read the rest.
    $stopActivity = try { Get-HomeAssistantState -EntityId "sensor.${node}_activity" -Headers $headers } catch { $null }
    Test-That 'the whole reply is on the card as its response' {
        [string]$stopActivity.attributes.response -eq "``````text`nhello-from-codex`n``````"
    } ([string]$stopActivity.attributes.response)
    Test-That 'and the status line is its first line' { [string]$stopActivity.state -eq '```text' } ([string]$stopActivity.state)

    Write-Host '--- SessionEnd returns promptly with no Home Assistant work ---'
    $r = Invoke-Hook 'sessionend.json'
    Test-That 'the SessionEnd hook exits 0 silently' { $r.ExitCode -eq 0 -and $r.Output -eq '' } "exit $($r.ExitCode)"
}
finally {
    Write-Host '--- cleanup ---'
    try {
        Remove-CopilotMqttSession -SessionId $sessionId -Headers $headers
        Remove-CodexApprovalMarker -SessionId $sessionId | Out-Null
        Write-Host '  removed the test session'
    }
    catch { Write-Host "  cleanup note: $($_.Exception.Message)" -ForegroundColor Yellow }
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
