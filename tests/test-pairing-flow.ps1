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

Remove-Item -LiteralPath $script:Runtime -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:Failures -eq 0) { Write-Host 'All pairing flow checks passed'; exit 0 }
Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
exit 1
