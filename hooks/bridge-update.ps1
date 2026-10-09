<#
.SYNOPSIS
    Update checking and self-update for the bridge.

.DESCRIPTION
    Installs are a clone plus install.ps1, so without this there is no way to learn
    that a newer version exists short of watching the repository. The daemon checks
    GitHub's releases a few times a day and publishes the result as a Home Assistant
    `update` entity, which is the native surface for exactly this: it shows the
    installed and latest versions, links the release notes, and appears in Home
    Assistant's own Updates list.

    The update entity is published **without** a command topic on purpose. Home
    Assistant sends an MQTT install command that nothing here is subscribed to, and it
    reports no state change when it does - verified against a live instance - so an
    Install button on that entity would silently do nothing. The action lives on a
    separate button entity instead, which the daemon watches with the same press
    timestamp mechanism the Submit button already uses.

    Nothing installs itself. The check is passive and the install is a deliberate
    press, because this software types into terminals and writes scheduled tasks.
#>

Set-StrictMode -Version Latest

$script:BridgeUpdateConfig = @{
    CacheFile     = Get-BridgeRuntimePath 'agent-bridge-update.json'
    # How often to check GitHub for a new release. Four times a day catches a release
    # within a few hours and still barely touches the unauthenticated GitHub rate
    # limit (60/hour/IP). Tunable with updates.checkHours in the config.
    CheckHours    = [double](Get-BridgeSetting 'updates.checkHours' 6)
    # How long a check that could not reach GitHub is believed for. A rate-limited or
    # briefly unreachable API used to be cached like an answer, so one bad moment hid
    # a release for the full six hours - which is exactly what happened on the day
    # 1.14.0 shipped, when checking repeatedly while publishing exhausted the
    # unauthenticated limit and every machine then reported itself up to date. Short
    # enough to recover on its own, long enough not to hammer anything.
    RetryMinutes  = 15
    UserAgent     = 'agent-ha-bridge'
    RequestTimeout = 15
}

function Get-BridgeInstalledVersion {
    <#
        The installed version, recorded at install time. Falls back to the VERSION
        file beside the hooks when running from a clone.
    #>
    param([switch]$Refresh)

    $recorded = Get-BridgeSetting 'updates.installedVersion' ''
    if ($Refresh) {
        # A surviving daemon's in-memory config predates an in-place update, including
        # one that changed the version record and then failed. Do not report rollback.
        $path = (Get-BridgeInstallContext).ConfigPath
        if (Test-BridgeTestExecution) { Assert-BridgeTestPath -Path $path }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'The installed version record is unavailable; configuration is missing.' }
        $current = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $recorded = if ($current['updates'] -is [Collections.IDictionary]) {
            $current['updates']['installedVersion']
        } else { '' }
        if ($null -ne $recorded -and $recorded -isnot [string]) {
            throw 'The recorded installed version is not a string.'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($recorded)) { return $recorded }

    foreach ($candidate in @(
        (Join-Path $PSScriptRoot 'VERSION'),
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'VERSION')
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return (Get-Content -LiteralPath $candidate -Raw).Trim()
        }
    }
    '0.0.0'
}

function Get-BridgeUpdateRepository {
    $repository = Get-BridgeSetting 'updates.repository' ''
    if ([string]::IsNullOrWhiteSpace($repository)) { $repository = 'danswett/agent-ha-bridge' }
    # A config written before the rename still names danswett/copilot-ha-bridge, which
    # only resolves because GitHub redirects a renamed repository - and that redirect
    # lasts exactly as long as nobody else registers the old name. Since this decides
    # what Invoke-BridgeSelfUpdate downloads and runs, it is corrected here too, not
    # only by install.ps1: a daemon can read a stale config for months before anyone
    # re-runs the installer.
    if ($repository -eq 'danswett/copilot-ha-bridge') { $repository = 'danswett/agent-ha-bridge' }
    $repository
}

function ConvertTo-BridgeVersion {
    <# Tags are published as v1.2.3; anything unparseable sorts as 0.0.0. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $clean = ([string]$Text).Trim().TrimStart('v', 'V')
    # Drop any pre-release or build suffix: [version] cannot parse 1.2.3-beta.1.
    $clean = ($clean -split '[-+]')[0]
    $parsed = [version]'0.0.0'
    if ([version]::TryParse($clean, [ref]$parsed)) { return $parsed }
    [version]'0.0.0'
}

function Test-BridgeUpdateRelease {
    param([AllowNull()]$Release)

    if ($null -eq $Release) { return $false }
    foreach ($name in @('Tag', 'Url', 'Zip')) {
        if (-not $Release.PSObject.Properties[$name] -or $Release.$name -isnot [string]) { return $false }
    }
    if ($Release.Tag -notmatch '^[vV]?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.+-]+)?$') { return $false }
    $parsed = $null
    if (-not [version]::TryParse((($Release.Tag -replace '^[vV]', '') -split '[-+]')[0], [ref]$parsed)) { return $false }
    foreach ($name in @('Url', 'Zip')) {
        $uri = $null
        if (-not [Uri]::TryCreate($Release.$name, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -notin @('https', 'http') -or $uri.UserInfo) { return $false }
    }
    $true
}

function ConvertTo-BridgeUpdateTime {
    param([AllowNull()]$Value)

    # ConvertFrom-Json can materialize ISO stamps as DateTime; a string cast then
    # loses Kind/offset and makes a fresh receipt appear hours old or in the future.
    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [DateTime]) { return [DateTimeOffset]$Value }
    $parsed = [DateTimeOffset]::MinValue
    if ($Value -is [string] -and [DateTimeOffset]::TryParse($Value, [ref]$parsed)) { return $parsed }
    throw [FormatException]::new('The update timestamp is invalid.')
}

function Get-BridgeHttpErrorDetail {
    <#
        The response body of a failed web call, or '' when there is none.

        GitHub says some things only in the body. A secondary rate limit answers 403
        with no X-RateLimit-Remaining: 0 and no Retry-After, and only the message says
        which it was - and that distinction decides whether the next thing this does is
        wait or make another request GitHub has asked it not to make.
    #>
    param([AllowNull()]$ErrorRecord)

    if ($null -eq $ErrorRecord) { return '' }
    $parts = @()
    try {
        if ($null -ne $ErrorRecord.PSObject.Properties['ErrorDetails'] -and $ErrorRecord.ErrorDetails) {
            $parts += [string]$ErrorRecord.ErrorDetails.Message
        }
    }
    catch { $parts = $parts }
    try {
        if ($null -ne $ErrorRecord.PSObject.Properties['Exception'] -and $ErrorRecord.Exception) {
            $parts += [string]$ErrorRecord.Exception.Message
        }
    }
    catch { $parts = $parts }
    ($parts | Where-Object { $_ }) -join ' '
}

function Get-BridgeRateLimitWait {
    <#
        Whether a failed GitHub call was refused for rate limiting, and when it can be
        tried again: { Limited, RetryAt, Suffix }.

        403 alone does not mean rate limiting - it is also what a private repository
        and a bad token return - so the headers decide. GitHub sends
        X-RateLimit-Remaining: 0 with the reset as epoch seconds, and 429 with
        Retry-After for secondary limits.

        Worth distinguishing because the remedy is the opposite of the usual one: a
        refused check reads as the machine being broken, so the operator presses the
        button again, which spends more of the allowance that was already exhausted.
    #>
    param([AllowNull()]$Response, [int]$Status = 0, [string]$Detail = '', [int]$Attempt = 1)

    $none = [pscustomobject]@{ Limited = $false; RetryAt = $null; Suffix = ''; Explicit = $false }
    if ($Status -ne 403 -and $Status -ne 429) { return $none }

    $header = {
        param([string]$Name)
        if ($null -eq $Response) { return '' }
        $bag = $null
        try { $bag = $Response.Headers } catch { return '' }
        if ($null -eq $bag) { return '' }
        # HttpResponseMessage carries HttpResponseHeaders, which has no indexer at all -
        # reading it like a dictionary throws, and the whole rate-limit signal would
        # then be silently missed on the one status that matters most, a 403 carrying
        # X-RateLimit-Remaining: 0. Other transports hand back something dictionary-like
        # with no TryGetValues, so both are tried.
        try {
            $values = $null
            if ($bag.PSObject.Methods['TryGetValues'] -and $bag.TryGetValues($Name, [ref]$values)) {
                return [string](@($values) | Select-Object -First 1)
            }
        }
        catch { }
        try {
            $direct = $bag[$Name]
            if ($null -ne $direct) { return [string](@($direct) | Select-Object -First 1) }
        }
        catch { }
        ''
    }

    $remaining = & $header 'X-RateLimit-Remaining'
    $retryAfter = & $header 'Retry-After'
    $reset = & $header 'X-RateLimit-Reset'

    # A secondary limit answers 429 with Retry-After and no remaining count, so either
    # signal on its own is enough.
    #
    # It can also answer 403 with neither: a nonzero remaining count, no Retry-After,
    # and only the body saying which it was. Reading that as a credential problem and
    # immediately asking again is the one response GitHub explicitly warns can get the
    # caller banned, so the message is believed here too.
    $secondary = $Status -eq 403 -and $Detail -match 'secondary rate limit'
    $limited = ($remaining -eq '0') -or ($Status -eq 429) -or ($retryAfter -ne '') -or $secondary
    if (-not $limited) { return $none }

    $retryAt = $null
    $explicit = $false
    $seconds = 0
    if ($retryAfter -and [int]::TryParse($retryAfter, [ref]$seconds) -and $seconds -gt 0) {
        $retryAt = [DateTimeOffset]::Now.AddSeconds($seconds)
        $explicit = $true
    }
    else {
        # X-RateLimit-Reset belongs to the primary bucket and is sent on every reply,
        # including a secondary-limit refusal that still has allowance left. Taking it
        # then names a time that has nothing to do with what was refused - and, being
        # treated as an answer from GitHub, cancels the backoff the secondary limit
        # needs. So it counts only when the primary allowance is actually gone, which
        # is the order GitHub documents: Retry-After, then reset if remaining is zero,
        # otherwise wait a minute and back off. Raised by Codex on #157.
        $epoch = 0L
        if ($remaining -eq '0' -and $reset -and [long]::TryParse($reset, [ref]$epoch) -and $epoch -gt 0) {
            $retryAt = [DateTimeOffset]::FromUnixTimeSeconds($epoch).ToLocalTime()
            $explicit = $true
        }
        # A secondary limit names no time at all, and neither does a 403 or 429 that
        # arrives without the headers. GitHub asks for an initial wait and then
        # exponentially increasing ones while it keeps answering that way - asking
        # again at a fixed interval is what it warns can earn a ban. So any refusal it
        # gave no time for waits a doubling amount per consecutive refusal, capped at
        # an hour: 1, 2, 4, 8, 16, 32, 60 minutes.
        else {
            $steps = [Math]::Max(0, [Math]::Min($Attempt - 1, 6))
            $minutes = [Math]::Min(60, [Math]::Pow(2, $steps))
            $retryAt = [DateTimeOffset]::Now.AddMinutes($minutes)
        }
    }

    $suffix = if ($null -ne $retryAt) { " until $($retryAt.ToString('HH:mm'))" } else { '' }
    [pscustomobject]@{ Limited = $true; RetryAt = $retryAt; Suffix = $suffix; Explicit = $explicit }
}

function Get-BridgeReleaseRequestHeaders {
    <#
        The headers for a GitHub release lookup, with an optional token.

        Unauthenticated callers get 60 requests an hour per IP. A Dev Box, or anything
        else behind shared egress, can exhaust that without the bridge having made a
        single request of its own - and then every machine behind that address is
        unable to take any release at all (#92).

        The token is read from configuration or the environment and is never logged;
        only whether one was used is ever reported.

        -Anonymous omits it deliberately. A token the machine merely happened to have
        can be expired or revoked - GITHUB_TOKEN expires when its workflow job ends -
        and sending one of those turns a release check that would have succeeded
        unauthenticated into a 401. The caller retries without it on exactly that.
    #>
    param([switch]$Anonymous)

    $headers = @{
        'User-Agent' = $script:BridgeUpdateConfig.UserAgent
        Accept       = 'application/vnd.github+json'
    }
    if ($Anonymous) { return $headers }
    $token = ''
    try { $token = [string](Get-BridgeSetting 'updates.token' '') } catch { $token = '' }
    foreach ($name in @('AGENT_HA_BRIDGE_UPDATE_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')) {
        if (-not [string]::IsNullOrWhiteSpace($token)) { break }
        # The machine very often already holds one of these, and a release check only
        # needs public read. Taking one that is already there is the difference between
        # 60 requests an hour shared with everything else behind the same address and
        # 5,000 of this machine's own - without asking anyone to configure anything.
        $token = [string][Environment]::GetEnvironmentVariable($name)
    }
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        $headers['Authorization'] = "Bearer $($token.Trim())"
    }
    $headers
}

function Get-BridgeReleaseArchiveUri {
    <#
        Where to download a release's source archive from, avoiding the API.

        api.github.com/repos/<r>/zipball/<tag> - what the latest-release response
        offers - is itself an API request, so an unauthenticated download spends the
        same 60-an-hour-per-IP allowance the check does, and is refused with a 403
        once it is gone. Pressing Update in Home Assistant then failed for a reason
        that had nothing to do with this machine and nothing the operator could act on.

        codeload.github.com serves the identical archive and is not part of that
        allowance. Checked against v1.33.8: one root folder, with VERSION and
        install.ps1 inside it, which is exactly what the installer below asserts.
    #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag
    )

    if ($Repository -notmatch '^[\w.-]+/[\w.-]+$') { return '' }
    if ($Tag -notmatch '^[\w.+-]+$') { return '' }
    "https://codeload.github.com/$Repository/zip/refs/tags/$Tag"
}

function Get-BridgeLatestReleaseWithoutApi {
    <#
        The current release, found without spending the API allowance that refused the
        check.

        github.com/<r>/releases/latest answers with a 302 to the release's own page,
        and is not part of that allowance - verified while the unauthenticated pool sat
        at 41/60, which it still did afterwards.

        It is used rather than releases.atom because it is the same selection the API
        makes: newest *published, non-prerelease* release. The feed is ordered by date
        and includes prereleases, so on a repository that ships them its newest entry
        is the wrong answer - PowerShell/PowerShell's feed leads with v7.7.0-preview.5
        while the API and this redirect both say v7.6.6. Taking the feed's first entry
        would have had a rate-limited machine install a preview, and this project
        pushes a release tag while its release is still a draft, so the feed can lead
        with a version whose assets are not attached yet.

        It carries no release notes, so this is deliberately only enough to know which
        release is current and where to get it. A correct version with no notes beats a
        stale one presented as current.
    #>
    param([Parameter(Mandatory)][string]$Repository)

    if ($Repository -notmatch '^[\w.-]+/[\w.-]+$') { return $null }
    $uri = "https://github.com/$Repository/releases/latest"
    Assert-BridgeHttpAllowed -Uri $uri -Transport WebRequest

    $response = $null
    try {
        $response = Invoke-WebRequest -Uri $uri -Headers @{ 'User-Agent' = $script:BridgeUpdateConfig.UserAgent } `
            -MaximumRedirection 0 -TimeoutSec $script:BridgeUpdateConfig.RequestTimeout -ErrorAction Stop
    }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        # The redirect *is* the answer, and PowerShell raises it rather than returning
        # it when told not to follow one. Anything with no response attached is a real
        # failure and is left to the caller.
        if ($null -eq $_.Exception.PSObject.Properties['Response'] -or $null -eq $_.Exception.Response) { throw }
        $response = $_.Exception.Response
    }

    # Both header shapes are read. PowerShell 7 hands back an HttpResponseMessage whose
    # Headers has a Location property; 5.1 and the basic-parsing object index by name
    # instead. Under StrictMode the wrong one of those throws rather than yielding
    # null, which is the most common live crash in this repository.
    $location = ''
    $headers = $null
    if ($null -ne $response -and $null -ne $response.PSObject.Properties['Headers']) { $headers = $response.Headers }
    if ($null -ne $headers) {
        $raw = $null
        try { $raw = $headers.Location } catch { $raw = $null }
        if (-not $raw) { try { $raw = $headers['Location'] } catch { $raw = $null } }
        $location = [string](@($raw) | Where-Object { $_ } | Select-Object -First 1)
    }
    if ([string]::IsNullOrWhiteSpace($location)) { return $null }

    # A repository with no release at all redirects to the releases index, so the tag
    # is taken from the structured path rather than searched for anywhere in the URL.
    $match = [regex]::Match($location, '/releases/tag/(?<tag>[^/?#]+)$')
    if (-not $match.Success) { return $null }
    $tag = [Uri]::UnescapeDataString($match.Groups['tag'].Value)
    if ($tag -notmatch '^[vV]?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.+-]+)?$') { return $null }

    [pscustomobject]@{
        Tag       = $tag
        Name      = $tag
        Url       = "https://github.com/$Repository/releases/tag/$tag"
        Zip       = (Get-BridgeReleaseArchiveUri -Repository $Repository -Tag $tag)
        Notes     = ''
        Published = ''
    }
}
function Get-BridgeLatestRelease {
    <#
        The newest published release, cached so a restart loop cannot hammer GitHub.
        -IncludeStatus retains the lookup result; release/null alone cannot distinguish
        a failed lookup from a latest-release endpoint that answered 404. The default
        release/null interface remains available to older callers.
    #>
    param(
        [switch]$Force,
        [double]$CheckHours = $script:BridgeUpdateConfig.CheckHours,
        [switch]$IncludeStatus
    )

    $cachePath = $script:BridgeUpdateConfig.CacheFile
    if (Test-BridgeTestExecution) { Assert-BridgeTestPath -Path $cachePath }
    $cache = $null
    if (Test-Path -LiteralPath $cachePath) {
        try { $cache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json }
        catch {
            if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
            Write-Warning "The update cache could not be read; checking again: $($_.Exception.Message)"
        }
    }

    $lookup = [pscustomobject]@{ State = 'Unavailable'; Release = $null; Detail = 'The latest release could not be established.'; RetryAt = $null }
    # Carried across checks so a limit that names no time of its own backs off instead
    # of being asked again at the same fixed interval for as long as it lasts.
    $strikes = 0
    if ($null -ne $cache -and $cache.PSObject.Properties['RateLimitStrikes']) {
        $parsed = 0
        if ([int]::TryParse([string]$cache.RateLimitStrikes, [ref]$parsed) -and $parsed -gt 0) { $strikes = $parsed }
    }
    if (-not $Force -and $null -ne $cache -and $cache.PSObject.Properties['CheckedAt']) {
        $checkedAt = $null
        try { $checkedAt = ConvertTo-BridgeUpdateTime $cache.CheckedAt }
        catch [FormatException] { Write-Warning 'The update cache has an invalid check time; checking again.' }
        if ($null -ne $checkedAt) {
            $rateLimitExpired = $false
            $cachedRetryAt = $null
            $cachedRelease = if ($cache.PSObject.Properties['Release']) { $cache.Release } else { $null }
            $reached = $cache.PSObject.Properties['Reached']
            if ((-not $reached -or ($cache.Reached -is [bool] -and $cache.Reached)) -and
                (Test-BridgeUpdateRelease $cachedRelease)) {
                $lookup.State = 'Found'
                $lookup.Release = $cachedRelease
                $lookup.Detail = ''
            }
            elseif ($reached -and $cache.Reached -is [bool] -and $cache.Reached -and $null -eq $cachedRelease) {
                $lookup.State = 'NotFound'
                $lookup.Detail = 'GitHub returned 404 for the latest-release endpoint; repository existence and access are not confirmed.'
            }
            # An old null cache without Reached is unknown, not evidence of a 404.
            elseif ($cache.PSObject.Properties['State'] -and $cache.State -eq 'RateLimited') {
                # Only while the limit it describes has not yet reset: past that the
                # detail names a time that has been and gone, and saying "wait until
                # 09:15" at 09:40 is its own kind of wrong.
                $retryAt = $null
                if ($cache.PSObject.Properties['RetryAt'] -and $cache.RetryAt) {
                    try { $retryAt = ConvertTo-BridgeUpdateTime $cache.RetryAt } catch [FormatException] { $retryAt = $null }
                }
                $cachedRetryAt = $retryAt
                if ($null -eq $retryAt -or $retryAt -gt [DateTimeOffset]::Now) {
                    $lookup.State = 'RateLimited'
                    $lookup.RetryAt = $cache.RetryAt
                    if ($cache.PSObject.Properties['Detail'] -and $cache.Detail) { $lookup.Detail = [string]$cache.Detail }
                }
                else {
                    # Past the reset, this cache entry has nothing left to say, and the
                    # retry window is what decides when to look again. A secondary limit
                    # names a minute and Retry-After often names two, both well inside
                    # the fifteen-minute window - so honouring that window would report
                    # a bare failure for the rest of it, having been told exactly when
                    # the check would work again. Raised by Codex on #157.
                    $rateLimitExpired = $true
                }
            }
            # Rate limiting takes the short retry window too. It is a queue to wait in,
            # not a settled answer, and a refused request costs a negligible part of an
            # already-spent allowance - so the machine recovers on its own within
            # minutes of the limit clearing rather than carrying the verdict for hours.
            $window = if ($lookup.State -in @('Unavailable', 'RateLimited')) {
                [Math]::Min($CheckHours, $script:BridgeUpdateConfig.RetryMinutes / 60)
            } else { $CheckHours }
            # Except that a verdict naming a time further out than that window is held
            # until the time it named. Otherwise the backoff above stops growing at
            # fifteen minutes, and the 16-, 32- and 60-minute waits all become asking
            # again sooner than GitHub allowed. Raised by Codex on #157.
            #
            # Deliberately not bounded by CheckHours: that is how often to look when
            # things are fine, and a configured cadence shorter than the wait would
            # otherwise override an instruction not to ask yet. It is bounded at an
            # hour instead, which is every legitimate case - the primary allowance
            # resets hourly, a secondary limit asks for minutes, and the inferred
            # backoff caps at sixty - so a corrupt or skewed timestamp past that falls
            # back to the ordinary window rather than silencing the check for a day.
            if ($lookup.State -eq 'RateLimited' -and $null -ne $cachedRetryAt -and
                $cachedRetryAt -gt [DateTimeOffset]::Now) {
                $untilRetry = ($cachedRetryAt - $checkedAt).TotalHours
                $window = [Math]::Max($window, [Math]::Min($untilRetry, 1))
            }
            $age = ([DateTimeOffset]::Now - $checkedAt).TotalHours
            if ($age -ge 0 -and $age -lt $window -and -not $rateLimitExpired) {
                if ($IncludeStatus) { return $lookup }
                return $lookup.Release
            }
        }
    }

    $lookup.State = 'Unavailable'
    $lookup.Release = $null
    $lookup.Detail = 'The latest release could not be established.'
    try {
        $repository = Get-BridgeUpdateRepository
        if ($repository -notmatch '^[\w.-]+/[\w.-]+$') { throw 'The update repository must be owner/name.' }
        $uri = "https://api.github.com/repos/$repository/releases/latest"
        Assert-BridgeHttpAllowed -Uri $uri -Transport Rest
        $headers = Get-BridgeReleaseRequestHeaders
        $sentToken = $headers.ContainsKey('Authorization')
        try {
            $response = Invoke-RestMethod -Uri $uri -Headers $headers `
                -TimeoutSec $script:BridgeUpdateConfig.RequestTimeout
        }
        catch {
            if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
            # A token picked up from the environment is not necessarily a good one.
            # GITHUB_TOKEN expires when its workflow job ends, and a revoked or
            # SSO-blocked token answers 401 - so sending one turns a check that would
            # have worked unauthenticated into a failure, on every retry, for a public
            # release anyone can read. Asking again without it costs one request and
            # only happens when credentials were actually the problem.
            #
            # A rate-limited 403 is deliberately not retried here: the allowance, not
            # the credential, is what was refused, and the non-API fallback below is
            # what answers that.
            $failureStatus = 0
            if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                $failureStatus = [int]$_.Exception.Response.StatusCode
            }
            $failureDetail = Get-BridgeHttpErrorDetail -ErrorRecord $_
            $badCredential = $failureStatus -eq 401 -or
                ($failureStatus -eq 403 -and -not (Get-BridgeRateLimitWait -Response $_.Exception.Response `
                    -Status $failureStatus -Detail $failureDetail).Limited)
            if (-not $sentToken -or -not $badCredential) { throw }
            $response = Invoke-RestMethod -Uri $uri -Headers (Get-BridgeReleaseRequestHeaders -Anonymous) `
                -TimeoutSec $script:BridgeUpdateConfig.RequestTimeout
        }

        $release = [pscustomobject]@{
            Tag       = [string]$response.tag_name
            Name      = [string]$response.name
            Url       = [string]$response.html_url
            Zip       = [string]$response.zipball_url
            Notes     = [string]$response.body
            Published = [string]$response.published_at
        }
        # Prefer the archive that is not an API request, so that pressing Update does
        # not spend - or get refused by - the same allowance the check competes for.
        $archive = Get-BridgeReleaseArchiveUri -Repository $repository -Tag $release.Tag
        if ($archive) { $release.Zip = $archive }
        if (-not (Test-BridgeUpdateRelease $release)) { throw 'The latest-release response has invalid version or download metadata.' }
        $lookup.State = 'Found'
        $lookup.Release = $release
        $lookup.Detail = ''
        $strikes = 0
    }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        $httpStatus = 0
        $failureResponse = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $failureResponse = $_.Exception.Response
            $httpStatus = [int]$failureResponse.StatusCode
        }
        $rateLimit = Get-BridgeRateLimitWait -Response $failureResponse -Status $httpStatus `
            -Detail (Get-BridgeHttpErrorDetail -ErrorRecord $_) -Attempt ($strikes + 1)
        # A refusal GitHub gave no time for is the one that has to back off; when it
        # named a reset, that time is the answer and waiting for it ends the loop.
        $strikes = if ($rateLimit.Limited -and -not $rateLimit.Explicit) { $strikes + 1 } else { 0 }
        if ($httpStatus -eq 404) {
            $lookup.State = 'NotFound'
            $lookup.Detail = 'GitHub returned 404 for the latest-release endpoint; repository existence and access are not confirmed.'
        }
        elseif ($rateLimit.Limited) {
            # Not a failure of this machine, and not something retrying will fix. An
            # unauthenticated caller gets 60 requests an hour per IP, so anything behind
            # shared egress can be refused without the bridge having done anything at
            # all - and the bare 403 that used to be reported read as the release being
            # broken rather than as a queue to wait in (#109, #92).
            #
            # Being refused is not the same as not knowing, though. The Atom feed is
            # outside that allowance, so it is asked before the refusal is accepted as
            # an answer. Without this the machine kept publishing whatever version it
            # last managed to read, with the update entity sitting at "off" - a machine
            # days behind looked exactly like one that was current.
            $lookup.State = 'RateLimited'
            $lookup.RetryAt = if ($rateLimit.RetryAt) { $rateLimit.RetryAt.ToString('o') } else { $null }
            $lookup.Detail = "GitHub is rate limiting this machine's release checks$($rateLimit.Suffix). " +
                'The install is fine; the check will work again once the limit resets. ' +
                'Setting updates.token raises the limit.'
            try {
                $fallback = Get-BridgeLatestReleaseWithoutApi -Repository $repository
                if (Test-BridgeUpdateRelease $fallback) {
                    $lookup.State = 'Found'
                    $lookup.Release = $fallback
                    $lookup.RetryAt = $null
                    $lookup.Detail = ''
                    $strikes = 0
                }
            }
            catch {
                if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
                # Keep the rate-limit verdict; the feed is a second chance, not a
                # second thing to report as broken.
            }
        }
        else { $lookup.Detail = "The latest release could not be established: $($_.Exception.Message)" }
    }

    # A 404 is authoritative - GitHub answered - so it is allowed to clear what was
    # known. Anything else never reached GitHub, and Reached=false already stops the
    # cached release being served as a current finding on the next pass.
    #
    # The rate-limit verdict is kept with it. Reached=false alone loses why the check
    # failed, and the daemon re-reads this cache about every fifteen seconds: the one
    # pass that saw the 403 would report the queue to wait in, and every pass after it
    # would say only "could not be established" - which is the reading of a refusal as
    # a broken install that #109 and #92 were about. Its reset time comes too, so a
    # verdict is only reinstated while it is still true.
    [pscustomobject]@{
        CheckedAt = [DateTimeOffset]::Now.ToString('o')
        Reached   = ($lookup.State -in @('Found', 'NotFound'))
        State     = $lookup.State
        Detail    = $lookup.Detail
        RetryAt   = $lookup.RetryAt
        RateLimitStrikes = $strikes
        Release   = $lookup.Release
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding UTF8

    if ($IncludeStatus) { return $lookup }
    $lookup.Release
}

function Get-BridgeUpdateStatus {
    <#
        Compares the installed version with the newest release.

        Always returns an object, so a caller can publish a card whether or not an
        update exists.
    #>
    param([switch]$Force)

    $installed = Get-BridgeInstalledVersion -Refresh
    $lookup = Get-BridgeLatestRelease -Force:$Force -IncludeStatus
    $release = $lookup.Release

    $latest = if ($release) { [string]$release.Tag -replace '^[vV]', '' } else { $null }
    $available = $false
    if ($release) {
        $available = (ConvertTo-BridgeVersion -Text $latest) -gt (ConvertTo-BridgeVersion -Text $installed)
    }

    [pscustomobject]@{
        Installed = $installed
        Latest    = $latest
        Available = $available
        LookupState = $lookup.State
        State     = if ($release) { if ($available) { 'Available' } else { 'Current' } } else { $lookup.State }
        Detail    = $lookup.Detail
        Url       = if ($release) { [string]$release.Url } else { "https://github.com/$(Get-BridgeUpdateRepository)/releases" }
        Notes     = if ($release -and $release.PSObject.Properties['Notes']) { [string]$release.Notes } else { '' }
        Zip       = if ($release) { [string]$release.Zip } else { '' }
    }
}

function Read-BridgeUpdateOutcome {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$AttemptId,
        [string]$Version
    )

    if (Test-BridgeTestExecution) { Assert-BridgeTestPath -Path $Path }
    Assert-BridgeInstallPayload -Root $Path -CheckAncestors
    $record = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    if ($record -isnot [Collections.IDictionary] -or $record['success'] -isnot [bool]) {
        throw 'The update outcome has no Boolean success value.'
    }
    $at = ConvertTo-BridgeUpdateTime $record['at']
    if ($at -gt [DateTimeOffset]::Now.AddMinutes(5)) { throw 'The update outcome completion time is in the future.' }
    $schema = 0
    if ($record.Contains('schemaVersion')) {
        if (($record['schemaVersion'] -isnot [int] -and $record['schemaVersion'] -isnot [long]) -or $record['schemaVersion'] -ne 1) {
            throw 'The update outcome schema is unsupported.'
        }
        $schema = 1
        if ($record['attemptId'] -isnot [string] -or $record['attemptId'] -cnotmatch '^[a-f0-9]{32}$' -or
            ($record['exitCode'] -isnot [int] -and $record['exitCode'] -isnot [long]) -or
            $record['success'] -ne ($record['exitCode'] -eq 0)) {
            throw 'The update outcome has inconsistent attempt or exit information.'
        }
    }
    $allowed = @('success', 'version', 'releaseUrl', 'error', 'at')
    if ($schema) { $allowed += @('schemaVersion', 'attemptId', 'exitCode') }
    if (@($record.Keys | Where-Object { $_ -cnotin $allowed }).Count) { throw 'The update outcome contains unsupported fields.' }
    if ($AttemptId -and ($schema -ne 1 -or $record['attemptId'] -cne $AttemptId)) {
        throw 'The update outcome does not belong to this attempt.'
    }
    $target = if ($record.Contains('version')) { $record['version'] } else { '' }
    if ($target -isnot [string] -or (($schema -eq 1 -or $record['success'] -or $target) -and
        $target -notmatch '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.+-]+)?$')) {
        throw 'The update outcome has no valid attempted version.'
    }
    if ($target) {
        $parsedTarget = $null
        if (-not [version]::TryParse(($target -split '[-+]')[0], [ref]$parsedTarget)) { throw 'The attempted version is not parseable.' }
    }
    if ($Version -and $target -cne $Version) { throw 'The update outcome names a different release.' }
    $url = if ($record.Contains('releaseUrl')) { $record['releaseUrl'] } else { '' }
    $errorText = if ($record.Contains('error')) { $record['error'] } else { '' }
    if ($url -isnot [string] -or $errorText -isnot [string] -or
        (-not $record['success'] -and -not $errorText) -or ($record['success'] -and $errorText)) {
        throw 'The update outcome has invalid release or failure details.'
    }
    if ($url) {
        $uri = $null
        if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -notin @('https', 'http') -or $uri.UserInfo) { throw 'The update outcome release URL is invalid.' }
    }
    [pscustomobject]@{
        SchemaVersion = $schema
        AttemptId = if ($schema) { $record['attemptId'] } else { '' }
        Success = $record['success']
        Version = $target
        ReleaseUrl = $url
        Error = $errorText
        At = $at
    }
}

function Invoke-BridgeSelfUpdate {
    <#
        Downloads the newest release and runs its installer.

        The installer stops and restarts the scheduled task, which kills the daemon,
        so when this is triggered from the daemon it must run detached - otherwise the
        update dies halfway through with the process that started it. -Detached starts
        an independent pwsh and returns immediately.
    #>
    param(
        [switch]$Detached,
        [switch]$Force,
        [string]$TargetHome,
        [string]$InstallRoot,
        # Return the generated updater script instead of writing and launching it, so
        # its content can be verified in tests without downloading or installing.
        [switch]$ScriptOnly
    )

    $status = Get-BridgeUpdateStatus -Force
    $result = [pscustomobject]@{
        Started = $false; Success = $false; State = 'Refused'; AttemptId = ''
        AttemptedVersion = $status.Latest; InstalledVersion = $status.Installed; Detail = ''
    }
    if ($status.PSObject.Properties['LookupState'] -and $status.LookupState -ne 'Found') {
        $result.State = $status.LookupState
        $result.Detail = $status.Detail
        return $result
    }
    if (-not $status.Available -and -not $Force) {
        $result.State = if ($status.PSObject.Properties['State']) { $status.State } else { 'Unavailable' }
        $result.Detail = if ($result.State -eq 'Current') {
            "no newer release found (installed $($status.Installed), latest $($status.Latest))"
        } else { 'The updater did not establish a current release.' }
        return $result
    }
    if ($status.Available -isnot [bool] -or -not $status.PSObject.Properties['Zip'] -or
        -not $status.PSObject.Properties['Url'] -or -not (Test-BridgeUpdateRelease ([pscustomobject]@{
            Tag = $status.Latest; Zip = $status.Zip; Url = $status.Url
        }))) {
        $result.Detail = 'the release has no validated version and downloadable archive'
        return $result
    }

    $resolvedTarget = $TargetHome
    if ($TargetHome) {
        $resolvedTarget = if (Test-Path -LiteralPath $TargetHome -PathType Container) {
            (Resolve-Path -LiteralPath $TargetHome -ErrorAction Stop).Path
        } else { $null }
        if (-not $resolvedTarget -or -not (Test-Path -LiteralPath $resolvedTarget -PathType Container)) {
            $result.Detail = "TargetHome '$TargetHome' is not an existing directory"
            return $result
        }
    }
    $updateContext = if ($TargetHome -or $InstallRoot) { Resolve-BridgeInstallContext -TargetHome $resolvedTarget -BridgeHome $InstallRoot }
        else { Get-BridgeInstallContext }
    $result.AttemptId = [guid]::NewGuid().ToString('N')
    $attemptStartedAt = [DateTimeOffset]::Now
    $staging = Get-BridgeRuntimePath -Name "agent-ha-bridge-update-$($result.AttemptId)" -Context $updateContext
    $script = Join-Path $staging 'run-update.ps1'
    # The daemon claims/removes its own notice. It must never consume the only proof
    # a foreground parent needs, nor may an older notice prove this attempt succeeded.
    $resultPath = if (-not $Detached) {
        Get-BridgeRuntimePath -Name "agent-bridge-update-result-$($result.AttemptId).json" -Context $updateContext
    } else { '' }

    # Validate and single-quote-escape TargetHome before it is written into the
    # generated script, so a value containing a quote cannot alter the command line.
    $targetArgument = ''
    if ($TargetHome) {
        $targetArgument = " -TargetHome '$($resolvedTarget -replace "'", "''")'"
    }
    elseif ($updateContext.Isolated) { $targetArgument = " -TargetHome '$($updateContext.Home.Replace("'", "''"))'" }
    if ($updateContext.Isolated) { $targetArgument += ' -SkipTask -SkipPath -SkipDependencies' }
    $contextArgument = if ($updateContext.Isolated) { " -TargetHome '$($updateContext.Home.Replace("'", "''"))'" } else { '' }
    $rootArgument = " -InstallRoot '$($updateContext.BridgeHome.Replace("'", "''"))'"
    $logPath = Get-BridgeRuntimePath -Name 'agent-bridge-update.log' -Context $updateContext
    $outcomePath = Get-BridgeRuntimePath -Name 'agent-bridge-update-outcome.json' -Context $updateContext
    $scriptText = @"
`$ErrorActionPreference = 'Stop'
`$staging = '$($staging.Replace("'", "''"))'
`$log = '$($logPath.Replace("'", "''"))'
`$outcomeFile = '$($outcomePath.Replace("'", "''"))'
`$resultFile = '$($resultPath.Replace("'", "''"))'
`$env:AGENT_HA_BRIDGE_CONFIG = '$($updateContext.ConfigPath.Replace("'", "''"))'
`$pathsVerified = `$false
trap {
    if (`$_.Exception.Data['BridgeTestWriteBlocked']) { Write-Error -ErrorAction Continue 'BridgeTestWriteBlocked'; exit 78 }
    if (`$_.Exception.Data['BridgeTestNetworkBlocked']) { Write-Error -ErrorAction Continue 'BridgeTestNetworkBlocked'; exit 77 }
    Write-Error -ErrorAction Continue `$_
    exit 1
}
function Write-UpdateLog { param([string]`$Message) Add-Content -LiteralPath `$log -Value ("{0} {1}" -f [DateTimeOffset]::Now.ToString('o'), `$Message) }
function Write-UpdateOutcome {
    param([string]`$Path, [hashtable]`$Outcome)
    if (Test-BridgeTestExecution) { Assert-BridgeTestPath -Path `$Path }
    Assert-BridgeInstallPayload -Root `$Path -CheckAncestors
    `$temporary = "`$Path.$($result.AttemptId).tmp"
    if (Test-BridgeTestExecution) { Assert-BridgeTestPath -Path `$temporary }
    Assert-BridgeInstallPayload -Root `$temporary -CheckAncestors
    `$ownsTemporary = `$false
    try {
        `$stream = [IO.File]::Open(`$temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        `$ownsTemporary = `$true
        try {
            `$bytes = [Text.Encoding]::UTF8.GetBytes((`$Outcome | ConvertTo-Json -Compress))
            `$stream.Write(`$bytes, 0, `$bytes.Length)
        }
        finally { `$stream.Dispose() }
        [IO.File]::Move(`$temporary, `$Path, `$true)
    }
    finally { if (`$ownsTemporary -and (Test-Path -LiteralPath `$temporary)) { Remove-Item -LiteralPath `$temporary -Force -ErrorAction Stop } }
}
`$outcome = @{
    schemaVersion = 1; attemptId = '$($result.AttemptId)'; success = `$false; exitCode = 1
    version = '$($status.Latest)'; releaseUrl = '$($status.Url.Replace("'", "''"))'
    error = ''; at = ''
}

try {
    `$contextLibrary = '$((Join-Path $updateContext.HooksDir 'bridge-install-context.ps1').Replace("'", "''"))'
    foreach (`$path in @((Split-Path `$contextLibrary -Parent), `$contextLibrary)) {
        if ((Get-Item -LiteralPath `$path -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'The updater bootstrap is linked; no installer was run.'
        }
    }
    . `$contextLibrary
    Assert-BridgeTestEnvironment
    `$ownedContext = Resolve-BridgeInstallContext -BridgeHome '$($updateContext.BridgeHome.Replace("'", "''"))'$contextArgument
    if (Test-BridgeTestExecution) {
        `$paths = @(`$staging, `$log, `$outcomeFile, `$env:AGENT_HA_BRIDGE_CONFIG)
        if (`$resultFile) { `$paths += `$resultFile }
        Assert-BridgeTestPath -Path `$paths
    }
    Assert-BridgeInstallPayload -Root `$ownedContext.HooksDir -RelativePaths @('bridge-platform.ps1', 'bridge-test-guard.ps1')
    . '$((Join-Path $updateContext.HooksDir 'bridge-platform.ps1').Replace("'", "''"))'
    . '$((Join-Path $updateContext.HooksDir 'bridge-test-guard.ps1').Replace("'", "''"))'
    `$pathsVerified = `$true
    Write-UpdateLog 'downloading $($status.Latest)'
    `$zip = Join-Path `$staging 'release.zip'
    Assert-BridgeHttpAllowed -Uri '$($status.Zip.Replace("'", "''"))' -Transport WebRequest
    Invoke-WebRequest -Uri '$($status.Zip.Replace("'", "''"))' -OutFile `$zip -Headers @{ 'User-Agent' = 'agent-ha-bridge' } -UseBasicParsing
    Expand-Archive -LiteralPath `$zip -DestinationPath `$staging -Force
    `$roots = @(Get-ChildItem -LiteralPath `$staging -Directory)
    if (`$roots.Count -ne 1) { throw 'the archive did not contain exactly one expected folder' }
    `$root = `$roots[0]
    Assert-BridgeInstallPayload -Root `$root.FullName -RelativePaths @('VERSION', 'install.ps1')
    if (Test-BridgeTestExecution) { Assert-BridgeTestPath -Path `$root.FullName }

    # Verify the downloaded archive really is the release we resolved before running
    # its installer. GitHub source archives are unsigned, so this is not a
    # cryptographic guarantee, but it rejects a corrupt, truncated, or wrong-version
    # archive rather than executing whatever happened to download.
    `$versionFile = Join-Path `$root.FullName 'VERSION'
    if (-not (Test-Path -LiteralPath `$versionFile)) { throw 'the archive has no VERSION file' }
    `$archiveVersion = (Get-Content -LiteralPath `$versionFile -Raw).Trim() -replace '^[vV]', ''
    if (`$archiveVersion -ne '$($status.Latest)') {
        throw "archive version `$archiveVersion does not match the expected release $($status.Latest)"
    }

    Write-UpdateLog "installing from `$(`$root.FullName)"
    # The existing config is preserved and backed up by the installer, so no
    # settings are passed here.
    `$installer = Join-Path `$root.FullName 'install.ps1'
    if (-not (Get-Command `$installer).Parameters.ContainsKey('InstallRoot')) {
        throw 'The release installer cannot preserve this installation root; it was not run.'
    }
    `$global:LASTEXITCODE = 0
    & (Join-Path `$root.FullName 'install.ps1') -NonInteractive -SkipVerify$targetArgument$rootArgument
    if (`$LASTEXITCODE -ne 0) { throw "the installer exited with code `$LASTEXITCODE" }
    # Restart the daemon so the new code and config take effect. The installer cannot:
    # the running daemon is detached and survives the scheduled-task restart. Killing it
    # makes the supervisor relaunch a fresh one, which reads the notice and
    # announces the result.
    Assert-BridgeInstallPayload -Root `$ownedContext.HooksDir -RelativePaths @('bridge-platform.ps1')
    . '$((Join-Path $updateContext.HooksDir 'bridge-platform.ps1').Replace("'", "''"))'
    `$ownedContext = Resolve-BridgeInstallContext -BridgeHome '$($updateContext.BridgeHome.Replace("'", "''"))'$contextArgument
    Stop-BridgeOwnedRuntime -Context `$ownedContext -Roles daemon
    Write-UpdateLog 'installer complete; the daemon was asked to restart, so nothing has checked the install since'
    `$outcome.success = `$true
    `$outcome.exitCode = 0
}
catch {
    if (`$_.Exception.Data['BridgeTestWriteBlocked'] -or `$_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
    if (-not `$pathsVerified) { throw }
    `$failureDetail = `$_.Exception.Message
    # Archive can throw an empty-message FileFormatException whose inner chain
    # still contains the real ZIP failure. ErrorRecord.ToString() is empty too.
    if ([string]::IsNullOrWhiteSpace(`$failureDetail)) { `$failureDetail = `$_.Exception.ToString() }
    Write-UpdateLog "update FAILED: `$failureDetail"
    `$outcome.error = `$failureDetail
}
if (-not `$resultFile) {
    try {
        if (Test-BridgeTestExecution) { Assert-BridgeTestPath -Path `$staging }
        Remove-Item -LiteralPath `$staging -Recurse -Force -ErrorAction Stop
    }
    catch {
        if (`$_.Exception.Data['BridgeTestWriteBlocked'] -or `$_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        Write-UpdateLog "staging cleanup FAILED: `$(`$_.Exception.Message)"
        `$outcome.success = `$false
        `$outcome.exitCode = 1
        `$outcome.error = ("`$(`$outcome.error) Staging cleanup failed: `$(`$_.Exception.Message)").Trim()
    }
}
`$outcome.at = [DateTimeOffset]::Now.ToString('o')
if (`$resultFile) { Write-UpdateOutcome -Path `$resultFile -Outcome `$outcome }
Write-UpdateOutcome -Path `$outcomeFile -Outcome `$outcome
exit `$outcome.exitCode
"@

    if ($ScriptOnly) { return $scriptText }

    # Resolved before anything is written: a bare (Get-Command pwsh).Source throws
    # under StrictMode when the daemon's PATH has no PowerShell folder, which left a
    # staging directory behind, no updater running, and - because the caller swallowed
    # the exception - a card that sat on "Installing" for ever.
    $pwshPath = Get-BridgePwshPath
    if (-not $pwshPath) {
        $result.Detail = 'could not find pwsh to run the updater'
        return $result
    }

    $ownsStage = $false
    $ownsResult = $false
    try {
        New-Item -ItemType Directory -Path $staging -ErrorAction Stop | Out-Null
        $ownsStage = $true
        if ($resultPath) {
            Assert-BridgeInstallPayload -Root $resultPath -CheckAncestors
            [IO.File]::Open($resultPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None).Dispose()
            $ownsResult = $true
        }
        $scriptText | Set-Content -LiteralPath $script -Encoding UTF8
        $launch = @{
            FilePath     = $pwshPath
            ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"")
            ErrorAction  = 'Stop'
        }
        if ($script:BridgeIsWindows) { $launch.WindowStyle = 'Hidden' }
        if ($Detached) {
            Start-Process @launch | Out-Null
            $result.Started = $true
            $result.State = 'Started'
            $result.Detail = "update to $($status.Latest) launched in the background; completion is not yet known"
            return $result
        }

        $launch.RedirectStandardOutput = Join-Path $staging 'child.stdout.log'
        $launch.RedirectStandardError = Join-Path $staging 'child.stderr.log'
        $process = Start-Process @launch -Wait -PassThru
        $result.Started = $true
        try { $exitCode = $process.ExitCode }
        finally { if ($process -is [IDisposable]) { $process.Dispose() } }
        if ($exitCode -isnot [int]) { throw 'The updater process supplied no actual exit code.' }
        # A process boundary cannot carry Exception.Data. The generated child reserves
        # these exits for marked test guards; ordinary installer exits become exit 1.
        if ((Test-BridgeTestExecution) -and $exitCode -in @(77, 78)) {
            $blocked = [InvalidOperationException]::new('The generated updater propagated a test boundary violation.')
            $blocked.Data[$(if ($exitCode -eq 78) { 'BridgeTestWriteBlocked' } else { 'BridgeTestNetworkBlocked' })] = $true
            throw $blocked
        }
        $result.InstalledVersion = $null
        $result.InstalledVersion = Get-BridgeInstalledVersion -Refresh
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            throw "The updater exited $exitCode without this attempt's terminal result."
        }
        $outcome = Read-BridgeUpdateOutcome -Path $resultPath -AttemptId $result.AttemptId -Version $status.Latest
        if ($outcome.At -lt $attemptStartedAt.AddSeconds(-1)) { throw 'The foreground update outcome predates this attempt.' }
        if ($exitCode -ne 0 -or -not $outcome.Success) {
            throw "update to $($status.Latest) failed (child exit $exitCode): $($outcome.Error)"
        }
        $result.Success = $true
        $result.State = 'Completed'
        # Leads with what happened, and names the one thing it cannot vouch for.
        #
        # This used to end on "required local installation health is not certified",
        # printed seconds after the installer's own check had listed every probe green
        # and said "All good: the bridge is installed, running and connected". A
        # successful update therefore finished on a sentence that reads as a failure,
        # which is the tell #124 is about: people went hunting for an updater fault
        # while `status` reported the new version with everything green.
        #
        # The caution is still right, because the child stops the daemon after that
        # check so the supervisor relaunches it - nothing has looked at the install
        # since. That is a narrow, nameable gap rather than a blanket disclaimer, and
        # it comes with the one command that closes it.
        #
        # "asked to restart", not "restarted": Stop-BridgeOwnedRuntime stops a process
        # or finds none, and never starts or waits for the replacement. Saying the
        # daemon was restarted would claim a running daemon on exactly the occasions
        # it is not - a stopped or missing supervisor - which is the same overclaiming
        # this change exists to remove. Found by review on #152.
        $result.Detail = "updated to $($status.Latest); recorded version $($result.InstalledVersion); " +
            "the daemon was asked to restart, so nothing has checked the install since - run 'agent-ha-bridge status' to confirm"
    }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        $result.State = 'Failed'
        $result.Detail = $_.Exception.Message
    }
    finally {
        if (-not $Detached -or -not $result.Started) {
            if ($ownsStage) {
                foreach ($name in @('child.stdout.log', 'child.stderr.log')) {
                    $capture = Join-Path $staging $name
                    if (Test-BridgeTestExecution) { Assert-BridgeTestPath -Path @($capture, $logPath) }
                    if (Test-Path -LiteralPath $capture -PathType Leaf) {
                        Get-Content -LiteralPath $capture | Add-Content -LiteralPath $logPath -Encoding UTF8
                    }
                }
            }
            $ownedPaths = @()
            if ($ownsResult) { $ownedPaths += $resultPath }
            if ($ownsStage) { $ownedPaths += $staging }
            foreach ($path in $ownedPaths) {
                if (Test-BridgeTestExecution) { Assert-BridgeTestPath -Path $path }
                if (Test-Path -LiteralPath $path) {
                    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                }
            }
        }
    }
    $result
}
