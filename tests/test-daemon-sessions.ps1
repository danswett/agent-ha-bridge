#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the card lifecycle (hooks/daemon-sessions.ps1): one reconcile pass, and
    each of its steps on its own.

.DESCRIPTION
    Sync-DaemonSessions was one 428-line function, exercised only end to end. Its steps
    are separate functions now, so each is checked here in isolation with Home
    Assistant stood in for - nothing is published and nothing leaves the machine.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
$script:DaemonConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-daemon-sessions-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"
$script:FakeLaunchers = @('agency', 'copilot')
$script:FakeProfiles = @('work', 'home')
function Get-BridgeAvailableLaunchers { @($script:FakeLaunchers) }
function Get-BridgeAgencyProfiles { @($script:FakeProfiles) }

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

$headers = @{ Authorization = 'Bearer test' }

Write-Host '--- what every machine is running ---'
$local = @(
    [pscustomobject]@{ Node = 'agent_bridge_a'; Name = 'Claude: repo'; Machine = 'DESK'; Kind = 'claude' }
    [pscustomobject]@{ Node = 'agent_bridge_mcp'; Name = 'MCP: tool'; Machine = ''; Kind = 'mcp' }
)
$peers = @(
    [pscustomobject]@{ Slug = 'laptop'; Machine = 'LAPTOP'; Online = $true; Capabilities = @{ profile = $true; resume = $true; agent = $false }
        Sessions = @(@{ node = 'agent_bridge_b'; name = 'Codex: work'; machine = 'LAPTOP'; kind = 'codex' }, @{ node = 'agent_bridge_mcp'; name = 'MCP: tool'; machine = ''; kind = 'mcp' }) }
    [pscustomobject]@{ Slug = 'attic'; Machine = 'ATTIC'; Online = $false; Capabilities = $null
        Sessions = @(@{ node = 'agent_bridge_c'; name = 'Copilot: stale'; machine = 'ATTIC'; kind = 'copilot' }) }
)
$all = @(Get-DaemonAllDescriptors -Descriptors $local -Peers $peers)
Test-That 'a peer''s sessions join this machine''s' { @($all | Where-Object Node -eq 'agent_bridge_b').Count -eq 1 }
Test-That 'an MCP client both report appears once' { @($all | Where-Object Node -eq 'agent_bridge_mcp').Count -eq 1 }
Test-That 'an offline machine''s leftover sessions are not shown as live' { @($all | Where-Object Node -eq 'agent_bridge_c').Count -eq 0 }

Write-Host '--- the machine cards ---'
$cards = @(Get-DaemonMachineCards -Capabilities @{ profile = $false; resume = $true; agent = $true } -Peers $peers)
Test-That 'every registered machine gets one, sorted so rebuilds match' { ($cards.Slug -join ',') -eq (@($cards.Slug | Sort-Object) -join ',') -and $cards.Count -eq 3 }
Test-That 'this machine is online by definition, with its own capabilities' {
    $me = $cards | Where-Object Slug -eq $script:DaemonMachineSlug
    $me.Online -and $me.IncludeResume -and $me.IncludeAgent -and -not $me.IncludeProfile
}
Test-That 'a peer carries what it reported' { $p = $cards | Where-Object Slug -eq 'laptop'; $p.IncludeProfile -and -not $p.IncludeAgent }
Test-That 'a peer that reported nothing offers nothing' { $p = $cards | Where-Object Slug -eq 'attic'; -not $p.IncludeProfile -and -not $p.Online }

# Model, effort and context are reported as a capability of their own, so a peer still
# running a bridge from before those entities existed gets a launch card without the
# rows rather than three "Entity not found" boxes.
Test-That 'a capability set from before the tuning rows is read, not thrown on' {
    $me = @(Get-DaemonMachineCards -Capabilities @{ profile = $false; resume = $true; agent = $true } -Peers @()) |
        Where-Object Slug -eq $script:DaemonMachineSlug
    $me.IncludeTuning -eq $false
}
Test-That 'and a machine that has them says so' {
    $me = @(Get-DaemonMachineCards -Capabilities @{ profile = $false; resume = $true; agent = $true; tuning = $true } -Peers @()) |
        Where-Object Slug -eq $script:DaemonMachineSlug
    $me.IncludeTuning
}
Test-That 'a peer without the capability gets no tuning rows' {
    (@(Get-DaemonMachineCards -Capabilities @{ profile = $false; resume = $true; agent = $true } -Peers $peers) |
        Where-Object Slug -eq 'laptop').IncludeTuning -eq $false
}

Write-Host '--- what a session is running with ---'
# The command line is the only record of effort and context: neither appears in a
# transcript and no agent reports them back, so the daemon keeps what it launched with
# and hands it to the card. A session started at a keyboard has none, and its card
# then shows no settings line rather than guessing at the agent's defaults.
$script:DaemonLaunchedTuning = @{}
$launchedId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
$script:DaemonLaunchedTuning[$launchedId] = [pscustomobject]@{
    Model = 'gpt-5.4'; Effort = 'xhigh'; Context = 'long_context'; At = [DateTimeOffset]::Now
}
$claimed = Get-DaemonSessionTuning -SessionId $launchedId
Test-That 'a session the bridge launched carries what it was launched with' {
    $claimed.Model -eq 'gpt-5.4' -and $claimed.Effort -eq 'xhigh' -and $claimed.Context -eq 'long_context'
}
Test-That 'and the record is consumed, so nothing else can inherit it' {
    -not $script:DaemonLaunchedTuning.ContainsKey($launchedId)
}
Test-That 'a session the bridge did not launch carries nothing' {
    $none = Get-DaemonSessionTuning -SessionId 'ffffffff-0000-0000-0000-000000000000'
    $none.Model -eq '' -and $none.Effort -eq '' -and $none.Context -eq ''
}

# Codex picks its own id, so its launch is filed under a pending key and claimed by
# the first session to appear - the same rule its registration matcher already uses.
# Codex picks its own id, so its launch waits under the pending key until
# Update-DaemonPendingLaunch learns which session it produced and moves the record
# across. Nothing claims a pending record by guesswork, so an unrelated session
# adopted in the meantime gets nothing.
$script:DaemonLaunchedTuning = @{ $script:DaemonPendingTuningKey = [pscustomobject]@{
    Model = 'gpt-5.3-codex'; Effort = 'high'; Context = ''; At = [DateTimeOffset]::Now } }
Test-That 'a session adopted while a launch is still pending claims nothing' {
    (Get-DaemonSessionTuning -SessionId 'opened-by-hand').Effort -eq '' -and
    $script:DaemonLaunchedTuning.ContainsKey($script:DaemonPendingTuningKey)
}
Test-That 'and once the launch is re-keyed onto the id it registered under, that session gets it' {
    $real = 'codex-picked-this-id'
    $script:DaemonLaunchedTuning[$real] = $script:DaemonLaunchedTuning[$script:DaemonPendingTuningKey]
    [void]$script:DaemonLaunchedTuning.Remove($script:DaemonPendingTuningKey)
    (Get-DaemonSessionTuning -SessionId $real).Effort -eq 'high'
}
# A launch whose session never appears would otherwise sit here for the life of the
# daemon, and the next launch of that agent would find it waiting.
$script:DaemonLaunchedTuning = @{ $script:DaemonPendingTuningKey = [pscustomobject]@{
    Model = 'gpt-5.3-codex'; Effort = 'high'; Context = ''; At = [DateTimeOffset]::Now.AddMinutes(-20) } }
Clear-DaemonStaleLaunchTuning
Test-That 'a launch that never registered is eventually dropped' {
    $script:DaemonLaunchedTuning.Count -eq 0
}
$script:DaemonLaunchedTuning = @{ 'fresh-one' = [pscustomobject]@{
    Model = 'gpt-5.4'; Effort = ''; Context = ''; At = [DateTimeOffset]::Now } }
Clear-DaemonStaleLaunchTuning
Test-That 'while one still waiting on its session is left alone' {
    $script:DaemonLaunchedTuning.ContainsKey('fresh-one')
}

# Codex names its model on every hook call, which beats the launch record for the same
# reason a transcript beats a command line: it is what the session is actually using.
$script:DaemonLaunchedTuning = @{ $launchedId = [pscustomobject]@{
    Model = 'gpt-5.4'; Effort = 'xhigh'; Context = ''; At = [DateTimeOffset]::Now } }
Test-That 'a model the agent reports itself wins over the one it was launched with' {
    $reported = Get-DaemonSessionTuning -SessionId $launchedId -Session ([pscustomobject]@{ Model = 'gpt-5.3-codex' })
    $reported.Model -eq 'gpt-5.3-codex' -and $reported.Effort -eq 'xhigh'
}

Test-That 'only settings that are known reach the card' {
    $attrs = Add-DaemonTuningAttributes -Attributes @{ session = 'x' } `
        -Tuning ([pscustomobject]@{ Model = 'gpt-5.4'; Effort = ''; Context = $null })
    $attrs['model'] -eq 'gpt-5.4' -and -not $attrs.ContainsKey('effort') -and -not $attrs.ContainsKey('context')
}
Test-That 'a session restored from an older state file simply has none' {
    $attrs = Add-DaemonTuningAttributes -Attributes @{ session = 'x' } -Tuning ([pscustomobject]@{ Name = 'old' })
    $attrs.Count -eq 1
}
$script:DaemonLaunchedTuning = @{}

Write-Host '--- one reconcile pass ---'
# Everything that would reach Home Assistant is stood in for.
$script:Log = @()
$script:Published = @()
$script:Retired = @()
$script:FailPublish = @{}
function Write-DaemonLog { param([string]$Message) $script:Log += $Message }
function Get-HomeAssistantState { param([string]$EntityId, [hashtable]$Headers) $null }
function Publish-CopilotMqttSession { param($SessionId, $SessionName, $Machine, $Headers)
    if ($script:FailPublish[$SessionId]) { throw 'broker down' }; $script:Published += $SessionId }
function Set-CopilotMqttEntityIds { param($SessionId) $true }
function Clear-CopilotMqttDecisionFields { param($SessionId, $SessionName, $Machine, $Headers) }
function Publish-CopilotMqttSubmitButton { param($SessionId, $SessionName, $Machine, $Headers) }
# These emit something, as real calls can, to prove none of it leaks into what is returned.
function Set-CopilotMqttStatus { param($SessionId, $Status, $Headers, $Attributes) $script:StatusAttributes[$SessionId] = $Attributes; 'status-response' }
$script:StatusAttributes = @{}
function Set-CopilotMqttActivity { param($SessionId, $Summary, $Detail, $Headers) }
function Invoke-HomeAssistantService { param($Domain, $Service, $Headers, $Data) @('service', 'response') }
function Start-Sleep { param($Milliseconds, $Seconds) }
function Get-LiveMcpSessions { param($Headers) @{} }
function Get-DaemonPeerMachines { param($Headers) @() }
function Publish-CopilotMqttGlobalStatus { param($Headers, $Capabilities, $Sessions) $script:GlobalSessions = @($Sessions) }
function Publish-CopilotMqttMachineHeartbeat { param($Slug, $Headers) }
function Get-BridgeServedReplyCardUrl { '' }
function Set-CopilotMqttGlobalEntityId { $true }
function Clear-DaemonLaunchNoteOnRegistration { param($Headers) $script:NoteCleared = ($script:NoteCleared + 1) }
function Initialize-BridgeMachineSelector { param($Machines) '' }
function Save-CopilotSessionDashboard { param($Sessions, $Machines, $MachineSelector, $ReplyCardUrl) $script:DashboardSessions = @($Sessions); 'saved' }
function Remove-CopilotMqttSession { param($SessionId, $Headers) $script:Retired += $SessionId }
function Remove-CopilotDecisionMarker { param($SessionId) }
function Update-DaemonSessionActivity { param($Id, $Entry, $Session, $Headers, $VerboseOn) $script:Streamed += $Id }
function Test-BridgeSessionWorking { param($SessionId, $Kind, $Transcript, $Status) $false }
function Get-BridgeSessionDisplay { param($SessionId, $Kind, $WorkingDirectory)
    $resolved = if ($script:DisplayNames.ContainsKey($SessionId)) { $script:DisplayNames[$SessionId] } else { "Claude: $SessionId" }
    [pscustomobject]@{ Name = $resolved; Machine = 'DESK' } }
$script:DisplayNames = @{}
$script:DaemonDashboardSignature = $null
$script:DaemonPendingRetire = @()
$script:Streamed = @()
$script:NoteCleared = 0

# Real ids are UUIDs, and the log lines take their first eight characters.
$script:Ids = @{ s1 = '11111111-0000-4000-8000-000000000001'; s2 = '22222222-0000-4000-8000-000000000002'; s3 = '33333333-0000-4000-8000-000000000003'
    s4 = '44444444-0000-4000-8000-000000000004'; s5 = '55555555-0000-4000-8000-000000000005' }
function New-Session { param([string]$Id) [pscustomobject]@{ SessionId = $script:Ids[$Id]; Kind = 'claude'; Transcript = 'C:\nope.jsonl'; WorkingDirectory = 'C:\x'; ProcessId = 1 } }
$state = @{}
Sync-DaemonSessions -Headers $headers -State $state -Live @{ $script:Ids.s1 = (New-Session 's1'); $script:Ids.s2 = (New-Session 's2') }
Test-That 'new sessions are published and adopted into state' { (@($script:Published | Sort-Object) -join ',') -eq (@($script:Ids.s1, $script:Ids.s2) -join ',') -and $state.Count -eq 2 }
# A session registering is what says a launch note about one not registering is out of
# date - the 90-second wait is short for a first launch that has to sign in first.
Test-That 'and each one clears any launch note still claiming it never arrived' { $script:NoteCleared -eq 2 }
Test-That 'with an entry that starts at the transcript''s end' { $state[$script:Ids.s1].Offset -eq 0 -and $state[$script:Ids.s1].Kind -eq 'claude' }
Test-That 'and the dashboard is built with them' { @($script:DashboardSessions).Count -eq 2 }
Test-That 'the global status lists them' { @($script:GlobalSessions).Count -eq 2 }

$script:Published = @(); $script:FailPublish = @{ $script:Ids.s3 = $true }
Sync-DaemonSessions -Headers $headers -State $state -Live @{ $script:Ids.s1 = (New-Session 's1'); $script:Ids.s2 = (New-Session 's2'); $script:Ids.s3 = (New-Session 's3') }
Test-That 'a session whose publish fails is not adopted, so it is tried again' { -not $state.ContainsKey($script:Ids.s3) }
Test-That 'known sessions stream their activity instead of being republished' { $script:Streamed -contains $script:Ids.s1 -and $script:Published.Count -eq 0 }

Sync-DaemonSessions -Headers $headers -State $state -Live @{ $script:Ids.s1 = (New-Session 's1') }
Test-That 'an ended session leaves state at once' { -not $state.ContainsKey($script:Ids.s2) }
Test-That 'and its card leaves the dashboard' { @($script:DashboardSessions).Count -eq 1 }
Test-That 'but its entities wait a pass, so the browser is not left pointing at nothing' { $script:Retired.Count -eq 0 }
Sync-DaemonSessions -Headers $headers -State $state -Live @{ $script:Ids.s1 = (New-Session 's1') }
Test-That 'and are retired on the next' { ($script:Retired -join ',') -eq $script:Ids.s2 }

$rebuilds = @($script:Log | Where-Object { $_ -like 'dashboard rebuilt*' }).Count
Sync-DaemonSessions -Headers $headers -State $state -Live @{ $script:Ids.s1 = (New-Session 's1') }
Test-That 'an unchanged pass does not rebuild the dashboard' { @($script:Log | Where-Object { $_ -like 'dashboard rebuilt*' }).Count -eq $rebuilds }

Write-Host '--- a session renamed while it runs ---'
# Copilot takes its name from its workspace file, which the user can rewrite at any
# point; the name it was adopted under says nothing about whether it is still current.
$renamed = $script:Ids.s4
function New-CopilotSession { param([string]$Id) [pscustomobject]@{ SessionId = $script:Ids[$Id]; Kind = 'copilot'; Transcript = 'C:\nope.jsonl'; WorkingDirectory = 'C:\x'; ProcessId = 1 } }
$script:DisplayNames[$renamed] = 'Copilot: the whole first prompt, at length'
$renameState = @{}
Sync-DaemonSessions -Headers $headers -State $renameState -Live @{ $renamed = (New-CopilotSession 's4') }
Test-That 'it is adopted under the name its workspace file gave' { $renameState[$renamed].Name -eq 'Copilot: the whole first prompt, at length' }

$script:DisplayNames[$renamed] = 'Copilot: agent-ha-bridge'
$renameLeak = Sync-DaemonSessions -Headers $headers -State $renameState -Live @{ $renamed = (New-CopilotSession 's4') }
Test-That 'renaming it is picked up next pass, though the old name looked perfectly real' { $renameState[$renamed].Name -eq 'Copilot: agent-ha-bridge' }
Test-That 'the new name reaches its status attributes' { $script:StatusAttributes[$renamed].session -eq 'Copilot: agent-ha-bridge' }
Test-That 'and its card header' { @($script:DashboardSessions | Where-Object { $_.Name -eq 'Copilot: agent-ha-bridge' }).Count -eq 1 }
Test-That 'and the republish it triggers returns nothing to the reconcile' { $null -eq $renameLeak } ($renameLeak -join ',')

# The other half of the same check: a session of any kind can be holding the Copilot
# id fallback, from a build that published it before its own adapter had loaded.
$stale = $script:Ids.s5
$staleState = @{ $stale = [pscustomobject]@{ Offset = 0; Name = "Copilot: $($stale.Substring(0, 8))"; Machine = 'DESK'; Status = 'idle'; Kind = 'claude' } }
Sync-DaemonSessions -Headers $headers -State $staleState -Live @{ $stale = (New-Session 's5') }
Test-That 'a stale id fallback on another agent still heals' { $staleState[$stale].Name -eq "Claude: $stale" }

Write-Host ''
Write-Host '--- what this machine''s launch card can offer ---'
# The profile row is only worth drawing when there are profiles to choose between. A
# machine whose Agency has none - a new one, before whatever syncs the Agency config
# has run on it - used to get a row offering three that did not exist there, and
# every launch from it died before Copilot started.
function Get-BridgeSetting {
    param([Parameter(Mandatory)][string]$Path, $Default = $null)
    if ($Path -eq 'newSession.enabled') { return $true }
    $Default
}
Test-That 'Agency with profiles gets a profile row' { (Get-DaemonLaunchCapabilities).profile }
$script:FakeProfiles = @()
Test-That 'Agency with none gets no profile row' { -not (Get-DaemonLaunchCapabilities).profile }
Test-That 'though the rest of the card is untouched' {
    $caps = Get-DaemonLaunchCapabilities
    $caps.newSession -and $caps.resume -and $caps.agent -and $caps.tuning
}
$script:FakeProfiles = @('work', 'home')
$script:FakeLaunchers = @('copilot')
Test-That 'and a machine without Agency never gets one' { -not (Get-DaemonLaunchCapabilities).profile }

Remove-Item -LiteralPath $script:DaemonConfig.LogFile -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All daemon session checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
