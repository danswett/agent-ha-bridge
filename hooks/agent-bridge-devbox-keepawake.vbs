' Runs one Dev Box keep-awake pass with no console window, ever.
'
' Same reasoning as agent-bridge-launch.vbs: WScript.Shell.Run with
' intWindowStyle = 0 starts the process with its window hidden from creation, so
' there is never a flashing console. That matters more here than for the daemon,
' because this task fires every few hours for the life of the install, and a window
' blinking on the desktop several times a day is exactly the kind of thing that
' gets a useful feature turned off.
'
' A refused start is handled the same way as there too, and for the same reason:
' this task also fires at logon, where a pending Microsoft Store update to
' PowerShell refuses pwsh with "Permission denied" for a while, and unhandled that
' is a Windows Script Host error dialog on the desktop. It is retried every 5
' seconds for 5 minutes - inside the task's 10-minute limit, and the next pass is
' never far off - and one that never succeeds is recorded in the keep-awake log
' and exits 1. Keep the two launchers in step.
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
attempts = CLng(Setting("attempts", 60))
interval = CLng(Setting("interval", 5000))

For attempt = 1 To attempts
    Err.Clear
    shell.Run """" & executable & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\agent-bridge-devbox-keepawake.ps1""", 0, False
    If Err.Number = 0 Then WScript.Quit 0
    failure = Describe(Err.Number, Err.Description)
    If attempt = 1 Then WriteLog "could not start " & executable & ": " & failure & "; trying again every " & (interval / 1000) & " s, up to " & (attempts - 1) & " more times"
    If attempt < attempts Then WScript.Sleep interval
Next
WriteLog "gave up: " & executable & " could not be started in " & attempts & " attempts (last: " & failure & "); the next scheduled pass will try again"
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

' Best effort, into the pass's own log under the installation's runtime directory. Never through
' a link, which the PowerShell side refuses as well (Assert-BridgeInstallPayload).
Sub WriteLog(message)
    On Error Resume Next
    Dim root, folder, path, stream
    root = fso.GetParentFolderName(here)
    folder = fso.BuildPath(root, "runtime")
    path = fso.BuildPath(folder, "agent-bridge-devbox-keepawake.log")
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

' Local time with its UTC offset, matching the PowerShell logs' [DateTimeOffset]::Now.ToString('o').
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
