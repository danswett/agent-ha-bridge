# Temporary diagnostic (not part of the suite): dumps Terminal's window/tab
# inventory and tries closing each tagged window with the error left visible.
$tag = 'agent-bridge:verify-9911'

$inventory = @'
tell application "Terminal"
  set out to ""
  repeat with i from 1 to (count of windows)
    set w to window i
    set wid to "?"
    try
      set wid to (id of w) as text
    end try
    set wb to "?"
    try
      set wb to (busy of w) as text
    end try
    set wv to "?"
    try
      set wv to (visible of w) as text
    end try
    set wm to "?"
    try
      set wm to (miniaturized of w) as text
    end try
    set wn to "?"
    try
      set wn to name of w
    end try
    set out to out & "WIN idx=" & i & " id=" & wid & " busy=" & wb & " vis=" & wv & " min=" & wm & " name=[" & wn & "]" & linefeed
    try
      repeat with t in tabs of w
        set ct to "<none>"
        try
          set ct to custom title of t
        end try
        set tb to "?"
        try
          set tb to (busy of t) as text
        end try
        set tt to "?"
        try
          set tt to tty of t
        end try
        set pr to ""
        try
          set pr to (processes of t) as text
        end try
        set out to out & "   TAB title=[" & ct & "] busy=" & tb & " tty=" & tt & " procs=[" & pr & "]" & linefeed
      end repeat
    end try
  end repeat
  return out
end tell
'@

Write-Host '=== inventory ==='
(& osascript -e $inventory 2>&1 | Out-String).Trim() | Write-Host

$idScript = @"
tell application "Terminal"
  set out to ""
  repeat with w in windows
    repeat with t in tabs of w
      try
        if custom title of t is "$tag" then set out to out & (id of w) & linefeed
      end try
    end repeat
  end repeat
  return out
end tell
"@
$ids = @((& osascript -e $idScript 2>&1 | Out-String) -split "`r?`n" |
    ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })
Write-Host "=== tagged window ids: $($ids -join ',') ==="

foreach ($wid in $ids) {
    # Deliberately no try: the point is to surface the error AppleScript would hide.
    $byId = @"
tell application "Terminal"
  close (window id $wid) saving no
  return "close window id $wid returned"
end tell
"@
    Write-Host "  close id=$wid -> $((& osascript -e $byId 2>&1 | Out-String).Trim())"
    Start-Sleep -Seconds 3
}

Write-Host '=== inventory after ==='
Start-Sleep -Seconds 2
(& osascript -e $inventory 2>&1 | Out-String).Trim() | Write-Host

# A window whose shell has been killed has no session behind it; if Terminal will not
# close one from AppleScript, clicking its close button is the remaining option - and
# needs Accessibility permission, which this reports on rather than assumes.
$stillThere = @((& osascript -e $idScript 2>&1 | Out-String) -split "`r?`n" |
    ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })
if ($stillThere.Count) {
    Write-Host "=== $($stillThere.Count) still there; trying the close button ==="
    $click = @"
tell application "System Events"
  tell process "Terminal"
    repeat with w in windows
      try
        if name of w contains "$tag" then click button 1 of w
      end try
    end repeat
  end tell
end tell
"@
    Write-Host "  click -> $((& osascript -e $click 2>&1 | Out-String).Trim())"
    Start-Sleep -Seconds 2
    $after = @((& osascript -e $idScript 2>&1 | Out-String) -split "`r?`n" |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })
    Write-Host "  remaining after click: $($after.Count)"
}
