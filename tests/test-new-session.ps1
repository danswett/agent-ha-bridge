#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for launching a new Copilot CLI session from Home Assistant.

.DESCRIPTION
    The bridge used to be able only to attach to sessions someone had already
    started at a keyboard. These cover the pieces that let a dashboard button start
    one:

      * ConvertTo-BridgeArgumentString - Windows command-line quoting. Asserted by
        round-tripping through the real CommandLineToArgvW parser rather than by
        matching strings, because the prompt is free text typed on a phone and
        getting this wrong would split or mangle arguments.
      * Get-BridgeWorkspaceChoices / Resolve-BridgeWorkspacePath - the approved
        directory list, which is also the security boundary: a path from Home
        Assistant is never launched, only a label resolved against this list.
      * Get-BridgeNewSessionArguments - the command line itself, including that
        --allow-all-tools is opt-in.
      * Publish-CopilotMqttNewSession - the discovery payloads.
      * Sync-DaemonNewSession - press-timestamp semantics and refusal cases.

    Nothing here contacts Home Assistant or starts a real agent CLI: where the
    bridge talks to one over stdin and stdout, a small pwsh child stands in for it.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')

# Send this run's log lines to a throwaway file. Dot-sourcing the daemon brings its
# real log path with it, so without this a test run writes entries like
# "new session launched: started pid 4242" into the live daemon log, where they look
# exactly like real events during a later investigation.
$script:DaemonConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-new-session-$([guid]::NewGuid().ToString('N').Substring(0,8)).log"
$testLogFile = $script:DaemonConfig.LogFile

$headers = @{ Authorization = '******' }

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

# --- argument quoting, verified against the real parser --------------------------

Add-Type -Namespace BridgeTest -Name Cmd -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr CommandLineToArgvW(string lpCmdLine, out int pNumArgs);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr LocalFree(System.IntPtr hMem);
'@

function ConvertFrom-CommandLine {
    <#
        Parses a command line exactly the way a launched process will. argv[0] is
        parsed under different rules, so a dummy program name is prepended and then
        dropped.
    #>
    param([string]$CommandLine)

    $count = 0
    $ptr = [BridgeTest.Cmd]::CommandLineToArgvW("app.exe $CommandLine", [ref]$count)
    if ($ptr -eq [IntPtr]::Zero) { throw 'CommandLineToArgvW failed' }
    try {
        $parsed = for ($i = 1; $i -lt $count; $i++) {
            [System.Runtime.InteropServices.Marshal]::PtrToStringUni(
                [System.Runtime.InteropServices.Marshal]::ReadIntPtr($ptr, $i * [IntPtr]::Size))
        }
        @($parsed)
    }
    finally { [void][BridgeTest.Cmd]::LocalFree($ptr) }
}

# Windows command lines only: on macOS tmux is handed the arguments as a list and
# nothing is ever quoted into one string.
if ($script:BridgeIsWindows) {
Write-Host '--- argument quoting round-trips through CommandLineToArgvW ---'

$cases = @(
    @{ Name = 'a plain argument';            Args = @('--banner') }
    @{ Name = 'an argument with spaces';     Args = @('-i', 'fix the bug in main.js') }
    @{ Name = 'embedded double quotes';      Args = @('-i', 'say "hello world" twice') }
    @{ Name = 'a trailing backslash';        Args = @('-C', 'C:\repos\bridge\') }
    @{ Name = 'a backslash before a quote';  Args = @('-i', 'path is C:\x\" ok') }
    @{ Name = 'several backslashes';         Args = @('-i', 'a\\\b c') }
    @{ Name = 'an empty argument';           Args = @('-i', '') }
    @{ Name = 'a full launch line';          Args = @('--session-id', '0cb916db-26aa-40f2-86b5-1ba81b225fd2', '--banner', '-i', 'refactor the "login" flow') }
)

foreach ($case in $cases) {
    $line = ConvertTo-BridgeArgumentString -Arguments $case.Args
    $round = @(ConvertFrom-CommandLine -CommandLine $line)
    $expected = @($case.Args)
    Test-That "$($case.Name) survives a round trip" {
        $round.Count -eq $expected.Count -and
        (0..($expected.Count - 1) | ForEach-Object { $round[$_] -ceq $expected[$_] }) -notcontains $false
    } "line='$line' parsed=[$($round -join '][')]"
}

Test-That 'a prompt with a space is one argument, not several' {
    (ConvertFrom-CommandLine -CommandLine (ConvertTo-BridgeArgumentString -Arguments @('-i', 'two words'))).Count -eq 2
}

Test-That 'a quote in the prompt cannot inject an extra argument' {
    $evil = 'hi" --allow-all-tools "'
    $parsed = @(ConvertFrom-CommandLine -CommandLine (ConvertTo-BridgeArgumentString -Arguments @('-i', $evil)))
    $parsed.Count -eq 2 -and $parsed[1] -ceq $evil -and $parsed -notcontains '--allow-all-tools'
}
}

# --- the approved workspace list -------------------------------------------------

$root = Join-Path ([IO.Path]::GetTempPath()) "bridge-ws-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$alpha = Join-Path $root 'alpha'
$beta = Join-Path $root 'nested\beta'
$dupe = Join-Path $root 'other\alpha'
foreach ($d in @($alpha, $beta, $dupe)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
$missing = Join-Path $root 'does-not-exist'

$script:FakeSettings = @{}
function Get-BridgeSetting {
    param([Parameter(Mandatory)][string]$Path, $Default = $null)
    if ($script:FakeSettings.ContainsKey($Path)) { return $script:FakeSettings[$Path] }
    $Default
}

# Discovery reads this machine's real Claude history, so it is shadowed with a fixed
# list; the system-folder filter it relies on is tested on its own below.
$script:FakeDiscovered = @()
function Get-BridgeDiscoveredWorkspaces { @($script:FakeDiscovered) }

# Profile discovery shells out to `agency config profiles`, so it is shadowed too: a
# test run must not depend on which profiles the machine running it happens to have,
# nor pay for a process launch per call. The real one is kept, so the section on
# profiles below can still exercise it - caching and all - against a fake probe.
$script:RealAgencyProfileList = ${function:Get-BridgeAgencyProfileList}
$script:FakeProfiles = [pscustomobject]@{ Ok = $true; Profiles = @('work', 'home', 'local') }
function Get-BridgeAgencyProfileList { $script:FakeProfiles }

# Claude's and Codex's model discovery each start that CLI to ask it, so they are
# shadowed for the same reasons, finding nothing - which leaves both on their built-in
# lists. The real one is kept for the section on that discovery below.
$script:RealLauncherModelDiscovery = ${function:Get-BridgeLauncherModelDiscovery}
function Get-BridgeLauncherModelDiscovery {
    param([string]$Launcher, [string]$Path)
    [pscustomobject]@{ Models = @(); Efforts = @(); EffortsKnown = $false; ModelEfforts = @{} }
}

Write-Host ''
Write-Host '--- the workspace list ---'

$script:FakeSettings = @{ 'newSession.workspaces' = @($alpha, $missing) }
$choices = @(Get-BridgeWorkspaceChoices)
Test-That 'a plain path string becomes a choice' { $choices.Count -eq 1 -and $choices[0].Path -eq $alpha }
Test-That 'the label defaults to the folder name' { $choices[0].Label -eq 'alpha' }
Test-That 'a directory that does not exist is dropped' { $choices.Path -notcontains $missing }

$script:FakeSettings = @{ 'newSession.workspaces' = @(
    [pscustomobject]@{ label = 'Beta project'; path = $beta }
) }
$choices = @(Get-BridgeWorkspaceChoices)
Test-That 'an explicit label is used' { $choices.Count -eq 1 -and $choices[0].Label -eq 'Beta project' }

$script:FakeSettings = @{ 'newSession.workspaces' = @($alpha, $dupe) }
$choices = @(Get-BridgeWorkspaceChoices)
Test-That 'two folders with the same name both survive' { $choices.Count -eq 2 }
Test-That 'the duplicate label is disambiguated' { ($choices | Select-Object -Expand Label | Sort-Object -Unique).Count -eq 2 }

$script:FakeSettings = @{ 'newSession.workspaces' = @() }
$choices = @(Get-BridgeWorkspaceChoices)
Test-That 'no configured workspace grants no executable target, including home' {
    $choices.Count -eq 0
}

Write-Host ''
Write-Host '--- discovered workspaces ---'

$gamma = Join-Path $root 'gamma'
New-Item -ItemType Directory -Path $gamma -Force | Out-Null
$script:FakeDiscovered = @($gamma, $alpha)
$script:FakeSettings = @{ 'newSession.workspaces' = @($alpha) }
$choices = @(Get-BridgeWorkspaceChoices)
Test-That 'discovered folders do not broaden the configured executable list' { ($choices.Label -join ',') -eq 'alpha' }
Test-That 'a discovered folder already configured is not offered twice' { @($choices | Where-Object Path -eq $alpha).Count -eq 1 }
Test-That 'a discovered folder cannot resolve without explicit approval' { $null -eq (Resolve-BridgeWorkspacePath -Label 'gamma') }
$script:FakeSettings = @{}
Test-That 'discovery alone does not supply an executable default' { (Get-BridgeDefaultWorkspaceLabel) -eq '' }
$script:FakeDiscovered = @()

if ($script:BridgeIsWindows) {
    Test-That 'System32 is a system folder' { Test-BridgeSystemDirectory -Path (Join-Path $env:WINDIR 'System32') }
    Test-That 'the Windows folder itself is a system folder' { Test-BridgeSystemDirectory -Path $env:WINDIR }
    Test-That 'Program Files is a system folder' { Test-BridgeSystemDirectory -Path (Join-Path $env:ProgramFiles 'Something') }
    Test-That 'a drive root is a system folder' { Test-BridgeSystemDirectory -Path 'C:\' }
    Test-That 'a sibling that only shares a prefix is not' { -not (Test-BridgeSystemDirectory -Path "$($env:WINDIR)Projects") }
}
else {
    Test-That '/System is a system folder' { Test-BridgeSystemDirectory -Path '/System/Library' }
    Test-That '/usr is a system folder' { Test-BridgeSystemDirectory -Path '/usr/local/bin' }
    Test-That 'an isolated home under /var is still a system folder' { Test-BridgeSystemDirectory -Path '/var/folders/bridge-test/home/repos/project' }
    Test-That 'an isolated home under /private is still a system folder' { Test-BridgeSystemDirectory -Path '/private/var/folders/bridge-test/home/repos/project' }
    Test-That 'the root is a system folder' { Test-BridgeSystemDirectory -Path '/' }
    Test-That 'a sibling that only shares a prefix is not' { -not (Test-BridgeSystemDirectory -Path '/Users/someone/usrstuff') }
}
# The runner's macOS HOME lives under excluded /var, not a normal user-home root.
$userHomeFixture = if ($script:BridgeIsWindows) { 'C:\Users\bridge-test' } else { '/Users/bridge-test' }
Test-That 'a project under a user home folder is not' { -not (Test-BridgeSystemDirectory -Path (Join-Path $userHomeFixture 'repos\project')) }

Write-Host ''
Write-Host '--- defaults, so a launch needs no input ---'

$script:FakeSettings = @{ 'newSession.workspaces' = @($alpha, $beta) }
Test-That 'the first workspace is the default when none is configured' {
    (Get-BridgeDefaultWorkspaceLabel) -eq 'alpha'
}
$script:FakeSettings = @{ 'newSession.workspaces' = @($alpha, $beta); 'newSession.defaultWorkspace' = 'beta' }
Test-That 'a configured default workspace is used' { (Get-BridgeDefaultWorkspaceLabel) -eq 'beta' }
$script:FakeSettings = @{ 'newSession.workspaces' = @($alpha, $beta); 'newSession.defaultWorkspace' = 'gone' }
Test-That 'a default naming a missing workspace falls back to the first' {
    (Get-BridgeDefaultWorkspaceLabel) -eq 'alpha'
}
$script:FakeSettings = @{ 'newSession.workspaces' = @() }
Test-That 'no approved workspaces means there is no executable default' { (Get-BridgeDefaultWorkspaceLabel) -eq '' }

$script:FakeSettings = @{ 'newSession.profiles' = @('work', 'home') }
Test-That 'the first profile is the default when none is configured' { (Get-BridgeDefaultAgencyProfile) -eq 'work' }
$script:FakeSettings = @{ 'newSession.profiles' = @('work', 'home'); 'newSession.defaultProfile' = 'home' }
Test-That 'a configured default profile is used' { (Get-BridgeDefaultAgencyProfile) -eq 'home' }
$script:FakeSettings = @{ 'newSession.profiles' = @('work', 'home'); 'newSession.defaultProfile' = 'nope' }
Test-That 'a default naming a missing profile falls back to the first' { (Get-BridgeDefaultAgencyProfile) -eq 'work' }

Write-Host ''
Write-Host '--- label resolution is the security boundary ---'

$script:FakeSettings = @{ 'newSession.workspaces' = @($alpha) }
Test-That 'a known label resolves to its approved path' { (Resolve-BridgeWorkspacePath -Label 'alpha') -eq $alpha }
Test-That 'an unknown label resolves to nothing' { $null -eq (Resolve-BridgeWorkspacePath -Label 'alpha-evil') }
Test-That 'an arbitrary path is not accepted as a label' { $null -eq (Resolve-BridgeWorkspacePath -Label 'C:\Windows\System32') }
Test-That 'an empty label resolves to nothing' { $null -eq (Resolve-BridgeWorkspacePath -Label '') }

# --- the command line ------------------------------------------------------------

Write-Host ''
Write-Host '--- the launch arguments ---'

$sid = '0cb916db-26aa-40f2-86b5-1ba81b225fd2'
$args1 = @(Get-BridgeNewSessionArguments -SessionId $sid)
Test-That 'the session id is set explicitly' { $args1 -contains '--session-id' -and $args1 -contains $sid }
Test-That 'no prompt means no -i' { $args1 -notcontains '-i' }
Test-That 'nothing is auto-approved by default' { $args1 -notcontains '--allow-all' -and $args1 -notcontains '--allow-all-tools' }

$args2 = @(Get-BridgeNewSessionArguments -SessionId $sid -Prompt 'do the thing')
Test-That 'a prompt is passed with -i so the session stays interactive' {
    $args2 -contains '-i' -and $args2[$args2.IndexOf('-i') + 1] -eq 'do the thing'
}

$args3 = @(Get-BridgeNewSessionArguments -SessionId $sid -Prompt "line one`r`nline two")
Test-That 'a newline in the prompt is flattened' {
    $args3[$args3.IndexOf('-i') + 1] -eq 'line one line two'
}

$args4 = @(Get-BridgeNewSessionArguments -SessionId $sid -Prompt '   ')
Test-That 'a whitespace-only prompt is treated as no prompt' { $args4 -notcontains '-i' }

$args5 = @(Get-BridgeNewSessionArguments -SessionId $sid -Model 'gpt-5.4' -AllowAllTools)
Test-That 'a configured model is passed through' { $args5[$args5.IndexOf('--model') + 1] -eq 'gpt-5.4' }
Test-That 'permissions are waived only when asked for' { $args5 -contains '--allow-all' }
# Not the narrow one. Copilot splits permission into tools, paths and URLs, and
# --allow-all-tools grants only the first, so a session launched with it still stopped
# on "allow access to this folder?" - unattended, with nobody there to answer. The
# other launchers have always waived the lot.
Test-That 'and with the whole thing, not just tools' { $args5 -notcontains '--allow-all-tools' }

$args6 = @(Get-BridgeNewSessionArguments -SessionId $sid -Prompt 'p' -ExtraArguments @('--plan'))
Test-That 'extra arguments are included' { $args6 -contains '--plan' }
Test-That 'the prompt stays last so extras cannot displace it' { $args6[-2] -eq '-i' -and $args6[-1] -eq 'p' }

# --- Agency ----------------------------------------------------------------------

Write-Host ''
Write-Host '--- launching through Agency ---'

$ag = @(Get-BridgeNewSessionArguments -SessionId $sid -Launcher 'agency' -AgencyProfile 'work' -Prompt 'do it')
Test-That 'the agency command is copilot' { $ag[0] -eq 'copilot' }
Test-That 'the profile is applied with --profile-only' {
    $ag[$ag.IndexOf('--profile-only') + 1] -eq 'work'
}
Test-That 'agency is given the session id so both layers share it' {
    $ag[$ag.IndexOf('--session-id') + 1] -eq $sid
}
Test-That 'agency options precede the copilot pass-through args' {
    $ag.IndexOf('--profile-only') -lt $ag.IndexOf('--banner') -and
    $ag.IndexOf('--session-id') -lt $ag.IndexOf('--banner')
}
Test-That 'the prompt still rides on -i' { $ag[$ag.IndexOf('-i') + 1] -eq 'do it' }
Test-That '--profile is never used, only --profile-only' { $ag -notcontains '--profile' }

$agNoProfile = @(Get-BridgeNewSessionArguments -SessionId $sid -Launcher 'agency')
Test-That 'no profile means no --profile-only' { $agNoProfile -notcontains '--profile-only' }
Test-That 'and agency still gets the session id' { $agNoProfile -contains '--session-id' }

if ($script:BridgeIsWindows) {
$agLine = ConvertTo-BridgeArgumentString -Arguments (
    Get-BridgeNewSessionArguments -SessionId $sid -Launcher 'agency' -AgencyProfile 'work' -Prompt 'refactor the "login" flow')
$agParsed = @(ConvertFrom-CommandLine -CommandLine $agLine)
Test-That 'the whole agency line survives a round trip' {
    $agParsed[0] -eq 'copilot' -and $agParsed[-1] -ceq 'refactor the "login" flow'
}
}

# --- Claude and Codex ------------------------------------------------------------

Write-Host ''
Write-Host '--- launching Claude and Codex ---'

$cl = @(Get-BridgeNewSessionArguments -SessionId $sid -Launcher 'claude' -Prompt 'do it')
Test-That 'claude is given the session id up front' { $cl[$cl.IndexOf('--session-id') + 1] -eq $sid }
Test-That 'the claude prompt is positional, after --' { $cl[-2] -eq '--' -and $cl[-1] -eq 'do it' }
Test-That 'claude gets no copilot-only arguments' { $cl -notcontains '--banner' -and $cl -notcontains '-i' }
Test-That 'claude permissions are not skipped by default' { $cl -notcontains '--dangerously-skip-permissions' }

$clAll = @(Get-BridgeNewSessionArguments -SessionId $sid -Launcher 'claude' -Model 'opus' -AllowAllTools)
Test-That 'claude takes the configured model' { $clAll[$clAll.IndexOf('--model') + 1] -eq 'opus' }
Test-That 'allowAllTools maps to skipping claude permissions' { $clAll -contains '--dangerously-skip-permissions' }
Test-That 'no claude prompt means no --' { $clAll -notcontains '--' }

$flagPrompt = '--dangerously-skip-permissions'
# As the launched process will see it: through the Windows command line, or on macOS
# the list tmux is given as it is.
$clArgs = @(Get-BridgeNewSessionArguments -SessionId $sid -Launcher 'claude' -Prompt $flagPrompt)
$clFlag = if ($script:BridgeIsWindows) { @(ConvertFrom-CommandLine -CommandLine (ConvertTo-BridgeArgumentString -Arguments $clArgs)) } else { $clArgs }
Test-That 'a prompt that looks like a flag stays behind --' {
    $clFlag.IndexOf($flagPrompt) -eq $clFlag.Count - 1 -and $clFlag[-2] -eq '--'
}

$cx = @(Get-BridgeNewSessionArguments -SessionId '' -Launcher 'codex' -Prompt 'do it' -AllowAllTools)
Test-That 'codex is not given a session id' { $cx -notcontains '--session-id' }
Test-That 'allowAllTools maps to never asking codex for approval' {
    $cx[$cx.IndexOf('--ask-for-approval') + 1] -eq 'never'
}
Test-That 'the codex prompt is positional, after --' { $cx[-2] -eq '--' -and $cx[-1] -eq 'do it' }

Write-Host ''
Write-Host '--- reading the trust question off the screen ---'

# Keys are only sent once the question is on screen, and only what the highlight
# needs: the option list wraps, so one Down too many lands back on "No, exit".
$noScreen = "Quick safety check: Is this a project you created or one you trust?`n`n > No, exit`n   Yes, I trust this folder`n`nEnter to confirm"
$yesScreen = "Quick safety check`n   No, exit`n > Yes, I trust this folder`n"
Test-That 'the default highlight is No' { (Get-BridgeTrustPromptSelection -Screen $noScreen) -eq 'no' }
Test-That 'a moved highlight reads Yes' { (Get-BridgeTrustPromptSelection -Screen $yesScreen) -eq 'yes' }
Test-That 'no question on screen reads as nothing' { (Get-BridgeTrustPromptSelection -Screen "Welcome to Claude Code`n> ") -eq '' }
Test-That 'an unreadable screen reads as nothing' { (Get-BridgeTrustPromptSelection -Screen $null) -eq '' }

# The second question, which only 'Allow all' can produce: Claude shows it *because*
# --dangerously-skip-permissions was passed, and 2.1.285 records no acceptance of it
# anywhere, so it comes back every launch. Same two options, same refusing label - and
# reading only the first left an unattended launch sitting here (2026-10-15).
$bypassNo = "WARNING: Claude Code running in Bypass Permissions mode`n`n > No, exit`n   Yes, I accept`n"
$bypassYes = "WARNING: Claude Code running in Bypass Permissions mode`n   No, exit`n > Yes, I accept`n"
Test-That 'the bypass-permissions warning is read as a question too' { (Get-BridgeTrustPromptSelection -Screen $bypassNo) -eq 'no' }
Test-That 'and reads Yes once its accepting option is highlighted' { (Get-BridgeTrustPromptSelection -Screen $bypassYes) -eq 'yes' }
# "No, exit" is shared, so it alone must never be enough to start sending keys into a
# window: it is the accepting label that says which question is on screen.
Test-That 'a highlighted No with no question behind it reads as nothing' {
    (Get-BridgeTrustPromptSelection -Screen "Choose one`n > No, exit`n   Something else`n") -eq ''
}

Write-Host ''
Write-Host '--- the profiles this machine actually has ---'

# Agency's own listing, as `agency config profiles` prints it.
$listing = @'
Profiles:
  home
    MCPs: none
    Plugins: none
  local
    MCPs: ado, github
    Plugins: none
  work
    MCPs: none
    Plugins: none

'@
Test-That 'every profile in a listing is read' {
    (@(Get-BridgeAgencyProfileNames -Text $listing) -join ',') -eq 'home,local,work'
}
Test-That 'what each one contains is not read as a profile of its own' {
    @(Get-BridgeAgencyProfileNames -Text $listing) -notcontains 'MCPs: none'
}
# The case this whole path exists for: Agency installed, its config never synced here.
Test-That 'a machine with no profiles has none' {
    @(Get-BridgeAgencyProfileNames -Text "No profiles configured.`n").Count -eq 0
}
Test-That 'and so does output that says nothing at all' { @(Get-BridgeAgencyProfileNames -Text '').Count -eq 0 }
Test-That 'anything printed after the listing is not a profile' {
    (@(Get-BridgeAgencyProfileNames -Text "Profiles:`n  work`n`nActivate with: agency copilot --profile <name>`n") -join ',') -eq 'work'
}

$script:ProbeCalls = 0
$script:ProbeArguments = @()
$script:ProbeWorkingDirectory = ''
$script:ProbeResult = [pscustomobject]@{ Ran = $true; TimedOut = $false; ExitCode = 0; Output = ''; StandardOutput = $listing }
function Invoke-BridgeCommandProbe {
    param([string]$Executable, [string[]]$Arguments = @(), [int]$TimeoutMs = 5000, [string]$WorkingDirectory = '')
    $script:ProbeCalls++
    $script:ProbeArguments = @($Arguments)
    $script:ProbeWorkingDirectory = [string]$WorkingDirectory
    $script:ProbeResult
}

$script:BridgeAgencyProfileCache = $null
$asked = & $script:RealAgencyProfileList -Path 'C:\agency.exe'
Test-That 'Agency is asked what it has' { $asked.Ok -and (@($asked.Profiles) -join ',') -eq 'home,local,work' }
Test-That 'with the subcommand that lists them' { ($script:ProbeArguments -join ' ') -eq 'config profiles' }
# Agency merges any agency.yaml found from the current directory upwards, so asking
# from inside a repository that has one would offer profiles that exist only there.
Test-That 'from the home directory, not from wherever the daemon is running' {
    $script:ProbeWorkingDirectory -eq $HOME
}
$again = & $script:RealAgencyProfileList -Path 'C:\agency.exe'
Test-That 'a second look inside the window is served from the cache' {
    $script:ProbeCalls -eq 1 -and (@($again.Profiles) -join ',') -eq 'home,local,work'
}

# "Could not be asked" and "has none" are different answers, and the caller treats
# them differently: the first keeps whatever is configured, the second overrides it.
$script:BridgeAgencyProfileCache = $null
$script:ProbeResult = [pscustomobject]@{ Ran = $true; TimedOut = $true; ExitCode = -1; Output = ''; StandardOutput = '' }
Test-That 'an Agency that does not answer is not read as having none' {
    -not (& $script:RealAgencyProfileList -Path 'C:\agency.exe').Ok
}
$script:BridgeAgencyProfileCache = $null
$script:ProbeResult = [pscustomobject]@{ Ran = $true; TimedOut = $false; ExitCode = 2; Output = 'unrecognized subcommand'; StandardOutput = '' }
Test-That 'nor is one too old to know the subcommand' {
    -not (& $script:RealAgencyProfileList -Path 'C:\agency.exe').Ok
}

# ...unless it can be asked a question it does understand. On DSWETT-DEV-VM1 - agency
# 2026.7.18.2, no config file anywhere on the machine - `config profiles` failed with
# "unrecognized subcommand", the card went on offering the three configured profiles,
# and every launch died with "closed before it started" because none of them existed.
# `config get` has been there throughout, and "Key 'profiles' not found" is an answer.
$script:BridgeAgencyProfileCache = $null
$script:SavedPerArgsProbe = ${function:Invoke-BridgeCommandProbe}
function Invoke-BridgeCommandProbe {
    param([string]$Executable, [string[]]$Arguments = @(), [int]$TimeoutMs = 5000, [string]$WorkingDirectory = '')
    $script:ProbeCalls++
    $script:ProbeArguments = @($Arguments)
    if (($Arguments -join ' ') -eq 'config profiles') {
        return [pscustomobject]@{
            Ran = $true; TimedOut = $false; ExitCode = 2
            Output = "error: unrecognized subcommand 'profiles'"; StandardOutput = ''
        }
    }
    [pscustomobject]@{
        Ran = $true; TimedOut = $false; ExitCode = 1
        Output = "CLI command 'config' failed: Key 'profiles' not found in config"; StandardOutput = ''
    }
}
$script:ProbeCalls = 0
$script:OldAgencyAnswer = & $script:RealAgencyProfileList -Path 'C:\agency.exe'
Test-That 'an older Agency is then asked something it does understand' {
    $script:ProbeCalls -eq 2 -and ($script:ProbeArguments -join ' ') -eq 'config get profiles'
}
Test-That 'and "no profiles here" is an answer, not a failure to ask' {
    $script:OldAgencyAnswer.Ok -and @($script:OldAgencyAnswer.Profiles).Count -eq 0
}

$script:BridgeAgencyProfileCache = $null
function Invoke-BridgeCommandProbe {
    param([string]$Executable, [string[]]$Arguments = @(), [int]$TimeoutMs = 5000, [string]$WorkingDirectory = '')
    [pscustomobject]@{ Ran = $true; TimedOut = $false; ExitCode = 1; Output = 'connection refused'; StandardOutput = '' }
}
Test-That 'but a failure that says nothing about profiles still is not' {
    -not (& $script:RealAgencyProfileList -Path 'C:\agency.exe').Ok
}
${function:Invoke-BridgeCommandProbe} = $script:SavedPerArgsProbe
$script:BridgeAgencyProfileCache = $null
$script:ProbeResult = [pscustomobject]@{ Ran = $true; TimedOut = $false; ExitCode = 2; Output = 'unrecognized subcommand'; StandardOutput = '' }

# Each adapter ships its own copy of bridge-platform.ps1 and the daemon loads whichever
# is installed, so a bridge running from a checkout against an older install can be
# holding a probe from before this asked for stdout on its own. Losing the profiles
# then - or worse, throwing inside a reconcile pass - is not on.
$script:BridgeAgencyProfileCache = $null
$script:ProbeResult = [pscustomobject]@{ Ran = $true; TimedOut = $false; ExitCode = 0; Output = 'Profiles: home local work' }
Test-That 'a probe from before this could not answer, rather than answering nothing' {
    -not (& $script:RealAgencyProfileList -Path 'C:\agency.exe').Ok
}
$script:BridgeAgencyProfileCache = $null
$countingProbe = ${function:Invoke-BridgeCommandProbe}
function Invoke-BridgeCommandProbe {
    param([string]$Executable, [string[]]$Arguments = @(), [int]$TimeoutMs = 5000)
    [pscustomobject]@{ Ran = $true; TimedOut = $false; ExitCode = 0; Output = '' }
}
Test-That 'and one that has no working directory to be given does not throw' {
    -not (& $script:RealAgencyProfileList -Path 'C:\agency.exe').Ok
}
${function:Invoke-BridgeCommandProbe} = $countingProbe

$savedAgencyPath = ${function:Get-BridgeAgencyPath}
function Get-BridgeAgencyPath { $null }
$script:BridgeAgencyProfileCache = $null
$script:ProbeCalls = 0
Test-That 'and with no Agency installed, nothing is run at all' {
    $none = & $script:RealAgencyProfileList
    -not $none.Ok -and $script:ProbeCalls -eq 0
}
${function:Get-BridgeAgencyPath} = $savedAgencyPath
$script:BridgeAgencyProfileCache = $null

Write-Host ''
Write-Host '--- which of them the card offers ---'

$script:FakeSettings = @{}
$script:FakeProfiles = [pscustomobject]@{ Ok = $true; Profiles = @('work', 'home', 'local') }
Test-That 'with nothing configured, every profile the machine has is offered' {
    (Get-BridgeAgencyProfiles) -join ',' -eq 'work,home,local'
}
Test-That 'a known profile resolves' { (Resolve-BridgeAgencyProfile -Name 'home') -eq 'home' }
Test-That 'an unknown profile is refused' { $null -eq (Resolve-BridgeAgencyProfile -Name 'prod') }
Test-That 'an injected profile string is refused' { $null -eq (Resolve-BridgeAgencyProfile -Name 'work --yolo') }
Test-That 'an empty profile is refused' { $null -eq (Resolve-BridgeAgencyProfile -Name '') }

# A configured list picks and orders among the profiles that exist. It is no longer a
# way to name one that does not: `agency copilot --profile-only work` on a machine
# with no `work` exits 1 before Copilot starts, and the window closes too fast to read.
$script:FakeSettings = @{ 'newSession.profiles' = @('local', 'work') }
Test-That 'a configured list chooses among them, in its own order' {
    (Get-BridgeAgencyProfiles) -join ',' -eq 'local,work'
}
$script:FakeSettings = @{ 'newSession.profiles' = @('work', 'gone') }
Test-That 'and a name this machine does not have is dropped from it' {
    (Get-BridgeAgencyProfiles) -join ',' -eq 'work'
}
$script:FakeSettings = @{ 'newSession.profiles' = @('gone', 'also-gone') }
Test-That 'a configured list that is entirely stale falls back to the real ones' {
    (Get-BridgeAgencyProfiles) -join ',' -eq 'work,home,local'
}

# A new machine: Agency installed, no profiles yet. Nothing is offered, and a launch
# passes none - which runs Agency's base config, and that always works.
$script:FakeProfiles = [pscustomobject]@{ Ok = $true; Profiles = @() }
$script:FakeSettings = @{ 'newSession.profiles' = @('work', 'home', 'local') }
Test-That 'a machine whose Agency has no profiles offers none' { @(Get-BridgeAgencyProfiles).Count -eq 0 }
Test-That 'and asks for none when a launch needs a default' { (Get-BridgeDefaultAgencyProfile) -eq '' }
Test-That 'and no --profile-only reaches the command line' {
    (Get-BridgeNewSessionArguments -SessionId $sid -Launcher 'agency' -AgencyProfile '') -notcontains '--profile-only'
}

# Ok = $false is "Agency could not be asked", and dropping the configured list on that
# would quietly change what every launch here runs with.
$script:FakeProfiles = [pscustomobject]@{ Ok = $false; Profiles = @() }
$script:FakeSettings = @{ 'newSession.profiles' = @('work', 'home') }
Test-That 'an Agency that cannot be asked leaves the configured list alone' {
    (Get-BridgeAgencyProfiles) -join ',' -eq 'work,home'
}
$script:FakeSettings = @{}
Test-That 'and with nothing configured either, no profile is offered' {
    @(Get-BridgeAgencyProfiles).Count -eq 0
}

# Back to a machine with the usual three, for everything below.
$script:FakeProfiles = [pscustomobject]@{ Ok = $true; Profiles = @('work', 'home', 'local') }

Write-Host ''
Write-Host '--- model, effort and context ---'

# Copilot's model list comes from a conversation with its headless server: a
# throwaway session is asked for the roster its own /model picker shows. The transport
# is tested against a real child process in test-install-clients.ps1; here a scripted
# conversation stands in for the CLI, so what is asserted is what the bridge asks for,
# what it keeps, and what it leaves behind on disk.
$savedModelCopilotPath = ${function:Get-BridgeCopilotPath}
$savedRpcStart = ${function:Start-BridgeJsonRpcProcess}
$savedRpcInvoke = ${function:Invoke-BridgeJsonRpcRequest}
$savedRpcStop = ${function:Stop-BridgeJsonRpcProcess}
$savedModelRoster = ${function:Get-BridgeCopilotModelRoster}
$savedModelCopilotHome = $env:COPILOT_HOME
function Get-BridgeCopilotPath { 'C:\fake-copilot.exe' }

function New-FakeRpcError {
    param([int]$Code, [string]$Message)
    $exception = [InvalidOperationException]::new("$Message (code $Code)")
    $exception.Data['JsonRpcCode'] = $Code
    $exception
}
$script:RpcStarts = [Collections.Generic.List[object]]::new()
$script:RpcCalls = [Collections.Generic.List[object]]::new()
$script:RpcStops = 0
$script:FakeExited = $true
function Start-BridgeJsonRpcProcess {
    param([string]$Executable, [string[]]$Arguments = @(), [string]$WorkingDirectory = '')
    $script:RpcStarts.Add([pscustomobject]@{
            Executable = $Executable; Arguments = @($Arguments); WorkingDirectory = $WorkingDirectory
            Existed = [IO.Directory]::Exists($WorkingDirectory)
        })
    [pscustomobject]@{ Fake = $true }
}
function Invoke-BridgeJsonRpcRequest {
    param($Connection, [string]$Method, $Params = @{}, [DateTimeOffset]$Deadline)
    $script:RpcCalls.Add([pscustomobject]@{
            Method = $Method; Params = $Params; Remaining = ($Deadline - [DateTimeOffset]::Now).TotalSeconds
        })
    $handler = $script:RpcHandlers[$Method]
    if ($null -eq $handler) { throw (New-FakeRpcError -Code -32601 -Message "Method not found: $Method") }
    , (& $handler $Params)
}
function Stop-BridgeJsonRpcProcess {
    param($Connection, [int]$GraceMs = 2000)
    $script:RpcStops++
    [pscustomobject]@{ Exited = $script:FakeExited; Killed = $false; ExitCode = 0; StandardError = '' }
}
function Get-FakeRpcMethods { @($script:RpcCalls | ForEach-Object { $_.Method }) -join ',' }
function Get-FakeSessionId {
    $created = @($script:RpcCalls | Where-Object { $_.Method -eq 'session.create' })
    if ($created.Count -gt 0) { [string]$created[0].Params['sessionId'] } else { '' }
}

# What an account like this one is offered, among the other shapes a roster can carry.
$script:FullFakeRoster = @(
    @{ id = 'auto' }
    @{ id = 'claude-opus-5.5'; policy = @{ state = 'enabled' }; provider = @{ kind = 'copilot'; id = 'copilot' } }
    @{ id = 'claude-fable-5'; policy = @{ state = 'disabled' } }
    @{ id = 'gemini-3.8-flash'; policy = @{ state = 'enabled' } }
    @{ id = 'needs-setup'; policy = @{ state = 'unconfigured' } }
    @{ id = 'future-state'; policy = @{ state = 'something-new' } }
    @{ id = 'm365-model'; provider = @{ kind = 'loki'; id = 'm365' } }
    @{ id = 'ollama/llama3' }
    @{ id = 'gpt-5.4:latest' }
    @{ id = '-flag-like' }
    @{ id = "trailing-newline`n" }
    @{ id = 42 }
    'not-an-object'
    @{ id = 'claude-opus-5.5'; policy = @{ state = 'enabled' } }
    @{ id = 'grok-4.7' }
)

$script:LongAgo = [datetime]::new(2020, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
$script:ModelHome = [IO.Path]::Combine([IO.Path]::GetTempPath(), "bridge-models-$([guid]::NewGuid().ToString('N').Substring(0, 8))")
$script:FakeState = [IO.Path]::Combine($script:ModelHome, 'session-state')
$script:FakeLocks = [IO.Path]::Combine($script:FakeState, '.session-operation-locks')
$script:EarlierSession = [IO.Path]::Combine($script:FakeState, 'earlier-session')
$script:OtherLock = [IO.Path]::Combine($script:FakeLocks, 'other-session.lock')
$emptyModelHome = [IO.Path]::Combine([IO.Path]::GetTempPath(), "bridge-models-$([guid]::NewGuid().ToString('N').Substring(0, 8))")
$snapshotRoot = [IO.Path]::Combine([IO.Path]::GetTempPath(), "bridge-snapshot-$([guid]::NewGuid().ToString('N').Substring(0, 8))")

function Reset-FakeCopilot {
    $script:RpcStarts.Clear()
    $script:RpcCalls.Clear()
    $script:RpcStops = 0
    $script:FakeExited = $true
    $script:FakeRoster = $script:FullFakeRoster
    # What the real CLI does on disk: a lock beside other sessions' locks, and a folder
    # of its own that session.delete removes again.
    $script:RpcHandlers = @{
        'connect'            = { param($Params) @{ version = '1.0.95'; protocolVersion = 3 } }
        'session.create'     = {
            param($Params)
            $state = [IO.Path]::Combine($env:COPILOT_HOME, 'session-state')
            $locks = [IO.Path]::Combine($state, '.session-operation-locks')
            [void][IO.Directory]::CreateDirectory($locks)
            [IO.File]::WriteAllText([IO.Path]::Combine($locks, "$($Params['sessionId']).lock"), '')
            [void][IO.Directory]::CreateDirectory([IO.Path]::Combine($state, [string]$Params['sessionId']))
            @{ sessionId = $Params['sessionId'] }
        }
        'session.model.list' = { param($Params) @{ list = $script:FakeRoster } }
        'session.delete'     = {
            param($Params)
            $folder = [IO.Path]::Combine($env:COPILOT_HOME, 'session-state', [string]$Params['sessionId'])
            if ([IO.Directory]::Exists($folder)) { [IO.Directory]::Delete($folder, $true) }
            @{}
        }
    }
    # The launcher's 'auto' reads these times to tell when Copilot was last used.
    [IO.File]::SetLastWriteTimeUtc($script:OtherLock, $script:LongAgo)
    foreach ($folder in @($script:EarlierSession, $script:FakeLocks, $script:FakeState)) {
        [IO.Directory]::SetLastWriteTimeUtc($folder, $script:LongAgo)
    }
}
function Invoke-FakeRosterProbe {
    $script:RosterModels = @()
    $script:RosterError = $null
    try { $script:RosterModels = @(Get-BridgeCopilotModelRoster -Path 'C:\fake-copilot.exe') }
    catch { $script:RosterError = $_.Exception.Message }
}

try {
    [void][IO.Directory]::CreateDirectory($script:EarlierSession)
    [void][IO.Directory]::CreateDirectory($script:FakeLocks)
    [IO.File]::WriteAllText($script:OtherLock, '')
    [void][IO.Directory]::CreateDirectory($emptyModelHome)
    $env:COPILOT_HOME = $script:ModelHome

    Reset-FakeCopilot
    Invoke-FakeRosterProbe
    $sessionId = Get-FakeSessionId
    Test-That 'a model the account''s policy has not enabled - Fable, here - is not offered' {
        $script:RosterModels -notcontains 'claude-fable-5' -and $script:RosterModels -notcontains 'needs-setup' -and
            $script:RosterModels -notcontains 'future-state' -and $script:RosterModels -contains 'gemini-3.8-flash'
    } "$($script:RosterError)"
    Test-That 'nor is one from Microsoft 365 or a BYOK provider, which --model alone cannot reach' {
        $script:RosterModels.Count -gt 0 -and $script:RosterModels -notcontains 'm365-model' -and
            $script:RosterModels -notcontains 'ollama/llama3'
    }
    Test-That 'what remains keeps the CLI''s order, once each, without IDs unsafe on a command line' {
        ($script:RosterModels -join ',') -ceq 'auto,claude-opus-5.5,gemini-3.8-flash,grok-4.7'
    } "$($script:RosterModels -join ',')"
    Test-That 'the throwaway session loads no hooks, skills or project config and stores nothing' {
        $create = @($script:RpcCalls | Where-Object { $_.Method -eq 'session.create' })[0].Params
        $create['hooks'] -eq $false -and $create['enableFileHooks'] -eq $false -and
            $create['enableConfigDiscovery'] -eq $false -and $create['enableSkills'] -eq $false -and
            $create['enableSessionStore'] -eq $false -and $create['requestPermission'] -eq $false
    }
    Test-That 'one fresh session is created, listed and deleted' {
        $ids = @($script:RpcCalls | Where-Object { $_.Method -like 'session.*' } | ForEach-Object { [string]$_.Params['sessionId'] })
        $parsed = [guid]::Empty
        $ids.Count -eq 3 -and @($ids | Select-Object -Unique).Count -eq 1 -and [guid]::TryParse($ids[0], [ref]$parsed)
    } "$(Get-FakeRpcMethods)"
    Test-That 'the CLI runs headless over stdio in a scratch folder, without updating itself, and logs there' {
        $start = $script:RpcStarts[0]
        $arguments = @($start.Arguments)
        $logIndex = [Array]::IndexOf($arguments, '--log-dir')
        $script:RpcStarts.Count -eq 1 -and $start.Executable -eq 'C:\fake-copilot.exe' -and $start.Existed -and
            $arguments -contains '--headless' -and $arguments -contains '--stdio' -and $arguments -contains '--no-auto-update' -and
            $logIndex -ge 0 -and
            [IO.Path]::GetDirectoryName($arguments[$logIndex + 1]) -eq [IO.Path]::GetDirectoryName($start.WorkingDirectory)
    }
    Test-That 'a slow cold start still has most of twenty seconds to answer in' {
        $connect = @($script:RpcCalls | Where-Object { $_.Method -eq 'connect' })[0]
        $connect.Remaining -ge 15 -and $connect.Remaining -le 21
    }
    Test-That 'afterwards nothing of the throwaway session is left: no lock, no session folder, no scratch folder' {
        $sessionId -and $script:RpcStops -eq 1 -and
            -not [IO.File]::Exists([IO.Path]::Combine($script:FakeLocks, "$sessionId.lock")) -and
            -not [IO.Directory]::Exists([IO.Path]::Combine($script:FakeState, $sessionId)) -and
            -not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($script:RpcStarts[0].WorkingDirectory))
    }
    Test-That 'while other sessions'' locks and folders are left where they were' {
        [IO.File]::Exists($script:OtherLock) -and [IO.Directory]::Exists($script:EarlierSession)
    }
    Test-That 'and Copilot does not look freshly used to the launcher, whose auto choice reads those folder times' {
        (Get-BridgeCopilotUsage).LastUsed -eq $script:LongAgo
    } "last used $((Get-BridgeCopilotUsage).LastUsed)"

    Reset-FakeCopilot
    $script:RpcHandlers.Remove('connect')
    $script:RpcHandlers['ping'] = { param($Params) @{ message = 'pong'; timestamp = 0 } }
    Invoke-FakeRosterProbe
    Test-That 'a CLI too old to know connect is greeted with ping instead' {
        $null -eq $script:RosterError -and
            (Get-FakeRpcMethods) -eq 'connect,ping,session.create,session.model.list,session.delete'
    } "$($script:RosterError) $(Get-FakeRpcMethods)"

    Reset-FakeCopilot
    $script:RpcHandlers['session.model.list'] = {
        param($Params) throw (New-FakeRpcError -Code -32603 -Message 'simulated internal error')
    }
    Invoke-FakeRosterProbe
    $sessionId = Get-FakeSessionId
    Test-That 'a CLI that fails partway still has its session deleted and is stopped once, leaving nothing behind' {
        $script:RosterError -match 'simulated internal error' -and (Get-FakeRpcMethods) -match 'session\.delete\z' -and
            $script:RpcStops -eq 1 -and $sessionId -and
            -not [IO.File]::Exists([IO.Path]::Combine($script:FakeLocks, "$sessionId.lock")) -and
            -not [IO.Directory]::Exists([IO.Path]::Combine($script:FakeState, $sessionId)) -and
            (Get-BridgeCopilotUsage).LastUsed -eq $script:LongAgo
    } "$($script:RosterError)"

    Reset-FakeCopilot
    $script:RpcHandlers.Remove('session.model.list')
    Invoke-FakeRosterProbe
    Test-That 'a CLI without the roster says which version it is and to update it' {
        $script:RosterError -match 'Copilot CLI 1\.0\.95 cannot list its models' -and $script:RosterError -match 'update it'
    } "$($script:RosterError)"

    Reset-FakeCopilot
    $script:RpcHandlers.Remove('connect')
    $script:RpcHandlers.Remove('session.create')
    $script:RpcHandlers['ping'] = { param($Params) @{ message = 'pong'; timestamp = 0 } }
    Invoke-FakeRosterProbe
    Test-That 'and one too old even to report its version is told the same' {
        $script:RosterError -match 'this Copilot CLI cannot list its models' -and $script:RosterError -match 'update it'
    } "$($script:RosterError)"

    Reset-FakeCopilot
    $script:FakeRoster = @(@{ id = 'claude-fable-5'; policy = @{ state = 'disabled' } }, @{ id = 'ollama/llama3' })
    Invoke-FakeRosterProbe
    Test-That 'a roster with nothing usable in it is a failure rather than an empty choice' {
        $script:RosterError -match 'no usable models'
    } "$($script:RosterError)"

    Reset-FakeCopilot
    $script:RpcHandlers['session.model.list'] = { param($Params) @{ models = @('gpt-5.4') } }
    Invoke-FakeRosterProbe
    Test-That 'and so is an answer in a shape the bridge does not recognise' {
        $script:RosterError -match 'without a model list'
    } "$($script:RosterError)"

    Reset-FakeCopilot
    $script:FakeExited = $false
    Invoke-FakeRosterProbe
    $sessionId = Get-FakeSessionId
    $runningLock = [IO.Path]::Combine($script:FakeLocks, "$sessionId.lock")
    Test-That 'the lock of a CLI that could not be stopped is left alone, since it may still be held' {
        $sessionId -and [IO.File]::Exists($runningLock)
    }
    if ($sessionId -and [IO.File]::Exists($runningLock)) { [IO.File]::Delete($runningLock) }

    Reset-FakeCopilot
    $script:RpcHandlers['session.delete'] = {
        param($Params) throw (New-FakeRpcError -Code -32603 -Message 'simulated delete failure')
    }
    Invoke-FakeRosterProbe
    $sessionId = Get-FakeSessionId
    Test-That 'a session the CLI failed to delete is removed once it has exited, and its answer still counts' {
        $null -eq $script:RosterError -and $script:RosterModels.Count -eq 4 -and $sessionId -and
            -not [IO.Directory]::Exists([IO.Path]::Combine($script:FakeState, $sessionId)) -and
            [IO.Directory]::Exists($script:EarlierSession) -and (Get-BridgeCopilotUsage).LastUsed -eq $script:LongAgo
    } "$($script:RosterError)"

    Reset-FakeCopilot
    $env:COPILOT_HOME = $emptyModelHome
    Invoke-FakeRosterProbe
    $env:COPILOT_HOME = $script:ModelHome
    Test-That 'where Copilot has never kept a session, the probe leaves no session store to make it look signed in' {
        $null -eq $script:RosterError -and
            -not [IO.Directory]::Exists([IO.Path]::Combine($emptyModelHome, 'session-state'))
    } "$($script:RosterError)"

    # The same restore on its own, against what a real session starting alongside the
    # probe would leave.
    $quietFolder = [IO.Path]::Combine($snapshotRoot, 'quiet')
    $busyFolder = [IO.Path]::Combine($snapshotRoot, 'busy')
    $freshFolder = [IO.Path]::Combine($snapshotRoot, 'fresh')
    $claimedFolder = [IO.Path]::Combine($snapshotRoot, 'claimed')
    foreach ($folder in @($quietFolder, $busyFolder)) {
        [void][IO.Directory]::CreateDirectory($folder)
        [IO.File]::WriteAllText([IO.Path]::Combine($folder, 'a'), '')
        [IO.Directory]::SetLastWriteTimeUtc($folder, $script:LongAgo)
    }
    $snapshotError = $null
    try {
        $snapshot = Get-BridgeFolderSnapshot -Path @($quietFolder, $busyFolder, $freshFolder, $claimedFolder)
        foreach ($folder in @($quietFolder, $busyFolder)) { [IO.File]::WriteAllText([IO.Path]::Combine($folder, 'b'), '') }
        [IO.File]::Delete([IO.Path]::Combine($quietFolder, 'b'))
        [void][IO.Directory]::CreateDirectory($freshFolder)
        [void][IO.Directory]::CreateDirectory($claimedFolder)
        [IO.File]::WriteAllText([IO.Path]::Combine($claimedFolder, 'c'), '')
        Restore-BridgeFolderSnapshot -Snapshot $snapshot
    }
    catch { $snapshotError = $_.Exception.Message }
    Test-That 'a folder whose entries end up as they were gets its old time back' {
        $null -eq $snapshotError -and [IO.Directory]::GetLastWriteTimeUtc($quietFolder) -eq $script:LongAgo
    } "$snapshotError"
    Test-That 'one that gained an entry meanwhile keeps its new time, since that activity was real' {
        $null -eq $snapshotError -and [IO.Directory]::GetLastWriteTimeUtc($busyFolder) -gt $script:LongAgo
    }
    Test-That 'a folder the probe created is removed again while it is empty' {
        $null -eq $snapshotError -and -not [IO.Directory]::Exists($freshFolder)
    }
    Test-That 'but kept once something else has put files in it' {
        $null -eq $snapshotError -and [IO.File]::Exists([IO.Path]::Combine($claimedFolder, 'c'))
    }

    # The cache in front of it. Every refresh costs a throwaway session, so an answer
    # is kept for hours; a failure keeps the last good list and retries, backing off.
    $script:RosterCalls = 0
    $script:RosterPath = ''
    $script:RosterResult = @('auto', 'test-model')
    $script:RosterFailure = $null
    function Get-BridgeCopilotModelRoster {
        param([string]$Path, [int]$TimeoutMs = 20000)
        $script:RosterCalls++
        $script:RosterPath = $Path
        if ($script:RosterFailure) { throw $script:RosterFailure }
        $script:RosterResult
    }
    function Get-LastModelLog {
        if (-not (Test-Path -LiteralPath $script:testLogFile)) { return '' }
        [string](@(Get-Content -LiteralPath $script:testLogFile | Where-Object { $_ -match 'Copilot model discovery' }) |
                Select-Object -Last 1)
    }
    function Get-LastModelRetry { [int][regex]::Match((Get-LastModelLog), 'retrying in (\d+)s').Groups[1].Value }

    $script:FakeSettings = @{}
    $script:BridgeModelCache = $null
    Test-That 'a cold start asks the CLI once and offers what it answers' {
        (@(Get-BridgeCopilotModelList) -join ',') -eq 'auto,test-model' -and $script:RosterCalls -eq 1 -and
            $script:RosterPath -eq 'C:\fake-copilot.exe'
    }
    $script:BridgeModelCache.At = [DateTimeOffset]::Now.AddHours(-5)
    Test-That 'the answer is reused for hours rather than costing a session every reconcile' {
        (@(Get-BridgeCopilotModelList) -join ',') -eq 'auto,test-model' -and $script:RosterCalls -eq 1
    }
    $script:BridgeModelCache.At = [DateTimeOffset]::Now.AddHours(-6).AddSeconds(-1)
    [void](Get-BridgeCopilotModelList)
    Test-That 'and asked for again after six' { $script:RosterCalls -eq 2 }

    $script:RosterFailure = 'simulated roster failure'
    $script:BridgeModelCache.At = [DateTimeOffset]::Now.AddHours(-7)
    $keptModels = @(Get-BridgeCopilotModelList)
    Test-That 'a failed refresh keeps the last good list and logs why' {
        ($keptModels -join ',') -eq 'auto,test-model' -and
            (Get-LastModelLog) -match "failed for 'C:\\fake-copilot\.exe': simulated roster failure\. Keeping 2 cached model\(s\); retrying in 60s"
    } "$(Get-LastModelLog)"
    $modelCalls = $script:RosterCalls
    Test-That 'selector reads after a failure do not ask again before the retry is due' {
        ((Get-BridgeTuningOptions -Launcher 'agency' -Axis 'model') -join ',') -eq 'Agent default,auto,test-model' -and
            $script:RosterCalls -eq $modelCalls
    }
    $retryWaits = foreach ($attempt in 1..6) {
        $script:BridgeModelCache.At = [DateTimeOffset]::Now.AddSeconds(-(Get-LastModelRetry) - 1)
        [void](Get-BridgeCopilotModelList)
        Get-LastModelRetry
    }
    Test-That 'repeated failures back off, doubling up to half an hour, and keep the list throughout' {
        ($retryWaits -join ',') -eq '120,240,480,960,1800,1800' -and
            (@(Get-BridgeCopilotModelList) -join ',') -eq 'auto,test-model'
    } "waits $($retryWaits -join ',')"
    $modelCalls = $script:RosterCalls
    $script:BridgeModelCache.At = [DateTimeOffset]::Now.AddSeconds(-1700)
    [void](Get-BridgeCopilotModelList)
    Test-That 'and a backed-off failure is not retried before its wait is up' { $script:RosterCalls -eq $modelCalls }

    $script:RosterFailure = $null
    $script:BridgeModelCache.At = [DateTimeOffset]::Now.AddSeconds(-1801)
    $recoveredModels = @(Get-BridgeCopilotModelList)
    Test-That 'recovery is logged' {
        ($recoveredModels -join ',') -eq 'auto,test-model' -and (Get-LastModelLog) -match 'recovered: found 2 model\(s\)'
    } "$(Get-LastModelLog)"
    $script:RosterFailure = 'simulated roster failure'
    $script:BridgeModelCache.At = [DateTimeOffset]::Now.AddHours(-7)
    [void](Get-BridgeCopilotModelList)
    Test-That 'and resets the back-off, so the next failure retries after a minute again' {
        (Get-LastModelRetry) -eq 60
    } "$(Get-LastModelLog)"

    $script:BridgeModelCache = $null
    $coldChoices = @(Get-BridgeTuningOptions -Launcher 'copilot' -Axis 'model')
    Test-That 'a failure with nothing cached still offers Agent default and auto, and says so' {
        ($coldChoices -join ',') -eq 'Agent default,auto' -and
            (Get-LastModelLog) -match 'Keeping 0 cached model\(s\); retrying in 60s'
    } "$(Get-LastModelLog)"

    $script:RosterFailure = $null
    $script:BridgeModelCache = $null
    [void](Get-BridgeCopilotModelList)
    $script:RosterResult = @('auto', 'updated-model')
    $script:BridgeModelCache.At = [DateTimeOffset]::Now.AddHours(-7)
    Test-That 'a refresh replaces the list rather than keeping models the account has since lost' {
        ((Get-BridgeTuningOptions -Launcher 'copilot' -Axis 'model') -join ',') -eq 'Agent default,auto,updated-model'
    }

    $savedModelDiscoverer = $script:BridgeLauncherTuning.copilot.model.Discover
    try {
        $script:BridgeLauncherTuning.copilot.model.Discover = { throw 'unexpected discovery failure' }
        Test-That 'an unexpected discoverer failure is not hidden by another silent catch' {
            try { [void](Get-BridgeTuningOptions -Launcher 'copilot' -Axis 'model'); $false }
            catch { $_.Exception.Message -eq 'unexpected discovery failure' }
        }
    }
    finally { $script:BridgeLauncherTuning.copilot.model.Discover = $savedModelDiscoverer }
}
finally {
    $env:COPILOT_HOME = $savedModelCopilotHome
    foreach ($folder in @($script:ModelHome, $emptyModelHome, $snapshotRoot)) {
        Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
    }
    ${function:Get-BridgeCopilotPath} = $savedModelCopilotPath
    ${function:Start-BridgeJsonRpcProcess} = $savedRpcStart
    ${function:Invoke-BridgeJsonRpcRequest} = $savedRpcInvoke
    ${function:Stop-BridgeJsonRpcProcess} = $savedRpcStop
    ${function:Get-BridgeCopilotModelRoster} = $savedModelRoster
    $script:BridgeModelCache = $null
}

Write-Host ''
Write-Host '--- Claude and Codex model discovery ---'

# Claude's list comes from the initialize request its SDK opens every session with,
# Codex's from model/list on its app-server, and both talk one JSON object a line. A
# pwsh child stands in for each CLI: first one that tests that transport itself, then
# scripted CLIs, so what is asserted is what each probe asks and what it keeps, and
# last the cache in front of both.
$savedLauncherDiscovery = ${function:Get-BridgeLauncherModelDiscovery}
$savedDiscoveryClaudePath = ${function:Get-BridgeClaudePath}
$savedDiscoveryCodexPath = ${function:Get-BridgeCodexPath}
$savedLineStart = ${function:Start-BridgeJsonLineProcess}
$savedClaudeRoster = ${function:Get-BridgeClaudeModelRoster}
$savedCodexRoster = ${function:Get-BridgeCodexModelRoster}
$linePwsh = Get-BridgePwshPath
$lineRoot = [IO.Path]::Combine([IO.Path]::GetTempPath(), "jsonl-fake-$([guid]::NewGuid().ToString('N').Substring(0, 8))")
$lineChild = $null
$env:BRIDGE_TEST_PARENT = 'inherited'
try {
    ${function:Get-BridgeLauncherModelDiscovery} = $script:RealLauncherModelDiscovery
    [void][IO.Directory]::CreateDirectory($lineRoot)

    # What every stand-in shares: a line in, decoded once it is whole and logged where
    # FAKE_LOG says, and a line out, written in pieces when asked to be.
    $lineHelpers = @'
$ErrorActionPreference = 'Stop'
$stdin = [Console]::OpenStandardInput()
$stdout = [Console]::OpenStandardOutput()
$buffer = [Collections.Generic.List[byte]]::new()
$chunk = [byte[]]::new(4096)
function Read-Line {
    while ($true) {
        $end = $buffer.IndexOf([byte]10)
        if ($end -ge 0) {
            $line = [Text.Encoding]::UTF8.GetString($buffer.GetRange(0, $end).ToArray())
            $buffer.RemoveRange(0, $end + 1)
            if ($env:FAKE_LOG) { [IO.File]::AppendAllText($env:FAKE_LOG, "$line`n") }
            return $line
        }
        $count = $stdin.Read($chunk, 0, $chunk.Length)
        if ($count -le 0) { exit 0 }
        $buffer.AddRange([ArraySegment[byte]]::new($chunk, 0, $count))
    }
}
function Read-Request { ConvertFrom-Json -InputObject (Read-Line) -AsHashtable }
function Get-LineBytes($Message) {
    , [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Message -Depth 10 -Compress) + "`n")
}
function Write-Raw([byte[]]$Bytes, [int[]]$SplitAt = @()) {
    $from = 0
    foreach ($to in @($SplitAt) + $Bytes.Length) {
        if ($from -gt 0) { Start-Sleep -Milliseconds 150 }
        $stdout.Write($Bytes, $from, $to - $from)
        $stdout.Flush()
        $from = $to
    }
}
function Write-Line($Message) { Write-Raw (Get-LineBytes $Message) }
function Wait-End { while ($true) { [void](Read-Line) } }
'@
    function New-FakeLineScript {
        param([string]$Name, [string]$Body)
        $path = [IO.Path]::Combine($script:lineRoot, $Name)
        [IO.File]::WriteAllText($path, $script:lineHelpers + "`n" + $Body)
        $path
    }
    # The answer to one request of the child in $lineChild, or the exception it threw.
    function Invoke-FakeLineRequest {
        param([string]$Method, $Params = @{}, [DateTimeOffset]$Deadline = [DateTimeOffset]::Now.AddSeconds(60))
        try { Invoke-BridgeJsonLineRequest -Connection $script:lineChild -Method $Method -Params $Params -Deadline $Deadline }
        catch { $_.Exception }
    }
    function Format-FakeLineAnswer {
        param($Answer)
        if ($Answer -is [Exception]) { return "$($Answer.GetType().Name): $($Answer.Message)" }
        ConvertTo-Json -InputObject $Answer -Compress -Depth 5
    }

    # The transport, against a child that answers each method in its own way.
    $lineServer = New-FakeLineScript -Name 'server.ps1' -Body @'
while ($true) {
    $request = Read-Request
    $id = $request['id']
    switch ($request['method']) {
        'echo' {
            $bytes = Get-LineBytes ([ordered]@{
                    id = $id; result = [ordered]@{ params = $request['params']; keys = (@($request.Keys | Sort-Object) -join ',') }
                })
            # Three writes, the second ending between the two bytes of a character.
            Write-Raw $bytes -SplitAt @(10, ([Array]::IndexOf($bytes, [byte]0xC3) + 1))
        }
        'env' {
            Write-Line ([ordered]@{ id = $id; result = [ordered]@{
                        value = $env:BRIDGE_TEST_LINE; parent = $env:BRIDGE_TEST_PARENT; directory = [IO.Directory]::GetCurrentDirectory()
                    } })
        }
        'interleave' {
            # Stray output, a notification and a request of its own, then a reply to
            # some other request and the answer, written together.
            Write-Raw ([Text.Encoding]::UTF8.GetBytes("Warning: printed to stdout`n`n"))
            Write-Line ([ordered]@{ method = 'thread/started'; params = @{} })
            Write-Line ([ordered]@{ id = 'srv-1'; method = 'item/tool/requestUserInput'; params = @{} })
            $answer = Read-Request
            $refusal = $answer['error']
            $other = Get-LineBytes ([ordered]@{ id = 999; result = @{} })
            $mine = Get-LineBytes ([ordered]@{
                    id = $id; result = [ordered]@{ answered = $answer['id']; code = $refusal['code']; message = $refusal['message'] }
                })
            Write-Raw ([byte[]]($other + $mine))
        }
        'garbled' { Write-Raw ([Text.Encoding]::UTF8.GetBytes("{not json`n")) }
        'fail' { Write-Line ([ordered]@{ id = $id; error = [ordered]@{ code = -32001; message = 'simulated refusal' } }) }
        'hang' { Start-Sleep -Seconds 120 }
    }
}
'@
    $lineDead = [IO.Path]::Combine($lineRoot, 'dead.ps1')
    [IO.File]::WriteAllText($lineDead, "[Console]::Error.WriteLine('fatal: simulated bad flag')`nexit 7`n")

    $lineStart = @{
        Executable       = $linePwsh
        Arguments        = @('-NoProfile', '-NonInteractive', '-File', $lineServer)
        WorkingDirectory = $lineRoot
        Environment      = @{ BRIDGE_TEST_LINE = 'from-bridge' }
    }
    $lineChild = Start-BridgeJsonLineProcess @lineStart

    $lineEchoed = Invoke-FakeLineRequest -Method 'echo' -Params ([ordered]@{ text = 'Café ☕'; n = 3 })
    Test-That 'a line that arrives in pieces, one of them ending inside a character, is read whole' {
        $lineEchoed -is [Collections.IDictionary] -and $lineEchoed['params']['text'] -ceq 'Café ☕' -and
            $lineEchoed['params']['n'] -eq 3
    } (Format-FakeLineAnswer -Answer $lineEchoed)
    Test-That 'a request is its id, method and params, with no "jsonrpc" member' {
        $lineEchoed -is [Collections.IDictionary] -and $lineEchoed['keys'] -ceq 'id,method,params'
    } (Format-FakeLineAnswer -Answer $lineEchoed)

    $lineEnvironment = Invoke-FakeLineRequest -Method 'env'
    Test-That 'the child gets its own variables on top of the bridge''s, and starts in the folder it is given' {
        $lineEnvironment -is [Collections.IDictionary] -and $lineEnvironment['value'] -ceq 'from-bridge' -and
            $lineEnvironment['parent'] -ceq 'inherited' -and
            [IO.Path]::GetFileName($lineEnvironment['directory']) -ceq [IO.Path]::GetFileName($lineRoot)
    } (Format-FakeLineAnswer -Answer $lineEnvironment)

    $lineInterleaved = Invoke-FakeLineRequest -Method 'interleave'
    Test-That 'stray output, notifications and replies to other requests are passed over' {
        $lineInterleaved -is [Collections.IDictionary] -and $lineInterleaved['answered'] -ceq 'srv-1'
    } (Format-FakeLineAnswer -Answer $lineInterleaved)
    Test-That 'and a request from the child is refused rather than left waiting' {
        $lineInterleaved -is [Collections.IDictionary] -and $lineInterleaved['code'] -eq -32601 -and
            $lineInterleaved['message'] -ceq "agent-ha-bridge does not handle 'item/tool/requestUserInput'"
    } (Format-FakeLineAnswer -Answer $lineInterleaved)

    $lineGarbled = Invoke-FakeLineRequest -Method 'garbled'
    Test-That 'a line that starts like JSON but is not fails the request, saying what arrived' {
        $lineGarbled -is [Exception] -and $lineGarbled.Message -match 'not a JSON object' -and
            $lineGarbled.Message -match '\{not json'
    } (Format-FakeLineAnswer -Answer $lineGarbled)

    $lineRefusal = Invoke-FakeLineRequest -Method 'fail'
    Test-That 'an error reply throws its message and code, on a connection that outlived the bad line' {
        $lineRefusal -is [Exception] -and $lineRefusal.Message -ceq "'fail' failed: simulated refusal (code -32001)" -and
            $lineRefusal.Data['JsonRpcCode'] -eq -32001
    } (Format-FakeLineAnswer -Answer $lineRefusal)

    $lineClock = [Diagnostics.Stopwatch]::StartNew()
    $lineHung = Invoke-FakeLineRequest -Method 'hang' -Deadline ([DateTimeOffset]::Now.AddMilliseconds(1500))
    $lineClock.Stop()
    Test-That 'a child that never answers times out at the deadline' {
        $lineHung -is [Exception] -and $lineHung.GetBaseException() -is [TimeoutException] -and
            $lineHung.Message -match "the answer to 'hang'" -and $lineClock.Elapsed.TotalSeconds -lt 15
    } "$(Format-FakeLineAnswer -Answer $lineHung) after $([int]$lineClock.Elapsed.TotalSeconds)s"
    $lineClock.Restart()
    $lineStop = Stop-BridgeJsonRpcProcess -Connection $lineChild -GraceMs 500
    $lineClock.Stop()
    $lineChild = $null
    Test-That 'and is killed when it does not exit once its input closes' {
        $lineStop.Exited -and $lineStop.Killed -and $lineClock.Elapsed.TotalSeconds -lt 15
    } "$(ConvertTo-Json -InputObject $lineStop -Compress) after $([int]$lineClock.Elapsed.TotalSeconds)s"

    $lineChild = Start-BridgeJsonLineProcess -Executable $linePwsh -Arguments @('-NoProfile', '-NonInteractive', '-File', $lineDead)
    $lineDied = Invoke-FakeLineRequest -Method 'initialize'
    Test-That 'a child that exits at once fails the request with its exit code and what it printed' {
        $lineDied -is [Exception] -and $lineDied.Message -match 'code 7' -and $lineDied.Message -match 'simulated bad flag'
    } (Format-FakeLineAnswer -Answer $lineDied)
    $lineStop = Stop-BridgeJsonRpcProcess -Connection $lineChild
    $lineChild = $null
    Test-That 'and stopping it afterwards finds it already gone' {
        $lineStop.Exited -and -not $lineStop.Killed
    } (ConvertTo-Json -InputObject $lineStop -Compress)

    # The probes themselves, the real Get-BridgeClaudeModelRoster and
    # Get-BridgeCodexModelRoster, with only the process they start swapped: a scripted
    # CLI answering as that one does, in the mode FAKE_MODE names, and logging every
    # line it is sent.
    $script:LineStarts = [Collections.Generic.List[object]]::new()
    $script:FakeCliMode = ''
    $script:FakeCliLog = [IO.Path]::Combine($lineRoot, 'requests.log')
    $script:FakeCodexHome = [IO.Path]::Combine($lineRoot, 'codex-home')
    $script:FakeCliScript = ''
    $script:FakeCliScripts = @{}
    $script:FakeCliScripts['claude'] = New-FakeLineScript -Name 'claude.ps1' -Body @'
if ($env:FAKE_MODE -eq 'claude-old') {
    [Console]::Error.WriteLine("error: unknown option '--safe-mode'")
    exit 1
}
function Get-Model([string]$Value, [string[]]$Effort) {
    [ordered]@{ value = $Value; displayName = $Value; description = "$Value model"; supportsEffort = $true; supportedEffortLevels = @($Effort) }
}
$request = Read-Request
$requestId = $request['request_id']
if ($env:FAKE_MODE -eq 'claude-error') {
    Write-Line ([ordered]@{
            type = 'control_response'
            response = [ordered]@{ subtype = 'error'; request_id = $requestId; error = 'simulated initialize failure' }
        })
    Wait-End
}
# Other traffic first, as the real CLI sends: a status line, and the answer to some
# other request.
Write-Line ([ordered]@{ type = 'system'; subtype = 'status' })
Write-Line ([ordered]@{ type = 'control_response'; response = [ordered]@{ subtype = 'success'; request_id = 'req_0_other'; response = @{} } })
$models = @(
    (Get-Model 'default' @('low', 'medium', 'high', 'xhigh', 'max'))
    (Get-Model 'opus' @('low', 'medium', 'high', 'xhigh', 'max'))
    (Get-Model 'sonnet' @('low', 'medium', 'high'))
    (Get-Model 'haiku' @('low', 'medium', 'high'))
)
Write-Line ([ordered]@{
        type = 'control_response'
        response = [ordered]@{ subtype = 'success'; request_id = $requestId; response = [ordered]@{ commands = @(); models = $models } }
    })
if ($env:FAKE_MODE -eq 'claude-slow-exit') {
    # Still saving its settings when its input ends, as Claude is on a cold start, for
    # longer than the two seconds another probe gets to exit.
    while ($stdin.Read($chunk, 0, $chunk.Length) -gt 0) { }
    Start-Sleep -Milliseconds 3000
    [IO.File]::AppendAllText($env:FAKE_LOG, "{`"saved`":true}`n")
    exit 0
}
Wait-End
'@
    $script:FakeCliScripts['codex'] = New-FakeLineScript -Name 'codex.ps1' -Body @'
function Get-Effort([string[]]$Name) { @($Name | ForEach-Object { [ordered]@{ reasoningEffort = $_; description = "$_ effort" } }) }
function Get-Entry([string]$Name, [string[]]$Effort, [bool]$Hidden = $false) {
    [ordered]@{ id = $Name; model = $Name; displayName = $Name; hidden = $Hidden; supportedReasoningEfforts = @(Get-Effort $Effort) }
}
# What Codex leaves in its home once it has fetched the account's list: when, for which
# sign-in, and the models in it, hidden ones too. The modes leave it out, age it, drop
# the sign-in, or list other models, as a failed or an older fetch would, or another
# Codex sharing the home.
function Write-ModelCache {
    if ($env:FAKE_MODE -eq 'codex-no-cache') { return }
    $fetched = [DateTimeOffset]::UtcNow
    if ($env:FAKE_MODE -eq 'codex-stale') { $fetched = $fetched.AddSeconds(-301) }
    # Codex writes as many fractional digits as it has, up to nine.
    $format = if ($env:FAKE_MODE -eq 'codex-nanos') { "yyyy-MM-dd'T'HH:mm:ss.fffffff'00Z'" } else { "yyyy-MM-dd'T'HH:mm:ss.fff'Z'" }
    $cache = [ordered]@{ fetched_at = $fetched.ToString($format, [Globalization.CultureInfo]::InvariantCulture) }
    if ($env:FAKE_MODE -ne 'codex-no-identity') { $cache['identity'] = 'chatgpt:fake-account' }
    $cache['client_version'] = '0.0.0'
    $slugs = @('gpt-6.1-sol', 'gpt-6-astra', 'gpt-5.5')
    if ($env:FAKE_MODE -eq 'codex-other-list') { $slugs = @('gpt-6.1-sol', 'gpt-6-astra') }
    $cache['models'] = @($slugs | ForEach-Object { [ordered]@{ slug = $_; display_name = $_ } })
    [IO.File]::WriteAllText([IO.Path]::Combine($env:FAKE_CODEX_HOME, 'models_cache.json'), (ConvertTo-Json -InputObject $cache -Depth 4))
}
$request = Read-Request
$introduced = [ordered]@{ userAgent = 'codex/0' }
if ($env:FAKE_MODE -ne 'codex-no-home') { $introduced['codexHome'] = $env:FAKE_CODEX_HOME }
Write-Line ([ordered]@{ id = $request['id']; result = $introduced })
[void](Read-Request)
while ($true) {
    $request = Read-Request
    $id = $request['id']
    if ($request['method'] -ceq 'account/read') {
        $account = switch ($env:FAKE_MODE) {
            'codex-signed-out' { $null }
            'codex-apikey' { [ordered]@{ type = 'apiKey' } }
            default { [ordered]@{ type = 'chatgpt'; email = 'someone@example.com'; planType = 'pro' } }
        }
        Write-Line ([ordered]@{ id = $id; result = [ordered]@{ account = $account; requiresOpenaiAuth = $true } })
        continue
    }
    $params = $request['params']
    $cursor = if ($params -is [Collections.IDictionary] -and $params.Contains('cursor')) { $params['cursor'] } else { $null }
    if ($env:FAKE_MODE -eq 'codex-error') {
        Write-Line ([ordered]@{ id = $id; error = [ordered]@{ code = -32600; message = 'simulated refusal' } })
        continue
    }
    Write-ModelCache
    if ($env:FAKE_MODE -eq 'codex-loop') {
        # Handing back a cursor for ever.
        Write-Line ([ordered]@{ id = $id; result = [ordered]@{ data = @(Get-Entry 'gpt-6.1-sol' 'low'); nextCursor = 'again' } })
        continue
    }
    if ($cursor -eq 'page-2') {
        $page = @(Get-Entry 'gpt-5.5' 'low', 'medium', 'high', 'xhigh')
        Write-Line ([ordered]@{ id = $id; result = [ordered]@{ data = $page; nextCursor = $null } })
        continue
    }
    $page = @(
        (Get-Entry 'gpt-6.1-sol' 'low', 'medium', 'high', 'xhigh', 'max', 'ultra')
        (Get-Entry 'gpt-6-astra' 'mega' $true)
    )
    Write-Line ([ordered]@{ id = $id; result = [ordered]@{ data = $page; nextCursor = 'page-2' } })
}
'@
    function Start-BridgeJsonLineProcess {
        param(
            [string]$Executable,
            [string[]]$Arguments = @(),
            [AllowEmptyString()][AllowNull()][string]$WorkingDirectory = '',
            [AllowNull()][Collections.IDictionary]$Environment = $null
        )
        $script:LineStarts.Add([pscustomobject]@{
                Executable = $Executable; Arguments = @($Arguments); WorkingDirectory = $WorkingDirectory; Environment = $Environment
                Entries = if ([IO.Directory]::Exists($WorkingDirectory)) {
                    @([IO.Directory]::EnumerateFileSystemEntries($WorkingDirectory)).Count
                }
                else { -1 }
            })
        $childVariables = @{ FAKE_MODE = $script:FakeCliMode; FAKE_LOG = $script:FakeCliLog; FAKE_CODEX_HOME = $script:FakeCodexHome }
        if ($null -ne $Environment) { foreach ($name in @($Environment.Keys)) { $childVariables[$name] = $Environment[$name] } }
        $fake = @{
            Executable       = $script:linePwsh
            Arguments        = @('-NoProfile', '-NonInteractive', '-File', $script:FakeCliScript)
            WorkingDirectory = $WorkingDirectory
            Environment      = $childVariables
        }
        & $script:savedLineStart @fake
    }
    function Invoke-FakeLauncherProbe {
        param([string]$Launcher, [string]$Mode)
        $script:LineStarts.Clear()
        $script:FakeCliMode = $Mode
        $script:FakeCliScript = $script:FakeCliScripts[$Launcher]
        [IO.File]::WriteAllText($script:FakeCliLog, '')
        # An empty Codex home each time, so no probe reads a cache another one left.
        if ([IO.Directory]::Exists($script:FakeCodexHome)) { [IO.Directory]::Delete($script:FakeCodexHome, $true) }
        [void][IO.Directory]::CreateDirectory($script:FakeCodexHome)
        $script:LauncherProbeResult = $null
        $script:LauncherProbeError = ''
        try {
            $script:LauncherProbeResult = if ($Launcher -eq 'claude') {
                Get-BridgeClaudeModelRoster -Path 'C:\fake-claude.exe' -TimeoutMs 60000
            }
            else { Get-BridgeCodexModelRoster -Path 'C:\fake-codex.exe' -TimeoutMs 60000 }
        }
        catch { $script:LauncherProbeError = $_.Exception.Message }
        $script:LauncherProbeLines = @([IO.File]::ReadAllLines($script:FakeCliLog) | Where-Object { $_.Trim() } |
                ForEach-Object { ConvertFrom-Json -InputObject $_ -AsHashtable })
    }
    # The probe started one process, and its scratch folder is gone.
    function Test-FakeProbeCleanedUp {
        $script:LineStarts.Count -eq 1 -and
            -not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($script:LineStarts[0].WorkingDirectory))
    }
    # Details for a failure, which are worked out before the test runs: nothing here
    # may throw on a probe that went wrong.
    function Format-FakeProbeResult {
        if ($script:LauncherProbeError) { return "error: $($script:LauncherProbeError)" }
        ConvertTo-Json -InputObject $script:LauncherProbeResult -Compress -Depth 4
    }
    function Format-FakeProbeStart { ConvertTo-Json -InputObject @($script:LineStarts) -Compress -Depth 4 }
    function Format-FakeProbeLines { ConvertTo-Json -InputObject @($script:LauncherProbeLines) -Compress -Depth 6 }
    # Which model takes which efforts, by model, as 'model=effort+effort'.
    function Format-ModelEfforts {
        param([AllowNull()]$Map)
        if ($Map -isnot [Collections.IDictionary]) { return "not a map: $Map" }
        (@($Map.Keys | Sort-Object -CaseSensitive) | ForEach-Object { "$_=$(@($Map[$_]) -join '+')" }) -join ' '
    }

    Invoke-FakeLauncherProbe -Launcher 'claude' -Mode 'claude'
    Test-That 'Claude''s probe offers the models its picker lists, less default, and every effort one of them takes' {
        $null -ne $script:LauncherProbeResult -and
            (@($script:LauncherProbeResult.Models) -join ',') -ceq 'opus,sonnet,haiku' -and
            (@($script:LauncherProbeResult.Efforts) -join ',') -ceq 'low,medium,high,xhigh,max'
    } (Format-FakeProbeResult)
    Test-That 'and keeps which of those efforts each model takes' {
        $null -ne $script:LauncherProbeResult -and $script:LauncherProbeResult.EffortsKnown -eq $true -and
            (Format-ModelEfforts $script:LauncherProbeResult.ModelEfforts) -ceq
            'haiku=low+medium+high opus=low+medium+high+xhigh+max sonnet=low+medium+high'
    } (Format-FakeProbeResult)
    Test-That 'it starts Claude as the SDK does but inert, leaving updates to Claude''s own sessions' {
        $launched = $script:LineStarts[0]
        $script:LineStarts.Count -eq 1 -and $launched.Executable -ceq 'C:\fake-claude.exe' -and
            ($launched.Arguments -join ' ') -ceq ('-p --input-format stream-json --output-format stream-json --verbose ' +
                '--safe-mode --no-session-persistence --strict-mcp-config') -and
            $launched.Environment['DISABLE_AUTOUPDATER'] -ceq '1'
    } (Format-FakeProbeStart)
    Test-That 'in an empty scratch folder of its own, which is gone afterwards' {
        $launched = $script:LineStarts[0]
        $launched.Entries -eq 0 -and [IO.Path]::GetFileName($launched.WorkingDirectory) -ceq 'wd' -and
            [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($launched.WorkingDirectory)) -like 'agent-bridge-models-*' -and
            (Test-FakeProbeCleanedUp)
    } (Format-FakeProbeStart)
    Test-That 'and sends nothing but the initialize request, in the SDK''s form and with no hooks' {
        $sent = $script:LauncherProbeLines
        $sent.Count -eq 1 -and $sent[0]['type'] -ceq 'control_request' -and
            $sent[0]['request_id'] -cmatch '^req_1_[0-9a-f]{8}\z' -and
            $sent[0]['request']['subtype'] -ceq 'initialize' -and
            $sent[0]['request'].Contains('hooks') -and $null -eq $sent[0]['request']['hooks']
    } (Format-FakeProbeLines)

    Invoke-FakeLauncherProbe -Launcher 'claude' -Mode 'claude-error'
    Test-That 'a Claude that refuses initialize fails the probe with its reason, and the folder still goes' {
        $script:LauncherProbeError -ceq "'initialize' failed: simulated initialize failure" -and (Test-FakeProbeCleanedUp)
    } (Format-FakeProbeResult)
    Invoke-FakeLauncherProbe -Launcher 'claude' -Mode 'claude-slow-exit'
    Test-That 'a Claude still saving its settings once it has answered is left to finish rather than killed' {
        $null -ne $script:LauncherProbeResult -and
            @($script:LauncherProbeLines | Where-Object { $_['saved'] -eq $true }).Count -eq 1 -and (Test-FakeProbeCleanedUp)
    } "$(Format-FakeProbeResult) $(Format-FakeProbeLines)"
    Invoke-FakeLauncherProbe -Launcher 'claude' -Mode 'claude-old'
    Test-That 'a Claude too old for --safe-mode fails it with its exit code and what it printed' {
        $script:LauncherProbeError -match 'code 1\b' -and $script:LauncherProbeError -match "unknown option '--safe-mode'" -and
            (Test-FakeProbeCleanedUp)
    } (Format-FakeProbeResult)

    Invoke-FakeLauncherProbe -Launcher 'codex' -Mode 'codex'
    Test-That 'Codex''s probe pages through model/list, offering each visible model and every effort one takes' {
        $null -ne $script:LauncherProbeResult -and
            (@($script:LauncherProbeResult.Models) -join ',') -ceq 'gpt-6.1-sol,gpt-5.5' -and
            (@($script:LauncherProbeResult.Efforts) -join ',') -ceq 'low,medium,high,xhigh,max,ultra'
    } (Format-FakeProbeResult)
    Test-That 'and keeps which of those efforts each model takes' {
        $null -ne $script:LauncherProbeResult -and $script:LauncherProbeResult.EffortsKnown -eq $true -and
            (Format-ModelEfforts $script:LauncherProbeResult.ModelEfforts) -ceq
            'gpt-5.5=low+medium+high+xhigh gpt-6.1-sol=low+medium+high+xhigh+max+ultra'
    } (Format-FakeProbeResult)
    Test-That 'it starts the app-server with plugins off and nothing more, in an empty scratch folder that is gone afterwards' {
        $launched = $script:LineStarts[0]
        $launched.Executable -ceq 'C:\fake-codex.exe' -and ($launched.Arguments -join ' ') -ceq '-c features.plugins=false app-server' -and
            $null -eq $launched.Environment -and $launched.Entries -eq 0 -and (Test-FakeProbeCleanedUp)
    } (Format-FakeProbeStart)
    Test-That 'introduces the bridge, asks how Codex is signed in without renewing it, then asks for each page by the cursor the one before gave' {
        $sent = $script:LauncherProbeLines
        (@($sent | ForEach-Object { $_['method'] }) -join ',') -ceq 'initialize,initialized,account/read,model/list,model/list' -and
            $sent[0]['params']['clientInfo']['name'] -ceq 'agent-ha-bridge' -and -not $sent[1].Contains('id') -and
            $sent[2]['params'] -is [Collections.IDictionary] -and $sent[2]['params'].Count -eq 0 -and
            $sent[3]['params'] -is [Collections.IDictionary] -and $sent[3]['params'].Count -eq 0 -and
            $sent[4]['params']['cursor'] -ceq 'page-2'
    } (Format-FakeProbeLines)

    # model/list does not say whose list it is: signed out, or with its fetch failing,
    # Codex answers with the models built into it. Only a ChatGPT sign-in, with a
    # cache fetched for it in the last five minutes, is taken.
    $codexRefusals = [ordered]@{}
    foreach ($mode in 'codex-signed-out', 'codex-apikey') {
        Invoke-FakeLauncherProbe -Launcher 'codex' -Mode $mode
        $codexRefusals[$mode] = [pscustomobject]@{
            Error = $script:LauncherProbeError; Listed = @($script:LauncherProbeLines | Where-Object { $_['method'] -ceq 'model/list' }).Count
            CleanedUp = [bool](Test-FakeProbeCleanedUp)
        }
    }
    Test-That 'a Codex signed out, or signed in with an API key, is not asked for its list, and the folder still goes' {
        $codexRefusals['codex-signed-out'].Error -ceq ('Codex is signed out rather than with ChatGPT, so its model list may be ' +
            "the one built into it rather than the account's") -and
            $codexRefusals['codex-apikey'].Error -ceq ("Codex is signed in with 'apiKey' rather than with ChatGPT, so its model " +
                "list may be the one built into it rather than the account's") -and
            @($codexRefusals.Values | Where-Object { $_.Listed -ne 0 -or -not $_.CleanedUp }).Count -eq 0
    } (ConvertTo-Json -InputObject $codexRefusals -Compress)

    $codexUnconfirmed = [ordered]@{}
    foreach ($mode in 'codex-no-cache', 'codex-stale', 'codex-no-identity', 'codex-other-list') {
        Invoke-FakeLauncherProbe -Launcher 'codex' -Mode $mode
        $codexUnconfirmed[$mode] = $script:LauncherProbeError.Replace(
            [IO.Path]::Combine($script:FakeCodexHome, 'models_cache.json'), '<cache>')
    }
    $unconfirmedPrefix = "^could not confirm that Codex fetched this account's models: '<cache>' "
    $unconfirmedSuffix = '\. Offline, Codex lists the models built into it instead\z'
    Test-That 'a list Codex''s cache does not show it fetched - none written, written over five minutes before, for no sign-in, or without a model it offers - is not taken' {
        $codexUnconfirmed['codex-no-cache'] -cmatch "${unconfirmedPrefix}does not exist$unconfirmedSuffix" -and
            $codexUnconfirmed['codex-stale'] -cmatch "${unconfirmedPrefix}was fetched 3\d\ds before the list, and Codex keeps it 300s$unconfirmedSuffix" -and
            $codexUnconfirmed['codex-no-identity'] -cmatch "${unconfirmedPrefix}names no sign-in$unconfirmedSuffix" -and
            $codexUnconfirmed['codex-other-list'] -cmatch "${unconfirmedPrefix}does not list gpt-5\.5, which Codex answered with$unconfirmedSuffix"
    } ($codexUnconfirmed.Values -join ' | ')
    Invoke-FakeLauncherProbe -Launcher 'codex' -Mode 'codex-nanos'
    Test-That 'a cache dated to the nanosecond, as Codex can write it, is read' {
        $null -ne $script:LauncherProbeResult -and (@($script:LauncherProbeResult.Models) -join ',') -ceq 'gpt-6.1-sol,gpt-5.5'
    } (Format-FakeProbeResult)
    $savedCodexHome = $env:CODEX_HOME
    $env:CODEX_HOME = $script:FakeCodexHome
    try { Invoke-FakeLauncherProbe -Launcher 'codex' -Mode 'codex-no-home' }
    finally {
        if ($null -eq $savedCodexHome) { Remove-Item -LiteralPath 'Env:CODEX_HOME' -ErrorAction SilentlyContinue }
        else { $env:CODEX_HOME = $savedCodexHome }
    }
    Test-That 'a Codex that does not say where its home is has its cache looked for under CODEX_HOME' {
        $null -ne $script:LauncherProbeResult -and (@($script:LauncherProbeResult.Models) -join ',') -ceq 'gpt-6.1-sol,gpt-5.5'
    } (Format-FakeProbeResult)

    # The freshness check on its own: a cache written as each case needs, against a
    # list answered at 12:05:00 UTC.
    $cacheCheckPath = [IO.Path]::Combine($lineRoot, 'cache-check', 'models_cache.json')
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($cacheCheckPath))
    function Test-FakeCodexCache {
        param([AllowNull()]$Content, [AllowEmptyCollection()][string[]]$Model = @())
        if ($null -eq $Content) { [IO.File]::Delete($cacheCheckPath) } else { [IO.File]::WriteAllText($cacheCheckPath, $Content) }
        try {
            $emitted = @(Assert-BridgeCodexModelCacheFresh -Path $cacheCheckPath -ListedAt ([DateTimeOffset]::new(2026, 10, 8, 12, 5, 0, [TimeSpan]::Zero)) -Model $Model)
            if ($emitted.Count -eq 0) { 'fresh' } else { "emitted $($emitted -join ',')" }
        }
        catch {
            $match = [regex]::Match($_.Exception.Message, ("^could not confirm that Codex fetched this account's models: (.*)\. " +
                    'Offline, Codex lists the models built into it instead\z'))
            if ($match.Success) { $match.Groups[1].Value.Replace($cacheCheckPath, '<cache>') } else { "unexpected: $($_.Exception.Message)" }
        }
    }
    $cacheChecks = [ordered]@{
        'ten seconds before'      = '{"fetched_at":"2026-10-08T12:04:50.123Z","identity":"chatgpt:a"}'
        'to the nanosecond'       = '{"fetched_at":"2026-10-08T12:04:50.123456789Z","identity":"chatgpt:a"}'
        'just under five minutes' = '{"fetched_at":"2026-10-08T12:00:00.001Z","identity":"chatgpt:a"}'
        'five minutes'            = '{"fetched_at":"2026-10-08T12:00:00Z","identity":"chatgpt:a"}'
        'a second more'           = '{"fetched_at":"2026-10-08T11:59:59Z","identity":"chatgpt:a"}'
        'the same instant'        = '{"fetched_at":"2026-10-08T12:05:00Z","identity":"chatgpt:a"}'
        'a millisecond after'     = '{"fetched_at":"2026-10-08T12:05:00.001Z","identity":"chatgpt:a"}'
        'dated after'             = '{"fetched_at":"2026-10-08T12:11:40Z","identity":"chatgpt:a"}'
        'missing'                 = $null
        'not JSON'                = 'not json'
        'not an object'           = '[1,2]'
        'no sign-in'              = '{"fetched_at":"2026-10-08T12:04:50Z"}'
        'an empty sign-in'        = '{"fetched_at":"2026-10-08T12:04:50Z","identity":""}'
        'a numeric sign-in'       = '{"fetched_at":"2026-10-08T12:04:50Z","identity":42}'
        'no time'                 = '{"identity":"chatgpt:a"}'
        'not a time'              = '{"fetched_at":"soon","identity":"chatgpt:a"}'
        'a numeric time'          = '{"fetched_at":1760000000,"identity":"chatgpt:a"}'
    }
    $cacheVerdicts = [ordered]@{}
    foreach ($case in @($cacheChecks.Keys)) { $cacheVerdicts[$case] = Test-FakeCodexCache -Content $cacheChecks[$case] }
    $cacheVerdictText = (@($cacheVerdicts.Keys) | ForEach-Object { "${_}: $($cacheVerdicts[$_])" }) -join ' | '
    Test-That 'Codex''s cache confirms a list when it names a sign-in and was fetched under five minutes before it, to any precision, and never after it' {
        $cacheVerdicts['ten seconds before'] -ceq 'fresh' -and $cacheVerdicts['to the nanosecond'] -ceq 'fresh' -and
            $cacheVerdicts['just under five minutes'] -ceq 'fresh' -and
            $cacheVerdicts['five minutes'] -ceq "'<cache>' was fetched 300s before the list, and Codex keeps it 300s" -and
            $cacheVerdicts['a second more'] -ceq "'<cache>' was fetched 301s before the list, and Codex keeps it 300s" -and
            $cacheVerdicts['the same instant'] -ceq 'fresh' -and
            $cacheVerdicts['a millisecond after'] -ceq "'<cache>' is dated 0.001s after the list" -and
            $cacheVerdicts['dated after'] -ceq "'<cache>' is dated 400s after the list"
    } $cacheVerdictText
    Test-That 'and says what is wrong with one that is missing, unreadable, or lacks either' {
        $cacheVerdicts['missing'] -ceq "'<cache>' does not exist" -and
            $cacheVerdicts['not JSON'] -clike "'<cache>' could not be read (?*)" -and
            $cacheVerdicts['not JSON'] -cnotlike '*Exception calling*' -and
            $cacheVerdicts['not an object'] -clike "'<cache>' could not be read (?*)" -and
            @('no sign-in', 'an empty sign-in', 'a numeric sign-in' |
                    Where-Object { $cacheVerdicts[$_] -cne "'<cache>' names no sign-in" }).Count -eq 0 -and
            @('no time', 'not a time', 'a numeric time' |
                    Where-Object { $cacheVerdicts[$_] -cne "'<cache>' does not say when it was fetched" }).Count -eq 0
    } $cacheVerdictText

    # And its models, against a list answered with gpt-a and gpt-b: the time alone
    # cannot tell a file written for the answer from one another Codex sharing the
    # home wrote just after it.
    $cacheModelHead = '{"fetched_at":"2026-10-08T12:04:50Z","identity":"chatgpt:a"'
    $cacheModelChecks = [ordered]@{
        'every model'       = $cacheModelHead + ',"models":[{"slug":"gpt-b"},{"slug":"gpt-c","visibility":"hide"},{"slug":"gpt-a"}]}'
        'one missing'       = $cacheModelHead + ',"models":[{"slug":"gpt-a"},{"slug":"GPT-B"}]}'
        'no models'         = $cacheModelHead + '}'
        'models not a list' = $cacheModelHead + ',"models":{"slug":"gpt-a"}}'
        'no slugs'          = $cacheModelHead + ',"models":["gpt-a",{"slug":1},{"id":"gpt-b"},{"model":{"slug":"gpt-b"}}]}'
    }
    $cacheModelVerdicts = [ordered]@{}
    foreach ($case in @($cacheModelChecks.Keys)) {
        $cacheModelVerdicts[$case] = Test-FakeCodexCache -Content $cacheModelChecks[$case] -Model 'gpt-a', 'gpt-b'
    }
    Test-That 'and only once it lists, by its exact name, every model the bridge keeps from the answer, saying which it lacks' {
        $cacheModelVerdicts['every model'] -ceq 'fresh' -and
            $cacheModelVerdicts['one missing'] -ceq "'<cache>' does not list gpt-b, which Codex answered with" -and
            @('no models', 'models not a list', 'no slugs' | Where-Object {
                    $cacheModelVerdicts[$_] -cne "'<cache>' does not list gpt-a, gpt-b, which Codex answered with" }).Count -eq 0
    } ((@($cacheModelVerdicts.Keys) | ForEach-Object { "${_}: $($cacheModelVerdicts[$_])" }) -join ' | ')

    Invoke-FakeLauncherProbe -Launcher 'codex' -Mode 'codex-loop'
    Test-That 'a server handing back a cursor for ever is asked ten pages at most, and what came is kept' {
        @($script:LauncherProbeLines | Where-Object { $_['method'] -ceq 'model/list' }).Count -eq 10 -and
            $null -ne $script:LauncherProbeResult -and (@($script:LauncherProbeResult.Models) -join ',') -ceq 'gpt-6.1-sol'
    } (Format-FakeProbeResult)
    Invoke-FakeLauncherProbe -Launcher 'codex' -Mode 'codex-error'
    Test-That 'a refused model/list fails the probe with the refusal and its code, and the folder still goes' {
        $script:LauncherProbeError -ceq "'model/list' failed: simulated refusal (code -32600)" -and (Test-FakeProbeCleanedUp)
    } (Format-FakeProbeResult)

    # What each keeps of an answer, against shapes neither CLI should send but nothing
    # stops one sending: a value reaches a command line, so only a plain name is kept.
    $claudeConverted = $(try {
            ConvertFrom-BridgeClaudeModelRoster -Roster @{ models = @(
                    @{ value = 'default'; supportsEffort = $true; supportedEffortLevels = @('low', 'medium', 'high', 'xhigh', 'max', 'turbo') }
                    @{ value = 'opus'; supportsEffort = $true; supportedEffortLevels = @('low', 'medium', 'high', 'xhigh', 'max') }
                    @{ value = 'sonnet[1m]'; supportedEffortLevels = @('high') }
                    @{ value = 'us.anthropic.claude-opus-5:0'; supportedEffortLevels = @('high') }
                    @{ value = 'haiku'; supportsEffort = $false; supportedEffortLevels = @('ultra') }
                    @{ value = 'sonnet'; supportedEffortLevels = @('true', 'HIGH', 'x y', 'minimal', 42, 'low') }
                    @{ value = 'opus' }
                    @{ value = '-p' }
                    @{ value = 42 }
                    'not-an-object'
                ) }
        }
        catch { $_.Exception.Message })
    Test-That 'Claude''s list keeps plain names once each, and the efforts of every entry that takes one' {
        $claudeConverted -isnot [string] -and (@($claudeConverted.Models) -join ',') -ceq 'opus,haiku,sonnet' -and
            (@($claudeConverted.Efforts) -join ',') -ceq 'minimal,low,medium,high,xhigh,max,turbo'
    } (ConvertTo-Json -InputObject $claudeConverted -Compress -Depth 4)
    Test-That 'and each offered model''s own, none for one that takes none, and default''s with no model of its own' {
        $claudeConverted -isnot [string] -and $claudeConverted.EffortsKnown -eq $true -and
            (Format-ModelEfforts $claudeConverted.ModelEfforts) -ceq 'haiku= opus=low+medium+high+xhigh+max sonnet=minimal+low'
    } (ConvertTo-Json -InputObject $claudeConverted -Compress -Depth 4)
    $claudeEffortCases = foreach ($models in @(
            , @(@{ value = 'opus' }, @{ value = 'sonnet'; supportsEffort = $true })
            , @(@{ value = 'opus'; supportsEffort = $false }, @{ value = 'haiku'; supportsEffort = $false; supportedEffortLevels = @('high') })
        )) {
        $converted = ConvertFrom-BridgeClaudeModelRoster -Roster @{ models = $models }
        "$($converted.EffortsKnown):$(@($converted.Efforts) -join '+'):$(Format-ModelEfforts $converted.ModelEfforts)"
    }
    Test-That 'a list that never says what effort a model takes leaves efforts unknown, and one where none takes any knows that' {
        ($claudeEffortCases -join ' | ') -ceq 'False:: | True::haiku= opus='
    } ($claudeEffortCases -join ' | ')
    $claudeShapeErrors = @(@{ models = 'opus' }, @{ models = @{ value = 'opus' } }, @{} | ForEach-Object {
            $roster = $_
            try { [void](ConvertFrom-BridgeClaudeModelRoster -Roster $roster); 'no error' } catch { $_.Exception.Message }
        })
    Test-That 'an answer without a model list, or with one of the wrong shape, is an error rather than an empty list' {
        $claudeShapeErrors.Count -eq 3 -and
            @($claudeShapeErrors | Where-Object { $_ -cne 'Claude answered without a model list' }).Count -eq 0
    } ($claudeShapeErrors -join ' | ')
    $claudeNothingUsable = $(try {
            ConvertFrom-BridgeClaudeModelRoster -Roster @{ models = @(@{ value = 'default' }, @{ value = 'sonnet[1m]' }) }
        }
        catch { $_.Exception.Message })
    Test-That 'and so is a list with nothing worth offering, saying how many entries it had' {
        $claudeNothingUsable -ceq 'Claude listed no usable models (2 entries)'
    } "$claudeNothingUsable"

    $codexConverted = $(try {
            ConvertFrom-BridgeCodexModelRoster -Entry @(
                @{ id = 'gpt-6.1-sol'; model = 'gpt-6.1-sol'; hidden = $false
                    supportedReasoningEfforts = @(@{ reasoningEffort = 'low' }, @{ reasoningEffort = 'ultra' })
                }
                @{ id = 'gpt-6-astra'; model = 'gpt-6-astra'; hidden = $true; supportedReasoningEfforts = @(@{ reasoningEffort = 'mega' }) }
                @{ id = 'gpt-5.5'; supportedReasoningEfforts = @('medium', 'xhigh', 'inf') }
                @{ id = 'x'; model = 'gpt-6.1-sol' }
                @{ model = 'bad name' }
                @{ model = 'ollama/llama3' }
            )
        }
        catch { $_.Exception.Message })
    Test-That 'Codex''s list leaves hidden models out, names one by its id when it has no model, and keeps plain names once each' {
        $codexConverted -isnot [string] -and (@($codexConverted.Models) -join ',') -ceq 'gpt-6.1-sol,gpt-5.5' -and
            (@($codexConverted.Efforts) -join ',') -ceq 'low,medium,xhigh,ultra'
    } (ConvertTo-Json -InputObject $codexConverted -Compress -Depth 4)
    Test-That 'and each listed model''s own efforts, the first entry for a name being the one kept' {
        $codexConverted -isnot [string] -and $codexConverted.EffortsKnown -eq $true -and
            (Format-ModelEfforts $codexConverted.ModelEfforts) -ceq 'gpt-5.5=medium+xhigh gpt-6.1-sol=low+ultra'
    } (ConvertTo-Json -InputObject $codexConverted -Compress -Depth 4)
    $codexEffortCases = foreach ($entries in @(
            , @(@{ model = 'gpt-6.1-sol' }, @{ model = 'gpt-5.5'; supportedReasoningEfforts = 'high' })
            , @(@{ model = 'gpt-6.1-sol'; supportedReasoningEfforts = @() }, @{ model = 'gpt-5.5' })
        )) {
        $converted = ConvertFrom-BridgeCodexModelRoster -Entry $entries
        "$($converted.EffortsKnown):$(@($converted.Efforts) -join '+'):$(Format-ModelEfforts $converted.ModelEfforts)"
    }
    Test-That 'models listed without their efforts leave efforts unknown, and one listed as taking none knows that' {
        ($codexEffortCases -join ' | ') -ceq 'False:: | True::gpt-6.1-sol='
    } ($codexEffortCases -join ' | ')
    $codexEmpty = $(try { ConvertFrom-BridgeCodexModelRoster -Entry @() } catch { $_.Exception.Message })
    $codexAllHidden = $(try {
            ConvertFrom-BridgeCodexModelRoster -Entry @(@{ model = 'gpt-6-astra'; hidden = $true })
        }
        catch { $_.Exception.Message })
    Test-That 'an empty list, or one of hidden models only, is an error saying how many entries it had' {
        $codexEmpty -ceq 'Codex listed no usable models (0 entries)' -and
            $codexAllHidden -ceq 'Codex listed no usable models (1 entries)'
    } "$codexEmpty | $codexAllHidden"

    # The cache in front of both, read through the selectors. One answer fills a
    # launcher's model and effort lists, and is kept and retried as Copilot's is.
    $script:LauncherRosterCalls = @{ claude = 0; codex = 0 }
    $script:LauncherRosterPath = @{ claude = ''; codex = '' }
    $script:LauncherRosterFailure = @{ claude = $null; codex = $null }
    $script:LauncherRoster = @{
        claude = [pscustomobject]@{
            Models = @('opus', 'sonnet'); Efforts = @('low', 'high')
            EffortsKnown = $true; ModelEfforts = @{ opus = @('low', 'high'); sonnet = @('low') }
        }
        codex  = [pscustomobject]@{
            Models = @('gpt-6.1-sol'); Efforts = @('medium', 'ultra')
            EffortsKnown = $true; ModelEfforts = @{ 'gpt-6.1-sol' = @('medium', 'ultra') }
        }
    }
    function Get-FakeLauncherRoster {
        param([string]$Launcher, [string]$Path)
        $script:LauncherRosterCalls[$Launcher]++
        $script:LauncherRosterPath[$Launcher] = $Path
        if ($script:LauncherRosterFailure[$Launcher]) { throw $script:LauncherRosterFailure[$Launcher] }
        $script:LauncherRoster[$Launcher]
    }
    function Get-BridgeClaudeModelRoster {
        param([string]$Path, [int]$TimeoutMs = 20000)
        Get-FakeLauncherRoster -Launcher 'claude' -Path $Path
    }
    function Get-BridgeCodexModelRoster {
        param([string]$Path, [int]$TimeoutMs = 20000)
        Get-FakeLauncherRoster -Launcher 'codex' -Path $Path
    }
    $script:FakeClaudeExe = 'C:\fake-claude.exe'
    function Get-BridgeClaudePath { $script:FakeClaudeExe }
    function Get-BridgeCodexPath { 'C:\fake-codex.exe' }
    function Get-LastLauncherModelLog {
        param([string]$Label)
        if (-not (Test-Path -LiteralPath $script:testLogFile)) { return '' }
        [string](@(Get-Content -LiteralPath $script:testLogFile | Where-Object { $_ -match "$Label model discovery" }) |
                Select-Object -Last 1)
    }
    function Get-LastLauncherModelRetry {
        param([string]$Label)
        [int][regex]::Match((Get-LastLauncherModelLog -Label $Label), 'retrying in (\d+)s').Groups[1].Value
    }

    $script:FakeSettings = @{}
    $script:BridgeLauncherModelCache = @{}
    $claudeModelChoices = @(Get-BridgeTuningOptions -Launcher 'claude' -Axis 'model')
    $claudeCallsAfterModels = $script:LauncherRosterCalls['claude']
    $claudeEffortChoices = @(Get-BridgeTuningOptions -Launcher 'claude' -Axis 'effort')
    Test-That 'a cold start asks Claude once, and offers the models it lists instead of the built-in ones' {
        ($claudeModelChoices -join ',') -ceq 'Agent default,opus,sonnet' -and $claudeCallsAfterModels -eq 1 -and
            $script:LauncherRosterPath['claude'] -ceq 'C:\fake-claude.exe'
    } ($claudeModelChoices -join ',')
    Test-That 'and the efforts from the same answer, without asking again' {
        ($claudeEffortChoices -join ',') -ceq 'Agent default,low,high' -and $script:LauncherRosterCalls['claude'] -eq 1
    } "$($claudeEffortChoices -join ',') after $($script:LauncherRosterCalls['claude']) call(s)"
    Test-That 'a listed model is accepted from Home Assistant, and a built-in one Claude did not list is not' {
        (Resolve-BridgeTuningValue -Launcher 'claude' -Axis 'model' -Value 'sonnet') -ceq 'sonnet' -and
            (Resolve-BridgeTuningValue -Launcher 'claude' -Axis 'model' -Value 'fable') -ceq ''
    }
    $codexModelChoices = @(Get-BridgeTuningOptions -Launcher 'codex' -Axis 'model')
    $codexEffortChoices = @(Get-BridgeTuningOptions -Launcher 'codex' -Axis 'effort')
    Test-That 'Codex is asked on its own, and its answer fills both of its lists' {
        ($codexModelChoices -join ',') -ceq 'Agent default,gpt-6.1-sol' -and
            ($codexEffortChoices -join ',') -ceq 'Agent default,medium,ultra' -and
            $script:LauncherRosterCalls['codex'] -eq 1 -and $script:LauncherRosterPath['codex'] -ceq 'C:\fake-codex.exe'
    } "$($codexModelChoices -join ',') / $($codexEffortChoices -join ',')"

    $script:BridgeLauncherModelCache['claude'].At = [DateTimeOffset]::Now.AddHours(-5)
    [void](Get-BridgeTuningOptions -Launcher 'claude' -Axis 'model')
    Test-That 'the answer is reused for hours' { $script:LauncherRosterCalls['claude'] -eq 1 }
    $script:BridgeLauncherModelCache['claude'].At = [DateTimeOffset]::Now.AddHours(-6).AddSeconds(-1)
    [void](Get-BridgeTuningOptions -Launcher 'claude' -Axis 'model')
    Test-That 'and asked for again after six' { $script:LauncherRosterCalls['claude'] -eq 2 }

    $script:LauncherRosterFailure['claude'] = 'simulated Claude failure'
    $script:BridgeLauncherModelCache['claude'].At = [DateTimeOffset]::Now.AddHours(-7)
    $keptClaudeModels = @(Get-BridgeTuningOptions -Launcher 'claude' -Axis 'model')
    $keptClaudeEfforts = @(Get-BridgeTuningOptions -Launcher 'claude' -Axis 'effort')
    $keptClaudeTakes = Format-ModelEfforts (Get-BridgeLauncherModelDiscovery -Launcher 'claude').ModelEfforts
    Test-That 'a failed refresh keeps both of the last good lists and logs why' {
        ($keptClaudeModels -join ',') -ceq 'Agent default,opus,sonnet' -and
            ($keptClaudeEfforts -join ',') -ceq 'Agent default,low,high' -and
            $keptClaudeTakes -ceq 'opus=low+high sonnet=low' -and
            (Get-LastLauncherModelLog -Label 'Claude') -match ("failed for 'C:\\fake-claude\.exe': simulated Claude failure\. " +
                'Keeping 2 cached model\(s\); retrying in 60s')
    } "$(Get-LastLauncherModelLog -Label 'Claude') / $keptClaudeTakes"
    $launcherRetryWaits = foreach ($attempt in 1..6) {
        $script:BridgeLauncherModelCache['claude'].At = [DateTimeOffset]::Now.AddSeconds(-(Get-LastLauncherModelRetry -Label 'Claude') - 1)
        [void](Get-BridgeLauncherModelDiscovery -Launcher 'claude')
        Get-LastLauncherModelRetry -Label 'Claude'
    }
    Test-That 'repeated failures back off as Copilot''s do, and keep the lists throughout' {
        ($launcherRetryWaits -join ',') -ceq '120,240,480,960,1800,1800' -and
            ((Get-BridgeTuningOptions -Launcher 'claude' -Axis 'model') -join ',') -ceq 'Agent default,opus,sonnet'
    } "waits $($launcherRetryWaits -join ',')"
    $script:LauncherRosterFailure['claude'] = $null
    $script:BridgeLauncherModelCache['claude'].At = [DateTimeOffset]::Now.AddSeconds(-1801)
    [void](Get-BridgeLauncherModelDiscovery -Launcher 'claude')
    Test-That 'recovery is logged' {
        (Get-LastLauncherModelLog -Label 'Claude') -match "recovered: found 2 model\(s\) from 'C:\\fake-claude\.exe'"
    } (Get-LastLauncherModelLog -Label 'Claude')
    Test-That 'and none of it touched Codex''s answer' {
        $script:LauncherRosterCalls['codex'] -eq 1 -and -not $script:BridgeLauncherModelCache['codex'].Failed
    }

    $script:LauncherRosterFailure['claude'] = 'simulated Claude failure'
    $script:LauncherRosterFailure['codex'] = 'simulated Codex failure'
    $script:BridgeLauncherModelCache = @{}
    $fallbackChoices = @(
        (@(Get-BridgeTuningOptions -Launcher 'claude' -Axis 'model') -join ',')
        (@(Get-BridgeTuningOptions -Launcher 'claude' -Axis 'effort') -join ',')
        (@(Get-BridgeTuningOptions -Launcher 'codex' -Axis 'model') -join ',')
        (@(Get-BridgeTuningOptions -Launcher 'codex' -Axis 'effort') -join ',')
    ) -join ' / '
    Test-That 'a failure with nothing cached offers each built-in list instead, and says so' {
        $fallbackChoices -ceq ('Agent default,opus,sonnet,haiku,fable / Agent default,low,medium,high,xhigh,max / ' +
            'Agent default,gpt-6.1-sol,gpt-6-sol,gpt-6-luna / Agent default,low,medium,high,xhigh,max,ultra') -and
            (Get-LastLauncherModelLog -Label 'Claude') -match 'Keeping 0 cached model\(s\); retrying in 60s' -and
            (Get-LastLauncherModelLog -Label 'Codex') -match 'Keeping 0 cached model\(s\); retrying in 60s'
    } $fallbackChoices

    $script:LauncherRosterFailure['claude'] = $null
    $script:BridgeLauncherModelCache = @{}
    $claudeCallsBefore = $script:LauncherRosterCalls['claude']
    $script:FakeSettings = @{ 'newSession.models.claude' = @('opus') }
    $configuredClaudeChoices = @(Get-BridgeTuningOptions -Launcher 'claude' -Axis 'model')
    $script:FakeSettings = @{}
    Test-That 'a configured list is offered as it is, without asking Claude' {
        ($configuredClaudeChoices -join ',') -ceq 'Agent default,opus' -and $script:LauncherRosterCalls['claude'] -eq $claudeCallsBefore
    } ($configuredClaudeChoices -join ',')

    $script:FakeClaudeExe = $null
    $missingClaudeChoices = @(Get-BridgeTuningOptions -Launcher 'claude' -Axis 'model')
    Test-That 'with no Claude installed the built-in list stands, nothing is started, and the log says why' {
        ($missingClaudeChoices -join ',') -ceq 'Agent default,opus,sonnet,haiku,fable' -and
            $script:LauncherRosterCalls['claude'] -eq $claudeCallsBefore -and
            (Get-LastLauncherModelLog -Label 'Claude') -match 'Claude executable was not found'
    } (Get-LastLauncherModelLog -Label 'Claude')

    # The Effort list offers every effort some model takes, so it can offer one the
    # chosen model does not. A launch moves that to the nearest the model does take.
    $script:FakeClaudeExe = 'C:\fake-claude.exe'
    $script:LauncherRosterFailure = @{ claude = $null; codex = $null }
    $script:LauncherRoster['codex'] = [pscustomobject]@{
        Models       = @('gpt-6.1-sol', 'gpt-5.5', 'gpt-oss', 'gpt-lab')
        Efforts      = @('low', 'medium', 'high', 'xhigh', 'max', 'ultra', 'alpha', 'beta', 'gamma')
        EffortsKnown = $true
        ModelEfforts = @{
            'gpt-6.1-sol' = @('low', 'medium', 'high', 'xhigh', 'max', 'ultra')
            'gpt-5.5'     = @('medium', 'xhigh')
            'gpt-oss'     = @()
            'gpt-lab'     = @('alpha', 'beta', 'gamma')
        }
    }
    $script:BridgeLauncherModelCache = @{}
    $effortHolds = foreach ($case in @(
            , @('codex', 'gpt-6.1-sol', 'minimal', 'low')
            , @('codex', 'gpt-6.1-sol', 'none', 'low')
            , @('codex', 'gpt-6.1-sol', 'turbo', 'high')
            , @('codex', 'gpt-5.5', 'high', 'medium')
            , @('codex', 'gpt-5.5', 'ultra', 'xhigh')
            , @('codex', 'gpt-5.5', 'low', 'medium')
            , @('codex', 'gpt-oss', 'high', '')
            , @('codex', 'gpt-lab', 'high', 'beta')
            , @('codex', 'gpt-lab', 'beta', 'beta')
            , @('codex', 'gpt-9', 'minimal', 'minimal')
            , @('codex', '', 'minimal', 'minimal')
            , @('codex', 'gpt-6.1-sol', '', '')
            , @('copilot', 'gpt-6.1-sol', 'minimal', 'minimal')
            , @('claude', 'sonnet', 'high', 'low')
        )) {
        $held = $(try { Resolve-BridgeModelEffort -Launcher $case[0] -Model $case[1] -Effort $case[2] } catch { "threw: $($_.Exception.Message)" })
        [pscustomobject]@{ Case = "$($case[0]) '$($case[1])' '$($case[2])'"; Held = $held; Expected = $case[3] }
    }
    $wrongHolds = @($effortHolds | Where-Object { $_.Held -isnot [string] -or $_.Held -cne $_.Expected })
    Test-That 'an effort the model does not take moves to the nearest it does, the weaker of two, its middle if they cannot be compared, or none' {
        @($effortHolds).Count -eq 14 -and $wrongHolds.Count -eq 0
    } (($wrongHolds | ForEach-Object { "$($_.Case) held '$($_.Held)', not '$($_.Expected)'" }) -join ' | ')

    function Get-EffortHoldLog {
        if (-not (Test-Path -LiteralPath $script:testLogFile)) { return @() }
        @(Get-Content -LiteralPath $script:testLogFile | Where-Object { $_ -match 'does not take effort' })
    }
    $holdLogsBefore = @(Get-EffortHoldLog).Count
    $launchHeld = Resolve-BridgeLaunchTuning -Launcher 'codex' -Model 'gpt-5.5' -Effort 'high' -Context ''
    $holdLogsAfter = @(Get-EffortHoldLog)
    Test-That 'a launch passes the effort the model takes, and logs what it moved' {
        $launchHeld['model'] -ceq 'gpt-5.5' -and $launchHeld['effort'] -ceq 'medium' -and $launchHeld['context'] -ceq '' -and
            $holdLogsAfter.Count -eq $holdLogsBefore + 1 -and
            [string]($holdLogsAfter | Select-Object -Last 1) -cmatch "Codex model 'gpt-5\.5' does not take effort 'high'; starting it with 'medium'\.$"
    } "$(ConvertTo-Json -InputObject $launchHeld -Compress) / $($holdLogsAfter | Select-Object -Last 1)"
    $launchKept = Resolve-BridgeLaunchTuning -Launcher 'codex' -Model 'gpt-6.1-sol' -Effort 'high' -Context ''
    $launchUnmodelled = Resolve-BridgeLaunchTuning -Launcher 'codex' -Model '' -Effort 'max' -Context ''
    Test-That 'and an effort the model takes, or one chosen with no model, as it is, logging nothing' {
        $launchKept['model'] -ceq 'gpt-6.1-sol' -and $launchKept['effort'] -ceq 'high' -and
            $launchUnmodelled['model'] -ceq '' -and $launchUnmodelled['effort'] -ceq 'max' -and
            @(Get-EffortHoldLog).Count -eq $holdLogsAfter.Count
    } "$(ConvertTo-Json -InputObject $launchKept -Compress) / $(ConvertTo-Json -InputObject $launchUnmodelled -Compress)"
    $script:FakeSettings = @{ 'newSession.efforts.codex' = @('minimal', 'xhigh') }
    $launchUnlisted = Resolve-BridgeLaunchTuning -Launcher 'codex' -Model 'gpt-6.1-sol' -Effort 'minimal' -Context ''
    $script:FakeSettings = @{}
    Test-That 'a nearest effort the configured list leaves out is not passed, and the log says no effort' {
        $launchUnlisted['effort'] -ceq '' -and
            [string](Get-EffortHoldLog | Select-Object -Last 1) -cmatch "Codex model 'gpt-6\.1-sol' does not take effort 'minimal'; starting it with no effort\.$"
    } "$(ConvertTo-Json -InputObject $launchUnlisted -Compress) / $(Get-EffortHoldLog | Select-Object -Last 1)"

    # The same through a roster made from Codex's own answer, whose map is not a hashtable.
    $script:LauncherRoster['codex'] = ConvertFrom-BridgeCodexModelRoster -Entry @(
        @{ model = 'gpt-5.5'; supportedReasoningEfforts = @('medium', 'xhigh') }
        @{ model = 'gpt-oss'; supportedReasoningEfforts = @() }
    )
    $script:BridgeLauncherModelCache = @{}
    $convertedHolds = $(try {
            @(foreach ($model in 'gpt-5.5', 'gpt-oss') { "$model=$(Resolve-BridgeModelEffort -Launcher 'codex' -Model $model -Effort 'high')" }) -join ' '
        }
        catch { "threw: $($_.Exception.Message)" })
    Test-That 'and the same for the models Codex''s own list describes' {
        $convertedHolds -ceq 'gpt-5.5=medium gpt-oss='
    } $convertedHolds

    # An answer that no model takes an effort is an answer: only Agent default is
    # offered. One that does not say leaves the built-in list standing.
    $script:LauncherRoster['codex'] = [pscustomobject]@{
        Models = @('gpt-oss'); Efforts = @(); EffortsKnown = $true; ModelEfforts = @{ 'gpt-oss' = @() }
    }
    $script:BridgeLauncherModelCache = @{}
    $noEffortChoices = @(Get-BridgeTuningOptions -Launcher 'codex' -Axis 'effort')
    $script:LauncherRoster['codex'] = [pscustomobject]@{ Models = @('gpt-oss'); Efforts = @(); EffortsKnown = $false; ModelEfforts = @{} }
    $script:BridgeLauncherModelCache = @{}
    $unsaidEffortChoices = @(Get-BridgeTuningOptions -Launcher 'codex' -Axis 'effort')
    Test-That 'models that take no effort leave only Agent default to offer, and models that do not say leave the built-in list' {
        ($noEffortChoices -join ',') -ceq 'Agent default' -and
            ($unsaidEffortChoices -join ',') -ceq 'Agent default,low,medium,high,xhigh,max,ultra'
    } "$($noEffortChoices -join ',') / $($unsaidEffortChoices -join ',')"
}
finally {
    if ($null -ne $lineChild) { [void](Stop-BridgeJsonRpcProcess -Connection $lineChild -GraceMs 0) }
    Remove-Item -LiteralPath $lineRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath 'Env:BRIDGE_TEST_PARENT' -ErrorAction SilentlyContinue
    ${function:Get-BridgeLauncherModelDiscovery} = $savedLauncherDiscovery
    ${function:Get-BridgeClaudePath} = $savedDiscoveryClaudePath
    ${function:Get-BridgeCodexPath} = $savedDiscoveryCodexPath
    ${function:Start-BridgeJsonLineProcess} = $savedLineStart
    ${function:Get-BridgeClaudeModelRoster} = $savedClaudeRoster
    ${function:Get-BridgeCodexModelRoster} = $savedCodexRoster
    $script:BridgeLauncherModelCache = @{}
    $script:FakeSettings = @{}
}

# Three per-launch settings, spelled differently by every agent: Copilot has
# --reasoning-effort and --context, Claude has --effort and (having no real context
# switch) --autocompact, Codex has neither and takes both as `-c` overrides. Each was
# checked against the installed CLI, which rejects a bad value outright, so the option
# lists here are what those parsers actually accept.
#
# Discovery is shadowed throughout: the real one holds a throwaway session with the
# Copilot CLI, which is neither offline nor stable enough to assert on. Claude's and
# Codex's have been shadowed since the top, finding nothing, so those two offer their
# built-in lists here.
function Get-BridgeCopilotModelList { @('gpt-5.4', 'claude-opus-5') }

$script:FakeSettings = @{}
Test-That 'the axes are model, effort and context, in that order' {
    (Get-BridgeTuningAxes) -join ',' -eq 'model,effort,context'
}
Test-That 'every list opens on "Agent default", so an untouched card launches as before' {
    @('model', 'effort', 'context') | ForEach-Object {
        (Get-BridgeTuningOptions -Launcher 'copilot' -Axis $_)[0]
    } | Where-Object { $_ -ne 'Agent default' } | Measure-Object | ForEach-Object { $_.Count -eq 0 }
}
Test-That 'discovered Copilot models are offered alongside auto' {
    $m = @(Get-BridgeTuningOptions -Launcher 'copilot' -Axis 'model')
    $m -contains 'auto' -and $m -contains 'gpt-5.4' -and $m -contains 'claude-opus-5'
}
Test-That 'Agency offers Copilot\''s lists, because it builds a Copilot command line' {
    (Get-BridgeTuningOptions -Launcher 'agency' -Axis 'model') -join ',' -eq
        (Get-BridgeTuningOptions -Launcher 'copilot' -Axis 'model') -join ','
}
Test-That 'each agent offers its own efforts' {
    (Get-BridgeTuningOptions -Launcher 'claude' -Axis 'effort') -contains 'max' -and
    (Get-BridgeTuningOptions -Launcher 'claude' -Axis 'effort') -notcontains 'none' -and
    (Get-BridgeTuningOptions -Launcher 'codex' -Axis 'effort') -contains 'ultra' -and
    (Get-BridgeTuningOptions -Launcher 'copilot' -Axis 'effort') -contains 'none'
}
Test-That 'Claude\''s context options are autocompact sizes, which is all it has' {
    (Get-BridgeTuningOptions -Launcher 'claude' -Axis 'context') -join ',' -eq 'Agent default,auto,200k,500k,1m'
}

Test-That 'a known value resolves to itself' {
    (Resolve-BridgeTuningValue -Launcher 'copilot' -Axis 'effort' -Value 'xhigh') -eq 'xhigh'
}
Test-That 'the sentinel means pass nothing' {
    (Resolve-BridgeTuningValue -Launcher 'copilot' -Axis 'effort' -Value 'Agent default') -eq ''
}
Test-That 'an unset selector means pass nothing' {
    @('', 'unknown', 'unavailable') |
        ForEach-Object { Resolve-BridgeTuningValue -Launcher 'copilot' -Axis 'effort' -Value $_ } |
        Where-Object { $_ -ne '' } | Measure-Object | ForEach-Object { $_.Count -eq 0 }
}
# The security boundary, and the reason these are resolved at all: these three land
# directly in the agent's own argument parser, next to a shell.
Test-That 'an injected value never reaches the command line' {
    (Resolve-BridgeTuningValue -Launcher 'copilot' -Axis 'effort' -Value 'high --allow-all') -eq '' -and
    (Resolve-BridgeTuningValue -Launcher 'copilot' -Axis 'model' -Value 'x; rm -rf /') -eq ''
}
Test-That 'a value belonging to another agent is dropped, not refused' {
    # Claude has no 'xhigh' problem but no 'none' either; a selector left over from
    # Copilot means "whatever Claude does by default".
    (Resolve-BridgeTuningValue -Launcher 'claude' -Axis 'effort' -Value 'none') -eq ''
}
Test-That 'a dropped value produces no arguments at all' {
    @(Get-BridgeTuningArguments -Launcher 'copilot' -Axis 'effort' -Value 'evil --yolo').Count -eq 0
}

$tuned = @(Get-BridgeNewSessionArguments -SessionId $sid -Model 'gpt-5.4' -Effort 'xhigh' -Context 'long_context')
Test-That 'Copilot gets --reasoning-effort and --context' {
    $tuned[$tuned.IndexOf('--reasoning-effort') + 1] -eq 'xhigh' -and
    $tuned[$tuned.IndexOf('--context') + 1] -eq 'long_context'
}
$clTuned = @(Get-BridgeNewSessionArguments -SessionId $sid -Launcher 'claude' -Effort 'max' -Context '1m' -Prompt 'go')
Test-That 'Claude gets --effort and --autocompact' {
    $clTuned[$clTuned.IndexOf('--effort') + 1] -eq 'max' -and
    $clTuned[$clTuned.IndexOf('--autocompact') + 1] -eq '1m'
}
Test-That 'and they stay in front of the prompt, which is still last' { $clTuned[-2] -eq '--' -and $clTuned[-1] -eq 'go' }
$cxTuned = @(Get-BridgeNewSessionArguments -SessionId 'sid' -Launcher 'codex' -Effort 'high' -Context '400000' -Resume)
Test-That 'Codex takes both as -c overrides' {
    ($cxTuned -join ' ') -match '-c model_reasoning_effort=high' -and
    ($cxTuned -join ' ') -match '-c model_context_window=400000'
}
# `-c` is a global option; Codex reads those before the subcommand, where its own
# reasoning-summary override already sits.
Test-That 'and they precede the resume subcommand, like the other -c does' {
    $cxTuned.IndexOf('model_reasoning_effort=high') -lt $cxTuned.IndexOf('resume') -and
    $cxTuned.IndexOf('model_context_window=400000') -lt $cxTuned.IndexOf('resume')
}
Test-That 'nothing chosen means nothing added' {
    $plain = @(Get-BridgeNewSessionArguments -SessionId $sid)
    $plain -notcontains '--reasoning-effort' -and $plain -notcontains '--context' -and $plain -notcontains '--model'
}

# The config file is the machine owner's own, as trusted as newSession.extraArgs
# beside it, so a model the installed CLI has not advertised still works - a preview,
# or a BYOK provider.
$script:FakeSettings = @{ 'newSession.model' = 'preview-only' }
Test-That 'the pre-existing newSession.model still names the default model' {
    (Get-BridgeDefaultTuning -Launcher 'copilot' -Axis 'model') -eq 'preview-only'
}
Test-That 'and is offered on the card even though nothing else lists it' {
    (Get-BridgeTuningOptions -Launcher 'copilot' -Axis 'model') -contains 'preview-only'
}
Test-That 'so it survives validation on the way back in' {
    (Resolve-BridgeTuningValue -Launcher 'copilot' -Axis 'model' -Value 'preview-only') -eq 'preview-only'
}

$script:FakeSettings = @{ 'newSession.models.claude' = @('opus'); 'newSession.effort.claude' = 'high' }
Test-That 'a configured list replaces the built-in one outright' {
    (Get-BridgeTuningOptions -Launcher 'claude' -Axis 'model') -join ',' -eq 'Agent default,opus'
}
Test-That 'and a configured default opens the selector there' {
    (Get-BridgeDefaultTuning -Launcher 'claude' -Axis 'effort') -eq 'high'
}
Test-That 'a launcher with nothing configured is unaffected' {
    (Get-BridgeTuningOptions -Launcher 'codex' -Axis 'model') -contains 'gpt-6.1-sol'
}

$script:FakeSettings = @{}

Write-Host ''
Write-Host '--- launcher selection ---'

# Shadow the probes so launcher selection can be tested without any tool present.
$script:AgencyPresent = $true
$script:CopilotPresent = $true
$script:ClaudePresent = $false
$script:CodexPresent = $false
# The fakes below change between calls, so nothing may be served from the cache.
$script:BridgeLauncherCacheSeconds = 0
function Get-BridgeAgencyPath { if ($script:AgencyPresent) { 'C:\agency.exe' } else { $null } }
function Get-BridgeCopilotPath { if ($script:CopilotPresent) { 'C:\copilot.exe' } else { $null } }
function Get-BridgeClaudePath { if ($script:ClaudePresent) { 'C:\claude.exe' } else { $null } }
function Get-BridgeCodexPath { if ($script:CodexPresent) { 'C:\codex.cmd' } else { $null } }

Write-Host ''
Write-Host '--- reading how agents are used ---'
$usageRoot = Join-Path ([IO.Path]::GetTempPath()) "bridge-usage-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$savedHomes = @{ COPILOT_HOME = $env:COPILOT_HOME; CODEX_HOME = $env:CODEX_HOME; CLAUDE_CONFIG_DIR = $env:CLAUDE_CONFIG_DIR }
try {
    $env:COPILOT_HOME = Join-Path $usageRoot 'copilot'
    $env:CODEX_HOME = Join-Path $usageRoot 'codex'
    $env:CLAUDE_CONFIG_DIR = Join-Path $usageRoot 'claude'
    $session = New-Item -ItemType Directory -Force -Path (Join-Path $usageRoot 'codex\sessions\2026\09\27')
    $rollout = Join-Path $session.FullName 'rollout-1.jsonl'
    Set-Content -LiteralPath $rollout -Value '{}'
    (Get-Item -LiteralPath $rollout).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(10)
    New-Item -ItemType Directory -Force -Path (Join-Path $usageRoot 'claude') | Out-Null
    Set-Content -LiteralPath (Join-Path $usageRoot 'claude\.credentials.json') -Value '{}'

    $codex = Get-BridgeLauncherUsage -Launcher 'codex'
    Test-That 'a Codex session filed by date is found' { $null -ne $codex.LastUsed -and $codex.LastUsed -gt [DateTime]::UtcNow.AddMinutes(5) }
    $claude = Get-BridgeLauncherUsage -Launcher 'claude'
    Test-That 'a signed-in Claude with no sessions has no history' { $claude.SignedIn -and $null -eq $claude.LastUsed }
    $copilot = Get-BridgeLauncherUsage -Launcher 'agency'
    Test-That 'a Copilot never run is neither used nor signed in' { -not $copilot.SignedIn -and $null -eq $copilot.LastUsed }
}
finally {
    foreach ($name in $savedHomes.Keys) { Set-Item -Path "env:$name" -Value $savedHomes[$name] -ErrorAction SilentlyContinue; if (-not $savedHomes[$name]) { Remove-Item -Path "env:$name" -ErrorAction SilentlyContinue } }
    Remove-Item -LiteralPath $usageRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# Now shadow the usage probes too, so 'auto' sees no history unless a test gives it
# some. Agency shares Copilot's history, as the real probe does.
$script:Usage = @{}
function Get-BridgeLauncherUsage {
    param([string]$Launcher)
    $key = if ($Launcher -eq 'agency') { 'copilot' } else { $Launcher }
    if ($script:Usage.ContainsKey($key)) { return $script:Usage[$key] }
    [pscustomobject]@{ LastUsed = $null; SignedIn = $false }
}
function Set-TestUsage { param([hashtable]$Usage) $script:Usage = $Usage; $script:BridgeAutoLauncher = $null }

$script:FakeSettings = @{ 'newSession.launcher' = 'auto' }
$script:AgencyPresent = $true
Test-That 'auto prefers Agency when it is installed' { (Get-BridgeLauncherKind) -eq 'agency' }
$script:AgencyPresent = $false
Test-That 'auto falls back to copilot without Agency' { (Get-BridgeLauncherKind) -eq 'copilot' }

$script:FakeSettings = @{ 'newSession.launcher' = 'copilot' }
$script:AgencyPresent = $true
Test-That 'an explicit copilot setting is honoured even with Agency installed' { (Get-BridgeLauncherKind) -eq 'copilot' }

$script:FakeSettings = @{ 'newSession.launcher' = 'agency' }
$script:AgencyPresent = $false
Test-That 'asking for Agency without it installed falls back rather than failing' { (Get-BridgeLauncherKind) -eq 'copilot' }

$script:FakeSettings = @{ 'newSession.launcher' = 'AGENCY' }
$script:AgencyPresent = $true
Test-That 'the launcher setting is case-insensitive' { (Get-BridgeLauncherKind) -eq 'agency' }

# A machine with only Claude on it - the case that used to fail with copilot.exe
# not found.
$script:AgencyPresent = $false
$script:CopilotPresent = $false
$script:ClaudePresent = $true
$script:FakeSettings = @{ 'newSession.launcher' = 'auto' }
Test-That 'auto picks Claude when it is the only agent installed' { (Get-BridgeLauncherKind) -eq 'claude' }
$script:FakeSettings = @{ 'newSession.launcher' = 'copilot' }
Test-That 'a configured launcher that is missing falls back to one that is installed' { (Get-BridgeLauncherKind) -eq 'claude' }
$script:ClaudePresent = $false
Test-That 'with nothing installed it still names copilot, so the error says what is missing' { (Get-BridgeLauncherKind) -eq 'copilot' }

$script:AgencyPresent = $true
$script:CopilotPresent = $true
$script:ClaudePresent = $true
$script:CodexPresent = $true
$script:FakeSettings = @{ 'newSession.launcher' = 'codex' }
Test-That 'an explicit claude-or-codex choice is honoured' { (Get-BridgeLauncherKind) -eq 'codex' }

# 'auto' follows how the machine is used, not a fixed order: installing Copilot to
# try it must not turn every launch on a Claude machine into a Copilot one.
$script:AgencyPresent = $false
$script:FakeSettings = @{ 'newSession.launcher' = 'auto' }
$now = [DateTime]::UtcNow
Set-TestUsage @{
    claude  = [pscustomobject]@{ LastUsed = $now.AddMinutes(-5); SignedIn = $true }
    copilot = [pscustomobject]@{ LastUsed = $null; SignedIn = $false }
    codex   = [pscustomobject]@{ LastUsed = $now.AddDays(-3); SignedIn = $true }
}
Test-That 'auto picks the agent used most recently' { (Get-BridgeLauncherKind) -eq 'claude' }
Set-TestUsage @{
    claude = [pscustomobject]@{ LastUsed = $now.AddDays(-1); SignedIn = $true }
    codex  = [pscustomobject]@{ LastUsed = $now.AddMinutes(-1); SignedIn = $true }
}
Test-That 'and moves when another agent is used more recently' { (Get-BridgeLauncherKind) -eq 'codex' }
Set-TestUsage @{ codex = [pscustomobject]@{ LastUsed = $null; SignedIn = $true } }
Test-That 'with no history anywhere it prefers an agent that is signed in' { (Get-BridgeLauncherKind) -eq 'codex' }
Set-TestUsage @{}
Test-That 'and with nothing to go on, preference order' { (Get-BridgeLauncherKind) -eq 'copilot' }
$script:AgencyPresent = $true
Set-TestUsage @{
    copilot = [pscustomobject]@{ LastUsed = $now; SignedIn = $true }
    claude  = [pscustomobject]@{ LastUsed = $now.AddHours(-1); SignedIn = $true }
}
Test-That 'Agency shares Copilot''s history and wins the tie' { (Get-BridgeLauncherKind) -eq 'agency' }
$script:FakeSettings = @{ 'newSession.launcher' = 'claude' }
Set-TestUsage @{ codex = [pscustomobject]@{ LastUsed = $now; SignedIn = $true } }
Test-That 'an explicit launcher setting still beats usage' { (Get-BridgeLauncherKind) -eq 'claude' }
$script:FakeSettings = @{ 'newSession.launcher' = 'codex' }
Set-TestUsage @{}
Test-That 'every installed agent is offered, in preference order' {
    (@(Get-BridgeAvailableLaunchers) -join ',') -eq 'agency,copilot,claude,codex'
}
Test-That 'an agent label resolves to its launcher' { (Resolve-BridgeLauncher -Label 'Claude') -eq 'claude' }
Test-That 'the launcher kind itself also resolves' { (Resolve-BridgeLauncher -Label 'codex') -eq 'codex' }
Test-That 'an unknown agent is refused' { $null -eq (Resolve-BridgeLauncher -Label 'Claude --yolo') }
$script:CodexPresent = $false
Test-That 'an agent that is not installed is refused' { $null -eq (Resolve-BridgeLauncher -Label 'Codex') }
$script:CopilotPresent = $true
$script:ClaudePresent = $false

# --- the resume list ---------------------------------------------------------------

Write-Host ''
Write-Host '--- reading each agent''s sessions ---'

# Real parsers against fixture stores laid out as each CLI writes them.
$storeRoot = Join-Path ([IO.Path]::GetTempPath()) "bridge-sessions-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$savedHomes = @{ COPILOT_HOME = $env:COPILOT_HOME; CODEX_HOME = $env:CODEX_HOME; CLAUDE_CONFIG_DIR = $env:CLAUDE_CONFIG_DIR }
function Write-Lines { param([string]$Path, [object[]]$Records) New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null; Set-Content -LiteralPath $Path -Value @($Records | ForEach-Object { if ($_ -is [string]) { $_ } else { $_ | ConvertTo-Json -Compress -Depth 8 } }) -Encoding utf8 }
try {
    $env:CLAUDE_CONFIG_DIR = Join-Path $storeRoot 'claude'
    $env:COPILOT_HOME = Join-Path $storeRoot 'copilot'
    $env:CODEX_HOME = Join-Path $storeRoot 'codex'
    $project = Join-Path $storeRoot 'claude\projects\C--repos-alpha'

    Write-Lines (Join-Path $project '11111111-aaaa-0000-0000-000000000001.jsonl') @(
        @{ type = 'user'; cwd = 'C:\repos\alpha'; message = @{ role = 'user'; content = '<command-name>/clear</command-name>' } }
        @{ type = 'user'; cwd = 'C:\repos\alpha'; message = @{ role = 'user'; content = @(@{ type = 'text'; text = "Fix the flaky`nlogin test" }) } }
        @{ type = 'ai-title'; aiTitle = 'Flaky login test' })
    Write-Lines (Join-Path $project '11111111-aaaa-0000-0000-000000000002.jsonl') @(
        @{ type = 'user'; cwd = 'C:\repos\alpha'; message = @{ role = 'user'; content = 'Plan the release' } }
        @{ type = 'ai-title'; aiTitle = 'Release planning' }
        @{ type = 'custom-title'; customTitle = 'v2 launch' })
    Write-Lines (Join-Path $project '11111111-aaaa-0000-0000-000000000003.jsonl') @(
        @{ type = 'user'; cwd = 'C:\repos\alpha'; message = @{ role = 'user'; content = 'Just a prompt' } })
    # Opened and closed without a prompt: nothing to go back to.
    Write-Lines (Join-Path $project '11111111-aaaa-0000-0000-000000000004.jsonl') @(
        @{ type = 'mode'; mode = 'normal' }
        @{ type = 'user'; cwd = 'C:\repos\alpha'; message = @{ role = 'user'; content = '<local-command-stdout>See ya!</local-command-stdout>' } })
    # A subagent transcript in a folder below is not a session of its own.
    Write-Lines (Join-Path $project '11111111-aaaa-0000-0000-000000000001\subagents\agent-1.jsonl') @(
        @{ type = 'user'; cwd = 'C:\repos\alpha'; message = @{ role = 'user'; content = 'subagent task' } })

    $claudeEntries = @(Get-BridgeClaudeSessionEntries -Limit 10)
    $byId = @{}; foreach ($e in $claudeEntries) { $byId[$e.SessionId] = $e }
    Test-That 'Claude sessions are read from the projects folder' { $claudeEntries.Count -eq 3 }
    Test-That 'a generated title is used' { $byId['11111111-aaaa-0000-0000-000000000001'].Summary -eq 'Flaky login test' }
    Test-That 'a title the user gave wins over the generated one' { $byId['11111111-aaaa-0000-0000-000000000002'].Summary -eq 'v2 launch' }
    Test-That 'without a title the first real prompt is used' { $byId['11111111-aaaa-0000-0000-000000000003'].Summary -eq 'Just a prompt' }
    Test-That 'a session with no prompt is left out' { -not $byId.ContainsKey('11111111-aaaa-0000-0000-000000000004') }
    Test-That 'subagent transcripts are not listed' { @($claudeEntries | Where-Object { $_.SessionId -like 'agent-*' }).Count -eq 0 }
    Test-That 'the folder comes from the transcript' { $byId['11111111-aaaa-0000-0000-000000000001'].Folder -eq 'C:\repos\alpha' }
    Test-That 'and each entry names Claude as its launcher' { @($claudeEntries | Where-Object Launcher -ne 'claude').Count -eq 0 }

    # A transcript far larger than the window read from each end still gives up its
    # title and folder, and nothing from the middle is needed.
    $big = Join-Path $project '11111111-aaaa-0000-0000-000000000005.jsonl'
    Write-Lines $big @(
        @{ type = 'user'; cwd = 'C:\repos\alpha'; message = @{ role = 'user'; content = 'Big one' } }
        @(1..3000 | ForEach-Object { @{ type = 'assistant'; message = @{ content = ('x' * 200) } } })
        @{ type = 'ai-title'; aiTitle = 'Big session' })
    Test-That 'a large transcript is read from its ends' {
        (@(Get-BridgeClaudeSessionEntries -Limit 10) | Where-Object SessionId -eq '11111111-aaaa-0000-0000-000000000005').Summary -eq 'Big session'
    }

    $state = Join-Path $storeRoot 'copilot\session-state'
    New-Item -ItemType Directory -Force -Path (Join-Path $state '22222222-bbbb-0000-0000-000000000001') | Out-Null
    Set-Content -LiteralPath (Join-Path $state '22222222-bbbb-0000-0000-000000000001\workspace.yaml') -Value @(
        'id: 22222222-bbbb-0000-0000-000000000001', 'cwd: C:\repos\beta', 'summary: "Refactor the parser"')
    Write-Lines (Join-Path $state '22222222-bbbb-0000-0000-000000000002\events.jsonl') @(
        @{ type = 'session.start'; data = @{} }
        @{ type = 'user.message'; data = @{ content = 'Write the changelog' } })
    New-Item -ItemType Directory -Force -Path (Join-Path $state '22222222-bbbb-0000-0000-000000000003') | Out-Null
    $copilotEntries = @(Get-BridgeCopilotSessionEntries -Limit 10)
    Test-That 'Copilot sessions come with their workspace summary and folder' {
        $e = $copilotEntries | Where-Object SessionId -eq '22222222-bbbb-0000-0000-000000000001'
        $e.Summary -eq 'Refactor the parser' -and $e.Folder -eq 'C:\repos\beta' -and $e.Launcher -eq 'copilot'
    }
    Test-That 'or with their first prompt when there is no summary' {
        ($copilotEntries | Where-Object SessionId -eq '22222222-bbbb-0000-0000-000000000002').Summary -eq 'Write the changelog'
    }
    Test-That 'an empty Copilot session is left out' { $copilotEntries.Count -eq 2 }

    $rollouts = Join-Path $storeRoot 'codex\sessions\2026\09\27'
    Write-Lines (Join-Path $rollouts 'rollout-2026-09-27T10-00-00-33333333-cccc-0000-0000-000000000001.jsonl') @(
        @{ type = 'session_meta'; payload = @{ id = '33333333-cccc-0000-0000-000000000001'; cwd = 'C:\repos\gamma' } }
        @{ type = 'event_msg'; payload = @{ type = 'user_message'; message = '<environment_context>...</environment_context>' } }
        @{ type = 'event_msg'; payload = @{ type = 'user_message'; message = 'Port the tests' } })
    Write-Lines (Join-Path $rollouts 'rollout-2026-09-27T11-00-00-33333333-cccc-0000-0000-000000000002.jsonl') @(
        @{ type = 'session_meta'; payload = @{ id = '33333333-cccc-0000-0000-000000000002'; cwd = 'C:\repos\gamma' } }
        @{ type = 'event_msg'; payload = @{ type = 'user_message'; message = 'Something' } })
    Write-Lines (Join-Path $storeRoot 'codex\session_index.jsonl') @(
        @{ id = '33333333-cccc-0000-0000-000000000002'; thread_name = 'Named thread' })
    $codexEntries = @(Get-BridgeCodexSessionEntries -Limit 10)
    Test-That 'Codex sessions are found in their dated folders, with id and folder' {
        $e = $codexEntries | Where-Object SessionId -eq '33333333-cccc-0000-0000-000000000001'
        $e.Summary -eq 'Port the tests' -and $e.Folder -eq 'C:\repos\gamma' -and $e.Launcher -eq 'codex'
    }
    Test-That 'a thread name the user gave is the title' {
        ($codexEntries | Where-Object SessionId -eq '33333333-cccc-0000-0000-000000000002').Summary -eq 'Named thread'
    }
}
finally {
    foreach ($key in $savedHomes.Keys) {
        if ($savedHomes[$key]) { Set-Item -Path "env:$key" -Value $savedHomes[$key] } else { Remove-Item -Path "env:$key" -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $storeRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# From here the file readers are shadowed, so this machine's own sessions never
# leak into the assertions below.
$script:FileEntries = @{ claude = @(); copilot = @(); codex = @() }
function Get-BridgeClaudeSessionEntries { param([int]$Limit) @($script:FileEntries.claude) }
function Get-BridgeCopilotSessionEntries { param([int]$Limit) @($script:FileEntries.copilot) }
function Get-BridgeCodexSessionEntries { param([int]$Limit) @($script:FileEntries.codex) }
function New-FileEntry {
    param([string]$Id, [string]$Launcher, [string]$Summary, [string]$Folder, [string]$Updated)
    [pscustomobject]@{ SessionId = $Id; Launcher = $Launcher; Summary = $Summary; Folder = $Folder; Updated = [DateTimeOffset]::Parse($Updated) }
}

Write-Host ''
Write-Host '--- the resumable session list ---'

# Shadow the one slow, machine-dependent step so the parsing is testable offline.
$savedProbeResult = $script:ProbeResult
$savedAgencyPath = ${function:Get-BridgeAgencyPath}
function Get-BridgeAgencyPath { 'C:\fake-agency.exe' }
$script:ProbeResult = [pscustomobject]@{
    Ran = $true; TimedOut = $false; ExitCode = 0; Output = ''
    StandardOutput = '{"sessions":[]}'
}
Test-That 'Agency session discovery preserves the background command JSON' {
    (Get-BridgeAgencySessionJson) -eq '{"sessions":[]}'
}
$script:ProbeResult.TimedOut = $true
Test-That 'a timed-out Agency listing does not expose incomplete JSON' {
    (Get-BridgeAgencySessionJson) -eq ''
}
$script:ProbeResult = $savedProbeResult
${function:Get-BridgeAgencyPath} = $savedAgencyPath

$script:AgencyJson = ''
function Get-BridgeAgencySessionJson { $script:AgencyJson }

function Set-AgencySessions {
    param([object[]]$Sessions)
    $script:AgencyJson = (@{ sessions = $Sessions } | ConvertTo-Json -Depth 8)
}

$script:FakeSettings = @{ 'newSession.resumeCount' = 10 }

Set-AgencySessions -Sessions @(
    @{ session_id = 'aaaaaaaa-0000-0000-0000-000000000001'; summary = 'Older work'; folder = 'C:\repos\alpha'; can_resume = $true;  updated_at = '2026-09-20T10:00:00Z' }
    @{ session_id = 'bbbbbbbb-0000-0000-0000-000000000002'; summary = 'Newest work'; folder = 'C:\repos\beta'; can_resume = $true;  updated_at = '2026-09-23T10:00:00Z' }
    @{ session_id = 'cccccccc-0000-0000-0000-000000000003'; summary = 'A VS Code one'; folder = 'C:\repos\beta'; can_resume = $false; updated_at = '2026-09-23T11:00:00Z' }
    @{ session_id = 'dddddddd-0000-0000-0000-000000000004'; summary = '';             folder = 'C:\repos\beta'; can_resume = $true;  updated_at = '2026-09-21T10:00:00Z' }
)
$resume = @(Get-BridgeResumableSessions)

Test-That 'non-resumable sessions are dropped' { $resume.SessionId -notcontains 'cccccccc-0000-0000-0000-000000000003' }
Test-That 'the newest session comes first' { $resume[0].SessionId -eq 'bbbbbbbb-0000-0000-0000-000000000002' }
Test-That 'the label carries the summary and the folder' { $resume[0].Label -eq 'Newest work - beta' }
Test-That 'a session with no summary still gets a usable label' {
    ($resume | Where-Object { $_.SessionId -like 'dddddddd*' }).Label -match '^Session dddddddd'
}
Test-That 'the folder is carried through for the working directory' { $resume[0].Folder -eq 'C:\repos\beta' }

$excluded = @(Get-BridgeResumableSessions -Exclude @('bbbbbbbb-0000-0000-0000-000000000002'))
Test-That 'a live session is excluded' { $excluded.SessionId -notcontains 'bbbbbbbb-0000-0000-0000-000000000002' }

$limited = @(Get-BridgeResumableSessions -Limit 1)
Test-That 'the list honours its limit' { $limited.Count -eq 1 -and $limited[0].SessionId -eq 'bbbbbbbb-0000-0000-0000-000000000002' }

Set-AgencySessions -Sessions @(
    @{ session_id = 'aaaaaaaa-0000-0000-0000-000000000001'; summary = 'Same name'; folder = 'C:\repos\alpha'; can_resume = $true; updated_at = '2026-09-23T10:00:00Z' }
    @{ session_id = 'bbbbbbbb-0000-0000-0000-000000000002'; summary = 'Same name'; folder = 'C:\repos\alpha'; can_resume = $true; updated_at = '2026-09-22T10:00:00Z' }
)
$dupes = @(Get-BridgeResumableSessions)
Test-That 'two sessions with the same summary stay distinguishable' {
    $dupes.Count -eq 2 -and ($dupes.Label | Sort-Object -Unique).Count -eq 2
}

Set-AgencySessions -Sessions @(
    @{ session_id = 'eeeeeeee-0000-0000-0000-000000000005'; summary = ('z' * 400); folder = 'C:\repos\alpha'; can_resume = $true; updated_at = '2026-09-23T10:00:00Z' }
)
Test-That 'a very long summary is trimmed to stay a valid option' {
    (Get-BridgeResumableSessions)[0].Label.Length -le 130
}

$script:AgencyJson = 'not json at all'
Test-That 'malformed output yields an empty list rather than throwing' { @(Get-BridgeResumableSessions).Count -eq 0 }
$script:AgencyJson = ''
Test-That 'no Agency output yields an empty list' { @(Get-BridgeResumableSessions).Count -eq 0 }
$script:AgencyJson = '{"unexpected":true}'
Test-That 'output without a sessions array yields an empty list' { @(Get-BridgeResumableSessions).Count -eq 0 }

Write-Host ''
Write-Host '--- resuming across agents ---'

$savedPresence = @($script:AgencyPresent, $script:CopilotPresent, $script:ClaudePresent, $script:CodexPresent)
$script:AgencyPresent = $false; $script:CopilotPresent = $true; $script:ClaudePresent = $true; $script:CodexPresent = $true
$script:AgencyJson = ''
$script:FileEntries = @{
    claude  = @(New-FileEntry -Id 'c1' -Launcher 'claude' -Summary 'Claude work' -Folder 'C:\repos\alpha' -Updated '2026-09-27T10:00:00Z')
    copilot = @(New-FileEntry -Id 'p1' -Launcher 'copilot' -Summary 'Copilot work' -Folder 'C:\repos\beta' -Updated '2026-09-27T12:00:00Z')
    codex   = @(New-FileEntry -Id 'x1' -Launcher 'codex' -Summary 'Codex work' -Folder 'C:\repos\gamma' -Updated '2026-09-27T11:00:00Z')
}
$mixed = @(Get-BridgeResumableSessions)
Test-That 'without Agency, every agent''s sessions are offered' { ($mixed.SessionId -join ',') -eq 'p1,x1,c1' }
Test-That 'each keeps the agent that reopens it' { ($mixed.Launcher -join ',') -eq 'copilot,codex,claude' }
Test-That 'labels name the agent once the list mixes them' { $mixed[2].Label -eq 'Claude: Claude work - alpha' }

$script:CodexPresent = $false
Test-That 'an agent that is not installed contributes nothing' { @(Get-BridgeResumableSessions).SessionId -notcontains 'x1' }

$script:CopilotPresent = $false; $script:ClaudePresent = $true
Test-That 'with one agent the labels stay plain' { (@(Get-BridgeResumableSessions)[0]).Label -eq 'Claude work - alpha' }

# With Agency installed it speaks for Copilot; a session it also knows is listed once,
# under the agent whose files hold it.
$script:AgencyPresent = $true; $script:CopilotPresent = $true
Set-AgencySessions -Sessions @(
    @{ session_id = 'a1'; summary = 'Agency work'; folder = 'C:\repos\beta'; can_resume = $true; updated_at = '2026-09-27T13:00:00Z' }
    @{ session_id = 'c1'; summary = 'Claude work'; folder = 'C:\repos\alpha'; can_resume = $true; updated_at = '2026-09-27T10:00:00Z' }
)
$withAgency = @(Get-BridgeResumableSessions)
Test-That 'Agency replaces Copilot''s own store' { $withAgency.SessionId -notcontains 'p1' -and $withAgency.SessionId -contains 'a1' }
Test-That 'a session two sources know appears once, as its own agent' {
    @($withAgency | Where-Object SessionId -eq 'c1').Count -eq 1 -and ($withAgency | Where-Object SessionId -eq 'c1').Launcher -eq 'claude'
}
$script:AgencyJson = ''
Test-That 'and Copilot''s store fills in when Agency has nothing' { @(Get-BridgeResumableSessions).SessionId -contains 'p1' }

$script:AgencyPresent, $script:CopilotPresent, $script:ClaudePresent, $script:CodexPresent = $savedPresence
$script:FileEntries = @{ claude = @(); copilot = @(); codex = @() }

Write-Host ''
Write-Host '--- resume command lines ---'
$args1 = @(Get-BridgeNewSessionArguments -SessionId 'abc' -Launcher 'claude' -Resume -Prompt 'carry on')
Test-That 'Claude resumes with --resume, not --session-id' { ($args1 -join ' ') -eq '--resume abc -- carry on' }
$args2 = @(Get-BridgeNewSessionArguments -SessionId 'abc' -Launcher 'codex' -Resume -Prompt 'carry on')
Test-That 'Codex resumes with its resume subcommand' { ($args2 -join ' ') -match '(^| )resume abc -- carry on$' }
$args3 = @(Get-BridgeNewSessionArguments -SessionId 'abc' -Launcher 'codex' -Resume)
Test-That 'a Codex resume without a prompt just names the session' { ($args3 -join ' ') -match '(^| )resume abc$' }
# Its daemon has no console, so every hook it ran opened a window on Windows.
Test-That 'Codex is started without its background daemon' { $args2[0] -eq '--no-daemon' -and $args3[0] -eq '--no-daemon' }
Test-That 'with reasoning summaries on, for the card to stream' { ($args3 -join ' ') -match '-c model_reasoning_summary=detailed' }
Test-That 'the global options come before the resume subcommand' { $args2.IndexOf('--no-daemon') -lt $args2.IndexOf('resume') }
$args4 = @(Get-BridgeNewSessionArguments -SessionId 'abc' -Launcher 'copilot' -Resume)
Test-That 'Copilot resumes through --session-id as before' { $args4[0] -eq '--session-id' -and $args4[1] -eq 'abc' }
$args5 = @(Get-BridgeNewSessionArguments -SessionId 'abc' -Launcher 'claude')
Test-That 'a new Claude session still sets its id' { ($args5 -join ' ') -eq '--session-id abc' }

# --- discovery payloads ----------------------------------------------------------

Write-Host ''
Write-Host '--- the published entities ---'

# Everything the bridge publishes once per machine is scoped to that machine, because
# one Home Assistant is normally shared and a fixed id meant the second machine
# overwrote the first. Derived here rather than hard-coded so the suite passes on any
# machine, including a CI runner with a generated name.
$slug = Get-BridgeMachineSlug
$node = "agent_bridge_$slug"
function Uid { param([string]$Key) '"unique_id":"agent_bridge_' + $slug + '_' + $Key + '"' }
function Dev { '"identifiers":\["agent_bridge_' + $slug + '"\]' }

$script:MqttMsgs = @()
function Publish-CopilotMqttMessage {
    param([string]$Topic, [AllowEmptyString()][string]$Payload, [hashtable]$Headers, [switch]$Retain)
    $script:MqttMsgs += [pscustomobject]@{ Topic = $Topic; Payload = $Payload }
}

$script:MqttMsgs = @()
Publish-CopilotMqttNewSession -Workspaces @(
    [pscustomobject]@{ Label = 'alpha'; Path = $alpha }
    [pscustomobject]@{ Label = 'Beta project'; Path = $beta }
) -Profiles @('work', 'home') -Resumable @(
    [pscustomobject]@{ Label = 'Fix the thing - alpha'; SessionId = 'aaaaaaaa-0000-0000-0000-000000000001'; Folder = 'C:\repos\alpha' }
) -Tuning @{
    model   = @('Agent default', 'auto', 'gpt-5.4')
    effort  = @('Agent default', 'low', 'xhigh')
    context = @('Agent default', 'long_context')
} -Headers $headers

function Get-Config { param([string]$Match) ($script:MqttMsgs | Where-Object { $_.Topic -match $Match } | Select-Object -First 1).Payload }

Test-That 'a prompt text entity is published'  { (Get-Config "text/${node}/new_prompt/config") -match (Uid 'new_prompt') }
Test-That 'a prompt payload sensor is published beside it' {
    (Get-Config "sensor/${node}/new_prompt_payload/config") -match (Uid 'new_prompt_payload')
}
Test-That 'its text rides in an attribute, not the capped state' {
    $c = Get-Config "sensor/${node}/new_prompt_payload/config"
    $c -match '"json_attributes_topic"' -and $c -match '"value_template":"\{\{ value_json.at \}\}"'
} (Get-Config "sensor/${node}/new_prompt_payload/config")
Test-That 'a workspace select is published'    { (Get-Config "select/${node}/new_workspace/config") -match (Uid 'new_workspace') }
Test-That 'a profile select is published'      { (Get-Config "select/${node}/new_profile/config") -match (Uid 'new_profile') }
Test-That 'the profile select offers the profiles' { (Get-Config 'new_profile/config') -match 'work' -and (Get-Config 'new_profile/config') -match 'home' }
Test-That 'a launch button is published'       { (Get-Config "button/${node}/new_session/config") -match (Uid 'new_session') }
Test-That 'a resume select is published'       { (Get-Config "select/${node}/new_resume/config") -match (Uid 'new_resume') }
Test-That 'resume defaults to starting fresh'  { (Get-Config 'new_resume/config') -match '"options":\["New session"' }
Test-That 'the resume list offers the session' { (Get-Config 'new_resume/config') -match 'Fix the thing - alpha' }
Test-That 'a result sensor is published'       { (Get-Config "sensor/${node}/new_session_result/config") -match (Uid 'new_session_result') }
Test-That 'the select offers both workspaces'  { (Get-Config 'new_workspace/config') -match 'alpha' -and (Get-Config 'new_workspace/config') -match 'Beta project' }
Test-That 'they all land on the bridge device' { (Get-Config 'new_prompt/config') -match (Dev) }
Test-That 'the prompt box is optimistic (no state topic)' { (Get-Config 'new_prompt/config') -notmatch '"state_topic"' }
Test-That 'the result sensor does have a state topic' { (Get-Config 'new_session_result/config') -match '"state_topic"' }
Test-That 'a select is published for each tuning axis' {
    @('model', 'effort', 'context') | ForEach-Object { (Get-Config "select/${node}/new_$_/config") -match (Uid "new_$_") } |
        Where-Object { -not $_ } | Measure-Object | ForEach-Object { $_.Count -eq 0 }
}
Test-That 'each offers exactly what it was handed' {
    (Get-Config 'new_model/config') -match '"options":\["Agent default","auto","gpt-5.4"\]' -and
    (Get-Config 'new_context/config') -match '"options":\["Agent default","long_context"\]'
}
Test-That 'they are optimistic too, like the other selectors' {
    (Get-Config 'new_effort/config') -notmatch '"state_topic"'
}
Test-That 'and land on the same bridge device' { (Get-Config 'new_model/config') -match (Dev) }

$script:MqttMsgs = @()
Publish-CopilotMqttNewSession -Workspaces @() -Headers $headers
Test-That 'an empty list still publishes a valid select' {
    $cfg = Get-Config 'new_workspace/config'
    $cfg -match '"options":\[' -and $cfg -match 'no workspaces configured'
}
Test-That 'no profiles still publishes a valid profile select' {
    $cfg = Get-Config 'new_profile/config'
    $cfg -match '"options":\[' -and $cfg -match 'default'
}
# An MQTT select with no options is an invalid discovery payload, which Home Assistant
# rejects outright - and the generated dashboard names these entities literally, so a
# rejected one renders an "Entity not found" row where a control should be.
Test-That 'an agent that offers nothing on an axis still publishes a valid select' {
    $cfg = Get-Config 'new_model/config'
    $cfg -match '"options":\["Agent default"\]'
}

$script:MqttMsgs = @()
Set-CopilotMqttNewSessionResult -Text ('y' * 400) -Headers $headers
Test-That 'a long result is truncated to the state limit' {
    ($script:MqttMsgs | Where-Object { $_.Topic -match '/newsession/result$' } | Select-Object -First 1).Payload.Length -le 255
}

# --- the daemon reconcile --------------------------------------------------------

Write-Host ''
Write-Host '--- press handling ---'

$script:HaStates = @{}
$script:Launches = @()
$script:Results = @()
$script:Cleared = @()

function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    if (-not $script:HaStates.ContainsKey($EntityId)) { throw "no such entity $EntityId" }
    $value = $script:HaStates[$EntityId]
    # A hashtable stands for an entity whose attributes matter - the prompt payload
    # sensor, whose text is in an attribute because a state is capped at 255 chars.
    if ($value -is [hashtable]) {
        return [pscustomobject]@{ state = [string]$value.state; attributes = [pscustomobject]$value.attributes }
    }
    [pscustomobject]@{ state = $value }
}
function Publish-CopilotMqttNewSession { param([object[]]$Workspaces, [string[]]$Profiles = @(), [object[]]$Resumable = @(), [string[]]$Agents = @(), [hashtable]$Tuning = @{}, [string]$LastResult = '', [hashtable]$Headers) }
function Set-CopilotMqttNewSessionEntityIds { $false }
function Set-CopilotMqttNewSessionResult {
    param([string]$Text = '', [hashtable]$Headers)
    $script:Results += $Text
}
function Start-BridgeCopilotSession {
    param(
        [string]$WorkingDirectory, [string]$Prompt = '', [string]$SessionId = '', [string]$AgencyProfile = '',
        [string]$Launcher = '', [string]$Model = '', [string]$Effort = '', [string]$Context = '', [switch]$Resume
    )
    $script:Launches += [pscustomobject]@{
        Directory = $WorkingDirectory; Prompt = $Prompt; AgencyProfile = $AgencyProfile
        SessionId = $SessionId; Resumed = $Resume.IsPresent; Launcher = $Launcher
        Model = $Model; Effort = $Effort; Context = $Context
    }
    $id = if ($SessionId) { $SessionId } else { '11111111-2222-3333-4444-555555555555' }
    # This process stands in for the launched one, so it counts as running.
    [pscustomobject]@{
        Launched = $true; SessionId = $id; ProcessId = $PID; Launcher = 'agency'; Detail = "started pid $PID"
        Model = $Model; Effort = $Effort; Context = $Context
    }
}
# What the launched session is doing: registered yet, and what its screen shows.
$script:FakeRegistered = $false
$script:FakeTrustScreen = ''
$script:TrustAnswers = @()
function Test-BridgeSessionRegistered { param([string]$SessionId, [string]$Launcher, [DateTimeOffset]$Since) $script:FakeRegistered }
function Read-BridgeTrustPrompt { param([int]$ProcessId) $script:FakeTrustScreen }
function Send-BridgeTrustAnswer { param([int]$ProcessId, [string]$Selection) $script:TrustAnswers += $Selection; 'ok:2' }
function Invoke-HomeAssistantService {
    param([string]$Domain, [string]$Service, [hashtable]$Data, [hashtable]$Headers)
    $script:Cleared += "$Domain.$Service"
}
$script:PromptPayloadCleared = 0
function Clear-CopilotMqttNewSessionPrompt {
    param([string]$Slug, [hashtable]$Headers)
    $script:PromptPayloadCleared++
}

function Reset-NewSessionTest {
    param(
        [string]$Press,
        [string]$Workspace = 'alpha',
        [string]$Prompt = 'do the thing',
        [string]$ProfileState = 'work',
        [string]$ResumeState = 'New session',
        [string]$AgentState = 'unknown',
        [string]$ModelState = 'Agent default',
        [string]$EffortState = 'Agent default',
        [string]$ContextState = 'Agent default'
    )
    $script:Launches = @()
    $script:Results = @()
    $script:Cleared = @()
    $script:DaemonLaunchedTuning = @{}
    $script:DaemonNewSessionPublished = $true
    $script:DaemonNewSessionSignature = "alpha=$alpha"
    $script:DaemonNewSessionLastPress = ''
    $script:DaemonStartedAt = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z')
    $script:HaStates = @{
        "button.agent_bridge_${slug}_new_session"   = $Press
        "select.agent_bridge_${slug}_new_workspace" = $Workspace
        "select.agent_bridge_${slug}_new_profile"   = $ProfileState
        "select.agent_bridge_${slug}_new_resume"    = $ResumeState
        "select.agent_bridge_${slug}_new_agent"     = $AgentState
        "select.agent_bridge_${slug}_new_model"     = $ModelState
        "select.agent_bridge_${slug}_new_effort"    = $EffortState
        "select.agent_bridge_${slug}_new_context"   = $ContextState
        "text.agent_bridge_${slug}_new_prompt"      = $Prompt
    }
}

# No resumable sessions unless a test asks for them, and an empty live set.
$script:AgencyJson = ''
$noLive = @{}
function Reset-ResumeCache { $script:DaemonResumeCache = @(); $script:DaemonResumeCacheAt = [DateTimeOffset]::MinValue }
Reset-ResumeCache

# Agency is the launcher for these, so the profile path is exercised.
$script:AgencyPresent = $true
$script:FakeSettings = @{
    'newSession.workspaces' = @($alpha, $beta)
    'newSession.launcher'   = 'agency'
    'newSession.profiles'   = @('work', 'home', 'local')
}

Reset-NewSessionTest -Press '2026-06-01T12:00:00+00:00'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'a fresh press launches a session' { $script:Launches.Count -eq 1 }
Test-That 'it launches in the selected workspace' { $script:Launches[0].Directory -eq $alpha }
Test-That 'it passes the typed prompt' { $script:Launches[0].Prompt -eq 'do the thing' }
Test-That 'it passes the selected profile' { $script:Launches[0].AgencyProfile -eq 'work' }
Test-That 'an untouched tuning selector passes nothing, so the agent decides' {
    $script:Launches[0].Model -eq '' -and $script:Launches[0].Effort -eq '' -and $script:Launches[0].Context -eq ''
}
Test-That 'it reports the launch while it runs' { ($script:Results -join ' ') -match 'Starting' }
# The session's own card is the confirmation; the note is cleared so the card shows
# it only when there is something to say. Registration is checked on a later pass.
$script:FakeRegistered = $true
$script:DaemonPendingLaunch.LastCheck = [DateTimeOffset]::MinValue
Update-DaemonPendingLaunch -Headers $headers
Test-That 'and clears the note once the session registers' { $script:Results[-1] -eq '' }
$script:FakeRegistered = $false
$script:DaemonReconcileNow = $false
Test-That 'the result names the profile' { ($script:Results -join ' ') -match 'work' }
Test-That 'it clears the prompt box afterwards' { $script:Cleared -contains 'text.set_value' }

Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'the same press does not launch twice' { $script:Launches.Count -eq 1 }

# The three tuning selectors, at press time. They are read like the workspace and the
# prompt - only in combination with a press - and validated against the agent actually
# being launched, so a value left over from a different agent cannot reach its command
# line.
Reset-NewSessionTest -Press '2026-06-01T12:01:00+00:00' -ModelState 'gpt-5.4' -EffortState 'xhigh' -ContextState 'long_context'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'a chosen model, effort and context all reach the launch' {
    $script:Launches[0].Model -eq 'gpt-5.4' -and $script:Launches[0].Effort -eq 'xhigh' -and
    $script:Launches[0].Context -eq 'long_context'
}
Test-That 'and are remembered for the session that was started, so its card can say so' {
    $entry = $script:DaemonLaunchedTuning['11111111-2222-3333-4444-555555555555']
    $null -ne $entry -and $entry.Model -eq 'gpt-5.4' -and $entry.Effort -eq 'xhigh'
}

Reset-NewSessionTest -Press '2026-06-01T12:02:00+00:00' -EffortState 'not-an-effort --allow-all'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'a value the agent does not offer is dropped rather than passed on' {
    $script:Launches.Count -eq 1 -and $script:Launches[0].Effort -eq ''
}
Test-That 'and it does not refuse the launch the way an unknown profile does' {
    ($script:Results -join ' ') -notmatch 'Unknown'
}

Reset-NewSessionTest -Press '2025-01-01T00:00:00+00:00'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'a press from before the daemon started is ignored' { $script:Launches.Count -eq 0 }
Reset-NewSessionTest -Press 'unknown'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'an unknown button state is ignored' { $script:Launches.Count -eq 0 }

Reset-NewSessionTest -Press '2026-06-01T12:05:00+00:00' -Workspace 'somewhere-else'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'an unapproved workspace refuses to launch' { $script:Launches.Count -eq 0 }
Test-That 'and says why' { ($script:Results -join ' ') -match 'Unknown workspace' }

Reset-NewSessionTest -Press '2026-06-01T12:06:00+00:00' -Workspace 'unknown'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'an untouched selector falls back to the first workspace' {
    $script:Launches.Count -eq 1 -and $script:Launches[0].Directory -eq $alpha
}

Reset-NewSessionTest -Press '2026-06-01T12:07:00+00:00' -Prompt 'unknown'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'an untouched prompt box launches with no prompt' {
    $script:Launches.Count -eq 1 -and $script:Launches[0].Prompt -eq ''
}
# An untouched box reads `unknown`, which renders as "(empty value)". Priming it to
# blank is the point of the defaults pass, so one write here is correct - what must
# not happen is the post-launch clear running as well for a prompt that was empty.
Test-That 'an untouched prompt box is primed blank rather than left unknown' {
    $script:Cleared -contains 'text.set_value'
}
Test-That 'and it is written exactly once, not primed and then cleared again' {
    @($script:Cleared | Where-Object { $_ -eq 'text.set_value' }).Count -eq 1
}

Reset-NewSessionTest -Press '2026-06-01T12:10:00+00:00' -ProfileState 'home'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'a different profile is honoured' { $script:Launches[0].AgencyProfile -eq 'home' }

Write-Host ''
Write-Host '--- resuming a previous session ---'

# A resumable session whose folder really exists, so the resume path can assert on
# the working directory it chooses.
Set-AgencySessions -Sessions @(
    @{ session_id = 'f0f0f0f0-1111-2222-3333-444444444444'; summary = 'Earlier work'; folder = $beta; can_resume = $true; updated_at = '2026-09-23T10:00:00Z' }
)
$resumeLabel = 'Earlier work - beta'

Reset-NewSessionTest -Press '2026-06-01T12:20:00+00:00' -ResumeState $resumeLabel
Reset-ResumeCache
$script:DaemonNewSessionSignature = ''
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'a resume selection launches that session id' {
    $script:Launches.Count -eq 1 -and $script:Launches[0].SessionId -eq 'f0f0f0f0-1111-2222-3333-444444444444'
}
Test-That 'it is flagged as a resume' { $script:Launches[0].Resumed }
Test-That 'it uses the session own folder, not the workspace' { $script:Launches[0].Directory -eq $beta }
Test-That 'the profile still applies to a resume' { $script:Launches[0].AgencyProfile -eq 'work' }
Test-That 'the result says it resumed' { ($script:Results -join ' ') -match 'Resum' }

Reset-NewSessionTest -Press '2026-06-01T12:21:00+00:00' -ResumeState 'New session'
Reset-ResumeCache
$script:DaemonNewSessionSignature = ''
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'the New session option starts a fresh session' {
    $script:Launches.Count -eq 1 -and -not $script:Launches[0].Resumed -and $script:Launches[0].SessionId -eq ''
}
Test-That 'and uses the selected workspace' { $script:Launches[0].Directory -eq $alpha }

Reset-NewSessionTest -Press '2026-06-01T12:22:00+00:00' -ResumeState 'Something that vanished - old'
Reset-ResumeCache
$script:DaemonNewSessionSignature = ''
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'a stale resume selection refuses to launch' { $script:Launches.Count -eq 0 }
Test-That 'and says so' { ($script:Results -join ' ') -match 'no longer resumable' }

# A live session must never be offered for resume: two CLIs on one transcript.
Reset-ResumeCache
$live = @{ 'f0f0f0f0-1111-2222-3333-444444444444' = $true }
Test-That 'a live session is kept out of the resume list' {
    @(Get-DaemonResumableSessions -LiveSessionIds @($live.Keys)).Count -eq 0
}

# The Agency query is expensive, so it must be cached between reconciles.
Reset-ResumeCache
$script:AgencyJsonCalls = 0
function Get-BridgeAgencySessionJson { $script:AgencyJsonCalls++; $script:AgencyJson }
$null = Get-DaemonResumableSessions -LiveSessionIds @()
$null = Get-DaemonResumableSessions -LiveSessionIds @()
$null = Get-DaemonResumableSessions -LiveSessionIds @()
Test-That 'the session list is fetched once within the cache window' { $script:AgencyJsonCalls -eq 1 }
$script:DaemonResumeCacheAt = [DateTimeOffset]::Now.AddSeconds(-9999)
$null = Get-DaemonResumableSessions -LiveSessionIds @()
Test-That 'an expired cache refetches' { $script:AgencyJsonCalls -eq 2 }
$null = Get-DaemonResumableSessions -LiveSessionIds @() -Force
Test-That 'a forced refresh refetches' { $script:AgencyJsonCalls -eq 3 }

# Launching a session spawns Agency, and a concurrent `hub list-local-sessions`
# returns nothing. Caching that as truth emptied the resume dropdown for minutes.
Reset-ResumeCache
Set-AgencySessions -Sessions @(
    @{ session_id = 'f0f0f0f0-1111-2222-3333-444444444444'; summary = 'Earlier work'; folder = $beta; can_resume = $true; updated_at = '2026-09-23T10:00:00Z' }
)
$good = @(Get-DaemonResumableSessions -LiveSessionIds @())
Test-That 'a good fetch populates the list' { $good.Count -eq 1 }

$script:AgencyJson = '{"sessions":[]}'
$stillGood = @(Get-DaemonResumableSessions -LiveSessionIds @() -Force)
Test-That 'an empty fetch does not wipe a list that had entries' { $stillGood.Count -eq 1 }
Test-That 'and it retries sooner than the full interval' {
    ([DateTimeOffset]::Now - $script:DaemonResumeCacheAt).TotalSeconds -gt $script:DaemonConfig.ResumeRetrySeconds
}

Reset-ResumeCache
$script:AgencyJson = '{"sessions":[]}'
Test-That 'an empty fetch with nothing cached is simply empty' {
    @(Get-DaemonResumableSessions -LiveSessionIds @()).Count -eq 0
}

Write-Host ''
Write-Host '--- press handling, continued ---'
$script:AgencyJson = ''
Reset-ResumeCache

Reset-NewSessionTest -Press '2026-06-01T12:11:00+00:00' -ProfileState 'unknown'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'an untouched profile selector falls back to the first profile' {
    $script:Launches.Count -eq 1 -and $script:Launches[0].AgencyProfile -eq 'work'
}

Reset-NewSessionTest -Press '2026-06-01T12:12:00+00:00' -ProfileState 'prod --yolo'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'an unapproved profile refuses to launch' { $script:Launches.Count -eq 0 }
Test-That 'and says which profile' { ($script:Results -join ' ') -match 'Unknown profile' }

# Under the plain copilot launcher the profile is irrelevant and must not be passed.
$script:FakeSettings = @{
    'newSession.workspaces' = @($alpha, $beta)
    'newSession.launcher'   = 'copilot'
    'newSession.profiles'   = @('work', 'home', 'local')
}
Reset-NewSessionTest -Press '2026-06-01T12:13:00+00:00' -ProfileState 'home'
$script:DaemonNewSessionSignature = ''
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'the copilot launcher ignores the profile entirely' {
    $script:Launches.Count -eq 1 -and $script:Launches[0].AgencyProfile -eq ''
}

$script:FakeSettings = @{
    'newSession.workspaces' = @($alpha, $beta)
    'newSession.launcher'   = 'agency'
    'newSession.profiles'   = @('work', 'home', 'local')
}

Write-Host ''
Write-Host '--- choosing the agent ---'

$script:ClaudePresent = $true

Reset-NewSessionTest -Press '2026-06-01T12:30:00+00:00' -AgentState 'unknown'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'an untouched agent selector launches the default agent' {
    $script:Launches.Count -eq 1 -and $script:Launches[0].Launcher -eq 'agency'
}

Reset-NewSessionTest -Press '2026-06-01T12:31:00+00:00' -AgentState 'Claude' -ProfileState 'home'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'choosing Claude launches Claude' { $script:Launches.Count -eq 1 -and $script:Launches[0].Launcher -eq 'claude' }
Test-That 'an Agency profile is not passed to Claude' { $script:Launches[0].AgencyProfile -eq '' }
Test-That 'the result names the agent' { ($script:Results -join ' ') -match 'Claude' }

Reset-NewSessionTest -Press '2026-06-01T12:32:00+00:00' -AgentState 'Codex'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'an agent that is not installed refuses to launch' { $script:Launches.Count -eq 0 }
Test-That 'and says which agent' { ($script:Results -join ' ') -match "Unknown agent 'Codex'" }

Write-Host ''
Write-Host '--- following a launch, and Claude asking to trust its folder ---'

# The daemon used to wait up to 25 s on every launch, and longer for a trust answer,
# stalling replies and streaming. It now follows the launch a pass at a time.
function Invoke-FollowUp { $script:DaemonPendingLaunch.LastCheck = [DateTimeOffset]::MinValue; Update-DaemonPendingLaunch -Headers $headers }

$script:DaemonPendingLaunch = $null
$script:FakeRegistered = $false
$script:FakeTrustScreen = ''
$script:TrustAnswers = @()
Reset-NewSessionTest -Press '2026-06-01T12:40:00+00:00' -AgentState 'Claude'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'a press starts Claude straight away' { $script:Launches.Count -eq 1 -and $script:Launches[0].Launcher -eq 'claude' }
Test-That 'and returns without waiting for it' { $null -ne $script:DaemonPendingLaunch -and ($script:Results -join ' ') -match 'Starting Claude' }

$script:Results = @()
$script:FakeTrustScreen = 'no'
Invoke-FollowUp
Test-That 'when Claude asks to trust the folder, the note asks for a second press' {
    ($script:Results -join ' ') -match 'asking whether to trust .* Press Launch again'
}
Test-That 'and nothing is answered on the first press alone' { $script:TrustAnswers.Count -eq 0 }

Invoke-FollowUp
Test-That 'the question is announced once, not on every pass' { @($script:Results | Where-Object { $_ -match 'asking' }).Count -eq 1 }

Reset-NewSessionTest -Press '2026-06-01T12:40:20+00:00' -AgentState 'Claude'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'a second press confirms instead of starting another session' { $script:Launches.Count -eq 0 -and $script:DaemonPendingLaunch.TrustConfirmed }
Test-That 'and answers from the highlighted option' { ($script:TrustAnswers -join ',') -eq 'no' }

$script:FakeTrustScreen = ''
$script:FakeRegistered = $true
$script:Results = @()
$script:DaemonReconcileNow = $false
Invoke-FollowUp
Test-That 'once it registers the follow-up ends' { $null -eq $script:DaemonPendingLaunch }
Test-That 'the note clears, since its card says the rest' { $script:Results[-1] -eq '' }
Test-That 'and a reconcile is asked for at once' { $script:DaemonReconcileNow }
$script:DaemonReconcileNow = $false

# A question nobody confirms is left for the window, not answered.
$script:DaemonPendingLaunch = [pscustomobject]@{ SessionId = 's'; ProcessId = $PID; Launcher = 'claude'; Label = 'alpha'; Verb = 'Started'
    Since = [DateTimeOffset]::Now.AddMinutes(-3); LastCheck = [DateTimeOffset]::MinValue
    TrustAskedAt = [DateTimeOffset]::Now.AddMinutes(-3); TrustConfirmed = $false; TrustAnswers = 0 }
$script:FakeRegistered = $false
$script:FakeTrustScreen = 'no'
$script:TrustAnswers = @()
$script:Results = @()
Invoke-FollowUp
Test-That 'an unconfirmed question expires after two minutes' { $null -eq $script:DaemonPendingLaunch -and ($script:Results -join ' ') -match 'answer it in its window' }
Test-That 'without being answered' { $script:TrustAnswers.Count -eq 0 }

Reset-NewSessionTest -Press '2026-06-01T12:41:00+00:00' -AgentState 'Claude'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'so a later press starts a new session again' { $script:Launches.Count -eq 1 }

$script:DaemonPendingLaunch.ProcessId = 999999
$script:FakeTrustScreen = ''
$script:Results = @()
Invoke-FollowUp
Test-That 'a session that closes before registering is reported' { $null -eq $script:DaemonPendingLaunch -and ($script:Results -join ' ') -match 'closed before it started' }

$script:DaemonPendingLaunch = [pscustomobject]@{ SessionId = 's'; ProcessId = $PID; Launcher = 'claude'; Label = 'alpha'; Verb = 'Started'
    Since = [DateTimeOffset]::Now; LastCheck = [DateTimeOffset]::Now; TrustAskedAt = $null; TrustConfirmed = $false; TrustAnswers = 0 }
$script:FakeRegistered = $true
Update-DaemonPendingLaunch -Headers $headers
Test-That 'follow-ups are spaced out, not run on every 100 ms tick' { $null -ne $script:DaemonPendingLaunch }
$script:DaemonPendingLaunch = $null
$script:FakeRegistered = $false

Set-AgencySessions -Sessions @(
    @{ session_id = 'f0f0f0f0-1111-2222-3333-444444444444'; summary = 'Earlier work'; folder = $beta; can_resume = $true; updated_at = '2026-09-23T10:00:00Z' }
)
Reset-NewSessionTest -Press '2026-06-01T12:33:00+00:00' -AgentState 'Claude' -ResumeState 'Earlier work - beta'
Reset-ResumeCache
$script:DaemonNewSessionSignature = ''
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'an Agency session resumes in Agency whichever agent is selected' {
    $script:Launches.Count -eq 1 -and $script:Launches[0].Resumed -and $script:Launches[0].Launcher -eq 'agency'
}

# And a Claude session resumes in Claude, with no Agency profile, even with Copilot
# selected for new sessions.
$script:AgencyJson = ''
$script:FileEntries = @{ claude = @(New-FileEntry -Id '9e9e9e9e-0000-0000-0000-000000000001' -Launcher 'claude' -Summary 'Claude task' -Folder $beta -Updated '2026-09-27T10:00:00Z'); copilot = @(); codex = @() }
Reset-NewSessionTest -Press '2026-06-01T12:33:30+00:00' -AgentState 'Copilot' -ResumeState 'Claude task - beta'
Reset-ResumeCache
$script:DaemonNewSessionSignature = ''
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'a Claude session resumes in Claude whichever agent is selected' {
    $script:Launches.Count -eq 1 -and $script:Launches[0].Resumed -and $script:Launches[0].Launcher -eq 'claude' -and
        $script:Launches[0].SessionId -eq '9e9e9e9e-0000-0000-0000-000000000001'
}
Test-That 'in its own folder, and without an Agency profile' { $script:Launches[0].Directory -eq $beta -and -not $script:Launches[0].AgencyProfile }
$script:FileEntries = @{ claude = @(); copilot = @(); codex = @() }
$script:AgencyJson = ''
Reset-ResumeCache
$script:ClaudePresent = $false

Reset-NewSessionTest -Press '2026-06-01T12:08:00+00:00' -Workspace 'unknown'
$script:FakeSettings = @{ 'newSession.workspaces' = @() }
$script:DaemonNewSessionSignature = ''
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'no configured workspaces refuses launch and explains the missing approval' {
    $script:Launches.Count -eq 0 -and ($script:Results -join ' ') -match 'No workspaces configured'
}

$script:FakeSettings = @{ 'newSession.enabled' = $false; 'newSession.workspaces' = @($alpha) }
Reset-NewSessionTest -Press '2026-06-01T12:09:00+00:00'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'the whole feature can be turned off' { $script:Launches.Count -eq 0 -and $script:Results.Count -eq 0 }

Write-Host ''
Write-Host '--- Codex without a first message ---'
# Codex creates its session only on its first message, so one opened without a
# prompt is launched, then waits for a message the card can send it.
$script:FakeSettings = @{ 'newSession.workspaces' = @($alpha) }
$script:CodexPresent = $true
$script:FakeRegistered = $false
$script:Sent = @()
function Send-CopilotSessionPrompt {
    param([string]$SessionId, [string]$Text, [int]$ProcessId)
    $script:Sent += [pscustomobject]@{ Text = $Text; ProcessId = $ProcessId }
    [pscustomobject]@{ Delivered = $true; Detail = 'ok:5' }
}
Reset-NewSessionTest -Press '2026-06-01T12:39:00+00:00' -AgentState 'Codex' -Prompt ''
$script:DaemonPendingLaunch = $null
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'a Codex launch needs no first message from you' { $script:Launches.Count -eq 1 -and $script:Launches[0].Launcher -eq 'codex' }
Test-That 'it is given a short opening message, so it creates its session and attaches' {
    $script:Launches[0].Prompt -eq $script:DaemonConfig.CodexStartPrompt -and -not $script:DaemonPendingLaunch.AwaitingFirstMessage
}
Reset-NewSessionTest -Press '2026-06-01T12:39:30+00:00' -AgentState 'Claude' -Prompt ''
$script:ClaudePresent = $true
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'other agents start with no message at all' { $script:Launches.Count -eq 1 -and $script:Launches[0].Prompt -eq '' }
$script:ClaudePresent = $false

# With the opening message turned off, the launch waits for one from the card.
$script:FakeSettings = @{ 'newSession.workspaces' = @($alpha); 'newSession.codexStartPrompt' = '' }
Reset-NewSessionTest -Press '2026-06-01T12:40:00+00:00' -AgentState 'Codex' -Prompt ''
$script:DaemonPendingLaunch = $null
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'a Codex launch without the opening message still starts' { $script:Launches.Count -eq 1 -and $script:Launches[0].Launcher -eq 'codex' }
Test-That 'and waits for one rather than timing out' { $script:DaemonPendingLaunch.AwaitingFirstMessage }
$script:DaemonPendingLaunch.Since = [DateTimeOffset]::Now.AddMinutes(-5)
$script:DaemonPendingLaunch.LastCheck = [DateTimeOffset]::MinValue
Update-DaemonPendingLaunch -Headers $headers
Test-That 'past the usual 90 s it is still waited on' { $null -ne $script:DaemonPendingLaunch }
Test-That 'and the note offers to send the first message from the card' { ($script:Results -join ' ') -match 'appears here after its first message' }

# A second press with a first message typed sends it into that window.
$script:HaStates["button.agent_bridge_${slug}_new_session"] = '2026-06-01T12:41:00+00:00'
$script:HaStates["text.agent_bridge_${slug}_new_prompt"] = 'fix the build'
$script:Launches = @()
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'a second press sends the first message to the waiting Codex' {
    $script:Sent.Count -eq 1 -and $script:Sent[0].Text -eq 'fix the build' -and $script:Sent[0].ProcessId -eq $PID
}
Test-That 'instead of launching another session' { $script:Launches.Count -eq 0 }
Test-That 'and the launch is then followed until Codex registers' {
    $null -ne $script:DaemonPendingLaunch -and -not $script:DaemonPendingLaunch.AwaitingFirstMessage
}

# With the agent switched, a press is a new launch and the Codex window is left be.
Reset-NewSessionTest -Press '2026-06-01T12:42:00+00:00' -AgentState 'Codex' -Prompt ''
Sync-DaemonNewSession -Headers $headers -Live $noLive
$script:Sent = @()
$script:HaStates["button.agent_bridge_${slug}_new_session"] = '2026-06-01T12:43:00+00:00'
$script:HaStates["select.agent_bridge_${slug}_new_agent"] = 'Copilot'
$script:HaStates["text.agent_bridge_${slug}_new_prompt"] = 'something else'
$script:Launches = @()
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'a press for another agent launches it instead' {
    $script:Sent.Count -eq 0 -and $script:Launches.Count -eq 1 -and $script:Launches[0].Launcher -eq 'copilot'
}
$script:DaemonPendingLaunch = $null
$script:CodexPresent = $false

Write-Host ''
Write-Host '--- a first message longer than a text entity can hold ---'
# Home Assistant caps a text entity at 255 characters, which is far too short to hand
# a new session the context of what it is taking over. The launch card publishes the
# whole prompt to a sensor whose attribute has no cap; the text box stays for a
# dashboard whose card is too old to know about it.
$payloadEntity = "sensor.agent_bridge_${slug}_new_prompt_payload"
$longPrompt = ('Take over the migration. ' * 40).Trim()

Test-That 'the test prompt is longer than a text entity allows' { $longPrompt.Length -gt 255 } "$($longPrompt.Length)"

Reset-NewSessionTest -Press '2026-06-01T13:00:00+00:00' -Prompt 'the short one'
$script:HaStates[$payloadEntity] = @{
    state = '2026-06-01T13:00:00+00:00'
    attributes = @{ at = '2026-06-01T13:00:00+00:00'; text = $longPrompt; card_version = '1.18.0' }
}
Test-That 'the payload is what the launch reads' {
    (Get-DaemonLaunchPrompt -Headers $headers) -eq $longPrompt
} "$((Get-DaemonLaunchPrompt -Headers $headers).Length) chars"
Test-That 'and it is not truncated on the way through' {
    (Get-DaemonLaunchPrompt -Headers $headers).Length -gt 255
}

$script:Launches = @()
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'so the session is started with the whole prompt' {
    $script:Launches.Count -eq 1 -and $script:Launches[0].Prompt -eq $longPrompt
} "$($script:Launches.Count) launch(es), $($script:Launches[0].Prompt.Length) chars"

# An empty payload must not mask a prompt typed into the box by an older card.
Reset-NewSessionTest -Press '2026-06-01T13:05:00+00:00' -Prompt 'typed in the old box'
$script:HaStates[$payloadEntity] = @{ state = 'unknown'; attributes = @{} }
Test-That 'an empty payload falls back to the text box' {
    (Get-DaemonLaunchPrompt -Headers $headers) -eq 'typed in the old box'
} (Get-DaemonLaunchPrompt -Headers $headers)

# A bridge that never published the sensor at all - the stub throws for it, exactly as
# Home Assistant 404s - must not lose the typed prompt either.
Reset-NewSessionTest -Press '2026-06-01T13:06:00+00:00' -Prompt 'no payload sensor here'
Test-That 'a missing payload sensor falls back rather than throwing' {
    (Get-DaemonLaunchPrompt -Headers $headers) -eq 'no payload sensor here'
} (Get-DaemonLaunchPrompt -Headers $headers)

# Both boxes are emptied after a launch, or the retained payload would start the next
# session with the same prompt.
Reset-NewSessionTest -Press '2026-06-01T13:10:00+00:00' -Prompt ''
$script:HaStates[$payloadEntity] = @{
    state = '2026-06-01T13:10:00+00:00'
    attributes = @{ at = '2026-06-01T13:10:00+00:00'; text = $longPrompt }
}
$script:Cleared = @()
$script:PromptPayloadCleared = 0
$script:Launches = @()
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'the retained payload is cleared once it has been used' { $script:PromptPayloadCleared -ge 1 } "$script:PromptPayloadCleared"
Test-That 'and the text box is blanked alongside it' { $script:Cleared -contains 'text.set_value' } ($script:Cleared -join ',')

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $testLogFile -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
