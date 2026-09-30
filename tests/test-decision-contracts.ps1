#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'hooks\decision-bridge-common.ps1')
. (Join-Path $repo 'hooks\decision-mqtt.ps1')
. (Join-Path $repo 'hooks\copilot-hooks.ps1')
. (Join-Path $repo 'hooks\daemon-agents.ps1')
. (Join-Path $repo 'hooks\daemon-decisions.ps1')
. (Join-Path $repo 'hooks\decision-inject.ps1')
. (Join-Path $repo 'hooks\daemon-launch.ps1')
. (Join-Path $repo 'codex\hooks\codex-session.ps1')
. (Join-Path $repo 'codex\hooks\codex-hooks.ps1')
. (Join-Path $repo 'claude\hooks\claude-ask-parser.ps1')
. (Join-Path $repo 'claude\hooks\claude-transcript.ps1')
. (Join-Path $repo 'claude\hooks\claude-hooks.ps1')

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check)
    try {
        if (-not (& $Check)) { throw 'assertion was false' }
        Write-Host "  PASS  $Name"
    }
    catch {
        Write-Host "  FAIL  $Name - $($_.Exception.Message)"
        $script:Failures++
    }
}

$root = Join-Path $env:TEMP ('decision-contracts-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$script:DecisionBridgeConfig.SessionStateRoot = Join-Path $root 'sessions'
$script:DecisionBridgeConfig.LogFile = Join-Path $root 'bridge.log'
$sid = '00000000-0000-4000-8000-000000000003'
$headers = @{}
$node = Get-CopilotMqttNodeId -SessionId $sid
$script:QuestionTranscript = Join-Path $root 'question.jsonl'
$script:DaemonConfig = @{ ReplyBlankValue = ' ' }
$script:DaemonTerminalOnlyWarned = @{}
$script:DaemonLive = @{}
$script:CodexAdapterLoaded = $true
$script:ClaudeAdapterLoaded = $true
$script:HomeStates = @{}
$script:Notices = @()
$script:NativeCalls = 0
$script:ChoiceFields = @([pscustomobject]@{ Name = 'answer'; Label = 'Answer'; Options = @('No', 'Not now'); Values = @('No', 'Not now'); IsText = $false })
$state = @{ $sid = [pscustomobject]@{ Name = 'Synthetic session'; Machine = 'TEST'; Status = 'waiting'; LastReply = '' } }

# Real marker/publisher implementations; only transport and process discovery are replaced.
function Get-CodexOwningProcessId { param($SessionId, $Ancestors) 0 }
function Test-BridgeDaemonAlive { $true }
function Enter-BridgeAdapterSession { $null }
function Invoke-BridgeConsoleSend { $script:NativeCalls++; throw 'Console input is forbidden in this suite.' }
function Invoke-BridgeConsoleChoice { $script:NativeCalls++; throw 'Console input is forbidden in this suite.' }
function Get-DaemonSessionProcessId { param($SessionId) 111 }
function Write-DaemonLog { param($Message) }
function Set-DaemonTransientActivity { param($SessionId, $Summary, $Extra, $Headers) $script:Notices += $Summary }
function Start-Sleep { param($Milliseconds, $Seconds) }
function Invoke-HomeAssistantService { param($Domain, $Service, $Data, $Headers) }
function Get-HomeAssistantState {
    param($EntityId, $Headers)
    if (-not $script:HomeStates.ContainsKey($EntityId)) { throw 'Synthetic missing entity.' }
    $script:HomeStates[$EntityId]
}
$script:Published = @()
function Publish-CopilotMqttMessage {
    param($Topic, $Payload, $Headers, [switch]$Retain)
    $script:Published += [pscustomobject]@{ Topic = $Topic; Payload = $Payload }
}

function New-TestHaState {
    param([string]$Value, [string]$DecisionId, [DateTimeOffset]$ChangedAt = [DateTimeOffset]::Now)
    [pscustomobject]@{
        state = $Value; last_changed = $ChangedAt.ToString('o')
        attributes = [pscustomobject]@{ decision_id = $DecisionId; question = 'Pick' }
    }
}

function Initialize-TestQuestion {
    param([string]$DecisionId = 'generation', [string]$ToolCallId = 'native', [object[]]$Fields = $script:ChoiceFields)

    [pscustomobject]@{
        type = 'tool.execution_start'; timestamp = [DateTimeOffset]::Now.ToString('o')
        data = @{ toolName = 'ask_user'; toolCallId = $ToolCallId }
    } | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $script:QuestionTranscript -Encoding utf8
    Write-CopilotDecisionMarker -SessionId $sid -DecisionId $DecisionId -ToolCallId $ToolCallId `
        -Fields $Fields -Choices @('No', 'Not now') -Question 'Pick' -Mode multiple_choice
    $marker = Get-CopilotDecisionMarker -SessionId $sid
    $script:HomeStates = @{
        "select.${node}_decision" = New-TestHaState -Value 'No' -DecisionId $DecisionId `
            -ChangedAt ((ConvertTo-DecisionInstant $marker.armedAt).AddMilliseconds(1))
    }
    $script:DaemonLive = @{ $sid = [pscustomobject]@{ Kind = 'copilot'; Transcript = $script:QuestionTranscript; ProcessId = 111 } }
    $script:NativeCalls = 0
    $script:Notices = @()
    $marker
}

try {
    foreach ($eventName in @('PreToolUse', 'UserPromptSubmit', 'Stop', 'SessionEnd')) {
        Test-That "$eventName invalidates an old Codex approval before any early return" {
            Write-CodexApprovalMarker -SessionId $sid -DecisionId 'old' -Question 'Old approval'
            Invoke-CodexHook -HookEvent ([pscustomobject]@{
                session_id = $sid; hook_event_name = $eventName; cwd = $root
                tool_name = 'shell'; tool_use_id = 'next-tool'; tool_input = [pscustomobject]@{}
            })
            $null -eq (Get-CodexApprovalMarker -SessionId $sid)
        }
    }

    Test-That 'a Codex approval is persisted during an outage' {
        [void](Remove-CodexApprovalMarker -SessionId $sid)
        Invoke-CodexHook -HookEvent ([pscustomobject]@{
            session_id = $sid; hook_event_name = 'PermissionRequest'; cwd = $root
            tool_name = 'shell'; tool_use_id = 'approval-tool'; tool_input = [pscustomobject]@{}
        })
        $null -ne (Get-CodexApprovalMarker -SessionId $sid)
    }
    Test-That 'Codex invalidates locally even if later registration fails' {
        Write-CodexApprovalMarker -SessionId $sid -DecisionId 'old' -Question 'Old'
        function Write-CodexSessionRegistration { throw 'Synthetic registration failure.' }
        try {
            Invoke-CodexHook -HookEvent ([pscustomobject]@{ session_id = $sid; hook_event_name = 'PreToolUse'; cwd = $root; tool_name = 'shell' })
        }
        catch { }
        $null -eq (Get-CodexApprovalMarker -SessionId $sid)
    }

    # Native-ID-bearing Copilot events below are synthetic contract tests, not proof
    # that the current documented PreToolUse input exposes such an ID.
    Test-That 'a synthetic identified Copilot request is persisted before an outage' {
        & {
            Set-StrictMode -Off
            Invoke-CopilotAskUserHook -HookEvent ([pscustomobject]@{
                sessionId = $sid; cwd = $root; timestamp = '2026-09-30T09:00:00-07:00'
                toolCallId = 'current-tool'
                toolArgs = [pscustomobject]@{ question = 'Pick'; choices = @('No', 'Not now') }
            })
        }
        $marker = Get-CopilotDecisionMarker -SessionId $sid
        $null -ne $marker -and $marker.toolCallId -ceq 'current-tool'
    }
    Test-That 'Copilot leaves the marker intact when network setup throws' {
        function Enter-BridgeAdapterSession { throw 'Synthetic outage.' }
        try {
            Invoke-CopilotAskUserHook -HookEvent ([pscustomobject]@{
                sessionId = $sid; cwd = $root; tool_use_id = 'synthetic-alias-id'
                tool_input = '{"question":"Alias shape","choices":["No","Not now"]}'
            })
        }
        catch { }
        $marker = Get-CopilotDecisionMarker -SessionId $sid
        $marker.toolCallId -ceq 'synthetic-alias-id' -and -not $marker.terminalOnly
    }
    Test-That 'same-timestamp requests get different generations' {
        $event = [pscustomobject]@{ sessionId = $sid; cwd = $root; timestamp = 1; toolCallId = 'one'; toolArgs = '{"question":"Pick","choices":["A","B"]}' }
        Invoke-CopilotAskUserHook -HookEvent $event
        $first = (Get-CopilotDecisionMarker -SessionId $sid).decisionId
        $event.toolCallId = 'two'
        Invoke-CopilotAskUserHook -HookEvent $event
        $first -cne (Get-CopilotDecisionMarker -SessionId $sid).decisionId
    }
    Test-That 'replaying a Copilot hook cannot re-arm a consumed native request' {
        $m = Initialize-TestQuestion
        [void](Set-CopilotDecisionMarkerInjected -SessionId $sid -DecisionId $m.decisionId -Answer 'No' -Selections @('No'))
        Invoke-CopilotAskUserHook -HookEvent ([pscustomobject]@{
            sessionId = $sid; cwd = $root; toolCallId = $m.toolCallId
            toolArgs = '{"question":"Pick","choices":["No","Not now"]}'
        })
        $saved = Get-CopilotDecisionMarker -SessionId $sid
        $saved.decisionId -ceq $m.decisionId -and $saved.deliveryAttempted
    }
    Test-That 'replaying a Claude hook preserves the same consumed generation' {
        $m = Initialize-TestQuestion -ToolCallId 'claude-native'
        [void](Set-CopilotDecisionMarkerInjected -SessionId $sid -DecisionId $m.decisionId -Answer 'No' -Selections @('No'))
        Invoke-ClaudeAskHook -HookEvent ([pscustomobject]@{ session_id = $sid; tool_name = 'AskUserQuestion'; tool_use_id = 'claude-native' })
        $saved = Get-CopilotDecisionMarker -SessionId $sid
        $saved.decisionId -ceq $m.decisionId -and $saved.deliveryAttempted
    }
    Test-That 'replaying a Codex permission hook preserves its one-shot claim' {
        Write-CodexApprovalMarker -SessionId $sid -DecisionId 'codex-replay' -ToolCallId 'codex-native' -Question 'Synthetic'
        [void](Set-CodexApprovalMarkerAttempted -SessionId $sid -DecisionId 'codex-replay' -Answer Deny)
        Invoke-CodexHook -HookEvent ([pscustomobject]@{
            session_id = $sid; hook_event_name = 'PermissionRequest'; tool_use_id = 'codex-native'; tool_name = 'shell'; cwd = $root
        })
        $saved = Get-CodexApprovalMarker -SessionId $sid
        $saved.DecisionId -ceq 'codex-replay' -and $saved.DeliveryAttempted
    }
    Test-That 'the documented current Copilot payload is terminal-only without native identity' {
        # github/copilot-sdk 4dc774c91aff609c338563aadc699d5c2dc596f7:
        # docs/hooks/pre-tool-use.md lists no native toolCallId.
        Invoke-CopilotAskUserHook -HookEvent ([pscustomobject]@{
            sessionId = $sid; timestamp = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
            cwd = $root; toolName = 'ask_user'
            toolArgs = [pscustomobject]@{
                message = 'Pick'
                requestedSchema = [pscustomobject]@{
                    type = 'object'
                    properties = [pscustomobject]@{ answer = [pscustomobject]@{ type = 'string'; enum = @('A','B') } }
                }
            }
        })
        $marker = Get-CopilotDecisionMarker -SessionId $sid
        $script:NativeCalls = 0
        Invoke-PendingDecisions -Headers $headers -State $state -Live $script:DaemonLive
        $marker.terminalOnly -and $marker.toolCallId -ceq '' -and
        $marker.question -match 'did not identify' -and $script:NativeCalls -eq 0
    }

    $transcript = Join-Path $root 'events.jsonl'
    @(
        '{"type":"tool.execution_start","timestamp":"2026-09-30T09:00:00-07:00","data":{"toolName":"ask_user","toolCallId":"old"}}'
        '{"type":"tool.execution_complete","timestamp":"2026-09-30T09:00:01-07:00","data":{"toolCallId":"old","result":{"content":"No"}}}'
    ) | Set-Content -LiteralPath $transcript -Encoding utf8
    Test-That 'a new hook before its start does not inherit the previous answer' {
        $s = Get-CopilotAskUserState -TranscriptPath $transcript -ToolCallId 'new'
        -not $s.Started
    }
    Add-Content -LiteralPath $transcript -Encoding utf8 -Value @(
        '{"type":"tool.execution_start","timestamp":"2026-09-30T09:00:02-07:00","data":{"toolName":"ask_user","toolCallId":"new"}}'
        '{"type":"tool.execution_start","timestamp":"2026-09-30T09:00:03-07:00","data":{"toolName":"ask_user","toolCallId":"overlap"}}'
    )
    Test-That 'the reader checks a named request rather than the latest question' {
        $s = Get-CopilotAskUserState -TranscriptPath $transcript -ToolCallId 'old'
        $s.Started -and -not $s.Pending -and $s.ToolCallId -ceq 'old'
    }
    Test-That 'overlapping native requests are not a uniquely actionable UI' {
        $s = Get-CopilotAskUserState -TranscriptPath $transcript -ToolCallId 'new'
        $s.Started -and $s.Pending -and -not $s.CanAnswer
    }
    Test-That 'request identity comparison is case-sensitive' {
        -not (Get-CopilotAskUserState -TranscriptPath $transcript -ToolCallId 'OLD').Started
    }
    Test-That 'a duplicate native request id is ambiguous, not replayable' {
        $m = Initialize-TestQuestion
        $line = Get-Content -LiteralPath $script:QuestionTranscript -Raw
        Add-Content -LiteralPath $script:QuestionTranscript -Value $line
        -not (Get-CopilotAskUserState -TranscriptPath $script:QuestionTranscript -ToolCallId $m.toolCallId).CanAnswer
    }
    Test-That 'a terminal answer wins before dashboard input is read' {
        $null = Initialize-TestQuestion
        Add-Content -LiteralPath $script:QuestionTranscript -Value '{"type":"tool.execution_complete","data":{"toolCallId":"native","result":{"content":"User responded: answer=Not now"}}}'
        Invoke-PendingDecisions -Headers $headers -State $state -Live $script:DaemonLive
        $script:NativeCalls -eq 0 -and $null -eq (Get-CopilotDecisionMarker -SessionId $sid)
    }
    Test-That 'a terminal answer arriving during the dashboard read prevents injection' {
        $null = Initialize-TestQuestion
        $script:RaceWritten = $false
        function Get-HomeAssistantState {
            param($EntityId, $Headers)
            if (-not $script:RaceWritten) {
                $script:RaceWritten = $true
                Add-Content -LiteralPath $script:QuestionTranscript -Value '{"type":"tool.execution_complete","data":{"toolCallId":"native","result":{"content":"User responded: answer=Not now"}}}'
            }
            $script:HomeStates[$EntityId]
        }
        Invoke-PendingDecisions -Headers $headers -State $state -Live $script:DaemonLive
        $script:NativeCalls -eq 0
    }
    Test-That 'a replacement generation arriving during a read cannot receive the old answer' {
        $null = Initialize-TestQuestion
        function Get-HomeAssistantState {
            param($EntityId, $Headers)
            Write-CopilotDecisionMarker -SessionId $sid -DecisionId 'replacement' -ToolCallId 'replacement-tool' -Question 'Next' -Mode freeform
            $script:HomeStates[$EntityId]
        }
        Invoke-PendingDecisions -Headers $headers -State $state -Live $script:DaemonLive
        $script:NativeCalls -eq 0 -and (Get-CopilotDecisionMarker -SessionId $sid).decisionId -ceq 'replacement'
    }
    Test-That 'a request for a different native tool is not an ask_user authorization' {
        $m = Initialize-TestQuestion
        $m.toolName = 'another_tool'
        -not (Get-DaemonAskUserState -Session $script:DaemonLive[$sid] -Marker $m).CanAnswer
    }
    Test-That 'old completion and delivery callbacks cannot mutate a newer marker' {
        $old = Initialize-TestQuestion -DecisionId 'old-generation'
        Write-CopilotDecisionMarker -SessionId $sid -DecisionId 'new-generation' -ToolCallId 'new-tool' -Question 'New' -Mode freeform
        $sent = Set-CopilotDecisionMarkerInjected -SessionId $sid -DecisionId $old.decisionId -Answer 'No'
        $removed = Remove-CopilotDecisionMarker -SessionId $sid -DecisionId $old.decisionId -PassThru
        -not $sent -and -not $removed -and (Get-CopilotDecisionMarker -SessionId $sid).decisionId -ceq 'new-generation'
    }
    Test-That 'completion revokes locally before a clearing outage' {
        $m = Initialize-TestQuestion
        $script:RevokedBeforeIo = $false
        function Get-HomeAssistantState {
            param($EntityId, $Headers)
            $script:RevokedBeforeIo = $null -eq (Get-CopilotDecisionMarker -SessionId $sid)
            throw 'Synthetic outage.'
        }
        Complete-DaemonAnsweredDecision -SessionId $sid -Marker $m -AskState ([pscustomobject]@{ ResultContent = '' }) -State $state -Headers $headers
        $script:RevokedBeforeIo
    }
    Test-That 'marker recovery propagates the safe runner network boundary' {
        $m = Initialize-TestQuestion
        function Get-HomeAssistantState {
            param($EntityId, $Headers)
            $error = [InvalidOperationException]::new('Synthetic offline boundary.')
            $error.Data['BridgeTestNetworkBlocked'] = $true
            throw $error
        }
        $blocked = $false
        try { Confirm-DaemonDecisionArmed -SessionId $sid -Marker $m -State $state -Headers $headers }
        catch { $blocked = $_.Exception.Data['BridgeTestNetworkBlocked'] -eq $true }
        $blocked
    }
    Test-That 'a card from a previous generation cannot supply a choice' {
        $m = Initialize-TestQuestion
        $script:HomeStates["select.${node}_decision"].attributes.decision_id = 'old-generation'
        $null -eq (Read-DaemonDecisionAnswer -SessionId $sid -Marker $m -State $state -Headers $headers)
    }
    Test-That 'a retained selection from before the current marker is not an answer' {
        $m = Initialize-TestQuestion
        $script:HomeStates["select.${node}_decision"].last_changed = (ConvertTo-DecisionInstant $m.armedAt).AddMilliseconds(-1).ToString('o')
        (Read-DaemonDecisionAnswer -SessionId $sid -Marker $m -State $state -Headers $headers).Answer -eq ''
    }
    Test-That 'timestamp checks preserve subsecond precision across a JSON round trip' {
        $m = '{"armedAt":"2026-09-30T09:00:00.900-07:00"}' | ConvertFrom-Json
        $s = New-TestHaState -Value 'No' -DecisionId 'd' -ChangedAt ([DateTimeOffset]'2026-09-30T09:00:00.800-07:00')
        -not (Test-DaemonDecisionSelectionTime -Selection $s -Marker $m)
    }
    Test-That 'an exact current choice remains readable' {
        $m = Initialize-TestQuestion
        (Read-DaemonDecisionAnswer -SessionId $sid -Marker $m -State $state -Headers $headers).Answer -ceq 'No'
    }
    Test-That 'a label absent from the current request is rejected' {
        $m = Initialize-TestQuestion
        $script:HomeStates["select.${node}_decision"].state = 'N*'
        (Read-DaemonDecisionAnswer -SessionId $sid -Marker $m -State $state -Headers $headers).Answer -eq ''
    }
    Test-That 'missing submit evidence never auto-submits a complete form' {
        $formFields = @($script:ChoiceFields[0], [pscustomobject]@{ Name = 'next'; Label = 'Next'; Options = @('A', 'B') })
        $m = Initialize-TestQuestion -Fields $formFields
        $script:HomeStates["select.${node}_f1"] = New-TestHaState -Value 'No'
        $script:HomeStates["select.${node}_f2"] = New-TestHaState -Value 'B'
        (Read-DaemonFormAnswer -SessionId $sid -Marker $m -State $state -Headers $headers).Answer -eq ''
    }
    Test-That 'a partial form write is persisted and never falls back or replays' {
        $m = Initialize-TestQuestion
        $script:AttemptRecorded = $false
        function Invoke-BridgeConsoleSend {
            param($ProcessId, $Text, $Submit, $DelayMs)
            $script:NativeCalls++
            $script:AttemptRecorded = (Get-CopilotDecisionMarker -SessionId $sid).deliveryAttempted
            'failed:synthetic partial write'
        }
        $null = Invoke-DaemonDecisionAnswer -SessionId $sid -Marker $m -Answer 'No' -IsChoice $true -Headers $headers
        $script:CopilotAskUserStateCache.Clear()
        $again = Get-CopilotDecisionMarker -SessionId $sid
        $null = Invoke-DaemonDecisionAnswer -SessionId $sid -Marker $again -Answer 'Not now' -IsChoice $true -Headers $headers
        $script:NativeCalls -eq 1 -and $script:AttemptRecorded -and $again.injectedSelections[0] -ceq 'No'
    }
    Test-That 'single-field selections are persisted for eventual verification' {
        $m = Initialize-TestQuestion
        function Invoke-BridgeConsoleSend { param($ProcessId, $Text, $Submit, $DelayMs) 'ok:synthetic' }
        $ok = Invoke-DaemonDecisionAnswer -SessionId $sid -Marker $m -Answer 'Not now' -IsChoice $true -Headers $headers
        $saved = Get-CopilotDecisionMarker -SessionId $sid
        $ok -and $saved.injectedSelections[0] -ceq 'Not now' -and $saved.deliveryAttempted
    }
    Test-That 'a new generation during a form write stops all remaining input and cleanup' {
        $formFields = @($script:ChoiceFields[0], [pscustomobject]@{ Name = 'next'; Label = 'Next'; Options = @('A', 'B') })
        $m = Initialize-TestQuestion -Fields $formFields
        function Invoke-BridgeConsoleSend {
            param($ProcessId, $Text, $Submit, $DelayMs)
            $script:NativeCalls++
            Write-CopilotDecisionMarker -SessionId $sid -DecisionId 'next-generation' -ToolCallId 'next-native' -Question 'Next' -Mode freeform
            'ok:synthetic first field'
        }
        $ok = Invoke-DaemonDecisionAnswer -SessionId $sid -Marker $m -Answer 'No + B' -IsChoice $true -Selections @('No','B') -Headers $headers
        $saved = Get-CopilotDecisionMarker -SessionId $sid
        -not $ok -and $script:NativeCalls -eq 1 -and $saved.decisionId -ceq 'next-generation' -and
        -not $saved.deliveryAttempted -and $script:Notices.Count -eq 0
    }

    $fields = @([pscustomobject]@{ Name = 'answer'; Label = 'Answer'; Options = @('No', 'Not now'); IsText = $false })
    Test-That 'selected No is not verified by recorded Not now' {
        -not (Test-CopilotAnswerMatchesSelections -ResultContent 'User responded: answer=Not now' -Fields $fields -Selections @('No'))
    }
    Test-That 'a missing result is unconfirmed rather than a verified answer' {
        -not (Test-CopilotAnswerMatchesSelections -ResultContent '' -Fields $fields -Selections @('No'))
    }
    Test-That 'booleans retain their JSON type' {
        $choices = @(Get-DecisionSchemaFieldChoices -Field ('{"type":"boolean"}' | ConvertFrom-Json))
        $choices[0].Value -is [bool] -and $choices[0].Value -eq $true -and $choices[1].Value -eq $false
    }
    Test-That 'array identity and defaults survive schema parsing' {
        $schema = '{"properties":{"features":{"title":"Features","type":"array","items":{"enum":["A","B"]},"default":["B"]}}}' | ConvertFrom-Json
        $f = @(Get-DecisionSchemaFields -Schema $schema)[0]
        $f.Name -ceq 'features' -and $f.MultiSelect -and $f.Type -ceq 'array' -and @($f.Default)[0] -ceq 'B'
    }
    Test-That 'typed null, false, zero and numeric-looking strings round-trip without conversion' {
        $schema = '{"properties":{"answer":{"oneOf":[{"title":"Nothing","const":null},{"title":"False","const":false},{"title":"Zero","const":0},{"title":"String one","const":"1"}]}}}' | ConvertFrom-Json
        $f = @(Get-DecisionSchemaFields -Schema $schema)
        $m = Initialize-TestQuestion -Fields $f
        $values = @($m.fields[0].Values)
        $values.Count -eq 4 -and $null -eq $values[0] -and $values[1] -is [bool] -and
        $values[1] -eq $false -and $values[2] -isnot [string] -and $values[2] -eq 0 -and $values[3] -is [string]
    }
    Test-That 'date-looking choice values stay exact strings through the hook marker and verifier' {
        Invoke-CopilotAskUserHook -HookEvent ([pscustomobject]@{
            sessionId = $sid; cwd = $root; toolCallId = 'date-choice'
            toolArgs = '{"message":"Pick a date","requestedSchema":{"properties":{"date":{"type":"string","enum":["2026-09-30T09:00:00-07:00","later"]}}}}'
        })
        $m = Get-CopilotDecisionMarker -SessionId $sid
        $m.fields[0].Values[0] -is [string] -and $m.fields[0].Values[0] -ceq '2026-09-30T09:00:00-07:00' -and
        (Get-CopilotAnswerVerification -ResultContent '{"date":"2026-09-30T09:00:00-07:00"}' -Fields $m.fields -Selections @('2026-09-30T09:00:00-07:00')) -eq 'Match'
    }
    Test-That 'empty array and false defaults remain present and typed' {
        $f = @(Get-DecisionSchemaFields -Schema ('{"properties":{"items":{"type":"array","items":{"enum":["A","B"]},"default":[]},"flag":{"type":"boolean","default":false}}}' | ConvertFrom-Json))
        $m = Initialize-TestQuestion -Fields $f
        $m.fields[0].HasDefault -and $m.fields[0].Default -is [array] -and $m.fields[0].Default.Count -eq 0 -and
        $m.fields[1].HasDefault -and $m.fields[1].Default -is [bool] -and $m.fields[1].Default -eq $false
    }
    Test-That 'schema field names distinguish identical display labels' {
        $f = @(Get-DecisionSchemaFields -Schema ('{"properties":{"left":{"type":"string","title":"Same","enum":["A","B"]},"right":{"type":"string","title":"Same","enum":["A","B"]}}}' | ConvertFrom-Json))
        $m = Initialize-TestQuestion -Fields $f
        $m.fields[0].Name -ceq 'left' -and $m.fields[1].Name -ceq 'right' -and
        $m.fields[0].OptionIds[0] -cne $m.fields[1].OptionIds[0] -and
        (Get-CopilotAnswerVerification -ResultContent '{"left":"B","right":"A"}' -Fields $m.fields -Selections @('A','B')) -eq 'Mismatch'
    }
    Test-That 'wildcard characters in a label are compared literally' {
        $f = @([pscustomobject]@{ Name = 'answer'; Label = 'Answer'; Options = @('N*','No','[No]'); IsText = $false })
        (Get-CopilotAnswerVerification -ResultContent '{"answer":"No"}' -Fields $f -Selections @('N*')) -eq 'Mismatch' -and
        (Get-CopilotAnswerVerification -ResultContent '{"answer":"[No]"}' -Fields $f -Selections @('[No]')) -eq 'Match'
    }
    Test-That 'structured scalar values are not coerced into a different JSON type' {
        $f = @(Get-DecisionSchemaFields -Schema ('{"properties":{"answer":{"type":"boolean"}}}' | ConvertFrom-Json))
        (Get-CopilotAnswerVerification -ResultContent '{"answer":false}' -Fields $f -Selections @('No')) -eq 'Match' -and
        (Get-CopilotAnswerVerification -ResultContent '{"answer":"false"}' -Fields $f -Selections @('No')) -eq 'Mismatch'
    }
    Test-That 'equivalent JSON numbers match without treating numeric strings as numbers' {
        $f = @(Get-DecisionSchemaFields -Schema ('{"properties":{"answer":{"type":"number","enum":[1.0,2.5],"enumNames":["One","Two and a half"]}}}' | ConvertFrom-Json))
        $numeric = Get-CopilotAnswerVerification -ResultContent '{"answer":1}' -Fields $f -Selections @('One')
        $textual = Get-CopilotAnswerVerification -ResultContent '{"answer":"1"}' -Fields $f -Selections @('One')
        if ($numeric -ne 'Match' -or $textual -ne 'Mismatch') {
            $value = Get-DecisionFieldOptionValue -Field $f[0] -Option 'One'
            throw "number=$numeric string=$textual valueType=$($value.GetType().FullName) key=$(ConvertTo-DecisionValueKey -Value $value)"
        }
        $true
    }
    Test-That 'multi-select verification compares the whole typed set, including extra picks' {
        $f = @(Get-DecisionSchemaFields -Schema ('{"properties":{"answer":{"type":"array","items":{"type":"integer","enum":[1,2,3],"enumNames":["One","Two","Three"]}}}}' | ConvertFrom-Json))
        (Get-CopilotAnswerVerification -ResultContent '{"answer":[2,1]}' -Fields $f -Selections @('One + Two')) -eq 'Match' -and
        (Get-CopilotAnswerVerification -ResultContent '{"answer":[1,2,3]}' -Fields $f -Selections @('One + Two')) -eq 'Mismatch' -and
        (Get-CopilotAnswerVerification -ResultContent '{"answer":[1,1]}' -Fields $f -Selections @('One + Two')) -eq 'Mismatch'
    }
    foreach ($badResult in @('', 'Unstructured prose containing No', '{"answer":"No"', '{"other":"No"}', '{"answer":"Not now","answer":"No"}')) {
        Test-That "malformed or unverifiable result is not a match: [$badResult]" {
            (Get-CopilotAnswerVerification -ResultContent $badResult -Fields $fields -Selections @('No')) -eq 'Unconfirmed'
        }
    }
    foreach ($recorded in @('User responded: answer=Not now', 'malformed result')) {
        Test-That "verification never sends a corrective instruction for [$recorded]" {
            $m = Initialize-TestQuestion
            [void](Set-CopilotDecisionMarkerInjected -SessionId $sid -DecisionId $m.decisionId -Answer 'No' -Selections @('No'))
            $m = Get-CopilotDecisionMarker -SessionId $sid
            Complete-DaemonAnsweredDecision -SessionId $sid -Marker $m -AskState ([pscustomobject]@{ ResultContent = $recorded }) -State $state -Headers $headers
            $script:NativeCalls -eq 0 -and $script:Notices.Count -eq 1 -and $null -eq (Get-CopilotDecisionMarker -SessionId $sid)
        }
    }
    foreach ($options in @(@('Same','Same'), @('No','no'), @('Cancel request','Other'), @(('x' * 247 + 'first'), ('x' * 247 + 'second')))) {
        Test-That 'ambiguous, reserved or clipped option mappings expose no actionable selector' {
            $script:Published = @()
            Set-CopilotMqttDecision -SessionId $sid -SessionName 'Synthetic' -Machine 'TEST' -Question 'Pick' `
                -Choices $options -DecisionId 'unsafe' -Headers $headers | Out-Null
            $config = ($script:Published | Where-Object Topic -Match '/decision/config$' | Select-Object -Last 1).Payload | ConvertFrom-Json
            $config.options.Count -eq 1 -and $config.options[0] -ceq 'Awaiting answer...'
        }
    }
    Test-That 'distinct long Claude labels are retained rather than clipped into a collision' {
        $a = 'x' * 650 + ' first'
        $b = 'x' * 650 + ' second'
        $p = ConvertFrom-ClaudeAskUserQuestion -ToolInput ([pscustomobject]@{ questions = @([pscustomobject]@{ question = 'Which?'; options = @($a,$b) }) })
        $p.MarkerFields[0].Options[0] -ceq $a -and $p.MarkerFields[0].Options[1] -ceq $b -and
        -not (Test-DecisionFieldsAnswerable -Fields $p.MarkerFields)
    }
    foreach ($schemaText in @('{"properties":{"a":{"type":"array","items":{"enum":["A","B"]}}}}', '{"properties":{"a":{"type":"string","enum":["A","B"],"default":"B"}}}')) {
        Test-That 'Copilot arrays and defaults never borrow unverified native key semantics' {
            $f = @(Get-DecisionSchemaFields -Schema ($schemaText | ConvertFrom-Json))
            $refused = $false
            try { $null = Get-BridgeFormPayloads -Fields $f -Selections @('B') }
            catch { $refused = $true }
            $refused
        }
    }
    Test-That 'Claude completion does not infer an extra Enter from a missing result' {
        $m = Initialize-TestQuestion
        $script:DaemonLive[$sid].Kind = 'claude'
        $script:NativeCalls = 0
        $d = [pscustomobject]@{ Delivered = $true; ProcessId = 111; Detail = 'synthetic keys written' }
        $d = Complete-DaemonClaudeAnswer -SessionId $sid -Delivery $d -Marker $m -WaitMs 0
        -not $d.Delivered -and $script:NativeCalls -eq 0 -and $d.Detail -match 'unconfirmed'
    }
    Test-That 'a Codex approval attempt is durable even if the dashboard clear fails' {
        Write-CodexApprovalMarker -SessionId $sid -DecisionId 'approval-generation' -ToolCallId 'approval-tool' -ToolName 'shell' -Question 'Synthetic approval'
        $m = Get-CodexApprovalMarker -SessionId $sid
        $script:HomeStates["select.${node}_decision"] = New-TestHaState -Value 'Deny' -DecisionId $m.DecisionId `
            -ChangedAt ((ConvertTo-DecisionInstant $m.Created).AddMilliseconds(1))
        $live = @{ $sid = [pscustomobject]@{ Kind = 'codex'; ProcessId = 111; Status = 'waiting' } }
        $script:NativeCalls = 0
        $script:ApprovalKey = ''
        function Invoke-BridgeConsoleSend { param($ProcessId, $Text, $Submit, $DelayMs) $script:NativeCalls++; $script:ApprovalKey = $Text; 'ok:synthetic' }
        function Publish-CopilotMqttMessage { param($Topic, $Payload, $Headers, [switch]$Retain) throw 'Synthetic clear outage.' }
        Invoke-PendingCodexApprovals -Headers $headers -State $state -Live $live
        Invoke-PendingCodexApprovals -Headers $headers -State $state -Live $live
        $script:NativeCalls -eq 1 -and $script:ApprovalKey -ceq 'n' -and (Get-CodexApprovalMarker -SessionId $sid).DeliveryAttempted
    }
    Test-That 'a missing Codex card is recoverable from the local approval marker' {
        Write-CodexApprovalMarker -SessionId $sid -DecisionId 'recover-approval' -ToolCallId 'native-approval' -Question 'Synthetic approval'
        $script:HomeStates = @{}
        $script:Published = @()
        $script:NativeCalls = 0
        $live = @{ $sid = [pscustomobject]@{ Kind = 'codex'; ProcessId = 111; Status = 'waiting' } }
        Invoke-PendingCodexApprovals -Headers $headers -State $state -Live $live
        $attributes = @($script:Published | Where-Object Topic -Match '/decision/attr$' | ForEach-Object { $_.Payload | ConvertFrom-Json })
        $attributes.Count -eq 1 -and $attributes[0].decision_id -ceq 'recover-approval' -and $script:NativeCalls -eq 0
    }
    Test-That 'a Codex generation replaced during the state read cannot be attempted' {
        Write-CodexApprovalMarker -SessionId $sid -DecisionId 'old-approval' -ToolCallId 'old-tool' -Question 'Old'
        $m = Get-CodexApprovalMarker -SessionId $sid
        $script:OldApprovalCard = New-TestHaState -Value 'Approve' -DecisionId $m.DecisionId `
            -ChangedAt ((ConvertTo-DecisionInstant $m.Created).AddMilliseconds(1))
        function Get-HomeAssistantState {
            param($EntityId, $Headers)
            Write-CodexApprovalMarker -SessionId $sid -DecisionId 'replacement-approval' -ToolCallId 'new-tool' -Question 'New'
            $script:OldApprovalCard
        }
        $script:NativeCalls = 0
        Invoke-PendingCodexApprovals -Headers $headers -State $state -Live @{ $sid = [pscustomobject]@{ Kind = 'codex'; ProcessId = 111; Status = 'waiting' } }
        $script:NativeCalls -eq 0 -and -not (Get-CodexApprovalMarker -SessionId $sid).DeliveryAttempted
    }
    Test-That 'revoked and stale Codex approvals never reach a subsequent prompt' {
        [void](Remove-CodexApprovalMarker -SessionId $sid)
        $script:NativeCalls = 0
        $live = @{ $sid = [pscustomobject]@{ Kind = 'codex'; ProcessId = 111; Status = 'working' } }
        Invoke-PendingCodexApprovals -Headers $headers -State $state -Live $live
        Write-CodexApprovalMarker -SessionId $sid -DecisionId 'new-approval' -ToolCallId 'next' -Question 'Next'
        Invoke-PendingCodexApprovals -Headers $headers -State $state -Live $live
        $script:NativeCalls -eq 0
    }
    Test-That 'the actual publisher accepts the ending state its caller uses' {
        $script:Published = @()
        Set-CopilotMqttStatus -SessionId $sid -Status 'ending' -Headers $headers
        @($script:Published | Where-Object { $_.Payload -ceq 'ending' }).Count -eq 1
    }
    $script:StatusContractStates = @()
    foreach ($stopped in @($true, $false)) {
        Test-That "the real stop producer publishes ending followed by its truthful outcome ($stopped)" {
            $script:Published = @()
            $script:DaemonStartedAt = [DateTimeOffset]::Now.AddMinutes(-1)
            $script:DaemonLaunchedPids = @{}
            $script:DaemonReconcileNow = $false
            function Get-DaemonEntityState { param($EntityId, $Headers) [pscustomobject]@{ state = [DateTimeOffset]::Now.ToString('o') } }
            function Add-DaemonTuningAttributes { param($Attributes, $Tuning) $Attributes }
            function Stop-BridgeCopilotSession { param($SessionId, $ProcessId) [pscustomobject]@{ Stopped = $stopped; Detail = 'synthetic outcome' } }
            $s = @{ $sid = [pscustomobject]@{ Name = 'Synthetic'; Machine = 'TEST'; Status = 'idle' } }
            Invoke-PendingStops -Headers $headers -State $s -Live @{ $sid = [pscustomobject]@{ ProcessId = 0 } }
            $outcome = if ($stopped) { 'ended' } else { 'error' }
            $statusTopic = (Get-CopilotMqttTopics -SessionId $sid).StatusState
            $statuses = @($script:Published | Where-Object { $_.Topic -ceq $statusTopic } | ForEach-Object Payload)
            $script:StatusContractStates += $statuses
            ($statuses -join ',') -ceq "ending,$outcome" -and $s[$sid].Status -ceq $outcome
        }
    }
    Test-That 'the existing activity renderer displays the real producer and publisher states' {
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
        if ($LASTEXITCODE -ne 0) { throw 'The actual activity renderer failed.' }
        $rows = @($rendered | ConvertFrom-Json)
        ($rows.state -join ',') -ceq 'ending,ended,ending,error' -and
        @($rows | Where-Object working).Count -eq 0 -and @($rows | Where-Object { $_.title -notmatch 'Synthetic' }).Count -eq 0
    }
    Test-That 'the status publisher still rejects invalid vocabulary' {
        $rejected = $false
        try { Set-CopilotMqttStatus -SessionId $sid -Status 'made-up-state' -Headers $headers }
        catch [System.Management.Automation.ParameterBindingException] {
            $rejected = $_.FullyQualifiedErrorId -like 'ParameterArgumentValidationError,*'
        }
        $rejected
    }
}
finally {
    Remove-CopilotDecisionMarker -SessionId $sid
    [void](Remove-CodexApprovalMarker -SessionId $sid)
    Remove-CodexSessionRegistration -SessionId $sid
    Remove-Item -LiteralPath $root -Recurse -Force
}

if ($script:Failures) { exit 1 }
exit 0
