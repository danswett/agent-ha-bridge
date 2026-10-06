<#
    The entry point for pairing, as its own process:

      -Sponsor -Attempt <id>   started by the daemon when the helper holds a request for
                               this machine; runs the sponsor's side and exits.
      -Configure               the interactive "Session sharing" step, run by
                               install.ps1 once it has written the config, and by
                               `agent-ha-bridge pair`.
      -Show                    prints this machine's fleet secret, for the paste fallback.

    Kept apart from the libraries because dot-sourcing a script rebinds every parameter
    it declares; nothing else dot-sources this file.
#>
[CmdletBinding()]
param(
    [switch]$Sponsor,
    [ValidatePattern('^[0-9a-f]{32}$')][string]$Attempt,
    [switch]$Configure,
    [switch]$Show
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
    Write-Host ''
    exit 0
}

if (-not $Configure) { throw 'Pass -Configure, -Sponsor or -Show.' }

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
    exit 0
}

if (-not (Read-PairingYesNo -Prompt '    Share and resume sessions across machines?' -Default $true)) {
    Save-BridgeFleetMembership -ConfigPath $configPath -Share $false
    Write-Host '    sharing is off'
    exit 0
}

# A machine that already holds a secret - set up by hand before pairing existed - only
# needs a fleet id to start sponsoring others.
if ($membership.HasSecret) {
    $fleet = New-BridgePairingId
    Save-BridgeFleetMembership -ConfigPath $configPath -FleetId $fleet -Share $true
    Write-Host "    using the fleet secret already on this machine; fleet $($fleet.Substring(0, 8))"
    Write-Host '    sharing is on'
    exit 0
}

$sponsors = @(Get-BridgePairingSponsors -Headers $headers)
$choice = ''
if ($sponsors.Count -eq 0) {
    Write-Host '    No machine already in a fleet is online.'
    Write-Host '      N) start a new fleet with this machine'
    Write-Host '      P) paste the secret from another machine'
    Write-Host '      S) skip for now'
    $choice = (Read-PairingAnswer -Prompt '    Choose' -Default 'N').ToUpperInvariant()
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
    '^S$' {
        Write-Host '    skipped; run agent-ha-bridge pair later'
        exit 0
    }
    '^N$' {
        if ($sponsors.Count -gt 0) { throw 'there is already a fleet online; pair with it rather than starting another' }
        $fleet = New-BridgePairingId
        Save-BridgeFleetMembership -ConfigPath $configPath -Secret (New-BridgeFleetSecret) -FleetId $fleet -Share $true
        Write-Host "    started fleet $($fleet.Substring(0, 8)); add other machines with agent-ha-bridge pair on each"
        exit 0
    }
    '^P$' {
        $pasted = Read-BridgeSecret -Prompt '    Paste the fleet secret (from agent-ha-bridge secret show)'
        if ([string]::IsNullOrWhiteSpace($pasted)) { Write-Host '    nothing pasted; skipped'; exit 0 }
        $pasted = $pasted.Trim()
        $members = @(Get-BridgePairingSponsors -Headers $headers)
        if ($members.Count -eq 0) { throw 'no machine in a fleet is online to check the secret against' }
        $member = $members[0]
        if (-not (Test-BridgeFleetSecretWithMember -Secret $pasted -Member $member -Headers $headers)) {
            throw "that is not $($member.Machine)'s fleet secret - nothing was saved"
        }
        Save-BridgeFleetMembership -ConfigPath $configPath -Secret $pasted -FleetId $member.FleetId -Share $true
        Write-Host "    checked against $($member.Machine) and saved; sharing is on"
        exit 0
    }
    '^\d+$' {
        $index = [int]$choice - 1
        if ($index -lt 0 -or $index -ge $sponsors.Count) { throw "there is no machine $choice" }
        $chosen = $sponsors[$index]
        Write-Host "    asking $($chosen.Machine)..."
        $result = Invoke-BridgePairingJoin -Sponsor $chosen -Headers $headers -ShowCode {
            param($code)
            Write-Host ''
            Write-Host '    In Home Assistant, type this code into "Pair a machine"' -ForegroundColor Yellow
            Write-Host '    (Settings > Devices & services > Helpers, or the entity on any dashboard):' -ForegroundColor Yellow
            Write-Host ''
            Write-Host "        $($code.Substring(0, 3)) $($code.Substring(3))" -ForegroundColor Green
            Write-Host ''
            Write-Host "    Waiting for $($chosen.Machine)..."
        }
        Save-BridgeFleetMembership -ConfigPath $configPath -Secret $result.Secret -FleetId $result.FleetId -Share $true
        Write-Host "    paired with $($chosen.Machine); sharing is on" -ForegroundColor Green
        exit 0
    }
    default { throw "'$choice' is not one of the choices" }
}
