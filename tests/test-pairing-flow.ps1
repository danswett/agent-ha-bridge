#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for pairing's moving parts: the sponsor's attempt, the joiner's attempt, the
    daemon's look at the helper, the lockout, and saving the result.

.DESCRIPTION
    Home Assistant is replaced by a small fake: one helper value, a bus of published
    MQTT messages, and a subscription that hands each side its counterpart's messages
    in order. Each side is driven against the other side's real protocol functions, so
    a message one end produces in a shape the other cannot read fails here.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\bridge-platform.ps1')
. (Join-Path $PSScriptRoot '..\hooks\bridge-test-guard.ps1')
. (Join-Path $PSScriptRoot '..\hooks\bridge-pairing.ps1')
. (Join-Path $PSScriptRoot '..\hooks\bridge-pairing-io.ps1')

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($ok) { Write-Host "  PASS  $Name" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

# ------------------------------------------------------------- the fake Home Assistant
$script:Helper = ''
$script:HelperExists = $true
$script:HelperWrites = [Collections.Generic.List[string]]::new()
$script:Published = [Collections.Generic.List[object]]::new()
$script:Runtime = Join-Path ([IO.Path]::GetTempPath()) "pairing-flow-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
[void][IO.Directory]::CreateDirectory($script:Runtime)
$headers = @{ Authorization = 'Bearer test' }
$fleet = New-BridgePairingId
$secret = New-BridgeFleetSecret
$here = [Environment]::MachineName

function Get-HomeAssistantState {
    param($EntityId, $Headers)
    if ($EntityId -ne 'input_text.agent_bridge_pairing' -or -not $script:HelperExists) { throw "no such entity: $EntityId" }
    if ($script:OnHelperRead) { & $script:OnHelperRead }
    [pscustomobject]@{ entity_id = $EntityId; state = $script:Helper }
}
function Invoke-HomeAssistantService {
    param($Domain, $Service, $Headers, $Data)
    if ($Domain -eq 'input_text' -and $Service -eq 'set_value') {
        if ($Data.entity_id -cne 'input_text.agent_bridge_pairing') { throw "set_value on $($Data.entity_id)" }
        $script:Helper = [string]$Data.value; $script:HelperWrites.Add($script:Helper); return
    }
    throw "unexpected service $Domain.$Service"
}
function Publish-CopilotMqttMessage {
    param($Topic, $Payload, $Headers, [switch]$Retain)
    $script:Published.Add([pscustomobject]@{ Topic = $Topic; Payload = $Payload; Retain = [bool]$Retain })
}
function Get-BridgeMachineSlug { $script:Slug }
function Get-BridgeTransferSecret { $script:MySecret }
function Get-BridgeSetting { param($Path, $Default) if ($Path -eq 'newSession.fleetId') { $script:MyFleet } else { $Default } }
function Get-BridgeRuntimePath { param($Name) Join-Path $script:Runtime $Name }
function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }

function Reset-FakeHa {
    $script:Helper = ''; $script:HelperExists = $true; $script:HelperWrites.Clear(); $script:Published.Clear()
    $script:OnHelperRead = $null; $script:Slug = 'dswett_home'; $script:MySecret = $secret; $script:MyFleet = $fleet
    $script:DaemonPairingAttempt = ''
    Remove-Item -LiteralPath (Join-Path $script:Runtime 'agent-bridge-pairing-refusals.json') -ErrorAction SilentlyContinue
}
function Get-Sent { param([string]$Type) @($script:Published | ForEach-Object { $_.Payload | ConvertFrom-Json } | Where-Object { [string]$_.type -ceq $Type }) }

Write-Host '--- the sponsor''s attempt ---'
Reset-FakeHa
$joiner = New-BridgePairingJoiner -FleetId $fleet -Joiner 'DSWETT-DEV-VM1' -Sponsor $here -SponsorSlug 'dswett_home'
$script:Helper = $joiner.Request
# The subscription plays the joiner: once the sponsor is listening it has published its
# offer, so the joiner answers it with a real reveal - and the person then types the code.
function Read-BridgeHaMqttSubscription {
    param($Topic, $Until, $TimeoutSeconds, $OnReady)
    $script:SubscribedTo = $Topic
    & $OnReady
    $offer = @(Get-Sent 'offer')[-1]
    $reveal = Receive-BridgePairingOffer -State $joiner -Message $offer
    [void](& $Until @($reveal))
    $script:Helper = $joiner.Code.Substring(0, 3) + ' ' + $joiner.Code.Substring(3)
}
$outcome = Invoke-BridgePairingSponsor -Attempt $joiner.Attempt -Headers $headers
Test-That 'a sponsor that is given the right code accepts' { $outcome -ceq 'accepted' } "outcome=$outcome"
Test-That 'it listens on its own topic before offering, so the reveal cannot be missed' { $script:SubscribedTo -ceq "agent_bridge/pairing/$($joiner.Attempt)/to-sponsor" }
Test-That 'it writes the acceptance for this joiner into the helper' { $script:Helper -like 'accepted:DSWETT-DEV-VM1:*' }
$sealed = @(Get-Sent 'secret')
Test-That 'and sends one secret message, to the joiner''s topic' { $sealed.Count -eq 1 -and @($script:Published | Where-Object { $_.Topic -like '*/to-joiner' }).Count -eq 2 }
Test-That 'nothing it publishes is retained' { @($script:Published | Where-Object Retain).Count -eq 0 }
Test-That 'and the secret is in none of it' { -not (@($script:Published.Payload) -join "`n").Contains($secret) }
Test-That 'the joiner can open what it sent, with what Home Assistant shows' {
    (Complete-BridgePairingJoin -State $joiner -HelperValue $script:Helper -Message $sealed[0]) -ceq $secret
}

Write-Host '--- a sponsor given the wrong code ---'
Reset-FakeHa
$joiner = New-BridgePairingJoiner -FleetId $fleet -Joiner 'DSWETT-DEV-VM1' -Sponsor $here -SponsorSlug 'dswett_home'
$script:Helper = $joiner.Request
function Read-BridgeHaMqttSubscription {
    param($Topic, $Until, $TimeoutSeconds, $OnReady)
    & $OnReady
    [void](& $Until @(Receive-BridgePairingOffer -State $joiner -Message @(Get-Sent 'offer')[-1]))
    $script:Helper = '{0:D6}' -f (([int]$joiner.Code + 1) % 1000000)
}
$outcome = Invoke-BridgePairingSponsor -Attempt $joiner.Attempt -Headers $headers
Test-That 'it refuses' { $outcome -ceq 'refused' -and $script:Helper -ceq 'refused:DSWETT-DEV-VM1' }
Test-That 'sends no secret' { @(Get-Sent 'secret').Count -eq 0 }
Test-That 'and counts the refusal toward the lockout' { Test-Path -LiteralPath (Join-Path $script:Runtime 'agent-bridge-pairing-refusals.json') }

Write-Host '--- a sponsor whose helper is taken over ---'
Reset-FakeHa
$joiner = New-BridgePairingJoiner -FleetId $fleet -Joiner 'DSWETT-DEV-VM1' -Sponsor $here -SponsorSlug 'dswett_home'
$script:Helper = $joiner.Request
function Read-BridgeHaMqttSubscription {
    param($Topic, $Until, $TimeoutSeconds, $OnReady)
    & $OnReady
    [void](& $Until @(Receive-BridgePairingOffer -State $joiner -Message @(Get-Sent 'offer')[-1]))
    $script:Helper = 'request:dswett_home:somebody else entirely'
}
$outcome = Invoke-BridgePairingSponsor -Attempt $joiner.Attempt -Headers $headers
Test-That 'it stands down rather than judging somebody else''s text' { $outcome -ceq 'helper-taken' -and @(Get-Sent 'secret').Count -eq 0 }

Write-Host '--- a sponsor whose joiner never reveals ---'
Reset-FakeHa
$joiner = New-BridgePairingJoiner -FleetId $fleet -Joiner 'DSWETT-DEV-VM1' -Sponsor $here -SponsorSlug 'dswett_home'
$script:Helper = $joiner.Request
function Read-BridgeHaMqttSubscription { param($Topic, $Until, $TimeoutSeconds, $OnReady) & $OnReady }
Test-That 'it gives up without waiting for a code' { (Invoke-BridgePairingSponsor -Attempt $joiner.Attempt -Headers $headers) -ceq 'no-reveal' }
Test-That 'a request that has gone is not started' {
    $script:Helper = ''
    (Invoke-BridgePairingSponsor -Attempt $joiner.Attempt -Headers $headers) -ceq 'request-gone'
}

Write-Host '--- the joiner''s attempt ---'
Reset-FakeHa
$script:Shown = ''
$sponsorRecord = [pscustomobject]@{ Machine = 'DSWETT-HOME'; Slug = 'dswett_home'; FleetId = $fleet }
# The subscription plays the sponsor and the person: it reads the request the joiner
# wrote, offers, takes the reveal, judges the code that was shown, and seals the secret.
function Read-BridgeHaMqttSubscription {
    param($Topic, $Until, $TimeoutSeconds, $OnReady)
    $script:SubscribedTo = $Topic
    & $OnReady
    $request = ConvertFrom-BridgePairingRequest -Value $script:Helper
    $sponsor = New-BridgePairingSponsor -Request $request -FleetId $fleet -Sponsor 'DSWETT-HOME' -SponsorSlug 'dswett_home'
    [void](& $Until @($sponsor.Offer))
    Receive-BridgePairingReveal -State $sponsor.State -Message @(Get-Sent 'reveal')[-1]
    $verdict = Resolve-BridgePairingCode -State $sponsor.State -Typed $script:Shown -Secret $secret
    $script:Helper = $verdict.Helper
    [void](& $Until @($sponsor.Offer, $verdict.Message))
}
$joined = Invoke-BridgePairingJoin -Sponsor $sponsorRecord -Headers $headers -ShowCode { param($code) $script:Shown = $code }
Test-That 'the joiner shows a six-digit code' { $script:Shown -match '^\d{6}$' }
Test-That 'it listens on its own topic before writing the request' { $script:SubscribedTo -like 'agent_bridge/pairing/*/to-joiner' -and $script:HelperWrites[0] -like 'request:dswett_home:*' }
Test-That 'and comes back with the sponsor''s secret and fleet' { $joined.Secret -ceq $secret -and $joined.FleetId -ceq $fleet }
Test-That 'leaving the helper empty for the next machine' { $script:Helper -ceq '' }

Write-Host '--- a joiner that is refused ---'
Reset-FakeHa
function Read-BridgeHaMqttSubscription {
    param($Topic, $Until, $TimeoutSeconds, $OnReady)
    & $OnReady
    $request = ConvertFrom-BridgePairingRequest -Value $script:Helper
    $sponsor = New-BridgePairingSponsor -Request $request -FleetId $fleet -Sponsor 'DSWETT-HOME' -SponsorSlug 'dswett_home'
    [void](& $Until @($sponsor.Offer))
    $script:Helper = "refused:$here"
}
$message = ''
try { [void](Invoke-BridgePairingJoin -Sponsor $sponsorRecord -Headers $headers -ShowCode { param($c) }) } catch { $message = $_.Exception.Message }
Test-That 'says the sponsor refused the code' { $message -like '*refused the code*' } $message
Test-That 'and clears the refusal from the helper' { $script:Helper -ceq '' }

Write-Host '--- a joiner whose sponsor never answers ---'
Reset-FakeHa
function Read-BridgeHaMqttSubscription { param($Topic, $Until, $TimeoutSeconds, $OnReady) & $OnReady }
$message = ''
try { [void](Invoke-BridgePairingJoin -Sponsor $sponsorRecord -Headers $headers -ShowCode { param($c) }) } catch { $message = $_.Exception.Message }
Test-That 'says so, and suggests why' { $message -like '*did not answer*' } $message
Test-That 'and takes its request back out of the helper' { $script:Helper -ceq '' }

Write-Host '--- a joiner that cannot start ---'
Reset-FakeHa
$script:Helper = 'request:someone_else:already here'
$message = ''
try { [void](Invoke-BridgePairingJoin -Sponsor $sponsorRecord -Headers $headers -ShowCode { param($c) }) } catch { $message = $_.Exception.Message }
Test-That 'waits its turn while another pairing holds the helper' { $message -like '*another pairing is in progress*' -and $script:Helper -like 'request:someone_else:*' } $message
Reset-FakeHa
$script:HelperExists = $false
$message = ''
try { [void](Invoke-BridgePairingJoin -Sponsor $sponsorRecord -Headers $headers -ShowCode { param($c) }) } catch { $message = $_.Exception.Message }
Test-That 'and says what to do when the helper does not exist' { $message -like '*helper is missing*' } $message

Write-Host '--- the helper pairing reads and writes ---'
Reset-FakeHa
# Storage is not the state machine: a helper can be in the collection and the entity
# registry a moment before its state appears, and the next thing pairing does is read
# that state. Returning as soon as the create succeeded made a first-ever pairing fail
# with "the helper is missing" until the person ran it a second time.
$script:Ws = [Collections.Generic.List[string]]::new()
$script:HelperListed = $true
$script:StateAfterSleeps = 0
$script:Slept = 0
# Lets one command be made to fail the way a real transport would; everything else
# answers as usual.
$script:OnWebSocket = $null
function Invoke-CopilotHaWebSocket {
    param($Commands)
    $type = [string]$Commands[0].type
    $script:Ws.Add($type)
    if ($script:OnWebSocket) { & $script:OnWebSocket $type }
    # Assigned, never piped. `$x = if (...) { @() }` yields $null rather than an empty
    # array, and the caller then indexes a one-element list holding $null - the trap
    # this repository has hit before, and exactly what a real empty collection must not
    # look like here.
    $payload = $null
    if ($type -ceq 'input_text/list') {
        $payload = [object[]]::new(0)
        if ($script:HelperListed) { $payload = @([pscustomobject]@{ id = 'agent_bridge_pairing' }) }
    }
    elseif ($type -ceq 'input_text/create') {
        $script:HelperListed = $true
        $payload = [pscustomobject]@{ id = 'agent_bridge_pairing' }
    }
    # One entry per command, kept intact the way the real client does it: returned bare,
    # a result that is an empty list unrolls to nothing at all and indexing [0] throws.
    $results = [object[]]::new(1)
    $results[0] = $payload
    Write-Output -NoEnumerate $results
}
function Start-Sleep {
    param([int]$Seconds, [int]$Milliseconds)
    $script:Slept++
    if ($script:StateAfterSleeps -gt 0 -and $script:Slept -ge $script:StateAfterSleeps) { $script:HelperExists = $true }
}
Test-That 'a helper that is already there is used as it is, and nothing is created' {
    $script:Ws.Clear()
    (Initialize-BridgePairingHelper -Headers $headers) -and $script:Ws -notcontains 'input_text/create'
} "ws=[$($script:Ws -join ',')]"
$script:Ws.Clear(); $script:HelperListed = $false; $script:HelperExists = $false
$script:Slept = 0; $script:StateAfterSleeps = 2
Test-That 'a helper created now is waited for until its state is really there' {
    (Initialize-BridgePairingHelper -Headers $headers) -and $script:Ws -contains 'input_text/create'
} "ws=[$($script:Ws -join ',')] slept=$($script:Slept)"
Test-That 'and pairing can read it the moment this says so' {
    $null -ne (Get-BridgePairingHelperValue -Headers $headers)
}
$script:Ws.Clear(); $script:HelperListed = $false; $script:HelperExists = $false
$script:Slept = 0; $script:StateAfterSleeps = 0
Test-That 'a helper whose state never arrives is a failure, not a success to trip over' {
    -not (Initialize-BridgePairingHelper -Headers $headers)
} "slept=$($script:Slept)"
$script:StateAfterSleeps = 0

Write-Host '--- the daemon''s look at the helper ---'
Reset-FakeHa
$script:Started = @()
$start = { param($Attempt) $script:Started += $Attempt }
Test-That 'an empty helper is idle' { (Invoke-DaemonPairingRequest -Headers $headers -StartSponsor $start) -ceq 'idle' }
$req = New-BridgePairingJoiner -FleetId $fleet -Joiner 'J' -Sponsor 'S' -SponsorSlug 'someone_else'
$script:Helper = $req.Request
Test-That 'a request for another machine is not ours' { (Invoke-DaemonPairingRequest -Headers $headers -StartSponsor $start) -ceq 'not-ours' }
$req = New-BridgePairingJoiner -FleetId (New-BridgePairingId) -Joiner 'J' -Sponsor 'S' -SponsorSlug 'dswett_home'
$script:Helper = $req.Request
Test-That 'one for another fleet is refused' { (Invoke-DaemonPairingRequest -Headers $headers -StartSponsor $start) -ceq 'other-fleet' -and $script:Started.Count -eq 0 }
$req = New-BridgePairingJoiner -FleetId $fleet -Joiner 'J' -Sponsor 'S' -SponsorSlug 'dswett_home'
$script:Helper = $req.Request
Test-That 'one for this machine starts a sponsor, by attempt id alone' { (Invoke-DaemonPairingRequest -Headers $headers -StartSponsor $start) -ceq 'started' -and $script:Started -ceq @($req.Attempt) }
Test-That 'and only once, however many passes see it' { (Invoke-DaemonPairingRequest -Headers $headers -StartSponsor $start) -ceq 'running' -and $script:Started.Count -eq 1 }
# Recording the attempt before the process started left every later pass answering
# 'running' for a sponsor that never existed.
$script:DaemonPairingAttempt = ''
$req = New-BridgePairingJoiner -FleetId $fleet -Joiner 'J' -Sponsor 'S' -SponsorSlug 'dswett_home'
$script:Helper = $req.Request
$failing = { param($Attempt) throw 'could not start the sponsor' }
$threw = $false
try { [void](Invoke-DaemonPairingRequest -Headers $headers -StartSponsor $failing) } catch { $threw = $true }
Test-That 'a sponsor that fails to start is reported, not recorded as running' { $threw -and $script:DaemonPairingAttempt -ceq '' }
$script:Started = @()
Test-That 'so the next pass tries again' { (Invoke-DaemonPairingRequest -Headers $headers -StartSponsor $start) -ceq 'started' -and $script:Started -ceq @($req.Attempt) }
# Start-Process only establishes that pwsh was created. A sponsor that exits straight
# away - a missing entry point mid-update, a failure during initialisation - left the
# attempt recorded, so every later pass answered 'running' for nothing while the joiner
# waited out its whole timeout. The request is still in the helper here, which is itself
# the evidence that the sponsor never answered it.
$script:DaemonPairingAttempt = ''
$script:DaemonPairingSponsor = $null
$script:Started = @()
# One object, looked at again each pass, because that is what a real process handle is:
# an object built per call would answer with whatever was true when it was started.
$script:Child = [pscustomobject]@{ HasExited = $false }
$dead = { param($Attempt) $script:Started += $Attempt; $script:Child }
Test-That 'a sponsor whose process answers is started as usual' {
    (Invoke-DaemonPairingRequest -Headers $headers -StartSponsor $dead) -ceq 'started' -and $script:Started.Count -eq 1
}
Test-That 'and while it is alive the next pass leaves it alone' {
    (Invoke-DaemonPairingRequest -Headers $headers -StartSponsor $dead) -ceq 'running' -and $script:Started.Count -eq 1
}
$script:Child.HasExited = $true
Test-That 'but once it has gone without answering, the next pass starts another' {
    (Invoke-DaemonPairingRequest -Headers $headers -StartSponsor $dead) -ceq 'started' -and $script:Started.Count -eq 2
}
# A starter that hands nothing back is every caller that cannot say, and two sponsors
# racing to answer one pairing is worse than waiting for one that may still be there.
$script:DaemonPairingAttempt = ''
$script:DaemonPairingSponsor = $null
$script:Started = @()
Test-That 'a sponsor nobody can ask about is left running rather than started twice' {
    [void](Invoke-DaemonPairingRequest -Headers $headers -StartSponsor $start)
    (Invoke-DaemonPairingRequest -Headers $headers -StartSponsor $start) -ceq 'running' -and $script:Started.Count -eq 1
}
$script:DaemonPairingSponsor = $null
$script:MySecret = ''
$script:DaemonPairingAttempt = ''
Test-That 'a machine without the secret cannot sponsor' { (Invoke-DaemonPairingRequest -Headers $headers -StartSponsor $start) -ceq 'not-a-member' }

Write-Host '--- the lockout ---'
Reset-FakeHa
Test-That 'no refusals, no lock' { -not (Test-BridgePairingLocked) }
1..3 | ForEach-Object { Add-BridgePairingRefusal }
Test-That 'three refusals lock pairing' { Test-BridgePairingLocked }
Test-That 'and the lock lifts once they are old enough' { -not (Test-BridgePairingLocked -Now ([DateTimeOffset]::Now.AddMinutes(16))) }
$req = New-BridgePairingJoiner -FleetId $fleet -Joiner 'J' -Sponsor 'S' -SponsorSlug 'dswett_home'
$script:Helper = $req.Request
$script:Started = @()
Test-That 'a locked sponsor refuses at once and starts nothing' {
    (Invoke-DaemonPairingRequest -Headers $headers -StartSponsor $start) -ceq 'locked' -and $script:Helper -ceq 'refused:J' -and $script:Started.Count -eq 0
}
Set-Content -LiteralPath (Join-Path $script:Runtime 'agent-bridge-pairing-refusals.json') -Value 'not json'
Test-That 'an unreadable lockout record fails closed' { Test-BridgePairingLocked }

Write-Host '--- checking a pasted secret ---'
Reset-FakeHa
$member = [pscustomobject]@{ Machine = 'DSWETT-HOME'; Slug = 'dswett_home'; FleetId = $fleet }
# The member's daemon answers the check on the read after the joiner writes it.
$script:OnHelperRead = {
    if ($script:Helper -match '^check:dswett_home:([0-9a-f]{32})$') {
        $script:OnHelperRead = $null
        [void](Invoke-DaemonPairingRequest -Headers $headers -StartSponsor $start)
    }
}
Test-That 'the right secret passes' { Test-BridgeFleetSecretWithMember -Secret $secret -Member $member -Headers $headers }
Test-That 'leaving the helper empty' { $script:Helper -ceq '' }
$script:OnHelperRead = {
    if ($script:Helper -match '^check:dswett_home:') { $script:OnHelperRead = $null; [void](Invoke-DaemonPairingRequest -Headers $headers -StartSponsor $start) }
}
Test-That 'a typo does not' { -not (Test-BridgeFleetSecretWithMember -Secret ($secret.Substring(1) + 'A') -Member $member -Headers $headers) }
Test-That 'and the answer reveals nothing usable about the secret' {
    $tag = Get-BridgePairingCheckTag -Secret $secret -Nonce ('0' * 32)
    $tag -match '^[0-9a-f]{32}$' -and -not $secret.Contains($tag)
}

Write-Host '--- a Home Assistant call the offline guard refuses ---'
# A suite that fails to mock one of these reaches the transport guard. Read as "the
# helper cannot be read", that became $null here and 'idle' from the daemon's pass, so
# an attempt to reach a real Home Assistant looked exactly like a machine with nothing
# to do and nobody ever saw it.
Reset-FakeHa
$script:OnWebSocket = $null
$script:Started = @()
$start = { param($Attempt) $script:Started += $Attempt }
$blockedRead = { Assert-BridgeHttpAllowed -Uri 'http://home-assistant.invalid/api/states/input_text.agent_bridge_pairing' -Transport 'Rest' }
$req = New-BridgePairingJoiner -FleetId $fleet -Joiner 'J' -Sponsor 'S' -SponsorSlug 'dswett_home'
$script:Helper = $req.Request
$script:OnHelperRead = $blockedRead
$caught = $null
try { [void](Get-BridgePairingHelperValue -Headers $headers) } catch { $caught = $_ }
Test-That 'an unmocked helper read raises the guard rather than reading as a helper that is not there' {
    $null -ne $caught -and (Test-BridgeObservationGuardFailure -ErrorRecord $caught)
} "caught: $(if ($caught) { $caught.Exception.Message } else { '(nothing)' })"
$caught = $null
$answer = '(the daemon answered nothing)'
try { $answer = Invoke-DaemonPairingRequest -Headers $headers -StartSponsor $start } catch { $caught = $_ }
Test-That 'so the daemon''s pass carries it out instead of reporting an idle machine' {
    $null -ne $caught -and (Test-BridgeObservationGuardFailure -ErrorRecord $caught) -and $answer -cne 'idle'
} "answer=$answer"
$caught = $null
$script:HelperListed = $true
try { [void](Initialize-BridgePairingHelper -Headers $headers) } catch { $caught = $_ }
Test-That 'and creating the helper carries it out instead of reporting a state that never arrived' {
    $null -ne $caught -and (Test-BridgeObservationGuardFailure -ErrorRecord $caught)
}
# The rename after a create is best-effort - a helper the person renamed keeps its name
# - but a refused transport is not a rename that did not take.
$script:OnHelperRead = $null
$script:HelperListed = $false
$script:StateAfterSleeps = 0
$script:OnWebSocket = {
    param($type)
    if ($type -ceq 'config/entity_registry/update') {
        Assert-BridgeHttpAllowed -Uri 'http://home-assistant.invalid/api/websocket' -Transport 'WebSocket'
    }
}
$caught = $null
try { [void](Initialize-BridgePairingHelper -Headers $headers) } catch { $caught = $_ }
Test-That 'naming the new helper carries it out too, rather than passing for a rename that did not take' {
    $null -ne $caught -and (Test-BridgeObservationGuardFailure -ErrorRecord $caught)
}
$script:OnWebSocket = $null
# The tidy-up that clears the helper is deliberately forgiving: a join is not failed
# because Home Assistant could not be reached afterwards. A refused transport is not
# that, and swallowing it let the whole check report success.
Reset-FakeHa
$guardMember = [pscustomobject]@{ Machine = 'DSWETT-HOME'; Slug = 'dswett_home'; FleetId = $fleet }
$script:OnHelperRead = {
    if ($script:Helper -match '^check:dswett_home:([0-9a-f]{32})$') {
        $script:OnHelperRead = $null
        [void](Invoke-DaemonPairingRequest -Headers $headers -StartSponsor $start)
        $script:OnHelperRead = $blockedRead
    }
}
$caught = $null
try { [void](Test-BridgeFleetSecretWithMember -Secret $secret -Member $guardMember -Headers $headers) } catch { $caught = $_ }
Test-That 'a refused tidy-up read fails the check instead of letting a pasted secret through' {
    $null -ne $caught -and (Test-BridgeObservationGuardFailure -ErrorRecord $caught)
} "caught: $(if ($caught) { $caught.Exception.Message } else { '(nothing)' })"
$script:OnHelperRead = $null
# The same tidy-up at the end of a join. The ephemeral key still has to be disposed of
# on the way out: a refused transport is no reason to leave one and a session key behind.
Reset-FakeHa
$script:Shown = ''
$guardSponsor = [pscustomobject]@{ Machine = 'DSWETT-HOME'; Slug = 'dswett_home'; FleetId = $fleet }
function Read-BridgeHaMqttSubscription {
    param($Topic, $Until, $TimeoutSeconds, $OnReady)
    & $OnReady
    $sponsor = New-BridgePairingSponsor -Request (ConvertFrom-BridgePairingRequest -Value $script:Helper) `
        -FleetId $fleet -Sponsor 'DSWETT-HOME' -SponsorSlug 'dswett_home'
    [void](& $Until @($sponsor.Offer))
    Receive-BridgePairingReveal -State $sponsor.State -Message @(Get-Sent 'reveal')[-1]
    $verdict = Resolve-BridgePairingCode -State $sponsor.State -Typed $script:Shown -Secret $secret
    $script:Helper = $verdict.Helper
    [void](& $Until @($sponsor.Offer, $verdict.Message))
}
$madeJoiner = (Get-Command New-BridgePairingJoiner -CommandType Function).ScriptBlock
$script:JoinState = $null
function New-BridgePairingJoiner {
    param($FleetId, $Joiner, $Sponsor, $SponsorSlug)
    $script:JoinState = & $madeJoiner -FleetId $FleetId -Joiner $Joiner -Sponsor $Sponsor -SponsorSlug $SponsorSlug
    $script:JoinState
}
# Armed on the read that hands back the acceptance, so the join itself is complete and
# the only read left is the one clearing the helper.
$script:OnHelperRead = { if ($script:Helper -like 'accepted:*') { $script:OnHelperRead = $blockedRead } }
$caught = $null
try { [void](Invoke-BridgePairingJoin -Sponsor $guardSponsor -Headers $headers -ShowCode { param($code) $script:Shown = $code }) }
catch { $caught = $_ }
Test-That 'a refused tidy-up read after a join carries the guard out rather than reporting a machine that joined' {
    $null -ne $caught -and (Test-BridgeObservationGuardFailure -ErrorRecord $caught)
} "caught: $(if ($caught) { $caught.Exception.Message } else { '(nothing)' })"
Test-That 'and the attempt''s key is disposed of on the way out even so' {
    $null -ne $script:JoinState -and $null -eq $script:JoinState.Key -and $null -eq $script:JoinState.SessionKey
}
Set-Item -LiteralPath function:New-BridgePairingJoiner -Value $madeJoiner
$script:OnHelperRead = $null

Write-Host '--- the sponsor process, and the log it writes ---'
# Making the inner layers carry a refused transport out only moved the problem: the
# outermost handlers in this process absorbed it again. Nothing waits on a sponsor, so
# its exit code is the only evidence anyone gets, and logging the refusal and exiting 0
# turned a forbidden call to a real Home Assistant back into a quiet nothing-to-report.
$entryPath = (Resolve-Path (Join-Path $PSScriptRoot '..\hooks\bridge-pairing-entry.ps1')).Path
$platformPath = (Resolve-Path (Join-Path $PSScriptRoot '..\hooks\bridge-platform.ps1')).Path
$entrySource = [Management.Automation.Language.Parser]::ParseFile($entryPath, [ref]$null, [ref]$null)

# The real logger, run here against a boundary that refuses, rather than a copy of it.
$logFunction = $entrySource.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Write-PairingLog'
    }, $true)
. ([scriptblock]::Create($logFunction.Extent.Text))
$realRuntimePath = (Get-Command Get-BridgeRuntimePath -CommandType Function).ScriptBlock
function Get-BridgeRuntimePath {
    param($Name)
    $refusal = [InvalidOperationException]::new('a test suite tried to write outside its sandbox')
    $refusal.Data['BridgeTestWriteBlocked'] = $true
    throw $refusal
}
$caught = $null
try { Write-PairingLog 'an attempt started' } catch { $caught = $_ }
Test-That 'a pairing log line the write boundary refused is carried out, not dropped with the rest' {
    $null -ne $caught -and (Test-BridgeObservationGuardFailure -ErrorRecord $caught)
}
function Get-BridgeRuntimePath { param($Name) throw [IO.IOException]::new('the log is unwritable') }
$caught = $null
try { Write-PairingLog 'an attempt started' } catch { $caught = $_ }
Test-That 'while a log that simply cannot be written still costs a pairing nothing' { $null -eq $caught }
Set-Item -LiteralPath function:Get-BridgeRuntimePath -Value $realRuntimePath

$sponsorBlock = @($entrySource.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -ceq '$Sponsor'
        }, $true))
Test-That 'the sponsor entry point is still one block this can run' { $sponsorBlock.Count -eq 1 }
$pwshPath = (Get-Process -Id $PID).Path

function Invoke-SponsorEntryProcess {
    <#
        Runs the real -Sponsor block as its own process, with the one call it makes
        failing. Its exit code is the whole point: a function that throws would not have
        shown the problem, because the block caught it and exited 0 regardless.
    #>
    param([Parameter(Mandatory)][ValidateSet('guard', 'ordinary')][string]$Failure)

    $stem = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $log = (Join-Path $script:Runtime "sponsor-$stem.log").Replace("'", "''")
    $throw = 'throw [IO.IOException]::new(''the sponsor could not reach the broker'')'
    if ($Failure -ceq 'guard') {
        $throw = '$refusal = [InvalidOperationException]::new(''a test suite tried to reach a real Home Assistant'')' +
        '; $refusal.Data[''BridgeTestNetworkBlocked''] = $true; throw $refusal'
    }
    $child = Join-Path $script:Runtime "sponsor-$stem.ps1"
    @(
        'Set-StrictMode -Version Latest'
        '$ErrorActionPreference = ''Stop'''
        ". '$($platformPath.Replace("'", "''"))'"
        '$Sponsor = $true'
        "`$Attempt = '$(New-BridgePairingId)'"
        '$headers = @{}'
        "function Write-PairingLog { param([string]`$Message) Add-Content -LiteralPath '$log' -Value `$Message }"
        "function Invoke-BridgePairingSponsor { param(`$Attempt, `$Headers) $throw }"
        $sponsorBlock[0].Extent.Text
    ) | Set-Content -LiteralPath $child -Encoding utf8
    $run = Start-Process -FilePath $pwshPath -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $child) `
        -NoNewWindow -Wait -PassThru
    $written = ''
    if (Test-Path -LiteralPath $log) { $written = Get-Content -LiteralPath $log -Raw }
    [pscustomobject]@{ ExitCode = $run.ExitCode; Log = $written }
}

$refused = Invoke-SponsorEntryProcess -Failure 'guard'
Test-That 'a sponsor whose transport the guard refused ends its process with a failure' { $refused.ExitCode -ne 0 } "exit=$($refused.ExitCode)"
Test-That 'and does not write it off as an attempt that merely did not work' { $refused.Log -notlike '*failed:*' } "log: $($refused.Log)"
$ordinary = Invoke-SponsorEntryProcess -Failure 'ordinary'
Test-That 'while a sponsor that really failed is logged and left to the next pass' {
    $ordinary.ExitCode -eq 0 -and $ordinary.Log -like '*failed: the sponsor could not reach the broker*'
} "exit=$($ordinary.ExitCode) log: $($ordinary.Log)"

Write-Host '--- saving the result ---'
$cfg = Join-Path $script:Runtime 'config.json'
'{"homeAssistant":{"baseUrl":"http://ha:8123","token":"t"},"newSession":{"enabled":true,"workspaces":[{"label":"Home","path":"~"}]}}' |
    Set-Content -LiteralPath $cfg -Encoding utf8
function Write-BridgeSecretFile { param($Path, $Content) $script:SecretWrites++; Set-Content -LiteralPath $Path -Value $Content -Encoding utf8 }
$script:SecretWrites = 0
Save-BridgeFleetMembership -ConfigPath $cfg -Secret $secret -FleetId $fleet -Share $true
$saved = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
Test-That 'the secret and fleet are written into newSession' { $saved.newSession.transferSecret -ceq $secret -and $saved.newSession.fleetId -ceq $fleet }
Test-That 'sharing and transfer are turned on together' { $saved.newSession.shareResumable -eq $true -and $saved.newSession.transferResumable -eq $true }
Test-That 'everything else in the file is left as it was' { $saved.homeAssistant.token -ceq 't' -and @($saved.newSession.workspaces).Count -eq 1 }
Test-That 'and it goes through the protected writer' { $script:SecretWrites -eq 1 }
Save-BridgeFleetMembership -ConfigPath $cfg -Share $false
$saved = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
Test-That 'turning sharing off leaves the membership alone' { $saved.newSession.shareResumable -eq $false -and $saved.newSession.transferSecret -ceq $secret }

Write-Host '--- upgrading machines that already share a secret ---'
# Before pairing there was no fleet id and the secret was carried from machine to
# machine by hand, so an upgrade runs configure on several machines that already hold
# the same one. A fleet id drawn at random on each left them advertising unrelated
# fleets while sharing membership, which split sponsor selection and rotation across
# fleets of one machine each.
$carried = New-BridgeFleetSecret
$first = Join-Path $script:Runtime 'config-first.json'
$second = Join-Path $script:Runtime 'config-second.json'
foreach ($path in @($first, $second)) {
    '{"homeAssistant":{"baseUrl":"http://ha:8123","token":"t"},"newSession":{"transferSecret":"carried by hand"}}' |
        Set-Content -LiteralPath $path -Encoding utf8
}
$script:MySecret = $carried
$firstId = Save-BridgeFleetIdForHeldSecret -ConfigPath $first -Share
$secondId = Save-BridgeFleetIdForHeldSecret -ConfigPath $second -Share
Test-That 'both machines settle into one fleet, with neither of them having to go first' { $firstId -ceq $secondId } "$firstId vs $secondId"
Test-That 'and each is a member of it, so either can sponsor the next machine' {
    $script:MyFleet = $firstId
    $m = Get-BridgeFleetMembership
    $m.Member -and $m.FleetId -ceq $firstId
}
Test-That 'the fleet id and the sharing settings are written into the config' {
    $upgraded = Get-Content -LiteralPath $first -Raw | ConvertFrom-Json
    $upgraded.newSession.fleetId -ceq $firstId -and $upgraded.newSession.shareResumable -eq $true -and
    $upgraded.newSession.transferSecret -ceq 'carried by hand'
}
$script:MySecret = New-BridgeFleetSecret
Test-That 'a machine whose secret nobody else holds is a fleet of its own' {
    (Save-BridgeFleetIdForHeldSecret -ConfigPath $second -Share) -cne $firstId
}
$script:MySecret = ''
$message = ''
try { [void](Save-BridgeFleetIdForHeldSecret -ConfigPath $first -Share) } catch { $message = $_.Exception.Message }
Test-That 'and a machine holding no secret is told so rather than joining an empty fleet' { $message -like '*no fleet secret*' } $message
$script:MySecret = $secret
$script:MyFleet = $fleet
# Configure itself cannot be run from here, so what is checked is the one thing about
# that branch which matters: that it no longer invents an id of its own.
$entryAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot '..\hooks\bridge-pairing-entry.ps1'), [ref]$null, [ref]$null)
$heldBranch = @($entryAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -ceq '$membership.HasSecret'
        }, $true))
Test-That 'configure settles an already-held secret into the fleet that secret belongs to' {
    $heldBranch.Count -eq 1 -and $heldBranch[0].Extent.Text -match 'Save-BridgeFleetIdForHeldSecret' -and
    $heldBranch[0].Extent.Text -notmatch 'New-BridgePairingId'
} "matched $($heldBranch.Count) branch(es)"

Remove-Item -LiteralPath $script:Runtime -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:Failures -eq 0) { Write-Host 'All pairing flow checks passed'; exit 0 }
Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
exit 1
