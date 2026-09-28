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

const fs = require('fs');
const path = require('path');
const vm = require('vm');

let failures = 0;
function check(name, condition, detail) {
  if (condition) { console.log(`  PASS  ${name}`); return; }
  failures++;
  console.log(`  FAIL  ${name}${detail ? ` - ${detail}` : ''}`);
}

// --- a DOM small enough to run a card, and no smaller -----------------------------

class FakeClassList {
  constructor() { this._set = new Set(); }
  add(c) { this._set.add(c); }
  remove(c) { this._set.delete(c); }
  contains(c) { return this._set.has(c); }
  toggle(c, force) {
    const on = force === undefined ? !this._set.has(c) : !!force;
    if (on) { this.add(c); } else { this.remove(c); }
  }
}

class FakeElement {
  constructor(tag) {
    this.tagName = String(tag).toUpperCase();
    this.children = [];
    this.classList = new FakeClassList();
    this.style = {};
    this.hidden = false;
    this._text = '';
    this._listeners = {};
  }
  set textContent(value) {
    this._text = String(value);
    // Assigning '' is how a card empties a container before refilling it.
    if (this._text === '') { this.children = []; }
  }
  get textContent() { return this._text; }
  appendChild(child) { this.children.push(child); return child; }
  addEventListener(type, fn) { (this._listeners[type] = this._listeners[type] || []).push(fn); }
  click() { for (const fn of this._listeners.click || []) { fn(); } }
  querySelector(sel) { return (this._slots && this._slots[sel]) || null; }
}

// The choices card builds itself by assigning innerHTML, then looks its parts up.
// The stand-in hands back the same objects for those two selectors.
function makeShadow() {
  const root = new FakeElement('shadow');
  root._slots = { '.choices': new FakeElement('div'), 'ha-card': new FakeElement('ha-card') };
  Object.defineProperty(root, 'innerHTML', { set() {}, get() { return ''; } });
  return root;
}

const sandbox = {
  console: { info() {}, log() {} },
  window: { customCards: [] },
  document: { createElement: (tag) => new FakeElement(tag) },
  customElements: { get: () => undefined, define: () => {}, whenDefined: () => new Promise(() => {}) },
  HTMLElement: class {
    constructor() { this.hidden = false; }
    attachShadow() { this.shadowRoot = makeShadow(); return this.shadowRoot; }
    dispatchEvent() { return true; }
  },
  CustomEvent: class { constructor(type, init) { this.type = type; Object.assign(this, init); } },
  localStorage: { getItem: () => null, setItem: () => {} },
};
sandbox.globalThis = sandbox;

const sourcePath = path.join(__dirname, '..', 'agent-bridge-reply-card.js');
const source = fs.readFileSync(sourcePath, 'utf8');
const context = vm.createContext(sandbox);
// A classic script, so a trailing expression is what exposes its classes for testing.
vm.runInContext(`${source}\n;globalThis.__cards = { AgentBridgeChoicesCard, CARD_VERSION };`, context, { filename: sourcePath });
const { AgentBridgeChoicesCard, CARD_VERSION } = sandbox.__cards;

// --- the harness ------------------------------------------------------------------

const DECISION = 'select.agent_bridge_abc_decision';

function newCard() {
  const card = new AgentBridgeChoicesCard();
  card.setConfig({ decision: DECISION });
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

console.log('--- it is wired up ---');
check('the element is registered under its own name',
  /customElements\.define\('agent-bridge-choices-card'/.test(source));
check('and offered in the card picker',
  sandbox.window.customCards.some((c) => c.type === 'agent-bridge-choices-card'));
check('the card version is the one the dashboard gates the card on', CARD_VERSION === '1.13.0', CARD_VERSION);
check('"decision" is required', (() => {
  try { new AgentBridgeChoicesCard().setConfig({}); return false; } catch (e) { return /decision/.test(e.message); }
})());

console.log('');
if (failures) {
  console.log(`${failures} check(s) failed`);
  process.exit(1);
}
console.log('All card checks passed');
