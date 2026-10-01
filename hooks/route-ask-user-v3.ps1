<#
    ask_user routing over the per-session Home Assistant bridge - dual-input, non-blocking.

    Copilot's preToolUse hook for ask_user; what it does is Invoke-CopilotAskUserHook
    (copilot-hooks.ps1). It returns `allow` IMMEDIATELY, so the native terminal prompt
    appears at once and the dashboard is a second way to answer it.

    Fail-open: any error still returns `allow`, so the native ask_user prompt is never
    suppressed.
#>

$ErrorActionPreference = 'Stop'

try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    . (Join-Path $PSScriptRoot 'decision-bridge-common.ps1')
    . (Join-Path $PSScriptRoot 'decision-mqtt.ps1')
    . (Join-Path $PSScriptRoot 'decision-ha-websocket.ps1')
    . (Join-Path $PSScriptRoot 'bridge-adapter.ps1')
    . (Join-Path $PSScriptRoot 'copilot-hooks.ps1')

    $rawEvent = [Console]::In.ReadToEnd()
    if (-not [string]::IsNullOrWhiteSpace($rawEvent)) {
        $decisionEvent = ConvertFrom-DecisionJson -Json $rawEvent
        $hookEvent = $rawEvent | ConvertFrom-Json
        foreach ($name in @('toolArgs', 'tool_input')) {
            if ($decisionEvent.PSObject.Properties[$name]) {
                $hookEvent.$name = $decisionEvent.$name
            }
        }
        Invoke-CopilotAskUserHook -HookEvent $hookEvent | Out-Null
    }
}
catch {
    try {
        Write-DecisionBridgeLog -Message "route v3 failed: $($_.Exception.Message)"
    }
    catch {
        # The native ask_user dialog remains the fail-open response path.
    }
}

# Return immediately. The native prompt is shown and answerable; Home Assistant is a
# parallel input the daemon feeds in.
@{ permissionDecision = 'allow' } | ConvertTo-Json -Compress
exit 0
