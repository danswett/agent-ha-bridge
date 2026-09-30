#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the installer's client selection.

.DESCRIPTION
    The base installer now sets up the shared layer and then configures whichever
    clients are chosen, instead of always forcing Copilot. These cover the pure
    decision logic:

      * ConvertTo-BridgeClientList normalises aliases, de-dupes, drops blanks and
        rejects unknown names;
      * Resolve-BridgeClients honours -Clients first, then a persisted selection, then
        an interactive pick, and falls back to Copilot only for an unattended install.

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

Write-Host '--- ConvertTo-BridgeClientList ---'
Test-That 'passes known clients through' {
    (ConvertTo-BridgeClientList @('copilot', 'claude', 'codex', 'mcp')) -join ',' -eq 'copilot,claude,codex,mcp'
}
Test-That 'normalises aliases' {
    (ConvertTo-BridgeClientList @('GitHub', 'claude-code', 'codex-cli')) -join ',' -eq 'copilot,claude,codex'
}
Test-That 'is case-insensitive' {
    (ConvertTo-BridgeClientList @('Copilot', 'CLAUDE')) -join ',' -eq 'copilot,claude'
}
Test-That 'de-dupes' {
    (ConvertTo-BridgeClientList @('copilot', 'copilot', 'github')) -join ',' -eq 'copilot'
}
Test-That 'drops blanks' {
    (ConvertTo-BridgeClientList @('copilot', '', '  ')) -join ',' -eq 'copilot'
}
Test-That 'splits a comma-joined single string' {
    (ConvertTo-BridgeClientList @('copilot,claude,codex')) -join ',' -eq 'copilot,claude,codex'
}
Test-That 'rejects an unknown client' {
    $threw = $false
    try { ConvertTo-BridgeClientList @('sublime') } catch { $threw = $true }
    $threw
}

Write-Host '--- Resolve-BridgeClients precedence ---'
Test-That '-Clients wins over everything' {
    (Resolve-BridgeClients -Requested @('claude') -Persisted @('copilot') -NonInteractive) -join ',' -eq 'claude'
}
Test-That 'a persisted selection is used when nothing is requested' {
    (Resolve-BridgeClients -Persisted @('copilot', 'codex') -NonInteractive) -join ',' -eq 'copilot,codex'
}
Test-That 'a persisted selection is normalised too' {
    (Resolve-BridgeClients -Persisted @('github', 'claude-code') -NonInteractive) -join ',' -eq 'copilot,claude'
}
Test-That 'non-interactive with nothing set defaults to copilot' {
    (Resolve-BridgeClients -NonInteractive) -join ',' -eq 'copilot'
}
Test-That 'the interactive prompt is used when not non-interactive' {
    (Resolve-BridgeClients -Prompt { @('claude', 'codex') }) -join ',' -eq 'claude,codex'
}
Test-That 'a request beats a prompt' {
    (Resolve-BridgeClients -Requested @('copilot') -Prompt { @('claude') }) -join ',' -eq 'copilot'
}

Write-Host '--- a first install must always reach the picker ---'
# The regression this pins down: config.example.json shipped "clients": ["copilot"],
# and the installer seeds a fresh config from it. The persisted branch therefore fired
# on the very first install, the picker never appeared, and every new machine silently
# configured Copilot alone. Two things have to hold for that to stay fixed: nothing
# may be persisted on a fresh install, and the example must not pretend otherwise.
Test-That 'an empty persisted selection falls through to the picker' {
    $script:PickerAsked = $false
    $chosen = Resolve-BridgeClients -Persisted @() -Prompt { $script:PickerAsked = $true; @('claude') }
    $script:PickerAsked -and ($chosen -join ',' -eq 'claude')
}
Test-That 'a null persisted selection falls through to the picker' {
    (Resolve-BridgeClients -Persisted $null -Prompt { @('codex') }) -join ',' -eq 'codex'
}
$exampleRaw = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\config.example.json') -Raw -Encoding UTF8
$example = $exampleRaw | ConvertFrom-Json
Test-That 'config.example.json is still valid JSON' { $null -ne $example }
Test-That 'config.example.json does not preselect any clients' {
    -not $example.PSObject.Properties['clients']
}
Test-That 'the example still carries the settings the installer expects' {
    $example.PSObject.Properties['homeAssistant'] -and
    $example.PSObject.Properties['notifications'] -and
    $example.PSObject.Properties['dashboard'] -and
    $example.PSObject.Properties['updates']
}
Test-That 'the installer only treats a pre-existing config as a previous answer' {
    # The guard in install.ps1 is `if ($configExisted -and ...)`; without the first
    # half, seeding from the example resurrects the bug whatever the example says.
    $installerText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\install.ps1') -Raw
    $installerText -match '\$configExisted\s+-and\s+\$config\.PSObject\.Properties\[.clients.\]'
}

Write-Host '--- the picker offers every client, and preselects what is detected ---'
Test-That 'every known client has a label to show' {
    @($script:KnownClients | Where-Object { -not $script:ClientLabels[$_] }).Count -eq 0
}
Test-That 'the labels cover nothing that is not a known client' {
    @($script:ClientLabels.Keys | Where-Object { $script:KnownClients -notcontains $_ }).Count -eq 0
}

Write-Host '--- Test-BridgeClientInstalled returns a bool for each client ---'
foreach ($c in @('copilot', 'claude', 'codex', 'mcp')) {
    Test-That "$c detection does not throw" { (Test-BridgeClientInstalled $c) -is [bool] }
}

Write-Host '--- Protect-BridgeSecretFile locks a token file to the current user ---'
if (-not $script:BridgeIsWindows) {
    # macOS: owner read/write only (600), in place of the Windows ACL.
    $secretFile = Join-Path $env:TEMP ("bridge-acl-" + [guid]::NewGuid().ToString('N') + '.json')
    Set-Content -LiteralPath $secretFile -Value '{"homeAssistant":{"token":"secret"}}' -Encoding UTF8
    try {
        Test-That 'hardening reports success' { Protect-BridgeSecretFile -Path $secretFile }
        Test-That 'the file is readable by its owner alone' {
            [IO.File]::GetUnixFileMode($secretFile) -eq ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
        Test-That 'hardening it again succeeds' { Protect-BridgeSecretFile -Path $secretFile }
        Test-That 'a loosened file is detected' {
            [IO.File]::SetUnixFileMode($secretFile, [IO.UnixFileMode]'UserRead, UserWrite, GroupRead, OtherRead')
            -not (Test-BridgeSecretFileProtected -Path $secretFile)
        }
        Test-That 'and repaired' { (Protect-BridgeSecretFile -Path $secretFile) -and (Test-BridgeSecretFileProtected -Path $secretFile) }
        Test-That 'a missing file is handled without throwing' {
            (Protect-BridgeSecretFile -Path (Join-Path $env:TEMP ([guid]::NewGuid().ToString('N')))) -eq $false
        }
    }
    finally { Remove-Item -LiteralPath $secretFile -Force -ErrorAction SilentlyContinue }
}
else {
$secretFile = Join-Path $env:TEMP ("bridge-acl-" + [guid]::NewGuid().ToString('N') + '.json')
Set-Content -LiteralPath $secretFile -Value '{"homeAssistant":{"token":"secret"}}' -Encoding UTF8
try {
    $hardened = Protect-BridgeSecretFile -Path $secretFile
    Test-That 'hardening reports success' { $hardened }
    $acl = Get-Acl -LiteralPath $secretFile
    Test-That 'inheritance is disabled' { $acl.AreAccessRulesProtected }
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    Test-That 'only the current user is granted access' {
        (@($acl.Access).Count -eq 1) -and
        ($acl.Access[0].IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -eq $me)
    }
    Test-That 'a missing file is handled without throwing' {
        (Protect-BridgeSecretFile -Path (Join-Path $env:TEMP ([guid]::NewGuid().ToString('N')))) -eq $false
    }

    # Every re-install hardens the same file again. Set-Acl asks for
    # ACCESS_SYSTEM_SECURITY when the descriptor it writes is protected, which a normal
    # user does not have - so the second pass used to fail with a SeSecurityPrivilege
    # warning, and a genuinely weakened ACL could never be repaired.
    Test-That 'hardening an already-hardened file succeeds' { Protect-BridgeSecretFile -Path $secretFile }
    Test-That 'and again, because re-installing is the normal case' {
        (Protect-BridgeSecretFile -Path $secretFile) -and (Protect-BridgeSecretFile -Path $secretFile)
    }
    Test-That 'it recognises a file that is already in the right state' {
        Test-BridgeSecretFileProtected -Path $secretFile
    }

    Test-That 'a weakened ACL is detected' {
        $file = Get-Item -LiteralPath $secretFile
        $sections = [System.Security.AccessControl.AccessControlSections]::Access
        $sd = [System.IO.FileSystemAclExtensions]::GetAccessControl($file, $sections)
        $sd.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            'Everyone', 'Read', 'Allow')))
        [System.IO.FileSystemAclExtensions]::SetAccessControl($file, $sd)
        -not (Test-BridgeSecretFileProtected -Path $secretFile)
    }
    Test-That 'and repaired' {
        (Protect-BridgeSecretFile -Path $secretFile) -and (@((Get-Acl -LiteralPath $secretFile).Access).Count -eq 1)
    }
    Test-That 'a file with inheritance still on is not called protected' {
        $loose = Join-Path $env:TEMP ("bridge-acl-loose-" + [guid]::NewGuid().ToString('N') + '.json')
        Set-Content -LiteralPath $loose -Value '{}' -Encoding UTF8
        try { -not (Test-BridgeSecretFileProtected -Path $loose) }
        finally { Remove-Item -LiteralPath $loose -Force -ErrorAction SilentlyContinue }
    }
}
finally {
    Remove-Item -LiteralPath $secretFile -Force -ErrorAction SilentlyContinue
}
}

Write-Host '--- a scripted run is never offered things only a human can use ---'
Test-That 'console interactivity is reported as a bool' {
    (Test-BridgeConsoleInteractive) -is [bool]
}
Test-That 'this suite runs with input redirected, so it reports non-interactive' {
    # pwsh -File with a redirected stdin is exactly how the installer is driven in
    # tests; the browser offer must not fire there.
    ([Console]::IsInputRedirected) -eq (-not (Test-BridgeConsoleInteractive))
}

Write-Host '--- a command that exists is not the same as a command that works ---'
# npm writes a package's bin entry before it runs the package's postinstall, so a
# postinstall that fails leaves the command on PATH doing nothing. The installer has
# to notice, or re-running it skips the one thing that is actually broken.
$probePwsh = Get-BridgePwshPath
Test-That 'pwsh is available to probe with' { [bool]$probePwsh } "$probePwsh"

$missingExe = Join-Path ([IO.Path]::GetTempPath()) 'bridge-no-such-agent-ffff'
$probeGood = Invoke-BridgeCommandProbe -Executable $probePwsh -Arguments @('-NoProfile', '-Command', 'exit 0')
Test-That 'a command that exits 0 is reported as having run' {
    $probeGood.Ran -and -not $probeGood.TimedOut -and $probeGood.ExitCode -eq 0
} "ran=$($probeGood.Ran) code=$($probeGood.ExitCode)"

$probeBad = Invoke-BridgeCommandProbe -Executable $probePwsh `
    -Arguments @('-NoProfile', '-Command', 'Write-Error cannot-find-module; exit 1')
Test-That 'a command that fails reports its exit code' { $probeBad.Ran -and $probeBad.ExitCode -eq 1 } "code=$($probeBad.ExitCode)"
Test-That 'and what it said, so the failure can be quoted back' { $probeBad.Output -match 'cannot-find-module' } $probeBad.Output

$probeSlow = Invoke-BridgeCommandProbe -Executable $probePwsh `
    -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -TimeoutMs 1500
Test-That 'a command that never answers is killed, not waited on' { $probeSlow.TimedOut } "timedOut=$($probeSlow.TimedOut)"

$probeMissing = Invoke-BridgeCommandProbe -Executable $missingExe
Test-That 'a command that cannot be executed at all is not reported as run' { -not $probeMissing.Ran }

Test-That 'Test-BridgeCommandRuns agrees that pwsh runs' { Test-BridgeCommandRuns -Executable $probePwsh }
Test-That 'and that a missing file does not' { -not (Test-BridgeCommandRuns -Executable $missingExe) }

Write-Host '--- a half-installed agent CLI counts as missing, so a re-run repairs it ---'
# The exact shape of the Claude Code failure on macOS: `claude` on PATH, because npm
# linked it, but its postinstall never finished, so it exits non-zero immediately.
$fakeBin = Join-Path ([IO.Path]::GetTempPath()) ("bridge-fakebin-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
$pathBefore = $env:PATH
function Write-FakeAgent {
    param([string]$Directory, [string]$Command, [int]$Exit)
    if ($script:BridgeIsWindows) {
        $file = Join-Path $Directory "$Command.cmd"
        Set-Content -LiteralPath $file -Encoding ascii -Value @(
            '@echo off'
            $(if ($Exit -eq 0) { 'echo 1.2.3' } else { 'echo postinstall never ran 1>&2' })
            "exit /b $Exit"
        )
    }
    else {
        $file = Join-Path $Directory $Command
        Set-Content -LiteralPath $file -Encoding ascii -Value @(
            '#!/bin/sh'
            $(if ($Exit -eq 0) { 'echo 1.2.3' } else { 'echo postinstall never ran >&2' })
            "exit $Exit"
        )
        & /bin/chmod '+x' $file
    }
    $file
}
try {
    $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $env:PATH

    [void](Write-FakeAgent -Directory $fakeBin -Command 'claude' -Exit 1)
    Test-That 'a claude that is on PATH but exits non-zero is not "installed"' {
        -not (Test-BridgeClientInstalled 'claude')
    }
    Test-That 'so the installer would offer to install it again' {
        -not (Test-BridgeDependencyInstalled 'claude')
    }

    [void](Write-FakeAgent -Directory $fakeBin -Command 'claude' -Exit 0)
    Test-That 'and a claude that answers --version is' {
        Test-BridgeClientInstalled 'claude'
    }
}
finally {
    $env:PATH = $pathBefore
    Remove-Item -LiteralPath $fakeBin -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '--- the install says whether it actually worked ---'
# The install used to end on the same "Next steps" list whether or not any of it had
# worked, so a recovered "Bootstrap failed: 5" scrolling past read as a broken
# install, and a genuinely broken one read as a success.
$allGood = Get-BridgeInstallHealth -Clients @('copilot', 'claude') -OnWindows $true `
    -DaemonProbe { $true } -CommandProbe { $true } -ClientProbe { param($n) $true } `
    -ConnectionProbe { [pscustomobject]@{ Ok = $true; Version = '2026.9.4'; Error = '' } }
Test-That 'every check passes when everything is in place' {
    @($allGood | Where-Object { -not $_.Ok }).Count -eq 0
} (($allGood | Where-Object { -not $_.Ok } | ForEach-Object { $_.Name }) -join ', ')
Test-That 'the daemon, Home Assistant, both clients and the command are all checked' {
    @($allGood).Count -eq 5
} "$(@($allGood).Count)"
Test-That 'the connected version is shown, not just a tick' {
    @($allGood | Where-Object { $_.Detail -eq '2026.9.4' }).Count -eq 1
}
Test-That 'no tmux check on Windows' { @($allGood | Where-Object { $_.Name -match 'tmux' }).Count -eq 0 }
Test-That 'and one on macOS' {
    $mac = Get-BridgeInstallHealth -Clients @() -OnWindows $false -DaemonProbe { $true } -CommandProbe { $true } `
        -TmuxProbe { $false } -ConnectionProbe { [pscustomobject]@{ Ok = $true; Version = 'x'; Error = '' } }
    @($mac | Where-Object { $_.Name -match 'tmux' -and -not $_.Ok }).Count -eq 1
}
Test-That 'mcp is not probed as a command, because it is not one' {
    $withMcp = Get-BridgeInstallHealth -Clients @('mcp') -OnWindows $true -DaemonProbe { $true } -CommandProbe { $true } `
        -ClientProbe { param($n) throw "mcp must not be run as a command" } `
        -ConnectionProbe { [pscustomobject]@{ Ok = $true; Version = 'x'; Error = '' } }
    @($withMcp).Count -eq 3
}

$halfBroken = Get-BridgeInstallHealth -Clients @('claude') -OnWindows $true `
    -DaemonProbe { $false } -CommandProbe { $true } -ClientProbe { param($n) $false } `
    -ConnectionProbe { [pscustomobject]@{ Ok = $false; Version = ''; Error = 'no Home Assistant token' } }
Test-That 'a dead daemon is caught' { @($halfBroken | Where-Object { $_.Name -match 'daemon' -and -not $_.Ok }).Count -eq 1 }
Test-That 'a half-installed agent is caught, the same way the launcher catches it' {
    @($halfBroken | Where-Object { $_.Name -match 'Claude Code' -and -not $_.Ok }).Count -eq 1
}
Test-That 'and the connection error is carried through, not swallowed' {
    @($halfBroken | Where-Object { $_.Detail -eq 'no Home Assistant token' }).Count -eq 1
}
Test-That 'every failed check offers something to do about it' {
    @($halfBroken | Where-Object { -not $_.Ok -and [string]::IsNullOrWhiteSpace($_.Fix) }).Count -eq 0
}
Test-That 'the verdict is true only when nothing failed' {
    (Show-BridgeInstallVerdict -Checks $allGood 6>$null) -eq $true -and
    (Show-BridgeInstallVerdict -Checks $halfBroken 6>$null) -eq $false
}

Write-Host '--- the guidance an agent needs travels with the install, not the repository ---'

# An agent driving the bridge is nearly always working in some other repository, so it
# never reads this one's AGENTS.md. Copilot scans
# $HOME/.copilot/instructions/**/*.instructions.md, so the bridge owns one file there.
$script:InstrRoot = Join-Path ([IO.Path]::GetTempPath()) "bridge-instr-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$script:InstrPath = Join-Path $script:InstrRoot 'instructions\agent-ha-bridge.instructions.md'
try {
    $script:WroteFirst = Install-BridgeAgentInstructions -Path $script:InstrPath

    Test-That 'it writes the file, creating the directory Copilot scans' {
        $script:WroteFirst -and (Test-Path -LiteralPath $script:InstrPath)
    }
    Test-That 'and names it so Copilot actually reads it' {
        [IO.Path]::GetFileName($script:InstrPath).EndsWith('.instructions.md')
    }
    Test-That 'a second install changes nothing, so a re-run does not churn it' {
        (Install-BridgeAgentInstructions -Path $script:InstrPath) -eq $false
    }
    Test-That 'but a damaged file is repaired' {
        Set-Content -LiteralPath $script:InstrPath -Value 'clobbered' -Encoding UTF8
        $repaired = Install-BridgeAgentInstructions -Path $script:InstrPath
        $repaired -and (Get-Content -LiteralPath $script:InstrPath -Raw) -match 'AGENT_HA_AGENT_TOKEN'
    }

    $script:InstrText = Get-BridgeAgentInstructions
    Test-That 'it names the token an agent writes with' {
        $script:InstrText -match 'AGENT_HA_AGENT_TOKEN'
    }
    Test-That 'and that variable is the one the bridge actually hands over' {
        # Tied to the default in decision-bridge-common.ps1: renaming one without the
        # other would ship confident instructions naming a variable nothing sets.
        $common = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1') -Raw
        $common -match "agentTokenEnvVar'\s+'AGENT_HA_AGENT_TOKEN'"
    }
    Test-That 'and says where the answer from a session is read from' {
        $script:InstrText -match '_activity' -and $script:InstrText -match 'response'
    }
    Test-That 'and warns off the notification that cannot be read back' {
        $script:InstrText -match 'persistent_notification'
    }
    Test-That 'and says the bridge owns the file, so nobody hand-edits it' {
        $script:InstrText -match 'uninstall' -and $script:InstrText -match 'overwritten'
    }
}
finally {
    Remove-Item -LiteralPath $script:InstrRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
