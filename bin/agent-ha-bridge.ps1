<#
.SYNOPSIS
    The `agent-ha-bridge` command.

.DESCRIPTION
    Installing the bridge puts this on your PATH, so everything you might want to do
    to an existing install is one command away - above all reconfiguring it.

    That used to be the weakest part of the install. The documented answer was to
    re-run install.ps1 with arguments, which only works if you installed from a clone;
    everyone who used the one-liner had nothing left on disk to re-run, and
    bootstrap.ps1 takes no arguments. The installer now copies itself to
    ~/.agent-ha-bridge/installer, and this dispatches to it.

    Commands:

      configure   Re-run the installer interactively, keeping your current settings
                  as the defaults. Extra arguments are passed straight through, so
                  `agent-ha-bridge configure -Clients copilot,claude` works too.
      status      Where everything is, whether the daemon is running, and whether
                  Home Assistant answers.
      restart     Restart the bridge daemon.
      logs        Tail the daemon log.
      update      Check for a newer release and offer to install it.
      uninstall   Remove the bridge. Entities for this machine go with it; the
                  dashboard and Detailed activity toggle are shared, so they only
                  go when this is the last machine.
      version     Print the installed version.
      help        This text.

    `--configure`, `-configure` and `/configure` are all accepted, for whichever
    convention is in your fingers.

.PARAMETER Command
    The command to run. Defaults to `status`.

.PARAMETER Arguments
    Anything after the command, passed through to the underlying script.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command,
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Arguments
)

$ErrorActionPreference = 'Stop'

# The installed layout is <bridge home>/bin/this.ps1 with the installer next door; a
# clone has bin/this.ps1 with install.ps1 in the parent. Support both, so the command
# can be run straight out of the repository.
$root = Split-Path -Parent $PSScriptRoot
$installerDir = Join-Path $root 'installer'
$isInstalled = Test-Path -LiteralPath (Join-Path $installerDir 'install.ps1')
if (-not $isInstalled) { $installerDir = $root }

# The install this command belongs to is the one it was installed into, not whichever
# one happens to live in $HOME. That distinction is what stops a sandbox install's
# copy of this command from operating on the real install. A clone is not an install,
# so running out of the repository still means $HOME.
$bridgeHome = if ($isInstalled) { $root } else { Join-Path $HOME '.agent-ha-bridge' }
# Windows/macOS differences - $env:TEMP, process lookups - from this install's hooks.
$platform = Join-Path (Join-Path $root 'hooks') 'bridge-platform.ps1'
if (Test-Path -LiteralPath $platform) { . $platform }
else { $script:BridgeIsWindows = [bool]$IsWindows }
$configPath = Join-Path $bridgeHome 'config.json'
$taskName = 'AgentBridgeDaemon'
$launchAgentLabel = 'com.agent-ha-bridge.daemon'
# pwsh beside this one: pwsh.exe on Windows, pwsh elsewhere.
$pwshHere = Join-Path $PSHOME $(if ($script:BridgeIsWindows) { 'pwsh.exe' } else { 'pwsh' })
$daemonLog = Join-Path $env:TEMP 'agent-bridge-daemon.log'

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }

function Invoke-BridgeScript {
    <#
        Runs one of the payload scripts with the arguments the user typed, and exits
        with its exit code.

        Through a child pwsh rather than the call operator, because `& $script @array`
        splats *positionally*: `agent-ha-bridge configure -Clients copilot,claude`
        would bind the string "-Clients" to the installer's first positional
        parameter rather than naming one. `pwsh -File` parses the arguments exactly as
        typing the command by hand would.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Passthrough = @()
    )
    $pwsh = $pwshHere
    if (-not (Test-Path -LiteralPath $pwsh)) { $pwsh = 'pwsh' }
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File $Path @Passthrough
    exit $LASTEXITCODE
}

function Get-InstalledVersion {
    foreach ($candidate in @(
        (Join-Path $bridgeHome 'hooks\VERSION'),
        (Join-Path $installerDir 'VERSION')
    )) {
        if (Test-Path -LiteralPath $candidate) { return (Get-Content -LiteralPath $candidate -Raw).Trim() }
    }
    'unknown'
}

function Get-BridgeScript {
    <# A script from the installer payload, with a clear error when it is missing. #>
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path $installerDir $Name
    if (-not (Test-Path -LiteralPath $path)) {
        throw ("$Name was not found at $path. Re-install the bridge with: " +
               'irm https://raw.githubusercontent.com/danswett/agent-ha-bridge/main/bootstrap.ps1 | iex')
    }
    $path
}

function Show-Help {
    Write-Host 'agent-ha-bridge - the AI coding agent <-> Home Assistant bridge' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Usage: agent-ha-bridge <command> [options]'
    Write-Host ''
    Write-Host '  configure    Re-run the installer, keeping your settings as defaults'
    Write-Host '  status       Show the install, the daemon and the Home Assistant connection'
    Write-Host '  restart      Restart the bridge daemon'
    Write-Host '  logs         Tail the daemon log (-Lines N, -Follow)'
    Write-Host '  update       Check for a newer release and offer to install it'
    Write-Host '  uninstall    Remove the bridge (-KeepConfig, -ClearShared, -KeepShared)'
    Write-Host '  version      Print the installed version'
    Write-Host '  help         This text'
    Write-Host ''
    Write-Host 'Examples:' -ForegroundColor Yellow
    Write-Host '  agent-ha-bridge configure'
    Write-Host '  agent-ha-bridge configure -Clients copilot,claude'
    Write-Host '  agent-ha-bridge logs -Follow'
}

function Show-HomeAssistantStatus {
    <#
        Reuses the installer's own connection check, so status and install can never
        disagree about what "connected" means.

        The dot-source happens inside this function on purpose: install.ps1 assigns
        $bridgeHome, $configPath and friends at its script level, and dot-sourcing it
        at the caller's scope would silently rebind them to $HOME.

        The values are copied into names install.ps1 does not use first. Dot-sourcing
        a script also rebinds every parameter it *declares* to that parameter's
        default, and install.ps1 declares -Token - so reading $Token after the
        dot-source yields an empty string and the check reports "no token" for a
        perfectly good one.
    #>
    param(
        [AllowEmptyString()][AllowNull()][string]$BaseUrl,
        [AllowEmptyString()][AllowNull()][string]$Token,
        [Parameter(Mandatory)][string]$InstallerPath
    )
    $checkUrl = [string]$BaseUrl
    $checkToken = [string]$Token

    $env:BRIDGE_INSTALL_NORUN = '1'
    try {
        . $InstallerPath
        Write-BridgeConnectionResult -Result (
            Test-BridgeHomeAssistantConnection -BaseUrl $checkUrl -Token $checkToken)
    }
    finally { Remove-Item Env:\BRIDGE_INSTALL_NORUN -ErrorAction SilentlyContinue }
}

function Show-Status {
    Write-Host 'agent-ha-bridge' -ForegroundColor Cyan
    Write-Host "    version    : $(Get-InstalledVersion)"
    Write-Host "    install    : $bridgeHome"
    Write-Host "    config     : $configPath"

    if (-not (Test-Path -LiteralPath $configPath)) {
        Write-Host '    config     : missing - run `agent-ha-bridge configure`' -ForegroundColor Yellow
        return
    }

    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $clients = @()
    if ($config.PSObject.Properties['clients']) { $clients = @($config.clients) }
    Write-Host "    clients    : $(if ($clients) { $clients -join ', ' } else { 'none recorded' })"

    $task = if ($script:BridgeIsWindows) { Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } else { $null }
    if (-not $script:BridgeIsWindows -and -not (Get-Command Get-BridgeProcessesNamed -ErrorAction SilentlyContinue)) {
        Write-Host '    daemon     : unknown - the install''s hooks are missing; run agent-ha-bridge configure' -ForegroundColor Yellow
    }
    elseif (-not $script:BridgeIsWindows) {
        $loaded = [bool](& launchctl print "gui/$(& id -u)/$launchAgentLabel" 2>$null)
        $daemon = @(Get-BridgeProcessesNamed -Name 'pwsh' | Where-Object { $_.CommandLine -match 'agent-bridge-daemon\.ps1' })
        if ($daemon) { Write-Host "    daemon     : running (pid $($daemon[0].ProcessId))" -ForegroundColor Green }
        elseif ($loaded) { Write-Host '    daemon     : not running - launchd will start it again shortly' -ForegroundColor Yellow }
        else { Write-Host "    daemon     : the '$launchAgentLabel' LaunchAgent is not loaded - run agent-ha-bridge configure" -ForegroundColor Yellow }
        if (-not (Get-BridgeTmuxPath)) { Write-Host '    tmux       : not installed - replies from the dashboard need it (brew install tmux)' -ForegroundColor Yellow }
    }
    elseif ($task) {
        $daemon = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'agent-bridge-daemon\.ps1' })
        if ($daemon) {
            Write-Host "    daemon     : running (pid $($daemon[0].ProcessId))" -ForegroundColor Green
        }
        else {
            Write-Host "    daemon     : not running - task state $($task.State)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "    daemon     : the '$taskName' scheduled task is not registered" -ForegroundColor Yellow
    }

    $base = ([string]$config.homeAssistant.baseUrl).TrimEnd('/')
    $token = [string]$config.homeAssistant.token
    if (-not $token -and $config.homeAssistant.tokenEnvVar) {
        $token = [Environment]::GetEnvironmentVariable([string]$config.homeAssistant.tokenEnvVar)
    }

    $slug = 'agent-decisions'
    if ($config.PSObject.Properties['dashboard'] -and $config.dashboard.urlPath) {
        $slug = [string]$config.dashboard.urlPath
    }
    Write-Host "    dashboard  : $base/$slug"

    Write-Host '    home assistant:'
    try {
        Show-HomeAssistantStatus -BaseUrl $base -Token $token -InstallerPath (Get-BridgeScript 'install.ps1')
    }
    catch {
        Write-Host "    could not check the connection: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Read-only here: status reports, configure repairs.
    $cardCheck = Join-Path $bridgeHome 'hooks\bridge-frontend-cards.ps1'
    if (Test-Path -LiteralPath $cardCheck) {
        Write-Host '    dashboard cards:'
        $previous = $env:AGENT_HA_BRIDGE_CONFIG
        $env:AGENT_HA_BRIDGE_CONFIG = $configPath
        try { & $pwshHere -NoProfile -ExecutionPolicy Bypass -File $cardCheck }
        catch { Write-Host "    could not check the dashboard cards: $($_.Exception.Message)" -ForegroundColor Yellow }
        finally {
            if ($null -eq $previous) { Remove-Item Env:\AGENT_HA_BRIDGE_CONFIG -ErrorAction SilentlyContinue }
            else { $env:AGENT_HA_BRIDGE_CONFIG = $previous }
        }
    }

    Show-BridgeMachines -HooksDir (Join-Path $bridgeHome 'hooks') -ConfigPath $configPath
}

function Show-BridgeMachines {
    <#
        Every machine sharing this Home Assistant, and whether it is running.

        There was no way to see this outside the dashboard, which is precisely the
        wrong place to look when the question is "why is the dashboard showing
        something odd" - or when a machine you expected to be there is missing.

        Run in a child pwsh pointed at this install's config, so the runtime layer is
        loaded against the right instance and nothing is left dot-sourced here.
    #>
    param([Parameter(Mandatory)][string]$HooksDir, [Parameter(Mandatory)][string]$ConfigPath)

    if (-not (Test-Path -LiteralPath (Join-Path $HooksDir 'decision-mqtt.ps1'))) { return }

    $script = @'
param([string]$HooksDir)
$ErrorActionPreference = 'Stop'
. (Join-Path $HooksDir 'decision-bridge-common.ps1')
. (Join-Path $HooksDir 'decision-mqtt.ps1')
$headers = Get-HomeAssistantHeaders
$states = Invoke-DecisionHttpRequest -Parameters @{
    Method = 'Get'
    Uri = "$($script:DecisionBridgeConfig.HomeAssistantBaseUrl)/api/states"
    Headers = $headers
    TimeoutSec = 15
}
$peers = @(Get-BridgePeerMachine -States $states)
if ($peers.Count -eq 0) { Write-Host '    none registered yet'; return }
foreach ($p in ($peers | Sort-Object Slug)) {
    $mark = if ($p.Online) { 'online ' } else { 'offline' }
    $self = if ($p.IsSelf) { ' (this machine)' } else { '' }
    $count = @($p.Sessions).Count
    Write-Host ("    {0}  {1,-18} {2} session(s){3}" -f $mark, $p.Machine, $count, $self)
}
# Only an older bridge still publishes these, and it also rebuilds the shared
# dashboard from its own sessions alone - so it quietly overwrites everyone else's.
$stale = @($states | Where-Object {
    $_.entity_id -in @('sensor.agent_bridge_sessions', 'button.agent_bridge_new_session')
})
if ($stale.Count) {
    Write-Host '    a machine is running a bridge older than 1.6.0 - upgrade it, or it will' -ForegroundColor Yellow
    Write-Host '    keep replacing the shared dashboard with its own sessions only' -ForegroundColor Yellow
}
'@
    $temp = Join-Path ([IO.Path]::GetTempPath()) "bridge-machines-$([guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
    $previous = $env:AGENT_HA_BRIDGE_CONFIG
    try {
        Set-Content -LiteralPath $temp -Value $script -Encoding UTF8
        $env:AGENT_HA_BRIDGE_CONFIG = $ConfigPath
        Write-Host '    machines:'
        & $pwshHere -NoProfile -ExecutionPolicy Bypass -File $temp -HooksDir $HooksDir
    }
    catch { Write-Host "    could not list the machines: $($_.Exception.Message)" -ForegroundColor Yellow }
    finally {
        if ($null -eq $previous) { Remove-Item Env:\AGENT_HA_BRIDGE_CONFIG -ErrorAction SilentlyContinue }
        else { $env:AGENT_HA_BRIDGE_CONFIG = $previous }
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Restart {
    Write-Step 'Restarting the bridge daemon'
    if (-not $script:BridgeIsWindows) {
        $target = "gui/$(& id -u)/$launchAgentLabel"
        & launchctl kickstart -k $target 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "The '$launchAgentLabel' LaunchAgent is not loaded. Run: agent-ha-bridge configure" }
        Write-Host '    restarted' -ForegroundColor Green
        return
    }
    if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
        throw "The '$taskName' scheduled task is not registered. Run: agent-ha-bridge configure"
    }
    # The daemon is detached from the task, so stopping the task alone leaves it
    # running; kill it and let the supervisor bring up a fresh one.
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'agent-bridge-(daemon|supervisor)\.ps1' } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Host "    stopped pid $($_.ProcessId)"
        }
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $taskName
    Write-Host '    started' -ForegroundColor Green
}

function Show-Logs {
    param([string[]]$Passthrough)
    $lines = 60
    $follow = $false
    $list = @($Passthrough)
    for ($i = 0; $i -lt $list.Count; $i++) {
        if ($list[$i] -match '^[-/]{1,2}f(ollow)?$') { $follow = $true }
        elseif ($list[$i] -match '^[-/]{1,2}l(ines)?$') {
            $i++
            if ($i -lt $list.Count) { $lines = [int]$list[$i] }
        }
    }
    if (-not (Test-Path -LiteralPath $daemonLog)) {
        Write-Host "No daemon log yet at $daemonLog" -ForegroundColor Yellow
        return
    }
    Write-Host $daemonLog -ForegroundColor DarkGray
    if ($follow) { Get-Content -LiteralPath $daemonLog -Tail $lines -Wait }
    else { Get-Content -LiteralPath $daemonLog -Tail $lines }
}

$script:Verbs = [ordered]@{
    configure = @('configure', 'reconfigure', 'config', 'setup')
    status    = @('status', 'info')
    restart   = @('restart')
    logs      = @('logs', 'log')
    update    = @('update')
    uninstall = @('uninstall', 'remove')
    version   = @('version', 'v')
    help      = @('help', 'h', '?')
}

function Resolve-BridgeVerb {
    <# The canonical verb for a token, or '' when it names nothing. #>
    param([AllowEmptyString()][AllowNull()][string]$Token)
    $clean = ([string]$Token).Trim().TrimStart('-', '/').ToLowerInvariant()
    if (-not $clean) { return '' }
    foreach ($verb in $script:Verbs.Keys) {
        if ($script:Verbs[$verb] -contains $clean) { return $verb }
    }
    ''
}

$verb = Resolve-BridgeVerb $Command
$passthrough = @($Arguments | Where-Object { $_ })

# `agent-ha-bridge --configure` is the shape most fingers produce, but PowerShell
# binds a leading -configure as a parameter *name*, so it never reaches $Command - it
# is swept into $Arguments instead, and the command would quietly show status. Promote
# it when nothing else claimed the verb.
if (-not $verb -and -not $Command -and $passthrough.Count) {
    $promoted = Resolve-BridgeVerb $passthrough[0]
    if ($promoted) {
        $verb = $promoted
        $passthrough = @($passthrough | Select-Object -Skip 1)
    }
}
if (-not $verb -and $Command) {
    Write-Host "Unknown command '$Command'." -ForegroundColor Red
    Write-Host ''
    Show-Help
    exit 2
}
if (-not $verb) { $verb = 'status' }

switch ($verb) {
    'configure' {
        $installer = Get-BridgeScript 'install.ps1'
        Write-Step 'Reconfiguring the bridge'
        Write-Host "    $installer" -ForegroundColor DarkGray
        Invoke-BridgeScript -Path $installer -Passthrough $passthrough
        break
    }
    'status' { Show-Status; break }
    'restart' { Invoke-Restart; break }
    'logs' { Show-Logs -Passthrough $passthrough; break }
    'update' { Invoke-BridgeScript -Path (Get-BridgeScript 'update.ps1') -Passthrough $passthrough; break }
    'uninstall' {
        # The copy beside the config is the one that matches this install; the payload
        # is the fallback for an install that predates it.
        $uninstaller = Join-Path $bridgeHome 'uninstall.ps1'
        if (-not (Test-Path -LiteralPath $uninstaller)) { $uninstaller = Get-BridgeScript 'uninstall.ps1' }
        if (-not $passthrough) { $passthrough = @('-ClearEntities') }
        Invoke-BridgeScript -Path $uninstaller -Passthrough $passthrough
        break
    }
    'version' { Get-InstalledVersion; break }
    'help' { Show-Help; break }
}
