#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for pairing a machine into the fleet: the cryptography and the protocol steps.

.DESCRIPTION
    Everything in hooks/bridge-pairing.ps1 is pure, so both ends of an exchange - and a
    man in the middle - are driven here in one process with no network at all. See
    docs/fleet-pairing.md for the threat model these cases are written against.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\bridge-pairing.ps1')

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
function Test-Throws {
    param([string]$Name, [scriptblock]$Action, [string]$Like)
    $message = ''
    try { & $Action; $message = '(did not throw)' } catch { $message = $_.Exception.Message }
    Test-That $Name { $message -like $Like } "threw: $message"
}

$fleet = New-BridgePairingId
$secret = New-BridgeFleetSecret

function New-HonestPair {
    param([string]$Joiner = 'DSWETT-DEV-VM1', [string]$Sponsor = 'DSWETT-HOME')
    $j = New-BridgePairingJoiner -FleetId $fleet -Joiner $Joiner -Sponsor $Sponsor -SponsorSlug 'dswett_home'
    $request = ConvertFrom-BridgePairingRequest -Value $j.Request
    $s = New-BridgePairingSponsor -Request $request -FleetId $fleet -Sponsor $Sponsor -SponsorSlug 'dswett_home'
    $reveal = Receive-BridgePairingOffer -State $j -Message $s.Offer
    Receive-BridgePairingReveal -State $s.State -Message $reveal
    [pscustomobject]@{ Joiner = $j; Sponsor = $s.State; Offer = $s.Offer; Reveal = $reveal }
}

Write-Host '--- the platform has what the protocol needs ---'
# Checked here because the macOS CI job runs this suite: AES-GCM under PowerShell on
# macOS was the design's first open item.
Test-That 'AES-GCM is available on this platform' { [Security.Cryptography.AesGcm]::IsSupported }
Test-That 'a fleet secret is 32 random bytes' { [Convert]::FromBase64String((New-BridgeFleetSecret)).Length -eq 32 }
Test-That 'two fleet secrets differ' { (New-BridgeFleetSecret) -cne (New-BridgeFleetSecret) }

Write-Host '--- which AES-GCM constructor a pairing is built on ---'
# PowerShell 7.2 and 7.3 meet the documented PowerShell 7 requirement and run .NET 6
# and 7, where AesGcm(byte[], int) does not exist - so pairing threw there at the
# moment the person had just typed the code, and IsSupported above says nothing about
# it. AesGcm(byte[]) is in turn obsolete on .NET 8. These two stand in for the runtime
# this machine is not.
class PairingAesNetSix {
    [byte[]]$Key
    [int]$TagBytes
    PairingAesNetSix([byte[]]$key) { $this.Key = $key; $this.TagBytes = 0 }
}
class PairingAesNetEight {
    [byte[]]$Key
    [int]$TagBytes
    PairingAesNetEight([byte[]]$key) { $this.Key = $key; $this.TagBytes = 0 }
    PairingAesNetEight([byte[]]$key, [int]$tagBytes) { $this.Key = $key; $this.TagBytes = $tagBytes }
}
$aesKey = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
Test-That 'a runtime that has only the key-only constructor still gets its AES-GCM' {
    $made = New-BridgePairingAesGcm -Key $aesKey -Implementation ([PairingAesNetSix])
    $made -is [PairingAesNetSix] -and [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($made.Key, $aesKey)
}
Test-That 'a runtime that has the tagged constructor is asked for the same 16-byte tag' {
    (New-BridgePairingAesGcm -Key $aesKey -Implementation ([PairingAesNetEight])).TagBytes -eq 16
}
Test-Throws 'and a runtime with neither says so instead of failing inside an exchange' {
    [void](New-BridgePairingAesGcm -Key $aesKey -Implementation ([datetime]))
} '*no constructor pairing can use*'
Test-That 'whichever this runtime has, a secret seals and opens again' {
    $k = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    $t = Get-BridgePairingHash -Values @('a transcript')
    (Unprotect-BridgePairingSecret -SessionKey $k -Transcript $t `
            -Ciphertext (Protect-BridgePairingSecret -SessionKey $k -Secret $secret -Transcript $t)) -ceq $secret
}
Test-That 'and nothing in the hooks reaches for a constructor of its own' {
    @(Select-String -Path (Join-Path $PSScriptRoot '..\hooks\*.ps1') -Pattern 'AesGcm\]::new').Count -eq 0
}

Write-Host '--- the fleet a shared secret belongs to ---'
# Upgrading an installation from before pairing: every machine holds the same
# hand-copied secret and none has a fleet id, and configure then runs on each of them
# separately. A fleet id drawn at random on each left machines that share membership
# advertising unrelated fleets, so a joiner saw several one-machine fleets.
$carried = New-BridgeFleetSecret
Test-That 'two machines holding the same secret settle on one fleet, neither going first' {
    (Get-BridgeFleetIdFromSecret -Secret $carried) -ceq (Get-BridgeFleetIdFromSecret -Secret $carried)
}
Test-That 'a machine holding a different secret settles on a different fleet' {
    (Get-BridgeFleetIdFromSecret -Secret $carried) -cne (Get-BridgeFleetIdFromSecret -Secret (New-BridgeFleetSecret))
}
Test-That 'what it settles on is a fleet id a request and a sponsor both accept' {
    (Get-BridgeFleetIdFromSecret -Secret $carried) -match '^[0-9a-f]{32}$'
}
Test-That 'it is named for what it is, so no other hash of the secret can collide with it' {
    (Get-BridgeFleetIdFromSecret -Secret $carried) -cne
        (ConvertTo-BridgePairingHex -Bytes (Get-BridgePairingHash -Values @('code', $carried))).Substring(0, 32)
}
Test-That 'and a public fleet id gives nothing away about the secret it came from' {
    $id = Get-BridgeFleetIdFromSecret -Secret $carried
    -not $carried.Contains($id) -and
    -not ([Convert]::ToHexString([Convert]::FromBase64String($carried)).ToLowerInvariant().Contains($id))
}

Write-Host '--- an honest pairing ---'
$p = New-HonestPair
Test-That 'both ends arrive at the same six-digit code' { $p.Joiner.Code -match '^\d{6}$' -and $p.Joiner.Code -ceq $p.Sponsor.Code }
Test-That 'and the same session key' {
    [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($p.Joiner.SessionKey, $p.Sponsor.SessionKey)
}
$typed = $p.Joiner.Code.Substring(0, 3) + ' ' + $p.Joiner.Code.Substring(3)
$verdict = Resolve-BridgePairingCode -State $p.Sponsor -Typed $typed -Secret $secret
Test-That 'the code is accepted however the person grouped the digits' { $verdict.Accepted }
Test-That 'and the acceptance names the joiner' { $verdict.Helper -like 'accepted:DSWETT-DEV-VM1:*' }
Test-That 'the secret message carries no plaintext' { -not ($verdict.Message | ConvertTo-Json -Compress).Contains($secret) }
$joined = Complete-BridgePairingJoin -State $p.Joiner -HelperValue $verdict.Helper -Message $verdict.Message
Test-That 'the joiner ends up with exactly the sponsor''s secret' { $joined -ceq $secret }
Test-Throws 'a finished join cannot be completed again' { Complete-BridgePairingJoin -State $p.Joiner -HelperValue $verdict.Helper -Message $verdict.Message } '*cannot complete while joined*'
Test-That 'the request fits in a Home Assistant text helper' { $p.Joiner.Request.Length -le 255 }

Write-Host '--- what is hashed cannot be confused ---'
Test-That 'values are framed by length, so moving a boundary changes the hash' {
    -not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
        (Get-BridgePairingHash -Values @('ab', 'c')), (Get-BridgePairingHash -Values @('a', 'bc')))
}
# The framing first took its bytes from an if expression, which unrolled a one-byte
# value into a bare [byte] and an empty one into $null - so a one-letter machine name
# could not be hashed, and an honest exchange with long names hid it.
Test-That 'a one-letter machine name can pair' { $q = New-HonestPair -Joiner 'J' -Sponsor 'S'; $q.Joiner.Code -ceq $q.Sponsor.Code }
Test-That 'and an empty value can be hashed' { (Get-BridgePairingHash -Values @('', 'x')).Length -eq 32 }

Write-Host '--- a man in the middle ---'
# The attacker sits on MQTT between the joiner and the real sponsor. It can read and
# replace every MQTT message, but not what the person types into Home Assistant, nor
# what the sponsor writes there.
$j = New-BridgePairingJoiner -FleetId $fleet -Joiner 'DSWETT-DEV-VM1' -Sponsor 'DSWETT-HOME' -SponsorSlug 'dswett_home'
$fakeSponsor = New-BridgePairingSponsor -Request (ConvertFrom-BridgePairingRequest -Value $j.Request) -FleetId $fleet -Sponsor 'DSWETT-HOME' -SponsorSlug 'dswett_home'
$fakeJoiner = New-BridgePairingJoiner -FleetId $fleet -Joiner 'DSWETT-DEV-VM1' -Sponsor 'DSWETT-HOME' -SponsorSlug 'dswett_home'
$fakeJoiner.Attempt = $j.Attempt
$fakeRequest = ConvertTo-BridgePairingRequest -SponsorSlug 'dswett_home' -Attempt $j.Attempt -FleetId $fleet -Joiner 'DSWETT-DEV-VM1' `
    -Commit (Get-BridgePairingCommit -Public $fakeJoiner.Public -Nonce $fakeJoiner.Nonce)
$realSponsor = New-BridgePairingSponsor -Request (ConvertFrom-BridgePairingRequest -Value $fakeRequest) -FleetId $fleet -Sponsor 'DSWETT-HOME' -SponsorSlug 'dswett_home'
Receive-BridgePairingReveal -State $fakeSponsor.State -Message (Receive-BridgePairingOffer -State $j -Message $fakeSponsor.Offer)
Receive-BridgePairingReveal -State $realSponsor.State -Message (Receive-BridgePairingOffer -State $fakeJoiner -Message $realSponsor.Offer)
Test-That 'the joiner and the real sponsor see different codes' { $j.Code -cne $realSponsor.State.Code }
$real = Resolve-BridgePairingCode -State $realSponsor.State -Typed $j.Code -Secret $secret
Test-That 'so the real sponsor refuses the code the person carried from the joiner' { -not $real.Accepted -and $real.Helper -ceq 'refused:DSWETT-DEV-VM1' -and $null -eq $real.Message }
$forged = Resolve-BridgePairingCode -State $fakeSponsor.State -Typed $j.Code -Secret 'a secret the attacker knows'
Test-Throws 'and the joiner refuses the attacker''s secret, because Home Assistant shows a refusal' {
    Complete-BridgePairingJoin -State $j -HelperValue $real.Helper -Message $forged.Message
} '*refused the code*'
$j2 = New-BridgePairingJoiner -FleetId $fleet -Joiner 'DSWETT-DEV-VM1' -Sponsor 'DSWETT-HOME' -SponsorSlug 'dswett_home'
$f2 = New-BridgePairingSponsor -Request (ConvertFrom-BridgePairingRequest -Value $j2.Request) -FleetId $fleet -Sponsor 'DSWETT-HOME' -SponsorSlug 'dswett_home'
Receive-BridgePairingReveal -State $f2.State -Message (Receive-BridgePairingOffer -State $j2 -Message $f2.Offer)
$f2Verdict = Resolve-BridgePairingCode -State $f2.State -Typed $j2.Code -Secret 'a secret the attacker knows'
Test-Throws 'an acceptance for any other transcript is refused too, even with the right joiner name' {
    $other = New-HonestPair
    $otherAcceptance = Get-BridgePairingAcceptance -Transcript $other.Sponsor.Transcript -Joiner 'DSWETT-DEV-VM1'
    Complete-BridgePairingJoin -State $j2 -HelperValue $otherAcceptance -Message $f2Verdict.Message
} '*does not show DSWETT-HOME accepting*'

Write-Host '--- refusals ---'
$q = New-HonestPair
$wrong = '{0:D6}' -f (([int]$q.Joiner.Code + 1) % 1000000)
$no = Resolve-BridgePairingCode -State $q.Sponsor -Typed $wrong -Secret $secret
Test-That 'a wrong code is refused, and no secret message is made' { -not $no.Accepted -and $null -eq $no.Message }
Test-Throws 'and a refused attempt takes no second guess' { Resolve-BridgePairingCode -State $q.Sponsor -Typed $q.Joiner.Code -Secret $secret } '*not expected while refused*'
Test-Throws 'the joiner reports the refusal for what it is' { Complete-BridgePairingJoin -State $q.Joiner -HelperValue $no.Helper -Message $null } '*refused the code*'
Test-Throws 'an empty helper is not an acceptance' { Complete-BridgePairingJoin -State (New-HonestPair).Joiner -HelperValue '' -Message $null } '*does not show*'

Write-Host '--- the commitment ---'
$c = New-BridgePairingJoiner -FleetId $fleet -Joiner 'A' -Sponsor 'B' -SponsorSlug 'b'
$cs = New-BridgePairingSponsor -Request (ConvertFrom-BridgePairingRequest -Value $c.Request) -FleetId $fleet -Sponsor 'B' -SponsorSlug 'b'
$honestReveal = Receive-BridgePairingOffer -State $c -Message $cs.Offer
$swapped = New-BridgePairingKeyPair
$badReveal = New-BridgePairingMessage -Type 'reveal' -Attempt $c.Attempt -Fields @{ public = $swapped.Public; nonce = $honestReveal.nonce }
Test-Throws 'a reveal with a different key than was committed to is refused' { Receive-BridgePairingReveal -State $cs.State -Message $badReveal } '*does not match the commitment*'
$swapped.Key.Dispose()

Write-Host '--- messages that are not for this step ---'
$m = New-BridgePairingJoiner -FleetId $fleet -Joiner 'A' -Sponsor 'B' -SponsorSlug 'b'
$ms = New-BridgePairingSponsor -Request (ConvertFrom-BridgePairingRequest -Value $m.Request) -FleetId $fleet -Sponsor 'B' -SponsorSlug 'b'
$offer = $ms.Offer
Test-Throws 'an offer for another attempt is refused' {
    Receive-BridgePairingOffer -State $m -Message (New-BridgePairingMessage -Type 'offer' -Attempt (New-BridgePairingId) -Fields @{ public = $offer.public; nonce = $offer.nonce; sponsor = 'B' })
} '*another attempt*'
Test-Throws 'a message of the wrong type is refused' {
    Receive-BridgePairingOffer -State $m -Message (New-BridgePairingMessage -Type 'reveal' -Attempt $m.Attempt -Fields @{ public = $offer.public; nonce = $offer.nonce; sponsor = 'B' })
} '*expected a offer message*'
Test-Throws 'an offer from a machine other than the one chosen is refused' {
    Receive-BridgePairingOffer -State $m -Message (New-BridgePairingMessage -Type 'offer' -Attempt $m.Attempt -Fields @{ public = $offer.public; nonce = $offer.nonce; sponsor = 'SOMEONE-ELSE' })
} '*not B*'
Test-Throws 'another protocol is refused' {
    $o = $offer.PSObject.Copy(); $o.protocol = 'something else v9'
    Receive-BridgePairingOffer -State $m -Message $o
} '*unsupported pairing protocol*'
Test-Throws 'a message missing a field is refused' {
    Receive-BridgePairingOffer -State $m -Message (New-BridgePairingMessage -Type 'offer' -Attempt $m.Attempt -Fields @{ nonce = 'x'; sponsor = 'B' })
} '*has no public*'
Test-Throws 'a code is not judged before the reveal' { Resolve-BridgePairingCode -State $ms.State -Typed '000000' -Secret $secret } '*not expected while offered*'

Write-Host '--- keys ---'
Test-Throws 'a public key on another curve is refused' {
    $p384 = [Security.Cryptography.ECDiffieHellman]::Create([Security.Cryptography.ECCurve+NamedCurves]::nistP384)
    try { [void](Import-BridgePairingPublicKey -Public ([Convert]::ToBase64String($p384.ExportSubjectPublicKeyInfo()))) } finally { $p384.Dispose() }
} '*refused*'
Test-Throws 'and so is something that is not a key' { [void](Import-BridgePairingPublicKey -Public 'bm90IGEga2V5') } '*refused*'

Write-Host '--- the ciphertext ---'
$t = New-HonestPair
$sealed = Protect-BridgePairingSecret -SessionKey $t.Sponsor.SessionKey -Secret $secret -Transcript $t.Sponsor.Transcript
Test-That 'sealing twice gives different ciphertext' { $sealed -cne (Protect-BridgePairingSecret -SessionKey $t.Sponsor.SessionKey -Secret $secret -Transcript $t.Sponsor.Transcript) }
Test-Throws 'a flipped bit is refused' {
    $b = [Convert]::FromBase64String($sealed); $b[14] = $b[14] -bxor 1
    Unprotect-BridgePairingSecret -SessionKey $t.Joiner.SessionKey -Ciphertext ([Convert]::ToBase64String($b)) -Transcript $t.Joiner.Transcript
} '*did not authenticate*'
Test-Throws 'ciphertext made for another transcript is refused' {
    $u = New-HonestPair
    Unprotect-BridgePairingSecret -SessionKey $t.Joiner.SessionKey -Ciphertext $sealed -Transcript $u.Joiner.Transcript
} '*did not authenticate*'
Test-Throws 'a truncated message is refused' { Unprotect-BridgePairingSecret -SessionKey $t.Joiner.SessionKey -Ciphertext 'AAAA' -Transcript $t.Joiner.Transcript } '*too short*'

Write-Host '--- the request in the helper ---'
$r = ConvertFrom-BridgePairingRequest -Value $t.Joiner.Request
Test-That 'a request reads back field for field' { $r.SponsorSlug -ceq 'dswett_home' -and $r.Attempt -ceq $t.Joiner.Attempt -and $r.Joiner -ceq 'DSWETT-DEV-VM1' -and $r.FleetId -ceq $fleet }
Test-That 'a typed code is not mistaken for a request' { $null -eq (ConvertFrom-BridgePairingRequest -Value '482913') }
Test-That 'nor is an acceptance' { $null -eq (ConvertFrom-BridgePairingRequest -Value 'accepted:X:0123456789abcdef') }
Test-Throws 'a machine name with a colon cannot make a request' {
    ConvertTo-BridgePairingRequest -SponsorSlug 's' -Attempt (New-BridgePairingId) -FleetId $fleet -Joiner 'a:b' -Commit ('0' * 64)
} '*cannot contain a colon*'
Test-Throws 'a sponsor refuses a request addressed to another machine' {
    New-BridgePairingSponsor -Request $r -FleetId $fleet -Sponsor 'DSWETT-DEV-VM1' -SponsorSlug 'dswett_dev_vm1'
} '*for another machine*'
Test-Throws 'and one for another fleet' {
    New-BridgePairingSponsor -Request $r -FleetId (New-BridgePairingId) -Sponsor 'DSWETT-HOME' -SponsorSlug 'dswett_home'
} '*for another fleet*'

Write-Host '--- cleaning up ---'
$z = New-HonestPair
$keyRef = $z.Sponsor.SessionKey
Close-BridgePairingState -State $z.Sponsor
Test-That 'closing an attempt wipes its session key and drops its private key' {
    $null -eq $z.Sponsor.Key -and $null -eq $z.Sponsor.SessionKey -and @($keyRef | Where-Object { $_ -ne 0 }).Count -eq 0
}
Test-That 'and closing nothing is harmless' { Close-BridgePairingState -State $null; $true }

Write-Host ''
if ($script:Failures -eq 0) { Write-Host 'All pairing checks passed'; exit 0 }
Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
exit 1
