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
# What the session's own card already says, for the re-adoption case. A daemon that
# restarts has no launch record left, so the card is the only surviving witness.
$script:PriorDriver = ''
function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    if ($EntityId -eq $script:DaemonEntity.NewSession) { return $script:ButtonState }
    if ($EntityId -like 'sensor.*_activity') {
        $attrs = if ($script:PriorDriver) { [pscustomobject]@{ driver = $script:PriorDriver } }
        else { [pscustomobject]@{} }
        return [pscustomobject]@{ state = 'Idle'; attributes = $attrs }
    }
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
        $script:CardDetail = $null
        $entry = Add-DaemonSession -Session $session -Headers $headers

        Test-That 'the session is adopted' { $null -ne $entry }
        # The card is published once at adoption, before there is any transcript to
        # read. A session that launches and then waits produces no activity at all, so
        # a driver that only rides on an activity update never arrives - which is
        # exactly how an agent-launched session sat on the dashboard showing blue.
        Test-That 'and the card is born knowing an agent launched it' {
            $null -ne $script:CardDetail -and $script:CardDetail.ContainsKey('driver') -and
            [string]$script:CardDetail['driver'] -eq 'agent'
        } ("got: " + $(if ($script:CardDetail -and $script:CardDetail.ContainsKey('driver')) { [string]$script:CardDetail['driver'] } else { 'nothing' }))
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
        $script:CardDetail = $null
        $plainEntry = Add-DaemonSession -Session $plain -Headers $headers
        Test-That 'it has no driver of its own' {
            -not ($plainEntry.PSObject.Properties['Driver'] -and $plainEntry.Driver)
        }
        Test-That 'and its card is born reading as yours' {
            [string]$script:CardDetail['driver'] -eq 'human'
        } ("got: " + $(if ($script:CardDetail -and $script:CardDetail.ContainsKey('driver')) { [string]$script:CardDetail['driver'] } else { 'nothing' }))
        $script:CardDetail = $null
        Add-Content -LiteralPath $transcript -Encoding UTF8 -Value '{"type":"assistant.message","data":{"content":"hello"}}'
        Update-DaemonSessionActivity -Id $plainId -Entry $plainEntry -Session $plain -Headers $headers -VerboseOn $false
        Test-That 'and the card reads it as yours' { [string]$script:CardDetail['driver'] -eq 'human' }

        Write-Host "`n--- a restart does not hand an agent's session back ---"
        # The launch record does not survive a daemon restart, and the state entry is
        # built fresh, so the card itself is the only thing left that knows. Without
        # reading it back, every restart - and every re-prime after a Home Assistant
        # restart - quietly turned an agent-driven session blue.
        $script:DaemonLaunchDrivers = @{}
        $script:PriorDriver = 'agent'
        try {
            $restartId = 'survives-a-restart'
            $restarted = [pscustomobject]@{
                SessionId = $restartId; Transcript = $transcript; Kind = 'copilot'
                ProcessId = $PID; WorkingDirectory = 'C:\repo'
            }
            $script:CardDetail = $null
            $restartEntry = Add-DaemonSession -Session $restarted -Headers $headers
            Test-That 'the driver is read back off the card' {
                [string]$script:CardDetail['driver'] -eq 'agent'
            } ("got: " + $(if ($script:CardDetail -and $script:CardDetail.ContainsKey('driver')) { [string]$script:CardDetail['driver'] } else { 'nothing' }))
            # Republishing it once would not be enough on its own: the entry is what
            # the next activity update reads, and a blank one would undo this.
            Test-That 'and kept on the entry, so the next update does not undo it' {
                $restartEntry.PSObject.Properties['Driver'] -and $restartEntry.Driver -eq 'agent'
            }
            # The launch path owns the first-turn glow; a session being re-adopted is
            # mid-life and its next turn is ordinary.
            Test-That 'without claiming a first turn it never had' {
                -not ($restartEntry.PSObject.Properties['DriverPending'] -and $restartEntry.DriverPending)
            }
        }
        finally { $script:PriorDriver = '' }

        Write-Host "`n--- a quick answer given before adoption is still seen ---"
        # Registering and publishing a session takes several seconds, and a short
        # prompt is answered well inside that, so a launched session's first answer is
        # often already on disk before the daemon ever looks. Starting at the end of
        # the transcript skipped it for good: the card sat at Idle with nothing in it
        # while the session had in fact replied. Confirmed on a real Mac, where a
        # session showing no answer was asked and said it had already given one.
        $script:DaemonLaunchDrivers = @{}
        $quickId = 'answered-before-anyone-looked'
        $quickTranscript = Join-Path ([IO.Path]::GetTempPath()) "first-answer-$([guid]::NewGuid().ToString('N').Substring(0, 8)).jsonl"
        Set-Content -LiteralPath $quickTranscript -Encoding UTF8 -Value @(
            '{"type":"user.message"}'
            '{"type":"assistant.message","data":{"content":"COLOUR OK"}}'
        )
        try {
            $script:DaemonLaunchedTuning = @{ $quickId = [pscustomobject]@{
                    Model = ''; Effort = ''; Context = ''; At = [DateTimeOffset]::Now; Resumed = $false
                }
            }
            $quick = [pscustomobject]@{
                SessionId = $quickId; Transcript = $quickTranscript; Kind = 'copilot'
                ProcessId = $PID; WorkingDirectory = 'C:\repo'
            }
            $quickEntry = Add-DaemonSession -Session $quick -Headers $headers
            Test-That 'a session the bridge started is read from the beginning' {
                $quickEntry.Offset -eq 0
            } ("offset: " + [string]$quickEntry.Offset)

            # The proof that matters: the answer reaches the card without the session
            # being prodded into saying anything else.
            $script:CardDetail = $null
            Update-DaemonSessionActivity -Id $quickId -Entry $quickEntry -Session $quick -Headers $headers -VerboseOn $false
            Test-That 'and the answer it already gave reaches the card' {
                $null -ne $script:CardDetail -and ($script:CardDetail | Out-String) -match 'COLOUR OK'
            } ("card: " + $(if ($script:CardDetail) { ($script:CardDetail | Out-String).Trim() } else { 'nothing' }))

            Write-Host "`n--- but a resumed session is not replayed ---"
            # Its transcript is a conversation that already happened. Reading it from
            # the start would push the whole of it onto the card as though it were new.
            $resumedId = 'reopened-from-the-list'
            $script:DaemonLaunchedTuning = @{ $resumedId = [pscustomobject]@{
                    Model = ''; Effort = ''; Context = ''; At = [DateTimeOffset]::Now; Resumed = $true
                }
            }
            $resumed = [pscustomobject]@{
                SessionId = $resumedId; Transcript = $quickTranscript; Kind = 'copilot'
                ProcessId = $PID; WorkingDirectory = 'C:\repo'
            }
            $resumedEntry = Add-DaemonSession -Session $resumed -Headers $headers
            Test-That 'it starts at the end of what it already said' {
                $resumedEntry.Offset -eq (Get-Item -LiteralPath $quickTranscript).Length
            } ("offset: " + [string]$resumedEntry.Offset)

            Write-Host "`n--- and a session the bridge never launched is untouched ---"
            # Including one being re-adopted after a daemon restart: the launch record
            # does not survive, so nothing claims this is a fresh start, and rewinding
            # would replay a live session's whole history onto its card.
            $script:DaemonLaunchedTuning = @{}
            $foundId = 'was-already-running'
            $found = [pscustomobject]@{
                SessionId = $foundId; Transcript = $quickTranscript; Kind = 'copilot'
                ProcessId = $PID; WorkingDirectory = 'C:\repo'
            }
            $foundEntry = Add-DaemonSession -Session $found -Headers $headers
            Test-That 'it starts at the transcript''s end' {
                $foundEntry.Offset -eq (Get-Item -LiteralPath $quickTranscript).Length
            } ("offset: " + [string]$foundEntry.Offset)
        }
        finally { Remove-Item -LiteralPath $quickTranscript -Force -ErrorAction SilentlyContinue }
    }
    finally { Remove-Item -LiteralPath $transcript -Force -ErrorAction SilentlyContinue }
}
finally {
    Remove-Item -LiteralPath $script:DaemonConfig.LogFile -Force -ErrorAction SilentlyContinue
}

Write-Host "`n--- the one rule no code can enforce ---"

# An agent driving the bridge calls Home Assistant itself, so nothing in this
# repository is on that path and nothing here can make it use the right token. Saying
# so in AGENTS.md is the only control there is, which makes the wording load-bearing
# rather than decorative - so it is checked, the way the README's card names are.
#
# On 2026-09-29 AGENTS.md said none of this: an agent took the first token out of
# config.json, launched a session on another machine, and the card came back blue
# because Home Assistant had recorded the user's account against the press.
$script:AgentsDoc = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\AGENTS.md') -Raw
$script:CommonSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1') -Raw

Test-That 'AGENTS.md tells an agent which token to drive the bridge with' {
    $script:AgentsDoc -match 'AGENT_HA_AGENT_TOKEN'
}
Test-That 'and the variable it names is the one the bridge actually hands over' {
    # Tied to the default in decision-bridge-common.ps1 so renaming one without the
    # other fails here rather than in someone's session months later.
    $script:CommonSource -match "agentTokenEnvVar'\s+'AGENT_HA_AGENT_TOKEN'"
}
Test-That 'and says plainly which token is not the one to use' {
    $script:AgentsDoc -match 'homeAssistant\.token'
}
Test-That 'and names what silently goes wrong, so the reason survives an edit' {
    $script:AgentsDoc -match 'agentUserIds' -and $script:AgentsDoc -match 'purple'
}
Test-That 'and says how a remote session reports back, which is not a notification' {
    # Persistent notifications are invisible to GET /api/states, so an agent told to
    # answer with one polls forever and reads the silence as a dead session. That cost
    # two polling rounds on 2026-09-29 before the activity sensor was used instead.
    $script:AgentsDoc -match 'persistent_notification' -and $script:AgentsDoc -match '_activity'
}

if ($script:Failures -gt 0) {
    Write-Host "`n$($script:Failures) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall passed" -ForegroundColor Green
