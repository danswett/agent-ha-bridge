#Requires -Version 7.0
<#
.SYNOPSIS
    Real-file and Git regressions for worktree safety and workspace approval.
.DESCRIPTION
    Runs only in the canonical Offline sandbox. Tiny test-owned native processes
    exercise the real process readers; they are not agent clients. HA, installed
    launcher inventory and the final native launch boundary are synthetic.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($env:AGENT_HA_BRIDGE_OFFLINE_TEST -ne '1' -or -not $env:AGENT_HA_BRIDGE_TEST_ROOT) {
    throw 'Run this suite through tests\run-tests.ps1.'
}

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
$checkout = Split-Path $PSScriptRoot -Parent
. (Join-Path $checkout 'hooks\agent-bridge-daemon.ps1')
. (Join-Path $checkout 'claude\hooks\claude-session.ps1')
. (Join-Path $checkout 'codex\hooks\codex-session.ps1')
. (Join-Path $PSScriptRoot 'runner-support.ps1')
$script:ClaudeAdapterLoaded = $true
$script:CodexAdapterLoaded = $true

$script:P4Sandbox = $env:AGENT_HA_BRIDGE_TEST_ROOT
if (-not $IsWindows) {
    Push-Location -LiteralPath $script:P4Sandbox
    try {
        $script:P4Sandbox = (& /bin/pwd -P | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $script:P4Sandbox) { throw 'Cannot resolve the actual fixture sandbox.' }
    }
    finally { Pop-Location }
}
$script:P4Root = Join-Path $script:P4Sandbox 'home\p4'
$script:P4CaseNumber = 0
$script:P4Failures = 0
$script:P4FixtureErrors = 0
$script:P4Children = [Collections.Generic.List[object]]::new()
$script:P4Launches = [Collections.Generic.List[object]]::new()
$script:P4Messages = [Collections.Generic.List[string]]::new()
$script:P4States = @{}
$script:P4Available = @('copilot', 'claude', 'codex')
$script:P4OriginalConfig = Get-Content -LiteralPath $env:AGENT_HA_BRIDGE_CONFIG -Raw
$headers = @{}

# The harness is not an OS process namespace. Scope this external inventory to
# actual test-owned processes, without replacing any liveness/read failure helper.
function Get-Process {
    [CmdletBinding()]
    [OutputType([System.Diagnostics.Process], [object[]])]
    param([string[]]$Name = @(), [int[]]$Id = @())
    $owned = @($PID) + @($script:P4Children | ForEach-Object { $_.Process.Id })
    $actual = @(Microsoft.PowerShell.Management\Get-Process -Id $owned -ErrorAction SilentlyContinue)
    if ($Id.Count) { return @($actual | Where-Object { $_.Id -in $Id }) }
    if ($Name.Count) {
        return @($actual | Where-Object {
            $processName = $_.ProcessName
            @($Name | Where-Object { $processName -like $_ }).Count -gt 0
        })
    }
    $actual
}

function Assert-P4Path {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (Test-BridgeInstallDescendant -Path $full -Root $env:AGENT_HA_BRIDGE_TEST_ROOT) {
        $full = Join-Path $script:P4Sandbox ([IO.Path]::GetRelativePath($env:AGENT_HA_BRIDGE_TEST_ROOT, $full))
    }
    if (-not (Test-BridgeInstallDescendant -Path $full -Root $script:P4Sandbox)) {
        throw "Fixture path escaped the canonical child sandbox: $Path"
    }
    Assert-BridgeInstallPayload -Root $script:P4Sandbox -RelativePaths @(
        [IO.Path]::GetRelativePath($script:P4Sandbox, $full)
    )
}

function Invoke-P4Git {
    param([string]$Directory, [string[]]$Arguments)
    Assert-P4Path $Directory
    $result = Invoke-BridgeGit -Directory $Directory -Arguments $Arguments
    if (-not $result.Ok) { throw "Fixture git $($Arguments -join ' ') failed ($($result.Code)): $($result.Output)" }
    $result.Output
}

function Assert-P4Repository {
    param([Parameter(Mandatory)]$Fixture)
    Assert-P4Path $Fixture.Repository
    if (-not [IO.Directory]::Exists((Join-Path $Fixture.Repository '.git'))) {
        throw 'Cleanup requires a disposable primary fixture repository, not a worker worktree.'
    }
    $listed = Invoke-P4Git $Fixture.Repository @('worktree', 'list', '--porcelain')
    foreach ($line in ($listed -split '\r?\n')) {
        if ($line -match '^worktree (.+)$') {
            $path = [IO.Path]::GetFullPath($Matches[1])
            Assert-P4Path $path
            if (-not (Test-BridgeInstallDescendant -Path $path -Root $Fixture.Root)) {
                throw 'A fixture repository lists a worktree outside its own case.'
            }
        }
    }
}

function Test-P4 {
    param([string]$Name, [bool]$Passed, $Evidence = $null)
    if ($Passed) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name"; $script:P4Failures++ }
    if ($null -ne $Evidence) {
        $record = @{ name = $Name; passed = $Passed; observed = $Evidence } | ConvertTo-Json -Depth 8 -Compress
        $escapedRoot = ($env:AGENT_HA_BRIDGE_TEST_ROOT | ConvertTo-Json -Compress).Trim('"')
        Write-Host ('  EVIDENCE ' + $record.Replace($escapedRoot, '<sandbox>'))
    }
}

function Invoke-P4Scenario {
    param([string]$Name, [scriptblock]$Body)
    Write-Host "--- $Name ---"
    try { & $Body }
    catch {
        $script:P4FixtureErrors++
        Write-Host "  FIXTURE ERROR $Name : $($_.Exception.Message)"
        Write-Host $_.ScriptStackTrace
    }
}

function Set-P4Config {
    param([Parameter(Mandatory)]$Fixture, [hashtable]$Changes = @{}, [switch]$KeepDiscoveryCache)
    $config = $script:P4OriginalConfig | ConvertFrom-Json -AsHashtable
    $config['clients'] = @('copilot', 'claude', 'codex')
    $config['newSession'] = @{
        launcher = 'copilot'
        workspaces = @(@{ label = 'Approved'; path = $Fixture.Repository; isolate = $false })
        defaultWorkspace = 'Approved'
        worktreeRoot = $Fixture.WorktreeRoot
        worktreeLimit = 32
        worktreeIdleHours = 12
        discoverWorkspaces = $false
        discoverCount = 8
        resumeCount = 100
        allowAllTools = $false
    }
    foreach ($key in $Changes.Keys) {
        if ($null -eq $Changes[$key]) { $config.newSession.Remove($key) }
        else { $config.newSession[$key] = $Changes[$key] }
    }
    [IO.File]::WriteAllText($env:AGENT_HA_BRIDGE_CONFIG, ($config | ConvertTo-Json -Depth 12))
    $script:BridgeUserConfig = Get-BridgeUserConfig
    if (-not $KeepDiscoveryCache) {
        $script:BridgeDiscoveredWorkspaceCache = $null
        $script:BridgeDiscoveredWorkspaceCacheAt = [DateTimeOffset]::MinValue
    }
    $script:DaemonConfig.LogFile = Join-Path $Fixture.Root 'daemon.log'
    $script:DaemonResumeCache = @()
    $script:DaemonResumeCacheAt = [DateTimeOffset]::MinValue
    $script:P4States = @{
        $script:DaemonEntity.NewWorkspace = 'Approved'
        $script:DaemonEntity.NewAgent = 'Copilot'
        $script:DaemonEntity.NewResume = $script:CopilotMqttNewSessionOption
        $script:DaemonEntity.NewModel = $script:BridgeTuningDefaultOption
        $script:DaemonEntity.NewEffort = $script:BridgeTuningDefaultOption
        $script:DaemonEntity.NewContext = $script:BridgeTuningDefaultOption
        $script:DaemonEntity.NewPermissions = $script:BridgePermissionAskOption
        $script:DaemonEntity.NewPrompt = ''
    }
}

function New-P4Fixture {
    $script:P4CaseNumber++
    $root = Join-Path $script:P4Root "c$($script:P4CaseNumber)"
    Assert-P4Path $root
    [void][IO.Directory]::CreateDirectory($root)
    $fixture = [pscustomobject]@{
        Root = $root
        Repository = Join-Path $root 'repo'
        WorktreeRoot = Join-Path $root 'wt'
    }
    $null = Invoke-P4Git $root @('clone', '--quiet', '--no-hardlinks', $script:P4Origin, $fixture.Repository)
    $null = Invoke-P4Git $fixture.Repository @('config', 'user.name', 'P4 Fixture')
    $null = Invoke-P4Git $fixture.Repository @('config', 'user.email', 'p4@example.invalid')
    Set-P4Config $fixture
    Assert-P4Repository $fixture
    $fixture
}

function New-P4Worktree {
    param([Parameter(Mandatory)]$Fixture)
    Assert-P4Repository $Fixture
    $result = New-BridgeSessionWorktree -RepositoryPath $Fixture.Repository
    if (-not $result.Isolated -or $result.Path -eq $Fixture.Repository) {
        throw "Fixture worktree creation did not isolate: $($result.Detail)"
    }
    Assert-P4Path $result.Path
    Assert-P4Path (Get-BridgeWorktreeMarkerPath -Path $result.Path)
    $result.Path
}

function Set-P4OldWorktree {
    param([string]$Path)
    $marker = Get-BridgeWorktreeMarkerPath -Path $Path
    Assert-P4Path $marker
    [IO.File]::WriteAllText($marker, [DateTime]::Now.AddHours(-48).ToString('o'))
}

function Test-P4TreePreserved {
    param([string]$Path)
    $file = Join-Path $Path 'tracked.txt'
    [IO.File]::Exists((Join-Path $Path '.git')) -and [IO.File]::Exists($file) -and
        [IO.File]::ReadAllText($file) -ceq 'P4 tracked content'
}

function Invoke-P4Cleanup {
    param([Parameter(Mandatory)]$Fixture, [string]$Worktree)
    Assert-P4Repository $Fixture
    $removed = $null
    $failure = ''
    $warnings = @()
    try { $removed = Remove-BridgeFinishedWorktree -RepositoryPath $Fixture.Repository -IdleHours 12 -WarningVariable warnings }
    catch { $failure = $_.Exception.Message }
    [pscustomobject]@{
        Removed = $removed
        Error = $failure
        Warnings = @($warnings | ForEach-Object { $_.Message })
        DirectoryPresent = [IO.Directory]::Exists($Worktree)
        TrackedContentPreserved = Test-P4TreePreserved $Worktree
    }
}

function Start-P4Child {
    param([string]$Kind, [string]$Directory, [string]$SessionId,
        [string]$WatchTrace = '', [string]$WritePath = '', [string]$WriteTrigger = 'remove')
    Assert-P4Path $Directory
    $key = [guid]::NewGuid().ToString('N')
    $ready = Join-Path $script:P4Root "$key.ready"
    $stop = Join-Path $script:P4Root "$key.stop"
    $agent = if ($Kind -eq 'agency') { 'copilot' } elseif ($Kind -in @('writer', 'holder')) { 'fixture' } else { $Kind }
    $start = [Diagnostics.ProcessStartInfo]::new($script:P4Executables[$agent])
    $start.WorkingDirectory = $Directory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.ArgumentList.Add((Join-Path $script:P4Root "$agent.js"))
    if (-not $IsWindows) {
        $package = switch ($agent) {
            'copilot' { '@github/copilot' }
            'claude' { '@anthropic-ai/claude-code' }
            'codex' { '@openai/codex' }
            default { 'p4-fixture' }
        }
        $start.ArgumentList.Add("--fixture-package=$package")
    }
    foreach ($argument in @("-ready=$ready", "-stop=$stop", "--session-id=$SessionId")) {
        $start.ArgumentList.Add($argument)
    }
    if ($WatchTrace) {
        Assert-P4Path $WatchTrace
        Assert-P4Path $WritePath
        $start.ArgumentList.Add("-watch=$WatchTrace")
        $start.ArgumentList.Add("-write=$WritePath")
        $start.ArgumentList.Add("-trigger=$WriteTrigger")
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'Fixture child did not start.' }
    $child = [pscustomobject]@{ Process = $process; Ready = $ready; Stop = $stop; Agent = $agent; Written = "$ready.wrote" }
    $script:P4Children.Add($child)
    try {
        $reported = $null
        $deadline = [DateTimeOffset]::Now.AddSeconds(10)
        while ($null -eq $reported -and -not $process.HasExited -and [DateTimeOffset]::Now -lt $deadline) {
            if ([IO.File]::Exists($ready)) {
                try { $reported = [IO.File]::ReadAllText($ready) | ConvertFrom-Json }
                catch [IO.IOException] { Start-Sleep -Milliseconds 20 }
            }
            else { Start-Sleep -Milliseconds 20 }
        }
        if ($null -eq $reported -or $process.HasExited) { throw 'Fixture child did not report readable readiness within the deadline.' }
        if ($reported.pid -ne $process.Id -or -not (Test-BridgeInstallPath $reported.cwd (Resolve-BridgeWorkspaceDirectory $Directory))) {
            throw 'Fixture child identity or actual working directory did not match.'
        }
        if (@(Get-BridgeAgentProcesses -Agent $agent | Where-Object Id -eq $process.Id).Count -ne 1) {
            throw 'The actual process reader did not recognize the test-owned native fixture.'
        }
        $child
    }
    catch {
        $failure = $_
        Stop-P4Child $child
        throw $failure
    }
}

function Stop-P4Child {
    param([Parameter(Mandatory)]$Child)
    try {
        if (-not $Child.Process.HasExited) {
            [IO.File]::WriteAllText($Child.Stop, 'stop')
            if (-not $Child.Process.WaitForExit(5000)) {
                $Child.Process.Kill($true)
                $Child.Process.WaitForExit()
                throw 'The exact owned fixture process required forced shutdown.'
            }
        }
    }
    finally {
        [void]$script:P4Children.Remove($Child)
        $Child.Process.Dispose()
    }
}

function Start-P4MutexHolder {
    param([Parameter(Mandatory)]$Fixture)
    $contextPath = Join-Path $Fixture.Root 'mutex-context.json'
    $scriptPath = Join-Path $Fixture.Root 'mutex-holder.ps1'
    $ready = Join-Path $Fixture.Root 'mutex-ready.json'
    $stop = Join-Path $Fixture.Root 'mutex-stop'
    @{
        repository = $Fixture.Repository; checkout = $checkout; ready = $ready; stop = $stop
    } | ConvertTo-Json | Set-Content -LiteralPath $contextPath
    [IO.File]::WriteAllText($scriptPath, @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$context = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'mutex-context.json') -Raw | ConvertFrom-Json
. (Join-Path $context.checkout 'hooks\decision-bridge-common.ps1')
. (Join-Path $context.checkout 'hooks\session-launch.ps1')
$operation = Enter-BridgeWorktreeOperation -RepositoryPath $context.repository
try {
    [IO.File]::WriteAllText(($context.ready + '.pending'), ([string]$PID))
    [IO.File]::Move(($context.ready + '.pending'), $context.ready)
    $deadline = [DateTimeOffset]::Now.AddMinutes(2)
    while (-not [IO.File]::Exists($context.stop) -and [DateTimeOffset]::Now -lt $deadline) {
        Start-Sleep -Milliseconds 20
    }
}
finally { $operation.Mutex.ReleaseMutex(); $operation.Mutex.Dispose() }
'@)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = New-BridgeTestProcessStartInfo -ScriptPath $scriptPath -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT
    if (-not $process.Start()) { throw 'The owned mutex holder did not start.' }
    $process.StandardInput.Close()
    $child = [pscustomobject]@{ Process = $process; Ready = $ready; Stop = $stop }
    $script:P4Children.Add($child)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $child | Add-Member -NotePropertyName OutputTasks -NotePropertyValue @($stdout, $stderr)
    $deadline = [DateTimeOffset]::Now.AddSeconds(15)
    while (-not [IO.File]::Exists($ready) -and -not $process.HasExited -and [DateTimeOffset]::Now -lt $deadline) {
        Start-Sleep -Milliseconds 20
    }
    if (-not [IO.File]::Exists($ready) -or $process.HasExited) { throw 'The actual repository mutex was not acquired by the fixture child.' }
    $child
}

function New-P4SessionFiles {
    param([string]$Kind, [string]$Directory, [string]$SessionId, [int]$ProcessId = 0)
    $files = [Collections.Generic.List[string]]::new()
    if ($Kind -in @('copilot', 'agency')) {
        $state = Join-Path $script:DecisionBridgeConfig.SessionStateRoot $SessionId
        Assert-P4Path $state
        [void][IO.Directory]::CreateDirectory($state)
        $workspace = Join-Path $state 'workspace.yaml'
        [IO.File]::WriteAllText($workspace, "cwd: $Directory`nsummary: P4 $Kind fixture`n")
        $files.Add($workspace)
        $events = Join-Path $state 'events.jsonl'
        [IO.File]::WriteAllText($events, (@{
            type = 'session.start'; data = @{ context = @{ cwd = $Directory }; frontend = $Kind }
        } | ConvertTo-Json -Depth 5 -Compress))
        $files.Add($events)
        if ($ProcessId -gt 0) {
            $lock = Join-Path $state "inuse.$ProcessId.lock"
            [IO.File]::WriteAllText($lock, 'test-owned process')
            $files.Add($lock)
        }
    }
    elseif ($Kind -eq 'claude') {
        $project = Join-Path $script:ClaudeProjectsRoot 'p4'
        Assert-P4Path $project
        [void][IO.Directory]::CreateDirectory($project)
        $transcript = Join-Path $project "$SessionId.jsonl"
        [IO.File]::WriteAllText($transcript, (@{
            type = 'user'; cwd = $Directory; message = @{ content = 'P4 Claude fixture' }
        } | ConvertTo-Json -Depth 5 -Compress))
        $files.Add($transcript)
        if ($ProcessId -gt 0) {
            $files.Add((Write-ClaudeSessionRegistration -SessionId $SessionId -TranscriptPath $transcript `
                -WorkingDirectory $Directory -ProcessId $ProcessId -Status idle))
        }
    }
    else {
        $sessions = Join-Path (Get-BridgeInstallContext).CodexHome 'sessions'
        Assert-P4Path $sessions
        [void][IO.Directory]::CreateDirectory($sessions)
        $transcript = Join-Path $sessions "rollout-$SessionId.jsonl"
        $lines = @(
            (@{ type = 'session_meta'; payload = @{ id = $SessionId; cwd = $Directory } } | ConvertTo-Json -Compress)
            (@{ type = 'user_message'; payload = @{ type = 'user_message'; message = 'P4 Codex fixture' } } | ConvertTo-Json -Compress)
        )
        [IO.File]::WriteAllLines($transcript, $lines)
        $files.Add($transcript)
        if ($ProcessId -gt 0) {
            $files.Add((Write-CodexSessionRegistration -SessionId $SessionId -TranscriptPath $transcript `
                -WorkingDirectory $Directory -ProcessId $ProcessId -Status idle -Model fixture -Activity fixture))
        }
    }
    foreach ($file in $files) { Assert-P4Path $file }
    @($files)
}

function Remove-P4SessionFiles {
    param([string[]]$Files)
    # The early-exit transcript enumeration can retain a handle until finalization.
    # This is fixture teardown only, after all production-path observations.
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    foreach ($file in $Files) {
        Assert-P4Path $file
        if ([IO.File]::Exists($file)) { Remove-Item -LiteralPath $file -Force -ErrorAction Stop }
    }
}

# Alongside the scoped native process inventory above, these are the substituted
# external boundaries. Configuration, discovery, liveness, Git, worktree eligibility,
# creation and launch-request failure helpers remain the actual implementations.
function Get-BridgeAvailableLaunchers { @($script:P4Available) }
function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    $null = $Headers
    [pscustomobject]@{
        state = if ($script:P4States.ContainsKey($EntityId)) { $script:P4States[$EntityId] } else { 'unknown' }
        attributes = [pscustomobject]@{}
    }
}
function Set-CopilotMqttNewSessionResult {
    param([string]$Text, [hashtable]$Headers)
    $null = $Headers
    $script:P4Messages.Add($Text)
    $true
}
function Start-BridgeCopilotSession {
    param([string]$WorkingDirectory, [string]$Prompt, [string]$AgencyProfile, [string]$SessionId,
        [string]$Launcher, [string]$Model, [string]$Effort, [string]$Context, [bool]$AllowAllTools, [switch]$Resume)
    Assert-P4Path $WorkingDirectory
    $script:P4Launches.Add([pscustomobject]@{
        Directory = $WorkingDirectory; Resume = [bool]$Resume; Launcher = $Launcher
        Prompt = $Prompt; AgencyProfile = $AgencyProfile; AllowAllTools = $AllowAllTools
    })
    [pscustomobject]@{
        Launched = $true; ProcessId = 0; Detail = 'synthetic native launch'
        SessionId = if ($SessionId) { $SessionId } else { [guid]::NewGuid().ToString() }
        Model = $Model; Effort = $Effort; Context = $Context
    }
}

function Get-P4Controls {
    [pscustomobject]@{
        Workspaces = @(Get-BridgeWorkspaceChoices)
        Launcher = 'copilot'; Launchers = @($script:P4Available); Profiles = @()
        Resumable = @(Get-DaemonResumableSessions -LiveSessionIds @() -Force)
    }
}

function Invoke-P4Launch {
    param($Request = $null, $Controls = $null)
    $script:P4Launches.Clear()
    $script:P4Messages.Clear()
    $script:DaemonPendingLaunch = $null
    $failure = ''
    try {
        if ($null -eq $Request) {
            if ($null -eq $Controls) { $Controls = Get-P4Controls }
            $Request = Resolve-DaemonLaunchRequest -Controls $Controls -Headers $headers
        }
        if ($null -ne $Request) { Start-DaemonLaunch -Request $Request -Headers $headers }
    }
    catch { $failure = $_.Exception.Message }
    [pscustomobject]@{
        Calls = @($script:P4Launches.ToArray())
        Messages = @($script:P4Messages.ToArray())
        Error = $failure
        Pending = ($null -ne $script:DaemonPendingLaunch)
    }
}

function Test-P4IsolationFailure {
    param([string]$Name, [Parameter(Mandatory)]$Fixture, [string]$RepositoryPath = $Fixture.Repository)
    Assert-P4Path $RepositoryPath
    $result = $null
    $failure = ''
    try { $result = New-BridgeSessionWorktree -RepositoryPath $RepositoryPath }
    catch { $failure = $_.Exception.Message }
    $path = if ($null -ne $result) { [string]$result.Path } else { '' }
    $detail = if ($null -ne $result) { [string]$result.Detail } else { $failure }
    Test-P4 "${Name}: real creation failure returns no executable fallback" `
        ([string]::IsNullOrWhiteSpace($path)) @{ path = $path; detail = $detail; exception = $failure }
    Test-P4 "${Name}: actual failure has a useful diagnostic" (-not [string]::IsNullOrWhiteSpace($detail))
    $outcome = Invoke-P4Launch
    Test-P4 "${Name}: actual caller refuses native launch and pending-success state" `
        ($outcome.Calls.Count -eq 0 -and -not $outcome.Pending) $outcome
    Test-P4 "${Name}: refusal is visible to the caller" `
        ($outcome.Calls.Count -eq 0 -and (-not [string]::IsNullOrWhiteSpace($outcome.Error) -or
            ($outcome.Messages -join ' ') -match 'fail|refus|isolat|worktree|configured'))
}

try {
    Assert-P4Path $script:P4Root
    [void][IO.Directory]::CreateDirectory($script:P4Root)
    foreach ($root in @($HOME, (Get-BridgeInstallContext).RuntimeRoot, $script:DecisionBridgeConfig.SessionStateRoot)) {
        Assert-P4Path $root
    }
    $node = Get-Command node -CommandType Application -ErrorAction Stop
    $script:P4Executables = @{}
    $program = @'
const fs = require('node:fs');
const path = require('node:path');
const args = {};
for (const arg of process.argv.slice(2)) {
  const match = /^--?([^=]+)=(.*)$/s.exec(arg);
  if (match) args[match[1]] = match[2];
}
function publish(file, value) {
  fs.writeFileSync(file + '.pending', value, { mode: 0o600 });
  fs.renameSync(file + '.pending', file);
}
publish(args.ready, JSON.stringify({ pid: process.pid, cwd: process.cwd() }));
let written = false;
setInterval(() => {
  if (fs.existsSync(args.stop)) process.exit(0);
  if (args.watch && !written) {
    const trace = fs.readFileSync(args.watch, 'utf8');
    const trigger = args.trigger === 'restore' ? '"checkout-index","--all"' : '"rm","-r","--quiet","--","."';
    if (trace.includes(trigger)) {
      fs.mkdirSync(path.dirname(args.write), { recursive: true, mode: 0o700 });
      fs.writeFileSync(args.write, 'late ignored user data', { mode: 0o600 });
      publish(args.ready + '.wrote', new Date().toISOString());
      written = true;
    }
  }
}, 1);
setTimeout(() => process.exit(3), 5 * 60 * 1000);
'@
    foreach ($agent in @('copilot', 'claude', 'codex', 'fixture')) {
        [IO.File]::WriteAllText((Join-Path $script:P4Root "$agent.js"), $program)
        $script:P4Executables[$agent] = $node.Source
        if ($IsWindows) {
            $script:P4Executables[$agent] = Join-Path $script:P4Root "$agent.exe"
            Copy-Item -LiteralPath $node.Source -Destination $script:P4Executables[$agent]
        }
    }

    $script:P4Origin = Join-Path $script:P4Root 'origin.git'
    $seed = Join-Path $script:P4Root 'seed'
    $null = Invoke-P4Git $script:P4Root @('init', '--quiet', '--bare', '--initial-branch=main', $script:P4Origin)
    $null = Invoke-P4Git $script:P4Root @('clone', '--quiet', $script:P4Origin, $seed)
    $null = Invoke-P4Git $seed @('config', 'user.name', 'P4 Fixture')
    $null = Invoke-P4Git $seed @('config', 'user.email', 'p4@example.invalid')
    [IO.File]::WriteAllText((Join-Path $seed 'tracked.txt'), 'P4 tracked content')
    [void][IO.Directory]::CreateDirectory((Join-Path $seed 'src\child'))
    [IO.File]::WriteAllText((Join-Path $seed 'src\child\tracked.txt'), 'P4 descendant content')
    [IO.File]::WriteAllText((Join-Path $seed '.gitignore'), "ignored-data/`n")
    $null = Invoke-P4Git $seed @('add', 'tracked.txt', 'src', '.gitignore')
    $null = Invoke-P4Git $seed @('commit', '--quiet', '-m', 'P4 disposable fixture')
    $null = Invoke-P4Git $seed @('push', '--quiet', '-u', 'origin', 'main')

    foreach ($kind in @('copilot', 'agency', 'claude', 'codex')) {
        foreach ($descendant in @($false, $true)) {
            Invoke-P4Scenario "$kind live cwd descendant=$descendant with discovery disabled" {
                $fixture = New-P4Fixture
                $worktree = New-P4Worktree $fixture
                Set-P4OldWorktree $worktree
                $cwd = if ($descendant) { Join-Path $worktree 'src\child' } else { $worktree }
                $id = [guid]::NewGuid().ToString()
                $child = Start-P4Child -Kind $kind -Directory $cwd -SessionId $id
                $files = @()
                try {
                    $files = @(New-P4SessionFiles $kind $cwd $id $child.Process.Id)
                    foreach ($file in $files) {
                        [IO.File]::SetLastWriteTimeUtc($file, [DateTime]::UtcNow.AddHours(-48))
                    }
                    $live = switch ($kind) {
                        'claude' { @(Get-ClaudeSessionRegistrations | Where-Object SessionId -eq $id).Count -eq 1 }
                        'codex' { @(Get-CodexSessionRegistrations | Where-Object SessionId -eq $id).Count -eq 1 }
                        default { (Get-LiveCopilotSessions).ContainsKey($id) }
                    }
                    if (-not $live) { throw 'The real adapter reader did not establish the fixture session as live.' }
                    Test-P4 "$kind descendant=${descendant}: actual adapter/process reader sees the live fixture" $live
                    $outcome = Invoke-P4Cleanup $fixture $worktree
                    Test-P4 "$kind descendant=${descendant}: disabling discovery never permits live-tree cleanup" `
                        ($outcome.TrackedContentPreserved -and $outcome.Removed -eq 0 -and -not $child.Process.HasExited) $outcome
                }
                finally {
                    Stop-P4Child $child
                    Remove-P4SessionFiles $files
                }
            }
        }
    }

    foreach ($mode in @('exact', 'descendant', 'capped', 'cached', 'unreadable', 'malformed')) {
        Invoke-P4Scenario "real Claude state and discovery $mode" {
            $fixture = New-P4Fixture
            Set-P4Config $fixture @{ discoverWorkspaces = $true; discoverCount = 1 }
            if (Test-BridgeSystemDirectory $fixture.Root) {
                Write-Host "  SKIP discovery-${mode}: this platform's canonical sandbox is excluded by the actual system-directory filter."
                return
            }
            $worktree = New-P4Worktree $fixture
            Set-P4OldWorktree $worktree
            $cwd = if ($mode -eq 'descendant') { Join-Path $worktree 'src\child' } else { $worktree }
            $id = [guid]::NewGuid().ToString()
            $child = Start-P4Child claude $cwd $id
            $files = @()
            $lock = $null
            try {
                if ($mode -eq 'cached') {
                    $script:BridgeDiscoveredWorkspaceCache = $null
                    $null = @(Get-BridgeDiscoveredWorkspaces)
                }
                $files = @(New-P4SessionFiles claude $cwd $id $child.Process.Id)
                $registration = @($files | Where-Object { $_.EndsWith('.json') })[0]
                # Registration, not transcript history, is the only liveness input here.
                foreach ($transcript in @($files | Where-Object { $_.EndsWith('.jsonl') })) {
                    Remove-Item -LiteralPath $transcript
                }
                if ($mode -eq 'capped') {
                    [IO.File]::SetLastWriteTimeUtc($registration, [DateTime]::UtcNow.AddDays(-2))
                    $decoy = Join-Path $fixture.Root 'recent'
                    [void][IO.Directory]::CreateDirectory($decoy)
                    $decoyFile = Write-ClaudeSessionRegistration -SessionId ([guid]::NewGuid().ToString()) `
                        -WorkingDirectory $decoy -ProcessId 0
                    $files += $decoyFile
                }
                elseif ($mode -eq 'malformed') { [IO.File]::WriteAllText($registration, '{"SessionId":') }
                elseif ($mode -eq 'unreadable') {
                    $lock = [IO.File]::Open($registration, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                    $readFailed = $false
                    try { $null = Get-Content -LiteralPath $registration -Raw -ErrorAction Stop }
                    catch { $readFailed = $true }
                    if (-not $readFailed) { throw 'The own-file lock did not produce a real registration read failure.' }
                    Test-P4 'an exclusive own-file lock actually denies the registration reader' $readFailed
                }
                if ($mode -ne 'cached') { $script:BridgeDiscoveredWorkspaceCache = $null }
                $discovered = @(Get-BridgeDiscoveredWorkspaces)
                $outcome = Invoke-P4Cleanup $fixture $worktree
                Test-P4 "Claude ${mode}: live or unreadable state preserves the complete worktree" `
                    ($outcome.TrackedContentPreserved -and $outcome.Removed -eq 0) @{
                        cleanup = $outcome; discovered = $discovered; lockHeld = ($null -ne $lock)
                    }
            }
            finally {
                if ($null -ne $lock) { $lock.Dispose() }
                Stop-P4Child $child
                Remove-P4SessionFiles $files
            }
        }
    }

    foreach ($mode in @('clean', 'young', 'dirty', 'untracked', 'branch', 'ahead', 'unowned', 'ignored', 'locked', 'bad-index')) {
        Invoke-P4Scenario "real Git cleanup $mode" {
            $fixture = New-P4Fixture
            $worktree = New-P4Worktree $fixture
            if ($mode -ne 'young') { Set-P4OldWorktree $worktree }
            switch ($mode) {
                'dirty' { [IO.File]::WriteAllText((Join-Path $worktree 'edit.txt'), 'to be tracked'); $null = Invoke-P4Git $worktree @('add', 'edit.txt') }
                'untracked' { [IO.File]::WriteAllText((Join-Path $worktree 'untracked.txt'), 'keep this') }
                'branch' { $null = Invoke-P4Git $worktree @('switch', '--quiet', '-c', 'p4-unmerged') }
                'ahead' {
                    [IO.File]::WriteAllText((Join-Path $worktree 'ahead.txt'), 'keep detached commit')
                    $null = Invoke-P4Git $worktree @('add', 'ahead.txt')
                    $null = Invoke-P4Git $worktree @('commit', '--quiet', '-m', 'P4 detached work')
                }
                'unowned' { Remove-Item -LiteralPath (Get-BridgeWorktreeMarkerPath $worktree) }
                'ignored' {
                    $ignoredDirectory = Join-Path $worktree 'ignored-data'
                    [void][IO.Directory]::CreateDirectory($ignoredDirectory)
                    [IO.File]::WriteAllText((Join-Path $ignoredDirectory 'user.txt'), 'ignored user content')
                    $null = Invoke-P4Git $worktree @('check-ignore', 'ignored-data/user.txt')
                    Test-P4 'ignored data makes the actual finished predicate refuse cleanup' `
                        (-not (Test-BridgeWorktreeFinished $worktree 'origin/main' 12))
                }
                'locked' {
                    $null = Invoke-P4Git $fixture.Repository @('worktree', 'lock', '--reason', 'P4 fixture', $worktree)
                    $denied = Invoke-BridgeGit -Directory $fixture.Repository -Arguments @('worktree', 'remove', $worktree)
                    if ($denied.Ok) { throw 'Fixture Git worktree lock failed to deny removal.' }
                    Test-P4 'the real Git lock refuses removal before the cleanup consumer runs' (-not $denied.Ok) $denied
                }
                'bad-index' {
                    $admin = Split-Path (Get-BridgeWorktreeMarkerPath $worktree) -Parent
                    [IO.File]::WriteAllText((Join-Path $admin 'index'), 'invalid fixture index')
                    $denied = Invoke-BridgeGit -Directory $worktree -Arguments @('--no-optional-locks', 'status', '--porcelain')
                    if ($denied.Ok) { throw 'The corrupt fixture index did not fail the actual Git status path.' }
                    Test-P4 'the corrupt own index reaches the real Git status failure' (-not $denied.Ok) $denied
                }
            }
            $outcome = Invoke-P4Cleanup $fixture $worktree
            if ($mode -eq 'clean') {
                Test-P4 'a genuinely finished owned worktree can still be removed' `
                    ($outcome.Removed -eq 1 -and -not $outcome.DirectoryPresent -and -not $outcome.Error) $outcome
            }
            else {
                Test-P4 "$mode worktree survives actual unattended cleanup" `
                    ($outcome.Removed -eq 0 -and $outcome.TrackedContentPreserved) $outcome
                if ($mode -eq 'ignored') {
                    $ignored = Join-Path $worktree 'ignored-data\user.txt'
                    Test-P4 'ignored user bytes survive the real cleanup consumer' `
                        ([IO.File]::Exists($ignored) -and [IO.File]::ReadAllText($ignored) -ceq 'ignored user content')
                }
            }
            Test-P4 "$mode cleanup never removes the fixture primary repository" `
                ([IO.File]::Exists((Join-Path $fixture.Repository 'tracked.txt')) -and
                    (Invoke-P4Git $fixture.Repository @('branch', '--show-current')) -eq 'main')
        }
    }

    Invoke-P4Scenario 'native non-forced Git removal preserves ignored bytes' {
        $fixture = New-P4Fixture
        $worktree = New-P4Worktree $fixture
        $ignoredDirectory = Join-Path $worktree 'ignored-data'
        [void][IO.Directory]::CreateDirectory($ignoredDirectory)
        $ignored = Join-Path $ignoredDirectory 'user.txt'
        [IO.File]::WriteAllText($ignored, 'ignored user content')
        Assert-P4Repository $fixture
        $attempt = Invoke-BridgeGit -Directory $fixture.Repository -Arguments @('worktree', 'remove', $worktree)
        Write-Host ("  NATIVE OBSERVATION " + (@{
            operation = 'git worktree remove without force'
            succeeded = $attempt.Ok
            ignoredFilePreserved = [IO.File]::Exists($ignored)
        } | ConvertTo-Json -Compress))
    }

    foreach ($kind in @('copilot', 'agency', 'codex')) {
        foreach ($mode in @('unreadable', 'unknown')) {
            Invoke-P4Scenario "$kind authoritative state is $mode" {
                $fixture = New-P4Fixture
                $worktree = New-P4Worktree $fixture
                Set-P4OldWorktree $worktree
                $id = [guid]::NewGuid().ToString()
                $child = Start-P4Child $kind (Join-Path $worktree 'src\child') $id
                $files = @()
                $lock = $null
                try {
                    $files = @(New-P4SessionFiles $kind (Join-Path $worktree 'src\child') $id $child.Process.Id)
                    $metadata = if ($kind -eq 'codex') {
                        @($files | Where-Object { $_.EndsWith('.json') })[0]
                    } else { @($files | Where-Object { $_.EndsWith('workspace.yaml') })[0] }
                    if ($mode -eq 'unreadable') {
                        $lock = [IO.File]::Open($metadata, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                        $denied = $false
                        try { $null = [IO.File]::ReadAllText($metadata) } catch [IO.IOException] { $denied = $true }
                        if (-not $denied) { throw 'The metadata fixture did not produce a real read denial.' }
                        Test-P4 "$kind metadata has a real own-file read denial" $denied
                    }
                    else {
                        [IO.File]::WriteAllText($metadata, $(if ($kind -eq 'codex') { '{"SessionId":' } else { 'summary: unknown cwd' }))
                    }
                    $outcome = Invoke-P4Cleanup $fixture $worktree
                    Test-P4 "$kind $mode state never authorizes deletion" `
                        ($outcome.TrackedContentPreserved -and $outcome.Removed -eq 0) $outcome
                }
                finally {
                    if ($null -ne $lock) { $lock.Dispose() }
                    Stop-P4Child $child
                    Remove-P4SessionFiles $files
                }
            }
        }
    }

    Invoke-P4Scenario 'unknown live process is not absence of workspace use' {
        $fixture = New-P4Fixture
        $worktree = New-P4Worktree $fixture
        Set-P4OldWorktree $worktree
        $child = Start-P4Child copilot $worktree ([guid]::NewGuid().ToString())
        try {
            $usage = Get-BridgeWorktreeUsage
            Test-P4 'a real unregistered live fixture process makes usage explicitly unknown' `
                (-not $usage.Known -and -not [string]::IsNullOrWhiteSpace($usage.Detail))
            $outcome = Invoke-P4Cleanup $fixture $worktree
            Test-P4 'unknown process ownership preserves the complete candidate' `
                ($outcome.Removed -eq 0 -and $outcome.TrackedContentPreserved) $outcome
        }
        finally { Stop-P4Child $child }
    }

    foreach ($mode in @('stale-process-identity', 'relative-working-directory')) {
        Invoke-P4Scenario "a registration with $mode cannot authorize cleanup" {
            $fixture = New-P4Fixture
            $worktree = New-P4Worktree $fixture
            Set-P4OldWorktree $worktree
            $id = [guid]::NewGuid().ToString()
            $child = Start-P4Child codex $worktree $id
            $files = @()
            try {
                $reported = if ($mode -eq 'relative-working-directory') { '.' } else { $fixture.Root }
                $files = @(New-P4SessionFiles codex $reported $id $child.Process.Id)
                if ($mode -eq 'stale-process-identity') {
                    $registration = @($files | Where-Object { $_.EndsWith('.json') })[0]
                    $entry = [IO.File]::ReadAllText($registration) | ConvertFrom-Json
                    $entry.Updated = [DateTimeOffset]::Now.AddDays(-2).ToString('o')
                    [IO.File]::WriteAllText($registration, ($entry | ConvertTo-Json -Depth 5))
                }
                $originalDirectory = [Environment]::CurrentDirectory
                try {
                    [Environment]::CurrentDirectory = $fixture.Root
                    $usage = Get-BridgeWorktreeUsage
                }
                finally { [Environment]::CurrentDirectory = $originalDirectory }
                Test-P4 "$mode is a real unknown-state boundary, not authoritative absence" (-not $usage.Known) $usage
            }
            finally { Stop-P4Child $child; Remove-P4SessionFiles $files }
        }
    }

    Invoke-P4Scenario 'actual metadata staging failure restores clean files' {
        $fixture = New-P4Fixture
        $worktree = New-P4Worktree $fixture
        Set-P4OldWorktree $worktree
        $pointer = Join-Path $worktree '.git'
        $admin = Split-Path (Get-BridgeWorktreeMarkerPath $worktree) -Parent
        $indexHash = (Get-FileHash -LiteralPath (Join-Path $admin 'index')).Hash
        $lock = $null
        $mode = $null
        try {
            if ($IsWindows) {
                $lock = [IO.File]::Open($pointer, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            }
            else {
                $mode = [IO.File]::GetUnixFileMode($fixture.WorktreeRoot)
                [IO.File]::SetUnixFileMode($fixture.WorktreeRoot, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserExecute)
                $probe = Join-Path $fixture.WorktreeRoot 'write-denial-probe'
                $denied = $false
                try { [IO.File]::WriteAllText($probe, 'probe') } catch [UnauthorizedAccessException] { $denied = $true }
                if (-not $denied) { throw 'The fixture account bypasses the intended parent-directory write denial.' }
            }
            $outcome = Invoke-P4Cleanup $fixture $worktree
            Test-P4 'a real metadata move failure preserves the tree and restores missing tracked files' `
                ($outcome.Removed -eq 0 -and $outcome.TrackedContentPreserved) $outcome
            Test-P4 'failed cleanup does not modify the real index' `
                ((Get-FileHash -LiteralPath (Join-Path $admin 'index')).Hash -eq $indexHash)
            Test-P4 'failed cleanup releases only its own Git locks' `
                (-not (Test-Path -LiteralPath (Join-Path $admin 'HEAD.lock')) -and
                    -not (Test-Path -LiteralPath (Join-Path $admin 'index.lock')))
        }
        finally {
            if ($null -ne $lock) { $lock.Dispose() }
            if ($null -ne $mode) { [IO.File]::SetUnixFileMode($fixture.WorktreeRoot, $mode) }
        }
    }

    Invoke-P4Scenario 'a live descendant reached through an alias protects its real tree' {
        $fixture = New-P4Fixture
        $worktree = New-P4Worktree $fixture
        Set-P4OldWorktree $worktree
        $alias = Join-Path $fixture.Root 'alias'
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $linkType -Path $alias -Target $worktree -ErrorAction Stop | Out-Null
        $id = [guid]::NewGuid().ToString()
        $child = Start-P4Child claude (Join-Path $worktree 'src\child') $id
        $files = @()
        try {
            $files = @(New-P4SessionFiles claude (Join-Path $alias 'src\child') $id $child.Process.Id)
            $usage = Get-BridgeWorktreeUsage
            Test-P4 'an actual directory alias gives known, matching descendant liveness' `
                ($usage.Known -and (Test-BridgeWorktreeInUse -WorktreePath $worktree -Usage $usage))
            $outcome = Invoke-P4Cleanup $fixture $worktree
            Test-P4 'the actual alias-backed live tree remains intact' `
                ($outcome.Removed -eq 0 -and $outcome.TrackedContentPreserved) $outcome
        }
        finally {
            Stop-P4Child $child
            Remove-P4SessionFiles $files
            Remove-Item -LiteralPath $alias -Force -ErrorAction Stop
        }
    }

    Invoke-P4Scenario 'reservation read failure and foreign ownership preserve the lock' {
        $fixture = New-P4Fixture
        $worktree = New-P4Worktree $fixture
        $reservation = New-BridgeWorktreeLaunchReservation -WorktreePath $worktree
        $lockPath = Join-Path (Split-Path (Get-BridgeWorktreeMarkerPath $worktree) -Parent) 'locked'
        $locked = [IO.File]::Open($lockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $denied = $false
            try { $null = [IO.File]::ReadAllText($lockPath) } catch [IO.IOException] { $denied = $true }
            if (-not $denied) { throw 'The own-file reservation lock did not deny a real read.' }
            $released = Remove-BridgeWorktreeLaunchReservation -Reservation $reservation
            Test-P4 'an actual unreadable reservation is not silently unlocked' (-not $released -and [IO.File]::Exists($lockPath))
        }
        finally { $locked.Dispose() }
        [IO.File]::WriteAllText($lockPath, 'operator-owned lock')
        $released = Remove-BridgeWorktreeLaunchReservation -Reservation $reservation
        Test-P4 'a changed operator-owned lock is never removed by the old launch reservation' `
            (-not $released -and [IO.File]::ReadAllText($lockPath) -ceq 'operator-owned lock')
        Test-P4 'a pre-existing operator lock is not claimed as a new launch reservation' `
            ($null -eq (New-BridgeWorktreeLaunchReservation -WorktreePath $worktree))
    }

    Invoke-P4Scenario 'late ignored data cannot be deleted by unattended cleanup' {
        $fixture = New-P4Fixture
        $origin = Join-Path $fixture.Root 'local-origin.git'
        $null = Invoke-P4Git $fixture.Root @('clone', '--quiet', '--bare', $script:P4Origin, $origin)
        $null = Invoke-P4Git $fixture.Repository @('remote', 'set-url', 'origin', $origin)
        $bulk = Join-Path $fixture.Repository 'src\window'
        [void][IO.Directory]::CreateDirectory($bulk)
        for ($index = 0; $index -lt 128; $index++) {
            [IO.File]::WriteAllText((Join-Path $bulk "$index.txt"), ('fixture content ' * 256))
        }
        $null = Invoke-P4Git $fixture.Repository @('add', 'src/window')
        $null = Invoke-P4Git $fixture.Repository @('commit', '--quiet', '-m', 'P4 concurrent cleanup fixture')
        $null = Invoke-P4Git $fixture.Repository @('push', '--quiet', 'origin', 'main')
        $worktree = New-P4Worktree $fixture
        Set-P4OldWorktree $worktree
        Add-Content -LiteralPath (Join-Path $fixture.Repository '.git\info\exclude') -Value 'ignored-data/'
        $admin = Split-Path (Get-BridgeWorktreeMarkerPath $worktree) -Parent
        $indexHash = (Get-FileHash -LiteralPath (Join-Path $admin 'index')).Hash
        $trace = Join-Path $fixture.Root 'git-trace.jsonl'
        [IO.File]::WriteAllText($trace, '')
        $late = Join-Path $worktree 'ignored-data\late.txt'
        $savedTrace = $env:GIT_TRACE2_EVENT
        $child = Start-P4Child -Kind writer -Directory $fixture.Root -SessionId ([guid]::NewGuid().ToString()) -WatchTrace $trace -WritePath $late
        try {
            $env:GIT_TRACE2_EVENT = $trace
            $outcome = Invoke-P4Cleanup $fixture $worktree
            $deadline = [DateTimeOffset]::Now.AddSeconds(5)
            while (-not [IO.File]::Exists($child.Written) -and [DateTimeOffset]::Now -lt $deadline) { Start-Sleep -Milliseconds 10 }
            if (-not [IO.File]::Exists($child.Written)) { throw 'The native writer did not observe the real tracked-file removal.' }
            if ($outcome.Removed -ne 0) { throw 'The writer did not reach the intended pre-rmdir window; no race-safety pass is claimed.' }
            Test-P4 'ignored data arriving after eligibility checks causes real nonrecursive removal refusal' `
                ($outcome.TrackedContentPreserved -and [IO.File]::Exists($late)) $outcome
            Test-P4 'late ignored user bytes survive unchanged' ([IO.File]::ReadAllText($late) -ceq 'late ignored user data')
            Test-P4 'late-data refusal never replaces the real Git index' `
                ((Get-FileHash -LiteralPath (Join-Path $admin 'index')).Hash -eq $indexHash)
            Test-P4 'the retained late file is really ignored by Git' `
                ((Invoke-BridgeGit -Directory $worktree -Arguments @('check-ignore', 'ignored-data/late.txt')).Ok)
        }
        finally {
            $env:GIT_TRACE2_EVENT = $savedTrace
            Stop-P4Child $child
        }
    }

    Invoke-P4Scenario 'another real process owns the repository operation gate' {
        $fixture = New-P4Fixture
        Set-P4Config $fixture @{ workspaces = @(@{ label = 'Approved'; path = $fixture.Repository; isolate = $true }) }
        $child = Start-P4MutexHolder $fixture
        try {
            Test-P4IsolationFailure -Name 'repository gate held by an actual child' -Fixture $fixture
        }
        finally { Stop-P4Child $child }
        $created = New-BridgeSessionWorktree -RepositoryPath $fixture.Repository
        Test-P4 'releasing the actual operation gate permits a separate worktree' `
            ($created.Isolated -and $created.Path -ne $fixture.Repository)
    }

    Invoke-P4Scenario 'failed cleanup never overwrites a new tracked-path file during restoration' {
        $fixture = New-P4Fixture
        $origin = Join-Path $fixture.Root 'restore-origin.git'
        $null = Invoke-P4Git $fixture.Root @('clone', '--quiet', '--bare', $script:P4Origin, $origin)
        $null = Invoke-P4Git $fixture.Repository @('remote', 'set-url', 'origin', $origin)
        $bulk = Join-Path $fixture.Repository 'src\restore-window'
        [void][IO.Directory]::CreateDirectory($bulk)
        for ($index = 0; $index -lt 128; $index++) {
            [IO.File]::WriteAllText((Join-Path $bulk "$index.txt"), ('restoration fixture ' * 256))
        }
        $null = Invoke-P4Git $fixture.Repository @('add', 'src/restore-window')
        $null = Invoke-P4Git $fixture.Repository @('commit', '--quiet', '-m', 'P4 restoration fixture')
        $null = Invoke-P4Git $fixture.Repository @('push', '--quiet', 'origin', 'main')
        $worktree = New-P4Worktree $fixture
        Set-P4OldWorktree $worktree
        $admin = Split-Path (Get-BridgeWorktreeMarkerPath $worktree) -Parent
        $indexHash = (Get-FileHash -LiteralPath (Join-Path $admin 'index')).Hash
        $trace = Join-Path $fixture.Root 'restore-trace.jsonl'
        [IO.File]::WriteAllText($trace, '')
        $savedTrace = $env:GIT_TRACE2_EVENT
        $lock = $null
        $mode = $null
        $child = $null
        try {
            if ($IsWindows) {
                $lock = [IO.File]::Open((Join-Path $worktree '.git'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            }
            else {
                $mode = [IO.File]::GetUnixFileMode($fixture.WorktreeRoot)
                [IO.File]::SetUnixFileMode($fixture.WorktreeRoot, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserExecute)
            }
            $child = Start-P4Child -Kind writer -Directory $fixture.Root -SessionId ([guid]::NewGuid().ToString()) `
                -WatchTrace $trace -WritePath (Join-Path $worktree 'tracked.txt') -WriteTrigger restore
            $env:GIT_TRACE2_EVENT = $trace
            $outcome = Invoke-P4Cleanup $fixture $worktree
            $deadline = [DateTimeOffset]::Now.AddSeconds(5)
            while (-not [IO.File]::Exists($child.Written) -and [DateTimeOffset]::Now -lt $deadline) { Start-Sleep -Milliseconds 10 }
            if (-not [IO.File]::Exists($child.Written)) { throw 'The native writer did not reach the actual restoration path.' }
            Test-P4 'real restoration refuses to overwrite a file created after tracked-file cleanup' `
                ($outcome.Removed -eq 0 -and ($outcome.Warnings -join ' ') -match 'already exists') $outcome
            Test-P4 'the newer tracked-path user bytes survive unchanged' `
                ([IO.File]::ReadAllText((Join-Path $worktree 'tracked.txt')) -ceq 'late ignored user data')
            Test-P4 'conflicted restoration still leaves the real index untouched' `
                ((Get-FileHash -LiteralPath (Join-Path $admin 'index')).Hash -eq $indexHash)
        }
        finally {
            $env:GIT_TRACE2_EVENT = $savedTrace
            if ($null -ne $child) { Stop-P4Child $child }
            if ($null -ne $lock) { $lock.Dispose() }
            if ($null -ne $mode) { [IO.File]::SetUnixFileMode($fixture.WorktreeRoot, $mode) }
        }
    }

    Invoke-P4Scenario 'a pending launch is protected until actual registration' {
        $fixture = New-P4Fixture
        Set-P4Config $fixture @{
            workspaces = @(@{ label = 'Approved'; path = $fixture.Repository; isolate = $true })
            worktreeIdleHours = 0
        }
        $outcome = Invoke-P4Launch
        if ($outcome.Calls.Count -ne 1 -or $null -eq $script:DaemonPendingLaunch) { throw 'The approved launch fixture did not start.' }
        $pending = $script:DaemonPendingLaunch
        $worktree = $outcome.Calls[0].Directory
        $marker = Get-BridgeWorktreeMarkerPath $worktree
        $lockPath = Join-Path (Split-Path $marker -Parent) 'locked'
        Set-P4OldWorktree $worktree
        $cleanup = Invoke-P4Cleanup $fixture $worktree
        Test-P4 'an unregistered launch has a real Git lock and survives cleanup' `
            ([IO.File]::Exists($lockPath) -and $cleanup.Removed -eq 0 -and $cleanup.TrackedContentPreserved)
        $child = Start-P4Child copilot $worktree $pending.SessionId
        $files = @()
        try {
            $files = @(New-P4SessionFiles copilot $worktree $pending.SessionId $child.Process.Id)
            Update-DaemonPendingLaunch -Headers $headers
            Test-P4 'actual registration releases the owned launch reservation through the real pending-launch consumer' `
                ($null -eq $script:DaemonPendingLaunch -and -not [IO.File]::Exists($lockPath))
            $cleanup = Invoke-P4Cleanup $fixture $worktree
            Test-P4 'the registered live session stays protected after its startup reservation is released' `
                ($cleanup.Removed -eq 0 -and $cleanup.TrackedContentPreserved)
        }
        finally { Stop-P4Child $child; Remove-P4SessionFiles $files }
        $cleanup = Invoke-P4Cleanup $fixture $worktree
        Test-P4 'the genuinely ended clean session can subsequently be cleaned up' `
            ($cleanup.Removed -eq 1 -and -not $cleanup.DirectoryPresent)
    }

    foreach ($mode in @('not-repository', 'limit', 'root-is-file', 'invalid-root', 'missing-git', 'unborn-head')) {
        Invoke-P4Scenario "requested isolation failure $mode" {
            $fixture = New-P4Fixture
            $target = $fixture.Repository
            $changes = @{}
            switch ($mode) {
                'not-repository' {
                    $target = Join-Path $fixture.Root 'plain'
                    [void][IO.Directory]::CreateDirectory($target)
                }
                'limit' {
                    $null = New-P4Worktree $fixture
                    $changes.worktreeLimit = 1
                }
                'root-is-file' { [IO.File]::WriteAllText($fixture.WorktreeRoot, 'not a directory') }
                'invalid-root' { $changes.worktreeRoot = $fixture.WorktreeRoot + [char]0 }
                'unborn-head' {
                    $target = Join-Path $fixture.Root 'unborn'
                    $null = Invoke-P4Git $fixture.Root @('init', '--quiet', '--initial-branch=main', $target)
                }
            }
            $changes.workspaces = @(@{ label = 'Approved'; path = $target; isolate = $true })
            Set-P4Config $fixture $changes
            $savedPath = $env:PATH
            try {
                if ($mode -eq 'missing-git') { $env:PATH = '' }
                Test-P4IsolationFailure -Name $mode -Fixture $fixture -RepositoryPath $target
            }
            finally { $env:PATH = $savedPath }
        }
    }

    Invoke-P4Scenario 'approved fresh launch controls' {
        $fixture = New-P4Fixture
        $plain = Invoke-P4Launch
        Test-P4 'explicitly configured nonisolated launch remains legitimate' `
            ($plain.Calls.Count -eq 1 -and $plain.Calls[0].Directory -eq $fixture.Repository) $plain
        Set-P4Config $fixture @{ workspaces = @(@{ label = 'Approved'; path = $fixture.Repository; isolate = $true }) }
        $isolated = Invoke-P4Launch
        $valid = $isolated.Calls.Count -eq 1 -and $isolated.Calls[0].Directory -ne $fixture.Repository
        if ($valid) {
            $valid = (Test-BridgeManagedWorktree $isolated.Calls[0].Directory) -and
                (Test-P4TreePreserved $isolated.Calls[0].Directory)
        }
        Test-P4 'approved isolated launch reaches native boundary in a real separate worktree' $valid $isolated
    }

    Invoke-P4Scenario 'isolating a configured subdirectory does not approve its parent' {
        $fixture = New-P4Fixture
        $approved = Join-Path $fixture.Repository 'src\child'
        Set-P4Config $fixture @{ workspaces = @(@{ label = 'Approved'; path = $approved; isolate = $true }) }
        $outcome = Invoke-P4Launch
        if ($outcome.Calls.Count -ne 1) { throw 'The configured committed subdirectory did not launch.' }
        $launched = $outcome.Calls[0].Directory
        $top = Invoke-P4Git $launched @('rev-parse', '--show-toplevel')
        $corresponding = Join-Path $top 'src\child'
        Test-P4 'the actual isolated launch keeps the approved relative directory' `
            (Test-BridgeInstallPath -Left (Resolve-BridgeWorkspaceDirectory $launched) -Right (Resolve-BridgeWorkspaceDirectory $corresponding)) $outcome
        Test-P4 'approval of a subdirectory never authorizes its generated parent root' `
            (-not (Test-BridgeWorkspacePathApproved -Path $top))
        Test-P4 'the corresponding managed subdirectory remains an approved resume target' `
            (Test-BridgeWorkspacePathApproved -Path $corresponding)
    }

    Invoke-P4Scenario 'an approved subdirectory missing from the base refuses fallback' {
        $fixture = New-P4Fixture
        $approved = Join-Path $fixture.Repository 'local-only'
        [void][IO.Directory]::CreateDirectory($approved)
        [IO.File]::WriteAllText((Join-Path $approved 'user.txt'), 'local uncommitted data')
        Set-P4Config $fixture @{ workspaces = @(@{ label = 'Approved'; path = $approved; isolate = $true }) }
        Test-P4IsolationFailure -Name 'approved subdirectory absent from base' -Fixture $fixture -RepositoryPath $approved
        Test-P4 'the source subdirectory and its uncommitted bytes remain intact' `
            ([IO.File]::ReadAllText((Join-Path $approved 'user.txt')) -ceq 'local uncommitted data')
    }

    foreach ($mode in @('empty', 'missing-setting', 'invalid-target', 'discovered-only', 'discovered-extra')) {
        Invoke-P4Scenario "workspace approval $mode" {
            $fixture = New-P4Fixture
            $outside = Join-Path $fixture.Root 'unapproved'
            [void][IO.Directory]::CreateDirectory($outside)
            $changes = @{ workspaces = @() }
            $files = @()
            try {
                if ($mode -eq 'missing-setting') { $changes.workspaces = $null }
                elseif ($mode -eq 'invalid-target') { $changes.workspaces = @(Join-Path $fixture.Root 'missing') }
                elseif ($mode -like 'discovered-*') {
                    if (Test-BridgeSystemDirectory $fixture.Root) {
                        Write-Host "  SKIP ${mode}: the actual system-directory filter excludes this sandbox."
                        return
                    }
                    $changes.discoverWorkspaces = $true
                    $files = @(New-P4SessionFiles claude $outside ([guid]::NewGuid().ToString()))
                    if ($mode -eq 'discovered-extra') {
                        $changes.workspaces = @(@{ label = 'Approved'; path = $fixture.Repository })
                    }
                }
                Set-P4Config $fixture $changes
                $choices = @(Get-BridgeWorkspaceChoices)
                $permitted = @($choices | Where-Object Path -ne $fixture.Repository)
                Test-P4 "${mode}: actual executable choices contain no unapproved fallback" ($permitted.Count -eq 0) $choices
                $script:P4States[$script:DaemonEntity.NewWorkspace] = if ($mode -like 'discovered-*') { 'unapproved' } else { 'unknown' }
                $outcome = Invoke-P4Launch
                Test-P4 "${mode}: actual resolver and caller do not execute an unapproved directory" `
                    ($outcome.Calls.Count -eq 0 -and -not $outcome.Pending) $outcome
            }
            finally { Remove-P4SessionFiles $files }
        }
    }

    Invoke-P4Scenario 'stale and tampered workspace choices' {
        $fixture = New-P4Fixture
        $script:P4States[$script:DaemonEntity.NewWorkspace] = 'not an approved label'
        $unknown = Invoke-P4Launch
        Test-P4 'an unknown external workspace label is still refused' `
            ($unknown.Calls.Count -eq 0 -and ($unknown.Messages -join ' ') -match 'Unknown workspace') $unknown
        Set-P4Config $fixture
        $controls = Get-P4Controls
        $request = Resolve-DaemonLaunchRequest -Controls $controls -Headers $headers
        if ($null -eq $request) { throw 'Approved fixture request unexpectedly failed to resolve.' }
        Set-P4Config $fixture @{ workspaces = @() }
        $outcome = Invoke-P4Launch -Request $request
        Test-P4 'revocation after real resolution is rechecked at the actual launch consumer' `
            ($outcome.Calls.Count -eq 0 -and -not $outcome.Pending) $outcome
        Set-P4Config $fixture
        $request = Resolve-DaemonLaunchRequest -Controls (Get-P4Controls) -Headers $headers
        $tampered = Join-Path $fixture.Root 'tampered'
        [void][IO.Directory]::CreateDirectory($tampered)
        $request.Directory = $tampered
        $outcome = Invoke-P4Launch -Request $request
        Test-P4 'a configured label cannot authorize a different request directory' `
            ($outcome.Calls.Count -eq 0 -and -not $outcome.Pending) $outcome
    }

    foreach ($kind in @('copilot', 'claude', 'codex')) {
        Invoke-P4Scenario "$kind real historical resume approval" {
            $fixture = New-P4Fixture
            $outside = Join-Path $fixture.Root 'history'
            [void][IO.Directory]::CreateDirectory($outside)
            $id = [guid]::NewGuid().ToString()
            $files = @(New-P4SessionFiles $kind $outside $id)
            try {
                Set-P4Config $fixture @{ workspaces = @(
                    @{ label = 'Approved'; path = $fixture.Repository }
                    @{ label = 'History'; path = $outside }
                ) }
                $offered = @(Get-BridgeResumableSessions | Where-Object SessionId -eq $id)
                if ($offered.Count -ne 1) { throw 'Actual historical session reader did not return the fixture.' }
                $label = $offered[0].Label
                $script:P4States[$script:DaemonEntity.NewResume] = $label
                $approved = Invoke-P4Launch
                Test-P4 "${kind}: approved historical resume remains legitimate" `
                    ($approved.Calls.Count -eq 1 -and $approved.Calls[0].Resume -and $approved.Calls[0].Directory -eq $outside) $approved
                Set-P4Config $fixture
                $controls = Get-P4Controls
                Test-P4 "${kind}: revoked history is not executable in the actual resume list" `
                    (@($controls.Resumable | Where-Object SessionId -eq $id).Count -eq 0)
                $script:P4States[$script:DaemonEntity.NewResume] = $label
                $outcome = Invoke-P4Launch -Controls $controls
                Test-P4 "${kind}: actual resume consumer refuses the revoked target" `
                    ($outcome.Calls.Count -eq 0 -and -not $outcome.Pending) $outcome
            }
            finally { Remove-P4SessionFiles $files }
        }
    }

    Invoke-P4Scenario 'managed-worktree resume and missing-directory controls' {
        $fixture = New-P4Fixture
        $worktree = New-P4Worktree $fixture
        $id = [guid]::NewGuid().ToString()
        $files = @(New-P4SessionFiles copilot $worktree $id)
        try {
            Set-P4Config $fixture @{ workspaces = @(@{ label = 'Approved'; path = $fixture.Repository; isolate = $true }) }
            $resume = @(Get-BridgeResumableSessions | Where-Object SessionId -eq $id)[0]
            $script:P4States[$script:DaemonEntity.NewResume] = $resume.Label
            $outcome = Invoke-P4Launch
            Test-P4 'a managed worktree of the approved repository can resume in place' `
                ($outcome.Calls.Count -eq 1 -and $outcome.Calls[0].Resume -and $outcome.Calls[0].Directory -eq $worktree) $outcome
            $request = Resolve-DaemonLaunchRequest -Controls (Get-P4Controls) -Headers $headers
            Rename-Item -LiteralPath $worktree -NewName 'moved-fixture-worktree'
            $outcome = Invoke-P4Launch -Request $request
            Test-P4 'a disappeared resume directory never silently retargets the primary checkout' `
                ($outcome.Calls.Count -eq 0 -and -not $outcome.Pending) $outcome
        }
        finally { Remove-P4SessionFiles $files }
    }
}
catch {
    $script:P4FixtureErrors++
    Write-Host "  FIXTURE ERROR suite setup or teardown: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
}
finally {
    foreach ($child in @($script:P4Children.ToArray())) {
        try { Stop-P4Child $child }
        catch { $script:P4FixtureErrors++; Write-Host "  FIXTURE ERROR child cleanup: $($_.Exception.Message)" }
    }
    [IO.File]::WriteAllText($env:AGENT_HA_BRIDGE_CONFIG, $script:P4OriginalConfig)
}

Write-Host "P4 product assertion failures: $script:P4Failures; fixture errors: $script:P4FixtureErrors"
if ($script:P4FixtureErrors) { exit 2 }
if ($script:P4Failures) { exit 1 }
exit 0
