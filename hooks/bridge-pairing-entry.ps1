<#
    The entry point for pairing, as its own process:

      -Sponsor -Attempt <id>   started by the daemon when the helper holds a request for
                               this machine; runs the sponsor's side and exits.
      -Configure               the interactive "Session sharing" step, run by
                               install.ps1 once it has written the config, and by
                               `agent-ha-bridge pair`.
      -Show                    prints this machine's fleet secret, for the paste fallback.
      -Rotate                  replaces this machine's fleet secret; the others re-pair.

    Kept apart from the libraries because dot-sourcing a script rebinds every parameter
    it declares; nothing else dot-sources this file.
#>
[CmdletBinding()]
param(
    [switch]$Sponsor,
    [ValidatePattern('^[0-9a-f]{32}$')][string]$Attempt,
    [switch]$Configure,
    [switch]$Show,
    [switch]$Rotate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot 'decision-mqtt.ps1')
. (Join-Path $PSScriptRoot 'decision-ha-websocket.ps1')
. (Join-Path $PSScriptRoot 'session-launch.ps1')
. (Join-Path $PSScriptRoot 'bridge-pairing.ps1')
. (Join-Path $PSScriptRoot 'bridge-pairing-io.ps1')

$headers = Get-HomeAssistantHeaders
$configPath = $script:BridgeInstallContext.ConfigPath

function Write-PairingLog {
    # The code, the key and the secret never reach this log.
    param([string]$Message)
    try {
        Add-Content -LiteralPath (Get-BridgeRuntimePath -Name 'agent-bridge-pairing.log') -Encoding utf8 `
            -Value "$([DateTimeOffset]::Now.ToString('o')) $Message"
    }
    catch { }
}

function Read-PairingAnswer {
    param([string]$Prompt, [string]$Default = '')
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $answer = Read-Host "$Prompt$suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    $answer.Trim()
}

function Read-PairingYesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $answer = Read-PairingAnswer -Prompt "$Prompt $(if ($Default) { '[Y/n]' } else { '[y/N]' })"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    $answer -match '^(y|yes)$'
}

function Get-PairingSponsorsOrNone {
    # Discovery fails when Home Assistant cannot be reached, which is exactly when the
    # paste fallback has to keep working, so a failure here is "nobody to ask", not fatal.
    try { @(Get-BridgePairingSponsors -Headers $headers) }
    catch {
        if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
        [object[]]::new(0)
    }
}

function Select-PairingMachine {
    <# One of $Machines, chosen by number; the only one when there is just one. #>
    param([object[]]$Machines, [string]$Prompt)
    if ($Machines.Count -eq 1) { return $Machines[0] }
    for ($i = 0; $i -lt $Machines.Count; $i++) {
        Write-Host ("      {0}) {1,-20} fleet {2}" -f ($i + 1), $Machines[$i].Machine, $Machines[$i].FleetId.Substring(0, 8))
    }
    $pick = Read-PairingAnswer -Prompt $Prompt -Default '1'
    if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $Machines.Count) { throw "there is no machine $pick" }
    $Machines[[int]$pick - 1]
}

function Invoke-PairingJoin {
    <# Pairs with $Chosen and saves the result. Used for a first join and for re-pairing. #>
    param([Parameter(Mandatory)]$Chosen)
    # Created here, by the person choosing to pair, rather than by any daemon: a helper
    # somebody deleted on purpose stays deleted until somebody pairs again.
    if (-not (Initialize-BridgePairingHelper -Headers $headers)) { throw 'could not create the Pair a machine helper in Home Assistant' }
    Write-Host "    asking $($Chosen.Machine)..."
    $result = Invoke-BridgePairingJoin -Sponsor $Chosen -Headers $headers -ShowCode {
        param($code)
        Write-Host ''
        Write-Host '    In Home Assistant, type this code into "Pair a machine"' -ForegroundColor Yellow
        Write-Host '    (Settings > Devices & services > Helpers, or the entity on any dashboard):' -ForegroundColor Yellow
        Write-Host ''
        Write-Host "        $($code.Substring(0, 3)) $($code.Substring(3))" -ForegroundColor Green
        Write-Host ''
        Write-Host "    Waiting for $($Chosen.Machine)..."
    }
    Save-BridgeFleetMembership -ConfigPath $configPath -Secret $result.Secret -FleetId $result.FleetId -Share $true
    Write-Host "    paired with $($Chosen.Machine); sharing is on" -ForegroundColor Green
}

function Invoke-PairingPaste {
    <#
        Saves a pasted secret, checked against a member when one can answer. When none
        can - Home Assistant unreachable, or every member offline, which is what this
        fallback is for - it saves only on an explicit acknowledgement that it is
        unchecked, and asks for the fleet id it belongs to.
    #>
    $pasted = Read-BridgeSecret -Prompt '    Paste the fleet secret (from agent-ha-bridge secret show)'
    if ([string]::IsNullOrWhiteSpace($pasted)) { Write-Host '    nothing pasted; skipped'; return }
    $pasted = $pasted.Trim()
    $members = @(Get-PairingSponsorsOrNone)
    if ($members.Count -gt 0) {
        Write-Host '    Check it against:'
        $member = Select-PairingMachine -Machines $members -Prompt '    Machine'
        if (-not (Initialize-BridgePairingHelper -Headers $headers)) { throw 'could not create the Pair a machine helper in Home Assistant' }
        if (-not (Test-BridgeFleetSecretWithMember -Secret $pasted -Member $member -Headers $headers)) {
            throw "that is not $($member.Machine)'s fleet secret - nothing was saved"
        }
        Save-BridgeFleetMembership -ConfigPath $configPath -Secret $pasted -FleetId $member.FleetId -Share $true
        Write-Host "    checked against $($member.Machine) and saved; sharing is on"
        return
    }
    Write-Host '    No machine in a fleet can answer a check right now, so this secret cannot be' -ForegroundColor Yellow
    Write-Host '    verified. A typo would only show up later, as transfers that refuse.' -ForegroundColor Yellow
    $fleet = Read-PairingAnswer -Prompt '    Fleet id it belongs to (agent-ha-bridge status on a member shows it)'
    if ($fleet -notmatch '^[0-9a-f]{32}$') { throw 'that is not a fleet id - nothing was saved' }
    if ((Read-PairingAnswer -Prompt '    Type SAVE UNCHECKED to save it anyway') -cne 'SAVE UNCHECKED') {
        Write-Host '    not saved'; return
    }
    Save-BridgeFleetMembership -ConfigPath $configPath -Secret $pasted -FleetId $fleet -Share $true
    Write-Host '    saved unchecked; sharing is on'
}

if ($Sponsor) {
    if (-not $Attempt) { throw '-Sponsor needs -Attempt' }
    Write-PairingLog "sponsor attempt $Attempt started"
    try {
        $outcome = Invoke-BridgePairingSponsor -Attempt $Attempt -Headers $headers
        Write-PairingLog "sponsor attempt ${Attempt}: $outcome"
    }
    catch { Write-PairingLog "sponsor attempt $Attempt failed: $($_.Exception.Message)" }
    exit 0
}

if ($Show) {
    # Refused when the output is going anywhere but a person's screen, so the secret does
    # not end up in a log or a pipe by accident.
    if ([Console]::IsOutputRedirected) { throw 'agent-ha-bridge secret show only prints to a terminal' }
    $secret = Get-BridgeTransferSecret
    if (-not $secret) { Write-Host 'This machine holds no fleet secret.'; exit 1 }
    Write-Host ''
    Write-Host 'The fleet secret. Anyone holding it can ask this fleet for sessions - paste it' -ForegroundColor Yellow
    Write-Host 'only into agent-ha-bridge configure on a machine you are adding, then clear it.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "    $secret"
    Write-Host "    fleet $(Get-BridgeFleetId)"
    Write-Host ''
    exit 0
}

if ($Rotate) {
    # A shared secret cannot be un-shared, so removing a machine from the fleet, or
    # recovering from a leaked secret, means replacing it. The fleet id stays, so the
    # other machines re-pair with this one as before.
    $membership = Get-BridgeFleetMembership
    if (-not $membership.Member) { throw 'This machine is not in a fleet; there is no secret to rotate.' }
    Write-Host "Rotating the secret for fleet $($membership.FleetId.Substring(0, 8))." -ForegroundColor Yellow
    Write-Host 'Every other machine stops being able to transfer with this one until it re-pairs,'
    Write-Host 'with agent-ha-bridge pair on that machine.'
    if ((Read-PairingAnswer -Prompt 'Type ROTATE to continue') -cne 'ROTATE') { Write-Host 'not rotated'; exit 1 }
    Save-BridgeFleetMembership -ConfigPath $configPath -Secret (New-BridgeFleetSecret) -FleetId $membership.FleetId
    Write-PairingLog "fleet secret rotated for fleet $($membership.FleetId)"
    Write-Host 'rotated; now run agent-ha-bridge pair on each other machine, choosing this one' -ForegroundColor Green
    exit 0
}

if (-not $Configure) { throw 'Pass -Configure, -Sponsor, -Show or -Rotate.' }

Write-Host '==> Session sharing' -ForegroundColor Cyan
$membership = Get-BridgeFleetMembership

# The carry file #77 left behind, imported once and then removed, so the secret lives in
# exactly one protected place.
$carry = Join-Path (Split-Path $configPath -Parent) 'transfer-secret.txt'
if (-not $membership.HasSecret -and (Test-Path -LiteralPath $carry)) {
    $carried = (Get-Content -LiteralPath $carry -Raw).Trim()
    if ($carried -and (Read-PairingYesNo -Prompt "    Found $carry. Use it as this machine's fleet secret?")) {
        Save-BridgeFleetMembership -ConfigPath $configPath -Secret $carried
        Remove-Item -LiteralPath $carry -Force
        Write-Host '    imported, and the carry file deleted'
        $script:BridgeUserConfig = Get-BridgeUserConfig
        $membership = Get-BridgeFleetMembership
    }
}

$sharingOn = (Get-BridgeSetting 'newSession.shareResumable' $false) -eq $true
if ($membership.Member) {
    Write-Host "    this machine is in fleet $($membership.FleetId.Substring(0, 8))"
    $share = Read-PairingYesNo -Prompt '    Share and resume sessions across machines?' -Default $sharingOn
    Save-BridgeFleetMembership -ConfigPath $configPath -Share $share
    Write-Host "    sharing is $(if ($share) { 'on' } else { 'off' })"
    # After a rotation elsewhere, this machine's secret is the old one, so a member needs
    # a way back in that does not involve editing the config by hand.
    if ($share -and (Read-PairingYesNo -Prompt '    Re-pair, to pick up a secret rotated on another machine?' -Default $false)) {
        $sponsors = @(Get-PairingSponsorsOrNone)
        if ($sponsors.Count -eq 0) { throw 'no other machine in a fleet is online to re-pair with' }
        Write-Host '    Re-pair with:'
        Invoke-PairingJoin -Chosen (Select-PairingMachine -Machines $sponsors -Prompt '    Machine')
    }
    exit 0
}

if (-not (Read-PairingYesNo -Prompt '    Share and resume sessions across machines?' -Default $true)) {
    Save-BridgeFleetMembership -ConfigPath $configPath -Share $false
    Write-Host '    sharing is off'
    exit 0
}

# A machine that already holds a secret - set up by hand before pairing existed - only
# needs a fleet id to start sponsoring others. It is derived from that secret rather
# than drawn at random, because an upgrade runs configure on every machine: a random id
# on each left machines that already share one secret advertising unrelated fleets, so
# a joiner was offered several one-machine fleets and a rotation had nobody to re-pair.
if ($membership.HasSecret) {
    $fleet = Save-BridgeFleetIdForHeldSecret -ConfigPath $configPath -Share
    Write-Host "    using the fleet secret already on this machine; fleet $($fleet.Substring(0, 8))"
    Write-Host '    sharing is on'
    exit 0
}

$sponsors = @(Get-PairingSponsorsOrNone)
if ($sponsors.Count -eq 0) {
    # Not finding a sponsor does not make this the first machine: the members may all be
    # offline, and an untrusted broker can suppress their status. So a new fleet is only
    # ever an explicit choice, and skipping is the default.
    Write-Host '    No machine already in a fleet is online.'
    Write-Host '      P) paste the secret from a machine in the fleet'
    Write-Host '      NEW) start a new fleet with this machine - only if no fleet exists yet'
    Write-Host '      S) skip for now'
    $choice = (Read-PairingAnswer -Prompt '    Choose' -Default 'S').ToUpperInvariant()
}
else {
    Write-Host '    Machines that can let this one in:'
    for ($i = 0; $i -lt $sponsors.Count; $i++) {
        Write-Host ("      {0}) {1,-20} fleet {2}" -f ($i + 1), $sponsors[$i].Machine, $sponsors[$i].FleetId.Substring(0, 8))
    }
    Write-Host '      P) paste the secret instead'
    Write-Host '      S) skip for now'
    $choice = (Read-PairingAnswer -Prompt '    Pair with' -Default '1').ToUpperInvariant()
}

switch -Regex ($choice) {
    '^S$' { Write-Host '    skipped; run agent-ha-bridge pair later'; exit 0 }
    '^NEW$' {
        if ($sponsors.Count -gt 0) { throw 'there is already a fleet online; pair with it rather than starting another' }
        $fleet = New-BridgePairingId
        Save-BridgeFleetMembership -ConfigPath $configPath -Secret (New-BridgeFleetSecret) -FleetId $fleet -Share $true
        Write-Host "    started fleet $($fleet.Substring(0, 8)); add other machines with agent-ha-bridge pair on each"
        exit 0
    }
    '^P$' { Invoke-PairingPaste; exit 0 }
    '^\d+$' {
        $index = [int]$choice - 1
        if ($index -lt 0 -or $index -ge $sponsors.Count) { throw "there is no machine $choice" }
        Invoke-PairingJoin -Chosen $sponsors[$index]
        exit 0
    }
    default { throw "'$choice' is not one of the choices" }
}
