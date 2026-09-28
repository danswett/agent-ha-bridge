<#
    Attention routing for Claude Code.

    Registered as a Notification hook; what it does is Invoke-ClaudeNotificationHook
    (claude-hooks.ps1).

    Writes nothing to stdout and always exits 0, so it can never interfere.
#>

$ErrorActionPreference = 'Stop'

try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)

    . (Join-Path $PSScriptRoot 'claude-ask-parser.ps1')
    . (Join-Path $PSScriptRoot 'claude-session.ps1')

    # The shared Home Assistant layer is installed with the main bridge.
    $core = Join-Path $HOME '.agent-ha-bridge\hooks'
    . (Join-Path $core 'decision-bridge-common.ps1')
    . (Join-Path $core 'decision-mqtt.ps1')
    . (Join-Path $core 'decision-ha-websocket.ps1')
    . (Join-Path $core 'bridge-adapter.ps1')
    . (Join-Path $PSScriptRoot 'claude-hooks.ps1')

    $hookEvent = Get-ClaudeHookEvent
    if ($null -ne $hookEvent) { Invoke-ClaudeNotificationHook -HookEvent $hookEvent | Out-Null }
}
catch {
    try { Write-DecisionBridgeLog -Message "claude notification hook failed: $($_.Exception.Message)" } catch { }
}
exit 0
