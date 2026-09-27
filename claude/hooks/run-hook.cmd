@echo off
rem Runs one of the adapter's hook scripts under PowerShell 7.
rem
rem Claude Code runs hook commands through Git Bash on Windows, and Bash cannot
rem execute the Store PowerShell's execution alias (it fails with "Permission
rem denied"), while the versioned folder behind it disappears on every Store update.
rem cmd resolves `pwsh` the way Windows does - alias, MSI install or anything else on
rem PATH - so hooks keep working across PowerShell updates. Stdin, which carries the
rem hook event, passes straight through.
pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File %*
