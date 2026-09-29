#Requires -Version 7.0
<#
.SYNOPSIS
    The reconcile's one state read, and that every check it replaced still sees a press.

.DESCRIPTION
    A reconcile used to make about 5 Home Assistant reads per live session and 3
    besides, every pass, whether or not anything had happened: the repair pass read the
    reply box and the decision selector, the reply pass read the decision selector
    again and the payload sensor, and the stop pass read the stop button. Thirteen
    round trips for two sessions, forty-three for eight.

    Set-DaemonReconcileSnapshot now reads them all once. The risk in that is not the
    reading, it is the middle: a check that keeps calling Get-HomeAssistantState is
    still correct and still slow, and a check that reads the snapshot but is handed one
    that never contains its entity is fast and always wrong. So these assert both ends
    AND the wire - the snapshot is filled from the same template the daemon uses, and
    each converted check is then driven through it and must see the pressed value
    without any direct read being made.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-mqtt.ps1')
$script:DecisionBridgeConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-state-snapshot-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

# The daemon's shared state, as agent-bridge-daemon.ps1 declares it before dot-sourcing.
$script:DaemonConfig = @{ McpScanCacheSeconds = 60 }
$script:DaemonStatesCache = $null
$script:DaemonStatesCacheAt = [DateTimeOffset]::MinValue
$script:DaemonReconcileStates = $null
function Write-DaemonLog { param([string]$Message) }

. (Join-Path $PSScriptRoot '..\hooks\daemon-discovery.ps1')

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

$headers = @{ Authorization = '******' }
$node = 'agent_bridge_abc123def4567890'

# What Home Assistant would render for this template. Built here in the shape the real
# one produces - a list of { entity_id, state, attributes } - so a change to that shape
# fails these rather than silently emptying the snapshot.
$script:RenderedStates = @(
    [pscustomobject]@{ entity_id = "text.${node}_reply";           state = ' ';        attributes = [pscustomobject]@{ friendly_name = 'Reply' } }
    [pscustomobject]@{ entity_id = "select.${node}_decision";      state = 'Idle';     attributes = [pscustomobject]@{ options = @('Idle') } }
    [pscustomobject]@{ entity_id = "sensor.${node}_reply_payload"; state = 'unknown';  attributes = [pscustomobject]@{} }
    [pscustomobject]@{ entity_id = "button.${node}_stop";          state = 'unknown';  attributes = [pscustomobject]@{} }
)
$script:HttpCalls = 0
$script:DirectReads = @()
function Invoke-DecisionHttpRequest {
    param([Parameter(Mandatory)][hashtable]$Parameters, [int]$RetryCount = 4)
    $script:HttpCalls++
    ($script:RenderedStates | ConvertTo-Json -Depth 8 -Compress)
}
function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    $script:DirectReads += $EntityId
    throw "no direct read expected for $EntityId"
}

Write-Host '--- one read answers the whole pass ---'
$script:HttpCalls = 0
Set-DaemonReconcileSnapshot -Headers $headers
Test-That 'the snapshot is taken with a single Home Assistant call' { $script:HttpCalls -eq 1 } "calls=$($script:HttpCalls)"
Test-That 'and it holds every entity the pass reads' {
    @("text.${node}_reply", "select.${node}_decision", "sensor.${node}_reply_payload", "button.${node}_stop") |
        ForEach-Object { $null -ne (Get-DaemonEntityState -EntityId $_ -Headers $headers) } |
        Where-Object { -not $_ } | Measure-Object | ForEach-Object { $_.Count -eq 0 }
}
Test-That 'reading all four costs no further calls' { $script:HttpCalls -eq 1 } "calls=$($script:HttpCalls)"
Test-That 'and none of them fell through to a direct read' { @($script:DirectReads).Count -eq 0 } "direct=[$(@($script:DirectReads) -join ',')]"

Write-Host ''
Write-Host '--- the values are the real ones, not merely present ---'
Test-That 'the reply box reads back its blank sentinel' {
    [string](Get-DaemonEntityState -EntityId "text.${node}_reply" -Headers $headers).state -eq ' '
}
Test-That 'the decision selector reads back Idle, with its options' {
    $d = Get-DaemonEntityState -EntityId "select.${node}_decision" -Headers $headers
    [string]$d.state -eq 'Idle' -and @($d.attributes.options) -contains 'Idle'
}

Write-Host ''
Write-Host '--- a press lands on the next snapshot ---'
# The wire that matters. A check reading a snapshot that is never refreshed would pass
# every assertion above and still never notice anything a person did.
$pressedAt = [DateTimeOffset]::Now.ToString('o')
$script:RenderedStates = @(
    [pscustomobject]@{ entity_id = "text.${node}_reply";           state = 'ship it';            attributes = [pscustomobject]@{} }
    [pscustomobject]@{ entity_id = "select.${node}_decision";      state = 'Awaiting answer...'; attributes = [pscustomobject]@{ options = @('Awaiting answer...', 'Yes', 'Cancel request'); question = 'Ship?' } }
    [pscustomobject]@{ entity_id = "sensor.${node}_reply_payload"; state = $pressedAt;           attributes = [pscustomobject]@{} }
    [pscustomobject]@{ entity_id = "button.${node}_stop";          state = $pressedAt;           attributes = [pscustomobject]@{} }
)
Set-DaemonReconcileSnapshot -Headers $headers
Test-That 'the reply typed on the dashboard is seen' {
    [string](Get-DaemonEntityState -EntityId "text.${node}_reply" -Headers $headers).state -eq 'ship it'
}
Test-That 'the armed question is seen, with the attribute the reply gate reads' {
    $d = Get-DaemonEntityState -EntityId "select.${node}_decision" -Headers $headers
    [string]$d.state -eq 'Awaiting answer...' -and [string]$d.attributes.question -eq 'Ship?'
}
Test-That 'the End session press is seen' {
    ([datetimeoffset](Get-DaemonEntityState -EntityId "button.${node}_stop" -Headers $headers).state) -eq ([datetimeoffset]$pressedAt)
}
Test-That 'the reply card payload stamp is seen' {
    ([datetimeoffset](Get-DaemonEntityState -EntityId "sensor.${node}_reply_payload" -Headers $headers).state) -eq ([datetimeoffset]$pressedAt)
}
# Compared as a moment, not as text, because that is what the daemon does - a press
# counts only if it is newer than the moment the question was armed. Both read paths
# hand back a DateTime rather than the ISO string Home Assistant sent, because
# ConvertFrom-Json and Invoke-RestMethod both parse a date-shaped string; checked
# against the live instance, the two agree exactly. Asserting on the text instead
# would pass on one path and fail on the other for no real reason.
Test-That 'and a press is a date, the type the press comparison needs' {
    (Get-DaemonEntityState -EntityId "button.${node}_stop" -Headers $headers).state -is [datetime]
}
Test-That 'and a second pass really did ask Home Assistant again' { $script:HttpCalls -eq 2 } "calls=$($script:HttpCalls)"

Write-Host ''
Write-Host '--- the cache does not outlive the pass, or hide a press ---'
# Get-DaemonHomeAssistantStates caches for 60 s for its own slow-moving callers. A
# snapshot that honoured that cache would show a press up to a minute late, so it asks
# for a fresh read every time.
$script:HttpCalls = 0
Set-DaemonReconcileSnapshot -Headers $headers
Set-DaemonReconcileSnapshot -Headers $headers
Test-That 'two passes in the same minute are two reads, not one cached' { $script:HttpCalls -eq 2 } "calls=$($script:HttpCalls)"
Test-That 'the slow-moving callers still get their cache' {
    $before = $script:HttpCalls
    [void](Get-DaemonHomeAssistantStates -Headers $headers)
    $script:HttpCalls -eq $before
} "calls went $($script:HttpCalls)"

Clear-DaemonReconcileSnapshot
$script:DirectReads = @()
Test-That 'once the pass ends, a read goes back to Home Assistant directly' {
    try { [void](Get-DaemonEntityState -EntityId "button.${node}_stop" -Headers $headers); $false }
    catch { @($script:DirectReads) -contains "button.${node}_stop" }
}

Write-Host ''
Write-Host '--- an entity the snapshot does not hold is still read ---'
# Several callers use a throwing read as an existence probe. Answering "absent" from
# the snapshot would quietly change what they decide.
Set-DaemonReconcileSnapshot -Headers $headers
$script:DirectReads = @()
Test-That 'an unknown entity falls through rather than reading as missing' {
    try { [void](Get-DaemonEntityState -EntityId "select.${node}_f1" -Headers $headers); $false }
    catch { @($script:DirectReads) -contains "select.${node}_f1" }
}

Write-Host ''
Write-Host '--- a failed snapshot degrades to the old behaviour ---'
function Invoke-DecisionHttpRequest {
    param([Parameter(Mandatory)][hashtable]$Parameters, [int]$RetryCount = 4)
    throw 'Home Assistant is unreachable'
}
$script:DaemonStatesCache = $null
Set-DaemonReconcileSnapshot -Headers $headers
$script:DirectReads = @()
Test-That 'no snapshot is left behind' { $null -eq $script:DaemonReconcileStates }
Test-That 'and every check reads directly, exactly as before' {
    try { [void](Get-DaemonEntityState -EntityId "select.${node}_decision" -Headers $headers); $false }
    catch { @($script:DirectReads) -contains "select.${node}_decision" }
}

Write-Host ''
Write-Host '--- the checks that were converted still go through it ---'
# The other half of the wire: a converted call site that drifts back to a direct read
# is correct and slow, and nothing else here would notice.
$hot = @(
    @{ File = 'daemon-sessions.ps1'; Entity = 'text.${node}_reply' }
    @{ File = 'daemon-sessions.ps1'; Entity = 'select.${node}_decision' }
    @{ File = 'daemon-replies.ps1';  Entity = 'select.${node}_decision' }
    @{ File = 'daemon-replies.ps1';  Entity = 'sensor.${node}_reply_payload' }
    @{ File = 'daemon-launch.ps1';   Entity = 'button.${node}_stop' }
)
foreach ($check in $hot) {
    $path = Join-Path $PSScriptRoot "..\hooks\$($check.File)"
    $lines = Get-Content -LiteralPath $path
    $pattern = [regex]::Escape("-EntityId `"$($check.Entity)`"")
    Test-That "$($check.File) reads $($check.Entity) from the snapshot" {
        @($lines | Where-Object { $_ -match "Get-DaemonEntityState\s+$pattern" }).Count -ge 1
    }
    # Add-DaemonSession still reads the decision selector directly, on purpose: it uses
    # a read that throws to decide whether a brand-new session's entities exist yet, so
    # it must ask Home Assistant rather than a snapshot that cannot know. It is the
    # only one left, and it is named $probe.
    Test-That "  and the repeated check is not left reading directly" {
        @($lines | Where-Object {
            $_ -match "Get-HomeAssistantState\s+$pattern" -and $_ -notmatch '\$probe'
        }).Count -eq 0
    } "[$(@($lines | Where-Object { $_ -match "Get-HomeAssistantState\s+$pattern" -and $_ -notmatch '\$probe' } | ForEach-Object { $_.Trim() }) -join ' | ')]"
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
