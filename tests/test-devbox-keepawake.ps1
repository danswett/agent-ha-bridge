#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for keeping a Microsoft Dev Box from hibernating the bridge out from
    under itself.

.DESCRIPTION
    A Dev Box pool with stop-on-disconnect measures idleness by RDP and tunnel
    sessions rather than by load, so a Dev Box busy running the daemon and several
    agent sessions is hibernated anyway - the daemon stops mid-reconcile and the
    machine simply reads as offline on the dashboard with nothing saying why.

    The fix leans on Dev Center's own user-scoped action API, which exposes the
    pending stop and lets its owner skip or delay it. Two service-enforced limits
    shape the logic, both established against the live API on 2026-09-30 and both
    asserted here as error codes rather than as status lines:

      * a delay may not exceed 8 hours past where the action *originally* landed, so
        delays do not stack and the ladder has to step down to find the headroom;
      * neither lever may be used while the action is more than 24 hours away, which
        is the state worth reaching and so must be read as success.

    Nothing here touches the network or Task Scheduler: identity comes from a fixture
    settings file, and the token and every HTTP call are injected. The installer's
    own decisions are deliberately pure functions for the same reason - the offline
    suite also runs on the macOS CI leg, where ScheduledTasks does not exist.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\bridge-devbox.ps1')

$script:Failures = 0
function Test-That {
    # Underscored locals: an assertion scriptblock resolves its free variables in this
    # scope, so a plain $ok here would shadow one the caller set up for it to read.
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $__ok = $false
    try { $__ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($__ok) { Write-Host "  PASS  $Name" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

function New-DevBoxSettingsFixture {
    <# The shape the Dev Box agent actually writes, trimmed to what is read. #>
    param(
        [string]$DataplaneId = '72f988bf:devcenter-abc-dc:engprodspace:40978b68:dswett-dev',
        [string]$DevCenterUrl = 'https://72f988bf-devcenter-abc-dc.westus3.devcenter.azure.com/',
        [string]$ProjectName = 'EngProdSPACE'
    )
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("devbox-fixture-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir 'appsettings.Production.json'
    @{
        DevBoxAgent = @{
            disableIdleDetection = $false
            metadata = @{
                devCenterUrl = $DevCenterUrl
                projectName = $ProjectName
                devBoxDataplaneId = $DataplaneId
                poolName = 'WE-SPACE-Base-Pool-West'
            }
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8
    $path
}

function New-DevCenterError {
    <#
        A Dev Center 400, with the error envelope the service really sends. The code
        buried in error.details is the only part that says what went wrong.
    #>
    param([string]$Code)
    $body = @{
        status = 'Failed'
        error = @{
            code = 'ValidationError'
            message = 'The request is not valid.'
            details = @(@{ code = $Code; message = 'detail' })
        }
    } | ConvertTo-Json -Depth 8
    $record = [System.Management.Automation.ErrorRecord]::new(
        [Exception]::new('Response status code does not indicate success: 400 (Bad Request).'),
        'BadRequest', [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
    $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($body)
    $record
}

function New-ActionResponse {
    <# The actions list, with one pending stop at the given time. #>
    param([string]$ScheduledTime, [string]$Name = 'idle-stopondisconnect')
    [pscustomobject]@{
        value = @(
            [pscustomobject]@{
                name = $Name
                actionType = 'Stop'
                sourceType = 'Pool'
                next = [pscustomobject]@{ scheduledTime = $ScheduledTime }
            }
        )
    }
}

$fixedNow = [datetimeoffset]::Parse('2026-09-30T22:00:00Z')
$identity = [pscustomobject]@{
    Endpoint = 'https://dc.example.com'
    Project  = 'EngProdSPACE'
    DevBox   = 'dswett-dev'
}
$noToken = { 'fake-token' }
$asIdentity = { $identity }.GetNewClosure()

Write-Host '--- recognising a Dev Box ---'

Test-That 'the project, endpoint and Dev Box name are read from the agent settings' {
    $read = Get-BridgeDevBoxIdentity -SettingsPath (New-DevBoxSettingsFixture)
    $read.Project -eq 'EngProdSPACE' -and
    $read.DevBox -eq 'dswett-dev' -and
    $read.Endpoint -eq 'https://72f988bf-devcenter-abc-dc.westus3.devcenter.azure.com'
}

Test-That 'the Dev Box name comes from the tail of devBoxDataplaneId' {
    $path = New-DevBoxSettingsFixture -DataplaneId 'tenant:dc:proj:user:some-other-box'
    (Get-BridgeDevBoxIdentity -SettingsPath $path).DevBox -eq 'some-other-box'
}

Test-That 'a machine with no Dev Box agent is not a Dev Box' {
    $null -eq (Get-BridgeDevBoxIdentity -SettingsPath (Join-Path ([IO.Path]::GetTempPath()) 'definitely-absent.json'))
}

Test-That 'settings that do not parse are treated as not a Dev Box, not as an error' {
    $path = Join-Path ([IO.Path]::GetTempPath()) ("broken-" + [guid]::NewGuid().ToString('N') + '.json')
    Set-Content -LiteralPath $path -Value '{ this is not json' -Encoding utf8
    $null -eq (Get-BridgeDevBoxIdentity -SettingsPath $path)
}

Test-That 'settings missing the dataplane id are treated as not a Dev Box' {
    $path = New-DevBoxSettingsFixture -DataplaneId ''
    $null -eq (Get-BridgeDevBoxIdentity -SettingsPath $path)
}

Test-That 'Test-BridgeDevBox answers the same question as a boolean' {
    (Test-BridgeDevBox -SettingsPath (New-DevBoxSettingsFixture)) -and
    -not (Test-BridgeDevBox -SettingsPath (Join-Path ([IO.Path]::GetTempPath()) 'nope.json'))
}

Write-Host ''
Write-Host '--- reading the service back ---'

Test-That 'the error code is taken from the envelope, not the status line' {
    (Get-BridgeDevBoxErrorCode (New-DevCenterError 'DelayUntilTimeExceedLimit')) -eq 'DelayUntilTimeExceedLimit'
}

Test-That 'an error with no envelope falls back to the exception message' {
    $record = [System.Management.Automation.ErrorRecord]::new(
        [Exception]::new('socket closed'), 'x', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
    (Get-BridgeDevBoxErrorCode $record) -eq 'socket closed'
}

Test-That 'only Stop actions are considered' {
    $mixed = [pscustomobject]@{ value = @(
        [pscustomobject]@{ name = 'repair'; actionType = 'Repair'; next = [pscustomobject]@{ scheduledTime = '2026-10-01T00:00:00Z' } },
        [pscustomobject]@{ name = 'idle-stopondisconnect'; actionType = 'Stop'; next = [pscustomobject]@{ scheduledTime = '2026-10-01T00:00:00Z' } }
    ) }
    $found = Get-BridgeDevBoxStopAction -Identity $identity -Headers @{} -Invoke { param($m, $u, $h) $mixed }.GetNewClosure()
    $found.Count -eq 1 -and $found[0].name -eq 'idle-stopondisconnect'
}

Test-That 'an actions list with nothing in it yields an empty array, not null' {
    $empty = [pscustomobject]@{ value = @() }
    $found = Get-BridgeDevBoxStopAction -Identity $identity -Headers @{} -Invoke { param($m, $u, $h) $empty }.GetNewClosure()
    $null -ne $found -and $found.Count -eq 0
}

Write-Host ''
Write-Host '--- clearing a pending stop ---'

Test-That 'a stop more than 24 hours away is already safe and is not touched' {
    $calls = [System.Collections.ArrayList]::new()
    $far = New-ActionResponse -ScheduledTime '2026-10-03T05:00:00Z'
    $invoke = {
        param($Method, $Uri, $Head)
        [void]$calls.Add("$Method $Uri")
        $far
    }.GetNewClosure()
    $result = Invoke-BridgeDevBoxKeepAwake -IdentityProvider $asIdentity -TokenProvider $noToken `
        -Invoke $invoke -Now $fixedNow
    # One call only: the GET. Neither lever may be used out there, and trying would
    # log a failure for what is actually the desired state.
    $result.Status -eq 'safe' -and $calls.Count -eq 1 -and $calls[0].StartsWith('GET ')
}

Test-That 'a stop inside the window is skipped' {
    $near = New-ActionResponse -ScheduledTime '2026-09-30T23:00:00Z'
    $seen = [System.Collections.ArrayList]::new()
    $invoke = {
        param($Method, $Uri, $Head)
        [void]$seen.Add($Uri)
        if ($Method -eq 'GET') { return $near }
        $null
    }.GetNewClosure()
    $result = Invoke-BridgeDevBoxKeepAwake -IdentityProvider $asIdentity -TokenProvider $noToken `
        -Invoke $invoke -Now $fixedNow
    $result.Status -eq 'skipped' -and @($seen | Where-Object { $_ -match ':skip\?' }).Count -eq 1
}

Test-That 'skip is tried before delay' {
    $near = New-ActionResponse -ScheduledTime '2026-09-30T23:00:00Z'
    $order = [System.Collections.ArrayList]::new()
    $invoke = {
        param($Method, $Uri, $Head)
        if ($Method -eq 'GET') { return $near }
        if ($Uri -match ':skip\?') { [void]$order.Add('skip') } else { [void]$order.Add('delay') }
        $null
    }.GetNewClosure()
    Invoke-BridgeDevBoxKeepAwake -IdentityProvider $asIdentity -TokenProvider $noToken `
        -Invoke $invoke -Now $fixedNow | Out-Null
    $order.Count -ge 1 -and $order[0] -eq 'skip'
}

Test-That 'a refused skip falls back to delay, asking for the full 8 hours first' {
    $near = New-ActionResponse -ScheduledTime '2026-09-30T23:00:00Z'
    $delays = [System.Collections.ArrayList]::new()
    $invoke = {
        param($Method, $Uri, $Head)
        if ($Method -eq 'GET') { return $near }
        if ($Uri -match ':skip\?') { throw (New-DevCenterError 'OperationNotSupported') }
        [void]$delays.Add($Uri)
        [pscustomobject]@{ next = [pscustomobject]@{ scheduledTime = '2026-10-01T07:00:00Z' } }
    }.GetNewClosure()
    $result = Invoke-BridgeDevBoxKeepAwake -IdentityProvider $asIdentity -TokenProvider $noToken `
        -Invoke $invoke -Now $fixedNow
    # 23:00Z + 8h = 07:00Z the next day.
    $result.Status -eq 'delayed' -and $delays.Count -eq 1 -and $delays[0] -match 'until=2026-10-01T07:00:00Z'
}

Test-That 'the delay ladder steps down when the 8-hour ceiling is already used up' {
    $near = New-ActionResponse -ScheduledTime '2026-09-30T23:00:00Z'
    $asked = [System.Collections.ArrayList]::new()
    $invoke = {
        param($Method, $Uri, $Head)
        if ($Method -eq 'GET') { return $near }
        if ($Uri -match ':skip\?') { throw (New-DevCenterError 'OperationNotSupported') }
        [void]$asked.Add($Uri)
        # Everything past +2h is beyond what the service will allow this occurrence.
        if ($Uri -notmatch 'until=2026-10-01T01:00:00Z') { throw (New-DevCenterError 'DelayUntilTimeExceedLimit') }
        [pscustomobject]@{ next = [pscustomobject]@{ scheduledTime = '2026-10-01T01:00:00Z' } }
    }.GetNewClosure()
    $result = Invoke-BridgeDevBoxKeepAwake -IdentityProvider $asIdentity -TokenProvider $noToken `
        -Invoke $invoke -Now $fixedNow
    $result.Status -eq 'delayed' -and $asked.Count -eq 4 -and $result.Detail -match 'by 2h'
}

Test-That 'an occurrence that cannot be moved at all reports blocked rather than success' {
    $near = New-ActionResponse -ScheduledTime '2026-09-30T23:00:00Z'
    $invoke = {
        param($Method, $Uri, $Head)
        if ($Method -eq 'GET') { return $near }
        throw (New-DevCenterError 'DelayUntilTimeExceedLimit')
    }.GetNewClosure()
    $result = Invoke-BridgeDevBoxKeepAwake -IdentityProvider $asIdentity -TokenProvider $noToken `
        -Invoke $invoke -Now $fixedNow
    $result.Status -eq 'blocked'
}

Test-That 'a dry run reports what it would do without calling either lever' {
    $near = New-ActionResponse -ScheduledTime '2026-09-30T23:00:00Z'
    $writes = 0
    $invoke = {
        param($Method, $Uri, $Head)
        if ($Method -eq 'GET') { return $near }
        $script:unexpectedWrite = $true
        $null
    }.GetNewClosure()
    $script:unexpectedWrite = $false
    $result = Invoke-BridgeDevBoxKeepAwake -IdentityProvider $asIdentity -TokenProvider $noToken `
        -Invoke $invoke -Now $fixedNow -DryRun
    $writes = if ($script:unexpectedWrite) { 1 } else { 0 }
    $result.Status -eq 'dry-run' -and $writes -eq 0
}

Test-That 'a machine that is not a Dev Box does nothing and says so' {
    $result = Invoke-BridgeDevBoxKeepAwake -IdentityProvider { $null } -TokenProvider $noToken `
        -Invoke { param($m, $u, $h) throw 'should never be called' } -Now $fixedNow
    $result.Status -eq 'not-a-devbox'
}

Test-That 'a Dev Box with no pending stop is reported, not treated as a failure' {
    $empty = [pscustomobject]@{ value = @() }
    $result = Invoke-BridgeDevBoxKeepAwake -IdentityProvider $asIdentity -TokenProvider $noToken `
        -Invoke { param($m, $u, $h) $empty }.GetNewClosure() -Now $fixedNow
    $result.Status -eq 'no-action'
}

Test-That 'a missing Azure CLI login is a clear error, not a silent no-op' {
    $threw = $false
    try { Get-BridgeDevBoxAccessToken -TokenCommand { param($Resource) '' } }
    catch { $threw = $_.Exception.Message -match 'az login' }
    $threw
}

Write-Host ''
Write-Host '--- what the installer decides ---'

$env:BRIDGE_INSTALL_NORUN = '1'
. (Join-Path $PSScriptRoot '..\install.ps1')
Remove-Item Env:\BRIDGE_INSTALL_NORUN -ErrorAction SilentlyContinue

Test-That 'an ordinary machine never gets the task' {
    -not (Get-BridgeDevBoxKeepAwakeDecision -IsDevBox $false -Requested $true).Enabled
}
Test-That 'a Dev Box that asked for it gets the task' {
    (Get-BridgeDevBoxKeepAwakeDecision -IsDevBox $true -Requested $true).Enabled
}
Test-That 'a Dev Box that did not ask for it does not' {
    $decision = Get-BridgeDevBoxKeepAwakeDecision -IsDevBox $true -Requested $false
    -not $decision.Enabled -and $decision.Reason -eq 'not enabled'
}
Test-That 'a -TargetHome sandbox registers no machine-wide task' {
    $decision = Get-BridgeDevBoxKeepAwakeDecision -IsDevBox $true -Requested $true -Sandbox $true
    -not $decision.Enabled -and $decision.Reason -match 'sandbox'
}
Test-That '-SkipTask skips this task too' {
    -not (Get-BridgeDevBoxKeepAwakeDecision -IsDevBox $true -Requested $true -SkipTask $true).Enabled
}
Test-That 'there is no keep-awake task off Windows' {
    -not (Get-BridgeDevBoxKeepAwakeDecision -IsDevBox $true -Requested $true -OnWindows $false).Enabled
}

Test-That 'a fresh install on a Dev Box is asked' {
    Test-BridgeDevBoxKeepAwakePrompt -IsDevBox $true -Interactive $true -SwitchProvided $false -ConfigExisted $false
}
Test-That 'an upgrade whose config just gained the devBox section is asked once' {
    Test-BridgeDevBoxKeepAwakePrompt -IsDevBox $true -Interactive $true -SwitchProvided $false `
        -ConfigExisted $true -FilledKeys @('devBox')
}
Test-That 'an upgrade that already answered is not asked again' {
    -not (Test-BridgeDevBoxKeepAwakePrompt -IsDevBox $true -Interactive $true -SwitchProvided $false `
        -ConfigExisted $true -FilledKeys @())
}
Test-That 'an explicit -DevBoxKeepAwake answers the question instead of asking it' {
    -not (Test-BridgeDevBoxKeepAwakePrompt -IsDevBox $true -Interactive $true -SwitchProvided $true `
        -ConfigExisted $false)
}
Test-That 'a non-interactive run is never asked' {
    -not (Test-BridgeDevBoxKeepAwakePrompt -IsDevBox $true -Interactive $false -SwitchProvided $false `
        -ConfigExisted $false)
}
Test-That 'an ordinary machine is never asked' {
    -not (Test-BridgeDevBoxKeepAwakePrompt -IsDevBox $false -Interactive $true -SwitchProvided $false `
        -ConfigExisted $false)
}

Write-Host ''
Write-Host '--- wiring ---'

Test-That 'the keep-awake entry point and its windowless launcher ship in hooks' {
    (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\hooks\agent-bridge-devbox-keepawake.ps1')) -and
    (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\hooks\agent-bridge-devbox-keepawake.vbs'))
}
Test-That 'the launcher starts the pass hidden, as the daemon launcher does' {
    (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\hooks\agent-bridge-devbox-keepawake.vbs') -Raw) -match 'agent-bridge-devbox-keepawake\.ps1""", 0, False'
}
Test-That 'the shipped config carries the setting so an upgrade can detect it is new' {
    $example = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\config.example.json') -Raw | ConvertFrom-Json
    $example.devBox.PSObject.Properties['keepAwake'] -and $example.devBox.keepAwake -eq $false
}
Test-That 'the uninstaller removes the keep-awake task' {
    (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\uninstall.ps1') -Raw) -match 'AgentBridgeDevBoxKeepAwake'
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
