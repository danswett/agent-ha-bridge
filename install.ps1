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
        'npm' { return "npm install -g $($dep.Package)" }
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
            # Codex ships through npm and is not on PATH, so look where npm installs it.
            Test-Path -LiteralPath (Join-Path $env:APPDATA 'npm\node_modules\@openai\codex')
        }
        'mcp'     {
            # There is no single "MCP client", but Claude Desktop is the one this can
            # configure automatically, so its presence is the useful pre-select hint.
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

function Find-HomeAssistant {
    <#
        Locates Home Assistant on the local network.

        Home Assistant publishes itself as homeassistant.local over mDNS, which Windows
        resolves natively, so the default hostname plus its resolved address covers
        almost every install. Anything more exotic is a typed URL. No subnet scanning:
        it is slow and looks like hostile traffic.
    #>
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($hostName in @('homeassistant.local', 'homeassistant')) {
        $candidates.Add("http://${hostName}:8123")
    }
    try {
        $resolved = Resolve-DnsName -Name 'homeassistant.local' -Type A -ErrorAction Stop
        foreach ($address in @($resolved | Where-Object IPAddress | Select-Object -Expand IPAddress)) {
            $candidates.Add("http://${address}:8123")
        }
    }
    catch { }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
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

function Protect-BridgeSecretFile {
    <#
        Restricts a file that holds the Home Assistant token to the current user, so
        another local account cannot read the token off disk. Best-effort by design: a
        machine with unusual ACL policy must not fail the whole install over this.

        Returns $true when the file ended up with inheritance disabled and no identity
        other than the current user granted access, so the behaviour is testable.
    #>
    param([Parameter(Mandatory)][string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = Get-Acl -LiteralPath $Path
        # Disable inheritance and drop inherited rules, then strip every explicit rule
        # so only the single current-user grant below remains.
        $acl.SetAccessRuleProtection($true, $false)
        @($acl.Access) | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $me, 'FullControl', 'Allow')))
        Set-Acl -LiteralPath $Path -AclObject $acl

        $check = (Get-Acl -LiteralPath $Path).Access
        return -not ($check | Where-Object {
            $_.IsInherited -or $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -ne $me
        })
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

# ------------------------------------------------------- installer payload
# So that an install can be reconfigured, updated or removed from a machine that
# never had the repository - which is every machine installed from the one-liner.

# What `agent-ha-bridge configure` needs to re-run a full install. node_modules is
# excluded: the MCP installer runs npm itself, and copying it would dwarf everything
# else here.
$script:BridgePayloadFiles = @('install.ps1', 'uninstall.ps1', 'update.ps1', 'config.example.json', 'VERSION')
$script:BridgePayloadDirs = @('hooks', 'bin', 'claude', 'codex', 'mcp')

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
    foreach ($name in @('agent-ha-bridge.ps1', 'agent-ha-bridge.cmd')) {
        $from = Join-Path (Join-Path $RepoRoot 'bin') $name
        if (-not (Test-Path -LiteralPath $from)) { throw "The bridge command source $from is missing." }
        Copy-Item -LiteralPath $from -Destination $BinDir -Force
    }
    Join-Path $BinDir 'agent-ha-bridge.cmd'
}

# Tests dot-source this script with BRIDGE_INSTALL_NORUN set to load its helper
# functions without running the install; a real run never sets it.
if ($env:BRIDGE_INSTALL_NORUN) { return }

if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
    throw 'This bridge is Windows-only: reply injection uses AttachConsole/WriteConsoleInput.'
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
    -LegacyTaskName $legacyTaskName -SkipMachineWide:([bool]$TargetHome)

# ---------------------------------------------------------------- hook scripts
Write-Step "Copying hook scripts to $hooksDir"
if (-not (Test-Path -LiteralPath $hooksDir)) { New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null }
Get-ChildItem (Join-Path $repoRoot 'hooks') -File | ForEach-Object {
    Copy-Item $_.FullName $hooksDir -Force
    Write-Host "    $($_.Name)"
}

if (Test-Path -LiteralPath $versionFile) { Copy-Item $versionFile $hooksDir -Force }

# --------------------------------------------------------------------- config
Write-Step 'Reading the bridge config'
# Whether this is a first install decides whether a remembered client selection
# exists at all. config.example.json is a template, not a previous answer.
$configExisted = Test-Path -LiteralPath $configPath
$config = if ($configExisted) {
    # Never lose a working config to a mistyped re-run.
    Copy-Item $configPath "$configPath.bak" -Force
    [void](Protect-BridgeSecretFile -Path "$configPath.bak")
    Write-Host "    backed up existing config to $(Split-Path $configPath -Leaf).bak"
    Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
else {
    Get-Content -LiteralPath (Join-Path $repoRoot 'config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
}

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
    while (-not $connection.Ok -and -not $NonInteractive -and $remaining -gt 0) {
        $remaining--
        if ($effectiveToken) { Write-BridgeConnectionResult -Result $connection }
        Write-Host ''
        Write-Host 'Home Assistant needs a long-lived access token.' -ForegroundColor Yellow
        Write-Host "    1. Open $base/profile/security"
        Write-Host '    2. Scroll to "Long-lived access tokens" and choose "Create token"'
        Write-Host '    3. Name it anything (e.g. "agent bridge") and copy the value'
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
if (-not $SkipTask) {
    Write-Step "Registering the '$taskName' scheduled task"
    # wscript + the VBS launcher, not pwsh directly: WScript.Shell.Run(..., 0, False)
    # starts the supervisor with no window at all, while still giving the daemon a real
    # console. conhost --headless would give a pseudoconsole and break reply injection.
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
    Start-ScheduledTask -TaskName $taskName
    Write-Host "    registered and started"
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
Write-Step 'Registering in Apps & features'
if (-not (Test-Path -LiteralPath $bridgeHome)) { New-Item -ItemType Directory -Path $bridgeHome -Force | Out-Null }
Copy-Item (Join-Path $repoRoot 'uninstall.ps1') $bridgeHome -Force
$uninstallScript = Join-Path $bridgeHome 'uninstall.ps1'

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
    UninstallString = "pwsh.exe $uninstallArgs"
    QuietUninstallString = "pwsh.exe $uninstallArgs"
}
foreach ($name in $arpValues.Keys) { Set-ItemProperty -Path $arpKey -Name $name -Value $arpValues[$name] }
Set-ItemProperty -Path $arpKey -Name NoModify -Value 1 -Type DWord
Set-ItemProperty -Path $arpKey -Name NoRepair -Value 1 -Type DWord
Write-Host "    'AI coding agent Home Assistant bridge' is now uninstallable from Settings"

Write-Step 'Done'
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
Write-Host "     Logs: `$env:TEMP\agent-bridge-daemon.log and agent-decision-bridge.log"
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
