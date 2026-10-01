#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for finding a resumed Copilot session (hooks/bridge-platform.ps1,
    hooks/daemon-discovery.ps1, hooks/session-launch.ps1).

.DESCRIPTION
    A Copilot session resumed onto an id that already has history writes no
    `inuse.<pid>.lock`, and the bridge used to find Copilot sessions only by those
    locks - so a resumed session ran with no card and no reply box, and pressing
    Resume again put a second CLI on its transcript.

    These cover the command line as the second source: that it finds the session the
    locks miss, that it settles which session a pid owns when the locks are
    ambiguous, that the lock-based path still behaves as it did, and that a command
    line - the expensive part - is read once per process rather than every pass.

    Fixtures are real directories under a temporary root. No process is started, and
    nothing talks to Home Assistant.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')

$root = Join-Path ([IO.Path]::GetTempPath()) ('bridge-resume-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($root)
$script:DecisionBridgeConfig.SessionStateRoot = $root
$script:DaemonConfig.LogFile = Join-Path $root 'daemon.log'

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

# --- fixtures -------------------------------------------------------------------

$script:CommandLines = @{}
$script:CommandLineReads = 0
$script:FakeProcesses = @()
$script:LivePids = @{}

function New-FixtureSession {
    param(
        [Parameter(Mandatory)][string]$Id,
        [int[]]$LockPids = @(),
        [switch]$WithTranscript,
        [int]$TranscriptAgeMinutes = 0
    )
    $dir = Join-Path $root $Id
    [void][IO.Directory]::CreateDirectory($dir)
    foreach ($lockPid in $LockPids) {
        Set-Content -LiteralPath (Join-Path $dir "inuse.$lockPid.lock") -Value 'x' -Encoding UTF8
    }
    if ($WithTranscript) {
        $transcript = Join-Path $dir 'events.jsonl'
        Set-Content -LiteralPath $transcript -Value '{"type":"assistant.turn_start"}' -Encoding UTF8
        [IO.File]::SetLastWriteTimeUtc($transcript, [datetime]::UtcNow.AddMinutes(-$TranscriptAgeMinutes))
    }
    $dir
}

function New-FixtureProcess {
    param(
        [Parameter(Mandatory)][int]$Id,
        [string]$CommandLine = '',
        [int]$StartedTicksOffset = 0,
        [switch]$NoCommandLineProperty
    )
    $script:CommandLines[$Id] = $CommandLine
    $started = ([datetime]'2026-01-01T00:00:00Z').AddTicks($StartedTicksOffset)
    $process = [pscustomobject]@{ Id = $Id; StartTime = $started }
    if (-not $NoCommandLineProperty) {
        # A ScriptProperty so each read is counted: the real one costs about 77 ms,
        # which is the whole reason the answer is memoised.
        $process | Add-Member -MemberType ScriptProperty -Name CommandLine -Value {
            $script:CommandLineReads++
            $script:CommandLines[$this.Id]
        }
    }
    $process
}

function Set-FixtureProcesses {
    param([object[]]$Processes = @())
    $script:FakeProcesses = @($Processes)
    $script:LivePids = @{}
    foreach ($process in $script:FakeProcesses) { $script:LivePids[[int]$process.Id] = $true }
    # Every test starts from a cold cache unless it is deliberately measuring it.
    $script:BridgeAgentSessionIdCache = @{}
    $script:CommandLineReads = 0
}

function Get-BridgeAgentProcesses { param([string]$Agent) @($script:FakeProcesses) }
function Get-BridgeCommandLine { param([int]$ProcessId) $script:CommandLineReads++; [string]$script:CommandLines[$ProcessId] }
function Write-DaemonLog { param([string]$Message) }

# Only the pruning path calls this, and only for pids it did not just see.
function Get-Process {
    [CmdletBinding()]
    param([int]$Id, [string]$Name)
    # ProcessName matters: Get-CopilotSessionProcessId puts whatever a lock names
    # through Test-BridgeAgentProcess before typing into it.
    if ($script:LivePids.ContainsKey($Id)) { return [pscustomobject]@{ Id = $Id; ProcessName = 'copilot' } }
    $null
}

function New-CopilotCommandLine {
    param([Parameter(Mandatory)][string]$SessionId, [switch]$Equals)
    $separator = if ($Equals) { '=' } else { ' ' }
    'C:\copilot.exe --no-auto-update -C C:\repos --session-id' + $separator + $SessionId + ' --banner --allow-all'
}

$resumedId = 'acbcdc8b-a256-4602-95e2-d8f3aa04f943'
$freshId   = '9f6c92fb-a8df-4282-9ce6-25c2220d294c'
$otherId   = '11111111-2222-4333-8444-555555555555'

try {
    Write-Host '--- reading the session id off a command line ---'

    Set-FixtureProcesses @((New-FixtureProcess -Id 100 -CommandLine (New-CopilotCommandLine -SessionId $resumedId)))
    $ids = Get-BridgeAgentProcessSessionIds -Processes $script:FakeProcesses
    Test-That 'a process names the session it is working in' { $ids[100] -eq $resumedId }

    Set-FixtureProcesses @((New-FixtureProcess -Id 101 -CommandLine (New-CopilotCommandLine -SessionId $resumedId -Equals)))
    $ids = Get-BridgeAgentProcessSessionIds -Processes $script:FakeProcesses
    Test-That 'and does so spelled --session-id=<id> as well' { $ids[101] -eq $resumedId }

    Set-FixtureProcesses @((New-FixtureProcess -Id 102 -CommandLine 'C:\copilot.exe --banner --allow-all'))
    $ids = Get-BridgeAgentProcessSessionIds -Processes $script:FakeProcesses
    Test-That 'a process without one is simply absent' { -not $ids.ContainsKey(102) }

    Set-FixtureProcesses @((New-FixtureProcess -Id 103 -CommandLine 'C:\copilot.exe --resume my-feature --session-id notauuid'))
    $ids = Get-BridgeAgentProcessSessionIds -Processes $script:FakeProcesses
    Test-That 'a name or a prefix is not mistaken for an id' { -not $ids.ContainsKey(103) }

    Set-FixtureProcesses @((New-FixtureProcess -Id 104 -CommandLine (New-CopilotCommandLine -SessionId $resumedId) -NoCommandLineProperty))
    $ids = Get-BridgeAgentProcessSessionIds -Processes $script:FakeProcesses
    Test-That 'a platform with no CommandLine property falls back to asking the OS' { $ids[104] -eq $resumedId }

    Write-Host "`n--- the command line is read once, not every pass ---"

    Set-FixtureProcesses @((New-FixtureProcess -Id 105 -CommandLine (New-CopilotCommandLine -SessionId $resumedId)))
    $null = Get-BridgeAgentProcessSessionIds -Processes $script:FakeProcesses
    $afterFirst = $script:CommandLineReads
    for ($i = 0; $i -lt 5; $i++) { $null = Get-BridgeAgentProcessSessionIds -Processes $script:FakeProcesses }
    Test-That 'six passes over the same process read it once' {
        $afterFirst -eq 1 -and $script:CommandLineReads -eq 1
    } "first: $afterFirst, total: $($script:CommandLineReads)"

    # A pid is reused. Keyed on the pid alone, the dead process's session would be
    # served for as long as the daemon ran.
    $script:CommandLines[105] = New-CopilotCommandLine -SessionId $otherId
    $recycled = New-FixtureProcess -Id 105 -CommandLine (New-CopilotCommandLine -SessionId $otherId) -StartedTicksOffset 500
    $script:FakeProcesses = @($recycled)
    $script:LivePids = @{ 105 = $true }
    $ids = Get-BridgeAgentProcessSessionIds -Processes $script:FakeProcesses
    Test-That 'a recycled pid is not served the dead process''s session' { $ids[105] -eq $otherId }

    Write-Host "`n--- the cache does not grow without bound ---"

    Set-FixtureProcesses @((New-FixtureProcess -Id 106 -CommandLine (New-CopilotCommandLine -SessionId $resumedId)))
    $null = Get-BridgeAgentProcessSessionIds -Processes $script:FakeProcesses
    $populated = $script:BridgeAgentSessionIdCache.Count
    # The process goes, and is no longer among the live pids.
    $script:FakeProcesses = @()
    $script:LivePids = @{}
    $null = Get-BridgeAgentProcessSessionIds -Processes @()
    Test-That 'a process that has gone takes its entry with it' {
        $populated -eq 1 -and $script:BridgeAgentSessionIdCache.Count -eq 0
    } "populated: $populated, after: $($script:BridgeAgentSessionIdCache.Count)"

    Set-FixtureProcesses @((New-FixtureProcess -Id 107 -CommandLine (New-CopilotCommandLine -SessionId $resumedId)))
    $null = Get-BridgeAgentProcessSessionIds -Processes $script:FakeProcesses
    # Asked about a different agent's processes, with 107 still running.
    $null = Get-BridgeAgentProcessSessionIds -Processes @()
    Test-That 'but one still running is kept, even when a caller asks about another agent' {
        $script:BridgeAgentSessionIdCache.Count -eq 1
    } "count: $($script:BridgeAgentSessionIdCache.Count)"

    Write-Host "`n--- discovering live sessions ---"

    Get-ChildItem -LiteralPath $root -Directory | Remove-Item -Recurse -Force
    $null = New-FixtureSession -Id $resumedId -WithTranscript
    Set-FixtureProcesses @((New-FixtureProcess -Id 200 -CommandLine (New-CopilotCommandLine -SessionId $resumedId)))
    $live = Get-LiveCopilotSessions
    Test-That 'a resumed session with no lock of its own is found' {
        $live.ContainsKey($resumedId) -and $live[$resumedId].ProcessId -eq 200
    } "keys: $(@($live.Keys) -join ',')"
    Test-That 'and is reported as a Copilot session with its transcript' {
        $live[$resumedId].Kind -eq 'copilot' -and $live[$resumedId].HasTranscript
    }

    Get-ChildItem -LiteralPath $root -Directory | Remove-Item -Recurse -Force
    $null = New-FixtureSession -Id $freshId -LockPids 201 -WithTranscript
    Set-FixtureProcesses @((New-FixtureProcess -Id 201 -CommandLine (New-CopilotCommandLine -SessionId $freshId)))
    $live = Get-LiveCopilotSessions
    Test-That 'a freshly launched session is still found by its lock' {
        $live.ContainsKey($freshId) -and $live[$freshId].ProcessId -eq 201
    } "keys: $(@($live.Keys) -join ',')"

    Get-ChildItem -LiteralPath $root -Directory | Remove-Item -Recurse -Force
    $null = New-FixtureSession -Id $freshId -LockPids 202 -WithTranscript
    Set-FixtureProcesses @((New-FixtureProcess -Id 202 -NoCommandLineProperty))
    $script:CommandLines[202] = ''
    $live = Get-LiveCopilotSessions
    Test-That 'a process whose command line cannot be read still falls back to the lock' {
        $live.ContainsKey($freshId)
    } "keys: $(@($live.Keys) -join ',')"

    # The stale lock the CLI leaves behind: the same pid appears under two session
    # directories, and only the command line says which one it is really in.
    Get-ChildItem -LiteralPath $root -Directory | Remove-Item -Recurse -Force
    $null = New-FixtureSession -Id $otherId -LockPids 203 -WithTranscript -TranscriptAgeMinutes 0
    $null = New-FixtureSession -Id $resumedId -LockPids 203 -WithTranscript -TranscriptAgeMinutes 30
    Set-FixtureProcesses @((New-FixtureProcess -Id 203 -CommandLine (New-CopilotCommandLine -SessionId $resumedId)))
    $live = Get-LiveCopilotSessions
    Test-That 'the command line, not the newest transcript, decides which session a pid is in' {
        $live.Count -eq 1 -and $live.ContainsKey($resumedId)
    } "keys: $(@($live.Keys) -join ',')"

    Get-ChildItem -LiteralPath $root -Directory | Remove-Item -Recurse -Force
    $null = New-FixtureSession -Id $otherId -LockPids 204 -WithTranscript -TranscriptAgeMinutes 0
    $null = New-FixtureSession -Id $resumedId -LockPids 204 -WithTranscript -TranscriptAgeMinutes 30
    Set-FixtureProcesses @((New-FixtureProcess -Id 204 -NoCommandLineProperty))
    $script:CommandLines[204] = ''
    $live = Get-LiveCopilotSessions
    Test-That 'without one, the newest transcript still breaks the tie as before' {
        $live.Count -eq 1 -and $live.ContainsKey($otherId)
    } "keys: $(@($live.Keys) -join ',')"

    Get-ChildItem -LiteralPath $root -Directory | Remove-Item -Recurse -Force
    Set-FixtureProcesses @((New-FixtureProcess -Id 205 -CommandLine (New-CopilotCommandLine -SessionId $resumedId)))
    $live = Get-LiveCopilotSessions
    Test-That 'a session whose state directory has been cleaned away is not invented' { $live.Count -eq 0 }

    Get-ChildItem -LiteralPath $root -Directory | Remove-Item -Recurse -Force
    $null = New-FixtureSession -Id $resumedId -WithTranscript
    Set-FixtureProcesses @()
    $live = Get-LiveCopilotSessions
    Test-That 'nothing is live when no Copilot process is running' { $live.Count -eq 0 }

    # Both presses of Resume landed on the same session, which is one session.
    Get-ChildItem -LiteralPath $root -Directory | Remove-Item -Recurse -Force
    $null = New-FixtureSession -Id $resumedId -WithTranscript
    Set-FixtureProcesses @(
        (New-FixtureProcess -Id 206 -CommandLine (New-CopilotCommandLine -SessionId $resumedId)),
        (New-FixtureProcess -Id 207 -CommandLine (New-CopilotCommandLine -SessionId $resumedId))
    )
    $live = Get-LiveCopilotSessions
    Test-That 'two CLIs on one transcript are reported as the one session they share' {
        $live.Count -eq 1 -and $live.ContainsKey($resumedId)
    } "keys: $(@($live.Keys) -join ',')"

    Write-Host "`n--- a launch counts as registered ---"

    Get-ChildItem -LiteralPath $root -Directory | Remove-Item -Recurse -Force
    $null = New-FixtureSession -Id $resumedId -WithTranscript
    Set-FixtureProcesses @((New-FixtureProcess -Id 300 -CommandLine (New-CopilotCommandLine -SessionId $resumedId)))
    Test-That 'a resume registers, where only a lock would never have' {
        (Get-BridgeRegisteredSessionId -SessionId $resumedId -Launcher 'copilot') -eq $resumedId
    }
    Test-That 'and Test-BridgeSessionRegistered agrees' {
        Test-BridgeSessionRegistered -SessionId $resumedId -Launcher 'copilot'
    }

    Get-ChildItem -LiteralPath $root -Directory | Remove-Item -Recurse -Force
    $null = New-FixtureSession -Id $freshId -LockPids 301 -WithTranscript
    Set-FixtureProcesses @((New-FixtureProcess -Id 301 -CommandLine (New-CopilotCommandLine -SessionId $freshId)))
    Test-That 'a fresh launch still registers by its lock' {
        (Get-BridgeRegisteredSessionId -SessionId $freshId -Launcher 'copilot') -eq $freshId
    }

    Get-ChildItem -LiteralPath $root -Directory | Remove-Item -Recurse -Force
    $null = New-FixtureSession -Id $freshId -LockPids 302 -WithTranscript
    Set-FixtureProcesses @((New-FixtureProcess -Id 303 -CommandLine (New-CopilotCommandLine -SessionId $otherId)))
    Test-That 'a dead lock and an unrelated process is not registered' {
        (Get-BridgeRegisteredSessionId -SessionId $freshId -Launcher 'copilot') -eq ''
    }

    Write-Host "`n--- the process a reply is typed into ---"

    Get-ChildItem -LiteralPath $root -Directory | Remove-Item -Recurse -Force
    $null = New-FixtureSession -Id $resumedId -WithTranscript
    Set-FixtureProcesses @((New-FixtureProcess -Id 400 -CommandLine (New-CopilotCommandLine -SessionId $resumedId)))
    Test-That 'a resumed session with no lock still resolves the process to type into' {
        (Get-CopilotSessionProcessId -SessionId $resumedId) -eq 400
    } "got: $(Get-CopilotSessionProcessId -SessionId $resumedId)"

    Get-ChildItem -LiteralPath $root -Directory | Remove-Item -Recurse -Force
    $null = New-FixtureSession -Id $freshId -LockPids 401 -WithTranscript
    Set-FixtureProcesses @((New-FixtureProcess -Id 401 -CommandLine (New-CopilotCommandLine -SessionId $freshId)))
    Test-That 'a lock is still what settles it when there is one' {
        (Get-CopilotSessionProcessId -SessionId $freshId) -eq 401
    }

    Get-ChildItem -LiteralPath $root -Directory | Remove-Item -Recurse -Force
    $null = New-FixtureSession -Id $freshId -LockPids 402 -WithTranscript
    Set-FixtureProcesses @((New-FixtureProcess -Id 403 -CommandLine (New-CopilotCommandLine -SessionId $otherId)))
    Test-That 'a session no live CLI is in resolves no process at all' {
        $null -eq (Get-CopilotSessionProcessId -SessionId $freshId)
    } "got: $(Get-CopilotSessionProcessId -SessionId $freshId)"

    # The reason the command line has to be asked before the locks rather than after
    # them. A CLI resumed onto another session leaves its `inuse.<pid>.lock` behind in
    # the directory it came from, and that pid is still alive and still `copilot` - so
    # every guard the lock path applies is satisfied and the reply was typed into
    # whichever session that process moved to. Get-LiveCopilotSessions already resolves
    # this ambiguity command-line-first; a reply that disagreed with the card would be
    # delivered to a session the user was not looking at, with nothing logged.
    Get-ChildItem -LiteralPath $root -Directory | Remove-Item -Recurse -Force
    $null = New-FixtureSession -Id $freshId -LockPids 500 -WithTranscript
    $null = New-FixtureSession -Id $otherId -WithTranscript
    Set-FixtureProcesses @((New-FixtureProcess -Id 500 -CommandLine (New-CopilotCommandLine -SessionId $otherId)))
    Test-That 'a lock left behind by a CLI that resumed another session does not capture the reply' {
        $null -eq (Get-CopilotSessionProcessId -SessionId $freshId)
    } "got: $(Get-CopilotSessionProcessId -SessionId $freshId)"

    Test-That 'and the session that CLI actually moved to still resolves to it' {
        (Get-CopilotSessionProcessId -SessionId $otherId) -eq 500
    } "got: $(Get-CopilotSessionProcessId -SessionId $otherId)"

    # The lock is still the answer for a process the command line cannot speak for,
    # which is what keeps the pre-existing lock path working rather than replacing it.
    Get-ChildItem -LiteralPath $root -Directory | Remove-Item -Recurse -Force
    $null = New-FixtureSession -Id $freshId -LockPids 501 -WithTranscript
    Set-FixtureProcesses @((New-FixtureProcess -Id 501 -NoCommandLineProperty))
    Test-That 'a lock still settles it when that process has no readable session id' {
        (Get-CopilotSessionProcessId -SessionId $freshId) -eq 501
    } "got: $(Get-CopilotSessionProcessId -SessionId $freshId)"

    # The injector's own guard. $processId would be the [int]$ProcessId parameter -
    # PowerShell matches names case-insensitively - so a missing pid was stored as 0,
    # the guard never fired, and AttachConsole(0) returned "attach-failed:1341". Every
    # reply to a resumed session failed that way until the CLI wrote its lock.
    $script:SentTo = @()
    function Invoke-BridgeConsoleSend {
        param([int]$ProcessId, [string]$Text, [bool]$Submit = $true, [int]$DelayMs = 0)
        $script:SentTo += $ProcessId
        'ok:' + $Text.Length
    }
    function Invoke-BridgeConsoleChoice {
        param([int]$ProcessId, [int]$DownCount, [string]$Text, [int]$StepDelayMs = 0)
        $script:SentTo += $ProcessId
        'ok:choice'
    }

    Get-ChildItem -LiteralPath $root -Directory | Remove-Item -Recurse -Force
    $null = New-FixtureSession -Id $freshId -LockPids 404 -WithTranscript
    Set-FixtureProcesses @((New-FixtureProcess -Id 405 -CommandLine (New-CopilotCommandLine -SessionId $otherId)))
    $script:SentTo = @()
    $refused = Send-CopilotSessionPrompt -SessionId $freshId -Text 'are you there?'
    Test-That 'a reply to a session with no live process is refused, not typed into pid 0' {
        -not $refused.Delivered -and $refused.Detail -eq 'no live process for session' -and $script:SentTo.Count -eq 0
    } "delivered: $($refused.Delivered), detail: '$($refused.Detail)', sent to: $($script:SentTo -join ',')"

    $script:SentTo = @()
    $refusedChoice = Send-CopilotSessionChoice -SessionId $freshId -Text 'yes' -ChoiceCount 2
    Test-That 'and so is an answer to a question it asked' {
        -not $refusedChoice.Delivered -and $refusedChoice.Detail -eq 'no live process for session' -and $script:SentTo.Count -eq 0
    } "delivered: $($refusedChoice.Delivered), detail: '$($refusedChoice.Detail)', sent to: $($script:SentTo -join ',')"

    Get-ChildItem -LiteralPath $root -Directory | Remove-Item -Recurse -Force
    $null = New-FixtureSession -Id $resumedId -WithTranscript
    Set-FixtureProcesses @((New-FixtureProcess -Id 406 -CommandLine (New-CopilotCommandLine -SessionId $resumedId)))
    $script:SentTo = @()
    $delivered = Send-CopilotSessionPrompt -SessionId $resumedId -Text 'hello'
    Test-That 'a reply to a resumed session reaches the CLI its command line names' {
        $delivered.Delivered -and $delivered.ProcessId -eq 406 -and $script:SentTo -contains 406
    } "delivered: $($delivered.Delivered), pid: $($delivered.ProcessId), sent to: $($script:SentTo -join ',')"

    $script:SentTo = @()
    $explicit = Send-CopilotSessionPrompt -SessionId $resumedId -Text 'hello' -ProcessId 999
    Test-That 'an explicitly named process still overrides what the session resolves to' {
        $explicit.Delivered -and $script:SentTo -contains 999
    } "sent to: $($script:SentTo -join ',')"
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "$script:Failures check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
