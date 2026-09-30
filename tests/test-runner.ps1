#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $env:AGENT_HA_BRIDGE_TEST_ROOT) { throw 'Run this suite through tests\run-tests.ps1.' }
. (Join-Path $PSScriptRoot 'runner-support.ps1')

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = $_.Exception.Message }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name - $Detail"; $script:Failures++ }
}

Write-Host '--- one classified inventory for every platform ---'
$offline = @(Get-BridgeTestSuite)
foreach ($expected in @(
    'test-http-session.ps1', 'test-launch-permissions.ps1', 'test-reply-card.ps1',
    'test-status-card.ps1', 'test-terminal-window.ps1', 'test-worktree-isolation.ps1',
    'test-codex.ps1', 'test-claude-install.ps1'
)) {
    Test-That "$expected is selected offline" {
        @(Get-BridgeTestSuite -Suite $expected).Count -eq 1
    }
}
Test-That 'installer, platform and integration suites cannot enter the offline selection' {
    @($offline | Where-Object { $_.Suite -match 'test-install-command|test-platform|integration' }).Count -eq 0
}
Test-That 'all suites belong to exactly one group' {
    $all = @(foreach ($group in 'Offline', 'Host', 'Platform', 'Integration') { Get-BridgeTestSuite -Group $group })
    @($all | Group-Object Suite | Where-Object Count -ne 1).Count -eq 0
}
foreach ($bad in 'test-no-such-suite.ps1', 'test-install-command.ps1', '..\install.ps1', '*') {
    Test-That "selection rejects $bad rather than skipping it" {
        try { Get-BridgeTestSuite -Suite $bad; $false }
        catch { $_.Exception.Message -match 'Expected one Offline suite' }
    }
}
Test-That 'duplicate selectors fail instead of running twice' {
    try { Get-BridgeTestSuite -Suite @('test-runner.ps1', 'tests\test-runner.ps1'); $false }
    catch { $_.Exception.Message -match 'more than once' }
}
Test-That 'host execution is refused without an explicit opt-in' {
    try { Assert-BridgeHostedTest; $false }
    catch { $_.Exception.Message -match 'disposable GitHub-hosted' }
}
Test-That 'an opt-in alone never permits a developer or self-hosted machine' {
    try { Assert-BridgeHostedTest -AllowHostTests; $false }
    catch { $_.Exception.Message -match 'disposable GitHub-hosted' }
}

$scratch = Join-Path $env:TEMP ("runner-fixtures-" + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
$sandboxes = @()
$saved = @{}
$poison = @{
    AGENT_HA_TOKEN = 'synthetic-parent-token'
    AGENT_HA_AGENT_TOKEN = 'synthetic-parent-agent-token'
    CUSTOM_HOUSE_CREDENTIAL = 'synthetic-custom-token'
    BRIDGE_ALLOW_TEST_HTTP = '1'
    COPILOT_HA_BRIDGE_CONFIG = (Join-Path $scratch 'not-a-config.json')
    HTTPS_PROXY = 'http://proxy.invalid:1'
    NODE_OPTIONS = '--require=not-a-module'
    GIT_CONFIG_COUNT = '1'
}
try {
    Write-Host '--- private roots and no inherited credentials, including descendants ---'
    foreach ($key in $poison.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key)
        [Environment]::SetEnvironmentVariable($key, $poison[$key], 'Process')
    }
    $box = New-BridgeTestSandbox -ParentDirectory $scratch
    $sandboxes += $box
    $probe = Join-Path $scratch "probe ' utf8.ps1"
    $probeText = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. '__COMMON__'
$text = 'one' + [char]0xb7 + 'two'
$roundTrip = $text | & node -e "process.stdout.write(require('fs').readFileSync(0, 'utf8').trim())"
if ($LASTEXITCODE) { throw 'Node encoding probe failed.' }
$descendant = & pwsh -NoProfile -NonInteractive -Command '@{ Home = $HOME; Temp = [IO.Path]::GetTempPath(); Config = $env:AGENT_HA_BRIDGE_CONFIG; Offline = $env:AGENT_HA_BRIDGE_OFFLINE_TEST; Leaked = [bool]$env:CUSTOM_HOUSE_CREDENTIAL } | ConvertTo-Json -Compress'
if ($LASTEXITCODE) { throw 'Descendant probe failed.' }
@{
    Home = $HOME
    Temp = [IO.Path]::GetTempPath()
    Config = $env:AGENT_HA_BRIDGE_CONFIG
    BaseUrl = $script:DecisionBridgeConfig.HomeAssistantBaseUrl
    Token = $script:DecisionBridgeConfig.HomeAssistantToken
    AppData = $env:APPDATA
    LocalAppData = $env:LOCALAPPDATA
    Public = $env:PUBLIC
    Claude = $env:CLAUDE_CONFIG_DIR
    Codex = $env:CODEX_HOME
    Copilot = $env:COPILOT_HOME
    Xdg = $env:XDG_CONFIG_HOME
    GitConfig = $env:GIT_CONFIG_GLOBAL
    Leaked = @(Get-ChildItem Env: | Where-Object Name -in @(
        'AGENT_HA_TOKEN', 'AGENT_HA_AGENT_TOKEN', 'CUSTOM_HOUSE_CREDENTIAL', 'BRIDGE_ALLOW_TEST_HTTP',
        'COPILOT_HA_BRIDGE_CONFIG', 'HTTPS_PROXY', 'NODE_OPTIONS', 'GIT_CONFIG_COUNT'
    ) | ForEach-Object Name)
    ConsoleInput = [Console]::InputEncoding.CodePage
    ConsoleOutput = [Console]::OutputEncoding.CodePage
    Pipeline = $OutputEncoding.CodePage
    RoundTrip = $roundTrip
    Child = ($descendant | ConvertFrom-Json)
} | ConvertTo-Json -Depth 5 -Compress
'@
    $commonPath = Join-Path (Join-Path $script:BridgeTestRepository 'hooks') 'decision-bridge-common.ps1'
    $probeText.Replace('__COMMON__', $commonPath.Replace("'", "''")) | Set-Content -LiteralPath $probe -Encoding utf8
    $start = New-BridgeTestProcessStartInfo -ScriptPath $probe -Sandbox $box
    $result = Invoke-BridgeTestProcess -StartInfo $start
    Test-That 'the isolated child completes' { $result.ExitCode -eq 0 -and -not $result.TimedOut } $result.Output
    if ($result.ExitCode -eq 0) {
        $observed = $result.Output | ConvertFrom-Json
        Test-That 'HOME is the suite home, not the caller home' {
            $observed.Home -eq (Join-Path $box 'home') -and $observed.Home -ne $HOME
        }
        Test-That '.NET temporary files are inside the private TEMP' {
            $observed.Temp.TrimEnd('\', '/') -eq (Join-Path $box 'temp')
        }
        foreach ($property in 'Config', 'AppData', 'LocalAppData', 'Public', 'Claude', 'Codex', 'Copilot', 'Xdg', 'GitConfig') {
            Test-That "$property is inside the suite sandbox" {
                $observed.$property.StartsWith($box + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
            }
        }
        Test-That 'the checkout loads only synthetic loopback configuration' {
            $observed.BaseUrl -eq 'http://127.0.0.1:1' -and $observed.Token -eq 'synthetic-test-token'
        }
        Test-That 'known and arbitrarily named credentials and launch overrides are absent' { @($observed.Leaked).Count -eq 0 }
        Test-That 'child PowerShell inherits the same private roots and guard, not credentials' {
            $observed.Child.Home -eq $observed.Home -and $observed.Child.Temp -eq $observed.Temp -and
            $observed.Child.Config -eq $observed.Config -and $observed.Child.Offline -eq '1' -and -not $observed.Child.Leaked
        }
        Test-That 'redirected console input, output and pipelines are explicitly UTF-8' {
            $observed.ConsoleInput -eq 65001 -and $observed.ConsoleOutput -eq 65001 -and $observed.Pipeline -eq 65001
        }
        Test-That 'a middle dot survives the redirected PowerShell to Node round trip' {
            $observed.RoundTrip -ceq ('one' + [char]0xb7 + 'two')
        }
    }
    Test-That 'building a child environment leaves the caller environment untouched' {
        $env:CUSTOM_HOUSE_CREDENTIAL -eq $poison.CUSTOM_HOUSE_CREDENTIAL -and $env:BRIDGE_ALLOW_TEST_HTTP -eq '1'
    }
    $secondBox = New-BridgeTestSandbox -ParentDirectory $scratch
    $sandboxes += $secondBox
    Test-That 'two suites never share a home or temporary directory' {
        $other = New-BridgeTestProcessStartInfo -ScriptPath $probe -Sandbox $secondBox
        $other.Environment['HOME'] -ne $start.Environment['HOME'] -and $other.Environment['TEMP'] -ne $start.Environment['TEMP']
    }

    Write-Host '--- checkout code wins even when an installed copy exists ---'
    $installedHooks = Join-Path (Join-Path (Join-Path $box 'home') '.agent-ha-bridge') 'hooks'
    [void][IO.Directory]::CreateDirectory($installedHooks)
    Set-Content -LiteralPath (Join-Path $installedHooks 'decision-bridge-common.ps1') -Value "throw 'Installed code must not be loaded.'"
    $codexPath = (Get-BridgeTestSuite -Suite 'test-codex.ps1').Path
    $codexResult = Invoke-BridgeTestProcess -StartInfo (New-BridgeTestProcessStartInfo -ScriptPath $codexPath -Sandbox $box)
    Test-That 'Codex tests ignore an installed shared helper' { $codexResult.ExitCode -eq 0 } $codexResult.Output

    Write-Host '--- a subprocess cannot opt an offline run into real traffic ---'
    $guardProbe = Join-Path $scratch 'guard-probe.ps1'
    $guardText = @'
. '__COMMON__'
. '__WEBSOCKET__'
if ($script:BridgeUnderTestSuite) { throw 'Probe must run outside the tests call stack.' }
$env:BRIDGE_ALLOW_TEST_HTTP = '1'
$blocked = 0
foreach ($call in @(
    { Invoke-DecisionHttpRequest -Parameters @{ Uri = 'http://127.0.0.1:1/api/'; TimeoutSec = 1 } -RetryCount 0 },
    { Test-HomeAssistantReachable -TimeoutSec 1 },
    { Invoke-CopilotHaWebSocket -Commands @(@{ type = 'get_states' }) -TimeoutSeconds 1 },
    { Wait-CopilotHaStateChange -EntityIds @('sensor.test') -TimeoutSeconds 1 }
)) {
    try { & $call }
    catch {
        if ($_.Exception.Message -notmatch 'tried to reach a real Home Assistant') { throw }
        $blocked++
    }
}
if ($blocked -ne 4 -or $script:BridgeBlockedHttpCalls -ne 4) { throw "Expected four guarded calls, got $blocked." }
Write-Output 'all child transports blocked'
'@
    $websocketPath = Join-Path (Join-Path $script:BridgeTestRepository 'hooks') 'decision-ha-websocket.ps1'
    $guardText.Replace('__COMMON__', $commonPath.Replace("'", "''")).Replace('__WEBSOCKET__', $websocketPath.Replace("'", "''")) |
        Set-Content -LiteralPath $guardProbe -Encoding utf8
    $guardResult = Invoke-BridgeTestProcess -StartInfo (New-BridgeTestProcessStartInfo -ScriptPath $guardProbe -Sandbox $secondBox)
    Test-That 'HTTP, reachability and both WebSocket paths refuse traffic in a child' {
        $guardResult.ExitCode -eq 0 -and $guardResult.Output -match 'all child transports blocked'
    } $guardResult.Output

    Write-Host '--- unsafe groups also reject direct execution in an offline child ---'
    foreach ($group in 'Host', 'Platform', 'Integration') {
        foreach ($entry in @(Get-BridgeTestSuite -Group $group)) {
            $refused = Invoke-BridgeTestProcess -StartInfo (New-BridgeTestProcessStartInfo -ScriptPath $entry.Path -Sandbox $secondBox)
            Test-That "$($entry.Suite) fails before loading a live installation" {
                $refused.ExitCode -ne 0 -and $refused.Output -match 'disposable'
            } $refused.Output
        }
    }

    Write-Host '--- installer test namespaces agree without executing an install ---'
    $registryProbe = Join-Path $scratch 'registry-probe.ps1'
    $registryText = @'
$env:BRIDGE_INSTALL_NORUN = '1'
$env:BRIDGE_UNINSTALL_NORUN = '1'
function Get-TestKeys {
    param([string]$Entry, [string]$Namespace, [switch]$Sandboxed)
    $parameters = @{}
    if ($Namespace) { $parameters.TestRegistryId = $Namespace }
    if ($Sandboxed) { $parameters.TargetHome = $env:HOME }
    . (Join-Path '__REPOSITORY__' $Entry) @parameters
    [pscustomobject]@{ Current = $arpKey; Legacy = $legacyArpKey }
}
$firstId = [guid]::NewGuid().ToString('N')
$secondId = [guid]::NewGuid().ToString('N')
foreach ($entry in 'install.ps1', 'uninstall.ps1') {
    $normal = Get-TestKeys -Entry $entry
    if ($normal.Current -notmatch '\\AgentHaBridge$' -or $normal.Legacy -notmatch '\\CopilotHaBridge$') { throw 'Normal registry identity changed.' }
    $first = Get-TestKeys -Entry $entry -Namespace $firstId -Sandboxed
    $second = Get-TestKeys -Entry $entry -Namespace $secondId -Sandboxed
    if ($first.Current -ne ($normal.Current + "_Sandbox_$firstId") -or $first.Legacy -ne ($normal.Legacy + "_Sandbox_$firstId")) { throw 'Incorrect test namespace.' }
    if ($first.Current -eq $second.Current -or $first.Legacy -eq $second.Legacy) { throw 'Test namespaces collided.' }
    $refused = $false
    try { Get-TestKeys -Entry $entry -Namespace $firstId }
    catch { $refused = $_.Exception.Message -match 'requires -TargetHome' }
    if (-not $refused) { throw 'A test namespace was accepted without TargetHome.' }
    $refused = $false
    try { Get-TestKeys -Entry $entry -Namespace '..\shared' -Sandboxed }
    catch { $refused = $_.Exception.Message -match 'pattern' }
    if (-not $refused) { throw 'An invalid registry namespace was accepted.' }
}
Write-Output 'isolated registry names verified without registry writes'
'@
    $registryText.Replace('__REPOSITORY__', $script:BridgeTestRepository.Replace("'", "''")) |
        Set-Content -LiteralPath $registryProbe -Encoding utf8
    $registryResult = Invoke-BridgeTestProcess -StartInfo (New-BridgeTestProcessStartInfo -ScriptPath $registryProbe -Sandbox $secondBox)
    Test-That 'install and uninstall preserve normal names and require unique, constrained test names' {
        $registryResult.ExitCode -eq 0 -and $registryResult.Output -match 'without registry writes'
    } $registryResult.Output

    Write-Host '--- failures and timeouts cannot become a green result ---'
    $failureProbe = Join-Path $scratch 'failure.ps1'
    Set-Content -LiteralPath $failureProbe -Value "Write-Output 'failure-output'; exit 23"
    $failure = Invoke-BridgeTestProcess -StartInfo (New-BridgeTestProcessStartInfo -ScriptPath $failureProbe -Sandbox $secondBox)
    Test-That 'the original nonzero exit code and output are preserved' {
        $failure.ExitCode -eq 23 -and $failure.Output -match 'failure-output' -and -not $failure.TimedOut
    } $failure.Output
    Set-Content -LiteralPath $failureProbe -Value "throw 'intentional runner regression failure'"
    $failure = Invoke-BridgeTestProcess -StartInfo (New-BridgeTestProcessStartInfo -ScriptPath $failureProbe -Sandbox $secondBox)
    Test-That 'an uncaught exception also fails and keeps its diagnostics' {
        $failure.ExitCode -ne 0 -and $failure.Output -match 'intentional runner regression failure'
    } $failure.Output

    $timeoutProbe = Join-Path $scratch 'timeout.ps1'
    @'
$child = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 60' -NoNewWindow -PassThru
@{ Id = $child.Id; Started = $child.StartTime.ToUniversalTime().Ticks } | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $env:AGENT_HA_BRIDGE_TEST_ROOT 'child.json')
Start-Sleep -Seconds 60
'@ | Set-Content -LiteralPath $timeoutProbe -Encoding utf8
    $timeout = Invoke-BridgeTestProcess -StartInfo (New-BridgeTestProcessStartInfo -ScriptPath $timeoutProbe -Sandbox $secondBox) -TimeoutSeconds 5
    Test-That 'a timeout is reported within the bounded wait' { $timeout.TimedOut -and $timeout.Seconds -lt 15 }
    $childInfo = Get-Content -LiteralPath (Join-Path $secondBox 'child.json') -Raw | ConvertFrom-Json
    Test-That 'timing out kills the owned descendant as well as the suite' {
        $childProcess = Get-Process -Id $childInfo.Id -ErrorAction SilentlyContinue
        if (-not $childProcess -or $childProcess.StartTime.ToUniversalTime().Ticks -ne $childInfo.Started) { return $true }
        try { $childProcess.WaitForExit(5000) } finally { $childProcess.Dispose() }
    }
}
finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process') }
    foreach ($box in $sandboxes) {
        $pidFile = Join-Path $box 'child.json'
        if (Test-Path -LiteralPath $pidFile) {
            $childInfo = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
            $ownedProcess = Get-Process -Id $childInfo.Id -ErrorAction SilentlyContinue
            if ($ownedProcess) {
                try {
                    if ($ownedProcess.StartTime.ToUniversalTime().Ticks -eq $childInfo.Started) {
                        Stop-Process -Id $ownedProcess.Id -Force
                        [void]$ownedProcess.WaitForExit(5000)
                    }
                }
                finally { $ownedProcess.Dispose() }
            }
        }
    }
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
if ($script:Failures) { throw "$script:Failures runner check(s) failed." }
Write-Host 'All runner checks passed'
exit 0
