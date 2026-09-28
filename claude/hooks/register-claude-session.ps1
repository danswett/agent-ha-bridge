<#
    Registers a Claude Code session with the bridge as soon as it exists.

    Registered as the SessionStart and UserPromptSubmit hooks; what it does is
    Invoke-ClaudeRegisterHook (claude-hooks.ps1).

    It writes nothing to stdout: SessionStart and UserPromptSubmit output is added to
    Claude's context, and the bridge must never change what Claude sees.
#>

$ErrorActionPreference = 'Stop'

try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)

    . (Join-Path $PSScriptRoot 'claude-ask-parser.ps1')
    . (Join-Path $PSScriptRoot 'claude-session.ps1')
    . (Join-Path $PSScriptRoot 'claude-hooks.ps1')

    $hookEvent = Get-ClaudeHookEvent
    if ($null -ne $hookEvent) { Invoke-ClaudeRegisterHook -HookEvent $hookEvent | Out-Null }
}
catch {
    # Fail open: a bridge fault must never affect the session.
}
exit 0
