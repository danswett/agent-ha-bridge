<#
    Bridge daemon: how much of each agent's allowance is gone.

    `/usage` in Copilot CLI, `/status` in Codex and `/usage` in Claude Code all answer
    the same question - how much of this month's or this week's allowance is left - and
    each answers it only to whoever is sitting at that terminal. This asks on a timer
    instead and publishes the answer per machine, so the dashboard can show it beside
    the sessions doing the spending.

    Every client reduces to the same shape, a list of windows each with a percentage,
    because that is the only thing the three have in common: Copilot meters one monthly
    pool of AI credits, Codex two rolling rate-limit windows, Claude a session window
    and a weekly one. The card draws whatever windows it is handed rather than knowing
    anything about any of them.

    Part of agent-bridge-daemon.ps1, which dot-sources it into its own scope after
    declaring the shared $script: state; see docs/daemon-split.md.
    Shared state it changes: DaemonUsageCheckedAt, DaemonUsageSignature.
#>

$script:BridgeUsageConfig = @{
    # The figures move continuously while a session runs - Copilot's remaining credits
    # were measured changing inside three minutes - so this is a poll, not a cache
    # read. Two minutes is the compromise between showing "what is left right now" and
    # asking three vendors for it from every machine that runs a bridge.
    IntervalSeconds = 120
    RequestTimeout  = 15
    UserAgent       = 'agent-ha-bridge'
    # Enough to refuse a file that is not the small state document it should be,
    # without a judgement about how large those documents are allowed to grow.
    MaxStateBytes   = 8MB
}

$script:DaemonUsageCheckedAt = [DateTimeOffset]::MinValue
$script:DaemonUsageSignature = ''
$script:DaemonUsageEntityIds = ''

function Get-BridgeUsageLabel {
    param([Parameter(Mandatory)][string]$Client)
    switch ($Client) {
        'copilot' { 'GitHub Copilot' }
        'claude' { 'Claude Code' }
        'codex' { 'Codex' }
        default { $Client }
    }
}

function Read-BridgeUsageJson {
    <#
        Reads one of an agent's own state files.

        Copilot writes its state as JSON behind a `//` banner, which ConvertFrom-Json
        rejects outright, so whole-line comments are dropped first. Only whole-line
        ones: a `//` in the middle of a line is part of a URL far more often than it is
        a comment, and these files are full of URLs.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return $null }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Length -gt $script:BridgeUsageConfig.MaxStateBytes) { return $null }
    $lines = [IO.File]::ReadAllText($Path) -split "`r?`n" |
        Where-Object { $_.TrimStart() -notmatch '^//' }
    ($lines -join "`n") | ConvertFrom-Json
}

function ConvertTo-BridgeUsageInstant {
    <#
        One timestamp as a UTC instant, whatever ConvertFrom-Json left behind.

        A JSON timestamp comes back from ConvertFrom-Json as a local [DateTime], and
        [string] on that yields the machine's short date format - which then reparses
        as local time and moves the reading by the UTC offset. Measured before this
        existed: a cache entry stamped 19:32Z was republished as 02:32Z the next day,
        putting a stale reading seven hours into the future.
    #>
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [DateTime]) { return ([DateTimeOffset]$Value).ToUniversalTime() }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($text, [cultureinfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }
    $null
}

function Get-BridgeUsageWindow {
    <#
        One metered window, in the single shape the card knows how to draw.

        Percent is always "how much is gone", because the three vendors disagree:
        Copilot reports what remains, Codex and Claude what is used. Normalising here
        rather than in the card means a vendor changing its mind is a change in one
        place.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][double]$PercentUsed,
        [AllowNull()][System.Nullable[double]]$Used = $null,
        [AllowNull()][System.Nullable[double]]$Limit = $null,
        [AllowEmptyString()][string]$Unit = '',
        [AllowNull()][object]$ResetsAt = $null,
        [AllowNull()][object]$StartedAt = $null
    )

    $percent = [Math]::Round([Math]::Max(0.0, $PercentUsed), 1)
    $resetsAtUtc = ConvertTo-BridgeUsageInstant $ResetsAt
    $startedAtUtc = ConvertTo-BridgeUsageInstant $StartedAt
    $resets = if ($null -eq $resetsAtUtc) { '' } else { $resetsAtUtc.ToString('o') }
    $window = [ordered]@{
        key     = $Key
        label   = $Label
        percent = $percent
    }
    if ($null -ne $Used) { $window.used = $Used }
    if ($null -ne $Limit) { $window.limit = $Limit }
    if ($Unit) { $window.unit = $Unit }
    if ($resets) { $window.resets_at = $resets }

    # How far through the window we are, so the card can say whether the spend is
    # ahead of the clock. Only meaningful when both ends are known: a Codex window
    # reports when it resets but not when it began, and guessing the start from the
    # window length would quietly turn a rolling window into a fixed one.
    if ($null -ne $resetsAtUtc -and $null -ne $startedAtUtc -and $resetsAtUtc -gt $startedAtUtc) {
        $span = ($resetsAtUtc - $startedAtUtc).TotalSeconds
        $gone = ([DateTimeOffset]::UtcNow - $startedAtUtc).TotalSeconds
        $window.elapsed = [Math]::Round(100.0 * [Math]::Min(1.0, [Math]::Max(0.0, $gone / $span)), 1)
    }
    $window
}

function New-BridgeUsageRecord {
    param(
        [Parameter(Mandatory)][string]$Client,
        [AllowEmptyString()][string]$Account = '',
        [AllowEmptyString()][string]$Plan = '',
        [AllowEmptyString()][string]$Source = '',
        [AllowEmptyCollection()][object[]]$Windows = @(),
        # Not $Error: a parameter of that name would shadow the automatic variable
        # inside every catch in this file.
        [AllowEmptyString()][string]$Problem = '',
        [AllowEmptyString()][string]$MeasuredAt = ''
    )

    # The headline is the window closest to running out, not the first one: a weekly
    # allowance at 90% matters more than a session window at 2%, and the summary line
    # has room for exactly one number.
    $headline = $null
    foreach ($window in @($Windows)) {
        if ($null -eq $headline -or $window.percent -gt $headline) { $headline = [double]$window.percent }
    }

    [ordered]@{
        client      = $Client
        label       = Get-BridgeUsageLabel -Client $Client
        account     = $Account
        plan        = $Plan
        source      = $Source
        windows     = @($Windows)
        percent     = if ($null -eq $headline) { $null } else { $headline }
        error       = $Problem
        measured_at = if ($MeasuredAt) { $MeasuredAt } else { [DateTimeOffset]::UtcNow.ToString('o') }
    }
}

function Invoke-BridgeUsageRequest {
    <#
        One vendor call, with the test boundary asserted before anything leaves.

        Separate from its callers so a test can replace the whole transport with one
        stub and still exercise the parsing, which is where the shapes differ and
        where the bugs are.
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    Assert-BridgeHttpAllowed -Uri $Uri -Transport Rest
    Invoke-RestMethod -Uri $Uri -Headers $Headers -TimeoutSec $script:BridgeUsageConfig.RequestTimeout
}

function Get-BridgeCopilotStatePath {
    <#
        Where Copilot CLI keeps the two files this reads.

        Probed rather than computed: the config directory is `~/.copilot` everywhere,
        but the cache that backs it sits wherever the platform puts application data,
        and the CLI has moved it before. The first that exists wins, and none existing
        is simply "Copilot has not run here".
    #>
    param([ValidateSet('Config', 'Cache')][string]$Kind = 'Config')

    if ($Kind -eq 'Config') {
        $path = Join-Path $HOME '.copilot/config.json'
        if ([IO.File]::Exists($path)) { return $path }
        return ''
    }

    $roots = @()
    if ($env:LOCALAPPDATA) { $roots += (Join-Path $env:LOCALAPPDATA 'copilot') }
    $roots += @(
        (Join-Path $HOME 'Library/Application Support/copilot')
        (Join-Path $HOME '.local/share/copilot')
        (Join-Path $HOME '.copilot')
    )
    foreach ($root in $roots) {
        $candidate = Join-Path $root 'copilot-user-cache.json'
        if ([IO.File]::Exists($candidate)) { return $candidate }
    }
    ''
}

function Get-BridgeCopilotAccount {
    <#
        The account whose allowance is the one being spent here.

        `loggedInUsers` rather than every login the cache has ever seen: a token picked
        up from the environment leaves a second entry behind, and reporting a personal
        account's untouched allowance beside the work one it is not spending is worse
        than reporting nothing.
    #>
    param([AllowEmptyString()][string]$ConfigPath = (Get-BridgeCopilotStatePath -Kind Config))

    $config = Read-BridgeUsageJson -Path $ConfigPath
    if (-not $config) { return $null }

    $logins = @()
    if ($config.PSObject.Properties['loggedInUsers']) {
        foreach ($user in @($config.loggedInUsers)) {
            if ($user -and $user.PSObject.Properties['login'] -and $user.login) {
                $logins += [pscustomobject]@{
                    Login = [string]$user.login
                    Host  = if ($user.PSObject.Properties['host']) { [string]$user.host } else { 'https://github.com' }
                }
            }
        }
    }
    if ($logins.Count -eq 0) { return $null }
    if ($logins.Count -eq 1) { return $logins[0] }

    if ($config.PSObject.Properties['lastLoggedInUser'] -and $config.lastLoggedInUser -and
        $config.lastLoggedInUser.PSObject.Properties['login']) {
        $last = [string]$config.lastLoggedInUser.login
        foreach ($login in $logins) { if ($login.Login -ceq $last) { return $login } }
    }
    $logins[0]
}

function Get-BridgeCopilotToken {
    <#
        The token Copilot CLI itself would use, so the quota read is the same account's.

        Never logged, never published, and never written anywhere: it is read, used for
        one request and dropped. An absent token is not an error - the cache fallback
        below covers it - so every lookup here fails quietly.

        The environment variables come first because the CLI honours them first, so a
        machine driven that way would otherwise be read as a different account than the
        one actually spending.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Login, [string]$HostUrl = 'https://github.com')

    foreach ($name in @('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    if ([string]::IsNullOrWhiteSpace($Login)) { return '' }

    # Stored by the CLI under the account it belongs to, so a machine signed in to two
    # accounts hands back the right one rather than whichever was written last.
    $account = "${HostUrl}:$Login"
    try {
        if ($script:BridgeIsWindows) {
            Add-BridgeCompiledType -TypeName 'BridgeCredentialStore' -Source @'
using System;
using System.Runtime.InteropServices;

public static class BridgeCredentialStore
{
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredReadW(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public uint Flags;
        public uint Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    public static string Read(string target)
    {
        IntPtr handle;
        if (!CredReadW(target, 1, 0, out handle)) { return null; }
        try
        {
            CREDENTIAL credential = (CREDENTIAL)Marshal.PtrToStructure(handle, typeof(CREDENTIAL));
            if (credential.CredentialBlob == IntPtr.Zero) { return null; }
            return Marshal.PtrToStringUni(credential.CredentialBlob, (int)(credential.CredentialBlobSize / 2));
        }
        finally { CredFree(handle); }
    }
}
'@
            $stored = [BridgeCredentialStore]::Read("$account.copilot-cli")
            if (-not [string]::IsNullOrWhiteSpace($stored)) { return $stored }
        }
        else {
            $found = Invoke-BridgeCommandProbe -Executable 'security' `
                -Arguments @('find-generic-password', '-s', 'copilot-cli', '-a', $account, '-w') -TimeoutMs 5000
            if ($found.Ran -and -not $found.TimedOut -and $found.ExitCode -eq 0) {
                $value = ([string]$found.Output).Trim()
                if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
            }
        }
    }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
    }
    ''
}

function ConvertFrom-BridgeCopilotQuota {
    <#
        Turns one `/copilot_internal/user` body into the shared record shape.

        Only `premium_interactions` is drawn. The other two snapshots on an enterprise
        seat report `unlimited: true` with a zero entitlement, so charting them is a
        bar that is always empty next to the one number that can actually run out.
    #>
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][string]$Source,
        [AllowEmptyString()][string]$MeasuredAt = ''
    )

    if (-not $Response -or -not $Response.PSObject.Properties['quota_snapshots']) { return $null }
    $snapshots = $Response.quota_snapshots
    if (-not $snapshots -or -not $snapshots.PSObject.Properties['premium_interactions']) { return $null }
    $premium = $snapshots.premium_interactions
    if (-not $premium -or -not $premium.PSObject.Properties['entitlement']) { return $null }

    $limit = [double]$premium.entitlement
    if ($limit -le 0) { return $null }
    $remaining = if ($premium.PSObject.Properties['remaining']) { [double]$premium.remaining } else { 0.0 }
    $used = [Math]::Max(0.0, $limit - $remaining)

    $resetsAt = ConvertTo-BridgeUsageInstant $(
        if ($Response.PSObject.Properties['quota_reset_date_utc']) { $Response.quota_reset_date_utc } else { $null })
    # The allowance is monthly and resets on the first, so the window it belongs to
    # began a month before it ends. Derived from the reset date rather than from
    # today, so the pace reading survives being taken on the first of the month.
    $started = if ($null -eq $resetsAt) { $null } else { $resetsAt.AddMonths(-1) }

    # $stamp, not $measuredAt: variable names are case-insensitive, so that would be
    # the [string]-typed $MeasuredAt parameter, and assigning an instant to it coerced
    # it to text that then had no ToString($format) to call.
    $measured = $MeasuredAt
    if (-not $measured -and $premium.PSObject.Properties['timestamp_utc']) {
        $stamp = ConvertTo-BridgeUsageInstant $premium.timestamp_utc
        if ($null -ne $stamp) { $measured = $stamp.ToString('o') }
    }

    $window = Get-BridgeUsageWindow -Key 'plan' -Label 'Plan' -PercentUsed (100.0 * $used / $limit) `
        -Used $used -Limit $limit -Unit 'AIC' -ResetsAt $resetsAt -StartedAt $started

    New-BridgeUsageRecord -Client 'copilot' -Source $Source -MeasuredAt $measured `
        -Account $(if ($Response.PSObject.Properties['login']) { [string]$Response.login } else { '' }) `
        -Plan $(if ($Response.PSObject.Properties['copilot_plan']) { [string]$Response.copilot_plan } else { '' }) `
        -Windows @($window)
}

function Get-BridgeCopilotAllowance {
    <#
        Copilot's monthly AI-credit allowance.

        Asked of GitHub directly rather than read from the CLI's own cache, because
        that cache is only refreshed when a session starts: measured thirteen minutes
        stale, and already disagreeing with the live figure, in the middle of an active
        session. The cache is still the fallback, since a stale number with its age
        attached beats an empty card on a machine with no token to hand.
    #>
    param(
        [AllowEmptyString()][string]$ConfigPath = (Get-BridgeCopilotStatePath -Kind Config),
        [AllowEmptyString()][string]$CachePath = (Get-BridgeCopilotStatePath -Kind Cache),
        # Resolving the credential and spending it are separate so a test can supply
        # one without a credential store, and so the token never has to be a parameter
        # anything could log.
        [scriptblock]$ResolveToken = {
            param($Login, $HostUrl)
            Get-BridgeCopilotToken -Login $Login -HostUrl $HostUrl
        },
        [scriptblock]$Fetch = {
            param($Token)
            Invoke-BridgeUsageRequest -Uri 'https://api.github.com/copilot_internal/user' -Headers @{
                Authorization = "token $Token"
                Accept        = 'application/json'
                'User-Agent'  = $script:BridgeUsageConfig.UserAgent
            }
        }
    )

    $account = Get-BridgeCopilotAccount -ConfigPath $ConfigPath
    if (-not $account) { return $null }

    $failure = ''
    $token = ''
    try { $token = [string](& $ResolveToken $account.Login $account.Host) }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        $failure = "The Copilot credential could not be read: $($_.Exception.Message)"
    }
    if ($token) {
        try {
            $record = ConvertFrom-BridgeCopilotQuota -Response (& $Fetch $token) -Source 'api'
            if ($record) { return $record }
            $failure = 'GitHub returned no premium-interaction quota for this account.'
        }
        catch {
            if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
            $failure = "The Copilot quota could not be read: $($_.Exception.Message)"
        }
    }

    $cache = Read-BridgeUsageJson -Path $CachePath
    if ($cache -and $cache.PSObject.Properties['copilotUserCache']) {
        $newest = $null
        $newestAt = [DateTimeOffset]::MinValue
        foreach ($property in $cache.copilotUserCache.PSObject.Properties) {
            $entry = $property.Value
            if (-not $entry -or -not $entry.PSObject.Properties['response']) { continue }
            $response = $entry.response
            if (-not $response -or -not $response.PSObject.Properties['login']) { continue }
            if ([string]$response.login -cne $account.Login) { continue }
            $at = ConvertTo-BridgeUsageInstant $(
                if ($entry.PSObject.Properties['retrievedAt']) { $entry.retrievedAt } else { $null })
            if ($null -ne $at -and $at -gt $newestAt) {
                $newestAt = $at
                $newest = $response
            }
        }
        if ($newest) {
            $record = ConvertFrom-BridgeCopilotQuota -Response $newest -Source 'cache' `
                -MeasuredAt $newestAt.ToString('o')
            if ($record) {
                if ($failure) { $record.error = $failure }
                return $record
            }
        }
    }

    if (-not $failure) { $failure = 'No Copilot credential was available and nothing was cached.' }
    New-BridgeUsageRecord -Client 'copilot' -Account $account.Login -Source 'none' -Problem $failure
}

function Get-BridgeClaudeAllowance {
    <#
        Claude's session and weekly windows.

        Claude Code stores its OAuth token in the clear next to its settings, which is
        what makes this readable at all; it is used for the one usage call and nothing
        else.

        The token is never refreshed, and an expired one is not spent. Refreshing is
        the CLI's business: Anthropic issues a new refresh token with each use and
        retires the old one, so a refresh from here would either strand Claude Code
        with a dead token - signing the user out - or race its own write of the new
        one. Since it expires roughly hourly, that is the common case rather than the
        edge case, and it is handled by saying nothing: the published sensor is
        retained, so the last good reading stays on the card and simply ages, which is
        what the card already shows for Codex.
    #>
    param(
        [AllowEmptyString()][string]$StatePath = (Join-Path $HOME '.claude/.credentials.json'),
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,
        [scriptblock]$Fetch = {
            param($Token)
            Invoke-BridgeUsageRequest -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers @{
                Authorization    = "Bearer $Token"
                'anthropic-beta' = 'oauth-2025-04-20'
                Accept           = 'application/json'
                'User-Agent'     = $script:BridgeUsageConfig.UserAgent
            }
        }
    )

    $credentials = Read-BridgeUsageJson -Path $StatePath
    if (-not $credentials -or -not $credentials.PSObject.Properties['claudeAiOauth']) { return $null }
    $oauth = $credentials.claudeAiOauth
    if (-not $oauth -or -not $oauth.PSObject.Properties['accessToken'] -or
        [string]::IsNullOrWhiteSpace([string]$oauth.accessToken)) {
        return $null
    }
    $plan = if ($oauth.PSObject.Properties['subscriptionType']) { [string]$oauth.subscriptionType } else { '' }

    # Spending an expired token costs a round trip to be told so, and a 401 counts
    # against the account like any other failed authentication.
    if ($oauth.PSObject.Properties['expiresAt'] -and $oauth.expiresAt) {
        $expiresAt = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$oauth.expiresAt)
        if ($expiresAt -le $Now) { return $null }
    }

    try {
        $response = & $Fetch ([string]$oauth.accessToken)
    }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        # A refused token is the expiry above arriving a moment early, not a fault to
        # report: the retained reading carries on and ages.
        if ("$($_.Exception.Message)" -match '\b401\b|Unauthorized') { return $null }
        return New-BridgeUsageRecord -Client 'claude' -Plan $plan -Source 'none' `
            -Problem "The Claude usage could not be read: $($_.Exception.Message)"
    }

    # `limits` is the list Claude Code itself draws, and every entry in it applies to
    # this plan - including the session window, which reads 0% and inactive whenever
    # no five-hour window is open. Dropping those hid the session limit entirely for
    # anyone who had not used Claude in the last few hours, which looked like Claude
    # having only a weekly cap.
    $started = $null
    if ($response.PSObject.Properties['seven_day_breakdown'] -and $response.seven_day_breakdown -and
        $response.seven_day_breakdown.PSObject.Properties['window_started_at']) {
        $started = $response.seven_day_breakdown.window_started_at
    }
    $windows = @()
    if ($response.PSObject.Properties['limits']) {
        foreach ($limit in @($response.limits)) {
            if (-not $limit -or -not $limit.PSObject.Properties['percent']) { continue }
            if ($null -eq $limit.percent) { continue }
            $kind = if ($limit.PSObject.Properties['kind']) { [string]$limit.kind } else { 'limit' }
            $percent = [double]$limit.percent
            $label = switch ($kind) {
                'session' { 'Session (5h)' }
                'weekly_all' { 'Weekly' }
                'weekly_opus' { 'Weekly (Opus)' }
                default { (($kind -replace '_', ' ') -replace '^.', { $args[0].Value.ToUpperInvariant() }) }
            }
            $resets = $null
            if ($limit.PSObject.Properties['resets_at'] -and $limit.resets_at) { $resets = $limit.resets_at }
            $windows += Get-BridgeUsageWindow -Key $kind -Label $label -PercentUsed $percent `
                -ResetsAt $resets -StartedAt $(if ($kind -like 'weekly*') { $started } else { $null })
        }
    }
    if ($windows.Count -eq 0) { return $null }

    New-BridgeUsageRecord -Client 'claude' -Plan $plan -Source 'api' -Windows $windows
}

function Get-BridgeCodexAllowance {
    <#
        Codex's two rate-limit windows, read from its own transcripts.

        There is no endpoint to ask: Codex learns its limits from the headers on the
        replies it gets, and the only record of them is the `token_count` event it
        writes into the session file as it goes. So this is the newest figure Codex
        itself has seen, and it ages between runs - which is why the record carries
        when it was measured and the card says so.
    #>
    param([AllowEmptyString()][string]$SessionRoot = (Join-Path $HOME '.codex/sessions'))

    if ([string]::IsNullOrWhiteSpace($SessionRoot) -or -not (Test-Path -LiteralPath $SessionRoot -PathType Container)) {
        return $null
    }

    # Newest first, and only a handful: a session that ended without ever being told
    # its limits has no such event, so the search has to be allowed to walk back a
    # little - but not through years of transcripts.
    $files = @(Get-ChildItem -LiteralPath $SessionRoot -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 5)
    foreach ($file in $files) {
        if ($file.Length -gt $script:BridgeUsageConfig.MaxStateBytes) { continue }
        $lines = @([IO.File]::ReadAllLines($file.FullName))
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $line = $lines[$i]
            if ($line -notmatch '"rate_limits"') { continue }
            $event = $null
            try { $event = $line | ConvertFrom-Json } catch { continue }
            if (-not $event -or -not $event.PSObject.Properties['payload']) { continue }
            $payload = $event.payload
            if (-not $payload -or -not $payload.PSObject.Properties['rate_limits']) { continue }
            $limits = $payload.rate_limits
            if (-not $limits) { continue }

            $windows = @()
            foreach ($pair in @(
                    @{ Name = 'primary'; Key = 'primary'; Label = '5h limit' },
                    @{ Name = 'secondary'; Key = 'secondary'; Label = 'Weekly' })) {
                if (-not $limits.PSObject.Properties[$pair.Name]) { continue }
                $limit = $limits.($pair.Name)
                if (-not $limit -or -not $limit.PSObject.Properties['used_percent']) { continue }
                $label = $pair.Label
                if ($limit.PSObject.Properties['window_minutes'] -and $limit.window_minutes) {
                    $minutes = [double]$limit.window_minutes
                    $label = if ($minutes -ge 10080) { 'Weekly' }
                        elseif ($minutes -ge 1440) { "$([Math]::Round($minutes / 1440))d limit" }
                        else { "$([Math]::Round($minutes / 60))h limit" }
                }
                $resets = $null
                if ($limit.PSObject.Properties['resets_at'] -and $limit.resets_at) {
                    $resets = [DateTimeOffset]::FromUnixTimeSeconds([long]$limit.resets_at)
                }
                $windows += Get-BridgeUsageWindow -Key $pair.Key -Label $label `
                    -PercentUsed ([double]$limit.used_percent) -ResetsAt $resets
            }
            if ($windows.Count -eq 0) { continue }

            $measured = ''
            if ($event.PSObject.Properties['timestamp']) {
                $at = ConvertTo-BridgeUsageInstant $event.timestamp
                if ($null -ne $at) { $measured = $at.ToString('o') }
            }
            return New-BridgeUsageRecord -Client 'codex' -Source 'transcript' -Windows $windows -MeasuredAt $measured `
                -Plan $(if ($limits.PSObject.Properties['plan_type']) { [string]$limits.plan_type } else { '' })
        }
    }
    $null
}

function Get-BridgeAgentAllowance {
    <#
        One record per configured client that could say anything about itself.

        A client that is selected but has never run here returns nothing and is left
        off the card entirely, rather than drawn as an empty bar: "no data" and "none
        used" look identical as a progress bar and mean opposite things.
    #>
    param([AllowEmptyCollection()][string[]]$Clients = @())

    $records = @()
    foreach ($client in @($Clients)) {
        try {
            $record = switch ($client) {
                'copilot' { Get-BridgeCopilotAllowance }
                'claude' { Get-BridgeClaudeAllowance }
                'codex' { Get-BridgeCodexAllowance }
                default { $null }
            }
            if ($record) { $records += $record }
        }
        catch {
            if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
            $records += New-BridgeUsageRecord -Client $client -Source 'none' `
                -Problem "Usage for $client could not be collected: $($_.Exception.Message)"
        }
    }
    # Emitted as items, not as one array object: callers write @(Get-BridgeAgentAllowance),
    # and a `,@(...)` return nests inside that rather than unwrapping.
    $records
}

function Sync-DaemonUsage {
    <#
        Publishes this machine's usage, at most every configured interval.

        Off by default for nobody: the figures are already on the dashboard's own
        machine, and `usage.publish: false` turns it off for anyone who would rather
        not have an allowance on a screen. The signature check keeps an unchanged
        reading off the MQTT bus between polls, which matters because every publish is
        retained.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    if (-not [bool](Get-BridgeSetting 'usage.publish' $true)) { return $false }
    $interval = [double](Get-BridgeSetting 'usage.intervalSeconds' $script:BridgeUsageConfig.IntervalSeconds)
    if (($Now - $script:DaemonUsageCheckedAt).TotalSeconds -lt $interval) { return $false }
    $script:DaemonUsageCheckedAt = $Now

    $clients = Get-BridgeSelectedClients
    if ($null -eq $clients) { $clients = @('copilot', 'claude', 'codex') }
    $clients = @($clients | Where-Object { $_ -ne 'mcp' })
    if ($clients.Count -eq 0) { return $false }

    try {
        $records = @(Get-BridgeAgentAllowance -Clients $clients)
    }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        Write-DaemonLog -Message "usage collection failed: $($_.Exception.Message)"
        return $false
    }
    if ($records.Count -eq 0) { return $false }

    # Everything except when it was taken, so a poll that found no change does not
    # republish a retained message every two minutes for the sake of a new timestamp.
    $signature = ($records | ForEach-Object {
        @($_.client, $_.account, $_.source, $_.error, ($_.windows | ForEach-Object { "$($_.key)=$($_.percent)" })) -join '|'
    }) -join ';'
    if ($signature -ceq $script:DaemonUsageSignature) { return $false }

    try {
        Publish-CopilotMqttUsage -Records $records -Headers $Headers
        $script:DaemonUsageSignature = $signature

        # Home Assistant ignores object_id on an MQTT entity and names it after the
        # device, so the ids the dashboard was built around have to be forced. Done
        # when the set of clients changes rather than on every publish: the correction
        # needs the whole entity registry, which is thousands of rows, while the
        # reading itself changes every few minutes on a busy machine.
        $published = (@($records | ForEach-Object { [string]$_.client } | Sort-Object -Unique)) -join ','
        if ($published -cne $script:DaemonUsageEntityIds) {
            [void](Set-CopilotMqttUsageEntityIds -Clients @($records | ForEach-Object { [string]$_.client }))
            $script:DaemonUsageEntityIds = $published
        }
        return $true
    }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        Write-DaemonLog -Message "usage could not be published: $($_.Exception.Message)"
        return $false
    }
}
