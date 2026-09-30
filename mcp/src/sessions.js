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

const SESSION_ACTIVITY = /^sensor\.agent_bridge_([0-9a-f]{16})_activity$/;
const MACHINE_ONLINE = /^binary_sensor\.agent_bridge_(.+)_online$/;

/** Home Assistant caps a state at 255 characters; longer text rides in an attribute. */
const STATE_MAX_CHARS = 255;

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
 * A session reads `idle` briefly *before* it starts working as well as when a turn
 * ends, so `done` requires a response to actually be there - waiting on the status
 * alone returns an empty answer from a session that has not begun.
 */
export async function readSession(ha, sessionId) {
  const ids = sessionEntities(sessionId);
  const [activity, status] = await Promise.all([ha.getState(ids.activity), ha.getState(ids.status)]);
  if (!activity) throw new Error(`No session ${sessionId} in Home Assistant.`);

  const response = String(attr(activity, 'response') ?? '');
  const state = String(status?.state ?? 'unknown');
  return {
    sessionId,
    machine: attr(activity, 'machine') ?? '',
    name: attr(activity, 'session') ?? '',
    driver: attr(activity, 'driver') ?? '',
    status: state,
    activity: activity.state ?? '',
    response,
    done: state === 'idle' && response.trim().length > 0,
  };
}

/**
 * Sends text to a session as the agent.
 *
 * The payload topic carries the whole message; the text entity beside it is capped at
 * 255 characters by Home Assistant, so a long handover sent that way arrives cut off
 * mid-sentence. Both are written - the payload for the daemon, the text box so a
 * dashboard running an older card still shows what was sent - and then Submit is
 * pressed, which is what the daemon watches.
 */
export async function replyToSession(ha, sessionId, text) {
  const body = String(text ?? '');
  if (!body.trim()) throw new Error('A reply needs some text.');

  const ids = sessionEntities(sessionId);
  if (!(await ha.getState(ids.activity))) {
    throw new Error(`No session ${sessionId} in Home Assistant.`);
  }

  await ha.publishMqtt(replyPayloadTopic(sessionId), {
    at: new Date().toISOString(),
    text: body,
  });
  await ha
    .callService('text', 'set_value', {
      entity_id: ids.reply,
      value: body.length > STATE_MAX_CHARS ? body.slice(0, STATE_MAX_CHARS) : body,
    })
    .catch(() => {
      // The payload is what the daemon reads; an older session may have no text box.
    });
  await ha.callService('button', 'press', { entity_id: ids.submit });
  return { sessionId, sent: body.length };
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
