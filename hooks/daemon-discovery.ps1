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

# Only the bridge's own entities (agent_bridge_*) and the MCP server's (mcp_*), rendered
# by Home Assistant itself as a JSON list of { entity_id, state, attributes }.
#
# `selectattr` before the loop is the whole performance of this template. Written as
# `for s in states if s.object_id.startswith(...)` the filter runs in Jinja, once per
# entity, over every state in the instance - 5,354 of them on DASDESK to find 44 - and
# measured 221 ms of Home Assistant's CPU. `selectattr` does the same filtering inside
# Python and hands back only the matches, so the Jinja loop runs 44 times instead:
# 50 ms for byte-identical output. The accumulator is not the cost and the attributes
# are not the cost; iterating the whole instance in Jinja is.
$script:DaemonBridgeStatesTemplate = @'
{%- set sel = states | selectattr('object_id','match','agent_bridge_|mcp_') | list -%}
{%- set ns = namespace(out=[]) -%}
{%- for s in sel -%}
{%- set ns.out = ns.out + [{'entity_id': s.entity_id, 'state': s.state, 'attributes': dict(s.attributes)}] -%}
{%- endfor -%}
{{ ns.out | to_json }}
'@
$script:DaemonStatesTemplateRefused = $false

function Get-DaemonHomeAssistantStates {
    <#
        The Home Assistant states the daemon reads - the bridge's own entities and the MCP
        server's - cached for a short while.

        Three things read them - MCP clients, peer machines and the orphan sweep - and
        all change slowly, so they share one read per reconcile interval. -Fresh skips
        the cache and refills it, which is what the reconcile's own snapshot uses.

        Home Assistant filters them (DaemonBridgeStatesTemplate, through /api/template):
        the full /api/states list was 5,354 entities and 2.4 MB of JSON on DASDESK, of
        which the bridge uses about 40. Parsing it every reconcile, and caching it, held
        about 180 MB of the daemon's memory; the filtered list is 12 KB. A Home Assistant
        that refuses templates gets the full list, as before. Failure throws; each
        caller decides whether to fall back to its own last known good set.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers, [switch]$Fresh)

    if (-not $Fresh -and $null -ne $script:DaemonStatesCache -and
        ([DateTimeOffset]::Now - $script:DaemonStatesCacheAt).TotalSeconds -lt $script:DaemonConfig.McpScanCacheSeconds) {
        return ,$script:DaemonStatesCache
    }

    $base = $script:DecisionBridgeConfig.HomeAssistantBaseUrl
    $states = $null
    $filtered = $false
    if (-not $script:DaemonStatesTemplateRefused) {
        try {
            $rendered = Invoke-DecisionHttpRequest -Parameters @{
                Method = 'Post'
                Uri = "$base/api/template"
                Headers = $Headers
                ContentType = 'application/json'
                Body = (@{ template = $script:DaemonBridgeStatesTemplate } | ConvertTo-Json -Compress)
                TimeoutSec = 15
            }
            # Home Assistant answers text/plain, so the JSON arrives as a string.
            # -NoEnumerate keeps an empty list a list rather than nothing at all.
            $states = if ($rendered -is [string]) { $rendered | ConvertFrom-Json -NoEnumerate } else { $rendered }
            $filtered = $true
        }
        catch {
            # A refusal (a 4xx - an older Home Assistant, or a token not allowed to
            # render templates) is permanent, so stop asking; anything else is tried
            # again next time. Either way the full list serves for now.
            $code = 0
            try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            if ($code -ge 400 -and $code -lt 500) {
                $script:DaemonStatesTemplateRefused = $true
                Write-DaemonLog -Message "Home Assistant refused the filtered state read ($code); reading every state instead"
            }
        }
    }
    if (-not $filtered) {
        $states = Invoke-DecisionHttpRequest -Parameters @{
            Method = 'Get'
            Uri = "$base/api/states"
            Headers = $Headers
            TimeoutSec = 15
        }
    }
    $script:DaemonStatesCache = @($states)
    $script:DaemonStatesCacheAt = [DateTimeOffset]::Now
    # Comma-wrapped: an empty array returned bare unrolls to nothing, and the caller's
    # @($result) then yields a one-element array holding $null, which every consumer
    # here would dereference.
    ,$script:DaemonStatesCache
}

$script:DaemonReconcileStates = $null

function Set-DaemonReconcileSnapshot {
    <#
        Takes one read of every bridge entity and holds it for this reconcile, so the
        per-session checks below can be answered without a request each.

        A reconcile used to make about 5 Home Assistant reads per live session and 3
        besides - the repair pass read the reply box and the decision selector, the
        reply pass read the decision selector again and the payload sensor, and the
        stop pass read the stop button - every pass, for every session, whether or not
        anything had happened. Thirteen round trips for two sessions, forty-three for
        eight. One filtered template read answers all of them at once and costs the
        same whatever the session count, which is the point: the old shape charged for
        idleness and grew with every session opened.

        This is a backstop, not the fast path. A press is noticed within a tick by the
        WebSocket watch, which subscribes to these same entities and acts on the change
        directly (Invoke-DaemonHit); the reconcile exists to catch whatever landed
        between watch windows. So a snapshot taken at the top of a pass is no staler
        than the reads it replaces - and it is more consistent, because every check in
        the pass now sees the same instant rather than thirteen slightly different ones.

        A failure leaves no snapshot, and Get-DaemonEntityState falls back to reading
        each entity directly, exactly as before.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    $script:DaemonReconcileStates = $null
    try {
        $map = @{}
        # Assigned first, then wrapped. Get-DaemonHomeAssistantStates returns its list
        # comma-wrapped so that an empty one survives the caller's @(), which means
        # @(Get-DaemonHomeAssistantStates ...) is a one-element array holding the whole
        # list - and the loop below then ran once with every entity at once. It built a
        # single key 179 characters long, [string] having joined the ids with spaces,
        # and every lookup missed and fell back to a direct read: the batching silently
        # did nothing at all while looking like it worked.
        $states = Get-DaemonHomeAssistantStates -Headers $Headers -Fresh
        foreach ($entry in @($states)) {
            if ($null -eq $entry) { continue }
            $id = [string]$entry.entity_id
            if (-not [string]::IsNullOrWhiteSpace($id)) { $map[$id] = $entry }
        }
        $script:DaemonReconcileStates = $map
    }
    catch {
        Write-DaemonLog -Message "state snapshot failed, reading entities one at a time: $($_.Exception.Message)"
    }
}

function Clear-DaemonReconcileSnapshot {
    <# Ends the pass the snapshot belongs to, so nothing outside it reads stale values. #>
    $script:DaemonReconcileStates = $null
}

function Get-DaemonEntityState {
    <#
        One entity's state: from this reconcile's snapshot when it holds it, otherwise
        read directly.

        An entity the snapshot does not hold is read rather than reported missing.
        Several callers use a read that throws as an existence probe, and the template
        only renders entities Home Assistant already knows about, so answering "absent"
        from the snapshot would quietly change what those callers decide.
    #>
    param(
        [Parameter(Mandatory)][string]$EntityId,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    if ($null -ne $script:DaemonReconcileStates -and $script:DaemonReconcileStates.ContainsKey($EntityId)) {
        return $script:DaemonReconcileStates[$EntityId]
    }
    Get-HomeAssistantState -EntityId $EntityId -Headers $Headers
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
    <# Every live session across the front ends the bridge supports (see daemon-agents.ps1). #>
    $live = @{}
    foreach ($kind in @($script:DaemonAgents.Keys)) {
        $find = (Get-DaemonAgent -Kind $kind).FindSessions
        if (-not $find) { continue }
        foreach ($entry in (& $find).GetEnumerator()) {
            $live[$entry.Key] = $entry.Value
        }
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

    & (Get-DaemonAgent -Kind $Kind).Display $SessionId $WorkingDirectory
}

function Get-DaemonSessionProcessId {
    <#
        The owning process of a Claude or Codex session, from the live set, or 0 for a
        Copilot session, which the injector finds by its lock file.
    #>
    param([Parameter(Mandatory)][string]$SessionId)

    $known = if ($script:DaemonLive) { $script:DaemonLive[$SessionId] } else { $null }
    if ($null -ne $known -and $known.PSObject.Properties['Kind'] -and (Get-DaemonAgent -Kind ([string]$known.Kind)).KnowsProcessId -and
        $known.PSObject.Properties['ProcessId'] -and [int]$known.ProcessId -gt 0) {
        return [int]$known.ProcessId
    }
    0
}
