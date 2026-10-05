#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'runner-support.ps1')
Assert-BridgeTestEnvironment -Required
. (Join-Path $PSScriptRoot '..\hooks\bridge-install-context.ps1')

$script:ControlAssertions = 0
$script:ControlCases = 0
$script:ControlCalls = 0
$script:ControlResults = @{}

function Test-ControlThat {
    param([string]$Name, [bool]$Condition)
    $script:ControlAssertions++
    if (-not $Condition) {
        Write-Host "  FAIL  $Name"
        throw [InvalidOperationException]::new('The control-policy component fixture failed; no retry.')
    }
    Write-Host "  PASS  $Name"
}

function Get-ControlFixtureHash {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function ConvertTo-ControlFixtureBytes {
    param([object]$Value, [switch]$Pretty)
    $json = ConvertTo-Json -InputObject $Value -Depth 20 -Compress:(-not $Pretty)
    Write-Output -NoEnumerate ([Text.UTF8Encoding]::new($false).GetBytes($json))
}

function Get-ControlFixtureSnapshot {
    param([string]$Root)
    $items = @(
        Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName |
            ForEach-Object {
                if ($_.PSIsContainer) {
                    [ordered]@{ Path = [IO.Path]::GetRelativePath($Root, $_.FullName); Kind = 'Directory' }
                }
                else {
                    [ordered]@{
                        Path = [IO.Path]::GetRelativePath($Root, $_.FullName)
                        Kind = 'File'
                        Bytes = $_.Length
                        Sha256 = Get-ControlFixtureHash -Bytes ([IO.File]::ReadAllBytes($_.FullName))
                    }
                }
            }
    )
    ConvertTo-Json -InputObject ([ordered]@{ RootExists = [IO.Directory]::Exists($Root); Items = $items }) -Depth 5 -Compress
}

function New-ControlFixture {
    param([string]$Root, [string]$Action, [string]$GrantedCapability)
    $installation = 'installation-exact-01'
    $machine = 'machine-exact-01'
    $session = '11111111-2222-4333-8444-555555555555'
    $base = @{ installationId = $installation; machineId = $machine }
    $targets = @{
        'session.read' = $base + @{ client = 'copilot'; sessionId = $session }
        'session.reply' = $base + @{
            client = 'copilot'; sessionId = $session; processId = 424242
            processStartedAtUtc = '2030-01-01T00:00:00.0000000Z'
        }
        'session.launch' = $base + @{
            client = 'copilot'; workspaceId = 'workspace-exact-01'
            launchConfigurationSha256 = ('a' * 64); permissionMode = 'ask'
        }
        'installation.update' = $base + @{ releaseId = 'release-exact-01'; artifactSha256 = ('b' * 64) }
    }
    $scopes = @{
        read = $base + @{ client = 'copilot'; sessionId = $session }
        reply = $base + @{ client = 'copilot'; sessionId = $session }
        launch = $base + @{ client = 'copilot'; workspaceId = 'workspace-exact-01' }
        update = $base.Clone()
    }
    $content = [byte[]]::new(0)
    if ($Action -notin @('session.read', 'installation.update')) {
        $content = [Text.Encoding]::UTF8.GetBytes('synthetic command text')
    }
    $target = $targets[$Action].Clone()
    $configuration = @{
        unrelated = @{ keep = 'unchanged-unrelated-configuration'; dateText = '2030-01-02T20:00:00Z' }
        homeAssistant = @{ token = 'synthetic-sensitive-config-marker' }
        controlAuthorization = @{
            version = 1; generation = 'policy-exact-01'; installationId = $installation; machineId = $machine
            limits = @{ maxCommandBytes = 8192; maxContentBytes = 1024; maxLifetimeSeconds = 600; maxFutureSkewSeconds = 30 }
            principals = @(@{
                issuer = 'issuer-exact-01'; subject = 'subject-exact-01'
                grants = @(@{ capability = $GrantedCapability; scopes = @($scopes[$GrantedCapability]) })
            })
        }
    }
    @{
        Root = $Root
        Configuration = $configuration
        ConfigurationContext = @{ configPath = (Join-Path $Root 'configuration.json'); installationId = $installation; machineId = $machine }
        Principal = @{ issuer = 'issuer-exact-01'; subject = 'subject-exact-01' }
        Target = $target
        Command = [ordered]@{
            version = 1; requestId = '11111111222243338444555555555555'; action = $Action
            issuer = 'issuer-exact-01'; subject = 'subject-exact-01'; policyGeneration = 'policy-exact-01'
            target = $target.Clone()
            issuedAtUtc = '2030-01-02T19:59:00.0000000Z'
            notBeforeUtc = '2030-01-02T19:59:00.0000000Z'
            expiresAtUtc = '2030-01-02T20:02:00.0000000Z'
            contentSha256 = Get-ControlFixtureHash -Bytes $content
        }
        Content = $content
        Now = [DateTimeOffset]::new(2030, 1, 2, 20, 0, 0, [TimeSpan]::Zero)
        Limits = @{ maxConfigurationBytes = 65536; maxCommandBytes = 8192; maxContentBytes = 1024; maxLifetimeSeconds = 900; maxFutureSkewSeconds = 60 }
        RawConfiguration = $null
        RawCommand = $null
        MissingConfiguration = $false
        ConfigurationIsDirectory = $false
        PrettyCommand = $false
        ExpectedGuard = $false
    }
}

function Set-ControlFixtureMutation {
    param([hashtable]$Fixture, [string]$Mutation)
    $policy = $Fixture.Configuration.controlAuthorization
    switch -CaseSensitive ($Mutation) {
        'none' { }
        'missing-config' { $Fixture.MissingConfiguration = $true }
        'directory-config' { $Fixture.ConfigurationIsDirectory = $true }
        'empty-config' { $Fixture.RawConfiguration = [byte[]]::new(0) }
        'invalid-config-utf8' { $Fixture.RawConfiguration = [byte[]]@(0xc3, 0x28) }
        'invalid-config-json' { $Fixture.RawConfiguration = [Text.Encoding]::UTF8.GetBytes('{"synthetic-sensitive-parser-marker":') }
        'missing-policy' { $Fixture.Configuration.Remove('controlAuthorization') }
        'null-policy' { $Fixture.Configuration.controlAuthorization = $null }
        'empty-policy' { $Fixture.Configuration.controlAuthorization = @{} }
        'duplicate-policy-root' {
            $raw = ConvertTo-Json -InputObject $policy -Depth 20 -Compress
            $Fixture.RawConfiguration = [Text.Encoding]::UTF8.GetBytes('{"controlAuthorization":' + $raw + ',"controlAuthorization":' + $raw + '}')
        }
        'wrong-policy-key-case' { $Fixture.Configuration.Remove('controlAuthorization'); $Fixture.Configuration['ControlAuthorization'] = $policy }
        'unknown-policy-version' { $policy.version = 2 }
        'boolean-policy-version' { $policy.version = $true }
        'string-policy-version' { $policy.version = '1' }
        'fraction-policy-version' {
            $raw = ConvertTo-Json -InputObject $Fixture.Configuration -Depth 20 -Compress
            $Fixture.RawConfiguration = [Text.Encoding]::UTF8.GetBytes($raw.Replace('"version":1', '"version":1.0'))
        }
        'policy-extra-field' { $policy.verified = $true }
        'policy-generation-number' { $policy.generation = 1 }
        'policy-installation-mismatch' { $policy.installationId = 'installation-other' }
        'policy-machine-mismatch' { $policy.machineId = 'machine-other' }
        'principals-not-array' { $policy.principals = $policy.principals[0] }
        'empty-principals' { $policy.principals = @() }
        'duplicate-principal' { $policy.principals = @($policy.principals[0], $policy.principals[0]) }
        'principal-extra-field' { $policy.principals[0].verified = $true }
        'policy-issuer-wildcard' { $policy.principals[0].issuer = '*' }
        'policy-subject-blank' { $policy.principals[0].subject = ' ' }
        { $_ -in @('principals-exact-limit', 'policy-too-many-principals') } {
            $count = if ($Mutation -eq 'principals-exact-limit') { 128 } else { 129 }
            $principals = [Collections.Generic.List[object]]::new()
            for ($i = 1; $i -le $count; $i++) {
                $principal = $policy.principals[0].Clone()
                if ($i -gt 1) { $principal.subject = "other-subject-$i" }
                $principals.Add($principal)
            }
            $policy.principals = $principals.ToArray()
        }
        'empty-grants' { $policy.principals[0].grants = @() }
        'unknown-grant' { $policy.principals[0].grants[0].capability = 'stop' }
        'wrong-grant-case' { $policy.principals[0].grants[0].capability = 'Reply' }
        'grant-ordinal-ignorable' { $policy.principals[0].grants[0].capability = 're' + [char]0xad + 'ply' }
        'duplicate-grant' { $policy.principals[0].grants = @($policy.principals[0].grants[0], $policy.principals[0].grants[0]) }
        'missing-scopes' { $policy.principals[0].grants[0].Remove('scopes') }
        'empty-scopes' { $policy.principals[0].grants[0].scopes = @() }
        'scope-not-array' { $policy.principals[0].grants[0].scopes = $policy.principals[0].grants[0].scopes[0] }
        'duplicate-scope' { $policy.principals[0].grants[0].scopes = @($policy.principals[0].grants[0].scopes[0], $policy.principals[0].grants[0].scopes[0]) }
        'scope-wildcard' { $policy.principals[0].grants[0].scopes[0].sessionId = '*' }
        'scope-missing-machine' { $policy.principals[0].grants[0].scopes[0].Remove('machineId') }
        'scope-boolean-session' { $policy.principals[0].grants[0].scopes[0].sessionId = $true }
        'scope-other-installation' { $policy.principals[0].grants[0].scopes[0].installationId = 'installation-other' }
        'scope-other-session' { $policy.principals[0].grants[0].scopes[0].sessionId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' }
        { $_ -in @('scopes-exact-limit', 'policy-too-many-scopes') } {
            $count = if ($Mutation -eq 'scopes-exact-limit') { 128 } else { 129 }
            $scopes = [Collections.Generic.List[object]]::new()
            for ($i = 1; $i -le $count; $i++) {
                $scope = $policy.principals[0].grants[0].scopes[0].Clone()
                if ($i -gt 1) { $scope.sessionId = '00000000-0000-4000-8000-{0:d12}' -f $i }
                $scopes.Add($scope)
            }
            $policy.principals[0].grants[0].scopes = $scopes.ToArray()
        }
        { $_ -in @('json-depth-exact-limit', 'json-depth-over-limit') } {
            $depth = if ($Mutation -eq 'json-depth-exact-limit') { 31 } else { 32 }
            $rawPolicy = ConvertTo-Json -InputObject $policy -Depth 20 -Compress
            $Fixture.RawConfiguration = [Text.Encoding]::UTF8.GetBytes(
                '{"unrelated":' + ('[' * $depth) + '0' + (']' * $depth) + ',"controlAuthorization":' + $rawPolicy + '}')
        }
        'policy-limit-missing' { $policy.limits.Remove('maxContentBytes') }
        'policy-limit-string' { $policy.limits.maxContentBytes = '1024' }
        'policy-limit-zero' { $policy.limits.maxLifetimeSeconds = 0 }
        'policy-limit-over-ceiling' { $policy.limits.maxFutureSkewSeconds = 301 }
        'null-principal' { $Fixture.Principal = $null; $Fixture.Command['actor'] = 'agent' }
        'empty-principal' { $Fixture.Principal = @{} }
        'principal-verified-flag' { $Fixture.Principal.verified = $true }
        'principal-string' { $Fixture.Principal = 'issuer-exact-01/subject-exact-01' }
        'principal-number' { $Fixture.Principal.subject = 1 }
        'issuer-binding-mismatch' { $Fixture.Command.issuer = 'issuer-other' }
        'subject-binding-mismatch' { $Fixture.Command.subject = 'subject-other' }
        'issuer-not-granted' { $Fixture.Principal.issuer = 'Issuer-exact-01'; $Fixture.Command.issuer = $Fixture.Principal.issuer }
        'subject-not-granted' { $Fixture.Principal.subject = 'subject-other'; $Fixture.Command.subject = $Fixture.Principal.subject }
        'generation-mismatch' { $Fixture.Command.policyGeneration = 'Policy-exact-01' }
        'payload-actor' { $Fixture.Command['actor'] = 'agent' }
        'payload-context' { $Fixture.Command['context'] = @{ user_id = 'subject-exact-01'; verified = $true } }
        'payload-user-id' { $Fixture.Command['user_id'] = 'subject-exact-01' }
        'payload-verified' { $Fixture.Command['verified'] = $true }
        'capability-match' { $Fixture.Command['capability'] = 'reply' }
        { $_ -in @('capability-launder', 'launch-capability-launder', 'update-capability-launder') } {
            $Fixture.Command['capability'] = 'read'
        }
        'capability-number' { $Fixture.Command['capability'] = 1 }
        'capability-ordinal-ignorable' { $Fixture.Command['capability'] = 'laun' + [char]0xad + 'ch' }
        'action-ordinal-ignorable' { $Fixture.Command.action = 'session.laun' + [char]0xad + 'ch' }
        'unsupported-stop' { $Fixture.Command.action = 'session.stop' }
        'unsupported-cancel' { $Fixture.Command.action = 'command.cancel' }
        'unsupported-decision' { $Fixture.Command.action = 'decision.answer' }
        'unsupported-approval' { $Fixture.Command.action = 'approval.answer' }
        'unsupported-trust' { $Fixture.Command.action = 'workspace.trust' }
        'unsupported-transfer' { $Fixture.Command.action = 'session.transfer' }
        'unsupported-resume' { $Fixture.Command.action = 'session.resume' }
        'unknown-command-version' { $Fixture.Command.version = 2 }
        'string-command-version' { $Fixture.Command.version = '1' }
        'boolean-command-version' { $Fixture.Command.version = $true }
        'duplicate-command-key' {
            $raw = ConvertTo-Json -InputObject $Fixture.Command -Depth 20 -Compress
            $Fixture.RawCommand = [Text.Encoding]::UTF8.GetBytes($raw.Replace('"version":1', '"version":1,"version":1'))
        }
        'duplicate-target-key' {
            $raw = ConvertTo-Json -InputObject $Fixture.Command -Depth 20 -Compress
            $Fixture.RawCommand = [Text.Encoding]::UTF8.GetBytes($raw.Replace('"processId":424242', '"processId":424242,"processId":424242'))
        }
        'wrong-command-key-case' {
            $raw = ConvertTo-Json -InputObject $Fixture.Command -Depth 20 -Compress
            $Fixture.RawCommand = [Text.Encoding]::UTF8.GetBytes($raw.Replace('"action":', '"Action":'))
        }
        'invalid-command-json' { $Fixture.RawCommand = [Text.Encoding]::UTF8.GetBytes('{"synthetic-sensitive-parser-marker":') }
        'invalid-command-utf8' { $Fixture.RawCommand = [byte[]]@(0xc3, 0x28) }
        'empty-command' { $Fixture.RawCommand = [byte[]]::new(0) }
        'bad-request-id' { $Fixture.Command.requestId = '1111111122224333' }
        'zero-request-id' { $Fixture.Command.requestId = ('0' * 32) }
        'null-target' { $Fixture.Target = $null }
        'empty-target' { $Fixture.Target = @{} }
        'target-extra-field' { $Fixture.Target.verified = $true }
        'target-installation-mismatch' { $Fixture.Command.target.installationId = 'installation-other' }
        'target-machine-mismatch' { $Fixture.Command.target.machineId = 'machine-other' }
        'target-client-mismatch' { $Fixture.Command.target.client = 'claude' }
        'target-session-mismatch' { $Fixture.Command.target.sessionId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' }
        'target-process-mismatch' { $Fixture.Command.target.processId = 424243 }
        'target-incarnation-mismatch' { $Fixture.Command.target.processStartedAtUtc = '2030-01-01T00:00:00.0000001Z' }
        'target-short-session' { $Fixture.Command.target.sessionId = '1111111122224333' }
        'target-string-pid' { $Fixture.Command.target.processId = '424242' }
        'target-boolean-pid' { $Fixture.Command.target.processId = $true }
        'target-zero-pid' { $Fixture.Command.target.processId = 0 }
        'target-unknown-client' { $Fixture.Command.target.client = 'mcp' }
        'client-ordinal-ignorable' { $Fixture.Command.target.client = 'co' + [char]0xad + 'pilot' }
        'target-inexact-birth' { $Fixture.Command.target.processStartedAtUtc = '2030-01-01T00:00:00Z' }
        'launch-config-mismatch' { $Fixture.Command.target.launchConfigurationSha256 = ('c' * 64) }
        'launch-workspace-mismatch' { $Fixture.Command.target.workspaceId = 'workspace-other' }
        'launch-allow-all' { $Fixture.Command.target.permissionMode = 'allow-all' }
        'permission-ordinal-ignorable' { $Fixture.Command.target.permissionMode = 'a' + [char]0xad + 'sk' }
        'launch-trust-field' { $Fixture.Command.target['trust'] = $true }
        'update-release-mismatch' { $Fixture.Command.target.releaseId = 'release-other' }
        'update-artifact-mismatch' { $Fixture.Command.target.artifactSha256 = ('c' * 64) }
        'expired-exactly' { $Fixture.Command.expiresAtUtc = '2030-01-02T20:00:00.0000000Z' }
        'not-yet-valid' { $Fixture.Command.notBeforeUtc = '2030-01-02T20:00:00.0000001Z' }
        'invalid-time-order' { $Fixture.Command.notBeforeUtc = '2030-01-02T19:58:00.0000000Z' }
        'lifetime-over-limit' { $Fixture.Command.expiresAtUtc = '2030-01-02T20:09:00.0000001Z' }
        'lifetime-exact-limit' { $Fixture.Command.expiresAtUtc = '2030-01-02T20:09:00.0000000Z' }
        'skew-over-limit' {
            $Fixture.Command.issuedAtUtc = '2030-01-02T20:00:30.0000001Z'
            $Fixture.Command.notBeforeUtc = $Fixture.Command.issuedAtUtc
        }
        'skew-exact-limit' {
            $Fixture.Command.issuedAtUtc = '2030-01-02T20:00:30.0000000Z'
            $Fixture.Command.notBeforeUtc = $Fixture.Command.issuedAtUtc
        }
        'time-offset-form' { $Fixture.Command.issuedAtUtc = '2030-01-02T19:59:00.0000000+00:00' }
        'time-short-fraction' { $Fixture.Command.issuedAtUtc = '2030-01-02T19:59:00Z' }
        'time-number' { $Fixture.Command.issuedAtUtc = 1 }
        'clock-string' { $Fixture.Now = '2030-01-02T20:00:00.0000000Z' }
        'clock-datetime' { $Fixture.Now = [datetime]::new(2030, 1, 2, 20, 0, 0) }
        'content-digest-mismatch' { $Fixture.Command.contentSha256 = ('0' * 64) }
        'content-digest-uppercase' { $Fixture.Command.contentSha256 = ('A' * 64) }
        'content-invalid-utf8' { $Fixture.Content = [byte[]]@(0xc3, 0x28); $Fixture.Command.contentSha256 = Get-ControlFixtureHash -Bytes $Fixture.Content }
        'content-empty' { $Fixture.Content = [byte[]]::new(0); $Fixture.Command.contentSha256 = Get-ControlFixtureHash -Bytes $Fixture.Content }
        'content-blank' { $Fixture.Content = [Text.Encoding]::UTF8.GetBytes(" `t`r`n"); $Fixture.Command.contentSha256 = Get-ControlFixtureHash -Bytes $Fixture.Content }
        { $_ -in @('read-has-content', 'update-has-content') } {
            $Fixture.Content = [Text.Encoding]::UTF8.GetBytes('not empty metadata')
            $Fixture.Command.contentSha256 = Get-ControlFixtureHash -Bytes $Fixture.Content
        }
        'configuration-context-extra' { $Fixture.ConfigurationContext.verified = $true }
        'configuration-context-relative' { $Fixture.ConfigurationContext.configPath = 'configuration.json' }
        'configuration-context-null' { $Fixture.ConfigurationContext = $null }
        'limits-missing' { $Fixture.Limits.Remove('maxContentBytes') }
        'limits-string' { $Fixture.Limits.maxCommandBytes = '8192' }
        'limits-boolean' { $Fixture.Limits.maxCommandBytes = $true }
        'limits-float' { $Fixture.Limits.maxCommandBytes = [double]8192 }
        'limits-infinite' { $Fixture.Limits.maxCommandBytes = [double]::PositiveInfinity }
        'limits-over-ceiling' { $Fixture.Limits.maxCommandBytes = 16777217L }
        'limits-negative-skew' { $Fixture.Limits.maxFutureSkewSeconds = -1 }
        'command-exact-limit' { $Fixture.Limits.maxCommandBytes = (ConvertTo-ControlFixtureBytes $Fixture.Command).Length }
        'command-over-limit' { $Fixture.Limits.maxCommandBytes = (ConvertTo-ControlFixtureBytes $Fixture.Command).Length - 1 }
        'policy-command-over-limit' { $policy.limits.maxCommandBytes = (ConvertTo-ControlFixtureBytes $Fixture.Command).Length - 1 }
        'content-exact-limit' { $Fixture.Limits.maxContentBytes = $Fixture.Content.Length }
        'content-over-limit' { $Fixture.Limits.maxContentBytes = $Fixture.Content.Length - 1 }
        'policy-content-over-limit' { $policy.limits.maxContentBytes = $Fixture.Content.Length - 1 }
        'configuration-exact-limit' { $Fixture.Limits.maxConfigurationBytes = (ConvertTo-ControlFixtureBytes $Fixture.Configuration).Length }
        'configuration-over-limit' { $Fixture.Limits.maxConfigurationBytes = (ConvertTo-ControlFixtureBytes $Fixture.Configuration).Length - 1 }
        'oversized-invalid-command-before-read' {
            $Fixture.RawCommand = [byte[]]@(0xc3, 0x28)
            $Fixture.Limits.maxCommandBytes = 1
            $Fixture.ConfigurationIsDirectory = $true
        }
        'oversized-invalid-config-before-decode' {
            $Fixture.RawConfiguration = [byte[]]@(0xc3, 0x28)
            $Fixture.Limits.maxConfigurationBytes = 1
        }
        'command-buffer-string' { $Fixture.RawCommand = 'not a byte buffer' }
        'content-buffer-objects' { $Fixture.Content = [object[]]@(1, 2) }
        'pretty-command' { $Fixture.PrettyCommand = $true }
        'utf8-content-exact' {
            $Fixture.Content = [Text.Encoding]::UTF8.GetBytes(('literal text ' + [char]0x96ea + "`r`n"))
            $Fixture.Command.contentSha256 = Get-ControlFixtureHash -Bytes $Fixture.Content
        }
        'guard-outside-root' {
            $Fixture.ConfigurationContext.configPath = Join-Path (Split-Path $env:AGENT_HA_BRIDGE_TEST_ROOT -Parent) `
                ('control-policy-never-created-' + [guid]::NewGuid().ToString('N') + '.json')
            $Fixture.ExpectedGuard = $true
        }
        default { throw "Unknown fixture mutation: $Mutation" }
    }
}

# Data rows, not a hidden case selector: the complete list always executes.
$cases = [Collections.Generic.List[object]]::new()
$actions = [ordered]@{ read = 'session.read'; reply = 'session.reply'; launch = 'session.launch'; update = 'installation.update' }
foreach ($grant in $actions.Keys) {
    foreach ($request in $actions.Keys) {
        $cases.Add(@{
            Id = "matrix-$grant-$request"; Action = $actions[$request]; Grant = $grant; Mutation = 'none'
            Eligibility = if ($grant -ceq $request) { 'Eligible' } else { 'Ineligible' }
            Reason = if ($grant -ceq $request) { 'EligibleUnderAssumptions' } else { 'CapabilityNotGranted' }
        })
    }
}

$rows = @(
    ,@('missing-config','Unavailable','ConfigurationReadFailed')
    ,@('directory-config','Unavailable','ConfigurationReadFailed')
    ,@('empty-config','Unavailable','ConfigurationEmpty')
    ,@('invalid-config-utf8','Ineligible','InvalidUtf8')
    ,@('invalid-config-json','Ineligible','InvalidJson')
    ,@('missing-policy','Unavailable','PolicyMissing')
    ,@('null-policy','Ineligible','PolicyInvalid')
    ,@('empty-policy','Ineligible','PolicyInvalid')
    ,@('duplicate-policy-root','Ineligible','PolicyInvalid')
    ,@('wrong-policy-key-case','Ineligible','PolicyInvalid')
    ,@('unknown-policy-version','Ineligible','PolicyVersionUnsupported')
    ,@('boolean-policy-version','Ineligible','PolicyVersionUnsupported')
    ,@('string-policy-version','Ineligible','PolicyVersionUnsupported')
    ,@('fraction-policy-version','Ineligible','PolicyVersionUnsupported')
    ,@('policy-extra-field','Ineligible','PolicyInvalid')
    ,@('policy-generation-number','Ineligible','PolicyInvalid')
    ,@('policy-installation-mismatch','Ineligible','ConfigurationBindingMismatch')
    ,@('policy-machine-mismatch','Ineligible','ConfigurationBindingMismatch')
    ,@('principals-not-array','Ineligible','PolicyInvalid')
    ,@('empty-principals','Ineligible','PrincipalNotGranted')
    ,@('duplicate-principal','Ineligible','PolicyInvalid')
    ,@('principal-extra-field','Ineligible','PolicyInvalid')
    ,@('policy-issuer-wildcard','Ineligible','PolicyInvalid')
    ,@('policy-subject-blank','Ineligible','PolicyInvalid')
    ,@('principals-exact-limit','Eligible','EligibleUnderAssumptions')
    ,@('policy-too-many-principals','Ineligible','PolicyInvalid')
    ,@('empty-grants','Ineligible','CapabilityNotGranted')
    ,@('unknown-grant','Ineligible','PolicyInvalid')
    ,@('wrong-grant-case','Ineligible','PolicyInvalid')
    ,@('grant-ordinal-ignorable','Ineligible','PolicyInvalid')
    ,@('duplicate-grant','Ineligible','PolicyInvalid')
    ,@('missing-scopes','Ineligible','PolicyInvalid')
    ,@('empty-scopes','Ineligible','PolicyInvalid')
    ,@('scope-not-array','Ineligible','PolicyInvalid')
    ,@('duplicate-scope','Ineligible','PolicyInvalid')
    ,@('scope-wildcard','Ineligible','PolicyInvalid')
    ,@('scope-missing-machine','Ineligible','PolicyInvalid')
    ,@('scope-boolean-session','Ineligible','PolicyInvalid')
    ,@('scope-other-installation','Ineligible','PolicyInvalid')
    ,@('scope-other-session','Ineligible','ScopeNotGranted')
    ,@('scopes-exact-limit','Eligible','EligibleUnderAssumptions')
    ,@('policy-too-many-scopes','Ineligible','PolicyInvalid')
    ,@('json-depth-exact-limit','Eligible','EligibleUnderAssumptions')
    ,@('json-depth-over-limit','Ineligible','InvalidJson')
    ,@('policy-limit-missing','Ineligible','PolicyInvalid')
    ,@('policy-limit-string','Ineligible','PolicyInvalid')
    ,@('policy-limit-zero','Ineligible','PolicyInvalid')
    ,@('policy-limit-over-ceiling','Ineligible','PolicyInvalid')
    ,@('null-principal','Unavailable','PrincipalUnavailable')
    ,@('empty-principal','Ineligible','PrincipalContextInvalid')
    ,@('principal-verified-flag','Ineligible','PrincipalContextInvalid')
    ,@('principal-string','Ineligible','PrincipalContextInvalid')
    ,@('principal-number','Ineligible','PrincipalContextInvalid')
    ,@('issuer-binding-mismatch','Ineligible','PrincipalBindingMismatch')
    ,@('subject-binding-mismatch','Ineligible','PrincipalBindingMismatch')
    ,@('issuer-not-granted','Ineligible','PrincipalNotGranted')
    ,@('subject-not-granted','Ineligible','PrincipalNotGranted')
    ,@('generation-mismatch','Ineligible','PolicyGenerationMismatch')
    ,@('payload-actor','Ineligible','CommandInvalid')
    ,@('payload-context','Ineligible','CommandInvalid')
    ,@('payload-user-id','Ineligible','CommandInvalid')
    ,@('payload-verified','Ineligible','CommandInvalid')
    ,@('capability-match','Eligible','EligibleUnderAssumptions')
    ,@('capability-launder','Ineligible','CapabilityMismatch')
    ,@('launch-capability-launder','Ineligible','CapabilityMismatch','session.launch','read')
    ,@('update-capability-launder','Ineligible','CapabilityMismatch','installation.update','read')
    ,@('capability-number','Ineligible','CommandInvalid')
    ,@('capability-ordinal-ignorable','Ineligible','CapabilityMismatch','session.launch','launch')
    ,@('action-ordinal-ignorable','Ineligible','UnsupportedAction','session.launch','launch')
    ,@('unsupported-stop','Ineligible','UnsupportedAction')
    ,@('unsupported-cancel','Ineligible','UnsupportedAction')
    ,@('unsupported-decision','Ineligible','UnsupportedAction')
    ,@('unsupported-approval','Ineligible','UnsupportedAction')
    ,@('unsupported-trust','Ineligible','UnsupportedAction')
    ,@('unsupported-transfer','Ineligible','UnsupportedAction')
    ,@('unsupported-resume','Ineligible','UnsupportedAction')
    ,@('unknown-command-version','Ineligible','CommandVersionUnsupported')
    ,@('string-command-version','Ineligible','CommandVersionUnsupported')
    ,@('boolean-command-version','Ineligible','CommandVersionUnsupported')
    ,@('duplicate-command-key','Ineligible','CommandInvalid')
    ,@('duplicate-target-key','Ineligible','CommandTargetInvalid')
    ,@('wrong-command-key-case','Ineligible','CommandInvalid')
    ,@('invalid-command-json','Ineligible','InvalidJson')
    ,@('invalid-command-utf8','Ineligible','InvalidUtf8')
    ,@('empty-command','Ineligible','CommandEmpty')
    ,@('bad-request-id','Ineligible','CommandInvalid')
    ,@('zero-request-id','Ineligible','CommandInvalid')
    ,@('null-target','Unavailable','TargetUnavailable')
    ,@('empty-target','Ineligible','TargetContextInvalid')
    ,@('target-extra-field','Ineligible','TargetContextInvalid')
    ,@('target-installation-mismatch','Ineligible','TargetBindingMismatch')
    ,@('target-machine-mismatch','Ineligible','TargetBindingMismatch')
    ,@('target-client-mismatch','Ineligible','TargetBindingMismatch')
    ,@('target-session-mismatch','Ineligible','TargetBindingMismatch')
    ,@('target-process-mismatch','Ineligible','TargetBindingMismatch')
    ,@('target-incarnation-mismatch','Ineligible','TargetBindingMismatch')
    ,@('target-short-session','Ineligible','CommandTargetInvalid')
    ,@('target-string-pid','Ineligible','CommandTargetInvalid')
    ,@('target-boolean-pid','Ineligible','CommandTargetInvalid')
    ,@('target-zero-pid','Ineligible','CommandTargetInvalid')
    ,@('target-unknown-client','Ineligible','CommandTargetInvalid')
    ,@('client-ordinal-ignorable','Ineligible','CommandTargetInvalid')
    ,@('target-inexact-birth','Ineligible','CommandTargetInvalid')
    ,@('launch-config-mismatch','Ineligible','TargetBindingMismatch','session.launch','launch')
    ,@('launch-workspace-mismatch','Ineligible','TargetBindingMismatch','session.launch','launch')
    ,@('launch-allow-all','Ineligible','UnsupportedModifier','session.launch','launch')
    ,@('permission-ordinal-ignorable','Ineligible','UnsupportedModifier','session.launch','launch')
    ,@('launch-trust-field','Ineligible','CommandTargetInvalid','session.launch','launch')
    ,@('update-release-mismatch','Ineligible','TargetBindingMismatch','installation.update','update')
    ,@('update-artifact-mismatch','Ineligible','TargetBindingMismatch','installation.update','update')
    ,@('expired-exactly','Ineligible','Expired')
    ,@('not-yet-valid','Ineligible','NotYetValid')
    ,@('invalid-time-order','Ineligible','CommandTimeInvalid')
    ,@('lifetime-over-limit','Ineligible','CommandTimeInvalid')
    ,@('lifetime-exact-limit','Eligible','EligibleUnderAssumptions')
    ,@('skew-over-limit','Ineligible','IssuedTooFarAhead')
    ,@('skew-exact-limit','Ineligible','NotYetValid')
    ,@('time-offset-form','Ineligible','CommandTimeInvalid')
    ,@('time-short-fraction','Ineligible','CommandTimeInvalid')
    ,@('time-number','Ineligible','CommandTimeInvalid')
    ,@('clock-string','Ineligible','ClockInvalid')
    ,@('clock-datetime','Ineligible','ClockInvalid')
    ,@('content-digest-mismatch','Ineligible','ContentDigestMismatch')
    ,@('content-digest-uppercase','Ineligible','CommandInvalid')
    ,@('content-invalid-utf8','Ineligible','InvalidUtf8')
    ,@('content-empty','Ineligible','ContentEmpty')
    ,@('content-blank','Ineligible','ContentEmpty')
    ,@('read-has-content','Ineligible','ContentNotSupported','session.read','read')
    ,@('update-has-content','Ineligible','ContentNotSupported','installation.update','update')
    ,@('configuration-context-extra','Ineligible','ConfigurationContextInvalid')
    ,@('configuration-context-relative','Ineligible','ConfigurationPathNotAbsolute')
    ,@('configuration-context-null','Ineligible','ConfigurationContextInvalid')
    ,@('limits-missing','Ineligible','LimitsInvalid')
    ,@('limits-string','Ineligible','LimitsInvalid')
    ,@('limits-boolean','Ineligible','LimitsInvalid')
    ,@('limits-float','Ineligible','LimitsInvalid')
    ,@('limits-infinite','Ineligible','LimitsInvalid')
    ,@('limits-over-ceiling','Ineligible','LimitsInvalid')
    ,@('limits-negative-skew','Ineligible','LimitsInvalid')
    ,@('command-exact-limit','Eligible','EligibleUnderAssumptions')
    ,@('command-over-limit','Ineligible','CommandTooLarge')
    ,@('policy-command-over-limit','Ineligible','CommandTooLarge')
    ,@('content-exact-limit','Eligible','EligibleUnderAssumptions')
    ,@('content-over-limit','Ineligible','ContentTooLarge')
    ,@('policy-content-over-limit','Ineligible','ContentTooLarge')
    ,@('configuration-exact-limit','Eligible','EligibleUnderAssumptions')
    ,@('configuration-over-limit','Ineligible','ConfigurationTooLarge')
    ,@('oversized-invalid-command-before-read','Ineligible','CommandTooLarge')
    ,@('oversized-invalid-config-before-decode','Ineligible','ConfigurationTooLarge')
    ,@('command-buffer-string','Ineligible','ByteBufferRequired')
    ,@('content-buffer-objects','Ineligible','ByteBufferRequired')
    ,@('pretty-command','Eligible','EligibleUnderAssumptions')
    ,@('utf8-content-exact','Eligible','EligibleUnderAssumptions')
    ,@('guard-outside-root','GuardThrown','BridgeTestWriteBlocked')
)
foreach ($row in $rows) {
    $cases.Add(@{
        Id = $row[0]; Mutation = $row[0]; Eligibility = $row[1]; Reason = $row[2]
        Action = if ($row.Count -gt 3) { $row[3] } else { 'session.reply' }
        Grant = if ($row.Count -gt 4) { $row[4] } else { 'reply' }
    })
}

$sandbox = Join-Path $env:TEMP ('control-policy-' + [guid]::NewGuid().ToString('N'))
Assert-BridgeTestPath -Path $sandbox
[void][IO.Directory]::CreateDirectory($sandbox)
$oldAmbientConfig = $env:AGENT_HA_BRIDGE_CONFIG
try {
    $ambient = Join-Path $sandbox 'ambient-never-read.json'
    [IO.File]::WriteAllText($ambient, 'synthetic-sensitive-ambient-invalid-json', [Text.UTF8Encoding]::new($false))
    $env:AGENT_HA_BRIDGE_CONFIG = $ambient
    $ambientBefore = Get-ControlFixtureSnapshot $sandbox
    $helperPath = Join-Path $PSScriptRoot '..\hooks\bridge-control-policy.ps1'
    $parseTokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($helperPath, [ref]$parseTokens, [ref]$parseErrors)
    Test-ControlThat 'the helper has only its public function at import' (
        @($parseErrors).Count -eq 0 -and @($ast.EndBlock.Statements).Count -eq 1 -and
        $ast.EndBlock.Statements[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $ast.EndBlock.Statements[0].Name -ceq 'Get-BridgeControlEligibility')
    $locked = [IO.File]::Open($ambient, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try { $importOutput = @(. $helperPath) } finally { $locked.Dispose() }
    Test-ControlThat 'normal import emits nothing and leaves the ambient file untouched' (
        $importOutput.Count -eq 0 -and $ambientBefore -ceq (Get-ControlFixtureSnapshot $sandbox))

    foreach ($case in $cases) {
        $script:ControlCases++
        $root = Join-Path $sandbox $case.Id
        [void][IO.Directory]::CreateDirectory($root)
        $fixture = New-ControlFixture -Root $root -Action $case.Action -GrantedCapability $case.Grant
        Set-ControlFixtureMutation -Fixture $fixture -Mutation $case.Mutation
        # The actual input path may intentionally be invalid. Only fixture-owned
        # configuration.json is created; an outside guard target is never touched.
        $writtenPath = Join-Path $root 'configuration.json'
        if ($fixture.ConfigurationIsDirectory) { [void][IO.Directory]::CreateDirectory($writtenPath) }
        elseif (-not $fixture.MissingConfiguration) {
            $configurationBytes = $fixture.RawConfiguration
            if ($null -eq $configurationBytes) { $configurationBytes = ConvertTo-ControlFixtureBytes $fixture.Configuration }
            [IO.File]::WriteAllBytes($writtenPath, $configurationBytes)
        }
        $commandBytes = $fixture.RawCommand
        if ($null -eq $commandBytes) { $commandBytes = ConvertTo-ControlFixtureBytes $fixture.Command -Pretty:$fixture.PrettyCommand }
        $before = Get-ControlFixtureSnapshot $root
        $commandBefore = if ($commandBytes -is [byte[]]) { Get-ControlFixtureHash -Bytes $commandBytes } else { '' }
        $contentBefore = if ($fixture.Content -is [byte[]]) { Get-ControlFixtureHash -Bytes $fixture.Content } else { '' }
        $actual = @()
        $guard = $false
        $exceptionClass = ''
        $script:ControlCalls++
        try {
            $actual = @(Get-BridgeControlEligibility -ConfigurationContext $fixture.ConfigurationContext `
                -AssumedPrincipal $fixture.Principal -AssumedTarget $fixture.Target `
                -CommandBytes $commandBytes -ContentBytes $fixture.Content -Now $fixture.Now -Limits $fixture.Limits)
        }
        catch {
            $failure = $_.Exception
            while ($null -ne $failure) {
                if ($failure.Data['BridgeTestWriteBlocked']) { $guard = $true }
                $exceptionClass = $failure.GetType().FullName
                $failure = $failure.InnerException
            }
            if (-not $fixture.ExpectedGuard) { throw }
        }
        $after = Get-ControlFixtureSnapshot $root
        $record = [ordered]@{
            Id = $case.Id; ExpectedEligibility = $case.Eligibility; ExpectedReason = $case.Reason
            OutputCount = $actual.Count; GuardPropagated = $guard; ExceptionClass = $exceptionClass
            Result = if ($actual.Count -eq 1) { $actual[0] } else { $null }
            ConfigurationUnchanged = ($before -ceq $after)
            CommandUnchanged = ($commandBefore -eq '' -or $commandBefore -ceq (Get-ControlFixtureHash -Bytes $commandBytes))
            ContentUnchanged = ($contentBefore -eq '' -or $contentBefore -ceq (Get-ControlFixtureHash -Bytes $fixture.Content))
        }
        Write-Host ('CONTROL_POLICY_CASE ' + ($record | ConvertTo-Json -Depth 8 -Compress))
        Test-ControlThat "$($case.Id): configuration and caller buffers are unchanged" (
            $record.ConfigurationUnchanged -and $record.CommandUnchanged -and $record.ContentUnchanged)
        if ($fixture.ExpectedGuard) {
            Test-ControlThat "$($case.Id): the real path guard propagates instead of an eligibility result" ($guard -and $actual.Count -eq 0)
            continue
        }
        Test-ControlThat "$($case.Id): one named eligibility result matches" (
            $actual.Count -eq 1 -and $actual[0].Kind -ceq 'ControlCommandEligibility' -and
            $actual[0].Eligibility -ceq $case.Eligibility -and $actual[0].Reason -ceq $case.Reason)
        $expectedProperties = @('Kind', 'Version', 'Eligibility', 'Reason', 'RequiredCapability', 'RequestId',
            'CommandSha256', 'ContentSha256', 'DiagnosticPhase', 'DiagnosticType')
        Test-ControlThat "$($case.Id): the result has only the documented component fields" (
            @(Compare-Object -ReferenceObject $expectedProperties -DifferenceObject @($actual[0].PSObject.Properties.Name) -CaseSensitive).Count -eq 0 -and
            $actual[0].Version -is [int] -and $actual[0].Version -eq 1)
        $mapped = @($actions.Keys | Where-Object { $actions[$_] -ceq $fixture.Command.action })
        Test-ControlThat "$($case.Id): any derived capability belongs to the action, not a caller claim" (
            $null -eq $actual[0].RequiredCapability -or
            ($mapped.Count -eq 1 -and $actual[0].RequiredCapability -ceq $mapped[0]))
        $serialized = $actual[0] | ConvertTo-Json -Depth 6 -Compress
        Test-ControlThat "$($case.Id): diagnostics contain no policy body, private path or fabricated completion" (
            $serialized -notmatch 'synthetic-sensitive|unchanged-unrelated-configuration' -and
            @($actual[0].PSObject.Properties.Value | Where-Object { $_ -is [string] -and $_.Contains($root) }).Count -eq 0 -and
            @($actual[0].PSObject.Properties.Name | Where-Object { $_ -in @('Authenticated', 'Admitted', 'Done', 'Policy', 'Content') }).Count -eq 0)
        if ($case.Reason -in @('InvalidJson', 'InvalidUtf8', 'ConfigurationReadFailed')) {
            Test-ControlThat "$($case.Id): an actual safe exception class is retained" (
                $actual[0].DiagnosticType -match '^System\.[A-Za-z.]+Exception$')
        }
        if ($case.Eligibility -ceq 'Eligible') {
            Test-ControlThat "$($case.Id): exact original bytes define both digests and request identity" (
                $actual[0].CommandSha256 -ceq $commandBefore -and $actual[0].ContentSha256 -ceq $contentBefore -and
                $actual[0].RequestId -ceq [string]$fixture.Command.requestId)
        }
        $script:ControlResults[$case.Id] = $actual[0]
    }

    Test-ControlThat 'JSON layout is not silently canonicalized into the same command identity' (
        $script:ControlResults['matrix-reply-reply'].CommandSha256 -cne $script:ControlResults['pretty-command'].CommandSha256)

    $freshRoot = Join-Path $sandbox 'fresh-policy-and-no-replay-state'
    [void][IO.Directory]::CreateDirectory($freshRoot)
    $fresh = New-ControlFixture -Root $freshRoot -Action 'session.reply' -GrantedCapability 'reply'
    $freshBytes = ConvertTo-ControlFixtureBytes $fresh.Command
    [IO.File]::WriteAllBytes($fresh.ConfigurationContext.configPath, (ConvertTo-ControlFixtureBytes $fresh.Configuration))
    $freshBefore = Get-ControlFixtureSnapshot $freshRoot
    $first = Get-BridgeControlEligibility -ConfigurationContext $fresh.ConfigurationContext -AssumedPrincipal $fresh.Principal `
        -AssumedTarget $fresh.Target -CommandBytes $freshBytes -ContentBytes $fresh.Content -Now $fresh.Now -Limits $fresh.Limits
    $second = Get-BridgeControlEligibility -ConfigurationContext $fresh.ConfigurationContext -AssumedPrincipal $fresh.Principal `
        -AssumedTarget $fresh.Target -CommandBytes $freshBytes -ContentBytes $fresh.Content -Now $fresh.Now -Limits $fresh.Limits
    $expired = Get-BridgeControlEligibility -ConfigurationContext $fresh.ConfigurationContext -AssumedPrincipal $fresh.Principal `
        -AssumedTarget $fresh.Target -CommandBytes $freshBytes -ContentBytes $fresh.Content -Now ($fresh.Now.AddMinutes(3)) -Limits $fresh.Limits
    $rolledBack = Get-BridgeControlEligibility -ConfigurationContext $fresh.ConfigurationContext -AssumedPrincipal $fresh.Principal `
        -AssumedTarget $fresh.Target -CommandBytes $freshBytes -ContentBytes $fresh.Content -Now $fresh.Now -Limits $fresh.Limits
    Test-ControlThat 'repeated evaluations and caller clock changes do not mutate configuration' (
        $freshBefore -ceq (Get-ControlFixtureSnapshot $freshRoot))
    $fresh.Configuration.controlAuthorization.principals[0].grants = @()
    [IO.File]::WriteAllBytes($fresh.ConfigurationContext.configPath, (ConvertTo-ControlFixtureBytes $fresh.Configuration))
    $revokedBefore = Get-ControlFixtureSnapshot $freshRoot
    $third = Get-BridgeControlEligibility -ConfigurationContext $fresh.ConfigurationContext -AssumedPrincipal $fresh.Principal `
        -AssumedTarget $fresh.Target -CommandBytes $freshBytes -ContentBytes $fresh.Content -Now $fresh.Now -Limits $fresh.Limits
    $script:ControlCalls += 5
    Write-Host ('CONTROL_POLICY_SEQUENCE ' + (@{
        first = $first; repeated = $second; expired = $expired; afterClockRollback = $rolledBack; afterRevocation = $third
    } | ConvertTo-Json -Depth 8 -Compress))
    Test-ControlThat 'repeated evaluation is not represented as durable replay prevention' (
        $first.Eligibility -ceq 'Eligible' -and $second.Eligibility -ceq 'Eligible' -and $first.CommandSha256 -ceq $second.CommandSha256)
    Test-ControlThat 'caller clock rollback is not represented as persisted clock-history protection' (
        $expired.Reason -ceq 'Expired' -and $rolledBack.Eligibility -ceq 'Eligible')
    Test-ControlThat 'a later policy read cannot reuse the prior eligible decision' (
        $third.Eligibility -ceq 'Ineligible' -and $third.Reason -ceq 'CapabilityNotGranted')
    Test-ControlThat 'the component does not restore or rewrite a revoked policy' (
        $revokedBefore -ceq (Get-ControlFixtureSnapshot $freshRoot))
    Write-Host ('CONTROL_POLICY_COMPLETE ' + (@{
        cases = $script:ControlCases; helperCalls = $script:ControlCalls; assertions = $script:ControlAssertions
        liveAuthenticationProved = $false; admissionOrDispatchPerformed = $false
    } | ConvertTo-Json -Compress))
}
finally {
    $env:AGENT_HA_BRIDGE_CONFIG = $oldAmbientConfig
    Assert-BridgeTestPath -Path $sandbox
    if ([IO.Directory]::Exists($sandbox)) { [IO.Directory]::Delete($sandbox, $true) }
}
Write-Host 'All control-policy component checks passed.'
exit 0
