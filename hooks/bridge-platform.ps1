<#
    What differs between Windows and macOS, in one place.

    The bridge was written for Windows: processes were looked up through WMI, the
    temporary folder was $env:TEMP, and replies were typed into a session through the
    Windows console API. On macOS none of those exist. Everything here answers the
    same question both ways, so the rest of the bridge asks it once:

      * Initialize-BridgePlatform - $env:TEMP on macOS, where it is not set.
      * Get-BridgeProcessInfo / Get-BridgeProcessesNamed - a process's parent, name
        and command line, from WMI on Windows and `ps` elsewhere.
      * Test-BridgeAgentProcess - whether a process is a given agent's CLI. On macOS
        an npm-installed CLI runs as `node .../copilot/...`, so the name alone is
        not enough.
      * The tmux primitives - on macOS a session is reached through the tmux pane it
        runs in: `send-keys` types into it and `capture-pane` reads it, where Windows
        attaches to its console.

    Loaded by the core (decision-bridge-common.ps1) and by each adapter's hooks,
    which are installed apart from the core and so carry their own copy.
#>

$script:BridgeIsWindows = [bool]($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop')

# pid|start-time -> the session id on that process's command line, or ''. Memoised
# because reading a command line costs about 77 ms and the daemon asks every few
# seconds; Get-BridgeAgentProcessSessionIds prunes it as processes go.
$script:BridgeAgentSessionIdCache = @{}

function Initialize-BridgePlatform {
    <#
        On macOS, sets $env:TEMP - the name every script uses for the temporary folder
        - to the per-user one .NET reports ($TMPDIR). Windows always has it.
    #>
    if ($script:BridgeIsWindows) { return }
    if ([string]::IsNullOrWhiteSpace($env:TEMP)) {
        $env:TEMP = [IO.Path]::GetTempPath().TrimEnd('/')
    }
}
Initialize-BridgePlatform

function Add-BridgeCompiledType {
    <#
        Adds a C# type the way `Add-Type -TypeDefinition` does, without loading the C#
        compiler into this process.

        Add-Type compiles in-process with Roslyn, which stays loaded for the life of the
        process: about 60 MB of the daemon, for two small types whose source never
        changes. Instead the source is compiled once, by a short-lived pwsh, into a DLL
        named by a hash of the source and this PowerShell's version, under
        ~/.agent-ha-bridge/cache; every later start just loads that DLL. Anything that
        goes wrong falls back to compiling in-process, as before.
    #>
    param(
        [Parameter(Mandatory)][string]$TypeName,
        [Parameter(Mandatory)][string]$Source,
        [string]$CacheDir = (Join-Path (Get-BridgeInstallContext).BridgeHome 'cache')
    )

    if (([Management.Automation.PSTypeName]$TypeName).Type) { return }
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes("$($PSVersionTable.PSVersion)`n$Source")
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).Substring(0, 16).ToLowerInvariant()
        $dll = Join-Path $CacheDir "$TypeName-$hash.dll"
        if (-not [IO.File]::Exists($dll)) {
            [void][IO.Directory]::CreateDirectory($CacheDir)
            $sourceFile = Join-Path $CacheDir "$TypeName-$hash.cs"
            $partial = "$dll.$PID.tmp"
            [IO.File]::WriteAllText($sourceFile, $Source)
            $pwsh = (Get-Process -Id $PID).Path
            $command = "Add-Type -TypeDefinition ([IO.File]::ReadAllText('$($sourceFile.Replace("'", "''"))')) -OutputAssembly '$($partial.Replace("'", "''"))' -OutputType Library"
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            $compile = Invoke-BridgeCommandProbe -Executable $pwsh -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -TimeoutMs 30000
            if (-not $compile.Ran -or $compile.TimedOut -or $compile.ExitCode -ne 0) { throw "Type compilation failed: $($compile.Output)" }
            Remove-Item -LiteralPath $sourceFile -Force -ErrorAction SilentlyContinue
            # Renamed into place, so another process never loads half a file; if one got
            # there first, its copy is as good.
            if ([IO.File]::Exists($partial)) {
                try { [IO.File]::Move($partial, $dll) } catch { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
            }
        }
        if ([IO.File]::Exists($dll)) {
            Add-Type -Path $dll
            if (([Management.Automation.PSTypeName]$TypeName).Type) { return }
        }
    }
    catch { }
    Add-Type -Language CSharp -TypeDefinition $Source
}

if (-not $script:BridgeIsWindows) {
    function Join-Path {
        <#
            Join-Path with Windows separators turned into /. The bridge builds its paths
            as Join-Path $HOME '.agent-ha-bridge\hooks', and on macOS a backslash is an
            ordinary character to .NET: [IO.File]::Exists on such a path is always
            false. Defined only off Windows, so Windows is untouched.
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
            [AllowEmptyString()][string[]]$Path,
            [Parameter(Position = 1)][AllowNull()][AllowEmptyString()][string]$ChildPath,
            [Parameter(ValueFromRemainingArguments)][string[]]$AdditionalChildPath = @(),
            [switch]$Resolve
        )
        process {
            $splat = @{ Path = @($Path | ForEach-Object { $_ -replace '\\', '/' }); Resolve = $Resolve }
            if ($null -ne $ChildPath) { $splat.ChildPath = $ChildPath -replace '\\', '/' }
            if ($AdditionalChildPath.Count) { $splat.AdditionalChildPath = @($AdditionalChildPath | ForEach-Object { $_ -replace '\\', '/' }) }
            Microsoft.PowerShell.Management\Join-Path @splat
        }
    }
}

$installContextLibrary = Join-Path $PSScriptRoot 'bridge-install-context.ps1'
if (Test-Path -LiteralPath $installContextLibrary) { . $installContextLibrary }

function ConvertFrom-BridgeElapsedTime {
    <# `ps -o etime` ([[dd-]hh:]mm:ss) as a start time. #>
    param([string]$Elapsed)
    $e = ([string]$Elapsed).Trim()
    $days = 0
    if ($e -match '^(\d+)-(.*)$') { $days = [int]$Matches[1]; $e = $Matches[2] }
    $parts = @($e.Split(':') | ForEach-Object { [int]$_ })
    [array]::Reverse($parts)
    $seconds = 0
    if ($parts.Count -gt 0) { $seconds += $parts[0] }
    if ($parts.Count -gt 1) { $seconds += 60 * $parts[1] }
    if ($parts.Count -gt 2) { $seconds += 3600 * $parts[2] }
    [DateTime]::Now.AddSeconds( - ($days * 86400 + $seconds))
}

function ConvertFrom-BridgePsLine {
    <#
        One line of `ps -o pid=,ppid=,etime=,ucomm=`. ucomm - the short process name,
        never a path - is last, so a name with a space in it still parses. The command
        line is fetched separately, and only when asked for (Get-BridgeCommandLine):
        `comm` and `args` both carry spaces and cannot share a line safely.
    #>
    param([string]$Line)
    if ($Line -notmatch '^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.+?)\s*$') { return $null }
    [pscustomobject]@{
        ProcessId       = [int]$Matches[1]
        ParentProcessId = [int]$Matches[2]
        Name            = $Matches[4]
        Path            = ''
        CommandLine     = $null
        CreationDate    = ConvertFrom-BridgeElapsedTime -Elapsed $Matches[3]
    }
}

function Get-BridgeCommandLine {
    <# A process's full command line, or ''. #>
    param([Parameter(Mandatory)][int]$ProcessId)
    if ($script:BridgeIsWindows) {
        return [string](Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue).CommandLine
    }
    try { [string](& /bin/ps -o 'args=' -p $ProcessId 2>$null | Select-Object -First 1) } catch { '' }
    finally { $global:LASTEXITCODE = 0 }
}

function ConvertFrom-BridgeProcessObject {
    <#
        A Windows Get-Process object in Get-BridgeProcessInfo's shape.

        Get-Process rather than WMI: a WMI query costs about 100 ms, and a hook walking
        up four or five parents spent most of its second there - time Claude and Codex
        wait for. The parent and path come from the process itself in a few
        milliseconds; only the command line needs WMI, so it is fetched on request.
    #>
    param([Parameter(Mandatory)]$Process, [switch]$WithCommandLine)
    $parentId = 0
    try { $parent = $Process.Parent; if ($parent) { $parentId = [int]$parent.Id } } catch { }
    [pscustomobject]@{
        ProcessId       = [int]$Process.Id
        ParentProcessId = $parentId
        Name            = "$($Process.ProcessName).exe"
        Path            = $(try { [string]$Process.Path } catch { '' })
        CommandLine     = $(if ($WithCommandLine) { Get-BridgeCommandLine -ProcessId $Process.Id } else { $null })
        CreationDate    = $(try { $Process.StartTime } catch { $null })
    }
}

function Get-BridgeProcessInfo {
    <#
        One process as { ProcessId, ParentProcessId, Name, Path, CommandLine,
        CreationDate }, or $null when it is not running. Name is the executable's file
        name, with .exe on Windows. CommandLine is filled in only with
        -WithCommandLine: it costs a WMI query on Windows and a second `ps` on macOS.
        Path is known on Windows only.
    #>
    param([Parameter(Mandatory)][int]$ProcessId, [switch]$WithCommandLine)

    if ($ProcessId -le 0) { return $null }
    if ($script:BridgeIsWindows) {
        $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if (-not $process) { return $null }
        return ConvertFrom-BridgeProcessObject -Process $process -WithCommandLine:$WithCommandLine
    }
    $info = $null
    try {
        $line = & /bin/ps -o 'pid=,ppid=,etime=,ucomm=' -p $ProcessId 2>$null | Select-Object -First 1
        # ps exits 1 for a process that has gone, which is an answer, not a failure -
        # and left in $LASTEXITCODE it became the exit code of whatever hook asked.
        $global:LASTEXITCODE = 0
        if ($line) { $info = ConvertFrom-BridgePsLine -Line $line }
    }
    catch { }
    if ($info -and $WithCommandLine) { $info.CommandLine = Get-BridgeCommandLine -ProcessId $info.ProcessId }
    $info
}

function Get-BridgeProcessesNamed {
    <#
        Every running process whose executable is named $Name (without .exe), in the
        same shape as Get-BridgeProcessInfo; with command lines when asked for.
    #>
    param([Parameter(Mandatory)][string]$Name, [switch]$WithCommandLine)

    if ($script:BridgeIsWindows) {
        return @(Get-Process -Name $Name -ErrorAction SilentlyContinue |
                ForEach-Object { ConvertFrom-BridgeProcessObject -Process $_ -WithCommandLine:$WithCommandLine })
    }
    $all = try { @(& /bin/ps -A -o 'pid=,ppid=,etime=,ucomm=' 2>$null) } catch { @() }
    $global:LASTEXITCODE = 0
    @($all | ForEach-Object { ConvertFrom-BridgePsLine -Line $_ } | Where-Object { $_ -and $_.Name -eq $Name } | ForEach-Object {
            if ($WithCommandLine) { $_.CommandLine = Get-BridgeCommandLine -ProcessId $_.ProcessId }
            $_
        })
}

function Test-BridgeRuntimeProcess {
    param([Parameter(Mandatory)]$Process, [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][ValidateSet('daemon', 'supervisor', 'devbox-keepawake', 'setup-copilot', 'setup-claude', 'setup-codex', 'setup-mcp')][string]$Role)
    if (-not $Process.ProcessId -or -not $Process.Path -or -not $Process.CreationDate -or
        [IO.Path]::GetFileNameWithoutExtension([string]$Process.Path) -notin @('pwsh', 'powershell')) { return $false }
    $targetSuffix = ''
    $paths = if ($Role.StartsWith('setup-')) {
        $client = $Role.Substring(6)
        $target = [regex]::Escape($Context.BridgeHome)
        $targetSuffix = "\s+(?i:-InstallRoot)\s+(?:`"$target`"|'$target'|$target)(?=\s|$)"
        if ($client -eq 'copilot') { @(Join-Path $Context.BridgeHome 'installer\install.ps1') }
        else { @(Join-Path $Context.BridgeHome "installer\$client\install-$client.ps1") }
    } elseif ($Role -eq 'devbox-keepawake') {
        @(Join-Path $Context.HooksDir 'agent-bridge-devbox-keepawake.ps1')
    } else {
        @((Join-Path $Context.HooksDir "agent-bridge-$Role.ps1"),
            (Join-Path $Context.CopilotHome "hooks\copilot-bridge-$Role.ps1"))
    }
    $prefix = '^\s*(?:"(?<exe>[^"]+)"|(?<exe>\S+))\s+(?:(?i:-NoProfile|-NonInteractive|-NoLogo|-WindowStyle\s+Hidden|-ExecutionPolicy\s+\w+)\s+)*(?i:-File)\s+'
    $options = if ($script:BridgeIsWindows) { [Text.RegularExpressions.RegexOptions]::IgnoreCase } else { [Text.RegularExpressions.RegexOptions]::None }
    foreach ($path in $paths) {
        $escaped = [regex]::Escape($path)
        $match = [regex]::Match([string]$Process.CommandLine, ($prefix + "(?:`"$escaped`"|'$escaped'|$escaped)(?=\s|$)" + $targetSuffix), $options)
        if ($match.Success) {
            $executable = $match.Groups['exe'].Value
            if ([IO.Path]::IsPathFullyQualified($executable)) { return Test-BridgeInstallPath $executable ([string]$Process.Path) }
            return $executable -in @('pwsh', 'pwsh.exe', 'powershell', 'powershell.exe')
        }
    }
    $false
}

function Get-BridgeRuntimeProcess {
    param([Parameter(Mandatory)][int]$ProcessId, [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][ValidateSet('daemon', 'supervisor', 'devbox-keepawake', 'setup-copilot', 'setup-claude', 'setup-codex', 'setup-mcp')][string]$Role,
        [switch]$RequireReadable)
    $process = Get-BridgeProcessInfo -ProcessId $ProcessId -WithCommandLine
    if (-not $process) {
        if ($RequireReadable) {
            $readErrors = @()
            $remaining = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue -ErrorVariable readErrors
            if ($remaining -or @($readErrors | Where-Object {
                $_.FullyQualifiedErrorId -notlike 'NoProcessFoundForGivenId,*'
            }).Count) { throw 'Runtime ownership could not be read; cleanup was not authorized.' }
        }
        return $null
    }
    if (-not $process.Path -or -not $process.CreationDate) {
        try {
            $native = Get-Process -Id $ProcessId -ErrorAction Stop
            $process.Path = $native.Path
            $process.CreationDate = $native.StartTime
        }
        catch {
            if ($RequireReadable) { throw 'Runtime ownership could not be read; cleanup was not authorized.' }
            return $null
        }
    }
    if ($RequireReadable -and (-not $process.Path -or -not $process.CreationDate -or -not $process.CommandLine)) {
        throw 'Runtime ownership is unreadable; cleanup was not authorized.'
    }
    if (-not (Test-BridgeRuntimeProcess -Process $process -Context $Context -Role $Role)) { return $null }
    $record = Read-BridgeInstallRecord -Path (Get-BridgeRuntimePath -Name "$Role.process.json" -Context $Context)
    if ($record -and [int]$record['pid'] -eq $ProcessId) {
        if ([string]$record['installationId'] -cne [string]$Context.Id -or
            -not $record['executable'] -or
            -not (Test-BridgeInstallPath ([string]$record['executable']) ([string]$process.Path)) -or
            [long]$record['startedUtcTicks'] -ne ([datetime]$process.CreationDate).ToUniversalTime().Ticks) { return $null }
    }
    $process
}

function Get-BridgeOwnedRuntimeProcesses {
    param([Parameter(Mandatory)]$Context,
        [ValidateSet('daemon', 'supervisor', 'devbox-keepawake', 'setup-copilot', 'setup-claude', 'setup-codex', 'setup-mcp')]
        [string[]]$Roles = @('supervisor', 'daemon', 'devbox-keepawake', 'setup-copilot', 'setup-claude', 'setup-codex', 'setup-mcp'),
        [switch]$RequireReadable)
    $candidates = @(Get-BridgeProcessesNamed -Name 'pwsh' -WithCommandLine)
    foreach ($role in $Roles) {
        $scriptName = if ($role -eq 'setup-copilot') { 'install.ps1' }
        elseif ($role.StartsWith('setup-')) { "install-$($role.Substring(6)).ps1" }
        else { "bridge-$role.ps1" }
        $processIds = @(foreach ($candidate in $candidates) {
            if ($candidate.ProcessId -ne $PID -and [string]$candidate.CommandLine -match [regex]::Escape($scriptName)) {
                [int]$candidate.ProcessId
            }
        })
        $record = if ($RequireReadable) {
            Read-BridgeInstallRecord -Path (Get-BridgeRuntimePath -Name "$role.process.json" -Context $Context)
        } else { $null }
        if ($record -and [int]$record['pid'] -gt 0 -and [int]$record['pid'] -ne $PID) {
            $processIds += [int]$record['pid']
        }
        foreach ($processId in @($processIds | Select-Object -Unique)) {
            $requireProof = $RequireReadable -and $record -and [int]$record['pid'] -eq $processId
            $owned = Get-BridgeRuntimeProcess -ProcessId $processId -Context $Context -Role $role -RequireReadable:$requireProof
            if ($owned) {
                $owned | Add-Member -NotePropertyName BridgeRuntimeRole -NotePropertyValue $role -Force
                $owned
            }
        }
    }
}

function Register-BridgeRuntimeProcess {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][ValidateSet('daemon', 'supervisor', 'devbox-keepawake')][string]$Role)
    if ($Role -eq 'devbox-keepawake') {
        $existing = Read-BridgeInstallRecord -Path (Get-BridgeRuntimePath -Name "$Role.process.json" -Context $Context)
        if ($existing) {
            if ([string]$existing['installationId'] -cne $Context.Id -or -not $existing['pid']) {
                throw 'Existing keep-awake receipt ownership is invalid; it was preserved.'
            }
            if (Get-BridgeRuntimeProcess -ProcessId ([int]$existing['pid']) -Context $Context -Role $Role -RequireReadable) {
                throw 'An owned keep-awake process is still running; its receipt was preserved.'
            }
        }
    }
    $process = Get-Process -Id $PID -ErrorAction Stop
    $directory = Get-BridgeRuntimeRoot -Context $Context
    [void][IO.Directory]::CreateDirectory($directory)
    @{
        pid = $PID; installationId = $Context.Id; executable = $process.Path
        startedUtcTicks = $process.StartTime.ToUniversalTime().Ticks
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $directory "$Role.process.json") -Encoding utf8
}

function Unregister-BridgeRuntimeProcess {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][ValidateSet('daemon', 'supervisor', 'devbox-keepawake')][string]$Role)
    $path = Get-BridgeRuntimePath -Name "$Role.process.json" -Context $Context
    Assert-BridgeInstallPayload -Root (Get-BridgeRuntimeRoot -Context $Context) -RelativePaths @("$Role.process.json")
    $record = Read-BridgeInstallRecord -Path $path
    $process = Get-Process -Id $PID -ErrorAction Stop
    if (-not $record -or [int]$record['pid'] -ne $PID -or [string]$record['installationId'] -cne $Context.Id -or
        -not $record['executable'] -or -not (Test-BridgeInstallPath ([string]$record['executable']) $process.Path) -or
        [long]$record['startedUtcTicks'] -ne $process.StartTime.ToUniversalTime().Ticks) {
        throw 'Runtime receipt ownership changed; the replacement receipt was preserved.'
    }
    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
}

function Stop-BridgeOwnedRuntime {
    param([Parameter(Mandatory)]$Context,
        [ValidateSet('supervisor', 'daemon', 'devbox-keepawake', 'setup-copilot', 'setup-claude', 'setup-codex', 'setup-mcp')]
        [string[]]$Roles = @('supervisor', 'daemon', 'devbox-keepawake', 'setup-copilot', 'setup-claude', 'setup-codex', 'setup-mcp'))
    foreach ($process in @(Get-BridgeOwnedRuntimeProcesses -Context $Context -Roles $Roles -RequireReadable)) {
        $role = $process.BridgeRuntimeRole
        $current = Get-BridgeRuntimeProcess -ProcessId ([int]$process.ProcessId) -Context $Context -Role $role -RequireReadable
        if (-not $current -or
            ([datetime]$current.CreationDate).ToUniversalTime().Ticks -ne ([datetime]$process.CreationDate).ToUniversalTime().Ticks -or
            -not (Test-BridgeInstallPath ([string]$current.Path) ([string]$process.Path))) {
            throw 'Runtime ownership changed before shutdown; cleanup has not been authorized.'
        }
        Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        $exited = $false
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            $remaining = Get-BridgeRuntimeProcess -ProcessId ([int]$process.ProcessId) -Context $Context -Role $role -RequireReadable
            if (-not $remaining -or
                ([datetime]$remaining.CreationDate).ToUniversalTime().Ticks -ne ([datetime]$process.CreationDate).ToUniversalTime().Ticks) {
                $exited = $true
                break
            }
            Start-Sleep -Milliseconds 100
        }
        if (-not $exited) { throw 'The owned runtime did not stop; its files were preserved.' }
    }
    if ($Roles -contains 'supervisor' -and @(Get-BridgeOwnedRuntimeProcesses -Context $Context -Roles $Roles -RequireReadable).Count) {
        throw 'An owned runtime restarted during shutdown; cleanup was not authorized.'
    }
}

function Test-BridgeTaskOwnership {
    param([Parameter(Mandatory)]$Task, [Parameter(Mandatory)]$Context,
        [ValidateSet('daemon', 'devbox-keepawake')][string]$Role = 'daemon')
    if (@($Task.Actions).Count -ne 1) { return $false }
    $launchers = if ($Role -eq 'devbox-keepawake') {
        @(Join-Path $Context.HooksDir 'agent-bridge-devbox-keepawake.vbs')
    } else { @(
        (Join-Path $Context.HooksDir 'agent-bridge-launch.vbs'),
        (Join-Path $Context.CopilotHome 'hooks\copilot-bridge-launch.vbs')
    ) }
    foreach ($action in @($Task.Actions)) {
        if ([IO.Path]::GetFileName([string]$action.Execute) -ieq 'wscript.exe' -and
            $launchers -contains ([string]$action.Arguments).Trim().Trim('"')) { return $true }
    }
    $false
}

function Test-BridgeLaunchAgentOwnership {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Context)
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Ignore
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create($Path, $settings)
    try {
        $document = [Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($reader)
        if ($document.SelectSingleNode('/plist/dict/key[text()="Program"]')) { return $false }
        $key = $document.SelectSingleNode('/plist/dict/key[text()="ProgramArguments"]')
        if (-not $key -or -not $key.NextSibling -or $key.NextSibling.Name -ne 'array') { return $false }
        $arguments = @($key.NextSibling.SelectNodes('string') | ForEach-Object { $_.InnerText })
        if ($arguments.Count -lt 3 -or $key.NextSibling.ChildNodes.Count -ne $arguments.Count -or
            [IO.Path]::GetFileNameWithoutExtension([string]$arguments[0]) -notin @('pwsh', 'powershell')) { return $false }
        for ($index = 1; $index -lt $arguments.Count; $index++) {
            if ($arguments[$index] -eq '-File') {
                return $index + 1 -lt $arguments.Count -and
                    (Test-BridgeInstallPath ([string]$arguments[$index + 1]) (Join-Path $Context.HooksDir 'agent-bridge-daemon.ps1'))
            }
            if ($arguments[$index] -in @('-NoProfile', '-NonInteractive', '-NoLogo')) { continue }
            if ($arguments[$index] -in @('-ExecutionPolicy', '-WindowStyle') -and $index + 1 -lt $arguments.Count) {
                $index++
                if ($arguments[$index] -match '^\w+$') { continue }
            }
            return $false
        }
        $false
    }
    finally { $reader.Dispose() }
}

function Stop-BridgeOwnedService {
    param([Parameter(Mandatory)]$Context, [switch]$Remove,
        [ValidateSet('daemon', 'devbox-keepawake')][string[]]$Roles = @('daemon', 'devbox-keepawake'))
    if ($Context.Isolated) { return }
    if ($script:BridgeIsWindows) {
        foreach ($role in $Roles) {
            $currentName = if ($role -eq 'daemon') { $Context.TaskName } else { $Context.DevBoxTaskName }
            $names = if ($role -eq 'daemon') { @($currentName, 'AgentBridgeDaemon', 'CopilotBridgeDaemon') }
                else { @($currentName, 'AgentBridgeDevBoxKeepAwake') }
            foreach ($name in $names | Select-Object -Unique) {
                $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
                if (-not $task) { continue }
                if (-not (Test-BridgeTaskOwnership -Task $task -Context $Context -Role $role)) {
                    if ($name -eq $currentName) { throw 'The installation task points elsewhere; no cleanup was authorized.' }
                    continue
                }
                Stop-ScheduledTask -TaskName $name -ErrorAction Stop
                if ($Remove -or $name -ne $currentName -or $role -eq 'devbox-keepawake') {
                    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
                }
            }
        }
    }
    elseif ($Roles -contains 'daemon') {
        foreach ($label in @($Context.LaunchAgentLabel, 'com.agent-ha-bridge.daemon') | Select-Object -Unique) {
            $plist = Join-Path $Context.Home "Library\LaunchAgents\$label.plist"
            if (-not [IO.File]::Exists($plist)) { continue }
            if (-not (Test-BridgeLaunchAgentOwnership -Path $plist -Context $Context)) {
                if ($label -eq $Context.LaunchAgentLabel) { throw 'The installation LaunchAgent points elsewhere; no cleanup was authorized.' }
                continue
            }
            $userId = (& id -u | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or $userId -notmatch '^\d+$') { throw 'Could not identify the LaunchAgent owner for shutdown.' }
            $service = "gui/$userId/$label"
            & launchctl print $service 2>$null | Out-Null
            $readCode = $LASTEXITCODE
            if ($readCode -eq 0) {
                & launchctl bootout $service 2>$null | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "LaunchAgent shutdown failed (bootout exit $LASTEXITCODE); its files were preserved." }
                & launchctl print $service 2>$null | Out-Null
                $readCode = $LASTEXITCODE
            }
            if ($readCode -ne 113) { throw "LaunchAgent shutdown could not be confirmed (print exit $readCode); its files were preserved." }
            $global:LASTEXITCODE = 0
            if ($Remove -or $label -ne $Context.LaunchAgentLabel) { Remove-Item -LiteralPath $plist -Force }
        }
    }
}
function Test-BridgeAgentProcess {
    <#
        Whether a process (from Get-Process or Get-BridgeProcessInfo) is the named
        agent's CLI: copilot, claude, codex. Exact name on Windows - copilotapp and
        copilotapphost also run there. On macOS the name, or for a CLI that runs under
        node, the package in its command line.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Process,
        [Parameter(Mandatory)][string]$Agent
    )

    if ($null -eq $Process) { return $false }
    $name = if ($Process.PSObject.Properties['ProcessName']) { [string]$Process.ProcessName } else { [string]$Process.Name }
    $name = $name -replace '\.exe$', ''
    if ($name -eq $Agent) { return $true }
    if ($script:BridgeIsWindows) { return $false }

    if ($name -notin @('node', 'bun')) { return $false }
    $commandLine = if ($Process.PSObject.Properties['CommandLine'] -and $Process.CommandLine) { [string]$Process.CommandLine }
    else { Get-BridgeCommandLine -ProcessId ([int]$(if ($Process.PSObject.Properties['Id']) { $Process.Id } else { $Process.ProcessId })) }
    $package = switch ($Agent) {
        'copilot' { '@github/copilot' }
        'claude'  { '@anthropic-ai/claude-code' }
        'codex'   { '@openai/codex' }
        default   { "/$Agent" }
    }
    $commandLine.Contains($package) -or $commandLine -match "[/\\]$([regex]::Escape($Agent))(\.js)?(\s|$)"
}

function Get-BridgeAgentProcesses {
    <#
        Every running process of an agent's CLI, as Get-Process objects.

        Names are tried with and without .exe, and Test-BridgeAgentProcess strips it
        again. That is not Windows belt-and-braces: Claude Code ships a Bun-compiled
        binary that reports itself as claude.exe on macOS too, and Get-Process -Name is
        an exact match, so asking only for 'claude' returned nothing. The liveness of
        every Claude registration is decided by this set, so an empty one read every
        live session as dead and the sessions simply never got a card - while the
        window was open and answering.

        bun is fetched for the same reason it is accepted below: a CLI run under it
        would otherwise never be a candidate, and the check for it could never fire.
    #>
    param([Parameter(Mandatory)][string]$Agent)
    if ($script:BridgeIsWindows) { return @(Get-Process -Name $Agent -ErrorAction SilentlyContinue) }
    $candidates = @(@($Agent, "$Agent.exe", 'node', 'bun') | ForEach-Object {
            Get-Process -Name $_ -ErrorAction SilentlyContinue
        })
    @($candidates | Sort-Object -Property Id -Unique | Where-Object { Test-BridgeAgentProcess -Process $_ -Agent $Agent })
}

function Get-BridgeAgentProcessSessionIds {
    <#
        Which session each of $Processes is working in, as a pid -> session id map,
        read from the `--session-id` on its own command line.

        The `inuse.<pid>.lock` files under the session state root are not enough on
        their own. A Copilot session resumed onto an id that already has history
        writes no lock at all: on 2026-09-30 a resume loaded all 103 turns and ran
        normally, while the bridge - which found Copilot sessions only by those locks -
        never saw it. No card, no reply box, and a launch note stuck on "may still be
        starting" until a second Resume press put a second CLI on the same transcript,
        which is the one thing Get-LiveCopilotSessions exists to prevent. The command
        line carries the id for a new session and a resumed one alike, and names
        exactly one, where a lock only says a pid touched a directory at some point.

        Reading a command line is expensive - about 77 ms per process, through the
        Get-Process property and WMI alike - and the daemon asks this every few
        seconds, so each answer is memoised. The key is the pid *and* its start time:
        a pid on its own is reused, and a recycled one would otherwise keep answering
        with the dead process's session for as long as the daemon ran.
    #>
    param([AllowEmptyCollection()][object[]]$Processes = @())

    $sessions = @{}
    $seen = @{}
    foreach ($process in @($Processes)) {
        if ($null -eq $process) { continue }
        $processId = 0
        try { $processId = [int]$process.Id } catch { continue }
        if ($processId -le 0) { continue }

        # Cheap, unlike the command line, so it costs nothing to pin the key with it.
        $startedAt = ''
        try { $startedAt = [string]$process.StartTime.Ticks } catch { }
        $key = "$processId|$startedAt"
        $seen[$key] = $true

        if (-not $script:BridgeAgentSessionIdCache.ContainsKey($key)) {
            # Read once and keep it: this is the expensive line in the function, and
            # testing the property for emptiness before using it would pay for it
            # twice.
            $commandLine = ''
            if ($process.PSObject.Properties['CommandLine']) {
                try { $commandLine = [string]$process.CommandLine } catch { $commandLine = '' }
            }
            if ([string]::IsNullOrWhiteSpace($commandLine)) {
                $commandLine = Get-BridgeCommandLine -ProcessId $processId
            }
            # `--session-id <id>` and `--session-id=<id>` are both spelled by the CLI,
            # and the value is matched as a UUID so a prefix or a name cannot be taken
            # for one.
            $found = ''
            if ($commandLine -match '--session-id[=\s]+"?([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                $found = $Matches[1]
            }
            $script:BridgeAgentSessionIdCache[$key] = $found
        }

        $sessionId = [string]$script:BridgeAgentSessionIdCache[$key]
        if (-not [string]::IsNullOrWhiteSpace($sessionId)) { $sessions[$processId] = $sessionId }
    }

    # A process that has gone takes its entry with it, so a daemon up for days does
    # not keep one for every session it ever saw. Only entries this call did not
    # account for are looked at, so an ordinary pass does no work here at all, and
    # the test is that the process is gone rather than merely absent from
    # $Processes - a caller may legitimately ask about one agent at a time.
    foreach ($key in @($script:BridgeAgentSessionIdCache.Keys)) {
        if ($seen.ContainsKey($key)) { continue }
        $cachedPid = 0
        if ([string]$key -match '^(\d+)\|') { $cachedPid = [int]$Matches[1] }
        if ($cachedPid -gt 0 -and (Get-Process -Id $cachedPid -ErrorAction SilentlyContinue)) { continue }
        [void]$script:BridgeAgentSessionIdCache.Remove($key)
    }

    $sessions
}

function Find-BridgeAgentAncestor {
    <#
        Walks up from $StartPid to the first process that is the named agent's CLI,
        returning its id, or 0. How a hook finds the session it belongs to: a hook
        runs as a descendant of its session, so this picks the right one even with
        several open.

        -Ancestors is the chain a hook recorded, nearest first, for when the walk is
        made after the hook has exited (the daemon, from the native hook's spool). The
        shells between the hook and the agent have gone by then, so a pid no longer
        running is skipped rather than ending the walk.
    #>
    param([Parameter(Mandatory)][string]$Agent, [int]$StartPid = $PID, [int]$MaxDepth = 12, [int[]]$Ancestors = @())

    if (@($Ancestors).Count -gt 0) {
        foreach ($ancestorPid in @($Ancestors | Select-Object -First $MaxDepth)) {
            $process = Get-BridgeProcessInfo -ProcessId $ancestorPid
            if ($process -and (Test-BridgeAgentProcess -Process $process -Agent $Agent)) { return [int]$process.ProcessId }
        }
        return 0
    }

    $current = $StartPid
    for ($depth = 0; $depth -lt $MaxDepth; $depth++) {
        $process = Get-BridgeProcessInfo -ProcessId $current
        if (-not $process) { return 0 }
        if (Test-BridgeAgentProcess -Process $process -Agent $Agent) { return [int]$process.ProcessId }
        if (-not $process.ParentProcessId -or $process.ParentProcessId -eq $current) { return 0 }
        $current = [int]$process.ParentProcessId
    }
    0
}

function Invoke-BridgeCommandProbe {
    <#
        Runs a command with a deadline and reports what it did: its exit code, what it
        wrote to either stream, and whether it had to be killed.

        Both the installer and the launcher use this to ask an agent for its version,
        which is the cheapest way to tell a working install from a shim left behind by
        a half-finished one - npm writes a package's `bin` entry before running its
        postinstall, so a postinstall that fails leaves a command that exists, is on
        PATH, and does nothing. The deadline matters because the launcher calls this
        from inside the daemon: an agent that waits for input rather than answering
        must not hold a launch open.

        Arguments are handed to Start-Process as they are, which does its own quoting
        on Windows - fine for the plain flags this is for, not for arguments that
        contain quotes of their own.
    #>
    param(
        [Parameter(Mandatory)][string]$Executable,
        [string[]]$Arguments = @('--version'),
        [int]$TimeoutMs = 5000,

        # Where to run it. Some commands answer differently depending on where they
        # are run - `agency config profiles` merges any agency.yaml found from the
        # current directory upwards - and the daemon's own directory is not something
        # a caller should have to reason about. Ignored when it does not exist.
        [AllowEmptyString()][AllowNull()][string]$WorkingDirectory = ''
    )

    $out = [IO.Path]::GetTempFileName()
    $err = [IO.Path]::GetTempFileName()
    # Output is both streams, flattened, which is what a one-line "why did this fail"
    # message wants. StandardOutput keeps stdout with its lines intact, for the
    # callers that have to parse a listing.
    $result = [pscustomobject]@{ ExitCode = -1; Output = ''; StandardOutput = ''; TimedOut = $false; Ran = $false }
    try {
        $start = @{
            FilePath               = $Executable
            ArgumentList           = $Arguments
            RedirectStandardOutput = $out
            RedirectStandardError  = $err
            PassThru               = $true
            NoNewWindow            = $true
            ErrorAction            = 'Stop'
        }
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory) -and (Test-Path -LiteralPath $WorkingDirectory)) {
            $start.WorkingDirectory = $WorkingDirectory
        }
        $process = Start-Process @start
        $result.Ran = $true
        if ($process.WaitForExit($TimeoutMs)) {
            $result.ExitCode = $process.ExitCode
        }
        else {
            $result.TimedOut = $true
            try { $process.Kill($true) } catch { }
        }
        $stdout = [string](Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue)
        $result.StandardOutput = $stdout
        $text = @(
            $stdout
            (Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue)
        ) -join ' '
        $result.Output = ($text -replace '\s+', ' ').Trim()
    }
    catch {
        # Start-Process throws outright when the file cannot be executed at all.
        $result.Output = ($_.Exception.Message -replace '\s+', ' ').Trim()
    }
    finally {
        Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
    }
    $result
}

function Test-BridgeCommandRuns {
    <#
        Whether a command is not merely present but actually runs. Answers --version
        with a zero exit code is the bar: every agent CLI supports it, and none of
        them treat it as work.
    #>
    param(
        [Parameter(Mandatory)][string]$Executable,
        [int]$TimeoutMs = 5000
    )

    $probe = Invoke-BridgeCommandProbe -Executable $Executable -TimeoutMs $TimeoutMs
    [bool]($probe.Ran -and -not $probe.TimedOut -and $probe.ExitCode -eq 0)
}

function Get-BridgePwshPath {
    <#
        pwsh, wherever it is.

        Get-Command alone is not enough in two places that matter: straight after a
        winget install, where this process's PATH predates it, and inside the daemon,
        which a scheduled task or LaunchAgent starts with a PATH that need not include
        PowerShell's own folder. A bare `(Get-Command pwsh).Source` also throws under
        StrictMode when the lookup fails, rather than returning nothing, so callers
        that meant to degrade gracefully did not.
    #>
    $command = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }

    $candidates = if ($script:BridgeIsWindows) {
        @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
            Where-Object { $_ } |
            ForEach-Object { Join-Path $_ 'PowerShell\7\pwsh.exe' }
    }
    else {
        @('/usr/local/bin/pwsh', '/opt/homebrew/bin/pwsh', '/opt/local/bin/pwsh',
            '/usr/bin/pwsh', '/usr/local/microsoft/powershell/7/pwsh')
    }
    foreach ($candidate in $candidates) {
        if ([IO.File]::Exists($candidate)) { return $candidate }
    }
    $null
}

# --------------------------------------------------------------------------- tmux

function Get-BridgeTmuxPath {
    <#
        tmux, found where Homebrew puts it as well as on PATH: a LaunchAgent starts
        the daemon with a minimal PATH that does not include /opt/homebrew/bin.
    #>
    $command = Get-Command tmux -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    # Homebrew on Apple silicon, then on Intel, then MacPorts - which Intel Macs use now
    # that Homebrew has dropped them.
    foreach ($candidate in @('/opt/homebrew/bin/tmux', '/usr/local/bin/tmux', '/opt/local/bin/tmux', '/usr/bin/tmux')) {
        if ([IO.File]::Exists($candidate)) { return $candidate }
    }
    $null
}

function Invoke-BridgeTmux {
    <#
        Runs tmux with the given arguments, as { Ok, Output }.

        An object rather than the output itself: most tmux commands succeed silently,
        and PowerShell hands an empty result back as $null - so returning the lines
        made every successful send-keys look like a failure.
    #>
    param([Parameter(Mandatory)][string[]]$Arguments)
    $tmux = Get-BridgeTmuxPath
    if (-not $tmux) { return [pscustomobject]@{ Ok = $false; Output = @() } }
    $output = @(& $tmux @Arguments 2>$null)
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = $output }
}

function Find-BridgeTmuxPane {
    <#
        The tmux pane a process runs in, as a pane id (%12), or $null.

        A pane records the pid of the process it started - the shell, or the agent
        itself when the bridge launched it - so the process and its ancestors are
        matched against every pane's pid.
    #>
    param([Parameter(Mandatory)][int]$ProcessId)

    $panes = Invoke-BridgeTmux -Arguments @('list-panes', '-a', '-F', '#{pane_pid} #{pane_id}')
    if (-not $panes.Ok) { return $null }
    $byPid = @{}
    foreach ($line in $panes.Output) {
        if ($line -match '^(\d+)\s+(%\d+)$') { $byPid[[int]$Matches[1]] = $Matches[2] }
    }
    $current = $ProcessId
    for ($depth = 0; $depth -lt 16 -and $current -gt 1; $depth++) {
        if ($byPid.ContainsKey($current)) { return $byPid[$current] }
        $info = Get-BridgeProcessInfo -ProcessId $current
        if (-not $info -or $info.ParentProcessId -eq $current) { break }
        $current = [int]$info.ParentProcessId
    }
    $null
}

function Send-BridgeTmuxKeys {
    <#
        Types into a pane. -Literal sends text as characters; otherwise the arguments
        are tmux key names (Enter, Down, Escape).
    #>
    param(
        [Parameter(Mandatory)][string]$Pane,
        [Parameter(Mandatory)][string[]]$Keys,
        [switch]$Literal
    )
    $arguments = @('send-keys', '-t', $Pane)
    if ($Literal) { $arguments += '-l' }
    $arguments += '--'
    $arguments += $Keys
    (Invoke-BridgeTmux -Arguments $arguments).Ok
}

function Read-BridgeTmuxPane {
    <# The visible text of a pane, or '' when it cannot be read. #>
    param([Parameter(Mandatory)][string]$Pane)
    $capture = Invoke-BridgeTmux -Arguments @('capture-pane', '-p', '-t', $Pane)
    if (-not $capture.Ok) { return '' }
    ($capture.Output -join "`n")
}

function Send-BridgeTmuxText {
    <#
        The tmux counterpart of ConsoleInjector.Send: types $Text into the pane of
        $ProcessId and, with -Submit, presses Enter after $SubmitDelayMs - a separate
        keypress, so a CLI treating the burst as a paste still submits. Returns the
        same "ok:<count>" or "<stage>-failed" strings, so callers read both alike.
    #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [switch]$Submit,
        [int]$SubmitDelayMs = 300
    )
    if (-not (Get-BridgeTmuxPath)) { return 'no-tmux' }
    $pane = Find-BridgeTmuxPane -ProcessId $ProcessId
    if (-not $pane) { return 'not-in-tmux' }
    if ($Text.Length -gt 0 -and -not (Send-BridgeTmuxKeys -Pane $pane -Keys @($Text) -Literal)) { return 'write-failed' }
    if ($Submit) {
        if ($SubmitDelayMs -gt 0) { Start-Sleep -Milliseconds $SubmitDelayMs }
        if (-not (Send-BridgeTmuxKeys -Pane $pane -Keys @('Enter'))) { return 'enter-failed' }
    }
    "ok:$($Text.Length)"
}

function Send-BridgeTmuxForm {
    <#
        The tmux counterpart of ConsoleInjector.SendForm: per field, Down to the
        chosen option or the typed text, then Enter to commit it. Same pacing, for
        the same reason: the prompt needs a moment before each keystroke.
    #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][int[]]$DownCounts,
        [AllowNull()][string[]]$Texts,
        [int]$StepDelayMs = 120
    )
    if (-not (Get-BridgeTmuxPath)) { return 'no-tmux' }
    $pane = Find-BridgeTmuxPane -ProcessId $ProcessId
    if (-not $pane) { return 'not-in-tmux' }
    $typed = 0
    Start-Sleep -Milliseconds ($StepDelayMs * 4)
    for ($f = 0; $f -lt $DownCounts.Count; $f++) {
        $text = if ($null -ne $Texts -and $f -lt $Texts.Count) { $Texts[$f] } else { $null }
        if ($null -ne $text) {
            if ($text.Length -gt 0) {
                if (-not (Send-BridgeTmuxKeys -Pane $pane -Keys @($text) -Literal)) { return 'write-failed' }
                $typed++
            }
        }
        else {
            for ($i = 0; $i -lt $DownCounts[$f]; $i++) {
                Start-Sleep -Milliseconds $StepDelayMs
                if (-not (Send-BridgeTmuxKeys -Pane $pane -Keys @('Down'))) { return 'down-failed' }
            }
        }
        Start-Sleep -Milliseconds ($StepDelayMs * 2)
        if (-not (Send-BridgeTmuxKeys -Pane $pane -Keys @('Enter'))) { return 'commit-failed' }
        Start-Sleep -Milliseconds ($StepDelayMs * 2)
    }
    "ok:form:$($DownCounts.Count):typed$typed"
}

function Send-BridgeTmuxChoice {
    <# The tmux counterpart of ConsoleInjector.SendChoice: Down to "Other", Enter, type, Enter. #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][int]$DownCount,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [int]$StepDelayMs = 120
    )
    if (-not (Get-BridgeTmuxPath)) { return 'no-tmux' }
    $pane = Find-BridgeTmuxPane -ProcessId $ProcessId
    if (-not $pane) { return 'not-in-tmux' }
    for ($i = 0; $i -lt $DownCount; $i++) {
        if (-not (Send-BridgeTmuxKeys -Pane $pane -Keys @('Down'))) { return 'down-failed' }
        Start-Sleep -Milliseconds $StepDelayMs
    }
    if (-not (Send-BridgeTmuxKeys -Pane $pane -Keys @('Enter'))) { return 'enter-failed' }
    Start-Sleep -Milliseconds ($StepDelayMs * 2)
    if ($Text.Length -gt 0 -and -not (Send-BridgeTmuxKeys -Pane $pane -Keys @($Text) -Literal)) { return 'write-failed' }
    Start-Sleep -Milliseconds ($StepDelayMs * 2)
    if (-not (Send-BridgeTmuxKeys -Pane $pane -Keys @('Enter'))) { return 'submit-failed' }
    'ok:choice'
}
