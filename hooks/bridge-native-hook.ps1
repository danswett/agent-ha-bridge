<#
    Installing the native hook, agent-bridge-hook (hook/, see docs/fast-hooks.md).

    The program is compiled, so it cannot come from the source archive an update
    downloads. CI builds it for each release and attaches it, with SHA256SUMS; the
    installer fetches the build for this machine into ~/.agent-ha-bridge/bin, checks
    its checksum, and checks that it runs. A checkout with a local build
    (hook/agent-bridge-hook[.exe], from `go build`) uses that instead, so the program
    can be tried before any release carries it.

    Everything here fails soft: without the program the agents keep their PowerShell
    hooks, exactly as before.

    Needs bridge-platform.ps1 loaded ($script:BridgeIsWindows).
#>

function Get-BridgeNativeHookName {
    <# The installed file's name: agent-bridge-hook.exe on Windows. #>
    if ($script:BridgeIsWindows) { 'agent-bridge-hook.exe' } else { 'agent-bridge-hook' }
}

function Get-BridgeNativeHookAsset {
    <#
        The release asset built for this machine, as CI names it:
        agent-bridge-hook-<os>-<arch>[.exe], or $null on a platform with no build.
    #>
    $arch = switch ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64' { 'amd64' }
        'Arm64' { 'arm64' }
        default { $null }
    }
    if (-not $arch) { return $null }
    if ($script:BridgeIsWindows) { return "agent-bridge-hook-windows-$arch.exe" }
    if ($IsMacOS) { return "agent-bridge-hook-darwin-$arch" }
    $null
}

function Test-BridgeNativeHook {
    <#
        Whether the program at $Path runs, by asking its version. This is what catches a
        build antivirus has blocked, or one for the wrong machine: an agent is only ever
        pointed at a program that has been seen to work.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.File]::Exists($Path)) { return $false }
    try {
        $output = & $Path --version 2>$null
        $ok = ($LASTEXITCODE -eq 0) -and -not [string]::IsNullOrWhiteSpace(($output | Out-String))
        $global:LASTEXITCODE = 0
        return $ok
    }
    catch { return $false }
}

function Get-BridgeNativeHookPath {
    <#
        The installed program, when it is there and runs; otherwise $null, and hooks stay
        PowerShell. Used by the adapter installers when they write hook commands.
    #>
    param([Parameter(Mandatory)][string]$BridgeHome)

    $path = Join-Path (Join-Path $BridgeHome 'bin') (Get-BridgeNativeHookName)
    if (Test-BridgeNativeHook -Path $path) { return $path }
    $null
}

function Install-BridgeNativeHook {
    <#
        Puts the native hook in $BinDir: a local build from the checkout when there is
        one, otherwise this release's build from GitHub, checksum-verified. Returns
        { Path, Source, Detail }; Path is $null when it is not installed, and a program
        already installed is then left in place rather than removed.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$BinDir,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Version,
        [string]$Repository = 'danswett/agent-ha-bridge',

        # Fetches a URL to a file; replaced by tests.
        [scriptblock]$Download = {
            param([string]$Url, [string]$OutFile)
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 60 `
                -Headers @{ 'User-Agent' = 'agent-ha-bridge' } | Out-Null
        }
    )

    $result = [pscustomobject]@{ Path = $null; Source = ''; Detail = '' }
    $target = Join-Path $BinDir (Get-BridgeNativeHookName)
    if (-not (Test-Path -LiteralPath $BinDir)) { New-Item -ItemType Directory -Path $BinDir -Force | Out-Null }

    # Staged under a name that keeps .exe: Windows will not run it to check otherwise.
    $staged = Join-Path $BinDir ('staged-' + (Get-BridgeNativeHookName))
    try {
        $local = Join-Path (Join-Path $RepoRoot 'hook') (Get-BridgeNativeHookName)
        if ([IO.File]::Exists($local)) {
            Copy-Item -LiteralPath $local -Destination $staged -Force
            $result.Source = 'local build'
        }
        else {
            $asset = Get-BridgeNativeHookAsset
            if (-not $asset) { $result.Detail = 'no build for this platform'; return $result }
            $tag = 'v' + ($Version -replace '^[vV]', '')
            if ($tag -eq 'v') { $result.Detail = 'no version to fetch'; return $result }
            $base = "https://github.com/$Repository/releases/download/$tag"
            $sums = "$target.sums"
            try {
                & $Download "$base/SHA256SUMS" $sums
                & $Download "$base/$asset" $staged
            }
            catch {
                $result.Detail = "release $tag has no native hook for this machine ($($_.Exception.Message))"
                return $result
            }
            $expected = @(Get-Content -LiteralPath $sums | ForEach-Object {
                    $parts = ($_ -split '\s+', 2)
                    if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -eq $asset) { $parts[0].ToLowerInvariant() }
                }) | Select-Object -First 1
            Remove-Item -LiteralPath $sums -Force -ErrorAction SilentlyContinue
            $actual = (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash.ToLowerInvariant()
            if (-not $expected -or $expected -ne $actual) {
                $result.Detail = "checksum mismatch for $asset; not installed"
                return $result
            }
            $result.Source = "release $tag"
        }

        if (-not $script:BridgeIsWindows) {
            [IO.File]::SetUnixFileMode($staged, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupExecute, OtherRead, OtherExecute')
        }
        if (-not (Test-BridgeNativeHook -Path $staged)) {
            $result.Detail = "the $($result.Source) does not run here (blocked by antivirus?); not installed"
            return $result
        }

        # A hook may be running the old one; Windows lets a running program be renamed
        # but not replaced.
        if ([IO.File]::Exists($target)) {
            $old = "$target.old"
            Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
            try { Move-Item -LiteralPath $target -Destination $old -Force } catch { }
        }
        Move-Item -LiteralPath $staged -Destination $target -Force
        Remove-Item -LiteralPath "$target.old" -Force -ErrorAction SilentlyContinue
        $result.Path = $target
        $result.Detail = "installed from the $($result.Source)"
        return $result
    }
    catch {
        $result.Detail = "could not install: $($_.Exception.Message)"
        return $result
    }
    finally {
        Remove-Item -LiteralPath $staged, "$target.sums" -Force -ErrorAction SilentlyContinue
    }
}
