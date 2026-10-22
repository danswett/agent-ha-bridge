' Launches the Copilot bridge supervisor with no console window, ever.
'
' WScript.Shell.Run with intWindowStyle = 0 starts the process with its window
' hidden from creation, so there is never a visible (or briefly flashing) console
' the way "pwsh -WindowStyle Hidden" launched directly by Task Scheduler can show.
' The supervisor then launches the daemon itself, also hidden, and the daemon keeps
' a real console (required for AttachConsole reply injection) - unlike
' "conhost --headless", which gives a pseudoconsole that breaks injection.
'
' Every error is handled here. An unhandled one is a modal Windows Script Host
' dialog on the desktop at logon, after which wscript exits 0, so the task reads as
' a success, and the bridge stays down until something else starts the task: its
' RestartCount covers only a task that cannot be launched at all, never an exit
' code. On DSWETT-ARM8 on 2026-10-22 that is what happened after a boot. The bridge
' keeps PowerShell running, so a Microsoft Store update to it cannot apply ("apps
' need to be closed", 0x80073D02) until the next logon - the moment this task
' fires - and until Windows had re-registered the package, under a minute later,
' starting pwsh failed with "Permission denied" (800A0046). So a refused start is
' retried every 5 seconds for 10 minutes, and one that never succeeds is recorded
' in the supervisor's log and exits 1, which the task shows as its last run result.
'
' /pwsh:, /attempts: and /interval: (milliseconds) are for tests; the scheduled
' task passes none of them.
Option Explicit
On Error Resume Next

Dim fso, shell, here, executable, attempts, interval, attempt, failure
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
here = fso.GetParentFolderName(WScript.ScriptFullName)
executable = Setting("pwsh", "pwsh.exe")
attempts = CLng(Setting("attempts", 120))
interval = CLng(Setting("interval", 5000))

For attempt = 1 To attempts
    Err.Clear
    shell.Run """" & executable & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\agent-bridge-supervisor.ps1""", 0, False
    If Err.Number = 0 Then WScript.Quit 0
    failure = Describe(Err.Number, Err.Description)
    If attempt = 1 Then WriteLog "could not start " & executable & ": " & failure & "; trying again every " & (interval / 1000) & " s, up to " & (attempts - 1) & " more times"
    If attempt < attempts Then WScript.Sleep interval
Next
WriteLog "gave up: " & executable & " could not be started in " & attempts & " attempts (last: " & failure & "). Run: agent-ha-bridge restart"
WScript.Quit 1

Function Setting(name, fallback)
    Setting = fallback
    If WScript.Arguments.Named.Exists(name) Then Setting = WScript.Arguments.Named.Item(name)
End Function

' As the Windows Script Host dialog shows it: "Permission denied [800A0046]".
Function Describe(number, description)
    Dim code
    If number > 0 And number < 65536 Then code = "800A" & Right("000" & Hex(number), 4) Else code = Hex(number)
    Describe = description & " [" & code & "]"
End Function

' Best effort, into the supervisor's own log under the installation's runtime
' directory, so that one file tells the whole story of a start. Never through
' a link, which the PowerShell side refuses as well (Assert-BridgeInstallPayload).
Sub WriteLog(message)
    On Error Resume Next
    Dim root, folder, path, stream
    root = fso.GetParentFolderName(here)
    folder = fso.BuildPath(root, "runtime")
    path = fso.BuildPath(folder, "agent-bridge-supervisor.log")
    If Not fso.FolderExists(folder) Then Exit Sub
    If Linked(root) Or Linked(folder) Or Linked(path) Then Exit Sub
    Set stream = fso.OpenTextFile(path, 8, True)
    stream.WriteLine Timestamp() & " launcher: " & message
    stream.Close
End Sub

' True for a reparse point (a junction or symbolic link), and when it cannot tell.
Function Linked(path)
    On Error Resume Next
    Linked = True
    If fso.FolderExists(path) Then
        Linked = (fso.GetFolder(path).Attributes And 1024) <> 0
    ElseIf fso.FileExists(path) Then
        Linked = (fso.GetFile(path).Attributes And 1024) <> 0
    Else
        Linked = False
    End If
End Function

' Local time with its UTC offset, matching the supervisor's [DateTimeOffset]::Now.ToString('o').
Function Timestamp()
    On Error Resume Next
    Dim moment, bias, offset
    moment = Now
    Timestamp = Year(moment) & "-" & Pad(Month(moment)) & "-" & Pad(Day(moment)) & "T" & Pad(Hour(moment)) & ":" & Pad(Minute(moment)) & ":" & Pad(Second(moment))
    bias = shell.RegRead("HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation\ActiveTimeBias")
    If Err.Number <> 0 Then Exit Function
    If bias > 2147483647 Then bias = bias - 4294967296
    offset = -bias
    If offset < 0 Then Timestamp = Timestamp & "-" Else Timestamp = Timestamp & "+"
    Timestamp = Timestamp & Pad(Abs(offset) \ 60) & ":" & Pad(Abs(offset) Mod 60)
End Function

Function Pad(value)
    Pad = Right("0" & value, 2)
End Function
