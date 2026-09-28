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

## Why Go

Checked with the user before starting (2026-09-27). The native part is small: read
stdin, record ancestors, check the heartbeat, write a file or run the old hook.

* Startup does not decide it: Go, Rust and C# Native AOT all start in a few ms, well
  under Windows' ~20 ms process-creation floor. Node measured 58 ms and needs Node.
* Go builds all four targets from any one machine with no C toolchain, so DASDESK
  and one CI job can produce them. Rust and C# AOT need a Mac to build for Macs, and
  C# AOT needs the MSVC C++ build tools, which DASDESK does not have.
* C# would suit a future port of the whole daemon (the repo already has C#, and
  PowerShell maps onto it closely). The hook is about 300 lines, so rewriting it
  then is cheap; it does not justify the toolchain now.
* Go's known risk: Defender sometimes flags unsigned Go binaries. Hook configs only
  point at the binary once it has been seen to run, and phase 0 scans it.

Phase 0 gate: a built Go binary must start in under 30 ms on DASDESK and scan clean
with Defender. If either fails, stop and revisit the choice with the user.

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

- [x] **0. Toolchain.** Go installed on DASDESK (`winget install GoLang.Go`); CI
  job that builds and tests the Go code on Windows and macOS.
  *Done* (the CI job moved into phase 3, with the first Go code). The machine-wide
  winget install waited on a UAC prompt, so Go 1.27.1 is the portable zip (sha256
  checked) in `%LOCALAPPDATA%\Programs\go`; use `%LOCALAPPDATA%\Programs\go\bin\go.exe`
  if `go` is not on PATH. Gate passed 2026-09-27: a minimal Go program that reads and
  parses the event starts in 12.3 ms median (cmd.exe 14.3 ms, pwsh 234 ms), 2.6 MB, and
  Defender's scan found no threats.
- [x] **1. Hook bodies into functions.** Each hook script's body moves into a
  function taking `-Event` and `-Ancestors`; the script calls it with its own
  ancestry. No behaviour change. Tests call the functions with the existing
  fixtures (`claude/fixtures`, `codex/fixtures`).
  *Done.* `claude/hooks/claude-hooks.ps1` (Invoke-ClaudeRegisterHook, -StopHook, -AskHook,
  -NotificationHook), `codex/hooks/codex-hooks.ps1` (Invoke-CodexHook),
  `hooks/copilot-hooks.ps1` (Invoke-CopilotAskUserHook, -AgentStopHook, -PermissionHook).
  `Find-BridgeAgentAncestor` and `Get-CodexOwningProcessId` take `-Ancestors` (nearest
  first; exited pids skipped). Test: `tests/test-hook-functions.ps1`. Found on the way,
  and binding on phase 2:
  * Pass `-Ancestors` only when there is a chain: an older `bridge-platform.ps1`
    (mid-update, or a checkout against an older install) rejects the parameter, and a
    fail-open hook then silently loses its process.
  * Fail-open hides errors. Check `%TEMP%\agent-decision-bridge.log` for `failed`,
    not just exit code and stdout.
  * The hooks run without strict mode and the shared ask_user parser relies on it:
    the daemon's dispatch must `Set-StrictMode -Off` around each hook function.
  * `Enter-BridgeAdapterSession` sets a 45 s deadline on every HTTP call in the
    process (`Set-DecisionBridgeDeadline`). In the daemon that would break all later
    requests: save and restore `$script:DecisionBridgeDeadline` around each event.
- [x] **2. Daemon spool.** New part `hooks/daemon-hookspool.ps1`: drain the spool on
  the fast-lane tick, dispatch by `agent`/`script`, delete each file after (and a
  file that fails twice, logged). Tests drop fixture events into a temp spool.
  *Done.* `hooks/daemon-hookspool.ps1`; the daemon also loads `bridge-adapter.ps1`,
  `copilot-hooks.ps1` and each adapter's hook file (guarded, so an older adapter still
  loads). Test: `tests/test-hook-spool.ps1`. Live: a spooled SessionStart became a
  registration 88 ms after the rename. Notes:
  * The daemon already runs under strict mode (the Claude and Codex adapters set it
    when loaded), so each handler runs in its script's own mode: Claude and Codex
    strict, Copilot off.
  * Listing the folder each tick cost 60-100 us on Windows, more than an idle tick.
    A FileSystemWatcher queues events (no -Action) and the tick reads the queue's
    count; a sweep every 2 s is the backstop (macOS delivers events later).
  * Cost: an idle fast-lane tick is ~30 us slower than 1.11.1 (340 -> 369 us, median
    of 5). Accepted: it buys 400-650 ms off every hook.
- [x] **3. The Go hook.** `hook/` (Go module): stdin, ancestry (Windows: toolhelp
  snapshot; macOS: `sysctl kern.proc.pid`), daemon-alive check, spool write,
  fallback exec, fixed output per script. Go tests. Timed against the table above.
  *Done.* `hook/` (module `github.com/danswett/agent-ha-bridge/hook`, needs
  `golang.org/x/sys`): `agent-bridge-hook <agent> <hook> [fallback-script]`; hooks
  are claude/register, claude/stop, claude/ask, claude/notification, codex/hook,
  copilot/ask_user, copilot/agent_stop, copilot/permission. `--version` prints the
  version (`-ldflags -X main.version=`). CI vets, tests and builds all four targets
  on Windows and macOS. End to end (`tests/test-native-hook.ps1`, real binary + the
  daemon's spool code): the agent waits 37 ms median, against 450 ms for the
  PowerShell hook. Found on the way: a fallback that fails to run had pwsh print its
  error to stdout ahead of Copilot's reply; the fallback's output is now buffered and
  passed on only when it succeeded.
- [x] **4. Distribution.** Release assets + checksums from CI; install and update
  fetch them; hook configs switch to the binary when it works.
  *Done,* except the config switch, which is phase 5. `.github/workflows/release.yml`
  builds the four targets on a published release (version stamped from the tag) and
  uploads them with `SHA256SUMS`; it also runs by hand for a tag. **It has not run
  yet: check it on the first release that carries `hook/`.** `hooks/bridge-native-hook.ps1`
  (`Install-BridgeNativeHook`, `Get-BridgeNativeHookPath`) is used by install.ps1 before
  the adapters are configured: a checkout's local build wins, otherwise the release
  build, checksum-checked and seen to run. Test: `tests/test-native-hook-install.ps1`.
  On DASDESK it is installed from the local build (`--version` says `dev`). Gotchas:
  a staged copy must keep `.exe` or Windows will not run it to check it; and in tests,
  never name a variable `` or `` - Test-That's own parameters shadow them
  inside a check (caught three times).
- [x] **5. Wire Claude and Codex.** Settings/hooks point at the binary; measure;
  release.
  *Done on DASDESK; release pending the user's go-ahead.* `install-claude.ps1` and
  `install-codex.ps1` write `<agent-bridge-hook> <agent> <hook> <script>` when
  `Get-BridgeNativeHookPath` finds a working program (Codex only from a path with no
  space: it cannot quote). Measured 2026-09-27, the installed commands run as the agent
  runs them, median of 7: Claude UserPromptSubmit 608 -> 82 ms, Claude Stop 777 -> 80 ms
  (both include ~40 ms of Git Bash, which Claude Code always uses on Windows), Codex
  PreToolUse 553 -> 38 ms. Claude Code reads hooks at start, so running sessions keep the
  old commands until restarted; Codex asks to trust the changed hook once. The previous
  Claude settings on DASDESK are in `~/.claude/settings.json.pre-native-hook`.
- [x] **6. Copilot (and Agency, which runs Copilot and uses its hooks).** Found
  2026-09-27: Copilot CLI hooks accept `exec` + `args` to run a program with no shell
  (docs.github.com/en/copilot/reference/hooks-reference), e.g.
  `{ "type": "command", "exec": "<agent-bridge-hook>", "args": ["copilot", "ask_user",
  "<route-ask-user-v3.ps1>"], "timeoutSec": 120 }`. `exec` must not be combined with
  `powershell`, and no minimum version is documented; preToolUse hooks are fail-closed
  on a crash or non-zero exit. Plan: confirm on DASDESK's Copilot 1.0.88 with a
  throwaway sessionStart hook (no prompt sent), then have install.ps1 write `exec` only
  for a Copilot at or above the confirmed version, keeping the PowerShell entries
  otherwise. *Done.* Probed 2026-09-27 with the user's OK: a throwaway hook file in
  `~/.copilot/hooks` using `exec` ran for sessionStart and agentStop and got the event on
  stdin (hooks fire only once a prompt is sent: `copilot` started with no prompt ran
  none, even the `powershell` control). install.ps1 now installs the native hook before
  writing Copilot's hooks and, with Copilot >= 1.0.88 (`Test-BridgeCopilotRunsExec`),
  writes them as `exec`/`args` (`ConvertTo-BridgeCopilotExecHook`). Live: a real
  Copilot turn's agentStop went through the spool. Measured: 398 -> 43 ms. Agency
  (not on DASDESK) uses the same hook file; if it bundles a Copilot older than 1.0.88,
  the version check cannot see that - watch for it on the first Agency machine.
  DASDESK's previous file: `~/.copilot/hooks/decision-notifier.json.pre-native-hook.bak`.

## Before releasing (1.12.0)

- [ ] **R1. No release race.** The release workflow built only after publishing, so a
  machine updating in that minute got no native hook and stayed on PowerShell hooks.
  Now: create the release as a draft, run the workflow for its tag, check the assets,
  then publish (automatic updates never see drafts).
- [ ] **R2. Build the release assets in CI on every push** (no upload), so a broken
  release build shows up before a release.
- [ ] **R3. test-claude-install.ps1 in a sandbox TEMP**: it registered a fake session in
  the real %TEMP% owned by the Claude running the tests, which the daemon adopted.
- [ ] **R4. README and release notes**: Codex asks to trust its hook again once; running
  Claude sessions pick up new hooks on restart.
- [ ] **R5. DASDESK leftovers**: the portable Go (the user approved the machine-wide one),
  its zip, and test folders in %TEMP%. Keep the settings backups for now.
- [ ] **R6. test-dashboard.ps1 writes into the real bridge log**; point it at a temp log.
- [ ] **R7. VERSION 1.12.0, release, verify the assets attached.**

## Resuming

Read this file, then `git log --oneline -10`. The first unticked phase is next. A
half-done phase is never committed, so `git status` shows any work in progress.
