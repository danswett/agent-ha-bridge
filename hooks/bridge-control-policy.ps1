#Requires -Version 7.0

function Get-BridgeControlEligibility {
    <#
        An unwired, read-only component decision, not authentication or admission.
        The caller must supply principal and target facts from a future verified
        adapter. Nothing in the command can manufacture those facts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$ConfigurationContext,
        [Parameter(Mandatory)][AllowNull()][object]$AssumedPrincipal,
        [Parameter(Mandatory)][AllowNull()][object]$AssumedTarget,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object]$CommandBytes,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object]$ContentBytes,
        [Parameter(Mandatory)][AllowNull()][object]$Now,
        [Parameter(Mandatory)][AllowNull()][object]$Limits
    )

    Set-StrictMode -Version Latest
    $requestId = $null
    $requiredCapability = $null
    $commandDigest = $null
    $contentDigest = $null
    $phase = 'Inputs'
    $configurationDocument = $null
    $commandDocument = $null

    function New-ControlResult {
        param([string]$Eligibility, [string]$Reason, [string]$DiagnosticType = '')
        [pscustomobject][ordered]@{
            Kind               = 'ControlCommandEligibility'
            Version            = 1
            Eligibility        = $Eligibility
            Reason             = $Reason
            RequiredCapability = $requiredCapability
            RequestId          = $requestId
            CommandSha256      = $commandDigest
            ContentSha256      = $contentDigest
            DiagnosticPhase    = $phase
            DiagnosticType     = $DiagnosticType
        }
    }

    function Stop-ControlEvaluation {
        param([string]$Reason, [string]$Eligibility = 'Ineligible')
        $failure = [IO.InvalidDataException]::new('Control eligibility validation refused the input.')
        $failure.Data['BridgeControlReason'] = $Reason
        $failure.Data['BridgeControlEligibility'] = $Eligibility
        throw $failure
    }

    function Assert-ControlMap {
        param($Value, [string[]]$Required, [string[]]$Optional = @(), [string]$Reason)
        if ($Value -isnot [hashtable]) { Stop-ControlEvaluation $Reason }
        $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($key in @($Required) + @($Optional)) { [void]$allowed.Add($key) }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($key in $Value.Keys) {
            if ($key -isnot [string] -or -not $allowed.Contains($key)) { Stop-ControlEvaluation $Reason }
            [void]$seen.Add($key)
        }
        foreach ($key in $Required) {
            if (-not $seen.Contains($key)) { Stop-ControlEvaluation $Reason }
        }
    }

    function Assert-ControlObject {
        param($Value, [string[]]$Required, [string[]]$Optional = @(), [string]$Reason)
        if ($Value.ValueKind -ne [Text.Json.JsonValueKind]::Object) { Stop-ControlEvaluation $Reason }
        $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($key in @($Required) + @($Optional)) { [void]$allowed.Add($key) }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Value.EnumerateObject()) {
            if (-not $seen.Add($property.Name) -or -not $allowed.Contains($property.Name)) {
                Stop-ControlEvaluation $Reason
            }
        }
        foreach ($key in $Required) {
            if (-not $seen.Contains($key)) { Stop-ControlEvaluation $Reason }
        }
    }

    function Get-ControlString {
        param($Value, [string]$Reason, [switch]$Json, [switch]$Path)
        if ($Json) {
            if ($Value.ValueKind -ne [Text.Json.JsonValueKind]::String) { Stop-ControlEvaluation $Reason }
            $Value = $Value.GetString()
        }
        $maximum = if ($Path) { 32768 } else { 256 }
        if ($Value -isnot [string] -or $Value.Length -eq 0 -or $Value.Length -gt $maximum -or
            -not [StringComparer]::Ordinal.Equals($Value, $Value.Trim()) -or $Value -match '\p{Cc}') {
            Stop-ControlEvaluation $Reason
        }
        if (-not $Path -and $Value -match '[*?\[\]]') { Stop-ControlEvaluation $Reason }
        $Value
    }

    function Get-ControlInteger {
        param($Value, [long]$Minimum, [long]$Maximum, [string]$Reason, [switch]$Json)
        if ($Json) {
            if ($Value.ValueKind -ne [Text.Json.JsonValueKind]::Number -or
                $Value.GetRawText() -cnotmatch '^(0|[1-9][0-9]*)$') { Stop-ControlEvaluation $Reason }
            $number = 0L
            if (-not $Value.TryGetInt64([ref]$number)) { Stop-ControlEvaluation $Reason }
        }
        else {
            if ($Value -isnot [int] -and $Value -isnot [long]) { Stop-ControlEvaluation $Reason }
            $number = [long]$Value
        }
        if ($number -lt $Minimum -or $number -gt $Maximum) { Stop-ControlEvaluation $Reason }
        $number
    }

    function Test-ControlOrdinalValue {
        param([string]$Value, [string[]]$Allowed)
        foreach ($item in $Allowed) {
            if ([StringComparer]::Ordinal.Equals($Value, $item)) { return $true }
        }
        $false
    }

    function Get-ControlLimits {
        param($Value, [string]$Reason, [switch]$Json)
        $keys = @('maxCommandBytes', 'maxContentBytes', 'maxLifetimeSeconds', 'maxFutureSkewSeconds')
        if ($Json) { Assert-ControlObject $Value -Required $keys -Reason $Reason }
        else {
            $keys = @('maxConfigurationBytes') + $keys
            Assert-ControlMap $Value -Required $keys -Reason $Reason
        }
        $result = @{}
        foreach ($key in $keys) {
            $minimum = if ($key -eq 'maxFutureSkewSeconds') { 0L } else { 1L }
            $maximum = switch ($key) {
                'maxLifetimeSeconds' { 86400L }
                'maxFutureSkewSeconds' { 300L }
                default { 16777216L }
            }
            $raw = if ($Json) { $Value.GetProperty($key) } else { $Value[$key] }
            $result[$key] = Get-ControlInteger $raw -Minimum $minimum -Maximum $maximum -Reason $Reason -Json:$Json
        }
        $result
    }

    function Assert-ControlVersion {
        param($Value, [string]$Reason)
        if ($Value.ValueKind -ne [Text.Json.JsonValueKind]::Number -or $Value.GetRawText() -cne '1') {
            Stop-ControlEvaluation $Reason
        }
    }

    function Get-ControlTime {
        param($Value, [string]$Reason, [switch]$Json)
        $text = Get-ControlString $Value -Reason $Reason -Json:$Json
        if ($text -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{7}Z$') {
            Stop-ControlEvaluation $Reason
        }
        $instant = [DateTimeOffset]::MinValue
        $style = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
        if (-not [DateTimeOffset]::TryParseExact($text, "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
                [Globalization.CultureInfo]::InvariantCulture, $style, [ref]$instant)) {
            Stop-ControlEvaluation $Reason
        }
        [pscustomobject]@{ Text = $text; Instant = $instant }
    }

    function Get-ControlScopeKeys {
        param([string]$Capability)
        switch -CaseSensitive ($Capability) {
            'read' { 'installationId'; 'machineId'; 'client'; 'sessionId' }
            'reply' { 'installationId'; 'machineId'; 'client'; 'sessionId' }
            'launch' { 'installationId'; 'machineId'; 'client'; 'workspaceId' }
            'update' { 'installationId'; 'machineId' }
            default { Stop-ControlEvaluation 'PolicyInvalid' }
        }
    }

    function Get-ControlTargetKeys {
        param([string]$Action)
        switch -CaseSensitive ($Action) {
            'session.read' { 'installationId'; 'machineId'; 'client'; 'sessionId' }
            'session.reply' { 'installationId'; 'machineId'; 'client'; 'sessionId'; 'processId'; 'processStartedAtUtc' }
            'session.launch' { 'installationId'; 'machineId'; 'client'; 'workspaceId'; 'launchConfigurationSha256'; 'permissionMode' }
            'installation.update' { 'installationId'; 'machineId'; 'releaseId'; 'artifactSha256' }
            default { Stop-ControlEvaluation 'UnsupportedAction' }
        }
    }

    function Get-ControlTarget {
        param($Value, [string[]]$Keys, [string]$Reason, [switch]$Json)
        if ($Json) { Assert-ControlObject $Value -Required $Keys -Reason $Reason }
        else { Assert-ControlMap $Value -Required $Keys -Reason $Reason }
        $result = @{}
        foreach ($key in $Keys) {
            $raw = if ($Json) { $Value.GetProperty($key) } else { $Value[$key] }
            if ($key -eq 'processId') {
                $result[$key] = Get-ControlInteger $raw -Minimum 1 -Maximum ([int]::MaxValue) -Reason $Reason -Json:$Json
                continue
            }
            $text = Get-ControlString $raw -Reason $Reason -Json:$Json
            switch -CaseSensitive ($key) {
                'sessionId' {
                    if ($text -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
                        $text -ceq '00000000-0000-0000-0000-000000000000') { Stop-ControlEvaluation $Reason }
                }
                'client' {
                    if (-not (Test-ControlOrdinalValue $text @('copilot', 'claude', 'codex'))) { Stop-ControlEvaluation $Reason }
                }
                'processStartedAtUtc' { [void](Get-ControlTime $text -Reason $Reason) }
                'permissionMode' {
                    if (-not [StringComparer]::Ordinal.Equals($text, 'ask')) { Stop-ControlEvaluation 'UnsupportedModifier' }
                }
                { $_ -in @('launchConfigurationSha256', 'artifactSha256') } {
                    if ($text -cnotmatch '^[0-9a-f]{64}$') { Stop-ControlEvaluation $Reason }
                }
            }
            $result[$key] = $text
        }
        $result
    }

    function Read-ControlConfigurationBytes {
        param([string]$Path, [long]$Maximum)
        $guard = Get-Command -Name Assert-BridgeTestPath -CommandType Function -ErrorAction SilentlyContinue
        if ($guard) { Assert-BridgeTestPath -Path $Path }
        elseif ($env:AGENT_HA_BRIDGE_OFFLINE_TEST -eq '1' -or $env:AGENT_HA_BRIDGE_TEST_ROOT -or
            $env:AGENT_HA_BRIDGE_TEST_ID -or
            @(Get-PSCallStack | Where-Object { $_.ScriptName -match '[\\/]test-[^\\/]+\.ps1$' }).Count -gt 0) {
            $failure = [InvalidOperationException]::new('The existing test path guard must be loaded before a configuration read.')
            $failure.Data['BridgeTestWriteBlocked'] = $true
            throw $failure
        }

        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $length = $stream.Length
            if ($length -gt $Maximum) { Stop-ControlEvaluation 'ConfigurationTooLarge' }
            if ($length -eq 0) { Stop-ControlEvaluation 'ConfigurationEmpty' 'Unavailable' }
            $bytes = [byte[]]::new([int]$length)
            $offset = 0
            while ($offset -lt $bytes.Length) {
                $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
                if ($read -eq 0) { Stop-ControlEvaluation 'ConfigurationChangedDuringRead' 'Unavailable' }
                $offset += $read
            }
            if ($stream.ReadByte() -ne -1) { Stop-ControlEvaluation 'ConfigurationChangedDuringRead' 'Unavailable' }
            Write-Output -NoEnumerate $bytes
        }
        finally { $stream.Dispose() }
    }

    function Get-ControlSha256 {
        param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try { ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
        finally { $algorithm.Dispose() }
    }

    try {
        $callerLimits = Get-ControlLimits $Limits -Reason 'LimitsInvalid'
        if ($CommandBytes -isnot [byte[]] -or $ContentBytes -isnot [byte[]]) {
            Stop-ControlEvaluation 'ByteBufferRequired'
        }
        if ($CommandBytes.Length -eq 0) { Stop-ControlEvaluation 'CommandEmpty' }
        if ($CommandBytes.LongLength -gt $callerLimits.maxCommandBytes) { Stop-ControlEvaluation 'CommandTooLarge' }
        if ($ContentBytes.LongLength -gt $callerLimits.maxContentBytes) { Stop-ControlEvaluation 'ContentTooLarge' }
        if ($Now -isnot [DateTimeOffset]) { Stop-ControlEvaluation 'ClockInvalid' }

        Assert-ControlMap $ConfigurationContext -Required @('configPath', 'installationId', 'machineId') -Reason 'ConfigurationContextInvalid'
        $configurationPath = Get-ControlString $ConfigurationContext.configPath -Reason 'ConfigurationContextInvalid' -Path
        if (-not [IO.Path]::IsPathFullyQualified($configurationPath)) { Stop-ControlEvaluation 'ConfigurationPathNotAbsolute' }
        $installationId = Get-ControlString $ConfigurationContext.installationId -Reason 'ConfigurationContextInvalid'
        $machineId = Get-ControlString $ConfigurationContext.machineId -Reason 'ConfigurationContextInvalid'

        if ($null -eq $AssumedPrincipal) { Stop-ControlEvaluation 'PrincipalUnavailable' 'Unavailable' }
        Assert-ControlMap $AssumedPrincipal -Required @('issuer', 'subject') -Reason 'PrincipalContextInvalid'
        $issuer = Get-ControlString $AssumedPrincipal.issuer -Reason 'PrincipalContextInvalid'
        $subject = Get-ControlString $AssumedPrincipal.subject -Reason 'PrincipalContextInvalid'
        if ($null -eq $AssumedTarget) { Stop-ControlEvaluation 'TargetUnavailable' 'Unavailable' }

        $encoding = [Text.UTF8Encoding]::new($false, $true)
        $options = [Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = 32
        $options.AllowTrailingCommas = $false
        $options.CommentHandling = [Text.Json.JsonCommentHandling]::Disallow

        $phase = 'ConfigurationRead'
        $configurationBytes = Read-ControlConfigurationBytes $configurationPath -Maximum $callerLimits.maxConfigurationBytes
        $phase = 'ConfigurationUtf8'
        $configurationText = $encoding.GetString($configurationBytes)
        $phase = 'ConfigurationJson'
        $configurationDocument = [Text.Json.JsonDocument]::Parse($configurationText, $options)
        $root = $configurationDocument.RootElement
        if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object) { Stop-ControlEvaluation 'PolicyInvalid' }
        $policyCount = 0
        foreach ($property in $root.EnumerateObject()) {
            if ([StringComparer]::OrdinalIgnoreCase.Equals($property.Name, 'controlAuthorization')) {
                if ($property.Name -cne 'controlAuthorization') { Stop-ControlEvaluation 'PolicyInvalid' }
                $policyCount++
            }
        }
        if ($policyCount -eq 0) { Stop-ControlEvaluation 'PolicyMissing' 'Unavailable' }
        if ($policyCount -ne 1) { Stop-ControlEvaluation 'PolicyInvalid' }
        $phase = 'Policy'
        $policy = $root.GetProperty('controlAuthorization')
        Assert-ControlObject $policy -Required @('version', 'generation', 'installationId', 'machineId', 'limits', 'principals') -Reason 'PolicyInvalid'
        Assert-ControlVersion ($policy.GetProperty('version')) -Reason 'PolicyVersionUnsupported'
        $generation = Get-ControlString ($policy.GetProperty('generation')) -Reason 'PolicyInvalid' -Json
        $policyInstallation = Get-ControlString ($policy.GetProperty('installationId')) -Reason 'PolicyInvalid' -Json
        $policyMachine = Get-ControlString ($policy.GetProperty('machineId')) -Reason 'PolicyInvalid' -Json
        if (-not [StringComparer]::Ordinal.Equals($installationId, $policyInstallation) -or
            -not [StringComparer]::Ordinal.Equals($machineId, $policyMachine)) {
            Stop-ControlEvaluation 'ConfigurationBindingMismatch'
        }
        $policyLimits = Get-ControlLimits ($policy.GetProperty('limits')) -Reason 'PolicyInvalid' -Json
        $effective = @{}
        foreach ($key in $policyLimits.Keys) { $effective[$key] = [Math]::Min($policyLimits[$key], $callerLimits[$key]) }
        if ($CommandBytes.LongLength -gt $effective.maxCommandBytes) { Stop-ControlEvaluation 'CommandTooLarge' }
        if ($ContentBytes.LongLength -gt $effective.maxContentBytes) { Stop-ControlEvaluation 'ContentTooLarge' }
        # Both limit sets precede the copies. Parsing and hashing share one bounded
        # snapshot, never a parse/reserialize round trip that changes wire identity.
        $commandSnapshot = [byte[]]$CommandBytes.Clone()
        $contentSnapshot = [byte[]]$ContentBytes.Clone()

        $principals = $policy.GetProperty('principals')
        if ($principals.ValueKind -ne [Text.Json.JsonValueKind]::Array -or $principals.GetArrayLength() -gt 128) {
            Stop-ControlEvaluation 'PolicyInvalid'
        }
        $identities = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $matchingGrants = @{}
        $principalFound = $false
        foreach ($principal in $principals.EnumerateArray()) {
            Assert-ControlObject $principal -Required @('issuer', 'subject', 'grants') -Reason 'PolicyInvalid'
            $policyIssuer = Get-ControlString ($principal.GetProperty('issuer')) -Reason 'PolicyInvalid' -Json
            $policySubject = Get-ControlString ($principal.GetProperty('subject')) -Reason 'PolicyInvalid' -Json
            if (-not $identities.ContainsKey($policyIssuer)) {
                $identities[$policyIssuer] = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            }
            if (-not $identities[$policyIssuer].Add($policySubject)) { Stop-ControlEvaluation 'PolicyInvalid' }
            $matchesPrincipal = [StringComparer]::Ordinal.Equals($issuer, $policyIssuer) -and
                [StringComparer]::Ordinal.Equals($subject, $policySubject)
            $grants = $principal.GetProperty('grants')
            if ($grants.ValueKind -ne [Text.Json.JsonValueKind]::Array -or $grants.GetArrayLength() -gt 4) {
                Stop-ControlEvaluation 'PolicyInvalid'
            }
            $seenCapabilities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($grant in $grants.EnumerateArray()) {
                Assert-ControlObject $grant -Required @('capability', 'scopes') -Reason 'PolicyInvalid'
                $capability = Get-ControlString ($grant.GetProperty('capability')) -Reason 'PolicyInvalid' -Json
                if (-not (Test-ControlOrdinalValue $capability @('read', 'reply', 'launch', 'update')) -or
                    -not $seenCapabilities.Add($capability)) { Stop-ControlEvaluation 'PolicyInvalid' }
                $scopeKeys = @(Get-ControlScopeKeys $capability)
                $scopes = $grant.GetProperty('scopes')
                if ($scopes.ValueKind -ne [Text.Json.JsonValueKind]::Array -or
                    $scopes.GetArrayLength() -eq 0 -or $scopes.GetArrayLength() -gt 128) {
                    Stop-ControlEvaluation 'PolicyInvalid'
                }
                $normalizedScopes = [Collections.Generic.List[object]]::new()
                $scopeIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach ($scope in $scopes.EnumerateArray()) {
                    $normalized = Get-ControlTarget $scope -Keys $scopeKeys -Reason 'PolicyInvalid' -Json
                    if (-not [StringComparer]::Ordinal.Equals($normalized.installationId, $installationId) -or
                        -not [StringComparer]::Ordinal.Equals($normalized.machineId, $machineId)) {
                        Stop-ControlEvaluation 'PolicyInvalid'
                    }
                    # Identity strings cannot contain control characters, so NUL
                    # separates exact tuple members without an ambiguous join.
                    $scopeIdentity = [string]::Join([string][char]0, [string[]]@($scopeKeys | ForEach-Object { $normalized[$_] }))
                    if (-not $scopeIdentities.Add($scopeIdentity)) { Stop-ControlEvaluation 'PolicyInvalid' }
                    $normalizedScopes.Add($normalized)
                }
                if ($matchesPrincipal) { $matchingGrants[$capability] = $normalizedScopes.ToArray() }
            }
            if ($matchesPrincipal) { $principalFound = $true }
        }

        $phase = 'CommandUtf8'
        $commandText = $encoding.GetString($commandSnapshot)
        $phase = 'CommandJson'
        $commandDocument = [Text.Json.JsonDocument]::Parse($commandText, $options)
        $command = $commandDocument.RootElement
        $phase = 'Command'
        Assert-ControlObject $command -Required @('version', 'requestId', 'action', 'issuer', 'subject',
            'policyGeneration', 'target', 'issuedAtUtc', 'notBeforeUtc', 'expiresAtUtc', 'contentSha256') `
            -Optional @('capability') -Reason 'CommandInvalid'
        Assert-ControlVersion ($command.GetProperty('version')) -Reason 'CommandVersionUnsupported'
        $candidateId = Get-ControlString ($command.GetProperty('requestId')) -Reason 'CommandInvalid' -Json
        if ($candidateId -cnotmatch '^[0-9a-f]{32}$' -or $candidateId -ceq ('0' * 32)) { Stop-ControlEvaluation 'CommandInvalid' }
        $requestId = $candidateId
        $action = Get-ControlString ($command.GetProperty('action')) -Reason 'CommandInvalid' -Json
        if (-not (Test-ControlOrdinalValue $action @('session.read', 'session.reply', 'session.launch', 'installation.update'))) {
            Stop-ControlEvaluation 'UnsupportedAction'
        }
        $requiredCapability = switch -CaseSensitive ($action) {
            'session.read' { 'read' }
            'session.reply' { 'reply' }
            'session.launch' { 'launch' }
            'installation.update' { 'update' }
            default { Stop-ControlEvaluation 'UnsupportedAction' }
        }
        foreach ($property in $command.EnumerateObject()) {
            if ($property.Name -ceq 'capability') {
                $claimed = Get-ControlString $property.Value -Reason 'CommandInvalid' -Json
                if (-not [StringComparer]::Ordinal.Equals($claimed, $requiredCapability)) { Stop-ControlEvaluation 'CapabilityMismatch' }
            }
        }
        $claimedIssuer = Get-ControlString ($command.GetProperty('issuer')) -Reason 'CommandInvalid' -Json
        $claimedSubject = Get-ControlString ($command.GetProperty('subject')) -Reason 'CommandInvalid' -Json
        if (-not [StringComparer]::Ordinal.Equals($claimedIssuer, $issuer) -or
            -not [StringComparer]::Ordinal.Equals($claimedSubject, $subject)) { Stop-ControlEvaluation 'PrincipalBindingMismatch' }
        $claimedGeneration = Get-ControlString ($command.GetProperty('policyGeneration')) -Reason 'CommandInvalid' -Json
        if (-not [StringComparer]::Ordinal.Equals($claimedGeneration, $generation)) { Stop-ControlEvaluation 'PolicyGenerationMismatch' }

        $targetKeys = @(Get-ControlTargetKeys $action)
        $target = Get-ControlTarget ($command.GetProperty('target')) -Keys $targetKeys -Reason 'CommandTargetInvalid' -Json
        $assumed = Get-ControlTarget $AssumedTarget -Keys $targetKeys -Reason 'TargetContextInvalid'
        foreach ($key in $targetKeys) {
            $same = if ($key -eq 'processId') { $target[$key] -eq $assumed[$key] }
                else { [StringComparer]::Ordinal.Equals($target[$key], $assumed[$key]) }
            if (-not $same) { Stop-ControlEvaluation 'TargetBindingMismatch' }
        }
        if (-not [StringComparer]::Ordinal.Equals($target.installationId, $installationId) -or
            -not [StringComparer]::Ordinal.Equals($target.machineId, $machineId)) { Stop-ControlEvaluation 'TargetBindingMismatch' }
        if (-not $principalFound) { Stop-ControlEvaluation 'PrincipalNotGranted' }
        if (-not $matchingGrants.ContainsKey($requiredCapability)) { Stop-ControlEvaluation 'CapabilityNotGranted' }
        $scopeMatched = $false
        foreach ($scope in $matchingGrants[$requiredCapability]) {
            $matchesScope = $true
            foreach ($key in @(Get-ControlScopeKeys $requiredCapability)) {
                if (-not [StringComparer]::Ordinal.Equals($scope[$key], $target[$key])) { $matchesScope = $false; break }
            }
            if ($matchesScope) { $scopeMatched = $true; break }
        }
        if (-not $scopeMatched) { Stop-ControlEvaluation 'ScopeNotGranted' }

        $phase = 'Time'
        $issued = Get-ControlTime ($command.GetProperty('issuedAtUtc')) -Reason 'CommandTimeInvalid' -Json
        $notBefore = Get-ControlTime ($command.GetProperty('notBeforeUtc')) -Reason 'CommandTimeInvalid' -Json
        $expires = Get-ControlTime ($command.GetProperty('expiresAtUtc')) -Reason 'CommandTimeInvalid' -Json
        if ($notBefore.Instant -lt $issued.Instant -or $expires.Instant -le $notBefore.Instant -or
            ($expires.Instant - $issued.Instant).TotalSeconds -gt $effective.maxLifetimeSeconds) {
            Stop-ControlEvaluation 'CommandTimeInvalid'
        }
        if (($issued.Instant - $Now).TotalSeconds -gt $effective.maxFutureSkewSeconds) { Stop-ControlEvaluation 'IssuedTooFarAhead' }
        if ($expires.Instant -le $Now) { Stop-ControlEvaluation 'Expired' }
        if ($notBefore.Instant -gt $Now) { Stop-ControlEvaluation 'NotYetValid' }

        $phase = 'Content'
        $expectedDigest = Get-ControlString ($command.GetProperty('contentSha256')) -Reason 'CommandInvalid' -Json
        if ($expectedDigest -cnotmatch '^[0-9a-f]{64}$') { Stop-ControlEvaluation 'CommandInvalid' }
        $commandDigest = Get-ControlSha256 -Bytes $commandSnapshot
        $contentDigest = Get-ControlSha256 -Bytes $contentSnapshot
        if ($expectedDigest -cne $contentDigest) { Stop-ControlEvaluation 'ContentDigestMismatch' }
        if ($requiredCapability -in @('read', 'update')) {
            if ($contentSnapshot.Length -ne 0) { Stop-ControlEvaluation 'ContentNotSupported' }
        }
        else {
            $phase = 'ContentUtf8'
            $contentText = $encoding.GetString($contentSnapshot)
            if ([string]::IsNullOrWhiteSpace($contentText)) { Stop-ControlEvaluation 'ContentEmpty' }
        }
        $phase = 'Eligibility'
        New-ControlResult 'Eligible' 'EligibleUnderAssumptions'
    }
    catch {
        $failure = $_.Exception
        $guardFailure = $false
        $validationFailure = $null
        $actual = $failure
        while ($null -ne $failure) {
            if ($failure.Data['BridgeTestWriteBlocked'] -or $failure.Data['BridgeTestNetworkBlocked']) { $guardFailure = $true }
            if ($failure.Data['BridgeControlReason']) { $validationFailure = $failure }
            $actual = $failure
            $failure = $failure.InnerException
        }
        if ($guardFailure) { throw }
        if ($null -ne $validationFailure) {
            return New-ControlResult ([string]$validationFailure.Data['BridgeControlEligibility']) `
                ([string]$validationFailure.Data['BridgeControlReason'])
        }
        if ($actual -is [Text.DecoderFallbackException]) {
            return New-ControlResult 'Ineligible' 'InvalidUtf8' $actual.GetType().FullName
        }
        if ($actual -is [Text.Json.JsonException]) {
            return New-ControlResult 'Ineligible' 'InvalidJson' $actual.GetType().FullName
        }
        if ($phase -ceq 'ConfigurationRead' -and
            ($actual -is [IO.IOException] -or $actual -is [UnauthorizedAccessException] -or
             $actual -is [Security.SecurityException] -or $actual -is [NotSupportedException] -or
             $actual -is [ArgumentException])) {
            return New-ControlResult 'Unavailable' 'ConfigurationReadFailed' $actual.GetType().FullName
        }
        throw
    }
    finally {
        if ($null -ne $commandDocument) { $commandDocument.Dispose() }
        if ($null -ne $configurationDocument) { $configurationDocument.Dispose() }
    }
}
