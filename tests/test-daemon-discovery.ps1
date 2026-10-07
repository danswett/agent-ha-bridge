#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the daemon's session discovery (hooks/daemon-discovery.ps1).

.DESCRIPTION
    Get-DaemonSessionDiscovery decides which sessions are live, and until now nothing
    in the suite called it. That gap is why 1.33.0 shipped a change that killed
    discovery on every machine that took it: the core began asking
    Get-BridgeAgentProcesses for an observation while an adapter left behind by the
    update still carried a copy of bridge-platform.ps1 without that parameter, so
    every adapter threw and every session read as gone.

    Adapters are dot-sourced from outside hooks/ - ~/.claude/ha-bridge and the Codex
    plugin directory - and carry their own copy of bridge-platform.ps1, so the hazard
    is shadowing rather than a bad return value. The skew tests below model that split
    literally, by dot-sourcing an out-of-tree file that redefines the function with
    the older signature.

    Nothing here touches Home Assistant, a real adapter or a real process list.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')

$script:FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "test-daemon-discovery-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $script:FixtureRoot -Force | Out-Null
$script:DaemonConfig.LogFile = Join-Path $script:FixtureRoot 'daemon.log'

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

# ---------------------------------------------------------------- the fixture ----

$script:SelectedKinds = @('copilot')
$script:ProcessesByAgent = @{}
$script:ProcessReadKnown = $true
$script:ProcessDiagnostics = @()
$script:SessionsByKind = @{}
$script:FailingKinds = @{}
$script:AgentProcessCalls = [Collections.Generic.List[object]]::new()

function Get-BridgeSelectedClients { , @($script:SelectedKinds) }

# Stands in for the platform helper every adapter reaches through. Recording the call
# matters as much as the answer: discovery must always ask for an observation, because
# the bare list cannot distinguish "no processes" from "could not look".
$script:ObservingAgentProcesses = {
    param([Parameter(Mandatory)][string]$Agent, [switch]$AsObservation)
    $script:AgentProcessCalls.Add([pscustomobject]@{ Agent = $Agent; AsObservation = [bool]$AsObservation })
    # Direct assignment, not an if-expression: a branch yielding @() unrolls to $null,
    # and the caller's $inventory.Processes.Count then throws under strict mode.
    $rows = @()
    if ($script:ProcessesByAgent.ContainsKey($Agent)) { $rows = @($script:ProcessesByAgent[$Agent]) }
    [pscustomobject]@{
        Known = $script:ProcessReadKnown
        Processes = $rows
        Diagnostics = @($script:ProcessDiagnostics)
    }
}
${function:Get-BridgeAgentProcesses} = $script:ObservingAgentProcesses

# Command lines are read only for a process no session accounted for, to tell an
# embedded headless CLI from a session that is genuinely missing one. Unknown pids
# answer as an ordinary interactive CLI, which is what the fixtures mean by default.
$script:CommandLines = @{}
$script:CommandLineState = 'Readable'
$script:DefaultCommandLine = '"C:\Users\u\.copilot-cli\copilot.exe" --banner'
function Get-BridgeCommandLine {
    param([int]$ProcessId, [switch]$AsObservation)
    $text = if ($script:CommandLines.ContainsKey($ProcessId)) { [string]$script:CommandLines[$ProcessId] }
        else { $script:DefaultCommandLine }
    [pscustomobject]@{
        State = $script:CommandLineState; Text = $text
        ProcessId = $ProcessId; Code = ''; NativeExit = $null
    }
}

function New-FixtureSession {
    param([string]$SessionId, [int]$ProcessId, [string]$Kind)
    [pscustomobject]@{ SessionId = $SessionId; ProcessId = $ProcessId; Kind = $Kind; RegistrationPath = '' }
}

function Get-FixtureFinder {
    param([Parameter(Mandatory)][string]$Kind)
    # Bound by name rather than by closure: the registry hands the finder no argument,
    # so the kind it speaks for has to be baked in.
    $text = @"
if (`$script:FailingKinds.ContainsKey('$Kind')) { throw `$script:FailingKinds['$Kind'] }
if (`$script:SessionsByKind.ContainsKey('$Kind')) { return `$script:SessionsByKind['$Kind'] }
@{}
"@
    [scriptblock]::Create($text)
}

# A kind the daemon does not know is the honest way to exercise the general branch
# alongside Copilot's: Get-DaemonAgent fills an unlisted kind from Copilot's slots.
$script:DaemonAgents['copilot'].FindSessions = Get-FixtureFinder -Kind 'copilot'
$script:DaemonAgents['fixture'] = @{ FindSessions = (Get-FixtureFinder -Kind 'fixture'); KnowsProcessId = $true }

function Reset-FixtureState {
    param([string[]]$Kinds = @('copilot'))
    $script:SelectedKinds = @($Kinds)
    $script:ProcessesByAgent = @{}
    $script:ProcessReadKnown = $true
    $script:ProcessDiagnostics = @()
    $script:CommandLines = @{}
    $script:CommandLineState = 'Readable'
    $script:SessionsByKind = @{}
    $script:FailingKinds = @{}
    $script:AgentProcessCalls = [Collections.Generic.List[object]]::new()
    $script:DaemonAgentCache = @{}
    $script:DaemonAdapterFailureReported = @{}
    $script:DaemonOwnerCatalogue = @{}
    $script:DaemonPendingRetire = @()
    $script:DaemonDiscoverySnapshot = $null
    $script:ClaudeAdapterLoaded = $false
    $script:CodexAdapterLoaded = $false
    if (Test-Path -LiteralPath $script:DaemonConfig.LogFile) {
        Remove-Item -LiteralPath $script:DaemonConfig.LogFile -Force
    }
}

function Get-FixtureLogText {
    if (-not (Test-Path -LiteralPath $script:DaemonConfig.LogFile)) { return '' }
    [string](Get-Content -LiteralPath $script:DaemonConfig.LogFile -Raw)
}

function Get-FixtureDiagnosticCodes {
    param([Parameter(Mandatory)]$Snapshot)
    @($Snapshot.Diagnostics | ForEach-Object { $_.Code })
}

# ------------------------------------------------------------ a healthy pass ----

Write-Host 'A pass in which every adapter answers'

Reset-FixtureState -Kinds @('copilot', 'fixture')
$script:ProcessesByAgent = @{
    copilot = @([pscustomobject]@{ Id = 4242 })
    fixture = @([pscustomobject]@{ Id = 5353 })
}
$script:SessionsByKind = @{
    copilot = @{ 'copilot-1' = New-FixtureSession -SessionId 'copilot-1' -ProcessId 4242 -Kind 'copilot' }
    fixture = @{ 'fixture-1' = New-FixtureSession -SessionId 'fixture-1' -ProcessId 5353 -Kind 'fixture' }
}
$healthy = Get-DaemonSessionDiscovery

Test-That 'a pass in which every adapter answers reports each kind''s sessions as live' {
    $healthy.Live.Count -eq 2 -and $healthy.Live.ContainsKey('copilot-1') -and $healthy.Live.ContainsKey('fixture-1')
} "live: $($healthy.Live.Keys -join ', ')"

Test-That 'and is complete, so a session that has gone may be retired' {
    $healthy.Complete -and (Test-DaemonRetirementObservation -Snapshot $healthy -SessionId 'vanished')
}

Test-That 'a session that is still live is never a candidate for retirement' {
    -not (Test-DaemonRetirementObservation -Snapshot $healthy -SessionId 'copilot-1')
}

Test-That 'discovery asks the platform for an observation, never for a bare list' {
    $script:AgentProcessCalls.Count -gt 0 -and
        @($script:AgentProcessCalls | Where-Object { -not $_.AsObservation }).Count -eq 0
} "calls: $($script:AgentProcessCalls.Count)"

# --------------------------------------------------- one adapter out of three ----

Write-Host ''
Write-Host 'One adapter failing while the others answer'

Reset-FixtureState -Kinds @('copilot', 'fixture')
$script:ProcessesByAgent = @{ fixture = @([pscustomobject]@{ Id = 5353 }) }
$script:SessionsByKind = @{
    fixture = @{ 'fixture-1' = New-FixtureSession -SessionId 'fixture-1' -ProcessId 5353 -Kind 'fixture' }
}
$script:FailingKinds = @{ copilot = 'Registration directory is unreadable.' }
$partial = Get-DaemonSessionDiscovery

Test-That 'one adapter failing does not take the others'' sessions down with it' {
    $partial.Live.ContainsKey('fixture-1')
} "live: $($partial.Live.Keys -join ', ')"

Test-That 'the kind that failed is recorded as unreadable' {
    (Get-FixtureDiagnosticCodes -Snapshot $partial) -contains 'AdapterReadFailed' -and
        @($partial.Diagnostics | Where-Object { $_.Code -eq 'AdapterReadFailed' -and $_.Kind -eq 'copilot' }).Count -eq 1
} "codes: $((Get-FixtureDiagnosticCodes -Snapshot $partial) -join ', ')"

Test-That 'and the pass is held incomplete, so nothing absent is retired on its word' {
    -not $partial.Complete -and -not (Test-DaemonRetirementObservation -Snapshot $partial -SessionId 'vanished')
}

Test-That 'the log says which adapter failed and why, not only that discovery is uncertain' {
    (Get-FixtureLogText) -match 'adapter copilot could not be read: Registration directory is unreadable\.'
}

# ------------------------------------------------- the reason, reported once ----

Write-Host ''
Write-Host 'Reporting a reason once rather than on every reconcile'

Reset-FixtureState -Kinds @('copilot')
$script:FailingKinds = @{ copilot = 'Registration directory is unreadable.' }
[void](Get-DaemonSessionDiscovery)
[void](Get-DaemonSessionDiscovery)
[void](Get-DaemonSessionDiscovery)

Test-That 'a reason that has not changed is logged once, not on every reconcile' {
    @([regex]::Matches((Get-FixtureLogText), 'adapter copilot could not be read')).Count -eq 1
} "matches: $(@([regex]::Matches((Get-FixtureLogText), 'adapter copilot could not be read')).Count)"

$script:FailingKinds = @{ copilot = 'Something else broke.' }
[void](Get-DaemonSessionDiscovery)

Test-That 'but a new reason from the same adapter is still reported' {
    (Get-FixtureLogText) -match 'adapter copilot could not be read: Something else broke\.' -and
        @([regex]::Matches((Get-FixtureLogText), 'adapter copilot could not be read')).Count -eq 2
}

Test-That 'uncertainty itself is still logged every pass, so the hold stays visible' {
    @([regex]::Matches((Get-FixtureLogText), 'session discovery uncertain')).Count -ge 4
} "matches: $(@([regex]::Matches((Get-FixtureLogText), 'session discovery uncertain')).Count)"

# ------------------------------------------------- a partial read of the host ----

Write-Host ''
Write-Host 'A process list that could not be read in full'

Reset-FixtureState -Kinds @('copilot')
$script:ProcessReadKnown = $false
$partialHost = Get-DaemonSessionDiscovery

Test-That 'a process list that could not be read in full is not read as no sessions' {
    -not $partialHost.Complete -and (Get-FixtureDiagnosticCodes -Snapshot $partialHost) -contains 'IncompleteAdapter'
} "codes: $((Get-FixtureDiagnosticCodes -Snapshot $partialHost) -join ', ')"

Reset-FixtureState -Kinds @('copilot')
$script:ProcessesByAgent = @{ copilot = @([pscustomobject]@{ Id = 4242 }) }
$script:SessionsByKind = @{
    copilot = @{ 'copilot-1' = New-FixtureSession -SessionId 'copilot-1' -ProcessId 9999 -Kind 'copilot' }
}
$unresolved = Get-DaemonSessionDiscovery

Test-That 'a registration whose process is not running is not reported live' {
    -not $unresolved.Live.ContainsKey('copilot-1')
} "live: $($unresolved.Live.Keys -join ', ')"

Test-That 'and a process with no registration of its own holds absence-based work' {
    (Get-FixtureDiagnosticCodes -Snapshot $unresolved) -contains 'UnaccountedProcess' -and -not $unresolved.Complete
} "codes: $((Get-FixtureDiagnosticCodes -Snapshot $unresolved) -join ', ')"

# ------------------------------------------------- an embedded, headless CLI ----

Write-Host ''
Write-Host 'An agent CLI embedded in another app'

# Microsoft Scout ships the Copilot CLI inside its own app and runs it headless, so
# it carries no --session-id and writes no lock. Nothing can ever account for it, and
# demanding a session for it held retirement, startup cleanup and every launch on
# DSWETT-DEV-VM1 for a whole day while a dead card stayed on the dashboard.
Reset-FixtureState -Kinds @('copilot')
$script:ProcessesByAgent = @{ copilot = @([pscustomobject]@{ Id = 22400 }) }
$script:CommandLines = @{ 22400 = '"C:\Apps\Scout\copilot.exe" --headless --no-auto-update --log-level info --stdio' }
$headless = Get-DaemonSessionDiscovery

Test-That 'an embedded headless CLI does not have to belong to a session' {
    $headless.Complete -and (Get-FixtureDiagnosticCodes -Snapshot $headless) -notcontains 'UnaccountedProcess'
} "complete=$($headless.Complete) codes: $((Get-FixtureDiagnosticCodes -Snapshot $headless) -join ', ')"

Reset-FixtureState -Kinds @('copilot')
$script:ProcessesByAgent = @{ copilot = @([pscustomobject]@{ Id = 22401 }) }
$script:CommandLines = @{ 22401 = '"C:\Users\u\.copilot-cli\copilot.exe" --banner --allow-all' }
$ordinary = Get-DaemonSessionDiscovery

Test-That 'while an ordinary session process with no session still holds it' {
    -not $ordinary.Complete -and (Get-FixtureDiagnosticCodes -Snapshot $ordinary) -contains 'UnaccountedProcess'
} "codes: $((Get-FixtureDiagnosticCodes -Snapshot $ordinary) -join ', ')"

Reset-FixtureState -Kinds @('copilot')
$script:ProcessesByAgent = @{ copilot = @([pscustomobject]@{ Id = 22402 }) }
$script:CommandLineState = 'Unknown'
$script:CommandLines = @{ 22402 = '' }
$unreadable = Get-DaemonSessionDiscovery

Test-That 'and an unreadable command line is not permission to excuse a process' {
    -not $unreadable.Complete -and (Get-FixtureDiagnosticCodes -Snapshot $unreadable) -contains 'UnaccountedProcess'
} "codes: $((Get-FixtureDiagnosticCodes -Snapshot $unreadable) -join ', ')"

Reset-FixtureState -Kinds @('copilot')
$script:ProcessesByAgent = @{ copilot = @([pscustomobject]@{ Id = 22403 }) }
$script:CommandLineState = 'Absent'
$departed = Get-DaemonSessionDiscovery

Test-That 'a process that exits mid-check is absence, not uncertainty' {
    $departed.Complete -and (Get-FixtureDiagnosticCodes -Snapshot $departed) -notcontains 'UnaccountedProcess'
} "complete=$($departed.Complete) codes: $((Get-FixtureDiagnosticCodes -Snapshot $departed) -join ', ')"

$script:CommandLineState = 'Readable'

# ------------------------------------------------------- an adapter not there ----

Write-Host ''
Write-Host 'An adapter that is not installed'

Reset-FixtureState -Kinds @('claude')
$absent = Get-DaemonSessionDiscovery

Test-That 'an adapter that was never installed is absence, not uncertainty' {
    $absent.Complete -and $absent.Live.Count -eq 0 -and $absent.Diagnostics.Count -eq 0
} "complete=$($absent.Complete) codes: $((Get-FixtureDiagnosticCodes -Snapshot $absent) -join ', ')"

Reset-FixtureState -Kinds @('claude')
$claudeRoot = Get-BridgeRuntimePath 'agent-bridge-claude'
New-Item -ItemType Directory -Path $claudeRoot -Force | Out-Null
Set-Content -LiteralPath (Join-Path $claudeRoot 'left-behind.json') -Value '{}' -Encoding utf8
$orphaned = Get-DaemonSessionDiscovery

Test-That 'an adapter gone while its registrations remain is uncertainty, not death' {
    -not $orphaned.Complete -and (Get-FixtureDiagnosticCodes -Snapshot $orphaned) -contains 'AdapterUnavailable'
} "codes: $((Get-FixtureDiagnosticCodes -Snapshot $orphaned) -join ', ')"

Remove-Item -LiteralPath $claudeRoot -Recurse -Force -ErrorAction SilentlyContinue

# -------------------------------------------------------- the 1.33.0 failure ----

Write-Host ''
Write-Host 'An adapter older than the contract the core calls'

# The real thing: an adapter directory outside hooks/ carrying its own copy of
# bridge-platform.ps1, from before -AsObservation existed. Dot-sourcing it here
# shadows the core's exactly as the leftover 9/30 copy did on 2026-10-06.
$script:StaleAdapter = Join-Path $script:FixtureRoot 'ha-bridge\bridge-platform.ps1'
New-Item -ItemType Directory -Path (Split-Path -Parent $script:StaleAdapter) -Force | Out-Null
Set-Content -LiteralPath $script:StaleAdapter -Encoding utf8 -Value @'
function Get-BridgeAgentProcesses {
    param([Parameter(Mandatory)][string]$Agent)
    [pscustomobject]@{ Known = $true; Processes = @(); Diagnostics = @() }
}
'@

Reset-FixtureState -Kinds @('copilot')
$script:SessionsByKind = @{
    copilot = @{ 'copilot-1' = New-FixtureSession -SessionId 'copilot-1' -ProcessId 4242 -Kind 'copilot' }
}
$priorState = @{ 'copilot-1' = New-FixtureSession -SessionId 'copilot-1' -ProcessId 4242 -Kind 'copilot' }

. $script:StaleAdapter
$skewed = Get-DaemonSessionDiscovery -State $priorState
$skewLog = Get-FixtureLogText
${function:Get-BridgeAgentProcesses} = $script:ObservingAgentProcesses

Test-That 'an adapter older than the contract the core calls does not stop discovery' {
    $null -ne $skewed -and (Test-DaemonDiscoveryContext -Snapshot $skewed)
}

Test-That 'the skew is reported as an unreadable adapter rather than silence' {
    (Get-FixtureDiagnosticCodes -Snapshot $skewed) -contains 'AdapterReadFailed'
} "codes: $((Get-FixtureDiagnosticCodes -Snapshot $skewed) -join ', ')"

Test-That 'the log names the missing parameter, which is what cost an hour on 2026-10-06' {
    $skewLog -match 'adapter copilot could not be read:.*AsObservation'
} $skewLog

Test-That 'a session the stale adapter could not account for is not retired' {
    -not (Test-DaemonRetirementObservation -Snapshot $skewed -SessionId 'copilot-1') -and -not $skewed.Complete
}

Test-That 'nor is any other session, while the adapter cannot be read at all' {
    -not (Test-DaemonRetirementObservation -Snapshot $skewed -SessionId 'some-other-session')
}

Test-That 'restoring the adapter restores discovery without a daemon restart' {
    Reset-FixtureState -Kinds @('copilot')
    $script:ProcessesByAgent = @{ copilot = @([pscustomobject]@{ Id = 4242 }) }
    $script:SessionsByKind = @{
        copilot = @{ 'copilot-1' = New-FixtureSession -SessionId 'copilot-1' -ProcessId 4242 -Kind 'copilot' }
    }
    $recovered = Get-DaemonSessionDiscovery
    $recovered.Complete -and $recovered.Live.ContainsKey('copilot-1')
}

# ------------------------------------------------------------- the test guard ----

Write-Host ''
Write-Host 'The offline guard'

Reset-FixtureState -Kinds @('copilot')
${function:Get-BridgeAgentProcesses} = {
    param([Parameter(Mandatory)][string]$Agent, [switch]$AsObservation)
    $blocked = [InvalidOperationException]::new('A test blocked this call.')
    $blocked.Data['BridgeTestNetworkBlocked'] = $true
    throw $blocked
}

Test-That 'the offline guard is never swallowed as an unreadable adapter' {
    $threw = $false
    try { [void](Get-DaemonSessionDiscovery) } catch { $threw = $true }
    $threw
}

Test-That 'and nothing claims the adapter was merely unreadable' {
    (Get-FixtureLogText) -notmatch 'adapter copilot could not be read'
}

${function:Get-BridgeAgentProcesses} = $script:ObservingAgentProcesses

Remove-Item -LiteralPath $script:FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All daemon discovery checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
