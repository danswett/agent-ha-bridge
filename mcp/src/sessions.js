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
 *     holds two clients and every write below goes through the agent one.
 *
 *   - Expecting an answer in a persistent notification. Home Assistant does not expose
 *     those through GET /api/states, so polling finds nothing however long you wait,
 *     which looks exactly like the session having died. What a session said is in its
 *     activity sensor's `response` attribute, which is what readSession returns.
 *
 * Entity and topic shapes here mirror hooks/decision-mqtt.ps1; that file is the source
 * of truth and the tests pin the ones that matter.
 */

import { createHash } from 'node:crypto';

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
  };
}

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
 * another one with what those agents found.
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
export async function replyToSession(ha, sessionId, text) {
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
  await ha.publishMqtt(
    replyPayloadTopic(sessionId),
    { at: new Date().toISOString(), text: body, driver: 'agent' },
    false,
  );
  return { sessionId, sent: body.length, attributed: true, since };
}

/**
 * Starts a session on a machine, optionally with an opening prompt.
 *
 * The prompt goes to the retained payload topic rather than the 255-character text
 * box, and for the same reason it is cleared again when no prompt was given: the
 * payload wins over the text box whenever it holds anything, so one left behind by an
 * earlier launch would silently open the next session instead.
 */
export async function launchSession(ha, slug, { prompt } = {}) {
  const ids = machineEntities(slug);
  const online = await ha.getState(ids.online);
  if (!online) throw new Error(`No machine ${slug} in Home Assistant.`);
  if (online.state !== 'on') throw new Error(`${slug} is offline.`);

  const text = String(prompt ?? '').trim();
  await ha.publishMqtt(
    launchPromptTopic(slug),
    text ? { at: new Date().toISOString(), text } : '',
  );
  await ha.callService('button', 'press', { entity_id: ids.newSession });
  return { machine: slug, prompt: text.length };
}
