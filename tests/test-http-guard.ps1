#Requires -Version 7.0
<#
.SYNOPSIS
    A test suite cannot reach a real Home Assistant.

.DESCRIPTION
    The CI step that runs these suites is named "PowerShell test suites (Home Assistant
    free)", but nothing enforced it, and on 2026-09-28 one of them was not.

    A suite defined its Get-HomeAssistantState stub *below* the call that needed it.
    PowerShell binds a function as the script executes, so at the call the real one was
    still in scope and every read went to the live house carrying a placeholder token.
    The call sat inside Set-CopilotSelectOption, which retries twelve times, and the
    same suite had stubbed Start-Sleep - so twelve invalid-auth requests arrived in
    seventy milliseconds. Home Assistant read that as a brute-force attempt and IP
    banned the machine, which took the bridge daemon down with it for half an hour.

    Both halves were silent: the suite passed, because the retry loop swallows a failed
    read, and the ban only showed up later as 403s in the daemon log. So the guard has
    to fail loudly, and it has to catch the stub-in-the-wrong-place shape specifically -
    a missing stub is easy to see, one written thirty lines too late is not.

    Nothing here reaches the network. The one check that deliberately gets past the
    guard is pointed at a closed port on this machine.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-mqtt.ps1')
$script:DecisionBridgeConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-http-guard-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $__ok = $false
    try { $__ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($__ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

$headers = @{ Authorization = '******' }

Write-Host '--- the guard knows it is inside a suite ---'

Test-That 'running from tests/ is detected at load' { $script:BridgeUnderTestSuite }

Write-Host ''
Write-Host '--- and refuses a real call ---'

$script:Thrown = $null
try { Get-HomeAssistantState -EntityId 'select.agent_bridge_fake_decision' -Headers $headers }
catch { $script:Thrown = $_.Exception.Message }

Test-That 'a state read from a suite throws instead of reaching Home Assistant' {
    $script:Thrown -and $script:Thrown -match 'tried to reach a real Home Assistant'
} "[$script:Thrown]"

Test-That 'and the message names the entity it was about to read' {
    $script:Thrown -match 'select\.agent_bridge_fake_decision'
} "[$script:Thrown]"

Test-That 'and explains the mistake that caused the ban, not just the rule' {
    $script:Thrown -match 'above the code' -and $script:Thrown -match 'below the call'
} "[$script:Thrown]"

$script:ServiceThrew = $null
try { Invoke-HomeAssistantService -Domain 'select' -Service 'select_option' -Headers $headers -Data @{ entity_id = 'select.x'; option = 'y' } }
catch { $script:ServiceThrew = $_.Exception.Message }

Test-That 'a service call is refused on the same chokepoint' {
    $script:ServiceThrew -and $script:ServiceThrew -match 'tried to reach a real Home Assistant'
} "[$script:ServiceThrew]"

Write-Host ''
Write-Host '--- the shape that actually caused it ---'

# Exactly what test-choices-form.ps1 did: Start-Sleep stubbed so the retries have no
# delay, and the Get-HomeAssistantState stub defined further down the file, after the
# code that needs it. Set-CopilotMqttSelectOption swallows a failed read on purpose,
# which is why the original was silent - so what matters is not that something threw
# but that nothing was ever put on the wire.
function Start-Sleep { param([int]$Milliseconds, [int]$Seconds) }

$script:BridgeBlockedHttpCalls = 0
Set-CopilotMqttSelectOption -EntityId 'select.agent_bridge_fake_decision' -Option 'Cancel request' -Headers $headers | Out-Null

Test-That 'the burst of retries is refused every time, not sent' {
    $script:BridgeBlockedHttpCalls -ge 12
} "blocked=$script:BridgeBlockedHttpCalls"

Test-That 'and that is the whole retry budget plus the select itself' {
    $script:BridgeBlockedHttpCalls -eq 13
} "blocked=$script:BridgeBlockedHttpCalls"

# The stub the suite meant to use, in the place that made it useless.
function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    [pscustomobject]@{ entity_id = $EntityId; state = 'unknown'; attributes = @{ options = @('Cancel request') } }
}

Write-Host ''
Write-Host '--- an integration test can still opt in ---'

# Past the guard deliberately, and pointed at a closed port on this machine so the
# check proves the guard let it through without any traffic leaving the box.
$script:DecisionBridgeConfig.HomeAssistantBaseUrl = 'http://127.0.0.1:1'
$env:BRIDGE_ALLOW_TEST_HTTP = '1'
$script:OptedIn = $null
try {
    Invoke-DecisionHttpRequest -Parameters @{ Method = 'Get'; Uri = 'http://127.0.0.1:1/api/'; TimeoutSec = 2 } -RetryCount 0
}
catch { $script:OptedIn = $_.Exception.Message }
$env:BRIDGE_ALLOW_TEST_HTTP = $null

Test-That 'BRIDGE_ALLOW_TEST_HTTP=1 gets past the guard' {
    $script:OptedIn -and $script:OptedIn -notmatch 'tried to reach a real Home Assistant'
} "[$script:OptedIn]"

Test-That 'and the guard is back on once it is unset' {
    $t = $null
    try { Invoke-DecisionHttpRequest -Parameters @{ Method = 'Get'; Uri = 'http://127.0.0.1:1/api/'; TimeoutSec = 2 } -RetryCount 0 }
    catch { $t = $_.Exception.Message }
    $t -match 'tried to reach a real Home Assistant'
}

Write-Host ''
Write-Host '--- a suite that cannot reach the wire is left alone ---'

# test-decision-retry.ps1 drives this very retry layer with Invoke-RestMethod replaced,
# which is the correct way to do it and puts nothing on the network. Refusing that would
# punish the pattern the guard exists to encourage. Defined last so the checks above
# ran against the real cmdlet.
function Invoke-RestMethod { param($Method, $Uri, $Headers, $ContentType, $Body, $TimeoutSec) 'stubbed' }

$script:BridgeBlockedHttpCalls = 0
$script:Stubbed = $null
try { $script:Stubbed = Invoke-DecisionHttpRequest -Parameters @{ Method = 'Get'; Uri = 'http://example' } -RetryCount 0 }
catch { $script:Stubbed = "threw: $($_.Exception.Message)" }

Test-That 'a stubbed sender is allowed through' { $script:Stubbed -eq 'stubbed' } "[$script:Stubbed]"
Test-That 'and is not counted as a refusal' { $script:BridgeBlockedHttpCalls -eq 0 } "blocked=$script:BridgeBlockedHttpCalls"

Remove-Item -LiteralPath $script:DecisionBridgeConfig.LogFile -Force -ErrorAction SilentlyContinue
if ($script:Failures) { Write-Host "`n$script:Failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "`nAll HTTP-guard checks passed" -ForegroundColor Green
