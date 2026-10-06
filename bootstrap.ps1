<#
.SYNOPSIS
    One-line installer for the AI coding agent <-> Home Assistant bridge.

.DESCRIPTION
    Downloads the latest release and runs its install.ps1:

        irm https://raw.githubusercontent.com/danswett/agent-ha-bridge/main/bootstrap.ps1 | iex

    This file is deliberately Windows PowerShell 5.1 compatible, because that is what
    `powershell.exe` gives you and it is where most people paste the one-liner. It used
    to stop dead there with "PowerShell 7+ is required"; now it offers to install
    PowerShell 7 and hands the install over to it.

    Nothing else needs arguments: install.ps1 is interactive, and once it has run the
    `agent-ha-bridge` command reconfigures the install from anywhere.

.PARAMETER Version
    A release to install, such as 1.32.3. Defaults to the latest published release.

.PARAMETER Branch
    Install a branch's unreleased code instead of a release, to try a change before
    it ships. Never the default: see Resolve-BridgeDownload.

.PARAMETER Yes
    Install PowerShell 7 without asking, for an unattended run.
#>

[CmdletBinding()]
param(
    [string]$Version,
    [string]$Branch,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

$repo = 'danswett/agent-ha-bridge'
$wingetCommand = 'winget install --id Microsoft.PowerShell --source winget --exact ' +
                 '--accept-package-agreements --accept-source-agreements'

# Windows PowerShell 5.1 negotiates TLS 1.0 by default, which GitHub refuses.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }

function Resolve-BridgeDownload {
    <#
        Which archive to install: the latest published release, unless a version or a
        branch is named.

        It used to default to main, so the one-liner in the README installed whatever
        had merged that minute - including work deliberately held out of every release -
        and the machine then reported main's VERSION as though it were a release. A
        failed lookup stops rather than falling back to main for the same reason.
    #>
    param(
        [Parameter(Mandatory)][string]$Repo,
        [string]$Version,
        [string]$Branch,
        [scriptblock]$GetLatestTag = {
            param($r)
            # releases/latest never returns a draft or a prerelease.
            (Invoke-RestMethod -Uri "https://api.github.com/repos/$r/releases/latest").tag_name
        }
    )
    if ($Version -and $Branch) { throw 'Pass -Version or -Branch, not both.' }
    if ($Branch) {
        return [pscustomobject]@{
            Label = "branch $Branch, unreleased"
            Url   = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"
        }
    }
    if ($Version) { $tag = 'v' + $Version.Trim().TrimStart('v', 'V') }
    else {
        $tag = try { [string](& $GetLatestTag $Repo) } catch { '' }
        if ([string]::IsNullOrWhiteSpace($tag)) {
            throw ("Could not look up the latest $Repo release. Check the connection and run " +
                   'this again, or name one with -Version.')
        }
        $tag = $tag.Trim()
    }
    [pscustomobject]@{ Label = "release $tag"; Url = "https://github.com/$Repo/archive/refs/tags/$tag.zip" }
}

function Get-PwshPath {
    # Get-Command alone is not enough straight after an install: this process's PATH
    # predates it, so the well-known locations are checked too.
    $command = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
    foreach ($root in $roots) {
        $candidate = Join-Path $root 'PowerShell\7\pwsh.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    $null
}

function Install-Pwsh {
    <# Offers to install PowerShell 7 and returns its path, or throws explaining why not. #>
    Write-Host ''
    Write-Host 'PowerShell 7 is not installed.' -ForegroundColor Yellow
    Write-Host '    every bridge script and hook runs under pwsh' -ForegroundColor DarkGray
    Write-Host "    $wingetCommand" -ForegroundColor DarkGray

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw ('PowerShell 7 is required and winget is not available to install it. ' +
               'Install it from https://aka.ms/powershell-release and run this again.')
    }
    if (-not $Yes) {
        $answer = Read-Host '    Install PowerShell 7 now? [Y/n]'
        if ($answer -and $answer.Trim() -notmatch '^(y|yes)$') {
            throw "PowerShell 7 is required. Install it with: $wingetCommand"
        }
    }

    Write-Step 'Installing PowerShell 7'
    & winget install --id Microsoft.PowerShell --source winget --exact `
        --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget exited $LASTEXITCODE. Install PowerShell 7 with: $wingetCommand"
    }

    # winget updated the stored PATH, not this process's copy of it.
    try {
        $parts = @(
            [Environment]::GetEnvironmentVariable('Path', 'Machine'),
            [Environment]::GetEnvironmentVariable('Path', 'User')
        ) | Where-Object { $_ }
        if ($parts) { $env:PATH = $parts -join ';' }
    }
    catch { }

    Get-PwshPath
}

# ---------------------------------------------------------------- PowerShell 7
$pwsh = Get-PwshPath
if (-not $pwsh) { $pwsh = Install-Pwsh }
if (-not $pwsh) {
    throw 'PowerShell 7 was installed but pwsh.exe could not be found. Open a new terminal and run this again.'
}
Write-Host "    using $pwsh" -ForegroundColor DarkGray

# --------------------------------------------------------------------- download
$staging = Join-Path ([IO.Path]::GetTempPath()) ('agent-ha-bridge-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$zipPath = "$staging.zip"

$download = Resolve-BridgeDownload -Repo $repo -Version $Version -Branch $Branch
Write-Step "Downloading $repo ($($download.Label))"
try {
    Invoke-WebRequest -Uri $download.Url -OutFile $zipPath -UseBasicParsing
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    Expand-Archive -LiteralPath $zipPath -DestinationPath $staging -Force

    # The archive contains a single <name>-<branch or version> directory.
    $root = Get-ChildItem -LiteralPath $staging -Directory | Select-Object -First 1
    if (-not $root) { throw 'The downloaded archive did not contain the expected folder.' }

    Write-Step 'Running the installer'
    # Always through pwsh, even when this is already running under PowerShell 7: one
    # code path, and install.ps1 is only ever tested there.
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root.FullName 'install.ps1')
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "The installer exited with code $code." }
}
finally {
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
