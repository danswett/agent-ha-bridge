#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for collecting and showing each agent's remaining allowance
    (hooks/daemon-usage.ps1, Publish-CopilotMqttUsage, and the usage card).

.DESCRIPTION
    Three vendors report the same idea in three different shapes - Copilot a monthly
    pool of credits it describes by what remains, Codex two rolling windows it
    describes by what is used, Claude a list of windows that varies by plan - and the
    card draws all of them from one normalised record. These check that normalisation
    against bodies in each vendor's real shape, then run the whole chain: the real
    publishers, the real dashboard generator and the real card under node.

    Nothing here reaches a network. Every collector takes its fetch as a scriptblock
    and its files as paths, so the stubs replace the transport rather than the parsing.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-mqtt.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-ha-websocket.ps1')
. (Join-Path $PSScriptRoot '..\hooks\daemon-usage.ps1')
$env:BRIDGE_FRONTEND_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\bridge-frontend-cards.ps1')
$script:DecisionBridgeConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-usage-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $__ok = $false
    try { $__ok = [bool](& $Condition) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($__ok) { Write-Host "  PASS  $Name" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) "usage-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $root | Out-Null

# --- 0. the module does not quietly replace anything ------------------------------

Write-Host '--- names this module claims ---'

# The daemon dot-sources every hook into one scope, so a function defined twice is
# simply the last one loaded. That is how Get-BridgeCopilotUsage - which already meant
# "has Copilot been used and signed in here" for the launch card - was replaced by an
# allowance reader of the same name, and the launcher started failing on a property
# that no longer existed. Nothing announced it; the suite that caught it was three
# files away.
$script:UsageModuleNames = @(Select-String -Path (Join-Path $PSScriptRoot '..\hooks\daemon-usage.ps1') `
        -Pattern '^function ([A-Za-z][A-Za-z-]*)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
Test-That 'the module defines the functions this suite covers' {
    $script:UsageModuleNames -contains 'Get-BridgeAgentAllowance' -and $script:UsageModuleNames.Count -ge 10
}
Test-That 'and none of them is a name another hook already defines' {
    $clashes = @()
    foreach ($name in $script:UsageModuleNames) {
        $others = @(Select-String -Path (Join-Path $PSScriptRoot '..\hooks\*.ps1') -Pattern "^function $name\b" |
            Where-Object { $_.Path -notmatch 'daemon-usage\.ps1$' })
        if ($others.Count -gt 0) { $clashes += $name }
    }
    $clashes.Count -eq 0
} "clashes=$(@(foreach ($name in $script:UsageModuleNames) { if (@(Select-String -Path (Join-Path $PSScriptRoot '..\hooks\*.ps1') -Pattern "^function $name\b" | Where-Object { $_.Path -notmatch 'daemon-usage\.ps1$' }).Count) { $name } }) -join ',')"

# --- 1. Copilot -------------------------------------------------------------------

Write-Host '--- Copilot, which reports what is left ---'

$copilotConfig = Join-Path $root 'config.json'
Set-Content -LiteralPath $copilotConfig -Encoding UTF8 -Value @'
// Disposable cache for Copilot user responses, safe to delete.
{
  "lastLoggedInUser": { "host": "https://github.com", "login": "work_account" },
  "loggedInUsers": [
    { "host": "https://github.com", "login": "personal_account" },
    { "host": "https://github.com", "login": "work_account" }
  ]
}
'@

Test-That 'the banner Copilot writes above its JSON does not stop it being read' {
    $null -ne (Get-BridgeCopilotAccount -ConfigPath $copilotConfig)
}
Test-That 'and the account reported is the one last signed in, not the first listed' {
    (Get-BridgeCopilotAccount -ConfigPath $copilotConfig).Login -ceq 'work_account'
}

# The shape GitHub really returns, trimmed to the parts that are read. The snapshot is
# stamped now rather than on a fixed date: the card calls a reading over an hour old a
# memory, so a literal timestamp here passes in the morning and fails after lunch.
function New-CopilotBody {
    param(
        [double]$Remaining = 492078,
        [double]$Entitlement = 1500000,
        [string]$Login = 'work_account',
        [string]$Stamp = ([DateTimeOffset]::UtcNow.ToString('o'))
    )
    @"
{
  "login": "$Login",
  "copilot_plan": "enterprise",
  "quota_reset_date_utc": "2026-11-01T00:00:00.000Z",
  "quota_snapshots": {
    "chat": { "entitlement": 0, "remaining": 0, "unlimited": true, "percent_remaining": 100 },
    "premium_interactions": {
      "entitlement": $Entitlement,
      "remaining": $Remaining,
      "percent_remaining": 32.8,
      "unlimited": false,
      "timestamp_utc": "$Stamp"
    }
  }
}
"@ | ConvertFrom-Json
}

$copilot = Get-BridgeCopilotAllowance -ConfigPath $copilotConfig -CachePath '' -ResolveToken { 'stub' } -Fetch { New-CopilotBody }

Test-That 'the live reading is used when a token answers' { $copilot.source -ceq 'api' }
Test-That 'and it is attributed to the account that was asked for' { $copilot.account -ceq 'work_account' }
Test-That 'a quota reported as remaining becomes a percentage used' {
    $copilot.percent -eq 67.2
} "percent=$($copilot.percent)"
Test-That 'the window keeps the raw figures the card prints under the bar' {
    $copilot.windows[0].used -eq 1007922 -and $copilot.windows[0].limit -eq 1500000 -and $copilot.windows[0].unit -ceq 'AIC'
}
Test-That 'the reset date is carried as sortable UTC, not a local short date' {
    $copilot.windows[0].resets_at -match '^2026-11-01T00:00:00'
} "resets_at=$($copilot.windows[0].resets_at)"
Test-That 'and the window it belongs to is the month ending there, so pace can be read' {
    $copilot.windows[0].Contains('elapsed') -and $copilot.windows[0].elapsed -gt 0
} "elapsed=$(if ($copilot.windows[0].Contains('elapsed')) { $copilot.windows[0].elapsed } else { '<none>' })"
Test-That 'an unlimited snapshot is not drawn as a bar that can never move' {
    $copilot.windows.Count -eq 1
}

# The cache is what is left when the live call cannot be made, and it is the case
# that used to be silently reported as healthy: a stale number and no sign of it.
$copilotCache = Join-Path $root 'copilot-user-cache.json'
Set-Content -LiteralPath $copilotCache -Encoding UTF8 -Value @'
// Disposable cache for Copilot user responses, safe to delete.
{
  "copilotUserCache": {
    "v1:older": {
      "retrievedAt": "2026-10-05T19:32:20.071Z",
      "response": {
        "login": "work_account", "copilot_plan": "enterprise",
        "quota_reset_date_utc": "2026-11-01T00:00:00.000Z",
        "quota_snapshots": { "premium_interactions": { "entitlement": 1500000, "remaining": 900000 } }
      }
    },
    "v1:newer": {
      "retrievedAt": "2026-10-06T19:32:20.071Z",
      "response": {
        "login": "work_account", "copilot_plan": "enterprise",
        "quota_reset_date_utc": "2026-11-01T00:00:00.000Z",
        "quota_snapshots": { "premium_interactions": { "entitlement": 1500000, "remaining": 600000 } }
      }
    },
    "v1:other": {
      "retrievedAt": "2026-10-07T19:32:20.071Z",
      "response": {
        "login": "personal_account", "copilot_plan": "enterprise",
        "quota_reset_date_utc": "2026-11-01T00:00:00.000Z",
        "quota_snapshots": { "premium_interactions": { "entitlement": 1000000, "remaining": 999358 } }
      }
    }
  }
}
'@

$fallback = Get-BridgeCopilotAllowance -ConfigPath $copilotConfig -CachePath $copilotCache `
    -ResolveToken { 'stub' } -Fetch { throw 'the network is down' }

Test-That 'a failed live call falls back to what Copilot last cached' { $fallback.source -ceq 'cache' }
Test-That 'taking the newest entry for that account' { $fallback.percent -eq 60 } "percent=$($fallback.percent)"
Test-That 'never another account cached beside it' { $fallback.account -ceq 'work_account' }
Test-That 'and it says why it is not live, so a stale bar is not read as a fresh one' {
    $fallback.error -match 'the network is down'
}
Test-That 'the cached reading is dated when it was taken, not when it was read' {
    $fallback.measured_at -match '^2026-10-06T19:32:20'
} "measured_at=$($fallback.measured_at)"

$nothing = Get-BridgeCopilotAllowance -ConfigPath $copilotConfig -CachePath '' -ResolveToken { '' } -Fetch { throw 'no token' }
Test-That 'with neither, the record exists but offers no percentage to draw' {
    $null -eq $nothing.percent -and $nothing.windows.Count -eq 0 -and $nothing.error
}
Test-That 'a machine where Copilot has never run reports nothing at all' {
    $null -eq (Get-BridgeCopilotAllowance -ConfigPath (Join-Path $root 'absent.json') -CachePath '')
}

# --- 2. Claude --------------------------------------------------------------------

Write-Host ''
Write-Host '--- Claude, whose windows depend on the plan ---'

$claudeStatePath = Join-Path $root 'claude-credentials.json'
$claudeExpiry = [DateTimeOffset]::UtcNow.AddMinutes(30).ToUnixTimeMilliseconds()
Set-Content -LiteralPath $claudeStatePath -Encoding UTF8 -Value @"
{ "claudeAiOauth": { "accessToken": "stub-token", "subscriptionType": "pro", "expiresAt": $claudeExpiry } }
"@

# The body Anthropic really returns when no five-hour window is open: the session
# limit is listed, but inactive and at zero. The weekly window is anchored relative to
# now for the same reason the Copilot snapshot is - a fixed date makes "how far
# through the week are we" depend on the day the suite happens to run.
$claudeWeekStart = [DateTimeOffset]::UtcNow.AddDays(-2)
$claudeWeekEnd = $claudeWeekStart.AddDays(7)
$claudeBody = @"
{
  "seven_day_breakdown": { "window_started_at": "$($claudeWeekStart.ToString('o'))" },
  "limits": [
    { "kind": "session", "percent": 0, "resets_at": null, "is_active": false },
    { "kind": "weekly_all", "percent": 14, "resets_at": "$($claudeWeekEnd.ToString('o'))", "is_active": true }
  ]
}
"@ | ConvertFrom-Json

$claude = Get-BridgeClaudeAllowance -StatePath $claudeStatePath -Fetch { $claudeBody }

Test-That 'the plan comes from the credential, not from the usage body' { $claude.plan -ceq 'pro' }
# The bug this guards: filtering out inactive zero windows hid the session limit from
# anyone who had not used Claude for a few hours, so Claude looked weekly-only.
Test-That 'the session limit is drawn even with no window open' {
    @($claude.windows | Where-Object { $_.key -ceq 'session' }).Count -eq 1
} "windows=$(@($claude.windows | ForEach-Object { $_.key }) -join ',')"
Test-That 'at zero, which is what it is, rather than being left out' {
    (@($claude.windows | Where-Object { $_.key -ceq 'session' })[0]).percent -eq 0
}
Test-That 'and it is labelled with the window it covers' {
    (@($claude.windows | Where-Object { $_.key -ceq 'session' })[0]).label -ceq 'Session (5h)'
}
Test-That 'a window with no reset time yet carries none, rather than an invented one' {
    -not (@($claude.windows | Where-Object { $_.key -ceq 'session' })[0]).Contains('resets_at')
}
Test-That 'the weekly window is labelled for a person' {
    (@($claude.windows | Where-Object { $_.key -ceq 'weekly_all' })[0]).label -ceq 'Weekly'
}
Test-That 'its reset is normalised to UTC' {
    (@($claude.windows | Where-Object { $_.key -ceq 'weekly_all' })[0]).resets_at -match "^$($claudeWeekEnd.ToString('yyyy-MM-dd'))"
}
Test-That 'and the window start it reports gives the weekly bar its pace mark' {
    $w = @($claude.windows | Where-Object { $_.key -ceq 'weekly_all' })[0]
    $w.Contains('elapsed') -and $w.elapsed -gt 25 -and $w.elapsed -lt 32
} "elapsed=$((@($claude.windows | Where-Object { $_.key -ceq 'weekly_all' })[0]).elapsed)"
Test-That 'the headline is the window closest to running out, not the first listed' {
    $claude.percent -eq 14
} "percent=$($claude.percent)"

# Anthropic retires a refresh token as it is used, so the bridge never refreshes:
# it would either sign Claude Code out or race its own write. An expired token is
# simply not spent, and the retained sensor keeps its last reading and ages.
Test-That 'an expired token is not spent at all' {
    $expired = Join-Path $root 'claude-expired.json'
    $past = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeMilliseconds()
    Set-Content -LiteralPath $expired -Encoding UTF8 -Value "{ `"claudeAiOauth`": { `"accessToken`": `"stub`", `"expiresAt`": $past } }"
    $called = $false
    $result = Get-BridgeClaudeAllowance -StatePath $expired -Fetch { $script:ClaudeFetchCalled = $true; $claudeBody }
    $null -eq $result -and -not $called
}
Test-That 'and a token refused as it expires is not reported as a fault' {
    $null -eq (Get-BridgeClaudeAllowance -StatePath $claudeStatePath -Fetch { throw 'Response status code does not indicate success: 401 (Unauthorized).' })
}
Test-That 'while a real failure still is' {
    $broken = Get-BridgeClaudeAllowance -StatePath $claudeStatePath -Fetch { throw 'the name resolution failed' }
    $null -eq $broken.percent -and $broken.error -match 'name resolution'
}
Test-That 'and a machine with no Claude credential reports nothing' {
    $null -eq (Get-BridgeClaudeAllowance -StatePath (Join-Path $root 'absent.json'))
}

# --- 3. Codex -------------------------------------------------------------------

Write-Host ''
Write-Host '--- Codex, which only ever knows what its last reply told it ---'

$codexRoot = Join-Path $root 'codex-sessions'
New-Item -ItemType Directory -Path $codexRoot | Out-Null
$older = Join-Path $codexRoot 'rollout-old.jsonl'
$newer = Join-Path $codexRoot 'rollout-new.jsonl'
Set-Content -LiteralPath $older -Encoding UTF8 -Value @(
    '{"timestamp":"2026-09-01T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":99.0,"window_minutes":300,"resets_at":1790124112},"plan_type":"plus"}}}'
)
Set-Content -LiteralPath $newer -Encoding UTF8 -Value @(
    '{"timestamp":"2026-09-22T23:26:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":5.0,"window_minutes":300,"resets_at":1790124112},"secondary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1790580854},"plan_type":"plus"}}}'
    'this line is not json'
    '{"timestamp":"2026-09-22T23:26:21.422Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1790124112},"secondary":{"used_percent":3.0,"window_minutes":10080,"resets_at":1790580854},"plan_type":"plus"}}}'
    '{"timestamp":"2026-09-22T23:27:00.000Z","type":"event_msg","payload":{"type":"agent_message"}}'
)
(Get-Item -LiteralPath $older).LastWriteTime = [DateTime]::Parse('2026-09-01T10:00:00')
(Get-Item -LiteralPath $newer).LastWriteTime = [DateTime]::Parse('2026-09-22T23:27:00')

$codex = Get-BridgeCodexAllowance -SessionRoot $codexRoot

Test-That 'the newest transcript wins, not whichever is found first' { $codex.percent -eq 12 } "percent=$($codex.percent)"
Test-That 'and within it the last reading, not the first' {
    $codex.windows[0].percent -eq 12 -and $codex.windows[1].percent -eq 3
}
Test-That 'a line that is not JSON is stepped over rather than ending the search' {
    $codex.windows.Count -eq 2
}
Test-That 'windows are named from the length Codex reports' {
    $codex.windows[0].label -ceq '5h limit' -and $codex.windows[1].label -ceq 'Weekly'
} "labels=$(@($codex.windows | ForEach-Object { $_.label }) -join ',')"
Test-That 'the epoch reset becomes the same UTC string the others use' {
    $codex.windows[0].resets_at -match '^2026-09-2\dT'
} "resets_at=$($codex.windows[0].resets_at)"
Test-That 'the reading is dated from the transcript, so the card can show its age' {
    $codex.measured_at -match '^2026-09-22T23:26:21'
} "measured_at=$($codex.measured_at)"
Test-That 'and a machine that has never run Codex reports nothing' {
    $null -eq (Get-BridgeCodexAllowance -SessionRoot (Join-Path $root 'absent'))
}

Write-Host ''
Write-Host '--- collecting across clients ---'
Test-That 'asking for no clients yields an empty list, not a null to be indexed' {
    @(Get-BridgeAgentAllowance -Clients @()).Count -eq 0
}
Test-That 'and a client with no collector is skipped rather than invented' {
    @(Get-BridgeAgentAllowance -Clients @('mcp')).Count -eq 0
} "count=$(@(Get-BridgeAgentAllowance -Clients @('mcp')).Count)"

# --- 4. what the bridge publishes -------------------------------------------------

Write-Host ''
Write-Host '--- the sensors the daemon publishes ---'

$script:Published = [System.Collections.Generic.List[object]]::new()
function Publish-CopilotMqttMessage {
    param([string]$Topic, [string]$Payload, [hashtable]$Headers, [switch]$Retain)
    $script:Published.Add([pscustomobject]@{ Topic = $Topic; Payload = $Payload; Retain = [bool]$Retain })
}

$headers = @{ Authorization = '******' }
$desk = @{ Slug = 'dswett_home'; Machine = 'DSWETT-HOME' }
$book = @{ Slug = 'dans_mbp'; Machine = 'Dans-MBP' }

Publish-CopilotMqttUsage -Records @($copilot, $claude, $codex) -Slug $desk.Slug -MachineName $desk.Machine -Headers $headers
# The laptop is signed in to the same Copilot account and was last read a week ago,
# with a figure from before most of the month's spend.
$stale = Get-BridgeCopilotAllowance -ConfigPath $copilotConfig -CachePath '' `
    -ResolveToken { 'stub' } -Fetch { New-CopilotBody -Remaining 1400000 }
$stale.measured_at = '2026-09-30T00:00:00.0000000+00:00'
Publish-CopilotMqttUsage -Records @($stale) -Slug $book.Slug -MachineName $book.Machine -Headers $headers

Test-That 'every usage publish is retained, so a machine switched off still reports' {
    @($script:Published | Where-Object { $_.Topic -match '/usage[_/]' -and -not $_.Retain }).Count -eq 0
}
Test-That 'each client gets a sensor of its own, so each gets its own history' {
    $node = "homeassistant/sensor/agent_bridge_$($desk.Slug)"
    # The client is held in a named variable: $_ inside the Where-Object below is the
    # message being filtered, not the client being looked for.
    $counts = @('copilot', 'claude', 'codex') | ForEach-Object {
        $wanted = "$node/usage_$_/config"
        @($script:Published | Where-Object { $_.Topic -ceq $wanted }).Count
    }
    @($counts | Where-Object { $_ -ne 1 }).Count -eq 0
} "counts=$(@('copilot', 'claude', 'codex') | ForEach-Object { $wanted = "homeassistant/sensor/agent_bridge_$($desk.Slug)/usage_$_/config"; @($script:Published | Where-Object { $_.Topic -ceq $wanted }).Count })"
Test-That 'the state is the percentage, which is the part worth graphing' {
    $topic = "copilot/cli/machine/$($desk.Slug)/usage/copilot/state"
    ([string](@($script:Published | Where-Object { $_.Topic -ceq $topic })[-1].Payload)) -ceq '67.2'
}
Test-That 'and it is declared as a percentage measurement' {
    $topic = "homeassistant/sensor/agent_bridge_$($desk.Slug)/usage_copilot/config"
    $config = (@($script:Published | Where-Object { $_.Topic -ceq $topic })[-1].Payload) | ConvertFrom-Json
    $config.unit_of_measurement -ceq '%' -and $config.state_class -ceq 'measurement' -and
        $config.object_id -ceq "agent_bridge_$($desk.Slug)_usage_copilot"
}

$unknown = Get-BridgeCopilotAllowance -ConfigPath $copilotConfig -CachePath '' -ResolveToken { '' } -Fetch { throw 'no token' }
$script:Published.Clear()
Publish-CopilotMqttUsage -Records @($unknown) -Slug $desk.Slug -MachineName $desk.Machine -Headers $headers
Test-That 'a client that could not be read publishes unknown, never a zero that reads as unused' {
    $topic = "copilot/cli/machine/$($desk.Slug)/usage/copilot/state"
    ([string](@($script:Published | Where-Object { $_.Topic -ceq $topic })[-1].Payload)) -ceq 'unknown'
}

Test-That 'the topics a forget has to clear name every sensor that was published' {
    $topics = @(Get-CopilotMqttUsageTopics -Slug $desk.Slug)
    $published = @($script:Published | ForEach-Object { $_.Topic } | Sort-Object -Unique)
    @($published | Where-Object { $_ -notin $topics }).Count -eq 0
}

# --- 5. the dashboard, the card, and the wire between them ------------------------

Write-Host ''
Write-Host '--- the dashboard the daemon generates ---'

$script:Published.Clear()
Publish-CopilotMqttUsage -Records @($copilot, $claude, $codex) -Slug $desk.Slug -MachineName $desk.Machine -Headers $headers
Publish-CopilotMqttUsage -Records @($stale) -Slug $book.Slug -MachineName $book.Machine -Headers $headers

function Get-PublishedHaStates {
    <# The entity states Home Assistant would hold, by the rules it applies to these. #>
    $states = @{}
    foreach ($message in $script:Published) {
        if ($message.Topic -notmatch '^homeassistant/([a-z_]+)/[^/]+/[^/]+/config$') { continue }
        $domain = $Matches[1]
        if ([string]::IsNullOrEmpty($message.Payload)) { continue }
        $config = $message.Payload | ConvertFrom-Json
        if (-not $config.PSObject.Properties['object_id']) { continue }
        $raw = @($script:Published | Where-Object { $_.Topic -ceq [string]$config.state_topic } | Select-Object -Last 1)
        $attributes = @{}
        if ($config.PSObject.Properties['json_attributes_topic']) {
            $attrRaw = @($script:Published | Where-Object { $_.Topic -ceq [string]$config.json_attributes_topic } | Select-Object -Last 1)
            if ($attrRaw.Count -gt 0 -and $attrRaw[0].Payload) {
                $body = $attrRaw[0].Payload | ConvertFrom-Json
                foreach ($property in $body.PSObject.Properties) { $attributes[$property.Name] = $property.Value }
            }
        }
        $states["$domain.$($config.object_id)"] = @{
            state = if ($raw.Count -eq 0) { 'unavailable' } else { [string]$raw[0].Payload }
            attributes = $attributes
        }
    }
    $states
}
$haStates = Get-PublishedHaStates

$script:SavedConfig = $null
. (Join-Path $PSScriptRoot 'test-dashboard.ps1') -PublicationFixturesOnly
function Invoke-CopilotHaWebSocket {
    param([Parameter(Mandatory)][object[]]$Commands)
    Invoke-TestPublicationCommands -Commands $Commands
}
Initialize-TestPublicationStore
Initialize-TestPublicationAuthority

$cardVersion = Get-BridgeReplyCardFileVersion -SourcePath (Join-Path $PSScriptRoot '..\frontend\agent-bridge-reply-card.js')
$machines = @(
    [pscustomobject]@{ Slug = $desk.Slug; Machine = $desk.Machine; Online = $true; IncludeProfile = $false; IncludeResume = $true; IncludeAgent = $true; IncludeDetailed = $true; SessionNodes = @() }
    [pscustomobject]@{ Slug = $book.Slug; Machine = $book.Machine; Online = $false; IncludeProfile = $false; IncludeResume = $true; IncludeAgent = $false; IncludeDetailed = $false; SessionNodes = @() }
)

function Get-GeneratedDashboard {
    param([string]$Version)
    Set-TestPublicationCardUrl -Url "/local/agent-bridge-reply-card.js?v=$Version"
    Save-CopilotSessionDashboard -Sessions @() -Machines $machines `
        -ReplyCardUrl "/local/agent-bridge-reply-card.js?v=$Version"
    $script:SavedConfig | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
}

$current = Get-GeneratedDashboard -Version $cardVersion
$usageCard = @($current.views[0].cards | Where-Object { $_.type -eq 'custom:agent-bridge-usage-card' })[0]

Test-That 'the card file is at least the version the gate asks for' {
    [version]$cardVersion -ge [version]'1.25.0'
} "card=$cardVersion"
Test-That 'the generated view carries a usage card' { $null -ne $usageCard }
Test-That 'and it is the first card on the dashboard' {
    $current.views[0].cards[0].type -ceq 'custom:agent-bridge-usage-card'
} "first=$($current.views[0].cards[0].type)"
Test-That 'it is handed every machine, because an allowance is not per machine' {
    @($usageCard.entities | Where-Object { $_ -like "*_$($book.Slug)_*" }).Count -gt 0 -and
    @($usageCard.entities | Where-Object { $_ -like "*_$($desk.Slug)_*" }).Count -gt 0
}
Test-That 'and every entity it reads is one the publisher really declares' {
    $declared = @($haStates.Keys)
    $asked = @($usageCard.entities | Where-Object { $_ -like '*usage_copilot' })
    @($asked | Where-Object { $_ -notin $declared }).Count -eq 0
} "asked=[$(@($usageCard.entities) -join ',')]"

$older = Get-GeneratedDashboard -Version '1.21.1'
Test-That 'a browser serving the older card gets no card it would silently empty' {
    @($older.views[0].cards | Where-Object { $_.type -eq 'custom:agent-bridge-usage-card' }).Count -eq 0
}
Test-That 'and gets a standard card in its place instead of nothing at all' {
    $fallbackCard = @($older.views[0].cards | Where-Object {
        $_.type -eq 'conditional' -and $_.card -and $_.card.title -eq 'Agent usage'
    })[0]
    $null -ne $fallbackCard -and @($fallbackCard.card.entities).Count -gt 0
}
Test-That 'whose rows are row objects, the shape every other generated card uses' {
    $fallbackCard = @($older.views[0].cards | Where-Object {
        $_.type -eq 'conditional' -and $_.card -and $_.card.title -eq 'Agent usage'
    })[0]
    @($fallbackCard.card.entities | Where-Object { -not $_.PSObject.Properties['entity'] }).Count -eq 0
}
Test-That 'but it does not displace the session controls on a browser still serving the old one' {
    $older.views[0].cards[0].type -ceq 'custom:agent-bridge-status-card'
} "first=$($older.views[0].cards[0].type)"

Write-Host ''
Write-Host '--- the real card, on that config and those states ---'

$nodeExe = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $nodeExe) {
    Write-Host '  FAIL  node is required to run the card' -ForegroundColor Red
    exit 1
}
$driver = Join-Path $PSScriptRoot '..\frontend\test\drive-usage-card.js'
$job = @{ config = $usageCard; states = $haStates; open = $true } | ConvertTo-Json -Depth 40
$drawn = ($job | & $nodeExe.Source $driver) | ConvertFrom-Json -Depth 40

Test-That 'the card draws a group for each client that reported' {
    @($drawn.groups).Count -eq 3
} "groups=$(@($drawn.groups | ForEach-Object { $_.name }) -join ',')"
Test-That 'one account read by two machines is drawn once, not twice' {
    @($drawn.groups | Where-Object { $_.name -eq 'GitHub Copilot' }).Count -eq 1
}
Test-That 'and the figure kept is the fresher machine, not the one left shut' {
    (@($drawn.groups | Where-Object { $_.name -eq 'GitHub Copilot' })[0]).windows[0].percent -ceq '67.2%'
} "drew=$((@($drawn.groups | Where-Object { $_.name -eq 'GitHub Copilot' })[0]).windows[0].percent)"
Test-That 'the bar is filled to the percentage used' {
    (@($drawn.groups | Where-Object { $_.name -eq 'GitHub Copilot' })[0]).windows[0].width -ceq '67.2%'
}
Test-That 'with the pace mark where an even spend would have reached by now' {
    $pace = (@($drawn.groups | Where-Object { $_.name -eq 'GitHub Copilot' })[0]).windows[0].pace
    $pace -match '^\d+(\.\d+)?%$' -and [double]($pace -replace '%', '') -lt 67.2
} "pace=$((@($drawn.groups | Where-Object { $_.name -eq 'GitHub Copilot' })[0]).windows[0].pace)"
# The bug this guards: the mark was reported as "what are the white lines on the
# bars". A marker that has to be asked about explains nothing, and a dashboard read
# on a phone cannot be hovered for a tooltip.
Test-That 'and a line naming the mark, so it does not have to be asked about' {
    (@($drawn.groups | Where-Object { $_.name -eq 'GitHub Copilot' })[0]).windows[0].paceMark -match 'even pace \d+%'
} "mark=$((@($drawn.groups | Where-Object { $_.name -eq 'GitHub Copilot' })[0]).windows[0].paceMark)"
Test-That 'a spend well ahead of the clock says so, and is coloured for it' {
    $w = (@($drawn.groups | Where-Object { $_.name -eq 'GitHub Copilot' })[0]).windows[0]
    $w.verdict -match 'ahead of pace' -and $w.ahead
} "verdict=$((@($drawn.groups | Where-Object { $_.name -eq 'GitHub Copilot' })[0]).windows[0].verdict)"
Test-That 'while one running behind the clock says so, without colour' {
    $w = (@($drawn.groups | Where-Object { $_.name -eq 'Claude Code' })[0]).windows |
        Where-Object { $_.label -eq 'Weekly' } | Select-Object -First 1
    $w.verdict -match 'under pace' -and -not $w.ahead
} "verdict=$(((@($drawn.groups | Where-Object { $_.name -eq 'Claude Code' })[0]).windows | Where-Object { $_.label -eq 'Weekly' } | Select-Object -First 1).verdict)"
Test-That 'and a window with no known start shows no pace line at all' {
    $w = (@($drawn.groups | Where-Object { $_.name -eq 'Codex' })[0]).windows[0]
    [string]::IsNullOrEmpty($w.paceMark) -and [string]::IsNullOrEmpty($w.verdict)
}
Test-That 'the raw credits are printed under the bar' {
    (@($drawn.groups | Where-Object { $_.name -eq 'GitHub Copilot' })[0]).windows[0].detail -match '1,007,922 / 1,500,000 AIC'
}
Test-That 'the client closest to running out is listed first' {
    $drawn.groups[0].name -ceq 'GitHub Copilot'
}
Test-That 'the summary names every client and its percentage' {
    $drawn.summary -match 'GitHub Copilot 67' -and $drawn.summary -match 'Claude Code 14' -and $drawn.summary -match 'Codex 12'
} "summary=$($drawn.summary)"
Test-That 'a reading old enough to be a memory is marked as one' {
    (@($drawn.groups | Where-Object { $_.name -eq 'Codex' })[0]).stale
}
Test-That 'while a reading taken moments ago is not' {
    -not (@($drawn.groups | Where-Object { $_.name -eq 'GitHub Copilot' })[0]).stale
}
Test-That 'Codex draws both of its windows' {
    @((@($drawn.groups | Where-Object { $_.name -eq 'Codex' })[0]).windows).Count -eq 2
}

# A quota nearly gone has to look different, because the number alone is what nobody
# reads in time.
$hot = $haStates.Clone()
$hotEntity = "sensor.agent_bridge_$($desk.Slug)_usage_copilot"
$hot[$hotEntity] = @{
    state = '93.4'
    attributes = @{
        client = 'copilot'; label = 'GitHub Copilot'; account = 'work_account'; plan = 'enterprise'
        source = 'api'; error = ''; machine = $desk.Machine
        measured_at = [DateTimeOffset]::UtcNow.ToString('o')
        windows = @(@{ key = 'plan'; label = 'Plan'; percent = 93.4; used = 1401000; limit = 1500000; unit = 'AIC'; elapsed = 20 })
    }
}
$hotJob = @{ config = $usageCard; states = $hot; open = $true } | ConvertTo-Json -Depth 40
$hotDrawn = ($hotJob | & $nodeExe.Source $driver) | ConvertFrom-Json -Depth 40
Test-That 'an allowance nearly gone colours its bar as critical' {
    (@($hotDrawn.groups | Where-Object { $_.name -eq 'GitHub Copilot' })[0]).windows[0].severity -ceq 'crit'
}
Test-That 'and says so on the line you see without opening the card' {
    $hotDrawn.severity -ceq 'crit'
}

$closed = @{ config = $usageCard; states = $haStates; open = $false } | ConvertTo-Json -Depth 40
$closedDrawn = ($closed | & $nodeExe.Source $driver) | ConvertFrom-Json -Depth 40
Test-That 'folded shut, the card still summarises rather than going blank' {
    $closedDrawn.hidden -and $closedDrawn.summary -match 'GitHub Copilot'
}

# --- 6. the timer the daemon runs it on -------------------------------------------

Write-Host ''
Write-Host '--- how often the daemon asks ---'

# Stubbed after everything above has used the real ones. Every publish is retained, so
# a poll that found nothing new must stay off the bus entirely.
$script:Settings = @{}
function Get-BridgeSetting { param([string]$Name, $Default) if ($script:Settings.ContainsKey($Name)) { $script:Settings[$Name] } else { $Default } }
function Get-BridgeSelectedClients { , @('copilot', 'mcp') }
function Write-DaemonLog { param([string]$Message) }
$script:Collected = 0
$script:Asked = @()
function Get-BridgeAgentAllowance {
    param([AllowEmptyCollection()][string[]]$Clients = @())
    $script:Collected++
    $script:Asked = @($Clients)
    @($copilot)
}
$script:UsagePublishes = 0
function Publish-CopilotMqttUsage {
    param([object[]]$Records, [string]$Slug, [string]$MachineName, [hashtable]$Headers)
    $script:UsagePublishes++
}
$script:IdForcings = 0
function Set-CopilotMqttUsageEntityIds {
    param([string]$Slug, [AllowEmptyCollection()][string[]]$Clients = @())
    $script:IdForcings++
    $false
}

$script:DaemonUsageCheckedAt = [DateTimeOffset]::MinValue
$script:DaemonUsageSignature = ''
$script:DaemonUsageEntityIds = ''
$clock = [DateTimeOffset]::Parse('2026-10-07T12:00:00Z')

Test-That 'the first pass collects and publishes' {
    (Sync-DaemonUsage -Headers $headers -Now $clock) -and $script:UsagePublishes -eq 1
}
Test-That 'and asks only for clients that meter anything' {
    $script:Asked -join ',' -ceq 'copilot'
} "asked=$($script:Asked -join ',')"
Test-That 'a pass moments later does not ask again' {
    (Sync-DaemonUsage -Headers $headers -Now $clock.AddSeconds(30)) -eq $false -and $script:Collected -eq 1
}
Test-That 'once the interval is up it asks again' {
    (Sync-DaemonUsage -Headers $headers -Now $clock.AddSeconds(200)) | Out-Null
    $script:Collected -eq 2
}
Test-That 'but an unchanged reading is not republished over a retained topic' {
    $script:UsagePublishes -eq 1
} "publishes=$($script:UsagePublishes)"
Test-That 'while a reading that moved is' {
    $moved = Get-BridgeCopilotAllowance -ConfigPath $copilotConfig -CachePath '' -ResolveToken { 'stub' } `
        -Fetch { New-CopilotBody -Remaining 400000 }
    function Get-BridgeAgentAllowance { param([AllowEmptyCollection()][string[]]$Clients = @()) @($moved) }
    [void](Sync-DaemonUsage -Headers $headers -Now $clock.AddSeconds(400))
    $script:UsagePublishes -eq 2
} "publishes=$($script:UsagePublishes)"
Test-That 'the entity ids are forced once, not on every reading that moves' {
    $script:IdForcings -eq 1
} "forcings=$($script:IdForcings)"
Test-That 'and turning it off stops the collecting, not just the showing' {
    $script:Settings['usage.publish'] = $false
    $before = $script:Collected
    (Sync-DaemonUsage -Headers $headers -Now $clock.AddHours(1)) -eq $false -and $script:Collected -eq $before
}

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All usage checks passed' -ForegroundColor Green
