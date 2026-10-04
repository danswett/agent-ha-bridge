#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $env:AGENT_HA_BRIDGE_TEST_ROOT) { throw 'Run this suite through tests\run-tests.ps1.' }
. (Join-Path $PSScriptRoot 'runner-support.ps1')
Assert-BridgeTestEnvironment -Required
$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
Remove-Item Env:\AGENT_BRIDGE_DAEMON_NORUN

$script:P5Checks = 0
$script:P5CaseNumber = 0
$script:P5Root = Join-Path $env:TEMP 'p5-attachment-privacy'
Assert-BridgeTestPath -Path $script:P5Root
[void][IO.Directory]::CreateDirectory($script:P5Root)
$script:P5OriginalContext = Get-BridgeInstallContext
$script:P5OriginalAgents = $script:DaemonAgents
$script:P5SessionId = '55555555-0000-4000-8000-000000000005'
$script:P5Node = Get-CopilotMqttNodeId -SessionId $script:P5SessionId
$script:P5Topics = Get-CopilotMqttTopics -SessionId $script:P5SessionId
$script:P5PayloadEntity = "sensor.$($script:P5Node)_reply_payload"
$script:P5ActivityEntity = "sensor.$($script:P5Node)_activity"
$script:DecisionBridgeConfig.SessionStateRoot = Join-Path $script:P5Root 'absent-sessions'
$script:DaemonConfig.LogFile = Join-Path $script:P5Root 'daemon.log'

function Test-That {
    param([string]$Name, [scriptblock]$Check)
    $script:P5Checks++
    try {
        if (-not [bool](& $Check)) { throw 'The required outcome was not observed.' }
        if ($script:P5Unexpected.Count) { throw ($script:P5Unexpected -join '; ') }
        if ([IO.File]::ReadAllText($script:P5PublicSentinel) -cne 'unattributed public bytes' -or
            [IO.File]::ReadAllText($script:P5TempSentinel) -cne 'unattributed temporary bytes' -or
            @(Get-ChildItem -LiteralPath (Split-Path $script:P5PublicSentinel -Parent) -Force).Count -ne 1 -or
            @(Get-ChildItem -LiteralPath (Split-Path $script:P5TempSentinel -Parent) -Force).Count -ne 1) {
            throw 'Public/shared-TEMP fixture data was changed or used for staging.'
        }
        Write-Host "  PASS  $Name"
    }
    catch {
        Write-Host "  FAIL  $Name : $($_.Exception.Message)"
        throw
    }
}

function New-P5Context {
    param([string]$Label)
    $context = Resolve-BridgeInstallContext -TargetHome (Join-Path $script:P5Root $Label)
    Write-BridgeSecretFile -Path $context.ConfigPath -Content '{"homeAssistant":{"baseUrl":"http://127.0.0.1:1","token":"synthetic-test-token"}}'
    Initialize-BridgeInstallIdentity -Context $context
}

function Reset-P5Submission {
    param([string]$Label = 'ordinary')
    $script:P5CaseNumber++
    $script:BridgeInstallContext = New-P5Context -Label "$($script:P5CaseNumber)-$Label"
    $publicDirectory = Join-Path $script:BridgeInstallContext.PublicRoot 'agent-ha-bridge\attachments'
    $tempDirectory = Join-Path $env:TEMP 'agent-ha-bridge-attachments'
    Assert-BridgeTestPath -Path @($publicDirectory, $tempDirectory)
    [void][IO.Directory]::CreateDirectory($publicDirectory)
    [void][IO.Directory]::CreateDirectory($tempDirectory)
    $script:P5PublicSentinel = Join-Path $publicDirectory 'unattributed.txt'
    $script:P5TempSentinel = Join-Path $tempDirectory 'unattributed.txt'
    [IO.File]::WriteAllText($script:P5PublicSentinel, 'unattributed public bytes')
    if (-not (Test-Path -LiteralPath $script:P5TempSentinel)) {
        [IO.File]::WriteAllText($script:P5TempSentinel, 'unattributed temporary bytes')
    }
    $script:DaemonLive = @{}
    $script:DaemonAgents = [ordered]@{}
    $script:DaemonAgentCache = @{}
    $script:DaemonReconcileStates = $null
    $script:P5Entry = [pscustomobject]@{
        Name = 'Synthetic attachment session'; Machine = 'Fixture'
        LastReplyPayloadAt = 'previous-request'; LastPayloadDeliveredAt = 'previous-success'
        Driver = 'human'; DriverPending = $false
    }
    $script:P5Payload = [pscustomobject]@{
        state = "request-$($script:P5CaseNumber)"
        attributes = [pscustomobject]@{ text = 'read every attachment'; driver = 'agent'; images = @(); files = @() }
    }
    $script:P5Ha = @{
        $script:P5PayloadEntity = $script:P5Payload
        $script:P5ActivityEntity = [pscustomobject]@{
            state = 'Idle'; attributes = [pscustomobject]@{ response = 'previous response' }
        }
    }
    $script:P5Images = @{ first = [byte[]](11, 22, 33, 44); second = [byte[]](55, 66, 77, 88) }
    $script:P5FetchMode = @{}
    $script:P5Downloads = [Collections.Generic.List[object]]::new()
    $script:P5Console = [Collections.Generic.List[string]]::new()
    $script:P5Deleted = [Collections.Generic.List[string]]::new()
    $script:P5Order = [Collections.Generic.List[string]]::new()
    $script:P5ProcessReads = 0
    $script:P5NativeOutcome = 'ok:synthetic'
    $script:P5StampAtConsole = ''
    $script:P5ExclusiveRejected = $false
    $script:P5Unexpected = [Collections.Generic.List[string]]::new()
}

function Enable-P5SyntheticTransport {
    # The real Claude registry advertises an explicit PID. Only its OS lookup and
    # console boundary are synthetic; no registration scan or client is started.
    $script:DaemonAgents = $script:P5OriginalAgents
    $script:DaemonAgentCache = @{}
    $script:DaemonLive = @{
        $script:P5SessionId = [pscustomobject]@{ Kind = 'claude'; ProcessId = 555555 }
    }
}

function Set-P5PermissivePath {
    param([string]$Path)
    Assert-BridgeTestPath -Path $Path
    $item = Get-Item -LiteralPath $Path -Force
    if ($IsWindows) {
        $acl = [IO.FileSystemAclExtensions]::GetAccessControl(
            $item, [Security.AccessControl.AccessControlSections]::Access)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new('S-1-1-0'),
            [Security.AccessControl.FileSystemRights]::ReadAndExecute,
            [Security.AccessControl.AccessControlType]::Allow))
        [IO.FileSystemAclExtensions]::SetAccessControl($item, $acl)
    }
    else {
        $mode = if ($item.PSIsContainer) { '755' } else { '644' }
        [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode][Convert]::ToInt32($mode, 8))
    }
}

function Get-P5CorePathObservation {
    param([string]$Path)
    Assert-BridgeTestPath -Path $Path
    $observation = [ordered]@{
        Path = $Path; Exists = (Test-Path -LiteralPath $Path)
        IsDirectory = $null; Attributes = $null; Length = $null; WriteTicks = $null
        PermissionsHash = $null; Protected = $null; ContentHash = $null; Entries = @()
    }
    if ($observation.Exists) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $observation.IsDirectory = $item.PSIsContainer
        $observation.Attributes = [string]$item.Attributes
        $observation.WriteTicks = $item.LastWriteTimeUtc.Ticks
        $permissions = if ($IsWindows) { (Get-Acl -LiteralPath $Path).Sddl }
            else { [string](Get-BridgeSecretUnixMode -Path $Path) }
        $observation.PermissionsHash = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($permissions)))
        $observation.Protected = Test-BridgeSecretFileProtected -Path $Path
        if ($item.PSIsContainer) {
            $observation.Entries = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop | Sort-Object Name | ForEach-Object {
                [pscustomobject]@{
                    Name = $_.Name; IsDirectory = $_.PSIsContainer; Attributes = [string]$_.Attributes
                    Length = $(if ($_.PSIsContainer) { $null } else { $_.Length })
                    WriteTicks = $_.LastWriteTimeUtc.Ticks
                }
            })
        }
        else {
            $observation.Length = $item.Length
            $observation.ContentHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        }
    }
    [pscustomobject]$observation
}

function Test-P5CoreErrorMarker {
    param([AllowNull()][Management.Automation.ErrorRecord]$ErrorRecord, [string]$Marker)
    if ($null -eq $ErrorRecord) { return $false }
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception.Data[$Marker]) { return $true }
        $exception = $exception.InnerException
    }
    $false
}

function Stop-P5UnexpectedBoundary {
    param([string]$Message)
    $script:P5Unexpected.Add($Message)
    throw $Message
}

function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $ContentType, $Body, $TimeoutSec)
    $endpoint = [uri]$Uri
    if ($endpoint.Host -ne '127.0.0.1' -or $endpoint.Port -ne 1) { Stop-P5UnexpectedBoundary 'Unexpected REST authority.' }
    if ($Method -eq 'Get' -and $endpoint.AbsolutePath.StartsWith('/api/states/')) {
        $entity = $endpoint.AbsolutePath.Substring('/api/states/'.Length)
        if (-not $script:P5Ha.ContainsKey($entity)) { Stop-P5UnexpectedBoundary "Unexpected state read: $entity" }
        return $script:P5Ha[$entity]
    }
    if ($Method -ne 'Post' -or $endpoint.AbsolutePath -ne '/api/services/mqtt/publish') {
        Stop-P5UnexpectedBoundary 'Unexpected REST operation.'
    }
    $request = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
    if ($request.topic -eq $script:P5Topics.ActivityState) {
        $script:P5Ha[$script:P5ActivityEntity].state = [string]$request.payload
    }
    elseif ($request.topic -eq $script:P5Topics.ActivityAttributes) {
        $script:P5Ha[$script:P5ActivityEntity].attributes = $request.payload | ConvertFrom-Json
    }
    else { Stop-P5UnexpectedBoundary 'Unexpected MQTT topic.' }
}

function Invoke-WebRequest {
    param($Uri, $Headers, $OutFile, [switch]$UseBasicParsing, $ErrorAction)
    $endpoint = [uri]$Uri
    if ($endpoint.Host -ne '127.0.0.1' -or $endpoint.Port -ne 1 -or
        $endpoint.AbsolutePath -notmatch '^/api/image/serve/([a-z]+)/original$') {
        Stop-P5UnexpectedBoundary 'Unexpected attachment request.'
    }
    $imageId = $Matches[1]
    if (-not $script:P5Images.ContainsKey($imageId)) { Stop-P5UnexpectedBoundary 'Unexpected image id.' }
    Assert-BridgeTestPath -Path $OutFile
    $observation = [pscustomobject]@{
        Id = $imageId; Path = $OutFile
        RootProtectedBeforeBytes = (Test-BridgeSecretFileProtected -Path (Split-Path $OutFile -Parent))
        FileProtectedBeforeBytes = (Test-BridgeSecretFileProtected -Path $OutFile)
    }
    $script:P5Downloads.Add($observation)
    if (-not $observation.RootProtectedBeforeBytes -or -not $observation.FileProtectedBeforeBytes) {
        throw 'The HTTP boundary observed unprotected staging before its first byte.'
    }
    $script:P5Order.Add("download:$imageId")
    $mode = if ($script:P5FetchMode.ContainsKey($imageId)) { $script:P5FetchMode[$imageId] } else { 'ok' }
    if ($mode -eq 'refuse') { throw [IO.IOException]::new('synthetic HTTP refusal before bytes') }
    if ($mode -eq 'exclusive') {
        $held = [IO.File]::Open($OutFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { [IO.File]::WriteAllBytes($OutFile, $script:P5Images[$imageId]) }
        catch {
            $script:P5ExclusiveRejected = $_.Exception.GetBaseException() -is [IO.IOException]
            throw
        }
        finally { $held.Dispose() }
        Stop-P5UnexpectedBoundary 'The exclusive-handle fixture did not reject the second writer.'
    }
    if ($mode -eq 'partial') {
        [IO.File]::WriteAllBytes($OutFile, [byte[]](11))
        throw [IO.IOException]::new('synthetic HTTP failure after partial bytes')
    }
    [IO.File]::WriteAllBytes($OutFile, $script:P5Images[$imageId])
    if ($mode -eq 'unprotect-after-write') { Set-P5PermissivePath -Path $OutFile }
}

function Invoke-CopilotHaWebSocket {
    param([hashtable[]]$Commands)
    foreach ($command in $Commands) {
        if ($command.type -ne 'image/delete' -or -not $script:P5Images.ContainsKey($command.image_id)) {
            Stop-P5UnexpectedBoundary 'Unexpected HA WebSocket command.'
        }
        $script:P5Order.Add("delete:$($command.image_id)")
        $script:P5Deleted.Add([string]$command.image_id)
        $script:P5Images.Remove($command.image_id)
    }
}

function Get-Process {
    param([int]$Id, $ErrorAction)
    if ($Id -ne 555555) { Stop-P5UnexpectedBoundary 'Unexpected process lookup.' }
    $script:P5ProcessReads++
    [pscustomobject]@{ Id = $Id; ProcessName = 'synthetic-client' }
}

function Invoke-BridgeConsoleSend {
    param([int]$ProcessId, [string]$Text, [bool]$Submit, [int]$DelayMs)
    if ($ProcessId -ne 555555 -or -not $Submit) { Stop-P5UnexpectedBoundary 'Unexpected native delivery.' }
    $script:P5StampAtConsole = $script:P5Entry.LastReplyPayloadAt
    $script:P5Order.Add('console')
    $script:P5Console.Add($Text)
    $script:P5NativeOutcome
}

function Test-P5FailedSubmission {
    $script:P5Console.Count -eq 0 -and $script:P5Deleted.Count -eq 0 -and
        -not $script:P5Entry.DriverPending -and
        $script:P5Entry.LastReplyPayloadAt -eq $script:P5Payload.state -and
        $script:P5Entry.LastPayloadDeliveredAt -eq 'previous-success' -and
        $script:P5Ha[$script:P5ActivityEntity].state -eq 'Reply NOT sent'
}

Write-Host '--- private allocation and actual permission checks ---'
Reset-P5Submission
$uncreated = Get-BridgeAttachmentRoot -NoCreate
Test-That 'reading an owned attachment path creates no directory or marker' {
    -not (Test-Path -LiteralPath $uncreated) -and
        (Split-Path $uncreated -Leaf) -ceq "install-$($script:BridgeInstallContext.Id)"
}
[void][IO.Directory]::CreateDirectory($uncreated)
Set-P5PermissivePath -Path $uncreated
Test-That 'NoCreate does not repair an existing permissive directory' {
    (Get-BridgeAttachmentRoot -NoCreate) -eq $uncreated -and
        -not (Test-BridgeSecretFileProtected -Path $uncreated)
}
$saved = Save-BridgeReplyAttachment -ImageId first -Name image.png -Headers @{}
Test-That 'the actual allocator repairs its owned root and protects the image before the HTTP writer' {
    $saved -and $script:P5Downloads.Count -eq 1 -and
        $script:P5Downloads[0].RootProtectedBeforeBytes -and $script:P5Downloads[0].FileProtectedBeforeBytes -and
        (Test-BridgeSecretFileProtected -Path $saved) -and
        ([IO.File]::ReadAllBytes($saved) -join ',') -eq '11,22,33,44'
}
$existing = Join-Path $uncreated 'existing-owned.txt'
[IO.File]::WriteAllText($existing, 'previous private bytes')
Set-P5PermissivePath -Path $existing
Initialize-BridgeSecretFile -Path $existing
Test-That 'the reused initializer repairs a permissive owned file without truncating it' {
    (Test-BridgeSecretFileProtected -Path $existing) -and
        [IO.File]::ReadAllText($existing) -ceq 'previous private bytes'
}
$document = Save-BridgeReplyFile -Name notes.txt -Base64 'bm90ZXM='
Test-That 'the actual inline writer leaves the requested bytes in a protected file' {
    $document -and (Test-BridgeSecretFileProtected -Path $document) -and
        [IO.File]::ReadAllText($document) -ceq 'notes'
}
$atLimit = Save-BridgeReplyFile -Name limit.bin -Base64 ([Convert]::ToBase64String([byte[]]::new(262144)))
Test-That 'the existing inline byte limit still accepts exactly 262144 protected bytes' {
    $atLimit -and (Get-Item -LiteralPath $atLimit).Length -eq 262144 -and
        (Test-BridgeSecretFileProtected -Path $atLimit)
}

Write-Host '--- production core allocation with absent optional Windows metadata ---'
if ($IsWindows) {
    if ($script:BridgeIsWindows -isnot [bool] -or -not $script:BridgeIsWindows) {
        throw 'The allocation-core cases require the actual initialized Windows platform, not a substituted flag.'
    }
    Write-Host ('P5_CORE_SCOPE ' + (@{
        isWindows = $IsWindows; bridgeIsWindows = $script:BridgeIsWindows
        bridgeIsWindowsType = $script:BridgeIsWindows.GetType().FullName
        nullStringBinding = 'Caller null may normalize to empty; no distinct internal branch is claimed.'
        missingContextWrapperExercised = $false
    } | ConvertTo-Json -Compress))
    $coreForms = @(
        [pscustomobject]@{ Form = 'null'; Value = $null },
        [pscustomobject]@{ Form = 'empty'; Value = '' }
    )
    # These are caller forms, not distinct internal branches: a string parameter
    # can bind the caller's null as empty. The real environment/context stays valid.
    foreach ($coreForm in $coreForms) {
        Reset-P5Submission -Label "core-nocreate-$($coreForm.Form)"
        $coreContext = Get-BridgeInstallContext
        $coreArguments = @{
            BridgeHome = $coreContext.BridgeHome; LocalAppData = $coreForm.Value
            InstallationId = $coreContext.Id; Legacy = $coreContext.Legacy
        }
        $coreExpected = Join-Path (Join-Path $coreContext.BridgeHome 'attachments') "install-$($coreContext.Id)"
        $coreBefore = Get-P5CorePathObservation -Path $coreExpected
        $coreParentBefore = Get-P5CorePathObservation -Path $coreContext.BridgeHome
        $corePath = Get-BridgeAttachmentRootForInstallation @coreArguments -NoCreate
        $coreAfter = Get-P5CorePathObservation -Path $coreExpected
        $coreParentAfter = Get-P5CorePathObservation -Path $coreContext.BridgeHome
        Write-Host ('P5_CORE_ALLOCATION ' + (@{
            callerForm = $coreForm.Form; noCreate = $true; selected = $corePath
            bridgeHome = $coreContext.BridgeHome; installationId = $coreContext.Id; legacy = $coreContext.Legacy
            before = $coreBefore; after = $coreAfter; parentBefore = $coreParentBefore; parentAfter = $coreParentAfter
            contextLocalAppDataPresent = -not [string]::IsNullOrWhiteSpace($coreContext.LocalAppData)
            environmentLocalAppDataPresent = -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)
            coverage = 'production core only; no missing-context wrapper claim'
        } | ConvertTo-Json -Depth 6 -Compress))
        Test-That "the $($coreForm.Form) core argument leaves fallback NoCreate entirely read-only" {
            $corePath -ceq $coreExpected -and -not $coreBefore.Exists -and -not $coreAfter.Exists -and
                ($coreParentBefore | ConvertTo-Json -Depth 5 -Compress) -ceq ($coreParentAfter | ConvertTo-Json -Depth 5 -Compress) -and
                -not [string]::IsNullOrWhiteSpace($coreContext.LocalAppData) -and
                -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)
        }
    }
    foreach ($coreForm in $coreForms) {
        Reset-P5Submission -Label "core-create-$($coreForm.Form)"
        $coreContext = Get-BridgeInstallContext
        $coreArguments = @{
            BridgeHome = $coreContext.BridgeHome; LocalAppData = $coreForm.Value
            InstallationId = $coreContext.Id; Legacy = $coreContext.Legacy
        }
        $coreExpected = Join-Path (Join-Path $coreContext.BridgeHome 'attachments') "install-$($coreContext.Id)"
        $corePath = Get-BridgeAttachmentRootForInstallation @coreArguments
        $coreRootBeforeBytes = Get-P5CorePathObservation -Path $corePath
        $coreFile = Join-Path $corePath 'core-initialized.txt'
        Assert-BridgeTestPath -Path $coreFile
        Initialize-BridgeSecretFile -Path $coreFile
        $coreBeforeBytes = Get-P5CorePathObservation -Path $coreFile
        Write-BridgeSecretFile -Path $coreFile -Content 'synthetic-core-content'
        $coreAfterBytes = Get-P5CorePathObservation -Path $coreFile
        $coreRootAfterBytes = Get-P5CorePathObservation -Path $corePath
        Write-Host ('P5_CORE_ALLOCATION ' + (@{
            callerForm = $coreForm.Form; noCreate = $false; selected = $corePath
            bridgeHome = $coreContext.BridgeHome; installationId = $coreContext.Id; legacy = $coreContext.Legacy
            rootBeforeBytes = $coreRootBeforeBytes; fileBeforeBytes = $coreBeforeBytes
            rootAfterBytes = $coreRootAfterBytes; fileAfterBytes = $coreAfterBytes
            coverage = 'production core and shared file primitives only'
        } | ConvertTo-Json -Depth 6 -Compress))
        Test-That "the $($coreForm.Form) core argument creates private fallback storage before real writer bytes" {
            $corePath -ceq $coreExpected -and $coreRootBeforeBytes.IsDirectory -and $coreRootBeforeBytes.Protected -and
                $coreBeforeBytes.Length -eq 0 -and $coreBeforeBytes.Protected -and
                $coreRootAfterBytes.Protected -and $coreAfterBytes.Protected -and
                [IO.File]::ReadAllText($coreFile) -ceq 'synthetic-core-content' -and
                -not [string]::IsNullOrWhiteSpace($coreContext.LocalAppData) -and
                -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)
        }
    }

    Reset-P5Submission -Label 'core-existing'
    $coreContext = Get-BridgeInstallContext
    $coreArguments = @{
        BridgeHome = $coreContext.BridgeHome; LocalAppData = ''
        InstallationId = $coreContext.Id; Legacy = $coreContext.Legacy
    }
    $coreExpected = Join-Path (Join-Path $coreContext.BridgeHome 'attachments') "install-$($coreContext.Id)"
    Assert-BridgeTestPath -Path $coreExpected
    [void][IO.Directory]::CreateDirectory($coreExpected)
    $coreSentinel = Join-Path $coreExpected 'keep.bin'
    [IO.File]::WriteAllBytes($coreSentinel, [byte[]](4, 3, 2, 1))
    Set-P5PermissivePath -Path $coreExpected
    $coreWeakBefore = Get-P5CorePathObservation -Path $coreExpected
    $coreSentinelBefore = Get-P5CorePathObservation -Path $coreSentinel
    $corePath = Get-BridgeAttachmentRootForInstallation @coreArguments -NoCreate
    $coreWeakAfter = Get-P5CorePathObservation -Path $coreExpected
    $coreRepairedPath = Get-BridgeAttachmentRootForInstallation @coreArguments
    $coreRepaired = Get-P5CorePathObservation -Path $coreExpected
    $coreSentinelAfter = Get-P5CorePathObservation -Path $coreSentinel
    Write-Host ('P5_CORE_REPAIR ' + (@{
        before = $coreWeakBefore; afterNoCreate = $coreWeakAfter; repaired = $coreRepaired
        sentinelBefore = $coreSentinelBefore; sentinelAfter = $coreSentinelAfter
    } | ConvertTo-Json -Depth 6 -Compress))
    Test-That 'the core leaves a permissive fallback root untouched under NoCreate and really repairs it for allocation' {
        $corePath -ceq $coreExpected -and $coreRepairedPath -ceq $coreExpected -and -not $coreWeakBefore.Protected -and
            ($coreWeakBefore | ConvertTo-Json -Depth 5 -Compress) -ceq ($coreWeakAfter | ConvertTo-Json -Depth 5 -Compress) -and
            $coreRepaired.Protected -and $coreSentinelBefore.ContentHash -ceq $coreSentinelAfter.ContentHash
    }

    Reset-P5Submission -Label 'core-obstructed'
    $coreContext = Get-BridgeInstallContext
    $coreArguments = @{
        BridgeHome = $coreContext.BridgeHome; LocalAppData = ''
        InstallationId = $coreContext.Id; Legacy = $coreContext.Legacy
    }
    $coreExpected = Join-Path (Join-Path $coreContext.BridgeHome 'attachments') "install-$($coreContext.Id)"
    Assert-BridgeTestPath -Path $coreExpected
    [void][IO.Directory]::CreateDirectory((Split-Path $coreExpected -Parent))
    [IO.File]::WriteAllText($coreExpected, 'core directory obstruction')
    $coreObstructionBefore = Get-P5CorePathObservation -Path $coreExpected
    $coreObstructionError = $null
    $coreObstructedResult = $null
    try { $coreObstructedResult = Get-BridgeAttachmentRootForInstallation @coreArguments }
    catch {
        $coreObstructionError = $_
        if ((Test-P5CoreErrorMarker $coreObstructionError 'BridgeTestWriteBlocked') -or
            (Test-P5CoreErrorMarker $coreObstructionError 'BridgeTestNetworkBlocked')) { throw $coreObstructionError }
        if ($coreObstructionError.Exception.GetBaseException() -isnot [IO.IOException] -or
            $coreObstructionError.ScriptStackTrace -notmatch 'Get-BridgeAttachmentRootForInstallation') { throw $coreObstructionError }
    }
    $coreObstructionAfter = Get-P5CorePathObservation -Path $coreExpected
    Write-Host ('P5_CORE_OBSTRUCTION ' + (@{
        before = $coreObstructionBefore; after = $coreObstructionAfter
        originalError = $(if ($coreObstructionError) { @{
            type = $coreObstructionError.Exception.GetType().FullName; text = $coreObstructionError.Exception.ToString()
            fullyQualifiedErrorId = $coreObstructionError.FullyQualifiedErrorId; stack = $coreObstructionError.ScriptStackTrace
        } } else { $null })
    } | ConvertTo-Json -Depth 6 -Compress))
    Test-That 'a real file blocks core fallback creation without becoming a guard or binding failure pass' {
        $null -ne $coreObstructionError -and $null -eq $coreObstructedResult -and
            -not $coreObstructionAfter.IsDirectory -and
            ($coreObstructionBefore | ConvertTo-Json -Depth 5 -Compress) -ceq ($coreObstructionAfter | ConvertTo-Json -Depth 5 -Compress) -and
            $script:P5Downloads.Count -eq 0 -and $script:P5Console.Count -eq 0 -and $script:P5Deleted.Count -eq 0
    }

    Reset-P5Submission -Label 'core-linked'
    $coreContext = Get-BridgeInstallContext
    $coreArguments = @{
        BridgeHome = $coreContext.BridgeHome; LocalAppData = $null
        InstallationId = $coreContext.Id; Legacy = $coreContext.Legacy
    }
    $coreExpected = Join-Path (Join-Path $coreContext.BridgeHome 'attachments') "install-$($coreContext.Id)"
    $coreTarget = Join-Path $script:P5Root "core-link-target-$($script:P5CaseNumber)"
    Assert-BridgeTestPath -Path @($coreExpected, $coreTarget)
    [void][IO.Directory]::CreateDirectory((Split-Path $coreExpected -Parent))
    [void][IO.Directory]::CreateDirectory($coreTarget)
    $coreTargetFile = Join-Path $coreTarget 'untouched.bin'
    [IO.File]::WriteAllBytes($coreTargetFile, [byte[]](8, 6, 4, 2))
    $coreTargetBefore = Get-P5CorePathObservation -Path $coreTarget
    $coreTargetFileBefore = Get-P5CorePathObservation -Path $coreTargetFile
    New-Item -ItemType Junction -Path $coreExpected -Target $coreTarget | Out-Null
    try {
        $coreLinkError = $null
        $coreLinkedResult = $null
        try { $coreLinkedResult = Get-BridgeAttachmentRootForInstallation @coreArguments }
        catch {
            $coreLinkError = $_
            if (-not (Test-P5CoreErrorMarker $coreLinkError 'BridgeTestWriteBlocked') -or
                (Test-P5CoreErrorMarker $coreLinkError 'BridgeTestNetworkBlocked')) { throw $coreLinkError }
        }
        $coreTargetAfter = Get-P5CorePathObservation -Path $coreTarget
        $coreTargetFileAfter = Get-P5CorePathObservation -Path $coreTargetFile
        Write-Host ('P5_CORE_LINK ' + (@{
            originalError = $(if ($coreLinkError) { @{
                type = $coreLinkError.Exception.GetType().FullName; text = $coreLinkError.Exception.ToString()
                fullyQualifiedErrorId = $coreLinkError.FullyQualifiedErrorId; stack = $coreLinkError.ScriptStackTrace
            } } else { $null })
            targetBefore = $coreTargetBefore; targetAfter = $coreTargetAfter
            fileBefore = $coreTargetFileBefore; fileAfter = $coreTargetFileAfter
            expectedRejectingBoundary = 'Assert-BridgeTestPath / BridgeTestWriteBlocked'
        } | ConvertTo-Json -Depth 6 -Compress))
        Test-That 'the real S1 selected-path boundary refuses a core fallback link and preserves its target' {
            $null -ne $coreLinkError -and $null -eq $coreLinkedResult -and
                $coreLinkError.ScriptStackTrace -match 'Assert-BridgeTestPath' -and
                ($coreTargetBefore | ConvertTo-Json -Depth 5 -Compress) -ceq ($coreTargetAfter | ConvertTo-Json -Depth 5 -Compress) -and
                ($coreTargetFileBefore | ConvertTo-Json -Depth 5 -Compress) -ceq ($coreTargetFileAfter | ConvertTo-Json -Depth 5 -Compress) -and
                $script:P5Downloads.Count -eq 0 -and $script:P5Console.Count -eq 0
        }
    }
    finally { [IO.Directory]::Delete($coreExpected) }

    Reset-P5Submission -Label 'core-owner-a'
    $coreOwnerA = Get-BridgeInstallContext
    $coreRootA = Get-BridgeAttachmentRootForInstallation -BridgeHome $coreOwnerA.BridgeHome `
        -LocalAppData '' -InstallationId $coreOwnerA.Id -Legacy $coreOwnerA.Legacy
    $coreFileA = Join-Path $coreRootA 'owner.txt'
    Write-BridgeSecretFile -Path $coreFileA -Content 'core-owner-a'
    $coreFileABefore = Get-P5CorePathObservation -Path $coreFileA
    $coreRootABefore = Get-P5CorePathObservation -Path $coreRootA
    $corePublicA = $script:P5PublicSentinel
    $corePublicABefore = Get-P5CorePathObservation -Path $corePublicA
    Reset-P5Submission -Label 'core-owner-b'
    $coreOwnerB = Get-BridgeInstallContext
    $coreExpectedB = Join-Path (Join-Path $coreOwnerB.BridgeHome 'attachments') "install-$($coreOwnerB.Id)"
    Assert-BridgeTestPath -Path $coreExpectedB
    [void][IO.Directory]::CreateDirectory((Split-Path $coreExpectedB -Parent))
    $coreLegacy = Join-Path (Split-Path $coreExpectedB -Parent) 'unattributed.txt'
    [IO.File]::WriteAllText($coreLegacy, 'unattributed core sentinel')
    $coreLegacyBefore = Get-P5CorePathObservation -Path $coreLegacy
    $coreRootB = Get-BridgeAttachmentRootForInstallation -BridgeHome $coreOwnerB.BridgeHome `
        -LocalAppData $null -InstallationId $coreOwnerB.Id -Legacy $coreOwnerB.Legacy
    $coreFileB = Join-Path $coreRootB 'owner.txt'
    Write-BridgeSecretFile -Path $coreFileB -Content 'core-owner-b'
    $coreFileAAfter = Get-P5CorePathObservation -Path $coreFileA
    $coreFileBAfter = Get-P5CorePathObservation -Path $coreFileB
    $coreRootAAfter = Get-P5CorePathObservation -Path $coreRootA
    $coreRootBAfter = Get-P5CorePathObservation -Path $coreRootB
    $corePublicAAfter = Get-P5CorePathObservation -Path $corePublicA
    $coreLegacyAfter = Get-P5CorePathObservation -Path $coreLegacy
    Write-Host ('P5_CORE_OWNERSHIP ' + (@{
        rootA = $coreRootA; rootB = $coreRootB; fileABefore = $coreFileABefore; fileAAfter = $coreFileAAfter
        rootABefore = $coreRootABefore; rootAAfter = $coreRootAAfter; rootBAfter = $coreRootBAfter
        fileB = $coreFileBAfter; legacyBefore = $coreLegacyBefore; legacyAfter = $coreLegacyAfter
        publicABefore = $corePublicABefore; publicAAfter = $corePublicAAfter
    } | ConvertTo-Json -Depth 6 -Compress))
    Test-That 'absent core metadata keeps two real installation roots and unrelated sentinels separate' {
        $coreOwnerA.Id -cne $coreOwnerB.Id -and $coreRootA -cne $coreRootB -and
            (Split-Path $coreRootA -Leaf) -ceq "install-$($coreOwnerA.Id)" -and
            (Split-Path $coreRootB -Leaf) -ceq "install-$($coreOwnerB.Id)" -and
            $coreRootAAfter.Protected -and $coreRootBAfter.Protected -and
            ($coreRootABefore | ConvertTo-Json -Depth 5 -Compress) -ceq ($coreRootAAfter | ConvertTo-Json -Depth 5 -Compress) -and
            $coreFileAAfter.Protected -and $coreFileBAfter.Protected -and
            $coreFileABefore.ContentHash -ceq $coreFileAAfter.ContentHash -and
            [IO.File]::ReadAllText($coreFileB) -ceq 'core-owner-b' -and
            $coreLegacyBefore.ContentHash -ceq $coreLegacyAfter.ContentHash -and
            $corePublicABefore.ContentHash -ceq $corePublicAAfter.ContentHash
    }
}
else {
    Write-Host 'SKIP Windows missing-metadata allocation-core cases: the real platform is not Windows.'
}

foreach ($label in @("O'Brien", "unicode-$([char]0x00e9)")) {
    Reset-P5Submission -Label $label
    $saved = Save-BridgeReplyAttachment -ImageId first -Name image.png -Headers @{}
    Test-That "$label stays private and keeps the existing unquoted prompt representation" {
        $saved -and (Test-BridgeSecretFileProtected -Path $saved) -and
            (New-BridgeAttachmentPrompt -Text 'read it' -Paths @($saved)) -ceq "@$saved read it"
    }
}

Reset-P5Submission -Label 'home with spaces'
$script:P5Payload.attributes.images = @([pscustomobject]@{ id = 'first'; name = 'image.png' })
[void](Send-DaemonCardPayload -SessionId $script:P5SessionId -Entry $script:P5Entry -Headers @{})
Test-That 'a spaced private path refuses all native text while keeping its source and protected bytes' {
    (Test-P5FailedSubmission) -and $script:P5Images.ContainsKey('first') -and
        $script:P5Downloads.Count -eq 1 -and
        (Test-BridgeInstallDescendant $script:P5Downloads[0].Path $script:BridgeInstallContext.Home) -and
        -not (Test-BridgeInstallDescendant $script:P5Downloads[0].Path $script:BridgeInstallContext.PublicRoot) -and
        (Test-BridgeSecretFileProtected -Path $script:P5Downloads[0].Path)
}
Test-That 'the failed spaced submission is not automatically retried' {
    (Send-DaemonCardPayload -SessionId $script:P5SessionId -Entry $script:P5Entry -Headers @{}) -eq $false -and
        $script:P5Downloads.Count -eq 1 -and $script:P5Console.Count -eq 0
}

Reset-P5Submission
$localAppData = $script:BridgeInstallContext.LocalAppData
try {
    $script:BridgeInstallContext.LocalAppData = ''
    $refusal = $null
    try { $null = Save-BridgeReplyFile -Name notes.txt -Base64 'bm90ZXM=' }
    catch { $refusal = $_ }
    Test-That 'a missing fixture LocalAppData propagates the real S1 refusal without weakening containment' {
        $refusal -and $refusal.Exception.Data['BridgeTestWriteBlocked'] -and $script:P5Downloads.Count -eq 0
    }
}
finally { $script:BridgeInstallContext.LocalAppData = $localAppData }
Write-Host 'GAP: the normal-runtime missing-LocalAppData fallback is not exercised; S1 requires that fixture field.'

$legacy = $script:P5OriginalContext
if (-not $legacy.Legacy) { throw 'The fresh canonical fixture did not provide the expected unidentified legacy context.' }
$legacyRoot = Join-Path $legacy.LocalAppData 'agent-ha-bridge\attachments'
Assert-BridgeTestPath -Path $legacyRoot
[void][IO.Directory]::CreateDirectory($legacyRoot)
$legacyFile = Join-Path $legacyRoot 'unattributed.txt'
[IO.File]::WriteAllText($legacyFile, 'unattributed legacy bytes')
$script:BridgeInstallContext = $legacy
$legacyRefusal = $null
try { $null = Get-BridgeAttachmentRoot } catch { $legacyRefusal = $_ }
Test-That 'an unidentified legacy installation is refused without claiming its old files' {
    $legacyRefusal -and $legacyRefusal.Exception.Message -like '*installation identity*' -and
        [IO.File]::ReadAllText($legacyFile) -ceq 'unattributed legacy bytes' -and
        -not (Test-Path -LiteralPath $legacy.MetadataPath)
}

Reset-P5Submission -Label 'owner-a'
$ownerA = Get-BridgeAttachmentRoot
$fileA = Save-BridgeReplyFile -Name keep.txt -Base64 'QQ=='
Reset-P5Submission -Label 'owner-b'
$ownerB = Get-BridgeAttachmentRoot
$fileB = Save-BridgeReplyFile -Name keep.txt -Base64 'Qg=='
Remove-BridgeStaleAttachment -MaxAgeHours 24
Test-That 'a second installation and cleanup preserve the first installation and unattributed legacy bytes' {
    $ownerA -ne $ownerB -and [IO.File]::ReadAllText($fileA) -ceq 'A' -and
        [IO.File]::ReadAllText($fileB) -ceq 'B' -and
        [IO.File]::ReadAllText($legacyFile) -ceq 'unattributed legacy bytes'
}

Write-Host '--- real filesystem failures reach the real card consumer ---'
Reset-P5Submission
$blocked = Get-BridgeAttachmentRoot -NoCreate
[void][IO.Directory]::CreateDirectory((Split-Path $blocked -Parent))
[IO.File]::WriteAllText($blocked, 'directory-blocking sentinel')
$script:P5Payload.attributes.images = @([pscustomobject]@{ id = 'first'; name = 'image.png' })
[void](Send-DaemonCardPayload -SessionId $script:P5SessionId -Entry $script:P5Entry -Headers @{})
Test-That 'a real file obstructing directory creation refuses the whole send before any HTTP bytes' {
    (Test-P5FailedSubmission) -and $script:P5Downloads.Count -eq 0 -and
        [IO.File]::ReadAllText($blocked) -ceq 'directory-blocking sentinel' -and $script:P5Images.ContainsKey('first')
}
foreach ($mode in @('exclusive', 'partial', 'refuse')) {
    Reset-P5Submission
    $script:P5FetchMode['first'] = $mode
    $script:P5Payload.attributes.images = @([pscustomobject]@{ id = 'first'; name = 'image.png' })
    [void](Send-DaemonCardPayload -SessionId $script:P5SessionId -Entry $script:P5Entry -Headers @{})
    Test-That "$mode download failure preserves the source and never types a partial reply" {
        (Test-P5FailedSubmission) -and $script:P5Downloads.Count -eq 1 -and
            $script:P5Images.ContainsKey('first') -and
            ($mode -ne 'exclusive' -or ($script:P5ExclusiveRejected -and
                (Get-Item -LiteralPath $script:P5Downloads[0].Path).Length -eq 0)) -and
            ($mode -ne 'partial' -or (Get-Item -LiteralPath $script:P5Downloads[0].Path).Length -eq 1) -and
            (Test-BridgeSecretFileProtected -Path $script:P5Downloads[0].Path)
    }
}
Reset-P5Submission
$script:P5FetchMode['first'] = 'unprotect-after-write'
$script:P5Payload.attributes.images = @([pscustomobject]@{ id = 'first'; name = 'image.png' })
try {
    [void](Send-DaemonCardPayload -SessionId $script:P5SessionId -Entry $script:P5Entry -Headers @{})
    Test-That 'a real post-download permission mismatch refuses the reply and preserves its HA source' {
        (Test-P5FailedSubmission) -and $script:P5Images.ContainsKey('first') -and
            $script:P5Downloads.Count -eq 1 -and $script:P5Downloads[0].FileProtectedBeforeBytes -and
            -not (Test-BridgeSecretFileProtected -Path $script:P5Downloads[0].Path)
    }
}
finally {
    if ($script:P5Downloads.Count -and -not (Protect-BridgeSecretFile -Path $script:P5Downloads[0].Path)) {
        throw 'Could not restore the deliberately weakened synthetic file.'
    }
}
Reset-P5Submission
$script:P5FetchMode['second'] = 'partial'
$script:P5Payload.attributes.images = @(
    [pscustomobject]@{ id = 'first'; name = 'one.png' }, [pscustomobject]@{ id = 'second'; name = 'two.png' })
[void](Send-DaemonCardPayload -SessionId $script:P5SessionId -Entry $script:P5Entry -Headers @{})
Test-That 'a later failed image preserves the successfully staged first image and both HA sources' {
    (Test-P5FailedSubmission) -and $script:P5Downloads.Count -eq 2 -and $script:P5Images.Count -eq 2 -and
        ([IO.File]::ReadAllBytes($script:P5Downloads[0].Path) -join ',') -eq '11,22,33,44'
}

foreach ($inline in @(
    @{ Name = 'malformed'; Base64 = 'not base64!' },
    @{ Name = '262145-byte'; Base64 = [Convert]::ToBase64String([byte[]]::new(262145)) }
)) {
    Reset-P5Submission
    $script:P5Payload.attributes.images = @([pscustomobject]@{ id = 'first'; name = 'image.png' })
    $script:P5Payload.attributes.files = @([pscustomobject]@{ name = 'notes.txt'; b64 = $inline.Base64 })
    [void](Send-DaemonCardPayload -SessionId $script:P5SessionId -Entry $script:P5Entry -Headers @{})
    Test-That "a $($inline.Name) inline document keeps the staged image instead of sending a subset" {
        (Test-P5FailedSubmission) -and $script:P5Images.ContainsKey('first') -and
            ([IO.File]::ReadAllBytes($script:P5Downloads[0].Path) -join ',') -eq '11,22,33,44'
    }
}
foreach ($metadata in @(
    [pscustomobject]@{ text = 'text must not escape'; images = @([pscustomobject]@{ name = 'missing-id.png' }) },
    [pscustomobject]@{ text = ''; images = @($null) },
    [pscustomobject]@{ text = 'text must not escape'; files = @([pscustomobject]@{ name = 'missing-bytes.txt' }) }
)) {
    Reset-P5Submission
    $script:P5Payload.attributes = $metadata
    $script:P5Entry.Driver = 'agent'
    $expectedDriver = if ($metadata.text) { 'human' } else { 'agent' }
    $metadataLabel = if ($metadata.PSObject.Properties['files']) { 'missing inline bytes' }
        elseif ($metadata.text) { 'a missing image id' }
        else { 'a null image without text' }
    [void](Send-DaemonCardPayload -SessionId $script:P5SessionId -Entry $script:P5Entry -Headers @{})
    Test-That "$metadataLabel is a visible whole-submission failure" {
        (Test-P5FailedSubmission) -and $script:P5Downloads.Count -eq 0 -and
            $script:P5Entry.Driver -eq $expectedDriver
    }
}

Reset-P5Submission
$script:P5Payload.attributes.images = @([pscustomobject]@{ id = 'first'; name = 'image.png' })
$webBoundary = ${function:Invoke-WebRequest}
try {
    Remove-Item Function:\Invoke-WebRequest
    $networkRefusal = $null
    try { $null = Send-DaemonCardPayload -SessionId $script:P5SessionId -Entry $script:P5Entry -Headers @{} }
    catch { $networkRefusal = $_ }
    Test-That 'the real offline HTTP guard propagates through staging and the card consumer' {
        $networkRefusal -and $networkRefusal.Exception.Data['BridgeTestNetworkBlocked'] -and
            $script:P5Downloads.Count -eq 0 -and $script:P5Console.Count -eq 0 -and
            $script:P5Deleted.Count -eq 0 -and -not $script:P5Entry.DriverPending
    }
}
finally { Set-Item Function:\Invoke-WebRequest -Value $webBoundary }

Reset-P5Submission
$link = Get-BridgeAttachmentRoot -NoCreate
$target = Join-Path $script:P5Root 'link-target'
[void][IO.Directory]::CreateDirectory((Split-Path $link -Parent))
[void][IO.Directory]::CreateDirectory($target)
$targetFile = Join-Path $target 'untouched.txt'
[IO.File]::WriteAllText($targetFile, 'link target sentinel')
$targetPermissions = if ($IsWindows) { (Get-Acl -LiteralPath $target).Sddl }
    else { [string](Get-BridgeSecretUnixMode -Path $target) }
New-Item -ItemType $(if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }) -Path $link -Target $target | Out-Null
try {
    Test-That 'the real privacy helper refuses a linked directory without protecting its target' {
        $refused = -not (Protect-BridgeSecretFile -Path $link)
        $afterPermissions = if ($IsWindows) { (Get-Acl -LiteralPath $target).Sddl }
            else { [string](Get-BridgeSecretUnixMode -Path $target) }
        $refused -and $afterPermissions -ceq $targetPermissions -and
            [IO.File]::ReadAllText($targetFile) -ceq 'link target sentinel'
    }
    $script:P5Payload.attributes.images = @([pscustomobject]@{ id = 'first'; name = 'image.png' })
    $linkRefusal = $null
    try { $null = Send-DaemonCardPayload -SessionId $script:P5SessionId -Entry $script:P5Entry -Headers @{} }
    catch { $linkRefusal = $_ }
    Test-That 'the real consumer stops at S1 for a linked destination and never touches the target' {
        $afterPermissions = if ($IsWindows) { (Get-Acl -LiteralPath $target).Sddl }
            else { [string](Get-BridgeSecretUnixMode -Path $target) }
        $linkRefusal -and $linkRefusal.Exception.Data['BridgeTestWriteBlocked'] -and
            $afterPermissions -ceq $targetPermissions -and
            $script:P5Downloads.Count -eq 0 -and $script:P5Console.Count -eq 0 -and
            $script:P5Deleted.Count -eq 0 -and [IO.File]::ReadAllText($targetFile) -ceq 'link target sentinel'
    }
}
finally { [IO.Directory]::Delete($link) }

Write-Host '--- real delivery failures and transport-only success ---'
Reset-P5Submission
$script:P5Payload.attributes.images = @([pscustomobject]@{ id = 'first'; name = 'image.png' })
[void](Send-DaemonCardPayload -SessionId $script:P5SessionId -Entry $script:P5Entry -Headers @{})
Test-That 'an actually absent synthetic session fails before process lookup and retains its staged image' {
    (Test-P5FailedSubmission) -and $script:P5ProcessReads -eq 0 -and
        $script:P5Ha[$script:P5ActivityEntity].attributes.error -eq 'no live process for session' -and
        $script:P5Images.ContainsKey('first') -and
        ([IO.File]::ReadAllBytes($script:P5Downloads[0].Path) -join ',') -eq '11,22,33,44'
}
Reset-P5Submission
Enable-P5SyntheticTransport
$script:P5NativeOutcome = 'attach-failed:synthetic'
$script:P5Payload.attributes.images = @([pscustomobject]@{ id = 'first'; name = 'image.png' })
[void](Send-DaemonCardPayload -SessionId $script:P5SessionId -Entry $script:P5Entry -Headers @{})
Test-That 'a refused console transport returns through the real send helpers without deleting its image' {
    $script:P5Console.Count -eq 1 -and $script:P5Deleted.Count -eq 0 -and
        $script:P5Images.ContainsKey('first') -and -not $script:P5Entry.DriverPending -and
        $script:P5Entry.LastPayloadDeliveredAt -eq 'previous-success' -and
        $script:P5Ha[$script:P5ActivityEntity].state -eq 'Reply NOT sent'
}
$firstCopy = $script:P5Downloads[0].Path
$script:P5FetchMode['first'] = 'partial'
$script:P5Payload.state = 'explicit-new-request'
[void](Send-DaemonCardPayload -SessionId $script:P5SessionId -Entry $script:P5Entry -Headers @{})
Test-That 'a failed new submission of the same image cannot truncate the previous private copy' {
    $script:P5Downloads.Count -eq 2 -and $firstCopy -ne $script:P5Downloads[1].Path -and
        ([IO.File]::ReadAllBytes($firstCopy) -join ',') -eq '11,22,33,44' -and $script:P5Deleted.Count -eq 0
}
Reset-P5Submission
Enable-P5SyntheticTransport
$script:P5Payload.attributes.images = @([pscustomobject]@{ id = 'first'; name = 'image.png' })
$script:P5Payload.attributes.files = @([pscustomobject]@{ name = 'notes.txt'; b64 = 'bm90ZXM=' })
[void](Send-DaemonCardPayload -SessionId $script:P5SessionId -Entry $script:P5Entry -Headers @{})
$successfulFiles = @(Get-ChildItem -LiteralPath (Get-BridgeAttachmentRoot -NoCreate) -File)
$expectedPrompt = "@$($script:P5Downloads[0].Path) @$((@($successfulFiles | Where-Object Extension -EQ '.txt'))[0].FullName) read every attachment"
Test-That 'successful synthetic transport carries every protected file before HA source cleanup' {
    $script:P5Console.Count -eq 1 -and $script:P5Console[0] -ceq $expectedPrompt -and
        $script:P5StampAtConsole -ceq $script:P5Payload.state -and
        $successfulFiles.Count -eq 2 -and
        @($successfulFiles | Where-Object { -not (Test-BridgeSecretFileProtected -Path $_.FullName) }).Count -eq 0 -and
        $script:P5Order.IndexOf('console') -lt $script:P5Order.IndexOf('delete:first') -and
        $script:P5Deleted.Count -eq 1 -and -not $script:P5Images.ContainsKey('first') -and
        $script:P5Entry.DriverPending -and $script:P5Entry.LastPayloadDeliveredAt -ne 'previous-success'
}
Test-That 'the consumed successful stamp cannot deliver the same payload twice' {
    (Send-DaemonCardPayload -SessionId $script:P5SessionId -Entry $script:P5Entry -Headers @{}) -eq $false -and
        $script:P5Console.Count -eq 1 -and $script:P5Deleted.Count -eq 1
}
Reset-P5Submission
Enable-P5SyntheticTransport
$script:P5Payload.attributes = [pscustomobject]@{ text = 'ordinary old-card text' }
[void](Send-DaemonCardPayload -SessionId $script:P5SessionId -Entry $script:P5Entry -Headers @{})
Test-That 'old text-only payloads still deliver unchanged without creating attachment storage' {
    $script:P5Console.Count -eq 1 -and $script:P5Console[0] -ceq 'ordinary old-card text' -and
        $script:P5Entry.Driver -eq 'human' -and $script:P5Downloads.Count -eq 0 -and
        -not (Test-Path -LiteralPath (Get-BridgeAttachmentRoot -NoCreate))
}
$expectedChecks = if ($IsWindows) { 41 } else { 33 }
if ($script:P5Checks -ne $expectedChecks) { throw "Expected $expectedChecks attachment checks, observed $($script:P5Checks)." }
Write-Host "P5 attachment privacy: $($script:P5Checks) checks passed; no fixture child or native client was launched."
