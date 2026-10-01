<#
.SYNOPSIS
    Installs the Copilot <-> Home Assistant bridge.

.DESCRIPTION
    Copies the shared hook scripts into the bridge home, writes the config, and
    registers the supervisor as a hidden scheduled task. It then configures the
    clients you choose - Copilot CLI, Claude Code, Codex CLI - registering each one's
    hooks; the shared daemon, dashboard and Home Assistant plumbing are installed
    regardless.

    Anything missing is offered rather than demanded: PowerShell 7, Node.js and the
    agent CLIs themselves can all be installed from here. It also puts an
    `agent-ha-bridge` command on your PATH, which is how you reconfigure later without
    needing the repository.

    Everything is idempotent: re-running it upgrades an existing install in place.

.PARAMETER HomeAssistantUrl
    Base URL of Home Assistant, e.g. http://homeassistant.local:8123. Supplying this
    explicitly authorizes using the configured credentials at that endpoint.

.PARAMETER Token
    A Home Assistant long-lived access token. Stored in the bridge config outside the
    repository. Omit it to keep an existing token, or to supply one via the
    AGENT_HA_TOKEN environment variable instead.

.PARAMETER AgentToken
    A long-lived access token belonging to a *separate* Home Assistant account that
    stands for the agent. What an agent does through the bridge is then attributed to
    that account instead of to you, which is the only thing that can tell an agent's
    turn from yours. The matching user id is read back from the token and stored for
    you. Omit it to keep an existing one, or to supply one via the
    AGENT_HA_AGENT_TOKEN environment variable instead.

.PARAMETER NotifyService
    Optional Home Assistant notify-style service for out-of-band alerts, e.g.
    notify.mobile_app_pixel. Omit to disable notifications.

.PARAMETER TargetHome
    Install into this directory's .agent-ha-bridge instead of $HOME's. Intended for
    testing a build without touching a working install; $HOME is read-only in
    PowerShell, so it cannot be redirected any other way.

.PARAMETER Clients
    Which clients to configure: any of copilot, claude, codex (comma-separated).
    Omit it to be asked interactively, or to reuse a previously chosen set on a
    re-run. A non-interactive run with nothing set configures copilot.

.PARAMETER SkipVerify
    Skip the Home Assistant connectivity check. Use for an offline install, or when
    the token comes from an environment variable that is not set yet.

.PARAMETER SkipDependencies
    Never offer to install anything (PowerShell 7, Node.js, the agent CLIs). Missing
    prerequisites are reported with the command that would install them.

.PARAMETER SkipPath
    Do not put the `agent-ha-bridge` command on your PATH.

.PARAMETER DevBoxKeepAwake
    On a Microsoft Dev Box, register a scheduled task that keeps the machine from
    hibernating itself while the bridge is running. A pool with stop-on-disconnect
    measures idleness by RDP sessions rather than by load, so a Dev Box busy running
    the daemon and several agent sessions is hibernated anyway. The task clears the
    pending stop through Dev Center's own user-scoped API. Use
    -DevBoxKeepAwake:$false to turn it off; omit it to keep the current setting, or
    to be asked once on a Dev Box that has not chosen yet. Ignored elsewhere.

.PARAMETER TestRegistryId
    Unique registry namespace for disposable installer tests. Requires -TargetHome;
    it does not isolate other machine-wide effects.

.PARAMETER NonInteractive
    Never prompt. Without this, the installer discovers Home Assistant on the network
    and asks for anything it still needs.

.EXAMPLE
    .\install.ps1 -HomeAssistantUrl http://homeassistant.local:8123

.EXAMPLE
    .\install.ps1 -HomeAssistantUrl http://ha.lan:8123 -NotifyService notify.mobile_app_pixel

.EXAMPLE
    # Once installed, reconfigure from anywhere - no clone needed.
    agent-ha-bridge configure
#>

[CmdletBinding()]
param(
    [string]$HomeAssistantUrl,
    [string]$Token,
    [string]$AgentToken,
    [string]$NotifyService,
    [string]$TickerCategory,
    [string]$TargetHome,
    [string[]]$Clients,
    [switch]$SkipVerify,
    [switch]$SkipDependencies,
    [switch]$SkipPath,
    [switch]$NonInteractive,
    [switch]$SkipTask,
    [switch]$DevBoxKeepAwake,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$TestRegistryId
)

$ErrorActionPreference = 'Stop'
if ($TestRegistryId -and -not $TargetHome) { throw '-TestRegistryId requires -TargetHome.' }
$testRegistrySuffix = if ($TestRegistryId) { "_$TestRegistryId" } else { '' }

$repoRoot = $PSScriptRoot
# Windows/macOS differences, before any path is built: on macOS it also makes
# Join-Path accept the Windows separators used throughout.
. (Join-Path $repoRoot 'hooks/bridge-platform.ps1')
. (Join-Path $repoRoot 'hooks/bridge-native-hook.ps1')
. (Join-Path $repoRoot 'hooks/bridge-test-guard.ps1')
. (Join-Path $repoRoot 'hooks/bridge-secrets.ps1')
# No param block of its own, so dot-sourcing it cannot rebind anything here.
. (Join-Path $repoRoot 'hooks/bridge-devbox.ps1')
$installHome = if ($TargetHome) { $TargetHome } else { $HOME }

# The VERSION file is the single source of truth, so the Apps & features entry, the
# recorded config and the update check can never disagree about what is installed.
$versionFile = Join-Path $repoRoot 'VERSION'
$version = if (Test-Path -LiteralPath $versionFile) { (Get-Content -LiteralPath $versionFile -Raw).Trim() } else { '0.0.0' }

# Whether this install came from a working copy rather than a published release.
# VERSION only moves when a release is cut, so a machine running the source and one
# running the release report the same number while being days apart - which is exactly
# how a machine came to look up to date while missing a feature entirely. The
# dashboard says "(dev)" beside the version when this is set.
#
# A release is installed from an extracted archive with no .git in it, so the presence
# of the repository is the distinction. Checked as a path rather than by running git,
# which need not be installed on a machine that only ever takes releases.
$installedFromSource = (Test-Path -LiteralPath (Join-Path $repoRoot '.git'))
# ~/.copilot belongs to the Copilot CLI: the bridge only ever writes its hook
# definition there, and reads the transcripts under session-state. Everything the
# bridge owns lives in its own root, so a Claude-, Codex- or MCP-only install never
# creates a Copilot directory.
$copilotHome = Join-Path $installHome '.copilot'
$bridgeHome = Join-Path $installHome '.agent-ha-bridge'
$hooksDir = Join-Path $bridgeHome 'hooks'
# A copy of the installer, so `agent-ha-bridge configure` works on a machine that
# never had the repository - which is every machine installed from the one-liner.
$installerDir = Join-Path $bridgeHome 'installer'
$binDir = Join-Path $bridgeHome 'bin'
$configPath = Join-Path $bridgeHome 'config.json'
$hookConfigPath = Join-Path $copilotHome 'hooks\decision-notifier.json'
# Copilot reads $HOME/.copilot/instructions/**/*.instructions.md, so the bridge owns one
# file in there rather than editing the user's own copilot-instructions.md beside it.
# An agent that drives the bridge is usually working in some unrelated repository and
# never sees this repository's AGENTS.md, which is where the rules used to live only.
$agentInstructionsPath = Join-Path $copilotHome 'instructions\agent-ha-bridge.instructions.md'
$taskName = 'AgentBridgeDaemon'
# Separate from the daemon task because it has a different life: it fires on a timer
# rather than staying resident, and it exists only on a Dev Box that opted in.
$devBoxTaskName = 'AgentBridgeDevBoxKeepAwake'
# The macOS counterpart of the scheduled task.
$launchAgentLabel = 'com.agent-ha-bridge.daemon'
$launchAgentPath = Join-Path $installHome "Library/LaunchAgents/$launchAgentLabel.plist"
# A sandbox install must not collide with the real Add/Remove Programs entry.
$arpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AgentHaBridge' +
          $(if ($TargetHome) { "_Sandbox$testRegistrySuffix" } else { '' })

# Pre-rename locations, still cleaned up on upgrade.
$legacySkillDir = Join-Path $copilotHome 'skills\decision-notifier'
$legacyHooksDir = Join-Path $copilotHome 'hooks'
$legacyConfigPath = Join-Path $copilotHome 'copilot-ha-bridge.config.json'
$legacyBridgeHome = Join-Path $copilotHome 'copilot-ha-bridge'
$legacyTaskName = 'CopilotBridgeDaemon'
$legacyArpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\CopilotHaBridge' +
                $(if ($TargetHome) { "_Sandbox$testRegistrySuffix" } else { '' })

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }

# ------------------------------------------------------------------ prompting
# Everything that reads from the user goes through these, so the phrasing is uniform
# and a non-interactive run has exactly one place that can ever block.

function Read-BridgeYesNo {
    <# A yes/no prompt that accepts Enter as the default. #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [bool]$Default = $true
    )
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = Read-Host "$Prompt $suffix"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        switch -Regex ($answer.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$'  { return $false }
            default     { Write-Host '    Please answer y or n.' -ForegroundColor DarkGray }
        }
    }
}

function Test-BridgeConsoleInteractive {
    <#
        Whether there is a person at the keyboard.

        Read-Host reads piped input perfectly happily, which is what makes the
        installer's prompts testable - but it also means a scripted run must not be
        offered things only a human can act on, like a browser window.
    #>
    try { return -not [Console]::IsInputRedirected }
    catch { return $false }
}

# --------------------------------------------------------------- dependencies
# The installer used to stop dead on a missing prerequisite, which is a poor first
# impression on a fresh machine. Everything it knows how to install lives in this
# catalogue, so a missing dependency becomes an offer instead of an error and the
# exact command is a single testable lookup.
$script:BridgeDependencies = [ordered]@{
    pwsh = [ordered]@{
        Label   = 'PowerShell 7'
        Manager = 'winget'
        Package = 'Microsoft.PowerShell'
        Why     = 'every bridge script and hook runs under pwsh'
    }
    node = [ordered]@{
        Label   = 'Node.js (LTS)'
        Manager = 'winget'
        Package = 'OpenJS.NodeJS.LTS'
        Why     = 'npm installs the agent CLIs, and the MCP server is a Node process'
    }
    copilot = [ordered]@{
        Label   = 'GitHub Copilot CLI'
        Manager = 'npm'
        Package = '@github/copilot'
        Why     = ''
    }
    claude = [ordered]@{
        Label   = 'Claude Code'
        Manager = 'npm'
        Package = '@anthropic-ai/claude-code'
        Why     = ''
    }
    codex = [ordered]@{
        Label   = 'OpenAI Codex CLI'
        Manager = 'npm'
        Package = '@openai/codex'
        Why     = ''
    }
    tmux = [ordered]@{
        Label   = 'tmux'
        Manager = 'brew'
        Package = 'tmux'
        Why     = 'on macOS each session runs in tmux, which is how replies from the dashboard reach it'
    }
}
# macOS installs through Homebrew what Windows installs through winget - or, on an
# Intel Mac, which Homebrew no longer supports, through MacPorts.
if (-not $script:BridgeIsWindows) {
    # MacPorts' folder, so the checks below - and anything it installs - are found.
    if ([IO.Directory]::Exists('/opt/local/bin') -and (($env:PATH -split ':') -notcontains '/opt/local/bin')) {
        $env:PATH = "$env:PATH`:/opt/local/bin"
    }
    $useMacPorts = -not (Get-Command brew -ErrorAction SilentlyContinue) -and
        ((Get-Command port -ErrorAction SilentlyContinue) -or [IO.File]::Exists('/opt/local/bin/port'))
    if ($useMacPorts) {
        $script:BridgeDependencies.pwsh.Manager = 'port'
        $script:BridgeDependencies.pwsh.Package = 'powershell'
        $script:BridgeDependencies.node.Manager = 'port'
        $script:BridgeDependencies.node.Package = 'nodejs22 npm10'
        $script:BridgeDependencies.tmux.Manager = 'port'
    }
    else {
        $script:BridgeDependencies.pwsh.Manager = 'brew'
        $script:BridgeDependencies.pwsh.Package = 'powershell'
        $script:BridgeDependencies.node.Manager = 'brew'
        $script:BridgeDependencies.node.Package = 'node'
    }
}

# Whether `npm install -g` has to be elevated, worked out once and cached. $null until
# asked, because npm may not be installed yet when the catalogue above is built.
$script:BridgeNpmNeedsSudo = $null

function Test-BridgeNpmNeedsSudo {
    <#
        Whether npm's global folder needs root to write to.

        On an Intel Mac, Node and npm come from MacPorts, whose global folder is
        /opt/local/lib/node_modules - owned by root. Every `npm install -g` therefore
        died with "EACCES: permission denied, mkdir '/opt/local/lib/node_modules/...'",
        and the advice printed afterwards was the same command that had just failed.
        Homebrew's prefix is owned by the user, and Windows keeps global packages under
        the profile, so neither needs this.

        Decided by trying to create a folder rather than by reading ownership: the
        question is only ever "can this user write here", and a probe answers it
        without having to reason about groups, ACLs or who owns what.
    #>
    # Cache first, so this is the seam a test can set on any platform.
    if ($null -ne $script:BridgeNpmNeedsSudo) { return $script:BridgeNpmNeedsSudo }
    if ($script:BridgeIsWindows) { $script:BridgeNpmNeedsSudo = $false; return $false }

    $needs = $false
    try {
        $prefix = ([string](& npm prefix -g 2>$null | Select-Object -First 1)).Trim()
        if ($prefix) {
            # npm creates the leaf itself, so the nearest folder that exists is the one
            # that has to be writable.
            $dir = Join-Path $prefix 'lib/node_modules'
            while ($dir -and -not [IO.Directory]::Exists($dir)) {
                $parent = Split-Path -Parent $dir
                if ($parent -eq $dir) { break }
                $dir = $parent
            }
            if ($dir -and [IO.Directory]::Exists($dir)) {
                $probe = Join-Path $dir (".agent-ha-bridge-probe-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
                try {
                    New-Item -ItemType Directory -Path $probe -ErrorAction Stop | Out-Null
                    Remove-Item -LiteralPath $probe -Force -Recurse -ErrorAction SilentlyContinue
                }
                catch { $needs = $true }
            }
        }
    }
    catch { }

    $script:BridgeNpmNeedsSudo = $needs
    $needs
}

function Get-BridgeNpmPath {
    <#
        npm's full path, because sudo does not keep the PATH that found it.

        `sudo npm` answers "sudo: npm: command not found" on a MacPorts Mac: sudo
        resets the environment, and the PATH it substitutes does not include
        /opt/local/bin. Only an absolute path survives that.
    #>
    $command = Get-Command npm -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.Source) { return [string]$command.Source }
    foreach ($candidate in @('/opt/local/bin/npm', '/opt/homebrew/bin/npm', '/usr/local/bin/npm')) {
        if ([IO.File]::Exists($candidate)) { return $candidate }
    }
    'npm'
}

function Get-BridgeDependencyCommand {
    <# The exact command line that installs a dependency. #>
    param([Parameter(Mandatory)][string]$Name)

    $dep = $script:BridgeDependencies[$Name]
    if (-not $dep) { throw "Unknown dependency '$Name'. Known: $(($script:BridgeDependencies.Keys) -join ', ')." }
    switch ($dep.Manager) {
        'winget' {
            return ("winget install --id $($dep.Package) --source winget --exact " +
                    '--accept-package-agreements --accept-source-agreements')
        }
        'npm' {
            if (Test-BridgeNpmNeedsSudo) {
                $npm = Get-BridgeNpmPath
                # Elevating only ever happens on macOS, where this path is POSIX, so the
                # folder is taken by splitting on '/': Split-Path would answer with the
                # host's own separator instead.
                $binDir = if ($npm -match '^(.*)/[^/]+$') { $Matches[1] } else { '/usr/local/bin' }
                # -H so npm caches as root rather than leaving root-owned files in the
                # user's own ~/.npm, which would break their next unelevated npm; npm by
                # full path, because sudo drops the PATH that found it; and `env PATH=`
                # carrying node's own folder, because a package whose postinstall shells
                # out to node - Claude Code's runs `node install.cjs` - otherwise fails
                # with "sh: node: command not found" after npm has already unpacked it.
                return ("sudo -H env PATH=${binDir}:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin " +
                        "$npm install -g $($dep.Package)")
            }
            return "npm install -g $($dep.Package)"
        }
        'brew' { return "brew install $($dep.Package)" }
        # MacPorts installs system-wide, so it asks for the Mac's password.
        'port' { return "sudo port -N install $($dep.Package)" }
        default { throw "Unknown package manager '$($dep.Manager)' for '$Name'." }
    }
}

function Update-BridgeSessionPath {
    <#
        winget and npm update the stored PATH, not this process's copy of it, so a
        dependency installed a moment ago is invisible until the next terminal. Merge
        the stored value in so the rest of the install can use what it just installed,
        without discarding anything this shell had of its own.
    #>
    # macOS has no stored PATH to merge (and separates entries with ':'); Homebrew's
    # folder is added instead, so something brew just installed is found.
    if (-not $script:BridgeIsWindows) {
        foreach ($dir in @('/opt/homebrew/bin', '/usr/local/bin', '/opt/local/bin')) {
            if ([IO.Directory]::Exists($dir) -and (($env:PATH -split ':') -notcontains $dir)) { $env:PATH = "$env:PATH`:$dir" }
        }
        return
    }
    try {
        $seen = @{}
        $merged = @()
        foreach ($source in @(
            $env:PATH,
            [Environment]::GetEnvironmentVariable('Path', 'Machine'),
            [Environment]::GetEnvironmentVariable('Path', 'User')
        )) {
            foreach ($entry in (([string]$source) -split ';')) {
                if ([string]::IsNullOrWhiteSpace($entry)) { continue }
                $key = ConvertTo-BridgePathKey $entry
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                $merged += $entry
            }
        }
        if ($merged) { $env:PATH = $merged -join ';' }
    }
    catch { }
}

function ConvertTo-BridgeArgumentList {
    <#
        Rebuilds a command-line argument list from bound parameters, so the installer
        can relaunch itself under PowerShell 7 with the options it was given.

        Secrets are never forwarded - a command line is readable by every process on
        the machine - so the caller refuses the relaunch when a token was passed
        rather than this quietly leaking one.
    #>
    param([Parameter(Mandatory)][hashtable]$BoundParameters, [string[]]$Exclude = @())

    $list = @()
    foreach ($name in $BoundParameters.Keys) {
        if ($Exclude -contains $name) { continue }
        $value = $BoundParameters[$name]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { $list += "-$name" }
            continue
        }
        if ($null -eq $value) { continue }
        $joined = (@($value) | ForEach-Object { [string]$_ }) -join ','
        if ([string]::IsNullOrWhiteSpace($joined)) { continue }
        $list += "-$name"
        $list += $joined
    }
    $list
}

function Test-BridgeDependencyInstalled {
    <# Whether a catalogue entry is already satisfied. #>
    param([Parameter(Mandatory)][string]$Name)
    switch ($Name) {
        'pwsh' { return [bool](Get-BridgePwshPath) }
        'node' { return [bool](Get-Command npm -ErrorAction SilentlyContinue) }
        'tmux' { return [bool](Get-BridgeTmuxPath) }
        default { return [bool](Test-BridgeClientInstalled $Name) }
    }
}

function Invoke-BridgeInstallCommand {
    <#
        Runs an install command line, echoing its output rather than returning it, so
        the caller gets a clean boolean and the user still sees the progress.
    #>
    param([Parameter(Mandatory)][string]$Command)

    $parts = @($Command -split '\s+' | Where-Object { $_ })
    $exe = $parts[0]
    $rest = @()
    if ($parts.Count -gt 1) { $rest = $parts[1..($parts.Count - 1)] }

    $global:LASTEXITCODE = 0
    & $exe @rest 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    return ($LASTEXITCODE -eq 0)
}

function Request-BridgeDependency {
    <#
        Offers to install a missing dependency, and reports what happened as one of
        Present, Installed, Declined, Failed, Unavailable or Skipped.

        -Probe, -Ask, -Runner and -ManagerProbe are injectable, so the whole decision
        can be tested without a package manager ever running.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [scriptblock]$Probe,
        [scriptblock]$Ask,
        [scriptblock]$Runner,
        [scriptblock]$ManagerProbe,
        [switch]$NonInteractive
    )

    $dep = $script:BridgeDependencies[$Name]
    if (-not $dep) { throw "Unknown dependency '$Name'. Known: $(($script:BridgeDependencies.Keys) -join ', ')." }
    if (-not $Probe)        { $Probe        = { param($n) Test-BridgeDependencyInstalled $n } }
    if (-not $Ask)          { $Ask          = { param($p) Read-BridgeYesNo -Prompt $p } }
    if (-not $Runner)       { $Runner       = { param($c) Invoke-BridgeInstallCommand -Command $c } }
    if (-not $ManagerProbe) { $ManagerProbe = { param($m) [bool](Get-Command $m -ErrorAction SilentlyContinue) } }

    if (& $Probe $Name) { return 'Present' }

    $command = Get-BridgeDependencyCommand -Name $Name

    if ($NonInteractive) {
        Write-Warning "$($dep.Label) is not installed. Install it with: $command"
        return 'Skipped'
    }
    if (-not (& $ManagerProbe $dep.Manager)) {
        Write-Warning ("$($dep.Label) is missing and $($dep.Manager) is not available to install it. " +
                       "Install it yourself with: $command")
        return 'Unavailable'
    }

    Write-Host ''
    Write-Host "$($dep.Label) is not installed." -ForegroundColor Yellow
    if ($dep.Why) { Write-Host "    $($dep.Why)" -ForegroundColor DarkGray }
    Write-Host "    $command" -ForegroundColor DarkGray
    if (-not (& $Ask "    Install $($dep.Label) now?")) {
        Write-Host "    skipped - install it later with: $command" -ForegroundColor DarkGray
        return 'Declined'
    }

    Write-Step "Installing $($dep.Label)"
    $ok = $false
    try { $ok = [bool](& $Runner $command) }
    catch { Write-Warning $_.Exception.Message; $ok = $false }

    if (-not $ok) {
        Write-Warning "$($dep.Label) did not install cleanly. Install it with: $command"
        return 'Failed'
    }

    Update-BridgeSessionPath
    if (& $Probe $Name) { Write-Host "    $($dep.Label) installed" -ForegroundColor Green }
    else {
        Write-Host ("    $($dep.Label) installed, but it is not on this shell's PATH yet - " +
                    'open a new terminal to use it.') -ForegroundColor Yellow
    }
    return 'Installed'
}

# ------------------------------------------------------------------ user PATH
# So that `agent-ha-bridge` works from any terminal, which is also how you
# reconfigure an install whose clone is long gone.

function ConvertTo-BridgePathKey {
    <# Comparison form for a PATH entry: unquoted, trailing separator and case dropped. #>
    param([AllowEmptyString()][AllowNull()][string]$Path)
    ([string]$Path).Trim().Trim('"').TrimEnd('\', '/').ToLowerInvariant()
}

function Add-BridgePathEntry {
    <#
        $Current with $Directory appended, or $null when it is already present.

        The existing value is preserved character for character - empty segments and
        all - because the uninstaller has to be able to put it back exactly as it was.
        A new entry goes in before any trailing separator, so a PATH written as
        "a;b;" stays that shape rather than growing a ";;".

        Pure, so the quoting, separator and duplicate handling are testable without
        touching the real PATH.
    #>
    param(
        [AllowEmptyString()][AllowNull()][string]$Current,
        [Parameter(Mandatory)][string]$Directory
    )
    $target = ConvertTo-BridgePathKey $Directory
    $segments = @(([string]$Current) -split ';')
    foreach ($entry in $segments) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        if ((ConvertTo-BridgePathKey $entry) -eq $target) { return $null }
    }
    if ([string]::IsNullOrWhiteSpace($Current)) { return $Directory }

    $insertAt = $segments.Count
    while ($insertAt -gt 0 -and [string]::IsNullOrWhiteSpace($segments[$insertAt - 1])) { $insertAt-- }

    $updated = @()
    if ($insertAt -gt 0) { $updated += $segments[0..($insertAt - 1)] }
    $updated += $Directory
    if ($insertAt -lt $segments.Count) { $updated += $segments[$insertAt..($segments.Count - 1)] }
    $updated -join ';'
}

function Remove-BridgePathEntry {
    <#
        $Current without $Directory, or $null when it was not there to begin with.
        Everything else is kept verbatim, so add-then-remove is an exact round trip.
    #>
    param(
        [AllowEmptyString()][AllowNull()][string]$Current,
        [Parameter(Mandatory)][string]$Directory
    )
    $target = ConvertTo-BridgePathKey $Directory
    $segments = @(([string]$Current) -split ';')
    $kept = @($segments | Where-Object {
        [string]::IsNullOrWhiteSpace($_) -or (ConvertTo-BridgePathKey $_) -ne $target
    })
    if ($kept.Count -eq $segments.Count) { return $null }
    $kept -join ';'
}

function Get-BridgeUserPath {
    <#
        The user PATH exactly as stored, unexpanded.

        [Environment]::GetEnvironmentVariable would hand back an expanded copy, and
        writing that back turns a REG_EXPAND_SZ PATH into a literal one - baking
        today's %USERPROFILE% into every entry that used it. Reading through the
        registry keeps the raw value intact.
    #>
    try {
        $key = Get-Item -LiteralPath 'HKCU:\Environment' -ErrorAction Stop
        return [string]$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    }
    catch { return '' }
}

function Set-BridgeUserPath {
    <# Writes the user PATH back, preserving whether it expands environment variables. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $kind = 'ExpandString'
    try {
        $key = Get-Item -LiteralPath 'HKCU:\Environment' -ErrorAction Stop
        if ($key.GetValueNames() -contains 'Path') { $kind = [string]$key.GetValueKind('Path') }
    }
    catch { }
    $type = if ($kind -eq 'String') { 'String' } else { 'ExpandString' }
    Set-ItemProperty -LiteralPath 'HKCU:\Environment' -Name 'Path' -Value $Value -Type $type
}

function Send-BridgeEnvironmentChange {
    <#
        Tells Explorer the environment changed, so a terminal opened afterwards sees
        the new PATH instead of needing a sign-out. Best-effort: a failure here only
        costs the user a new shell.
    #>
    try {
        if (-not ('BridgeNativeEnv' -as [type])) {
            Add-Type -Namespace '' -Name 'BridgeNativeEnv' -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg,
    System.IntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
'@ -ErrorAction Stop
        }
        $result = [UIntPtr]::Zero
        # HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG, 5s.
        [void][BridgeNativeEnv]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [IntPtr]::Zero,
            'Environment', 0x2, 5000, [ref]$result)
    }
    catch { }
}

function Register-BridgePathEntry {
    <#
        Adds (or with -Remove, drops) a directory on the user PATH and reports whether
        anything changed. -Getter and -Setter are injectable so a test can exercise the
        whole path without touching the real environment.
    #>
    param(
        [Parameter(Mandatory)][string]$Directory,
        [scriptblock]$Getter,
        [scriptblock]$Setter,
        [switch]$Remove
    )
    if (-not $Getter) { $Getter = { Get-BridgeUserPath } }
    if (-not $Setter) { $Setter = { param($v) Set-BridgeUserPath -Value $v } }

    $current = [string](& $Getter)
    $updated = if ($Remove) { Remove-BridgePathEntry -Current $current -Directory $Directory }
               else { Add-BridgePathEntry -Current $current -Directory $Directory }
    if ($null -eq $updated) { return $false }

    & $Setter $updated
    return $true
}

function Merge-BridgeConfigDefaults {
    <#
        Fills in whatever a config is missing from the shipped example, and returns the
        names of the keys it added.

        A config written by an older version does not have every key a newer installer
        expects, and the installer reaches straight into them: `$config.notifications
        .enabled` against a config with no notifications section is a crash several
        steps into an upgrade, with the config already backed up and half the install
        done. Only absent - or explicitly null - keys are filled; anything already set
        is left exactly as it is.

        One level of nesting is enough: every section in config.example.json is flat.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Defaults
    )

    $added = @()
    foreach ($property in $Defaults.PSObject.Properties) {
        $name = $property.Name
        $existing = $null
        if ($Config.PSObject.Properties[$name]) { $existing = $Config.$name }

        if (-not $Config.PSObject.Properties[$name] -or $null -eq $existing) {
            $Config | Add-Member -NotePropertyName $name -NotePropertyValue $property.Value -Force
            $added += $name
            continue
        }
        if ($existing -is [psobject] -and $property.Value -is [psobject] -and
            $existing -isnot [array] -and $property.Value -isnot [array]) {
            foreach ($child in $property.Value.PSObject.Properties) {
                if (-not $existing.PSObject.Properties[$child.Name]) {
                    $existing | Add-Member -NotePropertyName $child.Name -NotePropertyValue $child.Value -Force
                    $added += "$name.$($child.Name)"
                }
            }
        }
    }
    $added
}

function Read-BridgeConfigFile {
    <#
        Reads a config, or reports that it could not be read.

        A hand-edited config with a stray comma used to end the install on a raw JSON
        parser error, which says nothing about what to do next. The file is always
        backed up first, so falling back to the defaults loses nothing that cannot be
        recovered from the .bak.
    #>
    param([Parameter(Mandatory)][string]$Path)

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return [pscustomobject]@{ Config = $null; Error = 'the file is empty' }
        }
        return [pscustomobject]@{ Config = ($raw | ConvertFrom-Json); Error = '' }
    }
    catch {
        return [pscustomobject]@{ Config = $null; Error = 'the file could not be read as valid JSON; check its syntax and permissions' }
    }
}

# ------------------------------------------------------- Home Assistant check

function Get-BridgeHttpErrorDetail {
    <# Turns a failed Invoke-RestMethod into something worth showing a user. #>
    param([Parameter(Mandatory)]$ErrorRecord)

    $status = $null
    try { $status = [int]$ErrorRecord.Exception.Response.StatusCode } catch { }
    switch ($status) {
        401 { return 'the token was rejected (401 Unauthorized) - it may be mistyped, or created on a different Home Assistant' }
        403 { return 'access was refused (403 Forbidden)' }
        404 { return 'no Home Assistant API at that URL (404) - check the port and any path prefix' }
        default {
            if ($status -ge 300 -and $status -lt 400) {
                return "HTTP $status redirect refused; configure the intended Home Assistant URL explicitly"
            }
            if ($status) { return "HTTP $status; check the configured Home Assistant endpoint" }
            return 'request failed; check the configured URL, DNS, TLS certificate, and connectivity'
        }
    }
}

function Test-BridgeHomeAssistantConnection {
    <#
        Confirms that a URL and token really do talk to Home Assistant, and reports
        enough to show the user what they just connected to.

        Connection failures return an object, so the caller can offer another go at
        the token. A violated offline-test boundary throws instead.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$BaseUrl,
        [AllowEmptyString()][AllowNull()][string]$Token,
        [int]$TimeoutSec = 15
    )

    $base = ([string]$BaseUrl).TrimEnd('/')
    $result = [pscustomobject]@{
        Ok           = $false
        BaseUrl      = ''
        Message      = ''
        Version      = ''
        LocationName = ''
        MqttPublish  = $false
        Error        = ''
    }
    if ([string]::IsNullOrWhiteSpace($base)) { $result.Error = 'no Home Assistant URL'; return $result }
    if (-not [string]::IsNullOrWhiteSpace($Token)) { Assert-BridgeHttpAllowed -Uri "$base/api/" }
    try { $base = ConvertTo-BridgeHomeAssistantUrl -Value $base }
    catch {
        $result.BaseUrl = ''
        $result.Error = 'invalid Home Assistant URL; use HTTP(S) without user info, a query, or a fragment'
        return $result
    }
    $result.BaseUrl = $base
    if ([string]::IsNullOrWhiteSpace($Token)) { $result.Error = 'no Home Assistant token'; return $result }
    $headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' }
    try {
        $api = Invoke-RestMethod -Uri "$base/api/" -Headers $headers -TimeoutSec $TimeoutSec -MaximumRedirection 0
        $result.Message = [string]$api.message
        $result.Ok = $true
    }
    catch {
        $result.Error = Get-BridgeHttpErrorDetail -ErrorRecord $_
        return $result
    }

    # Cosmetic, but it is what turns "it worked" into "it worked, and this is the
    # Home Assistant you are now attached to".
    Assert-BridgeHttpAllowed -Uri "$base/api/config"
    try {
        $haConfig = Invoke-RestMethod -Uri "$base/api/config" -Headers $headers -TimeoutSec $TimeoutSec -MaximumRedirection 0
        $result.Version = [string]$haConfig.version
        $result.LocationName = [string]$haConfig.location_name
    }
    catch { }

    # The MQTT integration is the one prerequisite the bridge cannot provision itself:
    # every per-session entity is published through the mqtt.publish service.
    Assert-BridgeHttpAllowed -Uri "$base/api/services"
    try {
        $services = Invoke-RestMethod -Uri "$base/api/services" -Headers $headers -TimeoutSec ($TimeoutSec + 5) -MaximumRedirection 0
        $mqtt = @($services) | Where-Object { $_.domain -eq 'mqtt' }
        $result.MqttPublish = [bool]($mqtt -and ($mqtt.services.PSObject.Properties.Name -contains 'publish'))
    }
    catch { }

    $result
}

function Get-BridgeHomeAssistantUser {
    <#
        Which Home Assistant account a token belongs to.

        This is what makes an agent identity configurable rather than transcribed.
        The user id is otherwise copied by hand out of a Settings URL, and the obvious
        shortcut - reading it off the token - is a trap: a long-lived token is a JWT
        whose `iss` claim looks exactly like a user id but is the *refresh token's*
        id, so using it means nothing is ever marked and nothing ever says why.
        `auth/current_user` answers it properly, from the account the token actually
        authenticates as.

        WebSocket rather than REST because Home Assistant offers this nowhere else.
        Connection failures return an object: a rejected token is an ordinary
        outcome here - it is exactly what a revoked or half-pasted one looks like -
        and the caller offers another go. Test-boundary violations still throw.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$BaseUrl,
        [AllowEmptyString()][AllowNull()][string]$Token,
        [int]$TimeoutSec = 20
    )

    $result = [pscustomobject]@{ Ok = $false; Id = ''; Name = ''; IsAdmin = $false; Rejected = $false; Error = '' }
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $result.Error = 'no Home Assistant URL'; return $result }
    if ([string]::IsNullOrWhiteSpace($Token)) { $result.Error = 'no token'; return $result }

    Assert-BridgeHttpAllowed -Uri "$(([string]$BaseUrl).TrimEnd('/') -replace '^http', 'ws')/api/websocket" -Transport WebSocket
    try { $base = ConvertTo-BridgeHomeAssistantUrl -Value $BaseUrl }
    catch { $result.Error = 'invalid Home Assistant URL'; return $result }
    $wsUrl = ($base -replace '^http', 'ws') + '/api/websocket'
    $ws = $null
    $cancel = $null
    $invoker = $null
    try {
        # Older runtimes cannot disable WebSocket redirects. Refuse account lookup
        # there rather than authenticate a redirected socket with a saved credential.
        $connect = [Net.WebSockets.ClientWebSocket].GetMethod('ConnectAsync',
            [type[]]@([Uri], [Net.Http.HttpMessageInvoker], [Threading.CancellationToken]))
        if (-not $connect) {
            $result.Error = 'secure account verification requires PowerShell 7.3 or newer; update PowerShell and retry'
            return $result
        }
        $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))
        $ws = [System.Net.WebSockets.ClientWebSocket]::new()
        $handler = [Net.Http.SocketsHttpHandler]::new()
        $handler.AllowAutoRedirect = $false
        $invoker = [Net.Http.HttpMessageInvoker]::new($handler)
        $ws.ConnectAsync([Uri]$wsUrl, $invoker, $cancel.Token).GetAwaiter().GetResult()

        $buffer = [byte[]]::new(65536)
        # Scriptblocks, not nested functions: a function declared inside a function is
        # defined in that scope every call, and PowerShell has been known to lose its
        # footing over it in odd ways.
        $receive = {
            $segment = [ArraySegment[byte]]::new($buffer)
            $got = $ws.ReceiveAsync($segment, $cancel.Token).GetAwaiter().GetResult()
            [Text.Encoding]::UTF8.GetString($buffer, 0, $got.Count)
        }
        $send = {
            param($Message)
            $bytes = [Text.Encoding]::UTF8.GetBytes($Message)
            $ws.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, $cancel.Token).Wait()
        }

        [void](& $receive)   # auth_required
        & $send (@{ type = 'auth'; access_token = $Token } | ConvertTo-Json -Compress)
        $auth = (& $receive) | ConvertFrom-Json
        if ([string]$auth.type -ne 'auth_ok') {
            # Home Assistant answered and said no. Worth separating from "could not
            # ask": one means the token is bad, the other means the network is, and
            # only the first justifies telling someone their token is no good.
            $result.Rejected = $true
            $result.Error = 'Home Assistant rejected the token'
            return $result
        }

        & $send (@{ id = 1; type = 'auth/current_user' } | ConvertTo-Json -Compress)
        $answer = (& $receive) | ConvertFrom-Json
        if (-not $answer.success) { $result.Error = 'Home Assistant would not say who the token belongs to'; return $result }

        $result.Id = [string]$answer.result.id
        $result.Name = [string]$answer.result.name
        $result.IsAdmin = [bool]$answer.result.is_admin
        $result.Ok = -not [string]::IsNullOrWhiteSpace($result.Id)
        if (-not $result.Ok) { $result.Error = 'Home Assistant returned no user id' }
        $result
    }
    catch {
        $result.Error = 'account lookup failed; check the configured URL, DNS, TLS certificate, and connectivity; redirects are not followed'
        $result
    }
    finally {
        if ($ws) { $ws.Dispose() }
        if ($invoker) { $invoker.Dispose() }
        if ($cancel) { $cancel.Dispose() }
    }
}

function Resolve-BridgeAgentIdentity {
    <#
        What to do with a candidate agent token: store it, or refuse it and say why.

        Split out of the install flow so the decision is testable on its own. The two
        refusals are the point of it, because both fail *silently* if simply stored -
        the dashboard marks nothing, forever, with no error anywhere:

          * a token Home Assistant rejects, which is what a revoked or half-pasted one
            looks like (this machine had one saved from a previous attempt that had
            since stopped working, and nothing ever said so);
          * a token belonging to your own account, which authenticates perfectly and
            is indistinguishable from you by construction - the whole feature rests on
            the two being different accounts.

        On success it also carries the user id read back off the token, so the caller
        never has to ask anyone to copy one.

        -Lookup is the seam: it takes a URL and a token and answers like
        Get-BridgeHomeAssistantUser.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$BaseUrl,
        [AllowEmptyString()][AllowNull()][string]$AgentToken,
        [AllowEmptyString()][AllowNull()][string]$OwnToken,
        [switch]$EnvironmentOnly,
        [scriptblock]$Lookup = $null
    )

    if (-not $Lookup) { $Lookup = { param($Url, $Tok) Get-BridgeHomeAssistantUser -BaseUrl $Url -Token $Tok } }

    $result = [pscustomobject]@{
        Store = $false; Token = ''; UserId = ''; Name = ''; IsAdmin = $false; Warning = ''
    }
    if ([string]::IsNullOrWhiteSpace($AgentToken)) { return $result }

    $agent = & $Lookup $BaseUrl $AgentToken
    if (-not $agent.Ok) {
        $rejected = $agent.PSObject.Properties['Rejected'] -and $agent.Rejected
        $result.Warning = if ($rejected) {
            "The agent token was not accepted ($($agent.Error)), so it has not been saved. " +
            'Create a fresh one on that account and re-run with -AgentToken.'
        }
        else {
            # The network, not the token. Saying "your token is no good" here would be
            # a guess, and a discouraging one.
            "Could not check the agent token ($($agent.Error)), so it has not been saved. Try again."
        }
        return $result
    }

    $own = & $Lookup $BaseUrl $OwnToken
    if ($own.Ok -and $agent.Id -eq $own.Id) {
        $result.Warning = "That token belongs to '$($agent.Name)' - the same account as the bridge's own token. " +
                          'An agent using it is indistinguishable from you, so it has not been saved. ' +
                          'Create a separate Home Assistant user for the agent.'
        return $result
    }

    $result.Store = $true
    $result.Token = if ($EnvironmentOnly) { '' } else { [string]$AgentToken }
    $result.UserId = [string]$agent.Id
    $result.Name = [string]$agent.Name
    $result.IsAdmin = [bool]$agent.IsAdmin
    $result
}

function Write-BridgeConnectionResult {
    <# The one place that decides how a connection attempt is reported. #>
    param([Parameter(Mandatory)]$Result)

    if (-not $Result.Ok) {
        Write-Host "    could not connect to $($Result.BaseUrl): $($Result.Error)" -ForegroundColor Red
        return
    }
    $who = @($Result.LocationName, $Result.Version) | Where-Object { $_ }
    $suffix = if ($who) { " - $($who -join ' ')" } else { '' }
    Write-Host "    connected to $($Result.BaseUrl)$suffix" -ForegroundColor Green
    if ($Result.MqttPublish) { Write-Host '    mqtt.publish available' -ForegroundColor Green }
    else {
        Write-Warning ('Home Assistant has no mqtt.publish service. Add the MQTT integration ' +
                       '(Settings > Devices & Services > Add Integration > MQTT) or the bridge ' +
                       'cannot create its entities.')
    }
}

$script:KnownClients = @('copilot', 'claude', 'codex', 'mcp')
$script:ClientLabels = [ordered]@{
    copilot = 'GitHub Copilot CLI'
    claude  = 'Claude Code'
    codex   = 'OpenAI Codex CLI'
    mcp     = 'MCP server'
}

function ConvertTo-BridgeClientList {
    <# Normalises and validates a list of client names, dropping blanks and dupes.
       Each element may itself be comma-separated, so -Clients "copilot,claude" works
       as well as -Clients copilot,claude. #>
    param([string[]]$Clients)
    $out = @()
    foreach ($raw in @($Clients)) {
        foreach ($c in (([string]$raw) -split ',')) {
            $n = ([string]$c).Trim().ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            if ($n -in @('github', 'copilot-cli', 'github-copilot')) { $n = 'copilot' }
            if ($n -in @('claude-code')) { $n = 'claude' }
            if ($n -in @('codex-cli', 'openai-codex')) { $n = 'codex' }
            if ($script:KnownClients -notcontains $n) {
                throw "Unknown client '$c'. Known clients: $($script:KnownClients -join ', ')."
            }
            if ($out -notcontains $n) { $out += $n }
        }
    }
    $out
}

function Test-BridgeClientInstalled {
    <#
        Best-effort detection so the picker can pre-select what is actually present,
        and so a re-run reinstalls what is broken.

        Presence alone is not enough. npm writes a package's `bin` entry before it
        runs the package's postinstall, so a postinstall that fails - as Claude
        Code's did on macOS whenever `node` was missing from an elevated PATH - leaves
        `claude` on PATH doing nothing. Reporting that as installed meant re-running
        the installer skipped it, and the only symptom was a session that died the
        instant it launched. So the agent CLIs have to answer --version too.
    #>
    param([Parameter(Mandatory)][string]$Client)
    switch ($Client) {
        'copilot' { [bool](Test-BridgeClientRunnable -Name 'copilot') }
        'claude'  { [bool](Test-BridgeClientRunnable -Name 'claude') }
        'codex'   {
            if (Test-BridgeClientRunnable -Name 'codex') { return $true }
            if (-not $script:BridgeIsWindows) { return $false }
            # Codex ships through npm and is not on PATH, so look where npm installs it.
            Test-Path -LiteralPath (Join-Path $env:APPDATA 'npm\node_modules\@openai\codex')
        }
        'mcp'     {
            # There is no single "MCP client", but Claude Desktop is the one this can
            # configure automatically, so its presence is the useful pre-select hint.
            if (-not $script:BridgeIsWindows) { return (Test-Path -LiteralPath (Join-Path $HOME 'Library/Application Support/Claude')) }
            Test-Path -LiteralPath (Join-Path $env:APPDATA 'Claude')
        }
        default { $false }
    }
}

function Get-BridgeDaemonProcess {
    <# The running daemon, or nothing. Same test on both platforms. #>
    @(Get-BridgeProcessesNamed -Name 'pwsh' -WithCommandLine |
        Where-Object { $_.CommandLine -match 'agent-bridge-daemon\.ps1' })
}

function Get-BridgeInstallHealth {
    <#
        The checks behind the install's closing verdict, as { Name, Ok, Detail, Fix }.

        Kept apart from the printing so the verdict can be tested without installing
        anything, and so each check is one plain fact rather than a wall of output
        nobody reads. They are deliberately the things that have actually gone wrong
        on a real machine: a daemon that never started, an agent CLI that is on PATH
        but does not run, a command the shell still cannot find.

        Every probe is injectable for the same reason.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Clients = @(),
        [scriptblock]$DaemonProbe,
        [scriptblock]$ClientProbe,
        [scriptblock]$CommandProbe,
        [scriptblock]$ConnectionProbe,
        [scriptblock]$TmuxProbe,
        [bool]$OnWindows = $script:BridgeIsWindows
    )

    if (-not $DaemonProbe)     { $DaemonProbe     = { [bool](Get-BridgeDaemonProcess) } }
    if (-not $ClientProbe)     { $ClientProbe     = { param($name) [bool](Test-BridgeClientRunnable -Name $name) } }
    if (-not $CommandProbe)    { $CommandProbe    = { [bool](Get-Command 'agent-ha-bridge' -ErrorAction SilentlyContinue) } }
    if (-not $ConnectionProbe) { $ConnectionProbe = { [pscustomobject]@{ Ok = $false; Version = ''; Error = 'not checked' } } }
    if (-not $TmuxProbe)       { $TmuxProbe       = { [bool](Get-BridgeTmuxPath) } }

    $checks = [System.Collections.Generic.List[object]]::new()

    $checks.Add([pscustomobject]@{
        Name   = 'The bridge daemon is running'
        Ok     = [bool](& $DaemonProbe)
        Detail = ''
        Fix    = 'run: agent-ha-bridge restart'
    })

    $connection = & $ConnectionProbe
    $connectionOk = [bool]($connection -and $connection.Ok)
    $checks.Add([pscustomobject]@{
        Name   = 'Home Assistant answers'
        Ok     = $connectionOk
        Detail = if ($connectionOk) { [string]$connection.Version } elseif ($connection) { [string]$connection.Error } else { 'no answer' }
        Fix    = 'run: agent-ha-bridge configure'
    })

    # 'mcp' is a client config, not a command, so there is nothing to run.
    foreach ($client in @($Clients | Where-Object { $_ -and $_ -ne 'mcp' })) {
        $label = [string]$script:BridgeDependencies[$client].Label
        if (-not $label) { $label = $client }
        $checks.Add([pscustomobject]@{
            Name   = "$label runs"
            Ok     = [bool](& $ClientProbe $client)
            Detail = ''
            Fix    = "run: agent-ha-bridge configure -Clients $client"
        })
    }

    if (-not $OnWindows) {
        $checks.Add([pscustomobject]@{
            Name   = 'tmux is installed, so replies can be typed into sessions'
            Ok     = [bool](& $TmuxProbe)
            Detail = ''
            Fix    = 'install tmux, then run: agent-ha-bridge configure'
        })
    }

    $checks.Add([pscustomobject]@{
        Name   = 'The agent-ha-bridge command is on PATH'
        Ok     = [bool](& $CommandProbe)
        Detail = ''
        Fix    = 'open a new terminal - the PATH line only applies to new ones'
    })

    @($checks)
}

function Show-BridgeInstallVerdict {
    <#
        Prints the checks and a single verdict, and says whether everything passed.

        The install used to end on a list of next steps whether or not any of it had
        worked, so "Bootstrap failed" scrolling past a working install read as a
        failure and a genuinely broken one read as a success. This says which it was.
    #>
    param([AllowEmptyCollection()]$Checks)

    Write-Host ''
    Write-Host 'Checking the install:' -ForegroundColor Cyan
    foreach ($check in @($Checks)) {
        $mark = if ($check.Ok) { '[ ok ]' } else { '[ !! ]' }
        $colour = if ($check.Ok) { 'Green' } else { 'Red' }
        $line = "  $mark $($check.Name)"
        if ($check.Detail) { $line += " - $($check.Detail)" }
        Write-Host $line -ForegroundColor $colour
    }

    $failed = @(@($Checks) | Where-Object { -not $_.Ok })
    Write-Host ''
    if ($failed.Count -eq 0) {
        Write-Host 'All good: the bridge is installed, running and connected.' -ForegroundColor Green
        return $true
    }
    $one = ($failed.Count -eq 1)
    Write-Host "$($failed.Count) thing$(if (-not $one) { 's' }) still need$(if ($one) { 's' }) attention:" -ForegroundColor Red
    foreach ($check in $failed) {
        Write-Host "  - $($check.Name) -> $($check.Fix)" -ForegroundColor Yellow
    }
    $false
}

function Test-BridgeClientRunnable {
    <# An agent CLI that is on PATH and actually runs. #>
    param([Parameter(Mandatory)][string]$Name)

    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $command -or -not $command.Source) { return $false }
    Test-BridgeCommandRuns -Executable ([string]$command.Source)
}

function Resolve-BridgeClients {
    <#
        Decides which clients to configure. An explicit -Clients wins; then a
        previously persisted selection, so a re-run or a self-update reconfigures the
        same set; then an interactive pick; and finally 'copilot' as the
        non-interactive default so an unattended install keeps working as before.
    #>
    param(
        [string[]]$Requested,
        [string[]]$Persisted,
        [switch]$NonInteractive,
        [scriptblock]$Prompt
    )
    if ($Requested)  { return @(ConvertTo-BridgeClientList $Requested) }
    if ($Persisted)  { return @(ConvertTo-BridgeClientList $Persisted) }
    if (-not $NonInteractive -and $Prompt) { return @(& $Prompt) }
    return @('copilot')
}

function Read-BridgeClientSelection {
    <# A small numbered multi-select; Enter accepts the detected default. #>
    param([string[]]$Detected)

    Write-Host ''
    Write-Host 'Which clients should the bridge configure?' -ForegroundColor Yellow
    Write-Host '(the shared daemon, dashboard and Home Assistant plumbing are always installed)' -ForegroundColor DarkGray

    $index = @{}
    $i = 1
    foreach ($c in $script:ClientLabels.Keys) {
        $mark = if ($Detected -contains $c) { ' (detected)' } else { '' }
        Write-Host ("  {0}) {1}{2}" -f $i, $script:ClientLabels[$c], $mark)
        $index["$i"] = $c
        $i++
    }
    $default = if ($Detected) { @($Detected) } else { @('copilot') }
    $defaultLabel = ($default | ForEach-Object { $script:ClientLabels[$_] }) -join ', '
    Write-Host ("Enter numbers separated by commas, or press Enter for [{0}]." -f $defaultLabel)

    $raw = Read-Host 'Clients'
    if ([string]::IsNullOrWhiteSpace($raw)) { return @($default) }

    $picked = @()
    foreach ($tok in ($raw -split '[,\s]+')) {
        $t = $tok.Trim()
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        if ($index.ContainsKey($t)) { $picked += $index[$t] }
        else {
            try { $picked += ConvertTo-BridgeClientList @($t) } catch { Write-Warning $_.Exception.Message }
        }
    }
    if (-not $picked) { return @($default) }
    @($picked | Select-Object -Unique)
}

function Test-IsHomeAssistant {
    <#
        True when the URL serves Home Assistant. manifest.json is unauthenticated and
        names the product outright, which makes it a reliable fingerprint; /api/ only
        returns a bare 401 without a token.
    #>
    param([Parameter(Mandatory)][string]$BaseUrl, [int]$TimeoutSec = 4)

    Assert-BridgeHttpAllowed -Uri "$($BaseUrl.TrimEnd('/'))/manifest.json" -Transport WebRequest
    try {
        $base = ConvertTo-BridgeHomeAssistantUrl -Value $BaseUrl
        $response = Invoke-WebRequest -Uri "$base/manifest.json" `
            -TimeoutSec $TimeoutSec -SkipHttpErrorCheck -MaximumRedirection 0 -ErrorAction Stop
        if ($response.StatusCode -ne 200) { return $false }
        $body = if ($response.Content -is [byte[]]) {
            [Text.Encoding]::UTF8.GetString($response.Content)
        } else { [string]$response.Content }
        return ($body -match '"(short_)?name"\s*:\s*"Home Assistant"')
    }
    catch { return $false }
}

function Get-BridgeHomeAssistantCandidate {
    <#
        The URLs worth probing for a Home Assistant, in the order worth trying them.

        Split out from Find-HomeAssistant because that stops at the first hit, which
        makes the list itself untestable on a network that has a Home Assistant on it.

        -Resolver is injectable so the DNS lookup can be driven from a test.
    #>
    param([scriptblock]$Resolver)

    if (-not $Resolver) {
        Assert-BridgeHttpAllowed -Uri 'homeassistant.local' -Transport Discovery
        $Resolver = {
            # [System.Net.Dns] rather than Resolve-DnsName: that cmdlet ships only with
            # Windows, so on a Mac the lookup threw and every address candidate was
            # dropped - leaving discovery with nothing but the two host names. This goes
            # through the system resolver on both, which on macOS is what answers mDNS.
            @([System.Net.Dns]::GetHostAddresses('homeassistant.local') |
                Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
                ForEach-Object { $_.IPAddressToString })
        }
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    # Home Assistant publishes itself as homeassistant.local over mDNS, which Windows
    # resolves natively; the bare hostname covers a network that does its own DNS.
    foreach ($hostName in @('homeassistant.local', 'homeassistant')) {
        $candidates.Add("http://${hostName}:8123")
    }
    try {
        foreach ($address in @(& $Resolver)) {
            if ($address) { $candidates.Add("http://${address}:8123") }
        }
    }
    catch { }
    # Home Assistant on this machine - a Docker or WSL install - is common enough to be
    # worth one probe, and it is the one case mDNS cannot help with.
    $candidates.Add('http://localhost:8123')
    # Last, because it is the least likely and a TLS handshake costs the most to fail.
    $candidates.Add('https://homeassistant.local:8123')

    @($candidates | Select-Object -Unique)
}

function Find-HomeAssistant {
    <#
        Locates Home Assistant on the local network, or returns $null.

        No subnet scanning: it is slow and looks like hostile traffic. Anything more
        exotic than the candidates above is a typed URL.
    #>
    foreach ($candidate in (Get-BridgeHomeAssistantCandidate)) {
        Write-Host "    probing $candidate" -ForegroundColor DarkGray
        if (Test-IsHomeAssistant -BaseUrl $candidate) { return $candidate }
    }
    return $null
}

function Resolve-BridgeHomeAssistantUrl {
    <#
        Settles on a Home Assistant URL, and prompts only when it has to.

        A failed probe does not authorize moving saved credentials. Discovery and a
        URL prompt are only for an unconfigured setup; -HomeAssistantUrl is the
        deliberate way to change an existing endpoint, including in automation.

        -Probe, -Discover and -Prompt are injectable so the decision is testable
        without a Home Assistant on the network.
    #>
    param(
        [AllowEmptyString()][AllowNull()][string]$Configured,
        [scriptblock]$Probe,
        [scriptblock]$Discover,
        [scriptblock]$Prompt
    )
    if (-not $Probe)    { $Probe    = { param($u) Test-IsHomeAssistant -BaseUrl $u } }
    if (-not $Discover) { $Discover = { Find-HomeAssistant } }

    $configured = ([string]$Configured).Trim().TrimEnd('/')
    if ($configured) {
        $configured = ConvertTo-BridgeHomeAssistantUrl -Value $configured
        $source = if (& $Probe $configured) { 'config' } else { 'unverified' }
        return [pscustomobject]@{ Url = $configured; Source = $source; Prompted = $false }
    }

    $found = & $Discover
    if ($found) {
        return [pscustomobject]@{ Url = (ConvertTo-BridgeHomeAssistantUrl -Value $found); Source = 'discovered'; Prompted = $false }
    }

    if (-not $Prompt) {
        return [pscustomobject]@{ Url = $configured; Source = 'unverified'; Prompted = $false }
    }
    $answer = ([string](& $Prompt $configured)).Trim().TrimEnd('/')
    if (-not $answer) { $answer = $configured }
    if ($answer) { $answer = ConvertTo-BridgeHomeAssistantUrl -Value $answer }
    [pscustomobject]@{ Url = $answer; Source = 'typed'; Prompted = $true }
}

# ------------------------------------------------------------------ migration
# Installs from before the rename kept everything in ~/.copilot. Move what the bridge
# owns into its own root, leaving the Copilot CLI's own files alone.

# Everything the bridge ever shipped into ~/.copilot/hooks, current and historical.
# Anything not on this list belongs to the Copilot CLI or another tool and is left.
$script:LegacyHookFiles = @(
    'decision-bridge-common.ps1', 'decision-mqtt.ps1', 'decision-ha-websocket.ps1',
    'decision-inject.ps1', 'bridge-adapter.ps1', 'bridge-update.ps1',
    'session-launch.ps1', 'notify-agent-response.ps1', 'notify-home-assistant.ps1',
    'route-ask-user-v3.ps1', 'VERSION',
    'copilot-bridge-daemon.ps1', 'copilot-bridge-supervisor.ps1', 'copilot-bridge-launch.vbs',
    'agent-bridge-daemon.ps1', 'agent-bridge-supervisor.ps1', 'agent-bridge-launch.vbs',
    # Retired in earlier releases; deleted rather than carried forward.
    'route-ask-user-v2.ps1', 'route-ask-user-home-assistant.ps1', 'sync-active-sessions.ps1',
    'test-decision-args.ps1', 'test-decision-retry.ps1'
)

function Get-BridgeAgentInstructions {
    <#
        What an agent driving the bridge has to know, in the form Copilot reads
        globally.

        Both rules below fail silently, which is why they are worth the context they
        cost: nothing errors, nothing is logged, and the symptom shows up somewhere the
        agent is not looking. Both were learned the hard way on 2026-09-29.

        This lives here rather than only in the repository's AGENTS.md because an agent
        driving the bridge is almost never working *in* the bridge's repository - it is
        in some unrelated project on a machine that happens to have the bridge
        installed, and it never sees that file.

        The variable name is rendered rather than fixed: Get-BridgeAgentTokenEnvironment
        exports whatever homeAssistant.agentTokenEnvVar names, so an install that has
        overridden it would otherwise be handed instructions pointing at a variable
        nothing sets. For the same reason the promise that it is *there* is only made
        when an agent token is actually configured - without one the variable is never
        exported at all, and an agent following that would send an empty bearer token.
    #>
    param(
        [string]$EnvVarName = 'AGENT_HA_AGENT_TOKEN',
        [switch]$HasAgentToken
    )

    if (-not $EnvVarName) { $EnvVarName = 'AGENT_HA_AGENT_TOKEN' }
    # Literal here-strings with a placeholder, rather than an expandable one: the text
    # is markdown full of backticks and `$env:` references, and escaping those for the
    # parser makes it unreadable and easy to break.
    $tokenRule = if ($HasAgentToken) {
        @'
A press, a reply or a launch must use `$env:__ENVVAR__`. When the bridge launched this
session that variable is already in its environment. The token in
`~/.agent-ha-bridge/config.json` under `homeAssistant.token` is the *user's*, and is
the right one for reads.
'@
    }
    else {
        @'
No agent account is configured on this machine, so there is no separate token to write
with and every action is recorded as the user. If `$env:__ENVVAR__` is set in your
environment, use it for a press, a reply or a launch; otherwise the token in
`~/.agent-ha-bridge/config.json` under `homeAssistant.token` is all there is, and it is
the user's. `agent-ha-bridge configure -AgentToken <token>` sets one up.
'@
    }

    $body = @'
# agent-ha-bridge

Installed and maintained by agent-ha-bridge. Removed when the bridge is uninstalled;
local edits are overwritten on the next install.

This machine runs a bridge that puts agent sessions on a Home Assistant dashboard. You
can drive a session - yours, or one on another machine - through its entities. Two
things about that fail silently, so they are worth knowing before you try.

## Authenticate writes as the agent

__TOKENRULE__

Both tokens authenticate and both are authorised, so using the wrong one raises no
error and writes no log line. The only symptom is that Home Assistant records the
action against the user instead of the agent, and the session card is styled as the
user's own.

## Read a session's answer from its activity sensor

`sensor.agent_bridge_<session>_activity` carries what the session said, in its
`response` attribute. `sensor.agent_bridge_<session>_status` reads `idle` when a turn
ends - but also briefly before the session starts working, and a session keeps the
*previous* turn's response while the next one starts, so an answer only counts once
that `response` has actually changed from what it was when you wrote.

Do not ask a session to answer with a persistent notification. Home Assistant does not
expose those through `GET /api/states`, so polling for a `persistent_notification.*`
entity finds nothing however long you wait, and that silence looks exactly like the
session having died.
'@

    $body.Replace('__TOKENRULE__', $tokenRule.Trim()).Replace('__ENVVAR__', $EnvVarName)
}

function Install-BridgeAgentInstructions {
    <#
        Writes the instruction file, and says whether it changed anything.

        Rewritten only when the content differs, so a re-install does not churn a file
        the CLI may be reading, and so the common case prints nothing.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$EnvVarName = 'AGENT_HA_AGENT_TOKEN',
        [switch]$HasAgentToken
    )

    $wanted = Get-BridgeAgentInstructions -EnvVarName $EnvVarName -HasAgentToken:$HasAgentToken
    if (Test-Path -LiteralPath $Path) {
        $current = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
        # Both sides normalised: Set-Content writes the platform's line ending, so a
        # file written on Windows and compared on macOS would differ every time.
        if ($null -ne $current -and ($current -replace "`r`n", "`n").Trim() -eq ($wanted -replace "`r`n", "`n").Trim()) {
            return $false
        }
    }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Set-Content -LiteralPath $Path -Value $wanted -Encoding UTF8
    $true
}

function Invoke-BridgeLayoutMigration {
    <#
        Moves a pre-rename install into ~/.agent-ha-bridge and returns whether it had
        anything to do. Safe to run repeatedly: every step is guarded on the legacy
        artefact still being there.

        Every path is a parameter rather than a script variable so a test can point the
        whole migration at a scratch directory. -SkipMachineWide leaves the scheduled
        task and running processes alone, for a sandbox install that must not disturb
        the real one.
    #>
    param(
        [Parameter(Mandatory)][string]$CopilotHome,
        [Parameter(Mandatory)][string]$BridgeHome,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$LegacyHooksDir,
        [Parameter(Mandatory)][string]$LegacyConfigPath,
        [Parameter(Mandatory)][string]$LegacyBridgeHome,
        [string]$LegacyArpKey,
        [string]$LegacyTaskName,
        [switch]$SkipMachineWide
    )

    $migrated = $false
    function Write-Once {
        if (-not $script:MigrationAnnounced) {
            Write-Step 'Migrating the pre-rename install'
            $script:MigrationAnnounced = $true
        }
    }
    $script:MigrationAnnounced = $false

    if (-not $SkipMachineWide -and $LegacyTaskName) {
        # The old daemon holds the old script paths in memory, so it has to go first:
        # otherwise it keeps rewriting the state files the new one is about to adopt.
        if (Get-ScheduledTask -TaskName $LegacyTaskName -ErrorAction SilentlyContinue) {
            Write-Once; $migrated = $true
            Stop-ScheduledTask -TaskName $LegacyTaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $LegacyTaskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "    removed the '$LegacyTaskName' scheduled task"
        }
        foreach ($proc in Get-Process pwsh -ErrorAction SilentlyContinue) {
            try {
                $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)" -ErrorAction Stop).CommandLine
                if ($cmd -match 'copilot-bridge-(daemon|supervisor)\.ps1') {
                    Write-Once; $migrated = $true
                    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                    Write-Host "    stopped the old daemon (pid $($proc.Id))"
                }
            }
            catch { }
        }
    }

    if (-not (Test-Path -LiteralPath $BridgeHome)) {
        New-Item -ItemType Directory -Path $BridgeHome -Force | Out-Null
        if (-not (Protect-BridgeSecretFile -Path $BridgeHome)) { throw 'Could not protect the bridge credential directory.' }
    }

    # The config carries the Home Assistant token, so moving it rather than rewriting
    # it from scratch is what keeps an upgrade from prompting all over again.
    if ((Test-Path -LiteralPath $LegacyConfigPath) -and -not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Once; $migrated = $true
        Copy-BridgeSecretFile -Source $LegacyConfigPath -Destination $ConfigPath
        Remove-Item -LiteralPath $LegacyConfigPath -Force
        Write-Host "    config -> $ConfigPath"
    }
    if ((Test-Path -LiteralPath "$LegacyConfigPath.bak") -and -not (Test-Path -LiteralPath "$ConfigPath.bak")) {
        Copy-BridgeSecretFile -Source "$LegacyConfigPath.bak" -Destination "$ConfigPath.bak"
        Remove-Item -LiteralPath "$LegacyConfigPath.bak" -Force
    }

    # ~/.copilot/mcp and ~/.copilot/codex-bridge are wholly the bridge's.
    foreach ($name in @('mcp', 'codex-bridge')) {
        $from = Join-Path $CopilotHome $name
        $to = Join-Path $BridgeHome $name
        if ((Test-Path -LiteralPath $from) -and -not (Test-Path -LiteralPath $to)) {
            Write-Once; $migrated = $true
            Move-Item -LiteralPath $from -Destination $to -Force
            Write-Host "    $name -> $to"
        }
    }

    if (Test-Path -LiteralPath $LegacyHooksDir) {
        $removed = 0
        foreach ($name in $script:LegacyHookFiles) {
            $path = Join-Path $LegacyHooksDir $name
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                $removed++
            }
        }
        $legacyDashboard = Join-Path $LegacyHooksDir 'dashboard'
        if (Test-Path -LiteralPath $legacyDashboard) {
            Remove-Item -LiteralPath $legacyDashboard -Recurse -Force -ErrorAction SilentlyContinue
            $removed++
        }
        if ($removed -gt 0) {
            Write-Once; $migrated = $true
            Write-Host "    removed $removed stale file(s) from $LegacyHooksDir"
        }
        # Only when the Copilot CLI has left nothing of its own behind - its hook
        # definition normally still lives here.
        if (-not (Get-ChildItem -LiteralPath $LegacyHooksDir -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $LegacyHooksDir -Force -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path -LiteralPath $LegacyBridgeHome) {
        Write-Once; $migrated = $true
        Remove-Item -LiteralPath $LegacyBridgeHome -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "    removed $LegacyBridgeHome"
    }
    if ($LegacyArpKey -and (Test-Path -LiteralPath $LegacyArpKey)) {
        Write-Once; $migrated = $true
        Remove-Item -LiteralPath $LegacyArpKey -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host '    removed the old Apps & features entry'
    }

    if ($migrated) { Write-Host '    the dashboard moves to /agent-decisions once the daemon restarts' }
    $migrated
}

function Invoke-BridgeFrontendCardCheck {
    <#
        Runs the dashboard's frontend card check, and lets it register any card that is
        downloaded but not registered.

        In a child pwsh on purpose: the check needs the runtime layer - the config
        reader, the MQTT helpers and the WebSocket client - which between them set
        script-scoped state and define several dozen functions, none of which belong in
        the installer's scope. AGENT_HA_BRIDGE_CONFIG points it at the config this
        install just wrote, so a -TargetHome sandbox checks its own settings rather
        than the real install's.

        Ordinary checker failures are reported without failing an otherwise good
        install. Test-boundary violations fail before launching the child.
    #>
    param(
        [Parameter(Mandatory)][string]$HooksDir,
        [Parameter(Mandatory)][string]$ConfigPath,
        [switch]$Register
    )

    $checker = Join-Path $HooksDir 'bridge-frontend-cards.ps1'
    if (-not (Test-Path -LiteralPath $checker)) { return $false }
    Assert-BridgeHttpAllowed -Transport ChildProcess

    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwsh)) { $pwsh = 'pwsh' }

    $previous = $env:AGENT_HA_BRIDGE_CONFIG
    $env:AGENT_HA_BRIDGE_CONFIG = $ConfigPath
    try {
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $checker)
        if ($Register) { $arguments += '-Register' }
        # Echoed rather than returned: a native child's stdout becomes this function's
        # output, so the caller's [void] would throw away everything it printed along
        # with the return value - which is the whole point of running it. Write-Host
        # rather than Out-Host, because Out-Host bypasses the streams and so cannot be
        # asserted on.
        & $pwsh @arguments 2>&1 | ForEach-Object { Write-Host $_ }
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        Write-Host "    could not check the dashboard cards: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
    finally {
        if ($null -eq $previous) { Remove-Item Env:\AGENT_HA_BRIDGE_CONFIG -ErrorAction SilentlyContinue }
        else { $env:AGENT_HA_BRIDGE_CONFIG = $previous }
    }
}

# ------------------------------------------------------- installer payload
# So that an install can be reconfigured, updated or removed from a machine that
# never had the repository - which is every machine installed from the one-liner.

# What `agent-ha-bridge configure` needs to re-run a full install. node_modules is
# excluded: the MCP installer runs npm itself, and copying it would dwarf everything
# else here.
$script:BridgePayloadFiles = @('install.ps1', 'uninstall.ps1', 'update.ps1', 'config.example.json', 'VERSION')
$script:BridgePayloadDirs = @('hooks', 'bin', 'claude', 'codex', 'mcp', 'frontend')

function Copy-BridgeInstallerPayload {
    <#
        Copies the installer next to the install it produced, and returns the number of
        items copied. The destination is cleared first so a file deleted upstream cannot
        linger and be re-run by a later `configure`.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Destination
    )

    # Run from the payload itself - `agent-ha-bridge configure`, or the daemon setting
    # up an agent installed later - the source is the destination: clearing it first
    # deleted the whole payload, the running installer included. It is already current.
    $source = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    $target = [IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')
    if ($source -ieq $target) { return @(Get-ChildItem -LiteralPath $Destination -Force).Count }

    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    $copied = 0
    foreach ($name in $script:BridgePayloadFiles) {
        $from = Join-Path $RepoRoot $name
        if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination $Destination -Force; $copied++ }
    }
    foreach ($name in $script:BridgePayloadDirs) {
        $from = Join-Path $RepoRoot $name
        if (-not (Test-Path -LiteralPath $from)) { continue }
        $to = Join-Path $Destination $name
        Copy-Item -LiteralPath $from -Destination $to -Recurse -Force `
            -Exclude @('node_modules') -ErrorAction SilentlyContinue
        $stale = Join-Path $to 'node_modules'
        if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Recurse -Force -ErrorAction SilentlyContinue }
        $copied++
    }
    $copied
}

function Install-BridgeCommand {
    <#
        Puts the `agent-ha-bridge` command in $BinDir and reports its path.

        The .cmd shim is what actually goes on PATH: a PowerShell function or a profile
        edit would only work in pwsh, and only in shells started afterwards.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$BinDir
    )

    if (-not (Test-Path -LiteralPath $BinDir)) { New-Item -ItemType Directory -Path $BinDir -Force | Out-Null }
    # macOS: a shell shim in place of the .cmd one.
    $shim = if ($script:BridgeIsWindows) { 'agent-ha-bridge.cmd' } else { 'agent-ha-bridge' }
    foreach ($name in @('agent-ha-bridge.ps1', $shim)) {
        $from = Join-Path (Join-Path $RepoRoot 'bin') $name
        if (-not (Test-Path -LiteralPath $from)) { throw "The bridge command source $from is missing." }
        Copy-Item -LiteralPath $from -Destination $BinDir -Force
    }
    $command = Join-Path $BinDir $shim
    if (-not $script:BridgeIsWindows) {
        $mode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute -bor
            [IO.UnixFileMode]::GroupRead -bor [IO.UnixFileMode]::GroupExecute -bor [IO.UnixFileMode]::OtherRead -bor [IO.UnixFileMode]::OtherExecute
        [IO.File]::SetUnixFileMode($command, $mode)
    }
    $command
}

function Get-BridgeLaunchAgentPlist {
    <#
        The LaunchAgent that runs the daemon on macOS: at login, restarted whenever it
        exits (which is how the daemon restarts itself after an update), with the PATH
        this installer ran with - a LaunchAgent otherwise gets only /usr/bin:/bin, and
        the agents, node and tmux live in Homebrew and npm folders.

        AbandonProcessGroup keeps a dashboard-started update alive while the installer
        it runs reloads this agent, which would otherwise kill the daemon's whole group.
    #>
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$PwshPath,
        [Parameter(Mandatory)][string]$DaemonPath,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$PathValue
    )
    $x = { param($s) [Security.SecurityElement]::Escape([string]$s) }
    @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$(& $x $Label)</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(& $x $PwshPath)</string>
        <string>-NoProfile</string>
        <string>-NonInteractive</string>
        <string>-File</string>
        <string>$(& $x $DaemonPath)</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>$(& $x $PathValue)</string>
        <key>DOTNET_GCConserveMemory</key><string>7</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>AbandonProcessGroup</key><true/>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>$(& $x $LogPath)</string>
    <key>StandardErrorPath</key><string>$(& $x $LogPath)</string>
</dict>
</plist>
"@
}

function Get-BridgeLaunchAgentLogPath {
    <#
        Where launchd itself writes the job's stdout and stderr.

        Not $TMPDIR. On macOS that is /var/folders/<hash>/T, launchd's own per-user
        per-session directory, and a job whose StandardOutPath lives there is rejected
        at bootstrap with "Bootstrap failed: 5: Input/output error" - launchd cannot
        open the file in the context it is bootstrapping into, and the whole daemon
        then never starts. ~/Library/Logs is the documented place for this and always
        exists for the user launchd is running the job as.
    #>
    param([string]$HomeDir = $HOME)

    $dir = Join-Path (Join-Path $HomeDir 'Library/Logs') 'agent-ha-bridge'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Join-Path $dir 'launchd.log'
}

function Register-BridgeLaunchAgent {
    <#
        Writes and (re)loads the LaunchAgent. bootout first, so an update replaces a
        running daemon rather than leaving the old version in memory.

        launchctl reports failures on stderr and in its exit code, not by throwing, so
        both are captured: a bootstrap that fails silently used to leave nothing but
        "launchd did not accept <path>", which says nothing about why. The plist is
        linted first for the same reason, and a failed bootstrap falls back to the
        older `load -w`, which still works where bootstrap refuses.
    #>
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$PlistPath,
        [Parameter(Mandatory)][string]$Content
    )
    $dir = Split-Path $PlistPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath $PlistPath -Value $Content -Encoding UTF8

    $lint = @(& plutil -lint $PlistPath 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "The LaunchAgent file is not valid: $($lint -join ' ')"
        return $false
    }

    $domain = "gui/$(& id -u)"
    & launchctl bootout "$domain/$Label" 2>$null | Out-Null
    # bootout returns before launchd has finished tearing the job down, and
    # bootstrapping a label that is still loaded fails with
    # "Bootstrap failed: 5: Input/output error". Waiting for it to actually go means
    # the normal path succeeds instead of leaning on the fallback below.
    for ($i = 0; $i -lt 20; $i++) {
        & launchctl print "$domain/$Label" *> $null
        if ($LASTEXITCODE -ne 0) { break }
        Start-Sleep -Milliseconds 100
    }

    $out = @(& launchctl bootstrap $domain $PlistPath 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) {
        # Not printed yet. bootstrap refusing a job that the older API still takes is
        # common and recoverable, and printing "Bootstrap failed: 5: Input/output
        # error" for something that then worked perfectly reads as a broken install -
        # which is exactly how it was read. Only a fallback that also fails is worth
        # showing, and then both messages are.
        $fallback = @(& launchctl load -w $PlistPath 2>&1 | ForEach-Object { [string]$_ })
        if ($LASTEXITCODE -ne 0) {
            foreach ($line in @($out + $fallback)) { Write-Host "    $line" -ForegroundColor DarkGray }
        }
    }
    & launchctl kickstart -k "$domain/$Label" 2>&1 | Out-Null
    [bool](& launchctl print "$domain/$Label" 2>$null)
}

function Get-BridgeShellProfile {
    <#
        The profile files a login shell will actually read, for putting a folder on PATH.

        ~/.zprofile covers zsh, the default since Catalina. bash is the awkward one: it
        reads the FIRST of ~/.bash_profile, ~/.bash_login and ~/.profile and ignores the
        rest, so creating ~/.bash_profile when someone only has ~/.profile would orphan
        whatever is already in it - MacPorts puts its own PATH line there. The one that
        exists is appended to instead, and a new ~/.bash_profile written only when there
        is none at all.

        Before this, ~/.bash_profile was written only if it already existed, so anyone
        whose shell is bash got the line in ~/.zprofile alone - a file bash never reads
        - and `agent-ha-bridge` stayed "command not found" however many terminals they
        opened.
    #>
    param([string]$HomeDir = $HOME, [AllowEmptyString()][AllowNull()][string]$Shell = $env:SHELL)

    $files = [System.Collections.Generic.List[string]]::new()
    $files.Add((Join-Path $HomeDir '.zprofile'))

    $usesBash = ([string]$Shell) -match 'bash' -or
        (Test-Path -LiteralPath (Join-Path $HomeDir '.bash_profile')) -or
        (Test-Path -LiteralPath (Join-Path $HomeDir '.bash_login'))
    if ($usesBash) {
        $first = @('.bash_profile', '.bash_login', '.profile') |
            ForEach-Object { Join-Path $HomeDir $_ } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if (-not $first) { $first = Join-Path $HomeDir '.bash_profile' }
        $files.Add($first)
    }

    @($files | Select-Object -Unique)
}

function Register-BridgeShellPath {
    <#
        macOS: puts $Directory on PATH for new terminals, through whichever profile
        files the login shell reads (Get-BridgeShellProfile). Marked, so a re-run does
        not add it twice and the uninstaller can find it.
    #>
    param([Parameter(Mandatory)][string]$Directory, [string]$HomeDir = $HOME,
          [AllowEmptyString()][AllowNull()][string]$Shell = $env:SHELL)
    $marker = '# agent-ha-bridge'
    $line = "export PATH=`"$Directory`:`$PATH`" $marker"
    $changed = $false
    foreach ($file in (Get-BridgeShellProfile -HomeDir $HomeDir -Shell $Shell)) {
        $existing = if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw } else { '' }
        # This exact folder, not merely any bridge line: the CLIs the installer put in
        # npm's own bin folder need that folder on PATH too, and matching the marker
        # alone would treat the second call as already done.
        if ($existing -match [regex]::Escape($line)) { continue }
        Add-Content -LiteralPath $file -Value "`n$line"
        $changed = $true
    }
    $changed
}

function Get-BridgeNpmBinDir {
    <#
        The folder `npm install -g` links its commands into, or ''.

        On a MacPorts Mac that is /opt/local/bin, and MacPorts does not reliably get it
        onto a bash user's PATH - so `codex` and `claude` came back "command not found"
        in the very terminal they have to be signed in from, right after the installer
        had put them there.
    #>
    $npm = Get-BridgeNpmPath
    if ($npm -eq 'npm') { return '' }
    if ($npm -match '^(.*)/[^/]+$') { return $Matches[1] }
    ''
}

function Get-BridgeDevBoxKeepAwakeDecision {
    <#
        Whether the Dev Box keep-awake task should exist after this install, and the
        one-line reason - which is what the summary prints and what a test asserts on.

        Deliberately pure: no Task Scheduler, no file system, no network. The offline
        suite runs on the macOS CI leg too, where the ScheduledTasks module does not
        exist at all, so the decision has to be separable from carrying it out.
    #>
    param(
        [bool]$IsDevBox,
        [bool]$Requested,
        [bool]$OnWindows = $true,
        [bool]$Sandbox,
        [bool]$SkipTask
    )

    if (-not $IsDevBox) { return [pscustomobject]@{ Enabled = $false; Reason = 'not a Dev Box' } }
    if (-not $OnWindows) { return [pscustomobject]@{ Enabled = $false; Reason = 'Dev Box keep-awake is Windows-only' } }
    if ($SkipTask) { return [pscustomobject]@{ Enabled = $false; Reason = 'scheduled tasks skipped' } }
    # A -TargetHome run is a throwaway sandbox, and a scheduled task is machine-wide:
    # registering one there would outlive the sandbox it was testing.
    if ($Sandbox) { return [pscustomobject]@{ Enabled = $false; Reason = 'sandbox install registers no task' } }
    if (-not $Requested) { return [pscustomobject]@{ Enabled = $false; Reason = 'not enabled' } }
    [pscustomobject]@{ Enabled = $true; Reason = 'enabled' }
}

function Test-BridgeDevBoxKeepAwakePrompt {
    <#
        Whether to put the keep-awake question this run.

        Asked once and then remembered, because it is a question about this machine's
        power behaviour rather than about the bridge: re-asking on every upgrade would
        be noise, and never asking would leave the feature undiscovered on exactly the
        machines that need it.
    #>
    param(
        [bool]$IsDevBox,
        [bool]$Interactive,
        [bool]$SwitchProvided,
        [bool]$ConfigExisted,
        [AllowEmptyCollection()][string[]]$FilledKeys = @()
    )

    if (-not $IsDevBox -or -not $Interactive) { return $false }
    # An explicit -DevBoxKeepAwake has already answered it.
    if ($SwitchProvided) { return $false }
    if (-not $ConfigExisted) { return $true }
    # Merge-BridgeConfigDefaults reports the keys it had to add, so the devBox section
    # turning up there means this config predates the feature and has never been
    # asked - which is how an upgrade gets the question exactly once.
    $filled = @($FilledKeys)
    ($filled -contains 'devBox') -or ($filled -contains 'devBox.keepAwake')
}

# Tests dot-source this script with BRIDGE_INSTALL_NORUN set to load its helper
# functions without running the install; a real run never sets it.
if ($env:BRIDGE_INSTALL_NORUN) { return }

if (-not $IsWindows -and -not $IsMacOS -and $PSVersionTable.PSVersion.Major -ge 6) {
    throw 'This bridge runs on Windows and macOS.'
}

# Windows PowerShell can parse this script but not run it: the hooks, the daemon and
# the reply injection are all pwsh. A missing prerequisite used to end the install
# here, which is exactly the wrong moment to hand someone a winget command - so get
# PowerShell 7 installed and hand the install over to it instead.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ''
    Write-Host "This installer runs on PowerShell 7; you are on Windows PowerShell $($PSVersionTable.PSVersion)." -ForegroundColor Yellow

    $pwshPath = Get-BridgePwshPath
    if (-not $pwshPath) {
        $outcome = Request-BridgeDependency -Name 'pwsh' -NonInteractive:$NonInteractive
        if ($outcome -eq 'Installed') { $pwshPath = Get-BridgePwshPath }
    }
    if (-not $pwshPath) {
        throw ("PowerShell 7 is required. Install it with:`n    " +
               (Get-BridgeDependencyCommand -Name 'pwsh'))
    }
    if (($PSBoundParameters.ContainsKey('Token') -and $Token) -or
        ($PSBoundParameters.ContainsKey('AgentToken') -and $AgentToken)) {
        throw ('PowerShell 7 is ready, but token arguments are not forwarded to a child process. ' +
               'Re-run in PowerShell 7 using the masked prompts or token environment variables.')
    }

    Write-Step "Restarting under PowerShell 7 ($pwshPath)"
    $forwarded = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath) +
                 @(ConvertTo-BridgeArgumentList -BoundParameters $PSBoundParameters -Exclude @('Token', 'AgentToken'))
    & $pwshPath @forwarded
    exit $LASTEXITCODE
}
if (-not (Test-Path -LiteralPath $bridgeHome)) {
    New-Item -ItemType Directory -Path $bridgeHome -Force | Out-Null
    if (-not (Protect-BridgeSecretFile -Path $bridgeHome)) { throw 'Could not protect the bridge credential directory.' }
}

$script:DidMigrate = Invoke-BridgeLayoutMigration `
    -CopilotHome $copilotHome -BridgeHome $bridgeHome -ConfigPath $configPath `
    -LegacyHooksDir $legacyHooksDir -LegacyConfigPath $legacyConfigPath `
    -LegacyBridgeHome $legacyBridgeHome -LegacyArpKey $legacyArpKey `
    -LegacyTaskName $legacyTaskName -SkipMachineWide:([bool]$TargetHome -or -not $script:BridgeIsWindows)

# ---------------------------------------------------------------- hook scripts
Write-Step "Copying hook scripts to $hooksDir"
if (-not (Test-Path -LiteralPath $hooksDir)) { New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null }
Get-ChildItem (Join-Path $repoRoot 'hooks') -File | ForEach-Object {
    Copy-Item $_.FullName $hooksDir -Force
    Write-Host "    $($_.Name)"
}

if (Test-Path -LiteralPath $versionFile) { Copy-Item $versionFile $hooksDir -Force }

# The reply card lives next to the hooks so bridge-frontend-cards.ps1 can find it
# from an install that never had the repository.
$frontendSource = Join-Path $repoRoot 'frontend'
if (Test-Path -LiteralPath $frontendSource) {
    $frontendDir = Join-Path $bridgeHome 'frontend'
    if (-not (Test-Path -LiteralPath $frontendDir)) {
        New-Item -ItemType Directory -Path $frontendDir -Force | Out-Null
    }
    Get-ChildItem $frontendSource -File | ForEach-Object {
        Copy-Item $_.FullName $frontendDir -Force
        Write-Host "    $($_.Name)"
    }
}

# --------------------------------------------------------------------- config
Write-Step 'Reading the bridge config'
# Whether this is a first install decides whether a remembered client selection
# exists at all. config.example.json is a template, not a previous answer.
$configExisted = Test-Path -LiteralPath $configPath
$exampleRaw = Get-Content -LiteralPath (Join-Path $repoRoot 'config.example.json') -Raw -Encoding UTF8
$defaults = $exampleRaw | ConvertFrom-Json
$config = $null
if ($configExisted) {
    # Never lose a working config to a mistyped re-run - and back it up before reading
    # it, so even an unreadable one is recoverable.
    Copy-BridgeSecretFile -Source $configPath -Destination "$configPath.bak"
    Write-Host "    backed up existing config to $(Split-Path $configPath -Leaf).bak"

    $read = Read-BridgeConfigFile -Path $configPath
    if ($read.Config) { $config = $read.Config }
    else {
        if (-not ($PSBoundParameters.ContainsKey('HomeAssistantUrl') -and $HomeAssistantUrl)) {
            throw ('The existing configuration could not be read. Repair it, or explicitly supply ' +
                   '-HomeAssistantUrl to authorize a replacement configuration. The protected backup is retained.')
        }
        Write-Warning ("$configPath could not be read ($($read.Error)). Starting from the " +
                       "defaults; your previous file is at $(Split-Path $configPath -Leaf).bak.")
        # A config that cannot be read holds no remembered answers either.
        $configExisted = $false
    }
}
# Parsed separately rather than reusing $defaults: a fresh install would otherwise
# merge an object into itself, and every later edit would mutate the defaults too.
if (-not $config) { $config = $exampleRaw | ConvertFrom-Json }
$configuredUrl = ''
if ($configExisted -and $config.PSObject.Properties['homeAssistant'] -and $config.homeAssistant -and
    $config.homeAssistant.PSObject.Properties['baseUrl']) {
    $configuredUrl = [string]$config.homeAssistant.baseUrl
}

# A config from an older version is missing keys this installer reaches straight into.
$filled = @(Merge-BridgeConfigDefaults -Config $config -Defaults $defaults)
if ($filled) { Write-Host "    added missing setting(s): $($filled -join ', ')" }

if ($PSBoundParameters.ContainsKey('HomeAssistantUrl') -and $HomeAssistantUrl) {
    $config.homeAssistant.baseUrl = ConvertTo-BridgeHomeAssistantUrl -Value $HomeAssistantUrl
}
if ($PSBoundParameters.ContainsKey('Token') -and $Token) {
    $config.homeAssistant.token = $Token
}
if (($PSBoundParameters.ContainsKey('Token') -and $Token) -or
    ($PSBoundParameters.ContainsKey('AgentToken') -and $AgentToken)) {
    Write-Warning 'Token arguments can appear in shell history and process listings. Prefer masked prompts or environment variables.'
}
# -AgentToken is deliberately NOT stored here. It is a *candidate* until the agent
# identity step below has asked Home Assistant who it belongs to: storing it first
# means a revoked token, or one minted on your own account, is persisted anyway and
# then fails silently for the life of the install - which is the exact failure the
# check exists to prevent.
if ($PSBoundParameters.ContainsKey('NotifyService') -and $NotifyService) {
    $config.notifications.enabled = $true
    $config.notifications.service = $NotifyService
}
if ($PSBoundParameters.ContainsKey('TickerCategory') -and $TickerCategory) {
    $config.notifications.tickerCategory = $TickerCategory
}

# A Dev Box pool with stop-on-disconnect hibernates the machine an hour or so after
# the last RDP session goes, measuring idleness by sessions rather than by load - so
# a Dev Box running the daemon and several agent sessions is hibernated mid-task and
# simply reads as offline on the dashboard. Detected rather than configured, so an
# ordinary desktop never sees any of this.
$isDevBox = Test-BridgeDevBox
if ($PSBoundParameters.ContainsKey('DevBoxKeepAwake')) {
    $config.devBox.keepAwake = [bool]$DevBoxKeepAwake
}
elseif (Test-BridgeDevBoxKeepAwakePrompt -IsDevBox $isDevBox `
        -Interactive (-not $NonInteractive -and (Test-BridgeConsoleInteractive)) `
        -SwitchProvided $false -ConfigExisted $configExisted -FilledKeys $filled) {
    Write-Host ''
    Write-Host '    This machine is a Microsoft Dev Box, and Dev Box pools commonly hibernate' -ForegroundColor DarkGray
    Write-Host '    on disconnect. That stops the daemon and every running agent session, because' -ForegroundColor DarkGray
    Write-Host '    the pool measures idleness by RDP sessions rather than by what is running.' -ForegroundColor DarkGray
    $config.devBox.keepAwake = Read-BridgeYesNo -Prompt '    Keep this Dev Box awake while the bridge runs?' -Default $true
}
# Settled here rather than beside the task registration, because the summary is
# printed before the task is registered and both have to agree.
$devBoxIntervalHours = 4
if ($config.devBox.PSObject.Properties['intervalHours'] -and [int]$config.devBox.intervalHours -ge 1) {
    $devBoxIntervalHours = [int]$config.devBox.intervalHours
}
$devBoxDecision = Get-BridgeDevBoxKeepAwakeDecision -IsDevBox $isDevBox `
    -Requested ([bool]$config.devBox.keepAwake) -OnWindows ([bool]$script:BridgeIsWindows) `
    -Sandbox ([bool]$TargetHome) -SkipTask ([bool]$SkipTask)

# Pre-rename configs pinned the old slug explicitly, which would leave the daemon
# writing to /copilot-decisions forever. Only the old default is rewritten - a slug
# the user actually chose is left alone.
if ($config.PSObject.Properties['dashboard'] -and
    [string]$config.dashboard.urlPath -eq 'copilot-decisions') {
    $config.dashboard.urlPath = 'agent-decisions'
    Write-Host '    dashboard slug: copilot-decisions -> agent-decisions'
}

# Same for the update repository, and this one matters more than tidiness. A
# pre-rename config still names danswett/copilot-ha-bridge, which resolves only
# because GitHub redirects a renamed repository - and that redirect lasts exactly as
# long as nobody else registers the old name. The moment someone does, every install
# still carrying it checks a stranger's releases, and the self-updater downloads and
# runs their archive. Only the old default is rewritten; a fork is left alone.
if ($config.PSObject.Properties['updates'] -and $config.updates -and
    [string]$config.updates.repository -eq 'danswett/copilot-ha-bridge') {
    $config.updates.repository = 'danswett/agent-ha-bridge'
    Write-Host '    update repository: danswett/copilot-ha-bridge -> danswett/agent-ha-bridge'
}

# ------------------------------------------------------------------- clients
# Which clients to configure comes first: the answer decides what else gets offered,
# and it is the question people most want to be asked. -Clients wins, then a
# selection remembered from a previous install (so a re-run or a self-update
# reconfigures the same set), then an interactive pick, then 'copilot' as the
# unattended default. The shared daemon, dashboard and Home Assistant plumbing are
# installed either way.
$detectedClients = @($script:KnownClients | Where-Object { Test-BridgeClientInstalled $_ })
$requestedClients = if ($PSBoundParameters.ContainsKey('Clients')) { $Clients } else { $null }
# Only a config that already existed can hold a previous answer. Reading this from
# the shipped example is what used to make the picker never appear.
$persistedClients = @()
if ($configExisted -and $config.PSObject.Properties['clients']) { $persistedClients = @($config.clients) }
$selectedClients = Resolve-BridgeClients -Requested $requestedClients -Persisted $persistedClients `
    -NonInteractive:$NonInteractive -Prompt { Read-BridgeClientSelection -Detected $detectedClients }
if ($config.PSObject.Properties['clients']) { $config.clients = @($selectedClients) }
else { $config | Add-Member -NotePropertyName 'clients' -NotePropertyValue @($selectedClients) -Force }
Write-Step "Configuring: $(($selectedClients | ForEach-Object { $script:ClientLabels[$_] }) -join ', ')"

# Configuring a client the machine does not have writes hooks that do nothing, which
# is a confusing thing to discover later. Offer to install each one instead - and
# Node first when it is needed, since every agent CLI ships through npm.
if (-not $SkipDependencies) {
    $wanted = @($selectedClients | Where-Object { -not (Test-BridgeDependencyInstalled $_) })
    if ($wanted) {
        Write-Step 'Checking the clients you chose are installed'
        # Node covers all of them: the CLIs install through npm, and 'mcp' is this
        # repo's own Node server rather than a package, so it needs the runtime too.
        [void](Request-BridgeDependency -Name 'node' -NonInteractive:$NonInteractive)
        foreach ($client in @($wanted | Where-Object { $_ -ne 'mcp' })) {
            [void](Request-BridgeDependency -Name $client -NonInteractive:$NonInteractive)
        }
    }
    # macOS sessions run in tmux: without it they still get cards, but no replies.
    if (-not $script:BridgeIsWindows) {
        [void](Request-BridgeDependency -Name 'tmux' -NonInteractive:$NonInteractive)
    }
}

# ----------------------------------------------------------- Home Assistant
# Settle the URL without asking a question that already has an answer, then make sure
# the token actually works before the install carries on.
$effectiveToken = $config.homeAssistant.token
if (-not $effectiveToken -and $config.homeAssistant.tokenEnvVar) {
    $effectiveToken = [Environment]::GetEnvironmentVariable($config.homeAssistant.tokenEnvVar)
}

if (-not ($PSBoundParameters.ContainsKey('HomeAssistantUrl') -and $HomeAssistantUrl)) {
    Write-Step 'Looking for Home Assistant'
    $urlPrompt = $null
    if (-not $NonInteractive) {
        $urlPrompt = {
            param($current)
            Write-Host '    not found automatically' -ForegroundColor Yellow
            Read-Host "    Home Assistant URL [$current]"
        }
    }
    if ($configExisted -and -not $configuredUrl) {
        throw 'The existing configuration has no Home Assistant URL. Supply -HomeAssistantUrl explicitly before using its credentials.'
    }
    $resolvedUrl = Resolve-BridgeHomeAssistantUrl -Configured $configuredUrl -Prompt $urlPrompt
    if ($resolvedUrl.Url) { $config.homeAssistant.baseUrl = $resolvedUrl.Url }
    switch ($resolvedUrl.Source) {
        'config'     { Write-Host "    using $($resolvedUrl.Url) from the existing config" -ForegroundColor Green }
        'discovered' { Write-Host "    found $($resolvedUrl.Url)" -ForegroundColor Green }
        'typed'      { Write-Host "    using $($resolvedUrl.Url)" }
        default      { Write-Host "    keeping $($resolvedUrl.Url), unverified" -ForegroundColor Yellow }
    }
}

# A long-lived token is sent on every request, so over plain HTTP it crosses the
# network in the clear. Local Home Assistant installs are usually http, so this warns
# rather than blocks.
$base = ConvertTo-BridgeHomeAssistantUrl -Value $config.homeAssistant.baseUrl
$config.homeAssistant.baseUrl = $base
if (([Uri]$base).Scheme -eq 'http' -and -not ([Uri]$base).IsLoopback) {
    Write-Warning ("$base is plain HTTP, so the access token is sent unencrypted over your " +
                   'network. Prefer https:// if your Home Assistant has a certificate.')
}

$homeAssistantReady = $false
if ($SkipVerify) {
    Write-Step 'Skipping the Home Assistant check (-SkipVerify)'
    if (-not $effectiveToken -and -not $NonInteractive) {
        Write-Host '    no token yet; set one later with: agent-ha-bridge configure' -ForegroundColor DarkGray
    }
}
else {
    Write-Step 'Connecting to Home Assistant'
    # Up to three goes, because the overwhelmingly likely failure is a half-copied
    # token - and being told that at the end of the install, rather than here, is what
    # made the old flow frustrating.
    $connection = Test-BridgeHomeAssistantConnection -BaseUrl $base -Token $effectiveToken
    $remaining = 3
    $offeredBrowser = $false
    while (-not $connection.Ok -and -not $NonInteractive -and $remaining -gt 0) {
        $remaining--
        if ($effectiveToken) { Write-BridgeConnectionResult -Result $connection }
        $profileUrl = "$base/profile/security"
        Write-Host ''
        Write-Host 'Home Assistant needs a long-lived access token.' -ForegroundColor Yellow
        Write-Host "    1. Open $profileUrl"
        Write-Host '    2. Scroll to "Long-lived access tokens" and choose "Create token"'
        Write-Host '    3. Name it anything (e.g. "agent bridge") and copy the value'
        # Offered once, and never to a scripted run: nobody is there to see the window,
        # and the prompt would eat a line of piped input meant for the token.
        if (-not $offeredBrowser -and (Test-BridgeConsoleInteractive)) {
            $offeredBrowser = $true
            if (Read-BridgeYesNo -Prompt '    Open that page in your browser now?') {
                try { Start-Process $profileUrl | Out-Null }
                catch { Write-Host "    could not open a browser; visit $profileUrl yourself" -ForegroundColor Yellow }
            }
        }
        $entered = Read-BridgeSecret -Prompt '    Paste the token here'
        if ([string]::IsNullOrWhiteSpace($entered)) {
            Write-Host '    nothing pasted; giving up on the token for now.' -ForegroundColor DarkGray
            break
        }
        $effectiveToken = $entered.Trim()
        $config.homeAssistant.token = $effectiveToken
        Write-Step 'Connecting to Home Assistant'
        $connection = Test-BridgeHomeAssistantConnection -BaseUrl $base -Token $effectiveToken
    }

    Write-BridgeConnectionResult -Result $connection
    if (-not $connection.Ok) {
        throw ("Could not reach Home Assistant at $base : $($connection.Error)`n" +
               '    Fix it and re-run, or pass -SkipVerify to finish the install and use ' +
               '`agent-ha-bridge configure` later.')
    }
    $homeAssistantReady = $true
}

# ------------------------------------------------------- the agent's own identity
#
# Optional, and skipped without complaint. What it buys is the only honest way to
# tell an agent's turn from yours: an agent drives the bridge through the same
# entities you do, so the account behind the press is the one signal that separates
# them, and that needs an account of its own.
#
# The user id is read back from the token rather than asked for. It used to be copied
# by hand out of a Settings URL - the one step in this whole flow with a silent wrong
# answer available, since a long-lived token's `iss` claim looks exactly like a user
# id and is not one.
if ($homeAssistantReady) {
    # Candidate order: what was passed, then what is already configured, then the
    # environment. Only the check below decides whether any of it is stored.
    $agentTokenValue = ''
    $persistAgentToken = $false
    if ($PSBoundParameters.ContainsKey('AgentToken') -and $AgentToken) { $agentTokenValue = [string]$AgentToken }
    if (-not $agentTokenValue) { $agentTokenValue = [string]$config.homeAssistant.agentToken }
    if ($agentTokenValue) { $persistAgentToken = $true }
    if (-not $agentTokenValue) {
        $agentEnvVar = [string]$config.homeAssistant.agentTokenEnvVar
        if ($agentEnvVar) { $agentTokenValue = [string][Environment]::GetEnvironmentVariable($agentEnvVar) }
    }

    if (-not $agentTokenValue -and -not $NonInteractive -and (Test-BridgeConsoleInteractive)) {
        Write-Host ''
        Write-Host 'Optional: give the agent its own Home Assistant account.' -ForegroundColor Yellow
        Write-Host '    Without one, a session an agent starts or replies to is indistinguishable'
        Write-Host '    from one you drove yourself, and is never marked on the dashboard.'
        if (Read-BridgeYesNo -Prompt '    Set that up now?' -Default $false) {
            Write-Host "    1. Open $base/config/person and add a person with 'Allow login' on -"
            Write-Host '       call it Copilot, and leave it a non-administrator'
            Write-Host '    2. Log in as that user (a private browser window is easiest)'
            Write-Host '    3. On its profile, Security -> Long-lived access tokens -> Create token'
            $enteredAgent = Read-BridgeSecret -Prompt '    Paste the agent token here (Enter to skip)'
            if (-not [string]::IsNullOrWhiteSpace($enteredAgent)) {
                $agentTokenValue = $enteredAgent.Trim()
                $persistAgentToken = $true
            }
        }
    }

    if ($agentTokenValue) {
        Write-Step 'Checking the agent account'
        $identity = Resolve-BridgeAgentIdentity -BaseUrl $base -AgentToken $agentTokenValue -OwnToken $effectiveToken `
            -EnvironmentOnly:(-not $persistAgentToken)
        if ($identity.Store) {
            $config.homeAssistant.agentToken = $identity.Token
            # Written from the token, never asked for: this is the step that used to
            # have a silent wrong answer available.
            $config.homeAssistant.agentUserIds = @($identity.UserId)
            Write-Host "    agent account: $($identity.Name) ($($identity.UserId))" -ForegroundColor Green
            if ($identity.IsAdmin) {
                Write-Host '                   it is an administrator; a non-admin is plenty for driving sessions' -ForegroundColor Yellow
            }
        }
        else { Write-Warning $identity.Warning }
    }
}

# Record what was installed, so the update check can compare against the newest
# release without guessing.
if (-not $config.PSObject.Properties.Name.Contains('updates')) {
    $config | Add-Member -NotePropertyName 'updates' -NotePropertyValue ([pscustomobject]@{
        repository = 'danswett/agent-ha-bridge'; installedVersion = ''; checkForUpdates = $true
    })
}
$config.updates.installedVersion = $version
# Written every install, not only when true, so a machine that moves from a working
# copy to a release stops calling itself dev.
if ($config.updates.PSObject.Properties.Name -contains 'installedFromSource') {
    $config.updates.installedFromSource = $installedFromSource
}
else {
    $config.updates | Add-Member -NotePropertyName 'installedFromSource' -NotePropertyValue $installedFromSource
}

Write-Step "Writing bridge config to $configPath"
Write-BridgeSecretFile -Path $configPath -Content ($config | ConvertTo-Json -Depth 8)
$hasAgentToken = -not [string]::IsNullOrWhiteSpace([string]$config.homeAssistant.agentToken)
if (-not $hasAgentToken -and $config.homeAssistant.agentTokenEnvVar) {
    $hasAgentToken = -not [string]::IsNullOrWhiteSpace(
        [Environment]::GetEnvironmentVariable([string]$config.homeAssistant.agentTokenEnvVar))
}
Write-Host "    baseUrl      : $($config.homeAssistant.baseUrl)"
Write-Host "    token        : $(if ($config.homeAssistant.token) { 'set in config' } else { "from `$env:$($config.homeAssistant.tokenEnvVar)" })"
Write-Host "    agent account: $(
    if ($hasAgentToken -and @($config.homeAssistant.agentUserIds).Count) { 'set - agent-driven sessions are marked' }
    elseif ($config.homeAssistant.agentToken -or @($config.homeAssistant.agentUserIds).Count) { 'half set - see the warning below' }
    else { 'none - an agent drives the bridge as you' })"
Write-Host "    notifications: $(if ($config.notifications.enabled) { $config.notifications.service } else { 'disabled' })"
if ($isDevBox) {
    Write-Host "    Dev Box      : $(if ($devBoxDecision.Enabled) { "keep-awake on - '$devBoxTaskName' every ${devBoxIntervalHours}h" } else { "keep-awake off ($($devBoxDecision.Reason))" })"
}

function Get-BridgeInstallAgentIdentityWarning {
    <#
        Why an agent-driven session could never be marked as one, or '' when it can.

        An agent identity is two settings that are inert apart, and having only one of
        them fails silently - the dashboard simply never marks anything. Said here
        because nothing later will.

        The rule lives with the code that reads the config rather than being copied,
        and the library is dot-sourced inside this function: at script scope it would
        define the whole thing in the installer, and a dot-sourced script rebinds any
        parameter it declares over a same-named local here. AGENT_HA_BRIDGE_CONFIG is
        pointed at the file just written, since -TargetHome need not be $HOME.
    #>
    param([Parameter(Mandatory)][string]$HooksDir, [Parameter(Mandatory)][string]$ConfigFile)

    $lib = Join-Path $HooksDir 'decision-bridge-common.ps1'
    if (-not (Test-Path -LiteralPath $lib)) { return '' }
    $previous = $env:AGENT_HA_BRIDGE_CONFIG
    $env:AGENT_HA_BRIDGE_CONFIG = $ConfigFile
    try {
        . $lib
        if (-not (Get-Command Get-BridgeAgentIdentityWarning -ErrorAction SilentlyContinue)) { return '' }
        [string](Get-BridgeAgentIdentityWarning)
    }
    catch { '' }
    finally {
        if ($null -eq $previous) { Remove-Item Env:\AGENT_HA_BRIDGE_CONFIG -ErrorAction SilentlyContinue }
        else { $env:AGENT_HA_BRIDGE_CONFIG = $previous }
    }
}

$agentIdentityWarning = Get-BridgeInstallAgentIdentityWarning -HooksDir $hooksDir -ConfigFile $configPath
if ($agentIdentityWarning) { Write-Warning $agentIdentityWarning }

# The dashboard is drawn with three custom Lovelace cards. Without them it renders as
# a column of "Custom element doesn't exist" boxes - an install that reports success
# and then visibly does not work. The file itself can only come from HACS, but a card
# that is downloaded and merely unregistered is repaired here.
#
# This is also the only place the bridge's own reply card is delivered, so gating it on
# a *verified* connection quietly broke every update: a self-update runs this script
# with -SkipVerify, which leaves $homeAssistantReady false, so the card was last
# refreshed by whatever interactive install came before it. Dashboards sat on a card
# several releases old while every machine reported itself up to date, and a card
# feature could ship and simply never appear. -SkipVerify means "do not fail the
# install on the check", not "do not talk to Home Assistant" - so with a token to hand,
# try. Nothing here throws: the card check reports and returns.
$canReachHomeAssistant = $homeAssistantReady -or (-not [string]::IsNullOrWhiteSpace($effectiveToken))
if ($canReachHomeAssistant) {
    Write-Step 'Checking the dashboard frontend cards'
    [void](Invoke-BridgeFrontendCardCheck -HooksDir $hooksDir -ConfigPath $configPath -Register)
}


# Builds up to 1.4.2 shipped a decision-notifier skill. It never had frontmatter, so
# Copilot never registered it, and any instruction telling the model to load it cost a
# failed lookup plus a round of reasoning to rediscover that the preToolUse hook already
# does the work. Remove it on upgrade rather than leaving the stale copy behind, whatever
# clients are selected now.
if (Test-Path -LiteralPath $legacySkillDir) {
    Write-Step 'Removing the obsolete decision-notifier skill'
    Remove-Item -LiteralPath $legacySkillDir -Recurse -Force
    Write-Host "    $legacySkillDir"
}

# --------------------------------------------------------------- native hook
# The fast hook program (docs/fast-hooks.md), before any agent's hooks are written:
# they point at it only when it is installed and runs. Without it they stay PowerShell.
Write-Step 'Installing the native hook'
$nativeRepository = if ($config.PSObject.Properties['updates'] -and $config.updates -and $config.updates.repository) {
    [string]$config.updates.repository
} else { 'danswett/agent-ha-bridge' }
$nativeHook = Install-BridgeNativeHook -RepoRoot $repoRoot -BinDir $binDir -Version $version -Repository $nativeRepository
if ($nativeHook.Path) { Write-Host "    $($nativeHook.Path) ($($nativeHook.Detail))" }
else { Write-Host "    skipped: $($nativeHook.Detail); hooks stay PowerShell" -ForegroundColor DarkGray }

# ------------------------------------------------------- configure Copilot CLI
if ($selectedClients -contains 'copilot') {
    if (-not (Test-BridgeClientInstalled 'copilot')) {
        Write-Warning 'Copilot CLI was selected but is not on PATH; its hooks are written and will take effect once it is installed.'
    }

    Write-Step 'Merging Copilot hook definitions'
    # The hook definition is the one bridge file that has to stay under ~/.copilot,
    # because that is where the Copilot CLI looks for it. It points at the scripts in
    # the bridge's own root.
    $copilotHooksDir = Split-Path -Parent $hookConfigPath
    if (-not (Test-Path -LiteralPath $copilotHooksDir)) {
        New-Item -ItemType Directory -Path $copilotHooksDir -Force | Out-Null
    }
    $hookDefs = [ordered]@{
        agentStop = @(
            [ordered]@{
                type = 'command'
                powershell = "& '$(Join-Path $hooksDir 'notify-agent-response.ps1')'"
                timeoutSec = 30
            }
        )
        preToolUse = @(
            [ordered]@{
                type = 'command'
                matcher = 'ask_user'
                powershell = "& '$(Join-Path $hooksDir 'route-ask-user-v3.ps1')'"
                timeoutSec = 120
            }
        )
        notification = @(
            [ordered]@{
                type = 'command'
                matcher = 'permission_prompt'
                powershell = "& '$(Join-Path $hooksDir 'notify-home-assistant.ps1')'"
                timeoutSec = 15
            }
        )
    }
    # The native hook, run with no shell (`exec` + `args`), when it is installed and runs
    # and this Copilot is new enough to take it (Test-BridgeCopilotRunsExec). Agency runs
    # Copilot and uses these same hooks. The script stays as the native hook's fallback.
    $copilotVersion = if ($nativeHook.Path) { Get-BridgeCopilotVersion } else { $null }
    $copilotExec = [bool]$nativeHook.Path -and (Test-BridgeCopilotRunsExec -Version $copilotVersion)
    if ($copilotExec) {
        ConvertTo-BridgeCopilotExecHook -HookDefs $hookDefs -NativeHook $nativeHook.Path
        Write-Host "    through the native hook (Copilot $copilotVersion)"
    }
    elseif ($nativeHook.Path) {
        Write-Warning "Copilot CLI $(if ($copilotVersion) { $copilotVersion } else { 'not found' }) is below $($script:BridgeCopilotExecMinVersion), so its hooks stay PowerShell and cost about 570 ms each instead of 21 ms - on the path you wait on. Run 'copilot update', then re-run this installer."
    }
    # Off Windows the CLI runs a hook's `bash` command, so each gets one that starts
    # the same script under pwsh, by full path - a hook's PATH may not include it.
    if (-not $script:BridgeIsWindows -and -not $copilotExec) {
        $pwshForHooks = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
        foreach ($event in @($hookDefs.Keys)) {
            foreach ($def in $hookDefs[$event]) {
                $scriptPath = ([regex]::Match($def.powershell, "'([^']+)'")).Groups[1].Value
                $def.bash = "'$pwshForHooks' -NoProfile -NonInteractive -File '$scriptPath'"
            }
        }
    }
    @{ version = 1; hooks = $hookDefs } | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $hookConfigPath -Encoding UTF8
    Write-Host "    $hookConfigPath"
    if (Install-BridgeAgentInstructions -Path $agentInstructionsPath `
            -EnvVarName ([string]$config.homeAssistant.agentTokenEnvVar) `
            -HasAgentToken:$hasAgentToken) {
        Write-Host "    $agentInstructionsPath"
    }
}
elseif (Test-Path -LiteralPath $hookConfigPath) {
    # Copilot is not configured, so a definition left over from an earlier run would
    # point the CLI at scripts this install has just moved out from under it.
    Write-Step 'Removing the stale Copilot hook definition'
    Remove-Item -LiteralPath $hookConfigPath -Force -ErrorAction SilentlyContinue
    Write-Host "    $hookConfigPath"
}
if (-not ($selectedClients -contains 'copilot') -and (Test-Path -LiteralPath $agentInstructionsPath)) {
    # Guidance for a client this install no longer configures is just context cost.
    Remove-Item -LiteralPath $agentInstructionsPath -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------- scheduled task
$taskRegistered = $false
if (-not $SkipTask -and -not $script:BridgeIsWindows) {
    Write-Step "Registering the '$launchAgentLabel' LaunchAgent"
    try {
        if ($TargetHome) { throw 'a -TargetHome sandbox does not register a LaunchAgent' }
        $pwshPath = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
        $pathValue = @(@($env:PATH -split ':') + @('/opt/homebrew/bin', '/usr/local/bin', '/opt/local/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin') |
            Where-Object { $_ } | Select-Object -Unique) -join ':'
        $plist = Get-BridgeLaunchAgentPlist -Label $launchAgentLabel -PwshPath $pwshPath `
            -DaemonPath (Join-Path $hooksDir 'agent-bridge-daemon.ps1') `
            -LogPath (Get-BridgeLaunchAgentLogPath) -PathValue $pathValue
        $taskRegistered = Register-BridgeLaunchAgent -Label $launchAgentLabel -PlistPath $launchAgentPath -Content $plist
        if ($taskRegistered) { Write-Host '    registered and started' }
        else { Write-Warning "launchd did not accept $launchAgentPath" }
    }
    catch {
        Write-Warning "Could not register the LaunchAgent: $($_.Exception.Message)"
    }
}
elseif (-not $SkipTask) {
    Write-Step "Registering the '$taskName' scheduled task"
    # wscript + the VBS launcher, not pwsh directly: WScript.Shell.Run(..., 0, False)
    # starts the supervisor with no window at all, while still giving the daemon a real
    # console. conhost --headless would give a pseudoconsole and break reply injection.
    try {
        $launcher = Join-Path $hooksDir 'agent-bridge-launch.vbs'
        $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$launcher`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
            -LogonType Interactive -RunLevel Limited

        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Set-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                -Settings $settings -Principal $principal | Out-Null
        }
        else {
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                -Settings $settings -Principal $principal `
                -Description 'Supervises the AI coding agent Home Assistant bridge daemon.' | Out-Null
        }
        # Stopping the task does not stop the bridge: the task only runs wscript, which
        # has long since exited, and the supervisor it started is detached. The old
        # supervisor and daemon therefore kept running the previous version, and the new
        # supervisor saw one already running and quit - so an install or update never
        # took effect until the next logon. They are stopped here, sparing this
        # installer's own ancestors: a dashboard update runs it from the daemon.
        if (-not $TargetHome) {
            $ancestors = @{}
            $walk = $PID
            for ($i = 0; $i -lt 16 -and $walk; $i++) {
                $ancestors[[int]$walk] = $true
                $walk = (Get-CimInstance Win32_Process -Filter "ProcessId=$walk" -ErrorAction SilentlyContinue).ParentProcessId
            }
            foreach ($proc in @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue)) {
                if ($ancestors.ContainsKey([int]$proc.ProcessId)) { continue }
                if ([string]$proc.CommandLine -match 'agent-bridge-(supervisor|daemon)\.ps1') {
                    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
                    Write-Host "    stopped the running $($Matches[1]) (pid $($proc.ProcessId))"
                }
            }
        }
        Start-ScheduledTask -TaskName $taskName
        Write-Host '    registered and started'
        $taskRegistered = $true
    }
    catch {
        # Group policy can forbid task creation outright. Everything else this installer
        # does is still worth finishing - the PATH command, the hooks, the config - and
        # `agent-ha-bridge status` reports the missing task, so fail loudly here rather
        # than abandoning the install half-done.
        Write-Warning ("Could not register the '$taskName' scheduled task: $($_.Exception.Message)`n" +
                       '    The bridge cannot run until it exists. Task Scheduler is often ' +
                       'restricted by policy; once that is sorted, run: agent-ha-bridge configure')
    }
}

# ------------------------------------------------- Dev Box keep-awake task
if ($devBoxDecision.Enabled) {
    Write-Step "Registering the '$devBoxTaskName' scheduled task"
    try {
        $keepAwakeLauncher = Join-Path $hooksDir 'agent-bridge-devbox-keepawake.vbs'
        $keepAwakeAction = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$keepAwakeLauncher`""
        # Two triggers rather than one with its .Repetition reassigned: mutating the
        # repetition of an AtLogOn trigger is fragile across Windows builds, and this
        # says the same thing - run once the machine is usable, then keep running.
        $keepAwakeTriggers = @(
            (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME),
            (New-ScheduledTaskTrigger -Once -At (Get-Date) `
                -RepetitionInterval (New-TimeSpan -Hours $devBoxIntervalHours) `
                -RepetitionDuration ([TimeSpan]::MaxValue))
        )
        # No RestartCount: a pass that fails because the Azure CLI login expired will
        # fail again immediately, and the next scheduled pass is the right retry.
        $keepAwakeSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -Hidden
        $keepAwakePrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
            -LogonType Interactive -RunLevel Limited

        if (Get-ScheduledTask -TaskName $devBoxTaskName -ErrorAction SilentlyContinue) {
            Set-ScheduledTask -TaskName $devBoxTaskName -Action $keepAwakeAction -Trigger $keepAwakeTriggers `
                -Settings $keepAwakeSettings -Principal $keepAwakePrincipal | Out-Null
        }
        else {
            Register-ScheduledTask -TaskName $devBoxTaskName -Action $keepAwakeAction -Trigger $keepAwakeTriggers `
                -Settings $keepAwakeSettings -Principal $keepAwakePrincipal `
                -Description 'Clears the pending Dev Box stop so the bridge is not hibernated mid-session.' | Out-Null
        }
        Start-ScheduledTask -TaskName $devBoxTaskName
        Write-Host "    registered; runs at logon and every ${devBoxIntervalHours}h"
    }
    catch {
        # Same reasoning as the daemon task: policy can forbid task creation, and the
        # rest of the install is still worth finishing.
        Write-Warning ("Could not register the '$devBoxTaskName' scheduled task: $($_.Exception.Message)`n" +
                       '    The bridge still works; this Dev Box may hibernate while it is running.')
    }
}
elseif ($script:BridgeIsWindows -and -not $TargetHome) {
    # Turned off, or never on: a task left by an earlier run would keep delaying the
    # stop forever with nothing in the config to explain why.
    if (Get-ScheduledTask -TaskName $devBoxTaskName -ErrorAction SilentlyContinue) {
        Write-Step "Removing the '$devBoxTaskName' scheduled task"
        Unregister-ScheduledTask -TaskName $devBoxTaskName -Confirm:$false
        Write-Host "    $($devBoxDecision.Reason)"
    }
}

# --------------------------------------------------------- configure adapters
# Claude, Codex and the MCP server reuse the shared layer just installed, so configure
# them by running their own installers. Each is idempotent and warns rather than fails
# if the client turns out not to be present.
foreach ($client in @('claude', 'codex', 'mcp')) {
    if ($selectedClients -notcontains $client) { continue }
    $adapterInstaller = Join-Path $repoRoot "$client\install-$client.ps1"
    if (-not (Test-Path -LiteralPath $adapterInstaller)) {
        Write-Warning "The $($script:ClientLabels[$client]) installer was not found at $adapterInstaller; skipping."
        continue
    }
    Write-Step "Configuring $($script:ClientLabels[$client])"
    try {
        if ($TargetHome) { & $adapterInstaller -TargetHome $TargetHome }
        else { & $adapterInstaller }
    }
    catch {
        Write-Warning "$($script:ClientLabels[$client]) did not configure cleanly: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------- the bridge command
# `agent-ha-bridge` on PATH is the answer to "how do I change this later". The
# installer payload goes next to it so the command has a real installer to run, even
# though the one-liner leaves nothing else behind.
Write-Step "Installing the agent-ha-bridge command"
$payloadCount = Copy-BridgeInstallerPayload -RepoRoot $repoRoot -Destination $installerDir
Write-Host "    installer payload -> $installerDir ($payloadCount item(s))"
$commandPath = Install-BridgeCommand -RepoRoot $repoRoot -BinDir $binDir
Write-Host "    $commandPath"

if ($SkipPath) {
    Write-Step 'Leaving PATH alone (-SkipPath)'
    Write-Host "    run it as $commandPath" -ForegroundColor DarkGray
}
elseif ($TargetHome) {
    # A sandbox install shares the user's PATH with the real one, so putting its bin
    # directory there would shadow the real command with a throwaway copy.
    Write-Step 'Leaving PATH alone (-TargetHome)'
    Write-Host "    run it as $commandPath" -ForegroundColor DarkGray
}
elseif (-not $script:BridgeIsWindows) {
    Write-Step 'Putting agent-ha-bridge on your PATH'
    if (Register-BridgeShellPath -Directory $binDir) {
        Write-Host "    added $binDir to PATH in $((Get-BridgeShellProfile | ForEach-Object { '~/' + (Split-Path -Leaf $_) }) -join ' and ')" -ForegroundColor Green
        Write-Host '    open a new terminal to use it there' -ForegroundColor DarkGray
    }
    else {
        Write-Host "    $binDir was already on PATH"
    }
    if (($env:PATH -split ':') -notcontains $binDir) { $env:PATH = "$binDir`:$env:PATH" }

    # The agent CLIs are linked into npm's own bin folder. On a MacPorts Mac that is
    # /opt/local/bin, which MacPorts does not reliably put on a bash user's PATH - so
    # they were "command not found" in the terminal they have to be signed in from,
    # immediately after this installer had installed them.
    $npmBinDir = Get-BridgeNpmBinDir
    if ($npmBinDir -and $npmBinDir -ne $binDir -and (Test-Path -LiteralPath $npmBinDir) -and
        (($env:PATH -split ':') -notcontains $npmBinDir)) {
        if (Register-BridgeShellPath -Directory $npmBinDir) {
            Write-Host "    added $npmBinDir, where the agent CLIs are, too" -ForegroundColor Green
        }
        $env:PATH = "$npmBinDir`:$env:PATH"
    }
}
else {
    Write-Step 'Putting agent-ha-bridge on your PATH'
    if (Register-BridgePathEntry -Directory $binDir) {
        Send-BridgeEnvironmentChange
        Write-Host "    added $binDir to the user PATH" -ForegroundColor Green
        Write-Host '    open a new terminal to use it there' -ForegroundColor DarkGray
    }
    else {
        Write-Host "    $binDir was already on the user PATH"
    }
    # Make it usable in this shell straight away, without waiting for a new terminal.
    $sessionPath = Add-BridgePathEntry -Current $env:PATH -Directory $binDir
    if ($sessionPath) { $env:PATH = $sessionPath }
}

# ------------------------------------------------------- add/remove programs
# No installer executable is needed for this: a per-user uninstall key is the same
# list Settings reads, and it avoids the SmartScreen warning an unsigned exe would
# produce. uninstall.ps1 is copied somewhere stable so the entry keeps working after
# the cloned repo is deleted.
if (-not (Test-Path -LiteralPath $bridgeHome)) { New-Item -ItemType Directory -Path $bridgeHome -Force | Out-Null }
Copy-Item (Join-Path $repoRoot 'uninstall.ps1') $bridgeHome -Force
$uninstallScript = Join-Path $bridgeHome 'uninstall.ps1'
if ($script:BridgeIsWindows) {
Write-Step 'Registering in Apps & features'

# A sandbox install must uninstall itself, not the real one, so the entry carries its
# own location. A normal install omits it and lets uninstall.ps1 use $HOME, which also
# keeps the machine-wide cleanup (scheduled task, daemon processes) enabled.
$uninstallArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$uninstallScript`" -ClearEntities"
if ($TargetHome) { $uninstallArgs += " -TargetHome `"$installHome`"" }
if ($TestRegistryId) { $uninstallArgs += " -TestRegistryId $TestRegistryId" }

New-Item -Path $arpKey -Force | Out-Null
$arpValues = @{
    DisplayName     = 'AI coding agent Home Assistant bridge'
    DisplayVersion  = $version
    Publisher       = 'agent-ha-bridge'
    InstallLocation = $bridgeHome
    URLInfoAbout    = 'https://github.com/danswett/agent-ha-bridge'
    # Windows gives this its own console and closes it the instant the script ends, so
    # without the pause every warning - and any outright failure - flashes past
    # unread. That matters here more than for most uninstallers, because a good deal
    # of the work happens in Home Assistant and can fail on its own.
    UninstallString = "pwsh.exe $uninstallArgs -Pause"
    # Deliberately without it: this one exists for unattended callers such as winget,
    # and a prompt would hang them forever.
    QuietUninstallString = "pwsh.exe $uninstallArgs"
}
foreach ($name in $arpValues.Keys) { Set-ItemProperty -Path $arpKey -Name $name -Value $arpValues[$name] }
Set-ItemProperty -Path $arpKey -Name NoModify -Value 1 -Type DWord
Set-ItemProperty -Path $arpKey -Name NoRepair -Value 1 -Type DWord
Write-Host "    'AI coding agent Home Assistant bridge' is now uninstallable from Settings"
}

Write-Step 'Done'
if (-not $SkipTask -and -not $taskRegistered) {
    Write-Host ''
    $service = if ($script:BridgeIsWindows) { 'its scheduled task' } else { 'its LaunchAgent' }
    Write-Host "The bridge daemon is NOT running: $service could not be registered." -ForegroundColor Red
    Write-Host 'Nothing below will work until that is fixed - see the warning above.' -ForegroundColor Red
}
Write-Host 'Next steps:' -ForegroundColor Yellow
$stepNo = 1
if ($selectedClients -contains 'copilot') {
    Write-Host "  $stepNo. Restart any running Copilot CLI sessions (/restart) so they pick up the hooks."
    $stepNo++
}
if ($selectedClients -contains 'claude') {
    Write-Host "  $stepNo. Restart any running Claude Code sessions so they pick up the hooks."
    $stepNo++
}
if ($selectedClients -contains 'codex') {
    Write-Host "  $stepNo. In Codex, trust the bridge hooks once when prompted, or they are skipped silently."
    $stepNo++
}
if ($selectedClients -contains 'mcp') {
    Write-Host "  $stepNo. MCP: a paste-ready client config is at ~/.agent-ha-bridge/mcp/mcp-client-config.json"
    Write-Host '        (Claude Desktop was configured automatically if present). See mcp/README.md for ChatGPT/HTTP.'
    $stepNo++
}
Write-Host "  $stepNo. Open the Agent Sessions dashboard in Home Assistant."
Write-Host "     Logs: $(Join-Path $env:TEMP 'agent-bridge-daemon.log') and agent-decision-bridge.log"
if (-not $script:BridgeIsWindows) {
    $stepNo++
    Write-Host "  $stepNo. macOS: the dashboard types replies into sessions running in tmux. Sessions it"
    Write-Host '        launches are; for ones you start yourself, run the agent inside tmux (tmux new claude).'
    Write-Host '        The first launch asks whether the bridge may control Terminal: allow it.'
}
Write-Host ''
Write-Host 'From now on, manage this install with the agent-ha-bridge command:' -ForegroundColor Yellow
Write-Host '  agent-ha-bridge status       what is installed, running and connected'
Write-Host '  agent-ha-bridge configure    change any of these answers'
Write-Host '  agent-ha-bridge update       move to a newer release'
Write-Host '  agent-ha-bridge help         everything else'
if ($selectedClients -notcontains 'mcp') {
    Write-Host ''
    Write-Host 'Want an MCP client too (Claude Desktop, Cursor, ChatGPT)? Run' -ForegroundColor DarkGray
    Write-Host '`agent-ha-bridge configure -Clients mcp`, or add it in the picker. See mcp/README.md.' -ForegroundColor DarkGray
}

# The verdict goes last, so it is what is left on screen. Until now the install ended
# on the same list of next steps whether or not any of it had worked: a recovered
# "Bootstrap failed" scrolling past looked like a broken install, and a genuinely
# broken one looked fine.
if (-not $SkipTask) {
    # The daemon is started by the task or LaunchAgent that was just registered, and
    # that takes a moment; a verdict of "not running" a second too early would be
    # wrong more often than right.
    for ($i = 0; $i -lt 15; $i++) {
        if (Get-BridgeDaemonProcess) { break }
        Start-Sleep -Milliseconds 400
    }
}
$health = Get-BridgeInstallHealth -Clients $selectedClients -ConnectionProbe {
    Test-BridgeHomeAssistantConnection -BaseUrl ([string]$config.homeAssistant.baseUrl) -Token $effectiveToken -TimeoutSec 10
}
# Printed, not exited on: this same script runs unattended for a self-update, and a
# missing tmux or a half-installed agent must not be reported as a failed update.
[void](Show-BridgeInstallVerdict -Checks $health)
