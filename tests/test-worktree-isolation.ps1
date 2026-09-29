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
    Test-That 'it is under the configured root, which is what makes it the bridge''s to prune' {
        $first.Path.StartsWith($root)
    } "[$($first.Path)]"
    Test-That 'it is a real worktree of that repository' {
        @(Get-BridgeManagedWorktree -RepositoryPath $repo) -contains $first.Path
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
    # deliberately: everything else about them is already "finished".
    function Set-Aged { param([string]$Path, [double]$Hours) (Get-Item -LiteralPath $Path -Force).CreationTime = [datetime]::Now.AddHours(-$Hours) }

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
    Test-That 'the uncommitted ones are still there' { ($after -contains $dirty) -and ($after -contains $edited) }
    Test-That 'so is the unmerged branch' { $after -contains $branched }
    Test-That 'so is the detached commit' { $after -contains $committed }
    Test-That 'and the repository itself is never a candidate' { $after -notcontains $repo }

    Write-Host ''
    Write-Host '--- a session in a folder is left alone whatever git says about it ---'
    $busyWorktree = (New-BridgeSessionWorktree -RepositoryPath $repo).Path
        Set-Aged -Path $busyWorktree -Hours 48
        # Named distinctly on purpose. A stub's free variables are resolved in whatever
        # scope calls it, so a stub returning `$busy` would pick up a local called $busy
        # inside the function under test rather than this one - which is exactly what
        # happened, and it failed with "Hashtable does not contain a method named
        # TrimEnd" from deep inside the pruner.
        function Get-BridgeDiscoveredWorkspaces { @($busyWorktree) }
        Test-That 'a recently used worktree survives a prune' {
            (Remove-BridgeFinishedWorktree -RepositoryPath $repo -IdleHours 12) -eq 0 -and
            (@(Get-BridgeManagedWorktree -RepositoryPath $repo) -contains $busyWorktree)
        }
        function Get-BridgeDiscoveredWorkspaces { @() }

    Write-Host ''
    Write-Host '--- a launch is never blocked by any of this ---'
    $notRepo = Join-Path $sandbox 'plain'
    [void][System.IO.Directory]::CreateDirectory($notRepo)
    $plain = New-BridgeSessionWorktree -RepositoryPath $notRepo
    Test-That 'a workspace that is not a repository runs where it was told to' {
        -not $plain.Isolated -and $plain.Path -eq $notRepo
    }
    Test-That 'and says why' { $plain.Detail -match 'not a git repository' } "[$($plain.Detail)]"

    $capped = New-BridgeSessionWorktree -RepositoryPath $repo -Limit 1
    Test-That 'hitting the worktree limit falls back to the repository rather than failing' {
        -not $capped.Isolated -and $capped.Path -eq $repo
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
    Test-That 'while an ordinary discovered folder still is' {
        @($withDiscovery | Where-Object { $_.Path -eq $notRepo }).Count -eq 1
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
