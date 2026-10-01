<#
    Bridge daemon: what differs between the agents it serves.

    One entry per agent, keyed by the Kind its sessions carry. Shared code asks
    Get-DaemonAgent for a session's entry and calls through it, instead of testing
    for each agent by name. A new agent is a new entry here.

    Slots (script blocks) and flags:
      FindSessions      its live sessions, keyed by id
      Display           a session's name and machine, for its card
      ReadAppend        transcript lines written since an offset
      Activity          what those lines say, for the card
      IsWorking         whether a session is busy when first seen
      PollRegistration  fast lane: has its hook registration changed? ($true = yes)
      FastActivity      fast lane: streams its own card, instead of the shared path
      KnownActivity     reconcile: likewise, for a session already in state
      HookStatus        its hooks record the status, which is authoritative
      InlineReasoning   the card shows its thinking inline, newest line of either kind
      RefreshName       its sessions can be renamed while they run, so the name is
                        re-resolved on every reconcile rather than fixed at adoption
      KnowsProcessId    its live sessions carry the owning process id (Copilot's
                        injector finds the process by its lock file instead)
      AskUserState      whether a question it asked is still waiting, from its transcript
      ApprovalMarker    a pending tool approval its hook recorded, or $null
      TranscriptConfirmsInput  its transcript shows whether typed input was submitted,
                        so a reply or an answer is confirmed rather than assumed
      AdapterInstalled  whether its bridge adapter is in place; an agent without this
                        slot has no adapter the daemon can set up
      Installer         how to install its adapter, given the installer payload; without
                        one, <kind>\install-<kind>.ps1 with no arguments
      SetupNote         what the launch note adds once its adapter is set up

    Copilot is the default: a slot an entry leaves out, or a kind that is blank or not
    listed, gets Copilot's Display, ReadAppend, Activity, IsWorking and AskUserState. That is what the old
    `else` branches did. Flags are never inherited.
    An entry whose adapter is optional checks that it loaded and falls back the way
    those branches did.

    Part of agent-bridge-daemon.ps1, which dot-sources it into its own scope after
    declaring the shared $script: state; see docs/daemon-split.md.
    Shared state it changes: DaemonAgents, DaemonAgentCache; DaemonRegistrationStamps
    and ClaudeRegistrationPaths (Claude's PollRegistration).
#>

$script:DaemonAgents = [ordered]@{
    copilot = @{
        FindSessions = { Get-LiveCopilotSessions }
        Display = { param($SessionId, $WorkingDirectory) Get-CopilotSessionDisplay -SessionId $SessionId -WorkingDirectory $WorkingDirectory }
        ReadAppend = { param($Path, $Offset) Read-TranscriptAppend -Path $Path -Offset $Offset }
        Activity = { param($Lines, $VerboseMode) Get-ActivityFromEvents -Lines $Lines -VerboseMode $VerboseMode }
        IsWorking = { param($SessionId, $Transcript, $Status) Test-CopilotSessionWorking -SessionId $SessionId }
        AskUserState = { param($Session, $Marker) Get-CopilotAskUserState -TranscriptPath ([string]$Session.Transcript) }
        AdapterInstalled = { Test-Path -LiteralPath (Join-Path $HOME '.copilot\hooks\decision-notifier.json') }
        # Copilot's hooks are written by the main installer, which also removes them
        # whenever Copilot is not among the configured clients - so it is run with
        # Copilot added to the list, which makes the setup stick.
        Installer = {
            param($Payload)
            $clients = @(@(Get-BridgeSetting 'clients' @()) | ForEach-Object { [string]$_ } | Where-Object { $_ })
            if ($clients -notcontains 'copilot') { $clients += 'copilot' }
            [pscustomobject]@{
                Path      = Join-Path $Payload 'install.ps1'
                Arguments = "-NonInteractive -Clients $($clients -join ',')"
            }
        }
        SetupNote = {
            if (-not (Get-BridgeLauncherUsage -Launcher 'copilot').SignedIn) { return ' Run copilot once and sign in (/login) before launching it from here.' }
            ' Restart any running sessions so they pick it up.'
        }
        RefreshName = $true
        # Copilot writes its thinking as messages of its own, interleaved with the ones
        # carrying text, so the card can show them in order (Add-DaemonCardText).
        InlineReasoning = $true
    }

    claude = @{
        FindSessions = { Get-LiveClaudeSessions }
        Display = {
            param($SessionId, $WorkingDirectory)
            if (-not $script:ClaudeAdapterLoaded) { return Get-CopilotSessionDisplay -SessionId $SessionId -WorkingDirectory $WorkingDirectory }
            Get-ClaudeSessionDisplay -SessionId $SessionId -WorkingDirectory $WorkingDirectory
        }
        ReadAppend = {
            param($Path, $Offset)
            if (-not $script:ClaudeAdapterLoaded) { return Read-TranscriptAppend -Path $Path -Offset $Offset }
            Read-ClaudeTranscriptAppend -Path $Path -Offset $Offset -MaxTailBytes $script:DaemonConfig.MaxTailBytes
        }
        Activity = {
            param($Lines, $VerboseMode)
            if (-not $script:ClaudeAdapterLoaded) { return Get-ActivityFromEvents -Lines $Lines -VerboseMode $VerboseMode }
            Get-ClaudeActivityFromTranscript -Lines $Lines -VerboseMode $VerboseMode
        }
        IsWorking = {
            param($SessionId, $Transcript, $Status)
            if (-not $script:ClaudeAdapterLoaded -or -not $Transcript) { return $false }
            # Claude writes no turn-end entry, so freshness is the best available signal at
            # adoption time; the Stop hook corrects it authoritatively at the next turn end.
            try {
                return ([DateTime]::UtcNow - [IO.File]::GetLastWriteTimeUtc($Transcript)).TotalSeconds -lt 20
            }
            catch { return $false }
        }
        # Watches the hook registration, so a status a hook just set (a new prompt's
        # 'working', say) is adopted within a tick rather than a reconcile.
        PollRegistration = {
            param($Id, $Session)
            if (-not $script:ClaudeAdapterLoaded) { return $false }
            $changed = $false
            # The path never changes, and building it was most of a tick's cost.
            $registration = $script:ClaudeRegistrationPaths[$Id]
            if (-not $registration) {
                $registration = Join-Path $env:TEMP "agent-bridge-claude\$(Get-ClaudeSafeSessionKey -SessionId $Id).json"
                $script:ClaudeRegistrationPaths[$Id] = $registration
            }
            $stamp = [IO.File]::GetLastWriteTimeUtc($registration).Ticks
            if (-not $script:DaemonRegistrationStamps.ContainsKey($Id) -or $script:DaemonRegistrationStamps[$Id] -ne $stamp) {
                $script:DaemonRegistrationStamps[$Id] = $stamp
                try {
                    $fresh = Get-Content -LiteralPath $registration -Raw | ConvertFrom-Json
                    foreach ($field in @('HookStatus', 'HookStatusAt')) {
                        if ($fresh.PSObject.Properties[$field]) {
                            $Session | Add-Member -NotePropertyName $field -NotePropertyValue ([string]$fresh.$field) -Force
                        }
                    }
                    $changed = $true
                }
                catch { }
            }
            $changed
        }
        # Judged by the marker's own question, not whichever one the transcript shows last.
        AskUserState = {
            param($Session, $Marker)
            if (-not $script:ClaudeAdapterLoaded) { return Get-CopilotAskUserState -TranscriptPath ([string]$Session.Transcript) }
            $toolCallId = ''
            $since = $null
            if ($null -ne $Marker) {
                if ($Marker.PSObject.Properties['toolCallId']) { $toolCallId = [string]$Marker.toolCallId }
                if ($Marker.PSObject.Properties['armedAt']) { $since = [string]$Marker.armedAt }
            }
            Get-ClaudeAskUserState -TranscriptPath ([string]$Session.Transcript) -ToolCallId $toolCallId -Since $since
        }
        AdapterInstalled = { Test-Path -LiteralPath (Join-Path $HOME '.claude\ha-bridge\claude-session.ps1') }
        HookStatus = $true
        InlineReasoning = $true
        KnowsProcessId = $true
        TranscriptConfirmsInput = $true
    }

    codex = @{
        FindSessions = { Get-LiveCodexSessions }
        Display = {
            param($SessionId, $WorkingDirectory)
            if (-not $script:CodexAdapterLoaded) { return Get-CopilotSessionDisplay -SessionId $SessionId -WorkingDirectory $WorkingDirectory }
            Get-CodexSessionDisplay -SessionId $SessionId -WorkingDirectory $WorkingDirectory
        }
        KnowsProcessId = $true
        AdapterInstalled = { Test-Path -LiteralPath (Join-Path $HOME '.agent-ha-bridge\codex-bridge\plugins\agent-ha-bridge\hooks\codex-session.ps1') }
        # Codex asks, inside Codex, for its hooks to be trusted once; that is left to the user.
        SetupNote = { ' Open Codex once and approve the agent-ha-bridge hooks so its sessions show here.' }
        ApprovalMarker = {
            param($SessionId, [bool]$RequireReadable = $false)
            if (-not $script:CodexAdapterLoaded) {
                if ($RequireReadable) { throw 'Codex approval state reader is unavailable.' }
                return $null
            }
            if ($RequireReadable) { return Get-CodexApprovalMarker -SessionId $SessionId -RequireReadable }
            Get-CodexApprovalMarker -SessionId $SessionId
        }
        # Codex reports its own status: a turn begins at UserPromptSubmit and ends at
        # Stop, both of which the hook records, so there is nothing to infer.
        IsWorking = { param($SessionId, $Transcript, $Status) $Status -eq 'working' }
        # What it says comes from its rollout, and its status from the registration its
        # hooks write - published here, so a hook on every tool call does not wait on
        # Home Assistant (Sync-DaemonCodexHookStatus).
        FastActivity = {
            param($Id, $Entry, $Session, $Headers)
            $republish = Sync-DaemonCodexHookStatus -Id $Id -Entry $Entry -Headers $Headers
            $length = 0L
            try { $length = [IO.FileInfo]::new([string]$Session.Transcript).Length } catch { }
            if ($republish -or ($length -gt 0 -and $length -ne [long]$Entry.Offset)) {
                Update-DaemonCodexActivity -Id $Id -Entry $Entry -Session $Session -Headers $Headers `
                    -VerboseOn ([bool]$script:DaemonVerbose) -Republish:$republish
            }
        }
        # Codex publishes its status from its hooks; what it says - progress notes, the
        # answer, reasoning, tool calls - is read from its rollout (Update-DaemonCodexActivity).
        KnownActivity = {
            param($Id, $Entry, $Session, $Headers, $VerboseOn)
            Update-DaemonCodexActivity -Id $Id -Entry $Entry -Session $Session -Headers $Headers -VerboseOn $VerboseOn
        }
    }
}

$script:DaemonAgentCache = @{}
$script:ClaudeRegistrationPaths = @{}

function Get-DaemonAgent {
    <# The entry for a kind of session, with Copilot's slots filling any it leaves out. #>
    param([AllowEmptyString()][AllowNull()][string]$Kind)

    if (-not $Kind) { $Kind = 'copilot' }
    # Resolved once per kind: the fast lane asks for every session ten times a second.
    $cached = $script:DaemonAgentCache[$Kind]
    if ($null -ne $cached) { return $cached }

    # An unlisted kind (an MCP client's, say) gets Copilot's slots but none of its
    # flags: the old checks named Copilot for those.
    $default = $script:DaemonAgents['copilot']
    $own =if ($script:DaemonAgents.Contains($Kind)) { $script:DaemonAgents[$Kind] } else { @{} }
    # Every slot and flag is present, so callers can test one under strict mode.
    $agent = @{
        FindSessions = $null; PollRegistration = $null; FastActivity = $null; KnownActivity = $null; ApprovalMarker = $null
        AdapterInstalled = $null; Installer = $null; SetupNote = $null
        HookStatus = $false; InlineReasoning = $false; RefreshName = $false; KnowsProcessId = $false; TranscriptConfirmsInput = $false
    }
    foreach ($slot in 'Display', 'ReadAppend', 'Activity', 'IsWorking', 'AskUserState') { $agent[$slot] = $default[$slot] }
    foreach ($slot in $own.Keys) { $agent[$slot] = $own[$slot] }
    $script:DaemonAgentCache[$Kind] = $agent
    $agent
}

function Get-DaemonEntryKind {
    <# A state entry's or live session's kind; one recorded before kinds existed is Copilot's. #>
    param($Entry)
    if ($null -ne $Entry -and $Entry.PSObject.Properties['Kind'] -and $Entry.Kind) { return [string]$Entry.Kind }
    'copilot'
}
