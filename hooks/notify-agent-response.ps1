<#
    Mirrors a completed Copilot turn to Home Assistant as a notification.

    Copilot's agentStop hook; what it does is Invoke-CopilotAgentStopHook
    (copilot-hooks.ps1). Non-blocking, and it always replies `{}`: response delivery
    must not affect the completed turn.
#>

$ErrorActionPreference = 'Stop'

try {
    . (Join-Path $PSScriptRoot 'decision-bridge-common.ps1')
    . (Join-Path $PSScriptRoot 'bridge-adapter.ps1')
    . (Join-Path $PSScriptRoot 'copilot-hooks.ps1')

    $rawEvent = [Console]::In.ReadToEnd()
    if (-not [string]::IsNullOrWhiteSpace($rawEvent)) {
        Invoke-CopilotAgentStopHook -HookEvent ($rawEvent | ConvertFrom-Json) | Out-Null
    }
}
catch {
    try {
        Write-DecisionBridgeLog -Message "response notification failed: $($_.Exception.Message)"
    }
    catch {
        # Response delivery must not affect the completed CLI turn.
    }
}

Write-Output '{}'
