#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for sharing one Home Assistant between several machines.

.DESCRIPTION
    A Home Assistant instance is usually shared: a desktop and a laptop both run the
    bridge and both talk to the same server. Per-session entities were always safe
    because they are keyed by session id, but everything the bridge publishes *once* -
    the new-session controls, the update entity, the session counter - used a fixed
    unique id, so the second machine overwrote the first rather than adding to it.

    Two consequences drove this suite. Pressing Launch ran a session on every machine
    at once, because each daemon watched the same button and kept its own idea of when
    it was last pressed. And uninstalling anywhere deleted the shared dashboard and
    toggle, taking them away from machines that were still running.

    Everything here is offline. The decision helpers are pure, and the Home Assistant
    lookups are exercised through injected state lists rather than a live server.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:BRIDGE_UNINSTALL_NORUN = '1'
. (Join-Path $PSScriptRoot '..\uninstall.ps1')
Remove-Item Env:\BRIDGE_UNINSTALL_NORUN -ErrorAction SilentlyContinue

$script:Failures = 0
function Test-That {
    # Underscored locals: an assertion scriptblock resolves its free variables in this
    # scope, so a plain $ok here would shadow one the caller set up for it to read.
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $__ok = $false
    try { $__ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($__ok) { Write-Host "  PASS  $Name" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

Write-Host '--- deciding whether shared Home Assistant state may be removed ---'

Test-That 'another machine present keeps the dashboard' {
    $d = Get-BridgeSharedStateDecision -Interactive $false -OtherMachines @('LAPTOP')
    (-not $d.Clear) -and $d.Reason -match 'LAPTOP'
}

Test-That 'the last machine removes it' {
    $d = Get-BridgeSharedStateDecision -Interactive $false -OtherMachines @()
    $d.Clear
}

Test-That 'an unknown peer list keeps it rather than guessing' {
    # $null means the lookup failed. Reading that as "nobody else is here" would delete
    # the dashboard of every other machine on any transient Home Assistant error.
    $d = Get-BridgeSharedStateDecision -Interactive $false -OtherMachines $null
    (-not $d.Clear) -and $d.Reason -match 'could not tell'
}

Test-That 'blank entries in the peer list do not count as machines' {
    $d = Get-BridgeSharedStateDecision -Interactive $false -OtherMachines @('', '   ')
    $d.Clear
}

Test-That '-KeepShared wins over a peer list that says this is the last machine' {
    $d = Get-BridgeSharedStateDecision -KeepShared -Interactive $false -OtherMachines @()
    (-not $d.Clear) -and $d.Reason -eq '-KeepShared'
}

Test-That '-ClearShared wins over a peer that is still running' {
    $d = Get-BridgeSharedStateDecision -ClearShared -Interactive $false -OtherMachines @('LAPTOP')
    $d.Clear -and $d.Reason -eq '-ClearShared'
}

Test-That 'both switches together resolve to the safe one' {
    $d = Get-BridgeSharedStateDecision -ClearShared -KeepShared -Interactive $false -OtherMachines $null
    -not $d.Clear
}

Write-Host '--- falling back to a prompt when the peer list is unknown ---'

Test-That 'a yes at the prompt removes the shared state' {
    $d = Get-BridgeSharedStateDecision -Interactive $true -OtherMachines $null -Prompt { $true }
    $d.Clear -and $d.Reason -match 'prompt'
}

Test-That 'a no at the prompt keeps it' {
    $d = Get-BridgeSharedStateDecision -Interactive $true -OtherMachines $null -Prompt { $false }
    -not $d.Clear
}

Test-That 'a known peer list is never overridden by a prompt' {
    # The prompt would throw if it ran, which is the assertion: detection outranks it.
    $d = Get-BridgeSharedStateDecision -Interactive $true -OtherMachines @('LAPTOP') `
        -Prompt { throw 'the prompt must not run when the answer is known' }
    -not $d.Clear
}

Test-That 'a non-interactive run never prompts' {
    $d = Get-BridgeSharedStateDecision -Interactive $false -OtherMachines $null `
        -Prompt { throw 'a scripted uninstall must not block on a prompt' }
    -not $d.Clear
}

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) test(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All multi-machine tests passed' -ForegroundColor Green
