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

        A fresh install has no `newSession.workspaces`, and the folders a user actually
        works in are already known: every Claude transcript records its cwd, and the
        Claude and Codex hooks register theirs. Offering those means the launch card
        works on a new machine without editing any config.

        These come only from files the agents write locally, never from Home
        Assistant, so they sit inside the same boundary as the configured list. System
        folders are dropped (see Test-BridgeSystemDirectory). Disabled with
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
        $dir = Join-Path $env:TEMP $stateDir
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
    $projects = Join-Path $HOME '.claude\projects'
    if ([System.IO.Directory]::Exists($projects)) {
        $dirs = Get-ChildItem -LiteralPath $projects -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First ($limit * 3)
        foreach ($dir in $dirs) {
            $newest = Get-ChildItem -LiteralPath $dir.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($null -eq $newest) { continue }
            try {
                foreach ($line in [System.Linq.Enumerable]::Take([System.IO.File]::ReadLines($newest.FullName), 40)) {
                    if ($line -notmatch '"cwd"') { continue }
                    $cwd = [string]($line | ConvertFrom-Json).cwd
                    if ($cwd) {
                        $candidates.Add([pscustomobject]@{ Path = $cwd; Updated = $newest.LastWriteTime })
                        break
                    }
                }
            }
            catch { }
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
        The directories offered as launch targets: `newSession.workspaces` first, then
        folders recent sessions worked in (Get-BridgeDiscoveredWorkspaces), and the home
        folder if both are empty, so the launch card is never left with nothing.

        Each configured entry is either a plain path string or an object with `label`
        and `path`. A label keeps the dropdown readable on a phone, where a full path is
        unusable, and is what the daemon matches against when the button is pressed.

        This list is also the security boundary. The daemon never launches a path
        that came from Home Assistant; it launches a path from this list, selected by
        label. A wrong or tampered entity state can therefore only ever pick a
        directory the user configured or already worked in, or nothing at all.

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

        [pscustomobject]@{ Label = $label; Path = $path }
    }
    $choices = @($choices)

    $known = @{}
    foreach ($choice in $choices) { $known[$choice.Path.TrimEnd('\', '/').ToLowerInvariant()] = $true }
    foreach ($path in @(Get-BridgeDiscoveredWorkspaces)) {
        if ($known.ContainsKey($path.ToLowerInvariant())) { continue }
        $known[$path.ToLowerInvariant()] = $true
        $choices += [pscustomobject]@{ Label = [System.IO.Path]::GetFileName($path); Path = $path }
    }

    if ($choices.Count -eq 0 -and [System.IO.Directory]::Exists($HOME)) {
        $choices = @([pscustomobject]@{ Label = 'Home'; Path = [System.IO.Path]::GetFullPath($HOME) })
    }

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
        [pscustomobject]@{ Label = $label; Path = $choice.Path }
    }

    @($unique)
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
            param($SessionId, $Model, $AllowAllTools, $Extras, $Resuming, $FlatPrompt)
            $arguments = @()
            # Claude refuses an id already in use, so a resume needs `--resume <id>`.
            if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
                $arguments += if ($Resuming) { @('--resume', $SessionId) } else { @('--session-id', $SessionId) }
            }
            if (-not [string]::IsNullOrWhiteSpace($Model)) { $arguments += @('--model', $Model) }
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
            param($SessionId, $Model, $AllowAllTools, $Extras, $Resuming, $FlatPrompt)
            # Without its shared background daemon, Codex runs hooks from its own
            # window's process. Under the daemon - which has no console - Windows opened
            # a console window for every hook, several a turn, and a reply could not tell
            # which window was the session's.
            $arguments = @('--no-daemon')
            # Reasoning summaries, which the card streams; without this Codex writes its
            # reasoning encrypted and there is nothing to show.
            if ([bool](Get-BridgeSetting 'detailedActivity' $true)) { $arguments += @('-c', 'model_reasoning_summary=detailed') }
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

function Get-BridgeAgencyProfiles {
    <#
        The Agency profiles offered on the dashboard.

        Read from config rather than by shelling out to `agency config profiles` on
        every reconcile: that call costs a process launch and a config-cache read,
        and the profile list changes about as often as the config file does.
    #>
    $configured = @(Get-BridgeSetting 'newSession.profiles' @('work', 'home', 'local'))
    @($configured | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Resolve-BridgeAgencyProfile {
    <#
        Validates a profile name coming from Home Assistant against the configured
        list, for the same reason workspaces are resolved by label: a value arriving
        from outside is never passed to a command line unchecked.
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
        `newSession.defaultProfile`. Falls back to the first configured profile for
        the same reason the workspace does: pressing Launch must never require a
        preceding selection.
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
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SessionId,
        [string]$Prompt = '',
        [string]$Model = '',
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
        return @(& $own $SessionId $Model $AllowAllTools.IsPresent $extras $resuming $flatPrompt)
    }

    # Copilot-side arguments, identical in both modes.
    $copilotArguments = @('--banner')

    if (-not [string]::IsNullOrWhiteSpace($Model)) { $copilotArguments += @('--model', $Model) }

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
        $raw = & $agency hub list-local-sessions --json 2>$null | Out-String
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
            foreach ($line in [System.IO.File]::ReadAllLines($workspace)) {
                if ($line -match '^(\w+):\s*(.*)$') {
                    $value = $Matches[2].Trim().Trim('"', "'")
                    switch ($Matches[1]) {
                        'cwd' { $folder = $value }
                        'summary' { $summary = $value }
                        'updated_at' { $parsed = [DateTimeOffset]::MinValue; if ([DateTimeOffset]::TryParse($value, [ref]$parsed)) { $updated = $parsed } }
                    }
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
        }
    }

    @($results)
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

    # Wrapped: an empty list (Codex with no prompt and no options) came back as $null
    # and failed the launch before anything started.
    $arguments = @(Get-BridgeNewSessionArguments `
        -SessionId $result.SessionId `
        -Prompt $Prompt `
        -Model ([string](Get-BridgeSetting 'newSession.model' '')) `
        -AllowAllTools:([bool](Get-BridgeSetting 'newSession.allowAllTools' $false)) `
        -ExtraArguments @(Get-BridgeSetting 'newSession.extraArgs' @()) `
        -Launcher $launcher `
        -AgencyProfile $AgencyProfile `
        -Resume:$Resume)

    try {
        if (-not $script:BridgeIsWindows) {
            # macOS: the session runs in a tmux session of its own - which is how the
            # dashboard types into it - shown in a Terminal window attached to it.
            $processId = Start-BridgeTmuxSession -Executable $executable -Arguments $arguments `
                -WorkingDirectory $WorkingDirectory -Name "$launcher-$(Get-Date -Format 'HHmmss')"
            $process = [pscustomobject]@{ Id = $processId }
        }
        else {
        # Start-Process (ShellExecute) rather than a redirected .NET process start:
        # it gives the child its own console instead of letting it inherit the
        # daemon's hidden one, which is what makes the window visible. It refuses an
        # empty -ArgumentList, so none is passed when there are no arguments.
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
        [Parameter(Mandatory)][string]$Name
    )

    $tmux = Get-BridgeTmuxPath
    if (-not $tmux) { throw 'tmux is not installed (brew install tmux); the bridge runs macOS sessions inside it' }
    $session = "bridge-$($Name -replace '[^A-Za-z0-9_-]', '')"

    $new = @('new-session', '-d', '-s', $session, '-c', $WorkingDirectory, '-x', '220', '-y', '50')
    # The agent inherits the daemon's PATH, which the LaunchAgent sets to the one the
    # installer saw - node, Homebrew and npm's bin included.
    if ($env:PATH) { $new += @('-e', "PATH=$($env:PATH)") }
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

    Open-BridgeTerminalWindow -Command "'$tmux' attach -t '$session'"
    $panePid
}

function Open-BridgeTerminalWindow {
    <# Opens a macOS terminal window running $Command (already shell-quoted). #>
    param([Parameter(Mandatory)][string]$Command)

    $app = [string](Get-BridgeSetting 'platform.terminal' 'Terminal')
    if ($app -eq 'none') { return }
    $quoted = $Command.Replace('\', '\\').Replace('"', '\"')
    $script = if ($app -match '^iterm') {
        "tell application `"iTerm`" to create window with default profile command `"$quoted`""
    }
    else {
        "tell application `"Terminal`"`n  do script `"$quoted`"`n  activate`nend tell"
    }
    & osascript -e $script 2>&1 | Out-Null
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

function Test-BridgeSessionRegistered {
    <#
        One look at whether a launched session has registered - no waiting, so the
        daemon can call it on every pass without stalling.

        The session directory and its `inuse.<pid>.lock` are what the daemon discovers
        Copilot sessions from; Claude and Codex register through their hooks under
        %TEMP% instead, recording the owning pid. Either way the pid is checked against
        the running processes: a resumed session's directory usually still holds the
        lock from the run that created it, so the file alone would report success for a
        resume that never started.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SessionId,
        [string]$Launcher = 'copilot',

        # Codex chooses its own session id, so its registration is recognised as the
        # first one written after the launch.
        [DateTimeOffset]$Since = [DateTimeOffset]::Now.AddMinutes(-1)
    )

    # Agents that register through their hooks (Claude, Codex) record the owning pid
    # under %TEMP%; the rest are Copilot sessions, found by their lock files below.
    $registrations = (Get-BridgeLauncher -Launcher $Launcher).RegistrationFiles
    if ($registrations) {
        $stateDir = Join-Path $env:TEMP "agent-bridge-$Launcher"
        if (-not [System.IO.Directory]::Exists($stateDir)) { return $false }
        $files = @(& $registrations $stateDir $SessionId $Since)
        foreach ($file in $files) {
            try { $entry = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { continue }
            $processId = [int]($entry.ProcessId ?? 0)
            if ($processId -le 0) { continue }
            $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if (Test-BridgeAgentProcess -Process $process -Agent $Launcher) { return $true }
        }
        return $false
    }

    $directory = Join-Path $script:DecisionBridgeConfig.SessionStateRoot $SessionId
    if (-not [System.IO.Directory]::Exists($directory)) { return $false }
    $livePids = @{}
    foreach ($process in @(Get-BridgeAgentProcesses -Agent 'copilot')) { $livePids[$process.Id] = $true }
    foreach ($lock in [System.IO.Directory]::EnumerateFiles($directory, 'inuse.*.lock')) {
        $name = [System.IO.Path]::GetFileName($lock)
        if ($name -notmatch '^inuse\.(\d+)\.lock$') { continue }
        if ($livePids.ContainsKey([int]$Matches[1])) { return $true }
    }
    $false
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

