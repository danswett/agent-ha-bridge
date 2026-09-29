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
| **Detailed activity** | Cards carry the model's reasoning and every tool call; fold a session card to keep it short. Off with `detailedActivity: false`. |
| **Real forms** | Multi-field questions become one dropdown per field plus a Send button. |
| **Continuation** | Reply to a finished turn from your phone; it's typed into the session. |
| **Paste an image** | Paste or attach a screenshot in the reply box and it's attached to the prompt. |
| **Start a conversation** | A session appears as soon as it opens, so you can send it its first prompt from the dashboard. |
| **Launch a session** | Pick a workspace, type an opening prompt, press a button — a new CLI session opens on your desktop. |
| **End a session** | An **End session** row on every card, so sessions don't just accumulate. |
| **No polling** | State changes arrive over a Home Assistant WebSocket subscription. |

The card glows **blue** while working, **amber** while waiting on you, and not at all
when idle.

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
* **The transcript is the source of truth.** A `tool.execution_start` for `ask_user`
  paired with its matching `tool.execution_complete` is the authoritative "answered"
  signal, whichever input produced it — so the two paths can't collide.

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
* Nothing extra for the bridge's own dashboard card: the installer registers it as a
  Lovelace resource over the API, so no file share, Samba add-on or credentials are
  needed

---

## Install

The one-liner:

```powershell
irm https://raw.githubusercontent.com/danswett/agent-ha-bridge/main/bootstrap.ps1 | iex
```

Or from a clone:

```powershell
git clone https://github.com/danswett/agent-ha-bridge.git
cd agent-ha-bridge
.\install.ps1
```

### macOS

> **Preview.** macOS support passes the full test suite on macOS in CI, including
> replies typed into a live tmux session, but has not yet had much use on real Macs.
> Please report anything that misbehaves, with the output of `agent-ha-bridge logs`.

The one-liner, in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/danswett/agent-ha-bridge/main/bootstrap.sh | bash
```

It installs what is missing, then hands over to the same installer, which asks the
same questions. From a clone it is `pwsh ./install.ps1`.

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

Then it finds Home Assistant: it probes `homeassistant.local:8123` (the hostname Home
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

A token that doesn't work is reported there and then, with another go at pasting it,
rather than failing at the end of the install.

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
.\install.ps1 -HomeAssistantUrl http://homeassistant.local:8123 -Token 'eyJ...'
```

Then `/restart` any running Copilot sessions so they pick up the hooks, and open the
**Agent Sessions** dashboard in Home Assistant.

Optional out-of-band push when a session needs you:

```powershell
.\install.ps1 -NotifyService notify.mobile_app_pixel
```

The installer is idempotent — re-run it to upgrade in place. Re-running with only
some arguments keeps the rest of your settings, and the previous config is backed up
to `config.json.bak` first. A config written by an older version has any keys it is
missing filled in from the defaults, and one that cannot be parsed at all is reported
and replaced rather than ending the install on a JSON error — the backup is taken
before it is read, so nothing is lost either way.

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
| `homeAssistant.agentUserIds` | Home Assistant user ids that count as an agent rather than you. A session an agent starts or replies to gets a purple edge on its card, so a session being driven remotely says so at a glance. Empty by default, which means nothing is ever marked — see [Telling an agent's turn from yours](#telling-an-agents-turn-from-yours) |
| `homeAssistant.agentToken` | The long-lived token belonging to that agent account. Handed to the MCP server and to every session the bridge launches, so an agent drives the bridge as itself; the daemon and the hooks keep using `homeAssistant.token`. Without it an agent presses with your token and nothing is ever marked — the two settings are useless apart, and `agent-ha-bridge status` says so when only one is set |
| `homeAssistant.agentTokenEnvVar` | Read the agent token from this env var instead (default `AGENT_HA_AGENT_TOKEN`) |
| `dashboard.urlPath` | Lovelace dashboard slug (default `agent-decisions`) |
| `notifications.enabled` / `.service` | Optional notify-style service |
| `copilot.sessionStateRoot` | Override the Copilot CLI's session-state location if not `~/.copilot/session-state` |
| `newSession.enabled` | Set to `false` to hide the "Start a new session" controls (default `true`) |
| `newSession.launcher` | Default agent: `auto` (default: the installed agent used most recently on this machine, else one that is signed in), `agency`, `copilot`, `claude` or `codex`. With more than one installed, the card also gets an Agent dropdown |
| `newSession.codexStartPrompt` | The first message a Codex launched without one is given, so it creates its session and attaches. Empty: the launch waits for a first message sent from the card |
| `detailedActivity` | `true` (default): cards carry reasoning and each tool call. `false`: status and responses only |
| `platform.terminal` | macOS: the window a launched session opens in - `Terminal` (default), `iTerm`, or `none` (the session still runs; `tmux attach` reaches it) |
| `newSession.profiles` | Agency profiles offered on the dashboard (default `["work","home","local"]`) |
| `newSession.defaultProfile` | Profile preselected on the card (default: the first in `profiles`) |
| `newSession.defaultWorkspace` | Workspace label preselected on the card (default: the first in `workspaces`) |
| `newSession.workspaces` | Directories offered as launch targets — a path string, or `{ "label": …, "path": … }`. Folders recent Claude/Codex sessions worked in are added after these, and the home folder is offered if the list would otherwise be empty |
| `newSession.discoverWorkspaces` | Set to `false` to offer only the configured workspaces (default `true`). System folders such as `C:\Windows\System32` are never discovered |
| `newSession.discoverCount` | How many discovered folders to offer (default `8`) |
| `newSession.resumeCount` | How many recent sessions the Resume dropdown offers (default `12`) |
| `newSession.model` | Model preselected on the card (default: **Agent default** — the CLI's own choice). Applies to Copilot and Agency; `newSession.model.claude` / `.codex` do the same per agent |
| `newSession.effort.<agent>` / `.context.<agent>` | Reasoning effort and context window preselected on the card, per agent (`copilot`, `claude`, `codex`; Agency reads Copilot's) |
| `newSession.models.<agent>` | Replace the model list the card offers, e.g. `"models": { "copilot": ["auto", "claude-opus-5"] }`. Copilot's is otherwise read from `copilot help config`; `efforts.<agent>` and `contexts.<agent>` do the same for the other two axes |
| `newSession.allowAllTools` | What the card's **Permissions** row opens on (default `false`). **Allow all** launches without permission prompts: `--allow-all` for Copilot, `--dangerously-skip-permissions` for Claude, `--ask-for-approval never` for Codex, and it answers Claude's folder-trust dialog rather than waiting for a second press. The card decides each launch, so a session started on another machine no longer silently takes that machine's setting |
| `newSession.extraArgs` | Extra CLI arguments for launched sessions, e.g. `["--plan"]` |
| `newSession.copilotPath` | Full path to `copilot.exe` if it is not on the daemon's PATH |
| `newSession.agencyPath` | Full path to `agency.exe` if it is not on the daemon's PATH |
| `newSession.claudePath` / `.codexPath` | Full path to `claude.exe` / the Codex CLI if not on the daemon's PATH |
| `updates.repository` | Repository to check for releases (default `danswett/agent-ha-bridge`) |
| `updates.checkForUpdates` | Set to `false` to disable the update check |
| `updates.checkHours` | How often to check GitHub for a release (default `6`, i.e. 4×/day) |

Prefer keeping the token out of a file? Leave `token` empty and set `AGENT_HA_TOKEN`
in your environment.

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
2. Log in as that user once and create a long-lived token for it (*Profile →
   Security → Long-lived access tokens*). Put it in `homeAssistant.agentToken`, and
   leave your own `homeAssistant.token` alone: the daemon, the hooks and the dashboard
   provisioning still run as you. The bridge hands the agent token to the MCP server
   and into the environment of every session it launches (`AGENT_HA_AGENT_TOKEN`), so
   an agent that goes on to drive another session does so as itself.
3. Find the user's id under *Settings → People → <the user>*; it is the long hex string
   in the URL. Put it in `homeAssistant.agentUserIds`.

   Read it from that URL, not from the token. A long-lived token is a JWT whose `iss`
   claim looks exactly like a user id but is the *refresh token's* id, and using it
   means nothing is ever marked as agent-driven. If the URL is awkward to get at, have
   the agent change something with its own token and read `context.user_id` back off
   the resulting state — that is the same id the bridge compares against.

Steps 2 and 3 are useless apart, and having only one of them fails silently: the
dashboard simply never marks anything. `agent-ha-bridge status` and the installer both
say so when only one is set.

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
authenticates with a long-lived token and provisions everything itself:

| Object | How it appears |
|---|---|
| Per-session entities (`select`, `text`, `sensor`, `button`) | MQTT discovery, created on demand and removed when the session exits |
| `sensor.agent_bridge_sessions` | MQTT discovery, published by the daemon |
| New-session controls (`text`, `select`, `button`, `sensor`) | MQTT discovery, on the same bridge-level device as the update entity |
| The **Agent Sessions** dashboard (`agent-decisions`) | Regenerated by the daemon whenever the live session set changes |

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
existing setup in one pass:

| Before | Now |
|---|---|
| `~/.copilot/hooks/*.ps1` (shared scripts) | `~/.agent-ha-bridge/hooks/` |
| `~/.copilot/copilot-ha-bridge.config.json` | `~/.agent-ha-bridge/config.json` |
| `~/.copilot/mcp`, `~/.copilot/codex-bridge` | `~/.agent-ha-bridge/mcp`, `.../codex-bridge` |
| Scheduled task `CopilotBridgeDaemon` | `AgentBridgeDaemon` |
| Dashboard `/copilot-decisions` | `/agent-decisions` |
| `%TEMP%\copilot-decision-bridge.log` | `%TEMP%\agent-decision-bridge.log` |
| `$env:COPILOT_HA_BRIDGE_CONFIG` | `$env:AGENT_HA_BRIDGE_CONFIG` |

Your Home Assistant token is moved, not re-requested, so the upgrade never prompts for
it again. The old scheduled task and Apps & features entry are removed, and the old
dashboard is replaced by `/agent-decisions` — **re-pin it in the sidebar** if you had
it placed. `~/.copilot` keeps only what belongs to the Copilot CLI: its hook definition
and its session transcripts.

Entity ids do not change, so automations built on `agent_bridge_*` keep working. The
old `$env:COPILOT_HA_BRIDGE_CONFIG` and config path are still read as a fallback, so a
machine that has not been upgraded yet keeps running.

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
| **Profile** | The Agency profile, applied to new and resumed sessions alike |
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

Agency takes `--session-id` itself and uses that UUID for both its own session and the
underlying Copilot one, so the daemon still knows the session id before the process
starts either way.

Configure the workspace list first, or the card has nothing to offer:

```jsonc
"newSession": {
  "workspaces": [
    { "label": "Bridge", "path": "~/repos/agent-ha-bridge" },
    "~/repos/my-app"
  ]
}
```

A few deliberate choices:

- **Only listed directories can be launched.** The dropdown sends a *label*, and the
  daemon resolves that label against this list. A path typed or injected anywhere else
  is never executed, so the config file — not Home Assistant — decides where a session
  may start.
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

It is safe to press. The transcript survives either way, so an ended session stays in
the **Resume** list and can be reopened — a mistaken press costs a window, not the work.

---

## Several machines, one Home Assistant

Install the bridge on as many machines as you like. They all talk to the same Home
Assistant and none of them needs to know about the others.

Each machine publishes its own device — **AI Agent Bridge (DESKTOP)**, **AI Agent Bridge
(LAPTOP)** — carrying its own update entity, its own launch controls and its own session
counter. Entity ids are suffixed with the machine, so
`button.agent_bridge_desktop_new_session` and `button.agent_bridge_laptop_new_session`
are different buttons. Pressing one launches a session on that machine and nowhere else.

There is still **one dashboard**, and it shows everything:

- a **Machines** card listing every machine that has ever registered, with whether it is
  online right now, how many sessions it is running and what version it is on,
- one **Start a new session** card with a **Machine** dropdown at the top — pick where,
  then the workspace, profile and resume rows for *that* machine appear beneath it,
- **Live sessions** summed across the machines that are actually running,
- one card per session wherever it is running, labelled with its machine — and because
  the entities are real, you can answer a prompt on the laptop from the same screen.

The dropdown is a display filter and nothing more. No daemon reads it, and **Launch**
presses the selected machine's own button — a single shared button is exactly what made
one press start a session everywhere at once. With only one machine online there is
nothing to pick, so the dropdown does not appear at all.

Liveness is a heartbeat: each machine reports in every 60 seconds and Home Assistant
marks it offline after three missed beats. An offline machine stays listed in
**Machines**, because knowing a machine exists but is currently off is exactly what you
want when a session you expected is not there — but it gets no launch card, no install
button, and its sessions are hidden, since none of them can be running.

No machine talks to another. Each publishes a retained sensor describing what it is
running, and every daemon reads all of them, so the picture is complete whichever
machine happens to rebuild the dashboard.

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
replacing everyone else's until it is upgraded.

One thing stays shared, because it belongs to the instance rather than to a machine:
the dashboard itself. (The machine dropdown is shared too, but it is created and
retired automatically.) An uninstall therefore leaves
it alone unless it is removing the last machine — see [Uninstall](#uninstall).

Upgrading an older install migrates itself. The bridge-level entities it published
before were unscoped, so the first run of the new daemon withdraws them and republishes
them under this machine's name. Nothing needs doing by hand.

---

## Updating

The daemon asks GitHub for the newest release a few times a day (every 6 hours by
default, tunable via `updates.checkHours`) and publishes the result as
a Home Assistant **update entity**, so a new version shows up on the dashboard and in
Home Assistant's own Updates list — with the release notes and a one-press **Install
now** button. Pressing it shows a spinner while the install runs and leaves a
notification when it finishes — *Bridge updated to X*, or the error if it failed —
then restarts the daemon so the new version is actually running.

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
.\tests\test-decision-args.ps1    # ask_user argument parsing and recovery
.\tests\test-decision-retry.ps1   # HTTP retry / transient-failure classification
.\tests\test-http-guard.ps1      # a suite cannot reach a real Home Assistant
.\tests\test-bridge-adapter.ps1   # shared adapter orchestration (entities, status, notifications)
.\tests\test-dashboard.ps1        # generated dashboard: title, view, session summary + version
.\tests\test-security.ps1         # template injection, path and topic safety, token handling
.\tests\test-copilot-activity.ps1 # Copilot's transcript reader, and the inline thinking on its card
.\tests\test-reliability.ps1      # request budget, StrictMode safety, stale-state pruning
.\tests\test-update.ps1           # version comparison, release cache, failure safety
.\tests\test-update-outcome.ps1   # install spinner + updated/failed notification
.\tests\test-restart-restore.ps1  # a daemon restart restores cards instead of blanking them
.\tests\test-driver-card.ps1      # the agent/human driver reaching the card, on every path that publishes one
.\tests\test-new-session.ps1      # launching a session: argument quoting, the workspace allowlist, press handling
.\tests\test-stop-session.ps1     # ending a session: graceful /exit, terminate fallback, press handling
.\tests\test-install-clients.ps1  # installer client selection (‑Clients, persisted, defaults, first-install picker)
.\tests\test-install-deps.ps1     # dependency offers (PowerShell 7, Node, the agent CLIs) and PATH handling
.\tests\test-install-connection.ps1 # Home Assistant discovery without a pointless prompt, and the connection check
.\tests\test-install-command.ps1  # the agent-ha-bridge command, its payload, and a sandboxed end-to-end install
.\tests\test-install-cards.ps1    # the dashboard's frontend cards: detection, and repairing an unregistered one
.\tests\test-layout-migration.ps1 # upgrading a pre-rename ~/.copilot install in place
.\tests\test-verbose-toggle.ps1   # Detailed activity helper is provisioned without ever resetting it
```

These are plain PowerShell, need no Home Assistant, and run in a couple of seconds.
The Claude adapter and the MCP server have their own suites — see their READMEs. The
dashboard cards have one of their own in `frontend/test/test-cards.js`, run with plain
`node` against a small DOM stand-in. CI runs the full list in
`.github/workflows/ci.yml`, along with `tests/test-bootstrap.sh` — what the macOS
installer hands to `installer` — on the macOS runner, because it needs BSD `mktemp`.

The native hook is Go (`hook/`): `go test ./...` there, and `go build -o
agent-bridge-hook.exe .` (no `.exe` on macOS) for a local build - which the installer
then uses instead of downloading one, and which `tests/test-native-hook.ps1` runs end
to end with the daemon's spool.

Nothing in the suite may disturb a real install on the machine running it. The
installer tests run against `-TargetHome` with `-SkipTask`, `-SkipPath` and
`-SkipDependencies`, configure only Copilot (the Codex adapter registers a plugin with
the real `codex` binary, and the MCP one can write to Claude Desktop — neither honours
`-TargetHome`), inject their own package-manager runners, drive PATH through injected
getters and setters, and assert afterwards that the user PATH and the real config are
byte-for-byte unchanged.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Cards show `unknown` after a Home Assistant restart | Self-heals within one reconcile (~15 s); the entities are optimistic and have no state to restore. |
| "Entity not found" on a card | The daemon provisions entities on its next pass; check the daemon log. |
| Answers picked in Home Assistant do nothing | The session predates the install — `/restart` it. |
| Nothing at all happens | Check `$env:TEMP\agent-bridge-daemon.log` and `agent-decision-bridge.log`. |

The daemon runs as the hidden scheduled task `AgentBridgeDaemon`:

```powershell
Get-ScheduledTask -TaskName AgentBridgeDaemon
Get-Content $env:TEMP\agent-bridge-daemon.log -Tail 20
```

---

## Notes and limitations

* **The reply box needs the bridge's own card.** The installer registers
  `agent-bridge-reply-card.js` inline, as a `data:` URL Lovelace resource, over the
  websocket API. There is no API for writing a file into `www`, but a resource is only
  a URL, and the frontend loads a module resource with a plain `<script src>`, so no
  file share is involved. The card is about 27 KB, sent with Home Assistant's resource
  list when the app or page loads. It shows as a very long URL under Settings >
  Dashboards > Resources; that is expected. If it cannot be registered, the dashboard
  falls back to a plain `text` entity and Send button, with a **255-character** cap
  on replies, until the next install or update registers it. Installs from before
  1.10.1 copied the card into `config\www`; that file is no longer used and can be
  deleted.
* **Images go via Home Assistant.** A pasted image is uploaded to Home Assistant, pulled
  down by the daemon, attached to the prompt as `@<path>`, and then deleted from Home
  Assistant. Local copies are kept for a day in case the CLI is slow to read them.
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

* A **single-field** form becomes one dropdown.
* A **multi-field** form (up to 4 fields) becomes one dropdown per field plus Send, so
  every combination stays reachable without a combinatorial option list.
* Larger forms fall back to freeform, with the question carrying a numbered outline of
  every field and its options, marking any default.
* Questions are carried up to 6,000 characters and each choice up to 600; anything
  longer is truncated and the card says so.

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
| `agent-bridge-supervisor.ps1` | Keeps one daemon alive with backoff; a named mutex prevents a second instance |
| `route-ask-user-v3.ps1` | The non-blocking `ask_user` router |
| `notify-agent-response.ps1` | Non-blocking response mirror + card |

Logs: `%TEMP%\agent-decision-bridge.log` (hooks), `%TEMP%\agent-bridge-daemon.log`,
`%TEMP%\agent-bridge-supervisor.log`. Hook config changes reach a running CLI only
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


