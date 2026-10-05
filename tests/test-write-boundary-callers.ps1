#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $env:AGENT_HA_BRIDGE_TEST_ROOT) { throw 'Run this suite through tests\run-tests.ps1.' }
. (Join-Path $PSScriptRoot 'runner-support.ps1')
Assert-BridgeTestEnvironment -Required
. (Join-Path $PSScriptRoot 'write-boundary-fixtures.ps1')

$script:Failures = 0
$fixture = New-BoundaryFixture -Suite 'test-write-boundary-callers.ps1'
try {
    $scratch = $fixture.Scratch
    $protectedHooks = $fixture.ProtectedHooks
    $null = Invoke-BoundaryFixture -Fixture $fixture -Name 'the two ambient hook writes' -Refused -Body @'
New-BridgeTestAmbientInstall -HomeDirectory $protectedHome
'@
    $null = Invoke-BoundaryFixture -Fixture $fixture -Name 'the real adapter pointer writer' -Refused -Body @'
Set-BridgeAdapterRoot -Directory $protectedHooks -Context $context
'@
    $null = Invoke-BoundaryFixture -Fixture $fixture -Name 'the allowed ambient writer and selected installation roots' -Body @'
$hooks = New-BridgeTestAmbientInstall -HomeDirectory $env:HOME
if ([IO.File]::ReadAllText((Join-Path $hooks 'decision-bridge-common.ps1')).Trim() -cne '# inert ambient dependency') {
    throw 'The actual common fixture bytes were not written.'
}
if ([IO.File]::ReadAllText((Join-Path $hooks 'bridge-update.ps1')) -notmatch 'other-install') {
    throw 'The actual competing updater bytes were not written.'
}
$selected = @(foreach ($name in 'home A', 'home B') {
    $owner = Resolve-BridgeInstallContext -TargetHome (Join-Path $env:TEMP $name)
    Set-BridgeAdapterRoot -Directory (Join-Path $owner.ClaudeHome 'ha-bridge') -Context $owner
    $pointer = Read-BridgeInstallRecord -Path (Join-Path $owner.ClaudeHome 'ha-bridge\bridge-root.json')
    if ($pointer['bridgeHome'] -ne $owner.BridgeHome -or $owner.Home -eq $env:HOME) { throw 'Ambient home won selection.' }
    $owner.BridgeHome
})
if ($selected[0] -eq $selected[1]) { throw 'The two selected installations collided.' }
'@
    foreach ($caller in @(
        'Set-BridgeHomeAssistantReachable', 'Set-BridgeDaemonAlive',
        'Test-HomeAssistantReachable', 'Get-BridgeDaemonPid', 'Test-BridgeDaemonAlive',
        "Get-CopilotDecisionMarkerPath -SessionId 'synthetic-no-session'"
    )) {
        $null = Invoke-BoundaryFixture -Fixture $fixture -Name "the actual $caller caller" -Refused -Body (
            '$script:BridgeInstallContext = $context; $context.RuntimeRoot = $protectedBridge' + "`n" + $caller)
    }
    $null = Invoke-BoundaryFixture -Fixture $fixture -Name 'the enclosing reachability probe catch' -Refused -Body @'
function Invoke-RestMethod {
    $script:BridgeInstallContext.ConfigPath = Join-Path $protectedBridge 'config.json'
    @{}
}
Test-HomeAssistantReachable
'@
    $null = Invoke-BoundaryFixture -Fixture $fixture -Name 'ordinary unmarked liveness failures' -Body @'
$root = Get-BridgeRuntimeRoot
[void][IO.Directory]::CreateDirectory($root)
$reachable = Get-BridgeReachableMarker
[void][IO.Directory]::CreateDirectory($reachable)
Set-BridgeHomeAssistantReachable
[IO.Directory]::Delete($reachable)
$heartbeat = Get-BridgeDaemonHeartbeat
[void][IO.Directory]::CreateDirectory($heartbeat)
Set-BridgeDaemonAlive
if ((Get-BridgeDaemonPid) -ne 0) { throw 'Ordinary unreadable heartbeat no longer returns zero.' }
[IO.Directory]::SetLastWriteTimeUtc($heartbeat, [DateTime]::UtcNow.AddDays(-1))
if (Test-BridgeDaemonAlive) { throw 'Ordinary stale heartbeat no longer returns false.' }
function Invoke-RestMethod { throw [IO.IOException]::new('synthetic ordinary transport failure') }
if (Test-HomeAssistantReachable) { throw 'Ordinary transport failure no longer returns false.' }
$original = $context.BridgeHome
Remove-Item Env:\AGENT_HA_BRIDGE_TEST_ROOT, Env:\AGENT_HA_BRIDGE_TEST_ID, Env:\AGENT_HA_BRIDGE_OFFLINE_TEST
if (Test-BridgeTestExecution) { throw 'A non-test entry was classified as a test by its parent directory.' }
if ((Resolve-BridgeInstallContext).BridgeHome -ne $original) { throw 'Non-test root selection changed.' }
'@
    $updateSetup = @'
. (Join-Path $repository 'hooks\bridge-update.ps1')
function Get-BridgeUpdateStatus {
    [pscustomobject]@{
        Installed = '1.0.0'; Latest = '9.9.9'; Available = $true
        Url = 'https://github.com/x/y/releases/tag/v9.9.9'
        Zip = 'https://api.github.com/repos/x/y/zipball/v9.9.9'
    }
}
$script:StagedLaunch = $null
function Start-Process {
    param($FilePath, $ArgumentList, $WindowStyle)
    $script:StagedLaunch = @($ArgumentList)
}
'@
    $staged = Invoke-BoundaryFixture -Fixture $fixture -Name 'actual updater staging and embedded references' -Body ($updateSetup + @'

$result = Invoke-BridgeSelfUpdate -Detached
if (-not $result.Started -or -not $script:StagedLaunch) { throw 'The real staging path was not exercised.' }
$runner = ([string]$script:StagedLaunch[-1]).Trim('"')
Assert-BridgeTestPath -Path $runner
$text = [IO.File]::ReadAllText($runner)
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'The actual staged script does not parse.' }
$references = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
        [IO.Path]::IsPathFullyQualified($node.Value)
}, $true) | ForEach-Object { $_.Value })
if ($references.Count -lt 6) { throw 'The staged path inventory is incomplete.' }
Assert-BridgeTestPath -Path $references
foreach ($required in @(
    $context.ConfigPath, $context.BridgeHome, (Split-Path $runner -Parent),
    (Get-BridgeRuntimePath 'agent-bridge-update.log'), (Get-BridgeRuntimePath 'agent-bridge-update-outcome.json')
)) {
    if ($required -notin $references) { throw 'The staged script lost a required confined reference.' }
}
if (Test-Path -LiteralPath (Get-BridgeRuntimePath 'agent-bridge-update-outcome.json')) {
    throw 'The fixture executed an updater instead of only staging it.'
}
Write-Output ('STAGED-REFERENCES ' + ($references | ConvertTo-Json -Compress))
'@)
    Write-Host $staged.Output
    foreach ($field in 'ConfigPath', 'RuntimeRoot') {
        foreach ($mode in 'ScriptOnly', 'Detached') {
            $body = $updateSetup + "`n" + '$script:BridgeInstallContext = $context' + "`n" +
                ('$context.__FIELD__ = Join-Path $protectedBridge "outside"' -replace '__FIELD__', $field) +
                "`nInvoke-BridgeSelfUpdate -$mode"
            $null = Invoke-BoundaryFixture -Fixture $fixture -Name "updater $mode with escaped $field" -Refused -Body $body
        }
    }
    foreach ($client in 'claude', 'codex') {
        $body = @'
$env:AGENT_HA_BRIDGE_CONFIG = Join-Path $protectedBridge 'config.json'
. (Join-Path $repository '__CLIENT__\hooks\__CLIENT__-session.ps1')
Get-__CLIENT__StateRoot
'@
        $null = Invoke-BoundaryFixture -Fixture $fixture -Name "$client runtime initialization" -Refused -Body $body.Replace('__CLIENT__', $client)
    }
    foreach ($entry in @(
        'claude\hooks\notify-claude-stop.ps1', 'claude\hooks\route-askuserquestion.ps1',
        'claude\hooks\route-notification.ps1', 'codex\hooks\codex-bridge-hook.ps1'
    )) {
        $body = '$env:AGENT_HA_BRIDGE_CONFIG = Join-Path $protectedBridge "config.json"' + "`n" +
            "& (Join-Path `$repository '$entry')"
        $null = Invoke-BoundaryFixture -Fixture $fixture -Name "$entry marked entry failure" -Refused -Body $body
        $null = Invoke-BoundaryFixture -Fixture $fixture -Name "$entry ordinary missing fixture core" -Body "& (Join-Path `$repository '$entry')"
    }
    $reconcileSetup = @'
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'hooks\agent-bridge-daemon.ps1'), [ref]$null, [ref]$null)
$function = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DaemonReconcile'
}, $true)
if (-not $function) { throw 'The actual reconcile function was not found.' }
. ([scriptblock]::Create($function.Extent.Text))
foreach ($name in @(
    'Set-DaemonReconcileSnapshot', 'Sync-DaemonSessions', 'Repair-CopilotSessionEntities',
    'Invoke-DaemonFastActivity', 'Invoke-PendingDecisions', 'Invoke-PendingReplies',
    'Invoke-PendingCodexApprovals', 'Invoke-PendingStops', 'Sync-DaemonUpdateStatus',
    'Sync-DaemonNewSession', 'Sync-DaemonClients', 'Clear-DaemonStaleNote'
)) {
    Set-Item -LiteralPath "function:$name" -Value { param($Headers, $State, $Live) }
}
function Get-LiveBridgeSessions {
    $live = @{}
    [pscustomobject]@{ Complete = $true; Live = $live; PositiveLive = $live; OwnerCatalogue = @{}; UncertainIds = @{} }
}
$script:DaemonSessionCleanupPending = @{}
$platformAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'hooks\bridge-platform.ps1'), [ref]$null, [ref]$null)
$guardFunction = $platformAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-BridgeObservationGuardFailure'
}, $true)
if (-not $guardFunction) { throw 'The actual observation guard function was not found.' }
. ([scriptblock]::Create($guardFunction.Extent.Text))
$script:SnapshotCleared = $false
$script:OrdinaryReconcileLogged = $false
function Clear-DaemonReconcileSnapshot { $script:SnapshotCleared = $true }
function Write-DaemonLog { param($Message) $script:OrdinaryReconcileLogged = $true }
'@
    $null = Invoke-BoundaryFixture -Fixture $fixture -Name 'the actual reconcile catch and snapshot finally' -Refused -Body ($reconcileSetup + @'

function Write-DaemonState { param($State) $script:BridgeInstallContext.ConfigPath = Join-Path $protectedBridge 'config.json' }
try { Invoke-DaemonReconcile -Headers @{} -State @{} }
finally {
    if (-not $script:SnapshotCleared -or $script:OrdinaryReconcileLogged) {
        throw 'A marked reconcile failure lost the snapshot-finally or became an ordinary log-only result.'
    }
    Write-Output 'RECONCILE-SNAPSHOT-CLEARED'
}
'@)
    $null = Invoke-BoundaryFixture -Fixture $fixture -Name 'ordinary reconcile logging and snapshot cleanup' -Body ($reconcileSetup + @'

function Write-DaemonState { param($State) throw [IO.IOException]::new('synthetic ordinary state failure') }
Invoke-DaemonReconcile -Headers @{} -State @{}
if (-not $script:SnapshotCleared -or -not $script:OrdinaryReconcileLogged) { throw 'Ordinary reconcile behavior changed.' }
'@)
    $cleanupSetup = @'
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'uninstall.ps1'), [ref]$null, [ref]$null)
$function = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-BridgeUninstall'
}, $true)
$cleanup = $function.Body.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.IfStatementAst] -and
        $_.Clauses[0].Item1.Extent.Text -eq '$ClearEntities -and $installContext.Isolated'
} | Select-Object -First 1
if (-not $cleanup) { throw 'The actual entity-cleanup branch was not found.' }
$installContext = Get-BridgeInstallContext
$ClearEntities = $true
function Write-Step { param($Message) }
'@
    $null = Invoke-BoundaryFixture -Fixture $fixture -Name 'the actual uninstall entity-cleanup catch' -Refused -Body ($cleanupSetup + @'

$hooksDir = Join-Path $repository 'hooks'
$installContext.RuntimeRoot = $protectedBridge
. ([scriptblock]::Create($cleanup.Extent.Text))
'@)
    $null = Invoke-BoundaryFixture -Fixture $fixture -Name 'ordinary uninstall cleanup warnings' -Body ($cleanupSetup + @'

$hooksDir = Join-Path $env:TEMP 'missing-core'
$warnings = @()
. ([scriptblock]::Create($cleanup.Extent.Text)) 3>&1 | ForEach-Object {
    if ($_ -is [Management.Automation.WarningRecord]) { $warnings += $_.Message }
}
if ($warnings.Count -ne 1 -or $warnings[0] -notmatch 'Could not clear entities') {
    throw 'Ordinary cleanup failure no longer warns and returns.'
}
'@)
    foreach ($linkCase in 'directory', 'ancestor', 'root') {
        $body = @'
$linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
$link = Join-Path $env:TEMP ('sandbox-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType $linkType -Path $link -Value $protectedHome)
switch ('__CASE__') {
    'root' {
        $env:AGENT_HA_BRIDGE_TEST_ROOT = $link
        $env:AGENT_HA_BRIDGE_TEST_ID = (Split-Path $link -Leaf).Substring(8)
        Set-BridgeAdapterRoot -Directory $protectedHooks -Context $context
    }
    'ancestor' { Set-BridgeAdapterRoot -Directory (Join-Path $link 'child\adapter') -Context $context }
    'directory' { Set-BridgeAdapterRoot -Directory $link -Context $context }
}
'@
        $null = Invoke-BoundaryFixture -Fixture $fixture -Name "a linked $linkCase" -Refused -Body $body.Replace('__CASE__', $linkCase)
    }
    $fileLinkSupported = $true
    $capabilityLink = Join-Path $scratch 'file-link-capability'
    $capabilityClock = [Diagnostics.Stopwatch]::StartNew()
    Write-BoundaryRecord -Prefix 'S1-FIXTURE-TIMING' -Record ([ordered]@{
        Suite = $fixture.Suite; Operation = 'file-link-capability'; Phase = 'setup'; Event = 'phase-start'
    })
    try {
        [void](New-Item -ItemType SymbolicLink -Path $capabilityLink -Value (Join-Path $protectedHooks 'decision-bridge-common.ps1') -ErrorAction Stop)
    }
    catch {
        if (-not $IsWindows -or $_.CategoryInfo.Category -ne [Management.Automation.ErrorCategory]::PermissionDenied) { throw }
        $fileLinkSupported = $false
        Write-Host 'SKIP final-file and dangling symlink cases: this Windows identity cannot create symbolic links.'
    }
    finally {
        Write-BoundaryRecord -Prefix 'S1-FIXTURE-TIMING' -Record ([ordered]@{
            Suite = $fixture.Suite; Operation = 'file-link-capability'; Phase = 'setup'; Event = 'phase-end'
            Seconds = [Math]::Round($capabilityClock.Elapsed.TotalSeconds, 6)
        })
        $capabilityClock.Restart()
        Write-BoundaryRecord -Prefix 'S1-FIXTURE-TIMING' -Record ([ordered]@{
            Suite = $fixture.Suite; Operation = 'file-link-capability'; Phase = 'cleanup'; Event = 'phase-start'
        })
        try {
            if (Test-Path -LiteralPath $capabilityLink) { Remove-Item -LiteralPath $capabilityLink -Force }
        }
        finally {
            $capabilityClock.Stop()
            Write-BoundaryRecord -Prefix 'S1-FIXTURE-TIMING' -Record ([ordered]@{
                Suite = $fixture.Suite; Operation = 'file-link-capability'; Phase = 'cleanup'; Event = 'phase-end'
                Seconds = [Math]::Round($capabilityClock.Elapsed.TotalSeconds, 6)
            })
        }
    }
    if ($fileLinkSupported) {
        foreach ($linkCase in 'file', 'dangling') {
            $body = @'
$hooks = Join-Path $env:HOME '.agent-ha-bridge\hooks'
[void][IO.Directory]::CreateDirectory($hooks)
$target = if ('__CASE__' -eq 'dangling') { Join-Path $protectedHome 'missing-target' }
    else { Join-Path $protectedHooks 'decision-bridge-common.ps1' }
[void](New-Item -ItemType SymbolicLink -Path (Join-Path $hooks 'decision-bridge-common.ps1') -Value $target)
New-BridgeTestAmbientInstall -HomeDirectory $env:HOME
'@
            $null = Invoke-BoundaryFixture -Fixture $fixture -Name "a final $linkCase link at the actual hook write" -Refused -Body $body.Replace('__CASE__', $linkCase)
        }
    }
    $nested = Invoke-BoundaryFixture -Fixture $fixture -Name 'two levels of inherited synthetic home and credential isolation' -Body @'
$leaf = Join-Path $env:TEMP 'descendant.ps1'
@"
@{
    Home = `$HOME; EnvironmentHome = `$env:HOME; UserProfile = `$env:USERPROFILE
    Temp = [IO.Path]::GetTempPath(); Config = `$env:AGENT_HA_BRIDGE_CONFIG
    Leaked = [bool](`$env:AGENT_HA_AGENT_TOKEN -or `$env:CUSTOM_HOUSE_CREDENTIAL)
} | ConvertTo-Json -Compress
"@ | Set-Content -LiteralPath $leaf
$middle = Join-Path $env:TEMP 'middle.ps1'
@"
`$child = & pwsh -NoProfile -NonInteractive -File '__LEAF__'
if (`$LASTEXITCODE) { throw 'Grandchild failed.' }
@{ Home = `$HOME; EnvironmentHome = `$env:HOME; UserProfile = `$env:USERPROFILE; Child = (`$child | ConvertFrom-Json) } |
    ConvertTo-Json -Depth 4 -Compress
"@.Replace('__LEAF__', $leaf.Replace("'", "''")) | Set-Content -LiteralPath $middle
$observed = & pwsh -NoProfile -NonInteractive -File $middle
if ($LASTEXITCODE) { throw 'Descendant failed.' }
$record = $observed | ConvertFrom-Json
foreach ($level in @($record, $record.Child)) {
    if ($level.Home -ne $env:HOME -or $level.EnvironmentHome -ne $env:HOME -or $level.UserProfile -ne $env:HOME) {
        throw 'A nested PowerShell did not retain its synthetic HOME/USERPROFILE.'
    }
}
Assert-BridgeTestPath -Path @($record.Child.Temp, $record.Child.Config)
if ($record.Child.Leaked) { throw 'A descendant inherited owner credentials.' }
Write-Output ('DESCENDANT-ROOTS ' + $observed)
'@
    Write-Host $nested.Output
}
finally {
    try { Complete-BoundaryFixture -Fixture $fixture }
    finally { Remove-BoundaryFixture -Fixture $fixture }
}
if ($script:Failures) { throw "$script:Failures write-boundary check(s) failed." }
Write-Host 'All write-boundary checks passed'
exit 0
