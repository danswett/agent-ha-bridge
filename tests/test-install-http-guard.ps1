#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $env:AGENT_HA_BRIDGE_TEST_ROOT) { throw 'Run this suite through tests\run-tests.ps1.' }

$env:BRIDGE_INSTALL_NORUN = '1'
. (Join-Path $PSScriptRoot '..\install.ps1')
$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = $_.Exception.Message }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name - $Detail"; $script:Failures++ }
}
function Test-Blocked {
    param([string]$Label, [scriptblock]$Action)
    Test-That $Label {
        try { & $Action | Out-Null; $false }
        catch {
            $_.Exception.Data['BridgeTestNetworkBlocked'] -eq $true -and
            $_.Exception.Message -match 'tried to reach a real Home Assistant'
        }
    }
}

# An unsupported scheme cannot send traffic even if a REST/WebSocket guard regresses.
$fixtureUrl = 'offline-test://fixture'
$hooksPath = Join-Path $PSScriptRoot '..\hooks'
Write-Host '--- the installer has its own configuration-free boundary ---'
Test-That 'loading installer helpers does not load runtime configuration' {
    -not (Get-Variable -Name DecisionBridgeConfig -Scope Script -ErrorAction SilentlyContinue)
}
Test-Blocked 'a missing REST stub throws instead of becoming an ordinary connection failure' {
    Test-BridgeHomeAssistantConnection -BaseUrl $fixtureUrl -Token 'synthetic-test-token'
}
Test-Blocked 'a missing WebSocket stub throws instead of becoming an ordinary identity failure' {
    Get-BridgeHomeAssistantUser -BaseUrl $fixtureUrl -Token 'synthetic-test-token'
}
Test-Blocked 'the agent identity wrapper propagates the boundary violation' {
    Resolve-BridgeAgentIdentity -BaseUrl $fixtureUrl -AgentToken 'synthetic-agent-token' -OwnToken 'synthetic-own-token'
}
Test-Blocked 'the unauthenticated manifest probe does not hide a missing WebRequest stub' {
    Test-IsHomeAssistant -BaseUrl $fixtureUrl
}
Test-Blocked 'URL resolution does not hide an unstubbed configured-URL probe' {
    Resolve-BridgeHomeAssistantUrl -Configured $fixtureUrl
}
Test-Blocked 'a checker child is refused before loading any runtime configuration' {
    Invoke-BridgeFrontendCardCheck -HooksDir $hooksPath -ConfigPath 'not-a-config.json'
}

# The default resolver uses a fixed mDNS name, not our unsupported URI. Check its
# preflight placement before exercising it so a removed/misplaced guard cannot make
# this regression itself issue a real DNS query.
$candidateAst = (Get-Command Get-BridgeHomeAssistantCandidate).ScriptBlock.Ast
$discoveryGuards = @($candidateAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -eq 'Assert-BridgeHttpAllowed' -and
    $node.Extent.Text -match '-Transport Discovery'
}, $true))
$lookups = @($candidateAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Expression -is [Management.Automation.Language.TypeExpressionAst] -and
    $node.Expression.TypeName.FullName -eq 'System.Net.Dns'
}, $true))
if ($discoveryGuards.Count -ne 1 -or $lookups.Count -ne 1 -or
    $discoveryGuards[0].Extent.StartOffset -ge $lookups[0].Extent.StartOffset) {
    throw 'Discovery must guard its default resolver before this test may exercise it.'
}
for ($ancestor = $discoveryGuards[0].Parent; $ancestor; $ancestor = $ancestor.Parent) {
    if ($ancestor -is [Management.Automation.Language.TryStatementAst]) {
        throw 'Discovery must not put the test guard inside a transport catch.'
    }
}
try { Assert-BridgeHttpAllowed -Transport Discovery; throw 'Discovery preflight was not blocked.' }
catch { if (-not $_.Exception.Data['BridgeTestNetworkBlocked']) { throw } }
Test-Blocked 'default candidate discovery fails before DNS, outside its best-effort catch' {
    Get-BridgeHomeAssistantCandidate
}
Test-Blocked 'finding Home Assistant cannot start LAN discovery' { Find-HomeAssistant }
Test-Blocked 'resolving an absent URL cannot start LAN discovery' { Resolve-BridgeHomeAssistantUrl -Configured '' }
Test-That 'an explicitly injected resolver still supports offline candidate tests' {
    @(Get-BridgeHomeAssistantCandidate -Resolver { '192.0.2.10' }) -contains 'http://192.0.2.10:8123'
}

Write-Host '--- a stub defined after the negative calls only replaces its own transport ---'
$script:RestCalls = 0
function Invoke-RestMethod {
    param([string]$Uri, $Headers, $TimeoutSec)
    $script:RestCalls++
    if ($Uri.EndsWith('/api/config')) { return [pscustomobject]@{ version = 'test'; location_name = 'fixture' } }
    if ($Uri.EndsWith('/api/services')) { return @([pscustomobject]@{ domain = 'mqtt'; services = [pscustomobject]@{ publish = @{} } }) }
    [pscustomobject]@{ message = 'API running.' }
}
Test-That 'a correctly placed REST stub covers all three connection requests' {
    $connection = Test-BridgeHomeAssistantConnection -BaseUrl $fixtureUrl -Token 'synthetic-test-token'
    $connection.Ok -and $connection.MqttPublish -and $script:RestCalls -eq 3
}
Test-Blocked 'a REST stub never permits the installer WebSocket' {
    Get-BridgeHomeAssistantUser -BaseUrl $fixtureUrl -Token 'synthetic-test-token'
}
Test-Blocked 'a REST stub never permits the manifest WebRequest' { Test-IsHomeAssistant -BaseUrl $fixtureUrl }
Test-Blocked 'a REST stub never permits discovery' { Get-BridgeHomeAssistantCandidate }
Test-Blocked 'a REST stub in the parent never permits a checker child' {
    Invoke-BridgeFrontendCardCheck -HooksDir $hooksPath -ConfigPath 'not-a-config.json'
}
function Invoke-WebRequest {
    param($Uri, $TimeoutSec, [switch]$SkipHttpErrorCheck, $ErrorAction)
    [pscustomobject]@{ StatusCode = 200; Content = '{"name":"Home Assistant"}' }
}
Test-That 'a WebRequest stub permits only its own manifest probe' { Test-IsHomeAssistant -BaseUrl $fixtureUrl }
Test-Blocked 'both HTTP stubs still do not authorize WebSockets' {
    Get-BridgeHomeAssistantUser -BaseUrl $fixtureUrl -Token 'synthetic-test-token'
}
Test-Blocked 'both HTTP stubs still do not authorize DNS' { Get-BridgeHomeAssistantCandidate }
Remove-Item Function:\Invoke-WebRequest
Remove-Item Function:\Invoke-RestMethod

foreach ($removeAfter in 1, 2) {
    $script:RestCalls = 0
    function Invoke-RestMethod {
        param([string]$Uri, $Headers, $TimeoutSec)
        $script:RestCalls++
        if ($script:RestCalls -eq $removeAfter) { Remove-Item Function:\Invoke-RestMethod }
        [pscustomobject]@{ message = 'API running.'; version = 'test'; location_name = 'fixture' }
    }
    Test-Blocked "losing the REST stub after request $removeAfter cannot become cosmetic success" {
        Test-BridgeHomeAssistantConnection -BaseUrl $fixtureUrl -Token 'synthetic-test-token'
    }
}
Test-That 'the real REST cmdlet is restored before policy-only checks' {
    (Get-Command Invoke-RestMethod).CommandType -eq 'Cmdlet'
}
Set-Alias -Name Invoke-RestMethod -Value Microsoft.PowerShell.Utility\Invoke-RestMethod
try {
    Test-Blocked 'an alias to the real REST cmdlet is not mistaken for a stub' {
        Test-BridgeHomeAssistantConnection -BaseUrl $fixtureUrl -Token 'synthetic-test-token'
    }
}
finally { Remove-Item Alias:\Invoke-RestMethod }

Write-Host '--- frontend fallbacks must not swallow guard failures or probe the network ---'
. (Join-Path $hooksPath 'decision-bridge-common.ps1')
. (Join-Path $hooksPath 'decision-ha-websocket.ps1')
$script:DecisionBridgeConfig.HomeAssistantBaseUrl = $fixtureUrl
$env:BRIDGE_FRONTEND_NORUN = '1'
. (Join-Path $hooksPath 'bridge-frontend-cards.ps1')
Remove-Item Env:\BRIDGE_FRONTEND_NORUN
Test-Blocked 'the frontend resource-list catch propagates a WebSocket guard failure' {
    Get-BridgeFrontendCardStatus -FileProbe { $false }
}
Test-Blocked 'the frontend file-probe catches propagate a WebRequest guard failure' {
    Get-BridgeFrontendCardStatus -Resources { @() }
}
Test-Blocked 'the reply-card resource-list catch propagates a WebSocket guard failure' {
    Get-BridgeReplyCardState -FileProbe { $false }
}
$replyResource = [pscustomobject]@{ url = '/local/agent-bridge-reply-card.js'; id = 'fixture' }
Test-Blocked 'the reply-card file-probe catches propagate a WebRequest guard failure' {
    Get-BridgeReplyCardState -Resources { @($replyResource) }
}
Test-Blocked 'resource registration cannot turn the guard into a false result' {
    Register-BridgeFrontendCard -Url '/local/fixture.js'
}
Test-Blocked 'reply-card installation cannot turn the guard into success or an ordinary failure' {
    Install-BridgeReplyCard -Resources { @() } -FileProbe { $false }
}
Test-That 'loading the shared guard again preserves the refusal evidence' {
    $before = $script:BridgeBlockedHttpCalls
    . (Join-Path $hooksPath 'bridge-test-guard.ps1')
    $before -gt 0 -and $script:BridgeBlockedHttpCalls -eq $before
}

Write-Host '--- descendants inherit the boundary without the common runtime or test stack ---'
. (Join-Path $PSScriptRoot 'runner-support.ps1')
$scratch = Join-Path $env:TEMP ('installer-guard-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
try {
    $probePath = Join-Path $scratch 'installer-probe.ps1'
    $probe = @'
param([switch]$Descendant)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $Descendant) {
    & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $PSCommandPath -Descendant
    exit $LASTEXITCODE
}
$env:BRIDGE_INSTALL_NORUN = '1'
. '__INSTALLER__'
if ($script:BridgeUnderTestSuite) { throw 'The descendant must not have a test-suite call stack.' }
if (Get-Variable -Name DecisionBridgeConfig -Scope Script -ErrorAction SilentlyContinue) { throw 'Installer loaded runtime configuration.' }
if ($env:AGENT_HA_BRIDGE_OFFLINE_TEST -ne '1' -or $env:AGENT_HA_BRIDGE_TEST_LOOPBACK_ORIGIN) { throw 'Incorrect inherited boundary.' }
$env:BRIDGE_ALLOW_TEST_HTTP = '1'
$blocked = 0
foreach ($call in @(
    { Test-BridgeHomeAssistantConnection -BaseUrl 'offline-test://fixture' -Token 'synthetic-test-token' },
    { Get-BridgeHomeAssistantUser -BaseUrl 'offline-test://fixture' -Token 'synthetic-test-token' },
    { Test-IsHomeAssistant -BaseUrl 'offline-test://fixture' },
    { Invoke-BridgeFrontendCardCheck -HooksDir '__HOOKS__' -ConfigPath 'not-a-config.json' }
)) {
    try { & $call | Out-Null }
    catch {
        if (-not $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        $blocked++
    }
}
function Invoke-RestMethod { param($Uri, $Headers, $TimeoutSec) throw 'REST stub must not service a WebSocket.' }
try { Get-BridgeHomeAssistantUser -BaseUrl 'offline-test://fixture' -Token 'synthetic-test-token' | Out-Null }
catch {
    if (-not $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
    $blocked++
}
if ($blocked -ne 5 -or $script:BridgeBlockedHttpCalls -ne 5) { throw "Expected five blocked descendant calls, got $blocked." }
Write-Output 'installer descendant transports blocked without runtime configuration'
'@
    $probe.Replace('__INSTALLER__', (Join-Path $script:BridgeTestRepository 'install.ps1').Replace("'", "''")).
        Replace('__HOOKS__', (Join-Path $script:BridgeTestRepository 'hooks').Replace("'", "''")) |
        Set-Content -LiteralPath $probePath -Encoding utf8
    $box = New-BridgeTestSandbox -ParentDirectory $scratch
    $result = Invoke-BridgeTestProcess -StartInfo (New-BridgeTestProcessStartInfo -ScriptPath $probePath -Sandbox $box)
    Test-That 'the child and its descendant retain REST, WebRequest, WebSocket and checker guards' {
        $result.ExitCode -eq 0 -and -not $result.TimedOut -and
        $result.Output -match 'installer descendant transports blocked without runtime configuration'
    } $result.Output

    Write-Host '--- suite detection follows the entry filename, not a checkout ancestor ---'
    # These scripts invoke only the guard, never an installer or transport. Removing
    # the inherited flag here tests call-stack detection independently and safely.
    $pathProbe = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$env:AGENT_HA_BRIDGE_OFFLINE_TEST = $null
. '__GUARD__'
$expected = __EXPECTED__
if ($script:BridgeUnderTestSuite -ne $expected) { throw 'Incorrect suite classification for this script path.' }
$blocked = $false
try { Assert-BridgeHttpAllowed -Uri 'offline-test://fixture' -Transport WebSocket }
catch {
    if (-not $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
    $blocked = $true
}
if ($blocked -ne $expected) { throw 'The guard did not honor the script classification.' }
Write-Output 'call-stack classification verified without invoking a transport'
'@
    foreach ($pathCase in @(
        @{ Relative = 'tests\checkout\install.ps1'; IsSuite = $false },
        @{ Relative = 'tests\checkout\hooks\runtime.ps1'; IsSuite = $false },
        @{ Relative = 'component\tests\nested\test-nested.ps1'; IsSuite = $true },
        @{ Relative = 'mcp\checks\test-component.ps1'; IsSuite = $true }
    )) {
        $pathProbeFile = Join-Path $scratch ($pathCase.Relative.Replace('\', [IO.Path]::DirectorySeparatorChar))
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $pathProbeFile))
        $expectedLiteral = if ($pathCase.IsSuite) { '$true' } else { '$false' }
        $pathProbe.Replace('__GUARD__', (Join-Path $script:BridgeTestRepository 'hooks\bridge-test-guard.ps1').Replace("'", "''")).
            Replace('__EXPECTED__', $expectedLiteral) | Set-Content -LiteralPath $pathProbeFile -Encoding utf8
        $pathResult = Invoke-BridgeTestProcess -StartInfo (New-BridgeTestProcessStartInfo -ScriptPath $pathProbeFile -Sandbox $box)
        Test-That "$($pathCase.Relative) is classified as suite=$($pathCase.IsSuite) without network access" {
            $pathResult.ExitCode -eq 0 -and -not $pathResult.TimedOut -and
            $pathResult.Output -match 'call-stack classification verified without invoking a transport'
        } $pathResult.Output
    }
}
finally { Remove-Item -LiteralPath $scratch -Recurse -Force }

Write-Host '--- hosted fixture policy is tested without invoking any transport ---'
$saved = @{}
foreach ($key in 'AGENT_HA_BRIDGE_TEST_GROUP', 'GITHUB_ACTIONS', 'RUNNER_ENVIRONMENT', 'AGENT_HA_BRIDGE_TEST_LOOPBACK_ORIGIN') {
    $saved[$key] = [Environment]::GetEnvironmentVariable($key)
}
try {
    $env:AGENT_HA_BRIDGE_TEST_GROUP = 'Host'
    $env:GITHUB_ACTIONS = 'true'
    $env:RUNNER_ENVIRONMENT = 'github-hosted'
    $env:AGENT_HA_BRIDGE_TEST_LOOPBACK_ORIGIN = 'http://127.0.0.1:1'
    foreach ($transport in 'Rest', 'WebRequest', 'WebSocket', 'ChildProcess') {
        Test-That "the explicitly gated fixture permits the $transport preflight only" {
            Assert-BridgeHttpAllowed -Uri 'http://127.0.0.1:1/api/' -Transport $transport
            $true
        }
    }
    Test-That 'the matching loopback WebSocket endpoint is permitted' {
        Assert-BridgeHttpAllowed -Uri 'ws://127.0.0.1:1/api/websocket' -Transport WebSocket
        $true
    }
    foreach ($uri in @(
        'http://127.0.0.1:8123/api/', 'http://localhost:1/api/', 'http://192.0.2.10:1/api/',
        'http://homeassistant.local:8123/api/', 'http://127.0.0.1.example:1/api/',
        'http://user@127.0.0.1:1/api/', 'https://127.0.0.1:1/api/'
    )) {
        Test-Blocked "the hosted preflight rejects $uri" { Assert-BridgeHttpAllowed -Uri $uri }
    }
    Test-Blocked 'hosted fixtures never permit DNS discovery' {
        Assert-BridgeHttpAllowed -Uri 'homeassistant.local' -Transport Discovery
    }
    foreach ($boundary in @(
        @{ Key = 'AGENT_HA_BRIDGE_TEST_GROUP'; Value = 'Offline' },
        @{ Key = 'AGENT_HA_BRIDGE_TEST_GROUP'; Value = 'Platform' },
        @{ Key = 'GITHUB_ACTIONS'; Value = 'false' },
        @{ Key = 'RUNNER_ENVIRONMENT'; Value = 'self-hosted' },
        @{ Key = 'AGENT_HA_BRIDGE_TEST_LOOPBACK_ORIGIN'; Value = '' }
    )) {
        $previous = [Environment]::GetEnvironmentVariable($boundary.Key)
        try {
            [Environment]::SetEnvironmentVariable($boundary.Key, $boundary.Value, 'Process')
            Test-Blocked "$($boundary.Key)=$($boundary.Value) cannot enable even loopback traffic" {
                Assert-BridgeHttpAllowed -Uri 'http://127.0.0.1:1/api/'
            }
            Test-Blocked "$($boundary.Key)=$($boundary.Value) cannot enable a checker child" {
                Assert-BridgeHttpAllowed -Transport ChildProcess
            }
        }
        finally { [Environment]::SetEnvironmentVariable($boundary.Key, $previous, 'Process') }
    }
}
finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process') }
}

if ($script:Failures) { throw "$script:Failures installer guard check(s) failed." }
Write-Host 'All installer guard checks passed'
exit 0
