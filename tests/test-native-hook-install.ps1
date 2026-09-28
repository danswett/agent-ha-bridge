#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for installing the native hook (hooks/bridge-native-hook.ps1).

.DESCRIPTION
    Downloads are replaced by a stand-in that serves files from a folder, so these
    check the choices: a local build first, otherwise the release build for this
    machine, only with a matching checksum and only if it runs; and a program already
    installed is kept when a new one cannot be.

    A runnable program is needed for most checks: AGENT_BRIDGE_HOOK_BIN, or
    hook/agent-bridge-hook(.exe) after `go build`. Without one they are skipped.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\bridge-platform.ps1')
. (Join-Path $PSScriptRoot '..\hooks\bridge-native-hook.ps1')

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

$programName = Get-BridgeNativeHookName
$built = if ($env:AGENT_BRIDGE_HOOK_BIN) { $env:AGENT_BRIDGE_HOOK_BIN } else { Join-Path $PSScriptRoot "..\hook\$programName" }
$root = Join-Path ([IO.Path]::GetTempPath()) "native-install-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $root | Out-Null

try {
    Write-Host '--- this machine ---'
    $asset = Get-BridgeNativeHookAsset
    Test-That 'there is a release build for this machine' { $asset -match '^agent-bridge-hook-(windows|darwin)-(amd64|arm64)(\.exe)?$' }
    Test-That 'a missing program does not count as installed' { -not (Test-BridgeNativeHook -Path (Join-Path $root 'nothing')) }
    $notAProgram = Join-Path $root "fake-$programName"
    Set-Content -LiteralPath $notAProgram -Value 'not a program'
    Test-That 'nor one that does not run' { -not (Test-BridgeNativeHook -Path $notAProgram) }

    if (-not (Test-Path -LiteralPath $built)) {
        Write-Host "SKIP  the rest: no native hook build at $built (go build in hook/ first)" -ForegroundColor Yellow
    }
    else {
        Test-That 'the built program runs' { Test-BridgeNativeHook -Path $built }

        # A checkout with no local build, and a release folder the stand-in serves.
        $repo = Join-Path $root 'repo'; New-Item -ItemType Directory -Path (Join-Path $repo 'hook') -Force | Out-Null
        $release = Join-Path $root 'release'; New-Item -ItemType Directory -Path $release | Out-Null
        Copy-Item -LiteralPath $built -Destination (Join-Path $release $asset)
        $hash = (Get-FileHash -LiteralPath $built -Algorithm SHA256).Hash.ToLowerInvariant()
        Set-Content -LiteralPath (Join-Path $release 'SHA256SUMS') -Value @("0000  agent-bridge-hook-other-arch", "$hash  $asset")
        $script:Fetched = @()
        $serve = { param([string]$Url, [string]$OutFile)
            $script:Fetched += $Url
            $file = Join-Path $release ($Url -split '/')[-1]
            if (-not (Test-Path -LiteralPath $file)) { throw '404 Not Found' }
            Copy-Item -LiteralPath $file -Destination $OutFile -Force
        }
        $bin = Join-Path $root 'bin'

        Write-Host '--- from the release ---'
        $result = Install-BridgeNativeHook -RepoRoot $repo -BinDir $bin -Version '1.2.3' -Repository 'me/bridge' -Download $serve
        Test-That 'this release''s build is installed' { $result.Path -eq (Join-Path $bin $programName) -and $result.Source -eq 'release v1.2.3' } "$($result.Detail) [$($result.Path)]"
        Test-That 'from this repository''s release' { $script:Fetched -contains "https://github.com/me/bridge/releases/download/v1.2.3/$asset" }
        Test-That 'and it runs' { Test-BridgeNativeHook -Path $result.Path }
        Test-That 'nothing is left beside it' { @(Get-ChildItem $bin).Count -eq 1 }
        Test-That 'the adapters then find it' { (Get-BridgeNativeHookPath -BridgeHome $root) -eq $result.Path }

        Write-Host '--- refusing a bad one ---'
        Set-Content -LiteralPath (Join-Path $release 'SHA256SUMS') -Value "ffff  $asset"
        $result = Install-BridgeNativeHook -RepoRoot $repo -BinDir $bin -Version '1.2.4' -Download $serve
        Test-That 'a checksum mismatch is not installed' { $null -eq $result.Path -and $result.Detail -match 'checksum mismatch' }
        Test-That 'and the program already installed is kept' { Test-BridgeNativeHook -Path (Join-Path $bin $programName) }
        Set-Content -LiteralPath (Join-Path $release 'SHA256SUMS') -Value "$hash  something-else"
        Test-That 'nor a build the checksums do not list' { $null -eq (Install-BridgeNativeHook -RepoRoot $repo -BinDir $bin -Version '1.2.4' -Download $serve).Path }
        $result = Install-BridgeNativeHook -RepoRoot $repo -BinDir $bin -Version '9.9.9' -Download { param($Url, $OutFile) throw '404 Not Found' }
        Test-That 'a release without the program leaves the hooks as they were' { $null -eq $result.Path -and $result.Detail -match 'v9\.9\.9' }

        Copy-Item -LiteralPath $notAProgram -Destination (Join-Path $release $asset) -Force
        $fakeHash = (Get-FileHash -LiteralPath $notAProgram -Algorithm SHA256).Hash.ToLowerInvariant()
        Set-Content -LiteralPath (Join-Path $release 'SHA256SUMS') -Value "$fakeHash  $asset"
        $result = Install-BridgeNativeHook -RepoRoot $repo -BinDir $bin -Version '1.2.5' -Download $serve
        Test-That 'a download that will not run (antivirus, wrong machine) is not installed' { $null -eq $result.Path -and $result.Detail -match 'does not run' }

        Write-Host '--- a local build ---'
        Copy-Item -LiteralPath $built -Destination (Join-Path (Join-Path $repo 'hook') $programName)
        $script:Fetched = @()
        $result = Install-BridgeNativeHook -RepoRoot $repo -BinDir $bin -Version '1.2.3' -Download $serve
        Test-That 'a checkout''s own build is used, with no download' { $result.Source -eq 'local build' -and $script:Fetched.Count -eq 0 }
        Test-That 'without a version it still installs the local build' { (Install-BridgeNativeHook -RepoRoot $repo -BinDir $bin -Version '' -Download $serve).Path }
    }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All native hook install checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
