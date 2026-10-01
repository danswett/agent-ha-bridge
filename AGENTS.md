# Working on this repository

Notes for anyone - person or agent - making changes here. Several agent sessions are
often working in this repository at once, so the first section is not optional.

## Do not work in the primary clone

`~/repos/agent-ha-bridge` stays on `main` and stays clean. It is what other sessions
read, and what releases are cut from. A `git checkout` there changes the files under
every session sharing the clone.

You should not normally have to do anything about this. **Bridge** is configured with
`"isolate": true`, so every session the bridge launches into it gets a git worktree of
its own under `~/repos/wt`, created at launch and named for the moment it was made.
Your session is already somewhere private; `git status` will tell you where.

If you find yourself in the primary clone after launching by hand, make your own
before doing anything else. Requested bridge isolation fails closed:

```powershell
$wt = "$HOME\repos\wt\agent-ha-bridge-manual"
git -C "$HOME\repos\agent-ha-bridge" fetch origin --quiet
git -C "$HOME\repos\agent-ha-bridge" worktree add --detach $wt origin/main
Set-Location $wt
```

Either way, branch from freshly fetched `origin/main` once you are in one:

```powershell
git fetch origin --quiet
git switch -c feat/<topic> origin/main
```

A worktree is a complete working copy: the full suite runs there, and the installer
still marks an install from one as `(dev)` (a worktree's `.git` is a file, and
`Test-Path` returns true for it).

### What happens to it afterwards

The bridge cleans only marked, unlocked worktrees with readable ownership, Git and
all-adapter liveness: no uncommitted, untracked or ignored data, no checked-out branch,
no detached commit ahead of the base, no live session at or below the directory, and
at least `newSession.worktreeIdleHours` (12) old. Unknown state and linked/submodule
trees are retained. Only clean tracked files and empty directories are removed;
pending launches stay Git-locked until registration. Anything unmerged or uncommitted stays.

So leaving a branch behind is safe, and is the right thing to do if the work is not
finished. If it *is* finished, leave the worktree clean and detached and it will be
tidied up on its own:

```powershell
git switch --detach origin/main
git branch -D feat/<topic>
```

Do that *after* the merge. `gh pr merge --delete-branch` cannot delete a branch that is
checked out in a worktree: it warns and suggests `git worktree remove`. Following that
is fine here - the worktree is disposable - but detaching is enough.

`newSession.worktreeLimit` (10) caps managed worktrees per repository. At the cap or
on an isolation failure, the launch is refused with a diagnostic on the launch card
and in the daemon log. There is no fallback to the primary checkout.

The general rules - never touch a branch you did not create, never `git stash`, stage
only files you changed, never `git add -A` - are in
`~/.copilot/reference/git-workflow.md`.

## Everything lands through a pull request

Including one-line and documentation changes.

1. Rebase onto freshly fetched `origin/main`; never merge `main` into the branch.
2. Re-run the tests *after* the rebase.
3. `gh pr create`, saying what changed, why, and what was run to verify it.
4. Wait for CI to be green. If it fails on something you did not touch, check whether
   `main` is already failing the same way and say so rather than merging into red.
5. `gh pr merge <n> --squash --delete-branch`.
6. Leave the worktree clean and detached; the bridge tidies it up later.

## Tests

Use the runner, not individual suite scripts or a `Get-ChildItem` execution loop.
From a slot, with PowerShell 7, Node.js and Git available:

```powershell
node --check frontend/agent-bridge-reply-card.js
node frontend/test/test-cards.js                 # the dashboard cards
pwsh -NoProfile -File tests\run-tests.ps1 -Suite test-runner.ps1
pwsh -NoProfile -File tests\run-tests.ps1 -Suite test-auth-backoff.ps1
pwsh -NoProfile -File tests\run-tests.ps1 -List   # no execution
```

The canonical offline selection is `tests/suites.psd1`. Windows and macOS CI run the
same command; new suites must be classified there or the runner fails:

```powershell
pwsh -NoProfile -File tests\run-tests.ps1
```

Inventory discovers `test-*.ps1` throughout the checkout, including new components
and nested directories. It prunes `.git`, `node_modules`, `vendor`, `.venv`, `venv`,
`fixtures`, `__fixtures__`, `test-results`, `TestResults`, `coverage`, and `dist` at
any depth, plus runner output marked by `.bridge-test-results`. It never follows
symbolic links or junctions, including linked suite files. Excluded trees cannot be
made executable by adding them to the manifest. Use either path separator in the
manifest or selectors; duplicate canonical paths are rejected.

Each suite gets a fresh process, HOME, TEMP, config, AppData and client roots. Only a
small OS/tool environment allowlist is inherited, not credentials or HTTP opt-ins.
Console input/output and pipelines use UTF-8. The offline guard also applies in child
processes; mock transports before calling code that uses them. Do not defeat that
guard, read installed helpers, or add real client/installer execution to Offline.
This is isolation for reviewed tests, not an OS sandbox for arbitrary scripts.
Installer helpers share that configuration-free guard. Stub the actual transport:
`Invoke-RestMethod` does not replace `Invoke-WebRequest`, WebSockets, DNS discovery,
or a checker subprocess. A guard violation must propagate, not become an ordinary
connection failure or a successful cosmetic fallback.
Manual suite detection uses the `test-*.ps1` entry filename, not an ancestor folder
named `tests`; ordinary installer/runtime scripts in such a checkout remain normal.

The runner retains logs and `summary.json` in the printed results directory, reports
skips explicitly, and fails on a nonzero suite exit or timeout (180 seconds per suite).
Use `-ResultsDirectory <new-directory>` to choose where diagnostics go. Build the
native hook in `hook/` before a full run (`go build -o agent-bridge-hook.exe .` on
Windows, without `.exe` on macOS); missing native binaries are reported as skips.

`Host` (installer-command) and `Platform` (tmux delivery) are deliberately separate.
They require `-Group Host` or `-Group Platform`, `-AllowHostTests`, and a disposable
GitHub-hosted runner; developer and self-hosted machines are refused. Host tests use
unique `-TestRegistryId` namespaces and loopback fixtures, but `-TargetHome` still
does not isolate every installer side effect. Never run that suite locally.
The Host runner alone permits its fixed connection-refused endpoint,
`http://127.0.0.1:1` (and the matching WebSocket endpoint); it never permits LAN
discovery. Supply the fixture URL explicitly to avoid discovery during reconfigure.
`Integration` is inventory-only here: those suites require a separately provisioned,
disposable Home Assistant and an explicit `BRIDGE_ALLOW_TEST_HTTP=1` outside this
runner. They are not part of CI or the safe offline command.

CI also runs PSScriptAnalyzer over every `.ps1` under `PSScriptAnalyzerSettings.psd1`
and fails on any finding. Run it before pushing - it has caught unapproved verbs and
cmdlet aliases that no test would:

```powershell
Get-ChildItem -Recurse -Include *.ps1, *.psm1 |
  Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' } |
  ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Settings ./PSScriptAnalyzerSettings.psd1 }
```

`tests/verify-*.ps1` are manual checks against real hardware (a Mac's Terminal, for
one). The manifest and CI do not run them, and neither should you without reading
them first and explicitly arranging a suitable test system.

## Dashboard cards are version-gated

The dashboard is generated by `Save-CopilotSessionDashboard`, but which cards it emits
depends on the card file Home Assistant is actually serving, read from the `?v=` on its
resource URL by `Test-BridgeActivityCardServed`.

When adding a feature that needs a new or changed custom card:

1. Bump `CARD_VERSION` in `frontend/agent-bridge-reply-card.js`.
2. Gate the generator on that exact version, and keep the old output as the fallback.
   An older card silently drops config keys it does not know, so an ungated change
   looks like it worked while the rows never appear.
3. Cover both sides: the new shape at the new version, the old shape below it.

This is what keeps a fleet on mixed versions working.

## Releases

One at a time. Check `gh release list` and that `main`'s CI is green first.

1. Merge the feature PR.
2. On `main`, bump `VERSION` and commit `Release X.Y.Z` - that commit touches nothing
   else.
3. Create the release as a **draft**: `gh release create vX.Y.Z --draft --target <sha>`.
4. Push the tag (`git tag vX.Y.Z <sha> && git push origin vX.Y.Z`), which runs
   `release.yml` and attaches the native hook builds.
5. Check all five assets are attached, then publish.

Publishing before the assets exist leaves a window in which a machine updating finds no
build and silently keeps its old hooks.

## One dashboard, several machines

Every machine renders the *whole* picture from retained per-machine sensors, and every
machine rebuilds the same shared Lovelace dashboard. Two consequences worth knowing
before debugging something that "keeps reverting":

- A machine running an older bridge will rewrite the dashboard in its own older shape.
  A layout change is not fully live until every online machine has the release.
- A daemon only rebuilds when its signature changes, so after installing from source
  run `agent-ha-bridge restart` - an installer that does not restart the daemon leaves
  the old generator in memory.

Peers can be updated from Home Assistant without a shell on them: press that machine's
`button.agent_bridge_<slug>_install_update`. The press forces a fresh release check, so
it works even when the machine's own cached check still reads as up to date.

## Driving the bridge as an agent

An agent can drive a session the same way the dashboard does - press **Launch**, answer
a question, reply to a session on another machine - by calling Home Assistant directly.
Do that with the *agent's* token, never yours:

```powershell
$headers = @{ Authorization = "Bearer $env:AGENT_HA_AGENT_TOKEN" }
```

Every session the bridge launches already carries that variable;
`Get-BridgeAgentTokenEnvironment` puts it there for exactly this, so an agent that goes
on to drive another session arrives as itself. Two caveats it is worth knowing before
you hard-code the name: it is exported only when an agent token is configured, and the
name itself is `homeAssistant.agentTokenEnvVar` - `AGENT_HA_AGENT_TOKEN` is only its
default, so an install that has renamed it exports the renamed one.
`homeAssistant.token` is *yours*, and stays what the daemon, the hooks and the
dashboard provisioning use. The MCP server holds both: yours for provisioning, which is
administrator-only, and the agent's for the session tools that press things.

Getting it wrong fails silently, which is the whole problem. Both tokens authenticate
and both are authorised, so nothing errors and no log line appears. The only difference
is the `context.user_id` Home Assistant records against the press, which
`Test-BridgeAgentUserId` matches against `homeAssistant.agentUserIds` to decide whether
the session card gets its purple edge.

On 2026-09-29 an agent took the first token it found in `config.json`, launched a
session on another machine with it, and the card came back blue: a launch attributed to
the user, with nothing anywhere saying otherwise. The token it should have used was
already sitting in its own environment. Reading state is different - for a read
`homeAssistant.token` is correct and simpler. The rule is about writes: a press, a
reply, a launch.

### Reading the answer back

A session on another machine reports through its own entities, and the one that
carries what it actually said is `sensor.agent_bridge_<session>_activity` - the text is
in the `response` attribute, with `sensor.agent_bridge_<session>_status` going `idle`
when the turn is done. Two things make waiting on that alone unreliable: a session is
briefly `idle` before it starts working, and it *keeps the previous turn's* `response`
while the next one starts. So snapshot `response` (or the activity's `updated`) before
you write, and treat the turn as finished only once it has changed - otherwise the
first poll hands back the last answer and you stop waiting.

Do not ask a remote session to answer with a persistent notification. Home Assistant
does not expose those through `GET /api/states`, so polling for a
`persistent_notification.*` entity finds nothing however long you wait, and the silence
looks exactly like the session having died. They can be listed over Home Assistant's
WebSocket API, but the activity sensor is already there and needs no second connection.

## Style

- Comments explain *why*, and especially what went wrong before. Most of the comments
  here record a specific failure; keep that, and do not add comments that only restate
  the code.
- Test names read as sentences about behaviour, not about functions.
- PowerShell runs under `Set-StrictMode -Version Latest`. Two traps this repository has
  hit repeatedly are documented at their sites: a function returning an empty array
  bare yields `$null`, and dot-sourcing a script rebinds every parameter it declares.
