#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the `agent-ha-bridge` command and the installer payload behind it.

.DESCRIPTION
    Reconfiguring an install used to mean re-running install.ps1 with arguments, which
    only worked if you still had the clone. Everyone who used the one-liner had nothing
    left to re-run, and bootstrap.ps1 takes no arguments. The installer now leaves a
    copy of itself in ~/.agent-ha-bridge/installer and an `agent-ha-bridge` command on
    PATH that dispatches to it.

    The dangerous part of testing this is that the machine running the tests usually
    has a real install. So:

      * the end-to-end install runs with -TargetHome, -SkipTask, -SkipPath,
        -SkipDependencies and -NonInteractive, which keeps it out of $HOME, the
        scheduled task, the user PATH and every package manager;
      * only the Copilot client is selected - the Codex adapter registers a plugin with
        the real `codex` binary and the MCP one can write to Claude Desktop, neither of
        which honours -TargetHome;
      * the command's own dispatch is checked against a fake payload whose install.ps1
        records its arguments instead of installing anything;
      * the user PATH and the real bridge root are compared before and after.

    install.ps1 is dot-sourced with BRIDGE_INSTALL_NORUN set so its functions load
    without running the install.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$env:BRIDGE_INSTALL_NORUN = '1'
. (Join-Path $repoRoot 'install.ps1')
Remove-Item Env:\BRIDGE_INSTALL_NORUN -ErrorAction SilentlyContinue

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

function New-ScratchDir {
    $path = Join-Path $env:TEMP ('bridge-cli-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $path
}

Write-Host '--- the installer payload ---'
$payloadRoot = New-ScratchDir
try {
    $count = Copy-BridgeInstallerPayload -RepoRoot $repoRoot -Destination $payloadRoot
    Test-That 'it reports what it copied' { $count -gt 0 }
    # Deliberately not $name: Test-That has a $Name parameter, and an assertion
    # scriptblock resolves free variables dynamically in the caller's scope, so a
    # loop variable called $name would silently become the test's own title.
    foreach ($payloadFile in @('install.ps1', 'uninstall.ps1', 'update.ps1', 'config.example.json', 'VERSION')) {
        Test-That "$payloadFile is in the payload" { Test-Path -LiteralPath (Join-Path $payloadRoot $payloadFile) }
    }
    Test-That 'the shared hooks are in the payload' {
        Test-Path -LiteralPath (Join-Path $payloadRoot 'hooks\agent-bridge-daemon.ps1')
    }
    Test-That 'the command itself is in the payload' {
        Test-Path -LiteralPath (Join-Path $payloadRoot 'bin\agent-ha-bridge.cmd')
    }
    foreach ($adapter in @('claude\install-claude.ps1', 'codex\install-codex.ps1', 'mcp\install-mcp.ps1')) {
        Test-That "$(Split-Path $adapter -Leaf) is in the payload, so configure can add that client later" {
            Test-Path -LiteralPath (Join-Path $payloadRoot $adapter)
        }
    }
    Test-That 'node_modules is never copied' {
        -not (Test-Path -LiteralPath (Join-Path $payloadRoot 'mcp\node_modules'))
    }
    Test-That 'a second copy clears a file that upstream deleted' {
        $orphan = Join-Path $payloadRoot 'left-behind.ps1'
        Set-Content -LiteralPath $orphan -Value '# stale' -Encoding UTF8
        [void](Copy-BridgeInstallerPayload -RepoRoot $repoRoot -Destination $payloadRoot)
        -not (Test-Path -LiteralPath $orphan)
    }
    # `configure` runs the installer from the payload, so source and destination are
    # the same folder - which used to be cleared, taking the whole payload with it.
    $again = Copy-BridgeInstallerPayload -RepoRoot "$payloadRoot\" -Destination $payloadRoot
    Test-That 'copying the payload onto itself leaves it intact' {
        $again -gt 0 -and (Test-Path -LiteralPath (Join-Path $payloadRoot 'bin\agent-ha-bridge.ps1')) -and
            (Test-Path -LiteralPath (Join-Path $payloadRoot 'install.ps1'))
    }
}
finally { Remove-Item -LiteralPath $payloadRoot -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host '--- installing the command ---'
$binRoot = New-ScratchDir
try {
    $cmd = Install-BridgeCommand -RepoRoot $repoRoot -BinDir $binRoot
    Test-That 'the shim exists' { Test-Path -LiteralPath $cmd }
    Test-That 'the dispatcher exists beside it' {
        Test-Path -LiteralPath (Join-Path $binRoot 'agent-ha-bridge.ps1')
    }
    if ($script:BridgeIsWindows) {
        Test-That 'it returns the .cmd shim, which is what goes on PATH' {
            $cmd -eq (Join-Path $binRoot 'agent-ha-bridge.cmd')
        }
        Test-That 'the shim calls the dispatcher next to itself, not an absolute path' {
            (Get-Content -LiteralPath $cmd -Raw) -match '%~dp0agent-ha-bridge\.ps1'
        }
        Test-That 'the shim falls back to the default pwsh location' {
            (Get-Content -LiteralPath $cmd -Raw) -match 'PowerShell\\7\\pwsh\.exe'
        }
    }
    else {
        Test-That 'it returns the shell shim, which is what goes on PATH' {
            $cmd -eq (Join-Path $binRoot 'agent-ha-bridge')
        }
        Test-That 'the shim is executable' {
            ([IO.File]::GetUnixFileMode($cmd) -band [IO.UnixFileMode]::UserExecute) -ne 0
        }
        Test-That 'the shim runs the dispatcher next to itself' {
            (Get-Content -LiteralPath $cmd -Raw) -match '\$dir/agent-ha-bridge\.ps1'
        }
        Test-That 'the shim looks for pwsh where Homebrew puts it' {
            (Get-Content -LiteralPath $cmd -Raw) -match '/opt/homebrew/bin/pwsh'
        }
        Test-That 'the shim runs the command' { $null = & $cmd version 2>&1; $LASTEXITCODE -eq 0 }
    }
    Test-That 'installing again is a no-op that still succeeds' {
        [void](Install-BridgeCommand -RepoRoot $repoRoot -BinDir $binRoot)
        Test-Path -LiteralPath $cmd
    }
}
finally { Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host '--- the command dispatches to the payload ---'
# A fake payload, so `configure`, `update` and `uninstall` can be driven without any
# of them actually running. The stubs declare the real parameter names on purpose:
# a stub using ValueFromRemainingArguments would swallow anything and hide the
# difference between a named argument and a positional one.
$fakeHome = New-ScratchDir
try {
    $fakeBin = Join-Path $fakeHome 'bin'
    $fakeInstaller = Join-Path $fakeHome 'installer'
    New-Item -ItemType Directory -Path $fakeInstaller -Force | Out-Null
    [void](Install-BridgeCommand -RepoRoot $repoRoot -BinDir $fakeBin)
    $record = Join-Path $fakeHome 'invoked.txt'

    Set-Content -LiteralPath (Join-Path $fakeInstaller 'install.ps1') -Encoding UTF8 -Value @"
param([string]`$HomeAssistantUrl, [string[]]`$Clients, [switch]`$NonInteractive)
Add-Content -LiteralPath '$record' -Value ("install url=[`$HomeAssistantUrl] clients=[" +
    (@(`$Clients) -join ',') + "] nonInteractive=[`$NonInteractive]")
"@
    Set-Content -LiteralPath (Join-Path $fakeInstaller 'update.ps1') -Encoding UTF8 -Value @"
param([switch]`$Check, [switch]`$Force, [switch]`$Yes)
Add-Content -LiteralPath '$record' -Value "update check=[`$Check] force=[`$Force]"
"@
    Set-Content -LiteralPath (Join-Path $fakeInstaller 'uninstall.ps1') -Encoding UTF8 -Value @"
param([switch]`$KeepConfig, [switch]`$ClearEntities, [string]`$TargetHome)
Add-Content -LiteralPath '$record' -Value ("uninstall keepConfig=[`$KeepConfig] " +
    "clearEntities=[`$ClearEntities] targetHome=[`$TargetHome]")
"@
    Set-Content -LiteralPath (Join-Path $fakeInstaller 'VERSION') -Value '9.9.9' -Encoding UTF8
    $fakeCli = Join-Path $fakeBin 'agent-ha-bridge.ps1'

    function Invoke-Cli {
        param([string[]]$CliArgs)
        Remove-Item -LiteralPath $record -Force -ErrorAction SilentlyContinue
        $null = & pwsh -NoProfile -File $fakeCli @CliArgs 2>&1
        if (Test-Path -LiteralPath $record) { (Get-Content -LiteralPath $record -Raw).Trim() } else { '' }
    }

    $out = & pwsh -NoProfile -File $fakeCli version 2>&1
    Test-That 'version reads the payload it was installed from, not $HOME' {
        ($out -join '') -match '9\.9\.9'
    }

    Test-That 'configure runs the payload installer' { (Invoke-Cli @('configure')) -match '^install ' }
    Test-That 'configure passes arguments as named parameters, not positionally' {
        # The bug this pins down: `& $script @array` splats positionally, so -Clients
        # would have been bound to the installer's first positional parameter.
        (Invoke-Cli @('configure', '-Clients', 'copilot,claude')) -eq 'install url=[] clients=[copilot,claude] nonInteractive=[False]'
    }
    Test-That 'a switch passed through stays a switch' {
        (Invoke-Cli @('configure', '-NonInteractive')) -match 'nonInteractive=\[True\]'
    }
    Test-That 'a genuine positional argument still works' {
        (Invoke-Cli @('configure', 'http://ha.test:8123')) -match 'url=\[http://ha\.test:8123\]'
    }

    foreach ($alias in @('--configure', '-configure', '/configure', 'reconfigure')) {
        Test-That "'$alias' reaches the installer too" { (Invoke-Cli @($alias)) -match '^install ' }
    }

    Test-That 'update runs the payload updater with its switch intact' {
        (Invoke-Cli @('update', '-Check')) -eq 'update check=[True] force=[False]'
    }
    Test-That 'uninstall passes -KeepConfig as a switch, not as a target directory' {
        (Invoke-Cli @('uninstall', '-KeepConfig')) -eq 'uninstall keepConfig=[True] clearEntities=[False] targetHome=[]'
    }
    Test-That 'a bare uninstall clears the Home Assistant entities by default' {
        (Invoke-Cli @('uninstall')) -match 'clearEntities=\[True\]'
    }

    $out = & pwsh -NoProfile -File $fakeCli help 2>&1
    Test-That 'help lists configure' { ($out -join "`n") -match 'configure' }
    Test-That 'help exits cleanly' { $LASTEXITCODE -eq 0 }

    $out = & pwsh -NoProfile -File $fakeCli wibble 2>&1
    Test-That 'an unknown command fails with a non-zero exit code' { $LASTEXITCODE -eq 2 }
    Test-That 'an unknown command still shows the help' { ($out -join "`n") -match 'Usage' }

    Test-That 'a failing script propagates its exit code' {
        Set-Content -LiteralPath (Join-Path $fakeInstaller 'update.ps1') -Value 'exit 3' -Encoding UTF8
        $null = & pwsh -NoProfile -File $fakeCli update 2>&1
        $LASTEXITCODE -eq 3
    }

    Test-That 'a payload without an installer says how to repair it' {
        Remove-Item -LiteralPath (Join-Path $fakeInstaller 'install.ps1') -Force
        $result = & pwsh -NoProfile -File $fakeCli configure 2>&1
        ($result -join "`n") -match 'bootstrap\.ps1'
    }
}
finally { Remove-Item -LiteralPath $fakeHome -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host '--- the frontend card check reaches the console ---'
# `& $pwsh ...` makes a native child's stdout this function's output, so a caller
# writing [void](...) throws away everything it printed - which is the entire point of
# running it. The installer did exactly that: "Checking the dashboard frontend cards"
# appeared with nothing under it.
$cardHooks = New-ScratchDir
try {
    Set-Content -LiteralPath (Join-Path $cardHooks 'bridge-frontend-cards.ps1') -Encoding UTF8 -Value @'
param([switch]$Register, [switch]$Json, [switch]$Quiet)
Write-Host "CARD-CHECK-RAN register=$Register config=$env:AGENT_HA_BRIDGE_CONFIG"
'@
    $marker = Join-Path $cardHooks 'pretend-config.json'
    $captured = (Invoke-BridgeFrontendCardCheck -HooksDir $cardHooks -ConfigPath $marker -Register 6>&1) |
        Out-String

    Test-That 'the check actually runs' { $captured -match 'CARD-CHECK-RAN' }
    Test-That '-Register is passed through' { $captured -match 'register=True' }
    Test-That 'it is pointed at the config this install wrote' {
        $captured -match [regex]::Escape($marker)
    }
    Test-That 'the return value is a bool, not the child output' {
        (Invoke-BridgeFrontendCardCheck -HooksDir $cardHooks -ConfigPath $marker) -is [bool]
    }
    Test-That 'a missing checker is not an error' {
        (Invoke-BridgeFrontendCardCheck -HooksDir (New-ScratchDir) -ConfigPath $marker) -eq $false
    }
    Test-That 'AGENT_HA_BRIDGE_CONFIG is not left set afterwards' {
        [string]::IsNullOrEmpty($env:AGENT_HA_BRIDGE_CONFIG)
    }
}
finally { Remove-Item -LiteralPath $cardHooks -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host '--- status hands the configured token to the connection check ---'# The bug this pins down: `status` dot-sources install.ps1 to borrow its connection
# check, and dot-sourcing a script rebinds every parameter that script *declares* to
# that parameter's default. install.ps1 declares -Token, so a perfectly good token
# read from the config was blanked on the way in and status reported "no token".
$statusHome = New-ScratchDir
try {
    $statusBin = Join-Path $statusHome 'bin'
    $statusInstaller = Join-Path $statusHome 'installer'
    New-Item -ItemType Directory -Path $statusInstaller -Force | Out-Null
    [void](Install-BridgeCommand -RepoRoot $repoRoot -BinDir $statusBin)

    # A stand-in installer that declares the same parameters as the real one - that is
    # the whole point - and reports what the check was actually handed.
    Set-Content -LiteralPath (Join-Path $statusInstaller 'install.ps1') -Encoding UTF8 -Value @'
[CmdletBinding()]
param(
    [string]$HomeAssistantUrl, [string]$Token, [string]$NotifyService, [string]$TickerCategory,
    [string]$TargetHome, [string[]]$Clients, [switch]$SkipVerify, [switch]$SkipDependencies,
    [switch]$SkipPath, [switch]$NonInteractive, [switch]$SkipTask
)
function Test-BridgeHomeAssistantConnection {
    param([AllowEmptyString()][AllowNull()][string]$BaseUrl, [AllowEmptyString()][AllowNull()][string]$Token, [int]$TimeoutSec = 15)
    [pscustomobject]@{ Ok = $true; BaseUrl = $BaseUrl; TokenLength = ([string]$Token).Length }
}
function Write-BridgeConnectionResult {
    param($Result)
    Write-Host "SAW url=$($Result.BaseUrl) tokenLength=$($Result.TokenLength)"
}
if ($env:BRIDGE_INSTALL_NORUN) { return }
'@
    @{
        homeAssistant = @{ baseUrl = 'http://ha.test:8123'; token = 'abcdefghij'; tokenEnvVar = 'AGENT_HA_TOKEN' }
        clients       = @('copilot')
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $statusHome 'config.json') -Encoding UTF8

    $statusOut = (& pwsh -NoProfile -File (Join-Path $statusBin 'agent-ha-bridge.ps1') status 2>&1) -join "`n"
    Test-That 'the configured token reaches the connection check intact' {
        $statusOut -match 'tokenLength=10'
    }
    Test-That 'the configured URL reaches it too' { $statusOut -match 'url=http://ha\.test:8123' }
    Test-That 'status reads the config beside the command, not the one in $HOME' {
        # The leaf, not the whole path: a GitHub runner hands out $env:TEMP in 8.3
        # short form while the child resolves it long, so the strings differ even
        # though they are the same directory. The GUID is unique either way.
        $statusOut -match [regex]::Escape((Split-Path $statusHome -Leaf))
    }
    Test-That 'status lists the configured clients' { $statusOut -match 'clients\s*:\s*copilot' }
}
finally { Remove-Item -LiteralPath $statusHome -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host '--- an end-to-end install, sandboxed away from the real one ---'
$sandbox = New-ScratchDir
$pathBefore = Get-BridgeUserPath
$realBridgeHome = Join-Path $HOME '.agent-ha-bridge'
$realConfig = Join-Path $realBridgeHome 'config.json'
$realConfigBefore = if (Test-Path -LiteralPath $realConfig) {
    (Get-FileHash -LiteralPath $realConfig -Algorithm SHA256).Hash
} else { 'absent' }
$sandboxArpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AgentHaBridge_Sandbox'

try {
    $log = & pwsh -NoProfile -File (Join-Path $repoRoot 'install.ps1') `
        -TargetHome $sandbox -SkipTask -SkipPath -SkipDependencies -SkipVerify -NonInteractive `
        -Clients copilot -HomeAssistantUrl 'http://ha.invalid:8123' 2>&1
    $logText = $log -join "`n"
    $sandboxHome = Join-Path $sandbox '.agent-ha-bridge'

    Test-That 'the install succeeds' { $LASTEXITCODE -eq 0 }
    Test-That 'the command is installed' {
        Test-Path -LiteralPath (Join-Path $sandboxHome $(if ($script:BridgeIsWindows) { 'bin\agent-ha-bridge.cmd' } else { 'bin/agent-ha-bridge' }))
    }
    Test-That 'the installer payload is installed' {
        Test-Path -LiteralPath (Join-Path $sandboxHome 'installer\install.ps1')
    }
    Test-That 'the payload carries the adapters, so configure can add a client later' {
        Test-Path -LiteralPath (Join-Path $sandboxHome 'installer\claude\install-claude.ps1')
    }
    Test-That 'the hooks are installed' {
        Test-Path -LiteralPath (Join-Path $sandboxHome 'hooks\agent-bridge-daemon.ps1')
    }
    Test-That 'the config records the client that was asked for' {
        $written = Get-Content -LiteralPath (Join-Path $sandboxHome 'config.json') -Raw | ConvertFrom-Json
        (@($written.clients) -join ',') -eq 'copilot'
    }
    Test-That 'the Copilot hook definition is written inside the sandbox' {
        Test-Path -LiteralPath (Join-Path $sandbox '.copilot\hooks\decision-notifier.json')
    }
    Test-That 'it explains that PATH was left alone' { $logText -match 'Leaving PATH alone' }
    Test-That 'it points at the agent-ha-bridge command at the end' {
        $logText -match 'agent-ha-bridge configure'
    }

    Write-Host '--- and it left the real install alone ---'
    Test-That 'the user PATH is unchanged' { (Get-BridgeUserPath) -eq $pathBefore }
    Test-That "the real install's config is untouched" {
        $after = if (Test-Path -LiteralPath $realConfig) {
            (Get-FileHash -LiteralPath $realConfig -Algorithm SHA256).Hash
        } else { 'absent' }
        $after -eq $realConfigBefore
    }
    # Apps & features is Windows-only.
    if ($script:BridgeIsWindows) {
    Test-That 'it registered under the sandbox uninstall key, not the real one' {
        Test-Path -LiteralPath $sandboxArpKey
    }
    Test-That 'the Apps & features entry pauses so its window can be read' {
        # Windows gives that command its own console and closes it the instant the
        # script ends, so without this every warning and any failure flashes past.
        [string](Get-ItemProperty -LiteralPath $sandboxArpKey).UninstallString -match '\s-Pause\b'
    }
    Test-That 'the quiet entry does not, so an unattended uninstall cannot hang' {
        # winget uses this one and has nobody to press a key.
        [string](Get-ItemProperty -LiteralPath $sandboxArpKey).QuietUninstallString -notmatch '\s-Pause\b'
    }
    Test-That 'both still uninstall the sandbox rather than the real install' {
        $arp = Get-ItemProperty -LiteralPath $sandboxArpKey
        ([string]$arp.UninstallString -match '-TargetHome') -and
        ([string]$arp.QuietUninstallString -match '-TargetHome')
    }
    }

    Write-Host '--- the installed command reports on the install it came from ---'
    $status = & pwsh -NoProfile -File (Join-Path $sandboxHome 'bin\agent-ha-bridge.ps1') version 2>&1
    $expected = (Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw).Trim()
    Test-That 'version matches the VERSION file' { ($status -join '') -match [regex]::Escape($expected) }

    Write-Host '--- uninstalling the sandbox ---'
    $uninstallLog = & pwsh -NoProfile -File (Join-Path $repoRoot 'uninstall.ps1') -TargetHome $sandbox 2>&1
    Test-That 'the sandbox uninstall succeeds' { $LASTEXITCODE -eq 0 }
    Test-That 'it leaves PATH alone for a sandbox' { ($uninstallLog -join "`n") -match 'Leaving PATH alone' }
    Test-That 'the sandbox bridge root is gone' { -not (Test-Path -LiteralPath $sandboxHome) }
    Test-That 'the user PATH is still untouched after uninstalling' { (Get-BridgeUserPath) -eq $pathBefore }
    Test-That "the real install's config is still untouched" {
        $after = if (Test-Path -LiteralPath $realConfig) {
            (Get-FileHash -LiteralPath $realConfig -Algorithm SHA256).Hash
        } else { 'absent' }
        $after -eq $realConfigBefore
    }
}
finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sandboxArpKey -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '--- upgrading a pre-rename config in place ---'
# Two values in a pre-rename config point at the old name. The dashboard slug is
# cosmetic; the update repository decides what the self-updater downloads and runs,
# and it resolves today only because GitHub redirects a renamed repository.
$legacy = New-ScratchDir
try {
    $legacyBridge = Join-Path $legacy '.agent-ha-bridge'
    New-Item -ItemType Directory -Path $legacyBridge -Force | Out-Null
    @{
        homeAssistant = @{ baseUrl = 'http://ha.invalid:8123'; token = 'kept'; tokenEnvVar = 'AGENT_HA_TOKEN' }
        dashboard     = @{ urlPath = 'copilot-decisions' }
        clients       = @('copilot')
        updates       = @{ repository = 'danswett/copilot-ha-bridge'; installedVersion = '1.2.0'; checkForUpdates = $true }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $legacyBridge 'config.json') -Encoding UTF8

    $null = & pwsh -NoProfile -File (Join-Path $repoRoot 'install.ps1') `
        -TargetHome $legacy -SkipTask -SkipPath -SkipDependencies -SkipVerify -NonInteractive 2>&1
    $after = Get-Content -LiteralPath (Join-Path $legacyBridge 'config.json') -Raw | ConvertFrom-Json

    Test-That 'the update repository is corrected' {
        $after.updates.repository -eq 'danswett/agent-ha-bridge'
    }
    Test-That 'the dashboard slug is corrected' { $after.dashboard.urlPath -eq 'agent-decisions' }
    Test-That 'the token survives the upgrade' { $after.homeAssistant.token -eq 'kept' }
    Test-That 'the remembered client selection survives' { (@($after.clients) -join ',') -eq 'copilot' }
    Test-That 'the recorded version is brought up to date' {
        $after.updates.installedVersion -eq (Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw).Trim()
    }
}
finally {
    Remove-Item -LiteralPath $legacy -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sandboxArpKey -Recurse -Force -ErrorAction SilentlyContinue
}

Test-That 'a fork is not rewritten' {
    $fork = New-ScratchDir
    try {
        $forkBridge = Join-Path $fork '.agent-ha-bridge'
        New-Item -ItemType Directory -Path $forkBridge -Force | Out-Null
        @{
            homeAssistant = @{ baseUrl = 'http://ha.invalid:8123'; token = 't'; tokenEnvVar = 'AGENT_HA_TOKEN' }
            updates       = @{ repository = 'someone/their-fork'; installedVersion = '1.0.0'; checkForUpdates = $true }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $forkBridge 'config.json') -Encoding UTF8
        $null = & pwsh -NoProfile -File (Join-Path $repoRoot 'install.ps1') `
            -TargetHome $fork -SkipTask -SkipPath -SkipDependencies -SkipVerify -NonInteractive 2>&1
        (Get-Content -LiteralPath (Join-Path $forkBridge 'config.json') -Raw | ConvertFrom-Json).updates.repository -eq 'someone/their-fork'
    }
    finally {
        Remove-Item -LiteralPath $fork -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $sandboxArpKey -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host '--- the prompts people actually see, driven through stdin ---'# Read-Host reads redirected stdin, so the interactive path can be exercised for real
# rather than only through its injectable seams. -HomeAssistantUrl keeps both of these
# off the network.
function Invoke-SandboxInstall {
    param([string]$Answers, [string[]]$ExtraArgs)
    $box = New-ScratchDir
    $installArgs = @(
        '-NoProfile', '-File', (Join-Path $repoRoot 'install.ps1'),
        '-TargetHome', $box, '-SkipTask', '-SkipPath', '-SkipDependencies'
    ) + $ExtraArgs
    $output = $Answers | & pwsh @installArgs 2>&1
    [pscustomobject]@{
        Root   = $box
        Home   = Join-Path $box '.agent-ha-bridge'
        Exit   = $LASTEXITCODE
        Output = ($output -join "`n")
    }
}

$run = Invoke-SandboxInstall -Answers "1`n" -ExtraArgs @('-SkipVerify', '-HomeAssistantUrl', 'http://ha.example:8123')
try {
    # The bug: config.example.json shipped a clients list, the persisted branch fired
    # on a first install, and this question was never asked.
    Test-That 'a first install actually asks which clients to configure' {
        $run.Output -match 'Which clients should the bridge configure'
    }
    Test-That 'the numbered answer is honoured' { $run.Output -match 'Configuring: GitHub Copilot CLI' }
    Test-That 'it does not silently configure something else as well' {
        $run.Output -notmatch 'Configuring:.*(Claude Code|Codex)'
    }
    Test-That 'the answer is what lands in the config' {
        $written = Get-Content -LiteralPath (Join-Path $run.Home 'config.json') -Raw | ConvertFrom-Json
        (@($written.clients) -join ',') -eq 'copilot'
    }
    Test-That 'a supplied URL is never re-asked' { $run.Output -notmatch 'Home Assistant URL \[' }
    Test-That 'the install succeeds' { $run.Exit -eq 0 }
}
finally {
    Remove-Item -LiteralPath $run.Root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sandboxArpKey -Recurse -Force -ErrorAction SilentlyContinue
}

# A token that does not work has to be reported at the point it is pasted, with
# another go - not accepted in silence and blamed on something else much later.
$run = Invoke-SandboxInstall -Answers "1`nbad-one`nbad-two`nbad-three`n" `
    -ExtraArgs @('-Clients', 'copilot', '-HomeAssistantUrl', 'http://127.0.0.1:1')
try {
    Test-That 'a bad token is reported rather than accepted' {
        $run.Output -match 'could not connect to http://127\.0\.0\.1:1'
    }
    Test-That 'the failure explains itself' { $run.Output -match 'refused|No connection' }
    Test-That 'it offers the token again instead of giving up at once' {
        ([regex]::Matches($run.Output, 'Home Assistant needs a long-lived access token')).Count -ge 2
    }
    Test-That 'it gives up after three goes rather than looping forever' {
        ([regex]::Matches($run.Output, 'Connecting to Home Assistant')).Count -eq 4
    }
    Test-That 'the install fails rather than reporting success' { $run.Exit -ne 0 }
    Test-That 'it says how to finish the install later' { $run.Output -match 'agent-ha-bridge configure' }
}
finally {
    Remove-Item -LiteralPath $run.Root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sandboxArpKey -Recurse -Force -ErrorAction SilentlyContinue
}

Test-That 'none of the interactive runs touched the real user PATH' {
    (Get-BridgeUserPath) -eq $pathBefore
}

Write-Host ''
Write-Host '--- the command lands on PATH in a file the shell actually reads ---'
# On a Mac whose shell is bash, the line went into ~/.zprofile alone - which bash never
# reads - so `agent-ha-bridge` stayed "command not found" however many terminals were
# opened. bash reads the FIRST of ~/.bash_profile, ~/.bash_login, ~/.profile.
function New-ProfileHome {
    param([string[]]$Existing = @())
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("bridge-profile-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    foreach ($name in $Existing) { Set-Content -LiteralPath (Join-Path $dir $name) -Value '# theirs' -Encoding utf8 }
    $dir
}
function Get-Marked {
    param([string]$Dir)
    @(Get-ChildItem -LiteralPath $Dir -Force -File |
        Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'agent-ha-bridge' } |
        ForEach-Object { $_.Name } | Sort-Object)
}

$binDir = '/Users/x/.agent-ha-bridge/bin'
$zshHome = New-ProfileHome
[void](Register-BridgeShellPath -Directory $binDir -HomeDir $zshHome -Shell '/bin/zsh')
Test-That 'a zsh shell gets ~/.zprofile' { (Get-Marked $zshHome) -join ',' -eq '.zprofile' } ((Get-Marked $zshHome) -join ',')

$bashHome = New-ProfileHome
[void](Register-BridgeShellPath -Directory $binDir -HomeDir $bashHome -Shell '/bin/bash')
Test-That 'a bash shell with no profile at all gets one bash reads' {
    (Get-Marked $bashHome) -contains '.bash_profile'
} ((Get-Marked $bashHome) -join ',')

# Creating ~/.bash_profile here would orphan ~/.profile, where MacPorts puts its own
# PATH line - bash stops reading it the moment ~/.bash_profile exists.
$profileHome = New-ProfileHome -Existing @('.profile')
[void](Register-BridgeShellPath -Directory $binDir -HomeDir $profileHome -Shell '/bin/bash')
Test-That 'an existing ~/.profile is appended to, not orphaned by a new ~/.bash_profile' {
    ((Get-Marked $profileHome) -contains '.profile') -and
    -not (Test-Path -LiteralPath (Join-Path $profileHome '.bash_profile'))
} ((Get-Marked $profileHome) -join ',')
Test-That 'and what was already in it is kept' {
    (Get-Content -LiteralPath (Join-Path $profileHome '.profile') -Raw) -match '# theirs'
}

$bpHome = New-ProfileHome -Existing @('.bash_profile', '.profile')
[void](Register-BridgeShellPath -Directory $binDir -HomeDir $bpHome -Shell '/bin/bash')
Test-That 'the first file bash reads wins, and the others are left alone' {
    (Get-Marked $bpHome) -join ',' -eq '.bash_profile,.zprofile'
} ((Get-Marked $bpHome) -join ',')

# A zsh $SHELL but bash files present: someone who switched shells keeps working.
$mixedHome = New-ProfileHome -Existing @('.bash_profile')
[void](Register-BridgeShellPath -Directory $binDir -HomeDir $mixedHome -Shell '/bin/zsh')
Test-That 'an existing bash profile is still covered whatever $SHELL says' {
    (Get-Marked $mixedHome) -contains '.bash_profile'
} ((Get-Marked $mixedHome) -join ',')

Test-That 'a re-run does not add the line twice' {
    $before = (Get-Content -LiteralPath (Join-Path $bashHome '.bash_profile') -Raw)
    [void](Register-BridgeShellPath -Directory $binDir -HomeDir $bashHome -Shell '/bin/bash')
    (Get-Content -LiteralPath (Join-Path $bashHome '.bash_profile') -Raw) -eq $before
}
Test-That 'and reports that it changed nothing' {
    -not (Register-BridgeShellPath -Directory $binDir -HomeDir $bashHome -Shell '/bin/bash')
}
Test-That 'the line it writes puts the folder first, ahead of anything else' {
    (Get-Content -LiteralPath (Join-Path $bashHome '.bash_profile') -Raw) -match ([regex]::Escape("export PATH=`"$binDir`:`$PATH`""))
}
# The agent CLIs live in npm's own bin folder, which MacPorts does not reliably put on
# a bash user's PATH - `codex` was "command not found" right after being installed.
Test-That 'a second folder is added rather than mistaken for the first' {
    [void](Register-BridgeShellPath -Directory '/opt/local/bin' -HomeDir $bashHome -Shell '/bin/bash')
    $body = Get-Content -LiteralPath (Join-Path $bashHome '.bash_profile') -Raw
    $body -match ([regex]::Escape("export PATH=`"$binDir`:`$PATH`"")) -and
    $body -match ([regex]::Escape('export PATH="/opt/local/bin:$PATH"'))
}
Test-That 'and it too is skipped on a re-run' {
    -not (Register-BridgeShellPath -Directory '/opt/local/bin' -HomeDir $bashHome -Shell '/bin/bash')
}
Test-That 'every line the uninstaller looks for is marked' {
    @(Get-Content -LiteralPath (Join-Path $bashHome '.bash_profile') |
        Where-Object { $_ -match 'export PATH=' } |
        Where-Object { $_ -notmatch '# agent-ha-bridge$' }).Count -eq 0
}
foreach ($dir in @($zshHome, $bashHome, $profileHome, $bpHome, $mixedHome)) {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '--- launchd is handed a log path it can actually open ---'
# StandardOutPath under $TMPDIR (/var/folders/<hash>/T) is refused at bootstrap with
# "Bootstrap failed: 5: Input/output error" - that is launchd's own per-session
# directory, and the daemon then never starts at all.
$logHome = Join-Path ([IO.Path]::GetTempPath()) ("bridge-launchd-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $logHome -Force | Out-Null
$logPath = Get-BridgeLaunchAgentLogPath -HomeDir $logHome
Test-That 'the log goes under ~/Library/Logs, not the temp folder' {
    $logPath -match 'Library[\\/]Logs[\\/]agent-ha-bridge[\\/]launchd\.log$'
} $logPath
Test-That 'and its folder is created, so launchd has somewhere to write' {
    Test-Path -LiteralPath (Split-Path -Parent $logPath)
}
Test-That 'asking twice is harmless' {
    (Get-BridgeLaunchAgentLogPath -HomeDir $logHome) -eq $logPath
}
$plist = Get-BridgeLaunchAgentPlist -Label 'com.agent-ha-bridge.daemon' -PwshPath '/usr/local/bin/pwsh' `
    -DaemonPath '/Users/x/.agent-ha-bridge/hooks/agent-bridge-daemon.ps1' -LogPath $logPath -PathValue '/usr/bin:/bin'
Test-That 'the plist points launchd at that path, both streams' {
    ([regex]::Matches($plist, [regex]::Escape($logPath))).Count -eq 2
}
Test-That 'and never at the temp folder' { $plist -notmatch '/var/folders/' }
Remove-Item -LiteralPath $logHome -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
