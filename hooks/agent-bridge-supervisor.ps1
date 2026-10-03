<#
    Supervises the Copilot CLI bridge daemon.

    Launched by a scheduled task at logon. Keeps a single daemon instance running,
    restarting it if it ever exits, with a short backoff so a persistent failure
    cannot spin. The daemon itself holds a named mutex, so even if this supervisor is
    started twice only one daemon runs.

    Deliberately thin: all real logic lives in agent-bridge-daemon.ps1, so this
    wrapper rarely needs to change.
#>

$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'bridge-platform.ps1')
$supervisorContext = Resolve-BridgeInstallContext -EntryDirectory $PSScriptRoot
$daemon = Join-Path $PSScriptRoot 'agent-bridge-daemon.ps1'
$logFile = Get-BridgeRuntimePath -Name 'agent-bridge-supervisor.log' -Context $supervisorContext
[void][IO.Directory]::CreateDirectory((Split-Path $logFile -Parent))

function Write-SupervisorLog {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $logFile -Value "$([DateTimeOffset]::Now.ToString('o')) $Message"
    }
    catch { }
}

# One supervisor only. If the scheduled task fires more than once - a second logon
# trigger, a manual start - the second instance must not spawn a competing daemon
# that then loops against the first one's mutex. Hold a named mutex for the lifetime
# of the supervisor; a second instance that cannot acquire it exits immediately.
$mutexName = 'Local\CopilotBridgeSupervisor' + $(if ($supervisorContext.Id) { "_$($supervisorContext.Id)" } else { '' })
$supervisorMutex = [Threading.Mutex]::new($false, $mutexName)
$ownsSupervisor = $false
try {
    $ownsSupervisor = $supervisorMutex.WaitOne([TimeSpan]::FromSeconds(2))
}
catch [System.Threading.AbandonedMutexException] {
    $ownsSupervisor = $true
}
if (-not $ownsSupervisor) {
    Write-SupervisorLog -Message "another supervisor is already running (pid $PID); exiting"
    return
}

Write-SupervisorLog -Message "supervisor starting (pid $PID)"
Register-BridgeRuntimeProcess -Context $supervisorContext -Role supervisor

$backoffSeconds = 5
$maxBackoff = 120

# Asks .NET's garbage collector to hand memory back rather than keep it for the next
# burst: the daemon's live objects are about 30 MB, but after each reconcile the
# collector held 150-180 MB more in reserve. 7 measured about 90 MB steady instead of
# 160 on DASDESK (see Invoke-DaemonMemoryTrim for the rest). Read by the runtime at
# start, so it is set here, where the daemon inherits it.
$env:DOTNET_GCConserveMemory = '7'

try {
    while ($true) {
        $started = [DateTimeOffset]::Now
        try {
            $start = [Diagnostics.ProcessStartInfo]::new((Get-BridgePwshPath))
            $start.UseShellExecute = $false
            foreach ($argument in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $daemon)) { $start.ArgumentList.Add($argument) }
            # CreateNoWindow, not merely a hidden window. WindowStyle is ignored when
            # UseShellExecute is false, so without this the daemon gets a console - either
            # a new one or, when a hook starts it, whatever short-lived process was running
            # at the time. That console is tied to the interactive session, and when the
            # session is disconnected or its owner exits the daemon keeps running with a
            # handle that no longer resolves.
            #
            # Nothing announces that. The daemon goes on logging and publishing, and the
            # only symptom is that anything reaching PowerShell's console plumbing throws
            # 'The Win32 internal error "The handle is invalid." 0x6 occurred while getting
            # the console mode'. The first thing to hit it in practice was launching into
            # an `isolate` workspace: New-BridgeSessionWorktree's catch turned it into
            # "Launch refused: requested isolation failed", which says nothing about a
            # console and sends you looking at git. Observed on two machines, one of them
            # running a release with no local changes at all, and cleared on both by
            # restarting the daemon - which is what made a stale console the explanation.
            #
            # A daemon has no business owning a console, so it is given none.
            if ($script:BridgeIsWindows) { $start.CreateNoWindow = $true }
            $process = [Diagnostics.Process]::Start($start)
            try { $process.WaitForExit() } finally { $process.Dispose() }
        }
        catch {
            Write-SupervisorLog -Message "daemon launch error: $($_.Exception.Message)"
        }

        $ranFor = ([DateTimeOffset]::Now - $started).TotalSeconds
        # A daemon that ran for a good while and then exited is a one-off; reset the
        # backoff. One that dies immediately is failing, so back off progressively.
        if ($ranFor -ge 60) {
            $backoffSeconds = 5
        }
        else {
            $backoffSeconds = [Math]::Min($backoffSeconds * 2, $maxBackoff)
        }

        Write-SupervisorLog -Message "daemon exited after $([Math]::Round($ranFor, 0))s; restarting in $backoffSeconds s"
        Start-Sleep -Seconds $backoffSeconds
    }
}
finally {
    if ($ownsSupervisor) {
        $supervisorMutex.ReleaseMutex()
    }
    $supervisorMutex.Dispose()
}
