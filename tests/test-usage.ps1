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

# The real backoff is hundreds of milliseconds per attempt, which is right against a
# vendor and absurd against a scriptblock that throws instantly. Every deliberately
# failing fetch below would otherwise pay for it three times over.
$script:BridgeUsageConfig.RetryDelayMs = 1

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
#
# The reset date moves with the clock for the same reason. The window is the month
# ending there, and the card's pace verdict compares the spend with how much of that
# month has gone - so a fixed 2026-11-01 read as "ahead of pace" early in October and
# "on pace" from the 18th, failing every build from then on. Twenty days out keeps the
# window between 28% and 39% gone, whatever today is, which 67.2% is well ahead of.
$copilotResetDay = [DateTimeOffset]::new([DateTime]::UtcNow.Date.AddDays(20), [TimeSpan]::Zero)
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
  "quota_reset_date_utc": "$($copilotResetDay.ToString('yyyy-MM-dd'))T00:00:00.000Z",
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
    $copilot.windows[0].resets_at -match "^$($copilotResetDay.ToString('yyyy-MM-dd'))T00:00:00"
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

Write-Host '--- a read that fails once is not a failed reading ---'
# Measured on DSWETT-HOME on 2026-10-07: api.github.com completed 6 of 14 handshakes
# while two other hosts managed 14 of 14 from the same machine in the same seconds.
# A single-shot read reported a failure most of the time with a correct figure one
# retry away, so the card carried a permanent red line under a true number.
$script:FlakyCalls = 0
$flaky = Get-BridgeCopilotAllowance -ConfigPath $copilotConfig -CachePath $copilotCache -ResolveToken { 'stub' } -Fetch {
    $script:FlakyCalls++
    if ($script:FlakyCalls -lt 3) { throw 'The SSL connection could not be established, see inner exception.' }
    New-CopilotBody
}
Test-That 'a read that fails twice and then succeeds is a live reading, not a cached one' {
    $flaky.source -ceq 'api' -and -not $flaky.error
} "source=$($flaky.source) error=$($flaky.error)"
Test-That 'and it stops retrying the moment it has an answer' {
    $script:FlakyCalls -eq 3
} "calls=$($script:FlakyCalls)"

$script:AlwaysCalls = 0
$null = Get-BridgeCopilotAllowance -ConfigPath $copilotConfig -CachePath $copilotCache -ResolveToken { 'stub' } -Fetch {
    $script:AlwaysCalls++
    throw 'the network is down'
}
Test-That 'a read that never succeeds gives up rather than retrying forever' {
    $script:AlwaysCalls -eq $script:BridgeUsageConfig.RequestAttempts
} "calls=$($script:AlwaysCalls) attempts=$($script:BridgeUsageConfig.RequestAttempts)"

$chained = Get-BridgeCopilotAllowance -ConfigPath $copilotConfig -CachePath '' -ResolveToken { 'stub' } -Fetch {
    throw [Net.Http.HttpRequestException]::new(
        'The SSL connection could not be established, see inner exception.',
        [IO.IOException]::new('An existing connection was forcibly closed by the remote host.'))
}
Test-That 'the reported reason is the cause itself, not a pointer at one' {
    $chained.error -match 'forcibly closed' -and $chained.error -notmatch 'see inner exception'
} "error=$($chained.error)"

$script:GuardCalls = 0
$guardPropagated = $false
try {
    $null = Get-BridgeCopilotAllowance -ConfigPath $copilotConfig -CachePath '' -ResolveToken { 'stub' } -Fetch {
        $script:GuardCalls++
        $violation = [InvalidOperationException]::new('the offline guard refused this call')
        $violation.Data['BridgeTestNetworkBlocked'] = $true
        throw $violation
    }
}
catch { $guardPropagated = $true }
Test-That 'an offline-guard violation propagates instead of becoming a connection failure' {
    $guardPropagated
}
Test-That 'and is never retried, which would report one violation as three' {
    $script:GuardCalls -eq 1
} "calls=$($script:GuardCalls)"

$script:RefusedCalls = 0
$refused = $null
try {
    $null = Invoke-BridgeUsageAttempt -Operation {
        $script:RefusedCalls++
        throw 'Response status code does not indicate success: 401 (Unauthorized).'
    }
}
catch { $refused = $_ }
Test-That 'a refusal is an answer, reported at once rather than retried into the same answer' {
    $script:RefusedCalls -eq 1 -and $null -ne $refused
} "calls=$($script:RefusedCalls)"

$script:ThrottledCalls = 0
try {
    $null = Invoke-BridgeUsageAttempt -Operation {
        $script:ThrottledCalls++
        throw 'Response status code does not indicate success: 429 (Too Many Requests).'
    }
}
catch { }
Test-That 'but being asked to slow down is about timing, so that one is retried' {
    $script:ThrottledCalls -eq $script:BridgeUsageConfig.RequestAttempts
} "calls=$($script:ThrottledCalls)"

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

# Where Claude Code records the account it is signed in as. The same object holds an
# email address and an organisation and the file a great deal besides; every collector
# below is given this path rather than left to find the real one under $HOME.
$claudeUuid = '0f6a5c1e-7d2b-4c8e-9a31-5b7e2d4f8a10'
$claudeOrganisation = '3b9d4e72-a1c6-4f58-b0e3-6c2d7a8f9e14'
$claudeAccountPath = Join-Path $root 'claude-account.json'
Set-Content -LiteralPath $claudeAccountPath -Encoding UTF8 -Value @"
{ "numStartups": 12, "oauthAccount": { "accountUuid": "$claudeUuid", "organizationUuid": "$claudeOrganisation", "emailAddress": "someone@example.test", "organizationName": "Example Org", "ccOnboardingFlags": { "seen": true } }, "projects": {} }
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

$claude = Get-BridgeClaudeAllowance -StatePath $claudeStatePath -AccountPath $claudeAccountPath -Fetch { $claudeBody }

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
    $result = Get-BridgeClaudeAllowance -StatePath $expired -AccountPath $claudeAccountPath -Fetch { $script:ClaudeFetchCalled = $true; $claudeBody }
    $null -eq $result -and -not $called
}
Test-That 'and a token refused as it expires is not reported as a fault' {
    $null -eq (Get-BridgeClaudeAllowance -StatePath $claudeStatePath -AccountPath $claudeAccountPath -Fetch { throw 'Response status code does not indicate success: 401 (Unauthorized).' })
}
Test-That 'while a real failure still is' {
    $broken = Get-BridgeClaudeAllowance -StatePath $claudeStatePath -AccountPath $claudeAccountPath -Fetch { throw 'the name resolution failed' }
    $null -eq $broken.percent -and $broken.error -match 'name resolution'
}
Test-That 'and a machine with no Claude credential reports nothing' {
    $null -eq (Get-BridgeClaudeAllowance -StatePath (Join-Path $root 'absent.json') -AccountPath $claudeAccountPath)
}

Write-Host ''
Write-Host '--- Claude, and whose allowance it is ---'

# Neither the credential nor the usage body names an account, so a Claude record used
# to be the same account as every other Claude record. The card keeps one row per
# account, which drew two machines signed in to two different Claude accounts as one
# row - whichever had read last - and left the other account's figure nowhere at all.
$claudeId = Get-BridgeClaudeAccountId -Path $claudeAccountPath
Test-That 'the account is told by a short opaque id, and the record carries it' {
    $claudeId -cmatch '^[0-9a-f]{12}$' -and $claude.account_id -ceq $claudeId
} "id=$claudeId; record=$($claude.account_id)"
Test-That 'a failed read says whose it was too, so it is not a second row beside the reading it failed to refresh' {
    $broken = Get-BridgeClaudeAllowance -StatePath $claudeStatePath -AccountPath $claudeAccountPath -Fetch { throw 'the name resolution failed' }
    $broken.account_id -ceq $claudeId
}
# Anything thrown outside the fetch's own handling lands in the collector loop's catch,
# a credentials file half written while Claude Code refreshes its token, say. That
# record must name the account as well, or it is a second row beside the reading.
Test-That 'and so does a collector that threw outright' {
    function Get-BridgeClaudeAllowance { throw 'the credentials file was half written' }
    function Get-BridgeClaudeAccountId { 'a1b2c3d4e5f6' }
    $thrown = @(Get-BridgeAgentAllowance -Clients @('claude'))
    $thrown.Count -eq 1 -and $thrown[0].account_id -ceq 'a1b2c3d4e5f6' -and $thrown[0].error -match 'half written'
}
Test-That 'while another client that threw is not given an id it has no use for' {
    function Get-BridgeCopilotAllowance { throw 'the config could not be read' }
    function Get-BridgeClaudeAccountId { throw 'must not be asked about for Copilot' }
    $thrown = @(Get-BridgeAgentAllowance -Clients @('copilot'))
    $thrown.Count -eq 1 -and $thrown[0].account_id -ceq '' -and $thrown[0].error -match 'config could not be read'
}
Test-That 'the id is not the identifier it stands for' {
    $claudeId -notmatch '0f6a5c1e|7d2b|4c8e|9a31|3b9d4e72|a1c6|4f58|b0e3'
}
# Pinned, because the card compares ids from different machines: two bridge versions
# that derived it differently would split one allowance into two rows. The values were
# taken from SHA256.HashData over "claude:<account>:<organisation>", so they also prove
# the runtime-compatible hashing used now produces exactly what the first version did.
Test-That 'the id is a fixed function of the account and organisation, the same on every machine' {
    $claudeId -ceq '95adb0b680fe' -and (Get-BridgeClaudeAccountId -Path $claudeAccountPath) -ceq '95adb0b680fe'
} "id=$claudeId"
Test-That 'and nothing else from that file reaches the record: not the email, not the organisation' {
    $text = $claude | ConvertTo-Json -Depth 8 -Compress
    $text -notmatch 'someone@example\.test' -and $text -notmatch 'Example Org' -and
        $text -notmatch [regex]::Escape($claudeUuid) -and $text -notmatch [regex]::Escape($claudeOrganisation)
}
Test-That 'one allowance reads as one id however the file spells it, and wherever the file is' {
    $respelled = Join-Path $root 'claude-account-respelled.json'
    Set-Content -LiteralPath $respelled -Encoding UTF8 -Value "{ `"oauthAccount`": { `"organizationUuid`": `" $($claudeOrganisation.ToUpperInvariant())`", `"accountUuid`": `"  $($claudeUuid.ToUpperInvariant()) `" } }"
    (Get-BridgeClaudeAccountId -Path $respelled) -ceq $claudeId
}
Test-That 'and another account is another id' {
    $elsewhere = Join-Path $root 'claude-account-other.json'
    Set-Content -LiteralPath $elsewhere -Encoding UTF8 -Value "{ `"oauthAccount`": { `"accountUuid`": `"9f8e7d6c-5b4a-4c3d-8e2f-1a0b9c8d7e6f`", `"organizationUuid`": `"$claudeOrganisation`" } }"
    $otherId = Get-BridgeClaudeAccountId -Path $elsewhere
    $otherId -cmatch '^[0-9a-f]{12}$' -and $otherId -cne $claudeId
}

# One person can sit in more than one organisation - a personal plan on one machine, a
# team seat on another - and each has an allowance of its own under the same account
# UUID. Keyed on the account alone they would still be drawn as one row.
$claudeBare = Join-Path $root 'claude-account-bare.json'
Set-Content -LiteralPath $claudeBare -Encoding UTF8 -Value "{ `"oauthAccount`": { `"accountUuid`": `"$claudeUuid`" } }"
$claudeInTeam = Join-Path $root 'claude-account-team.json'
Set-Content -LiteralPath $claudeInTeam -Encoding UTF8 -Value "{ `"oauthAccount`": { `"accountUuid`": `"$claudeUuid`", `"organizationUuid`": `"5d1e8a3c-72b4-4096-8cf1-e03a9b6d2714`" } }"
$claudeOddOrganisation = Join-Path $root 'claude-account-odd-organisation.json'
Set-Content -LiteralPath $claudeOddOrganisation -Encoding UTF8 -Value "{ `"oauthAccount`": { `"accountUuid`": `"$claudeUuid`", `"organizationUuid`": 7 } }"
Test-That 'the same account in another organisation is another allowance, so another id' {
    $teamId = Get-BridgeClaudeAccountId -Path $claudeInTeam
    $teamId -cmatch '^[0-9a-f]{12}$' -and $teamId -cne $claudeId
}
Test-That 'an organisation that is missing still leaves an id, from the account alone' {
    $bareId = Get-BridgeClaudeAccountId -Path $claudeBare
    $bareId -cmatch '^[0-9a-f]{12}$' -and $bareId -cne $claudeId -and $bareId -ceq '070ee00faa64'
} "id=$(Get-BridgeClaudeAccountId -Path $claudeBare)"
Test-That 'and one that is not text is ignored rather than voiding the account' {
    (Get-BridgeClaudeAccountId -Path $claudeOddOrganisation) -ceq (Get-BridgeClaudeAccountId -Path $claudeBare)
}

# Whatever cannot be read is no id, not a guess: a wrong id would put two accounts in
# one row, which is the very thing this exists to prevent.
$noAccount = [ordered]@{
    'a file signed out of Claude'         = '{ "oauthAccount": null }'
    'a file with no account in it'        = '{ "numStartups": 3 }'
    'a blank identifier'                  = '{ "oauthAccount": { "accountUuid": "  " } }'
    'a number where the identifier goes'  = '{ "oauthAccount": { "accountUuid": 12 } }'
    'a string where the account goes'     = '{ "oauthAccount": "x" }'
    'a file that is not JSON'             = 'this is not json'
    'a list where the object should be'   = '[1, 2]'
}
foreach ($case in $noAccount.Keys) {
    $unreadable = Join-Path $root "claude-account-$([guid]::NewGuid().ToString('N').Substring(0, 6)).json"
    Set-Content -LiteralPath $unreadable -Encoding UTF8 -Value $noAccount[$case]
    Test-That "$case yields no id, so the record goes ungrouped as it always did" {
        (Get-BridgeClaudeAccountId -Path $unreadable) -ceq ''
    }
}
Test-That 'a machine with no such file at all yields none either' {
    (Get-BridgeClaudeAccountId -Path (Join-Path $root 'nowhere.json')) -ceq '' -and
        (Get-BridgeClaudeAccountId -Path '') -ceq ''
}
Test-That 'and a file too large to be the small state document it should be is not read for one' {
    $limit = $script:BridgeUsageConfig.MaxStateBytes
    try {
        $script:BridgeUsageConfig.MaxStateBytes = 20
        (Get-BridgeClaudeAccountId -Path $claudeAccountPath) -ceq ''
    }
    finally { $script:BridgeUsageConfig.MaxStateBytes = $limit }
}
Test-That 'a machine whose account cannot be told still reports its allowance, only ungrouped' {
    $ungrouped = Get-BridgeClaudeAllowance -StatePath $claudeStatePath -AccountPath (Join-Path $root 'nowhere.json') -Fetch { $claudeBody }
    $ungrouped.windows.Count -eq 2 -and $ungrouped.Contains('account_id') -and $ungrouped.account_id -ceq ''
}
Test-That 'every record has an account_id, blank where the client names its own account' {
    (New-BridgeUsageRecord -Client 'copilot' -Account 'work_account').Contains('account_id') -and
        (New-BridgeUsageRecord -Client 'copilot' -Account 'work_account').account_id -ceq ''
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
Test-That 'the account id rides in the attributes beside the account, for the card to group on' {
    $topic = "copilot/cli/machine/$($desk.Slug)/usage/claude/attr"
    $attributes = (@($script:Published | Where-Object { $_.Topic -ceq $topic })[-1].Payload) | ConvertFrom-Json
    $attributes.account_id -ceq $claudeId
} "id=$claudeId"
Test-That 'and is blank rather than missing for a client that names its own account' {
    $topic = "copilot/cli/machine/$($desk.Slug)/usage/copilot/attr"
    $attributes = (@($script:Published | Where-Object { $_.Topic -ceq $topic })[-1].Payload) | ConvertFrom-Json
    $null -ne $attributes.PSObject.Properties['account_id'] -and $attributes.account_id -ceq '' -and
        $attributes.account -ceq 'work_account'
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
# Nothing tells the dashboard which further Copilot logins a machine reports (#200), and
# the card skips an entity that does not exist, so it is handed every numbered sensor.
Test-That 'and the numbered sensors further Copilot logins go on, for every machine alike' {
    $missing = @(foreach ($slug in $desk.Slug, $book.Slug) {
            foreach ($n in 2, 3, 4) {
                if (@($usageCard.entities | Where-Object { $_ -like "*_${slug}_usage_copilot_$n" }).Count -ne 1) { "$slug/$n" }
            }
        })
    $missing.Count -eq 0
} "entities=[$(@($usageCard.entities) -join ',')]"

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
Test-That 'and which leaves the numbered sensors out, an entities card drawing each one missing as an error' {
    $fallbackCard = @($older.views[0].cards | Where-Object {
        $_.type -eq 'conditional' -and $_.card -and $_.card.title -eq 'Agent usage'
    })[0]
    @($fallbackCard.card.entities | Where-Object { $_.entity -match 'usage_copilot_\d' }).Count -eq 0
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

# Claude names no account, so what tells its accounts apart is the id the daemon chose
# to publish. Two machines are published through the real publisher and drawn by the
# real card; nothing between them knows what an account is except that one attribute.
$secondAccountPath = Join-Path $root 'claude-account-second.json'
Set-Content -LiteralPath $secondAccountPath -Encoding UTF8 -Value '{ "oauthAccount": { "accountUuid": "9f8e7d6c-5b4a-4c3d-8e2f-1a0b9c8d7e6f" } }'
function Get-ClaudeRowsDrawn {
    param([string]$SecondMachineAccountPath)
    $second = Get-BridgeClaudeAllowance -StatePath $claudeStatePath -AccountPath $SecondMachineAccountPath -Fetch { $claudeBody }
    $script:Published.Clear()
    Publish-CopilotMqttUsage -Records @($claude) -Slug $desk.Slug -MachineName $desk.Machine -Headers $headers
    Publish-CopilotMqttUsage -Records @($second) -Slug $book.Slug -MachineName $book.Machine -Headers $headers
    $claudeOnly = @{
        type = 'custom:agent-bridge-usage-card'; title = 'Agent usage'
        entities = @("sensor.agent_bridge_$($desk.Slug)_usage_claude", "sensor.agent_bridge_$($book.Slug)_usage_claude")
    }
    $request = @{ config = $claudeOnly; states = (Get-PublishedHaStates); open = $true } | ConvertTo-Json -Depth 40
    ($request | & $nodeExe.Source $driver) | ConvertFrom-Json -Depth 40
}
$oneClaude = Get-ClaudeRowsDrawn -SecondMachineAccountPath $claudeAccountPath
$twoClaudes = Get-ClaudeRowsDrawn -SecondMachineAccountPath $secondAccountPath
Test-That 'one Claude account on two machines is drawn once' {
    @($oneClaude.groups | Where-Object { $_.name -eq 'Claude Code' }).Count -eq 1
} "rows=$(@($oneClaude.groups).Count)"
Test-That 'while two Claude accounts on two machines are drawn as two rows, which used to be one' {
    @($twoClaudes.groups | Where-Object { $_.name -eq 'Claude Code' }).Count -eq 2
} "rows=$(@($twoClaudes.groups).Count)"
Test-That 'and told apart on the card by a few characters of the id each machine published' {
    $shown = @($twoClaudes.groups | ForEach-Object { $_.account })
    @($shown | Where-Object { $_ -match '^#[0-9a-f]{4} .{1,3} pro$' }).Count -eq 2 -and @($shown | Select-Object -Unique).Count -eq 2
} "shown=$(@($twoClaudes.groups | ForEach-Object { $_.account }) -join ' | ')"

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
#
# The real publisher is kept first: section 6c builds the retained sensors a peer
# machine leaves behind with it, so renaming an attribute there fails a check here
# rather than quietly stopping every machine standing down for another one.
$script:RealUsagePublisher = (Get-Item function:Publish-CopilotMqttUsage).ScriptBlock
$script:RealUsageWithdrawal = (Get-Item function:Remove-CopilotMqttUsageSensors).ScriptBlock
$script:RealUsageIdForcing = (Get-Item function:Set-CopilotMqttUsageEntityIds).ScriptBlock
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
# True: every sensor was found in the registry, so the correction is done.
function Set-CopilotMqttUsageEntityIds {
    param([string]$Slug, [AllowEmptyCollection()][string[]]$Clients = @())
    $script:IdForcings++
    $true
}
# What a pass withdrew, keys by pass. A daemon's first pass that reads anything
# withdraws the numbered sensors no further login is on (#200); see section 6d.
$script:Withdrawn = [System.Collections.Generic.List[string]]::new()
$script:WithdrawThrows = $false
function Remove-CopilotMqttUsageSensors {
    param([string]$Slug, [AllowEmptyCollection()][string[]]$Keys = @(), [hashtable]$Headers)
    if ($script:WithdrawThrows) { throw 'mqtt unreachable' }
    $script:Withdrawn.Add(($Keys -join ','))
    @($Keys).Count
}

$script:DaemonUsageClients = @{}
$script:DaemonUsageEntityIds = ''
$script:DaemonUsageExtraSensors = $null
$script:DaemonUsageExtraNote = ''
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
# The same windows under another account are another reading, and the card groups on
# the account: a machine signed in to a different Claude account must republish even
# though not one percentage moved.
Test-That 'a change of account alone is a reading that moved, and is published' {
    $windows = @(Get-BridgeUsageWindow -Key 'weekly_all' -Label 'Weekly' -PercentUsed 14)
    $script:Pending = New-BridgeUsageRecord -Client 'claude' -AccountId 'a1b2c3d4e5f6' -Plan 'max' -Source 'api' -Windows $windows
    function Get-BridgeAgentAllowance { param([AllowEmptyCollection()][string[]]$Clients = @()) @($script:Pending) }
    $before = $script:UsagePublishes
    [void](Sync-DaemonUsage -Headers $headers -Now $clock.AddSeconds(600))
    [void](Sync-DaemonUsage -Headers $headers -Now $clock.AddSeconds(800))
    $afterFirst = $script:UsagePublishes
    $script:Pending = New-BridgeUsageRecord -Client 'claude' -AccountId '9f8e7d6c5b4a' -Plan 'max' -Source 'api' -Windows $windows
    [void](Sync-DaemonUsage -Headers $headers -Now $clock.AddSeconds(1000))
    $afterFirst -eq $before + 1 -and $script:UsagePublishes -eq $afterFirst + 1
} "publishes=$($script:UsagePublishes)"
Test-That 'and turning it off stops the collecting, not just the showing' {
    $script:Settings['usage.publish'] = $false
    $before = $script:Collected
    (Sync-DaemonUsage -Headers $headers -Now $clock.AddHours(1)) -eq $false -and $script:Collected -eq $before
}

# --- 6b. each client at the pace its sessions set ---------------------------------

Write-Host ''
Write-Host '--- asking quickly only while a session is open ---'

# The allowance belongs to the account, not the machine, so every machine signed in to
# it asking every two minutes was the same question from each of them, for an answer
# only the one doing the work could be changing. What these drive is Sync-DaemonUsage
# with a clock and a set of open sessions, reading back which clients it asked about
# and what it published: nothing is slept and nothing is fetched.
$settingsBefore = $script:Settings
$script:Settings = @{}
$script:Selected = @('copilot', 'claude', 'codex', 'mcp')
function Get-BridgeSelectedClients { if ($null -eq $script:Selected) { return $null }; , @($script:Selected) }
$script:Readings = @{}
$script:AskLog = [System.Collections.Generic.List[string]]::new()
$script:Published = [System.Collections.Generic.List[string]]::new()
$script:ForcedWith = [System.Collections.Generic.List[string]]::new()
$script:Logged = [System.Collections.Generic.List[string]]::new()
$script:CollectorThrows = $false
$script:PublishThrows = $false
$script:ForcingThrows = $false
$script:ForcingUnsettled = $false
function Write-DaemonLog { param([string]$Message) $script:Logged.Add($Message) }
function Get-BridgeAgentAllowance {
    param([AllowEmptyCollection()][string[]]$Clients = @())
    $script:AskLog.Add($Clients -join ',')
    if ($script:CollectorThrows) { throw 'the collector blew up' }
    foreach ($client in $Clients) { if ($script:Readings.ContainsKey($client)) { $script:Readings[$client] } }
}
function Publish-CopilotMqttUsage {
    param([object[]]$Records, [string]$Slug, [string]$MachineName, [hashtable]$Headers)
    if ($script:PublishThrows) { throw 'mqtt unreachable' }
    foreach ($record in $Records) { $script:Published.Add([string]$record.client) }
}
function Set-CopilotMqttUsageEntityIds {
    param([string]$Slug, [AllowEmptyCollection()][string[]]$Clients = @())
    $script:ForcedWith.Add($Clients -join ',')
    if ($script:ForcingThrows) { throw 'the entity registry could not be reached' }
    # Whether every sensor was in the registry; one published moments ago may not be.
    -not $script:ForcingUnsettled
}

function New-UsageReading {
    param([string]$Client, [double]$Used)
    New-BridgeUsageRecord -Client $Client -Source 'api' -Windows @(Get-BridgeUsageWindow -Key 'main' -Label 'Main' -PercentUsed $Used)
}
function Reset-UsagePacing {
    $script:DaemonUsageClients = @{}
    $script:DaemonUsageEntityIds = ''
    $script:DaemonUsageExtraSensors = $null
    $script:DaemonUsageExtraNote = ''
    $script:Withdrawn.Clear()
    $script:WithdrawThrows = $false
    $script:Settings = @{}
    $script:Selected = @('copilot', 'claude', 'codex', 'mcp')
    $script:CollectorThrows = $false
    $script:PublishThrows = $false
    $script:ForcingThrows = $false
    $script:ForcingUnsettled = $false
    $script:Logged.Clear()
    $script:Readings = @{
        copilot = New-UsageReading 'copilot' 10
        claude  = New-UsageReading 'claude' 20
        codex   = New-UsageReading 'codex' 30
    }
}
# Open sessions as discovery reports them: an entry per session, an object with a Kind
# - except the word 'unkinded', a session recorded before kinds existed, which has none.
function New-LiveSessions {
    param([string[]]$Kinds = @())
    $live = @{}
    foreach ($kind in $Kinds) {
        $id = "session-$($live.Count)"
        $live[$id] = if ($kind -eq 'unkinded') { [pscustomobject]@{ SessionId = $id } } else { [pscustomobject]@{ SessionId = $id; Kind = $kind } }
    }
    $live
}
$paceStart = [DateTimeOffset]::Parse('2026-10-07T12:00:00Z')
function Invoke-UsageAt {
    param([double]$Seconds, $Live, $States = $null)
    $script:AskLog.Clear()
    $script:Published.Clear()
    $script:ForcedWith.Clear()
    [void](Sync-DaemonUsage -Headers $headers -Live $Live -States $States -Now $paceStart.AddSeconds($Seconds))
    $script:AskLog -join ';'
}
$none = New-LiveSessions
$claudeOpen = New-LiveSessions 'claude'

Reset-UsagePacing
Test-That 'the first pass asks about every client, there being nothing yet to be quiet about' {
    $asked = Invoke-UsageAt 0 $none
    $asked -ceq 'copilot,claude,codex' -and (@($script:Published) -join ',') -ceq 'copilot,claude,codex'
}
Test-That 'with no session open anywhere, nothing is asked again for a quarter of an hour' {
    $asks = @(foreach ($second in 30, 120, 300, 600, 899) { Invoke-UsageAt $second $none })
    @($asks | Where-Object { $_ }).Count -eq 0
}
Test-That 'and then every client is' {
    (Invoke-UsageAt 900 $none) -ceq 'copilot,claude,codex'
}

Reset-UsagePacing
[void](Invoke-UsageAt 0 $none)
Test-That 'a session opening is asked about at once, and only for its own client' {
    (Invoke-UsageAt 100 $claudeOpen) -ceq 'claude'
}
Test-That 'then at the quick pace for as long as it stays open' {
    $early = Invoke-UsageAt 219 $claudeOpen
    $due = Invoke-UsageAt 220 $claudeOpen
    $early -ceq '' -and $due -ceq 'claude'
}
Test-That 'while the other clients wait for their own turn' {
    $asks = @(foreach ($second in 340, 460, 580, 700, 820) { Invoke-UsageAt $second $claudeOpen })
    ($asks -join ',') -ceq 'claude,claude,claude,claude,claude'
}
Test-That 'and an ask that finds nothing new publishes nothing' {
    $asked = Invoke-UsageAt 940 $claudeOpen
    $asked -match 'claude' -and @($script:Published).Count -eq 0
}
Test-That 'the session closing is asked about once more at once, for what it spent at the end' {
    (Invoke-UsageAt 1000 $none) -ceq 'claude'
}
Test-That 'after which that client goes back to the idle pace' {
    # Copilot and Codex were last asked at 940, so they are due a quarter of an hour on.
    $early = (Invoke-UsageAt 1899 $none) -split ','
    $due = (Invoke-UsageAt 1900 $none) -split ','
    $early -notcontains 'claude' -and $early -contains 'copilot' -and $due -contains 'claude'
}

Reset-UsagePacing
[void](Invoke-UsageAt 0 $none)
Test-That 'a session that opens inside the gap since the last ask is not asked about yet' {
    (Invoke-UsageAt 10 $claudeOpen) -ceq ''
}
Test-That 'one that closes again before the gap is up costs nothing at all' {
    $closed = Invoke-UsageAt 20 $none
    $after = Invoke-UsageAt 31 $none
    $closed -ceq '' -and $after -ceq ''
}
Test-That 'while one that is still open when the gap is up is asked about' {
    (Invoke-UsageAt 40 $claudeOpen) -ceq 'claude'
}

Reset-UsagePacing
Test-That 'discovery that could not say counts as a session open for every client' {
    $first = Invoke-UsageAt 0 $null
    $early = Invoke-UsageAt 119 $null
    $due = Invoke-UsageAt 120 $null
    $first -ceq 'copilot,claude,codex' -and $early -ceq '' -and $due -ceq 'copilot,claude,codex'
}

# One torn read of a session's registration is enough for discovery to say it cannot
# account for everything, and a pass like that comes exactly when a session registers.
# It sets the pace - every client counts as open - but it is not a session opening, and
# the pass after it is not one closing: counted as both, each such pass cost every
# client with no session two asks that had nothing to do with it.
Reset-UsagePacing
[void](Invoke-UsageAt 0 $none)
Test-That 'a pass where discovery could not say is not a session opening for clients with none' {
    $early = Invoke-UsageAt 105 $null
    $due = Invoke-UsageAt 120 $null
    $early -ceq '' -and $due -ceq 'copilot,claude,codex'
}
Test-That 'nor is the pass after it a session closing' {
    (Invoke-UsageAt 150 $none) -ceq ''
}
Test-That 'while a session that is open when discovery can say again is found as usual' {
    (Invoke-UsageAt 180 $claudeOpen) -ceq 'claude'
}

Reset-UsagePacing
[void](Invoke-UsageAt 0 $none)
Test-That 'a session recorded with no kind is Copilot''s' {
    (Invoke-UsageAt 100 (New-LiveSessions 'unkinded')) -ceq 'copilot'
}
Reset-UsagePacing
[void](Invoke-UsageAt 0 $none)
Test-That 'and one MCP client is not a session of anything that meters an allowance' {
    (Invoke-UsageAt 100 (New-LiveSessions 'mcp')) -ceq ''
}
Reset-UsagePacing
[void](Invoke-UsageAt 0 $none)
Test-That 'each client is told apart by its own sessions' {
    $asked = Invoke-UsageAt 100 (New-LiveSessions 'codex', 'copilot')
    $asked -ceq 'copilot,codex'
}

# A gh held off after a keyring timeout used to stay held for the daemon's life (#201).
# A Copilot session opening means somebody is at the machine to answer a prompt, so it
# ends the hold - and another client's session, which says nothing about gh, does not.
Reset-UsagePacing
[void](Invoke-UsageAt 0 $none)
$script:BridgeGhUnavailable = $true
$script:BridgeGhUnavailableAt = $paceStart.AddHours(-1)
[void](Invoke-UsageAt 60 $claudeOpen)
$heldAfterClaude = $script:BridgeGhUnavailable
[void](Invoke-UsageAt 120 (New-LiveSessions 'copilot'))
Test-That 'a Copilot session opening here ends a gh hold early, where another client''s does not' {
    $heldAfterClaude -and -not $script:BridgeGhUnavailable -and
        @($script:Logged | Where-Object { $_ -match 'asking gh for the allowance again' }).Count -eq 1
} "held after Claude=$heldAfterClaude, held now=$($script:BridgeGhUnavailable)"
$script:BridgeGhUnavailable = $false

Reset-UsagePacing
$script:Settings['usage.idleIntervalSeconds'] = 1800
[void](Invoke-UsageAt 0 $none)
Test-That 'the idle pace is the one configured' {
    $early = Invoke-UsageAt 900 $none
    $due = Invoke-UsageAt 1800 $none
    $early -ceq '' -and $due -ceq 'copilot,claude,codex'
}
Reset-UsagePacing
$script:Settings['usage.intervalSeconds'] = 300
$script:Settings['usage.idleIntervalSeconds'] = 60
[void](Invoke-UsageAt 0 $none)
Test-That 'but an idle machine is never asked more often than a busy one' {
    $early = Invoke-UsageAt 299 $none
    $due = Invoke-UsageAt 300 $none
    $early -ceq '' -and $due -ceq 'copilot,claude,codex'
}
Reset-UsagePacing
$script:Settings['usage.idleIntervalSeconds'] = 120
Test-That 'an idle interval set to the quick one asks everywhere as often as before' {
    [void](Invoke-UsageAt 0 $none)
    $early = Invoke-UsageAt 119 $none
    $due = Invoke-UsageAt 120 $none
    $early -ceq '' -and $due -ceq 'copilot,claude,codex'
}
Reset-UsagePacing
$script:Settings['usage.intervalSeconds'] = 'often'
Test-That 'an interval that is not a number is the default, not a failure of the reconcile' {
    [void](Invoke-UsageAt 0 $claudeOpen)
    $early = Invoke-UsageAt 119 $claudeOpen
    $due = Invoke-UsageAt 120 $claudeOpen
    $early -ceq '' -and $due -ceq 'claude'
}
# NaN and infinity both parse as numbers and both would silently stop an idle client
# being asked at all, since nothing is ever greater than or equal to them.
foreach ($unusable in 'never', 'NaN', 'Infinity') {
    Reset-UsagePacing
    $script:Settings['usage.idleIntervalSeconds'] = $unusable
    Test-That "and so is an idle interval of '$unusable'" {
        [void](Invoke-UsageAt 0 $none)
        $early = Invoke-UsageAt 899 $none
        $due = Invoke-UsageAt 900 $none
        $early -ceq '' -and $due -ceq 'copilot,claude,codex'
    }
}

Reset-UsagePacing
[void](Invoke-UsageAt 0 $none)
$script:Readings['codex'] = New-UsageReading 'codex' 31
Test-That 'only the client whose reading moved is republished, though all were asked' {
    $asked = Invoke-UsageAt 900 $none
    $asked -ceq 'copilot,claude,codex' -and (@($script:Published) -join ',') -ceq 'codex'
}

Reset-UsagePacing
$script:Readings.Remove('codex')
Test-That 'the entity ids are forced when a client is first published, with every client published so far' {
    [void](Invoke-UsageAt 0 $none)
    $first = @($script:ForcedWith) -join '|'
    $script:Readings['codex'] = New-UsageReading 'codex' 30
    [void](Invoke-UsageAt 900 $none)
    $second = @($script:ForcedWith) -join '|'
    $script:Readings['codex'] = New-UsageReading 'codex' 31
    [void](Invoke-UsageAt 1800 $none)
    $third = @($script:ForcedWith) -join '|'
    $first -ceq 'claude,copilot' -and $second -ceq 'claude,codex,copilot' -and $third -ceq ''
}

Reset-UsagePacing
Test-That 'a clock that has gone backwards asks rather than waiting to be caught up with' {
    [void](Invoke-UsageAt 1000 $none)
    (Invoke-UsageAt 500 $none) -ceq 'copilot,claude,codex'
}

Reset-UsagePacing
$script:CollectorThrows = $true
Test-That 'a collection that fails waits for its turn rather than being repeated on every pass' {
    $first = Invoke-UsageAt 0 $null
    $retry = Invoke-UsageAt 60 $null
    $later = Invoke-UsageAt 120 $null
    $first -ceq 'copilot,claude,codex' -and $retry -ceq '' -and $later -ceq 'copilot,claude,codex' -and
        @($script:Logged | Where-Object { $_ -match 'usage collection failed' }).Count -eq 2
}

Reset-UsagePacing
$script:PublishThrows = $true
Test-That 'a reading that could not be published is asked for again at the busy pace, not the idle one' {
    [void](Invoke-UsageAt 0 $none)
    $early = Invoke-UsageAt 119 $none
    $script:PublishThrows = $false
    $retry = Invoke-UsageAt 120 $none
    $published = @($script:Published) -join ','
    $early -ceq '' -and $retry -ceq 'copilot,claude,codex' -and $published -ceq 'copilot,claude,codex'
}
Test-That 'and once it has published it is back on the idle pace' {
    $early = Invoke-UsageAt 1019 $none
    $due = Invoke-UsageAt 1020 $none
    $early -ceq '' -and $due -ceq 'copilot,claude,codex'
}

# The correction of the entity ids is a separate step from the publish, and failing it
# loses nothing that reading again would bring back: the readings are on the bus.
Reset-UsagePacing
$script:ForcingThrows = $true
Test-That 'entity ids that could not be corrected are logged, and the readings were published all the same' {
    $asked = Invoke-UsageAt 0 $none
    $asked -ceq 'copilot,claude,codex' -and (@($script:Published) -join ',') -ceq 'copilot,claude,codex' -and
        @($script:Logged | Where-Object { $_ -match 'entity ids could not be corrected' }).Count -eq 1 -and
        @($script:Logged | Where-Object { $_ -match 'could not be published' }).Count -eq 0
}
Test-That 'and that is no reason to read the vendors again at the busy pace' {
    (Invoke-UsageAt 120 $none) -ceq ''
}
Test-That 'but it is tried again at the next ask, though no reading has moved since' {
    $script:ForcingThrows = $false
    $asked = Invoke-UsageAt 900 $none
    $asked -ceq 'copilot,claude,codex' -and @($script:Published).Count -eq 0 -and
        (@($script:ForcedWith) -join '|') -ceq 'claude,codex,copilot' -and $script:DaemonUsageEntityIds -ceq 'claude,codex,copilot'
}
Test-That 'after which it is left alone' {
    [void](Invoke-UsageAt 1800 $none)
    @($script:ForcedWith).Count -eq 0
}

# The correction skips a sensor Home Assistant has not registered yet rather than
# waiting for it, and one published moments before may well not have been. Taken as
# done, that sensor would keep the id Home Assistant derived until the set of sensors
# next changed.
Reset-UsagePacing
$script:ForcingUnsettled = $true
[void](Invoke-UsageAt 0 $none)
$script:ForcingUnsettled = $false
$unsettledAgain = Invoke-UsageAt 900 $none
$unsettledForced = @($script:ForcedWith) -join '|'
[void](Invoke-UsageAt 1800 $none)
Test-That 'a correction that found a sensor not yet registered is made again at the next ask' {
    $unsettledAgain -ceq 'copilot,claude,codex' -and $unsettledForced -ceq 'claude,codex,copilot'
} "asked=$unsettledAgain forced=$unsettledForced"
Test-That 'and left alone once every sensor was there' {
    @($script:ForcedWith).Count -eq 0 -and $script:DaemonUsageEntityIds -ceq 'claude,codex,copilot'
} "forced=$(@($script:ForcedWith) -join '|') settled=$($script:DaemonUsageEntityIds)"

Reset-UsagePacing
$script:Selected = @('Copilot', 'CLAUDE', 'mcp')
Test-That 'a client selected under another capitalisation is the same client' {
    [void](Invoke-UsageAt 0 $none)
    $asked = Invoke-UsageAt 100 (New-LiveSessions 'claude')
    $keys = (@($script:DaemonUsageClients.Keys) | Sort-Object) -join ','
    $asked -ceq 'claude' -and $keys -ceq 'claude,copilot'
}
Reset-UsagePacing
$script:Selected = $null
Test-That 'an install that never chose its clients is asked about all three' {
    (Invoke-UsageAt 0 $none) -ceq 'copilot,claude,codex'
}

# --- 6c. one machine reads the account, not all of them ---------------------------

Write-Host ''
Write-Host '--- standing down while another machine reads the same account ---'

# Five machines signed in to one account asked three vendors the same question every
# two minutes and the card then discarded four of the five answers (#142). The machine
# named in dashboard.publication.writer does the asking; the others ask only when
# nothing fresh has been published for their account. What this must never become is a
# say in who publishes the dashboard, so the role is read from the explicit
# configuration and used for nothing but whether to repeat somebody else's vendor call.

# Which account is mine has to be decided before the vendor call, and on a Mac an
# identity that reached the login keychain would put back on every machine the
# authorization panel this is removing (#122). So it comes from the agents' own files.
Test-That 'the account key for Copilot is the login its own config names' {
    (Get-BridgeUsageAccountKey -Client 'copilot' -CopilotConfigPath $copilotConfig) -ceq 'work_account'
}
Test-That 'and for Claude the opaque id the card groups its rows on' {
    (Get-BridgeUsageAccountKey -Client 'claude' -ClaudeAccountPath $claudeAccountPath) -ceq $claudeId
}
Test-That 'Codex has none, its figures coming from this machine''s own transcripts' {
    (Get-BridgeUsageAccountKey -Client 'codex') -ceq ''
}
Test-That 'and an agent that has never run here has none either' {
    (Get-BridgeUsageAccountKey -Client 'copilot' -CopilotConfigPath (Join-Path $root 'no-config.json')) -ceq '' -and
        (Get-BridgeUsageAccountKey -Client 'claude' -ClaudeAccountPath (Join-Path $root 'no-account.json')) -ceq ''
}

# Held so sections 7 and 8 get the real readers back; what the checks below vary is
# which account this machine is signed in to, not how it finds out.
$script:RealCopilotAccount = (Get-Item function:Get-BridgeCopilotAccount).ScriptBlock
$script:RealClaudeAccountId = (Get-Item function:Get-BridgeClaudeAccountId).ScriptBlock
$script:LocalCopilot = 'work_account'
$script:LocalClaude = '95adb0b680fe'
function Get-BridgeCopilotAccount {
    param([AllowEmptyString()][string]$ConfigPath = '')
    if ($script:LocalCopilot) { [pscustomobject]@{ Login = $script:LocalCopilot; Host = 'https://github.com' } } else { $null }
}
function Get-BridgeClaudeAccountId { param([AllowEmptyString()][string]$Path = '') $script:LocalClaude }

$script:PeerMessages = [System.Collections.Generic.List[object]]::new()
function Publish-CopilotMqttMessage {
    param([string]$Topic, [string]$Payload, [hashtable]$Headers, [switch]$Retain)
    $script:PeerMessages.Add([pscustomobject]@{ Topic = $Topic; Payload = $Payload; Retain = [bool]$Retain })
}

function ConvertTo-PeerUsageState {
    <# What Home Assistant holds for the sensors a publish left behind, in the shape a
       state read hands back. #>
    $states = @()
    foreach ($message in $script:PeerMessages) {
        if ($message.Topic -notmatch '^homeassistant/([a-z_]+)/[^/]+/[^/]+/config$') { continue }
        $domain = $Matches[1]
        $config = $message.Payload | ConvertFrom-Json
        $raw = @($script:PeerMessages | Where-Object { $_.Topic -ceq [string]$config.state_topic } | Select-Object -Last 1)
        $attrRaw = @($script:PeerMessages | Where-Object { $_.Topic -ceq [string]$config.json_attributes_topic } | Select-Object -Last 1)
        $states += [pscustomobject]@{
            entity_id  = "$domain.$($config.object_id)"
            state      = if ($raw.Count -eq 0) { 'unavailable' } else { [string]$raw[0].Payload }
            attributes = if ($attrRaw.Count -eq 0) { $null } else { $attrRaw[0].Payload | ConvertFrom-Json }
        }
    }
    $states
}

function New-PeerUsageState {
    <# One other machine's retained reading, published by the real publisher and then
       stamped with the moment it was taken. #>
    param(
        [Parameter(Mandatory)][string]$Client,
        [AllowEmptyString()][string]$Account = '',
        [AllowEmptyString()][string]$AccountId = '',
        [string]$Slug = 'otherbox',
        # A further Copilot login's numbered sensor, rather than the client's own (#200).
        [string]$Sensor = '',
        [Parameter(Mandatory)][DateTimeOffset]$Updated
    )
    $record = New-BridgeUsageRecord -Client $Client -Account $Account -AccountId $AccountId -Source 'api' `
        -Windows @(Get-BridgeUsageWindow -Key 'main' -Label 'Main' -PercentUsed 42)
    if ($Sensor) { $record['sensor'] = $Sensor }
    $script:PeerMessages.Clear()
    & $script:RealUsagePublisher -Records @($record) -Slug $Slug -MachineName 'Other box' -Headers $headers
    $states = @(ConvertTo-PeerUsageState)
    foreach ($entry in $states) {
        if ($null -ne $entry.attributes) { $entry.attributes.updated = $Updated.ToString('o') }
    }
    $states
}
# The Copilot account this machine is signed in to, read somewhere else at a moment on
# the same clock the passes below run on.
function New-PeerCopilotState {
    param([double]$Seconds)
    New-PeerUsageState -Client 'copilot' -Account 'work_account' -Updated $paceStart.AddSeconds($Seconds)
}

$writerHere = @{ authority = 'bridge-fleet'; participant = 'dev-vm1'; writer = 'dev-vm1'; generation = 1 }
$writerElsewhere = @{ authority = 'bridge-fleet'; participant = 'home-desk'; writer = 'dev-vm1'; generation = 1 }
$copilotOpen = New-LiveSessions 'copilot'

Reset-UsagePacing
$script:Settings['dashboard.publication'] = $writerElsewhere
Test-That 'a machine that is not the designated writer leaves an account another one just read' {
    (Invoke-UsageAt 0 $copilotOpen (New-PeerCopilotState 0)) -ceq 'claude,codex'
}
Test-That 'and still leaves it two intervals on, inside the three it takes to take over' {
    # Due at 120 on the busy pace, against a reading taken six minutes before that.
    (Invoke-UsageAt 120 $copilotOpen (New-PeerCopilotState -240)) -ceq ''
}
Test-That 'but once nothing has been published for three of them, the gauge is this machine''s to keep current' {
    (Invoke-UsageAt 240 $copilotOpen (New-PeerCopilotState -121)) -ceq 'copilot'
}

Reset-UsagePacing
$script:Settings['dashboard.publication'] = $writerHere
Test-That 'the designated writer asks whatever anybody else has published' {
    (Invoke-UsageAt 0 $copilotOpen (New-PeerCopilotState 0)) -ceq 'copilot,claude,codex'
}

Reset-UsagePacing
Test-That 'and an installation that has designated nobody asks from every machine, as it always has' {
    (Invoke-UsageAt 0 $copilotOpen (New-PeerCopilotState 0)) -ceq 'copilot,claude,codex'
}

Reset-UsagePacing
$script:Settings['dashboard.publication'] = 'dev-vm1'
Test-That 'a publication setting that is not a configuration asks rather than throwing out of the pass' {
    (Invoke-UsageAt 0 $copilotOpen (New-PeerCopilotState 0)) -ceq 'copilot,claude,codex'
}

Reset-UsagePacing
$script:Settings['dashboard.publication'] = $writerElsewhere
Test-That 'another account''s reading is not this account''s, however fresh' {
    $peer = New-PeerUsageState -Client 'copilot' -Account 'someone_else' -Updated $paceStart
    (Invoke-UsageAt 0 $copilotOpen $peer) -ceq 'copilot,claude,codex'
}

Reset-UsagePacing
$script:Settings['dashboard.publication'] = $writerElsewhere
Test-That 'and neither is this machine''s own retained reading, which is the one being replaced' {
    $mine = New-PeerUsageState -Client 'copilot' -Account 'work_account' -Slug (Get-BridgeMachineSlug) -Updated $paceStart
    (Invoke-UsageAt 0 $copilotOpen $mine) -ceq 'copilot,claude,codex'
}

Reset-UsagePacing
$script:Settings['dashboard.publication'] = $writerElsewhere
Test-That 'a pass that could not read Home Assistant asks rather than assuming it is covered' {
    (Invoke-UsageAt 0 $copilotOpen $null) -ceq 'copilot,claude,codex'
}

Reset-UsagePacing
$script:Settings['dashboard.publication'] = $writerElsewhere
Test-That 'a reading with no timestamp on it says nothing about when it was taken' {
    $peer = New-PeerCopilotState 0
    foreach ($entry in $peer) { $entry.attributes.updated = '' }
    (Invoke-UsageAt 0 $copilotOpen $peer) -ceq 'copilot,claude,codex'
}

# A peer whose clock runs ahead would otherwise look permanently current and hold every
# other machine off indefinitely, which is the one way this could flatten a gauge.
Reset-UsagePacing
$script:Settings['dashboard.publication'] = $writerElsewhere
Test-That 'a reading stamped further ahead than a whole interval is a clock, not a figure' {
    (Invoke-UsageAt 0 $copilotOpen (New-PeerCopilotState 121)) -ceq 'copilot,claude,codex'
}
Reset-UsagePacing
$script:Settings['dashboard.publication'] = $writerElsewhere
Test-That 'while seconds of skew between two machines are not worth asking twice over' {
    (Invoke-UsageAt 0 $copilotOpen (New-PeerCopilotState 20)) -ceq 'claude,codex'
}

# How current a reading has to be is the pace the client is being asked about on: a
# machine with a session open needs one inside six minutes, one with nothing open does
# not, and its own slower interval is what three of them are counted from.
Reset-UsagePacing
$script:Settings['dashboard.publication'] = $writerElsewhere
Test-That 'a machine with nothing open is content with a reading three of its slower intervals old' {
    (Invoke-UsageAt 0 $none (New-PeerCopilotState -2699)) -ceq 'claude,codex'
}
Reset-UsagePacing
$script:Settings['dashboard.publication'] = $writerElsewhere
Test-That 'and asks once even that has lapsed' {
    (Invoke-UsageAt 0 $none (New-PeerCopilotState -2701)) -ceq 'copilot,claude,codex'
}

Reset-UsagePacing
$script:Settings['dashboard.publication'] = $writerElsewhere
Test-That 'Claude is matched on the opaque id, there being no account name to match on' {
    $peer = New-PeerUsageState -Client 'claude' -AccountId $script:LocalClaude -Updated $paceStart
    (Invoke-UsageAt 0 $claudeOpen $peer) -ceq 'copilot,codex'
}
Reset-UsagePacing
$script:Settings['dashboard.publication'] = $writerElsewhere
Test-That 'and a machine signed in to another Claude account is another allowance entirely' {
    $peer = New-PeerUsageState -Client 'claude' -AccountId '9f8e7d6c5b4a' -Updated $paceStart
    (Invoke-UsageAt 0 $claudeOpen $peer) -ceq 'copilot,claude,codex'
}

# Codex costs no vendor call at all - the figures are read out of this machine's own
# transcripts - so deferring would trade a free local read for somebody else's staler
# number, and there is no account on the record to match it by in any case.
Reset-UsagePacing
$script:Settings['dashboard.publication'] = $writerElsewhere
Test-That 'Codex is never stood down for, however recently another machine published one' {
    $peer = New-PeerUsageState -Client 'codex' -Updated $paceStart
    (Invoke-UsageAt 0 $none $peer) -ceq 'copilot,claude,codex'
}

# An unchanged reading that is never republished looks exactly like a machine that has
# stopped reading, and every machine standing down for it would take over.
Reset-UsagePacing
$script:Settings['dashboard.publication'] = $writerHere
Test-That 'the machine doing the asking republishes an unchanged reading, so being quiet is not mistaken for being gone' {
    [void](Invoke-UsageAt 0 $copilotOpen @())
    [void](Invoke-UsageAt 120 $copilotOpen @())
    $quiet = @($script:Published) -join ','
    [void](Invoke-UsageAt 240 $copilotOpen @())
    $quiet -ceq '' -and (@($script:Published) -join ',') -ceq 'copilot'
}
Reset-UsagePacing
Test-That 'while an installation where nobody defers keeps an unchanged reading off the bus between polls' {
    [void](Invoke-UsageAt 0 $copilotOpen @())
    [void](Invoke-UsageAt 240 $copilotOpen @())
    $first = @($script:Published) -join ','
    [void](Invoke-UsageAt 480 $copilotOpen @())
    $first -ceq '' -and (@($script:Published) -join ',') -ceq ''
}
# But not for ever. Never republishing it made a daemon still asking and finding
# nothing new look exactly like one that had stopped asking: a Mac's sensors sat at the
# same reading for four days while its daemon was demonstrably alive (#201).
Test-That 'and republishes it every half hour, so a reading nobody is checking any more ages on the card' {
    [void](Invoke-UsageAt ($script:BridgeUsageConfig.RepublishSeconds - 120) $copilotOpen @())
    $before = @($script:Published) -join ','
    [void](Invoke-UsageAt $script:BridgeUsageConfig.RepublishSeconds $copilotOpen @())
    $before -ceq '' -and (@($script:Published) -join ',') -ceq 'copilot' -and
        $script:BridgeUsageConfig.RepublishSeconds -lt 3600
}

Reset-UsagePacing
$script:Settings['dashboard.publication'] = $writerElsewhere
Test-That 'a machine that has stopped asking says so once, and says so again when it takes over' {
    [void](Invoke-UsageAt 0 $copilotOpen (New-PeerCopilotState 0))
    [void](Invoke-UsageAt 120 $copilotOpen (New-PeerCopilotState 0))
    $stood = @($script:Logged | Where-Object { $_ -match 'not asking from here' }).Count
    [void](Invoke-UsageAt 240 $copilotOpen (New-PeerCopilotState -1000))
    $stood -eq 1 -and @($script:Logged | Where-Object { $_ -match 'no longer being read' }).Count -eq 1
} "log: $(@($script:Logged) -join ' | ')"

Reset-UsagePacing
$script:Settings['dashboard.publication'] = $writerElsewhere
$script:Settings['usage.publish'] = $false
Test-That 'and turning the whole thing off still stops the collecting, designated writer or not' {
    (Invoke-UsageAt 0 $copilotOpen (New-PeerCopilotState 0)) -ceq ''
}

# Two machines that take over together are symmetric, and that symmetry was a bug: both
# read, both published, and from then on each stood down for the other's ageing reading
# until it timed out - so the account was refreshed every eight minutes by two machines
# at once instead of every two by one of them, which is worse than the polling it
# replaced and past the takeover it promises. Driven here against a store of what each
# machine has actually published, with each machine keeping its own pacing.
$script:World = @{}
$script:FleetState = @{}
$script:FleetEntityIds = @{}
$script:SimNow = $paceStart
$script:ThisSlug = 'one'
$script:RealMachineSlug = (Get-Item function:Get-BridgeMachineSlug).ScriptBlock
function Get-BridgeMachineSlug { param([string]$MachineName = '') $script:ThisSlug }
function Publish-CopilotMqttUsage {
    param([object[]]$Records, [string]$Slug, [string]$MachineName, [hashtable]$Headers)
    foreach ($record in $Records) { $script:Published.Add([string]$record.client) }
    $script:PeerMessages.Clear()
    & $script:RealUsagePublisher -Records $Records -Slug $script:ThisSlug -MachineName $script:ThisSlug -Headers $Headers
    foreach ($entry in @(ConvertTo-PeerUsageState)) {
        # Stamped on the simulated clock the passes run on, not the wall clock the
        # publisher reaches for.
        if ($null -ne $entry.attributes) { $entry.attributes.updated = $script:SimNow.ToString('o') }
        $script:World[$entry.entity_id] = $entry
    }
}
function Invoke-FleetUsageAt {
    <# One machine's pass: its own pacing, and the sensors every machine has published
       so far unless a particular view of them is given. #>
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][double]$Seconds,
        $Live,
        $States = $null
    )
    $script:ThisSlug = $Slug
    $script:SimNow = $paceStart.AddSeconds($Seconds)
    if (-not $script:FleetState.ContainsKey($Slug)) {
        $script:FleetState[$Slug] = @{}
        $script:FleetEntityIds[$Slug] = ''
    }
    $script:DaemonUsageClients = $script:FleetState[$Slug]
    $script:DaemonUsageEntityIds = $script:FleetEntityIds[$Slug]
    $script:AskLog.Clear()
    $script:Published.Clear()
    $view = if ($null -ne $States) { $States } else { @($script:World.Values) }
    [void](Sync-DaemonUsage -Headers $headers -Live $Live -States $view -Now $script:SimNow)
    $script:FleetState[$Slug] = $script:DaemonUsageClients
    $script:FleetEntityIds[$Slug] = $script:DaemonUsageEntityIds
    $script:AskLog -join ';'
}

$script:Settings = @{ 'dashboard.publication' = $writerElsewhere }
# A real Copilot record names the account it belongs to, and that is what the machines
# match each other's readings on.
$script:Readings = @{
    copilot = New-BridgeUsageRecord -Client 'copilot' -Account 'work_account' -Source 'api' `
        -Windows @(Get-BridgeUsageWindow -Key 'main' -Label 'Main' -PercentUsed 10)
}
$script:Selected = @('copilot')
Test-That 'with the writer gone, two machines becoming due at the same instant both read' {
    # The same view of Home Assistant for both, which is what "at the same instant"
    # means: neither can see a reading the other has not published yet.
    $race = @($script:World.Values)
    $first = Invoke-FleetUsageAt -Slug 'one' -Seconds 0 -Live $copilotOpen -States $race
    $second = Invoke-FleetUsageAt -Slug 'two' -Seconds 1 -Live $copilotOpen -States $race
    $first -ceq 'copilot' -and $second -ceq 'copilot'
}
Test-That 'and from then on exactly one of them keeps the account current' {
    $one = Invoke-FleetUsageAt -Slug 'one' -Seconds 120 -Live $copilotOpen
    $two = Invoke-FleetUsageAt -Slug 'two' -Seconds 121 -Live $copilotOpen
    ($one -ceq 'copilot') -xor ($two -ceq 'copilot')
} "one=$(@($script:FleetState['one'].copilot.Covered)) two=$(@($script:FleetState['two'].copilot.Covered))"
$script:FleetRounds = @()
Test-That 'at the pace a session open needs, rather than the two of them in bursts twice as far apart' {
    $script:FleetRounds = @()
    foreach ($second in 240, 360, 480) {
        $script:FleetRounds += , @(
            (Invoke-FleetUsageAt -Slug 'one' -Seconds $second -Live $copilotOpen),
            (Invoke-FleetUsageAt -Slug 'two' -Seconds ($second + 1) -Live $copilotOpen))
    }
    # Whichever published last is the one asking; the other never does.
    $polls = @($script:FleetRounds | ForEach-Object { @($_ | Where-Object { $_ -ceq 'copilot' }).Count })
    @($polls | Where-Object { $_ -ne 1 }).Count -eq 0
} "rounds: $(@($script:FleetRounds | ForEach-Object { $_ -join '+' }) -join ' / ')"
Test-That 'and when that one goes away the other takes over within three of its intervals' {
    # 'two' stops here; 'one' has been standing down for it throughout.
    $early = Invoke-FleetUsageAt -Slug 'one' -Seconds 720 -Live $copilotOpen
    $due = Invoke-FleetUsageAt -Slug 'one' -Seconds 960 -Live $copilotOpen
    $early -ceq '' -and $due -ceq 'copilot'
}

Set-Item -LiteralPath function:Get-BridgeMachineSlug -Value $script:RealMachineSlug

# The constraint that matters more than the saving: this reads who the writer is and
# decides nothing else. A machine that starts asking must not thereby start publishing.
Test-That 'the module reads the configured writer and never writes anything shared' {
    $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\hooks\daemon-usage.ps1'))
    $source -match 'Get-BridgePublicationSettings' -and
        $source -notmatch 'Set-BridgePublicationPolicy|Save-BridgePublicationReceipt|Save-CopilotSessionDashboard|Set-BridgeDashboardView'
}
Test-That 'and settles the role from that configuration alone, never from a hostname or a presence sensor' {
    $script:Settings = @{ 'dashboard.publication' = $writerElsewhere }
    $asParticipant = Get-BridgeUsagePollRole
    $script:Settings = @{ 'dashboard.publication' = $writerHere }
    $asWriter = Get-BridgeUsagePollRole
    $script:Settings = @{}
    $asParticipant -ceq 'participant' -and $asWriter -ceq 'writer' -and (Get-BridgeUsagePollRole) -ceq 'none'
}

# --- 6d. further Copilot logins, each on a numbered sensor -------------------------

Write-Host ''
Write-Host '--- further Copilot logins, each on a numbered sensor of its own ---'

# One machine can hold more than one Copilot seat - the work account Copilot is signed
# in as, and a personal one gh also holds a token for - and only the first was ever
# reported (#200). That was deliberate: a login Copilot's cache merely remembers is not
# one being spent here. A further login is reported because usage.copilotAccounts names
# it, on a numbered sensor of its own, and the card draws a row for each account.
function Get-ExtraAccounts {
    param($Configured)
    $script:Settings = @{ 'usage.copilotAccounts' = $Configured }
    Get-BridgeCopilotExtraAccounts
}
function Format-ExtraAccounts {
    param($Resolved)
    @($Resolved.Accounts | ForEach-Object { "$($_.Sensor)=$($_.Login)" }) -join ','
}

Test-That 'with none configured there are no further logins, and nothing to say about them' {
    $resolved = Get-ExtraAccounts $null
    @($resolved.Accounts).Count -eq 0 -and @($resolved.Problems).Count -eq 0
}
Test-That 'each login listed goes on a numbered sensor of its own, in the order listed' {
    (Format-ExtraAccounts (Get-ExtraAccounts @('danswett', 'hubot'))) -ceq 'copilot_2=danswett,copilot_3=hubot'
}
Test-That 'a single login written without a list around it is a list of one' {
    (Format-ExtraAccounts (Get-ExtraAccounts 'danswett')) -ceq 'copilot_2=danswett'
}
# By position, so mending or removing one entry never moves another login onto a
# sensor whose history belongs to somebody else.
$gapped = Get-ExtraAccounts @('danswett', 'not a login', 'hubot')
Test-That 'an entry that is not a login leaves its sensor unused rather than moving the rest up' {
    (Format-ExtraAccounts $gapped) -ceq 'copilot_2=danswett,copilot_4=hubot' -and
        (@($gapped.Problems) -join '|') -ceq 'entry 2 is not a GitHub login'
} "accounts=$(Format-ExtraAccounts $gapped) problems=$(@($gapped.Problems) -join '|')"
$twice = Get-ExtraAccounts @('danswett', 'DanSwett')
Test-That 'a login listed twice, in whatever case, is read once' {
    (Format-ExtraAccounts $twice) -ceq 'copilot_2=danswett' -and (@($twice.Problems) -join '|') -ceq 'DanSwett is listed twice'
} "accounts=$(Format-ExtraAccounts $twice) problems=$(@($twice.Problems) -join '|')"
$overflow = Get-ExtraAccounts @('one', 'two', 'three', 'four')
Test-That 'one past the last numbered sensor is said, not quietly dropped' {
    (Format-ExtraAccounts $overflow) -ceq 'copilot_2=one,copilot_3=two,copilot_4=three' -and
        (@($overflow.Problems) -join '|') -match '^four is past the 3 further logins'
} "accounts=$(Format-ExtraAccounts $overflow) problems=$(@($overflow.Problems) -join '|')"
# The likely mistake is a token pasted where the login belongs. Repeated back, it would
# reach the daemon log, and through gh's refusal to find such a login, the card.
$pasted = Get-ExtraAccounts @('ghp_0123456789abcdefABCDEF0123456789abcd', 'github_pat_11AAAAAAA0123456789_abcdef')
Test-That 'a token pasted where a login belongs is refused, and never repeated back' {
    @($pasted.Accounts).Count -eq 0 -and @($pasted.Problems | Where-Object { $_ -match 'looks like a token' }).Count -eq 2 -and
        @($pasted.Problems | Where-Object { $_ -match 'ghp_|github_pat_|0123456789' }).Count -eq 0
} "problems=$(@($pasted.Problems).Count)"
Test-That 'and a setting that is not a list at all is said to be wrong, not guessed at' {
    $map = Get-ExtraAccounts @{ danswett = 'copilot_2' }
    $object = Get-ExtraAccounts ([pscustomobject]@{ login = 'danswett' })
    @($map.Accounts).Count -eq 0 -and @($object.Accounts).Count -eq 0 -and
        (@($map.Problems) -join '|') -ceq 'it is not a list of logins' -and (@($object.Problems) -join '|') -ceq 'it is not a list of logins'
}

# Read with a token for that login and nothing else: whatever the environment or the
# keychain holds is the signed-in account's, and spent for another login it would put
# that account's figure under this one's name.
$script:SeenToken = ''
$further = Get-BridgeCopilotLoginAllowance -Login 'danswett' -Sensor 'copilot_2' -ResolveToken { param($Login) "token-for-$Login" } `
    -Fetch { param($Token) $script:SeenToken = $Token; New-CopilotBody -Login 'danswett' -Remaining 1200000 }
Test-That 'a further login is read with the token resolved for that login' {
    $script:SeenToken -ceq 'token-for-danswett' -and $further.source -ceq 'api' -and $further.percent -eq 20
} "token=$($script:SeenToken) source=$($further.source) percent=$($further.percent) error=$($further.error)"
Test-That 'and its reading goes on the numbered sensor it was given, under its own account' {
    (Get-CopilotMqttUsageRecordKey -Record $further) -ceq 'copilot_2' -and $further.account -ceq 'danswett' -and $further.client -ceq 'copilot'
}
$wrongAccount = Get-BridgeCopilotLoginAllowance -Login 'danswett' -Sensor 'copilot_2' -ResolveToken { 'stub' } -Fetch { New-CopilotBody -Login 'work_account' }
Test-That 'a token that answers for some other account is not believed, its figure being somebody else''s' {
    $wrongAccount.source -ceq 'none' -and $null -eq $wrongAccount.percent -and $wrongAccount.account -ceq 'danswett' -and
        $wrongAccount.error -ceq 'The token gh holds for danswett reads the allowance of work_account instead.' -and
        (Get-CopilotMqttUsageRecordKey -Record $wrongAccount) -ceq 'copilot_2'
} "source=$($wrongAccount.source) error=$($wrongAccount.error)"
Test-That 'though the same login in another case is the same account' {
    (Get-BridgeCopilotLoginAllowance -Login 'DanSwett' -Sensor 'copilot_2' -ResolveToken { 'stub' } -Fetch { New-CopilotBody -Login 'danswett' }).source -ceq 'api'
}
$script:BridgeGhReasons = @{ 'https://github.com:danswett' = 'gh has no token for danswett - run gh auth login' }
$noToken = Get-BridgeCopilotLoginAllowance -Login 'danswett' -Sensor 'copilot_2' -ResolveToken { '' } -Fetch { throw 'never reached' }
$script:BridgeGhReasons = @{}
Test-That 'a login gh holds no token for stays on the card, saying why, rather than vanishing from it' {
    $noToken.source -ceq 'none' -and $null -eq $noToken.percent -and (Get-CopilotMqttUsageRecordKey -Record $noToken) -ceq 'copilot_2' -and
        $noToken.error -ceq 'No Copilot credential was available for danswett (gh has no token for danswett - run gh auth login).'
} "error=$($noToken.error)"
$fetchFailed = Get-BridgeCopilotLoginAllowance -Login 'danswett' -Sensor 'copilot_2' -ResolveToken { 'stub' } -Fetch { throw 'the line went dead' }
Test-That 'and a quota that cannot be fetched says so, for that login' {
    $fetchFailed.source -ceq 'none' -and $fetchFailed.error -ceq 'The Copilot quota for danswett could not be read: the line went dead'
} "error=$($fetchFailed.error)"

# The real publisher, as Home Assistant would see it. Every machine's dashboard lists
# the numbered sensors by id, so the id is the contract.
$deskNode = Get-CopilotMqttMachineNode -Slug 'deskbox'
$deskRoot = Get-CopilotMqttMachineTopicRoot -Slug 'deskbox'
$script:PeerMessages.Clear()
& $script:RealUsagePublisher -Records @($further) -Slug 'deskbox' -MachineName 'Desk box' -Headers $headers
$furtherState = @(ConvertTo-PeerUsageState)
$furtherConfig = @($script:PeerMessages | Where-Object { $_.Topic -ceq "homeassistant/sensor/$deskNode/usage_copilot_2/config" })
Test-That 'a further login''s reading is published as a sensor of its own, on the id the dashboard lists' {
    $furtherState.Count -eq 1 -and $furtherState[0].entity_id -ceq 'sensor.agent_bridge_deskbox_usage_copilot_2' -and
        $furtherState[0].state -ceq '20' -and $furtherState[0].attributes.account -ceq 'danswett' -and $furtherState[0].attributes.client -ceq 'copilot'
} "states=$(@($furtherState | ForEach-Object { "$($_.entity_id)=$($_.state)" }) -join ',')"
Test-That 'named for its account, so the entity list tells it apart from the signed-in one' {
    $furtherConfig.Count -eq 1 -and ($furtherConfig[0].Payload | ConvertFrom-Json).name -ceq 'GitHub Copilot usage (danswett)' -and
        ($furtherConfig[0].Payload | ConvertFrom-Json).unique_id -ceq 'agent_bridge_deskbox_usage_copilot_2'
} "config=$(@($furtherConfig | ForEach-Object { $_.Payload }) -join ' ')"
Test-That 'and every topic of it is retained, like the client sensors beside it' {
    @($script:PeerMessages | Where-Object { -not $_.Retain }).Count -eq 0 -and
        @($script:PeerMessages | Where-Object { $_.Topic -like "$deskRoot/usage/copilot_2/*" }).Count -eq 2
}
Test-That 'while a record naming a sensor that is not one of its client''s is published nowhere' {
    $strays = foreach ($pair in @(@('copilot', 'copilot_9'), @('copilot', 'claude_2'), @('claude', 'copilot_2'), @('copilot', 'copilot_02'))) {
        $stray = New-BridgeUsageRecord -Client $pair[0] -Account 'x' -Source 'api' -Windows @(Get-BridgeUsageWindow -Key 'main' -Label 'Main' -PercentUsed 1)
        $stray['sensor'] = $pair[1]
        $stray
    }
    $script:PeerMessages.Clear()
    & $script:RealUsagePublisher -Records @($strays) -Slug 'deskbox' -MachineName 'Desk box' -Headers $headers
    $script:PeerMessages.Count -eq 0
} "published=$(@($script:PeerMessages | ForEach-Object { $_.Topic }) -join ',')"

$script:PeerMessages.Clear()
$withdrewCount = & $script:RealUsageWithdrawal -Slug 'deskbox' -Keys @('copilot_3', 'copilot_4') -Headers $headers
Test-That 'withdrawing numbered sensors clears exactly theirs, retained, so Home Assistant drops them' {
    $expected = @(foreach ($key in 'copilot_3', 'copilot_4') {
            "homeassistant/sensor/$deskNode/usage_$key/config", "$deskRoot/usage/$key/state", "$deskRoot/usage/$key/attr"
        }) | Sort-Object
    $cleared = @($script:PeerMessages | ForEach-Object { $_.Topic }) | Sort-Object
    $withdrewCount -eq 6 -and ($cleared -join ',') -ceq ($expected -join ',') -and
        @($script:PeerMessages | Where-Object { $_.Payload -ne '' -or -not $_.Retain }).Count -eq 0
} "cleared=$(@($script:PeerMessages | ForEach-Object { $_.Topic }) -join ',')"
Test-That 'and withdrawing none clears nothing' {
    $script:PeerMessages.Clear()
    (& $script:RealUsageWithdrawal -Slug 'deskbox' -Keys @() -Headers $headers) -eq 0 -and $script:PeerMessages.Count -eq 0
}
# The topics an uninstall or a forget clears. The usage sensors were missing from them
# before the numbered ones existed, so a removed machine left its readings behind.
Test-That 'what an uninstall or a forget clears includes every usage sensor, numbered ones and all' {
    $machineTopics = @(Get-CopilotMqttMachineTopic -Slug 'deskbox')
    $missing = @(foreach ($key in Get-CopilotMqttUsageSensorKey) {
            foreach ($topic in "homeassistant/sensor/$deskNode/usage_$key/config", "$deskRoot/usage/$key/state", "$deskRoot/usage/$key/attr") {
                if ($machineTopics -cnotcontains $topic) { $topic }
            }
        })
    $missing.Count -eq 0
} "missing=$(@(foreach ($key in Get-CopilotMqttUsageSensorKey) { if (@(Get-CopilotMqttMachineTopic -Slug 'deskbox') -cnotcontains "$deskRoot/usage/$key/state") { $key } }) -join ',')"

# The correction of entity ids, against a registry that has registered one numbered
# sensor and not yet the other. The registry is a stub local to this block, so the
# publication fixture the dashboard checks used stays in place for anything after.
$script:RegistryUpdates = [System.Collections.Generic.List[string]]::new()
$idForcing = & {
    function Invoke-CopilotHaWebSocket {
        param([Parameter(Mandatory)][object[]]$Commands)
        if ($Commands[0].type -ceq 'config/entity_registry/list') {
            $registry = @(
                [pscustomobject]@{ unique_id = 'agent_bridge_deskbox_usage_copilot'; entity_id = 'sensor.agent_bridge_deskbox_usage_copilot' }
                [pscustomobject]@{ unique_id = 'agent_bridge_deskbox_usage_copilot_2'; entity_id = 'sensor.ai_agent_bridge_desk_box_github_copilot_usage_danswett' }
            )
            return Write-Output -NoEnumerate @(, $registry)
        }
        $script:RegistryUpdates.Add("$($Commands[0].entity_id)>$($Commands[0].new_entity_id)")
        Write-Output -NoEnumerate @($null)
    }
    $pending = & $script:RealUsageIdForcing -Slug 'deskbox' -Clients @('copilot', 'copilot_2', 'copilot_3')
    $renamed = @($script:RegistryUpdates)
    $settled = & $script:RealUsageIdForcing -Slug 'deskbox' -Clients @('copilot', 'copilot_2')
    [pscustomobject]@{ Pending = $pending; Settled = $settled; Renamed = $renamed }
}
Test-That 'forcing the ids renames what is registered, and says the correction is not done while one is not' {
    $idForcing.Pending -eq $false -and $idForcing.Settled -eq $true -and
        ($idForcing.Renamed -join ',') -ceq 'sensor.ai_agent_bridge_desk_box_github_copilot_usage_danswett>sensor.agent_bridge_deskbox_usage_copilot_2'
} "pending=$($idForcing.Pending) settled=$($idForcing.Settled) renamed=$(@($idForcing.Renamed) -join ',')"

# The passes, with the reader of a further login stubbed: what was asked, in the order
# it was asked, and which sensor each reading went out on.
$script:RealLoginAllowance = (Get-Item function:Get-BridgeCopilotLoginAllowance).ScriptBlock
$script:LoginThrows = $false
function Get-BridgeCopilotLoginAllowance {
    param([string]$Login, [string]$Sensor)
    $script:AskLog.Add("${Sensor}:$Login")
    if ($script:LoginThrows) { throw 'gh went away' }
    $record = New-BridgeUsageRecord -Client 'copilot' -Account $Login -Source 'api' `
        -Windows @(Get-BridgeUsageWindow -Key 'plan' -Label 'Plan' -PercentUsed 5)
    $record['sensor'] = $Sensor
    $record
}
$script:PublishedRecords = [System.Collections.Generic.List[object]]::new()
function Publish-CopilotMqttUsage {
    param([object[]]$Records, [string]$Slug, [string]$MachineName, [hashtable]$Headers)
    if ($script:PublishThrows) { throw 'mqtt unreachable' }
    foreach ($record in $Records) {
        $script:Published.Add((Get-CopilotMqttUsageRecordKey -Record $record))
        $script:PublishedRecords.Add($record)
    }
}

Reset-UsagePacing
$script:Settings['usage.copilotAccounts'] = @('danswett')
$firstAsk = Invoke-UsageAt 0 $none
Test-That 'a further login is asked about on the first pass, beside the clients, and published on its own sensor' {
    $firstAsk -ceq 'copilot,claude,codex;copilot_2:danswett' -and (@($script:Published) -join ',') -ceq 'copilot,claude,codex,copilot_2'
} "asked=$firstAsk published=$(@($script:Published) -join ',')"
Test-That 'that first pass withdraws the numbered sensors no login is on, whatever an earlier run left there' {
    (@($script:Withdrawn) -join '|') -ceq 'copilot_3,copilot_4'
} "withdrawn=$(@($script:Withdrawn) -join '|')"
Test-That 'and forces its sensor''s id along with the rest' {
    (@($script:ForcedWith) -join '|') -ceq 'claude,codex,copilot,copilot_2'
} "forced=$(@($script:ForcedWith) -join '|')"
$busyAsks = @(foreach ($second in 30, 120, 240, 360, 480, 600, 720, 840) { Invoke-UsageAt $second $copilotOpen })
$idleDue = Invoke-UsageAt 900 $copilotOpen
Test-That 'it is read at the idle pace while a Copilot session is open here, those sessions spending the signed-in account' {
    @($busyAsks | Where-Object { $_ -match 'copilot_2' }).Count -eq 0 -and @($busyAsks | Where-Object { $_ -ceq 'copilot' }).Count -ge 6 -and
        $idleDue -match ';copilot_2:danswett$'
} "asks=$($busyAsks -join ' / ') then=$idleDue"
Test-That 'and nothing is withdrawn again while the logins listed stay the same' {
    @($script:Withdrawn).Count -eq 1
} "withdrawn=$(@($script:Withdrawn) -join '|')"

Reset-UsagePacing
$script:Settings['usage.copilotAccounts'] = @('danswett')
[void](Invoke-UsageAt 0 $none)
$script:Settings['usage.copilotAccounts'] = @()
$script:Withdrawn.Clear()
$afterRemoval = Invoke-UsageAt 900 $none
Test-That 'a login taken off the list is asked about no more, and its sensor is withdrawn rather than left showing its last reading' {
    $afterRemoval -ceq 'copilot,claude,codex' -and (@($script:Withdrawn) -join '|') -ceq 'copilot_2,copilot_3,copilot_4' -and
        -not $script:DaemonUsageClients.ContainsKey('copilot_2')
} "asked=$afterRemoval withdrawn=$(@($script:Withdrawn) -join '|')"

# Taken off the list and listed again, the set of sensors can read exactly as it did
# when their ids were last forced, if the correction in between did not go through -
# but the entity forced then went with the withdrawal, and the one published now is
# registered afresh.
Reset-UsagePacing
$script:Settings['usage.copilotAccounts'] = @('danswett')
[void](Invoke-UsageAt 0 $none)
$script:Settings['usage.copilotAccounts'] = @()
$script:ForcingThrows = $true
$removalAsk = Invoke-UsageAt 900 $none
$script:ForcingThrows = $false
$script:Settings['usage.copilotAccounts'] = @('danswett')
$relisted = Invoke-UsageAt 960 $none
Test-That 'listed again, it is read and published at once, its retained reading having been cleared' {
    $removalAsk -ceq 'copilot,claude,codex' -and $relisted -ceq 'copilot_2:danswett' -and (@($script:Published) -join ',') -ceq 'copilot_2'
} "removal=$removalAsk asked=$relisted published=$(@($script:Published) -join ',')"
Test-That 'and its id forced afresh, the entity it was forced on before having gone with it' {
    (@($script:ForcedWith) -join '|') -ceq 'claude,codex,copilot,copilot_2'
} "forced=$(@($script:ForcedWith) -join '|')"

# A withdrawal is a publish, and the reconcile runs every fifteen seconds: retried on
# every pass, one that failed would be retried, and logged, four times a minute.
Reset-UsagePacing
$script:Settings['usage.copilotAccounts'] = @('danswett')
$script:WithdrawThrows = $true
$withdrawFailedAsk = Invoke-UsageAt 0 $none
$script:WithdrawThrows = $false
[void](Invoke-UsageAt 15 $none)
$withdrawnBeforeReading = @($script:Withdrawn).Count
[void](Invoke-UsageAt 30 $claudeOpen)
Test-That 'a withdrawal that fails holds up no reading, is said, and is tried again with the next reading, not on every pass' {
    $withdrawFailedAsk -ceq 'copilot,claude,codex;copilot_2:danswett' -and $withdrawnBeforeReading -eq 0 -and
        @($script:Logged | Where-Object { $_ -match 'could not be withdrawn' }).Count -eq 1 -and
        (@($script:Withdrawn) -join '|') -ceq 'copilot_3,copilot_4'
} "asked=$withdrawFailedAsk early=$withdrawnBeforeReading withdrawn=$(@($script:Withdrawn) -join '|') log=$(@($script:Logged) -join ' | ')"

Reset-UsagePacing
$script:Readings = @{}
[void](Invoke-UsageAt 0 $none)
Test-That 'and a pass that read nothing withdraws nothing, so a machine with nothing to report writes nothing for it' {
    @($script:Withdrawn).Count -eq 0 -and $null -eq $script:DaemonUsageExtraSensors
} "withdrawn=$(@($script:Withdrawn) -join '|')"

Reset-UsagePacing
$script:Settings['usage.copilotAccounts'] = @('danswett')
$script:LoginThrows = $true
$script:PublishedRecords.Clear()
[void](Invoke-UsageAt 0 $none)
$failedRow = @($script:PublishedRecords | Where-Object { (Get-CopilotMqttUsageRecordKey -Record $_) -ceq 'copilot_2' } | Select-Object -Last 1)
$signedInRow = @($script:PublishedRecords | Where-Object { (Get-CopilotMqttUsageRecordKey -Record $_) -ceq 'copilot' } | Select-Object -Last 1)
Test-That 'a further login whose reading blew up says so on its own row, and not on the signed-in account''s' {
    $failedRow.Count -eq 1 -and $failedRow[0].source -ceq 'none' -and $failedRow[0].account -ceq 'danswett' -and
        $failedRow[0].error -match '^Usage for danswett could not be collected: gh went away' -and
        $signedInRow.Count -eq 1 -and $signedInRow[0].source -ceq 'api' -and -not $signedInRow[0].error
} "row=$(@($failedRow | ForEach-Object { "$($_.source): $($_.error)" }) -join ',')"
$script:LoginThrows = $false

Reset-UsagePacing
$script:Settings['usage.copilotAccounts'] = @('danswett')
$script:PublishThrows = $true
[void](Invoke-UsageAt 0 $none)
$script:PublishThrows = $false
$republishEarly = Invoke-UsageAt 119 $none
$republishDue = Invoke-UsageAt 120 $none
Test-That 'one that could not be published is asked for again at the busy pace, like any reading' {
    $republishEarly -ceq '' -and $republishDue -ceq 'copilot,claude,codex;copilot_2:danswett' -and
        (@($script:Published) -join ',') -ceq 'copilot,claude,codex,copilot_2'
} "early=$republishEarly due=$republishDue"

Reset-UsagePacing
$script:Settings['usage.copilotAccounts'] = @('danswett')
$script:Selected = @('claude', 'mcp')
$noCopilot = Invoke-UsageAt 0 $none
Test-That 'a machine that does not report Copilot reads no further Copilot login either, and keeps no numbered sensor' {
    $noCopilot -ceq 'claude' -and (@($script:Withdrawn) -join '|') -ceq 'copilot_2,copilot_3,copilot_4'
} "asked=$noCopilot withdrawn=$(@($script:Withdrawn) -join '|')"

Reset-UsagePacing
$script:Settings['usage.copilotAccounts'] = @('danswett', 'ghp_0123456789abcdefABCDEF0123456789abcd')
[void](Invoke-UsageAt 0 $none)
[void](Invoke-UsageAt 30 $none)
[void](Invoke-UsageAt 900 $none)
$listNotes = @($script:Logged | Where-Object { $_ -like 'usage.copilotAccounts:*' })
Test-That 'what the list amounts to is logged once, not on every pass' {
    $listNotes.Count -eq 1 -and $listNotes[0] -ceq 'usage.copilotAccounts: reporting danswett on usage_copilot_2; entry 2 looks like a token, not a login, so it is not used'
} "notes=$($listNotes -join ' | ')"
Test-That 'and nothing logged repeats the entry shaped like a token' {
    @($script:Logged | Where-Object { $_ -match 'ghp_|0123456789abcdef' }).Count -eq 0
}

# Another machine keeping the same login current is as good as reading it here, exactly
# as for the signed-in account (#142) - including when that machine is signed in to
# Copilot as the login this one lists, and so reports it on its own client sensor.
Reset-UsagePacing
$script:Settings['dashboard.publication'] = $writerElsewhere
$script:Settings['usage.copilotAccounts'] = @('danswett')
$peerSignedIn = Invoke-UsageAt 0 $none @(New-PeerUsageState -Client 'copilot' -Account 'danswett' -Updated $paceStart)
Test-That 'a further login another machine has just read is left to it, like any account' {
    $peerSignedIn -ceq 'copilot,claude,codex'
} "asked=$peerSignedIn"
Reset-UsagePacing
$script:Settings['dashboard.publication'] = $writerElsewhere
$script:Settings['usage.copilotAccounts'] = @('danswett')
$peerNumbered = Invoke-UsageAt 0 $none @(New-PeerUsageState -Client 'copilot' -Account 'danswett' -Sensor 'copilot_3' -Updated $paceStart)
Test-That 'whichever sensor that machine reported it on' {
    $peerNumbered -ceq 'copilot,claude,codex'
} "asked=$peerNumbered"
Reset-UsagePacing
$script:Settings['dashboard.publication'] = $writerElsewhere
$script:Settings['usage.copilotAccounts'] = @('DanSwett')
$peerCased = Invoke-UsageAt 0 $none @(New-PeerUsageState -Client 'copilot' -Account 'danswett' -Updated $paceStart)
Test-That 'and however the list spells the login, GitHub''s logins not being case-sensitive' {
    $peerCased -ceq 'copilot,claude,codex'
} "asked=$peerCased"
Reset-UsagePacing
$script:Settings['dashboard.publication'] = $writerElsewhere
$script:Settings['usage.copilotAccounts'] = @('danswett')
$peerOther = Invoke-UsageAt 0 $none @(New-PeerUsageState -Client 'copilot' -Account 'hubot' -Updated $paceStart)
Test-That 'but another login''s reading is no reason to leave this one unread' {
    $peerOther -ceq 'copilot,claude,codex;copilot_2:danswett'
} "asked=$peerOther"
Reset-UsagePacing
$script:Settings['dashboard.publication'] = $writerElsewhere
$claudeCased = Invoke-UsageAt 0 $claudeOpen @(New-PeerUsageState -Client 'claude' -AccountId '95ADB0B680FE' -Updated $paceStart)
Test-That 'while Claude''s opaque account id is still matched exactly' {
    $claudeCased -ceq 'copilot,claude,codex'
} "asked=$claudeCased"

Set-Item -LiteralPath function:Get-BridgeCopilotLoginAllowance -Value $script:RealLoginAllowance

Set-Item -LiteralPath function:Get-BridgeCopilotAccount -Value $script:RealCopilotAccount
Set-Item -LiteralPath function:Get-BridgeClaudeAccountId -Value $script:RealClaudeAccountId

$script:Settings = $settingsBefore
function Get-BridgeSelectedClients { , @('copilot', 'mcp') }
function Write-DaemonLog { param([string]$Message) }

# --- 7. the keychain the Copilot token comes from ---------------------------------
Write-Host ''
Write-Host '--- reading the Copilot token on macOS ---'

# A Mac was made unusable by authorization panels while the bridge asked, every two
# minutes, for a number that decorates a gauge (#122). The reason pressing "Always
# Allow" never settled it is that the CLI replaces its keychain item whenever it
# refreshes the token, and the replacement carries a new ACL - so the grant belongs to
# an item that no longer exists. A prompt that cannot be stopped by answering it is
# not something to raise by default.
$script:BridgeIsWindows = $false
$script:Probes = 0
$script:ProbeResult = [pscustomobject]@{ Ran = $true; TimedOut = $false; ExitCode = 0; Output = 'gho_fromkeychain' }
function Invoke-BridgeCommandProbe {
    param([string]$Executable, [string[]]$Arguments, [int]$TimeoutMs)
    $script:Probes++
    $script:ProbeResult
}

# The rung after the keychain has its own section below. Here gh is absent, so that
# what these count is the keychain and nothing else.
function Get-BridgeGitHubCliPath { $null }

foreach ($name in @('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')) {
    Set-Item -LiteralPath "env:$name" -Value '' -ErrorAction SilentlyContinue
}

$script:Settings = @{}
$script:BridgeKeychainToken = ''
$script:BridgeKeychainUnavailable = $false

Test-That 'the keychain is left alone unless it was deliberately turned on' {
    $token = Get-BridgeCopilotToken -Login 'octocat'
    $token -eq '' -and $script:Probes -eq 0
} "probes: $($script:Probes)"

$script:Settings['usage.keychain'] = $true
Test-That 'turning it on reads the token the CLI stored' {
    (Get-BridgeCopilotToken -Login 'octocat') -eq 'gho_fromkeychain'
}

Test-That 'and having read it once, does not ask a second time' {
    $before = $script:Probes
    (Get-BridgeCopilotToken -Login 'octocat') -eq 'gho_fromkeychain' -and $script:Probes -eq $before
} "probes: $($script:Probes)"

# Being refused is the same storm by another route: the poll comes back in two minutes
# and raises the panel again, for as long as the machine is on.
$script:BridgeKeychainToken = ''
$script:BridgeKeychainUnavailable = $false
$script:ProbeResult = [pscustomobject]@{ Ran = $true; TimedOut = $false; ExitCode = 44; Output = '' }
$script:Probes = 0

Test-That 'a refusal is taken as an answer, not retried on the next poll' {
    $first = Get-BridgeCopilotToken -Login 'octocat'
    $second = Get-BridgeCopilotToken -Login 'octocat'
    $first -eq '' -and $second -eq '' -and $script:Probes -eq 1
} "probes: $($script:Probes)"

Test-That 'an unanswered prompt is described as nobody having answered it' {
    (Get-BridgeKeychainRefusal -Probe ([pscustomobject]@{ Ran = $true; TimedOut = $true; ExitCode = 0; Output = '' })) -match 'went unanswered'
}

Test-That 'and a denied one as access refused, which is a different thing to fix' {
    (Get-BridgeKeychainRefusal -Probe ([pscustomobject]@{ Ran = $true; TimedOut = $false; ExitCode = 44; Output = '' })) -match 'denied'
}

# The way out that costs no interruption at all.
$script:Probes = 0
$env:COPILOT_GITHUB_TOKEN = 'gho_fromenvironment'
Test-That 'an environment token is used without going near the keychain' {
    (Get-BridgeCopilotToken -Login 'octocat') -eq 'gho_fromenvironment' -and $script:Probes -eq 0
} "probes: $($script:Probes)"
$env:COPILOT_GITHUB_TOKEN = ''

# Copilot's lastLoggedInUser can change under a running daemon, and the allowance then
# belongs to a different account. Reusing the token read for the previous one went on
# publishing the old account's figure until restart - a wrong number, which is worse
# than no number at all. Found by review on #141.
function Invoke-BridgeCommandProbe {
    param([string]$Executable, [string[]]$Arguments, [int]$TimeoutMs)
    $script:Probes++
    $account = ''
    for ($i = 0; $i -lt $Arguments.Count - 1; $i++) {
        if ($Arguments[$i] -eq '-a') { $account = [string]$Arguments[$i + 1] }
    }
    [pscustomobject]@{ Ran = $true; TimedOut = $false; ExitCode = 0; Output = "gho_for_$account" }
}
$script:BridgeKeychainToken = ''
$script:BridgeKeychainAccount = ''
$script:BridgeKeychainUnavailable = $false

Test-That 'signing in as someone else re-reads rather than reusing the last token' {
    $first = Get-BridgeCopilotToken -Login 'octocat'
    $second = Get-BridgeCopilotToken -Login 'hubot'
    $first -eq 'gho_for_https://github.com:octocat' -and $second -eq 'gho_for_https://github.com:hubot'
}

Test-That 'and a refusal for one account does not silence the next' {
    $script:BridgeKeychainToken = ''
    $script:BridgeKeychainAccount = 'https://github.com:octocat'
    $script:BridgeKeychainUnavailable = $true
    (Get-BridgeCopilotToken -Login 'hubot') -eq 'gho_for_https://github.com:hubot'
}

# --- 8. the token gh holds --------------------------------------------------------

Write-Host ''
Write-Host '--- reading the Copilot token from the GitHub CLI ---'

# Copilot CLI's own order ends at `gh auth token`, and the bridge stopped one rung
# short of it. Measured on 2026-10-09: a Mac signed in to Copilot as danswett, with the
# keychain read off by default, said "No Copilot credential was available" while gh
# held a token for that login that the quota endpoint accepted. gh reads and writes its
# keychain entries through /usr/bin/security, which therefore trusts them, so asking it
# raises none of the panels that reading the CLI's own item does.
$script:GhPath = '/opt/homebrew/bin/gh'
function Get-BridgeGitHubCliPath { $script:GhPath }

function New-ProbeAnswer {
    param([bool]$Ran = $true, [bool]$TimedOut = $false, [int]$ExitCode = 0, [string]$Stdout = '')
    [pscustomobject]@{ Ran = $Ran; TimedOut = $TimedOut; ExitCode = $ExitCode; Output = $Stdout; StandardOutput = $Stdout }
}

# Anything that is not the `security` command is gh, so a test can tell which of the
# two was run without caring about either's real arguments.
function Invoke-BridgeCommandProbe {
    param([string]$Executable, [string[]]$Arguments, [int]$TimeoutMs)
    if ($Executable -ceq 'security') { $script:KeychainRuns++; return $script:KeychainAnswer }
    $script:GhRuns += [pscustomobject]@{ Executable = $Executable; Arguments = @($Arguments) }
    $script:GhAnswer
}
function Write-DaemonLog { param([string]$Message) $script:GhLog += $Message }

function Reset-GhRung {
    $script:GhRuns = @()
    $script:KeychainRuns = 0
    $script:GhLog = @()
    $script:GhPath = '/opt/homebrew/bin/gh'
    $script:GhAnswer = New-ProbeAnswer -Stdout "gho_fromgh`n"
    $script:KeychainAnswer = New-ProbeAnswer -ExitCode 44
    $script:Settings = @{}
    $script:BridgeKeychainToken = ''
    $script:BridgeKeychainAccount = ''
    $script:BridgeKeychainUnavailable = $false
    $script:BridgeGhReasons = @{}
    $script:BridgeGhUnavailable = $false
    $script:BridgeGhUnavailableAt = [DateTimeOffset]::MinValue
    foreach ($name in @('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')) {
        Set-Item -LiteralPath "env:$name" -Value '' -ErrorAction SilentlyContinue
    }
}

Reset-GhRung
Test-That 'a Mac that leaves its keychain alone still gets the token gh holds' {
    (Get-BridgeCopilotToken -Login 'octocat') -ceq 'gho_fromgh' -and $script:KeychainRuns -eq 0
} "keychain asked $($script:KeychainRuns) time(s)"
Test-That 'asked for the login Copilot is signed in as, on github.com, not whichever account is active' {
    @($script:GhRuns).Count -eq 1 -and
        $script:GhRuns[0].Executable -ceq $script:GhPath -and
        ($script:GhRuns[0].Arguments -join ' ') -ceq 'auth token --hostname github.com --user octocat'
} "ran: $(@($script:GhRuns | ForEach-Object { $_.Arguments -join ' ' }) -join ' | ')"

Reset-GhRung
$env:GH_TOKEN = 'gho_fromenvironment'
Test-That 'an environment token still comes first, and gh is not run' {
    (Get-BridgeCopilotToken -Login 'octocat') -ceq 'gho_fromenvironment' -and @($script:GhRuns).Count -eq 0
}
# The environment's token is the signed-in account's. Spent for a further login it
# would read that account's allowance, which the login check would then refuse, so the
# further login would never be read at all (#200).
$script:SeenToken = ''
$furtherFromGh = Get-BridgeCopilotLoginAllowance -Login 'hubot' -Sensor 'copilot_2' `
    -Fetch { param($Token) $script:SeenToken = $Token; New-CopilotBody -Login 'hubot' }
Test-That 'while a further login''s token comes from gh, asked for that login, whatever the environment holds' {
    $script:SeenToken -ceq 'gho_fromgh' -and $furtherFromGh.source -ceq 'api' -and @($script:GhRuns).Count -eq 1 -and
        ($script:GhRuns[0].Arguments -join ' ') -ceq 'auth token --hostname github.com --user hubot'
} "token=$($script:SeenToken) source=$($furtherFromGh.source) ran: $(@($script:GhRuns | ForEach-Object { $_.Arguments -join ' ' }) -join ' | ')"
$env:GH_TOKEN = ''

Reset-GhRung
$script:Settings['usage.keychain'] = $true
$script:KeychainAnswer = New-ProbeAnswer -Stdout "gho_fromkeychain`n"
Test-That 'a keychain that was turned on is read before gh' {
    (Get-BridgeCopilotToken -Login 'octocat') -ceq 'gho_fromkeychain' -and @($script:GhRuns).Count -eq 0
}
Reset-GhRung
$script:Settings['usage.keychain'] = $true
Test-That 'and when it refuses, gh is the next rung rather than the end of the line' {
    (Get-BridgeCopilotToken -Login 'octocat') -ceq 'gho_fromgh' -and $script:KeychainRuns -eq 1
} "keychain asked $($script:KeychainRuns) time(s)"

Reset-GhRung
$script:GhPath = $null
Test-That 'a machine without gh gets no token from it, and runs nothing' {
    (Get-BridgeCopilotToken -Login 'octocat') -ceq '' -and @($script:GhRuns).Count -eq 0
}
Test-That 'and the refusal says so' {
    (Get-BridgeGitHubCliRefusal -Login 'octocat') -ceq 'gh is not installed'
}

Reset-GhRung
$script:GhAnswer = New-ProbeAnswer -ExitCode 1
Test-That 'gh holding no token for that account gets none' {
    (Get-BridgeCopilotToken -Login 'octocat') -ceq ''
}
Test-That 'and is asked again on the next poll, so signing in to gh heals the card without a restart' {
    $before = @($script:GhRuns).Count
    $null = Get-BridgeCopilotToken -Login 'octocat'
    @($script:GhRuns).Count -eq $before + 1
}
Test-That 'the refusal names the account and what mends it' {
    (Get-BridgeGitHubCliRefusal -Login 'octocat') -ceq 'gh has no token for octocat - run gh auth login'
}
Test-That 'and is logged once, not on every poll' {
    @($script:GhLog).Count -eq 1
} "log: $(@($script:GhLog) -join ' | ')"
Test-That 'a refusal belongs to the account it was given for' {
    (Get-BridgeGitHubCliRefusal -Login 'hubot') -ceq '' -and
        (Get-BridgeGitHubCliRefusal -Login 'octocat' -HostUrl 'https://octo.ghe.com') -ceq ''
}

Reset-GhRung
$script:GhAnswer = New-ProbeAnswer -Ran $false
Test-That 'a gh that cannot be run gets none, and says that rather than that it has no token' {
    (Get-BridgeCopilotToken -Login 'octocat') -ceq '' -and (Get-BridgeGitHubCliRefusal -Login 'octocat') -ceq 'gh could not be run'
}

# A keyring waiting to be unlocked holds gh at a prompt, and asking again in two
# minutes raises that prompt again - the storm the keychain read is kept off for.
Reset-GhRung
$script:GhAnswer = New-ProbeAnswer -TimedOut $true -ExitCode -1
Test-That 'a gh that never answers is asked once, not on every poll' {
    $first = Get-BridgeCopilotToken -Login 'octocat'
    $second = Get-BridgeCopilotToken -Login 'octocat'
    $first -ceq '' -and $second -ceq '' -and @($script:GhRuns).Count -eq 1
} "runs: $(@($script:GhRuns).Count)"
Test-That 'and says that it did not answer' {
    (Get-BridgeGitHubCliRefusal -Login 'octocat') -ceq 'gh did not answer in time'
}
# What hung was gh, not the account: a keyring holding it at a prompt holds it for any
# login. Asked afresh for each, every login read in a poll was the prompt again, every
# poll, once further logins were read beside Copilot's own (#200).
Test-That 'and is held off for every other login too, saying why on each' {
    $script:GhAnswer = New-ProbeAnswer -Stdout "gho_forhubot`n"
    (Get-BridgeCopilotToken -Login 'hubot') -ceq '' -and @($script:GhRuns).Count -eq 1 -and
        (Get-BridgeGitHubCliRefusal -Login 'hubot') -ceq 'gh did not answer in time'
} "runs: $(@($script:GhRuns).Count)"

# Held off, but not for as long as the daemon lives. "Final for the run" was final for
# weeks on a daemon that never restarted, and a Mac's Copilot reading never moved
# again (#201).
Reset-GhRung
$script:GhAnswer = New-ProbeAnswer -TimedOut $true -ExitCode -1
$null = Get-BridgeCopilotToken -Login 'octocat'
$script:GhAnswer = New-ProbeAnswer -Stdout "gho_fromgh`n"
$script:BridgeGhUnavailableAt = [DateTimeOffset]::Now.AddHours(-$script:BridgeUsageConfig.GhHoldHours).AddMinutes(-1)
Test-That 'a gh that did not answer is asked again once its hold has run out' {
    (Get-BridgeCopilotToken -Login 'octocat') -ceq 'gho_fromgh' -and @($script:GhRuns).Count -eq 2
} "runs: $(@($script:GhRuns).Count)"

Reset-GhRung
$script:GhAnswer = New-ProbeAnswer -TimedOut $true -ExitCode -1
$null = Get-BridgeCopilotToken -Login 'octocat'
$failedAt = $script:BridgeGhUnavailableAt
Test-That 'a Copilot session opening straight after the timeout does not ask again, which would be the prompt storm' {
    -not (Reset-BridgeGitHubCliHold -Now $failedAt.AddMinutes(5)) -and $script:BridgeGhUnavailable -and
        (Get-BridgeCopilotToken -Login 'octocat') -ceq '' -and @($script:GhRuns).Count -eq 1
}
Test-That 'but one opening a while later does, somebody being at the machine to answer it' {
    $script:GhAnswer = New-ProbeAnswer -Stdout "gho_fromgh`n"
    (Reset-BridgeGitHubCliHold -Now $failedAt.AddMinutes($script:BridgeUsageConfig.GhPresentMinutes + 1)) -and
        (Get-BridgeCopilotToken -Login 'octocat') -ceq 'gho_fromgh' -and @($script:GhRuns).Count -eq 2
}
Test-That 'and with no hold in place there is nothing to end' { -not (Reset-BridgeGitHubCliHold) }

# What goes into an Authorization header, and what lands in a log, are not for gh to
# decide: a success prints the token itself.
Reset-GhRung
$script:GhAnswer = New-ProbeAnswer -Stdout "gho_one`ngho_two`n"
Test-That 'more than one line of output is not a token, and is not copied into the log' {
    (Get-BridgeCopilotToken -Login 'octocat') -ceq '' -and -not (@($script:GhLog) -join ' ').Contains('gho_')
} "log: $(@($script:GhLog) -join ' | ')"
Reset-GhRung
$script:GhAnswer = New-ProbeAnswer -Stdout "gho with a space`n"
Test-That 'nor is a line with whitespace in it' {
    (Get-BridgeCopilotToken -Login 'octocat') -ceq ''
}
Reset-GhRung
$script:GhAnswer = New-ProbeAnswer -Stdout "`r`n"
Test-That 'nor is nothing' {
    (Get-BridgeCopilotToken -Login 'octocat') -ceq ''
}
Reset-GhRung
$script:GhAnswer = New-ProbeAnswer -Stdout "  gho_fromgh`r`n"
Test-That 'but the line ending and padding around a real one are not part of it' {
    (Get-BridgeCopilotToken -Login 'octocat') -ceq 'gho_fromgh'
}

Reset-GhRung
Test-That 'a host other than github.com is not sent to gh, since the quota is read from api.github.com' {
    (Get-BridgeCopilotToken -Login 'octocat' -HostUrl 'https://octo.ghe.com') -ceq '' -and @($script:GhRuns).Count -eq 0
}

# The whole chain, through the allowance rather than the token alone.
$ghConfig = Join-Path $root 'gh-config.json'
Set-Content -LiteralPath $ghConfig -Encoding UTF8 -Value @'
{
  "lastLoggedInUser": { "host": "https://github.com", "login": "octocat" },
  "loggedInUsers": [ { "host": "https://github.com", "login": "octocat" } ]
}
'@

Reset-GhRung
$script:SpentToken = ''
$viaGh = Get-BridgeCopilotAllowance -ConfigPath $ghConfig -CachePath '' -Fetch {
    param($Token)
    $script:SpentToken = $Token
    New-CopilotBody -Login 'octocat'
}
Test-That 'the allowance is read live with the token gh holds' {
    $viaGh.source -ceq 'api' -and $script:SpentToken -ceq 'gho_fromgh' -and -not $viaGh.error
} "source=$($viaGh.source) error=$($viaGh.error)"
Test-That 'and attributed to the account that was asked for' {
    $viaGh.account -ceq 'octocat'
}

Reset-GhRung
$script:GhAnswer = New-ProbeAnswer -ExitCode 1
$unsigned = Get-BridgeCopilotAllowance -ConfigPath $ghConfig -CachePath '' -Fetch { throw 'never reached without a token' }
Test-That 'with no credential anywhere, the card is told which one to mend' {
    $unsigned.source -ceq 'none' -and
        $unsigned.error -ceq 'No Copilot credential was available and nothing was cached (gh has no token for octocat - run gh auth login).'
} "error=$($unsigned.error)"

$plain = Get-BridgeCopilotAllowance -ConfigPath $copilotConfig -CachePath '' -ResolveToken { '' } -Fetch { throw 'no token' }
Test-That 'while an account gh was never asked about keeps the plain message' {
    $plain.error -ceq 'No Copilot credential was available and nothing was cached.'
} "error=$($plain.error)"

Reset-GhRung
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All usage checks passed' -ForegroundColor Green
