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

function Get-BridgeHookStats {
    <#
        How the native hook has been doing: from the line it logs for every run
        (%TEMP%\agent-bridge-hook.log, and the rotated .1), over the last $Hours.

        A run's path is `spool` (handed to the daemon - the fast path), `fallback` (the
        PowerShell hook ran instead) or `reply` (neither: the fixed reply alone, e.g. an
        event the hook could not use). NotSpooled / Total is the fallback rate; ByReason
        says why, with numbers in reasons folded together ("daemon heartbeat Ns old").
    #>
    param(
        [double]$Hours = 24,
        [string]$LogPath = (Join-Path $env:TEMP 'agent-bridge-hook.log'),
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $since = $Now.AddHours(-$Hours)
    $runs = [System.Collections.Generic.List[object]]::new()
    foreach ($path in @("$LogPath.1", $LogPath)) {
        if (-not [IO.File]::Exists($path)) { continue }
        foreach ($line in [IO.File]::ReadLines($path)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $run = $line | ConvertFrom-Json } catch { continue }
            $at = [DateTimeOffset]::MinValue
            if (-not $run.PSObject.Properties['at'] -or -not [DateTimeOffset]::TryParse([string]$run.at, [ref]$at) -or $at -lt $since -or $at -gt $Now) { continue }
            $runs.Add($run)
        }
    }

    $count = { param($Path) @($runs | Where-Object { [string]$_.path -eq $Path }).Count }
    $percentile = { param([object[]]$Values, [double]$P)
        $sorted = @($Values | Sort-Object)
        if ($sorted.Count -eq 0) { return $null }
        $sorted[[int][Math]::Min($sorted.Count - 1, [Math]::Floor($P * $sorted.Count))]
    }
    $notSpooled = @($runs | Where-Object { [string]$_.path -ne 'spool' })
    $byReason = [ordered]@{}
    foreach ($group in ($notSpooled | Group-Object { (([string]$_.reason -split ':')[0] -replace '\d+', 'N').Trim() } | Sort-Object Count -Descending)) {
        $byReason[$(if ($group.Name) { $group.Name } else { '(none)' })] = $group.Count
    }
    $byHook = [ordered]@{}
    foreach ($group in ($runs | Group-Object { "$($_.agent)/$($_.hook)" } | Sort-Object Name)) {
        $byHook[$group.Name] = [pscustomobject]@{
            Total = $group.Count
            NotSpooled = @($group.Group | Where-Object { [string]$_.path -ne 'spool' }).Count
        }
    }
    $allMs = @($runs | ForEach-Object { [double]$_.ms })
    $spoolMs = @($runs | Where-Object { [string]$_.path -eq 'spool' } | ForEach-Object { [double]$_.ms })
    $fallbackMs = @($runs | Where-Object { [string]$_.path -eq 'fallback' } | ForEach-Object { [double]$_.ms })

    [pscustomobject]@{
        Since = $since
        Total = $runs.Count
        Spooled = & $count 'spool'
        Fallback = & $count 'fallback'
        ReplyOnly = & $count 'reply'
        NotSpooled = $notSpooled.Count
        FallbackRate = if ($runs.Count) { [Math]::Round($notSpooled.Count / $runs.Count, 4) } else { 0 }
        ByReason = $byReason
        ByHook = $byHook
        MedianMs = & $percentile $allMs 0.5
        P95Ms = & $percentile $allMs 0.95
        SpoolMedianMs = & $percentile $spoolMs 0.5
        FallbackMedianMs = & $percentile $fallbackMs 0.5
    }
}

function Format-BridgeHookStats {
    <# One line for `agent-ha-bridge status`: runs, how many fell back and why, typical wait. #>
    param([Parameter(Mandatory)]$Stats, [double]$Hours = 24)

    if ($Stats.Total -eq 0) { return "no runs in the last $Hours h" }
    $text = "$($Stats.Total) runs in the last $Hours h, $($Stats.NotSpooled) not spooled ($([Math]::Round(100 * $Stats.FallbackRate, 1))%)"
    if ($Stats.NotSpooled) {
        $text += ': ' + (@($Stats.ByReason.GetEnumerator() | ForEach-Object { "$($_.Key) x$($_.Value)" }) -join ', ')
    }
    $text += "; median $($Stats.MedianMs) ms"
    if ($null -ne $Stats.FallbackMedianMs) { $text += " (fallbacks $($Stats.FallbackMedianMs) ms)" }
    $text
}

# The oldest Copilot CLI seen to run an `exec` hook (a program with no shell): 1.0.88,
# on DASDESK, 2026-09-27. The docs give no minimum, and an older CLI that did not know
# `exec` could drop the hook - so older ones keep their PowerShell hooks.
$script:BridgeCopilotExecMinVersion = [version]'1.0.88'

function Get-BridgeCopilotVersion {
    <# The installed Copilot CLI's version, from `copilot --version`, or $null. #>
    $command = Get-Command copilot -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { return $null }
    try {
        $text = (& $command.Source --version 2>$null | Out-String)
        $global:LASTEXITCODE = 0
        if ($text -match '(\d+\.\d+\.\d+)') { return [version]$Matches[1] }
    }
    catch { }
    $null
}

function Test-BridgeCopilotRunsExec {
    <# Whether this machine's Copilot CLI can run the native hook through `exec`. #>
    param([AllowNull()][version]$Version)
    $null -ne $Version -and $Version -ge $script:BridgeCopilotExecMinVersion
}

function ConvertTo-BridgeCopilotExecHook {
    <#
        Turns Copilot hook definitions that run a script through PowerShell
        (`powershell = "& '<script>'"`) into ones that run the native hook with no
        shell (`exec`, `args`), the script kept as its fallback. `exec` may not be
        combined with `powershell` or `bash`, so those go. Changes $HookDefs in place.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$HookDefs,
        [Parameter(Mandatory)][string]$NativeHook
    )

    $nativeNames = @{ agentStop = 'agent_stop'; preToolUse = 'ask_user'; notification = 'permission' }
    foreach ($eventName in @($HookDefs.Keys)) {
        if (-not $nativeNames.ContainsKey($eventName)) { continue }
        foreach ($def in $HookDefs[$eventName]) {
            $scriptPath = ([regex]::Match([string]$def.powershell, "'([^']+)'")).Groups[1].Value
            if (-not $scriptPath) { continue }
            $def.Remove('powershell')
            $def.Remove('bash')
            $def.exec = $NativeHook
            $def.args = @('copilot', $nativeNames[$eventName], $scriptPath)
        }
    }
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
