#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the Codex adapter: hook event handling and the rollout reducer.

.DESCRIPTION
    The hook fixtures are real payloads captured from Codex 0.155.0-alpha.6, and so
    is the rollout fixture: its two reasoning lines are the verbatim output of a
    `gpt-6-astra` turn run at `model_reasoning_effort=high` with
    `model_reasoning_summary=detailed`, with only the opaque `encrypted_content`
    truncated and the cwd made generic.

    That capture corrected the reducer. An earlier version of this fixture was
    synthetic, modelled on the `Reasoning` variant in codex-rs `ThreadItemDetails`,
    which holds `{ text }` - and the real item carries no `text` field at all. It is
    `summary_text`, an array of strings. The reducer had been matching a field that
    never appears, so it would have returned nothing forever.

    What arrives is the model's *summary* of its reasoning: `raw_content` is empty
    and `encrypted_content` is opaque by design.

    Reasoning is opt-in. It is absent unless `model_reasoning_effort` is set, and a
    turn that does not reason emits no items at all, so the no-reasoning case below
    is the common one rather than an edge case.

    Needs no Home Assistant and no Codex session.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Loaded exactly as the hook loads it: template sanitisation lives in the shared
# module, and codex-session defers to it when present.
$core = Join-Path $HOME '.agent-ha-bridge\hooks\decision-bridge-common.ps1'
if (Test-Path -LiteralPath $core) { . $core }
else { . (Join-Path $PSScriptRoot '..\..\hooks\decision-bridge-common.ps1') }

. (Join-Path $PSScriptRoot '..\hooks\codex-session.ps1')
. (Join-Path $PSScriptRoot '..\hooks\codex-transcript.ps1')

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($ok) { Write-Host "  PASS  $Name" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

$fixtures = Join-Path $PSScriptRoot '..\fixtures'

Write-Host '--- real hook payloads ---'
foreach ($case in @(
    @{ File = 'sessionstart.json'; Event = 'SessionStart'; Fields = @('session_id', 'transcript_path', 'cwd', 'model', 'permission_mode', 'source') }
    @{ File = 'userpromptsubmit.json'; Event = 'UserPromptSubmit'; Fields = @('session_id', 'turn_id', 'prompt') }
    @{ File = 'pretooluse.json'; Event = 'PreToolUse'; Fields = @('tool_name', 'tool_input', 'tool_use_id') }
    @{ File = 'stop.json'; Event = 'Stop'; Fields = @('stop_hook_active', 'last_assistant_message') }
    @{ File = 'sessionend.json'; Event = 'SessionEnd'; Fields = @('session_id', 'reason') }
)) {
    $event = Get-CodexHookEvent -Raw (Get-Content (Join-Path $fixtures $case.File) -Raw)
    Test-That "$($case.Event) parses" { $event.hook_event_name -eq $case.Event } (($event.hook_event_name) ?? 'null')
    foreach ($field in $case.Fields) {
        Test-That "$($case.Event) carries $field" { $event.PSObject.Properties.Name -contains $field }
    }
}

Write-Host '--- session naming ---'
Test-That 'a session is named after its working directory' {
    (Get-CodexSessionDisplay -SessionId 'abc123' -WorkingDirectory 'C:\repos\my-project').Name -eq 'Codex: my-project'
}
Test-That 'a missing directory falls back to the id' {
    (Get-CodexSessionDisplay -SessionId '01a0cb31aaaa' -WorkingDirectory '').Name -eq 'Codex: 01a0cb31'
}
Test-That 'template syntax in a folder name is neutralised' {
    (Get-CodexSessionDisplay -SessionId 'abc' -WorkingDirectory 'C:\repos\{{ states(''sun.sun'') }}').Name -notmatch '\{\{'
}

Write-Host '--- session ids used as paths ---'
foreach ($candidate in @('../../evil', 'a/b', '', 'C:\Windows')) {
    Test-That "path-safe: '$candidate'" {
        (Get-CodexSafeSessionKey -SessionId $candidate) -notmatch '[\\/]'
    } (Get-CodexSafeSessionKey -SessionId $candidate)
}

Write-Host '--- approval markers ---'
$sessionId = 'test-approval-0001'
try {
    Test-That 'no marker to begin with' { $null -eq (Get-CodexApprovalMarker -SessionId $sessionId) }
    Write-CodexApprovalMarker -SessionId $sessionId -DecisionId 'd1' -Question 'Needs approval: rm -rf /'
    $marker = Get-CodexApprovalMarker -SessionId $sessionId
    Test-That 'a marker round-trips' { $marker.DecisionId -eq 'd1' -and $marker.Question -match 'rm -rf' }
    Test-That 'removing reports that it removed something' { Remove-CodexApprovalMarker -SessionId $sessionId }
    Test-That 'removing again reports nothing to remove' { -not (Remove-CodexApprovalMarker -SessionId $sessionId) }

    # The bug this guards: approval markers live beside registrations and also end in
    # .json, so the registration reader parsed them as registrations. The missing
    # fields threw under StrictMode and took down the daemon's whole reconcile.
    Write-CodexApprovalMarker -SessionId $sessionId -DecisionId 'd2' -Question 'q'
    Test-That 'a marker is not mistaken for a registration' {
        # The assertion is that this completes at all: before the fix it threw on the
        # marker's missing fields, and that exception propagated out of the daemon's
        # reconcile.
        $null = @(Get-CodexSessionRegistrations -IncludeEnded)
        $true
    }
    Test-That 'the marker survives a registration scan' {
        $null -ne (Get-CodexApprovalMarker -SessionId $sessionId)
    }
}
finally {
    Remove-CodexApprovalMarker -SessionId $sessionId | Out-Null
}

Write-Host '--- rollout reducer (real captured format) ---'
$lines = @(Get-Content (Join-Path $fixtures 'rollout-with-reasoning.jsonl') | Where-Object { $_.Trim() })
Test-That 'the latest reasoning wins' {
    (Get-CodexReasoningFromTranscript -Lines $lines) -eq "**Checking the remainder**`nFive minus three leaves two."
} (Get-CodexReasoningFromTranscript -Lines $lines)
Test-That 'a real event_msg Reasoning item is read from summary_text' {
    $one = @($lines | Where-Object { $_ -match '"Reasoning"' } | Select-Object -First 1)
    (Get-CodexReasoningFromTranscript -Lines $one) -eq '**Filling the 5-unit jug**'
} (Get-CodexReasoningFromTranscript -Lines @($lines | Where-Object { $_ -match '"Reasoning"' } | Select-Object -First 1))
Test-That 'a real response_item reasoning is read from summary[].text' {
    # -cmatch: the event_msg spelling is "Reasoning", and a case-insensitive match
    # would select it too.
    $one = @($lines | Where-Object { $_ -cmatch '"type":"reasoning"' })
    (Get-CodexReasoningFromTranscript -Lines $one) -eq '**Filling the 5-unit jug**'
} (Get-CodexReasoningFromTranscript -Lines @($lines | Where-Object { $_ -cmatch '"type":"reasoning"' }))
Test-That 'multiple summary_text entries are joined' {
    (Get-CodexReasoningFromTranscript -Lines $lines) -match 'Five minus three'
}
Test-That 'the opaque encrypted_content is never surfaced' {
    (Get-CodexReasoningFromTranscript -Lines $lines) -notmatch 'gAAAAAB'
}
Test-That 'agent messages are not treated as reasoning' {
    (Get-CodexReasoningFromTranscript -Lines $lines) -notmatch 'twice\.$'
}
Test-That 'a rollout with no reasoning yields nothing' {
    $none = @($lines | Where-Object { $_ -notmatch 'reasoning' })
    $null -eq (Get-CodexReasoningFromTranscript -Lines $none)
}
Test-That 'the tolerated flat text shape still works' {
    $flat = @('{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning","id":"r9","text":"flat shape"}}}')
    (Get-CodexReasoningFromTranscript -Lines $flat) -eq 'flat shape'
}
Test-That 'malformed lines are skipped' {
    $null -eq (Get-CodexReasoningFromTranscript -Lines @('{bad', ''))
}
Test-That 'an empty batch is safe' {
    $null -eq (Get-CodexReasoningFromTranscript -Lines @())
}

Write-Host '--- tailing reader ---'
$temp = Join-Path ([IO.Path]::GetTempPath()) "codex-rollout-$([guid]::NewGuid().ToString('N').Substring(0,8)).jsonl"
try {
    Copy-Item (Join-Path $fixtures 'rollout-with-reasoning.jsonl') $temp
    $first = Read-CodexTranscriptAppend -Path $temp -Offset 0
    Test-That 'a first read returns every line' { $first.Lines.Count -eq $lines.Count } "$($first.Lines.Count)"
    $second = Read-CodexTranscriptAppend -Path $temp -Offset $first.Offset
    Test-That 'a second read returns nothing new' { $second.Lines.Count -eq 0 }

    [IO.File]::AppendAllText($temp, '{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning","id":"r3","text":"later thought"}}}' + "`n")
    $third = Read-CodexTranscriptAppend -Path $temp -Offset $second.Offset
    Test-That 'only the appended line is returned' { $third.Lines.Count -eq 1 } "$($third.Lines.Count)"
    Test-That 'the appended reasoning is read' {
        (Get-CodexReasoningFromTranscript -Lines $third.Lines) -eq 'later thought'
    }

    [IO.File]::AppendAllText($temp, '{"type":"event_msg","payload":{"type":"item_comp')
    $partial = Read-CodexTranscriptAppend -Path $temp -Offset $third.Offset
    Test-That 'a partial trailing line is withheld' { $partial.Lines.Count -eq 0 } "$($partial.Lines.Count)"

    Set-Content -LiteralPath $temp -Value '{"type":"event_msg","payload":{"type":"task_started"}}'
    $shrunk = Read-CodexTranscriptAppend -Path $temp -Offset 999999
    Test-That 'a shrinking file resets the offset' { $shrunk.Lines.Count -eq 1 } "$($shrunk.Lines.Count)"

    Test-That 'a missing file is handled' { (Read-CodexTranscriptAppend -Path 'C:\nope.jsonl').Lines.Count -eq 0 }
    Test-That 'an empty path is handled' { (Read-CodexTranscriptAppend -Path '').Lines.Count -eq 0 }
}
finally {
    Remove-Item $temp -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '--- what a turn adds to the card (Codex 0.157 rollout shapes) ---'
$turn = @(
    '{"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}'
    '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"is my wifi ok?"}]}}'
    '{"type":"response_item","payload":{"type":"reasoning","summary":[],"encrypted_content":"gAAAA"}}'
    '{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"I''ll check the network settings first."}]}}'
    '{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"ipconfig"}}'
    '{"type":"event_msg","payload":{"type":"token_count"}}'
    '{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"**DNS is fine.**\nThe problem is the proxy."}]}}'
)
$a = Get-CodexActivityFromTranscript -Lines $turn
Test-That 'a new turn is noticed' { $a.TurnStarted }
Test-That 'the newest thing said is the final answer, whole' { $a.Latest -eq "**DNS is fine.**`nThe problem is the proxy." -and -not $a.LatestIsThinking }
Test-That 'the user''s own message is not shown as the agent''s' { $a.Latest -notmatch 'wifi' }
Test-That 'tool calls become the history' { (@($a.History) -join '|') -eq 'Ran: exec' }
Test-That 'encrypted reasoning shows nothing' { -not $a.Reasoning }
$mid = Get-CodexActivityFromTranscript -Lines $turn[0..4]
Test-That 'mid-turn, the progress note is what the card shows' { $mid.Latest -eq "I'll check the network settings first." }
$summary = Get-CodexActivityFromTranscript -Lines @('{"type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"Weighing DNS against the proxy"}]}}')
Test-That 'a reasoning summary is shown as thinking' { $summary.Latest -eq 'Weighing DNS against the proxy' -and $summary.LatestIsThinking -and $summary.Reasoning }
# Detail on puts it in the trail as well, so History is no longer tool calls only.
Test-That 'without detail, the trail is what it ran' { @($summary.History).Count -eq 0 } (@($summary.History) -join '|')
$summaryDetailed = Get-CodexActivityFromTranscript -VerboseMode $true -Lines @('{"type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"Weighing DNS against the proxy"}]}}')
Test-That 'with detail, the thought is a step in the trail' {
    (@($summaryDetailed.History) -join '|') -eq 'Thinking: Weighing DNS against the proxy'
} (@($summaryDetailed.History) -join '|')
Test-That 'a batch with nothing to show adds nothing' {
    $none = Get-CodexActivityFromTranscript -Lines @('{"type":"event_msg","payload":{"type":"token_count"}}', 'not json')
    -not $none.TurnStarted -and -not $none.Latest -and @($none.History).Count -eq 0
}

Write-Host ''
Write-Host '--- the process a reply is typed into ---'

# Codex 0.157 runs hooks under a console-less `codex.exe app-server` child of the
# terminal UI; registering that pid made every dashboard reply fail with
# attach-failed:6. The tree below is the one captured from a live session.
$script:FakeTree = @{
    100 = [pscustomobject]@{ ProcessId = 100; ParentProcessId = 90; Name = 'pwsh.exe'; CommandLine = 'pwsh -File codex-bridge-hook.ps1' }
    90  = [pscustomobject]@{ ProcessId = 90; ParentProcessId = 80; Name = 'codex.exe'; CommandLine = '"\\?\C:\Users\u\.codex\packages\app-server-daemon\bin\codex.exe" app-server --listen stdio' }
    80  = [pscustomobject]@{ ProcessId = 80; ParentProcessId = 70; Name = 'codex.exe'; CommandLine = 'C:\npm\codex-win32-x64\vendor\codex.exe' }
    70  = [pscustomobject]@{ ProcessId = 70; ParentProcessId = 1; Name = 'node.exe'; CommandLine = 'node codex.js' }
    60  = [pscustomobject]@{ ProcessId = 60; ParentProcessId = 1; Name = 'codex.exe'; CommandLine = 'codex.exe app-server' }
    50  = [pscustomobject]@{ ProcessId = 50; ParentProcessId = 60; Name = 'pwsh.exe'; CommandLine = 'pwsh -File codex-bridge-hook.ps1' }
}
# The platform layer's lookups stand in for WMI on Windows and ps on macOS alike.
function Get-BridgeProcessInfo { param([int]$ProcessId, [switch]$WithCommandLine) $script:FakeTree[$ProcessId] }
function Get-BridgeProcessesNamed {
    param([string]$Name)
    @($script:FakeTree.Values | Where-Object { ($_.Name -replace '\.exe$', '') -eq $Name })
}
# Registrations go to a scratch folder, not the real one.
$savedRoot = $script:CodexStateRoot
$script:CodexStateRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-owner-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $script:CodexStateRoot | Out-Null
try {
    Test-That 'a hook under the app-server resolves to the terminal codex.exe' { (Get-CodexOwningProcessId -StartPid 100) -eq 80 }
    Test-That 'an app-server with no terminal above it, and no window free, is still better than nothing' {
        $script:FakeTree.Remove(80); $r = Get-CodexOwningProcessId -StartPid 50
        $script:FakeTree[80] = [pscustomobject]@{ ProcessId = 80; ParentProcessId = 70; Name = 'codex.exe'; CommandLine = 'C:\npm\codex-win32-x64\vendor\codex.exe'; CreationDate = [datetime]'2026-09-27T11:51:00' }
        $r -eq 60
    }

    # The app-server is shared: a second window's hooks run under the first window's
    # tree, or under a window that has since closed. Captured live: the second
    # session was registered against the orphaned app-server and could not be
    # replied to.
    $script:FakeTree[80].PSObject.Properties.Add([psnoteproperty]::new('CreationDate', [datetime]'2026-09-27T11:51:00'))
    $script:FakeTree[20] = [pscustomobject]@{ ProcessId = 20; ParentProcessId = 70; Name = 'codex.exe'; CommandLine = 'C:\npm\codex-win32-x64\vendor\codex.exe'; CreationDate = [datetime]'2026-09-27T12:31:30' }
    Write-CodexSessionRegistration -SessionId 'first-session' -ProcessId 80 -Status 'idle' | Out-Null
    Test-That 'a second session under the shared app-server takes the window nobody has claimed' {
        (Get-CodexOwningProcessId -StartPid 100 -SessionId 'second-session') -eq 20
    }
    Test-That 'while the first session keeps its own window' {
        (Get-CodexOwningProcessId -StartPid 100 -SessionId 'first-session') -eq 80
    }
    Test-That 'with the first window closed, the orphaned app-server still leads to the free window' {
        (Get-CodexOwningProcessId -StartPid 50 -SessionId 'second-session') -eq 20
    }
    Write-CodexSessionRegistration -SessionId 'second-session' -ProcessId 20 -Status 'idle' | Out-Null
    Test-That 'a session keeps the window it recorded' {
        (Get-CodexOwningProcessId -StartPid 50 -SessionId 'second-session') -eq 20
    }
}
finally {
    Remove-Item -LiteralPath $script:CodexStateRoot -Recurse -Force -ErrorAction SilentlyContinue
    $script:CodexStateRoot = $savedRoot
    Remove-Item function:Get-BridgeProcessInfo, function:Get-BridgeProcessesNamed
    . (Join-Path $PSScriptRoot '../../hooks/bridge-platform.ps1')
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) test(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All tests passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
