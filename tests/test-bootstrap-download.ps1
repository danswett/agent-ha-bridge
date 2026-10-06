#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for which archive bootstrap.ps1 installs.

.DESCRIPTION
    The one-liner in the README used to install main, so a machine set up from it ran
    whatever had merged that minute - including work deliberately held out of every
    release - and then reported main's VERSION as though it were a release. It now
    installs the latest published release unless a version or a branch is named.

    bootstrap.ps1 runs the install when it is loaded, so it cannot be dot-sourced:
    Resolve-BridgeDownload is lifted out of it by the parser, and the release lookup
    is always a stub, so nothing here reaches the network.
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

$source = Join-Path $PSScriptRoot '..\bootstrap.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$null)
$definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Resolve-BridgeDownload'
    }, $true)
if (-not $definition) { throw 'Resolve-BridgeDownload is not defined in bootstrap.ps1.' }
. ([scriptblock]::Create($definition.Extent.Text))

$repo = 'danswett/agent-ha-bridge'
$latest = { param($r) 'v1.32.3' }

Write-Host '--- which archive is installed ---'

Test-That 'by default the latest release, not main' {
    (Resolve-BridgeDownload -Repo $repo -GetLatestTag $latest).Url -ceq
        'https://github.com/danswett/agent-ha-bridge/archive/refs/tags/v1.32.3.zip'
}
Test-That 'and it says which release it is' {
    (Resolve-BridgeDownload -Repo $repo -GetLatestTag $latest).Label -ceq 'release v1.32.3'
}
Test-That 'the lookup is asked about this repository' {
    $script:askedRepo = $null
    [void](Resolve-BridgeDownload -Repo $repo -GetLatestTag { param($r) $script:askedRepo = $r; 'v1.0.0' })
    $script:askedRepo -ceq $repo
}
Test-That '-Version pins a release without asking for the latest' {
    $d = Resolve-BridgeDownload -Repo $repo -Version '1.31.0' -GetLatestTag { throw 'must not be called' }
    $d.Url -ceq 'https://github.com/danswett/agent-ha-bridge/archive/refs/tags/v1.31.0.zip'
}
Test-That 'with or without its v' {
    (Resolve-BridgeDownload -Repo $repo -Version 'v1.31.0').Url -ceq
        'https://github.com/danswett/agent-ha-bridge/archive/refs/tags/v1.31.0.zip'
}
Test-That '-Branch still installs a branch when asked for by name, and says it is unreleased' {
    $d = Resolve-BridgeDownload -Repo $repo -Branch 'main' -GetLatestTag { throw 'must not be called' }
    $d.Url -ceq 'https://github.com/danswett/agent-ha-bridge/archive/refs/heads/main.zip' -and
        $d.Label -like '*unreleased*'
}
Test-That 'naming both is refused' {
    try { [void](Resolve-BridgeDownload -Repo $repo -Version '1.31.0' -Branch 'main'); $false }
    catch { $_.Exception.Message -like '*-Version or -Branch*' }
}
Test-That 'a failed lookup stops instead of falling back to main' {
    try { [void](Resolve-BridgeDownload -Repo $repo -GetLatestTag { throw 'offline' }); $false }
    catch { $_.Exception.Message -like 'Could not look up the latest*' }
}
Test-That 'and so does a lookup that finds no release' {
    try { [void](Resolve-BridgeDownload -Repo $repo -GetLatestTag { param($r) $null }); $false }
    catch { $_.Exception.Message -like 'Could not look up the latest*' }
}

Write-Host ''
if ($script:Failures -eq 0) { Write-Host 'All bootstrap download checks passed'; exit 0 }
Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
exit 1
