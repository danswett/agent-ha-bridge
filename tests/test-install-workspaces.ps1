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
    # the daemon's real Get-BridgeWorkspaceChoices and Get-BridgeDefaultWorkspaceLabel
    # over the config the installer would write, in a child process so the hook stack
    # cannot be influenced by the installer functions loaded here. If the two ever
    # derive a label differently, the card offers a folder the default does not name,
    # which is the half-working state being fixed.
    $script:CardCheck = $null
    function Invoke-CardCheck {
        param([Parameter(Mandatory)]$Plan)

        $configDir = Join-Path $script:Root "cfg-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        $configPath = Join-Path $configDir 'config.json'
        @{ newSession = @{
                workspaces        = @($Plan.Workspaces)
                defaultWorkspace  = $Plan.Default
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
