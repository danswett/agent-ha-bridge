<#
.SYNOPSIS
    Codex CLI session tracking for the Home Assistant bridge.

.DESCRIPTION
    Codex is the easiest of the three front ends to track, because its hooks carry
    almost everything the bridge needs:

      SessionStart       session_id, transcript_path, cwd, model, permission_mode, source
      UserPromptSubmit   + turn_id, prompt
      PreToolUse         + tool_name, tool_input, tool_use_id
      Stop               + stop_hook_active, last_assistant_message
      SessionEnd         + reason

    Those field names were captured from real sessions on Codex 0.155.0-alpha.6, not
    taken from documentation.

    Two consequences for this file. Activity does not need the transcript at all - the
    hooks report each prompt, tool call and reply directly - so the daemon only reads
    the rollout for reasoning. And liveness is authoritative rather than inferred:
    Codex fires an explicit SessionEnd, which neither Copilot nor Claude does, so a
    session is retired the moment it exits instead of when its process disappears.

    Two things Codex demands that the others do not, both learned the hard way:

    * Hooks must be **trusted** before they run. An untrusted hook is skipped in
      complete silence - no error, no log line - which looks exactly like a hook that
      was never registered. The installer explains this; the first run prompts.
    * The `command` string must not be shell-quoted. A quoted executable path fails
      with `hook exited with code 1`, while the same command unquoted runs fine.
#>

Set-StrictMode -Version Latest

# Windows/macOS differences, before anything reads $env:TEMP. Installed beside this
# file; in the repository it is the core's copy.
. $(if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'bridge-platform.ps1')) { Join-Path $PSScriptRoot 'bridge-platform.ps1' }
    else { Join-Path $PSScriptRoot '../../hooks/bridge-platform.ps1' })

$script:BridgeInstallContext = Resolve-BridgeInstallContext -EntryDirectory $PSScriptRoot
$script:CodexStateRoot = Get-BridgeRuntimePath 'agent-bridge-codex'
# Codex writes rollouts under CODEX_HOME/sessions/<yyyy>/<MM>/<dd>/.
$script:CodexHome = $script:BridgeInstallContext.CodexHome
$script:CodexSessionStaleMinutes = 240

function Get-CodexStateRoot {
    param([switch]$NoCreate)
    if (-not $NoCreate -and -not (Test-Path -LiteralPath $script:CodexStateRoot)) {
        New-Item -ItemType Directory -Path $script:CodexStateRoot -Force | Out-Null
    }
    $script:CodexStateRoot
}

function Get-CodexSafeSessionKey {
    <# Filesystem-safe key, so a hostile session id cannot escape the state directory. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$SessionId)

    $clean = ($SessionId -replace '[^a-zA-Z0-9._-]', '').TrimStart('.')
    if ([string]::IsNullOrWhiteSpace($clean)) { return 'unknown' }
    if ($clean.Length -gt 96) { $clean = $clean.Substring(0, 96) }
    $clean
}

function Get-CodexSessionDisplay {
    <#
        Names a session after its working directory, prefixed so its cards are
        distinguishable from Copilot's and Claude's on a shared dashboard.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SessionId,
        [string]$WorkingDirectory
    )

    $folder = if ($WorkingDirectory) { Split-Path -Leaf $WorkingDirectory } else { '' }
    if ([string]::IsNullOrWhiteSpace($folder)) {
        $folder = $SessionId.Substring(0, [Math]::Min(8, $SessionId.Length))
    }

    $name = "Codex: $folder"
    if ($name.Length -gt 120) { $name = $name.Substring(0, 117) + '...' }

    # The working directory is attacker-controllable - a folder called "{{ ... }}" is
    # enough - so template syntax is neutralised before this can reach a card.
    if (Get-Command Remove-CopilotTemplateMarkup -ErrorAction SilentlyContinue) {
        $name = Remove-CopilotTemplateMarkup -Text $name
    }

    [pscustomobject]@{
        Name    = $name
        Machine = [Environment]::MachineName
    }
}

function Get-CodexOwningProcessId {
    <#
        Finds the codex process that owns this hook by walking the parent chain, the
        same approach the Claude adapter uses: a hook runs as a descendant of its
        session, so this identifies the right one even with several open.

        Newer Codex runs hooks under a `codex.exe app-server` child of the terminal
        UI. That process has no console, so replies typed into it failed with
        attach-failed:6 (ERROR_INVALID_HANDLE); the walk carries on past it to the
        interactive codex.exe that owns the window.

        The app-server is also shared: a second Codex window reuses the one the first
        started, so its hooks run under the first window's process tree - or under
        no window at all once that one has closed. When the walk finds no window of
        its own, this session keeps the window it already recorded if that is still
        running; failing that, it takes the newest Codex window no other live
        session has claimed. The app-server is the last resort.
    #>
    param(
        [int]$StartPid = $PID, [int]$MaxDepth = 12, [string]$SessionId = '',

        # The chain a hook recorded, nearest first, for a walk made after it exited
        # (see Find-BridgeAgentAncestor): pids no longer running are skipped.
        [int[]]$Ancestors = @()
    )

    $recorded = @($Ancestors | Select-Object -First $MaxDepth)
    $fallback = 0
    $current = if ($recorded.Count -gt 0) { $recorded[0] } else { $StartPid }
    for ($depth = 0; $depth -lt $MaxDepth; $depth++) {
        if ($recorded.Count -gt 0 -and $depth -ge $recorded.Count) { break }
        if ($recorded.Count -gt 0) { $current = $recorded[$depth] }
        $process = Get-BridgeProcessInfo -ProcessId $current
        if (-not $process) {
            if ($recorded.Count -gt 0) { continue }
            break
        }
        # Exact match: codex-windows-sandbox-setup and codex-command-runner also exist.
        if (Test-BridgeAgentProcess -Process $process -Agent 'codex') {
            if (-not (Test-CodexAppServer -Process $process)) {
                # Under the shared app-server, the window above it can belong to a
                # different session: take it only if nobody else has.
                if ($fallback -eq 0 -or -not (Test-CodexWindowClaimed -ProcessId ([int]$process.ProcessId) -SessionId $SessionId)) {
                    return [int]$process.ProcessId
                }
                break
            }
            if ($fallback -eq 0) { $fallback = [int]$process.ProcessId }
        }
        if ($recorded.Count -gt 0) { continue }
        if (-not $process.ParentProcessId -or $process.ParentProcessId -eq $current) { break }
        $current = [int]$process.ParentProcessId
    }
    if ($fallback -eq 0) { return 0 }

    $windows = @(Get-BridgeProcessesNamed -Name 'codex' | Where-Object { -not (Test-CodexAppServer -Process $_) })

    # The window this session already recorded, while it runs.
    if ($SessionId) {
        $mine = Get-CodexRecordedProcessId -SessionId $SessionId
        if ($mine -gt 0 -and @($windows | Where-Object { [int]$_.ProcessId -eq $mine }).Count -gt 0) { return $mine }
    }

    $free = @($windows | Where-Object { -not (Test-CodexWindowClaimed -ProcessId ([int]$_.ProcessId) -SessionId $SessionId) } |
        Sort-Object CreationDate -Descending)
    if ($free.Count -gt 0) { return [int]$free[0].ProcessId }
    $fallback
}

function Test-CodexAppServer {
    <#
        Whether a codex process is the app-server rather than a terminal window. From
        its path where that is known (Windows: the daemon runs from
        ~\.codex\packages\app-server-daemon), which costs nothing; otherwise from its
        command line, fetched only then.
    #>
    param([Parameter(Mandatory)][object]$Process)
    $path = if ($Process.PSObject.Properties['Path']) { [string]$Process.Path } else { '' }
    if ($path) { return $path -match '[\\/]app-server-daemon[\\/]' }
    $commandLine = if ($Process.PSObject.Properties['CommandLine'] -and $Process.CommandLine) { [string]$Process.CommandLine }
        else { Get-BridgeCommandLine -ProcessId ([int]$Process.ProcessId) }
    $commandLine -match '\sapp-server(\s|$)'
}

function Get-CodexRecordedProcessId {
    param([Parameter(Mandatory)][string]$SessionId)
    $path = Join-Path (Get-CodexStateRoot) ((Get-CodexSafeSessionKey -SessionId $SessionId) + '.json')
    try { [int]((Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json).ProcessId) } catch { 0 }
}

function Test-CodexWindowClaimed {
    <# Whether another live session's registration already names this window. #>
    param([Parameter(Mandatory)][int]$ProcessId, [string]$SessionId = '')
    $root = Get-CodexStateRoot
    if (-not (Test-Path -LiteralPath $root)) { return $false }
    $ownKey = if ($SessionId) { (Get-CodexSafeSessionKey -SessionId $SessionId) + '.json' } else { '' }
    foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        if ($file.Name -eq $ownKey -or $file.Name -like '*.approval.json') { continue }
        try { $entry = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { continue }
        if ($entry.PSObject.Properties['Ended'] -and $entry.Ended) { continue }
        if ([int]($entry.ProcessId ?? 0) -eq $ProcessId) { return $true }
    }
    $false
}

function Write-CodexSessionRegistration {
    <#
        Records a session, its transcript and its owning process.

        Status is carried here as well, because Codex reports it directly: a turn
        starts at UserPromptSubmit and ends at Stop, so the daemon never has to guess
        from transcript freshness.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$TranscriptPath,
        [string]$WorkingDirectory,
        [string]$Model,
        [string]$Status,
        [string]$Activity,
        [int]$ProcessId = 0,
        [switch]$Ended
    )

    $path = Join-Path (Get-CodexStateRoot) ((Get-CodexSafeSessionKey -SessionId $SessionId) + '.json')
    $existing = if (Test-Path -LiteralPath $path) {
        try { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { $null }
    }

    # Later events carry less than SessionStart did, so anything already known is kept
    # rather than blanked.
    function Resolve-Field {
        param([string]$New, [string]$Field)
        if (-not [string]::IsNullOrWhiteSpace($New)) { return $New }
        if ($existing -and $existing.PSObject.Properties.Name -contains $Field) { return [string]$existing.$Field }
        ''
    }

    if ($ProcessId -le 0 -and $existing -and $existing.PSObject.Properties.Name -contains 'ProcessId') {
        $ProcessId = [int]$existing.ProcessId
    }

    [pscustomobject]@{
        SessionId        = $SessionId
        ProcessId        = $ProcessId
        TranscriptPath   = Resolve-Field -New $TranscriptPath -Field 'TranscriptPath'
        WorkingDirectory = Resolve-Field -New $WorkingDirectory -Field 'WorkingDirectory'
        Model            = Resolve-Field -New $Model -Field 'Model'
        Status           = if ($Ended) { 'ended' } else { Resolve-Field -New $Status -Field 'Status' }
        Activity         = Resolve-Field -New $Activity -Field 'Activity'
        Ended            = [bool]$Ended
        Updated          = [DateTimeOffset]::Now.ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding UTF8

    $path
}

function Get-CodexSessionRegistrations {
    <#
        Live sessions, pruning dead ones as it goes.

        A session is live until SessionEnd fires, so an ended one is dropped
        immediately. The process check is a safety net for a session killed outright,
        where no SessionEnd is delivered. Pruning matters because nothing else would
        ever remove these files.
    #>
    param([switch]$IncludeEnded, [switch]$AsObservation)

    if ($AsObservation) {
        return Read-DaemonAdapterRegistrations -Kind codex -Root (Get-CodexStateRoot -NoCreate)
    }

    $root = Get-CodexStateRoot
    if (-not (Test-Path -LiteralPath $root)) { return @() }

    $cutoff = [DateTimeOffset]::Now.AddMinutes(-$script:CodexSessionStaleMinutes)

    $livePids = @{}
    foreach ($process in @(Get-BridgeAgentProcesses -Agent 'codex')) {
        $livePids[$process.Id] = $true
    }

    foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        # Approval markers live in the same directory and also end in .json, so they
        # have to be skipped explicitly. Without this they are parsed as registrations,
        # and the missing fields throw under StrictMode - which took the daemon's whole
        # reconcile down, not just this function.
        if ($file.Name -like '*.approval.json') { continue }

        $entry = try { Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { $null }
        if (-not $entry) { continue }
        if ($entry.PSObject.Properties.Name -notcontains 'SessionId') { continue }

        $ended = ($entry.PSObject.Properties.Name -contains 'Ended' -and $entry.Ended)
        $knownPid = ($entry.PSObject.Properties.Name -contains 'ProcessId' -and [int]$entry.ProcessId -gt 0)
        $alive = $false
        if (-not $ended -and $knownPid) {
            $alive = $livePids.ContainsKey([int]$entry.ProcessId)
        }
        $fresh = $true
        if ($entry.PSObject.Properties.Name -contains 'Updated' -and $entry.Updated) {
            $fresh = ([DateTimeOffset]::Parse($entry.Updated) -gt $cutoff)
        }

        # Prune when the session is definitively over: it said goodbye, its process is
        # gone, or - with no pid to check - it went quiet for long enough to be
        # abandoned. The process check matters because a session killed outright never
        # fires SessionEnd. Quietness is only a signal when there is no pid: a running
        # process is live however long it has been idle, and treating a four-hour pause
        # as abandonment retired sessions that were still open.
        $finished = $ended -or ($knownPid -and -not $alive) -or (-not $knownPid -and -not $fresh)
        if (-not $IncludeEnded -and $finished) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            continue
        }

        if ($IncludeEnded -or $alive) {
            [pscustomobject]@{
                SessionId        = [string]$entry.SessionId
                ProcessId        = [int]($entry.ProcessId ?? 0)
                TranscriptPath   = [string]$entry.TranscriptPath
                WorkingDirectory = [string]$entry.WorkingDirectory
                Model            = [string]$entry.Model
                Status           = [string]$entry.Status
                Activity         = [string]$entry.Activity
                IsLive           = $alive -and -not $ended
                StatePath        = $file.FullName
            }
        }
    }
}

function Remove-CodexSessionRegistration {
    param([Parameter(Mandatory)][string]$SessionId)
    $path = Join-Path (Get-CodexStateRoot) ((Get-CodexSafeSessionKey -SessionId $SessionId) + '.json')
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

function Get-CodexApprovalMarkerPath {
    param([Parameter(Mandatory)][string]$SessionId)
    Join-Path (Get-CodexStateRoot) ((Get-CodexSafeSessionKey -SessionId $SessionId) + '.approval.json')
}

function Write-CodexApprovalMarker {
    <#
        Records that a command is waiting for approval.

        This is the daemon's gate, the same role the pending-decision marker plays for
        Copilot's ask_user: while it exists, an answer on the dashboard is delivered
        into the session's own approval prompt. It is removed as soon as any later
        event proves the prompt was answered, whichever way it was answered.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$DecisionId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Question
    )

    [pscustomobject]@{
        SessionId  = $SessionId
        DecisionId = $DecisionId
        Question   = $Question
        Created    = [DateTimeOffset]::Now.ToString('o')
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Get-CodexApprovalMarkerPath -SessionId $SessionId) -Encoding UTF8
}

function Get-CodexApprovalMarker {
    param([Parameter(Mandatory)][string]$SessionId, [switch]$RequireReadable)
    Read-DecisionMarkerFile -Path (Get-CodexApprovalMarkerPath -SessionId $SessionId) -RequireReadable:$RequireReadable
}

function Set-CodexApprovalAttempt {
    <# Claim the existing generation durably before touching native input. An
       incomplete write is unreadable ownership, never permission to send. #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$DecisionId,
        [Parameter(Mandatory)][ValidateSet('Approve', 'Deny')][string]$Choice
    )

    $path = Get-CodexApprovalMarkerPath -SessionId $SessionId
    $stream = $null
    try {
        $stream = [IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $true, 4096, $true)
        try { $raw = $reader.ReadToEnd() }
        finally { $reader.Dispose() }
        $marker = ConvertFrom-DecisionJson -Json $raw
        if ($marker -isnot [pscustomobject] -or
            -not $marker.PSObject.Properties['SessionId'] -or
            $marker.SessionId -isnot [string] -or
            -not [StringComparer]::Ordinal.Equals($marker.SessionId, $SessionId) -or
            -not $marker.PSObject.Properties['DecisionId'] -or $marker.DecisionId -isnot [string]) {
            throw [IO.InvalidDataException]::new('Invalid local approval identity.')
        }
        if (-not [StringComparer]::Ordinal.Equals($marker.DecisionId, $DecisionId)) { return $false }
        if ($marker.PSObject.Properties['DeliveryAttempted']) {
            if ($marker.DeliveryAttempted -isnot [bool] -or -not $marker.DeliveryAttempted) {
                throw [IO.InvalidDataException]::new('Invalid local approval attempt state.')
            }
            return $false
        }

        $marker | Add-Member -NotePropertyName DeliveryAttempted -NotePropertyValue $true
        $marker | Add-Member -NotePropertyName DeliveryChoice -NotePropertyValue $Choice
        $marker | Add-Member -NotePropertyName DeliveryAttemptedAt -NotePropertyValue ([DateTimeOffset]::Now.ToString('o'))
        $marker | Add-Member -NotePropertyName DeliveryOutcome -NotePropertyValue 'unconfirmed'
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($marker | ConvertTo-Json -Depth 8 -Compress))
        $stream.Position = 0
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.SetLength($bytes.Length)
        $stream.Flush($true)
        $true
    }
    catch [IO.FileNotFoundException] { $false }
    catch [IO.DirectoryNotFoundException] { $false }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Remove-CodexApprovalMarker {
    <# Returns $true when a marker was actually removed, so callers can tell whether
       there was anything pending. #>
    param([Parameter(Mandatory)][string]$SessionId)
    $path = Get-CodexApprovalMarkerPath -SessionId $SessionId
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    return $true
}

function Get-CodexHookEvent {
    <# Reads the hook event from stdin, returning $null when nothing usable arrives. #>
    param([string]$Raw)

    if (-not $Raw) { $Raw = [Console]::In.ReadToEnd() }
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    try { return $Raw | ConvertFrom-Json } catch { return $null }
}
