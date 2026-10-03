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

Write-Host ''
Write-Host '--- a Stop action that is defined but not scheduled ---'

# The case that made the feature look like it worked while the machine kept
# hibernating. A pool's Stop action is listed permanently, but it carries 'next' only
# once an occurrence exists - which, for stop-on-disconnect, is only after the last
# session has gone. Reading it unconditionally threw under Set-StrictMode and took the
# whole pass down: on 2026-10-02/03 this Dev Box logged FAILED on 15 of 24 passes and
# hibernated three times regardless.

Test-That 'a Stop action with no occurrence at all reports no-action rather than failing' {
    # Built here rather than once above because GetNewClosure copies only the
    # scriptblock's own locals; a fixture held at script scope arrives as $null.
    $unscheduled = [pscustomobject]@{
        value = @([pscustomobject]@{ name = 'idle-stopondisconnect'; actionType = 'Stop'; sourceType = 'Pool' })
    }
    $result = Invoke-BridgeDevBoxKeepAwake -IdentityProvider $asIdentity -TokenProvider $noToken `
        -Invoke { param($m, $u, $h) $unscheduled }.GetNewClosure() -Now $fixedNow
    $result.Status -eq 'no-action'
}

Test-That 'and neither lever is reached for it' {
    $unscheduled = [pscustomobject]@{
        value = @([pscustomobject]@{ name = 'idle-stopondisconnect'; actionType = 'Stop'; sourceType = 'Pool' })
    }
    $calls = [System.Collections.ArrayList]::new()
    $invoke = {
        param($Method, $Uri, $Head)
        [void]$calls.Add("$Method $Uri")
        $unscheduled
    }.GetNewClosure()
    Invoke-BridgeDevBoxKeepAwake -IdentityProvider $asIdentity -TokenProvider $noToken `
        -Invoke $invoke -Now $fixedNow | Out-Null
    $calls.Count -eq 1 -and $calls[0].StartsWith('GET ')
}

Test-That 'an occurrence whose scheduled time is blank is treated the same way' {
    $blank = [pscustomobject]@{ value = @([pscustomobject]@{
        name = 'idle-stopondisconnect'; actionType = 'Stop'
        next = [pscustomobject]@{ scheduledTime = '' }
    }) }
    $result = Invoke-BridgeDevBoxKeepAwake -IdentityProvider $asIdentity -TokenProvider $noToken `
        -Invoke { param($m, $u, $h) $blank }.GetNewClosure() -Now $fixedNow
    $result.Status -eq 'no-action'
}

Test-That 'a time the service renders in some other shape drops that action instead of the pass' {
    $odd = [pscustomobject]@{ value = @([pscustomobject]@{
        name = 'idle-stopondisconnect'; actionType = 'Stop'
        next = [pscustomobject]@{ scheduledTime = 'whenever' }
    }) }
    $result = Invoke-BridgeDevBoxKeepAwake -IdentityProvider $asIdentity -TokenProvider $noToken `
        -Invoke { param($m, $u, $h) $odd }.GetNewClosure() -Now $fixedNow
    $result.Status -eq 'no-action'
}

Test-That 'an unscheduled action does not hide a scheduled one later in the list' {
    $mixed = [pscustomobject]@{ value = @(
        [pscustomobject]@{ name = 'idle-stopondisconnect'; actionType = 'Stop' },
        [pscustomobject]@{ name = 'scheduled-stop'; actionType = 'Stop'
            next = [pscustomobject]@{ scheduledTime = '2026-09-30T23:00:00Z' } }
    ) }
    $skipped = [System.Collections.ArrayList]::new()
    $invoke = {
        param($Method, $Uri, $Head)
        if ($Method -eq 'GET') { return $mixed }
        if ($Uri -match ':skip\?') { [void]$skipped.Add($Uri) }
        $null
    }.GetNewClosure()
    $result = Invoke-BridgeDevBoxKeepAwake -IdentityProvider $asIdentity -TokenProvider $noToken `
        -Invoke $invoke -Now $fixedNow
    $result.Status -eq 'skipped' -and $skipped.Count -eq 1 -and $skipped[0] -match '/scheduled-stop:skip'
}

Write-Host ''
Write-Host '--- how often a pass runs ---'

# 1.25.0 polled every 4 hours against a pool granting a 60-minute grace, so the
# occurrence was routinely created and fired between two passes. No value the old
# hours-based key could hold was short enough, which is why it is replaced rather
# than re-defaulted.
Test-That 'an unconfigured Dev Box polls every 15 minutes' {
    (Get-BridgeDevBoxIntervalMinutes -DevBox ([pscustomobject]@{ keepAwake = $true })) -eq 15
}

Test-That 'a configured interval is honoured' {
    (Get-BridgeDevBoxIntervalMinutes -DevBox ([pscustomobject]@{ intervalMinutes = 5 })) -eq 5
}

Test-That 'an interval that could outlast the shortest grace Dev Box offers is capped at 30' {
    (Get-BridgeDevBoxIntervalMinutes -DevBox ([pscustomobject]@{ intervalMinutes = 240 })) -eq 30
}

Test-That '1.25.0 configs written in hours are carried over and capped, not obeyed' {
    (Get-BridgeDevBoxIntervalMinutes -DevBox ([pscustomobject]@{ intervalHours = 4 })) -eq 30
}

Test-That 'the new key wins when an upgrade has left both behind' {
    (Get-BridgeDevBoxIntervalMinutes -DevBox ([pscustomobject]@{ intervalMinutes = 15; intervalHours = 4 })) -eq 15
}

Test-That 'a nonsense or missing interval falls back to the default instead of throwing' {
    (Get-BridgeDevBoxIntervalMinutes -DevBox ([pscustomobject]@{ intervalMinutes = 'soon' })) -eq 15 -and
    (Get-BridgeDevBoxIntervalMinutes -DevBox ([pscustomobject]@{ intervalMinutes = 0 })) -eq 15 -and
    (Get-BridgeDevBoxIntervalMinutes -DevBox $null) -eq 15
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
Test-That 'and states the cadence in minutes, which is the only unit that can be short enough' {
    $example = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\config.example.json') -Raw | ConvertFrom-Json
    $example.devBox.PSObject.Properties['intervalMinutes'] -and
    $example.devBox.intervalMinutes -eq 15 -and
    -not $example.devBox.PSObject.Properties['intervalHours']
}

# Building a trigger registers nothing - New-ScheduledTaskTrigger only returns a CIM
# object - so this is safe to run anywhere the module exists. It does not exist on the
# macOS CI leg, hence the skip rather than a guard inside the check.
if ($IsWindows -and (Get-Command New-ScheduledTaskTrigger -ErrorAction SilentlyContinue)) {
    # An explicit user: the runner clears USERNAME, and -AtLogOn refuses an empty one.
    $script:Triggers = @()
    Test-That 'the triggers build at all' {
        $script:Triggers = @(New-BridgeDevBoxKeepAwakeTrigger -IntervalMinutes 15 -User 'someone')
        $script:Triggers.Count -eq 2
    }

    $repeating = @($script:Triggers | Where-Object {
        $_.PSObject.Properties['Repetition'] -and $_.Repetition -and $_.Repetition.Interval
    })

    Test-That 'the task repeats on the interval it was given' {
        $repeating.Count -eq 1 -and $repeating[0].Repetition.Interval -eq 'PT15M'
    } "intervals: $(@($script:Triggers | ForEach-Object { if ($_.Repetition) { $_.Repetition.Interval } }) -join ',')"

    # P99999999DT23H59M59S - what [TimeSpan]::MaxValue serialises to - is rejected by
    # Task Scheduler, so 1.25.0 warned and registered nothing. An empty duration is
    # "forever" and is accepted.
    Test-That 'and repeats forever, which is an empty duration rather than MaxValue' {
        $repeating.Count -eq 1 -and [string]::IsNullOrEmpty($repeating[0].Repetition.Duration)
    } "duration: '$(if ($repeating.Count) { $repeating[0].Repetition.Duration })'"
}
else {
    Write-Host '  SKIP  the trigger shape: no ScheduledTasks module on this platform'
}

Write-Host '--- installation-owned task and detached-runtime wiring ---'
function Invoke-DevBoxOwnershipFixture {
    param($Owner, [hashtable]$Tasks, [hashtable]$Processes, [bool]$OnWindows, [switch]$Install, [switch]$Enable)
    $repository = Split-Path $PSScriptRoot -Parent
    $savedPlatform = $script:BridgeIsWindows
    $savedInstallNoRun = $env:BRIDGE_INSTALL_NORUN
    $savedUninstallNoRun = $env:BRIDGE_UNINSTALL_NORUN
    $env:BRIDGE_INSTALL_NORUN = '1'
    $env:BRIDGE_UNINSTALL_NORUN = '1'
    try {
        . (Join-Path $repository 'install.ps1') -InstallRoot $Owner.BridgeHome
        . (Join-Path $repository 'uninstall.ps1') -InstallRoot $Owner.BridgeHome
        $script:BridgeIsWindows = $OnWindows
        $script:OwnershipOperations = [Collections.Generic.List[string]]::new()
        function Get-ScheduledTask { param($TaskName, $ErrorAction) $Tasks[$TaskName] }
        function Stop-ScheduledTask { param($TaskName, $ErrorAction) $script:OwnershipOperations.Add("stop-task:$TaskName") }
        function Unregister-ScheduledTask {
            [CmdletBinding(SupportsShouldProcess)]
            param($TaskName)
            if ($PSCmdlet.ShouldProcess($TaskName, 'Remove fixture task')) {
                $script:OwnershipOperations.Add("remove-task:$TaskName")
                [void]$Tasks.Remove($TaskName)
            }
        }
        function New-ScheduledTaskAction { param($Execute, $Argument) [pscustomobject]@{ Execute = $Execute; Arguments = $Argument } }
        function New-ScheduledTaskTrigger { param([switch]$AtLogOn, $User, [switch]$Once, $At, $RepetitionInterval) [pscustomobject]@{ Interval = $RepetitionInterval } }
        function New-ScheduledTaskSettingsSet { param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, [switch]$StartWhenAvailable, $ExecutionTimeLimit, [switch]$Hidden) [pscustomobject]@{} }
        function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) [pscustomobject]@{} }
        function Register-ScheduledTask {
            param($TaskName, $Action, $Trigger, $Settings, $Principal, $Description)
            $script:OwnershipOperations.Add("register:$TaskName")
            $Tasks[$TaskName] = [pscustomobject]@{ Actions = @($Action) }
        }
        function Set-ScheduledTask {
            param($TaskName, $Action, $Trigger, $Settings, $Principal)
            $script:OwnershipOperations.Add("set:$TaskName")
            $Tasks[$TaskName] = [pscustomobject]@{ Actions = @($Action) }
        }
        function Start-ScheduledTask { param($TaskName) $script:OwnershipOperations.Add("start:$TaskName") }
        function Get-BridgeProcessesNamed { param($Name, [switch]$WithCommandLine) @($Processes.Values) }
        function Get-BridgeProcessInfo { param($ProcessId, [switch]$WithCommandLine) $Processes[[int]$ProcessId] }
        function Stop-Process {
            param($Id, [switch]$Force, $ErrorAction)
            $script:OwnershipOperations.Add("stop-process:$Id")
            [void]$Processes.Remove([int]$Id)
        }
        $failure = ''
        try {
            if ($Install) {
                $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'install.ps1'), [ref]$null, [ref]$null)
                $shutdown = $ast.Find({
                    param($node)
                    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Stop-BridgeOwnedService'
                }, $true)
                . ([scriptblock]::Create($shutdown.Extent.Text))
                Stop-BridgeOwnedRuntime -Context $installContext
                Set-Variable -Name devBoxDecision -Value (Get-BridgeDevBoxKeepAwakeDecision -IsDevBox $true -Requested ([bool]$Enable) `
                    -OnWindows $OnWindows -Sandbox $installContext.Isolated -SkipTask ([bool]$SkipTask))
                Set-Variable -Name devBoxIntervalMinutes -Value 15
                $registration = $ast.EndBlock.Statements | Where-Object {
                    $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -match 'devBoxDecision.Enabled'
                } | Select-Object -First 1
                if (-not $registration) { throw 'The actual keep-awake registration branch was not found.' }
                . ([scriptblock]::Create($registration.Extent.Text))
            }
            else {
                Set-Variable -Name ClearEntities -Value $false
                Set-Variable -Name AdapterPayloadRoot -Value $repository
                $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'uninstall.ps1'), [ref]$null, [ref]$null)
                $entry = $ast.Find({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-BridgeUninstall'
                }, $true)
                $prefix = @(foreach ($statement in $entry.Body.EndBlock.Statements) {
                    if ($statement.Extent.Text -match '^Remove-BridgeInstalledAdapters') { break }
                    $statement.Extent.Text
                })
                . ([scriptblock]::Create($prefix -join "`n"))
            }
        }
        catch { $failure = $_.Exception.Message }
        [pscustomobject]@{ Operations = @($script:OwnershipOperations); Error = $failure }
    }
    finally {
        $script:BridgeIsWindows = $savedPlatform
        $env:BRIDGE_INSTALL_NORUN = $savedInstallNoRun
        $env:BRIDGE_UNINSTALL_NORUN = $savedUninstallNoRun
    }
}

$normalOwner = Initialize-BridgeInstallIdentity -Context (Resolve-BridgeInstallContext)
if ($normalOwner.Isolated -or -not (Test-BridgeInstallDescendant $normalOwner.Home $env:AGENT_HA_BRIDGE_TEST_ROOT)) {
    throw 'The ordinary-root fixture must remain within canonical synthetic HOME.'
}
$otherOwner = Initialize-BridgeInstallIdentity -Context (
    Resolve-BridgeInstallContext -TargetHome (Join-Path $env:TEMP ('devbox-other-' + [guid]::NewGuid().ToString('N'))))
foreach ($owner in @($normalOwner, $otherOwner)) {
    Write-BridgeSecretFile -Path $owner.ConfigPath -Content '{"clients":[]}'
    [void][IO.Directory]::CreateDirectory($owner.HooksDir)
}
$normalTaskName = "AgentBridgeDevBoxKeepAwake_$($normalOwner.Id)"
$otherTaskName = "AgentBridgeDevBoxKeepAwake_$($otherOwner.Id)"
$legacyTaskName = 'AgentBridgeDevBoxKeepAwake'
$normalTask = [pscustomobject]@{ Actions = @([pscustomobject]@{
    Execute = 'wscript.exe'; Arguments = '"' + (Join-Path $normalOwner.HooksDir 'agent-bridge-devbox-keepawake.vbs') + '"'
}) }
$otherTask = [pscustomobject]@{ Actions = @([pscustomobject]@{
    Execute = 'wscript.exe'; Arguments = '"' + (Join-Path $otherOwner.HooksDir 'agent-bridge-devbox-keepawake.vbs') + '"'
}) }
Test-That 'recorded installations have distinct keep-awake task identities' {
    $normalOwner.PSObject.Properties['DevBoxTaskName'] -and
        $normalOwner.DevBoxTaskName -eq $normalTaskName -and $otherOwner.DevBoxTaskName -eq $otherTaskName
}
Test-That 'keep-awake task ownership requires its exact launcher and a single action' {
    $extraArgument = [pscustomobject]@{ Actions = @([pscustomobject]@{
        Execute = 'wscript.exe'; Arguments = $normalTask.Actions[0].Arguments + ' unrelated'
    }) }
    $extraAction = [pscustomobject]@{ Actions = @($normalTask.Actions[0], $otherTask.Actions[0]) }
    (Test-BridgeTaskOwnership -Task $normalTask -Context $normalOwner -Role devbox-keepawake) -and
        -not (Test-BridgeTaskOwnership -Task $otherTask -Context $normalOwner -Role devbox-keepawake) -and
        -not (Test-BridgeTaskOwnership -Task $extraArgument -Context $normalOwner -Role devbox-keepawake) -and
        -not (Test-BridgeTaskOwnership -Task $extraAction -Context $normalOwner -Role devbox-keepawake)
}
foreach ($operation in @('install', 'uninstall')) {
    $tasks = @{ $legacyTaskName = $normalTask }
    $outcome = Invoke-DevBoxOwnershipFixture -Owner $otherOwner -Tasks $tasks -Processes @{} -OnWindows $true -Install:($operation -eq 'install')
    Test-That "isolated $operation leaves an unrelated legacy fixed task unchanged" {
        -not $outcome.Error -and $outcome.Operations.Count -eq 0 -and $tasks.ContainsKey($legacyTaskName)
    } $outcome.Error
    $tasks = @{ $legacyTaskName = $normalTask }
    $outcome = Invoke-DevBoxOwnershipFixture -Owner $normalOwner -Tasks $tasks -Processes @{} -OnWindows $false -Install:($operation -eq 'install')
    Test-That "non-Windows $operation never calls Task Scheduler" { -not $outcome.Error -and $outcome.Operations.Count -eq 0 } $outcome.Error
}
$tasks = @{ $legacyTaskName = $otherTask }
$outcome = Invoke-DevBoxOwnershipFixture -Owner $normalOwner -Tasks $tasks -Processes @{} -OnWindows $true
Test-That 'a legacy name alone cannot authorize removal of another installations task' {
    -not $outcome.Error -and $outcome.Operations.Count -eq 0 -and $tasks.ContainsKey($legacyTaskName)
} $outcome.Error

$pwshPath = (Get-Process -Id $PID).Path
$started = [datetime]'2026-01-01T00:00:00Z'
foreach ($operation in @('install', 'uninstall')) {
    $tasks = @{ $legacyTaskName = $normalTask; $otherTaskName = $otherTask }
    $processes = @{}
    foreach ($row in @(@{ Id = 930001; Owner = $normalOwner }, @{ Id = 930002; Owner = $otherOwner })) {
        $processes[$row.Id] = [pscustomobject]@{
            ProcessId = $row.Id; Path = $pwshPath; CreationDate = $started
            CommandLine = '"' + $pwshPath + '" -NoProfile -File "' + (Join-Path $row.Owner.HooksDir 'agent-bridge-devbox-keepawake.ps1') + '"'
        }
        @{ pid = $row.Id; installationId = $row.Owner.Id; executable = $pwshPath; startedUtcTicks = $started.ToUniversalTime().Ticks } |
            ConvertTo-Json | Set-Content -LiteralPath (Get-BridgeRuntimePath -Name 'devbox-keepawake.process.json' -Context $row.Owner) -Encoding utf8
    }
    $outcome = Invoke-DevBoxOwnershipFixture -Owner $normalOwner -Tasks $tasks -Processes $processes -OnWindows $true `
        -Install:($operation -eq 'install') -Enable
    Test-That "$operation retires the verified legacy task and stops only its detached writer before payload work" {
        -not $outcome.Error -and -not $tasks.ContainsKey($legacyTaskName) -and
            -not $processes.ContainsKey(930001) -and $processes.ContainsKey(930002) -and $tasks.ContainsKey($otherTaskName)
    } $outcome.Error
    if ($operation -eq 'install') {
        Test-That 'the selected feature is registered and started under its recorded installation identity' {
            $tasks.ContainsKey($normalTaskName) -and $outcome.Operations -contains "start:$normalTaskName"
        }
    }
}
$tasks = @{ $normalTaskName = $otherTask }
$outcome = Invoke-DevBoxOwnershipFixture -Owner $normalOwner -Tasks $tasks -Processes @{} -OnWindows $true -Install -Enable
Test-That 'an installation-named task pointing elsewhere is refused without replacement' {
    $outcome.Error -match 'elsewhere|another|ownership' -and $outcome.Operations.Count -eq 0 -and
        $tasks[$normalTaskName].Actions[0].Arguments -eq $otherTask.Actions[0].Arguments
}

Write-Host '--- the actual detached entry owns its receipt and log ---'
$ambientLog = Join-Path $env:TEMP 'agent-bridge-devbox-keepawake.log'
[IO.File]::WriteAllText($ambientLog, 'unrelated ambient log')
foreach ($owner in @($normalOwner, $otherOwner)) {
    foreach ($name in @('agent-bridge-devbox-keepawake.ps1', 'bridge-platform.ps1', 'bridge-install-context.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "..\hooks\$name") -Destination $owner.HooksDir -Force
    }
    $observation = Join-Path $owner.BridgeHome 'entry-observation.json'
    $scenarioPath = Join-Path $owner.BridgeHome 'entry-scenario.txt'
    $receipt = Get-BridgeRuntimePath -Name 'devbox-keepawake.process.json' -Context $owner
    if (Test-Path -LiteralPath $receipt) { Remove-Item -LiteralPath $receipt -Force }
    $cloudBoundary = @'
function Invoke-BridgeDevBoxKeepAwake {
    param([scriptblock]$Logger, [switch]$DryRun)
    $receipt = if ([IO.File]::Exists('__RECEIPT__')) { Get-Content -LiteralPath '__RECEIPT__' -Raw | ConvertFrom-Json } else { $null }
    $calls = if ([IO.File]::Exists('__OBSERVATION__')) { (Get-Content -LiteralPath '__OBSERVATION__' -Raw | ConvertFrom-Json).calls + 1 } else { 1 }
    @{ pid = $PID; dryRun = [bool]$DryRun; receipt = $receipt; calls = $calls } | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath '__OBSERVATION__' -Encoding utf8
    & $Logger 'synthetic one-pass operation'
    $scenario = [IO.File]::ReadAllText('__SCENARIO__')
    if ($scenario -eq 'error') { throw 'synthetic cloud failure' }
    [pscustomobject]@{ Status = $scenario; Detail = 'synthetic result' }
}
'@
    $cloudBoundary.Replace('__RECEIPT__', $receipt.Replace("'", "''")).Replace('__OBSERVATION__', $observation.Replace("'", "''")).Replace('__SCENARIO__', $scenarioPath.Replace("'", "''")) |
        Set-Content -LiteralPath (Join-Path $owner.HooksDir 'bridge-devbox.ps1') -Encoding utf8
    foreach ($scenario in @('dry-run', 'blocked', 'error', 'unreadable', 'contended')) {
        if (Test-Path -LiteralPath $observation) { Remove-Item -LiteralPath $observation -Force }
        [IO.File]::WriteAllText($scenarioPath, $scenario)
        if ($scenario -eq 'unreadable') { [IO.File]::WriteAllText($receipt, '{unreadable') }
        $heldMutex = $null
        if ($scenario -eq 'contended') {
            $heldMutex = [Threading.Mutex]::new($false, ('Local\' + $owner.DevBoxTaskName))
            if (-not $heldMutex.WaitOne([TimeSpan]::Zero)) { throw 'The synthetic owner could not hold its unique mutex.' }
        }
        $start = [Diagnostics.ProcessStartInfo]::new($pwshPath)
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.Environment['AGENT_HA_BRIDGE_CONFIG'] = $otherOwner.ConfigPath
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File',
            (Join-Path $owner.HooksDir 'agent-bridge-devbox-keepawake.ps1'))) { $start.ArgumentList.Add($argument) }
        if ($scenario -eq 'dry-run') { $start.ArgumentList.Add('-DryRun') }
        $child = $null
        try {
            $child = [Diagnostics.Process]::Start($start)
            $stdout = $child.StandardOutput.ReadToEndAsync()
            $stderr = $child.StandardError.ReadToEndAsync()
            if (-not $child.WaitForExit(30000)) { $child.Kill($true); throw 'Synthetic keep-awake entry timed out.' }
            $observed = if (Test-Path -LiteralPath $observation) { Get-Content -LiteralPath $observation -Raw | ConvertFrom-Json } else { $null }
            $entryOutput = $stdout.Result + $stderr.Result
            if ($scenario -in @('unreadable', 'contended')) {
                Test-That "the actual $scenario entry fails before any cloud operation or receipt overwrite" {
                    $child.ExitCode -eq 1 -and $null -eq $observed -and
                        $(if ($scenario -eq 'unreadable') { [IO.File]::ReadAllText($receipt) -ceq '{unreadable' }
                            else { -not (Test-Path -LiteralPath $receipt) })
                } $entryOutput
            }
            else {
                $expectedExit = switch ($scenario) { 'blocked' { 2 }; 'error' { 1 }; default { 0 } }
                $expectedOutput = if ($scenario -eq 'error') { 'FAILED: synthetic cloud failure' } else { "${scenario}: synthetic result" }
                Test-That "the actual $scenario entry preserves one-pass, receipt, DryRun, output and exit semantics" {
                    $child.ExitCode -eq $expectedExit -and $observed.calls -eq 1 -and
                        $observed.dryRun -eq ($scenario -eq 'dry-run') -and $observed.receipt -and
                        $observed.receipt.pid -eq $observed.pid -and $observed.receipt.installationId -eq $owner.Id -and
                        $entryOutput.Contains($expectedOutput)
                } "exit=$($child.ExitCode); $entryOutput"
                Test-That 'the completed detached pass clears only its own process receipt' { -not (Test-Path -LiteralPath $receipt) } $entryOutput
            }
            Test-That 'the actual entry log belongs to its installation rather than the ambient temporary directory' {
                [IO.File]::Exists((Get-BridgeRuntimePath -Name 'agent-bridge-devbox-keepawake.log' -Context $owner)) -and
                    [IO.File]::ReadAllText($ambientLog) -ceq 'unrelated ambient log'
            }
        }
        finally {
            if ($child) { $child.Dispose() }
            if ($heldMutex) { $heldMutex.ReleaseMutex(); $heldMutex.Dispose() }
            if ($scenario -eq 'unreadable' -and (Test-Path -LiteralPath $receipt)) { Remove-Item -LiteralPath $receipt -Force }
        }
    }
}

Write-Host '--- changed or unreadable runtime receipts are preserved ---'
$receiptPath = Get-BridgeRuntimePath -Name 'devbox-keepawake.process.json' -Context $normalOwner
Register-BridgeRuntimeProcess -Context $normalOwner -Role devbox-keepawake
$ownedReceipt = [IO.File]::ReadAllText($receiptPath)
try {
    $changed = $ownedReceipt | ConvertFrom-Json
    $changed.installationId = $otherOwner.Id
    $replacement = $changed | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($receiptPath, $replacement)
    Test-That 'receipt completion cannot delete a replacement owned by another installation' {
        $refused = $false
        try { Unregister-BridgeRuntimeProcess -Context $normalOwner -Role devbox-keepawake }
        catch { $refused = $_.Exception.Message -match 'ownership changed' }
        $refused -and [IO.File]::ReadAllText($receiptPath) -ceq $replacement
    }
    [IO.File]::WriteAllText($receiptPath, '{unreadable')
    Test-That 'an unreadable receipt is an explicit failure rather than cleanup permission' {
        $refused = $false
        try { Unregister-BridgeRuntimeProcess -Context $normalOwner -Role devbox-keepawake }
        catch { $refused = $_.Exception.Message -match 'unreadable' }
        $refused -and [IO.File]::ReadAllText($receiptPath) -ceq '{unreadable'
    }
    [IO.File]::WriteAllText($receiptPath, $ownedReceipt)
    Unregister-BridgeRuntimeProcess -Context $normalOwner -Role devbox-keepawake
    Test-That 'the matching live process can remove its own receipt normally' { -not (Test-Path -LiteralPath $receiptPath) }
}
finally {
    if (Test-Path -LiteralPath $receiptPath) { Remove-Item -LiteralPath $receiptPath -Force }
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
