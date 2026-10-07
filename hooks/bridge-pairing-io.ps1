<#
    Pairing, the half that talks to Home Assistant: the helper, the topics, the
    sponsor's daemon hook, the joiner's flow, and saving the result.

    The cryptography and the protocol steps are in bridge-pairing.ps1 and are pure;
    everything here only moves their messages and stores their outcome. No parameters
    are declared at file scope, so the daemon can dot-source this safely.
#>

$script:BridgePairingHelperId = 'agent_bridge_pairing'
$script:BridgePairingHelperEntity = 'input_text.agent_bridge_pairing'
$script:BridgePairingHelperName = 'Agent Bridge Pairing'
$script:BridgePairingHelperDisplayName = 'Pair a machine'
# How long the person has to type the code, and how long a sponsor waits for the reveal.
$script:BridgePairingCodeSeconds = 300
$script:BridgePairingRevealSeconds = 120
# Three refused codes lock pairing on a sponsor for this long.
$script:BridgePairingLockMinutes = 15
$script:BridgePairingLockRefusals = 3
# The attempt this daemon last started a sponsor for, so one request starts one process.
if (-not (Test-Path variable:script:DaemonPairingAttempt)) { $script:DaemonPairingAttempt = '' }
# And the process it started, so a sponsor that died can be told from one still waiting
# for a person. Kept beside the attempt because the two are only meaningful together.
if (-not (Test-Path variable:script:DaemonPairingSponsor)) { $script:DaemonPairingSponsor = $null }

# ---------------------------------------------------------------------- the helper

function Initialize-BridgePairingHelper {
    <#
        Makes sure input_text.agent_bridge_pairing exists and has a state.

        Called only when a person chooses to pair - `agent-ha-bridge pair`, or the
        sharing step in configure - and never by a daemon. A daemon that created it at
        startup recreated a helper somebody had deleted on purpose; this way a deleted
        helper stays deleted until somebody deliberately pairs again. An existing helper
        is left exactly as it is: one the person renamed keeps its name. Created over the
        WebSocket collection API with the administrator token. Returns $true when the
        helper exists afterwards.

        Storage is not the state machine. A helper can be in the collection and in the
        entity registry a moment before its state appears, and the very next thing
        pairing does is read that state - so returning as soon as the create succeeded
        made a first-ever pairing fail with "the helper is missing" until the person ran
        it a second time. Waited for here, the same way the Detailed activity switch
        waits, rather than left for the caller to discover.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    try {
        $existing = (Invoke-CopilotHaWebSocket -Commands @(@{ type = 'input_text/list' }))[0]
        if (-not (@($existing) | Where-Object { [string]$_.id -eq $script:BridgePairingHelperId })) {
            $created = (Invoke-CopilotHaWebSocket -Commands @(@{
                    type = 'input_text/create'; name = $script:BridgePairingHelperName
                    icon = 'mdi:handshake-outline'; min = 0; max = 255; mode = 'text'
                }))[0]
            if ([string]$created.id -ne $script:BridgePairingHelperId) {
                Write-Warning "The pairing helper came back as '$($created.id)', expected '$($script:BridgePairingHelperId)'."
                return $false
            }
            try {
                [void](Invoke-CopilotHaWebSocket -Commands @(@{
                        type = 'config/entity_registry/update'; entity_id = $script:BridgePairingHelperEntity
                        name = $script:BridgePairingHelperDisplayName
                    }))
            }
            catch { if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw } }
        }
        # Read through the same path pairing itself uses, so "ready" means the thing
        # pairing is about to do actually works. '' is a helper that is simply empty,
        # which is its normal resting state; only $null is "cannot be read".
        foreach ($attempt in 1..5) {
            if ($null -ne (Get-BridgePairingHelperValue -Headers $Headers)) { return $true }
            Start-Sleep -Milliseconds 800
        }
        Write-Warning "The pairing helper '$($script:BridgePairingHelperEntity)' has no state yet."
        $false
    }
    catch {
        if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
        $false
    }
}

function Get-BridgePairingHelperValue {
    <#
        What the helper holds: '' when it is empty or has no state yet, $null when it
        does not exist or cannot be read. Read through Home Assistant's REST API, never
        MQTT, because that is the whole reason the helper is trusted.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)
    try {
        $state = Get-HomeAssistantState -EntityId $script:BridgePairingHelperEntity -Headers $Headers
        $value = [string]$state.state
        if ($value -in @('unknown', 'unavailable')) { return '' }
        $value
    }
    catch {
        # An Offline suite that fails to mock this read reaches the transport guard, and
        # reading that as "no helper" turned a forbidden request to a real Home Assistant
        # into a quiet 'idle' from Invoke-DaemonPairingRequest - the guard violation then
        # looked exactly like a machine with nothing to do.
        if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
        $null
    }
}

function Set-BridgePairingHelperValue {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value, [Parameter(Mandatory)][hashtable]$Headers)
    Invoke-HomeAssistantService -Domain 'input_text' -Service 'set_value' -Headers $Headers `
        -Data @{ entity_id = $script:BridgePairingHelperEntity; value = $Value }
}

# ----------------------------------------------------------------- fleet settings

function Get-BridgeFleetId {
    [string](Get-BridgeSetting 'newSession.fleetId' '')
}

function Get-BridgeFleetMembership {
    <# Whether this machine can sponsor: it holds a secret and a fleet id. #>
    $secret = Get-BridgeTransferSecret
    $fleet = Get-BridgeFleetId
    [pscustomobject]@{
        Member = (-not [string]::IsNullOrEmpty($secret)) -and ($fleet -match '^[0-9a-f]{32}$')
        FleetId = $fleet
        HasSecret = -not [string]::IsNullOrEmpty($secret)
    }
}

function Save-BridgeFleetMembership {
    <#
        Writes the fleet settings into the bridge config, leaving everything else in it
        as it was, and keeps the file protected. -Secret and -FleetId are optional so the
        sharing flags can be changed on their own.
    #>
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [AllowEmptyString()][string]$Secret,
        [AllowEmptyString()][string]$FleetId,
        [Nullable[bool]]$Share
    )
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $config.PSObject.Properties['newSession'] -or $null -eq $config.newSession) {
        $config | Add-Member -NotePropertyName newSession -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $section = $config.newSession
    $set = { param($name, $value) $section | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }
    if ($PSBoundParameters.ContainsKey('Secret')) { & $set 'transferSecret' $Secret }
    if ($PSBoundParameters.ContainsKey('FleetId')) { & $set 'fleetId' $FleetId }
    if ($null -ne $Share) {
        & $set 'shareResumable' ([bool]$Share)
        & $set 'transferResumable' ([bool]$Share)
    }
    Write-BridgeSecretFile -Path $ConfigPath -Content ($config | ConvertTo-Json -Depth 32)
}

function Save-BridgeFleetIdForHeldSecret {
    <#
        Settles the fleet id of a machine that already holds a fleet secret but has no
        fleet id - an installation from before pairing existed, where the secret was
        copied from machine to machine by hand. Returns the id it saved.

        The id comes from the secret, so every machine holding that same secret settles
        on the same fleet without any of them having to go first. Drawing a random one
        as each machine ran configure split a fleet that already shared membership into
        one-machine fleets, and sponsor selection, rotation and re-pairing all work on
        the fleet id.
    #>
    param([Parameter(Mandatory)][string]$ConfigPath, [switch]$Share)

    $secret = Get-BridgeTransferSecret
    if ([string]::IsNullOrEmpty($secret)) { throw 'this machine holds no fleet secret to take a fleet id from' }
    $fleet = Get-BridgeFleetIdFromSecret -Secret $secret
    Save-BridgeFleetMembership -ConfigPath $ConfigPath -FleetId $fleet -Share ([bool]$Share)
    $fleet
}

function Get-BridgePairingSponsors {
    <# Online machines, other than this one, that advertise a fleet and so can sponsor. #>
    param([Parameter(Mandatory)][hashtable]$Headers, [AllowNull()][object[]]$States)
    $peers = if ($PSBoundParameters.ContainsKey('States')) { @(Get-BridgePeerMachine -Headers $Headers -ExcludeSelf -States $States) }
             else { @(Get-BridgePeerMachine -Headers $Headers -ExcludeSelf) }
    @($peers | Where-Object {
            $_.Online -and $null -ne $_.Capabilities -and $_.Capabilities.PSObject.Properties['fleet'] -and
            ([string]$_.Capabilities.fleet) -match '^[0-9a-f]{32}$'
        } | ForEach-Object {
            [pscustomobject]@{ Machine = $_.Machine; Slug = $_.Slug; FleetId = [string]$_.Capabilities.fleet }
        })
}

function Get-BridgePairingTopic {
    param([Parameter(Mandatory)][string]$Attempt, [Parameter(Mandatory)][ValidateSet('joiner', 'sponsor')][string]$To)
    "agent_bridge/pairing/$Attempt/to-$To"
}

function Send-BridgePairingMessage {
    <# Never retained: nothing in the exchange should outlive it, and no entity is bound to these topics. #>
    param([Parameter(Mandatory)][string]$Topic, [Parameter(Mandatory)]$Message, [Parameter(Mandatory)][hashtable]$Headers)
    Publish-CopilotMqttMessage -Topic $Topic -Payload ($Message | ConvertTo-Json -Depth 4 -Compress) -Headers $Headers
}

# -------------------------------------------------------------- lockout bookkeeping

function Get-BridgePairingRefusalPath { Get-BridgeRuntimePath -Name 'agent-bridge-pairing-refusals.json' }

function Test-BridgePairingLocked {
    <# Whether this sponsor has refused enough codes recently to stop taking new attempts. #>
    param([DateTimeOffset]$Now = [DateTimeOffset]::Now)
    $path = Get-BridgePairingRefusalPath
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $recent = @()
    try {
        $recent = @((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) | ForEach-Object { [DateTimeOffset]::Parse([string]$_) } |
                Where-Object { ($Now - $_).TotalMinutes -lt $script:BridgePairingLockMinutes })
    }
    catch { return $true }   # an unreadable record fails closed
    $recent.Count -ge $script:BridgePairingLockRefusals
}

function Add-BridgePairingRefusal {
    param([DateTimeOffset]$Now = [DateTimeOffset]::Now)
    $path = Get-BridgePairingRefusalPath
    $kept = @()
    if (Test-Path -LiteralPath $path) {
        try {
            $kept = @((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) | Where-Object {
                    ($Now - [DateTimeOffset]::Parse([string]$_)).TotalMinutes -lt $script:BridgePairingLockMinutes })
        }
        catch { $kept = @() }
    }
    ConvertTo-Json -InputObject @($kept + $Now.ToString('o')) -Compress | Set-Content -LiteralPath $path -Encoding utf8
}

# ------------------------------------------------------------- the sponsor's daemon

function Get-BridgePairingCheckTag {
    <# The answer to a pasted secret's check: proves the sponsor holds the same secret, and reveals nothing about it. #>
    param([Parameter(Mandatory)][string]$Secret, [Parameter(Mandatory)][string]$Nonce)
    $mac = [Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($Secret))
    try { (ConvertTo-BridgePairingHex -Bytes $mac.ComputeHash((ConvertTo-BridgePairingFrame -Values @('check', $Nonce)))).Substring(0, 32) }
    finally { $mac.Dispose() }
}

function Invoke-DaemonPairingRequest {
    <#
        One reconcile's look at the helper. A pairing request for this machine starts a
        sponsor process - it waits minutes for a person, so it cannot run in the loop -
        and a check of a pasted secret is answered on the spot.

        Returns what it did, for the log and for tests.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers, [scriptblock]$StartSponsor)

    $value = Get-BridgePairingHelperValue -Headers $Headers
    if ([string]::IsNullOrEmpty($value)) { return 'idle' }
    $slug = Get-BridgeMachineSlug
    $membership = Get-BridgeFleetMembership

    if ($value -match "^check:$([regex]::Escape($slug)):([0-9a-f]{32})$") {
        if (-not $membership.HasSecret) { return 'no-secret' }
        $nonce = $Matches[1]
        Set-BridgePairingHelperValue -Headers $Headers -Value "checked:${slug}:${nonce}:$(Get-BridgePairingCheckTag -Secret (Get-BridgeTransferSecret) -Nonce $nonce)"
        return 'checked'
    }

    $request = ConvertFrom-BridgePairingRequest -Value $value
    if ($null -eq $request -or $request.SponsorSlug -cne $slug) { return 'not-ours' }
    if (-not $membership.Member) { return 'not-a-member' }
    if ($request.FleetId -cne $membership.FleetId) { return 'other-fleet' }
    if ($script:DaemonPairingAttempt -ceq $request.Attempt) {
        # A sponsor that is gone cannot still be running. Start-Process only establishes
        # that pwsh was created: an entry point missing mid-update, or a failure during
        # initialisation, exits straight away, and the attempt stayed recorded so every
        # later pass answered 'running' for nothing at all while the joiner waited out
        # its whole timeout. Reaching here means the request is still in the helper, so
        # the sponsor never answered it, whatever it exited with.
        if (-not (Test-BridgePairingSponsorGone -Process $script:DaemonPairingSponsor)) { return 'running' }
        $script:DaemonPairingAttempt = ''
        $script:DaemonPairingSponsor = $null
    }
    if (Test-BridgePairingLocked) {
        $script:DaemonPairingAttempt = $request.Attempt
        Set-BridgePairingHelperValue -Headers $Headers -Value "refused:$($request.Joiner)"
        return 'locked'
    }
    if (-not $StartSponsor) {
        $StartSponsor = {
            param($Attempt)
            $entry = Join-Path $PSScriptRoot 'bridge-pairing-entry.ps1'
            $start = @{ FilePath = (Get-BridgePwshPath); ArgumentList = @('-NoProfile', '-NonInteractive', '-File', $entry, '-Sponsor', '-Attempt', $Attempt) }
            if ($script:BridgeIsWindows) { $start.WindowStyle = 'Hidden' }
            # Handed back, not discarded, so a child that dies can be told from one that
            # is waiting for a person.
            Start-Process @start -PassThru
        }
    }
    # Recorded only once the process has started. Recorded before, a start that threw -
    # a transient resource error, an entry point missing mid-update - left every later
    # pass answering 'running' for a sponsor that did not exist, and the joiner waited
    # out its whole timeout.
    $sponsor = & $StartSponsor $request.Attempt
    $script:DaemonPairingSponsor = $sponsor
    $script:DaemonPairingAttempt = $request.Attempt
    'started'
}

function Test-BridgePairingSponsorGone {
    <#
        Whether a started sponsor has determinately exited.

        Only "yes, it has gone" releases the attempt. Nothing to look at - a caller that
        hands back no process, which is every test that supplies its own starter - and a
        process that cannot be asked both mean nobody can tell, and the attempt stays
        recorded: starting a second sponsor for a joiner that already has one is worse
        than waiting, because both would race to answer the same pairing.
    #>
    param([AllowNull()]$Process)

    if ($null -eq $Process) { return $false }
    try {
        if (-not $Process.PSObject.Properties['HasExited']) { return $false }
        [bool]$Process.HasExited
    }
    catch {
        if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw }
        $false
    }
}

function Invoke-BridgePairingSponsor {
    <#
        The sponsor's whole attempt, run in its own process. Returns the outcome:
        'accepted', 'refused', or why it gave up.
    #>
    param([Parameter(Mandatory)][string]$Attempt, [Parameter(Mandatory)][hashtable]$Headers)

    $value = Get-BridgePairingHelperValue -Headers $Headers
    $request = ConvertFrom-BridgePairingRequest -Value $value
    if ($null -eq $request -or $request.Attempt -cne $Attempt) { return 'request-gone' }
    $membership = Get-BridgeFleetMembership
    $started = New-BridgePairingSponsor -Request $request -FleetId $membership.FleetId `
        -Sponsor ([Environment]::MachineName) -SponsorSlug (Get-BridgeMachineSlug)
    $state = $started.State
    try {
        # The callbacks below are plain script blocks, deliberately not closures: they
        # run inside Read-BridgeHaMqttSubscription and find $ctx, $state and the
        # functions they call through the call stack, which works whether this file was
        # dot-sourced into the daemon or into a standalone process. A closure binds to a
        # module of its own, where the daemon's dot-sourced functions cannot be seen.
        $ctx = @{ Reveal = $null }
        $toSponsor = Get-BridgePairingTopic -Attempt $Attempt -To 'sponsor'
        $toJoiner = Get-BridgePairingTopic -Attempt $Attempt -To 'joiner'
        $offer = $started.Offer
        [void](Read-BridgeHaMqttSubscription -Topic $toSponsor -TimeoutSeconds $script:BridgePairingRevealSeconds `
                -OnReady { Send-BridgePairingMessage -Topic $toJoiner -Message $offer -Headers $Headers } `
                -Until {
                param($messages)
                foreach ($m in @($messages)) {
                    if ($m.PSObject.Properties['type'] -and [string]$m.type -ceq 'reveal' -and [string]$m.attempt -ceq $Attempt) {
                        $ctx.Reveal = $m; return $true
                    }
                }
                $false
            })
        if ($null -eq $ctx.Reveal) { return 'no-reveal' }
        Receive-BridgePairingReveal -State $state -Message $ctx.Reveal

        # Wait for the person. Anything other than our own request or a typed code
        # means someone else is using the helper, and this attempt stands down.
        $deadline = [DateTimeOffset]::Now.AddSeconds($script:BridgePairingCodeSeconds)
        $typed = $null
        while ([DateTimeOffset]::Now -lt $deadline) {
            $now = Get-BridgePairingHelperValue -Headers $Headers
            if ($null -eq $now) { return 'helper-gone' }
            if ($now -cne $value) {
                if ((ConvertTo-BridgePairingTypedCode -Typed $now) -match '^\d{6}$') { $typed = $now; break }
                return 'helper-taken'
            }
            Start-Sleep -Seconds 2
        }
        if ($null -eq $typed) {
            if ((Get-BridgePairingHelperValue -Headers $Headers) -ceq $value) { Set-BridgePairingHelperValue -Headers $Headers -Value '' }
            return 'timed-out'
        }

        $verdict = Resolve-BridgePairingCode -State $state -Typed $typed -Secret (Get-BridgeTransferSecret)
        Set-BridgePairingHelperValue -Headers $Headers -Value $verdict.Helper
        if (-not $verdict.Accepted) { Add-BridgePairingRefusal; return 'refused' }
        Send-BridgePairingMessage -Topic $toJoiner -Message $verdict.Message -Headers $Headers
        'accepted'
    }
    finally { Close-BridgePairingState -State $state }
}

# ---------------------------------------------------------------------- the joiner

function Invoke-BridgePairingJoin {
    <#
        Joins this machine to the sponsor's fleet. Shows the code through -ShowCode,
        and returns { Secret; FleetId } or throws with the reason.
    #>
    param(
        [Parameter(Mandatory)]$Sponsor,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][scriptblock]$ShowCode,
        [int]$TimeoutSeconds = ($script:BridgePairingCodeSeconds + 60)
    )

    $current = Get-BridgePairingHelperValue -Headers $Headers
    if ($null -eq $current) { throw 'the Pair a machine helper is missing from Home Assistant; restart the bridge on a machine already in the fleet to create it' }
    if (-not [string]::IsNullOrEmpty($current)) { throw 'another pairing is in progress - wait for it to finish, or clear the Pair a machine helper' }

    $state = New-BridgePairingJoiner -FleetId $Sponsor.FleetId -Joiner ([Environment]::MachineName) `
        -Sponsor $Sponsor.Machine -SponsorSlug $Sponsor.Slug
    try {
        $toJoiner = Get-BridgePairingTopic -Attempt $state.Attempt -To 'joiner'
        $toSponsor = Get-BridgePairingTopic -Attempt $state.Attempt -To 'sponsor'
        $ctx = @{ Secret = $null; Error = $null; Seen = 0 }
        $request = $state.Request
        [void](Read-BridgeHaMqttSubscription -Topic $toJoiner -TimeoutSeconds $TimeoutSeconds `
                -OnReady { Set-BridgePairingHelperValue -Headers $Headers -Value $request } `
                -Until {
                param($messages)
                $all = @($messages)
                for ($i = $ctx.Seen; $i -lt $all.Count; $i++) {
                    $m = $all[$i]
                    if (-not $m.PSObject.Properties['type']) { continue }
                    try {
                        if ([string]$m.type -ceq 'offer' -and $state.Phase -ceq 'committed') {
                            $reveal = Receive-BridgePairingOffer -State $state -Message $m
                            Send-BridgePairingMessage -Topic $toSponsor -Message $reveal -Headers $Headers
                            & $ShowCode $state.Code
                        }
                        elseif ([string]$m.type -ceq 'secret' -and $state.Phase -ceq 'revealed') {
                            $ctx.Secret = $m
                            $ctx.Seen = $i + 1
                            return $true
                        }
                    }
                    catch { $ctx.Error = $_.Exception.Message; return $true }
                }
                $ctx.Seen = $all.Count
                $false
            })

        if ($ctx.Error) { throw $ctx.Error }
        $helper = Get-BridgePairingHelperValue -Headers $Headers
        if ($null -eq $ctx.Secret) {
            if ([string]$helper -ceq "refused:$($state.Joiner)") { throw "$($Sponsor.Machine) refused the code" }
            if ($state.Phase -ceq 'committed') { throw "$($Sponsor.Machine) did not answer - is its bridge running and up to date?" }
            throw 'no code was entered in time'
        }
        $secret = Complete-BridgePairingJoin -State $state -HelperValue $helper -Message $ctx.Secret
        [pscustomobject]@{ Secret = $secret; FleetId = $Sponsor.FleetId }
    }
    finally {
        # Whatever happened, our request does not stay in the helper.
        $refused = $null
        try {
            $left = Get-BridgePairingHelperValue -Headers $Headers
            if ($left -ceq $state.Request -or $left -like "accepted:$($state.Joiner):*" -or $left -ceq "refused:$($state.Joiner)") {
                Set-BridgePairingHelperValue -Headers $Headers -Value ''
            }
        }
        catch {
            # A tidy-up that cannot reach Home Assistant is not worth failing a join
            # over - but a transport the Offline guard refused is not a failed tidy-up,
            # and swallowing it here would let the join report success. Held back until
            # the ephemeral key has been disposed of: a guard violation is no reason to
            # leave that and the session key behind.
            if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { $refused = $_ }
        }
        Close-BridgePairingState -State $state
        if ($refused) { throw $refused }
    }
}

function Test-BridgeFleetSecretWithMember {
    <#
        Checks a pasted secret against a member before it is saved: the member answers a
        fresh nonce with an HMAC under its own secret. Returns $true only on a match.
    #>
    param([Parameter(Mandatory)][string]$Secret, [Parameter(Mandatory)]$Member, [Parameter(Mandatory)][hashtable]$Headers, [int]$TimeoutSeconds = 60)
    $current = Get-BridgePairingHelperValue -Headers $Headers
    if ($null -eq $current) { throw 'the Pair a machine helper is missing from Home Assistant' }
    if (-not [string]::IsNullOrEmpty($current)) { throw 'another pairing is in progress' }
    $nonce = New-BridgePairingId
    Set-BridgePairingHelperValue -Headers $Headers -Value "check:$($Member.Slug):$nonce"
    try {
        $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
        while ([DateTimeOffset]::Now -lt $deadline) {
            $v = Get-BridgePairingHelperValue -Headers $Headers
            if ([string]$v -match "^checked:$([regex]::Escape($Member.Slug)):${nonce}:([0-9a-f]{32})$") {
                return Test-BridgePairingEqual -A $Matches[1] -B (Get-BridgePairingCheckTag -Secret $Secret -Nonce $nonce)
            }
            Start-Sleep -Seconds 2
        }
        throw "$($Member.Machine) did not answer the check"
    }
    finally {
        try {
            $left = Get-BridgePairingHelperValue -Headers $Headers
            if ($left -like "check:$($Member.Slug):$nonce" -or $left -like "checked:$($Member.Slug):${nonce}:*") { Set-BridgePairingHelperValue -Headers $Headers -Value '' }
        }
        catch { if (Test-BridgeObservationGuardFailure -ErrorRecord $_) { throw } }
    }
}
