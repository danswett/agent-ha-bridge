#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the hook bodies as functions (claude-hooks.ps1, codex-hooks.ps1,
    copilot-hooks.ps1) and for finding a session's process from a recorded chain.

.DESCRIPTION
    The daemon will run these for events the native hook spools to it (see
    docs/fast-hooks.md), after the hook has exited: the owning process is then found
    from the ancestors the hook recorded, and the shells in between have gone. Every
    Home Assistant call and every file write is replaced by a recorder here.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Join-Path $PSScriptRoot '..'
. (Join-Path $repo 'hooks/bridge-platform.ps1')
. (Join-Path $repo 'hooks/decision-bridge-common.ps1')
. (Join-Path $repo 'hooks/decision-mqtt.ps1')
. (Join-Path $repo 'hooks/bridge-adapter.ps1')
. (Join-Path $repo 'claude/hooks/claude-ask-parser.ps1')
. (Join-Path $repo 'claude/hooks/claude-session.ps1')
. (Join-Path $repo 'claude/hooks/claude-hooks.ps1')
. (Join-Path $repo 'codex/hooks/codex-session.ps1')
. (Join-Path $repo 'codex/hooks/codex-hooks.ps1')
. (Join-Path $repo 'hooks/copilot-hooks.ps1')

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

# A process table: 10 the hook, 20 a shell that has since exited, 30 claude, 40 the
# terminal. 50 a codex app-server under 60, a codex window.
$script:Processes = @{
    10 = [pscustomobject]@{ ProcessId = 10; ParentProcessId = 20; Name = 'pwsh.exe'; Path = '' }
    30 = [pscustomobject]@{ ProcessId = 30; ParentProcessId = 40; Name = 'claude.exe'; Path = '' }
    40 = [pscustomobject]@{ ProcessId = 40; ParentProcessId = 1; Name = 'WindowsTerminal.exe'; Path = '' }
    50 = [pscustomobject]@{ ProcessId = 50; ParentProcessId = 60; Name = 'codex.exe'; Path = 'C:\x\app-server-daemon\codex.exe' }
    60 = [pscustomobject]@{ ProcessId = 60; ParentProcessId = 40; Name = 'codex.exe'; Path = 'C:\x\bin\codex.exe' }
}
function Get-BridgeProcessInfo { param([int]$ProcessId, [switch]$WithCommandLine) $script:Processes[$ProcessId] }

Write-Host '--- finding the owner from a recorded chain ---'
Test-That 'a shell that has exited is skipped, not the end of the walk' { (Find-BridgeAgentAncestor -Agent 'claude' -Ancestors @(10, 20, 30, 40)) -eq 30 }
Test-That 'a chain with no agent in it gives 0' { (Find-BridgeAgentAncestor -Agent 'codex' -Ancestors @(10, 20, 30, 40)) -eq 0 }
Test-That 'Claude''s lookup uses the chain' { (Get-ClaudeOwningProcessId -Ancestors @(20, 30)) -eq 30 }
Test-That 'a live walk still stops at an exited process, as before' { (Find-BridgeAgentAncestor -Agent 'claude' -StartPid 10) -eq 0 }
function Test-CodexWindowClaimed { param([int]$ProcessId, [string]$SessionId) $false }
Test-That 'Codex walks past its app-server to the window' { (Get-CodexOwningProcessId -SessionId 's' -Ancestors @(10, 20, 50, 60)) -eq 60 }

Write-Host '--- Claude ---'
$script:Registered = @()
function Write-ClaudeSessionRegistration { param($SessionId, $TranscriptPath, $WorkingDirectory, $ProcessId, $Status) $script:Registered += [pscustomobject]@{ Id = $SessionId; Pid = $ProcessId; Status = $Status }; 'written' }
function Resolve-ClaudeTranscriptPath { param($SessionId, $KnownPath) $KnownPath }
$script:Reachable = $false
function Enter-BridgeAdapterSession { if ($script:Reachable) { @{ Authorization = 'Bearer t' } } else { $null } }
function Write-DecisionBridgeLog { param([string]$Message) }

$out = Invoke-ClaudeRegisterHook -HookEvent ([pscustomobject]@{ session_id = 'c1'; transcript_path = 't'; cwd = 'w'; hook_event_name = 'UserPromptSubmit' }) -Ancestors @(20, 30)
Test-That 'a prompt registers the session as working, owned by claude' { $script:Registered[-1].Pid -eq 30 -and $script:Registered[-1].Status -eq 'working' }
Test-That 'and writes nothing Claude would see' { $null -eq $out }
$null = Invoke-ClaudeRegisterHook -HookEvent ([pscustomobject]@{ session_id = 'c1'; transcript_path = 't'; cwd = 'w'; hook_event_name = 'SessionStart' }) -Ancestors @(30)
Test-That 'SessionStart records no status' { $script:Registered[-1].Status -eq '' }
$script:Registered = @()
$null = Invoke-ClaudeRegisterHook -HookEvent ([pscustomobject]@{ session_id = ''; hook_event_name = 'SessionStart' })
Test-That 'an event without a session is ignored' { $script:Registered.Count -eq 0 }

$out = Invoke-ClaudeStopHook -HookEvent ([pscustomobject]@{ session_id = 'c1'; transcript_path = 't'; cwd = 'w'; last_assistant_message = 'done' }) -Ancestors @(30)
Test-That 'Stop marks it idle even with Home Assistant away, and says nothing' { $script:Registered[-1].Status -eq 'idle' -and $null -eq $out }

$script:Markers = @()
function Write-CopilotDecisionMarker { param($SessionId, $DecisionId, $Question, $Choices, $Combos, $Fields, $Mode, [switch]$TerminalOnly, $ToolCallId) $script:Markers += [pscustomobject]@{ Question = $Question; ToolCallId = $ToolCallId } }
$ask = [pscustomobject]@{
    session_id = 'c1'; transcript_path = 't'; cwd = 'w'; tool_name = 'AskUserQuestion'; tool_use_id = 'tu1'
    tool_input = [pscustomobject]@{ questions = @([pscustomobject]@{ question = 'Which?'; header = 'Pick'; multiSelect = $false; options = @([pscustomobject]@{ label = 'A' }, [pscustomobject]@{ label = 'B' }) }) }
}
$out = Invoke-ClaudeAskHook -HookEvent $ask -Ancestors @(30)
Test-That 'a question leaves a marker for the daemon before touching the network' { $script:Markers.Count -eq 1 -and $script:Markers[0].ToolCallId -eq 'tu1' -and $null -eq $out }
$script:Markers = @()
$ask.tool_name = 'Bash'
$null = Invoke-ClaudeAskHook -HookEvent $ask
Test-That 'any other tool is ignored' { $script:Markers.Count -eq 0 }

# A multi-select question is answered in the terminal: the daemon refuses to inject
# one. The card used to be armed with working dropdowns all the same, so it looked
# answerable and silently was not - every Send was dropped at the daemon's
# terminal-only check with nothing said on the card.
function Write-CopilotDecisionMarker { param($SessionId, $DecisionId, $Question, $Choices, $Combos, $Fields, $Mode, [switch]$TerminalOnly, $ToolCallId) $script:Markers += [pscustomobject]@{ Question = $Question; Choices = @($Choices); Fields = @($Fields); TerminalOnly = [bool]$TerminalOnly } }
$script:Published = @()
function Get-ClaudeSessionDisplay { param($SessionId, $WorkingDirectory) [pscustomobject]@{ Name = 'Claude: t'; Machine = 'M' } }
function Confirm-BridgeSessionEntities { param($SessionId, $SessionName, $Machine, $Headers, $ProbeEntity) $true }
function Set-CopilotMqttDecision { param($SessionId, $SessionName, $Machine, $Question, $Choices, $Fields, $DecisionId, $Headers) $script:Published += [pscustomobject]@{ Question = $Question; Choices = @($Choices); Fields = @($Fields) } }
function Send-BridgeNotification { param($Title, $Message, $Headers) $script:Notified += $Message }
function Format-BridgeNotificationTitle { param($Name) $Name }
$script:Reachable = $true

$script:Markers = @(); $script:Published = @(); $script:Notified = @()
$multiAsk = [pscustomobject]@{
    session_id = 'c1'; transcript_path = 't'; cwd = 'w'; tool_name = 'AskUserQuestion'; tool_use_id = 'tu2'
    tool_input = [pscustomobject]@{ questions = @(
        [pscustomobject]@{ question = 'Which database?'; header = 'Database'; multiSelect = $false; options = @([pscustomobject]@{ label = 'PostgreSQL' }, [pscustomobject]@{ label = 'SQLite' }) }
        [pscustomobject]@{ question = 'Which features?'; header = 'Features'; multiSelect = $true; options = @([pscustomobject]@{ label = 'Auth' }, [pscustomobject]@{ label = 'Billing' }) }
    ) }
}
$null = Invoke-ClaudeAskHook -HookEvent $multiAsk -Ancestors @(30)
Test-That 'a multi-select question is now answerable from the card' { -not $script:Markers[-1].TerminalOnly }
Test-That 'its field is passed through as multi-select' {
    Test-DecisionFieldIsMultiSelect -Field (@($script:Published[-1].Fields)[1])
}
Test-That 'the single-select field is untouched' {
    (@($script:Published[-1].Fields)[0].Options -join ',') -eq 'PostgreSQL,SQLite'
}
Test-That 'the marker keeps the real options for the keystrokes' {
    (@($script:Markers[-1].Fields)[1].Options -join ',') -eq 'Auth,Billing'
}
Test-That 'and nothing is sent to the terminal' { $script:Published[-1].Question -notmatch 'Answer this one in the terminal' }

# Too many options to list every combination: back to the terminal, and said so.
$script:Markers = @(); $script:Published = @(); $script:Notified = @()
$wideAsk = [pscustomobject]@{
    session_id = 'c1'; transcript_path = 't'; cwd = 'w'; tool_name = 'AskUserQuestion'; tool_use_id = 'tu9'
    tool_input = [pscustomobject]@{ questions = @(
        [pscustomobject]@{ question = 'Which?'; header = 'Many'; multiSelect = $true; options = @(
            [pscustomobject]@{ label = 'A' }, [pscustomobject]@{ label = 'B' }, [pscustomobject]@{ label = 'C' },
            [pscustomobject]@{ label = 'D' }, [pscustomobject]@{ label = 'E' }, [pscustomobject]@{ label = 'F' },
            [pscustomobject]@{ label = 'G' }) }
    ) }
}
$null = Invoke-ClaudeAskHook -HookEvent $wideAsk -Ancestors @(30)
Test-That 'too many combinations falls back to the terminal' { $script:Markers[-1].TerminalOnly }
Test-That 'and the card says which limit it hit' { $script:Published[-1].Question -match 'more combinations than the dashboard can list' } $script:Published[-1].Question
Test-That 'with no dropdown published' { $script:Published[-1].Fields.Count -eq 0 -and $script:Published[-1].Choices.Count -eq 0 }

# One multi-select question shows a single dropdown, so the combinations go there.
$script:Markers = @(); $script:Published = @(); $script:Notified = @()
$soloAsk = [pscustomobject]@{
    session_id = 'c1'; transcript_path = 't'; cwd = 'w'; tool_name = 'AskUserQuestion'; tool_use_id = 'tu8'
    tool_input = [pscustomobject]@{ questions = @(
        [pscustomobject]@{ question = 'Which features?'; header = 'Features'; multiSelect = $true; options = @(
            [pscustomobject]@{ label = 'Auth' }, [pscustomobject]@{ label = 'Billing' }) }
    ) }
}
$null = Invoke-ClaudeAskHook -HookEvent $soloAsk -Ancestors @(30)
Test-That 'a lone multi-select question offers combinations on the main selector' {
    ($script:Published[-1].Choices -join ' / ') -eq 'Auth / Billing / Auth + Billing'
} ($script:Published[-1].Choices -join ' / ')
# Written out, never as positions. Copilot's cards carry a set as '#1,3' because they
# draw their own checkboxes and only use the slot to hold the answer; here the
# combinations are the rows somebody reads and chooses between, so a position would be
# a row of gibberish. The two clients are separate contracts and must stay so.
Test-That 'and never as the positions the Copilot slot carries' {
    @($script:Published[-1].Choices | Where-Object { $_ -match '^#' }).Count -eq 0
} ($script:Published[-1].Choices -join ' / ')
Test-That 'and is not sent to the terminal' { -not $script:Markers[-1].TerminalOnly }

$script:Markers = @(); $script:Published = @(); $script:Notified = @()
$driveable = [pscustomobject]@{
    session_id = 'c1'; transcript_path = 't'; cwd = 'w'; tool_name = 'AskUserQuestion'; tool_use_id = 'tu3'
    tool_input = [pscustomobject]@{ questions = @(
        [pscustomobject]@{ question = 'Which database?'; header = 'Database'; multiSelect = $false; options = @([pscustomobject]@{ label = 'PostgreSQL' }, [pscustomobject]@{ label = 'SQLite' }) }
        [pscustomobject]@{ question = 'Deploy now?'; header = 'Deploy'; multiSelect = $false; options = @([pscustomobject]@{ label = 'Yes' }, [pscustomobject]@{ label = 'No' }) }
    ) }
}
$null = Invoke-ClaudeAskHook -HookEvent $driveable -Ancestors @(30)
Test-That 'a single-select form still gets its dropdowns' { -not $script:Markers[-1].TerminalOnly -and $script:Published[-1].Fields.Count -eq 2 } "fields=$($script:Published[-1].Fields.Count)"
Test-That 'and is not told to go to the terminal' { $script:Published[-1].Question -notmatch 'Answer this one in the terminal' }
Test-That 'its push still offers both inputs' { $script:Notified[-1] -match 'Answer in the terminal or on the dashboard\.' }
$script:Reachable = $false

$script:Registered = @()
$null = Invoke-ClaudeNotificationHook -HookEvent ([pscustomobject]@{ session_id = 'c1'; transcript_path = 't'; cwd = 'w'; notification_type = 'permission_prompt'; message = 'Claude needs your permission to use Bash' }) -Ancestors @(30)
Test-That 'a permission notification marks it waiting' { $script:Registered[-1].Status -eq 'waiting' -and $script:Registered[-1].Pid -eq 30 }

Write-Host '--- Codex ---'
$script:CodexRegistered = @()
function Write-CodexSessionRegistration { param($SessionId, $TranscriptPath, $WorkingDirectory, $Model, $Status, $Activity, $ProcessId, [switch]$Ended) $script:CodexRegistered += [pscustomobject]@{ Status = $Status; Activity = $Activity; Pid = $ProcessId; Ended = [bool]$Ended }; 'written' }
function Test-BridgeDaemonAlive { $true }
$out = Invoke-CodexHook -HookEvent ([pscustomobject]@{ session_id = 'x1'; hook_event_name = 'PreToolUse'; cwd = 'w'; tool_name = 'shell'; tool_input = [pscustomobject]@{ command = 'ls' } }) -Ancestors @(10, 20, 50, 60)
Test-That 'a tool call is recorded for the daemon to publish, owned by the window' {
    $script:CodexRegistered[-1].Status -eq 'working' -and $script:CodexRegistered[-1].Activity -eq 'Running: shell - ls' -and $script:CodexRegistered[-1].Pid -eq 60
}
Test-That 'and says nothing' { $null -eq $out }
$null = Invoke-CodexHook -HookEvent ([pscustomobject]@{ session_id = 'x1'; hook_event_name = 'SessionEnd'; cwd = 'w' }) -Ancestors @(60)
Test-That 'SessionEnd marks the registration ended' { $script:CodexRegistered[-1].Ended }
$count = $script:CodexRegistered.Count
$null = Invoke-CodexHook -HookEvent ([pscustomobject]@{ session_id = 'x1'; hook_event_name = 'SomethingNew'; cwd = 'w' })
Test-That 'an event it does not know is ignored' { $script:CodexRegistered.Count -eq $count }

Write-Host '--- Copilot ---'
# The hooks run without strict mode, and the shared ask_user parser relies on that (a
# missing property reads as $null), so these run as the hook does. The daemon's spool
# dispatch turns strict mode off around each hook function for the same reason.
Set-StrictMode -Off
$script:Reachable = $false
$script:Markers = @()
$out = Invoke-CopilotAskUserHook -HookEvent ([pscustomobject]@{ sessionId = 's1'; cwd = 'w'; timestamp = 1; toolArgs = [pscustomobject]@{ question = 'Pick'; choices = @('A', 'B') } })
Test-That 'ask_user with Home Assistant away retains its marker and leaves the native reply to the script' {
    $null -eq $out -and $script:Markers.Count -eq 1 -and
    $script:Markers[0].Question -ceq 'Pick' -and
    ($script:Markers[0].Choices -join '|') -ceq 'A|B' -and -not $script:Markers[0].TerminalOnly
}
$script:Sent = @()
function Send-BridgeNotification { param($Title, $Message, $Headers) $script:Sent += $Title }
function Get-HomeAssistantHeaders { @{ Authorization = 'Bearer t' } }
$out = Invoke-CopilotPermissionHook -HookEvent ([pscustomobject]@{ notification_type = 'permission_prompt'; title = ''; message = '' })
Test-That 'a permission prompt is pushed with a sensible title' { ($script:Sent -join ',') -eq 'Copilot permission needed' -and $null -eq $out }

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All hook function checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
