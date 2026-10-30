#Requires -Version 7.0
<#
.SYNOPSIS
    A folder that is not a link is not refused as one, a daemon's warning is said once
    an hour and never to a console, and the decision log cannot grow without bound.

.DESCRIPTION
    On 2026-10-30 the decision log reached 506 MB, nearly all of it one line written
    about once a second (#265):

        launch warning: Workspace approval could not be established: Workspace
        directory link could not be resolved: ...\OneDrive - Microsoft\Documents\...
        (warning host failed: The Win32 internal error "The handle is invalid." ...)

    Three things went wrong at once, and each is asserted here on its own:

      - OneDrive's Files On-Demand folders are reparse points that are not links. The
        workspace resolver asked .NET to follow every reparse point, got nothing back
        for those, and refused them as broken links.
      - The daemon re-asks the same approval question every pass, so the same warning
        came back every pass. A daemon now logs each one at most once an hour.
      - It wrote the warning to a console it does not have, and logged the failure to
        do so. A daemon now logs its warnings and leaves the console alone.

    And the log had no bound at all, so it now rolls over to a .1 file.
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

$sandbox = Join-Path ([IO.Path]::GetTempPath()) "bridge-warnings-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
[void][IO.Directory]::CreateDirectory($sandbox)

# Everything logged, instead of the file - except in the rotation section, which uses
# the real writer against a file of its own.
$script:RealLog = ${function:Write-DecisionBridgeLog}
$script:Logged = [Collections.Generic.List[string]]::new()
function Write-DecisionBridgeLog { param([Parameter(Mandatory)][string]$Message) $script:Logged.Add($Message) }

try {
    Write-Host "`n--- a OneDrive folder is a folder ---"
    # How .NET reports a Files On-Demand folder: a reparse point with no link target,
    # which ResolveLinkTarget cannot follow. Only that one folder is made to look so;
    # everything around it is the real file system.
    $cloud = Join-Path $sandbox 'OneDrive - Contoso'
    $documents = Join-Path $cloud 'Documents'
    [void][IO.Directory]::CreateDirectory($documents)
    $script:RealEntry = ${function:Get-BridgeWorkspaceEntry}
    function Get-BridgeWorkspaceEntry {
        param([Parameter(Mandatory)][string]$Path)
        $real = & $script:RealEntry -Path $Path
        if ([IO.Path]::GetFileName($Path.TrimEnd('\', '/')) -ne 'OneDrive - Contoso') { return $real }
        $cloudEntry = [pscustomobject]@{
            Exists = $real.Exists
            Attributes = [IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint
            LinkTarget = $null
            FullName = $real.FullName
        }
        $cloudEntry | Add-Member -MemberType ScriptMethod -Name ResolveLinkTarget -Value { param($ReturnFinalTarget) $null }
        $cloudEntry
    }

    $resolved = $null
    $failure = ''
    try { $resolved = Resolve-BridgeWorkspaceDirectory -Path $documents } catch { $failure = $_.Exception.Message }
    Test-That 'a folder under a non-link reparse point resolves' { $null -ne $resolved } $failure
    Test-That 'to where it is, since it points nowhere else' {
        [IO.Path]::GetFileName($resolved) -eq 'Documents' -and
        [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($resolved)) -eq 'OneDrive - Contoso'
    } "$resolved"

    $script:Logged.Clear()
    $said = @(& { [void](Test-BridgeWorkspacePathApproved -Path $documents) } 3>&1)
    Test-That 'an unconfigured OneDrive folder is simply not approved' { -not (Test-BridgeWorkspacePathApproved -Path $documents) }
    Test-That 'without a warning, because nothing went wrong' {
        $said.Count -eq 0 -and $script:Logged.Count -eq 0
    } ((@($said | ForEach-Object { "$_" }) + @($script:Logged)) -join ' | ')

    # A real link still has to be followed: that is the whole point of resolving, and
    # approval compares where a folder really is.
    $target = Join-Path $sandbox 'real-target'
    [void][IO.Directory]::CreateDirectory($target)
    $link = Join-Path $sandbox 'a-link'
    New-Item -ItemType $(if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }) -Path $link -Target $target | Out-Null
    Test-That 'while a junction or symlink is still followed to its target' {
        [IO.Path]::GetFileName((Resolve-BridgeWorkspaceDirectory -Path $link)) -eq 'real-target'
    }

    Write-Host "`n--- a daemon's warnings ---"
    $script:BridgeLaunchWarningsToLog = $true
    $script:BridgeLaunchWarningLogged.Clear()
    $script:Logged.Clear()
    $console = @(& { Write-BridgeLaunchWarning 'Workspace approval could not be established: somewhere' } 3>&1)
    Test-That 'go to the log' { $script:Logged.Count -eq 1 -and $script:Logged[0] -eq 'launch warning: Workspace approval could not be established: somewhere' } ($script:Logged -join ' | ')
    Test-That 'and not to a console' { $console.Count -eq 0 } "$($console.Count) record(s)"

    1..5 | ForEach-Object { Write-BridgeLaunchWarning 'Workspace approval could not be established: somewhere' }
    Test-That 'the same warning on every later pass is not written again' { $script:Logged.Count -eq 1 } "$($script:Logged.Count) lines"
    Write-BridgeLaunchWarning 'Workspace approval could not be established: elsewhere'
    Test-That 'a different one still is' { $script:Logged.Count -eq 2 } "$($script:Logged.Count) lines"
    # An hour on, so a problem that is still there is still visible in a log someone
    # opens today.
    $script:BridgeLaunchWarningLogged['Workspace approval could not be established: somewhere'] = [DateTimeOffset]::Now.AddMinutes(-61)
    Write-BridgeLaunchWarning 'Workspace approval could not be established: somewhere'
    Test-That 'and the first is said again an hour later' { $script:Logged.Count -eq 3 } "$($script:Logged.Count) lines"

    # More distinct warnings than are tracked, recurring every pass. Forgetting the
    # tracked ones to make room would write all of them again on the next pass.
    $script:BridgeLaunchWarningLogged.Clear()
    $script:BridgeLaunchWarningOverflowAt = $null
    $script:Logged.Clear()
    $many = @(1..300 | ForEach-Object { "Workspace approval could not be established: folder $_" })
    foreach ($warning in $many) { Write-BridgeLaunchWarning $warning }
    $firstPass = $script:Logged.Count
    Test-That 'more distinct warnings than are tracked are each logged once, then summed up in one line' {
        $firstPass -eq $script:BridgeLaunchWarningLimit + 1 -and $script:Logged[$script:Logged.Count - 1] -like '*different warnings this hour*'
    } "$firstPass lines"
    foreach ($warning in $many) { Write-BridgeLaunchWarning $warning }
    Test-That 'and the next pass over the same ones writes nothing' { $script:Logged.Count -eq $firstPass } "$($script:Logged.Count - $firstPass) more lines"

    Write-Host "`n--- anything else's warnings ---"
    # The installer and the launch command are run by a person, at a console, once.
    $script:BridgeLaunchWarningsToLog = $false
    $script:Logged.Clear()
    $shown = @(& { 1..2 | ForEach-Object { Write-BridgeLaunchWarning 'shown at the console' } } 3>&1)
    Test-That 'are still shown, every time' { $shown.Count -eq 2 -and $script:Logged.Count -eq 0 } "$($shown.Count) shown, $($script:Logged.Count) logged"

    Write-Host "`n--- the decision log is bounded ---"
    Set-Item -Path function:Write-DecisionBridgeLog -Value $script:RealLog
    $log = Join-Path $sandbox 'agent-decision-bridge.log'
    $previous = @{ File = $script:DecisionBridgeConfig.LogFile; Max = $script:DecisionBridgeConfig.LogMaxBytes }
    try {
        $script:DecisionBridgeConfig.LogFile = $log
        $script:DecisionBridgeConfig.LogMaxBytes = 4096
        1..200 | ForEach-Object { Write-DecisionBridgeLog -Message ("line $_ " + ('x' * 60)) }
        Test-That 'it rolls over once it passes its limit' { [IO.File]::Exists("$log.1") }
        Test-That 'so neither file grows much past the limit' {
            (Get-Item -LiteralPath $log).Length -le 4096 + 200 -and (Get-Item -LiteralPath "$log.1").Length -le 4096 + 200
        } "log=$((Get-Item -LiteralPath $log).Length) rolled=$((Get-Item -LiteralPath "$log.1" -ErrorAction SilentlyContinue).Length)"
        Test-That 'and the newest line is in the live log' { (Get-Content -LiteralPath $log -Tail 1) -match 'line 200 ' }
    }
    finally {
        $script:DecisionBridgeConfig.LogFile = $previous.File
        $script:DecisionBridgeConfig.LogMaxBytes = $previous.Max
    }
}
finally {
    $script:BridgeLaunchWarningsToLog = $false
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0) {
    Write-Host "`n$($script:Failures) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall passed" -ForegroundColor Green
