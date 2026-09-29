#Requires -Version 7.0
<#
.SYNOPSIS
    Tests the Claude Code AskUserQuestion parser against the real hook contract.

.DESCRIPTION
    The field names exercised here were read out of the shipping claude.exe (2.1.215),
    not from documentation. These tests need no Home Assistant and no Claude session.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\claude-ask-parser.ps1')

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

function Get-Fixture {
    param([string]$Name)
    Get-Content (Join-Path $PSScriptRoot "..\fixtures\$Name") -Raw | ConvertFrom-Json
}

Write-Host '--- single question ---'
$single = (Get-Fixture 'pretooluse-single.json')
$parsed = ConvertFrom-ClaudeAskUserQuestion -ToolInput $single.tool_input
Test-That 'the question text leads' { $parsed.Question.StartsWith('Which database should we use?') } $parsed.Question
Test-That 'both options become choices' { $parsed.Choices.Count -eq 2 } "$($parsed.Choices.Count)"
# The label alone is the option. Folding the description in made the dropdown
# unreadable, and Claude records the bare label, so an injected answer never matched.
Test-That 'an option is its bare label' { $parsed.Choices[0] -eq 'PostgreSQL (Recommended)' } $parsed.Choices[0]
Test-That 'its description is listed under the question instead' {
    $parsed.Question -match [regex]::Escape('**PostgreSQL (Recommended)** - Best fit for relational data')
} $parsed.Question
Test-That 'an option without a description stays bare' { $parsed.Choices[1] -eq 'SQLite' } $parsed.Choices[1]
Test-That 'a single question uses no per-field dropdowns on the card' { $parsed.Fields.Count -eq 0 }
Test-That 'but the marker carries its field, so it is answered by index' {
    @($parsed.MarkerFields).Count -eq 1 -and (@($parsed.MarkerFields[0].Options) -join ',') -eq 'PostgreSQL (Recommended),SQLite'
}
Test-That 'a single-select question can be answered from the dashboard' { -not $parsed.MultiSelect }

Write-Host '--- several questions ---'
$multi = (Get-Fixture 'pretooluse-multi.json')
$parsedMulti = ConvertFrom-ClaudeAskUserQuestion -ToolInput $multi.tool_input
Test-That 'each question becomes a field' { $parsedMulti.Fields.Count -eq 2 } "$($parsedMulti.Fields.Count)"
Test-That 'the header names the field' { $parsedMulti.Fields[0].Label -eq 'Database' } $parsedMulti.Fields[0].Label
Test-That 'the field carries its options for the dropdown' { $parsedMulti.Fields[0].Options.Count -eq 2 }
Test-That 'multiSelect is preserved' { $parsedMulti.Fields[1].MultiSelect -eq $true }
Test-That 'the prompt mentions both questions' { $parsedMulti.Question -match 'database' -and $parsedMulti.Question -match 'features' }
Test-That 'no flattened choice list is produced' { $parsedMulti.Choices.Count -eq 0 }
Test-That 'one multi-select question makes the whole set terminal-only' { $parsedMulti.MultiSelect }

Write-Host '--- a prompt the dashboard cannot drive ---'
# The dropdowns are dropped for these, so the options have to survive in the text or
# they are not on the card at all: only the ones Claude described would show.
$notice = Add-ClaudeTerminalOnlyNotice -Question $parsedMulti.Question -Fields $parsedMulti.MarkerFields
Test-That 'the question still leads' { $notice.StartsWith($parsedMulti.Question) }
Test-That 'it says to answer in the terminal' { $notice -match '\*\*Answer this one in the terminal\*\*' } $notice
Test-That 'and says why, in multi-select terms' { $notice -match 'more combinations than the dashboard can list' } $notice
Test-That 'every option is still readable' {
    $notice -match 'PostgreSQL \(Recommended\)' -and $notice -match 'SQLite' -and
    $notice -match 'Auth' -and $notice -match 'Billing'
} $notice
Test-That 'the multi-select question is marked as one' { $notice -match 'Features.*\(pick any\)|\(pick any\)' } $notice
Test-That 'a form with no fields still gets the notice, with the other reason' {
    $bare = Add-ClaudeTerminalOnlyNotice -Question 'Too many' -Fields @()
    $bare -match 'Answer this one in the terminal' -and $bare -match 'more fields than the dashboard can drive'
}
Test-That 'a caller can say why itself' {
    (Add-ClaudeTerminalOnlyNotice -Question 'q' -Fields @() -Reason 'the moon is wrong') -match 'the moon is wrong'
}
Test-That 'it stays within the question length cap' {
    $longQ = 'q' * 4000
    $longR = 'r' * 4000
    $optX = 'x' * 500
    $optY = 'y' * 500
    $optZ = 'z' * 500
    $huge = [pscustomobject]@{ questions = @(
        [pscustomobject]@{ question = $longQ; header = 'A'; multiSelect = $true; options = @($optX, $optY) }
        [pscustomobject]@{ question = $longR; header = 'B'; options = @($optZ) }
    ) }
    $p = ConvertFrom-ClaudeAskUserQuestion -ToolInput $huge
    (Add-ClaudeTerminalOnlyNotice -Question $p.Question -Fields $p.MarkerFields).Length -le 6000
}

Write-Host '--- more questions than dropdowns ---'
$many = (Get-Fixture 'pretooluse-too-many.json')
$parsedMany = ConvertFrom-ClaudeAskUserQuestion -ToolInput $many.tool_input
Test-That 'it falls back to freeform' { $parsedMany.Fields.Count -eq 0 -and $parsedMany.Choices.Count -eq 0 }
Test-That 'every question survives in the outline' {
    (1..5 | ForEach-Object { $parsedMany.Question -match "$_\." }) -notcontains $false
}
Test-That 'options stay visible in the outline' { $parsedMany.Question -match 'Redis' }

Write-Host '--- degenerate input ---'
Test-That 'no questions yields a usable default' {
    (ConvertFrom-ClaudeAskUserQuestion -ToolInput ([pscustomobject]@{ questions = @() })).Question
}
Test-That 'null input does not throw' { (ConvertFrom-ClaudeAskUserQuestion -ToolInput $null).Question }
Test-That 'options given as plain strings still work' {
    $input = [pscustomobject]@{ questions = @([pscustomobject]@{ question = 'Pick'; options = @('A', 'B') }) }
    (ConvertFrom-ClaudeAskUserQuestion -ToolInput $input).Choices -join ',' -eq 'A,B'
}

Write-Host '--- truncation ---'
Test-That 'an overlong option label is truncated' {
    $long = 'x' * 900
    $input = [pscustomobject]@{ questions = @([pscustomobject]@{ question = 'Pick'; options = @([pscustomobject]@{ label = $long }) }) }
    $result = ConvertFrom-ClaudeAskUserQuestion -ToolInput $input
    $result.Choices[0].Length -le 600 -and $result.Choices[0].EndsWith('...')
}

Write-Host '--- hook event reading ---'
Test-That 'a full hook event parses' {
    $raw = Get-Content (Join-Path $PSScriptRoot '..\fixtures\pretooluse-single.json') -Raw
    $event = Get-ClaudeHookEvent -Raw $raw
    $event.tool_name -eq 'AskUserQuestion' -and $event.session_id -and $event.transcript_path
}
Test-That 'malformed JSON returns null rather than throwing' { $null -eq (Get-ClaudeHookEvent -Raw '{not json') }
Test-That 'empty input returns null' { $null -eq (Get-ClaudeHookEvent -Raw '   ') }

Write-Host '--- owning process lookup ---'
# The Windows System process (pid 4) has no claude ancestor wherever the tests run.
# The test's own process - or anything it starts - does when the tests run inside a
# Claude session, which made this check fail there for reasons unrelated to the code.
Test-That 'no claude ancestor resolves to 0' { (Get-ClaudeOwningProcessId -StartPid 4) -eq 0 }
Test-That 'running inside Claude resolves to that claude process' {
    $found = Get-ClaudeOwningProcessId -StartPid $PID
    # Outside Claude there is nothing to find; inside it, the answer must be a claude.
    $found -eq 0 -or (Get-Process -Id $found).ProcessName -match '^claude'
}
Test-That 'an unknown pid resolves to 0' { (Get-ClaudeOwningProcessId -StartPid 999999) -eq 0 }

Write-Host ''
Write-Host '--- which notifications mean Claude is blocked ---'

# The idle reminder a minute after a finished turn used to turn the card 'waiting'.
function New-Notification { param([string]$Type, [string]$Message)
    $n = [ordered]@{ session_id = 's'; hook_event_name = 'Notification'; message = $Message }
    if ($Type) { $n.notification_type = $Type }
    [pscustomobject]$n
}
Test-That 'a permission prompt is blocking' {
    Test-ClaudeNotificationNeedsUser -Event (New-Notification 'permission_prompt' 'Claude needs your permission to use Bash')
}
Test-That 'a question dialog is blocking' { Test-ClaudeNotificationNeedsUser -Event (New-Notification 'elicitation_dialog' 'x') }
Test-That 'the idle reminder is not' {
    -not (Test-ClaudeNotificationNeedsUser -Event (New-Notification 'idle_prompt' 'Claude is waiting for your input'))
}
Test-That 'nor is a finished-auth notice' { -not (Test-ClaudeNotificationNeedsUser -Event (New-Notification 'auth_success' 'Signed in')) }
Test-That 'with no type, the idle wording is recognised' {
    -not (Test-ClaudeNotificationNeedsUser -Event (New-Notification '' 'Claude is waiting for your input'))
}
Test-That 'with no type, anything else is still treated as blocking' {
    Test-ClaudeNotificationNeedsUser -Event (New-Notification '' 'Claude needs your permission to run: git push --force')
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) test(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All tests passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
