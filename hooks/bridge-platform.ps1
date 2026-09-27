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

function Get-BridgeProcessInfo {
    <#
        One process as { ProcessId, ParentProcessId, Name, CommandLine, CreationDate },
        or $null when it is not running. Name is the executable's file name, with .exe
        on Windows as WMI reports it. On macOS CommandLine is filled in only with
        -WithCommandLine, since it costs a second `ps`.
    #>
    param([Parameter(Mandatory)][int]$ProcessId, [switch]$WithCommandLine)

    if ($ProcessId -le 0) { return $null }
    if ($script:BridgeIsWindows) {
        return Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue |
            Select-Object ProcessId, ParentProcessId, Name, CommandLine, CreationDate
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
        same shape as Get-BridgeProcessInfo, command lines included.
    #>
    param([Parameter(Mandatory)][string]$Name)

    if ($script:BridgeIsWindows) {
        return @(Get-CimInstance Win32_Process -Filter "Name='$Name.exe'" -ErrorAction SilentlyContinue |
            Select-Object ProcessId, ParentProcessId, Name, CommandLine, CreationDate)
    }
    $all = try { @(& /bin/ps -A -o 'pid=,ppid=,etime=,ucomm=' 2>$null) } catch { @() }
    $global:LASTEXITCODE = 0
    @($all | ForEach-Object { ConvertFrom-BridgePsLine -Line $_ } | Where-Object { $_ -and $_.Name -eq $Name } | ForEach-Object {
        $_.CommandLine = Get-BridgeCommandLine -ProcessId $_.ProcessId
        $_
    })
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
    <# Every running process of an agent's CLI, as Get-Process objects. #>
    param([Parameter(Mandatory)][string]$Agent)
    if ($script:BridgeIsWindows) { return @(Get-Process -Name $Agent -ErrorAction SilentlyContinue) }
    @(@(Get-Process -Name $Agent -ErrorAction SilentlyContinue) + @(Get-Process -Name 'node' -ErrorAction SilentlyContinue) |
        Where-Object { Test-BridgeAgentProcess -Process $_ -Agent $Agent })
}

function Find-BridgeAgentAncestor {
    <#
        Walks up from $StartPid to the first process that is the named agent's CLI,
        returning its id, or 0. How a hook finds the session it belongs to: a hook
        runs as a descendant of its session, so this picks the right one even with
        several open.
    #>
    param([Parameter(Mandatory)][string]$Agent, [int]$StartPid = $PID, [int]$MaxDepth = 12)

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
