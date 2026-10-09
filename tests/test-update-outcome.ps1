#Requires -Version 7.0
<#
.SYNOPSIS
    Update outcomes and real MQTT payloads against the supported HA contract.
.DESCRIPTION
    Uses actual lookup, daemon consumers, publisher JSON and synthetic config/marker
    files. Only REST/WebSocket and a read/replace filesystem race are simulated.
    The consumer subset is not a live HA test or required local-health verification.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'runner-support.ps1')
Assert-BridgeTestEnvironment -Required

$configPath = $env:AGENT_HA_BRIDGE_CONFIG
Assert-BridgeTestPath -Path $configPath
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
$config['updates']['installedVersion'] = '1.1.0'
$config['updates']['checkForUpdates'] = $true
$config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding UTF8

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
$outcomeFile = $script:DaemonConfig.UpdateOutcomeFile
Assert-BridgeTestPath -Path @($outcomeFile, $script:BridgeUpdateConfig.CacheFile)
$headers = @{ Authorization = 'Bearer synthetic-test-token' }

function Assert-UpdateOutcome {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { throw "FAIL: $Name" }
    Write-Host "  PASS  $Name"
}

$script:MqttMsgs = @()
$script:Notified = @()
$script:Lookup = 'current'
# What the install button reports. Unpressed unless a case says otherwise.
$script:ButtonState = 'unavailable'
function Invoke-RestMethod {
    param($Uri, $Method, $Headers, $Body, $ContentType, $TimeoutSec, $WebSession)
    if ($Uri -like 'https://api.github.com/repos/*/releases/latest') {
        if ($script:Lookup -eq 'unavailable') { throw [IO.IOException]::new('synthetic lookup outage') }
        if ($script:Lookup -eq 'not-found') {
            $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::NotFound)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Not Found', $response)
        }
        $tag = if ($script:Lookup -eq 'available') { 'v1.2.0' } else { 'v1.1.0' }
        return [pscustomobject]@{
            tag_name = $tag; name = $tag; body = ''; published_at = ''
            html_url = "https://example.test/releases/$tag"; zipball_url = "https://example.test/archive/$tag.zip"
        }
    }
    if ($Uri -like 'http://127.0.0.1:1/api/states/button.*') { return [pscustomobject]@{ state = $script:ButtonState } }
    $data = if ($Body -is [byte[]]) { [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json } else { $Body | ConvertFrom-Json }
    if ($Uri -eq 'http://127.0.0.1:1/api/services/mqtt/publish') {
        $script:MqttMsgs += [pscustomobject]@{ Topic = $data.topic; Payload = $data.payload }
        return @()
    }
    if ($Uri -eq 'http://127.0.0.1:1/api/services/persistent_notification/create') {
        $script:Notified += $data
        return @()
    }
    throw "Unexpected REST fixture endpoint: $Uri"
}
function Invoke-CopilotHaWebSocket {
    param($Commands)
    if (@($Commands).Count -ne 1 -or $Commands[0].type -ne 'config/entity_registry/list') { throw 'Unexpected WebSocket fixture command.' }
    $replies = [Collections.Generic.List[object]]::new()
    $replies.Add([object[]]@([pscustomobject]@{ unique_id = 'unrelated-fixture'; entity_id = 'sensor.fixture' }))
    return ,$replies.ToArray()
}
function Get-StatePayload {
    ($script:MqttMsgs | Where-Object { $_.Topic -match '/update/state$' } | Select-Object -Last 1).Payload
}
function Get-UpdateAttributesPayload {
    <# The entity attributes, which is where anything outside HA's schema has to go. #>
    ($script:MqttMsgs | Where-Object { $_.Topic -match '/update/attributes$' } | Select-Object -Last 1).Payload
}
function Reset-UpdateCapture {
    $script:MqttMsgs = @()
    $script:Notified = @()
    $script:DaemonUpdatePendingAttempt = ''
    Remove-Item -LiteralPath $outcomeFile -Force -ErrorAction SilentlyContinue
}
function Write-Marker {
    param([hashtable]$Data)
    $Data | ConvertTo-Json -Compress | Set-Content -LiteralPath $outcomeFile -Encoding UTF8
}
function Set-RecordedVersion {
    param([string]$Version)
    $saved = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
    $saved['updates']['installedVersion'] = $Version
    $saved | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding UTF8
}

function Receive-UpdatePayload {
    param([hashtable]$Consumer, [string]$StatePayload = (Get-StatePayload))
    # Contract subset, not HA/Jinja execution: HA 2026.9.4 at
    # 9212531f40a0b7b23229a90d688dd79d9dfccff4:
    # mqtt/update.py uses cv.string (including some scalar coercions) and updates
    # only present keys. Identical discovery does not reset retained attributes.
    # HA compares versions with AwesomeVersion; this subset covers only the
    # three-part numeric strings emitted in these fixtures, not all HA inputs.
    $discovery = ($script:MqttMsgs | Where-Object { $_.Topic -match '/update/.+/config$' } | Select-Object -Last 1).Payload | ConvertFrom-Json
    if ($discovery.availability_topic -cne $discovery.state_topic -or
        $discovery.availability_template -cne "{{ 'online' if value_json.get('latest_version') else 'offline' }}") {
        throw 'The discovery payload does not match the supported availability contract.'
    }
    $wire = $StatePayload | ConvertFrom-Json -AsHashtable
    # MQTT_JSON_UPDATE_SCHEMA is a plain vol.Schema with no ALLOW_EXTRA, so an
    # unrecognised key raises MultipleInvalid and _handle_state_message_received
    # logs a warning and returns - the entire payload is discarded and the entity
    # keeps whatever it had, including its versions. Modelled here because the
    # fixture previously tracked only the keys it knew and so accepted a payload
    # Home Assistant would have thrown away whole, which is how three invented
    # keys reached a published entity (#129 review).
    $allowed = @('installed_version', 'latest_version', 'title', 'release_summary',
        'release_url', 'entity_picture', 'in_progress', 'update_percentage')
    $unknown = @($wire.Keys | Where-Object { $_ -cnotin $allowed })
    if ($unknown.Count -gt 0) {
        throw "Home Assistant would discard this payload whole: $($unknown -join ', ') are not in MQTT_JSON_UPDATE_SCHEMA."
    }
    # vol.Any(vol.Range(min=0, max=100), None): an empty string is a violation, and
    # a violation costs the whole payload rather than just this field.
    if ($wire.Contains('update_percentage') -and $null -ne $wire['update_percentage']) {
        $percentage = $wire['update_percentage'] -as [double]
        if ($null -eq $percentage -or $percentage -lt 0 -or $percentage -gt 100) {
            throw "Home Assistant would discard this payload whole: update_percentage '$($wire['update_percentage'])' is neither null nor 0-100."
        }
    }
    foreach ($key in @('installed_version', 'latest_version')) {
        if ($wire.Contains($key)) {
            if ($wire[$key] -isnot [string] -or $wire[$key] -notmatch '^\d+\.\d+\.\d+$') {
                throw 'This publisher fixture must emit three-part numeric version strings.'
            }
            $Consumer[$key] = $wire[$key]
        }
    }
    if ($wire.Contains('release_summary')) {
        if ($wire['release_summary'] -isnot [string]) { throw 'This publisher fixture must emit a string summary.' }
        $Consumer['release_summary'] = $wire['release_summary']
    }
    $Consumer['in_progress'] = $wire['in_progress']
    $Consumer['state'] = if (-not $wire.Contains('latest_version') -or -not $wire['latest_version']) { 'unavailable' }
        elseif ($null -eq $Consumer['installed_version'] -or $null -eq $Consumer['latest_version']) { 'unknown' }
        elseif ([version]$Consumer['latest_version'] -gt [version]$Consumer['installed_version']) { 'on' } else { 'off' }
}
$consumer = @{ installed_version = $null; latest_version = $null; release_summary = $null; state = 'unknown'; in_progress = $false }

Publish-CopilotMqttUpdate -InstalledVersion '1.1.0' -LatestVersion '1.2.0' -ReleaseNotes 'Fixture release notes' -InProgress -Headers $headers
Receive-UpdatePayload $consumer
Assert-UpdateOutcome 'a real available publish carries the spinner and newer version' ($consumer.state -eq 'on' -and $consumer.in_progress)
Assert-UpdateOutcome 'the real publisher preserves nonempty release notes' ($consumer.release_summary -ceq 'Fixture release notes')

# Everything Home Assistant is told has to survive its own schema, because a single
# key outside it costs the whole payload - versions included.
Reset-UpdateCapture
Publish-CopilotMqttUpdate -InstalledVersion '1.1.0' -LatestVersion '1.2.0' -InProgress `
    -Stage 'downloading' -Proportion 0.42 -StageDetail 'fetching the release' -Headers $headers
$accepted = $true
$rejection = ''
try { Receive-UpdatePayload $consumer }
catch { $accepted = $false; $rejection = $_.Exception.Message }
Assert-UpdateOutcome 'a payload carrying progress is one Home Assistant would accept' $accepted "[$rejection]"
Assert-UpdateOutcome 'and the proportion travels as the schema own update_percentage' (
    (Get-StatePayload | ConvertFrom-Json -AsHashtable)['update_percentage'] -eq 42)
Assert-UpdateOutcome 'with no proportion published as null rather than an empty string' (
    $(
        Publish-CopilotMqttUpdate -InstalledVersion '1.1.0' -LatestVersion '1.2.0' -Headers $headers
        $idle = Get-StatePayload | ConvertFrom-Json -AsHashtable
        $idle.Contains('update_percentage') -and $null -eq $idle['update_percentage']
    ))
$attributes = Get-UpdateAttributesPayload | ConvertFrom-Json -AsHashtable
Assert-UpdateOutcome 'while the stage rides on the attributes topic, where custom keys are allowed' (
    $null -ne $attributes -and $attributes.Contains('stage') -and $attributes.Contains('stage_detail'))
Reset-UpdateCapture
Publish-CopilotMqttUpdate -InstalledVersion '1.1.0' -LatestVersion '1.2.0' -ReleaseNotes 'Fixture release notes' -InProgress -Headers $headers
Receive-UpdatePayload $consumer
# Replay only the historical omission against the same discovery and retained
# consumer. All production-path assertions below use unmodified captured JSON.
$omittedSummary = Get-StatePayload | ConvertFrom-Json -AsHashtable
$omittedSummary.Remove('release_summary')
Receive-UpdatePayload $consumer -StatePayload ($omittedSummary | ConvertTo-Json -Compress)
Assert-UpdateOutcome 'an omitted summary retains its old text despite identical discovery' ($consumer.release_summary -ceq 'Fixture release notes')
Reset-UpdateCapture
Publish-CopilotMqttUpdate -InstalledVersion '1.1.0' -LatestVersion $null -Headers $headers
Receive-UpdatePayload $consumer
Assert-UpdateOutcome 'unknown latest is omitted, not a null or synthetic version' (-not ((Get-StatePayload | ConvertFrom-Json -AsHashtable).Contains('latest_version')))
Assert-UpdateOutcome 'omission retains the old attribute but availability overrides its old on-state' ($consumer.latest_version -eq '1.2.0' -and $consumer.state -eq 'unavailable' -and -not $consumer.in_progress)

Write-Host '--- no marker is a no-op ---'
Reset-UpdateCapture
[void](Invoke-DaemonUpdateOutcome -Headers $headers)
Assert-UpdateOutcome 'nothing is published or notified' ($script:MqttMsgs.Count -eq 0 -and $script:Notified.Count -eq 0)

Write-Host '--- legacy Boolean success does not replace the actual version record ---'
Reset-UpdateCapture
Set-RecordedVersion '1.3.0'
Write-Marker @{ success = $true; version = '1.2.0'; releaseUrl = 'https://example.test/rel'; at = [DateTimeOffset]::Now.ToString('o') }
[void](Invoke-DaemonUpdateOutcome -Headers $headers)
Receive-UpdatePayload $consumer
Assert-UpdateOutcome 'the attempted release is not substituted for the recorded version' ($consumer.installed_version -eq '1.3.0' -and $consumer.latest_version -eq '1.2.0' -and $consumer.state -eq 'off')
Assert-UpdateOutcome 'completion notification names both observations without certifying health' ($script:Notified.Count -eq 1 -and $script:Notified[0].message -match '1\.2\.0.*1\.3\.0.*nothing has checked the install since')
# The updater requests a restart and does not wait for one, so the notification
# must not assert a running daemon. Review, #152.
Assert-UpdateOutcome 'completion notification does not claim a restart it only requested' (
    $script:Notified[0].message -match 'asked to restart' -and $script:Notified[0].message -notmatch 'was restarted')
Assert-UpdateOutcome 'the notification is scoped to this machine' ($script:Notified[0].notification_id -eq "agent_bridge_update_$(Get-BridgeMachineSlug)")
# The notification is a one-shot; the entity is what the dashboard reads on every
# pass. Without the verdict there, an update that finished looked exactly like one
# that was never pressed - which is the silence #129 is about.
$terminal = Get-UpdateAttributesPayload | ConvertFrom-Json -AsHashtable
Assert-UpdateOutcome 'the entity carries how the attempt ended, not only that it stopped' (
    $terminal['stage'] -ceq 'completed' -and $terminal['stage_detail'] -match '1\.2\.0')
Assert-UpdateOutcome 'the claimed marker is consumed' (-not (Test-Path -LiteralPath $outcomeFile))

Write-Host '--- a failure marker clears the spinner and reports the error ---'
Reset-UpdateCapture
Set-RecordedVersion '1.1.0'
Write-Marker @{ schemaVersion = 1; attemptId = ('a' * 32); success = $false; exitCode = 1; version = '1.2.0'; error = 'disk full'; at = [DateTimeOffset]::Now.ToString('o') }
[void](Invoke-DaemonUpdateOutcome -Headers $headers)
Receive-UpdatePayload $consumer
Assert-UpdateOutcome 'retry availability is established by both actual JSON versions and the consumer' ($consumer.state -eq 'on' -and $consumer.installed_version -eq '1.1.0' -and $consumer.latest_version -eq '1.2.0' -and -not $consumer.in_progress)
Assert-UpdateOutcome 'failure reports the error without claiming rollback' ($script:Notified.Count -eq 1 -and $script:Notified[0].message -match 'disk full.*no rollback is claimed')
$terminal = Get-UpdateAttributesPayload | ConvertFrom-Json -AsHashtable
Assert-UpdateOutcome 'and the entity says it failed, and why' (
    $terminal['stage'] -ceq 'failed' -and $terminal['stage_detail'] -ceq 'disk full')

Reset-UpdateCapture
Set-RecordedVersion '1.2.0'
Write-Marker @{ success = $false; version = '1.2.0'; error = 'failed after recording version'; at = [DateTimeOffset]::Now.ToString('o') }
[void](Invoke-DaemonUpdateOutcome -Headers $headers)
Receive-UpdatePayload $consumer
Assert-UpdateOutcome 'failure after mutation does not claim that the old version survived' ($consumer.installed_version -eq '1.2.0' -and $script:Notified[0].title -match '^Bridge update failed')

Reset-UpdateCapture
Write-Marker @{ success = $false; error = 'old marker without target'; at = [DateTimeOffset]::Now.ToString('o') }
[void](Invoke-DaemonUpdateOutcome -Headers $headers)
Receive-UpdatePayload $consumer
Assert-UpdateOutcome 'a legacy failure without a target is not advertised as current or retryable' ($consumer.state -eq 'unavailable' -and $script:Notified[0].title -match '^Bridge update failed')

Write-Host '--- a stale marker is ignored ---'
Reset-UpdateCapture
Write-Marker @{ success = $true; version = '1.2.0'; at = ([DateTimeOffset]::Now.AddHours(-24)).ToString('o') }
[void](Invoke-DaemonUpdateOutcome -Headers $headers)
Assert-UpdateOutcome 'no completion is announced for an old marker' ($script:Notified.Count -eq 0 -and -not (Test-Path -LiteralPath $outcomeFile))

foreach ($bad in @('malformed', 'string-true', 'string-false', 'unsupported', 'inconsistent', 'future', 'unversioned-attempt', 'bad-legacy-target')) {
    Reset-UpdateCapture
    $marker = @{ schemaVersion = 1; attemptId = ('a' * 32); success = $true; exitCode = 0; version = '1.2.0'; at = [DateTimeOffset]::Now.ToString('o') }
    switch ($bad) {
        'string-true' { $marker.success = 'true' }
        'string-false' { $marker.success = 'false' }
        'unsupported' { $marker.schemaVersion = 9 }
        'inconsistent' { $marker.exitCode = 1 }
        'future' { $marker.at = [DateTimeOffset]::Now.AddDays(1).ToString('o') }
        'unversioned-attempt' { $marker.Remove('schemaVersion') }
        'bad-legacy-target' {
            $marker = @{ success = $false; version = 'not-a-version'; error = 'synthetic failure'; at = [DateTimeOffset]::Now.ToString('o') }
        }
    }
    Write-Marker $marker
    if ($bad -eq 'malformed') { Set-Content -LiteralPath $outcomeFile -Value '{ invalid json' }
    [void](Invoke-DaemonUpdateOutcome -Headers $headers)
    Receive-UpdatePayload $consumer
    Assert-UpdateOutcome "$bad cannot announce completion or a known latest version" ($script:Notified.Count -eq 0 -and $consumer.state -eq 'unavailable' -and -not (Test-Path -LiteralPath $outcomeFile))
}

Write-Host '--- a replacement notice survives the older notice read ---'
Reset-UpdateCapture
$script:ReplaceOnRead = $true
function Get-Content {
    [CmdletBinding()]
    param([string]$LiteralPath, [switch]$Raw, [string]$Encoding)
    $text = Microsoft.PowerShell.Management\Get-Content @PSBoundParameters
    if ($script:ReplaceOnRead -and ($LiteralPath -eq $outcomeFile -or $LiteralPath -like "$outcomeFile.*.reading")) {
        $script:ReplaceOnRead = $false
        Write-Marker @{ success = $true; version = '1.3.0'; at = [DateTimeOffset]::Now.ToString('o') }
    }
    $text
}
Write-Marker @{ success = $true; version = '1.2.0'; at = [DateTimeOffset]::Now.ToString('o') }
try { [void](Invoke-DaemonUpdateOutcome -Headers $headers) }
finally { Remove-Item Function:\Get-Content }
Assert-UpdateOutcome 'consuming an old notice does not delete its replacement' ((Read-BridgeUpdateOutcome -Path $outcomeFile).Version -eq '1.3.0')

Write-Host '--- lookup truth changes republish even when Available stays false ---'
Reset-UpdateCapture
Set-RecordedVersion '1.1.0'
$script:DaemonUpdateSignature = ''
$script:DaemonUpdatePublished = $false
$script:DaemonUpdateAvailable = $false
$expected = @('off', 'unavailable', 'off', 'unavailable', 'off', 'on')
$lookups = @('current', 'unavailable', 'current', 'not-found', 'current', 'available')
$index = 0
foreach ($lookup in $lookups) {
    $script:Lookup = $lookup
    $before = @($script:MqttMsgs | Where-Object { $_.Topic -match '/update/state$' }).Count
    Remove-Item -LiteralPath $script:BridgeUpdateConfig.CacheFile -Force -ErrorAction SilentlyContinue
    Sync-DaemonUpdateStatus -Headers $headers
    Receive-UpdatePayload $consumer
    $after = @($script:MqttMsgs | Where-Object { $_.Topic -match '/update/state$' }).Count
    Assert-UpdateOutcome "$lookup is republished with the supported consumer state" ($after -eq $before + 1 -and $consumer.state -eq $expected[$index])
    $wire = Get-StatePayload | ConvertFrom-Json -AsHashtable
    if ($lookup -in @('unavailable', 'not-found')) {
        Assert-UpdateOutcome "$lookup retains its distinct explanation in the real payload" (
            $wire.release_summary -match $(if ($lookup -eq 'not-found') { '404.*existence and access are not confirmed' } else { 'could not be established' }) -and
            $consumer.release_summary -ceq $wire.release_summary)
    }
    elseif ($lookup -eq 'current' -and $index -gt 0) {
        Assert-UpdateOutcome "known no-notes recovery after $($lookups[$index - 1]) explicitly clears the prior explanation" (
            $wire.Contains('release_summary') -and $wire.release_summary -is [string] -and
            $wire.release_summary -ceq '' -and $consumer.release_summary -ceq '')
    }
    $index++
}

# A release check that fails used to `return` before the install button was read, so
# a press from Home Assistant was silently discarded - and pressing again only spent
# more of the rate-limit allowance that had refused the check in the first place. The
# entity was never published either, so the machine read as dead on the dashboard
# while its daemon was alive and heartbeating (#92, #109).
Write-Host '--- a failed release check neither hides the machine nor eats the press ---'
Reset-UpdateCapture
$script:Lookup = 'unavailable'
$script:ButtonState = [DateTimeOffset]::Now.AddMinutes(1).ToString('o')
$script:DaemonUpdateLastPress = ''
$script:DaemonUpdateSignature = ''
$script:DaemonUpdatePublished = $false
$script:SelfUpdateCalls = 0
$realSelfUpdate = (Get-Item Function:\Invoke-BridgeSelfUpdate).ScriptBlock
function Invoke-BridgeSelfUpdate {
    param([switch]$Detached, [switch]$Force, [switch]$ScriptOnly)
    $script:SelfUpdateCalls++
    [pscustomobject]@{
        Started = $false; Success = $false; State = 'Unavailable'; AttemptId = ''
        AttemptedVersion = $null; InstalledVersion = '1.1.0'; Detail = 'synthetic refusal'
    }
}
Remove-Item -LiteralPath $script:BridgeUpdateConfig.CacheFile -Force -ErrorAction SilentlyContinue
try { Sync-DaemonUpdateStatus -Headers $headers }
finally { Set-Item Function:\Invoke-BridgeSelfUpdate -Value $realSelfUpdate }
Assert-UpdateOutcome 'the press is still acted on when the release check failed' ($script:SelfUpdateCalls -eq 1)
$failedWire = Get-StatePayload | ConvertFrom-Json -AsHashtable
Assert-UpdateOutcome 'and the entity still carries the installed version rather than going blank' (
    $failedWire.Contains('installed_version') -and [string]$failedWire.installed_version -match '^\d+\.\d+')
# Any of the publishes from this pass: the point is that the machine explained itself
# instead of going quiet, not which message carried it.
$explained = @($script:MqttMsgs | Where-Object { $_.Topic -match '/update/state$' } |
    Where-Object { [string]$_.Payload -match 'could not be established' })
Assert-UpdateOutcome 'and says why the latest is unknown, instead of looking like a dead machine' (
    $explained.Count -ge 1)
$script:ButtonState = 'unavailable'
$script:Lookup = 'current'

# A press that found the release already installed is not a press that broke.
# Reporting the two the same way is what sent people to a log to find out which had
# happened - and then to a shell, which is where tonight's damage came from (#129).
Write-Host '--- a press with nothing to install says so, and is not a failure ---'
Reset-UpdateCapture
$script:DaemonUpdateVerdict = $null
$script:ButtonState = [DateTimeOffset]::Now.AddMinutes(2).ToString('o')
$script:DaemonUpdateLastPress = ''
$script:DaemonUpdateSignature = ''
$script:DaemonUpdatePublished = $false
$realSelfUpdate = (Get-Item Function:\Invoke-BridgeSelfUpdate).ScriptBlock
function Invoke-BridgeSelfUpdate {
    param([switch]$Detached, [switch]$Force, [switch]$ScriptOnly)
    [pscustomobject]@{
        Started = $false; Success = $true; State = 'Current'; AttemptId = ''
        AttemptedVersion = $null; InstalledVersion = '1.1.0'
        Detail = 'no newer release found; nothing installed'
    }
}
try { Sync-DaemonUpdateStatus -Headers $headers }
finally { Set-Item Function:\Invoke-BridgeSelfUpdate -Value $realSelfUpdate }
$currentWire = Get-UpdateAttributesPayload | ConvertFrom-Json -AsHashtable
Assert-UpdateOutcome 'it is reported as already current, not as a failed update' (
    $currentWire['stage'] -ceq 'current' -and $currentWire['stage_detail'] -match 'no newer release')

# The verdict has to outlive the pass that made it, because nothing else records it:
# the updater never started, so there is no progress file to read it back from.
Write-Host '--- and the verdict stays readable for long enough to be read ---'
Assert-UpdateOutcome 'a fresh verdict is what the next pass would publish' (
    (Get-DaemonUpdateProgress).Stage -ceq 'current')
Assert-UpdateOutcome 'and it is not kept so long that it describes yesterday' (
    (Get-DaemonUpdateProgress -Now ([DateTimeOffset]::Now.AddHours(1))).Stage -eq '')
$script:DaemonUpdateVerdict = $null
Assert-UpdateOutcome 'with no verdict and no progress file, nothing is claimed' (
    (Get-DaemonUpdateProgress).Stage -eq '' -and $null -eq (Get-DaemonUpdateProgress).Proportion)

# The reader accepts any attempt once the daemon has restarted, because a daemon that
# came up mid-update has no attempt id to match. Age is then the only thing keeping a
# file from a finished update out of today's dashboard.
$progressFile = $script:BridgeUpdateConfig.ProgressFile
@{ schemaVersion = 1; attemptId = ('b' * 32); stage = 'downloading'; proportion = 0.5
   at = [DateTimeOffset]::Now.ToString('o') } | ConvertTo-Json -Compress |
    Set-Content -LiteralPath $progressFile -Encoding UTF8
Assert-UpdateOutcome 'a current progress record is published as the stage it names' (
    (Get-DaemonUpdateProgress).Stage -ceq 'downloading' -and (Get-DaemonUpdateProgress).Proportion -eq 0.5)
Assert-UpdateOutcome 'and the progress file wins over any verdict, being the newer truth' (
    $(
        Set-DaemonUpdateVerdict -Stage 'failed' -Detail 'stale'
        (Get-DaemonUpdateProgress).Stage -ceq 'downloading'
    ))
@{ schemaVersion = 1; attemptId = ('b' * 32); stage = 'completed'
   at = [DateTimeOffset]::Now.AddHours(-26).ToString('o') } | ConvertTo-Json -Compress |
    Set-Content -LiteralPath $progressFile -Encoding UTF8
$script:DaemonUpdateVerdict = $null
Assert-UpdateOutcome 'an old record is not replayed as an update that just finished' (
    (Get-DaemonUpdateProgress).Stage -eq '')
Remove-Item -LiteralPath $progressFile -Force -ErrorAction SilentlyContinue
$script:ButtonState = 'unavailable'
$script:DaemonUpdateVerdict = $null
$script:DaemonUpdateSignature = ''

Write-Host '--- marked guard failures propagate through daemon outcome and status consumers ---'
Reset-UpdateCapture
Write-Marker @{ success = $true; version = '1.2.0'; at = [DateTimeOffset]::Now.ToString('o') }
$restStub = (Get-Item Function:\Invoke-RestMethod).ScriptBlock
Remove-Item Function:\Invoke-RestMethod
$blocked = $false
try { Sync-DaemonUpdateStatus -Headers $headers }
catch { $blocked = [bool]$_.Exception.Data['BridgeTestNetworkBlocked'] }
finally { Set-Item Function:\Invoke-RestMethod -Value $restStub }
Assert-UpdateOutcome 'real network guard refusal is not converted to a cosmetic update failure' $blocked
$script:DaemonConfig.UpdateOutcomeFile = Join-Path (Split-Path $env:AGENT_HA_BRIDGE_TEST_ROOT -Parent) 'forbidden-outcome.json'
$blocked = $false
try { Sync-DaemonUpdateStatus -Headers $headers }
catch { $blocked = [bool]$_.Exception.Data['BridgeTestWriteBlocked'] }
finally { $script:DaemonConfig.UpdateOutcomeFile = $outcomeFile }
Assert-UpdateOutcome 'real write guard refusal is not swallowed by the daemon consumer' $blocked

Reset-UpdateCapture
Write-Host 'All update outcome checks passed'
exit 0
