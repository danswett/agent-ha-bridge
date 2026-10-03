function ConvertTo-BridgeInstallPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "An installation path must be absolute: $Path" }
    [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Path))
}

function Test-BridgeInstallPath {
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    [string]::Equals((ConvertTo-BridgeInstallPath $Left), (ConvertTo-BridgeInstallPath $Right), $comparison)
}

function Test-BridgeInstallDescendant {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    (ConvertTo-BridgeInstallPath $Path).StartsWith(
        (ConvertTo-BridgeInstallPath $Root) + [IO.Path]::DirectorySeparatorChar, $comparison)
}

function Assert-BridgeInstallPayload {
    param(
        [Parameter(Mandatory)][string]$Root, [string[]]$RelativePaths = @(),
        [switch]$CheckAncestors, [switch]$PathComponentsOnly
    )
    if ($CheckAncestors) {
        $ancestors = [Collections.Generic.Stack[string]]::new()
        $ancestor = Split-Path -Parent (ConvertTo-BridgeInstallPath $Root)
        while ($ancestor) {
            $ancestors.Push($ancestor)
            $ancestor = Split-Path -Parent $ancestor
        }
        while ($ancestors.Count) { Assert-BridgeInstallPayload -Root $ancestors.Pop() }
    }
    $inspected = $null
    if ($PathComponentsOnly) {
        $inspected = [Collections.Generic.HashSet[string]]::new(
            $(if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }))
    }
    foreach ($relative in @('') + $RelativePaths) {
        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') {
            throw 'A payload boundary must remain within its installation root.'
        }
        $path = $Root
        $components = @('') + @($relative -split '[\\/]' | Where-Object { $_ })
        $item = $null
        foreach ($component in $components) {
            if ($component) { $path = Join-Path $path $component }
            if ($PathComponentsOnly -and -not $inspected.Add($path)) { continue }
            $item = $null
            try { $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop }
            catch [Management.Automation.ItemNotFoundException] { continue }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "A linked installation payload was preserved before access: $path"
            }
        }
        if (-not $PathComponentsOnly -and $relative -and $item -and $item.PSIsContainer) {
            foreach ($child in Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop) {
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw "A linked installation payload was preserved before access: $($child.FullName)"
                }
            }
        }
    }
}

function Test-BridgeTestExecution {
    if ($env:AGENT_HA_BRIDGE_OFFLINE_TEST -eq '1' -or $env:AGENT_HA_BRIDGE_TEST_ROOT -or
        $env:AGENT_HA_BRIDGE_TEST_ID) { return $true }
    foreach ($frame in Get-PSCallStack) {
        if ([string]$frame.ScriptName -match '[\\/]test-[^\\/]+\.ps1$') { return $true }
    }
    $false
}

function Stop-BridgeTestWrite {
    param([Parameter(Mandatory)][string]$Reason, [Exception]$Cause)
    $errorMessage = "Test fixture boundary rejected access: $Reason Run tests through tests\run-tests.ps1."
    $exception = if ($Cause) { [InvalidOperationException]::new($errorMessage, $Cause) }
        else { [InvalidOperationException]::new($errorMessage) }
    $exception.Data['BridgeTestWriteBlocked'] = $true
    throw $exception
}

function Get-BridgeTestSandbox {
    param([AllowNull()][AllowEmptyString()][string]$Root)
    try {
        if ([string]::IsNullOrWhiteSpace($Root) -or $Root -match '^(\\\\|//)|(^|[\\/])\.\.?([\\/]|$)') {
            throw 'The fixture root is missing or is not a local canonical path.'
        }
        $fullRoot = ConvertTo-BridgeInstallPath $Root
        $leaf = Split-Path $fullRoot -Leaf
        if ($leaf -cmatch '^sandbox-([a-f0-9]{32})$') { $sandboxId = $Matches[1] }
        else { throw 'The root was not allocated as a test sandbox.' }
        Assert-BridgeInstallPayload -Root $fullRoot -CheckAncestors
        if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) { throw 'The sandbox directory is missing.' }
        $marker = Join-Path $fullRoot '.bridge-test-sandbox.json'
        Assert-BridgeInstallPayload -Root $marker
        if ((Get-Item -LiteralPath $marker -Force -ErrorAction Stop).Length -gt 16384) {
            throw 'The sandbox identity is not a bounded runner record.'
        }
        $record = [IO.File]::ReadAllText($marker) | ConvertFrom-Json -AsHashtable
        if ($record -isnot [Collections.IDictionary] -or $record['schemaVersion'] -ne 1 -or
            [string]$record['id'] -cne $sandboxId -or
            -not (Test-BridgeInstallPath ([string]$record['root']) $fullRoot) -or
            -not (Test-BridgeInstallPath ([string]$record['parent']) (Split-Path $fullRoot -Parent)) -or
            -not (Test-BridgeInstallPath ([string]$record['home']) (Join-Path $fullRoot 'home'))) {
            throw 'The sandbox identity does not describe this directory.'
        }
        $repository = ConvertTo-BridgeInstallPath ([string]$record['repository'])
        Assert-BridgeInstallPayload -Root $repository -CheckAncestors
        if (-not (Test-Path -LiteralPath $repository -PathType Container)) { throw 'The source checkout is missing.' }
        return $record
    }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked']) { throw }
        Stop-BridgeTestWrite -Reason 'The disposable root could not be verified.' -Cause $_.Exception
    }
}

function Assert-BridgeTestPath {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Path,
        [switch]$AllowRoot,
        [switch]$SourceEntry
    )
    $boundary = Get-BridgeTestSandbox -Root $env:AGENT_HA_BRIDGE_TEST_ROOT
    if ([string]$boundary['id'] -cne [string]$env:AGENT_HA_BRIDGE_TEST_ID) {
        Stop-BridgeTestWrite -Reason 'The child does not carry this sandbox identity.'
    }
    try {
        $fixturePaths = [Collections.Generic.List[string]]::new()
        $sourcePaths = [Collections.Generic.List[string]]::new()
        foreach ($candidate in $Path) {
            if ([string]::IsNullOrWhiteSpace($candidate) -or
                $candidate -match '^(\\\\|//)|(^|[\\/])\.\.?([\\/]|$)|[\x00*?]') {
                throw 'A fixture destination is missing or is not a local canonical path.'
            }
            $fullPath = ConvertTo-BridgeInstallPath $candidate
            if ($IsWindows) {
                $tail = $fullPath.Substring([IO.Path]::GetPathRoot($fullPath).Length)
                if ($tail.Contains(':')) { throw 'A fixture destination cannot address an alternate data stream.' }
                foreach ($component in $tail -split '[\\/]') {
                    if ($component -match '[. ]$|^(CON(IN\$|OUT\$)?|PRN|AUX|NUL|COM[0-9\u00b9\u00b2\u00b3]|LPT[0-9\u00b9\u00b2\u00b3])(\.|$)') {
                        throw 'A fixture destination cannot use a Windows path alias or device name.'
                    }
                }
            }
            $inside = (Test-BridgeInstallDescendant $fullPath $boundary['root']) -or
                ($AllowRoot -and (Test-BridgeInstallPath $fullPath $boundary['root']))
            if ($inside) {
                $relative = [IO.Path]::GetRelativePath($boundary['root'], $fullPath)
                $fixturePaths.Add($(if ($relative -eq '.') { '' } else { $relative }))
            }
            elseif ($SourceEntry -and ((Test-BridgeInstallPath $fullPath $boundary['repository']) -or
                (Test-BridgeInstallDescendant $fullPath $boundary['repository']))) {
                $relative = [IO.Path]::GetRelativePath($boundary['repository'], $fullPath)
                $sourcePaths.Add($(if ($relative -eq '.') { '' } else { $relative }))
            }
            else { throw 'A fixture destination escapes its allocated root.' }
        }
        if ($fixturePaths.Count) {
            Assert-BridgeInstallPayload -Root $boundary['root'] -RelativePaths $fixturePaths.ToArray() -PathComponentsOnly
        }
        if ($sourcePaths.Count) {
            Assert-BridgeInstallPayload -Root $boundary['repository'] -RelativePaths $sourcePaths.ToArray() -PathComponentsOnly
        }
    }
    catch {
        if ($_.Exception.Data['BridgeTestWriteBlocked']) { throw }
        Stop-BridgeTestWrite -Reason 'A fixture path is outside the verified, unlinked boundary.' -Cause $_.Exception
    }
}

function Assert-BridgeTestEnvironment {
    param([switch]$Required)
    if (-not $Required -and -not (Test-BridgeTestExecution)) { return }
    $boundary = Get-BridgeTestSandbox -Root $env:AGENT_HA_BRIDGE_TEST_ROOT
    $paths = [Collections.Generic.List[string]]::new()
    try {
        foreach ($homePath in @($HOME, $env:HOME, $env:USERPROFILE)) {
            if (-not (Test-BridgeInstallPath $homePath $boundary['home'])) {
                throw 'PowerShell HOME, environment HOME and USERPROFILE must identify the synthetic home.'
            }
        }
        foreach ($name in @(
            'HOME', 'USERPROFILE', 'TEMP', 'TMP', 'TMPDIR', 'PUBLIC', 'APPDATA', 'LOCALAPPDATA',
            'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_RUNTIME_DIR',
            'CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'COPILOT_HOME', 'DOTNET_CLI_HOME', 'GIT_CONFIG_GLOBAL',
            'AGENT_HA_BRIDGE_CONFIG'
        )) {
            $value = [Environment]::GetEnvironmentVariable($name)
            if ([string]::IsNullOrWhiteSpace($value)) { throw "The synthetic $name path is missing." }
            $paths.Add($value)
        }
        foreach ($name in @('COPILOT_HA_BRIDGE_CONFIG', 'BRIDGE_CLAUDE_DESKTOP_CONFIG')) {
            $value = [Environment]::GetEnvironmentVariable($name)
            if ($value) { $paths.Add($value) }
        }
        $paths.Add([IO.Path]::GetTempPath())
        if ($IsWindows -and -not (Test-BridgeInstallPath ($env:HOMEDRIVE + $env:HOMEPATH) $boundary['home'])) {
            throw 'The Windows home drive/path do not identify the synthetic home.'
        }
    }
    catch {
        Stop-BridgeTestWrite -Reason 'The effective child environment is not contained.' -Cause $_.Exception
    }
    Assert-BridgeTestPath -Path $paths.ToArray()
}

function Assert-BridgeTestInstallContext {
    param([Parameter(Mandatory)]$Context)
    if (-not (Test-BridgeTestExecution)) { return }
    Assert-BridgeTestEnvironment
    foreach ($name in @('Legacy', 'Isolated', 'Recorded', 'ExplicitConfig', 'LegacyLayout')) {
        $value = if ($Context -is [Collections.IDictionary]) { $Context[$name] }
            elseif ($Context.PSObject.Properties[$name]) { $Context.$name }
            else { $null }
        if ($value -isnot [bool]) { Stop-BridgeTestWrite -Reason "The effective installation context has no verified $name flag." }
    }
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($name in @(
        'Home', 'BridgeHome', 'ConfigPath', 'HooksDir', 'MetadataPath', 'RuntimeRoot',
        'CopilotHome', 'ClaudeHome', 'CodexHome', 'DesktopConfig', 'LocalAppData', 'PublicRoot'
    )) {
        $value = if ($Context -is [Collections.IDictionary]) { $Context[$name] }
            elseif ($Context.PSObject.Properties[$name]) { $Context.$name }
            else { $null }
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
            Stop-BridgeTestWrite -Reason "The effective installation context has no verified $name."
        }
        $paths.Add($value)
    }
    Assert-BridgeTestPath -Path $paths.ToArray()
}

function Read-BridgeInstallRecord {
    param([Parameter(Mandatory)][string]$Path, [switch]$SourceEntry)
    if (Test-BridgeTestExecution) {
        if ($SourceEntry -and (Split-Path $Path -Leaf) -notin @('bridge-root.json', 'installation.json')) {
            Stop-BridgeTestWrite -Reason 'Only a source entry pointer may be read outside the fixture.'
        }
        Assert-BridgeTestPath -Path $Path -SourceEntry:$SourceEntry
    }
    try {
        $record = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable
        if ($record -isnot [Collections.IDictionary]) { throw 'Not an object.' }
        return $record
    }
    catch [IO.FileNotFoundException] { return $null }
    catch [IO.DirectoryNotFoundException] { return $null }
    catch {
        if (Test-BridgeTestExecution) {
            Stop-BridgeTestWrite -Reason "Installation metadata is unreadable: $Path" -Cause $_.Exception
        }
        throw "Installation metadata is unreadable: $Path"
    }
}

function Resolve-BridgeInstallContext {
    <# Explicit targets and installed entry points cannot fall through to a different HOME.
       Unbound, pre-metadata default installations retain their legacy runtime paths. #>
    param(
        [string]$TargetHome,
        [string]$BridgeHome,
        [string]$ConfigPath,
        [string]$EntryDirectory
    )
    Assert-BridgeTestEnvironment
    if (Test-BridgeTestExecution) {
        foreach ($explicitPath in @($TargetHome, $BridgeHome, $ConfigPath)) {
            if ($explicitPath) { Assert-BridgeTestPath -Path $explicitPath }
        }
        if ($EntryDirectory) { Assert-BridgeTestPath -Path $EntryDirectory -SourceEntry }
    }
    $defaultHome = ConvertTo-BridgeInstallPath $HOME
    $defaultBridge = Join-Path $defaultHome '.agent-ha-bridge'
    $explicitConfig = -not [string]::IsNullOrWhiteSpace($ConfigPath)
    $homeRoot = ''
    if ($TargetHome) {
        $homeRoot = ConvertTo-BridgeInstallPath $TargetHome
        if (-not $BridgeHome) { $BridgeHome = Join-Path $homeRoot '.agent-ha-bridge' }
        elseif (-not (Test-BridgeInstallDescendant $BridgeHome $homeRoot)) {
            throw 'InstallRoot must remain within TargetHome.'
        }
        if (-not $ConfigPath) { $ConfigPath = Join-Path $BridgeHome 'config.json' }
    }
    elseif (-not $BridgeHome -and $EntryDirectory) {
        $pointer = Read-BridgeInstallRecord -Path (Join-Path $EntryDirectory 'bridge-root.json') -SourceEntry
        if ($pointer) {
            if (-not $pointer['bridgeHome']) {
                if (Test-BridgeTestExecution) { Stop-BridgeTestWrite -Reason 'The adapter installation pointer has no bridgeHome.' }
                throw 'The adapter installation pointer has no bridgeHome.'
            }
            $BridgeHome = ConvertTo-BridgeInstallPath ([string]$pointer['bridgeHome'])
        }
        elseif ([IO.File]::Exists((Join-Path $EntryDirectory 'installation.json'))) {
            $BridgeHome = $EntryDirectory
        }
        else {
            $parent = Split-Path $EntryDirectory -Parent
            if ((Split-Path $EntryDirectory -Leaf) -in @('hooks', 'bin', 'installer') -and
                ((Split-Path $parent -Leaf) -eq '.agent-ha-bridge' -or
                 [IO.File]::Exists((Join-Path $parent 'installation.json')))) {
                $BridgeHome = $parent
            }
            elseif ((Split-Path $EntryDirectory -Leaf) -in @('hooks', 'bin', 'installer') -and
                [IO.File]::Exists((Join-Path $parent 'installer\install.ps1'))) {
                throw "Installation metadata is missing for this custom root: $parent"
            }
        }
    }
    if (-not $BridgeHome) {
        if (-not $ConfigPath -and $env:AGENT_HA_BRIDGE_CONFIG) {
            $ConfigPath = $env:AGENT_HA_BRIDGE_CONFIG
            $explicitConfig = $true
        }
        if (-not $ConfigPath -and -not [IO.File]::Exists((Join-Path $defaultBridge 'config.json'))) {
            if ($env:COPILOT_HA_BRIDGE_CONFIG) {
                $ConfigPath = $env:COPILOT_HA_BRIDGE_CONFIG
                $explicitConfig = $true
            }
            elseif ([IO.File]::Exists((Join-Path $defaultHome '.copilot\copilot-ha-bridge.config.json'))) {
                $ConfigPath = Join-Path $defaultHome '.copilot\copilot-ha-bridge.config.json'
            }
        }
        if ($ConfigPath) {
            $ConfigPath = ConvertTo-BridgeInstallPath $ConfigPath
            $BridgeHome = if (Test-BridgeInstallPath $ConfigPath (Join-Path $defaultHome '.copilot\copilot-ha-bridge.config.json')) {
                $defaultBridge
            } else { Split-Path $ConfigPath -Parent }
        }
        else { $BridgeHome = $defaultBridge }
    }
    $BridgeHome = ConvertTo-BridgeInstallPath $BridgeHome
    if (-not $homeRoot) { $homeRoot = Split-Path $BridgeHome -Parent }
    if (-not $ConfigPath) { $ConfigPath = Join-Path $BridgeHome 'config.json' }
    $ConfigPath = ConvertTo-BridgeInstallPath $ConfigPath
    $metadataPath = Join-Path $BridgeHome 'installation.json'
    if (Test-BridgeTestExecution) {
        Assert-BridgeTestPath -Path @($homeRoot, $BridgeHome, $ConfigPath, $metadataPath)
    }
    Assert-BridgeInstallPayload -Root $BridgeHome -RelativePaths @('installation.json')
    $record = Read-BridgeInstallRecord -Path $metadataPath
    $isolated = [bool]$TargetHome -or -not (Test-BridgeInstallPath $homeRoot $defaultHome) -or
        -not (Test-BridgeInstallPath $BridgeHome $defaultBridge)
    $legacy = (Test-BridgeInstallPath $BridgeHome $defaultBridge) -and
        ((Test-BridgeInstallPath $ConfigPath (Join-Path $defaultBridge 'config.json')) -or
         (Test-BridgeInstallPath $ConfigPath (Join-Path $defaultHome '.copilot\copilot-ha-bridge.config.json')))
    $id = ''
    if ($record) {
        if (Test-BridgeTestExecution) {
            foreach ($key in @('home', 'bridgeHome', 'configPath', 'copilotHome', 'claudeHome', 'codexHome', 'desktopConfig', 'legacyCopilotHome')) {
                if ($record[$key]) { Assert-BridgeTestPath -Path ([string]$record[$key]) }
            }
        }
        if ($record['schemaVersion'] -ne 1 -or [string]$record['id'] -cnotmatch '^[a-f0-9]{32}$' -or
            -not $record['bridgeHome'] -or -not (Test-BridgeInstallPath ([string]$record['bridgeHome']) $BridgeHome)) {
            if (Test-BridgeTestExecution) { Stop-BridgeTestWrite -Reason "Installation metadata does not identify this root: $metadataPath" }
            throw "Installation metadata does not identify this root: $metadataPath"
        }
        $id = [string]$record['id']
        if (-not $record['home'] -or $record['isolated'] -isnot [bool]) {
            if (Test-BridgeTestExecution) { Stop-BridgeTestWrite -Reason "Installation metadata has invalid roots: $metadataPath" }
            throw "Installation metadata has invalid roots: $metadataPath"
        }
        if ($TargetHome -and -not (Test-BridgeInstallPath $TargetHome ([string]$record['home']))) {
            throw 'TargetHome does not match the recorded installation.'
        }
        $homeRoot = ConvertTo-BridgeInstallPath ([string]$record['home'])
        $isolated = $isolated -or [bool]$record['isolated']
        if ($record['configPath']) { $ConfigPath = ConvertTo-BridgeInstallPath ([string]$record['configPath']) }
        $legacy = $false
    }
    elseif (-not $legacy) {
        $key = if ($IsWindows) { $BridgeHome.ToLowerInvariant() } else { $BridgeHome }
        $id = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key))).Substring(0, 32).ToLowerInvariant()
    }
    $roots = @{}
    foreach ($client in @(
        @{ Key = 'copilotHome'; Environment = 'COPILOT_HOME'; Directory = '.copilot' },
        @{ Key = 'claudeHome'; Environment = 'CLAUDE_CONFIG_DIR'; Directory = '.claude' },
        @{ Key = 'codexHome'; Environment = 'CODEX_HOME'; Directory = '.codex' }
    )) {
        $value = if ($record -and $record[$client.Key]) { [string]$record[$client.Key] }
            elseif (-not $isolated -and [Environment]::GetEnvironmentVariable($client.Environment)) {
                [Environment]::GetEnvironmentVariable($client.Environment)
            } else { Join-Path $homeRoot $client.Directory }
        $roots[$client.Key] = ConvertTo-BridgeInstallPath $value
        if ($isolated -and -not (Test-BridgeInstallDescendant $value $homeRoot)) {
            throw "An isolated installation cannot use a client root outside TargetHome: $value"
        }
    }
    if ($isolated -and -not (Test-BridgeInstallDescendant $ConfigPath $homeRoot)) {
        throw 'An isolated installation cannot use an external configuration.'
    }
    $legacyLayout = $legacy -and
        (Test-BridgeInstallPath $ConfigPath (Join-Path $roots.copilotHome 'copilot-ha-bridge.config.json'))
    if ($record -and $record['legacyCopilotHome']) {
        if (-not (Test-BridgeInstallPath ([string]$record['legacyCopilotHome']) $roots.copilotHome)) {
            throw 'The recorded legacy layout does not belong to this client root.'
        }
        $legacyLayout = $true
    }
    $localAppData = if ($isolated) { Join-Path $homeRoot 'AppData\Local' } else { [string]$env:LOCALAPPDATA }
    $publicRoot = if ($isolated) { Join-Path $homeRoot 'Public' } else { [string]$env:PUBLIC }
    $desktop = if ($record -and $record['desktopConfig']) { [string]$record['desktopConfig'] }
        elseif (-not $isolated -and $env:BRIDGE_CLAUDE_DESKTOP_CONFIG) { $env:BRIDGE_CLAUDE_DESKTOP_CONFIG }
        elseif ($IsWindows) {
            $roaming = if ($isolated) { Join-Path $homeRoot 'AppData\Roaming' } else { $env:APPDATA }
            Join-Path $roaming 'Claude\claude_desktop_config.json'
        } else { Join-Path $homeRoot 'Library\Application Support\Claude\claude_desktop_config.json' }
    $desktop = ConvertTo-BridgeInstallPath $desktop
    if ($isolated -and -not (Test-BridgeInstallDescendant $desktop $homeRoot)) {
        throw 'An isolated installation cannot use an external Desktop configuration.'
    }
    $resolvedContext = [pscustomobject]@{
        Id = $id; Home = $homeRoot; BridgeHome = $BridgeHome; ConfigPath = $ConfigPath
        HooksDir = Join-Path $BridgeHome 'hooks'; MetadataPath = $metadataPath
        RuntimeRoot = if ($legacy) { $env:TEMP } else { Join-Path $BridgeHome 'runtime' }
        CopilotHome = $roots.copilotHome; ClaudeHome = $roots.claudeHome; CodexHome = $roots.codexHome
        DesktopConfig = $desktop; LocalAppData = $localAppData; PublicRoot = $publicRoot
        Isolated = $isolated; Legacy = $legacy; LegacyLayout = $legacyLayout
        Recorded = [bool]$record; ExplicitConfig = $explicitConfig
        TaskName = if ($id) { "AgentBridgeDaemon_$id" } else { 'AgentBridgeDaemon' }
        DevBoxTaskName = if ($id) { "AgentBridgeDevBoxKeepAwake_$id" } else { 'AgentBridgeDevBoxKeepAwake' }
        LaunchAgentLabel = if ($id) { "com.agent-ha-bridge.daemon.$id" } else { 'com.agent-ha-bridge.daemon' }
        TestRegistryId = if ($record -and $record['testRegistryId']) { [string]$record['testRegistryId'] } else { '' }
    }
    Assert-BridgeTestInstallContext -Context $resolvedContext
    $resolvedContext
}

function Get-BridgeInstallContext {
    $current = Get-Variable -Name BridgeInstallContext -Scope Script -ErrorAction SilentlyContinue
    if ($current -and $current.Value) {
        Assert-BridgeTestInstallContext -Context $current.Value
        return $current.Value
    }
    Resolve-BridgeInstallContext
}

function Get-BridgeRuntimeRoot {
    param($Context = (Get-BridgeInstallContext))
    Assert-BridgeTestInstallContext -Context $Context
    if ($Context.Legacy) { return $env:TEMP }
    $Context.RuntimeRoot
}

function Get-BridgeRuntimePath {
    param([Parameter(Mandatory)][string]$Name, $Context = (Get-BridgeInstallContext))
    if ([IO.Path]::IsPathRooted($Name) -or $Name -match '(^|[\\/])\.\.([\\/]|$)') {
        if (Test-BridgeTestExecution) { Stop-BridgeTestWrite -Reason 'A runtime filename escapes its installation.' }
        throw 'A runtime filename must stay within its installation.'
    }
    $runtimePath = Join-Path (Get-BridgeRuntimeRoot -Context $Context) $Name
    if (Test-BridgeTestExecution) { Assert-BridgeTestPath -Path $runtimePath }
    $runtimePath
}

function Initialize-BridgeInstallIdentity {
    param([Parameter(Mandatory)]$Context, [string]$TestRegistryId, [switch]$LegacyLayout)
    Assert-BridgeTestInstallContext -Context $Context
    if ($Context.Recorded) {
        if ($TestRegistryId -and $Context.TestRegistryId -ne $TestRegistryId) {
            throw 'The test registry namespace does not match this installation.'
        }
        [void][IO.Directory]::CreateDirectory($Context.RuntimeRoot)
        return $Context
    }
    $record = [ordered]@{
        schemaVersion = 1; id = $(if ($Context.Id) { $Context.Id } else { [guid]::NewGuid().ToString('N') }); bridgeHome = $Context.BridgeHome
        home = $Context.Home; configPath = $Context.ConfigPath; isolated = $Context.Isolated
        copilotHome = $Context.CopilotHome; claudeHome = $Context.ClaudeHome; codexHome = $Context.CodexHome
        desktopConfig = $Context.DesktopConfig; testRegistryId = $TestRegistryId
    }
    if ($LegacyLayout) {
        if (-not (Test-BridgeInstallPath $Context.BridgeHome (Join-Path $Context.Home '.agent-ha-bridge'))) {
            throw 'Only the canonical replacement root can own the pre-rename layout.'
        }
        $record['legacyCopilotHome'] = $Context.CopilotHome
    }
    Write-BridgeSecretFile -Path $Context.MetadataPath -Content ($record | ConvertTo-Json -Depth 5)
    $resolved = Resolve-BridgeInstallContext -BridgeHome $Context.BridgeHome
    [void][IO.Directory]::CreateDirectory($resolved.RuntimeRoot)
    $resolved
}

function Set-BridgeAdapterRoot {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)]$Context)
    Assert-BridgeTestInstallContext -Context $Context
    $path = Join-Path $Directory 'bridge-root.json'
    if (Test-BridgeTestExecution) { Assert-BridgeTestPath -Path @($Directory, $path) }
    $existing = Read-BridgeInstallRecord -Path $path
    if ($existing -and (-not $existing['bridgeHome'] -or
        -not (Test-BridgeInstallPath ([string]$existing['bridgeHome']) $Context.BridgeHome))) {
        throw 'The adapter directory is owned by another installation.'
    }
    [void][IO.Directory]::CreateDirectory($Directory)
    @{ bridgeHome = $Context.BridgeHome } | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8
}

function Test-BridgeAdapterRoot {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)]$Context)
    Assert-BridgeTestInstallContext -Context $Context
    $pointer = Read-BridgeInstallRecord -Path (Join-Path $Directory 'bridge-root.json')
    if (-not $pointer) { return $true }
    $pointer['bridgeHome'] -and (Test-BridgeInstallPath ([string]$pointer['bridgeHome']) $Context.BridgeHome)
}

function Get-BridgeSelectedClients {
    $context = Get-BridgeInstallContext
    if ($context.Recorded) {
        $config = Read-BridgeInstallRecord -Path $context.ConfigPath
        if (-not $config) { throw 'The recorded installation configuration is missing; client discovery and repair were not authorized.' }
        if (-not $config.Contains('clients')) { return $null }
        $clients = @($config['clients'])
    }
    else {
        $config = Get-Variable -Name BridgeUserConfig -Scope Script -ErrorAction SilentlyContinue
        if (-not $config -or -not $config.Value -or -not $config.Value.PSObject.Properties['clients']) { return $null }
        $clients = @($config.Value.clients)
    }
    foreach ($client in $clients) {
        if ($client -isnot [string] -or $client -notin @('copilot', 'claude', 'codex', 'mcp')) {
            throw 'The configured client selection is invalid; no additional clients were enrolled.'
        }
    }
    ,$clients
}

function Remove-BridgeCopilotHookEntries {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)]$Context)
    if (-not $Config.ContainsKey('hooks')) { return $Config }
    $paths = @('route-ask-user-v3.ps1', 'notify-agent-response.ps1', 'notify-home-assistant.ps1') |
        ForEach-Object { Join-Path $Context.HooksDir $_ }
    foreach ($eventName in @($Config.hooks.Keys)) {
        $kept = @()
        foreach ($entry in @($Config.hooks[$eventName])) {
            $owned = $false
            foreach ($path in $paths) {
                if ($entry['powershell'] -eq "& '$path'" -or
                    ($entry['bash'] -and [string]$entry['bash'] -match ("^'[^']*/pwsh' -NoProfile -NonInteractive -File '" + [regex]::Escape($path) + "'$"))) {
                    $owned = $true
                }
                if ($entry['exec'] -and $entry['args'] -and @($entry['args']) -contains $path) {
                    foreach ($nativeName in @('agent-bridge-hook', 'agent-bridge-hook.exe')) {
                        if ([string]$entry['exec'] -eq (Join-Path $Context.BridgeHome "bin\$nativeName")) { $owned = $true }
                    }
                }
            }
            if (-not $owned) { $kept += $entry }
        }
        if ($kept.Count) { $Config.hooks[$eventName] = $kept }
        else { [void]$Config.hooks.Remove($eventName) }
    }
    if ($Config.hooks.Count -eq 0) { [void]$Config.Remove('hooks') }
    $Config
}

function Test-BridgeUninstallEntryOwnership {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Context, [switch]$Legacy)
    $entry = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
    if (-not $entry.PSObject.Properties['InstallLocation'] -or
        -not [IO.Path]::IsPathFullyQualified([string]$entry.InstallLocation)) { return $false }
    if (Test-BridgeInstallPath ([string]$entry.InstallLocation) $Context.BridgeHome) { return $true }
    $Legacy -and (Test-BridgeInstallPath ([string]$entry.InstallLocation) (Join-Path $Context.CopilotHome 'copilot-ha-bridge'))
}

function Set-BridgeAdapterEnrollment {
    param([Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][ValidateSet('claude', 'codex', 'mcp')][string]$Client,
        [Parameter(Mandatory)][bool]$Installed, [switch]$RepairOnly, [switch]$KeepSelection,
        [switch]$KeepAdapterRecord)
    Assert-BridgeTestInstallContext -Context $Context
    if (-not $KeepSelection) {
        $config = Read-BridgeInstallRecord -Path $Context.ConfigPath
        if (-not $config -and $Installed) { throw 'The selected bridge configuration is missing; the adapter cannot be enrolled.' }
        if ($config) {
            $clients = @(if ($config.Contains('clients')) { $config['clients'] })
            if ($RepairOnly -and $clients -notcontains $Client) { throw "The $Client client is no longer selected; automatic setup cannot enroll it." }
            $updated = if ($Installed) { @($clients + $Client | Select-Object -Unique) }
                else { @($clients | Where-Object { $_ -ne $Client }) }
            if (($updated -join ',') -cne ($clients -join ',')) {
                $config['clients'] = $updated
                Write-BridgeSecretFile -Path $Context.ConfigPath -Content ($config | ConvertTo-Json -Depth 20)
            }

        }
    }
    if ($KeepAdapterRecord) { return }
    $record = Read-BridgeInstallRecord -Path $Context.MetadataPath
    if (-not $record) { return }
    if ([string]$record['id'] -cne $Context.Id) { throw 'Installation ownership changed while recording adapter enrollment.' }
    $adapters = @(if ($record.Contains('adapters')) { $record['adapters'] })
    $record['adapters'] = if ($Installed) { @($adapters + $Client | Select-Object -Unique) }
        else { @($adapters | Where-Object { $_ -ne $Client }) }
    Write-BridgeSecretFile -Path $Context.MetadataPath -Content ($record | ConvertTo-Json -Depth 8)
}

function Assert-BridgeAdapterSelection {
    param([Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][ValidateSet('claude', 'codex', 'mcp')][string]$Client)
    Assert-BridgeTestInstallContext -Context $Context
    $config = Read-BridgeInstallRecord -Path $Context.ConfigPath
    if (-not $config -or -not $config.Contains('clients') -or @($config['clients']) -notcontains $Client) {
        throw "The $Client client is not selected; automatic repair did not change its adapter."
    }
}
