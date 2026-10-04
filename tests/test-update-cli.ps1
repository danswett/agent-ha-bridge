#Requires -Version 7.0
<#
.SYNOPSIS
    Truthful check-only, Force, failure and selected-root CLI behavior.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('Suite', 'Updater', 'Cli')][string]$Mode = 'Suite',
    [Parameter(Position = 1)][string]$Entry = ''
)

. (Join-Path $PSScriptRoot 'update-intake-fixture.ps1') -FixtureMode $Mode -TestEntryPath $PSCommandPath -UpdaterEntry $Entry
if ($Mode -ne 'Suite') { exit $LASTEXITCODE }
. Initialize-UpdateIntakeSuite

foreach ($intent in @(
    @{ Case = 'check-unavailable'; Lookup = 'unavailable'; Target = '1.2.0'; Force = $false; Exit = 1 },
    @{ Case = 'check-not-found'; Lookup = 'http-404'; Target = '1.2.0'; Force = $true; Exit = 1 },
    @{ Case = 'check-available'; Lookup = 'found'; Target = '1.2.0'; Force = $false; Exit = 0 },
    @{ Case = 'check-force-current'; Lookup = 'found'; Target = '1.1.0'; Force = $true; Exit = 0 },
    @{ Case = 'check-force-older'; Lookup = 'found'; Target = '1.0.0'; Force = $true; Exit = 0 }
)) {
    New-UpdateFixture -Case $intent.Case -Target $intent.Target -Lookup $intent.Lookup -Check -Force:$intent.Force
    $start = New-BridgeTestProcessStartInfo -ScriptPath $fixtureState.TestEntry -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT -ScriptArguments @('Cli')
    $child = Invoke-BridgeTestProcess -StartInfo $start
    Write-UpdateCliDiagnostic -Case $intent.Case -Child $child -ExpectedExit $intent.Exit
    Assert-UpdateIntake "$($intent.Case) completes within its normal child limit" (-not $child.TimedOut)
    $observation = Get-Content -LiteralPath (Join-Path $fixtureState.FixtureRoot 'cli-observation.json') -Raw | ConvertFrom-Json
    $expectedReason = switch ($intent.Lookup) {
        'unavailable' { 'The latest release could not be established: synthetic lookup outage' }
        'http-404' { 'GitHub returned 404 for the latest-release endpoint; repository existence and access are not confirmed.' }
        'found' {
            if ($intent.Case -eq 'check-available') { 'Available; check only, nothing installed.' }
            else { 'Current; check only, nothing installed.' }
        }
    }
    $expectedLatest = if ($intent.Lookup -eq 'found') { $intent.Target } else { 'not established' }
    $reasonMatches = $child.Output -match [regex]::Escape($expectedReason) -and
        $child.Output -match ('(?m)^\s*latest\s*:\s*{0}\s*$' -f [regex]::Escape($expectedLatest))
    Write-UpdateIntakeDiagnostic -Kind UPDATE -Data ([ordered]@{
        stage = 'check-causal-operands'; case = $intent.Case; restCalls = $observation.restCalls
        expectedReason = $expectedReason; expectedLatest = $expectedLatest; reasonMatches = $reasonMatches
        actualExit = $child.ExitCode; expectedExit = $intent.Exit
        launches = $observation.launches; flags = $observation.fixture
    })
    Assert-UpdateIntake "$($intent.Case) reaches the intended REST boundary exactly once" ($observation.restCalls -eq 1)
    Assert-UpdateIntake "$($intent.Case) reports the intended lookup reason and latest value" $reasonMatches
    Assert-UpdateIntake "$($intent.Case) has the truthful CLI exit without launching or prompting" (
        $child.ExitCode -eq $intent.Exit -and $observation.launches -eq 0 -and
        -not (Test-Path -LiteralPath (Join-Path $fixtureState.FixtureRoot 'cli-prompts.txt')))
}

if ($IsWindows) {
    foreach ($target in @('1.1.0', '1.0.0')) {
        New-UpdateFixture -Case "cli-force-$target" -Target $target -Force -Yes
        $start = New-BridgeTestProcessStartInfo -ScriptPath $fixtureState.TestEntry -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT -ScriptArguments @('Cli')
        $child = Invoke-BridgeTestProcess -StartInfo $start
        Write-UpdateCliDiagnostic -Case $fixtureState.Fixture.Case -Child $child -ExpectedExit 0
        $observation = Get-Content -LiteralPath (Join-Path $fixtureState.FixtureRoot 'cli-observation.json') -Raw | ConvertFrom-Json
        Assert-UpdateIntake "CLI Force reaches the real updater and reinstalls $target" (
            -not $child.TimedOut -and -not $observation.timedOut -and $child.ExitCode -eq 0 -and
            $observation.launches -eq 1 -and $(
                $cliInstalledOperand = Get-BridgeInstalledVersion -Refresh
                Write-UpdateIntakeDiagnostic -Kind UPDATE -Data ([ordered]@{
                    stage = 'cli-installed-operand'; case = $fixtureState.Fixture.Case
                    actual = $cliInstalledOperand; expected = $target
                })
                $cliInstalledOperand -eq $target
            ))
    }
    New-UpdateFixture -Case 'installer-exit-cli' -Yes
    $fixtureState.Fixture.Case = 'installer-exit'
    $fixtureState.Fixture | ConvertTo-Json | Set-Content -LiteralPath $fixtureState.FixtureFile
    $start = New-BridgeTestProcessStartInfo -ScriptPath $fixtureState.TestEntry -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT -ScriptArguments @('Cli')
    $child = Invoke-BridgeTestProcess -StartInfo $start
    Write-UpdateCliDiagnostic -Case $fixtureState.Fixture.Case -Child $child -ExpectedExit 'nonzero'
    Assert-UpdateIntake 'CLI failure exits nonzero without success or restart guidance' (
        -not $child.TimedOut -and $child.ExitCode -ne 0 -and $child.Output -match 'installer exited with code 23' -and
        $child.Output -notmatch 'Restart any running')

    New-UpdateFixture -Case 'cli-quoted-root' -Yes
    $quotedRoot = Join-Path $env:HOME "bridge's selected root"
    $quotedRuntime = Join-Path $quotedRoot 'runtime'
    $quotedHooks = Join-Path $quotedRoot 'hooks'
    $quotedConfig = Join-Path $quotedRoot 'config.json'
    Assert-BridgeTestPath -Path @($quotedRoot, $quotedRuntime, $quotedHooks, $quotedConfig)
    New-Item -ItemType Directory -Path $quotedRoot, $quotedRuntime, $quotedHooks | Out-Null
    Copy-Item -LiteralPath $env:AGENT_HA_BRIDGE_CONFIG -Destination $quotedConfig
    foreach ($source in Get-ChildItem -LiteralPath $fixtureHooks -File) {
        Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $quotedHooks $source.Name)
    }
    $fixtureState.Fixture.InstallRoot = $quotedRoot
    $fixtureState.Fixture | ConvertTo-Json | Set-Content -LiteralPath $fixtureState.FixtureFile
    $start = New-BridgeTestProcessStartInfo -ScriptPath $fixtureState.TestEntry -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT -ScriptArguments @('Cli')
    $child = Invoke-BridgeTestProcess -StartInfo $start
    Write-UpdateCliDiagnostic -Case $fixtureState.Fixture.Case -Child $child -ExpectedExit 0
    $selected = Get-Content -LiteralPath $quotedConfig -Raw | ConvertFrom-Json
    $ambient = Get-Content -LiteralPath $env:AGENT_HA_BRIDGE_CONFIG -Raw | ConvertFrom-Json
    Write-UpdateIntakeDiagnostic -Kind UPDATE -Data ([ordered]@{
        stage = 'selected-root-operands'; case = $fixtureState.Fixture.Case
        selectedVersion = $selected.updates.installedVersion; ambientVersion = $ambient.updates.installedVersion
        actualExit = $child.ExitCode; timedOut = $child.TimedOut
    })
    Assert-UpdateIntake 'quoted-root CLI update changes only its selected synthetic installation' (
        -not $child.TimedOut -and $child.ExitCode -eq 0 -and
        $selected.updates.installedVersion -eq '1.2.0' -and $ambient.updates.installedVersion -eq '1.1.0')
    Remove-BridgeTestSandbox -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT -Directory $quotedRoot
}
else { Write-Host '  SKIP  generated-child/repair execution: only the Windows OS transport fixture is defined.' }

Remove-BridgeTestSandbox -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT -Directory $fixtureState.FixtureRoot
Remove-BridgeTestSandbox -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT -Directory $fixtureHooks
Remove-Item -LiteralPath $fixtureState.FixtureFile -Force
Write-Host 'All focused update CLI checks passed'
exit 0
