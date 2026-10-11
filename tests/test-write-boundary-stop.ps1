#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $env:AGENT_HA_BRIDGE_TEST_ROOT) { throw 'Run this suite through tests\run-tests.ps1.' }
. (Join-Path $PSScriptRoot 'runner-support.ps1')
Assert-BridgeTestEnvironment -Required
. (Join-Path $PSScriptRoot 'write-boundary-fixtures.ps1')

$script:Failures = 0
$storeSetup = @'
. (Join-Path $repository 'hooks\decision-mqtt.ps1')
. (Join-Path $repository 'hooks\bridge-adapter.ps1')
$script:BridgeInstallContext = $context
$expires = [DateTimeOffset]::Now.AddMinutes(5)
$script:StopStatuses = @()
$script:StopActivities = @()
function Set-CopilotMqttStatus {
    param($SessionId, $Status, $Headers, $Attributes)
    $script:StopStatuses += $Status
}
function Set-CopilotMqttActivity {
    param($SessionId, $Summary, $Detail, $Headers)
    $script:StopActivities += $Summary
}
'@
$daemonSetup = $storeSetup + @'

# Load the real functions without running daemon startup or unrelated adapters.
foreach ($source in @(
    @{ Path = 'hooks\agent-bridge-daemon.ps1'; Names = @('Write-DaemonLog', 'Wait-DaemonChange', 'Invoke-DaemonHit') }
    @{ Path = 'hooks\daemon-launch.ps1'; Names = @(
        'Get-DaemonProcessIdentity', 'Set-DaemonStopArm', 'Remove-DaemonStopArm', 'Clear-DaemonStopPrompts'
        'Test-DaemonStopConfirms', 'Test-DaemonStopArmed', 'Get-DaemonStopConfirmHint'
        'Clear-DaemonExpiredStopArms', 'Invoke-PendingStops', 'Update-DaemonPendingLaunch'
    ) }
    @{ Path = 'hooks\daemon-activity.ps1'; Names = @('ConvertTo-DaemonActivityInstant', 'Invoke-DaemonFastActivity') }
    @{ Path = 'hooks\daemon-discovery.ps1'; Names = @('Get-DaemonEntityState') }
)) {
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repository $source.Path), [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'The actual daemon source does not parse.' }
    foreach ($name in $source.Names) {
        $definitions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
        }, $true))
        if ($definitions.Count -ne 1) { throw "The actual $name function is not unique." }
        . ([scriptblock]::Create($definitions[0].Extent.Text))
    }
}
$stopSession = 'aaaaaaaa-1111-2222-3333-444444444444'
$stopState = @{ $stopSession = [pscustomobject]@{ Status = 'working' } }
$stopEntity = 'button.' + (Get-CopilotMqttNodeId -SessionId $stopSession) + '_stop'
$script:DaemonConfig = @{
    StopConfirmSeconds = 10; StopLapseRetrySeconds = 2
    LogFile = (Join-Path $env:TEMP 'stop-boundary.log')
}
Assert-BridgeTestPath -Path $script:DaemonConfig.LogFile
$script:DaemonStopArmed = @{
    $stopSession = [pscustomobject]@{
        At = [DateTimeOffset]::Now.AddMinutes(-1); RetryAt = [DateTimeOffset]::MinValue
        Status = 'working'; ProcessId = 0; Identity = $null
    }
}
$script:DaemonPendingLaunch = $null
$script:DaemonHookSpoolEvents = @()
$script:DaemonHookSpoolAttempts = @{}
$script:DaemonHookSpoolSweptAt = [DateTime]::UtcNow
$script:DaemonHookSpoolSweepSeconds = 300
$script:DaemonLive = @{}
$script:DaemonReconcileNow = $false
$script:DaemonReconcileStates = @{
    $stopEntity = [pscustomobject]@{ state = [DateTimeOffset]::Now.ToString('o') }
}
$script:DaemonStartedAt = [DateTimeOffset]::MinValue
$script:DaemonWatchFailures = 0
$script:DaemonEntity = @{ NewSession = 'button.synthetic_no_launch' }
$ReconcileSeconds = 15
$script:StopPublications = @()
$script:StopPublicationFails = $false
$script:StopCalls = @()
$script:StopWaits = 0
$script:StopWaitFails = $false
$script:StopSleeps = @()
function Set-DaemonTransientActivity {
    param($SessionId, $Summary, $Extra, $Headers)
    $script:StopPublications += $Summary
    if ($script:StopPublicationFails) { throw [IO.IOException]::new('synthetic publication failure') }
}
function Stop-BridgeCopilotSession {
    param($SessionId, $ProcessId, $GraceSeconds)
    $script:StopCalls += $ProcessId
    [pscustomobject]@{ Stopped = $true; Forced = $false; Detail = 'synthetic stop recorder' }
}
function Wait-CopilotHaStateChange {
    param($EntityIds, $TimeoutSeconds, [scriptblock]$OnTick, $TickMilliseconds, $EventTypes)
    $script:StopWaits++
    if ($script:StopWaitFails) { throw [IO.IOException]::new('synthetic wait failure') }
    & $OnTick | Out-Null
    $null
}
# The wait asks which Home Assistant events to subscribe to as well as which
# entities. Stubbed rather than loaded: this suite is about the stop boundary, and
# the real one reads the answer-button configuration.
function Get-DaemonWatchEventTypes { @() }
function Start-Sleep {
    param([int]$Seconds, [int]$Milliseconds)
    $script:StopSleeps += $Seconds
}
'@
$tickSetup = $daemonSetup + @'

$tickAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repository 'hooks\decision-ha-websocket.ps1'), [ref]$null, [ref]$null)
$tickFunction = $tickAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Wait-CopilotHaStateChange'
}, $true)
if (-not $tickFunction) { throw 'The actual websocket wait function is missing.' }
$tickClauses = @($tickFunction.Body.FindAll({
    param($node)
    $node -is [Management.Automation.Language.TryStatementAst] -and
        $node.Body.Statements.Count -eq 2 -and
        $node.Body.Statements[0].Extent.Text -ceq '$ticked = @(& $OnTick)'
}, $true))
if ($tickClauses.Count -ne 1) { throw 'The actual OnTick try/catch is not unique.' }
$tickBlock = [scriptblock]::Create($tickClauses[0].Extent.Text)
'@
$cases = @(
    @{ Name = 'the prompt-store reader propagates a real context refusal'; Setup = $storeSetup; Refused = $true; Body = @'
$context.RuntimeRoot = $protectedBridge
Read-BridgeStopPromptStore
'@ }
    @{ Name = 'the prompt-store writer propagates a real context refusal'; Setup = $storeSetup; Refused = $true; Body = @'
$context.RuntimeRoot = $protectedBridge
Write-BridgeStopPrompt -SessionId 'synthetic' -Until $expires
'@ }
    @{ Name = 'the whole-store clear propagates a real context refusal'; Setup = $storeSetup; Refused = $true; Body = @'
$context.RuntimeRoot = $protectedBridge
Clear-BridgeStopPromptStore
'@ }
    @{ Name = 'a standalone publisher cannot turn a context refusal into an absent prompt'; Setup = $storeSetup; Refused = $true; Body = @'
$context.RuntimeRoot = $protectedBridge
try {
    Publish-BridgeSessionStatus -SessionId 'synthetic' -SessionName 'S' -Machine 'M' -Headers @{} `
        -Status 'waiting' -Activity 'synthetic activity'
}
finally {
    if ($script:StopStatuses.Count -ne 1 -or $script:StopActivities.Count -ne 0) {
        throw 'The refusal did not occur between status and activity publication.'
    }
}
'@ }
    @{ Name = 'ordinary store states preserve atomic publication and unknown prompts'; Setup = $storeSetup; Refused = $false; Body = @'
$path = Get-BridgeStopPromptPath
if ((Read-BridgeStopPromptStore).State -ne 'Empty' -or (Get-BridgeStopPrompt -SessionId 'first').State -ne 'None') {
    throw 'An absent store no longer reports Empty and None.'
}
if (-not (Write-BridgeStopPrompt -SessionId 'first' -Until $expires -Hint 'first hint') -or
    -not (Write-BridgeStopPrompt -SessionId 'second' -Until $expires -Hint 'second hint')) {
    throw 'An ordinary prompt was not written.'
}
$store = Read-BridgeStopPromptStore
$prompt = Get-BridgeStopPrompt -SessionId 'first'
if ($store.State -ne 'Ok' -or $store.Prompts.Count -ne 2 -or $prompt.State -ne 'Prompt' -or
    $prompt.Hint -ne 'first hint' -or (Test-Path -LiteralPath "$path.pending")) {
    throw 'Atomic publication or the live prompt shape changed.'
}
if (-not (Write-BridgeStopPrompt -SessionId 'first') -or
    (Get-BridgeStopPrompt -SessionId 'second').State -ne 'Prompt') {
    throw 'Removing one prompt changed the other prompt.'
}
if (-not (Write-BridgeStopPrompt -SessionId 'second' -Until ([DateTimeOffset]::Now.AddMinutes(-1))) -or
    (Get-BridgeStopPrompt -SessionId 'second').State -ne 'None') { throw 'An expired prompt is still shown.' }
foreach ($invalid in @('{', '[]', '{"synthetic":{"until":"not-a-date"}}')) {
    [IO.File]::WriteAllText($path, $invalid)
    if ((Read-BridgeStopPromptStore).State -ne 'Failed' -or
        (Get-BridgeStopPrompt -SessionId 'synthetic').State -ne 'Unknown') {
        throw 'An unreadable or invalid store became an absent question.'
    }
    if ((Write-BridgeStopPrompt -SessionId 'synthetic' -Until $expires) -or
        (Write-BridgeStopPrompt -SessionId 'synthetic') -or [IO.File]::ReadAllText($path) -cne $invalid) {
        throw 'A per-session operation rewrote an unreadable store.'
    }
}
Publish-BridgeSessionStatus -SessionId 'synthetic' -SessionName 'S' -Machine 'M' -Headers @{} `
    -Status 'waiting' -Activity 'synthetic activity'
if ($script:StopStatuses.Count -ne 1 -or $script:StopActivities.Count -ne 0) {
    throw 'A standalone publisher overwrote an unknown prompt.'
}
[IO.File]::WriteAllText("$path.pending", 'synthetic pending bytes')
if (-not (Clear-BridgeStopPromptStore) -or (Test-Path -LiteralPath $path) -or
    (Test-Path -LiteralPath "$path.pending")) { throw 'Whole-store cleanup left a store or pending file.' }
'@ }
    @{ Name = 'ordinary non-test path failures keep the store failure results'; Setup = $storeSetup; Refused = $false; Body = @'
if ($HOME -ne $context.Home -or $env:HOME -ne $context.Home) { throw 'The control lost its synthetic home.' }
Remove-Item Env:\AGENT_HA_BRIDGE_TEST_ROOT, Env:\AGENT_HA_BRIDGE_TEST_ID, Env:\AGENT_HA_BRIDGE_OFFLINE_TEST
if (Test-BridgeTestExecution) { throw 'The ordinary control still has a test entry.' }
# An empty path fails binding before I/O; every other root remains synthetic.
$context.Legacy = $false
$context.RuntimeRoot = ''
if ((Read-BridgeStopPromptStore).State -ne 'Failed' -or
    (Get-BridgeStopPrompt -SessionId 'synthetic').State -ne 'Unknown' -or
    (Write-BridgeStopPrompt -SessionId 'synthetic' -Until $expires) -or
    (Clear-BridgeStopPromptStore)) { throw 'An ordinary unmarked path failure changed its result.' }
'@ }
    @{ Name = 'ordinary publication failure removes its pending path'; Setup = $storeSetup; Refused = $false; Body = @'
$path = Get-BridgeStopPromptPath
[void][IO.Directory]::CreateDirectory("$path.pending")
if (Write-BridgeStopPrompt -SessionId 'synthetic' -Until $expires) {
    throw 'Writing prompt bytes to a directory was reported as successful.'
}
if ((Test-Path -LiteralPath $path) -or (Test-Path -LiteralPath "$path.pending")) {
    throw 'An ordinary failed publication left its target or pending directory.'
}
'@ }
    @{ Name = 'arming a stop propagates a real store refusal'; Setup = $daemonSetup; Refused = $true; Body = @'
$script:DaemonStopArmed.Clear()
$context.RuntimeRoot = $protectedBridge
try { Set-DaemonStopArm -SessionId $stopSession -Status 'working' }
finally {
    if ($script:DaemonStopArmed.Count -ne 0) { throw 'A refused store write created consent.' }
}
'@ }
    @{ Name = 'an ordinary unreadable store never arms a stop'; Setup = $daemonSetup; Refused = $false; Body = @'
$path = Get-BridgeStopPromptPath
[void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
[IO.File]::WriteAllText($path, '{')
$script:DaemonStopArmed.Clear()
if ((Set-DaemonStopArm -SessionId $stopSession -Status 'working') -or
    $script:DaemonStopArmed.Count -ne 0 -or [IO.File]::ReadAllText($path) -cne '{') {
    throw 'An unreadable store gained an arm or was rewritten.'
}
'@ }
    @{ Name = 'startup prompt cleanup propagates a real store refusal'; Setup = $daemonSetup; Refused = $true; Body = @'
$script:DaemonStopArmed.Clear()
$context.RuntimeRoot = $protectedBridge
Clear-DaemonStopPrompts
'@ }
    @{ Name = 'ordinary whole-store repair drops every stranded arm'; Setup = $daemonSetup; Refused = $false; Body = @'
$path = Get-BridgeStopPromptPath
[void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
[IO.File]::WriteAllText($path, '{')
$script:DaemonStopArmed['other'] = [pscustomobject]@{ At = [DateTimeOffset]::Now }
Remove-DaemonStopArm -SessionId $stopSession
if ($script:DaemonStopArmed.Count -ne 0 -or (Test-Path -LiteralPath $path)) {
    throw 'Whole-store repair stranded consent or left the unreadable document.'
}
if ([IO.File]::ReadAllText($script:DaemonConfig.LogFile) -notmatch 'cleared it whole and disarmed 1') {
    throw 'The ordinary repair was not reported.'
}
'@ }
    @{ Name = 'the lapse caller propagates the actual removal refusal'; Setup = $daemonSetup; Refused = $true; Body = @'
$arm = $script:DaemonStopArmed[$stopSession]
$context.RuntimeRoot = $protectedBridge
try { Clear-DaemonExpiredStopArms -Headers @{} -State $stopState }
finally {
    if ($script:StopPublications.Count -ne 1 -or $arm.RetryAt -ne [DateTimeOffset]::MinValue) {
        throw 'The store refusal became an ordinary publication retry.'
    }
}
'@ }
    @{ Name = 'ordinary lapse publication failure retains its retry arm'; Setup = $daemonSetup; Refused = $false; Body = @'
$script:StopPublicationFails = $true
$before = [DateTimeOffset]::Now
Clear-DaemonExpiredStopArms -Headers @{} -State $stopState
if ($script:StopPublications.Count -ne 1 -or -not $script:DaemonStopArmed.ContainsKey($stopSession) -or
    $script:DaemonStopArmed[$stopSession].RetryAt -le $before) {
    throw 'An ordinary publication failure lost the retry arm or backoff.'
}
'@ }
    @{ Name = 'the fast lane propagates the actual lapse refusal'; Setup = $daemonSetup; Refused = $true; Body = @'
$context.RuntimeRoot = $protectedBridge
try { Invoke-DaemonFastActivity -Headers @{} -State $stopState }
finally {
    if ($script:StopPublications.Count -ne 1 -or (Test-Path -LiteralPath $script:DaemonConfig.LogFile)) {
        throw 'The marked sweep became an ordinary log-only result.'
    }
}
'@ }
    @{ Name = 'ordinary fast-lane sweep failures are still logged'; Setup = $daemonSetup; Refused = $false; Body = @'
$script:DaemonStopArmed[$stopSession] = [pscustomobject]@{ At = [DateTimeOffset]::Now.AddMinutes(-1) }
Invoke-DaemonFastActivity -Headers @{} -State $stopState
if ([IO.File]::ReadAllText($script:DaemonConfig.LogFile) -notmatch 'end confirmation sweep failed' -or
    $script:StopPublications.Count -ne 0 -or $script:DaemonStopArmed.Count -ne 1) {
    throw 'An ordinary malformed arm changed the sweep failure behavior.'
}
'@ }
    @{ Name = 'the watch caller propagates its real fast-lane refusal'; Setup = $daemonSetup; Refused = $true; Body = @'
$context.RuntimeRoot = $protectedBridge
try { Wait-DaemonChange -Headers @{} -State $stopState -WatchEntities @($stopEntity) }
finally {
    if ($script:StopWaits -ne 1 -or $script:StopPublications.Count -ne 1 -or
        $script:DaemonWatchFailures -ne 0 -or $script:StopSleeps.Count -ne 0) {
        throw 'The marked callback became a watch retry or sleep.'
    }
}
'@ }
    @{ Name = 'ordinary watch failures retain backoff and success resets it'; Setup = $daemonSetup; Refused = $false; Body = @'
$script:StopWaitFails = $true
$first = Wait-DaemonChange -Headers @{} -State $stopState -WatchEntities @($stopEntity)
$second = Wait-DaemonChange -Headers @{} -State $stopState -WatchEntities @($stopEntity)
if ($null -ne $first -or $null -ne $second -or $script:DaemonWatchFailures -ne 2 -or
    ($script:StopSleeps -join ',') -cne '2,4' -or
    [IO.File]::ReadAllText($script:DaemonConfig.LogFile) -notmatch 'watch failed') {
    throw 'Ordinary wait failure changed its result, log or exponential backoff.'
}
$script:StopWaitFails = $false
$script:DaemonStopArmed.Clear()
$null = Wait-DaemonChange -Headers @{} -State $stopState -WatchEntities @($stopEntity)
if ($script:DaemonWatchFailures -ne 0 -or $script:StopWaits -ne 3 -or $script:StopSleeps.Count -ne 2) {
    throw 'A successful wait did not reset failures without sleeping.'
}
'@ }
    @{ Name = 'the immediate stop-hit caller propagates a real store refusal'; Setup = $daemonSetup; Refused = $true; Body = @'
$script:DaemonLive = @{ $stopSession = [pscustomobject]@{ ProcessId = 1234 } }
$context.RuntimeRoot = $protectedBridge
try { Invoke-DaemonHit -Hit ([pscustomobject]@{ EntityId = $stopEntity }) -Headers @{} -State $stopState }
finally {
    if ($script:StopCalls.Count -ne 0 -or $script:StopPublications.Count -ne 0 -or
        (Test-Path -LiteralPath $script:DaemonConfig.LogFile)) {
        throw 'The refused store reached a stop, publication or ordinary failure log.'
    }
}
'@ }
    @{ Name = 'ordinary immediate stop-hit failures are still logged'; Setup = $daemonSetup; Refused = $false; Body = @'
$script:DaemonLive = @{ $stopSession = [pscustomobject]@{ ProcessId = 'not-a-process-id' } }
Invoke-DaemonHit -Hit ([pscustomobject]@{ EntityId = $stopEntity }) -Headers @{} -State $stopState
if ([IO.File]::ReadAllText($script:DaemonConfig.LogFile) -notmatch 'end session failed' -or
    $script:StopCalls.Count -ne 0 -or $script:StopPublications.Count -ne 0) {
    throw 'An ordinary invalid target changed the stop-hit failure behavior.'
}
'@ }
    @{ Name = 'ordinary tick failures and the boolean stop signal are preserved'; Setup = $tickSetup; Refused = $false; Body = @'
$invalidJson = Join-Path $env:TEMP 'invalid-tick.json'
[IO.File]::WriteAllText($invalidJson, '{')
$OnTick = { Get-Content -LiteralPath $invalidJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
$stop = $false
. $tickBlock
if ($stop) { throw 'An ordinary file failure ended the wait.' }
$OnTick = { 'synthetic progress'; $true }
$stop = $false
. $tickBlock
if (-not $stop -or $ticked.Count -ne 2) { throw 'The ordinary final boolean no longer ends the wait.' }
'@ }
    @{ Name = 'the actual tick catch propagates its real stop-store refusal'; Setup = $tickSetup; Refused = $true; Body = @'
$context.RuntimeRoot = $protectedBridge
$OnTick = { Invoke-DaemonFastActivity -Headers @{} -State $stopState }
$stop = $false
try { . $tickBlock }
finally {
    if ($script:StopPublications.Count -ne 1 -or $stop) {
        throw 'The real store refusal did not reach the tick boundary.'
    }
}
'@ }
)

$fixture = New-BoundaryFixture -Suite 'test-write-boundary-stop.ps1'
try {
    foreach ($case in $cases) {
        $null = Invoke-BoundaryFixture -Fixture $fixture -Name $case.Name -Refused:$case.Refused `
            -Body ($case.Setup + "`n" + $case.Body)
    }
}
finally {
    try { Complete-BoundaryFixture -Fixture $fixture }
    finally { Remove-BoundaryFixture -Fixture $fixture }
}
if ($script:Failures) { throw "$script:Failures stop-boundary check(s) failed." }
Write-Host 'All stop-boundary checks passed'
exit 0
