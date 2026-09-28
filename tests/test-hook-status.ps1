#Requires -Version 7.0
<#
.SYNOPSIS
    Tests that the daemon adopts the status Claude's hooks set.

.DESCRIPTION
    Claude's Stop and Notification hooks publish 'idle' and 'waiting' straight to
    Home Assistant. The daemon used to keep its own copy at 'working', so it never
    published 'working' again when the session carried on: a card stuck on
    'waiting' while the agent worked, with no glow. These cover the adoption, the
    publish on a new prompt, and that the tail of a finished turn is not mistaken
    for a resumption.

    Nothing here contacts Home Assistant.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
$script:DaemonConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-hook-status-$([guid]::NewGuid().ToString('N').Substring(0,8)).log"

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

$script:Published = @()
$script:PublishFails = $false
function Set-CopilotMqttStatus {
    param([string]$SessionId, [string]$Status, [hashtable]$Headers, [hashtable]$Attributes)
    if ($script:PublishFails) { throw 'broker down' }
    $script:Published += $Status
}

$headers = @{ Authorization = 'Bearer test' }
function New-Entry { param([string]$Status) [pscustomobject]@{ Name = 'Claude: x'; Machine = 'M'; Status = $Status } }
function New-Session {
    param([string]$Status, [string]$At)
    [pscustomobject]@{ ProcessId = 1; HookStatus = $Status; HookStatusAt = $At }
}

Write-Host ''
Write-Host '--- adopting what a hook set ---'

$entry = New-Entry 'working'
$at = Sync-DaemonHookStatus -Entry $entry -Session (New-Session 'waiting' '2026-09-27T07:00:00Z') -SessionId 's' -Headers $headers
Test-That 'a notification moves the daemon off working' { $entry.Status -eq 'waiting' }
Test-That 'without republishing what the hook already sent' { $script:Published.Count -eq 0 }
Test-That 'and reports when the hook fired' { $at -eq [DateTimeOffset]'2026-09-27T07:00:00Z' }

$script:Published = @()
$entry = New-Entry 'idle'
$null = Sync-DaemonHookStatus -Entry $entry -Session (New-Session 'working' '2026-09-27T07:01:00Z') -SessionId 's' -Headers $headers
Test-That 'a new prompt publishes working, which no hook does itself' {
    $entry.Status -eq 'working' -and ($script:Published -join ',') -eq 'working'
}

$script:Published = @()
$null = Sync-DaemonHookStatus -Entry $entry -Session (New-Session 'working' '2026-09-27T07:01:00Z') -SessionId 's' -Headers $headers
Test-That 'the same hook event is acted on only once' { $script:Published.Count -eq 0 }

$script:PublishFails = $true
$entry = New-Entry 'idle'
$null = Sync-DaemonHookStatus -Entry $entry -Session (New-Session 'working' '2026-09-27T07:02:00Z') -SessionId 's' -Headers $headers
Test-That 'a failed publish is left to retry' { $entry.Status -eq 'idle' -and -not $entry.PSObject.Properties['HookStatusAt'] }
$script:PublishFails = $false
$null = Sync-DaemonHookStatus -Entry $entry -Session (New-Session 'working' '2026-09-27T07:02:00Z') -SessionId 's' -Headers $headers
Test-That 'and the retry succeeds' { $entry.Status -eq 'working' }

$entry = New-Entry 'working'
Test-That 'no recorded hook status changes nothing' {
    ($null -eq (Sync-DaemonHookStatus -Entry $entry -Session (New-Session '' '') -SessionId 's' -Headers $headers)) -and
    $entry.Status -eq 'working'
}
Test-That 'an older registration without hook fields is tolerated' {
    $null -eq (Sync-DaemonHookStatus -Entry $entry -Session ([pscustomobject]@{ ProcessId = 1 }) -SessionId 's' -Headers $headers)
}

Write-Host ''
Write-Host '--- the fast lane ---'

# Streaming used to happen only in the 15-second reconcile. The fast lane runs every
# wait tick and must act on exactly the sessions whose transcript grew.
$work = Join-Path ([IO.Path]::GetTempPath()) "fastlane-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $work -Force | Out-Null
$grown = Join-Path $work 'grown.jsonl'
$quiet = Join-Path $work 'quiet.jsonl'
Set-Content -LiteralPath $grown -Value 'one line' -NoNewline
Set-Content -LiteralPath $quiet -Value 'one line' -NoNewline

$script:Updated = @()
function Update-DaemonSessionActivity {
    param([string]$Id, $Entry, $Session, [hashtable]$Headers, [bool]$VerboseOn)
    $script:Updated += "$Id/$VerboseOn"
}

$fastState = @{
    grown = [pscustomobject]@{ Kind = 'copilot'; Offset = 0 }
    quiet = [pscustomobject]@{ Kind = 'copilot'; Offset = (Get-Item $quiet).Length }
    codex = [pscustomobject]@{ Kind = 'codex'; Offset = 0 }
    gone  = [pscustomobject]@{ Kind = 'copilot'; Offset = 0 }
}
$script:DaemonLive = @{
    grown = [pscustomobject]@{ Transcript = $grown }
    quiet = [pscustomobject]@{ Transcript = $quiet }
    codex = [pscustomobject]@{ Transcript = $grown }
}
$script:DaemonVerbose = $true

Invoke-DaemonFastActivity -Headers $headers -State $fastState
Test-That 'a session whose transcript grew is streamed' { $script:Updated -contains 'grown/True' }
Test-That 'with the current verbose setting' { $script:Updated -notcontains 'grown/False' }
Test-That 'an unchanged transcript costs nothing' { $script:Updated -notmatch '^quiet/' }
Test-That 'codex is left to its hooks' { $script:Updated -notmatch '^codex/' }
Test-That 'a session the last reconcile did not see as live is skipped' { $script:Updated -notmatch '^gone/' }

$script:Updated = @()
$script:DaemonLive = @{}
Invoke-DaemonFastActivity -Headers $headers -State $fastState
Test-That 'before the first reconcile it does nothing' { $script:Updated.Count -eq 0 }

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '--- confirming a reply was submitted ---'

# A long reply's Enter can be absorbed by Claude Code's paste handling, leaving the
# text in the input box while the card said "Reply sent". The transcript is the proof.
. (Join-Path $PSScriptRoot '..\claude\hooks\claude-transcript.ps1')
$tx = Join-Path ([IO.Path]::GetTempPath()) "submit-$([guid]::NewGuid().ToString('N').Substring(0,8)).jsonl"
Set-Content -LiteralPath $tx -Value '{"type":"assistant","message":{"content":[{"type":"text","text":"earlier"}]}}'
$start = (Get-Item $tx).Length

Test-That 'nothing new means not submitted' { -not (Test-DaemonClaudePromptSubmitted -Transcript $tx -Offset $start) }
Add-Content -LiteralPath $tx -Value '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"x","content":"ok"}]}}'
Test-That 'a tool result is not a submitted prompt' { -not (Test-DaemonClaudePromptSubmitted -Transcript $tx -Offset $start) }
Add-Content -LiteralPath $tx -Value '{"type":"user","isMeta":true,"message":{"content":"housekeeping"}}'
Test-That 'a meta entry is not one either' { -not (Test-DaemonClaudePromptSubmitted -Transcript $tx -Offset $start) }
$beforePrompt = (Get-Item $tx).Length
Add-Content -LiteralPath $tx -Value '{"type":"user","message":{"content":"the reply"}}'
Test-That 'a user prompt is' { Test-DaemonClaudePromptSubmitted -Transcript $tx -Offset $start }
Test-That 'but only if it is past the offset' { -not (Test-DaemonClaudePromptSubmitted -Transcript $tx -Offset (Get-Item $tx).Length) }
$beforeQueue = (Get-Item $tx).Length
Add-Content -LiteralPath $tx -Value '{"type":"queue-operation","operation":"enqueue","content":"queued reply"}'
Test-That 'a reply queued while a turn runs is' { Test-DaemonClaudePromptSubmitted -Transcript $tx -Offset $beforeQueue }

# With no submit in the transcript and retries not allowed, it reports rather than
# pressing Enter into a pending permission prompt.
$c = Confirm-DaemonClaudeSubmit -ProcessId 1 -Transcript $tx -Offset (Get-Item $tx).Length -WaitMs 200
Test-That 'no retry is attempted while a prompt is pending' { -not $c.Submitted -and $c.Retries -eq 0 -and $c.Detail -match 'not retried' }
$c = Confirm-DaemonClaudeSubmit -ProcessId 1 -Transcript $tx -Offset $beforePrompt -WaitMs 200 -AllowRetry
Test-That 'an already submitted prompt needs no extra Enter' { $c.Submitted -and $c.Retries -eq 0 }
Remove-Item -LiteralPath $tx -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '--- setting up an agent installed after the bridge ---'

# Every side effect is stood in for: no installer runs and the real config is untouched.
# The installers are found in a fake payload, not whatever this machine has installed.
$script:DaemonInstallerPayload = Join-Path ([IO.Path]::GetTempPath()) "bridge-payload-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
foreach ($stub in @('install.ps1', 'claude/install-claude.ps1', 'codex/install-codex.ps1')) {
    $stubPath = Join-Path $script:DaemonInstallerPayload $stub
    New-Item -ItemType Directory -Path (Split-Path $stubPath -Parent) -Force | Out-Null
    Set-Content -LiteralPath $stubPath -Value '# stub'
}
$script:Installed = @{ claude = $true; codex = $false }
$script:Adapters = @{ claude = $true; codex = $false }
$script:Started = @()
$script:Recorded = @()
$script:Notes = @()
$script:FakeExit = 0
# The fake below changes between calls, so nothing may be served from the cache.
$script:BridgeLauncherCacheSeconds = 0
function Get-BridgeLauncherPath { param([string]$Launcher) if ($script:Installed[$Launcher]) { "C:\bin\$Launcher.exe" } else { $null } }
function Get-DaemonClientAdapterInstalled { param([string]$Client) [bool]$script:Adapters[$Client] }
function Add-DaemonConfiguredClient { param([string]$Client) $script:Recorded += $Client }
function Set-CopilotMqttNewSessionResult { param([string]$Text, [hashtable]$Headers) $script:Notes += $Text }
function Start-Process {
    param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru, $RedirectStandardOutput, $RedirectStandardError, $ErrorAction)
    $script:Started += [string]$ArgumentList
    $script:FakeProcess = [pscustomobject]@{ Id = 777; HasExited = $false; ExitCode = 0 }
    $script:FakeProcess
}

$script:DaemonClientSetup = @{}
$script:DaemonRestartRequested = ''
$script:FakeSettings = @{ clients = @('claude') }
function Get-BridgeSetting { param([string]$Path, $Default) if ($script:FakeSettings.ContainsKey($Path)) { $script:FakeSettings[$Path] } else { $Default } }

Sync-DaemonClients -Headers $headers
Test-That 'an agent that is not installed is left alone' { $script:Started.Count -eq 0 }

$script:Installed.codex = $true
Sync-DaemonClients -Headers $headers
Test-That 'a newly installed agent gets its adapter installer run' {
    $script:Started.Count -eq 1 -and $script:Started[0] -match 'install-codex\.ps1'
}
Test-That 'in the background, without waiting' { -not $script:DaemonClientSetup.codex.Done }
Test-That 'an agent whose adapter is already there is not reinstalled' { @($script:Started | Where-Object { $_ -match 'install-claude' }).Count -eq 0 }

Sync-DaemonClients -Headers $headers
Test-That 'it is not started twice while running' { $script:Started.Count -eq 1 }

$script:FakeProcess.HasExited = $true
$script:Adapters.codex = $true
Sync-DaemonClients -Headers $headers
Test-That 'on success the agent joins the configured clients' { $script:Recorded -contains 'codex' }
Test-That 'the note says to approve the hooks in Codex' { ($script:Notes -join ' ') -match 'approve the agent-ha-bridge hooks' }
Test-That 'and the daemon restarts to load the adapter' { $script:DaemonRestartRequested -match 'Codex' }

$script:Started = @(); $script:DaemonRestartRequested = ''
Sync-DaemonClients -Headers $headers
Test-That 'a finished setup is not repeated' { $script:Started.Count -eq 0 }

# A failing installer is reported once, not retried on every pass.
$script:DaemonClientSetup = @{}
$script:Adapters.codex = $false
$script:Notes = @(); $script:Recorded = @()
Sync-DaemonClients -Headers $headers
$script:FakeProcess.HasExited = $true
$script:FakeProcess.ExitCode = 1
Sync-DaemonClients -Headers $headers
Test-That 'a failed setup is reported' { ($script:Notes -join ' ') -match 'setting it up failed' -and $script:Recorded.Count -eq 0 }
Test-That 'without a restart' { -not $script:DaemonRestartRequested }
$script:Started = @()
Sync-DaemonClients -Headers $headers
Test-That 'and not retried in a loop' { $script:Started.Count -eq 0 }

# An adapter installed by hand but missing from the list is recorded, not reinstalled.
$script:DaemonClientSetup = @{}
$script:Adapters.codex = $true
$script:Recorded = @(); $script:Started = @()
Sync-DaemonClients -Headers $headers
Test-That 'a hand-installed adapter is recorded without running its installer' { ($script:Recorded -contains 'codex') -and $script:Started.Count -eq 0 }

$script:DaemonClientSetup = @{}
$script:Adapters.codex = $false
$script:FakeSettings['autoConfigureClients'] = $false
$script:Started = @()
Sync-DaemonClients -Headers $headers
Test-That 'autoConfigureClients: false turns it off' { $script:Started.Count -eq 0 }

# Copilot's hooks come from the main installer, which drops them for any client not
# listed - so it is run with Copilot added to the clients already configured.
$script:DaemonClientSetup = @{}
$script:FakeSettings = @{ clients = @('claude', 'codex') }
$script:Installed.copilot = $true
$script:Adapters.copilot = $false
$script:Adapters.codex = $true
$script:Started = @()
Sync-DaemonClients -Headers $headers
Test-That 'Copilot installed later is set up by the main installer' {
    $script:Started.Count -eq 1 -and $script:Started[0] -match '[\\/]install\.ps1"' -and $script:Started[0] -match '-NonInteractive'
}
Test-That 'with Copilot added to the configured clients, not replacing them' { $script:Started[0] -match '-Clients claude,codex,copilot$' }

Write-Host ''
Write-Host '--- Codex status from its registration ---'
# The prompt and tool-call hooks only write the registration while the daemon runs;
# the daemon publishes it. Loaded against a scratch registration folder.
. (Join-Path $PSScriptRoot '..\codex\hooks\codex-session.ps1')
$savedCodexLoaded = $script:CodexAdapterLoaded
$savedCodexRoot = $script:CodexStateRoot
$script:CodexAdapterLoaded = $true
$script:CodexStateRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-reg-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $script:CodexStateRoot -Force | Out-Null
$script:StatusPublished = @()
function Set-CopilotMqttStatus { param([string]$SessionId, [string]$Status, [hashtable]$Headers, [hashtable]$Attributes) $script:StatusPublished += $Status }
try {
    $codexEntry = [pscustomobject]@{ Name = 'Codex: x'; Machine = 'M'; Status = 'idle'; Offset = 0L }
    Write-CodexSessionRegistration -SessionId 'cx1' -Status 'working' -Activity 'Prompt: fix it' -ProcessId 42 | Out-Null
    $codexEntry | Add-Member -NotePropertyName LastMessage -NotePropertyValue 'the previous answer' -Force
    Test-That 'a changed registration is picked up' { Sync-DaemonCodexHookStatus -Id 'cx1' -Entry $codexEntry -Headers $headers }
    Test-That 'its status is published' { ($script:StatusPublished -join ',') -eq 'working' -and $codexEntry.Status -eq 'working' }
    Test-That 'a new prompt starts the card afresh' { -not $codexEntry.LastMessage }
    Test-That 'an unchanged registration is left alone' { -not (Sync-DaemonCodexHookStatus -Id 'cx1' -Entry $codexEntry -Headers $headers) }
    Start-Sleep -Milliseconds 30
    Write-CodexSessionRegistration -SessionId 'cx1' -Status 'working' -Activity 'Running: exec' -ProcessId 42 | Out-Null
    $codexEntry.LastMessage = 'progress so far'
    Test-That 'a tool call republishes the card' { Sync-DaemonCodexHookStatus -Id 'cx1' -Entry $codexEntry -Headers $headers }
    Test-That 'without publishing an unchanged status again' { ($script:StatusPublished -join ',') -eq 'working' }
    Test-That 'and without clearing what the card shows' { $codexEntry.LastMessage -eq 'progress so far' }

    # A private TEMP: the real heartbeat is what every hook on this machine checks, and
    # deleting it sent them all to their slow PowerShell path for the duration.
    $realTemp = $env:TEMP
    $env:TEMP = $script:CodexStateRoot
    try {
        Test-That 'with no daemon heartbeat, hooks publish themselves' { -not (Test-BridgeDaemonAlive) }
        Set-BridgeDaemonAlive
        Test-That 'with a fresh one, they leave it to the daemon' { Test-BridgeDaemonAlive }
        $env:AGENT_BRIDGE_HOOKS_PUBLISH = '1'
        Test-That 'unless told to publish anyway' { -not (Test-BridgeDaemonAlive) }
        Remove-Item Env:\AGENT_BRIDGE_HOOKS_PUBLISH
    }
    finally { $env:TEMP = $realTemp }
}
finally {
    Remove-Item -LiteralPath $script:CodexStateRoot -Recurse -Force -ErrorAction SilentlyContinue
    $script:CodexStateRoot = $savedCodexRoot
    $script:CodexAdapterLoaded = $savedCodexLoaded
}

Write-Host '--- launch-card notes expire ---'
# Nothing else clears a note: "setting it up failed" stayed long after it was fixed.
$script:NoteState = $null
function Get-HomeAssistantState { param([string]$EntityId, [hashtable]$Headers) $script:NoteState }
$script:Notes = @()
$script:DaemonPendingLaunch = $null

$script:NoteState = [pscustomobject]@{ state = 'Copilot was found but setting it up failed'; last_changed = [DateTimeOffset]::Now.AddMinutes(-11).ToString('o') }
Clear-DaemonStaleNote -Headers $headers
Test-That 'a note older than ten minutes is cleared' { $script:Notes.Count -eq 1 -and $script:Notes[0] -eq '' }

$script:Notes = @()
$script:NoteState = [pscustomobject]@{ state = 'Launch failed: nope'; last_changed = [DateTimeOffset]::Now.AddMinutes(-2).ToString('o') }
Clear-DaemonStaleNote -Headers $headers
Test-That 'a recent note stays' { $script:Notes.Count -eq 0 }

$script:NoteState = [pscustomobject]@{ state = 'Press Launch again to trust this folder'; last_changed = [DateTimeOffset]::Now.AddMinutes(-30).ToString('o') }
$script:DaemonPendingLaunch = [pscustomobject]@{ SessionId = 'x' }
Clear-DaemonStaleNote -Headers $headers
Test-That 'a note for a launch still in progress stays, however old' { $script:Notes.Count -eq 0 }
$script:DaemonPendingLaunch = $null

$script:NoteState = [pscustomobject]@{ state = ''; last_changed = [DateTimeOffset]::Now.AddHours(-3).ToString('o') }
Clear-DaemonStaleNote -Headers $headers
Test-That 'an empty note is not cleared again' { $script:Notes.Count -eq 0 }

Write-Host ''
Write-Host '--- noticing PATH changes without a restart ---'

# Windows only: macOS has no stored machine or user PATH, and the LaunchAgent is given
# the installer's PATH instead.
if (-not $script:BridgeIsWindows) {
    $savedPath = $env:PATH
    Update-BridgeProcessPath -Force
    Test-That 'on macOS PATH is left exactly as it was' { $env:PATH -eq $savedPath }
}
else {
$savedPath = $env:Path
try {
    $env:Path = 'C:\only\this'
    Update-BridgeProcessPath -Force
    $parts = @($env:Path -split ';')
    Test-That 'entries the machine and user PATH gained are added' { $parts.Count -gt 1 }
    Test-That 'nothing already there is removed' { $parts[0] -eq 'C:\only\this' }
    $before = $env:Path
    Update-BridgeProcessPath -Force
    Test-That 'running it again adds no duplicates' { $env:Path -eq $before }
}
finally { $env:Path = $savedPath }
}

Remove-Item -LiteralPath $script:DaemonConfig.LogFile -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) test(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'all hook status checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
