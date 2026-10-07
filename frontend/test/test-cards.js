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

// Dotted versions compare as numbers, not as text: '1.20.0' sorts before '1.9.0' as a
// string, which would have read as the card having fallen behind the dashboard.
function cmpVersion(a, b) {
  const pa = String(a).split('.').map(Number);
  const pb = String(b).split('.').map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d) { return d < 0 ? -1 : 1; }
  }
  return 0;
}

// --- the card itself, in a DOM small enough to run it (card-harness.js) --------

const { FakeElement, loadCards } = require('./card-harness');
const { AgentBridgeChoicesCard, AgentBridgeSessionCard, AgentBridgeActivityCard, CARD_VERSION, sandbox, source } = loadCards();

// --- the harness ------------------------------------------------------------------

const DECISION = 'select.agent_bridge_abc_decision';

function newCard(fields, submit) {
  const card = new AgentBridgeChoicesCard();
  const config = { decision: DECISION };
  if (fields) { config.fields = fields; }
  if (submit) { config.submit = submit; }
  card.setConfig(config);
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
// Nothing commits on the tap any more. A tap says what the answer will be; Send
// answer sends it. The two used to be one gesture on a single choice and two on a
// form, which is the same card behaving differently for no reason you could see,
// and a tap is the easiest thing to do by accident on a phone.
const SUBMIT = 'button.agent_bridge_abc_submit';
const CANCEL_ROW = 'Cancel request';

function hassFor(state, options, { defer = false, reject = false, rejectButton = false, attrs = undefined } = {}) {
  const calls = [];
  const base = options === undefined ? {} : { options };
  const states = { [DECISION]: { state, attributes: Object.assign(base, attrs || {}) } };
  const env = {
    calls,
    states,
    // Applies what a call asked for, the way Home Assistant pushing the new state
    // back does. Held back when deferring, which is the case the card has to survive:
    // service completion and the state arriving are two different events.
    settle() {
      for (const call of calls.splice(0, calls.length)) {
        if (call.domain !== 'select') { continue; }
        if (states[call.data.entity_id]) { states[call.data.entity_id].state = call.data.option; }
      }
      env.card.hass = env.hass;
    },
    hass: {
      states,
      callService: (domain, service, data) => {
        calls.push({ domain, service, data });
        if (reject) { return Promise.reject(new Error('not allowed')); }
        if (rejectButton && domain === 'button') { return Promise.reject(new Error('not allowed')); }
        if (!defer && domain === 'select') {
          if (states[data.entity_id]) { states[data.entity_id].state = data.option; }
          env.card.hass = env.hass;
        }
        return Promise.resolve();
      },
    },
  };
  return env;
}

const flush = () => new Promise((r) => setImmediate(r));

card = newCard(undefined, SUBMIT);
let env = hassFor('Awaiting answer...', ['Awaiting answer...', 'Yes - reboot now', 'Cancel request']);
env.card = card;
card.hass = env.hass;
rows(card)[0].click();
check('a tap selects that option on the entity', env.calls.length === 1 &&
  env.calls[0].domain === 'select' && env.calls[0].service === 'select_option' &&
  env.calls[0].data.entity_id === DECISION && env.calls[0].data.option === 'Yes - reboot now',
  JSON.stringify(env.calls));
check('but it does not send, and the rows stay live',
  !card.shadowRoot.querySelector('.choices').classList.contains('sending'));
check('and Send answer is offered, because there is now something to commit',
  labels(card).includes('Send answer'), labels(card).join('|'));
env.settle();
// The press only goes once the tap has been acknowledged, which is a promise even
// when the stand-in answers immediately. Captured here rather than read later: the
// rest of this file reassigns `card` and `env` while this is waiting its turn.
const tapCard = card;
const tapEnv = env;
async function checkTapThenSend() {
  await flush();
  buttons(tapCard).find((b) => b.textContent === 'Send answer').click();
  check('Send answer presses the Send button the daemon waits on',
    tapEnv.calls.length === 1 && tapEnv.calls[0].domain === 'button' && tapEnv.calls[0].service === 'press' &&
    tapEnv.calls[0].data.entity_id === SUBMIT, JSON.stringify(tapEnv.calls));
}

card = newCard(undefined, SUBMIT);
env = hassFor('Awaiting answer...', ['Awaiting answer...', 'Yes - reboot now', 'Cancel request'], { defer: true });
env.card = card;
card.hass = env.hass;
buttons(card).find((b) => b.textContent === CANCEL_ROW).click();
check('Cancel still acts on the tap, because withdrawing is not an answer',
  env.calls.length === 1 && env.calls[0].data.option === CANCEL_ROW, JSON.stringify(env.calls));
check('and the rows are marked as sending while it is in flight',
  card.shadowRoot.querySelector('.choices').classList.contains('sending'));
check('Send answer sits above it, because that is the row being looked for',
  labels(card).indexOf('Send answer') < labels(card).indexOf(CANCEL_ROW), labels(card).join('|'));
rows(card)[0].click();
check('so a tap behind a cancel sends nothing more', env.calls.length === 1, JSON.stringify(env.calls));

console.log('--- a question the tap itself answers ---');
// A Codex approval is published without the snapshot a press is checked against, so
// the daemon acts on Approve or Deny the moment it sees it and never looks for a
// press. Drawing Send beside that offered a confirmation step that did not exist:
// the command was already approved by the tap somebody made meaning to review it.
const tapOnly = newCard(undefined, SUBMIT);
const tapOnlyEnv = hassFor('Awaiting answer...', ['Awaiting answer...', 'Approve', 'Deny'],
  { attrs: { answer_on_tap: true } });
tapOnlyEnv.card = tapOnly;
tapOnly.hass = tapOnlyEnv.hass;
check('an approval still offers both choices',
  labels(tapOnly).join('|') === 'Approve|Deny', labels(tapOnly).join('|'));
check('but no Send answer beside them, because the tap is the answer',
  !labels(tapOnly).includes('Send answer'), labels(tapOnly).join('|'));
rows(tapOnly)[0].click();
check('and the tap still sets the selector, which is what the daemon reads',
  tapOnlyEnv.calls.length === 1 && tapOnlyEnv.calls[0].domain === 'select' &&
  tapOnlyEnv.calls[0].data.option === 'Approve', JSON.stringify(tapOnlyEnv.calls));
// The attribute is what does this, not the options happening to read Approve/Deny:
// a question that really is answered with Send must keep it whatever it offers.
const sendOnSame = newCard(undefined, SUBMIT);
const sendOnSameEnv = hassFor('Awaiting answer...', ['Awaiting answer...', 'Approve', 'Deny']);
sendOnSameEnv.card = sendOnSame;
sendOnSame.hass = sendOnSameEnv.hass;
check('the same options without the attribute are still sent with Send',
  labels(sendOnSame).includes('Send answer'), labels(sendOnSame).join('|'));

// The daemon clears the question, which is what releases the card for the next one.
card.hass = hassFor('Idle', ['Idle']).hass;
env = hassFor('Awaiting answer...', ['Awaiting answer...', 'Another question', 'Cancel request']);
env.card = card;
card.hass = env.hass;
rows(card)[0].click();
check('the next question can be answered again',
  env.calls.length === 1 && env.calls[0].data.option === 'Another question', JSON.stringify(env.calls));

console.log('--- a tap that Home Assistant has not confirmed yet ---');
// Two taps in a row used to compute from the same state, because the second ran
// before the first had been pushed back: ticking Auth then Search sent "Auth" and
// then "Search", losing Auth. Send had the matching problem - pressed straight after
// a tap it committed whatever the slot still held.
//
// In its own function because it has to await: a tap is settled only once Home
// Assistant has acknowledged it, and an acknowledgement is a promise. The rest of
// this file runs while this is awaiting and reassigns the shared `card` and `env`,
// so both are local here.
async function checkUnconfirmedTap() {
  const unconfirmedCard = newCard(undefined, SUBMIT);
  const unconfirmedEnv = hassFor('Awaiting answer...',
    ['Awaiting answer...', 'Yes - reboot now', 'No - leave it', 'Cancel request'], { defer: true });
  unconfirmedEnv.card = unconfirmedCard;
  unconfirmedCard.hass = unconfirmedEnv.hass;
  const c = unconfirmedCard;
  const e = unconfirmedEnv;

  rows(c)[0].click();
  rows(c)[1].click();
  check('a second tap still replaces the first, not the state behind it',
    e.calls.length === 2 && e.calls[1].data.option === 'No - leave it', JSON.stringify(e.calls));
  check('the row you last tapped is the one shown as chosen',
    buttons(c).filter((b) => b.classList.contains('chosen')).map((b) => b.textContent).join('|') === 'No - leave it',
    buttons(c).filter((b) => b.classList.contains('chosen')).map((b) => b.textContent).join('|'));
  check('Send is held while anything is unconfirmed',
    buttons(c).find((b) => b.textContent === 'Send answer').getAttribute('disabled') === 'disabled');
  check('and the card says why rather than looking broken',
    labels(c).includes('Saving your choice...'), labels(c).join('|'));
  buttons(c).find((b) => b.textContent === 'Send answer').click();
  check('pressing Send while unconfirmed sends nothing',
    e.calls.filter((x) => x.domain === 'button').length === 0, JSON.stringify(e.calls));

  // Acknowledged but the state has not arrived: still held, because the slot has not
  // been seen holding what was asked for.
  await flush();
  check('an acknowledgement on its own does not release Send',
    buttons(c).find((b) => b.textContent === 'Send answer').getAttribute('disabled') === 'disabled',
    labels(c).join('|'));

  e.settle();
  await flush();
  check('once the state arrives the note goes', !labels(c).includes('Saving your choice...'), labels(c).join('|'));
  check('and Send is released',
    buttons(c).find((b) => b.textContent === 'Send answer').getAttribute('disabled') === null);
  buttons(c).find((b) => b.textContent === 'Send answer').click();
  check('exactly the confirmed answer is sent, once',
    e.calls.length === 1 && e.calls[0].domain === 'button', JSON.stringify(e.calls));
}

async function checkRefusedSelection() {
  // Local, not the shared `card`/`env`: the rest of this file runs while this is
  // awaiting, and it reassigns both.
  const rejectCard = newCard(undefined, SUBMIT);
  const rejectEnv = hassFor('Awaiting answer...',
    ['Awaiting answer...', 'Yes - reboot now', 'Cancel request'], { reject: true });
  rejectEnv.card = rejectCard;
  rejectCard.hass = rejectEnv.hass;
  rows(rejectCard)[0].click();
  await flush();
  check('a refused call takes its tick back rather than lying about it',
    buttons(rejectCard).filter((b) => b.classList.contains('chosen')).length === 0,
    buttons(rejectCard).filter((b) => b.classList.contains('chosen')).map((b) => b.textContent).join('|'));
  check('and says so where the rows are',
    labels(rejectCard).some((l) => l.startsWith('Home Assistant would not take that')),
    labels(rejectCard).join('|'));
  check('with Send released, so it can be tried again',
    buttons(rejectCard).find((b) => b.textContent === 'Send answer').getAttribute('disabled') === null);
}

/*
 * A Home Assistant that does nothing on its own.
 *
 * Every call is parked, and the test decides when - and whether - it completes, and
 * separately when the new state arrives. Those are two events and the card has to
 * survive them happening in any order; the ordinary harness ties them together, so
 * the cases that actually went wrong in the field cannot be written with it.
 */
function controlledEnv(armed, decisionId) {
  const calls = [];
  const attributes = {
    options: ['Awaiting answer...', 'Cancel request'],
    decision_id: decisionId || 'q1',
  };
  const states = { [DECISION]: { state: 'Awaiting answer...', attributes } };
  for (let i = 1; i <= 4; i++) {
    const field = armed[i];
    if (!field) { states[F(i)] = { state: 'Idle', attributes: { options: ['Idle'] } }; continue; }
    attributes[`field_${i}_label`] = field.label;
    if (field.multi) {
      attributes[`field_${i}_multi`] = true;
      attributes[`field_${i}_options`] = field.options;
      attributes[`field_${i}_separator`] = ' + ';
      // Absent for a bridge old enough to publish only the options written out, which
      // is what the card has to keep writing back to it.
      if (field.codes) { attributes[`field_${i}_codes`] = true; }
    }
    states[F(i)] = {
      state: field.state || 'Choose...',
      attributes: { options: ['Choose...'].concat(field.slotOptions || field.options) },
    };
  }
  const env = {
    calls,
    states,
    push() { env.card.hass = env.hass; },
    // The state Home Assistant eventually pushes back, on its own schedule.
    arrive(entityId, value) { states[entityId].state = value; env.push(); },
    // A question withdrawn and replaced by another, which is what a session does
    // when it asks something else before the first was answered. The attributes are
    // rebuilt rather than merged, because the bridge publishes them as one retained
    // JSON document and Home Assistant replaces the whole set with it - a stale
    // field_n_multi left behind would draw a single choice as a multi-select.
    replace(nextId, nextArmed) {
      for (const key of Object.keys(attributes)) {
        if (key !== 'options') { delete attributes[key]; }
      }
      attributes.decision_id = nextId;
      for (let i = 1; i <= 4; i++) {
        const field = nextArmed[i];
        if (!field) { states[F(i)] = { state: 'Idle', attributes: { options: ['Idle'] } }; continue; }
        attributes[`field_${i}_label`] = field.label;
        states[F(i)] = {
          state: field.state || 'Choose...',
          attributes: { options: ['Choose...'].concat(field.options) },
        };
      }
      env.push();
    },
    hass: {
      states,
      callService: (domain, service, data) => {
        let settle;
        const promise = new Promise((resolve, reject) => { settle = { resolve, reject }; });
        // Nothing here is ever unhandled: the card attaches handlers synchronously,
        // and a test that never completes a call leaves a promise nobody rejects.
        calls.push({ domain, service, data, settle, promise });
        return promise;
      },
    },
  };
  return env;
}

const pickedRows = (card) =>
  buttons(card).filter((b) => b.classList.contains('chosen')).map((b) => b.textContent).join('|');
const sendRow = (card) => buttons(card).find((b) => b.textContent === 'Send answer');

async function checkDeferredChoices() {
  console.log('--- a set written as positions rather than as words ---');
  // Six plainly-worded options joined together run to 350 characters, and a Home
  // Assistant select entry holds 255. That is why a real question on 2026-10-05 was
  // refused outright and sent to the terminal. Positions are short whatever the
  // options say.
  const LONG = [
    'Restore this VM to release 1.32.2 now',
    'Leave the branch installed so I can keep testing',
    'Investigate why the dashboard stopped re-rendering at 19:30',
    'Fix the Scout headless copilot.exe being counted as a CLI session',
    'Commit the correction work and report to the coordinator',
    'Raise the diverged release line (v1.32.2 vs main) with the coordinator',
  ];
  let card = newCard(FIELDS, SUBMIT);
  let env = controlledEnv({ 1: { label: 'Follow-ups', multi: true, codes: true, options: LONG } });
  env.card = card;
  card.hass = env.hass;
  check('every option is drawn in full, however long it is',
    LONG.every((o) => labels(card).includes(o)), labels(card).join('|'));
  buttons(card).find((b) => b.textContent === LONG[0]).click();
  buttons(card).find((b) => b.textContent === LONG[2]).click();
  buttons(card).find((b) => b.textContent === LONG[5]).click();
  check('three ticks are written as three positions',
    env.calls[env.calls.length - 1].data.option === '#1,3,6',
    env.calls.map((c) => c.data.option).join(' / '));
  check('and what is written stays far inside what a select entry can hold',
    env.calls.every((c) => c.data.option.length <= 32),
    env.calls.map((c) => c.data.option.length).join(','));
  for (const call of env.calls) { call.settle.resolve(); }
  env.arrive(F(1), '#1,3,6');
  await flush();
  check('positions coming back tick exactly those rows',
    pickedRows(card) === [LONG[0], LONG[2], LONG[5]].join('|'), pickedRows(card));

  // A bridge that never published positions gets the words back, unchanged.
  card = newCard(FIELDS, SUBMIT);
  env = controlledEnv({ 1: { label: 'Features', multi: true, options: ['Auth', 'Billing', 'Search'] } });
  env.card = card;
  card.hass = env.hass;
  buttons(card).find((b) => b.textContent === 'Auth').click();
  buttons(card).find((b) => b.textContent === 'Search').click();
  check('an older bridge still gets the options written out',
    env.calls[env.calls.length - 1].data.option === 'Auth + Search',
    env.calls.map((c) => c.data.option).join(' / '));
  for (const call of env.calls) { call.settle.resolve(); }
  env.arrive(F(1), 'Auth + Search');
  await flush();
  check('and the words coming back still tick those rows',
    pickedRows(card) === 'Auth|Search', pickedRows(card));

  // A slot holding positions this field does not have is not a set to make the best
  // of: showing one nobody picked is how a wrong answer gets sent.
  for (const bad of ['#4', '#0', '#1,1', '#1,', '#', '#1,x']) {
    card = newCard(FIELDS, SUBMIT);
    env = controlledEnv({ 1: { label: 'Features', multi: true, codes: true, options: ['Auth', 'Billing', 'Search'], state: bad } });
    env.card = card;
    card.hass = env.hass;
    check(`'${bad}' ticks nothing rather than guessing`, pickedRows(card) === '', pickedRows(card));
  }

  // A field that offers an option written like a position. For it, '#1' is that
  // option's own text, so whether the field uses positions has to be asked before the
  // value's shape is tested. Asking in the other order showed the FIRST option ticked
  // when the second had been chosen - and the backend had the same bug separately, so
  // fixing one proved nothing about the other.
  card = newCard(FIELDS, SUBMIT);
  env = controlledEnv({ 1: { label: 'Pick', multi: true, options: ['X', '#1'], state: '#1',
    slotOptions: ['X', '#1', 'X + #1'] } });
  env.card = card;
  card.hass = env.hass;
  check('a literal position is ticked as the option it is, not as a position',
    pickedRows(card) === '#1', pickedRows(card));
  buttons(card).find((b) => b.textContent === 'X').click();
  check('and ticking the other one composes in words, because this field has no positions',
    env.calls[env.calls.length - 1].data.option === 'X + #1',
    env.calls.map((c) => c.data.option).join(' / '));
  env.calls[env.calls.length - 1].settle.resolve();
  await flush();
  env.arrive(F(1), 'X + #1');
  check('and both come back ticked',
    pickedRows(card) === 'X|#1', pickedRows(card));

  // The same shape where the bridge *did* offer positions: now '#1' is a position.
  card = newCard(FIELDS, SUBMIT);
  env = controlledEnv({ 1: { label: 'Features', multi: true, codes: true,
    options: ['Auth', 'Billing'], state: '#1' } });
  env.card = card;
  card.hass = env.hass;
  check('where the field does use positions, the same text is read as one',
    pickedRows(card) === 'Auth', pickedRows(card));

  console.log('--- a slot that moves on its own ---');

  // A slot that moves after the card has seen it settle. Another viewer answering the
  // same question looks identical to a state arriving out of order, and both end the
  // same way: two rows ticked became one row ticked on its own, Send stayed live, and
  // pressing it sent the one. The rows were never wrong - what was wrong was letting
  // it go without anybody looking.
  card = newCard(FIELDS, SUBMIT);
  env = controlledEnv({ 1: { label: 'Features', multi: true, codes: true, options: ['Auth', 'Billing', 'Search'] } });
  env.card = card;
  card.hass = env.hass;
  buttons(card).find((b) => b.textContent === 'Auth').click();
  buttons(card).find((b) => b.textContent === 'Search').click();
  for (const call of env.calls) { call.settle.resolve(); }
  await flush();
  env.arrive(F(1), '#1,3');
  check('both ticks settle and Send is live',
    pickedRows(card) === 'Auth|Search' && sendRow(card).getAttribute('disabled') === null, pickedRows(card));

  env.arrive(F(1), '#1');
  check('a slot that moves on its own still shows what is really there',
    pickedRows(card) === 'Auth', pickedRows(card));
  check('but Send is held, because that is not what was chosen here',
    sendRow(card).getAttribute('disabled') === 'disabled', labels(card).join('|'));
  check('and the card says what happened',
    labels(card).includes('Changed since you chose - check what is ticked'), labels(card).join('|'));
  const before = env.calls.length;
  sendRow(card).click();
  check('pressing it anyway sends nothing',
    env.calls.length === before, JSON.stringify(env.calls.slice(before).map((c) => c.domain)));

  // Tapping adopts what is there now and the warning goes.
  buttons(card).find((b) => b.textContent === 'Search').click();
  env.calls[env.calls.length - 1].settle.resolve();
  await flush();
  env.arrive(F(1), '#1,3');
  check('tapping adopts it and clears the warning',
    !labels(card).includes('Changed since you chose - check what is ticked') &&
    pickedRows(card) === 'Auth|Search' && sendRow(card).getAttribute('disabled') === null,
    `${pickedRows(card)} / ${labels(card).join('|')}`);


  card = newCard(FIELDS, SUBMIT);
  env = controlledEnv({ 1: { label: 'Features', multi: true, codes: true, options: ['Auth', 'Billing'], state: '#1' } });
  env.card = card;
  card.hass = env.hass;
  check('the slot opens holding the first option', pickedRows(card) === 'Auth', pickedRows(card));
  buttons(card).find((b) => b.textContent === 'Billing').click();
  buttons(card).find((b) => b.textContent === 'Billing').click();
  check('toggling back asks for the value the slot is already on',
    env.calls[env.calls.length - 1].data.option === '#1',
    env.calls.map((c) => c.data.option).join(' / '));
  check('and Send stays held until that is acknowledged, not because the state matches',
    sendRow(card).getAttribute('disabled') === 'disabled', labels(card).join('|'));
  // The second call acknowledged while the first is still in flight. The pending set
  // holds only the latest value asked for, so the first was invisible to it and Send
  // went live over a write that could still land and tick the row back on.
  env.calls[1].settle.resolve();
  await flush();
  check('an earlier write still in flight keeps Send held, even once the later one is acknowledged',
    sendRow(card).getAttribute('disabled') === 'disabled', labels(card).join('|'));
  env.calls[0].settle.resolve();
  await flush();
  check('once nothing is outstanding Send is released',
    sendRow(card).getAttribute('disabled') === null && pickedRows(card) === 'Auth', pickedRows(card));
  await flush();

  console.log('--- answers given faster than Home Assistant replies ---');

  // Ticking two options and having the first one refused used to untick the second
  // as well: the card matched a late reply by question id, and two taps on one
  // question share it. The answer then sent was "Billing" with no sign that
  // anything had been dropped.
  card = newCard(FIELDS, SUBMIT);
  env = controlledEnv({ 1: { label: 'Features', multi: true, options: ['Auth', 'Billing', 'Search'] } });
  env.card = card;
  card.hass = env.hass;
  buttons(card).find((b) => b.textContent === 'Auth').click();
  buttons(card).find((b) => b.textContent === 'Billing').click();
  check('a second tick composes on the first rather than replacing it',
    env.calls.length === 2 && env.calls[1].data.option === 'Auth + Billing', JSON.stringify(env.calls.map((c) => c.data.option)));
  env.calls[0].settle.reject(new Error('too slow'));
  await flush();
  check('an older refusal leaves the newer ticks exactly as they were',
    pickedRows(card) === 'Auth|Billing', pickedRows(card));
  check('and Send stays held, because the newer tick is still unconfirmed',
    sendRow(card).getAttribute('disabled') === 'disabled');
  env.calls[1].settle.resolve();
  env.arrive(F(1), 'Auth + Billing');
  await flush();
  check('once the slot catches up both ticks are confirmed',
    pickedRows(card) === 'Auth|Billing' && sendRow(card).getAttribute('disabled') === null, pickedRows(card));

  // Accepted, but the slot already held exactly that. Nothing further arrives, so
  // completion is the only thing that can release Send.
  card = newCard(FIELDS, SUBMIT);
  env = controlledEnv({ 1: { label: 'Features', multi: true, options: ['Auth', 'Billing'], state: 'Auth' } });
  env.card = card;
  card.hass = env.hass;
  buttons(card).find((b) => b.textContent === 'Billing').click();
  buttons(card).find((b) => b.textContent === 'Billing').click();
  check('ticking and unticking asks for what the slot already holds',
    env.calls[env.calls.length - 1].data.option === 'Auth', JSON.stringify(env.calls.map((c) => c.data.option)));
  for (const call of env.calls) { call.settle.resolve(); }
  await flush();
  check('and Send is released on acceptance, not left waiting for a state that will never change',
    sendRow(card).getAttribute('disabled') === null, labels(card).join('|'));

  // The states arriving out of order. Only the tick that was actually asked for
  // last may clear; an earlier value turning up afterwards must not look like
  // confirmation of it.
  card = newCard(FIELDS, SUBMIT);
  env = controlledEnv({ 1: { label: 'Features', multi: true, options: ['Auth', 'Billing', 'Search'] } });
  env.card = card;
  card.hass = env.hass;
  buttons(card).find((b) => b.textContent === 'Auth').click();
  buttons(card).find((b) => b.textContent === 'Search').click();
  // Accepted, both of them. Home Assistant does not push a new state for a call it
  // has not taken, so the states below are the only thing still outstanding.
  for (const call of env.calls) { call.settle.resolve(); }
  await flush();
  env.arrive(F(1), 'Auth');
  check('a state from the earlier tap does not confirm the later one',
    sendRow(card).getAttribute('disabled') === 'disabled' && pickedRows(card) === 'Auth|Search', pickedRows(card));
  env.arrive(F(1), 'Auth + Search');
  check('and the one that was actually asked for does',
    sendRow(card).getAttribute('disabled') === null && pickedRows(card) === 'Auth|Search', pickedRows(card));

  // The question is replaced while a tap is still in flight. Its reply belongs to a
  // question that is no longer on screen and must not touch the new one.
  card = newCard(FIELDS, SUBMIT);
  env = controlledEnv({ 1: { label: 'Features', multi: true, options: ['Auth', 'Billing'] } }, 'q1');
  env.card = card;
  card.hass = env.hass;
  buttons(card).find((b) => b.textContent === 'Auth').click();
  const orphan = env.calls[0];
  env.replace('q2', { 1: { label: 'Database', options: ['PostgreSQL', 'SQLite'] } });
  check('the replacement question is drawn with nothing carried over',
    labels(card).join('|').includes('PostgreSQL') && pickedRows(card) === '', labels(card).join('|'));
  orphan.settle.reject(new Error('gone'));
  await flush();
  check('and a reply to the question that went does not mark the new one up',
    pickedRows(card) === '' && !labels(card).some((l) => l.startsWith('Home Assistant would not take that')),
    labels(card).join('|'));
  check('nor does it hold the new question\'s Send',
    sendRow(card).getAttribute('disabled') === null);

  // Send itself refused. It used to be fired and forgotten, so a press Home
  // Assistant threw away looked exactly like one the session was still thinking
  // about - and the answer was never sent.
  card = newCard(FIELDS, SUBMIT);
  env = controlledEnv({ 1: { label: 'Features', multi: true, options: ['Auth', 'Billing'], state: 'Auth' } });
  env.card = card;
  card.hass = env.hass;
  sendRow(card).click();
  check('Send presses the button the daemon waits on',
    env.calls.length === 1 && env.calls[0].domain === 'button' && env.calls[0].service === 'press',
    JSON.stringify(env.calls.map((c) => `${c.domain}.${c.service}`)));
  env.calls[0].settle.reject(new Error('nope'));
  await flush();
  check('a refused Send says so rather than looking like a session still thinking',
    labels(card).some((l) => l.startsWith('Send failed')), labels(card).join('|'));
  check('and leaves the ticks alone, so it can simply be pressed again',
    pickedRows(card) === 'Auth' && sendRow(card).getAttribute('disabled') === null, pickedRows(card));
  sendRow(card).click();
  check('pressing it again really does press it again',
    env.calls.length === 2 && env.calls[1].domain === 'button', JSON.stringify(env.calls.map((c) => c.domain)));
  env.calls[1].settle.resolve();
  await flush();

  // A question with no Send button cannot be answered from the card at all, and
  // must not quietly offer a row that does nothing.
  card = newCard(FIELDS);
  env = controlledEnv({ 1: { label: 'Features', multi: true, options: ['Auth', 'Billing'] } });
  env.card = card;
  card.hass = env.hass;
  check('a card with no submit entity offers no Send row at all',
    !labels(card).includes('Send answer'), labels(card).join('|'));
  buttons(card).find((b) => b.textContent === 'Auth').click();
  check('and a tick on it still only sets the slot, never sends',
    env.calls.length === 1 && env.calls[0].domain === 'select', JSON.stringify(env.calls.map((c) => c.domain)));
  env.calls[0].settle.resolve();
  await flush();

  // The legacy shape: one selector carrying its own options, no fields. It used to
  // go the instant a row was tapped.
  card = newCard(undefined, SUBMIT);
  env = controlledEnv({});
  env.states[DECISION].attributes.options = ['Awaiting answer...', 'Yes', 'No', 'Cancel request'];
  env.card = card;
  card.hass = env.hass;
  check('a selector carrying its own choices still offers Send',
    labels(card).includes('Send answer'), labels(card).join('|'));
  buttons(card).find((b) => b.textContent === 'Yes').click();
  check('and a tap on it sends nothing on its own',
    env.calls.length === 1 && env.calls[0].domain === 'select', JSON.stringify(env.calls.map((c) => c.domain)));
  env.calls[0].settle.resolve();
  env.arrive(DECISION, 'Yes');
  await flush();
  sendRow(card).click();
  check('it takes an explicit Send, like every other shape',
    env.calls.length === 2 && env.calls[1].domain === 'button' && env.calls[1].data.entity_id === SUBMIT,
    JSON.stringify(env.calls.map((c) => `${c.domain}.${c.service}`)));
  env.calls[1].settle.resolve();
  await flush();
}

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
// The generator gates its newest card shape on 1.20.0 - the X on an offline machine's
// row, and the topics that go with it. The card may run ahead of that - a fix needing
// no new config key still has to change the version, because that is what the resource
// URL is keyed on and an unchanged one is never re-served - but it must never fall
// behind it, and a fix takes the patch place so that the next minor is still free for
// the shape the generator will gate on.
check('the card is at least the version the dashboard gates the card on',
  cmpVersion(CARD_VERSION, '1.20.0') >= 0, CARD_VERSION);
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
check('and the glow has a colour of its own rather than reusing the working one',
  /\.frame\.agent\.working ~ \.glow[\s\S]{0,160}--agent-bridge-agent-color/.test(source));

console.log('');
console.log('--- a session waiting on background agents is not idle ---');
/*
 * A background agent outlives the turn that started it: the session's own turn ends,
 * so the transcript says idle while work it is waiting on is still running. An idle
 * card is an invitation to close a session that has not finished, which is how a code
 * review ten minutes in was thrown away. The daemon publishes `agents` and how many,
 * and the card reads them out rather than leaving you to guess.
 */
function renderActivity({ status, attributes = {}, question }) {
  const card = Object.create(AgentBridgeActivityCard.prototype);
  card._last = {};
  const el = (tag) => new FakeElement(tag);
  card._els = {
    title: el('div'), meta: el('div'), question: el('div'), q: el('div'),
    response: el('div'), reasoning: el('details'), r: el('div'),
    history: el('details'), list: el('ul'),
    working: el('div'), glyph: el('span'), verb: el('span'), elapsed: el('span'),
  };
  card._config = {
    name: 'review', machine: 'DESK', status: S_STATUS, activity: S_ACTIVITY, decision: S_DECISION,
  };
  card._hass = {
    states: {
      [S_STATUS]: { state: status, attributes },
      [S_ACTIVITY]: { state: '', attributes: {} },
      [S_DECISION]: { state: 'Idle', attributes: question ? { question } : {} },
    },
  };
  card._render();
  return { title: card._els.title.textContent, meta: card._els.meta.textContent };
}

const twoAgents = renderActivity({ status: 'agents', attributes: { background_agents: 2 } });
check('the status line says so in words, with how many',
  twoAgents.meta === 'DESK \u2022 status: waiting for 2 background agents', twoAgents.meta);
const oneAgent = renderActivity({ status: 'agents', attributes: { background_agents: 1 } });
check('and one agent is one agent',
  oneAgent.meta === 'DESK \u2022 status: waiting for 1 background agent', oneAgent.meta);
// A machine still running a bridge from before the count was published says the true
// thing it knows rather than "waiting for 0 background agents".
const noCount = renderActivity({ status: 'agents' });
check('a card given no count still says what is happening',
  noCount.meta === 'DESK \u2022 status: waiting for background agents', noCount.meta);
check('it gets a dot of its own, so a glance tells it from both idle and working',
  twoAgents.title === '\u{1F535} review', twoAgents.title);
const plainIdle = renderActivity({ status: 'idle' });
check('while a genuinely idle session reads exactly as it did',
  plainIdle.meta === 'DESK \u2022 status: idle' && plainIdle.title === '\u26AA review',
  `${plainIdle.title} / ${plainIdle.meta}`);
const asked = renderActivity({ status: 'agents', question: 'Which one?' });
check('and a question still takes precedence, because that is waiting on you',
  asked.meta === 'DESK \u2022 status: waiting for you', asked.meta);

check('the frame marks it, rather than leaving it looking closed',
  renderSession({ status: 'agents' }).contains('delegating'));
check('without claiming the session itself is working',
  renderSession({ status: 'agents' }).contains('working') === false);
// The pulse means "this session is thinking right now", which it is not - it is
// waiting. The edge is steady so the two are not confused.
check('its edge is steady, since the glow belongs to a session doing its own work',
  /\.frame\.delegating \{/.test(source) && !/delegating ~ \.glow/.test(source));
check('a question arriving over the top of it still reads as waiting on you',
  renderSession({ status: 'agents', question: 'Which one?' }).contains('waiting'));

console.log('');
console.log('--- the pulse is composited, never repainted ---');
/*
 * `box-shadow` is not a property the compositor can animate, so keyframes on it make
 * every frame of the pulse a main-thread repaint of the whole card - for as long as a
 * session is working, whether or not anything about it changed. Four sessions working
 * at once was enough to make the Home Assistant tab stutter and the window hang.
 *
 * The glow is now a static shadow on a layer of its own whose `opacity` animates,
 * which the GPU runs on its own. The look is the same; the cost is not. These guard
 * the property, because it is the whole point and nothing about the rendered card
 * would look wrong if someone put it back.
 */
function keyframeBlocks(css) {
  const blocks = [];
  const re = /@keyframes\s+([\w-]+)\s*\{/g;
  let m;
  while ((m = re.exec(css))) {
    let depth = 1;
    let i = re.lastIndex;
    while (i < css.length && depth > 0) {
      if (css[i] === '{') { depth++; } else if (css[i] === '}') { depth--; }
      i++;
    }
    blocks.push({ name: m[1], body: css.slice(re.lastIndex, i - 1) });
  }
  return blocks;
}

const frames = keyframeBlocks(source);
const repainting = frames.filter((f) => /box-shadow|border-|width|height|top|left|margin|padding/.test(f.body));
check('the card still animates something', frames.length > 0);
check('and no keyframe animates a property the compositor cannot run',
  repainting.length === 0, repainting.map((f) => f.name).join(', '));
check('the glow pulses on opacity, which it can',
  frames.some((f) => /opacity/.test(f.body)));
check('the glow is a sibling of the frame, whose overflow would otherwise clip it',
  source.indexOf('class="glow"') > source.indexOf('class="frame"')
  && /\.frame\.working ~ \.glow/.test(source));
const baseGlow = (() => {
  // The standalone `.glow` rule, not the `~ .glow` ones: a bare `\.glow \{` matches
  // both, and the pulsing rule does carry will-change, so the check always passed.
  const at = source.search(/\n\s*\.glow \{/);
  return at < 0 ? '' : source.slice(at, source.indexOf('}', at));
})();
check('a layer is only promoted while it is actually pulsing',
  /will-change: opacity/.test(source) && baseGlow !== '' && !/will-change/.test(baseGlow),
  JSON.stringify(baseGlow.slice(0, 120)));
// The glow covers the card exactly, and draws nothing inside it. Were it to take
// pointer events it would swallow every tap meant for the reply box, the choices and
// End session, while looking completely correct.
check('and it never swallows a tap meant for the card underneath it',
  /pointer-events: none/.test(baseGlow));
check('nor shows up as an element to a screen reader',
  /<div class="glow" aria-hidden="true">/.test(source));
check('and a viewer who asked for less motion keeps the glow without the breathing',
  /prefers-reduced-motion[\s\S]{0,200}animation: none/.test(source));

console.log('');
console.log('--- the elapsed-time spinner stops while nobody is looking ---');
/*
 * Home Assistant sits in a pinned tab for days, with one of these timers per working
 * session. The first attempt returned early from the tick while `document.hidden`,
 * which reads correctly and does nothing: the interval still fires on schedule and
 * still wakes the main thread, it just finds nothing to do once it has.
 *
 * A source-text check passed on that version, which is the whole reason these exercise
 * the real methods against a controllable timer and visibility state instead.
 *
 * The card must come from the sandbox whose timers are being counted: a second
 * loadCards() builds a second sandbox with a timer map of its own, and every count
 * then reads zero while the real one fills up.
 */
function spinnerCard() {
  const card = Object.create(AgentBridgeActivityCard.prototype);
  card._els = { glyph: new FakeElement('span'), elapsed: new FakeElement('span') };
  card._since = Date.now();
  return card;
}

const doc = sandbox.document;
const timers = sandbox.intervals;

doc.hidden = false;
timers.clear();
const spin = spinnerCard();
spin._startSpinner();
check('a visible tab gets a running interval', timers.size === 1, `size=${timers.size}`);
check('and is drawn at once rather than after the first 120ms',
  spin._els.glyph.textContent !== '' && spin._els.elapsed.textContent !== '');

spin._startSpinner();
check('starting twice does not stack a second interval', timers.size === 1, `size=${timers.size}`);

doc.hidden = true;
doc._fire('visibilitychange');
check('hiding the tab clears the interval, rather than leaving it firing into nothing',
  timers.size === 0, `size=${timers.size}`);

const hiddenCard = spinnerCard();
hiddenCard._startSpinner();
check('and a card that starts while already hidden arms no interval at all',
  timers.size === 0, `size=${timers.size}`);
hiddenCard._stopSpinner();

spin._els.elapsed.textContent = 'stale';
doc.hidden = false;
doc._fire('visibilitychange');
check('showing it again starts a fresh interval', timers.size === 1, `size=${timers.size}`);
check('and catches the elapsed time up immediately, not 120ms later',
  spin._els.elapsed.textContent !== 'stale', spin._els.elapsed.textContent);

spin._stopSpinner();
check('stopping leaves no interval behind', timers.size === 0, `size=${timers.size}`);
check('and unregisters its visibility listener',
  (doc._listeners.visibilitychange || []).length === 0,
  String((doc._listeners.visibilitychange || []).length));
doc._fire('visibilitychange');
check('so a later visibility change cannot revive it', timers.size === 0, `size=${timers.size}`);

console.log('');
console.log('--- the launch card carries model, effort and context ---');
/*
 * The three tuning selectors are the launch card's only controls whose options change
 * with another control: pick Claude and the model list becomes Claude's. The daemon
 * republishes them when the agent moves, so the card's job is simply to render
 * whatever the entity offers now, send a tap straight back to that entity, and keep
 * out of the way while the list is being read.
 */
const { AgentBridgeLaunchCard } = require('./card-harness').loadCards();

const L = (key) => `select.agent_bridge_desk_new_${key}`;

function launchEnv(states) {
  const calls = [];
  const full = {
    [L('agent')]: { state: 'Copilot', attributes: { options: ['Copilot', 'Claude'] } },
    [L('workspace')]: { state: 'bridge', attributes: { options: ['bridge'] } },
    'text.agent_bridge_desk_new_prompt': { state: ' ', attributes: {} },
    'sensor.agent_bridge_desk_new_session_result': { state: '', attributes: {} },
  };
  Object.assign(full, states);
  return { calls, hass: { states: full, callService: (d, s, data) => calls.push({ domain: d, service: s, data }) } };
}

function launchCard(env) {
  const card = new AgentBridgeLaunchCard();
  card.setConfig({
    machines: [{
      machine: 'desk',
      agent: L('agent'),
      workspace: L('workspace'),
      model: L('model'),
      effort: L('effort'),
      context: L('context'),
      permissions: L('permissions'),
      prompt: 'text.agent_bridge_desk_new_prompt',
      launch: 'button.agent_bridge_desk_new_session',
      result: 'sensor.agent_bridge_desk_new_session_result',
    }],
  });
  card._open = true;
  card.hass = env.hass;
  return card;
}

const TUNED = {
  [L('model')]: { state: 'gpt-5.4', attributes: { options: ['Agent default', 'auto', 'gpt-5.4'] } },
  [L('effort')]: { state: 'xhigh', attributes: { options: ['Agent default', 'low', 'xhigh'] } },
  [L('context')]: { state: 'Agent default', attributes: { options: ['Agent default', 'long_context'] } },
  [L('permissions')]: { state: 'Ask permission', attributes: { options: ['Ask permission', 'Allow all'] } },
};

let lenv = launchEnv(TUNED);
let lcard = launchCard(lenv);
const optionsOf = (key) => lcard.shadowRoot.querySelector(`select[data-key="${key}"]`).children.map((o) => o.value);

check('the model selector offers exactly what its entity offers',
  optionsOf('model').join('|') === 'Agent default|auto|gpt-5.4', optionsOf('model').join('|'));
check('and opens on the value that entity is holding',
  lcard.shadowRoot.querySelector('select[data-key="model"]').value === 'gpt-5.4');
check('effort and context get their own selectors',
  optionsOf('effort').includes('xhigh') && optionsOf('context').includes('long_context'));
check('each row is shown, since its entity has options',
  ['model', 'effort', 'context'].every((k) => lcard.shadowRoot.querySelector(`.f-${k}`).hidden === false));

check('choosing a model sets it on that entity and nothing else', (() => {
  lenv.calls.length = 0;
  lcard._choose('model', 'auto');
  return lenv.calls.length === 1 && lenv.calls[0].domain === 'select' &&
    lenv.calls[0].service === 'select_option' &&
    lenv.calls[0].data.entity_id === L('model') && lenv.calls[0].data.option === 'auto';
})(), JSON.stringify(lenv.calls));

check('what is set shows in the collapsed summary, so a launch says what it will use',
  lcard.shadowRoot.querySelector('.summary').textContent === 'Copilot · bridge · gpt-5.4 · xhigh',
  lcard.shadowRoot.querySelector('.summary').textContent);

check('an axis left at the default is not worth a word in that summary',
  !lcard.shadowRoot.querySelector('.summary').textContent.includes('Agent default'));

// --- the permissions row -------------------------------------------------------
// The launch card is where this is decided now, because the machine that runs the
// session is not always the one choosing: a launch onto another machine used to take
// that machine's newSession.allowAllTools, unseen from where Launch was pressed.
check('permissions offers both options and opens on the one its entity holds',
  optionsOf('permissions').join('|') === 'Ask permission|Allow all' &&
  lcard.shadowRoot.querySelector('select[data-key="permissions"]').value === 'Ask permission',
  optionsOf('permissions').join('|'));

check('asking is the quiet default, so it says nothing in the summary',
  !lcard.shadowRoot.querySelector('.summary').textContent.includes('Ask permission'),
  lcard.shadowRoot.querySelector('.summary').textContent);

check('choosing it sets it on that entity and nothing else', (() => {
  lenv.calls.length = 0;
  lcard._choose('permissions', 'Allow all');
  return lenv.calls.length === 1 && lenv.calls[0].domain === 'select' &&
    lenv.calls[0].service === 'select_option' &&
    lenv.calls[0].data.entity_id === L('permissions') && lenv.calls[0].data.option === 'Allow all';
})(), JSON.stringify(lenv.calls));

check('but allowing everything is worth saying before Launch is pressed', (() => {
  const env = launchEnv(Object.assign({}, TUNED, {
    [L('permissions')]: { state: 'Allow all', attributes: { options: ['Ask permission', 'Allow all'] } },
  }));
  const card = launchCard(env);
  return card.shadowRoot.querySelector('.summary').textContent === 'Copilot · bridge · gpt-5.4 · xhigh · Allow all';
})());

check('a machine whose bridge has no permissions entity shows no permissions row', (() => {
  const env = launchEnv({});
  const card = new AgentBridgeLaunchCard();
  card.setConfig({ machines: [{ machine: 'desk', agent: L('agent'), workspace: L('workspace'), prompt: 'text.agent_bridge_desk_new_prompt', launch: 'button.x', result: 'sensor.y' }] });
  card._open = true;
  card.hass = env.hass;
  return card.shadowRoot.querySelector('.f-permissions').hidden === true;
})());

check('a machine whose bridge has no tuning entities shows no tuning rows', (() => {
  const env = launchEnv({});
  const card = new AgentBridgeLaunchCard();
  card.setConfig({ machines: [{ machine: 'desk', agent: L('agent'), workspace: L('workspace'), prompt: 'text.agent_bridge_desk_new_prompt', launch: 'button.x', result: 'sensor.y' }] });
  card._open = true;
  card.hass = env.hass;
  return ['model', 'effort', 'context'].every((k) => card.shadowRoot.querySelector(`.f-${k}`).hidden === true);
})());

check('a resume still carries them, because they are options of this launch not of the conversation', (() => {
  const env = launchEnv(Object.assign({
    [L('resume')]: { state: 'Yesterday, bridge', attributes: { options: ['New session', 'Yesterday, bridge'] } },
  }, TUNED));
  const card = new AgentBridgeLaunchCard();
  card.setConfig({
    machines: [{
      machine: 'desk', agent: L('agent'), workspace: L('workspace'), resume: L('resume'),
      model: L('model'), effort: L('effort'), context: L('context'),
      prompt: 'text.agent_bridge_desk_new_prompt', launch: 'button.x', result: 'sensor.y',
    }],
  });
  card._open = true;
  card.hass = env.hass;
  const summary = card.shadowRoot.querySelector('.summary').textContent;
  return card.shadowRoot.querySelector('.f-model').hidden === false &&
    !card.shadowRoot.querySelector('.f-model').classList.contains('dim') &&
    summary === 'Resume: Yesterday, bridge · gpt-5.4 · xhigh';
})());

console.log('');
console.log('--- a first message long enough to hand over a whole task ---');
/*
 * A Home Assistant text entity is capped at 255 characters, which is far too short
 * for the box's best use: giving a new session the full context of what it is taking
 * over. The card publishes the prompt to an MQTT topic instead, exactly as the reply
 * box already does, and only falls back to the text entity when the bridge is too old
 * to offer a topic.
 */
const PROMPT_TOPIC = 'copilot/cli/machine/desk/newsession/promptpayload';

function promptCard(env, extra) {
  const card = new AgentBridgeLaunchCard();
  card.setConfig({
    machines: [Object.assign({
      machine: 'desk', agent: L('agent'), workspace: L('workspace'),
      prompt: 'text.agent_bridge_desk_new_prompt',
      launch: 'button.agent_bridge_desk_new_session',
      result: 'sensor.agent_bridge_desk_new_session_result',
    }, extra || {})],
  });
  card._open = true;
  card.hass = env.hass;
  return card;
}

const LONG_PROMPT = 'Take over the migration. '.repeat(40);

check('a prompt longer than a text entity allows is worth testing with', LONG_PROMPT.length > 255, `${LONG_PROMPT.length}`);

check('a prompt typed here is not overwritten by the blank text entity', (() => {
  const env = launchEnv({ 'text.agent_bridge_desk_new_prompt': { state: 'stale leftover', attributes: {} } });
  const card = promptCard(env, { promptTopic: PROMPT_TOPIC });
  card.shadowRoot.querySelector('textarea[data-key="prompt"]').value = 'what I am typing';
  card.hass = env.hass;
  return card.shadowRoot.querySelector('textarea[data-key="prompt"]').value === 'what I am typing';
})());

check('while a bridge without a topic still restores what the entity holds', (() => {
  const env = launchEnv({ 'text.agent_bridge_desk_new_prompt': { state: 'typed on my phone', attributes: {} } });
  const card = promptCard(env, {});
  card.shadowRoot.querySelector('textarea[data-key="prompt"]').value = '';
  card.hass = env.hass;
  return card.shadowRoot.querySelector('textarea[data-key="prompt"]').value === 'typed on my phone';
})());

console.log('');
console.log('--- the status card: counts folded, machines opened ---');
/*
 * This replaced a markdown summary plus a separate Machines card. The two rules that
 * matter are that the counts mean what they say - an offline machine's retained
 * session sensor is not a live session - and that flicking a Detail switch reaches
 * the machine it is drawn beside and stays where it was put.
 */
const statusLoad = require('./card-harness').loadCards();
const { AgentBridgeStatusCard } = statusLoad;

const HOME = {
  machine: 'DSWETT-HOME',
  online: 'binary_sensor.agent_bridge_home_online',
  sessions: 'sensor.agent_bridge_home_sessions',
  version: 'update.agent_bridge_home_update',
  detailed: 'input_boolean.agent_bridge_home_detailed_activity',
};
// No `detailed`: a machine on a bridge from before the switch existed.
const MBP = {
  machine: 'Dans-MBP',
  online: 'binary_sensor.agent_bridge_mbp_online',
  sessions: 'sensor.agent_bridge_mbp_sessions',
  version: 'update.agent_bridge_mbp_update',
};
const D_IDLE = 'select.agent_bridge_a_decision';
const D_ASKED = 'select.agent_bridge_b_decision';

function statusStates(overrides) {
  return Object.assign({
    [HOME.online]: { state: 'on', attributes: {} },
    [HOME.sessions]: { state: '3', attributes: {} },
    [HOME.version]: { state: 'off', attributes: { installed_version: '1.19.0' } },
    [HOME.detailed]: { state: 'on', attributes: {} },
    // Offline, but its session sensor is retained and still says 2.
    [MBP.online]: { state: 'off', attributes: {} },
    [MBP.sessions]: { state: '2', attributes: {} },
    [MBP.version]: { state: 'off', attributes: { installed_version: '1.17.1' } },
    [D_IDLE]: { state: 'Idle', attributes: {} },
    [D_ASKED]: { state: 'Awaiting answer...', attributes: {} },
  }, overrides || {});
}

function statusCard(config, states, open) {
  const calls = [];
  const hass = { states, callService: (d, s, data) => calls.push({ domain: d, service: s, data }) };
  const card = new AgentBridgeStatusCard();
  card.setConfig(config);
  card._open = open !== false;
  card.hass = hass;
  return { card, calls, hass };
}

const BOTH = { machines: [HOME, MBP], decisions: [D_IDLE, D_ASKED] };
let scard = statusCard(BOTH, statusStates()).card;
const summary = () => scard._els.summary.textContent;

check('the folded line carries both counts', summary() === 'Live sessions: 3 · Pending decisions: 1', summary());
check('an offline machine\'s retained session sensor is not counted as live',
  !summary().includes('Live sessions: 5'), summary());
check('a decision sitting at Idle is not pending', summary().includes('Pending decisions: 1'), summary());
check('a question waiting on you colours the line', scard._els.summary.classList.contains('waiting'));
check('and nothing waiting leaves it quiet',
  statusCard(BOTH, statusStates({ [D_ASKED]: { state: 'Idle', attributes: {} } })).card
    ._els.summary.classList.contains('waiting') === false);

check('an online machine\'s row says what it is running and what it is on',
  scard._rows[0].meta.textContent === '3 sessions · 1.19.0', scard._rows[0].meta.textContent);
check('and is marked online', scard._rows[0].row.classList.contains('online'));
check('an offline machine says only that', scard._rows[1].meta.textContent === 'offline', scard._rows[1].meta.textContent);
check('and is not marked online', scard._rows[1].row.classList.contains('online') === false);
check('one session is not "1 sessions"',
  statusCard(BOTH, statusStates({ [HOME.sessions]: { state: '1', attributes: {} } })).card
    ._rows[0].meta.textContent === '1 session · 1.19.0');
check('a machine yet to report a version does not print "undefined"',
  statusCard(BOTH, statusStates({ [HOME.version]: { state: 'off', attributes: {} } })).card
    ._rows[0].meta.textContent === '3 sessions · ?');
check('a machine running a working copy is marked (dev)',
  statusCard({ machines: [Object.assign({ dev: true }, HOME), MBP], decisions: [] }, statusStates()).card
    ._rows[0].meta.textContent === '3 sessions · 1.19.0 (dev)');

check('the machines are hidden while it is folded',
  statusCard(BOTH, statusStates(), false).card._els.machines.hidden === true);
check('and shown when it is opened', scard._els.machines.hidden === false);
check('there is a row per machine, in the order given',
  scard._rows.length === 2 && scard._rows[0].machine.machine === 'DSWETT-HOME');

check('a machine that cannot have a Detail switch gets none', scard._rows[1].toggle === null);
check('one that can gets it, set from its entity', scard._rows[0].toggle.checked === true);
check('with the switch sitting inside that machine\'s own row',
  scard._rows[0].row.children.some((c) => c.classList.contains('detail')));
// The switch is an input_boolean in Home Assistant, not a property of the machine
// process, so an offline machine's Detail setting is still yours to change - it is
// read when that machine comes back. Only a state nobody can read locks it.
check('an offline machine\'s switch can still be set, ready for when it comes back',
  statusCard({ machines: [Object.assign({}, MBP, { detailed: 'input_boolean.agent_bridge_mbp_detailed_activity' })], decisions: [] },
    statusStates({ 'input_boolean.agent_bridge_mbp_detailed_activity': { state: 'off', attributes: {} } })).card
    ._rows[0].toggle.disabled === false);
check('but one whose entity says nothing readable is locked rather than guessed at',
  statusCard(BOTH, statusStates({ [HOME.detailed]: { state: 'unavailable', attributes: {} } })).card
    ._rows[0].toggle.disabled === true);

const flick = statusCard(BOTH, statusStates());
flick.card._rows[0].toggle.checked = false;
flick.card._rows[0].toggle.dispatch('change');
check('flicking a Detail switch toggles that machine\'s entity, not another\'s',
  flick.calls.length === 1 && flick.calls[0].data.entity_id === HOME.detailed, JSON.stringify(flick.calls));
check('through the entity\'s own domain', flick.calls[0].domain === 'input_boolean' && flick.calls[0].service === 'toggle');
flick.card.hass = flick.hass;
check('and it holds its new position while the state catches up, instead of bouncing back',
  flick.card._rows[0].toggle.checked === false);
flick.hass.states[HOME.detailed] = { state: 'off', attributes: {} };
flick.card.hass = flick.hass;
check('then settles on what the entity ended up at', flick.card._rows[0].toggle.checked === false);

check('one machine puts its version on the line you always see',
  statusCard({ machines: [HOME], decisions: [] }, statusStates()).card._els.summary.textContent
    === 'Live sessions: 3 · Pending decisions: 0 · Bridge 1.19.0');
check('and keeps it there while that machine is off, since the update entity is retained',
  statusCard({ machines: [Object.assign({}, HOME, { online: MBP.online })], decisions: [] }, statusStates())
    .card._els.summary.textContent.includes('Bridge 1.19.0'));
check('several do not, since each has its own row to compare',
  !summary().includes('Bridge '), summary());

// This card replaced the entities card that used to draw a toggle row, and with it
// the only thing on the view that pulled ha-switch's chunk into the page.
check('the frontend is asked for that chunk before a switch is drawn', (() => {
  const asked = [];
  statusLoad.sandbox.window.loadCardHelpers = () => {
    asked.push(true);
    return Promise.resolve({ createRowElement: () => ({}) });
  };
  statusCard(BOTH, statusStates());
  delete statusLoad.sandbox.window.loadCardHelpers;
  return asked.length === 1;
})());
check('and not at all when no machine has a switch to draw', (() => {
  const asked = [];
  statusLoad.sandbox.window.loadCardHelpers = () => { asked.push(true); return Promise.resolve({ createRowElement: () => ({}) }); };
  statusCard({ machines: [MBP], decisions: [] }, statusStates());
  delete statusLoad.sandbox.window.loadCardHelpers;
  return asked.length === 0;
})());

check('folded it asks for less room than opened', (() => {
  const folded = statusCard(BOTH, statusStates(), false).card;
  return folded.getCardSize() < scard.getCardSize();
})());

console.log('--- removing a machine that is never coming back ---');
/*
 * A machine that was renamed, reimaged or thrown away never withdraws its own
 * entities, so its row sat on the dashboard reading "offline" for good. The X clears
 * the retained topics the dashboard handed the card, which is exactly what an
 * uninstall on that machine would have published.
 */
const GONE = {
  machine: 'CPC-OLD-NAME',
  online: 'binary_sensor.agent_bridge_gone_online',
  sessions: 'sensor.agent_bridge_gone_sessions',
  version: 'update.agent_bridge_gone_update',
  detailed: 'input_boolean.agent_bridge_gone_detailed_activity',
  forget: [
    'homeassistant/sensor/agent_bridge_gone/sessions/config',
    'homeassistant/binary_sensor/agent_bridge_gone/online/config',
    'copilot/cli/machine/gone/global/state',
  ],
};
const goneStates = () => statusStates({
  [GONE.online]: { state: 'off', attributes: {} },
  [GONE.sessions]: { state: '2', attributes: {} },
  [GONE.version]: { state: 'off', attributes: { installed_version: '1.19.0' } },
  [GONE.detailed]: { state: 'on', attributes: {} },
});

const goneEnv = statusCard({ machines: [HOME, GONE], decisions: [] }, goneStates());
const goneRow = goneEnv.card._rows[1];
check('an offline machine is given an X', goneRow.forget !== null && goneRow.forget.hidden === false);
check('and its Detail switch steps aside for it', goneRow.detail.hidden === true);
check('a machine that is running keeps its switch and is shown no X',
  goneEnv.card._rows[0].detail.hidden === false && goneEnv.card._rows[0].forget === null);
check('an offline machine the dashboard gave no topics for keeps its switch',
  statusCard({ machines: [Object.assign({}, MBP, { detailed: 'input_boolean.agent_bridge_mbp_detailed_activity' })], decisions: [] },
    statusStates({ 'input_boolean.agent_bridge_mbp_detailed_activity': { state: 'off', attributes: {} } })).card
    ._rows[0].detail.hidden === false);

goneRow.forgetButton.click();
check('one tap only asks', goneEnv.calls.length === 0 && goneRow.forgetButton.textContent === 'Remove?',
  `${goneEnv.calls.length} call(s), label [${goneRow.forgetButton.textContent}]`);
check('and marks the button as asking', goneRow.forgetButton.classList.contains('confirm'));

// An online machine has nothing to remove, and a render that finds one running puts
// the question away rather than leaving it armed behind the row.
const armedThenBack = statusCard({ machines: [GONE], decisions: [] }, goneStates());
armedThenBack.card._rows[0].forgetButton.click();
armedThenBack.hass.states[GONE.online] = { state: 'on', attributes: {} };
armedThenBack.card.hass = armedThenBack.hass;
check('a machine that comes back disarms its own X',
  armedThenBack.card._rows[0].forget.hidden === true &&
  armedThenBack.card._rows[0].forgetButton.textContent === '');

// Awaited by the block at the end of this file, so its checks cannot race the
// summary that decides the exit code.
async function checkForgetRemoval() {
  await goneEnv.card._forget(goneRow);
  check('the second tap clears every topic the dashboard listed',
    goneEnv.calls.length === GONE.forget.length &&
    goneEnv.calls.every((c) => c.domain === 'mqtt' && c.service === 'publish'),
    JSON.stringify(goneEnv.calls.map((c) => `${c.domain}.${c.service}`)));
  check('each one emptied and retained, which is how a retained topic is withdrawn',
    goneEnv.calls.every((c) => c.data.payload === '' && c.data.retain === true),
    JSON.stringify(goneEnv.calls.map((c) => c.data)));
  check('and in the order the dashboard gave them',
    goneEnv.calls.map((c) => c.data.topic).join('|') === GONE.forget.join('|'));
  check('the row goes at once rather than waiting for the rebuild', goneRow.row.hidden === true);

  // Home Assistant can refuse - no MQTT integration, a token that may not publish -
  // and a row that vanished on a failed removal would be a lie.
  const failEnv = statusCard({ machines: [GONE], decisions: [] }, goneStates());
  failEnv.hass.callService = () => { throw new Error('no mqtt here'); };
  const failRow = failEnv.card._rows[0];
  failRow.forgetButton.click();
  await failEnv.card._forget(failRow);
  check('a removal that fails says so and leaves the row alone',
    failRow.row.hidden === false && failRow.forgetButton.textContent === 'Failed');
}

check('the element is registered under its own name',
  /customElements\.define\('agent-bridge-status-card'/.test(source));
check('and offered in the card picker',
  sandbox.window.customCards.some((c) => c.type === 'agent-bridge-status-card'));
check('"machines" is required', (() => {
  try { new AgentBridgeStatusCard().setConfig({}); return false; } catch (e) { return /machines/.test(e.message); }
})());

async function checkFrozenAfterSend() {
  // Home Assistant took the press, but the daemon sweeps on its own schedule. A row
  // changed in that window was read against the press already made, so the new value
  // reached the session without anyone pressing Send for it.
  const c = newCard(undefined, SUBMIT);
  const e = hassFor('Awaiting answer...', ['Awaiting answer...', 'Yes - reboot now', 'No - leave it', 'Cancel request']);
  e.card = c;
  c.hass = e.hass;
  rows(c)[0].click();
  await flush();
  e.calls.length = 0;
  buttons(c).find((b) => b.textContent === 'Send answer').click();
  await flush();
  check('an accepted Send presses the button once',
    e.calls.length === 1 && e.calls[0].domain === 'button', JSON.stringify(e.calls));
  check('and the rows are frozen afterwards, not left live until the daemon sweeps',
    c.shadowRoot.querySelector('.choices').classList.contains('sending'));
  check('and the card says the answer has gone', labels(c).includes('Sent - waiting for the session'),
    labels(c).join('|'));
  e.calls.length = 0;
  rows(c)[1].click();
  check('so changing a row after Send sends nothing', e.calls.length === 0, JSON.stringify(e.calls));
  buttons(c).find((b) => b.textContent === 'Send answer').click();
  check('and Send cannot be pressed a second time either', e.calls.length === 0, JSON.stringify(e.calls));

  // The daemon clearing the question is what ends it, and the card has to come back.
  c.hass = hassFor('Idle', ['Idle']).hass;
  const next = hassFor('Awaiting answer...', ['Awaiting answer...', 'Another question', 'Cancel request']);
  next.card = c;
  c.hass = next.hass;
  rows(c)[0].click();
  check('the question after it is answerable again',
    next.calls.length === 1 && next.calls[0].data.option === 'Another question', JSON.stringify(next.calls));
}

async function checkFrozenWhilePressInFlight() {
  // callService is a promise. Freezing only when it resolved left a window in which a
  // tap reached the selector before the daemon read it, so the daemon submitted the
  // changed value against a press made for the previous one - and the freeze then
  // arrived too late and locked in what had already been changed.
  const c = newCard(undefined, SUBMIT);
  const e = hassFor('Awaiting answer...', ['Awaiting answer...', 'Yes - reboot now', 'No - leave it', 'Cancel request']);
  e.card = c;
  c.hass = e.hass;
  rows(c)[0].click();
  await flush();
  e.calls.length = 0;
  buttons(c).find((b) => b.textContent === 'Send answer').click();
  // Deliberately not awaited: the press is dispatched and not yet acknowledged.
  rows(c)[1].click();
  check('a row tapped while the press is still in flight sets nothing',
    e.calls.filter((x) => x.domain === 'select').length === 0, JSON.stringify(e.calls));
  check('so the only thing sent is the press itself',
    e.calls.length === 1 && e.calls[0].domain === 'button', JSON.stringify(e.calls));
  await flush();
  check('and the rows are still frozen once it is acknowledged',
    c.shadowRoot.querySelector('.choices').classList.contains('sending'));
}

async function checkRefusedSendReleases() {
  // Nothing was sent, so the form has to come back - otherwise a refused press would
  // leave a question that can never be answered from the card again.
  const c = newCard(undefined, SUBMIT);
  const e = hassFor('Awaiting answer...', ['Awaiting answer...', 'Yes - reboot now', 'Cancel request'],
    { rejectButton: true });
  e.card = c;
  c.hass = e.hass;
  rows(c)[0].click();
  await flush();
  e.calls.length = 0;
  buttons(c).find((b) => b.textContent === 'Send answer').click();
  await flush();
  check('a press Home Assistant refuses says so', labels(c).some((l) => l.startsWith('Send failed:')),
    labels(c).join('|'));
  check('and unfreezes the rows, because nothing was sent',
    !c.shadowRoot.querySelector('.choices').classList.contains('sending'));
  e.calls.length = 0;
  rows(c)[1].click();
  check('so the answer can still be changed', e.calls.length === 1, JSON.stringify(e.calls));
}

async function checkIncompleteSendStaysLive() {
  // The daemon refuses an incomplete form and names the field it is waiting on, so
  // freezing one would leave no way to go and answer it.
  const c = newCard(['select.agent_bridge_abc_f1', 'select.agent_bridge_abc_f2'], SUBMIT);
  const calls = [];
  const states = {
    [DECISION]: {
      state: 'Awaiting answer...',
      attributes: { options: ['Awaiting answer...', 'Cancel request'], decision_id: 'd1', field_1_label: 'A', field_2_label: 'B' },
    },
    'select.agent_bridge_abc_f1': { state: 'Red', attributes: { options: ['Choose...', 'Red', 'Blue'] } },
    'select.agent_bridge_abc_f2': { state: 'Choose...', attributes: { options: ['Choose...', 'S', 'L'] } },
  };
  const hass = {
    states,
    callService: (domain, service, data) => {
      calls.push({ domain, service, data });
      if (domain === 'select' && states[data.entity_id]) {
        states[data.entity_id].state = data.option;
        c.hass = hass;
      }
      return Promise.resolve();
    },
  };
  c.hass = hass;
  buttons(c).find((b) => b.textContent === 'Send answer').click();
  await flush();
  check('an incomplete form still presses Send, because the daemon is what refuses it',
    calls.filter((x) => x.domain === 'button').length === 1, JSON.stringify(calls));
  check('but its rows stay live, so the missing field can still be answered',
    !c.shadowRoot.querySelector('.choices').classList.contains('sending'));
  calls.length = 0;
  buttons(c).find((b) => b.textContent === 'L').click();
  check('and answering it really does set the slot', calls.length === 1 && calls[0].data.option === 'L',
    JSON.stringify(calls));
}

// _launch awaits its service calls, so the checks that read them have to await it too.
(async () => {
  await checkForgetRemoval();
  await checkTapThenSend();
  await checkUnconfirmedTap();
  await checkRefusedSelection();
  await checkFrozenAfterSend();
  await checkFrozenWhilePressInFlight();
  await checkRefusedSendReleases();
  await checkIncompleteSendStaysLive();

  const pubEnv = launchEnv({});
  const pubCard = promptCard(pubEnv, { promptTopic: PROMPT_TOPIC });
  pubCard.shadowRoot.querySelector('textarea[data-key="prompt"]').value = LONG_PROMPT;
  pubEnv.calls.length = 0;
  await pubCard._launch();

  const published = pubEnv.calls.find((c) => c.domain === 'mqtt' && c.service === 'publish');
  check('Launch publishes the prompt over MQTT', !!published,
    JSON.stringify(pubEnv.calls.map((c) => `${c.domain}.${c.service}`)));
  check('to the topic the bridge named', !!published && published.data.topic === PROMPT_TOPIC);
  check('carrying the prompt whole, not cut to 255 characters', (() => {
    if (!published) { return false; }
    const body = JSON.parse(published.data.payload);
    return body.text === LONG_PROMPT.trim() && body.text.length > 255;
  })(), published ? `${JSON.parse(published.data.payload).text.length} chars` : 'nothing published');
  check('retained, so the daemon still finds it when it reads the press',
    !!published && published.data.retain === true);
  check('and the capped text entity is not written at all',
    !pubEnv.calls.some((c) => c.domain === 'text'));
  check('the button is still pressed',
    pubEnv.calls.some((c) => c.domain === 'button' && c.service === 'press'));
  check('the box is emptied once it has been sent',
    pubCard.shadowRoot.querySelector('textarea[data-key="prompt"]').value === '');

  const oldEnv = launchEnv({});
  const oldCard = promptCard(oldEnv, {});
  oldCard.shadowRoot.querySelector('textarea[data-key="prompt"]').value = 'short one';
  oldEnv.calls.length = 0;
  await oldCard._launch();
  check('a bridge with no topic still gets the text entity, so nothing regresses',
    oldEnv.calls.some((c) => c.domain === 'text' && c.service === 'set_value' && c.data.value === 'short one'),
    JSON.stringify(oldEnv.calls));
  check('and no MQTT publish is attempted', !oldEnv.calls.some((c) => c.domain === 'mqtt'));

  // --- attaching an image, and being told when it could not be attached -----------
  //
  // An image is the one thing on this card that cannot go over the websocket. A reply
  // is published through hass.callService, which rides the page's connection and
  // stays authenticated for as long as the tab is open; an image has to be POSTed to
  // /api/image/upload over plain HTTP, which does not. So when Home Assistant starts
  // refusing HTTP - a lapsed sign-in, or an ip_bans entry matching whatever address a
  // reverse proxy reports the browser as - replies carry on working and images stop,
  // which is a hard thing to guess at from a status line reading "403 Forbidden".
  // Worse, a refused token renewal rejects with the bare number 2 and read simply
  // "Upload failed: 2".
  console.log('');
  console.log('--- attaching an image ---');

  const replyLoad = require('./card-harness').loadCards();
  const { AgentBridgeReplyCard } = replyLoad;
  const PNG = { name: 'shot.png', type: 'image/png' };
  const ERR_INVALID_AUTH = 2;

  // `auth` is what Home Assistant hands a card; `over` decides what each route does.
  function replyCard({ viaHass, direct, refresh }) {
    const card = new AgentBridgeReplyCard();
    card.setConfig({ topic: 'copilot/cli/session/abc/replypayload' });
    const tried = [];
    const published = [];
    replyLoad.sandbox.fetch = async () => { tried.push('direct'); return direct(); };
    card.hass = {
      auth: {
        accessToken: 'tok',
        expired: false,
        refreshAccessToken: async () => {
          tried.push('refresh');
          if (refresh) { return refresh(); }
          return undefined;
        },
      },
      fetchWithAuth: async () => { tried.push('hass'); return viaHass(); },
      callService: async (domain, service, data) => { published.push({ domain, service, data }); },
    };
    return { card, tried, published, status: () => card._els.status.textContent };
  }

  const ok = () => ({ ok: true, status: 200, json: async () => ({ id: 'img1', name: 'shot.png', content_type: 'image/png' }) });
  const refused = (status, statusText) => ({ ok: false, status, statusText, json: async () => ({}) });

  // The failure that was actually reported: the tab's token was due for renewal,
  // Home Assistant turned the renewal down, and the card gave up without ever trying
  // the token it was already holding - which the live websocket proved was fine.
  let r = replyCard({
    viaHass: () => { throw ERR_INVALID_AUTH; },
    direct: ok,
  });
  await r.card._ingest([PNG]);
  check('a refused token renewal no longer abandons the upload',
    r.tried.includes('direct'), r.tried.join(','));
  check('so the image is attached anyway, on the token already in hand',
    r.card._images.length === 1 && r.card._images[0].id === 'img1');
  check('and nothing is reported as gone wrong', r.status() === '', r.status());

  r = replyCard({ viaHass: () => refused(403, 'Forbidden'), direct: () => refused(403, 'Forbidden') });
  await r.card._ingest([PNG]);
  check('a blocked browser is told it was blocked, not shown a status line',
    /refused this browser \(403\)/.test(r.status()) && !/Forbidden/.test(r.status()), r.status());
  check('and told why replies still work when images do not',
    /websocket/.test(r.status()), r.status());
  check('nothing is attached when the upload was refused', r.card._images.length === 0);

  r = replyCard({
    viaHass: () => refused(401, 'Unauthorized'),
    direct: () => refused(401, 'Unauthorized'),
    refresh: () => { throw ERR_INVALID_AUTH; },
  });
  await r.card._ingest([PNG]);
  check('a lapsed sign-in says to reload the page', /reload/.test(r.status()), r.status());
  check('and a thrown ERR_INVALID_AUTH never surfaces as the bare number it is',
    !/:\s*2$/.test(r.status()), r.status());
  check('a refused renewal still lets the attempt finish rather than throwing',
    r.tried.filter((t) => t === 'direct').length >= 1, r.tried.join(','));

  r = replyCard({ viaHass: () => refused(413, 'Payload Too Large'), direct: () => refused(413, 'Payload Too Large') });
  await r.card._ingest([PNG]);
  check('an image Home Assistant will not take says so in words', /larger than/.test(r.status()), r.status());

  r = replyCard({ viaHass: () => refused(500, 'Internal Server Error'), direct: () => refused(500, 'Internal Server Error') });
  await r.card._ingest([PNG]);
  check('and any other refusal still names what came back',
    /500 Internal Server Error/.test(r.status()), r.status());

  // --- attaching something that is not an image -----------------------------------
  //
  // A document cannot travel the way an image does: /api/image/upload runs whatever
  // it is handed through an image decoder and answers 400 for a .md, a .log or a
  // .csv, so there is no id to put in the payload. Until this, the picker did not
  // offer them and _ingest dropped them without a word - the file had to go via
  // cloud storage and come back on the desktop's filesystem instead. They now ride
  // inside the payload itself, which is already published over MQTT with no length
  // cap, and the daemon writes them out next to the downloaded images.
  console.log('');
  console.log('--- attaching a file that is not an image ---');

  const doc = (name, text, type) => ({
    name,
    type: type === undefined ? 'text/markdown' : type,
    size: Buffer.byteLength(text, 'utf8'),
    arrayBuffer: async () => Buffer.from(text, 'utf8'),
  });
  const sentFiles = (published) => (published[0] && published[0].data
    ? JSON.parse(published[0].data.payload).files
    : []);

  r = replyCard({ viaHass: ok, direct: ok });
  await r.card._ingest([doc('notes.md', '# hello')]);
  check('a document is never sent to the image endpoint',
    r.tried.length === 0 && r.card._images.length === 0, r.tried.join(','));
  check('it is carried in the payload as base64 instead',
    r.card._files.length === 1
      && r.card._files[0].name === 'notes.md'
      && Buffer.from(r.card._files[0].b64, 'base64').toString('utf8') === '# hello',
    JSON.stringify(r.card._files));
  check('and nothing is reported as gone wrong', r.status() === '', r.status());
  check('a file on its own is enough to enable Send', r.card._els.send.disabled === false);

  await r.card._send();
  check('the published reply carries the file', sentFiles(r.published).length === 1,
    JSON.stringify(r.published));
  check('with its bytes intact after the round trip through JSON',
    Buffer.from(sentFiles(r.published)[0].b64, 'base64').toString('utf8') === '# hello');
  check('and the card is emptied, so the next reply does not resend it',
    r.card._files.length === 0 && r.card._els.textarea.value === '');

  // Both routes at once, because they are chosen per file rather than per send.
  r = replyCard({ viaHass: ok, direct: ok });
  await r.card._ingest([PNG, doc('notes.md', 'hi')]);
  check('an image and a document in one attach each take their own route',
    r.card._images.length === 1 && r.card._files.length === 1,
    `${r.card._images.length} image(s), ${r.card._files.length} file(s)`);

  // Unlike an uploaded image, an inline file sits in a Home Assistant state
  // attribute, so it has a ceiling - and being told about it beats a reply that
  // looks sent and never arrives.
  r = replyCard({ viaHass: ok, direct: ok });
  await r.card._ingest([doc('huge.log', 'x'.repeat(256 * 1024 + 1))]);
  check('a file over the limit says so in words', /over the 256 KB limit/.test(r.status()), r.status());
  check('and is not attached', r.card._files.length === 0);

  // size is metadata. A file that grew after being picked reports the old length,
  // which is why the length that decides is the one measured after the read.
  r = replyCard({ viaHass: ok, direct: ok });
  await r.card._ingest([{
    name: 'liar.md', type: 'text/markdown', size: 10,
    arrayBuffer: async () => Buffer.alloc(256 * 1024 + 1, 0x61),
  }]);
  check('a file that under-reports its size is still caught, after the read',
    /over the/.test(r.status()), r.status());
  check('and it is not attached either', r.card._files.length === 0);

  r = replyCard({ viaHass: ok, direct: ok });
  await r.card._ingest([doc('empty.md', '')]);
  check('an empty file is refused rather than attached as nothing',
    r.card._files.length === 0 && /empty/.test(r.status()), r.status());

  check('the file picker no longer limits itself to images',
    !/accept="image\/\*"/.test(source) && /<input type="file" multiple/.test(source));

  check('the element is registered under its own name',
    /customElements\.define\('agent-bridge-reply-card'/.test(source));
  check('"topic" is required', (() => {
    try { new AgentBridgeReplyCard().setConfig({}); return false; } catch (e) { return /topic/.test(e.message); }
  })());

  await checkDeferredChoices();

  console.log('');
  if (failures) {
    console.log(`${failures} check(s) failed`);
    process.exit(1);
  }
  console.log('All card checks passed');
})();
