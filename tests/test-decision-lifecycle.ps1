#Requires -Version 7.0
<#
.SYNOPSIS
    Local decision ownership, later lifecycle invalidation and stop status contracts.
.DESCRIPTION
    Uses checkout hooks, marker files, readers and the real status publisher/renderer.
    Client payloads and transport/process boundaries are synthetic; no native client,
    console input, live Home Assistant or approval UI is exercised.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'hooks\agent-bridge-daemon.ps1')
. (Join-Path $repo 'codex\hooks\codex-session.ps1')
. (Join-Path $repo 'codex\hooks\codex-hooks.ps1')
$script:CodexAdapterLoaded = $true

$root = Join-Path $env:TEMP ('decision-lifecycle-' + [guid]::NewGuid().ToString('N'))
if (-not [IO.Path]::GetFullPath($root).StartsWith(
    $env:AGENT_HA_BRIDGE_TEST_ROOT + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase)) { throw 'Lifecycle fixtures require the canonical test sandbox.' }
[void][IO.Directory]::CreateDirectory($root)
$script:CodexStateRoot = Join-Path $root 'codex'
$script:DecisionBridgeConfig.SessionStateRoot = Join-Path $root 'copilot'
$script:DaemonConfig.LogFile = Join-Path $root 'daemon.log'
$headers = @{}
$script:Failures = 0

function Test-That {
    param([string]$Name, [scriptblock]$Check)
    $ok = $false
    $detail = ''
    try { $ok = [bool](& $Check) } catch { $detail = " - $($_.Exception.Message)" }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$detail"; $script:Failures++ }
}

function New-LifecycleEvent {
    param([string]$SessionId, [string]$Name)
    [pscustomobject]@{
        session_id = $SessionId; hook_event_name = $Name; cwd = $root
        tool_name = 'shell'; tool_input = [pscustomobject]@{ command = 'echo synthetic' }
        prompt = 'Synthetic prompt'; last_assistant_message = 'Synthetic reply'
    }
}

function Confirm-LifecycleStop {
    <#
        Puts the sessions in $State past the confirmation a session that is not idle
        asks for, so a single Invoke-PendingStops below actually ends them.

        Everything here is about what a stop *does* - the error it records, how that
        survives restart, the statuses it publishes - and every fixture is deliberately
        fixed at 'working'. Without this they would only ever arm, and the failures
        these assert on would never happen. The confirmation itself is covered where it
        belongs, in tests/test-stop-session.ps1.
    #>
    param([Parameter(Mandatory)][hashtable]$State)
    foreach ($id in @($State.Keys)) { Set-DaemonStopArm -SessionId $id -Status 'working' }
}

try {
    & {
        Write-Host '--- later lifecycle invalidation, without native request IDs ---'
        $sid = '10000000-0000-4000-8000-000000000001'
        function Get-CodexOwningProcessId {
            param($SessionId, $Ancestors)
            $script:OwnerLookupSawMarker = Test-Path -LiteralPath (Get-CodexApprovalMarkerPath -SessionId $SessionId)
            0
        }
        function Test-BridgeDaemonAlive { $script:LifecycleScenario -eq 'live daemon' }
        function Enter-BridgeAdapterSession {
            $script:AdmissionCalls++
            if ($script:LifecycleScenario -eq 'admission failure') { throw 'Synthetic admission failure.' }
            $null
        }
        foreach ($eventName in @('PreToolUse', 'UserPromptSubmit', 'Stop', 'SessionEnd')) {
            foreach ($scenario in @('live daemon', 'offline', 'admission failure')) {
                $script:LifecycleScenario = $scenario
                $script:AdmissionCalls = 0
                $script:OwnerLookupSawMarker = $true
                Write-CodexApprovalMarker -SessionId $sid -DecisionId 'previous-approval' -Question 'Synthetic approval'
                Test-That "$eventName retires approval before local lookup and $scenario early returns" {
                    $expectedFailure = $scenario -eq 'admission failure' -and $eventName -ne 'SessionEnd'
                    $failed = $false
                    try { $output = Invoke-CodexHook -HookEvent (New-LifecycleEvent $sid $eventName) }
                    catch {
                        if ($_.Exception.Message -cne 'Synthetic admission failure.') { throw }
                        $failed = $true
                        $output = $null
                    }
                    $failed -eq $expectedFailure -and $null -eq $output -and
                    -not $script:OwnerLookupSawMarker -and
                    -not (Test-Path -LiteralPath (Get-CodexApprovalMarkerPath -SessionId $sid)) -and
                    ($eventName -ne 'SessionEnd' -or $script:AdmissionCalls -eq 0)
                }
                [void](Remove-CodexApprovalMarker -SessionId $sid)
            }
        }
    }

    & {
        Write-Host '--- unchanged PermissionRequest timing, format and no-ID approval route ---'
        $sid = '20000000-0000-4000-8000-000000000002'
        $script:PermissionId = $sid
        $script:PermissionOnline = $true
        $script:PermissionPublishFails = $false
        $script:PermissionTrace = [Collections.Generic.List[string]]::new()
        $script:ApprovalInputs = [Collections.Generic.List[string]]::new()
        $script:ApprovalChoice = 'Approve'
        $script:ApprovalGeneration = ''
        function Get-CodexOwningProcessId { param($SessionId, $Ancestors) 0 }
        function Test-BridgeDaemonAlive { $true }
        function Enter-BridgeAdapterSession { if ($script:PermissionOnline) { @{} } }
        function Get-CodexSessionDisplay { param($SessionId, $WorkingDirectory) [pscustomobject]@{ Name = 'Synthetic'; Machine = 'TEST' } }
        function Confirm-BridgeSessionEntities { param($SessionId, $SessionName, $Machine, $Headers) $true }
        function Publish-BridgeSessionStatus {
            param($SessionId, $SessionName, $Machine, $Headers, $Status, $Activity, $ExtraAttributes, $PreserveActivityDetail, $ActivityDetail)
            $script:PermissionTrace.Add("status:$((Get-CodexApprovalMarker -SessionId $SessionId).DecisionId)")
        }
        function Set-CopilotMqttDecision {
            param($SessionId, $SessionName, $Machine, $Question, $Choices, $Fields, $DecisionId, $Headers)
            $script:PermissionTrace.Add("selector:$((Get-CodexApprovalMarker -SessionId $SessionId).DecisionId)")
            if ($script:PermissionPublishFails) { throw 'Synthetic selector failure.' }
            $script:PermissionChoices = @($Choices)
        }
        function Send-BridgeNotification {
            param($Title, $Message, $Headers)
            $script:PermissionTrace.Add("notification:$((Get-CodexApprovalMarker -SessionId $script:PermissionId).DecisionId)")
        }
        function Get-HomeAssistantState {
            param($EntityId, $Headers)
            [pscustomobject]@{
                state = $script:ApprovalChoice
                attributes = [pscustomobject]@{ decision_id = $script:ApprovalGeneration }
            }
        }
        function Send-CopilotSessionPrompt {
            param($SessionId, $Text, $ProcessId)
            $script:ApprovalInputs.Add([string]$Text)
            [pscustomobject]@{ Delivered = $true; ProcessId = $ProcessId; Detail = 'synthetic boundary' }
        }
        function Clear-CopilotMqttDecision { param($SessionId, $SessionName, $Machine, $Headers) }
        Write-CodexApprovalMarker -SessionId $sid -DecisionId 'previous' -Question 'Previous synthetic approval'
        $output = Invoke-CodexHook -HookEvent (New-LifecycleEvent $sid 'PermissionRequest')
        $marker = Get-CodexApprovalMarker -SessionId $sid
        Test-That 'a no-ID PermissionRequest still returns no native decision and writes the legacy marker' {
            $null -eq $output -and
            ($marker.PSObject.Properties.Name | Sort-Object) -join ',' -ceq 'Created,DecisionId,Question,SessionId'
        }
        Test-That 'PermissionRequest still creates its marker after status and selector publication' {
            $script:PermissionTrace.Count -eq 3 -and
            $script:PermissionTrace[0] -ceq 'status:previous' -and
            $script:PermissionTrace[1] -ceq 'selector:previous' -and
            $script:PermissionTrace[2] -ceq "notification:$($marker.DecisionId)"
        }
        Test-That 'the existing selector choices and timestamp-based dashboard key are unchanged' {
            ($script:PermissionChoices -join ',') -ceq 'Approve,Deny' -and
            $marker.DecisionId -match ('^' + [regex]::Escape((Get-CopilotMqttNodeId -SessionId $sid)) + '-\d+$')
        }
        $state = @{ $sid = [pscustomobject]@{ Name = 'Synthetic'; Machine = 'TEST' } }
        $live = @{ $sid = [pscustomobject]@{ Kind = 'codex'; ProcessId = 123 } }
        foreach ($choice in @('Approve', 'Deny')) {
            $script:ApprovalChoice = $choice
            $script:ApprovalGeneration = "legacy-$choice"
            Write-CodexApprovalMarker -SessionId $sid -DecisionId $script:ApprovalGeneration -Question 'Synthetic approval'
            Invoke-PendingCodexApprovals -Headers $headers -State $state -Live $live
        }
        Test-That 'real legacy marker readers preserve both existing dashboard approval routes' {
            ($script:ApprovalInputs -join ',') -ceq 'y,n'
        }
        Invoke-CodexHook -HookEvent (New-LifecycleEvent $sid 'PreToolUse')
        Invoke-PendingCodexApprovals -Headers $headers -State $state -Live $live
        Test-That 'a later tool fast path prevents a retired approval from being delivered again' {
            $script:ApprovalInputs.Count -eq 2
        }

        Write-CodexApprovalMarker -SessionId $sid -DecisionId 'preserved' -Question 'Synthetic pending approval'
        $path = Get-CodexApprovalMarkerPath -SessionId $sid
        $before = [IO.File]::ReadAllText($path)
        $script:PermissionOnline = $false
        Invoke-CodexHook -HookEvent (New-LifecycleEvent $sid 'PermissionRequest')
        Test-That 'PermissionRequest outage behavior is unchanged rather than moved to an earlier write' {
            [IO.File]::ReadAllText($path) -ceq $before
        }
        $script:PermissionOnline = $true
        $script:PermissionPublishFails = $true
        Test-That 'a failed selector publish still precedes any replacement PermissionRequest marker' {
            $failed = $false
            try { Invoke-CodexHook -HookEvent (New-LifecycleEvent $sid 'PermissionRequest') }
            catch {
                if ($_.Exception.Message -cne 'Synthetic selector failure.') { throw }
                $failed = $true
            }
            $failed -and [IO.File]::ReadAllText($path) -ceq $before
        }
        $script:PermissionOnline = $false
        foreach ($name in @('SessionStart', 'UnknownEvent')) {
            Invoke-CodexHook -HookEvent (New-LifecycleEvent $sid $name)
            Test-That "$name does not acquire a new approval-invalidation meaning" { [IO.File]::ReadAllText($path) -ceq $before }
        }
        [void](Remove-CodexApprovalMarker -SessionId $sid)
    }

    & {
        Write-Host '--- documented no-ID Copilot input retains both existing answer routes ---'
        $sid = '30000000-0000-4000-8000-000000000003'
        $transcript = Join-Path $root 'copilot-events.jsonl'
        $script:QuestionInputs = [Collections.Generic.List[string]]::new()
        $script:QuestionClears = 0
        function Enter-BridgeAdapterSession { @{ Synthetic = 'fixture' } }
        function Get-CopilotSessionDisplay { param($SessionId, $WorkingDirectory) [pscustomobject]@{ Name = 'Synthetic'; Machine = 'TEST' } }
        function Confirm-BridgeSessionEntities { param($SessionId, $SessionName, $Machine, $Headers, $ProbeEntity) $true }
        function Set-CopilotMqttDecision { param($SessionId, $SessionName, $Machine, $Question, $Choices, $Fields, $DecisionId, $Headers) }
        function Send-BridgeNotification { param($Title, $Message, $Headers) }
        function Get-HomeAssistantState {
            param($EntityId, $Headers)
            if ($EntityId -like 'text.*_reply') { return [pscustomobject]@{ state = 'Synthetic dashboard answer' } }
            [pscustomobject]@{ state = 'Awaiting answer...'; attributes = [pscustomobject]@{ question = 'Synthetic question' } }
        }
        function Send-CopilotSessionPrompt {
            param($SessionId, $Text, $ProcessId)
            $script:QuestionInputs.Add([string]$Text)
            [pscustomobject]@{ Delivered = $true; ProcessId = $ProcessId; Detail = 'synthetic boundary' }
        }
        function Clear-CopilotMqttDecision { param($SessionId, $SessionName, $Machine, $Headers) $script:QuestionClears++ }
        function Invoke-HomeAssistantService { param($Domain, $Service, $Headers, $Data) }
        function Set-DaemonTransientActivity { param($SessionId, $Summary, $Extra, $Headers) }
        $hook = [pscustomobject]@{
            sessionId = $sid; timestamp = 1; cwd = $root; toolName = 'ask_user'
            toolArgs = [pscustomobject]@{ question = 'Synthetic question' }
        }
        # The production hook/spool parser runs without StrictMode on current main.
        $output = & { Set-StrictMode -Off; Invoke-CopilotAskUserHook -HookEvent $hook }
        $marker = Get-CopilotDecisionMarker -SessionId $sid
        Test-That 'the documented no-ID hook stays dashboard-answerable with its existing marker shape' {
            $null -eq $output -and $null -ne $marker -and
            [string]$marker.toolCallId -ceq '' -and -not $marker.terminalOnly -and $marker.mode -ceq 'freeform'
        }
        Set-Content -LiteralPath $transcript -Encoding utf8 -Value '{"type":"tool.execution_start","timestamp":"2026-09-30T16:00:00-07:00","data":{"toolName":"ask_user","toolCallId":"transcript-only-id"}}'
        $session = [pscustomobject]@{ SessionId = $sid; Kind = 'copilot'; Transcript = $transcript }
        $state = @{ $sid = [pscustomobject]@{ Name = 'Synthetic'; Machine = 'TEST'; Status = 'working' } }
        $script:DaemonLive = @{ $sid = $session }
        $ask = Get-DaemonAskUserState -Session $session -Marker $marker
        Test-That 'the real current transcript reader accepts a marker without native hook identity' { $ask.Started -and $ask.Pending }
        Invoke-PendingDecisions -Headers $headers -State $state -Live $script:DaemonLive
        Invoke-PendingDecisions -Headers $headers -State $state -Live $script:DaemonLive
        Test-That 'the existing no-ID dashboard answer route records delivery once' {
            $script:QuestionInputs.Count -eq 1 -and $script:QuestionInputs[0] -ceq 'Synthetic dashboard answer' -and
            (Get-CopilotDecisionMarker -SessionId $sid).injectedAnswer -ceq 'Synthetic dashboard answer'
        }
        Remove-CopilotDecisionMarker -SessionId $sid
        $null = & { Set-StrictMode -Off; Invoke-CopilotAskUserHook -HookEvent $hook }
        Add-Content -LiteralPath $transcript -Encoding utf8 -Value '{"type":"tool.execution_complete","timestamp":"2026-09-30T16:00:01-07:00","data":{"toolCallId":"transcript-only-id","result":{"content":"Synthetic terminal answer"}}}'
        Invoke-PendingDecisions -Headers $headers -State $state -Live $script:DaemonLive
        Test-That 'a terminal answer still completes the no-ID marker without dashboard delivery' {
            $script:QuestionInputs.Count -eq 1 -and $script:QuestionClears -gt 0 -and
            $null -eq (Get-CopilotDecisionMarker -SessionId $sid)
        }
    }

    & {
        Write-Host '--- real-file ownership: legacy markers, absence and uncertainty ---'
        $sid = '40000000-0000-4000-8000-000000000004'
        $state = @{ $sid = [pscustomobject]@{ Name = 'Synthetic'; Machine = 'TEST' } }
        $script:OwnershipLog = [Collections.Generic.List[string]]::new()
        $script:CardMode = 'empty'
        $script:OnOwnershipRead = $null
        $script:OnOwnershipTranscript = $null
        $script:OnOwnershipClear = $null
        function Write-DaemonLog { param($Message) $script:OwnershipLog.Add([string]$Message) }
        function Get-DaemonEntityState {
            param($EntityId, $Headers)
            $script:OwnershipReads++
            if ($script:OnOwnershipRead) { & $script:OnOwnershipRead }
            if ($script:CardMode -eq 'unavailable') { throw 'Synthetic card outage.' }
            [pscustomobject]@{ attributes = [pscustomobject]@{ question = $(if ($script:CardMode -eq 'armed') { 'Synthetic question' } else { '' }) } }
        }
        function Get-DaemonAskUserState {
            param($Session, $Marker)
            if ($script:OnOwnershipTranscript) { & $script:OnOwnershipTranscript }
            [pscustomobject]@{ Pending = $false }
        }
        function Clear-CopilotMqttDecision {
            param($SessionId, $SessionName, $Machine, $Headers)
            $script:OwnershipClears++
            if ($script:OnOwnershipClear) { & $script:OnOwnershipClear }
        }
        foreach ($kind in @('copilot', 'codex')) {
            $session = [pscustomobject]@{ SessionId = $sid; Kind = $kind }
            $reader = if ($kind -eq 'copilot') { 'Get-CopilotDecisionMarker' } else { 'Get-CodexApprovalMarker' }
            $path = if ($kind -eq 'copilot') { Get-CopilotDecisionMarkerPath -SessionId $sid } else { Get-CodexApprovalMarkerPath -SessionId $sid }
            if (-not [IO.Path]::GetFullPath($path).StartsWith(
                $env:AGENT_HA_BRIDGE_TEST_ROOT + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $path)) { throw 'Unsafe or existing marker fixture.' }
            $writeOwner = {
                if ($kind -eq 'copilot') { Write-CopilotDecisionMarker -SessionId $sid -DecisionId 'legacy-owner' -Question 'Synthetic' -Mode freeform }
                else { Write-CodexApprovalMarker -SessionId $sid -DecisionId 'legacy-owner' -Question 'Synthetic' }
            }
            foreach ($mode in @('empty', 'unavailable')) {
                $script:CardMode = $mode
                $script:OwnershipReads = 0
                Test-That "absent $kind markers permit ordinary continuation with a $mode card" {
                    $null -eq (& $reader -SessionId $sid) -and
                    (Test-DaemonReplyBoxFree -SessionId $sid -Session $session -State $state -Headers $headers)
                }
            }
            & $writeOwner
            foreach ($mode in @('empty', 'unavailable', 'armed')) {
                $script:CardMode = $mode
                $script:OwnershipReads = 0
                Test-That "a real legacy $kind owner takes precedence over a $mode remote card" {
                    (& $reader -SessionId $sid).DecisionId -ceq 'legacy-owner' -and
                    -not (Test-DaemonReplyBoxFree -SessionId $sid -Session $session -State $state -Headers $headers) -and
                    $script:OwnershipReads -eq 0
                }
            }
            $script:CardMode = 'empty'
            if ($script:BridgeIsWindows) {
                $locked = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                try {
                    Test-That "a real exclusively locked $kind file is uncertain, not absent" {
                        $script:OwnershipReads = 0
                        $script:OwnershipLog.Clear()
                        -not (Test-DaemonReplyBoxFree -SessionId $sid -Session $session -State $state -Headers $headers) -and
                        $script:OwnershipReads -eq 0 -and $script:OwnershipLog.Count -gt 0
                    }
                }
                finally { $locked.Dispose() }
            }
            else { Write-Host "SKIP  Windows exclusive-sharing $kind error; real directory read errors run on all platforms" }
            Remove-Item -LiteralPath $path -Force
            foreach ($content in @(
                @{ Name = 'corrupt'; Text = '{"private-synthetic-content":' }
                @{ Name = 'empty'; Text = '' }
                @{ Name = 'whitespace'; Text = " `r`n " }
                @{ Name = 'JSON null'; Text = 'null' }
                @{ Name = 'JSON array'; Text = '[]' }
            )) {
                [IO.File]::WriteAllText($path, $content.Text)
                Test-That "real $($content.Name) $kind ownership fails closed without exposing content" {
                    $script:OwnershipReads = 0
                    $script:OwnershipLog.Clear()
                    -not (Test-DaemonReplyBoxFree -SessionId $sid -Session $session -State $state -Headers $headers) -and
                    $script:OwnershipReads -eq 0 -and $script:OwnershipLog.Count -gt 0 -and
                    ($script:OwnershipLog -join ' ') -notmatch 'private-synthetic-content'
                }
                Remove-Item -LiteralPath $path -Force
            }
            [void][IO.Directory]::CreateDirectory($path)
            Test-That "a real $kind directory read failure cannot free continuation" {
                $script:OwnershipReads = 0
                $script:OwnershipLog.Clear()
                -not (Test-DaemonReplyBoxFree -SessionId $sid -Session $session -State $state -Headers $headers) -and
                $script:OwnershipReads -eq 0 -and $script:OwnershipLog.Count -gt 0
            }
            Remove-Item -LiteralPath $path -Force
            $script:OnOwnershipRead = $writeOwner
            Test-That "a $kind owner arriving during an empty-card read blocks continuation" {
                -not (Test-DaemonReplyBoxFree -SessionId $sid -Session $session -State $state -Headers $headers)
            }
            $script:OnOwnershipRead = $null
            Remove-Item -LiteralPath $path -Force
            $script:CardMode = 'armed'
            $script:OwnershipClears = 0
            $script:OnOwnershipTranscript = $writeOwner
            Test-That "a $kind owner arriving during the stale check prevents card clearing" {
                -not (Test-DaemonReplyBoxFree -SessionId $sid -Session $session -State $state -Headers $headers) -and
                $script:OwnershipClears -eq 0
            }
            $script:OnOwnershipTranscript = $null
            Remove-Item -LiteralPath $path -Force
            $script:OnOwnershipClear = $writeOwner
            Test-That "a $kind owner arriving during cleanup still blocks continuation" {
                -not (Test-DaemonReplyBoxFree -SessionId $sid -Session $session -State $state -Headers $headers)
            }
            $script:OnOwnershipClear = $null
            Remove-Item -LiteralPath $path -Force
            Test-That "a genuinely stale unowned $kind card still clears and permits continuation" {
                Test-DaemonReplyBoxFree -SessionId $sid -Session $session -State $state -Headers $headers
            }
            $script:CardMode = 'empty'
        }
        $script:OnOwnershipRead = {
            $blocked = [InvalidOperationException]::new('Synthetic offline boundary.')
            $blocked.Data['BridgeTestNetworkBlocked'] = $true
            throw $blocked
        }
        Test-That 'the offline transport boundary is never converted into free continuation' {
            $rejected = $false
            try { [void](Test-DaemonReplyBoxFree -SessionId $sid -Session $session -State $state -Headers $headers) }
            catch { $rejected = [bool]$_.Exception.Data['BridgeTestNetworkBlocked'] }
            $rejected
        }
    }

    & {
        Write-Host '--- failed stop survives real state persistence and startup restoration ---'
        . (Join-Path $repo 'codex\hooks\codex-transcript.ps1')
        . (Join-Path $repo 'claude\hooks\claude-transcript.ps1')
        $script:ClaudeAdapterLoaded = $true
        $script:RestorePublished = [Collections.Generic.List[object]]::new()
        $script:RestoreLive = @{}
        $script:RestoreStopCalls = 0
        $script:RestorePress = '2026-09-30T17:00:00-07:00'
        $script:DaemonStartedAt = [DateTimeOffset]::Parse('2026-09-30T16:00:00-07:00')
        $script:DaemonLaunchedPids = @{}
        $script:DaemonReconcileStates = $null
        $script:DaemonRegistrationStamps = @{}
        $previousStateFile = $script:DaemonConfig.StateFile
        $script:DaemonConfig.StateFile = Join-Path $root 'stop-restoration.json'
        $script:DaemonStateLastWritten = $null

        function Publish-CopilotMqttMessage {
            param($Topic, $Payload, $Headers, [switch]$Retain)
            $script:RestorePublished.Add([pscustomobject]@{ Topic = $Topic; Payload = $Payload })
        }
        function Get-HomeAssistantState {
            param($EntityId, $Headers)
            [pscustomobject]@{
                state = $(if ($EntityId -like 'button.*_stop') { $script:RestorePress } else { 'off' })
                attributes = [pscustomobject]@{}
            }
        }
        function Invoke-HomeAssistantService { param($Domain, $Service, $Headers, $Data) }
        function Stop-BridgeCopilotSession {
            param($SessionId, $ProcessId)
            $script:RestoreStopCalls++
            [pscustomobject]@{ Stopped = $false; Detail = 'Synthetic process remains alive' }
        }
        function Get-LiveBridgeSessions { $script:RestoreLive }
        function Get-LiveMcpSessions { param($Headers) @{} }
        function Get-BridgeSessionDisplay { param($SessionId, $Kind, $WorkingDirectory) [pscustomobject]@{ Name = "$Kind`: synthetic"; Machine = 'TEST' } }
        function Get-DaemonLaunchCapabilities { @{} }
        function Publish-DaemonGlobalStatus { param($Descriptors, $Capabilities, $Headers) }
        function Publish-DaemonOnlineHeartbeat { param($Headers) }
        function Sync-DaemonDashboard { param($Descriptors, $Capabilities, $Headers) $true }
        function Remove-CopilotMqttSession { param($SessionId, $Headers) }

        function Set-RestorationCodexRegistration {
            param([string]$SessionId, [string]$Status, [string]$At, [string]$Transcript)
            $path = Write-CodexSessionRegistration -SessionId $SessionId -Status $Status `
                -Activity 'Synthetic native activity' -TranscriptPath $Transcript -WorkingDirectory $root -ProcessId 0
            $registration = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $registration.Updated = $At
            $registration | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding utf8
            [IO.File]::SetLastWriteTimeUtc($path, [DateTimeOffset]::Parse($At).UtcDateTime)
        }
        function New-RestorationFixture {
            param([string]$Kind)
            $id = [guid]::NewGuid().ToString()
            $sessionRoot = Join-Path $script:DecisionBridgeConfig.SessionStateRoot $id
            [void][IO.Directory]::CreateDirectory($sessionRoot)
            $transcript = Join-Path $sessionRoot 'events.jsonl'
            $text = if ($Kind -eq 'copilot') { '{"type":"assistant.turn_start","timestamp":"2026-09-30T16:59:00-07:00"}' + "`n" } else { '' }
            [IO.File]::WriteAllText($transcript, $text, [Text.UTF8Encoding]::new($false))
            $session = [pscustomobject]@{
                SessionId = $id; Kind = $Kind; ProcessId = 0; Transcript = $transcript
                Status = 'working'; WorkingDirectory = $root
            }
            $entry = [pscustomobject]@{
                Name = "$Kind`: synthetic"; Machine = 'TEST'; Kind = $Kind; Status = 'working'
                Offset = [IO.FileInfo]::new($transcript).Length
                LastSummary = 'Earlier native activity'; LastResponse = 'Retained synthetic response'
            }
            if ($Kind -eq 'claude') {
                $session | Add-Member HookStatus 'idle'
                $session | Add-Member HookStatusAt '2026-09-30T16:59:00-07:00'
                $entry | Add-Member HookStatusAt '2026-09-30T16:59:00-07:00'
            }
            elseif ($Kind -eq 'codex') {
                Set-RestorationCodexRegistration -SessionId $id -Status working -At '2026-09-30T16:59:00-07:00' -Transcript $transcript
            }
            @{ Id = $id; Session = $session; State = @{ $id = $entry }; Live = @{ $id = $session }; Transcript = $transcript }
        }
        function Invoke-RestorationRoundTrip {
            param([hashtable]$Fixture)
            Write-DaemonState -State $Fixture.State
            $read = Read-DaemonState
            $script:RestoreLive = $Fixture.Live
            $script:RestorePublished.Clear()
            Restore-DaemonSessionCards -Headers $headers -State $read -Live $Fixture.Live
            $Fixture.State = $read
        }
        try {
            foreach ($kind in @('copilot', 'claude', 'codex')) {
                $fixture = New-RestorationFixture -Kind $kind
                Confirm-LifecycleStop -State $fixture.State
                Invoke-PendingStops -Headers $headers -State $fixture.State -Live $fixture.Live
                Test-That "the real $kind failed-stop producer records its error and consumed press" {
                    $fixture.State[$fixture.Id].Status -ceq 'error' -and
                    $fixture.State[$fixture.Id].LastStopAt -ceq $script:RestorePress
                }
                Test-That "a $kind failed stop survives write read full restore and actual publication" {
                    Invoke-RestorationRoundTrip -Fixture $fixture
                    $topic = (Get-CopilotMqttTopics -SessionId $fixture.Id).StatusState
                    $published = @($script:RestorePublished | Where-Object Topic -CEQ $topic)
                    $fixture.State[$fixture.Id].Status -ceq 'error' -and $published[-1].Payload -ceq 'error'
                }
                Test-That "the restored $kind error summary does not replay stale normal activity" {
                    $topic = (Get-CopilotMqttTopics -SessionId $fixture.Id).ActivityState
                    @($script:RestorePublished | Where-Object Topic -CEQ $topic)[-1].Payload -ceq 'Could not end session'
                }
                # Start from the actual persisted failure again even on the red baseline.
                $fixture.State[$fixture.Id].Status = 'error'
                if ($kind -eq 'claude') {
                    $fixture.State[$fixture.Id].PSObject.Properties.Remove('HookStatusAt')
                    [void](Sync-DaemonHookStatus -SessionId $fixture.Id -Entry $fixture.State[$fixture.Id] `
                        -Session $fixture.Session -Headers $headers)
                    Test-That 'a stale Claude hook first seen after restart cannot erase the failed stop' {
                        $fixture.State[$fixture.Id].Status -ceq 'error'
                    }
                    foreach ($nativeStatus in @('working', 'waiting', 'idle')) {
                        $fixture.State[$fixture.Id].Status = 'error'
                        $fixture.Session.HookStatus = $nativeStatus
                        $fixture.Session.HookStatusAt = [DateTimeOffset]::Parse($fixture.Session.HookStatusAt).AddMinutes(2).ToString('o')
                        Test-That "a newer Claude $nativeStatus hook recovers normally through restore" {
                            Invoke-RestorationRoundTrip -Fixture $fixture
                            $fixture.State[$fixture.Id].Status -ceq $nativeStatus
                        }
                    }
                }
                elseif ($kind -eq 'codex') {
                    $script:DaemonRegistrationStamps = @{}
                    [void](Sync-DaemonCodexHookStatus -Id $fixture.Id -Entry $fixture.State[$fixture.Id] -Headers $headers)
                    Test-That 'a stale Codex registration first seen after restart cannot erase the failed stop' {
                        $fixture.State[$fixture.Id].Status -ceq 'error'
                    }
                    $minute = 1
                    foreach ($nativeStatus in @('working', 'idle')) {
                        $fixture.State[$fixture.Id].Status = 'error'
                        Set-RestorationCodexRegistration -SessionId $fixture.Id -Status $nativeStatus `
                            -At ([DateTimeOffset]::Parse($script:RestorePress).AddMinutes($minute).ToString('o')) -Transcript $fixture.Transcript
                        $fixture.Session.Status = $nativeStatus
                        [void](Sync-DaemonCodexHookStatus -Id $fixture.Id -Entry $fixture.State[$fixture.Id] -Headers $headers)
                        Test-That "a newer Codex $nativeStatus registration recovers and restores normally" {
                            Invoke-RestorationRoundTrip -Fixture $fixture
                            $fixture.State[$fixture.Id].Status -ceq $nativeStatus
                        }
                        $minute++
                    }
                }
                else {
                    Add-Content -LiteralPath $fixture.Transcript -Encoding utf8 -Value @(
                        '{"type":"user.message","timestamp":"2026-09-30T17:01:00-07:00","data":{"content":"Synthetic newer prompt"}}'
                        '{"type":"assistant.turn_start","timestamp":"2026-09-30T17:01:00-07:00"}'
                    )
                    Test-That 'newer Copilot transcript activity recovers through the unchanged full restore path' {
                        Invoke-RestorationRoundTrip -Fixture $fixture
                        $fixture.State[$fixture.Id].Status -ceq 'working'
                    }
                    Add-Content -LiteralPath $fixture.Transcript -Encoding utf8 -Value '{"type":"assistant.turn_end","timestamp":"2026-09-30T17:02:00-07:00"}'
                    Test-That 'a recovered Copilot turn can end idle without resurrecting the old stop error' {
                        Invoke-RestorationRoundTrip -Fixture $fixture
                        $fixture.State[$fixture.Id].Status -ceq 'idle'
                    }
                }
                Test-That "another $kind restart does not resurrect an already recovered stop error" {
                    Invoke-RestorationRoundTrip -Fixture $fixture
                    $fixture.State[$fixture.Id].Status -ceq 'idle'
                }
                $fixture.State[$fixture.Id].Status = 'error'
                $fixture.Live = @{}
                Test-That "a retired $kind failed-stop session is still removed by the unchanged reconcile" {
                    Invoke-RestorationRoundTrip -Fixture $fixture
                    -not $fixture.State.ContainsKey($fixture.Id)
                }
            }

            Write-Host '--- persisted subsecond stop and native timestamp boundaries ---'
            $precisionStop = [DateTimeOffset]::Parse('2026-09-30T17:00:00.900-07:00')
            function Get-PrecisionInput {
                param([DateTimeOffset]$Instant, [string]$Representation)
                switch ($Representation) {
                    'offset-text' { $Instant.ToOffset([TimeSpan]::FromHours(-7)).ToString('o') }
                    'utc-text' { $Instant.UtcDateTime.ToString('o') }
                    'offset-object' { $Instant.ToOffset([TimeSpan]::FromHours(-7)) }
                    'utc-datetime' { $Instant.UtcDateTime }
                    'local-datetime' { $Instant.LocalDateTime }
                    default { throw "Unknown precision fixture representation: $Representation" }
                }
            }
            foreach ($representation in @('offset-text', 'utc-text', 'offset-object', 'utc-datetime', 'local-datetime')) {
                $exact = $precisionStop.AddTicks(7)
                $value = Get-PrecisionInput -Instant $exact -Representation $representation
                Test-That "the failed-stop consumer preserves every tick of a $representation value" {
                    $entry = [pscustomobject]@{ Status = 'error'; LastStopAt = $value }
                    $actual = Get-DaemonFailedStopRequestTime -Entry $entry
                    $actual -is [DateTimeOffset] -and $actual.UtcTicks -eq $exact.UtcTicks
                }
            }

            $precisionCases = @(
                @{ Label = 'older'; At = $precisionStop.AddMilliseconds(-100); Expected = 'error'; HookStatus = 'idle' }
                @{ Label = 'equal'; At = $precisionStop; Expected = 'error'; HookStatus = 'idle' }
                @{ Label = 'one-tick-newer'; At = $precisionStop.AddTicks(1); Expected = 'working'; HookStatus = 'working' }
                @{ Label = 'newer'; At = $precisionStop.AddMilliseconds(50); Expected = 'working'; HookStatus = 'working' }
            )
            foreach ($stopRepresentation in @('offset-text', 'utc-text')) {
                $script:RestorePress = Get-PrecisionInput -Instant $precisionStop -Representation $stopRepresentation
                foreach ($hookRepresentation in @('offset-text', 'utc-text', 'offset-object', 'utc-datetime', 'local-datetime', 'persisted')) {
                    foreach ($timestampCase in $precisionCases) {
                        $fixture = New-RestorationFixture -Kind claude
                        Confirm-LifecycleStop -State $fixture.State
                        Invoke-PendingStops -Headers $headers -State $fixture.State -Live $fixture.Live
                        if ($hookRepresentation -eq 'persisted') {
                            $fixture.State[$fixture.Id] | Add-Member NativeHookTimeFixture ($timestampCase.At.ToString('o'))
                        }
                        Write-DaemonState -State $fixture.State
                        $fixture.State = Read-DaemonState
                        $entry = $fixture.State[$fixture.Id]
                        $fixture.Session.HookStatus = $timestampCase.HookStatus
                        $fixture.Session.HookStatusAt = if ($hookRepresentation -eq 'persisted') {
                            $entry.NativeHookTimeFixture
                        }
                        else { Get-PrecisionInput -Instant $timestampCase.At -Representation $hookRepresentation }
                        Test-That "persisted $stopRepresentation stop handles $($timestampCase.Label) same-second Claude $hookRepresentation precisely" {
                            $savedStop = Get-DaemonFailedStopRequestTime -Entry $entry
                            $observed = Sync-DaemonHookStatus -SessionId $fixture.Id -Entry $entry -Session $fixture.Session -Headers $headers
                            $entry.LastStopAt -is [datetime] -and
                            $savedStop.UtcTicks -eq $precisionStop.UtcTicks -and
                            $observed.UtcTicks -eq $timestampCase.At.UtcTicks -and
                            $entry.Status -ceq $timestampCase.Expected
                        }
                    }
                }
                foreach ($registrationRepresentation in @('offset-text', 'utc-text')) {
                    foreach ($timestampCase in $precisionCases) {
                        $fixture = New-RestorationFixture -Kind codex
                        Confirm-LifecycleStop -State $fixture.State
                        Invoke-PendingStops -Headers $headers -State $fixture.State -Live $fixture.Live
                        Write-DaemonState -State $fixture.State
                        $fixture.State = Read-DaemonState
                        $registeredAt = Get-PrecisionInput -Instant $timestampCase.At -Representation $registrationRepresentation
                        Set-RestorationCodexRegistration -SessionId $fixture.Id -Status $timestampCase.HookStatus `
                            -At $registeredAt -Transcript $fixture.Transcript
                        $script:DaemonRegistrationStamps = @{}
                        Test-That "persisted $stopRepresentation stop handles $($timestampCase.Label) same-second Codex $registrationRepresentation precisely" {
                            $savedStop = Get-DaemonFailedStopRequestTime -Entry $fixture.State[$fixture.Id]
                            $changed = Sync-DaemonCodexHookStatus -Id $fixture.Id -Entry $fixture.State[$fixture.Id] -Headers $headers
                            $savedStop.UtcTicks -eq $precisionStop.UtcTicks -and
                            $fixture.State[$fixture.Id].Status -ceq $timestampCase.Expected -and
                            $changed -eq ($timestampCase.Expected -eq 'working')
                        }
                    }
                }
            }

            foreach ($hookRepresentation in @('offset-object', 'utc-datetime', 'local-datetime', 'utc-text')) {
                $fixture = New-RestorationFixture -Kind claude
                $entry = $fixture.State[$fixture.Id]
                $entry.Status = 'idle'
                $entry.HookStatusAt = $precisionStop.AddMilliseconds(-100).ToString('o')
                Write-DaemonState -State $fixture.State
                $fixture.State = Read-DaemonState
                $entry = $fixture.State[$fixture.Id]
                $next = $precisionStop.AddMilliseconds(50).AddTicks(7)
                $fixture.Session.HookStatus = 'working'
                $fixture.Session.HookStatusAt = Get-PrecisionInput -Instant $next -Representation $hookRepresentation
                Test-That "a persisted seen timestamp does not hide a newer same-second $hookRepresentation hook" {
                    $observed = Sync-DaemonHookStatus -SessionId $fixture.Id -Entry $entry -Session $fixture.Session -Headers $headers
                    $entry.Status -ceq 'working' -and $observed.UtcTicks -eq $next.UtcTicks
                }
                Test-That "adopting $hookRepresentation preserves precise hook time through a second real state round-trip" {
                    Write-DaemonState -State $fixture.State
                    $fixture.State = Read-DaemonState
                    $saved = $fixture.State[$fixture.Id].HookStatusAt
                    $saved -is [datetime] -and $saved.ToUniversalTime().Ticks -eq $next.UtcTicks
                }
                $entry = $fixture.State[$fixture.Id]
                # Later transcript work can change status without changing the last hook.
                $entry.Status = 'idle'
                $fixture.Session.HookStatusAt = $next.ToOffset([TimeSpan]::FromHours(2)).ToString('o')
                Test-That "an equivalent offset timestamp cannot replay an already seen $hookRepresentation hook" {
                    [void](Sync-DaemonHookStatus -SessionId $fixture.Id -Entry $entry -Session $fixture.Session -Headers $headers)
                    $entry.Status -ceq 'idle'
                }
                $fixture.Session.HookStatusAt = $next.AddTicks(1).UtcDateTime
                Test-That "a truly newer tick still recovers after the $hookRepresentation duplicate is rejected" {
                    [void](Sync-DaemonHookStatus -SessionId $fixture.Id -Entry $entry -Session $fixture.Session -Headers $headers)
                    $entry.Status -ceq 'working'
                }
            }

            foreach ($savedSummary in @('', 'Working', 'Earlier native activity')) {
                Test-That "error priming has a truthful label instead of the saved summary '$savedSummary'" {
                    $entry = [pscustomobject]@{ Name = 'Synthetic'; Machine = 'TEST'; LastSummary = $savedSummary; LastResponse = 'Retained response' }
                    $card = Resolve-DaemonPrimedCard -Entry $entry -Status error -VerboseOn $false
                    $card.Summary -ceq 'Could not end session' -and $card.Detail.response -ceq 'Retained response'
                }
            }
            foreach ($savedStatus in @('idle', 'working', 'waiting', 'ending', 'ended', 'nonsense', 'error')) {
                $fixture = New-RestorationFixture -Kind copilot
                $fixture.State[$fixture.Id].Status = $savedStatus
                Test-That "startup does not stick to an unrelated saved '$savedStatus' status without a failed stop" {
                    (Get-DaemonStartupStatus -Session $fixture.Session -Entry $fixture.State[$fixture.Id]) -ceq 'working'
                }
            }
            $fixture = New-RestorationFixture -Kind copilot
            $fixture.State[$fixture.Id].Status = 'error'
            $fixture.State[$fixture.Id] | Add-Member LastStopAt 'not-a-time'
            Test-That 'an invalid saved stop timestamp does not create a sticky error status' {
                (Get-DaemonStartupStatus -Session $fixture.Session -Entry $fixture.State[$fixture.Id]) -ceq 'working'
            }
            $empty = @{ State = @{}; Live = @{} }
            Test-That 'startup with no saved or live sessions still restores nothing' {
                Invoke-RestorationRoundTrip -Fixture $empty
                $empty.State.Count -eq 0
            }
        }
        finally { $script:DaemonConfig.StateFile = $previousStateFile }
    }

    & {
        Write-Host '--- real stop producer, publisher validation and existing renderer ---'
        $sid = '50000000-0000-4000-8000-000000000005'
        $script:StatusMessages = [Collections.Generic.List[object]]::new()
        $script:StopDiagnostics = [Collections.Generic.List[string]]::new()
        $script:StatusContractStates = @()
        $script:StatusPublishFails = $false
        function Publish-CopilotMqttMessage {
            param($Topic, $Payload, $Headers, [switch]$Retain)
            if ($script:StatusPublishFails) { throw 'Synthetic status outage.' }
            $script:StatusMessages.Add([pscustomobject]@{ Topic = $Topic; Payload = $Payload })
        }
        function Get-DaemonEntityState { param($EntityId, $Headers) [pscustomobject]@{ state = '2026-09-30T16:00:00-07:00' } }
        function Add-DaemonTuningAttributes { param($Attributes, $Tuning) $Attributes }
        function Set-DaemonTransientActivity { param($SessionId, $Summary, $Extra, $Headers) $script:StopActivity = $Summary }
        function Write-DaemonLog { param($Message) $script:StopDiagnostics.Add([string]$Message) }
        function Stop-BridgeCopilotSession {
            param($SessionId, $ProcessId)
            $script:StopCalls++
            [pscustomobject]@{ Stopped = $script:StopSucceeds; Detail = 'Synthetic stop outcome' }
        }
        foreach ($stopped in @($true, $false)) {
            $script:StopSucceeds = $stopped
            $script:StopCalls = 0
            $script:StopActivity = ''
            $script:StatusMessages.Clear()
            $script:DaemonStartedAt = [DateTimeOffset]::Parse('2026-09-30T15:00:00-07:00')
            $script:DaemonLaunchedPids = @{}
            $script:DaemonReconcileNow = $false
            $state = @{ $sid = [pscustomobject]@{ Name = 'Synthetic'; Machine = 'TEST'; Status = 'working' } }
            $live = @{ $sid = [pscustomobject]@{ ProcessId = 0 } }
            Confirm-LifecycleStop -State $state
            Invoke-PendingStops -Headers $headers -State $state -Live $live
            $outcome = if ($stopped) { 'ended' } else { 'error' }
            $statusTopic = (Get-CopilotMqttTopics -SessionId $sid).StatusState
            $statuses = @($script:StatusMessages | Where-Object { $_.Topic -ceq $statusTopic } | ForEach-Object Payload)
            $script:StatusContractStates += $statuses
            Test-That "the real producer and publisher report ending then $outcome" {
                ($statuses -join ',') -ceq "ending,$outcome" -and $state[$sid].Status -ceq $outcome -and
                $script:DaemonReconcileNow -eq $stopped
            }
            Invoke-PendingStops -Headers $headers -State $state -Live $live
            Test-That "the $outcome status path keeps the existing one-press contract" { $script:StopCalls -eq 1 }
            $script:StatusPublishFails = $true
            $script:StopDiagnostics.Clear()
            $script:StopCalls = 0
            $state[$sid] = [pscustomobject]@{ Name = 'Synthetic'; Machine = 'TEST'; Status = 'working' }
            Confirm-LifecycleStop -State $state
            Invoke-PendingStops -Headers $headers -State $state -Live $live
            Test-That "a publication outage preserves and diagnoses the local $outcome outcome" {
                $state[$sid].Status -ceq $outcome -and $script:StopCalls -eq 1 -and
                ($script:StopDiagnostics -join ' ') -match 'status publish failed' -and
                ($stopped -or $script:StopActivity -ceq 'Could not end session')
            }
            $script:StatusPublishFails = $false
        }
        # The guard, against the same real publisher. A first press on a working
        # session must publish nothing at all: an 'ending' that goes out and is never
        # followed by 'ended' leaves the card claiming the session is closing while it
        # quietly carries on working.
        $script:StopCalls = 0
        $script:StopActivity = ''
        $script:StatusMessages.Clear()
        $script:DaemonStopArmed = @{}
        $state = @{ $sid = [pscustomobject]@{ Name = 'Synthetic'; Machine = 'TEST'; Status = 'working' } }
        Invoke-PendingStops -Headers $headers -State $state -Live $live
        Test-That 'an unconfirmed press publishes no status and stops nothing' {
            $statusTopic = (Get-CopilotMqttTopics -SessionId $sid).StatusState
            @($script:StatusMessages | Where-Object { $_.Topic -ceq $statusTopic }).Count -eq 0 -and
            $script:StopCalls -eq 0 -and $state[$sid].Status -ceq 'working'
        }
        Test-That 'and the card asks for the second press instead' {
            $script:StopActivity -ceq $script:CopilotEndSessionConfirmNote
        }
        Test-That 'the real publisher retains existing vocabulary and accepts terminal outcomes' {
            foreach ($status in @('working', 'idle', 'waiting', 'offline', 'ending', 'ended', 'error')) {
                Set-CopilotMqttStatus -SessionId $sid -Status $status -Headers $headers
            }
            $true
        }
        Test-That 'the real publisher still rejects unknown status vocabulary' {
            $rejected = $false
            try { Set-CopilotMqttStatus -SessionId $sid -Status 'made-up-state' -Headers $headers }
            catch [System.Management.Automation.ParameterBindingException] { $rejected = $true }
            $rejected
        }
        Test-That 'the existing activity renderer displays the actual emitted status sequence' {
            $driver = @'
const fs = require('fs');
const vm = require('vm');
const { loadCards, FakeElement } = require(process.argv[1]);
const { sandbox } = loadCards();
class Element extends FakeElement {
  append(...children) {
    for (let child of children) {
      if (typeof child === 'string') {
        const text = new Element('span');
        text.textContent = child;
        child = text;
      }
      this.appendChild(child);
    }
  }
}
sandbox.document.createElement = tag => new Element(tag);
const Card = vm.runInContext('AgentBridgeActivityCard', sandbox);
const job = JSON.parse(fs.readFileSync(0, 'utf8'));
const rendered = job.states.map(state => {
  const card = Object.create(Card.prototype);
  card._last = {};
  card._els = {};
  for (const key of ['title', 'meta', 'question', 'q', 'response', 'working', 'verb', 'elapsed', 'reasoning', 'r', 'history', 'list']) {
    card._els[key] = new Element('div');
  }
  card.setConfig({ name: 'Synthetic', machine: 'TEST', status: 'sensor.status', activity: 'sensor.activity' });
  card._hass = { states: { 'sensor.status': { state, attributes: {} } } };
  card._render();
  return {
    state: card._els.meta.children.find(child => child.tagName === 'B').textContent,
    working: !card._els.working.hidden,
    title: card._els.title.textContent
  };
});
process.stdout.write(JSON.stringify(rendered));
'@
            $job = @{ states = $script:StatusContractStates } | ConvertTo-Json -Compress
            $rendered = $job | & node -e $driver (Join-Path $repo 'frontend\test\card-harness.js')
            if ($LASTEXITCODE) { throw 'The actual activity renderer failed.' }
            $rows = @($rendered | ConvertFrom-Json)
            ($rows.state -join ',') -ceq 'ending,ended,ending,error' -and
            @($rows | Where-Object working).Count -eq 0 -and
            @($rows | Where-Object { $_.title -notmatch 'Synthetic' }).Count -eq 0
        }
    }
}
finally { Remove-Item -LiteralPath $root -Recurse -Force }

if ($script:Failures) { Write-Host "$($script:Failures) lifecycle check(s) failed"; exit 1 }
Write-Host 'All decision lifecycle checks passed'
exit 0
