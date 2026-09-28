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
function Set-CopilotMqttStatus { param($SessionId, $Status, $Headers, $Attributes) 'status-response' }
function Set-CopilotMqttActivity { param($SessionId, $Summary, $Detail, $Headers) }
function Invoke-HomeAssistantService { param($Domain, $Service, $Headers, $Data) @('service', 'response') }
function Start-Sleep { param($Milliseconds, $Seconds) }
function Get-LiveMcpSessions { param($Headers) @{} }
function Get-DaemonPeerMachines { param($Headers) @() }
function Publish-CopilotMqttGlobalStatus { param($Headers, $Capabilities, $Sessions) $script:GlobalSessions = @($Sessions) }
function Publish-CopilotMqttMachineHeartbeat { param($Slug, $Headers) }
function Get-BridgeServedReplyCardUrl { '' }
function Set-CopilotMqttGlobalEntityId { $true }
function Initialize-BridgeMachineSelector { param($Machines) '' }
function Save-CopilotSessionDashboard { param($Sessions, $Machines, $MachineSelector, $ReplyCardUrl) $script:DashboardSessions = @($Sessions); 'saved' }
function Remove-CopilotMqttSession { param($SessionId, $Headers) $script:Retired += $SessionId }
function Remove-CopilotDecisionMarker { param($SessionId) }
function Update-DaemonSessionActivity { param($Id, $Entry, $Session, $Headers, $VerboseOn) $script:Streamed += $Id }
function Test-BridgeSessionWorking { param($SessionId, $Kind, $Transcript, $Status) $false }
function Get-BridgeSessionDisplay { param($SessionId, $Kind, $WorkingDirectory) [pscustomobject]@{ Name = "Claude: $SessionId"; Machine = 'DESK' } }
$script:DaemonDashboardSignature = $null
$script:DaemonPendingRetire = @()
$script:Streamed = @()

# Real ids are UUIDs, and the log lines take their first eight characters.
$script:Ids = @{ s1 = '11111111-0000-4000-8000-000000000001'; s2 = '22222222-0000-4000-8000-000000000002'; s3 = '33333333-0000-4000-8000-000000000003' }
function New-Session { param([string]$Id) [pscustomobject]@{ SessionId = $script:Ids[$Id]; Kind = 'claude'; Transcript = 'C:\nope.jsonl'; WorkingDirectory = 'C:\x'; ProcessId = 1 } }
$state = @{}
Sync-DaemonSessions -Headers $headers -State $state -Live @{ $script:Ids.s1 = (New-Session 's1'); $script:Ids.s2 = (New-Session 's2') }
Test-That 'new sessions are published and adopted into state' { (@($script:Published | Sort-Object) -join ',') -eq (@($script:Ids.s1, $script:Ids.s2) -join ',') -and $state.Count -eq 2 }
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

Remove-Item -LiteralPath $script:DaemonConfig.LogFile -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All daemon session checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
