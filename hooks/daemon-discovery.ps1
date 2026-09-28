<#
    Bridge daemon: which sessions are live.

    Finds the live Copilot, Claude, Codex and MCP sessions, the other machines
    sharing this Home Assistant, and the process behind a session.

    Part of agent-bridge-daemon.ps1, which dot-sources it into its own scope after
    declaring the shared $script: state; see docs/daemon-split.md.
    Shared state it changes: DaemonMcpCache, DaemonMcpCacheAt, DaemonPeerCache,
    DaemonStatesCache, DaemonStatesCacheAt.
#>

function Get-LiveCopilotSessions {
    <#
        Live sessions, keyed by session id, resolved from the `inuse.<pid>.lock` files
        that the CLI maintains. A lock whose process is gone is stale and skipped.

        Built to stay cheap even with hundreds of historical session directories on
        disk (this machine has ~480). The live Copilot pids are fetched once up front,
        directory and lock enumeration go through the .NET APIs rather than the
        PowerShell provider, and no per-lock Get-Process call is made. An earlier
        version cost about 1.9 seconds per call and, run every few seconds, pinned a
        third of a CPU core on its own.
    #>
    $root = $script:DecisionBridgeConfig.SessionStateRoot
    if (-not [IO.Directory]::Exists($root)) { return @{} }

    # One process snapshot; membership is then a hash lookup per lock.
    $livePids = @{}
    foreach ($process in @(Get-BridgeAgentProcesses -Agent 'copilot')) {
        $livePids[$process.Id] = $true
    }
    if ($livePids.Count -eq 0) { return @{} }

    $candidates = @()
    foreach ($dir in [IO.Directory]::EnumerateDirectories($root)) {
        $processId = $null
        foreach ($lock in [IO.Directory]::EnumerateFiles($dir, 'inuse.*.lock')) {
            $name = [IO.Path]::GetFileName($lock)
            if ($name -notmatch '^inuse\.(\d+)\.lock$') { continue }
            $candidatePid = [int]$Matches[1]
            if ($livePids.ContainsKey($candidatePid)) { $processId = $candidatePid; break }
        }
        if ($null -eq $processId) { continue }

        $transcript = [IO.Path]::Combine($dir, 'events.jsonl')

        # A session that has not taken its first turn has no transcript yet. It is
        # still a real, live session, so it is included rather than skipped: the card
        # shows it as idle and, more usefully, its reply box can start the
        # conversation from Home Assistant. Streaming begins on its own once the
        # transcript appears.
        $hasTranscript = [IO.File]::Exists($transcript)

        $candidates += [pscustomobject]@{
            SessionId = [IO.Path]::GetFileName($dir)
            ProcessId = $processId
            Transcript = $transcript
            HasTranscript = $hasTranscript
            # A missing file reports a 1601 sentinel, which naturally loses the
            # per-pid tie-break below to any session that has actually written one.
            LastWrite = if ($hasTranscript) { [IO.File]::GetLastWriteTimeUtc($transcript) } else { [DateTime]::MinValue }
            Kind = 'copilot'
        }
    }

    # One CLI process owns exactly one live session. A process that resumed a
    # different session leaves the old `inuse.<pid>.lock` behind, so the same pid can
    # appear under several session directories. Publishing all of them would create
    # phantom sessions in Home Assistant and, worse, deliver a reply meant for one
    # session into whichever session shares the pid. Keep only the most recently
    # written transcript for each pid.
    $live = @{}
    foreach ($group in ($candidates | Group-Object -Property ProcessId)) {
        $winner = $group.Group | Sort-Object LastWrite -Descending | Select-Object -First 1
        $live[$winner.SessionId] = $winner
    }

    $live
}

function Get-LiveCodexSessions {
    <#
        Live Codex sessions, from the registrations its hooks write.

        Codex needs no transcript tailing: its hooks report every prompt, tool call
        and reply directly, and the hook records the resulting status and activity in
        the registration. The daemon therefore publishes what the registration already
        says rather than deriving it.

        Liveness is authoritative here in a way it is not for the others, because
        Codex fires an explicit SessionEnd.
    #>
    if (-not $script:CodexAdapterLoaded) { return @{} }

    $live = @{}
    foreach ($registration in @(Get-CodexSessionRegistrations)) {
        if (-not $registration.IsLive) { continue }
        $live[$registration.SessionId] = [pscustomobject]@{
            SessionId        = $registration.SessionId
            ProcessId        = $registration.ProcessId
            Transcript       = $registration.TranscriptPath
            WorkingDirectory = $registration.WorkingDirectory
            Status           = $registration.Status
            Activity         = $registration.Activity
            LastWrite        = [DateTime]::UtcNow
            Kind             = 'codex'
        }
    }
    $live
}

function Get-DaemonHomeAssistantStates {
    <#
        Every Home Assistant state, cached for a short while.

        Two scans need the full state list - MCP clients and peer machines - and both
        change slowly, so they share one read rather than each paying for an O(all
        entities) fetch on every reconcile. Failure throws; each caller decides whether
        to fall back to its own last known good set.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    if ($null -ne $script:DaemonStatesCache -and
        ([DateTimeOffset]::Now - $script:DaemonStatesCacheAt).TotalSeconds -lt $script:DaemonConfig.McpScanCacheSeconds) {
        return ,$script:DaemonStatesCache
    }

    $states = Invoke-DecisionHttpRequest -Parameters @{
        Method = 'Get'
        Uri = "$($script:DecisionBridgeConfig.HomeAssistantBaseUrl)/api/states"
        Headers = $Headers
        TimeoutSec = 15
    }
    $script:DaemonStatesCache = @($states)
    $script:DaemonStatesCacheAt = [DateTimeOffset]::Now
    # Comma-wrapped: an empty array returned bare unrolls to nothing, and the caller's
    # @($result) then yields a one-element array holding $null, which every consumer
    # here would dereference.
    ,$script:DaemonStatesCache
}

function Get-DaemonPeerMachines {
    <#
        The other machines running the bridge against this Home Assistant, with
        whatever each is currently running.

        This is what makes one dashboard able to show every machine. Discovery is
        one-directional and needs no agreement between machines: each publishes a
        retained sensor describing itself, and everyone else simply reads it.

        A failed scan falls back to the last known set rather than to none, so a
        transient Home Assistant error does not make every other machine's sessions
        blink out of the dashboard and back in.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    try { $states = Get-DaemonHomeAssistantStates -Headers $Headers }
    catch {
        if ($null -ne $script:DaemonPeerCache) { return $script:DaemonPeerCache }
        return @()
    }

    $peers = @(Get-BridgePeerMachine -States $states -ExcludeSelf)
    $script:DaemonPeerCache = $peers
    $peers
}

function Get-LiveMcpSessions {
    <#
        Live MCP clients, discovered from their Home Assistant entities.

        The MCP server is a separate process on any operating system, so there is no
        registration file or process to inspect. Its entities are the only evidence it
        exists - and they are sufficient, because it publishes them on connect and
        withdraws them on disconnect, so presence is liveness.

        These sessions are deliberately thin. An MCP server never sees a transcript
        and cannot originate a turn, so it publishes a decision, a reply and a status
        and nothing else; the dashboard renders them with a reduced card for that
        reason.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    # Serve the cached scan while it is fresh. MCP presence changes slowly and only
    # affects the global count and dashboard card - the MCP server publishes and
    # withdraws its own decision entities - so a short TTL avoids a full O(all HA
    # entities) /api/states read on every reconcile.
    #
    # That TTL now lives on the shared state snapshot, which the peer-machine scan
    # reads too, so both get one HTTP round trip between them. Re-parsing the snapshot
    # each call is cheap and keeps the two from drifting: a private freshness gate here
    # as well could expire while the snapshot behind it was still warm, so the "fresh"
    # scan would have re-read nothing.
    $live = @{}
    try {
        $states = Get-DaemonHomeAssistantStates -Headers $Headers
    }
    catch {
        # Show the last known set on a transient scan failure rather than flapping the
        # count to zero; a still-expired cache is retried on the next reconcile.
        if ($null -ne $script:DaemonMcpCache) { return $script:DaemonMcpCache }
        return $live
    }

    foreach ($state in @($states)) {
        if ($null -eq $state) { continue }
        $entityId = [string]$state.entity_id
        if ($entityId -notmatch '^select\.(mcp_[a-z0-9]+)_decision$') { continue }
        $node = $Matches[1]

        $name = [string]$state.attributes.friendly_name
        if ([string]::IsNullOrWhiteSpace($name)) { $name = 'MCP client' }
        # The friendly name is "<device> Decision"; the device is the useful part.
        $name = ($name -replace '\s+Decision$', '')
        if (Get-Command Remove-CopilotTemplateMarkup -ErrorAction SilentlyContinue) {
            $name = Remove-CopilotTemplateMarkup -Text $name
        }

        # The node doubles as the id: these sessions are addressed only by entity.
        $live[$node] = [pscustomobject]@{
            SessionId  = $node
            ProcessId  = 0
            Transcript = ''
            Node       = $node
            Name       = $name
            LastWrite  = [DateTime]::UtcNow
            Kind       = 'mcp'
        }
    }
    $script:DaemonMcpCache = $live
    $script:DaemonMcpCacheAt = [DateTimeOffset]::Now
    $live
}

function Get-LiveBridgeSessions {
    <# Every live session across the front ends the bridge supports. #>
    $live = Get-LiveCopilotSessions
    foreach ($entry in (Get-LiveClaudeSessions).GetEnumerator()) {
        $live[$entry.Key] = $entry.Value
    }
    foreach ($entry in (Get-LiveCodexSessions).GetEnumerator()) {
        $live[$entry.Key] = $entry.Value
    }
    $live
}

function Get-LiveClaudeSessions {
    <#
        Live Claude Code sessions, from the registrations its hooks write.

        Claude has no inuse.<pid>.lock, so liveness is the recorded pid still being a
        running claude process - established in Get-ClaudeSessionRegistrations.
    #>
    if (-not $script:ClaudeAdapterLoaded) { return @{} }

    $live = @{}
    foreach ($registration in @(Get-ClaudeSessionRegistrations)) {
        if (-not $registration.IsLive) { continue }
        # Claude creates the transcript only when the first message is sent, so a
        # session just started - from the dashboard, typically - has none yet. It is
        # live all the same, and requiring the file hid it until someone typed in it.
        # Everything that reads the transcript treats a missing file as no activity.
        $transcript = [string]$registration.TranscriptPath
        if ([string]::IsNullOrWhiteSpace($transcript)) { continue }

        $live[$registration.SessionId] = [pscustomobject]@{
            SessionId        = $registration.SessionId
            ProcessId        = $registration.ProcessId
            Transcript       = $transcript
            WorkingDirectory = $registration.WorkingDirectory
            LastWrite        = [IO.File]::GetLastWriteTimeUtc($transcript)
            Kind             = 'claude'
            # The status the last hook set, and when (see Sync-DaemonHookStatus).
            HookStatus       = [string]$registration.HookStatus
            HookStatusAt     = [string]$registration.HookStatusAt
        }
    }
    $live
}

function Get-BridgeSessionDisplay {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$Kind = 'copilot',
        [string]$WorkingDirectory = 'Unknown folder'
    )

    if ($Kind -eq 'claude' -and $script:ClaudeAdapterLoaded) {
        return Get-ClaudeSessionDisplay -SessionId $SessionId -WorkingDirectory $WorkingDirectory
    }
    if ($Kind -eq 'codex' -and $script:CodexAdapterLoaded) {
        return Get-CodexSessionDisplay -SessionId $SessionId -WorkingDirectory $WorkingDirectory
    }
    Get-CopilotSessionDisplay -SessionId $SessionId -WorkingDirectory $WorkingDirectory
}

function Get-DaemonSessionProcessId {
    <#
        The owning process of a Claude or Codex session, from the live set, or 0 for a
        Copilot session, which the injector finds by its lock file.
    #>
    param([Parameter(Mandatory)][string]$SessionId)

    $known = if ($script:DaemonLive) { $script:DaemonLive[$SessionId] } else { $null }
    if ($null -ne $known -and $known.PSObject.Properties['Kind'] -and [string]$known.Kind -in @('claude', 'codex') -and
        $known.PSObject.Properties['ProcessId'] -and [int]$known.ProcessId -gt 0) {
        return [int]$known.ProcessId
    }
    0
}
