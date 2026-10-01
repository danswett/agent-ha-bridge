<#
    Codex CLI bridge hook.

    One script handles every event; what it does is Invoke-CodexHook (codex-hooks.ps1).
    Codex identifies the event in its payload, so a single trusted entry point is
    simpler to install and - because each hook has to be trusted individually - means
    one approval rather than five.

    It writes nothing to stdout. A Codex hook can return JSON to allow, deny or ask,
    and emitting anything unexpected risks altering a decision Codex should own, so
    staying silent guarantees the bridge cannot change what Codex does.

    Fail-open throughout: any error exits 0, because a bridge fault must never stop
    Codex from running.
#>

$ErrorActionPreference = 'Stop'

try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)

    . (Join-Path $PSScriptRoot 'codex-session.ps1')

    $core = (Resolve-BridgeInstallContext -EntryDirectory $PSScriptRoot).HooksDir
    . (Join-Path $core 'decision-bridge-common.ps1')
    . (Join-Path $core 'decision-mqtt.ps1')
    . (Join-Path $core 'decision-ha-websocket.ps1')
    . (Join-Path $core 'bridge-adapter.ps1')
    . (Join-Path $PSScriptRoot 'codex-hooks.ps1')

    $hookEvent = Get-CodexHookEvent
    if ($null -ne $hookEvent) { Invoke-CodexHook -HookEvent $hookEvent | Out-Null }
}
catch {
    try { Write-DecisionBridgeLog -Message "codex hook failed: $($_.Exception.Message)" } catch { }
}
exit 0
