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
        Live sessions, keyed by session id.

        Two sources, because neither is complete on its own. The `--session-id` on a
        process's own command line names its session outright, for a new session and a
        resumed one alike, and is what settles the pid. The `inuse.<pid>.lock` files
        the CLI maintains cover anything whose command line could not be read.

        The locks alone used to be the whole answer, and a resumed session was
        invisible for it: resuming onto an id that already has history writes no lock,
        so on 2026-09-30 a session resumed from the dashboard ran normally with all
        103 of its turns while the bridge never saw it - no card and no reply box,
        then a second Resume press onto the same transcript.

        Built to stay cheap even with hundreds of historical session directories on
        disk (this machine has ~480). The live Copilot pids are fetched once up front,
        directory and lock enumeration go through the .NET APIs rather than the
        PowerShell provider, and no per-lock Get-Process call is made. An earlier
        version cost about 1.9 seconds per call and, run every few seconds, pinned a
        third of a CPU core on its own; command lines are memoised per process for the
        same reason.
    #>
    $root = $script:DecisionBridgeConfig.SessionStateRoot
    if (-not [IO.Directory]::Exists($root)) { return @{} }

    # One process snapshot; membership is then a hash lookup per lock.
    $processes = @(Get-BridgeAgentProcesses -Agent 'copilot')
    $livePids = @{}
    foreach ($process in $processes) {
        $livePids[$process.Id] = $true
    }
    if ($livePids.Count -eq 0) { return @{} }

    $named = Get-BridgeAgentProcessSessionIds -Processes $processes

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

        # Null only if the directory went between enumerating it and reading it;
        # appending that would put a $null in the list for the tie-break to trip over.
        $candidate = New-DaemonCopilotSession -Directory $dir -ProcessId $processId
        if ($null -ne $candidate) { $candidates += $candidate }
    }

    # One CLI process owns exactly one live session. A process that resumed a
    # different session leaves the old `inuse.<pid>.lock` behind, so the same pid can
    # appear under several session directories. Publishing all of them would create
    # phantom sessions in Home Assistant and, worse, deliver a reply meant for one
    # session into whichever session shares the pid.
    #
    # A command line settles that outright, so it is taken first and the lock-based
    # tie-break is left to the processes it could not answer for.
    $live = @{}
    $settled = @{}
    foreach ($entry in $named.GetEnumerator()) {
        $processId = [int]$entry.Key
        $sessionId = [string]$entry.Value
        $winner = @($candidates | Where-Object { $_.ProcessId -eq $processId -and $_.SessionId -eq $sessionId })

        # No lock for it: a resume, which is exactly the case the locks miss. The
        # directory is the session's own, so it still describes it.
        $resolved = if ($winner.Count -gt 0) { $winner[0] }
            else { New-DaemonCopilotSession -Directory ([IO.Path]::Combine($root, $sessionId)) -ProcessId $processId }
        if ($null -eq $resolved) { continue }

        $live[$sessionId] = $resolved
        $settled[$processId] = $true
    }

    foreach ($group in ($candidates | Group-Object -Property ProcessId)) {
        if ($settled.ContainsKey([int]$group.Name)) { continue }
        # Keep only the most recently written transcript for each pid.
        $winner = $group.Group | Sort-Object LastWrite -Descending | Select-Object -First 1
        if (-not $live.ContainsKey($winner.SessionId)) { $live[$winner.SessionId] = $winner }
    }

    $live
}

function New-DaemonCopilotSession {
    <#
        One live Copilot session, as Get-LiveCopilotSessions describes them. Shared so
        that a session found by its lock and one found by its command line cannot come
        out in different shapes.

        Returns $null for a directory that is not there - a command line can name a
        session whose state directory has been cleaned away.
    #>
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][int]$ProcessId
    )

    if (-not [IO.Directory]::Exists($Directory)) { return $null }

    $transcript = [IO.Path]::Combine($Directory, 'events.jsonl')

    # A session that has not taken its first turn has no transcript yet. It is
    # still a real, live session, so it is included rather than skipped: the card
    # shows it as idle and, more usefully, its reply box can start the
    # conversation from Home Assistant. Streaming begins on its own once the
    # transcript appears.
    $hasTranscript = [IO.File]::Exists($transcript)

    [pscustomobject]@{
        SessionId = [IO.Path]::GetFileName($Directory)
        ProcessId = $ProcessId
        Transcript = $transcript
        HasTranscript = $hasTranscript
        # A missing file reports a 1601 sentinel, which naturally loses the
        # per-pid tie-break to any session that has actually written one.
        LastWrite = if ($hasTranscript) { [IO.File]::GetLastWriteTimeUtc($transcript) } else { [DateTime]::MinValue }
        Kind = 'copilot'
    }
}

function Read-DaemonRegistrationFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('claude', 'codex')][string]$Kind,
        [ValidateSet('Discovery', 'Hook')][string]$Projection = 'Discovery'
    )
    $stamp = $null
    $code = 'ReadFailed'
    try {
        if (Test-BridgeTestExecution) { Assert-BridgeTestPath -Path $Path }
        $file = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $code = 'UnsafeRecordPath'
            throw 'Registration path is not an ordinary file.'
        }
        $stamp = $file.LastWriteTimeUtc.Ticks
        $length = $file.Length
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        $code = 'InvalidJson'
        $parsed = $raw | ConvertFrom-Json -NoEnumerate -ErrorAction Stop
        $code = 'InvalidRecordShape'
        if ($parsed -isnot [pscustomobject]) { throw 'Registration is not a JSON object.' }
        $value = [ordered]@{}
        $required = if ($Projection -eq 'Discovery') {
            @('SessionId', 'TranscriptPath', 'WorkingDirectory', 'Updated') +
                $(if ($Kind -eq 'codex') { @('Model', 'Status', 'Activity') } else { @() })
        } elseif ($Kind -eq 'codex') { @('Status', 'Activity') } else { @() }
        $optional = if ($Kind -eq 'claude') { @('HookStatus', 'HookStatusAt') } else { @('Model', 'Updated') }
        foreach ($field in @($required) + @($optional)) {
            $property = $parsed.PSObject.Properties[$field]
            if (-not $property) {
                if ($required -contains $field) { throw 'A required registration field is missing.' }
                continue
            }
            $text = $property.Value
            if ($field -in @('Updated', 'HookStatusAt') -and
                ($text -is [datetime] -or $text -is [DateTimeOffset])) { $text = ([DateTimeOffset]$text).ToString('o') }
            if ($text -isnot [string]) { throw 'A registration field has the wrong type.' }
            if ($field -eq 'SessionId' -and [string]::IsNullOrWhiteSpace($text)) { throw 'Registration identity is empty.' }
            if ($field -in @('Updated', 'HookStatusAt') -and $text) {
                $instant = [DateTimeOffset]::MinValue
                if (-not [DateTimeOffset]::TryParse($text, [ref]$instant)) { throw 'Registration timestamp is invalid.' }
            }
            $value[$field] = $text
        }
        if ($Projection -eq 'Discovery' -or $parsed.PSObject.Properties['ProcessId']) {
            $processId = 0
            if (-not $parsed.PSObject.Properties['ProcessId'] -or
                $parsed.ProcessId -is [bool] -or $parsed.ProcessId -is [Array] -or
                -not [int]::TryParse([string]$parsed.ProcessId, [ref]$processId) -or $processId -lt 0) {
                throw 'Registration process identity is invalid.'
            }
            $value['ProcessId'] = $processId
        }
        if ($Projection -eq 'Discovery') {
            $key = if ($Kind -eq 'claude') { Get-ClaudeSafeSessionKey -SessionId $value.SessionId }
                else { Get-CodexSafeSessionKey -SessionId $value.SessionId }
            $comparison = if ($script:BridgeIsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
            if (-not [string]::Equals($file.Name, "$key.json", $comparison)) { throw 'Registration identity does not match its path.' }
            $value['Ended'] = $false
            if ($Kind -eq 'codex' -and $parsed.PSObject.Properties['Ended']) {
                if ($parsed.Ended -isnot [bool]) { throw 'Registration ended state is invalid.' }
                $value['Ended'] = $parsed.Ended
            }
        }
        $file.Refresh()
        if (-not $file.Exists -or $file.LastWriteTimeUtc.Ticks -ne $stamp -or $file.Length -ne $length) {
            $code = 'ChangedDuringRead'
            throw 'Registration changed during the read.'
        }
        return [pscustomobject]@{ Known = $true; Record = [pscustomobject]$value; Stamp = $stamp; Path = $Path; Diagnostic = $null }
    }
    catch {
        if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
        return [pscustomobject]@{
            Known = $false; Record = $null; Stamp = $stamp; Path = $Path
            Diagnostic = [pscustomobject]@{ Kind = $Kind; Path = $Path; Code = $code }
        }
    }
}

function Read-DaemonAdapterRegistrations {
    param([Parameter(Mandatory)][ValidateSet('claude', 'codex')][string]$Kind, [Parameter(Mandatory)][string]$Root)
    if (Test-BridgeTestExecution) { Assert-BridgeTestPath -Path $Root }
    $inventory = Get-BridgeAgentProcesses -Agent $Kind -AsObservation
    $known = [bool]$inventory.Known
    $diagnostics = [Collections.Generic.List[object]]::new()
    foreach ($diagnostic in $inventory.Diagnostics) {
        if ($diagnostic.Code -ne 'ProcessDisappeared') {
            $diagnostics.Add([pscustomobject]@{ Kind = $Kind; Path = $Root; Code = $diagnostic.Code })
        }
    }
    $livePids = @{}
    foreach ($process in $inventory.Processes) { $livePids[[int]$process.Id] = $true }
    # Shared infrastructure is live but is nobody's session, so it is pre-accounted:
    # Codex's app-server daemon is named codex.exe and never registers, and requiring
    # a registration for it left Known false on every pass - no snapshot was ever
    # Complete, retirement and the orphan sweep were held, and Launch was refused.
    # Read defensively: an adapter from before Shared existed does not report it.
    $accounted = @{}
    if ($inventory.PSObject.Properties['Shared']) {
        foreach ($processId in @($inventory.Shared)) { $accounted[[int]$processId] = $true }
    }
    $records = [Collections.Generic.List[object]]::new()
    $files = @()
    try {
        if (Test-Path -LiteralPath $Root -ErrorAction Stop) {
            $directory = Get-Item -LiteralPath $Root -ErrorAction Stop
            if (-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Registration root is not an ordinary directory.'
            }
            $files = @(Get-ChildItem -LiteralPath $Root -Filter '*.json' -File -ErrorAction Stop)
        }
    }
    catch {
        if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
        $known = $false
        $diagnostics.Add([pscustomobject]@{ Kind = $Kind; Path = $Root; Code = 'EnumerationFailed' })
    }
    foreach ($file in $files) {
        if ($Kind -eq 'codex' -and $file.Name -like '*.approval.json') { continue }
        $read = Read-DaemonRegistrationFile -Path $file.FullName -Kind $Kind
        if (-not $read.Known) {
            $known = $false
            $diagnostics.Add($read.Diagnostic)
            continue
        }
        $entry = $read.Record
        $alive = $entry.ProcessId -gt 0 -and $livePids.ContainsKey($entry.ProcessId) -and -not $entry.Ended
        if ($entry.ProcessId -gt 0 -and $livePids.ContainsKey($entry.ProcessId)) {
            $accounted[$entry.ProcessId] = $true
        }
        if (-not $entry.Ended -and ($entry.ProcessId -eq 0 -or (-not $alive -and -not $inventory.Known))) {
            $known = $false
            $diagnostics.Add([pscustomobject]@{ Kind = $Kind; Path = $file.FullName; Code = 'OwnerUnresolved' })
            continue
        }
        if ($Kind -eq 'claude' -and $alive -and [string]::IsNullOrWhiteSpace($entry.TranscriptPath)) {
            $known = $false
            $diagnostics.Add([pscustomobject]@{ Kind = $Kind; Path = $file.FullName; Code = 'TranscriptIdentityMissing' })
            continue
        }
        $entry | Add-Member -NotePropertyName IsLive -NotePropertyValue $alive
        $entry | Add-Member -NotePropertyName StatePath -NotePropertyValue $file.FullName
        $records.Add($entry)
        $staleMinutes = if ($Kind -eq 'claude') { $script:ClaudeSessionStaleMinutes } else { $script:CodexSessionStaleMinutes }
        $fresh = -not $entry.Updated -or [DateTimeOffset]::Parse($entry.Updated) -gt [DateTimeOffset]::Now.AddMinutes(-$staleMinutes)
        # Keep a validated Ended receipt while its process is still draining. Deleting
        # it first would make that same process "unaccounted" on the retirement pass.
        $endedCanPrune = $entry.Ended -and ($entry.ProcessId -eq 0 -or ($inventory.Known -and -not $livePids.ContainsKey($entry.ProcessId)))
        if ($endedCanPrune -or (-not $entry.Ended -and $inventory.Known -and $entry.ProcessId -gt 0 -and
                -not $alive -and ($Kind -eq 'codex' -or -not $fresh))) {
            try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop }
            catch {
                if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
                $known = $false
                $diagnostics.Add([pscustomobject]@{ Kind = $Kind; Path = $file.FullName; Code = 'PruneFailed' })
            }
        }
    }
    foreach ($processId in $livePids.Keys) {
        if (-not $accounted.ContainsKey($processId)) {
            $known = $false
            $diagnostics.Add([pscustomobject]@{ Kind = $Kind; Path = $Root; Code = 'UnaccountedProcess' })
        }
    }
    [pscustomobject]@{ Known = $known; Records = @($records.ToArray()); Diagnostics = @($diagnostics.ToArray()) }
}

function New-DaemonDiscoverySnapshot {
    param([hashtable]$Live = @{}, [hashtable]$State = @{}, [switch]$Complete)
    $catalogue = @{}
    $previous = Get-Variable -Name DaemonOwnerCatalogue -Scope Script -ErrorAction SilentlyContinue
    $pending = Get-Variable -Name DaemonPendingRetire -Scope Script -ErrorAction SilentlyContinue
    $ids = @(@($State.Keys) + @($Live.Keys) + $(if ($pending) { @($pending.Value) } else { @() }) | Select-Object -Unique)
    foreach ($id in $ids) {
        if (-not $id) { continue }
        $kind = ''
        $path = ''
        if ($Live.ContainsKey($id)) {
            $session = $Live[$id]
            if ($session.PSObject.Properties['Kind']) { $kind = [string]$session.Kind }
            if ($session.PSObject.Properties['RegistrationPath']) { $path = [string]$session.RegistrationPath }
        }
        if (-not $kind -and $State.ContainsKey($id) -and $null -ne $State[$id] -and $State[$id].PSObject.Properties['Kind']) {
            $kind = [string]$State[$id].Kind
        }
        if (-not $path -and $previous -and $previous.Value.ContainsKey($id)) {
            $kind = [string]$previous.Value[$id].Kind
            $path = [string]$previous.Value[$id].Path
        }
        $keyReader = if ($kind -eq 'claude') { 'Get-ClaudeSafeSessionKey' } else { 'Get-CodexSafeSessionKey' }
        if (-not $path -and $kind -in @('claude', 'codex') -and (Get-Command $keyReader -ErrorAction SilentlyContinue)) {
            $key = if ($kind -eq 'claude') { Get-ClaudeSafeSessionKey -SessionId $id } else { Get-CodexSafeSessionKey -SessionId $id }
            $path = Get-BridgeRuntimePath "agent-bridge-$kind\$key.json"
        }
        $catalogue[$id] = [pscustomobject]@{ SessionId = [string]$id; Kind = $kind; Path = $path }
    }
    [pscustomobject]@{
        Complete = [bool]$Complete; Live = $Live; PositiveLive = $Live
        OwnerCatalogue = $catalogue; UncertainIds = @{}; UncertainKinds = @{}
        Diagnostics = [Collections.Generic.List[object]]::new()
    }
}

function Set-DaemonDiscoveryUncertain {
    param(
        [AllowNull()]$Snapshot = $null, [string]$Kind = '', [string]$Path = '',
        [string]$SessionId = '', [string]$Code = 'RecordUnreadable'
    )
    if ($null -eq $Snapshot) {
        $current = Get-Variable -Name DaemonDiscoverySnapshot -Scope Script -ErrorAction SilentlyContinue
        if ($current -and $current.Value) { $Snapshot = $current.Value }
        else {
            $active = Get-Variable -Name DaemonLive -Scope Script -ErrorAction SilentlyContinue
            $map = if ($active -and $active.Value -is [hashtable]) { $active.Value } else { @{} }
            $Snapshot = New-DaemonDiscoverySnapshot -Live $map
            $script:DaemonDiscoverySnapshot = $Snapshot
        }
    }
    $Snapshot.Complete = $false
    $matches = @()
    if ($SessionId) { $matches = @($SessionId) }
    elseif ($Path) {
        $comparison = if ($script:BridgeIsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        $matches = @($Snapshot.OwnerCatalogue.Keys | Where-Object {
            $owner = $Snapshot.OwnerCatalogue[$_]
            $owner.Kind -eq $Kind -and $owner.Path -and [string]::Equals($owner.Path, $Path, $comparison)
        })
    }
    foreach ($id in $matches) {
        $Snapshot.UncertainIds[$id] = $true
        [void]$Snapshot.Live.Remove($id)
    }
    if ($matches.Count -eq 0) { $Snapshot.UncertainKinds[$Kind] = $true }
    $Snapshot.Diagnostics.Add([pscustomobject]@{ Kind = $Kind; Path = $Path; Code = $Code; KnownOwners = @($matches) })
    Write-DaemonLog -Message "session discovery uncertain ($Kind/$Code); absence-based work is held"
}

function Test-DaemonRetirementObservation {
    param([AllowNull()]$Snapshot, [Parameter(Mandatory)][string]$SessionId)
    if (-not (Test-DaemonDiscoveryContext -Snapshot $Snapshot)) { return $false }
    if ($Snapshot.Live.ContainsKey($SessionId) -or $Snapshot.UncertainIds.ContainsKey($SessionId)) { return $false }
    # Unknown attribution deliberately protects the whole local negative namespace.
    # This does not add an owner to PositiveLive or expire uncertainty into death.
    [bool]$Snapshot.Complete
}

function Test-DaemonDiscoveryContext {
    param([AllowNull()]$Snapshot)
    if ($null -eq $Snapshot) { return $false }
    foreach ($field in @('Complete', 'Live', 'PositiveLive', 'UncertainIds', 'OwnerCatalogue')) {
        if (-not $Snapshot.PSObject.Properties[$field]) { return $false }
    }
    $Snapshot.Complete -is [bool] -and $Snapshot.Live -is [hashtable] -and
        $Snapshot.UncertainIds -is [hashtable] -and $Snapshot.OwnerCatalogue -is [hashtable] -and
        [object]::ReferenceEquals($Snapshot.Live, $Snapshot.PositiveLive)
}

function Update-DaemonOwnerCatalogue {
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)][hashtable]$State)
    $bounded = @{}
    foreach ($id in @(@($State.Keys) + @($Snapshot.Live.Keys) + @($script:DaemonPendingRetire) | Select-Object -Unique)) {
        if ($Snapshot.OwnerCatalogue.ContainsKey($id)) { $bounded[$id] = $Snapshot.OwnerCatalogue[$id] }
    }
    $script:DaemonOwnerCatalogue = $bounded
}

# The adapter failures already reported, keyed by adapter and message, so a reason is
# logged once rather than on every reconcile.
$script:DaemonAdapterFailureReported = @{}

function Get-DaemonSessionDiscovery {
    param([hashtable]$State = @{})
    $live = @{}
    $issues = [Collections.Generic.List[object]]::new()
    $selected = Get-BridgeSelectedClients
    foreach ($kind in @($script:DaemonAgents.Keys)) {
        if ($null -ne $selected -and $selected -notcontains $kind) { continue }
        try {
            $result = switch ($kind) {
                'claude' { Get-LiveClaudeSessions -AsObservation }
                'codex' { Get-LiveCodexSessions -AsObservation }
                default {
                    $find = (Get-DaemonAgent -Kind $kind).FindSessions
                    $map = if ($find) { & $find } else { @{} }
                    if ($map -isnot [hashtable]) { throw 'Invalid discovery result.' }
                    $inventory = Get-BridgeAgentProcesses -Agent $kind -AsObservation
                    $pids = @{}
                    foreach ($process in $inventory.Processes) { $pids[[int]$process.Id] = $true }
                    $validated = @{}
                    $accounted = @{}
                    $legacyIssues = [Collections.Generic.List[object]]::new()
                    foreach ($id in $map.Keys) {
                        $session = $map[$id]
                        $pidValue = 0
                        if ($null -eq $session -or -not $session.PSObject.Properties['ProcessId'] -or
                            -not [int]::TryParse([string]$session.ProcessId, [ref]$pidValue) -or
                            -not $pids.ContainsKey($pidValue)) {
                            $legacyIssues.Add([pscustomobject]@{ Kind = $kind; Path = ''; Code = 'SessionProcessUnresolved'; SessionId = [string]$id })
                            continue
                        }
                        $validated[$id] = $session
                        $accounted[$pidValue] = $true
                    }
                    foreach ($pidValue in $pids.Keys) {
                        if ($accounted.ContainsKey($pidValue)) { continue }
                        # Only a process nothing accounted for costs a command-line
                        # read, which is about 77 ms - normally there are none. An
                        # embedded CLI (Scout runs copilot.exe --headless) is not a
                        # session and never will be, so demanding one for it held
                        # discovery open for as long as that app stayed running.
                        $command = Get-BridgeCommandLine -ProcessId $pidValue -AsObservation
                        if ($command.State -eq 'Absent') { continue }
                        if ($command.State -eq 'Readable' -and
                            (Test-BridgeAgentEmbeddedProcess -CommandLine $command.Text)) { continue }
                        # Anything else stays unaccounted: excusing a process takes
                        # positive identification, never an unreadable command line.
                        $legacyIssues.Add([pscustomobject]@{ Kind = $kind; Path = ''; Code = 'UnaccountedProcess' })
                    }
                    foreach ($diagnostic in $inventory.Diagnostics) {
                        if ($diagnostic.Code -ne 'ProcessDisappeared') {
                            $legacyIssues.Add([pscustomobject]@{ Kind = $kind; Path = ''; Code = $diagnostic.Code })
                        }
                    }
                    [pscustomobject]@{
                        Known = $inventory.Known -and $legacyIssues.Count -eq 0
                        Live = $validated; Diagnostics = @($legacyIssues.ToArray())
                    }
                }
            }
            foreach ($id in $result.Live.Keys) {
                if ($live.ContainsKey($id)) {
                    $issues.Add([pscustomobject]@{ Kind = ''; Path = ''; Code = 'AmbiguousSessionId'; SessionId = [string]$id })
                }
                $live[$id] = $result.Live[$id]
            }
            foreach ($issue in $result.Diagnostics) { $issues.Add($issue) }
            if (-not $result.Known -and @($result.Diagnostics).Count -eq 0) {
                $issues.Add([pscustomobject]@{ Kind = $kind; Path = ''; Code = 'IncompleteAdapter' })
            }
        }
        catch {
            if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
            # Say what actually failed. "AdapterReadFailed" on its own cost an hour on
            # 2026-10-06: an adapter left behind by an update was shadowing
            # Get-BridgeAgentProcesses, so every adapter threw on an unknown
            # -AsObservation, and the log reported only that discovery was uncertain.
            $reason = [string]$_.Exception.Message
            $reportKey = "$kind|$reason"
            if (-not $script:DaemonAdapterFailureReported.ContainsKey($reportKey)) {
                $script:DaemonAdapterFailureReported[$reportKey] = $true
                try { Write-DaemonLog -Message "adapter $kind could not be read: $reason" } catch { }
            }
            $issues.Add([pscustomobject]@{ Kind = $kind; Path = ''; Code = 'AdapterReadFailed' })
        }
    }
    $snapshot = New-DaemonDiscoverySnapshot -Live $live -State $State -Complete
    foreach ($id in @($live.Keys)) {
        if (-not $State.ContainsKey($id) -or $null -eq $State[$id] -or
            -not $State[$id].PSObject.Properties['Kind'] -or
            -not $live[$id].PSObject.Properties['Kind']) { continue }
        $priorKind = [string]$State[$id].Kind
        if ($priorKind -in @('copilot', 'claude', 'codex') -and $priorKind -ne [string]$live[$id].Kind) {
            $issues.Add([pscustomobject]@{ Kind = ''; Path = ''; Code = 'OwnerKindChanged'; SessionId = [string]$id })
        }
    }
    foreach ($issue in $issues) {
        $id = if ($issue.PSObject.Properties['SessionId']) { [string]$issue.SessionId } else { '' }
        Set-DaemonDiscoveryUncertain -Snapshot $snapshot -Kind $issue.Kind -Path $issue.Path -Code $issue.Code -SessionId $id
    }
    foreach ($group in @($snapshot.OwnerCatalogue.Values | Where-Object Path | Group-Object Path -CaseSensitive:(-not $script:BridgeIsWindows))) {
        if ($group.Count -le 1) { continue }
        foreach ($owner in $group.Group) {
            Set-DaemonDiscoveryUncertain -Snapshot $snapshot -Kind $owner.Kind -Path $owner.Path `
                -SessionId $owner.SessionId -Code 'AmbiguousRegistrationPath'
        }
    }
    $snapshot
}

function Get-DaemonUnavailableAdapterObservation {
    param([Parameter(Mandatory)][ValidateSet('claude', 'codex')][string]$Kind)
    $inventory = Get-BridgeAgentProcesses -Agent $Kind -AsObservation
    $root = Get-BridgeRuntimePath "agent-bridge-$Kind"
    $hasRecords = $true
    try {
        $hasRecords = $false
        if (Test-Path -LiteralPath $root -ErrorAction Stop) {
            $directory = Get-Item -LiteralPath $root -ErrorAction Stop
            if (-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Unavailable adapter root is unreadable.'
            }
            $hasRecords = @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction Stop |
                Where-Object { $Kind -ne 'codex' -or $_.Name -notlike '*.approval.json' }).Count -gt 0
        }
    }
    catch {
        if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
        $hasRecords = $true
    }
    $known = $inventory.Known -and $inventory.Processes.Count -eq 0 -and -not $hasRecords
    [pscustomobject]@{
        Known = [bool]$known; Live = @{}
        Diagnostics = $(if ($known) { @() } else { @([pscustomobject]@{ Kind = $Kind; Path = $root; Code = 'AdapterUnavailable' }) })
    }
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
    param([switch]$AsObservation)
    $live = @{}
    if (-not $script:CodexAdapterLoaded) {
        $unavailable = Get-DaemonUnavailableAdapterObservation -Kind codex
        if ($AsObservation) { return $unavailable }
        if (-not $unavailable.Known) { throw 'Codex session discovery is unavailable.' }
        return $live
    }
    $observed = Get-CodexSessionRegistrations -AsObservation
    foreach ($registration in $observed.Records) {
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
            RegistrationPath = $registration.StatePath
        }
    }
    if ($AsObservation) { return [pscustomobject]@{ Known = $observed.Known; Live = $live; Diagnostics = $observed.Diagnostics } }
    if (-not $observed.Known) { throw 'Codex session discovery is incomplete; use its observation result.' }
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

function Get-DaemonEntityPresence {
    <#
        Whether one entity is there at all: 'present', 'absent' or 'unreadable'.

        An entity that does not exist is an ordinary state, not a failure, but the read
        above cannot say so on its own: it throws for a Home Assistant that answered
        "no such entity" and for one that could not be reached alike. The two call for
        opposite responses - rebuild the entity, or keep hands off until Home Assistant
        can be read again - so collapsing them is not safe in either direction. A live
        session whose card was torn down stayed torn down for hours because absence was
        swallowed as a read failure; republishing on an outage instead would reset the
        optimistic selector and blank a question somebody is waiting on.

        Absence is read off the response status, never off the wording of a message,
        for the reason Get-CopilotDecisionChannelObservation gives at length: the
        phrasing belongs to Home Assistant, a proxy or a translation, and matching it
        fails silently in both directions.
    #>
    param(
        [Parameter(Mandatory)][string]$EntityId,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $state = $null
    try { $state = Get-DaemonEntityState -EntityId $EntityId -Headers $Headers }
    catch {
        if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
        if ((Get-BridgeHttpStatusCode -ErrorRecord $_) -eq 404) { return 'absent' }
        return 'unreadable'
    }
    # A reader that answers with nothing rather than throwing is saying the same thing
    # a 404 says; the publish probes in Add-DaemonSession already read it that way.
    if ($null -eq $state) { return 'absent' }
    'present'
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
    param([switch]$AsObservation, [hashtable]$State = @{})
    if ($AsObservation) { return Get-DaemonSessionDiscovery -State $State }
    $live = @{}
    $selected = Get-BridgeSelectedClients
    foreach ($kind in @($script:DaemonAgents.Keys)) {
        if ($null -ne $selected -and $selected -notcontains $kind) { continue }
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
    param([switch]$AsObservation)
    $live = @{}
    if (-not $script:ClaudeAdapterLoaded) {
        $unavailable = Get-DaemonUnavailableAdapterObservation -Kind claude
        if ($AsObservation) { return $unavailable }
        if (-not $unavailable.Known) { throw 'Claude session discovery is unavailable.' }
        return $live
    }
    $observed = Get-ClaudeSessionRegistrations -AsObservation
    foreach ($registration in $observed.Records) {
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
            HookStatus       = if ($registration.PSObject.Properties['HookStatus']) { [string]$registration.HookStatus } else { '' }
            HookStatusAt     = if ($registration.PSObject.Properties['HookStatusAt']) { [string]$registration.HookStatusAt } else { '' }
            RegistrationPath = $registration.StatePath
        }
    }
    if ($AsObservation) { return [pscustomobject]@{ Known = $observed.Known; Live = $live; Diagnostics = $observed.Diagnostics } }
    if (-not $observed.Known) { throw 'Claude session discovery is incomplete; use its observation result.' }
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
