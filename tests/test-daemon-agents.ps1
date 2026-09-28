#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the per-agent table (hooks/daemon-agents.ps1) and the shared code that
    calls through it.

.DESCRIPTION
    Each agent's readers and publishers are replaced by recorders, so these check
    only which one a session of each kind is routed to - including the kinds the
    table does not list, which get Copilot's readers and none of its flags, as the
    old `else` branches did. Nothing reads a real transcript or talks to Home
    Assistant.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
$script:DaemonConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-daemon-agents-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

$script:Calls = [System.Collections.Generic.List[string]]::new()
function Read-TranscriptAppend { param($Path, $Offset) $script:Calls.Add('events-read'); [pscustomobject]@{ Lines = @(); Offset = 0 } }
function Read-ClaudeTranscriptAppend { param($Path, $Offset, $MaxTailBytes) $script:Calls.Add('claude-read'); [pscustomobject]@{ Lines = @(); Offset = 0 } }
function Get-ActivityFromEvents { param($Lines, $VerboseMode) $script:Calls.Add('events-activity') }
function Get-ClaudeActivityFromTranscript { param($Lines, $VerboseMode) $script:Calls.Add('claude-activity') }
function Test-CopilotSessionWorking { param($SessionId) $script:Calls.Add('copilot-lock'); $true }
function Write-DaemonLog { param([string]$Message) }

function Get-Routed { param([scriptblock]$Call) $script:Calls.Clear(); & $Call | Out-Null; ($script:Calls -join ',') }

Write-Host '--- looking an agent up ---'
Test-That 'Copilot, Claude and Codex are listed' { (@($script:DaemonAgents.Keys) -join ',') -eq 'copilot,claude,codex' }
Test-That 'an entry recorded before kinds existed is Copilot''s' { (Get-DaemonEntryKind -Entry ([pscustomobject]@{ Name = 'x' })) -eq 'copilot' }
Test-That 'and so is a blank kind' { (Get-DaemonEntryKind -Entry ([pscustomobject]@{ Kind = '' })) -eq 'copilot' }
Test-That 'a recorded kind is kept' { (Get-DaemonEntryKind -Entry ([pscustomobject]@{ Kind = 'mcp' })) -eq 'mcp' }
Test-That 'Codex gets Copilot''s readers for the slots it leaves out' { (Get-DaemonAgent -Kind 'codex').ReadAppend -eq $script:DaemonAgents.copilot.ReadAppend }
Test-That 'an unlisted kind gets Copilot''s readers' { (Get-DaemonAgent -Kind 'mcp').IsWorking -eq $script:DaemonAgents.copilot.IsWorking }
Test-That 'but none of its flags' { -not (Get-DaemonAgent -Kind 'mcp').RefreshName }
Test-That 'a blank kind gets Copilot''s flags too' { (Get-DaemonAgent -Kind '').RefreshName }
Test-That 'only Claude has hook status and inline reasoning' {
    @($script:DaemonAgents.Keys | Where-Object { (Get-DaemonAgent -Kind $_).HookStatus -or (Get-DaemonAgent -Kind $_).InlineReasoning }) -join ',' -eq 'claude'
}

Write-Host '--- reading a transcript ---'
$script:ClaudeAdapterLoaded = $true
Test-That 'Claude reads with its adapter' { (Get-Routed { Read-BridgeTranscriptAppend -Path 'p' -Offset 0 -Kind 'claude' }) -eq 'claude-read' }
Test-That 'and parses with it' { (Get-Routed { Get-BridgeActivity -Lines @() -VerboseMode $true -Kind 'claude' }) -eq 'claude-activity' }
Test-That 'Copilot reads events' { (Get-Routed { Read-BridgeTranscriptAppend -Path 'p' -Offset 0 -Kind 'copilot' }) -eq 'events-read' }
Test-That 'as does an unlisted kind' { (Get-Routed { Get-BridgeActivity -Lines @() -VerboseMode $true -Kind 'mcp' }) -eq 'events-activity' }
$script:ClaudeAdapterLoaded = $false
Test-That 'Claude without its adapter falls back to events, as before' { (Get-Routed { Read-BridgeTranscriptAppend -Path 'p' -Offset 0 -Kind 'claude' }) -eq 'events-read' }

Write-Host '--- is it working ---'
Test-That 'Copilot asks its lock file' { (Get-Routed { Test-BridgeSessionWorking -SessionId 's' -Kind 'copilot' }) -eq 'copilot-lock' }
Test-That 'an unlisted kind too' { (Get-Routed { Test-BridgeSessionWorking -SessionId 's' -Kind 'mcp' }) -eq 'copilot-lock' }
Test-That 'Codex takes the status its hooks recorded' {
    (Test-BridgeSessionWorking -SessionId 's' -Kind 'codex' -Status 'working') -and -not (Test-BridgeSessionWorking -SessionId 's' -Kind 'codex' -Status 'idle')
}
Test-That 'Claude without its adapter is idle' { -not (Test-BridgeSessionWorking -SessionId 's' -Kind 'claude' -Transcript 'x') }
$script:ClaudeAdapterLoaded = $true
$fresh = Join-Path ([IO.Path]::GetTempPath()) "agents-$([guid]::NewGuid().ToString('N')).jsonl"
Set-Content -LiteralPath $fresh -Value '{}'
Test-That 'Claude with a transcript just written is working' { Test-BridgeSessionWorking -SessionId 's' -Kind 'claude' -Transcript $fresh }
[IO.File]::SetLastWriteTimeUtc($fresh, [DateTime]::UtcNow.AddMinutes(-5))
Test-That 'and with an old one is not' { -not (Test-BridgeSessionWorking -SessionId 's' -Kind 'claude' -Transcript $fresh) }
Remove-Item -LiteralPath $fresh -Force
Test-That 'a Claude hook''s status wins at startup' {
    (Get-DaemonStartupStatus -Session ([pscustomobject]@{ SessionId = 's'; HookStatus = 'waiting' }) -Entry ([pscustomobject]@{ Kind = 'claude' })) -eq 'waiting'
}
Test-That 'a Copilot session''s recorded hook status is not consulted' {
    (Get-DaemonStartupStatus -Session ([pscustomobject]@{ SessionId = 's'; HookStatus = 'waiting' }) -Entry ([pscustomobject]@{ Kind = 'copilot' })) -eq 'working'
}

Write-Host '--- the card text ---'
$entry = [pscustomobject]@{ Kind = 'claude'; LastResponse = 'answer'; LastMessage = 'thought'; LastMessageIsThinking = $true; LastReasoning = 'why' }
$card = @{}; Add-DaemonCardText -Entry $entry -Detail $card -VerboseOn $true
Test-That 'Claude shows its newest line, thinking included, inline' { $card.response -eq 'thought' -and $card.response_kind -eq 'reasoning' -and -not $card.ContainsKey('reasoning') }
$entry.Kind = 'copilot'
$card = @{}; Add-DaemonCardText -Entry $entry -Detail $card -VerboseOn $true
Test-That 'Copilot shows its answer, with the reasoning below it' { $card.response -eq 'answer' -and $card.reasoning -eq 'why' }

Write-Host '--- the fast lane ---'
function Update-DaemonPendingLaunch { param($Headers) }
function Sync-DaemonCodexHookStatus { param($Id, $Entry, $Headers) $script:Calls.Add("codex-hook:$Id"); $true }
function Update-DaemonCodexActivity { param($Id, $Entry, $Session, $Headers, $VerboseOn, [switch]$Republish) $script:Calls.Add("codex-card:$Id") }
function Update-DaemonSessionActivity { param($Id, $Entry, $Session, $Headers, $VerboseOn) $script:Calls.Add("shared:$Id") }
function Get-ClaudeSafeSessionKey { param($SessionId) "k-$SessionId" }
$transcript = Join-Path ([IO.Path]::GetTempPath()) "agents-$([guid]::NewGuid().ToString('N')).jsonl"
Set-Content -LiteralPath $transcript -Value '{"type":"x"}'
$state = @{
    cx = [pscustomobject]@{ Kind = 'codex'; Offset = 0 }
    cp = [pscustomobject]@{ Kind = 'copilot'; Offset = 0 }
    mc = [pscustomobject]@{ Kind = 'mcp'; Offset = 0 }
}
$script:DaemonLive = @{
    cx = [pscustomobject]@{ SessionId = 'cx'; Transcript = $transcript }
    cp = [pscustomobject]@{ SessionId = 'cp'; Transcript = $transcript }
    mc = [pscustomobject]@{ SessionId = 'mc'; Transcript = $transcript }
}
$routed = (Get-Routed { Invoke-DaemonFastActivity -Headers @{} -State $state }) -split ',' | Sort-Object
Test-That 'Codex streams its own card' { $routed -contains 'codex-hook:cx' -and $routed -contains 'codex-card:cx' -and $routed -notcontains 'shared:cx' }
Test-That 'Copilot and an unlisted kind take the shared path' { $routed -contains 'shared:cp' -and $routed -contains 'shared:mc' }
$state.cp.Offset = (Get-Item -LiteralPath $transcript).Length
Test-That 'a transcript that has not grown is left alone' { (Get-Routed { Invoke-DaemonFastActivity -Headers @{} -State @{ cp = $state.cp } }) -eq '' }

$regDir = Join-Path $env:TEMP 'agent-bridge-claude'
New-Item -ItemType Directory -Force -Path $regDir | Out-Null
$claudeId = "t-$([guid]::NewGuid().ToString('N'))"
$registration = Join-Path $regDir "k-$claudeId.json"
Set-Content -LiteralPath $registration -Value '{"HookStatus":"idle","HookStatusAt":"2026-09-27T07:00:00Z"}'
$claudeSession = [pscustomobject]@{ SessionId = $claudeId; Transcript = '' }
$script:DaemonLive = @{ $claudeId = $claudeSession }
$claudeState = @{ $claudeId = [pscustomobject]@{ Kind = 'claude'; Offset = 0 } }
Test-That 'a Claude hook registration change is picked up, with no transcript yet' {
    (Get-Routed { Invoke-DaemonFastActivity -Headers @{} -State $claudeState }) -eq "shared:$claudeId" -and $claudeSession.HookStatus -eq 'idle'
}
Test-That 'and only once' { (Get-Routed { Invoke-DaemonFastActivity -Headers @{} -State $claudeState }) -eq '' }
Remove-Item -LiteralPath $registration, $transcript -Force

Write-Host '--- the reconcile ---'
$cxId = '11111111-0000-4000-8000-000000000001'
$script:Named = $false
function Get-BridgeSessionDisplay { param($SessionId, $Kind, $WorkingDirectory) $script:Named = $true; [pscustomobject]@{ Name = 'x' } }
function Set-CopilotMqttStatus { param($SessionId, $Status, $Headers, $Attributes) }
$routed = Get-Routed { Update-DaemonKnownSession -Session ([pscustomobject]@{ SessionId = $cxId }) -Entry ([pscustomobject]@{ Kind = 'codex'; Name = 'Codex: x' }) -Headers @{} -VerboseOn $true }
Test-That 'a known Codex session streams its own card' { $routed -eq "codex-card:$cxId" }
$script:Named = $false
$null = Get-Routed { Update-DaemonKnownSession -Session ([pscustomobject]@{ SessionId = '22222222-0000-4000-8000-000000000002' }) -Entry ([pscustomobject]@{ Kind = 'copilot'; Name = 'old name'; Status = 'idle'; Machine = 'M' }) -Headers @{} -VerboseOn $true }
Test-That 'a Copilot name without its prefix is re-resolved' { $script:Named }
$script:Named = $false
$null = Get-Routed { Update-DaemonKnownSession -Session ([pscustomobject]@{ SessionId = '33333333-0000-4000-8000-000000000003' }) -Entry ([pscustomobject]@{ Kind = 'mcp'; Name = 'Cursor'; Status = 'idle'; Machine = 'M' }) -Headers @{} -VerboseOn $true }
Test-That 'an unlisted kind''s name is left as it is' { -not $script:Named }

Remove-Item -LiteralPath $script:DaemonConfig.LogFile -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All daemon agent checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
