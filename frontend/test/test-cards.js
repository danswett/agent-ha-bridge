/*
 * Tests for the dashboard cards' own logic, run under plain node with a small DOM
 * stand-in. No browser and no Home Assistant.
 *
 * agent-bridge-choices-card is what these cover. It replaced Home Assistant's select
 * control for a waiting question, because that control sizes its menu to the longest
 * option and will not wrap - so on a phone the answers ran off the edge of the screen
 * and could not be read. The rules worth pinning down are which options it offers,
 * when it shows at all, and that one tap sends exactly one answer.
 */
'use strict';

let failures = 0;
function check(name, condition, detail) {
  if (condition) { console.log(`  PASS  ${name}`); return; }
  failures++;
  console.log(`  FAIL  ${name}${detail ? ` - ${detail}` : ''}`);
}

// --- the card itself, in a DOM small enough to run it (card-harness.js) --------

const { FakeElement, loadCards } = require('./card-harness');
const { AgentBridgeChoicesCard, AgentBridgeSessionCard, CARD_VERSION, sandbox, source } = loadCards();

// --- the harness ------------------------------------------------------------------

const DECISION = 'select.agent_bridge_abc_decision';

function newCard(fields) {
  const card = new AgentBridgeChoicesCard();
  card.setConfig(fields ? { decision: DECISION, fields } : { decision: DECISION });
  return card;
}

function hassWith(state, options) {
  const calls = [];
  return {
    calls,
    hass: {
      states: { [DECISION]: { state, attributes: options === undefined ? {} : { options } } },
      callService: (domain, service, data) => calls.push({ domain, service, data }),
    },
  };
}

const rows = (card) => card.shadowRoot.querySelector('.choices').children;
const labels = (card) => rows(card).map((b) => b.textContent);
const buttons = (card) => rows(card).filter((r) => r.tagName === 'BUTTON');

// --- what it offers ---------------------------------------------------------------

console.log('--- the choices a waiting question offers ---');
let card = newCard();
card.hass = hassWith('Awaiting answer...',
  ['Awaiting answer...', 'Yes - reboot now', 'No - leave it (Recommended)', 'Cancel request']).hass;
check('every real choice gets a row of its own',
  labels(card).join('|') === 'Yes - reboot now|No - leave it (Recommended)|Cancel request', labels(card).join('|'));
check('the parked placeholder is never offered as an answer', !labels(card).includes('Awaiting answer...'));
check('the card is shown', card.hidden === false);
check('cancelling is the quieter row, and an answer is not',
  rows(card)[2].classList.contains('cancel') && !rows(card)[0].classList.contains('cancel'));

console.log('--- when it stays out of the way ---');
for (const [name, state, options] of [
  ['an unarmed session shows nothing', 'Idle', ['Idle']],
  ['a session that has gone shows nothing', 'unknown', []],
  ['nor does an unavailable one', 'unavailable', ['Awaiting answer...']],
  ['a question with no choices of its own shows nothing', 'Awaiting answer...', ['Awaiting answer...']],
]) {
  const c = newCard();
  c.hass = hassWith(state, options).hass;
  check(name, c.hidden === true);
}
card = newCard();
card.hass = { states: {}, callService: () => {} };
check('an entity that is not there at all shows nothing', card.hidden === true);

console.log('--- answering ---');
card = newCard();
let env = hassWith('Awaiting answer...', ['Awaiting answer...', 'Yes - reboot now', 'Cancel request']);
card.hass = env.hass;
rows(card)[0].click();
check('a tap selects that option on the entity', env.calls.length === 1 &&
  env.calls[0].domain === 'select' && env.calls[0].service === 'select_option' &&
  env.calls[0].data.entity_id === DECISION && env.calls[0].data.option === 'Yes - reboot now',
  JSON.stringify(env.calls));
rows(card)[1].click();
check('a second tap while the first is in flight sends nothing more', env.calls.length === 1, JSON.stringify(env.calls));
check('and the rows are marked as sending', card.shadowRoot.querySelector('.choices').classList.contains('sending'));

// The daemon clears the question, which is what releases the card for the next one.
card.hass = hassWith('Idle', ['Idle']).hass;
env = hassWith('Awaiting answer...', ['Awaiting answer...', 'Another question', 'Cancel request']);
card.hass = env.hass;
rows(card)[0].click();
check('the next question can be answered again',
  env.calls.length === 1 && env.calls[0].data.option === 'Another question', JSON.stringify(env.calls));

console.log('--- a whole form, not just one choice ---');
// A multi-field question publishes one select per field and leaves the main selector
// carrying only 'Cancel request'. Those fields used to render as Home Assistant's own
// dropdowns, which commit on blur - so answering meant tapping the option, tapping
// away, and only then pressing Send - and which size their menu to the longest option
// without wrapping, so sentence-length answers were cut off on a phone.

const F = (n) => `select.agent_bridge_abc_f${n}`;
const FIELDS = [F(1), F(2), F(3), F(4)];

/*
 * A form as the bridge actually publishes one: `armed` gives each named slot its
 * options and current state, unnamed slots stay parked on 'Idle', and the headings
 * ride on the decision entity's attributes because a field's own friendly_name is the
 * device name followed by the entity name.
 */
function formEnv(armed, decisionOptions) {
  const calls = [];
  const attributes = { options: decisionOptions || ['Awaiting answer...', 'Cancel request'] };
  const states = { [DECISION]: { state: 'Awaiting answer...', attributes } };
  for (let i = 1; i <= 4; i++) {
    const field = armed[i];
    if (field) {
      attributes[`field_${i}_label`] = field.label;
      states[F(i)] = {
        state: field.state || 'Choose...',
        attributes: {
          options: ['Choose...'].concat(field.options),
          friendly_name: `Copilot: a task ${field.label}`,
        },
      };
    }
    else { states[F(i)] = { state: 'Idle', attributes: { options: ['Idle'] } }; }
  }
  return { calls, hass: { states, callService: (d, s, data) => calls.push({ domain: d, service: s, data }) } };
}

const twoFields = {
  1: { label: 'Approach', options: ['Rewrite it', 'Patch it in place (Recommended)'] },
  2: { label: 'When', options: ['Now', 'After the release'] },
};

card = newCard(FIELDS);
env = formEnv(twoFields);
card.hass = env.hass;
check('each armed field gets a heading of its own',
  rows(card).filter((r) => r.classList.contains('label')).map((r) => r.textContent).join('|') === 'Approach|When',
  labels(card).join('|'));
check('the headings come from the decision attributes, not the device-prefixed name',
  labels(card).every((t) => !t.includes('Copilot: a task')), labels(card).join('|'));
check('every option of every field is a row, in field order',
  labels(card).join('|') === 'Approach|Rewrite it|Patch it in place (Recommended)|When|Now|After the release|Cancel request',
  labels(card).join('|'));
check('an unarmed field slot contributes nothing', !labels(card).includes('Idle'));
check('and a field placeholder is never offered as an answer', !labels(card).includes('Choose...'));
check('cancelling stays the quiet row at the bottom',
  buttons(card)[buttons(card).length - 1].classList.contains('cancel'));
check('the form is shown', card.hidden === false);

// The wire that matters: a row has to set the entity the daemon reads when Send is
// pressed, which is that field's own select and not the main one.
buttons(card)[1].click();
check('a tap on a field row selects that option on that field entity',
  env.calls.length === 1 && env.calls[0].domain === 'select' && env.calls[0].service === 'select_option' &&
  env.calls[0].data.entity_id === F(1) && env.calls[0].data.option === 'Patch it in place (Recommended)',
  JSON.stringify(env.calls));
check('answering one field does not lock the rest of the form',
  card.shadowRoot.querySelector('.choices').classList.contains('sending') === false);
buttons(card)[3].click();
check('so the next field can be answered straight away',
  env.calls.length === 2 && env.calls[1].data.entity_id === F(2) && env.calls[1].data.option === 'After the release',
  JSON.stringify(env.calls));

// A form is only sent when Send is pressed, so what has already been picked has to
// stay visible while the rest is filled in.
card = newCard(FIELDS);
card.hass = formEnv({
  1: { label: 'Approach', options: ['Rewrite it', 'Patch it in place'], state: 'Patch it in place' },
  2: { label: 'When', options: ['Now', 'After the release'] },
}).hass;
check('a field already answered shows which option was picked',
  buttons(card).filter((b) => b.classList.contains('chosen')).map((b) => b.textContent).join('|') === 'Patch it in place',
  buttons(card).map((b) => `${b.textContent}:${b.classList.contains('chosen')}`).join('|'));

// The card short-circuits on an unchanged signature, and a selection changes only a
// field's state - leaving it out of the signature made a tap look like it did nothing.
card = newCard(FIELDS);
card.hass = formEnv(twoFields).hass;
card.hass = formEnv({
  1: { label: 'Approach', options: ['Rewrite it', 'Patch it in place (Recommended)'], state: 'Rewrite it' },
  2: { label: 'When', options: ['Now', 'After the release'] },
}).hass;
check('and the mark follows the state once the selection lands',
  buttons(card).filter((b) => b.classList.contains('chosen')).map((b) => b.textContent).join('|') === 'Rewrite it',
  buttons(card).map((b) => `${b.textContent}:${b.classList.contains('chosen')}`).join('|'));

card = newCard(FIELDS);
card.hass = formEnv({}).hass;
check('a decision offering only Cancel, with no field armed, is just that one row',
  labels(card).join('|') === 'Cancel request', labels(card).join('|'));
card = newCard(FIELDS);
card.hass = hassWith('Idle', ['Idle']).hass;
check('and a cleared question with field slots configured shows nothing at all',
  card.hidden === true);
check('"fields" is optional, so a single-choice question needs no change',
  (() => { const c = new AgentBridgeChoicesCard(); c.setConfig({ decision: DECISION }); return c._fields.length === 0; })());

console.log('--- it is wired up ---');
check('the element is registered under its own name',
  /customElements\.define\('agent-bridge-choices-card'/.test(source));
check('and offered in the card picker',
  sandbox.window.customCards.some((c) => c.type === 'agent-bridge-choices-card'));
check('the card version is the one the dashboard gates the card on', CARD_VERSION === '1.15.0', CARD_VERSION);
check('"decision" is required', (() => {
  try { new AgentBridgeChoicesCard().setConfig({}); return false; } catch (e) { return /decision/.test(e.message); }
})());

console.log('');
console.log('--- a session driven by an agent is marked as one ---');
// An agent driving a session does what you do - set the reply text, press Submit - so
// the two arrive as identical service calls. The daemon tells them apart by the Home
// Assistant account behind the press and publishes it as `driver`; the card turns that
// into a purple edge, so a session being driven remotely says so at a glance.
const S_STATUS = 'sensor.agent_bridge_abc_status';
const S_ACTIVITY = 'sensor.agent_bridge_abc_activity';
const S_DECISION = 'select.agent_bridge_abc_decision';

function renderSession({ status, driver, question }) {
  const card = Object.create(AgentBridgeSessionCard.prototype);
  card._frame = new FakeElement('div');
  card._collapsed = false;
  card._setCollapsed = () => { card._collapsed = false; };
  card._config = { status: S_STATUS, activity: S_ACTIVITY, decision: S_DECISION };
  const activityAttrs = {};
  if (driver !== undefined) { activityAttrs.driver = driver; }
  card._hass = {
    states: {
      [S_STATUS]: { state: status || 'idle', attributes: {} },
      [S_ACTIVITY]: { state: 'x', attributes: activityAttrs },
      [S_DECISION]: { state: 'Idle', attributes: question ? { question } : {} },
    },
  };
  card._renderState();
  return card._frame.classList;
}

check('a session you are driving has no agent glow',
  renderSession({ status: 'working', driver: 'human' }).contains('agent') === false);
check('and still shows it is working',
  renderSession({ status: 'working', driver: 'human' }).contains('working'));
check('a session an agent is driving is marked',
  renderSession({ status: 'working', driver: 'agent' }).contains('agent'));
check('and keeps its working pulse, so the purple replaces the colour not the motion',
  renderSession({ status: 'working', driver: 'agent' }).contains('working'));
check('an idle session left under an agent still says so',
  renderSession({ status: 'idle', driver: 'agent' }).contains('agent'));
check('a question an agent asked for is still marked waiting',
  (() => {
    const cl = renderSession({ status: 'idle', driver: 'agent', question: 'Which one?' });
    return cl.contains('waiting') && cl.contains('agent');
  })());
check('a card served by an older daemon, with no driver at all, reads as yours',
  renderSession({ status: 'working' }).contains('agent') === false);
check('the purple is a variable, so a theme can change it',
  /--agent-bridge-agent-color/.test(source));
check('and the glow has its own keyframes rather than reusing the working one',
  /@keyframes cpagent/.test(source));

console.log('');
if (failures) {
  console.log(`${failures} check(s) failed`);
  process.exit(1);
}
console.log('All card checks passed');
