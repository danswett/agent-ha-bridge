# D2.1 control-command eligibility component (UNWIRED)

`hooks\bridge-control-policy.ps1` defines only
`Get-BridgeControlEligibility` when imported. Import performs no configuration read,
file write, network operation, clock lookup or runtime registration. Nothing in the
existing daemon, cards, MCP server or configuration examples imports or calls it.
Adding the section described below to a running installation does **not** activate
authorization. This is an internal component contract, not an operator switch or an
already-effective security mitigation.

The component reads one explicitly supplied configuration and returns a named
eligibility result. It does not authenticate a principal, enroll anyone, resolve a
live process/workspace/release, admit or queue a request, dispatch input, create an
acknowledgement, sign a receipt or prove completion. Those remain separate work.

## Trust and caller boundary

All seven parameters are mandatory. The component has no installed/default
configuration lookup, environment credential resolution, permissive setting fallback
or positive-policy cache.

| Parameter | Exact type and fields |
|---|---|
| `ConfigurationContext` | PowerShell hashtable with exactly `configPath`, `installationId`, `machineId`. All are strings. The path must be fully qualified and explicitly chosen by the trusted caller. |
| `AssumedPrincipal` | Hashtable with exactly `issuer`, `subject`; nonempty identity strings. This is an **assumption** from a future verified adapter, not authenticated by its shape. |
| `AssumedTarget` | Hashtable with exactly the action-specific target fields below. It is a caller-supplied snapshot, not current-target evidence created by this helper. |
| `CommandBytes` | Nonempty `byte[]` containing the command's exact UTF-8 JSON bytes. Strings and object arrays are refused, not coerced. |
| `ContentBytes` | `byte[]`, including an explicit empty array for read/update. This is a separate exact-byte content buffer, not a path or a native argument vector. |
| `Now` | A `DateTimeOffset` value. A string or `DateTime` is not converted into a clock. |
| `Limits` | Hashtable with exactly the five numeric fields in the next table. Values must be `Int32` or `Int64`, not Boolean, string, floating-point or decimal values. |

Hashtable key names are exact, including case; unknown fields are refused.
Identity strings retain their decoded JSON/string identity. They are ordinal,
nonempty, at most256 UTF-16 code units, without control characters, leading/trailing
whitespace or wildcard characters `*?[]`. No case folding, trimming, prefix/slug
matching or Unicode normalization confers a grant. Configuration paths allow
ordinary internal spaces and are limited to32768 code units; they are not expanded
as wildcard expressions.

The trusted caller must validate the configuration location and obtain principal,
target and approval facts outside untrusted command data. This component does not
certify file ownership, filesystem topology, issuer/channel authenticity, process
liveness or workspace approval. Do not expose its separate context arguments as
remote caller-controlled fields. A caller-set `verified` property is rejected, not
converted into authority.

If the existing `Assert-BridgeTestPath` function is loaded, it is applied before the
configuration read. In a detected test context the helper refuses to read without
that guard. Marked write/network guard exceptions propagate, including through inner
exceptions. The helper does not import runtime/bootstrap scripts to obtain defaults.

## Finite bounds, without production defaults

| Caller limit | Inclusive accepted range |
|---|---:|
| `maxConfigurationBytes` | 1..16777216 |
| `maxCommandBytes` | 1..16777216 |
| `maxContentBytes` | 1..16777216 |
| `maxLifetimeSeconds` | 1..86400 |
| `maxFutureSkewSeconds` | 0..300 |

These are implementation ceilings on **explicit inputs**, not suggested production
settings. The policy must also provide `maxCommandBytes`, `maxContentBytes`,
`maxLifetimeSeconds` and `maxFutureSkewSeconds`, with the same ranges. The effective
value of each is the smaller of the caller and policy values. Nothing missing
defaults to a grant or an unlimited value.

Caller buffer lengths are checked before loading the policy. Both caller and policy
byte limits are checked before cloning, UTF-8 decoding, JSON parsing or hashing of
command/content. A bounded snapshot is then used consistently for parsing and
identity. The caller must not concurrently mutate buffers or context inputs during
the call.

The configuration file is opened read-only, its length is checked before allocating
its byte buffer, and a short read or an extra byte is reported as
`ConfigurationChangedDuringRead`. UTF-8 decoding is strict. JSON has no comments or
trailing commas and has a nesting ceiling of32. A UTF-8 BOM is not stripped; the JSON
parser's refusal is an explicit invalid-JSON result.

This is **not network-stream admission**: caller buffers are already materialized.
It is not an OS/filesystem deadline or a promise about an underlying network-mounted
configuration path. Future ingress must bound streams before creating these buffers.

## Configuration schema

The configuration root must be a JSON object. Its one exact `controlAuthorization`
member has this shape; names below are required and unknown members inside this
section are rejected:

```text
controlAuthorization:
  version:                 integer token 1
  generation:              identity string
  installationId:          identity string
  machineId:               identity string
  limits:
    maxCommandBytes:        bounded integer
    maxContentBytes:        bounded integer
    maxLifetimeSeconds:     bounded integer
    maxFutureSkewSeconds:   bounded integer
  principals:              array, 0..128
    item:
      issuer:               identity string
      subject:              identity string
      grants:               array, 0..4
        item:
          capability:       read | reply | launch | update
          scopes:           array, 1..128
            item:           exact capability-specific scope
```

Only canonical decimal integer tokens are accepted for numeric JSON fields: no
quoted numbers, Boolean values, fractions, exponent spelling or negative zero.
`version` must be the literal integer token `1`.

The policy installation/machine must equal the separate configuration context.
Every scope repeats those same installation/machine IDs. Duplicate reserved root
sections, differently cased reserved section names, duplicate properties inside
known policy objects, duplicate issuer/subject pairs, duplicate capabilities per
principal and duplicate exact scopes are invalid.

An empty principal list or an explicit empty grant list grants nothing. Missing,
null, empty, unreadable or malformed policy does not select a permissive default.
Unrelated configuration fields are not interpreted or mutated; the full document
still must fit the finite byte/depth limits and be valid JSON. No configuration
backup is consulted and no invalid replacement reuses a previously eligible result.

## Component-owned action mapping and scope schema

The command's action, not a caller-selected permission string, determines the
required capability.

| Supported action | Required capability | Exact scope properties |
|---|---|---|
| `session.read` | `read` | `installationId`, `machineId`, `client`, `sessionId` |
| `session.reply` | `reply` | `installationId`, `machineId`, `client`, `sessionId` |
| `session.launch` | `launch` | `installationId`, `machineId`, `client`, `workspaceId` |
| `installation.update` | `update` | `installationId`, `machineId` |

There are no wildcard fleet/session scopes and no capability implications. A read
grant does not permit a launch or update. A valid scope is an exact tuple, not a
prefix or pattern. Actions, capabilities, clients and permission mode also use
ordinal equality, not culture-sensitive matching of visually similar strings.
`client` is exactly `copilot`, `claude` or `codex`; Agency-launched
Copilot is represented by its native client kind, not a new implicit capability.

`sessionId` is a full nonzero lowercase UUID in hyphenated36-character form. The
sixteen-character dashboard node ID is not accepted as a full session identity.
Other native session-ID forms are not silently transformed; supporting them would
require an explicit contract revision. Installation, machine, workspace and release
IDs are exact opaque identity strings supplied by the future trusted adapter, not
IDs that this component discovers or fabricates.

Stop, cancellation, resume, decisions, approvals, folder trust, allow-all launches,
session transfer/export/import and other actions/modifiers are unsupported here.
They do not inherit reply/launch authority. Existing runtime paths and native
permission behavior remain unchanged because this component is unwired.

## Command schema and target binding

```text
version:             integer token 1
requestId:           nonzero lowercase32-hex identifier
action:              one of the four supported action strings
issuer:              identity string, must equal AssumedPrincipal.issuer
subject:             identity string, must equal AssumedPrincipal.subject
policyGeneration:    identity string, must equal the freshly read policy generation
target:              exact action-specific object below
issuedAtUtc:         exact UTC timestamp string
notBeforeUtc:        exact UTC timestamp string
expiresAtUtc:        exact UTC timestamp string
contentSha256:       lowercase64-hex SHA256 of ContentBytes
capability:          OPTIONAL; if supplied, must equal the component-derived capability
```

All other command properties are rejected. In particular, `actor`, `context`,
`user_id`, `verified` and unknown permission modifiers cannot create authority.
The command's issuer/subject fields are **claims to bind**, not a source for the
separate assumed principal. Randomness and global uniqueness of a request ID are
caller obligations; checking its format does not establish either.

| Action | Exact target properties |
|---|---|
| `session.read` | `installationId`, `machineId`, `client`, `sessionId` |
| `session.reply` | Read fields plus integer `processId` in1..2147483647 and exact string `processStartedAtUtc` |
| `session.launch` | `installationId`, `machineId`, `client`, `workspaceId`, lowercase64-hex `launchConfigurationSha256`, `permissionMode` exactly `ask` |
| `installation.update` | `installationId`, `machineId`, `releaseId`, lowercase64-hex `artifactSha256` |

The separate target context must have precisely the same action-specific fields.
Every field must equal the command target; process IDs are strict integers and
other values are ordinal strings. Scope matching is an additional check. A matching
snapshot does not prove the process still exists, a workspace is currently approved,
or an artifact is authentic. Those facts must be established and rechecked before
any future dispatch.

Read/update content must be an explicit empty byte array. Reply/launch content must
decode as nonblank UTF-8 text. It is content, not native launch options or a trusted
schema carrying identities. This component neither rewrites control characters nor
invents an attachment/quoting transport. Any eventual consumer must honor its own
validated content/permission contract.

### Exact time and byte identity

All wire timestamps, including process creation time, use the exact format
`yyyy-MM-ddTHH:mm:ss.fffffffZ`. Alternate offsets, missing precision, nonstrings and
invalid calendar values are rejected, not converted into equivalent identities.
The implementation parses for comparisons but retains exact string identity.

`issuedAt <= notBefore < expiresAt`, and `expiresAt - issuedAt` must not exceed the
effective lifetime. Issuance beyond the permitted future skew is refused.
`expiresAt <= Now` is expired, including equality; `notBefore > Now` is not yet
eligible. Skew tolerance does not bypass not-before. There is no clock lookup,
clock-history state or rollback protection across calls.

`CommandSha256` hashes the original bounded command snapshot, including whitespace,
property order and JSON escape spelling. `ContentSha256` hashes the exact separate
content snapshot, including line endings. The claimed content digest must match.
No parsed/reserialized command or date-coerced value defines the digest. Decoded
JSON strings still compare ordinally: two escape spellings can denote the same ID,
but their raw command digests differ.

## Result and safe diagnostics

Every ordinary result contains exactly:

| Field | Meaning |
|---|---|
| `Kind` | `ControlCommandEligibility` |
| `Version` | integer1 |
| `Eligibility` | `Eligible`, `Ineligible`, or `Unavailable` |
| `Reason` | Named component reason; success is `EligibleUnderAssumptions` |
| `RequiredCapability` | Component-derived capability, or null before derivation |
| `RequestId` | Validated request ID, or null before validation |
| `CommandSha256`, `ContentSha256` | Exact digests, or null before their computation |
| `DiagnosticPhase` | Inputs, configuration read/UTF-8/JSON, policy, command UTF-8/JSON/validation, time, content UTF-8/validation, or eligibility |
| `DiagnosticType` | Empty for component refusals; actual exception class for handled file/decoder/parser failures |

Reasons distinguish missing/invalid inputs and policy, byte ceilings, version/action
and capability mismatch, principal/configuration/generation/target binding, missing
grants/scopes, invalid time, expiry, not-before and content/digest refusal. File errors
return `Unavailable / ConfigurationReadFailed`, with the actual safe exception class.
Invalid UTF-8/JSON returns `Ineligible / InvalidUtf8` or `InvalidJson`.

No result returns configuration/policy bodies, credentials, raw content, paths,
exception messages, authenticated/admitted/done flags or native completion claims.
Marked test guard exceptions and unexpected programming/platform exceptions propagate
rather than becoming eligibility. Callers must not convert an exception or missing
result into a grant.

An eligible result is only a policy/shape decision under the stated assumptions.
Repeated calls can both be eligible. There is no durable request ID store, admission
transaction, ordering, replay prevention, target lease, timeout/cancel protocol,
acknowledgement, client-read proof or completed-turn evidence.

## Fixture boundary

`tests\test-control-policy.ps1` is a canonical Offline suite, not an independent
entrypoint for installed helpers. It imports the actual component normally and
uses real isolated configuration files, deterministic clock values and explicitly
synthetic assumed principal/target inputs. The file-as-directory/missing-file and
decoder/parser failures go through the real reader/evaluator. The existing S1 path
guard is exercised without creating or reading the outside target.

The fixture includes the full capability matrix, strict policy/command/context
failures, exact byte/time boundaries, unique principal/scope cardinality boundaries,
original-byte digest checks, read-only preservation, real guard propagation and
fresh policy reads. A repeated eligible evaluation explicitly demonstrates that this
is not replay prevention; a supplied clock moving backwards demonstrates that there
is no persisted clock-history protection. It does not authenticate HA/MQTT/MCP, probe
a live process, alter privileges or exercise producer migration.

Source preparation and static parser/analyzer results do not mean this fixture has
run. Runtime validation requires its own reviewed byte seal, assertion inventory and
canonical-run authorization.
