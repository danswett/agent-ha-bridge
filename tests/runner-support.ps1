#Requires -Version 7.0

$script:BridgeTestRepository = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $script:BridgeTestRepository 'hooks\bridge-install-context.ps1')

function Get-BridgeTestSuitePath {
    param([Parameter(Mandatory)][string]$Repository)

    $root = Get-Item -LiteralPath $Repository -Force -ErrorAction Stop
    if (-not $root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The suite repository must be a directory, not a symbolic link or junction.'
    }
    $excluded = @(
        '.git', 'node_modules', 'vendor', '.venv', 'venv',
        'fixtures', '__fixtures__', 'test-results', 'TestResults', 'coverage', 'dist'
    )
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($root.FullName)
    while ($pending.Count) {
        foreach ($entry in Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop) {
            # Do not recurse and filter afterwards: even enumerating a linked or
            # dependency tree can leave the checkout or loop back into it.
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($entry.PSIsContainer) {
                if ($entry.Name -in $excluded -or
                    (Test-Path -LiteralPath (Join-Path $entry.FullName '.bridge-test-results') -PathType Leaf)) { continue }
                $pending.Push($entry.FullName)
            }
            elseif ($entry.Name -like 'test-*.ps1') {
                [IO.Path]::GetRelativePath($root.FullName, $entry.FullName).Replace('/', '\')
            }
        }
    }
}

function Get-BridgeTestSuite {
    param(
        [ValidateSet('Offline', 'Host', 'Platform', 'Integration')][string]$Group = 'Offline',
        [string[]]$Suite = @(),
        [string]$Repository = $script:BridgeTestRepository
    )

    $Repository = [IO.Path]::GetFullPath($Repository)
    $discovered = @(Get-BridgeTestSuitePath -Repository $Repository)
    $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path (Join-Path $Repository 'tests') 'suites.psd1')
    $groups = @('Offline', 'Host', 'Platform', 'Integration')
    if (@(Compare-Object $groups @($manifest.Keys)).Count) { throw 'The suite manifest must declare exactly Offline, Host, Platform and Integration.' }
    $declared = @{}
    foreach ($category in $manifest.Keys) {
        foreach ($relative in $manifest[$category]) {
            $key = ([string]$relative).Replace('/', '\')
            if ($key -match '(^\\|:|(^|\\)\.\.?($|\\)|\\\\)' -or $key -notmatch '(^|\\)test-[^\\]+\.ps1$') {
                throw "Suite paths must be canonical repository-relative test-*.ps1 paths: $relative"
            }
            if ($declared.ContainsKey($key)) { throw "Suite declared twice: $key" }
            $declared[$key] = $category
        }
    }
    $difference = @($declared.Keys | Where-Object { $_ -notin $discovered }) +
        @($discovered | Where-Object { -not $declared.ContainsKey($_) })
    if ($difference.Count) {
        throw "Update tests\suites.psd1; suite inventory differs: $(($difference | Sort-Object) -join ', ')"
    }

    $selected = @($declared.Keys | Where-Object { $declared[$_] -eq $Group })
    if ($Suite.Count) {
        $selected = @(
            foreach ($requested in $Suite) {
                $key = $requested.Replace('/', '\')
                $matches = @($selected | Where-Object { $_ -eq $key -or ($_ -split '\\')[-1] -eq $key })
                if ($matches.Count -ne 1) { throw "Expected one $Group suite named '$requested'; use -List to see the selection." }
                $matches[0]
            }
        )
        if (@($selected | Select-Object -Unique).Count -ne $selected.Count) { throw 'A suite was selected more than once.' }
    }
    foreach ($relative in ($selected | Sort-Object)) {
        [pscustomobject]@{
            Suite = $relative
            Group = $Group
            Path = Join-Path $Repository ($relative.Replace('\', [IO.Path]::DirectorySeparatorChar))
        }
    }
}

function Assert-BridgeHostedTest {
    param([switch]$AllowHostTests)

    if (-not $AllowHostTests -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
        throw 'Host/platform suites require -AllowHostTests on a disposable GitHub-hosted CI runner. Never run them on a developer or self-hosted machine.'
    }
}

function New-BridgeTestDefaultResultsDirectory {
    param([string]$PlatformTempBase = [IO.Path]::GetTempPath())

    if (Test-BridgeTestExecution) { Assert-BridgeTestEnvironment }
    if ([string]::IsNullOrWhiteSpace($PlatformTempBase) -or
        -not [IO.Path]::IsPathFullyQualified($PlatformTempBase) -or $PlatformTempBase -match '^(\\\\|//)') {
        throw 'The platform default temporary base must be an existing local absolute directory.'
    }

    # /var can be an ancestor alias on macOS. Resolve only the existing default
    # base; explicit results paths still reach the original link-refusing guard.
    $resolved = [IO.Path]::GetPathRoot($PlatformTempBase)
    $pending = [Collections.Generic.Queue[string]]::new(
        [string[]]@($PlatformTempBase.Substring($resolved.Length) -split '[\\/]' | Where-Object { $_ }))
    $links = 0
    while ($pending.Count) {
        $part = $pending.Dequeue()
        if ($part -eq '.') { continue }
        if ($part -eq '..') {
            $parent = Split-Path -Parent $resolved
            if (-not $parent) { throw 'The platform default temporary base traverses above its filesystem root.' }
            $resolved = $parent
            continue
        }

        try { $entry = Get-Item -LiteralPath (Join-Path $resolved $part) -Force -ErrorAction Stop }
        catch [Management.Automation.ItemNotFoundException] {
            throw "The platform default temporary base is missing or unreadable: $PlatformTempBase"
        }
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $kind = $entry.PSObject.Properties['LinkType']
            $targetProperty = $entry.PSObject.Properties['Target']
            if (-not $entry.PSIsContainer -or -not $kind -or
                $kind.Value -notin @('SymbolicLink', 'Junction') -or -not $targetProperty) {
                throw 'The platform default temporary base has an unsupported directory link.'
            }
            $targets = @($targetProperty.Value)
            if ($targets.Count -ne 1) { throw 'The platform default temporary base has an ambiguous link target.' }
            $target = [string]$targets[0]
            $links++
            if ($links -gt 40) { throw 'The platform default temporary base has a cycle or exceeds 40 link resolutions.' }
            if ([string]::IsNullOrWhiteSpace($target) -or $target -match '^(\\\\|//)') {
                throw 'The platform default temporary base has an unsafe link target.'
            }
            if ([IO.Path]::IsPathRooted($target)) {
                if (-not [IO.Path]::IsPathFullyQualified($target)) {
                    throw 'The platform default temporary base has an ambiguous rooted link target.'
                }
                $resolved = [IO.Path]::GetPathRoot($target)
                $target = $target.Substring($resolved.Length)
            }
            $parts = [string[]]@($target -split '[\\/]' | Where-Object { $_ })
            $pending = [Collections.Generic.Queue[string]]::new([string[]]($parts + @($pending.ToArray())))
            continue
        }
        if (-not $entry.PSIsContainer) {
            throw "The platform default temporary base is not a directory: $PlatformTempBase"
        }
        $resolved = $entry.FullName
    }

    $physicalBase = [IO.Path]::TrimEndingDirectorySeparator($resolved)
    if (-not [IO.Directory]::Exists($physicalBase)) {
        throw "The platform default temporary base is not an existing directory: $PlatformTempBase"
    }
    Assert-BridgeInstallPayload -Root $physicalBase -CheckAncestors
    $directory = New-BridgeTestResultsDirectory -Directory (
        Join-Path $physicalBase ("bridge-tests-" + [guid]::NewGuid().ToString('N')))
    [pscustomobject]@{
        PlatformBase = $PlatformTempBase
        PhysicalBase = $physicalBase
        Directory = $directory
        LinksResolved = $links
    }
}

function New-BridgeTestResultsDirectory {
    param([Parameter(Mandatory)][string]$Directory)
    $resultsRoot = [IO.Path]::GetFullPath($Directory)
    if ($resultsRoot -match '^(\\\\|//)') { throw 'Test results must use a local directory.' }
    if (Test-BridgeTestExecution) {
        Assert-BridgeTestEnvironment
        Assert-BridgeTestPath -Path $resultsRoot
    }
    Assert-BridgeInstallPayload -Root $resultsRoot -CheckAncestors
    if (Test-Path -LiteralPath $resultsRoot) { throw "Use a new results directory; refusing to overwrite $resultsRoot" }
    [void][IO.Directory]::CreateDirectory($resultsRoot)
    @{ schemaVersion = 1; root = $resultsRoot } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $resultsRoot '.bridge-test-results') -Encoding utf8
    $resultsRoot
}

function New-BridgeTestSandbox {
    param([Parameter(Mandatory)][string]$ParentDirectory)

    $ParentDirectory = ConvertTo-BridgeInstallPath $ParentDirectory
    Assert-BridgeInstallPayload -Root $ParentDirectory -CheckAncestors
    if (Test-BridgeTestExecution) {
        Assert-BridgeTestEnvironment
        Assert-BridgeTestPath -Path $ParentDirectory -AllowRoot
    }
    else {
        $resultsMarker = Join-Path $ParentDirectory '.bridge-test-results'
        Assert-BridgeInstallPayload -Root $resultsMarker
        $results = [IO.File]::ReadAllText($resultsMarker) | ConvertFrom-Json -AsHashtable
        if ($results['schemaVersion'] -ne 1 -or -not (Test-BridgeInstallPath $results['root'] $ParentDirectory)) {
            throw 'Allocate test sandboxes only in a verified runner results directory.'
        }
    }
    $sandbox = Join-Path $ParentDirectory ("sandbox-" + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $sandbox) { throw 'The new sandbox already exists; nothing was overwritten.' }
    Assert-BridgeInstallPayload -Root $sandbox -CheckAncestors
    $homeDir = Join-Path $sandbox 'home'
    foreach ($relative in @(
        'home', 'temp', 'public', 'home\.agent-ha-bridge', 'home\.copilot', 'home\.claude', 'home\.codex',
        'home\AppData\Roaming', 'home\AppData\Local', 'home\.config', 'home\.cache', 'home\.local\share',
        'home\.local\state', 'runtime'
    )) {
        [void][IO.Directory]::CreateDirectory((Join-Path $sandbox ($relative.Replace('\', [IO.Path]::DirectorySeparatorChar))))
    }
    @{
        schemaVersion = 1
        id = (Split-Path $sandbox -Leaf).Substring('sandbox-'.Length)
        root = $sandbox
        parent = $ParentDirectory
        home = $homeDir
        repository = $script:BridgeTestRepository
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sandbox '.bridge-test-sandbox.json') -Encoding utf8
    $configPath = Join-Path (Join-Path $homeDir '.agent-ha-bridge') 'config.json'
    @{
        homeAssistant = @{ baseUrl = 'http://127.0.0.1:1'; token = 'synthetic-test-token'; agentToken = '' }
        copilot = @{ sessionStateRoot = (Join-Path (Join-Path $homeDir '.copilot') 'session-state') }
        notifications = @{ enabled = $false }
        updates = @{ checkForUpdates = $false }
        platform = @{ terminal = 'none' }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding utf8
    $sandbox
}

function Remove-BridgeTestSandbox {
    param([Parameter(Mandatory)][string]$Sandbox, [string]$Directory)
    $boundary = Get-BridgeTestSandbox -Root $Sandbox
    if (-not $Directory) { $Directory = $boundary['root'] }
    if (-not (Test-BridgeInstallPath $Directory $boundary['root']) -and
        -not (Test-BridgeInstallDescendant $Directory $boundary['root'])) {
        throw 'Cleanup cannot leave its owned test sandbox.'
    }
    Assert-BridgeInstallPayload -Root $Directory -CheckAncestors
    $pending = [Collections.Generic.Stack[string]]::new()
    $directories = [Collections.Generic.List[string]]::new()
    $pending.Push($Directory)
    while ($pending.Count) {
        $current = $pending.Pop()
        $directories.Add($current)
        foreach ($entry in Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                # Unlink the entry itself; never enumerate a fixture's link target.
                if ($entry.PSIsContainer) { [IO.Directory]::Delete($entry.FullName) }
                else { [IO.File]::Delete($entry.FullName) }
            }
            elseif ($entry.PSIsContainer) { $pending.Push($entry.FullName) }
            else { Remove-Item -LiteralPath $entry.FullName -Force -ErrorAction Stop }
        }
    }
    for ($index = $directories.Count - 1; $index -ge 0; $index--) {
        [IO.Directory]::Delete($directories[$index])
    }
}

function New-BridgeTestAmbientInstall {
    param([Parameter(Mandatory)][string]$HomeDirectory)
    Assert-BridgeTestEnvironment -Required
    $ambientHooks = Join-Path $HomeDirectory '.agent-ha-bridge\hooks'
    Assert-BridgeTestPath -Path @(
        $HomeDirectory, $ambientHooks,
        (Join-Path $ambientHooks 'decision-bridge-common.ps1'), (Join-Path $ambientHooks 'bridge-update.ps1')
    )
    [void][IO.Directory]::CreateDirectory($ambientHooks)
    Set-Content -LiteralPath (Join-Path $ambientHooks 'decision-bridge-common.ps1') -Value '# inert ambient dependency' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $ambientHooks 'bridge-update.ps1') -Encoding utf8 -Value @'
function Get-BridgeUpdateRepository { 'other-install' }
function Get-BridgeUpdateStatus {
    param([switch]$Force)
    [pscustomobject]@{ Installed = '1'; Latest = '1'; Available = $false }
}
'@
    $ambientHooks
}

function New-BridgeTestProcessStartInfo {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$Sandbox,
        [ValidateSet('Offline', 'Host', 'Platform')][string]$Group = 'Offline',
        [string[]]$ScriptArguments = @()
    )

    $ownedProbe = Test-BridgeTestExecution
    if ($ownedProbe) {
        Assert-BridgeTestEnvironment
        Assert-BridgeTestPath -Path $Sandbox -AllowRoot
        Assert-BridgeTestPath -Path $ScriptPath -SourceEntry
    }
    $boundary = Get-BridgeTestSandbox -Root $Sandbox
    # A real CLI entry changes script scope; both source paths belong to the validated boundary.
    $sourceRoot = [string]$boundary['repository']
    if (-not $ownedProbe -and -not (Test-BridgeInstallDescendant $ScriptPath $Sandbox) -and
        -not (Test-BridgeInstallDescendant $ScriptPath $boundary['repository'])) {
        throw 'The test entry must be in its sandbox or the source checkout.'
    }
    Assert-BridgeInstallPayload -Root $ScriptPath -CheckAncestors
    $homeDir = Join-Path $Sandbox 'home'
    $tempDir = Join-Path $Sandbox 'temp'
    $configPath = Join-Path (Join-Path $homeDir '.agent-ha-bridge') 'config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "Test sandbox is not initialized: $Sandbox" }
    if ($Group -ne 'Offline') { Assert-BridgeHostedTest -AllowHostTests }

    $pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    $start = [Diagnostics.ProcessStartInfo]::new($pwsh)
    $start.WorkingDirectory = $sourceRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)

    # An allowlist also removes custom token variable names, proxy credentials,
    # client launch context, Git overrides and BRIDGE_ALLOW_TEST_HTTP.
    $start.Environment.Clear()
    foreach ($name in @(
        'PATH', 'PATHEXT', 'SystemRoot', 'SystemDrive', 'WINDIR', 'ComSpec', 'OS',
        'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432', 'ProgramData',
        'PROCESSOR_ARCHITECTURE', 'PROCESSOR_ARCHITEW6432', 'NUMBER_OF_PROCESSORS', 'SHELL'
    )) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($null -ne $value) { $start.Environment[$name] = $value }
    }
    $variables = @{
        HOME = $homeDir
        USERPROFILE = $homeDir
        TEMP = $tempDir
        TMP = $tempDir
        TMPDIR = $tempDir
        PUBLIC = (Join-Path $Sandbox 'public')
        APPDATA = (Join-Path (Join-Path $homeDir 'AppData') 'Roaming')
        LOCALAPPDATA = (Join-Path (Join-Path $homeDir 'AppData') 'Local')
        XDG_CONFIG_HOME = (Join-Path $homeDir '.config')
        XDG_CACHE_HOME = (Join-Path $homeDir '.cache')
        XDG_DATA_HOME = (Join-Path (Join-Path $homeDir '.local') 'share')
        XDG_STATE_HOME = (Join-Path (Join-Path $homeDir '.local') 'state')
        XDG_RUNTIME_DIR = (Join-Path $Sandbox 'runtime')
        CLAUDE_CONFIG_DIR = (Join-Path $homeDir '.claude')
        CODEX_HOME = (Join-Path $homeDir '.codex')
        COPILOT_HOME = (Join-Path $homeDir '.copilot')
        DOTNET_CLI_HOME = $homeDir
        GIT_CONFIG_GLOBAL = (Join-Path $homeDir '.gitconfig')
        GIT_CONFIG_NOSYSTEM = '1'
        GIT_TERMINAL_PROMPT = '0'
        AGENT_HA_BRIDGE_CONFIG = $configPath
        AGENT_HA_BRIDGE_OFFLINE_TEST = '1'
        AGENT_HA_BRIDGE_TEST_ROOT = $Sandbox
        AGENT_HA_BRIDGE_TEST_ID = [string]$boundary['id']
        AGENT_HA_BRIDGE_TEST_GROUP = $Group
        LANG = 'en_US.UTF-8'
        LC_ALL = 'en_US.UTF-8'
        NO_COLOR = '1'
        TERM = 'dumb'
    }
    if ($IsWindows) {
        $drive = [IO.Path]::GetPathRoot($homeDir).TrimEnd('\')
        $variables.HOMEDRIVE = $drive
        $variables.HOMEPATH = $homeDir.Substring($drive.Length)
    }
    foreach ($name in $variables.Keys) { $start.Environment[$name] = $variables[$name] }
    if ($Group -ne 'Offline') {
        $start.Environment['GITHUB_ACTIONS'] = 'true'
        $start.Environment['RUNNER_ENVIRONMENT'] = 'github-hosted'
    }
    if ($Group -eq 'Host') {
        $start.Environment['AGENT_HA_BRIDGE_TEST_LOOPBACK_ORIGIN'] = 'http://127.0.0.1:1'
    }

    $command = @'
$ErrorActionPreference = 'Stop'
Set-Variable -Name HOME -Value $env:HOME -Scope Global -Force
. '__CONTEXT__'
Assert-BridgeTestEnvironment -Required
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$global:OutputEncoding = [Text.UTF8Encoding]::new($false)
$global:LASTEXITCODE = 0
& '__SUITE__' __ARGUMENTS__
if (-not $?) {
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    exit 1
}
exit 0
'@
    $command = $command.Replace('__SUITE__', $ScriptPath.Replace("'", "''"))
    $command = $command.Replace('__CONTEXT__', (Join-Path $sourceRoot 'hooks\bridge-install-context.ps1').Replace("'", "''"))
    $command = $command.Replace('__ARGUMENTS__', (@($ScriptArguments | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ' '))
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand',
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))) {
        $start.ArgumentList.Add($argument)
    }
    $start
}

function Invoke-BridgeTestProcess {
    param(
        [Parameter(Mandatory)][Diagnostics.ProcessStartInfo]$StartInfo,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 180
    )

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $StartInfo
    $started = $false
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $started = $process.Start()
        if (-not $started) { throw "Could not start test process: $($StartInfo.FileName)" }
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) {
            # Only this suite's process tree, never a process-name match.
            $process.Kill($true)
            $process.WaitForExit()
        }
        if (-not $stdout.Wait(5000) -or -not $stderr.Wait(5000)) { throw 'Test output did not close; a suite left a child process running.' }
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            TimedOut = $timedOut
            Seconds = [Math]::Round($watch.Elapsed.TotalSeconds, 2)
            Output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}
