#Requires -Version 7.0
<#
    Registration uncertainty through real readers, discovery, synchronization,
    retirement and factored startup cleanup. Only raw process/CLI and HA transports
    are simulated. No client, full initializer, fixture child or daemon loop runs.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
Assert-BridgeTestEnvironment -Required
. (Join-Path $PSScriptRoot 'test-dashboard.ps1') -PublicationFixturesOnly

$script:A14Checks = 0
$script:A14Groups = 0
$script:A14Rejected = [Collections.Generic.List[string]]::new()
$script:A14Requests = [Collections.Generic.List[object]]::new()
$script:A14Topics = @{}
$script:A14AllowedTopics = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$script:A14LegacyResultTopic = 'homeassistant/sensor/copilot_cli_bridge/new_session_result/config'
$script:A14States = @{}
$script:A14FieldSlots = @{}
$script:A14InputSelectStore = @()
$script:A14Processes = @()
$script:A14ProcessMode = 'normal'
$script:A14CommandMode = 'readable'
$script:A14CommandText = 'node @anthropic-ai/claude-code/index.js --synthetic-secret-do-not-log'
$script:A14PsExit = 0
$script:A14PsCalls = 0
$script:A14Guard = $null
$script:A14ActualWindows = $script:BridgeIsWindows
$expectedGroups = 25
$expectedChecks = 114
$primaryFailure = $null

function Test-A14 {
    param([string]$Name, [bool]$Condition)
    $script:A14Checks++
    if (-not $Condition -or $script:A14Rejected.Count) {
        [Console]::Out.WriteLine('A14-ASSERTION-FAILURE ' + ([ordered]@{
            Check = $script:A14Checks; Condition = $Condition; RejectedBoundaryCount = $script:A14Rejected.Count
        } | ConvertTo-Json -Compress))
        [Console]::Out.Flush()
        Write-Host "  FAIL  $Name; rejected boundaries=$($script:A14Rejected.Count)"
        throw "Registration isolation check failed: $Name"
    }
    Write-Host "  PASS  $Name"
}

function Invoke-A14Group {
    param([string]$Name, [scriptblock]$Body)
    $script:A14Groups++
    Write-Host "A14-GROUP $script:A14Groups $Name"
    & $Body
}

function Get-A14ValueShape {
    param([AllowNull()]$Value, [switch]$MapKeys, [string]$IdentityKind = '')
    $shape = [ordered]@{ Type = $null; Length = $null }
    if ($null -eq $Value) { return $shape }
    $shape.Type = $Value.GetType().FullName
    if ($Value -is [string] -or $Value -is [array]) { $shape.Length = $Value.Length }
    elseif ($Value -is [Collections.IDictionary]) { $shape.Length = $Value.Count }
    if ($MapKeys -and $Value -is [Collections.IDictionary]) {
        $knownKeys = @('topic', 'payload', 'qos', 'retain', 'entity_id', 'value', 'option', 'template',
            'type', 'id', 'url', 'res_type', 'resource_id', 'url_path', 'title', 'icon',
            'show_in_sidebar', 'require_admin', 'dashboard_id', 'config', 'force')
        $names = @($Value.Keys | Where-Object { $_ -is [string] -and $_ -cin $knownKeys })
        $otherKeys = @($Value.Keys | Where-Object { $_ -isnot [string] -or $_ -cnotin $knownKeys })
        $shape['TopLevelKeys'] = $names
        $shape['OtherKeyCount'] = $Value.Count - $names.Count
        $shape['OtherKeyShapes'] = @(for ($index = 0; $index -lt [Math]::Min(8, $otherKeys.Count); $index++) {
            Get-A14ValueShape -Value $otherKeys[$index]
        })
        $shape['OtherKeysTruncated'] = $otherKeys.Count -gt 8
        $fields = [ordered]@{}
        foreach ($key in $names) {
            $identity = if ($key -ceq 'entity_id') { 'entity' } elseif ($key -ceq 'topic') { 'topic' } else { '' }
            $fields[$key] = Get-A14ValueShape -Value $Value[$key] -IdentityKind $identity
        }
        $shape['Fields'] = $fields
    }
    if ($Value -is [string] -and $IdentityKind) {
        $nodePattern = 'agent_bridge_(?:1111111111114111|2222222222224222|3333333333334333|4444444444444444)'
        if ($IdentityKind -ceq 'entity') {
            $shape['FixtureMember'] = $script:A14States.ContainsKey($Value)
            if ($Value -cmatch "^(?:sensor|text|select|button)\.$nodePattern`_(?:status|activity|reply_payload|reply|decision|submit|stop)$") {
                $shape['SyntheticIdentity'] = $Value
            }
            elseif ($Value -cmatch "^select\.$nodePattern`_f[1-4]$" -and $script:A14FieldSlots.ContainsKey($Value)) {
                $shape['SyntheticIdentity'] = $Value
            }
        }
        elseif ($IdentityKind -ceq 'topic') {
            $shape['FixtureMember'] = $script:A14AllowedTopics.Contains($Value)
            if ($shape.FixtureMember -and $Value -ceq $script:A14LegacyResultTopic) {
                $shape['KnownTopic'] = $script:A14LegacyResultTopic
            }
            $nodeMatch = [regex]::Match($Value, "(?:^|/)($nodePattern)(?:/|$)")
            if ($nodeMatch.Success) {
                $shape['SyntheticNode'] = $nodeMatch.Groups[1].Value
                $safeTopicPattern = "^(?:homeassistant/(?:sensor|text|select|button)/$nodePattern/(?:status|activity|reply_payload|reply|decision|submit|stop)/config|copilot/cli/$nodePattern/(?:status|activity|reply|replypayload|decision|decisionpayload|submit|stop)/(?:state|attributes|set))$"
                if ($shape.FixtureMember -and $Value -cmatch $safeTopicPattern) { $shape['SyntheticIdentity'] = $Value }
            }
        }
    }
    $shape
}

function Get-A14RequestShape {
    param([string]$Boundary, $Method, $Uri, $ContentType, $Body, $Commands)
    $shape = [ordered]@{ Boundary = $Boundary }
    if ($Boundary -ceq 'REST') {
        $shape['Method'] = Get-A14ValueShape $Method
        if ($Method -is [string] -and $Method -imatch '^(?:GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS|CONNECT|TRACE)$') {
            $shape.Method['KnownValue'] = $Method
        }
        $shape['Uri'] = Get-A14ValueShape $Uri
        $shape['ContentType'] = Get-A14ValueShape $ContentType
        if ($ContentType -is [string] -and $ContentType -cin @('application/json', 'application/json; charset=utf-8')) {
            $shape.ContentType['KnownValue'] = $ContentType
        }
        $shape['Body'] = Get-A14ValueShape -Value $Body -MapKeys
        $shape['OriginRelation'] = 'not-an-absolute-URI'
        $parsedUri = $null
        if ($Uri -is [string] -and [uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$parsedUri)) {
            $shape['OriginRelation'] = 'other-origin'
            $shape['QueryPresent'] = -not [string]::IsNullOrEmpty($parsedUri.Query)
            $shape['UserInfoPresent'] = -not [string]::IsNullOrEmpty($parsedUri.UserInfo)
            if ($parsedUri.Scheme -ceq 'http' -and $parsedUri.Host -ceq 'publication.invalid' -and $parsedUri.Port -eq 8123) {
                $shape['OriginRelation'] = 'expected-origin'
                $shape['RouteKind'] = switch -CaseSensitive ($parsedUri.AbsolutePath) {
                    '/api/template' { 'template' }
                    '/api/states' { 'state-list' }
                    '/api/services/mqtt/publish' { 'mqtt-publish' }
                    '/api/services/text/set_value' { 'text-set-value' }
                    '/api/services/select/select_option' { 'select-select-option' }
                    default { 'other' }
                }
                if ($parsedUri.AbsolutePath.StartsWith('/api/states/', [StringComparison]::Ordinal)) {
                    $shape['RouteKind'] = 'state-item'
                    $shape['StateEntity'] = Get-A14ValueShape -Value $parsedUri.AbsolutePath.Substring('/api/states/'.Length) -IdentityKind entity
                }
            }
        }
    }
    elseif ($Boundary -ceq 'WebSocket') {
        $shape['OriginRelation'] = 'not-supplied-to-boundary'
        $shape['Commands'] = Get-A14ValueShape $Commands
        $commandRows = @()
        if ($null -ne $Commands) { $commandRows = @($Commands) }
        $shape['CommandCount'] = $commandRows.Count
        $shape['CommandsTruncated'] = $commandRows.Count -gt 8
        $knownTypes = @('config/entity_registry/list', 'lovelace/resources', 'lovelace/resources/create',
            'lovelace/resources/update', 'lovelace/dashboards/list', 'lovelace/dashboards/create',
            'lovelace/dashboards/delete', 'lovelace/config', 'lovelace/config/save', 'input_select/list')
        $shape['CommandShapes'] = @(for ($index = 0; $index -lt [Math]::Min(8, $commandRows.Count); $index++) {
            $command = $commandRows[$index]
            $commandShape = Get-A14ValueShape -Value $command -MapKeys
            if ($command -is [Collections.IDictionary] -and $command.Contains('type') -and
                $command.type -is [string] -and $command.type -cin $knownTypes) {
                $commandShape['KnownCommandType'] = $command.type
            }
            $commandShape
        })
    }
    $shape
}

function Stop-A14Boundary {
    param([string]$Reason, [Collections.IDictionary]$Shape = @{ Boundary = 'unspecified' })
    # Ordinary producer catches consumed thirteen rejections before the old latch check.
    try {
        $script:A14Rejected.Add($Reason)
        if ($script:A14Rejected.Count -eq 1) {
            [Console]::Out.WriteLine('A14-BOUNDARY-REJECTION ' + ([ordered]@{
                Reason = $Reason; Group = $script:A14Groups; Checks = $script:A14Checks
                RejectedBoundaryCount = $script:A14Rejected.Count; Shape = $Shape; ExitCode = 37
            } | ConvertTo-Json -Depth 8 -Compress))
            [Console]::Out.Flush()
        }
    }
    finally { exit 37 }
}

function Get-Process {
    [CmdletBinding()]
    param([string[]]$Name, [int[]]$Id)
    if ($script:A14ProcessMode -eq 'guard') { throw [IO.IOException]::new('Synthetic outer boundary', $script:A14Guard.Exception) }
    $rows = @($script:A14Processes)
    if ($PSBoundParameters.ContainsKey('Name')) {
        $rows = @($rows | Where-Object { $_.ProcessName -cin $Name })
    }
    if ($PSBoundParameters.ContainsKey('Id')) { $rows = @($rows | Where-Object { $_.Id -in $Id }) }
    if ($PSBoundParameters.ContainsKey('Id') -and $script:A14ProcessMode -eq 'disappear-on-id') { $rows = @() }
    if ($script:A14ProcessMode -eq 'denied') { $rows = @() }
    if ($script:A14ProcessMode -in @('partial', 'denied')) {
        foreach ($row in $rows) { $row }
        $PSCmdlet.WriteError([Management.Automation.ErrorRecord]::new(
            [UnauthorizedAccessException]::new('Synthetic denied inventory'),
            'SyntheticProcessInventoryDenied', [Management.Automation.ErrorCategory]::PermissionDenied, $null))
        return
    }
    if ($rows.Count -eq 0 -and ($PSBoundParameters.ContainsKey('Name') -or $PSBoundParameters.ContainsKey('Id'))) {
        $errorId = if ($PSBoundParameters.ContainsKey('Id')) { 'NoProcessFoundForGivenId' } else { 'NoProcessFoundForGivenName' }
        $PSCmdlet.WriteError([Management.Automation.ErrorRecord]::new(
            [ArgumentException]::new('Synthetic specifically absent process'),
            $errorId, [Management.Automation.ErrorCategory]::ObjectNotFound, $null))
        return
    }
    foreach ($row in $rows) { $row }
}

function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName, [string]$Filter)
    if ($ClassName -cne 'Win32_Process' -or $Filter -notmatch '^ProcessId=\d+$') { Stop-A14Boundary 'CIM query shape' }
    if ($script:A14CommandMode -eq 'denied') {
        $PSCmdlet.WriteError([Management.Automation.ErrorRecord]::new(
            [UnauthorizedAccessException]::new('Synthetic denied command query'),
            'SyntheticCommandDenied', [Management.Automation.ErrorCategory]::PermissionDenied, $null))
        return
    }
    if ($script:A14CommandMode -eq 'absent') { return }
    [pscustomobject]@{ CommandLine = $(if ($script:A14CommandMode -eq 'empty') { '' } else { $script:A14CommandText }) }
}

function Invoke-CopilotHaWebSocket {
    param([hashtable[]]$Commands)
    $shape = [ordered]@{ Boundary = 'WebSocket' }
    try {
        $shape = Get-A14RequestShape -Boundary WebSocket -Commands $Commands
        if ($null -ne $Commands -and $Commands.Count -eq 1 -and $null -ne $Commands[0] -and $Commands[0].Count -eq 1) {
            $keys = @($Commands[0].Keys)
            if ($keys.Count -eq 1 -and $keys[0] -is [string] -and $keys[0] -ceq 'type' -and
                $Commands[0].type -is [string] -and $Commands[0].type -ceq 'input_select/list') {
                # The caller indexes result[0] even when its selector list is empty.
                $selectorResults = New-Object object[] 1
                $selectorResults[0] = @($script:A14InputSelectStore)
                [Console]::Out.WriteLine('A14-SELECTOR-LIST ' + ([ordered]@{
                    Command = 'input_select/list'; CommandCount = $Commands.Count
                    ResultCount = $selectorResults.Count; SelectorCount = $selectorResults[0].Count
                    Group = $script:A14Groups; Checks = $script:A14Checks
                } | ConvertTo-Json -Compress))
                [Console]::Out.Flush()
                return ,$selectorResults
            }
        }
        Write-Output -NoEnumerate (Invoke-TestPublicationCommands -Commands $Commands)
    }
    catch {
        $shape['ExceptionType'] = $_.Exception.GetType().FullName
        Stop-A14Boundary 'WebSocket command' -Shape $shape
    }
}

function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $ContentType, $Body, $TimeoutSec)
    $shape = [ordered]@{ Boundary = 'REST' }
    try {
        $shape = Get-A14RequestShape -Boundary REST -Method $Method -Uri $Uri -ContentType $ContentType -Body $Body
        $shape['UnboundArgumentCount'] = $args.Count
        if ($args.Count -or $Method -isnot [string] -or $Uri -isnot [string]) { Stop-A14Boundary 'REST arguments' -Shape $shape }
        if ($Method -ceq 'Post' -and $Uri -ceq 'http://publication.invalid:8123/api/template' -and
            $ContentType -ceq 'application/json' -and $Body -is [string]) {
            try { $request = $Body | ConvertFrom-Json -AsHashtable }
            catch { Stop-A14Boundary 'template JSON' -Shape $shape }
            $shape['ParsedBody'] = Get-A14ValueShape -Value $request -MapKeys
            if ($request -isnot [Collections.IDictionary] -or $request.Count -ne 1 -or
                -not $request.Contains('template') -or $request.template -cne $script:DaemonBridgeStatesTemplate) { Stop-A14Boundary 'template shape' -Shape $shape }
            return (ConvertTo-Json -InputObject @($script:A14States.Values) -Depth 12 -Compress)
        }
        if ($Method -ceq 'Get' -and $Uri -ceq 'http://publication.invalid:8123/api/states') {
            return ,@($script:A14States.Values)
        }
        if ($Method -ceq 'Get' -and $Uri.StartsWith('http://publication.invalid:8123/api/states/', [StringComparison]::Ordinal)) {
            $id = $Uri.Substring('http://publication.invalid:8123/api/states/'.Length)
            # Every reconcile reads the pairing helper (docs/fleet-pairing.md). Answered
            # here rather than seeded into A14States, which the state-list reads return
            # whole: the helper's id begins agent_bridge_, so seeding it would change what
            # those reads count. Empty is what it holds whenever no pairing is under way.
            if ($id -ceq 'input_text.agent_bridge_pairing') {
                return [pscustomobject]@{ entity_id = $id; state = ''; attributes = [pscustomobject]@{} }
            }
            if (-not $script:A14States.ContainsKey($id)) { Stop-A14Boundary 'unlisted state read' -Shape $shape }
            return $script:A14States[$id]
        }
        if ($Method -cne 'Post' -or $ContentType -cne 'application/json; charset=utf-8' -or $Body -isnot [byte[]]) {
            Stop-A14Boundary 'REST route or encoding' -Shape $shape
        }
        try { $data = [Text.UTF8Encoding]::new($false, $true).GetString($Body) | ConvertFrom-Json -AsHashtable }
        catch { Stop-A14Boundary 'service JSON' -Shape $shape }
        $shape['ParsedBody'] = Get-A14ValueShape -Value $data -MapKeys
        if ($data -isnot [Collections.IDictionary]) { Stop-A14Boundary 'service object shape' -Shape $shape }
        $legacyResultCleanup = $data.Contains('topic') -and $data.topic -is [string] -and
            [StringComparer]::OrdinalIgnoreCase.Equals($data.topic, $script:A14LegacyResultTopic)
        if ($legacyResultCleanup) {
            if ($Uri -cne 'http://publication.invalid:8123/api/services/mqtt/publish' -or $data.Count -ne 4 -or
                -not ($data.Keys -ccontains 'topic') -or -not ($data.Keys -ccontains 'payload') -or
                -not ($data.Keys -ccontains 'qos') -or -not ($data.Keys -ccontains 'retain') -or
                -not [StringComparer]::Ordinal.Equals($data.topic, $script:A14LegacyResultTopic) -or $data.payload -isnot [string] -or $data.payload.Length -ne 0 -or
                ($data.qos -isnot [int] -and $data.qos -isnot [long]) -or $data.qos -ne 1 -or
                $data.retain -isnot [bool] -or -not $data.retain) {
                Stop-A14Boundary 'legacy result cleanup shape' -Shape $shape
            }
        }
        # A declared field must not fall through to the looser primary-control branch.
        if ($data.Contains('entity_id') -and $data.entity_id -is [string] -and $script:A14FieldSlots.ContainsKey($data.entity_id)) {
            $fieldSlot = $script:A14FieldSlots[$data.entity_id]
            if ($Uri -cne 'http://publication.invalid:8123/api/services/select/select_option' -or $data.Count -ne 2 -or
                -not ($data.Keys -ccontains 'entity_id') -or -not ($data.Keys -ccontains 'option') -or
                $data.entity_id -cne $fieldSlot.EntityId -or $data.option -isnot [string] -or $data.option -cne 'Idle') {
                Stop-A14Boundary 'field reset shape' -Shape $shape
            }
            if (-not $script:A14States.ContainsKey($fieldSlot.EntityId)) { Stop-A14Boundary 'field reset state' -Shape $shape }
            $fieldState = $script:A14States[$fieldSlot.EntityId]
            $fieldOptions = @($fieldState.attributes.options)
            if ($fieldState.entity_id -isnot [string] -or $fieldState.entity_id -cne $fieldSlot.EntityId -or
                $fieldState.state -isnot [string] -or $fieldState.state -cnotin @('unknown', 'Idle') -or
                $fieldState.attributes.options -isnot [array] -or $fieldOptions.Count -ne 1 -or
                $fieldOptions[0] -isnot [string] -or $fieldOptions[0] -cne 'Idle') {
                Stop-A14Boundary 'field reset state' -Shape $shape
            }
            $fieldState.state = 'Idle'
            [Console]::Out.WriteLine('A14-FIELD-RESET ' + ([ordered]@{
                EntityId = $fieldSlot.EntityId; Slot = $fieldSlot.Slot; Option = 'Idle'
                Group = $script:A14Groups; Checks = $script:A14Checks
            } | ConvertTo-Json -Compress))
            [Console]::Out.Flush()
            return @()
        }
        if ($Uri -ceq 'http://publication.invalid:8123/api/services/mqtt/publish') {
            if (-not $data.Contains('topic') -or -not $data.Contains('payload') -or -not $data.Contains('qos') -or -not $data.Contains('retain') -or
                $data.topic -isnot [string] -or -not $script:A14AllowedTopics.Contains($data.topic) -or
                $data.payload -isnot [string] -or $data.qos -ne 1 -or $data.retain -isnot [bool]) {
                Stop-A14Boundary 'MQTT shape or topic' -Shape $shape
            }
            $script:A14Requests.Add([pscustomobject]@{ Topic = $data.topic; Payload = $data.payload; Retain = $data.retain })
            $script:A14Topics[$data.topic] = $data.payload
            if ($data.topic -match '^copilot/cli/(agent_bridge_[a-z0-9]+)/status/state$') {
                $script:A14States["sensor.$($Matches[1])_status"].state = $data.payload
            }
            if ($legacyResultCleanup) {
                [Console]::Out.WriteLine('A14-LEGACY-RESULT-CLEANUP ' + ([ordered]@{
                    Topic = $script:A14LegacyResultTopic; Payload = ''; Qos = 1; Retain = $true
                    Group = $script:A14Groups; Checks = $script:A14Checks
                } | ConvertTo-Json -Compress))
                [Console]::Out.Flush()
            }
            return @()
        }
        if ($Uri -cin @('http://publication.invalid:8123/api/services/text/set_value',
                'http://publication.invalid:8123/api/services/select/select_option') -and
            $data.Contains('entity_id') -and $data.entity_id -is [string] -and $script:A14States.ContainsKey($data.entity_id)) {
            $value = if ($data.Contains('value')) { $data.value } else { $data.option }
            if ($value -isnot [string]) { Stop-A14Boundary 'entity value type' -Shape $shape }
            $script:A14States[$data.entity_id].state = $value
            return @()
        }
        Stop-A14Boundary 'unlisted service' -Shape $shape
    }
    catch {
        $shape['ExceptionType'] = $_.Exception.GetType().FullName
        Stop-A14Boundary 'REST unexpected exception' -Shape $shape
    }
}

function Write-A14Observation {
    param([string]$Name, [AllowNull()]$Discovery = $null)
    $files = @($script:A14DataPaths | Where-Object { [IO.File]::Exists($_) })
    if ($files.Count -gt 12 -or @($files | Where-Object { [IO.FileInfo]::new($_).Length -gt 8192 }).Count) {
        throw 'The synthetic input file/count budget was exceeded.'
    }
    $marker = if ([IO.File]::Exists($script:A14Marker)) { (Get-FileHash -LiteralPath $script:A14Marker -Algorithm SHA256).Hash } else { $null }
    [Console]::Out.WriteLine('A14-OBSERVATION ' + (@{
        case = $Name; stateIds = @($script:A14State.Keys); pendingRetire = @($script:DaemonPendingRetire)
        positiveLive = $(if ($Discovery) { @($Discovery.Live.Keys) } else { @() })
        complete = $(if ($Discovery) { $Discovery.Complete } else { $null })
        markerHash = $marker; rejectedBoundaries = $script:A14Rejected.Count; inputFiles = $files.Count
        persistedStateHash = (Get-FileHash -LiteralPath $script:DaemonConfig.StateFile -Algorithm SHA256).Hash
        emptyPublications = @($script:A14Requests | Where-Object { $_.Payload -ceq '' } | ForEach-Object Topic)
    } | ConvertTo-Json -Depth 8 -Compress))
}

function Write-A14Json {
    param([string]$Path, [object]$Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 10 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 8192) { throw 'Synthetic record exceeds the reviewed 8KiB limit.' }
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Get-A14RegistrationPath {
    param([string]$Slot)
    $kind = $script:A14Kinds[$Slot]
    $root = if ($kind -eq 'claude') { Get-ClaudeStateRoot } else { Get-CodexStateRoot }
    $key = if ($kind -eq 'claude') { Get-ClaudeSafeSessionKey $script:A14Ids[$Slot] } else { Get-CodexSafeSessionKey $script:A14Ids[$Slot] }
    Join-Path $root "$key.json"
}

function Write-A14Registration {
    param([string]$Slot, [switch]$Ended, [int]$ProcessId = -1)
    $pidValue = if ($ProcessId -ge 0) { $ProcessId } else { $script:A14Pids[$Slot] }
    $record = [ordered]@{
        SessionId = $script:A14Ids[$Slot]; ProcessId = $pidValue
        TranscriptPath = $script:A14Transcripts[$Slot]; WorkingDirectory = $script:A14Root
        Updated = [DateTimeOffset]::Now.ToString('o')
    }
    if ($script:A14Kinds[$Slot] -eq 'claude') {
        $record.HookStatus = 'working'; $record.HookStatusAt = [DateTimeOffset]::Now.ToString('o')
    }
    else {
        $record.Model = ''; $record.Status = 'working'; $record.Activity = 'Working'; $record.Ended = [bool]$Ended
    }
    Write-A14Json -Path (Get-A14RegistrationPath $Slot) -Value $record
}

function Add-A14Message {
    param([string]$Slot, [string]$Text)
    $line = if ($script:A14Kinds[$Slot] -eq 'claude') {
        @{ type = 'assistant'; message = @{ content = $Text } }
    } else {
        @{ type = 'response_item'; payload = @{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = $Text }) } }
    }
    [IO.File]::AppendAllText($script:A14Transcripts[$Slot], (($line | ConvertTo-Json -Depth 8 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
}

function Reset-A14Records {
    param([string]$Kind)
    foreach ($path in $script:A14DataPaths) { [IO.File]::Delete($path) }
    $script:A14Kinds = @{ A = $Kind; B = $Kind; C = $(if ($Kind -eq 'claude') { 'codex' } else { 'claude' }); D = $Kind }
    $script:A14Processes = @('A', 'B', 'C' | ForEach-Object {
        [pscustomobject]@{ Id = $script:A14Pids[$_]; ProcessName = $script:A14Kinds[$_]; StartTime = [datetime]::UtcNow.AddHours(-2) }
    })
    $script:A14ProcessMode = 'normal'
    $script:BridgeIsWindows = $script:A14ActualWindows
    $script:DaemonRegistrationStamps = @{}
    $script:ClaudeRegistrationPaths = @{}
    $script:DaemonOwnerCatalogue = @{}
    $script:DaemonPendingRetire = @()
    $script:DaemonSessionCleanupPending = @{}
    $script:DaemonStateLastWritten = $null
    $script:DaemonGlobalSignature = ''
    $script:DaemonDashboardSignature = $null
    $script:DaemonGlobalLastPublish = [DateTimeOffset]::MinValue
    $script:DaemonPeerCache = $null
    $script:DaemonStatesCache = $null
    $state = @{}
    foreach ($slot in @('A', 'B', 'C')) {
        Write-A14Registration $slot
        Add-A14Message $slot 'initial'
        $state[$script:A14Ids[$slot]] = [pscustomobject]@{
            Name = "$($script:A14Kinds[$slot]): $slot"; Machine = 'FIXTURE'; Kind = $script:A14Kinds[$slot]
            Status = 'idle'; Offset = 0L; LastMessage = 'previous'; LastResponse = 'previous'
            LastReasoning = ''; LastMessageIsThinking = $false; LastHistory = @()
        }
    }
    Write-DaemonState -State $state
    $script:A14State = Read-DaemonState
    Write-CopilotDecisionMarker -SessionId $script:A14Ids.A -DecisionId 'held-question' -Question 'Synthetic question' -Mode freeform
    $script:A14MarkerHash = (Get-FileHash -LiteralPath $script:A14Marker -Algorithm SHA256).Hash
    [IO.File]::WriteAllText($script:DaemonConfig.LegacyCleanupMarker, 'completed-before-fixture')
    $script:A14Requests.Clear()
    $script:A14Topics.Clear()
}

function Invoke-A14Reconcile {
    $logBefore = if ([IO.File]::Exists($script:DaemonConfig.LogFile)) { [IO.File]::ReadAllText($script:DaemonConfig.LogFile).Length } else { 0 }
    Invoke-DaemonReconcile -Headers @{} -State $script:A14State
    $log = if ([IO.File]::Exists($script:DaemonConfig.LogFile)) { [IO.File]::ReadAllText($script:DaemonConfig.LogFile) } else { '' }
    if ($log.Length -gt $logBefore -and $log.Substring($logBefore) -match 'reconcile failed:') {
        throw 'The actual reconciliation aborted before its consumer/persistence boundary.'
    }
    $persisted = Read-DaemonState
    if ($persisted.Count -ne $script:A14State.Count) { throw 'The actual reconcile did not persist its state set.' }
    foreach ($id in $script:A14State.Keys) {
        if (-not $persisted.ContainsKey($id) -or $persisted[$id].Status -cne $script:A14State[$id].Status -or
            [long]$persisted[$id].Offset -ne [long]$script:A14State[$id].Offset) {
            throw 'The actual reconcile did not persist the observed session state.'
        }
    }
    Write-A14Observation -Name 'actual reconcile' -Discovery $script:DaemonDiscoverySnapshot
    $script:DaemonDiscoverySnapshot
}

function Test-A14HeldOwner {
    param([string]$Name, $Discovery)
    $id = $script:A14Ids.A
    Test-A14 "${Name}: A remains state but is not positive-live" (
        $script:A14State.ContainsKey($id) -and -not $Discovery.Live.ContainsKey($id) -and -not $Discovery.Complete)
    Test-A14 "${Name}: A decision ownership bytes remain" (
        [IO.File]::Exists($script:A14Marker) -and (Get-FileHash -LiteralPath $script:A14Marker -Algorithm SHA256).Hash -ceq $script:A14MarkerHash)
    $node = Get-CopilotMqttNodeId -SessionId $id
    Test-A14 "${Name}: no A entity or retained state was withdrawn" (
        @($script:A14Requests | Where-Object { $_.Payload -ceq '' -and $_.Topic.Split('/') -ccontains $node }).Count -eq 0)
}

Initialize-TestPublicationStore
$script:A14Root = Join-Path $script:BridgeInstallContext.RuntimeRoot 'registration-isolation'
[void][IO.Directory]::CreateDirectory($script:A14Root)
$config = Get-Content -LiteralPath $script:BridgeInstallContext.ConfigPath -Raw | ConvertFrom-Json -AsHashtable
$config.clients = @('claude', 'codex')
$config.autoConfigureClients = $false
$config.updates = @{ checkForUpdates = $false }
$config.newSession = @{ enabled = $false; shareResumable = $false }
foreach ($client in @('copilot', 'agency', 'claude', 'codex')) { $config.newSession["${client}Path"] = Join-Path $script:A14Root "absent-$client" }
Write-BridgeSecretFile -Path $script:BridgeInstallContext.ConfigPath -Content ($config | ConvertTo-Json -Depth 12)
$script:BridgeUserConfig = Get-BridgeUserConfig
. (Join-Path $PSScriptRoot '..\claude\hooks\claude-session.ps1')
. (Join-Path $PSScriptRoot '..\claude\hooks\claude-transcript.ps1')
. (Join-Path $PSScriptRoot '..\codex\hooks\codex-session.ps1')
. (Join-Path $PSScriptRoot '..\codex\hooks\codex-transcript.ps1')
$script:ClaudeAdapterLoaded = $true
$script:CodexAdapterLoaded = $true
$script:DaemonConfig.StateFile = Join-Path $script:A14Root 'state.json'
$script:DaemonConfig.LogFile = Join-Path $script:A14Root 'daemon.log'
$script:DaemonConfig.LegacyCleanupMarker = Join-Path $script:A14Root 'legacy.marker'
$script:A14Ids = @{
    A = '11111111-1111-4111-8111-111111111111'; B = '22222222-2222-4222-8222-222222222222'
    C = '33333333-3333-4333-8333-333333333333'; D = '44444444-4444-4444-8444-444444444444'
}
$script:A14Pids = @{ A = 81001; B = 81002; C = 81003; D = 81004 }
$script:A14Transcripts = @{}
foreach ($slot in @('A', 'B', 'C', 'D')) { $script:A14Transcripts[$slot] = Join-Path $script:A14Root "$slot.jsonl" }
$script:A14Marker = Get-CopilotDecisionMarkerPath -SessionId $script:A14Ids.A
$script:A14DataPaths = @($script:A14Transcripts.Values) +
    @($script:DaemonConfig.StateFile, "$($script:DaemonConfig.StateFile).bak", "$($script:DaemonConfig.StateFile).tmp",
        $script:A14Marker, $script:DaemonConfig.LegacyCleanupMarker, (Join-Path $script:A14Root 'root-obstruction'))
foreach ($root in @((Get-ClaudeStateRoot), (Get-CodexStateRoot))) {
    foreach ($id in $script:A14Ids.Values) { $script:A14DataPaths += Join-Path $root "$id.json" }
    $script:A14DataPaths += Join-Path $root 'unidentified.json'
    $script:A14DataPaths += Join-Path $root 'collisiona.json'
}
foreach ($id in $script:A14Ids.Values) {
    $node = Get-CopilotMqttNodeId -SessionId $id
    foreach ($topic in @((Get-CopilotMqttSessionDiscoveryTopic -Node $node) + (Get-CopilotMqttSessionStateTopic -Node $node))) {
        [void]$script:A14AllowedTopics.Add($topic)
    }
    foreach ($suffix in @('status', 'activity', 'reply_payload')) {
        $entity = "sensor.${node}_$suffix"
        $script:A14States[$entity] = [pscustomobject]@{ entity_id = $entity; state = 'unknown'; attributes = [pscustomobject]@{} }
    }
    foreach ($pair in @(@('text', 'reply'), @('select', 'decision'), @('button', 'submit'), @('button', 'stop'))) {
        $entity = "$($pair[0]).${node}_$($pair[1])"
        $script:A14States[$entity] = [pscustomobject]@{ entity_id = $entity; state = 'unknown'; attributes = [pscustomobject]@{} }
    }
    for ($fieldIndex = 1; $fieldIndex -le 4; $fieldIndex++) {
        $fieldEntity = Get-CopilotMqttFieldEntityId -Node $node -Index $fieldIndex
        $script:A14FieldSlots[$fieldEntity] = [pscustomobject]@{ EntityId = $fieldEntity; Slot = $fieldIndex }
        $script:A14States[$fieldEntity] = [pscustomobject]@{
            entity_id = $fieldEntity; state = 'unknown'; attributes = [pscustomobject]@{ options = @('Idle') }
        }
    }
    $legacy = Get-CopilotLegacyMqttNodeId -SessionId $id
    foreach ($pair in @(@('select', 'decision'), @('text', 'reply'), @('sensor', 'status'), @('sensor', 'activity'), @('button', 'submit'))) {
        [void]$script:A14AllowedTopics.Add("homeassistant/$($pair[0])/$legacy/$($pair[1])/config")
    }
    for ($field = 1; $field -le $script:CopilotMqttMaxFields; $field++) { [void]$script:A14AllowedTopics.Add("homeassistant/select/$legacy/f$field/config") }
}
foreach ($topic in Get-CopilotMqttMachineTopic -Slug $script:DaemonMachineSlug) { [void]$script:A14AllowedTopics.Add($topic) }
foreach ($suffix in @('update/copilot_cli_bridge/update', 'button/copilot_cli_bridge/install_update',
    'text/copilot_cli_bridge/new_prompt', 'select/copilot_cli_bridge/new_workspace',
    'select/copilot_cli_bridge/new_profile', 'select/copilot_cli_bridge/new_resume',
    'button/copilot_cli_bridge/new_session', 'sensor/copilot_cli_global/sessions')) {
    [void]$script:A14AllowedTopics.Add("homeassistant/$suffix/config")
}
[void]$script:A14AllowedTopics.Add($script:A14LegacyResultTopic)
$machineEntity = Get-BridgeMachineEntityId -Domain sensor -Key sessions -Slug $script:DaemonMachineSlug
$script:A14States[$machineEntity] = [pscustomobject]@{
    entity_id = $machineEntity; state = '3'
    attributes = [pscustomobject]@{ machine = $script:DaemonMachineName; machine_slug = $script:DaemonMachineSlug; sessions = @(); capabilities = [pscustomobject]@{} }
}
$script:A14States[$script:DaemonConfig.VerboseToggle] = [pscustomobject]@{ entity_id = $script:DaemonConfig.VerboseToggle; state = 'off'; attributes = [pscustomobject]@{} }
$script:A14States[$script:DaemonEntity.NewResult] = [pscustomobject]@{ entity_id = $script:DaemonEntity.NewResult; state = ''; attributes = [pscustomobject]@{} }
$oldFrontend = $env:BRIDGE_FRONTEND_NORUN
$env:BRIDGE_FRONTEND_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\bridge-frontend-cards.ps1')
if ($null -eq $oldFrontend) { Remove-Item Env:\BRIDGE_FRONTEND_NORUN } else { $env:BRIDGE_FRONTEND_NORUN = $oldFrontend }

# The adapter imports replaced this boundary before the first modeled ps case.
function Invoke-BridgePsCommandLine {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { Stop-A14Boundary 'ps PID' }
    $script:A14PsCalls++
    [pscustomobject]@{
        Text = $(if ($script:A14CommandMode -in @('empty', 'absent')) { '' } else { $script:A14CommandText })
        ExitCode = $script:A14PsExit
    }
}

$cardPath = Join-Path $PSScriptRoot '..\frontend\agent-bridge-reply-card.js'
$cardVersion = Get-BridgeReplyCardFileVersion -SourcePath $cardPath
$cardUrl = 'data:text/javascript;base64,' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($cardPath)) + "#agent-bridge-reply-card.js?v=$cardVersion"
Initialize-TestPublicationAuthority -CardUrl $cardUrl

try {
    $bindingSources = @(
        @{
            Path = (Join-Path $PSScriptRoot 'test-registration-isolation.ps1')
            Names = @('Get-Process', 'Get-CimInstance', 'Invoke-BridgePsCommandLine', 'Invoke-CopilotHaWebSocket', 'Invoke-RestMethod')
        }
        @{
            Path = (Join-Path $PSScriptRoot '..\hooks\bridge-platform.ps1')
            Names = @('Get-BridgeCommandLine', 'Get-BridgeAgentProcesses', 'Test-BridgeAgentProcess')
        }
    )
    $bindingPathComparison = if ($script:A14ActualWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    foreach ($bindingSource in $bindingSources) {
        $bindingPath = [IO.Path]::GetFullPath($bindingSource.Path)
        $bindingTokens = $null
        $bindingErrors = $null
        $bindingAst = [Management.Automation.Language.Parser]::ParseFile($bindingPath, [ref]$bindingTokens, [ref]$bindingErrors)
        if ($bindingErrors.Count) { throw "A14 binding source could not be parsed: $bindingPath" }
        $bindingSourceHash = (Get-FileHash -LiteralPath $bindingPath -Algorithm SHA256 -ErrorAction Stop).Hash
        foreach ($bindingName in $bindingSource.Names) {
            $bindingDeclarations = @($bindingAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $bindingName
            }, $true))
            $bindingCommands = @(Get-Command -Name $bindingName -ErrorAction Stop)
            $bindingFunction = if ($bindingCommands.Count -eq 1 -and $bindingCommands[0] -is [Management.Automation.FunctionInfo]) {
                $bindingCommands[0]
            } else { $null }
            $bindingActualPath = if ($null -ne $bindingFunction -and $bindingFunction.ScriptBlock.File) {
                [IO.Path]::GetFullPath($bindingFunction.ScriptBlock.File)
            } else { '' }
            $bindingSourceMatches = [string]::Equals($bindingPath, $bindingActualPath, $bindingPathComparison)
            $bindingRuntimeAst = if ($null -ne $bindingFunction) { $bindingFunction.ScriptBlock.Ast } else { $null }
            $bindingExpectedBody = if ($bindingDeclarations.Count -eq 1) { $bindingDeclarations[0].Body } else { $null }
            $bindingComparisonAst = $null
            $bindingNormalization = 'UnsupportedOrMissing'
            $bindingFunctionIdentityMatches = $null -ne $bindingFunction -and $bindingFunction.Name -ceq $bindingName
            # Some PowerShell versions expose the whole function declaration, not its body.
            if ($bindingRuntimeAst -is [Management.Automation.Language.FunctionDefinitionAst]) {
                $bindingFunctionIdentityMatches = $bindingFunctionIdentityMatches -and $bindingRuntimeAst.Name -ceq $bindingName
                $bindingComparisonAst = $bindingRuntimeAst.Body
                $bindingNormalization = 'FunctionDefinitionAst.Body'
            }
            elseif ($bindingRuntimeAst -is [Management.Automation.Language.ScriptBlockAst]) {
                $bindingComparisonAst = $bindingRuntimeAst
                $bindingNormalization = 'ScriptBlockAst'
            }
            $bindingDefinitionMatches = $bindingFunctionIdentityMatches -and $bindingDeclarations.Count -eq 1 -and
                $bindingComparisonAst -is [Management.Automation.Language.ScriptBlockAst] -and
                $bindingExpectedBody -is [Management.Automation.Language.ScriptBlockAst] -and
                $bindingComparisonAst.Extent.Text -ceq $bindingExpectedBody.Extent.Text
            [Console]::Out.WriteLine('A14-BINDING ' + ([ordered]@{
                Name = $bindingName; ExpectedSource = $bindingPath; ActualSource = $bindingActualPath
                SourceSHA256 = $bindingSourceHash; SourceMatches = $bindingSourceMatches; DefinitionMatches = $bindingDefinitionMatches
                FunctionIdentityMatches = $bindingFunctionIdentityMatches; Normalization = $bindingNormalization
                RuntimeAstType = $(if ($null -ne $bindingRuntimeAst) { $bindingRuntimeAst.GetType().FullName } else { $null })
                ExpectedDeclarationCount = $bindingDeclarations.Count
                ExpectedDeclarationAstType = $(if ($bindingDeclarations.Count -eq 1) { $bindingDeclarations[0].GetType().FullName } else { $null })
                ExpectedBodyAstType = $(if ($null -ne $bindingExpectedBody) { $bindingExpectedBody.GetType().FullName } else { $null })
                ComparisonAstType = $(if ($null -ne $bindingComparisonAst) { $bindingComparisonAst.GetType().FullName } else { $null })
            } | ConvertTo-Json -Compress))
            if (-not $bindingSourceMatches -or -not $bindingDefinitionMatches) {
                throw "A14 binding precondition failed: $bindingName"
            }
        }
    }
    Invoke-A14Group 'default Windows collection and complete-empty observation' {
        $script:BridgeIsWindows = $true
        $borrowed = [pscustomobject]@{ Id = 90001; ProcessName = 'claude'; CommandLine = 'unchanged borrowed value' }
        $script:A14Processes = @($borrowed)
        $legacy = @(Get-BridgeAgentProcesses -Agent claude)
        Test-A14 'the default API returns its original process object' ($legacy.Count -eq 1 -and [object]::ReferenceEquals($legacy[0], $borrowed))
        $script:A14Processes = @()
        $empty = Get-BridgeAgentProcesses -Agent claude -AsObservation
        Test-A14 'specific scoped name absence is known complete empty' ($empty.Known -and $empty.Processes.Count -eq 0)
    }
    Invoke-A14Group 'partial enumeration retains positive rows but not completeness' {
        $script:A14Processes = @([pscustomobject]@{ Id = 90001; ProcessName = 'claude' })
        $script:A14ProcessMode = 'partial'
        $partial = Get-BridgeAgentProcesses -Agent claude -AsObservation
        Test-A14 'positive process evidence survives an enumeration error' (-not $partial.Known -and $partial.Processes.Count -eq 1 -and $partial.Diagnostics.Count -gt 0)
    }
    Invoke-A14Group 'denied inventory and recovery are distinct' {
        $script:A14ProcessMode = 'denied'
        $denied = Get-BridgeAgentProcesses -Agent claude -AsObservation
        Test-A14 'denial does not mean known empty' (-not $denied.Known -and $denied.Processes.Count -eq 0)
        $script:A14ProcessMode = 'normal'
        Test-A14 'a later real boundary success recovers completeness' (Get-BridgeAgentProcesses -Agent claude -AsObservation).Known
    }
    Invoke-A14Group 'non-Windows direct names preserve default identity rules' {
        $script:BridgeIsWindows = $false
        $borrowed = [pscustomobject]@{ Id = 90002; ProcessName = 'claude.exe' }
        $script:A14Processes = @($borrowed)
        $legacy = @(Get-BridgeAgentProcesses -Agent claude)
        Test-A14 'agent.exe remains a default candidate without mutation' ($legacy.Count -eq 1 -and [object]::ReferenceEquals($legacy[0], $borrowed))
        Test-A14 'the observation path uses the same direct-name rule' (Get-BridgeAgentProcesses -Agent claude -AsObservation).Known
        Test-A14 'the non-Windows default command API retains string behavior' ((Get-BridgeCommandLine -ProcessId 90002) -ceq $script:A14CommandText)
    }
    Invoke-A14Group 'readable node and bun identity stays local' {
        $script:A14Processes = @([pscustomobject]@{ Id = 90003; ProcessName = 'node' }, [pscustomobject]@{ Id = 90004; ProcessName = 'bun' })
        $script:A14CommandMode = 'readable'; $script:A14PsExit = 0
        $before = $script:A14PsCalls
        $observed = Get-BridgeAgentProcesses -Agent claude -AsObservation
        Test-A14 'readable package identity identifies both existing hosts' ($observed.Known -and $observed.Processes.Count -eq 2)
        Test-A14 'the identity predicate does not refetch observed command lines' ($script:A14PsCalls -eq ($before + 2))
        Test-A14 'command-line content never enters observation rows or diagnostics' (($observed | ConvertTo-Json -Depth 6) -notmatch 'synthetic-secret-do-not-log')
        Test-A14 'borrowed process objects were not given command-line properties' ($null -eq $script:A14Processes[0].PSObject.Properties['CommandLine'])
        $legacy = @(Get-BridgeAgentProcesses -Agent claude)
        Test-A14 'default node and bun results remain their original objects' (
            $legacy.Count -eq 2 -and [object]::ReferenceEquals($legacy[0], $script:A14Processes[0]))
        $script:A14CommandText = 'node unrelated-package/index.js'
        $other = Get-BridgeAgentProcesses -Agent claude -AsObservation
        Test-A14 'readable non-agent command lines are known negatives' ($other.Known -and $other.Processes.Count -eq 0)
        $script:A14Processes = @([pscustomobject]@{ Id = 90003; ProcessName = 'claude' }, [pscustomobject]@{ Id = 90003; ProcessName = 'node' })
        $conflict = Get-BridgeAgentProcesses -Agent claude -AsObservation
        Test-A14 'conflicting observed identities for one PID are not authoritative positives' (-not $conflict.Known -and $conflict.Processes.Count -eq 0)
    }
    Invoke-A14Group 'specific command-read disappearance is not a generic ps error' {
        $script:A14CommandMode = 'absent'; $script:A14PsExit = 1; $script:A14Processes = @()
        $gone = Get-BridgeCommandLine -ProcessId 90003 -AsObservation
        Test-A14 'a scoped process-not-found check can establish disappearance' ($gone.State -eq 'Absent')
        $script:A14Processes = @([pscustomobject]@{ Id = 90003; ProcessName = 'node' })
        $script:A14ProcessMode = 'disappear-on-id'
        $goneInventory = Get-BridgeAgentProcesses -Agent claude -AsObservation
        Test-A14 'the real observer retains complete absence after specific disappearance' (
            $goneInventory.Known -and $goneInventory.Processes.Count -eq 0 -and $goneInventory.Diagnostics[0].Code -eq 'ProcessDisappeared')
        $script:A14ProcessMode = 'normal'
        $script:A14PsExit = 2
        $generic = Get-BridgeCommandLine -ProcessId 90003 -AsObservation
        Test-A14 'a generic ps error is not a known non-agent and its exit is retained' ($generic.State -eq 'Unknown' -and $generic.NativeExit -eq 2)
    }
    Invoke-A14Group 'denied and empty command identity remain unknown' {
        $script:BridgeIsWindows = $true
        $script:A14CommandMode = 'denied'
        Test-A14 'denied CIM command data stays unknown' ((Get-BridgeCommandLine -ProcessId 90003 -AsObservation).State -eq 'Unknown')
        $script:A14CommandMode = 'empty'
        Test-A14 'empty command text stays unknown' ((Get-BridgeCommandLine -ProcessId 90003 -AsObservation).State -eq 'Unknown')
        $script:A14CommandMode = 'readable'; $script:A14CommandText = 'plain default text'
        Test-A14 'the default string API remains a string with the original value' ((Get-BridgeCommandLine -ProcessId 90003) -ceq 'plain default text')
        # "or ''", as the function promises. CIM answers nothing for a process that has
        # exited, and reading .CommandLine off that threw PropertyNotFound under
        # StrictMode instead. Every caller of this path walks a process list or a parent
        # chain, where a process going between being enumerated and being asked about is
        # ordinary - so the throw escaped into hook and installer code with no reason to
        # expect one, and took test-claude-install.ps1 down intermittently. The
        # observation path beside it was already careful about the same row.
        $script:A14CommandMode = 'absent'
        Test-A14 'the default string API answers nothing rather than throwing once the process has gone' (
            (Get-BridgeCommandLine -ProcessId 90003) -ceq '')
        # But only when the query itself succeeded. A denied or provider-failed read
        # returns no row either, and letting that collapse into the same empty string
        # would be cached against pid and start time by Get-BridgeAgentProcessSessionIds
        # - hiding a live session for as long as that process ran. The macOS branch
        # already separates them; this keeps Windows honest about the difference.
        $script:A14CommandMode = 'denied'
        $deniedThrew = $false
        try { [void](Get-BridgeCommandLine -ProcessId 90003) } catch { $deniedThrew = $true }
        Test-A14 'a failed command query is raised rather than answered as a vanished process' $deniedThrew
        $script:A14CommandMode = 'readable'
        $script:BridgeIsWindows = $false
        $script:A14PsExit = 0; $script:A14CommandMode = 'empty'
        $script:A14Processes = @([pscustomobject]@{ Id = 90003; ProcessName = 'node' }, [pscustomobject]@{ Id = 90005; ProcessName = 'claude' })
        $unreadable = Get-BridgeAgentProcesses -Agent claude -AsObservation
        Test-A14 'an unreadable host identity retains other positives but not completeness' (-not $unreadable.Known -and $unreadable.Processes.Count -eq 1)
        $script:BridgeIsWindows = $true
    }
    Invoke-A14Group 'actual S1 refusal survives wrapper exceptions' {
        try { [void](Read-DaemonRegistrationFile -Path (Join-Path $PSScriptRoot '..\README.md') -Kind claude) }
        catch { $script:A14Guard = $_ }
        Test-A14 'an out-of-bound record read propagates the actual guard' ($null -ne $script:A14Guard -and (Test-BridgeObservationGuardFailure $script:A14Guard))
        $script:A14ProcessMode = 'guard'; $caught = $null
        try { [void](Get-BridgeAgentProcesses -Agent claude -AsObservation) } catch { $caught = $_ }
        Test-A14 'the actual guard remains marked through an outer raw-boundary exception' ($null -ne $caught -and (Test-BridgeObservationGuardFailure $caught))
        $script:A14ProcessMode = 'normal'
    }

    foreach ($kind in @('claude', 'codex')) {
        Invoke-A14Group "$kind complete baseline and optional hook compatibility" {
            Reset-A14Records $kind
            $optional = Get-Content -LiteralPath (Get-A14RegistrationPath A) -Raw | ConvertFrom-Json -AsHashtable
            if ($kind -eq 'claude') { [void]$optional.Remove('HookStatus'); [void]$optional.Remove('HookStatusAt') }
            else { [void]$optional.Remove('Ended') }
            Write-A14Json -Path (Get-A14RegistrationPath A) -Value $optional
            $snapshot = Invoke-A14Reconcile
            Test-A14 "$kind baseline has three real positive records" ($snapshot.Complete -and $snapshot.Live.Count -eq 3 -and $script:A14State.Count -eq 3)
            Test-A14 "$kind baseline publishes actual activity" ($script:A14State[$script:A14Ids.B].LastMessage -ceq 'initial')
        }
        Invoke-A14Group "$kind incomplete owner retains state and marker across two passes" {
            Reset-A14Records $kind
            [void](Invoke-A14Reconcile)
            $prior = $script:A14State[$script:A14Ids.A] | ConvertTo-Json -Depth 10 -Compress
            Write-A14Json -Path (Get-A14RegistrationPath A) -Value @{ SessionId = $script:A14Ids.A }
            foreach ($round in 1..2) {
                if ($round -eq 2) {
                    Write-A14Registration A
                    $badPid = Get-Content -LiteralPath (Get-A14RegistrationPath A) -Raw | ConvertFrom-Json -AsHashtable
                    $badPid.ProcessId = 'not-a-process-id'
                    Write-A14Json -Path (Get-A14RegistrationPath A) -Value $badPid
                }
                Add-A14Message B "neighbor-$round"; Add-A14Message C "other-$round"
                $snapshot = Invoke-A14Reconcile
                Test-A14HeldOwner "$kind incomplete pass$round" $snapshot
                Test-A14 "$kind pass$round preserves A's fields and updates B/C" (
                    ($script:A14State[$script:A14Ids.A] | ConvertTo-Json -Depth 10 -Compress) -ceq $prior -and
                    $script:A14State[$script:A14Ids.B].LastMessage -ceq "neighbor-$round" -and
                    $script:A14State[$script:A14Ids.C].LastMessage -ceq "other-$round")
            }
        }
        Invoke-A14Group "$kind actual locked read retries without a timestamp change" {
            Reset-A14Records $kind
            [void](Invoke-A14Reconcile)
            $path = Get-A14RegistrationPath A
            $stamp = [IO.File]::GetLastWriteTimeUtc($path)
            $script:DaemonRegistrationStamps.Clear()
            $active = $script:DaemonLive[$script:A14Ids.A]
            $lock = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try {
                if ($kind -eq 'claude') { [void](& (Get-DaemonAgent -Kind claude).PollRegistration $script:A14Ids.A $active) }
                else { [void](Sync-DaemonCodexHookStatus -Id $script:A14Ids.A -Entry $script:A14State[$script:A14Ids.A] -Headers @{}) }
                $snapshot = Invoke-A14Reconcile
                Test-A14HeldOwner "$kind locked" $snapshot
                $cacheKey = if ($kind -eq 'claude') { $script:A14Ids.A } else { "codex:$($script:A14Ids.A)" }
                Test-A14 "$kind failed read is not acknowledged" (-not $script:DaemonRegistrationStamps.ContainsKey($cacheKey))
            }
            finally { $lock.Dispose() }
            $snapshot = Invoke-A14Reconcile
            Test-A14 "$kind same-T unlocked read recovers without a new write" ($snapshot.Complete -and $snapshot.Live.ContainsKey($script:A14Ids.A) -and [IO.File]::GetLastWriteTimeUtc($path) -eq $stamp)
            Test-A14 "$kind successful same-T read is acknowledged only after recovery" ($script:DaemonRegistrationStamps[$cacheKey] -eq $stamp.Ticks)
            $lock = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try {
                $again = if ($kind -eq 'claude') { & (Get-DaemonAgent -Kind claude).PollRegistration $script:A14Ids.A $snapshot.Live[$script:A14Ids.A] }
                    else { Sync-DaemonCodexHookStatus -Id $script:A14Ids.A -Entry $script:A14State[$script:A14Ids.A] -Headers @{} }
                Test-A14 "$kind acknowledged unchanged read does not reread or poison liveness" (-not $again -and $snapshot.Live.ContainsKey($script:A14Ids.A))
            }
            finally { $lock.Dispose() }
        }
        Invoke-A14Group "$kind same-T repair defeats an old retirement queue" {
            Reset-A14Records $kind
            [void](Invoke-A14Reconcile)
            $path = Get-A14RegistrationPath A; $stamp = [IO.File]::GetLastWriteTimeUtc($path)
            $withoutA = @{}
            foreach ($id in @($script:A14Ids.B, $script:A14Ids.C)) { $withoutA[$id] = $script:A14State[$id] }
            [void](Sync-DaemonDashboard -Descriptors @(Get-DaemonSessionDescriptors -State $withoutA -Headers @{}) -Capabilities (Get-DaemonLaunchCapabilities) -Headers @{})
            $script:DaemonPendingRetire = @($script:A14Ids.A)
            [IO.File]::WriteAllText($path, '{', [Text.UTF8Encoding]::new($false))
            [IO.File]::SetLastWriteTimeUtc($path, $stamp)
            $snapshot = Invoke-A14Reconcile
            Test-A14HeldOwner "$kind queued malformed" $snapshot
            Test-A14 "$kind verified view omission cannot retire uncertain A" ($script:DaemonPendingRetire -contains $script:A14Ids.A)
            Write-A14Registration A; [IO.File]::SetLastWriteTimeUtc($path, $stamp)
            $snapshot = Invoke-A14Reconcile
            Test-A14 "$kind repair at the same stamp recovers and cancels stale retirement" (
                $snapshot.Complete -and $snapshot.Live.ContainsKey($script:A14Ids.A) -and
                $script:DaemonPendingRetire -notcontains $script:A14Ids.A -and [IO.File]::Exists($script:A14Marker))
        }
        Invoke-A14Group "$kind unidentifiable ownership is not no owner" {
            Reset-A14Records $kind
            [void](Invoke-A14Reconcile)
            $root = if ($kind -eq 'claude') { Get-ClaudeStateRoot } else { Get-CodexStateRoot }
            Write-A14Json -Path (Join-Path $root 'unidentified.json') -Value @('not-an-object')
            $snapshot = Invoke-A14Reconcile
            Test-A14 "$kind unidentifiable record holds absence while positives remain" (
                -not $snapshot.Complete -and $snapshot.Live.ContainsKey($script:A14Ids.B) -and $script:A14State.Count -eq 3)
            $before = $script:A14Requests.Count
            Clear-CopilotMqttOrphans -Headers @{} -Live $snapshot.Live -Discovery $snapshot
            Test-A14 "$kind incomplete ownership cannot authorize orphan clearing" ($script:A14Requests.Count -eq $before)
        }
        Invoke-A14Group "$kind genuine dead and unresolved PID remain distinct" {
            Reset-A14Records $kind
            [void](Invoke-A14Reconcile)
            $script:A14State[$script:A14Ids.D] = [pscustomobject]@{ Name = "$kind`: D"; Machine = 'FIXTURE'; Kind = $kind; Status = 'idle'; Offset = 0L }
            Write-A14Registration D
            [void](Invoke-A14Reconcile)
            Test-A14 "$kind complete negative evidence queues only D" (-not $script:A14State.ContainsKey($script:A14Ids.D) -and $script:DaemonPendingRetire -contains $script:A14Ids.D)
            [void](Invoke-A14Reconcile)
            $nodeD = Get-CopilotMqttNodeId -SessionId $script:A14Ids.D
            Test-A14 "$kind existing delayed retirement removes the genuinely dead record" (
                @($script:A14Requests | Where-Object { $_.Payload -ceq '' -and $_.Topic.Split('/') -ccontains $nodeD }).Count -gt 0)
            Write-A14Registration A
            $badTime = Get-Content -LiteralPath (Get-A14RegistrationPath A) -Raw | ConvertFrom-Json -AsHashtable
            $badTime.Updated = 'not-a-timestamp'
            Write-A14Json -Path (Get-A14RegistrationPath A) -Value $badTime
            $snapshot = Invoke-A14Reconcile
            Test-A14HeldOwner "$kind invalid timestamp" $snapshot
            Write-A14Registration A -ProcessId 0
            $snapshot = Invoke-A14Reconcile
            Test-A14HeldOwner "$kind unresolved PID0" $snapshot
            Write-A14Registration A -Ended:($kind -eq 'codex')
            if ($kind -eq 'claude') {
                $oldLive = Get-Content -LiteralPath (Get-A14RegistrationPath A) -Raw | ConvertFrom-Json -AsHashtable
                $oldLive.Updated = [DateTimeOffset]::Now.AddDays(-5).ToString('o')
                Write-A14Json -Path (Get-A14RegistrationPath A) -Value $oldLive
            }
            $lifetime = Get-LiveBridgeSessions -AsObservation -State $script:A14State
            $policyHeld = if ($kind -eq 'claude') { $lifetime.Live.ContainsKey($script:A14Ids.A) }
                else { -not $lifetime.Live.ContainsKey($script:A14Ids.A) }
            Test-A14 "$kind existing long-idle or explicit-ended policy remains" ($lifetime.Complete -and $policyHeld)
        }
    }

    Invoke-A14Group 'Codex app-server does not need a registration of its own' {
        # Codex's app-server daemon is named codex.exe and never registers, so
        # requiring a registration for it left Known false on every pass: no snapshot
        # was ever Complete, retirement and the orphan sweep were held, and Launch was
        # refused with "Session discovery is incomplete". Captured on a machine stuck
        # there with the daemon's pids unaccounted for.
        Reset-A14Records codex
        $daemonPid = 81090
        $script:A14Processes = @(@($script:A14Processes) + [pscustomobject]@{
            Id = $daemonPid; ProcessName = 'codex'
            Path = (Join-Path ([IO.Path]::GetTempPath()) 'codex\packages\app-server-daemon\bin\codex.exe')
            StartTime = [datetime]::UtcNow.AddHours(-2)
        })
        $snapshot = Invoke-A14Reconcile
        Test-A14 'an unregistered app-server leaves the snapshot complete' (
            $snapshot.Complete -and $snapshot.Live.Count -eq 3)

        # It is excused a registration, not treated as dead: Get-CodexOwningProcessId
        # falls back to the app-server when it cannot identify a window of its own, so
        # a live session really does register this pid, and reading it as gone would
        # delete that session's record while it is still answering.
        $script:A14Processes = @(@($script:A14Processes) | Where-Object { [int]$_.Id -ne $script:A14Pids.A })
        Write-A14Registration A -ProcessId $daemonPid
        $owned = Invoke-A14Reconcile
        Test-A14 'a session that registered the app-server is still live' (
            $owned.Complete -and $owned.Live.ContainsKey($script:A14Ids.A))
        Test-A14 'and its registration was not pruned' ([IO.File]::Exists((Get-A14RegistrationPath A)))

        # An ordinary codex process with no registration is still a real gap.
        Reset-A14Records codex
        $script:A14Processes = @(@($script:A14Processes) + [pscustomobject]@{
            Id = 81091; ProcessName = 'codex'; Path = (Join-Path ([IO.Path]::GetTempPath()) 'codex\bin\codex.exe')
            StartTime = [datetime]::UtcNow.AddHours(-2)
        })
        $stranger = Invoke-A14Reconcile
        Test-A14 'while an unaccounted session process still holds discovery' (-not $stranger.Complete)
    }

    Invoke-A14Group 'publication resumes after completeness without a new unrelated event' {
        Reset-A14Records claude
        [void](Invoke-A14Reconcile)
        $signature = $script:DaemonGlobalSignature; $dashboard = $script:DaemonDashboardSignature
        Write-A14Json -Path (Get-A14RegistrationPath A) -Value @{ SessionId = $script:A14Ids.A }
        Write-A14Registration D
        $script:A14Processes += [pscustomobject]@{ Id = $script:A14Pids.D; ProcessName = 'claude'; StartTime = [datetime]::UtcNow.AddHours(-1) }
        $script:TestPublication.Commands.Clear()
        $snapshot = Invoke-A14Reconcile
        Test-A14 'a new validated positive is adopted during uncertainty' ($snapshot.Live.ContainsKey($script:A14Ids.D) -and $script:A14State.ContainsKey($script:A14Ids.D))
        Test-A14 'held complete publication advances no success signature' (
            $script:DaemonGlobalSignature -ceq $signature -and $script:DaemonDashboardSignature -ceq $dashboard -and @(Get-TestPublicationWrites).Count -eq 0)
        Write-A14Registration A
        $script:TestPublication.Commands.Clear()
        $snapshot = Invoke-A14Reconcile
        Test-A14 'completeness resumes held global/view publication without restart' (
            $snapshot.Complete -and $script:DaemonGlobalSignature -cne $signature -and
            @(Get-TestPublicationWrites).Count -gt 0 -and $script:BridgeDashboardObservation.Verified)
    }
    Invoke-A14Group 'actual startup session cleanup defers then resumes on reconcile' {
        Reset-A14Records codex
        [void](Invoke-A14Reconcile)
        [IO.File]::Delete($script:DaemonConfig.LegacyCleanupMarker)
        Write-A14Json -Path (Get-A14RegistrationPath A) -Value @{}
        $snapshot = Get-LiveBridgeSessions -AsObservation -State $script:A14State
        $before = $script:A14Requests.Count
        [void](Invoke-DaemonStartupSessionCleanup -Headers @{} -State $script:A14State -Discovery $snapshot -Phase Legacy)
        [void](Invoke-DaemonStartupSessionCleanup -Headers @{} -State $script:A14State -Discovery $snapshot -Phase Orphans)
        Test-A14 'deferred startup neither deletes resources nor writes completion' ($script:A14Requests.Count -eq $before -and -not [IO.File]::Exists($script:DaemonConfig.LegacyCleanupMarker))
        Test-A14 'both actual deferred startup phases stay pending' ($script:DaemonSessionCleanupPending.Count -eq 2)
        Write-DaemonState -State @{}
        $script:A14State = Read-DaemonState
        $script:DaemonOwnerCatalogue = @{}
        $snapshot = Invoke-A14Reconcile
        Test-A14 'startup without a usable A catalogue does not invent its liveness or discard ownership' (
            -not $snapshot.Live.ContainsKey($script:A14Ids.A) -and -not $script:A14State.ContainsKey($script:A14Ids.A) -and
            [IO.File]::Exists($script:A14Marker) -and -not $snapshot.Complete)
        Test-A14 'valid startup neighbors are still adopted under the conservative hold' (
            $script:A14State.ContainsKey($script:A14Ids.B) -and $script:A14State.ContainsKey($script:A14Ids.C))
        Write-A14Registration A
        $complete = Get-LiveBridgeSessions -AsObservation -State $script:A14State
        $machine = $script:A14States[$machineEntity]
        [void]$script:A14States.Remove($machineEntity)
        $script:DaemonStatesCache = $null
        try {
            $attempted = Invoke-DaemonStartupSessionCleanup -Headers @{} -State $script:A14State -Discovery $complete -Phase Orphans
            Test-A14 'a skipped orphan observation does not poison the pending-success state' (-not $attempted -and $script:DaemonSessionCleanupPending.ContainsKey('Orphans'))
        }
        finally { $script:A14States[$machineEntity] = $machine; $script:DaemonStatesCache = $null }
        [void](Invoke-A14Reconcile)
        Test-A14 'ordinary recovery resumes actual deferred startup work' ($script:DaemonSessionCleanupPending.Count -eq 0 -and [IO.File]::Exists($script:DaemonConfig.LegacyCleanupMarker))
    }
    Invoke-A14Group 'poll failure changes the effective map already held by consumers' {
        foreach ($kind in @('claude', 'codex')) {
            Reset-A14Records $kind
            $snapshot = Invoke-A14Reconcile
            $captured = $snapshot.Live
            $invalid = Get-Content -LiteralPath (Get-A14RegistrationPath A) -Raw | ConvertFrom-Json -AsHashtable
            $field = if ($kind -eq 'claude') { 'HookStatus' } else { 'Status' }
            $invalid[$field] = 123
            Write-A14Json -Path (Get-A14RegistrationPath A) -Value $invalid
            $script:DaemonRegistrationStamps.Clear()
            Invoke-DaemonFastActivity -Headers @{} -State $script:A14State
            Test-A14 "$kind previously captured map no longer routes the uncertain owner" (
                [object]::ReferenceEquals($captured, $script:DaemonLive) -and -not $captured.ContainsKey($script:A14Ids.A) -and -not $snapshot.Complete)
            $before = (Get-FileHash -LiteralPath $script:A14Marker -Algorithm SHA256).Hash
            Invoke-PendingDecisions -Headers @{} -State @{ $script:A14Ids.A = $script:A14State[$script:A14Ids.A] } -Live $captured
            Test-A14 "$kind real decision consumer leaves uncertain ownership alone" ((Get-FileHash -LiteralPath $script:A14Marker -Algorithm SHA256).Hash -ceq $before)
        }
    }
    Invoke-A14Group 'collision and independent P4 uncertainty remain conservative' {
        Reset-A14Records claude
        [void](Invoke-A14Reconcile)
        $script:A14State['collision/a'] = [pscustomobject]@{ Name = 'ambiguous A'; Machine = 'FIXTURE'; Kind = 'claude'; Status = 'idle'; Offset = 0L }
        $script:A14State['collisiona'] = [pscustomobject]@{ Name = 'ambiguous B'; Machine = 'FIXTURE'; Kind = 'claude'; Status = 'idle'; Offset = 0L }
        $script:A14State[$script:A14Ids.A].Kind = 'codex'
        Write-A14Json -Path (Join-Path (Get-ClaudeStateRoot) 'collisiona.json') -Value @{}
        $snapshot = Get-LiveBridgeSessions -AsObservation -State $script:A14State
        Test-A14 'colliding paths or changed known owner kinds do not invent ownership' (
            -not $snapshot.Complete -and $snapshot.UncertainIds.ContainsKey('collision/a') -and
            $snapshot.UncertainIds.ContainsKey('collisiona') -and -not $snapshot.Live.ContainsKey($script:A14Ids.A))
        $usage = Get-BridgeWorktreeUsage
        Test-A14 'the independent authoritative worktree reader remains unknown/in-use' (-not $usage.Known -and (Test-BridgeWorktreeInUse -WorktreePath $script:A14Root -Usage $usage))
        $oldRoot = $script:ClaudeStateRoot
        $obstruction = Join-Path $script:A14Root 'root-obstruction'
        [IO.File]::WriteAllText($obstruction, 'not a registration directory')
        try {
            $script:ClaudeStateRoot = $obstruction
            $blocked = Get-LiveBridgeSessions -AsObservation -State $script:A14State
            Test-A14 'a real obstructed root is not a successful empty observation' (-not $blocked.Complete -and $blocked.Live.ContainsKey($script:A14Ids.C))
        }
        finally { $script:ClaudeStateRoot = $oldRoot }
    }
    Test-A14 'the fixed twenty-five source groups were reached' ($script:A14Groups -eq $expectedGroups)
    Test-A14 'the fixed assertion inventory was reached' ($script:A14Checks -eq ($expectedChecks - 1))
}
catch {
    $primaryFailure = $_
    throw
}
finally {
    $script:BridgeIsWindows = $script:A14ActualWindows
    try { foreach ($path in $script:A14DataPaths) { [IO.File]::Delete($path) } }
    catch {
        [Console]::Error.WriteLine('A14-CLEANUP-ERROR ' + $_.Exception.GetType().FullName)
        if ($null -eq $primaryFailure) { throw }
    }
}
Write-Host "A14-REGISTRATION-COMPLETE groups=$script:A14Groups checks=$script:A14Checks failures=0 fixtureChildren=0"
