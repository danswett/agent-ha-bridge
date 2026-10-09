# AI coding agent ⇄ Home Assistant bridge

[![CI](https://github.com/danswett/agent-ha-bridge/actions/workflows/ci.yml/badge.svg)](https://github.com/danswett/agent-ha-bridge/actions/workflows/ci.yml)
[![CodeQL](https://github.com/danswett/agent-ha-bridge/actions/workflows/codeql.yml/badge.svg)](https://github.com/danswett/agent-ha-bridge/actions/workflows/codeql.yml)

Answer your AI coding agent from Home Assistant — or from your terminal — whichever you
happen to be looking at. Works with **GitHub Copilot CLI**, **Claude Code**, **OpenAI
Codex CLI**, and any **MCP client**.

Every live session gets its own card on a Home Assistant dashboard showing what it's
doing, what it just said, and what it's waiting on. When the agent asks a question, the
card grows the matching controls. Whatever you pick is typed into the real terminal
prompt, so the terminal never stops working and nothing is ever answered twice.

> **Windows and macOS.** Answers are typed into the running CLI: on Windows through the
> session's console (`AttachConsole` + `WriteConsoleInput`), on macOS through the tmux
> pane the session runs in. Everything above that - the daemon, the dashboard, how
> replies are confirmed and forms are answered - is the same code on both. The
> [MCP server](mcp/) needs no console at all, so it runs on any OS.

---

## What you get

| | |
|---|---|
| **Dual input** | Answer in the terminal *or* Home Assistant. First one wins; the other clears. |
| **Live activity** | Each session streams its status, current tool, and last response to its card. |
| **Background agents** | A session whose turn has ended while agents it started are still running reads *waiting for N background agents*, not *idle*. |
| **Detailed activity** | Cards carry the model's reasoning and every tool call; fold a session card to keep it short. Off with `detailedActivity: false`. |
| **Real forms** | Every question becomes rows you tap plus a Send button; multi-select questions take as many options as you like. |
| **Continuation** | Reply to a finished turn from your phone; it's typed into the session. |
| **Paste an image** | Paste or attach a screenshot in the reply box and it's attached to the prompt. |
| **Attach a file** | Attach a document, log or diff the same way; up to 256 KB travels in the reply itself. |
| **Start a conversation** | A session appears as soon as it opens, so you can send it its first prompt from the dashboard. |
| **Launch a session** | Pick a workspace, type an opening prompt, press a button — a new CLI session opens on your desktop. |
| **Allowance left** | An **Agent usage** card: how much of each agent's plan or rate-limit window is gone, with a pace mark showing where an even spend would be by now. |
| **End a session** | An **End session** row on every card, so sessions don't just accumulate — and a second press to confirm if it isn't idle. |
| **No polling** | State changes arrive over a Home Assistant WebSocket subscription. |

The card glows **blue** while working, **amber** while waiting on you, and not at all
when idle. A session waiting on background agents it started holds a steady blue edge
without the pulse: live, but not working itself.

---

## Supported clients

| Client | Support |
|---|---|
| **GitHub Copilot CLI** — the origin | The full experience: decisions, live activity, chain-of-thought, multi-field forms, and reply-after-the-turn. Set up by [`install.ps1`](#install). |
| **Claude Code** | The full stack too — the same four primitives, the same card. See [`claude/`](claude/). |
| **OpenAI Codex CLI** | Cards, live activity, command approvals, and the reasoning summary; replies are delivered back into the session. See [`codex/`](codex/). |
| **Any MCP client** — Claude Desktop, ChatGPT, … | The *ask* half only, on any OS: a Home Assistant card races the app's own prompt and cancels whichever loses. Installable from the picker (`-Clients mcp`). See [`mcp/`](mcp/). |

The Windows daemon, dashboard, and Home Assistant plumbing are shared; each client is
just a thin adapter onto them. The installer sets up the shared layer, then asks which
clients to configure — Copilot CLI, Claude Code, Codex CLI, and the MCP server
(detecting what you have). The MCP option installs the Node server and writes a
paste-ready client config (and registers Claude Desktop automatically if it's there),
since MCP clients point at a server rather than loading a hook.

---

## How it works

```
Your AI CLI ──hooks──► bridge scripts ──REST/WS──► Home Assistant
     ▲                                                   │
     └────── console injection ◄─── bridge daemon ◄───────┘
                                    (tails transcripts,
                                     watches entities)
```

The example below is the Copilot CLI path; Claude Code, Codex CLI, and the MCP server
each fill the same three roles — intercept a prompt, stream activity, deliver an answer
— through their own thin adapter.

* **`route-ask-user-v3.ps1`** (`preToolUse`) arms the session's card when Copilot calls
  `ask_user`, then returns immediately. It does **not** block, so the native terminal
  prompt stays live.
* **The daemon** tails every session's transcript for activity, publishes it to Home
  Assistant, and watches the cards. When you answer on a card, it types that answer
  into the session's console.
  On Windows, background CLI discovery and type compilation run without a console:
  after a reply the daemon has none of its own, so anything it starts must be started
  windowless through `Start-BridgeWindowlessProcess` rather than relying on
  `-NoNewWindow` or `-WindowStyle Hidden`. Neither of those survives a console-less
  parent, and an empty PowerShell or Windows Terminal window then flashes up and
  takes the focus on every background probe.
* **The transcript is the source of truth.** A `tool.execution_start` for `ask_user`
  paired with its matching `tool.execution_complete` is the authoritative "answered"
  signal, whichever input produced it — so the two paths can't collide.

Activity tails find complete LF-delimited records in bytes before UTF-8 decoding;
unfinished records, including split characters or CRLF, wait for the next read.
Each read has a fixed bounded window plus at most one look-behind byte. A partial
leading record is skipped, so capped or oversized records are not lossless replay.
Complete records retain normal UTF-8 replacement decoding. Cursors track byte
positions, not file identity: same-size/larger replacement or truncation followed
by regrowth can go undetected. Existing shrink and session-adoption policies remain.

Registration discovery keeps validated live sessions separate from uncertain ownership.
An unreadable or incomplete record does not retire its known owner, clear a pending
decision, or let an older retirement queue delete it; valid neighboring sessions still
stream activity. Incomplete discovery conservatively holds absence-based cleanup,
launch/resume decisions and complete global-inventory/dashboard replacement while
observing the actual accepted view. Existing cards keep updating, but a newly adopted
card may wait for completeness. A successful reread, including repair at the same file
timestamp, resumes held work without a restart; a skipped operation is not cached as
published. This does not promise atomic registration writes or file-identity recovery.

**The hooks are fast.** An agent waits for every hook, and starting PowerShell alone
takes a quarter of a second, so each hook is a small native program,
`agent-bridge-hook`, that hands the event to the daemon and returns in tens of
milliseconds (Codex's tool-call hook went from 553 ms to 38 ms). The daemon then runs
the same PowerShell code the hook would have. When the daemon is not running the
program runs the PowerShell hook itself, and on a machine without the program the
agents keep their PowerShell hooks - so the bridge works the same either way, only
slower. See [docs/fast-hooks.md](docs/fast-hooks.md).

Entities are created on demand per session through **MQTT discovery**, published via
Home Assistant's own `mqtt.publish` service. **No MQTT broker credentials are needed** —
only a Home Assistant token.

---

## Requirements

* Windows 10/11 and **PowerShell 7+** — the installer offers to install it if you
  don't have it, including when you paste the one-liner into Windows PowerShell
* or macOS 13+ with **PowerShell 7+** and **tmux** — the macOS one-liner installs both
  (through Homebrew on Apple silicon, Microsoft's package and MacPorts on Intel)
* At least one supported client. The installer asks which of
  **[GitHub Copilot CLI](https://docs.github.com/copilot/how-tos/use-copilot-agents/use-copilot-cli)**,
  **Claude Code**, **Codex CLI** and the **MCP server** to configure (detecting what
  you have), and offers to install any you picked but don't have yet. MCP additionally
  needs **Node.js**, and works with any MCP client ([`mcp/`](mcp/))
* Home Assistant with the **MQTT integration** configured (any broker)
* A Home Assistant **long-lived access token**
* These HACS frontend cards:
  [`card-mod`](https://github.com/thomasloven/lovelace-card-mod),
  [`button-card`](https://github.com/custom-cards/button-card),
  [`layout-card`](https://github.com/thomasloven/lovelace-layout-card).
  The installer checks for these and tells you which are missing — and registers any
  that you have downloaded but not added as a Lovelace resource
* The bridge's own card is published as an inline Lovelace resource by the designated
  writer after [explicit publication bootstrap](#publication-authority-and-migration).
  No file share, Samba add-on or file-share credentials are needed

---

## Install

The one-liner:

```powershell
irm https://raw.githubusercontent.com/danswett/agent-ha-bridge/main/bootstrap.ps1 | iex
```

It installs the **latest published release**, never unreleased code. To pin a release,
or to try a branch before it ships, run the script with an argument:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/danswett/agent-ha-bridge/main/bootstrap.ps1))) -Version 1.32.3
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/danswett/agent-ha-bridge/main/bootstrap.ps1))) -Branch main
```

Or from a clone, which installs whatever is checked out:

```powershell
git clone https://github.com/danswett/agent-ha-bridge.git
cd agent-ha-bridge
.\install.ps1
```

**Shared publication needs an explicit writer.** Installation can report sessions
without taking ownership of the shared card or dashboard. A first setup, or an
upgrade from a build without publication fences, needs the operator's
[publication configuration and one-shot bootstrap](#publication-authority-and-migration).
Existing unfenced contents are preserved until that migration is authorized.

### macOS

> **Preview.** macOS support passes the full test suite on macOS in CI, including
> replies typed into a live tmux session, but has not yet had much use on real Macs.
> Please report anything that misbehaves, with the output of `agent-ha-bridge logs`.

The one-liner, in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/danswett/agent-ha-bridge/main/bootstrap.sh | bash
```

It installs what is missing, then hands over to the latest release's installer, which
asks the same questions. Put `BRIDGE_VERSION=1.32.3` or `BRANCH=main` before `bash` to
pin a release or try a branch. From a clone it is `pwsh ./install.ps1`.

* **Apple silicon:** PowerShell 7 and tmux come from [Homebrew](https://brew.sh),
  which it offers to install first.
* **Intel:** Homebrew no longer supports Intel Macs, so PowerShell comes from
  Microsoft's own package (falling back to 7.4, the long-term release, if the newest
  needs a later macOS), and tmux from [MacPorts](https://www.macports.org) - offered
  too, along with Apple's command line tools it needs. An Intel Mac that already has
  a working Homebrew keeps using it.

Installing any of these asks for your Mac password.

What differs on a Mac:

* **Sessions run in tmux.** That is how the dashboard types into them. Sessions it
  launches are started in tmux and shown in a Terminal window attached to it (iTerm
  with `platform.terminal: iTerm`, or no window with `none`). For a session you start
  yourself, start it inside tmux - `tmux new claude` - or its card still shows
  everything but the reply box cannot reach it.
* **The first launch asks for permission.** macOS asks once whether PowerShell may
  control Terminal, which is how the window is opened. Allow it.
* **The daemon is a LaunchAgent** (`com.agent-ha-bridge.daemon`) rather than a
  scheduled task: it starts at login and launchd restarts it if it exits.
  `agent-ha-bridge restart` loads it if something has left it unloaded, rather than
  sending you back to `configure`.
* **`agent-ha-bridge` goes on your PATH through `~/.zprofile`**; open a new terminal
  to use it.

Nothing is a hard prerequisite except Windows itself. If **PowerShell 7** is missing
the installer offers to install it with winget and hands the install over to it —
`bootstrap.ps1` is deliberately Windows PowerShell 5.1 compatible so the offer works
where `pwsh` doesn't exist yet. Decline anything and you get the exact command to run
later instead of a dead end; `-SkipDependencies` turns the offers off entirely.

It then asks **which clients to configure** — Copilot CLI, Claude Code, Codex CLI, and
the MCP server — pre-selecting the ones it detects, and offering to install any you
chose that aren't there yet (`npm install -g` for the CLIs, winget for Node). The
shared daemon, dashboard and Home Assistant plumbing are installed either way; the
choice only decides which adapters get set up. Pick them non-interactively with
`-Clients`:

```powershell
.\install.ps1 -Clients copilot,claude,mcp
```

Your selection is remembered, so a re-run or a self-update reconfigures the same set.
Choosing **mcp** installs the Node server, writes a paste-ready client config to
`~/.agent-ha-bridge/mcp/mcp-client-config.json`, and registers Claude Desktop automatically if
it's present; other MCP clients (Cursor, ChatGPT) use the snippet — see
[`mcp/README.md`](mcp/README.md).

It also settles **which folders a launch may open**. The dashboard can only start a
session in a directory the config approves, so it checks the configured list against
this machine and asks if none of those folders are here, offering the conventional code
roots under your home. Set it outright with `-Workspace`, which skips the question:

```powershell
.\install.ps1 -Workspace ~/repos, ~/work
```

On a first setup it finds Home Assistant: it probes `homeassistant.local:8123` (the hostname Home
Assistant publishes over mDNS, which Windows resolves natively) and confirms the
product from its unauthenticated `manifest.json`. **If that works it just uses it** —
it doesn't ask you to confirm a question it already answered. You're only prompted for
a URL when nothing responded. It then walks you through creating a long-lived token,
and immediately shows you what you connected to:

```
==> Connecting to Home Assistant
    connected to http://homeassistant.local:8123 - 303 Home 2026.9.3
    mqtt.publish available
```

A token that doesn't work is reported there and then, with another go at pasting it
into a masked prompt, rather than failing at the end of the install.

An existing configured endpoint is never replaced by discovery, even when it is
offline or its DNS/TLS probe fails. Use `agent-ha-bridge configure -HomeAssistantUrl
<intended-url>` to deliberately change it; this explicitly authorizes using the
configured credentials at that URL. Installer verification does not follow redirects.
HTTP on a trusted LAN remains supported, with the existing unencrypted-token warning.

Last it checks the three custom Lovelace cards the dashboard is drawn with. Without
them the dashboard renders as a column of *Custom element doesn't exist* boxes — an
install that reports success and visibly does not work. A card needs two separate
things: the JavaScript downloaded to the Home Assistant host, which only HACS can do,
and a Lovelace resource pointing at it, which is one WebSocket command — so the second
half is repaired automatically, and the first is reported with the HACS repository to
install.

It also puts an **`agent-ha-bridge` command on your PATH** and registers in **Apps &
features**, so it uninstalls like any other program. No installer executable, no admin
rights, and no SmartScreen warning.

If you already know the details, skip the prompts entirely:

```powershell
.\install.ps1 -HomeAssistantUrl http://homeassistant.local:8123 -NonInteractive
```

For unattended setup, supply `AGENT_HA_TOKEN` through your process's secret/environment
configuration. `-Token` and `-AgentToken` remain supported, but their values can appear
in shell history, process listings, and automation logs; do not put literal secrets
in a command line. Omitting `-NonInteractive` lets the installer mask token entry.
Redirected stdin remains supported and is read without echoing the token.

Then `/restart` any running Copilot sessions so they pick up the hooks, and open the
**Agent Sessions** dashboard in Home Assistant.

Optional out-of-band push when a session needs you:

```powershell
.\install.ps1 -NotifyService notify.mobile_app_pixel
```

The installer is idempotent — re-run it to upgrade in place. Re-running with only
some arguments keeps the rest of your settings, and the previous config is backed up
to `config.json.bak` first. A config written by an older version has any keys it is
missing filled in from the defaults. An unreadable existing config is backed up and
reported without echoing its contents; repair it or explicitly provide
`-HomeAssistantUrl` before replacing it with defaults. A missing endpoint in an
existing config also requires an explicit URL rather than discovery.

It is **not interactive** when you pass `-NonInteractive`, which is what you want in a
script; otherwise it prompts for anything missing. Use `-SkipVerify` for an offline
install, or when the token comes from an environment variable that isn't set yet, and
`-SkipPath` to leave PATH alone.

To try a build without touching a working install, point it at a sandbox:

```powershell
.\install.ps1 -HomeAssistantUrl http://ha.example:8123 -Token test `
              -TargetHome $env:TEMP\bridge-sandbox -SkipTask -SkipVerify
```

`-TargetHome` also keeps the sandbox off your PATH, so its copy of the command can
never act on the real install.

### The `agent-ha-bridge` command

Installing puts `agent-ha-bridge` on your PATH, and copies the installer to
`~/.agent-ha-bridge/installer`. That is how you change anything later — **you do not
need the repository**, which matters because the one-liner doesn't leave one behind:

```powershell
agent-ha-bridge                 # same as `status`
agent-ha-bridge configure       # re-run the installer, keeping your settings as defaults
agent-ha-bridge status          # install, daemon, Home Assistant connection, cards and machines
agent-ha-bridge restart         # restart the bridge daemon
agent-ha-bridge logs -Follow    # tail the daemon log
agent-ha-bridge update          # check for a newer release and offer to install it
agent-ha-bridge uninstall       # remove the bridge
agent-ha-bridge help
```

Anything after the command goes straight to the underlying script, as a normal named
parameter — so `agent-ha-bridge configure -Clients copilot,claude` and
`agent-ha-bridge configure -NotifyService notify.mobile_app_pixel` both work.
`--configure` and `/configure` are accepted too.

### Configuration

Settings live in `~/.agent-ha-bridge/config.json` (written by the installer,
never in the repo). See [`config.example.json`](config.example.json).

| Key | Meaning |
|---|---|
| `homeAssistant.baseUrl` | e.g. `http://homeassistant.local:8123` |
| `homeAssistant.token` | Long-lived access token |
| `homeAssistant.tokenEnvVar` | Read the token from this env var instead (default `AGENT_HA_TOKEN`; `COPILOT_HA_TOKEN` still works) |
| `homeAssistant.agentUserIds` | Home Assistant user ids that count as an agent rather than you. A session an agent starts or replies to gets a purple edge on its card, so a session being driven remotely says so at a glance. Written for you from `agentToken` — see [Telling an agent's turn from yours](#telling-an-agents-turn-from-yours) |
| `homeAssistant.agentToken` | A long-lived token for a *separate* Home Assistant account standing for the agent. Handed to every session the bridge launches, so an agent driving another session does so as itself; the daemon, the hooks and the MCP server keep using `homeAssistant.token`. Set it with `agent-ha-bridge configure -AgentToken <token>`, which also fills in `agentUserIds` |
| `homeAssistant.agentTokenEnvVar` | Read the agent token from this env var instead (default `AGENT_HA_AGENT_TOKEN`) |
| `dashboard.urlPath` | Lovelace dashboard slug (default `agent-decisions`) |
| `dashboard.publication.authority` | Explicit, stable, non-secret identity for the shared publication policy; no inferred default |
| `dashboard.publication.participant` | This installation's explicit publication identity; do not derive authority from a hostname or installation path |
| `dashboard.publication.writer` | The one designated publisher's identity, shared by participating configurations; only that participant may write |
| `dashboard.publication.generation` | Explicit positive integer policy generation. A manual policy change requires exactly the next generation; ordinary publication must match the established generation |
| `notifications.enabled` / `.service` | Optional notify-style service |
| `copilot.sessionStateRoot` | Override the Copilot CLI's session-state location if not `~/.copilot/session-state` |
| `newSession.enabled` | Set to `false` to hide the "Start a new session" controls (default `true`) |
| `newSession.launcher` | Default agent: `auto` (default: the installed agent used most recently on this machine, else one that is signed in), `agency`, `copilot`, `claude` or `codex`. With more than one installed, the card also gets an Agent dropdown |
| `newSession.codexStartPrompt` | The first message a Codex launched without one is given, so it creates its session and attaches. Empty: the launch waits for a first message sent from the card |
| `detailedActivity` | `true` (default): cards carry reasoning and each tool call. `false`: status and responses only |
| `platform.terminal` | macOS: the window a launched session opens in - `Terminal` (default), `iTerm`, or `none` (the session still runs; `tmux attach` reaches it) |
| `newSession.profiles` | Restrict which Agency profiles the dashboard offers, and in what order (default: all of them, read from `agency config profiles`). Names this machine's Agency does not have are dropped |
| `newSession.defaultProfile` | Profile preselected on the card (default: the first offered) |
| `newSession.defaultWorkspace` | Workspace label preselected on the card (default: the first in `workspaces`) |
| `newSession.workspaces` | Explicitly approved launch directories: a path string, or `{ "label": …, "path": … }`. Add the Boolean `"isolate": true` for a separate git worktree on each fresh launch. Discovery and an empty list never implicitly approve another directory. The installer checks this list against the disk and approves a real folder when none of it exists here, so a fresh machine never starts with an empty card |
| `newSession.worktreeRoot` | Where isolated launches get their worktrees (default `~/repos/wt`). A private marker in Git's administration directory identifies managed worktrees; a directory name alone does not grant cleanup ownership |
| `newSession.worktreeLimit` | Maximum bridge-managed worktrees per repository (default `10`). At the cap, requested isolation refuses the launch with a diagnostic; it never falls back to the primary checkout |
| `newSession.worktreeIdleHours` | How old a finished worktree must be before it is removed (default `12`) |
| `newSession.discoverWorkspaces` | Controls the explicitly invoked `Get-BridgeDiscoveredWorkspaces` helper (default `true`), not the launch card. Use the [read-only suggestion command](docs/installation-isolation.md#listing-workspace-suggestions), then explicitly configure any chosen folder. System folders such as `C:\Windows\System32` are excluded |
| `newSession.discoverCount` | Maximum suggestions returned by that helper (default `8`). It does not populate the launch card or limit cleanup's liveness checks |
| `newSession.resumeCount` | How many recent sessions the Resume dropdown offers (default `12`) |
| `newSession.model` | Model preselected on the card (default: **Agent default** — the CLI's own choice). Applies to Copilot and Agency; `newSession.model.claude` / `.codex` do the same per agent |
| `newSession.effort.<agent>` / `.context.<agent>` | Reasoning effort and context window preselected on the card, per agent (`copilot`, `claude`, `codex`; Agency reads Copilot's) |
| `newSession.models.<agent>` | Replace the model list the card offers, e.g. `"models": { "copilot": ["auto", "claude-opus-5"] }`. Copilot's is otherwise read from `copilot help config`; `efforts.<agent>` and `contexts.<agent>` do the same for the other two axes |
| `newSession.allowAllTools` | What the card's **Permissions** row opens on (default `false`). **Allow all** launches without permission prompts: `--allow-all` for Copilot, `--dangerously-skip-permissions` for Claude, `--ask-for-approval never` for Codex, and it answers Claude's folder-trust dialog rather than waiting for a second press. The card decides each launch, so a session started on another machine no longer silently takes that machine's setting |
| `newSession.extraArgs` | Extra CLI arguments for launched sessions, e.g. `["--plan"]` |
| `newSession.copilotPath` | Full path to `copilot.exe` if it is not on the daemon's PATH |
| `newSession.agencyPath` | Full path to `agency.exe` if it is not on the daemon's PATH |
| `newSession.claudePath` / `.codexPath` | Full path to `claude.exe` / the Codex CLI if not on the daemon's PATH |
| `devBox.keepAwake` | On a Microsoft Dev Box, keep the machine from hibernating itself while the bridge runs (default `false`; you are asked once on a Dev Box). See [Running on a Microsoft Dev Box](#running-on-a-microsoft-dev-box) |
| `devBox.intervalMinutes` | How often the keep-awake task runs (default `15`, capped at `30`). It has to be shorter than the pool's stop-on-disconnect grace period, since the pending stop only exists inside that window |
| `updates.repository` | Repository to check for releases (default `danswett/agent-ha-bridge`) |
| `updates.checkForUpdates` | Set to `false` to disable the update check |
| `updates.checkHours` | How often to check GitHub for a release (default `6`, i.e. 4×/day) |
| `updates.token` | Optional GitHub token for release checks only, sent to `api.github.com` and never logged. Unauthenticated callers share **60 requests an hour per IP**, so a Dev Box or anything else behind shared egress can be refused without the bridge having made a request of its own. `AGENT_HA_BRIDGE_UPDATE_TOKEN`, `GH_TOKEN` or `GITHUB_TOKEN` in the environment are used too, in that order, when the setting is empty - a machine that already has one needs no configuration. If a token is rejected as bad credentials, the check is retried without one rather than failing - an ambient `GITHUB_TOKEN` expires when its workflow job ends, and these are public releases. A read-only token with no scopes is enough for them |
| `usage.publish` | Set to `false` to stop collecting and publishing each agent's remaining allowance (default `true`). This stops the vendor calls, not just the card |
| `usage.intervalSeconds` | How often to re-read the allowances (default `120`). Copilot's figure moves continuously while a session runs, so this is a poll rather than a cache read |
| `usage.keychain` | Set to `true` to let the Copilot allowance read its token from the macOS login keychain (default `false`). Off because the read raises an authorization panel that **Always Allow** cannot silence — the CLI replaces the item on every token refresh, so each grant outlives its item by minutes. `COPILOT_GITHUB_TOKEN`, `GH_TOKEN` or `GITHUB_TOKEN` get the same figure without prompting. No effect on Windows, which reads the credential store silently |

Prefer keeping tokens out of a file? Leave `token` / `agentToken` empty and set the
variables named by `tokenEnvVar` / `agentTokenEnvVar` in the environment of each process
that needs them. Verification saves an environment-only agent's user ID, not its token.
Environment-only credentials must also be available when the daemon or MCP client
starts; a terminal's temporary environment does not automatically reach a desktop app.

The installer protects main configs, MCP snippets, Claude Desktop configs, and their
owned backups before writing: owner-only ACLs on Windows, `0600` files and `0700` new
credential directories on Unix. When the .NET Unix mode APIs are unavailable, the
credential helper uses the OS's `stat` and `chmod` and verifies the resulting mode.
Protection failures stop the write instead of
reporting success. Generated MCP entries reference the protected bridge config via
`HA_BRIDGE_CONFIG`, so neither saved nor environment-only tokens are copied into
the snippet. Existing saved credentials are still plaintext in the protected main
config; OS protection is not encryption and does not exclude administrators.
Installer credential-file targets must be regular files, not symlinks or reparse
points; use the actual protected config location rather than a linked file.

MCP removal strips this install's registration from Claude Desktop and its `.bak`
without replacing unrelated settings. Copies pasted into other clients or backups
made by other software must be removed there manually. `-KeepConfig` deliberately
retains the main config and its backup; removing an adapter does not revoke HA tokens.

### Running on a Microsoft Dev Box

A Dev Box pool commonly has **stop-on-disconnect** enabled, and when it does the Dev
Box agent hibernates the machine a set number of minutes after your last RDP or tunnel
session goes away. Idleness there is measured by *sessions*, not by load, so a Dev Box
busy running the daemon and several agent sessions looks exactly as idle as one doing
nothing. The daemon stops mid-reconcile, its liveness beat stops, and the machine shows
as offline on the dashboard with nothing anywhere saying why.

The installer detects a Dev Box and offers to register a second scheduled task,
`AgentBridgeDevBoxKeepAwake_<installation-id>`, which clears the pending stop every 15 minutes through
Dev Center's own API:

```powershell
.\install.ps1 -DevBoxKeepAwake          # or answer the prompt
.\install.ps1 -DevBoxKeepAwake:$false   # turn it off again; the task is removed
```

It uses the documented, **user-scoped** developer API (`users/me`) and your existing
Azure CLI login — nothing is reconfigured on the Dev Box agent, and the agent keeps
reporting health as normal. Each pass asks Dev Center to skip the pending stop, falling
back to delaying it as far as the service allows. Two service limits are why it runs on
a timer rather than once:

- a delay may not exceed **8 hours past where the action originally landed**, so delays
  do not stack;
- **neither lever works while the stop is more than 24 hours away** — which is the state
  worth reaching, so the task reports that as already safe and does nothing.

The cadence matters more than it looks. A stop-on-disconnect occurrence does not exist
while you are connected: the pool creates it when your last session goes and fires it
one grace period later, so a pass that runs less often than that grace can miss the
window entirely and never see anything to clear. The grace is never shorter than 60
minutes, hence the 15-minute default and the 30-minute cap on `devBox.intervalMinutes`.
A pass with nothing scheduled logs `no-action`; that is the normal state while you are
connected, not a failure.

The task and its detached PowerShell worker belong to the recorded installation.
Removal stops that owned worker before deleting its payload; isolated/custom-root
installs do not register or remove shared tasks. The installation ID is stored in
`installation.json` beside the bridge config.

Passes are logged to `~\.agent-ha-bridge\runtime\agent-bridge-devbox-keepawake.log`
for the default installation. To see what it would
do without changing anything:

```powershell
pwsh -File ~\.agent-ha-bridge\hooks\agent-bridge-devbox-keepawake.ps1 -DryRun
```

Requirements: the Azure CLI, signed in as you (`az login`). If that login expires the
task logs it and exits non-zero rather than failing quietly, because a silent failure
here looks exactly like the Dev Box hibernating for no reason.

This is a per-occurrence reprieve, not a policy change. The durable fix is for whoever
administers the pool to raise `gracePeriodMinutes` (up to 480) or disable
stop-on-disconnect; you can read the current setting yourself with:

```powershell
$t = az account get-access-token --resource https://devcenter.azure.com --query accessToken -o tsv
Invoke-RestMethod -Headers @{ Authorization = "Bearer $t" } `
  -Uri "$devCenterUri/projects/$project/pools/$pool?api-version=2024-02-01" |
  Select-Object -ExpandProperty stopOnDisconnect
```

Keeping a Dev Box awake around the clock has a real cost, so it is off unless you turn
it on.

### Telling an agent's turn from yours

An agent can drive a session on another machine through the same entities the
dashboard uses: set `text.…_reply`, press `button.…_submit`, read `sensor.…_activity`.
That is useful — it is how a session on a Mac can be debugged from a Windows box — but
it means the bridge cannot tell an agent's reply from yours. Both arrive as the same
two service calls, carrying the same Home Assistant account, because the dashboard and
the API are the same door.

Giving the agent its own account is what makes the difference real:

1. *Settings → People → Add person*, with **Allow login** on. Call it whatever you
   like — `Copilot`, say — and make it a non-administrator.
2. Log in as that user once (a private browser window is easiest) and create a
   long-lived token for it (*Profile → Security → Long-lived access tokens*).
3. Hand it to the installer:

   ```powershell
   agent-ha-bridge configure
   ```

   Use the optional masked agent-token prompt. A protected `homeAssistant.agentToken`
   in the config, or the `AGENT_HA_AGENT_TOKEN` environment variable, does the same.
   Automated `-AgentToken` input remains supported with the command-line risks above.

That is the whole setup — there is no user id to copy. The installer reads the account
back off the token (`auth/current_user`) and writes `agentUserIds` itself, because that
was the one step in this flow with a silent wrong answer available: a long-lived token
is a JWT whose `iss` claim looks exactly like a user id but is the *refresh token's*
id, and using it means nothing is ever marked and nothing ever says why.

It also refuses two tokens rather than storing them to fail quietly later: one Home
Assistant rejects, and one belonging to *your own* account — which authenticates
perfectly and can never mark anything.
Secure account verification requires PowerShell 7.3 or newer so WebSocket redirects
can be disabled. Older runtimes report the limitation without sending an agent token.

Your own `homeAssistant.token` is left alone; the daemon, the hooks and the dashboard
provisioning still run as you. The agent token goes into the environment of every
session the bridge launches (`AGENT_HA_AGENT_TOKEN`), so an agent that goes on to
drive another session does so as itself.

A token in the environment is only half of it, though: an agent has to know it should
reach for that one rather than yours, and an agent driving the bridge is nearly always
working in some unrelated repository, so this repository's `AGENTS.md` never reaches
it. A Copilot install therefore also writes
`~/.copilot/instructions/agent-ha-bridge.instructions.md` — a file the CLI reads in
every session, wherever it is working. It is short, it says which token writes and
where a session's answer is read back from, and it is removed on uninstall. Your own
`~/.copilot/copilot-instructions.md` is never touched.

**A non-administrator is genuinely enough**, and the split is deliberate. Driving a
session is service calls and state reads, both of which a plain user may do. The MCP
server keeps the user's token for *provisioning* — it renames entities
to deterministic ids and creates its own dashboard, and `config/entity_registry/update`,
`lovelace/dashboards/create` and `lovelace/config/save` all return `unauthorized` to a
plain user (measured against a real instance, with `config/auth/list` as the control).
Its session reply/launch tools use the separate agent token when configured; they do
not need the user's administrator privileges.

A session an agent starts or replies to is drawn with a purple edge — steady while
idle, pulsing while it works — and hands back to the ordinary colours the moment you
reply yourself or type in the session's own window. With nothing configured nothing is
ever marked, which is deliberate: a glow that lies is worse than no glow.

The same change makes Home Assistant's own logbook honest, since those actions are
then attributed to the agent rather than to you.

---

## Home Assistant setup

There is **no config flow** — the bridge is a set of Windows-side scripts, not a Home
Assistant integration, so it never appears under *Settings → Devices & Services*. It
authenticates with a long-lived token. Session/machine reporting and shared publication
have separate prerequisites:

| Object | How it appears |
|---|---|
| Per-session entities (`select`, `text`, `sensor`, `button`) | MQTT discovery on demand; retirement waits until verified shared output no longer renders the ended session |
| `sensor.agent_bridge_sessions` | MQTT discovery, published by the daemon |
| New-session controls (`text`, `select`, `button`, `sensor`) | MQTT discovery, on the same bridge-level device as the update entity |
| Shared reply card and publication-policy resource | Explicit operator bootstrap, then guarded publication by the designated writer |
| The **Agent Sessions** dashboard (`agent-decisions`) | Generated and repaired by the designated writer; currentness is checked against actual accepted shared output |

### Entity ids are `agent_bridge_*`

Everything is namespaced `agent_bridge_`, including per-session entities
(`sensor.agent_bridge_<id>_status`). That is deliberate: the bridge serves Claude Code,
Codex and MCP clients as well as Copilot CLI, and the old `copilot_*` ids described a
Claude session as a Copilot one.

Upgrading from a build that used `copilot_cli_*` renames them for you. The daemon
clears the old retained discovery configs on its first start, so the previous entities
disappear rather than lingering unavailable beside their replacements.

The generated dashboard follows automatically. **Any automations, scripts or templates
you wrote against the old ids need updating** — check *Settings → Automations* if you
built anything on them.

### Upgrading from `copilot-ha-bridge`

The project was called `copilot-ha-bridge` until it grew past Copilot CLI. Everything
it installs now carries the neutral name, and re-running `install.ps1` migrates an
existing setup's files and configuration:

| Before | Now |
|---|---|
| `~/.copilot/hooks/*.ps1` (shared scripts) | `~/.agent-ha-bridge/hooks/` |
| `~/.copilot/copilot-ha-bridge.config.json` | `~/.agent-ha-bridge/config.json` |
| `~/.copilot/mcp`, `~/.copilot/codex-bridge` | `~/.agent-ha-bridge/mcp`, `.../codex-bridge` |
| Scheduled task `CopilotBridgeDaemon` | `AgentBridgeDaemon_<installation-id>` |
| Dashboard `/copilot-decisions` | `/agent-decisions` |
| `%TEMP%\copilot-decision-bridge.log` | `~\.agent-ha-bridge\runtime\agent-decision-bridge.log` |
| `$env:COPILOT_HA_BRIDGE_CONFIG` | `$env:AGENT_HA_BRIDGE_CONFIG` |

Your Home Assistant token is moved, not re-requested, so the upgrade never prompts for
it again. The old scheduled task and Apps & features entry are removed. The old
dashboard is retired only after the explicitly authorized publisher has saved and
verified `/agent-decisions` — **re-pin it in the sidebar** after that transition if
you had it placed. A file/configuration migration does not bootstrap publication
authority. `~/.copilot` keeps only what belongs to the Copilot CLI: its hook
definition and its session transcripts.

Entity ids do not change, so automations built on `agent_bridge_*` keep working. The
old `$env:COPILOT_HA_BRIDGE_CONFIG` and config path are still read as a fallback, so a
machine that has not been upgraded yet keeps running.

Current installations record their local identity and roots in `installation.json`.
Verified legacy task registrations are retired during upgrade; an unrelated task
with a historical name is not claimed by name alone. See
[installation ownership](docs/installation-isolation.md) for custom-root and
pre-metadata compatibility.

### There is no MQTT broker to configure

The bridge **never connects to your broker** — no host, port, or credentials anywhere.
It has no MQTT client at all. Every entity is published by calling Home Assistant's own
`mqtt.publish` service over the REST API, so Home Assistant owns the broker connection
and the bridge only ever needs its token.

That means the MQTT integration is the one prerequisite it cannot provision itself. The
installer checks for it and warns if `mqtt.publish` is missing. Nothing goes in
`configuration.yaml`.

`uninstall.ps1 -ClearEntities` reverses all of it. The helper and the dashboard are
shared with any other machine on the same Home Assistant, so they only go when the last
machine is removed.

---

## Starting a session from the dashboard

Everything else in the bridge attaches to sessions you already started at a keyboard.
The **Start a new session** card opens one — or reopens an old one.

Both selectors carry a default, so the whole thing is one button press: open the card,
press **Launch**. Nothing has to be filled in first.

| Row | What it does |
|---|---|
| **Resume** | `New session` (the default), or one of your recent resumable sessions |
| **Workspace** | Where a new session starts. Ignored for a resume, which reopens in its own folder |
| **Profile** | The Agency profile, applied to new and resumed sessions alike. Only the profiles that machine's Agency actually has, so the row is absent on one that has none |
| **Launch** | Starts it |
| **Last launch** | What the previous press actually did |
| **Opening prompt** | Optional. A first instruction, if you want one |

A session opens in its own console window on the desktop, which the daemon then adopts
like any other — it gets the usual card, activity stream, reply box and decision
prompts. Because the window is real and visible, you can also walk over and take the
session over at the keyboard.

### Resuming

The list comes from `agency hub list-local-sessions`, which is the only thing that
knows about every session on the machine and which of them can actually be resumed —
desktop-app and VS Code sessions cannot. That call reads hundreds of sessions and takes
over a second, so the daemon caches it (`newSession.resumeCount` controls how many are
offered) and refreshes it on a timer rather than on every reconcile.

Sessions that are currently live are never offered, because two CLIs writing one
transcript would corrupt it. A resume reopens in the folder the session originally ran
in; the Workspace row only applies to a new session.

### Model, effort and context

The card carries three more dropdowns: **Model**, **Effort** and **Context**. Each
opens on *Agent default*, which passes no flag at all and lets the CLI use whatever it
has persisted, so a launch that ignores them behaves exactly as it did before.

They belong to the agent selected above them, and the daemon republishes their options
whenever that selection moves — pick Claude and the model list becomes Claude's. What
each one drives:

| | Copilot / Agency | Claude | Codex |
|---|---|---|---|
| Model | `--model` | `--model` | `--model` |
| Effort | `--reasoning-effort` | `--effort` | `-c model_reasoning_effort=` |
| Context | `--context` | `--autocompact` | `-c model_context_window=` |

Claude has no context-window switch; `--autocompact`, which sets the window it compacts
at, is the nearest equivalent and is what its Context row offers (`auto`, `200k`, `500k`,
`1m`).

Copilot's model list is read from `copilot help config` and cached for half an hour, so
it stays current as models come and go. The other two ship with a short built-in list,
which `newSession.models.<agent>` replaces — worth doing for Copilot too, since
twenty-six options on a phone is a scroll rather than a choice.

A value arriving from Home Assistant is validated against that agent's list before it
reaches a command line, exactly as a workspace label is. An unrecognised one quietly
means "agent default" rather than refusing the launch, because a selector left over
from a different agent is ordinary rather than suspicious.

Each session's card shows what it is running with, in small type just above **End
session**.

The **Model** comes from the session itself: all three agents stamp it on every
message they write, so a session shows its model whether the bridge launched it or
you started it at a keyboard, and a `/model` typed into the window is picked up within
a turn. **Effort** and **Context** can only be what the launch asked for — they appear
in no transcript and no agent reports them back, so the command line the bridge built
is the only record. A session started at a keyboard therefore shows a model and
nothing else, which is better than guessing at the rest.

### Agency

On a machine with [Agency](https://aka.ms/agency), sessions launch through
`agency copilot` by default, so they match what you get launching by hand. That matters
more than it sounds: Agency's `--profile-only` makes the named profile the *whole*
configuration and ignores ambient MCP sources like `~/.copilot/mcp-config.json`, so a
session gets the curated set of MCP servers and plugins for that profile rather than
every server on the machine.

Because the same directory is routinely opened under different profiles, the profile is
its own dropdown rather than a property of the workspace. Set `newSession.launcher` to
`copilot` to bypass Agency entirely; the profile and resume rows then disappear from
the card.

The dropdown offers what `agency config profiles` reports on that machine, refreshed
every ten minutes, so it can only name a profile that exists there. A machine whose
Agency has none — a newly set-up one, before whatever syncs your Agency config has run
on it — gets no Profile row, and its launches pass no profile and use Agency's base
configuration. This matters because `agency copilot --profile-only work` on a machine
with no `work` profile exits before Copilot starts, and the window closes too fast to
read the error.

Agency takes `--session-id` itself and uses that UUID for both its own session and the
underlying Copilot one, so the daemon still knows the session id before the process
starts either way.

The installer settles the workspace list, so a new machine has something to launch in
without any JSON editing. It checks each configured directory against the disk, and if
none of them are here it asks which folders to approve — offering the conventional code
roots under your home, and your home itself — then writes the answer to the config. An
unattended run takes those same folders without asking. So the usual reason to edit this
by hand is to add a repository the installer did not suggest, or to turn on `isolate`:

```jsonc
"newSession": {
  "workspaces": [
    { "label": "Bridge", "path": "~/repos/agent-ha-bridge", "isolate": true },
    "~/repos/my-app"
  ]
}
```

Pass `-Workspace` to set it outright, which skips the question and fails if a folder is
not there:

```powershell
agent-ha-bridge configure -Workspace ~/repos/my-app,~/work
```

Commas with no spaces around them: every argument reaches the installer as one literal
string, so `~/repos/my-app, ~/work` would arrive as a single mangled path. Running
`install.ps1` directly from a PowerShell prompt takes an ordinary array
(`-Workspace ~/repos, ~/work`) because PowerShell parses it before the script sees it.

If the card ever does say **No workspaces configured**, it means every directory in the
list is missing on that machine — a renamed folder, or an unmounted volume. Run
`agent-ha-bridge configure` there and it is repaired; a machine you cannot reach can be
updated from Home Assistant with its **Install update** button instead.

A few deliberate choices:

- **Only listed directories can be launched.** The dropdown sends a *label*, and the
  daemon resolves that label against this list. A path typed or injected anywhere else
  is never executed, so the config file — not Home Assistant — decides where a session
  may start.
- **`isolate` keeps concurrent sessions off each other.** Several agent sessions working
  in one repository share a checkout, and so share one `HEAD`, one index and one branch
  list — a `git checkout` in one rewrites the files under all the others. With
  `"isolate": true` each fresh launch gets a git worktree of its own instead, made at
  launch from the remote's default branch. The dropdown still lists the repository, not
  the worktrees: you pick **Bridge** and never see them. Resumes stay in their existing
  approved directory, including managed worktrees of an approved isolated repository;
  missing or revoked targets are refused, not redirected.
- **Nothing unmerged is ever cleaned up.** Finished worktrees are removed before each
  launch only when ownership, Git state and all-adapter liveness are readable: no
  uncommitted or untracked files, no ignored files beyond the native hook binary the
  project tells you to build, no checked-out branch or detached commits
  ahead of the base, no live session at or below the directory, and sufficient
  `newSession.worktreeIdleHours`. Locked, uncertain and linked/submodule trees remain.
  Cleanup removes only clean tracked files, that one named build output and empty
  directories, never recursively deleting ignored user data; Git retains prunable
  administration for normal maintenance.
  A `.env`, a `config.json`, `node_modules` or any other ignored file still keeps the
  whole tree. The hook binary is the single exception because a tree only qualifies
  when no tracked file is modified, so its source is exactly what is committed and the
  documented `go build` reproduces it; build it from modified source and those
  modifications keep the tree. Without the exception, following the project's own test
  instructions made a worktree unreclaimable for ever and the launch cap filled.
  Pending launches hold a Git lock until registration. If isolation cannot be provided,
  the launch stops with a useful error instead of using the original checkout.
- **Tools are not auto-approved.** Launched sessions get no `--allow-all` unless
  you set `newSession.allowAllTools`. Permission prompts already route to Home
  Assistant, so an unattended session still asks before it acts.
- **Launch is a button, not the text box.** Home Assistant commits a text entity as soon
  as it loses focus, so acting on the typed value alone would spawn a session the moment
  you clicked away.
- **The opening prompt is as long as you need it to be.** The launch card publishes it
  over MQTT, the same way the reply box sends a long reply, so a whole handover — the
  context, the constraints, what has already been tried — can start the session. A
  dashboard still on an older card falls back to a plain `text` entity, which Home
  Assistant caps at 255 characters.

The **Last launch** row reports what happened. It confirms success only once the new
session has actually registered itself, not merely when a process started.

### Ending a session

Every session card has an **End session** row. Starting work remotely but not being
able to stop it is a bad trade: a session that has gone wrong — wrong repo, stuck in a
loop, burning credits — otherwise has to be dealt with at the keyboard, and sessions
pile up.

The stop is graceful. `/exit` is typed into the session's console exactly as a reply
would be, so the CLI shuts down the way it does at the keyboard: transcript written,
MCP servers closed, lock released. Only a session still running after the grace period
is terminated outright, because a killed CLI leaves a stale lock and half-written state.

The status is `ending` while the stop runs, then `ended` when it succeeds or `error`
when it fails. A failed stop keeps the failure detail on the card rather than looking
like an idle session. If status publication fails, the daemon retains the local
outcome and logs the publication failure.

**A session that is not idle takes two presses.** End sits one tap away from Send, and
a stray tap landing mid-turn throws away the turn in flight. So the first press only
arms: the card's status line changes to *Press End session again to end it*, naming
what the second press would interrupt, and the session carries on untouched. A second
press within ten seconds ends it; without one the confirmation lapses, the card says
*End session NOT confirmed*, and the next press starts over. Only an idle session ends
on a single press, having nothing in flight to lose. A session waiting on background
agents it started is not idle and so takes two presses: its own turn has ended, but
the work it is waiting on has not. A session whose status the daemon has not yet
worked out is guarded too, precisely because it may well be
mid-turn. A press with no process behind it is not guarded, since there is nothing a
second press could protect: such a session cannot be stopped at all, and the card
reports that rather than appearing to have worked.

The guard lives in the daemon rather than in the dashboard card, deliberately. The
same button is pressed from a phone, from an automation and by other agents, and only
the daemon sees all of those; a confirmation dialog would protect the dashboard and
leave everything else ending a working session on one press.

Beyond that it is safe to press. The transcript survives either way, so an ended
session stays in the **Resume** list and can be reopened — a mistaken press costs a
window, not the work.

---

## Agent usage

Every one of these agents meters you, and each one keeps that figure to the terminal
it is running in: Copilot's `/usage`, Codex's `/status`, Claude Code's `/usage`. The
daemon polls them instead and publishes what it finds, so the dashboard answers "how
much is left" without opening a session to ask.

Each client gets its own sensor per machine —
`sensor.agent_bridge_<slug>_usage_<client>`, whose state is the percentage used, so
Home Assistant records the history and you can graph or alert on it like anything
else. The **Agent usage** card groups them by account, not by machine: an allowance
belongs to a login, so two machines signed in to the same account are reconciled to
whichever read it most recently rather than drawn twice.

| | |
|---|---|
| **Copilot** | The monthly AI-credit allowance, read live from GitHub using the credential Copilot CLI itself stored. Falls back to the CLI's own cache when there is no credential to hand — and then says so, because a cached figure was measured thirteen minutes stale, and already wrong, during an active session |
| **Claude** | The session (5-hour) and weekly windows, read with the OAuth token Claude Code keeps beside its settings. Both are drawn whenever Anthropic lists them, including a session window sitting at 0% because none is open — leaving those out made Claude look as though it had only a weekly cap. That token expires about hourly and only Claude Code can refresh it: Anthropic retires a refresh token as it is used, so refreshing from here would either sign Claude Code out or race its own write. An expired token is therefore not spent, and the retained sensor keeps its last reading and ages |
| **Codex** | The 5-hour and weekly rate-limit windows. Codex has no endpoint to ask — it learns its limits from the replies it gets — so this is the newest figure in its own transcripts, and the card marks it stale once it is over an hour old |

Each bar carries a thin **pace mark** where an even spend would have reached by now,
with the line underneath naming it: `│ even pace 20% · 48% ahead of pace`. Two thirds
of a monthly allowance gone means nothing on its own — on the 25th it is thrift, on the
5th it is a problem, and the bar alone cannot tell you which. Being ahead of the clock
by more than a tenth of the window is coloured; anything closer is noise. Bars turn
amber at 75% and red at 90%, and the folded summary line takes the colour of whichever
window is closest to running out.

Tokens are read, spent on the one request, and dropped — never logged, never
published, never written anywhere. Turn the whole thing off with `usage.publish:
false`, which stops the collection rather than merely hiding the result.

On macOS the Copilot figure needs a token the CLI keeps in the login keychain, and
reading it is **off by default** (`usage.keychain`). Nothing the bridge can do makes
that read quiet: the keychain item does not trust `/usr/bin/security`, so every read
raises an authorization panel, and pressing **Always Allow** does not settle it,
because the CLI replaces the item whenever it refreshes its token and the replacement
carries a new ACL that the earlier grant does not belong to. With a two-minute poll
behind it, that was enough panels to make a Mac unusable.

Set `usage.keychain: true` to allow the read anyway. A machine that wants the live
Copilot figure without any of that can export `COPILOT_GITHUB_TOKEN`, `GH_TOKEN` or
`GITHUB_TOKEN` instead — those are read first and prompt for nothing. Otherwise the
allowance falls back to its cached reading, and the other agents are unaffected.

### How current it is

The daemon re-reads the allowances every `usage.intervalSeconds` (120 by default) and
publishes only when a figure has actually moved, since every publish is retained. Home
Assistant then pushes that change straight to any open dashboard, so **a card you are
looking at redraws within a second of the daemon publishing** — there is nothing to
refresh. In practice that means Copilot is never more than two minutes behind, which is
the point: its figure was measured moving continuously during an active session.

The card also runs a half-minute timer of its own, purely so the relative text —
`37m ago`, `resets in 3h` — keeps up when nothing is being pushed. Codex's figures can
sit unchanged for days, so without it that row would never redraw at all. The timer is
stopped outright while the browser tab is hidden rather than left firing into nothing.

### When a read fails

Each poll retries a few times before giving up, and a failure never overwrites a good
figure: the retained sensor keeps its last reading and visibly ages instead.

A failed read is therefore only *reported* on the card once the reading it was meant
to replace is more than an hour old. That rule exists because the opposite was worse.
On a machine whose path to `api.github.com` dropped most of its TLS handshakes, a
single-shot read failed more often than it succeeded, and the card carried a permanent
red line underneath a figure that was both current and correct — which teaches you to
ignore the colour. The age beside each client is the honest signal while a reading is
fresh; the error is what is left when nothing recent survived.

The reason shown is the whole exception chain rather than its head, because .NET's
outer message for a failed HTTPS call is *"The SSL connection could not be established,
see inner exception"* — which names no cause and points at something a card cannot
show. The cause (*"An existing connection was forcibly closed by the remote host"*) is
always a level or two further down.

---

## Several machines, one Home Assistant

Install the bridge on as many machines as you like. They all talk to the same Home
Assistant through retained state, without direct machine-to-machine connections.
Agree on one explicitly configured writer for the shared card/dashboard; machine and
session reporting remain per-machine.

Each machine publishes its own device — **AI Agent Bridge (DESKTOP)**, **AI Agent Bridge
(LAPTOP)** — carrying its own update entity, its own launch controls and its own session
counter. Entity ids are suffixed with the machine, so
`button.agent_bridge_desktop_new_session` and `button.agent_bridge_laptop_new_session`
are different buttons. Pressing one launches a session on that machine and nowhere else.

There is still **one dashboard**, and it shows everything:

- an **Agent sessions** card at the top: live sessions and pending decisions on the line
  you always see, folding open to a row per machine — whether it is online right now,
  how many sessions it is running, what version it is on, and its own **Detail** switch,
  replaced by an update button whenever that machine has one to install or is part-way
  through installing it,
- one **Start a new session** card with a **Machine** dropdown at the top — pick where,
  then the workspace, profile and resume rows for *that* machine appear beneath it,
- one card per session wherever it is running, labelled with its machine — and because
  the entities are real, you can answer a prompt on the laptop from the same screen.

The dropdown is a display filter and nothing more. No daemon reads it, and **Launch**
presses the selected machine's own button — a single shared button is exactly what made
one press start a session everywhere at once. With only one machine online there is
nothing to pick, so the dropdown does not appear at all.

Liveness is a heartbeat: each machine reports in every 60 seconds and Home Assistant
marks it offline after three missed beats. An offline machine stays listed in **Agent
sessions**, because knowing a machine exists but is currently off is exactly what you
want when a session you expected is not there — but it gets no launch card, no install
button, and its sessions are hidden, since none of them can be running.

A machine that is *gone* — renamed, reimaged, retired — is a different thing, and it
never comes back to withdraw what it published, so its row would read "offline" for
good. Open **Agent sessions** and an offline row carries an **✕** where its **Detail**
switch sits: one press asks, a second removes. That clears the machine's retained
topics along with those of the sessions it was last listed as running, so Home
Assistant drops its entities, its device and its rows, and the dashboard is rebuilt
without it. Nothing belonging to any other machine is touched, and its Detailed
activity switch — a helper rather than a retained topic — is swept up a reconcile later
by a participant that verifies the current shared view no longer needs it.

Pressing it on a machine that is only switched off costs nothing lasting: it
republishes everything when it next starts, and the row comes back.

No machine talks to another. Each publishes a retained sensor describing what it is
running, and every daemon reads all of them. The designated writer renders the whole
picture; other participating daemons observe accepted shared output rather than
competing to replace it. There is no host-clock election or automatic failover.

You can see the same list from any machine's terminal:

```powershell
agent-ha-bridge status
```

```
machines:
online   DESKTOP            2 session(s) (this machine)
offline  LAPTOP             0 session(s)
```

It also warns if it finds a machine still running a bridge older than 1.6.0, because
that one rebuilds the shared dashboard from its own sessions alone and will keep
replacing everyone else's until it is upgraded. That warning is **not** a publication
fence participation check: later pre-fence builds can still overwrite shared state.

One thing stays shared, because it belongs to the instance rather than to a machine:
the dashboard itself. (The machine dropdown is shared too, but it is created and
retired automatically.) An uninstall therefore leaves
it alone unless it is removing the last machine — see [Uninstall](#uninstall).

The older machine-entity namespace migration is separate: previously unscoped
bridge-level entities are withdrawn and republished under the machine's name.
That does not establish exclusive shared-publication authority.

### Publication authority and migration

**The first introduction of publication fences into an unfenced fleet is an
operator-coordinated migration, not a transparent routine update.** Agree the
cutover and offline-host rejoin plan with the release owner before deploying it.
These are cooperative checks, not an HA access-control boundary: an unmodified
pre-fence writer, including 1.22.2 and pre-fence 1.23/1.24 builds, ignores the policy
even if its card version matches. Updating one machine does not contain those
writers. Detecting and repairing an overwrite is not preventing it.

The bridge distinguishes four states:

| Observed state | Publication behavior |
|---|---|
| Successful reads; no policy, bridge resource or dashboard | First install: no self-election or automatic write; configure the writer and explicitly bootstrap |
| Successful reads; existing unfenced bridge resources/dashboard | Preserve contents and report migration required; matching bytes, hostnames or an old signature do not identify an incumbent writer |
| Valid established authority | Continue the explicit writer/generation/version policy; compatible participating upgrades do not need another bootstrap |
| Denied, unreadable, malformed, conflicting or lost-after-establishment state | Refuse unsafe publication with diagnostics; never interpret it as absence or automatically reset the policy |

Publication uses ordinary HA module-resource `url`/`res_type` commands. A separate
inert resource named `agent-bridge-publication-policy.js` in its URL fragment retains
the policy independently of the generated dashboard. Protected local receipts under
the installation's runtime root remember observed generations and high-water
fences. Their local serialization is **not a distributed lease**.

#### Configure the participants

Merge this section into the selected installation's existing protected
`config.json`; do not replace its other settings or copy credentials into a command:

```json
{
  "dashboard": {
    "urlPath": "agent-decisions",
    "publication": {
      "authority": "shared-agent-dashboard",
      "participant": "publisher-a",
      "writer": "publisher-a",
      "generation": 1
    }
  }
}
```

Identity values are explicit non-secret labels: 1–80 letters, digits, `.`, `_`, `:`
or `-`, beginning with a letter or digit. They are not HA user IDs or a replacement
for existing credentials. The writer's `participant` must equal `writer`; another
participant uses its own label, such as `observer-b`, while naming the same writer
and authority. Keep `dashboard.urlPath` consistent for this shared dashboard.
For a publication write, the local writer, authority and generation
must match the established shared policy.

**Only the designated writer bootstraps.** Other machines still report their
sessions and can observe an accepted view without becoming publishers. They do not
bootstrap once per host. Missing local publication settings never grant write
authority; a refused shared write does not stop unrelated reporting. Observers
retire old session entities only when verified shared output no longer renders them.

Before bootstrap, writer reassignment or a policy-generation change, quiesce
automatic shared publishers using their owning service/task controls, including
pending installer/card-check work, and prevent them restarting during the operation.
Do not stop unrelated installations. The following helpers do not perform that
quiescence or provide an atomic HA compare-and-swap. Keep pre-fence writers from
interfering through the operator's agreed cutover procedure.

#### Bootstrap or migrate once

Use a fresh `pwsh -NoProfile` shell on the selected writer after editing its
configuration. Load that installation's helpers; choose the actual root instead of
the default below for a custom installation. This uses the existing administrator
provisioning configuration, not an agent's ordinary session-control token.

```powershell
$publicationRoot = Join-Path $HOME '.agent-ha-bridge'
$publicationCodeRoot = $publicationRoot
$env:AGENT_HA_BRIDGE_CONFIG = Join-Path $publicationRoot 'config.json'
$publicationHooks = Join-Path $publicationCodeRoot 'hooks'
. (Join-Path $publicationHooks 'decision-bridge-common.ps1')
. (Join-Path $publicationHooks 'decision-mqtt.ps1')
. (Join-Path $publicationHooks 'decision-ha-websocket.ps1')
$env:BRIDGE_FRONTEND_NORUN = '1'
. (Join-Path $publicationHooks 'bridge-frontend-cards.ps1')
Remove-Item Env:\BRIDGE_FRONTEND_NORUN
```

The frontend guard loads functions without running the checker's automatic work.
Inspect successful reads and the exact proposed card/renderer targets before acting:

```powershell
$publicationState = Read-BridgePublicationState
$publicationState.Kind
$publicationState.Policy | ConvertTo-Json -Depth 10
$publicationTarget = Get-BridgePublicationTarget
$publicationTarget | ConvertTo-Json -Depth 10
```

Inspection performs shared reads and preserves any established local receipt. If a
policy already exists, do not bootstrap again. With no policy, an explicitly
configured generation `1` and inspected targets, run the one-shot operation:

```powershell
Set-BridgePublicationPolicy -ExpectedGeneration 0 -ExpectedPolicyHash absent `
    -Target $publicationTarget -Mode advance | Out-Null
$publicationCard = Install-BridgeReplyCard
if (-not $publicationCard.Ok -or $publicationCard.Action -notin @('current', 'deployed', 'updated')) {
    throw $publicationCard.Detail
}
```

`Ok` alone is not publication proof: an already usable card can accompany a
`blocked` result. Resolve conflicts or `unconfirmed` writes before proceeding; do
not guess whether an uncertain operation committed. An equal-version/different-body
conflict requires a genuinely versioned compatible artifact or a deliberately
authorized exact pin, not a relabeled `-Version` argument.

After the approved artifacts are in place, resume the selected writer through its
own control path (`agent-ha-bridge restart` for a normally registered installation).
Let its reconciliation build from the actual live/retained session inventory; do
not publish an empty session list to clear a migration error. In the inspection
shell, check:

```powershell
Get-BridgeDashboardPublication | Select-Object Verified, Reason, InputSignature
```

A version badge, registered resource or successful policy write is not proof that
the dashboard is current. `Verified` concerns the actual accepted shared view; read
`Reason` and the daemon's `dashboard publication not current` diagnostics when false.

#### Versions and bounded rollback

Bridge release `VERSION`, card `CARD_VERSION`, the renderer's publication version,
the fencing protocol and the operator policy generation are different things.
Ordinary authorized publication may advance compatible artifact versions, but never
silently replaces equal-version/different-content artifacts or lowers a fence.

The composed renderer that includes End-session confirmation uses publication version
`1.1.0`. The earlier frozen `1.0.0` candidate is a different render artifact, even
when bridge/card versions or session inputs match. Inspect targets again from the
complete selected build before an authorized policy change; do not reuse the old
renderer target/hash or edit a receipt to make it appear current.

Rollback is an explicit next-generation **pin of exact card and renderer versions
and content hashes**. It is not a permanent force flag or a transactional installer
rollback. For a card-only rollback, inspect an approved historical card file with
the current participating renderer. For a renderer rollback, load the complete
approved participating build's helpers; `Get-BridgePublicationTarget` fingerprints
the renderer actually loaded, not a bridge release number. A pre-fence bridge is
not a supported policy-enforcing rollback target. This does not certify downgrading
other clients' or approval handlers' persisted state.

With publishers quiesced, inspect generation `N`, configure the chosen writer's
local generation to exactly `N + 1`, and load a fresh inspection shell as above.
For a different renderer, set `publicationCodeRoot` to the approved build while
keeping `AGENT_HA_BRIDGE_CONFIG` pointed at the selected installation. Loading that
code for inspection does not activate it in the daemon: the resumed writer must
actually run the approved renderer, or its fingerprint will be refused.
Replace the example path below with the approved card file's actual location:

```powershell
$approvedCardSource = 'C:\approved-bridge-build\frontend\agent-bridge-reply-card.js'
$beforePolicyChange = Read-BridgePublicationState
$expectedGeneration = [int]$beforePolicyChange.Policy.generation
$expectedPolicyHash = Get-BridgePublicationHash (ConvertTo-BridgePublicationJson $beforePolicyChange.Policy)
$rollbackTarget = Get-BridgePublicationTarget -CardSourcePath $approvedCardSource
$rollbackTarget | ConvertTo-Json -Depth 10
```

Only after reviewing those exact targets:

```powershell
Set-BridgePublicationPolicy -ExpectedGeneration $expectedGeneration `
    -ExpectedPolicyHash $expectedPolicyHash -Target $rollbackTarget -Mode pin | Out-Null
$pinnedCard = Install-BridgeReplyCard -SourcePath $approvedCardSource
if (-not $pinnedCard.Ok -or $pinnedCard.Action -notin @('current', 'deployed', 'updated')) {
    throw $pinnedCard.Detail
}
```

Resume the approved writer and verify the actual shared view. A missing pinned
card, a wrong version, the same version with different bytes, or a file URL that
cannot prove the exact content is **not current / repair required**. Hashing that
wrong URL into a new dashboard receipt cannot satisfy the pin. Apply the exact
authorized artifact before rendering; the bridge cannot reconstruct old bytes from
their hash. Advance-mode missing-card fallback remains available, but does not
convert an incomplete exact rollback into success.

Newer automatic code cannot undo a pin. Leaving it requires another explicit
generation and expected-policy digest with `-Mode advance`, using inspected targets
at or above the retained high-water fences (and the same bytes at an equal version).
Changing the designated writer also needs a deliberate generation change and
quiescence, never presence or clock-based takeover. A stale expected generation or
digest is a refusal to investigate, not a reason to retry with guessed values.

#### Deletion, outage and policy-loss recovery

With valid authority, the designated writer detects an externally deleted or
overwritten dashboard and repairs it even if its local signature is unchanged.
If the writer is offline, reporting/observation can continue, but no peer elects
itself to repair or change the layout.

Before changing policy, retain an operator-approved backup of its complete policy
and the exact HA resource URL. Inspect them with `Read-BridgePublicationState`;
`PolicyResource` contains the HA `id`, `type` and `url`, not secret credentials.
HA backups and the protected per-install receipt located by
`Get-BridgePublicationReceiptPath` are recovery evidence, not automatic authority
to choose a replacement generation.

If the policy resource is lost, stop publishers and preserve the remaining
resources, dashboard and local receipts. Restore the **exact known authoritative
policy resource** through the operator's HA resource/backup recovery procedure,
preserving authority, writer, generation, targets and high-water records. Do not
delete receipts, call bootstrap over the loss, select the largest local timestamp,
or silently choose between conflicting copies. If no trustworthy policy record can
be established, stop for an operator recovery decision rather than inventing one.
Re-read the restored state before resuming; conflicting or corrupt receipts remain
errors, not an empty first installation.

Once policy is intact, ordinary dashboard deletion can be repaired by the writer.
An exact card pin still requires its actual artifact before the view can be verified.
Denied/unreadable state and duplicate policy/card registrations need their real
cause resolved; neither is permission to create another resource or reset a fence.

---

## Updating

For the first release introducing publication fences, complete the
[operator migration plan](#publication-authority-and-migration) before using routine
per-machine update controls. Those controls do not coordinate a fleet cutover or
bootstrap policy. Later compatible participating updates continue the established
authority and fences; a card/render change that conflicts with a pin stays refused
until an explicit policy operation authorizes it.

The daemon asks GitHub for the newest release a few times a day (every 6 hours by
default, tunable via `updates.checkHours`) and publishes the result as
a Home Assistant **update entity**, so a new version shows up on the dashboard and in
Home Assistant's own Updates list — with the release notes and a one-press install.

On the dashboard that press is on the machine's own row in **Agent sessions**, where
it takes the place of that row's **Detail** switch, and it is only there when there is
something to say. It names the version it would install — *Update to 1.33.9* — and
while the update runs it reports the stage the updater has actually reached:
*Checking*, *Downloading*, *Installing*, *Restarting*, *Verifying*. A stage that
reports how far it has got is drawn as a bar as well; no stage reports one yet, so
today each is named without a percentage.
A machine that is part-way through shows that rather than the **✕**, because its
liveness sensor expires while its own daemon restarts — which is one of the stages.

It ends on what happened rather than on silence: *Updated to 1.33.9*, *Already
current*, or *Update failed* with the reason, which can be pressed again to retry. A
release that was already installed is **not** reported as a failure. A machine whose
release check failed says that too, instead of looking like one with nothing to
install.

A notification is left as well — *Bridge updated to X*, or the error if it failed. The
updater then asks the supervisor to restart the daemon so the new version is actually
running.

A browser served a card older than 1.31.0 gets the previous separate **Bridge update
available** card instead; the two are never drawn at once.

From a terminal:

```powershell
.\update.ps1 -Check     # report what's available
.\update.ps1            # install it, after confirming
```

Or, from anywhere, `agent-ha-bridge update`.

Either way your configuration is preserved: the installer reads the existing config,
backs it up, and keeps your URL, token and settings.

The installer also fetches the native hook built for the release (checked against the
release's `SHA256SUMS`) and points the agents' hooks at it. When that changes an
agent's hook command:

* **Codex** asks you to trust the bridge's hook again, once - approve it, or its
  sessions stop showing on the dashboard.
* **Claude Code** picks up the new hooks by itself, even in sessions already running;
  there is nothing to restart.
* **Copilot CLI and Agency** use the native hook from Copilot 1.0.88; older versions
  keep PowerShell hooks.

**Nothing updates itself.** The check is passive and installing is always a deliberate
action, because this software types into terminals and registers scheduled tasks. Set
`updates.checkForUpdates` to `false` to turn the check off entirely, or point
`updates.repository` at your own fork.

**If the check is refused.** GitHub allows unauthenticated callers 60 requests an hour
per IP, so a machine behind shared egress can be rate limited without having made a
request of its own - measured here going from 39 remaining to none in ninety seconds.
Four things keep that from becoming a failed update:

- The release archive is fetched from `codeload.github.com`, which is not part of the
  API allowance. The `zipball_url` the API offers is itself an API request, so pressing
  **Install update** used to spend the same allowance the check competes for - and be
  refused once it was gone, for a reason that had nothing to do with this machine.
- When the check itself is refused, `github.com/<r>/releases/latest` is asked instead;
  that redirect is outside the allowance too. It is used rather than the `releases.atom`
  feed because it makes the same selection the API does - the newest **published,
  non-prerelease** release. The feed is ordered by date and includes prereleases, so on
  a repository that ships them its newest entry is the wrong answer, and this project
  pushes a release tag while the release is still a draft. Release notes are not
  available this way, but which release is current is, and a correct version with no
  notes beats a stale one presented as current.
- A secondary limit names no reset time of its own, so the wait doubles each time it
  keeps answering - 1, 2, 4, 8 minutes and so on to an hour - rather than asking again
  at a fixed interval, which GitHub warns can earn a ban.
- If that endpoint cannot answer either, the refusal is reported as rate limiting with the
  time the limit resets - not as a failed update - and the machine keeps publishing its
  installed version rather than going blank, because the fault is neither in the
  install nor in the release. The machine's row says **Update check failed**
  rather than going quiet, so a refused check does not read as nothing to install.

A token raises the limit to 5,000 requests an hour. One already in the environment as
`GH_TOKEN` or `GITHUB_TOKEN` is used automatically; `updates.token` sets one
explicitly.

---

## Uninstall

From **Settings → Apps → Installed apps** on Windows, or on either system:

```powershell
agent-ha-bridge uninstall
```

Both do the same thing. The Settings entry gets its own console window, which Windows
closes the instant the script ends, so that one waits for a keypress before closing —
otherwise every warning, and any outright failure, flashes past unread. (The silent
entry that package managers use does not wait, since nothing is there to press a key.)
…which is `uninstall.ps1 -ClearEntities`. `-ClearEntities` clears the retained MQTT
discovery topics for **this machine**, so Home Assistant is left clean; without it they
linger. `-KeepConfig` preserves your settings. The `agent-ha-bridge` PATH entry is
removed too.

The dashboard is shared by every machine that talks
to the same Home Assistant, so it is only removed when this is the last one. If the
bridge cannot tell, it asks; a scripted uninstall keeps them. `-ClearShared` and
`-KeepShared` decide it outright.

---

## Tests

```powershell
pwsh -NoProfile -File .\tests\run-tests.ps1                         # all offline suites
pwsh -NoProfile -File .\tests\run-tests.ps1 -List                   # inspect the selection
pwsh -NoProfile -File .\tests\run-tests.ps1 -Suite test-runner.ps1  # runner safety checks
pwsh -NoProfile -File .\tests\run-tests.ps1 -Suite test-status-card.ps1
```

Use PowerShell 7, Node.js and Git (including Git Bash on Windows). The runner uses
`tests/suites.psd1` for the same Windows/macOS selection, including the Claude and
Codex offline suites. Every suite must appear exactly once in the manifest.
Discovery covers every component and nested `test-*.ps1`, not just existing test
directories. Dependency, Git, fixture and generated-output exclusions are documented
in `AGENTS.md` and regression-tested; symbolic links and junctions are not traversed.
The runner marks its output with `.bridge-test-results` so a custom results directory
inside the checkout cannot become a source of executable suites.
Each runs in a fresh process with a private home, temporary directory, synthetic
configuration and client roots. Credentials and HTTP opt-ins are not inherited;
redirected input, output and pipelines are UTF-8. Do not invoke suite files directly:
these protections belong to the runner, not to every individual script.
Installer REST, WebRequest, WebSocket, discovery and checker-child paths honor the
same inherited boundary without loading runtime configuration. Stub each transport
actually used: a REST stub does not authorize a WebSocket or discovery request.

Logs and a machine-readable `summary.json` are kept in the printed results directory
(or a new `-ResultsDirectory` you supply). Failures and per-suite timeouts fail the
run; missing prerequisites are reported as explicit skips, not hidden passes.
The default timeout is 900 seconds per suite. This is a test harness for reviewed
fixtures, not a general OS sandbox.

Installer-command tests are in the separate **Host** group. They run on disposable
GitHub-hosted Windows/macOS CI machines with `-AllowHostTests`, unique test registry
names and loopback fixtures. **Never run them on a developer or self-hosted machine**:
`-TargetHome` does not redirect every external side effect. The **Platform** group
keeps tmux/terminal delivery separate and has the same hosted-runner gate.
Only the Host group permits its fixed `http://127.0.0.1:1` connection-refused fixture
and matching WebSocket endpoint; LAN discovery remains blocked.
**Integration** suites are inventoried but never executed by this runner or CI.
They require an explicitly configured disposable Home Assistant, installed test
hooks, and `BRIDGE_ALLOW_TEST_HTTP=1` outside the runner.

The MCP server has its own Node suites; see its README. Dashboard cards also have
`frontend/test/test-cards.js`, run with plain `node` against a small DOM stand-in.
CI additionally runs `tests/test-bootstrap.sh` on macOS because it needs BSD `mktemp`.

`AGENTS.md` has the rest of what a contributor needs: the worktree slots that keep
concurrent sessions out of each other's way, the branch and pull request rules, the
lint CI also enforces, how dashboard cards are version-gated, and the release steps.

Build the native hook before a full offline run. It is Go (`hook/`): `go test ./...`
there, and `go build -o agent-bridge-hook.exe .` (no `.exe` on macOS) for a local build -
which the installer
then uses instead of downloading one, and which `tests/test-native-hook.ps1` runs end
to end with the daemon's spool.

Offline installer-helper tests inject package-manager and PATH operations; they do
not run the main installer. The host-only suite still uses `-SkipTask`, `-SkipPath`,
`-SkipDependencies` and Copilot-only fixtures. These switches are defense in depth
inside a disposable machine, not permission to exercise installation on a real one.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Cards show `unknown` after a Home Assistant restart | Self-heals within one reconcile (~15 s); the entities are optimistic and have no state to restore. |
| "Entity not found" on a card | The daemon provisions entities on its next pass; check the daemon log. |
| Answers picked in Home Assistant do nothing | The session predates the install — `/restart` it. |
| Nothing at all happens | Run `agent-ha-bridge logs`, or check `agent-bridge-daemon.log` and `agent-decision-bridge.log` under the installation's `runtime` directory. |
| `reply card publication paused` or `bootstrap` / `migration required` | Choose/configure the publisher and follow the explicit [publication procedure](#publication-authority-and-migration); reporting or a registered card alone is not authority. |
| `not current`, `Pinned card ... repair required`, or `unconfirmed` publication | Inspect actual policy/card/view state. Apply the exact pin or resolve the failed operation; do not weaken the pin or infer success from a cached signature. |
| `Publication policy was lost after establishment` | Preserve receipts and restore the operator-verified policy resource; do not erase local evidence or bootstrap again. |
| A Dev Box goes offline mid-session every evening | Its pool hibernates on disconnect. See [Running on a Microsoft Dev Box](#running-on-a-microsoft-dev-box). |

On Windows the daemon runs under an installation-scoped hidden task. For the default
installation (set `$bridgeRoot` to the intended root for a custom installation):

```powershell
$bridgeRoot = Join-Path $HOME '.agent-ha-bridge'
$installation = Get-Content (Join-Path $bridgeRoot 'installation.json') -Raw | ConvertFrom-Json
Get-ScheduledTask -TaskName "AgentBridgeDaemon_$($installation.id)"
Get-Content (Join-Path $bridgeRoot 'runtime\agent-bridge-daemon.log') -Tail 20
```

On a Dev Box with keep-awake enabled there is a second task beside it:

```powershell
Get-ScheduledTask -TaskName "AgentBridgeDevBoxKeepAwake_$($installation.id)"
Get-Content (Join-Path $bridgeRoot 'runtime\agent-bridge-devbox-keepawake.log') -Tail 20
```

Pre-metadata installations retain their historical task names and temporary log
locations until upgraded. No shared scheduled task is created by an isolated install.

---

## Notes and limitations

* **The reply box needs the bridge's own card.** After explicit publication
  bootstrap, the designated writer registers
  `agent-bridge-reply-card.js` inline, as a `data:` URL Lovelace resource, over the
  websocket API. There is no API for writing a file into `www`, but a resource is only
  a URL, and the frontend loads a module resource with a plain `<script src>`, so no
  file share is involved. The card is about 27 KB, sent with Home Assistant's resource
  list when the app or page loads. It shows as a very long URL under Settings >
  Dashboards > Resources; that is expected. If it cannot be registered, the dashboard
  can use the advance-mode plain `text` entity and Send button fallback, with a
  **255-character** cap on replies. An unsatisfied exact card pin instead reports
  repair-required and is never called current. Installs from before
  1.10.1 copied the card into `config\www`; that file is no longer used and can be
  deleted.
* **Images go via Home Assistant.** A pasted image is uploaded to Home Assistant, pulled
  into protected installation-scoped storage by the daemon and attached as `@<path>`.
  Only successful reply transport permits deletion of the Home Assistant source;
  staging or transport failure retains source images and staged private files.
  Transport success is not proof that the client read the file or completed a turn.
  Local files older than a day are swept after a successful reply, not on an idle
  expiry schedule. This is not a durable retry queue: the card still clears drafts
  after MQTT publication and a newer submission can replace the single payload.
* **Other files go inside the reply.** `/api/image/upload` decodes what it is given and
  refuses anything that is not an image, so a document is base64'd into the reply payload
  instead and written out by the daemon. That puts it in a Home Assistant state attribute,
  hence the **256 KB** ceiling; a larger file is refused on the card rather than sent. The
  name is rewritten before it is written to a protected file. The current transport
  has no established quoted-path support: whitespace in the private directory refuses
  the entire attachment-bearing submission, without sending just text or a subset.
  There is no Public/shared-TEMP fallback and no automatic retry. Unidentified legacy
  installations must be reconfigured before sending attachments; old shared files are
  preserved for a separate ownership-aware migration.
* **A file needs the receiving machine updated too.** The card is one shared resource, so
  it offers file attachments for every session once the designated writer publishes
  that card, while a machine still on an older bridge ignores the `files` in the payload and
  delivers only the text. Unlike a missing dashboard row this announces itself — the agent
  answers that it cannot see an attachment — and the fix is to update that machine, which
  its `button.agent_bridge_<slug>_install_update` does without a shell on it.
* **Multi-field questions cap at 4 fields**; larger forms fall back to a text outline.
* **Hooks never wait on a missing Home Assistant.** Each one probes first and skips its
  Home Assistant work if the host doesn't answer within about a second, so an outage
  costs a moment rather than the tens of seconds the retry layer would otherwise spend.
  The question is still recorded locally and the daemon arms the card once Home
  Assistant is reachable again.
* **Session names are treated as untrusted.** A Copilot session is named after its task
  and a Claude session after its working directory, so template syntax in either is
  neutralised before it reaches a card — otherwise a folder called `{{ ... }}` would be
  evaluated by Home Assistant.
* **Use HTTPS if you can.** A long-lived token is sent on every request, so over plain
  HTTP it crosses your network in the clear. The installer warns about this.
* The daemon idles at a few percent of one core and reconciles every ~15 s, with
  WebSocket pushes for anything latency-sensitive.
* **On macOS, only sessions in tmux can be replied to.** Windows can type into any
  console; macOS offers no way to type into a terminal another app owns, so the bridge
  goes through tmux. A session outside tmux still gets its card - status, reasoning,
  responses, questions - from its hooks and transcript.

---

## Internals

There is **nothing for a model to call**. The `preToolUse` hook fires on `ask_user` by
itself, so no skill, tool or prompt instruction is needed — and builds up to 1.4.2 that
installed a `decision-notifier` skill were wrong about this. That skill is removed on
upgrade.

### Question shapes

Two `ask_user` argument shapes are handled. Current builds pass **`message`** plus a
**`requestedSchema`** JSON-Schema form; older builds passed `question` plus a flat
`choices` array. Options are derived from `requestedSchema.properties`, covering `enum`
(with optional `enumNames`), `oneOf: [{const, title}]`, multi-select `items.enum` /
`items.anyOf`, and `type: boolean` (Yes/No).

* Every form, down to a **single field**, becomes one labelled group of rows per field
  plus **Send answer**. Nothing sends itself on a tap: picking changes what will be
  sent, and Send sends it.
* A **multi-select** field (`type: array`) draws its options as checkboxes - tap to
  tick, tap again to untick, send as many as you like. A schema default arrives with
  those rows already ticked, exactly as the terminal shows them, and sending it
  untouched types nothing at all. A Home Assistant select holds one value, so the slot
  behind it has to enumerate every combination: up to **ten options**. Beyond that the
  question says to answer it in the terminal rather than offering a list that could
  only take one.
* **The set rides as positions, not as words.** A slot carries `#1,3` rather than the
  picked options joined together. Spelling them out meant a select entry had to hold
  every chosen option's full text, and six ordinarily-worded options ran to 350
  characters against Home Assistant's 255 - so perfectly normal questions were refused
  and sent to the terminal. Positions are 22 characters for all ten, so how long
  somebody's options happen to be no longer decides whether the question is answerable.
  Both forms are published while they fit, so a card older than 1.23.0 goes on writing
  the words and is understood; where the words are too long to be offered at all, an
  older card cannot answer that one question and says so rather than failing silently.
* **One rough edge, written down rather than smoothed over.** On a question whose
  options are too long for the written-out form, a card older than 1.22.0 draws the
  slot's own entries - so it shows `#1`, `#2`, `#1,2` and so on, which mean nothing to
  read. Anything tapped there still answers correctly, and before this change the
  question did not reach the dashboard at all, so it is a gain; but the readable fix
  is to serve a current card.
* **Up to 4 fields.** Larger forms fall back to freeform, with the question carrying a
  numbered outline of every field and its options, marking any default.
* **Typing is answering.** Every Copilot option list ends in "Other (type your
  answer)", so words typed into the reply box and sent answer a choice question
  through that entry. Where they cannot be used - a form with no free-text field, or
  a choice already tapped - the card says so rather than dropping them.
* Questions are carried up to 6,000 characters and each choice up to 600; anything
  longer is truncated and the card says so.
* **An answer is read by identity, never by a clock.** As a question is armed the
  bridge records what the reply card and the Send button already held, in a file of
  its own named for that question, written once. Only something determinately
  different from that counts as an answer: a channel nobody could read is not an
  empty one, and nothing is read until it can be. Comparing timestamps instead meant
  a browser running behind left every typed answer looking old, and one running
  ahead answered the next question with the last one's text.

A malformed `ask_user` call is repaired before publishing. When a model fails to close
the tool-call markup, the closing tag and later parameters get swallowed into the
question string; the parser splits at the leak and reads the trailing payload — for both
a leaked `choices` array and a leaked `requestedSchema`, including when either is cut off
mid-write. Real arguments always win over recovered ones.

### Where the work lives

| File | Role |
|---|---|
| `decision-bridge-common.ps1` | Config loader, `ask_user` argument parsing and repair, REST helpers with retry/backoff |
| `bridge-adapter.ps1` | Shared adapter orchestration reused by every client's hooks: the reachability gate, publish-on-demand, status/activity, notifications |
| `decision-mqtt.ps1` | Per-session MQTT discovery: publish, arm/clear a decision, set status and activity, tear down |
| `decision-ha-websocket.ps1` | Entity-registry reads and renames, scoped `subscribe_trigger` waits, dashboard generation |
| `decision-inject.ps1` | `AttachConsole` + `WriteConsoleInput` delivery, with session→pid lookup from `inuse.<pid>.lock` |
| `session-launch.ps1` | Starting a new CLI session: the workspace allowlist, argument quoting, and the launch itself |
| `agent-bridge-daemon.ps1` | The loop: reconcile sessions, stream activity, sweep orphans, deliver answers |
| `daemon-usage.ps1` | Each agent's remaining allowance, normalised from three vendors into one shape |
| `agent-bridge-supervisor.ps1` | Keeps one daemon alive with backoff; a named mutex prevents a second instance |
| `route-ask-user-v3.ps1` | The non-blocking `ask_user` router |
| `notify-agent-response.ps1` | Non-blocking response mirror + card |

Logs are under the recorded installation's `runtime` directory:
`agent-decision-bridge.log` (hooks), `agent-bridge-daemon.log`,
`agent-bridge-supervisor.log`, and, when enabled, `agent-bridge-devbox-keepawake.log`.
Pre-metadata installs retain their legacy temporary paths. Hook config changes reach a running CLI only
after `/restart`; the daemon is shared and picks up new sessions on its own reconcile.

### Design constraints worth knowing

* The decision `select` and reply `text` are **optimistic** (no state topic) so a tap or
  typed value sticks without a device echo. The cost is that they read `unknown` after a
  Home Assistant restart; the daemon repairs them on its next reconcile.
* Home Assistant derives an MQTT entity id from device name + entity name and **ignores
  `object_id`**, so the bridge forces deterministic ids with
  `config/entity_registry/update` → `new_entity_id`.
* Waits use a scoped `subscribe_trigger`, **not** a broad `state_changed` subscription —
  the latter floods the CPU.
* The daemon must keep a **real** console for `AttachConsole` to work. It is launched
  hidden via `agent-bridge-launch.vbs` (`WScript.Shell.Run(..., 0, …)`). Do not switch
  it to `conhost --headless`, which gives a pseudoconsole and breaks injection.

---

## Other clients

### Claude Code — full support

[`claude/`](claude/) adds the same experience to Claude Code: live activity,
chain-of-thought, a reply box that types into the real terminal, and a card when it
needs you. Claude Code exposes the same four primitives this bridge is built on —
`PreToolUse` with a matcher, a `Stop` hook, JSONL transcripts, and a real console — so
it gets the full stack rather than a subset.

```powershell
cd claude
.\install-claude.ps1
```

See [`claude/README.md`](claude/README.md), which states exactly what is verified
against a live session and what is not.

### Codex CLI — cards, approvals, and reasoning

[`codex/`](codex/) gives OpenAI Codex CLI a card per session showing the prompt, each
command as it runs, and the final reply. Codex's hooks carry all of that directly, so
no transcript reading is needed for activity, and it is the only front end that fires
an explicit `SessionEnd` — cards retire because the session ended, not because a
process vanished. With **Detailed activity** on (the default) and `model_reasoning_effort` set, the
rollout is also read for the model's reasoning summary.

```powershell
cd codex
.\install-codex.ps1
```

Commands awaiting approval appear on the card and can be approved or denied from
Home Assistant, while the terminal prompt stays usable. See
[`codex/README.md`](codex/README.md) — and note the hooks must be **trusted once** in
Codex or they are skipped silently.

### Anything else, via MCP (experimental)

[`mcp/`](mcp/) holds a separate MCP server that brings the *ask* half of this to
Claude Desktop and other MCP clients, on any OS. It races a Home Assistant card
against the app's own elicitation prompt and cancels whichever loses.

The installer's picker can set it up for you (`-Clients mcp`): it installs the server
under `~/.agent-ha-bridge/mcp`, runs `npm install`, writes a paste-ready client config, and
registers Claude Desktop automatically if present. Or run
[`mcp/install-mcp.ps1`](mcp/install-mcp.ps1) directly.

It speaks stdio by default, and can also serve over HTTP for clients that can't start
a local process — ChatGPT among them. That listener binds to localhost and requires a
bearer token, and refuses to start on a public interface without one, because the
server holds an unscopable Home Assistant token; reach it remotely through a tunnel
rather than by opening a port.

It is a sibling, not a replacement: an MCP server never sees the transcript and can't
start a turn, so there is no activity streaming and no reply-after-the-turn. See
[`mcp/README.md`](mcp/README.md).

---

## License

MIT — see [LICENSE](LICENSE).
