' Runs one Dev Box keep-awake pass with no console window, ever.
'
' Same reasoning as agent-bridge-launch.vbs: WScript.Shell.Run with
' intWindowStyle = 0 starts the process with its window hidden from creation, so
' there is never a flashing console. That matters more here than for the daemon,
' because this task fires every few hours for the life of the install, and a window
' blinking on the desktop several times a day is exactly the kind of thing that
' gets a useful feature turned off.
Dim fso, shell, here
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
here = fso.GetParentFolderName(WScript.ScriptFullName)
shell.Run "pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\agent-bridge-devbox-keepawake.ps1""", 0, False
