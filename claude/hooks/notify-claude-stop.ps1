<#
    Turn-end handling for Claude Code.

    Registered as a Stop hook; what it does is Invoke-ClaudeStopHook (claude-hooks.ps1).

    It writes nothing to stdout. A Stop hook may return a block decision to force the
    model to continue; staying silent guarantees the turn ends exactly as Claude
    intended.
#>

$ErrorActionPreference = 'Stop'

try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)

    . (Join-Path $PSScriptRoot 'claude-ask-parser.ps1')
    . (Join-Path $PSScriptRoot 'claude-session.ps1')
    . (Join-Path $PSScriptRoot 'claude-transcript.ps1')

    # The shared Home Assistant layer is installed with the main bridge.
    $core = (Resolve-BridgeInstallContext -EntryDirectory $PSScriptRoot).HooksDir
    . (Join-Path $core 'decision-bridge-common.ps1')
    . (Join-Path $core 'decision-mqtt.ps1')
    . (Join-Path $core 'bridge-adapter.ps1')
    . (Join-Path $PSScriptRoot 'claude-hooks.ps1')

    $hookEvent = Get-ClaudeHookEvent
    if ($null -ne $hookEvent) { Invoke-ClaudeStopHook -HookEvent $hookEvent | Out-Null }
}
catch {
    if ($_.Exception.Data['BridgeTestWriteBlocked']) { throw }
    try { Write-DecisionBridgeLog -Message "claude stop hook failed: $($_.Exception.Message)" } catch { }
}
exit 0
