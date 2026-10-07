#Requires -Version 7.0
<#
.SYNOPSIS
    Tests the generated Home Assistant dashboard config.

.DESCRIPTION
    Save-CopilotSessionDashboard builds the whole Lovelace config from the live session
    list. These assert the parts that are easy to get wrong and that users see: the
    dashboard title, the view tab, the control card's live/version summary, and that a
    live session produces a card. The Home Assistant save is mocked, so nothing here
    touches a real instance.
#>

param([switch]$PublicationFixturesOnly)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\hooks\bridge-secrets.ps1')

function Initialize-TestPublicationStore {
    param([switch]$Unconfigured)

    if ($env:AGENT_HA_BRIDGE_OFFLINE_TEST -ne '1') { throw 'Publication fixtures require the canonical Offline runner.' }
    $root = Join-Path $env:TEMP ('publication-' + [guid]::NewGuid().ToString('N'))
    $bridgeRoot = Join-Path $root '.agent-ha-bridge'
    $configPath = Join-Path $bridgeRoot 'config.json'
    $config = @{
        homeAssistant = @{ baseUrl = 'http://publication.invalid:8123'; token = 'synthetic-publication-token' }
        dashboard = @{ urlPath = 'agent-decisions' }
    }
    if (-not $Unconfigured) {
        $config.dashboard.publication = @{ authority = 'fixture-authority'; participant = 'writer-a'; writer = 'writer-a'; generation = 1 }
    }
    Write-BridgeSecretFile -Path $configPath -Content ($config | ConvertTo-Json -Depth 10)
    $context = Resolve-BridgeInstallContext -TargetHome $root -BridgeHome $bridgeRoot -ConfigPath $configPath
    $script:BridgeInstallContext = Initialize-BridgeInstallIdentity -Context $context
    $env:AGENT_HA_BRIDGE_CONFIG = $configPath
    $script:BridgeUserConfig = Get-BridgeUserConfig
    $script:DecisionBridgeConfig.HomeAssistantBaseUrl = $config.homeAssistant.baseUrl
    $script:DecisionBridgeConfig.HomeAssistantToken = $config.homeAssistant.token
    $script:DecisionBridgeConfig.DashboardUrlPath = 'agent-decisions'
    $script:DecisionBridgeConfig.LogFile = Join-Path $root 'publication.log'
    $script:BridgeDashboardReady = $false
    $script:TestPublication = @{
        Path = (Join-Path $root 'ha.json')
        Commands = [Collections.Generic.List[object]]::new()
        Reject = @{}
    }
    Set-TestPublicationStore @{ resources = @(); dashboards = @(); configs = @{}; nextId = 1 }
}

function Get-TestPublicationStore {
    Get-Content -LiteralPath $script:TestPublication.Path -Raw | ConvertFrom-Json -AsHashtable -Depth 100
}

function Set-TestPublicationStore {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Store)
    [IO.File]::WriteAllText($script:TestPublication.Path, ($Store | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
}

function Set-TestPublicationIdentity {
    param([string]$Participant = 'writer-a', [string]$Writer = 'writer-a', [long]$Generation = 1)
    $path = $script:BridgeInstallContext.ConfigPath
    $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    $config.dashboard.publication = @{ authority = 'fixture-authority'; participant = $Participant; writer = $Writer; generation = $Generation }
    Write-BridgeSecretFile -Path $path -Content ($config | ConvertTo-Json -Depth 10)
    $script:BridgeUserConfig = Get-BridgeUserConfig
}

function Invoke-TestPublicationCommands {
    param([Parameter(Mandatory)][hashtable[]]$Commands)

    # HA core 14f9b7e699d6: lovelace/const.py and websocket.py. Metadata must
    # travel in supported URL/config values, not invented resource properties.
    $fields = @{
        'config/entity_registry/list' = @()
        'lovelace/resources' = @()
        'lovelace/resources/create' = @('url', 'res_type')
        'lovelace/resources/update' = @('url', 'res_type', 'resource_id')
        'lovelace/dashboards/list' = @()
        'lovelace/dashboards/create' = @('url_path', 'title', 'icon', 'show_in_sidebar', 'require_admin')
        'lovelace/dashboards/delete' = @('dashboard_id')
        'lovelace/config' = @('url_path', 'force')
        'lovelace/config/save' = @('url_path', 'config')
    }
    $results = [Collections.Generic.List[object]]::new()
    foreach ($command in $Commands) {
        $type = [string]$command.type
        if (-not $fields.ContainsKey($type)) { throw "Unexpected synthetic HA command: $type" }
        foreach ($key in $command.Keys) {
            if ($key -notin (@('type', 'id') + $fields[$type])) { throw "Unsupported HA field '$key' on $type" }
        }
        $script:TestPublication.Commands.Add(($command | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100))
        if ($script:TestPublication.Reject.ContainsKey($type)) {
            throw "WebSocket command '$type' failed: $($script:TestPublication.Reject[$type])"
        }
        $store = Get-TestPublicationStore
        $result = $null
        switch ($type) {
            'config/entity_registry/list' { $result = @() }
            'lovelace/resources' { $result = @($store.resources) }
            'lovelace/resources/create' {
                if ($command.res_type -ne 'module' -or $command.url -isnot [string]) { throw 'Invalid module resource.' }
                $result = @{ id = "res-$($store.nextId)"; type = $command.res_type; url = $command.url }
                $store.nextId++
                $store.resources = @($store.resources) + @($result)
            }
            'lovelace/resources/update' {
                $matches = @($store.resources | Where-Object { $_.id -ceq $command.resource_id })
                if ($matches.Count -ne 1) { throw 'Resource not found.' }
                if ($command.res_type -ne 'module' -or $command.url -isnot [string]) { throw 'Invalid module resource.' }
                $matches[0].url = $command.url
                $matches[0].type = $command.res_type
                $result = $matches[0]
            }
            'lovelace/dashboards/list' { $result = @($store.dashboards) }
            'lovelace/dashboards/create' {
                if (@($store.dashboards | Where-Object { $_.url_path -ceq $command.url_path }).Count) { throw 'Dashboard already exists.' }
                $result = @{ id = "dash-$($store.nextId)"; url_path = $command.url_path; title = $command.title }
                $store.nextId++
                $store.dashboards = @($store.dashboards) + @($result)
            }
            'lovelace/dashboards/delete' {
                $matches = @($store.dashboards | Where-Object { $_.id -ceq $command.dashboard_id })
                if ($matches.Count -ne 1) { throw 'Dashboard not found.' }
                [void]$store.configs.Remove($matches[0].url_path)
                $store.dashboards = @($store.dashboards | Where-Object { $_.id -cne $command.dashboard_id })
            }
            'lovelace/config' {
                if (-not $store.configs.Contains($command.url_path)) {
                    throw 'WebSocket command ''lovelace/config'' failed: {"code":"config_not_found","message":"No config found."}'
                }
                $result = $store.configs[$command.url_path]
            }
            'lovelace/config/save' {
                if (-not @($store.dashboards | Where-Object { $_.url_path -ceq $command.url_path }).Count) { throw 'Dashboard not found.' }
                if ($command.config -isnot [System.Collections.IDictionary]) { throw 'Expected a dashboard configuration object.' }
                $store.configs[$command.url_path] = $command.config
                $script:SavedConfig = $command.config
                $script:SavedUrlPath = $command.url_path
            }
        }
        Set-TestPublicationStore $store
        if ($null -ne $result) {
            $result = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $result -Depth 100) -Depth 100 -NoEnumerate
        }
        $results.Add($result)
    }
    Write-Output -NoEnumerate $results.ToArray()
}

function New-TestPublicationCard {
    param([string]$Version, [string]$Content = 'export {};')
    $path = Join-Path (Split-Path $script:TestPublication.Path -Parent) ("card-$([guid]::NewGuid().ToString('N')).js")
    [IO.File]::WriteAllText($path, "const CARD_VERSION = '$Version';`n$Content", [Text.UTF8Encoding]::new($false))
    $path
}

function New-TestPublicationPolicy {
    param([string]$CardSource, [string]$Mode = 'advance', [long]$Generation = 1, [string]$Writer = 'writer-a')
    $card = @{ version = (Get-BridgeReplyCardFileVersion $CardSource); hash = (Get-FileHash -LiteralPath $CardSource -Algorithm SHA256).Hash.ToLowerInvariant() }
    $render = Get-BridgeRenderArtifact
    @{
        protocol = 1; authority = 'fixture-authority'; writer = $Writer; generation = $Generation; mode = $Mode
        dashboard = 'agent-decisions'
        card = $card; render = $render; highCard = $card; highRender = $render; legacyCard = ''
    }
}

function Set-TestPublicationPolicy {
    param([Parameter(Mandatory)][hashtable]$Policy, [AllowEmptyString()][string]$CardUrl = '')
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Policy | ConvertTo-Json -Depth 15 -Compress)))
    $url = 'data:text/javascript;base64,ZXhwb3J0IHt9Ow==#agent-bridge-publication-policy.js?policy=' + $payload
    $store = Get-TestPublicationStore
    $store.resources = @(@{ id = 'publication-policy'; type = 'module'; url = $url })
    if ($CardUrl) { $store.resources += @{ id = 'reply-card'; type = 'module'; url = $CardUrl } }
    Set-TestPublicationStore $store
}

function Get-TestPublicationWrites {
    @($script:TestPublication.Commands | Where-Object { $_.type -match '/(create|update|delete|save)$' })
}

function Set-TestPublicationCardUrl {
    param([AllowEmptyString()][string]$Url)
    $store = Get-TestPublicationStore
    $store.resources = @($store.resources | Where-Object { $_.url -notmatch 'agent-bridge-reply-card\.js' })
    if ($Url) { $store.resources += @{ id = 'reply-card'; type = 'module'; url = $Url } }
    Set-TestPublicationStore $store
}

function Set-TestPublicationReceiptForCard {
    param([Parameter(Mandatory)][string]$CardUrl, [string]$InputSignature)
    # Persist the internally consistent state an older participating writer could
    # leave behind. The real reader must reject its pin mismatch, not merely a bad seal.
    Set-TestPublicationCardUrl -Url $CardUrl
    $store = Get-TestPublicationStore
    $config = $store.configs['agent-decisions']
    $config.agent_bridge_publication.cardUrlHash = Get-BridgePublicationHash $CardUrl
    if ($PSBoundParameters.ContainsKey('InputSignature')) { $config.agent_bridge_publication.inputHash = $InputSignature }
    [void]$config.agent_bridge_publication.Remove('contentHash')
    $config.agent_bridge_publication.contentHash = Get-BridgePublicationHash (ConvertTo-BridgePublicationJson $config)
    Set-TestPublicationStore $store
}

function Initialize-TestPublicationAuthority {
    param([string]$CardSource = (Join-Path $PSScriptRoot '..\frontend\agent-bridge-reply-card.js'),
        [AllowEmptyString()][string]$CardUrl = '', [switch]$ServeCard)
    # Keep the checker's Json switch in this function's scope, not a caller's $json.
    if (-not (Get-Command Get-BridgeReplyCardFileVersion -ErrorAction SilentlyContinue)) {
        $previousFrontendNoRun = $env:BRIDGE_FRONTEND_NORUN
        $env:BRIDGE_FRONTEND_NORUN = '1'
        . (Join-Path $PSScriptRoot '..\hooks\bridge-frontend-cards.ps1')
        if ($null -eq $previousFrontendNoRun) { Remove-Item Env:\BRIDGE_FRONTEND_NORUN }
        else { $env:BRIDGE_FRONTEND_NORUN = $previousFrontendNoRun }
    }
    $target = Get-BridgePublicationTarget -CardSourcePath $CardSource
    if ($ServeCard) { $CardUrl = "/local/agent-bridge-reply-card.js?v=$($target.card.version)" }
    Set-TestPublicationCardUrl -Url $CardUrl
    Set-BridgePublicationPolicy -ExpectedGeneration 0 -ExpectedPolicyHash absent -Target $target | Out-Null
    $script:TestPublication.Commands.Clear()
}

function Invoke-TestPublicationRestart {
    param([switch]$Repair)
    $fixtureRoot = Split-Path $script:TestPublication.Path -Parent
    $childPath = Join-Path $fixtureRoot ("restart-$([guid]::NewGuid().ToString('N')).ps1")
    $hooks = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\hooks'))
    $fixture = Join-Path $PSScriptRoot 'test-dashboard.ps1'
    $source = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. '__HOOKS__\decision-bridge-common.ps1'
. '__HOOKS__\decision-mqtt.ps1'
. '__HOOKS__\decision-ha-websocket.ps1'
. '__FIXTURE__' -PublicationFixturesOnly
$script:TestPublication = @{ Path = '__STORE__'; Commands = [Collections.Generic.List[object]]::new(); Reject = @{} }
function Invoke-CopilotHaWebSocket {
    param([hashtable[]]$Commands)
    Invoke-TestPublicationCommands -Commands $Commands
}
try {
    if ('__REPAIR__' -eq 'yes') { Save-CopilotSessionDashboard -Sessions @() }
    $published = Get-BridgeDashboardPublication
    [pscustomobject]@{
        verified = $published.Verified
        generation = $published.State.Policy.generation
        receipt = (Test-Path -LiteralPath (Get-BridgePublicationReceiptPath) -PathType Leaf)
        writes = @(Get-TestPublicationWrites).Count
        processId = $PID
        fixtureRoot = $env:AGENT_HA_BRIDGE_TEST_ROOT
        fixtureId = $env:AGENT_HA_BRIDGE_TEST_ID
        configPath = (Get-BridgeInstallContext).ConfigPath
    } | ConvertTo-Json -Compress
    exit 0
}
catch {
    [pscustomobject]@{ error = $_.Exception.Message; processId = $PID } | ConvertTo-Json -Compress
    exit 2
}
'@
    $source = $source.Replace('__HOOKS__', $hooks.Replace("'", "''")).
        Replace('__FIXTURE__', $fixture.Replace("'", "''")).
        Replace('__STORE__', $script:TestPublication.Path.Replace("'", "''")).
        Replace('__REPAIR__', $(if ($Repair) { 'yes' } else { 'no' }))
    [IO.File]::WriteAllText($childPath, $source, [Text.UTF8Encoding]::new($false))
    . (Join-Path $PSScriptRoot 'runner-support.ps1')
    # Restart the same installation inside its verified sandbox. A nested sandbox
    # correctly rejects the parent installation's config as an escaped path.
    $sandbox = $env:AGENT_HA_BRIDGE_TEST_ROOT
    $start = New-BridgeTestProcessStartInfo -ScriptPath $childPath -Sandbox $sandbox -Group Offline
    $start.Environment['AGENT_HA_BRIDGE_CONFIG'] = $script:BridgeInstallContext.ConfigPath
    $child = Invoke-BridgeTestProcess -StartInfo $start -TimeoutSeconds 30
    [pscustomobject]@{
        ExitCode = $child.ExitCode; TimedOut = $child.TimedOut
        Observation = (($child.Output -split '#< CLIXML', 2)[0].Trim() | ConvertFrom-Json)
    }
}

function Invoke-TestPreFencePublication {
    param([Parameter(Mandatory)][string]$CardSource, [object[]]$Sessions = @())

    # Exact publisher function extents from 1.22.2, commit 664814b6a5b97dc3e633d309d689d038c7830d75.
    # Archived rather than fetched so shallow checkouts run the same Offline proof.
    $compressed = [Convert]::FromBase64String('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')
    $inputStream = [IO.MemoryStream]::new($compressed)
    $gzip = [IO.Compression.GZipStream]::new($inputStream, [IO.Compression.CompressionMode]::Decompress)
    $reader = [IO.StreamReader]::new($gzip, [Text.Encoding]::UTF8)
    try { $source = $reader.ReadToEnd() }
    finally { $reader.Dispose(); $gzip.Dispose(); $inputStream.Dispose() }
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source)))
    if ($hash -cne '8342CD99E28AB9842002A9FE895890EB0363B488B792432595A0F283B8B4B28E') { throw 'The pinned pre-fence publisher fixture changed.' }
    . ([scriptblock]::Create($source))
    $script:BridgeDashboardReady = $false
    $legacyCard = Install-BridgeReplyCard -SourcePath $CardSource
    if (-not $legacyCard.Ok) { throw "Pinned publisher could not establish the card: $($legacyCard.Detail)" }
    Save-CopilotSessionDashboard -Sessions $Sessions -ReplyCardUrl $legacyCard.Url
}

if ($PublicationFixturesOnly) { return }

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-mqtt.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-ha-websocket.ps1')
# The failures these checks provoke on purpose went into the machine's real bridge log,
# where they buried real ones.
$script:DecisionBridgeConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-dashboard-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($ok) { Write-Host "  PASS  $Name" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

# Capture the config that would be saved instead of sending it to Home Assistant.
$script:SavedUrlPath = $null
$script:SavedConfig = $null
function Invoke-CopilotHaWebSocket {
    param([Parameter(Mandatory)][object[]]$Commands)
    Invoke-TestPublicationCommands -Commands $Commands
}
Initialize-TestPublicationStore
Initialize-TestPublicationAuthority

Write-Host '--- the dashboard is titled and routed correctly ---'
# Per-machine entity ids, derived rather than hard-coded so the suite passes on any
# machine including a CI runner. Without a -Machines list the dashboard renders the
# local machine alone, which is the single-machine case these tests cover.
$slug = Get-BridgeMachineSlug
$sessions = @(
    [pscustomobject]@{ Node = 'copilot_abc123def456'; Name = 'Copilot: my task'; Machine = 'BOX'; Kind = 'copilot' }
)
Set-TestPublicationCardUrl -Url ''
Save-CopilotSessionDashboard -Sessions $sessions
$cfg = $script:SavedConfig

Test-That 'the dashboard title is Agent Sessions' { $cfg.title -eq 'Agent Sessions' }
Test-That 'the view tab is titled Sessions' { $cfg.views[0].title -eq 'Sessions' }
Test-That 'the view path stays decision (URL slug unchanged)' { $cfg.views[0].path -eq 'decision' }
Test-That 'it is saved to the agent-decisions slug' { $script:SavedUrlPath -eq $script:DecisionBridgeConfig.DashboardUrlPath }

Write-Host '--- the control card summarises sessions and the installed version ---'
# The summary and its toggle are one stacked card now, so the markdown lives a level
# down rather than directly among the view's cards.
$agentCard = @($cfg.views[0].cards | Where-Object {
    $_.type -eq 'vertical-stack' -and @($_.cards | Where-Object { $_.type -eq 'markdown' -and $_.content -match 'Agent sessions' }).Count -gt 0
})[0]
Test-That 'the agent sessions card exists' { $null -ne $agentCard }
$control = @($agentCard.cards | Where-Object { $_.type -eq 'markdown' })[0]
Test-That 'the control markdown card exists' { $null -ne $control }
Test-That 'it shows the live session count' {
    # Summed across machines with int(0) on each term, so one machine's sensor being
    # briefly unavailable reads as zero rather than breaking the whole template.
    $control.content.Contains("states('sensor.agent_bridge_${slug}_sessions')|int(0)")
}
Test-That 'it shows the installed bridge version from the update entity' {
    $control.content.Contains("state_attr('update.agent_bridge_${slug}_update', 'installed_version')") -and
    $control.content.Contains('**Bridge**')
}

Write-Host '--- detailed activity is a setting, not a card ---'
# Folding session cards does what the toggle was for, and the toggle never changed how
# often anything is published, so it no longer takes a card of its own.
$toggleRows = @($agentCard.cards | Where-Object { $_.type -eq 'entities' } | ForEach-Object { $_.entities })
Test-That 'no Detailed activity toggle is drawn' {
    @($toggleRows | Where-Object { $_.entity -eq 'input_boolean.agent_bridge_detailed_activity' }).Count -eq 0 -and
        (($script:SavedConfig | ConvertTo-Json -Depth 40) -notmatch 'agent_bridge_detailed_activity')
}
Test-That 'and the summary no longer points at one' { $control.content -notmatch 'Detailed activity' }
Write-Host '--- the duplicate session counter is gone ---'
# The count is printed in the markdown above, so a sensor row repeating it was noise.
$allRows = @($cfg.views[0].cards | ForEach-Object {
    if ($_.type -eq 'vertical-stack') { $_.cards | Where-Object { $_.type -eq 'entities' } | ForEach-Object { $_.entities } }
    elseif ($_.type -eq 'entities') { $_.entities }
})
Test-That 'no card repeats the live-session sensor as a row' {
    @($allRows | Where-Object { $_.entity -eq "sensor.agent_bridge_${slug}_sessions" }).Count -eq 0
}
Test-That 'there is no longer a standalone toggle card beside the summary' {
    @($cfg.views[0].cards | Where-Object {
        $_.type -eq 'entities' -and @($_.entities | Where-Object { $_.entity -eq 'input_boolean.agent_bridge_detailed_activity' }).Count -gt 0
    }).Count -eq 0
}

Write-Host '--- from card 1.19.0 the summary and the machines are one folding card ---'
# Two markdown cards took a third of a phone screen to say "three sessions, nothing
# waiting", and the Detail switches sat in a list you had to match to machine names
# by eye. One card that folds says the same in a line, and puts each switch on the
# row of the machine it belongs to.
$twoMachines = @(
    [pscustomobject]@{ Slug = 'dswett_home'; Machine = 'DSWETT-HOME'; Online = $true; IncludeProfile = $false; IncludeResume = $true; IncludeAgent = $true; IncludeDetailed = $true }
    [pscustomobject]@{ Slug = 'dans_mbp'; Machine = 'Dans-MBP'; Online = $false; IncludeProfile = $false; IncludeResume = $true; IncludeAgent = $false; IncludeDetailed = $false }
)
Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.19.0'
Save-CopilotSessionDashboard -Sessions $sessions -Machines $twoMachines -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.19.0'
$status = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'custom:agent-bridge-status-card' })[0]
Test-That 'the status card is generated' { $null -ne $status }
Test-That 'it lists every machine that has registered, offline ones included' {
    (@($status['machines'] | ForEach-Object { [string]$_['machine'] }) -join ',') -eq 'DSWETT-HOME,Dans-MBP'
}
Test-That 'each with the entities it reads liveness, sessions and version from' {
    $m = @($status['machines'])[0]
    $m['online'] -eq 'binary_sensor.agent_bridge_dswett_home_online' -and
    $m['sessions'] -eq 'sensor.agent_bridge_dswett_home_sessions' -and
    $m['version'] -eq 'update.agent_bridge_dswett_home_update'
}
Test-That 'the Detail switch travels with the machine it belongs to' {
    @($status['machines'])[0]['detailed'] -eq 'input_boolean.agent_bridge_dswett_home_detailed_activity'
}
# The bug this guards: a peer on an older bridge has no such helper, so pointing a
# switch at one put an "Entity not found" box on everyone's dashboard.
Test-That 'and a machine that cannot have one is handed no entity for it' {
    -not @($status['machines'])[1].Contains('detailed')
}
Test-That 'it is given every session decision to count pending answers from' {
    @($status['decisions']) -contains 'select.copilot_abc123def456_decision'
}
Test-That 'the two markdown cards it replaces are gone, not left beside it' {
    $json = $script:SavedConfig | ConvertTo-Json -Depth 40 -Compress
    $json -notmatch '## Agent sessions' -and $json -notmatch '### Machines'
}
Test-That 'and it is the first card on the view' {
    [string]@($script:SavedConfig.views[0].cards)[0]['type'] -eq 'custom:agent-bridge-status-card'
}
Test-That 'a machine running a working copy is marked for the card to say so' {
    $dev = @([pscustomobject]@{ Slug = 'buildbox'; Machine = 'BUILDBOX'; Online = $true; IncludeProfile = $false; IncludeResume = $false; IncludeAgent = $false; IncludeDetailed = $true; IsDev = $true })
    Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.19.0'
    Save-CopilotSessionDashboard -Sessions $sessions -Machines $dev -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.19.0'
    $card = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'custom:agent-bridge-status-card' })[0]
    [bool]@($card['machines'])[0]['dev']
}
Test-That 'a card that predates the X is given no topics to clear with it' {
    # An older card drops config keys it does not know without a word, so the rows
    # would look fine while the X was never there to press.
    -not @($status['machines'])[1].Contains('forget')
}

Write-Host '--- from card 1.20.0 a machine that is gone can be removed from the row ---'
# A machine that was renamed or reimaged never publishes under its old name again, so
# nothing it left behind would ever be withdrawn and its row read "offline" for good.
$forgetful = @(
    [pscustomobject]@{ Slug = 'dswett_home'; Machine = 'DSWETT-HOME'; Online = $true; IncludeProfile = $false; IncludeResume = $true; IncludeAgent = $true; IncludeDetailed = $true
        SessionNodes = @('agent_bridge_abcdef0123456789') }
    [pscustomobject]@{ Slug = 'old_name'; Machine = 'OLD-NAME'; Online = $false; IncludeProfile = $false; IncludeResume = $false; IncludeAgent = $false; IncludeDetailed = $false }
)
Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.20.0'
Save-CopilotSessionDashboard -Sessions $sessions -Machines $forgetful -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.20.0'
$forgetStatus = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'custom:agent-bridge-status-card' })[0]
Test-That 'every machine is handed the topics that removing it would clear' {
    @($forgetStatus['machines'] | Where-Object { @($_['forget']).Count -gt 0 }).Count -eq 2
}
Test-That 'they are that machine own controls, and nobody else' {
    $topics = @(@($forgetStatus['machines'])[1]['forget'])
    ($topics -contains 'homeassistant/sensor/agent_bridge_old_name/sessions/config') -and
    ($topics -contains 'homeassistant/binary_sensor/agent_bridge_old_name/online/config') -and
    @($topics | Where-Object { $_ -match 'dswett_home' }).Count -eq 0
}
Test-That 'a machine running sessions has those cleared with it' {
    # Its session entities are retained too, and with the machine gone nothing else
    # would ever come back for them.
    $topics = @(@($forgetStatus['machines'])[0]['forget'])
    @($topics | Where-Object { $_ -match 'agent_bridge_abcdef0123456789' }).Count -ge 2
}

Write-Host '--- an older served card keeps the pair it knows how to draw ---'
Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.18.0'
Save-CopilotSessionDashboard -Sessions $sessions -Machines $twoMachines -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.18.0'
$oldStatusJson = $script:SavedConfig | ConvertTo-Json -Depth 40 -Compress
Test-That 'no status card is drawn for it' { $oldStatusJson -notmatch 'agent-bridge-status-card' }
Test-That 'so the summary is still there' { $oldStatusJson -match '## Agent sessions' }
Test-That 'and so is the Machines card' { $oldStatusJson -match '### Machines' }

Write-Host '--- a live session produces a card ---'
Test-That 'the control cards plus a session card are present' { @($cfg.views[0].cards).Count -ge 3 }

Write-Host '--- the session renders as one card, not a stack of loose ones ---'
$sessionCard = @($cfg.views[0].cards | Where-Object {
    $_.type -eq 'vertical-stack' -and @($_.cards | Where-Object { $_.type -eq 'markdown' -and $_.content -match 'my task' }).Count -gt 0
})[0]
Test-That 'the session card exists' { $null -ne $sessionCard }
Test-That 'the stack itself carries the border and background' {
    $sessionCard.card_mod.style -match ':host' -and
    $sessionCard.card_mod.style -match 'background' -and
    $sessionCard.card_mod.style -match 'border'
}
Test-That 'the state glow moved onto the stack' {
    $sessionCard.card_mod.style -match 'cpwait' -and $sessionCard.card_mod.style -match 'cpwork'
}
Test-That 'the gaps between sections are collapsed' {
    $sessionCard.card_mod.style -match 'margin-top:\s*0'
}
$sessionHeader = @($sessionCard.cards | Where-Object { $_.type -eq 'markdown' })[0]
Test-That 'the header no longer draws its own border' {
    $sessionHeader.card_mod.style -match 'border:\s*none'
}
Test-That 'the header no longer owns the glow' {
    $sessionHeader.card_mod.style -notmatch 'cpwait'
}
Test-That 'every inner card is transparent so one surface shows through' {
    $inner = @($sessionCard.cards | Where-Object { $_.type -in @('markdown', 'conditional') })
    $opaque = foreach ($c in $inner) {
        $target = if ($c.type -eq 'conditional') { $c.card } else { $c }
        if ("$($target.type)" -eq 'custom:button-card') {
            # A button-card carries its own styles block rather than card-mod.
            if (@($target.styles.card | Where-Object { $_.ContainsKey('background') -and $_['background'] -eq 'none' }).Count -eq 0) { $target }
        }
        elseif ("$($target.card_mod.style)" -notmatch 'background:\s*none') { $target }
    }
    @($opaque).Count -eq 0
}

Write-Host '--- the decision row says what it actually does ---'
# On a multi-field question the per-field dropdowns carry the answer and this selector
# offers only "Cancel request". Rendered as a dropdown it was a third thing to fill in,
# sitting exactly where the last field should have been - reported from the dashboard
# as "still three things to fill in" even after it had been relabelled.
$answerRow = @($sessionCard.cards | Where-Object {
    $_.type -eq 'conditional' -and $_.card.type -eq 'entities' -and
    "$($_.card.entities[0].entity)" -match '_decision$'
})[0]
$cancelRow = @($sessionCard.cards | Where-Object {
    $_.type -eq 'conditional' -and $_.card.type -eq 'custom:button-card' -and
    "$($_.card.name)" -eq 'Cancel this request'
})[0]

Test-That 'the answer dropdown is still there for a single-field question' {
    $null -ne $answerRow -and $answerRow.card.entities[0].name -eq 'Answer'
}
Test-That 'cancelling is a button, not another dropdown to fill in' {
    $null -ne $cancelRow
}
Test-That 'and it actually cancels when tapped' {
    "$($cancelRow.card.tap_action.perform_action)" -eq 'select.select_option' -and
    "$($cancelRow.card.tap_action.data.option)" -eq 'Cancel request'
}
Test-That 'Answer shows only when no field dropdown is in play' {
    @($answerRow.conditions | Where-Object {
        "$($_.entity)" -match '_f1$' -and "$($_.state)" -eq 'Idle'
    }).Count -eq 1
}
Test-That 'Cancel shows only when a field dropdown is in play' {
    @($cancelRow.conditions | Where-Object {
        "$($_.entity)" -match '_f1$' -and "$($_.state_not)" -eq 'Idle'
    }).Count -eq 1
}
Test-That 'so the two can never appear together' {
    $a = @($answerRow.conditions | Where-Object { "$($_.entity)" -match '_f1$' })[0]
    $c = @($cancelRow.conditions | Where-Object { "$($_.entity)" -match '_f1$' })[0]
    "$($a.entity)" -eq "$($c.entity)" -and "$($a.state)" -eq 'Idle' -and "$($c.state_not)" -eq 'Idle'
}
Test-That 'cancel sits with End session, not among the questions' {
    $idx = 0; $cancelIdx = -1; $replyIdx = -1
    foreach ($c in $sessionCard.cards) {
        if ($c.type -eq 'custom:layout-card') { $replyIdx = $idx }
        if ($c.type -eq 'conditional' -and $c.card.type -eq 'custom:button-card') { $cancelIdx = $idx }
        $idx++
    }
    $cancelIdx -gt $replyIdx -and $replyIdx -ge 0
}

Write-Host '--- End session is a footer, well away from Send ---'
$stop = $sessionCard.cards[-1]
Test-That 'End session is the last thing on the card' { $stop.entity -match '_stop$' }
Test-That 'send feedback sits next to Send, not in the header' {
    # The header is the first thing to scroll away on a long card, which is exactly
    # when "Sending..." or "NOT sent" needs to be visible.
    $idx = 0
    $statusIdx = -1
    $replyIdx = -1
    foreach ($c in $sessionCard.cards) {
        if ($c.type -eq 'custom:layout-card') { $replyIdx = $idx }
        if ($c.type -eq 'conditional' -and $c.card.type -eq 'markdown' -and
            "$($c.conditions[0].entity)" -match '_activity$') { $statusIdx = $idx }
        $idx++
    }
    $statusIdx -gt $replyIdx -and $replyIdx -ge 0
}
Test-That 'it only shows while reporting on something you just did' {
    $status = @($sessionCard.cards | Where-Object { $_.type -eq 'conditional' -and $_.card.type -eq 'markdown' })[0]
    @($status.conditions[0].state) -contains 'Sending...' -and @($status.conditions[0].state) -contains 'Reply NOT sent'
}
# End session asking for its second press is the one note here that has to be seen,
# and it has only the length of the confirmation window to be seen in.
$sendStatus = @($sessionCard.cards | Where-Object { $_.type -eq 'conditional' -and $_.card.type -eq 'markdown' })[0]
Test-That 'End session asking for confirmation is one of them' {
    @($sendStatus.conditions[0].state) -contains $script:CopilotEndSessionConfirmNote
}
Test-That 'and so is giving up on one' {
    @($sendStatus.conditions[0].state) -contains $script:CopilotEndSessionLapsedNote
}
Test-That 'the question is marked as a warning, not as something in progress' {
    "$($sendStatus.card.content)" -match [regex]::Escape("a == '$script:CopilotEndSessionConfirmNote'")
}
# Spelled with a capital NOT so it falls into the same warning branch as 'Reply NOT
# sent' without a second special case.
Test-That 'and so is the lapse, by the rule the other outcomes already use' {
    $script:CopilotEndSessionLapsedNote -cmatch 'NOT'
}
Test-That 'it is separated by a hairline rather than butting up to Send' {
    @($stop.styles.card | Where-Object { $_.ContainsKey('border-top') }).Count -gt 0
}
Test-That 'it is left-aligned, unlike the right-aligned Send button' {
    @($stop.styles.grid | Where-Object { $_.ContainsKey('justify-items') -and $_['justify-items'] -eq 'start' }).Count -gt 0
}
Test-That 'it is rendered muted rather than as a primary action' {
    @($stop.styles.name | Where-Object { $_.ContainsKey('color') -and $_['color'] -match 'secondary-text-color' }).Count -gt 0
}

# What a session was started with, quietly, at the bottom of its card. Rendered from
# the status sensor's attributes rather than baked in at build time, because the
# dashboard is only rebuilt when the session list changes - a model swapped
# mid-session would otherwise keep showing the one it started on.
$settings = @($sessionCard.cards | Where-Object {
    $_.type -eq 'markdown' -and "$($_.content)" -match "state_attr\('sensor\.copilot_abc123def456_status','model'\)"
})[0]
Test-That 'the card says what the session is running with' { $null -ne $settings }
Test-That 'all three settings are shown, not just the model' {
    "$($settings.content)" -match "'effort'" -and "$($settings.content)" -match "'context'"
}
# A session started at a keyboard has none of these, and a row of blanks - or a guess
# at the agent's defaults - would be worse than saying nothing.
Test-That 'a session with none of them shows no line at all' {
    "$($settings.content)" -match 'if bits'
}
Test-That 'it sits at the bottom, just above End session' {
    $idx = 0; $settingsIdx = -1
    foreach ($c in $sessionCard.cards) {
        if ($c.type -eq 'markdown' -and "$($c.content)" -match "_status','model'") { $settingsIdx = $idx }
        $idx++
    }
    $settingsIdx -eq $sessionCard.cards.Count - 2
}
Test-That 'Send and End are not in the same row' {
    $replyRow = @($sessionCard.cards | Where-Object { $_.type -eq 'custom:layout-card' })[0]
    $inRow = @($replyRow.cards | ForEach-Object { if ($_.ContainsKey('entity')) { [string]$_['entity'] } else { '' } })
    ($inRow -join ' ') -notmatch '_stop'
}
Test-That 'Send is still in the reply row' {
    $replyRow = @($sessionCard.cards | Where-Object { $_.type -eq 'custom:layout-card' })[0]
    $inRow = @($replyRow.cards | ForEach-Object { if ($_.ContainsKey('entity')) { [string]$_['entity'] } else { '' } })
    ($inRow -join ' ') -match '_submit'
}

Write-Host ''
Write-Host '--- a free-text field leaves no empty dropdown behind ---'
# A text field is answered through the reply box, not a dropdown, so its slot is
# published with only the 'Idle' option. It was still *started* on 'Choose...', a value
# not in its own option list, so the dashboard's "hide while Idle" condition failed and
# a blank dropdown appeared between the real ones.
$script:FieldStarts = @{}
$script:FieldOptions = @{}
function Publish-CopilotMqttMessage {
    param([string]$Topic, [string]$Payload, [hashtable]$Headers, [switch]$Retain)
    if ($Topic -match '/select/[^/]+/(f\d)/config$') {
        $script:FieldOptions[$Matches[1]] = ($Payload | ConvertFrom-Json).options
    }
}
function Invoke-HomeAssistantService {
    param([string]$Domain, [string]$Service, [hashtable]$Headers, [hashtable]$Data)
    if ("$($Data.entity_id)" -match '_(f\d)$') { $script:FieldStarts[$Matches[1]] = [string]$Data.option }
}
function Set-CopilotMqttEntityIds { param([string]$SessionId) }

$mixedFields = @(
    [pscustomobject]@{ Label = 'Glow';  Options = @('Amber', 'Blue'); IsText = $false }
    [pscustomobject]@{ Label = 'Notes'; Options = @();                IsText = $true }
    [pscustomobject]@{ Label = 'Pick';  Options = @('One', 'Two');    IsText = $false }
)
Publish-CopilotMqttDecisionFields -SessionId 'abc123de-f456-7890-abcd-ef1234567890' `
    -SessionName 'S' -Machine 'BOX' -Fields $mixedFields -Headers @{ Authorization = '******' }

Test-That 'the two choice fields start on Choose...' {
    $script:FieldStarts['f1'] -eq 'Choose...' -and $script:FieldStarts['f3'] -eq 'Choose...'
}
Test-That 'the free-text slot is parked on Idle, like an unused one' {
    $script:FieldStarts['f2'] -eq 'Idle' -and $script:FieldStarts['f4'] -eq 'Idle'
}
Test-That 'and its starting value is one of its own options' {
    @($script:FieldOptions['f2']) -contains $script:FieldStarts['f2']
}
Test-That 'the choice slots still carry their real options' {
    @($script:FieldOptions['f1']) -contains 'Amber' -and @($script:FieldOptions['f3']) -contains 'Two'
}

# A multi-select field cannot be offered as its bare options: a Home Assistant select
# holds one value, so picking one would quietly answer "choose any" with exactly one.
# Its dropdown carries the combinations instead.
$script:FieldOptions = @{}; $script:FieldStarts = @{}
$msFields = @(
    [pscustomobject]@{ Label = 'Envs';  Options = @('Staging', 'Production'); IsText = $false; MultiSelect = $true }
    [pscustomobject]@{ Label = 'Pick';  Options = @('One', 'Two');            IsText = $false }
)
Publish-CopilotMqttDecisionFields -SessionId 'abc123de-f456-7890-abcd-ef1234567890' `
    -SessionName 'S' -Machine 'BOX' -Fields $msFields -Headers @{ Authorization = '******' }

Test-That 'a multi-select slot lists every combination' {
    # Written out for any card up to 1.22.0, then the same subsets as positions for
    # 1.23.0 and later. Both, because the hook publishing this cannot see which card
    # Home Assistant is serving and a select rejects a value outside its own list.
    (@($script:FieldOptions['f1']) -join ' / ') -eq
        'Choose... / Staging / Production / Staging + Production / #1 / #2 / #1,2'
} (@($script:FieldOptions['f1']) -join ' / ')
Test-That 'a single-select slot beside it is unchanged' {
    (@($script:FieldOptions['f2']) -join ' / ') -eq 'Choose... / One / Two'
} (@($script:FieldOptions['f2']) -join ' / ')
Test-That 'and it still starts on Choose...' { $script:FieldStarts['f1'] -eq 'Choose...' }

Write-Host ''
Write-Host '--- the new-session card is only what a launch needs ---'
# The card exists to be one press: every selector carries a default. The first
# message is back, optional: Codex creates no session until it has one. The launch
# note sits in the same stack, right under Launch, so a press never looks ignored.
Set-TestPublicationCardUrl -Url ''
Save-CopilotSessionDashboard -Sessions $sessions -IncludeProfile -IncludeResume
$launchStack = @($script:SavedConfig.views[0].cards | Where-Object {
    $_['type'] -eq 'vertical-stack' -and @($_['cards'] | Where-Object { $_.ContainsKey('title') -and $_['title'] -eq 'Start a new session' }).Count -gt 0
})[0]
$newCard = @($launchStack['cards'] | Where-Object { $_.ContainsKey('title') -and $_['title'] -eq 'Start a new session' })[0]
$newRows = @($newCard.entities | ForEach-Object {
    if ($_.ContainsKey('entity')) { [string]$_['entity'] } else { '' }
})

Test-That 'the card is still generated' { $null -ne $newCard }
Test-That 'it keeps the selectors and Launch' {
    ($newRows -contains "select.agent_bridge_${slug}_new_resume") -and
    ($newRows -contains "select.agent_bridge_${slug}_new_workspace") -and
    ($newRows -contains "select.agent_bridge_${slug}_new_profile") -and
    ($newRows -contains "button.agent_bridge_${slug}_new_session")
}
Test-That 'the last-launch result is not a row' {
    $newRows -notcontains "sensor.agent_bridge_${slug}_new_session_result"
}
Test-That 'an optional first message is offered' {
    $newRows -contains "text.agent_bridge_${slug}_new_prompt"
}
Test-That 'Launch is the last thing on the card' { $newRows[-1] -eq "button.agent_bridge_${slug}_new_session" }
Test-That 'the launch note sits right under the card, only when there is something to say' {
    $note = @($launchStack['cards'] | Where-Object {
        $_['type'] -eq 'conditional' -and $_['card']['type'] -eq 'markdown' -and
        [string]$_['card']['content'] -match 'new_session_result'
    })[0]
    $null -ne $note -and
    @($note['conditions'] | ForEach-Object { [string]$_['state_not'] }) -contains '' -and
    @($note['conditions'] | ForEach-Object { [string]$_['state_not'] }) -contains 'unknown'
}

# From card 1.12.0 the bridge draws a compact launch card of its own.
Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.12.0'
Save-CopilotSessionDashboard -Sessions $sessions -IncludeProfile -IncludeResume -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.12.0'
$compact = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'custom:agent-bridge-launch-card' })
Test-That 'a served 1.12.0 card gets the compact launch card' { $compact.Count -eq 1 }
Test-That 'which carries every control of the machine' {
    $m = @($compact[0]['machines'])[0]
    $m['launch'] -eq "button.agent_bridge_${slug}_new_session" -and $m['prompt'] -eq "text.agent_bridge_${slug}_new_prompt" -and
        $m['result'] -eq "sensor.agent_bridge_${slug}_new_session_result" -and $m['workspace'] -eq "select.agent_bridge_${slug}_new_workspace"
}
Test-That 'and no separate launch cards are left beside it' {
    @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'vertical-stack' -and ($_ | ConvertTo-Json -Depth 20) -match 'new_session_result' }).Count -eq 0
}
Set-TestPublicationCardUrl -Url ''
Save-CopilotSessionDashboard -Sessions $sessions -IncludeProfile -IncludeResume
Test-That 'there is no agent row when there is nothing to choose between' {
    $newRows -notcontains "select.agent_bridge_${slug}_new_agent"
}

Set-TestPublicationCardUrl -Url ''
Save-CopilotSessionDashboard -Sessions $sessions -IncludeAgent
$newCard = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'vertical-stack' } | ForEach-Object { $_['cards'] } |
    Where-Object { $_.ContainsKey('title') -and $_['title'] -eq 'Start a new session' })[0]
$agentRows = @($newCard.entities | ForEach-Object { if ($_.ContainsKey('entity')) { [string]$_['entity'] } else { '' } })
Test-That 'with several agents installed the agent row is shown' {
    $agentRows -contains "select.agent_bridge_${slug}_new_agent"
}
Test-That 'the agent row sits under the workspace' {
    $agentRows.IndexOf("select.agent_bridge_${slug}_new_agent") -eq $agentRows.IndexOf("select.agent_bridge_${slug}_new_workspace") + 1
}

# Model, effort and context. Reported as a capability of their own, so a peer still
# running a bridge without those entities gets a launch card without the rows rather
# than three "Entity not found" boxes.
Set-TestPublicationCardUrl -Url ''
Save-CopilotSessionDashboard -Sessions $sessions -IncludeAgent -IncludeTuning
$tunedCard = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'vertical-stack' } | ForEach-Object { $_['cards'] } |
    Where-Object { $_.ContainsKey('title') -and $_['title'] -eq 'Start a new session' })[0]
$tunedRows = @($tunedCard.entities | ForEach-Object { if ($_.ContainsKey('entity')) { [string]$_['entity'] } else { '' } })
Test-That 'the tuning rows are shown when the machine has them' {
    @('model', 'effort', 'context') | ForEach-Object { $tunedRows -contains "select.agent_bridge_${slug}_new_$_" } |
        Where-Object { -not $_ } | Measure-Object | ForEach-Object { $_.Count -eq 0 }
}
# Their options belong to whichever agent is selected, so choosing the agent is what
# decides what they can offer: reading top-to-bottom is also the order to set them in.
Test-That 'and sit below the agent that decides what they offer' {
    $tunedRows.IndexOf("select.agent_bridge_${slug}_new_model") -gt $tunedRows.IndexOf("select.agent_bridge_${slug}_new_agent")
}
Test-That 'Launch is still the last thing on the card' {
    $tunedRows[-1] -eq "button.agent_bridge_${slug}_new_session"
}
Test-That 'a machine without them gets no tuning rows at all' {
    @('model', 'effort', 'context') | ForEach-Object { $agentRows -contains "select.agent_bridge_${slug}_new_$_" } |
        Where-Object { $_ } | Measure-Object | ForEach-Object { $_.Count -eq 0 }
}

# The compact card draws them itself, and only from 1.16.0 - an older card silently
# ignores keys it does not know, which would look like the rows had simply vanished.
Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.16.0'
Save-CopilotSessionDashboard -Sessions $sessions -IncludeAgent -IncludeTuning -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.16.0'
$tunedCompact = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'custom:agent-bridge-launch-card' })[0]
Test-That 'the compact card is handed all three tuning entities' {
    $m = @($tunedCompact['machines'])[0]
    $m['model'] -eq "select.agent_bridge_${slug}_new_model" -and
    $m['effort'] -eq "select.agent_bridge_${slug}_new_effort" -and
    $m['context'] -eq "select.agent_bridge_${slug}_new_context"
}
Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.15.0'
Save-CopilotSessionDashboard -Sessions $sessions -IncludeAgent -IncludeTuning -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.15.0'
$oldCompact = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'custom:agent-bridge-launch-card' })[0]
Test-That 'a card too old to draw them is not handed them' {
    -not @($oldCompact['machines'])[0].Contains('model')
}

# Permissions. The machine that runs the session is not always the one choosing, so
# the row has to reach the dashboard the peer draws - the row and the card entry were
# both added at once, and each fails invisibly on its own.
Set-TestPublicationCardUrl -Url ''
Save-CopilotSessionDashboard -Sessions $sessions -IncludeAgent -IncludeTuning -IncludePermissions
$permCard = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'vertical-stack' } | ForEach-Object { $_['cards'] } |
    Where-Object { $_.ContainsKey('title') -and $_['title'] -eq 'Start a new session' })[0]
$permRows = @($permCard.entities | ForEach-Object { if ($_.ContainsKey('entity')) { [string]$_['entity'] } else { '' } })
Test-That 'the permissions row is shown when the machine offers it' {
    $permRows -contains "select.agent_bridge_${slug}_new_permissions"
}
Test-That 'it sits below the settings it applies to, and above Launch' {
    $permRows.IndexOf("select.agent_bridge_${slug}_new_permissions") -gt $permRows.IndexOf("select.agent_bridge_${slug}_new_model") -and
    $permRows.IndexOf("select.agent_bridge_${slug}_new_permissions") -lt $permRows.IndexOf("button.agent_bridge_${slug}_new_session")
}
Test-That 'a machine that does not offer it gets no such row' {
    $tunedRows -notcontains "select.agent_bridge_${slug}_new_permissions"
}

Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.17.0'
Save-CopilotSessionDashboard -Sessions $sessions -IncludeAgent -IncludeTuning -IncludePermissions -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.17.0'
$permCompact = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'custom:agent-bridge-launch-card' })[0]
Test-That 'the compact card is handed the permissions entity' {
    @($permCompact['machines'])[0]['permissions'] -eq "select.agent_bridge_${slug}_new_permissions"
} ([string](@($permCompact['machines'])[0]['permissions']))
Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.16.0'
Save-CopilotSessionDashboard -Sessions $sessions -IncludeAgent -IncludeTuning -IncludePermissions -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.16.0'
$preCompact = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'custom:agent-bridge-launch-card' })[0]
Test-That 'and a card too old to draw it is not, so it is never silently dropped' {
    -not @($preCompact['machines'])[0].Contains('permissions')
}

# The long first message arrived with 1.18.0. A card that knows the topic publishes
# the whole prompt there; an older one writes the text entity, which Home Assistant
# caps at 255 characters.
Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.18.0'
Save-CopilotSessionDashboard -Sessions $sessions -IncludeAgent -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.18.0'
$promptCompact = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'custom:agent-bridge-launch-card' })[0]
Test-That 'a 1.18.0 card is told where to publish a long first message' {
    @($promptCompact['machines'])[0]['promptTopic'] -match 'newsession/promptpayload$'
} ([string](@($promptCompact['machines'])[0]['promptTopic']))
Test-That 'and still gets the text entity, so it has something to fall back on' {
    @($promptCompact['machines'])[0]['prompt'] -eq "text.agent_bridge_${slug}_new_prompt"
}
Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.17.0'
Save-CopilotSessionDashboard -Sessions $sessions -IncludeAgent -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.17.0'
$oldPromptCompact = @($script:SavedConfig.views[0].cards | Where-Object { $_['type'] -eq 'custom:agent-bridge-launch-card' })[0]
Test-That 'a 1.17.0 card is not handed a key it would drop' {
    -not @($oldPromptCompact['machines'])[0].Contains('promptTopic')
}

Write-Host ''
Write-Host '--- the session header updates in place when the card supports it ---'
# The markdown header re-renders wholesale on every attribute change, collapsing the
# reasoning expander while it streams. The activity card ships in the reply card's
# file from 1.10.0, and naming it against an older served copy would render an error.
function Get-SavedJson { $script:SavedConfig | ConvertTo-Json -Depth 40 -Compress }

Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.10.0'
Save-CopilotSessionDashboard -Sessions $sessions -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.10.0'
Test-That 'a served 1.10.0 card gets the in-place activity header' { (Get-SavedJson) -match 'custom:agent-bridge-activity-card' }
Test-That 'the header is pointed at the session entities' {
    (Get-SavedJson) -match [regex]::Escape("sensor.$($sessions[0].Node)_activity")
}

Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.9.2'
Save-CopilotSessionDashboard -Sessions $sessions -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.9.2'
Test-That 'an older served card keeps the markdown header' { (Get-SavedJson) -notmatch 'custom:agent-bridge-activity-card' }

Set-TestPublicationCardUrl -Url ''
Save-CopilotSessionDashboard -Sessions $sessions
Test-That 'no served card keeps the markdown header' { (Get-SavedJson) -notmatch 'custom:agent-bridge-activity-card' }

Test-That 'the version gate reads the cache-buster' {
    (Test-BridgeActivityCardServed -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.10.1') -and
    (Test-BridgeActivityCardServed -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=2.0') -and
    -not (Test-BridgeActivityCardServed -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.9.9') -and
    -not (Test-BridgeActivityCardServed -ReplyCardUrl '/local/agent-bridge-reply-card.js')
}

Write-Host ''
Write-Host '--- the session frame does not depend on card-mod loading first ---'
# A card-mod-styled vertical-stack lost its outline, background and glow on a hard
# refresh whenever it was built before card-mod loaded. From 1.12.0 the bridge's own
# card draws them.
Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.12.0'
Save-CopilotSessionDashboard -Sessions $sessions -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.12.0'
$framed = $script:SavedConfig | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
$sessionCard = @($framed.views[0].cards | Where-Object { $_.type -eq 'custom:agent-bridge-session-card' }) | Select-Object -First 1
Test-That 'a served 1.12.0 card frames each session with the session card' { $null -ne $sessionCard }
Test-That 'which watches the session status and decision for its glow' {
    $sessionCard.status -eq "sensor.$($sessions[0].Node)_status" -and $sessionCard.decision -eq "select.$($sessions[0].Node)_decision"
}
# The driver is an attribute of the activity sensor, so a frame not given that entity
# reads every session as yours and can never show the purple edge - which is exactly
# what shipped, on every dashboard, for three releases. The card's own test supplies
# all three keys itself, so nothing failed while the view handed over only two.
Test-That 'and the activity entity, without which the agent glow can never fire' {
    $sessionCard.activity -eq "sensor.$($sessions[0].Node)_activity"
} "activity=[$(if ($sessionCard.PSObject.Properties['activity']) { $sessionCard.activity } else { '<missing>' })]"
Test-That 'and holds the session sections' { @($sessionCard.cards | Where-Object { $_.type -eq 'custom:agent-bridge-activity-card' }).Count -eq 1 }

# A question is answered through the entities: the daemon reads the free-text field
# from text.<node>_reply and waits for a press on button.<node>_submit. The reply card
# writes neither - its Send publishes an MQTT payload, which the reply path ignores
# while a question owns the box, and it returns early on an empty textarea. So a form
# under the card took every dropdown and did nothing at all on Send, silently and with
# nothing in the daemon log. The pair has to come back while a question is armed.
$decEntity = "select.$($sessions[0].Node)_decision"
$cardWhenFree = @($sessionCard.cards | Where-Object {
    $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'custom:agent-bridge-reply-card' })
$pairWhenAsked = @($sessionCard.cards | Where-Object {
    $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'custom:layout-card' })
Test-That 'the reply card is shown only while no question is waiting' {
    $cardWhenFree.Count -eq 1 -and
        @($cardWhenFree[0].conditions | Where-Object { $_.entity -eq $decEntity -and @($_.state) -contains 'Idle' }).Count -eq 1
} "found $($cardWhenFree.Count)"
Test-That 'and the entity pair, which can actually answer one, takes over when it is' {
    $pairWhenAsked.Count -eq 1 -and
        @($pairWhenAsked[0].conditions | Where-Object { $_.entity -eq $decEntity -and "$($_.state_not)" -eq 'Idle' }).Count -eq 1
} "found $($pairWhenAsked.Count)"
Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.11.3'
Save-CopilotSessionDashboard -Sessions $sessions -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.11.3'
Test-That 'an older served card keeps the styled stack' { (Get-SavedJson) -notmatch 'agent-bridge-session-card' }

Write-Host ''
Write-Host '--- a waiting question is answered by rows, not a dropdown ---'
# Home Assistant's select sizes its menu to the longest option and will not wrap, so on
# a phone a question whose answers are sentences ran off the edge of the screen.
Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.13.0'
Save-CopilotSessionDashboard -Sessions $sessions -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.13.0'
$rowsCard = $script:SavedConfig | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
$rowsSession = @($rowsCard.views[0].cards | Where-Object { $_.type -eq 'custom:agent-bridge-session-card' }) | Select-Object -First 1
$answer = @($rowsSession.cards | Where-Object {
    $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'custom:agent-bridge-choices-card'
})[0]
Test-That 'a served 1.13.0 card answers with the choices card' { $null -ne $answer }
Test-That 'pointed at the session''s decision entity' { $answer.card.decision -eq "select.$($sessions[0].Node)_decision" }
Test-That 'it is transparent like every other section' { "$($answer.card.card_mod.style)" -match 'background:\s*none' }
Test-That 'and still only while no field dropdown is in play' {
    @($answer.conditions | Where-Object { "$($_.entity)" -match '_f1$' -and "$($_.state)" -eq 'Idle' }).Count -eq 1
}
Test-That 'the dropdown row is gone with it' {
    @($rowsSession.cards | Where-Object {
        $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'entities' -and
        "$($_.card.entities[0].entity)" -match '_decision$'
    }).Count -eq 0
}
Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.12.3'
Save-CopilotSessionDashboard -Sessions $sessions -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.12.3'
Test-That 'an older served card keeps the dropdown, not an error box' {
    (Get-SavedJson) -notmatch 'agent-bridge-choices-card'
}

Write-Host ''
Write-Host '--- and from 1.15.0 the same card answers the whole form ---'
# A form used to render as one native dropdown per field. A native select commits on
# blur, so an answer needed a tap away and then Send, and it sizes its menu to the
# longest option without wrapping, so sentence-length answers were cut off on a phone.
# The card draws a labelled group of rows per field instead - but only if the view
# actually hands it the field entities, which is the link this pins down.
Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.15.0'
Save-CopilotSessionDashboard -Sessions $sessions -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.15.0'
$formDash = $script:SavedConfig | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
$formSession = @($formDash.views[0].cards | Where-Object { $_.type -eq 'custom:agent-bridge-session-card' }) | Select-Object -First 1
$formAnswer = @($formSession.cards | Where-Object {
    $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'custom:agent-bridge-choices-card'
})[0]
$node = $sessions[0].Node
Test-That 'the choices card is handed the field entities' {
    $null -ne $formAnswer -and $formAnswer.card.PSObject.Properties['fields']
} "fields=[$(if ($null -ne $formAnswer -and $formAnswer.card.PSObject.Properties['fields']) { @($formAnswer.card.fields) -join ',' } else { '<missing>' })]"
# The ids themselves, not just their presence: the card sets these entities and
# Read-DaemonFormAnswer reads them, so a rename on either side is a form that takes
# every tap and delivers nothing. Both sides are asked the same helper.
Test-That 'and they are exactly the slots the daemon reads, in slot order' {
    $expected = @(1..4 | ForEach-Object { Get-CopilotMqttFieldEntityId -Node $node -Index $_ })
    (@($formAnswer.card.fields) -join ',') -eq ($expected -join ',')
} "fields=[$(@($formAnswer.card.fields) -join ',')]"
Test-That 'the answer card no longer hides itself when a field is in play' {
    @($formAnswer.conditions | Where-Object { "$($_.entity)" -match '_f\d$' }).Count -eq 0
}
Test-That 'the per-field dropdowns it replaces are gone' {
    @($formSession.cards | Where-Object {
        $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'entities' -and
        "$($_.card.entities[0].entity)" -match '_f\d$'
    }).Count -eq 0
}
Test-That 'and so is the separate cancel button, which the card draws as a row' {
    @($formSession.cards | Where-Object {
        $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'custom:button-card' -and
        "$($_.card.name)" -eq 'Cancel this request'
    }).Count -eq 0
}
Test-That 'the entity pair still takes over the reply box while a question is armed' {
    @($formSession.cards | Where-Object {
        $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'custom:layout-card'
    }).Count -eq 1
}
Test-That 'End session is still the last thing on the card' {
    "$($formSession.cards[-1].entity)" -match '_stop$'
}
Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.14.5'
Save-CopilotSessionDashboard -Sessions $sessions -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.14.5'
$oldDash = $script:SavedConfig | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
$oldSession = @($oldDash.views[0].cards | Where-Object { $_.type -eq 'custom:agent-bridge-session-card' }) | Select-Object -First 1
Test-That 'a card served before 1.15.0 keeps its dropdowns rather than an empty form' {
    @($oldSession.cards | Where-Object {
        $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'entities' -and
        "$($_.card.entities[0].entity)" -match '_f\d$'
    }).Count -eq 4
}
Test-That 'and is handed no fields it would not know what to do with' {
    $old = @($oldSession.cards | Where-Object {
        $_.type -eq 'conditional' -and "$($_.card.type)" -eq 'custom:agent-bridge-choices-card'
    })[0]
    $null -ne $old -and -not $old.card.PSObject.Properties['fields']
}

Write-Host '--- the dashboard is provisioned before it is written to ---'
Initialize-TestPublicationStore
Initialize-TestPublicationAuthority
$provisioningStore = Get-TestPublicationStore
$provisioningStore.dashboards = @(
    @{ url_path = 'copilot-decisions'; id = 'old-id'; title = 'Agent Sessions' }
    @{ url_path = 'lovelace'; id = 'home-id'; title = 'Home' }
)
$provisioningStore.configs['copilot-decisions'] = @{ title = 'Legacy'; views = @() }
Set-TestPublicationStore $provisioningStore
$script:BridgeDashboardReady = $false
Initialize-BridgeDashboard
Test-That 'creation alone does not delete the legacy view before a replacement is published' {
    @($script:TestPublication.Commands | Where-Object { $_.type -eq 'lovelace/dashboards/delete' }).Count -eq 0
}
Save-CopilotSessionDashboard -Sessions @()
$script:SentCommands = @($script:TestPublication.Commands)

$created = @($script:SentCommands | Where-Object { $_.type -eq 'lovelace/dashboards/create' })
$deleted = @($script:SentCommands | Where-Object { $_.type -eq 'lovelace/dashboards/delete' })

Test-That 'the target dashboard is created when it is missing' { $created.Count -eq 1 }
Test-That 'it is created at the configured slug' {
    $created[0].url_path -eq $script:DecisionBridgeConfig.DashboardUrlPath
}
Test-That 'it is created as Agent Sessions' { $created[0].title -eq 'Agent Sessions' }
Test-That 'it is shown in the sidebar' { $created[0].show_in_sidebar }
Test-That 'the pre-rename dashboard is removed' { $deleted.Count -eq 1 }
Test-That 'it is removed by id, not by slug' { $deleted[0].dashboard_id -eq 'old-id' }
Test-That 'the replacement is created before the old one is deleted' {
    $types = @($script:SentCommands | ForEach-Object { $_.type })
    [array]::IndexOf($types, 'lovelace/dashboards/create') -lt [array]::IndexOf($types, 'lovelace/dashboards/delete')
}
Test-That 'the replacement is saved before the old one is deleted' {
    $types = @($script:SentCommands | ForEach-Object { $_.type })
    [array]::IndexOf($types, 'lovelace/config/save') -lt [array]::IndexOf($types, 'lovelace/dashboards/delete')
}
Test-That 'an unrelated dashboard is left alone' {
    -not (@($deleted | Where-Object { $_.dashboard_id -eq 'home-id' }).Count)
}

Write-Host '--- an unchanged view is inspected without rewriting it ---'
$script:TestPublication.Commands.Clear()
Initialize-BridgeDashboard
Test-That 'a second call makes no further writes' { @(Get-TestPublicationWrites).Count -eq 0 }
Test-That 'but it checks that the actual dashboard still exists' {
    @($script:TestPublication.Commands | Where-Object { $_.type -eq 'lovelace/dashboards/list' }).Count -gt 0
}

Write-Host '--- an existing dashboard is left as it is ---'
$script:TestPublication.Commands.Clear()
$script:BridgeDashboardReady = $false
Initialize-BridgeDashboard
$script:SentCommands = @($script:TestPublication.Commands)
Test-That 'nothing is created when the dashboard already exists' {
    -not (@($script:SentCommands | Where-Object { $_.type -eq 'lovelace/dashboards/create' }).Count)
}
Test-That 'nothing is deleted when there is no pre-rename dashboard' {
    -not (@($script:SentCommands | Where-Object { $_.type -eq 'lovelace/dashboards/delete' }).Count)
}

Write-Host ''
Write-Host '--- explicit policy generations, rollback and real failure paths ---'
& {
    $previousFrontendNoRun = $env:BRIDGE_FRONTEND_NORUN
    $env:BRIDGE_FRONTEND_NORUN = '1'
    . (Join-Path $PSScriptRoot '..\hooks\bridge-frontend-cards.ps1')
    if ($null -eq $previousFrontendNoRun) { Remove-Item Env:\BRIDGE_FRONTEND_NORUN }
    else { $env:BRIDGE_FRONTEND_NORUN = $previousFrontendNoRun }
    $originalRenderVersion = $script:BridgeDashboardRenderVersion
    try {
        Test-That 'publication hashing preserves empty arrays and sorted single strings as JSON values' {
            (ConvertTo-BridgePublicationJson @{ nodes = @('one' | Sort-Object); empty = @() }) -ceq '{"empty":[],"nodes":["one"]}'
        }
        Initialize-TestPublicationStore
        $oldSource = New-TestPublicationCard '2.0.0'
        $newSource = New-TestPublicationCard '3.0.0'
        $oldTarget = Get-BridgePublicationTarget -CardSourcePath $oldSource
        Test-That 'the composed renderer target advances independently of the card version' {
            # The composed renderer, not a literal: the two versions move for different
            # reasons, and pinning one here made a generator change look like a test
            # failure rather than the fence advance it is.
            $oldTarget.render.version -ceq (Get-BridgeRenderArtifact).version -and $oldTarget.card.version -ceq '2.0.0' -and
                $oldTarget.render.hash -ceq (Get-BridgeRenderArtifact).hash
        }
        Set-TestPublicationCardUrl -Url (Get-BridgeInlineReplyCardUrl -SourcePath $newSource -Version '3.0.0')
        Test-That 'bootstrap cannot silently set a fence below an actually observed newer card' {
            try { Set-BridgePublicationPolicy -ExpectedGeneration 0 -ExpectedPolicyHash absent -Target $oldTarget | Out-Null; $false }
            catch { $_.Exception.Message -match 'older|rollback' -and @(Get-TestPublicationWrites).Count -eq 0 }
        }
        Initialize-TestPublicationStore
        Set-BridgePublicationPolicy -ExpectedGeneration 0 -ExpectedPolicyHash absent -Target $oldTarget | Out-Null
        $installed = Install-BridgeReplyCard -SourcePath $oldSource
        Save-CopilotSessionDashboard -Sessions @()
        Test-That 'one explicit bootstrap establishes policy, card and a verified dashboard' {
            $installed.Ok -and (Get-BridgeDashboardPublication).Verified
        }
        Test-That 'the policy uses only actual HA resource storage fields' {
            $record = @((Get-TestPublicationStore).resources | Where-Object { $_.url -match '#agent-bridge-publication-policy\.js' })[0]
            (@($record.Keys | Sort-Object) -join ',') -ceq 'id,type,url'
        }

        $boundaryReceiptPath = Get-BridgePublicationReceiptPath
        $boundaryReceiptBytes = [IO.File]::ReadAllBytes($boundaryReceiptPath)
        $boundaryStore = Get-TestPublicationStore
        try {
            [IO.File]::WriteAllText($boundaryReceiptPath, '{"protocol":', [Text.UTF8Encoding]::new($false))
            $script:TestPublication.Commands.Clear()
            Test-That 'card publication propagates a marked receipt read instead of returning a blocked result' {
                try { Install-BridgeReplyCard -SourcePath $oldSource | Out-Null; $false }
                catch {
                    $_.Exception.Data['BridgeTestWriteBlocked'] -eq $true -and
                        @(Get-TestPublicationWrites).Count -eq 0
                }
            }
            [IO.File]::WriteAllBytes($boundaryReceiptPath, $boundaryReceiptBytes)

            $boundarySource = New-TestPublicationCard '2.1.0'
            $boundaryProbe = @{
                ReceiptPath = $boundaryReceiptPath
                CardResourceId = (Get-BridgeReplyCardState).ResourceId
                CardWriteSeen = $false
                WritesAtCorruption = 0
            }
            $boundaryInvoker = {
                param([hashtable[]]$Commands)
                $responses = Invoke-TestPublicationCommands -Commands $Commands
                foreach ($command in $Commands) {
                    if ($command.type -ceq 'lovelace/resources/update' -and
                        $command.resource_id -ceq $boundaryProbe.CardResourceId) {
                        [IO.File]::WriteAllText($boundaryProbe.ReceiptPath, '{"protocol":', [Text.UTF8Encoding]::new($false))
                        $boundaryProbe.CardWriteSeen = $true
                        $boundaryProbe.WritesAtCorruption = @(Get-TestPublicationWrites).Count
                    }
                }
                Write-Output -NoEnumerate $responses
            }
            Test-That 'card confirmation propagates a real marked receipt error after its synthetic write' {
                try { Install-BridgeReplyCard -SourcePath $boundarySource -Invoker $boundaryInvoker | Out-Null; $false }
                catch {
                    $_.Exception.Data['BridgeTestWriteBlocked'] -eq $true -and $boundaryProbe.CardWriteSeen -and
                        @(Get-TestPublicationWrites).Count -eq $boundaryProbe.WritesAtCorruption
                }
            }
        }
        finally {
            [IO.File]::WriteAllBytes($boundaryReceiptPath, $boundaryReceiptBytes)
            Set-TestPublicationStore $boundaryStore
            $script:TestPublication.Commands.Clear()
        }

        $script:BridgeDashboardRenderVersion = '1.0.0'
        $script:TestPublication.Commands.Clear()
        Test-That 'the previous renderer version cannot replace the composed publication' {
            try { Save-CopilotSessionDashboard -Sessions @() | Out-Null; $false }
            catch { $_.Exception.Message -match 'older.*render' -and @(Get-TestPublicationWrites).Count -eq 0 }
        }
        $script:BridgeDashboardRenderVersion = $originalRenderVersion

        # Participating renderer versions share the fencing protocol; the pinned
        # unmodified 1.22.2 implementation is exercised separately, not modeled here.
        $script:BridgeDashboardRenderVersion = '2.0.0'
        $upgraded = Install-BridgeReplyCard -SourcePath $newSource
        Save-CopilotSessionDashboard -Sessions @()
        $advanced = (Read-BridgePublicationState).Policy
        Test-That 'participating card and renderer upgrades advance separate persisted fences' {
            $upgraded.Ok -and $advanced.card.version -eq '3.0.0' -and $advanced.render.version -eq '2.0.0' -and
                $advanced.protocol -eq 1 -and $advanced.generation -eq 1
        }
        $script:BridgeDashboardRenderVersion = $originalRenderVersion
        $script:TestPublication.Commands.Clear()
        Test-That 'an older participating renderer refuses the real save path' {
            try { Save-CopilotSessionDashboard -Sessions @() | Out-Null; $false }
            catch { $_.Exception.Message -match 'older.*render' -and @(Get-TestPublicationWrites).Count -eq 0 }
        }
        Test-That 'Force on the real create path does not bypass the renderer fence' {
            try { Initialize-BridgeDashboard -Force | Out-Null; $false }
            catch { $_.Exception.Message -match 'older.*render' -and @(Get-TestPublicationWrites).Count -eq 0 }
        }

        Set-TestPublicationIdentity -Generation 2
        $expected = Get-BridgePublicationHash (ConvertTo-BridgePublicationJson $advanced)
        Set-BridgePublicationPolicy -ExpectedGeneration 1 -ExpectedPolicyHash $expected -Target $oldTarget -Mode pin | Out-Null
        $rolledBack = Install-BridgeReplyCard -SourcePath $oldSource
        Save-CopilotSessionDashboard -Sessions @()
        $pinned = (Read-BridgePublicationState).Policy
        Test-That 'an explicit next generation rolls back exact targets without erasing high-water fences' {
            $rolledBack.Ok -and $pinned.mode -eq 'pin' -and $pinned.generation -eq 2 -and
                $pinned.card.version -eq '2.0.0' -and $pinned.render.version -eq $originalRenderVersion -and
                $pinned.highCard.version -eq '3.0.0' -and $pinned.highRender.version -eq '2.0.0' -and
                (Get-BridgeDashboardPublication).Verified
        }
        $script:BridgeDashboardRenderVersion = '2.0.0'
        $script:TestPublication.Commands.Clear()
        $automaticUndo = Install-BridgeReplyCard -SourcePath $newSource
        Test-That 'newer automatic card code cannot undo the actual operator rollback' {
            $automaticUndo.Action -eq 'blocked' -and $automaticUndo.Detail -match 'pin|rollback' -and
                @(Get-TestPublicationWrites).Count -eq 0
        }
        Test-That 'newer automatic render code cannot undo the actual operator rollback' {
            try { Save-CopilotSessionDashboard -Sessions @() | Out-Null; $false }
            catch { $_.Exception.Message -match 'pin|rollback' -and @(Get-TestPublicationWrites).Count -eq 0 }
        }
        Set-TestPublicationIdentity -Generation 3
        $newTarget = Get-BridgePublicationTarget -CardSourcePath $newSource
        $expected = Get-BridgePublicationHash (ConvertTo-BridgePublicationJson $pinned)
        Test-That 'a stale expected policy digest cannot change a generation' {
            try { Set-BridgePublicationPolicy -ExpectedGeneration 2 -ExpectedPolicyHash ('0' * 64) -Target $newTarget | Out-Null; $false }
            catch { $_.Exception.Message -match 'no longer matches' -and @(Get-TestPublicationWrites).Count -eq 0 }
        }
        Set-BridgePublicationPolicy -ExpectedGeneration 2 -ExpectedPolicyHash $expected -Target $newTarget | Out-Null
        [void](Install-BridgeReplyCard -SourcePath $newSource)
        Save-CopilotSessionDashboard -Sessions @()
        Test-That 'only another explicit generation leaves the rollback pin' {
            $latest = (Read-BridgePublicationState).Policy
            $latest.generation -eq 3 -and $latest.mode -eq 'advance' -and (Get-BridgeDashboardPublication).Verified
        }

        $validView = Get-TestPublicationStore
        $changedReceipt = Get-TestPublicationStore
        $changedReceipt.configs['agent-decisions'].agent_bridge_publication.inputHash = '0' * 64
        Set-TestPublicationStore $changedReceipt
        Test-That 'changing only the claimed input signature invalidates the observed publication' {
            -not (Get-BridgeDashboardPublication).Verified
        }
        Set-TestPublicationStore $validView
        $typedReceipt = Get-TestPublicationStore
        $typedReceipt.configs['agent-decisions'].agent_bridge_publication.contentHash = $true
        Set-TestPublicationStore $typedReceipt
        Test-That 'a Boolean cannot coerce itself into a matching content hash' {
            try { -not (Get-BridgeDashboardPublication).Verified }
            catch { $_.Exception.Message -match 'receipt|hash|malformed' }
        }
        Set-TestPublicationStore $validView

        Set-TestPublicationIdentity -Participant 'observer-b' -Generation 3
        $script:TestPublication.Commands.Clear()
        Test-That 'a configured observer can verify a newer published renderer without writing' {
            (Get-BridgeDashboardPublication).Verified -and @(Get-TestPublicationWrites).Count -eq 0
        }
        Test-That 'the real save refuses a non-writer even when called outside the daemon' {
            try { Save-CopilotSessionDashboard -Sessions @() | Out-Null; $false }
            catch { $_.Exception.Message -match 'writer' -and @(Get-TestPublicationWrites).Count -eq 0 }
        }
        Test-That 'the real legacy cleanup also refuses a non-writer' {
            try { Remove-BridgeLegacyDashboard | Out-Null; $false }
            catch { $_.Exception.Message -match 'writer' -and @(Get-TestPublicationWrites).Count -eq 0 }
        }

        Initialize-TestPublicationStore
        Initialize-TestPublicationAuthority
        Save-CopilotSessionDashboard -Sessions @()
        $lostPolicy = Get-TestPublicationStore
        $lostPolicy.resources = @()
        $lostPolicy.dashboards = @()
        $lostPolicy.configs.Clear()
        Set-TestPublicationStore $lostPolicy
        $script:TestPublication.Commands.Clear()
        Test-That 'a real local receipt distinguishes total shared-state loss from first install' {
            try { Read-BridgePublicationState | Out-Null; $false }
            catch { $_.Exception.Message -match 'lost after establishment' -and @(Get-TestPublicationWrites).Count -eq 0 }
        }
        Test-That 'a bootstrap call cannot reset the lost policy or its fences' {
            try { Set-BridgePublicationPolicy -ExpectedGeneration 0 -ExpectedPolicyHash absent -Target $newTarget | Out-Null; $false }
            catch { $_.Exception.Message -match 'lost after establishment' -and @(Get-TestPublicationWrites).Count -eq 0 }
        }

        Initialize-TestPublicationStore
        $typedSource = New-TestPublicationCard '2.0.0'
        $typedPolicy = New-TestPublicationPolicy $typedSource
        $typedPolicy.protocol = $true
        Set-TestPublicationPolicy -Policy $typedPolicy
        $script:TestPublication.Commands.Clear()
        Test-That 'a Boolean fencing protocol is malformed rather than version one' {
            try { Read-BridgePublicationState | Out-Null; $false }
            catch { $_.Exception.Message -match 'protocol' -and @(Get-TestPublicationWrites).Count -eq 0 }
        }
        Initialize-TestPublicationStore
        $scopedSource = New-TestPublicationCard '2.0.0'
        $badScope = New-TestPublicationPolicy $scopedSource
        $badScope.dashboard = $true
        Set-TestPublicationPolicy -Policy $badScope
        Test-That 'a Boolean cannot stand in for the configured dashboard scope' {
            try { Read-BridgePublicationState | Out-Null; $false }
            catch { $_.Exception.Message -match 'dashboard' -and @(Get-TestPublicationWrites).Count -eq 0 }
        }
        Initialize-TestPublicationStore
        $badResourceSource = New-TestPublicationCard '2.0.0'
        Set-TestPublicationPolicy -Policy (New-TestPublicationPolicy $badResourceSource)
        $badResource = Get-TestPublicationStore
        $badResource.resources[0].type = $true
        Set-TestPublicationStore $badResource
        Test-That 'a Boolean cannot stand in for a module resource type' {
            try { Read-BridgePublicationState | Out-Null; $false }
            catch { $_.Exception.Message -match 'module' -and @(Get-TestPublicationWrites).Count -eq 0 }
        }

        $script:BridgeDashboardRenderVersion = $originalRenderVersion
        Initialize-TestPublicationStore
        Initialize-TestPublicationAuthority
        $receiptBeforeEquivalentOrigin = Get-BridgePublicationReceiptPath
        $script:DecisionBridgeConfig.HomeAssistantBaseUrl = 'HTTP://PUBLICATION.INVALID:8123/'
        Test-That 'equivalent HA URI spelling cannot abandon the established local receipt' {
            (Get-BridgePublicationReceiptPath) -ceq $receiptBeforeEquivalentOrigin
        }
        $script:DecisionBridgeConfig.HomeAssistantBaseUrl = 'http://publication.invalid:8123'
        Save-CopilotSessionDashboard -Sessions @()
        $restarted = Invoke-TestPublicationRestart
        Test-That 'a genuinely fresh process verifies the intact policy and persisted receipt' {
            $restarted.ExitCode -eq 0 -and -not $restarted.TimedOut -and $restarted.Observation.verified -and
                $restarted.Observation.receipt -and $restarted.Observation.processId -ne $PID -and $restarted.Observation.writes -eq 0
        }
        Test-That 'a fresh publisher keeps the same installation inside its verified sandbox' {
            $restarted.Observation.fixtureRoot -ceq $env:AGENT_HA_BRIDGE_TEST_ROOT -and
                $restarted.Observation.fixtureId -ceq $env:AGENT_HA_BRIDGE_TEST_ID -and
                $restarted.Observation.configPath -ceq $script:BridgeInstallContext.ConfigPath -and
                (Test-BridgeInstallDescendant $restarted.Observation.configPath $restarted.Observation.fixtureRoot)
        }
        $deletedAfterRestart = Get-TestPublicationStore
        $deletedAfterRestart.dashboards = @()
        $deletedAfterRestart.configs.Clear()
        Set-TestPublicationStore $deletedAfterRestart
        $repairedAfterRestart = Invoke-TestPublicationRestart -Repair
        Test-That 'a fresh designated-writer process repairs a deleted dashboard without resetting generation' {
            $repairedAfterRestart.ExitCode -eq 0 -and $repairedAfterRestart.Observation.verified -and
                $repairedAfterRestart.Observation.generation -eq 1 -and $repairedAfterRestart.Observation.writes -gt 0
        }
        $lostAfterRestart = Get-TestPublicationStore
        $lostAfterRestart.resources = @()
        $lostAfterRestart.dashboards = @()
        $lostAfterRestart.configs.Clear()
        Set-TestPublicationStore $lostAfterRestart
        $lostInFreshProcess = Invoke-TestPublicationRestart -Repair
        Test-That 'policy loss stays a refusal across an actual process restart' {
            $lostInFreshProcess.ExitCode -eq 2 -and $lostInFreshProcess.Observation.error -match 'lost after establishment'
        }

        Initialize-TestPublicationStore
        Initialize-TestPublicationAuthority
        $receiptPath = Get-BridgePublicationReceiptPath
        [IO.File]::WriteAllText($receiptPath, '{"protocol":', [Text.UTF8Encoding]::new($false))
        $script:TestPublication.Commands.Clear()
        Test-That 'a genuinely corrupt receipt file is not a missing receipt' {
            try { Read-BridgePublicationState | Out-Null; $false }
            catch { $_.Exception.Message -match 'metadata is unreadable' -and @(Get-TestPublicationWrites).Count -eq 0 }
        }

        Initialize-TestPublicationStore
        $blockedSource = New-TestPublicationCard '2.0.0'
        Set-TestPublicationPolicy -Policy (New-TestPublicationPolicy $blockedSource)
        $runtimeRoot = Get-BridgeRuntimeRoot
        [IO.Directory]::Delete($runtimeRoot)
        [IO.File]::WriteAllText($runtimeRoot, 'Synthetic non-directory')
        $script:TestPublication.Commands.Clear()
        Test-That 'a real receipt write failure propagates before any shared publication' {
            try { Read-BridgePublicationState | Out-Null; $false }
            catch {
                $_.ScriptStackTrace -match 'Save-BridgePublicationReceipt' -and
                    $_.Exception.Message -match 'directory|metadata' -and @(Get-TestPublicationWrites).Count -eq 0
            }
        }

        Write-Host '--- dashboard publication honors the actual exact card pin ---'
        Initialize-TestPublicationStore
        $script:BridgeDashboardRenderVersion = $originalRenderVersion
        $advanceSource = New-TestPublicationCard '1.21.0'
        $pinSource = New-TestPublicationCard '1.20.0'
        $wrongContentSource = New-TestPublicationCard '1.20.0' 'export const differentContent = true;'
        Initialize-TestPublicationAuthority -CardSource $advanceSource
        [void](Install-BridgeReplyCard -SourcePath $advanceSource)
        Save-CopilotSessionDashboard -Sessions @()
        $advancePolicy = (Read-BridgePublicationState).Policy
        Set-TestPublicationIdentity -Generation 2
        Set-BridgePublicationPolicy -ExpectedGeneration 1 `
            -ExpectedPolicyHash (Get-BridgePublicationHash (ConvertTo-BridgePublicationJson $advancePolicy)) `
            -Target (Get-BridgePublicationTarget -CardSourcePath $pinSource) -Mode pin | Out-Null
        $script:TestPublication.Commands.Clear()
        $unappliedPinFailure = ''
        try { Save-CopilotSessionDashboard -Sessions @() }
        catch { $unappliedPinFailure = $_.Exception.Message }
        $unappliedPin = Get-BridgeDashboardPublication
        Test-That 'a not-yet-applied card rollback cannot be published as current' {
            $unappliedPinFailure -match 'pin.*repair|repair.*pin' -and
                -not $unappliedPin.Verified -and @(Get-TestPublicationWrites).Count -eq 0
        }
        Test-That 'an unapplied exact card pin keeps an actionable currentness reason' {
            $unappliedPin.Reason -match 'pin.*repair|repair.*pin'
        }
        $appliedCardPin = Install-BridgeReplyCard -SourcePath $pinSource
        Save-CopilotSessionDashboard -Sessions @()
        Test-That 'an actually applied exact card and renderer pin remains verified' {
            $appliedCardPin.Ok -and (Get-BridgeDashboardPublication).Verified
        }

        Invoke-TestPreFencePublication -CardSource $advanceSource -Sessions @()
        Test-That 'a genuine pre-fence overwrite is still possible and initially detected' {
            -not (Get-BridgeDashboardPublication).Verified -and
                (Get-BridgeRegisteredCardArtifact -Url (Read-BridgePublicationState).CardUrl).version -ceq '1.21.0'
        }
        $script:TestPublication.Commands.Clear()
        $legacyPinFailure = ''
        try { Save-CopilotSessionDashboard -Sessions @() }
        catch { $legacyPinFailure = $_.Exception.Message }
        Test-That 'the new publisher cannot bless a pre-fence overwrite across the card pin' {
            $legacyPinFailure -match 'pin.*repair|repair.*pin' -and
                -not (Get-BridgeDashboardPublication).Verified -and @(Get-TestPublicationWrites).Count -eq 0
        }
        [void](Install-BridgeReplyCard -SourcePath $pinSource)
        Save-CopilotSessionDashboard -Sessions @()

        $wrongContentUrl = Get-BridgeInlineReplyCardUrl -SourcePath $wrongContentSource -Version '1.20.0'
        Set-TestPublicationCardUrl -Url $wrongContentUrl
        $script:TestPublication.Commands.Clear()
        $wrongContentFailure = ''
        try { Save-CopilotSessionDashboard -Sessions @() }
        catch { $wrongContentFailure = $_.Exception.Message }
        Test-That 'the right pinned version with wrong actual content is also refused by the publisher' {
            $wrongContentFailure -match 'pin.*repair|repair.*pin' -and
                -not (Get-BridgeDashboardPublication).Verified -and @(Get-TestPublicationWrites).Count -eq 0
        }
        Set-TestPublicationReceiptForCard -CardUrl $wrongContentUrl
        $consistentWrongPin = Get-BridgeDashboardPublication
        Test-That 'a self-consistent persisted receipt cannot make wrong pinned card content current' {
            -not $consistentWrongPin.Verified -and $consistentWrongPin.Reason -match 'pin.*repair|repair.*pin'
        }
        Set-TestPublicationIdentity -Participant 'observer-b' -Generation 2
        $script:TestPublication.Commands.Clear()
        Test-That 'a non-writer observes the actual card-pin mismatch without claiming currentness' {
            -not (Get-BridgeDashboardPublication).Verified -and @(Get-TestPublicationWrites).Count -eq 0
        }
        Set-TestPublicationIdentity -Generation 2
        [void](Install-BridgeReplyCard -SourcePath $pinSource)
        Save-CopilotSessionDashboard -Sessions @()
        Set-TestPublicationIdentity -Participant 'observer-b' -Generation 2
        Test-That 'a non-writer still verifies a genuinely restored exact pin' { (Get-BridgeDashboardPublication).Verified }

        Set-TestPublicationIdentity -Generation 2
        Set-TestPublicationCardUrl -Url ''
        $script:TestPublication.Commands.Clear()
        $missingPinFailure = ''
        try { Save-CopilotSessionDashboard -Sessions @() }
        catch { $missingPinFailure = $_.Exception.Message }
        Test-That 'a missing required pinned artifact is repair-required, not a completed rollback' {
            $missingPinFailure -match 'pin.*repair|repair.*pin' -and
                -not (Get-BridgeDashboardPublication).Verified -and @(Get-TestPublicationWrites).Count -eq 0
        }
        Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.20.0'
        $opaquePinFailure = ''
        try { Save-CopilotSessionDashboard -Sessions @() }
        catch { $opaquePinFailure = $_.Exception.Message }
        Test-That 'a version-only file URL is not proof of exact pinned content' {
            $opaquePinFailure -match 'pin.*repair|repair.*pin' -and -not (Get-BridgeDashboardPublication).Verified
        }

        Initialize-TestPublicationStore
        Initialize-TestPublicationAuthority -CardSource $advanceSource
        Save-CopilotSessionDashboard -Sessions @([pscustomobject]@{
            Node = 'agent_bridge_fallback'; Name = 'Fallback remains supported'; Machine = 'SYNTHETIC'; Kind = 'copilot'
        })
        Test-That 'ordinary advance mode still supports a verified missing-card plain-reply fallback' {
            (Get-BridgeDashboardPublication).Verified -and
                ((Get-TestPublicationStore).configs['agent-decisions'] | ConvertTo-Json -Depth 100) -match 'text.agent_bridge_fallback_reply'
        }
    }
    finally { $script:BridgeDashboardRenderVersion = $originalRenderVersion }
}

Write-Host ''
Write-Host '--- who is driving a session ---'
# An agent driving a session sets the reply text and presses Submit, exactly as the
# dashboard does for a person, so the two arrive as identical service calls. The Home
# Assistant account behind the press is the only thing that differs - and only if the
# agent has an account of its own, which is why this is configured, never guessed.
function New-PressState {
    param([AllowEmptyString()][AllowNull()][string]$UserId, [switch]$NoContext)
    if ($NoContext) { return [pscustomobject]@{ entity_id = 'button.x'; state = 'ts' } }
    [pscustomobject]@{
        entity_id = 'button.x'; state = 'ts'
        context = [pscustomobject]@{ id = 'abc'; parent_id = $null; user_id = $UserId }
    }
}
$script:AgentIds = @()
function Get-BridgeSetting {
    param($Path, $Default)
    if ($Path -eq 'homeAssistant.agentUserIds') { return $script:AgentIds }
    $Default
}

Test-That 'the user is read off the press' {
    (Get-BridgeStateUserId -State (New-PressState -UserId 'user-1')) -eq 'user-1'
}
Test-That 'a state with no context at all is handled, not thrown on' {
    (Get-BridgeStateUserId -State (New-PressState -NoContext)) -eq ''
}
Test-That 'and so is no state' { (Get-BridgeStateUserId -State $null) -eq '' }

$script:AgentIds = @()
Test-That 'with no agent configured, nothing is an agent' { -not (Test-BridgeAgentUserId -UserId 'user-1') }
Test-That 'so a session reads as yours' {
    (Get-BridgeDriverFromState -State (New-PressState -UserId 'user-1')) -eq 'human'
}

$script:AgentIds = @('agent-user')
Test-That 'the configured agent is recognised' { Test-BridgeAgentUserId -UserId 'agent-user' }
Test-That 'anyone else is not' { -not (Test-BridgeAgentUserId -UserId 'user-1') }
Test-That 'a press from the agent marks the session agent-driven' {
    (Get-BridgeDriverFromState -State (New-PressState -UserId 'agent-user')) -eq 'agent'
}
Test-That 'a press from you does not' {
    (Get-BridgeDriverFromState -State (New-PressState -UserId 'user-1')) -eq 'human'
}
Test-That 'a press carrying no user - an automation, say - is not an agent' {
    (Get-BridgeDriverFromState -State (New-PressState -UserId '')) -eq 'human'
}
$script:AgentIds = @('  agent-user  ')
Test-That 'whitespace around a configured id does not stop it matching' {
    Test-BridgeAgentUserId -UserId 'agent-user'
}
$script:AgentIds = @('', '   ')
Test-That 'and a blank entry never matches a blank user' { -not (Test-BridgeAgentUserId -UserId '') }

Remove-Item -LiteralPath $script:DecisionBridgeConfig.LogFile -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
