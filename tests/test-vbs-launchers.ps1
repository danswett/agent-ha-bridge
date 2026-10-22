#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the Windows Script Host launchers the scheduled tasks run:
    hooks/agent-bridge-launch.vbs, which starts the supervisor at logon, and
    hooks/agent-bridge-devbox-keepawake.vbs, which starts each keep-awake pass.

.DESCRIPTION
    Both were a bare WScript.Shell.Run of pwsh.exe. On 2026-10-22 a Microsoft Store
    update to PowerShell, held back for a week because the bridge keeps pwsh running,
    was applied at logon just as the task fired, and starting pwsh failed with
    "Permission denied" (800A0046) for under a minute. Unhandled, that was a Windows
    Script Host error dialog at boot and no bridge - and wscript still exited 0, so
    nothing tried again.

    Each launcher is copied into a throwaway installation beside a stub of the script
    it starts, and run by the real script host. cscript rather than wscript, because
    it writes an unhandled error to its output where wscript would block on a dialog;
    the script engine is the same. The refusal is real as well: a copy of a system
    executable this account is denied permission to execute, which Run reports
    exactly as it reported the Store package.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

$cscript = if ($IsWindows -and $env:SystemRoot) { Join-Path $env:SystemRoot 'System32\cscript.exe' } else { '' }
if (-not $cscript -or -not (Test-Path -LiteralPath $cscript)) {
    Write-Host '  SKIP  the Windows Script Host launchers: there is no script host on this platform' -ForegroundColor Yellow
    exit 0
}

function Start-Launcher {
    param([Parameter(Mandatory)][string]$Path, [string[]]$Arguments = @())
    $start = [Diagnostics.ProcessStartInfo]::new($cscript)
    foreach ($argument in @('//NoLogo', $Path) + $Arguments) { $start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    [Diagnostics.Process]::Start($start)
}

function Wait-Launcher {
    param([Parameter(Mandatory)][Diagnostics.Process]$Process)
    try {
        if (-not $Process.WaitForExit(60000)) {
            $Process.Kill()
            return [pscustomobject]@{ ExitCode = 'still running after 60 s'; Output = '' }
        }
        [pscustomobject]@{
            ExitCode = $Process.ExitCode
            Output   = ($Process.StandardOutput.ReadToEnd() + $Process.StandardError.ReadToEnd()).Trim()
        }
    }
    finally { $Process.Dispose() }
}

function Wait-Until {
    param([Parameter(Mandatory)][scriptblock]$Condition)
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (-not (& $Condition)) {
        if ([DateTime]::UtcNow -ge $deadline) { return $false }
        Start-Sleep -Milliseconds 100
    }
    $true
}

function Read-LauncherLog {
    param([Parameter(Mandatory)][string]$Path)
    try { if (Test-Path -LiteralPath $Path) { return [string](Get-Content -LiteralPath $Path -Raw) } }
    catch { }
    ''
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) "vbs-launchers-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
[void][IO.Directory]::CreateDirectory($sandbox)

try {
    $probe = Join-Path $sandbox 'probe.vbs'
    Set-Content -LiteralPath $probe -Value 'WScript.Quit 7' -Encoding ascii
    $probeRun = Wait-Launcher (Start-Launcher -Path $probe)
    if ($probeRun.ExitCode -ne 7) {
        Write-Host "  SKIP  the Windows Script Host launchers: VBScript does not run here ($($probeRun.Output))" -ForegroundColor Yellow
        exit 0
    }

    $deniedPwsh = Join-Path $sandbox 'bin\pwsh.exe'
    [void][IO.Directory]::CreateDirectory((Split-Path $deniedPwsh -Parent))
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\whoami.exe') -Destination $deniedPwsh
    $denial = [Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent().User, 'ExecuteFile', 'Deny')
    function Set-PwshDenied {
        param([bool]$Denied)
        $acl = Get-Acl -LiteralPath $deniedPwsh
        if ($Denied) { $acl.AddAccessRule($denial) } else { [void]$acl.RemoveAccessRule($denial) }
        Set-Acl -LiteralPath $deniedPwsh -AclObject $acl
    }

    function New-LauncherInstall {
        param([Parameter(Mandatory)]$Launcher)
        $root = Join-Path $sandbox ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $hooks = Join-Path $root 'hooks'
        [void][IO.Directory]::CreateDirectory($hooks)
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'runtime'))
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "..\hooks\$($Launcher.File)") -Destination $hooks
        Set-Content -LiteralPath (Join-Path $hooks $Launcher.Starts) `
            -Value 'Set-Content -LiteralPath (Join-Path $PSScriptRoot "started.txt") -Value started'
        [pscustomobject]@{
            Launcher = Join-Path $hooks $Launcher.File
            Started  = Join-Path $hooks 'started.txt'
            Log      = Join-Path $root "runtime\$($Launcher.Log)"
        }
    }

    $launchers = @(
        [pscustomobject]@{ Name = 'the daemon launcher'; File = 'agent-bridge-launch.vbs'
            Starts = 'agent-bridge-supervisor.ps1'; Log = 'agent-bridge-supervisor.log' }
        [pscustomobject]@{ Name = 'the keep-awake launcher'; File = 'agent-bridge-devbox-keepawake.vbs'
            Starts = 'agent-bridge-devbox-keepawake.ps1'; Log = 'agent-bridge-devbox-keepawake.log' }
    )

    foreach ($launcher in $launchers) {
        Write-Host ''
        Write-Host "--- $($launcher.Name) ---"

        $install = New-LauncherInstall -Launcher $launcher
        $run = Wait-Launcher (Start-Launcher -Path $install.Launcher)
        $started = Wait-Until { Test-Path -LiteralPath $install.Started }
        Test-That 'starts its script with pwsh and exits 0, logging nothing' {
            $run.ExitCode -eq 0 -and -not $run.Output -and $started -and -not (Test-Path -LiteralPath $install.Log)
        } -Detail "exit $($run.ExitCode), output '$($run.Output)', script started: $started"

        $install = New-LauncherInstall -Launcher $launcher
        Set-PwshDenied $true
        $process = Start-Launcher -Path $install.Launcher -Arguments @("/pwsh:$deniedPwsh", '/attempts:600', '/interval:100')
        $refusedOnce = Wait-Until { (Read-LauncherLog $install.Log) -match 'could not start' }
        Set-PwshDenied $false
        $run = Wait-Launcher $process
        $log = Read-LauncherLog $install.Log
        Test-That 'a start refused at first is tried again, and goes ahead once pwsh can start' {
            $refusedOnce -and $run.ExitCode -eq 0 -and -not $run.Output -and
            $log -match 'launcher: could not start .*: .*\[800A0046\]; trying again' -and
            $log -notmatch 'gave up'
        } -Detail "exit $($run.ExitCode), output '$($run.Output)', log '$log'"

        $install = New-LauncherInstall -Launcher $launcher
        Set-PwshDenied $true
        $run = Wait-Launcher (Start-Launcher -Path $install.Launcher -Arguments @("/pwsh:$deniedPwsh", '/attempts:3', '/interval:50'))
        $log = Read-LauncherLog $install.Log
        Test-That 'one that can never start gives up without an error dialog, exits 1, and logs why' {
            $run.ExitCode -eq 1 -and -not $run.Output -and
            $log -match 'launcher: gave up: .* could not be started in 3 attempts \(last: .*\[800A0046\]\)'
        } -Detail "exit $($run.ExitCode), output '$($run.Output)', log '$log'"
    }
}
finally {
    try { Set-PwshDenied $false } catch { }
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
