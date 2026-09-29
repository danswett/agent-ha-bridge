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

function Remove-TaggedWindows {
    <#
        Clears anything left tagged from an earlier run.

        Without this the counts start above zero and every assertion below reads
        wrong - which is exactly what happened on the first attempt, where a failed
        run's leftovers made a working close look broken. Force-closes, because a
        leftover may well be busy.
    #>
    param([string[]]$Titles)
    foreach ($t in $Titles) {
        # Anything still running has to go first: `close saving no` suppresses the
        # save prompt, not the "terminate running processes?" one, so a busy window
        # will not close. Killing whatever is on the tab's tty makes it closable.
        # Only ever applied to windows carrying these test tags.
        $ttyScript = @"
tell application "Terminal"
  set found to {}
  repeat with w in windows
    repeat with tb in tabs of w
      try
        if custom title of tb is "$t" then set end of found to tty of tb
      end try
    end repeat
  end repeat
  set AppleScript's text item delimiters to " "
  return found as text
end tell
"@
        $ttys = (& osascript -e $ttyScript 2>&1 | Out-String).Trim()
        foreach ($tty in ($ttys -split '\s+' | Where-Object { $_ -match '^/dev/tty' })) {
            & pkill -t ([System.IO.Path]::GetFileName($tty)) 2>&1 | Out-Null
        }
        Start-Sleep -Milliseconds 400

        # Closed by id for the same reason the bridge does: the references
        # `repeat with w in windows` yields are positional, so closing one shifts
        # every later one onto a different window.
        $script = @"
tell application "Terminal"
  set doomed to {}
  repeat with w in windows
    repeat with tb in tabs of w
      try
        if custom title of tb is "$t" then
          set wid to id of w
          if doomed does not contain wid then set end of doomed to wid
        end if
      end try
    end repeat
  end repeat
  repeat with wid in doomed
    try
      close (first window whose id is wid) saving no
    end try
  end repeat
end tell
"@
        & osascript -e $script 2>&1 | Out-Null
    }
    Start-Sleep -Seconds 2
}

try {
    Write-Host '--- clearing anything left from an earlier run ---'
    Remove-TaggedWindows -Titles @($mine, $yours)
    $startMine = Count-Tabs -Title $mine
    $startYours = Count-Tabs -Title $yours
    Write-Host "  start: bridge=$startMine  user=$startYours"
    Check 'the slate is clean before anything is measured' (($startMine + $startYours) -eq 0) `
        "bridge=$startMine user=$startYours"

    Write-Host '--- two windows: one the bridge opened, one the user did ---'
    Open-Tagged -Title $mine
    Open-Tagged -Title $yours
    $mineBefore = Count-Tabs -Title $mine
    $yoursBefore = Count-Tabs -Title $yours
    Write-Host "  before: bridge=$mineBefore  user=$yoursBefore"
    Check 'the bridge window opened' ($mineBefore -eq 1) "got $mineBefore"
    Check "the user's window opened" ($yoursBefore -eq 1) "got $yoursBefore"

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

    Write-Host '--- several tagged windows all go, and only they ---'
    # The case that exposed the positional-reference bug: with one match, closing
    # `window 2` after `window 1` happens to be right, so a single window proves
    # nothing. Three, with windows of the user's interleaved, is what caught it.
    Open-Tagged -Title $yours
    Open-Tagged -Title $mine
    Open-Tagged -Title $yours
    Open-Tagged -Title $mine
    Open-Tagged -Title $mine
    $manyMine = Count-Tabs -Title $mine
    $manyYours = Count-Tabs -Title $yours
    Write-Host "  before: bridge=$manyMine  user=$manyYours"
    Check 'three bridge windows are open' ($manyMine -eq 3) "got $manyMine"
    $manyClosed = Close-BridgeTerminalWindow -Title $mine
    Start-Sleep -Seconds 2
    $manyMineAfter = Count-Tabs -Title $mine
    $manyYoursAfter = Count-Tabs -Title $yours
    Write-Host "  after : bridge=$manyMineAfter  user=$manyYoursAfter"
    Check 'it reports closing them' $manyClosed
    Check 'every bridge window is gone' ($manyMineAfter -eq 0) "still $manyMineAfter"
    Check "and none of the user's went with them" ($manyYoursAfter -eq $manyYours) `
        "was $manyYours, now $manyYoursAfter"

    Write-Host '--- a window still running something ---'
    # Not the state the bridge's window is ever in: it runs `tmux attach`, which has
    # returned by the time anything tries to close it. Reported rather than asserted,
    # because Terminal will not close a busy window and *that is the right answer* -
    # if something is still running in there, leaving it alone beats killing it.
    Open-Tagged -Title $mine -Command 'sleep 120'
    $busyBefore = Count-Tabs -Title $mine
    $busyClosed = Close-BridgeTerminalWindow -Title $mine
    Start-Sleep -Seconds 2
    $busyAfter = Count-Tabs -Title $mine
    Write-Host "  INFO  busy window: opened=$busyBefore closed=$busyClosed remaining=$busyAfter"
    Check 'a busy window is either closed or honestly reported as not closed' `
        (($busyClosed -and $busyAfter -eq 0) -or ((-not $busyClosed) -and $busyAfter -eq $busyBefore)) `
        "closed=$busyClosed before=$busyBefore after=$busyAfter"
}
finally {
    # Take the stand-ins away whatever happened, so a failed run does not leave
    # windows sitting on the user's desktop - and does not poison the next run.
    Remove-TaggedWindows -Titles @($mine, $yours)
    Write-Host "  cleaned up; bridge=$(Count-Tabs -Title $mine) user=$(Count-Tabs -Title $yours)"
}

if ($failures -gt 0) { Write-Host "RESULT: $failures FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'RESULT: all passed' -ForegroundColor Green
