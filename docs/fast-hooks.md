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
  winget install waited on a UAC prompt, so Go was first the portable zip; once the user approved the prompt, Go 1.27.0 is
  machine-wide (`C:\Program Files\Go`) and the portable copy was removed. `hook/go.mod`
  asks for 1.27.0. Gate passed 2026-09-27: a minimal Go program that reads and
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
  PreToolUse 553 -> 38 ms. Claude Code picks the changed hooks up in running sessions (seen
  2026-09-28: this session's hooks ran natively without a restart); Codex asks to trust the changed hook once. The previous
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

- [x] **R1. No release race.** The release workflow built only after publishing, so a
  machine updating in that minute got no native hook and stayed on PowerShell hooks.
  Now: create the release as a draft, run the workflow for its tag, check the assets,
  then publish (automatic updates never see drafts). *Done:* release.yml runs only by
  hand (`tag` + `ref`), and `hook/build-release.sh` is the one build both use.
- [x] **R2. Build the release assets in CI on every push** (no upload), so a broken
  release build shows up before a release.
- [x] **R3. test-claude-install.ps1 in a sandbox TEMP**: it registered a fake session in
  the real %TEMP% owned by the Claude running the tests, which the daemon adopted.
- [x] **R4. README and release notes**: Codex asks to trust its hook again once; running
  Claude sessions pick up new hooks without a restart.
- [x] **R5. DASDESK leftovers**: the portable Go (the user approved the machine-wide one),
  its zip, and test folders in %TEMP%. Keep the settings backups for now.
- [x] **R6. test-dashboard.ps1 writes into the real bridge log**; point it at a temp log.
- [x] **R8. Measure fallbacks** (asked by the user). The native hook appends one line per
  run to `%TEMP%\agent-bridge-hook.log` (JSON: at, agent, hook, path = spool | fallback |
  reply, reason, ms), rotated at 1 MB; `Get-BridgeHookStats` summarises a window
  (total, fallback rate, by reason, median ms). Tests: Go per path, the end-to-end
  counts, the summary. *Done:* `agent-ha-bridge status` shows it (`hooks : native (v) - N
  runs in the last 24 h, M not spooled (x%): reasons; median ms`). A fallback whose script
  also failed is its own reason (`...; fallback failed`): the agent got no bridge at all.
- [x] **R7. VERSION 1.12.0, release, verify the assets attached.** *Released 2026-09-28*
  (https://github.com/danswett/agent-ha-bridge/releases/tag/v1.12.0), from a37acc6..a63a336.
  The Windows build was downloaded from the draft, checksum-checked, run (`1.12.0`) and
  scanned clean by Defender before publishing; after, Install-BridgeNativeHook fetched
  it from the public release, and DASDESK now runs the released build. Traps hit, for
  next time:
  * `gh release upload <tag>` cannot find a draft (a lookup by tag skips drafts);
    release.yml now attaches by release id.
  * Deleting a draft's tag (to move it) detaches the draft: its tag becomes
    `untagged-...`. PATCH `tag_name` back after re-pushing the tag.
  * The PAT had no Actions permission, so the workflow could not be started by hand;
    it now also runs on a pushed `v*` tag. The user added the permission afterwards, so
    `workflow_dispatch` (tag + ref) works for the next release.

## After release

- **1.12.1** (2026-09-28): a finished Claude turn showed `working` - the daemon could
  record the Stop a few ms before Claude wrote the final message (fixed: only a new user
  entry resumes work; `tests/test-turn-end.ps1`); the card spinner's ✳ drew as a green
  emoji on iOS (U+FE0E). Released with the intended process, first time: draft,
  `workflow_dispatch` (tag + ref), assets checked, publish.
- **1.12.2** (2026-09-28): after 1.12.0 changed the hook command, a Codex launched
  from the dashboard stopped at Codex's own "Hooks need review" and the card only said
  "has not registered"; launchers now have a `BlockingPrompt` the launch follow-up
  checks against the new window's screen (never its own), and the card says what to
  answer. Also the daemon's memory, 274 -> ~120 MB private: Home Assistant filters the
  states it reads (/api/template), the C# helpers are compiled once into cached DLLs,
  and DOTNET_GCConserveMemory=7 plus an occasional aggressive collection.
- **1.13.0** (2026-09-28): a real install on an Intel Mac, which failed at four
  separate points - `installer` rejects a downloaded package whose name has no `.pkg`
  on it; `grep -E` read the MacPorts asset pattern (`-13-Ventura.pkg`) as its own
  options; npm's global folder belongs to root under MacPorts, so the CLIs need
  elevation, with `node` kept on `PATH` for Claude Code's postinstall; and launchd
  refuses an entire job whose `StandardOutPath` is under `$TMPDIR`, its own
  per-session directory ("Bootstrap failed: 5"), so the log moved to
  `~/Library/Logs`. `PATH` also went to `~/.zprofile` only, which bash never reads.
  Also: choices are tappable rows, not a dropdown that ran off a phone screen (card
  1.13.0); Copilot's reasoning shows inline like Claude's; a renamed session renames
  its card and its device; a failed dashboard-card read during a Home Assistant
  restart is no longer cached for five minutes; and a launch note stops insisting the
  session never arrived once it has. The macOS CI job earned its keep - three of the
  four install bugs were Windows assumptions.
- **1.13.1** (2026-09-28): pressing Install on the update card put it on "Installing"
  and left it there, with nothing in the log. `Invoke-BridgeSelfUpdate` resolved pwsh
  with a bare `(Get-Command pwsh).Source`, which throws under StrictMode when the
  daemon's scheduled-task PATH has no PowerShell folder - after writing the staging
  folder and updater script, before launching anything. The caller then swallowed it
  in a `catch` written for a different case. pwsh is now resolved the way install.ps1
  already resolved it (`Get-BridgePwshPath`, moved into the platform layer), and an
  update that cannot start clears its own spinner, notifies and logs. Also: a
  half-installed agent CLI no longer counts as installed - npm links a package's
  command before its postinstall, so Claude Code's failed postinstall left `claude`
  on PATH doing nothing and a re-run skipped it; the CLIs must answer `--version`
  now, so re-running the installer repairs them. And a tmux pane that is gone before
  it can be read says which reason it was, instead of "its process could not be
  found".
- **1.13.2** (2026-09-28): with the failure finally logged, the real cause appeared -
  `$detached = @{ ... }` inside a function taking `[switch]$Detached`. Names are
  case-insensitive, so it assigned to the parameter and died converting a hashtable
  to a SwitchParameter. Only the dashboard button passes `-Detached`, which is why
  `agent-ha-bridge update` always worked and the button never had. Swept the codebase
  with the AST for locals differing only in case from a `[switch]` or `[scriptblock]`
  parameter; this was the only one. Also raised the native hook's latency check from
  100 ms to 500 ms, after the same CI runner measured 50, 109 and 131 ms on three
  consecutive runs of identical code.
- **1.13.3** (2026-09-28): a card sat on `idle` showing a line from mid-turn, with the
  turn's answer missing. `Get-ActivityFromEvents` read `data.reasoningText` directly;
  under StrictMode a missing property throws, and that read is inside a `catch` that
  drops the whole event silently. Copilot writes assistant messages in several shapes
  and only some carry it - 224 of 518 in one real session had none - so nearly half of
  everything said was discarded and the card kept the last message that happened to
  include thinking. A final answer is usually plain text, so it was the likeliest
  thing to vanish. Fields now go through `Get-BridgeEventField`. `Read-TranscriptAppend`
  compounded it by setting the offset to the file length while returning a line still
  being written: parsing threw into the same catch with the offset already past it, so
  the loss was permanent. It now withholds a partial trailing line and rewinds by its
  length, as the Codex reader always has.
- **1.14.0** (2026-09-28): cards now show a purple edge while an agent is driving the
  session rather than you - steady when idle, pulsing while it works, and back to the
  ordinary colours the moment you reply yourself or type in the session's own window.
  The account behind the Submit press is the only thing that can tell them apart,
  because the dashboard and the API are the same door, so it needs the agent to have
  its own login and its id in `homeAssistant.agentUserIds`; with none configured
  nothing is ever marked, deliberately. Reading that id off the token does not work
  and costs an afternoon to notice: a long-lived token's `iss` claim is the refresh
  token's id, in exactly the shape of a user id, and the comparison simply never
  matches. Also: the install ends by checking itself - daemon up, Home Assistant
  answering, each chosen CLI actually running, tmux present, command on PATH - and
  says so in green, rather than printing the same next steps whether or not any of it
  worked. `launchctl bootout` returns before launchd has unloaded, so registering the
  LaunchAgent printed "Bootstrap failed: 5: Input/output error" on installs that then
  worked; it now waits for the job to go and only speaks if the `load -w` fallback
  fails too. A launch waiting on Claude's "do you trust the files in this folder?" is
  no longer dropped at 90 seconds - that had stopped the window being read at all, so
  the flow written to answer that question had nothing to work with and pressing
  Launch again was the only way back. And an agent pressing Send with an empty box no
  longer arms a ten-minute "Waiting for your text": that benefit of the doubt is for a
  person, whose text is on screen but uncommitted, while a value set through the API
  commits at once, so an empty box really is empty.
- **1.14.1** (2026-09-28): 1.14.0's purple glow could not be seen, for two independent
  reasons. No update had ever refreshed the dashboard card: cards are delivered by
  `install.ps1`, gated on `$homeAssistantReady`, and a self-update runs the installer
  with `-SkipVerify`, which never sets it. A dashboard was serving card 1.13.0 while
  the machine reported itself fully up to date on 1.13.3 - so the glow was installed,
  published as an attribute, and had no code in the browser to draw it. This is not
  specific to the glow: any card change could ship and simply never appear, which is
  the part worth remembering. `-SkipVerify` means "do not fail the install on the
  check", not "do not talk to Home Assistant". Second, `TurnStarted` came only from
  the Claude and Codex reducers, so for a Copilot session the caller believed no turn
  ever began; that flag is what hands a session back to the person at the keyboard, so
  a card an agent had driven once kept its purple edge for the rest of the session, and
  the reasoning and history carried from the previous turn were never cleared either. A
  user message now starts a turn, and anything reasoned before it in the same batch
  belongs to the turn that ended, exactly as `claude-transcript.ps1` has always done it.
  Separately, publishing 1.14.0 exhausted GitHub's unauthenticated rate limit (60 an
  hour, per IP) and the 403s were cached exactly like a real reply, so `update` answered
  "already on 1.13.3" minutes after 1.14.0 went live, on every machine, for six hours.
  The cache now records whether GitHub was reached at all, separately from what it said,
  and an unreached check is believed for fifteen minutes; 404 still counts as reached,
  being an answer. A cache written before this has no `Reached` field and is read as it
  always was.
- **1.14.2** (2026-09-28): two more, both found by driving a real session from the
  dashboard rather than by reading code. A Claude session launched on the Mac ran,
  answered, and never got a card: `Get-Process -Name` is an exact match and
  `Get-BridgeAgentProcesses` asked only for `claude` and `node`, but Claude Code ships
  a Bun-compiled binary that calls itself **claude.exe on macOS** - `Get-Process` there
  returns literally `53859 claude.exe`. That set decides the liveness of every Claude
  registration, so an empty one marked every open session dead and
  `Get-LiveClaudeSessions` returned nothing. `bun` is now gathered too, for the same
  reason: the filter accepts a CLI running under it but one could never be a candidate.
  Separately, a Codex card could never glow, because Codex builds its own detail rather
  than using the shared path and simply never set `driver`; a missing driver reads as
  yours, so every Codex card was drawn as yours however it had been driven. The restart
  prime had the same gap.

  The lesson is in how both hid. `Test-BridgeAgentProcess` has stripped `.exe` since it
  was written and a test asserted it did - passing the whole time on a candidate the
  gatherer never handed it. The driver had a test for mapping a user id and a test for
  recording the press, and none for the value reaching the card. Both features were
  tested at their two ends and broken through the middle, which no amount of adding
  cases at either end would have caught. `tests/test-driver-card.ps1` and the new block
  in `test-platform.ps1` drive the real functions instead.

  Worth knowing before hunting a missing glow: it needs a token belonging to the
  *agent's* account. A person and an id in `agentUserIds` are only two of the three
  steps, and with the agent still pressing on your own token every press is correctly
  read as yours - the feature works and nothing ever lights up.
- **1.14.3** (2026-09-28): picking Approve or Deny on a Codex approval did nothing; the
  prompt had to be answered in the terminal every time. `Test-DaemonReplyBoxFree` looks
  for the `ask_user` marker to decide whether a question still owns the card, and a
  Codex approval arms the same selector through its `PermissionRequest` hook instead.
  So a live approval fell through to the staleness check below, which asks the
  transcript whether an `ask_user` is pending - for an approval there is none and never
  was, so it always answered no, read the card as a leftover and cleared it.
  `Invoke-PendingReplies` runs that for every live session on every reconcile, so this
  was not a race: armed at 15:51:45 with Approve/Deny/Cancel, back to a single `Idle`
  option by 15:51:48 while the card still read "Needs approval". A choice made in that
  window is sent against an option list that has just been emptied and Home Assistant
  rejects it, so the dropdown appeared to do nothing rather than failing visibly.
- **1.14.4** (2026-09-28): the purple edge had never appeared on any dashboard and could
  not have. `AgentBridgeSessionCard` draws the frame and reads the driver from the
  activity sensor's attributes; the view that builds it handed over `status` and
  `decision` and never `activity`. With no entity to look at, the card falls back to
  'human' - the deliberate safe default - so every session read as yours whatever the
  daemon published.
- **1.14.5** (2026-09-28): a question could not be answered from the dashboard at all.
  Every field chosen, Send pressed, nothing delivered and nothing logged. A question is
  answered through the entities - the daemon reads the free-text field from
  `text.<node>_reply` and waits for a press on `button.<node>_submit` newer than the
  moment the question was armed - and the custom reply card writes neither: its Send
  publishes an MQTT payload, which `Invoke-PendingReplies` deliberately ignores while a
  question owns the box. Its Send also returns early on an empty textarea, so a form
  whose only free-text field was optional could not be submitted at all. Nothing
  failed, so nothing was reported: the daemon log for 17:08:58 to 17:13:30 holds one
  line, the terminal answer being adopted. Latent for as long as the card has existed,
  and reachable only once the card was upgraded to a version the dashboard gates its
  own layout on, which swapped the entity pair for the card. The card stays for
  ordinary replies; while a question is armed the pair is shown, because that is what
  can answer one.

  **The shape all five share.** Every one sat in the wiring between two tested ends.
  `Test-BridgeAgentProcess` has stripped `.exe` since it was written and a test
  asserted it did - passing on a candidate the gatherer never handed it. The card's
  suite sets `status`, `activity` and `decision` by hand and passed all eight glow
  checks on a config the dashboard never produced. The driver had a test for mapping a
  user id and one for recording the press, and none for the value reaching the card.
  Adding cases at either end would not have caught any of them; each now has a test
  that follows the value the whole way and fails without its fix.
- **1.14.6** (2026-09-28): `newSession.allowAllTools` did not actually stop a launched
  Copilot session stopping for a prompt. Copilot's permissions are three independent
  axes - tools, paths and URLs - and `--allow-all-tools` grants only the first, so a
  session still halted the moment it wanted to read a file. That is the one prompt
  Copilot does not route to Home Assistant, so the session went dark on the dashboard
  with no way to answer it: exactly the deadlock the flag was turned on to avoid. Now
  `--allow-all`, which is the three together. The name of the config key is unchanged
  and still reads `allowAllTools`; it is the flag it sends that was too narrow. Claude
  (`--dangerously-skip-permissions`) and Codex (`--ask-for-approval never`) waive
  everything already, so Copilot was the only one with a half-open door.
- **1.15.0** (2026-09-28): a multi-field question is answered by tapping rows, not by
  filling in Home Assistant's native dropdowns - one labelled group per field, the
  picked option staying marked until Send. The dropdowns were bad in the two ways the
  rows were built to fix: a native select commits on blur, so an answer needed a tap
  away and then Send, and it sizes its menu to the longest option without wrapping, so
  sentence-length answers were cut off on a phone. The headings come from the decision
  entity's `field_<n>_label` attributes rather than the entity's own `friendly_name`,
  which Home Assistant builds from the device name plus the entity name and would have
  put the session's whole title in front of every field. Verified live: a form answered
  from the dashboard delivered `idx=3 of 4` intact, and an optional free-text field
  committed empty and was accepted. Two things came out of testing it rather than out
  of the feature. A test suite fired ten reads at the live instance with a placeholder
  token in seventy milliseconds and got the machine IP-banned, which is now impossible
  (`tests/test-http-guard.ps1`). And the answer-mismatch warning turns out to be a
  false alarm on any question built from value/label pairs - see below; the correction
  it injects tells the agent to disregard an answer that was right.

## Next: let a Copilot permission prompt be approved from Home Assistant

Do this before the choices card. A Copilot session that hits a permission prompt stalls
with no sign of it on the dashboard - the card reads `working / Running: powershell`
indefinitely, its decision selector sits on `Idle`, and the only way through is the
terminal. Three sessions were stuck like that at once on 2026-09-28 and the owner could
not see why from the dashboard, which defeats the point of having it on a phone.

Copilot has half the path already. `Invoke-CopilotPermissionHook`
(hooks/copilot-hooks.ps1, ~line 189) receives the `permission_prompt` notification and,
by its own docstring, is *purely informational*: it sends a notification and returns.
It writes no approval marker, so nothing arms a card.

Codex has the whole path and is the template. Its hook records a marker
(`Get-CodexApprovalMarker`), its agent definition exposes it as `ApprovalMarker`
(hooks/daemon-agents.ps1, ~line 161), and `Invoke-PendingCodexApprovals`
(hooks/daemon-decisions.ps1, ~line 520) arms Approve/Deny and types the answer into the
prompt. That last function is already generic - it looks the marker up by session kind
and does nothing for a kind that has none - so the daemon side needs no change beyond
Copilot gaining a marker. The default in `Get-DaemonAgent` is `ApprovalMarker = $null`,
which is exactly why Copilot is silently skipped today.

Two things to get right. The marker must be cleared when the prompt goes, or a stale one
keeps arming a card for a question nobody is being asked - Codex clears it on the next
hook event for that session. And check what Copilot's prompt actually accepts before
reusing Codex's `y`/`n`; see the delivery warning below, which applies here too.

**`newSession.allowAllTools` is now on, and that does not make this task redundant.**
It was turned on for both machines on 2026-09-28, so Copilot and Agency sessions
launched from the dashboard get `--allow-all` (all three permission axes - see 1.14.6,
where `--allow-all-tools` alone turned out to still stop for a file prompt) and do not
stop for a prompt. That covers sessions the *bridge* starts. It does nothing for a
session started by hand in a terminal, or for one whose permission mode is changed
mid-session, and those still go dark on the dashboard exactly as before. Routing the
prompt is still the fix; the flag just stops it being hit constantly in the meantime.

Worth knowing if injection is considered instead: typing `/allow-all` into a running
session only helps if it arrives *before* the session hits its first prompt. Tried live
on a session already waiting on one - the text goes to the approval dialog rather than
the prompt, and the session stayed on `Running: powershell` across eight samples. So
injection can prevent a deadlock and cannot undo one, which is why the launch flag is
the right place for it and routing is the right fix for the rest.

Note also that the comment justifying the old default in hooks/session-launch.ps1
(~line 889) says "the bridge already routes permission prompts to Home Assistant". That
is true for Codex and false for Copilot, so it was resting on a guarantee Copilot does
not provide. Fixing this task makes that comment true.

## Then: a session an agent launches should read as agent-driven

A session the agent starts from the dashboard comes up with the ordinary colours, not
the purple edge, and stays that way until the agent replies to it. That is backwards -
you did not open it, and the launch is exactly the moment it is most useful to see that
something else is driving. Noticed immediately every time a session is handed off.

`Get-BridgeDriverFromState` is called from exactly one place: the Submit press in
`daemon-replies.ps1` (~line 404). So `Driver` is set by an agent *replying* to a
session, never by one *starting* it. `Test-DaemonNewSessionPressed`
(hooks/daemon-launch.ps1, ~line 394) already reads the Launch button's state and throws
its `context` away - the presser's account is sitting on it, exactly as it is on a
Submit press, and `Get-BridgeDriverFromState` would take it unchanged.

The awkward part, and why this is not a two-line change: the press and the session are
not the same moment. The launch returns before the CLI has registered itself, so the
entry to stamp does not exist yet and the driver has to be carried from the press to
whichever session that launch produces. Get the correlation wrong and a session gets
somebody else's driver, which is worse than no glow - a glow that lies is the one
outcome the feature was built to avoid.

## Then: the choices card should answer a whole form

Done, card 1.15.0. Multi-field questions rendered as Home Assistant's native `select`
dropdowns, and they are bad in two specific ways the row buttons already solved: a
native select commits on blur, so an answer needed a tap away and then Send, and it
sizes its menu to the longest option and will not wrap, so sentence-length answers were
cut off on a phone. Both were why `agent-bridge-choices-card` was written for 1.13.0,
and it was only ever wired up for the single-choice case - gated on `select.<node>_f1`
being `Idle`, that is, shown only when there were no field dropdowns, which is exactly
backwards from what a form needs.

`AgentBridgeChoicesCard` now takes a `fields` list of the field entities and draws a
labelled group of rows per armed field, each tap calling `select.select_option` on that
field's entity, with the picked option kept marked because a form is only sent when
Send is pressed. The headings come from the decision entity's `field_<n>_label`
attributes, where the bridge has published them since the dropdowns existed: an MQTT
entity's own `friendly_name` is the device name plus the entity name, so reading it
there would have put the session's whole title in front of every field. The text box
and Send stay beneath for the free-text field, and no daemon change was needed - it
reads those same entities today. With the card served the dashboard stops building the
per-field dropdowns and the separate cancel button, which the card draws as its own
quiet row.

**The test follows the value the whole way** (`tests/test-choices-form.ps1`). It arms a
real two-field question through `Set-CopilotMqttDecision` and keeps the entity ids,
options and labels that publishes; builds the real dashboard and takes the card's config
out of it; runs the *real card* on that config and those states through node
(`frontend/test/drive-choices-card.js`, sharing `frontend/test/card-harness.js` with the
card's own suite); then applies the `select_option` calls the card made and asks the
real `Read-DaemonFormAnswer` what the form says. Nothing in the middle is written out by
hand. Both halves of the break were checked by mutation: renaming the `fields` slot in
the view fails it, and pointing the card's rows at the decision entity instead of the
field fails it at the daemon end - neither of which any test at either end would have
caught.

Worth keeping: a test suite must not be able to reach the live instance. An early draft
dot-sourced `bridge-frontend-cards.ps1` without its `BRIDGE_FRONTEND_NORUN` guard, which
runs the card check and opens real WebSocket connections, and stubbed
`Invoke-CopilotHaWebSocket` only halfway down the file. Every door is closed before
anything runs now.

Related, and now understood: **the mismatch warning is a false alarm, and the
arrow-key delivery was never the problem.** `Get-DaemonAnswerCorrection` had fired
three times on 2026-09-28, each reported as the answer reaching the CLI not being the
one sent, and each time the intended answer happened to be the first option - which is
also where a mis-delivery lands, so the two were indistinguishable from the values
alone. The live drive of the form card settled it. A form was answered from the
dashboard with `Next task` at **index 3 of 4**, a mis-delivery could not produce it,
the CLI recorded exactly that option - and the correction fired anyway.

`Test-CopilotAnswerMatchesSelections` asserts that the recorded result contains each
injected option label verbatim; its docstring says labels are "reproduced verbatim".
They are not. Copilot records a form's answer as its *schema values*, not its labels:
the transcript for that question reads `User responded: release=cut_now,
next_task=stop_here`, while the labels sent were `(Recommended) Cut 1.15.0 now` and
`Nothing - stop for tonight`. So any question whose options are value/label pairs -
`oneOf: [{const, title}]`, which is what a readable prompt needs - can never match, and
neither can a boolean field, recorded as `true` rather than the `Yes` that was typed.
A plain `enum`, where label and value are the same string, matches and is why this was
not constant.

The cost is not cosmetic: the card says "Answer may be wrong - check the terminal" and
a correction is injected into the session telling the agent to disregard an answer that
was in fact correct. It trains you to ignore the one warning that exists for a genuinely
confident wrong answer.

**Fixed 2026-09-28.** A field now carries `Values` alongside `Options`, and
`Test-CopilotAnswerMatchesSelections` accepts a choice under either name. Both halves
are read by one function, `Get-DecisionSchemaFieldChoices`, which returns Label/Value
pairs; `Get-DecisionSchemaFieldOptions` is now a thin wrapper over it that takes the
labels. That is deliberate - read by two copies of the branching logic the lists would
eventually disagree about which value sits behind which label, and the check would
then blame the wrong option. The neighbour check keeps its teeth, because a
neighbouring option differs under both names.

The work was all in the middle. Reading values where the schema is parsed and
comparing them where the answer is checked are two ends that would each pass their own
test while the value was dropped in between - the two are separated by a marker file
that is JSON on disk, written by the hook and read by the daemon minutes later.
`tests/test-answer-match.ps1` therefore follows one answer the whole way: real tool
arguments, the real parse, `Write-CopilotDecisionMarker` to a real file,
`Get-CopilotDecisionMarker` back off it, and only then the check, against the verbatim
string Copilot recorded. It picks the **second** option of each list, because a first
option passes a broken check by accident. Three mutations were confirmed to fail it:
ignoring the value in the check, dropping `Values` at capture, and letting labels and
values drift out of step - the last of which flips `the neighbouring option is still
caught`, which is the assertion that proves the check still does its job.

One thing found on the way: `Get-DecisionSchemaFieldOptions` read `$Field.enum` and
`$Field.oneOf` bare. Under `Set-StrictMode` that is a terminating error on any field
lacking them. It has never fired, because `daemon-hookspool.ps1` spools the Copilot
handlers with `Strict = $false` for exactly this reason, but the new pair function is
reachable from elsewhere and now probes through `PSObject.Properties` instead.

**Still open, and not the same thing:** nothing yet proves delivery is always right.
This is one correct delivery at a non-first index; it removes the evidence that
delivery was broken, not the possibility.

Also open: **a rejected auth is retried hard enough to get the bridge IP-banned.** Seen
live on 2026-09-28. Two `wyoming` config entries hung Home Assistant's bootstrap - it
logged `Waiting for integrations to complete setup: {('wyoming', ...): 66.03, ...}`
with the same frozen elapsed value minute after minute - and while core was starting
every bridge request was logged as `Login attempt or request with invalid
authentication ... Requested URL: '/api/websocket'`, six per reconcile.

That noise was not on its own what banned the machine, and the arithmetic is worth
keeping straight. `login_attempts_threshold` is 10 and a *successful* login resets the
count, so a burst of six never reaches it: four of those bursts came and went between
17:23 and 18:17 with no ban at all. What tripped it was a test suite firing ten reads
of one entity in seventy milliseconds with a placeholder token, too fast for any
success to land in between - `tests/test-choices-form.ps1` had defined its
`Get-HomeAssistantState` stub *below* the call that needed it, so the real one was
still in scope. Home Assistant logged the ban in the same millisecond as the tenth.
Had the count merely accumulated, the ban would have landed at 17:24 rather than 18:22.
That hole is now closed by a guard on `Invoke-DecisionHttpRequest`, covered by
`tests/test-http-guard.ps1`: a suite cannot reach a real Home Assistant at all.

So the slow start is the standing hazard rather than this ban's cause: six per cycle
sits four short of the threshold, and anything else failing auth at the same time
closes that gap. Once banned, every request from the machine - daemon and dashboard
alike - answered 403.

Three things are worth knowing. The ban is written to `/config/ip_bans.yaml` and read
back at startup, so restarting Home Assistant does *not* lift it - the file has to be
emptied first, which is not obvious when the symptom is "I restarted and it is still
banned". Nothing in the bridge said what had happened; the daemon log only repeated
`403 (Forbidden)`, which reads like a token problem and is not one. And the bridge's
own behaviour is what leaves it exposed: it keeps issuing the same six calls on every
cycle while the answer is an auth rejection. A rejected auth is not a transient error
to retry at full rate - it wants a long back-off and a line in the log naming the ban
as the likely cause. Note this is the WebSocket path specifically;
`Test-DecisionTransientHttpError` already declines to retry an unauthorised REST call.

Also open: **thinking never enters the history trail.** `History` only ever receives
`Reading your message`, `Running: <tool>` and, for Copilot, assistant text; reasoning is
published only as the single newest line (`response` with `response_kind: reasoning`).
The daemon publishes every few seconds, so a thought superseded within that window is
never seen and cannot be recovered from the trail, which is capped at
`ActivityHistory = 12`. Raised twice by the owner. It affects every inline agent's
trail, so it wants a decision - put thinking in the trail (capped in length, probably
only with Detailed activity on), or publish per line rather than per reconcile.

## A performance pass, measured (2026-09-28)

Numbers taken on DSWETT-HOME against the live instance, not estimated.

| | |
|---|---|
| daemon, steady | 2-5% of one core continuously, 147-159 MB private |
| where its CPU goes | ~68% in reconcile spikes of 100-170 ms; ~30% in the 10 Hz tick at ~0.7 ms |
| a PowerShell hook, end to end | 587-634 ms |
| the same event through the native hook | 21 ms |
| `pwsh -NoProfile -Command exit` | 341 ms |
| REST: one entity / template / WebSocket command | 5.5 / 14.6 / 12 ms |
| REST: `/api/states`, everything | 421 ms |
| build the whole Lovelace config, and serialise it | 18-23 ms, then 0.3 ms |
| `Get-CopilotAskUserState` over a 4 MB tail | 93 ms |
| tail-read a **276 MB** transcript | 32 ms |
| `Get-CimInstance Win32_Process` | 272 ms |

**The two largest findings were not Go work.**

**The native hook was installed and not being used.** `agent-ha-bridge status` read
`native (1.14.6) - no runs in the last 24 h`, which sounds idle and meant bypassed:
Copilot only runs it from 1.0.88 and this machine had 1.0.87, so every `ask_user`,
permission prompt and turn end paid 587 ms of PowerShell startup instead of 21 ms, on
the one path a person waits for. The installer did say so - once, in dark grey, in a
page of output nobody re-reads. It is a warning now, and `status` says it beside the
version rather than leaving "no runs" to be read as quiet.

**A reconcile made about 5 Home Assistant reads per session and 3 besides, every pass,
whether or not anything had happened** - the repair pass read the reply box and the
decision selector, the reply pass read the decision selector *again* and the payload
sensor, and the stop pass read the stop button. Thirteen round trips for two sessions,
forty-three for eight. The machinery to avoid this already existed and was used for
three slow-moving things only: `Get-DaemonHomeAssistantStates` renders the bridge's
entities through `/api/template` in one read. There were 3 calls to it against 47
direct `Get-HomeAssistantState` calls. The reconcile now takes one snapshot up front
(`Set-DaemonReconcileSnapshot`) and the repeated checks read from it - 17 ms of CPU
against 37 ms for five direct reads, and flat in the session count rather than linear.

**That template was also four times slower than it needed to be.** Written as
`for s in states if s.object_id.startswith(...)` the filter ran in Jinja, once per
entity, across all 5,354 states to find 44: 221 ms of Home Assistant's CPU. Moving the
filter into `selectattr` - the same output, byte for byte - made it 50 ms. The
accumulator was not the cost and the attributes were not the cost; iterating the whole
instance in Jinja was.

**Two things this pass got wrong, both caught by testing rather than reasoning.**
The snapshot was built with `foreach ($x in @(Get-DaemonHomeAssistantStates ...))`,
and that function returns its list comma-wrapped so an empty one survives a caller's
`@()`. The wrap therefore produced a one-element array holding the whole list, the
loop ran once with every entity at once, and `[string]` joined the ids into a single
key 179 characters long. Every lookup missed and fell through to a direct read: the
batching did nothing whatsoever while passing every end-to-end check. And the daemon's
CPU read 4.8% after the change against 2.2% before, which looked like a regression and
was not attributable at all - the two windows differed by how hard the session on the
machine happened to be working. The isolated measurement is the one that means
anything.

**Still open, in rough order of measured value.**

- `Invoke-DaemonFastActivity` runs **four times per reconcile**
  (`agent-bridge-daemon.ps1`), each a full scan of every session.
- Launcher, workspace and adapter discovery are machine-level but recomputed every
  15 seconds; the dashboard is already signature-gated and these could be.
- `Get-CopilotAskUserState` re-parses the tail every pass at 93 ms. It cannot have
  changed if the transcript has not grown, and the length is already known.
- `bin/agent-ha-bridge.ps1` finds the daemon with a 272 ms WMI query, for a pid the
  heartbeat file already holds.

**On moving more to Go.** The hook is already there and is 28x faster; the work was
getting it used. Beyond it the only rewrite the measurements justify is a resident
**transcript worker** - bounded append reads and the reducers behind a small JSON
contract, with the PowerShell readers kept as the fallback - because transcript
parsing is what the reconcile actually spends its CPU on. A full daemon rewrite is not
justified: the loop is orchestration rather than compute, and the I/O it orchestrates
is already 5-15 ms. Dashboard generation (20 ms, gated), MQTT and WebSocket transport,
and the installer are not worth moving. Console injection is already compiled C# in a
cached DLL, so it is a strategic move rather than a performance one.

## Resuming

Read this file, then `git log --oneline -10`. The first unticked phase is next. A
half-done phase is never committed, so `git status` shows any work in progress.
