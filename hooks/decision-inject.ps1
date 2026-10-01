<#
    Delivers text into a running Copilot CLI session as if it had been typed.

    This is what lets the bridge answer a session whose turn has already finished.
    The previous design held the turn open from inside the agentStop hook, which
    created a deadlock: while the hook blocks, the CLI queues anything typed in the
    terminal and does not append it to the transcript, so the documented "terminal
    input cancels the wait" escape could never fire. The workaround was to arm the
    reply box only on turns longer than three minutes, which in practice disabled it
    - 21 of 22 turns in the bridge log were skipped with "user is still at the
    terminal".

    Writing to the session's console input buffer removes the need to block at all.
    The hook can return immediately, and a reply typed on the phone minutes later is
    still delivered.

    Verified 2026-09-21 against a throwaway process: WriteConsoleInput reported
    ok=True written=138/138 and the injected command executed.
#>

$script:CopilotInjectorTypeName = 'CopilotCli.ConsoleInjector'

function Invoke-BridgeConsoleSend {
    <#
        Types $Text into the terminal of $ProcessId and, with -Submit, presses Enter
        after $DelayMs as a separate keystroke. The text may carry arrow-key escape
        sequences (a form's Down presses).

        Windows attaches to the session's console (ConsoleInjector.Send); macOS types
        into the tmux pane the session runs in. Returns "ok:..." or why it failed -
        "not-in-tmux" for a macOS session started outside tmux.
    #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [bool]$Submit = $true,
        [int]$DelayMs = 300
    )
    if (-not $script:BridgeIsWindows) {
        return Send-BridgeTmuxText -ProcessId $ProcessId -Text $Text -Submit:$Submit -SubmitDelayMs $DelayMs
    }
    Initialize-CopilotConsoleInjector
    [string][CopilotCli.ConsoleInjector]::Send([uint32]$ProcessId, $Text, $Submit, $DelayMs)
}

function Invoke-BridgeConsoleChoice {
    <# Answers an arrow-key choice prompt through its "Other" entry; see Send-CopilotSessionChoice. #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][int]$DownCount,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [int]$StepDelayMs = 120
    )
    if (-not $script:BridgeIsWindows) {
        return Send-BridgeTmuxChoice -ProcessId $ProcessId -DownCount $DownCount -Text $Text -StepDelayMs $StepDelayMs
    }
    Initialize-CopilotConsoleInjector
    [string][CopilotCli.ConsoleInjector]::SendChoice([uint32]$ProcessId, $DownCount, $Text, $StepDelayMs)
}

function Initialize-CopilotConsoleInjector {
    # The Windows console API; macOS goes through tmux instead (Invoke-BridgeConsoleSend).
    if (-not $script:BridgeIsWindows) { return }
    if (-not ([Management.Automation.PSTypeName]$script:CopilotInjectorTypeName).Type) {
        # Compiled once into a cached DLL rather than in this process (Add-BridgeCompiledType).
        Add-BridgeCompiledType -TypeName $script:CopilotInjectorTypeName -Source @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

namespace CopilotCli {
    public static class ConsoleInjector {
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AttachConsole(uint dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool FreeConsole();

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateFileW(
            string lpFileName, uint dwDesiredAccess, uint dwShareMode,
            IntPtr lpSecurityAttributes, uint dwCreationDisposition,
            uint dwFlagsAndAttributes, IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        [StructLayout(LayoutKind.Sequential)]
        private struct KEY_EVENT_RECORD {
            public bool bKeyDown;
            public ushort wRepeatCount;
            public ushort wVirtualKeyCode;
            public ushort wVirtualScanCode;
            public char UnicodeChar;
            public uint dwControlKeyState;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct INPUT_RECORD {
            [FieldOffset(0)] public ushort EventType;
            [FieldOffset(4)] public KEY_EVENT_RECORD Key;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool WriteConsoleInputW(
            IntPtr hConsoleInput, INPUT_RECORD[] lpBuffer, uint nLength, out uint lpNumberOfEventsWritten);

        private const uint GENERIC_READ = 0x80000000;
        private const uint GENERIC_WRITE = 0x40000000;
        private const uint OPEN_EXISTING = 3;
        private const ushort KEY_EVENT = 1;
        private const ushort VK_RETURN = 0x0D;
        private const ushort VK_DOWN = 0x28;
        private const ushort VK_UP = 0x26;
        private const ushort VK_TAB = 0x09;

        public static string SendForm(uint processId, int[] downCounts, string[] texts, int stepDelayMs) {
            // Answers the native ask_user prompt, which renders as an arrow-key option
            // list per field, shown as tabbed sections for a multi-field form.
            //
            // A field is answered one of two ways. A choice field is answered by
            // pressing Down to the chosen option's index; a free-text field is
            // answered by typing its value. Either way Enter commits - the prompt's
            // own footer reads "enter accept" - and on a non-final field it advances
            // to the next one, while on the last field it submits the whole form.
            //
            // Supporting typed fields is what makes a mixed form answerable at all.
            // Before this, a form with even one free-text field could not be driven by
            // arrow keys, so the bridge fell back to a plain text box - and typing
            // into a live arrow-key prompt silently discards every character, which
            // lost the answer and left the prompt waiting.
            //
            // Tab is deliberately NOT used to move between fields. It moves focus
            // without committing the highlighted option, so a form driven with
            // Down/Tab/Down/Enter came back with only the last field set and the
            // earlier ones missing entirely (observed: a two-field colour/size form
            // returned "size: Large" with no colour at all).
            FreeConsole();
            if (!AttachConsole(processId)) {
                return "attach-failed:" + Marshal.GetLastWin32Error();
            }

            IntPtr handle = IntPtr.Zero;
            try {
                handle = CreateFileW("CONIN$", GENERIC_READ | GENERIC_WRITE, 1 | 2,
                    IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                if (handle == new IntPtr(-1)) {
                    return "conin-failed:" + Marshal.GetLastWin32Error();
                }

                int typed = 0;
                // Let the prompt settle before the first keystroke. Without this the
                // very first Down was delivered the instant after AttachConsole and
                // could be swallowed before the prompt was listening - which silently
                // answered one option short. Observed: a field selected as index 1 in
                // Home Assistant came back from the CLI as index 0, while a field
                // needing no Down at all was correct, so every earlier test passed by
                // accident.
                Thread.Sleep(stepDelayMs * 4);

                for (int f = 0; f < downCounts.Length; f++) {
                    string text = (texts != null && f < texts.Length) ? texts[f] : null;

                    if (text != null) {
                        // A typed field. The characters go in as one burst, which the
                        // CLI treats as a paste, so the committing Enter has to be a
                        // separate keypress after a pause - exactly as in Send().
                        List<INPUT_RECORD> textRecords = new List<INPUT_RECORD>();
                        foreach (char c in text) {
                            AddChar(textRecords, c);
                        }
                        if (textRecords.Count > 0) {
                            INPUT_RECORD[] textBuffer = textRecords.ToArray();
                            uint textWritten;
                            if (!WriteConsoleInputW(handle, textBuffer, (uint)textBuffer.Length, out textWritten)) {
                                return "write-failed:" + Marshal.GetLastWin32Error();
                            }
                            if (textWritten != textBuffer.Length) {
                                return "partial:" + textWritten + "/" + textBuffer.Length;
                            }
                            typed++;
                        }
                    }
                    else {
                        for (int i = 0; i < downCounts[f]; i++) {
                            // Pause *before* each press, not only after. The gap the
                            // prompt needs is the one ahead of a keystroke.
                            Thread.Sleep(stepDelayMs);
                            if (!WriteVirtualKey(handle, VK_DOWN)) {
                                return "down-failed:" + Marshal.GetLastWin32Error();
                            }
                        }
                    }

                    // Commit this field. The final one submits the form.
                    Thread.Sleep(stepDelayMs * 2);
                    if (!WriteVirtualKey(handle, VK_RETURN)) {
                        return "commit-failed:" + Marshal.GetLastWin32Error();
                    }
                    Thread.Sleep(stepDelayMs * 2);
                }

                return "ok:form:" + downCounts.Length + ":typed" + typed;
            }
            finally {
                if (handle != IntPtr.Zero && handle != new IntPtr(-1)) {
                    CloseHandle(handle);
                }
                FreeConsole();
            }
        }

        public static string SendChoice(uint processId, int downCount, string text, int stepDelayMs) {
            // Answers an ask_user choice prompt, which the CLI renders as an arrow-key
            // select list whose final entry is "Other (type your answer)".
            //
            // Rather than counting arrow presses to land on a specific option - which
            // would break whenever the option list changes - this walks all the way
            // down to the "Other" entry and types the answer as text. That is the one
            // path that works for any option list, including combined multi-field
            // options whose text does not match any single entry.
            FreeConsole();
            if (!AttachConsole(processId)) {
                return "attach-failed:" + Marshal.GetLastWin32Error();
            }

            IntPtr handle = IntPtr.Zero;
            try {
                handle = CreateFileW("CONIN$", GENERIC_READ | GENERIC_WRITE, 1 | 2,
                    IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                if (handle == new IntPtr(-1)) {
                    return "conin-failed:" + Marshal.GetLastWin32Error();
                }

                // Each arrow key is written as its own burst with a pause, so the TUI
                // processes them as distinct keypresses rather than one paste.
                for (int i = 0; i < downCount; i++) {
                    if (!WriteVirtualKey(handle, VK_DOWN)) {
                        return "down-failed:" + Marshal.GetLastWin32Error();
                    }
                    Thread.Sleep(stepDelayMs);
                }

                // Enter selects "Other", which opens the text input.
                if (!WriteVirtualKey(handle, VK_RETURN)) {
                    return "enter-failed:" + Marshal.GetLastWin32Error();
                }
                Thread.Sleep(stepDelayMs * 2);

                // Type the answer, then submit it as a separate keystroke so the CLI's
                // paste detection does not swallow the newline.
                List<INPUT_RECORD> textRecords = new List<INPUT_RECORD>();
                foreach (char c in text) {
                    AddChar(textRecords, c);
                }
                if (textRecords.Count > 0) {
                    INPUT_RECORD[] buf = textRecords.ToArray();
                    uint written;
                    if (!WriteConsoleInputW(handle, buf, (uint)buf.Length, out written)) {
                        return "write-failed:" + Marshal.GetLastWin32Error();
                    }
                }
                Thread.Sleep(stepDelayMs * 2);
                if (!WriteVirtualKey(handle, VK_RETURN)) {
                    return "submit-failed:" + Marshal.GetLastWin32Error();
                }

                return "ok:choice";
            }
            finally {
                if (handle != IntPtr.Zero && handle != new IntPtr(-1)) {
                    CloseHandle(handle);
                }
                FreeConsole();
            }
        }

        private static bool WriteVirtualKey(IntPtr handle, ushort vk) {
            List<INPUT_RECORD> records = new List<INPUT_RECORD>();
            for (int i = 0; i < 2; i++) {
                INPUT_RECORD r = new INPUT_RECORD();
                r.EventType = KEY_EVENT;
                char ch = '\0';
                if (vk == VK_RETURN) { ch = '\r'; }
                else if (vk == VK_TAB) { ch = '\t'; }
                r.Key = new KEY_EVENT_RECORD {
                    bKeyDown = (i == 0),
                    wRepeatCount = 1,
                    wVirtualKeyCode = vk,
                    wVirtualScanCode = 0,
                    UnicodeChar = ch,
                    dwControlKeyState = 0
                };
                records.Add(r);
            }
            INPUT_RECORD[] buffer = records.ToArray();
            uint written;
            return WriteConsoleInputW(handle, buffer, (uint)buffer.Length, out written);
        }

        public static string Send(uint processId, string text, bool submit, int submitDelayMs) {
            // Detach from any console this process already owns, otherwise
            // AttachConsole fails with ERROR_ACCESS_DENIED.
            FreeConsole();

            if (!AttachConsole(processId)) {
                return "attach-failed:" + Marshal.GetLastWin32Error();
            }

            IntPtr handle = IntPtr.Zero;
            try {
                handle = CreateFileW("CONIN$", GENERIC_READ | GENERIC_WRITE, 1 | 2,
                    IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                if (handle == new IntPtr(-1)) {
                    return "conin-failed:" + Marshal.GetLastWin32Error();
                }

                // Write the text as its own burst. The Copilot CLI treats a rapid
                // burst of characters as a paste, and a newline that arrives inside
                // that burst is inserted literally rather than submitting the line -
                // which is exactly the multi-line-paste behaviour it wants. So the
                // Enter must be delivered separately, after a pause long enough for
                // the CLI to consider the paste finished, so it lands as a genuine
                // standalone keypress that submits.
                List<INPUT_RECORD> textRecords = new List<INPUT_RECORD>();
                foreach (char c in text) {
                    AddChar(textRecords, c);
                }

                if (textRecords.Count > 0) {
                    INPUT_RECORD[] textBuffer = textRecords.ToArray();
                    uint textWritten;
                    if (!WriteConsoleInputW(handle, textBuffer, (uint)textBuffer.Length, out textWritten)) {
                        return "write-failed:" + Marshal.GetLastWin32Error();
                    }
                    if (textWritten != textBuffer.Length) {
                        return "partial:" + textWritten + "/" + textBuffer.Length;
                    }
                }

                if (submit) {
                    if (submitDelayMs > 0) {
                        Thread.Sleep(submitDelayMs);
                    }
                    List<INPUT_RECORD> enterRecords = new List<INPUT_RECORD>();
                    AddChar(enterRecords, '\r');
                    INPUT_RECORD[] enterBuffer = enterRecords.ToArray();
                    uint enterWritten;
                    if (!WriteConsoleInputW(handle, enterBuffer, (uint)enterBuffer.Length, out enterWritten)) {
                        return "enter-failed:" + Marshal.GetLastWin32Error();
                    }
                }

                return "ok:" + textRecords.Count;
            }
            finally {
                if (handle != IntPtr.Zero && handle != new IntPtr(-1)) {
                    CloseHandle(handle);
                }
                FreeConsole();
            }
        }

        private static void AddChar(List<INPUT_RECORD> records, char c) {
            // Every character needs a matching key-up, otherwise the console
            // input buffer reports a stuck key.
            for (int i = 0; i < 2; i++) {
                INPUT_RECORD record = new INPUT_RECORD();
                record.EventType = KEY_EVENT;
                record.Key = new KEY_EVENT_RECORD {
                    bKeyDown = (i == 0),
                    wRepeatCount = 1,
                    wVirtualKeyCode = (c == '\r') ? VK_RETURN : (ushort)0,
                    wVirtualScanCode = 0,
                    UnicodeChar = c,
                    dwControlKeyState = 0
                };
                records.Add(record);
            }
        }
    }
}
'@
    }
}

function Get-CopilotSessionProcessId {
    <#
        Resolves the CLI process that owns a session.

        Each live session directory holds an `inuse.<pid>.lock` file. A lock whose
        process is gone is stale and ignored, which also keeps a resumed session from
        being delivered to a dead pid.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId
    )

    $dir = Join-Path $script:DecisionBridgeConfig.SessionStateRoot (Get-CopilotSafeSessionKey -SessionId $SessionId)
    if (-not (Test-Path -LiteralPath $dir)) {
        return $null
    }

    $locks = @(Get-ChildItem -LiteralPath $dir -Filter 'inuse.*.lock' -ErrorAction SilentlyContinue)
    foreach ($lock in $locks) {
        if ($lock.Name -notmatch '^inuse\.(\d+)\.lock$') { continue }
        $processId = [int]$Matches[1]
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -eq $process) { continue }
        # Exact match only. The machine also runs `copilotapp` and `copilotapphost`,
        # which a prefix match would happily accept and then type into.
        if (-not (Test-BridgeAgentProcess -Process $process -Agent 'copilot')) { continue }
        return $processId
    }

    $null
}

function Get-CopilotInjectableText {
    <#
        Reduces a reply to text that is safe to type into a live terminal.

        Every control character - newlines, carriage returns, tab, escape, backspace,
        and the other C0/C1 controls - is collapsed to a space. That keeps a reply
        typed on the dashboard to printable text only: it can never submit an extra
        line into the CLI, nor smuggle a terminal control/escape sequence that drives
        the UI. Submission is done deliberately by a separate Enter keystroke.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $Text -replace '\p{Cc}', ' '
}

function Send-CopilotSessionPrompt {
    <#
        Types text into a session's console and submits it.

        Returns a result object rather than throwing, because a delivery failure must
        never take down the daemon: the answer can still be read on the dashboard and
        retried.

        A newline inside the text is converted to a space. The CLI treats Enter as
        submit, so an embedded newline would send a partial prompt.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        [Parameter(Mandatory)]
        [string]$Text,

        [switch]$NoSubmit,

        # Pause between the text burst and the Enter keystroke, long enough for the
        # CLI to treat the text as a finished paste so the following Enter submits.
        [int]$SubmitDelayMs = 300,

        # Explicit target process, for front ends that do not leave an
        # inuse.<pid>.lock behind. Claude Code sessions are identified by walking the
        # hook's parent chain instead, and the daemon already knows the result.
        [int]$ProcessId = 0
    )

    $result = [pscustomobject]@{
        Delivered = $false
        ProcessId = $null
        Detail = ''
    }

    if ([string]::IsNullOrWhiteSpace($Text)) {
        $result.Detail = 'empty text'
        return $result
    }

    $processId = if ($ProcessId -gt 0) { $ProcessId } else { Get-CopilotSessionProcessId -SessionId $SessionId }
    if ($null -eq $processId) {
        $result.Detail = 'no live process for session'
        return $result
    }
    $result.ProcessId = $processId

    $clean = Get-CopilotInjectableText -Text $Text

    try {
        $outcome = Invoke-BridgeConsoleSend -ProcessId $processId -Text $clean `
            -Submit (-not $NoSubmit.IsPresent) -DelayMs $SubmitDelayMs
        $result.Detail = $outcome
        $result.Delivered = $outcome.StartsWith('ok:')
    }
    catch {
        $result.Detail = "exception: $($_.Exception.Message)"
    }

    $result
}

# How long to leave between the separate writes one field is delivered in - each
# toggle of a multi-select list. Measured against a live prompt: the toggles land
# reliably at this spacing, and were dropped entirely when sent as one write.
$script:BridgeFormKeyGapMs = 350

function Get-BridgeFormPayloads {
    <#
        Turns a form's fields and chosen values into the exact sequence typed into the
        prompt, one entry per field.

        A scalar choice moves from its captured default focus to the selected index;
        a free-text field becomes the text itself. The caller commits with Enter.

        This is separated out because getting it wrong is silent: the prompt accepts
        whatever arrives and reports it as the user's own answer. An empty payload for
        a choice field does not fail - it leaves that field on its current default.

        Returns objects with Payload and IsText, in field order. Throws if a selection
        is not one of its field's options.

        Keys is the payload split into the separate writes it has to be delivered in:
        one entry for most fields, one per toggle plus the walk to Submit for a
        multi-select one, which cannot be delivered in a single write (see
        Send-CopilotSessionForm).
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Fields,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Selections
    )

    if ($Fields.Count -ne $Selections.Count) { throw 'Every decision field needs one selection.' }
    $esc = [string][char]27
    for ($i = 0; $i -lt $Fields.Count; $i++) {
        if (Test-DecisionFieldIsText -Field $Fields[$i]) {
            # Normalised the same way a reply is: a newline mid-form would commit the
            # field early and leave the rest of the prompt unanswered.
            $text = [string](Get-CopilotInjectableText -Text ([string]$Selections[$i]))
            [pscustomobject]@{
                Payload = $text
                Keys    = @($text)
                IsText  = $true
                Index   = 0
            }
            continue
        }

        $options = @($Fields[$i].Options | ForEach-Object { [string]$_ })
        [void](Get-DecisionSchemaFieldChoices -Field ([pscustomobject]@{ enum = $options }))

        # A multi-select field is a checkbox list, not a cursor. Its options are
        # numbered on screen and typing a number toggles that one, wherever the cursor
        # happens to be - which is both simpler and safer than counting Down presses.
        # Then Down once per row (the options plus the "Type something" row) lands on
        # Submit, and the caller's Enter presses it.
        #
        # Verified live against Claude Code 2.1.273 on two- and three-option questions:
        # "2" then "3" checked exactly Billing and Search, four Downs highlighted
        # Submit, and Claude recorded "Billing, Search". Tab was tried as a way to
        # reach Submit without counting - the decompiled handler ignores it once Submit
        # has focus - but overshooting with Tab tore the prompt down, so the count is
        # exact and deliberate.
        if (Test-DecisionFieldIsMultiSelect -Field $Fields[$i]) {
            $picked = @(Resolve-DecisionMultiSelectChoice -Field $Fields[$i] -Choice ([string]$Selections[$i]))
            if ($picked.Count -eq 0) { throw "combination '$($Selections[$i])' not found in field $i" }
            $keys = New-Object System.Collections.Generic.List[string]
            foreach ($option in $picked) {
                $at = [Array]::IndexOf($options, [string]$option)
                # Only the first nine rows have a number to type.
                if ($at -lt 0 -or $at -ge 9) { throw "option '$option' is not typeable in field $i" }
                $keys.Add([string]($at + 1))
            }
            $keys.Add((($esc + '[B') * ($options.Count + 1)))
            [pscustomobject]@{
                Payload = ($keys -join '')
                Keys    = $keys.ToArray()
                IsText  = $false
                Index   = -1
            }
            continue
        }

        $idx = [Array]::IndexOf($options, [string]$Selections[$i])
        if ($idx -lt 0) { throw "option '$($Selections[$i])' not found in field $i" }

        $start = 0
        if ($Fields[$i].PSObject.Properties['DefaultIndex']) {
            $start = $Fields[$i].DefaultIndex
            if ($start -isnot [int] -and $start -isnot [long]) { throw "invalid initial focus in field $i" }
            if ($start -lt 0 -or $start -ge $options.Count) { throw "initial focus outside field $i" }
        }
        $distance = $idx - $start
        $arrow = if ($distance -lt 0) { $esc + '[A' } else { $esc + '[B' }
        $arrows = $arrow * [Math]::Abs($distance)
        [pscustomobject]@{
            Payload = $arrows
            Keys    = @($arrows)
            IsText  = $false
            Index   = $idx
        }
    }
}

function Send-CopilotSessionForm {
    <#
        Answers the native ask_user prompt field by field.

        The prompt renders one arrow-key option list per field, tabbed when there is
        more than one ("up/down select - enter accept - tab next"). Given the field
        definitions captured when the decision was armed, plus the value chosen or
        typed for each field, this drives each field in turn and commits with Enter.

        A field marked IsText is typed rather than selected. That is what makes a form
        mixing dropdowns with a free-text box answerable: previously one free-text
        field made the whole form unanswerable by arrow keys, the bridge fell back to
        a plain text box, and the typed answer was silently discarded by the live
        arrow-key prompt.

        Selecting by index is preferred over typing into a choice field's "Other (type
        your answer)" entry because it returns the schema's real value rather than
        free text, which is what the model expects back.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        # Ordered field definitions: each needs .Options, and optionally .IsText.
        [Parameter(Mandatory)]
        [object[]]$Fields,

        # Ordered value per field, matching $Fields: a chosen option label for a
        # choice field, or the literal text for a text field.
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]]$Selections,

        [int]$StepDelayMs = 120,

        # Explicit target process, for front ends with no inuse.<pid>.lock (Claude,
        # Codex). Without it the form could only ever reach a Copilot session.
        [int]$ProcessId = 0
    )

    $result = [pscustomobject]@{ Delivered = $false; ProcessId = $null; Detail = '' }

    if ($Fields.Count -eq 0 -or $Selections.Count -ne $Fields.Count) {
        $result.Detail = "field/selection mismatch ($($Fields.Count)/$($Selections.Count))"
        return $result
    }

    try {
        $steps = @(Get-BridgeFormPayloads -Fields $Fields -Selections $Selections)
    }
    catch {
        $result.Detail = $_.Exception.Message
        return $result
    }

    # Record exactly what is about to be delivered to the prompt. When a field comes
    # back wrong, this is the difference between knowing the index was miscomputed and
    # knowing the keystrokes were mis-delivered.
    $trace = for ($i = 0; $i -lt $Fields.Count; $i++) {
        if ($steps[$i].IsText) {
            "$($Fields[$i].Label)=<typed $($steps[$i].Payload.Length) chars>"
        }
        else {
            "$($Fields[$i].Label)='$($Selections[$i])' idx=$($steps[$i].Index) of [$(@($Fields[$i].Options) -join ',')]"
        }
    }
    $result.Detail = ($trace -join ' ; ')

    $processId = if ($ProcessId -gt 0) { $ProcessId } else { Get-CopilotSessionProcessId -SessionId $SessionId }
    if ($null -eq $processId) {
        $result.Detail = 'no live process for session'
        return $result
    }
    $result.ProcessId = $processId

    try {
        # One attach-write-detach per FIELD, with that field's arrows and its
        # committing Enter in the same call.
        #
        # Delivering the whole form inside a single attach did not work: the arrow
        # moves were silently dropped and every choice field committed at its FIRST
        # option, in the user's name. Splitting the arrows and the Enter into separate
        # calls did not work either. What does work - verified repeatedly against a
        # live prompt, on single-field and multi-field alike - is exactly this shape:
        # the escape sequence and the Enter delivered together, as Send already does
        # for a reply.
        # One attach-write-detach per FIELD, with that field's arrows and its
        # committing Enter delivered together - the same shape Send already uses for a
        # reply, which is the delivery path with a long record of working.
        $outcome = 'ok:form'
        for ($i = 0; $i -lt $steps.Count; $i++) {
            # A multi-select field needs each toggle in its own attach-write-detach.
            # Delivered as one write - the digits and the walk to Submit together -
            # the toggles were silently dropped and the prompt reached its review
            # screen saying "You have not answered all questions", which is the same
            # way the arrows behaved when a whole form was delivered in one attach.
            # Only the last write carries the committing Enter.
            $keys = @($steps[$i].Keys)
            $failed = $false
            for ($k = 0; $k -lt $keys.Count; $k++) {
                $isLast = ($k -eq ($keys.Count - 1))
                $r = Invoke-BridgeConsoleSend -ProcessId $processId -Text $keys[$k] -Submit $isLast -DelayMs $StepDelayMs
                if (-not $r.StartsWith('ok')) { $outcome = "field${i}:$r"; $failed = $true; break }
                if (-not $isLast) { Start-Sleep -Milliseconds $script:BridgeFormKeyGapMs }
            }
            if ($failed) { break }
            Start-Sleep -Milliseconds ($StepDelayMs * 2)
        }

        $result.Detail = "$outcome | " + $result.Detail
        $result.Delivered = $outcome.StartsWith('ok')
    }
    catch {
        $result.Detail = "exception: $($_.Exception.Message)"
    }

    $result
}

function Send-CopilotSessionChoice {
    <#
        Answers a live ask_user choice prompt.

        The CLI renders choices as an arrow-key select list whose final entry is
        "Other (type your answer)" - confirmed from the CLI bundle, whose footer hints
        read {"up-down":"to select", enter:"to confirm"}. Selecting that entry opens a
        text input.

        Walking to the "Other" entry and typing the answer is deliberately preferred
        over counting arrow presses to a specific option: it is correct no matter how
        the option list is ordered or rendered, and it is the only workable path for a
        combined multi-field answer whose text matches no single entry.

        `ChoiceCount` is how many options the prompt lists; the walk is that many Downs
        (plus a margin) to land on the trailing "Other" entry. Extra Downs are harmless
        because the list stops at its last entry.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [int]$ChoiceCount,

        [int]$StepDelayMs = 120,

        # Explicit target process, as for Send-CopilotSessionForm.
        [int]$ProcessId = 0
    )

    $result = [pscustomobject]@{
        Delivered = $false
        ProcessId = $null
        Detail = ''
    }

    if ([string]::IsNullOrWhiteSpace($Text)) {
        $result.Detail = 'empty text'
        return $result
    }

    $processId = if ($ProcessId -gt 0) { $ProcessId } else { Get-CopilotSessionProcessId -SessionId $SessionId }
    if ($null -eq $processId) {
        $result.Detail = 'no live process for session'
        return $result
    }
    $result.ProcessId = $processId

    $clean = Get-CopilotInjectableText -Text $Text
    # A couple of extra Downs guarantee the caret reaches the trailing "Other" entry
    # even if the prompt adds an option the bridge did not know about.
    $downs = [Math]::Max(1, $ChoiceCount + 2)

    try {
        $outcome = Invoke-BridgeConsoleChoice -ProcessId $processId -DownCount $downs -Text $clean -StepDelayMs $StepDelayMs
        $result.Detail = $outcome
        $result.Delivered = $outcome.StartsWith('ok:')
    }
    catch {
        $result.Detail = "exception: $($_.Exception.Message)"
    }

    $result
}
