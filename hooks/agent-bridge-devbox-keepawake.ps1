<#
    One Dev Box keep-awake pass, run by the AgentBridgeDevBoxKeepAwake scheduled task.

    Deliberately thin: everything worth testing lives in bridge-devbox.ps1, which this
    only wires to a log file and an exit code.
#>
param([switch]$DryRun)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'bridge-devbox.ps1')

$logFile = Join-Path $env:TEMP 'agent-bridge-devbox-keepawake.log'

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

try {
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
