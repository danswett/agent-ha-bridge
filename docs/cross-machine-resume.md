# Resuming a session on another machine

Today a session can only be reopened where it ran. The **Resume** dropdown on a
machine's launch card is built from that machine's own session files, so a session
started on the desktop can be resumed from the phone - but only *onto the desktop*.

This describes making any session resumable onto any machine: the dropdown becomes one
merged list covering the whole fleet, and picking a session that belongs elsewhere moves
it. Every other row on the card stays exactly as it is, and stays per-machine.

Everything below was measured on the real fleet (DSWETT-HOME, DSWETT-DEV-VM1, DASDESK,
Dans-MBP) on 2026-10-01, not inferred. Where a thing was tried and did not work, it is
recorded, because the dead ends are the expensive part to rediscover.

## What is already true

| Claim | How it was established |
|---|---|
| A Copilot session is portable by copying `session-state/<id>/` | Copied `events.jsonl` + `workspace.yaml` (4 files, 225 KB) into an empty `COPILOT_HOME`; the resumed session quoted the real first user message and loaded 109.9k tokens, 60.4k cached |
| A Claude session is portable by copying one `.jsonl` | Transcript placed in a scratch `CLAUDE_CONFIG_DIR`; resumed session recalled codewords that existed only in its history |
| A Codex session is portable by copying one `rollout-*.jsonl` | Same method with a scratch `CODEX_HOME`; recalled its codewords and the correct ACK count |
| None of the three needs path rewriting | Claude resumed from a project folder named `zzz-totally-unrelated-name`; Codex from `sessions\1999\01\01\` and from a flat `sessions\`. The stale `cwd` inside the transcript is ignored |
| There is no cloud shortcut | `workspace.yaml` carries `mc_task_id`, and `--session-id <task-id>` in a clean home returned `NO-HISTORY`. Copilot's `/resume` accepts a cloud history ID, but it does not rehydrate a session the machine has never seen |
| Home Assistant can carry the bytes | A 924 KB session was zipped to 287 KB, chunked, published, reassembled and SHA256-verified through `mqtt.publish` in **1.5 s**, then resumed with full history |

### The one agent that fails silently

`copilot --session-id <id>` on a machine that does not have the session **does not
fail**. It starts a new, empty session wearing that id and exits 0. The control test
was indistinguishable from success until the session was asked to quote its own first
message and quoted the prompt back.

This is the single most dangerous thing in this feature. The bridge keys every entity,
card, reply and decision on session id, so a half-finished transfer followed by a launch
would produce two divergent sessions sharing one identity across the fleet, with nothing
logged anywhere.

Claude and Codex do not have this failure mode - they hard-fail with
`No conversation found` and `no rollout found for thread id` respectively. The integrity
gate below exists mainly to protect Copilot and Agency.

### Credentials are not transferable

Copying `.credentials.json` to a second location **rotated Claude's OAuth refresh
token** and spent the original, forcing a `/login` on the machine it came from. The
file was never modified; simply using it elsewhere was enough.

So a transfer moves transcripts and nothing else. The target must already be signed in
to that agent. `Get-BridgeLauncherUsage` already reports `SignedIn` per launcher, so a
resume onto a machine that is not signed in should be refused on the card, before any
bytes move.

## Why the bytes go through Home Assistant

The machines cannot reach each other. `DSWETT-HOME` does not resolve from
`DSWETT-DEV-VM1`, and no port is open between them: one is a cloud VM, the others are at
home. They are also `WORKGROUP`, not domain-joined, so there is no Kerberos identity to
borrow, and no `sshd` is installed.

Other routes were tried and rejected:

| Route | Why not |
|---|---|
| SMB / Windows share | No network path; workgroup machines would need stored passwords on every peer; not available on the Mac |
| SSH | Would mean installing and exposing a listening service on every machine |
| HA `media_source` upload | Rejects non-media files - `400 Bad Request` on a `.bin` |
| HA `/api/file_upload` | Write-only; consumed by integrations, with no download path for a peer |
| Supervisor API proxy | `401` with a normal long-lived token |
| OneDrive staging | Works, and survives the source being switched off, but puts transcripts containing source code into cloud storage and has unpredictable sync latency |

That leaves the one channel every machine already authenticates to and which is
identical on Windows and macOS: Home Assistant. It also keeps the bridge's existing
invariant - *machines talk to Home Assistant, never to each other*.

### Chunk size is 256 KB, and that is not negotiable upward

Measured end to end, published to a `json_attributes_topic` and read back from
`/api/states`:

| Payload | Base64 chars | Result |
|---|---|---|
| 256 KB | 349,528 | OK, ~640 ms |
| 512 KB | 699,052 | OK, ~976 ms |
| 1 MB | 1,398,104 | OK, ~895 ms |
| 2 MB | 2,796,204 | **Not delivered; killed the HA-to-broker connection** |

Mosquitto 2.1 lowered the default `max_packet_size` to **2,000,000 bytes**. Exceeding it
disconnects Home Assistant from the broker with `oversize packet`, every ~10 s, taking
down every MQTT entity on the instance - the bridge, Frigate, Valetudo - until the
broker's limit is raised. That outage is how the number above was learned.

Latency is dominated by polling, not payload size, so larger chunks buy nothing. **Use
256 KB**, which is an order of magnitude under the cap and leaves room for a fleet whose
broker has not been reconfigured.

Transcripts compress 3-4x, so the common case is one or two chunks:

| Session | Raw | Compressed | Chunks at 256 KB |
|---|---|---|---|
| Typical | 400 KB - 1.4 MB | 130 - 370 KB | 1 - 2 |
| Large | 13 MB | 3.5 MB | ~14 |
| Pathological (seen in the wild) | 206 MB | 67 MB | ~263 |

## The merged Resume list

Each machine already publishes a retained sensor describing itself, which every other
machine reads through `Get-BridgePeerMachine` - that is how the shared dashboard knows
what to draw for a peer. The resumable list rides the same way.

1. Each machine publishes its own resumable sessions - what `Get-DaemonResumableSessions`
   already computes - to a retained per-machine topic, each entry carrying `sessionId`,
   `launcher`, `folder`, `summary` and `updated`.
2. Every machine builds its `new_resume` options from **its own list plus every peer's**,
   with remote entries labelled by owning machine.
3. A new capability flag travels with the global status, as `profile` and `resume` already
   do. A peer that does not publish it contributes nothing rather than an empty row - the
   established pattern for not breaking a fleet on mixed versions.

Twelve entries per machine at roughly 150 bytes is a few KB, far inside what the
attribute channel carries comfortably.

Two existing rules have to widen from "this machine" to "the fleet":

* **A live session is never offered.** Two CLIs writing one transcript corrupts it. The
  global status attribute already lists each machine's live sessions, so the check has
  the data it needs.
* **A session is listed once.** After a transfer the transcript exists in two places, so
  the merged list dedupes by session id, keeping the most recently updated copy - see
  [Decisions](#the-source-copy-stays).

## Moving a session

Both ends poll Home Assistant, so the transfer is sequential and acknowledged - which is
exactly what the prototype did, and it completed a two-chunk transfer in 1.5 s.

1. **B** resolves the chosen label, sees the session belongs to **A**, and checks its
   preconditions (below). It picks a workspace from its own approved list.
2. **B** publishes a transfer request naming the session, the launcher and a nonce.
3. **A** sees the request, refuses if the session is live locally, bundles the required
   files, and publishes a manifest: file list, total size, SHA256, chunk count, and the
   source agent version.
4. **A** publishes chunk *n*; **B** acknowledges *n*; **A** publishes *n+1*.
5. **B** reassembles, and **verifies the SHA256 before writing anything into its agent
   home**.
6. Only then does B install the files and launch.
7. Both ends clear their transfer topics. Retained multi-hundred-KB payloads on an
   instance with thousands of entities are not something to leave lying about.

What each agent needs, and the one naming rule each imposes:

| Agent | Files | Naming rule that must be preserved |
|---|---|---|
| Copilot / Agency | `session-state/<id>/events.jsonl`, `workspace.yaml` | directory named `<id>` |
| Claude | `projects/<any-folder>/<id>.jsonl` | file must be `<id>.jsonl`; folder is arbitrary |
| Codex | `sessions/**/rollout-<ts>-<id>.jsonl` | filename must keep `rollout-…-<id>.jsonl`; folders arbitrary |

`session_index.jsonl`, `config.toml` and Codex's `thread_history_*.sqlite` were all
verified unnecessary.

## Where it opens

A same-machine resume reopens in its original folder and ignores the Workspace row. A
cross-machine resume cannot: the fleet's directories are disjoint (`rezna`, `danswett`,
`dswett`, `repos`), and a session that ran in an isolated worktree has a branch that
exists only on the machine that made it.

So **for a remote resume the Workspace row applies**, and the target's own approved list
decides. This is a deliberate departure from the current rule and should be stated on the
card, not inferred. Nothing is auto-created and no path is invented: the same
`Test-BridgeWorkspacePathApproved` gate governs it, so Home Assistant still cannot name a
directory the config has not approved.

## What must be true before any bytes move

Each of these is refusable on the card, with a reason, before a transfer starts:

* the source machine is **online** - presence can change between the dropdown being
  rendered and Launch being pressed, which happened during testing when a laptop slept
  in the two minutes between the two;
* the session is **not live** anywhere;
* the launcher is **installed and signed in** on the target;
* the bundle is **within the size cap**;
* for Codex, the agent versions are **compatible** - 0.158 introduced SQLite thread
  history and a `migrate-rollouts` command, so a rollout written by a different build may
  not be read the same way. Record the source version in the manifest and warn on a
  mismatch.

## Limits

Cap a transfer at roughly 25-50 MB compressed and refuse beyond it, saying so: a 206 MB
transcript is ~263 chunks, and pushing that much through Home Assistant is precisely the
kind of load that took the broker down. A session that large should be `/compact`ed
first.

## Failure modes worth testing

* a transfer whose SHA256 does not match **must not launch** - this is the guard against
  Copilot's silent empty session, and the test should assert no session was started;
* the source machine going offline mid-transfer leaves no partial files in the target's
  agent home;
* a session that goes live on the source after the request but before the bundle is
  refused;
* a target not signed in to the agent refuses on the card, before any chunk is published;
* a peer running an older bridge, publishing no resumable list, contributes nothing and
  breaks nothing;
* chunk topics are cleared after both success and failure;
* a session present on two machines is offered once, as the copy that was updated most
  recently, and the older copy disappears from the list once the newer one is written;
* an Agency session offered to a machine without Agency installed is refused, and one
  offered to a machine whose Agency has no profiles launches with no profile rather than
  with a name that machine does not have;
* progress and refusals reach the existing "Last launch" line, so no card version bump is
  needed and a peer on an older card still renders them.

## Decisions

### The source copy stays

A move is not destructive: nothing is deleted from the machine the session came from.
That leaves the transcript in two places, so the merged list has to make sure only one
of them is ever offered.

It already has what it needs to do that without any new bookkeeping. Each entry carries
`Updated`, so **dedupe by session id, keeping the most recently updated copy**. Resuming
on the target makes the target's copy the newer one, so the session simply follows the
machine it was last used on, and the stale copy stops being offered the moment the new
one is written.

This is deliberately not a "moved to" marker. A marker is state that has to be published,
kept in step and cleaned up, and it would be wrong the moment someone resumed the
original at the keyboard rather than through the dashboard. A timestamp comparison cannot
drift out of step with reality, because it *is* reality.

### Agency sessions transfer as Agency

They share Copilot's store, so the files that move are identical; only the launcher that
reopens them differs. A session that ran under Agency reopens under Agency.

That adds one precondition and reuses one existing row:

* Agency must be installed on the target, or the resume is refused on the card like any
  other missing launcher.
* The **Profile** row already applies to resumes and already offers only the profiles
  that target machine actually has, so the profile is chosen there rather than carried
  across. This matters because `agency copilot --profile-only <name>` on a machine
  without that profile exits before Copilot starts - the window closes too fast to read,
  which is exactly the failure the existing per-machine profile list was built to avoid.

A machine whose Agency has no profiles gets no Profile row and passes none, falling back
to Agency's base configuration - unchanged behaviour.

### The card shows transfer progress

A one-chunk transfer finishes in about a second, but a fourteen-chunk one does not, and a
card that sits silent through it looks broken.

Progress goes in the **existing `new_session_result` sensor** - the "Last launch" line -
as `Transferring 3/14...`, then the usual outcome text. Deliberately not a new entity:
the dashboard gates card shape on `CARD_VERSION`, so a new row would mean bumping the
card, gating the generator on that exact version and keeping the old output as a
fallback. Reusing a field the card already renders means a fleet on mixed versions shows
this correctly with no card change at all.

The same line carries the refusals, which is where most of them will be seen: the source
being offline, the agent not being signed in on the target, the bundle being over the
cap.
