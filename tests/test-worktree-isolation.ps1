#Requires -Version 7.0
<#
.SYNOPSIS
    Isolated workspaces: a git worktree per launch.

.DESCRIPTION
    A workspace marked `isolate` gives every fresh launch a worktree of its own, so
    two sessions in the same repository cannot move each other's HEAD.

    These run against a real temporary git repository rather than a stubbed `git`,
    because the things worth proving are things only git can answer: that a worktree
    really is separate, that a branch made in one leaves the others alone, and above
    all that pruning cannot reach work that has not been merged. A stub would only
    prove that the code calls the commands it calls.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\session-launch.ps1')

# This suite has no agent processes. The real process/registration matrix lives in
# test-p4-worktree-safety; unrelated developer sessions are outside this fixture.
function Get-Process {
    [CmdletBinding()]
    [OutputType([System.Diagnostics.Process], [object[]])]
    param([string[]]$Name = @(), [int[]]$Id = @())
    $own = Microsoft.PowerShell.Management\Get-Process -Id $PID
    if ($Id.Count -and $PID -notin $Id) { return @() }
    if ($Name.Count -and @($Name | Where-Object { $own.ProcessName -like $_ }).Count -eq 0) { return @() }
    $own
}

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $__ok = $false
    try { $__ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($__ok) { Write-Host "  PASS  $Name" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    Write-Host '  FAIL  git is required to test worktree isolation' -ForegroundColor Red
    exit 1
}

# --- a real repository with a real remote -----------------------------------------

$sandbox = Join-Path ([IO.Path]::GetTempPath()) "bridge-wt-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$origin = Join-Path $sandbox 'origin.git'
$repo = Join-Path $sandbox 'repo'
$root = Join-Path $sandbox 'wt'
[void][System.IO.Directory]::CreateDirectory($sandbox)

function Invoke-Git { param([string]$Directory, [string[]]$Arguments) & git -C $Directory @Arguments 2>&1 | Out-Null }

# Membership by directory name, because git reports a worktree by its real path and
# macOS reaches the temporary directory through a symlink - /var/... going in,
# /private/var/... coming back. The names here are unique (they carry a timestamp),
# so this compares what the assertions actually mean.
function Test-Listed {
    param([string[]]$List, [string]$Path)
    @($List | ForEach-Object { [System.IO.Path]::GetFileName($_.TrimEnd('\', '/')) }) -contains
        [System.IO.Path]::GetFileName($Path.TrimEnd('\', '/'))
}

& git init --bare --initial-branch=main $origin 2>&1 | Out-Null
& git clone $origin $repo 2>&1 | Out-Null
Invoke-Git $repo @('config', 'user.email', 'test@example.com')
Invoke-Git $repo @('config', 'user.name', 'Bridge Test')
Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'first' -Encoding UTF8
Invoke-Git $repo @('add', 'README.md')
Invoke-Git $repo @('commit', '-m', 'first')
Invoke-Git $repo @('push', '-u', 'origin', 'main')

# The settings the functions read. Overridden in-process so nothing touches the real
# install's config.
$script:TestSettings = @{
    'newSession.worktreeRoot'      = $root
    'newSession.worktreeLimit'     = 10
    'newSession.worktreeIdleHours' = 12
    'newSession.discoverWorkspaces' = $false
    'newSession.workspaces'        = @()
}
function Get-BridgeSetting {
    param([Parameter(Mandatory)][string]$Path, $Default = $null)
    if ($script:TestSettings.ContainsKey($Path)) { return $script:TestSettings[$Path] }
    $Default
}
# Nothing here should consult the machine's real session history.
function Get-BridgeDiscoveredWorkspaces { @() }

try {
    Write-Host '--- the remote default branch is found, not assumed to be main ---'
    Test-That 'origin/HEAD is what a worktree starts from' {
        (Get-BridgeRepositoryBaseRef -RepositoryPath $repo) -eq 'origin/main'
    } "[$(Get-BridgeRepositoryBaseRef -RepositoryPath $repo)]"

    Write-Host ''
    Write-Host '--- a launch gets a worktree of its own ---'
    $first = New-BridgeSessionWorktree -RepositoryPath $repo
    Test-That 'it reports the session is isolated' { $first.Isolated }
    Test-That 'the directory exists' { [System.IO.Directory]::Exists($first.Path) }
    Test-That 'it is physically under the configured worktree root' {
        Test-BridgeInstallDescendant -Path $first.Path -Root (Resolve-BridgeWorkspaceDirectory -Path $root)
    } "[$($first.Path)]"
    Test-That 'it is a real worktree of that repository' {
        Test-Listed -List @(Get-BridgeManagedWorktree -RepositoryPath $repo) -Path $first.Path
    }
    # The bug this pins down: identity used to be "is the path under the worktree
    # root", which is false on macOS the moment a symlinked path is involved - git
    # reports /private/var/... for a worktree created at /var/..., so no worktree was
    # ever recognised as the bridge's and nothing was ever pruned, silently. A marker
    # inside the worktree's git admin directory does not care how the path was spelled.
    Test-That 'recognised by its marker, not by how its path is spelled' {
        Test-BridgeManagedWorktree -Path $first.Path
    }
    Test-That 'the marker is outside the working tree, so the worktree stays clean' {
        (& git -C $first.Path --no-optional-locks status --porcelain | Out-String).Trim() -eq ''
    }
    Test-That 'the repository itself is never mistaken for one' {
        -not (Test-BridgeManagedWorktree -Path $repo)
    }
    Test-That 'nor is a worktree somebody made by hand' {
        $manual = Join-Path $sandbox 'by-hand'
        Invoke-Git $repo @('worktree', 'add', '--detach', $manual, 'origin/main')
        (Test-Path $manual) -and -not (Test-BridgeManagedWorktree -Path $manual) -and
            (-not (Test-Listed -List @(Get-BridgeManagedWorktree -RepositoryPath $repo) -Path $manual))
    }
    Test-That 'and it carries the repository content' { Test-Path (Join-Path $first.Path 'README.md') }

    $second = New-BridgeSessionWorktree -RepositoryPath $repo
    Test-That 'a second launch gets a different one' { $second.Isolated -and $second.Path -ne $first.Path }

    Write-Host ''
    Write-Host '--- which is the point: one session cannot move another''s HEAD ---'
    Invoke-Git $first.Path @('switch', '-c', 'feat/one')
    Test-That 'a branch in one worktree is checked out only there' {
        (& git -C $first.Path rev-parse --abbrev-ref HEAD).Trim() -eq 'feat/one'
    }
    Test-That 'the second worktree is untouched' {
        (& git -C $second.Path rev-parse --abbrev-ref HEAD).Trim() -eq 'HEAD'
    }
    Test-That 'and so is the repository itself' {
        (& git -C $repo rev-parse --abbrev-ref HEAD).Trim() -eq 'main'
    }

    Write-Host ''
    Write-Host '--- pruning cannot reach work ---'
    # Age is the only thing standing between these and removal, so they are aged
    # deliberately: everything else about them is already "finished". Written through
    # the marker the bridge itself reads, rather than by setting a filesystem
    # timestamp, so this means the same thing on every platform.
    function Set-Aged {
        param([string]$Path, [double]$Hours)
        $marker = Get-BridgeWorktreeMarkerPath -Path $Path
        [System.IO.File]::WriteAllText($marker, [DateTime]::Now.AddHours(-$Hours).ToString('o'))
    }

    $base = Get-BridgeRepositoryBaseRef -RepositoryPath $repo

    $dirty = (New-BridgeSessionWorktree -RepositoryPath $repo).Path
    Set-Content -LiteralPath (Join-Path $dirty 'scratch.txt') -Value 'unsaved work' -Encoding UTF8
    Set-Aged -Path $dirty -Hours 48
    Test-That 'an untracked file is enough to keep a worktree' {
        -not (Test-BridgeWorktreeFinished -WorktreePath $dirty -BaseRef $base -IdleHours 12)
    }

    $edited = (New-BridgeSessionWorktree -RepositoryPath $repo).Path
    Set-Content -LiteralPath (Join-Path $edited 'README.md') -Value 'edited' -Encoding UTF8
    Set-Aged -Path $edited -Hours 48
    Test-That 'so is an uncommitted edit' {
        -not (Test-BridgeWorktreeFinished -WorktreePath $edited -BaseRef $base -IdleHours 12)
    }

    $branched = (New-BridgeSessionWorktree -RepositoryPath $repo).Path
    Invoke-Git $branched @('switch', '-c', 'feat/unmerged')
    Set-Content -LiteralPath (Join-Path $branched 'feature.txt') -Value 'a feature' -Encoding UTF8
    Invoke-Git $branched @('add', 'feature.txt')
    Invoke-Git $branched @('commit', '-m', 'unmerged work')
    Set-Aged -Path $branched -Hours 48
    Test-That 'an unmerged branch is never finished, however old' {
        -not (Test-BridgeWorktreeFinished -WorktreePath $branched -BaseRef $base -IdleHours 12)
    }

    $committed = (New-BridgeSessionWorktree -RepositoryPath $repo).Path
    Set-Content -LiteralPath (Join-Path $committed 'detached.txt') -Value 'on a detached head' -Encoding UTF8
    Invoke-Git $committed @('add', 'detached.txt')
    Invoke-Git $committed @('commit', '-m', 'commit with no branch')
    Set-Aged -Path $committed -Hours 48
    # The easiest commit in git to lose, and the one a naive "is it clean?" check
    # would throw away without a word.
    Test-That 'nor is a commit made on a detached HEAD' {
        -not (Test-BridgeWorktreeFinished -WorktreePath $committed -BaseRef $base -IdleHours 12)
    }

    $fresh = (New-BridgeSessionWorktree -RepositoryPath $repo).Path
    Test-That 'a worktree just handed to a session is not finished either' {
        -not (Test-BridgeWorktreeFinished -WorktreePath $fresh -BaseRef $base -IdleHours 12)
    }
    Set-Aged -Path $fresh -Hours 48
    Test-That 'but once it is clean, detached and old, it is' {
        Test-BridgeWorktreeFinished -WorktreePath $fresh -BaseRef $base -IdleHours 12
    }

    Write-Host ''
    Write-Host '--- and pruning removes only those ---'
    $before = @(Get-BridgeManagedWorktree -RepositoryPath $repo).Count
    $removed = Remove-BridgeFinishedWorktree -RepositoryPath $repo -IdleHours 12
    $after = @(Get-BridgeManagedWorktree -RepositoryPath $repo)
    Test-That 'exactly the finished one went' { $removed -eq 1 -and $after.Count -eq ($before - 1) } "removed=$removed before=$before after=$($after.Count)"
    Test-That 'the uncommitted ones are still there' { (Test-Listed -List $after -Path $dirty) -and (Test-Listed -List $after -Path $edited) }
    Test-That 'so is the unmerged branch' { Test-Listed -List $after -Path $branched }
    Test-That 'so is the detached commit' { Test-Listed -List $after -Path $committed }
    Test-That 'and the repository itself is never a candidate' { -not (Test-Listed -List $after -Path $repo) }

    Write-Host ''
    Write-Host '--- a session in a folder is left alone whatever git says about it ---'
    $busyWorktree = (New-BridgeSessionWorktree -RepositoryPath $repo).Path
        Set-Aged -Path $busyWorktree -Hours 48
        # This is the caller's reported-usage control, not proof of the reader.
        # test-p4-worktree-safety exercises actual processes and registration files.
        $realUsage = ${function:Get-BridgeWorktreeUsage}
        try {
            $script:ReportedWorktree = $busyWorktree
            function Get-BridgeWorktreeUsage {
                [pscustomobject]@{ Known = $true; Directories = @($script:ReportedWorktree); Detail = '' }
            }
            Test-That 'a worktree reported in use survives cleanup' {
                (Remove-BridgeFinishedWorktree -RepositoryPath $repo -IdleHours 12) -eq 0 -and
                (Test-Listed -List @(Get-BridgeManagedWorktree -RepositoryPath $repo) -Path $busyWorktree)
            }
        }
        finally { ${function:Get-BridgeWorktreeUsage} = $realUsage }

    Write-Host ''
    Write-Host '--- requested isolation never falls back to the repository ---'
    $notRepo = Join-Path $sandbox 'plain'
    [void][System.IO.Directory]::CreateDirectory($notRepo)
    $plain = New-BridgeSessionWorktree -RepositoryPath $notRepo
    Test-That 'a non-repository cannot provide requested isolation or an executable fallback' {
        -not $plain.Isolated -and [string]::IsNullOrWhiteSpace($plain.Path)
    }
    Test-That 'and says why' { $plain.Detail -match 'not a git repository' } "[$($plain.Detail)]"

    $capped = New-BridgeSessionWorktree -RepositoryPath $repo -Limit 1
    Test-That 'hitting the worktree limit refuses an executable fallback' {
        -not $capped.Isolated -and [string]::IsNullOrWhiteSpace($capped.Path)
    }
    Test-That 'and says how to clear it' { $capped.Detail -match 'limit 1' } "[$($capped.Detail)]"

    Write-Host ''
    Write-Host '--- the dropdown ---'
    $script:TestSettings['newSession.workspaces'] = @(
        [pscustomobject]@{ label = 'Repo'; path = $repo; isolate = $true }
        [pscustomobject]@{ label = 'Plain'; path = $notRepo }
    )
    $choices = @(Get-BridgeWorkspaceChoices)
    Test-That 'an entry asking for isolation is marked' {
        (@($choices | Where-Object { $_.Label -eq 'Repo' })[0]).Isolate
    }
    Test-That 'one that does not is not' {
        -not (@($choices | Where-Object { $_.Label -eq 'Plain' })[0]).Isolate
    }
    Test-That 'the label still resolves to the repository, not to a worktree' {
        (Resolve-BridgeWorkspacePath -Label 'Repo') -eq $repo
    }
    Test-That 'and the whole entry can be looked up by label' {
        (Get-BridgeWorkspaceChoice -Label 'Repo').Path -eq $repo
    }
    Test-That 'an unknown label is still nothing at all' { $null -eq (Get-BridgeWorkspaceChoice -Label 'Nope') }

    # The bug this prevents: every isolated launch is a real session working in a real
    # folder, so discovery finds it, and the picker fills with one entry per session
    # ever started - on a phone, unusable within a day.
    function Get-BridgeDiscoveredWorkspaces { @($first.Path, $notRepo) }
    $withDiscovery = @(Get-BridgeWorkspaceChoices)
    Test-That 'a worktree the bridge made is never offered as a workspace of its own' {
        @($withDiscovery | Where-Object { $_.Path -eq $first.Path }).Count -eq 0
    } "[$(@($withDiscovery | ForEach-Object { $_.Label }) -join ', ')]"
    Test-That 'while an ordinary explicitly configured folder remains available' {
        @($withDiscovery | Where-Object { $_.Path -eq $notRepo }).Count -eq 1
    }

    Write-Host '--- the daemon is given no console to lose ---'
    # A console inherited from an interactive session outlives nothing: when the session
    # is disconnected, or the short-lived process that started the daemon exits, the
    # handle stops resolving and PowerShell throws on anything reaching console plumbing.
    # The first thing to hit it was this very feature - launching into an isolate
    # workspace - and the message named git rather than the console. Seen on two
    # machines, one running an unmodified release.
    $supervisorAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot '..\hooks\agent-bridge-supervisor.ps1'), [ref]$null, [ref]$null)
    $supervisorAssignments = @($supervisorAst.FindAll({
        param($node) $node -is [Management.Automation.Language.AssignmentStatementAst]
    }, $true) | ForEach-Object { $_.Extent.Text })

    Test-That 'the supervisor starts the daemon with CreateNoWindow' {
        @($supervisorAssignments | Where-Object { $_ -match '\$start\.CreateNoWindow\s*=\s*\$true' }).Count -eq 1
    }
    Test-That 'and not WindowStyle, which is ignored when UseShellExecute is false' {
        @($supervisorAssignments | Where-Object { $_ -match '\$start\.WindowStyle' }).Count -eq 0
    }
    Test-That 'while still avoiding ShellExecute, which would make a window of its own' {
        @($supervisorAssignments | Where-Object { $_ -match '\$start\.UseShellExecute\s*=\s*\$false' }).Count -eq 1
    }

    Test-That 'a lost console handle is reported as that, not as a repository problem' {
        # Thrown from `fetch` rather than the first `rev-parse`: that one runs before the
        # try, so a failure there escapes to the daemon's own catch and is reported
        # differently. The case being pinned here is the one actually observed.
        function Invoke-BridgeGit { param($Directory, $Arguments, $IndexFile)
            if (@($Arguments)[0] -eq 'rev-parse') { return [pscustomobject]@{ Ok = $true; Output = $repo; Code = 0 } }
            throw 'The Win32 internal error "The handle is invalid." 0x6 occurred while getting the console mode. Contact Microsoft Customer Support Services.' }
        try { $consoleRefusal = New-BridgeSessionWorktree -RepositoryPath $repo }
        finally { Remove-Item -Path Function:\Invoke-BridgeGit -ErrorAction SilentlyContinue }
        -not $consoleRefusal.Isolated -and
            $consoleRefusal.Detail -like '*lost its console handle*' -and
            $consoleRefusal.Detail -like '*agent-ha-bridge restart*'
    }
}
finally {
    function Get-BridgeDiscoveredWorkspaces { @() }
    try { [void](Invoke-BridgeGit -Directory $repo -Arguments @('worktree', 'prune')) } catch { }
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All isolated workspace checks passed' -ForegroundColor Green
