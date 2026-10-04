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

    $lookup = [pscustomobject]@{ State = 'Unavailable'; Release = $null; Detail = 'The latest release could not be established.' }
    if (-not $Force -and $null -ne $cache -and $cache.PSObject.Properties['CheckedAt']) {
        $checkedAt = $null
        try { $checkedAt = ConvertTo-BridgeUpdateTime $cache.CheckedAt }
        catch [FormatException] { Write-Warning 'The update cache has an invalid check time; checking again.' }
        if ($null -ne $checkedAt) {
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
            $window = if ($lookup.State -eq 'Unavailable') {
                [Math]::Min($CheckHours, $script:BridgeUpdateConfig.RetryMinutes / 60)
            } else { $CheckHours }
            $age = ([DateTimeOffset]::Now - $checkedAt).TotalHours
            if ($age -ge 0 -and $age -lt $window) {
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
        $response = Invoke-RestMethod -Uri $uri `
            -Headers @{ 'User-Agent' = $script:BridgeUpdateConfig.UserAgent; Accept = 'application/vnd.github+json' } `
            -TimeoutSec $script:BridgeUpdateConfig.RequestTimeout

        $release = [pscustomobject]@{
            Tag       = [string]$response.tag_name
            Name      = [string]$response.name
            Url       = [string]$response.html_url
            Zip       = [string]$response.zipball_url
            Notes     = [string]$response.body
            Published = [string]$response.published_at
        }
        if (-not (Test-BridgeUpdateRelease $release)) { throw 'The latest-release response has invalid version or download metadata.' }
        $lookup.State = 'Found'
        $lookup.Release = $release
        $lookup.Detail = ''
    }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        $status = 0
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        if ($status -eq 404) {
            $lookup.State = 'NotFound'
            $lookup.Detail = 'GitHub returned 404 for the latest-release endpoint; repository existence and access are not confirmed.'
        }
        else { $lookup.Detail = "The latest release could not be established: $($_.Exception.Message)" }
    }

    [pscustomobject]@{
        CheckedAt = [DateTimeOffset]::Now.ToString('o')
        Reached   = ($lookup.State -ne 'Unavailable')
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
    Write-UpdateLog 'installer and restart request complete; local installation health is not certified'
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
        $result.Detail = "installer completed for $($status.Latest); currently recorded version $($result.InstalledVersion); required local installation health is not certified"
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
