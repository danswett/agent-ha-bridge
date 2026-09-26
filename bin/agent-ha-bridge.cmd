@echo off
rem The PATH entry for the bridge. A .cmd shim rather than a PowerShell function or a
rem profile edit, so `agent-ha-bridge` works from cmd, from Windows PowerShell, from a
rem Run box and from any shell that only knows how to launch executables.
rem
rem pwsh is resolved at run time: the installer may have just installed it, in which
rem case this process's PATH predates it.
setlocal
set "BRIDGE_PWSH=pwsh.exe"
where /q pwsh.exe || set "BRIDGE_PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
"%BRIDGE_PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0agent-ha-bridge.ps1" %*
exit /b %ERRORLEVEL%
