#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for update checking.

.DESCRIPTION
    Covers version comparison, the release cache, and the safety properties that
    matter: a failing or unreachable GitHub must never break the daemon, and a
    repository with no releases must not look like an available update.

    Uses only the canonical runner's verified synthetic roots. The real generator
    and staging writer run, but the external launch/download boundary never does.
    Generated scripts and every embedded destination must remain in the fixture.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'runner-support.ps1')
Assert-BridgeTestEnvironment -Required

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\bridge-update.ps1')

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

# The real GitHub API is rate-limited on shared CI runners, where an unauthenticated
# 403 is indistinguishable from an outage. That made the refetch and failure tests
# non-deterministic. Simulate every fetch as an outage: the cache, version and
# failure-handling logic under test needs no real response, and this keeps the suite
# offline and stable.
function Invoke-RestMethod { throw 'network disabled in test' }
# A refused check now falls back to a second endpoint over Invoke-WebRequest. A REST
# stub does not stand in for that transport - the boundary guard says so - and an
# unstubbed call would surface as a test-boundary violation rather than as the outage
# these tests simulate.
function Invoke-WebRequest { throw 'network disabled in test' }

Write-Host '--- version comparison ---'
$cases = @(
    @{ Installed = '1.0.0'; Latest = 'v1.0.1'; Newer = $true }
    @{ Installed = '1.0.0'; Latest = 'v1.0.0'; Newer = $false }
    @{ Installed = '1.0.1'; Latest = 'v1.0.0'; Newer = $false }
    # String ordering would get this one wrong.
    @{ Installed = '1.2.0'; Latest = 'v1.10.0'; Newer = $true }
    @{ Installed = '1.0.0'; Latest = '2.0.0'; Newer = $true }
    @{ Installed = '1.0.0'; Latest = 'v2.0.0-beta.1'; Newer = $true }
    @{ Installed = '1.0.0'; Latest = 'not-a-version'; Newer = $false }
    @{ Installed = '1.0.0'; Latest = ''; Newer = $false }
)
foreach ($case in $cases) {
    $installed = ConvertTo-BridgeVersion -Text $case.Installed
    $latest = ConvertTo-BridgeVersion -Text $case.Latest
    Test-That "$($case.Installed) vs '$($case.Latest)' newer=$($case.Newer)" {
        ($latest -gt $installed) -eq $case.Newer
    } "$installed vs $latest"
}
Test-That 'an unparseable version sorts as 0.0.0' {
    (ConvertTo-BridgeVersion -Text 'garbage') -eq [version]'0.0.0'
}

Write-Host '--- repository resolution ---'
Test-That 'a repository is always resolved' {
    (Get-BridgeUpdateRepository) -match '^[\w.-]+/[\w.-]+$'
} (Get-BridgeUpdateRepository)

# This value decides what Invoke-BridgeSelfUpdate downloads and executes, so a stale
# one is not a cosmetic problem. A pre-rename config names danswett/copilot-ha-bridge,
# which resolves only while GitHub's rename redirect stands; the day someone else
# registers that name, every install still carrying it fetches and runs a stranger's
# archive.
Test-That 'the pre-rename repository is corrected, not trusted' {
    $script:DecisionBridgeConfig.UpdateRepositoryOverride = $null
    function Get-BridgeSetting { param($Path, $Default) 'danswett/copilot-ha-bridge' }
    try { (Get-BridgeUpdateRepository) -eq 'danswett/agent-ha-bridge' }
    finally { Remove-Item Function:\Get-BridgeSetting -ErrorAction SilentlyContinue }
}
Test-That 'a fork is left exactly as configured' {
    function Get-BridgeSetting { param($Path, $Default) 'someone-else/their-fork' }
    try { (Get-BridgeUpdateRepository) -eq 'someone-else/their-fork' }
    finally { Remove-Item Function:\Get-BridgeSetting -ErrorAction SilentlyContinue }
}
Test-That 'an unset repository falls back to this project' {
    function Get-BridgeSetting { param($Path, $Default) '' }
    try { (Get-BridgeUpdateRepository) -eq 'danswett/agent-ha-bridge' }
    finally { Remove-Item Function:\Get-BridgeSetting -ErrorAction SilentlyContinue }
}
Test-That 'config.example.json names the current repository' {
    $example = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\config.example.json') -Raw | ConvertFrom-Json
    $example.updates.repository -eq 'danswett/agent-ha-bridge'
}

Write-Host '--- installed version ---'
Test-That 'an installed version is always reported' {
    (Get-BridgeInstalledVersion) -match '^\d+\.\d+'
} (Get-BridgeInstalledVersion)

Write-Host '--- the cache ---'
# Redirect the cache to a scratch file rather than writing bogus releases to the one
# the daemon reads. Moving the real file aside and back still leaves a window where a
# running daemon picks up "v9.9.9" and announces a phantom update in Home Assistant -
# which it did, on the machine this was developed on.
$realCachePath = $script:BridgeUpdateConfig.CacheFile
$cachePath = Join-Path $env:TEMP ("bridge-update-test-" + [guid]::NewGuid().ToString('N') + '.json')
$script:BridgeUpdateConfig.CacheFile = $cachePath
$validCachedRelease = [pscustomobject]@{
    Tag = 'v9.9.9'; Url = 'https://example.test/releases/v9.9.9'
    Zip = 'https://example.test/archive/v9.9.9.zip'; Notes = ''; Name = ''; Published = ''
}
try {
    # A cache that is fresh must be used rather than re-fetching. A bogus tag proves
    # the value came from the cache and not the network.
    [pscustomobject]@{
        CheckedAt = [DateTimeOffset]::Now.ToString('o')
        Release   = $validCachedRelease
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding UTF8

    $cached = Get-BridgeLatestRelease
    Test-That 'a fresh cache is reused' { $cached.Tag -eq 'v9.9.9' } (($cached.Tag) ?? 'null')

    $status = Get-BridgeUpdateStatus
    Test-That 'a newer cached release reads as available' { $status.Available } "latest=$($status.Latest)"
    Test-That 'the v prefix is stripped for display' { $status.Latest -eq '9.9.9' } $status.Latest

    # An expired cache must be refetched rather than trusted.
    [pscustomobject]@{
        CheckedAt = [DateTimeOffset]::Now.AddDays(-3).ToString('o')
        Release   = $validCachedRelease
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding UTF8
    $refreshed = Get-BridgeLatestRelease
    Test-That 'an expired cache is refetched (network)' {
        $null -eq $refreshed -or $refreshed.Tag -ne 'v9.9.9'
    } $(if ($null -ne $refreshed) { $refreshed.Tag } else { 'null' })

    Write-Host '--- the check interval controls how often GitHub is polled ---'
    [pscustomobject]@{
        CheckedAt = [DateTimeOffset]::Now.AddHours(-2).ToString('o')
        Release   = $validCachedRelease
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding UTF8
    Test-That 'a wide interval reuses a 2h-old cache' { (Get-BridgeLatestRelease -CheckHours 24).Tag -eq 'v9.9.9' }
    # A refetch hits the mocked (offline) network and returns null, proving a shorter
    # interval re-polls rather than trusting the cache.
    Test-That 'a short interval re-polls a 2h-old cache' { $null -eq (Get-BridgeLatestRelease -CheckHours 1) }

    Write-Host '--- a check that never reached GitHub is not an answer ---'
    # Publishing 1.14.0 meant checking repeatedly, which exhausted the unauthenticated
    # rate limit (60/hour/IP). The 403s were cached exactly like a real reply, so every
    # machine reported itself up to date on 1.13.3 and `update` said "already on
    # 1.13.3" minutes after the release went live. A failed check is now believed for
    # minutes, not hours. The bogus tag is the tell: if it comes back, the cache was
    # trusted; if null comes back, the mocked outage was re-polled.
    [pscustomobject]@{
        CheckedAt = [DateTimeOffset]::Now.AddMinutes(-30).ToString('o')
        Reached   = $false
        Release   = $validCachedRelease
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding UTF8
    Test-That 'a 30-minute-old failure is re-polled, not trusted for six hours' {
        $null -eq (Get-BridgeLatestRelease)
    }

    [pscustomobject]@{
        CheckedAt = [DateTimeOffset]::Now.AddMinutes(-5).ToString('o')
        Reached   = $false
        Release   = $validCachedRelease
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding UTF8
    Test-That 'a five-minute-old failure stays unknown rather than trusting retained release data' {
        $lookup = Get-BridgeLatestRelease -IncludeStatus
        $lookup.State -eq 'Unavailable' -and $null -eq $lookup.Release
    }

    [pscustomobject]@{
        CheckedAt = [DateTimeOffset]::Now.AddHours(-2).ToString('o')
        Reached   = $true
        Release   = $validCachedRelease
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding UTF8
    Test-That 'a real answer is still believed for the full interval' {
        (Get-BridgeLatestRelease).Tag -eq 'v9.9.9'
    }

    # An older cache with a validated release still has affirmative metadata. A null
    # legacy cache does not establish whether the request failed or returned 404.
    [pscustomobject]@{
        CheckedAt = [DateTimeOffset]::Now.AddHours(-2).ToString('o')
        Release   = $validCachedRelease
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding UTF8
    Test-That 'a cache from an older version is read as before' {
        (Get-BridgeLatestRelease).Tag -eq 'v9.9.9'
    }

    Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
    $null = Get-BridgeLatestRelease -Force
    Test-That 'an unreachable GitHub is recorded as unreached' {
        ((Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json).Reached) -eq $false
    }

    # A bare 404 does not establish repository existence/access. Preserve it as a
    # distinct endpoint result, never as "installed equals latest".
    function Invoke-RestMethod {
        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
        throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Not Found', $response)
    }
    Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
    $null = Get-BridgeLatestRelease -Force
    Test-That 'a latest-release 404 is retained without inventing release metadata' {
        $written = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
        $written.Reached -and $null -eq $written.Release
    }
    Test-That 'a latest-release 404 is not a current-version claim' {
        $notFound = Get-BridgeUpdateStatus
        $notFound.State -eq 'NotFound' -and $null -eq $notFound.Latest -and
            $notFound.Detail -match 'existence and access are not confirmed'
    }
    function Invoke-RestMethod { throw 'network disabled in test' }

    # A refused request is not a broken install. 403 alone is ambiguous - a private
    # repository answers the same way - so the rate-limit headers are what decide,
    # and getting that wrong left the machine looking dead on the dashboard while the
    # operator pressed a button that spent more of an allowance already at zero.
    Write-Host '--- a rate-limited check says so, rather than looking like a failure ---'
    function New-RateLimitedResponse {
        param([int]$Code = 403, [string]$Remaining = '0', [string]$Reset = '', [string]$RetryAfter = '')
        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]$Code)
        if ($Remaining -ne '') { [void]$response.Headers.TryAddWithoutValidation('X-RateLimit-Remaining', $Remaining) }
        if ($Reset -ne '') { [void]$response.Headers.TryAddWithoutValidation('X-RateLimit-Reset', $Reset) }
        if ($RetryAfter -ne '') { [void]$response.Headers.TryAddWithoutValidation('Retry-After', $RetryAfter) }
        $response
    }

    $resetAt = [DateTimeOffset]::Now.AddMinutes(37)
    function Invoke-RestMethod {
        $response = New-RateLimitedResponse -Code 403 -Remaining '0' -Reset ([string]$resetAt.ToUnixTimeSeconds())
        throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('rate limit exceeded', $response)
    }
    Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
    $limited = Get-BridgeUpdateStatus -Force
    Test-That 'a rate-limited check is reported as rate limiting, not as a bare failure' {
        $limited.State -eq 'RateLimited'
    } $limited.State
    Test-That 'and says the install is fine, so nobody goes looking for a broken release' {
        $limited.Detail -match 'rate limiting' -and $limited.Detail -match 'install is fine'
    } $limited.Detail
    Test-That 'and names the time it can be tried again, from X-RateLimit-Reset' {
        $limited.Detail -match $resetAt.ToString('HH:mm')
    } $limited.Detail
    Test-That 'it still reports the installed version while rate limited' {
        $limited.Installed -match '^\d+\.\d+'
    } $limited.Installed
    Test-That 'a rate-limited check is never recorded as having reached GitHub' {
        ((Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json).Reached) -eq $false
    }

    # The daemon re-reads this cache roughly every fifteen seconds, and an unreached
    # lookup used to be rebuilt as a generic 'Unavailable'. So the single pass that saw
    # the 403 reported the queue to wait in, and every pass after it said only that the
    # release could not be established - which is exactly the refusal-reads-as-breakage
    # failure this change exists to stop. Found by review on #137.
    $cachedLimited = Get-BridgeUpdateStatus
    Test-That 'the rate-limit verdict survives the next pass instead of decaying to a bare failure' {
        $cachedLimited.State -eq 'RateLimited' -and $cachedLimited.Detail -match 'install is fine'
    } "$($cachedLimited.State): $($cachedLimited.Detail)"

    Test-That 'and still names the reset time it was told, rather than losing it' {
        $cachedLimited.Detail -match $resetAt.ToString('HH:mm')
    } $cachedLimited.Detail

    # A verdict is only worth reinstating while it is still true: past the reset it
    # names a time that has been and gone, so it must not be served as current.
    $expired = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
    $expired.RetryAt = [DateTimeOffset]::Now.AddMinutes(-5).ToString('o')
    $expired.CheckedAt = [DateTimeOffset]::Now.ToString('o')
    $expired | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding UTF8
    function Invoke-RestMethod { throw 'network is still down' }
    $afterReset = Get-BridgeUpdateStatus
    Test-That 'but a verdict whose reset has passed is not reinstated' {
        $afterReset.State -ne 'RateLimited'
    } "$($afterReset.State): $($afterReset.Detail)"

    $resetAt = [DateTimeOffset]::Now.AddMinutes(37)
    function Invoke-RestMethod {
        $response = New-RateLimitedResponse -Code 403 -Remaining '0' -Reset ([string]$resetAt.ToUnixTimeSeconds())
        throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('rate limit exceeded', $response)
    }

    # 429 for a secondary limit carries Retry-After and no remaining count.
    function Invoke-RestMethod {
        $response = New-RateLimitedResponse -Code 429 -Remaining '' -RetryAfter '120'
        throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('too many requests', $response)
    }
    Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
    Test-That 'a secondary limit answering 429 with Retry-After is recognised too' {
        (Get-BridgeUpdateStatus -Force).State -eq 'RateLimited'
    }

    # The ambiguous case. A 403 with an allowance left is a permission problem, and
    # calling it rate limiting would tell someone to wait for something that will
    # never clear on its own.
    function Invoke-RestMethod {
        $response = New-RateLimitedResponse -Code 403 -Remaining '57'
        throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Forbidden', $response)
    }
    Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
    Test-That 'a 403 with allowance left is not called rate limiting' {
        (Get-BridgeUpdateStatus -Force).State -eq 'Unavailable'
    }
    function Invoke-RestMethod { throw 'network disabled in test' }

    # Being refused is not the same as not knowing. Pressing Update in Home Assistant
    # has to work on a machine behind shared egress, where the 60-an-hour allowance is
    # routinely gone through no fault of this machine - measured here going 39 -> 0 in
    # ninety seconds. Two things follow: the archive must not come from the API, and a
    # refused check must ask somewhere outside the allowance before giving up.
    Write-Host '--- a release can still be found when the API allowance is gone ---'

    $archiveUri = ''
    try { $archiveUri = Get-BridgeReleaseArchiveUri -Repository 'owner/repo' -Tag 'v1.2.3' }
    catch { $archiveUri = "threw: $($_.Exception.Message)" }
    Test-That 'the archive is fetched from codeload, which is outside the API allowance' {
        $archiveUri -ceq 'https://codeload.github.com/owner/repo/zip/refs/tags/v1.2.3'
    } $archiveUri

    Test-That 'a malformed repository or tag yields no archive rather than a built URL' {
        (Get-BridgeReleaseArchiveUri -Repository 'owner/repo/extra' -Tag 'v1.2.3') -eq '' -and
        (Get-BridgeReleaseArchiveUri -Repository 'owner repo' -Tag 'v1.2.3') -eq '' -and
        (Get-BridgeReleaseArchiveUri -Repository 'owner/repo' -Tag '../../../etc') -eq '' -and
        (Get-BridgeReleaseArchiveUri -Repository 'owner/repo' -Tag 'v1 2 3') -eq ''
    }

    # The zipball the API hands back is itself an API request, so an unauthenticated
    # download both spends the allowance the check needs and is refused once it is
    # gone. That was the actual reason pressing Update failed: not a broken release,
    # but the download being the thing that ran out of quota.
    function Invoke-RestMethod {
        param($Uri, $Headers, $TimeoutSec)
        if ($Uri -notlike 'https://api.github.com/*') { throw "unexpected lookup URI: $Uri" }
        [pscustomobject]@{
            tag_name = 'v9.9.9'; name = 'synthetic'; body = ''; published_at = ''
            html_url = 'https://github.com/danswett/agent-ha-bridge/releases/tag/v9.9.9'
            zipball_url = 'https://api.github.com/repos/danswett/agent-ha-bridge/zipball/v9.9.9'
        }
    }
    Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
    $viaApi = Get-BridgeUpdateStatus -Force
    Test-That 'a successful lookup still downloads from codeload, never from the API' {
        $viaApi.Zip -ceq 'https://codeload.github.com/danswett/agent-ha-bridge/zip/refs/tags/v9.9.9'
    } $viaApi.Zip
    Test-That 'and the API zipball is not what the press would fetch' {
        $viaApi.Zip -notmatch 'api\.github\.com'
    } $viaApi.Zip

    # The Atom feed is not part of the API allowance - measured while the pool sat at
    # 41/60, which it still did afterwards. Without this the machine kept republishing
    # whatever version it last managed to read, with the update entity at "off": one
    # days behind looked exactly like one that was current.
    # Built as a real HttpResponseMessage, because that is what PowerShell 7 attaches
    # to the error it raises for a 3xx when told not to follow one. The redirect is
    # the answer here, so the "failure" path is the normal one.
    function New-RedirectError {
        param([string]$Location)
        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Found)
        if ($Location) { $response.Headers.Location = [Uri]$Location }
        [Microsoft.PowerShell.Commands.HttpResponseException]::new('redirect', $response)
    }
    $resetAt = [DateTimeOffset]::Now.AddMinutes(37)
    $script:AskedFor = @()
    function Invoke-RestMethod {
        param($Uri, $Headers, $TimeoutSec)
        $script:AskedFor += [string]$Uri
        $response = New-RateLimitedResponse -Code 403 -Remaining '0' -Reset ([string]$resetAt.ToUnixTimeSeconds())
        throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('rate limit exceeded', $response)
    }
    function Invoke-WebRequest {
        param($Uri, $Headers, $TimeoutSec, $MaximumRedirection)
        $script:AskedFor += [string]$Uri
        throw (New-RedirectError -Location 'https://github.com/danswett/agent-ha-bridge/releases/tag/v9.9.9')
    }
    Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
    $rescued = Get-BridgeUpdateStatus -Force
    Test-That 'a refused check that can be answered elsewhere reports the release, not the refusal' {
        $rescued.State -eq 'Available' -or $rescued.Available
    } "$($rescued.State): $($rescued.Detail)"
    Test-That 'and names the version it was told, rather than the last one it managed to read' {
        $rescued.Latest -eq '9.9.9'
    } $rescued.Latest
    Test-That 'and offers an archive that can actually be downloaded while refused' {
        $rescued.Zip -ceq 'https://codeload.github.com/danswett/agent-ha-bridge/zip/refs/tags/v9.9.9'
    } $rescued.Zip
    Test-That 'a release found that way is recorded as having reached GitHub' {
        ((Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json).Reached) -eq $true
    }

    # Which endpoint is asked *is* the prerelease guarantee, so it is pinned here.
    # releases.atom is ordered by date and includes prereleases, so its newest entry is
    # the wrong answer on any repository that ships them - checked live against
    # PowerShell/PowerShell, whose feed leads with v7.7.0-preview.5 while both the API
    # and this redirect say v7.6.6. Taking the feed's first entry would have had a
    # rate-limited machine install a preview; this project also pushes a release tag
    # while the release is still a draft, so the feed can lead with a version whose
    # assets are not attached yet. GitHub does the selecting, which is the point.
    Test-That 'the release is asked for at the endpoint that excludes prereleases and drafts' {
        ($script:AskedFor -contains 'https://github.com/danswett/agent-ha-bridge/releases/latest') -and
            -not (@($script:AskedFor) -match 'releases\.atom')
    } ($script:AskedFor -join ' | ')

    # PowerShell 5.1 hands back a WebHeaderCollection, which has no Location *property*
    # - reading one throws PropertyNotFoundException under StrictMode, checked rather
    # than assumed - and must be indexed by name instead. A hashtable would resolve
    # either way and prove nothing, so the real type is used.
    function Invoke-WebRequest {
        param($Uri, $Headers, $TimeoutSec, $MaximumRedirection)
        $collection = [System.Net.WebHeaderCollection]::new()
        $collection.Add('Location', 'https://github.com/danswett/agent-ha-bridge/releases/tag/v9.9.7')
        [pscustomobject]@{ StatusCode = 302; Headers = $collection }
    }
    Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
    $indexed = Get-BridgeUpdateStatus -Force
    Test-That 'a response that indexes its headers by name is read too, not thrown on' {
        $indexed.Latest -eq '9.9.7'
    } "$($indexed.State): latest=$($indexed.Latest)"

    # A repository with no release at all redirects to the releases index, and
    # /releases/expanded_assets/<tag> is a real GitHub URL that ends in a version
    # without being a release. The tag is taken from the structured path for that
    # reason - anything found loosely in a URL goes straight to the downloader.
    foreach ($elsewhere in @(
        'https://github.com/danswett/agent-ha-bridge/releases',
        'https://github.com/danswett/agent-ha-bridge/releases/expanded_assets/v9.9.9')) {
        function Invoke-WebRequest {
            param($Uri, $Headers, $TimeoutSec, $MaximumRedirection)
            throw (New-RedirectError -Location $elsewhere)
        }
        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
        $noRelease = Get-BridgeUpdateStatus -Force
        Test-That "a redirect to $(($elsewhere -split '/')[-2..-1] -join '/') is not read as a release" {
            $noRelease.State -eq 'RateLimited' -and $null -eq $noRelease.Latest
        } "$($noRelease.State): latest=$($noRelease.Latest)"
    }

    # A tag that is not a version must not be handed to the downloader either.
    function Invoke-WebRequest {
        param($Uri, $Headers, $TimeoutSec, $MaximumRedirection)
        throw (New-RedirectError -Location 'https://github.com/danswett/agent-ha-bridge/releases/tag/nightly')
    }
    Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
    $unusable = Get-BridgeUpdateStatus -Force
    Test-That 'a redirect to a tag that is not a version is declined rather than installed' {
        $unusable.State -eq 'RateLimited' -and $null -eq $unusable.Latest
    } "$($unusable.State): latest=$($unusable.Latest)"

    # A response with no Location at all is a failure, not a release.
    function Invoke-WebRequest {
        param($Uri, $Headers, $TimeoutSec, $MaximumRedirection)
        throw (New-RedirectError -Location '')
    }
    Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
    $headerless = Get-BridgeUpdateStatus -Force
    Test-That 'a redirect with no Location header is declined rather than guessed at' {
        $headerless.State -eq 'RateLimited'
    } "$($headerless.State): latest=$($headerless.Latest)"

    # And when that endpoint is unreachable too, the verdict and its reset time survive
    # exactly as before. The fallback is a second chance, never a second failure to
    # report (#109, #92).
    function Invoke-WebRequest {
        param($Uri, $Headers, $TimeoutSec, $MaximumRedirection)
        throw 'the redirect endpoint is unreachable too'
    }
    Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
    $stillLimited = Get-BridgeUpdateStatus -Force
    Test-That 'a refused check that cannot be answered elsewhere is still reported as rate limiting' {
        $stillLimited.State -eq 'RateLimited' -and $stillLimited.Detail -match $resetAt.ToString('HH:mm')
    } "$($stillLimited.State): $($stillLimited.Detail)"

    # A token the machine already holds turns 60 requests an hour shared with
    # everything behind the same address into 5,000 of this machine's own. Nobody has
    # ever been offered a place to configure updates.token (#153), so the ones that
    # are already in the environment are what there is to use.
    Write-Host '--- a token already on the machine is used ---'
    foreach ($tokenVar in @('GH_TOKEN', 'GITHUB_TOKEN', 'AGENT_HA_BRIDGE_UPDATE_TOKEN')) {
        $priorTokens = @{}
        foreach ($name in @('GH_TOKEN', 'GITHUB_TOKEN', 'AGENT_HA_BRIDGE_UPDATE_TOKEN')) {
            $priorTokens[$name] = [Environment]::GetEnvironmentVariable($name)
            Set-Item -LiteralPath "Env:$name" -Value ''
        }
        try {
            Set-Item -LiteralPath "Env:$tokenVar" -Value 'synthetic-token-value'
            $headers = Get-BridgeReleaseRequestHeaders
            Test-That "a release check authenticates with $tokenVar when the machine already has one" {
                $headers.ContainsKey('Authorization') -and
                    [string]$headers['Authorization'] -match 'synthetic-token-value'
            } $(if ($headers.ContainsKey('Authorization')) { 'present' } else { 'absent' })
        }
        finally {
            foreach ($name in $priorTokens.Keys) {
                if ($null -eq $priorTokens[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
                else { Set-Item -LiteralPath "Env:$name" -Value $priorTokens[$name] }
            }
        }
    }
    $noTokenHeaders = Get-BridgeReleaseRequestHeaders
    Test-That 'and sends no empty Authorization header when the machine has no token' {
        -not $noTokenHeaders.ContainsKey('Authorization')
    }

    function Invoke-RestMethod { throw 'network disabled in test' }
    function Invoke-WebRequest { throw 'network disabled in test' }

    Write-Host '--- failure is survivable ---'
    Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
    $script:DecisionBridgeConfig.UpdateRepositoryOverride = $null
    # Point at a repository that cannot exist, which is the same shape as an outage.
    function Get-BridgeUpdateRepository { 'danswett/this-repository-does-not-exist-9f8e7d' }
    $status = Get-BridgeUpdateStatus -Force
    Test-That 'a missing repository is not an available update' { -not $status.Available }
    Test-That 'an unavailable lookup does not report a fabricated latest version' {
        $status.State -eq 'Unavailable' -and $null -eq $status.Latest
    }
    Test-That 'it still reports the installed version' { $status.Installed -match '^\d+\.\d+' } $status.Installed
    Test-That 'the failed check is recorded so it is not retried immediately' {
        Test-Path -LiteralPath $cachePath
    }
    Test-That 'a self-update is refused when nothing is available' {
        (Invoke-BridgeSelfUpdate).Started -eq $false
    }
}
finally {
    Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
    $script:BridgeUpdateConfig.CacheFile = $realCachePath
}

Test-That "the daemon's own update cache was never touched" {
    $script:BridgeUpdateConfig.CacheFile -eq $realCachePath -and
    ((-not (Test-Path -LiteralPath $realCachePath)) -or
     ((Get-Content -LiteralPath $realCachePath -Raw) -notmatch '9\.9\.9'))
}

Write-Host '--- the generated updater is integrity-checked and safely quoted ---'
function Get-BridgeUpdateStatus {
    param([switch]$Force)
    [pscustomobject]@{
        Installed = '1.0.0'; Latest = '9.9.9'; Available = $true
        Url = 'https://github.com/x/y/releases/tag/v9.9.9'
        Notes = ''; Zip = 'https://api.github.com/repos/x/y/zipball/v9.9.9'
    }
}
$generated = Invoke-BridgeSelfUpdate -ScriptOnly
Test-That 'the updater verifies the archive VERSION against the resolved release' {
    ($generated -match 'archiveVersion') -and ($generated -match '9\.9\.9')
}
Test-That 'the updater still runs the installer non-interactively' {
    $generated -match 'install\.ps1.*-NonInteractive'
}
Test-That 'no -TargetHome argument is emitted when none is supplied' {
    $generated -notmatch '-TargetHome'
}
$genValid = Invoke-BridgeSelfUpdate -ScriptOnly -TargetHome $env:TEMP
Test-That 'a valid TargetHome is passed through to the installer' {
    $genValid -match "-TargetHome '"
}
$quoteDir = Join-Path $env:TEMP ("bridge'quote-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $quoteDir -Force | Out-Null
try {
    $genQuote = Invoke-BridgeSelfUpdate -ScriptOnly -TargetHome $quoteDir
    Test-That 'a single quote in TargetHome is doubled, not broken out of' {
        $genQuote -match "-TargetHome '.*''.*'"
    }
}
finally {
    Remove-Item -LiteralPath $quoteDir -Recurse -Force -ErrorAction SilentlyContinue
}
$bogus = Invoke-BridgeSelfUpdate -TargetHome (Join-Path $env:TEMP ('missing-update-home-' + [guid]::NewGuid().ToString('N')))
Test-That 'a non-existent TargetHome is refused, never interpolated' {
    ($bogus.Started -eq $false) -and ($bogus.Detail -match 'not an existing directory')
}

Write-Host '--- the Install button path really launches the updater ---'
# -Detached is used only by the dashboard button, which is why this being broken never
# showed up in `agent-ha-bridge update`: that takes the other branch.
$script:LaunchedWith = $null
function Start-Process {
    param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru, $ErrorAction)
    $script:LaunchedWith = [pscustomobject]@{ FilePath = $FilePath; ArgumentList = @($ArgumentList) }
}
$detachedRun = Invoke-BridgeSelfUpdate -Detached
Test-That 'a detached update reports that it started' { $detachedRun.Started -eq $true } "$($detachedRun.Detail)"
Test-That 'launch acceptance is not completion' { $detachedRun.State -eq 'Started' -and -not $detachedRun.Success }
Test-That 'and really launched pwsh with the generated script' {
    $null -ne $script:LaunchedWith -and
    $script:LaunchedWith.FilePath -match 'pwsh' -and
    (($script:LaunchedWith.ArgumentList) -join ' ') -match 'run-update\.ps1'
} "$(if ($script:LaunchedWith) { $script:LaunchedWith.FilePath } else { 'nothing launched' })"
$stagedScript = [string]$script:LaunchedWith.ArgumentList[-1]
$stagedScript = $stagedScript.Trim('"')
Assert-BridgeTestPath -Path $stagedScript
Test-That 'the actual staged file is confined to the selected runtime' {
    (Test-BridgeInstallDescendant $stagedScript (Get-BridgeRuntimeRoot)) -and
        (Test-Path -LiteralPath $stagedScript -PathType Leaf)
}
$stagedText = Get-Content -LiteralPath $stagedScript -Raw
foreach ($expectedPath in @(
    (Get-BridgeInstallContext).ConfigPath,
    (Get-BridgeInstallContext).BridgeHome,
    (Get-BridgeRuntimePath 'agent-bridge-update.log'),
    (Get-BridgeRuntimePath 'agent-bridge-update-outcome.json'),
    (Split-Path $stagedScript -Parent)
)) {
    Assert-BridgeTestPath -Path $expectedPath
    Test-That "the staged updater retains its verified destination $expectedPath" {
        $stagedText.Contains($expectedPath.Replace("'", "''"))
    }
}
Remove-BridgeTestSandbox -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT -Directory (Split-Path $stagedScript -Parent)

Write-Host '--- an updater that cannot be launched fails cleanly and leaves nothing behind ---'
Test-That 'pwsh is resolvable here' { [bool](Get-BridgePwshPath) } "$(Get-BridgePwshPath)"
# The real failure this came from: the daemon's PATH, set by a scheduled task, had no
# PowerShell folder. The old code created the staging folder and wrote the updater
# script, then threw on a bare (Get-Command pwsh).Source - so nothing ran, a staging
# folder was orphaned, and the caller's empty catch meant the card sat on "Installing"
# with not one line in the log to say why.
$stagingPattern = 'agent-ha-bridge-update-*'
$fixtureRuntime = Get-BridgeRuntimeRoot
Assert-BridgeTestPath -Path $fixtureRuntime
$stagingBefore = @(Get-ChildItem -LiteralPath $fixtureRuntime -Directory -Filter $stagingPattern -ErrorAction Stop |
    Sort-Object FullName | ForEach-Object { $_.FullName })
function Get-BridgePwshPath { $null }
$noPwsh = Invoke-BridgeSelfUpdate -Detached
Test-That 'a pwsh that cannot be found is reported, not thrown' {
    ($noPwsh.Started -eq $false) -and ($noPwsh.Detail -match 'could not find pwsh')
} "$($noPwsh.Detail)"
$stagingAfter = @(Get-ChildItem -LiteralPath $fixtureRuntime -Directory -Filter $stagingPattern -ErrorAction Stop |
    Sort-Object FullName | ForEach-Object { $_.FullName })
Test-That 'and no half-written staging folder is left behind' {
    ($stagingAfter -join "`n") -ceq ($stagingBefore -join "`n")
} "before=$(@($stagingBefore).Count) after=$(@($stagingAfter).Count)"

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) test(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All tests passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
