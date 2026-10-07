#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the installer leaving a machine with a launch folder that exists.

.DESCRIPTION
    The launch card offers only configured directories that are present, which is the
    allowlist working as intended - but it means a config naming folders this machine
    does not have produces a card that says "No workspaces configured" and cannot be
    repaired from the dashboard. config.example.json ships ~/repos entries, so that was
    the default outcome on any machine keeping its code somewhere else.

    These cover the installer's side of that: checking the configured list against the
    disk, approving a real folder when none of it exists, repairing a default label
    that points at nothing, and refusing an explicit -Workspace that names a folder
    which is not there.

    Real directories under a disposable root throughout - existence is the whole
    question, so a stubbed Test-Path would prove nothing.

    install.ps1 is dot-sourced with BRIDGE_INSTALL_NORUN set so its functions load
    without running the install.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'runner-support.ps1')
Assert-BridgeTestEnvironment -Required

$env:BRIDGE_INSTALL_NORUN = '1'
. (Join-Path $PSScriptRoot '..\install.ps1')

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

$script:Root = Join-Path ([System.IO.Path]::GetTempPath()) "bridge-ws-$([guid]::NewGuid().ToString('N'))"
$script:FakeHome = Join-Path $script:Root 'home'
New-Item -ItemType Directory -Path $script:FakeHome -Force | Out-Null
$script:Repos = Join-Path $script:FakeHome 'repos'
New-Item -ItemType Directory -Path $script:Repos -Force | Out-Null
$script:Bridge = Join-Path $script:Repos 'agent-ha-bridge'
New-Item -ItemType Directory -Path $script:Bridge -Force | Out-Null
# A home with no conventional code root at all, which is the machine the bug was
# reported on: the shipped template named folders that were simply not there.
$script:BareHome = Join-Path $script:Root 'bare'
New-Item -ItemType Directory -Path $script:BareHome -Force | Out-Null
$script:Missing = Join-Path $script:Root 'gone'

function Invoke-CardCheck {
    <#
        Runs the daemon's real Get-BridgeWorkspaceChoices and
        Get-BridgeDefaultWorkspaceLabel over a config the installer would write, in a
        child process so the hook stack cannot be influenced by the installer functions
        dot-sourced here.

        This is what stops the two sides drifting. The installer decides whether an
        entry will be offered and what label it will carry; the card decides the same
        things independently, and a disagreement is invisible until a dashboard is
        empty or the default names a folder nobody is shown.
    #>
    param([Parameter(Mandatory)]$Plan)

    $configDir = Join-Path $script:Root "cfg-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    $configPath = Join-Path $configDir 'config.json'
    @{ newSession = @{
            workspaces         = @($Plan.Workspaces)
            defaultWorkspace   = $Plan.Default
            discoverWorkspaces = $false
    } } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding utf8

    $common = (Resolve-Path (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')).Path
    $launch = (Resolve-Path (Join-Path $PSScriptRoot '..\hooks\session-launch.ps1')).Path
    $scriptPath = Join-Path $configDir 'check.ps1'
    @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
. '$($common -replace "'", "''")'
. '$($launch -replace "'", "''")'
# The real reader, pointed at the config the installer would have written. Replacing
# the loaded config rather than Get-BridgeSetting keeps the function under test real.
`$script:BridgeUserConfig = Get-Content -LiteralPath '$($configPath -replace "'", "''")' -Raw |
    ConvertFrom-Json
`$choices = @(Get-BridgeWorkspaceChoices)
@{
    Labels  = @(`$choices | ForEach-Object { `$_.Label })
    Paths   = @(`$choices | ForEach-Object { `$_.Path })
    Default = [string](Get-BridgeDefaultWorkspaceLabel)
} | ConvertTo-Json -Depth 5 -Compress
"@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

    $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $scriptPath 2>&1
    if ($LASTEXITCODE -ne 0) { throw "card check failed: $($output -join "`n")" }
    ($output | Where-Object { "$_".TrimStart().StartsWith('{') } | Select-Object -Last 1) | ConvertFrom-Json
}

try {
    Write-Host '--- reading the configured list ---'
    Test-That 'expands ~ against the install home rather than the real one' {
        $e = @(ConvertTo-BridgeWorkspaceEntries -Workspaces @('~/repos') -HomePath $script:FakeHome)
        $e.Count -eq 1 -and $e[0].Exists -and $e[0].Path -eq ([System.IO.Path]::GetFullPath($script:Repos))
    }
    Test-That 'reports a configured folder that is not on this machine' {
        $e = @(ConvertTo-BridgeWorkspaceEntries -Workspaces @($script:Missing) -HomePath $script:FakeHome)
        $e.Count -eq 1 -and -not $e[0].Exists
    }
    Test-That 'labels a folder the way the launch card will' {
        $e = @(ConvertTo-BridgeWorkspaceEntries -Workspaces @($script:Bridge) -HomePath $script:FakeHome)
        $e[0].Label -eq 'agent-ha-bridge'
    }
    Test-That 'keeps an explicit label' {
        $e = @(ConvertTo-BridgeWorkspaceEntries -HomePath $script:FakeHome `
                -Workspaces @([pscustomobject]@{ label = 'Bridge'; path = $script:Bridge }))
        $e[0].Label -eq 'Bridge'
    }

    Write-Host '--- folders worth approving when the config names none ---'
    Test-That 'finds a conventional code root under the install home' {
        (Get-BridgeWorkspaceFallbacks -HomePath $script:FakeHome) -contains [System.IO.Path]::GetFullPath($script:Repos)
    }
    Test-That 'always ends with the home directory itself' {
        $f = @(Get-BridgeWorkspaceFallbacks -HomePath $script:FakeHome)
        $f[-1] -eq ([System.IO.Path]::GetFullPath($script:FakeHome).TrimEnd('\', '/'))
    }
    Test-That 'offers the home directory even when there is no code root at all' {
        $f = @(Get-BridgeWorkspaceFallbacks -HomePath $script:BareHome)
        $f.Count -eq 1 -and $f[0] -eq ([System.IO.Path]::GetFullPath($script:BareHome).TrimEnd('\', '/'))
    }
    Test-That 'lists each folder once, whatever the case of its name' {
        $f = @(Get-BridgeWorkspaceFallbacks -HomePath $script:FakeHome)
        $keys = @($f | ForEach-Object { $_.ToLowerInvariant() })
        $keys.Count -eq (@($keys | Select-Object -Unique).Count)
    }

    Write-Host '--- a config that already works is left alone ---'
    Test-That 'changes nothing when every configured folder is there' {
        $plan = Resolve-BridgeWorkspaceConfig -Configured @('~/repos') -Default 'repos' `
            -Fallbacks (Get-BridgeWorkspaceFallbacks -HomePath $script:FakeHome) -HomePath $script:FakeHome
        -not $plan.Changed -and $plan.Added.Count -eq 0 -and $plan.Workspaces[0] -eq '~/repos'
    }
    Test-That 'does not rewrite a portable ~ entry into an absolute path' {
        $plan = Resolve-BridgeWorkspaceConfig -Configured @('~/repos', '~/repos/agent-ha-bridge') `
            -Default 'repos' -HomePath $script:FakeHome
        ($plan.Workspaces -join '|') -eq '~/repos|~/repos/agent-ha-bridge'
    }
    Test-That 'keeps a missing folder on an upgrade and says so' {
        $plan = Resolve-BridgeWorkspaceConfig -Configured @('~/repos', $script:Missing) -Default 'repos' `
            -Fallbacks (Get-BridgeWorkspaceFallbacks -HomePath $script:FakeHome) -HomePath $script:FakeHome
        $plan.Missing.Count -eq 1 -and @($plan.Workspaces).Count -eq 2 -and $plan.Added.Count -eq 0
    }

    Write-Host '--- a machine the configured folders are not on ---'
    Test-That 'approves a real folder so the card has something to offer' {
        $plan = Resolve-BridgeWorkspaceConfig -Configured @('~/repos', '~/repos/agent-ha-bridge') `
            -Default 'Bridge' -Fallbacks (Get-BridgeWorkspaceFallbacks -HomePath $script:BareHome) `
            -HomePath $script:BareHome
        $plan.Changed -and $plan.Added -contains ([System.IO.Path]::GetFullPath($script:BareHome).TrimEnd('\', '/'))
    }
    Test-That 'points the default at a folder that is actually offered' {
        $plan = Resolve-BridgeWorkspaceConfig -Configured @('~/repos') -Default 'Bridge' `
            -Fallbacks (Get-BridgeWorkspaceFallbacks -HomePath $script:BareHome) -HomePath $script:BareHome
        $plan.Default -eq 'Home'
    }
    Test-That 'names the approved home directory Home rather than the user name' {
        $plan = Resolve-BridgeWorkspaceConfig -Configured @() `
            -Fallbacks (Get-BridgeWorkspaceFallbacks -HomePath $script:BareHome) -HomePath $script:BareHome
        $plan.Workspaces[0].label -eq 'Home'
    }
    Test-That 'drops the shipped template on a first install' {
        $plan = Resolve-BridgeWorkspaceConfig -Configured @('~/repos', '~/repos/agent-ha-bridge') `
            -Default 'Bridge' -Fallbacks (Get-BridgeWorkspaceFallbacks -HomePath $script:BareHome) `
            -HomePath $script:BareHome -FirstInstall
        $plan.Dropped.Count -eq 2 -and @($plan.Workspaces).Count -eq 1
    }
    Test-That 'approves nothing extra while one configured folder still exists' {
        $plan = Resolve-BridgeWorkspaceConfig -Configured @('~/repos', $script:Missing) -Default 'repos' `
            -Fallbacks (Get-BridgeWorkspaceFallbacks -HomePath $script:FakeHome) -HomePath $script:FakeHome
        $plan.Added.Count -eq 0
    }
    Test-That 'asks before approving anything when someone is watching' {
        $asked = $false
        $plan = Resolve-BridgeWorkspaceConfig -Configured @('~/repos') -HomePath $script:BareHome `
            -Fallbacks (Get-BridgeWorkspaceFallbacks -HomePath $script:BareHome) `
            -Prompt { param($Suggestions) $script:Asked = $true; @($script:Repos) }
        $asked = $script:Asked
        $asked -and $plan.Added -contains ([System.IO.Path]::GetFullPath($script:Repos))
    }
    Test-That 'falls back to the suggestions when the answer is empty' {
        $plan = Resolve-BridgeWorkspaceConfig -Configured @() -HomePath $script:BareHome `
            -Fallbacks (Get-BridgeWorkspaceFallbacks -HomePath $script:BareHome) -Prompt { @() }
        $plan.Added.Count -eq 1
    }

    Write-Host '--- an explicit -Workspace ---'
    Test-That 'replaces the configured list outright' {
        $plan = Resolve-BridgeWorkspaceConfig -Configured @('~/repos') -Default 'repos' `
            -Requested @($script:Bridge) -HomePath $script:FakeHome
        @($plan.Workspaces).Count -eq 1 -and $plan.Workspaces[0].path -eq ([System.IO.Path]::GetFullPath($script:Bridge))
    }
    # The installed command runs install.ps1 through `pwsh -File`, which hands every
    # argument over as one literal string - so several folders arrive comma-joined in a
    # single element, exactly as -Clients does. A space after the comma is worse than
    # useless: the second path binds positionally to -HomeAssistantUrl instead.
    Test-That 'splits several folders out of one comma-joined argument' {
        $plan = Resolve-BridgeWorkspaceConfig -Configured @() -HomePath $script:FakeHome `
            -Requested @("$script:Repos,$script:Bridge")
        @($plan.Workspaces).Count -eq 2
    }
    Test-That 'tolerates spaces around those commas' {
        $plan = Resolve-BridgeWorkspaceConfig -Configured @() -HomePath $script:FakeHome `
            -Requested @("$script:Repos , $script:Bridge")
        @($plan.Workspaces).Count -eq 2
    }
    Test-That 'still refuses a missing folder inside a comma-joined argument' {
        $threw = $false
        try {
            Resolve-BridgeWorkspaceConfig -Configured @() -HomePath $script:FakeHome `
                -Requested @("$script:Repos,$script:Missing")
        }
        catch { $threw = $_.Exception.Message -match 'does not exist' }
        $threw
    }
    Test-That 'refuses a folder that is not on this machine' {
        $threw = $false
        try {
            Resolve-BridgeWorkspaceConfig -Configured @('~/repos') -Requested @($script:Missing) -HomePath $script:FakeHome
        }
        catch { $threw = $_.Exception.Message -match 'does not exist' }
        $threw
    }
    Test-That 'refuses the whole request rather than approving the half that exists' {
        $threw = $false
        try {
            Resolve-BridgeWorkspaceConfig -Configured @() -HomePath $script:FakeHome `
                -Requested @($script:Repos, $script:Missing)
        }
        catch { $threw = $true }
        $threw
    }

    Write-Host '--- an entry the card rejects for a reason other than absence ---'
    # "isolate": "true" is the ordinary JSON slip, and Get-BridgeWorkspaceChoices drops
    # the whole entry over it. An installer that counted such an entry as usable would
    # see a working list where the card sees none: no fallback approved, a cheerful
    # success line, and a dashboard still saying "No workspaces configured" - with the
    # new message telling you to run a repair that changes nothing.
    $script:BadIsolate = @([pscustomobject]@{ label = 'Repos'; path = $script:Repos; isolate = 'true' })
    Test-That 'does not count a non-Boolean isolate entry as something to launch in' {
        $plan = Resolve-BridgeWorkspaceConfig -Configured $script:BadIsolate -Default 'Repos' `
            -Fallbacks (Get-BridgeWorkspaceFallbacks -HomePath $script:BareHome) -HomePath $script:BareHome
        $plan.Changed -and $plan.Added.Count -eq 1 -and $plan.Rejected -contains ([System.IO.Path]::GetFullPath($script:Repos))
    }
    Test-That 'keeps the operator''s broken entry rather than rewriting it' {
        $plan = Resolve-BridgeWorkspaceConfig -Configured $script:BadIsolate -Default 'Repos' `
            -Fallbacks (Get-BridgeWorkspaceFallbacks -HomePath $script:BareHome) -HomePath $script:BareHome
        @($plan.Workspaces | Where-Object { $_.PSObject.Properties['isolate'] }).Count -eq 1
    }
    Test-That 'a valid Boolean isolate is still offered' {
        $plan = Resolve-BridgeWorkspaceConfig -HomePath $script:FakeHome -Default 'Repos' `
            -Configured @([pscustomobject]@{ label = 'Repos'; path = $script:Repos; isolate = $true }) `
            -Fallbacks (Get-BridgeWorkspaceFallbacks -HomePath $script:FakeHome)
        $plan.Added.Count -eq 0 -and $plan.Rejected.Count -eq 0 -and -not $plan.Changed
    }
    Test-That 'the card really does reject it, which is why the installer must' {
        # Pins the parity rather than assuming it: if session-launch ever stopped
        # dropping these, the installer would be approving a fallback for nothing.
        $check = Invoke-CardCheck -Plan ([pscustomobject]@{
            Workspaces = $script:BadIsolate; Default = 'Repos'
        })
        @($check.Labels).Count -eq 0
    }
    Test-That 'and the repaired config gives that machine a card again' {
        $plan = Resolve-BridgeWorkspaceConfig -Configured $script:BadIsolate -Default 'Repos' `
            -Fallbacks (Get-BridgeWorkspaceFallbacks -HomePath $script:BareHome) -HomePath $script:BareHome
        $check = Invoke-CardCheck -Plan $plan
        @($check.Labels).Count -ge 1 -and @($check.Labels) -contains $check.Default
    }

    Write-Host '--- two folders sharing a label ---'
    # The card suffixes the second with its path, because a Home Assistant select
    # cannot show two identical options. defaultWorkspace is matched against those
    # labels, so reading a suffixed default as "no longer on the list" would silently
    # move the one-press Launch to the other directory.
    $script:DupA = Join-Path $script:Root 'dup\a\repos'
    $script:DupB = Join-Path $script:Root 'dup\b\repos'
    New-Item -ItemType Directory -Path $script:DupA, $script:DupB -Force | Out-Null
    $script:DupConfig = @($script:DupA, $script:DupB)
    $script:DupSuffixed = "repos ($([System.IO.Path]::GetFullPath($script:DupB)))"
    Test-That 'leaves a default naming the suffixed duplicate alone' {
        $plan = Resolve-BridgeWorkspaceConfig -Configured $script:DupConfig -Default $script:DupSuffixed `
            -HomePath $script:FakeHome -Fallbacks (Get-BridgeWorkspaceFallbacks -HomePath $script:FakeHome)
        $plan.Default -eq $script:DupSuffixed -and -not $plan.Changed
    }
    Test-That 'the card offers exactly that suffixed label' {
        $check = Invoke-CardCheck -Plan ([pscustomobject]@{
            Workspaces = $script:DupConfig; Default = $script:DupSuffixed
        })
        @($check.Labels) -contains $script:DupSuffixed -and $check.Default -eq $script:DupSuffixed
    }
    Test-That 'a default naming no offered label is still repaired' {
        $plan = Resolve-BridgeWorkspaceConfig -Configured $script:DupConfig -Default 'nothing-like-this' `
            -HomePath $script:FakeHome -Fallbacks (Get-BridgeWorkspaceFallbacks -HomePath $script:FakeHome)
        $plan.Changed -and $plan.Default -eq 'repos'
    }

    Write-Host '--- the shipped template against a machine without ~/repos ---'
    # The reported failure end to end: a clean install writes config.example.json, and
    # on a machine with no ~/repos every entry in it is invisible to the launch card.
    Test-That 'a first install from the example still leaves a usable card' {
        $example = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\config.example.json') -Raw |
            ConvertFrom-Json
        $plan = Resolve-BridgeWorkspaceConfig -Configured $example.newSession.workspaces `
            -Default ([string]$example.newSession.defaultWorkspace) `
            -Fallbacks (Get-BridgeWorkspaceFallbacks -HomePath $script:BareHome) `
            -HomePath $script:BareHome -FirstInstall
        $offered = @(ConvertTo-BridgeWorkspaceEntries -Workspaces $plan.Workspaces -HomePath $script:BareHome |
            Where-Object { $_.Exists })
        $offered.Count -ge 1 -and ($offered | ForEach-Object { $_.Label }) -contains $plan.Default
    }

    Write-Host '--- what the launch card itself makes of the written config ---'
    # The check above only asks the installer to grade its own homework. This one runs
    # the daemon's real chooser over the config the installer would write. If the two
    # ever derive a label differently, or disagree about what is offerable, the card
    # offers a folder the default does not name - the half-working state being fixed.
    $script:CardCheck = $null

    $script:BarePlan = Resolve-BridgeWorkspaceConfig -Configured @('~/repos', '~/repos/agent-ha-bridge') `
        -Default 'Bridge' -Fallbacks (Get-BridgeWorkspaceFallbacks -HomePath $script:BareHome) `
        -HomePath $script:BareHome -FirstInstall
    $script:CardCheck = Invoke-CardCheck -Plan $script:BarePlan

    Test-That 'the card offers at least one folder after the installer has run' {
        @($script:CardCheck.Labels).Count -ge 1
    }
    Test-That 'the card offers the folder the installer approved' {
        @($script:CardCheck.Paths) -contains ([System.IO.Path]::GetFullPath($script:BareHome).TrimEnd('\', '/'))
    }
    Test-That 'the card and the installer agree on the default label' {
        $script:CardCheck.Default -eq $script:BarePlan.Default -and
        @($script:CardCheck.Labels) -contains $script:CardCheck.Default
    }
    Test-That 'the shipped template alone would have offered nothing on this machine' {
        # The regression itself, stated as a fact about the example rather than about
        # the fix: without the installer's repair the card is empty here.
        $example = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\config.example.json') -Raw |
            ConvertFrom-Json
        $bare = Invoke-CardCheck -Plan ([pscustomobject]@{
            Workspaces = @($example.newSession.workspaces | ForEach-Object {
                if ($_ -is [string]) { $_ -replace '^~', $script:BareHome }
                else { [pscustomobject]@{ label = $_.label; path = ($_.path -replace '^~', $script:BareHome) } }
            })
            Default = [string]$example.newSession.defaultWorkspace
        })
        @($bare.Labels).Count -eq 0
    }
}
finally {
    Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0) {
    Write-Host "$script:Failures test(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'All workspace configuration tests passed.' -ForegroundColor Green
