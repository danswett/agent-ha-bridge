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

Write-Host '--- discovery covers the cases mDNS cannot ---'
$candidates = @(Get-BridgeHomeAssistantCandidate -Resolver { @('192.168.1.10', '192.168.1.11') })
Test-That 'the mDNS hostname is probed first' { $candidates[0] -eq 'http://homeassistant.local:8123' }
Test-That 'the bare hostname is probed, for a network without mDNS' {
    $candidates -contains 'http://homeassistant:8123'
}
Test-That 'every resolved address is probed' {
    ($candidates -contains 'http://192.168.1.10:8123') -and ($candidates -contains 'http://192.168.1.11:8123')
}
Test-That 'localhost is probed, for Home Assistant in Docker or WSL on this machine' {
    $candidates -contains 'http://localhost:8123'
}
Test-That 'https is probed too' { $candidates -contains 'https://homeassistant.local:8123' }
Test-That 'the expensive TLS candidate is left until last' {
    $candidates[-1] -eq 'https://homeassistant.local:8123'
}
Test-That 'no candidate is probed twice' {
    @($candidates | Group-Object | Where-Object { $_.Count -gt 1 }).Count -eq 0
}
Test-That 'a DNS failure still leaves a usable list' {
    $noDns = @(Get-BridgeHomeAssistantCandidate -Resolver { throw 'no such host' })
    ($noDns -contains 'http://homeassistant.local:8123') -and ($noDns -contains 'http://localhost:8123')
}
Test-That 'a resolver returning nothing is handled' {
    @(Get-BridgeHomeAssistantCandidate -Resolver { @() }).Count -ge 4
}
# Resolve-DnsName ships only with Windows. On a Mac the default resolver threw, the
# catch swallowed it, and every address candidate was dropped - so discovery had
# nothing but the two host names to go on and reported no Home Assistant found.
Test-That 'the default address lookup is not the Windows-only cmdlet' {
    # Read from the syntax tree, not the text: the comment beside it names the cmdlet.
    $ast = (Get-Command Get-BridgeHomeAssistantCandidate).ScriptBlock.Ast
    $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    @($calls | Where-Object { "$($_.GetCommandName())" -eq 'Resolve-DnsName' }).Count -eq 0
}
Test-That 'and it runs on this platform, whichever it is' {
    $list = @(Get-BridgeHomeAssistantCandidate)
    ($list -contains 'http://homeassistant.local:8123') -and ($list -contains 'http://localhost:8123')
}

Write-Host '--- an old or damaged config does not end the install ---'
$example = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json

Test-That 'a config missing a whole section gets it back' {
    $old = '{"homeAssistant":{"baseUrl":"http://ha:8123","token":"t"}}' | ConvertFrom-Json
    $added = @(Merge-BridgeConfigDefaults -Config $old -Defaults $example)
    ($added -contains 'notifications') -and ($null -ne $old.notifications) -and
    ($old.notifications.enabled -eq $false)
}
Test-That 'a section missing one key gets just that key' {
    $old = '{"notifications":{"enabled":true,"service":"notify.me"}}' | ConvertFrom-Json
    $added = @(Merge-BridgeConfigDefaults -Config $old -Defaults $example)
    ($added -contains 'notifications.tickerCategory') -and ($old.notifications.service -eq 'notify.me')
}
Test-That 'nothing already set is overwritten' {
    $old = '{"homeAssistant":{"baseUrl":"http://mine:8123","token":"secret","tokenEnvVar":"X"}}' | ConvertFrom-Json
    [void](Merge-BridgeConfigDefaults -Config $old -Defaults $example)
    ($old.homeAssistant.baseUrl -eq 'http://mine:8123') -and ($old.homeAssistant.token -eq 'secret') -and
    ($old.homeAssistant.tokenEnvVar -eq 'X')
}
Test-That 'an explicitly null section is replaced rather than left to crash' {
    $old = '{"homeAssistant":null}' | ConvertFrom-Json
    [void](Merge-BridgeConfigDefaults -Config $old -Defaults $example)
    ($null -ne $old.homeAssistant) -and ($old.homeAssistant.PSObject.Properties['baseUrl'])
}
Test-That 'an already-complete config needs nothing added' {
    $current = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\config.example.json') -Raw | ConvertFrom-Json
    @(Merge-BridgeConfigDefaults -Config $current -Defaults $example).Count -eq 0
}
Test-That 'the example is not the place a client selection comes back from' {
    $old = '{"homeAssistant":{"baseUrl":"http://ha:8123"}}' | ConvertFrom-Json
    [void](Merge-BridgeConfigDefaults -Config $old -Defaults $example)
    -not $old.PSObject.Properties['clients']
}
Test-That 'an array value is replaced wholesale, not merged into' {
    $old = '{"newSession":{"profiles":["only-mine"]}}' | ConvertFrom-Json
    [void](Merge-BridgeConfigDefaults -Config $old -Defaults $example)
    (@($old.newSession.profiles) -join ',') -eq 'only-mine'
}

$scratch = Join-Path $env:TEMP ("bridge-config-" + [guid]::NewGuid().ToString('N') + '.json')
try {
    Set-Content -LiteralPath $scratch -Value '{"homeAssistant":{"baseUrl":"http://ha:8123"}' -Encoding UTF8
    $read = Read-BridgeConfigFile -Path $scratch
    Test-That 'malformed JSON is reported rather than thrown' {
        ($null -eq $read.Config) -and $read.Error
    }
    Set-Content -LiteralPath $scratch -Value '' -Encoding UTF8
    Test-That 'an empty config is reported too' {
        $empty = Read-BridgeConfigFile -Path $scratch
        ($null -eq $empty.Config) -and ($empty.Error -match 'empty')
    }
    Set-Content -LiteralPath $scratch -Value '{"homeAssistant":{"baseUrl":"http://ha:8123"}}' -Encoding UTF8
    Test-That 'a good config is returned with no error' {
        $good = Read-BridgeConfigFile -Path $scratch
        ($good.Config.homeAssistant.baseUrl -eq 'http://ha:8123') -and (-not $good.Error)
    }
}
finally { Remove-Item -LiteralPath $scratch -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------- the agent's own identity
# An agent drives the bridge through the same entities you do, so the account behind
# the press is the only thing that separates its turn from yours. Both refusals below
# fail silently if the token is simply stored: the dashboard marks nothing, forever,
# with no error anywhere. One of them had already happened on the author's machine -
# a token saved from an earlier attempt had since been revoked, and nothing said so.
Write-Host ''
Write-Host '--- the agent identity the installer will store ---'

$you = [pscustomobject]@{ Ok = $true; Id = 'owner-id'; Name = 'Dan Swett'; IsAdmin = $true; Error = '' }
$bot = [pscustomobject]@{ Ok = $true; Id = 'agent-id'; Name = 'Copilot'; IsAdmin = $false; Error = '' }
$dud = [pscustomobject]@{ Ok = $false; Id = ''; Name = ''; IsAdmin = $false; Rejected = $true; Error = 'Home Assistant rejected the token' }
# Not the same thing: the network failed, so the token is unjudged rather than bad.
$unreachable = [pscustomobject]@{ Ok = $false; Id = ''; Name = ''; IsAdmin = $false; Rejected = $false; Error = 'connection refused' }

# The seam answers by token, the way the real lookup does.
$lookup = { param($Url, $Tok)
    switch ($Tok) { 'agent-token' { $bot } 'own-token' { $you } 'admin-agent' { [pscustomobject]@{ Ok = $true; Id = 'agent-id'; Name = 'Copilot'; IsAdmin = $true; Error = '' } } default { $dud } }
}

$good = Resolve-BridgeAgentIdentity -BaseUrl 'http://ha.test:8123' -AgentToken 'agent-token' -OwnToken 'own-token' -Lookup $lookup
Test-That 'a token on its own account is stored' { $good.Store }
Test-That 'and its user id comes off the token, so nobody copies one by hand' { $good.UserId -eq 'agent-id' } $good.UserId
Test-That 'the account is named, so the install says what it just wired up' { $good.Name -eq 'Copilot' }
Test-That 'nothing is warned about' { $good.Warning -eq '' } $good.Warning

$same = Resolve-BridgeAgentIdentity -BaseUrl 'http://ha.test:8123' -AgentToken 'own-token' -OwnToken 'own-token' -Lookup $lookup
Test-That 'a second token on your OWN account is refused' { -not $same.Store }
Test-That 'and nothing is left to store' { $same.Token -eq '' -and $same.UserId -eq '' }
Test-That 'the refusal says why, since it would otherwise mark nothing forever' {
    $same.Warning -match 'same account' -and $same.Warning -match 'indistinguishable'
} $same.Warning

$revoked = Resolve-BridgeAgentIdentity -BaseUrl 'http://ha.test:8123' -AgentToken 'stale-token' -OwnToken 'own-token' -Lookup $lookup
Test-That 'a token Home Assistant rejects is not saved as a dud' { -not $revoked.Store }
Test-That 'and says so, rather than failing quietly later' { $revoked.Warning -match 'not accepted' } $revoked.Warning

# Telling "your token is bad" from "I could not ask" matters: the first is worth
# acting on, the second is the network and saying it is the token would be a guess.
$offline = { param($Url, $Tok) if ($Tok -eq 'own-token') { $you } else { $unreachable } }
$unjudged = Resolve-BridgeAgentIdentity -BaseUrl 'http://ha.test:8123' -AgentToken 'agent-token' -OwnToken 'own-token' -Lookup $offline
Test-That 'a token that could not be checked is also not stored' { -not $unjudged.Store }
Test-That 'but is not called bad, because nothing judged it' {
    $unjudged.Warning -match 'Could not check' -and $unjudged.Warning -notmatch 'not accepted'
} $unjudged.Warning

$none = Resolve-BridgeAgentIdentity -BaseUrl 'http://ha.test:8123' -AgentToken '' -OwnToken 'own-token' -Lookup $lookup
Test-That 'no agent token at all is not an error - the whole step is optional' {
    -not $none.Store -and $none.Warning -eq ''
} $none.Warning

$adminBot = Resolve-BridgeAgentIdentity -BaseUrl 'http://ha.test:8123' -AgentToken 'admin-agent' -OwnToken 'own-token' -Lookup $lookup
Test-That 'an administrator agent account is still stored, only remarked on' {
    $adminBot.Store -and $adminBot.IsAdmin
}

# A daemon token that cannot be checked must not turn into "same account" by accident:
# the comparison only refuses when the owner lookup actually succeeded.
$unknownOwner = { param($Url, $Tok) if ($Tok -eq 'agent-token') { $bot } else { $dud } }
$stillOk = Resolve-BridgeAgentIdentity -BaseUrl 'http://ha.test:8123' -AgentToken 'agent-token' -OwnToken 'own-token' -Lookup $unknownOwner
Test-That 'an unreadable owner token does not block a good agent token' { $stillOk.Store }

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
