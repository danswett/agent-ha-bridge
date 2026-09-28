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
    Base URL of Home Assistant, e.g. http://homeassistant.local:8123

.PARAMETER Token
    A Home Assistant long-lived access token. Stored in the bridge config outside the
    repository. Omit it to keep an existing token, or to supply one via the
    AGENT_HA_TOKEN environment variable instead.

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

.PARAMETER NonInteractive
    Never prompt. Without this, the installer discovers Home Assistant on the network
    and asks for anything it still needs.

.EXAMPLE
    .\install.ps1 -HomeAssistantUrl http://homeassistant.local:8123 -Token 'eyJ...'

.EXAMPLE
    .\install.ps1 -HomeAssistantUrl http://ha.lan:8123 -Token 'eyJ...' -NotifyService notify.mobile_app_pixel

.EXAMPLE
    # Once installed, reconfigure from anywhere - no clone needed.
    agent-ha-bridge configure
#>

[CmdletBinding()]
param(
    [string]$HomeAssistantUrl,
    [string]$Token,
    [string]$NotifyService,
    [string]$TickerCategory,
    [string]$TargetHome,
    [string[]]$Clients,
    [switch]$SkipVerify,
    [switch]$SkipDependencies,
    [switch]$SkipPath,
    [switch]$NonInteractive,
    [switch]$SkipTask
)

$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
# Windows/macOS differences, before any path is built: on macOS it also makes
# Join-Path accept the Windows separators used throughout.
. (Join-Path $repoRoot 'hooks/bridge-platform.ps1')
. (Join-Path $repoRoot 'hooks/bridge-native-hook.ps1')
$installHome = if ($TargetHome) { $TargetHome } else { $HOME }

# The VERSION file is the single source of truth, so the Apps & features entry, the
# recorded config and the update check can never disagree about what is installed.
$versionFile = Join-Path $repoRoot 'VERSION'
$version = if (Test-Path -LiteralPath $versionFile) { (Get-Content -LiteralPath $versionFile -Raw).Trim() } else { '0.0.0' }
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
$taskName = 'AgentBridgeDaemon'
# The macOS counterpart of the scheduled task.
$launchAgentLabel = 'com.agent-ha-bridge.daemon'
$launchAgentPath = Join-Path $installHome "Library/LaunchAgents/$launchAgentLabel.plist"
# A sandbox install must not collide with the real Add/Remove Programs entry.
$arpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AgentHaBridge' +
          $(if ($TargetHome) { '_Sandbox' } else { '' })

# Pre-rename locations, still cleaned up on upgrade.
$legacySkillDir = Join-Path $copilotHome 'skills\decision-notifier'
$legacyHooksDir = Join-Path $copilotHome 'hooks'
$legacyConfigPath = Join-Path $copilotHome 'copilot-ha-bridge.config.json'
$legacyBridgeHome = Join-Path $copilotHome 'copilot-ha-bridge'
$legacyTaskName = 'CopilotBridgeDaemon'
$legacyArpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\CopilotHaBridge' +
                $(if ($TargetHome) { '_Sandbox' } else { '' })

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

function Get-BridgePwshPath {
    <#
        pwsh.exe, wherever it is. Get-Command alone is not enough straight after a
        winget install: this process's PATH predates it, so the well-known install
        locations are checked as well.
    #>
    $command = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
    foreach ($root in $roots) {
        $candidate = Join-Path $root 'PowerShell\7\pwsh.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    $null
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
        return [pscustomobject]@{ Config = $null; Error = $_.Exception.Message }
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
            if ($status) { return "HTTP $status - $($ErrorRecord.Exception.Message)" }
            return $ErrorRecord.Exception.Message
        }
    }
}

function Test-BridgeHomeAssistantConnection {
    <#
        Confirms that a URL and token really do talk to Home Assistant, and reports
        enough to show the user what they just connected to.

        Always returns an object rather than throwing, so the caller can offer another
        go at the token instead of ending the install on a typo.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$BaseUrl,
        [AllowEmptyString()][AllowNull()][string]$Token,
        [int]$TimeoutSec = 15
    )

    $base = ([string]$BaseUrl).TrimEnd('/')
    $result = [pscustomobject]@{
        Ok           = $false
        BaseUrl      = $base
        Message      = ''
        Version      = ''
        LocationName = ''
        MqttPublish  = $false
        Error        = ''
    }
    if ([string]::IsNullOrWhiteSpace($base)) { $result.Error = 'no Home Assistant URL'; return $result }
    if ([string]::IsNullOrWhiteSpace($Token)) { $result.Error = 'no Home Assistant token'; return $result }

    $headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' }
    try {
        $api = Invoke-RestMethod -Uri "$base/api/" -Headers $headers -TimeoutSec $TimeoutSec
        $result.Message = [string]$api.message
        $result.Ok = $true
    }
    catch {
        $result.Error = Get-BridgeHttpErrorDetail -ErrorRecord $_
        return $result
    }

    # Cosmetic, but it is what turns "it worked" into "it worked, and this is the
    # Home Assistant you are now attached to".
    try {
        $haConfig = Invoke-RestMethod -Uri "$base/api/config" -Headers $headers -TimeoutSec $TimeoutSec
        $result.Version = [string]$haConfig.version
        $result.LocationName = [string]$haConfig.location_name
    }
    catch { }

    # The MQTT integration is the one prerequisite the bridge cannot provision itself:
    # every per-session entity is published through the mqtt.publish service.
    try {
        $services = Invoke-RestMethod -Uri "$base/api/services" -Headers $headers -TimeoutSec ($TimeoutSec + 5)
        $mqtt = @($services) | Where-Object { $_.domain -eq 'mqtt' }
        $result.MqttPublish = [bool]($mqtt -and ($mqtt.services.PSObject.Properties.Name -contains 'publish'))
    }
    catch { }

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
    <# Best-effort detection so the picker can pre-select what is actually present. #>
    param([Parameter(Mandatory)][string]$Client)
    switch ($Client) {
        'copilot' { [bool](Get-Command copilot -ErrorAction SilentlyContinue) }
        'claude'  { [bool](Get-Command claude -ErrorAction SilentlyContinue) }
        'codex'   {
            if (Get-Command codex -ErrorAction SilentlyContinue) { return $true }
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

    try {
        $response = Invoke-WebRequest -Uri "$($BaseUrl.TrimEnd('/'))/manifest.json" `
            -TimeoutSec $TimeoutSec -SkipHttpErrorCheck -ErrorAction Stop
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

        The old flow discovered Home Assistant, printed what it found, and then asked
        for the URL anyway - an empty Enter being the right answer to a question that
        should never have been asked. Now a URL that answers as Home Assistant is
        simply used: the one already in the config first (a re-run should not re-probe
        a working install), then whatever discovery turns up. The prompt is the
        fallback for when neither works, and -HomeAssistantUrl still overrides
        everything.

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
    if ($configured -and (& $Probe $configured)) {
        return [pscustomobject]@{ Url = $configured; Source = 'config'; Prompted = $false }
    }

    $found = & $Discover
    if ($found) {
        return [pscustomobject]@{ Url = ([string]$found).TrimEnd('/'); Source = 'discovered'; Prompted = $false }
    }

    if (-not $Prompt) {
        return [pscustomobject]@{ Url = $configured; Source = 'unverified'; Prompted = $false }
    }
    $answer = ([string](& $Prompt $configured)).Trim().TrimEnd('/')
    if (-not $answer) { $answer = $configured }
    [pscustomobject]@{ Url = $answer; Source = 'typed'; Prompted = $true }
}

function Test-BridgeSecretFileProtected {
    <#
        True when a file is already locked to the current user alone: inheritance off,
        and exactly one allow rule granting this user full control.
    #>
    param([Parameter(Mandatory)][string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        # macOS: owner read/write and nothing else.
        if (-not $script:BridgeIsWindows) {
            return ([IO.File]::GetUnixFileMode($Path) -eq ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite))
        }
        $acl = Get-Acl -LiteralPath $Path
        if (-not $acl.AreAccessRulesProtected) { return $false }
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $rules = @($acl.Access)
        if ($rules.Count -ne 1) { return $false }
        $rule = $rules[0]
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { return $false }
        if ($rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -ne $me) { return $false }
        $full = [System.Security.AccessControl.FileSystemRights]::FullControl
        return (($rule.FileSystemRights -band $full) -eq $full)
    }
    catch { return $false }
}

function Protect-BridgeSecretFile {
    <#
        Restricts a file that holds the Home Assistant token to the current user, so
        another local account cannot read the token off disk. Best-effort by design: a
        machine with unusual ACL policy must not fail the whole install over this.

        Returns $true when the file ends up with inheritance disabled and no identity
        other than the current user granted access, so the behaviour is testable.

        The write goes through the .NET API rather than Set-Acl. Set-Acl asks for
        ACCESS_SYSTEM_SECURITY when the descriptor it is writing is protected, which a
        normal user does not have (SeSecurityPrivilege) - so every re-install of an
        already-hardened file failed with a warning, and a genuinely wrong ACL could
        never be repaired at all. Scoping the write to the Access section does not
        touch the SACL and needs no privilege.
    #>
    param([Parameter(Mandatory)][string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        # Nothing to do is the common case on a re-install, and rewriting an identical
        # descriptor is exactly what used to fail.
        if (Test-BridgeSecretFileProtected -Path $Path) { return $true }

        if (-not $script:BridgeIsWindows) {
            [IO.File]::SetUnixFileMode($Path, ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite))
            return (Test-BridgeSecretFileProtected -Path $Path)
        }

        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $file = Get-Item -LiteralPath $Path -Force
        $access = [System.Security.AccessControl.AccessControlSections]::Access
        $acl = [System.IO.FileSystemAclExtensions]::GetAccessControl($file, $access)
        # Disable inheritance and drop inherited rules, then strip every explicit rule
        # so only the single current-user grant below remains.
        $acl.SetAccessRuleProtection($true, $false)
        @($acl.Access) | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $me, 'FullControl', 'Allow')))
        [System.IO.FileSystemAclExtensions]::SetAccessControl($file, $acl)

        return (Test-BridgeSecretFileProtected -Path $Path)
    }
    catch {
        Write-Host "    note: could not restrict permissions on $(Split-Path $Path -Leaf) ($($_.Exception.Message))" -ForegroundColor Yellow
        return $false
    }
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
    }

    # The config carries the Home Assistant token, so moving it rather than rewriting
    # it from scratch is what keeps an upgrade from prompting all over again.
    if ((Test-Path -LiteralPath $LegacyConfigPath) -and -not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Once; $migrated = $true
        Move-Item -LiteralPath $LegacyConfigPath -Destination $ConfigPath -Force
        Write-Host "    config -> $ConfigPath"
    }
    if ((Test-Path -LiteralPath "$LegacyConfigPath.bak") -and -not (Test-Path -LiteralPath "$ConfigPath.bak")) {
        Move-Item -LiteralPath "$LegacyConfigPath.bak" -Destination "$ConfigPath.bak" -Force
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

        Never throws: a dashboard prerequisite is worth reporting, not worth failing
        an otherwise good install over.
    #>
    param(
        [Parameter(Mandatory)][string]$HooksDir,
        [Parameter(Mandatory)][string]$ConfigPath,
        [switch]$Register
    )

    $checker = Join-Path $HooksDir 'bridge-frontend-cards.ps1'
    if (-not (Test-Path -LiteralPath $checker)) { return $false }

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
    $out = @(& launchctl bootstrap $domain $PlistPath 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) {
        foreach ($line in $out) { Write-Host "    $line" -ForegroundColor DarkGray }
        # The older API takes jobs bootstrap has been known to refuse.
        $out = @(& launchctl load -w $PlistPath 2>&1 | ForEach-Object { [string]$_ })
        foreach ($line in $out) { Write-Host "    $line" -ForegroundColor DarkGray }
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
    if ($PSBoundParameters.ContainsKey('Token') -and $Token) {
        throw ("PowerShell 7 is ready at $pwshPath, but -Token is not forwarded to it: a " +
               "command line is readable by every process on the machine. Re-run there " +
               "yourself:`n    & '$pwshPath' -NoProfile -File '$PSCommandPath' -Token '<token>'")
    }

    Write-Step "Restarting under PowerShell 7 ($pwshPath)"
    $forwarded = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath) +
                 @(ConvertTo-BridgeArgumentList -BoundParameters $PSBoundParameters -Exclude @('Token'))
    & $pwshPath @forwarded
    exit $LASTEXITCODE
}
if (-not (Test-Path -LiteralPath $bridgeHome)) {
    New-Item -ItemType Directory -Path $bridgeHome -Force | Out-Null
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
    Copy-Item $configPath "$configPath.bak" -Force
    [void](Protect-BridgeSecretFile -Path "$configPath.bak")
    Write-Host "    backed up existing config to $(Split-Path $configPath -Leaf).bak"

    $read = Read-BridgeConfigFile -Path $configPath
    if ($read.Config) { $config = $read.Config }
    else {
        Write-Warning ("$configPath could not be read ($($read.Error)). Starting from the " +
                       "defaults; your previous file is at $(Split-Path $configPath -Leaf).bak.")
        # A config that cannot be read holds no remembered answers either.
        $configExisted = $false
    }
}
# Parsed separately rather than reusing $defaults: a fresh install would otherwise
# merge an object into itself, and every later edit would mutate the defaults too.
if (-not $config) { $config = $exampleRaw | ConvertFrom-Json }

# A config from an older version is missing keys this installer reaches straight into.
$filled = @(Merge-BridgeConfigDefaults -Config $config -Defaults $defaults)
if ($filled) { Write-Host "    added missing setting(s): $($filled -join ', ')" }

if ($PSBoundParameters.ContainsKey('HomeAssistantUrl') -and $HomeAssistantUrl) {
    $config.homeAssistant.baseUrl = $HomeAssistantUrl.TrimEnd('/')
}
if ($PSBoundParameters.ContainsKey('Token') -and $Token) {
    $config.homeAssistant.token = $Token
}
if ($PSBoundParameters.ContainsKey('NotifyService') -and $NotifyService) {
    $config.notifications.enabled = $true
    $config.notifications.service = $NotifyService
}
if ($PSBoundParameters.ContainsKey('TickerCategory') -and $TickerCategory) {
    $config.notifications.tickerCategory = $TickerCategory
}

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
    $resolvedUrl = Resolve-BridgeHomeAssistantUrl -Configured $config.homeAssistant.baseUrl -Prompt $urlPrompt
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
$base = ([string]$config.homeAssistant.baseUrl).TrimEnd('/')
if ($base -match '^http://' -and $base -notmatch '^http://(localhost|127\.0\.0\.1|\[::1\])') {
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
        $entered = Read-Host '    Paste the token here'
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

# Record what was installed, so the update check can compare against the newest
# release without guessing.
if (-not $config.PSObject.Properties.Name.Contains('updates')) {
    $config | Add-Member -NotePropertyName 'updates' -NotePropertyValue ([pscustomobject]@{
        repository = 'danswett/agent-ha-bridge'; installedVersion = ''; checkForUpdates = $true
    })
}
$config.updates.installedVersion = $version

Write-Step "Writing bridge config to $configPath"
$config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding UTF8
# The token lives here; keep it readable only by the current user and out of any
# shared listing.
[void](Protect-BridgeSecretFile -Path $configPath)
Write-Host "    baseUrl      : $($config.homeAssistant.baseUrl)"
Write-Host "    token        : $(if ($config.homeAssistant.token) { 'set in config' } else { "from `$env:$($config.homeAssistant.tokenEnvVar)" })"
Write-Host "    notifications: $(if ($config.notifications.enabled) { $config.notifications.service } else { 'disabled' })"

# The dashboard is drawn with three custom Lovelace cards. Without them it renders as
# a column of "Custom element doesn't exist" boxes - an install that reports success
# and then visibly does not work. The file itself can only come from HACS, but a card
# that is downloaded and merely unregistered is repaired here.
if ($homeAssistantReady) {
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
        Write-Host "    PowerShell hooks: Copilot $(if ($copilotVersion) { $copilotVersion } else { 'not found' }) is older than $($script:BridgeCopilotExecMinVersion), the first seen to run the native hook" -ForegroundColor DarkGray
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
}
elseif (Test-Path -LiteralPath $hookConfigPath) {
    # Copilot is not configured, so a definition left over from an earlier run would
    # point the CLI at scripts this install has just moved out from under it.
    Write-Step 'Removing the stale Copilot hook definition'
    Remove-Item -LiteralPath $hookConfigPath -Force -ErrorAction SilentlyContinue
    Write-Host "    $hookConfigPath"
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
