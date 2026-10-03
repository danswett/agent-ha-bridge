#Requires -Version 7.0
<#
.SYNOPSIS
    PROPOSED tests for sharing resumable sessions between machines
    (hooks/daemon-launch.ps1, hooks/daemon-sessions.ps1, hooks/decision-mqtt.ps1).

.DESCRIPTION
    UNAPPLIED PROPOSAL - never executed. Accompanies the unapplied discovery diff; for
    the owner who applies it to run, not for me.

    Everything is stood in for: no Home Assistant, no broker, no agent CLI, no network
    and no session files. Boundaries stubbed: HA state reads, peer discovery, workspace
    approval, installed launchers, settings, the card's result line, and the launcher
    itself - counted, so a test can assert it was never called.

    Two things an earlier draft got wrong and this does not:

    * The refusal is driven through Resolve-DaemonLaunchRequest, the real consumer, not
      by calling the guard directly. Calling the guard proves the guard works; it cannot
      catch the guard being absent from the path, placed after the workspace check, or
      swallowed by the empty catch - which are the ways this actually breaks.
    * Peer entries are round-tripped through ConvertTo-Json/ConvertFrom-Json, because
      that is what Get-BridgePeerMachine hands over. Hashtables behave differently under
      PSObject.Properties probing and would pass while the real shape failed.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
$script:DaemonConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-resume-sharing-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

# --- boundaries, all stubbed ----------------------------------------------------------
$script:FakeSettings = @{}
function Get-BridgeSetting { param([string]$Name, $Default) if ($script:FakeSettings.ContainsKey($Name)) { $script:FakeSettings[$Name] } else { $Default } }
function Get-BridgeAvailableLaunchers { @('copilot', 'claude') }
function Get-BridgeLauncherLabel { param([string]$Launcher) switch ($Launcher) { 'copilot' { 'Copilot' } 'claude' { 'Claude' } default { $Launcher } } }
$script:ApprovedPaths = @('C:\Users\dswett\repos')
function Test-BridgeWorkspacePathApproved { param([string]$Path) $script:ApprovedPaths -contains $Path }
$script:FakePeers = @()
function Get-DaemonPeerMachines { param($Headers) @($script:FakePeers) }
$script:LaunchCalls = 0
function Start-BridgeCopilotSession { $script:LaunchCalls++; @{ ProcessId = 1 } }
$script:Notes = @()
function Set-CopilotMqttNewSessionResult { param([string]$Text, [hashtable]$Headers) $script:Notes += $Text; $true }
$script:HaStates = @{}
function Get-HomeAssistantState { param($EntityId, $Headers) [pscustomobject]@{ state = [string]$script:HaStates[$EntityId] } }

$headers = @{ Authorization = '******' }
function New-Local {
    param($Id, $Launcher = 'copilot', $Summary = 'a summary', $Folder = 'C:\Users\dswett\repos', $Label = 'local label')
    [pscustomobject]@{ SessionId = $Id; Launcher = $Launcher; Summary = $Summary; Folder = $Folder
        Updated = [DateTimeOffset]::Now; Label = $Label }
}
# What Get-BridgePeerMachine actually hands over: JSON, deserialized.
function New-Peer {
    param($Slug, $Machine, $Online = $true, $Shares = $true, $Entries = @())
    [pscustomobject]@{
        Slug = $Slug; Machine = $Machine; Online = $Online; IsSelf = $false
        Capabilities = [pscustomobject]@{ resumeShare = $Shares }
        Resumable = @($Entries); Sessions = @()
    } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
}
function New-RemoteEntry {
    param($Id, $Launcher = 'claude', $Title, $Leaf)
    $h = @{ id = $Id; launcher = $Launcher; updated = [DateTimeOffset]::Now.ToString('o') }
    if ($PSBoundParameters.ContainsKey('Title')) { $h['title'] = $Title }
    if ($PSBoundParameters.ContainsKey('Leaf')) { $h['leaf'] = $Leaf }
    $h
}

Write-Host '--- a machine shares nothing unless it has been asked to ---'

$script:FakeSettings = @{}
Test-That 'sharing is off by default, so nothing is exported at all' {
    @(Get-DaemonResumableExport -Resumable @(New-Local -Id 'aaaaaaaa-1111-2222-3333-444444444444')).Count -eq 0
}
Test-That 'and the capability says so, so no peer offers this machine sessions' {
    -not (Get-DaemonLaunchCapabilities).resumeShare
}

$script:FakeSettings = @{ 'newSession.shareResumable' = $true }
$export = @(Get-DaemonResumableExport -Resumable @(New-Local -Id 'aaaaaaaa-1111-2222-3333-444444444444' -Summary 'Rotate the prod API key' -Folder 'C:\Users\dswett\repos\secret-client'))
Test-That 'turning sharing on exports the session' { $export.Count -eq 1 }
Test-That 'but still no prompt text' { -not $export[0].ContainsKey('title') }
Test-That 'and still no path or folder leaf' { -not $export[0].ContainsKey('leaf') -and -not $export[0].ContainsKey('folder') }
Test-That 'only what identifies it' {
    $export[0].id -eq 'aaaaaaaa-1111-2222-3333-444444444444' -and $export[0].launcher -eq 'copilot' -and $export[0].updated
}

$script:FakeSettings = @{ 'newSession.shareResumable' = $true; 'newSession.shareResumableDetail' = $true }
$detailed = @(Get-DaemonResumableExport -Resumable @(New-Local -Id 'bbbbbbbb-1111-2222-3333-444444444444' -Summary ('x' * 200) -Folder 'C:\Users\dswett\repos\secret-client'))
Test-That 'opting into detail bounds the title' { $detailed[0].title.Length -le 48 }
Test-That 'opting into detail shares the folder leaf and never the path' {
    $detailed[0].leaf -eq 'secret-client' -and -not $detailed[0].ContainsKey('folder')
}

Write-Host '--- bounds, and settings that are not what they claim to be ---'

$script:FakeSettings = @{ 'newSession.shareResumable' = $true; 'newSession.resumeCount' = 3 }
Test-That 'the shared list is capped by entry count' {
    @(Get-DaemonResumableExport -Resumable @(1..20 | ForEach-Object { New-Local -Id "cccccccc-0000-0000-0000-00000000$('{0:D4}' -f $_)" })).Count -eq 3
}
$script:FakeSettings = @{ 'newSession.shareResumable' = $true; 'newSession.shareResumableDetail' = $true
    'newSession.resumeCount' = 50; 'newSession.shareResumableMaxBytes' = 400 }
$big = @(Get-DaemonResumableExport -Resumable @(1..50 | ForEach-Object { New-Local -Id "dddddddd-0000-0000-0000-00000000$('{0:D4}' -f $_)" -Summary ('y' * 48) }))
Test-That 'and by encoded bytes, which is what the broker and recorder see' {
    $big.Count -lt 50 -and ([Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json @($big) -Depth 4 -Compress)) -le 400)
}
$script:FakeSettings = @{ 'newSession.shareResumable' = $true; 'newSession.resumeCount' = 'not a number' }
Test-That 'a non-numeric count falls back instead of throwing inside the publish path' {
    @(Get-DaemonResumableExport -Resumable @(New-Local -Id 'eeeeeeee-1111-2222-3333-444444444444')).Count -eq 1
}
$script:FakeSettings = @{ 'newSession.shareResumable' = $true; 'newSession.resumeCount' = -5 }
Test-That 'a negative count means none, not all' {
    @(Get-DaemonResumableExport -Resumable @(New-Local -Id 'eeeeeeee-1111-2222-3333-444444444444')).Count -eq 0
}

Write-Host '--- what a machine shows from its peers ---'

$script:FakeSettings = @{}
$remote = New-RemoteEntry -Id 'ffffffff-1111-2222-3333-444444444444'

Test-That 'a session on a sharing peer appears' {
    @(Get-DaemonRemoteResumable -Peers @(New-Peer -Slug 'dasdesk' -Machine 'DASDESK' -Entries @($remote))).Count -eq 1
}
Test-That 'a session from a machine that is switched off does not' {
    @(Get-DaemonRemoteResumable -Peers @(New-Peer -Slug 'dasdesk' -Machine 'DASDESK' -Online $false -Entries @($remote))).Count -eq 0
}
Test-That 'a peer that has not opted in contributes nothing' {
    @(Get-DaemonRemoteResumable -Peers @(New-Peer -Slug 'dasdesk' -Machine 'DASDESK' -Shares $false -Entries @($remote))).Count -eq 0
}
Test-That 'a non-boolean resumeShare is not consent' {
    $p = New-Peer -Slug 'odd' -Machine 'ODD' -Entries @($remote)
    $p.Capabilities.resumeShare = 'yes'
    @(Get-DaemonRemoteResumable -Peers @($p)).Count -eq 0
}
Test-That 'a peer with no capabilities at all is harmless' {
    $p = [pscustomobject]@{ Slug = 'old'; Machine = 'OLD'; Online = $true; IsSelf = $false; Resumable = @(); Sessions = @() }
    @(Get-DaemonRemoteResumable -Peers @($p)).Count -eq 0
}
Test-That 'a malformed entry is skipped rather than throwing' {
    $p = New-Peer -Slug 'bad' -Machine 'BAD' -Entries @(@{ nonsense = 1 }, $remote)
    @(Get-DaemonRemoteResumable -Peers @($p)).Count -eq 1
}
Test-That 'a session already offered locally is not listed twice' {
    @(Get-DaemonRemoteResumable -Peers @(New-Peer -Slug 'd' -Machine 'D' -Entries @($remote)) -ExcludeIds @($remote.id)).Count -eq 0
}
Test-That 'a remote entry never carries a folder path, even when a leaf was shared' {
    $e = @(Get-DaemonRemoteResumable -Peers @(New-Peer -Slug 'd' -Machine 'D' -Entries @((New-RemoteEntry -Id 'f1111111-1111-1111-1111-111111111111' -Leaf 'repos'))))[0]
    $e.Folder -eq '' -and $e.Leaf -eq 'repos'
}
Test-That 'the label says where it is and that it cannot be opened here' {
    $e = @(Get-DaemonRemoteResumable -Peers @(New-Peer -Slug 'dasdesk' -Machine 'DASDESK' -Entries @($remote)))[0]
    $l = Get-DaemonRemoteResumeLabel -Entry $e
    $l -like '*DASDESK*' -and $l -like '*not available here*'
}

Write-Host '--- the merged list the selector is actually built from ---'

$script:FakePeers = @(New-Peer -Slug 'dasdesk' -Machine 'DASDESK' -Entries @($remote))
$merged = @(Get-DaemonMergedResumable -Live @{} -Headers $headers)
Test-That 'the merged list reaches the selector, not just the helper' { $merged.Count -ge 1 }
Test-That 'every merged entry has a Label, because the selector matches on it' {
    @($merged | Where-Object { -not $_.PSObject.Properties['Label'] -or -not $_.Label }).Count -eq 0
}
Test-That 'merged labels are unique, so two sessions cannot resolve to one option' {
    @($merged | ForEach-Object { [string]$_.Label } | Select-Object -Unique).Count -eq $merged.Count
}

Write-Host '--- a consent flag fails closed on anything it does not understand ---'
# [bool]'false' is $true in PowerShell, so a config holding the STRING "false" must not
# switch sharing on. This is the producer-side twin of the peer resumeShare check.

foreach ($case in @(
    @{ Value = 'false'; Name = 'the string "false" is not consent' }
    @{ Value = 'False'; Name = 'nor is "False"' }
    @{ Value = 'no';    Name = 'nor is an unparseable string' }
    @{ Value = 0;       Name = 'nor is a number' }
    @{ Value = @();     Name = 'nor is an empty list' }
)) {
    $script:FakeSettings = @{ 'newSession.shareResumable' = $case.Value }
    Test-That $case.Name {
        @(Get-DaemonResumableExport -Resumable @(New-Local -Id 'aaaaaaaa-1111-2222-3333-444444444444')).Count -eq 0
    }
    Test-That "$($case.Name) - and the capability agrees" { -not (Get-DaemonLaunchCapabilities).resumeShare }
}
$script:FakeSettings = @{ 'newSession.shareResumable' = 'true' }
Test-That 'the string "true" is consent, so configuration files still work' {
    @(Get-DaemonResumableExport -Resumable @(New-Local -Id 'aaaaaaaa-1111-2222-3333-444444444444')).Count -eq 1
}
$script:FakeSettings = @{ 'newSession.shareResumable' = $true; 'newSession.shareResumableDetail' = 'false' }
Test-That 'detail opt-in fails closed the same way' {
    -not (@(Get-DaemonResumableExport -Resumable @(New-Local -Id 'aaaaaaaa-1111-2222-3333-444444444444' -Summary 'secret')))[0].ContainsKey('title')
}

Write-Host '--- the selector is built from the merged list, through the real builder ---'
# Not Get-DaemonMergedResumable directly: that proves the merge works and cannot catch it
# being disconnected from Get-DaemonNewSessionControls, which is what actually feeds both
# the published options and the resolver.

function Get-BridgeWorkspaceChoices { @([pscustomobject]@{ Label = 'Repos'; Path = 'C:\Users\dswett\repos' }) }
function Get-BridgeLauncherKind { 'copilot' }
function Get-BridgeAgencyProfiles { @() }
function Get-DaemonSelectedLauncher { param($Fallback, $Installed, $Headers) 'copilot' }
function Get-BridgeTuningAxes { @('model') }
function Get-BridgeTuningOptions { param($Launcher, $Axis) @('Agent default') }

$script:FakeSettings = @{}
$script:DaemonResumeCache = @(New-Local -Id 'a1111111-1111-1111-1111-111111111111' -Label 'Copilot: local work - repos')
$script:DaemonResumeCacheAt = [DateTimeOffset]::Now
$script:FakePeers = @(New-Peer -Slug 'dasdesk' -Machine 'DASDESK' -Entries @($remote))

$controlsBuilt = Get-DaemonNewSessionControls -Live @{} -Headers $headers

Test-That 'the controls the card is published from include the local session' {
    @($controlsBuilt.Resumable | Where-Object { $_.SessionId -eq 'a1111111-1111-1111-1111-111111111111' }).Count -eq 1
}
Test-That 'and the peer session, so the merge really reaches the selector' {
    @($controlsBuilt.Resumable | Where-Object { $_.SessionId -eq $remote.id }).Count -eq 1
}
Test-That 'the peer entry arrives marked Remote, so the resolver can refuse it' {
    $e = @($controlsBuilt.Resumable | Where-Object { $_.SessionId -eq $remote.id })[0]
    $e.PSObject.Properties['Remote'] -and $e.Remote
}
Test-That 'every control entry has a Label, since the options are built from them' {
    @($controlsBuilt.Resumable | Where-Object { -not $_.PSObject.Properties['Label'] -or -not $_.Label }).Count -eq 0
}
Test-That 'and the labels are unique across local and remote' {
    @($controlsBuilt.Resumable | ForEach-Object { [string]$_.Label } | Select-Object -Unique).Count -eq @($controlsBuilt.Resumable).Count
}
Test-That 'a live session is still excluded from the controls' {
    @((Get-DaemonNewSessionControls -Live @{ 'a1111111-1111-1111-1111-111111111111' = $true } -Headers $headers).Resumable |
        Where-Object { $_.SessionId -eq 'a1111111-1111-1111-1111-111111111111' }).Count -eq 0
}

Write-Host '--- a remote session must never reach a native launch ---'
# Driven through the real resolver. The remote entry is given an approved local path on
# purpose: C:\Users\dswett\repos is approved on more than one machine in this fleet, so
# the workspace check cannot be what stops it. If the guard is missing, placed after that
# check, or swallowed by the empty catch, this is where it shows.

$remoteEntry = [pscustomobject]@{
    SessionId = 'ffffffff-1111-2222-3333-444444444444'; Launcher = 'copilot'
    Summary = ''; Folder = 'C:\Users\dswett\repos'; Leaf = 'repos'
    Updated = [DateTimeOffset]::Now; Remote = $true; Machine = 'DASDESK'; Slug = 'dasdesk'
    Label = 'Copilot on DASDESK: ffffffff - not available here'
}
$controls = [pscustomobject]@{
    Workspaces = @([pscustomobject]@{ Label = 'Repos'; Path = 'C:\Users\dswett\repos' })
    Launcher = 'copilot'; Launchers = @('copilot', 'claude'); Agents = @('Copilot', 'Claude')
    Profiles = @(); TuningFor = 'copilot'; Tuning = @{}
    Resumable = @($remoteEntry)
}
$script:HaStates = @{
    "$($script:DaemonEntity.NewResume)"    = $remoteEntry.Label
    "$($script:DaemonEntity.NewAgent)"     = 'Copilot'
    "$($script:DaemonEntity.NewWorkspace)" = 'Repos'
}
$script:LaunchCalls = 0
$script:Notes = @()
$request = Resolve-DaemonLaunchRequest -Controls $controls -Headers $headers

Test-That 'the real resolver refuses a remote entry whose folder is approved here' { $null -eq $request }
Test-That 'and no launcher was started' { $script:LaunchCalls -eq 0 }
Test-That 'and the refusal names the machine it is actually on' { ($script:Notes -join ' ') -like '*DASDESK*' }
Test-That 'and it does not claim the session is gone' { ($script:Notes -join ' ') -notlike '*no longer resumable*' }

$localEntry = [pscustomobject]@{
    SessionId = 'a1111111-1111-1111-1111-111111111111'; Launcher = 'copilot'
    Summary = 'local work'; Folder = 'C:\Users\dswett\repos'
    Updated = [DateTimeOffset]::Now; Label = 'Copilot: local work - repos'
}
$controls.Resumable = @($localEntry)
$script:HaStates["$($script:DaemonEntity.NewResume)"] = $localEntry.Label
$script:LaunchCalls = 0
$local = Resolve-DaemonLaunchRequest -Controls $controls -Headers $headers
Test-That 'a local resume with the same folder is still resolved, not refused' {
    $null -ne $local -and [string]$local.ResumeSession.SessionId -eq $localEntry.SessionId
}

Write-Host ''
if ($script:Failures -gt 0) { Write-Host "$($script:Failures) failed" -ForegroundColor Red; exit 1 }
Write-Host 'all passed' -ForegroundColor Green
