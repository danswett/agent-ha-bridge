#Requires -Version 7.0
<#
.SYNOPSIS
    An agent can act as itself, and a launch decides its own permissions.

.DESCRIPTION
    Two failures that look unrelated and are the same shape: a setting whose two ends
    were both present and never joined up in the middle.

    The purple edge is decided by the Home Assistant account behind the press, and
    agentUserIds says which account that is. But the bridge held exactly one token -
    yours - and handed it to everything, so an agent had no way to press as anyone
    else. Every press it made was read as yours, correctly, and the edge could not
    appear on any dashboard however the feature was configured. agentUserIds and
    agentToken are therefore useless apart, which is what Get-BridgeAgentIdentityWarning
    exists to say out loud: nothing fails without it, the dashboard simply never lights
    up, and a silent half-configuration is indistinguishable from a broken feature.

    newSession.allowAllTools was read from the config of the machine that *runs* the
    session, not the one choosing. A launch onto another machine therefore took that
    machine's setting, which the person pressing Launch could neither see nor change -
    so a session started from a phone stopped dead on a permission prompt with nobody
    at the keyboard. It is now a selector on the launch card, opening on the local
    config so the control states the existing behaviour rather than changing it.

    The Claude case is the one worth asserting. 'Allow all' means "launch without
    permission prompts", and Claude's folder-trust dialog is one - the one flag that
    cannot waive it, because Claude skips that dialog only in non-interactive mode and
    a bridge window is deliberately interactive. Left needing its second Launch press,
    an unattended launch simply stops there, which is the deadlock the setting exists
    to avoid.

    Every check below follows a value the whole way rather than testing either end:
    the config to the selector, the selector to the command line, and the press to the
    session it produced.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $__ok = $false
    try { $__ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($__ok) { Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

# A throwaway config, so none of this reads the real one - these settings decide
# whether a session launches unattended, and the real file is a live install's.
$scratch = Join-Path ([IO.Path]::GetTempPath()) "bridge-perms-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$configPath = Join-Path $scratch 'config.json'

# Set before the library is loaded: it reads the config once, at load.
$env:AGENT_HA_BRIDGE_CONFIG = $configPath
$env:AGENT_HA_AGENT_TOKEN = ''

function Set-TestConfig {
    param([Parameter(Mandatory)][hashtable]$Settings)
    ($Settings | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $configPath -Encoding UTF8
}

# $script:DecisionBridgeConfig is built at load time, so a test that changes a setting
# has to re-read the library - the same thing a restarted daemon does, and the only
# honest way to assert what a given config produces. Dot-sourced at script scope every
# time rather than from inside a helper: a helper's dot-source defines everything in
# that helper's scope, where it vanishes the moment it returns.
$commonLib = Join-Path $PSScriptRoot '../hooks/decision-bridge-common.ps1'

try {
    Write-Host "`n--- an agent has somewhere to keep its own token ---"
    Set-TestConfig @{ homeAssistant = @{ token = 'the-persons-token' } }
    . $commonLib
    Test-That 'with none configured there is no agent token' { (Get-BridgeAgentToken) -eq '' }
    Test-That 'and nothing is exported into a launched session' {
        $null -eq (Get-BridgeAgentTokenEnvironment)
    }
    Test-That 'the daemon token is never mistaken for one' {
        (Get-BridgeAgentToken) -ne 'the-persons-token'
    }

    Set-TestConfig @{ homeAssistant = @{ token = 'the-persons-token'; agentToken = 'the-agents-token' } }
    . $commonLib
    Test-That 'a configured agent token is found' { (Get-BridgeAgentToken) -eq 'the-agents-token' }
    Test-That 'and is what a launched session carries' {
        $e = Get-BridgeAgentTokenEnvironment
        $null -ne $e -and $e.Name -eq 'AGENT_HA_AGENT_TOKEN' -and $e.Value -eq 'the-agents-token'
    }
    Test-That 'the daemon still resolves its own token, not the agent one' {
        (Get-HomeAssistantHeaders).Authorization -eq 'Bearer the-persons-token'
    } ([string](Get-HomeAssistantHeaders).Authorization)

    # Keeping a second token out of a file, the way homeAssistant.token already can be.
    Set-TestConfig @{ homeAssistant = @{ token = 'the-persons-token'; agentTokenEnvVar = 'BRIDGE_TEST_AGENT_TOKEN' } }
    $env:BRIDGE_TEST_AGENT_TOKEN = 'from-the-environment'
    . $commonLib
    Test-That 'an agent token can come from the environment instead' {
        (Get-BridgeAgentToken) -eq 'from-the-environment'
    } ([string](Get-BridgeAgentToken))
    Remove-Item Env:\BRIDGE_TEST_AGENT_TOKEN -ErrorAction SilentlyContinue

    Write-Host "`n--- and half a configuration says so instead of failing silently ---"
    Set-TestConfig @{ homeAssistant = @{ token = 't' } }
    . $commonLib
    Test-That 'neither half configured is the documented default, not a warning' {
        (Get-BridgeAgentIdentityWarning) -eq ''
    } ([string](Get-BridgeAgentIdentityWarning))

    # The exact state this machine was in: an id configured, no token anywhere, and a
    # dashboard that had never once shown the edge the id was added for.
    Set-TestConfig @{ homeAssistant = @{ token = 't'; agentUserIds = @('9239a5ef') } }
    . $commonLib
    Test-That 'an id with no token is reported' { (Get-BridgeAgentIdentityWarning) -match 'agentToken' }
    Test-That 'and says the agent is still acting as you' {
        (Get-BridgeAgentIdentityWarning) -match 'as you'
    } ([string](Get-BridgeAgentIdentityWarning))

    Set-TestConfig @{ homeAssistant = @{ token = 't'; agentToken = 'a' } }
    . $commonLib
    Test-That 'a token with no id is reported too, being just as inert' {
        (Get-BridgeAgentIdentityWarning) -match 'agentUserIds'
    } ([string](Get-BridgeAgentIdentityWarning))

    Set-TestConfig @{ homeAssistant = @{ token = 't'; agentToken = 'a'; agentUserIds = @('9239a5ef') } }
    . $commonLib
    Test-That 'both halves together is the only quiet case' { (Get-BridgeAgentIdentityWarning) -eq '' }
    Test-That 'and that id is then recognised as an agent' { Test-BridgeAgentUserId -UserId '9239a5ef' }
    Test-That 'while yours is not' { -not (Test-BridgeAgentUserId -UserId '334d6cf2') }

    Write-Host "`n--- the permissions selector says only what it means ---"
    Test-That 'both options are offered, the cautious one first' {
        (@(Get-BridgePermissionOptions) -join '|') -eq 'Ask permission|Allow all'
    } ((@(Get-BridgePermissionOptions) -join '|'))
    Test-That 'allow-all on maps to the allow option' {
        (Get-BridgePermissionLabel -AllowAllTools $true) -eq 'Allow all'
    }
    Test-That 'and off to the asking one' {
        (Get-BridgePermissionLabel -AllowAllTools $false) -eq 'Ask permission'
    }
    Test-That 'only the exact option waives permissions' { Test-BridgePermissionAllowsAll -Value 'Allow all' }
    # Everything unclear has to read as asking: an entity a machine has not published
    # yet, a value from an older bridge, a blank. The failure mode of a wrong guess
    # here is a session handed blanket approval nobody chose.
    foreach ($value in @('Ask permission', 'unknown', 'unavailable', '', 'allow all', 'Allow', 'Agent default')) {
        Test-That "'$value' does not" { -not (Test-BridgePermissionAllowsAll -Value $value) }
    }
    Test-That 'and neither does nothing at all' { -not (Test-BridgePermissionAllowsAll -Value $null) }

    Write-Host "`n--- the choice reaches the command line, per agent ---"
    . (Join-Path $PSScriptRoot '../hooks/session-launch.ps1')
    $sid = '11111111-2222-3333-4444-555555555555'
    $allowed = @{
        copilot = @(Get-BridgeNewSessionArguments -SessionId $sid -Launcher 'copilot' -AllowAllTools)
        agency  = @(Get-BridgeNewSessionArguments -SessionId $sid -Launcher 'agency' -AllowAllTools)
        claude  = @(Get-BridgeNewSessionArguments -SessionId $sid -Launcher 'claude' -AllowAllTools)
        codex   = @(Get-BridgeNewSessionArguments -SessionId '' -Launcher 'codex' -Prompt 'go' -AllowAllTools)
    }
    Test-That 'Copilot gets the whole thing, not just tools' {
        $allowed.copilot -contains '--allow-all' -and $allowed.copilot -notcontains '--allow-all-tools'
    } ($allowed.copilot -join ' ')
    Test-That 'Agency passes it through to the Copilot it runs' { $allowed.agency -contains '--allow-all' }
    Test-That 'Claude skips its permission checks' { $allowed.claude -contains '--dangerously-skip-permissions' }
    Test-That 'Codex stops asking for approval' {
        ((@($allowed.codex) -join ' ') -match '--ask-for-approval never')
    } ($allowed.codex -join ' ')

    $asked = @(Get-BridgeNewSessionArguments -SessionId $sid -Launcher 'copilot')
    Test-That 'and none of it is passed when the launch did not ask for it' {
        $asked -notcontains '--allow-all' -and $asked -notcontains '--dangerously-skip-permissions'
    } ($asked -join ' ')

    Write-Host "`n--- the daemon opens the control on what the machine would have done ---"
    $env:AGENT_BRIDGE_DAEMON_NORUN = '1'
    Set-TestConfig @{
        homeAssistant = @{ token = 't' }
        newSession = @{
            allowAllTools = $true
            workspaces = @(@{ label = 'Bridge'; path = $scratch })
        }
    }
    . (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
    $script:DaemonConfig.LogFile = Join-Path $scratch 'daemon.log'

    Test-That 'the permissions entity is one of the machine-scoped ids' {
        $script:DaemonEntity.NewPermissions -match '^select\.agent_bridge_.+_new_permissions$'
    } ([string]$script:DaemonEntity.NewPermissions)

    $script:SelectorState = 'unknown'
    $script:Selected = @()
    function Get-HomeAssistantState {
        param([string]$EntityId, [hashtable]$Headers)
        if ($EntityId -eq $script:DaemonEntity.NewPermissions) {
            return [pscustomobject]@{ state = $script:SelectorState }
        }
        [pscustomobject]@{ state = 'unknown' }
    }
    function Invoke-HomeAssistantService {
        param($Domain, $Service, $Headers, $Data)
        if ($Data.entity_id -eq $script:DaemonEntity.NewPermissions) { $script:Selected += [string]$Data.option }
    }
    function Get-DaemonEntityState { param($EntityId, $Headers) [pscustomobject]@{ state = 'unknown' } }
    $headers = @{ Authorization = '******' }

    Set-DaemonNewSessionDefaults -Headers $headers -Workspaces @() -Profiles @()
    Test-That 'an unset selector is driven to the configured allowAllTools' {
        $script:Selected -contains 'Allow all'
    } ($script:Selected -join ',')

    # A value someone picked survives every reconcile, exactly like the workspace and
    # the tuning axes - otherwise the daemon would silently undo the choice seconds
    # after it was made.
    $script:SelectorState = 'Ask permission'
    $script:Selected = @()
    Set-DaemonNewSessionDefaults -Headers $headers -Workspaces @() -Profiles @()
    Test-That 'a choice already made is left alone' { $script:Selected.Count -eq 0 } ($script:Selected -join ',')

    Write-Host "`n--- and the launch uses the selector, not the local config ---"
    # The config says allow-all; the card says ask. The card wins, which is the whole
    # point: the machine running the session is not the one choosing.
    $script:Started = $null
    function Start-BridgeCopilotSession {
        param(
            [string]$WorkingDirectory, [string]$Prompt, [string]$SessionId, [string]$AgencyProfile,
            [string]$Launcher, [string]$Model, [string]$Effort, [string]$Context,
            [bool]$AllowAllTools, [switch]$Resume
        )
        $script:Started = [pscustomobject]@{ AllowAllTools = $AllowAllTools; Launcher = $Launcher }
        [pscustomobject]@{
            Launched = $true; SessionId = 'sess-1'; ProcessId = $PID; Detail = 'started'
            Model = ''; Effort = ''; Context = ''
        }
    }
    function Set-CopilotMqttNewSessionResult { param($Headers, $Text) }
    function Get-BridgeLauncherLabel { param([string]$Launcher) 'Claude' }
    function Write-DaemonLog { param([string]$Message) }

    $request = [pscustomobject]@{
        Launcher = 'claude'; Directory = $scratch; Label = 'Bridge'; Prompt = ''
        AgencyProfile = ''; Model = ''; Effort = ''; Context = ''
        AllowAllTools = $false; ResumeSession = $null; ResumeLabel = ''
    }
    Start-DaemonLaunch -Request $request -Headers $headers
    Test-That 'asking on the card beats allowAllTools in the config' {
        $null -ne $script:Started -and -not $script:Started.AllowAllTools
    }
    Test-That 'and such a launch still waits for its second press before trusting a folder' {
        -not $script:DaemonPendingLaunch.TrustConfirmed
    }

    # The Claude deadlock. 'Allow all' has to cover the folder-trust dialog too, or an
    # unattended launch stops on the one prompt the flag cannot waive.
    $script:Started = $null
    $request.AllowAllTools = $true
    Start-DaemonLaunch -Request $request -Headers $headers
    Test-That 'allowing everything on the card reaches the launcher' {
        $null -ne $script:Started -and $script:Started.AllowAllTools
    }
    Test-That 'and the folder-trust question is taken as already answered' {
        $script:DaemonPendingLaunch.TrustConfirmed
    }

    # A request from an older caller carries no such property; it must keep launching
    # exactly as it did, from the config, rather than silently becoming "ask".
    $script:Started = $null
    $old = [pscustomobject]@{
        Launcher = 'claude'; Directory = $scratch; Label = 'Bridge'; Prompt = ''
        AgencyProfile = ''; Model = ''; Effort = ''; Context = ''
        ResumeSession = $null; ResumeLabel = ''
    }
    Start-DaemonLaunch -Request $old -Headers $headers
    Test-That 'a request without the property falls back to the config, not to off' {
        $null -ne $script:Started -and $script:Started.AllowAllTools
    }
}
finally {
    Remove-Item Env:\AGENT_HA_BRIDGE_CONFIG -ErrorAction SilentlyContinue
    Remove-Item Env:\AGENT_HA_AGENT_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:\AGENT_BRIDGE_DAEMON_NORUN -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0) {
    Write-Host "`n$($script:Failures) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall passed" -ForegroundColor Green
