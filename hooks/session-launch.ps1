<#
    Launching a brand new agent session (Copilot, Agency, Claude or Codex) on request.

    Everything else in the bridge attaches to sessions that already exist: the daemon
    discovers them from the `inuse.<pid>.lock` files the CLI leaves behind. This
    module is the one place that starts one, so a session can be opened from the
    Home Assistant dashboard instead of from a keyboard.

    Three details make this work at all, and all three were verified against a live
    machine before this was written:

    * `--session-id` sets the UUID of a *new* session, not only of a resumed one. The
      daemon can therefore choose the id up front and knows exactly which session it
      just created, instead of racing to guess which of several new directories is
      the right one.
    * A process started by the hidden daemon still gets its own visible console
      window, because Start-Process goes through ShellExecute and creates a new
      console rather than inheriting the daemon's hidden one.
    * The session that results is completely ordinary. The daemon discovers it on the
      next reconcile and publishes it like any other, and console injection into it
      works, so the reply box and decision cards all function with no extra wiring.

    Nothing here needs Home Assistant, so it is straightforward to test offline.
#>

function Write-BridgeLaunchWarning {
    param([Parameter(Mandatory)][string]$Message)

    try {
        Microsoft.PowerShell.Utility\Write-Warning $Message
    }
    catch {
        # A long-running Windows daemon can survive with a poisoned console handle
        # after console attach/detach work. Warnings must not turn safe cleanup
        # failures into refused launches.
        try { Write-DecisionBridgeLog -Message "launch warning: $Message (warning host failed: $($_.Exception.Message))" } catch { }
    }
}

function ConvertTo-BridgeArgumentString {
    <#
        Builds a Windows command line from an argument array.

        Start-Process joins an -ArgumentList array with plain spaces and does no
        quoting of its own, so an argument containing a space silently becomes two
        arguments. The prompt typed on a phone is free text and arrives here
        unfiltered, so it has to be escaped properly rather than hopefully.

        Implements the rules CommandLineToArgvW parses: wrap an argument containing
        whitespace or a quote in double quotes, double any run of backslashes that
        immediately precedes a quote (or the closing quote), and escape embedded
        quotes with a backslash.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Arguments
    )

    $parts = foreach ($argument in $Arguments) {
        $value = [string]$argument
        if ($value.Length -gt 0 -and $value -notmatch '[\s"]') {
            $value
            continue
        }

        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append('"')
        $backslashes = 0
        foreach ($char in $value.ToCharArray()) {
            if ($char -eq '\') {
                $backslashes++
                continue
            }
            if ($char -eq '"') {
                # Every backslash run before a quote is doubled, then the quote itself
                # is escaped.
                [void]$sb.Append('\' * ($backslashes * 2 + 1))
                [void]$sb.Append('"')
                $backslashes = 0
                continue
            }
            if ($backslashes -gt 0) {
                [void]$sb.Append('\' * $backslashes)
                $backslashes = 0
            }
            [void]$sb.Append($char)
        }
        # Backslashes running up to the closing quote are doubled too, so the quote
        # is not swallowed as an escape.
        if ($backslashes -gt 0) { [void]$sb.Append('\' * ($backslashes * 2)) }
        [void]$sb.Append('"')
        $sb.ToString()
    }

    $parts -join ' '
}

$script:BridgeDiscoveredWorkspaceCache = $null
$script:BridgeDiscoveredWorkspaceCacheAt = [DateTimeOffset]::MinValue

function Test-BridgeSystemDirectory {
    <#
        True for a directory no session should be launched into.

        A console opened from the Start menu starts in System32, so that is a routine
        working directory for a session nobody meant to point anywhere in particular.
        Offering it back as a workspace would turn an accident into a default. The
        Windows folder, Program Files, ProgramData, temp and bare drive roots are all
        excluded for the same reason.
    #>
    param([Parameter(Mandatory)][string]$Path)

    try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/') }
    catch { return $true }

    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($full) -or $full -eq ([string]$root).TrimEnd('\', '/')) { return $true }

    # Wrapped whole: with one folder left (macOS has only TEMP) the pipeline gives a
    # string, and += on a string appends text rather than folders.
    $excluded = @(@($env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:TEMP) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if (-not $script:BridgeIsWindows) {
        $excluded += @('/System', '/Library', '/usr', '/bin', '/sbin', '/private', '/Applications', '/opt', '/var', '/etc')
    }
    $separator = [System.IO.Path]::DirectorySeparatorChar
    foreach ($candidate in $excluded) {
        $prefix = [System.IO.Path]::GetFullPath($candidate).TrimEnd('\', '/')
        if ($full -eq $prefix -or $full.StartsWith("$prefix$separator", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

function Get-BridgeDiscoveredWorkspaces {
    <#
        Folders agent sessions on this machine have recently worked in, newest first.

        These are suggestions for explicit approval in `newSession.workspaces`, not
        executable targets or a liveness authority. System folders are dropped
        (see Test-BridgeSystemDirectory). Disabled with
        `newSession.discoverWorkspaces: false`; `newSession.discoverCount` caps it.

        Cached for a minute, because the daemon asks several times per reconcile and
        the answer changes about as often as a new project is opened.
    #>
    if (-not [bool](Get-BridgeSetting 'newSession.discoverWorkspaces' $true)) { return @() }
    $limit = [int](Get-BridgeSetting 'newSession.discoverCount' 8)
    if ($limit -le 0) { return @() }

    if ($null -ne $script:BridgeDiscoveredWorkspaceCache -and
        ([DateTimeOffset]::Now - $script:BridgeDiscoveredWorkspaceCacheAt).TotalSeconds -lt 60) {
        return @($script:BridgeDiscoveredWorkspaceCache | Select-Object -First $limit)
    }

    $candidates = [System.Collections.Generic.List[object]]::new()

    # Hook registrations: what is running, or ran recently.
    foreach ($stateDir in @('agent-bridge-claude', 'agent-bridge-codex')) {
        $dir = Get-BridgeRuntimePath $stateDir
        if (-not [System.IO.Directory]::Exists($dir)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
            if ($file.Name -like '*.approval.json') { continue }
            try { $entry = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { continue }
            if ($entry -and $entry.PSObject.Properties['WorkingDirectory'] -and $entry.WorkingDirectory) {
                $candidates.Add([pscustomobject]@{ Path = [string]$entry.WorkingDirectory; Updated = $file.LastWriteTime })
            }
        }
    }

    # Claude transcripts: the history, one folder per project. The cwd is on nearly
    # every line, so only the head of the newest transcript in each is read.
    $projects = Join-Path (Get-BridgeInstallContext).ClaudeHome 'projects'
    if ([System.IO.Directory]::Exists($projects)) {
        $dirs = Get-ChildItem -LiteralPath $projects -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First ($limit * 3)
        foreach ($dir in $dirs) {
            $newest = Get-ChildItem -LiteralPath $dir.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($null -eq $newest) { continue }
            $reader = $null
            try {
                $reader = [System.IO.File]::OpenText($newest.FullName)
                for ($index = 0; $index -lt 40 -and -not $reader.EndOfStream; $index++) {
                    $line = $reader.ReadLine()
                    if ($line -notmatch '"cwd"') { continue }
                    $cwd = [string]($line | ConvertFrom-Json).cwd
                    if ($cwd) {
                        $candidates.Add([pscustomobject]@{ Path = $cwd; Updated = $newest.LastWriteTime })
                        break
                    }
                }
            }
            catch { }
            finally { if ($null -ne $reader) { $reader.Dispose() } }
        }
    }

    $seen = @{}
    $found = foreach ($candidate in ($candidates | Sort-Object Updated -Descending)) {
        try { $path = [System.IO.Path]::GetFullPath($candidate.Path).TrimEnd('\', '/') } catch { continue }
        $key = $path.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if (-not [System.IO.Directory]::Exists($path)) { continue }
        if (Test-BridgeSystemDirectory -Path $path) { continue }
        $path
    }

    $script:BridgeDiscoveredWorkspaceCache = @($found | Select-Object -First $limit)
    $script:BridgeDiscoveredWorkspaceCacheAt = [DateTimeOffset]::Now
    @($script:BridgeDiscoveredWorkspaceCache)
}

function Get-BridgeWorkspaceChoices {
    <#
        Explicitly configured executable targets. Discovery and an empty configuration
        cannot grant permission to launch in an additional directory.

        Each configured entry is either a plain path string or an object with `label`
        and `path`. A label keeps the dropdown readable on a phone, where a full path is
        unusable, and is what the daemon matches against when the button is pressed.

        This list is also the security boundary. The daemon never launches a path
        that came from Home Assistant; it launches a path from this list, selected by
        label. A wrong or tampered entity state can therefore only ever pick a
        directory the user configured, or nothing at all.

        Paths that do not exist are dropped rather than offered, so the dashboard
        cannot present a choice that is guaranteed to fail.
    #>
    $configured = @(Get-BridgeSetting 'newSession.workspaces' @())

    $choices = foreach ($entry in $configured) {
        $label = ''
        $path = ''
        if ($entry -is [string]) {
            $path = [string]$entry
        }
        elseif ($null -ne $entry -and $entry.PSObject.Properties['path']) {
            $path = [string]$entry.path
            if ($entry.PSObject.Properties['label']) { $label = [string]$entry.label }
        }
        if ([string]::IsNullOrWhiteSpace($path)) { continue }

        # A leading ~ is expanded so the config file stays portable between machines.
        if ($path.StartsWith('~')) { $path = Join-Path $HOME $path.Substring(1).TrimStart('\', '/') }
        try { $path = [System.IO.Path]::GetFullPath($path) } catch { continue }
        if (-not [System.IO.Directory]::Exists($path)) { continue }

        if ([string]::IsNullOrWhiteSpace($label)) { $label = [System.IO.Path]::GetFileName($path.TrimEnd('\', '/')) }
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $path }

        # `isolate` asks for every fresh launch here to get a git worktree of its own,
        # so two sessions in the same repository cannot move each other's HEAD. Only
        # ever set on a configured entry: a discovered folder is somewhere the user
        # happened to work, not somewhere they asked the bridge to manage.
        $isolate = $false
        if ($null -ne $entry -and $entry.PSObject.Properties['isolate']) {
            if ($entry.isolate -isnot [bool]) {
                Write-BridgeLaunchWarning "Workspace '$label' has a non-Boolean isolate setting; it is not an executable target."
                continue
            }
            $isolate = $entry.isolate
        }

        [pscustomobject]@{ Label = $label; Path = $path; Isolate = $isolate }
    }
    $choices = @($choices)

    # Home Assistant select options must be unique, so a duplicate label would make
    # two entries indistinguishable. Keep the first and suffix the rest with their
    # path rather than dropping a directory the user deliberately listed.
    $seen = @{}
    $unique = foreach ($choice in @($choices)) {
        $label = $choice.Label
        if ($seen.ContainsKey($label)) {
            $label = "$label ($($choice.Path))"
        }
        if ($seen.ContainsKey($label)) { continue }
        $seen[$label] = $true
        [pscustomobject]@{ Label = $label; Path = $choice.Path; Isolate = [bool]$choice.Isolate }
    }

    @($unique)
}

function Get-BridgeWorktreeRoot {
    <#
        Where the per-launch worktrees live. `newSession.worktreeRoot`, defaulting to
        ~/repos/wt.

        Deliberately one directory, outside every repository: it is what tells the
        bridge which worktrees are its own to prune. A worktree a person made
        somewhere else is never touched.
    #>
    $configured = [string](Get-BridgeSetting 'newSession.worktreeRoot' '~/repos/wt')
    if ([string]::IsNullOrWhiteSpace($configured)) { return '' }
    if ($configured.StartsWith('~')) { $configured = Join-Path $HOME $configured.Substring(1).TrimStart('\', '/') }
    try { [System.IO.Path]::GetFullPath($configured).TrimEnd('\', '/') } catch { '' }
}

function Get-BridgeWorkspaceChoice {
    <# The whole dropdown entry for a label, or $null when it is not on the list. #>
    param([string]$Label)

    if ([string]::IsNullOrWhiteSpace($Label)) { return $null }
    Get-BridgeWorkspaceChoices | Where-Object { $_.Label -eq $Label } | Select-Object -First 1
}

function Resolve-BridgeWorkspaceDirectory {
    <# GetFullPath alone does not resolve a junction or a symlink in an ancestor. #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not [System.IO.Path]::IsPathFullyQualified($Path)) { throw 'A workspace directory must be absolute.' }
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    $resolved = $root
    foreach ($part in ($full.Substring($root.Length) -split '[\\/]' | Where-Object { $_ })) {
        $entry = [System.IO.DirectoryInfo]::new((Join-Path $resolved $part))
        if (-not $entry.Exists) { throw "Workspace directory is missing or unreadable: $Path" }
        if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            $entry = $entry.ResolveLinkTarget($true)
            if ($null -eq $entry -or -not $entry.Exists -or $entry -isnot [System.IO.DirectoryInfo]) {
                throw "Workspace directory link could not be resolved: $Path"
            }
        }
        $resolved = $entry.FullName
    }
    [System.IO.Path]::TrimEndingDirectorySeparator($resolved)
}

function Get-BridgeWorkspaceRelativeDirectory {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$RepositoryRoot)
    $root = Resolve-BridgeWorkspaceDirectory -Path $RepositoryRoot
    $directory = Resolve-BridgeWorkspaceDirectory -Path $Path
    if (-not (Test-BridgeInstallPath -Left $directory -Right $root) -and
        -not (Test-BridgeInstallDescendant -Path $directory -Root $root)) {
        throw 'The configured workspace is outside its repository root.'
    }
    [System.IO.Path]::GetRelativePath($root, $directory)
}

function Test-BridgeWorkspacePathApproved {
    <# A resume stays in an approved folder, or in a managed worktree derived from
       an approved isolated repository. Historical discovery is not approval. #>
    param([AllowEmptyString()][AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Directory]::Exists($Path)) { return $false }
    try {
        $resolved = Resolve-BridgeWorkspaceDirectory -Path $Path
        $choices = @(Get-BridgeWorkspaceChoices)
        foreach ($choice in $choices) {
            if (Test-BridgeInstallPath -Left $resolved -Right (Resolve-BridgeWorkspaceDirectory $choice.Path)) { return $true }
        }
        if (@($choices | Where-Object Isolate).Count -eq 0) { return $false }
        $top = Invoke-BridgeGit -Directory $Path -Arguments @('rev-parse', '--show-toplevel')
        if (-not $top.Ok -or -not (Test-BridgeManagedWorktree -Path $top.Output)) { return $false }
        foreach ($choice in @($choices | Where-Object Isolate)) {
            $source = Invoke-BridgeGit -Directory $choice.Path -Arguments @('rev-parse', '--show-toplevel')
            if (-not $source.Ok) { continue }
            $relative = Get-BridgeWorkspaceRelativeDirectory -Path $choice.Path -RepositoryRoot $source.Output
            $targetRoot = Resolve-BridgeWorkspaceDirectory -Path $top.Output
            $corresponding = [System.IO.Path]::GetFullPath($relative, $targetRoot)
            if (-not [System.IO.Directory]::Exists($corresponding)) { continue }
            $corresponding = Resolve-BridgeWorkspaceDirectory -Path $corresponding
            if (-not (Test-BridgeInstallPath -Left $corresponding -Right $targetRoot) -and
                -not (Test-BridgeInstallDescendant -Path $corresponding -Root $targetRoot)) { continue }
            if (-not (Test-BridgeInstallPath -Left $resolved -Right $corresponding) -and
                -not (Test-BridgeInstallDescendant -Path $resolved -Root $corresponding)) { continue }
            foreach ($worktree in @(Get-BridgeManagedWorktree -RepositoryPath $choice.Path)) {
                if (Test-BridgeInstallPath -Left (Resolve-BridgeWorkspaceDirectory $top.Output) `
                    -Right (Resolve-BridgeWorkspaceDirectory $worktree)) { return $true }
            }
        }
    }
    catch { Write-BridgeLaunchWarning "Workspace approval could not be established: $($_.Exception.Message)" }
    $false
}

function Invoke-BridgeGit {
    <#
        Runs git in a directory and hands back its output and exit code, with stderr
        folded in. Callers must check Ok; a failed Git read is not an empty answer.
    #>
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$IndexFile = ''
    )

    $result = [pscustomobject]@{ Ok = $false; Output = ''; Code = -1 }
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $git) {
        $result.Output = 'Git is not available on PATH.'
        return $result
    }
    $process = [System.Diagnostics.Process]::new()
    try {
        $start = [System.Diagnostics.ProcessStartInfo]::new($git.Source)
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $start.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
        foreach ($argument in @('-C', $Directory) + $Arguments) { $start.ArgumentList.Add($argument) }
        # The declared directory, not the launching shell's Git context, owns this
        # operation. Cleanup's alternate index belongs only to this child.
        foreach ($name in @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE',
            'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES')) {
            [void]$start.Environment.Remove($name)
        }
        if ($IndexFile) { $start.Environment['GIT_INDEX_FILE'] = $IndexFile }
        $start.Environment['GIT_TERMINAL_PROMPT'] = '0'
        $process.StartInfo = $start
        if (-not $process.Start()) { throw 'Git did not start.' }
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $result.Code = $process.ExitCode
        $result.Output = ($stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()).Trim()
        $result.Ok = ($result.Code -eq 0)
    }
    catch { $result.Output = $_.Exception.Message }
    finally { $process.Dispose() }
    $result
}

function Enter-BridgeWorktreeOperation {
    param([Parameter(Mandatory)][string]$RepositoryPath)

    $common = Invoke-BridgeGit -Directory $RepositoryPath -Arguments @('rev-parse', '--path-format=absolute', '--git-common-dir')
    if (-not $common.Ok) { throw "Cannot establish repository ownership: $($common.Output)" }
    $directory = Resolve-BridgeWorkspaceDirectory -Path $common.Output
    $key = if ($script:BridgeIsWindows) { $directory.ToLowerInvariant() } else { $directory }
    $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
        [System.Text.Encoding]::UTF8.GetBytes($key))).ToLowerInvariant()
    $mutex = [System.Threading.Mutex]::new($false, "Local\AgentBridgeWorktree_$hash")
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne([TimeSpan]::Zero) }
        catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Another worktree operation is in progress; retry the launch after it finishes.' }
        [pscustomobject]@{ Mutex = $mutex; CommonDirectory = $directory }
    }
    catch { $mutex.Dispose(); throw }
}

function Get-BridgeWorkspaceManagedWorktree {
    param([Parameter(Mandatory)][string]$Path)
    $top = Invoke-BridgeGit -Directory $Path -Arguments @('rev-parse', '--show-toplevel')
    if ($top.Ok -and (Test-BridgeManagedWorktree -Path $top.Output)) { return $top.Output }
    ''
}

function New-BridgeWorktreeLaunchReservation {
    <# Git's own lock protects the gap between native start and registration, even
       across daemon failure and when worktreeIdleHours is zero. #>
    param([Parameter(Mandatory)][string]$WorktreePath)

    $marker = Get-BridgeWorktreeMarkerPath -Path $WorktreePath
    if (-not $marker) { throw 'Cannot reserve an unowned worktree for launch.' }
    $locked = Join-Path (Split-Path $marker -Parent) 'locked'
    if ([System.IO.File]::Exists($locked)) { return $null }
    $token = 'agent-bridge-launch:' + [guid]::NewGuid().ToString('N')
    $result = Invoke-BridgeGit -Directory $WorktreePath -Arguments @('worktree', 'lock', '--reason', $token, $WorktreePath)
    if (-not $result.Ok) { throw "Cannot protect the worktree while its session starts: $($result.Output)" }
    [pscustomobject]@{ Path = $WorktreePath; Token = $token }
}

function Remove-BridgeWorktreeLaunchReservation {
    param([Parameter(Mandatory)]$Reservation)
    $operation = $null
    try {
        if ([string]$Reservation.Token -cnotmatch '^agent-bridge-launch:[a-f0-9]{32}$') {
            throw 'The launch reservation does not identify a bridge-owned lock.'
        }
        $operation = Enter-BridgeWorktreeOperation -RepositoryPath ([string]$Reservation.Path)
        $marker = Get-BridgeWorktreeMarkerPath -Path ([string]$Reservation.Path)
        if (-not $marker) { throw 'The reserved worktree identity is no longer readable.' }
        $locked = Join-Path (Split-Path $marker -Parent) 'locked'
        if (-not [System.IO.File]::Exists($locked)) { return $true }
        if ([System.IO.File]::ReadAllText($locked).Trim() -cne [string]$Reservation.Token) {
            throw 'The worktree lock belongs to another owner; it was preserved.'
        }
        $result = Invoke-BridgeGit -Directory ([string]$Reservation.Path) `
            -Arguments @('worktree', 'unlock', [string]$Reservation.Path)
        if (-not $result.Ok) { throw "Cannot release the completed launch reservation: $($result.Output)" }
        $true
    }
    catch {
        Write-BridgeLaunchWarning "The worktree remains protected: $($_.Exception.Message)"
        $false
    }
    finally {
        if ($null -ne $operation) { $operation.Mutex.ReleaseMutex(); $operation.Mutex.Dispose() }
    }
}

function Read-BridgeCopilotWorkspace {
    param([Parameter(Mandatory)][string]$Path)
    $fields = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -notmatch '^(\w+):\s*(.*)$') { continue }
        $key = $Matches[1]
        $value = $Matches[2].Trim().Trim('"', "'")
        if ($key -eq 'cwd' -and $fields.ContainsKey($key)) { throw 'A Copilot workspace has ambiguous working directories.' }
        $fields[$key] = $value
    }
    $fields
}

function Get-BridgeWorktreeUsage {
    <# A read-only safety snapshot, not session discovery: no caps, cached answers,
       enrollment filtering, age-based retirement or deletion of registrations.
       An incomplete snapshot cannot authorize cleanup. #>
    $directories = [System.Collections.Generic.List[string]]::new()
    try {
        $processes = @(Get-Process -ErrorAction Stop)
        $allProcesses = @{}
        foreach ($process in $processes) { $allProcesses[[int]$process.Id] = $process }
        $agents = @{}
        if (-not $script:BridgeIsWindows) {
            foreach ($process in $processes) {
                if ($process.ProcessName -in @('node', 'bun') -and
                    [string]::IsNullOrWhiteSpace((Get-BridgeCommandLine -ProcessId $process.Id))) {
                    throw 'A potential native agent process has an unreadable command line.'
                }
            }
        }
        foreach ($kind in @('copilot', 'claude', 'codex')) {
            $agents[$kind] = @{}
            foreach ($process in $processes) {
                if (Test-BridgeAgentProcess -Process $process -Agent $kind) {
                    [void]$process.StartTime
                    $agents[$kind][[int]$process.Id] = $process
                }
                if (@($processes | Where-Object { Test-BridgeAgentProcess -Process $_ -Agent 'agency' }).Count) {
                    throw 'An Agency launcher is active; cleanup cannot rule out a session still starting.'
                }
            }
        }

        $stateRoot = [string]$script:DecisionBridgeConfig.SessionStateRoot
        $copilotProcesses = @($agents.copilot.Values)
        $named = Get-BridgeAgentProcessSessionIds -Processes $copilotProcesses
        $accounted = @{}
        if (Test-Path -LiteralPath $stateRoot -ErrorAction Stop) {
            foreach ($session in Get-ChildItem -LiteralPath $stateRoot -Directory -Force -ErrorAction Stop) {
                if ($session.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    throw 'A linked Copilot session directory cannot establish complete workspace usage.'
                }
                $owners = @{}
                foreach ($processId in $named.Keys) {
                    if ([string]$named[$processId] -eq $session.Name) { $owners[[int]$processId] = $true }
                }
                foreach ($lock in Get-ChildItem -LiteralPath $session.FullName -Filter 'inuse.*.lock' -File -Force -ErrorAction Stop) {
                    if ($lock.Name -notmatch '^inuse\.(\d+)\.lock$') { throw 'An invalid Copilot process lock prevents cleanup.' }
                    $processId = [int]$Matches[1]
                    if ($agents.copilot.ContainsKey($processId) -and
                        (-not $named.ContainsKey($processId) -or [string]$named[$processId] -eq $session.Name)) {
                        if (-not $named.ContainsKey($processId) -and
                            $lock.LastWriteTimeUtc -lt $agents.copilot[$processId].StartTime.ToUniversalTime()) {
                            throw 'A Copilot lock predates the current process generation; workspace usage is uncertain.'
                        }
                        $owners[$processId] = $true
                    }
                }
                if ($owners.Count -eq 0) { continue }
                $workspace = Read-BridgeCopilotWorkspace -Path (Join-Path $session.FullName 'workspace.yaml')
                $cwd = [string]$workspace['cwd']
                if (-not $cwd) { throw 'A live Copilot/Agency session has no readable working directory.' }
                $directories.Add((Resolve-BridgeWorkspaceDirectory -Path $cwd))
                foreach ($owner in $owners.Keys) { $accounted[$owner] = $true }
            }
        }
        foreach ($processId in $agents.copilot.Keys) {
            if (-not $accounted.ContainsKey($processId)) {
                throw 'A live Copilot/Agency process has no authoritative session working directory.'
            }
        }

        foreach ($kind in @('claude', 'codex')) {
            $root = Get-BridgeRuntimePath "agent-bridge-$kind"
            $accounted = @{}
            if (Test-Path -LiteralPath $root -ErrorAction Stop) {
                foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.json' -File -Force -ErrorAction Stop) {
                    if ($kind -eq 'codex' -and $file.Name -like '*.approval.json') { continue }
                    if ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                        throw "A linked $kind registration prevents cleanup."
                    }
                    $entry = [System.IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                    if ($entry -isnot [System.Collections.IDictionary] -or -not $entry['SessionId']) {
                        throw "An incomplete $kind registration prevents cleanup."
                    }
                    if ($kind -eq 'codex' -and $entry.Contains('Ended')) {
                        if ($entry['Ended'] -isnot [bool]) { throw 'An invalid Codex ended state prevents cleanup.' }
                        if ($entry['Ended']) { continue }
                    }
                    $processId = 0
                    if (-not [int]::TryParse([string]$entry['ProcessId'], [ref]$processId) -or $processId -le 0) {
                        throw "A $kind registration has no authoritative process identity."
                    }
                    if (-not $agents[$kind].ContainsKey($processId)) {
                        if ($allProcesses.ContainsKey($processId)) {
                            throw "A $kind registration names a different live process; ownership is uncertain."
                        }
                        continue
                    }
                    $rawUpdated = $entry['Updated']
                    if ($rawUpdated -isnot [datetime] -and $rawUpdated -isnot [DateTimeOffset] -and
                        $rawUpdated -isnot [string]) { throw "A $kind registration has no valid process-generation timestamp." }
                    $updated = [DateTimeOffset]$rawUpdated
                    $started = [DateTimeOffset]$agents[$kind][$processId].StartTime
                    if ($updated -lt $started -or $updated -gt [DateTimeOffset]::Now) {
                        throw "A $kind registration does not establish ownership of the current process generation."
                    }
                    if (-not $entry['WorkingDirectory']) { throw "A live $kind session has no working directory." }
                    $directories.Add((Resolve-BridgeWorkspaceDirectory -Path ([string]$entry['WorkingDirectory'])))
                    $accounted[$processId] = $true
                }
            }
            foreach ($processId in $agents[$kind].Keys) {
                if (-not $accounted.ContainsKey($processId)) {
                    throw "A live $kind process has no authoritative registration."
                }
            }
        }
        [pscustomobject]@{ Known = $true; Directories = @($directories.ToArray()); Detail = '' }
    }
    catch {
        [pscustomobject]@{ Known = $false; Directories = @(); Detail = $_.Exception.Message }
    }
}

function Test-BridgeWorktreeInUse {
    param([Parameter(Mandatory)][string]$WorktreePath, [Parameter(Mandatory)]$Usage)
    if (-not $Usage.Known) { return $true }
    $directory = Resolve-BridgeWorkspaceDirectory -Path $WorktreePath
    foreach ($cwd in $Usage.Directories) {
        if ((Test-BridgeInstallPath -Left $cwd -Right $directory) -or
            (Test-BridgeInstallDescendant -Path $cwd -Root $directory)) { return $true }
    }
    $false
}

function Get-BridgeRepositoryBaseRef {
    <#
        What a fresh worktree should start from: the remote's default branch, read
        from origin/HEAD rather than assumed to be main - plenty of repositories are
        still on master, and some use neither.

        Falls back to the checked-out HEAD, so a repository with no remote at all
        still gets a usable worktree.
    #>
    param([Parameter(Mandatory)][string]$RepositoryPath)

    $head = Invoke-BridgeGit -Directory $RepositoryPath -Arguments @('symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD')
    if ($head.Ok -and $head.Output -match 'refs/remotes/(origin/.+)$') { return $Matches[1] }
    if ($head.Code -notin @(0, 1)) { throw "Cannot read the repository's default reference: $($head.Output)" }
    foreach ($candidate in @('origin/main', 'origin/master')) {
        $check = Invoke-BridgeGit -Directory $RepositoryPath -Arguments @('rev-parse', '--verify', '--quiet', $candidate)
        if ($check.Ok -and $check.Output) { return $candidate }
        if ($check.Code -ne 1) { throw "Cannot read repository reference '$candidate': $($check.Output)" }
    }
    $local = Invoke-BridgeGit -Directory $RepositoryPath -Arguments @('rev-parse', '--verify', '--quiet', 'HEAD')
    if (-not $local.Ok) { throw 'The repository has no readable base commit for an isolated worktree.' }
    'HEAD'
}

function Get-BridgeWorktreeMarkerPath {
    <#
        Where a worktree's "made by the bridge" marker lives: inside its git admin
        directory, which is under the repository rather than in the worktree itself -
        so it can never show up as an untracked file and make the tree look dirty.

        Returns '' for anything that is not a linked worktree. A worktree's `.git` is
        a *file* holding `gitdir: <path>`, while a repository's own is a directory,
        so this also cannot mistake a primary clone for one of these.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $dotGit = Join-Path $Path '.git'
    if (-not [System.IO.File]::Exists($dotGit)) { return '' }
    $text = try { [System.IO.File]::ReadAllText($dotGit) } catch { '' }
    if ($text -notmatch '(?m)^gitdir:\s*(.+?)\s*$') { return '' }
    try { Join-Path ([System.IO.Path]::GetFullPath($Matches[1], [System.IO.Path]::GetFullPath($Path))) 'agent-bridge-created' } catch { '' }
}

function Test-BridgeManagedWorktree {
    <#
        Whether this directory is a worktree the bridge made for a launch.

        Asked by marker rather than by comparing paths against the worktree root.
        Comparing paths looked simpler and was wrong: on macOS the temporary and home
        directories are reached through symlinks, so git reports /private/var/... for
        a worktree created at /var/..., every prefix test failed, and not one worktree
        was recognised as the bridge's - which meant nothing was ever pruned, silently.
        A marker is also more precise: a worktree someone made by hand inside the same
        root is not the bridge's to remove.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $marker = Get-BridgeWorktreeMarkerPath -Path $Path
    [bool]($marker -and [System.IO.File]::Exists($marker))
}

function Get-BridgeWorktreeCreatedAt {
    <# An unreadable or malformed ownership marker cannot prove a tree old enough. #>
    param([Parameter(Mandatory)][string]$Path)

    $marker = Get-BridgeWorktreeMarkerPath -Path $Path
    if ($marker -and [System.IO.File]::Exists($marker)) {
        $raw = [System.IO.File]::ReadAllText($marker).Trim()
        $parsed = [datetime]::MinValue
        if ($raw -and [datetime]::TryParseExact($raw, 'o', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { return $parsed }
    }
    throw "The worktree's ownership timestamp is missing or invalid: $Path"
}

function Get-BridgeRepositoryWorktree {
    param([Parameter(Mandatory)][string]$RepositoryPath)

    $listed = Invoke-BridgeGit -Directory $RepositoryPath -Arguments @('worktree', 'list', '--porcelain', '-z')
    if (-not $listed.Ok) { throw "Cannot enumerate the repository's worktrees: $($listed.Output)" }

    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($field in ($listed.Output -split "`0")) {
        if (-not $field.StartsWith('worktree ')) { continue }
        $found.Add([System.IO.Path]::GetFullPath($field.Substring(9)))
    }
    @($found.ToArray())
}

function Get-BridgeManagedWorktree {
    <# The repository's registered, marked linked worktrees; never its primary tree. #>
    param([Parameter(Mandatory)][string]$RepositoryPath)
    @(Get-BridgeRepositoryWorktree -RepositoryPath $RepositoryPath |
        Where-Object { Test-BridgeManagedWorktree -Path $_ })
}

function Get-BridgeWorktreeTrackedPath {
    param([Parameter(Mandatory)][string]$WorktreePath)

    $entries = Invoke-BridgeGit -Directory $WorktreePath -Arguments @('ls-files', '--stage', '-z')
    if (-not $entries.Ok) { throw "Cannot read the tracked-file inventory: $($entries.Output)" }
    foreach ($entry in ($entries.Output -split "`0" | Where-Object { $_ })) {
        if ($entry -notmatch '(?s)^100(?:644|755) [a-f0-9]+ 0\t(.+)$') {
            throw 'Linked, conflicted or unsupported tracked entries require explicit worktree cleanup.'
        }
        $relative = $Matches[1]
        $file = [System.IO.Path]::GetFullPath($relative, $WorktreePath)
        if (-not (Test-BridgeInstallDescendant -Path $file -Root $WorktreePath)) { throw 'A tracked path escaped its worktree.' }
        $relative
    }
}

function Test-BridgeWorktreeFinished {
    <#
        Whether a managed worktree holds nothing worth keeping.

        Four things have to be true, and the first three are what make removing it
        safe rather than merely tidy: no uncommitted or untracked files, no branch
        checked out - a session that is working has one, and an unmerged branch is
        work - and no commit of its own on a detached HEAD. Such a worktree contains
        nothing that is not already in the repository.

        The fourth is age, because a launch that has only just happened is clean and
        detached too, and pulling the directory out from under it would end the
        session even though no work would be lost. Age comes from the marker the
        bridge wrote when it made the worktree, so nothing that merely reads the tree
        can disturb it.
    #>
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$BaseRef,
        [double]$IdleHours = 12
    )

    if (-not [System.IO.Directory]::Exists($WorktreePath)) { return $false }

    # Git can report clean ordinary entries while a physical ancestor is a junction,
    # or while assume-unchanged hides a missing file. Neither authorizes cleanup.
    try {
        Assert-BridgeInstallPayload -Root $WorktreePath -RelativePaths @('.git')
        $paths = @(Get-BridgeWorktreeTrackedPath -WorktreePath $WorktreePath)
        Assert-BridgeInstallPayload -Root $WorktreePath -RelativePaths $paths
        foreach ($path in $paths) {
            if (-not [System.IO.File]::Exists((Join-Path $WorktreePath $path))) {
                throw "A tracked path is missing, unreadable or not a regular file: $path"
            }
        }
    }
    catch { Write-BridgeLaunchWarning "Worktree physical paths could not be authorized: $($_.Exception.Message)"; return $false }

    # --no-optional-locks so asking the question cannot itself write to the index.
    $status = Invoke-BridgeGit -Directory $WorktreePath -Arguments @('--no-optional-locks', 'status', '--porcelain', '--untracked-files=all', '--ignored=matching')
    if (-not $status.Ok -or $status.Output) { return $false }

    $branch = Invoke-BridgeGit -Directory $WorktreePath -Arguments @('symbolic-ref', '--quiet', 'HEAD')
    if ($branch.Ok -or $branch.Code -ne 1) { return $false }

    $ahead = Invoke-BridgeGit -Directory $WorktreePath -Arguments @('rev-list', '--count', "$BaseRef..HEAD")
    if (-not $ahead.Ok -or $ahead.Output -ne '0') { return $false }

    try { $created = Get-BridgeWorktreeCreatedAt -Path $WorktreePath }
    catch { Write-BridgeLaunchWarning $_.Exception.Message; return $false }
    ([datetime]::Now - $created).TotalHours -ge $IdleHours
}

function Remove-BridgeWorktreeFiles {
    <# Even non-forced `git worktree remove` recursively deletes ignored files.
       Remove only clean tracked paths through a private index, then use rmdir's
       atomic empty-directory check. Never recursively delete a working directory. #>
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$BaseRef,
        [double]$IdleHours = 12
    )

    $marker = Get-BridgeWorktreeMarkerPath -Path $WorktreePath
    if (-not $marker) { return $false }
    $admin = Split-Path $marker -Parent
    if ([System.IO.File]::Exists((Join-Path $admin 'locked'))) { return $false }
    $ownedLocks = [System.Collections.Generic.List[object]]::new()
    $trackedPaths = @()
    $temporaryIndex = Join-Path $admin ("agent-bridge-cleanup-" + [guid]::NewGuid().ToString('N') + '.index')
    $dotGit = Join-Path $WorktreePath '.git'
    $stagedPointer = Join-Path (Split-Path $WorktreePath -Parent) ('.agent-bridge-cleanup-' + [guid]::NewGuid().ToString('N'))
    $removedTracked = $false
    $removedDirectory = $false
    try {
        foreach ($name in @('HEAD.lock', 'index.lock')) {
            $path = Join-Path $admin $name
            $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $ownedLocks.Add([pscustomobject]@{ Stream = $stream; Path = $path })
        }
        if (-not (Test-BridgeWorktreeFinished -WorktreePath $WorktreePath -BaseRef $BaseRef -IdleHours $IdleHours)) { return $false }
        $usage = Get-BridgeWorktreeUsage
        if (-not $usage.Known) { throw "Workspace usage is unknown: $($usage.Detail)" }
        if (Test-BridgeWorktreeInUse -WorktreePath $WorktreePath -Usage $usage) { return $false }

        $trackedPaths = @(Get-BridgeWorktreeTrackedPath -WorktreePath $WorktreePath)
        $directories = [System.Collections.Generic.HashSet[string]]::new(
            $(if ($script:BridgeIsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }))
        foreach ($relative in $trackedPaths) {
            $file = [System.IO.Path]::GetFullPath($relative, $WorktreePath)
            $parent = Split-Path $file -Parent
            while (Test-BridgeInstallDescendant -Path $parent -Root $WorktreePath) {
                [void]$directories.Add($parent)
                $parent = Split-Path $parent -Parent
            }
        }
        $prepared = Invoke-BridgeGit -Directory $WorktreePath -Arguments @('read-tree', 'HEAD') -IndexFile $temporaryIndex
        if (-not $prepared.Ok) { throw "Cannot prepare safe tracked-file cleanup: $($prepared.Output)" }
        if ($trackedPaths.Count -gt 0) {
            Assert-BridgeInstallPayload -Root $WorktreePath -RelativePaths (@('.git') + $trackedPaths)
            $removedTracked = $true
            $files = Invoke-BridgeGit -Directory $WorktreePath -Arguments @('rm', '-r', '--quiet', '--', '.') -IndexFile $temporaryIndex
            if (-not $files.Ok) { throw "Tracked-file cleanup was refused: $($files.Output)" }
        }
        foreach ($directory in @($directories | Sort-Object Length -Descending)) {
            if ([System.IO.Directory]::Exists($directory)) { [System.IO.Directory]::Delete($directory, $false) }
        }
        [System.IO.File]::Move($dotGit, $stagedPointer)
        [System.IO.Directory]::Delete($WorktreePath, $false)
        $removedDirectory = $true
    }
    catch { Write-BridgeLaunchWarning "Worktree cleanup stopped without recursive deletion: $($_.Exception.Message)" }
    finally {
        if (-not $removedDirectory) {
            if ([System.IO.File]::Exists($stagedPointer)) {
                try { [System.IO.File]::Move($stagedPointer, $dotGit) }
                catch { Write-BridgeLaunchWarning "Worktree metadata was retained at '$stagedPointer'; automatic restoration was refused: $($_.Exception.Message)" }
            }
            if ($removedTracked -and [System.IO.File]::Exists($dotGit)) {
                # Without --force, checkout-index restores missing files only. A new
                # user file is never overwritten to make an aborted cleanup look clean.
                try {
                    Assert-BridgeInstallPayload -Root $WorktreePath -RelativePaths (@('.git') + $trackedPaths)
                    $restore = Invoke-BridgeGit -Directory $WorktreePath -Arguments @('checkout-index', '--all')
                    if (-not $restore.Ok) { Write-BridgeLaunchWarning "Existing files were preserved; inspect the stopped worktree cleanup: $($restore.Output)" }
                }
                catch { Write-BridgeLaunchWarning "Worktree restoration refused uncertain physical paths: $($_.Exception.Message)" }
            }
        }
        foreach ($temporary in @($temporaryIndex) + $(if ($removedDirectory) { @($stagedPointer) } else { @() })) {
            try { if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) } }
            catch { Write-BridgeLaunchWarning "Cleanup metadata was retained at '$temporary': $($_.Exception.Message)" }
        }
        foreach ($lock in $ownedLocks) {
            try { $lock.Stream.Dispose() }
            finally {
                try { [System.IO.File]::Delete($lock.Path) }
                catch { Write-BridgeLaunchWarning "The owned cleanup lock could not be removed: $($_.Exception.Message)" }
            }
        }
    }
    # Leave the missing worktree's administration to Git's normal maintenance.
    # A repository-wide prune here would also retire other owners' missing trees.
    $removedDirectory
}

function Remove-BridgeFinishedWorktree {
    param([Parameter(Mandatory)][string]$RepositoryPath, [double]$IdleHours = 12)

    $removed = 0
    $operation = $null
    try {
        $operation = Enter-BridgeWorktreeOperation -RepositoryPath $RepositoryPath
        $baseRef = Get-BridgeRepositoryBaseRef -RepositoryPath $RepositoryPath
        $usage = Get-BridgeWorktreeUsage
        if (-not $usage.Known) { throw "Workspace usage is unknown: $($usage.Detail)" }
        foreach ($worktree in @(Get-BridgeManagedWorktree -RepositoryPath $RepositoryPath)) {
            if (Test-BridgeWorktreeInUse -WorktreePath $worktree -Usage $usage) { continue }
            $common = Invoke-BridgeGit -Directory $worktree -Arguments @('rev-parse', '--path-format=absolute', '--git-common-dir')
            if (-not $common.Ok -or -not (Test-BridgeInstallPath -Left (Resolve-BridgeWorkspaceDirectory $common.Output) -Right $operation.CommonDirectory)) {
                Write-BridgeLaunchWarning "Worktree repository ownership is uncertain; preserving '$worktree'."
                continue
            }
            if (-not (Test-BridgeWorktreeFinished -WorktreePath $worktree -BaseRef $baseRef -IdleHours $IdleHours)) { continue }
            if (Remove-BridgeWorktreeFiles -WorktreePath $worktree -BaseRef $baseRef -IdleHours $IdleHours) { $removed++ }
        }
    }
    catch { Write-BridgeLaunchWarning "Managed worktrees were retained because cleanup could not be authorized: $($_.Exception.Message)" }
    finally {
        if ($null -ne $operation) { $operation.Mutex.ReleaseMutex(); $operation.Mutex.Dispose() }
    }
    $removed
}

function New-BridgeSessionWorktree {
    <#
        A git worktree of its own for one launch, so two sessions in the same
        repository cannot move each other's HEAD - which is the whole reason this
        exists. Returns the directory to launch in and a line for the log.

        Failure has no executable path. The caller must refuse the launch rather than
        silently trading away requested isolation.
    #>
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [int]$Limit = -1,
        [double]$IdleHours = -1
    )

    $refused = [pscustomobject]@{ Path = ''; Isolated = $false; Detail = '' }
    if ($Limit -lt 0) { $Limit = [int](Get-BridgeSetting 'newSession.worktreeLimit' 10) }
    if ($IdleHours -lt 0) { $IdleHours = [double](Get-BridgeSetting 'newSession.worktreeIdleHours' 12) }
    if ($Limit -lt 0 -or $IdleHours -lt 0 -or [double]::IsNaN($IdleHours) -or [double]::IsInfinity($IdleHours)) {
        $refused.Detail = 'Worktree limits and idle hours must be nonnegative, finite values.'
        return $refused
    }

    $root = Get-BridgeWorktreeRoot
    if (-not $root) {
        $refused.Detail = 'The configured worktree root is empty or invalid; correct newSession.worktreeRoot.'
        return $refused
    }

    $inside = Invoke-BridgeGit -Directory $RepositoryPath -Arguments @('rev-parse', '--show-toplevel')
    if (-not $inside.Ok) {
        $refused.Detail = "Cannot establish the repository for isolation: $($inside.Output)"
        return $refused
    }

    $operation = $null
    try {
        $operation = Enter-BridgeWorktreeOperation -RepositoryPath $RepositoryPath
        # Finished worktrees are cleared before the cap is judged, so a long-lived
        # install does not end up refusing isolation because of sessions that ended days
        # ago. Best effort: a prune that fails must not stop a launch.
        $removed = 0
        try { $removed = Remove-BridgeFinishedWorktree -RepositoryPath $RepositoryPath -IdleHours $IdleHours }
        catch { Write-BridgeLaunchWarning "Worktree cleanup was refused; existing trees were retained: $($_.Exception.Message)" }

        $existing = @(Get-BridgeManagedWorktree -RepositoryPath $RepositoryPath)
        $registered = @(Get-BridgeRepositoryWorktree -RepositoryPath $RepositoryPath)
        if ($Limit -gt 0 -and $existing.Count -ge $Limit) {
            $refused.Detail = "$($existing.Count) managed worktrees already exist (limit $Limit); finish or explicitly remove some before launching."
            return $refused
        }

        # Fetch first so the worktree starts from what the remote has now, not from
        # whatever this clone last saw. Best effort: offline is not a reason to refuse.
        $fetch = Invoke-BridgeGit -Directory $RepositoryPath -Arguments @('fetch', 'origin', '--quiet')
        $baseRef = Get-BridgeRepositoryBaseRef -RepositoryPath $RepositoryPath

        $leaf = [System.IO.Path]::GetFileName($RepositoryPath.TrimEnd('\', '/'))
        if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = 'repo' }
        # Named for when it was made, so the directory says which session it belongs to
        # and two launches in the same second still get their own.
        $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
        $target = Join-Path $root "$leaf-$stamp"
        $suffix = 1
        while ((Test-Path -LiteralPath $target) -or @($registered | Where-Object { Test-BridgeInstallPath -Left $_ -Right $target }).Count -gt 0) {
            $target = Join-Path $root "$leaf-$stamp-$suffix"
            $suffix++
            if ($suffix -gt 50) {
                $refused.Detail = 'No unused worktree name is available; existing directories were preserved.'
                return $refused
            }
        }

        try { [void][System.IO.Directory]::CreateDirectory($root) }
        catch {
            $refused.Detail = "Cannot create the worktree root: $($_.Exception.Message)"
            return $refused
        }
        $added = Invoke-BridgeGit -Directory $RepositoryPath -Arguments @('worktree', 'add', '--detach', $target, $baseRef)
        if (-not $added.Ok -or -not [System.IO.Directory]::Exists($target)) {
            $refused.Detail = "Could not create an isolated worktree: $($added.Output)"
            return $refused
        }

        # The marker is what makes this one the bridge's to tidy up later, and carries the
        # moment it was made. If it cannot be written the worktree simply stays unmanaged
        # and is never pruned - the safe direction to fail in.
        try {
            $marker = Get-BridgeWorktreeMarkerPath -Path $target
            if ($marker) { [System.IO.File]::WriteAllText($marker, [DateTime]::Now.ToString('o')) }
        }
        catch { Write-BridgeLaunchWarning "The isolated worktree is retained unmanaged because its marker could not be written: $($_.Exception.Message)" }

        $relative = Get-BridgeWorkspaceRelativeDirectory -Path $RepositoryPath -RepositoryRoot $inside.Output
        $targetRoot = Resolve-BridgeWorkspaceDirectory -Path $target
        $launchPath = [System.IO.Path]::GetFullPath($relative, $targetRoot)
        if (-not [System.IO.Directory]::Exists($launchPath)) {
            $refused.Detail = 'The approved subdirectory is absent from the isolated base; the new worktree was retained without launching.'
            return $refused
        }
        $launchPath = Resolve-BridgeWorkspaceDirectory -Path $launchPath
        if (-not (Test-BridgeInstallPath -Left $launchPath -Right $targetRoot) -and
            -not (Test-BridgeInstallDescendant -Path $launchPath -Root $targetRoot)) {
            $refused.Detail = 'The approved subdirectory escapes the isolated worktree; launch was refused.'
            return $refused
        }
        $detail = "$launchPath from $baseRef"
        if ($removed -gt 0) { $detail += " (removed $removed finished)" }
        if (-not $fetch.Ok) { $detail += '; origin fetch failed, so the existing local base was used' }
        [pscustomobject]@{ Path = $launchPath; Isolated = $true; Detail = $detail }
    }
    catch {
        # Named rather than passed through raw. The console-handle failure described in
        # agent-bridge-supervisor.ps1 surfaces here as a Win32 message about console mode
        # with no hint that git, the worktree and the repository are all perfectly fine,
        # which cost a long diagnosis the first time. If that is what this is, say so and
        # say what fixes it.
        $message = $_.Exception.Message
        if ($message -match 'console mode|handle is invalid') {
            $refused.Detail = 'This machine''s bridge daemon has lost its console handle, so it cannot start an isolated worktree. Nothing is wrong with the repository. Restart the daemon (agent-ha-bridge restart) and try again.'
        }
        else {
            $refused.Detail = "Could not provide requested isolation: $message"
        }
        $refused
    }
    finally {
        if ($null -ne $operation) { $operation.Mutex.ReleaseMutex(); $operation.Mutex.Dispose() }
    }
}

function Resolve-BridgeWorkspacePath {
    <#
        Maps a dropdown label back to its approved directory. Returns $null for
        anything not currently on the list, which is what keeps an arbitrary string
        from Home Assistant out of the launch command.
    #>
    param([string]$Label)

    if ([string]::IsNullOrWhiteSpace($Label)) { return $null }
    $match = Get-BridgeWorkspaceChoices | Where-Object { $_.Label -eq $Label } | Select-Object -First 1
    if ($null -eq $match) { return $null }
    $match.Path
}

function Get-BridgeDefaultWorkspaceLabel {
    <#
        The workspace a launch uses when nothing has been chosen.

        Launching should take one button press, so both selectors need a real default
        rather than sitting at `unknown` and forcing a decision. `newSession.
        defaultWorkspace` names it; anything unset, or naming a workspace that is no
        longer on the list, falls back to the first entry so the button always works.
    #>
    $choices = @(Get-BridgeWorkspaceChoices)
    if ($choices.Count -eq 0) { return '' }

    $configured = [string](Get-BridgeSetting 'newSession.defaultWorkspace' '')
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        $match = $choices | Where-Object { $_.Label -eq $configured } | Select-Object -First 1
        if ($null -ne $match) { return [string]$match.Label }
    }

    [string]$choices[0].Label
}

function Get-BridgeCopilotPath {
    <#
        Locates copilot.exe. An explicit `newSession.copilotPath` wins; otherwise the
        one on PATH is used. The daemon runs from a scheduled task, whose PATH can be
        narrower than an interactive shell's, so the WinGet install location is
        checked as a last resort before giving up.
    #>
    $configured = [string](Get-BridgeSetting 'newSession.copilotPath' '')
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        if ([System.IO.File]::Exists($configured)) { return $configured }
        return $null
    }

    $command = Get-Command 'copilot' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command -and $command.Source) { return [string]$command.Source }

    if (-not $script:BridgeIsWindows) { return Find-BridgeUnixCommand -Name 'copilot' }

    $wingetPath = Join-Path $HOME 'AppData\Local\Microsoft\WinGet\Packages\GitHub.Copilot_Microsoft.Winget.Source_8wekyb3d8bbwe\copilot.exe'
    if ([System.IO.File]::Exists($wingetPath)) { return $wingetPath }

    $null
}

function Get-BridgeAgencyPath {
    <#
        Locates agency.exe, the Microsoft Agency launcher.

        Agency runs the same copilot.exe but applies a named profile: which MCP
        servers load, which plugins are mounted, and where logs go. Crucially
        `--profile-only` *ignores* the ambient ~/.copilot/mcp-config.json, so a
        session started through Agency loads the curated set for that profile rather
        than every server on the machine - which is the visible difference between a
        session launched here and one launched by hand.
    #>
    $configured = [string](Get-BridgeSetting 'newSession.agencyPath' '')
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        if ([System.IO.File]::Exists($configured)) { return $configured }
        return $null
    }

    $command = Get-Command 'agency' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command -and $command.Source) { return [string]$command.Source }

    if (-not $script:BridgeIsWindows) { return Find-BridgeUnixCommand -Name 'agency' }

    # Agency installs under Roaming and self-updates behind a CurrentVersion
    # junction, so this path stays correct across versions.
    $installed = Join-Path $env:APPDATA 'agency\CurrentVersion\agency.exe'
    if ([System.IO.File]::Exists($installed)) { return $installed }

    $null
}

function Get-BridgeClaudePath {
    <#
        Locates claude.exe. An explicit `newSession.claudePath` wins; otherwise PATH,
        then the native installer's location, which a scheduled task's narrower PATH
        may not include.
    #>
    $configured = [string](Get-BridgeSetting 'newSession.claudePath' '')
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        if ([System.IO.File]::Exists($configured)) { return $configured }
        return $null
    }

    $command = Get-Command 'claude' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command -and $command.Source) { return [string]$command.Source }

    if (-not $script:BridgeIsWindows) { return Find-BridgeUnixCommand -Name 'claude' }

    $native = Join-Path $HOME '.local\bin\claude.exe'
    if ([System.IO.File]::Exists($native)) { return $native }

    $null
}

function Get-BridgeCodexPath {
    <#
        Locates the Codex CLI. An explicit `newSession.codexPath` wins; otherwise PATH,
        then npm's global bin, where `npm i -g @openai/codex` puts its shim.
    #>
    $configured = [string](Get-BridgeSetting 'newSession.codexPath' '')
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        if ([System.IO.File]::Exists($configured)) { return $configured }
        return $null
    }

    $command = Get-Command 'codex' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command -and $command.Source) { return [string]$command.Source }

    if (-not $script:BridgeIsWindows) { return Find-BridgeUnixCommand -Name 'codex' }

    $npm = Join-Path $env:APPDATA 'npm\codex.cmd'
    if ([System.IO.File]::Exists($npm)) { return $npm }

    $null
}

function Find-BridgeUnixCommand {
    <#
        An agent's command on macOS where a LaunchAgent's minimal PATH would miss it:
        Homebrew (Apple silicon and Intel), the native installers' ~/.local/bin,
        Claude's own ~/.claude/local, and npm's global prefix.
    #>
    param([Parameter(Mandatory)][string]$Name)

    $dirs = @('/opt/homebrew/bin', '/usr/local/bin', '/opt/local/bin', (Join-Path $HOME '.local/bin'),
        (Join-Path $HOME '.claude/local'), (Join-Path $HOME '.npm-global/bin'), (Join-Path $HOME '.bun/bin'))
    foreach ($dir in $dirs) {
        $candidate = Join-Path $dir $Name
        if ([System.IO.File]::Exists($candidate)) { return $candidate }
    }
    # nvm and friends: whatever node is first on PATH, its bin folder.
    $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($node) {
        $candidate = Join-Path (Split-Path $node.Source -Parent) $Name
        if ([System.IO.File]::Exists($candidate)) { return $candidate }
    }
    $null
}

# Every agent the bridge can start, and what differs between them. The order is the
# one 'auto' prefers: Agency first, because a machine that has it expects sessions to
# carry an Agency profile. A launcher is not a session kind - Agency starts Copilot
# sessions - so each names the Kind it produces; the daemon's per-kind table is
# daemon-agents.ps1.
#
#   Label               shown on the dashboard
#   Kind                the kind of session it starts
#   Path                its executable, or $null when it is not installed
#   Usage               when it last ran here and whether it is signed in (for 'auto')
#   Resumable           its sessions that can be resumed; $Found holds what the
#                       launchers read before it returned
#   ResumeOrder         when Resumable is read: a session two sources know is listed
#                       under the first, so an agent's own files come before Agency,
#                       which also lists Claude sessions, and Copilot's store last
#   Arguments           its command line; without one, Copilot's (shared with Agency)
#   RegistrationFiles   the hook registrations that may be the launched session's;
#                       without one, Copilot's lock files are checked
#   ChoosesOwnSessionId it picks its session id, so none is invented for it (Codex)
#   NeedsFirstMessage   it only registers once sent a first message (Codex)
#   AnswersTrustPrompt  it asks whether to trust a new folder on start (Claude)
#   BlockingPrompt      given the launched window's screen, the note to show when the
#                       agent is stuck on a question only its window can answer (Codex's
#                       hook review), or $null
$script:BridgeLaunchers = [ordered]@{
    agency = @{
        Label = 'Agency'; Kind = 'copilot'
        Path = { Get-BridgeAgencyPath }
        # Agency runs Copilot underneath and keeps its sessions in Copilot's store.
        Usage = { Get-BridgeCopilotUsage }
        # Agency knows which of its sessions can resume.
        Resumable = { param($Limit, $Found) Get-BridgeAgencySessionEntries }
        ResumeOrder = 3
    }
    copilot = @{
        Label = 'Copilot'; Kind = 'copilot'
        Path = { Get-BridgeCopilotPath }
        Usage = { Get-BridgeCopilotUsage }
        # Copilot's own store fills in when Agency is not installed, or came back empty.
        Resumable = {
            param($Limit, $Found)
            # ContainsKey first: @($null) - Agency not installed - counts as one.
            if ($Found.ContainsKey('agency') -and @($Found['agency']).Count -gt 0) { return @() }
            Get-BridgeCopilotSessionEntries -Limit $Limit
        }
        ResumeOrder = 4
    }
    claude = @{
        Label = 'Claude'; Kind = 'claude'
        Path = { Get-BridgeClaudePath }
        Usage = {
            $claudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
            [pscustomobject]@{
                LastUsed = Get-BridgeNewestWriteTime -Path @((Join-Path $claudeHome 'history.jsonl'), (Join-Path $claudeHome 'projects')) -Depth 2
                SignedIn = (Test-Path -LiteralPath (Join-Path $claudeHome '.credentials.json')) -or [bool]$env:ANTHROPIC_API_KEY
            }
        }
        Resumable = { param($Limit, $Found) Get-BridgeClaudeSessionEntries -Limit $Limit }
        ResumeOrder = 1
        Arguments = {
            param($SessionId, $Model, $AllowAllTools, $Extras, $Resuming, $FlatPrompt, $Effort, $Context)
            $arguments = @()
            # Claude refuses an id already in use, so a resume needs `--resume <id>`.
            if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
                $arguments += if ($Resuming) { @('--resume', $SessionId) } else { @('--session-id', $SessionId) }
            }
            if (-not [string]::IsNullOrWhiteSpace($Model)) { $arguments += @('--model', $Model) }
            $arguments += @(Get-BridgeTuningArguments -Launcher 'claude' -Axis 'effort' -Value $Effort)
            $arguments += @(Get-BridgeTuningArguments -Launcher 'claude' -Axis 'context' -Value $Context)
            # Opt-in only, as for Copilot.
            if ($AllowAllTools) { $arguments += '--dangerously-skip-permissions' }
            $arguments += $Extras
            if ($FlatPrompt) { $arguments += @('--', $FlatPrompt) }
            $arguments
        }
        RegistrationFiles = {
            param($StateDir, $SessionId, $Since)
            @(Join-Path $StateDir "$SessionId.json" | Where-Object { [System.IO.File]::Exists($_) } | Get-Item)
        }
        AnswersTrustPrompt = $true
    }
    codex = @{
        Label = 'Codex'; Kind = 'codex'
        Path = { Get-BridgeCodexPath }
        Usage = {
            $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
            [pscustomobject]@{
                LastUsed = Get-BridgeNewestWriteTime -Path @((Join-Path $codexHome 'history.jsonl'), (Join-Path $codexHome 'sessions')) -Depth 4
                SignedIn = (Test-Path -LiteralPath (Join-Path $codexHome 'auth.json')) -or [bool]$env:OPENAI_API_KEY
            }
        }
        Resumable = { param($Limit, $Found) Get-BridgeCodexSessionEntries -Limit $Limit }
        ResumeOrder = 2
        Arguments = {
            param($SessionId, $Model, $AllowAllTools, $Extras, $Resuming, $FlatPrompt, $Effort, $Context)
            # Without its shared background daemon, Codex runs hooks from its own
            # window's process. Under the daemon - which has no console - Windows opened
            # a console window for every hook, several a turn, and a reply could not tell
            # which window was the session's.
            $arguments = @('--no-daemon')
            # Reasoning summaries, which the card streams; without this Codex writes its
            # reasoning encrypted and there is nothing to show.
            if ([bool](Get-BridgeSetting 'detailedActivity' $true)) { $arguments += @('-c', 'model_reasoning_summary=detailed') }
            # Effort and context are `-c` overrides rather than flags of their own, so
            # they join the one above, ahead of the subcommand where Codex reads its
            # global options.
            $arguments += @(Get-BridgeTuningArguments -Launcher 'codex' -Axis 'effort' -Value $Effort)
            $arguments += @(Get-BridgeTuningArguments -Launcher 'codex' -Axis 'context' -Value $Context)
            if ($Resuming) { $arguments += 'resume' }
            if (-not [string]::IsNullOrWhiteSpace($Model)) { $arguments += @('--model', $Model) }
            # Opt-in only. Codex keeps its sandbox; only approvals go.
            if ($AllowAllTools) { $arguments += @('--ask-for-approval', 'never') }
            $arguments += $Extras
            # `codex resume [OPTIONS] [SESSION_ID] [PROMPT]`: the id is the first positional.
            if ($Resuming) { $arguments += $SessionId }
            if ($FlatPrompt) { $arguments += @('--', $FlatPrompt) }
            $arguments
        }
        # Codex chooses its own session id, so its registration is recognised as the
        # first one written after the launch.
        RegistrationFiles = {
            param($StateDir, $SessionId, $Since)
            @(Get-ChildItem -LiteralPath $StateDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike '*.approval.json' -and $_.LastWriteTime -ge $Since.LocalDateTime })
        }
        ChoosesOwnSessionId = $true
        NeedsFirstMessage = $true
        # Codex asks, in its window, for the bridge's hooks to be trusted - once, and
        # again whenever they change (1.12.0 changed them). Until someone answers, no
        # hook runs and the session never registers, so the dashboard says so.
        BlockingPrompt = {
            param([string]$Screen)
            if ($Screen -match 'Hooks need review') {
                return "Codex in {0} is asking you to trust the bridge's hooks - it asks once after they change. Choose 'Trust all and continue' in its window, and it appears here."
            }
            $null
        }
    }
}

function Get-BridgeLauncher {
    <# A launcher's entry, with every slot and flag present; an unknown one has none. #>
    param([AllowEmptyString()][AllowNull()][string]$Launcher)

    $entry = @{
        Label = $Launcher; Kind = $Launcher; Path = $null; Usage = $null; Resumable = $null; ResumeOrder = 99; Arguments = $null
        RegistrationFiles = $null; ChoosesOwnSessionId = $false; NeedsFirstMessage = $false; AnswersTrustPrompt = $false
        BlockingPrompt = $null
    }
    if ($Launcher -and $script:BridgeLaunchers.Contains($Launcher)) {
        $own = $script:BridgeLaunchers[$Launcher]
        foreach ($slot in $own.Keys) { $entry[$slot] = $own[$slot] }
    }
    $entry
}

function Get-BridgeLauncherPath {
    param([Parameter(Mandatory)][string]$Launcher)

    $path = (Get-BridgeLauncher -Launcher $Launcher).Path
    if ($path) { return & $path }
    $null
}

$script:BridgePathRefreshedAt = [DateTimeOffset]::MinValue

function Update-BridgeProcessPath {
    <#
        Adds to this process's PATH any entries the machine and user PATH have gained
        since it started.

        The daemon runs for days, and a process's PATH is a copy taken when it started,
        so an agent installed afterwards - `npm install -g @openai/codex` adding npm's
        folder, say - stayed invisible until the daemon was restarted. Nothing is
        removed, and it runs at most once a minute.
    #>
    param([switch]$Force)

    # Windows keeps machine and user PATH in the registry; macOS has neither, and the
    # LaunchAgent is given the installer's PATH (Find-BridgeUnixCommand covers the rest).
    if (-not $script:BridgeIsWindows) { return }
    if (-not $Force -and ([DateTimeOffset]::Now - $script:BridgePathRefreshedAt).TotalSeconds -lt 60) { return }
    $script:BridgePathRefreshedAt = [DateTimeOffset]::Now

    $current = @($env:Path -split ';' | Where-Object { $_ })
    $known = @{}
    foreach ($entry in $current) { $known[$entry.TrimEnd('\').ToLowerInvariant()] = $true }

    $added = foreach ($scope in 'Machine', 'User') {
        $raw = [Environment]::GetEnvironmentVariable('Path', $scope)
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        foreach ($entry in ($raw -split ';')) {
            if ([string]::IsNullOrWhiteSpace($entry)) { continue }
            $expanded = [Environment]::ExpandEnvironmentVariables($entry)
            $key = $expanded.TrimEnd('\').ToLowerInvariant()
            if ($known.ContainsKey($key)) { continue }
            $known[$key] = $true
            $expanded
        }
    }
    if (@($added).Count -gt 0) { $env:Path = (@($current) + @($added)) -join ';' }
}

# How long the installed-agent list is kept. Finding each agent searches PATH and
# several install folders - about 75 ms for the four - and a reconcile asked four
# times, which made it half of every pass. A new install is still noticed within a
# minute, which is also how often PATH itself is refreshed.
$script:BridgeLauncherCacheSeconds = 60
$script:BridgeLauncherCache = $null

function Get-BridgeAvailableLaunchers {
    <#
        The launchers installed on this machine, in preference order. This is what the
        dashboard's agent selector offers, so it cannot show a choice that would fail.
    #>
    Update-BridgeProcessPath
    $cache = $script:BridgeLauncherCache
    if ($null -ne $cache -and $cache.Path -eq $env:PATH -and
        ([DateTimeOffset]::Now - $cache.At).TotalSeconds -lt $script:BridgeLauncherCacheSeconds) {
        return @($cache.Launchers)
    }
    $found = @(@($script:BridgeLaunchers.Keys) | Where-Object { Get-BridgeLauncherPath -Launcher $_ })
    $script:BridgeLauncherCache = [pscustomobject]@{ At = [DateTimeOffset]::Now; Path = $env:PATH; Launchers = $found }
    @($found)
}

function Get-BridgeLauncherLabel {
    param([Parameter(Mandatory)][string]$Launcher)
    [string](Get-BridgeLauncher -Launcher $Launcher).Label
}

function Resolve-BridgeLauncher {
    <#
        Maps an agent label from Home Assistant back to an installed launcher kind, or
        $null. Validated for the same reason workspaces and profiles are: a value
        arriving from outside never picks an executable unchecked.
    #>
    param([string]$Label)

    if ([string]::IsNullOrWhiteSpace($Label)) { return $null }
    foreach ($kind in @(Get-BridgeAvailableLaunchers)) {
        if ($Label -eq $kind -or $Label -eq (Get-BridgeLauncherLabel -Launcher $kind)) { return $kind }
    }
    $null
}

function Get-BridgeNewestWriteTime {
    <#
        The newest write time among the given files and folders, following a folder's
        newest child down up to -Depth levels (Codex files sessions by year\month\day).
        $null when none exists. Folder times move whenever an entry is added, so this
        stays cheap however many sessions there are.
    #>
    param([string[]]$Path, [int]$Depth = 1)

    $newest = $null
    foreach ($item in $Path) {
        if (-not $item) { continue }
        try {
            $info = Get-Item -LiteralPath $item -Force -ErrorAction Stop
            $level = 0
            while ($true) {
                if ($null -eq $newest -or $info.LastWriteTimeUtc -gt $newest) { $newest = $info.LastWriteTimeUtc }
                if (-not $info.PSIsContainer -or $level -ge $Depth) { break }
                $child = Get-ChildItem -LiteralPath $info.FullName -Force -ErrorAction Stop |
                    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
                if ($null -eq $child) { break }
                $info = $child
                $level++
            }
        }
        catch { }
    }
    $newest
}

function Get-BridgeLauncherUsage {
    <#
        What this machine says about how each agent is used: when a session of it
        last ran (LastUsed, UTC, or $null) and whether it has been signed in
        (SignedIn). 'auto' picks the default launcher from this.

        Agency runs Copilot underneath and keeps its sessions in Copilot's store, so
        the two share one history; Agency, first in preference order, wins the tie
        on a machine that has it.
    #>
    param([Parameter(Mandatory)][string]$Launcher)

    $usage = (Get-BridgeLauncher -Launcher $Launcher).Usage
    if ($usage) { return & $usage }
    [pscustomobject]@{ LastUsed = $null; SignedIn = $false }
}

function Get-BridgeCopilotUsage {
    <# Copilot's usage, which Agency shares (see Get-BridgeLauncherUsage). #>
    $copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }
    $state = Join-Path $copilotHome 'session-state'
    [pscustomobject]@{
        LastUsed = Get-BridgeNewestWriteTime -Path @($state) -Depth 2
        SignedIn = (Test-Path -LiteralPath $state) -or
            (Test-Path -LiteralPath (Join-Path $copilotHome 'config.json')) -or
            [bool]$env:GH_TOKEN -or [bool]$env:GITHUB_TOKEN -or [bool]$env:COPILOT_GITHUB_TOKEN
    }
}

$script:BridgeAutoLauncher = $null

function Get-BridgeAutoLauncher {
    <#
        The launcher 'auto' means: of the installed agents, the one used most recently
        on this machine; failing any history, one that is signed in; failing that, the
        first in preference order.

        A fixed order was wrong wherever more than one agent is installed: installing
        Copilot to try it made every dashboard launch a Copilot one on a machine used
        for Claude, and an agent never signed in cannot start a session at all.
        Cached for five minutes, since it only moves when a session starts.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Available)

    $key = $Available -join ','
    $cache = $script:BridgeAutoLauncher
    if ($null -ne $cache -and $cache.Key -eq $key -and ([DateTimeOffset]::Now - $cache.At).TotalMinutes -lt 5) {
        return $cache.Launcher
    }

    $ranked = for ($i = 0; $i -lt $Available.Count; $i++) {
        $usage = Get-BridgeLauncherUsage -Launcher $Available[$i]
        [pscustomobject]@{
            Launcher = $Available[$i]
            Order    = $i
            LastUsed = if ($null -ne $usage.LastUsed) { $usage.LastUsed.Ticks } else { [long]0 }
            SignedIn = [int][bool]$usage.SignedIn
        }
    }
    $best = @($ranked | Sort-Object -Property @(
            @{ Expression = 'LastUsed'; Descending = $true },
            @{ Expression = 'SignedIn'; Descending = $true },
            @{ Expression = 'Order'; Descending = $false })) | Select-Object -First 1
    $launcher = if ($null -ne $best) { [string]$best.Launcher } else { $null }

    $script:BridgeAutoLauncher = [pscustomobject]@{ Key = $key; At = [DateTimeOffset]::Now; Launcher = $launcher }
    $launcher
}

function Get-BridgeLauncherKind {
    <#
        The default launcher for new sessions: 'agency', 'copilot', 'claude' or 'codex'.

        `newSession.launcher` names it. 'auto' (the default), or a launcher that is not
        installed, picks among the installed ones by how this machine uses them (see
        Get-BridgeAutoLauncher) rather than failing. With nothing installed it still
        answers 'copilot', so the launch reports which executable is missing instead
        of doing nothing.
    #>
    $configured = ([string](Get-BridgeSetting 'newSession.launcher' 'auto')).Trim().ToLowerInvariant()
    $available = @(Get-BridgeAvailableLaunchers)

    if ($available -contains $configured) { return $configured }
    if ($available.Count -gt 0) { return [string](Get-BridgeAutoLauncher -Available $available) }
    'copilot'
}

# How long a discovered model list is kept. Only Copilot can be asked for one, and
# that costs a process launch (about 0.7 s), which is far too much to spend on every
# reconcile. Half an hour is well inside the time it takes to notice a new model
# exists, and a bridge restart re-reads it anyway.
$script:BridgeModelCacheMinutes = 30
$script:BridgeModelCache = $null

function Get-BridgeCopilotModelList {
    <#
        The models Copilot will accept, read from `copilot help config`.

        Copilot prints its model list under the `model` setting, which is the only
        machine-readable list any of the agents offer - Claude and Codex document
        theirs only in prose, so those stay configured lists. Discovering it matters
        because the set turns over quickly: a hard-coded list is wrong within weeks,
        and a wrong list here means a launch that fails at the command line.

        Returns @() when Copilot is not installed or the output does not parse, and
        the caller then falls back to its configured list.
    #>
    param([string]$Path)

    # The clock is checked before anything else, deliberately. Locating copilot.exe
    # searches PATH and several install folders - 5.3 ms measured - so an earlier
    # version that resolved the path to build its cache key paid the whole discovery
    # cost on every cache hit, and the three axes ask once each per reconcile. This is
    # the same trap Get-BridgeAvailableLaunchers documents for the launcher list.
    $cached = $script:BridgeModelCache
    if ($null -ne $cached -and ([DateTimeOffset]::Now - $cached.At).TotalMinutes -lt $script:BridgeModelCacheMinutes) {
        return @($cached.Models)
    }

    if (-not $Path) { $Path = Get-BridgeCopilotPath }
    if ([string]::IsNullOrWhiteSpace($Path)) { return @() }

    $models = @()
    try {
        $probe = Invoke-BridgeCommandProbe -Executable $Path -Arguments @('help', 'config')
        if (-not $probe.Ran -or $probe.TimedOut -or $probe.ExitCode -ne 0) { throw "Model discovery failed: $($probe.Output)" }
        $raw = $probe.StandardOutput
        # The block of quoted names directly under "`model`:" and nothing else: the
        # same file lists themes and modes in the same shape, so the match is anchored
        # to that heading rather than hunting for quoted strings anywhere.
        $block = [regex]::Match($raw, '(?ms)^\s*`model`:.*?\r?\n((?:[ \t]*-[ \t]*"[^"]+"[ \t]*\r?\n)+)')
        if ($block.Success) {
            $models = @([regex]::Matches($block.Groups[1].Value, '"([^"]+)"') |
                ForEach-Object { [string]$_.Groups[1].Value } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    }
    catch { }

    # Cached either way, including an empty answer: a machine where the call fails
    # should not retry it on every reconcile. A Copilot upgraded or installed in the
    # meantime is picked up when this expires, which is what the half hour is for.
    $script:BridgeModelCache = [pscustomobject]@{ At = [DateTimeOffset]::Now; Models = @($models) }
    @($models)
}

# What each agent accepts on each axis, and how it is spelled on the command line.
# Keyed by launcher kind, so Agency - which starts Copilot sessions - shares
# Copilot's entry.
#
#   Options     the values offered, beyond 'Agent default'
#   Discover    an optional extra source of Options, merged ahead of the built-in list
#   Arguments   the flag form of a chosen value
#
# Verified against the installed CLIs rather than guessed: `copilot --reasoning-effort
# bogus` and `--context bogus` both exit 1 naming the valid set, and `claude
# --autocompact bogus` prints the accepted range. Claude has no context-window switch
# at all; --autocompact, which sets the window it compacts at, is the nearest thing
# and is what the Context row drives for it.
$script:BridgeLauncherTuning = @{
    copilot = @{
        model = @{
            Options   = @('auto')
            Discover  = { Get-BridgeCopilotModelList }
            Arguments = { param($Value) @('--model', $Value) }
        }
        effort = @{
            Options   = @('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max')
            Arguments = { param($Value) @('--reasoning-effort', $Value) }
        }
        context = @{
            Options   = @('default', 'long_context')
            Arguments = { param($Value) @('--context', $Value) }
        }
    }
    claude = @{
        model = @{
            Options   = @('opus', 'sonnet', 'haiku', 'fable')
            Arguments = { param($Value) @('--model', $Value) }
        }
        effort = @{
            Options   = @('low', 'medium', 'high', 'xhigh', 'max')
            Arguments = { param($Value) @('--effort', $Value) }
        }
        context = @{
            Options   = @('auto', '200k', '500k', '1m')
            Arguments = { param($Value) @('--autocompact', $Value) }
        }
    }
    codex = @{
        model = @{
            Options   = @('gpt-5.3-codex', 'gpt-5.4', 'gpt-5.4-mini')
            Arguments = { param($Value) @('--model', $Value) }
        }
        effort = @{
            Options   = @('minimal', 'low', 'medium', 'high')
            Arguments = { param($Value) @('-c', "model_reasoning_effort=$Value") }
        }
        context = @{
            Options   = @('200000', '400000', '1000000')
            Arguments = { param($Value) @('-c', "model_context_window=$Value") }
        }
    }
}

function Get-BridgeTuningLauncherKey {
    <#
        Which tuning entry a launcher uses. Agency starts Copilot sessions and passes
        Copilot's own flags straight through, so the two share one entry rather than
        keeping duplicate lists that could drift apart.
    #>
    param([AllowEmptyString()][AllowNull()][string]$Launcher)
    if ($Launcher -eq 'agency') { return 'copilot' }
    [string]$Launcher
}

function Get-BridgeConfiguredTuning {
    <#
        The raw `newSession.<axis>.<launcher>` value, with no validation - or
        `newSession.model` for Copilot, which named the launch model before any of
        this existed and still does.

        Deliberately unvalidated. This comes from the bridge's own config file, which
        is exactly as trusted as `newSession.extraArgs` sitting beside it, and a
        machine configured for a model the installed CLI has not yet advertised
        (a preview, a BYOK provider) must keep working. What arrives from Home
        Assistant is a different matter and goes through Resolve-BridgeTuningValue.
    #>
    param(
        [Parameter(Mandatory)][string]$Launcher,
        [Parameter(Mandatory)][string]$Axis
    )

    $key = Get-BridgeTuningLauncherKey -Launcher $Launcher
    $configured = [string](Get-BridgeSetting "newSession.$Axis.$key" '')
    if ([string]::IsNullOrWhiteSpace($configured) -and $Axis -eq 'model') {
        $configured = [string](Get-BridgeSetting 'newSession.model' '')
    }
    $configured.Trim()
}

function Get-BridgeTuningOptions {
    <#
        What an agent's selector offers on one axis: 'Agent default' first, then the
        values it accepts.

        `newSession.<axis>s.<launcher>` replaces the built-in list outright, for the
        same reason `newSession.profiles` exists: the set of models worth offering is
        a matter of taste and of what an account can actually reach, and a list of
        twenty-six on a phone is not a choice, it is a scroll. A configured list is
        taken as given - it is the user's own - but is still validated on the way back
        in, so nothing here lets an arbitrary string reach a command line.

        The keys are `newSession.models.copilot`, `newSession.efforts.claude`,
        `newSession.contexts.codex` and so on; `agency` reads Copilot's key, since
        that is the command line it builds.
    #>
    param(
        [Parameter(Mandatory)][string]$Launcher,
        [Parameter(Mandatory)][string]$Axis
    )

    $key = Get-BridgeTuningLauncherKey -Launcher $Launcher
    $entry = $script:BridgeLauncherTuning[$key]
    if ($null -eq $entry -or -not $entry.ContainsKey($Axis)) { return @() }

    $configured = @(Get-BridgeSetting "newSession.${Axis}s.$key" @() |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $values = if ($configured.Count -gt 0) { $configured } else {
        $built = @($entry[$Axis].Options)
        # Discovery adds to the built-in list rather than replacing it, so 'auto' -
        # which Copilot accepts but does not print among its models - stays offered.
        if ($entry[$Axis].ContainsKey('Discover')) {
            $found = @()
            try { $found = @(& $entry[$Axis].Discover) } catch { }
            if ($found.Count -gt 0) { $built = @($built) + @($found) }
        }
        $built
    }

    # Distinct, order preserved, and never carrying the sentinel twice.
    $seen = @{}
    $ordered = New-Object System.Collections.Generic.List[string]
    $ordered.Add($script:BridgeTuningDefaultOption)
    $seen[$script:BridgeTuningDefaultOption] = $true
    # The configured default joins the list even when it is on no other, so a machine
    # set to a model its CLI does not advertise - a preview, a BYOK provider - can
    # still be seen and re-selected on the card rather than silently launching as
    # something the card never showed.
    foreach ($value in @(@(Get-BridgeConfiguredTuning -Launcher $Launcher -Axis $Axis)) + @($values)) {
        $text = [string]$value
        if ([string]::IsNullOrWhiteSpace($text) -or $seen.ContainsKey($text)) { continue }
        $seen[$text] = $true
        $ordered.Add($text)
    }
    $ordered.ToArray()
}

function Get-BridgeDefaultTuning {
    <#
        The value an axis opens on: what `newSession.<axis>.<launcher>` asks for, or
        'Agent default' when it asks for nothing.

        Falls back to 'Agent default' rather than refusing, for the same reason the
        workspace does: pressing Launch must never require a preceding selection.
    #>
    param(
        [Parameter(Mandatory)][string]$Launcher,
        [Parameter(Mandatory)][string]$Axis
    )

    $configured = Get-BridgeConfiguredTuning -Launcher $Launcher -Axis $Axis
    if ([string]::IsNullOrWhiteSpace($configured)) { return $script:BridgeTuningDefaultOption }
    $configured
}

function Resolve-BridgeTuningValue {
    <#
        Validates a value arriving from Home Assistant against what the chosen agent
        actually offers, and returns '' for "pass nothing" - the sentinel, an empty or
        unknown selector, or an option the agent does not have.

        The same contract as Resolve-BridgeWorkspacePath and Resolve-BridgeAgencyProfile:
        a value from outside is never put on a command line unchecked. It matters more
        here than for a profile, because these three land next to a shell invocation
        in the agent's own argument parser.

        Unlike those two, an unrecognised value is not an error worth refusing a launch
        over - it means the agent selector moved and this selector has not caught up
        yet - so it quietly means "agent default" instead.
    #>
    param(
        [Parameter(Mandatory)][string]$Launcher,
        [Parameter(Mandatory)][string]$Axis,
        [AllowEmptyString()][AllowNull()][string]$Value
    )

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    if ($text -in @($script:BridgeTuningDefaultOption, 'unknown', 'unavailable')) { return '' }

    $match = @(Get-BridgeTuningOptions -Launcher $Launcher -Axis $Axis) |
        Where-Object { $_ -eq $text } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($match) -or $match -eq $script:BridgeTuningDefaultOption) { return '' }
    [string]$match
}

function Get-BridgeTuningArguments {
    <#
        The flag form of one resolved value, or @() for "pass nothing".

        Takes the value through Resolve-BridgeTuningValue first, so this cannot be
        used to smuggle an unvalidated string onto a command line even if a caller
        forgets to validate.
    #>
    param(
        [Parameter(Mandatory)][string]$Launcher,
        [Parameter(Mandatory)][string]$Axis,
        [AllowEmptyString()][AllowNull()][string]$Value
    )

    $resolved = Resolve-BridgeTuningValue -Launcher $Launcher -Axis $Axis -Value $Value
    if ([string]::IsNullOrWhiteSpace($resolved)) { return @() }

    $key = Get-BridgeTuningLauncherKey -Launcher $Launcher
    $entry = $script:BridgeLauncherTuning[$key]
    if ($null -eq $entry -or -not $entry.ContainsKey($Axis)) { return @() }
    @(& $entry[$Axis].Arguments $resolved)
}

function Get-BridgeAgencyProfileNames {
    <#
        The profile names in `agency config profiles` output.

        Its shape is a heading, each profile indented under it, and each profile's
        MCPs and plugins indented further again:

            Profiles:
              home
                MCPs: none
                Plugins: none

        so a name is an indented line with no colon in it. Matched on the absence of a
        colon rather than on an exact indent, so a re-indented listing still parses. A
        machine with no profiles prints "No profiles configured." and no heading at
        all, which yields nothing - which is the answer.
    #>
    param([AllowEmptyString()][AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $names = New-Object System.Collections.Generic.List[string]
    $listing = $false
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^\s*Profiles:\s*$') { $listing = $true; continue }
        if (-not $listing) { continue }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # Back at column zero: the listing is over and this is something else.
        if ($line -notmatch '^\s') { break }
        if ($line -match ':') { continue }
        $name = $line.Trim()
        if ($name -and -not $names.Contains($name)) { $names.Add($name) }
    }
    $names.ToArray()
}

# How long a discovered profile list is kept. Asking Agency costs a process launch -
# 0.3 s measured warm - which is far too much to spend on every reconcile, and the
# list only changes when the config defining it does. Ten minutes bounds how long the
# card can be offering the previous set; restarting the bridge re-reads it at once.
$script:BridgeAgencyProfileCacheMinutes = 10
$script:BridgeAgencyProfileCache = $null

function Test-BridgeAgencyHasNoProfiles {
    <#
        Whether Agency answered, definitely, that this machine has none.

        `config profiles` is recent. An Agency from before it - 2026.7.18.2, say -
        answers with "unrecognized subcommand 'profiles'" and exit 2, which is
        indistinguishable from being unable to ask at all. Falling back to the
        configured list then offers profiles the machine does not have, and that is
        precisely the failure discovery exists to prevent: `--profile-only work` exits
        1 before Copilot starts, the window closes too fast to read, and all the
        dashboard ever says is "closed before it started".

        `config get` has been there throughout, and on a machine with no Agency config
        at all it fails with "Key 'profiles' not found in config". That is an answer -
        none - rather than a failure to ask. Offering no profile launches Agency's base
        config, which always works.

        Measured on DSWETT-DEV-VM1 on 2026-09-29: agency 2026.7.18.2, no config file
        found anywhere, `config profiles` exit 2, `config get profiles` exit 1 with
        that message, and every launch from the card dead on arrival.
    #>
    param($Probe)

    if ($null -eq $Probe -or -not $Probe.Ran -or $Probe.TimedOut) { return $false }
    if ($Probe.ExitCode -eq 0) { return $false }
    $text = ''
    # Output is stdout and stderr together; which stream carries it is Agency's
    # business and has moved between versions.
    if ($Probe.PSObject.Properties['Output']) { $text = [string]$Probe.Output }
    [bool]($text -match "Key\s+.{0,2}profiles.{0,2}\s+not found")
}

function Get-BridgeAgencyProfileList {
    <#
        Which profiles Agency actually has here, as @{ Ok; Profiles }.

        Ok is false only when Agency could not be asked at all - not installed, too
        old for `config profiles`, or the call failed - which is a different thing
        from a machine that genuinely has none, and the two fall back differently in
        Get-BridgeAgencyProfiles.
    #>
    param([string]$Path)

    # The clock is checked before anything else, deliberately: resolving agency.exe
    # searches PATH and the install folder, and several callers ask once per
    # reconcile. The same trap Get-BridgeCopilotModelList documents.
    $cached = $script:BridgeAgencyProfileCache
    if ($null -ne $cached -and ([DateTimeOffset]::Now - $cached.At).TotalMinutes -lt $script:BridgeAgencyProfileCacheMinutes) {
        return [pscustomobject]@{ Ok = [bool]$cached.Ok; Profiles = @($cached.Profiles) }
    }

    if (-not $Path) { $Path = Get-BridgeAgencyPath }

    $ok = $false
    $found = @()
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        # Run from the home directory rather than wherever the daemon happens to be:
        # Agency merges any agency.yaml found from the current directory upwards, so
        # asking from inside a repository that has one would offer profiles that exist
        # only there - and a launch in any other workspace would then fail.
        #
        # Ten seconds, where the probe's own default is five: this runs once every ten
        # minutes, and a timeout costs the card its profiles until the next one.
        $ask = @{ Executable = $Path; Arguments = @('config', 'profiles'); TimeoutMs = 10000 }
        # -WorkingDirectory only if the probe actually loaded has it. Each adapter
        # ships its own copy of bridge-platform.ps1 and the daemon loads whichever is
        # installed, so a checkout run against an older install can be holding a probe
        # from before this parameter existed - the same reason Get-ClaudeOwningProcessId
        # passes -Ancestors conditionally. Unguarded, the parameter binding throws and
        # takes the whole reconcile pass with it.
        $probeCommand = Get-Command Invoke-BridgeCommandProbe -ErrorAction SilentlyContinue
        if ($probeCommand -and $probeCommand.Parameters.ContainsKey('WorkingDirectory')) {
            $ask.WorkingDirectory = $HOME
        }
        $probe = $null
        try { $probe = Invoke-BridgeCommandProbe @ask } catch { }
        # An older probe returns only the flattened Output, whose lines are gone. That
        # counts as "could not be asked" rather than "has none", so a machine mid-update
        # keeps offering what it is configured with instead of losing its profiles.
        if ($null -ne $probe -and $probe.Ran -and -not $probe.TimedOut -and $probe.ExitCode -eq 0 -and
            $probe.PSObject.Properties['StandardOutput']) {
            $ok = $true
            $found = @(Get-BridgeAgencyProfileNames -Text ([string]$probe.StandardOutput))
        }

        # An Agency too old for `config profiles` is not the same as one that cannot be
        # asked, and treating it as the latter is what left this machine offering three
        # profiles it did not have. `config get` answers on every version.
        if (-not $ok) {
            $older = @{ Executable = $Path; Arguments = @('config', 'get', 'profiles'); TimeoutMs = 10000 }
            if ($probeCommand -and $probeCommand.Parameters.ContainsKey('WorkingDirectory')) {
                $older.WorkingDirectory = $HOME
            }
            $fallback = $null
            try { $fallback = Invoke-BridgeCommandProbe @older } catch { }
            if (Test-BridgeAgencyHasNoProfiles -Probe $fallback) {
                $ok = $true
                $found = @()
            }
        }
    }

    # Cached either way, a failure included: a machine where this cannot work should
    # not pay for it on every reconcile. An Agency installed or configured in the
    # meantime is picked up when the cache expires.
    $script:BridgeAgencyProfileCache = [pscustomobject]@{ At = [DateTimeOffset]::Now; Ok = $ok; Profiles = @($found) }
    [pscustomobject]@{ Ok = $ok; Profiles = @($found) }
}

function Get-BridgeAgencyProfiles {
    <#
        The Agency profiles offered on the dashboard: the ones this machine has.

        Asked of Agency rather than taken from a list in config, because a list naming
        a profile Agency does not have is a Launch button that cannot work.
        `agency copilot --profile-only work` on a machine with no `work` profile exits
        1 with "unknown profile `work` (available profiles: ...)" before Copilot
        starts, and the window closes far too fast to read; all the dashboard shows is
        "closed before it started". That is exactly what a newly installed machine
        looks like until whatever syncs the Agency config has run on it, and the
        built-in work/home/local list - right for the machine it was written on - made
        every launch there fail.

        `newSession.profiles` still applies where it is set, as the subset and the
        order to offer, but only of profiles that exist: it is no longer a way to name
        one that does not, since filtering is the whole point.
    #>
    $configured = @(Get-BridgeSetting 'newSession.profiles' @() |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $discovered = Get-BridgeAgencyProfileList
    # Agency could not be asked. A configured list is then all there is to go on, and
    # with none, no profile is offered at all - which launches Agency's base config,
    # and that always works.
    if (-not $discovered.Ok) { return @($configured) }

    $present = @($discovered.Profiles)
    if ($configured.Count -eq 0) { return $present }

    $filtered = @($configured | Where-Object { $present -contains $_ })
    # A configured list naming nothing that exists is stale rather than deliberate -
    # the same "the sync has not run here yet" case - so the machine's own profiles
    # are offered rather than an empty row.
    if ($filtered.Count -eq 0) { return $present }
    $filtered
}

function Resolve-BridgeAgencyProfile {
    <#
        Validates a profile name coming from Home Assistant against the profiles this
        machine has, for the same reason workspaces are resolved by label: a value
        arriving from outside is never passed to a command line unchecked.
    #>
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $match = Get-BridgeAgencyProfiles | Where-Object { $_ -eq $Name } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($match)) { return $null }
    $match
}

function Get-BridgeDefaultAgencyProfile {
    <#
        The Agency profile a launch uses when nothing has been chosen, from
        `newSession.defaultProfile`. Falls back to the first offered profile for the
        same reason the workspace does: pressing Launch must never require a preceding
        selection. Empty when the machine has no profiles, and a launch then passes
        none.
    #>
    $profiles = @(Get-BridgeAgencyProfiles)
    if ($profiles.Count -eq 0) { return '' }

    $configured = [string](Get-BridgeSetting 'newSession.defaultProfile' '')
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        $match = $profiles | Where-Object { $_ -eq $configured } | Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace($match)) { return [string]$match }
    }

    [string]$profiles[0]
}

function Get-BridgeNewSessionArguments {
    <#
        The argument list for a new session, kept separate from the launch itself so
        it can be asserted on in tests without starting anything.

        `-i` starts interactive mode *and* runs the prompt, which is what makes a
        dashboard-launched session useful: it begins working immediately, yet stays
        interactive so the reply box and decision cards keep working afterwards. With
        no prompt the session simply opens and waits.

        Under Agency the same Copilot arguments are forwarded as pass-through
        EXTRA_ARGS, behind Agency's own options. Agency takes `--session-id` itself
        and uses that UUID for both its session and the underlying Copilot one, so
        the daemon still knows the id up front either way.

        Claude takes `--session-id` too. Codex cannot be told its id; it reports the
        one it chose through its SessionStart hook. Both take the prompt as a
        positional argument, so it goes after `--`: a prompt typed as
        "--dangerously-skip-permissions" must stay a prompt, not become a flag.

        -Resume reopens the session named by -SessionId. Copilot and Agency do that
        with the same --session-id; Claude refuses an id already in use and needs
        `--resume <id>`; Codex needs its `resume <id>` subcommand.

        -Effort and -Context are spelled differently by every agent - Copilot has
        --reasoning-effort and --context, Claude has --effort and (for want of a real
        context switch) --autocompact, Codex has neither and takes both as `-c`
        overrides - so each launcher splices them in itself, from the one table in
        $script:BridgeLauncherTuning. Both are validated against that table on the way
        through, so an unknown value means "leave it to the agent" rather than
        reaching a command line.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SessionId,
        [string]$Prompt = '',
        [string]$Model = '',
        [string]$Effort = '',
        [string]$Context = '',
        [switch]$AllowAllTools,
        [string[]]$ExtraArguments = @(),
        [ValidateScript({ $script:BridgeLaunchers.Contains($_) })][string]$Launcher = 'copilot',
        [string]$AgencyProfile = '',
        [switch]$Resume
    )

    $flatPrompt = ($Prompt -replace '\r?\n', ' ').Trim()
    $extras = @(@($ExtraArguments) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [string]$_ })
    $resuming = $Resume.IsPresent -and -not [string]::IsNullOrWhiteSpace($SessionId)

    # A launcher with its own command line (Claude, Codex) builds it; Copilot and
    # Agency share the one below.
    $own = (Get-BridgeLauncher -Launcher $Launcher).Arguments
    if ($own) {
        return @(& $own $SessionId $Model $AllowAllTools.IsPresent $extras $resuming $flatPrompt $Effort $Context)
    }

    # Copilot-side arguments, identical in both modes.
    $copilotArguments = @('--banner')

    if (-not [string]::IsNullOrWhiteSpace($Model)) { $copilotArguments += @('--model', $Model) }
    $copilotArguments += @(Get-BridgeTuningArguments -Launcher 'copilot' -Axis 'effort' -Value $Effort)
    $copilotArguments += @(Get-BridgeTuningArguments -Launcher 'copilot' -Axis 'context' -Value $Context)

    # Off unless explicitly configured. A session launched from a phone may well run
    # unattended, so blanket approval is not handed out by default.
    #
    # --allow-all, not --allow-all-tools. Copilot splits permission into three axes -
    # tools, file paths and URLs - and the narrow flag grants only the first, so a
    # session launched with it still stopped dead on "allow access to this folder?"
    # with nobody watching. `--allow-all` is documented as exactly
    # `--allow-all-tools --allow-all-paths --allow-all-urls`, and is the flag form of
    # the `/allow-all` a user would type. It also makes Copilot match the other two,
    # which have always had the whole thing: Claude's --dangerously-skip-permissions
    # and Codex's --ask-for-approval never both cover everything, so Copilot was the
    # only launcher whose "launch without permission prompts" setting did not.
    if ($AllowAllTools.IsPresent) { $copilotArguments += '--allow-all' }

    foreach ($extra in @($ExtraArguments)) {
        if (-not [string]::IsNullOrWhiteSpace($extra)) { $copilotArguments += [string]$extra }
    }

    # The prompt goes last so a stray value in ExtraArguments cannot displace it.
    if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
        $copilotArguments += @('-i', ($Prompt -replace '\r?\n', ' ').Trim())
    }

    if ($Launcher -eq 'agency') {
        $arguments = @('copilot')
        # --profile-only, not --profile: it makes the named profile the whole
        # configuration and ignores ambient MCP sources, which is what keeps a
        # launched session matching a hand-launched one instead of loading every
        # server on the machine.
        if (-not [string]::IsNullOrWhiteSpace($AgencyProfile)) { $arguments += @('--profile-only', $AgencyProfile) }
        $arguments += @('--session-id', $SessionId)
        return @($arguments + $copilotArguments)
    }

    @(@('--session-id', $SessionId) + $copilotArguments)
}

function Get-BridgeAgencySessionJson {
    <#
        The raw JSON from `agency hub list-local-sessions --json`.

        Split out from the parsing so the parsing can be tested without Agency
        installed, and so the one slow, machine-dependent step sits behind a single
        seam.

        Agency prints a version banner and a log path before the payload, so the
        caller gets everything from the first brace onward; anything without a brace
        is treated as no data rather than parsed and thrown from.
    #>
    $agency = Get-BridgeAgencyPath
    if ([string]::IsNullOrWhiteSpace($agency)) { return '' }

    try {
        $probe = Invoke-BridgeCommandProbe -Executable $agency -Arguments @('hub', 'list-local-sessions', '--json') -TimeoutMs 30000
        if (-not $probe.Ran -or $probe.TimedOut -or $probe.ExitCode -ne 0) { throw "Session discovery failed: $($probe.Output)" }
        $raw = $probe.StandardOutput
    }
    catch {
        return ''
    }

    if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
    $start = $raw.IndexOf('{')
    if ($start -lt 0) { return '' }
    $raw.Substring($start)
}

function Get-BridgeAgencySessionEntries {
    <#
        Resumable sessions from Agency, as raw entries (Get-BridgeResumableSessions
        labels them).

        Agency aggregates sessions from the CLI, the desktop app and VS Code, and marks
        which are actually resumable. On a working machine that call returns about
        half a megabyte describing 700+ sessions and takes over a second, so it is
        never run on a reconcile - the daemon caches the list and refreshes it on a
        timer.

        `can_resume` is the filter that matters: desktop-app and VS Code sessions all
        report false, and resuming one in a terminal is not a thing.
    #>
    $json = Get-BridgeAgencySessionJson
    if ([string]::IsNullOrWhiteSpace($json)) { return @() }

    try { $parsed = $json | ConvertFrom-Json }
    catch { return @() }

    if ($null -eq $parsed -or -not $parsed.PSObject.Properties['sessions']) { return @() }

    $entries = foreach ($session in @($parsed.sessions)) {
        if (-not $session.can_resume) { continue }
        $id = [string]$session.session_id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }

        $updated = [DateTimeOffset]::MinValue
        if ($session.PSObject.Properties['updated_at']) {
            [void][DateTimeOffset]::TryParse([string]$session.updated_at, [ref]$updated)
        }

        [pscustomobject]@{
            SessionId = $id
            Launcher  = 'agency'
            Summary   = if ($session.PSObject.Properties['summary']) { [string]$session.summary } else { '' }
            Folder    = if ($session.PSObject.Properties['folder']) { [string]$session.folder } else { '' }
            Updated   = $updated
        }
    }
    @($entries)
}

function Read-BridgeFileEnds {
    <#
        The complete lines in the first and last -Bytes of a file, without reading the
        middle. Transcripts run to tens of megabytes, and what a resume list needs -
        where the session ran, its title, its first prompt - sits at either end.
    #>
    param([Parameter(Mandatory)][string]$Path, [int]$Bytes = 131072)

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
        $length = $stream.Length
        $read = {
            param([long]$Offset, [int]$Count)
            $buffer = New-Object byte[] $Count
            [void]$stream.Seek($Offset, 'Begin')
            $got = 0
            while ($got -lt $Count) {
                $n = $stream.Read($buffer, $got, $Count - $got)
                if ($n -le 0) { break }
                $got += $n
            }
            [System.Text.Encoding]::UTF8.GetString($buffer, 0, $got)
        }

        if ($length -le 2 * $Bytes) {
            return @((& $read 0 ([int]$length)) -split "\r?\n" | Where-Object { $_ })
        }
        # A cut line at the seam is dropped: the head's last line and the tail's first.
        $head = @((& $read 0 $Bytes) -split "\r?\n")
        $tail = @((& $read ($length - $Bytes) $Bytes) -split "\r?\n")
        @(@($head | Select-Object -SkipLast 1) + @($tail | Select-Object -Skip 1) | Where-Object { $_ })
    }
    catch { @() }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Get-BridgePromptSummary {
    <#
        A user prompt as a resume-list title, or '' for text that is not one: the
        wrappers the CLIs record around slash commands, environment context and
        caveats all start with a tag.
    #>
    param([AllowNull()][object]$Content)

    $text = ''
    if ($Content -is [string]) { $text = $Content }
    else {
        foreach ($part in @($Content)) {
            if ($null -ne $part -and $part.PSObject.Properties['text'] -and
                (-not $part.PSObject.Properties['type'] -or [string]$part.type -in @('text', 'input_text'))) {
                $text = [string]$part.text
                break
            }
        }
    }
    $text = ($text -replace '\s+', ' ').Trim()
    if (-not $text -or $text.StartsWith('<')) { return '' }
    $text
}

function Get-BridgeSessionFilesByAge {
    <#
        The newest files matching -Filter under the given folders, newest first,
        at most -Count of them.
    #>
    param([string[]]$Folder, [string]$Filter, [int]$Count, [switch]$Recurse)

    $files = foreach ($dir in @($Folder)) {
        if (-not $dir -or -not [System.IO.Directory]::Exists($dir)) { continue }
        Get-ChildItem -LiteralPath $dir -Filter $Filter -File -Recurse:$Recurse -Force -ErrorAction SilentlyContinue
    }
    @(@($files) | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $Count)
}

function Get-BridgeClaudeSessionEntries {
    <#
        Recent Claude Code sessions: ~/.claude/projects/<folder>/<session id>.jsonl.

        The title is the one the user gave (/rename, a custom-title line), else the
        one Claude generated (ai-title), else the first prompt. A session opened and
        closed without a prompt has none of these and is left out: there is nothing
        in it to go back to.
    #>
    param([int]$Limit)

    $claudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
    $projects = Join-Path $claudeHome 'projects'
    if (-not [System.IO.Directory]::Exists($projects)) { return @() }

    # Only each project folder's own files: subagent transcripts live in folders below.
    $folders = @(Get-ChildItem -LiteralPath $projects -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $files = Get-BridgeSessionFilesByAge -Folder $folders -Filter '*.jsonl' -Count ($Limit * 3)

    $entries = foreach ($file in $files) {
        $customTitle = ''; $aiTitle = ''; $prompt = ''; $folder = ''
        foreach ($line in (Read-BridgeFileEnds -Path $file.FullName)) {
            if ($line -notmatch '"type":"(custom-title|ai-title|user)"') { continue }
            try { $record = $line | ConvertFrom-Json } catch { continue }
            switch ([string]$record.type) {
                'custom-title' { if ($record.PSObject.Properties['customTitle']) { $customTitle = [string]$record.customTitle } }
                'ai-title' { if ($record.PSObject.Properties['aiTitle']) { $aiTitle = [string]$record.aiTitle } }
                'user' {
                    if (-not $folder -and $record.PSObject.Properties['cwd']) { $folder = [string]$record.cwd }
                    if (-not $prompt -and $record.PSObject.Properties['message'] -and $null -ne $record.message -and
                        $record.message.PSObject.Properties['content'] -and
                        -not ($record.PSObject.Properties['isMeta'] -and $record.isMeta)) {
                        $prompt = Get-BridgePromptSummary -Content $record.message.content
                    }
                }
            }
        }
        $summary = if ($customTitle) { $customTitle } elseif ($aiTitle) { $aiTitle } else { $prompt }
        if (-not $summary) { continue }

        [pscustomobject]@{
            SessionId = $file.BaseName
            Launcher  = 'claude'
            Summary   = $summary
            Folder    = $folder
            Updated   = [DateTimeOffset]$file.LastWriteTimeUtc
        }
    }
    @($entries)
}

function Get-BridgeCopilotSessionEntries {
    <#
        Recent Copilot CLI sessions: ~/.copilot/session-state/<session id>/, whose
        workspace.yaml records the folder and a summary, and whose events.jsonl
        holds the prompts when there is no summary yet.
    #>
    param([int]$Limit)

    $copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }
    $state = Join-Path $copilotHome 'session-state'
    if (-not [System.IO.Directory]::Exists($state)) { return @() }

    $dirs = @(Get-ChildItem -LiteralPath $state -Directory -Force -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First ($Limit * 3))

    $entries = foreach ($dir in $dirs) {
        $summary = ''; $folder = ''
        $updated = [DateTimeOffset]$dir.LastWriteTimeUtc
        $workspace = Join-Path $dir.FullName 'workspace.yaml'
        if ([System.IO.File]::Exists($workspace)) {
            $fields = Read-BridgeCopilotWorkspace -Path $workspace
            foreach ($key in $fields.Keys) {
                $value = [string]$fields[$key]
                switch ($key) {
                    'cwd' { $folder = $value }
                    'summary' { $summary = $value }
                    'updated_at' { $parsed = [DateTimeOffset]::MinValue; if ([DateTimeOffset]::TryParse($value, [ref]$parsed)) { $updated = $parsed } }
                }
            }
        }
        $events = Join-Path $dir.FullName 'events.jsonl'
        if ([System.IO.File]::Exists($events)) {
            $updated = [DateTimeOffset]([System.IO.File]::GetLastWriteTimeUtc($events))
            if (-not $summary) {
                foreach ($line in (Read-BridgeFileEnds -Path $events)) {
                    if ($line -notmatch '"type":"user\.message"') { continue }
                    try { $record = $line | ConvertFrom-Json } catch { continue }
                    if ($record.PSObject.Properties['data'] -and $null -ne $record.data -and $record.data.PSObject.Properties['content']) {
                        $summary = Get-BridgePromptSummary -Content $record.data.content
                        if ($summary) { break }
                    }
                }
            }
        }
        if (-not $summary) { continue }

        [pscustomobject]@{
            SessionId = $dir.Name
            Launcher  = 'copilot'
            Summary   = $summary
            Folder    = $folder
            Updated   = $updated
        }
    }
    @($entries)
}

function Get-BridgeCodexSessionEntries {
    <#
        Recent Codex sessions: ~/.codex/sessions/<yyyy>/<mm>/<dd>/rollout-*.jsonl,
        whose first line (session_meta) carries the id and folder. The title is the
        thread name from session_index.jsonl when the user gave one, else the first
        prompt.
    #>
    param([int]$Limit)

    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    $sessions = Join-Path $codexHome 'sessions'
    if (-not [System.IO.Directory]::Exists($sessions)) { return @() }

    $names = @{}
    $index = Join-Path $codexHome 'session_index.jsonl'
    if ([System.IO.File]::Exists($index)) {
        foreach ($line in (Read-BridgeFileEnds -Path $index)) {
            try { $record = $line | ConvertFrom-Json } catch { continue }
            if ($record.PSObject.Properties['id'] -and $record.PSObject.Properties['thread_name'] -and $record.thread_name) {
                $names[[string]$record.id] = [string]$record.thread_name
            }
        }
    }

    $files = Get-BridgeSessionFilesByAge -Folder @($sessions) -Filter 'rollout-*.jsonl' -Count ($Limit * 3) -Recurse

    $entries = foreach ($file in $files) {
        $id = ''; $folder = ''; $prompt = ''
        foreach ($line in (Read-BridgeFileEnds -Path $file.FullName)) {
            if ($line -notmatch '"type":"(session_meta|user_message)"') { continue }
            try { $record = $line | ConvertFrom-Json } catch { continue }
            if (-not $record.PSObject.Properties['payload'] -or $null -eq $record.payload) { continue }
            $payload = $record.payload
            if ([string]$record.type -eq 'session_meta') {
                if ($payload.PSObject.Properties['id']) { $id = [string]$payload.id }
                if ($payload.PSObject.Properties['cwd']) { $folder = [string]$payload.cwd }
            }
            elseif (-not $prompt -and $payload.PSObject.Properties['type'] -and [string]$payload.type -eq 'user_message' -and
                $payload.PSObject.Properties['message']) {
                $prompt = Get-BridgePromptSummary -Content $payload.message
            }
        }
        if (-not $id) { continue }
        $summary = if ($names.ContainsKey($id)) { $names[$id] } else { $prompt }
        if (-not $summary) { continue }

        [pscustomobject]@{
            SessionId = $id
            Launcher  = 'codex'
            Summary   = $summary
            Folder    = $folder
            Updated   = [DateTimeOffset]$file.LastWriteTimeUtc
        }
    }
    @($entries)
}

function Get-BridgeResumableSessions {
    <#
        Recent sessions that can be resumed, newest first, from every installed agent:
        each entry names the launcher that reopens it, so a Claude session resumes in
        Claude whichever agent is the default for new ones.

        Agency, when installed, is asked for Copilot sessions - it knows which of its
        sessions can resume - and Copilot's own store fills in when it is not (or
        comes back empty). Claude and Codex are read from their session files. A
        session two sources know is listed once, under its own agent.

        Sessions that are currently live are excluded separately by the caller,
        because attaching a second process to a running session would mean two CLIs
        writing one transcript.
    #>
    param(
        [int]$Limit = 0,

        # Session ids to leave out - the live ones.
        [AllowEmptyCollection()]
        [string[]]$Exclude = @()
    )

    if ($Limit -le 0) { $Limit = [int](Get-BridgeSetting 'newSession.resumeCount' 12) }
    if ($Limit -le 0) { return @() }

    $installed = @(Get-BridgeAvailableLaunchers)
    $candidates = @()
    $found = @{}
    $byOrder = @($script:BridgeLaunchers.Keys) | Sort-Object { (Get-BridgeLauncher -Launcher $_).ResumeOrder }
    foreach ($launcher in $byOrder) {
        if ($installed -notcontains $launcher) { continue }
        $read = (Get-BridgeLauncher -Launcher $launcher).Resumable
        if (-not $read) { continue }
        $found[$launcher] = @(& $read $Limit $found)
        $candidates += $found[$launcher]
    }

    $excluded = @{}
    foreach ($id in @($Exclude)) {
        if (-not [string]::IsNullOrWhiteSpace($id)) { $excluded[[string]$id] = $true }
    }
    $unique = foreach ($entry in @($candidates)) {
        if ($excluded.ContainsKey([string]$entry.SessionId)) { continue }
        $excluded[[string]$entry.SessionId] = $true
        $entry
    }

    $recent = @(@($unique) | Sort-Object Updated -Descending | Select-Object -First $Limit)

    # The agent is named in each label once the list holds more than one kind, so a
    # Claude and a Copilot session on the same task can be told apart.
    $kinds = @($recent | ForEach-Object { (Get-BridgeLauncher -Launcher ([string]$_.Launcher)).Kind } | Select-Object -Unique)
    $prefixed = $kinds.Count -gt 1

    # Build display labels. Home Assistant needs every option in a select to be
    # unique, and a duplicate would make two different sessions indistinguishable, so
    # a repeated label gets its session-id prefix appended.
    $seen = @{}
    $results = foreach ($entry in $recent) {
        $short = $entry.SessionId.Substring(0, [Math]::Min(8, $entry.SessionId.Length))
        $summary = ($entry.Summary -replace '\s+', ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($summary)) { $summary = "Session $short" }
        if ($prefixed) { $summary = "$(Get-BridgeLauncherLabel -Launcher $entry.Launcher): $summary" }

        # Either separator: a folder recorded on Windows is read on a Mac and the
        # other way round, and GetFileName only knows the current system's.
        $folderLeaf = ''
        if (-not [string]::IsNullOrWhiteSpace($entry.Folder)) {
            $folderLeaf = @($entry.Folder.TrimEnd('\', '/') -split '[\\/]')[-1]
        }

        $label = if ($folderLeaf) { "$summary - $folderLeaf" } else { $summary }
        # An option has to match the entity state exactly, and Home Assistant caps a
        # state at 255 characters, so a long summary is trimmed here rather than
        # arriving truncated and never matching.
        if ($label.Length -gt 120) { $label = $label.Substring(0, 117) + '...' }
        if ($seen.ContainsKey($label)) { $label = "$label ($short)" }
        if ($seen.ContainsKey($label)) { continue }
        $seen[$label] = $true

        [pscustomobject]@{
            Label     = $label
            SessionId = $entry.SessionId
            Launcher  = $entry.Launcher
            Folder    = $entry.Folder
            Updated   = $entry.Updated
            # Carried through rather than dropped here. Without it the opt-in detail
            # setting could never share a title: the per-agent readers produce a
            # Summary, this projection discarded it, and everything downstream saw an
            # object that had never had one.
            Summary   = $entry.Summary
        }
    }

    @($results)
}

function Get-BridgeUnlinkedDescendantFile {
    <#
        Every file under a directory, without ever stepping through a link.

        Directory.EnumerateFiles with AllDirectories follows symlinks and Windows
        junctions. A session directory is not a trusted tree - its files\ is where a
        session puts whatever it was working on - so a single junction called `files\x`
        pointing at a repository, or at the user's profile, would have put that
        directory's contents into a bundle and sent them to another machine. A link
        cycle would not have terminated at all.

        So the walk is explicit and refuses reparse points on both files and
        directories, rather than trying to decide whether a particular target is
        acceptable.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $out = [System.Collections.Generic.List[string]]::new()
    if (-not [System.IO.Directory]::Exists($Path)) { return $out.ToArray() }

    $pending = [System.Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($Path)
    while ($pending.Count -gt 0) {
        $current = $pending.Dequeue()
        foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($current)) {
            $info = [System.IO.FileInfo]::new($entry)
            if ($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            if ($info.Attributes -band [System.IO.FileAttributes]::Directory) { $pending.Enqueue($entry) }
            else { $out.Add($entry) }
        }
    }
    # Unwrapped would make an empty result $null under StrictMode rather than nothing.
    $out.ToArray()
}

function Get-BridgeSessionBundleSpec {
    <#
        Where a session's transcript lives and what identifies it, per agent.

        One place, because three things need the same answer and had better agree: what
        to collect when a session is sent somewhere, where to put it when it arrives, and
        what has to be renamed for the copy to be a session in its own right.

        Each agent resolves a session by *name*, which was established by moving real
        sessions and watching them fail: a Claude transcript not called `<id>.jsonl`
        gives "No conversation found", and a Codex rollout whose filename loses its id
        gives "no rollout found for thread id". So the name is the identity, and a copy
        installed under a new name is a new session - which is exactly what makes a
        transfer safe.

        Returns $null for a session that cannot be found, rather than guessing.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Launcher
    )

    # The id reaches here from another machine's MQTT payload and is about to build
    # paths and a -Filter. Unsanitised it is three separate primitives: `..\..\x` walks
    # out of the session-state root, `*` is a glob that -Recurse will happily resolve to
    # somebody else's transcript, and either one reaches the archive name too. Real ids
    # are UUIDs and pass through this untouched.
    $SessionId = Get-CopilotSafeSessionKey -SessionId $SessionId
    if ($SessionId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        return $null
    }

    $kind = (Get-BridgeLauncher -Launcher $Launcher).Kind
    switch ($kind) {
        'copilot' {
            $agentHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }
            $dir = Join-Path (Join-Path $agentHome 'session-state') $SessionId
            if (-not [System.IO.Directory]::Exists($dir)) { return $null }
            # The conversation, its workspace record, and the session's own persistent
            # content. Not the whole directory: rewind-file-snapshots is this machine's
            # undo state for files on this machine's disks, and means nothing once the
            # session is somewhere else.
            #
            # checkpoints and files are included because they are part of the session
            # rather than scratch. A live test transferred a session with 605 artifacts
            # under files\ and 10 checkpoint summaries, and the fork arrived with the
            # conversation referring to both and neither present - the transcript said
            # "saved to files\discovery-proposal" about a directory that was now empty.
            #
            # session.db is deliberately left out. It is binary, so the id rewrite that
            # makes the copy its own session cannot touch it, and a database still
            # naming the original would disagree with the directory it sits in. Nothing
            # establishes it is needed - the sessions proven to resume after a move did
            # not have one - so it stays out until something does.
            $files = [System.Collections.Generic.List[string]]::new()
            foreach ($name in @('events.jsonl', 'workspace.yaml')) {
                $path = Join-Path $dir $name
                if (-not [System.IO.File]::Exists($path)) { continue }
                # A symlinked transcript resolves somewhere this session does not own.
                if ([System.IO.FileInfo]::new($path).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                $files.Add($path)
            }
            foreach ($sub in @('checkpoints', 'files')) {
                $subPath = Join-Path $dir $sub
                if (-not [System.IO.Directory]::Exists($subPath)) { continue }
                if ([System.IO.DirectoryInfo]::new($subPath).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                foreach ($f in (Get-BridgeUnlinkedDescendantFile -Path $subPath)) { $files.Add($f) }
            }
            if ($files.Count -eq 0) { return $null }
            [pscustomobject]@{
                Kind = 'copilot'; Root = $dir; Files = @($files)
                # A directory named for the session; the copy gets a directory of its own.
                Layout = 'directory'
            }
        }
        'claude' {
            $agentHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
            $projects = Join-Path $agentHome 'projects'
            if (-not [System.IO.Directory]::Exists($projects)) { return $null }
            $file = Get-ChildItem -LiteralPath $projects -Filter "$SessionId.jsonl" -File -Recurse -Force -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $file) { return $null }
            [pscustomobject]@{ Kind = 'claude'; Root = $file.Directory.FullName; Files = @($file.FullName); Layout = 'file' }
        }
        'codex' {
            $agentHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
            $sessions = Join-Path $agentHome 'sessions'
            if (-not [System.IO.Directory]::Exists($sessions)) { return $null }
            $file = Get-ChildItem -LiteralPath $sessions -Filter "rollout-*$SessionId.jsonl" -File -Recurse -Force -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $file) { return $null }
            [pscustomobject]@{ Kind = 'codex'; Root = $file.Directory.FullName; Files = @($file.FullName); Layout = 'file' }
        }
        default { $null }
    }
}

function New-BridgeSessionBundle {
    <#
        Packs a session's transcript into a zip beside a manifest describing it.

        Read-only with respect to the session: nothing is renamed, moved, locked or
        marked. The copy that stays behind remains a perfectly good session, which is the
        whole reason this is safe to do while the fleet is in any state at all.

        The manifest carries a SHA256 of the archive because the receiving side must be
        able to refuse a damaged one *before* it writes anything into an agent's home.
        That matters most for Copilot: handed `--session-id` for a session whose files are
        absent or unreadable, it does not fail - it silently starts a new, empty session
        under that id and exits 0.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Launcher,
        [Parameter(Mandatory)][string]$Destination,
        # A bound on what is read, checked before a byte is copied. Distinct from the
        # cap on what goes on the wire, which is measured on the zip afterwards: a
        # session observed in testing was 62.6 MB on disk and well under a 25 MB wire
        # cap once compressed, so refusing on raw size against the wire cap would have
        # turned away a transfer that works. This exists only to stop the work itself
        # being unbounded. 0 disables it.
        [long]$MaxSourceBytes = 0
    )

    $spec = Get-BridgeSessionBundleSpec -SessionId $SessionId -Launcher $Launcher
    if ($null -eq $spec) { throw "no $Launcher session files found for $SessionId" }
    # Sanitised above; used again here because it names the archive.
    $safeId = Get-CopilotSafeSessionKey -SessionId $SessionId

    # Before the staging directory exists, let alone a copy. The file list is fully
    # known from the spec, and `files\` is a session's own artifact store with nothing
    # upstream bounding it - so without this one request could have the owning machine
    # copy and compress an arbitrarily large tree into temp, inside the single-threaded
    # reconcile, answering nothing else while it did.
    if ($MaxSourceBytes -gt 0) {
        $total = 0L
        foreach ($f in @($spec.Files)) { $total += [System.IO.FileInfo]::new($f).Length }
        if ($total -gt $MaxSourceBytes) {
            throw "that session is $([int]($total / 1MB)) MB on disk, over the $([int]($MaxSourceBytes / 1MB)) MB a transfer will read"
        }
    }

    $stage = Join-Path $Destination "stage-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        # What the files looked like before the copy started. A session is only checked
        # for being live once, in the snapshot the caller took at the start of its
        # reconcile, and sending can take tens of seconds - so someone resuming the
        # source in between would have the agent appending while this reads, producing a
        # fork that is digest-valid and truncated. That cannot be prevented from here:
        # there is no lock an agent CLI would honour. It can be *detected*, and a refusal
        # is the right answer, because a silently half-copied conversation is worse than
        # no transfer at all.
        $witness = @{}
        foreach ($f in @($spec.Files)) {
            $info = [System.IO.FileInfo]::new($f)
            $witness[$f] = "$($info.Length):$($info.LastWriteTimeUtc.Ticks)"
        }

        $entries = foreach ($f in @($spec.Files)) {
            # Relative to the session root, not the leaf: a Copilot session keeps content
            # in checkpoints\ and files\, and flattening those collides the moment two
            # subdirectories hold the same name.
            $relative = [System.IO.Path]::GetRelativePath($spec.Root, $f)
            $target = Join-Path $stage $relative
            $parent = [System.IO.Path]::GetDirectoryName($target)
            if ($parent -and -not [System.IO.Directory]::Exists($parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Copy-Item -LiteralPath $f -Destination $target -Force
            $relative
        }

        $zip = Join-Path $Destination "$safeId.zip"
        if ([System.IO.File]::Exists($zip)) { Remove-Item -LiteralPath $zip -Force }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip,
            [System.IO.Compression.CompressionLevel]::Optimal, $false)

        # Re-read after the copy, not before: a file that grew or was rewritten while it
        # was being read makes the archive a snapshot of no single moment.
        foreach ($f in @($spec.Files)) {
            $info = [System.IO.FileInfo]::new($f)
            if (-not $info.Exists -or $witness[$f] -ne "$($info.Length):$($info.LastWriteTimeUtc.Ticks)") {
                throw "that session changed while it was being packed - it is probably open somewhere"
            }
        }

        [pscustomobject]@{
            SessionId = $SessionId
            Launcher  = $Launcher
            Kind      = $spec.Kind
            Layout    = $spec.Layout
            Files     = @($entries)
            Path      = $zip
            Bytes     = (Get-Item -LiteralPath $zip).Length
            Sha256    = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
            # The agent that wrote it. Codex changed its on-disk history between builds,
            # so a receiver on a different version is worth warning about.
            Version   = Get-BridgeLauncherVersion -Launcher $Launcher
        }
    }
    finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-BridgeLauncherVersion {
    <#
        The agent's version string, or '' when it cannot be asked. Never throws, and
        never waits.

        The timeout is the point. This runs inside the daemon's reconcile, on a path a
        *peer machine* can trigger by asking for a session, so a CLI that sits there
        instead of answering would stop this machine reconciling at all - no activity,
        no decisions, no replies - until it gave up. An agent not answering `--version`
        is a case this codebase has already hit: "it may be waiting to be signed in".
        The field is only a cosmetic warning about version skew, so it is never worth a
        stalled daemon.
    #>
    param([Parameter(Mandatory)][string]$Launcher)
    try {
        $path = Get-BridgeLauncherPath -Launcher $Launcher
        if (-not $path) { return '' }
        $probe = Invoke-BridgeCommandProbe -Executable $path -Arguments @('--version') -TimeoutMs 5000
        if (-not $probe.Ran -or $probe.TimedOut) { return '' }
        $out = [string]$probe.StandardOutput
        if ([string]::IsNullOrWhiteSpace($out)) { $out = [string]$probe.Output }
        (@($out -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1).Trim()
    }
    catch { '' }
}

function Install-BridgeSessionBundle {
    <#
        Unpacks a bundle into this machine's agent home as a session of its own, and
        returns the new session id.

        The copy is deliberately given a NEW id rather than the one it had. That single
        choice removes the hardest problem in moving a session between machines: if two
        machines could hold the same id, something would have to arbitrate which of them
        may write - across machines that cannot reach each other, with no arbiter, and
        with no way at all to stop someone typing `claude --resume <id>` at a keyboard.
        Renaming the original was tried on paper and does not work: a rename revokes
        neither an open handle nor another hard link, so both copies stay writable.

        With a new id there is nothing to arbitrate. Each machine holds one session that
        only it has, the original stays usable where it always was, and continuing both
        is divergence between two clearly different sessions rather than two writers
        corrupting one transcript.

        The digest is checked before anything is written. See New-BridgeSessionBundle for
        why that is not optional.
    #>
    param(
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][object]$Manifest,
        [string]$NewSessionId,
        # Where the forked session should think it is working. Only recorded; nothing is
        # created, and the caller has already checked it is an approved workspace.
        [string]$WorkingDirectory
    )

    if (-not [System.IO.File]::Exists($BundlePath)) { throw "bundle not found: $BundlePath" }
    $actual = (Get-FileHash -LiteralPath $BundlePath -Algorithm SHA256).Hash
    if ($actual -ne [string]$Manifest.Sha256) {
        throw "bundle digest mismatch: expected $($Manifest.Sha256), got $actual"
    }
    if (-not $NewSessionId) { $NewSessionId = [guid]::NewGuid().ToString() }

    $unpack = Join-Path ([System.IO.Path]::GetTempPath()) "bridge-unpack-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory -Path $unpack -Force | Out-Null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($BundlePath, $unpack)

        $old = [string]$Manifest.SessionId
        foreach ($f in Get-ChildItem -LiteralPath $unpack -File -Recurse) {
            # Text transcripts name the session inside as well as outside. Rewritten so
            # the copy is consistently its own session; a binary sits untouched, since
            # the filename is what the agent resolves on.
            if ($f.Extension -in @('.jsonl', '.yaml', '.json', '.md')) {
                $text = [System.IO.File]::ReadAllText($f.FullName)
                if ($text.Contains($old)) {
                    [System.IO.File]::WriteAllText($f.FullName, $text.Replace($old, $NewSessionId))
                }
            }
        }

        switch ([string]$Manifest.Kind) {
            'copilot' {
                $agentHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }
                $dest = Join-Path (Join-Path $agentHome 'session-state') $NewSessionId
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                # Recursive: checkpoints\ and files\ are part of the session, and a
                # top-level-only copy silently left both behind.
                Get-ChildItem -LiteralPath $unpack -File -Recurse | ForEach-Object {
                    $relative = [System.IO.Path]::GetRelativePath($unpack, $_.FullName)
                    $target = Join-Path $dest $relative
                    $parent = [System.IO.Path]::GetDirectoryName($target)
                    if ($parent -and -not [System.IO.Directory]::Exists($parent)) {
                        New-Item -ItemType Directory -Path $parent -Force | Out-Null
                    }
                    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
                }
                if ($WorkingDirectory) { Set-BridgeCopilotWorkspaceCwd -Path (Join-Path $dest 'workspace.yaml') -Cwd $WorkingDirectory }
            }
            'claude' {
                $agentHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
                # The folder encodes a working directory, and any name resolves - proven
                # by resuming from one called zzz-totally-unrelated-name. It is named for
                # the target's own directory so a human reading the folder list is not
                # misled about where the session now runs.
                $slug = if ($WorkingDirectory) { ($WorkingDirectory -replace '[:\\/]', '-').TrimStart('-') } else { 'bridge-transferred' }
                $dest = Join-Path (Join-Path $agentHome 'projects') $slug
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                $src = Get-ChildItem -LiteralPath $unpack -File | Select-Object -First 1
                Copy-Item -LiteralPath $src.FullName -Destination (Join-Path $dest "$NewSessionId.jsonl") -Force
            }
            'codex' {
                $agentHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
                $now = [DateTimeOffset]::Now
                $dest = Join-Path (Join-Path $agentHome 'sessions') (Join-Path $now.ToString('yyyy') (Join-Path $now.ToString('MM') $now.ToString('dd')))
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                $src = Get-ChildItem -LiteralPath $unpack -File | Select-Object -First 1
                # The id must stay in the filename; the timestamp part is free.
                $stamp = $now.ToString('yyyy-MM-ddTHH-mm-ss')
                Copy-Item -LiteralPath $src.FullName -Destination (Join-Path $dest "rollout-$stamp-$NewSessionId.jsonl") -Force
            }
            default { throw "unknown session kind '$($Manifest.Kind)'" }
        }

        # A digest proves the archive arrived intact. It does not prove there was a
        # session in it: an empty-but-valid archive would create the directory, write
        # nothing, and hand back an id. For Copilot that is the exact fail-open this
        # whole design exists to avoid, because `--session-id` against an empty
        # directory starts a new empty session and exits 0. So the result is checked for
        # what it is supposed to be, and withdrawn if it is not.
        # Kind doubles as a launcher name here ('copilot', 'claude', 'codex' are both),
        # so this works whether or not the manifest carried a Launcher.
        $installed = Get-BridgeSessionBundleSpec -SessionId $NewSessionId -Launcher ([string]$Manifest.Kind)
        if ($null -eq $installed) {
            Remove-BridgeInstalledSession -SessionId $NewSessionId -Kind ([string]$Manifest.Kind)
            throw 'bundle contained no usable session files'
        }
        $NewSessionId
    }
    finally {
        Remove-Item -LiteralPath $unpack -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Remove-BridgeInstalledSession {
    <#
        Withdraws a session this machine just installed, when it turned out not to be
        one. Only ever called on a freshly created id, so there is nothing of anyone
        else's to delete.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Kind
    )

    $safe = Get-CopilotSafeSessionKey -SessionId $SessionId
    switch ($Kind) {
        'copilot' {
            $agentHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }
            Remove-Item -LiteralPath (Join-Path (Join-Path $agentHome 'session-state') $safe) -Recurse -Force -ErrorAction SilentlyContinue
        }
        'claude' {
            $agentHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
            Get-ChildItem -LiteralPath (Join-Path $agentHome 'projects') -Filter "$safe.jsonl" -File -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        }
        'codex' {
            $agentHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
            Get-ChildItem -LiteralPath (Join-Path $agentHome 'sessions') -Filter "rollout-*$safe.jsonl" -File -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Set-BridgeCopilotWorkspaceCwd {
    <#
        Points a forked Copilot session's workspace record at the directory it will
        actually run in.

        The original path came from another machine and will usually not exist here -
        this fleet has sessions under 'rezna', 'danswett' and 'dswett' - so leaving it
        would describe a tree that is not there.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Cwd
    )
    if (-not [System.IO.File]::Exists($Path)) { return }
    $lines = foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match '^cwd:\s') { "cwd: $Cwd" } else { $line }
    }
    [System.IO.File]::WriteAllLines($Path, @($lines))
}

function Test-BridgeTransferComplete {
    <#
        Whether every chunk of a bundle has arrived.

        Counts distinct sequence numbers rather than messages. Chunks are published at
        QoS 1, which permits redelivery, so a raw message count let one chunk arriving
        twice stand in for one that had not arrived at all: the subscription closed
        early and reassembly failed as incomplete while the sender was still publishing
        perfectly good chunks.
    #>
    param([AllowEmptyCollection()][AllowNull()][object[]]$Messages)

    $manifest = @($Messages) | Where-Object { $null -ne $_ -and $_.PSObject.Properties['sha256'] } | Select-Object -First 1
    if ($null -eq $manifest) { return $false }
    $seen = @(@($Messages) |
        Where-Object { $null -ne $_ -and $_.PSObject.Properties['d'] -and $_.PSObject.Properties['s'] } |
        ForEach-Object { [int]$_.s } | Sort-Object -Unique)
    @($seen).Count -ge [int]$manifest.chunks
}

function Get-BridgeBundleChunk {
    <#
        Splits bundle bytes into pieces small enough to publish, measuring what actually
        goes on the wire rather than the slice.

        A raw slice is not the packet. Base64 inflates it by a third, the envelope adds
        its sequence and offset fields, and the topic string rides along too. A "2 MB"
        test published a ~2.8 MB packet, which is how this limit was learned: mosquitto
        2.1 lowered the default max_packet_size to 2,000,000 bytes, and exceeding it
        disconnects Home Assistant from the broker - not just this publish, but every
        MQTT entity on the instance, repeatedly, until the oversize message is gone.

        So each piece is measured encoded and shrunk until it fits. The default budget is
        a quarter of a megabyte: an order of magnitude under that ceiling, so a fleet
        whose broker has never been reconfigured is still safe, and large enough that a
        typical session is one or two pieces.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$Topic,
        [int]$Budget = 262144
    )

    if ($Bytes.Length -eq 0) { return @() }
    # Base64 is 4 bytes per 3, and the envelope and topic are along for the ride.
    # Floor, not [int]: PowerShell's cast rounds, so [int]0.9 is 1 - which in the shrink
    # loop below gave a size that could never get smaller and a loop that never ended.
    $overhead = $Topic.Length + 96
    $slice = [Math]::Max(1, [int][Math]::Floor(($Budget - $overhead) * 3 / 4))

    $chunks = [System.Collections.Generic.List[object]]::new()
    $offset = 0
    while ($offset -lt $Bytes.Length) {
        # Each piece is sized by measurement, not arithmetic: the arithmetic above is an
        # estimate, and being wrong by a few bytes at the ceiling is what breaks a broker.
        $take = [Math]::Min($slice, $Bytes.Length - $offset)
        $fitted = $false
        while ($take -gt 0) {
            $buf = [byte[]]::new($take)
            [Array]::Copy($Bytes, $offset, $buf, 0, $take)
            $payload = @{ s = $chunks.Count; o = $offset; d = [Convert]::ToBase64String($buf) } |
                ConvertTo-Json -Compress
            $encoded = [Text.Encoding]::UTF8.GetByteCount($payload) + $Topic.Length
            if ($encoded -le $Budget) {
                $chunks.Add([pscustomobject]@{
                    Seq = $chunks.Count; Offset = $offset; Length = $take
                    Payload = $payload; Encoded = $encoded
                })
                $fitted = $true
                break
            }
            # Always strictly smaller, so this terminates even when 90% rounds back up.
            $take = [Math]::Min($take - 1, [int][Math]::Floor($take * 0.9))
        }
        if (-not $fitted) { throw "cannot fit a chunk within $Budget bytes for topic '$Topic'" }
        $offset += $take
    }
    @($chunks)
}

function Join-BridgeBundleChunk {
    <#
        Rebuilds bundle bytes from received pieces, or throws saying what is wrong.

        Refuses a gap rather than writing a shorter file: an archive missing a slice from
        its middle can still extract, and the result would be a transcript that looks
        plausible and is not.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Chunks,
        [Parameter(Mandatory)][int]$TotalBytes,
        [AllowEmptyString()][string]$Sha256 = ''
    )

    $bytes = [byte[]]::new($TotalBytes)
    $ordered = @(@($Chunks) | Where-Object { $null -ne $_ } | Sort-Object { [int]$_.o })
    foreach ($chunk in $ordered) {
        $data = [Convert]::FromBase64String([string]$chunk.d)
        $offset = [int]$chunk.o
        if ($offset -lt 0 -or ($offset + $data.Length) -gt $TotalBytes) {
            throw "chunk $($chunk.s) lies outside the bundle"
        }
        [Array]::Copy($data, 0, $bytes, $offset, $data.Length)
    }

    # Coverage is checked by walking the pieces, not by marking every byte: a bundle is
    # megabytes and a per-byte loop made this take seconds for no extra certainty.
    $reached = 0
    foreach ($chunk in $ordered) {
        $offset = [int]$chunk.o
        if ($offset -gt $reached) {
            throw "bundle incomplete: nothing covers bytes $reached..$($offset - 1) of $TotalBytes"
        }
        $end = $offset + [Convert]::FromBase64String([string]$chunk.d).Length
        if ($end -gt $reached) { $reached = $end }
    }
    if ($reached -lt $TotalBytes) {
        throw "bundle incomplete: $($TotalBytes - $reached) of $TotalBytes bytes never arrived"
    }

    if ($Sha256) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $actual = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') }
        finally { $sha.Dispose() }
        if ($actual -ne $Sha256.ToUpperInvariant()) {
            throw "bundle digest mismatch: expected $Sha256, got $actual"
        }
    }
    $bytes
}

function Get-BridgeTransferSecret {
    <#
        The shared secret every machine in a fleet must hold for transfers to work, or
        an empty string when none is configured.

        A transfer rides ordinary MQTT topics. Anything holding broker credentials can
        publish to them, and on a normal home instance that is a much lower bar than
        Home Assistant admin - Frigate, Zigbee2MQTT, ESPHome and the rest all clear it.
        Without a secret, "can publish MQTT" is also "can ask any machine for any
        session it offers, and have it delivered to a topic of my choosing".

        A broker ACL was considered first and rejected: mosquitto's ACL file is
        allow-only with no deny rule, so restricting one prefix means enumerating every
        topic every other client legitimately uses, on an instance where an MQTT mistake
        has already taken the whole fleet offline once. Signing makes the protocol not
        care who else can reach the transport, which is the right shape for a transport
        that was never trusted.
    #>
    $secret = [string](Get-BridgeSetting 'newSession.transferSecret' '')
    $secret.Trim()
}

function Get-BridgeTransferSignature {
    <#
        An HMAC-SHA256 over the fields that decide what a transfer does, hex encoded.

        Canonicalised by joining the named values with a separator that cannot appear in
        any of them, rather than by hashing serialised JSON: property order is not
        guaranteed across PowerShell versions, and a signature that depends on it would
        start failing on an upgrade with no visible cause.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Fields,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Secret
    )

    if ([string]::IsNullOrEmpty($Secret)) { return '' }
    $payload = (@($Fields) -join "`u{001f}")
    $mac = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($Secret))
    try {
        [BitConverter]::ToString($mac.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload))).Replace('-', '').ToLowerInvariant()
    }
    finally { $mac.Dispose() }
}

function Test-BridgeTransferSignature {
    <#
        Whether a presented signature matches, in constant time.

        Ordinary -eq on strings returns as soon as it finds a difference, which leaks
        how much of a guess was right. The amount leaked over MQTT is small, but a
        fixed-time comparison costs nothing and removes the question.
    #>
    param(
        [AllowEmptyString()][AllowNull()][string]$Presented,
        [AllowEmptyString()][AllowNull()][string]$Expected
    )

    if ([string]::IsNullOrEmpty($Expected) -or [string]::IsNullOrEmpty($Presented)) { return $false }
    $a = [Text.Encoding]::UTF8.GetBytes($Presented)
    $b = [Text.Encoding]::UTF8.GetBytes($Expected)
    if ($a.Length -ne $b.Length) { return $false }
    $difference = 0
    for ($i = 0; $i -lt $a.Length; $i++) { $difference = $difference -bor ($a[$i] -bxor $b[$i]) }
    $difference -eq 0
}

function Get-BridgeTransferRequestFields {
    <# Exactly what a request signature covers, in one place so both sides agree. #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Launcher,
        [Parameter(Mandatory)][string]$Requester,
        [Parameter(Mandatory)][string]$Correlation,
        [Parameter(Mandatory)][string]$At
    )
    # The requester and the correlation are in here deliberately: they name the topic the
    # transcript is published to, so an unsigned one would let a valid request be
    # replayed with the destination changed.
    @('transfer-request-v1', $SessionId, $Launcher, $Requester, $Correlation, $At)
}

function Get-BridgeTransferManifestFields {
    <# Exactly what a manifest signature covers, in one place so both sides agree. #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][int]$Bytes,
        [Parameter(Mandatory)][int]$Chunks,
        [Parameter(Mandatory)][string]$Correlation
    )
    # The digest is in here, which is what carries the signature down to the bytes: the
    # chunks themselves are not signed individually, but a chunk set that does not hash
    # to this digest is already refused by Join-BridgeBundleChunk.
    @('transfer-manifest-v1', $SessionId, $Kind, $Sha256, [string]$Bytes, [string]$Chunks, $Correlation)
}

function Get-BridgeTransferTopic {
    <#
        Where one transfer's messages live: a topic per transfer, under the owning
        machine.

        Deliberately not under `homeassistant/`, and never named by a discovery config,
        so Home Assistant creates no entity for it. That is what keeps chunk payloads out
        of the state machine and therefore out of the recorder and backups - clearing a
        retained topic afterwards would not remove rows already written.
    #>
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$Correlation
    )
    "$($script:CopilotMqttConfig.TopicRoot)/transfer/$Slug/$Correlation"
}

function Send-BridgeSessionBundle {
    <#
        Publishes a bundle as a manifest followed by its chunks.

        Not retained, any of it. A retained chunk would sit on the broker after the
        transfer, be redelivered to every reconnecting subscriber, and - at these sizes -
        is exactly the shape of message that took this fleet's MQTT down for twenty-five
        minutes. The receiver is listening before this is called; a transfer nobody is
        listening for is simply lost, which is the right outcome.
    #>
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$Correlation,
        [Parameter(Mandatory)][hashtable]$Headers,
        [int]$Budget = 262144,
        [scriptblock]$OnProgress
    )

    $root = Get-BridgeTransferTopic -Slug $Slug -Correlation $Correlation
    $bytes = [IO.File]::ReadAllBytes([string]$Manifest.Path)
    $chunks = @(Get-BridgeBundleChunk -Bytes $bytes -Topic "$root/c" -Budget $Budget)

    $signature = Get-BridgeTransferSignature -Secret (Get-BridgeTransferSecret) -Fields (
        Get-BridgeTransferManifestFields -SessionId ([string]$Manifest.SessionId) -Kind ([string]$Manifest.Kind) `
            -Sha256 ([string]$Manifest.Sha256) -Bytes ([int]$Manifest.Bytes) -Chunks $chunks.Count -Correlation $Correlation)

    Publish-CopilotMqttMessage -Topic "$root/manifest" -Headers $Headers -Payload (@{
        session  = [string]$Manifest.SessionId
        launcher = [string]$Manifest.Launcher
        kind     = [string]$Manifest.Kind
        bytes    = [int]$Manifest.Bytes
        sha256   = [string]$Manifest.Sha256
        chunks   = $chunks.Count
        version  = [string]$Manifest.Version
        sig      = $signature
    } | ConvertTo-Json -Compress)

    foreach ($chunk in $chunks) {
        Publish-CopilotMqttMessage -Topic "$root/c" -Headers $Headers -Payload $chunk.Payload
        if ($OnProgress) { & $OnProgress $chunk.Seq $chunks.Count }
    }
    $chunks.Count
}

function Read-BridgeHaMqttSubscription {
    <#
        Collects messages published to a topic, over Home Assistant's WebSocket API.

        The receiving half of the data path, and the reason chunks need no entity: this
        subscribes to the topic directly, so nothing is ever written to a state and the
        recorder has nothing to keep.

        Returns once -Until says so or the timeout passes, whichever comes first.
    #>
    param(
        [Parameter(Mandatory)][string]$Topic,
        [Parameter(Mandatory)][scriptblock]$Until,
        [int]$TimeoutSeconds = 300,
        # Called once the subscription is live. Nothing published here is retained, so a
        # sender that starts before this has fired is talking to no one.
        [scriptblock]$OnReady
    )

    $token = (Get-HomeAssistantHeaders).Authorization -replace '^Bearer ', ''
    $wsUri = [Uri](($script:DecisionBridgeConfig.HomeAssistantBaseUrl -replace '^http', 'ws').TrimEnd('/') + '/api/websocket')
    Assert-BridgeHttpAllowed -Uri $wsUri -Transport WebSocket
    Assert-BridgeAuthAllowed

    $socket = [Net.WebSockets.ClientWebSocket]::new()
    $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    $received = [System.Collections.Generic.List[object]]::new()
    try {
        [void]$socket.ConnectAsync($wsUri, $cancel.Token).GetAwaiter().GetResult()
        $buffer = [ArraySegment[byte]]::new([byte[]]::new(1048576))
        $recv = {
            $text = [Text.StringBuilder]::new()
            do {
                $r = $socket.ReceiveAsync($buffer, $cancel.Token).GetAwaiter().GetResult()
                [void]$text.Append([Text.Encoding]::UTF8.GetString($buffer.Array, 0, $r.Count))
            } while (-not $r.EndOfMessage)
            $text.ToString() | ConvertFrom-Json
        }
        $send = {
            param($o)
            $b = [Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Depth 10 -Compress))
            [void]$socket.SendAsync([ArraySegment[byte]]::new($b), [Net.WebSockets.WebSocketMessageType]::Text, $true, $cancel.Token).GetAwaiter().GetResult()
        }

        [void](& $recv)                                   # auth_required
        & $send @{ type = 'auth'; access_token = $token }
        $auth = & $recv
        if ([string]$auth.type -ne 'auth_ok') { throw "websocket auth failed: $($auth.type)" }

        & $send @{ id = 1; type = 'mqtt/subscribe'; topic = $Topic }
        [void](& $recv)                                   # subscription result
        if ($OnReady) { & $OnReady }

        while (-not $cancel.IsCancellationRequested) {
            # A cancelled receive throws rather than returning, so without this the
            # timeout escapes as "A task was canceled" and the caller's own "that
            # machine did not send it" message is unreachable.
            try { $msg = & $recv } catch { break }
            if ([string]$msg.type -ne 'event') { continue }
            $payload = $msg.event.payload
            if ($null -eq $payload) { continue }
            try { $received.Add(($payload | ConvertFrom-Json)) } catch { continue }
            if (& $Until @($received)) { break }
        }
        @($received)
    }
    finally {
        try { [void]$socket.CloseAsync([Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', [Threading.CancellationToken]::None).GetAwaiter().GetResult() } catch { }
        $socket.Dispose(); $cancel.Dispose()
    }
}

function Read-BridgeConsoleScreen {
    <#
        The visible text of a session's terminal, or '' when it cannot be read: its
        console on Windows, its tmux pane on macOS.
    #>
    param([Parameter(Mandatory)][int]$ProcessId)
    if (-not $script:BridgeIsWindows) {
        $pane = Find-BridgeTmuxPane -ProcessId $ProcessId
        if (-not $pane) { return '' }
        return Read-BridgeTmuxPane -Pane $pane
    }
    Initialize-BridgeConsoleReader
    [string][CopilotCli.ConsoleReader]::ReadScreen([uint32]$ProcessId)
}

function Initialize-BridgeConsoleReader {
    <#
        Compiles a small reader for another process's console screen: attach, read the
        visible rows, detach. Kept apart from the injector so that proven type is
        untouched.
    #>
    if (([Management.Automation.PSTypeName]'CopilotCli.ConsoleReader').Type) { return }
    # Compiled once into a cached DLL rather than in this process (Add-BridgeCompiledType).
    Add-BridgeCompiledType -TypeName 'CopilotCli.ConsoleReader' -Source @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace CopilotCli {
    public static class ConsoleReader {
        [StructLayout(LayoutKind.Sequential)] private struct COORD { public short X; public short Y; }
        [StructLayout(LayoutKind.Sequential)] private struct SMALL_RECT { public short Left; public short Top; public short Right; public short Bottom; }
        [StructLayout(LayoutKind.Sequential)] private struct CONSOLE_SCREEN_BUFFER_INFO {
            public COORD dwSize; public COORD dwCursorPosition; public ushort wAttributes;
            public SMALL_RECT srWindow; public COORD dwMaximumWindowSize;
        }

        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AttachConsole(uint dwProcessId);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool FreeConsole();
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CONSOLE_SCREEN_BUFFER_INFO info);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool ReadConsoleOutputCharacterW(IntPtr h, [Out] char[] buffer, uint length, COORD at, out uint read);

        // The visible rows of the process's console, one line each, or null when it
        // cannot be read.
        public static string ReadScreen(uint processId) {
            FreeConsole();
            if (!AttachConsole(processId)) { return null; }
            IntPtr h = IntPtr.Zero;
            try {
                h = CreateFileW("CONOUT$", 0x80000000 | 0x40000000, 1 | 2, IntPtr.Zero, 3, 0, IntPtr.Zero);
                if (h == new IntPtr(-1)) { return null; }
                CONSOLE_SCREEN_BUFFER_INFO info;
                if (!GetConsoleScreenBufferInfo(h, out info)) { return null; }
                int width = info.dwSize.X;
                char[] row = new char[width];
                StringBuilder text = new StringBuilder();
                for (short y = info.srWindow.Top; y <= info.srWindow.Bottom; y++) {
                    uint read;
                    COORD at = new COORD { X = 0, Y = y };
                    if (ReadConsoleOutputCharacterW(h, row, (uint)width, at, out read)) {
                        text.Append(new string(row, 0, (int)read).TrimEnd()).Append('\n');
                    }
                }
                return text.ToString();
            }
            finally {
                if (h != IntPtr.Zero && h != new IntPtr(-1)) { CloseHandle(h); }
                FreeConsole();
            }
        }
    }
}
'@
}

function Get-BridgeTrustPromptSelection {
    <#
        Reads Claude's "Do you trust this folder?" question off a console screen.
        Returns 'yes' or 'no' for the highlighted option, or '' when the question is not
        on screen. Pure, so it can be tested against captured screens.
    #>
    param([AllowEmptyString()][AllowNull()][string]$Screen)

    if ([string]::IsNullOrWhiteSpace($Screen) -or $Screen -notmatch 'Yes, I trust this folder') { return '' }
    foreach ($line in ($Screen -split "`n")) {
        if ($line -match '^\s*[>❯›]\s*Yes, I trust this folder') { return 'yes' }
        if ($line -match '^\s*[>❯›]\s*No, exit') { return 'no' }
    }
    ''
}

function Read-BridgeTrustPrompt {
    <#
        Looks at a Claude session's screen for its "Do you trust this folder?" question.
        Returns 'yes' or 'no' for the highlighted option, or '' when the question is not
        showing. Whether Claude will ask cannot be predicted reliably from its config -
        it has honoured entries its own code path would not suggest - so the bridge
        reads what is actually on screen.
    #>
    param([Parameter(Mandatory)][int]$ProcessId)

    try {
        Get-BridgeTrustPromptSelection -Screen (Read-BridgeConsoleScreen -ProcessId $ProcessId)
    }
    catch { '' }
}

function Send-BridgeTrustAnswer {
    <#
        Answers Claude's trust question with "Yes, I trust this folder", given which
        option is highlighted now. Only called after the user explicitly confirmed.

        Never blind: the option list wraps, so one Down too many lands back on
        "No, exit" and closes the session (verified). From "No" it is Down then Enter;
        from "Yes" it is Enter alone.
    #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$Selection
    )

    $keys = if ($Selection -eq 'yes') { '' } else { "$([char]27)[B" }
    Invoke-BridgeConsoleSend -ProcessId $ProcessId -Text $keys -Submit $true -DelayMs 200
}

function Start-BridgeCopilotSession {
    <#
        Starts a new agent session in its own visible console window, with the chosen
        launcher, or the default one (Get-BridgeLauncherKind) when none is given.

        Returns a result object instead of throwing: a failed launch has to surface
        on the dashboard and leave the daemon running, exactly like a failed reply.

        The window is deliberately visible. A session opened from the sofa should
        still be something you can walk over to, read and take over at the keyboard,
        and an invisible one could only ever be driven through Home Assistant.
    #>
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string]$Prompt = '',
        [string]$SessionId = '',
        [string]$AgencyProfile = '',

        # 'agency', 'copilot', 'claude' or 'codex'; empty means the default.
        [string]$Launcher = '',

        # The three tuning axes, as chosen on the launch card. Each is a label from
        # that agent's own option list; anything else - including the 'Agent default'
        # sentinel - means "pass nothing and let the agent decide". Empty falls back
        # to what the config asks for, which is how a launch from the command line or
        # from an older daemon still honours `newSession.model`.
        [AllowEmptyString()][string]$Model = '',
        [AllowEmptyString()][string]$Effort = '',
        [AllowEmptyString()][string]$Context = '',

        # Launch without permission prompts. Chosen per launch on the card, because
        # the machine that runs the session is not always the one choosing: a session
        # started on a Mac from a Windows dashboard used to take the Mac's
        # newSession.allowAllTools, unseen and unchangeable from where Launch was
        # pressed. Not passed at all - from the command line, or from a daemon too old
        # to send it - still means that config setting.
        [bool]$AllowAllTools = [bool](Get-BridgeSetting 'newSession.allowAllTools' $false),

        # Resuming an existing session rather than creating one. Copilot and Agency
        # resume whenever --session-id names a session that exists; Claude and Codex
        # need their own resume syntax (Get-BridgeNewSessionArguments).
        [switch]$Resume
    )

    $result = [pscustomobject]@{
        Launched  = $false
        SessionId = $SessionId
        ProcessId = 0
        Launcher  = ''
        Detail    = ''
        Model     = ''
        Effort    = ''
        Context   = ''
    }

    if (-not [System.IO.Directory]::Exists($WorkingDirectory)) {
        $result.Detail = "working directory does not exist: $WorkingDirectory"
        return $result
    }

    $launcher = if ([string]::IsNullOrWhiteSpace($Launcher)) { Get-BridgeLauncherKind } else { $Launcher.ToLowerInvariant() }
    if (-not $script:BridgeLaunchers.Contains($launcher)) {
        $result.Detail = "unknown launcher '$launcher'"
        return $result
    }
    $result.Launcher = $launcher

    $executable = Get-BridgeLauncherPath -Launcher $launcher
    if ([string]::IsNullOrWhiteSpace($executable)) {
        $result.Detail = "$launcher not found; install it or set newSession.${launcher}Path in the bridge config"
        return $result
    }

    # Codex picks its own session id and reports it through its hook, so none is
    # invented for it here.
    if ([string]::IsNullOrWhiteSpace($result.SessionId) -and -not (Get-BridgeLauncher -Launcher $launcher).ChoosesOwnSessionId) {
        $result.SessionId = [guid]::NewGuid().ToString()
    }

    # Each axis: what the card chose, or - when it chose nothing - what the config
    # asks for. Resolved here rather than in the argument builder so the result can
    # report what the session was actually started with, which is what the session
    # card then shows.
    $chosen = @{}
    foreach ($axis in @(Get-BridgeTuningAxes)) {
        $asked = switch ($axis) { 'model' { $Model } 'effort' { $Effort } 'context' { $Context } }
        $value = Resolve-BridgeTuningValue -Launcher $launcher -Axis $axis -Value $asked
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = Resolve-BridgeTuningValue -Launcher $launcher -Axis $axis `
                -Value (Get-BridgeDefaultTuning -Launcher $launcher -Axis $axis)
        }
        $chosen[$axis] = $value
    }
    $result.Model = $chosen['model']
    $result.Effort = $chosen['effort']
    $result.Context = $chosen['context']

    # Wrapped: an empty list (Codex with no prompt and no options) came back as $null
    # and failed the launch before anything started.
    $arguments = @(Get-BridgeNewSessionArguments `
        -SessionId $result.SessionId `
        -Prompt $Prompt `
        -Model $chosen['model'] `
        -Effort $chosen['effort'] `
        -Context $chosen['context'] `
        -AllowAllTools:$AllowAllTools `
        -ExtraArguments @(Get-BridgeSetting 'newSession.extraArgs' @()) `
        -Launcher $launcher `
        -AgencyProfile $AgencyProfile `
        -Resume:$Resume)

    # The agent account's token, so a session the bridge starts can go on and drive
    # the bridge as itself rather than as the person who owns the daemon's token.
    # Without this a session an agent launches is indistinguishable from one you
    # launched, because the only thing that tells them apart is the account on the
    # press - see Get-BridgeAgentToken.
    $agentEnv = Get-BridgeAgentTokenEnvironment

    try {
        if (-not $script:BridgeIsWindows) {
            # macOS: the session runs in a tmux session of its own - which is how the
            # dashboard types into it - shown in a Terminal window attached to it.
            $processId = Start-BridgeTmuxSession -Executable $executable -Arguments $arguments `
                -WorkingDirectory $WorkingDirectory -Name "$launcher-$(Get-Date -Format 'HHmmss')" `
                -Environment $agentEnv
            $process = [pscustomobject]@{ Id = $processId }
        }
        else {
        # Start-Process (ShellExecute) rather than a redirected .NET process start:
        # it gives the child its own console instead of letting it inherit the
        # daemon's hidden one, which is what makes the window visible. It refuses an
        # empty -ArgumentList, so none is passed when there are no arguments.
        #
        # ShellExecute takes no environment of its own, so the variable is set on this
        # process for the child to inherit. Harmless here: nothing the bridge itself
        # runs reads this name - Get-HomeAssistantHeaders resolves the daemon's own
        # token, and only from homeAssistant.token or homeAssistant.tokenEnvVar.
        if ($null -ne $agentEnv) {
            [Environment]::SetEnvironmentVariable($agentEnv.Name, $agentEnv.Value, 'Process')
        }
        $startArgs = @{
            FilePath         = $executable
            WorkingDirectory = $WorkingDirectory
            WindowStyle      = 'Normal'
            PassThru         = $true
            ErrorAction      = 'Stop'
        }
        if ($arguments.Count -gt 0) { $startArgs.ArgumentList = ConvertTo-BridgeArgumentString -Arguments $arguments }
        $process = Start-Process @startArgs
        }

        $result.ProcessId = $process.Id
        $result.Launched = $true
        $verb = if ($Resume.IsPresent) { 'resumed' } else { 'started' }
        $detail = "$verb pid $($process.Id) in $WorkingDirectory via $(Get-BridgeLauncherLabel -Launcher $launcher)"
        if ($launcher -eq 'agency' -and $AgencyProfile) { $detail += " (profile $AgencyProfile)" }
        $result.Detail = $detail
    }
    catch {
        # No "launch failed" prefix: both callers already say that, and the other
        # Detail messages here are bare too.
        $result.Detail = $_.Exception.Message
    }

    $result
}

function Get-BridgeAgentStartFailure {
    <#
        Why a tmux pane was gone before its process could be read.

        tmux returns 0 from `new-session` as soon as the session exists, so a command
        that cannot be executed - or that exits immediately - still looks like a
        successful start, and tmux tears the session down before the pane can be
        listed. "its process could not be found" described that symptom and read like
        a fault in the bridge, when it is almost always the agent itself: npm writes
        its `claude` shim before running the package's postinstall, so a postinstall
        that fails leaves a command that exists, is on PATH, and does nothing.

        So say which it is, and quote what the agent said when asked for its version.
    #>
    param(
        [Parameter(Mandatory)][string]$Executable,
        [scriptblock]$Probe
    )

    if (-not [System.IO.File]::Exists($Executable)) {
        return "$Executable does not exist - the agent is not installed on this machine"
    }

    if (-not $Probe) { $Probe = { param($exe) Invoke-BridgeCommandProbe -Executable $exe } }
    # Not $probe: PowerShell variable names are case-insensitive, so that would assign
    # the result back into the [scriptblock]$Probe parameter and throw on the cast.
    $outcome = & $Probe $Executable

    if ($null -eq $outcome -or -not $outcome.Ran) {
        $why = if ($outcome -and $outcome.Output) { ": $($outcome.Output)" } else { '' }
        return "$Executable could not be run$why - reinstall the agent"
    }
    if ($outcome.TimedOut) {
        return "$Executable did not answer --version - it may be waiting to be signed in; run it in a terminal once"
    }
    if ($outcome.ExitCode -eq 0) {
        return "$Executable runs, but the session exited as soon as it started - run it in a terminal to see why"
    }

    $detail = [string]$outcome.Output
    if ($detail.Length -gt 200) { $detail = $detail.Substring(0, 200) + '...' }
    if (-not $detail) { $detail = "exit $($outcome.ExitCode)" }
    return "$Executable is installed but does not run ($detail) - reinstall the agent"
}

function Start-BridgeTmuxSession {
    <#
        Starts a command in a new detached tmux session and opens a terminal window
        attached to it, returning the command's process id.

        tmux runs a command given as separate arguments directly, with no shell in
        between, so the pane's process is the agent itself and nothing typed on the
        dashboard is ever parsed by a shell. The window is opened through AppleScript:
        Terminal by default, iTerm with `platform.terminal: iTerm`, or none with
        `none` (the session still runs, and `tmux attach` reaches it). macOS asks once
        whether the bridge may control that app.
    #>
    param(
        [Parameter(Mandatory)][string]$Executable,
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$Name,

        # An extra variable for the session's environment, as Name/Value, or $null.
        # tmux does not inherit the caller's environment, which is why PATH is passed
        # below and why anything else the session needs has to come the same way.
        $Environment = $null
    )

    $tmux = Get-BridgeTmuxPath
    if (-not $tmux) { throw 'tmux is not installed (brew install tmux); the bridge runs macOS sessions inside it' }
    $session = "bridge-$($Name -replace '[^A-Za-z0-9_-]', '')"

    $new = @('new-session', '-d', '-s', $session, '-c', $WorkingDirectory, '-x', '220', '-y', '50')
    # The agent inherits the daemon's PATH, which the LaunchAgent sets to the one the
    # installer saw - node, Homebrew and npm's bin included.
    if ($env:PATH) { $new += @('-e', "PATH=$($env:PATH)") }
    if ($null -ne $Environment -and $Environment.Name) { $new += @('-e', "$($Environment.Name)=$($Environment.Value)") }
    $new += '--'
    $new += $Executable
    $new += $Arguments
    & $tmux @new 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "tmux could not start the session (exit $LASTEXITCODE)" }

    $panePid = 0
    for ($i = 0; $i -lt 20 -and $panePid -le 0; $i++) {
        $line = & $tmux list-panes -t $session -F '#{pane_pid}' 2>$null | Select-Object -First 1
        if ($line -match '^\d+$') { $panePid = [int]$line } else { Start-Sleep -Milliseconds 100 }
    }
    if ($panePid -le 0) { throw (Get-BridgeAgentStartFailure -Executable $Executable) }

    Open-BridgeTerminalWindow -Command "'$tmux' attach -t '$session'" `
        -Title (Get-BridgeTerminalWindowTitle -ProcessId $panePid)
    $panePid
}

function Open-BridgeTerminalWindow {
    <#
        Opens a macOS terminal window running $Command (already shell-quoted).

        The window is tagged with $Title so it can be found and closed again when the
        session ends. Nothing else identifies it: the window runs `tmux attach`, whose
        process is not the agent and is gone by the time anything wants to tidy up, so
        without a tag the only way to find it would be to guess - and guessing wrong
        means closing a window of the user's with their own work in it.
    #>
    param(
        [Parameter(Mandatory)][string]$Command,
        [AllowEmptyString()][string]$Title = ''
    )

    $app = [string](Get-BridgeSetting 'platform.terminal' 'Terminal')
    if ($app -eq 'none') { return }
    $quoted = $Command.Replace('\', '\\').Replace('"', '\"')
    $safeTitle = $Title.Replace('\', '\\').Replace('"', '\"')
    $script = if ($app -match '^iterm') {
        # iTerm names the session rather than the tab, and `create window` hands back
        # the window whose current session it is.
        @"
tell application "iTerm"
  set w to (create window with default profile command "$quoted")
  try
    tell current session of w to set name to "$safeTitle"
  end try
end tell
"@
    }
    else {
        # `do script` returns the tab it started in, which is what carries the title.
        @"
tell application "Terminal"
  set t to do script "$quoted"
  try
    set custom title of t to "$safeTitle"
  end try
  activate
end tell
"@
    }
    & osascript -e $script 2>&1 | Out-Null
}

function Get-BridgeTerminalWindowTitle {
    <#
        The tag put on the terminal window opened for a session.

        Keyed on the process the window was opened for, because that is the one thing
        both ends have: the launcher knows it the moment tmux reports the pane, and
        the daemon still has it when the session is stopped. A session id would not
        do - Codex chooses its own, and does so after the window is already open.
    #>
    param([Parameter(Mandatory)][int]$ProcessId)
    "agent-bridge:$ProcessId"
}

function Close-BridgeTerminalWindow {
    <#
        Closes the terminal window the bridge opened for a session, by its tag.

        macOS needs this and Windows does not. There, the bridge starts the CLI with
        its own console and closing the window is a matter of ending that process. On
        a Mac the session runs inside tmux and the window is a separate Terminal
        window running `tmux attach`: when the agent exits, tmux tears its session
        down and the attach returns, but the window stays open showing a dead shell.
        The pid the daemon has is the tmux *pane's* - the agent itself - so there is
        no process left whose death would take the window with it.

        Only ever called for a window the bridge opened, and only ever closes one
        carrying this bridge's tag, so a terminal the user opened is never touched.
        A window with something still running in it is left alone rather than closed,
        because the confirmation macOS raises for that is modal and there is nobody
        at the keyboard to answer it.

        Best effort: a window that has already been closed, a terminal that is not
        running, or an osascript that fails must not stop a session from ending.
        Returns whether a window was closed.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Title,

        # How long to give tmux to finish tearing down before the window is judged
        # busy. The attach returns on its own once the session is gone; closing in
        # that gap would find the window still running something and leave it.
        [double]$SettleSeconds = 6
    )

    if ([string]::IsNullOrWhiteSpace($Title)) { return $false }
    $app = [string](Get-BridgeSetting 'platform.terminal' 'Terminal')
    if ($app -eq 'none') { return $false }
    if ($script:BridgeIsWindows) { return $false }
    $waitTicks = [Math]::Max(1, [int][Math]::Round($SettleSeconds / 0.5))

    $safeTitle = $Title.Replace('\', '\\').Replace('"', '\"')
    # Two things had to be got right here, both learned from a real Mac.
    #
    # Windows are addressed by id through `window id N`, Terminal's own by-id
    # specifier - not as the references `repeat with w in windows` hands out, and not
    # through `first window whose id is N`. The plain references are positional
    # (`window 1`, `window 2`), so closing the first shifts every later one down and
    # the rest of the list then points at whatever moved into that slot; on a real Mac
    # that closed a window belonging to a *different* session, leaving its tmux
    # detached with no window and its card still on the dashboard. A `whose` filter
    # fares no better here - Terminal resolved one to the wrong window too.
    #
    # And `close` is never called on a busy window. `saving no` suppresses the *save*
    # prompt; the "terminate running processes?" confirmation is a different dialog
    # and it is modal. Closing a busy window therefore does not fail - it puts a
    # dialog on the user's screen and waits, and every later attempt queues another
    # behind it. That is what left windows stuck open and unclosable through repeated
    # attempts. So the window is given a few seconds to go idle first, which is all
    # tmux needs to finish tearing down and let the attach return, and if something
    # is still running after that the window is left alone - much the better outcome
    # than a modal dialog nobody is at the keyboard to answer.
    #
    # What comes back is how many actually went, counted by looking again - not how
    # many matched. `close` is wrapped in `try` because a window that has already gone
    # must not throw, and that same `try` will swallow a close that genuinely failed;
    # returning the matched count would then report success for a window still sitting
    # on screen. Measured on a real Mac, where exactly that happened.
    $script = if ($app -match '^iterm') {
        @"
tell application "iTerm"
  set doomed to {}
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        try
          if name of s is "$safeTitle" then
            set wid to id of w
            if doomed does not contain wid then set end of doomed to wid
          end if
        end try
      end repeat
    end repeat
  end repeat
  repeat with wid in doomed
    try
      close (window id wid)
    end try
  end repeat
  delay 0.3
  set remaining to 0
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        try
          if name of s is "$safeTitle" then set remaining to remaining + 1
        end try
      end repeat
    end repeat
  end repeat
  return ((count of doomed) - remaining)
end tell
"@
    }
    else {
        @"
tell application "Terminal"
  set doomed to {}
  repeat with w in windows
    repeat with t in tabs of w
      try
        if custom title of t is "$safeTitle" then
          set wid to id of w
          if doomed does not contain wid then set end of doomed to wid
        end if
      end try
    end repeat
  end repeat
  repeat with wid in doomed
    try
      set target to (window id wid)
      repeat $waitTicks times
        if (busy of target) is false then exit repeat
        delay 0.5
      end repeat
      if (busy of target) is false then close target saving no
    end try
  end repeat
  delay 0.3
  set remaining to 0
  repeat with w in windows
    repeat with t in tabs of w
      try
        if custom title of t is "$safeTitle" then set remaining to remaining + 1
      end try
    end repeat
  end repeat
  return ((count of doomed) - remaining)
end tell
"@
    }

    try {
        $out = (& osascript -e $script 2>&1 | Out-String).Trim()
        return ($out -match '^[1-9]')
    }
    catch { return $false }
}

function Stop-BridgeCopilotSession {
    <#
        Ends a running session.

        Graceful first: `/exit` is typed into the session's console exactly as a reply
        would be, so the CLI shuts down the way it does at the keyboard - writing its
        transcript, closing its MCP servers and releasing the lock file. Only if it is
        still there after the grace period is the process terminated, because a killed
        CLI leaves a stale lock and half-written state behind.

        This is deliberately non-destructive. The session's transcript survives either
        way, so an ended session remains in the resume list and can be reopened; a
        mistaken press costs a window, not the work.

        Returns a result object rather than throwing - a failed stop must leave the
        daemon running, like every other action here.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][int]$ProcessId,

        # How long to let the CLI close itself before the process is terminated.
        [int]$GraceSeconds = 12
    )

    $result = [pscustomobject]@{
        Stopped = $false
        Forced  = $false
        Detail  = ''
    }

    if ($ProcessId -le 0) {
        $result.Detail = 'no process id for session'
        return $result
    }

    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        # Already gone: report success, because the caller's goal is met.
        $result.Stopped = $true
        $result.Detail = "process $ProcessId had already exited"
        return $result
    }

    $delivery = Send-CopilotSessionPrompt -SessionId $SessionId -ProcessId $ProcessId -Text '/exit'
    if (-not $delivery.Delivered) {
        $result.Detail = "could not type /exit: $($delivery.Detail)"
    }

    $deadline = [DateTimeOffset]::Now.AddSeconds($GraceSeconds)
    while ([DateTimeOffset]::Now -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if ($null -eq (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
            $result.Stopped = $true
            $result.Detail = "exited cleanly (pid $ProcessId)"
            return $result
        }
    }

    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
        Start-Sleep -Milliseconds 800
        $result.Stopped = ($null -eq (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue))
        $result.Forced = $true
        $result.Detail = if ($result.Stopped) {
            "did not exit within $GraceSeconds s; terminated pid $ProcessId"
        } else {
            "could not terminate pid $ProcessId"
        }
    }
    catch {
        $result.Detail = "terminate failed: $($_.Exception.Message)"
    }

    $result
}

function Get-BridgeRegisteredSessionId {
    <#
        The id a launched session actually registered under, or '' if it has not yet.

        This exists so that "has the launch registered?" and "as what?" are one
        answer rather than two. Only one agent hands back the id it was given:
        Copilot and Claude register under the id the bridge invented for them, but
        Codex picks its own, and its registration is recognised only as the first one
        written after the launch. Deciding that a launch has registered in one place
        and then guessing which session it produced somewhere else is how a session
        would come to wear somebody else's driver, which is worse than wearing none.

        No waiting, so the daemon can call it on every pass without stalling.

        The session directory and its `inuse.<pid>.lock` are what the daemon discovers
        Copilot sessions from; Claude and Codex register through their hooks under
        %TEMP% instead, recording the owning pid. Either way the pid is checked against
        the running processes: a resumed session's directory may still hold the lock
        from the run that created it, so the file alone would report success for a
        resume that never started.

        A resume writes no lock of its own, though - resuming onto an id that already
        has history leaves the CLI running with nothing under the session directory to
        say so - so a live process naming the session on its command line counts as
        registered too. Without that, a resumed session never registered at all: the
        launch note sat on "may still be starting" while the session was up and
        answering, and pressing Resume again put a second CLI on its transcript.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SessionId,
        [string]$Launcher = 'copilot',

        # Codex chooses its own session id, so its registration is recognised as the
        # first one written after the launch.
        [DateTimeOffset]$Since = [DateTimeOffset]::Now.AddMinutes(-1)
    )

    # Agents that register through their hooks (Claude, Codex) record the owning pid
    # under the installation runtime root; the rest are Copilot sessions, found by their lock files below.
    $registrations = (Get-BridgeLauncher -Launcher $Launcher).RegistrationFiles
    if ($registrations) {
        $stateDir = Get-BridgeRuntimePath "agent-bridge-$Launcher"
        if (-not [System.IO.Directory]::Exists($stateDir)) { return '' }
        $files = @(& $registrations $stateDir $SessionId $Since)
        foreach ($file in $files) {
            try { $entry = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { continue }
            $processId = [int]($entry.ProcessId ?? 0)
            if ($processId -le 0) { continue }
            $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if (Test-BridgeAgentProcess -Process $process -Agent $Launcher) {
                # The file is named for the session, which is how an agent that chose
                # its own id says what it chose.
                return [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            }
        }
        return ''
    }

    $directory = Join-Path $script:DecisionBridgeConfig.SessionStateRoot $SessionId
    if (-not [System.IO.Directory]::Exists($directory)) { return '' }
    $processes = @(Get-BridgeAgentProcesses -Agent 'copilot')
    $livePids = @{}
    foreach ($process in $processes) { $livePids[$process.Id] = $true }
    foreach ($lock in [System.IO.Directory]::EnumerateFiles($directory, 'inuse.*.lock')) {
        $name = [System.IO.Path]::GetFileName($lock)
        if ($name -notmatch '^inuse\.(\d+)\.lock$') { continue }
        if ($livePids.ContainsKey([int]$Matches[1])) { return $SessionId }
    }

    # The resume case, which leaves no lock to find.
    foreach ($named in (Get-BridgeAgentProcessSessionIds -Processes $processes).Values) {
        if ([string]$named -eq $SessionId) { return $SessionId }
    }
    ''
}

function Test-BridgeSessionRegistered {
    <#
        One look at whether a launched session has registered - no waiting, so the
        daemon can call it on every pass without stalling. A thin reading of
        Get-BridgeRegisteredSessionId, so this and "which session was it" are always
        the same answer.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SessionId,
        [string]$Launcher = 'copilot',
        [DateTimeOffset]$Since = [DateTimeOffset]::Now.AddMinutes(-1)
    )

    -not [string]::IsNullOrWhiteSpace(
        (Get-BridgeRegisteredSessionId -SessionId $SessionId -Launcher $Launcher -Since $Since))
}

function Wait-BridgeSessionRegistered {
    <#
        Waits up to TimeoutSeconds for Test-BridgeSessionRegistered. The daemon no
        longer waits on a launch - it checks once per pass - but this remains for
        callers that genuinely want to block.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SessionId,
        [int]$TimeoutSeconds = 25,
        [string]$Launcher = 'copilot',
        [DateTimeOffset]$Since = [DateTimeOffset]::Now.AddMinutes(-1)
    )

    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::Now -lt $deadline) {
        if (Test-BridgeSessionRegistered -SessionId $SessionId -Launcher $Launcher -Since $Since) { return $true }
        Start-Sleep -Milliseconds 500
    }
    $false
}
