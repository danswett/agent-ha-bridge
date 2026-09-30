#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the Windows/macOS layer (hooks/bridge-platform.ps1) and, where tmux is
    installed, for delivering replies into a session through it.

.DESCRIPTION
    Runs on both. The parsing and process checks run everywhere; the macOS-only parts
    (the Join-Path separator fix, $env:TEMP) are asserted only off Windows, and the
    tmux round trips only when tmux is present - they start a real detached session
    running a small shell script and check what it received.

    The tmux checks are what stand in for the Windows console injector's live tests:
    a reply is typed into the pane exactly as the daemon would, and the receiving
    script records it byte for byte - including characters a shell would act on, which
    must arrive as plain text.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'runner-support.ps1')
Assert-BridgeHostedTest -AllowHostTests:($env:AGENT_HA_BRIDGE_TEST_GROUP -eq 'Platform')

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($ok) { Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

# A throwaway config, so nothing reads the real one and no terminal window opens.
$scratch = Join-Path ([IO.Path]::GetTempPath()) "bridge-platform-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$env:AGENT_HA_BRIDGE_CONFIG = Join-Path $scratch 'config.json'
'{ "platform": { "terminal": "none" } }' | Set-Content -LiteralPath $env:AGENT_HA_BRIDGE_CONFIG

. (Join-Path $PSScriptRoot '../hooks/decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '../hooks/decision-inject.ps1')
. (Join-Path $PSScriptRoot '../hooks/session-launch.ps1')

Write-Host '--- parsing ps output ---'
$started = ConvertFrom-BridgeElapsedTime -Elapsed '05:10'
Test-That 'mm:ss is minutes and seconds ago' { [Math]::Abs(([DateTime]::Now - $started).TotalSeconds - 310) -lt 5 }
$started = ConvertFrom-BridgeElapsedTime -Elapsed '1-02:03:04'
Test-That 'dd-hh:mm:ss counts the days' { [Math]::Abs(([DateTime]::Now - $started).TotalSeconds - 93784) -lt 5 }

$line = ConvertFrom-BridgePsLine -Line '  4321   123   01:02:03 Google Chrome H'
Test-That 'a line gives pid, parent and name' { $line.ProcessId -eq 4321 -and $line.ParentProcessId -eq 123 }
Test-That 'a name with a space in it survives, being the last column' { $line.Name -eq 'Google Chrome H' }
Test-That 'a line that is not one gives nothing' { $null -eq (ConvertFrom-BridgePsLine -Line 'PID PPID ELAPSED UCOMM') }

Write-Host '--- this process ---'
$me = Get-BridgeProcessInfo -ProcessId $PID -WithCommandLine
Test-That 'this process is found' { $null -ne $me -and $me.ProcessId -eq $PID }
Test-That 'with its name' { ($me.Name -replace '\.exe$', '') -eq 'pwsh' } ([string]$me.Name)
Test-That 'its parent' { $me.ParentProcessId -gt 0 }
Test-That 'and its command line' { [string]$me.CommandLine -match 'pwsh' } ([string]$me.CommandLine)
Test-That 'a process that is not running gives nothing' { $null -eq (Get-BridgeProcessInfo -ProcessId 999999) }
Test-That 'pwsh processes are listed by name' {
    @(Get-BridgeProcessesNamed -Name 'pwsh' | Where-Object { $_.ProcessId -eq $PID }).Count -eq 1
}

Write-Host '--- recognising an agent''s CLI ---'
Test-That 'by name, with or without .exe' {
    (Test-BridgeAgentProcess -Process ([pscustomobject]@{ Name = 'claude.exe' }) -Agent 'claude') -and
        (Test-BridgeAgentProcess -Process ([pscustomobject]@{ ProcessName = 'codex' }) -Agent 'codex')
}
Test-That 'never a longer name that merely starts the same' {
    -not (Test-BridgeAgentProcess -Process ([pscustomobject]@{ ProcessName = 'copilotapp' }) -Agent 'copilot')
}
if (-not $script:BridgeIsWindows) {
    Test-That 'an npm CLI running under node, by its package' {
        Test-BridgeAgentProcess -Agent 'copilot' -Process ([pscustomobject]@{
            ProcessId = 1; Name = 'node'; CommandLine = 'node /opt/homebrew/lib/node_modules/@github/copilot/index.js' })
    }
    Test-That 'but not some other node program' {
        -not (Test-BridgeAgentProcess -Agent 'copilot' -Process ([pscustomobject]@{
            ProcessId = 1; Name = 'node'; CommandLine = 'node /Users/me/server.js' }))
    }
}

Write-Host '--- gathering an agent''s processes ---'
# The check above strips .exe, and passed from the day it was written - on a candidate
# it was never actually handed. Get-Process -Name is an exact match, and this gathered
# only 'claude' and 'node', so the claude.exe that Claude Code's Bun-compiled binary
# calls itself on macOS was never a candidate at all. Every Claude registration then
# read as dead and a live, answering session never got a card. Forced off the Windows
# branch so the real one is exercised wherever this runs.
$wasWindows = $script:BridgeIsWindows
$script:BridgeIsWindows = $false
$script:Asked = @()
$script:Running = @{ 'claude.exe' = [pscustomobject]@{ Id = 53859; ProcessName = 'claude.exe' } }
function Get-Process {
    param([string]$Name, $ErrorAction)
    $script:Asked += $Name
    if ($script:Running.ContainsKey($Name)) { $script:Running[$Name] }
}
$found = @(Get-BridgeAgentProcesses -Agent 'claude')
Test-That 'the .exe name is asked for as well as the bare one' {
    ($script:Asked -contains 'claude') -and ($script:Asked -contains 'claude.exe')
} ($script:Asked -join ',')
Test-That 'so a claude.exe process is found, not missed' {
    $found.Count -eq 1 -and [int]$found[0].Id -eq 53859
} "found $($found.Count)"
Test-That 'and bun is a candidate, so the check that accepts it can fire' {
    $script:Asked -contains 'bun'
} ($script:Asked -join ',')
Remove-Item function:Get-Process
$script:BridgeIsWindows = $wasWindows

Write-Host '--- finding the session a hook belongs to ---'
$script:Tree = @{
    30 = [pscustomobject]@{ ProcessId = 30; ParentProcessId = 20; Name = 'pwsh'; CommandLine = 'pwsh -File hook.ps1' }
    20 = [pscustomobject]@{ ProcessId = 20; ParentProcessId = 10; Name = 'claude'; CommandLine = 'claude' }
    10 = [pscustomobject]@{ ProcessId = 10; ParentProcessId = 1; Name = 'zsh'; CommandLine = '-zsh' }
}
function Get-BridgeProcessInfo { param([int]$ProcessId, [switch]$WithCommandLine) $script:Tree[$ProcessId] }
Test-That 'the walk up stops at the agent' { (Find-BridgeAgentAncestor -Agent 'claude' -StartPid 30) -eq 20 }
Test-That 'and gives 0 when there is none' { (Find-BridgeAgentAncestor -Agent 'codex' -StartPid 30) -eq 0 }
Remove-Item function:Get-BridgeProcessInfo
. (Join-Path $PSScriptRoot '../hooks/bridge-platform.ps1')

if (-not $script:BridgeIsWindows) {
    Write-Host '--- macOS paths ---'
    Test-That '$env:TEMP is set' { -not [string]::IsNullOrWhiteSpace($env:TEMP) -and (Test-Path -LiteralPath $env:TEMP) }
    Test-That 'Join-Path turns Windows separators into /' { (Join-Path '/tmp' '.agent-ha-bridge\hooks\x.ps1') -eq '/tmp/.agent-ha-bridge/hooks/x.ps1' }
    Test-That 'including in more child paths' { (Join-Path '/tmp' 'a' 'b\c') -eq '/tmp/a/b/c' }
    Test-That 'and from the pipeline' { (@('/x', '/y') | Join-Path -ChildPath 'z\w') -join ',' -eq '/x/z/w,/y/z/w' }
    Test-That 'the Windows-only launch folders are not looked up' { $null -eq (Find-BridgeUnixCommand -Name 'no-such-agent-cli') }
}

if (-not $script:BridgeIsWindows -and (Get-BridgeTmuxPath)) {
    Write-Host '--- typing into a session through tmux ---'
    $received = Join-Path $scratch 'received.txt'
    # Records each line it is sent, as typed, until told to stop.
    $receiver = Join-Path $scratch 'receiver.sh'
    @(
        '#!/bin/sh'
        'while IFS= read -r line; do'
        '  printf "%s\n" "$line" >> "$1"'
        '  [ "$line" = "quit" ] && exit 0'
        'done'
    ) -join "`n" | Set-Content -LiteralPath $receiver -NoNewline
    [IO.File]::SetUnixFileMode($receiver, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')

    $processId = 0
    try { $processId = Start-BridgeTmuxSession -Executable '/bin/sh' -Arguments @($receiver, $received) -WorkingDirectory $scratch -Name 'test' }
    catch { Write-Host "  (could not start: $($_.Exception.Message))" }
    Test-That 'a session starts in tmux and its process is known' { $processId -gt 0 -and (Get-Process -Id $processId -ErrorAction SilentlyContinue) }
    Test-That 'the process is found in its pane' { (Find-BridgeTmuxPane -ProcessId $processId) -match '^%\d+$' }
    Test-That 'a process outside tmux has no pane' { $null -eq (Find-BridgeTmuxPane -ProcessId $PID) }

    Start-Sleep -Milliseconds 300
    $r = Invoke-BridgeConsoleSend -ProcessId $processId -Text 'hello from the dashboard' -Submit $true -DelayMs 100
    Test-That 'a reply is typed and submitted' { $r -like 'ok:*' } $r
    $tricky = 'a; rm -rf $(whoami) `id` "q" ''s'' && | > <'
    $r = Invoke-BridgeConsoleSend -ProcessId $processId -Text $tricky -Submit $true -DelayMs 100
    Start-Sleep -Milliseconds 500
    # Wrapped whole: `$x = if ... { @(...) }` unrolls a one-line result to a string.
    $lines = @(if (Test-Path -LiteralPath $received) { Get-Content -LiteralPath $received })
    Test-That 'it arrives as typed' { $lines.Count -ge 1 -and $lines[0] -eq 'hello from the dashboard' } ($lines -join ' | ')
    Test-That 'shell characters in a reply arrive as plain text' { $lines.Count -ge 2 -and $lines[1] -eq $tricky } ($lines -join ' | ')
    Test-That 'a reply to a process outside tmux says so' { (Invoke-BridgeConsoleSend -ProcessId $PID -Text 'x' -Submit $true) -eq 'not-in-tmux' }

    $screen = Read-BridgeConsoleScreen -ProcessId $processId
    Test-That 'the session''s screen can be read' { $screen -match 'hello from the dashboard' } $screen

    [void](Invoke-BridgeConsoleSend -ProcessId $processId -Text 'quit' -Submit $true -DelayMs 50)
    Start-Sleep -Milliseconds 800
    Test-That 'the session ends with its process' { -not (Get-Process -Id $processId -ErrorAction SilentlyContinue) }
}
elseif (-not $script:BridgeIsWindows) {
    Write-Host '  (tmux not installed: skipping the tmux round trips)' -ForegroundColor Yellow
}

Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item Env:\AGENT_HA_BRIDGE_CONFIG -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All platform checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
