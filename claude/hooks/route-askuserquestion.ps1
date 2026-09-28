<#
    AskUserQuestion routing for Claude Code - dual-input, non-blocking.

    Registered as a PreToolUse hook matching AskUserQuestion; what it does is
    Invoke-ClaudeAskHook (claude-hooks.ps1).

    It deliberately produces no stdout. A PreToolUse hook can return
    hookSpecificOutput.permissionDecision to allow or deny, but AskUserQuestion is not
    permission-gated and its whole purpose is to prompt; staying silent is the only
    response that guarantees the native prompt is unaffected.

    Fail-open throughout: any error exits 0 silently, so a bridge problem can never
    stop Claude from asking.
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
    if ($null -ne $hookEvent) { Invoke-ClaudeAskHook -HookEvent $hookEvent | Out-Null }
}
catch {
    try { Write-DecisionBridgeLog -Message "claude ask router failed: $($_.Exception.Message)" } catch { }
}
exit 0
