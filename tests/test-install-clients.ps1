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
. (Join-Path $PSScriptRoot 'runner-support.ps1')
Assert-BridgeTestEnvironment -Required

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

if ($IsWindows) {
    # npm installs its clients as .cmd shims, and Get-BridgeCodexPath falls back to
    # %APPDATA%\npm\codex.cmd outright - so a probe that could not run a batch file
    # would report a working client as unrunnable and refuse every launch. Worth
    # pinning rather than assuming: CreateProcess is often said not to run batch
    # files, and the probe no longer goes through Start-Process.
    $shimRoot = Join-Path $env:TEMP "probe-shim-$([guid]::NewGuid().ToString('N'))"
    [void][IO.Directory]::CreateDirectory($shimRoot)
    $shimPath = Join-Path $shimRoot 'probe-shim.cmd'
    [IO.File]::WriteAllText($shimPath, "@echo off`r`necho shim-version 9.9.9`r`nexit /b 0")
    try {
        $probeShim = Invoke-BridgeCommandProbe -Executable $shimPath -TimeoutMs 20000
        Test-That 'a .cmd shim runs and its version is read back' {
            $probeShim.Ran -and -not $probeShim.TimedOut -and $probeShim.ExitCode -eq 0 -and
                $probeShim.StandardOutput -match 'shim-version 9\.9\.9'
        } "ran=$($probeShim.Ran) code=$($probeShim.ExitCode) out=$($probeShim.Output)"
        Test-That 'and such a client counts as actually runnable' {
            Test-BridgeCommandRuns -Executable $shimPath -TimeoutMs 20000
        }
    }
    finally { Remove-Item -LiteralPath $shimRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($IsWindows) {
    Write-Host '--- background probes never recreate a detached daemon console ---'
    $consoleRoot = Join-Path $env:TEMP "probe-console-$([guid]::NewGuid().ToString('N'))"
    [void][IO.Directory]::CreateDirectory($consoleRoot)
    $consoleScript = Join-Path $consoleRoot 'probe.ps1'
    $platformPath = (Join-Path $PSScriptRoot '..\hooks\bridge-platform.ps1').Replace("'", "''")
    $childSource = @'
$ErrorActionPreference = 'Stop'
. '__PLATFORM__'
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ProbeConsole {
    [DllImport("kernel32.dll")] public static extern bool FreeConsole();
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
}
"@
$null = [ProbeConsole]::FreeConsole()
$pwsh = (Get-Process -Id $PID).Path
$code = '[Console]::WriteLine("first"); [Console]::WriteLine("second"); [Console]::Error.WriteLine("error"); exit 3'
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
$probe = Invoke-BridgeCommandProbe -Executable $pwsh -Arguments @('-NoProfile', '-EncodedCommand', $encoded)
if (-not $probe.Ran -or $probe.ExitCode -ne 3 -or $probe.StandardOutput -notmatch "first\r?\nsecond" -or $probe.Output -notmatch 'error') {
    throw "Probe output was not preserved: $($probe | ConvertTo-Json -Compress)"
}
if ([ProbeConsole]::GetConsoleWindow() -ne [IntPtr]::Zero) { throw 'Probe allocated a console for its detached parent.' }
# The window the user sees belongs to the *child*. The parent's own
# GetConsoleWindow() reads zero whether or not one appeared, so the checks above
# passed for months while every probe from a console-less daemon put a Windows
# Terminal window on screen and took the focus with it. Ask the child instead.
$windowCode = @"
Add-Type -Namespace Probe -Name Win -MemberDefinition '[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();'
[Console]::WriteLine("childConsoleWindow=" + [Probe.Win]::GetConsoleWindow())
"@
$windowEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($windowCode))
$windowProbe = Invoke-BridgeCommandProbe -Executable $pwsh -Arguments @('-NoProfile', '-EncodedCommand', $windowEncoded) -TimeoutMs 60000
if (-not $windowProbe.Ran -or $windowProbe.ExitCode -ne 0) {
    throw "The console-window probe did not run: $($windowProbe | ConvertTo-Json -Compress)"
}
if ($windowProbe.StandardOutput -notmatch 'childConsoleWindow=0\s*$') {
    throw "A probe started from a console-less parent gave its child a console window: $($windowProbe.StandardOutput)"
}
$slow = Invoke-BridgeCommandProbe -Executable $pwsh -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -TimeoutMs 1000
if (-not $slow.TimedOut) { throw 'The background command deadline was not enforced.' }
if ([ProbeConsole]::GetConsoleWindow() -ne [IntPtr]::Zero) { throw 'Timed-out probe allocated a console.' }
$cache = Join-Path $PSScriptRoot 'type-cache'
Add-BridgeCompiledType -TypeName ConsoleFreeCompiledType -Source 'public class ConsoleFreeCompiledType {}' -CacheDir $cache
if (-not ([Management.Automation.PSTypeName]'ConsoleFreeCompiledType').Type) { throw 'The background type was not compiled.' }
if ([ProbeConsole]::GetConsoleWindow() -ne [IntPtr]::Zero) { throw 'Type compilation allocated a console.' }
'console-free'
'@
    [IO.File]::WriteAllText($consoleScript, $childSource.Replace('__PLATFORM__', $platformPath))
    $consoleProcess = [Diagnostics.Process]::new()
    try {
        $start = [Diagnostics.ProcessStartInfo]::new($probePwsh)
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $consoleScript)) { $start.ArgumentList.Add($argument) }
        $consoleProcess.StartInfo = $start
        [void]$consoleProcess.Start()
        $consoleProcess.StandardInput.Close()
        $consoleOut = $consoleProcess.StandardOutput.ReadToEndAsync()
        $consoleErr = $consoleProcess.StandardError.ReadToEndAsync()
        # 90 seconds, not 15. This child compiles C# three times over - its own
        # P/Invoke block, the console-window probe's, and Add-BridgeCompiledType's
        # separate pwsh - and on a cold hosted runner those cost far more than they do
        # warm. At 15 the child was killed mid-compile, which surfaced as a bare
        # assertion failure with no output at all rather than as the timeout it was.
        $consoleFinished = $consoleProcess.WaitForExit(90000)
        if (-not $consoleFinished) { $consoleProcess.Kill($true); $consoleProcess.WaitForExit() }
        $consoleText = $consoleOut.GetAwaiter().GetResult() + $consoleErr.GetAwaiter().GetResult()
        Test-That 'a detached background process preserves output and deadlines without a console' {
            $consoleFinished -and $consoleProcess.ExitCode -eq 0 -and $consoleText -match 'console-free'
        } "finished=$consoleFinished exit=$(if ($consoleFinished) { $consoleProcess.ExitCode } else { 'killed' }) output=$consoleText"
    }
    finally {
        $consoleProcess.Dispose()
        Remove-Item -LiteralPath $consoleScript -Force
        $consoleCache = Join-Path $consoleRoot 'type-cache'
        if (Test-Path -LiteralPath $consoleCache) {
            Get-ChildItem -LiteralPath $consoleCache -File | Remove-Item -Force
            Remove-Item -LiteralPath $consoleCache -Force
        }
        Remove-Item -LiteralPath $consoleRoot -Force
    }
}

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

Write-Host '--- two installations keep their roots and enrollment separate ---'
$isolationRoot = Join-Path $env:TEMP ('bridge-isolation-' + [guid]::NewGuid().ToString('N'))
$savedIsolationConfig = $env:AGENT_HA_BRIDGE_CONFIG
$savedIsolationCodex = $env:CODEX_HOME
$homes = @((Join-Path $isolationRoot 'home A'), (Join-Path $isolationRoot 'home B'))
$registrationFiles = @()
try {
    foreach ($homeRoot in $homes) {
        $bridge = Join-Path $homeRoot '.agent-ha-bridge'
        foreach ($relative in @('hooks', 'bin', 'installer', 'installer\hooks', 'installer\claude', 'installer\codex')) {
            [void][IO.Directory]::CreateDirectory((Join-Path $bridge $relative))
        }
        @{ clients = @('claude'); homeAssistant = @{ baseUrl = 'http://127.0.0.1:1'; token = 'synthetic-isolation-token' } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $bridge 'config.json') -Encoding utf8
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\bin\agent-ha-bridge.ps1') -Destination (Join-Path $bridge 'bin\agent-ha-bridge.ps1')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\update.ps1') -Destination (Join-Path $bridge 'installer\update.ps1')
        foreach ($relative in @('installer\install.ps1', 'uninstall.ps1', 'installer\claude\install-claude.ps1', 'installer\codex\install-codex.ps1')) {
            Set-Content -LiteralPath (Join-Path $bridge $relative) -Encoding utf8 -Value @'
[CmdletBinding()]
param([string]$TargetHome, [string]$InstallRoot, [switch]$ClearEntities)
@{ TargetHome = $TargetHome } | ConvertTo-Json -Compress
'@
        }
        foreach ($relative in @('hooks', 'installer\hooks')) {
            foreach ($helper in @('bridge-platform.ps1', 'bridge-install-context.ps1')) {
                Copy-Item -LiteralPath (Join-Path $PSScriptRoot "..\hooks\$helper") -Destination (Join-Path $bridge "$relative\$helper")
            }
            Set-Content -LiteralPath (Join-Path $bridge "$relative\decision-bridge-common.ps1") -Value '# inert update dependency' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $bridge "$relative\bridge-update.ps1") -Encoding utf8 -Value @'
function Get-BridgeUpdateRepository { 'selected-install' }
function Get-BridgeUpdateStatus {
    param([switch]$Force)
    [pscustomobject]@{ Installed = '1'; Latest = '1'; Available = $false; LookupState = 'Found'; State = 'Current' }
}
'@
        }
    }
    $fixtureAmbientHome = (Get-BridgeTestSandbox -Root $env:AGENT_HA_BRIDGE_TEST_ROOT)['home']
    [void](New-BridgeTestAmbientInstall -HomeDirectory $fixtureAmbientHome)
    $pwshFixture = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    foreach ($homeRoot in $homes) {
        $cli = Join-Path $homeRoot '.agent-ha-bridge\bin\agent-ha-bridge.ps1'
        foreach ($operation in @('configure', 'uninstall')) {
            $child = Invoke-BridgeTestProcess -StartInfo (New-BridgeTestProcessStartInfo `
                -ScriptPath $cli -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT -ScriptArguments @($operation))
            if ($child.TimedOut) { throw 'The synthetic installation child timed out.' }
            $output = @($child.Output -split '\r?\n')
            $exit = $child.ExitCode
            $record = $output | Where-Object { [string]$_ -like '{"TargetHome"*' } | Select-Object -Last 1 | ConvertFrom-Json
            Test-That "$operation carries the owning home for $(Split-Path $homeRoot -Leaf)" {
                $exit -eq 0 -and $record.TargetHome -eq $homeRoot
            }
        }
        $child = Invoke-BridgeTestProcess -StartInfo (New-BridgeTestProcessStartInfo `
            -ScriptPath $cli -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT -ScriptArguments @('update', '-Check', '-Yes'))
        if ($child.TimedOut) { throw 'The synthetic update-check child timed out.' }
        $output = $child.Output
        Test-That "the real update entry point uses $(Split-Path $homeRoot -Leaf), not ambient HOME" {
            $child.ExitCode -eq 0 -and $output -match 'selected-install' -and $output -notmatch 'other-install'
        }
    }

    $runtimePaths = @()
    $attachmentPaths = @()
    $codexPaths = @()
    $sameSession = 'p2-' + [guid]::NewGuid().ToString('N')
    foreach ($homeRoot in $homes) {
        $env:AGENT_HA_BRIDGE_CONFIG = Join-Path $homeRoot '.agent-ha-bridge\config.json'
        $env:CODEX_HOME = Join-Path $homeRoot '.codex'
        . (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
        . (Join-Path $PSScriptRoot '..\hooks\daemon-hookspool.ps1')
        . (Join-Path $PSScriptRoot '..\hooks\daemon-replies.ps1')
        . (Join-Path $PSScriptRoot '..\codex\hooks\codex-session.ps1')
        $runtimePaths += [pscustomobject]@{ Heartbeat = Get-BridgeDaemonHeartbeat; Spool = $script:DaemonHookSpoolDirectory }
        $attachmentPaths += Get-BridgeAttachmentRoot
        $path = Write-CodexSessionRegistration -SessionId $sameSession -ProcessId 424242 -WorkingDirectory $homeRoot -Status 'idle'
        $codexPaths += $path
        $registrationFiles += $path
        if ($homeRoot -eq $homes[0]) { $firstRegistration = [IO.File]::ReadAllText($path) }
    }
    Test-That 'the two real heartbeat readers have different roots' { $runtimePaths[0].Heartbeat -ne $runtimePaths[1].Heartbeat }
    Test-That 'the two real spool readers have different roots' { $runtimePaths[0].Spool -ne $runtimePaths[1].Spool }
    Test-That 'new attachment storage is installation-specific' { $attachmentPaths[0] -ne $attachmentPaths[1] }
    Test-That 'Codex writes the same session ID into different owned files' { $codexPaths[0] -ne $codexPaths[1] }
    Test-That 'writing B leaves the actual A registration unchanged' { [IO.File]::ReadAllText($codexPaths[0]) -ceq $firstRegistration }
    $env:AGENT_HA_BRIDGE_CONFIG = Join-Path $homes[1] '.agent-ha-bridge\missing.json'
    Test-That 'a missing explicit config cannot fall through into ambient HOME' {
        try { $null -eq (Get-BridgeUserConfig) } catch { $_.Exception.Message -like '*missing.json*' }
    }
    $env:AGENT_HA_BRIDGE_CONFIG = Join-Path $homes[1] '.agent-ha-bridge\config.json'
    . (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
    . (Join-Path $PSScriptRoot '..\hooks\daemon-agents.ps1')
    . (Join-Path $PSScriptRoot '..\hooks\daemon-maintenance.ps1')
    $script:DaemonInstallerPayload = Join-Path $homes[1] '.agent-ha-bridge\installer'
    $script:DaemonClientSetup = @{}
    $script:SetupCalls = @()
    function Get-BridgeLauncherPath { param($Launcher) "synthetic-$Launcher" }
    function Get-BridgeLauncherLabel { param($Launcher) $Launcher }
    function Write-DaemonLog { param($Message) }
    function Start-Process {
        param($FilePath, $ArgumentList, [switch]$PassThru, $RedirectStandardOutput, $RedirectStandardError, $ErrorAction, $WindowStyle)
        $script:SetupCalls += [string]$ArgumentList
        [pscustomobject]@{ Id = 424242; HasExited = $false }
    }
    try {
        Sync-DaemonClients -Headers @{}
        Test-That 'maintenance does not enroll unselected Copilot or Codex' {
            @($script:SetupCalls | Where-Object { $_ -notmatch 'install-claude\.ps1' }).Count -eq 0
        }
    }
    finally { Remove-Item Function:\Start-Process, Function:\Get-BridgeLauncherPath, Function:\Get-BridgeLauncherLabel, Function:\Write-DaemonLog }

    Write-Host '--- persisted identities, owned runtime and actual uninstall orchestration ---'
    $contextA = Initialize-BridgeInstallIdentity -Context (Resolve-BridgeInstallContext -TargetHome $homes[0])
    $contextB = Initialize-BridgeInstallIdentity -Context (Resolve-BridgeInstallContext -TargetHome $homes[1])
    Test-That 'installation identities persist and do not collide' {
        $contextA.Id -ne $contextB.Id -and
            (Resolve-BridgeInstallContext -BridgeHome $contextA.BridgeHome).Id -ceq $contextA.Id -and
            $contextA.TaskName -ne $contextB.TaskName
    }
    Test-That 'isolated roots do not inherit ambient client or Desktop settings' {
        $contextA.CopilotHome -eq (Join-Path $homes[0] '.copilot') -and
            $contextA.ClaudeHome -eq (Join-Path $homes[0] '.claude') -and
            $contextA.CodexHome -eq (Join-Path $homes[0] '.codex') -and
            (Test-BridgeInstallDescendant $contextA.DesktopConfig $homes[0])
    }
    $savedAttachmentContext = $script:BridgeInstallContext
    $savedAttachmentPlatform = $script:BridgeIsWindows
    try {
        $script:BridgeInstallContext = Resolve-BridgeInstallContext -TargetHome (Join-Path $isolationRoot 'home with spaces')
        Test-That 'a spaced installation keeps its canonical private attachment path without a TEMP fallback' {
            $parent = if ($script:BridgeIsWindows) {
                Join-Path $script:BridgeInstallContext.LocalAppData 'agent-ha-bridge\attachments'
            } else { Join-Path $script:BridgeInstallContext.BridgeHome 'attachments' }
            $expected = Join-Path $parent "install-$($script:BridgeInstallContext.Id)"
            (Get-BridgeAttachmentRoot -NoCreate) -eq $expected
        }
    }
    finally {
        $script:BridgeInstallContext = $savedAttachmentContext
        $script:BridgeIsWindows = $savedAttachmentPlatform
    }
    Test-That 'automatic repair reads the real selection and cannot opt an omitted adapter in' {
        try { Assert-BridgeAdapterSelection -Context $contextA -Client codex; $false }
        catch { $_.Exception.Message -like '*not selected*' }
    }
    Test-That 'automatic repair accepts a genuinely selected adapter through the actual reader' {
        Assert-BridgeAdapterSelection -Context $contextA -Client claude
        $true
    }
    Set-BridgeAdapterEnrollment -Context $contextA -Client codex -Installed $true
    Test-That 'an explicitly invoked adapter installer records the deliberate selection' {
        (Get-Content -LiteralPath $contextA.ConfigPath -Raw | ConvertFrom-Json).clients -contains 'codex'
    }
    Set-BridgeAdapterEnrollment -Context $contextA -Client codex -Installed $false -KeepSelection
    Test-That 'whole-install removal can retain the selected clients for KeepConfig' {
        (Get-Content -LiteralPath $contextA.ConfigPath -Raw | ConvertFrom-Json).clients -contains 'codex' -and
            (Get-Content -LiteralPath $contextA.MetadataPath -Raw | ConvertFrom-Json).adapters -notcontains 'codex'
    }
    Set-BridgeAdapterEnrollment -Context $contextA -Client mcp -Installed $true
    $savedSelectionContext = $script:BridgeInstallContext
    $savedSelectionConfig = $script:BridgeUserConfig
    $savedStopRuntime = (Get-Command Stop-BridgeOwnedRuntime).ScriptBlock
    $savedInstallerContext = $installContext
    try {
        $script:BridgeInstallContext = $contextA
        $script:BridgeUserConfig = [pscustomobject]@{ clients = @('claude', 'codex', 'mcp') }
        Set-BridgeAdapterEnrollment -Context $contextA -Client codex -Installed $false
        Test-That 'a running installation observes a saved adapter opt-out rather than its startup selection' {
            (Get-BridgeSelectedClients) -notcontains 'codex' -and (Get-BridgeSelectedClients) -contains 'claude'
        }
        $installContext = $contextA
        Set-Variable -Name KeepSelection -Value $false
        function Stop-BridgeOwnedRuntime {
            param($Context, [string[]]$Roles)
            $script:AdapterStopRoles = $Roles -join ','
            $script:AdapterSelectionAtStop = @((Read-BridgeInstallRecord -Path $Context.ConfigPath)['clients'])
            $script:AdapterRecordsAtStop = @((Read-BridgeInstallRecord -Path $Context.MetadataPath)['adapters'])
        }
        foreach ($client in @('claude', 'codex', 'mcp')) {
            Set-BridgeAdapterEnrollment -Context $contextA -Client $client -Installed $true
            $ast = [Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $PSScriptRoot "..\$client\install-$client.ps1"), [ref]$null, [ref]$null)
            $branch = $ast.EndBlock.Statements | Where-Object {
                $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$Uninstall'
            } | Select-Object -First 1
            if (-not $branch) { throw "No actual $client uninstall branch was found." }
            $prefix = @(foreach ($statement in $branch.Clauses[0].Item2.Statements) {
                if ($statement.Extent.Text -match '^Remove-Bridge') { break }
                $statement.Extent.Text
            })
            & ([scriptblock]::Create($prefix -join "`n"))
            Test-That "standalone $client removal stops only that adapters setup worker" {
                $script:AdapterStopRoles -eq "setup-$client"
            }
            Test-That "standalone $client opts out before stopping setup, retaining cleanup ownership until success" {
                $script:AdapterSelectionAtStop -notcontains $client -and $script:AdapterRecordsAtStop -contains $client
            }
        }
        Set-BridgeAdapterEnrollment -Context $contextA -Client claude -Installed $true
        Set-BridgeAdapterEnrollment -Context $contextA -Client mcp -Installed $true
    }
    finally {
        Set-Item Function:\Stop-BridgeOwnedRuntime -Value $savedStopRuntime
        $installContext = $savedInstallerContext
        $script:BridgeInstallContext = $savedSelectionContext
        $script:BridgeUserConfig = $savedSelectionConfig
    }
    $customRoot = Join-Path $homes[0] 'custom-bridge'
    $customContext = Initialize-BridgeInstallIdentity -Context (
        Resolve-BridgeInstallContext -TargetHome $homes[0] -BridgeHome $customRoot)
    [void][IO.Directory]::CreateDirectory((Join-Path $customRoot 'installer'))
    [void][IO.Directory]::CreateDirectory($customContext.HooksDir)
    [IO.File]::WriteAllText((Join-Path $customRoot 'installer\install.ps1'), '# synthetic installed payload')
    [IO.File]::WriteAllText($customContext.ConfigPath, '{"clients":[]}')
    Remove-Item -LiteralPath $customContext.MetadataPath -Force
    Test-That 'a damaged custom core cannot fall through to another installation without its metadata' {
        try { $null = Resolve-BridgeInstallContext -EntryDirectory $customContext.HooksDir; $false }
        catch { $_.Exception.Message -match 'metadata.*missing|missing.*metadata' }
    }
    $taskA = [pscustomobject]@{ Actions = @([pscustomobject]@{
        Execute = 'wscript.exe'; Arguments = '"' + (Join-Path $contextA.HooksDir 'agent-bridge-launch.vbs') + '"'
    }) }
    Test-That 'task ownership requires the exact installation launcher, not the task name' {
        (Test-BridgeTaskOwnership -Task $taskA -Context $contextA) -and
            -not (Test-BridgeTaskOwnership -Task $taskA -Context $contextB)
    }
    Test-That 'an owned launcher does not claim unrelated actions in the same task' {
        $mixedTask = [pscustomobject]@{ Actions = @($taskA.Actions) + @([pscustomobject]@{
            Execute = 'unrelated.exe'; Arguments = ''
        }) }
        -not (Test-BridgeTaskOwnership -Task $mixedTask -Context $contextA)
    }
    $savedInstallerContext = $installContext
    $savedServicePlatform = $script:BridgeIsWindows
    $script:RetiredLegacyTasks = @()
    $installContext = $contextA | Select-Object *
    $installContext.Recorded = $false
    $installContext.Legacy = $true
    $installContext.Isolated = $false
    $installContext.TaskName = 'AgentBridgeDaemon'
    $script:BridgeIsWindows = $true
    function Get-ScheduledTask { param($TaskName, $ErrorAction) if ($TaskName -eq 'AgentBridgeDaemon') { $taskA } }
    function Stop-ScheduledTask { param($TaskName, $ErrorAction) }
    function Unregister-ScheduledTask {
        [CmdletBinding(SupportsShouldProcess)]
        param($TaskName)
        if ($PSCmdlet.ShouldProcess($TaskName, 'Remove fixture task')) { $script:RetiredLegacyTasks += $TaskName }
    }
    try {
        $installerAst = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot '..\install.ps1'), [ref]$null, [ref]$null)
        $stopService = $installerAst.Find({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Stop-BridgeOwnedService'
        }, $true)
        if (-not $stopService) { throw 'The actual installer service shutdown was not found.' }
        & ([scriptblock]::Create($stopService.Extent.Text))
        Test-That 'the actual installer retires its verified legacy task before identity rollover' {
            $script:RetiredLegacyTasks -join ',' -eq 'AgentBridgeDaemon'
        }
    }
    finally {
        $installContext = $savedInstallerContext
        $script:BridgeIsWindows = $savedServicePlatform
        Remove-Item Function:\Get-ScheduledTask, Function:\Stop-ScheduledTask, Function:\Unregister-ScheduledTask
    }
    $plistPath = Join-Path $contextA.Home "Library\LaunchAgents\$($contextA.LaunchAgentLabel).plist"
    [void][IO.Directory]::CreateDirectory((Split-Path $plistPath -Parent))
    $plistExecutable = [Security.SecurityElement]::Escape($pwshFixture)
    $plistScript = [Security.SecurityElement]::Escape((Join-Path $contextA.HooksDir 'agent-bridge-daemon.ps1'))
    $ownedPlist = "<plist><dict><key>ProgramArguments</key><array><string>$plistExecutable</string><string>-NoProfile</string><string>-File</string><string>$plistScript</string></array></dict></plist>"
    [IO.File]::WriteAllText($plistPath, $ownedPlist)
    Test-That 'a LaunchAgent claims only its actual installation script' {
        (Test-BridgeLaunchAgentOwnership -Path $plistPath -Context $contextA) -and
            -not (Test-BridgeLaunchAgentOwnership -Path $plistPath -Context $contextB)
    }
    [IO.File]::WriteAllText($plistPath, $ownedPlist.Replace('<string>-NoProfile</string>', '<string>-Command</string><string>Write-Output</string>'))
    Test-That 'a LaunchAgent command mentioning File is not an owned script invocation' {
        -not (Test-BridgeLaunchAgentOwnership -Path $plistPath -Context $contextA)
    }
    [IO.File]::WriteAllText($plistPath, $ownedPlist)
    $savedWindows = $script:BridgeIsWindows
    $contextA.Isolated = $false
    $script:BridgeIsWindows = $false
    $script:LaunchdFixtureMode = 'failed'
    $script:LaunchdStopCalls = 0
    function id { param($Option) $global:LASTEXITCODE = 0; '1000' }
    function launchctl {
        param($Action, $Service)
        if ($Action -eq 'bootout') {
            $script:LaunchdStopCalls++
            $global:LASTEXITCODE = if ($script:LaunchdFixtureMode -eq 'failed') { 5 } else { 0 }
            if ($global:LASTEXITCODE -eq 0) { $script:LaunchdFixtureMode = 'absent' }
        }
        else { $global:LASTEXITCODE = if ($script:LaunchdFixtureMode -eq 'absent') { 113 } else { 0 } }
    }
    try {
        Test-That 'a failed service shutdown preserves its registration and blocks cleanup' {
            $rejected = $false
            try { Stop-BridgeOwnedService -Context $contextA -Remove }
            catch { $rejected = $_.Exception.Message -match 'stop|shutdown|bootout' }
            $rejected -and (Test-Path -LiteralPath $plistPath)
        }
        $script:LaunchdFixtureMode = 'running'
        $script:LaunchdStopCalls = 0
        Stop-BridgeOwnedService -Context $contextA -Remove
        Test-That 'confirmed service shutdown removes only the owned LaunchAgent' {
            $script:LaunchdStopCalls -eq 1 -and -not (Test-Path -LiteralPath $plistPath)
        }
        [IO.File]::WriteAllText($plistPath, $ownedPlist)
        $script:LaunchdStopCalls = 0
        Stop-BridgeOwnedService -Context $contextA -Remove
        Test-That 'a positively absent service needs no stop before its owned registration is removed' {
            $script:LaunchdStopCalls -eq 0 -and -not (Test-Path -LiteralPath $plistPath)
        }
    }
    finally {
        $contextA.Isolated = $true
        $script:BridgeIsWindows = $savedWindows
        Remove-Item Function:\id, Function:\launchctl
    }
    $started = [datetime]'2026-01-01T00:00:00Z'
    $script:OwnedProcessFixture = @{}
    foreach ($fixture in @(
        @{ Id = 910001; Context = $contextA; Role = 'supervisor' },
        @{ Id = 910002; Context = $contextA; Role = 'daemon' },
        @{ Id = 910003; Context = $contextB; Role = 'daemon' },
        @{ Id = 910005; Context = $contextA; Role = 'devbox-keepawake' },
        @{ Id = 910006; Context = $contextB; Role = 'devbox-keepawake' }
    )) {
        $scriptPath = Join-Path $fixture.Context.HooksDir "agent-bridge-$($fixture.Role).ps1"
        $script:OwnedProcessFixture[$fixture.Id] = [pscustomobject]@{
            ProcessId = $fixture.Id; Path = $pwshFixture; CreationDate = $started
            CommandLine = '"' + $pwshFixture + '" -NoProfile -File "' + $scriptPath + '"'
        }
        @{ pid = $fixture.Id; installationId = $fixture.Context.Id; executable = $pwshFixture; startedUtcTicks = $started.ToUniversalTime().Ticks } |
            ConvertTo-Json | Set-Content -LiteralPath (Get-BridgeRuntimePath -Name "$($fixture.Role).process.json" -Context $fixture.Context) -Encoding utf8
    }
    $script:OwnedProcessFixture[910004] = [pscustomobject]@{
        ProcessId = 910004; Path = $pwshFixture; CreationDate = $started
        CommandLine = '"' + $pwshFixture + '" -NoProfile -Command Start-Sleep'
    }
    $env:BRIDGE_UNINSTALL_NORUN = '1'
    . (Join-Path $PSScriptRoot '..\uninstall.ps1') -TargetHome $homes[0]
    $savedProcessInfo = (Get-Command Get-BridgeProcessInfo).ScriptBlock
    $savedProcessList = (Get-Command Get-BridgeProcessesNamed).ScriptBlock
    $script:ShutdownOrder = @()
    function Get-BridgeProcessInfo { param($ProcessId, [switch]$WithCommandLine) $script:OwnedProcessFixture[[int]$ProcessId] }
    function Get-BridgeProcessesNamed { param($Name, [switch]$WithCommandLine) @($script:OwnedProcessFixture.Values) }
    function Stop-Process {
        param($Id, [switch]$Force, $ErrorAction)
        $script:ShutdownOrder += [int]$Id
        [void]$script:OwnedProcessFixture.Remove([int]$Id)
    }
    try {
        Test-That 'a heartbeat PID alone cannot claim an unrelated PowerShell process' {
            $null -eq (Get-BridgeRuntimeProcess -ProcessId 910004 -Context $contextA -Role daemon)
        }
        $script:OwnedProcessFixture[910004].CommandLine = '"' + $pwshFixture + '" -Command ''Write-Output -File "' +
            (Join-Path $contextA.HooksDir 'agent-bridge-daemon.ps1') + '" ignored'''
        Test-That 'a quoted command mentioning an owned script is not that runtime' {
            $null -eq (Get-BridgeRuntimeProcess -ProcessId 910004 -Context $contextA -Role daemon)
        }
        $script:OwnedProcessFixture[910002].CreationDate = $started.AddSeconds(1)
        Test-That 'a reused PID is rejected even when its script and executable match' {
            $null -eq (Get-BridgeRuntimeProcess -ProcessId 910002 -Context $contextA -Role daemon)
        }
        $script:OwnedProcessFixture[910002].CreationDate = $started
        $savedDaemonCommand = $script:OwnedProcessFixture[910002].CommandLine
        $script:OwnedProcessFixture[910002].CommandLine = ''
        try {
            Test-That 'an unreadable recorded runtime is not assumed stopped during cleanup' {
                try { Stop-BridgeOwnedRuntime -Context $contextA -Roles daemon; $false }
                catch { $_.Exception.Message -match 'read|ownership' }
            }
        }
        finally { $script:OwnedProcessFixture[910002].CommandLine = $savedDaemonCommand }
        $cliAst = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot '..\bin\agent-ha-bridge.ps1'), [ref]$null, [ref]$null)
        $restart = $cliAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Restart'
        }, $true)
        . ([scriptblock]::Create($restart.Extent.Text))
        $commandContext = $contextA
        $taskName = $commandContext.TaskName
        $savedWindows = $script:BridgeIsWindows
        $script:BridgeIsWindows = $true
        $script:TaskActions = @()
        function Get-ScheduledTask { param($TaskName, $ErrorAction) $taskA }
        function Stop-ScheduledTask { param($TaskName, $ErrorAction) $script:TaskActions += "stop:$TaskName" }
        function Start-ScheduledTask { param($TaskName) $script:TaskActions += "start:$TaskName" }
        $savedSupervisor = $script:OwnedProcessFixture[910001]
        $savedDaemon = $script:OwnedProcessFixture[910002]
        $savedKeepAwake = $script:OwnedProcessFixture[910005]
        try {
            Invoke-Restart
            Test-That 'the actual CLI restart stops and starts only its owned task and runtime' {
                $script:TaskActions -join ',' -eq "stop:$($contextA.TaskName),start:$($contextA.TaskName)" -and
                    $script:ShutdownOrder -join ',' -eq '910001,910002,910005' -and
                    $script:OwnedProcessFixture.ContainsKey(910003) -and $script:OwnedProcessFixture.ContainsKey(910004) -and
                    $script:OwnedProcessFixture.ContainsKey(910006)
            }
        }
        finally {
            $script:BridgeIsWindows = $savedWindows
            Remove-Item Function:\Get-ScheduledTask, Function:\Stop-ScheduledTask, Function:\Start-ScheduledTask
            $script:OwnedProcessFixture[910001] = $savedSupervisor
            $script:OwnedProcessFixture[910002] = $savedDaemon
            $script:OwnedProcessFixture[910005] = $savedKeepAwake
            $script:ShutdownOrder = @()
        }
        $script:BridgeInstallContext = $contextA
        $ownedAttachments = Get-BridgeAttachmentRoot
        [IO.File]::WriteAllText((Join-Path $ownedAttachments 'owned.txt'), 'synthetic-A')
        $legacyAttachment = Join-Path (Split-Path $ownedAttachments -Parent) 'legacy-sentinel.txt'
        [IO.File]::WriteAllText($legacyAttachment, 'unattributed legacy data')
        $sentinelB = Join-Path $contextB.BridgeHome 'other-install.txt'
        [IO.File]::WriteAllText($sentinelB, 'B must survive')
        $unrelatedA = Join-Path $contextA.BridgeHome 'unrelated.txt'
        [IO.File]::WriteAllText($unrelatedA, 'not an installer payload')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\hooks\daemon-replies.ps1') -Destination $contextA.HooksDir
        $payload = Join-Path $contextA.BridgeHome 'installer'
        foreach ($client in @('claude', 'codex', 'mcp')) {
            $directory = if ($client -eq 'claude') { Join-Path $contextA.ClaudeHome 'ha-bridge' }
                elseif ($client -eq 'codex') { Join-Path $contextA.BridgeHome 'codex-bridge' }
                else { Join-Path $contextA.BridgeHome 'mcp' }
            [void][IO.Directory]::CreateDirectory($directory)
            $stub = @'
param([string]$TargetHome, [string]$InstallRoot, [switch]$Uninstall, [switch]$KeepSelection)
if (-not $Uninstall -or -not (Test-Path -LiteralPath (Join-Path $InstallRoot 'hooks\bridge-platform.ps1'))) { throw 'Adapter cleanup ran after its payload disappeared.' }
if ($OwnedProcessFixture.ContainsKey(910001) -or $OwnedProcessFixture.ContainsKey(910002) -or $OwnedProcessFixture.ContainsKey(910005)) { throw 'Adapter cleanup ran before owned shutdown.' }
Add-Content -LiteralPath (Join-Path $InstallRoot 'cleanup-order.txt') -Value '__CLIENT__'
if (Test-Path -LiteralPath '__DIRECTORY__') { Remove-Item -LiteralPath '__DIRECTORY__' -Recurse -Force }
'@
            [void][IO.Directory]::CreateDirectory((Join-Path $payload $client))
            $stub.Replace('__CLIENT__', $client).Replace('__DIRECTORY__', $directory.Replace("'", "''")) |
                Set-Content -LiteralPath (Join-Path $payload "$client\install-$client.ps1") -Encoding utf8
        }
        Remove-Item -LiteralPath (Join-Path $contextA.BridgeHome 'mcp') -Recurse -Force
        $hookFile = Join-Path $contextA.CopilotHome 'hooks\decision-notifier.json'
        [void][IO.Directory]::CreateDirectory((Split-Path $hookFile -Parent))
        @{ version = 1; hooks = @{ agentStop = @(
            @{ powershell = "& '$(Join-Path $contextA.HooksDir 'notify-agent-response.ps1')'" },
            @{ powershell = 'Write-Output unrelated-hook' }
        ) } } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $hookFile -Encoding utf8
        $unattributedLegacy = @(
            (Join-Path $contextA.CopilotHome 'hooks\VERSION'),
            (Join-Path $contextA.CopilotHome 'copilot-ha-bridge.config.json'),
            (Join-Path $contextA.CopilotHome 'copilot-ha-bridge\unrelated.txt'),
            (Join-Path $contextA.CopilotHome 'skills\decision-notifier\SKILL.md')
        )
        foreach ($path in $unattributedLegacy) {
            [void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
            [IO.File]::WriteAllText($path, '{"owner":"unattributed legacy installation"}')
        }
        Invoke-BridgeUninstall -AdapterPayloadRoot $payload
        Test-That 'real uninstall stops A before every adapter, including an MCP payload already missing' {
            $script:ShutdownOrder -join ',' -eq '910001,910002,910005' -and
                ([IO.File]::ReadAllText((Join-Path $contextA.BridgeHome 'cleanup-order.txt')) -split '\s+' | Where-Object { $_ }) -join ',' -eq 'claude,codex,mcp'
        }
        Test-That 'uninstall preserves B and unrelated processes, hooks and files' {
            $script:OwnedProcessFixture.ContainsKey(910003) -and $script:OwnedProcessFixture.ContainsKey(910004) -and
                $script:OwnedProcessFixture.ContainsKey(910006) -and
                [IO.File]::ReadAllText($sentinelB) -eq 'B must survive' -and
                [IO.File]::ReadAllText($unrelatedA) -eq 'not an installer payload' -and
                (Get-Content -LiteralPath $hookFile -Raw | ConvertFrom-Json).hooks.agentStop[0].powershell -eq 'Write-Output unrelated-hook'
        }
        Test-That 'uninstall removes A credentials and owned storage, preserving unknown legacy attachments' {
            -not (Test-Path -LiteralPath $contextA.ConfigPath) -and
                -not (Test-Path -LiteralPath $contextA.MetadataPath) -and
                -not (Test-Path -LiteralPath $ownedAttachments) -and
                [IO.File]::ReadAllText($legacyAttachment) -eq 'unattributed legacy data'
        }
        Test-That 'new-layout removal does not claim unknown legacy files or skills by their names' {
            @($unattributedLegacy | Where-Object {
                [IO.File]::Exists($_) -and [IO.File]::ReadAllText($_) -eq '{"owner":"unattributed legacy installation"}'
            }).Count -eq $unattributedLegacy.Count
        }
    }
    finally {
        Set-Item Function:\Get-BridgeProcessInfo -Value $savedProcessInfo
        Set-Item Function:\Get-BridgeProcessesNamed -Value $savedProcessList
        Remove-Item Function:\Stop-Process
        Remove-Item Env:\BRIDGE_UNINSTALL_NORUN -ErrorAction SilentlyContinue
    }
}
finally {
    $env:AGENT_HA_BRIDGE_CONFIG = $savedIsolationConfig
    $env:CODEX_HOME = $savedIsolationCodex
    foreach ($path in @($registrationFiles | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    if (Test-Path -LiteralPath $isolationRoot) { Remove-Item -LiteralPath $isolationRoot -Recurse -Force }
}

Write-Host '--- linked payloads are refused before foreign imports or mutation ---'
function Invoke-LinkedPayloadRemovalFixture {
    param([string]$Repository, $Owner, [string]$Mode)
    if ($Mode -eq 'invoke') {
        . (Join-Path $Repository 'uninstall.ps1') -TargetHome $Owner.Home
        function Get-BridgeProcessesNamed { param($Name, [switch]$WithCommandLine) @() }
        Invoke-BridgeUninstall -AdapterPayloadRoot (Join-Path $Owner.BridgeHome 'installer')
    }
    else {
        $entry = if ($Mode -eq 'uninstaller-bootstrap') { 'uninstall.ps1' } else { 'install.ps1' }
        & (Join-Path $Owner.BridgeHome $entry) -TargetHome $Owner.Home
    }
}
$linkedRoot = Join-Path $env:TEMP ('linked-payload-' + [guid]::NewGuid().ToString('N'))
$savedInstallNoRun = $env:BRIDGE_INSTALL_NORUN
$savedUninstallNoRun = $env:BRIDGE_UNINSTALL_NORUN
$env:BRIDGE_INSTALL_NORUN = '1'
$env:BRIDGE_UNINSTALL_NORUN = '1'
try {
    foreach ($mode in @('invoke', 'uninstaller-bootstrap', 'installer-bootstrap')) {
        $caseRoot = Join-Path $linkedRoot $mode
        $owner = Initialize-BridgeInstallIdentity -Context (Resolve-BridgeInstallContext -TargetHome (Join-Path $caseRoot 'A'))
        $foreign = Initialize-BridgeInstallIdentity -Context (Resolve-BridgeInstallContext -TargetHome (Join-Path $caseRoot 'B'))
        Write-BridgeSecretFile -Path $owner.ConfigPath -Content '{"clients":[]}'
        Write-BridgeSecretFile -Path $foreign.ConfigPath -Content '{"clients":[]}'
        [void][IO.Directory]::CreateDirectory($foreign.HooksDir)
        Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\hooks') -File |
            Copy-Item -Destination $foreign.HooksDir
        $executed = Join-Path $foreign.BridgeHome 'foreign-helper-executed.txt'
        $instrumented = Join-Path $foreign.HooksDir $(if ($mode -eq 'invoke') { 'daemon-replies.ps1' } else { 'bridge-platform.ps1' })
        $prefix = "[IO.File]::WriteAllText('$($executed.Replace("'", "''"))', 'executed')`n"
        [IO.File]::WriteAllText($instrumented, $prefix + [IO.File]::ReadAllText($instrumented))
        $version = Join-Path $foreign.HooksDir 'VERSION'
        $sentinel = Join-Path $foreign.HooksDir 'unrelated.txt'
        [IO.File]::WriteAllText($version, 'foreign version')
        [IO.File]::WriteAllText($sentinel, 'foreign sentinel')
        $beforeHelper = [IO.File]::ReadAllText($instrumented)
        foreach ($entry in @('install.ps1', 'uninstall.ps1')) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot "..\$entry") -Destination $owner.BridgeHome
        }
        $link = $owner.HooksDir
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $linkType -Path $link -Target $foreign.HooksDir | Out-Null
        if (-not ((Get-Item -LiteralPath $link -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'The fixture did not create a real directory link.'
        }
        try {
            $refusal = ''
            try { Invoke-LinkedPayloadRemovalFixture -Repository (Split-Path $PSScriptRoot -Parent) -Owner $owner -Mode $mode }
            catch { $refusal = $_.Exception.Message }
            Test-That "$mode refuses the real linked payload" { $refusal -match 'link|reparse' } $refusal
            Test-That "$mode refuses before executing a foreign helper" { -not [IO.File]::Exists($executed) }
            Test-That "$mode preserves foreign helper and version bytes, not only unrelated files" {
                [IO.File]::Exists($instrumented) -and [IO.File]::ReadAllText($instrumented) -ceq $beforeHelper -and
                    [IO.File]::Exists($version) -and [IO.File]::ReadAllText($version) -ceq 'foreign version' -and
                    [IO.File]::ReadAllText($sentinel) -ceq 'foreign sentinel'
            }
            Test-That "$mode preserves the rejected owners metadata and credentials" {
                [IO.File]::Exists($owner.MetadataPath) -and [IO.File]::Exists($owner.ConfigPath)
            }
        }
        finally {
            if (-not ((Get-Item -LiteralPath $link -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'The fixture link changed unexpectedly; recursive cleanup was not authorized.'
            }
            [IO.Directory]::Delete($link)
        }
    }
}
finally {
    $env:BRIDGE_INSTALL_NORUN = $savedInstallNoRun
    $env:BRIDGE_UNINSTALL_NORUN = $savedUninstallNoRun
    if (Test-Path -LiteralPath $linkedRoot) { Remove-Item -LiteralPath $linkedRoot -Recurse -Force }
}

Write-Host '--- adapter entity cleanup does not require Copilot storage ---'
function Invoke-AdapterEntityCleanupFixture {
    $repository = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repository 'uninstall.ps1')
    $fixtureContext = Initialize-BridgeInstallIdentity -Context $installContext
    if ($fixtureContext.Isolated -or -not (Test-BridgeInstallDescendant $fixtureContext.Home $env:AGENT_HA_BRIDGE_TEST_ROOT)) {
        throw 'Entity cleanup requires the ordinary installation inside canonical synthetic HOME.'
    }
    $installContext = $fixtureContext
    $script:BridgeInstallContext = $fixtureContext
    $hooksDir = $fixtureContext.HooksDir
    [void][IO.Directory]::CreateDirectory($hooksDir)
    Get-ChildItem -LiteralPath (Join-Path $repository 'hooks') -File | Copy-Item -Destination $hooksDir -Force
    $unusedState = Join-Path $fixtureContext.CopilotHome ('unused-' + [guid]::NewGuid().ToString('N'))
    $script:CleanupPublications = [Collections.Generic.List[object]]::new()
    function Invoke-RestMethod {
        param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec, $MaximumRedirection)
        if ($Uri -like '*/api/services/mqtt/publish') {
            if ($Body -isnot [byte[]]) { throw 'The real service helper must send UTF-8 bytes.' }
            $publication = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
            if (-not $publication.PSObject.Properties['topic']) { throw 'The MQTT fixture did not decode a real publication.' }
            $script:CleanupPublications.Add($publication)
            return @()
        }
        if ($Uri -like '*/api/states') { return @() }
        throw "Unexpected synthetic REST operation: $Method $Uri"
    }
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'uninstall.ps1'), [ref]$null, [ref]$null)
    $uninstall = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-BridgeUninstall'
    }, $true)
    $cleanup = $uninstall.Body.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.IfStatementAst] -and
            $_.Clauses[0].Item1.Extent.Text -eq '$ClearEntities -and $installContext.Isolated'
    } | Select-Object -First 1
    if (-not $cleanup) { throw 'The actual entity-cleanup branch was not found.' }
    Set-Variable -Name ClearEntities -Value $true
    Set-Variable -Name KeepShared -Value $true
    Set-Variable -Name ClearShared -Value $false
    foreach ($fixtureClient in @('claude', 'codex')) {
        $config = @{
            clients = @($fixtureClient)
            homeAssistant = @{ baseUrl = 'http://127.0.0.1:1'; token = 'synthetic-cleanup-token' }
            copilot = @{ sessionStateRoot = $unusedState }
        }
        Write-BridgeSecretFile -Path $fixtureContext.ConfigPath -Content ($config | ConvertTo-Json -Depth 6)
        $session = [guid]::NewGuid().ToString()
        $registry = Get-BridgeRuntimePath -Name "agent-bridge-$fixtureClient" -Context $fixtureContext
        [void][IO.Directory]::CreateDirectory($registry)
        $registration = Join-Path $registry "$session.json"
        @{ SessionId = $session; TranscriptPath = (Join-Path $fixtureContext.Home 'synthetic.jsonl') } |
            ConvertTo-Json | Set-Content -LiteralPath $registration -Encoding utf8
        try {
            if (Test-Path -LiteralPath $unusedState) { throw 'The missing-Copilot fixture was not empty.' }
            $script:CleanupPublications.Clear()
            . ([scriptblock]::Create($cleanup.Extent.Text))
            $node = Get-CopilotMqttNodeId -SessionId $session
            $without = @($script:CleanupPublications | Where-Object { $_.topic -like "*/$node/*" })
            Test-That "$fixtureClient-only uninstall publishes the complete 21-message cleanup with no Copilot directory" {
                $without.Count -eq 21 -and
                    $without[0].topic -eq (Get-CopilotMqttTopics -SessionId $session).Availability -and
                    $without[0].payload -ceq 'offline' -and
                    @($without | Where-Object { -not $_.retain }).Count -eq 0 -and
                    @($without | Select-Object -Skip 1 | Where-Object { $_.payload -cne '' }).Count -eq 0
            }
            # 24 rather than 22 since the session transfer sensor and its request topic
            # joined the machine list. The number is deliberately spelled out: it is the
            # tripwire that caught the permissions selector being added to the dashboard
            # and not to the cleanup, which left a dead entity behind in Home Assistant.
            Test-That "$fixtureClient-only machine cleanup remains a separate 24-topic control" {
                $script:CleanupPublications.Count - $without.Count -eq 24
            }
            [void][IO.Directory]::CreateDirectory($unusedState)
            $script:CleanupPublications.Clear()
            . ([scriptblock]::Create($cleanup.Extent.Text))
            $with = @($script:CleanupPublications | Where-Object { $_.topic -like "*/$node/*" }).Count
            Test-That "adding an empty Copilot directory does not change $fixtureClient cleanup" {
                $with -eq 21 -and $without.Count -eq $with -and $script:CleanupPublications.Count - $with -eq 24
            }
        }
        finally {
            Remove-Item -LiteralPath $registration -Force
            if (Test-Path -LiteralPath $unusedState) { [IO.Directory]::Delete($unusedState) }
        }
    }
}
$savedEntityConfig = $env:AGENT_HA_BRIDGE_CONFIG
$savedEntityNoRun = $env:BRIDGE_UNINSTALL_NORUN
$savedEntityContext = $script:BridgeInstallContext
$env:AGENT_HA_BRIDGE_CONFIG = Join-Path (Get-BridgeTestSandbox -Root $env:AGENT_HA_BRIDGE_TEST_ROOT)['home'] '.agent-ha-bridge\config.json'
$env:BRIDGE_UNINSTALL_NORUN = '1'
try { Invoke-AdapterEntityCleanupFixture }
finally {
    $env:AGENT_HA_BRIDGE_CONFIG = $savedEntityConfig
    $env:BRIDGE_UNINSTALL_NORUN = $savedEntityNoRun
    $script:BridgeInstallContext = $savedEntityContext
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
