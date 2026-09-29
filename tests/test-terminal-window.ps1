#Requires -Version 7.0
<#
.SYNOPSIS
    Ending a macOS session closes the window the bridge opened for it.

.DESCRIPTION
    A session ended from the dashboard left its Terminal window behind, sitting on a
    dead shell. The Windows path had always closed its console by ending the process
    that owned it, and the same block was expected to cover macOS - but there the pid
    the daemon holds is the tmux *pane's*, which is the agent itself. Killing it is
    what ending the session already did, so `$launcherPid -ne $processId` was never
    true and the branch never ran. The window is a separate Terminal window running
    `tmux attach`: when tmux tears the session down the attach returns, and the window
    stays.

    Nothing about that window identifies it, which is the whole difficulty. Its
    process is gone, and picking by "the frontmost window" or "any window that is not
    busy" would eventually close one of the user's with their work in it. So the
    window is tagged at launch with the pid it was opened for - known on both sides,
    unlike the session id, which Codex chooses only after the window is already open -
    and only a window carrying that tag is ever closed.

    These drive the real functions, with osascript stubbed so the generated AppleScript
    can be read: that script is the actual product here, and a test that only asserted
    "a close was attempted" would pass on a script that closed the wrong window, or
    every window.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $__ok = $false
    try { $__ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($__ok) { Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) "bridge-termwin-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$env:AGENT_HA_BRIDGE_CONFIG = Join-Path $scratch 'config.json'
'{ "homeAssistant": { "token": "t" } }' | Set-Content -LiteralPath $env:AGENT_HA_BRIDGE_CONFIG

try {
    . (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
    . (Join-Path $PSScriptRoot '..\hooks\session-launch.ps1')

    # Pretend to be a Mac, and capture what would have been sent to osascript.
    $script:BridgeIsWindows = $false
    $script:Sent = @()
    $script:OsascriptResult = '1'
    # No param block on purpose: with one, PowerShell tries to bind `-e` as a
    # parameter name and fails on the common-parameter prefix. The automatic $args
    # takes the switch and its value verbatim, which is what needs inspecting anyway.
    function osascript { $script:Sent += ($args -join ' '); $script:OsascriptResult }

    Write-Host "`n--- the tag both ends agree on ---"
    Test-That 'a window is tagged with the pid it was opened for' {
        (Get-BridgeTerminalWindowTitle -ProcessId 4321) -eq 'agent-bridge:4321'
    } (Get-BridgeTerminalWindowTitle -ProcessId 4321)
    Test-That 'two sessions never share a tag' {
        (Get-BridgeTerminalWindowTitle -ProcessId 1) -ne (Get-BridgeTerminalWindowTitle -ProcessId 2)
    }

    Write-Host "`n--- opening a window puts the tag on it ---"
    $script:Sent = @()
    Open-BridgeTerminalWindow -Command "'tmux' attach -t 'bridge-x'" -Title (Get-BridgeTerminalWindowTitle -ProcessId 999)
    $open = $script:Sent -join "`n"
    Test-That 'the command still runs' { $open -match [regex]::Escape("tmux' attach -t 'bridge-x") } $open
    Test-That 'and the tab carries the tag' { $open -match 'set custom title of t to "agent-bridge:999"' } $open
    # Without this the whole mechanism is untestable from the other end, and a failure
    # to tag would look exactly like a window that could not be found.
    Test-That 'the tag is set on the tab do script handed back, not on a guess' {
        $open -match 'set t to do script' -and $open -match 'custom title of t'
    } $open

    Write-Host "`n--- closing only ever touches a tagged window ---"
    $script:Sent = @()
    $closed = Close-BridgeTerminalWindow -Title 'agent-bridge:999'
    $close = $script:Sent -join "`n"
    Test-That 'a window is closed' { $closed }
    Test-That 'and it is matched on the tag' { $close -match 'custom title of t is "agent-bridge:999"' } $close
    # The failure that matters: a script that closes windows it has not matched.
    Test-That 'nothing is closed outside the matched set' {
        $close -match 'repeat with wid in doomed' -and $close -notmatch 'close every window'
    } $close
    Test-That 'the matched windows are collected before any is closed' {
        $close.IndexOf('set end of doomed') -lt $close.IndexOf('repeat with wid in doomed')
    }
    # Three tagged windows on a real Mac produced exactly one close. `repeat with w in
    # windows` yields positional references - `window 1`, `window 2` - so closing the
    # first shifts every later one down and the rest of the list points at whatever
    # moved into the slot, which could be a window of the user's.
    Test-That 'windows are remembered by id, not by their position in the list' {
        $close -match 'set wid to id of w' -and $close -match 'first window whose id is wid'
    } $close
    # A busy window is never handed to `close`. 'saving no' suppresses the save
    # prompt, not the "terminate running processes?" confirmation, and that one is
    # modal: closing a busy window hangs a dialog on the user's screen instead of
    # failing, and every later attempt queues another behind it. Seen on a real Mac,
    # where windows then stayed open through repeated closes.
    Test-That 'a busy window is waited for, not closed out from under whatever is running' {
        $close -match 'if \(busy of target\) is false then close target saving no'
    } $close
    Test-That 'and it is given time to go idle first, since tmux takes a moment to go' {
        $close -match '(?m)repeat \d+ times' -and $close -match 'if \(busy of target\) is false then exit repeat'
    } $close
    Test-That 'the settle time is the caller''s to set' {
        $script:Sent = @()
        [void](Close-BridgeTerminalWindow -Title 'agent-bridge:999' -SettleSeconds 1)
        ($script:Sent -join "`n") -match '(?m)repeat 2 times'
    } ($script:Sent -join "`n")
    $script:Sent = @()
    [void](Close-BridgeTerminalWindow -Title 'agent-bridge:999')
    $close = $script:Sent -join "`n"
    Test-That 'no positional reference is ever closed' {
        $close -notmatch 'close w saving no' -and $close -notmatch '(?m)^\s*close w\s*$'
    } $close
    Test-That 'a window matched by two of its tabs is only closed once' {
        $close -match 'doomed does not contain wid'
    } $close
    Test-That 'Terminal is not asked to confirm a window it thinks is busy' {
        $close -match 'close target saving no'
    } $close
    # A real Mac reported "closed one" while the window was still on screen: `close`
    # sits inside a `try`, so a close that fails is swallowed, and returning the
    # matched count called that success.
    Test-That 'what comes back is what actually went, counted by looking again' {
        $close -match 'set remaining to 0' -and $close -match '\(count of doomed\) - remaining'
    } $close

    Write-Host "`n--- and it stays out of the way when it should ---"
    $script:OsascriptResult = '0'
    Test-That 'no matching window means nothing was closed' {
        -not (Close-BridgeTerminalWindow -Title 'agent-bridge:12345')
    }
    $script:OsascriptResult = '1'
    $script:Sent = @()
    Test-That 'an empty tag closes nothing, rather than matching everything' {
        (-not (Close-BridgeTerminalWindow -Title '')) -and $script:Sent.Count -eq 0
    }
    $script:Sent = @()
    Test-That 'osascript failing is not fatal - a session must still end' {
        function osascript { throw 'no osascript here' }
        -not (Close-BridgeTerminalWindow -Title 'agent-bridge:1')
    }
    function osascript { $script:Sent += ($args -join ' '); $script:OsascriptResult }

    # platform.terminal: none means the bridge never opened a window, so there is
    # nothing of its own to close.
    $script:Sent = @()
    '{ "homeAssistant": { "token": "t" }, "platform": { "terminal": "none" } }' |
        Set-Content -LiteralPath $env:AGENT_HA_BRIDGE_CONFIG
    . (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
    . (Join-Path $PSScriptRoot '..\hooks\session-launch.ps1')
    $script:BridgeIsWindows = $false
    Test-That "with platform.terminal 'none' nothing is opened or closed" {
        Open-BridgeTerminalWindow -Command 'x' -Title 'agent-bridge:1'
        (-not (Close-BridgeTerminalWindow -Title 'agent-bridge:1')) -and $script:Sent.Count -eq 0
    } ($script:Sent -join '|')

    Write-Host "`n--- iTerm names its session instead ---"
    '{ "homeAssistant": { "token": "t" }, "platform": { "terminal": "iTerm" } }' |
        Set-Content -LiteralPath $env:AGENT_HA_BRIDGE_CONFIG
    . (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
    . (Join-Path $PSScriptRoot '..\hooks\session-launch.ps1')
    $script:BridgeIsWindows = $false
    $script:Sent = @()
    Open-BridgeTerminalWindow -Command 'run-me' -Title 'agent-bridge:77'
    [void](Close-BridgeTerminalWindow -Title 'agent-bridge:77')
    $iterm = $script:Sent -join "`n"
    Test-That 'iTerm tags the session it just created' { $iterm -match 'set name to "agent-bridge:77"' } $iterm
    Test-That 'and closes by that name' { $iterm -match 'if name of s is "agent-bridge:77"' } $iterm
    Test-That 'closing that window by id too' { $iterm -match 'first window whose id is wid' } $iterm
    Test-That 'never falling back to Terminal syntax' { $iterm -notmatch 'custom title' } $iterm

    Write-Host "`n--- on Windows this is not the mechanism ---"
    $script:BridgeIsWindows = $true
    $script:Sent = @()
    Test-That 'closing is a no-op, since a console dies with its process' {
        (-not (Close-BridgeTerminalWindow -Title 'agent-bridge:1')) -and $script:Sent.Count -eq 0
    }
}
finally {
    Remove-Item Env:\AGENT_HA_BRIDGE_CONFIG -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0) {
    Write-Host "`n$($script:Failures) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall passed" -ForegroundColor Green

