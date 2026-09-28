#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the daemon's read of Home Assistant states (Get-DaemonHomeAssistantStates).

.DESCRIPTION
    The daemon used to read every state (5,354 entities, 2.4 MB, on DASDESK) each
    reconcile to find the bridge's own ~40, which held about 180 MB of its memory. Home
    Assistant now filters them through /api/template. These check that the filtered
    read is what is asked for, that its text reply is parsed, and that a Home Assistant
    which refuses it still gets the full list. HTTP is a recorder.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
$script:DaemonConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-state-read-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

function New-HttpError { param([int]$Code)
    $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$Code)
    $exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new("HTTP $Code", $response)
    throw $exception
}

$script:Calls = @()
$script:TemplateReply = { '[{"entity_id":"sensor.agent_bridge_desk_sessions","state":"1","attributes":{"machine":"DESK","sessions":[]}}]' }
$script:FullList = @([pscustomobject]@{ entity_id = 'light.kitchen'; state = 'on' }, [pscustomobject]@{ entity_id = 'sensor.agent_bridge_desk_sessions'; state = '1' })
function Invoke-DecisionHttpRequest {
    param([hashtable]$Parameters)
    $path = ([string]$Parameters.Uri) -replace '^https?://[^/]+', ''
    $script:Calls += "$($Parameters.Method) $path"
    if ($path -eq '/api/template') {
        $script:LastTemplate = (($Parameters.Body | ConvertFrom-Json).template)
        return & $script:TemplateReply
    }
    $script:FullList
}
function Reset-Cache { $script:DaemonStatesCache = $null; $script:DaemonStatesCacheAt = [DateTimeOffset]::MinValue; $script:Calls = @() }
$headers = @{ Authorization = 'Bearer t' }

Write-Host '--- the filtered read ---'
Reset-Cache
$states = Get-DaemonHomeAssistantStates -Headers $headers
Test-That 'only the filtered read is made' { ($script:Calls -join ',') -eq 'Post /api/template' } ($script:Calls -join ',')
Test-That 'asking for the bridge''s entities and the MCP server''s' { $script:LastTemplate -match "startswith\('agent_bridge_'\)" -and $script:LastTemplate -match "startswith\('mcp_'\)" }
Test-That 'its text reply is parsed into states' { @($states).Count -eq 1 -and $states[0].entity_id -eq 'sensor.agent_bridge_desk_sessions' -and $states[0].attributes.machine -eq 'DESK' }
Test-That 'which the peer scan reads as before' { @(Get-BridgePeerMachine -States $states).Count -eq 1 }
$script:Calls = @()
$null = Get-DaemonHomeAssistantStates -Headers $headers
Test-That 'and it is cached' { $script:Calls.Count -eq 0 }

Reset-Cache
$script:TemplateReply = { '[]' }
$states = Get-DaemonHomeAssistantStates -Headers $headers
Test-That 'no bridge entities is an empty list, not a reason to read everything' { @($states).Count -eq 0 -and ($script:Calls -join ',') -eq 'Post /api/template' }

Write-Host '--- a Home Assistant that will not render it ---'
Reset-Cache
$script:TemplateReply = { New-HttpError 500 }
$states = Get-DaemonHomeAssistantStates -Headers $headers
Test-That 'a failure reads the full list instead' { ($script:Calls -join ',') -eq 'Post /api/template,Get /api/states' -and @($states).Count -eq 2 } ($script:Calls -join ',')
Reset-Cache
$script:TemplateReply = { '[]' }
$null = Get-DaemonHomeAssistantStates -Headers $headers
Test-That 'and a passing failure is tried again next time' { ($script:Calls -join ',') -eq 'Post /api/template' }

Reset-Cache
$script:TemplateReply = { New-HttpError 403 }
$null = Get-DaemonHomeAssistantStates -Headers $headers
Reset-Cache
$null = Get-DaemonHomeAssistantStates -Headers $headers
Test-That 'a refusal is not asked again' { ($script:Calls -join ',') -eq 'Get /api/states' } ($script:Calls -join ',')

Write-Host '--- handing memory back ---'
$clock = [DateTimeOffset]::Parse('2026-09-28T12:00:00Z')
$script:DaemonMemoryTrimmedAt = [DateTimeOffset]::MinValue
$big = { [pscustomobject]@{ Committed = 200MB; Heap = 30MB } }
$small = { [pscustomobject]@{ Committed = 60MB; Heap = 30MB } }
Test-That 'a large reserve is handed back' { Invoke-DaemonMemoryTrim -Now $clock -Measure $big }
Test-That 'but not again within five minutes' { -not (Invoke-DaemonMemoryTrim -Now $clock.AddMinutes(4) -Measure $big) }
Test-That 'after which it may' { Invoke-DaemonMemoryTrim -Now $clock.AddMinutes(6) -Measure $big }
Test-That 'a small reserve is not worth a full collection' { -not (Invoke-DaemonMemoryTrim -Now $clock.AddMinutes(20) -Measure $small) }
Test-That 'the real measurement works' { (Invoke-DaemonMemoryTrim -Now $clock.AddHours(1) -MinimumReserveBytes 0) -eq $true }

Remove-Item -LiteralPath $script:DaemonConfig.LogFile -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All state read checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
