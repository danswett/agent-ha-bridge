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

> **This is a design, not a sanctioned implementation.** See [Status](#status) at the
> end for what is and is not approved, and for the limits of the evidence below.

## What is already true

| Claim | How it was established |
|---|---|
| A Copilot session is portable by copying `session-state/<id>/` | Copied `events.jsonl` + `workspace.yaml` (4 files, 225 KB) into an empty `COPILOT_HOME`; the resumed session quoted the real first user message and loaded 109.9k tokens, 60.4k cached |
| A Claude session is portable by copying one `.jsonl` | Transcript placed in a scratch `CLAUDE_CONFIG_DIR`; resumed session recalled codewords that existed only in its history |
| A Codex session is portable by copying one `rollout-*.jsonl` | Same method with a scratch `CODEX_HOME`; recalled its codewords and the correct ACK count |
| None of the three needs path rewriting | Claude resumed from a project folder named `zzz-totally-unrelated-name`; Codex from `sessions\1999\01\01\` and from a flat `sessions\`. The stale `cwd` inside the transcript is ignored |
| There is no cloud shortcut | `workspace.yaml` carries `mc_task_id`, and `--session-id <task-id>` in a clean home returned `NO-HISTORY`. Copilot's `/resume` accepts a cloud history ID, but it does not rehydrate a session the machine has never seen |
| Home Assistant can carry the bytes | A 924 KB session was zipped to 287 KB, chunked, published, reassembled and SHA256-verified through `mqtt.publish` in **1.5 s**, then resumed with full history. Measured on **raw** slice size through entity attributes, so it demonstrates feasibility only - not an encoded-packet limit proof, and not the retention-safe data path this design now specifies |

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

So a transfer moves transcripts and nothing else. The target must already be signed in to
that agent.

**But "signed in" is weaker than it sounds.** `Get-BridgeLauncherUsage` reports
`SignedIn` by testing whether a credential file exists, or whether an API-key environment
variable is set - for Claude, `.credentials.json` or `ANTHROPIC_API_KEY`; for Codex,
`auth.json` or `OPENAI_API_KEY`. That is **presence, not validity**. A file holding an
expired, revoked or - as this very investigation produced - a spent refresh token passes
the check exactly as a working one does.

So the precondition is a cheap filter that prevents the obviously pointless transfer, and
it must be described that way rather than as proof the target can run the agent. The
design has to assume a launch can still fail on authentication *after* a successful
transfer, which means:

* the failure is reported as an authentication problem on the card, naming the agent and
  the machine, not as a failed resume;
* the transferred files are left in place rather than rolled back, so that signing in and
  pressing resume again works without moving the bytes a second time;
* nothing about the source copy is changed on the strength of a launch that never
  happened.

Validating properly would mean asking each agent whether its credentials actually work,
which is an extra per-agent probe with its own cost and failure modes. Worth doing later;
worth not pretending to do now.

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

### Chunk size, and what actually has to be bounded

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

Latency is dominated by polling, not payload size, so larger chunks buy nothing.

**256 KB is the raw slice, not the budget.** A raw slice is only part of what goes on the
wire: base64 inflates it by a third, the JSON envelope adds the sequence, offset, length
and digest fields, and the MQTT packet then carries the topic string and its properties
on top of that. The measurements above were taken on raw input and are therefore *not*
an end-to-end limit proof, which is the honest reading of the outage: a "2 MB" test was
a ~2.8 MB packet.

What must be bounded is the **total encoded packet**, measured and asserted before
publishing, against a configured ceiling well under the broker's. A chunk that would
exceed it is split further rather than sent and hoped for. A publisher that cannot
measure its own packet is not safe at any nominal chunk size, which is the actual lesson
from taking the fleet's MQTT down.

Raising a broker's `max_packet_size` is **not** containment. It is an operator action on
one instance, it does not travel with the product, and a fleet member whose broker has
not been changed would fail exactly as before. The product has to bound itself.

Transcripts compress 3-4x, so the common case is one or two chunks:

| Session | Raw | Compressed | Chunks at 256 KB |
|---|---|---|---|
| Typical | 400 KB - 1.4 MB | 130 - 370 KB | 1 - 2 |
| Large | 13 MB | 3.5 MB | ~14 |
| Pathological (seen in the wild) | 206 MB | 67 MB | ~263 |

### What the recorder keeps, which is the real cost

Clearing a retained topic removes the *retained message*. It does not remove anything
Home Assistant already wrote down.

If chunks arrive as entity attributes - which is how the first prototype read them back,
through `/api/states` - then every chunk is a state change, and the recorder writes each
one to its database. Those rows outlive the topic, land in backups, and are exactly the
transcript content the transfer was carrying. A 14-chunk transfer would deposit several
megabytes of base64 session transcript into the history database of a Home Assistant
instance that also runs the cameras and the vacuum. "We delete the retained topic
afterwards" is not a remedy, and the design should never have implied it was.

That rules out entity attributes as the data path. **Chunks must not become entity
state.** The transport should therefore:

* **publish chunk payloads to topics no discovery config binds to an entity**, so Home
  Assistant never creates a state for them and the recorder has nothing to write; and
* **receive them over Home Assistant's WebSocket API** (`mqtt/subscribe`), which delivers
  messages to a subscriber without creating entities. The bridge already maintains a
  WebSocket connection for its own entity watching, so this is an existing capability
  rather than a new dependency.

Entities stay for what they are good at - the control plane, which is small, legible and
worth recording: the request, the progress line, the outcome.

Three things still need stating explicitly, and are design gates rather than
implementation details:

* **Retention.** Confirm, by inspection rather than assumption, that no chunk payload
  reaches `recorder`, `logbook` or backups by any path - including a stray discovery
  config, a debug log line, or an `attributes` field on the control entities.
* **Privacy and consent.** A transcript archive carries source code, file contents, tool
  output and whatever the user typed, even with credential files excluded. Moving one
  between machines is a data movement the user should be making knowingly, not a side
  effect of choosing an entry in a dropdown. The card should say what is about to move.
* **Bounded staging.** Both ends write temporary files. Those need a bounded location, a
  size ceiling, and cleanup on **every** exit path - success, refusal, digest mismatch,
  source disappearing, target dying mid-transfer - with the cleanup itself tested rather
  than assumed.

### Identity is not ours to invent

A transfer nonce, a machine-name assertion in a payload, and a SHA256 digest are an
addressing scheme and an integrity check. None of them is authentication, and none of
them establishes that the machine asking is allowed to ask.

* A **nonce** correlates a reply with a request. It proves nothing about who sent it.
* A **machine name** in a payload is a self-assertion by whoever published it.
* A **SHA256** proves the bytes arrived intact. It says nothing about who sent them, or
  whether they should have.

Anything that can publish to the broker could therefore request a transcript. That is the
gap, and it is not one this feature should close on its own terms, because an
authenticated command identity/target/expiry/ack contract is owned elsewhere in the
programme. **This design depends on that contract and must not invent a competing one.**
Until it exists, the transfer protocol described here is specified but not authorised to
run on a live fleet.

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

The control plane is entities - small, legible, worth recording. The data plane is not:
chunks go to topics no entity is bound to, and the target receives them over the
WebSocket API, for the retention reasons above.

1. **B** resolves the chosen label, sees the session belongs to **A**, and checks its
   preconditions (below). It picks a workspace from its own approved list, and the card
   states what is about to move.
2. **B** publishes a transfer request naming the session, the launcher and a correlation
   id, under the authenticated command contract owned elsewhere - not a bare nonce.
3. **A** validates the request, **claims a reservation on the session id** with a holder
   and an expiry, and refuses if the session is live locally or already reserved.
4. **A** bundles into bounded staging and publishes a manifest: file list, total size,
   SHA256, chunk count, source agent version, and the encoded size of each chunk.
5. **A** publishes chunk *n* to a non-entity topic, having **measured the encoded packet**
   and split further if it would exceed the budget; **B** acknowledges *n* over the
   control plane; **A** publishes *n+1*.
6. **B** reassembles in bounded staging and **verifies the SHA256 before writing anything
   into its agent home**.
7. **B** re-checks the reservation is still valid, then installs and launches.
8. Both ends clear transfer topics and delete staging - on success, refusal, digest
   mismatch, expiry, and either machine disappearing. **A** releases the reservation.

Step 8 runs on every exit path, not just the happy one. Note what clearing a retained
topic does and does not do: it removes the retained message, not anything the recorder
already wrote, which is why step 5 keeps chunks off the state machine in the first
place.

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
* the session is **not live** anywhere, and a **reservation** is held on it for the whole
  transfer;
* the launcher is **installed**, and its credential file or key is **present** on the
  target - a filter against the obviously pointless, not proof that authentication will
  succeed;
* the bundle is **within the size cap**, and every individual packet is within the
  **encoded packet budget**;
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
  needed and a peer on an older card still renders them;
* a reservation is held for the **whole** transfer: a second request for the same session
  is refused with a reason rather than queued, and a session going live at the keyboard
  mid-transfer stops it;
* a reservation whose holder disappears **expires** rather than stranding the session,
  and the expiry is longer than the largest permitted bundle takes;
* the reservation is re-checked immediately before launch, not only before the first
  chunk;
* **no chunk payload reaches `recorder`, `logbook` or backups** by any path - asserted by
  inspecting the database after a transfer, not by reasoning about topics;
* staging is deleted on every exit path - success, refusal, digest mismatch, expiry,
  source disappearing, target dying - and the cleanup is asserted, not assumed;
* the **encoded packet** is measured before publishing and a chunk that would exceed the
  budget is split rather than sent, including when topic and properties push it over;
* a target whose credential file is present but **invalid** fails as a named
  authentication error, leaves the transferred files in place so a retry needs no second
  transfer, and changes nothing about the source copy;
* clock skew, stale retained peer state and a direct local resume each leave the merged
  list wrong without ever allowing two writers.

## Decisions

### The source copy stays

A move is not destructive: nothing is deleted from the machine the session came from.
That leaves the transcript in two places, so the merged list has to decide which one to
offer.

Each entry carries `Updated`, so the list **displays** the most recently updated copy and
hides the other. That is all it is: a display choice. An earlier draft of this document
claimed a timestamp comparison "cannot drift out of step with reality, because it *is*
reality". That was wrong, and it is worth being explicit about why, because the claim is
seductive:

* **Clocks skew.** `Updated` comes from each machine's own filesystem and is compared
  across machines. A machine minutes ahead wins every tie regardless of what happened.
* **Peer state is retained and can be stale.** A machine that is switched off keeps
  publishing - by retention - the list it had when it left. Nothing about that list is
  current, and a switched-off machine cannot correct it.
* **Direct resumes are invisible until the next publish.** Someone resuming at the
  keyboard changes the truth immediately; the merged list learns at the next refresh.
* **Concurrent transfers have no ordering.** Two machines requesting the same session at
  once both see a consistent-looking list.

So `Updated` orders the *display* and must never be read as ownership, liveness, or
permission to write. Those come from the reservation below, which is a separate
mechanism with separate failure behaviour. Where the two disagree, the reservation wins
and the display is simply out of date.

### One writer per session, for the whole transfer

Acknowledging each chunk makes the *stream* orderly; it does nothing about two transfers
of the same session overlapping, or a transfer racing a direct resume at the keyboard.
The unit that needs excluding is the whole operation - from the moment a bundle is
requested to the moment the target has launched or given up - not the individual chunk.

A transfer therefore takes a **reservation on the session id** before any bytes move, and
holds it across the entire operation:

* The reservation is claimed on the **source**, which is the only machine that can see
  the session's own lock files and local processes, and so the only one that can refuse
  a transfer because the session just went live at the keyboard.
* It carries a holder and an **expiry**, so a target that dies mid-transfer cannot strand
  a session permanently. Expiry must be long enough for the largest permitted bundle.
* It is checked again immediately before the target launches, because a reservation that
  was valid when the first chunk was sent proves nothing by the last one.
* A second request for a reserved session is refused with a reason, not queued.

The reservation is **not** an authentication or ownership mechanism and must not be used
as one - see [Identity is not ours to invent](#identity-is-not-ours-to-invent).

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

## Status

Design only. Not approved for implementation, nor for running on a live fleet.

The evidence here was gathered on the author's own machines before these gates were
agreed. The feasibility findings stand - all three agents are portable, and nothing needs
path rewriting - but the limit measurements are raw rather than end-to-end, and the
prototype read chunks through entity attributes, which is the one thing the retention
section above now rules out. Further probing belongs on a separately scoped disposable
system, not the live fleet.

Two dependencies are outside this document. The authenticated command contract the
transfer protocol needs is owned elsewhere and does not yet exist; until it does, any
publisher on the broker could request a transcript. And the shared daemon files this
would touch - `hooks/daemon-sessions.ps1`, `hooks/decision-mqtt.ps1`,
`hooks/daemon-launch.ps1`, `hooks/agent-bridge-daemon.ps1` - are reserved to other
owners, so implementation needs explicit handoffs that have not been granted.

Merging this document would record the design. It would not grant any of the above.