#Requires -Version 7.0
<#
.SYNOPSIS
    A session an agent launches reads as agent-driven from the moment it appears.

.DESCRIPTION
    The purple edge says something other than you is driving a session. It was only
    ever set by an agent *replying* to a session, never by one *starting* it, so a
    session handed over from the dashboard came up in the ordinary colours and stayed
    that way until the first reply - backwards, since the launch is the moment it is
    most useful to see.

    The hard part is not reading who pressed Launch, it is that the press and the
    session are not the same moment. The launch returns before the CLI has registered,
    so the session to stamp does not exist yet, and the driver has to be carried across.
    Get the correlation wrong and a session wears somebody else's driver, which is
    worse than wearing none: a glow that lies is the exact thing the feature exists to
    avoid.

    Only one agent registers under the id it was offered. Copilot and Claude take the
    id the bridge invented; Codex picks its own, and its registration is recognised
    merely as the first one written after the launch. So "has it registered?" and "as
    what?" are one question, answered by one function - and the Codex case below is
    what that is for, because there the offered id and the real one differ.

    These follow the driver the whole way: the Launch press, the registration, the
    session being adopted, and what the card is finally told - including across the
    first turn, which reads as somebody typing unless it is told to expect one.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
$script:DaemonConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-agent-launched-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $__ok = $false
    try { $__ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($__ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

# Stubs above everything that calls them: PowerShell binds a function as it runs.
$script:ButtonState = $null
function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    if ($EntityId -eq $script:DaemonEntity.NewSession) { return $script:ButtonState }
    # Every session entity already exists, so Add-DaemonSession adopts rather than
    # republishes - the path a launched session actually takes.
    [pscustomobject]@{ state = 'Idle'; attributes = [pscustomobject]@{} }
}
function Invoke-HomeAssistantService { param($Domain, $Service, $Headers, $Data) }
function Set-CopilotMqttStatus { param($SessionId, $Status, $Headers, $Attributes) }
$script:CardDetail = $null
function Set-CopilotMqttActivity {
    param([string]$SessionId, [string]$Summary, $Detail, [hashtable]$Headers)
    $script:CardDetail = $Detail
}
function Get-BridgeSessionDisplay {
    param($SessionId, $Kind, $WorkingDirectory)
    [pscustomobject]@{ Name = "Agent: $SessionId"; Machine = 'M' }
}
function Test-BridgeSessionWorking { param($SessionId, $Kind, $Transcript, $Status) $false }
function Clear-DaemonLaunchNoteOnRegistration { param($Headers) }
function Set-CopilotMqttEntityIds { param($SessionId) }
function Start-Sleep { param($Milliseconds, $Seconds) }

$headers = @{ Authorization = '******' }

# A Home Assistant state as it arrives with the account behind the press on it. The
# agent's own user id is what Get-BridgeDriverFromState recognises.
function New-Press {
    param([Parameter(Mandatory)][string]$UserId, [Parameter(Mandatory)][DateTimeOffset]$At)
    [pscustomobject]@{
        state = $At.ToString('o')
        context = [pscustomobject]@{ user_id = $UserId }
    }
}

$agentUser = 'agent-user-id'

try {
    Write-Host "`n--- the Launch press says who pressed it ---"
    $script:DaemonStartedAt = [DateTimeOffset]::Now.AddMinutes(-5)
    $script:DaemonNewSessionLastPress = ''
    $script:DaemonNewSessionPressDriver = ''

    # An agent's own account, as Get-BridgeDriverFromState is configured to read it.
    function Test-BridgeAgentUserId { param([string]$UserId) $UserId -eq $agentUser }
    $script:ButtonState = New-Press -UserId $agentUser -At ([DateTimeOffset]::Now)

    Test-That 'the press is seen' { Test-DaemonNewSessionPressed -Headers $headers }
    Test-That 'and recorded as an agent press' { $script:DaemonNewSessionPressDriver -eq 'agent' }

    $script:DaemonNewSessionLastPress = ''
    $script:ButtonState = New-Press -UserId 'a-person' -At ([DateTimeOffset]::Now.AddSeconds(1))
    Test-That 'a person pressing it is recorded as a person' {
        (Test-DaemonNewSessionPressed -Headers $headers) -and $script:DaemonNewSessionPressDriver -eq 'human'
    }

    # A press from before this daemon started is history in a retained value, and must
    # not leave a driver lying around for the next launch.
    $script:DaemonNewSessionLastPress = ''
    $script:DaemonNewSessionPressDriver = ''
    $script:ButtonState = New-Press -UserId $agentUser -At ($script:DaemonStartedAt.AddMinutes(-1))
    Test-That 'a stale retained press is ignored' { -not (Test-DaemonNewSessionPressed -Headers $headers) }
    Test-That 'and leaves no driver behind' { $script:DaemonNewSessionPressDriver -eq '' }

    Write-Host "`n--- the session that press produced is the one stamped ---"
    # Codex is the case worth asserting: it is offered one id and registers under
    # another of its own choosing, so stamping the offered one would glow the wrong
    # session - or no session at all.
    $launchedAt = [DateTimeOffset]::Now.AddSeconds(-5)
    $chosenById = 'codex-picked-this-one'
    function Get-BridgeRegisteredSessionId {
        param([string]$SessionId, [string]$Launcher, [DateTimeOffset]$Since)
        if ($Launcher -eq 'codex') { return $chosenById }
        $SessionId
    }
    function Get-BridgeLauncherLabel { param([string]$Launcher) 'Codex' }
    function Set-CopilotMqttNewSessionResult { param($Headers, $Text) }

    $script:DaemonLaunchDrivers = @{}
    $script:DaemonPendingLaunch = [pscustomobject]@{
        SessionId = 'the-id-we-offered'; ProcessId = $PID; Launcher = 'codex'
        Label = 'repo'; Verb = 'Started'; Since = $launchedAt
        LastCheck = [DateTimeOffset]::MinValue
        TrustAskedAt = $null; TrustConfirmed = $false; TrustAnswers = 0
        Driver = 'agent'
        AwaitingFirstMessage = $false; FirstMessageAsked = $false
    }
    Update-DaemonPendingLaunch -Headers $headers

    Test-That 'the driver is put aside for the id it really registered under' {
        $script:DaemonLaunchDrivers.ContainsKey($chosenById)
    } ("held: " + (@($script:DaemonLaunchDrivers.Keys) -join ', '))
    Test-That 'and not for the id it was offered' {
        -not $script:DaemonLaunchDrivers.ContainsKey('the-id-we-offered')
    }

    Write-Host "`n--- a launch the person made leaves nothing behind ---"
    $script:DaemonLaunchDrivers = @{}
    $script:DaemonPendingLaunch = [pscustomobject]@{
        SessionId = 'x'; ProcessId = $PID; Launcher = 'codex'
        Label = 'repo'; Verb = 'Started'; Since = $launchedAt
        LastCheck = [DateTimeOffset]::MinValue
        TrustAskedAt = $null; TrustConfirmed = $false; TrustAnswers = 0
        Driver = 'human'
        AwaitingFirstMessage = $false; FirstMessageAsked = $false
    }
    Update-DaemonPendingLaunch -Headers $headers
    Test-That 'nothing is waiting to be stamped' { $script:DaemonLaunchDrivers.Count -eq 0 }

    Write-Host "`n--- the session comes up already driven ---"
    $transcript = Join-Path ([IO.Path]::GetTempPath()) "agent-launched-$([guid]::NewGuid().ToString('N').Substring(0, 8)).jsonl"
    # Empty at adoption, as a just-launched session's transcript is - it is written
    # after the session comes up, which is why the driver has to survive that first
    # turn rather than merely be set before it.
    Set-Content -LiteralPath $transcript -Value '' -NoNewline
    try {
        $script:DaemonLaunchDrivers = @{ $chosenById = @{ Driver = 'agent'; At = [DateTimeOffset]::Now } }
        $session = [pscustomobject]@{
            SessionId = $chosenById; Transcript = $transcript; Kind = 'copilot'
            ProcessId = $PID; WorkingDirectory = 'C:\repo'
        }
        $entry = Add-DaemonSession -Session $session -Headers $headers

        Test-That 'the session is adopted' { $null -ne $entry }
        Test-That 'and carries the agent as its driver' {
            $entry.PSObject.Properties['Driver'] -and $entry.Driver -eq 'agent'
        }
        Test-That 'the handoff is taken, not left for a later session' {
            -not $script:DaemonLaunchDrivers.ContainsKey($chosenById)
        }

        # Without this the glow lasts until the first activity update, seconds later:
        # a starting turn is read as somebody typing unless one is expected.
        Test-That 'and the first turn is expected, so it is not read as typed' {
            $entry.PSObject.Properties['DriverPending'] -and $entry.DriverPending
        }

        Write-Host "`n--- and the card is told, across the session's first turn ---"
        # The turn the launch itself starts. Read as somebody typing unless the
        # session was told to expect it, which is the whole reason DriverPending
        # exists on the reply path too.
        Add-Content -LiteralPath $transcript -Encoding UTF8 -Value @(
            '{"type":"user.message"}'
            '{"type":"assistant.message","data":{"content":"on it"}}'
        )
        $script:CardDetail = $null
        Update-DaemonSessionActivity -Id $chosenById -Entry $entry -Session $session -Headers $headers -VerboseOn $false
        Test-That 'the card is given a driver' { $null -ne $script:CardDetail -and $script:CardDetail.ContainsKey('driver') } `
            ("detail: " + ($(if ($script:CardDetail) { @($script:CardDetail.Keys) -join ',' } else { 'none' })))
        Test-That 'and it is still the agent after that first turn' { [string]$script:CardDetail['driver'] -eq 'agent' } `
            ("got: " + $(if ($script:CardDetail -and $script:CardDetail.ContainsKey('driver')) { [string]$script:CardDetail['driver'] } else { 'nothing' }))

        # The glow is not permanent: once the launch's own turn is past, a turn the
        # person starts in the terminal hands the session back to them.
        Add-Content -LiteralPath $transcript -Encoding UTF8 -Value @(
            '{"type":"user.message"}'
            '{"type":"assistant.message","data":{"content":"next"}}'
        )
        $script:CardDetail = $null
        Update-DaemonSessionActivity -Id $chosenById -Entry $entry -Session $session -Headers $headers -VerboseOn $false
        Test-That 'a later turn typed in the terminal hands it back' { [string]$script:CardDetail['driver'] -eq 'human' } `
            ("got: " + [string]$script:CardDetail['driver'])

        Write-Host "`n--- a session nobody handed over is unchanged ---"
        $script:DaemonLaunchDrivers = @{}
        $plainId = 'opened-in-a-terminal'
        $plain = [pscustomobject]@{
            SessionId = $plainId; Transcript = $transcript; Kind = 'copilot'
            ProcessId = $PID; WorkingDirectory = 'C:\repo'
        }
        $plainEntry = Add-DaemonSession -Session $plain -Headers $headers
        Test-That 'it has no driver of its own' {
            -not ($plainEntry.PSObject.Properties['Driver'] -and $plainEntry.Driver)
        }
        $script:CardDetail = $null
        Add-Content -LiteralPath $transcript -Encoding UTF8 -Value '{"type":"assistant.message","data":{"content":"hello"}}'
        Update-DaemonSessionActivity -Id $plainId -Entry $plainEntry -Session $plain -Headers $headers -VerboseOn $false
        Test-That 'and the card reads it as yours' { [string]$script:CardDetail['driver'] -eq 'human' }
    }
    finally { Remove-Item -LiteralPath $transcript -Force -ErrorAction SilentlyContinue }
}
finally {
    Remove-Item -LiteralPath $script:DaemonConfig.LogFile -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0) {
    Write-Host "`n$($script:Failures) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall passed" -ForegroundColor Green
