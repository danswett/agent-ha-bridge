#Requires -Version 7.0

function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = $_.Exception.Message }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name - $Detail"; $script:Failures++ }
}

function Write-BoundaryRecord {
    param([string]$Prefix, [Collections.IDictionary]$Record)
    $Record['AtPacific'] = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId(
        [DateTimeOffset]::Now, 'Pacific Standard Time').ToString('o')
    # InformationRecord serialization lost the last timestamp when the suite died.
    [Console]::Out.WriteLine($Prefix + ' ' + ($Record | ConvertTo-Json -Depth 10 -Compress))
    [Console]::Out.Flush()
}

function Set-BoundaryPhase {
    param(
        [Parameter(Mandatory)]$Trace,
        [AllowEmptyString()][string]$Phase,
        [bool]$PreviousSucceeded = $true
    )
    if ($Trace.Phase) {
        $Trace.PhaseClock.Stop()
        $seconds = [Math]::Round($Trace.PhaseClock.Elapsed.TotalSeconds, 6)
        $Trace.Durations[$Trace.Phase] = $seconds
        Write-BoundaryRecord -Prefix 'S1-CASE-TIMING' -Record ([ordered]@{
            Suite = $Trace.Suite; Case = $Trace.Case; Event = 'phase-end'; Phase = $Trace.Phase
            Seconds = $seconds; Succeeded = $PreviousSucceeded
            CaseSeconds = [Math]::Round($Trace.CaseClock.Elapsed.TotalSeconds, 6)
        })
    }
    $Trace.Phase = $Phase
    if ($Phase) {
        $Trace.PhaseClock.Restart()
        Write-BoundaryRecord -Prefix 'S1-CASE-TIMING' -Record ([ordered]@{
            Suite = $Trace.Suite; Case = $Trace.Case; Event = 'phase-start'; Phase = $Phase
            CaseSeconds = [Math]::Round($Trace.CaseClock.Elapsed.TotalSeconds, 6)
        })
    }
}

function Get-ProtectedFixtureSnapshot {
    param([Parameter(Mandatory)][string]$HomeDirectory)
    Assert-BridgeTestEnvironment -Required
    Assert-BridgeTestPath -Path $HomeDirectory
    @(
        Get-ChildItem -LiteralPath $HomeDirectory -Recurse -Force | Sort-Object FullName | ForEach-Object {
            @{
                Path = [IO.Path]::GetRelativePath($HomeDirectory, $_.FullName)
                Kind = $(if ($_.PSIsContainer) { 'directory' } else { 'file' })
                Hash = $(if ($_.PSIsContainer) { '' } else { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
            }
        }
    ) | ConvertTo-Json -Depth 4 -Compress -AsArray
}

function New-BoundaryFixture {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('test-write-boundary-context.ps1', 'test-write-boundary-callers.ps1')]
        [string]$Suite
    )
    Assert-BridgeTestEnvironment -Required
    # The canonical suite root is already unique; another GUID here makes nested
    # Windows link paths fail before containment can be exercised.
    $scratch = Join-Path $env:TEMP 'b'
    $protectedHome = Join-Path $scratch 'protected-home'
    $protectedBridge = Join-Path $protectedHome '.agent-ha-bridge'
    $protectedHooks = Join-Path $protectedBridge 'hooks'
    Assert-BridgeTestPath -Path @($scratch, $protectedHome, $protectedHooks)
    if (Test-Path -LiteralPath $scratch) {
        throw 'The boundary fixture scratch path already exists; nothing was overwritten.'
    }
    $fixture = [pscustomobject]@{
        Suite = $Suite; Scratch = $scratch; ProtectedHome = $protectedHome; ProtectedHooks = $protectedHooks
        ProtectedBefore = ''; SavedEnvironment = @{}; Evidence = [Collections.Generic.List[object]]::new()
        Clock = [Diagnostics.Stopwatch]::StartNew()
    }
    $initialized = $false
    try {
        Write-BoundaryRecord -Prefix 'S1-SUITE-START' -Record ([ordered]@{ Suite = $Suite })
        Write-BoundaryRecord -Prefix 'S1-FIXTURE-TIMING' -Record ([ordered]@{
            Suite = $Suite; Operation = 'suite-setup'; Event = 'phase-start'
        })
        [void][IO.Directory]::CreateDirectory($protectedHooks)
        foreach ($relative in @('hooks\decision-bridge-common.ps1', 'hooks\bridge-update.ps1', 'config.json')) {
            [IO.File]::WriteAllText((Join-Path $protectedBridge $relative), "protected sentinel: $relative")
        }
        $fixture.ProtectedBefore = Get-ProtectedFixtureSnapshot -HomeDirectory $protectedHome
        $poison = @{
            AGENT_HA_TOKEN = 'synthetic-parent-token'
            AGENT_HA_AGENT_TOKEN = 'synthetic-parent-agent-token'
            CUSTOM_HOUSE_CREDENTIAL = 'synthetic-custom-token'
            BRIDGE_ALLOW_TEST_HTTP = '1'
            AGENT_HA_BRIDGE_TEST_LOOPBACK_ORIGIN = 'http://127.0.0.1:1'
            COPILOT_HA_BRIDGE_CONFIG = (Join-Path $scratch 'not-a-config.json')
            HTTPS_PROXY = 'http://proxy.invalid:1'
            NODE_OPTIONS = '--require=not-a-module'
            GIT_CONFIG_COUNT = '1'
        }
        foreach ($key in $poison.Keys) {
            $fixture.SavedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key)
            [Environment]::SetEnvironmentVariable($key, $poison[$key], 'Process')
        }
        Write-BoundaryRecord -Prefix 'S1-PROTECTED-BEFORE' -Record ([ordered]@{
            Suite = $Suite; ProtectedHome = $protectedHome
            Snapshot = ($fixture.ProtectedBefore | ConvertFrom-Json)
        })
        $initialized = $true
        $fixture
    }
    finally {
        Write-BoundaryRecord -Prefix 'S1-FIXTURE-TIMING' -Record ([ordered]@{
            Suite = $Suite; Operation = 'suite-setup'; Event = 'phase-end'; Succeeded = $initialized
            Seconds = [Math]::Round($fixture.Clock.Elapsed.TotalSeconds, 6)
        })
        if (-not $initialized) { Remove-BoundaryFixture -Fixture $fixture }
    }
}

function Invoke-BoundaryFixture {
    param(
        [Parameter(Mandatory)]$Fixture,
        [string]$Name, [string]$Body, [switch]$Refused, [switch]$DirectEntry
    )
    $trace = [pscustomobject]@{
        Suite = $Fixture.Suite; Case = $Name; Phase = ''
        CaseClock = [Diagnostics.Stopwatch]::StartNew(); PhaseClock = [Diagnostics.Stopwatch]::new()
        Durations = [ordered]@{ setup = $null; child = $null; sentinel = $null; cleanup = $null }
    }
    Write-BoundaryRecord -Prefix 'S1-CASE-START' -Record ([ordered]@{
        Suite = $Fixture.Suite; Case = $Name; ExpectedRefusal = [bool]$Refused
    })
    Set-BoundaryPhase -Trace $trace -Phase 'setup'
    $box = $null
    $childResult = $null
    $caseSucceeded = $false
    $cleanupSucceeded = $false
    try {
        Assert-BridgeTestEnvironment -Required
        Assert-BridgeTestPath -Path @($Fixture.Scratch, $Fixture.ProtectedHome)
        $box = New-BridgeTestSandbox -ParentDirectory $Fixture.Scratch
        $entryName = $(if ($DirectEntry) { 'test-boundary-' } else { 'boundary-' }) + [guid]::NewGuid().ToString('N') + '.ps1'
        $entryPath = Join-Path $box $entryName
        $prefix = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = '__REPOSITORY__'
$protectedHome = '__PROTECTED__'
$protectedBridge = Join-Path $protectedHome '.agent-ha-bridge'
$protectedHooks = Join-Path $protectedBridge 'hooks'
. (Join-Path $repository 'hooks\decision-bridge-common.ps1')
. (Join-Path $repository 'tests\runner-support.ps1')
$context = Get-BridgeInstallContext
try {
'@
        $suffix = @'
}
catch {
    if ($_.Exception.Data['BridgeTestWriteBlocked']) { Write-Output 'BOUNDARY-MARKED-REFUSAL' }
    throw
}
'@
        $text = $prefix.Replace('__REPOSITORY__', $script:BridgeTestRepository.Replace("'", "''")).
            Replace('__PROTECTED__', $Fixture.ProtectedHome.Replace("'", "''")) + "`n" + $Body + "`n" + $suffix
        Set-Content -LiteralPath $entryPath -Value $text -Encoding utf8
        $start = New-BridgeTestProcessStartInfo -ScriptPath $entryPath -Sandbox $box
        Set-BoundaryPhase -Trace $trace -Phase 'child'
        $childResult = Invoke-BridgeTestProcess -StartInfo $start
        Set-BoundaryPhase -Trace $trace -Phase 'sentinel' -PreviousSucceeded (-not $childResult.TimedOut)
        $snapshot = Get-ProtectedFixtureSnapshot -HomeDirectory $Fixture.ProtectedHome
        $unchanged = $snapshot -ceq $Fixture.ProtectedBefore
        $marked = $childResult.Output -match '(?m)^BOUNDARY-MARKED-REFUSAL\r?$'
        $evidence = [ordered]@{
            Suite = $Fixture.Suite; Case = $Name; ExitCode = $childResult.ExitCode; TimedOut = $childResult.TimedOut
            Marked = $marked; SentinelsAndInventoryUnchanged = $unchanged; Sandbox = $box
            Snapshot = ($snapshot | ConvertFrom-Json)
        }
        $Fixture.Evidence.Add($evidence)
        Write-BoundaryRecord -Prefix 'S1-CONTAINMENT' -Record $evidence
        foreach ($line in $childResult.Output -split '\r?\n') {
            if ($line -match '^(STAGED-REFERENCES |DESCENDANT-ROOTS |RECONCILE-SNAPSHOT-CLEARED$)') {
                [Console]::Out.WriteLine($line)
                [Console]::Out.Flush()
            }
        }
        if ($childResult.TimedOut -or -not $unchanged -or
            ($Refused -and ($childResult.ExitCode -eq 0 -or -not $marked)) -or
            (-not $Refused -and $childResult.ExitCode -ne 0)) {
            Write-Host $childResult.Output
            throw "The $Name fixture did not reach its required real boundary outcome; stopping."
        }
        Test-That "$Name preserves the protected bytes and directory inventory" { $unchanged }
        if ($Refused) {
            Test-That "$Name propagates the marked refusal as a nonzero child result" {
                $childResult.ExitCode -ne 0 -and $marked
            }
        }
        else { Test-That "$Name completes through the actual helper" { $childResult.ExitCode -eq 0 } }
        $caseSucceeded = $true
    }
    finally {
        Set-BoundaryPhase -Trace $trace -Phase 'cleanup' -PreviousSucceeded $caseSucceeded
        try {
            if ($box) { Remove-BridgeTestSandbox -Sandbox $box }
            $cleanupSucceeded = $true
        }
        finally {
            Set-BoundaryPhase -Trace $trace -Phase '' -PreviousSucceeded $cleanupSucceeded
            $trace.CaseClock.Stop()
            Write-BoundaryRecord -Prefix 'S1-CASE-END' -Record ([ordered]@{
                Suite = $Fixture.Suite; Case = $Name; Succeeded = ($caseSucceeded -and $cleanupSucceeded)
                Seconds = [Math]::Round($trace.CaseClock.Elapsed.TotalSeconds, 6); Phases = $trace.Durations
            })
        }
    }
    $childResult
}

function Complete-BoundaryFixture {
    param([Parameter(Mandatory)]$Fixture)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Write-BoundaryRecord -Prefix 'S1-FIXTURE-TIMING' -Record ([ordered]@{
        Suite = $Fixture.Suite; Operation = 'final-sentinel'; Event = 'phase-start'
    })
    try {
        $after = Get-ProtectedFixtureSnapshot -HomeDirectory $Fixture.ProtectedHome
        Write-BoundaryRecord -Prefix 'S1-PROTECTED-SENTINELS' -Record ([ordered]@{
            Suite = $Fixture.Suite; ProtectedHome = $Fixture.ProtectedHome
            Before = ($Fixture.ProtectedBefore | ConvertFrom-Json); After = ($after | ConvertFrom-Json)
            Unchanged = ($after -ceq $Fixture.ProtectedBefore); CompletedCases = $Fixture.Evidence.Count
            Seconds = [Math]::Round($Fixture.Clock.Elapsed.TotalSeconds, 6)
        })
        Test-That 'every real refusal leaves protected common, updater, config and inventory unchanged' {
            $after -ceq $Fixture.ProtectedBefore
        }
    }
    finally {
        $clock.Stop()
        Write-BoundaryRecord -Prefix 'S1-FIXTURE-TIMING' -Record ([ordered]@{
            Suite = $Fixture.Suite; Operation = 'final-sentinel'; Event = 'phase-end'
            Seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 6)
        })
    }
}

function Remove-BoundaryFixture {
    param([Parameter(Mandatory)]$Fixture)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Write-BoundaryRecord -Prefix 'S1-FIXTURE-TIMING' -Record ([ordered]@{
        Suite = $Fixture.Suite; Operation = 'suite-cleanup'; Event = 'phase-start'
    })
    try {
        Assert-BridgeTestEnvironment -Required
        Assert-BridgeTestPath -Path $Fixture.Scratch
        if (Test-Path -LiteralPath $Fixture.Scratch) {
            Remove-BridgeTestSandbox -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT -Directory $Fixture.Scratch
        }
    }
    finally {
        foreach ($key in $Fixture.SavedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $Fixture.SavedEnvironment[$key], 'Process')
        }
        $Fixture.Clock.Stop()
        $clock.Stop()
        Write-BoundaryRecord -Prefix 'S1-FIXTURE-TIMING' -Record ([ordered]@{
            Suite = $Fixture.Suite; Operation = 'suite-cleanup'; Event = 'phase-end'
            Seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 6)
        })
    }
}
