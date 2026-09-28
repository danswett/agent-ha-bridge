# Splitting the daemon

`hooks/agent-bridge-daemon.ps1` is one 4,691-line script: 67 functions sharing
script-scope state. It works and is well covered by tests, but it is harder to
change safely than it should be. Five functions are a third of it:

| Function | Lines | What it does |
|---|---|---|
| `Sync-DaemonSessions` | 428 | adopts new sessions, retires ended ones, rebuilds the dashboard, streams activity |
| `Sync-DaemonNewSession` | 338 | the launch card: publishing its controls, reading a press, launching or resuming |
| `Invoke-PendingDecisions` | 285 | arming and answering question cards |
| `Start-BridgeDaemon` | 283 | startup and the main loop |
| `Invoke-PendingReplies` | 245 | delivering dashboard replies |

The plan has three steps, each shipped and tested on its own.

## Step 1 - move code, change nothing

`agent-bridge-daemon.ps1` becomes a short loader: its header, configuration and
shared state, then it dot-sources the parts, then (as now) starts the loop unless
`AGENT_BRIDGE_DAEMON_NORUN` is set.

| File | Responsibility | Functions |
|---|---|---|
| `agent-bridge-daemon.ps1` | entry point, configuration, logging, state file, main loop | `Write-DaemonLog`, `Read-DaemonStateFile`, `Read-DaemonState`, `Write-DaemonState`, `Test-VerboseStreaming`, `Set-DaemonSessionProperty`, `Start-BridgeDaemon` |
| `daemon-discovery.ps1` | which sessions are live | `Get-LiveCopilotSessions`, `Get-LiveCodexSessions`, `Get-DaemonHomeAssistantStates`, `Get-DaemonPeerMachines`, `Get-LiveMcpSessions`, `Get-LiveBridgeSessions`, `Get-LiveClaudeSessions`, `Get-BridgeSessionDisplay`, `Get-DaemonSessionProcessId` |
| `daemon-activity.ps1` | what a session is doing, onto its card | `Format-CardText`, `Read-BridgeTranscriptAppend`, `Get-BridgeActivity`, `Test-BridgeSessionWorking`, `Sync-DaemonHookStatus`, `Get-DaemonStartupStatus`, `Read-TranscriptAppend`, `Get-ActivityFromEvents`, `Set-DaemonTransientActivity`, `Update-DaemonSessionActivity`, `Sync-DaemonCodexHookStatus`, `Update-DaemonCodexActivity`, `Add-DaemonCardText`, `Invoke-DaemonFastActivity` |
| `daemon-sessions.ps1` | card lifecycle | `Sync-DaemonSessions`, `Update-DaemonRetireQueue`, `Repair-CopilotSessionEntities`, `Clear-CopilotMqttOrphans`, `Invoke-DaemonLegacyCleanup`, `Invoke-DaemonUnscopedEntityCleanup` |
| `daemon-replies.ps1` | dashboard to agent text | `Get-BridgeAttachmentRoot`, `Get-BridgeReplyPayload`, `New-BridgeAttachmentPrompt`, `Save-BridgeReplyAttachment`, `Remove-BridgeHomeAssistantImage`, `Remove-BridgeStaleAttachment`, `Invoke-PendingReplies`, `Invoke-DaemonReply`, `Test-DaemonClaudePromptSubmitted`, `Confirm-DaemonClaudeSubmit`, `Resolve-SessionFromReplyEntity`, `Resolve-DaemonPrimedCard` |
| `daemon-decisions.ps1` | questions and approvals | `Invoke-PendingDecisions`, `Get-DaemonAskUserState`, `Complete-DaemonClaudeAnswer`, `Invoke-DaemonDecisionAnswer`, `Get-DaemonAnswerCorrection`, `Invoke-PendingCodexApprovals` |
| `daemon-launch.ps1` | starting and ending sessions | `Get-DaemonResumableSessions`, `Set-DaemonNewSessionDefaults`, `Sync-DaemonNewSession`, `Update-DaemonPendingLaunch`, `Test-DaemonLaunchProgressNote`, `Clear-DaemonStaleNote`, `Invoke-PendingStops` |
| `daemon-maintenance.ps1` | keeping the install current | `Invoke-DaemonUpdateOutcome`, `Sync-DaemonUpdateStatus`, `Get-DaemonClientAdapterInstalled`, `Get-DaemonClientInstaller`, `Add-DaemonConfiguredClient`, `Sync-DaemonClients` |

Rules for the move:

* Function bodies move byte for byte; nothing is renamed or reformatted.
* Shared state (`$script:Daemon*`) stays declared in the loader, before the parts
  load. Parts are dot-sourced into the loader's scope, so `$script:` still means
  the one shared scope and every function sees the same variables.
* Each part starts with a comment saying what it is responsible for and which shared
  variables it changes.
* The uninstaller removes hook files from a fixed list: the new files go on it.
  The installer and the update payload copy the whole `hooks` folder already.
* Tests keep dot-sourcing `agent-bridge-daemon.ps1` and need no change.

Done when: the full suite passes on Windows and macOS, the linter is clean, the
daemon runs on a real install, and a script check confirms every function that
existed before still exists exactly once, with an identical body.

## Step 2 - break up the five large functions

Along the seams they already have, each piece testable on its own:

* `Sync-DaemonSessions` -> adopt new sessions, retire ended ones, publish the
  dashboard, stream activity.
* `Sync-DaemonNewSession` -> publish the controls, read a press, the trust and
  first-message follow-ups, launch or resume.
* `Invoke-PendingDecisions` -> arm new questions, read answers, deliver, clear.
* `Invoke-PendingReplies` -> read the payload, resolve the session, deliver, confirm.
* `Start-BridgeDaemon` -> startup, then a plain list of reconcile steps and the hit
  dispatch table instead of inline code.

One function per commit, with the suite run each time.

## Step 3 - one place per agent

"If Codex, else Claude, else Copilot" is scattered across discovery, activity,
replies and the fast lane, which is why adding Codex touched so many places. A small
table per agent - how to find its sessions, read its activity, find its process,
confirm a reply - lets the shared code call through it. The next agent is then one
table rather than edits in six files.
