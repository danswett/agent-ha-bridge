#Requires -Version 7.0
<#
.SYNOPSIS
    The Detailed activity switch the dashboard draws is the one the daemon reads.

.DESCRIPTION
    Detailed activity decides how much each card carries, and now also whether the
    agent's thinking joins the activity trail. It was a dashboard toggle, then briefly
    a setting in a file on each machine, and is a switch again - per machine, because
    one machine may be doing something you want to watch closely while the others are
    not.

    Three things have to agree for that to work at all, and none of them is checked by
    looking at either end. Home Assistant slugifies a helper's *name* into its id, so a
    name and an id that drift apart silently produce a second helper rather than a
    renamed one. The daemon polls the switch by entity id every reconcile. And the
    dashboard draws a row by entity id too. Get any one of the three wrong and the
    symptom is identical and quiet: a switch that is drawn, can be pressed, and changes
    nothing - or an "Entity not found" row where a control should be.

    So these assert the three against each other rather than individually, and then
    follow the switch through to what it actually controls: whether a thought reaches
    the trail.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
$script:DaemonConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-detailed-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

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

# Home Assistant's slugify, as far as it matters here: lower case, anything that is
# not a letter or digit becomes an underscore, and runs of those collapse.
function ConvertTo-HaSlug {
    param([string]$Text)
    (($Text.ToLowerInvariant() -replace '[^a-z0-9]+', '_')).Trim('_')
}

Write-Host "`n--- the name, the helper and the entity all agree ---"
$slug = $script:DaemonMachineSlug
$expected = Get-BridgeMachineEntityId -Domain 'input_boolean' -Key 'detailed_activity' -Slug $slug

Test-That 'the daemon polls the per-machine switch' {
    [string]$script:DaemonConfig.VerboseToggle -eq $expected
} "reads $($script:DaemonConfig.VerboseToggle), expected $expected"

Test-That 'the helper it creates carries that id' {
    "input_boolean.$($script:DaemonConfig.VerboseHelperId)" -eq $expected
} "helper $($script:DaemonConfig.VerboseHelperId)"

# The trap the existing toggle code documents: Home Assistant makes the id out of the
# name, so a name that slugifies to anything else creates a second helper and the
# daemon then polls one nobody can see.
Test-That 'and the name Home Assistant slugifies produces exactly that helper' {
    (ConvertTo-HaSlug $script:DaemonConfig.VerboseHelperName) -eq [string]$script:DaemonConfig.VerboseHelperId
} "'$($script:DaemonConfig.VerboseHelperName)' slugifies to '$(ConvertTo-HaSlug $script:DaemonConfig.VerboseHelperName)'"

Write-Host "`n--- the dashboard draws the switch the daemon reads ---"
. (Join-Path $PSScriptRoot '..\hooks\decision-mqtt.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-ha-websocket.ps1')

# Capture what would be saved rather than sending it to Home Assistant.
$script:SavedConfig = $null
function Invoke-CopilotHaWebSocket {
    param([Parameter(Mandatory)][object[]]$Commands)
    $script:SavedConfig = $Commands[0].config
    @()
}
$sessions = @([pscustomobject]@{ Node = 'copilot_abc123def456'; Name = 'Copilot: a task'; Machine = 'BOX'; Kind = 'copilot' })
$mine = [pscustomobject]@{ Slug = $slug; Machine = 'DSWETT-HOME'; Online = $true; IncludeProfile = $false; IncludeResume = $true; IncludeAgent = $true; IncludeDetailed = $true }
$old  = [pscustomobject]@{ Slug = 'dans_mbp'; Machine = 'Dans-MBP'; Online = $true; IncludeProfile = $false; IncludeResume = $true; IncludeAgent = $false; IncludeDetailed = $false }

Save-CopilotSessionDashboard -Sessions $sessions -Machines @($mine, $old)
$json = $script:SavedConfig | ConvertTo-Json -Depth 40 -Compress

Test-That 'the machines are still listed' { $json -match 'Machines' }
Test-That 'and the toggle is the entity the daemon polls' { $json -match [regex]::Escape($expected) } $expected

# The bug this replaces: a peer on an older bridge has no such helper, so drawing its
# row put an "Entity not found" box on everyone's dashboard. Seen live against 1.14.6.
Test-That 'a machine that cannot have one gets no toggle' {
    $json -notmatch [regex]::Escape('input_boolean.agent_bridge_dans_mbp_detailed_activity')
}
Test-That 'but it is still listed as a machine' { $json -match 'Dans-MBP' }
Test-That 'the switch sits with the machine, not on a card of its own' {
    $json -notmatch '"title":"Detailed activity"'
}

Write-Host "`n--- the switch decides, the setting is only the default ---"
$script:ProbeState = $null
function Get-DaemonEntityState { param([string]$EntityId, [hashtable]$Headers) $script:ProbeState }
$script:SettingValue = $false
function Get-BridgeSetting { param([string]$Path, $Default) $script:SettingValue }
$headers = @{ Authorization = '******' }

# The setting says off throughout this pair, so only the switch can account for a
# yes. Left saying on, a switch that was never read would still produce one and this
# would pass while reading nothing at all - which it did, until a mutation caught it.
$script:SettingValue = $false
$script:ProbeState = [pscustomobject]@{ state = 'on' }
Test-That 'the switch on means detail on, though the setting says off' { Test-VerboseStreaming -Headers $headers }
$script:ProbeState = [pscustomobject]@{ state = 'off' }
Test-That 'and off means off' { -not (Test-VerboseStreaming -Headers $headers) }

# And the other way round, so neither answer can be coming from the setting.
$script:SettingValue = $true
$script:ProbeState = [pscustomobject]@{ state = 'off' }
Test-That 'the switch off wins over a setting that says on' {
    -not (Test-VerboseStreaming -Headers $headers)
}

# A machine whose helper has not been created yet, or one that cannot reach Home
# Assistant, must behave exactly as it did before there was a switch.
$script:ProbeState = [pscustomobject]@{ state = 'unavailable' }
Test-That 'no switch yet falls back to the setting' { Test-VerboseStreaming -Headers $headers }
function Get-DaemonEntityState { param([string]$EntityId, [hashtable]$Headers) throw 'no Home Assistant' }
Test-That 'and an unreachable Home Assistant does too, rather than silently going quiet' {
    Test-VerboseStreaming -Headers $headers
}
$script:SettingValue = $false
Test-That 'with the setting off and no switch, detail stays off' {
    -not (Test-VerboseStreaming -Headers $headers)
}

Write-Host "`n--- and that is what puts a thought in the trail ---"
# The end the switch exists for. Asserted through the real reducer, so the switch and
# the thing it controls are connected rather than merely both present.
$batch = @(
    '{"type":"assistant.message","data":{"reasoningText":"Weighing the options"}}'
    '{"type":"tool.execution_start","data":{"toolName":"view"}}'
)
$on = Get-ActivityFromEvents -Lines $batch -VerboseMode $true
$off = Get-ActivityFromEvents -Lines $batch -VerboseMode $false
Test-That 'detail on puts the thought in the trail' {
    (@($on.History) -join '|') -eq 'Thinking: Weighing the options|Running: view'
} (@($on.History) -join '|')
Test-That 'detail off leaves the trail as it was' {
    (@($off.History) -join '|') -eq 'Running: view'
} (@($off.History) -join '|')
Test-That 'but the thought is captured either way, so the switch shows it at once' {
    $off.Reasoning -eq 'Weighing the options'
}

Write-Host "`n--- the trail is deeper while detail is on ---"
# Almost every message carries a thought, so the trail fills about twice as fast;
# at the ordinary depth, turning detail on would lose you actions to gain thoughts.
Test-That 'a deeper cap is configured' {
    [int]$script:DaemonConfig.ActivityHistoryDetailed -gt [int]$script:DaemonConfig.ActivityHistory
} "$($script:DaemonConfig.ActivityHistory) -> $($script:DaemonConfig.ActivityHistoryDetailed)"

Remove-Item -LiteralPath $script:DaemonConfig.LogFile -Force -ErrorAction SilentlyContinue
if ($script:Failures -gt 0) {
    Write-Host "`n$($script:Failures) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall passed" -ForegroundColor Green
