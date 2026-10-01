<#
    One Dev Box keep-awake pass, run by its installation-owned scheduled task.

    Deliberately thin: everything worth testing lives in bridge-devbox.ps1, which this
    only wires to a log file and an exit code.
#>
param([switch]$DryRun)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$contextLibrary = Join-Path $PSScriptRoot 'bridge-install-context.ps1'
foreach ($path in @((Split-Path $PSScriptRoot -Parent), $PSScriptRoot, $contextLibrary)) {
    if ((Get-Item -LiteralPath $path -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "A linked keep-awake bootstrap was preserved before loading helpers: $path"
    }
}
. $contextLibrary
Assert-BridgeInstallPayload -Root (Split-Path $PSScriptRoot -Parent) -RelativePaths @('hooks')
. (Join-Path $PSScriptRoot 'bridge-platform.ps1')
$keepAwakeContext = Resolve-BridgeInstallContext -EntryDirectory $PSScriptRoot
$script:BridgeInstallContext = $keepAwakeContext
Assert-BridgeInstallPayload -Root (Get-BridgeRuntimeRoot -Context $keepAwakeContext) `
    -RelativePaths @('devbox-keepawake.process.json', 'agent-bridge-devbox-keepawake.log')
. (Join-Path $PSScriptRoot 'bridge-devbox.ps1')

$logFile = Get-BridgeRuntimePath -Name 'agent-bridge-devbox-keepawake.log' -Context $keepAwakeContext

function Write-KeepAwakeLog {
    param([Parameter(Mandatory)][string]$Message)

    $line = '{0} {1}' -f [DateTimeOffset]::Now.ToString('o'), $Message
    Write-Information $line -InformationAction Continue
    try {
        Add-Content -LiteralPath $logFile -Value $line -Encoding utf8
        # Trimmed in place rather than rotated: a second file is one more thing to
        # explain, and a keep-awake pass is not worth keeping for long.
        $existing = @(Get-Content -LiteralPath $logFile -ErrorAction Stop)
        if ($existing.Count -gt 800) {
            Set-Content -LiteralPath $logFile -Value $existing[-400..-1] -Encoding utf8
        }
    }
    catch {
        # Logging must never be the thing that breaks the run.
    }
}

$registered = $false
$ownsPass = $false
# The timer's VBS exits before the worker, so the worker owns the receipt lifetime.
$passMutex = [Threading.Mutex]::new($false, ('Local\' + $keepAwakeContext.DevBoxTaskName))
try {
    try { $ownsPass = $passMutex.WaitOne([TimeSpan]::Zero) }
    catch [Threading.AbandonedMutexException] { $ownsPass = $true }
    if (-not $ownsPass) { throw 'Another keep-awake pass owns this installation; no cloud operation was attempted.' }
    Register-BridgeRuntimeProcess -Context $keepAwakeContext -Role devbox-keepawake
    $registered = $true
    $result = Invoke-BridgeDevBoxKeepAwake -Logger { param($Message) Write-KeepAwakeLog $Message } -DryRun:$DryRun
    Write-KeepAwakeLog "$($result.Status): $($result.Detail)"
    # 2, not 1: Task Scheduler shows the last result, and "the service would not let
    # me move it" is a different thing to find than a crash or an expired login.
    if ($result.Status -eq 'blocked') { exit 2 }
    exit 0
}
catch {
    Write-KeepAwakeLog "FAILED: $($_.Exception.Message)"
    exit 1
}
finally {
    try {
        if ($registered) { Unregister-BridgeRuntimeProcess -Context $keepAwakeContext -Role devbox-keepawake }
    }
    finally {
        if ($ownsPass) { $passMutex.ReleaseMutex() }
        $passMutex.Dispose()
    }
}
