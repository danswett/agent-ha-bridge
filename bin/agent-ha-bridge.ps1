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
                  `agent-ha-bridge configure -Clients copilot,claude` and
                  `agent-ha-bridge configure -Workspace ~/repos,~/work` work too.
                  Separate several values with commas and no spaces: arguments arrive
                  here as literal strings, so a space would start a new one.
      pair        Join this machine to the fleet: shows a six-digit code to type into
                  Home Assistant, then receives the fleet secret from a machine
                  already in it, and turns session sharing on.
      secret show Print this machine's fleet secret, for the paste fallback.
      secret rotate
                  Replace the fleet secret, to remove a machine or after a leak; the
                  other machines re-pair with agent-ha-bridge pair.
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
$commandContext = if (Get-Command Resolve-BridgeInstallContext -ErrorAction SilentlyContinue) {
    if ($isInstalled) { Resolve-BridgeInstallContext -BridgeHome $bridgeHome }
    else { Resolve-BridgeInstallContext }
} else { $null }
$configPath = if ($commandContext) { $commandContext.ConfigPath } else { Join-Path $bridgeHome 'config.json' }
$taskName = if ($commandContext) { $commandContext.TaskName } else { '' }
$launchAgentLabel = if ($commandContext) { $commandContext.LaunchAgentLabel } else { '' }
# pwsh beside this one: pwsh.exe on Windows, pwsh elsewhere.
$pwshHere = Join-Path $PSHOME $(if ($script:BridgeIsWindows) { 'pwsh.exe' } else { 'pwsh' })
$daemonLog = if ($commandContext) { Get-BridgeRuntimePath -Name 'agent-bridge-daemon.log' -Context $commandContext } else { '' }

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
    if (-not $commandContext) { throw 'The installation root helper is missing. Restore the installer payload before changing this installation.' }
    $targetArguments = @()
    if ($isInstalled) {
        if (@($Passthrough | Where-Object { $_ -match '^-(TargetHome|InstallRoot)(:|$)' }).Count) {
            throw 'An installed command cannot be retargeted to another installation.'
        }
        $targetArguments = @('-InstallRoot', $commandContext.BridgeHome)
        if ($commandContext.Isolated) { $targetArguments += @('-TargetHome', $commandContext.Home) }
    }
    $savedConfig = $env:AGENT_HA_BRIDGE_CONFIG
    try {
        $env:AGENT_HA_BRIDGE_CONFIG = $commandContext.ConfigPath
        & $pwsh -NoProfile -ExecutionPolicy Bypass -File $Path @Passthrough @targetArguments
        $exitCode = $LASTEXITCODE
    }
    finally { $env:AGENT_HA_BRIDGE_CONFIG = $savedConfig }
    exit $exitCode
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
    Write-Host '  pair         Join this machine to the fleet, so sessions can move between machines'
    Write-Host '  secret show  Print the fleet secret, for pasting where pairing cannot run'
    Write-Host '  secret rotate  Replace the fleet secret; the other machines then re-pair'
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
    Write-Host '  agent-ha-bridge configure -Workspace ~/repos,~/work'    Write-Host '  agent-ha-bridge logs -Follow'
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
    if (-not $commandContext) { throw 'Installation helpers are missing; restore the installer payload to read its status safely.' }
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

    # The daemon writes its own pid to the heartbeat every pass, so the usual answer
    # costs a file read. Scanning command lines for it costs 272 ms on Windows, and
    # is kept only for when the heartbeat cannot answer - it is the difference
    # between "no heartbeat" and "not running", which are not the same thing.
    $daemonPid = Get-BridgeStatusDaemonPid -HooksDir (Join-Path $bridgeHome 'hooks')
    if (-not $script:BridgeIsWindows -and -not (Get-Command Get-BridgeProcessesNamed -ErrorAction SilentlyContinue)) {
        Write-Host '    daemon     : unknown - the install''s hooks are missing; run agent-ha-bridge configure' -ForegroundColor Yellow
    }
    elseif (-not $script:BridgeIsWindows) {
        $loaded = [bool](& launchctl print "gui/$(& id -u)/$launchAgentLabel" 2>$null)
        if ($daemonPid -le 0) {
            $daemon = @(Get-BridgeOwnedRuntimeProcesses -Context $commandContext -Roles daemon)
            if ($daemon) { $daemonPid = [int]$daemon[0].ProcessId }
        }
        if ($daemonPid -gt 0) { Write-Host "    daemon     : running (pid $daemonPid)" -ForegroundColor Green }
        elseif ($loaded) { Write-Host '    daemon     : not running - launchd will start it again shortly' -ForegroundColor Yellow }
        else { Write-Host "    daemon     : the '$launchAgentLabel' LaunchAgent is not loaded - run agent-ha-bridge configure" -ForegroundColor Yellow }
        if (-not (Get-BridgeTmuxPath)) { Write-Host '    tmux       : not installed - replies from the dashboard need it (brew install tmux)' -ForegroundColor Yellow }
    }
    elseif ($task) {
        if ($daemonPid -le 0) {
            $daemon = @(Get-BridgeOwnedRuntimeProcesses -Context $commandContext -Roles daemon)
            if ($daemon) { $daemonPid = [int]$daemon[0].ProcessId }
        }
        if ($daemonPid -gt 0) {
            Write-Host "    daemon     : running (pid $daemonPid)" -ForegroundColor Green
        }
        else {
            Write-Host "    daemon     : not running - task state $($task.State)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "    daemon     : the '$taskName' scheduled task is not registered" -ForegroundColor Yellow
    }

    # The native hook (docs/fast-hooks.md), and how often it has fallen back to PowerShell.
    $nativeLib = Join-Path (Join-Path $root 'hooks') 'bridge-native-hook.ps1'
    if (Test-Path -LiteralPath $nativeLib) {
        . $nativeLib
        $nativePath = Get-BridgeNativeHookPath -BridgeHome $bridgeHome
        if ($nativePath) {
            $nativeVersion = (& $nativePath --version 2>$null | Out-String).Trim()
            Write-Host "    hooks      : native ($nativeVersion) - $(Format-BridgeHookStats -Stats (Get-BridgeHookStats -Hours 24 -LogPath (Get-BridgeRuntimePath -Name 'agent-bridge-hook.log' -Context $commandContext)) -Hours 24)"
            # Installed is not the same as used. Copilot only runs the native hook from
            # a version that can launch one directly, and below it the installer writes
            # PowerShell hooks instead - which cost 587 ms a hook against 21 ms, on the
            # path a person is actually waiting on. That was reported once, in grey,
            # during an install nobody re-reads; "no runs in 24 h" beside a version
            # number reads like the hook is idle rather than bypassed.
            $copilotVersion = Get-BridgeCopilotVersion
            if ($null -ne $copilotVersion -and -not (Test-BridgeCopilotRunsExec -Version $copilotVersion)) {
                Write-Host "                 Copilot CLI $copilotVersion is below $($script:BridgeCopilotExecMinVersion), so its hooks are NOT using it" -ForegroundColor Yellow
                Write-Host '                 and cost about 570 ms each. Run: copilot update, then agent-ha-bridge configure' -ForegroundColor Yellow
            }
        }
        else {
            Write-Host '    hooks      : PowerShell - the native hook is not installed (agent-ha-bridge update fetches it)' -ForegroundColor Yellow
        }
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

    # Both halves of the agent identity or neither; with only one, the purple edge is
    # off for good and nothing else ever says so.
    $identityWarning = Get-BridgeStatusAgentIdentityWarning -HooksDir (Join-Path $bridgeHome 'hooks')
    if ($identityWarning) {
        Write-Host "    agent id   : $identityWarning" -ForegroundColor Yellow
    }

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

    # The thing the bridge is for. Everything above reports whether a part is switched
    # on, and all of it can be green on a machine where no session has registered for
    # a day - which is exactly what happened, and what "but status says it is online"
    # was then believed against for hours (#127).
    if ($commandContext -and (Get-Command Get-BridgeRegistrationHealth -ErrorAction SilentlyContinue)) {
        $registration = $null
        try { $registration = Get-BridgeRegistrationHealth -Context $commandContext }
        catch { Write-Host "    sessions   : could not be checked - $($_.Exception.Message)" -ForegroundColor Yellow }
        if ($registration -and $registration.Ok) {
            Write-Host "    sessions   : registering normally - $($registration.Detail)" -ForegroundColor Green
        }
        elseif ($registration) {
            # Not "NOT registering": a held discovery stops retirement, cleanup and new
            # launches while sessions that are already registered carry on reporting
            # perfectly well. Saying otherwise contradicts the machine list printed a
            # few lines further down, and a status that argues with itself is the thing
            # this check exists to stop.
            Write-Host "    sessions   : needs attention - $($registration.Detail)" -ForegroundColor Red
            if ($daemonLog) { Write-Host "                 see $daemonLog" -ForegroundColor Yellow }
        }
    }

    Show-BridgeMachines -HooksDir (Join-Path $bridgeHome 'hooks') -ConfigPath $configPath
}

function Get-BridgeStatusDaemonPid {
    <#
        The daemon's pid, from the heartbeat it writes each pass.

        Read through the hooks library so there is one implementation of it rather
        than a copy here that can drift from the one the hooks use. Dot-sourced inside
        this function deliberately: at script scope it would leave the whole library
        defined in this command, which this file avoids on purpose, and a dot-sourced
        script rebinds any parameter it declares over a same-named local here.

        Returns 0 when the library is missing or the heartbeat cannot answer, and the
        caller falls back to scanning process command lines.
    #>
    param([Parameter(Mandatory)][string]$HooksDir)

    $lib = Join-Path $HooksDir 'decision-bridge-common.ps1'
    if (-not (Test-Path -LiteralPath $lib)) { return 0 }
    try {
        . $lib
        [int](Get-BridgeDaemonPid)
    }
    catch { 0 }
}

function Get-BridgeStatusAgentIdentityWarning {
    <#
        Why an agent-driven session can never be marked as one, or '' when it can.

        Asked of the installed library for the same reason the pid is: the rule that
        decides it lives with the code that reads the config, and a copy here would
        drift. Dot-sourced inside the function on purpose - see above.

        Returns '' when the library is too old to answer, so an install mid-upgrade
        says nothing rather than claiming everything is fine.
    #>
    param([Parameter(Mandatory)][string]$HooksDir)

    $lib = Join-Path $HooksDir 'decision-bridge-common.ps1'
    if (-not (Test-Path -LiteralPath $lib)) { return '' }
    try {
        . $lib
        if (-not (Get-Command Get-BridgeAgentIdentityWarning -ErrorAction SilentlyContinue)) { return '' }
        [string](Get-BridgeAgentIdentityWarning)
    }
    catch { '' }
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
    if (-not $commandContext) { throw 'The installation root helper is missing; no runtime was stopped.' }
    Write-Step 'Restarting the bridge daemon'
    if (-not $script:BridgeIsWindows) {
        $plist = Join-Path $commandContext.Home "Library\LaunchAgents\$launchAgentLabel.plist"
        if (-not (Test-Path -LiteralPath $plist) -or
            -not (Test-BridgeLaunchAgentOwnership -Path $plist -Context $commandContext)) {
            throw 'No owned LaunchAgent is registered; no other installation was restarted.'
        }
        $target = "gui/$(& id -u)/$launchAgentLabel"
        & launchctl kickstart -k $target 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            # Nothing loaded to kick. The plist is right here and has already been
            # proven to be ours, so load it rather than refusing: a failed update can
            # leave the LaunchAgent unloaded, and restart is the command people reach
            # for. Being told to run `configure` - a full reinstall - to reload a file
            # that is already correct is the long way round (#123).
            Write-Host '    the LaunchAgent was not loaded; loading it' -ForegroundColor Yellow
            if (-not (Restore-BridgeOwnedLaunchAgent -Service $target -PlistPath $plist)) {
                throw "The '$launchAgentLabel' LaunchAgent is not loaded and could not be loaded. Run: agent-ha-bridge configure"
            }
            Write-Host '    loaded' -ForegroundColor Green
            return
        }
        Write-Host '    restarted' -ForegroundColor Green
        return
    }
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) {
        throw "The '$taskName' scheduled task is not registered. Run: agent-ha-bridge configure"
    }
    if (-not (Test-BridgeTaskOwnership -Task $task -Context $commandContext)) {
        throw 'The scheduled task points at another installation; it was not changed.'
    }
    # The daemon is detached from the task, so stopping the task alone leaves it
    # running; kill it and let the supervisor bring up a fresh one.
    Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop
    Stop-BridgeOwnedRuntime -Context $commandContext
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
    pair      = @('pair', 'join')
    secret    = @('secret')
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
    'pair' {
        # Run directly rather than through Invoke-BridgeScript, which exits with the
        # child's code: a machine that has just joined needs its daemon restarted so it
        # starts signing with the new secret, and only a successful pairing should.
        $entry = Join-Path $bridgeHome 'hooks/bridge-pairing-entry.ps1'
        if (-not (Test-Path -LiteralPath $entry)) { throw "Pairing is not installed at $entry. Update the bridge first: agent-ha-bridge update" }
        & $pwshHere -NoProfile -File $entry -Configure
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        Invoke-Restart
        break
    }
    'secret' {
        $entry = Join-Path $bridgeHome 'hooks/bridge-pairing-entry.ps1'
        $action = if (@($passthrough).Count) { [string]$passthrough[0] } else { '' }
        if ($action -eq 'show') { & $pwshHere -NoProfile -File $entry -Show; exit $LASTEXITCODE }
        if ($action -eq 'rotate') {
            # Restarted afterwards so this machine signs with the new secret straight away.
            & $pwshHere -NoProfile -File $entry -Rotate
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            Invoke-Restart
            break
        }
        throw 'Usage: agent-ha-bridge secret show | agent-ha-bridge secret rotate'
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
