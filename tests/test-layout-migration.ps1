#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the pre-rename layout migration.

.DESCRIPTION
    Before the rename the bridge kept everything under ~/.copilot - shared scripts,
    config, the MCP server, the Codex plugin root and an uninstaller folder. The
    installer now owns ~/.agent-ha-bridge and has to lift an existing install across
    without losing the Home Assistant token and without disturbing the Copilot CLI's
    own files, which live in the same directory.

    Invoke-BridgeLayoutMigration takes every path as a parameter, so these run against
    a scratch directory. -SkipMachineWide keeps the scheduled task and the real running
    daemon out of it.

    install.ps1 is dot-sourced with BRIDGE_INSTALL_NORUN set so its functions load
    without running the install.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:BRIDGE_INSTALL_NORUN = '1'
. (Join-Path $PSScriptRoot '..\install.ps1')

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

function New-LegacyInstall {
    <# Builds a scratch ~/.copilot laid out the way a pre-rename install left it. #>
    $root = Join-Path $env:TEMP ("bridge-migrate-" + [guid]::NewGuid().ToString('N'))
    $copilotHome = Join-Path $root '.copilot'
    $hooks = Join-Path $copilotHome 'hooks'
    New-Item -ItemType Directory -Path $hooks -Force | Out-Null

    foreach ($name in @(
        'decision-bridge-common.ps1', 'decision-mqtt.ps1', 'decision-ha-websocket.ps1',
        'decision-inject.ps1', 'bridge-adapter.ps1', 'bridge-update.ps1', 'session-launch.ps1',
        'copilot-bridge-daemon.ps1', 'copilot-bridge-supervisor.ps1', 'copilot-bridge-launch.vbs',
        'route-ask-user-v3.ps1', 'notify-agent-response.ps1', 'notify-home-assistant.ps1',
        'VERSION', 'route-ask-user-v2.ps1', 'sync-active-sessions.ps1')) {
        Set-Content -LiteralPath (Join-Path $hooks $name) -Value 'stale' -Encoding UTF8
    }
    New-Item -ItemType Directory -Path (Join-Path $hooks 'dashboard') -Force | Out-Null

    # The Copilot CLI's own files, which must survive untouched.
    Set-Content -LiteralPath (Join-Path $hooks 'decision-notifier.json') -Value '{"version":1}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $copilotHome 'config.json') -Value '{"cli":true}' -Encoding UTF8
    New-Item -ItemType Directory -Path (Join-Path $copilotHome 'session-state') -Force | Out-Null

    Set-Content -LiteralPath (Join-Path $copilotHome 'copilot-ha-bridge.config.json') `
        -Value '{"homeAssistant":{"token":"secret-token"}}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $copilotHome 'copilot-ha-bridge.config.json.bak') `
        -Value '{"homeAssistant":{"token":"older"}}' -Encoding UTF8

    New-Item -ItemType Directory -Path (Join-Path $copilotHome 'mcp') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $copilotHome 'mcp\mcp-client-config.json') -Value '{}' -Encoding UTF8
    New-Item -ItemType Directory -Path (Join-Path $copilotHome 'codex-bridge\plugins') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $copilotHome 'copilot-ha-bridge') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $copilotHome 'copilot-ha-bridge\uninstall.ps1') -Value '# old' -Encoding UTF8

    [pscustomobject]@{
        Root = $root
        CopilotHome = $copilotHome
        BridgeHome = Join-Path $root '.agent-ha-bridge'
        LegacyHooksDir = $hooks
    }
}

function Invoke-Migration {
    param([pscustomobject]$Install)
    Invoke-BridgeLayoutMigration `
        -CopilotHome $Install.CopilotHome `
        -BridgeHome $Install.BridgeHome `
        -ConfigPath (Join-Path $Install.BridgeHome 'config.json') `
        -LegacyHooksDir $Install.LegacyHooksDir `
        -LegacyConfigPath (Join-Path $Install.CopilotHome 'copilot-ha-bridge.config.json') `
        -LegacyBridgeHome (Join-Path $Install.CopilotHome 'copilot-ha-bridge') `
        -SkipMachineWide
}

Write-Host '--- migrating a pre-rename install ---'
$install = New-LegacyInstall
try {
    $result = Invoke-Migration -Install $install 6>$null
    $config = Join-Path $install.BridgeHome 'config.json'

    Test-That 'it reports that it migrated something' { $result }
    Test-That 'the config moves to the bridge root' { Test-Path -LiteralPath $config }
    Test-That 'the token survives the move' {
        (Get-Content -LiteralPath $config -Raw | ConvertFrom-Json).homeAssistant.token -eq 'secret-token'
    }
    Test-That 'the config backup moves too' { Test-Path -LiteralPath "$config.bak" }
    Test-That 'the old config path is gone' {
        -not (Test-Path -LiteralPath (Join-Path $install.CopilotHome 'copilot-ha-bridge.config.json'))
    }
    Test-That 'the MCP server moves across with its contents' {
        Test-Path -LiteralPath (Join-Path $install.BridgeHome 'mcp\mcp-client-config.json')
    }
    Test-That 'the Codex plugin root moves across' {
        Test-Path -LiteralPath (Join-Path $install.BridgeHome 'codex-bridge\plugins')
    }
    Test-That 'the old uninstaller folder is removed' {
        -not (Test-Path -LiteralPath (Join-Path $install.CopilotHome 'copilot-ha-bridge'))
    }

    Write-Host '--- the Copilot CLI keeps its own files ---'
    Test-That "the CLI's hook definition is left in place" {
        Test-Path -LiteralPath (Join-Path $install.LegacyHooksDir 'decision-notifier.json')
    }
    Test-That "the CLI's own config is untouched" {
        (Get-Content -LiteralPath (Join-Path $install.CopilotHome 'config.json') -Raw) -match 'cli'
    }
    Test-That 'session-state is left alone' {
        Test-Path -LiteralPath (Join-Path $install.CopilotHome 'session-state')
    }
    Test-That 'the hooks directory survives because the CLI still uses it' {
        Test-Path -LiteralPath $install.LegacyHooksDir
    }

    Write-Host '--- stale bridge scripts are cleared out ---'
    foreach ($name in @('decision-bridge-common.ps1', 'copilot-bridge-daemon.ps1',
                        'copilot-bridge-launch.vbs', 'route-ask-user-v3.ps1',
                        'route-ask-user-v2.ps1', 'sync-active-sessions.ps1', 'VERSION')) {
        Test-That "$name is removed" {
            -not (Test-Path -LiteralPath (Join-Path $install.LegacyHooksDir $name))
        }
    }
    Test-That 'the generated dashboard folder is removed' {
        -not (Test-Path -LiteralPath (Join-Path $install.LegacyHooksDir 'dashboard'))
    }

    Write-Host '--- running it again is a no-op ---'
    Test-That 'a second pass reports nothing to do' { -not (Invoke-Migration -Install $install 6>$null) }
    Test-That 'the config is still there afterwards' { Test-Path -LiteralPath $config }
    $recorded = Initialize-BridgeInstallIdentity -Context (Resolve-BridgeInstallContext -TargetHome $install.Root) -LegacyLayout
    Test-That 'the canonical migration can retain its exact legacy client-root ownership' {
        $recorded.LegacyLayout -and
            (Get-Content -LiteralPath $recorded.MetadataPath -Raw | ConvertFrom-Json).legacyCopilotHome -eq $install.CopilotHome
    }
}
finally {
    Remove-Item -LiteralPath $install.Root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '--- a clean install has nothing to migrate ---'
$fresh = Join-Path $env:TEMP ("bridge-migrate-" + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fresh -Force | Out-Null
    $result = Invoke-BridgeLayoutMigration `
        -CopilotHome (Join-Path $fresh '.copilot') `
        -BridgeHome (Join-Path $fresh '.agent-ha-bridge') `
        -ConfigPath (Join-Path $fresh '.agent-ha-bridge\config.json') `
        -LegacyHooksDir (Join-Path $fresh '.copilot\hooks') `
        -LegacyConfigPath (Join-Path $fresh '.copilot\copilot-ha-bridge.config.json') `
        -LegacyBridgeHome (Join-Path $fresh '.copilot\copilot-ha-bridge') `
        -SkipMachineWide 6>$null
    Test-That 'it reports nothing migrated' { -not $result }
    Test-That 'it still creates the bridge root' {
        Test-Path -LiteralPath (Join-Path $fresh '.agent-ha-bridge')
    }
    Test-That 'it does not invent a Copilot directory' {
        -not (Test-Path -LiteralPath (Join-Path $fresh '.copilot'))
    }
}
finally {
    Remove-Item -LiteralPath $fresh -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '--- an existing new-layout config is never overwritten ---'
$both = New-LegacyInstall
try {
    New-Item -ItemType Directory -Path $both.BridgeHome -Force | Out-Null
    $config = Join-Path $both.BridgeHome 'config.json'
    Set-Content -LiteralPath $config -Value '{"homeAssistant":{"token":"current"}}' -Encoding UTF8

    [void](Invoke-Migration -Install $both 6>$null)
    Test-That 'the newer config wins' {
        (Get-Content -LiteralPath $config -Raw | ConvertFrom-Json).homeAssistant.token -eq 'current'
    }
    Test-That 'the superseded legacy config is left for the uninstaller' {
        Test-Path -LiteralPath (Join-Path $both.CopilotHome 'copilot-ha-bridge.config.json')
    }
}
finally {
    Remove-Item -LiteralPath $both.Root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '--- the hooks directory is removed when the CLI has nothing there ---'
$bare = New-LegacyInstall
try {
    Remove-Item -LiteralPath (Join-Path $bare.LegacyHooksDir 'decision-notifier.json') -Force
    [void](Invoke-Migration -Install $bare 6>$null)
    Test-That 'an emptied hooks directory is cleaned up' {
        -not (Test-Path -LiteralPath $bare.LegacyHooksDir)
    }
}
finally {
    Remove-Item -LiteralPath $bare.Root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '--- a second root cannot adopt the existing legacy installation ---'
$separate = New-LegacyInstall
try {
    $separate.BridgeHome = Join-Path $separate.Root 'second-bridge'
    $result = Invoke-Migration -Install $separate 6>$null
    Test-That 'a noncanonical root leaves the legacy configuration and adapter payload untouched' {
        -not $result -and
            (Test-Path -LiteralPath (Join-Path $separate.CopilotHome 'copilot-ha-bridge.config.json')) -and
            (Test-Path -LiteralPath (Join-Path $separate.CopilotHome 'mcp\mcp-client-config.json')) -and
            -not (Test-Path -LiteralPath (Join-Path $separate.BridgeHome 'config.json'))
    }
}
finally { Remove-Item -LiteralPath $separate.Root -Recurse -Force }

Write-Host '--- a verified legacy writer hands off state without rewriting lifecycle fields ---'
$previousContext = Resolve-BridgeInstallContext
if (-not $previousContext.Legacy -or $previousContext.Recorded) { throw 'The migration fixture requires an unrecorded private default installation.' }
$previousContext.TaskName = 'P2LegacyFixture_' + [guid]::NewGuid().ToString('N')
$heartbeat = Get-BridgeRuntimePath -Name 'agent-bridge-daemon.heartbeat' -Context $previousContext
$oldState = Get-BridgeRuntimePath -Name 'agent-bridge-daemon-state.json' -Context $previousContext
$stateText = '{"legacy-session":{"Kind":"claude","Status":"stopped","LastResponse":"unchanged","StopAcceptedAt":"2026-01-01T00:00:00Z"}}'
$savedProcessInfo = (Get-Command Get-BridgeProcessInfo).ScriptBlock
$fixtureExecutable = (Get-Process -Id $PID).Path
$fixtureStart = [datetime]::UtcNow.AddMinutes(-1)
function Get-BridgeProcessInfo {
    param($ProcessId, [switch]$WithCommandLine)
    [pscustomobject]@{
        ProcessId = $ProcessId; Path = $fixtureExecutable; CreationDate = $fixtureStart
        CommandLine = '"' + $fixtureExecutable + '" -File "' + (Join-Path $previousContext.HooksDir 'agent-bridge-daemon.ps1') + '"'
    }
}
try {
    [IO.File]::WriteAllText($heartbeat, '910100')
    [IO.File]::WriteAllText($oldState, $stateText)
    [IO.File]::WriteAllText("$oldState.bak", $stateText)
    $claim = Get-BridgeLegacyRuntimeClaim -Context $previousContext
    $context = Initialize-BridgeInstallIdentity -Context $previousContext
    Copy-BridgeLegacyRuntimeState -PreviousContext $previousContext -Context $context -Claim $claim
    $newState = Get-BridgeRuntimePath -Name 'agent-bridge-daemon-state.json' -Context $context
    Test-That 'verified state and backup retain their exact saved lifecycle bytes' {
        $null -ne $claim -and [IO.File]::ReadAllText($newState) -ceq $stateText -and
            [IO.File]::ReadAllText("$newState.bak") -ceq $stateText
    }
    Test-That 'legacy copies remain, but the stopped owners heartbeat cannot misroute old native hooks' {
        [IO.File]::ReadAllText($oldState) -ceq $stateText -and -not (Test-Path -LiteralPath $heartbeat)
    }
    Remove-Item -LiteralPath $newState -Force
    [IO.File]::WriteAllText($heartbeat, '910101')
    Copy-BridgeLegacyRuntimeState -PreviousContext $previousContext -Context $context -Claim $claim -WarningAction SilentlyContinue
    Test-That 'a changed legacy writer cannot hand its state to this installation' {
        -not (Test-Path -LiteralPath $newState) -and [IO.File]::ReadAllText($heartbeat) -eq '910101'
    }
}
finally {
    Set-Item Function:\Get-BridgeProcessInfo -Value $savedProcessInfo
    foreach ($path in @($heartbeat, $oldState, "$oldState.bak")) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
