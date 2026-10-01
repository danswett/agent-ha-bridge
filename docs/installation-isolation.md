# Installation ownership

The bridge records a local installation identity and its resolved paths in
`installation.json` beside `config.json`. This file contains paths and an opaque
identifier, not credentials. Keep it with the installation; copying another
installation's metadata to a different root is rejected.
An installed custom native binary missing that metadata cannot use an ambient
daemon. Restore its metadata before relying on that installation.

## Path binding

An installed `agent-ha-bridge` command belongs to its own directory. Configure,
update and uninstall forward that directory with `-InstallRoot` and preserve
`-TargetHome` for isolated installations. They cannot be retargeted through extra
command arguments or an inherited configuration override.

Standalone scripts still support `AGENT_HA_BRIDGE_CONFIG`, the legacy configuration
locations, and `-TargetHome`. An explicit missing or unreadable configuration never
falls through into a different home. The initial normal installation resolves
`COPILOT_HOME`, `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, and the Desktop configuration
override; its metadata preserves those bindings for later operations. A target home
does not inherit the invoking account's client or Desktop paths.

Adapter payloads carry a `bridge-root.json` pointer. This makes their PowerShell
fallbacks and the native hook use the same shared core even when the client caches
the adapter elsewhere. The native fast path remains native: no additional shell is
started to resolve these paths.

New installations keep heartbeats, registration files, spooled events, update
staging/outcomes and daemon state under `<install root>\runtime`. Task names and
mutexes include the local installation identity. The default pre-metadata layout
continues to understand its legacy temporary paths.

The optional Dev Box timer uses `AgentBridgeDevBoxKeepAwake_<installation-id>`.
Its detached worker writes an owned process receipt before its one-pass operation
and removes that receipt on completion only when process identity still matches.
An installation-scoped mutex prevents overlapping detached passes from replacing
one another's receipt. Its log stays in the installation runtime directory. A verified legacy fixed task
is retired before the scoped task is installed; unrelated task actions are preserved.

When a verified legacy daemon owns the old heartbeat, installation stops that
writer and copies its state and backup without rewriting their contents. Registry
and pending-marker copies require a matching session and a transcript inside the
recorded client root. The old mutex guards that handoff. Unattributed legacy files
are retained rather than assigned to a new owner by filename alone.
Only the canonical replacement root adopts a detected pre-rename layout; the
installation record retains that attribution for adapter registration cleanup.
A separate custom root cannot migrate another installation's legacy files.

## Selected clients

An explicit `clients` array is authoritative, including an empty array. Discovery
does not activate an omitted local client. `autoConfigureClients` defaults to
`true`, but repairs only selected adapters; set it to `false` to disable that
maintenance. Removing a client is not undone by the next discovery pass. Running
an adapter installer explicitly records that opt-in; automatic repair must still
find the client in the saved selection before changing it.
Recorded installations read that selection again during discovery and repair, so
a standalone adapter removal takes effect without stopping the remaining bridge.
Pre-selection legacy configurations keep their compatibility behavior until the
installer records a selection.

## Removal and degraded operation

Removal stops the owned service, supervisor, daemon, detached keep-awake worker and background adapter setup
before clearing entities or removing registrations and payloads. A process name or
heartbeat PID alone is insufficient: executable, start identity, script path and
installation ownership are checked. Unrelated processes and registrations are not
stopped or replaced.
Standalone adapter removal first opts that client out and stops only its setup
worker. Whole-install removal and reconfiguration own the daemon/service shutdown;
the first identity upgrade also removes its verified pre-metadata service.
An unreadable recorded process or an unconfirmed service shutdown blocks removal
rather than treating the writer as stopped. Unattributed pre-rename configurations,
hooks and skills are preserved, even when they use historical bridge filenames.
Installer and uninstaller bootstrap paths are checked before shared helpers load.
Owned payload boundaries are checked before imports or child-file changes; linked
payloads are refused without executing or deleting the linked installation's files.

Claude removal matches the installation's actual hook commands, including backups;
unrelated hooks survive. Codex operations run with the recorded `CODEX_HOME` and
working directory and verify the marketplace's source root before removal. If the
Codex CLI or a required cleanup helper is unavailable, removal reports the blocker
and retains the payload rather than leaving an active registration pointing at
deleted code. MCP retains its config-reference credential model and removes only
entries pointing to this server, from both the Desktop file and its existing backup.
Claude and Codex session-entity cleanup reads each adapter's owned registry
independently; it does not require a Copilot session-state directory.

New attachment storage is partitioned by installation identity under the existing
attachment allocation policy. This does **not** change its space-free path,
PUBLIC fallback or permissions policy. Shared legacy attachment directories and
unattributed files are not recursively removed. `-KeepConfig` also retains the
installation metadata so a later reconfiguration keeps the same identity.

Target-home/custom-root installations do not register system services, alter user
PATH, install global dependencies or provision shared Home Assistant resources.
They refuse entity deletion because the fleet namespace is still shared. A target
directory is **not an OS sandbox**: native client execution and network checks
still require an appropriate environment. Host/Platform tests remain restricted
to disposable GitHub-hosted runners.

Fleet MQTT/entity naming and transactional update/rollback policy are unchanged.
An update whose installer cannot accept the bound installation root is refused
before that installer runs. Restart existing clients after adapter changes so
cached hooks use the current payload.
