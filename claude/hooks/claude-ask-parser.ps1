<#
.SYNOPSIS
    Parses a Claude Code AskUserQuestion hook event into the bridge's decision shape.

.DESCRIPTION
    Claude Code delivers hook events as JSON on stdin. A PreToolUse event carries:

        session_id, transcript_path, cwd, hook_event_name, tool_name,
        tool_input, permission_mode

    and for AskUserQuestion the tool_input is:

        { questions: [ { question, header, multiSelect,
                         options: [ { label, description } ] } ] }

    These field names were read out of the shipping claude.exe (2.1.215) rather than
    documentation, so they reflect what the tool actually sends.

    The output matches what Set-CopilotMqttDecision already expects, so the Claude
    adapter reuses the proven Home Assistant layer unchanged:

        @{ Question = <string>; Choices = <string[]>; Fields = <object[]> }

    Claude always offers "Other" for free text, so no synthetic Other option is added.
#>

Set-StrictMode -Version Latest

# Windows/macOS differences. Installed beside this file; in the repository it is the
# core's copy.
. $(if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'bridge-platform.ps1')) { Join-Path $PSScriptRoot 'bridge-platform.ps1' }
    else { Join-Path $PSScriptRoot '../../hooks/bridge-platform.ps1' })

$script:ClaudeMaxFields = 4
$script:ClaudeMaxQuestionLength = 6000

function ConvertFrom-ClaudeAskUserQuestion {
    <#
        Returns the decision shape for a Claude AskUserQuestion tool_input.

        One question becomes a single dropdown. Several become one dropdown per
        question, which is how the bridge avoids a combinatorial option list. More
        than $ClaudeMaxFields falls back to freeform with a numbered outline, so
        nothing is ever silently dropped.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $ToolInput
    )

    $questions = @()
    if ($null -ne $ToolInput -and $ToolInput.PSObject.Properties.Name -contains 'questions') {
        $questions = @($ToolInput.questions)
    }

    if ($questions.Count -eq 0) {
        return [pscustomobject]@{
            Question     = 'Claude needs an answer.'
            Choices      = @()
            Fields       = @()
            MarkerFields = @()
            MultiSelect  = $false
        }
    }

    # Option descriptions carry real decision content, but folded into the option
    # text they made the dropdown unreadable ("label - description" cut off after a
    # few words), and the recorded answer - which is the bare label - never matched
    # what was sent. They are listed under the question instead.
    $notes = [System.Collections.Generic.List[string]]::new()

    $fields = foreach ($question in $questions) {
        $labels = @()
        if ($question.PSObject.Properties.Name -contains 'options') {
            $labels = @(
                foreach ($option in @($question.options)) {
                    $label = if ($option -is [string]) { $option } else { [string]$option.label }
                    if ($option -isnot [string] -and
                        $option.PSObject.Properties.Name -contains 'description' -and
                        $option.description) {
                        $notes.Add("- **$label** - $([string]$option.description)")
                    }
                    $label
                }
            )
        }

        [pscustomobject]@{
            # Label and Options are the contract Set-CopilotMqttDecision consumes for
            # per-field dropdowns; Title and MultiSelect are extra context for logging
            # and the freeform outline.
            Label       = if ($question.PSObject.Properties.Name -contains 'header' -and $question.header) {
                              [string]$question.header
                          } else {
                              [string]$question.question
                          }
            Title       = [string]$question.question
            Name        = [string]$question.question
            Client      = 'claude'
            Values      = $labels
            Type        = if ($question.PSObject.Properties['multiSelect'] -and $question.multiSelect) { 'array' } else { 'string' }
            IsText      = ($labels.Count -eq 0)
            Options     = $labels
            MultiSelect = [bool]($question.PSObject.Properties.Name -contains 'multiSelect' -and $question.multiSelect)
        }
    }

    $fields = @($fields)
    $prompt = ($fields | ForEach-Object { $_.Title }) -join ' / '
    $described = if ($notes.Count -gt 0) { "`n`n" + ($notes -join "`n") } else { '' }
    # A multi-select question is toggled option by option and then submitted, which
    # the bridge cannot drive reliably by keystroke; it is answered in the terminal.
    $multiSelect = @($fields | Where-Object { $_.MultiSelect }).Count -gt 0

    if ($fields.Count -eq 1) {
        return [pscustomobject]@{
            Question     = Limit-ClaudeText -Text ($fields[0].Title + $described)
            Choices      = $fields[0].Options
            Fields       = @()
            # The daemon drives the answer by index through its field, so the marker
            # carries it even though the card shows a single plain dropdown.
            MarkerFields = @($fields[0])
            MultiSelect  = $multiSelect
        }
    }

    if ($fields.Count -le $script:ClaudeMaxFields) {
        return [pscustomobject]@{
            Question     = Limit-ClaudeText -Text ($prompt + $described)
            Choices      = @()
            Fields       = $fields
            MarkerFields = $fields
            MultiSelect  = $multiSelect
        }
    }

    # Too many questions for dropdowns: keep every option visible in the text so the
    # user can still answer accurately in the reply box.
    $outline = for ($i = 0; $i -lt $fields.Count; $i++) {
        $options = if ($fields[$i].Options.Count) { ': ' + ($fields[$i].Options -join ' | ') } else { '' }
        "$($i + 1). $($fields[$i].Title)$options"
    }

    [pscustomobject]@{
        Question     = Limit-ClaudeText -Text (($prompt, ($outline -join "`n")) -join "`n`n")
        Choices      = @()
        Fields       = @()
        MarkerFields = $fields
        MultiSelect  = $multiSelect
    }
}

function Limit-ClaudeText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ($Text.Length -le $script:ClaudeMaxQuestionLength) { return $Text }
    $Text.Substring(0, $script:ClaudeMaxQuestionLength - 20) + "`n[truncated]"
}

function Add-ClaudeTerminalOnlyNotice {
    <#
        Rewrites a question the dashboard cannot drive so the card says so, and lists
        the options the card will no longer be showing.

        The options have to be repeated here because they reach the card only through
        the dropdowns, which a terminal-only question does not get: without this, an
        option Claude gave no description for disappears from the card entirely.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Question,
        [AllowNull()][AllowEmptyCollection()][object[]]$Fields = @(),

        # Why it cannot be driven, when the caller knows better than the shape of the
        # fields does. Whether a multi-select question is answerable depends on how
        # many combinations its options make, which is the core's to decide, not this
        # parser's.
        [AllowEmptyString()][string]$Reason = ''
    )

    $fieldList = @($Fields)
    $parts = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($Question)) { $parts.Add($Question) }

    $anyMultiSelect = $false
    if ($fieldList.Count -gt 0) {
        $outline = for ($i = 0; $i -lt $fieldList.Count; $i++) {
            $field = $fieldList[$i]
            $multi = [bool]($field.PSObject.Properties.Name -contains 'MultiSelect' -and $field.MultiSelect)
            if ($multi) { $anyMultiSelect = $true }
            $options = if (@($field.Options).Count) { ': ' + (@($field.Options) -join ' | ') } else { '' }
            "$($i + 1). $([string]$field.Title)$(if ($multi) { ' (pick any)' })$options"
        }
        $parts.Add(($outline -join "`n"))
    }

    $why = if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $Reason
    }
    elseif ($anyMultiSelect) {
        'it offers more combinations than the dashboard can list'
    }
    else {
        'it has more fields than the dashboard can drive'
    }
    $parts.Add("**Answer this one in the terminal** - $why, so an answer chosen here would not reach the prompt.")

    Limit-ClaudeText -Text ($parts -join "`n`n")
}

function Get-ClaudeHookEvent {
    <#
        Reads and parses the hook event from stdin. Returns $null when nothing usable
        arrives, so a caller can fail open rather than block Claude.
    #>
    param([string]$Raw)

    if (-not $Raw) { $Raw = [Console]::In.ReadToEnd() }
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    try { return $Raw | ConvertFrom-Json } catch { return $null }
}

function Test-ClaudeNotificationNeedsUser {
    <#
        Whether a Notification event means Claude is blocked on the user.

        Claude sends notifications for several reasons, and only some of them mean
        it cannot continue: a permission prompt, a question dialog. The idle reminder
        - "Claude is waiting for your input", sent about a minute after a turn ends -
        does not; the turn is already over. Treating it as blocked turned every
        finished session's card to 'waiting' a minute later.

        The type comes from `notification_type`, read out of Claude Code 2.1.283. A
        build that does not send one is judged by the idle reminder's fixed wording,
        and anything else is still treated as blocking, so a genuine prompt is never
        missed.
    #>
    param([Parameter(Mandatory)]$Event)

    $blocking = @('permission_prompt', 'worker_permission_prompt', 'elicitation_dialog',
                  'elicitation_url_dialog', 'agent_needs_input')

    $type = ''
    if ($Event.PSObject.Properties['notification_type']) { $type = [string]$Event.notification_type }
    if (-not [string]::IsNullOrWhiteSpace($type)) { return ($blocking -contains $type) }

    $message = if ($Event.PSObject.Properties['message']) { [string]$Event.message } else { '' }
    -not ($message -match '^\s*Claude is waiting for your input')
}

function Get-ClaudeOwningProcessId {
    <#
        Finds the claude process that owns this hook.

        Claude Code has no equivalent of Copilot's inuse.<pid>.lock, but a hook runs as
        a descendant of the session it belongs to, so walking up the parent chain
        identifies it unambiguously - and correctly picks the right one when several
        sessions are open.
    #>
    param([int]$StartPid = $PID, [int]$MaxDepth = 12, [int[]]$Ancestors = @())

    # Passed only when there is a chain: a bridge-platform.ps1 from before -Ancestors
    # (mid-update, or a checkout run against an older install) would otherwise refuse
    # the call, and every hook would quietly lose its session's process.
    if (@($Ancestors).Count -gt 0) {
        return Find-BridgeAgentAncestor -Agent 'claude' -StartPid $StartPid -MaxDepth $MaxDepth -Ancestors $Ancestors
    }
    Find-BridgeAgentAncestor -Agent 'claude' -StartPid $StartPid -MaxDepth $MaxDepth
}
