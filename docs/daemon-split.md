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
| `daemon-discovery.ps1` | which sessions are live | `Get-LiveCopilotSessions`, `New-DaemonCopilotSession`, `Get-LiveCodexSessions`, `Get-DaemonHomeAssistantStates`, `Get-DaemonPeerMachines`, `Get-LiveMcpSessions`, `Get-LiveBridgeSessions`, `Get-LiveClaudeSessions`, `Get-BridgeSessionDisplay`, `Get-DaemonSessionProcessId` |
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

**Status: done** (last commit `0396d87`). New tests: `test-daemon-sessions.ps1`,
`test-daemon-decisions.ps1`, `test-daemon-replies.ps1`, `test-daemon-loop.ps1`.

## Step 3 - one place per agent

"If Codex, else Claude, else Copilot" is scattered across discovery, activity,
replies and the fast lane, which is why adding Codex touched so many places. A small
table per agent - how to find its sessions, read its activity, find its process,
confirm a reply - lets the shared code call through it. The next agent is then one
table rather than edits in six files.

About 37 branches in 9 files. Copilot is often not named: it is whatever is left
after the Claude and Codex checks, so the table has to name it outright.

### Design

* New part `hooks/daemon-agents.ps1`, dot-sourced first. It holds
  `$script:DaemonAgents`: an ordered table keyed by kind (`copilot`, `claude`,
  `codex`), each entry a hashtable of script blocks and flags.
* `Get-DaemonAgent -Kind` returns an entry; a blank or unknown kind gets
  `copilot`, as the old `else` did. `Get-DaemonEntryKind -Entry` replaces the
  repeated `if ($entry.Kind) ... else 'copilot'`.
* Behaviour is kept exactly, including a missing adapter: an entry's script block
  checks `$script:ClaudeAdapterLoaded` / `$script:CodexAdapterLoaded` itself and
  falls back the way the old branch did. No behaviour change in this step.
* Shared code calls `& $agent.ReadAppend ...`, or tests a flag. An agent without
  a slot gets the shared default.

### Phases (one commit each; tick here in the same commit)

- [x] **A. Activity** (`daemon-activity.ps1`, `Update-DaemonKnownSession` in
  `daemon-sessions.ps1`). Slots: `ReadAppend`, `Activity`, `IsWorking`,
  `PollRegistration` (Claude's hook-status watch in the fast lane),
  `FastActivity` / `KnownActivity` (Codex streams its own card), flags
  `HookStatus`, `InlineReasoning`, `RefreshName` (Copilot). Test:
  `tests/test-daemon-agents.ps1`. *Done.* Gotchas: `Get-DaemonAgent` must return every
  slot and flag (strict mode throws on a missing hashtable key); an unlisted kind
  (`mcp`) gets Copilot's slots but no flags, since the old checks named Copilot.
- [x] **B. Discovery** (`daemon-discovery.ps1`). Slots: `FindSessions`,
  `Display`; flag `KnowsProcessId`. `Get-LiveBridgeSessions` loops the table.
  *Done.* Tests in `test-daemon-agents.ps1` stub `Get-BridgeSessionDisplay` for the
  reconcile checks, so the display checks ask the table directly.
- [x] **C. Decisions and replies**. Claude's question parser, Codex approvals,
  Claude's reply confirmation. *Done.* Slots `AskUserState`
  (inherited), `ApprovalMarker`; flag `TranscriptConfirmsInput` (replies and answers).
  `Invoke-DaemonReply`'s fallback process scan loops agents with `KnowsProcessId`.
  `Invoke-PendingCodexApprovals` keeps its name but serves any agent with an
  `ApprovalMarker`.
- [x] **D. Launch** (`session-launch.ps1`, `daemon-launch.ps1`). Arguments,
  resume, transcript location, Codex's first prompt.
  Design (decided mid-phase): launchers are not session kinds (Agency launches
  Copilot sessions), and `session-launch.ps1` loads without the daemon
  (`test-platform.ps1`). So D adds `$script:BridgeLaunchers` inside
  `session-launch.ps1`: one entry per launcher (agency, copilot, claude, codex) with
  its label, path, arguments, resumable sessions, registration check and flags
  (`ChoosesOwnSessionId`, `NeedsFirstMessage`, `AnswersTrustPrompt`) and the
  session `Kind` it produces. A new agent is then one launcher entry plus one agent
  entry. `daemon-launch.ps1` reads the flags via `Get-BridgeLauncher`.
  *Done.* The `Kind` field is used for the resumable list's labels. Gotchas: the
  resumable read order is its own slot (`ResumeOrder`: Claude, Codex, Agency,
  Copilot) because the first source to list a session wins, and Agency lists Claude
  sessions too; `@($null).Count` is 1, so test `ContainsKey` first. Launch notes are
  recognised by shape, not agent name (`Test-DaemonLaunchProgressNote`). All 768
  argument combinations were diffed against 1.11.0: identical. Test:
  `tests/test-launchers.ps1`.
- [x] **E. Maintenance**. Install notes per client. *Done.* Agent slots
  `AdapterInstalled`, `Installer` (Copilot's; others use `<kind>\install-<kind>.ps1`)
  and `SetupNote`; `Sync-DaemonClients` loops the agents that have an adapter.

**Step 3 status: done.** Adding an agent now means one entry in `daemon-agents.ps1`,
one in `BridgeLaunchers` (`session-launch.ps1`), one in `BridgeLauncherTuning` beside
it - the models, efforts and context sizes it accepts, and how each is spelled on its
command line - and its adapter. Still named per agent, by design: the adapter loading
at the top of `agent-bridge-daemon.ps1` (runs before the parts load), Agency's
profiles, and comments describing today's agents.

C to E are optional: A and B are the code that runs constantly. The user approved
C to E on 2026-09-27; carry on through them without asking.

After A and B a benchmark found the fast lane 25% slower (a fresh agent hashtable per
session per tick); `526a316` caches agents and Claude's registration path, making a
tick 20% faster than 1.11.0. Anything on the fast lane path must stay allocation-free:
use `Get-DaemonAgent` (cached), never build an entry inline.

### Resuming

Read this section, then `git log --oneline -8`. The first unticked phase is next.
A half-done phase is never committed, so `git status` shows any work in progress:
finish it or `git checkout` it.