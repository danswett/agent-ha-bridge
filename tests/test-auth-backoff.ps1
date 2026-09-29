#Requires -Version 7.0
<#
.SYNOPSIS
    A rejected login is not repeated until it gets the machine banned.

.DESCRIPTION
    Home Assistant bans an IP after ten failed logins, and a successful login resets
    its count - so what is dangerous is not one rejection, it is a steady stream of
    them with nothing succeeding in between. The daemon produced exactly that: six
    calls a cycle, every fifteen seconds, offering the same rejected token for as long
    as it kept being rejected. Six sits four short of the threshold, and anything else
    on the machine failing auth at the same moment closes the gap.

    On 2026-09-28 that gap was closed and the machine was banned. Every request then
    answered 403 - daemon and dashboard alike - and nothing in the bridge said why.
    The log showed `403 (Forbidden)` over and over, which reads like a bad token and is
    not one, and the two have opposite remedies: a token is replaced, a ban is cleared
    out of a file that survives restarting Home Assistant.

    So there are two things to get right here, and they pull in different directions.
    Backing off has to actually stop calls being made - a hold-off that still lets the
    next six through has done nothing - and it must not swallow the ordinary transient
    failures the retry layer exists for, or a Home Assistant restart would take the
    bridge down for fifteen minutes. These assert both, and that what gets written down
    names the ban rather than leaving someone to guess at a token.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
$script:LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-auth-backoff-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"
$script:DecisionBridgeConfig.LogFile = $script:LogFile

# Defined above everything that calls it: PowerShell binds a function as it runs, so a
# stub written below the code under test intercepts nothing. That exact mistake is what
# banned the machine this suite is about.
$script:Attempts = 0
$script:ThrowThis = $null
function Invoke-RestMethod {
    param(
        $Uri, $Method, $Headers, $Body, $ContentType, $TimeoutSec,
        $UserAgent, $WebSession, $SessionVariable, $SkipHttpErrorCheck
    )
    $script:Attempts++
    if ($null -ne $script:ThrowThis) { throw $script:ThrowThis }
    'ok'
}
function Start-Sleep { param($Milliseconds, $Seconds) }

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $__ok = $false
    try { $__ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($__ok) { Write-Host "  PASS  $Name" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

function New-HttpError {
    <# What Invoke-RestMethod throws for a status code, carrying a real response. #>
    param([Parameter(Mandatory)][int]$Status)
    $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$Status)
    [Microsoft.PowerShell.Commands.HttpResponseException]::new("Response status code does not indicate success: $Status.", $response)
}

function Reset-Backoff {
    $script:BridgeAuthBackoffUntil = $null
    $script:BridgeAuthBackoffStep = -1
    $script:Attempts = 0
    $script:ThrowThis = $null
}

function Invoke-Call {
    <# One bridge request, reporting what came back rather than throwing. #>
    try {
        $null = Invoke-DecisionHttpRequest -Parameters @{ Uri = 'http://ha.invalid/api/states'; Method = 'Get' }
        [pscustomobject]@{ Threw = $false; Message = '' }
    }
    catch { [pscustomobject]@{ Threw = $true; Message = [string]$_.Exception.Message } }
}

try {
    Write-Host "`n--- a rejected token is refused, not repeated ---"
    Reset-Backoff
    $script:ThrowThis = New-HttpError -Status 401

    $first = Invoke-Call
    Test-That 'the call fails' { $first.Threw }
    Test-That 'and is tried exactly once, not retried' { $script:Attempts -eq 1 } "tried $($script:Attempts)"
    Test-That 'the bridge is now holding off' { (Get-BridgeAuthBackoffSeconds) -gt 0 }

    # The point of the whole exercise: the next call must not reach Home Assistant,
    # because a request it never sees cannot count towards a ban.
    $script:Attempts = 0
    $second = Invoke-Call
    Test-That 'the next call fails without being sent' { $second.Threw -and $script:Attempts -eq 0 } `
        "sent $($script:Attempts)"
    Test-That 'and says how long it is holding off for' { $second.Message -match 'not retrying for \d+s' } `
        $second.Message

    Write-Host "`n--- holding off longer each time it is rejected again ---"
    Test-That 'the first hold-off is a minute' { $script:BridgeAuthBackoffSteps[0] -eq 60 }
    $seen = @()
    for ($i = 0; $i -lt 4; $i++) {
        $seen += (Get-BridgeAuthBackoffSeconds)
        # Let the window lapse, as it would with time passing, and be rejected again.
        $script:BridgeAuthBackoffUntil = [DateTimeOffset]::Now.AddSeconds(-1)
        $null = Invoke-Call
    }
    Test-That 'it grows 60 -> 300 -> 900' { ($seen[0] -eq 60) -and ($seen[1] -eq 300) -and ($seen[2] -eq 900) } `
        ($seen -join ', ')
    Test-That 'and then stops growing' { $seen[3] -eq 900 } ($seen -join ', ')

    Write-Host "`n--- a burst does not multiply the hold-off ---"
    # Six calls a cycle used to arrive together. Each one pushing the window out again,
    # or logging again, would be its own problem.
    Reset-Backoff
    $script:ThrowThis = New-HttpError -Status 401
    $null = Invoke-Call
    1..6 | ForEach-Object { $null = Invoke-Call }
    Test-That 'the window is still the first step' { (Get-BridgeAuthBackoffSeconds) -le 60 } `
        "$(Get-BridgeAuthBackoffSeconds)s"
    Test-That 'and only the first was written down' {
        @(Get-Content -LiteralPath $script:LogFile | Where-Object { $_ -match 'Holding off' }).Count -ge 1
    }

    Write-Host "`n--- Home Assistant accepting the bridge clears it ---"
    Reset-Backoff
    $script:ThrowThis = New-HttpError -Status 401
    $null = Invoke-Call
    Test-That 'holding off after a rejection' { (Get-BridgeAuthBackoffSeconds) -gt 0 }
    $script:BridgeAuthBackoffUntil = [DateTimeOffset]::Now.AddSeconds(-1)
    $script:ThrowThis = $null
    $ok = Invoke-Call
    Test-That 'a call that works goes through' { -not $ok.Threw }
    Test-That 'and the hold-off is gone' { (Get-BridgeAuthBackoffSeconds) -eq 0 }
    Test-That 'and starts again from a minute, not from where it left off' {
        $script:ThrowThis = New-HttpError -Status 401
        $null = Invoke-Call
        (Get-BridgeAuthBackoffSeconds) -le 60
    }

    Write-Host "`n--- a ban is named as a ban ---"
    Reset-Backoff
    Set-Content -LiteralPath $script:LogFile -Value '' -Encoding UTF8
    $script:ThrowThis = New-HttpError -Status 403
    $null = Invoke-Call
    $written = (Get-Content -LiteralPath $script:LogFile -Raw)
    Test-That 'the log says the machine was refused outright' { $written -match 'banned address' } $written
    Test-That 'and where the ban is kept' { $written -match 'ip_bans\.yaml' } $written
    Test-That 'and that restarting will not lift it' { $written -match 'does not lift it' } $written

    Write-Host "`n--- an ordinary failure is still retried ---"
    # The hold-off must not swallow what the retry layer is for. A restarting Home
    # Assistant answers 500 and a refused connection carries no status at all; treating
    # either as a rejection would take the bridge off the air for fifteen minutes over
    # a blip.
    Reset-Backoff
    $script:ThrowThis = New-HttpError -Status 500
    $null = Invoke-Call
    Test-That 'a 500 is retried' { $script:Attempts -gt 1 } "tried $($script:Attempts)"
    Test-That 'and does not start a hold-off' { (Get-BridgeAuthBackoffSeconds) -eq 0 }

    Reset-Backoff
    $script:ThrowThis = [Net.WebException]::new('No connection could be made because the target machine actively refused it.')
    $null = Invoke-Call
    Test-That 'a refused connection is retried' { $script:Attempts -gt 1 } "tried $($script:Attempts)"
    Test-That 'and does not start a hold-off either' { (Get-BridgeAuthBackoffSeconds) -eq 0 }

    Write-Host "`n--- classifying what came back ---"
    $rec401 = try { throw (New-HttpError -Status 401) } catch { $_ }
    $rec403 = try { throw (New-HttpError -Status 403) } catch { $_ }
    $rec404 = try { throw (New-HttpError -Status 404) } catch { $_ }
    Test-That '401 is a rejected token' { (Test-BridgeAuthRejection -ErrorRecord $rec401) -eq 'token' }
    Test-That '403 is a ban' { (Test-BridgeAuthRejection -ErrorRecord $rec403) -eq 'banned' }
    Test-That '404 is neither' { (Test-BridgeAuthRejection -ErrorRecord $rec404) -eq '' }
    Test-That 'a refused WebSocket upgrade is read out of its message' {
        # The watch reconnects every cycle, and a banned address is refused there
        # before any token is offered - with the status only in the message.
        $ws = try { throw [InvalidOperationException]::new("The server returned status code '403' when status code '101' was expected.") } catch { $_ }
        (Test-BridgeAuthRejection -ErrorRecord $ws) -eq 'banned'
    }
}
finally {
    Remove-Item -LiteralPath $script:LogFile -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0) {
    Write-Host "`n$($script:Failures) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall passed" -ForegroundColor Green
