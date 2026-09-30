/**
 * Unit tests for driving the bridge's own sessions.
 *
 * Two of the behaviours here are the whole reason these tools exist, and both fail
 * silently when done by hand:
 *
 *   - every write goes out on the agent's client, not the user's, because Home
 *     Assistant records the account against the action and nothing errors when it is
 *     the wrong one;
 *   - a session's answer comes from its activity sensor, because persistent
 *     notifications are invisible to the states API.
 *
 * Nothing here reaches Home Assistant: the client is a recording stub.
 */
import {
  launchPromptTopic,
  launchSession,
  listSessions,
  machineEntities,
  readSession,
  replyPayloadTopic,
  replyToSession,
  sessionEntities,
} from '../src/sessions.js';

let pass = 0;
let fail = 0;
function check(name, condition, detail = '') {
  if (condition) {
    console.log(`  PASS  ${name}`);
    pass++;
  } else {
    console.log(`  FAIL  ${name}${detail ? ` - ${detail}` : ''}`);
    fail++;
  }
}

function stubHa(states = []) {
  const byId = new Map(states.map((s) => [s.entity_id, s]));
  return {
    calls: [],
    published: [],
    async getStates() {
      return states;
    },
    async getState(id) {
      return byId.get(id) ?? null;
    },
    async callService(domain, service, data) {
      this.calls.push({ domain, service, data });
      return null;
    },
    async publishMqtt(topic, payload, retain = true) {
      this.published.push({ topic, payload, retain });
      return null;
    },
  };
}

const SESSION = '05b56763411c4c37';
const states = [
  {
    entity_id: `sensor.agent_bridge_${SESSION}_activity`,
    state: 'Running: powershell',
    attributes: {
      machine: 'DSWETT-DEV-VM1',
      session: 'Copilot: something',
      driver: 'agent',
      response: 'the answer',
      updated: '09/29/2026 17:39:32',
    },
  },
  { entity_id: `sensor.agent_bridge_${SESSION}_status`, state: 'idle', attributes: {} },
  { entity_id: 'binary_sensor.agent_bridge_dswett_dev_vm1_online', state: 'on', attributes: {} },
  { entity_id: 'sensor.agent_bridge_dswett_dev_vm1_sessions', state: '2', attributes: {} },
  { entity_id: 'binary_sensor.agent_bridge_dasdesk_online', state: 'unavailable', attributes: {} },
  // Deliberate noise: a machine-scoped entity that must not be read as a session.
  { entity_id: 'sensor.agent_bridge_dswett_dev_vm1_new_session_result', state: '', attributes: {} },
];

console.log('--- finding what there is to talk to ---');
{
  const { sessions, machines } = await listSessions(stubHa(states));
  check('a session is found by its activity sensor', sessions.length === 1, `got ${sessions.length}`);
  check('and carries the machine it runs on', sessions[0]?.machine === 'DSWETT-DEV-VM1');
  check('and who is driving it', sessions[0]?.driver === 'agent');
  check('and its status, read from the sensor beside it', sessions[0]?.status === 'idle');
  check('machines are listed separately', machines.length === 2, `got ${machines.length}`);
  check('an offline machine is marked, not dropped', machines.find((m) => m.slug === 'dasdesk')?.online === false);
  check('and a machine reports its session count', machines.find((m) => m.slug === 'dswett_dev_vm1')?.sessions === 2);
  check(
    'a machine-scoped sensor is not mistaken for a session',
    !sessions.some((s) => s.sessionId.includes('dswett')),
  );
}

console.log('\n--- reading the answer back ---');
{
  const result = await readSession(stubHa(states), SESSION);
  check('the response attribute is what is returned', result.response === 'the answer');
  check('and a finished turn says so', result.done === true);

  const notStarted = structuredClone(states);
  notStarted[0].attributes.response = '';
  const early = await readSession(stubHa(notStarted), SESSION);
  check(
    'a session idle before it has begun is not reported as done',
    early.done === false,
    'status is idle both before a turn starts and after it ends',
  );

  // The one that matters after sending: a session keeps its previous response while
  // the next turn is starting, so without `since` an immediate poll reports the old
  // answer as finished and the caller stops waiting.
  const stale = await readSession(stubHa(states), SESSION, { since: '09/29/2026 17:39:32' });
  check(
    "the previous turn's answer is not reported as this turn's",
    stale.done === false,
    'same updated stamp as when the reply was sent',
  );
  const moved = await readSession(stubHa(states), SESSION, { since: '09/29/2026 17:00:00' });
  check('but an answer from a turn that has moved on is', moved.done === true);
  check('and the stamp to compare against is returned', moved.updated === '09/29/2026 17:39:32');

  let threw = '';
  await readSession(stubHa([]), SESSION).catch((e) => {
    threw = e.message;
  });
  check('an unknown session is an error, not an empty answer', threw.includes(SESSION));
}

console.log('\n--- replying, by one path only ---');
{
  // Short enough for the text box, which is the only path Home Assistant records an
  // account on - Send-DaemonReplyBoxText reads the driver off the Submit press.
  const ha = stubHa(states);
  const short = await replyToSession(ha, SESSION, 'hello there');
  const box = ha.calls.find((c) => c.domain === 'text');
  check('a short reply goes in the text box', box?.data?.value === 'hello there');
  const press = ha.calls.find((c) => c.domain === 'button' && c.service === 'press');
  check('and Submit is pressed, which is what carries the account', press?.data?.entity_id === sessionEntities(SESSION).submit);
  check('so it is marked as the agent', short.attributed === true);
  check('nothing is published as well, which would deliver it twice', ha.published.length === 0);
  check('and the stamp to poll against comes back', short.since === '09/29/2026 17:39:32');

  // Too long for the text box. The payload has no cap but arrives over MQTT, which
  // carries no context, so the turn cannot be marked - sent whole and unmarked beats
  // silently truncated.
  const long = 'x'.repeat(400);
  const ha2 = stubHa(states);
  const big = await replyToSession(ha2, SESSION, long);
  const sent = ha2.published.find((p) => p.topic === replyPayloadTopic(SESSION));
  check('a long reply goes whole to the payload topic', sent?.payload?.text.length === 400);
  check('and the topic is the one the card uses', replyPayloadTopic(SESSION) === `copilot/cli/agent_bridge_${SESSION}/replypayload/set`);
  check(
    'published unretained, as the reply card does',
    sent?.retain === false,
    "the daemon's guard against re-delivery is in memory, so a restored payload is injected again",
  );
  check('it says it could not be attributed', big.attributed === false);
  check(
    'and neither the box nor Submit is touched, so it arrives once',
    ha2.calls.length === 0,
    `calls=${ha2.calls.length}`,
  );

  let empty = '';
  await replyToSession(stubHa(states), SESSION, '   ').catch((e) => {
    empty = e.message;
  });
  check('an empty reply is refused rather than sent', empty.length > 0);
}

console.log('\n--- a session whose card carries no update stamp ---');
{
  // Codex publishes its own card and Set-CopilotMqttActivity sends the detail as
  // given, so there is no `updated` at all. Keying only on that produced an empty
  // marker, which compares as changed straight away and reports the previous answer
  // as this turn's - the exact bug the stamp exists to prevent.
  const codex = [
    {
      entity_id: `sensor.agent_bridge_${SESSION}_activity`,
      state: 'Working',
      attributes: { machine: 'DEV', session: 'Codex: x', driver: 'agent', response: 'the old answer' },
    },
    { entity_id: `sensor.agent_bridge_${SESSION}_status`, state: 'idle', attributes: {} },
  ];
  const ha = stubHa(codex);
  const sent = await replyToSession(ha, SESSION, 'go again');
  check('a reply still gets a marker to poll against', sent.since.length > 0, `since='${sent.since}'`);

  const stale = await readSession(stubHa(codex), SESSION, { since: sent.since });
  check(
    "the previous answer is not reported as this turn's",
    stale.done === false,
    'no updated attribute, so the response itself is the marker',
  );

  const answered = structuredClone(codex);
  answered[0].attributes.response = 'a brand new answer';
  const fresh = await readSession(stubHa(answered), SESSION, { since: sent.since });
  check('and a genuinely new answer is', fresh.done === true);
}

console.log('\n--- measuring a reply the way Home Assistant does ---');
{
  // .length counts UTF-16 units, so 128 emoji would read as 256 and be pushed down the
  // unattributed path despite fitting Home Assistant's 255 characters.
  const emoji = '\u{1F600}'.repeat(200);
  check('the test string really is non-BMP', emoji.length === 400 && [...emoji].length === 200);
  const ha = stubHa(states);
  const result = await replyToSession(ha, SESSION, emoji);
  check('200 emoji still go the attributed way', result.attributed === true);
  check('and through the text box, whole', ha.calls.find((c) => c.domain === 'text')?.data?.value === emoji);
  check('with nothing published', ha.published.length === 0);

  const tooMany = '\u{1F600}'.repeat(300);
  const ha2 = stubHa(states);
  const big = await replyToSession(ha2, SESSION, tooMany);
  check('but 300 really is too many', big.attributed === false && ha2.published.length === 1);
}

console.log('\n--- launching ---');
{
  const ha = stubHa(states);
  await launchSession(ha, 'dswett_dev_vm1', { prompt: 'do the thing' });
  const payload = ha.published.find((p) => p.topic === launchPromptTopic('dswett_dev_vm1'));
  check('the opening prompt goes to the launch payload topic', payload?.payload?.text === 'do the thing');
  check('and that topic is the machine-scoped one', launchPromptTopic('dswett_dev_vm1') === 'copilot/cli/machine/dswett_dev_vm1/newsession/promptpayload');
  const press = ha.calls.find((c) => c.domain === 'button');
  check('Launch is pressed', press?.data?.entity_id === machineEntities('dswett_dev_vm1').newSession);
  check(
    'the launch prompt IS retained, matching the launch card',
    payload?.retain === true,
    'unlike a reply: the daemon reads this one on the reconcile after the press',
  );

  const ha2 = stubHa(states);
  await launchSession(ha2, 'dswett_dev_vm1');
  const cleared = ha2.published.find((p) => p.topic === launchPromptTopic('dswett_dev_vm1'));
  check(
    'launching with no prompt clears the retained one',
    cleared?.payload === '',
    'the payload beats the text box, so one left behind would open the next session',
  );

  let offline = '';
  await launchSession(stubHa(states), 'dasdesk').catch((e) => {
    offline = e.message;
  });
  check('an offline machine is refused', offline.includes('offline'));

  let missing = '';
  await launchSession(stubHa(states), 'nope').catch((e) => {
    missing = e.message;
  });
  check('and an unknown one says so', missing.includes('nope'));
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
