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

function Count-Modals {
    <#
        How many sheets or dialogs Terminal currently has up.

        The failure this guards is silent from the script's side: `close` on a busy
        window does not return an error, it raises a modal confirmation and waits.
        Counting them is the only way the check can tell "declined to close" from
        "asked a question nobody answered".
    #>
    $script = @'
tell application "Terminal"
  set n to 0
  repeat with w in windows
    try
      set n to n + (count of sheets of w)
    end try
  end repeat
  return n
end tell
'@
    $raw = (& osascript -e $script 2>&1 | Out-String).Trim()
    if ($raw -match '^\d+$') { return [int]$raw }
    0
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
        run's leftovers made a working close look broken.

        Unlike the bridge, this does kill what is running in the window first, by
        tty. It has to: a busy window cannot be closed without raising the modal
        confirmation, and these are the check's own stand-in windows with nothing in
        them but a sleep. The bridge never does this to a real session's window.
    #>
    param([string[]]$Titles)
    foreach ($pass in 1..2) {
    foreach ($t in $Titles) {
        # Anything still running has to go first: `close saving no` suppresses the
        # save prompt, not the "terminate running processes?" one, and that dialog is
        # modal - so a busy window cannot be closed from a script at all. Only ever
        # applied to windows carrying these test tags.
        $ttyScript = @"
tell application "Terminal"
  set out to ""
  repeat with w in windows
    repeat with tb in tabs of w
      try
        if custom title of tb is "$t" then set out to out & (tty of tb) & linefeed
      end try
    end repeat
  end repeat
  return out
end tell
"@
        # Accumulated with linefeed rather than joined through AppleScript's text item
        # delimiters: the delimiter version returned nothing usable, so no tty was
        # ever killed and the busy window survived cleanup with the failure invisible.
        $ttys = @((& osascript -e $ttyScript 2>&1 | Out-String) -split "`r?`n" |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^/dev/tty' })
        # Only what is running *in* the shell is killed, never the shell itself. A
        # window whose login shell has been killed is left showing "[Process
        # completed]" with no session behind it, and Terminal will not close one of
        # those from AppleScript at all - it reports success and the window stays.
        # That husk is what kept the slate dirty for run after run.
        $shells = @('login', 'bash', '-bash', 'zsh', '-zsh', 'sh', '-sh', 'tcsh', 'csh')
        $killed = @()
        foreach ($tty in $ttys) {
            $short = [System.IO.Path]::GetFileName($tty)
            foreach ($line in @(& ps -t $short -o pid=,comm= 2>$null)) {
                $parts = $line.Trim() -split '\s+', 2
                if ($parts.Count -lt 2 -or $parts[0] -notmatch '^\d+$') { continue }
                if ([int]$parts[0] -eq $PID) { continue }
                $name = [System.IO.Path]::GetFileName($parts[1])
                if ($shells -contains $name) { continue }
                & kill -9 $parts[0] 2>&1 | Out-Null
                $killed += "$($parts[0]):$name"
            }
        }
        if ($pass -eq 1) {
            Write-Host "  cleanup [$t]: ttys $(if ($ttys.Count) { $ttys -join ',' } else { '<none>' })" `
                "killed $(if ($killed.Count) { $killed -join ',' } else { '<none>' })"
        }
        Start-Sleep -Milliseconds 800

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
      close (window id wid) saving no
    end try
  end repeat
end tell
"@
        & osascript -e $script 2>&1 | Out-Null
    }
    Start-Sleep -Seconds 2
    }
}

try {
    Write-Host '--- clearing anything left from an earlier run ---'
    Write-Host "  dialogs waiting on screen before cleanup: $(Count-Modals)"
    Remove-TaggedWindows -Titles @($mine, $yours)
    $startMine = Count-Tabs -Title $mine
    $startYours = Count-Tabs -Title $yours
    Write-Host "  start: bridge=$startMine  user=$startYours  dialogs=$(Count-Modals)"
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

    Write-Host '--- a window still running something is left alone, not argued with ---'
    # The case that produced the real damage. macOS answers `close` on a busy window
    # with a modal "terminate running processes?" dialog rather than an error, so the
    # call sits there waiting for a click nobody is there to give, and every retry
    # stacks another dialog up behind it. Windows stayed open through repeated closes
    # because of this. A busy window must now be declined outright.
    Open-Tagged -Title $mine -Command 'sleep 120'
    $busyBefore = Count-Tabs -Title $mine
    Check 'the busy window opened' ($busyBefore -eq 1) "got $busyBefore"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $busyClosed = Close-BridgeTerminalWindow -Title $mine -SettleSeconds 2
    $sw.Stop()
    Start-Sleep -Seconds 2
    $busyAfter = Count-Tabs -Title $mine
    Write-Host "  busy window: closed=$busyClosed remaining=$busyAfter in $([int]$sw.Elapsed.TotalSeconds)s"
    Check 'it declines to close it' (-not $busyClosed) "closed=$busyClosed"
    Check 'and leaves it standing' ($busyAfter -eq $busyBefore) "was $busyBefore, now $busyAfter"
    # A dialog would hold the call open indefinitely; returning promptly is the proof
    # that none was raised.
    Check 'without hanging on a dialog' ($sw.Elapsed.TotalSeconds -lt 20) `
        "took $([int]$sw.Elapsed.TotalSeconds)s"
    Check 'and Terminal is left with nothing to answer' ((Count-Modals) -eq 0) `
        "$(Count-Modals) dialog(s) on screen"

    Write-Host '--- once what it was running ends, it goes ---'
    # Which is the bridge's own case: the window runs `tmux attach`, and that returns
    # when the session is torn down.
    #
    # The busy window from the case above is cleared first. Leaving it standing is
    # the correct outcome there, but it is still a tagged window, so counting
    # straight afterwards reads it as this case's failure - which is exactly what it
    # did, reporting a close that had in fact worked as broken.
    Remove-TaggedWindows -Titles @($mine)
    $settleStart = Count-Tabs -Title $mine
    Check 'the busy window is out of the way first' ($settleStart -eq 0) "still $settleStart"
    Open-Tagged -Title $mine -Command 'sleep 4'
    $settleClosed = Close-BridgeTerminalWindow -Title $mine -SettleSeconds 15
    Start-Sleep -Seconds 2
    $settleAfter = Count-Tabs -Title $mine
    Check 'it waits for the command to finish and then closes' ($settleClosed -and $settleAfter -eq 0) `
        "closed=$settleClosed remaining=$settleAfter"
}
finally {
    # Take the stand-ins away whatever happened, so a failed run does not leave
    # windows sitting on the user's desktop - and does not poison the next run.
    Remove-TaggedWindows -Titles @($mine, $yours)
    Write-Host "  cleaned up; bridge=$(Count-Tabs -Title $mine) user=$(Count-Tabs -Title $yours)"
}

if ($failures -gt 0) { Write-Host "RESULT: $failures FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'RESULT: all passed' -ForegroundColor Green
