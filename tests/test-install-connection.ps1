#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the installer's Home Assistant discovery and connection check.

.DESCRIPTION
    Two things the installer got wrong, both of which these pin down:

      * it discovered Home Assistant, announced what it had found, and then asked for
        the URL anyway - a question whose correct answer was a bare Enter;
      * it took the token without ever showing that it worked, leaving the only
        confirmation to a "Verifying" step much later, or to nothing at all.

    Resolve-BridgeHomeAssistantUrl now prompts only when nothing answered, and
    Test-BridgeHomeAssistantConnection reports what it connected to. Neither may reach
    the network from a test, so Invoke-RestMethod is shadowed by a stub: install.ps1 is
    dot-sourced into this scope, so its functions resolve the name here first.

    install.ps1 is dot-sourced with BRIDGE_INSTALL_NORUN set so its functions load
    without running the install.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:BRIDGE_INSTALL_NORUN = '1'
. (Join-Path $PSScriptRoot '..\install.ps1')

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($ok) { Write-Host "  PASS  $Name" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

# ------------------------------------------------------------- a stub for HA
$script:Responses = @{}
$script:Requested = @()

function Invoke-RestMethod {
    <#
        Stands in for the real cmdlet. Shadowing it here rather than starting an
        HttpListener keeps the suite offline, deterministic, and free of the URL ACL
        that listening on a port would need.
    #>
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [int]$TimeoutSec,
        [Parameter(ValueFromRemainingArguments = $true)]$Rest
    )
    $script:Requested += [pscustomobject]@{ Uri = $Uri; Authorization = [string]$Headers['Authorization'] }
    if (-not $script:Responses.ContainsKey($Uri)) { throw "no stub for $Uri" }
    $value = $script:Responses[$Uri]
    if ($value -is [scriptblock]) { return (& $value) }
    $value
}

function Set-HomeAssistantStub {
    <# A Home Assistant that answers everything, unless told to fail. #>
    param(
        [string]$Base = 'http://ha.test:8123',
        [string]$Version = '2026.9.3',
        [string]$Location = '303 Home',
        [bool]$Mqtt = $true,
        [scriptblock]$ApiFailure
    )
    $script:Responses = @{}
    $script:Requested = @()
    $script:Responses["$Base/api/"] = if ($ApiFailure) { $ApiFailure } else { [pscustomobject]@{ message = 'API running.' } }
    $script:Responses["$Base/api/config"] = [pscustomobject]@{ version = $Version; location_name = $Location }
    $services = @([pscustomobject]@{ domain = 'light'; services = [pscustomobject]@{ turn_on = @{} } })
    if ($Mqtt) {
        $services += [pscustomobject]@{ domain = 'mqtt'; services = [pscustomobject]@{ publish = @{}; dump = @{} } }
    }
    $script:Responses["$Base/api/services"] = $services
}

Write-Host '--- a working connection is reported in full ---'
Set-HomeAssistantStub
$result = Test-BridgeHomeAssistantConnection -BaseUrl 'http://ha.test:8123' -Token 'good-token'
Test-That 'it reports success' { $result.Ok }
Test-That 'it carries the API greeting' { $result.Message -eq 'API running.' }
Test-That 'it reports the Home Assistant version' { $result.Version -eq '2026.9.3' }
Test-That 'it reports the location name, so you can see which instance it is' {
    $result.LocationName -eq '303 Home'
}
Test-That 'it notices mqtt.publish' { $result.MqttPublish }
Test-That 'the token is sent as a bearer token' {
    $script:Requested[0].Authorization -eq 'Bearer good-token'
}
Test-That 'a trailing slash on the URL does not double up' {
    Set-HomeAssistantStub
    $trailing = Test-BridgeHomeAssistantConnection -BaseUrl 'http://ha.test:8123/' -Token 'good-token'
    $trailing.Ok -and $trailing.BaseUrl -eq 'http://ha.test:8123'
}

Write-Host '--- a Home Assistant without MQTT is reported, not rejected ---'
Set-HomeAssistantStub -Mqtt $false
$result = Test-BridgeHomeAssistantConnection -BaseUrl 'http://ha.test:8123' -Token 'good-token'
Test-That 'the connection still succeeds' { $result.Ok }
Test-That 'mqtt.publish is reported missing' { -not $result.MqttPublish }

Write-Host '--- cosmetic lookups never sink the connection ---'
Set-HomeAssistantStub
$script:Responses.Remove('http://ha.test:8123/api/config')
$script:Responses.Remove('http://ha.test:8123/api/services')
$result = Test-BridgeHomeAssistantConnection -BaseUrl 'http://ha.test:8123' -Token 'good-token'
Test-That 'a missing /api/config does not fail the check' { $result.Ok }
Test-That 'the version is simply blank' { $result.Version -eq '' }
Test-That 'a missing /api/services does not fail the check either' { -not $result.MqttPublish }

Write-Host '--- failures come back as a result, never an exception ---'
Set-HomeAssistantStub -ApiFailure { throw 'The remote server returned an error: (401) Unauthorized.' }
$result = Test-BridgeHomeAssistantConnection -BaseUrl 'http://ha.test:8123' -Token 'bad-token'
Test-That 'a rejected token reports failure' { -not $result.Ok }
Test-That 'the reason is carried on the result' { $result.Error -match 'Unauthorized' }

Test-That 'an empty token is refused before any request is made' {
    Set-HomeAssistantStub
    $none = Test-BridgeHomeAssistantConnection -BaseUrl 'http://ha.test:8123' -Token ''
    (-not $none.Ok) -and ($none.Error -match 'token') -and ($script:Requested.Count -eq 0)
}
Test-That 'a null token is refused too' {
    Set-HomeAssistantStub
    $none = Test-BridgeHomeAssistantConnection -BaseUrl 'http://ha.test:8123' -Token $null
    (-not $none.Ok) -and ($script:Requested.Count -eq 0)
}
Test-That 'an empty URL is refused' {
    Set-HomeAssistantStub
    $none = Test-BridgeHomeAssistantConnection -BaseUrl '' -Token 'good-token'
    (-not $none.Ok) -and ($none.Error -match 'URL')
}

Write-Host '--- HTTP failures are explained rather than echoed ---'
function New-HttpError {
    param([int]$Status)
    $exception = [pscustomobject]@{
        Message  = "The remote server returned an error: ($Status)."
        Response = [pscustomobject]@{ StatusCode = $Status }
    }
    [pscustomobject]@{ Exception = $exception }
}
Test-That '401 explains that the token was rejected' {
    (Get-BridgeHttpErrorDetail -ErrorRecord (New-HttpError -Status 401)) -match 'token was rejected'
}
Test-That '404 points at the URL rather than the token' {
    (Get-BridgeHttpErrorDetail -ErrorRecord (New-HttpError -Status 404)) -match 'port'
}
Test-That 'an unrecognised status still names itself' {
    (Get-BridgeHttpErrorDetail -ErrorRecord (New-HttpError -Status 503)) -match '503'
}
Test-That 'a transport failure falls back to the exception message' {
    $record = [pscustomobject]@{ Exception = [pscustomobject]@{ Message = 'No such host is known.'; Response = $null } }
    (Get-BridgeHttpErrorDetail -ErrorRecord $record) -eq 'No such host is known.'
}

Write-Host '--- the URL prompt only appears when there is nothing to use ---'
$script:Discovered = 0
$script:Prompted = 0
$yes = { param($u) $true }
$no = { param($u) $false }
$discoverNothing = { $script:Discovered++; $null }
$discoverSomething = { $script:Discovered++; 'http://found.test:8123' }
$prompt = { param($current) $script:Prompted++; 'http://typed.test:8123' }

$script:Discovered = 0; $script:Prompted = 0
$resolved = Resolve-BridgeHomeAssistantUrl -Configured 'http://ha.test:8123' -Probe $yes `
    -Discover $discoverSomething -Prompt $prompt
Test-That 'a configured URL that answers is used as-is' { $resolved.Url -eq 'http://ha.test:8123' }
Test-That 'its source is reported as the config' { $resolved.Source -eq 'config' }
Test-That 'a working config is not re-discovered' { $script:Discovered -eq 0 }
Test-That 'a working config is never prompted about' {
    (-not $resolved.Prompted) -and ($script:Prompted -eq 0)
}

$script:Discovered = 0; $script:Prompted = 0
$resolved = Resolve-BridgeHomeAssistantUrl -Configured 'http://stale.test:8123' -Probe $no `
    -Discover $discoverSomething -Prompt $prompt
Test-That 'a discovered Home Assistant is used' { $resolved.Url -eq 'http://found.test:8123' }
Test-That 'its source is reported as discovery' { $resolved.Source -eq 'discovered' }
Test-That 'discovery is not followed by a pointless prompt' {
    (-not $resolved.Prompted) -and ($script:Prompted -eq 0)
}

$script:Discovered = 0; $script:Prompted = 0
$resolved = Resolve-BridgeHomeAssistantUrl -Configured 'http://stale.test:8123' -Probe $no `
    -Discover $discoverNothing -Prompt $prompt
Test-That 'only a failed discovery leads to a prompt' { $script:Prompted -eq 1 }
Test-That 'the typed answer is used' { $resolved.Url -eq 'http://typed.test:8123' }
Test-That 'it is reported as typed' { ($resolved.Source -eq 'typed') -and $resolved.Prompted }

Test-That 'pressing Enter at the prompt keeps the configured URL' {
    $r = Resolve-BridgeHomeAssistantUrl -Configured 'http://stale.test:8123' -Probe $no `
        -Discover $discoverNothing -Prompt { param($c) '' }
    $r.Url -eq 'http://stale.test:8123'
}
Test-That 'a typed trailing slash is trimmed' {
    $r = Resolve-BridgeHomeAssistantUrl -Configured '' -Probe $no `
        -Discover $discoverNothing -Prompt { param($c) 'http://typed.test:8123/' }
    $r.Url -eq 'http://typed.test:8123'
}
Test-That 'the prompt is shown the current value as its default' {
    $script:SeenDefault = ''
    [void](Resolve-BridgeHomeAssistantUrl -Configured 'http://stale.test:8123' -Probe $no `
        -Discover $discoverNothing -Prompt { param($c) $script:SeenDefault = $c; '' })
    $script:SeenDefault -eq 'http://stale.test:8123'
}

Write-Host '--- with no prompt (a non-interactive run) it never blocks ---'
$resolved = Resolve-BridgeHomeAssistantUrl -Configured 'http://stale.test:8123' -Probe $no `
    -Discover $discoverNothing
Test-That 'the configured value is kept' { $resolved.Url -eq 'http://stale.test:8123' }
Test-That 'it is flagged as unverified rather than claimed to work' {
    ($resolved.Source -eq 'unverified') -and (-not $resolved.Prompted)
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
