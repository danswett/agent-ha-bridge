#Requires -Version 7.0
<#
.SYNOPSIS
    Truthful lookup and attributable direct-updater completion.
.DESCRIPTION
    The REST-boundary precondition precedes the controlled semantic red and all
    generated execution. CLI intent cases live in test-update-cli.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('Suite', 'Updater', 'Cli')][string]$Mode = 'Suite',
    [Parameter(Position = 1)][string]$Entry = ''
)

. (Join-Path $PSScriptRoot 'update-intake-fixture.ps1') -FixtureMode $Mode -TestEntryPath $PSCommandPath -UpdaterEntry $Entry
if ($Mode -ne 'Suite') { exit $LASTEXITCODE }

# Prove the intended outage before the semantic red; no generated work runs on red.
$unreachable = Get-BridgeUpdateStatus -Force
Assert-UpdateIntake 'the semantic case reached the intended REST boundary exactly once' ($fixtureState.RestCalls -eq 1)
Assert-UpdateIntake 'an unreachable lookup never claims the installed version is latest' ($null -eq $unreachable.Latest)
Assert-UpdateIntake 'unavailable is distinct from current and available' ($unreachable.State -eq 'Unavailable' -and -not $unreachable.Available)
foreach ($code in @(401, 403, 404, 429, 500)) {
    $fixtureState.Fixture.Lookup = "http-$code"
    $status = Get-BridgeUpdateStatus -Force
    # 429 is a rate limit by definition, and is now named as one so the operator is
    # told to wait rather than to go looking for a broken release. A bare 403 carries
    # no rate-limit headers here and stays Unavailable, because 403 on its own is also
    # what a private repository and a bad token return.
    $expected = if ($code -eq 404) { 'NotFound' } elseif ($code -eq 429) { 'RateLimited' } else { 'Unavailable' }
    Assert-UpdateIntake "HTTP $code has no invented latest version" ($status.State -eq $expected -and $null -eq $status.Latest)
    $refused = Invoke-BridgeSelfUpdate -Force
    Assert-UpdateIntake "Force cannot turn HTTP $code into an install target" (-not $refused.Started -and $refused.State -eq $expected -and $fixtureState.Launches -eq 0)
    if ($code -eq 404) { Assert-UpdateIntake '404 does not assert repository existence or access' ($status.Detail -match 'existence and access are not confirmed') }
    if ($code -eq 429) { Assert-UpdateIntake '429 says the install is fine and the limit will reset' ($status.Detail -match 'rate limiting' -and $status.Detail -match 'install is fine') }
}
$fixtureState.Fixture.Lookup = 'invalid'
$invalid = Invoke-BridgeSelfUpdate -Force
Assert-UpdateIntake 'Force cannot install malformed release metadata' (-not $invalid.Started -and $invalid.State -eq 'Unavailable')
$restStub = (Get-Item Function:\Invoke-RestMethod).ScriptBlock
Remove-Item Function:\Invoke-RestMethod
$blocked = $false
try { [void](Invoke-BridgeSelfUpdate -Force) }
catch { $blocked = [bool]$_.Exception.Data['BridgeTestNetworkBlocked'] }
finally { Set-Item Function:\Invoke-RestMethod -Value $restStub }
Assert-UpdateIntake 'the real lookup guard propagates through self-update' $blocked

$fixtureState.Fixture.Lookup = 'found'
$before = $fixtureState.RestCalls
@{ CheckedAt = [DateTimeOffset]::Now.ToString('o'); Release = $null } | ConvertTo-Json |
    Set-Content -LiteralPath $script:BridgeUpdateConfig.CacheFile -Encoding UTF8
$legacy = Get-BridgeUpdateStatus
Assert-UpdateIntake 'a fresh legacy null cache is unknown and bounded, not a confirmed 404' ($legacy.State -eq 'Unavailable' -and $fixtureState.RestCalls -eq $before)

. Initialize-UpdateIntakeSuite

foreach ($target in @('1.1.0', '1.0.0')) {
    New-UpdateFixture -Case "ordinary-$target" -Target $target
    $result = Invoke-BridgeSelfUpdate
    Write-UpdateResultDiagnostic -Result $result -Expected @{ State = 'Current'; Started = $false; Launches = 0 }
    Assert-UpdateIntake "ordinary update does not reinstall or downgrade to $target" ($result.State -eq 'Current' -and -not $result.Started -and $fixtureState.Launches -eq 0)
}

if ($IsWindows) {
    foreach ($case in @('detached-success', 'detached-failure')) {
        New-UpdateFixture -Case $case
        $result = Invoke-BridgeSelfUpdate -Detached
        Write-UpdateResultDiagnostic -Result $result -Expected @{ State = 'Started'; Started = $true; Success = $false }
        $notice = Read-BridgeUpdateOutcome -Path $script:DaemonConfig.UpdateOutcomeFile
        $success = $case -eq 'detached-success'
        Write-UpdateResultDiagnostic -Stage 'terminal-notice' -Result $notice -Expected @{
            Success = $success; AttemptId = $result.AttemptId; ChildExit = $(if ($success) { 0 } else { 1 })
        }
        Assert-UpdateIntake "$case remains launch-only at the parent" ($result.Started -and -not $result.Success -and $result.State -eq 'Started' -and -not $fixtureState.ChildTimedOut)
        Assert-UpdateIntake "$case writes its actual typed terminal notice" (
            $notice.Success -eq $success -and $notice.AttemptId -ceq $result.AttemptId -and
            $fixtureState.DetachedChildExit -eq $(if ($success) { 0 } else { 1 }))
        Assert-UpdateIntake "$case removes its child-owned stage" (-not (Test-Path -LiteralPath $fixtureState.LastStage))
    }
    foreach ($case in @(
        'corrupt-zip', 'missing-version', 'wrong-version', 'multiple-roots', 'incapable-installer',
        'installer-exit', 'installer-throw', 'partial-failure', 'restart-denied',
        'missing-proof', 'wrong-attempt', 'wrong-version-proof', 'stale-proof', 'string-true-proof', 'string-false-proof',
        'launch-denied', 'valid', 'daemon-race', 'record-race'
    )) {
        New-UpdateFixture -Case $case
        $result = Invoke-BridgeSelfUpdate
        Write-UpdateResultDiagnostic -Result $result -Expected @{ Success = ($case -in @('valid', 'daemon-race', 'record-race')); AttemptedVersion = '1.2.0' }
        Assert-UpdateIntake "$case does not hide a fixture timeout" (-not $fixtureState.ChildTimedOut)
        $success = $case -in @('valid', 'daemon-race', 'record-race')
        Assert-UpdateIntake "$case has a typed, attempt-attributable outcome" (
            $result.Success -is [bool] -and $result.Success -eq $success -and
            $result.State -eq $(if ($success) { 'Completed' } else { 'Failed' }) -and
            $result.AttemptedVersion -eq '1.2.0')
        if ($case -eq 'corrupt-zip') {
            Assert-UpdateIntake 'a corrupt archive supplies its actual private terminal receipt' (
                $fixtureState.PrivateProofRaw -is [string] -and -not [string]::IsNullOrWhiteSpace($fixtureState.PrivateProofRaw))
            $receipt = $fixtureState.PrivateProofRaw | ConvertFrom-Json -AsHashtable
            $archiveCause = 'Central Directory corrupt.'
            Write-UpdateIntakeDiagnostic -Kind UPDATE -Data ([ordered]@{
                stage = 'archive-failure-operands'; case = $case; receipt = $receipt
                parentDetail = $result.Detail; expectedCause = $archiveCause
            })
            Assert-UpdateIntake 'a corrupt archive receipt attributes a typed failure to the actual attempt' (
                $receipt.schemaVersion -eq 1 -and $receipt.success -is [bool] -and -not $receipt.success -and
                ($receipt.exitCode -is [int] -or $receipt.exitCode -is [long]) -and $receipt.exitCode -eq 1 -and
                $receipt.attemptId -ceq $result.AttemptId -and $receipt.version -ceq $result.AttemptedVersion)
            Assert-UpdateIntake 'the private terminal receipt preserves the real inner ZIP failure' (
                $receipt.error -is [string] -and $receipt.error.Contains($archiveCause))
            Assert-UpdateIntake 'the real parent retains the archive cause instead of rejecting empty failure details' (
                $result.Detail.Contains($receipt.error) -and $result.Detail -match 'child exit 1' -and
                $result.Detail -notmatch 'invalid release or failure details')
        }
        if ($success) {
            Assert-UpdateIntake "$case does not certify required local health" ($result.Detail -match 'health is not certified')
            # Declining to certify is right; ending on it was not. The installer's own
            # check prints every probe green and "All good" seconds earlier, so a
            # successful update that finishes on a disclaimer reads as a failure and
            # sends people hunting for an updater fault (#124). It leads with what
            # happened, and names the command that closes the gap.
            Assert-UpdateIntake "$case leads with the update succeeding, not with the caveat" (
                $result.Detail -match '^updated to ' -and $result.Detail -notmatch '^installer completed')
            Assert-UpdateIntake "$case says how to certify what it will not" ($result.Detail -match 'agent-ha-bridge status')
        }
        $observed = if ($case -eq 'record-race') { '1.3.0' }
            elseif ($case -in @('partial-failure', 'restart-denied', 'missing-proof', 'wrong-attempt', 'wrong-version-proof', 'stale-proof', 'string-true-proof', 'string-false-proof', 'valid', 'daemon-race')) { '1.2.0' }
            else { '1.1.0' }
        Write-UpdateIntakeDiagnostic -Kind UPDATE -Data ([ordered]@{
            stage = 'installed-record-operands'; case = $case
            actual = $result.InstalledVersion; expected = $observed
        })
        Assert-UpdateIntake "$case reports the actual version record, not an assumed rollback" ($result.InstalledVersion -eq $observed)
        if ($case -in @('corrupt-zip', 'missing-version', 'wrong-version', 'multiple-roots', 'incapable-installer', 'launch-denied')) {
            Assert-UpdateIntake "$case never reaches even the inert installer" (-not (Test-Path -LiteralPath (Join-Path $fixtureState.DefaultInstallRoot 'inert-installer-called.txt')))
        }
        if ($case -eq 'installer-exit') { Assert-UpdateIntake 'a nonzero installer exit survives into failure detail' ($result.Detail -match 'installer exited with code 23') }
        if ($case -eq 'restart-denied') { Assert-UpdateIntake 'real owned-runtime stop failure prevents completion' ($result.Detail -match 'synthetic restart denied') }
        if ($case -eq 'daemon-race') { Assert-UpdateIntake 'parent completion survives real daemon notice consumption' $fixtureState.DaemonConsumed }
        if ($fixtureState.LastStage) { Assert-UpdateIntake "$case cleans only its owned foreground stage" (-not (Test-Path -LiteralPath $fixtureState.LastStage)) }
        $proof = Get-BridgeRuntimePath -Name "agent-bridge-update-result-$($result.AttemptId).json"
        Write-UpdateIntakeDiagnostic -Kind UPDATE -Data ([ordered]@{
            stage = 'private-proof-cleanup'; case = $case; path = $proof; present = (Test-Path -LiteralPath $proof)
        })
        Assert-UpdateIntake "$case cleans its reserved private result" (-not (Test-Path -LiteralPath $proof))
    }
    foreach ($case in @('guard-child-network', 'guard-child-write')) {
        New-UpdateFixture -Case $case
        $marker = if ($case -eq 'guard-child-network') { 'BridgeTestNetworkBlocked' } else { 'BridgeTestWriteBlocked' }
        $blocked = $false
        try { [void](Invoke-BridgeSelfUpdate) }
        catch {
            $blocked = [bool]$_.Exception.Data[$marker]
            Write-UpdateIntakeDiagnostic -Kind UPDATE -Data ([ordered]@{
                stage = 'guard-exception'; case = $case; expectedMarker = $marker; marked = $blocked
                networkMarker = [bool]$_.Exception.Data['BridgeTestNetworkBlocked']
                writeMarker = [bool]$_.Exception.Data['BridgeTestWriteBlocked']
                exceptionType = $_.Exception.GetType().FullName; message = $_.Exception.Message
            })
        }
        Write-UpdateIntakeDiagnostic -Kind UPDATE -Data ([ordered]@{
            stage = 'guard-operands'; case = $case; blocked = $blocked
            childTimedOut = $fixtureState.ChildTimedOut; launches = $fixtureState.Launches
            inertInstallerCalled = (Test-Path -LiteralPath (Join-Path $fixtureState.DefaultInstallRoot 'inert-installer-called.txt'))
        })
        Assert-UpdateIntake "$case propagates the real child guard across the process boundary" ($blocked -and -not $fixtureState.ChildTimedOut)
        Assert-UpdateIntake "$case never reaches the inert installer" (-not (Test-Path -LiteralPath (Join-Path $fixtureState.DefaultInstallRoot 'inert-installer-called.txt')))
    }
}
else { Write-Host '  SKIP  generated-child/repair execution: only the Windows OS transport fixture is defined.' }

New-UpdateFixture -Case 'detached-accepted'
$detached = Invoke-BridgeSelfUpdate -Detached
Write-UpdateResultDiagnostic -Result $detached -Expected @{ State = 'Started'; Started = $true; Success = $false }
Assert-UpdateIntake 'detached launch acceptance is not terminal success' ($detached.Started -and -not $detached.Success -and $detached.State -eq 'Started')
Remove-BridgeTestSandbox -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT -Directory $fixtureState.LastStage
Remove-BridgeTestSandbox -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT -Directory $fixtureState.FixtureRoot
Remove-BridgeTestSandbox -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT -Directory $fixtureHooks
Remove-Item -LiteralPath $fixtureState.FixtureFile -Force
Write-Host 'All focused update intake checks passed'
exit 0
