#Requires -Version 7.0
<#
.SYNOPSIS
    Tests the Claude adapter installer, including running a hook the way Claude does.

.DESCRIPTION
    Claude Code runs hook commands under Git Bash on Windows. A command that works
    from PowerShell can still fail there - the Store pwsh's execution alias cannot be
    executed by Bash at all - and because the hooks always exit 0 the failure is
    silent: sessions simply stop being registered. So beyond checking what gets
    written to settings.json, this runs the exact registered command through Bash
    with a real hook payload and checks that the session was registered.

    Installs into a throwaway home; the real ~/.claude is never touched.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$sandbox = Join-Path ([IO.Path]::GetTempPath()) "claude-install-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$coreHooks = Join-Path $sandbox '.agent-ha-bridge\hooks'
New-Item -ItemType Directory -Path $coreHooks -Force | Out-Null
# The installer only checks that the main bridge is present.
Set-Content -LiteralPath (Join-Path $coreHooks 'decision-mqtt.ps1') -Value '# placeholder'

# $env:TEMP on macOS, and $script:BridgeIsWindows.
. (Join-Path $PSScriptRoot '../../hooks/bridge-platform.ps1')

$sessionId = "00000000-0000-4000-8000-$([guid]::NewGuid().ToString('N').Substring(0,12))"
$registration = Join-Path $env:TEMP "agent-bridge-claude\$sessionId.json"

try {
    Write-Host ''
    Write-Host '--- what the installer writes ---'

    & (Join-Path $PSScriptRoot '..\install-claude.ps1') -TargetHome $sandbox *> $null

    $adapter = Join-Path $sandbox '.claude\ha-bridge'
    $settings = Get-Content -LiteralPath (Join-Path $sandbox '.claude\settings.json') -Raw | ConvertFrom-Json

    foreach ($eventName in @('PreToolUse', 'Notification', 'Stop', 'SessionStart', 'UserPromptSubmit')) {
        Test-That "$eventName is registered" { $null -ne $settings.hooks.$eventName }
    }
    $commands = @($settings.hooks.PSObject.Properties | ForEach-Object { [string]$_.Value[0].hooks[0].command })
    Test-That 'the Windows/macOS layer is installed with the adapter' { Test-Path -LiteralPath (Join-Path $adapter 'bridge-platform.ps1') }
    if ($script:BridgeIsWindows) {
        Test-That 'the hook launcher is installed with the adapter' { Test-Path -LiteralPath (Join-Path $adapter 'run-hook.cmd') }
        Test-That 'every hook runs through the launcher' {
            @($commands | Where-Object { $_ -notlike '"*\run-hook.cmd" "*.ps1"' }).Count -eq 0
        }
        Test-That 'no hook names a pwsh path, which breaks under Bash or on update' {
            @($commands | Where-Object { $_ -match 'pwsh' }).Count -eq 0
        }
    }
    else {
        # macOS runs hooks through sh, whose PATH may lack Homebrew: pwsh by full path.
        Test-That 'every hook starts its script under pwsh, named by full path' {
            @($commands | Where-Object { $_ -notmatch "^'/[^']*/pwsh' -NoProfile -NonInteractive -File '[^']*\.ps1'$" }).Count -eq 0
        }
    }

    Write-Host ''
    Write-Host '--- running a hook the way Claude does ---'

    $bash = if (-not $script:BridgeIsWindows) { '/bin/bash' } else {
        @(
            (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
            (Get-Command bash.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    }

    if (-not $bash) {
        Write-Host '  SKIP  Git Bash not found'
    }
    else {
        $command = [string]$settings.hooks.SessionStart[0].hooks[0].command
        $payload = @{
            session_id      = $sessionId
            transcript_path = 'C:\nowhere\transcript.jsonl'
            cwd             = $sandbox
            hook_event_name = 'SessionStart'
        } | ConvertTo-Json -Compress

        $output = $payload | & $bash -c $command 2>&1
        $exit = $LASTEXITCODE

        Test-That 'the SessionStart command runs under Bash' { $exit -eq 0 } "exit ${exit}: $output"
        Test-That 'it writes nothing to stdout, which Claude would add to its context' {
            [string]::IsNullOrWhiteSpace(($output | Out-String))
        } ($output | Out-String)
        Test-That 'the hook event reached the script and registered the session' {
            (Get-Content -LiteralPath $registration -Raw | ConvertFrom-Json).WorkingDirectory -eq $sandbox
        }
    }

    Write-Host ''
    Write-Host '--- uninstall ---'
    & (Join-Path $PSScriptRoot '..\install-claude.ps1') -TargetHome $sandbox -Uninstall *> $null
    $after = Get-Content -LiteralPath (Join-Path $sandbox '.claude\settings.json') -Raw | ConvertFrom-Json
    Test-That 'uninstall removes every hook it added' { -not $after.PSObject.Properties['hooks'] }
    # A sandboxed uninstall once deleted the real session registry, retiring every
    # live Claude session on the machine.
    Test-That 'a sandboxed uninstall leaves the real session registry alone' {
        Test-Path -LiteralPath $registration
    }
}
finally {
    Remove-Item -LiteralPath $registration -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) test(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'all claude install checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
