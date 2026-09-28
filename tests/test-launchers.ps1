#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the launcher table (`$script:BridgeLaunchers` in hooks/session-launch.ps1)
    and the launch code that reads it.

.DESCRIPTION
    Each launcher's executable lookup, session readers and hook registrations are
    replaced or pointed at temporary files, so these check only what each launcher
    is routed to: its label and kind, its command line, its resumable sessions, how
    its launch is recognised, and the daemon's launch flags. Nothing is started.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
$script:DaemonConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-launchers-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

Write-Host '--- the table ---'
Test-That 'Agency, Copilot, Claude and Codex, in the order auto prefers' { (@($script:BridgeLaunchers.Keys) -join ',') -eq 'agency,copilot,claude,codex' }
Test-That 'labels are the dashboard''s' { (@('agency', 'copilot', 'claude', 'codex' | ForEach-Object { Get-BridgeLauncherLabel -Launcher $_ }) -join ',') -eq 'Agency,Copilot,Claude,Codex' }
Test-That 'an unknown launcher is labelled by its own name' { (Get-BridgeLauncherLabel -Launcher 'gemini') -eq 'gemini' }
Test-That 'Agency starts Copilot sessions' { (Get-BridgeLauncher -Launcher 'agency').Kind -eq 'copilot' }
Test-That 'only Codex chooses its own session id and needs a first message' {
    (@($script:BridgeLaunchers.Keys | Where-Object { (Get-BridgeLauncher -Launcher $_).ChoosesOwnSessionId }) -join ',') -eq 'codex' -and
    (@($script:BridgeLaunchers.Keys | Where-Object { (Get-BridgeLauncher -Launcher $_).NeedsFirstMessage }) -join ',') -eq 'codex'
}
Test-That 'only Claude asks to trust a folder' { (@($script:BridgeLaunchers.Keys | Where-Object { (Get-BridgeLauncher -Launcher $_).AnswersTrustPrompt }) -join ',') -eq 'claude' }
Test-That 'an unknown launcher has no slots and no flags' {
    $e = Get-BridgeLauncher -Launcher 'gemini'
    $null -eq $e.Path -and $null -eq $e.Arguments -and -not $e.NeedsFirstMessage -and -not $e.AnswersTrustPrompt
}

Write-Host '--- finding each executable ---'
function Get-BridgeAgencyPath { 'agency.exe' }
function Get-BridgeCopilotPath { 'copilot.exe' }
function Get-BridgeClaudePath { 'claude.exe' }
function Get-BridgeCodexPath { $null }
Test-That 'each launcher asks its own lookup' {
    (Get-BridgeLauncherPath -Launcher 'agency') -eq 'agency.exe' -and (Get-BridgeLauncherPath -Launcher 'claude') -eq 'claude.exe' -and
    $null -eq (Get-BridgeLauncherPath -Launcher 'codex')
}
Test-That 'an unknown launcher is not installed' { $null -eq (Get-BridgeLauncherPath -Launcher 'gemini') }

Write-Host '--- command lines ---'
$sid = '11111111-2222-3333-4444-555555555555'
function Get-Args { param([string]$Launcher, [string]$Id = $sid, [string]$Prompt = '', [switch]$All, [switch]$Resume)
    (@(Get-BridgeNewSessionArguments -SessionId $Id -Prompt $Prompt -Launcher $Launcher -AllowAllTools:$All -Resume:$Resume) -join ' ')
}
Test-That 'Claude takes its id, and the prompt after --' { (Get-Args 'claude' -Prompt 'hi') -eq "--session-id $sid -- hi" }
Test-That 'and resumes with --resume' { (Get-Args 'claude' -Resume) -eq "--resume $sid" }
Test-That 'and skips permissions only when asked' { (Get-Args 'claude' -All) -eq "--session-id $sid --dangerously-skip-permissions" }
Test-That 'Codex runs without its daemon, and resumes by subcommand with the id last' { (Get-Args 'codex' -Resume) -match '^--no-daemon .*\bresume ' -and (Get-Args 'codex' -Resume).EndsWith($sid) }
Test-That 'Codex opened with nothing has an empty-safe command line' { @(Get-BridgeNewSessionArguments -SessionId '' -Launcher 'codex').Count -ge 1 }
Test-That 'Copilot keeps its own command line' { (Get-Args 'copilot') -match '--banner' }
Test-That 'an unknown launcher is refused' { try { Get-BridgeNewSessionArguments -SessionId $sid -Launcher 'gemini'; $false } catch { $true } }

Write-Host '--- resumable sessions ---'
function Get-BridgeAvailableLaunchers { $script:Installed }
function Get-BridgeAgencySessionEntries { @($script:AgencyEntries) }
function Get-BridgeCopilotSessionEntries { param($Limit) @([pscustomobject]@{ SessionId = 'cp1'; Launcher = 'copilot'; Updated = [DateTime]::UtcNow.AddMinutes(-3); Summary = 'copilot one'; Folder = 'C:\w' }) }
function Get-BridgeClaudeSessionEntries { param($Limit) @([pscustomobject]@{ SessionId = 'cl1'; Launcher = 'claude'; Updated = [DateTime]::UtcNow.AddMinutes(-1); Summary = 'claude one'; Folder = 'C:\w' }) }
function Get-BridgeCodexSessionEntries { param($Limit) @() }
$script:Installed = @('agency', 'copilot', 'claude')
$script:AgencyEntries = @([pscustomobject]@{ SessionId = 'ag1'; Launcher = 'agency'; Updated = [DateTime]::UtcNow.AddMinutes(-2); Summary = 'agency one'; Folder = 'C:\w' })
$ids = @(Get-BridgeResumableSessions -Limit 10 | ForEach-Object SessionId)
Test-That 'Agency''s sessions stand in for Copilot''s when it has any' { ($ids -contains 'ag1') -and ($ids -notcontains 'cp1') -and ($ids -contains 'cl1') }
$script:AgencyEntries = @()
$ids = @(Get-BridgeResumableSessions -Limit 10 | ForEach-Object SessionId)
Test-That 'Copilot''s own store fills in when Agency comes back empty' { $ids -contains 'cp1' }
$script:Installed = @('claude')
$ids = @(Get-BridgeResumableSessions -Limit 10 | ForEach-Object SessionId)
Test-That 'only installed launchers are asked' { ($ids -join ',') -eq 'cl1' }

$script:Installed = @('agency', 'claude')
$script:AgencyEntries = @([pscustomobject]@{ SessionId = 'cl1'; Launcher = 'agency'; Updated = [DateTime]::UtcNow; Summary = 'claude one'; Folder = 'C:\w' })
$both = @(Get-BridgeResumableSessions -Limit 10)
Test-That 'a Claude session Agency also lists is reopened by Claude' { $both.Count -eq 1 -and $both[0].Launcher -eq 'claude' }

Write-Host '--- recognising a launch ---'
$dir = Join-Path $env:TEMP 'agent-bridge-claude'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$claudeId = "t-$([guid]::NewGuid().ToString('N'))"
$reg = Join-Path $dir "$claudeId.json"
Set-Content -LiteralPath $reg -Value (@{ ProcessId = $PID } | ConvertTo-Json)
function Test-BridgeAgentProcess { param($Process, $Agent) $null -ne $Process -and $Agent -eq 'claude' }
Test-That 'a Claude launch is recognised by its registration and live process' { Test-BridgeSessionRegistered -SessionId $claudeId -Launcher 'claude' }
Remove-Item -LiteralPath $reg -Force
Test-That 'and not before it registers' { -not (Test-BridgeSessionRegistered -SessionId $claudeId -Launcher 'claude') }

Write-Host '--- launch notes ---'
Test-That 'a note about a launch in progress is recognised, for any agent' {
    (Test-DaemonLaunchProgressNote -Text 'Starting Claude in repo...') -and
    (Test-DaemonLaunchProgressNote -Text 'Codex is open in repo. It appears here after its first message: type one.') -and
    (Test-DaemonLaunchProgressNote -Text 'Claude is asking whether to trust repo. Press Launch again within 2 minutes to trust it and start.') -and
    (Test-DaemonLaunchProgressNote -Text 'Gemini is asking whether to trust repo. Press Launch again.')
}
Test-That 'an outcome is not' {
    -not (Test-DaemonLaunchProgressNote -Text 'Claude is still asking whether to trust repo - answer it in its window.') -and
    -not (Test-DaemonLaunchProgressNote -Text 'Claude in repo closed before it started.') -and
    -not (Test-DaemonLaunchProgressNote -Text '')
}

Write-Host '--- a question only the window can answer ---'
# Seen on DASDESK after 1.12.0: Codex stopped at its hook review, never registered,
# and the launch just said "has not registered" after 90 s.
$reviewScreen = "  Hooks need review`n  6 hooks are new or changed.`n› 1. Review hooks`n  2. Trust all and continue"
Test-That 'Codex recognises its hook review' { (& (Get-BridgeLauncher -Launcher 'codex').BlockingPrompt $reviewScreen) -match "Trust all and continue" }
Test-That 'and nothing else' { $null -eq (& (Get-BridgeLauncher -Launcher 'codex').BlockingPrompt 'OpenAI Codex ready') }
Test-That 'the other launchers have no such check' { $null -eq (Get-BridgeLauncher -Launcher 'copilot').BlockingPrompt }
Test-That 'its note counts as a launch in progress' {
    Test-DaemonLaunchProgressNote -Text ((& (Get-BridgeLauncher -Launcher 'codex').BlockingPrompt $reviewScreen) -f 'repo')
}

$script:Notes = @()
function Set-CopilotMqttNewSessionResult { param([hashtable]$Headers, [string]$Text) $script:Notes += $Text }
function Test-BridgeSessionRegistered { param($SessionId, $Launcher, $Since) $false }
$script:Screen = $reviewScreen
function Read-BridgeConsoleScreen { param([int]$ProcessId) $script:Screen }
$started = [DateTimeOffset]::Now.AddSeconds(-5)
# A running process that is not this one: the daemon never reads its own console.
$otherPid = (Get-Process -Id $PID).Parent.Id
$script:DaemonPendingLaunch = [pscustomobject]@{
    SessionId = ''; Launcher = 'codex'; ProcessId = $otherPid; Label = 'repo'; Verb = 'Started'; Since = $started
    LastCheck = [DateTimeOffset]::MinValue; TrustAskedAt = $null; TrustConfirmed = $false; TrustAnswers = 0
    AwaitingFirstMessage = $false; FirstMessageAsked = $false
}
Update-DaemonPendingLaunch -Headers @{}
Test-That 'the card says what the window is asking, within seconds' { ($script:Notes -join '|') -match "Codex in repo is asking you to trust the bridge's hooks" } ($script:Notes -join '|')
$script:DaemonPendingLaunch.Since = [DateTimeOffset]::Now.AddMinutes(-5)
$script:DaemonPendingLaunch.LastCheck = [DateTimeOffset]::MinValue
Update-DaemonPendingLaunch -Headers @{}
Test-That 'and the launch waits for an answer past the usual 90 s' { $null -ne $script:DaemonPendingLaunch }
$script:DaemonPendingLaunch.BlockedAt = [DateTimeOffset]::Now.AddMinutes(-11)
$script:DaemonPendingLaunch.LastCheck = [DateTimeOffset]::MinValue
Update-DaemonPendingLaunch -Headers @{}
Test-That 'but not forever' { $null -eq $script:DaemonPendingLaunch -and $script:Notes[-1] -match 'still waiting on a question in its window' }

Remove-Item -LiteralPath $script:DaemonConfig.LogFile -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All launcher checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
