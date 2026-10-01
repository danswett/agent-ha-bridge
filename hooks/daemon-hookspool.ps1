<#
    Bridge daemon: hook events the native hook handed over.

    The agents wait for every hook, and a PowerShell hook costs half a second before it
    has done anything. The native hook (agent-bridge-hook, see docs/fast-hooks.md)
    instead records the event and its process ancestry in the spool folder and returns
    at once; this runs each event through the same function the PowerShell hook script
    runs (claude-hooks.ps1, codex-hooks.ps1, copilot-hooks.ps1), on the fast-lane tick.

    A spool file is `{ v, agent, hook, ancestors, receivedAt, event }`, written under a
    temporary name and renamed to *.json when complete, so a half-written file is never
    read. Files are taken in name order - the native hook names them by time - so one
    session's events are handled in the order they happened.

    The spool is not listed on every tick: a directory call costs 60-100 microseconds
    on Windows, more than the rest of an idle tick. A file-system watcher queues an
    event when a file arrives, and a tick reads that queue's count (Test-DaemonHookSpoolDue).
    A sweep every two seconds covers anything a watcher misses.

    Part of agent-bridge-daemon.ps1, which dot-sources it into its own scope after
    declaring the shared $script: state; see docs/daemon-split.md.
    Shared state it changes: DaemonHookSpoolAttempts, DaemonHookSpoolWatcher,
    DaemonHookSpoolEvents, DaemonHookSpoolSweptAt, DecisionBridgeDeadline (restored);
    reads DaemonHookSpoolDirectory.
#>

$script:DaemonHookSpoolAttempts = @{}

# The native hook writes here, under the same installation root as registrations. Resolved
# once, since Join-Path alone costs more than an idle tick.
$script:DaemonHookSpoolDirectory = Get-BridgeRuntimePath 'agent-bridge-spool'

$script:DaemonHookSpoolWatcher = $null
$script:DaemonHookSpoolEvents = $null
$script:DaemonHookSpoolSweptAt = [DateTime]::MinValue
$script:DaemonHookSpoolSources = @('agent-bridge-spool-created', 'agent-bridge-spool-renamed', 'agent-bridge-spool-error')
$script:DaemonHookSpoolSweepSeconds = 2

# Which function runs each spooled hook, and whether it runs under strict mode - as its
# own script does: the Claude and Codex adapters set it, the Copilot hooks do not, and
# the shared ask_user parser relies on reading a missing property as $null.
$script:DaemonHookHandlers = @{
    'claude/register'     = @{ Function = 'Invoke-ClaudeRegisterHook'; Ancestors = $true; Strict = $true }
    'claude/stop'         = @{ Function = 'Invoke-ClaudeStopHook'; Ancestors = $true; Strict = $true }
    'claude/ask'          = @{ Function = 'Invoke-ClaudeAskHook'; Ancestors = $true; Strict = $true }
    'claude/notification' = @{ Function = 'Invoke-ClaudeNotificationHook'; Ancestors = $true; Strict = $true }
    'codex/hook'          = @{ Function = 'Invoke-CodexHook'; Ancestors = $true; Strict = $true }
    'copilot/ask_user'    = @{ Function = 'Invoke-CopilotAskUserHook'; Ancestors = $false; Strict = $false }
    'copilot/agent_stop'  = @{ Function = 'Invoke-CopilotAgentStopHook'; Ancestors = $false; Strict = $false }
    'copilot/permission'  = @{ Function = 'Invoke-CopilotPermissionHook'; Ancestors = $false; Strict = $false }
}

function Start-DaemonHookSpoolWatcher {
    <#
        Watches the spool folder, creating it if need be. Events are queued, not acted
        on - no -Action - so nothing runs on another thread; the fast lane reads the
        queue's count. Safe to call again: a watcher already running is kept.
    #>
    if ($null -ne $script:DaemonHookSpoolWatcher) { return }
    try {
        [void][IO.Directory]::CreateDirectory($script:DaemonHookSpoolDirectory)
        $watcher = [IO.FileSystemWatcher]::new($script:DaemonHookSpoolDirectory, '*.json')
        # The native hook writes a temporary file and renames it; Created covers a
        # writer that does not.
        $null = Register-ObjectEvent -InputObject $watcher -EventName Renamed -SourceIdentifier 'agent-bridge-spool-renamed'
        $null = Register-ObjectEvent -InputObject $watcher -EventName Created -SourceIdentifier 'agent-bridge-spool-created'
        # A buffer overflow loses notifications; the queued error makes the next tick look.
        $null = Register-ObjectEvent -InputObject $watcher -EventName Error -SourceIdentifier 'agent-bridge-spool-error'
        $watcher.EnableRaisingEvents = $true
        $script:DaemonHookSpoolWatcher = $watcher
        $script:DaemonHookSpoolEvents = $Host.Runspace.Events.ReceivedEvents
    }
    catch {
        # Without a watcher the two-second sweep still delivers everything, just later.
        Write-DaemonLog -Message "hook spool watcher unavailable: $($_.Exception.Message)"
    }
}

function Test-DaemonHookSpoolDue {
    <#
        Whether the spool needs looking at: a watcher notification is queued, an event is
        waiting for its retry, or the sweep is due. Costs a few microseconds otherwise.
    #>
    ($null -ne $script:DaemonHookSpoolEvents -and $script:DaemonHookSpoolEvents.Count -gt 0) -or
        $script:DaemonHookSpoolAttempts.Count -gt 0 -or
        ([DateTime]::UtcNow - $script:DaemonHookSpoolSweptAt).TotalSeconds -ge $script:DaemonHookSpoolSweepSeconds
}

function Invoke-DaemonHookEvent {
    <#
        Runs one spooled event through its hook function. Throws when the event cannot
        be handled, so the caller can retry it once.
    #>
    param([Parameter(Mandatory)]$Spooled)

    $selected = Get-BridgeSelectedClients
    if ($null -ne $selected -and $selected -notcontains [string]$Spooled.agent) {
        Write-DaemonLog -Message "ignored a hook for the unselected $([string]$Spooled.agent) client"
        return
    }
    $key = "$([string]$Spooled.agent)/$([string]$Spooled.hook)"
    $handler = $script:DaemonHookHandlers[$key]
    if ($null -eq $handler) { throw "no handler for $key" }
    if (-not (Get-Command $handler.Function -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "$($handler.Function) is not loaded (is the $([string]$Spooled.agent) adapter installed?)"
    }

    $arguments = @{ HookEvent = $Spooled.event }
    if ($handler.Ancestors) {
        $arguments.Ancestors = [int[]]@(@($Spooled.ancestors) | Where-Object { $_ } | ForEach-Object { [int]$_ })
    }

    # A hook sets a deadline on every HTTP call in its process (Enter-BridgeAdapterSession);
    # left in place here it would cut off the daemon's own requests 45 seconds later.
    $deadline = $script:DecisionBridgeDeadline
    try {
        & {
            # A child scope, so the mode set here ends with it.
            if ($handler.Strict) { Set-StrictMode -Version Latest } else { Set-StrictMode -Off }
            & $handler.Function @arguments | Out-Null
        }
    }
    finally {
        $script:DecisionBridgeDeadline = $deadline
    }
}

function Invoke-DaemonHookSpool {
    <#
        Handles every event waiting in the spool, oldest first. Called on the fast-lane
        tick, so it costs one directory listing when the spool is empty.

        An event that fails is tried once more on the next tick, then dropped and
        logged: a hook's work is repaired by the reconcile anyway, and a bad file must
        not be retried forever. Returns how many were handled.
    #>
    # Taken before listing, so a file arriving during the pass queues a fresh one.
    $script:DaemonHookSpoolSweptAt = [DateTime]::UtcNow
    if ($null -ne $script:DaemonHookSpoolEvents -and $script:DaemonHookSpoolEvents.Count -gt 0) {
        foreach ($source in $script:DaemonHookSpoolSources) { Remove-Event -SourceIdentifier $source -ErrorAction SilentlyContinue }
    }

    $directory = $script:DaemonHookSpoolDirectory
    if (-not [IO.Directory]::Exists($directory)) { return 0 }
    $files = [IO.Directory]::GetFiles($directory, '*.json')
    if ($files.Length -eq 0) { return 0 }
    [Array]::Sort($files, [StringComparer]::Ordinal)

    $handled = 0
    foreach ($path in $files) {
        $name = [IO.Path]::GetFileName($path)
        $spooled = $null
        try {
            $raw = [IO.File]::ReadAllText($path)
            $spooled = $raw | ConvertFrom-Json
            if ([string]$spooled.agent -eq 'copilot' -and [string]$spooled.hook -eq 'ask_user') {
                $decision = ConvertFrom-DecisionJson -Json $raw
                foreach ($argument in @('toolArgs', 'tool_input')) {
                    if ($decision.event.PSObject.Properties[$argument]) {
                        $spooled.event.$argument = $decision.event.$argument
                    }
                }
            }
            Invoke-DaemonHookEvent -Spooled $spooled
            $handled++
            $script:DaemonHookSpoolAttempts.Remove($name)
            try { [IO.File]::Delete($path) } catch { }
        }
        catch {
            $attempts = 1 + [int]$script:DaemonHookSpoolAttempts[$name]
            $script:DaemonHookSpoolAttempts[$name] = $attempts
            if ($attempts -ge 2) {
                Write-DaemonLog -Message "dropped spooled hook $name after $attempts attempts: $($_.Exception.Message)"
                $script:DaemonHookSpoolAttempts.Remove($name)
                try { [IO.File]::Delete($path) } catch { }
            }
            else {
                Write-DaemonLog -Message "spooled hook $name failed, will retry: $($_.Exception.Message)"
            }
        }
    }
    $handled
}
