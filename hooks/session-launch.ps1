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

    $excluded = @($env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:TEMP) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($candidate in $excluded) {
        $prefix = [System.IO.Path]::GetFullPath($candidate).TrimEnd('\', '/')
        if ($full -eq $prefix -or $full.StartsWith("$prefix\", [StringComparison]::OrdinalIgnoreCase)) { return $true }
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

    $npm = Join-Path $env:APPDATA 'npm\codex.cmd'
    if ([System.IO.File]::Exists($npm)) { return $npm }

    $null
}

# Every agent the bridge can start, keyed by kind, valued by the label shown on the
# dashboard. The order is the one 'auto' prefers: Agency first, because a machine
# that has it expects sessions to carry an Agency profile.
$script:BridgeLaunchers = [ordered]@{
    agency  = 'Agency'
    copilot = 'Copilot'
    claude  = 'Claude'
    codex   = 'Codex'
}

function Get-BridgeLauncherPath {
    param([Parameter(Mandatory)][string]$Launcher)

    switch ($Launcher) {
        'agency'  { return Get-BridgeAgencyPath }
        'copilot' { return Get-BridgeCopilotPath }
        'claude'  { return Get-BridgeClaudePath }
        'codex'   { return Get-BridgeCodexPath }
    }
    $null
}

function Get-BridgeAvailableLaunchers {
    <#
        The launchers installed on this machine, in preference order. This is what the
        dashboard's agent selector offers, so it cannot show a choice that would fail.
    #>
    @(@($script:BridgeLaunchers.Keys) | Where-Object { Get-BridgeLauncherPath -Launcher $_ })
}

function Get-BridgeLauncherLabel {
    param([Parameter(Mandatory)][string]$Launcher)
    if ($script:BridgeLaunchers.Contains($Launcher)) { return [string]$script:BridgeLaunchers[$Launcher] }
    $Launcher
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

function Get-BridgeLauncherKind {
    <#
        The default launcher for new sessions: 'agency', 'copilot', 'claude' or 'codex'.

        `newSession.launcher` names it. 'auto' (the default), or a launcher that is not
        installed, falls back to the first installed one in preference order rather
        than failing. With nothing installed it still answers 'copilot', so the launch
        reports which executable is missing instead of doing nothing.
    #>
    $configured = ([string](Get-BridgeSetting 'newSession.launcher' 'auto')).Trim().ToLowerInvariant()
    $available = @(Get-BridgeAvailableLaunchers)

    if ($available -contains $configured) { return $configured }
    if ($available.Count -gt 0) { return [string]$available[0] }
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
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SessionId,
        [string]$Prompt = '',
        [string]$Model = '',
        [switch]$AllowAllTools,
        [string[]]$ExtraArguments = @(),
        [ValidateSet('copilot', 'agency', 'claude', 'codex')][string]$Launcher = 'copilot',
        [string]$AgencyProfile = ''
    )

    $flatPrompt = ($Prompt -replace '\r?\n', ' ').Trim()
    $extras = @(@($ExtraArguments) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [string]$_ })

    if ($Launcher -in @('claude', 'codex')) {
        $arguments = @()
        if ($Launcher -eq 'claude' -and -not [string]::IsNullOrWhiteSpace($SessionId)) {
            $arguments += @('--session-id', $SessionId)
        }
        if (-not [string]::IsNullOrWhiteSpace($Model)) { $arguments += @('--model', $Model) }
        # Opt-in only, as for Copilot. Codex keeps its sandbox; only approvals go.
        if ($AllowAllTools.IsPresent) {
            $arguments += if ($Launcher -eq 'claude') { '--dangerously-skip-permissions' } else { @('--ask-for-approval', 'never') }
        }
        $arguments += $extras
        if ($flatPrompt) { $arguments += @('--', $flatPrompt) }
        return @($arguments)
    }

    # Copilot-side arguments, identical in both modes.
    $copilotArguments = @('--banner')

    if (-not [string]::IsNullOrWhiteSpace($Model)) { $copilotArguments += @('--model', $Model) }

    # Off unless explicitly configured. A session launched from a phone may well run
    # unattended, and the bridge already routes permission prompts to Home Assistant,
    # so there is no reason to hand it blanket approval by default.
    if ($AllowAllTools.IsPresent) { $copilotArguments += '--allow-all-tools' }

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

function Get-BridgeResumableSessions {
    <#
        Recent sessions that can be resumed, newest first.

        Agency is the only thing that knows this: it aggregates sessions from the CLI,
        the desktop app and VS Code, and marks which are actually resumable. On a
        working machine that call returns about half a megabyte describing 700+
        sessions and takes over a second, so it is never run on a reconcile - the
        daemon caches the result and only refreshes it on a timer.

        `can_resume` is the filter that matters: desktop-app and VS Code sessions all
        report false, and resuming one in a terminal is not a thing. Sessions that are
        currently live are excluded separately by the caller, because attaching a
        second process to a running session would mean two CLIs writing one transcript.
    #>
    param(
        [int]$Limit = 0,

        # Session ids to leave out - the live ones.
        [AllowEmptyCollection()]
        [string[]]$Exclude = @()
    )

    if ($Limit -le 0) { $Limit = [int](Get-BridgeSetting 'newSession.resumeCount' 12) }
    if ($Limit -le 0) { return @() }

    $json = Get-BridgeAgencySessionJson
    if ([string]::IsNullOrWhiteSpace($json)) { return @() }

    try { $parsed = $json | ConvertFrom-Json }
    catch { return @() }

    if ($null -eq $parsed -or -not $parsed.PSObject.Properties['sessions']) { return @() }

    $excluded = @{}
    foreach ($id in @($Exclude)) {
        if (-not [string]::IsNullOrWhiteSpace($id)) { $excluded[[string]$id] = $true }
    }

    $candidates = foreach ($session in @($parsed.sessions)) {
        if (-not $session.can_resume) { continue }
        $id = [string]$session.session_id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if ($excluded.ContainsKey($id)) { continue }

        $updated = [DateTimeOffset]::MinValue
        if ($session.PSObject.Properties['updated_at']) {
            [void][DateTimeOffset]::TryParse([string]$session.updated_at, [ref]$updated)
        }

        [pscustomobject]@{
            SessionId = $id
            Summary   = if ($session.PSObject.Properties['summary']) { [string]$session.summary } else { '' }
            Folder    = if ($session.PSObject.Properties['folder']) { [string]$session.folder } else { '' }
            Updated   = $updated
        }
    }

    $recent = @($candidates) | Sort-Object Updated -Descending | Select-Object -First $Limit

    # Build display labels. Home Assistant needs every option in a select to be
    # unique, and a duplicate would make two different sessions indistinguishable, so
    # a repeated label gets its session-id prefix appended.
    $seen = @{}
    $results = foreach ($entry in @($recent)) {
        $short = $entry.SessionId.Substring(0, [Math]::Min(8, $entry.SessionId.Length))
        $summary = ($entry.Summary -replace '\s+', ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($summary)) { $summary = "Session $short" }

        $folderLeaf = ''
        if (-not [string]::IsNullOrWhiteSpace($entry.Folder)) {
            $folderLeaf = [System.IO.Path]::GetFileName($entry.Folder.TrimEnd('\', '/'))
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
            Folder    = $entry.Folder
            Updated   = $entry.Updated
        }
    }

    @($results)
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

        # Resuming an existing session rather than creating one. The command line is
        # identical - the CLI resumes whenever --session-id names a session that
        # already exists - so this only affects what gets reported.
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
    if ([string]::IsNullOrWhiteSpace($result.SessionId) -and $launcher -ne 'codex') {
        $result.SessionId = [guid]::NewGuid().ToString()
    }

    $arguments = Get-BridgeNewSessionArguments `
        -SessionId $result.SessionId `
        -Prompt $Prompt `
        -Model ([string](Get-BridgeSetting 'newSession.model' '')) `
        -AllowAllTools:([bool](Get-BridgeSetting 'newSession.allowAllTools' $false)) `
        -ExtraArguments @(Get-BridgeSetting 'newSession.extraArgs' @()) `
        -Launcher $launcher `
        -AgencyProfile $AgencyProfile

    try {
        # Start-Process (ShellExecute) rather than a redirected .NET process start:
        # it gives the child its own console instead of letting it inherit the
        # daemon's hidden one, which is what makes the window visible.
        $process = Start-Process -FilePath $executable `
            -ArgumentList (ConvertTo-BridgeArgumentString -Arguments $arguments) `
            -WorkingDirectory $WorkingDirectory `
            -WindowStyle Normal -PassThru -ErrorAction Stop

        $result.ProcessId = $process.Id
        $result.Launched = $true
        $verb = if ($Resume.IsPresent) { 'resumed' } else { 'started' }
        $detail = "$verb pid $($process.Id) in $WorkingDirectory via $(Get-BridgeLauncherLabel -Launcher $launcher)"
        if ($launcher -eq 'agency' -and $AgencyProfile) { $detail += " (profile $AgencyProfile)" }
        $result.Detail = $detail
    }
    catch {
        $result.Detail = "launch failed: $($_.Exception.Message)"
    }

    $result
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

function Wait-BridgeSessionRegistered {
    <#
        Waits for the CLI to register the session it was told to create or resume.

        The session directory and its `inuse.<pid>.lock` are what the daemon
        discovers sessions from, so their appearance is the real confirmation that
        the launch worked - a process id alone only proves something started, not
        that it got far enough to be a session. Used to report an honest result on
        the dashboard rather than an optimistic one.

        The lock's pid has to be checked against the live process list rather than
        taken at face value. A resumed session's directory usually still holds the
        lock from the run that created it, so simply looking for the file would
        report instant success for a resume that in fact never started.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SessionId,
        [int]$TimeoutSeconds = 25,

        # Claude and Codex have no lock file; their hooks write a registration under
        # %TEMP% instead, recording the owning pid, and that is waited for.
        [string]$Launcher = 'copilot',

        # Codex chooses its own session id, so its registration is recognised as the
        # first one written after the launch.
        [DateTimeOffset]$Since = [DateTimeOffset]::Now.AddMinutes(-1)
    )

    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)

    if ($Launcher -in @('claude', 'codex')) {
        $stateDir = Join-Path $env:TEMP "agent-bridge-$Launcher"
        while ([DateTimeOffset]::Now -lt $deadline) {
            if ([System.IO.Directory]::Exists($stateDir)) {
                $files = if ($Launcher -eq 'claude') {
                    @(Join-Path $stateDir "$SessionId.json" | Where-Object { [System.IO.File]::Exists($_) } | Get-Item)
                }
                else {
                    @(Get-ChildItem -LiteralPath $stateDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -notlike '*.approval.json' -and $_.LastWriteTime -ge $Since.LocalDateTime })
                }
                foreach ($file in $files) {
                    try { $entry = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { continue }
                    $processId = [int]($entry.ProcessId ?? 0)
                    if ($processId -le 0) { continue }
                    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
                    if ($process -and $process.ProcessName -match "^$Launcher") { return $true }
                }
            }
            Start-Sleep -Milliseconds 500
        }
        return $false
    }

    $directory = Join-Path $script:DecisionBridgeConfig.SessionStateRoot $SessionId

    while ([DateTimeOffset]::Now -lt $deadline) {
        if ([System.IO.Directory]::Exists($directory)) {
            $livePids = @{}
            foreach ($process in @(Get-Process -Name 'copilot' -ErrorAction SilentlyContinue)) {
                $livePids[$process.Id] = $true
            }

            foreach ($lock in [System.IO.Directory]::EnumerateFiles($directory, 'inuse.*.lock')) {
                $name = [System.IO.Path]::GetFileName($lock)
                if ($name -notmatch '^inuse\.(\d+)\.lock$') { continue }
                if ($livePids.ContainsKey([int]$Matches[1])) { return $true }
            }
        }
        Start-Sleep -Milliseconds 500
    }

    $false
}

