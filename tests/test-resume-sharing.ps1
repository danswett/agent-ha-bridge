#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for sharing resumable sessions between machines
    (hooks/daemon-launch.ps1, hooks/daemon-sessions.ps1, hooks/decision-mqtt.ps1).

.DESCRIPTION
    Runs in CI as part of the offline suite. Everything is stood in for: no Home
    Assistant, no broker, no agent CLI, no network and no session files. Boundaries
    stubbed: HA state reads, peer discovery, workspace approval, installed launchers,
    settings, the card's result line, and the launcher itself - counted, so a test can
    assert it was never called.

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
Test-That 'the label names the machine it is on' {
    $e = @(Get-DaemonRemoteResumable -Peers @(New-Peer -Slug 'dasdesk' -Machine 'DASDESK' -Entries @($remote)))[0]
    $l = Get-DaemonRemoteResumeLabel -Entry $e
    $l -like '*DASDESK*' -and $l -notlike '*not available here*'
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

Write-Host '--- serving a transfer is itself gated, and bounded to what was offered ---'
# Both of these were missing entirely: Invoke-DaemonTransferRequest consulted no flag and
# ran on every reconcile, and it looked the requested id up in the agent home rather than
# in what this machine had offered. Anything able to publish one retained message could
# take an arbitrary transcript off a machine that had opted out.

$script:Served = @()
function New-BridgeSessionBundle { param($SessionId, $Launcher, $Destination)
    $script:Served += $SessionId
    [pscustomobject]@{ SessionId = $SessionId; Launcher = $Launcher; Kind = 'copilot'; Path = 'C:\nope.zip'; Bytes = 10; Sha256 = 'X'; Version = '' } }
function Send-BridgeSessionBundle { param($Manifest, $Slug, $Correlation, $Headers, $Budget, $OnProgress) 1 }
function Clear-CopilotMqttTransferRequest { param($Slug, $Headers) }
$script:DaemonMachineSlug = 'me'
function Get-BridgeMachineEntityId { param($Domain, $Key, $Slug) "sensor.agent_bridge_${Slug}_$Key" }

$offeredId = 'cafe0000-0000-0000-0000-000000000001'
$secretId  = 'dead0000-0000-0000-0000-000000000002'
$script:DaemonResumeOffered = @([pscustomobject]@{ SessionId = $offeredId })

$script:TransferSecret = 'suite-fleet-secret'
function Set-Request {
    param($Session, $Correlation, $Requester = 'peer', $At = [DateTimeOffset]::Now, $Sig = $null)
    $script:HaStates = @{}
    $stamp = $At.ToString('o')
    # Signed the way a real peer would, so the gates below are still exercised rather
    # than all refusing at the signature. An unsigned fixture would have made every one
    # of them pass for the wrong reason - the same trap the 'c1' correlations sprang.
    if ($null -eq $Sig) {
        $Sig = Get-BridgeTransferSignature -Secret $script:TransferSecret -Fields (
            Get-BridgeTransferRequestFields -SessionId $Session -Launcher 'copilot' `
                -Requester $Requester -Correlation $Correlation -At $stamp)
    }
    $script:RequestAttrs = [pscustomobject]@{
        at = $stamp; session = $Session; launcher = 'copilot'
        requester = $Requester; correlation = $Correlation; sig = $Sig
    }
}
function Get-HomeAssistantState { param($EntityId, $Headers)
    if ($EntityId -like '*transfer_request*') { return [pscustomobject]@{ state = 'x'; attributes = $script:RequestAttrs } }
    [pscustomobject]@{ state = [string]$script:HaStates[$EntityId] } }

$script:FakeSettings = @{}
$script:Served = @(); $script:DaemonTransferServed = ''
Set-Request -Session $offeredId -Correlation 'cc000001'
Invoke-DaemonTransferRequest -LiveSessionIds @() -Headers $headers
Test-That 'with sharing off, a request is not served at all' { $script:Served.Count -eq 0 }

$script:FakeSettings = @{ 'newSession.shareResumable' = 'false'; 'newSession.transferSecret' = $script:TransferSecret }
$script:Served = @(); $script:DaemonTransferServed = ''
Set-Request -Session $offeredId -Correlation 'cc000002'
Invoke-DaemonTransferRequest -LiveSessionIds @() -Headers $headers
Test-That 'and the string "false" is not consent to serve either' { $script:Served.Count -eq 0 }

$script:FakeSettings = @{ 'newSession.shareResumable' = $true; 'newSession.transferSecret' = $script:TransferSecret }
$script:Served = @(); $script:DaemonTransferServed = ''
Set-Request -Session $secretId -Correlation 'cc000003'
Invoke-DaemonTransferRequest -LiveSessionIds @() -Headers $headers
Test-That 'a session this machine never offered is refused, however it is named' { $script:Served.Count -eq 0 }
$script:Served = @(); $script:DaemonTransferServed = ''
Set-Request -Session $offeredId -Correlation 'cc000004'
Invoke-DaemonTransferRequest -LiveSessionIds @($offeredId) -Headers $headers
Test-That 'a session live here is refused rather than bundled mid-sentence' { $script:Served.Count -eq 0 }

$script:Served = @(); $script:DaemonTransferServed = ''
Set-Request -Session $offeredId -Correlation 'cc000005' -At ([DateTimeOffset]::Now.AddHours(-2))
Invoke-DaemonTransferRequest -LiveSessionIds @() -Headers $headers
Test-That 'a stale retained request is not re-served after a restart' { $script:Served.Count -eq 0 }

$script:Served = @(); $script:DaemonTransferServed = ''
Set-Request -Session $offeredId -Correlation 'cc000006'
Invoke-DaemonTransferRequest -LiveSessionIds @() -Headers $headers
Test-That 'an offered session, not live, freshly asked for, IS served' { $script:Served -contains $offeredId }
Invoke-DaemonTransferRequest -LiveSessionIds @() -Headers $headers
Test-That 'and is not served twice for the same request' { @($script:Served).Count -eq 1 }

# The correlation names a staging directory and the reply topic. It was taken straight
# from the peer's retained JSON, so 'x/../../target' put New-Item - and the
# Remove-Item -Recurse that cleans up after it - outside the temp area entirely.
$script:TransferCleared = 0
function Clear-CopilotMqttTransferRequest { param($Slug, $Headers) $script:TransferCleared++ }
foreach ($bad in @('x/../../target', '../../etc', 'ab*cd', 'CC000001', 'c1', 'cc0000011')) {
    $script:Served = @(); $script:DaemonTransferServed = ''
    Set-Request -Session $offeredId -Correlation $bad
    Invoke-DaemonTransferRequest -LiveSessionIds @() -Headers $headers
    Test-That "a correlation of '$bad' is refused before it can name a directory" {
        $script:Served.Count -eq 0
    }
}
foreach ($bad in @('PEER', 'peer/../x', 'peer-1')) {
    $script:Served = @(); $script:DaemonTransferServed = ''
    Set-Request -Session $offeredId -Correlation 'aaaa0001' -Requester $bad
    Invoke-DaemonTransferRequest -LiveSessionIds @() -Headers $headers
    Test-That "a requester of '$bad' is refused before it can name a topic" {
        $script:Served.Count -eq 0
    }
}
$script:Served = @(); $script:DaemonTransferServed = ''
Set-Request -Session $offeredId -Correlation 'abcdef01'
Invoke-DaemonTransferRequest -LiveSessionIds @() -Headers $headers
Test-That 'and a well-formed one still serves, so the guard is not refusing everything' {
    $script:Served -contains $offeredId
}

# Shape is not origin. Everything checked above - the id, the slug, the timestamp - is
# something anything holding broker credentials can produce, and a request is an
# instruction to bundle a session and publish it to a topic the requester names.
$script:Served = @(); $script:DaemonTransferServed = ''
Set-Request -Session $offeredId -Correlation 'ab000001' -Sig ''
Invoke-DaemonTransferRequest -LiveSessionIds @() -Headers $headers
Test-That 'an unsigned request is refused even though every other field is valid' { $script:Served.Count -eq 0 }

$script:Served = @(); $script:DaemonTransferServed = ''
Set-Request -Session $offeredId -Correlation 'ab000002' -Sig ('0' * 64)
Invoke-DaemonTransferRequest -LiveSessionIds @() -Headers $headers
Test-That 'a wrongly signed request is refused' { $script:Served.Count -eq 0 }

# A signature over a different destination must not travel: the requester and the
# correlation both name the topic the transcript is published to.
$script:Served = @(); $script:DaemonTransferServed = ''
$liftedSig = Get-BridgeTransferSignature -Secret $script:TransferSecret -Fields (
    Get-BridgeTransferRequestFields -SessionId $offeredId -Launcher 'copilot' `
        -Requester 'peer' -Correlation 'ab000003' -At ([DateTimeOffset]::Now.ToString('o')))
Set-Request -Session $offeredId -Correlation 'ab000003' -Requester 'attacker' -Sig $liftedSig
Invoke-DaemonTransferRequest -LiveSessionIds @() -Headers $headers
Test-That 'a valid signature cannot be replayed with the delivery topic changed' { $script:Served.Count -eq 0 }

# Fail closed rather than silently unauthenticated.
$script:FakeSettings = @{ 'newSession.shareResumable' = $true }
$script:Served = @(); $script:DaemonTransferServed = ''
Set-Request -Session $offeredId -Correlation 'ab000004'
Invoke-DaemonTransferRequest -LiveSessionIds @() -Headers $headers
Test-That 'with no secret configured a machine serves nothing rather than serving unsigned' { $script:Served.Count -eq 0 }
$script:FakeSettings = @{ 'newSession.shareResumable' = $true; 'newSession.transferSecret' = $script:TransferSecret }

# During startup Restore-DaemonSessionCards reaches Sync-DaemonSessions before
# Sync-DaemonNewSession has filled the offered list. Treating that moment as "we do not
# offer it" burned the correlation and cleared the request, leaving the asking machine
# waiting out its timeout for a session this one was about to offer seconds later.
$remembered = $script:DaemonResumeOffered
$script:DaemonResumeOffered = @()
$script:Served = @(); $script:DaemonTransferServed = ''; $script:TransferCleared = 0
Set-Request -Session $offeredId -Correlation 'beef0001'
Invoke-DaemonTransferRequest -LiveSessionIds @() -Headers $headers
Test-That 'a request arriving before the offered list is built is deferred, not refused' {
    $script:Served.Count -eq 0 -and $script:TransferCleared -eq 0 -and $script:DaemonTransferServed -eq ''
}
$script:DaemonResumeOffered = $remembered
Invoke-DaemonTransferRequest -LiveSessionIds @() -Headers $headers
Test-That 'and is served on the next pass once the list exists' { $script:Served -contains $offeredId }

Write-Host '--- the transfer request entity has to be renamed, and removed on uninstall ---'
# Found the hard way against a live Home Assistant: publishing the discovery config is
# not enough. HA builds an MQTT entity id from device name plus entity name and ignores
# object_id, so this one appeared as
# sensor.ai_agent_bridge_<slug>_session_transfer_request while the daemon looked for
# sensor.agent_bridge_<slug>_transfer_request - and every transfer timed out, silently,
# because the request was published somewhere nothing was reading.

$src = Get-Content (Join-Path $PSScriptRoot '..\hooks\decision-ha-websocket.ps1') -Raw
Test-That 'the transfer request is on the list of entities forced onto a known id' {
    $src -match "@\('sensor',\s*'transfer_request'\)"
}
$topics = @(Get-CopilotMqttMachineTopic -Slug 'laptop')
Test-That 'its discovery config is removed when a machine is forgotten' {
    $topics -contains 'homeassistant/sensor/agent_bridge_laptop/transfer_request/config'
}
Test-That 'and its retained request is cleared too, so a stale one cannot be served' {
    $topics -contains 'copilot/cli/machine/laptop/transfer/request'
}

Write-Host '--- a remote session is refused unless everything lines up ---'
# Driven through the real resolver. The remote entry is given an approved local path on
# purpose: C:\Users\dswett\repos is approved on more than one machine in this fleet, so
# the workspace check cannot be what stops it. If the guard is missing, placed after that
# check, or swallowed by the empty catch, this is where it shows.

$script:Transfers = 0
function Receive-DaemonSessionTransfer { param($Entry, $WorkingDirectory, $Headers, $TimeoutSeconds) $script:Transfers++; $null }
function Get-BridgeLauncherUsage { param($Launcher) [pscustomobject]@{ SignedIn = $script:SignedIn; LastUsed = [DateTimeOffset]::Now } }
$script:SignedIn = $true
function Get-DaemonPeerMachines { param($Headers) @([pscustomobject]@{ Slug = 'dasdesk'; Machine = 'DASDESK'; Online = $script:PeerOnline; IsSelf = $false }) }
$script:PeerOnline = $true

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

function Reset-Attempt { $script:LaunchCalls = 0; $script:Notes = @(); $script:Transfers = 0 }

# Off by default: moving a transcript between machines is not something to start doing
# because an entry happened to be selected.
Reset-Attempt
$script:FakeSettings = @{}
$r = Resolve-DaemonLaunchRequest -Controls $controls -Headers $headers
Test-That 'with transfers off it is refused, and nothing is fetched' { $null -eq $r -and $script:Transfers -eq 0 }
Test-That 'and no launcher is started' { $script:LaunchCalls -eq 0 }
Test-That 'and the refusal says where the session actually is' { ($script:Notes -join ' ') -like '*DASDESK*' }
Test-That 'and does not claim the session is gone' { ($script:Notes -join ' ') -notlike '*no longer resumable*' }

$script:FakeSettings = @{ 'newSession.transferResumable' = $true }

Reset-Attempt
$script:PeerOnline = $false
$r = Resolve-DaemonLaunchRequest -Controls $controls -Headers $headers
Test-That 'an offline owner is refused before any bytes move' { $null -eq $r -and $script:Transfers -eq 0 }
Test-That 'and the refusal says it is offline' { ($script:Notes -join ' ') -like '*offline*' }
$script:PeerOnline = $true

Reset-Attempt
$script:SignedIn = $false
$r = Resolve-DaemonLaunchRequest -Controls $controls -Headers $headers
Test-That 'not being signed in is refused before any bytes move' { $null -eq $r -and $script:Transfers -eq 0 }
Test-That 'and the refusal names signing in' { ($script:Notes -join ' ') -like '*sign*' }
$script:SignedIn = $true

Reset-Attempt
$missing = $remoteEntry.PSObject.Copy(); $missing.Launcher = 'codex'   # not installed here
$controls.Resumable = @($missing)
$script:HaStates["$($script:DaemonEntity.NewResume)"] = $missing.Label
$r = Resolve-DaemonLaunchRequest -Controls $controls -Headers $headers
Test-That 'an agent that is not installed here is refused before any bytes move' { $null -eq $r -and $script:Transfers -eq 0 }
$controls.Resumable = @($remoteEntry)
$script:HaStates["$($script:DaemonEntity.NewResume)"] = $remoteEntry.Label

Reset-Attempt
$r = Resolve-DaemonLaunchRequest -Controls $controls -Headers $headers
Test-That 'with everything in order it attempts the transfer' { $script:Transfers -eq 1 }
Test-That 'and a transfer that fails still starts no launcher' { $null -eq $r -and $script:LaunchCalls -eq 0 }

Write-Host '--- a transfer that succeeds resumes the copy, not the original ---'

Reset-Attempt
function Receive-DaemonSessionTransfer { param($Entry, $WorkingDirectory, $Headers, $TimeoutSeconds)
    $script:Transfers++; $script:GotDirectory = $WorkingDirectory; 'bbbbbbbb-9999-9999-9999-999999999999' }
$r = Resolve-DaemonLaunchRequest -Controls $controls -Headers $headers
Test-That 'the request carries the NEW id, so the original is never touched' {
    $null -ne $r -and [string]$r.ResumeSession.SessionId -eq 'bbbbbbbb-9999-9999-9999-999999999999'
}
Test-That 'and not the id it had on the other machine' {
    [string]$r.ResumeSession.SessionId -ne 'ffffffff-1111-2222-3333-444444444444'
}
Test-That 'it opens in the approved workspace chosen here, not the folder it came from' {
    $script:GotDirectory -eq 'C:\Users\dswett\repos' -and [string]$r.ResumeSession.Folder -eq 'C:\Users\dswett\repos'
}
Test-That 'and the entry is no longer remote, so it resumes like any local session' {
    -not ($r.ResumeSession.PSObject.Properties['Remote'] -and $r.ResumeSession.Remote)
}

Write-Host '--- a local resume is completely unaffected ---'

$localEntry = [pscustomobject]@{
    SessionId = 'a1111111-1111-1111-1111-111111111111'; Launcher = 'copilot'
    Summary = 'local work'; Folder = 'C:\Users\dswett\repos'
    Updated = [DateTimeOffset]::Now; Label = 'Copilot: local work - repos'
}
$controls.Resumable = @($localEntry)
$script:HaStates["$($script:DaemonEntity.NewResume)"] = $localEntry.Label
Reset-Attempt
$local = Resolve-DaemonLaunchRequest -Controls $controls -Headers $headers
Test-That 'a local resume still resolves' {
    $null -ne $local -and [string]$local.ResumeSession.SessionId -eq $localEntry.SessionId
}
Test-That 'and fetches nothing from anywhere' { $script:Transfers -eq 0 }

Write-Host '--- the remote half of the list is bounded by this machine, not by its peers ---'
# Everything bounding the producing side - resumeCount, shareResumableMaxBytes - is a
# setting on a different machine. Without a bound here, a peer decides how large this
# machine's retained new_resume payload is, and that payload is the shape of message
# that took this fleet's MQTT down.
$flood = [pscustomobject]@{
    IsSelf = $false; Online = $true; Machine = 'LOUD'; Slug = 'loud'
    Capabilities = [pscustomobject]@{ resumeShare = $true }
    Resumable = @(1..500 | ForEach-Object {
        [pscustomobject]@{ id = "ffff0000-0000-0000-0000-$('{0:D12}' -f $_)"; launcher = 'copilot'; updated = '2026-01-01T00:00:00+00:00' }
    })
}
$flooded = @(Get-DaemonRemoteResumable -Peers @($flood))
Test-That 'one peer cannot contribute an unbounded number of entries' { $flooded.Count -le 25 }

$many = @(1..12 | ForEach-Object {
    [pscustomobject]@{
        IsSelf = $false; Online = $true; Machine = "M$_"; Slug = "m$_"
        Capabilities = [pscustomobject]@{ resumeShare = $true }
        Resumable = @(1..40 | ForEach-Object {
            [pscustomobject]@{ id = [guid]::NewGuid().ToString(); launcher = 'copilot'; updated = '2026-01-01T00:00:00+00:00' }
        })
    }
})
$all = @(Get-DaemonRemoteResumable -Peers $many)
Test-That 'and the whole fleet together is bounded too' { $all.Count -le 100 }
Test-That 'while an ordinary peer is still listed in full' {
    $ordinary = [pscustomobject]@{
        IsSelf = $false; Online = $true; Machine = 'CALM'; Slug = 'calm'
        Capabilities = [pscustomobject]@{ resumeShare = $true }
        Resumable = @(1..3 | ForEach-Object { [pscustomobject]@{ id = [guid]::NewGuid().ToString(); launcher = 'copilot'; updated = '2026-01-01T00:00:00+00:00' } })
    }
    @(Get-DaemonRemoteResumable -Peers @($ordinary)).Count -eq 3
}

Write-Host '--- what the global status actually publishes, through the real publisher call ---'
# This was the gap: every existing suite stubs Publish-DaemonGlobalStatus itself or
# records only -Sessions, so deleting `-Resumable $export` - which silently stops this
# machine sharing anything at all - left the whole suite green.
$script:PublishedResumable = $null
$script:PublishCount = 0
function Publish-CopilotMqttGlobalStatus {
    param($Headers, $Capabilities, $Sessions, $Resumable)
    $script:PublishCount++
    $script:PublishedResumable = @($Resumable)
}
$script:DaemonGlobalSignature = ''
$script:DaemonGlobalLastPublish = [DateTimeOffset]::MinValue
$script:DaemonConfig = @{ GlobalReassertSeconds = 3600 }
$caps = @{ newSession = $true; profile = $false; resume = $true; agent = $true; tuning = $true; detailed = $true; dev = $false; resumeShare = $true }
$descriptors = @([pscustomobject]@{ Node = 'n1'; Name = 'One'; Machine = 'ME'; Kind = 'copilot' })
$offered = @(
    [pscustomobject]@{ SessionId = 'aaaa1111-0000-0000-0000-000000000001'; Launcher = 'copilot'; Summary = 'secret prompt text'; Folder = 'C:\work\customer'; Updated = [DateTimeOffset]::Now }
)

$script:FakeSettings = @{ 'newSession.shareResumable' = $true }
Publish-DaemonGlobalStatus -Descriptors $descriptors -Capabilities $caps -Resumable $offered -Headers $headers
Test-That 'the offered sessions actually reach the publisher' {
    $e = @($script:PublishedResumable)
    $e.Count -eq 1 -and $null -ne $e[0] -and $e[0].ContainsKey('id') -and
        [string]$e[0]['id'] -eq 'aaaa1111-0000-0000-0000-000000000001'
}
Test-That 'and carry no prompt text or path by default' {
    $e = @($script:PublishedResumable)
    $e.Count -eq 1 -and $null -ne $e[0] -and -not $e[0].ContainsKey('title') -and -not $e[0].ContainsKey('leaf')
}

# The signature has to cover the exported content, or a privacy change sits unpublished
# behind a retained message until the re-assert interval happens to come round.
$before = $script:PublishCount
$script:FakeSettings = @{ 'newSession.shareResumable' = $false }
Publish-DaemonGlobalStatus -Descriptors $descriptors -Capabilities $caps -Resumable $offered -Headers $headers
Test-That 'turning sharing off republishes immediately rather than waiting out the interval' {
    $script:PublishCount -eq $before + 1
}
Test-That 'and replaces the retained list with an empty one' {
    @($script:PublishedResumable).Count -eq 0
}

Write-Host '--- a reply has to be for the session that was actually asked for ---'
# The transfer topic is not authenticated and the correlation is published in the
# retained request, so anything subscribed to the broker can answer first. An honest
# sender cannot mismatch - it derives the kind from the launcher the request carried -
# but nothing compared the two until now. A bundle declaring 'claude' installs into
# .claude and verifies there happily, and then the launcher that actually runs is
# Copilot, pointed at a session-state directory with no such session: the empty-session
# fail-open this whole design exists to prevent.
# The resolver tests above replaced this function with a stub, so the real one has to
# come back before it can be exercised. Safe to re-source: daemon-launch.ps1 declares no
# script-level parameters (which would rebind here) and its only non-function statement
# is a constant table.
. (Join-Path $PSScriptRoot '..\hooks\daemon-launch.ps1')

$script:Installed = @()
$script:ReplyManifest = $null
function Get-BridgeTransferTopic { param($Slug, $Correlation) "copilot/cli/transfer/$Slug/$Correlation" }
function Set-CopilotMqttTransferRequest { param($Slug, $SessionId, $Launcher, $Requester, $Correlation, $Headers) }
function Join-BridgeBundleChunk { param($Chunks, $TotalBytes, $Sha256) [byte[]]::new(4) }
function Install-BridgeSessionBundle { param($BundlePath, $Manifest, $NewSessionId, $WorkingDirectory)
    $script:Installed += [string]$Manifest.Kind; 'cccccccc-1111-1111-1111-111111111111' }
function Read-BridgeHaMqttSubscription { param($Topic, $TimeoutSeconds, $OnReady, $Until)
    if ($OnReady) { & $OnReady }
    @($script:ReplyManifest, [pscustomobject]@{ s = 0; o = 0; d = 'AAAA' })
}
$wanted = 'ffffffff-1111-2222-3333-444444444444'
$entry = [pscustomobject]@{ SessionId = $wanted; Slug = 'other'; Machine = 'OTHER'; Launcher = 'copilot'; Remote = $true }

# The receive side signs over the correlation it generated, which is not predictable
# from outside, so these fixtures sign whatever correlation the call produced.
function Set-ReplyManifest {
    param($Session, $Kind, $Signed = $true)
    $script:SignReply = $Signed
    $script:ReplySession = $Session
    $script:ReplyKind = $Kind
}
function Read-BridgeHaMqttSubscription { param($Topic, $TimeoutSeconds, $OnReady, $Until)
    if ($OnReady) { & $OnReady }
    # The correlation is the second-to-last topic segment.
    $parts = @($Topic.TrimEnd('/#').TrimEnd('/') -split '/')
    $corr = $parts[-1]
    $m = [ordered]@{ sha256 = ('a' * 64); bytes = 4; chunks = 1; session = $script:ReplySession; kind = $script:ReplyKind }
    if ($script:SignReply) {
        $m['sig'] = Get-BridgeTransferSignature -Secret $script:TransferSecret -Fields (
            Get-BridgeTransferManifestFields -SessionId ([string]$script:ReplySession) -Kind ([string]$script:ReplyKind) `
                -Sha256 ('a' * 64) -Bytes 4 -Chunks 1 -Correlation $corr)
    }
    @([pscustomobject]$m, [pscustomobject]@{ s = 0; o = 0; d = 'AAAA' })
}
$script:FakeSettings = @{ 'newSession.transferSecret' = $script:TransferSecret }

$script:Installed = @()
Set-ReplyManifest -Session $wanted -Kind 'claude'
$got = Receive-DaemonSessionTransfer -Entry $entry -WorkingDirectory 'C:\Users\dswett\repos' -Headers $headers -TimeoutSeconds 1
Test-That 'a reply claiming a different agent is refused rather than installed elsewhere' {
    $null -eq $got -and $script:Installed.Count -eq 0
}

$script:Installed = @()
Set-ReplyManifest -Session 'dddddddd-0000-0000-0000-000000000000' -Kind 'copilot'
$got = Receive-DaemonSessionTransfer -Entry $entry -WorkingDirectory 'C:\Users\dswett\repos' -Headers $headers -TimeoutSeconds 1
Test-That 'a reply for a different session is refused too' {
    $null -eq $got -and $script:Installed.Count -eq 0
}

$script:Installed = @()
Set-ReplyManifest -Session $wanted -Kind 'copilot'
$got = Receive-DaemonSessionTransfer -Entry $entry -WorkingDirectory 'C:\Users\dswett\repos' -Headers $headers -TimeoutSeconds 1
Test-That 'and the matching reply still installs, so the check is not refusing everything' {
    $got -eq 'cccccccc-1111-1111-1111-111111111111' -and $script:Installed -contains 'copilot'
}

# An attacker racing the real owner satisfies the session/kind check trivially - it only
# has to name what was asked for. The signature is what it cannot produce, and this is
# the path that ends with an agent resuming someone else's bytes with tool access.
$script:Installed = @()
Set-ReplyManifest -Session $wanted -Kind 'copilot' -Signed $false
$got = Receive-DaemonSessionTransfer -Entry $entry -WorkingDirectory 'C:\Users\dswett\repos' -Headers $headers -TimeoutSeconds 1
Test-That 'an unsigned bundle naming the right session is still refused before anything is written' {
    $null -eq $got -and $script:Installed.Count -eq 0
}

$script:Installed = @()
$script:FakeSettings = @{ 'newSession.transferSecret' = 'a-different-fleet' }
Set-ReplyManifest -Session $wanted -Kind 'copilot'
$got = Receive-DaemonSessionTransfer -Entry $entry -WorkingDirectory 'C:\Users\dswett\repos' -Headers $headers -TimeoutSeconds 1
Test-That 'a bundle signed by another fleet is refused' { $null -eq $got -and $script:Installed.Count -eq 0 }

$script:Installed = @()
$script:FakeSettings = @{}
$script:Subscribed = 0
$realSubscribe = ${function:Read-BridgeHaMqttSubscription}
function Read-BridgeHaMqttSubscription { param($Topic, $TimeoutSeconds, $OnReady, $Until) $script:Subscribed++; @() }
Set-ReplyManifest -Session $wanted -Kind 'copilot'
$got = Receive-DaemonSessionTransfer -Entry $entry -WorkingDirectory 'C:\Users\dswett\repos' -Headers $headers -TimeoutSeconds 1
Test-That 'with no secret here a transfer is refused rather than accepted unauthenticated' {
    $null -eq $got -and $script:Installed.Count -eq 0
}
Test-That 'and it refuses before subscribing, rather than waiting out the timeout' {
    $script:Subscribed -eq 0
}
Test-That 'saying what is actually wrong, not that the other machine is offline' {
    $last = @($script:Notes)[-1]
    $last -like '*transferSecret*' -and $last -notlike '*busy or offline*'
}
${function:Read-BridgeHaMqttSubscription} = $realSubscribe
$script:FakeSettings = @{ 'newSession.transferSecret' = $script:TransferSecret }

Write-Host ''
if ($script:Failures -gt 0) { Write-Host "$($script:Failures) failed" -ForegroundColor Red; exit 1 }
Write-Host 'all passed' -ForegroundColor Green
