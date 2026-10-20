/**
 * Driving the bridge's own sessions: find them, read what they said, answer them,
 * start new ones.
 *
 * These exist so an agent never has to hand-roll the Home Assistant calls, because two
 * things about doing that by hand fail silently and neither leaves a trace:
 *
 *   - Writing with the user's token instead of the agent's. Both authenticate and both
 *     are authorised, so nothing errors; Home Assistant simply records the action
 *     against the user, and the session card is styled as theirs. The server therefore
 *     holds two clients and every *attributed* write below goes through the agent one.
 *
 *     The exception is `mqtt.publish`, which Home Assistant restricts to
 *     administrators. The agent account is deliberately not one, so publishing on the
 *     agent client fails with 401 and the two paths that carry unbounded text - a long
 *     reply and a launch prompt - could not be used by an agent at all. Those take a
 *     `publisher` client, the user's.
 *
 *     Attribution is unaffected, but the two are marked differently and only one of
 *     them presses anything. A launch publishes the prompt and then presses Launch,
 *     and Home Assistant records the account on that press. A long reply makes no
 *     service call at all - sending one as well would deliver it twice - so it marks
 *     itself with `driver` instead. Either way an MQTT-published state carries no
 *     account, so publishing as the user cannot turn a session blue.
 *
 *   - Expecting an answer in a persistent notification. Home Assistant does not expose
 *     those through GET /api/states, so polling finds nothing however long you wait,
 *     which looks exactly like the session having died. What a session said is in its
 *     activity sensor's `response` attribute, which is what readSession returns.
 *
 * Entity and topic shapes here mirror hooks/decision-mqtt.ps1; that file is the source
 * of truth and the tests pin the ones that matter.
 */

import { createHash, randomUUID } from 'node:crypto';

const SESSION_ACTIVITY = /^sensor\.agent_bridge_([0-9a-f]{16})_activity$/;
const MACHINE_ONLINE = /^binary_sensor\.agent_bridge_(.+)_online$/;

/** Home Assistant caps a state at 255 characters; longer text rides in an attribute. */
const STATE_MAX_CHARS = 255;

/**
 * A marker for "the turn the card is showing now".
 *
 * Most activity carries an `updated` stamp, but Codex's does not: it publishes its own
 * card rather than going through the shared path, and Set-CopilotMqttActivity sends the
 * detail exactly as it is given. Keying only on `updated` therefore produced an empty
 * marker for every Codex session, which compares as "changed" immediately and brings
 * back the stale-answer bug this exists to prevent.
 *
 * So the response itself is the fallback, hashed rather than carried: it can run to
 * thousands of characters and this value is passed back and forth through the tool
 * call. Two consecutive turns answering with byte-identical text would look unchanged,
 * which is worth it against always being wrong on one of the three agents.
 */
function turnMarker(activity) {
  const updated = String(activity?.attributes?.updated ?? '');
  if (updated) return updated;
  const response = String(activity?.attributes?.response ?? '');
  if (!response) return '';
  return `r:${createHash('sha1').update(response).digest('hex').slice(0, 16)}`;
}

export function sessionNode(sessionId) {
  return `agent_bridge_${sessionId}`;
}

export function sessionEntities(sessionId) {
  const node = sessionNode(sessionId);
  return {
    activity: `sensor.${node}_activity`,
    status: `sensor.${node}_status`,
    reply: `text.${node}_reply`,
    replyPayload: `sensor.${node}_reply_payload`,
    submit: `button.${node}_submit`,
    stop: `button.${node}_stop`,
  };
}

export function machineEntities(slug) {
  return {
    online: `binary_sensor.agent_bridge_${slug}_online`,
    sessions: `sensor.agent_bridge_${slug}_sessions`,
    newSession: `button.agent_bridge_${slug}_new_session`,
    newResult: `sensor.agent_bridge_${slug}_new_session_result`,
    newPrompt: `text.agent_bridge_${slug}_new_prompt`,
    newPromptPayload: `sensor.agent_bridge_${slug}_new_prompt_payload`,
  };
}

/**
 * The launch card's selectors, by the setting each one offers. Read for the options a
 * machine has, never written: a launch an agent asks for carries its own settings, so
 * a person's choices on the card are neither used nor changed (#227).
 */
export const LAUNCH_SETTINGS = ['agent', 'workspace', 'profile', 'resume', 'model', 'effort', 'context', 'permissions'];

export function launchSelectEntity(slug, setting) {
  return `select.agent_bridge_${slug}_new_${setting}`;
}

/** What a requested launch can come to once the machine is done with it. */
const FINAL_OUTCOMES = new Set(['started', 'refused', 'failed', 'busy', 'unconfirmed']);
const TUNING_SETTINGS = new Set(['model', 'effort', 'context']);
const REQUEST_ID = /^[A-Za-z0-9-]{8,64}$/;
// Exactly the daemon's two labels, case included: this one decides whether a session
// runs without asking, and anything unclear is refused rather than read as asking.
const PERMISSIONS = ['Ask permission', 'Allow all'];
const NEW_SESSION_OPTION = 'New session';
// How long a published request has to show in the slot before Launch is pressed for it.
// Home Assistant normally shows one in well under a second.
const LANDING_MS = 5000;

/** The retained topic the reply card publishes a long reply to. */
export function replyPayloadTopic(sessionId) {
  return `copilot/cli/${sessionNode(sessionId)}/replypayload/set`;
}

/** The retained topic a machine's launch card publishes its opening prompt to. */
export function launchPromptTopic(slug) {
  return `copilot/cli/machine/${slug}/newsession/promptpayload`;
}

function attr(state, name) {
  return state?.attributes?.[name];
}

/**
 * Publishes on the client allowed to, and explains it when that is refused.
 *
 * `mqtt.publish` is administrator-only. A plain 401 here reads as a bad token, which
 * sends anyone diagnosing it to the one place the fault is not: an agent token is
 * valid and is authorised for every other call in the sequence - reads,
 * `text.set_value` and `button.press` all succeed with it. Measured on DSWETT-DEV-VM1:
 * agent token 401, user token OK.
 *
 * Which credential to name depends on which one was actually used. Called through the
 * MCP server a publisher is always supplied and it is the user's, so a refusal there
 * means *that* token was rejected - expired, revoked, or not an administrator's - and
 * blaming the agent token would send an operator to a credential that was never used.
 * Only the fallback, where no publisher was given and the caller's own client had to
 * do it, is the case the split exists to fix.
 */
async function publishVia(publisher, topic, payload, retain, { fellBack = false } = {}) {
  try {
    return await publisher.publishMqtt(topic, payload, retain);
  } catch (error) {
    if (error?.status === 401 || error?.status === 403) {
      throw new Error(
        fellBack
          ? 'Home Assistant refused mqtt.publish, which it restricts to administrators, ' +
            'and this call was given no publisher client - it fell back to the one it was ' +
            "called with. Pass the user's client as `publisher`; an agent token may not " +
            'publish, though it is what presses afterwards.'
          : 'Home Assistant refused mqtt.publish, which it restricts to administrators. ' +
            'The publisher credential (homeAssistant.token) was the one refused: check it ' +
            "is an administrator's token and has not expired or been revoked.",
      );
    }
    throw error;
  }
}

/**
 * Every bridge session and machine Home Assistant currently knows about.
 *
 * One /api/states read rather than a call per entity: over a tunnel each round trip is
 * ~100 ms, and a fleet has dozens of these.
 */
export async function listSessions(ha) {
  const states = await ha.getStates();
  const byId = new Map(states.map((s) => [s.entity_id, s]));

  const sessions = [];
  const machines = [];

  for (const state of states) {
    const session = SESSION_ACTIVITY.exec(state.entity_id);
    if (session) {
      const id = session[1];
      const ids = sessionEntities(id);
      sessions.push({
        sessionId: id,
        machine: attr(state, 'machine') ?? '',
        name: attr(state, 'session') ?? '',
        driver: attr(state, 'driver') ?? '',
        status: byId.get(ids.status)?.state ?? 'unknown',
        activity: state.state ?? '',
        updated: attr(state, 'updated') ?? '',
      });
      continue;
    }
    const machine = MACHINE_ONLINE.exec(state.entity_id);
    if (machine) {
      const slug = machine[1];
      machines.push({
        slug,
        online: state.state === 'on',
        sessions: Number(byId.get(machineEntities(slug).sessions)?.state ?? 0) || 0,
      });
    }
  }

  sessions.sort((a, b) => a.machine.localeCompare(b.machine) || a.sessionId.localeCompare(b.sessionId));
  machines.sort((a, b) => a.slug.localeCompare(b.slug));
  return { sessions, machines };
}

/**
 * What a session last said, and whether it is still working.
 *
 * `since` is what makes `done` trustworthy. A session's `response` is deliberately
 * kept across turns - Update-DaemonSessionActivity retains it and the card republishes
 * it - and its status reads `idle` briefly before work starts as well as after a turn
 * ends. So an immediate poll after sending a message would otherwise return the
 * *previous* answer marked done, and the caller would stop waiting before the new turn
 * had produced anything. Pass the `since` that reply_to_agent_session returned and the
 * answer only counts once the activity has actually moved on.
 *
 * A session waiting on background agents it started reports `agents` rather than
 * `idle`, so it is correctly not done: its own turn has ended, but it will take
 * another one with what those agents found. A session waiting on a background
 * command it started and has not collected reports `shell`, for the same reason.
 */
export async function readSession(ha, sessionId, { since = '' } = {}) {
  const ids = sessionEntities(sessionId);
  const [activity, status] = await Promise.all([ha.getState(ids.activity), ha.getState(ids.status)]);
  if (!activity) throw new Error(`No session ${sessionId} in Home Assistant.`);

  const response = String(attr(activity, 'response') ?? '');
  const state = String(status?.state ?? 'unknown');
  const updated = String(attr(activity, 'updated') ?? '');
  const moved = !since || turnMarker(activity) !== since;
  return {
    sessionId,
    machine: attr(activity, 'machine') ?? '',
    name: attr(activity, 'session') ?? '',
    driver: attr(activity, 'driver') ?? '',
    status: state,
    activity: activity.state ?? '',
    response,
    updated,
    marker: turnMarker(activity),
    done: state === 'idle' && response.trim().length > 0 && moved,
  };
}

/**
 * Sends text to a session, by whichever of the two paths fits - never both.
 *
 * Sending both is what the obvious implementation does, and it delivers the message
 * twice: Invoke-PendingReplies takes the payload, `continue`s without consuming the
 * Submit press, and the next pass then finds a fresh press beside a populated text box
 * and injects the same text again.
 *
 * Which path is not a free choice, because they differ in what they can carry:
 *
 *   - The text box commits through a service call, so Home Assistant records the
 *     account on the Submit press and Send-DaemonReplyBoxText reads the driver off it.
 *     That is what marks the turn as the agent's. It is capped at 255 characters.
 *   - The payload topic has no cap, but arrives over MQTT, and an MQTT-published state
 *     carries no context at all - measured: context.user_id comes back empty. Nothing
 *     downstream can read who sent it, so the payload says so itself: `driver`, which
 *     the reply card omits because a reply typed on the dashboard is the person's.
 *
 * Both paths are therefore marked. The long one is marked by assertion rather than by
 * Home Assistant's own record, which is sound here because the glow is presentation
 * and publishing at all already needs a token - but it is the weaker of the two, so
 * the press stays the way a reply that fits is sent.
 */
export async function replyToSession(ha, sessionId, text, { publisher } = {}) {
  const body = String(text ?? '');
  if (!body.trim()) throw new Error('A reply needs some text.');

  const ids = sessionEntities(sessionId);
  const activity = await ha.getState(ids.activity);
  if (!activity) throw new Error(`No session ${sessionId} in Home Assistant.`);
  // Captured before sending, so read_agent_session can tell the next answer from this
  // turn's leftover one.
  const since = turnMarker(activity);

  // Code points, not UTF-16 units. Home Assistant counts characters, so measuring with
  // .length sends anything with emoji or other non-BMP characters down the unattributed
  // path early - 128 emoji would be enough - and quietly loses the agent's mark on it.
  if ([...body].length <= STATE_MAX_CHARS) {
    await ha.callService('text', 'set_value', { entity_id: ids.reply, value: body });
    await ha.callService('button', 'press', { entity_id: ids.submit });
    return { sessionId, sent: body.length, attributed: true, since };
  }

  // Not retained, matching the reply card: the daemon's guard against re-delivering a
  // payload is in memory, so a retained one restored by the broker after a restart
  // would be read as a new submission and injected again.
  await publishVia(
    publisher ?? ha,
    replyPayloadTopic(sessionId),
    { at: new Date().toISOString(), text: body, driver: 'agent' },
    false,
    { fellBack: !publisher },
  );
  return { sessionId, sent: body.length, attributed: true, since };
}

/**
 * Starts a session on a machine, and reports what that launch actually came to.
 *
 * A machine that understands launch requests (capabilities.launchRequest) is sent one:
 * an id, the prompt, and whichever settings were given, on the retained payload topic
 * the daemon reads at the press. What is left out is that machine's configured default
 * - never what its card shows, so an agent cannot inherit an 'Allow all' a person left
 * selected - and the daemon publishes what the request came to, keyed by its id, on
 * the result sensor. This waits up to `waitSeconds` for a final answer and otherwise
 * returns `pending` with the id, for readLaunchResult.
 *
 * An older machine ignores both, so settings are refused for one rather than quietly
 * dropped, and a launch without any is sent the old way and reported as `sent`.
 *
 * The payload is the single slot two agents launching at once would share, so the
 * press waits until the slot shows this request: pressing earlier could launch the
 * request it replaced, or nothing of this one. Nothing is pressed for a request that
 * never shows: `lost` if another replaced it, `undelivered` if it simply has not
 * arrived (notLanded).
 */
export async function launchSession(ha, slug, options = {}) {
  const {
    prompt,
    publisher,
    settings = {},
    waitSeconds = 30,
    now = () => Date.now(),
    sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    newRequestId = () => randomUUID(),
  } = options;
  const ids = machineEntities(slug);
  const states = await ha.getStates();
  const byId = new Map(states.map((s) => [s.entity_id, s]));
  const online = byId.get(ids.online);
  if (!online) throw new Error(`No machine ${slug} in Home Assistant.`);
  if (online.state !== 'on') throw new Error(`${slug} is offline.`);

  const wanted = launchSettings(settings);
  const status = byId.get(ids.sessions);
  const capabilities = attr(status, 'capabilities') ?? {};
  if (capabilities.newSession === false) {
    throw new Error(`Launching is turned off on ${slug} (newSession.enabled), so nothing was launched.`);
  }
  const held = String(attr(status, 'discovery_held') ?? '').trim();
  if (held) throw new Error(`${slug} is holding launches until it can account for ${held}. Nothing was launched.`);
  const supported = Number(capabilities.launchRequest ?? 0) >= 1;
  if (!supported && Object.keys(wanted).length) {
    throw new Error(
      `${slug} runs a bridge too old to take launch settings, so nothing was launched. Update it ` +
        `(button.agent_bridge_${slug}_install_update), or launch without settings to use what its card shows.`,
    );
  }

  const text = String(prompt ?? '').trim();
  if (!supported) {
    // The old contract, unchanged: an empty prompt clears the slot, since the payload
    // beats the text box and one left behind would open the next session instead.
    await publishVia(
      publisher ?? ha,
      launchPromptTopic(slug),
      text ? { at: new Date(now()).toISOString(), text } : '',
      true,
      { fellBack: !publisher },
    );
    await ha.callService('button', 'press', { entity_id: ids.newSession });
    return {
      machine: slug,
      prompt: text.length,
      status: 'sent',
      note:
        `${slug} runs a bridge from before launch requests: it launched with what its card shows, ` +
        'and reports no outcome. Look for the new session with list_agent_sessions.',
    };
  }

  const refusal = precheckLaunch(wanted, byId, slug);
  if (refusal) return { machine: slug, prompt: text.length, status: 'refused', note: refusal };

  const request = newRequestId();
  const payload = { at: new Date(now()).toISOString(), text, request };
  if (Object.keys(wanted).length) payload.settings = wanted;
  await publishVia(publisher ?? ha, launchPromptTopic(slug), payload, true, { fellBack: !publisher });

  // Pressed only once the slot shows this request, and not at all if another press
  // has already taken it - which is a launch, reported like any other.
  let taken = null;
  const landBy = now() + LANDING_MS;
  for (;;) {
    const slot = await ha.getState(ids.newPromptPayload);
    if (attr(slot, 'request') === request) break;
    taken = findOutcome(await ha.getState(ids.newResult), request);
    if (taken) break;
    if (now() >= landBy) return notLanded(slug, request, text.length, attr(slot, 'request'));
    await sleep(200);
  }
  if (!taken) await ha.callService('button', 'press', { entity_id: ids.newSession });
  const pressedAt = now();

  // Read about once a second. A request that is neither answered nor still waiting
  // in the slot five seconds after the press was replaced before the machine took it.
  const until = pressedAt + Math.max(0, Math.min(120, Number(waitSeconds) || 0)) * 1000;
  let latest = taken;
  for (;;) {
    const [result, slot] = await Promise.all([ha.getState(ids.newResult), ha.getState(ids.newPromptPayload)]);
    const record = findOutcome(result, request);
    if (record) {
      latest = record;
      if (FINAL_OUTCOMES.has(record.outcome)) return launchResult(slug, request, record, text.length);
    } else if (attr(slot, 'request') !== request && now() - pressedAt >= 5000) {
      return {
        machine: slug,
        request,
        prompt: text.length,
        status: 'lost',
        note:
          'Another launch request replaced this one before the machine took it, so nothing was ' +
          'launched for it. Try again.',
      };
    }
    if (now() >= until) break;
    await sleep(1000);
  }
  return launchResult(slug, request, latest, text.length);
}

/**
 * What a launch requested earlier came to - for one launch_agent_session returned as
 * `pending`. Reads the machine's outcomes once; never waits.
 */
export async function readLaunchResult(ha, slug, request) {
  const id = String(request ?? '').trim();
  if (!REQUEST_ID.test(id)) throw new Error(`'${id}' is not a launch request id.`);
  const ids = machineEntities(slug);
  const [result, slot] = await Promise.all([ha.getState(ids.newResult), ha.getState(ids.newPromptPayload)]);
  if (!result && !slot) throw new Error(`No machine ${slug} in Home Assistant.`);
  const record = findOutcome(result, id);
  if (record) return launchResult(slug, id, record);
  if (attr(slot, 'request') === id) {
    return { machine: slug, request: id, status: 'pending', note: 'Waiting for the machine to take the request.' };
  }
  return {
    machine: slug,
    request: id,
    status: 'unknown',
    note:
      `Not among ${slug}'s latest launch outcomes, nor waiting to be taken: it was replaced before ` +
      'the machine took it, or is older than the five outcomes a machine keeps.',
  };
}

/**
 * What a machine's launch card offers, read from its selectors: the values a
 * launch_agent_session setting may take there. Read-only.
 *
 * The model, effort and context lists belong to whichever agent the card currently
 * shows, which is why they are labelled with it: another agent offers its own, and
 * a value it does not have is refused at launch rather than guessed at.
 */
export async function getLaunchOptions(ha, slug) {
  const ids = machineEntities(slug);
  const states = await ha.getStates();
  const byId = new Map(states.map((s) => [s.entity_id, s]));
  const online = byId.get(ids.online);
  if (!online) throw new Error(`No machine ${slug} in Home Assistant.`);
  const status = byId.get(ids.sessions);
  const capabilities = attr(status, 'capabilities') ?? {};
  const options = (setting) => selectOptions(byId.get(launchSelectEntity(slug, setting)));
  return {
    machine: slug,
    online: online.state === 'on',
    launching: capabilities.newSession !== false,
    launchRequest: Number(capabilities.launchRequest ?? 0) >= 1,
    held: String(attr(status, 'discovery_held') ?? ''),
    agents: options('agent'),
    workspaces: options('workspace'),
    profiles: options('profile'),
    permissions: options('permissions'),
    resume: options('resume').filter((label) => label !== NEW_SESSION_OPTION),
    tuning: {
      agent: String(byId.get(launchSelectEntity(slug, 'agent'))?.state ?? ''),
      model: options('model'),
      effort: options('effort'),
      context: options('context'),
    },
  };
}

function selectOptions(state) {
  const options = attr(state, 'options');
  return Array.isArray(options) ? options.map(String) : [];
}

/** The settings a launch was given, as text, without the ones left empty. */
function launchSettings(settings) {
  const wanted = {};
  for (const [key, value] of Object.entries(settings ?? {})) {
    if (!LAUNCH_SETTINGS.includes(key)) {
      throw new Error(`Unknown launch setting '${key}' - a launch takes ${LAUNCH_SETTINGS.join(', ')}.`);
    }
    const text = value === undefined || value === null ? '' : String(value).trim();
    if (text) wanted[key] = text;
  }
  return wanted;
}

/**
 * A refusal for a setting the machine's card shows it does not offer, so a doomed
 * request does not take the payload slot. Matched as loosely as the daemon matches,
 * never more strictly, and only where the card's list is the one the daemon will use:
 * a session id resumes though only labels are listed, and the tuning lists belong to
 * the card's agent, so they are checked only for a launch that names that same agent.
 */
function precheckLaunch(wanted, byId, slug) {
  const same = (a, b) => a.localeCompare(b, undefined, { sensitivity: 'accent' }) === 0;
  const offered = (setting) => selectOptions(byId.get(launchSelectEntity(slug, setting)));
  const refuse = (setting, value, list) =>
    `${slug} does not offer ${setting} '${value}'. It has: ${list.join(', ') || 'nothing'}. Nothing was launched.`;
  const cardAgent = String(byId.get(launchSelectEntity(slug, 'agent'))?.state ?? '');

  for (const [setting, value] of Object.entries(wanted)) {
    if (setting === 'permissions') {
      if (!PERMISSIONS.includes(value)) return refuse(setting, value, PERMISSIONS);
      continue;
    }
    if (TUNING_SETTINGS.has(setting) && !(wanted.agent && cardAgent && same(wanted.agent, cardAgent))) continue;
    const list = offered(setting).filter((option) => !(setting === 'resume' && option === NEW_SESSION_OPTION));
    if (!list.length) continue;
    if (setting === 'resume' && !list.some((option) => same(option, value))) {
      if (/^[0-9a-f]{8}-[0-9a-f-]{4,}$/i.test(value)) continue;
    }
    if (!list.some((option) => same(option, value))) return refuse(setting, value, list);
  }
  return '';
}

function findOutcome(result, request) {
  const recent = attr(result, 'recent');
  if (!Array.isArray(recent)) return null;
  return recent.find((entry) => entry?.request === request) ?? null;
}

/**
 * A request that never showed in the slot, so Launch was not pressed for it. Replaced
 * by another, it can never launch. Merely not shown yet - Home Assistant running slow -
 * it still could: it is retained, so a press of Launch there while it is fresh would
 * start it. Trying again replaces it, so only a press in between can start both, which
 * read_launch_result shows.
 */
function notLanded(slug, request, promptLength, inSlot) {
  const shaped = { machine: slug, request, prompt: promptLength };
  if (inSlot && inSlot !== request) {
    return {
      ...shaped,
      status: 'lost',
      note:
        `Another launch request replaced this one on ${slug} before it showed there, so Launch was not ` +
        'pressed and nothing was launched for it. Try again.',
    };
  }
  return {
    ...shaped,
    status: 'undelivered',
    note:
      `The request did not show on ${slug} within ${LANDING_MS / 1000} seconds, so Launch was not pressed. If ` +
      'it arrives late, a press of Launch there in the next minute would start it: check read_launch_result ' +
      'with this request before trying again. Trying again replaces it.',
  };
}

function launchResult(slug, request, record, promptLength) {
  const shaped = { machine: slug, request };
  if (promptLength !== undefined) shaped.prompt = promptLength;
  if (!record) {
    return { ...shaped, status: 'pending', stage: '', note: 'Launch pressed; the machine has not answered yet.' };
  }
  const outcome = String(record.outcome ?? '');
  const final = FINAL_OUTCOMES.has(outcome);
  return {
    ...shaped,
    status: final ? outcome : 'pending',
    stage: final ? '' : outcome,
    session: String(record.session ?? ''),
    note: String(record.note ?? ''),
    launched: record.launched ?? null,
  };
}
