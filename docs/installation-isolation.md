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

New attachments use a protected `install-<id>` directory under the installation's
LocalAppData on Windows, or its BridgeHome on macOS and when Windows LocalAppData
is missing. Directories and destination files are protected before content is
written and checked afterward; existing path/reparse checks do not promise
race-free protection against concurrent filesystem changes. Public/shared-TEMP
fallbacks are not used. Unidentified legacy installations refuse attachment sends
until reconfigured; old shared directories and unattributed files are left alone,
not migrated, re-permissioned or recursively removed. `-NoCreate` only reads the
chosen path; it does not create, repair permissions or migrate data. A private path
that the current reply transport cannot represent, including whitespace, refuses
the whole attachment-bearing submission rather than sending only its text or a
subset. Failed staging or transport retains source images and staged private data
without automatic retry; this is not a durable queue or a client acknowledgement.
`-KeepConfig` retains installation metadata so reconfiguration keeps the identity.

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

### Update lookup, intent and completion

Update status distinguishes an unavailable lookup, a latest-release endpoint
returning 404, a known release with nothing newer to install, and a known newer
release. GitHub's bare 404 does not establish that the repository exists or that
the caller can access it. Neither unavailable nor not-found means "up to date";
both leave the latest version unestablished. Failed lookups retain the short retry
interval rather than trusting an older release left in the cache.

The MQTT update entity is unavailable while that version is unestablished; other
entities on the machine remain available. The publisher omits `latest_version`
and derives entity-specific availability from its presence on the state topic.
Stock Home Assistant rejects JSON null versions, and omission alone retains the
previous version attribute. Do not interpret that retained attribute as a new
successful check, or substitute an empty/"unknown" version string.
The publisher always supplies `release_summary`, using an empty string to clear
previous failure text when a successful lookup has no release notes. Omitting the
summary retains it, and replaying identical discovery does not reset it.
This uses the [MQTT update availability contract](https://www.home-assistant.io/integrations/update.mqtt/)
and the stock 2026.9.4 consumer at
[`9212531f40a0b7b23229a90d688dd79d9dfccff4`](https://github.com/home-assistant/core/tree/9212531f40a0b7b23229a90d688dd79d9dfccff4/homeassistant/components/mqtt).

`update -Check` never prompts or installs, including with `-Force` and without
`-Yes`. An unestablished lookup exits unsuccessfully rather than reporting current.
`-Force` reinstalls the validated newest release even if its version is equal to or
older than the recorded version. Without Force, a known older release is a no-op.
Force does not bypass lookup, archive VERSION, or installation-root checks.

Detached `Started` means only that the operating system accepted the launch.
Foreground completion requires the actual child's exit code and this attempt's
typed terminal receipt. Each foreground attempt reserves its own result file
beside staging; the daemon atomically claims a separate shared notice. Neither a
stale notice nor a daemon consuming that notice can supply or erase the parent's
proof. Legacy Boolean notices remain readable, but cannot prove a new foreground
attempt. Malformed, unknown-schema, or string-valued success fields are rejected.
Child output is retained in the selected runtime's update log before foreground
staging is removed.

An outcome records the **attempted** release separately from the installed version
read again from the selected configuration. A failed in-place installer may have
already changed that record or other files; failure does not claim rollback or
preservation of old bytes. "Installer completed" covers the installer return and
owned-runtime restart request, not required local installation health. Whole-install
locking, complete payload manifests, atomic activation, rollback and required local
health remain separate work; this slice does not make installation transactional.

## Approved workspaces and isolated launches

`newSession.workspaces` is the executable directory allowlist. Its entries are path
strings or objects containing `label`, `path`, and optionally the Boolean `isolate`.
An empty, missing or unusable list does not authorize Home or a discovered folder.
Local discovery produces suggestions for explicit configuration, not permission.
Existing resume history is filtered against current approval; the actual launch
consumer checks again. A missing resume directory is never replaced by another one.
A managed worktree of an approved isolated repository may resume in place.
An approved repository subdirectory remains that same relative subdirectory in the
new checkout; it does not approve the generated parent root. A subdirectory missing
from the selected base, or escaping the new tree through a link, refuses the launch.

An entry with `"isolate": true` requests a separate worktree for a fresh launch.
Missing Git, invalid repository/root, capacity or creation failures refuse the launch
with a diagnostic. They never start the session in the original checkout. Offline
fetch failure can still use a readable local base, and is reported in the worktree
detail. These settings take effect when the bridge reloads its configuration.

Creation and cleanup share a repository-scoped operation gate. A native Git lock
protects an isolated launch while its client is starting or waiting to register,
including when the configured idle age is zero. Registration releases only that
launch's own lock; pre-existing operator locks are not removed. An unconfirmed launch,
lost registration or daemon failure may leave the tree locked for inspection.
Establish that no session still uses it before explicitly unlocking or removing it.
This is a host-local safety change, not a shared dashboard or client-state migration.

Cleanup reads uncapped current Copilot/Agency, Claude and Codex process/registration
state independently of suggestion settings and caches. Descendant working directories
and path aliases protect their containing tree. Unreadable, incomplete or unmapped
live state blocks cleanup; age alone never proves a session ended. A standalone
Agency launcher is conservatively treated as a potentially starting session.
Relative working directories and registrations predating the current process
generation are uncertain, not evidence that another worktree is unused.

Only marked, unlocked, sufficiently old, clean and detached trees with no commits
ahead of their readable base qualify. Dirty, untracked, ignored, unmerged,
unowned, linked/submodule and uncertain trees are retained. Git's ordinary non-forced
worktree removal can delete ignored files, so the bridge instead locks the Git
metadata, removes only clean tracked paths through a private index, and removes
directories only if empty. New untracked or ignored data prevents that removal. Missing
tracked files are restored without overwriting existing files or replacing the real
index. Git retains the removed tree's administration for its normal maintenance;
the bridge does not prune other owners' missing worktree records.

### Listing workspace suggestions

The launch card shows configured targets only; it does not automatically display
discovered folders. `discoverWorkspaces` and `discoverCount` apply to the following
explicit, read-only PowerShell helper invocation. Set `$bridgeRoot` to the actual
installation root when it is not the default:

```powershell
$bridgeRoot = Join-Path $HOME '.agent-ha-bridge'
$hooks = Join-Path $bridgeRoot 'hooks'
. (Join-Path $hooks 'decision-bridge-common.ps1')
. (Join-Path $hooks 'session-launch.ps1')
Get-BridgeDiscoveredWorkspaces
```

This prints eligible local folder suggestions without starting a client, changing
configuration or approving a target. Review the results, add only the desired paths
to `newSession.workspaces`, and reload the bridge configuration before launching.
Setting `discoverWorkspaces` to `false` makes this helper return no suggestions.
