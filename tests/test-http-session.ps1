#Requires -Version 7.0
<#
.SYNOPSIS
    Home Assistant calls reuse one connection.

.DESCRIPTION
    Invoke-RestMethod builds a fresh session, and with it a fresh connection pool, for
    every call it is not handed one. Each request therefore paid a new TCP connect and
    a full TLS handshake.

    On the LAN that is a few milliseconds, which is why it sat here unnoticed. Measured
    from a machine reaching Home Assistant through a Cloudflare tunnel on 2026-09-29 it
    was 60-75 ms a call, against 23-26 ms once one session was shared - on a daemon
    that makes about eight calls every fifteen seconds.

    The catch is that suites replace Invoke-RestMethod with stubs that declare their
    own parameters: test-decision-retry.ps1 uses a bare param(), test-http-guard.ps1
    names six. Splatting WebSession at either is a binding error, so attaching it
    unconditionally would have broken every suite that drives this retry layer. Hence
    the check that only the real cmdlet is given one - and hence this suite, which
    covers both halves.

    Nothing here reaches the network: every call goes to a stub.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
$script:DecisionBridgeConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-http-session-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $__ok = $false
    try { $__ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($__ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

Write-Host '--- the session outlives a single call ---'

$first = Get-BridgeHttpSession
$second = Get-BridgeHttpSession

Test-That 'a session is handed out at all' {
    $first -is [Microsoft.PowerShell.Commands.WebRequestSession]
} "got [$($first.GetType().Name)]"

Test-That 'and the same one comes back next time, which is what holds the connection open' {
    [object]::ReferenceEquals($first, $second)
}

Write-Host ''
Write-Host '--- a stub is called exactly as it was before ---'

# The shape that would have broken: a stub declaring no parameters at all, which is
# what test-decision-retry.ps1 drives this retry layer with.
$script:BareCalls = 0
function Invoke-RestMethod {
    param()
    $script:BareCalls++
    [pscustomobject]@{ state = 'ok' }
}

$script:BareResult = $null
try { $script:BareResult = Invoke-DecisionHttpRequest -Parameters @{ Uri = 'http://example' } }
catch { $script:BareResult = "threw: $($_.Exception.Message)" }

Test-That 'a stub taking no parameters is not handed a WebSession' {
    $script:BareResult.state -eq 'ok' -and $script:BareCalls -eq 1
} "[$script:BareResult] calls=$script:BareCalls"

Test-That 'and the decision says so for itself' { -not (Test-BridgeHttpSessionSupported) }

Write-Host ''
Write-Host '--- the real cmdlet does get one ---'

Test-That 'with nothing shadowing it, a session is attached' {
    # Proven by removing the stub for the length of the check, so Get-Command resolves
    # the genuine cmdlet. Nothing is called here - only the decision is read.
    Remove-Item -LiteralPath 'function:Invoke-RestMethod' -ErrorAction SilentlyContinue
    Test-BridgeHttpSessionSupported
}

Write-Host ''
Write-Host '--- and the session reaches the call ---'

# BridgeUnderTestSuite off for the length of this check, so the attach path runs as it
# does in production. The sender is still a stub, so nothing leaves the machine.
$script:Seen = [System.Collections.Generic.List[object]]::new()
function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $ContentType, $Body, $TimeoutSec, $WebSession)
    $script:Seen.Add($WebSession)
    [pscustomobject]@{ state = 'ok' }
}

$wasUnderSuite = $script:BridgeUnderTestSuite
try {
    $script:BridgeUnderTestSuite = $false
    $caller = @{ Uri = 'http://example' }
    Invoke-DecisionHttpRequest -Parameters $caller | Out-Null
    Invoke-DecisionHttpRequest -Parameters $caller | Out-Null

    Test-That 'the sender is given a session' {
        $script:Seen.Count -eq 2 -and $null -ne $script:Seen[0]
    } "seen=$($script:Seen.Count)"

    Test-That 'and both calls share one, so the connection is not rebuilt each time' {
        [object]::ReferenceEquals($script:Seen[0], $script:Seen[1])
    }

    Test-That "and the caller's own parameters are left alone" {
        -not $caller.ContainsKey('WebSession')
    } "keys=$($caller.Keys -join ',')"
}
finally { $script:BridgeUnderTestSuite = $wasUnderSuite }

Write-Host ''
Write-Host '--- a caller supplying its own session keeps it ---'

$mine = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
$script:Seen.Clear()
try {
    $script:BridgeUnderTestSuite = $false
    Invoke-DecisionHttpRequest -Parameters @{ Uri = 'http://example'; WebSession = $mine } | Out-Null
    Test-That 'the one it passed is the one used' {
        $script:Seen.Count -eq 1 -and [object]::ReferenceEquals($script:Seen[0], $mine)
    } "seen=$($script:Seen.Count)"
}
finally { $script:BridgeUnderTestSuite = $wasUnderSuite }

Remove-Item -LiteralPath $script:DecisionBridgeConfig.LogFile -Force -ErrorAction SilentlyContinue
if ($script:Failures) { Write-Host "`n$script:Failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "`nAll HTTP-session checks passed" -ForegroundColor Green
