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
    param([Parameter(Mandatory)][string]$Root, [string[]]$RelativePaths = @())
    foreach ($relative in @('') + $RelativePaths) {
        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') {
            throw 'A payload boundary must remain within its installation root.'
        }
        $path = $Root
        $components = @('') + @($relative -split '[\\/]' | Where-Object { $_ })
        $item = $null
        foreach ($component in $components) {
            if ($component) { $path = Join-Path $path $component }
            $item = $null
            try { $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop }
            catch [Management.Automation.ItemNotFoundException] { continue }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "A linked installation payload was preserved before access: $path"
            }
        }
        if ($relative -and $item -and $item.PSIsContainer) {
            foreach ($child in Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop) {
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw "A linked installation payload was preserved before access: $($child.FullName)"
                }
            }
        }
    }
}

function Read-BridgeInstallRecord {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $record = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable
        if ($record -isnot [Collections.IDictionary]) { throw 'Not an object.' }
        return $record
    }
    catch [IO.FileNotFoundException] { return $null }
    catch [IO.DirectoryNotFoundException] { return $null }
    catch { throw "Installation metadata is unreadable: $Path" }
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
        $pointer = Read-BridgeInstallRecord -Path (Join-Path $EntryDirectory 'bridge-root.json')
        if ($pointer) {
            if (-not $pointer['bridgeHome']) { throw 'The adapter installation pointer has no bridgeHome.' }
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
    Assert-BridgeInstallPayload -Root $BridgeHome -RelativePaths @('installation.json')
    $record = Read-BridgeInstallRecord -Path $metadataPath
    $isolated = [bool]$TargetHome -or -not (Test-BridgeInstallPath $homeRoot $defaultHome) -or
        -not (Test-BridgeInstallPath $BridgeHome $defaultBridge)
    $legacy = (Test-BridgeInstallPath $BridgeHome $defaultBridge) -and
        ((Test-BridgeInstallPath $ConfigPath (Join-Path $defaultBridge 'config.json')) -or
         (Test-BridgeInstallPath $ConfigPath (Join-Path $defaultHome '.copilot\copilot-ha-bridge.config.json')))
    $id = ''
    if ($record) {
        if ($record['schemaVersion'] -ne 1 -or [string]$record['id'] -cnotmatch '^[a-f0-9]{32}$' -or
            -not $record['bridgeHome'] -or -not (Test-BridgeInstallPath ([string]$record['bridgeHome']) $BridgeHome)) {
            throw "Installation metadata does not identify this root: $metadataPath"
        }
        $id = [string]$record['id']
        if (-not $record['home'] -or $record['isolated'] -isnot [bool]) { throw "Installation metadata has invalid roots: $metadataPath" }
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
    [pscustomobject]@{
        Id = $id; Home = $homeRoot; BridgeHome = $BridgeHome; ConfigPath = $ConfigPath
        HooksDir = Join-Path $BridgeHome 'hooks'; MetadataPath = $metadataPath
        RuntimeRoot = if ($legacy) { $env:TEMP } else { Join-Path $BridgeHome 'runtime' }
        CopilotHome = $roots.copilotHome; ClaudeHome = $roots.claudeHome; CodexHome = $roots.codexHome
        DesktopConfig = $desktop; LocalAppData = $localAppData; PublicRoot = $publicRoot
        Isolated = $isolated; Legacy = $legacy; LegacyLayout = $legacyLayout
        Recorded = [bool]$record; ExplicitConfig = $explicitConfig
        TaskName = if ($id) { "AgentBridgeDaemon_$id" } else { 'AgentBridgeDaemon' }
        LaunchAgentLabel = if ($id) { "com.agent-ha-bridge.daemon.$id" } else { 'com.agent-ha-bridge.daemon' }
        TestRegistryId = if ($record -and $record['testRegistryId']) { [string]$record['testRegistryId'] } else { '' }
    }
}

function Get-BridgeInstallContext {
    $current = Get-Variable -Name BridgeInstallContext -Scope Script -ErrorAction SilentlyContinue
    if ($current -and $current.Value) { return $current.Value }
    Resolve-BridgeInstallContext
}

function Get-BridgeRuntimeRoot {
    param($Context = (Get-BridgeInstallContext))
    if ($Context.Legacy) { return $env:TEMP }
    $Context.RuntimeRoot
}

function Get-BridgeRuntimePath {
    param([Parameter(Mandatory)][string]$Name, $Context = (Get-BridgeInstallContext))
    if ([IO.Path]::IsPathRooted($Name) -or $Name -match '(^|[\\/])\.\.([\\/]|$)') {
        throw 'A runtime filename must stay within its installation.'
    }
    Join-Path (Get-BridgeRuntimeRoot -Context $Context) $Name
}

function Initialize-BridgeInstallIdentity {
    param([Parameter(Mandatory)]$Context, [string]$TestRegistryId, [switch]$LegacyLayout)
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
    $path = Join-Path $Directory 'bridge-root.json'
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
    $config = Read-BridgeInstallRecord -Path $Context.ConfigPath
    if (-not $config -or -not $config.Contains('clients') -or @($config['clients']) -notcontains $Client) {
        throw "The $Client client is not selected; automatic repair did not change its adapter."
    }
}
