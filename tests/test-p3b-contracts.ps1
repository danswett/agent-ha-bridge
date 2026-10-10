#Requires -Version 7.0
<#
.SYNOPSIS
    Lossless decisions, local-first requests and generation-bound approval attempts.
.DESCRIPTION
    Uses real schema, marker, hook and adapter helpers in the canonical Offline
    sandbox, including wrapper stdin/output, daemon recovery, decision publishers
    and fresh approval processes. HA transport, entity registration and native
    delivery are synthetic; no real client or Home Assistant runs.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'hooks\agent-bridge-daemon.ps1')

$root = Join-Path $env:TEMP ('p3b-contracts-' + [guid]::NewGuid().ToString('N'))
if (-not [IO.Path]::GetFullPath($root).StartsWith(
    $env:AGENT_HA_BRIDGE_TEST_ROOT + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase)) { throw 'P3b fixtures require the canonical test sandbox.' }
[void][IO.Directory]::CreateDirectory($root)
$script:DecisionBridgeConfig.SessionStateRoot = Join-Path $root 'copilot'
$script:DecisionBridgeConfig.LogFile = Join-Path $root 'hook.log'
$script:DaemonConfig.LogFile = Join-Path $root 'daemon.log'
$script:Failures = 0
$script:Checks = 0

function Test-That {
    param([string]$Name, [scriptblock]$Check)
    $script:Checks++
    $ok = $false
    $detail = ''
    try { $ok = [bool](& $Check) } catch { $detail = " - $($_.Exception.Message)" }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$detail"; $script:Failures++ }
}

try {
    Write-Host '--- exact selected No / recorded Not now audit reproduction ---'
    $field = [pscustomobject]@{
        Label = 'Confirm'; Options = @('No', 'Not now')
        Values = @('no', 'not_now'); IsText = $false
    }
    Test-That 'selected No does not match the audit result Confirm=Not now' {
        -not (Test-CopilotAnswerMatchesSelections -ResultContent 'Confirm=Not now' `
            -Fields @($field) -Selections @('No'))
    }
    Test-That 'selected No still matches Confirm=No' {
        Test-CopilotAnswerMatchesSelections -ResultContent 'Confirm=No' `
            -Fields @($field) -Selections @('No')
    }
    Test-That 'selected No does not match the captured native single-field neighbour' {
        -not (Test-CopilotAnswerMatchesSelections -ResultContent 'User responded: Not now' `
            -Fields @($field) -Selections @('No'))
    }
    Test-That 'selected No still matches the captured native single-field answer' {
        Test-CopilotAnswerMatchesSelections -ResultContent 'User responded: No' `
            -Fields @($field) -Selections @('No')
    }
    Test-That 'an absent result is unconfirmed rather than a verified selection' {
        -not (Test-CopilotAnswerMatchesSelections -ResultContent '' `
            -Fields @($field) -Selections @('No'))
    }

    $namedFields = @(
        [pscustomobject]@{ Name = 'first'; Label = 'First'; Options = @('North', 'South'); Values = @('north', 'south'); IsText = $false }
        [pscustomobject]@{ Name = 'second'; Label = 'Second'; Options = @('North', 'South'); Values = @('north', 'south'); IsText = $false }
    )
    Test-That 'structured answers cannot exchange values between fields' {
        -not (Test-CopilotAnswerMatchesSelections -ResultContent '{"first":"south","second":"north"}' `
            -Fields $namedFields -Selections @('North', 'South'))
    }
    Test-That 'the correctly addressed structured answers still match' {
        Test-CopilotAnswerMatchesSelections -ResultContent '{"first":"north","second":"south"}' `
            -Fields $namedFields -Selections @('North', 'South')
    }
    $typedField = [pscustomobject]@{
        Name = 'enabled'; Label = 'Enabled'; Options = @('Enabled', 'Disabled')
        Values = @($true, $false); IsText = $false
    }
    Test-That 'a structured string false is not the typed boolean false' {
        -not (Test-CopilotAnswerMatchesSelections -ResultContent '{"enabled":"false"}' `
            -Fields @($typedField) -Selections @('Disabled'))
    }
    Test-That 'the structured boolean false remains a matching answer' {
        Test-CopilotAnswerMatchesSelections -ResultContent '{"enabled":false}' `
            -Fields @($typedField) -Selections @('Disabled')
    }

    Write-Host '--- schema identity survives the actual marker round trip ---'
    $dateText = '2026-09-30T19:00:00.1234567-07:00'
    $schema = [pscustomobject]@{
        properties = [pscustomobject][ordered]@{
            enabled = [pscustomobject]@{ title = 'Enabled'; type = 'boolean'; default = $false }
            value = [pscustomobject]@{
                title = 'Value'; default = $null
                oneOf = @(
                    [pscustomobject]@{ title = 'Zero'; const = 0 }
                    [pscustomobject]@{ title = 'Null'; const = $null }
                    [pscustomobject]@{ title = 'Date text'; const = $dateText }
                )
            }
            tags = [pscustomobject]@{
                title = 'Tags'; type = 'array'; default = @('B')
                items = [pscustomobject]@{ enum = @('A', 'B') }
            }
        }
    }
    $fields = @(& { Set-StrictMode -Off; Get-DecisionSchemaFields -Schema $schema })
    Test-That 'schema fields keep their original field name' {
        $fields[0].PSObject.Properties['Name'] -and $fields[0].Name -ceq 'enabled'
    }
    Test-That 'boolean false is retained as a boolean schema value' {
        $fields[0].Values[1] -is [bool] -and $fields[0].Values[1] -eq $false
    }
    Test-That 'numeric zero is retained as a numeric schema value' {
        $fields[1].Values[0] -is [int] -and $fields[1].Values[0] -eq 0
    }
    Test-That 'null const is not replaced with its presentation label' {
        $null -eq $fields[1].Values[1]
    }
    Test-That 'a date-looking string remains exact before persistence' {
        $fields[1].Values[2] -is [string] -and $fields[1].Values[2] -ceq $dateText
    }
    $sid = 'a3000000-0000-4000-8000-000000000019'
    [void][IO.Directory]::CreateDirectory((Join-Path $script:DecisionBridgeConfig.SessionStateRoot $sid))
    Write-CopilotDecisionMarker -SessionId $sid -DecisionId 'synthetic-typed-schema' `
        -Question 'Synthetic schema identity' -Fields $fields -Mode multiple_choice
    $marker = Get-CopilotDecisionMarker -SessionId $sid
    Test-That 'the real marker reader returns all three persisted fields' {
        $null -ne $marker -and @($marker.fields).Count -eq 3
    }
    Test-That 'a date-looking schema value remains a string after real marker reading' {
        $marker.fields[1].Values[2] -is [string] -and $marker.fields[1].Values[2] -ceq $dateText
    }
    Remove-CopilotDecisionMarker -SessionId $sid

    $defaultSchema = [pscustomobject]@{
        properties = [pscustomobject]@{
            answer = [pscustomobject]@{
                title = 'Answer'; type = 'string'; enum = @('No', 'Not now'); default = 'Not now'
            }
        }
    }
    $defaultFields = @(& { Set-StrictMode -Off; Get-DecisionSchemaFields -Schema $defaultSchema })
    Test-That 'accepting the current native default does not move down from that default' {
        $payloads = @(Get-BridgeFormPayloads -Fields $defaultFields -Selections @('Not now'))
        $payloads.Count -eq 1 -and $payloads[0].Payload -ceq ''
    }

    Write-Host '--- lossless scalar containers, defaults and supported result shapes ---'
    $typedSchema = ConvertFrom-DecisionJson -Json @'
{"properties":{"value":{"title":"Value","default":null,"oneOf":[
{"title":"Boolean false","const":false},{"title":"Text false","const":"false"},
{"title":"Nothing","const":null},{"title":"Text null","const":"null"},
{"title":"Zero","const":0},{"title":"Text zero","const":"0"},
{"title":"Empty text","const":""},
{"title":"Short timestamp","const":"2030-01-02T03:04:05Z"},
{"title":"Precise timestamp","const":"2030-01-02T03:04:05.000Z"}]}}}
'@
    $scalarFields = @(Get-DecisionSchemaFields -Schema $typedSchema)
    Test-That 'null defaults retain presence, value and their nonzero native focus' {
        $scalarFields[0].HasDefault -and $null -eq $scalarFields[0].Default -and $scalarFields[0].DefaultIndex -eq 2
    }
    Test-That 'typed choices keep stable positions even for false, null, zero and empty string' {
        $scalarFields[0].Values.Count -eq 9 -and $scalarFields[0].OptionIds.Count -eq 9 -and
            $scalarFields[0].OptionIds[6] -ceq 'option-6' -and $scalarFields[0].Values[6] -ceq ''
    }
    for ($index = 0; $index -lt $scalarFields[0].Options.Count; $index++) {
        $option = $scalarFields[0].Options[$index]
        $value = $scalarFields[0].Values[$index]
        Test-That "structured scalar '$option' retains its exact JSON value identity" {
            $json = ConvertTo-Json -InputObject @{ value = $value } -Depth 8 -Compress
            (Test-CopilotAnswerMatchesSelections -ResultContent $json -Fields $scalarFields -Selections @($option) -Detailed).Status -ceq 'Matched'
        }
    }
    Test-That 'false and string false are different supported structured answers' {
        (Test-CopilotAnswerMatchesSelections -ResultContent '{"value":"false"}' -Fields $scalarFields `
            -Selections @('Boolean false') -Detailed).Status -ceq 'Mismatch'
    }
    Test-That 'the same instant spelled differently remains a different string answer' {
        (Test-CopilotAnswerMatchesSelections -ResultContent '{"value":"2030-01-02T03:04:05.000Z"}' -Fields $scalarFields `
            -Selections @('Short timestamp') -Detailed).Status -ceq 'Mismatch'
    }
    foreach ($text in @('false', 'null', '0')) {
        Test-That "flattened '$text' is unconfirmed when typed options collide" {
            (Test-CopilotAnswerMatchesSelections -ResultContent "User responded: $text" -Fields $scalarFields `
                -Selections @('Boolean false') -Detailed).Status -ceq 'Unconfirmed'
        }
    }
    foreach ($content in @(
        '', '{}', '{"VALUE":false}', '{"value":false,"extra":0}', '{"answers":{"value":false}}',
        '{"value":[]}', '{"value":{"nested":false}}', '[false]', '{', 'unrecognized content',
        '{"value":false,"value":false}', '{"value":false,"Value":false}'
    )) {
        Test-That "absent, ambiguous or unsupported result is unconfirmed: $content" {
            (Test-CopilotAnswerMatchesSelections -ResultContent $content -Fields $scalarFields `
                -Selections @('Boolean false') -Detailed).Status -ceq 'Unconfirmed'
        }
    }
    Test-That 'an already-coerced DateTime is not reconstructed into a matching string' {
        (Test-CopilotAnswerMatchesSelections -ResultContent ([pscustomobject]@{ value = [datetime]'2030-01-02T03:04:05Z' }) `
            -Fields $scalarFields -Selections @('Short timestamp') -Detailed).Status -ceq 'Unconfirmed'
    }
    Test-That 'a missing selection is unconfirmed even when every result field is present' {
        (Test-CopilotAnswerMatchesSelections -ResultContent '{"first":"north","second":"south"}' `
            -Fields $namedFields -Selections @('North') -Detailed).Status -ceq 'Unconfirmed'
    }
    foreach ($ambiguousValue in @('No, second=Yes', 'Confirm=No', '"No"', 'No ')) {
        $ambiguousField = [pscustomobject]@{
            Name = 'Confirm'; Label = 'Confirm'; Options = @('No', 'Other')
            Values = @('No', $ambiguousValue); IsText = $false
        }
        Test-That "lossy text syntax cannot prove a match when an option contains '$ambiguousValue'" {
            (Test-CopilotAnswerMatchesSelections -ResultContent 'User responded: Confirm=No' `
                -Fields @($ambiguousField) -Selections @('No') -Detailed).Status -ceq 'Unconfirmed'
        }
    }
    $wildcardField = [pscustomobject]@{ Label = 'Pattern'; Options = @('No*', 'Not now'); IsText = $false }
    Test-That 'wildcard-looking labels are compared literally, not as patterns' {
        (Test-CopilotAnswerMatchesSelections -ResultContent 'Pattern=Not now' -Fields @($wildcardField) `
            -Selections @('No*') -Detailed).Status -ceq 'Mismatch'
    }
    $duplicateValueField = [pscustomobject]@{ Label = 'Choice'; Options = @('First', 'Second'); Values = @('same', 'same'); IsText = $false }
    Test-That 'duplicate underlying values cannot verify a distinct native option identity' {
        (Test-CopilotAnswerMatchesSelections -ResultContent '{"Choice":"same"}' -Fields @($duplicateValueField) `
            -Selections @('First') -Detailed).Status -ceq 'Unconfirmed'
    }
    $claudeSet = [pscustomobject]@{ Name = 'Features?'; Label = 'Features'; Options = @('A', 'B', 'C'); MultiSelect = $true; IsText = $false }
    Test-That 'existing Claude multi-select verification compares per-field sets, not selection order' {
        (Test-CopilotAnswerMatchesSelections -ResultContent '"Features?"="C, A"' -Fields @($claudeSet) `
            -Selections @('A + C') -Detailed).Status -ceq 'Matched'
    }
    Test-That 'a missing member of an existing Claude multi-select is a mismatch' {
        (Test-CopilotAnswerMatchesSelections -ResultContent '{"Features?":["A"]}' -Fields @($claudeSet) `
            -Selections @('A + C') -Detailed).Status -ceq 'Mismatch'
    }
    Test-That 'the lossless decoder preserves arrays and JSON names that overlap CLR members' {
        $decoded = ConvertFrom-DecisionJson -Json '{"Type":"value","Count":4,"Value":[[],[null],[[false]],["2030-01-02T03:04:05Z"]]}'
        $decoded.Type -ceq 'value' -and $decoded.Count -eq 4 -and $decoded.Value.Count -eq 4 -and
            $decoded.Value[0] -is [array] -and $decoded.Value[0].Count -eq 0 -and
            $decoded.Value[1] -is [array] -and $decoded.Value[1].Count -eq 1 -and $null -eq $decoded.Value[1][0] -and
            $decoded.Value[2][0] -is [array] -and $decoded.Value[2][0][0] -is [bool] -and
            $decoded.Value[3][0] -is [string]
    }
    Test-That 'schema text recovery retains two distinct date-looking strings' {
        $recovered = ConvertFrom-DecisionSchemaText -Text '{"properties":{"v":{"enum":["2030-01-02T03:04:05Z","2030-01-02T03:04:05.000Z"]}}'
        $recovered.properties.v.enum[0] -is [string] -and
            $recovered.properties.v.enum[0] -cne $recovered.properties.v.enum[1]
    }
    Test-That 'a single null option keeps its label, list position and null value' {
        $only = @(Get-DecisionSchemaFields -Schema (ConvertFrom-DecisionJson -Json '{"properties":{"v":{"enum":[null],"enumNames":["Only"],"default":null}}}'))
        $only[0].Options.Count -eq 1 -and $only[0].Options[0] -ceq 'Only' -and
            $only[0].Values.Count -eq 1 -and $null -eq (Get-DecisionFieldOptionValue -Field $only[0] -Option 'Only')
    }
    Test-That 'moving before a captured default uses Up rather than Down from the first item' {
        @(Get-BridgeFormPayloads -Fields $defaultFields -Selections @('No'))[0].Payload -ceq ([string][char]27 + '[A')
    }
    Test-That 'zero, false and string defaults retain distinct native focus' {
        $defaults = @(Get-DecisionSchemaFields -Schema (ConvertFrom-DecisionJson -Json @'
{"properties":{"zero":{"title":"Zero","enum":[1,0],"default":0},"false":{"title":"False","type":"boolean","default":false},"text":{"title":"Text","enum":["A","B"],"default":"B"}}}
'@))
        $defaults[0].Default -is [long] -and $defaults[1].Default -is [bool] -and $defaults[2].Default -is [string] -and
            @($defaults | Where-Object { $_.DefaultIndex -ne 1 }).Count -eq 0 -and
            @((Get-BridgeFormPayloads -Fields $defaults -Selections @('0', 'No', 'B')) | Where-Object { $_.Payload -cne '' }).Count -eq 0
    }
    Test-That 'an old label-as-default fixture is rejected instead of guessing native focus' {
        $rejected = $false
        try {
            [void](Get-DecisionSchemaFields -Schema (ConvertFrom-DecisionJson -Json '{"properties":{"scope":{"type":"string","title":"Scope","default":"Patch only","oneOf":[{"const":"both","title":"Both"},{"const":"patch","title":"Patch only"}]}}}'))
        }
        catch [IO.InvalidDataException] { $rejected = $true }
        $rejected
    }
    foreach ($labels in @(
        @('Same', 'Same'), @('Case', 'case'), @(('x' * 251), ('x' * 250) + 'y'),
        @('Idle', 'Other'), @('Awaiting answer...', 'Other'), @('Choose...', 'Other'),
        @('Cancel request', 'Other'), @('unknown', 'Other'), @('unavailable', 'Other')
    )) {
        Test-That "ambiguous or reserved presentation is explicitly rejected: $($labels[0].Substring(0, [Math]::Min(25, $labels[0].Length)))" {
            $rejected = $false
            try { [void](Get-DecisionSchemaFieldChoices -Field ([pscustomobject]@{ enum = $labels })) }
            catch [IO.InvalidDataException] { $rejected = $true }
            $rejected
        }
    }

    & {
        Write-Host '--- actual wrapper stdin, marker values and fixed allow output ---'
        . (Join-Path $repo 'tests\runner-support.ps1')
        $bootstrap = @'
$ErrorActionPreference = 'Stop'
$wrapperContext = Get-Content -LiteralPath (Join-Path $env:AGENT_HA_BRIDGE_TEST_ROOT 'wrapper-context.json') -Raw | ConvertFrom-Json
. (Join-Path $wrapperContext.Repository 'hooks\decision-bridge-common.ps1')
[void][IO.Directory]::CreateDirectory((Join-Path $script:DecisionBridgeConfig.SessionStateRoot $wrapperContext.SessionId))
@{
    Marker = (Get-CopilotDecisionMarkerPath -SessionId $wrapperContext.SessionId)
    Log = $script:DecisionBridgeConfig.LogFile
    Isolated = ($env:AGENT_HA_BRIDGE_OFFLINE_TEST -eq '1' -and -not $env:GH_TOKEN -and -not $env:GITHUB_TOKEN -and -not $env:AGENT_HA_AGENT_TOKEN)
} | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $env:AGENT_HA_BRIDGE_TEST_ROOT 'wrapper-paths.json')
function Invoke-RestMethod {
    'synthetic request' | Add-Content -LiteralPath (Join-Path $env:AGENT_HA_BRIDGE_TEST_ROOT 'network.txt')
    throw 'Synthetic wrapper network outage.'
}
function Invoke-WebRequest {
    'synthetic request' | Add-Content -LiteralPath (Join-Path $env:AGENT_HA_BRIDGE_TEST_ROOT 'network.txt')
    throw 'Synthetic wrapper network outage.'
}
& (Join-Path $wrapperContext.Repository 'hooks\route-ask-user-v3.ps1')
'@
        function Invoke-P3bWrapper {
            param([AllowEmptyString()][string]$Raw)
            $sandbox = New-BridgeTestSandbox -ParentDirectory $root
            $process = [Diagnostics.Process]::new()
            $started = $false
            try {
                $context = @{ Repository = $repo; SessionId = 'a3000000-0000-4000-8000-000000000029' }
                $context | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $sandbox 'wrapper-context.json') -Encoding utf8
                $scriptPath = Join-Path $sandbox 'wrapper-fixture.ps1'
                $bootstrap | Set-Content -LiteralPath $scriptPath -Encoding utf8
                $process.StartInfo = New-BridgeTestProcessStartInfo -ScriptPath $scriptPath -Sandbox $sandbox -Group Offline
                $process.StartInfo.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
                $started = $process.Start()
                if (-not $started) { throw 'Could not start the isolated real wrapper.' }
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
                $process.StandardInput.Write($Raw)
                $process.StandardInput.Close()
                if (-not $process.WaitForExit(30000)) { throw 'The real wrapper did not finish.' }
                if (-not $stdout.Wait(5000) -or -not $stderr.Wait(5000)) { throw 'Wrapper output did not close.' }
                $paths = Get-Content -LiteralPath (Join-Path $sandbox 'wrapper-paths.json') -Raw | ConvertFrom-Json
                $networkPath = Join-Path $sandbox 'network.txt'
                [pscustomobject]@{
                    ExitCode = $process.ExitCode; Output = $stdout.GetAwaiter().GetResult()
                    ErrorOutput = $stderr.GetAwaiter().GetResult(); Isolated = $paths.Isolated
                    Marker = (Read-DecisionMarkerFile -Path $paths.Marker)
                    NetworkCalls = $(if (Test-Path -LiteralPath $networkPath) { @([IO.File]::ReadAllLines($networkPath)).Count } else { 0 })
                    Log = $(if (Test-Path -LiteralPath $paths.Log) { [IO.File]::ReadAllText($paths.Log) } else { '' })
                }
            }
            finally {
                if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
                $process.Dispose()
                Remove-Item -LiteralPath $sandbox -Recurse -Force
            }
        }
        foreach ($shape in @('object', 'string-arguments', 'string-schema')) {
            $schemaObject = [ordered]@{ properties = [ordered]@{ answer = [ordered]@{
                title = 'Timestamp text'; enum = @('2030-01-02T03:04:05Z', '2030-01-02T03:04:05.000Z')
                default = '2030-01-02T03:04:05.000Z'
            } } }
            $toolArgs = [ordered]@{ message = 'Synthetic timestamp choice'; requestedSchema = $schemaObject }
            if ($shape -eq 'string-schema') { $toolArgs.requestedSchema = $schemaObject | ConvertTo-Json -Depth 10 -Compress }
            if ($shape -eq 'string-arguments') { $toolArgs = $toolArgs | ConvertTo-Json -Depth 10 -Compress }
            $raw = [ordered]@{
                sessionId = 'a3000000-0000-4000-8000-000000000029'; timestamp = 123456
                cwd = 'synthetic'; toolName = 'ask_user'; toolArgs = $toolArgs
            } | ConvertTo-Json -Depth 12 -Compress
            $wrapped = Invoke-P3bWrapper -Raw $raw
            Test-That "the actual $shape wrapper preserves its exact allow output and exit behavior" {
                $wrapped.Isolated -and $wrapped.ExitCode -eq 0 -and $wrapped.Output.Trim() -ceq '{"permissionDecision":"allow"}'
            }
            Test-That "the actual $shape wrapper persists both raw date strings through a network outage" {
                $wrapped.NetworkCalls -gt 0 -and $null -ne $wrapped.Marker -and
                    $wrapped.Marker.fields[0].Values[0] -is [string] -and
                    $wrapped.Marker.fields[0].Values[0] -ceq '2030-01-02T03:04:05Z' -and
                    $wrapped.Marker.fields[0].Values[1] -ceq '2030-01-02T03:04:05.000Z'
            }
            Test-That "the $shape wrapper preserves the existing timestamp identity and scalar default payload" {
                $wrapped.Marker.decisionId.EndsWith('-123456') -and
                    [string]::IsNullOrEmpty([string]$wrapped.Marker.toolCallId) -and -not $wrapped.Marker.terminalOnly -and
                    @(Get-BridgeFormPayloads -Fields @($wrapped.Marker.fields) -Selections @('2030-01-02T03:04:05.000Z'))[0].Payload -ceq ''
            }
            Test-That "the $shape wrapper marker supports exact structured caller verification" {
                (Test-CopilotAnswerMatchesSelections -ResultContent '{"answer":"2030-01-02T03:04:05Z"}' `
                    -Fields @($wrapped.Marker.fields) -Selections @('2030-01-02T03:04:05.000Z') -Detailed).Status -ceq 'Mismatch'
            }
        }
        foreach ($invalid in @('', '{')) {
            $wrapped = Invoke-P3bWrapper -Raw $invalid
            Test-That 'empty or malformed wrapper input still allows the native tool without network or marker output' {
                $wrapped.ExitCode -eq 0 -and $wrapped.Output.Trim() -ceq '{"permissionDecision":"allow"}' -and
                    $null -eq $wrapped.Marker -and $wrapped.NetworkCalls -eq 0
            }
        }
        $wrapped = Invoke-P3bWrapper -Raw '{"sessionId":"a3000000-0000-4000-8000-000000000029","toolArgs":{"question":"Synthetic","choices":["Same","Same"]}}'
        Test-That 'ambiguous wrapper choices fail open natively but do not publish or persist a misleading mapping' {
            $wrapped.ExitCode -eq 0 -and $wrapped.Output.Trim() -ceq '{"permissionDecision":"allow"}' -and
                $null -eq $wrapped.Marker -and $wrapped.NetworkCalls -eq 0 -and $wrapped.Log -match 'distinct'
        }
    }

    & {
        Write-Host '--- actual spool decode, dispatch and unchanged non-decision metadata ---'
        $oldDirectory = $script:DaemonHookSpoolDirectory
        $script:DaemonHookSpoolDirectory = Join-Path $root 'decision-spool'
        [void][IO.Directory]::CreateDirectory($script:DaemonHookSpoolDirectory)
        $script:P3bSpooled = [Collections.Generic.List[object]]::new()
        $actualDispatch = (Get-Command Invoke-DaemonHookEvent).ScriptBlock
        function Invoke-DaemonHookEvent {
            param($Spooled)
            $script:P3bSpooled.Add($Spooled)
            & $actualDispatch -Spooled $Spooled
        }
        function Test-HomeAssistantReachable { $false }
        function Invoke-CopilotPermissionHook { param($HookEvent) }
        function Invoke-ClaudeAskHook { param($HookEvent, $Ancestors) }
        try {
            $sid = 'a3000000-0000-4000-8000-000000000039'
            [void][IO.Directory]::CreateDirectory((Join-Path $script:DecisionBridgeConfig.SessionStateRoot $sid))
            $events = @(
                '{"v":1,"agent":"copilot","hook":"ask_user","receivedAt":"2030-01-02T03:04:05Z","ancestors":[],"event":{"sessionId":"a3000000-0000-4000-8000-000000000039","timestamp":"2030-01-02T03:04:05Z","toolArgs":{"message":"Synthetic","requestedSchema":{"properties":{"answer":{"title":"Timestamp","enum":["2030-01-02T03:04:05Z","2030-01-02T03:04:05.000Z"]}}}}}}'
                '{"v":1,"agent":"copilot","hook":"permission","receivedAt":"2030-01-02T03:04:05Z","ancestors":[],"event":{"timestamp":"2030-01-02T03:04:05Z","toolArgs":{"value":"2030-01-02T03:04:05.000Z"}}}'
                '{"v":1,"agent":"claude","hook":"ask","receivedAt":"2030-01-02T03:04:05Z","ancestors":[],"event":{"timestamp":"2030-01-02T03:04:05Z","tool_input":{"value":"2030-01-02T03:04:05.000Z"}}}'
            )
            for ($index = 0; $index -lt $events.Count; $index++) {
                [IO.File]::WriteAllText((Join-Path $script:DaemonHookSpoolDirectory "$index.json"), $events[$index])
            }
            $handled = Invoke-DaemonHookSpool
            $spooledMarker = Get-CopilotDecisionMarker -SessionId $sid
            Test-That 'the actual spool and dispatcher persist distinct decision strings through the real hook' {
                $handled -eq 3 -and $null -ne $spooledMarker -and $spooledMarker.fields[0].Values[0] -is [string] -and
                    $spooledMarker.fields[0].Values[0] -ceq '2030-01-02T03:04:05Z' -and
                    $spooledMarker.fields[0].Values[1] -ceq '2030-01-02T03:04:05.000Z'
            }
            Test-That 'spool envelope and event timestamps keep their prior date interpretation' {
                $script:P3bSpooled[0].receivedAt -is [datetime] -and $script:P3bSpooled[0].event.timestamp -is [datetime]
            }
            Test-That 'non-decision Copilot values are not blanket-redecoded' {
                $script:P3bSpooled[1].event.toolArgs.value -is [datetime]
            }
            Test-That 'another client keeps its existing value decoding' {
                $script:P3bSpooled[2].event.tool_input.value -is [datetime]
            }
            Test-That 'successful spool handling retains its existing file cleanup' {
                @([IO.Directory]::GetFiles($script:DaemonHookSpoolDirectory, '*.json')).Count -eq 0
            }
            Remove-CopilotDecisionMarker -SessionId $sid
        }
        finally { $script:DaemonHookSpoolDirectory = $oldDirectory }
    }

    & {
        Write-Host '--- actual Claude hook, marker and supplied-ID caller ---'
        . (Join-Path $repo 'claude\hooks\claude-ask-parser.ps1')
        . (Join-Path $repo 'claude\hooks\claude-hooks.ps1')
        . (Join-Path $repo 'claude\hooks\claude-transcript.ps1')
        $oldLoaded = $script:ClaudeAdapterLoaded
        $script:ClaudeAdapterLoaded = $true
        function Get-ClaudeOwningProcessId { param($Ancestors) 0 }
        function Write-ClaudeSessionRegistration { param($SessionId, $TranscriptPath, $WorkingDirectory, $ProcessId) }
        function Resolve-ClaudeTranscriptPath { param($SessionId, $KnownPath) $KnownPath }
        function Test-HomeAssistantReachable { $false }
        try {
            $sid = 'a3000000-0000-4000-8000-000000000059'
            $directory = Join-Path $script:DecisionBridgeConfig.SessionStateRoot $sid
            [void][IO.Directory]::CreateDirectory($directory)
            $transcript = Join-Path $directory 'claude.jsonl'
            foreach ($supplied in @($true, $false)) {
                $event = [ordered]@{
                    session_id = $sid; transcript_path = $transcript; cwd = 'synthetic'; tool_name = 'AskUserQuestion'
                    tool_input = [pscustomobject]@{ questions = @([pscustomobject]@{
                        question = 'Confirm?'; header = 'Confirm'; options = @('No', 'Not now')
                    }) }
                }
                if ($supplied) { $event.tool_use_id = 'Native-Question' }
                Invoke-ClaudeAskHook -HookEvent ([pscustomobject]$event) | Out-Null
                $claudeMarker = Get-CopilotDecisionMarker -SessionId $sid
                Test-That "the real Claude hook conditionally stores the supplied native ID: $supplied" {
                    $null -ne $claudeMarker -and -not $claudeMarker.terminalOnly -and
                        $claudeMarker.fields[0].Name -ceq 'Confirm?' -and
                        $(if ($supplied) { $claudeMarker.toolCallId -ceq 'Native-Question' } else { $claudeMarker.toolCallId -ceq '' })
                }
                $record = [ordered]@{
                    type = 'assistant'; timestamp = [DateTimeOffset]::Now.ToString('o')
                    message = @{ content = @(@{ type = 'tool_use'; name = 'AskUserQuestion'; id = 'Native-Question' }) }
                } | ConvertTo-Json -Depth 8 -Compress
                [IO.File]::WriteAllText($transcript, $record + "`n")
                $session = [pscustomobject]@{ Kind = 'claude'; Transcript = $transcript }
                $pending = Get-DaemonAskUserState -Session $session -Marker $claudeMarker
                Test-That "the actual client-aware caller preserves pending Claude answering with native ID supplied=$supplied" {
                    $pending.Started -and $pending.Pending -and $pending.ToolCallId -ceq 'Native-Question'
                }
                '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"Native-Question","content":"Your questions have been answered: \"Confirm?\"=\"No\"."}]}}' |
                    Add-Content -LiteralPath $transcript -Encoding utf8
                $answered = Get-DaemonAskUserState -Session $session -Marker $claudeMarker
                Test-That "the actual Claude caller completes and verifies its own result with ID supplied=$supplied" {
                    $answered.Started -and -not $answered.Pending -and
                        (Test-CopilotAnswerMatchesSelections -ResultContent $answered.ResultContent `
                            -Fields @($claudeMarker.fields) -Selections @('No') -Detailed).Status -ceq 'Matched'
                }
                Remove-CopilotDecisionMarker -SessionId $sid
            }
        }
        finally { $script:ClaudeAdapterLoaded = $oldLoaded }
    }

    & {
        Write-Host '--- actual publisher rejection and terminal-result cleanup ---'
        $script:P3bPublished = [Collections.Generic.List[object]]::new()
        function Publish-CopilotMqttMessage {
            param($Topic, $Payload, $Headers, [switch]$Retain)
            $script:P3bPublished.Add([pscustomobject]@{ Topic = $Topic; Payload = (ConvertFrom-DecisionJson -Json $Payload) })
        }
        function Invoke-HomeAssistantService { param($Domain, $Service, $Headers, $Data) }
        # Arming now reads what the answer channels already hold, so that an answer
        # given before the first daemon sweep is not later mistaken for what was
        # always there. Nothing exists yet on this synthetic card, which is what Home
        # Assistant says with a 404.
        function Get-HomeAssistantState { param($EntityId, $Headers)
            $notFound = [InvalidOperationException]::new("Response status code does not indicate success: 404 (Not Found). [$EntityId]")
            $notFound.Data['BridgeHttpStatus'] = 404
            throw $notFound
        }
        function Set-CopilotMqttEntityIds { param($SessionId) }
        function Start-Sleep { param($Milliseconds, $Seconds) }
        $sid = 'a3000000-0000-4000-8000-000000000049'
        foreach ($invalidLabels in @(@('Duplicate', 'Duplicate'), @(('x' * 251), 'Other'), @('Choose...', 'Other'))) {
            $script:P3bPublished.Clear()
            $rejected = $false
            try {
                Set-CopilotMqttDecision -SessionId $sid -SessionName Synthetic -Machine TEST -Question Synthetic `
                    -Choices $invalidLabels -DecisionId 'synthetic' -Headers @{} | Out-Null
            }
            catch [IO.InvalidDataException] { $rejected = $true }
            Test-That 'the actual publisher rejects unsafe options before publishing any partial card' {
                $rejected -and $script:P3bPublished.Count -eq 0
            }
        }
        $fullLabel = 'x' * 250
        Set-CopilotMqttDecision -SessionId $sid -SessionName Synthetic -Machine TEST -Question Synthetic `
            -Choices @($fullLabel, 'Other') -DecisionId 'synthetic' -Headers @{} | Out-Null
        Test-That 'the selector length boundary is preserved exactly rather than clipped' {
            @($script:P3bPublished | Where-Object { $_.Topic -like '*/decision/config' })[0].Payload.options[1] -ceq $fullLabel
        }
        $script:P3bNativeCount = 0
        $script:P3bWarnings = [Collections.Generic.List[string]]::new()
        function Send-CopilotSessionPrompt { param($SessionId, $Text, $ProcessId) $script:P3bNativeCount++; throw 'No native input is allowed in completion.' }
        function Set-DaemonTransientActivity { param($SessionId, $Summary, $Extra, $Headers) $script:P3bWarnings.Add($Summary) }
        [void][IO.Directory]::CreateDirectory((Join-Path $script:DecisionBridgeConfig.SessionStateRoot $sid))
        foreach ($completion in @(
            @{ Content = 'Confirm=Not now'; Warning = 'differs' }
            @{ Content = ''; Warning = 'unconfirmed' }
            @{ Content = '{"unexpected":true}'; Warning = 'unconfirmed' }
            @{ Content = [pscustomobject]@{ Confirm = 'no' }; Warning = '' }
        )) {
            Write-CopilotDecisionMarker -SessionId $sid -DecisionId 'completion' -Question Synthetic -Fields @($field) -Mode multiple_choice
            Set-CopilotDecisionMarkerInjected -SessionId $sid -Answer 'No' -Selections @('No')
            $completionMarker = Get-CopilotDecisionMarker -SessionId $sid
            $state = @{ $sid = [pscustomobject]@{ Name = 'Synthetic'; Machine = 'TEST'; LastReply = 'old' } }
            $script:P3bWarnings.Clear()
            Complete-DaemonAnsweredDecision -SessionId $sid -Marker $completionMarker -Headers @{} -State $state `
                -AskState ([pscustomobject]@{ Started = $true; Pending = $false; ResultContent = $completion.Content })
            Test-That "actual completion reports '$($completion.Warning)' without overriding a terminal answer" {
                $script:P3bNativeCount -eq 0 -and
                    $(if ($completion.Warning) { ($script:P3bWarnings -join ' ') -match $completion.Warning } else { $script:P3bWarnings.Count -eq 0 })
            }
            Test-That 'actual completion still removes its real marker and clears the reply after either input' {
                $null -eq (Get-CopilotDecisionMarker -SessionId $sid) -and $state[$sid].LastReply -ceq ''
            }
        }
    }

    $deliveryInitialFailures = $script:Failures
    $deliveryInitialChecks = $script:Checks
    & {
        Write-Host '--- actual selector delivery persists the selections used by completion ---'
        . (Join-Path $repo 'claude\hooks\claude-session.ps1')
        . (Join-Path $repo 'claude\hooks\claude-ask-parser.ps1')
        . (Join-Path $repo 'claude\hooks\claude-hooks.ps1')
        . (Join-Path $repo 'claude\hooks\claude-transcript.ps1')
        $previousLive = $script:DaemonLive
        $previousClaudeLoaded = $script:ClaudeAdapterLoaded
        $previousClaudeRoot = $script:ClaudeStateRoot
        $script:ClaudeAdapterLoaded = $true
        $script:ClaudeStateRoot = Join-Path $root 'delivery-claude'

        function Test-HomeAssistantReachable { $false }
        function Get-ClaudeOwningProcessId { param($Ancestors) 0 }
        function Add-DeliveryResult {
            $fixture = $script:DeliveryFixture
            if ($fixture.ResultWritten) { throw 'This fixture already has a terminal result.' }
            if ($fixture.Kind -eq 'copilot') {
                $data = @{ toolCallId = $fixture.CallId }
                if ($fixture.ResultKind -ne 'missing') { $data.result = @{ content = $fixture.Content } }
                $entry = @{ type = 'tool.execution_complete'; timestamp = [DateTimeOffset]::Now.ToString('o'); data = $data }
            }
            else {
                $block = @{ type = 'tool_result'; tool_use_id = $fixture.CallId }
                if ($fixture.ResultKind -ne 'missing') { $block.content = $fixture.Content }
                $entry = @{ type = 'user'; timestamp = [DateTimeOffset]::Now.ToString('o'); message = @{ content = @($block) } }
            }
            [IO.File]::AppendAllText($fixture.Transcript, (($entry | ConvertTo-Json -Depth 8 -Compress) + "`n"))
            $fixture.ResultWritten = $true
        }
        function Get-HomeAssistantState {
            param($EntityId, $Headers)
            $fixture = $script:DeliveryFixture
            if ($EntityId -ceq $fixture.DecisionEntity) {
                $fixture.DecisionReads++
                if ($fixture.TerminalOnRead -and $fixture.DecisionReads -eq 2) { Add-DeliveryResult }
            }
            if (-not $fixture.Ha.ContainsKey($EntityId)) { throw "Unexpected synthetic entity: $EntityId" }
            $fixture.Ha[$EntityId]
        }
        function Publish-CopilotMqttMessage {
            param($Topic, $Payload, $Headers, [switch]$Retain)
            if ($Topic -ceq $script:DeliveryFixture.Topics.DecisionAttributes -and $Payload -ceq '{}') {
                $script:DeliveryFixture.CardClears++
            }
        }
        function Invoke-HomeAssistantService {
            param($Domain, $Service, $Headers, $Data)
            $fixture = $script:DeliveryFixture
            if ($Domain -eq 'text' -and $Service -eq 'set_value') {
                $fixture.Ha[$Data.entity_id].state = [string]$Data.value
            }
            elseif ($Domain -eq 'select' -and $Service -eq 'select_option') {
                $fixture.Ha[$Data.entity_id].state = [string]$Data.option
            }
            else { throw "Unexpected synthetic service: $Domain.$Service" }
        }
        function Set-DaemonTransientActivity {
            param($SessionId, $Summary, $Extra, $Headers)
            $script:DeliveryFixture.Activity.Add([string]$Summary)
        }
        function Send-CopilotSessionForm {
            param($SessionId, $Fields, $Selections, $ProcessId)
            $fixture = $script:DeliveryFixture
            $before = Get-CopilotDecisionMarker -SessionId $SessionId -RequireReadable
            $fixture.Inputs.Add([pscustomobject]@{
                Route = 'form'; Selections = @($Selections)
                Payloads = @(Get-BridgeFormPayloads -Fields $Fields -Selections $Selections)
                StoredBeforeInput = $(if ($before.PSObject.Properties['injectedSelections']) { @($before.injectedSelections).Count } else { 0 })
            })
            if ($fixture.FormDelivered -and $fixture.Kind -eq 'claude') { Add-DeliveryResult }
            [pscustomobject]@{ Delivered = $fixture.FormDelivered; ProcessId = 0; Detail = 'Synthetic native form boundary'
                # This fixture's failing form is a clean pre-write refusal, which is the
                # case the fallback below exists for. A form that had already written
                # would not fall back at all.
                Wrote = $fixture.FormDelivered }
        }
        function Send-CopilotSessionChoice {
            param($SessionId, $Text, $ChoiceCount, $ProcessId)
            $fixture = $script:DeliveryFixture
            $fixture.Inputs.Add([pscustomobject]@{ Route = 'text-choice'; Text = $Text })
            if ($fixture.FallbackDelivered -and $fixture.Kind -eq 'claude') { Add-DeliveryResult }
            [pscustomobject]@{ Delivered = $fixture.FallbackDelivered; ProcessId = 0; Detail = 'Synthetic native fallback boundary'; Wrote = $true }
        }
        function Send-CopilotSessionPrompt {
            param($SessionId, $Text, $ProcessId)
            $script:DeliveryFixture.UnexpectedInput++
            throw 'Completion must never override the terminal answer.'
        }
        function Invoke-BridgeConsoleSend {
            param($ProcessId, $Text, $Submit, $DelayMs)
            $script:DeliveryFixture.UnexpectedInput++
            throw 'This fixture completes through the actual transcript, not an extra native Enter.'
        }
        function New-DeliveryFixture {
            param(
                [string]$Kind,
                [string]$ResultKind = 'mismatch',
                [string]$Selection = 'No',
                [switch]$MultiField
            )
            $sid = [guid]::NewGuid().ToString()
            $directory = Join-Path $script:DecisionBridgeConfig.SessionStateRoot $sid
            [void][IO.Directory]::CreateDirectory($directory)
            $transcript = Join-Path $directory 'events.jsonl'
            [IO.File]::WriteAllText($transcript, '')
            $callId = "synthetic-$sid"
            $topics = Get-CopilotMqttTopics -SessionId $sid
            $session = [pscustomobject]@{ Kind = $Kind; SessionId = $sid; Transcript = $transcript; ProcessId = 0 }
            $script:DaemonLive = @{ $sid = $session }
            if ($Kind -eq 'copilot') {
                $properties = [ordered]@{
                    answer = [pscustomobject]@{ type = 'string'; title = 'Confirm'; enum = @('No', 'Not now'); default = 'Not now' }
                }
                if ($MultiField) { $properties.region = [pscustomobject]@{ type = 'string'; title = 'Region'; enum = @('East', 'West') } }
                $hook = [pscustomobject]@{
                    sessionId = $sid; cwd = $root; timestamp = 44; toolName = 'ask_user'
                    toolArgs = [pscustomobject]@{ message = 'Synthetic selection'; requestedSchema = [pscustomobject]@{ properties = [pscustomobject]$properties } }
                }
                & { Set-StrictMode -Off; Invoke-CopilotAskUserHook -HookEvent $hook } | Out-Null
                $start = @{ type = 'tool.execution_start'; timestamp = [DateTimeOffset]::Now.ToString('o'); data = @{ toolName = 'ask_user'; toolCallId = $callId } }
            }
            else {
                $questions = @([pscustomobject]@{ question = 'Confirm?'; header = 'Confirm'; options = @('No', 'Not now') })
                if ($MultiField) { $questions += [pscustomobject]@{ question = 'Region?'; header = 'Region'; options = @('East', 'West') } }
                Invoke-ClaudeAskHook -HookEvent ([pscustomobject]@{
                    session_id = $sid; transcript_path = $transcript; cwd = $root
                    tool_name = 'AskUserQuestion'; tool_use_id = $callId; tool_input = [pscustomobject]@{ questions = $questions }
                }) | Out-Null
                $start = @{ type = 'assistant'; timestamp = [DateTimeOffset]::Now.ToString('o'); message = @{
                    content = @(@{ type = 'tool_use'; id = $callId; name = 'AskUserQuestion' })
                } }
            }
            [IO.File]::AppendAllText($transcript, (($start | ConvertTo-Json -Depth 8 -Compress) + "`n"))
            $marker = Get-CopilotDecisionMarker -SessionId $sid -RequireReadable
            $recorded = if ($ResultKind -eq 'mismatch') { 'Not now' } else { $Selection }
            $content = if ($ResultKind -in @('missing', 'empty')) { '' }
                       elseif ($ResultKind -eq 'unsupported') { '{"unexpected":"shape"}' }
                       elseif ($Kind -eq 'copilot') {
                           if ($MultiField) { @{ answer = $recorded; region = 'East' } | ConvertTo-Json -Compress }
                           else { "User responded: $recorded" }
                       }
                       else {
                           $answer = '"Confirm?"="' + $recorded + '"'
                           if ($MultiField) { $answer += ', "Region?"="East"' }
                           "Your questions have been answered: $answer."
                       }
            # Where the answer sits is where Set-CopilotMqttDecision puts the controls:
            # in the field slots for anything published with fields, which is every
            # Copilot question and any multi-field Claude one, and on the main selector
            # for a lone Claude question, whose parser publishes its options there and
            # keeps the field only in the marker for the keystrokes.
            $usesSlots = $MultiField -or ($Kind -eq 'copilot')
            $ha = @{
                "select.$($topics.Node)_decision" = [pscustomobject]@{
                    state = $(if ($usesSlots) { 'Awaiting answer...' } else { $Selection })
                    attributes = [pscustomobject]@{
                        question = $marker.question; options = @($marker.choices)
                        decision_id = $marker.decisionId; multi_field = $usesSlots
                    }
                }
                "text.$($topics.Node)_reply" = [pscustomobject]@{ state = 'old reply' }
                # The retained reply payload as it stood when the question arrived.
                # The daemon records its identity as the baseline; only a different
                # one is an answer, so this one never is.
                "sensor.$($topics.Node)_reply_payload" = [pscustomobject]@{
                    state = 'armed-baseline'
                    attributes = [pscustomobject]@{ text = ''; images = @(); files = @() }
                }
                # No press yet. The press that answers is applied below, after the
                # baseline is recorded - which is the real order of events and the
                # only one in which a press means somebody pressed Send.
                "button.$($topics.Node)_submit" = [pscustomobject]@{ state = 'unknown' }
            }
            for ($index = 1; $index -le $script:CopilotMqttMaxFields; $index++) {
                $ha[(Get-CopilotMqttFieldEntityId -Node $topics.Node -Index $index)] = [pscustomobject]@{
                    state = $(if ($usesSlots -and $index -eq 1) { $Selection } elseif ($MultiField -and $index -eq 2) { 'East' } else { 'Idle' })
                }
            }
            $script:DeliveryFixture = [pscustomobject]@{
                Kind = $Kind; SessionId = $sid; CallId = $callId; Transcript = $transcript
                Topics = $topics; DecisionEntity = "select.$($topics.Node)_decision"; ReplyEntity = "text.$($topics.Node)_reply"
                State = @{ $sid = [pscustomobject]@{ Name = 'Synthetic'; Machine = 'TEST'; LastReply = 'old reply' } }
                Ha = $ha; Inputs = [Collections.Generic.List[object]]::new(); Activity = [Collections.Generic.List[string]]::new()
                ExpectedSelections = $(if ($MultiField) { @($Selection, 'East') } else { @($Selection) })
                UsesSlots = $usesSlots
                ResultKind = $ResultKind; Content = $content; ResultWritten = $false
                FormDelivered = $true; FallbackDelivered = $false; UnexpectedInput = 0
                DecisionReads = 0; TerminalOnRead = $false; CardClears = 0
            }
            # Arm, then press - in that order, which is the only one in which a press
            # is somebody pressing Send rather than something the card already held.
            $baselinePath = Get-CopilotDecisionBaselinePath -SessionId $sid -DecisionId ([string]$marker.decisionId)
            if (Test-Path -LiteralPath $baselinePath) { Remove-Item -LiteralPath $baselinePath -Force }
            if (-not (Set-CopilotDecisionMarkerBaseline -SessionId $sid -DecisionId ([string]$marker.decisionId) `
                -PayloadState 'present' -PayloadValue 'armed-baseline' -SubmitState 'absent' -SubmitValue '')) {
                throw "could not seed a baseline for $($marker.decisionId)"
            }
            $ha["button.$($topics.Node)_submit"].state = ([DateTimeOffset]$marker.armedAt).AddSeconds(1).ToString('o')
            $script:DeliveryFixture
        }
        function Invoke-DeliveryPass {
            Invoke-PendingDecisions -Headers @{} -State $script:DeliveryFixture.State -Live $script:DaemonLive
        }

        try {
            foreach ($kind in @('copilot', 'claude')) {
                foreach ($case in @(
                    @{ Result = 'matching'; Multi = $false; Selection = 'No' }
                    @{ Result = 'mismatch'; Multi = $false; Selection = 'No' }
                    @{ Result = 'unsupported'; Multi = $false; Selection = 'No' }
                    @{ Result = 'missing'; Multi = $false; Selection = 'No' }
                    @{ Result = 'empty'; Multi = $false; Selection = 'No' }
                    @{ Result = 'matching'; Multi = $false; Selection = 'Not now' }
                    @{ Result = 'matching'; Multi = $true; Selection = 'No' }
                    @{ Result = 'mismatch'; Multi = $true; Selection = 'No' }
                )) {
                    $fixture = New-DeliveryFixture -Kind $kind -ResultKind $case.Result -Selection $case.Selection -MultiField:$case.Multi
                    $label = "$kind $($case.Result), fields=$(if ($case.Multi) { 2 } else { 1 }), selected=$($case.Selection)"
                    $marker = Get-CopilotDecisionMarker -SessionId $fixture.SessionId -RequireReadable
                    $read = Read-DaemonDecisionAnswer -SessionId $fixture.SessionId -Marker $marker -State $fixture.State -Headers @{}
                    Test-That "$label reads the ordinary dashboard selection without seeding the marker" {
                        $read.IsChoice -and $read.Answer -ceq ($fixture.ExpectedSelections -join ' + ') -and
                            @($read.Selections).Count -eq $(if ($fixture.UsesSlots) { @($fixture.ExpectedSelections).Count } else { 0 }) -and
                            (-not $marker.PSObject.Properties['injectedSelections'] -or @($marker.injectedSelections).Count -eq 0)
                    }
                    Test-That "$label preserves the actual client hook identity" {
                        -not $marker.terminalOnly -and
                            $(if ($kind -eq 'copilot') { $marker.toolCallId -ceq '' } else { $marker.toolCallId -ceq $fixture.CallId })
                    }
                    Invoke-DeliveryPass
                    $delivered = Get-CopilotDecisionMarker -SessionId $fixture.SessionId -RequireReadable
                    Test-That "$label reaches the native boundary with the actual per-field selections and focus" {
                        $expectedPayload = if ($kind -eq 'copilot' -and $case.Selection -ceq 'No') { [string][char]27 + '[A' }
                                           elseif ($kind -eq 'claude' -and $case.Selection -ceq 'Not now') { [string][char]27 + '[B' }
                                           else { '' }
                        $fixture.Inputs.Count -eq 1 -and $fixture.Inputs[0].Route -ceq 'form' -and
                            ($fixture.Inputs[0].Selections -join '|') -ceq ($fixture.ExpectedSelections -join '|') -and
                            $fixture.Inputs[0].StoredBeforeInput -eq 0 -and $fixture.Inputs[0].Payloads[0].Payload -ceq $expectedPayload
                    }
                    Test-That "$label persists exactly the selections used by successful form delivery" {
                        $null -ne $delivered -and $delivered.injectedAnswer -ceq $read.Answer -and
                            @($delivered.injectedSelections).Count -eq @($fixture.ExpectedSelections).Count -and
                            ($delivered.injectedSelections -join '|') -ceq ($fixture.Inputs[0].Selections -join '|')
                    }
                    if (-not $fixture.ResultWritten) {
                        Invoke-DeliveryPass
                        Add-DeliveryResult
                    }
                    $expectedStatus = if ($case.Result -eq 'matching') { 'Matched' }
                                      elseif ($case.Result -eq 'mismatch') { 'Mismatch' } else { 'Unconfirmed' }
                    $ask = Get-DaemonAskUserState -Session $script:DaemonLive[$fixture.SessionId] -Marker $delivered
                    Test-That "$label uses the real client transcript with the expected $expectedStatus result" {
                        $ask.Started -and -not $ask.Pending -and
                            (Test-CopilotAnswerMatchesSelections -ResultContent $ask.ResultContent -Fields @($delivered.fields) `
                                -Selections $fixture.ExpectedSelections -Detailed).Status -ceq $expectedStatus
                    }
                    Invoke-DeliveryPass
                    $warnings = @($fixture.Activity | Where-Object { $_ -like 'Answer differs*' -or $_ -like 'Answer unconfirmed*' })
                    Test-That "$label completes with the expected verification and no competing correction input" {
                        $fixture.Inputs.Count -eq 1 -and $fixture.UnexpectedInput -eq 0 -and
                            $(if ($expectedStatus -ceq 'Matched') { $warnings.Count -eq 0 }
                              elseif ($expectedStatus -ceq 'Mismatch') { $warnings.Count -eq 1 -and $warnings[0] -ceq 'Answer differs - check the terminal' }
                              else { $warnings.Count -eq 1 -and $warnings[0] -ceq 'Answer unconfirmed - check the terminal' })
                    }
                    Test-That "$label retains real marker, card and reply cleanup" {
                        $null -eq (Get-CopilotDecisionMarker -SessionId $fixture.SessionId) -and $fixture.CardClears -eq 1 -and
                            $fixture.Ha[$fixture.DecisionEntity].state -ceq 'Idle' -and
                            $fixture.Ha[$fixture.ReplyEntity].state -ceq $script:DaemonConfig.ReplyBlankValue -and
                            $fixture.State[$fixture.SessionId].LastReply -ceq ''
                    }
                    Write-Host ('A19 delivery evidence: ' + ([ordered]@{
                        Kind = $kind; Result = $case.Result; Fields = @($marker.fields).Count
                        NativeAttempts = $fixture.Inputs.Count; StoredSelections = @($delivered.injectedSelections).Count
                        DirectMatcher = $expectedStatus; CompletionWarnings = $warnings
                    } | ConvertTo-Json -Compress))
                }
                foreach ($timing in @('before-pass', 'during-selector-read')) {
                    $fixture = New-DeliveryFixture -Kind $kind
                    if ($timing -eq 'before-pass') { Add-DeliveryResult } else { $fixture.TerminalOnRead = $true }
                    Invoke-DeliveryPass
                    Invoke-DeliveryPass
                    Test-That "$kind terminal answer $timing prevents input and removes the pending marker" {
                        # A form acknowledges the Send before it injects, and from the
                        # moment a single choice became a field that is every question
                        # - so the acknowledgement can land in the instant between the
                        # card being read and the terminal answer arriving. What must
                        # not happen is input, or a warning: nothing was delivered and
                        # nothing differs.
                        $fixture.ResultWritten -and $fixture.Inputs.Count -eq 0 -and $fixture.UnexpectedInput -eq 0 -and
                            $null -eq (Get-CopilotDecisionMarker -SessionId $fixture.SessionId) -and
                            $fixture.CardClears -eq 1 -and
                            @($fixture.Activity | Where-Object { $_ -notlike 'Sending answer*' }).Count -eq 0
                    }
                }
                foreach ($fallback in @($false, $true)) {
                    $fixture = New-DeliveryFixture -Kind $kind -ResultKind matching -MultiField
                    $fixture.FormDelivered = $false
                    $fixture.FallbackDelivered = $fallback
                    Invoke-DeliveryPass
                    $marker = Get-CopilotDecisionMarker -SessionId $fixture.SessionId -RequireReadable
                    Test-That "$kind failed form with fallback=$fallback never records unused per-field selections" {
                        $fixture.Inputs.Count -eq 2 -and $fixture.Inputs[1].Route -ceq 'text-choice' -and
                            (-not $marker.PSObject.Properties['injectedSelections'] -or @($marker.injectedSelections).Count -eq 0) -and
                            $fixture.UnexpectedInput -eq 0 -and
                            $(if ($fallback) { $marker.injectedAnswer -ceq 'No + East' } else { $marker.injectedAnswer -ceq '' })
                    }
                    if (-not $fixture.ResultWritten) { Add-DeliveryResult }
                    Invoke-DeliveryPass
                    Test-That "$kind fallback=$fallback keeps terminal cleanup without guessing selections from its result" {
                        $null -eq (Get-CopilotDecisionMarker -SessionId $fixture.SessionId) -and
                            $fixture.Inputs.Count -eq 2 -and $fixture.UnexpectedInput -eq 0 -and
                            @($fixture.Activity | Where-Object { $_ -like 'Answer differs*' -or $_ -like 'Answer unconfirmed*' }).Count -eq 0
                    }
                }
            }
        }
        finally {
            $script:DaemonLive = $previousLive
            $script:ClaudeAdapterLoaded = $previousClaudeLoaded
            $script:ClaudeStateRoot = $previousClaudeRoot
        }
    }
    $deliveryFailures = $script:Failures - $deliveryInitialFailures
    $deliveryChecks = $script:Checks - $deliveryInitialChecks
    Write-Host "A19 delivery assertions: $($deliveryChecks - $deliveryFailures) passed, $deliveryFailures failed."

    $a23InitialFailures = $script:Failures
    $a23InitialChecks = $script:Checks
    & {
        Write-Host '--- exact outage input through the real hook and null-return adapter ---'
        function New-A23Fixture {
            param([string]$SessionId, [string]$CallId)
            $script:OutageSessionId = $SessionId
            $directory = Join-Path $script:DecisionBridgeConfig.SessionStateRoot $SessionId
            [void][IO.Directory]::CreateDirectory($directory)
            $script:A23Topics = Get-CopilotMqttTopics -SessionId $SessionId
            $node = $script:A23Topics.Node
            $script:A23Ha = @{
                "select.${node}_decision" = [pscustomobject]@{
                    state = 'Idle'; attributes = [pscustomobject]@{ options = @('Idle'); question = '' }
                }
                "text.${node}_reply" = [pscustomobject]@{ state = ''; attributes = [pscustomobject]@{} }
                # What the reply card had retained when the question arrived. Its
                # identity is the baseline the daemon records; only a different one
                # is ever read as an answer.
                "sensor.${node}_reply_payload" = [pscustomobject]@{
                    state = 'armed-baseline'; attributes = [pscustomobject]@{ text = ''; images = @(); files = @() }
                }
                # Unpressed. Nothing on the card is an answer until this changes.
                "button.${node}_submit" = [pscustomobject]@{ state = 'unknown' }
            }
            $script:A23Messages = @{}
            $script:A23Inputs = [Collections.Generic.List[object]]::new()
            $script:A23Network = [Collections.Generic.List[object]]::new()
            $script:ProbeMarkerPresence = [Collections.Generic.List[bool]]::new()
            $script:A23ProbeMarkerBytes = ''
            $script:A23Reachable = $false
            $script:A23Fault = ''
            $transcript = Join-Path $directory 'events.jsonl'
            $session = [pscustomobject]@{ SessionId = $SessionId; Kind = 'copilot'; Transcript = $transcript }
            $script:DaemonLive = @{ $SessionId = $session }
            [pscustomobject]@{
                SessionId = $SessionId
                Session = $session
                State = @{ $SessionId = [pscustomobject]@{ Name = 'Synthetic'; Machine = 'TEST'; Status = 'working'; LastReply = '' } }
                Transcript = $transcript
                CallId = $CallId
                DecisionEntity = "select.${node}_decision"
                # Where a published choice is actually answered: its field slot, which
                # is what Set-CopilotMqttDecision puts every option list into now.
                FieldEntity = "select.${node}_f1"
                ReplyEntity = "text.${node}_reply"
                Topics = $script:A23Topics
            }
        }
        function Add-A23NetworkEvent {
            param([string]$Operation)
            $script:A23Network.Add([pscustomobject]@{
                Operation = $Operation
                MarkerPresent = ($null -ne (Get-CopilotDecisionMarker -SessionId $script:OutageSessionId))
            })
        }
        function Test-HomeAssistantReachable {
            param($TimeoutSec)
            Add-A23NetworkEvent -Operation 'probe'
            $script:ProbeMarkerPresence.Add($null -ne (Get-CopilotDecisionMarker -SessionId $script:OutageSessionId))
            $path = Get-CopilotDecisionMarkerPath -SessionId $script:OutageSessionId
            if (Test-Path -LiteralPath $path -PathType Leaf) { $script:A23ProbeMarkerBytes = [IO.File]::ReadAllText($path) }
            $script:A23Reachable
        }
        function Get-HomeAssistantHeaders { @{ Synthetic = 'fixture' } }
        function Get-HomeAssistantState {
            param([string]$EntityId, $Headers)
            Add-A23NetworkEvent -Operation 'state'
            if (-not $script:A23Ha.ContainsKey($EntityId)) { throw "Synthetic entity not found: $EntityId" }
            $script:A23Ha[$EntityId]
        }
        function Publish-CopilotMqttMessage {
            param([string]$Topic, [string]$Payload, $Headers, [switch]$Retain)
            Add-A23NetworkEvent -Operation 'mqtt'
            if ($script:A23Fault -eq 'publish') { throw 'Synthetic MQTT publication failure.' }
            $script:A23Messages[$Topic] = $Payload
            $data = $Payload | ConvertFrom-Json
            if ($Topic -match '/select/[^/]+/(decision|f\d+)/config$') {
                $script:A23Ha["select.$($data.unique_id)"] = [pscustomobject]@{
                    state = 'unknown'
                    attributes = [pscustomobject]@{ options = @($data.options); question = '' }
                }
            }
            elseif ($Topic -ceq $script:A23Topics.DecisionAttributes) {
                $entity = $script:A23Ha["select.$($script:A23Topics.Node)_decision"]
                $attributes = [ordered]@{ options = @($entity.attributes.options); question = '' }
                foreach ($property in $data.PSObject.Properties) { $attributes[$property.Name] = $property.Value }
                $entity.attributes = [pscustomobject]$attributes
            }
        }
        function Invoke-HomeAssistantService {
            param([string]$Domain, [string]$Service, $Headers, [hashtable]$Data)
            Add-A23NetworkEvent -Operation 'service'
            $entity = $script:A23Ha[[string]$Data.entity_id]
            if ($null -eq $entity) { throw "Synthetic entity not found: $($Data.entity_id)" }
            if ($Domain -eq 'select' -and $Service -eq 'select_option') {
                if ([string]$Data.option -notin @($entity.attributes.options)) { throw 'Synthetic option is not advertised.' }
                $entity.state = [string]$Data.option
            }
            elseif ($Domain -eq 'text' -and $Service -eq 'set_value') { $entity.state = [string]$Data.value }
            else { throw "Unexpected synthetic service: $Domain.$Service" }
        }
        function Set-CopilotMqttEntityIds { param($SessionId) }
        function Send-BridgeNotification {
            param($Title, $Message, $Headers)
            Add-A23NetworkEvent -Operation 'notification'
        }
        function Set-DaemonTransientActivity { param($SessionId, $Summary, $Extra, $Headers) }
        function Send-CopilotSessionForm {
            param($SessionId, $Fields, $Selections, $ProcessId)
            $script:A23Inputs.Add([pscustomobject]@{
                SessionId = $SessionId; Kind = 'form'; Fields = @($Fields); Selections = @($Selections)
            })
            [pscustomobject]@{ Delivered = $true; ProcessId = $ProcessId; Detail = 'Synthetic native delivery boundary'; Wrote = $true }
        }
        function Send-CopilotSessionPrompt {
            param($SessionId, $Text, $ProcessId)
            $script:A23Inputs.Add([pscustomobject]@{ SessionId = $SessionId; Kind = 'text'; Text = $Text })
            [pscustomobject]@{ Delivered = $true; ProcessId = $ProcessId; Detail = 'Synthetic native delivery boundary'; Wrote = $true }
        }
        function Send-CopilotSessionChoice {
            param($SessionId, $Text, $ChoiceCount, $ProcessId)
            throw 'Unexpected native text-choice fallback.'
        }
        function Write-A23QuestionStart {
            param($Fixture)
            [ordered]@{
                type = 'tool.execution_start'; timestamp = '2026-09-30T19:00:00-07:00'
                data = @{ toolName = 'ask_user'; toolCallId = $Fixture.CallId }
            } | ConvertTo-Json -Depth 5 -Compress | Set-Content -LiteralPath $Fixture.Transcript -Encoding utf8
        }
        function Add-A23QuestionResult {
            param($Fixture, [string]$Content)
            [ordered]@{
                type = 'tool.execution_complete'; timestamp = '2026-09-30T19:00:01-07:00'
                data = @{ toolCallId = $Fixture.CallId; result = @{ content = $Content } }
            } | ConvertTo-Json -Depth 5 -Compress | Add-Content -LiteralPath $Fixture.Transcript -Encoding utf8
        }
        $headers = @{}
        $fixture = New-A23Fixture -SessionId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' -CallId 'synthetic-choice-call'
        $hook = [pscustomobject]@{
            sessionId = $script:OutageSessionId
            cwd = $root
            toolArgs = [pscustomobject]@{
                message = 'Synthetic audit question'
                requestedSchema = [pscustomobject]@{ properties = [pscustomobject]@{
                    answer = [pscustomobject]@{ type = 'boolean' }
                } }
            }
        }
        $output = & { Set-StrictMode -Off; Invoke-CopilotAskUserHook -HookEvent $hook }
        $path = Get-CopilotDecisionMarkerPath -SessionId $script:OutageSessionId
        $marker = Get-CopilotDecisionMarker -SessionId $script:OutageSessionId
        Test-That 'the outage runs the reachability gate once and produces no hook output' {
            $script:ProbeMarkerPresence.Count -eq 1 -and $null -eq $output
        }
        Test-That 'a readable request marker exists before the first reachability probe' {
            $script:ProbeMarkerPresence.Count -eq 1 -and $script:ProbeMarkerPresence[0]
        }
        Test-That 'the outage retains one real marker rather than the audit zero markers' {
            (Test-Path -LiteralPath $path -PathType Leaf) -and $null -ne $marker
        }
        Test-That 'the recovered marker retains the no-ID dashboard-answerable contract' {
            $null -ne $marker -and [string]$marker.toolCallId -ceq '' -and
            -not $marker.terminalOnly -and $marker.mode -ceq 'multiple_choice'
        }
        Test-That 'an unreachable adapter performs no card publication or notification' {
            $script:A23Messages.Count -eq 0 -and $script:A23Network.Count -eq 1
        }

        Write-Host '--- the real daemon re-arms and answers the no-ID outage marker ---'
        Write-A23QuestionStart -Fixture $fixture
        $ask = Get-DaemonAskUserState -Session $fixture.Session -Marker $marker
        Test-That 'the unchanged transcript route observes a pending question without a hook ID' { $ask.Started -and $ask.Pending }
        Invoke-PendingDecisions -Headers $headers -State $fixture.State -Live $script:DaemonLive
        Test-That 'the actual publisher re-arms the card from the persisted outage marker' {
            $script:A23Ha[$fixture.DecisionEntity].state -ceq 'Awaiting answer...' -and
            $script:A23Ha[$fixture.DecisionEntity].attributes.question -ceq 'Synthetic audit question'
        }
        Test-That 'the re-armed card retains its decision ID, choice list and mode' {
            $attributes = $script:A23Ha[$fixture.DecisionEntity].attributes
            $attributes.PSObject.Properties['decision_id'] -and
            $attributes.decision_id -ceq "$($fixture.Topics.Node)-" -and
            (@($attributes.choices) -join '|') -ceq 'Yes|No' -and $attributes.mode -ceq 'multiple_choice'
        }
        Test-That 're-arming a placeholder does not inject an answer' { $script:A23Inputs.Count -eq 0 }
        $script:A23Ha[$fixture.FieldEntity].state = 'No'
        Invoke-PendingDecisions -Headers $headers -State $fixture.State -Live $script:DaemonLive
        Test-That 'a chosen option with no Send behind it is not delivered' { $script:A23Inputs.Count -eq 0 }
        $script:A23Ha["button.$($fixture.Topics.Node)_submit"].state = [DateTimeOffset]::Now.ToString('o')
        Invoke-PendingDecisions -Headers $headers -State $fixture.State -Live $script:DaemonLive
        Invoke-PendingDecisions -Headers $headers -State $fixture.State -Live $script:DaemonLive
        $delivered = Get-CopilotDecisionMarker -SessionId $fixture.SessionId
        Test-That 'the actual no-ID dashboard route delivers its choice exactly once' {
            $script:A23Inputs.Count -eq 1 -and $script:A23Inputs[0].Kind -ceq 'form' -and
            ($script:A23Inputs[0].Selections -join '|') -ceq 'No' -and
            ($script:A23Inputs[0].Fields[0].Options -join '|') -ceq 'Yes|No'
        }
        Test-That 'successful delivery is persisted without inventing a native hook ID' {
            $null -ne $delivered -and $delivered.injectedAnswer -ceq 'No' -and
            [string]$delivered.toolCallId -ceq '' -and $delivered.decisionId -ceq "$($fixture.Topics.Node)-" -and
            @($delivered.injectedSelections).Count -eq 1 -and $delivered.injectedSelections[0] -ceq 'No'
        }
        Add-A23QuestionResult -Fixture $fixture -Content 'User responded: false'
        Invoke-PendingDecisions -Headers $headers -State $fixture.State -Live $script:DaemonLive
        Test-That 'the matching transcript result removes the real outage marker after dashboard delivery' {
            $null -eq (Get-CopilotDecisionMarker -SessionId $fixture.SessionId) -and
            -not (Test-Path -LiteralPath $path -PathType Leaf) -and $script:A23Inputs.Count -eq 1
        }
        Test-That 'the actual cleanup publisher clears the card and reply box' {
            $script:A23Messages[$fixture.Topics.DecisionAttributes] -ceq '{}' -and
            $script:A23Ha[$fixture.DecisionEntity].state -ceq 'Idle' -and
            $script:A23Ha[$fixture.ReplyEntity].state -ceq $script:DaemonConfig.ReplyBlankValue
        }

        Write-Host '--- a terminal answer wins after no-ID outage recovery ---'
        $fixture = New-A23Fixture -SessionId 'b3000000-0000-4000-8000-000000000023' -CallId 'synthetic-terminal-call'
        $hook.sessionId = $fixture.SessionId
        $null = & { Set-StrictMode -Off; Invoke-CopilotAskUserHook -HookEvent $hook }
        Write-A23QuestionStart -Fixture $fixture
        Invoke-PendingDecisions -Headers $headers -State $fixture.State -Live $script:DaemonLive
        Test-That 'a second no-ID outage request is re-armed without a dashboard submission' {
            $script:A23Ha[$fixture.DecisionEntity].state -ceq 'Awaiting answer...' -and
            $null -ne (Get-CopilotDecisionMarker -SessionId $fixture.SessionId) -and $script:A23Inputs.Count -eq 0
        }
        Add-A23QuestionResult -Fixture $fixture -Content 'User responded: true'
        $script:A23Ha[$fixture.FieldEntity].state = 'No'
        $script:A23Ha["button.$($fixture.Topics.Node)_submit"].state = [DateTimeOffset]::Now.ToString('o')
        Invoke-PendingDecisions -Headers $headers -State $fixture.State -Live $script:DaemonLive
        Test-That 'a completed terminal answer prevents a competing dashboard choice from being delivered' {
            $script:A23Inputs.Count -eq 0 -and $null -eq (Get-CopilotDecisionMarker -SessionId $fixture.SessionId) -and
            $script:A23Ha[$fixture.DecisionEntity].state -ceq 'Idle'
        }

        Write-Host '--- no-ID freeform answering and completion before recovery ---'
        $fixture = New-A23Fixture -SessionId 'c3000000-0000-4000-8000-000000000023' -CallId 'synthetic-freeform-call'
        $freeHook = [pscustomobject]@{
            sessionId = $fixture.SessionId; timestamp = 23; cwd = $root; toolName = 'ask_user'
            toolArgs = [pscustomobject]@{ question = 'Synthetic freeform question' }
        }
        $null = & { Set-StrictMode -Off; Invoke-CopilotAskUserHook -HookEvent $freeHook }
        Write-A23QuestionStart -Fixture $fixture
        Invoke-PendingDecisions -Headers $headers -State $fixture.State -Live $script:DaemonLive
        Test-That 'the freeform outage request re-arms with the same timestamp-based decision ID' {
            $attributes = $script:A23Ha[$fixture.DecisionEntity].attributes
            $attributes.PSObject.Properties['decision_id'] -and
            $attributes.decision_id -ceq "$($fixture.Topics.Node)-23" -and $attributes.mode -ceq 'freeform'
        }
        $script:A23Ha[$fixture.ReplyEntity].state = 'Synthetic dashboard answer'
        Invoke-PendingDecisions -Headers $headers -State $fixture.State -Live $script:DaemonLive
        Invoke-PendingDecisions -Headers $headers -State $fixture.State -Live $script:DaemonLive
        Test-That 'the no-ID freeform dashboard route delivers once and clears its reply input' {
            $script:A23Inputs.Count -eq 1 -and $script:A23Inputs[0].Kind -ceq 'text' -and
            $script:A23Inputs[0].Text -ceq 'Synthetic dashboard answer' -and
            $script:A23Ha[$fixture.ReplyEntity].state -ceq $script:DaemonConfig.ReplyBlankValue
        }
        Add-A23QuestionResult -Fixture $fixture -Content 'Synthetic dashboard answer'
        Invoke-PendingDecisions -Headers $headers -State $fixture.State -Live $script:DaemonLive
        Test-That 'the freeform result clears its real marker and published question' {
            $null -eq (Get-CopilotDecisionMarker -SessionId $fixture.SessionId) -and
            $script:A23Messages[$fixture.Topics.DecisionAttributes] -ceq '{}' -and $script:A23Inputs.Count -eq 1
        }

        $fixture = New-A23Fixture -SessionId 'd3000000-0000-4000-8000-000000000023' -CallId 'synthetic-completed-call'
        $hook.sessionId = $fixture.SessionId
        $null = & { Set-StrictMode -Off; Invoke-CopilotAskUserHook -HookEvent $hook }
        Write-A23QuestionStart -Fixture $fixture
        Add-A23QuestionResult -Fixture $fixture -Content 'User responded: true'
        Invoke-PendingDecisions -Headers $headers -State $fixture.State -Live $script:DaemonLive
        Test-That 'a terminal result already present at recovery is cleaned up rather than re-armed' {
            $script:A23Messages.ContainsKey($fixture.Topics.DecisionAttributes) -and
            $script:A23Messages[$fixture.Topics.DecisionAttributes] -ceq '{}' -and
            $script:A23Ha[$fixture.DecisionEntity].state -ceq 'Idle' -and $script:A23Inputs.Count -eq 0 -and
            $null -eq (Get-CopilotDecisionMarker -SessionId $fixture.SessionId)
        }

        Write-Host '--- online hook and publication failure retain local-first ordering ---'
        $fixture = New-A23Fixture -SessionId 'e3000000-0000-4000-8000-000000000023' -CallId 'synthetic-online-call'
        $hook.sessionId = $fixture.SessionId
        $script:A23Reachable = $true
        $output = & { Set-StrictMode -Off; Invoke-CopilotAskUserHook -HookEvent $hook }
        $marker = Get-CopilotDecisionMarker -SessionId $fixture.SessionId
        Test-That 'the online hook still publishes the question, notifies and returns no native output' {
            $null -eq $output -and $script:A23Ha[$fixture.DecisionEntity].attributes.question -ceq 'Synthetic audit question' -and
            @($script:A23Network | Where-Object { $_.Operation -ceq 'notification' }).Count -eq 1
        }
        Test-That 'all online network boundaries observe the readable marker first' {
            $script:A23Network.Count -gt 1 -and @($script:A23Network | Where-Object { -not $_.MarkerPresent }).Count -eq 0
        }
        Test-That 'publication does not rewrite the marker created before the probe' {
            $null -ne $marker -and $script:A23ProbeMarkerBytes -cne '' -and
            [IO.File]::ReadAllText((Get-CopilotDecisionMarkerPath -SessionId $fixture.SessionId)) -ceq $script:A23ProbeMarkerBytes
        }
        Remove-CopilotDecisionMarker -SessionId $fixture.SessionId

        $fixture = New-A23Fixture -SessionId 'f3000000-0000-4000-8000-000000000023' -CallId 'synthetic-publish-failure-call'
        $hook.sessionId = $fixture.SessionId
        $script:A23Reachable = $true
        $script:A23Fault = 'publish'
        $failure = ''
        try { $null = & { Set-StrictMode -Off; Invoke-CopilotAskUserHook -HookEvent $hook } }
        catch { $failure = $_.Exception.Message }
        Test-That 'a real publisher transport failure keeps its existing exception behavior' { $failure -ceq 'Synthetic MQTT publication failure.' }
        Test-That 'publication failure leaves the real request recoverable without rewriting it' {
            $null -ne (Get-CopilotDecisionMarker -SessionId $fixture.SessionId) -and
            $script:A23ProbeMarkerBytes -cne '' -and
            [IO.File]::ReadAllText((Get-CopilotDecisionMarkerPath -SessionId $fixture.SessionId)) -ceq $script:A23ProbeMarkerBytes
        }
        $script:A23Fault = ''
        Write-A23QuestionStart -Fixture $fixture
        Invoke-PendingDecisions -Headers $headers -State $fixture.State -Live $script:DaemonLive
        Test-That 'the real daemon re-arms a request after the publication failure clears' {
            $script:A23Ha[$fixture.DecisionEntity].state -ceq 'Awaiting answer...' -and
            $script:A23Ha[$fixture.DecisionEntity].attributes.question -ceq 'Synthetic audit question'
        }
        Add-A23QuestionResult -Fixture $fixture -Content 'User responded: true'
        Invoke-PendingDecisions -Headers $headers -State $fixture.State -Live $script:DaemonLive
        Test-That 'publication-failure recovery also permits terminal cleanup without native injection' {
            $null -eq (Get-CopilotDecisionMarker -SessionId $fixture.SessionId) -and
            $script:A23Inputs.Count -eq 0 -and $script:A23Ha[$fixture.DecisionEntity].state -ceq 'Idle' -and
            $script:A23Messages.ContainsKey($fixture.Topics.DecisionAttributes) -and
            $script:A23Messages[$fixture.Topics.DecisionAttributes] -ceq '{}'
        }
    }
    $a23Failures = $script:Failures - $a23InitialFailures
    $a23Checks = $script:Checks - $a23InitialChecks
    Write-Host "A23 assertions: $($a23Checks - $a23Failures) passed, $a23Failures failed."

    $a07InitialFailures = $script:Failures
    $a07InitialChecks = $script:Checks
    & {
        Write-Host '--- A07 actual Codex generation and durable approval attempts ---'
        . (Join-Path $repo 'codex\hooks\codex-session.ps1')
        $script:CodexAdapterLoaded = $true

        function New-A07Fixture {
            param([string]$CaseName, [string]$Generation = 'generation-A', [string]$Choice = 'Deny')
            $directory = Join-Path $root "a07-$CaseName"
            [void][IO.Directory]::CreateDirectory($directory)
            $script:CodexStateRoot = Join-Path $directory 'codex'
            $script:DaemonConfig.LogFile = Join-Path $directory 'daemon.log'
            $script:DecisionBridgeConfig.LogFile = Join-Path $directory 'marker.log'
            $sid = 'a0700000-0000-4000-8000-000000000007'
            $script:A07Card = [pscustomobject]@{
                state = $Choice; attributes = [pscustomobject]@{ decision_id = $Generation }
            }
            $script:A07Inputs = [Collections.Generic.List[object]]::new()
            $script:A07Errors = [Collections.Generic.List[string]]::new()
            $script:A07ClearCount = 0
            $script:A07ClearFails = $false
            $script:A07NativeMode = 'delivered'
            $script:A07ReplaceAt = ''
            $script:A07ReplacementBytes = ''
            Write-CodexApprovalMarker -SessionId $sid -DecisionId $Generation -Question 'Synthetic approval'
            $path = Get-CodexApprovalMarkerPath -SessionId $sid
            $script:A07Fixture = [pscustomobject]@{
                Root = $directory; SessionId = $sid; Generation = $Generation
                CodexRoot = $script:CodexStateRoot; MarkerPath = $path
                OriginalBytes = [IO.File]::ReadAllText($path)
                State = @{ $sid = [pscustomobject]@{ Name = 'Synthetic'; Machine = 'TEST' } }
                Live = @{ $sid = [pscustomobject]@{ Kind = 'codex'; ProcessId = 0; Status = 'waiting' } }
            }
            $script:A07Fixture
        }
        function Set-A07Replacement {
            Write-CodexApprovalMarker -SessionId $script:A07Fixture.SessionId `
                -DecisionId 'generation-B' -Question 'Replacement synthetic approval'
            $script:A07ReplacementBytes = [IO.File]::ReadAllText($script:A07Fixture.MarkerPath)
            $script:A07Card = [pscustomobject]@{
                state = 'Deny'; attributes = [pscustomobject]@{ decision_id = 'generation-B' }
            }
        }
        function Get-HomeAssistantState {
            param($EntityId, $Headers)
            $snapshot = ConvertFrom-DecisionJson -Json (ConvertTo-Json -InputObject $script:A07Card -Depth 5 -Compress)
            if ($script:A07ReplaceAt -eq 'selector') {
                $script:A07ReplaceAt = ''
                Set-A07Replacement
            }
            $snapshot
        }
        function Send-CopilotSessionPrompt {
            param($SessionId, $Text, $ProcessId)
            $marker = Get-CodexApprovalMarker -SessionId $SessionId
            $script:A07Inputs.Add([pscustomobject]@{
                Text = $Text
                Generation = $(if ($null -ne $marker) { [string]$marker.DecisionId } else { '' })
                AttemptedBeforeInput = ($null -ne $marker -and $marker.PSObject.Properties['DeliveryAttempted'] -and
                    $marker.DeliveryAttempted -is [bool] -and $marker.DeliveryAttempted)
                Outcome = $(if ($null -ne $marker -and $marker.PSObject.Properties['DeliveryOutcome']) { $marker.DeliveryOutcome } else { '' })
            })
            if ($script:A07ReplaceAt -eq 'native') {
                $script:A07ReplaceAt = ''
                Set-A07Replacement
            }
            if ($script:A07NativeMode -eq 'throw') { throw 'Synthetic native outcome is unknown.' }
            [pscustomobject]@{
                Delivered = ($script:A07NativeMode -ne 'uncertain')
                ProcessId = 0
                Detail = 'Synthetic native input boundary; not confirmed approval'
            }
        }
        function Clear-CopilotMqttDecision {
            param($SessionId, $SessionName, $Machine, $Headers)
            $script:A07ClearCount++
            if ($script:A07ClearFails) { throw 'Synthetic dashboard-clear outage.' }
            $script:A07Card.state = 'Idle'
        }
        function Invoke-A07Pass {
            param([switch]$ObserveFailure)
            try {
                Invoke-PendingCodexApprovals -Headers @{} -State $script:A07Fixture.State -Live $script:A07Fixture.Live
            }
            catch {
                if (-not $ObserveFailure) { throw }
                $script:A07Errors.Add($_.Exception.Message)
                Write-Host 'INFO A07 observed an explicit failure; input and file effects are asserted separately.'
            }
        }

        foreach ($route in @('Approve', 'Deny')) {
            $fixture = New-A07Fixture -CaseName "route-$route" -Generation "route-$route" -Choice $route
            Invoke-A07Pass
            $key = if ($route -eq 'Approve') { 'y' } else { 'n' }
            Test-That "A07 matching-generation $route retains its positive native-input route" {
                $script:A07Inputs.Count -eq 1 -and $script:A07Inputs[0].Text -ceq $key -and
                $script:A07Inputs[0].Generation -ceq "route-$route"
            }
            Test-That "A07 $route is durably marked attempted, not confirmed, before native input begins" {
                $script:A07Inputs[0].AttemptedBeforeInput -and $script:A07Inputs[0].Outcome -ceq 'unconfirmed'
            }
            $script:A07Card.state = $route
            Invoke-A07Pass
            Test-That "A07 a repeated $route submission for an attempted generation is rejected" { $script:A07Inputs.Count -eq 1 }
        }

        $fixture = New-A07Fixture -CaseName 'clear-failure' -Generation 'synthetic-generation'
        $script:A07ClearFails = $true
        Invoke-A07Pass
        Test-That 'A07 the first same-generation Deny reaches native input despite a subsequent clear outage' {
            $script:A07Inputs.Count -eq 1 -and $script:A07Inputs[0].Text -ceq 'n' -and $script:A07ClearCount -eq 1
        }
        Invoke-A07Pass
        Test-That 'A07 a failed clear cannot replay one real pending marker on the next pass' { $script:A07Inputs.Count -eq 1 }
        Test-That 'A07 the still-pending approval retains local ownership after an input attempt' {
            $null -ne (Get-CodexApprovalMarker -SessionId $fixture.SessionId)
        }
        $beforeReplacement = $script:A07Inputs.Count
        Set-A07Replacement
        Invoke-A07Pass
        Test-That 'A07 a new legitimate generation is still answerable after an earlier attempt' {
            $script:A07Inputs.Count -eq $beforeReplacement + 1 -and
            $script:A07Inputs[-1].Generation -ceq 'generation-B' -and $script:A07Inputs[-1].Text -ceq 'n'
        }

        $fixture = New-A07Fixture -CaseName 'stale-card' -Generation 'synthetic-replacement'
        $script:A07Card.attributes.decision_id = 'synthetic-generation'
        Invoke-A07Pass
        Test-That 'A07 a retained old dashboard generation never supplies input to a replacement marker' { $script:A07Inputs.Count -eq 0 }
        Test-That 'A07 rejecting a stale card preserves the replacement marker bytes' {
            [IO.File]::ReadAllText($fixture.MarkerPath) -ceq $fixture.OriginalBytes
        }
        $fixture = New-A07Fixture -CaseName 'case-sensitive-generation' -Generation 'Generation-A'
        $script:A07Card.attributes.decision_id = 'generation-a'
        Invoke-A07Pass
        Test-That 'A07 generation comparison is ordinal rather than case-insensitive' {
            $script:A07Inputs.Count -eq 0 -and [IO.File]::ReadAllText($fixture.MarkerPath) -ceq $fixture.OriginalBytes
        }
        foreach ($invalid in @('missing-card-generation', 'missing-marker-generation', 'missing-session', 'invalid-attempt')) {
            $fixture = New-A07Fixture -CaseName $invalid
            if ($invalid -eq 'missing-card-generation') {
                $script:A07Card.attributes.PSObject.Properties.Remove('decision_id')
            }
            else {
                $invalidState = Get-CodexApprovalMarker -SessionId $fixture.SessionId
                if ($invalid -eq 'missing-marker-generation') { $invalidState.PSObject.Properties.Remove('DecisionId') }
                elseif ($invalid -eq 'missing-session') { $invalidState.PSObject.Properties.Remove('SessionId') }
                else { $invalidState | Add-Member -NotePropertyName DeliveryAttempted -NotePropertyValue 'uncertain' }
                $invalidState | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $fixture.MarkerPath -Encoding utf8
            }
            $unchanged = [IO.File]::ReadAllText($fixture.MarkerPath)
            Invoke-A07Pass
            Test-That "A07 $invalid fails closed without changing pending ownership" {
                $script:A07Inputs.Count -eq 0 -and [IO.File]::ReadAllText($fixture.MarkerPath) -ceq $unchanged
            }
        }

        $fixture = New-A07Fixture -CaseName 'replacement-before-claim'
        $script:A07ReplaceAt = 'selector'
        Invoke-A07Pass
        Test-That 'A07 replacement during the card read prevents stale-generation native input' { $script:A07Inputs.Count -eq 0 }
        Test-That 'A07 an old decision cannot overwrite the marker that replaced it before claiming' {
            [IO.File]::ReadAllText($fixture.MarkerPath) -ceq $script:A07ReplacementBytes -and
            (Get-CodexApprovalMarker -SessionId $fixture.SessionId).DecisionId -ceq 'generation-B'
        }

        $fixture = New-A07Fixture -CaseName 'replacement-during-native' -Choice 'Approve'
        $script:A07ReplaceAt = 'native'
        Invoke-A07Pass
        Test-That 'A07 an in-flight attempt preserves a newly published replacement marker' {
            $script:A07Inputs.Count -eq 1 -and $script:A07Inputs[0].Generation -ceq 'generation-A' -and
            [IO.File]::ReadAllText($fixture.MarkerPath) -ceq $script:A07ReplacementBytes
        }
        Test-That 'A07 completing the old attempt does not clear the replacement approval card' {
            $script:A07Card.state -ceq 'Deny' -and $script:A07Card.attributes.decision_id -ceq 'generation-B'
        }

        foreach ($nativeFailure in @('uncertain', 'throw')) {
            $fixture = New-A07Fixture -CaseName "native-$nativeFailure"
            $script:A07NativeMode = $nativeFailure
            $script:A07ClearFails = $true
            Invoke-A07Pass -ObserveFailure
            Test-That "A07 the $nativeFailure fixture reaches the native boundary exactly once initially" { $script:A07Inputs.Count -eq 1 }
            Invoke-A07Pass -ObserveFailure
            Test-That "A07 $nativeFailure input cannot silently re-arm the same approval" {
                $script:A07Inputs.Count -eq 1 -and $null -ne (Get-CodexApprovalMarker -SessionId $fixture.SessionId)
            }
            Test-That "A07 $nativeFailure input is not reported as delivered approval" {
                $log = if (Test-Path -LiteralPath $script:DaemonConfig.LogFile) { [IO.File]::ReadAllText($script:DaemonConfig.LogFile) } else { '' }
                $script:A07Inputs.Count -gt 0 -and $log -notmatch "approval '[^']+' delivered" -and
                ($script:A07Errors.Count -gt 0 -or $log -match 'FAILED')
            }
        }

        foreach ($invalidMarker in @('corrupt', 'empty', 'null', 'directory')) {
            $fixture = New-A07Fixture -CaseName "read-$invalidMarker"
            if ($invalidMarker -eq 'directory') {
                Remove-Item -LiteralPath $fixture.MarkerPath -Force
                [void][IO.Directory]::CreateDirectory($fixture.MarkerPath)
            }
            else {
                $contents = switch ($invalidMarker) { 'corrupt' { '{' } 'empty' { '' } 'null' { 'null' } }
                [IO.File]::WriteAllText($fixture.MarkerPath, $contents)
            }
            Test-That "A07 the actual best-effort reader returns null for a $invalidMarker marker" {
                $null -eq (Get-CodexApprovalMarker -SessionId $fixture.SessionId)
            }
            Invoke-A07Pass -ObserveFailure
            Test-That "A07 a real $invalidMarker marker failure is not permission for native input" {
                $script:A07Inputs.Count -eq 0 -and (Test-Path -LiteralPath $fixture.MarkerPath)
            }
        }

        $fixture = New-A07Fixture -CaseName 'persist-failure'
        $lock = $null
        $fileMode = $null
        $directoryMode = $null
        try {
            if ($IsWindows) {
                $lock = [IO.File]::Open($fixture.MarkerPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            }
            else {
                $fileMode = [IO.File]::GetUnixFileMode($fixture.MarkerPath)
                $directoryMode = [IO.File]::GetUnixFileMode($fixture.CodexRoot)
                [IO.File]::SetUnixFileMode($fixture.MarkerPath, [IO.UnixFileMode]::UserRead)
                [IO.File]::SetUnixFileMode($fixture.CodexRoot, ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserExecute))
            }
            $writeFailed = $false
            try { Write-CodexApprovalMarker -SessionId $fixture.SessionId -DecisionId 'must-not-write' -Question 'Synthetic blocked write' }
            catch { $writeFailed = $true }
            Test-That 'A07 the persistence-failure fixture is readable but rejects the actual marker writer' {
                $writeFailed -and (Get-CodexApprovalMarker -SessionId $fixture.SessionId).DecisionId -ceq 'generation-A' -and
                [IO.File]::ReadAllText($fixture.MarkerPath) -ceq $fixture.OriginalBytes
            }
            Invoke-A07Pass -ObserveFailure
            Test-That 'A07 inability to persist an attempt fails closed before native input' {
                $script:A07Inputs.Count -eq 0 -and [IO.File]::ReadAllText($fixture.MarkerPath) -ceq $fixture.OriginalBytes
            }
        }
        finally {
            if ($null -ne $lock) { $lock.Dispose() }
            if ($null -ne $directoryMode) { [IO.File]::SetUnixFileMode($fixture.CodexRoot, $directoryMode) }
            if ($null -ne $fileMode) { [IO.File]::SetUnixFileMode($fixture.MarkerPath, $fileMode) }
        }

        Write-Host '--- A07 fresh processes share only synthetic persisted approval state ---'
        $approvalChild = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$contextPath = Join-Path $env:AGENT_HA_BRIDGE_TEST_ROOT 'approval-context.json'
$context = Get-Content -LiteralPath $contextPath -Raw | ConvertFrom-Json
$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $context.Repository 'hooks\agent-bridge-daemon.ps1')
. (Join-Path $context.Repository 'codex\hooks\codex-session.ps1')
$context = Get-Content -LiteralPath $contextPath -Raw | ConvertFrom-Json
$script:CodexAdapterLoaded = $true
$script:CodexStateRoot = $context.CodexRoot
$script:DaemonConfig.LogFile = Join-Path $context.CaseRoot "$($context.Instance)-daemon.log"
$script:DecisionBridgeConfig.LogFile = Join-Path $context.CaseRoot "$($context.Instance)-marker.log"
[ordered]@{
    ProcessId = $PID
    Instance = [guid]::NewGuid().ToString('N')
    Offline = ($env:AGENT_HA_BRIDGE_OFFLINE_TEST -eq '1')
    NoOwnerToken = (-not $env:GH_TOKEN -and -not $env:GITHUB_TOKEN -and -not $env:AGENT_HA_AGENT_TOKEN)
} | ConvertTo-Json -Compress | Set-Content -LiteralPath $context.IdentityPath -Encoding utf8
function Get-HomeAssistantState {
    param($EntityId, $Headers)
    [pscustomobject]@{ state = 'Deny'; attributes = [pscustomobject]@{ decision_id = $context.Generation } }
}
function Send-CopilotSessionPrompt {
    param($SessionId, $Text, $ProcessId)
    [ordered]@{ ProcessId = $PID; Text = $Text } | ConvertTo-Json -Compress |
        Add-Content -LiteralPath $context.InputLog -Encoding utf8
    if ($context.NativeMode -eq 'crash') { [Environment]::Exit(37) }
    [pscustomobject]@{ Delivered = $true; ProcessId = 0; Detail = 'Synthetic native boundary only' }
}
function Clear-CopilotMqttDecision {
    param($SessionId, $SessionName, $Machine, $Headers)
    throw 'Synthetic dashboard-clear outage.'
}
$sid = $context.SessionId
$state = @{ $sid = [pscustomobject]@{ Name = 'Synthetic'; Machine = 'TEST' } }
$live = @{ $sid = [pscustomobject]@{ Kind = 'codex'; ProcessId = 0; Status = 'waiting' } }
Invoke-PendingCodexApprovals -Headers @{} -State $state -Live $live
exit 0
'@
        function Invoke-A07FreshProcess {
            param($Fixture, [string]$Instance, [string]$NativeMode = 'delivered')
            . (Join-Path $repo 'tests\runner-support.ps1')
            $sandbox = New-BridgeTestSandbox -ParentDirectory $Fixture.Root
            try {
                $context = [ordered]@{
                    Repository = $repo; CodexRoot = $Fixture.CodexRoot; CaseRoot = $Fixture.Root
                    SessionId = $Fixture.SessionId; Generation = $Fixture.Generation
                    Instance = $Instance; NativeMode = $NativeMode
                    IdentityPath = (Join-Path $Fixture.Root "$Instance-identity.json")
                    InputLog = (Join-Path $Fixture.Root 'native-input.jsonl')
                }
                $context | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $sandbox 'approval-context.json') -Encoding utf8
                $childPath = Join-Path $sandbox 'approval-fixture.ps1'
                $approvalChild | Set-Content -LiteralPath $childPath -Encoding utf8
                $start = New-BridgeTestProcessStartInfo -ScriptPath $childPath -Sandbox $sandbox -Group Offline
                $outcome = Invoke-BridgeTestProcess -StartInfo $start -TimeoutSeconds 30
                [IO.File]::WriteAllText((Join-Path $Fixture.Root "$Instance-output.log"), $outcome.Output)
                $identity = if (Test-Path -LiteralPath $context.IdentityPath) {
                    Get-Content -LiteralPath $context.IdentityPath -Raw | ConvertFrom-Json
                } else { $null }
                [pscustomobject]@{ ExitCode = $outcome.ExitCode; TimedOut = $outcome.TimedOut; Identity = $identity }
            }
            finally { Remove-Item -LiteralPath $sandbox -Recurse -Force }
        }

        foreach ($restartMode in @('clear-failure', 'crash')) {
            $fixture = New-A07Fixture -CaseName "restart-$restartMode"
            $nativeMode = if ($restartMode -eq 'crash') { 'crash' } else { 'delivered' }
            $first = Invoke-A07FreshProcess -Fixture $fixture -Instance 'first' -NativeMode $nativeMode
            $expectedExit = if ($restartMode -eq 'crash') { 37 } else { 0 }
            $inputLog = Join-Path $fixture.Root 'native-input.jsonl'
            $initialWrites = if (Test-Path -LiteralPath $inputLog) { @(Get-Content -LiteralPath $inputLog).Count } else { 0 }
            Test-That "A07 the $restartMode first process reaches native input with the expected termination" {
                -not $first.TimedOut -and $first.ExitCode -eq $expectedExit -and
                $null -ne $first.Identity -and $initialWrites -eq 1
            }
            $second = Invoke-A07FreshProcess -Fixture $fixture -Instance 'second'
            Test-That "A07 $restartMode recovery really executes in a new isolated process" {
                $null -ne $first.Identity -and $null -ne $second.Identity -and
                $first.Identity.ProcessId -ne $second.Identity.ProcessId -and
                $first.Identity.ProcessId -ne $PID -and $second.Identity.ProcessId -ne $PID -and
                $first.Identity.Instance -cne $second.Identity.Instance -and
                $first.Identity.Offline -and $second.Identity.Offline -and
                $first.Identity.NoOwnerToken -and $second.Identity.NoOwnerToken -and
                -not $second.TimedOut -and $second.ExitCode -eq 0
            }
            $writes = if (Test-Path -LiteralPath $inputLog) { @(Get-Content -LiteralPath $inputLog).Count } else { 0 }
            Test-That "A07 $restartMode persisted state prevents another native attempt after restart" {
                $writes -eq 1 -and $null -ne (Get-CodexApprovalMarker -SessionId $fixture.SessionId)
            }
            $observation = [ordered]@{
                Case = $restartMode
                FirstProcess = $(if ($first.Identity) { $first.Identity.ProcessId } else { $null })
                SecondProcess = $(if ($second.Identity) { $second.Identity.ProcessId } else { $null })
                FirstExit = $first.ExitCode; SecondExit = $second.ExitCode
                NativeAttempts = $writes; ExpectedAtMost = 1
                NativeClientOrHomeAssistantUsed = $false
            }
            Write-Host ("A07 restart evidence: " + ($observation | ConvertTo-Json -Compress))
        }
    }
    $a07Failures = $script:Failures - $a07InitialFailures
    $a07Checks = $script:Checks - $a07InitialChecks
    Write-Host "A07 assertions: $($a07Checks - $a07Failures) passed, $a07Failures failed."
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}

if ($script:Failures -gt 0) {
    Write-Host "`n$($script:Failures) failed"
    exit 1
}
Write-Host "`nall passed"
