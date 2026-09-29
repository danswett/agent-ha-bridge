#Requires -Version 7.0
<#
    Proves, on a real Mac, that the bridge can close a terminal window it opened -
    and only that one.

    The unit suite (tests/test-terminal-window.ps1) checks the AppleScript the bridge
    generates, with osascript stubbed. It cannot check that the AppleScript is
    *correct*, because that depends on Terminal's object model, and being wrong there
    fails in two ways that both matter: closing nothing, and closing a window that was
    not ours.

    So this opens two windows - one tagged as the bridge's, one standing in for a
    window of the user's - asks the bridge to close its own, and checks that exactly
    the right one went. Run it on the Mac:

        pwsh -NoProfile -File tests/verify-mac-terminal.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($IsWindows) { Write-Host 'SKIP: this only means anything on macOS'; exit 0 }

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\session-launch.ps1')

$failures = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:failures++ }
}

$mine = 'agent-bridge:verify-9911'
$yours = 'a window of my own'

function Count-Tabs {
    param([string]$Title)
    $script = @"
tell application "Terminal"
  set n to 0
  repeat with w in windows
    repeat with t in tabs of w
      try
        if custom title of t is "$Title" then set n to n + 1
      end try
    end repeat
  end repeat
  return n
end tell
"@
    [int]((& osascript -e $script 2>&1 | Out-String).Trim())
}

function Open-Tagged {
    <#
        A window in the state the bridge's really ends up in.

        The bridge's window runs `tmux attach`, which *returns* when the session is
        torn down, leaving a shell at a prompt - not a running command. The first
        version of this opened `sleep 120` instead, which leaves Terminal considering
        the window busy: a different case entirely, and one that made the close look
        broken when it was the test that was wrong. Both are covered below.
    #>
    param([string]$Title, [string]$Command = 'echo bridge-window-ready')
    $script = @"
tell application "Terminal"
  set t to do script "$Command"
  set custom title of t to "$Title"
end tell
"@
    & osascript -e $script 2>&1 | Out-Null
    Start-Sleep -Seconds 2
}

try {
    Write-Host '--- two windows: one the bridge opened, one the user did ---'
    Open-Tagged -Title $mine
    Open-Tagged -Title $yours
    $mineBefore = Count-Tabs -Title $mine
    $yoursBefore = Count-Tabs -Title $yours
    Write-Host "  before: bridge=$mineBefore  user=$yoursBefore"
    Check 'the bridge window opened' ($mineBefore -ge 1)
    Check "the user's window opened" ($yoursBefore -ge 1)

    Write-Host '--- the bridge closes its own ---'
    $closed = Close-BridgeTerminalWindow -Title $mine
    Start-Sleep -Seconds 2
    $mineAfter = Count-Tabs -Title $mine
    $yoursAfter = Count-Tabs -Title $yours
    Write-Host "  after : bridge=$mineAfter  user=$yoursAfter"

    Check 'it reports that it closed one' $closed
    Check 'the bridge window is gone' ($mineAfter -eq 0) "still $mineAfter"
    # The failure that would be much worse than the bug being fixed.
    Check "the user's window is untouched" ($yoursAfter -eq $yoursBefore) "was $yoursBefore, now $yoursAfter"

    Write-Host '--- and closing again is harmless ---'
    Check 'a second close finds nothing and says so' (-not (Close-BridgeTerminalWindow -Title $mine))
    Check 'an unknown tag closes nothing' (-not (Close-BridgeTerminalWindow -Title 'agent-bridge:never-existed'))
    Check "the user's window survived that too" ((Count-Tabs -Title $yours) -eq $yoursBefore)

    Write-Host '--- a window still running something closes too ---'
    # Not the usual case, but a session whose tmux did not tear down cleanly would
    # leave one, and Terminal treats a busy window differently: `saving no` is what
    # stops it stopping to ask.
    Open-Tagged -Title $mine -Command 'sleep 120'
    $busyBefore = Count-Tabs -Title $mine
    Check 'the busy window opened' ($busyBefore -ge 1)
    $busyClosed = Close-BridgeTerminalWindow -Title $mine
    Start-Sleep -Seconds 2
    $busyAfter = Count-Tabs -Title $mine
    Check 'it is closed without stopping to ask' ($busyClosed -and $busyAfter -eq 0) "closed=$busyClosed remaining=$busyAfter"
}
finally {
    # Take the stand-in away again whatever happened, so a failed run does not leave
    # a window sitting on the user's desktop.
    $cleanup = @"
tell application "Terminal"
  set doomed to {}
  repeat with w in windows
    repeat with t in tabs of w
      try
        if custom title of t is "$yours" or custom title of t is "$mine" then set end of doomed to w
      end try
    end repeat
  end repeat
  repeat with w in doomed
    try
      close w saving no
    end try
  end repeat
end tell
"@
    & osascript -e $cleanup 2>&1 | Out-Null
    Write-Host "  cleaned up; bridge=$(Count-Tabs -Title $mine) user=$(Count-Tabs -Title $yours)"
}

if ($failures -gt 0) { Write-Host "RESULT: $failures FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'RESULT: all passed' -ForegroundColor Green
