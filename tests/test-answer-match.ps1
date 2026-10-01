#Requires -Version 7.0
<#
.SYNOPSIS
    An answer given on the phone is recognised as the answer the CLI recorded.

.DESCRIPTION
    When a question is answered from Home Assistant the daemon checks, before tearing
    the card down, that the option it drove into the arrow-key prompt is the one the
    CLI ended up recording. A dropped keystroke selects the neighbouring option and
    the prompt reports it as the user's own choice, so that check is worth having.

    It was comparing the wrong halves. The card and the injector work in option
    labels; the CLI records the schema value - "release=cut_now", not "Cut 1.15.0
    now". Every form written with `oneOf` entries or a yes/no field therefore failed
    the check, and the daemon typed a correction into the session telling the agent to
    disregard an answer that was correct. Seen live on 2026-09-28 against a form whose
    answer had arrived perfectly.

    Carry field identity and typed schema values next to labels. Structured results
    compare the values; text may use labels only when their mapping is unambiguous. The risk
    in that is entirely in the middle: the value is read where the schema is parsed,
    but the check runs in the daemon, minutes later, on the far side of a marker file
    that is JSON on disk. Reading values correctly and checking them correctly is not
    enough if they are dropped in between - and both ends would still pass their own
    tests. So these follow one answer the whole way: real tool arguments, the real
    parse, the real marker written and read back off disk, and only then the check,
    against the verbatim string the CLI recorded.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
$script:DecisionBridgeConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-answer-match-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $__ok = $false
    try { $__ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($__ok) { Write-Host "  PASS  $Name" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

Write-Host "`n--- a label and the value behind it are read together ---"

# Both halves come from one function so they cannot drift out of step. Read by two
# copies of the branching logic they would eventually disagree about which value sits
# behind which label, and the check would blame the wrong option.
$oneOfField = '{"type":"string","oneOf":[{"const":"cut_now","title":"Cut 1.15.0 now"},{"const":"hold","title":"Hold"}]}' | ConvertFrom-Json
$oneOfChoices = @(Get-DecisionSchemaFieldChoices -Field $oneOfField)
Test-That 'a oneOf entry gives its title as the label' { $oneOfChoices[0].Label -eq 'Cut 1.15.0 now' }
Test-That 'and its const as the value' { $oneOfChoices[0].Value -eq 'cut_now' }
Test-That 'in the order the schema lists them' { $oneOfChoices[1].Value -eq 'hold' }

$enumField = '{"type":"string","enum":["a","b"],"enumNames":["Apples","Bananas"]}' | ConvertFrom-Json
$enumChoices = @(Get-DecisionSchemaFieldChoices -Field $enumField)
Test-That 'an enumNames label keeps the enum value behind it' {
    $enumChoices[0].Label -eq 'Apples' -and $enumChoices[0].Value -eq 'a'
}

$boolChoices = @(Get-DecisionSchemaFieldChoices -Field (('{"type":"boolean"}') | ConvertFrom-Json))
Test-That 'a yes/no field is shown as Yes but recorded as true' {
    $boolChoices[0].Label -ceq 'Yes' -and $boolChoices[0].Value -is [bool] -and $boolChoices[0].Value
}
Test-That 'and No as false' { $boolChoices[1].Label -ceq 'No' -and $boolChoices[1].Value -is [bool] -and -not $boolChoices[1].Value }

$plainChoices = @(Get-DecisionSchemaFieldChoices -Field (('{"type":"string","enum":["Closer","Aligned"]}') | ConvertFrom-Json))
Test-That 'a plain enum is its own label and value' {
    $plainChoices[0].Label -eq 'Closer' -and $plainChoices[0].Value -eq 'Closer'
}

Test-That 'a free-text field still has no choices' {
    @(Get-DecisionSchemaFieldChoices -Field (('{"type":"string","title":"Notes"}') | ConvertFrom-Json)).Count -eq 0
}

# The card is built from the labels, and every existing caller asks for those, so the
# label list must come back exactly as it did before values were carried.
Test-That 'the label list is unchanged for the card' {
    (@(Get-DecisionSchemaFieldOptions -Field $oneOfField) -join '|') -eq 'Cut 1.15.0 now|Hold'
}

Write-Host "`n--- the values reach the daemon through the marker on disk ---"

# The form that was answered correctly and then contradicted, as Copilot passed it to
# the hook.
$toolArgs = @'
{
  "message": "What next?",
  "requestedSchema": {
    "properties": {
      "release": {
        "type": "string",
        "title": "Release",
        "oneOf": [
          { "const": "cut_now",   "title": "Cut 1.15.0 now" },
          { "const": "hold",      "title": "Hold until morning" }
        ]
      },
      "next_task": {
        "type": "string",
        "title": "Next",
        "oneOf": [
          { "const": "stop_here",  "title": "Nothing more tonight" },
          { "const": "keep_going", "title": "Keep going" }
        ]
      },
      "notes": { "type": "string", "title": "Anything else" }
    }
  }
}
'@ | ConvertFrom-Json

$parsed = & {
    # The ask_user parser is spooled non-strict on purpose - daemon-hookspool.ps1
    # marks the Copilot handlers Strict = $false because the parser reads a missing
    # tool argument as $null. Running it strict here would fail on the absence of
    # `choices`, which is not a defect and not what this suite is about. A child
    # scope, so the rest of the file stays strict.
    Set-StrictMode -Off
    Repair-DecisionToolArguments -ToolArgs $toolArgs
}
Test-That 'the form is captured as fields' { @($parsed.Fields).Count -eq 3 }
Test-That 'and is answerable from the card' { -not $parsed.TerminalOnly }

$sessionId = "test-answer-match-$([guid]::NewGuid().ToString('N'))"
$markerPath = Get-CopilotDecisionMarkerPath -SessionId $sessionId
try {
    Write-CopilotDecisionMarker -SessionId $sessionId -DecisionId 'd1' -Question $parsed.Question `
        -Choices @($parsed.Choices) -Combos @($parsed.Combos) -Fields @($parsed.Fields) -Mode 'multiple_choice'

    # What the user tapped on the phone: the second option of each list, which is also
    # what makes this worth asserting - a first option would pass a broken check by
    # accident.
    Set-CopilotDecisionMarkerInjected -SessionId $sessionId -Answer 'release=hold, next_task=keep_going' `
        -Selections @('Hold until morning', 'Keep going', 'nothing to add')

    # Everything from here on reads the marker back off disk, exactly as the daemon
    # does - this is the stretch where a value that was read correctly gets lost.
    $marker = Get-CopilotDecisionMarker -SessionId $sessionId
    $markerFields = @($marker.fields)

    Test-That 'the marker survives the round trip with its fields' { $markerFields.Count -eq 3 }
    Test-That 'and the values come back with them' {
        $markerFields[0].PSObject.Properties['Values'] -and
        (@($markerFields[0].Values) -join '|') -eq 'cut_now|hold'
    }
    Test-That 'a one-option list is still a list after JSON' {
        $single = ('{"type":"string","oneOf":[{"const":"only","title":"Only one"}]}') | ConvertFrom-Json
        $f = [pscustomobject]@{ Label = 'S'; Options = @('Only one'); Values = @('only'); IsText = $false }
        $back = ($f | ConvertTo-Json -Depth 8 -Compress | ConvertFrom-Json)
        @($back.Values).Count -eq 1 -and @($back.Values)[0] -eq 'only' -and $null -ne $single
    }

    $injected = @($marker.injectedSelections)
    Test-That 'the selections come back too' { $injected.Count -eq 3 }

    # The verbatim shape Copilot records a form answer in: schema values, never the
    # labels the user actually saw and tapped.
    $recorded = 'User responded: release=hold, next_task=keep_going, notes=nothing to add'

    Test-That 'the answer that was given is recognised as the answer recorded' {
        Test-CopilotAnswerMatchesSelections -ResultContent $recorded -Fields $markerFields -Selections $injected
    }

    # The whole point of the check must survive the fix: a keystroke landing one row
    # short still has to be caught, and it is caught by value now rather than label.
    Test-That 'the neighbouring option is still caught' {
        -not (Test-CopilotAnswerMatchesSelections `
            -ResultContent 'User responded: release=cut_now, next_task=keep_going, notes=nothing to add' `
            -Fields $markerFields -Selections $injected)
    }
    Test-That 'and so is a slip in the second field' {
        -not (Test-CopilotAnswerMatchesSelections `
            -ResultContent 'User responded: release=hold, next_task=stop_here, notes=nothing to add' `
            -Fields $markerFields -Selections $injected)
    }
    Test-That 'a reworded free-text field is not a mismatch' {
        Test-CopilotAnswerMatchesSelections `
            -ResultContent 'User responded: release=hold, next_task=keep_going, notes=Nothing to add.' `
            -Fields $markerFields -Selections $injected
    }
}
finally {
    Remove-CopilotDecisionMarker -SessionId $sessionId
    $dir = Split-Path $markerPath -Parent
    if ($dir -like '*copilot-bridge-markers*' -and (Test-Path -LiteralPath $dir)) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n--- a yes/no answer is not called a mismatch ---"

# A checkbox could never match: the card offers Yes and No, the CLI writes true and
# false, and the two have no characters in common.
$boolFields = @(
    [pscustomobject]@{ Label = 'Glow'; Options = @('Yes', 'No'); Values = @('true', 'false'); IsText = $false }
)
Test-That 'Yes answered on the phone matches true in the transcript' {
    Test-CopilotAnswerMatchesSelections -ResultContent 'User responded: glow=true' `
        -Fields $boolFields -Selections @('Yes')
}
Test-That 'but Yes against false is still a mismatch' {
    -not (Test-CopilotAnswerMatchesSelections -ResultContent 'User responded: glow=false' `
        -Fields $boolFields -Selections @('Yes'))
}
Test-That 'No answered on the phone matches false' {
    Test-CopilotAnswerMatchesSelections -ResultContent 'User responded: glow=false' `
        -Fields $boolFields -Selections @('No')
}

Write-Host "`n--- the old behaviour still holds where it was right ---"

# A marker armed before values were carried is read by the new daemon after an
# upgrade. It has labels only, and must be compared on labels rather than throwing.
$legacyFields = @(
    [pscustomobject]@{ Label = 'Alignment'; Options = @('Aligned', 'Closer'); IsText = $false }
)
Test-That 'a marker from before the upgrade is compared on labels' {
    Test-CopilotAnswerMatchesSelections -ResultContent 'User responded: alignment=Closer' `
        -Fields $legacyFields -Selections @('Closer')
}
Test-That 'and a wrong one from before the upgrade is still caught' {
    -not (Test-CopilotAnswerMatchesSelections -ResultContent 'User responded: alignment=Aligned' `
        -Fields $legacyFields -Selections @('Closer'))
}

Write-Host "`n--- structured text is compared within its own field too ---"
$structuredFields = @(
    [pscustomobject]@{ Name = 'choice'; Label = 'Choice'; Options = @('Yes', 'No'); Values = @('yes', 'no'); IsText = $false }
    [pscustomobject]@{ Name = 'notes'; Label = 'Notes'; Options = @(); IsText = $true }
)
Test-That 'matching structured choice and text fields are confirmed together' {
    (Test-CopilotAnswerMatchesSelections -ResultContent '{"choice":"no","notes":"keep exactly"}' `
        -Fields $structuredFields -Selections @('No', 'keep exactly') -Detailed).Status -ceq 'Matched'
}
Test-That 'a structured text mismatch cannot hide behind a matching choice' {
    (Test-CopilotAnswerMatchesSelections -ResultContent '{"choice":"no","notes":"different"}' `
        -Fields $structuredFields -Selections @('No', 'keep exactly') -Detailed).Status -ceq 'Mismatch'
}
Test-That 'a non-string structured text result remains unconfirmed rather than coerced' {
    (Test-CopilotAnswerMatchesSelections -ResultContent '{"choice":"no","notes":false}' `
        -Fields $structuredFields -Selections @('No', 'false') -Detailed).Status -ceq 'Unconfirmed'
}
Test-That 'an exact structured text-only answer can be confirmed' {
    (Test-CopilotAnswerMatchesSelections -ResultContent '{"notes":"2030-01-02T03:04:05Z"}' `
        -Fields @($structuredFields[1]) -Selections @('2030-01-02T03:04:05Z') -Detailed).Status -ceq 'Matched'
}
Test-That 'different date-looking text spellings remain a structured text mismatch' {
    (Test-CopilotAnswerMatchesSelections -ResultContent '{"notes":"2030-01-02T03:04:05.000Z"}' `
        -Fields @($structuredFields[1]) -Selections @('2030-01-02T03:04:05Z') -Detailed).Status -ceq 'Mismatch'
}
$claudeField = [pscustomobject]@{ Name = 'Which?'; Label = 'Database'; Options = @('No', 'Not now', 'SQLite.'); IsText = $false }
Test-That 'the established Claude envelope still distinguishes No from Not now' {
    (Test-CopilotAnswerMatchesSelections -ResultContent 'Your questions have been answered: "Which?"="Not now".' `
        -Fields @($claudeField) -Selections @('No') -Detailed).Status -ceq 'Mismatch'
}
Test-That 'stripping the Claude envelope preserves punctuation inside the actual value' {
    (Test-CopilotAnswerMatchesSelections -ResultContent 'Your questions have been answered: "Which?"="SQLite.".' `
        -Fields @($claudeField) -Selections @('SQLite.') -Detailed).Status -ceq 'Matched'
}
Test-That 'an unknown trailing Claude sentence is not silently discarded' {
    (Test-CopilotAnswerMatchesSelections -ResultContent 'Your questions have been answered: "Which?"="No". Something else.' `
        -Fields @($claudeField) -Selections @('No') -Detailed).Status -ceq 'Unconfirmed'
}

if ($script:Failures -gt 0) {
    Write-Host "`n$($script:Failures) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall passed" -ForegroundColor Green
