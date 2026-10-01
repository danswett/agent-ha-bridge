<#
    Keeping a Microsoft Dev Box from hibernating the bridge out from under itself.

    A Dev Box pool can have stop-on-disconnect enabled, and when it is, the Dev Box
    agent hibernates the machine `gracePeriodMinutes` after the last RDP or tunnel
    session goes away. Idleness there is measured by *sessions*, not by load, so a
    machine busy running the daemon and several agent sessions looks exactly as idle
    as one doing nothing. On 2026-09-30 a Dev Box hibernated with its CPU averaging
    12-19%: the daemon stopped mid-reconcile, the machine's liveness beat stopped, and
    Home Assistant showed it offline with nothing anywhere saying why.

    Dev Center exposes that pending stop to the owning user as a schedulable action,
    and the developer REST API lets the user skip or delay it. That is a documented,
    user-scoped API (`users/me`), not a back door, which is what makes this safe to
    automate rather than having to disable the Dev Box agent.

    Two service-enforced limits shape everything below. Both were established by
    probing the live API on 2026-09-30, and both are the reason this has to run on a
    timer rather than once:

      * `DelayUntilTimeExceedLimit` - "A maximum delay of 8 hours is allowed from
        original scheduled time". Delays do not stack: an occurrence can only ever be
        pushed 8 hours past where it first landed.
      * `DevBoxActionPreferenceUpdateNotInAllowedTimeWindow` - "The target devbox
        action is more than 24 hours away, skip or delay can't be applied". An action
        already beyond 24 hours cannot be touched - which is the state this is trying
        to reach, so it is success, not failure.

    Skip is attempted before delay because it clears the occurrence outright instead
    of moving it, leaving nothing to re-delay on the next pass. Delay is the fallback
    for a pool or API version where skip is refused.

    Deliberately no top-level Set-StrictMode: this library is dot-sourced, and
    Set-StrictMode leaks into the dot-sourcing scope.
#>

$script:BridgeDevBoxResource = 'https://devcenter.azure.com'
$script:BridgeDevBoxApiVersion = '2024-02-01'
# Tried largest first: the 8-hour ceiling is measured from where the action
# originally landed, which the API never reports back, so the only way to find the
# remaining headroom is to ask for progressively less.
$script:BridgeDevBoxDelayLadder = @(8, 6, 4, 2, 1)

function Get-BridgeDevBoxAgentSettingsPath {
    <#
        The Dev Box agent's own settings file, which is the only place the machine
        records which project, pool and Dev Box it is. -Root is injectable so a test
        can point at a fixture instead of Program Files.
    #>
    param([string]$Root = 'C:\Program Files\Microsoft Dev Box Agent')

    if (-not (Test-Path -LiteralPath $Root)) { return $null }
    $found = Get-ChildItem -LiteralPath $Root -Recurse -Filter 'appsettings.Production.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($found) { return $found.FullName }
    $null
}

function Get-BridgeDevBoxIdentity {
    <#
        Where this Dev Box lives, or $null when the machine is not one.

        Read from the agent's settings rather than configured by hand, so the bridge
        keeps working after a reprovision onto a different pool, project or region -
        and so an ordinary desktop simply reports "not a Dev Box" instead of needing
        the feature turned off explicitly.
    #>
    param([string]$SettingsPath)

    if (-not $SettingsPath) { $SettingsPath = Get-BridgeDevBoxAgentSettingsPath }
    if (-not $SettingsPath -or -not (Test-Path -LiteralPath $SettingsPath)) { return $null }

    try {
        $parsed = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $meta = $parsed.DevBoxAgent.metadata

        $endpoint = ([string]$meta.devCenterUrl).TrimEnd('/')
        $project = [string]$meta.projectName
        # devBoxDataplaneId is "<tenant>:<devcenter>:<project>:<userObjectId>:<devBoxName>".
        # The Dev Box's own name appears nowhere else in the file, so it has to come
        # from the tail of this.
        $devBox = ([string]$meta.devBoxDataplaneId -split ':')[-1]

        if ([string]::IsNullOrWhiteSpace($endpoint) -or
            [string]::IsNullOrWhiteSpace($project) -or
            [string]::IsNullOrWhiteSpace($devBox)) {
            return $null
        }

        [pscustomobject]@{ Endpoint = $endpoint; Project = $project; DevBox = $devBox }
    }
    catch {
        # A settings file this script cannot parse is indistinguishable from not being
        # on a Dev Box, and neither is worth failing an install over.
        $null
    }
}

function Test-BridgeDevBox {
    <# Whether this machine is a Microsoft Dev Box. #>
    param([string]$SettingsPath)
    $null -ne (Get-BridgeDevBoxIdentity -SettingsPath $SettingsPath)
}

function Get-BridgeDevBoxAccessToken {
    <#
        A Dev Center token for the signed-in user, from the Azure CLI's own cache.

        The CLI is used rather than a device-code flow of our own because the user is
        already signed in to it on a Dev Box, and because the token must belong to the
        *user* - `users/me` is the only scope that can delay their own Dev Box.
    #>
    param([scriptblock]$TokenCommand)

    if (-not $TokenCommand) {
        $TokenCommand = {
            param($Resource)
            $value = & az account get-access-token --resource $Resource --query accessToken -o tsv 2>$null
            if ($LASTEXITCODE -ne 0) { return '' }
            [string]$value
        }
    }

    $token = [string](& $TokenCommand $script:BridgeDevBoxResource)
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "No Dev Center token. Run 'az login' as this user."
    }
    $token.Trim()
}

function Get-BridgeDevBoxStopAction {
    <#
        The pending stop actions on this Dev Box, newest schedule first.

        Returns a real (possibly empty) array: a function returning an empty array
        bare yields $null under Set-StrictMode, and the caller counts these.
    #>
    param(
        [Parameter(Mandatory)][pscustomobject]$Identity,
        [Parameter(Mandatory)][hashtable]$Headers,
        [scriptblock]$Invoke
    )

    if (-not $Invoke) { $Invoke = { param($Method, $Uri, $Head) Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Head } }

    $uri = '{0}/projects/{1}/users/me/devboxes/{2}/actions?api-version={3}' -f `
        $Identity.Endpoint, $Identity.Project, $Identity.DevBox, $script:BridgeDevBoxApiVersion
    $response = & $Invoke 'GET' $uri $Headers
    , @(@($response.value) | Where-Object { $_ -and [string]$_.actionType -eq 'Stop' })
}

function Get-BridgeDevBoxErrorCode {
    <#
        The service's own error code, which says why far better than the status line -
        "DevBoxActionPreferenceUpdateNotInAllowedTimeWindow" is a diagnosis, where
        "400 (Bad Request)" is not.
    #>
    param([Parameter(Mandatory)]$ErrorRecord)

    try {
        $detail = $ErrorRecord.ErrorDetails.Message | ConvertFrom-Json
        $codes = @(@($detail.error.details) | Where-Object { $_ -and $_.code } | ForEach-Object { [string]$_.code })
        if ($codes.Count -gt 0) { return ($codes -join ', ') }
        if ($detail.error.code) { return [string]$detail.error.code }
    }
    catch {
        # Not a Dev Center error envelope; the exception message is all there is.
    }
    [string]$ErrorRecord.Exception.Message
}

function Invoke-BridgeDevBoxReprieve {
    <#
        Clears one pending stop, and says which lever worked.

        Skip first - it removes the occurrence rather than moving it - then delay,
        asking for the largest push the service will still accept.
    #>
    param(
        [Parameter(Mandatory)][pscustomobject]$Identity,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)]$Action,
        [scriptblock]$Invoke,
        [scriptblock]$Logger
    )

    if (-not $Invoke) { $Invoke = { param($Method, $Uri, $Head) Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Head } }
    if (-not $Logger) { $Logger = { param($Message) } }

    $base = '{0}/projects/{1}/users/me/devboxes/{2}/actions/{3}' -f `
        $Identity.Endpoint, $Identity.Project, $Identity.DevBox, $Action.name

    try {
        & $Invoke 'POST' "${base}:skip?api-version=$($script:BridgeDevBoxApiVersion)" $Headers | Out-Null
        return [pscustomobject]@{ Status = 'skipped'; Detail = "skipped '$($Action.name)'" }
    }
    catch {
        & $Logger "skip refused for '$($Action.name)' ($(Get-BridgeDevBoxErrorCode $_)); trying delay"
    }

    $scheduled = [datetimeoffset]::Parse([string]$Action.next.scheduledTime).ToUniversalTime()
    foreach ($hours in $script:BridgeDevBoxDelayLadder) {
        $until = $scheduled.AddHours($hours).ToString('yyyy-MM-ddTHH:mm:ssZ')
        try {
            $result = & $Invoke 'POST' "${base}:delay?until=$until&api-version=$($script:BridgeDevBoxApiVersion)" $Headers
            $moved = if ($result -and $result.next) { [string]$result.next.scheduledTime } else { $until }
            return [pscustomobject]@{ Status = 'delayed'; Detail = "delayed '$($Action.name)' by ${hours}h to $moved" }
        }
        catch {
            & $Logger "delay +${hours}h refused ($(Get-BridgeDevBoxErrorCode $_))"
        }
    }

    [pscustomobject]@{
        Status = 'blocked'
        Detail = "could not move '$($Action.name)'; it is already as far out as the service allows"
    }
}

function Invoke-BridgeDevBoxKeepAwake {
    <#
        One pass: find any pending stop that is close enough to act on, and push it
        away.

        Everything that reaches outside the process is injectable, so the whole thing
        runs under the offline test guard.
    #>
    param(
        [scriptblock]$IdentityProvider,
        [scriptblock]$TokenProvider,
        [scriptblock]$Invoke,
        [scriptblock]$Logger,
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow,
        [switch]$DryRun
    )

    if (-not $IdentityProvider) { $IdentityProvider = { Get-BridgeDevBoxIdentity } }
    if (-not $TokenProvider) { $TokenProvider = { Get-BridgeDevBoxAccessToken } }
    if (-not $Logger) { $Logger = { param($Message) } }

    $identity = & $IdentityProvider
    if (-not $identity) {
        return [pscustomobject]@{ Status = 'not-a-devbox'; Detail = 'this machine is not a Dev Box'; Actions = @() }
    }

    $headers = @{ Authorization = "Bearer $(& $TokenProvider)" }
    # Assigned straight from the call, never wrapped in @(). Get-BridgeDevBoxStopAction
    # already guarantees an array with the unary comma, and @() around a value that is
    # *already* an array does not flatten it - it wraps it again. With no pending stop
    # that produced a one-element array holding an empty array, which then failed on
    # $action.next with "The property 'next' cannot be found on this object" instead of
    # taking the no-action path.
    $actions = Get-BridgeDevBoxStopAction -Identity $identity -Headers $headers -Invoke $Invoke
    if ($actions.Count -eq 0) {
        return [pscustomobject]@{ Status = 'no-action'; Detail = "no pending stop on $($identity.DevBox)"; Actions = @() }
    }

    $outcomes = @()
    foreach ($action in $actions) {
        $scheduled = [datetimeoffset]::Parse([string]$action.next.scheduledTime).ToUniversalTime()
        $hoursAway = [math]::Round(($scheduled - $Now).TotalHours, 2)

        if ($hoursAway -gt 24) {
            # Beyond 24 hours the service refuses both levers, but that is precisely
            # the state worth reaching, so report it as safe rather than as a failure.
            $outcomes += [pscustomobject]@{
                Status = 'safe'
                Detail = "'$($action.name)' is ${hoursAway}h away (> 24h); already safe"
            }
            continue
        }

        & $Logger "'$($action.name)' fires in ${hoursAway}h at $($scheduled.ToLocalTime().ToString('yyyy-MM-dd HH:mm')) local"
        if ($DryRun) {
            $outcomes += [pscustomobject]@{ Status = 'dry-run'; Detail = "would clear '$($action.name)'" }
            continue
        }
        $outcomes += (Invoke-BridgeDevBoxReprieve -Identity $identity -Headers $headers `
            -Action $action -Invoke $Invoke -Logger $Logger)
    }

    # 'blocked' is the only outcome a person needs to act on, so it wins the summary
    # even when another action was cleared happily.
    $blocked = @($outcomes | Where-Object { $_.Status -eq 'blocked' })
    $status = if ($blocked.Count -gt 0) { 'blocked' } else { [string]$outcomes[0].Status }

    [pscustomobject]@{
        Status  = $status
        Detail  = (@($outcomes | ForEach-Object { $_.Detail }) -join '; ')
        Actions = $outcomes
    }
}
