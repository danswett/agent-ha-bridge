#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $env:AGENT_HA_BRIDGE_TEST_ROOT) { throw 'Run this suite through tests\run-tests.ps1.' }
. (Join-Path $PSScriptRoot 'runner-support.ps1')
Assert-BridgeTestEnvironment -Required
. (Join-Path $PSScriptRoot 'write-boundary-fixtures.ps1')

$script:Failures = 0
$fixture = New-BoundaryFixture -Suite 'test-write-boundary-context.ps1'
try {
    $allocatorCollisionClock = [Diagnostics.Stopwatch]::StartNew()
    $allocatorCollisionRefused = $false
    try { $null = New-BoundaryFixture -Suite $fixture.Suite }
    catch {
        if ($_.Exception.Message -cne 'The boundary fixture scratch path already exists; nothing was overwritten.') { throw }
        $allocatorCollisionRefused = $true
    }
    $allocatorCollisionAfter = Get-ProtectedFixtureSnapshot -HomeDirectory $fixture.ProtectedHome
    $allocatorCollisionUnchanged = $allocatorCollisionAfter -ceq $fixture.ProtectedBefore
    $allocatorCollisionClock.Stop()
    Write-BoundaryRecord -Prefix 'S1-ALLOCATOR-COLLISION' -Record ([ordered]@{
        Suite = $fixture.Suite; Scratch = $fixture.Scratch
        Refused = $allocatorCollisionRefused; Unchanged = $allocatorCollisionUnchanged
        Before = ($fixture.ProtectedBefore | ConvertFrom-Json); After = ($allocatorCollisionAfter | ConvertFrom-Json)
        Seconds = [Math]::Round($allocatorCollisionClock.Elapsed.TotalSeconds, 6)
    })
    if (-not $allocatorCollisionRefused -or -not $allocatorCollisionUnchanged) {
        throw 'An occupied fixture scratch was not refused without changing protected bytes and inventory.'
    }
    Test-That 'an occupied fixture scratch refuses allocation without changing protected bytes or inventory' {
        $allocatorCollisionRefused -and $allocatorCollisionUnchanged
    }
    foreach ($case in @(
        @{ Name = 'a missing root'; Change = "Remove-Item Env:\AGENT_HA_BRIDGE_TEST_ROOT" },
        @{ Name = 'a missing child identity'; Change = "Remove-Item Env:\AGENT_HA_BRIDGE_TEST_ID" },
        @{ Name = 'a mismatched child identity'; Change = "`$env:AGENT_HA_BRIDGE_TEST_ID = 'not-the-allocated-id'" },
        @{ Name = 'a relative root'; Change = "`$env:AGENT_HA_BRIDGE_TEST_ROOT = 'sandbox-relative'" },
        @{ Name = 'a nonfixture ambient root'; Change = '$env:AGENT_HA_BRIDGE_TEST_ROOT = $protectedHome' },
        @{ Name = 'an escaped root'; Change = '$env:AGENT_HA_BRIDGE_TEST_ROOT = Join-Path $env:AGENT_HA_BRIDGE_TEST_ROOT "..\protected-home"' },
        @{ Name = 'a rebound PowerShell home'; Change = 'Set-Variable -Name HOME -Scope Global -Force -Value $protectedHome' },
        @{ Name = 'a rebound environment home'; Change = '$env:HOME = $protectedHome' },
        @{ Name = 'a rebound user profile'; Change = '$env:USERPROFILE = $protectedHome' },
        @{ Name = 'an external configuration override'; Change = '$env:AGENT_HA_BRIDGE_CONFIG = Join-Path $protectedBridge "config.json"' }
    )) {
        $null = Invoke-BoundaryFixture -Fixture $fixture -Name $case.Name -Refused -Body (
            $case.Change + "`n" + 'Set-BridgeAdapterRoot -Directory $protectedHooks -Context $context')
    }
    $null = Invoke-BoundaryFixture -Fixture $fixture -Name 'direct entry without runner flags' -DirectEntry -Refused -Body @'
Remove-Item Env:\AGENT_HA_BRIDGE_TEST_ROOT, Env:\AGENT_HA_BRIDGE_TEST_ID, Env:\AGENT_HA_BRIDGE_OFFLINE_TEST
Set-BridgeAdapterRoot -Directory $protectedHooks -Context $context
'@
    foreach ($markerCase in 'missing', 'malformed', 'copied') {
        $body = @'
$fake = Join-Path $env:TEMP ('sandbox-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fake)
switch ('__CASE__') {
    'malformed' { [IO.File]::WriteAllText((Join-Path $fake '.bridge-test-sandbox.json'), '{broken') }
    'copied' { Copy-Item -LiteralPath (Join-Path $env:AGENT_HA_BRIDGE_TEST_ROOT '.bridge-test-sandbox.json') -Destination $fake }
}
$env:AGENT_HA_BRIDGE_TEST_ROOT = $fake
$env:AGENT_HA_BRIDGE_TEST_ID = (Split-Path $fake -Leaf).Substring(8)
Set-BridgeAdapterRoot -Directory $protectedHooks -Context $context
'@
        $null = Invoke-BoundaryFixture -Fixture $fixture -Name "a $markerCase sandbox identity" -Refused -Body $body.Replace('__CASE__', $markerCase)
    }
    foreach ($field in @(
        'Home', 'BridgeHome', 'ConfigPath', 'HooksDir', 'MetadataPath', 'RuntimeRoot',
        'CopilotHome', 'ClaudeHome', 'CodexHome', 'DesktopConfig', 'LocalAppData', 'PublicRoot'
    )) {
        $body = @'
$script:BridgeInstallContext = $context
$script:BridgeInstallContext.__FIELD__ = Join-Path $protectedHome 'outside'
Set-BridgeDaemonAlive
'@
        $null = Invoke-BoundaryFixture -Fixture $fixture -Name "an escaped cached $field" -Refused -Body $body.Replace('__FIELD__', $field)
    }
    $null = Invoke-BoundaryFixture -Fixture $fixture -Name 'a recorded external configuration reference' -Refused -Body @'
$owner = Resolve-BridgeInstallContext -TargetHome (Join-Path $env:TEMP 'recorded-home')
[void][IO.Directory]::CreateDirectory($owner.BridgeHome)
@{
    schemaVersion = 1; id = [guid]::NewGuid().ToString('N'); home = $owner.Home
    bridgeHome = $owner.BridgeHome; isolated = $true
    configPath = (Join-Path $protectedBridge 'config.json')
} | ConvertTo-Json | Set-Content -LiteralPath $owner.MetadataPath
$escaped = Resolve-BridgeInstallContext -BridgeHome $owner.BridgeHome
Set-BridgeAdapterRoot -Directory $escaped.HooksDir -Context $escaped
'@
    $null = Invoke-BoundaryFixture -Fixture $fixture -Name 'an incomplete cached context cannot choose a runtime fallback' -Refused -Body @'
$script:BridgeInstallContext = $context
$context.PSObject.Properties.Remove('Legacy')
Set-BridgeDaemonAlive
'@
    $null = Invoke-BoundaryFixture -Fixture $fixture -Name 'an unreadable installation record' -Refused -Body @'
[IO.File]::WriteAllText($context.MetadataPath, '{broken')
Resolve-BridgeInstallContext -BridgeHome $context.BridgeHome
'@
    $null = Invoke-BoundaryFixture -Fixture $fixture -Name 'a prefix sibling is not a fixture descendant' -Refused -Body @'
$sibling = $env:AGENT_HA_BRIDGE_TEST_ROOT + '-outside'
Set-BridgeAdapterRoot -Directory $sibling -Context $context
'@
    if ($IsWindows) {
        foreach ($relative in @('.. \protected-home\.agent-ha-bridge\hooks', 'home\NUL')) {
            $body = 'Set-BridgeAdapterRoot -Directory (Join-Path $env:AGENT_HA_BRIDGE_TEST_ROOT ' +
                "'$relative') -Context `$context"
            $null = Invoke-BoundaryFixture -Fixture $fixture -Name "a Windows alias $relative" -Refused -Body $body
        }
    }
}
finally {
    try { Complete-BoundaryFixture -Fixture $fixture }
    finally { Remove-BoundaryFixture -Fixture $fixture }
}
if ($script:Failures) { throw "$script:Failures write-boundary check(s) failed." }
Write-Host 'All write-boundary checks passed'
exit 0
