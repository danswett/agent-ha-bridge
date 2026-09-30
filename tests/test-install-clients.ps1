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
$realCommandProbe = (Get-Command Test-BridgeCommandRuns).ScriptBlock
function Test-BridgeCommandRuns { param($Executable, $Arguments) $false }
try {
    foreach ($c in @('copilot', 'claude', 'codex', 'mcp')) {
        Test-That "$c detection does not throw" { (Test-BridgeClientInstalled $c) -is [bool] }
    }
}
finally {
    Set-Item -LiteralPath function:Test-BridgeCommandRuns -Value $realCommandProbe
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
        $nativeModeProbe = (Get-Command Test-BridgeUnixModeApi).ScriptBlock
        function Test-BridgeUnixModeApi { $false }
        $legacyModeDirectory = Join-Path $env:TEMP ("bridge-unix-mode-" + [guid]::NewGuid().ToString('N'))
        try {
            Test-That 'older Unix runtimes detect and repair weak modes through stat and chmod' {
                & /bin/chmod '644' $secretFile
                if ($LASTEXITCODE) { throw 'Could not prepare the permission fixture.' }
                -not (Test-BridgeSecretFileProtected -Path $secretFile) -and
                    (Protect-BridgeSecretFile -Path $secretFile) -and
                    [IO.File]::GetUnixFileMode($secretFile) -eq [IO.UnixFileMode]'UserRead, UserWrite'
            }
            Test-That 'the older-runtime path also creates a private credential directory' {
                [void][IO.Directory]::CreateDirectory($legacyModeDirectory)
                (Protect-BridgeSecretFile -Path $legacyModeDirectory) -and
                    [IO.File]::GetUnixFileMode($legacyModeDirectory) -eq [IO.UnixFileMode]'UserRead, UserWrite, UserExecute'
            }
            Test-That 'a native permission-command failure is explicit, not success-shaped' {
                try {
                    Set-BridgeSecretUnixMode -Path (Join-Path $legacyModeDirectory 'missing.json') -Mode '600'
                    $false
                }
                catch { $true }
            }
        }
        finally {
            Set-Item -LiteralPath function:Test-BridgeUnixModeApi -Value $nativeModeProbe
            if (Test-Path -LiteralPath $legacyModeDirectory) { Remove-Item -LiteralPath $legacyModeDirectory -Force }
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

Write-Host '--- credential copies and client cleanup use isolated file-only helpers ---'
$credentialRoot = Join-Path $env:TEMP ("bridge credentials ' " + [char]0x96EA + '-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($credentialRoot)
$env:BRIDGE_TEST_USER_TOKEN = 'synthetic-environment-user-secret'
$env:BRIDGE_TEST_AGENT_TOKEN = 'synthetic-environment-agent-secret'
try {
    . (Join-Path $PSScriptRoot '..\mcp\install-mcp.ps1') -TargetHome $credentialRoot
    $mcpRoot = Join-Path $credentialRoot 'mcp'
    [void][IO.Directory]::CreateDirectory($mcpRoot)
    $fixtureConfigPath = Join-Path $credentialRoot 'config.json'
    $fixtureConfig = [pscustomobject]@{ homeAssistant = [pscustomobject]@{
        baseUrl = 'http://127.0.0.1:1'; token = ''; tokenEnvVar = 'BRIDGE_TEST_USER_TOKEN'
        agentToken = ''; agentTokenEnvVar = 'BRIDGE_TEST_AGENT_TOKEN'; agentUserIds = @('synthetic-agent')
    } }
    $fixtureConfig | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureConfigPath -Encoding utf8
    $block = Get-BridgeMcpServerBlock -Config $fixtureConfig -ConfigPath $fixtureConfigPath -McpDir $mcpRoot
    Test-That 'MCP setup references the bound config without materializing either environment token' {
        $json = $block | ConvertTo-Json -Depth 8
        $block.env.Contains('HA_BRIDGE_CONFIG') -and $block.env.HA_BRIDGE_CONFIG -eq $fixtureConfigPath -and
            $json -notmatch 'synthetic-environment' -and $block.env.Count -eq 1
    }
    $fixtureConfig.homeAssistant.token = 'synthetic-saved-user-secret'
    $fixtureConfig.homeAssistant.agentToken = 'synthetic-saved-agent-secret'
    $savedBlock = Get-BridgeMcpServerBlock -Config $fixtureConfig -ConfigPath $fixtureConfigPath -McpDir $mcpRoot
    Test-That 'saved tokens also stay in their original config rather than client replicas' {
        ($savedBlock | ConvertTo-Json -Depth 8) -notmatch 'synthetic-saved'
    }
    $snippet = Join-Path $mcpRoot 'mcp-client-config.json'
    Write-BridgeMcpSnippet -Path $snippet -ServerBlock $block
    Test-That 'the generated snippet has explicit owner-only protection on its first write' {
        Test-BridgeSecretFileProtected -Path $snippet
    }
    Test-That 'the snippet preserves a spaced apostrophe and Unicode path as one argument' {
        $written = Get-Content -LiteralPath $snippet -Raw | ConvertFrom-Json -AsHashtable
        $written.mcpServers['home-assistant-bridge'].args.Count -eq 1 -and
            $written.mcpServers['home-assistant-bridge'].args[0] -eq (Join-Path $mcpRoot 'src\server.js')
    }

    $desktop = Join-Path $credentialRoot 'desktop.json'
    $other = @{ mcpServers = @{ other = @{ command = 'other-client'; env = @{ OTHER_SECRET = 'synthetic-other-secret' } } }
        preferences = @{ theme = 'dark'; nested = @{ unchanged = @('one', 'two') } } }
    $other | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $desktop -Encoding utf8
    Set-BridgeMcpClientConfig -Path $desktop -ServerBlock $block
    Test-That 'Desktop originals and backups are both explicitly protected' {
        (Test-BridgeSecretFileProtected -Path $desktop) -and
            (Test-BridgeSecretFileProtected -Path "$desktop.bak")
    }
    Test-That 'install preserves unrelated client servers and preferences' {
        $written = Get-Content -LiteralPath $desktop -Raw | ConvertFrom-Json -AsHashtable
        $written.mcpServers.other.env.OTHER_SECRET -eq 'synthetic-other-secret' -and
            $written.preferences.nested.unchanged -join ',' -eq 'one,two'
    }
    Set-BridgeMcpClientConfig -Path $desktop -ServerBlock $savedBlock
    Test-That 'repeated registration does not relax the config or backup permissions' {
        (Test-BridgeSecretFileProtected -Path $desktop) -and (Test-BridgeSecretFileProtected -Path "$desktop.bak")
    }
    Test-That 'registration repairs weakened Desktop and backup permissions' {
        foreach ($file in @($desktop, "$desktop.bak")) {
            if ($script:BridgeIsWindows) {
                $item = Get-Item -LiteralPath $file
                $acl = [IO.FileSystemAclExtensions]::GetAccessControl($item, [Security.AccessControl.AccessControlSections]::Access)
                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('Everyone', 'Read', 'Allow'))
                [IO.FileSystemAclExtensions]::SetAccessControl($item, $acl)
            }
            else { [IO.File]::SetUnixFileMode($file, [IO.UnixFileMode]'UserRead, UserWrite, GroupRead, OtherRead') }
        }
        Set-BridgeMcpClientConfig -Path $desktop -ServerBlock $block
        (Test-BridgeSecretFileProtected -Path $desktop) -and (Test-BridgeSecretFileProtected -Path "$desktop.bak")
    }

    $legacy = @{
        command = 'node'; args = @((Join-Path $mcpRoot 'src\server.js'))
        env = @{ HA_TOKEN = 'synthetic-legacy-secret'; HA_AGENT_TOKEN = 'synthetic-legacy-agent-secret' }
    }
    $old = Get-Content -LiteralPath $desktop -Raw | ConvertFrom-Json -AsHashtable
    $old.mcpServers['home-assistant-bridge'] = $legacy
    $old | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $desktop -Encoding utf8
    $old.preferences.theme = 'backup-only'
    $old | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath "$desktop.bak" -Encoding utf8
    Remove-BridgeMcpClientConfig -Path $desktop -ServerPath (Join-Path $mcpRoot 'src\server.js')
    Test-That 'uninstall removes owned credentials from the original and the existing backup' {
        foreach ($file in @($desktop, "$desktop.bak")) {
            $text = Get-Content -LiteralPath $file -Raw
            if ($text -match 'synthetic-legacy|home-assistant-bridge') { return $false }
        }
        $true
    }
    Test-That 'uninstall preserves each files unrelated data instead of overwriting the backup' {
        $current = Get-Content -LiteralPath $desktop -Raw | ConvertFrom-Json -AsHashtable
        $backup = Get-Content -LiteralPath "$desktop.bak" -Raw | ConvertFrom-Json -AsHashtable
        $current.mcpServers.other.command -eq 'other-client' -and $current.preferences.theme -eq 'dark' -and
            $backup.mcpServers.other.command -eq 'other-client' -and $backup.preferences.theme -eq 'backup-only'
    }
    Remove-Item -LiteralPath $desktop -Force
    $old | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath "$desktop.bak" -Encoding utf8
    Remove-BridgeMcpClientConfig -Path $desktop -ServerPath (Join-Path $mcpRoot 'src\server.js')
    Test-That 'an orphaned Desktop backup is cleaned even when the primary config is absent' {
        (Get-Content -LiteralPath "$desktop.bak" -Raw) -notmatch 'synthetic-legacy|home-assistant-bridge'
    }
    Test-That 'cleanup leaves a same-name registration belonging to another install untouched' {
        $foreign = @{
            mcpServers = @{ 'home-assistant-bridge' = @{
                command = 'node'; args = @((Join-Path $credentialRoot 'other-install\src\server.js'))
                env = @{ HA_TOKEN = 'synthetic-other-install-token' }
            } }
        }
        $foreign | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $desktop -Encoding utf8
        $before = [IO.File]::ReadAllText($desktop)
        if ($script:BridgeIsWindows) {
            $item = Get-Item -LiteralPath $desktop
            $acl = [IO.FileSystemAclExtensions]::GetAccessControl($item, [Security.AccessControl.AccessControlSections]::Access)
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('Everyone', 'Read', 'Allow'))
            [IO.FileSystemAclExtensions]::SetAccessControl($item, $acl)
        }
        else { [IO.File]::SetUnixFileMode($desktop, [IO.UnixFileMode]'UserRead, UserWrite, GroupRead, OtherRead') }
        Remove-BridgeMcpClientConfig -Path $desktop -ServerPath (Join-Path $mcpRoot 'src\server.js') -WarningAction SilentlyContinue
        [IO.File]::ReadAllText($desktop) -ceq $before -and -not (Test-BridgeSecretFileProtected -Path $desktop)
    }
    Test-That 'a malformed client config is not replaced or copied into diagnostics' {
        $malformed = '{"mcpServers":synthetic-invalid-config-secret}'
        Set-Content -LiteralPath $desktop -Value $malformed -NoNewline -Encoding utf8
        try { Set-BridgeMcpClientConfig -Path $desktop -ServerBlock $block; return $false }
        catch {
            $_.Exception.Message -notmatch 'synthetic-invalid-config-secret' -and
                [IO.File]::ReadAllText($desktop) -ceq $malformed
        }
    }

    $realProtector = (Get-Command Protect-BridgeSecretFile).ScriptBlock
    $script:ProtectionObservations = @()
    function Protect-BridgeSecretFile {
        param([string]$Path)
        $script:ProtectionObservations += [pscustomobject]@{
            Path = $Path; Before = if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::ReadAllText($Path) } else { '' }
        }
        & $realProtector -Path $Path
    }
    try {
        $private = Join-Path $credentialRoot 'new private directory\config.json'
        Test-That 'a new main config is protected while empty, before its credential bytes are written' {
            Write-BridgeSecretFile -Path $private -Content 'synthetic-write-secret'
            (Test-BridgeSecretFileProtected -Path $private) -and [IO.File]::ReadAllText($private) -eq 'synthetic-write-secret' -and
                @($script:ProtectionObservations | Where-Object { $_.Path -eq $private -and $_.Before -eq '' }).Count -gt 0
        }
        Test-That 'a new backup is protected while empty and keeps the exact original bytes' {
            Copy-BridgeSecretFile -Source $private -Destination "$private.bak"
            (Test-BridgeSecretFileProtected -Path "$private.bak") -and
                [IO.File]::ReadAllText("$private.bak") -ceq [IO.File]::ReadAllText($private) -and
                @($script:ProtectionObservations | Where-Object { $_.Path -eq "$private.bak" -and $_.Before -eq '' }).Count -gt 0
        }
    }
    finally { Set-Item -LiteralPath function:Protect-BridgeSecretFile -Value $realProtector }

    function Protect-BridgeSecretFile { param([string]$Path) $false }
    try {
        Test-That 'MCP writes fail closed without writing secret bytes if protection fails' {
            $denied = Join-Path $credentialRoot 'denied.json'
            try { Write-BridgeMcpSnippet -Path $denied -ServerBlock $legacy; return $false }
            catch {
                $_.Exception.Message -notmatch 'synthetic-legacy' -and
                    (-not (Test-Path -LiteralPath $denied) -or [IO.File]::ReadAllText($denied) -eq '')
            }
            Test-That 'a failed protection step does not overwrite an existing credential file' {
                $existing = Join-Path $credentialRoot 'unchanged.json'
                Set-Content -LiteralPath $existing -Value 'synthetic-original-secret' -NoNewline
                try { Write-BridgeSecretFile -Path $existing -Content 'synthetic-replacement-secret'; return $false }
                catch { [IO.File]::ReadAllText($existing) -ceq 'synthetic-original-secret' }
            }
        }
    }
    finally { Set-Item -LiteralPath function:Protect-BridgeSecretFile -Value $realProtector }
}
finally {
    Remove-Item Env:\BRIDGE_TEST_USER_TOKEN, Env:\BRIDGE_TEST_AGENT_TOKEN -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $credentialRoot -Recurse -Force
}

Write-Host '--- token prompts request masked input ---'
function Read-Host {
    param([string]$Prompt, [switch]$AsSecureString)
    if (-not $AsSecureString) { throw 'Token input must be masked.' }
    [Net.NetworkCredential]::new('', 'synthetic-entered-secret').SecurePassword
}
try {
    Test-That 'the secret prompt reads a SecureString without echoing it' {
        (Read-BridgeSecret -Prompt 'Synthetic token' -InputRedirected $false) -eq 'synthetic-entered-secret'
    }
}
finally { Remove-Item Function:\Read-Host }

Write-Host '--- redirected token input is consumed without a terminal or an echo ---'
$inputRoot = Join-Path $env:TEMP ('bridge-secret-input-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($inputRoot)
$inputProbe = Join-Path $inputRoot 'read-secret.ps1'
$probeText = @'
$ErrorActionPreference = 'Stop'
. '__SECRETS__'
$choice = Read-Host 'Choice'
$token = Read-BridgeSecret -Prompt 'Token'
if ($choice -ne '1' -or $token -cne 'synthetic-piped-token') { throw 'Redirected input was not consumed correctly.' }
Write-Output 'piped secret verified'
'@
$helperPath = (Join-Path $PSScriptRoot '..\hooks\bridge-secrets.ps1').Replace("'", "''")
$probeText.Replace('__SECRETS__', $helperPath) | Set-Content -LiteralPath $inputProbe -Encoding utf8
$inputProcess = [Diagnostics.Process]::new()
$started = $false
try {
    # Only a prompt helper is run, not an installer. This process inherits the
    # canonical runner's already-scrubbed environment and receives synthetic input.
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $inputProbe)) { $start.ArgumentList.Add($argument) }
    $inputProcess.StartInfo = $start
    $started = $inputProcess.Start()
    $stdout = $inputProcess.StandardOutput.ReadToEndAsync()
    $stderr = $inputProcess.StandardError.ReadToEndAsync()
    $inputProcess.StandardInput.WriteLine('1')
    $inputProcess.StandardInput.WriteLine('synthetic-piped-token')
    $inputProcess.StandardInput.Close()
    $finished = $inputProcess.WaitForExit(5000)
    if (-not $finished) { $inputProcess.Kill($true); $inputProcess.WaitForExit() }
    $inputOutput = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    Test-That 'a token after a normal prompt is read from redirected stdin without hanging' {
        $finished -and $inputProcess.ExitCode -eq 0 -and $inputOutput -match 'piped secret verified'
    }
    Test-That 'redirected token input is not echoed into either output stream' {
        $finished -and $inputOutput -notmatch 'synthetic-piped-token'
    }
}
finally {
    if ($started -and -not $inputProcess.HasExited) { $inputProcess.Kill($true); $inputProcess.WaitForExit() }
    $inputProcess.Dispose()
    Remove-Item -LiteralPath $inputRoot -Recurse -Force
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

    $script:InstrText = Get-BridgeAgentInstructions -HasAgentToken
    Test-That 'it names the token an agent writes with' {
        $script:InstrText -match 'AGENT_HA_AGENT_TOKEN'
    }
    Test-That 'and that variable is the one the bridge actually hands over' {
        # Tied to the default in decision-bridge-common.ps1: renaming one without the
        # other would ship confident instructions naming a variable nothing sets.
        $common = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1') -Raw
        $common -match "agentTokenEnvVar'\s+'AGENT_HA_AGENT_TOKEN'"
    }
    Test-That 'a renamed variable is what the instructions name' {
        # Get-BridgeAgentTokenEnvironment exports whatever agentTokenEnvVar says, so a
        # fixed name here would point an override at a variable nothing sets.
        $renamed = Get-BridgeAgentInstructions -EnvVarName 'HOUSE_AGENT_TOKEN' -HasAgentToken
        ($renamed -match 'HOUSE_AGENT_TOKEN') -and ($renamed -notmatch 'AGENT_HA_AGENT_TOKEN')
    }
    Test-That 'with no agent token configured it does not promise one is there' {
        # The variable is only exported when a token exists; claiming otherwise sends
        # an agent off to build an empty bearer header.
        $none = Get-BridgeAgentInstructions
        $none -match 'No agent account is configured' -and $none -match 'configure -AgentToken'
    }
    Test-That 'and says where the answer is read from' {
        $script:InstrText -match '_activity' -and $script:InstrText -match 'response'
    }
    Test-That 'and warns off the notification that cannot be read back' {
        $script:InstrText -match 'persistent_notification'
    }
    Test-That 'and warns that a stale response is kept while the next turn starts' {
        $script:InstrText -match 'previous'
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
