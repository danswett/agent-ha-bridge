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
