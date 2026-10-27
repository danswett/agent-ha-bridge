#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-mqtt.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-ha-websocket.ps1')
$previousFrontendNoRun = $env:BRIDGE_FRONTEND_NORUN
$env:BRIDGE_FRONTEND_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\bridge-frontend-cards.ps1')
if ($null -eq $previousFrontendNoRun) { Remove-Item Env:\BRIDGE_FRONTEND_NORUN }
else { $env:BRIDGE_FRONTEND_NORUN = $previousFrontendNoRun }
. (Join-Path $PSScriptRoot 'test-dashboard.ps1') -PublicationFixturesOnly
function Invoke-CopilotHaWebSocket {
    param([hashtable[]]$Commands)
    Invoke-TestPublicationCommands -Commands $Commands
}

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $__ok = $false
    try { $__ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($__ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name - $Detail"; $script:Failures++ }
}

Write-Host '--- observing generations is not changing policy ---'
Initialize-TestPublicationStore
$cardSource = New-TestPublicationCard '1.1.0'
$target = Get-BridgePublicationTarget -CardSourcePath $cardSource
$cardUrl = Get-BridgeInlineReplyCardUrl -SourcePath $cardSource -Version '1.1.0'
Initialize-TestPublicationAuthority -CardSource $cardSource -CardUrl $cardUrl
$one = (Read-BridgePublicationState).Policy
$receiptPath = Get-BridgePublicationReceiptPath
$generationOneReceipt = [IO.File]::ReadAllBytes($receiptPath)
Test-That 'operator bootstrap establishes generation one through the real setter' { $one.generation -eq 1 }

$script:TestPublication.Commands.Clear()
Set-TestPublicationIdentity -Generation 2
$two = Set-BridgePublicationPolicy -ExpectedGeneration 1 `
    -ExpectedPolicyHash (Get-BridgePublicationHash (ConvertTo-BridgePublicationJson $one)) -Target $target
Set-TestPublicationIdentity -Generation 3
$three = Set-BridgePublicationPolicy -ExpectedGeneration 2 `
    -ExpectedPolicyHash (Get-BridgePublicationHash (ConvertTo-BridgePublicationJson $two)) -Target $target -Mode pin
Test-That 'two exactly-next operator mutations establish generation three' {
    $two.generation -eq 2 -and $three.generation -eq 3 -and @(Get-TestPublicationWrites).Count -eq 2
}

# Replay the receipt actually held before the two operator actions, as an observer
# that missed them would. The shared policy is the real setter's generation three.
Set-TestPublicationIdentity -Participant 'observer-b' -Generation 1
[IO.File]::WriteAllBytes($receiptPath, $generationOneReceipt)
$sharedBefore = (Get-FileHash -LiteralPath $script:TestPublication.Path -Algorithm SHA256).Hash
$script:TestPublication.Commands.Clear()
$observed = Read-BridgePublicationState
$observerReceipt = Read-BridgeInstallRecord -Path $receiptPath
Test-That 'an older observer receipt catches up across two legitimate generations' {
    (ConvertTo-BridgePublicationJson $observed.Policy) -ceq (ConvertTo-BridgePublicationJson $three) -and
        (ConvertTo-BridgePublicationJson $observerReceipt) -ceq (ConvertTo-BridgePublicationJson $three)
}
Test-That 'observer catch-up never mutates shared policy card or dashboard' {
    @(Get-TestPublicationWrites).Count -eq 0 -and
        (Get-FileHash -LiteralPath $script:TestPublication.Path -Algorithm SHA256).Hash -ceq $sharedBefore
}

Set-TestPublicationIdentity -Generation 5
$receiptBefore = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash
$script:TestPublication.Commands.Clear()
$skipError = $null
try {
    Set-BridgePublicationPolicy -ExpectedGeneration 3 `
        -ExpectedPolicyHash (Get-BridgePublicationHash (ConvertTo-BridgePublicationJson $three)) -Target $target | Out-Null
}
catch {
    if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
    $skipError = $_
}
Test-That 'a skipped operator generation is rejected before any transport' {
    $null -ne $skipError -and $skipError.Exception.Message -match 'exactly the next configured generation' -and
        $script:TestPublication.Commands.Count -eq 0
}
Test-That 'skipped operator mutation preserves shared policy and local receipt' {
    (Get-FileHash -LiteralPath $script:TestPublication.Path -Algorithm SHA256).Hash -ceq $sharedBefore -and
        (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash -ceq $receiptBefore
}

Write-Host '--- exact pins reject numeric aliases before shared mutation ---'
Test-That 'the four-part review example is numerically newer not an alias' {
    ([version]'1.1.0.0').CompareTo([version]'1.1.0') -eq 1
}
Test-That 'leading-zero spellings are numerically equal but textually different' {
    ([version]'01.1.0').CompareTo([version]'1.1.0') -eq 0 -and
        ([version]'1.01.0').CompareTo([version]'1.1.0') -eq 0 -and
        '01.1.0' -cne '1.1.0' -and '1.01.0' -cne '1.1.0'
}

Initialize-TestPublicationStore
$pinCardSource = New-TestPublicationCard '1.1.0'
$pinTarget = Get-BridgePublicationTarget -CardSourcePath $pinCardSource
$pinCardUrl = Get-BridgeInlineReplyCardUrl -SourcePath $pinCardSource -Version '1.1.0'
Initialize-TestPublicationAuthority -CardSource $pinCardSource -CardUrl $pinCardUrl
$advance = (Read-BridgePublicationState).Policy
Set-TestPublicationIdentity -Generation 2
$pin = Set-BridgePublicationPolicy -ExpectedGeneration 1 `
    -ExpectedPolicyHash (Get-BridgePublicationHash (ConvertTo-BridgePublicationJson $advance)) -Target $pinTarget -Mode pin
Save-CopilotSessionDashboard -Sessions @()
$pinReceiptPath = Get-BridgePublicationReceiptPath
$pinSharedBytes = [IO.File]::ReadAllBytes($script:TestPublication.Path)
$pinReceiptBytes = [IO.File]::ReadAllBytes($pinReceiptPath)
$pinSharedHash = (Get-FileHash -LiteralPath $script:TestPublication.Path -Algorithm SHA256).Hash
$pinReceiptHash = (Get-FileHash -LiteralPath $pinReceiptPath -Algorithm SHA256).Hash
Test-That 'the fixture establishes a real pinned dashboard and receipt' {
    $pin.mode -ceq 'pin' -and $pin.generation -eq 2 -and (Get-BridgeDashboardPublication).Verified
}

foreach ($component in @('render', 'card')) {
    $canonical = @{ version = $pin[$component].version; hash = $pin[$component].hash }
    $script:TestPublication.Commands.Clear()
    $canonicalState = Update-BridgePublicationFence -Component $component -Artifact $canonical
    Test-That "the exact $component pin succeeds without changing stored state" {
        (ConvertTo-BridgePublicationJson $canonicalState.Policy[$component]) -ceq (ConvertTo-BridgePublicationJson $canonical) -and
            @(Get-TestPublicationWrites).Count -eq 0 -and
            (Get-FileHash -LiteralPath $script:TestPublication.Path -Algorithm SHA256).Hash -ceq $pinSharedHash -and
            (Get-FileHash -LiteralPath $pinReceiptPath -Algorithm SHA256).Hash -ceq $pinReceiptHash
    }
    foreach ($case in @(
        @{ Label = 'four-part control'; Version = '1.1.0.0'; Hash = $canonical.hash }
        @{ Label = 'leading-major alias'; Version = '01.1.0'; Hash = $canonical.hash }
        @{ Label = 'leading-minor alias'; Version = '1.01.0'; Hash = $canonical.hash }
        @{ Label = 'different hash'; Version = $canonical.version; Hash = ('0' * 64) }
    )) {
        $script:TestPublication.Commands.Clear()
        $pinError = $null
        try {
            try {
                Update-BridgePublicationFence -Component $component `
                    -Artifact @{ version = $case.Version; hash = $case.Hash } | Out-Null
            }
            catch {
                if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
                $pinError = $_
            }
            $writes = @(Get-TestPublicationWrites).Count
            $sharedUnchanged = (Get-FileHash -LiteralPath $script:TestPublication.Path -Algorithm SHA256).Hash -ceq $pinSharedHash
            $receiptUnchanged = (Get-FileHash -LiteralPath $pinReceiptPath -Algorithm SHA256).Hash -ceq $pinReceiptHash
            $earlyRefusal = $null -ne $pinError -and $pinError.Exception.Data['BridgePublicationRefused'] -eq $true -and
                $pinError.Exception.Message -match 'pins an exact publication target'
            Test-That "the $component pin rejects $($case.Label) before any shared mutation" {
                $earlyRefusal -and $writes -eq 0 -and $sharedUnchanged -and $receiptUnchanged
            } "earlyRefusal=$earlyRefusal; writes=$writes; sharedUnchanged=$sharedUnchanged; receiptUnchanged=$receiptUnchanged"
        }
        finally {
            [IO.File]::WriteAllBytes($script:TestPublication.Path, $pinSharedBytes)
            [IO.File]::WriteAllBytes($pinReceiptPath, $pinReceiptBytes)
        }
    }
}

Write-Host '--- the render fence admits a bumped renderer, not a changed one at the same version ---'
# A generator change that leaves $script:BridgeDashboardRenderVersion alone is a new
# hash at the old version, which is the definition of a conflict here. An installation
# already fenced at the previous renderer then refuses to publish at all, and the new
# card configuration can never reach the dashboard without an operator pin nobody
# should have to take. This is the gate that catches it.
Initialize-TestPublicationStore
$renderCard = New-TestPublicationCard '1.1.0'
$renderUrl = Get-BridgeInlineReplyCardUrl -SourcePath $renderCard -Version '1.1.0'
Initialize-TestPublicationAuthority -CardSource $renderCard -CardUrl $renderUrl
$fenced = Read-BridgePublicationState
$fencedRender = $fenced.Policy.render

Test-That 'the established fence is the renderer this build actually composes' {
    (ConvertTo-BridgePublicationJson $fencedRender) -ceq (ConvertTo-BridgePublicationJson (Get-BridgeRenderArtifact))
}

# An installation fenced at the renderer before this change, as one that has been
# running the previous release is.
$olderFence = @{ version = '1.1.0'; hash = ('a' * 64) }
$fenced.Policy.render = $olderFence
$fenced.Policy.highRender = $olderFence
Test-That 'the current renderer crosses a fence established at the older version' {
    Assert-BridgePublicationWriter -State $fenced -Component render -Artifact (Get-BridgeRenderArtifact)
    $true
}
Test-That 'and the version it crosses with is genuinely ahead of that fence' {
    [version](Get-BridgeRenderArtifact).version -gt [version]$olderFence.version
} "render=$((Get-BridgeRenderArtifact).version) fence=$($olderFence.version)"

# The other half, which must stay refused: same version, different content.
$sameVersionFence = @{ version = (Get-BridgeRenderArtifact).version; hash = ('b' * 64) }
$fenced.Policy.render = $sameVersionFence
$fenced.Policy.highRender = $sameVersionFence
Test-That 'an equal version with different content is still a conflict, not an advance' {
    $refused = $null
    try { Assert-BridgePublicationWriter -State $fenced -Component render -Artifact (Get-BridgeRenderArtifact) }
    catch { $refused = $_ }
    $null -ne $refused -and $refused.Exception.Data['BridgePublicationRefused'] -eq $true -and
        $refused.Exception.Message -match 'conflicting content'
}
Test-That 'and an older renderer still cannot cross a newer fence' {
    $refused = $null
    try {
        Assert-BridgePublicationWriter -State $fenced -Component render -Artifact @{ version = '1.0.0'; hash = ('c' * 64) }
    }
    catch { $refused = $_ }
    $null -ne $refused -and $refused.Exception.Message -match 'cannot cross the publication version fence'
}

Write-Host '--- new machines join established publication without changing authority ---'
Initialize-TestPublicationStore -Unconfigured
$joinCard = New-TestPublicationCard '1.1.0'
$joinPolicy = New-TestPublicationPolicy -CardSource $joinCard -Generation 2
Set-TestPublicationPolicy -Policy $joinPolicy
$sharedBeforeJoin = (Get-FileHash -LiteralPath $script:TestPublication.Path -Algorithm SHA256).Hash
Test-That 'a missing local publication setting is filled from the established shared policy' {
    $changed = Initialize-BridgePublicationParticipant
    $settings = Get-BridgePublicationSettings
    $changed -and $settings.authority -ceq $joinPolicy.authority -and
        $settings.writer -ceq $joinPolicy.writer -and $settings.generation -eq 2 -and
        $settings.participant -ceq (Get-BridgeMachineSlug)
}
Test-That 'joining persists only local participant settings and never changes shared resources' {
    $persisted = Get-BridgeUserConfig
    $persisted.dashboard.publication.participant -ceq (Get-BridgeMachineSlug) -and
        @(Get-TestPublicationWrites).Count -eq 0 -and
        (Get-FileHash -LiteralPath $script:TestPublication.Path -Algorithm SHA256).Hash -ceq $sharedBeforeJoin
}
$configBeforeRepeat = (Get-FileHash -LiteralPath $script:BridgeInstallContext.ConfigPath -Algorithm SHA256).Hash
$script:TestPublication.Commands.Clear()
Test-That 'an explicit local publication setting is preserved without even reading shared state' {
    -not (Initialize-BridgePublicationParticipant) -and $script:TestPublication.Commands.Count -eq 0 -and
        (Get-FileHash -LiteralPath $script:BridgeInstallContext.ConfigPath -Algorithm SHA256).Hash -ceq $configBeforeRepeat
}

foreach ($case in @('empty', 'legacy', 'unreadable', 'corrupt', 'lost')) {
    Initialize-TestPublicationStore -Unconfigured
    if ($case -eq 'legacy') { Set-TestPublicationCardUrl -Url '/local/agent-bridge-reply-card.js?v=1.1.0' }
    if ($case -eq 'unreadable') { $script:TestPublication.Reject['lovelace/resources'] = '{"code":"unauthorized","message":"Synthetic refusal"}' }
    if ($case -in @('corrupt', 'lost')) {
        Set-TestPublicationPolicy -Policy $joinPolicy
        if ($case -eq 'lost') { Read-BridgePublicationState | Out-Null }
        $store = Get-TestPublicationStore
        if ($case -eq 'corrupt') { $store.resources[0].url = 'data:text/javascript;base64,ZXhwb3J0IHt9Ow==#agent-bridge-publication-policy.js?policy=bad' }
        else { $store.resources = @() }
        Set-TestPublicationStore $store
    }
    $configBeforeFailure = (Get-FileHash -LiteralPath $script:BridgeInstallContext.ConfigPath -Algorithm SHA256).Hash
    $script:TestPublication.Commands.Clear()
    Test-That "$case publication state is reported instead of inventing participant authority" {
        $failure = $null
        try { Initialize-BridgePublicationParticipant | Out-Null }
        catch { $failure = $_ }
        $null -ne $failure -and
            ($case -notin @('empty', 'legacy') -or $failure.Exception.Message -match 'Choose a designated writer.*Set-BridgePublicationPolicy') -and
            @(Get-TestPublicationWrites).Count -eq 0 -and
            (Get-FileHash -LiteralPath $script:BridgeInstallContext.ConfigPath -Algorithm SHA256).Hash -ceq $configBeforeFailure
    }
}

Write-Host '--- health observes publication and this machine, not just a quiet log ---'
Initialize-TestPublicationStore
Initialize-TestPublicationAuthority -ServeCard
Save-CopilotSessionDashboard -Sessions @()
Set-TestPublicationIdentity -Participant 'observer-b'
$selfEntity = Get-CopilotMqttGlobalEntityId
$selfStates = @([pscustomobject]@{
    entity_id = $selfEntity; state = '0'
    attributes = [pscustomobject]@{ machine = 'Synthetic participant'; sessions = @() }
})
$script:TestPublication.Commands.Clear()
Test-That 'a configured non-writer observing verified publication is healthy' {
    (Get-BridgeMachineHealth -States $selfStates).Ok -and @(Get-TestPublicationWrites).Count -eq 0
}
Test-That 'a missing self sensor and machine-list entry are both diagnosed' {
    $health = Get-BridgeMachineHealth -States @()
    -not $health.Ok -and $health.Detail.Contains($selfEntity) -and
        $health.Detail -match 'missing from its own machine list'
}
Test-That 'a sensor left at Home Assistant''s derived id cannot make the machine healthy' {
    $wrongId = $selfEntity -replace '^sensor\.agent_bridge_', 'sensor.ai_agent_bridge_'
    $health = Get-BridgeMachineHealth -States @([pscustomobject]@{
        entity_id = $wrongId; state = '0'; attributes = $selfStates[0].attributes
    })
    -not $health.Ok -and $health.Detail -match 'wrong entity id.*administrator homeAssistant.token'
}
Set-TestPublicationIdentity -Participant 'observer-b' -Generation 2
Test-That 'local authority settings that disagree with shared policy need attention' {
    $health = Get-BridgeMachineHealth -States $selfStates
    -not $health.Ok -and $health.Detail -match 'does not match the established authority'
}
Set-TestPublicationIdentity
$savedRenderVersion = $script:BridgeDashboardRenderVersion
try {
    $script:BridgeDashboardRenderVersion = '1.0.0'
    Test-That 'a writer whose installed renderer is refused cannot report healthy' {
        $health = Get-BridgeMachineHealth -States $selfStates
        -not $health.Ok -and $health.Detail -match 'cannot cross the publication version fence'
    }
}
finally { $script:BridgeDashboardRenderVersion = $savedRenderVersion }
$config = Get-Content -LiteralPath $script:BridgeInstallContext.ConfigPath -Raw | ConvertFrom-Json -AsHashtable
[void]$config.dashboard.Remove('publication')
Write-BridgeSecretFile -Path $script:BridgeInstallContext.ConfigPath -Content ($config | ConvertTo-Json -Depth 10)
$script:BridgeUserConfig = Get-BridgeUserConfig
Test-That 'unconfigured publication is unhealthy even when the expected self sensor exists' {
    $health = Get-BridgeMachineHealth -States $selfStates
    -not $health.Ok -and $health.Detail -match 'Publication is not configured'
}

if ($script:Failures) {
    Write-Host "$($script:Failures) publication policy checks failed"
    exit 1
}
Write-Host 'All publication policy checks passed'
exit 0
