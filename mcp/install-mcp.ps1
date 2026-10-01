#Requires -Version 7.0
<#
.SYNOPSIS
    Sets up the bridge's MCP server and hands you a ready-to-paste client config.

.DESCRIPTION
    Copies the Node MCP server into ~/.agent-ha-bridge/mcp so it survives deleting the clone,
    installs its dependencies, and writes a paste-ready stdio reference to the Home
    Assistant URL and credential sources in the bridge config. If Claude Desktop is present,
    the server is written straight into its config; other MCP clients (Cursor, ChatGPT)
    use the generated snippet.

    Unlike the hook adapters, an MCP server is not a hook: MCP clients each point at it
    their own way, so for anything but Claude Desktop you paste the generated snippet.
    The base bridge must already be installed - the MCP setup reuses its Home Assistant
    URL and token.

.PARAMETER TargetHome
    Install into this directory's .agent-ha-bridge instead of $HOME's. For testing
    without touching a real setup.

.PARAMETER Uninstall
    Remove the MCP server and its Claude Desktop registration.
#>
[CmdletBinding()]
param(
    [string]$TargetHome,
    [string]$InstallRoot,
    [switch]$RepairOnly,
    [switch]$KeepSelection,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
# Windows/macOS differences; on macOS also makes Join-Path accept '\'.
. (Join-Path $PSScriptRoot '../hooks/bridge-platform.ps1')
. (Join-Path $PSScriptRoot '../hooks/bridge-secrets.ps1')

$installContext = Resolve-BridgeInstallContext -TargetHome $TargetHome -BridgeHome $InstallRoot
$bridgeHome  = $installContext.BridgeHome
$mcpDir      = Join-Path $bridgeHome 'mcp'
$configPath  = $installContext.ConfigPath
$snippetPath = Join-Path $mcpDir 'mcp-client-config.json'
$serverName  = 'home-assistant-bridge'
# Overridable so a sandbox test never touches the real Claude Desktop config.
$claudeDesktopConfig = $installContext.DesktopConfig
$legacyMcpDir = if ($installContext.LegacyLayout) { Join-Path $installContext.CopilotHome 'mcp' } else { '' }
$legacyServerPath = if ($legacyMcpDir) { Join-Path $legacyMcpDir 'src\server.js' } else { '' }

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ is required (found $($PSVersionTable.PSVersion))."
}

function Get-JsonFile {
    param([string]$Path, [switch]$Protect)
    if (-not (Test-Path -LiteralPath $Path)) { return @{} }
    if ($Protect -and -not (Protect-BridgeSecretFile -Path $Path)) { throw 'Could not protect the existing MCP configuration.' }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $parsed = $raw | ConvertFrom-Json -AsHashtable
        if ($parsed -isnot [System.Collections.IDictionary]) { throw 'Expected a JSON object.' }
        return $parsed
    }
    catch { throw 'The MCP configuration could not be read as a JSON object. Repair its syntax or permissions; it has not been replaced.' }
}

function Remove-BridgeMcpServer {
    <# Strips only this bridge's server, leaving any others the client has. #>
    param([hashtable]$Config, [Parameter(Mandatory)][string]$ServerPath, [string]$LegacyServerPath)
    if ($Config.ContainsKey('mcpServers') -and $Config['mcpServers'] -is [hashtable]) {
        if (-not $Config['mcpServers'].ContainsKey($serverName)) { return $Config }
        $entry = $Config['mcpServers'][$serverName]
        $serverArgs = @(if ($entry -is [Collections.IDictionary] -and $entry.Contains('args')) { $entry['args'] })
        $comparison = if ($script:BridgeIsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if ($serverArgs.Count -eq 0 -or $serverArgs[0] -isnot [string] -or
            -not [IO.Path]::IsPathFullyQualified($serverArgs[0]) -or
            (-not [string]::Equals([IO.Path]::GetFullPath($serverArgs[0]), [IO.Path]::GetFullPath($ServerPath), $comparison) -and
             (-not $LegacyServerPath -or -not (Test-BridgeInstallPath $serverArgs[0] $LegacyServerPath)))) {
            Write-Warning 'The named MCP registration points elsewhere; leaving it and its credentials unchanged.'
            return $Config
        }
        [void]$Config['mcpServers'].Remove($serverName)
        if ($Config['mcpServers'].Count -eq 0) { [void]$Config.Remove('mcpServers') }
    }
    $Config
}

function Get-BridgeMcpServerBlock {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$McpDir)

    [void](ConvertTo-BridgeHomeAssistantUrl -Value ([string]$Config.homeAssistant.baseUrl))
    # Keep the endpoint and both credential sources together. A generated client
    # config must not freeze an environment-only secret or override its authority.
    $serverEnv = [ordered]@{ HA_BRIDGE_CONFIG = [IO.Path]::GetFullPath($ConfigPath) }
    [ordered]@{ command = 'node'; args = @([IO.Path]::GetFullPath((Join-Path $McpDir 'src\server.js'))); env = $serverEnv }
}

function Write-BridgeMcpSnippet {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$ServerBlock)
    $content = [ordered]@{ mcpServers = [ordered]@{ $serverName = $ServerBlock } } | ConvertTo-Json -Depth 100
    Write-BridgeSecretFile -Path $Path -Content $content
}

function Set-BridgeMcpClientConfig {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$ServerBlock, [string]$LegacyServerPath)
    $cd = Get-JsonFile -Path $Path
    if ($cd.ContainsKey('mcpServers') -and $cd['mcpServers'] -isnot [hashtable]) {
        throw 'The client mcpServers setting must be a JSON object; it has not been replaced.'
    }
    if (-not $cd.ContainsKey('mcpServers')) { $cd['mcpServers'] = @{} }
    if ($cd['mcpServers'].ContainsKey($serverName)) {
        $existing = $cd['mcpServers'][$serverName]
        if ($existing -isnot [Collections.IDictionary] -or -not $existing.Contains('args') -or
            @($existing.args).Count -eq 0 -or $existing.args[0] -isnot [string] -or
            -not [IO.Path]::IsPathFullyQualified($existing.args[0]) -or
            (-not (Test-BridgeInstallPath $existing.args[0] $ServerBlock.args[0]) -and
             (-not $LegacyServerPath -or -not (Test-BridgeInstallPath $existing.args[0] $LegacyServerPath)))) {
            throw 'The named MCP registration belongs to another installation; it was not replaced.'
        }
    }
    $cd['mcpServers'][$serverName] = $ServerBlock
    if (Test-Path -LiteralPath $Path) { Copy-BridgeSecretFile -Source $Path -Destination "$Path.bak" }
    Write-BridgeSecretFile -Path $Path -Content ($cd | ConvertTo-Json -Depth 100)
}

function Remove-BridgeMcpClientConfig {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ServerPath, [string]$LegacyServerPath)
    foreach ($file in @($Path, "$Path.bak")) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $current = Get-JsonFile $file
        if (-not $current.ContainsKey('mcpServers') -or $current['mcpServers'] -isnot [hashtable] -or
            -not $current['mcpServers'].ContainsKey($serverName)) { continue }
        $updated = Remove-BridgeMcpServer -Config $current -ServerPath $ServerPath -LegacyServerPath $LegacyServerPath
        if ($updated.ContainsKey('mcpServers') -and $updated['mcpServers'].ContainsKey($serverName)) { continue }
        Write-BridgeSecretFile -Path $file -Content ($updated | ConvertTo-Json -Depth 100)
    }
}

# Credential helpers can be exercised without installing packages or clients.
if ($env:BRIDGE_INSTALL_NORUN) { return }
if ($RepairOnly -and -not $Uninstall) { Assert-BridgeAdapterSelection -Context $installContext -Client mcp }

# ------------------------------------------------------------------ uninstall
if ($Uninstall) {
    Write-Step 'Removing the MCP server'
    Stop-BridgeOwnedRuntime -Context $installContext
    Remove-BridgeMcpClientConfig -Path $claudeDesktopConfig -ServerPath (Join-Path $mcpDir 'src\server.js') `
        -LegacyServerPath $legacyServerPath
    if (Test-Path -LiteralPath $mcpDir) {
        Remove-Item -LiteralPath $mcpDir -Recurse -Force
        Write-Host "    removed $mcpDir"
    }
    if ($legacyMcpDir -and (Test-Path -LiteralPath $legacyMcpDir)) {
        Remove-Item -LiteralPath $legacyMcpDir -Recurse -Force
    }
    Set-BridgeAdapterEnrollment -Context $installContext -Client mcp -Installed $false -KeepSelection:$KeepSelection
    Write-Step 'Done'
    return
}

# -------------------------------------------------------------------- install
if (-not (Test-Path -LiteralPath $configPath)) {
    throw ("The bridge config was not found at $configPath. Run install.ps1 first - the " +
           'MCP setup reuses its Home Assistant URL and token.')
}
$config = Get-JsonFile -Path $configPath -Protect
# Two tokens, because this server does two different kinds of thing.
#
# HA_TOKEN is the bridge's own - the user's - because this server *provisions*:
# entities.js sends config/entity_registry/update to force deterministic entity ids,
# and dashboard.js sends lovelace/dashboards/create and lovelace/config/save. All
# three are admin-only - measured, not assumed: as a plain user every one comes back
# `unauthorized`, while reading states and calling services still work. Handing this
# server only the agent token would either break provisioning or force the agent
# account to be an administrator, and the whole point of a separate account is that it
# need not be one.
#
# HA_AGENT_TOKEN is the agent's, and the session tools use it for the writes whose
# account Home Assistant records - a reply, a launch. That used to be nothing: this
# server published a question and waited, pressing nothing. It now drives sessions
# too, and a press made with the user's token is indistinguishable from the user
# pressing it, so it is the one thing here that must not use HA_TOKEN.
#
# An unconfigured agent is optional. A configured identity whose environment-only
# credential is unavailable fails at startup instead of silently using the user.

Write-Step "Installing the MCP server into $mcpDir"
if (-not (Test-Path -LiteralPath $mcpDir)) {
    New-Item -ItemType Directory -Path $mcpDir -Force | Out-Null
    if (-not (Protect-BridgeSecretFile -Path $mcpDir)) { throw 'Could not protect the MCP credential directory.' }
}
# A clean copy of src each time, so a removed file cannot linger.
$destSrc = Join-Path $mcpDir 'src'
if (Test-Path -LiteralPath $destSrc) { Remove-Item -LiteralPath $destSrc -Recurse -Force }
Copy-Item (Join-Path $PSScriptRoot 'src') $mcpDir -Recurse -Force
Copy-Item (Join-Path $PSScriptRoot 'package.json') $mcpDir -Force
# Copy the release marker next to the server so it reports the bridge version it is
# actually running (server.js reads VERSION, falling back to package.json).
$mcpVersionFile = Join-Path $PSScriptRoot '..\VERSION'
if (Test-Path -LiteralPath $mcpVersionFile) { Copy-Item $mcpVersionFile $mcpDir -Force }
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'package-lock.json')) {
    Copy-Item (Join-Path $PSScriptRoot 'package-lock.json') $mcpDir -Force
}

if (Get-Command npm -ErrorAction SilentlyContinue) {
    Write-Step 'Installing dependencies (npm)'
    Push-Location $mcpDir
    try {
        & npm install --omit=dev --no-audit --no-fund 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "npm install exited $LASTEXITCODE; run 'npm install' in $mcpDir yourself."
        }
        else { Write-Host '    dependencies installed' }
    }
    finally { Pop-Location }
}
else {
    Write-Warning "Node/npm not found. Install Node.js, then run 'npm install' in $mcpDir."
}

# ------------------------------------------------------- paste-ready snippet
# Only the config path is serialized. Credentials are resolved by the MCP process.
$serverBlock = Get-BridgeMcpServerBlock -Config $config -ConfigPath $configPath -McpDir $mcpDir
Write-BridgeMcpSnippet -Path $snippetPath -ServerBlock $serverBlock
Write-Step "Wrote a paste-ready client config to $snippetPath"
Write-Host '    credentials are read at runtime; environment-only tokens must be available to the MCP client'

# ----------------------------------------------------------- Claude Desktop
$claudeDone = $false
if (Test-Path -LiteralPath (Split-Path -Parent $claudeDesktopConfig)) {
    Set-BridgeMcpClientConfig -Path $claudeDesktopConfig -ServerBlock $serverBlock `
        -LegacyServerPath $legacyServerPath
    Write-Step 'Registered with Claude Desktop'
    Write-Host "    added '$serverName' to $claudeDesktopConfig"
    $claudeDone = $true
}
Set-BridgeAdapterEnrollment -Context $installContext -Client mcp -Installed $true -RepairOnly:$RepairOnly

Write-Step 'Done'
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Yellow
if ($claudeDone) {
    Write-Host '  - Claude Desktop: restart it; the Home Assistant bridge tool is now available.'
}
Write-Host "  - Other MCP clients (Cursor, ...): paste $snippetPath into their MCP config."
Write-Host '  - ChatGPT / remote clients: use the HTTP transport - see mcp/README.md.'
