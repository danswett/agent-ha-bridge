# Pairing a machine into the fleet

Session transfers (#77) are signed with a fleet secret every machine must hold. Today
that secret is generated on one machine and has to be carried to every other one by
hand, as a file - which is how DSWETT-DEV-VM1 came to have a
`transfer-secret.txt` sitting in its bridge folder. Nothing in the installer knows the
secret exists, and nothing turns sharing on.

This describes making it part of setup:

* `agent-ha-bridge configure` gets a **session sharing** step: enable sharing and
  resume, and join this machine to the fleet.
* Joining is done by **pairing**: the new machine shows a six-digit code, you type it
  into the dashboard, and an existing machine hands over the secret, encrypted for the
  new machine alone. Nothing is copied by hand.
* Pasting the secret stays available as a fallback for when pairing cannot run.

> **Implemented** in `hooks/bridge-pairing.ps1` (the protocol, pure) and
> `hooks/bridge-pairing-io.ps1` (Home Assistant, the daemon and the joiner), with
> `hooks/bridge-pairing-entry.ps1` as the process the daemon and `agent-ha-bridge pair`
> start. Two refinements made while building it are marked *as built* below.

## What has to stay true

The fleet secret is *membership*, not identity (see
[cross-machine-resume.md](cross-machine-resume.md#what-the-fleet-secret-does-and-what-it-deliberately-does-not)).
Pairing distributes that membership secret and nothing more. It must not become a
competing identity, command-authorisation or target-binding scheme; that contract is
owned elsewhere ([control-authorization.md](control-authorization.md)) and pairing does
not pre-empt it.

The rest follows from the transfer design's threat model:

| Party | Trusted? | Why it matters here |
|---|---|---|
| **MQTT broker, and anything holding broker credentials** (Frigate, Zigbee2MQTT, ESPHome...) | **No** | Can read every topic and publish to any, including the state topics behind the bridge's own MQTT entities. A code shown on an MQTT-backed entity can be spoofed. |
| **Home Assistant core, and holders of an HA access token** | Yes | They can already drive every session through the dashboard. A broker-only client cannot write or read HA-native state. |
| **Recorder, logbook, backups** | Retain everything they see | Nothing secret may pass through entity state or service-call data in a form that is useful later. |
| **The two machines' own terminals** | Yes | Where the person actually is. |

So: **key exchange may travel over MQTT, but the confirmation must not.** Every value
the person compares or types, and the sponsor's final acceptance, goes through
HA-native state that a broker-only client cannot forge.

## The flow, as the person sees it

On the machine joining (the **joiner**):

```
agent-ha-bridge configure
...
==> Session sharing
    Share and resume sessions across machines? [Y/n]
    Joining the fleet. Machines that can let this one in:
      1) DSWETT-HOME        (online)
      2) DSWETT-DEV-VM1     (online)
    Pair with [1]: 1

    On the dashboard, type this code into "Pair a machine":

        482 913

    Waiting for DSWETT-HOME... paired. Sharing is on.
```

The field is one HA-native text helper, **Pair a machine**. You type the six digits and
press Enter. That's the only action, and it happens on whatever screen you have, phone
included.

*As built:* the field is the helper itself (Settings > Devices & services > Helpers, or
the entity on any dashboard), not yet a Fleet card on the shared agent dashboard.
Changing that dashboard means a renderer version bump under A28's publication fencing,
which is a release decision of its own, so the card is a follow-up.

The first machine in a fleet has nobody to pair with, so you create the fleet there:
`configure` generates the secret and a public fleet id. That is never inferred from
finding no sponsor online - the members may all be offline, and an untrusted broker can
hide their status - so it is an explicit choice you type (`NEW`), and skipping is the
default.

## Protocol

Roles: the **joiner** J and the **sponsor** S, a machine that already holds the secret,
which the person picked by name in J's terminal.

Keys are ephemeral **ECDH P-256**, made per attempt and discarded afterwards
(`System.Security.Cryptography.ECDiffieHellman`, in .NET on Windows and macOS).
Messages use non-retained MQTT topics under `agent_bridge/pairing/<attempt-id>/`, with
no discovery config, so no entity and no recorder state are ever created for them.
They are received over HA's WebSocket `mqtt/subscribe`, as transfer chunks already are.

1. **J → S: commit.** J makes a key pair (pkJ) and a 32-byte nonce nJ, and writes
   `request:<S's slug>:<attempt>:<fleet id>:<J>:<SHA-256 commit of pkJ ‖ nJ>` into
   the helper.

   *As built:* the design first sent this over MQTT. It goes through the helper instead,
   because the helper is the one channel every machine already watches, the request is
   then HA-authenticated as well, and it needs no new MQTT entity. Every value in it is
   public, so the recorder keeping it costs nothing.
2. **S → J: offer.** S checks that the fleet id is its own and that no other pairing is
   in progress, makes its own key pair (pkS) and nonce nS, and publishes `{pkS, nS}`.
   S has not yet seen pkJ, and that is the point of the commitment.
3. **J → S: reveal.** J publishes `{pkJ, nJ}`. S checks that it matches the commitment
   and abandons the attempt if not.
4. **Both** compute
   * the transcript `T = SHA-256("agent-ha-bridge pairing v1" ‖ attempt ‖ fleetId ‖ J ‖ S ‖ pkJ ‖ pkS ‖ nJ ‖ nS)`;
   * the code `SAS = (first 4 bytes of SHA-256("sas" ‖ T)) mod 10⁶`, shown as six digits;
   * the key `K = HKDF-SHA256(ECDH(pk, sk), salt = T, info = "fleet secret")`.
5. **J** shows the code in its terminal. **You** type it into **Pair a machine**
   (`input_text.agent_bridge_pairing`). The helper is created when someone chooses to
   pair - `agent-ha-bridge pair` or the sharing step in `configure` - and never by a
   daemon, so one you delete on purpose stays deleted until you pair again.
6. **S** reads the helper through HA, never MQTT. If the value equals its own code, S
   * writes an HA-native acceptance into the same helper: `accepted:<J>:<first 16 hex of SHA-256("accept" ‖ T)>`;
   * publishes `{ciphertext: AES-256-GCM(K, secret, aad = T)}`.

   If the code differs, it writes `refused:<J>` and abandons the attempt.
7. **J** reads the helper through HA and checks the acceptance names J and carries *its
   own* transcript hash. It then decrypts the secret, writes it to the protected config,
   turns on the sharing settings chosen earlier, and restarts its daemon. J clears the
   helper, whatever the outcome, so the next machine finds it empty.

### Why each piece is there

* **The commitment** stops a man in the middle from choosing its keys after seeing the
  honest ones in order to make the two codes collide. It gets one guess, a 1-in-10⁶
  chance, per attempt.
* **Typing the code into HA** is the sponsor's confirmation. A broker-only attacker
  sitting between J and S produces two different transcripts, so two different codes.
  You type J's code, it does not match the code S expects, and S refuses. The attacker
  cannot alter what you typed, because it never crosses MQTT.
* **The HA-native acceptance** is the joiner's confirmation. Without it an attacker
  could complete a separate exchange with J and hand it a secret the attacker knows, and
  J would then serve sessions to whoever holds that fake secret. J accepts only an
  acceptance, written through HA by S, that is bound to J's own transcript.
* **AES-GCM with the transcript as associated data** means the ciphertext is useless to
  anyone without the ephemeral private key, recorded or not. A broker log, an HA
  service-call record or a backup holds only public keys, nonces and ciphertext.

### Limits on attempts

* One pairing at a time per sponsor. An attempt expires after 5 minutes.
* Three refused codes lock pairing on that sponsor for 15 minutes, which keeps online
  guessing far from useful at 1-in-10⁶ per try.
* Every step is logged on both machines with the attempt id, but never the code, the
  key or the secret.

## The fallback: pasting the secret

For when pairing cannot run: HA unreachable, or no other machine online.

* `agent-ha-bridge secret show`, run interactively on a member, prints the secret once,
  with a warning. It refuses when its output is redirected.
* `configure` on the joiner offers "paste the fleet secret instead". When a member is
  online, you pick which one, and the pasted value is checked against it with a signed
  challenge before it is saved: J writes a nonce into the helper, the member answers with
  an HMAC over it, and J verifies. So a typo fails immediately, not later as "transfers
  refused".
* When no member can answer - Home Assistant unreachable, or every member offline, the
  cases this fallback exists for - the secret can still be saved, but only unchecked and
  only after you type `SAVE UNCHECKED`, together with the fleet id it belongs to
  (`secret show` prints both).
* Sharing is turned on as in the pairing path.

## Configuration and storage

| Setting | Where | Notes |
|---|---|---|
| `newSession.transferSecret` | protected config (owner-only ACL on Windows, `0600` on macOS) | as #77 already does; never published |
| `newSession.fleetId` | config, and the machine's retained status | public. It tells a joiner which machines can sponsor it, and lets two separate fleets on one HA instance tell each other apart |
| `newSession.shareResumable`, `newSession.transferResumable` | config | set by `configure` from the person's answer, not by hand |

The carry file (`transfer-secret.txt`) is retired: `configure` reads one if present,
offers to import it, and deletes it once the secret is stored.

## Rotation and removal

v1 keeps this simple and says so:

* `agent-ha-bridge secret rotate` makes a new secret on one machine, keeping the fleet
  id, after you type `ROTATE`, and restarts its daemon. Every other machine then runs
  `agent-ha-bridge pair` and answers yes to *re-pair*, choosing that machine; until it
  does, transfers to and from it refuse, as they do with mismatched secrets. Pushing a
  new secret over a channel keyed by the old one is a possible later improvement, not
  part of v1.
* Removing a machine from the fleet means rotating, because a shared secret cannot be
  un-shared. That is a property of the #77 design, not of pairing.

## Open items to verify before code

* **AES-GCM under PowerShell on macOS.** *As built:* `tests/test-pairing.ps1` asserts
  `AesGcm.IsSupported`, and the macOS CI job runs it, so the platform answers this
  rather than an assumption. It holds on Windows. If it ever fails on macOS, the
  fallback is AES-256-CBC with HMAC-SHA256, encrypt-then-MAC, with **independent
  subkeys**: one HKDF output labelled `fleet secret enc` for AES and one labelled
  `fleet secret mac` for HMAC, never the same bytes for both. The MAC covers
  transcript ‖ IV ‖ ciphertext and is checked, in fixed time, before anything is
  decrypted. Not implemented, because nothing needs it yet.
* **What the recorder keeps from `mqtt.publish` calls.** By the analysis above nothing
  in the pairing messages needs protecting, but it should be confirmed by inspection,
  as the transfer design requires.
* **Creating the `input_text` helper** needs the provisioning (administrator) token,
  which the installer already holds. Upgrades must create it once, and leave a helper
  the person renamed or removed alone.

## Shipping

Pairing only matters once transfers ship, and today those (#61, #77) exist only on
`main`, alongside A28's gated publication fencing. So this lands with whichever
release carries #61/#77, either:

* a 1.33 with an A28 cutover plan, or
* #61/#77 brought onto the 1.32 line without A28.

That choice is made separately.
