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
# The streaming download the generated updater uses, so its progress reporting can be
# driven here against an ordinary Stream rather than a socket (#155).
. (Join-Path $PSScriptRoot '..\hooks\bridge-download.ps1')

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

    # And it is looked at again straight away, rather than sat on for the rest of the
    # retry window. A secondary limit names a minute and Retry-After often names two,
    # both well inside the fifteen minutes an unreached lookup is otherwise kept for -
    # so honouring that window would report a bare failure for the remaining fourteen,
    # having been told exactly when the check would work again. Raised by Codex on #157.
    $expired.RetryAt = [DateTimeOffset]::Now.AddMinutes(-5).ToString('o')
    $expired.CheckedAt = [DateTimeOffset]::Now.ToString('o')
    $expired | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding UTF8
    function Invoke-RestMethod {
        param($Uri, $Headers, $TimeoutSec)
        [pscustomobject]@{
            tag_name = 'v9.9.5'; name = 'synthetic'; body = ''; published_at = ''
            html_url = 'https://github.com/danswett/agent-ha-bridge/releases/tag/v9.9.5'
            zipball_url = 'https://api.github.com/repos/danswett/agent-ha-bridge/zipball/v9.9.5'
        }
    }
    $reChecked = Get-BridgeUpdateStatus
    Test-That 'and the check is made again at the time it was told, not when the window ends' {
        $reChecked.Latest -eq '9.9.5'
    } "$($reChecked.State): latest=$($reChecked.Latest)"
    function Invoke-RestMethod { throw 'network is still down' }

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

    # A token that merely happens to be in the environment is not necessarily a good
    # one: GITHUB_TOKEN expires when its workflow job ends, and a revoked or
    # SSO-blocked token answers 401. Sending one of those turned a check that would
    # have succeeded unauthenticated - these are public releases - into a failure that
    # repeated on every retry, because the same token was selected again. Raised by
    # Codex on #157.
    $priorToken = [Environment]::GetEnvironmentVariable('GH_TOKEN')
    try {
        Set-Item -LiteralPath Env:GH_TOKEN -Value 'an-expired-token'
        $script:AuthAttempts = @()
        function Invoke-RestMethod {
            param($Uri, $Headers, $TimeoutSec)
            $script:AuthAttempts += [bool]$Headers.ContainsKey('Authorization')
            if ($Headers.ContainsKey('Authorization')) {
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Unauthorized)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Bad credentials', $response)
            }
            [pscustomobject]@{
                tag_name = 'v9.9.6'; name = 'synthetic'; body = ''; published_at = ''
                html_url = 'https://github.com/danswett/agent-ha-bridge/releases/tag/v9.9.6'
                zipball_url = 'https://api.github.com/repos/danswett/agent-ha-bridge/zipball/v9.9.6'
            }
        }
        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
        $expired = Get-BridgeUpdateStatus -Force
        Test-That 'an expired ambient token is not allowed to fail a check that works without one' {
            $expired.Latest -eq '9.9.6'
        } "$($expired.State): latest=$($expired.Latest)"
        Test-That 'and the retry is actually anonymous, having tried the token exactly once' {
            $script:AuthAttempts.Count -eq 2 -and $script:AuthAttempts[0] -and -not $script:AuthAttempts[1]
        } ($script:AuthAttempts -join ', ')

        # The allowance, not the credential, is what a rate-limited 403 refused.
        # Retrying it anonymously would spend a second request to be told the same
        # thing; the non-API fallback is what answers that case.
        $script:AuthAttempts = @()
        function Invoke-RestMethod {
            param($Uri, $Headers, $TimeoutSec)
            $script:AuthAttempts += [bool]$Headers.ContainsKey('Authorization')
            $response = New-RateLimitedResponse -Code 403 -Remaining '0' -Reset ([string]$resetAt.ToUnixTimeSeconds())
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('rate limit exceeded', $response)
        }
        function Invoke-WebRequest {
            param($Uri, $Headers, $TimeoutSec, $MaximumRedirection)
            throw 'the redirect endpoint is unreachable too'
        }
        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
        $limitedWithToken = Get-BridgeUpdateStatus -Force
        Test-That 'a rate-limited refusal is not retried anonymously, being about the allowance' {
            $script:AuthAttempts.Count -eq 1 -and $limitedWithToken.State -eq 'RateLimited'
        } "$($limitedWithToken.State), attempts=$($script:AuthAttempts.Count)"

        # A secondary limit answers 403 with a nonzero remaining count and no
        # Retry-After, saying which it was only in the body. Reading that as a bad
        # credential and immediately asking again is the one response GitHub warns can
        # get a caller banned. Raised by Codex on #157.
        $script:AuthAttempts = @()
        function Invoke-RestMethod {
            param($Uri, $Headers, $TimeoutSec)
            $script:AuthAttempts += [bool]$Headers.ContainsKey('Authorization')
            $response = New-RateLimitedResponse -Code 403 -Remaining '57'
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new(
                'You have exceeded a secondary rate limit. Please wait a few minutes before you try again.', $response)
        }
        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
        $secondary = Get-BridgeUpdateStatus -Force
        Test-That 'a secondary limit is not retried anonymously, which GitHub warns can earn a ban' {
            $script:AuthAttempts.Count -eq 1
        } "attempts=$($script:AuthAttempts.Count)"
        Test-That 'and is reported as rate limiting rather than as an unexplained failure' {
            $secondary.State -eq 'RateLimited' -and $secondary.Detail -match 'install is fine'
        } "$($secondary.State): $($secondary.Detail)"
        Test-That 'and names a time to try again, which a secondary limit never sends' {
            $secondary.Detail -match '\d\d:\d\d'
        } $secondary.Detail

        # A secondary limit that persists must not be asked again at the same interval
        # for as long as it lasts: GitHub requires exponentially increasing waits and
        # warns that continuing can earn a ban. The expired-reset cache bypass makes
        # that the difference between one request a minute and a backing-off one, so
        # the wait is carried across checks rather than recomputed fresh each time.
        # Raised by Codex on #157.
        $waits = @()
        foreach ($round in 1..4) {
            Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
            if ($waits.Count) {
                # Only the strike count survives; the entry is otherwise expired so the
                # next call really does re-check rather than being served from cache.
                [pscustomobject]@{
                    CheckedAt = [DateTimeOffset]::Now.AddHours(-9).ToString('o')
                    Reached = $false; State = 'RateLimited'; Detail = 'x'
                    RetryAt = [DateTimeOffset]::Now.AddMinutes(-5).ToString('o')
                    RateLimitStrikes = $waits.Count
                    Release = $null
                } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding UTF8
            }
            $null = Get-BridgeUpdateStatus -Force
            $written = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
            $waits += [int][Math]::Round(([DateTimeOffset]$written.RetryAt - [DateTimeOffset]::Now).TotalMinutes)
        }
        Test-That 'a secondary limit that keeps answering is backed off, not polled at a fixed minute' {
            ($waits -join ',') -eq '1,2,4,8'
        } ($waits -join ',')
        Test-That 'and the strike count is carried in the cache so the wait survives a restart' {
            ([int](Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json).RateLimitStrikes) -eq 4
        }

        # And a secondary limit still carries the *primary* bucket's reset header,
        # which can be most of an hour away and has nothing to do with what was
        # refused. Taking it as GitHub's answer also cancelled the backoff, so the
        # secondary limit was both misreported and polled at a fixed interval.
        # Raised by Codex on #157.
        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
        $primaryReset = [DateTimeOffset]::Now.AddMinutes(43)
        function Invoke-RestMethod {
            param($Uri, $Headers, $TimeoutSec)
            $response = New-RateLimitedResponse -Code 403 -Remaining '57' -Reset ([string]$primaryReset.ToUnixTimeSeconds())
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new(
                'You have exceeded a secondary rate limit. Please wait a few minutes before you try again.', $response)
        }
        $withPrimaryReset = Get-BridgeUpdateStatus -Force
        Test-That 'a secondary limit does not take the primary bucket reset as its own answer' {
            $written = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
            [Math]::Round(([DateTimeOffset]$written.RetryAt - [DateTimeOffset]::Now).TotalMinutes) -eq 1 -and
                [int]$written.RateLimitStrikes -eq 1
        } "$($withPrimaryReset.Detail)"

        # A limit that named its own reset ends on its own, so it must not accumulate
        # backoff - GitHub already said when.
        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
        function Invoke-RestMethod {
            param($Uri, $Headers, $TimeoutSec)
            $response = New-RateLimitedResponse -Code 403 -Remaining '0' -Reset ([string]$resetAt.ToUnixTimeSeconds())
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('rate limit exceeded', $response)
        }
        $null = Get-BridgeUpdateStatus -Force
        Test-That 'a limit that named its own reset accrues no backoff' {
            ([int](Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json).RateLimitStrikes) -eq 0
        } ([string](Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json).RateLimitStrikes)

        # A secondary limit can arrive as 429 just as well as 403, and without the
        # headers either way. Keying the inferred wait on 403 left a headerless 429
        # with no time at all, so the strike count it was accruing did nothing.
        # Raised by Codex on #157.
        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
        function Invoke-RestMethod {
            param($Uri, $Headers, $TimeoutSec)
            $response = New-RateLimitedResponse -Code 429 -Remaining '' -RetryAfter ''
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('too many requests', $response)
        }
        $headerless429 = Get-BridgeUpdateStatus -Force
        Test-That 'a 429 carrying no headers is given a wait as well, not left with none' {
            $written = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
            $headerless429.State -eq 'RateLimited' -and $written.RetryAt -and
                [Math]::Round(([DateTimeOffset]$written.RetryAt - [DateTimeOffset]::Now).TotalMinutes) -eq 1
        } "$($headerless429.State): $($headerless429.Detail)"

        # And a wait longer than the fifteen-minute retry window has to outlast it,
        # or the backoff stops growing there and every later step asks again early.
        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
        [pscustomobject]@{
            CheckedAt = [DateTimeOffset]::Now.AddMinutes(-16).ToString('o')
            Reached = $false; State = 'RateLimited'
            Detail = "GitHub is rate limiting this machine's release checks until 23:59. The install is fine."
            RetryAt = [DateTimeOffset]::Now.AddMinutes(16).ToString('o')
            RateLimitStrikes = 5
            Release = $null
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding UTF8
        $script:AuthAttempts = @()
        function Invoke-RestMethod {
            param($Uri, $Headers, $TimeoutSec)
            $script:AuthAttempts += $true
            throw [IO.IOException]::new('this request should never have been made')
        }
        $held = Get-BridgeUpdateStatus
        Test-That 'a wait past the retry window is honoured rather than cut short at fifteen minutes' {
            $script:AuthAttempts.Count -eq 0 -and $held.State -eq 'RateLimited'
        } "$($held.State), requests=$($script:AuthAttempts.Count)"

        # A short configured check interval says how often to look when things are
        # fine. It must not override an instruction not to ask yet, or every backoff
        # past it collapses to the polling cadence. Raised by Codex on #157.
        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
        [pscustomobject]@{
            CheckedAt = [DateTimeOffset]::Now.AddMinutes(-20).ToString('o')
            Reached = $false; State = 'RateLimited'
            Detail = "GitHub is rate limiting this machine's release checks until 23:59. The install is fine."
            RetryAt = [DateTimeOffset]::Now.AddMinutes(32).ToString('o')
            RateLimitStrikes = 6
            Release = $null
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding UTF8
        $script:AuthAttempts = @()
        $heldShortInterval = Get-BridgeLatestRelease -CheckHours 0.0833 -IncludeStatus
        Test-That 'a five-minute check interval does not cut a thirty-two minute backoff short' {
            $script:AuthAttempts.Count -eq 0 -and $heldShortInterval.State -eq 'RateLimited'
        } "$($heldShortInterval.State), requests=$($script:AuthAttempts.Count)"

        # Bounded all the same: a timestamp further out than any real limit is honoured
        # for at most an hour, so a corrupt or skewed one cannot silence the check for
        # days. Checked seventy minutes on, which is past that cap.
        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
        [pscustomobject]@{
            CheckedAt = [DateTimeOffset]::Now.AddMinutes(-70).ToString('o')
            Reached = $false; State = 'RateLimited'
            Detail = "GitHub is rate limiting this machine's release checks until 23:59. The install is fine."
            RetryAt = [DateTimeOffset]::Now.AddDays(3).ToString('o')
            RateLimitStrikes = 6
            Release = $null
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding UTF8
        $script:AuthAttempts = @()
        $null = Get-BridgeLatestRelease -CheckHours 0.0833 -IncludeStatus
        Test-That 'but a wait three days out is held for an hour at most, not for three days' {
            $script:AuthAttempts.Count -eq 1
        } "requests=$($script:AuthAttempts.Count)"
    }
    finally {
        if ($null -eq $priorToken) { Remove-Item -LiteralPath Env:GH_TOKEN -ErrorAction SilentlyContinue }
        else { Set-Item -LiteralPath Env:GH_TOKEN -Value $priorToken }
    }

    # Without a token there is nothing to retry without, so a 401 must not quietly
    # double every refused check.
    $script:AuthAttempts = @()
    function Invoke-RestMethod {
        param($Uri, $Headers, $TimeoutSec)
        $script:AuthAttempts += [bool]$Headers.ContainsKey('Authorization')
        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Unauthorized)
        throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Bad credentials', $response)
    }
    Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
    $noToken401 = Get-BridgeUpdateStatus -Force
    Test-That 'a 401 with no token to blame is asked once, not twice' {
        $script:AuthAttempts.Count -eq 1 -and $noToken401.State -eq 'Unavailable'
    } "$($noToken401.State), attempts=$($script:AuthAttempts.Count)"

    function Invoke-RestMethod { throw 'network disabled in test' }
    function Invoke-WebRequest { throw 'network disabled in test' }

    # --- which GitHub allowance the check is on -------------------------------------
    # Measured on DSWETT-HOME at 17:48 PT on 2026-10-10: the unauthenticated pool for
    # this address stood at 51/60 and resets hourly, while the identical call
    # authenticated reported 5000/5000. That 83-fold difference is the whole of #153,
    # and until now the only way to take it was to hand-edit config.json.
    Write-Host '--- the configured token wins, and only its name is ever reported ---'
    function Invoke-WithUpdateTokenEnvironment {
        param([hashtable]$Values, [Parameter(Mandatory)][scriptblock]$Body)
        $prior = @{}
        foreach ($name in @('AGENT_HA_BRIDGE_UPDATE_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')) {
            $prior[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $(if ($Values.ContainsKey($name)) { $Values[$name] } else { $null }))
        }
        try { & $Body }
        finally { foreach ($name in $prior.Keys) { [Environment]::SetEnvironmentVariable($name, $prior[$name]) } }
    }

    $configuredToken = 'ghp_configuredaaaaaaaaaaaaaaaaaaaaaaaa'
    $ambientToken = 'ghp_ambientbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    # Shadowed inside a scriptblock, never at script scope: Get-BridgeSetting is a real
    # function dot-sourced into this scope, so defining one here and then removing it
    # deletes the real one for every test that follows.
    & {
        function Get-BridgeSetting {
            param($Path, $Default)
            if ($Path -eq 'updates.token') { return $configuredToken }
            $Default
        }
        Invoke-WithUpdateTokenEnvironment @{ GH_TOKEN = $ambientToken } {
            $chosen = Get-BridgeUpdateToken
            Test-That 'a configured updates.token beats one the shell merely happened to export' {
                $chosen.Source -eq 'updates.token' -and $chosen.Token -ceq $configuredToken
            } $chosen.Source
            Test-That 'and the reported source is a name, never the credential' {
                $chosen.Source -notmatch 'ghp_'
            } $chosen.Source
        }
    }

    # A token is an HTTP header value. One pasted with a trailing newline, or with the
    # smart quotes a chat client substitutes, cannot be sent at all: .NET refuses the
    # header and the check fails complaining about header syntax, on a machine whose
    # unauthenticated check would have worked perfectly well.
    & {
        function Get-BridgeSetting {
            param($Path, $Default)
            if ($Path -eq 'updates.token') { return "ghp_pasted$([char]0x201C)`n" }
            $Default
        }
        Invoke-WithUpdateTokenEnvironment @{ GH_TOKEN = $ambientToken } {
            $fallback = Get-BridgeUpdateToken
            Test-That 'an unsendable updates.token does not cost the machine a usable ambient one' {
                $fallback.Source -eq '$env:GH_TOKEN' -and $fallback.Token -ceq $ambientToken
            } $fallback.Source
            Test-That 'and it names the setting to fix without quoting what was in it' {
                $fallback.Note -match 'updates\.token is not a usable token' -and $fallback.Note -notmatch 'ghp_'
            } $fallback.Note
        }
        Invoke-WithUpdateTokenEnvironment @{} {
            $alone = Get-BridgeUpdateToken
            Test-That 'with nothing to fall back to it degrades to an unauthenticated check, not a failure' {
                $alone.Token -eq '' -and $alone.Source -eq '' -and $alone.Note -match 'not a usable token'
            } "[$($alone.Source)] $($alone.Note)"
            $degraded = Get-BridgeReleaseRequestHeaders
            Test-That 'and sends no Authorization header at all rather than a malformed one' {
                -not $degraded.ContainsKey('Authorization')
            }
        }
    }

    Write-Host '--- the check says which allowance it spent, and the cache remembers ---'
    function New-SyntheticRelease {
        [pscustomobject]@{
            tag_name = 'v9.9.7'; name = 'synthetic'; body = ''; published_at = ''
            html_url = 'https://github.com/danswett/agent-ha-bridge/releases/tag/v9.9.7'
            zipball_url = 'https://api.github.com/repos/danswett/agent-ha-bridge/zipball/v9.9.7'
        }
    }
    function Invoke-RestMethod { param($Uri, $Headers, $TimeoutSec) New-SyntheticRelease }
    Invoke-WithUpdateTokenEnvironment @{ GH_TOKEN = $ambientToken } {
        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
        $authenticated = Get-BridgeUpdateStatus -Force
        Test-That 'a successful check reports the credential that authenticated it, by name' {
            $authenticated.TokenSource -eq '$env:GH_TOKEN' -and -not $authenticated.TokenNote
        } "[$($authenticated.TokenSource)] $($authenticated.TokenNote)"
        $recorded = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8
        Test-That 'and the cache keeps the name so status can read it without a request' {
            $recorded -match 'GH_TOKEN'
        }
        Test-That 'but never the credential itself, which only ever reaches a request header' {
            $recorded -notmatch 'ghp_'
        }
    }

    # The anonymous retry on a bad credential is right - these are public releases -
    # but it used to be silent, so a machine whose token had been revoked went back to
    # the 60-an-hour shared pool while its configuration said otherwise (#153).
    function Invoke-RestMethod {
        param($Uri, $Headers, $TimeoutSec)
        if ($Headers.ContainsKey('Authorization')) {
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Unauthorized)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Bad credentials', $response)
        }
        New-SyntheticRelease
    }
    Invoke-WithUpdateTokenEnvironment @{ GH_TOKEN = $ambientToken } {
        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
        $rejected = Get-BridgeUpdateStatus -Force
        Test-That 'a rejected token still yields an answer, and admits it was unauthenticated' {
            $rejected.Latest -eq '9.9.7' -and $rejected.TokenSource -eq ''
        } "$($rejected.State) source=[$($rejected.TokenSource)]"
        Test-That 'and says which credential GitHub refused, so the downgrade is not silent' {
            $rejected.TokenNote -match '\$env:GH_TOKEN was rejected' -and $rejected.TokenNote -notmatch 'ghp_'
        } $rejected.TokenNote
    }

    # The advice on a refused check has to be true of the machine reading it. Told to
    # set updates.token while already using one, an operator sets it again and is
    # refused again.
    $limitResetAt = [DateTimeOffset]::Now.AddMinutes(23)
    function Invoke-RestMethod {
        param($Uri, $Headers, $TimeoutSec)
        $response = New-RateLimitedResponse -Code 403 -Remaining '0' -Reset ([string]$limitResetAt.ToUnixTimeSeconds())
        throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('rate limit exceeded', $response)
    }
    function Invoke-WebRequest {
        param($Uri, $Headers, $TimeoutSec, $MaximumRedirection)
        throw 'the redirect endpoint is unreachable too'
    }
    Invoke-WithUpdateTokenEnvironment @{} {
        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
        $unauthenticated = Get-BridgeUpdateStatus -Force
        Test-That 'a refused unauthenticated check names the setting that raises the limit' {
            $unauthenticated.Detail -match 'setting updates\.token raises this machine to 5,000'
        } $unauthenticated.Detail
    }
    Invoke-WithUpdateTokenEnvironment @{ GH_TOKEN = $ambientToken } {
        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
        $alreadyAuthenticated = Get-BridgeUpdateStatus -Force
        Test-That 'but a machine already using one is not told to set it again' {
            $alreadyAuthenticated.Detail -notmatch 'setting updates\.token' -and
                $alreadyAuthenticated.Detail -match 'authenticated with \$env:GH_TOKEN'
        } $alreadyAuthenticated.Detail
    }

    # A press whose forced re-check is refused used to come back "already on 1.29.0" -
    # the same words as a press that found nothing to do - and the machine then read as
    # current on the dashboard while being a release behind (#56). The refusal has to
    # answer for itself.
    Invoke-WithUpdateTokenEnvironment @{} {
        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
        $refusedPress = Invoke-BridgeSelfUpdate
        Test-That 'a press whose re-check is refused is not reported as being up to date' {
            $refusedPress.Started -eq $false -and $refusedPress.State -eq 'RateLimited' -and
                $refusedPress.Detail -notmatch 'already on' -and $refusedPress.Detail -notmatch 'no newer release'
        } "$($refusedPress.State): $($refusedPress.Detail)"
        Test-That 'and says it is a queue to wait in, with the time it can be tried again' {
            $refusedPress.Detail -match 'rate limiting' -and $refusedPress.Detail -match '\d\d:\d\d'
        } $refusedPress.Detail
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

# The whole point of #129 is that the stages come from the updater rather than being
# guessed by a card, so the generated child has to actually emit them - and it is
# generated text, which no amount of testing the parent would catch a syntax error in.
Test-That 'the generated updater parses as PowerShell' {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($generated, [ref]$null, [ref]$errors)
    @($errors).Count -eq 0
} "parse errors: $(@(([System.Management.Automation.Language.Parser]::ParseInput($generated, [ref]$null, [ref]([System.Management.Automation.Language.ParseError[]]$null)))) | Out-String)"

Test-That 'it reports each stage it passes through' {
    foreach ($stage in @('downloading', 'installing', 'restarting', 'verifying')) {
        if ($generated -notmatch "Write-UpdateStage -Stage '$stage'") { return $false }
    }
    $true
}

# Stopping the daemon is what removes the reader, so a stage written after it has
# nobody to publish it.
Test-That 'it says it is restarting before it stops the daemon, not after' {
    $generated.IndexOf("Write-UpdateStage -Stage 'restarting'") -lt
        $generated.IndexOf('Stop-BridgeOwnedRuntime')
}

Test-That 'and ends on a terminal stage that distinguishes success from failure' {
    $generated -match "Write-UpdateStage -Stage \`$\(if \(\`$outcome\.success\) \{ 'completed' \} else \{ 'failed' \}\)"
}

# Downloading was the one stage that could never say how far it had got, because
# Invoke-WebRequest -OutFile blocks until the file is complete and reports nothing on
# the way. Everything downstream was already built for a proportion - the stage
# record validates one, the update entity publishes stage_proportion, the card draws
# the bar - and only the emitter was missing (#155).
Test-That 'the downloading stage emits a proportion as the archive arrives' {
    ($generated -match 'Save-BridgeUpdateDownload') -and
        ($generated -match "Write-UpdateStage -Stage 'downloading' -Proportion")
}
Test-That 'and no longer hands the transfer to a call that can only report the word' {
    $generated -notmatch '(?m)^\s*Invoke-WebRequest\b'
}
# The native hook is fetched afterwards, by the installer, under Installing. A bar
# that reached 100% and then sat there for the larger half of the wait would be worse
# than no bar, so the proportion ends when the archive does.
Test-That 'the installing stage carries no proportion, so the bar ends with the archive' {
    $generated -notmatch "Write-UpdateStage -Stage 'installing' -Proportion"
}
Test-That 'and the downloader library is verified before it is loaded' {
    $generated -match "RelativePaths @\('bridge-platform\.ps1', 'bridge-test-guard\.ps1', 'bridge-download\.ps1'\)"
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

# --- installed, then something after it failed -------------------------------------
# Three different things used to come out as one undifferentiated `child exit 1`:
# nothing installed, installed but a follow-up step failed, and installed and healthy.
# A stale Codex marketplace made every `codex plugin` command exit 1 *after* the
# installer had printed "All good", and the update reported itself failed while
# `agent-ha-bridge status` showed the new version with every check green (#124).
& {
    # The real generator runs; only the child process is replaced, and it writes the
    # terminal result the child would have written - a failure, after the installer
    # recorded the new version.
    function New-StubbedUpdateChild {
        param([string]$ScriptPath, [string]$FailureText)
        $text = Get-Content -LiteralPath $ScriptPath -Raw
        $resultFile = ([regex]::Match($text, "(?m)^\`$resultFile = '(?<p>.*)'\s*$").Groups['p'].Value) -replace "''", "'"
        $attemptId = [regex]::Match($text, "attemptId = '(?<id>[a-f0-9]{32})'").Groups['id'].Value
        @{
            schemaVersion = 1; attemptId = $attemptId; success = $false; exitCode = 1
            version = '9.9.9'; releaseUrl = 'https://github.com/x/y/releases/tag/v9.9.9'
            error = $FailureText; at = [DateTimeOffset]::Now.ToString('o')
        } | ConvertTo-Json -Compress | Set-Content -LiteralPath $resultFile -Encoding UTF8
        [pscustomobject]@{ ExitCode = 1 }
    }

    function Start-Process {
        param($FilePath, $ArgumentList, $WindowStyle, $RedirectStandardOutput, $RedirectStandardError,
              [switch]$PassThru, [switch]$Wait, $ErrorAction)
        New-StubbedUpdateChild -ScriptPath (([string]@($ArgumentList)[-1]).Trim('"')) `
            -FailureText 'codex plugin list exited 1'
    }

    function Get-BridgeInstalledVersion { param([switch]$Refresh) '9.9.9' }
    $afterInstall = Invoke-BridgeSelfUpdate
    Test-That 'a step failing after the install is not reported as the update failing' {
        $afterInstall.State -eq 'Incomplete' -and -not $afterInstall.Success
    } "$($afterInstall.State): $($afterInstall.Detail)"
    Test-That 'it says the release installed, names the step that failed, and says what to run' {
        $afterInstall.Detail -match 'installed 9\.9\.9' -and
            $afterInstall.Detail -match 'codex plugin list exited 1' -and
            $afterInstall.Detail -match 'agent-ha-bridge status'
    } $afterInstall.Detail

    # And the distinction has to be the recorded version, not optimism: an installer
    # that never got that far really did fail, and must still say so.
    function Get-BridgeInstalledVersion { param([switch]$Refresh) '1.0.0' }
    $neverInstalled = Invoke-BridgeSelfUpdate
    Test-That 'while an update that never recorded the release is still a failure' {
        $neverInstalled.State -eq 'Failed' -and $neverInstalled.Detail -match 'update to 9\.9\.9 failed'
    } "$($neverInstalled.State): $($neverInstalled.Detail)"
}

Test-That 'a pre-release is not mistaken for the release it is named after' {
    (Test-BridgeUpdateReachedInstall -Attempted '1.2.3' -Recorded 'v1.2.3') -and
        -not (Test-BridgeUpdateReachedInstall -Attempted '1.2.3' -Recorded '1.2.3-rc.1') -and
        -not (Test-BridgeUpdateReachedInstall -Attempted '1.2.3' -Recorded '') -and
        -not (Test-BridgeUpdateReachedInstall -Attempted '' -Recorded '1.2.3')
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

# --- what `status` reads back without making a request ----------------------------
# A refused check retains the last known release, so on the dashboard a machine that
# has not successfully checked in days looks exactly like one that is current (#153).
# `status` reads the cache the daemon already wrote rather than asking GitHub again.
$summaryDir = Join-Path $env:TEMP ("bridge-summary-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null
$summaryPath = Join-Path $summaryDir 'agent-bridge-update.json'
try {
    Test-That 'no cache at all is nothing to report, not a fault' {
        $null -eq (Get-BridgeUpdateCheckSummary -Path (Join-Path $summaryDir 'absent.json'))
    }
    'not json at all' | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    Test-That 'and neither is one that cannot be read' {
        $null -eq (Get-BridgeUpdateCheckSummary -Path $summaryPath)
    }

    [pscustomobject]@{
        CheckedAt = [DateTimeOffset]::Now.ToString('o'); Reached = $true; State = 'Found'
        Detail = ''; RetryAt = $null; RateLimitStrikes = 0; TokenSource = '$env:GH_TOKEN'; TokenNote = ''
        Release = [pscustomobject]@{ Tag = 'v9.9.7' }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    $answered = Get-BridgeUpdateCheckSummary -Path $summaryPath
    Test-That 'an answered check names the release and the credential that got it' {
        $answered.Answered -and $answered.Verdict -eq 'found v9.9.7' -and
            $answered.AllowanceKnown -and $answered.TokenSource -eq '$env:GH_TOKEN'
    } "$($answered.Verdict) / $($answered.TokenSource)"

    [pscustomobject]@{
        CheckedAt = [DateTimeOffset]::Now.ToString('o'); Reached = $false; State = 'RateLimited'
        Detail = 'x'; RetryAt = $null; RateLimitStrikes = 1; TokenSource = ''
        TokenNote = 'updates.token was rejected by GitHub (bad credentials); the check ran unauthenticated instead.'
        Release = $null
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    $refused = Get-BridgeUpdateCheckSummary -Path $summaryPath
    Test-That 'a refused check reads as refused rather than as current' {
        -not $refused.Answered -and $refused.Verdict -match 'rate limiting'
    } $refused.Verdict
    Test-That 'and an empty source is a check that really did go out unauthenticated' {
        $refused.AllowanceKnown -and $refused.TokenSource -eq '' -and $refused.TokenNote -match 'rejected'
    } "known=$($refused.AllowanceKnown) note=$($refused.TokenNote)"

    # The cache a machine is carrying the moment it takes this release was written by
    # the version before it, which had no TokenSource field - and *could* already
    # authenticate from updates.token or an ambient GH_TOKEN. Reading that absence as
    # "unauthenticated" would tell a machine that already has a token to go and
    # configure one, for as long as that cache lasts. Raised by Codex on #153.
    [pscustomobject]@{
        CheckedAt = [DateTimeOffset]::Now.ToString('o'); Reached = $false; State = 'RateLimited'
        Detail = 'x'; RetryAt = $null; RateLimitStrikes = 1; Release = $null
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    $legacy = Get-BridgeUpdateCheckSummary -Path $summaryPath
    Test-That 'a cache written before the field is unknown, not proof of an unauthenticated check' {
        -not $legacy.AllowanceKnown -and $legacy.TokenSource -eq '' -and $legacy.Verdict -match 'rate limiting'
    } "known=$($legacy.AllowanceKnown)"
}
finally { Remove-Item -LiteralPath $summaryDir -Recurse -Force -ErrorAction SilentlyContinue }

# --- where the download has got to -------------------------------------------------
# The emitter #155 was missing, driven against an ordinary Stream. The socket is not
# the interesting part - what gets reported while bytes arrive is - and the buffer and
# throttle are script-scope so this is deterministic rather than timed with sleeps.
$downloadDir = Join-Path $env:TEMP ("bridge-download-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
$downloadFile = Join-Path $downloadDir 'release.zip'
$payload = [byte[]]::new(10000)
[Random]::new(1155).NextBytes($payload)
$priorBuffer = $script:BridgeDownloadBufferSize
$priorInterval = $script:BridgeDownloadReportIntervalMs
try {
    # One hundred reads of one percent each.
    $script:BridgeDownloadBufferSize = 100

    $script:BridgeDownloadReportIntervalMs = 0
    $reports = [Collections.Generic.List[double]]::new()
    $source = [IO.MemoryStream]::new($payload)
    $result = Write-BridgeDownloadStream -Source $source -OutFile $downloadFile -Total $payload.Length `
        -OnProgress { param([double]$p) $reports.Add($p) }
    $source.Dispose()

    Test-That 'the whole body is written, byte for byte' {
        $result.Bytes -eq $payload.Length -and
            ((Get-FileHash -LiteralPath $downloadFile -Algorithm SHA256).Hash -eq
             [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($payload)).Replace('-', ''))
    } "wrote $($result.Bytes) of $($payload.Length)"
    Test-That 'a stated length is reported one whole percent at a time' {
        $reports.Count -eq 100
    } "reports=$($reports.Count)"
    Test-That 'every proportion is inside the range the card will draw, and never zero' {
        @($reports | Where-Object { $_ -le 0 -or $_ -gt 1 }).Count -eq 0
    } "first=$($reports[0]) last=$($reports[$reports.Count - 1])"
    Test-That 'and they only ever move forwards, ending on a full bar' {
        $ascending = $true
        for ($i = 1; $i -lt $reports.Count; $i++) { if ($reports[$i] -le $reports[$i - 1]) { $ascending = $false } }
        $ascending -and $reports[$reports.Count - 1] -eq 1
    } "last=$($reports[$reports.Count - 1])"

    # Every chunk would rewrite the progress record continuously for the whole
    # download, on the disk the installer is about to write to.
    $script:BridgeDownloadReportIntervalMs = 1000
    $throttled = [Collections.Generic.List[double]]::new()
    $source = [IO.MemoryStream]::new($payload)
    [void](Write-BridgeDownloadStream -Source $source -OutFile $downloadFile -Total $payload.Length `
        -OnProgress { param([double]$p) $throttled.Add($p) })
    $source.Dispose()
    Test-That 'a second between reports holds an instant transfer to a single one' {
        $throttled.Count -eq 1
    } "reports=$($throttled.Count)"

    # codeload sends no Content-Length on a HEAD and ignores a Range request, so a
    # body whose length the server never stated has to read as no proportion - never
    # as 0 and never as 100, either of which is a bar that cannot be believed.
    $script:BridgeDownloadReportIntervalMs = 0
    $silent = [Collections.Generic.List[double]]::new()
    $source = [IO.MemoryStream]::new($payload)
    $unknown = Write-BridgeDownloadStream -Source $source -OutFile $downloadFile -Total 0 `
        -OnProgress { param([double]$p) $silent.Add($p) }
    $source.Dispose()
    Test-That 'a body with no stated length downloads with no proportion at all' {
        $silent.Count -eq 0 -and -not $unknown.Proportioned -and $unknown.Bytes -eq $payload.Length
    } "reports=$($silent.Count) proportioned=$($unknown.Proportioned)"

    # The progress report drives a best-effort stage writer. One that throws must not
    # be able to fail an update that is otherwise fine.
    $source = [IO.MemoryStream]::new($payload)
    $despiteThrow = Write-BridgeDownloadStream -Source $source -OutFile $downloadFile -Total $payload.Length `
        -OnProgress { param([double]$p) throw 'the progress file is locked' }
    $source.Dispose()
    Test-That 'a progress report that throws does not fail the download it describes' {
        $despiteThrow.Bytes -eq $payload.Length
    } "wrote $($despiteThrow.Bytes)"

    # A truncated archive is worse than none: Expand-Archive fails on it with a ZIP
    # error, and the update is then reported as a corrupt release rather than as an
    # interrupted download.
    Remove-Item -LiteralPath $downloadFile -Force -ErrorAction SilentlyContinue
    $broken = [IO.MemoryStream]::new($payload)
    $broken.Dispose()
    $threw = $false
    try { [void](Write-BridgeDownloadStream -Source $broken -OutFile $downloadFile -Total $payload.Length) }
    catch { $threw = $true }
    Test-That 'an interrupted transfer throws and leaves no half-written archive behind' {
        $threw -and -not (Test-Path -LiteralPath $downloadFile)
    } "threw=$threw exists=$(Test-Path -LiteralPath $downloadFile)"
}
finally {
    $script:BridgeDownloadBufferSize = $priorBuffer
    $script:BridgeDownloadReportIntervalMs = $priorInterval
    Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- reading progress back ---------------------------------------------------------
# A display, not a verdict. Read-BridgeUpdateOutcome throws on anything unexpected
# because it guards the claim that an update succeeded; this must never turn a healthy
# update into a reported fault, so everything it cannot trust reads as "nothing yet".
$stageDir = Join-Path $env:TEMP ("bridge-stage-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
$stagePath = Join-Path $stageDir 'progress.json'
function Set-StageFile {
    param([hashtable]$Record)
    ($Record | ConvertTo-Json -Compress) | Set-Content -LiteralPath $stagePath -Encoding UTF8
}
try {
    Test-That 'no progress file at all is simply nothing to show' {
        $null -eq (Read-BridgeUpdateStage -Path (Join-Path $stageDir 'absent.json'))
    }

    Set-StageFile @{ schemaVersion = 1; attemptId = 'a1'; stage = 'downloading'; version = '9.9.9'; detail = ''; proportion = 0.5; at = [DateTimeOffset]::Now.ToString('o') }
    $live = Read-BridgeUpdateStage -Path $stagePath -AttemptId 'a1'
    Test-That 'a current record reports the stage, the version and the proportion' {
        $live.Stage -eq 'downloading' -and $live.Version -eq '9.9.9' -and $live.Proportion -eq 0.5 -and -not $live.Done
    } "$($live | Out-String)"

    Test-That 'a record from another attempt is not this attempt''s progress' {
        $null -eq (Read-BridgeUpdateStage -Path $stagePath -AttemptId 'a2')
    }

    Test-That 'nor is one that predates the attempt asking' {
        $null -eq (Read-BridgeUpdateStage -Path $stagePath -AttemptId 'a1' -NotBefore ([DateTimeOffset]::Now.AddMinutes(5)))
    }

    foreach ($bad in @(0.5, 'half', -1, 2)) {
        Set-StageFile @{ schemaVersion = 1; attemptId = 'a1'; stage = 'downloading'; version = '9.9.9'; detail = ''; proportion = $bad; at = [DateTimeOffset]::Now.ToString('o') }
        $read = Read-BridgeUpdateStage -Path $stagePath -AttemptId 'a1'
        if ($bad -eq 0.5) { continue }
        Test-That "a proportion of '$bad' is shown as no proportion rather than drawn somewhere arbitrary" {
            $read.Stage -eq 'downloading' -and $null -eq $read.Proportion
        } "proportion=$($read.Proportion)"
    }

    Set-StageFile @{ schemaVersion = 1; attemptId = 'a1'; stage = 'sideways'; version = '9.9.9'; detail = ''; proportion = -1; at = [DateTimeOffset]::Now.ToString('o') }
    Test-That 'a stage nobody can interpret is no progress at all' {
        $null -eq (Read-BridgeUpdateStage -Path $stagePath -AttemptId 'a1')
    }

    Set-StageFile @{ schemaVersion = 2; attemptId = 'a1'; stage = 'downloading'; version = '9.9.9'; detail = ''; proportion = -1; at = [DateTimeOffset]::Now.ToString('o') }
    Test-That 'so is a schema this does not know' {
        $null -eq (Read-BridgeUpdateStage -Path $stagePath -AttemptId 'a1')
    }

    Set-Content -LiteralPath $stagePath -Value 'this is not json' -Encoding UTF8
    Test-That 'an unreadable record reads as nothing to show, never as a failed update' {
        $null -eq (Read-BridgeUpdateStage -Path $stagePath -AttemptId 'a1')
    }

    foreach ($terminal in @('completed', 'failed')) {
        Set-StageFile @{ schemaVersion = 1; attemptId = 'a1'; stage = $terminal; version = '9.9.9'; detail = 'why'; proportion = -1; at = [DateTimeOffset]::Now.ToString('o') }
        $end = Read-BridgeUpdateStage -Path $stagePath -AttemptId 'a1'
        Test-That "'$terminal' is reported as finished, carrying its detail" {
            $end.Done -and $end.Stage -eq $terminal -and $end.Detail -eq 'why'
        }
    }
}
finally { Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) test(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All tests passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
