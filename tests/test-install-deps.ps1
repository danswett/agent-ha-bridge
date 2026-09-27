#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the installer's dependency offers and PATH handling.

.DESCRIPTION
    The installer used to stop dead on a missing prerequisite - PowerShell 7 above all,
    which is the one you hit before anything else has a chance to help you. It now
    offers to install what it needs, and puts an `agent-ha-bridge` command on PATH so
    the install can be changed later without the repository.

    Both are things you cannot safely test by running them: nothing here may install a
    package or touch the real user PATH. So the decisions are pure functions with
    injectable probes, prompts and runners, and these drive every branch of them.

    install.ps1 is dot-sourced with BRIDGE_INSTALL_NORUN set so its functions load
    without running the install.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

Write-Host '--- the dependency catalogue ---'
if ($script:BridgeIsWindows) {
    Test-That 'PowerShell 7 installs from winget' {
        (Get-BridgeDependencyCommand -Name 'pwsh') -match '^winget install --id Microsoft\.PowerShell\b'
    }
    Test-That 'Node installs the LTS package' {
        (Get-BridgeDependencyCommand -Name 'node') -match '--id OpenJS\.NodeJS\.LTS\b'
    }
    Test-That 'winget commands accept the agreements, so they never sit at a prompt' {
        (Get-BridgeDependencyCommand -Name 'pwsh') -match '--accept-package-agreements' -and
        (Get-BridgeDependencyCommand -Name 'pwsh') -match '--accept-source-agreements'
    }
}
else {
    Test-That 'on macOS Node installs from Homebrew' { (Get-BridgeDependencyCommand -Name 'node') -eq 'brew install node' }
    Test-That 'and so does PowerShell' { (Get-BridgeDependencyCommand -Name 'pwsh') -eq 'brew install powershell' }
}
Test-That 'tmux installs from Homebrew' { (Get-BridgeDependencyCommand -Name 'tmux') -eq 'brew install tmux' }
Test-That 'the Copilot CLI is the published npm package' {
    (Get-BridgeDependencyCommand -Name 'copilot') -eq 'npm install -g @github/copilot'
}
Test-That 'Claude Code is the published npm package' {
    (Get-BridgeDependencyCommand -Name 'claude') -eq 'npm install -g @anthropic-ai/claude-code'
}
Test-That 'Codex CLI is the published npm package' {
    (Get-BridgeDependencyCommand -Name 'codex') -eq 'npm install -g @openai/codex'
}
Test-That 'an unknown dependency throws' {
    $threw = $false
    try { Get-BridgeDependencyCommand -Name 'emacs' } catch { $threw = $true }
    $threw
}
Test-That 'every client the picker offers can be installed, except the MCP server' {
    $installable = @($script:KnownClients | Where-Object { $_ -ne 'mcp' })
    @($installable | Where-Object { -not $script:BridgeDependencies.Contains($_) }).Count -eq 0
}
Test-That 'every catalogue entry has a label and a resolvable command' {
    $bad = @($script:BridgeDependencies.Keys | Where-Object {
        -not $script:BridgeDependencies[$_].Label -or -not (Get-BridgeDependencyCommand -Name $_)
    })
    $bad.Count -eq 0
}

Write-Host '--- Request-BridgeDependency never installs anything it should not ---'
# A shared mutable record keeps the scriptblocks trivial and the assertions direct.
function New-DependencyHarness {
    param([bool]$Present = $false, [bool]$Answer = $true, [bool]$RunSucceeds = $true, [bool]$ManagerAvailable = $true)
    $record = [pscustomobject]@{
        Present = $Present; Answer = $Answer; RunSucceeds = $RunSucceeds
        ManagerAvailable = $ManagerAvailable
        Asked = 0; Ran = 0; Command = ''; Prompt = ''
    }
    $record | Add-Member -NotePropertyName Probe -NotePropertyValue {
        param($name) $record.Present
    }.GetNewClosure()
    $record | Add-Member -NotePropertyName Ask -NotePropertyValue {
        param($prompt) $record.Asked++; $record.Prompt = $prompt; $record.Answer
    }.GetNewClosure()
    $record | Add-Member -NotePropertyName Runner -NotePropertyValue {
        param($command)
        $record.Ran++
        $record.Command = $command
        if ($record.RunSucceeds) { $record.Present = $true }
        $record.RunSucceeds
    }.GetNewClosure()
    $record | Add-Member -NotePropertyName ManagerProbe -NotePropertyValue {
        param($manager) $record.ManagerAvailable
    }.GetNewClosure()
    $record
}

function Invoke-Request {
    param([pscustomobject]$Harness, [string]$Name = 'node', [switch]$NonInteractive)
    Request-BridgeDependency -Name $Name -Probe $Harness.Probe -Ask $Harness.Ask `
        -Runner $Harness.Runner -ManagerProbe $Harness.ManagerProbe -NonInteractive:$NonInteractive
}

$h = New-DependencyHarness -Present $true
$outcome = Invoke-Request -Harness $h 6>$null
Test-That 'an installed dependency reports Present' { $outcome -eq 'Present' }
Test-That 'it does not ask about something already installed' { $h.Asked -eq 0 }
Test-That 'it does not run anything for something already installed' { $h.Ran -eq 0 }

$h = New-DependencyHarness
$outcome = Invoke-Request -Harness $h -NonInteractive 6>$null 3>$null
Test-That 'a non-interactive run reports Skipped' { $outcome -eq 'Skipped' }
Test-That 'a non-interactive run never prompts' { $h.Asked -eq 0 }
Test-That 'a non-interactive run never installs' { $h.Ran -eq 0 }

$h = New-DependencyHarness -Answer $false
$outcome = Invoke-Request -Harness $h 6>$null
Test-That 'declining reports Declined' { $outcome -eq 'Declined' }
Test-That 'declining asks exactly once' { $h.Asked -eq 1 }
Test-That 'declining installs nothing' { $h.Ran -eq 0 }

$h = New-DependencyHarness
$outcome = Invoke-Request -Harness $h 6>$null
Test-That 'accepting reports Installed' { $outcome -eq 'Installed' }
Test-That 'accepting runs the install once' { $h.Ran -eq 1 }
Test-That 'the runner is handed the catalogue command verbatim' {
    $h.Command -eq (Get-BridgeDependencyCommand -Name 'node')
}
Test-That 'the prompt names what is being installed' { $h.Prompt -match 'Node\.js' }

$h = New-DependencyHarness -RunSucceeds $false
$outcome = Invoke-Request -Harness $h 6>$null 3>$null
Test-That 'a failed install reports Failed' { $outcome -eq 'Failed' }

$h = New-DependencyHarness -ManagerAvailable $false
$outcome = Invoke-Request -Harness $h 6>$null 3>$null
Test-That 'a missing package manager reports Unavailable' { $outcome -eq 'Unavailable' }
Test-That 'a missing package manager is never prompted about' { $h.Asked -eq 0 }
Test-That 'a missing package manager installs nothing' { $h.Ran -eq 0 }

Test-That 'each agent CLI resolves its own command' {
    $seen = @()
    foreach ($client in @('copilot', 'claude', 'codex')) {
        $harness = New-DependencyHarness
        [void](Invoke-Request -Harness $harness -Name $client 6>$null)
        $seen += $harness.Command
    }
    ($seen -join '|') -eq ('npm install -g @github/copilot|npm install -g @anthropic-ai/claude-code|' +
                           'npm install -g @openai/codex')
}

Write-Host '--- PATH entries ---'
Test-That 'a directory is appended to an existing PATH' {
    (Add-BridgePathEntry -Current 'C:\a;C:\b' -Directory 'C:\bin') -eq 'C:\a;C:\b;C:\bin'
}
Test-That 'an empty PATH becomes just the directory' {
    (Add-BridgePathEntry -Current '' -Directory 'C:\bin') -eq 'C:\bin'
}
Test-That 'a null PATH is handled' {
    (Add-BridgePathEntry -Current $null -Directory 'C:\bin') -eq 'C:\bin'
}
Test-That 'an existing entry already present is not added again' {
    $null -eq (Add-BridgePathEntry -Current 'C:\a;C:\bin' -Directory 'C:\bin')
}
Test-That 'the match ignores case' {
    $null -eq (Add-BridgePathEntry -Current 'C:\A;C:\BIN' -Directory 'C:\bin')
}
Test-That 'the match ignores a trailing separator' {
    $null -eq (Add-BridgePathEntry -Current 'C:\a;C:\bin\' -Directory 'C:\bin')
}
Test-That 'the match ignores quoting' {
    $null -eq (Add-BridgePathEntry -Current 'C:\a;"C:\bin"' -Directory 'C:\bin')
}
Test-That 'removing takes the entry out' {
    (Remove-BridgePathEntry -Current 'C:\a;C:\bin;C:\b' -Directory 'C:\bin') -eq 'C:\a;C:\b'
}
Test-That 'removing an absent entry reports no change' {
    $null -eq (Remove-BridgePathEntry -Current 'C:\a;C:\b' -Directory 'C:\bin')
}
Test-That 'removing the only entry leaves an empty PATH' {
    (Remove-BridgePathEntry -Current 'C:\bin' -Directory 'C:\bin') -eq ''
}

Write-Host '--- an existing PATH is never quietly reformatted ---'
# A real user PATH ends with a separator far more often than not, and PowerShell's
# obvious implementation - split, drop the blanks, re-join - silently rewrites it.
# Uninstalling then hands back something subtly different from what was there.
Test-That 'an empty segment in the middle survives' {
    (Add-BridgePathEntry -Current 'C:\a;;C:\b' -Directory 'C:\bin') -eq 'C:\a;;C:\b;C:\bin'
}
Test-That 'a trailing separator survives, without producing a double one' {
    (Add-BridgePathEntry -Current 'C:\a;C:\b;' -Directory 'C:\bin') -eq 'C:\a;C:\b;C:\bin;'
}
Test-That 'removing keeps empty segments it did not put there' {
    (Remove-BridgePathEntry -Current 'C:\a;;C:\bin;C:\b' -Directory 'C:\bin') -eq 'C:\a;;C:\b'
}
foreach ($shape in @('C:\a;C:\b', 'C:\a;C:\b;', 'C:\a;;C:\b', ';C:\a', 'C:\a', 'C:\a;;;')) {
    Test-That "add then remove is an exact round trip for '$shape'" {
        $added = Add-BridgePathEntry -Current $shape -Directory 'C:\bridge\bin'
        (Remove-BridgePathEntry -Current $added -Directory 'C:\bridge\bin') -eq $shape
    }
}
Test-That 'a round trip from an empty PATH comes back empty' {
    $added = Add-BridgePathEntry -Current '' -Directory 'C:\bridge\bin'
    (Remove-BridgePathEntry -Current $added -Directory 'C:\bridge\bin') -eq ''
}

Write-Host '--- Register-BridgePathEntry, against a fake environment ---'
$script:FakePath = 'C:\Windows;C:\Windows\System32'
$getter = { $script:FakePath }
$setter = { param($value) $script:FakePath = $value }

Test-That 'adding reports that it changed something' {
    Register-BridgePathEntry -Directory 'C:\bridge\bin' -Getter $getter -Setter $setter
}
Test-That 'the new value was written through the setter' {
    $script:FakePath -eq 'C:\Windows;C:\Windows\System32;C:\bridge\bin'
}
Test-That 'adding again reports no change' {
    -not (Register-BridgePathEntry -Directory 'C:\bridge\bin' -Getter $getter -Setter $setter)
}
Test-That 'a no-op leaves the value untouched' {
    $script:FakePath -eq 'C:\Windows;C:\Windows\System32;C:\bridge\bin'
}
Test-That 'removing reports that it changed something' {
    Register-BridgePathEntry -Directory 'C:\bridge\bin' -Getter $getter -Setter $setter -Remove
}
Test-That 'the entry is gone afterwards' {
    $script:FakePath -eq 'C:\Windows;C:\Windows\System32'
}
Test-That 'removing again reports no change' {
    -not (Register-BridgePathEntry -Directory 'C:\bridge\bin' -Getter $getter -Setter $setter -Remove)
}

Write-Host '--- the real user PATH is only ever read here ---'
$before = Get-BridgeUserPath
Test-That 'the stored user PATH is readable' { $before -is [string] }
Test-That 'nothing in this suite changed the real user PATH' { (Get-BridgeUserPath) -eq $before }

Write-Host '--- relaunch argument forwarding ---'
Test-That 'a present switch is forwarded bare' {
    (ConvertTo-BridgeArgumentList -BoundParameters @{
        NonInteractive = [switch]$true
    }) -join ' ' -eq '-NonInteractive'
}
Test-That 'an absent switch is dropped' {
    @(ConvertTo-BridgeArgumentList -BoundParameters @{ SkipVerify = [switch]$false }).Count -eq 0
}
Test-That 'a value is forwarded as a separate argument' {
    (ConvertTo-BridgeArgumentList -BoundParameters @{
        HomeAssistantUrl = 'http://ha:8123'
    }) -join ' ' -eq '-HomeAssistantUrl http://ha:8123'
}
Test-That 'an array is comma-joined, the way -Clients accepts it' {
    (ConvertTo-BridgeArgumentList -BoundParameters @{
        Clients = @('copilot', 'claude')
    }) -join ' ' -eq '-Clients copilot,claude'
}
Test-That 'an excluded parameter is not forwarded' {
    @(ConvertTo-BridgeArgumentList -BoundParameters @{ Token = 'secret' } -Exclude @('Token')).Count -eq 0
}
Test-That 'a null value is dropped' {
    @(ConvertTo-BridgeArgumentList -BoundParameters @{ NotifyService = $null }).Count -eq 0
}
Test-That 'an empty value is dropped' {
    @(ConvertTo-BridgeArgumentList -BoundParameters @{ NotifyService = '' }).Count -eq 0
}

Write-Host '--- the entry points still parse on Windows PowerShell ---'
# The whole point of offering to install PowerShell 7 is that the offer runs where
# PowerShell 7 is absent. PowerShell parses an entire file before executing any of it,
# so one PS7-only construct anywhere in these two files turns the offer into a parse
# error - the exact failure it exists to prevent.
$winPs = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { '' }
if (-not $winPs -or -not (Test-Path -LiteralPath $winPs)) {
    Write-Host '  SKIP  Windows PowerShell is not present on this machine' -ForegroundColor Yellow
}
else {
    # install.ps1 loads the platform layer before it can offer PowerShell 7, so that
    # file has to parse there too.
    foreach ($name in @('install.ps1', 'bootstrap.ps1', 'hooks\bridge-platform.ps1')) {
        $target = (Resolve-Path (Join-Path $PSScriptRoot "..\$name")).Path
        Test-That "$name parses under Windows PowerShell 5.1" {
            $script = @"
`$errors = `$null
[void][System.Management.Automation.Language.Parser]::ParseFile('$target', [ref]`$null, [ref]`$errors)
if (`$errors -and `$errors.Count) { `$errors | ForEach-Object { `$_.Message }; exit 1 }
exit 0
"@
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
            $output = & $winPs -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1
            if ($LASTEXITCODE -ne 0) { throw ($output -join '; ') }
            $true
        }
    }
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
