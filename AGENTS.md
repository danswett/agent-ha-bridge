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
all-adapter liveness: no uncommitted or untracked data, no ignored data other than the
build outputs below, no checked-out branch, no detached commit ahead of the base, no
live session at or below the directory, and at least `newSession.worktreeIdleHours`
(12) old. Unknown state and linked/submodule trees are retained. Only clean tracked
files, those build outputs and empty directories are removed; pending launches stay
Git-locked until registration. Anything unmerged or uncommitted stays.

The one exception to "ignored data retains the tree" is the native hook this file
tells you to build - `hook/agent-bridge-hook`, or `.exe` on Windows. It is named
exactly, in `$script:BridgeWorktreeBuildOutputs`, and it is the only ignored path
cleanup will delete. The claim that it is disposable rests on the other checks rather
than on its name: a tree is only a candidate when no tracked file is modified, so its
`hook/` source is exactly what is committed and `go build` reproduces the binary from
it. Build with local modifications and those modifications retain the tree, so the
instrumented binary goes nowhere.

Everything else ignored - a `.env`, a `config.json`, `mcp/node_modules`, `hook/dist` -
still retains the tree, and a build output sitting beside any of it excuses nothing.
Without that exception, following the test procedure below made a worktree
permanently unreclaimable, the cap filled, and launches were refused with no fallback
(#143).

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

### Tidy up only after yourself

"The bridge tidies them up later" means the bridge, not you. `~/repos/wt` is shared
across repositories and sessions, so most of what is in it belongs to someone else and
its uncommitted work is invisible from here. Remove a worktree you created, by name.
Never sweep the root, and never write an ad-hoc reclaimer - a cluttered root is not
evidence that anything in it is finished.

On 2026-10-08 a session that had just finished a release on an *unrelated project*
emptied every worktree under the root, twice in fifteen minutes, destroying uncommitted
and untracked work across projects it had no connection to. Branch `fix/keychain-prompt-storm`
was checked out in one of them. #143 records the same anti-pattern hours earlier, where
"an ad-hoc remover written during the original incident omitted it and used `--force`".

`Remove-BridgeFinishedWorktree` is the one supported reclaimer, and the checks above
are why it is trustworthy: a checked-out branch, uncommitted or untracked files, a
missing marker or an age under `newSession.worktreeIdleHours` are deliberate
protections for other people's work, not obstacles to route around with `--force`.
It also only ever enumerates the repository it is given, so it cannot reach another
project's trees - an ad-hoc sweep of the shared root can, and did.

The general rules - never touch a branch you did not create, never `git stash`, stage
only files you changed, never `git add -A` - are in
`~/.copilot/reference/git-workflow.md`.

## Everything lands through a pull request

Including one-line and documentation changes.

1. Rebase onto freshly fetched `origin/main`; never merge `main` into the branch.
2. Re-run the tests *after* the rebase.
3. `gh pr create`, saying what changed, why, and what was run to verify it.
4. Wait for green CI on the final head and read all submitted reviews, inline threads
   and general/bot comments. Fix or record a reasoned disposition for every
   substantive finding, verify the result, resolve accepted threads, and recheck
   feedback immediately before merge. Green CI or an outdated thread is not
   acceptance; never resolve a thread merely to bypass protection. If CI fails on
   something you did not touch, check whether `main` is already failing the same way
   and say so rather than merging into red.
5. `gh pr merge <n> --squash --delete-branch`.
6. Do not end a session while it still owns an open PR. Remain responsible through
   merge or deliberate closure; an ownership transfer counts only when a named
   successor explicitly accepts the recorded handoff. Then perform only the normal
   cleanup of your own branch/worktree. Leave completed worktrees clean and detached;
   the bridge tidies them up later.

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
skips explicitly, and fails on a nonzero suite exit or timeout (900 seconds per suite).
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

This preserves supported card-version fallbacks. It is not, by itself, a barrier
against another machine overwriting shared resources.

### Publication authority, versions and rollback

The writer is explicitly configured in `dashboard.publication`; never derive it from
hostnames, root-derived installation IDs, matching bundles, presence or clocks.
Bootstrap/migration is a one-shot operator action, not installer/daemon self-election.
Keep first install, existing unfenced artifacts, established authority and failed or
lost state distinct. Only the designated writer bootstraps; other machines continue
reporting and can observe accepted shared output without acquiring write authority.

Keep the version axes separate:

| Axis | Contributor contract |
|---|---|
| Bridge `VERSION` | Release identity, not card/render compatibility or publication authority |
| Card `CARD_VERSION` and bytes hash | Bump for changed card content; never relabel an old file with a publication argument |
| `$script:BridgeDashboardRenderVersion` and renderer fingerprint | Bump when changing the generating helpers fingerprinted by `Get-BridgeRenderArtifact`; equal-version/different-content artifacts are conflicts |
| Publication fencing protocol | Change deliberately when policy/receipt interpretation changes; unsupported formats must refuse rather than reset or guess |
| Operator generation | Explicit expected generation/content and exactly the next configured generation for policy changes; no timestamp election |

Guard actual publication entry points, including manual/installer callers, not only
the daemon. The reserved card/policy resources must not bypass those guards through
the generic third-party registrar. Use HA-supported resource fields; policy is in the
resource URL, not arbitrary wire metadata accepted only by a permissive fixture.

An exact rollback pin is a version **and content** contract for both artifacts.
Renderer publication and read-only verification must independently check the actual
pinned card. A matching receipt/URL hash alone is insufficient: do not bless a legacy
overwrite, an unapplied pin or same-version wrong content as current. Missing or
unverifiable pinned content stays repair-required; legitimate advance-mode fallback
and non-writer observation must remain supported. A new automatic publisher cannot
leave a pin without another explicit operator generation.

Currentness comes from the actual accepted view on every reconcile, not a remembered
local signature or a skipped save. Keep the receipt's input signature, resource,
content and rendered session-node set bound together. Retirement can proceed only
when verified shared output no longer renders that node, including for non-writers;
display text mentioning an ID is not a rendered entity reference. If a generator
adds new session-entity surfaces, preserve that rendered-node invariant and its tests.

Preserve the independent shared policy and protected local high-water receipts when
repairing a missing dashboard. Unreadable, corrupt or lost policy is not absence.
The local receipt mutex and check-then-write HA calls are **not a distributed lease**.
See the README's operator procedures for explicit bootstrap, pins and policy recovery.

Exercise real publishers, readers and reconciliation/retirement callers against
stateful, schema-faithful HA boundaries and real isolated config/files. Keep
red/green cases for upgrades, exact pins, same-version conflicts, deletion, denied
reads, lost policy, restart, non-writers and clock skew; a false/throwing replacement
for the helper under test does not prove its failure path. The pinned unmodified
pre-fence publisher fixture demonstrates an accepted limitation, not containment.

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

Every machine can read the whole picture from retained per-machine sensors, but only
the configured writer publishes the shared card and Lovelace dashboard. Observers
verify actual accepted output; they do not take over when the writer is unavailable.

Unmodified pre-fence writers still ignore the policy and can overwrite the same HA
paths, even when their card version matches. Installing the guards on one host does
not contain them; repair after an overwrite is not prevention. First introduction
therefore needs an operator-approved migration and offline-host rejoin plan before
release/cutover, not an assumed transparent per-machine rollout.

Reconciliation checks shared state even when the local signature is unchanged.
After approved source/configuration changes, restart the selected daemon so it uses
the intended renderer and configuration; a healthy old process is not proof that new
publication code or authority is active.

Peers can be updated from Home Assistant without a shell on them: press that machine's
`button.agent_bridge_<slug>_install_update`. The press forces a fresh release check, so
it works even when the machine's own cached check still reads as up to date. This is
not a fleet migration, publication bootstrap, rollback authorization or permission
to bypass the release owner's coordinated cutover.

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

### Press one thing, not everything

`Invoke-HomeAssistantService` refuses a call that names more than one entity, and
`Assert-HomeAssistantServiceTarget` is where that is enforced. It takes a single
scalar `entity_id` and nothing else: `area_id`, `device_id`, `label_id` and `floor_id`
are refused outright, because Home Assistant expands each of them to *every* matching
entity, so one scalar `area_id` presses every button in the area. **A direct
`Invoke-RestMethod` to `/api/services/...` goes nowhere near it**, so when you press
something yourself, the shape of the target is entirely your problem.

On 2026-10-02 a session ending one test session filtered `GET /api/states` down to
that session's stop button and sent an entity id from the result. The selection
collapsed, the POST carried thousands of ids instead of one, and Home Assistant
pressed every button among them: 166 of them at 22:45:23 PT. The UniFi fleet rebooted
mid-request, PoE camera ports power-cycled, and vacuum consumables, ERV totals and
bed-presence calibrations were reset. The call returned 502, which read as a transient
blip, so the identical command ran again three minutes later.

Worth knowing: the tempting explanation - that `Invoke-RestMethod` hands a JSON array
to the pipeline as one object, so `Where-Object` tests the whole array - **does not
reproduce here**. It enumerates under both PowerShell 7.6.6 and Windows PowerShell
5.1, checked against the live state list. Do not rely on that story; rely on the
habit below.

Never send a selection you have not proved is exactly one thing:

```powershell
$ids = @($states | Where-Object { $_.entity_id -like "*${sid}*_stop" } |
    ForEach-Object entity_id)
if ($ids.Count -ne 1) { throw "expected one stop button, got $($ids.Count)" }
# only now is it safe to POST $ids[0]
```

`$x[0].entity_id` on something you have not counted is the bug. If a selection can
ever be empty or plural, say so out loud *before* the POST, not after.

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
