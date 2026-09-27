<#
    Registers a Claude Code session with the bridge as soon as it exists.

    Registered as the SessionStart and UserPromptSubmit hooks. The daemon discovers
    Claude sessions only from the registrations hooks write, and before this the only
    writers were Stop, Notification and PreToolUse - so a session stayed invisible
    until its first turn ended, and a session launched from the dashboard could never
    be confirmed as started. SessionStart closes that gap; UserPromptSubmit covers a
    session that was already open when the adapter was installed.

    It writes nothing to stdout: SessionStart and UserPromptSubmit output is added to
    Claude's context, and the bridge must never change what Claude sees.
#>

$ErrorActionPreference = 'Stop'

try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)

    . (Join-Path $PSScriptRoot 'claude-ask-parser.ps1')
    . (Join-Path $PSScriptRoot 'claude-session.ps1')

    $event = Get-ClaudeHookEvent
    if ($null -eq $event) { exit 0 }

    $sessionId = [string]$event.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { exit 0 }

    # At SessionStart the transcript may not have been written yet, so the path Claude
    # reports is kept as-is rather than verified and discarded.
    $transcriptPath = [string]$event.transcript_path
    if ([string]::IsNullOrWhiteSpace($transcriptPath)) {
        $transcriptPath = Resolve-ClaudeTranscriptPath -SessionId $sessionId
    }

    # A submitted prompt is the start of a turn, so it records 'working'; that is what
    # lifts the card out of 'idle' or 'waiting' straight away. SessionStart records
    # no status, leaving whatever the daemon infers.
    $status = if ([string]$event.hook_event_name -eq 'UserPromptSubmit') { 'working' } else { '' }

    Write-ClaudeSessionRegistration -SessionId $sessionId -TranscriptPath $transcriptPath `
        -WorkingDirectory ([string]$event.cwd) -ProcessId (Get-ClaudeOwningProcessId) -Status $status | Out-Null
}
catch {
    # Fail open: a bridge fault must never affect the session.
}
exit 0
