/*
 * A DOM small enough to run the dashboard cards under plain node, and no smaller.
 *
 * Shared so that the card's own tests (test-cards.js) and the end-to-end wiring test
 * (drive-choices-card.js, driven from tests/test-choices-form.ps1) run the very same
 * card code. The point of the second is that the card is fed a config the PowerShell
 * view really generated, rather than one written out by hand next to the card - which
 * is how a card and the view that builds it stayed broken through the middle while
 * both ends passed.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

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
    this.dataset = {};
    this.attributes = {};
    this.parentElement = null;
    this._text = '';
    this._listeners = {};
  }
  set textContent(value) {
    this._text = String(value);
    // Assigning '' is how a card empties a container before refilling it.
    if (this._text === '') { this.children = []; }
  }
  get textContent() { return this._text; }
  appendChild(child) { child.parentElement = this; this.children.push(child); return child; }
  addEventListener(type, fn) { (this._listeners[type] = this._listeners[type] || []).push(fn); }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attributes, name) ? this.attributes[name] : null; }
  click() { for (const fn of this._listeners.click || []) { fn(); } }
  dispatch(type, event) { for (const fn of this._listeners[type] || []) { fn(event || {}); } }
  querySelector(sel) { return (this._slots && this._slots[sel]) || null; }
}

// The launch card's parts, as its innerHTML would create them. Seeded rather than
// invented on demand, so a selector the card looks for and the harness does not model
// still comes back null and fails loudly, the way it did before the card grew.
function seedLaunchParts(slots) {
  const head = new FakeElement('div');
  for (const sel of ['.toggle', '.name', '.summary', 'button.launch', '.fields', '.note', '.note .spin', '.note .text']) {
    slots[sel] = new FakeElement(sel === 'button.launch' ? 'button' : 'div');
  }
  slots['.toggle'].parentElement = head;
  slots['textarea[data-key="prompt"]'] = new FakeElement('textarea');
  slots['textarea[data-key="prompt"]'].value = '';
  // One select and one label per field, keyed exactly as the card asks for them.
  const selects = [];
  for (const key of ['machine', 'resume', 'agent', 'workspace', 'profile', 'model', 'effort', 'context', 'permissions']) {
    const select = new FakeElement('select');
    select.dataset.key = key;
    select.value = '';
    slots[`select[data-key="${key}"]`] = select;
    slots[`.f-${key}`] = new FakeElement('label');
    selects.push(select);
  }
  return selects;
}

// The choices card builds itself by assigning innerHTML, then looks its parts up.
// The stand-in hands back the same objects for those two selectors.
function makeShadow() {
  const root = new FakeElement('shadow');
  root._slots = { '.choices': new FakeElement('div'), 'ha-card': new FakeElement('ha-card') };
  const selects = seedLaunchParts(root._slots);
  root.querySelectorAll = (sel) => (sel === 'select' ? selects.slice() : []);
  Object.defineProperty(root, 'innerHTML', { set() {}, get() { return ''; } });
  return root;
}

/*
 * Loads the real card file into a sandbox and hands back its classes. A classic
 * script, so a trailing expression is what exposes them.
 */
function loadCards() {
  const sandboxTimers = [];
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
    // The launch card arms a timer while a press is in flight. Recorded rather than
    // run: a real timer would keep the test process alive for its full delay, and
    // nothing here needs it to fire.
    setTimeout: (fn, ms) => { sandboxTimers.push({ fn, ms }); return sandboxTimers.length; },
    clearTimeout: (id) => { if (id) { sandboxTimers[id - 1] = null; } },
  };
  sandbox.globalThis = sandbox;

  const sourcePath = path.join(__dirname, '..', 'agent-bridge-reply-card.js');
  const source = fs.readFileSync(sourcePath, 'utf8');
  const context = vm.createContext(sandbox);
  vm.runInContext(
    `${source}\n;globalThis.__cards = { AgentBridgeChoicesCard, AgentBridgeSessionCard, AgentBridgeLaunchCard, CARD_VERSION };`,
    context,
    { filename: sourcePath });
  return Object.assign({ sandbox, source }, sandbox.__cards);
}

module.exports = { FakeClassList, FakeElement, makeShadow, loadCards };
