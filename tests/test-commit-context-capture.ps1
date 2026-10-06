#Requires -Version 7.0
<#
.SYNOPSIS
    Measures whether an optimistic MQTT text.set_value commit binds its committed value to
    an authenticated caller context, against a disposable GitHub-hosted Home Assistant Core
    2026.9.4 + Mosquitto fixture. Neutral as to outcome.

.DESCRIPTION
    PR76's question-bound submission proposes an optimistic MQTT text entity (command_topic,
    no state_topic) whose text.set_value carries {SubmitId, digest}. Whether that path
    delivers the committed value WITH an authenticated caller (context.user_id) is
    UNMEASURED - the reply-payload measurement in hooks/daemon-replies.ps1 is a SENSOR with a
    state_topic, a different entity type, so it answers neither way. This harness measures the
    exact optimistic text path and classifies the result without presuming it.

    Two modes:
      -Mode SelfTest  (default) Pure, offline unit validation of the decision functions:
                      per-locus context classification, case-outcome determination, the
                      evidence projection builder, principal validation, the cleanup plan and
                      the image-pin check. No HA, no Docker, no network. NOT a measurement.
      -Mode Measure   The disposable measurement. Runs ONLY inside an ephemeral GitHub-hosted
                      runner it owns, after a preflight that refuses developer / self-hosted /
                      live / non-loopback targets before any network or container effect, and
                      after the supplied image refs are verified against the reviewed immutable
                      digests. It starts the pinned fixture on a dedicated network, onboards HA,
                      creates two validated synthetic principals, resolves the per-run entity by
                      its unique_id in the registry, runs bounded commit cases, and disposes
                      only the resources it created.

    Self-contained: never dot-sources installed bridge helpers under ~/.agent-ha-bridge, never
    reads live configuration, never reads the user's token.

    The value, new_state.context, event.context, the service result and the raw command-topic
    payload are kept as SEPARATE observations; a positive actor result is not required for the
    harness to be valid, and a missed/broken observation is never reported as a measured
    absence.
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Measure')][string]$Mode = 'SelfTest',
    # Immutable image references, supplied by the workflow and verified against the reviewed
    # digests below before any effect.
    [string]$HaImage,
    [string]$MosquittoImage,
    [ValidateRange(1, 16)][int]$MaxCommits = 16,
    [ValidateRange(1, 60)][int]$HandshakeTimeoutSeconds = 15,
    [ValidateRange(1, 60)][int]$ObservationTimeoutSeconds = 15,
    [ValidateRange(30, 600)][int]$JobTimeoutSeconds = 600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The reviewed immutable digests. The pinned refs the workflow passes must match these, or the
# run refuses before any effect: a tag or a drifted digest is not the reviewed instance.
$script:ReviewedHaDigest = 'sha256:3e6710a7ab2a61311d9d899b719f6c3657791c63e8f4942cec4ebc42401d6b76'
$script:ReviewedMosquittoDigest = 'sha256:199ea8ef2e35ec2b1b37e59cfd1dbae538ed4dfa4a2251a121a52215a6248a21'
$script:ReviewedHaVersion = '2026.9.4'

# ----------------------------------------------------------------------------------------
# Pure helpers. -Mode SelfTest validates every one of these offline; none may touch Home
# Assistant, Docker or the network.
# ----------------------------------------------------------------------------------------

function Get-CaptureProp {
    # Strict-mode-safe read: a missing property or key returns $null rather than throwing, so
    # classification stays total over partial observations.
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-CommitValueDigest {
    # Full SHA-256 of the exact value bytes; never truncated.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) | ForEach-Object { $_.ToString('x2') })) }
    finally { $sha.Dispose() }
}

function New-CaptureNonce {
    # Unpredictable, entity-id and topic safe, unique per run: two runs never share a
    # namespace, so one run can never clean up or collide with another's objects.
    return ([guid]::NewGuid().ToString('N')).Substring(0, 12)
}

function Test-ImagePinned {
    # An image ref is acceptable only if it is digest-pinned and, when an expected digest is
    # given, matches it exactly. A tag, or a different digest, is refused.
    param([AllowEmptyString()][string]$ImageRef, [AllowEmptyString()][string]$ExpectedDigest)
    if ($ImageRef -notmatch '@sha256:[0-9a-f]{64}$') { return $false }
    if ([string]::IsNullOrWhiteSpace($ExpectedDigest)) { return $true }
    return ($ImageRef.EndsWith("@$ExpectedDigest", [StringComparison]::Ordinal))
}

function Test-DisposableTargetAllowed {
    # Target-refusal contract. Returns an object, never throws, so SelfTest can drive it with
    # synthetic inputs. Measure calls it before any effect and aborts on Allowed=$false.
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][AllowEmptyString()][string]$HaBaseUrl,
        [Parameter(Mandatory)][AllowEmptyString()][string]$BrokerHost,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Nonce
    )
    $deny = { param($Reason) [pscustomobject]@{ Allowed = $false; Reason = $Reason } }
    $get = { param($Key) if ($Environment.ContainsKey($Key)) { [string]$Environment[$Key] } else { '' } }
    if ((& $get 'GITHUB_ACTIONS') -cne 'true') { return (& $deny 'GITHUB_ACTIONS is not "true"; refusing a non-Actions host') }
    if ((& $get 'RUNNER_ENVIRONMENT') -cne 'github-hosted') { return (& $deny "RUNNER_ENVIRONMENT is '$(& $get 'RUNNER_ENVIRONMENT')', not 'github-hosted'; refusing self-hosted/unknown") }
    if ([string]::IsNullOrWhiteSpace($Nonce)) { return (& $deny 'no per-run fixture nonce; refusing an unscoped target') }
    $uri = $null
    if (-not [uri]::TryCreate($HaBaseUrl, [UriKind]::Absolute, [ref]$uri)) { return (& $deny "HA base URL is not absolute: '$HaBaseUrl'") }
    if ($uri.Scheme -notin @('http', 'https')) { return (& $deny "HA base URL scheme must be http(s): '$($uri.Scheme)'") }
    $loopback = @('127.0.0.1', 'localhost', '::1')
    if ($uri.Host -notin $loopback) { return (& $deny "HA host is not loopback: '$($uri.Host)'") }
    if ($BrokerHost -notmatch '^[A-Za-z0-9_.-]+$') { return (& $deny "broker host has unexpected characters: '$BrokerHost'") }
    if ($BrokerHost -notin $loopback -and $BrokerHost -notlike "*$Nonce*") { return (& $deny "broker host is neither loopback nor this run's nonce fixture: '$BrokerHost'") }
    return [pscustomobject]@{ Allowed = $true; Reason = 'github-hosted runner; loopback/owned HA target; nonce present' }
}

function Get-ContextLocusClassification {
    # Classify ONE context locus (new_state.context OR event.context) against the expected
    # principal. The two loci are classified separately and never merged.
    param([AllowEmptyString()][string]$UserId, [AllowEmptyString()][string]$ExpectedUserId)
    if ([string]::IsNullOrWhiteSpace($UserId)) { return 'Absent' }
    if ($UserId -ceq $ExpectedUserId) { return 'Matched' }
    return 'Mismatched'
}

function Get-CommitCaseOutcome {
    # The case-level outcome, which distinguishes faults and stale/unmatched events from a
    # valid measured result. The per-locus context classes are reported alongside it (see
    # New-CommitCaseRecord) and are only meaningful when the outcome is 'Measured'.
    # SubscriberNotReady comes first: a commit withheld because the command-topic subscriber
    # never proved ready is NOT a measured service failure, and must not count toward a sound
    # inventory (see Get-RunCompletion).
    param([Parameter(Mandatory)]$Observation)
    if ([bool](Get-CaptureProp $Observation 'SubscriberNotReady')) { return 'SubscriberNotReady' }
    if (-not [string]::IsNullOrWhiteSpace([string](Get-CaptureProp $Observation 'ObservationError'))) { return 'ObservationError' }
    if (-not [bool](Get-CaptureProp $Observation 'ServiceAccepted')) { return 'ServiceFailed' }
    if (-not [bool](Get-CaptureProp $Observation 'StateObserved')) { return 'NoEvent' }
    $requested = [string](Get-CaptureProp $Observation 'RequestedValue')
    $observed = [string](Get-CaptureProp $Observation 'ObservedValue')
    if ($observed -cne $requested) { return 'ValueMismatch' }
    return 'Measured'
}

function Get-SubscriberReadiness {
    # Parse the OWNED mosquitto_sub -d transcript. In the pinned Mosquitto v2.0.22 client
    # (client/sub_client.c), my_log_callback prints every debug line with printf -> STDOUT, so
    # the handshake is on stdout, not stderr. my_subscribe_callback prints
    # "Subscribed (mid: N): Q[, Q...]" where a granted QoS < 128 is an allowed subscription and
    # 128 is a denial. Readiness therefore requires a successful CONNACK (reason code 0) AND at
    # least one granted (non-128) subscription; a bare CONNACK is NOT enough to receive a QoS0
    # command. Pure; SelfTested against these exact line formats.
    param([AllowNull()][AllowEmptyString()][string]$StdoutText)
    $connected = $false; $granted = $false; $rejected = $false
    if (-not [string]::IsNullOrEmpty($StdoutText)) {
        foreach ($line in ($StdoutText -split "`r?`n")) {
            if ($line -match 'received CONNACK \((\d+)\)') { if ([int]$Matches[1] -eq 0) { $connected = $true } }
            if ($line -match '^Subscribed \(mid: \d+\):\s*(.+)$') {
                $codes = @($Matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
                if (@($codes | Where-Object { $_ -lt 128 }).Count -gt 0) { $granted = $true }
                elseif ($codes.Count -gt 0) { $rejected = $true }
            }
        }
    }
    $state = if ($granted) { 'GrantedSubscription' } elseif ($rejected) { 'RejectedSubscription' } elseif ($connected) { 'ConnackOnly' } else { 'NoHandshake' }
    return [pscustomobject]@{ Connected = $connected; Granted = $granted; Rejected = $rejected; Ready = ($connected -and $granted); State = $state }
}

function Get-ObserverPayload {
    # Extract ONLY the nonce-bound payload emitted by mosquitto_sub -F "<Sentinel>%p" from a
    # stdout stream that also carries the -d debug transcript, so the transcript is never
    # hashed or reported as the committed value. The commit value is single-line compact JSON,
    # so the payload is the text from the sentinel to the next newline. Pure; SelfTested.
    param([AllowNull()][AllowEmptyString()][string]$StdoutText, [Parameter(Mandatory)][string]$Sentinel)
    if ([string]::IsNullOrEmpty($StdoutText)) { return $null }
    $idx = $StdoutText.IndexOf($Sentinel, [StringComparison]::Ordinal)
    if ($idx -lt 0) { return $null }
    $rest = $StdoutText.Substring($idx + $Sentinel.Length)
    $nl = $rest.IndexOfAny([char[]]@("`r", "`n"))
    if ($nl -ge 0) { $rest = $rest.Substring(0, $nl) }
    if ([string]::IsNullOrEmpty($rest)) { return $null }
    return $rest
}

function Get-ContainerTopology {
    # Pure projection of `docker inspect` output for ONE owned container: the actual id, its
    # running state, whether it is attached to the owned network, its host port bindings and
    # whether the image ref matches the pinned digest ref. A topology string is a claim; this
    # turns the inspected fixture into checkable facts. SelfTested with synthetic inspect JSON.
    param([AllowEmptyString()][string]$InspectJson, [Parameter(Mandatory)][string]$OwnedNetwork, [Parameter(Mandatory)][string]$ExpectedImageRef)
    $parsed = $null
    try { $parsed = $InspectJson | ConvertFrom-Json } catch { return [pscustomobject]@{ Ok = $false; Reason = 'inspect output is not valid JSON' } }
    $c = if ($parsed -is [array]) { $parsed[0] } else { $parsed }
    if ($null -eq $c) { return [pscustomobject]@{ Ok = $false; Reason = 'inspect output was empty' } }
    $id = [string](Get-CaptureProp $c 'Id')
    $running = [bool](Get-CaptureProp (Get-CaptureProp $c 'State') 'Running')
    $imageRef = [string](Get-CaptureProp (Get-CaptureProp $c 'Config') 'Image')
    $networkObj = Get-CaptureProp (Get-CaptureProp $c 'NetworkSettings') 'Networks'
    $networkNames = @(); if ($networkObj) { $networkNames = @($networkObj.PSObject.Properties.Name) }
    $portObj = Get-CaptureProp (Get-CaptureProp $c 'NetworkSettings') 'Ports'
    $hostBindings = @()
    if ($portObj) {
        foreach ($port in $portObj.PSObject.Properties) {
            foreach ($binding in @($port.Value)) {
                if ($null -ne $binding) { $hostBindings += ('{0}->{1}:{2}' -f $port.Name, [string](Get-CaptureProp $binding 'HostIp'), [string](Get-CaptureProp $binding 'HostPort')) }
            }
        }
    }
    return [pscustomobject]@{
        Ok = $true; Id = $id; Running = $running; ImageRef = $imageRef
        AttachedToOwnedNetwork = ($OwnedNetwork -in $networkNames); Networks = $networkNames
        HostPortBindings = $hostBindings; ImageRefMatches = ($imageRef -ceq $ExpectedImageRef)
    }
}

function Get-FixtureGate {
    # Pure gate over the two inspected containers. Each must be running, on the owned network
    # and the pinned image; the broker must expose NO host port; HA must be bound to EXACTLY
    # the 127.0.0.1:8123 loopback - zero host-port bindings is a failure, not a pass, so an HA
    # that silently came up with no published port cannot slip through. SelfTested.
    param([Parameter(Mandatory)]$Broker, [Parameter(Mandatory)]$Ha)
    $reasons = @()
    if (-not [bool](Get-CaptureProp $Broker 'Ok')) { $reasons += 'broker not inspected' }
    else {
        if (-not [bool](Get-CaptureProp $Broker 'Running')) { $reasons += 'broker not running' }
        if (-not [bool](Get-CaptureProp $Broker 'AttachedToOwnedNetwork')) { $reasons += 'broker not on the owned network' }
        if (-not [bool](Get-CaptureProp $Broker 'ImageRefMatches')) { $reasons += 'broker image ref is not the pin' }
        if (@(Get-CaptureProp $Broker 'HostPortBindings').Count -ne 0) { $reasons += 'broker exposes a host port' }
    }
    if (-not [bool](Get-CaptureProp $Ha 'Ok')) { $reasons += 'HA not inspected' }
    else {
        if (-not [bool](Get-CaptureProp $Ha 'Running')) { $reasons += 'HA not running' }
        if (-not [bool](Get-CaptureProp $Ha 'AttachedToOwnedNetwork')) { $reasons += 'HA not on the owned network' }
        if (-not [bool](Get-CaptureProp $Ha 'ImageRefMatches')) { $reasons += 'HA image ref is not the pin' }
        $haBindings = @(Get-CaptureProp $Ha 'HostPortBindings')
        $nonLoopback = @($haBindings | Where-Object { $_ -notmatch '->127\.0\.0\.1:' })
        $has8123 = (@($haBindings | Where-Object { $_ -match '^8123/tcp->127\.0\.0\.1:8123$' }).Count -ge 1)
        if ($haBindings.Count -eq 0) { $reasons += 'HA has no host port binding (expected 127.0.0.1:8123)' }
        elseif ($nonLoopback.Count -ne 0) { $reasons += 'HA has a non-loopback host port binding' }
        elseif (-not $has8123) { $reasons += 'HA is not bound to 127.0.0.1:8123' }
    }
    return [pscustomobject]@{ Ready = ($reasons.Count -eq 0); Reasons = $reasons }
}

function Get-RunCompletion {
    # The run is Completed only when every declared case produced a sound AND complete
    # observation. A withheld commit (subscriber not ready), a broken observation channel
    # (ObservationError), a short inventory (MaxCommits reached early / a declared case never
    # attempted), OR a partial command observation after an accepted write (observer non-zero /
    # timeout / missing payload) is a bounded Incomplete - never a completed empty or partial
    # surrogate. A genuine missing-context result with sound, complete observations
    # (Measured/NoEvent/ValueMismatch) is still a valid, completed negative. Pure; SelfTested.
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$DeclaredCases, [AllowEmptyCollection()][object[]]$Cases)
    $sound = @('Measured', 'NoEvent', 'ValueMismatch', 'ServiceFailed')
    $byCase = @{}
    foreach ($record in $Cases) { $byCase[[string](Get-CaptureProp $record 'case')] = $record }
    $missing = @($DeclaredCases | Where-Object { -not $byCase.ContainsKey($_) })
    if ($missing.Count) { return [pscustomobject]@{ Completed = $false; Reason = "declared cases not attempted: $($missing -join ', ')" } }
    $unsound = @()
    foreach ($name in $DeclaredCases) {
        $record = $byCase[$name]
        $outcome = [string](Get-CaptureProp $record 'outcome')
        if ($outcome -notin $sound) { $unsound += "${name}:$outcome" }
        elseif ([bool](Get-CaptureProp $record 'observationPartial')) { $unsound += "${name}:partial-observation" }
    }
    if ($unsound.Count) { return [pscustomobject]@{ Completed = $false; Reason = "cases without a sound, complete observation: $($unsound -join ', ')" } }
    return [pscustomobject]@{ Completed = $true; Reason = 'every declared case produced a sound, complete observation' }
}

function New-CommitCaseRecord {
    # The evidence projection builder. Pure: turns one observation into the bounded record
    # written to the evidence file. Validated by SelfTest. No credentials are recorded; the
    # two context loci are classified separately AND keep their raw id/parent_id/user_id so a
    # reviewer can distinguish a real matched actor from a classification claim, and the
    # service result, timing and subscriber readiness/exit evidence are all retained.
    param([Parameter(Mandatory)]$Observation)
    $requested = [string](Get-CaptureProp $Observation 'RequestedValue')
    $observed = Get-CaptureProp $Observation 'ObservedValue'
    $expected = [string](Get-CaptureProp $Observation 'ExpectedUserId')
    $commandPayload = Get-CaptureProp $Observation 'CommandPayload'
    $commandObserved = -not [string]::IsNullOrEmpty([string]$commandPayload)

    $observedValueDigest = $null
    $valueMatchesRequest = $false
    if ($null -ne $observed) {
        $observedValueDigest = Get-CommitValueDigest -Value ([string]$observed)
        $valueMatchesRequest = ([string]$observed -ceq $requested)
    }
    $commandPayloadDigest = $null
    if ($commandObserved) { $commandPayloadDigest = Get-CommitValueDigest -Value ([string]$commandPayload) }

    $newUserId = [string](Get-CaptureProp $Observation 'NewStateContextUserId')
    $eventUserId = [string](Get-CaptureProp $Observation 'EventContextUserId')

    # After an ACCEPTED write the command observer must have cleanly captured the payload; a
    # non-zero exit, a timeout (never exited) or a missing payload is a PARTIAL observation,
    # retained as partial so completion cannot silently count it as clean. A withheld or
    # rejected write expects no payload, so it is never partial on this basis.
    $serviceAccepted = [bool](Get-CaptureProp $Observation 'ServiceAccepted')
    $subscriberExited = [bool](Get-CaptureProp $Observation 'CommandSubscriberExited')
    $subscriberExit = Get-CaptureProp $Observation 'CommandSubscriberExit'
    $observationPartial = $false
    if ($serviceAccepted) {
        if (-not $subscriberExited) { $observationPartial = $true }
        elseif ($null -ne $subscriberExit -and [int]$subscriberExit -ne 0) { $observationPartial = $true }
        elseif (-not $commandObserved) { $observationPartial = $true }
    }

    return [ordered]@{
        case = [string](Get-CaptureProp $Observation 'Case')
        principal = [string](Get-CaptureProp $Observation 'PrincipalLabel')
        expectedUserId = $expected
        requestedValueDigest = (Get-CommitValueDigest -Value $requested)
        stateObserved = [bool](Get-CaptureProp $Observation 'StateObserved')
        observedValueDigest = $observedValueDigest
        valueMatchesRequest = $valueMatchesRequest
        newStateContext = (Get-ContextLocusClassification -UserId $newUserId -ExpectedUserId $expected)
        eventContext = (Get-ContextLocusClassification -UserId $eventUserId -ExpectedUserId $expected)
        newStateContextActor = [ordered]@{ id = [string](Get-CaptureProp $Observation 'NewStateContextId'); parentId = [string](Get-CaptureProp $Observation 'NewStateContextParentId'); userId = $newUserId }
        eventContextActor = [ordered]@{ id = [string](Get-CaptureProp $Observation 'EventContextId'); parentId = [string](Get-CaptureProp $Observation 'EventContextParentId'); userId = $eventUserId }
        service = [ordered]@{ accepted = $serviceAccepted; detail = [string](Get-CaptureProp $Observation 'ServiceDetail') }
        timing = [ordered]@{ committedUtc = [string](Get-CaptureProp $Observation 'CommittedAtUtc'); observedUtc = [string](Get-CaptureProp $Observation 'ObservedAtUtc'); latencyMs = (Get-CaptureProp $Observation 'ObservationLatencyMs') }
        subscriber = [ordered]@{ ready = [bool](Get-CaptureProp $Observation 'CommandSubscriberReady'); state = [string](Get-CaptureProp $Observation 'CommandSubscriberState'); exited = $subscriberExited; exitCode = $subscriberExit; errorTail = [string](Get-CaptureProp $Observation 'CommandSubscriberError') }
        commandPayloadObserved = $commandObserved
        commandPayloadDigest = $commandPayloadDigest
        observationPartial = $observationPartial
        observationError = [string](Get-CaptureProp $Observation 'ObservationError')
        outcome = (Get-CommitCaseOutcome -Observation $Observation)
    }
}

function Test-PrincipalsValid {
    # Synthetic principals must have non-empty, distinct, token-backed ids before measurement;
    # an empty or shared id cannot become expected identity data.
    param($PrincipalA, $PrincipalB)
    $idA = [string](Get-CaptureProp $PrincipalA 'UserId'); $idB = [string](Get-CaptureProp $PrincipalB 'UserId')
    $tokenA = [string](Get-CaptureProp $PrincipalA 'Token'); $tokenB = [string](Get-CaptureProp $PrincipalB 'Token')
    if ([string]::IsNullOrWhiteSpace($idA) -or [string]::IsNullOrWhiteSpace($idB)) { return [pscustomobject]@{ Valid = $false; Reason = 'a principal has no user id' } }
    if ([string]::IsNullOrWhiteSpace($tokenA) -or [string]::IsNullOrWhiteSpace($tokenB)) { return [pscustomobject]@{ Valid = $false; Reason = 'a principal has no token' } }
    if ($idA -ceq $idB) { return [pscustomobject]@{ Valid = $false; Reason = 'principals share a user id' } }
    return [pscustomobject]@{ Valid = $true; Reason = 'distinct non-empty token-backed principal ids' }
}

function Get-VolumeFreshness {
    # Decide a named volume's ownership from an AUTHORITATIVE `docker volume ls` result, never
    # from a failed inspect: a failed read is NOT proof of absence, and an idempotent create
    # after an unknown read is NOT freshness. Only a SUCCESSFUL list whose names do not include
    # the target proves absence (Fresh); the target being present is a Collision; a failed list
    # is an InventoryError. All three non-fresh paths refuse. Pure; SelfTested.
    param([bool]$ListSucceeded, [AllowEmptyCollection()][AllowNull()][string[]]$VolumeNames, [Parameter(Mandatory)][string]$Name)
    if (-not $ListSucceeded) { return [pscustomobject]@{ State = 'InventoryError'; Fresh = $false } }
    if ($Name -cin @($VolumeNames)) { return [pscustomobject]@{ State = 'Collision'; Fresh = $false } }
    return [pscustomobject]@{ State = 'Absent'; Fresh = $true }
}

function Get-FixtureCleanupPlan {
    # Ordered, ownership-scoped cleanup BY ACTUAL ID: containers first (so the network and any
    # anonymous volumes free), then owned volumes, then the network, then owned files. An entry
    # WITHOUT a recorded id has no proven ownership; it is put in Refused and never removed by
    # name, so a name collision can never cause this run to delete a resource it did not create.
    param([AllowEmptyCollection()][object[]]$Created)
    $containers = @(); $volumes = @(); $networks = @(); $files = @(); $refused = @()
    foreach ($entry in @($Created)) {
        $kind = [string](Get-CaptureProp $entry 'kind')
        $name = [string](Get-CaptureProp $entry 'name')
        $id = [string](Get-CaptureProp $entry 'id')
        if ([string]::IsNullOrWhiteSpace($id)) { $refused += [pscustomobject]@{ kind = $kind; name = $name }; continue }
        $item = [pscustomobject]@{ name = $name; id = $id }
        switch ($kind) {
            'container' { $containers += $item }
            'volume' { $volumes += $item }
            'network' { $networks += $item }
            'file' { $files += $item }
        }
    }
    return [pscustomobject]@{ Containers = @($containers); Volumes = @($volumes); Networks = @($networks); Files = @($files); Refused = @($refused) }
}

# ----------------------------------------------------------------------------------------
# SelfTest: pure unit validation. No Home Assistant measurement.
# ----------------------------------------------------------------------------------------

function Invoke-CommitContextSelfTest {
    $script:SelfTestFailures = 0
    $script:SelfTestTotal = 0
    function Confirm-Case {
        param([string]$Name, $Expected, $Actual)
        $script:SelfTestTotal++
        if ($Expected -ceq $Actual) { Write-Host "  PASS  $Name" }
        else { Write-Host "  FAIL  $Name - expected '$Expected', got '$Actual'" -ForegroundColor Red; $script:SelfTestFailures++ }
    }
    Write-Host 'UNIT VALIDATION (pure decision functions) - not a Home Assistant measurement'

    # Per-locus context classification.
    Confirm-Case 'empty locus is Absent' 'Absent' (Get-ContextLocusClassification -UserId '' -ExpectedUserId 'userA')
    Confirm-Case 'equal locus is Matched' 'Matched' (Get-ContextLocusClassification -UserId 'userA' -ExpectedUserId 'userA')
    Confirm-Case 'different locus is Mismatched' 'Mismatched' (Get-ContextLocusClassification -UserId 'userB' -ExpectedUserId 'userA')

    # Case outcome: quiet window vs fault vs failed write vs stale value vs measured.
    Confirm-Case 'observation error is ObservationError' 'ObservationError' (Get-CommitCaseOutcome ([pscustomobject]@{ ObservationError = 'socket drop'; ServiceAccepted = $true; StateObserved = $true; RequestedValue = 'v'; ObservedValue = 'v' }))
    Confirm-Case 'rejected write is ServiceFailed' 'ServiceFailed' (Get-CommitCaseOutcome ([pscustomobject]@{ ObservationError = ''; ServiceAccepted = $false; StateObserved = $false; RequestedValue = 'v' }))
    Confirm-Case 'quiet window is NoEvent' 'NoEvent' (Get-CommitCaseOutcome ([pscustomobject]@{ ObservationError = ''; ServiceAccepted = $true; StateObserved = $false; RequestedValue = 'v' }))
    Confirm-Case 'stale value is ValueMismatch' 'ValueMismatch' (Get-CommitCaseOutcome ([pscustomobject]@{ ObservationError = ''; ServiceAccepted = $true; StateObserved = $true; RequestedValue = 'v2'; ObservedValue = 'v1' }))
    Confirm-Case 'requested value is Measured' 'Measured' (Get-CommitCaseOutcome ([pscustomobject]@{ ObservationError = ''; ServiceAccepted = $true; StateObserved = $true; RequestedValue = 'v2'; ObservedValue = 'v2' }))
    Confirm-Case 'withheld commit is SubscriberNotReady' 'SubscriberNotReady' (Get-CommitCaseOutcome ([pscustomobject]@{ SubscriberNotReady = $true; ObservationError = ''; ServiceAccepted = $false; StateObserved = $false; RequestedValue = 'v' }))

    # Projection builder: loci distinct, value bound, digests full, no (if ...) runtime hazard.
    $measured = New-CommitCaseRecord ([pscustomobject]@{
            Case = 'c'; PrincipalLabel = 'principalA'; ExpectedUserId = 'userA'; ServiceAccepted = $true; ServiceDetail = 'HTTP 200'
            RequestedValue = 'val-2'; StateObserved = $true; ObservedValue = 'val-2'
            NewStateContextId = 'ctx-new'; NewStateContextParentId = 'par-new'; NewStateContextUserId = ''
            EventContextId = 'ctx-evt'; EventContextParentId = 'par-evt'; EventContextUserId = 'userA'
            CommittedAtUtc = '2026-10-06T00:00:00.000Z'; ObservedAtUtc = '2026-10-06T00:00:01.000Z'; ObservationLatencyMs = 42
            CommandPayload = 'val-2'; CommandSubscriberReady = $true; CommandSubscriberState = 'GrantedSubscription'; CommandSubscriberExited = $true; CommandSubscriberExit = 0; ObservationError = ''
        })
    Confirm-Case 'projection outcome Measured' 'Measured' $measured.outcome
    Confirm-Case 'projection keeps new_state locus Absent' 'Absent' $measured.newStateContext
    Confirm-Case 'projection keeps event locus Matched' 'Matched' $measured.eventContext
    Confirm-Case 'projection binds the value match' $true $measured.valueMatchesRequest
    Confirm-Case 'projection digests the requested value' $true ($measured.requestedValueDigest -match '^[a-f0-9]{64}$')
    Confirm-Case 'projection retains raw new_state actor id' 'ctx-new' $measured.newStateContextActor.id
    Confirm-Case 'projection retains raw event actor user id' 'userA' $measured.eventContextActor.userId
    Confirm-Case 'projection retains commit->observe latency' 42 $measured.timing.latencyMs
    Confirm-Case 'projection retains subscriber readiness state' 'GrantedSubscription' $measured.subscriber.state
    Confirm-Case 'projection records no credential fields' $true ($null -eq (Get-CaptureProp $measured 'token') -and $null -eq (Get-CaptureProp $measured 'password'))
    Confirm-Case 'a clean accepted projection is not partial' $false $measured.observationPartial
    $staleRecord = New-CommitCaseRecord ([pscustomobject]@{ Case = 'c'; PrincipalLabel = 'principalA'; ExpectedUserId = 'userA'; ServiceAccepted = $true; RequestedValue = 'new'; StateObserved = $true; ObservedValue = 'old'; CommandPayload = $null })
    Confirm-Case 'stale projection is ValueMismatch and value unmatched' $true (($staleRecord.outcome -eq 'ValueMismatch') -and (-not $staleRecord.valueMatchesRequest))
    Confirm-Case 'no-command projection leaves payload digest null' $true ($null -eq $staleRecord.commandPayloadDigest)

    # Target refusal.
    $hosted = @{ GITHUB_ACTIONS = 'true'; RUNNER_ENVIRONMENT = 'github-hosted' }
    Confirm-Case 'github-hosted loopback with nonce is allowed' $true (Test-DisposableTargetAllowed -Environment $hosted -HaBaseUrl 'http://127.0.0.1:8123' -BrokerHost '127.0.0.1' -Nonce 'abc123def456').Allowed
    Confirm-Case 'self-hosted is refused' $false (Test-DisposableTargetAllowed -Environment @{ GITHUB_ACTIONS = 'true'; RUNNER_ENVIRONMENT = 'self-hosted' } -HaBaseUrl 'http://127.0.0.1:8123' -BrokerHost '127.0.0.1' -Nonce 'abc123def456').Allowed
    Confirm-Case 'non-Actions host is refused' $false (Test-DisposableTargetAllowed -Environment @{ GITHUB_ACTIONS = '' } -HaBaseUrl 'http://127.0.0.1:8123' -BrokerHost '127.0.0.1' -Nonce 'abc123def456').Allowed
    Confirm-Case 'live LAN HA is refused' $false (Test-DisposableTargetAllowed -Environment $hosted -HaBaseUrl 'http://192.168.1.188:8123' -BrokerHost '127.0.0.1' -Nonce 'abc123def456').Allowed
    Confirm-Case 'missing nonce is refused' $false (Test-DisposableTargetAllowed -Environment $hosted -HaBaseUrl 'http://127.0.0.1:8123' -BrokerHost '127.0.0.1' -Nonce '').Allowed

    # Image pin check.
    Confirm-Case 'reviewed digest-pinned ref is accepted' $true (Test-ImagePinned -ImageRef "ghcr.io/x@$script:ReviewedHaDigest" -ExpectedDigest $script:ReviewedHaDigest)
    Confirm-Case 'a bare tag is refused' $false (Test-ImagePinned -ImageRef 'ghcr.io/x:2026.9.4' -ExpectedDigest $script:ReviewedHaDigest)
    Confirm-Case 'a different digest is refused' $false (Test-ImagePinned -ImageRef 'ghcr.io/x@sha256:0000000000000000000000000000000000000000000000000000000000000000' -ExpectedDigest $script:ReviewedHaDigest)

    # Principal validation.
    Confirm-Case 'distinct token-backed principals are valid' $true (Test-PrincipalsValid ([pscustomobject]@{ UserId = 'a'; Token = 'ta' }) ([pscustomobject]@{ UserId = 'b'; Token = 'tb' })).Valid
    Confirm-Case 'a missing principal id is invalid' $false (Test-PrincipalsValid ([pscustomobject]@{ UserId = ''; Token = 'ta' }) ([pscustomobject]@{ UserId = 'b'; Token = 'tb' })).Valid
    Confirm-Case 'shared principal ids are invalid' $false (Test-PrincipalsValid ([pscustomobject]@{ UserId = 'a'; Token = 'ta' }) ([pscustomobject]@{ UserId = 'a'; Token = 'tb' })).Valid

    # Cleanup plan ordering and ownership: entries carry the actual id, volumes are disposed.
    $plan = Get-FixtureCleanupPlan -Created @(@{ kind = 'network'; name = 'n1'; id = 'netid' }, @{ kind = 'container'; name = 'c1'; id = 'cid' }, @{ kind = 'file'; name = 'f1'; id = 'f1' }, @{ kind = 'volume'; name = 'v1'; id = 'v1' })
    Confirm-Case 'cleanup plan lists the owned container by id' $true ((@($plan.Containers).Count -eq 1) -and ($plan.Containers[0].id -eq 'cid'))
    Confirm-Case 'cleanup plan lists the owned volume' $true ((@($plan.Volumes).Count -eq 1) -and ($plan.Volumes[0].id -eq 'v1'))
    Confirm-Case 'cleanup plan lists the owned network by id' $true ((@($plan.Networks).Count -eq 1) -and ($plan.Networks[0].id -eq 'netid'))
    Confirm-Case 'cleanup plan lists the owned file' $true ((@($plan.Files).Count -eq 1) -and ($plan.Files[0].name -eq 'f1'))

    # Ownership: an id-less entry is REFUSED (never removed by name); an owned-but-unstarted
    # container (id recorded at create, before start) is still removable by its id.
    $planOwnership = Get-FixtureCleanupPlan -Created @(@{ kind = 'container'; name = 'c-noid' }, @{ kind = 'container'; name = 'c-unstarted'; id = 'cidunstarted' }, @{ kind = 'volume'; name = 'v-noid' })
    Confirm-Case 'an id-less resource is refused, not removed by name' $true ((@($planOwnership.Refused).Count -eq 2) -and ('c-noid' -cin @($planOwnership.Refused.name)) -and ('v-noid' -cin @($planOwnership.Refused.name)))
    Confirm-Case 'an id-less resource never enters a removable bucket' 0 (@($planOwnership.Volumes).Count)
    Confirm-Case 'an owned unstarted container is removable by id' $true ((@($planOwnership.Containers).Count -eq 1) -and ($planOwnership.Containers[0].id -eq 'cidunstarted'))

    # Volume freshness from an AUTHORITATIVE inventory: only a successful list proves absence.
    Confirm-Case 'a listed volume name is a collision' 'Collision' (Get-VolumeFreshness -ListSucceeded $true -VolumeNames @('other', 'cc-haconfig-x') -Name 'cc-haconfig-x').State
    Confirm-Case 'an authoritative absence is fresh' $true (Get-VolumeFreshness -ListSucceeded $true -VolumeNames @('other') -Name 'cc-haconfig-x').Fresh
    Confirm-Case 'a failed inventory is not absence' 'InventoryError' (Get-VolumeFreshness -ListSucceeded $false -VolumeNames @() -Name 'cc-haconfig-x').State
    Confirm-Case 'a failed inventory is not fresh' $false (Get-VolumeFreshness -ListSucceeded $false -VolumeNames @() -Name 'cc-haconfig-x').Fresh

    # Subscriber readiness parser, against the pinned Mosquitto v2.0.22 stdout contract.
    $connackOnly = "Client cid sending CONNECT`nClient cid received CONNACK (0)"
    $granted = "$connackOnly`nClient cid sending SUBSCRIBE (Mid: 1, Topic: cc/x/set, QoS: 0)`nClient cid received SUBACK`nSubscribed (mid: 1): 0"
    $denied = "$connackOnly`nSubscribed (mid: 1): 128"
    Confirm-Case 'connack then granted suback is ready' $true (Get-SubscriberReadiness -StdoutText $granted).Ready
    Confirm-Case 'granted suback reports GrantedSubscription' 'GrantedSubscription' (Get-SubscriberReadiness -StdoutText $granted).State
    Confirm-Case 'a bare connack is not ready' $false (Get-SubscriberReadiness -StdoutText $connackOnly).Ready
    Confirm-Case 'a bare connack is ConnackOnly' 'ConnackOnly' (Get-SubscriberReadiness -StdoutText $connackOnly).State
    Confirm-Case 'a denied subscription is rejected' $true (Get-SubscriberReadiness -StdoutText $denied).Rejected
    Confirm-Case 'a denied subscription is not ready' $false (Get-SubscriberReadiness -StdoutText $denied).Ready
    Confirm-Case 'no handshake is NoHandshake' 'NoHandshake' (Get-SubscriberReadiness -StdoutText '').State
    Confirm-Case 'a refused connack is not connected' $false (Get-SubscriberReadiness -StdoutText 'Client cid received CONNACK (5)').Connected
    Confirm-Case 'readiness parses PTY CRLF output' $true (Get-SubscriberReadiness -StdoutText ($granted -replace "`n", "`r`n")).Ready

    # Payload parser: the nonce-bound payload is separated from the debug transcript.
    $mixed = "$granted`nCCMSG-abc-0001>>{`"submitId`":`"PROBE-x`"}"
    Confirm-Case 'payload is extracted after the sentinel' '{"submitId":"PROBE-x"}' (Get-ObserverPayload -StdoutText $mixed -Sentinel 'CCMSG-abc-0001>>')
    Confirm-Case 'the debug transcript is not treated as payload' $true ((Get-ObserverPayload -StdoutText $mixed -Sentinel 'CCMSG-abc-0001>>') -notmatch 'CONNACK')
    Confirm-Case 'an absent sentinel yields null payload' $true ($null -eq (Get-ObserverPayload -StdoutText $granted -Sentinel 'CCMSG-abc-0001>>'))

    # Container topology projection from synthetic docker inspect JSON.
    $brokerInspect = (@{ Id = 'bid'; State = @{ Running = $true }; Config = @{ Image = 'mq@sha256:abc' }; NetworkSettings = @{ Networks = @{ 'cc-net-x' = @{} }; Ports = @{} } } | ConvertTo-Json -Depth 8)
    $brokerTopo = Get-ContainerTopology -InspectJson "[$brokerInspect]" -OwnedNetwork 'cc-net-x' -ExpectedImageRef 'mq@sha256:abc'
    Confirm-Case 'broker is attached to the owned network' $true $brokerTopo.AttachedToOwnedNetwork
    Confirm-Case 'broker exposes no host port' 0 (@($brokerTopo.HostPortBindings).Count)
    Confirm-Case 'broker image ref matches the pin' $true $brokerTopo.ImageRefMatches
    $haInspect = (@{ Id = 'hid'; State = @{ Running = $true }; Config = @{ Image = 'ha@sha256:def' }; NetworkSettings = @{ Networks = @{ 'cc-net-x' = @{} }; Ports = @{ '8123/tcp' = @(@{ HostIp = '127.0.0.1'; HostPort = '8123' }) } } } | ConvertTo-Json -Depth 8)
    $haTopo = Get-ContainerTopology -InspectJson $haInspect -OwnedNetwork 'cc-net-x' -ExpectedImageRef 'ha@sha256:def'
    Confirm-Case 'HA host port binding is loopback only' $true (@($haTopo.HostPortBindings).Count -eq 1 -and $haTopo.HostPortBindings[0] -match '127\.0\.0\.1:8123')
    Confirm-Case 'a foreign network is not owned' $false (Get-ContainerTopology -InspectJson $haInspect -OwnedNetwork 'cc-net-other' -ExpectedImageRef 'ha@sha256:def').AttachedToOwnedNetwork
    Confirm-Case 'invalid inspect json is not ok' $false (Get-ContainerTopology -InspectJson 'not json' -OwnedNetwork 'cc-net-x' -ExpectedImageRef 'x').Ok

    # Fixture gate: running, owned network, pinned image, broker unexposed, HA bound to the
    # 127.0.0.1:8123 loopback (zero bindings is a failure, not a pass).
    $gBroker = [pscustomobject]@{ Ok = $true; Running = $true; AttachedToOwnedNetwork = $true; ImageRefMatches = $true; HostPortBindings = @() }
    $gHa = [pscustomobject]@{ Ok = $true; Running = $true; AttachedToOwnedNetwork = $true; ImageRefMatches = $true; HostPortBindings = @('8123/tcp->127.0.0.1:8123') }
    Confirm-Case 'a correct fixture passes the gate' $true (Get-FixtureGate -Broker $gBroker -Ha $gHa).Ready
    Confirm-Case 'HA with zero bindings fails the gate' $false (Get-FixtureGate -Broker $gBroker -Ha ([pscustomobject]@{ Ok = $true; Running = $true; AttachedToOwnedNetwork = $true; ImageRefMatches = $true; HostPortBindings = @() })).Ready
    Confirm-Case 'HA with a non-loopback binding fails the gate' $false (Get-FixtureGate -Broker $gBroker -Ha ([pscustomobject]@{ Ok = $true; Running = $true; AttachedToOwnedNetwork = $true; ImageRefMatches = $true; HostPortBindings = @('8123/tcp->0.0.0.0:8123') })).Ready
    Confirm-Case 'an exposed broker fails the gate' $false (Get-FixtureGate -Broker ([pscustomobject]@{ Ok = $true; Running = $true; AttachedToOwnedNetwork = $true; ImageRefMatches = $true; HostPortBindings = @('1883/tcp->0.0.0.0:1883') }) -Ha $gHa).Ready
    Confirm-Case 'a broker off the owned network fails the gate' $false (Get-FixtureGate -Broker ([pscustomobject]@{ Ok = $true; Running = $true; AttachedToOwnedNetwork = $false; ImageRefMatches = $true; HostPortBindings = @() }) -Ha $gHa).Ready
    Confirm-Case 'a stopped HA fails the gate' $false (Get-FixtureGate -Broker $gBroker -Ha ([pscustomobject]@{ Ok = $true; Running = $false; AttachedToOwnedNetwork = $true; ImageRefMatches = $true; HostPortBindings = @('8123/tcp->127.0.0.1:8123') })).Ready
    Confirm-Case 'an unpinned image fails the gate' $false (Get-FixtureGate -Broker ([pscustomobject]@{ Ok = $true; Running = $true; AttachedToOwnedNetwork = $true; ImageRefMatches = $false; HostPortBindings = @() }) -Ha $gHa).Ready

    # Run completion: only a full inventory of sound, COMPLETE observations completes the run.
    $cleanA = New-CommitCaseRecord ([pscustomobject]@{ Case = 'a'; ServiceAccepted = $true; StateObserved = $true; RequestedValue = 'v'; ObservedValue = 'v'; CommandPayload = 'v'; CommandSubscriberExited = $true; CommandSubscriberExit = 0 })
    $cleanB = New-CommitCaseRecord ([pscustomobject]@{ Case = 'b'; ServiceAccepted = $true; StateObserved = $false; RequestedValue = 'v'; CommandPayload = 'v'; CommandSubscriberExited = $true; CommandSubscriberExit = 0 })
    Confirm-Case 'a full inventory of sound, complete cases completes' $true (Get-RunCompletion -DeclaredCases @('a', 'b') -Cases @($cleanA, $cleanB)).Completed
    Confirm-Case 'a missing declared case is incomplete' $false (Get-RunCompletion -DeclaredCases @('a', 'b', 'c') -Cases @($cleanA, $cleanB)).Completed
    $errorCase = @((New-CommitCaseRecord ([pscustomobject]@{ Case = 'a'; ObservationError = 'drop'; ServiceAccepted = $true; StateObserved = $true; RequestedValue = 'v'; ObservedValue = 'v' })))
    Confirm-Case 'an observation error is incomplete' $false (Get-RunCompletion -DeclaredCases @('a') -Cases $errorCase).Completed
    $withheldCase = @((New-CommitCaseRecord ([pscustomobject]@{ Case = 'a'; SubscriberNotReady = $true; ServiceAccepted = $false; StateObserved = $false; RequestedValue = 'v' })))
    Confirm-Case 'a withheld commit is incomplete' $false (Get-RunCompletion -DeclaredCases @('a') -Cases $withheldCase).Completed
    $negativeCase = @((New-CommitCaseRecord ([pscustomobject]@{ Case = 'a'; ServiceAccepted = $true; StateObserved = $true; RequestedValue = 'v'; ObservedValue = 'v'; NewStateContextUserId = ''; EventContextUserId = ''; CommandPayload = 'v'; CommandSubscriberExited = $true; CommandSubscriberExit = 0 })))
    Confirm-Case 'a sound missing-context negative still completes' $true (Get-RunCompletion -DeclaredCases @('a') -Cases $negativeCase).Completed

    # A partial command observation after an accepted write (non-zero exit / timeout / missing
    # payload) is retained as partial and keeps the run Incomplete; a rejected write expects no
    # payload and is not partial on that basis.
    Confirm-Case 'a clean accepted observation is not partial' $false $cleanA.observationPartial
    $timeoutRec = New-CommitCaseRecord ([pscustomobject]@{ Case = 'a'; ServiceAccepted = $true; StateObserved = $true; RequestedValue = 'v'; ObservedValue = 'v'; CommandPayload = 'v'; CommandSubscriberExited = $false; CommandSubscriberExit = $null })
    Confirm-Case 'an observer timeout after an accepted write is partial' $true $timeoutRec.observationPartial
    Confirm-Case 'a partial observation keeps the run incomplete' $false (Get-RunCompletion -DeclaredCases @('a') -Cases @($timeoutRec)).Completed
    $nonzeroRec = New-CommitCaseRecord ([pscustomobject]@{ Case = 'a'; ServiceAccepted = $true; StateObserved = $true; RequestedValue = 'v'; ObservedValue = 'v'; CommandPayload = 'v'; CommandSubscriberExited = $true; CommandSubscriberExit = 1 })
    Confirm-Case 'a non-zero observer exit after an accepted write is partial' $true $nonzeroRec.observationPartial
    $noPayloadRec = New-CommitCaseRecord ([pscustomobject]@{ Case = 'a'; ServiceAccepted = $true; StateObserved = $false; RequestedValue = 'v'; CommandPayload = $null; CommandSubscriberExited = $true; CommandSubscriberExit = 0 })
    Confirm-Case 'a missing payload after an accepted write is partial' $true $noPayloadRec.observationPartial
    $rejectedRec = New-CommitCaseRecord ([pscustomobject]@{ Case = 'a'; ServiceAccepted = $false; StateObserved = $false; RequestedValue = 'v'; CommandPayload = $null; CommandSubscriberExited = $true; CommandSubscriberExit = 1 })
    Confirm-Case 'a rejected write expects no payload and is not partial' $false $rejectedRec.observationPartial

    if ($script:SelfTestFailures -eq 0) { Write-Host "SelfTest: all $script:SelfTestTotal pure checks passed." -ForegroundColor Green }
    else { Write-Host "SelfTest: $script:SelfTestFailures of $script:SelfTestTotal check(s) failed." -ForegroundColor Red }
    return $script:SelfTestFailures
}

# ----------------------------------------------------------------------------------------
# Transport helpers (Measure mode). Bounded by explicit tokens; never dot-source the install.
# ----------------------------------------------------------------------------------------

function Invoke-HaRest {
    param(
        [Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Path, [string]$Token, $Body,
        [string]$ContentType = 'application/json', [int]$TimeoutSec = 15,
        [ValidateSet('Setup', 'Commit', 'None')][string]$Accounting = 'Setup'
    )
    switch ($Accounting) { 'Setup' { $script:SetupRequestCount++ } 'Commit' { $script:CommitWriteCount++ } }
    $headers = @{}
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    $arguments = @{ Uri = "$script:HaBaseUrl$Path"; Method = $Method; Headers = $headers; TimeoutSec = $TimeoutSec; ContentType = $ContentType }
    if ($null -ne $Body) { $arguments['Body'] = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 12 -Compress } }
    return Invoke-RestMethod @arguments
}

function Send-WsMessage {
    param($Ws, $Token, $Object)
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Object | ConvertTo-Json -Compress -Depth 10))
    [void]$Ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $Token).GetAwaiter().GetResult()
}

function Receive-WsMessage {
    param($Ws, $Token)
    $buffer = [byte[]]::new(131072); $builder = [Text.StringBuilder]::new()
    do {
        $frame = $Ws.ReceiveAsync([ArraySegment[byte]]::new($buffer), $Token).GetAwaiter().GetResult()
        [void]$builder.Append([Text.Encoding]::UTF8.GetString($buffer, 0, $frame.Count))
    } while (-not $frame.EndOfMessage)
    return $builder.ToString() | ConvertFrom-Json
}

function Close-Ws {
    param($Ws)
    try {
        if ($Ws.State -eq 'Open') {
            $cts = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(5))
            try { $Ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', $cts.Token).GetAwaiter().GetResult() } catch { } finally { $cts.Dispose() }
        }
    }
    catch { }
    $Ws.Dispose()
}

function Connect-HaWs {
    param([string]$Token, [int]$TimeoutSec)
    $uri = [uri]$script:HaBaseUrl
    $scheme = if ($uri.Scheme -eq 'https') { 'wss' } else { 'ws' }
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $cts = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))
    try {
        $ws.ConnectAsync([uri]("{0}://{1}:{2}/api/websocket" -f $scheme, $uri.Host, $uri.Port), $cts.Token).GetAwaiter().GetResult()
        $null = Receive-WsMessage $ws $cts.Token
        Send-WsMessage $ws $cts.Token @{ type = 'auth'; access_token = $Token }
        if ((Get-CaptureProp (Receive-WsMessage $ws $cts.Token) 'type') -ne 'auth_ok') { Close-Ws $ws; $cts.Dispose(); throw 'HA WebSocket auth failed' }
    }
    catch { $cts.Dispose(); throw }
    return [pscustomobject]@{ Ws = $ws; Cts = $cts }
}

function Invoke-HaWsCommand {
    param([string]$Token, [hashtable]$Command, [int]$TimeoutSec = 10)
    $script:SetupRequestCount++
    $session = Connect-HaWs -Token $Token -TimeoutSec $TimeoutSec
    try {
        Send-WsMessage $session.Ws $session.Cts.Token $Command
        $response = Receive-WsMessage $session.Ws $session.Cts.Token
        return [pscustomobject]@{ Success = [bool](Get-CaptureProp $response 'success'); Result = (Get-CaptureProp $response 'result'); Error = (Get-CaptureProp $response 'error') }
    }
    finally { Close-Ws $session.Ws; $session.Cts.Dispose() }
}

# ----------------------------------------------------------------------------------------
# Fixture lifecycle and the bounded capture.
# ----------------------------------------------------------------------------------------

function Invoke-FixtureDocker {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$AllowFailure, [ValidateSet('Setup', 'Cleanup')][string]$Accounting = 'Setup')
    switch ($Accounting) { 'Setup' { $script:SetupRequestCount++ } 'Cleanup' { $script:CleanupRequestCount++ } }
    $output = & docker @Arguments 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) { throw "docker $($Arguments -join ' ') failed ($LASTEXITCODE): $output" }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}

function Get-DockerStdoutId {
    # The last non-empty stdout line of a `docker create`/`network create`/`volume create`,
    # which is the created resource's id (network/container) or name (volume). A proposed name
    # is never used in its place.
    param([AllowEmptyString()][string]$Output)
    return ([string]($Output -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)).Trim()
}

function New-OwnedDockerResource {
    # Create a NETWORK and record the ACTUAL id docker returns, so disposal acts on this run's
    # resource. `docker network create` FAILS on a pre-existing name, so a zero exit already
    # proves a fresh owned network; a failed create does not enter the removal set. (A named
    # volume, whose create SUCCEEDS on a pre-existing name, cannot prove ownership this way and
    # uses New-OwnedVolume instead.)
    param([Parameter(Mandatory)][ValidateSet('network')][string]$Kind, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$CreateArguments)
    $result = Invoke-FixtureDocker -Arguments $CreateArguments -AllowFailure
    if ($result.ExitCode -ne 0) { return [pscustomobject]@{ Ok = $false; Id = $null; Record = $null; Diagnostics = "$Kind create failed: $($result.Output)" } }
    $id = Get-DockerStdoutId -Output $result.Output
    if ([string]::IsNullOrWhiteSpace($id)) { return [pscustomobject]@{ Ok = $false; Id = $null; Record = $null; Diagnostics = "$Kind create returned no id: $($result.Output)" } }
    return [pscustomobject]@{ Ok = $true; Id = $id; Record = @{ kind = $Kind; name = $Name; id = $id }; Diagnostics = "$Kind created: $id" }
}

function New-OwnedVolume {
    # A named volume is the one docker resource whose `create` SUCCEEDS on a pre-existing name,
    # so ownership cannot be inferred from a zero exit, and a failed `inspect` is NOT absence.
    # Prove freshness from an AUTHORITATIVE inventory: a SUCCESSFUL `docker volume ls` whose
    # names do not include this one (Get-VolumeFreshness) is real absence; a collision or a
    # failed inventory refuses outright - never mounted, never entered into the removal set.
    # After creating, an authoritative post-create list must show the name present.
    param([Parameter(Mandatory)][string]$Name)
    $before = Invoke-FixtureDocker -Arguments @('volume', 'ls', '--format', '{{.Name}}') -AllowFailure
    $names = @(($before.Output -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $freshness = Get-VolumeFreshness -ListSucceeded ($before.ExitCode -eq 0) -VolumeNames $names -Name $Name
    if (-not $freshness.Fresh) { return [pscustomobject]@{ Ok = $false; Id = $null; Record = $null; Diagnostics = "volume '$Name' not provably fresh: $($freshness.State)" } }
    $create = Invoke-FixtureDocker -Arguments @('volume', 'create', $Name) -AllowFailure
    if ($create.ExitCode -ne 0) { return [pscustomobject]@{ Ok = $false; Id = $null; Record = $null; Diagnostics = "volume create failed: $($create.Output)" } }
    $id = Get-DockerStdoutId -Output $create.Output
    if ($id -cne $Name) { return [pscustomobject]@{ Ok = $false; Id = $null; Record = $null; Diagnostics = "volume create returned an unexpected name '$id' (wanted '$Name')" } }
    $after = Invoke-FixtureDocker -Arguments @('volume', 'ls', '--format', '{{.Name}}') -AllowFailure
    $afterNames = @(($after.Output -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($after.ExitCode -ne 0 -or ($Name -cnotin $afterNames)) { return [pscustomobject]@{ Ok = $false; Id = $null; Record = $null; Diagnostics = 'volume not present in the authoritative inventory after create' } }
    return [pscustomobject]@{ Ok = $true; Id = $id; Record = @{ kind = 'volume'; name = $Name; id = $id }; Diagnostics = "fresh owned volume: $id" }
}

function New-OwnedContainer {
    # `docker create` returns the container id on stdout. Record the ACTUAL id BEFORE start, so
    # a created-but-unstarted container is still disposed and a name collision (a non-zero
    # create) never enters the removal set by name. Create and start are deliberately separate.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$CreateArguments)
    $result = Invoke-FixtureDocker -Arguments $CreateArguments -AllowFailure
    if ($result.ExitCode -ne 0) { return [pscustomobject]@{ Ok = $false; Id = $null; Record = $null; Diagnostics = "create failed: $($result.Output)" } }
    $id = Get-DockerStdoutId -Output $result.Output
    if ($id -notmatch '^[0-9a-f]{12,64}$') { return [pscustomobject]@{ Ok = $false; Id = $null; Record = $null; Diagnostics = "create returned no container id: $($result.Output)" } }
    return [pscustomobject]@{ Ok = $true; Id = $id; Record = @{ kind = 'container'; name = $Name; id = $id }; Diagnostics = "created: $id" }
}

function Start-OwnedContainer {
    # Start a container already recorded as owned by its id. A failed start leaves the id in the
    # removal set (the container exists), so the caller never has to re-derive ownership.
    param([Parameter(Mandatory)][string]$Id)
    $result = Invoke-FixtureDocker -Arguments @('start', $Id) -AllowFailure
    return [pscustomobject]@{ Ok = ($result.ExitCode -eq 0); Diagnostics = $result.Output }
}

function Get-FixtureTopologyObservation {
    # Inspect both owned containers and gate the fixture on checkable facts (Get-FixtureGate):
    # each must be running, on the owned network and the pinned image; the broker must expose
    # NO host port; HA must be bound to EXACTLY 127.0.0.1:8123. Returns the per-container facts
    # and the gate result; a topology string alone is never the observation.
    param([Parameter(Mandatory)][string]$BrokerId, [Parameter(Mandatory)][string]$HaId, [Parameter(Mandatory)][string]$Network, [Parameter(Mandatory)][string]$BrokerImage, [Parameter(Mandatory)][string]$HaImage)
    $brokerInspect = (Invoke-FixtureDocker -Arguments @('inspect', $BrokerId) -AllowFailure).Output
    $haInspect = (Invoke-FixtureDocker -Arguments @('inspect', $HaId) -AllowFailure).Output
    $broker = Get-ContainerTopology -InspectJson $brokerInspect -OwnedNetwork $Network -ExpectedImageRef $BrokerImage
    $ha = Get-ContainerTopology -InspectJson $haInspect -OwnedNetwork $Network -ExpectedImageRef $HaImage
    $gate = Get-FixtureGate -Broker $broker -Ha $ha
    return [ordered]@{
        broker = [ordered]@{ id = $broker.Id; running = [bool](Get-CaptureProp $broker 'Running'); attachedToOwnedNetwork = [bool](Get-CaptureProp $broker 'AttachedToOwnedNetwork'); hostPortBindings = @($broker.HostPortBindings); imageRefMatches = [bool](Get-CaptureProp $broker 'ImageRefMatches') }
        ha = [ordered]@{ id = $ha.Id; running = [bool](Get-CaptureProp $ha 'Running'); attachedToOwnedNetwork = [bool](Get-CaptureProp $ha 'AttachedToOwnedNetwork'); hostPortBindings = @($ha.HostPortBindings); imageRefMatches = [bool](Get-CaptureProp $ha 'ImageRefMatches') }
        gate = [ordered]@{ ready = $gate.Ready; reasons = @($gate.Reasons) }
        ownedNetwork = $Network
    }
}

function Wait-HaOnboardingReady {
    param([int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try { $null = Invoke-HaRest -Method Get -Path '/api/onboarding' -TimeoutSec 5; return $true } catch { Start-Sleep -Milliseconds 750 }
    }
    return $false
}

function Get-HaToken {
    param([Parameter(Mandatory)][string]$ClientId, [Parameter(Mandatory)][string]$Code)
    $body = "client_id=$([uri]::EscapeDataString($ClientId))&code=$([uri]::EscapeDataString($Code))&grant_type=authorization_code"
    return [string](Get-CaptureProp (Invoke-HaRest -Method Post -Path '/auth/token' -Body $body -ContentType 'application/x-www-form-urlencoded') 'access_token')
}

function Get-AuthenticatedUserId {
    # The supported path for the authenticated user id is the WebSocket auth/current_user
    # command. An empty result is returned to the caller to reject, never defaulted.
    param([Parameter(Mandatory)][string]$Token)
    $response = Invoke-HaWsCommand -Token $Token -Command @{ id = 1; type = 'auth/current_user' }
    return [string](Get-CaptureProp $response.Result 'id')
}

function Complete-HaOnboarding {
    # Supported onboarding for HA Core 2026.9.x: create the owner, exchange the code for a
    # token, finish the remaining steps, then read the id over auth/current_user. Never a
    # fabricated user.
    param([Parameter(Mandatory)][string]$Nonce)
    $clientId = "$script:HaBaseUrl/"
    $user = Invoke-HaRest -Method Post -Path '/api/onboarding/users' -Body @{
        client_id = $clientId; name = "Principal A $Nonce"; username = "principal_a_$Nonce"
        password = ([guid]::NewGuid().ToString('N') + 'Aa1!'); language = 'en'
    }
    $token = Get-HaToken -ClientId $clientId -Code ([string](Get-CaptureProp $user 'auth_code'))
    foreach ($step in @('core_config', 'analytics')) { try { $null = Invoke-HaRest -Method Post -Path "/api/onboarding/$step" -Token $token } catch { } }
    return [pscustomobject]@{ Token = $token; UserId = (Get-AuthenticatedUserId -Token $token); Label = 'principalA' }
}

function New-SyntheticPrincipalB {
    # A second wholly synthetic principal, created over the owner WebSocket and logged in for
    # its own token. Each WebSocket result is validated; an unexpected shape throws with
    # structured detail so the caller reports a fixture failure rather than inventing identity.
    param([Parameter(Mandatory)][string]$OwnerToken, [Parameter(Mandatory)][string]$Nonce)
    $username = "principal_b_$Nonce"; $password = ([guid]::NewGuid().ToString('N') + 'Bb2!')
    $session = Connect-HaWs -Token $OwnerToken -TimeoutSec 15
    $userId = ''
    try {
        Send-WsMessage $session.Ws $session.Cts.Token @{ id = 1; type = 'config/auth/create'; name = "Principal B $Nonce" }
        $created = Receive-WsMessage $session.Ws $session.Cts.Token
        if (-not [bool](Get-CaptureProp $created 'success')) { throw "config/auth/create failed: $((Get-CaptureProp $created 'error') | ConvertTo-Json -Compress)" }
        $userId = [string](Get-CaptureProp (Get-CaptureProp (Get-CaptureProp $created 'result') 'user') 'id')
        if ([string]::IsNullOrWhiteSpace($userId)) { throw 'config/auth/create returned no user id' }
        Send-WsMessage $session.Ws $session.Cts.Token @{ id = 2; type = 'config/auth_provider/homeassistant/create'; user_id = $userId; username = $username; password = $password }
        $provider = Receive-WsMessage $session.Ws $session.Cts.Token
        if (-not [bool](Get-CaptureProp $provider 'success')) { throw "auth_provider create failed: $((Get-CaptureProp $provider 'error') | ConvertTo-Json -Compress)" }
    }
    finally { Close-Ws $session.Ws; $session.Cts.Dispose() }

    $clientId = "$script:HaBaseUrl/"
    $flow = Invoke-HaRest -Method Post -Path '/auth/login_flow' -Body @{ client_id = $clientId; handler = @('homeassistant', $null); redirect_uri = $clientId }
    $step = Invoke-HaRest -Method Post -Path "/auth/login_flow/$([string](Get-CaptureProp $flow 'flow_id'))" -Body @{ username = $username; password = $password; client_id = $clientId }
    $code = [string](Get-CaptureProp $step 'result')
    if ([string]::IsNullOrWhiteSpace($code)) { throw "principalB login did not return an authorization code (step type: $((Get-CaptureProp $step 'type')))" }
    return [pscustomobject]@{ Token = (Get-HaToken -ClientId $clientId -Code $code); UserId = $userId; Label = 'principalB' }
}

function Set-MqttConfigEntry {
    # Supported MQTT setup is a config entry via the config flow, never obsolete YAML. Returns
    # a structured result with the flow diagnostics; an unexpected step is reported, not
    # guessed around.
    param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$BrokerHost)
    try {
        $flow = Invoke-HaRest -Method Post -Path '/api/config/config_entries/flow' -Token $Token -Body @{ handler = 'mqtt'; show_advanced_options = $false }
        $flowId = [string](Get-CaptureProp $flow 'flow_id')
        if (-not $flowId) { return [pscustomobject]@{ Configured = $false; Diagnostics = "no flow_id; type=$((Get-CaptureProp $flow 'type'))" } }
        $result = Invoke-HaRest -Method Post -Path "/api/config/config_entries/flow/$flowId" -Token $Token -Body @{ broker = $BrokerHost; port = 1883 }
        $type = [string](Get-CaptureProp $result 'type')
        for ($i = 0; $i -lt 2 -and $type -eq 'form'; $i++) {
            $result = Invoke-HaRest -Method Post -Path "/api/config/config_entries/flow/$([string](Get-CaptureProp $result 'flow_id'))" -Token $Token -Body @{}
            $type = [string](Get-CaptureProp $result 'type')
        }
        return [pscustomobject]@{ Configured = ($type -eq 'create_entry'); Diagnostics = "final type=$type; errors=$((Get-CaptureProp $result 'errors') | ConvertTo-Json -Compress)" }
    }
    catch { return [pscustomobject]@{ Configured = $false; Diagnostics = "exception: $($_.Exception.Message)" } }
}

function Publish-OptimisticTextDiscovery {
    # Publish discovery for an optimistic text entity (command_topic, NO state_topic) via HA's
    # own mqtt.publish, then resolve the ACTUAL entity id from the registry by the fixture's
    # unique_id - never a name guess, because HA derives ids from device/entity naming.
    param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Nonce)
    $uniqueId = "commit_probe_$Nonce"
    $commandTopic = "cc/$Nonce/commit/set"
    $config = @{
        name = "Commit Probe $Nonce"; unique_id = $uniqueId; command_topic = $commandTopic
        device = @{ identifiers = @("cc_probe_$Nonce"); name = "Commit Probe $Nonce" }
    } | ConvertTo-Json -Compress
    $null = Invoke-HaRest -Method Post -Path '/api/services/mqtt/publish' -Token $Token -Body @{ topic = "homeassistant/text/$uniqueId/config"; payload = $config; retain = $true; qos = 0 }

    $deadline = (Get-Date).AddSeconds([Math]::Max(10, $HandshakeTimeoutSeconds))
    while ((Get-Date) -lt $deadline) {
        $registry = Invoke-HaWsCommand -Token $Token -Command @{ id = 1; type = 'config/entity_registry/list' } -TimeoutSec 10
        $match = @($registry.Result | Where-Object { ([string](Get-CaptureProp $_ 'unique_id')) -ceq $uniqueId -and ([string](Get-CaptureProp $_ 'platform')) -ceq 'mqtt' })
        if ($match.Count -eq 1) {
            $entityId = [string](Get-CaptureProp $match[0] 'entity_id')
            if ($entityId) { return [pscustomobject]@{ EntityId = $entityId; CommandTopic = $commandTopic; UniqueId = $uniqueId } }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Start-CommandTopicObserver {
    # Observe the raw command-topic payload from inside the owned broker. `docker exec -t`
    # allocates a PTY, which is essential, not cosmetic: the pinned Mosquitto v2.0.22 client's
    # my_log_callback is printf("%s\n", str) with no fflush, and print_message likewise, so
    # under a REDIRECTED (non-TTY) stdout the C runtime fully block-buffers and the handshake
    # lines would not reach the file until the buffer fills or the process exits - which, with
    # -C 1, is only after the payload arrives, so a pre-commit readiness check could never see
    # a SUBACK. A PTY makes stdio line-buffered, so each handshake line is observable AS IT IS
    # EMITTED, before the commit. (Alpine/BusyBox has no stdbuf, so the PTY is the supported
    # flushing contract.) The PTY also merges stderr into this stream; readiness (CONNACK /
    # granted SUBACK) and the nonce-bound -F payload are still unambiguous on it. -C 1 exits
    # after the first message; -W (the alarm) covers the whole case so it cannot fire early.
    param([Parameter(Mandatory)][string]$BrokerName, [Parameter(Mandatory)][string]$Topic, [Parameter(Mandatory)][string]$Sentinel, [int]$LifetimeSec)
    $outFile = [IO.Path]::GetTempFileName(); $errFile = [IO.Path]::GetTempFileName()
    $arguments = @('exec', '-t', $BrokerName, 'mosquitto_sub', '-h', 'localhost', '-t', $Topic, '-C', '1', '-W', [string]$LifetimeSec, '-d', '-F', "$Sentinel%p")
    $process = Start-Process -FilePath 'docker' -ArgumentList $arguments -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -NoNewWindow
    return [pscustomobject]@{ Process = $process; OutFile = $outFile; ErrFile = $errFile; Sentinel = $Sentinel }
}

function Wait-CommandObserverReady {
    # Return the readiness classification of the OWNED subscriber, read from its stdout debug
    # stream: ready only on a successful CONNACK AND a granted (non-128) SUBACK. A bare CONNACK,
    # a denied subscription, an early exit or a quiet timeout each come back not-ready so the
    # caller can withhold the commit rather than lose a QoS0 command to a late subscription.
    param([Parameter(Mandatory)]$Observer, [int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $readiness = Get-SubscriberReadiness -StdoutText $null
    while ((Get-Date) -lt $deadline) {
        $readiness = Get-SubscriberReadiness -StdoutText (Get-Content -LiteralPath $Observer.OutFile -Raw -ErrorAction SilentlyContinue)
        if ($readiness.Ready -or $readiness.Rejected) { return $readiness }
        if ($Observer.Process.HasExited) { return (Get-SubscriberReadiness -StdoutText (Get-Content -LiteralPath $Observer.OutFile -Raw -ErrorAction SilentlyContinue)) }
        Start-Sleep -Milliseconds 150
    }
    return $readiness
}

function Complete-CommandObserver {
    # Collect the observer's payload (parsed out of the mixed stdout stream by its sentinel),
    # exit code, whether it exited and a bounded error tail, stopping only this owned process
    # if it has not exited. A missed or broken observer is reported as such, not as a measured
    # absence; the exit/timeout/error evidence is retained in the case record.
    param([Parameter(Mandatory)]$Observer, [int]$TimeoutSec)
    $exited = $Observer.Process.WaitForExit($TimeoutSec * 1000)
    if (-not $exited) { try { Stop-Process -Id $Observer.Process.Id -Force -ErrorAction SilentlyContinue } catch { } }
    $stdout = Get-Content -LiteralPath $Observer.OutFile -Raw -ErrorAction SilentlyContinue
    # The PTY merges stderr into stdout, so the diagnostic tail is taken from the non-payload
    # lines of the merged stream (the sentinel line is the payload, parsed separately); any
    # docker-level error on the real stderr file is prepended.
    $dockerErr = (Get-Content -LiteralPath $Observer.ErrFile -Tail 2 -ErrorAction SilentlyContinue) -join ' | '
    $diagnosticLines = @(($stdout -split "`r?`n") | Where-Object { $_.Trim() -and ($_.IndexOf($Observer.Sentinel, [StringComparison]::Ordinal) -lt 0) })
    $errorTail = (@($dockerErr; ($diagnosticLines | Select-Object -Last 3)) | Where-Object { $_ }) -join ' | '
    $exitCode = if ($exited) { $Observer.Process.ExitCode } else { $null }
    Remove-Item -LiteralPath $Observer.OutFile, $Observer.ErrFile -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Payload = (Get-ObserverPayload -StdoutText $stdout -Sentinel $Observer.Sentinel); ExitCode = $exitCode; Exited = $exited; ErrorTail = $errorTail }
}

function Invoke-HaStateCapture {
    # Subscribe to state_changed, run $CommitAction, and return the first state_changed FOR THE
    # REQUESTED VALUE within a bounded observation window, keeping new_state.context and
    # event.context separate. Handshake, service and observation deadlines are separate; a
    # healthy expired window leaves StateObserved=$false (a NoEvent), while auth/subscribe/
    # disconnect/malformed faults set ObservationError. All receives and the close are bounded.
    param(
        [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$EntityId,
        [Parameter(Mandatory)][string]$RequestedValue, [Parameter(Mandatory)][scriptblock]$CommitAction,
        [int]$HandshakeTimeoutSec, [int]$ObservationTimeoutSec
    )
    $result = [ordered]@{ ServiceAccepted = $false; ServiceDetail = $null; StateObserved = $false; ObservedValue = $null; NewStateContextId = $null; NewStateContextParentId = $null; NewStateContextUserId = $null; EventContextId = $null; EventContextParentId = $null; EventContextUserId = $null; CommittedAtUtc = $null; ObservedAtUtc = $null; ObservationLatencyMs = $null; ObservationError = $null }
    $ws = $null
    try {
        $session = Connect-HaWs -Token $Token -TimeoutSec $HandshakeTimeoutSec
        $ws = $session.Ws
        try {
            Send-WsMessage $ws $session.Cts.Token @{ id = 1; type = 'subscribe_events'; event_type = 'state_changed' }
            if (-not [bool](Get-CaptureProp (Receive-WsMessage $ws $session.Cts.Token) 'success')) { $result.ObservationError = 'subscribe_failed'; return [pscustomobject]$result }
        }
        finally { $session.Cts.Dispose() }

        # Subscription is live, so the commit cannot race ahead of it.
        $commit = & $CommitAction
        $result.CommittedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        $commitClock = [Diagnostics.Stopwatch]::StartNew()
        $result.ServiceAccepted = [bool](Get-CaptureProp $commit 'Accepted')
        $result.ServiceDetail = [string](Get-CaptureProp $commit 'Detail')

        $deadline = (Get-Date).AddSeconds($ObservationTimeoutSec)
        while ((Get-Date) -lt $deadline) {
            $remaining = [Math]::Max(1, [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds))
            $receiveCts = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($remaining))
            $message = $null
            try { $message = Receive-WsMessage $ws $receiveCts.Token }
            catch [OperationCanceledException] { break }          # window expired quietly -> NoEvent
            catch { $result.ObservationError = $_.Exception.Message; break }
            finally { $receiveCts.Dispose() }

            if ((Get-CaptureProp $message 'type') -ne 'event') { continue }
            $event = Get-CaptureProp $message 'event'
            $data = Get-CaptureProp $event 'data'
            if ((Get-CaptureProp $data 'entity_id') -ne $EntityId) { continue }
            $newState = Get-CaptureProp $data 'new_state'
            $value = [string](Get-CaptureProp $newState 'state')
            if ($value -cne $RequestedValue) { continue }          # not our value; stale/unrelated - keep waiting
            $newContext = Get-CaptureProp $newState 'context'
            $eventContext = Get-CaptureProp $event 'context'
            $result.StateObserved = $true
            $result.ObservedValue = $value
            $result.ObservedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            $result.ObservationLatencyMs = [int]$commitClock.Elapsed.TotalMilliseconds
            $result.NewStateContextId = [string](Get-CaptureProp $newContext 'id')
            $result.NewStateContextParentId = [string](Get-CaptureProp $newContext 'parent_id')
            $result.NewStateContextUserId = [string](Get-CaptureProp $newContext 'user_id')
            $result.EventContextId = [string](Get-CaptureProp $eventContext 'id')
            $result.EventContextParentId = [string](Get-CaptureProp $eventContext 'parent_id')
            $result.EventContextUserId = [string](Get-CaptureProp $eventContext 'user_id')
            break
        }
    }
    catch { $result.ObservationError = $_.Exception.Message }
    finally { if ($ws) { Close-Ws $ws } }
    return [pscustomobject]$result
}

function New-CommitValue {
    # Harmless synthetic commit value: a SubmitId plus the full digest of a synthetic,
    # non-user token. No user content. Fits the 255-character text budget.
    param([Parameter(Mandatory)][string]$Nonce, [Parameter(Mandatory)][int]$Serial)
    return (@{ submitId = "PROBE-$Nonce-$('{0:D4}' -f $Serial)"; digest = (Get-CommitValueDigest -Value "synthetic-sample-$Nonce-$Serial") } | ConvertTo-Json -Compress)
}

function Save-CommitEvidence {
    param([Parameter(Mandatory)]$Evidence, [Parameter(Mandatory)][string]$Path)
    ($Evidence | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $Path -Encoding utf8
}

function Remove-Fixture {
    # Remove only the resources this run recorded as created, BY THEIR ACTUAL IDS, in order,
    # and report every failure. An entry without an ownership id is REFUSED (Get-FixtureCleanupPlan
    # surfaces it) and recorded as a failure - never removed by name, so a name collision can
    # never make this run delete a resource it did not create. Containers first (-v also drops
    # their anonymous volumes), then owned volumes, then the network, then owned files. Hosted
    # disposability never justifies hiding a cleanup failure.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Created)
    $plan = Get-FixtureCleanupPlan -Created $Created
    $removed = @(); $failures = @()
    foreach ($entry in $plan.Refused) { $failures += "$($entry.kind) '$($entry.name)': no ownership id; refused name-based removal" }
    foreach ($container in $plan.Containers) {
        $removal = Invoke-FixtureDocker -Arguments @('rm', '-f', '-v', $container.id) -AllowFailure -Accounting Cleanup
        if ($removal.ExitCode -eq 0) { $removed += "container:$($container.id)" } else { $failures += "container $($container.id): $($removal.Output)" }
    }
    foreach ($volume in $plan.Volumes) {
        $removal = Invoke-FixtureDocker -Arguments @('volume', 'rm', $volume.id) -AllowFailure -Accounting Cleanup
        if ($removal.ExitCode -eq 0) { $removed += "volume:$($volume.id)" } else { $failures += "volume $($volume.id): $($removal.Output)" }
    }
    foreach ($network in $plan.Networks) {
        $removal = Invoke-FixtureDocker -Arguments @('network', 'rm', $network.id) -AllowFailure -Accounting Cleanup
        if ($removal.ExitCode -eq 0) { $removed += "network:$($network.id)" } else { $failures += "network $($network.id): $($removal.Output)" }
    }
    foreach ($file in $plan.Files) {
        try { Remove-Item -LiteralPath $file.id -Force -ErrorAction Stop; $removed += "file:$($file.id)" } catch { $failures += "file $($file.id): $($_.Exception.Message)" }
    }
    return [ordered]@{ removed = $removed; failures = $failures }
}

function Invoke-CommitContextMeasurement {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $script:SetupRequestCount = 0; $script:CommitWriteCount = 0; $script:CleanupRequestCount = 0
    $nonce = New-CaptureNonce
    $script:HaBaseUrl = 'http://127.0.0.1:8123'
    $network = "cc-net-$nonce"; $haName = "cc-ha-$nonce"; $brokerName = "cc-mqtt-$nonce"
    $environment = @{}
    foreach ($name in @('GITHUB_ACTIONS', 'RUNNER_ENVIRONMENT')) { $environment[$name] = [string][Environment]::GetEnvironmentVariable($name) }

    $evidence = [ordered]@{
        schema = 'commit-context-capture/3'; mode = 'Measure'; startedUtc = (Get-Date).ToUniversalTime().ToString('o')
        nonce = $nonce; runStatus = 'Reserved'
        images = [ordered]@{ homeAssistant = $HaImage; mosquitto = $MosquittoImage; haPinOk = $false; mosquittoPinOk = $false }
        haServerVersion = $null; haVersionMatches = $false
        topologyIntent = "dedicated bridge network '$network'; broker '$brokerName' reached only container-to-container / via docker exec (no host port); HA '$haName' published only to 127.0.0.1:8123; ephemeral runner, synthetic secret-free fixture"
        fixture = $null
        raceCoverage = 'not exercised (serial writes only; multi-principal concurrency is a separate, unproven claim)'
        preflight = $null; principalsValid = $null; mqttDiagnostics = $null; entity = $null
        budgets = [ordered]@{ maxCommits = $MaxCommits; handshakeTimeoutSeconds = $HandshakeTimeoutSeconds; observationTimeoutSeconds = $ObservationTimeoutSeconds; jobTimeoutSeconds = $JobTimeoutSeconds }
        accounting = [ordered]@{ setupRequests = 0; commitWrites = 0; cleanupRequests = 0 }
        cases = @(); completion = $null; cleanup = $null
    }
    # Persist the reservation before any effect so an early cancellation still leaves a record.
    Save-CommitEvidence -Evidence $evidence -Path $script:EvidencePath

    # Pins first, then target, then images present - all before any network/container effect.
    $evidence.images.haPinOk = Test-ImagePinned -ImageRef $HaImage -ExpectedDigest $script:ReviewedHaDigest
    $evidence.images.mosquittoPinOk = Test-ImagePinned -ImageRef $MosquittoImage -ExpectedDigest $script:ReviewedMosquittoDigest
    $preflight = Test-DisposableTargetAllowed -Environment $environment -HaBaseUrl $script:HaBaseUrl -BrokerHost $brokerName -Nonce $nonce
    $evidence.preflight = [ordered]@{ allowed = $preflight.Allowed; reason = $preflight.Reason }
    if (-not $preflight.Allowed) { $evidence.runStatus = 'RefusedTarget'; Save-CommitEvidence -Evidence $evidence -Path $script:EvidencePath; return [pscustomobject]$evidence }
    if (-not ($evidence.images.haPinOk -and $evidence.images.mosquittoPinOk)) { $evidence.runStatus = 'RefusedTarget'; $evidence.preflight.reason = 'supplied image refs are not the reviewed immutable digests'; Save-CommitEvidence -Evidence $evidence -Path $script:EvidencePath; return [pscustomobject]$evidence }

    $created = @()
    try {
        # Separate create from start and record the ACTUAL id docker returns, so a name
        # collision never enters the removal set and a created-but-unstarted resource is still
        # disposed. The broker conf file and the HA config volume are owned too.
        $haVolume = "cc-haconfig-$nonce"
        $brokerConf = Join-Path ([IO.Path]::GetTempPath()) "mosquitto-$nonce.conf"
        @('listener 1883', 'allow_anonymous true') | Set-Content -LiteralPath $brokerConf -Encoding ascii
        $created += @{ kind = 'file'; name = $brokerConf; id = $brokerConf }

        $net = New-OwnedDockerResource -Kind 'network' -Name $network -CreateArguments @('network', 'create', $network)
        if ($net.Ok) { $created += $net.Record } else { $evidence.runStatus = 'FixtureFailure'; $evidence.fixture = [ordered]@{ error = $net.Diagnostics }; return [pscustomobject]$evidence }

        $vol = New-OwnedVolume -Name $haVolume
        if ($vol.Ok) { $created += $vol.Record } else { $evidence.runStatus = 'FixtureFailure'; $evidence.fixture = [ordered]@{ error = $vol.Diagnostics }; return [pscustomobject]$evidence }

        $broker = New-OwnedContainer -Name $brokerName -CreateArguments @('create', '--name', $brokerName, '--network', $network, '-v', "${brokerConf}:/mosquitto/config/mosquitto.conf:ro", $MosquittoImage)
        if ($broker.Ok) { $created += $broker.Record } else { $evidence.runStatus = 'FixtureFailure'; $evidence.fixture = [ordered]@{ error = $broker.Diagnostics }; return [pscustomobject]$evidence }
        $brokerStart = Start-OwnedContainer -Id $broker.Id
        if (-not $brokerStart.Ok) { $evidence.runStatus = 'FixtureFailure'; $evidence.fixture = [ordered]@{ error = "broker start failed: $($brokerStart.Diagnostics)" }; return [pscustomobject]$evidence }

        $ha = New-OwnedContainer -Name $haName -CreateArguments @('create', '--name', $haName, '--network', $network, '-p', '127.0.0.1:8123:8123', '-v', "${haVolume}:/config", $HaImage)
        if ($ha.Ok) { $created += $ha.Record } else { $evidence.runStatus = 'FixtureFailure'; $evidence.fixture = [ordered]@{ error = $ha.Diagnostics }; return [pscustomobject]$evidence }
        $haStart = Start-OwnedContainer -Id $ha.Id
        if (-not $haStart.Ok) { $evidence.runStatus = 'FixtureFailure'; $evidence.fixture = [ordered]@{ error = "HA start failed: $($haStart.Diagnostics)" }; return [pscustomobject]$evidence }

        # Identity/topology as a GATE over checkable facts, not a description string: both
        # containers running, on the owned network and the pinned image; the broker exposing NO
        # host port; HA bound to exactly 127.0.0.1:8123 (zero bindings fails).
        $evidence.fixture = Get-FixtureTopologyObservation -BrokerId $broker.Id -HaId $ha.Id -Network $network -BrokerImage $MosquittoImage -HaImage $HaImage
        Save-CommitEvidence -Evidence $evidence -Path $script:EvidencePath
        if (-not $evidence.fixture.gate.ready) { $evidence.runStatus = 'FixtureFailure'; return [pscustomobject]$evidence }

        if (-not (Wait-HaOnboardingReady -TimeoutSec ([Math]::Max(60, $HandshakeTimeoutSeconds * 4)))) { $evidence.runStatus = 'FixtureFailure'; return [pscustomobject]$evidence }

        $principalA = Complete-HaOnboarding -Nonce $nonce
        $principalB = New-SyntheticPrincipalB -OwnerToken $principalA.Token -Nonce $nonce
        $principalsValid = Test-PrincipalsValid -PrincipalA $principalA -PrincipalB $principalB
        $evidence.principalsValid = [ordered]@{ valid = $principalsValid.Valid; reason = $principalsValid.Reason }
        if (-not $principalsValid.Valid) { $evidence.runStatus = 'FixtureFailure'; return [pscustomobject]$evidence }

        try { $evidence.haServerVersion = [string](Get-CaptureProp (Invoke-HaRest -Method Get -Path '/api/config' -Token $principalA.Token) 'version') } catch { }
        $evidence.haVersionMatches = ($evidence.haServerVersion -ceq $script:ReviewedHaVersion)
        if (-not $evidence.haVersionMatches) { $evidence.runStatus = 'FixtureFailure'; return [pscustomobject]$evidence }

        $mqtt = Set-MqttConfigEntry -Token $principalA.Token -BrokerHost $brokerName
        $evidence.mqttDiagnostics = $mqtt.Diagnostics
        if (-not $mqtt.Configured) { $evidence.runStatus = 'Unsupported'; return [pscustomobject]$evidence }

        $entity = Publish-OptimisticTextDiscovery -Token $principalA.Token -Nonce $nonce
        if (-not $entity) { $evidence.runStatus = 'Unsupported'; return [pscustomobject]$evidence }
        $evidence.entity = [ordered]@{ entityId = $entity.EntityId; uniqueId = $entity.UniqueId; commandTopic = $entity.CommandTopic }

        $plan = @(
            @{ Case = 'changed-value-1'; Principal = $principalA; Serial = 1 }
            @{ Case = 'changed-value-2'; Principal = $principalA; Serial = 2 }
            @{ Case = 'repeat-first'; Principal = $principalA; Serial = 3 }
            @{ Case = 'repeat-same'; Principal = $principalA; Serial = 3 }
            @{ Case = 'sequential-1'; Principal = $principalA; Serial = 4 }
            @{ Case = 'sequential-2'; Principal = $principalA; Serial = 5 }
            @{ Case = 'delayed'; Principal = $principalA; Serial = 6; DelayMs = 2000 }
            @{ Case = 'cross-principal-A'; Principal = $principalA; Serial = 7 }
            @{ Case = 'cross-principal-B'; Principal = $principalB; Serial = 8 }
        )
        $observerLifetime = $HandshakeTimeoutSeconds + $ObservationTimeoutSeconds + 5
        foreach ($step in $plan) {
            if ($script:CommitWriteCount -ge $MaxCommits) { break }
            if ($stopwatch.Elapsed.TotalSeconds -ge $JobTimeoutSeconds) { $evidence.runStatus = 'JobTimeout'; break }
            if ($step.ContainsKey('DelayMs')) { Start-Sleep -Milliseconds $step.DelayMs }
            $principal = $step.Principal
            $value = New-CommitValue -Nonce $nonce -Serial $step.Serial
            $sentinel = "CCMSG-$nonce-$('{0:D4}' -f $step.Serial)>>"

            # The command-topic subscriber must prove a GRANTED subscription (not merely a
            # CONNACK) on its own stdout before the commit; otherwise the QoS0 write is withheld
            # and the case is recorded as SubscriberNotReady, never as a measured absence.
            $observer = Start-CommandTopicObserver -BrokerName $brokerName -Topic $entity.CommandTopic -Sentinel $sentinel -LifetimeSec $observerLifetime
            $readiness = Wait-CommandObserverReady -Observer $observer -TimeoutSec ([Math]::Max(5, $HandshakeTimeoutSeconds))

            if (-not $readiness.Ready) {
                $withheld = Complete-CommandObserver -Observer $observer -TimeoutSec 5
                $evidence.cases += (New-CommitCaseRecord ([pscustomobject]@{
                            Case = $step.Case; PrincipalLabel = $principal.Label; ExpectedUserId = $principal.UserId
                            ServiceAccepted = $false; ServiceDetail = "commit withheld: command subscriber not ready ($($readiness.State))"
                            RequestedValue = $value; StateObserved = $false; ObservedValue = $null; SubscriberNotReady = $true
                            CommandPayload = $withheld.Payload; CommandSubscriberReady = $false; CommandSubscriberState = $readiness.State
                            CommandSubscriberExited = $withheld.Exited; CommandSubscriberExit = $withheld.ExitCode; CommandSubscriberError = $withheld.ErrorTail
                            ObservationError = ''
                        }))
                Save-CommitEvidence -Evidence $evidence -Path $script:EvidencePath
                continue
            }

            $capture = Invoke-HaStateCapture -Token $principal.Token -EntityId $entity.EntityId -RequestedValue $value -HandshakeTimeoutSec $HandshakeTimeoutSeconds -ObservationTimeoutSec $ObservationTimeoutSeconds -CommitAction {
                try { $null = Invoke-HaRest -Method Post -Path '/api/services/text/set_value' -Token $principal.Token -Body @{ entity_id = $entity.EntityId; value = $value } -Accounting Commit; [pscustomobject]@{ Accepted = $true; Detail = 'HTTP 200' } }
                catch { [pscustomobject]@{ Accepted = $false; Detail = $_.Exception.Message } }
            }
            $observed = Complete-CommandObserver -Observer $observer -TimeoutSec $ObservationTimeoutSeconds

            $evidence.cases += (New-CommitCaseRecord ([pscustomobject]@{
                        Case = $step.Case; PrincipalLabel = $principal.Label; ExpectedUserId = $principal.UserId
                        ServiceAccepted = $capture.ServiceAccepted; ServiceDetail = $capture.ServiceDetail
                        RequestedValue = $value; StateObserved = $capture.StateObserved; ObservedValue = $capture.ObservedValue
                        NewStateContextId = $capture.NewStateContextId; NewStateContextParentId = $capture.NewStateContextParentId; NewStateContextUserId = $capture.NewStateContextUserId
                        EventContextId = $capture.EventContextId; EventContextParentId = $capture.EventContextParentId; EventContextUserId = $capture.EventContextUserId
                        CommittedAtUtc = $capture.CommittedAtUtc; ObservedAtUtc = $capture.ObservedAtUtc; ObservationLatencyMs = $capture.ObservationLatencyMs
                        CommandPayload = $observed.Payload; CommandSubscriberReady = $true; CommandSubscriberState = $readiness.State
                        CommandSubscriberExited = $observed.Exited; CommandSubscriberExit = $observed.ExitCode; CommandSubscriberError = $observed.ErrorTail
                        ObservationError = $capture.ObservationError
                    }))
            Save-CommitEvidence -Evidence $evidence -Path $script:EvidencePath   # survive a later cancellation
        }

        # Completed only when every declared case produced a sound observation; a short
        # inventory (MaxCommits reached early) or a withheld/broken case is a bounded
        # Incomplete, never a completed empty or partial surrogate.
        $completion = Get-RunCompletion -DeclaredCases @($plan | ForEach-Object { $_.Case }) -Cases $evidence.cases
        $evidence.completion = [ordered]@{ completed = $completion.Completed; reason = $completion.Reason }
        if ($evidence.runStatus -eq 'Reserved') { $evidence.runStatus = if ($completion.Completed) { 'Completed' } else { 'Incomplete' } }
    }
    catch {
        $evidence.runStatus = 'FixtureFailure'
        $evidence.cases += [ordered]@{ case = 'fixture'; outcome = 'FixtureFailure'; observationError = $_.Exception.Message }
    }
    finally {
        $evidence.cleanup = (Remove-Fixture -Created $created)
        $evidence.accounting.setupRequests = $script:SetupRequestCount
        $evidence.accounting.commitWrites = $script:CommitWriteCount
        $evidence.accounting.cleanupRequests = $script:CleanupRequestCount
        $stopwatch.Stop()
        Save-CommitEvidence -Evidence $evidence -Path $script:EvidencePath
    }
    return [pscustomobject]$evidence
}

# ----------------------------------------------------------------------------------------
# Entry point.
# ----------------------------------------------------------------------------------------

switch ($Mode) {
    'SelfTest' { exit (Invoke-CommitContextSelfTest) }
    'Measure' {
        $script:EvidencePath = Join-Path (Get-Location) 'commit-context-evidence.json'
        $evidence = Invoke-CommitContextMeasurement
        Write-Host "runStatus: $($evidence.runStatus); cases: $(@($evidence.cases).Count); commitWrites: $($evidence.accounting.commitWrites); evidence: $script:EvidencePath"
        $cleanupFailures = @(Get-CaptureProp $evidence.cleanup 'failures')
        if ($cleanupFailures.Count -gt 0) { Write-Host "CLEANUP FAILURES: $($cleanupFailures -join '; ')" -ForegroundColor Red; exit 3 }
        if ($evidence.runStatus -ne 'Completed') { Write-Host "run did not complete a measurement (status $($evidence.runStatus))" -ForegroundColor Yellow; exit 2 }
        exit 0
    }
}
