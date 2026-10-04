#Requires -Version 7.0
<#
.SYNOPSIS
    Shared, non-suite fixtures for truthful update intake and CLI intent.
.DESCRIPTION
    Dot-source with the real suite entry path; this helper must never become the
    child entry. Every child uses the canonical Offline constructor. Downloaded
    archives contain only the inert installer below, never the product installer.
    Generated-child process fixtures are Windows-only: their OS boundary is
    Get-Process/Get-CimInstance/Stop-Process, not a live /bin/ps on other platforms.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Suite', 'Updater', 'Cli')][string]$FixtureMode,
    [Parameter(Mandatory)][string]$TestEntryPath,
    [string]$UpdaterEntry = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'runner-support.ps1')
Assert-BridgeTestEnvironment -Required
$fixtureState = [pscustomobject]@{
    TestEntry = $TestEntryPath
    FixtureFile = Join-Path $env:AGENT_HA_BRIDGE_TEST_ROOT 'update-fixture.json'
    FixtureRoot = Join-Path $env:AGENT_HA_BRIDGE_TEST_ROOT 'update-fixtures'
    Fixture = $null; RestCalls = 0; Messages = @()
    Launches = 0; ChildTimedOut = $false; LastStage = ''
    PrivateProofRaw = $null
    DaemonConsumed = $false; DetachedChildExit = $null
    DefaultInstallRoot = $null; InertInstaller = $null; UpdateOutcomeFile = $null
}
# The CLI changes script scope. Close over only the record, keeping real guards
# and canonical constructors in the boundary functions' original command scope.
Set-Item Function:\Get-UpdateFixtureState -Value { $fixtureState }.GetNewClosure()
Assert-BridgeTestPath -Path @($fixtureState.FixtureFile, $fixtureState.FixtureRoot)
if ($FixtureMode -ne 'Suite') {
    $fixtureState.Fixture = Get-Content -LiteralPath $fixtureState.FixtureFile -Raw | ConvertFrom-Json -AsHashtable
    Assert-BridgeTestPath -Path @($fixtureState.Fixture.InstallRoot, $fixtureState.Fixture.Archive)
    if ($FixtureMode -eq 'Updater') { $env:AGENT_HA_BRIDGE_CONFIG = Join-Path $fixtureState.Fixture.InstallRoot 'config.json' }
}

function Assert-UpdateIntake {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { throw "FAIL: $Name" }
    Write-Host "  PASS  $Name"
}
function Set-FixtureVersion {
    param([string]$Version)
    Assert-BridgeTestPath -Path $env:AGENT_HA_BRIDGE_CONFIG
    $saved = Get-Content -LiteralPath $env:AGENT_HA_BRIDGE_CONFIG -Raw | ConvertFrom-Json -AsHashtable
    $saved['updates']['installedVersion'] = $Version
    $saved['updates']['repository'] = 'fixture-owner/fixture-bridge'
    $saved | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $env:AGENT_HA_BRIDGE_CONFIG -Encoding UTF8
}

function Write-UpdateIntakeDiagnostic {
    param([ValidateSet('CLI', 'UPDATE')][string]$Kind, [Collections.IDictionary]$Data)
    # Console output must not become part of the real helper's return value.
    [Console]::Out.WriteLine("P6_${Kind}_DIAGNOSTIC " + ($Data | ConvertTo-Json -Depth 8 -Compress))
}
function Write-UpdateCliDiagnostic {
    param([string]$Case, [object]$Child, [object]$ExpectedExit)
    $fixtureState = Get-UpdateFixtureState
    Write-UpdateIntakeDiagnostic -Kind CLI -Data ([ordered]@{
        stage = 'child-result'; case = $Case; fixtureInput = $fixtureState.Fixture
        expectedExit = $ExpectedExit; actualExit = $Child.ExitCode
        timedOut = $Child.TimedOut; seconds = $Child.Seconds; output = $Child.Output
    })
    $cliObservationPath = Join-Path $fixtureState.FixtureRoot 'cli-observation.json'
    $cliPromptPath = Join-Path $fixtureState.FixtureRoot 'cli-prompts.txt'
    $cliObservationPresent = Test-Path -LiteralPath $cliObservationPath
    $cliPromptPresent = Test-Path -LiteralPath $cliPromptPath
    Write-UpdateIntakeDiagnostic -Kind CLI -Data ([ordered]@{
        stage = 'file-presence'; case = $Case
        observationPresent = $cliObservationPresent; promptPresent = $cliPromptPresent
    })
    if ($cliObservationPresent) {
        $cliObservationRaw = Get-Content -LiteralPath $cliObservationPath -Raw
        Write-UpdateIntakeDiagnostic -Kind CLI -Data ([ordered]@{
            stage = 'observation-content'; case = $Case; observationRaw = $cliObservationRaw
        })
    }
}
function Write-UpdateResultDiagnostic {
    param([string]$Stage = 'parent-result', [object]$Result, [object]$Expected)
    $fixtureState = Get-UpdateFixtureState
    Write-UpdateIntakeDiagnostic -Kind UPDATE -Data ([ordered]@{
        stage = $Stage; case = $fixtureState.Fixture.Case; fixtureInput = $fixtureState.Fixture
        result = $Result; expected = $Expected
        restCalls = $fixtureState.RestCalls; launches = $fixtureState.Launches
        childTimedOut = $fixtureState.ChildTimedOut; detachedChildExit = $fixtureState.DetachedChildExit
        daemonConsumed = $fixtureState.DaemonConsumed; lastStage = $fixtureState.LastStage
        stagePresent = $(if ($fixtureState.LastStage) { Test-Path -LiteralPath $fixtureState.LastStage } else { $null })
        inertInstallerCalled = Test-Path -LiteralPath (Join-Path $fixtureState.Fixture.InstallRoot 'inert-installer-called.txt')
    })
}

if ($FixtureMode -eq 'Suite') { $fixtureState.Fixture = @{ Lookup = 'unavailable'; Target = '1.2.0' } }
function Invoke-RestMethod {
    param($Uri, $Method, $Headers, $Body, $TimeoutSec, $ContentType, $WebSession)
    $fixtureState = Get-UpdateFixtureState
    if ($Uri -eq 'https://api.github.com/repos/fixture-owner/fixture-bridge/releases/latest') {
        $fixtureState.RestCalls++
        if ($fixtureState.Fixture.Lookup -eq 'unavailable') { throw [IO.IOException]::new('synthetic lookup outage') }
        if ($fixtureState.Fixture.Lookup -match '^http-(\d+)$') {
            $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode][int]$Matches[1])
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('synthetic HTTP response', $response)
        }
        return [pscustomobject]@{
            tag_name = $(if ($fixtureState.Fixture.Lookup -eq 'invalid') { 'not-a-version' } else { "v$($fixtureState.Fixture.Target)" })
            name = 'synthetic release'; body = ''; published_at = ''
            html_url = "https://example.test/releases/v$($fixtureState.Fixture.Target)"
            zipball_url = "https://example.test/archive/v$($fixtureState.Fixture.Target).zip"
        }
    }
    if ($Uri -eq 'http://127.0.0.1:1/api/services/mqtt/publish' -or
        $Uri -eq 'http://127.0.0.1:1/api/services/persistent_notification/create') {
        $fixtureState.Messages += [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
        return @()
    }
    throw "Unexpected REST fixture endpoint: $Uri"
}
if ($FixtureMode -eq 'Updater') {
    if (-not $IsWindows) { throw 'This generated-child fixture has no non-Windows process boundary.' }
    Assert-BridgeTestPath -Path $UpdaterEntry
    function Invoke-WebRequest {
        param($Uri, $OutFile, $Headers, [switch]$UseBasicParsing)
        $fixtureState = Get-UpdateFixtureState
        Assert-BridgeTestPath -Path @($OutFile, $fixtureState.Fixture.Archive)
        if ($Uri -cne "https://example.test/archive/v$($fixtureState.Fixture.Target).zip") { throw 'Unexpected download fixture endpoint.' }
        Copy-Item -LiteralPath $fixtureState.Fixture.Archive -Destination $OutFile
        if ($fixtureState.Fixture.Case -eq 'guard-child-write') {
            # The real post-extraction path guard sees the corrupted environment.
            # No file is read or written at this deliberately out-of-bound name.
            $env:AGENT_HA_BRIDGE_CONFIG = Join-Path (Split-Path $env:AGENT_HA_BRIDGE_TEST_ROOT -Parent) 'forbidden-config.json'
        }
    }
    function Get-Process {
        param($Id, $Name, $ErrorAction)
        $fixtureState = Get-UpdateFixtureState
        if ($fixtureState.Fixture.Case -ne 'restart-denied') { return @() }
        [pscustomobject]@{
            Id = 424242; ProcessName = 'pwsh'; Path = (Join-Path $PSHOME 'pwsh.exe')
            Parent = $null; StartTime = [datetime]'2026-01-01T00:00:00Z'
        }
    }
    function Get-CimInstance {
        param($ClassName, $Filter, $ErrorAction)
        $fixtureState = Get-UpdateFixtureState
        [pscustomobject]@{
            CommandLine = '"{0}" -NoProfile -File "{1}"' -f (Join-Path $PSHOME 'pwsh.exe'),
                (Join-Path $fixtureState.Fixture.InstallRoot 'hooks\agent-bridge-daemon.ps1')
        }
    }
    function Stop-Process {
        param($Id, [switch]$Force, $ErrorAction)
        if (@($Id).Count -ne 1 -or $Id -ne 424242) { throw 'Unexpected process-stop fixture target.' }
        throw [IO.IOException]::new('synthetic restart denied')
    }
    if ($fixtureState.Fixture.Case -eq 'guard-child-network') {
        # A REST stub is deliberately still present. It must not authorize WebRequest.
        Remove-Item Function:\Invoke-WebRequest
    }
    & $UpdaterEntry
    exit $LASTEXITCODE
}

if ($FixtureMode -eq 'Suite') { Set-FixtureVersion '1.1.0' }
. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\bridge-update.ps1')

function Start-Process {
    [CmdletBinding()]
    param($FilePath, $ArgumentList, $WindowStyle, [switch]$Wait, [switch]$PassThru,
        $RedirectStandardOutput, $RedirectStandardError)
    $fixtureState = Get-UpdateFixtureState
    $fixtureState.Launches++
    Write-UpdateIntakeDiagnostic -Kind UPDATE -Data ([ordered]@{
        stage = 'launch-input'; case = $fixtureState.Fixture.Case; fixtureInput = $fixtureState.Fixture
        filePath = $FilePath; argumentList = $ArgumentList; wait = [bool]$Wait; passThru = [bool]$PassThru
        launches = $fixtureState.Launches
    })
    if ($fixtureState.Fixture.Case -eq 'launch-denied') { throw [IO.IOException]::new('synthetic launch denied') }
    if ($FilePath -notmatch '(^|[\\/])pwsh(?:\.exe)?$' -or @($ArgumentList).Count -ne 5 -or
        $ArgumentList[0] -cne '-NoProfile' -or $ArgumentList[1] -cne '-ExecutionPolicy' -or
        $ArgumentList[2] -cne 'Bypass' -or $ArgumentList[3] -cne '-File') {
        throw 'Unexpected process-launch fixture arguments.'
    }
    $generated = ([string]$ArgumentList[4]).Trim('"')
    Assert-BridgeTestPath -Path $generated
    $fixtureState.LastStage = Split-Path $generated -Parent
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($generated, [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'The actual generated updater failed to parse.' }
    $paths = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.StringConstantExpressionAst] -and [IO.Path]::IsPathFullyQualified($node.Value)
    }, $true) | ForEach-Object Value)
    if ($paths.Count -lt 6) { throw 'Generated updater path inventory is incomplete.' }
    Assert-BridgeTestPath -Path $paths
    $assignment = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -eq 'resultFile'
    }, $true)
    $literal = $assignment.Right.Find({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] }, $true)
    $proof = $literal.Value
    $drainDetached = -not $Wait -and $fixtureState.Fixture.Case -in @('detached-success', 'detached-failure')
    if (-not $Wait -and -not $drainDetached) { return }
    if ($Wait) { Assert-BridgeTestPath -Path @($proof, $RedirectStandardOutput, $RedirectStandardError) }
    $start = New-BridgeTestProcessStartInfo -ScriptPath $fixtureState.TestEntry -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT `
        -ScriptArguments @('Updater', $generated)
    $child = Invoke-BridgeTestProcess -StartInfo $start
    Write-UpdateIntakeDiagnostic -Kind UPDATE -Data ([ordered]@{
        stage = 'child-result'; case = $fixtureState.Fixture.Case; fixtureInput = $fixtureState.Fixture
        generated = $generated; wait = [bool]$Wait; drainDetached = $drainDetached
        actualExit = $child.ExitCode; timedOut = $child.TimedOut; seconds = $child.Seconds
        output = $child.Output
    })
    $fixtureState.ChildTimedOut = $child.TimedOut
    if ($child.TimedOut) { throw 'P6 fixture child timed out; stop the execution phase.' }
    if ($drainDetached) {
        # Drain the fixture synchronously; no real detached process can outlive a
        # test. The caller still receives launch acceptance, not a terminal result.
        $fixtureState.DetachedChildExit = $child.ExitCode
        $capture = Join-Path (Split-Path $fixtureState.Fixture.Archive -Parent) 'detached-child.log'
        Assert-BridgeTestPath -Path $capture
        $child.Output | Set-Content -LiteralPath $capture -Encoding UTF8
        return
    }
    $child.Output | Set-Content -LiteralPath $RedirectStandardOutput -Encoding UTF8
    '' | Set-Content -LiteralPath $RedirectStandardError -Encoding UTF8
    if ($fixtureState.Fixture.Case -eq 'missing-proof') { Remove-Item -LiteralPath $proof -Force }
    elseif ($fixtureState.Fixture.Case -in @('wrong-attempt', 'wrong-version-proof', 'stale-proof', 'string-true-proof', 'string-false-proof')) {
        $receipt = Get-Content -LiteralPath $proof -Raw | ConvertFrom-Json -AsHashtable
        switch ($fixtureState.Fixture.Case) {
            'wrong-attempt' { $receipt.attemptId = ('b' * 32) }
            'wrong-version-proof' { $receipt.version = '8.8.8' }
            'stale-proof' { $receipt.at = [DateTimeOffset]::Now.AddHours(-1).ToString('o') }
            'string-true-proof' { $receipt.success = 'true' }
            'string-false-proof' { $receipt.success = 'false' }
        }
        $receipt | ConvertTo-Json | Set-Content -LiteralPath $proof -Encoding UTF8
    }
    elseif ($fixtureState.Fixture.Case -eq 'daemon-race') {
        [void](Invoke-DaemonUpdateOutcome -Headers @{ Authorization = 'Bearer synthetic-test-token' })
        $fixtureState.DaemonConsumed = -not (Test-Path -LiteralPath $fixtureState.UpdateOutcomeFile)
        Assert-UpdateIntake 'daemon notification consumption leaves the private proof intact' (Test-Path -LiteralPath $proof)
    }
    elseif ($fixtureState.Fixture.Case -eq 'record-race') { Set-FixtureVersion '1.3.0' }
    $proofPresent = Test-Path -LiteralPath $proof
    Write-UpdateIntakeDiagnostic -Kind UPDATE -Data ([ordered]@{
        stage = 'private-proof-presence'; case = $fixtureState.Fixture.Case
        path = $proof; present = $proofPresent
    })
    if ($proofPresent) {
        $proofRaw = Get-Content -LiteralPath $proof -Raw
        $fixtureState.PrivateProofRaw = $proofRaw
        Write-UpdateIntakeDiagnostic -Kind UPDATE -Data ([ordered]@{
            stage = 'private-proof-content'; case = $fixtureState.Fixture.Case; path = $proof; raw = $proofRaw
        })
    }
    [pscustomobject]@{ ExitCode = [int]$child.ExitCode }
}

if ($FixtureMode -eq 'Cli') {
    function Read-Host {
        param($Prompt)
        $fixtureState = Get-UpdateFixtureState
        'prompted' | Add-Content -LiteralPath (Join-Path $fixtureState.FixtureRoot 'cli-prompts.txt')
        'yes'
    }
    try {
        & (Join-Path $PSScriptRoot '..\update.ps1') -InstallRoot $fixtureState.Fixture.InstallRoot `
            -TargetHome $env:HOME -Check:([bool]$fixtureState.Fixture.Check) -Force:([bool]$fixtureState.Fixture.Force) -Yes:([bool]$fixtureState.Fixture.Yes)
    }
    finally {
        $cliExitAtFinally = $LASTEXITCODE
        $observedFixtureState = Get-UpdateFixtureState
        @{
            fixture = $observedFixtureState.Fixture
            targetHome = $env:HOME
            restCalls = $observedFixtureState.RestCalls
            launches = $observedFixtureState.Launches
            timedOut = $observedFixtureState.ChildTimedOut
            lastExitCodeAtFinally = $cliExitAtFinally
        } | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $observedFixtureState.FixtureRoot 'cli-observation.json') -Encoding UTF8
    }
    exit $LASTEXITCODE
}

function Initialize-UpdateIntakeSuite {
    # Suites dot-source this function so the real daemon imports stay in their
    # command scope, after intake's lookup preconditions rather than before them.
    $fixtureState = Get-UpdateFixtureState
    $env:AGENT_BRIDGE_DAEMON_NORUN = '1'
    . (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
    $fixtureState.UpdateOutcomeFile = $script:DaemonConfig.UpdateOutcomeFile
    # Mock the RPC boundary after the daemon has imported its real entity-id consumers.
    function Invoke-CopilotHaWebSocket {
        param($Commands)
        if (@($Commands).Count -ne 1 -or $Commands[0].type -ne 'config/entity_registry/list') { throw 'Unexpected WebSocket fixture command.' }
        $replies = [Collections.Generic.List[object]]::new()
        $replies.Add([object[]]@([pscustomobject]@{ unique_id = 'unrelated-fixture'; entity_id = 'sensor.fixture' }))
        return ,$replies.ToArray()
    }
    $fixtureState.DefaultInstallRoot = (Get-BridgeInstallContext).BridgeHome
    $fixtureHooks = Join-Path $fixtureState.DefaultInstallRoot 'hooks'
    $fixtureRuntime = Join-Path $fixtureState.DefaultInstallRoot 'runtime'
    Assert-BridgeTestPath -Path @($fixtureState.FixtureRoot, $fixtureHooks, $fixtureRuntime)
    New-Item -ItemType Directory -Path $fixtureState.FixtureRoot, $fixtureHooks, $fixtureRuntime -Force | Out-Null
    foreach ($source in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\hooks') -File -Filter '*.ps1') {
        Assert-BridgeTestPath -Path $source.FullName -SourceEntry
        $destination = Join-Path $fixtureHooks $source.Name
        Assert-BridgeTestPath -Path $destination
        Copy-Item -LiteralPath $source.FullName -Destination $destination
    }
    $fixtureState.InertInstaller = @'
param([switch]$NonInteractive, [switch]$SkipVerify, [string]$TargetHome,
    [string]$InstallRoot, [switch]$SkipTask, [switch]$SkipPath, [switch]$SkipDependencies)
$ErrorActionPreference = 'Stop'
Assert-BridgeTestEnvironment -Required
$fixtureFile = Join-Path $env:AGENT_HA_BRIDGE_TEST_ROOT 'update-fixture.json'
Assert-BridgeTestPath -Path @($fixtureFile, $InstallRoot)
$fixture = Get-Content -LiteralPath $fixtureFile -Raw | ConvertFrom-Json -AsHashtable
$called = Join-Path $InstallRoot 'inert-installer-called.txt'
$config = Join-Path $InstallRoot 'config.json'
Assert-BridgeTestPath -Path @($called, $config)
Set-Content -LiteralPath $called -Value $fixture.Case
if ($fixture.Case -in @('installer-exit', 'detached-failure')) { exit 23 }
if ($fixture.Case -eq 'installer-throw') { throw 'synthetic installer failure' }
$saved = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json -AsHashtable
$saved['updates']['installedVersion'] = $fixture.Target
$saved | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $config -Encoding UTF8
if ($fixture.Case -eq 'partial-failure') { throw 'synthetic failure after version mutation' }
exit 0
'@
}

function New-UpdateFixture {
    param([string]$Case, [string]$Target = '1.2.0', [string]$Lookup = 'found',
        [switch]$Check, [switch]$Force, [switch]$Yes)
    $fixtureState = Get-UpdateFixtureState
    $directory = Join-Path $fixtureState.FixtureRoot $Case
    $release = Join-Path $directory 'release'
    $archive = Join-Path $directory 'fixture.zip'
    Assert-BridgeTestPath -Path @($directory, $release, $archive)
    New-Item -ItemType Directory -Path $release -Force | Out-Null
    $installer = Join-Path $release 'install.ps1'
    $version = Join-Path $release 'VERSION'
    Assert-BridgeTestPath -Path @($installer, $version)
    $fixtureState.InertInstaller | Set-Content -LiteralPath $installer -Encoding UTF8
    if ($Case -eq 'incapable-installer') { 'param([switch]$NonInteractive) throw "must not execute"' | Set-Content -LiteralPath $installer }
    if ($Case -ne 'missing-version') {
        $(if ($Case -eq 'wrong-version') { '7.7.7' } else { $Target }) | Set-Content -LiteralPath $version
    }
    if ($Case -eq 'corrupt-zip') { 'not an archive' | Set-Content -LiteralPath $archive }
    elseif ($Case -eq 'multiple-roots') {
        $other = Join-Path $directory 'other'
        Assert-BridgeTestPath -Path $other
        New-Item -ItemType Directory -Path $other | Out-Null
        'second root' | Set-Content -LiteralPath (Join-Path $other 'entry.txt')
        Compress-Archive -LiteralPath @($release, $other) -DestinationPath $archive
    }
    else { Compress-Archive -LiteralPath $release -DestinationPath $archive }
    $fixtureState.Fixture = @{
        Case = $Case; Target = $Target; Lookup = $Lookup; Archive = $archive
        InstallRoot = $fixtureState.DefaultInstallRoot; Check = [bool]$Check; Force = [bool]$Force; Yes = [bool]$Yes
    }
    $fixtureState.Fixture | ConvertTo-Json | Set-Content -LiteralPath $fixtureState.FixtureFile -Encoding UTF8
    Set-FixtureVersion '1.1.0'
    $fixtureState.Launches = 0
    $fixtureState.ChildTimedOut = $false
    $fixtureState.PrivateProofRaw = $null
    $fixtureState.DaemonConsumed = $false
    $fixtureState.DetachedChildExit = $null
    $fixtureState.LastStage = ''
    foreach ($path in @(
        $script:BridgeUpdateConfig.CacheFile, $script:DaemonConfig.UpdateOutcomeFile,
        (Join-Path $fixtureState.DefaultInstallRoot 'inert-installer-called.txt'),
        (Join-Path $fixtureState.FixtureRoot 'cli-prompts.txt'), (Join-Path $fixtureState.FixtureRoot 'cli-observation.json')
    )) {
        Assert-BridgeTestPath -Path $path
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}
