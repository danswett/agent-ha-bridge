# Fast hooks

The agents wait for every hook. Each hook is a PowerShell script, and PowerShell
takes about 225 ms just to start on DASDESK, then loads 3,000 to 5,500 lines of
shared code. Measured 2026-09-27 (median of 3, fresh process each):

| Hook | Now |
|---|---|
| Claude UserPromptSubmit | 450 ms |
| Claude Stop | 698 ms |
| Codex PreToolUse (every tool call) | 545 ms |
| Bare `pwsh` start | 225-265 ms |
| Bare native process | 20 ms |

Goal: every hook the agent waits for under 60 ms, with no change to what the bridge
does.

## What the hooks do today

Every hook, for all three agents, has the same shape (read 2026-09-27):

* It never blocks and never changes what the agent does. Its stdout is fixed:
  nothing (Claude, Codex), `{}` (Copilot agentStop / notification) or
  `{"permissionDecision":"allow"}` (Copilot ask_user).
* It records local state: a session registration (Claude, Codex) and, for a
  question or approval, a pending-decision marker the daemon acts on.
* It publishes to Home Assistant: status, the decision card, push notifications.
  This is the slow part, and the daemon already has all of this code.
* It fails open: any error exits 0 with the fixed output.

| Agent | Script | Events |
|---|---|---|
| Claude | `claude/hooks/register-claude-session.ps1` | SessionStart, UserPromptSubmit |
| Claude | `claude/hooks/notify-claude-stop.ps1` | Stop |
| Claude | `claude/hooks/route-askuserquestion.ps1` | PreToolUse (AskUserQuestion) |
| Claude | `claude/hooks/route-notification.ps1` | Notification |
| Codex | `codex/hooks/codex-bridge-hook.ps1` | all five, one script |
| Copilot | `hooks/route-ask-user-v3.ps1` | preToolUse (ask_user) |
| Copilot | `hooks/notify-agent-response.ps1` | agentStop |
| Copilot | `hooks/notify-home-assistant.ps1` | notification (permission_prompt) |

The one thing only the hook process can know is its own process ancestry, which is
how the owning agent process (the window replies are typed into) is found.

## Design: a thin native hook, the daemon does the work

A small Go program, `agent-bridge-hook`, replaces the PowerShell entry point:

1. Reads the event from stdin.
2. Records its ancestor process ids (up to 12), while they are certain to be alive.
3. If the daemon is alive (heartbeat under 60 s old, as `Test-BridgeDaemonAlive`),
   writes `{agent, script, ancestors, receivedAt, event}` to the spool folder
   (`%TEMP%/agent-bridge-spool`, written to a temp name then renamed so the daemon
   never reads half a file), prints the fixed output and exits 0.
4. If the daemon is not alive, runs the existing PowerShell hook with the same
   stdin, exactly as today. Slow, but correct, and it keeps the bridge working
   without its daemon.
5. Anything unexpected: print the fixed output, exit 0.

The daemon drains the spool on every fast-lane tick (100 ms), in file-name order,
and runs each event through the same PowerShell code the hook script runs. To make
that true, each hook script's body becomes a function (for example
`Invoke-ClaudeStopHook -Event -Ancestors`) in its adapter library; the script is a
thin wrapper that calls it. The owning process is chosen from the recorded
ancestors with the existing `Test-BridgeAgentProcess`, so no process detection is
ported to Go.

Why not port the hooks to Go outright: they load 3,000 to 5,500 lines of Home
Assistant, MQTT and question-parsing code. A second implementation would drift.

## Distribution

Updates download the release's source archive, which cannot carry a compiled
program. So:

* CI builds `agent-bridge-hook` for windows-amd64, windows-arm64, darwin-amd64 and
  darwin-arm64 and attaches them to each GitHub release as assets.
* Install and update download the asset for the machine (checksum-verified against
  a `SHA256SUMS` asset) into `~/.agent-ha-bridge/bin`.
* Agent hook configs point at the binary only when it is present and runs
  (`agent-bridge-hook --version`); otherwise they keep the PowerShell hooks. A
  machine that cannot get the binary behaves exactly as today.

## Risks

* **Codex re-trust.** Codex asks for each hook command to be trusted. Changing the
  command will likely ask again once. The launch note and release notes must say so.
* **Copilot** runs its hook command through PowerShell (`"powershell": "& '...'"`),
  which would keep the startup cost. Find out whether its config accepts a plain
  command; if not, Copilot stays on PowerShell hooks. Claude and Codex are the ones
  that matter here.
* **Antivirus.** Unsigned Go binaries are sometimes flagged by Defender. Watch for it;
  the PowerShell fallback covers a blocked binary.
* **Ordering.** A registration now lands up to 100 ms after the hook instead of
  during it. `Test-BridgeSessionRegistered` and the Claude status handling must
  tolerate that. Spool files are processed in order, so events for one session
  stay in order.

## Phases (one commit each; tick here in the same commit)

- [ ] **0. Toolchain.** Go installed on DASDESK (`winget install GoLang.Go`); CI
  job that builds and tests the Go code on Windows and macOS.
- [ ] **1. Hook bodies into functions.** Each hook script's body moves into a
  function taking `-Event` and `-Ancestors`; the script calls it with its own
  ancestry. No behaviour change. Tests call the functions with the existing
  fixtures (`claude/fixtures`, `codex/fixtures`).
- [ ] **2. Daemon spool.** New part `hooks/daemon-hookspool.ps1`: drain the spool on
  the fast-lane tick, dispatch by `agent`/`script`, delete each file after (and a
  file that fails twice, logged). Tests drop fixture events into a temp spool.
- [ ] **3. The Go hook.** `hook/` (Go module): stdin, ancestry (Windows: toolhelp
  snapshot; macOS: `sysctl kern.proc.pid`), daemon-alive check, spool write,
  fallback exec, fixed output per script. Go tests. Timed against the table above.
- [ ] **4. Distribution.** Release assets + checksums from CI; install and update
  fetch them; hook configs switch to the binary when it works.
- [ ] **5. Wire Claude and Codex.** Settings/hooks point at the binary; measure;
  release.
- [ ] **6. Copilot**, if its hook config can run a plain command.

## Resuming

Read this file, then `git log --oneline -10`. The first unticked phase is next. A
half-done phase is never committed, so `git status` shows any work in progress.
