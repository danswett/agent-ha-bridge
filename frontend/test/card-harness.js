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
  // Markup replaces whatever was in the element. The cards use this to build once and
  // to empty a container before refilling it, and the second is the one that matters:
  // without it a re-render appended to the old children instead of replacing them.
  set innerHTML(value) {
    this._html = String(value);
    this.children = [];
  }
  get innerHTML() { return this._html || ''; }
  // A card writes `el.className = 'row'` and later reads `el.classList`; in a browser
  // those are two views of one thing, so they are here too. Without this a class set
  // at build time was invisible to every classList check.
  set className(value) {
    this.classList = new FakeClassList();
    for (const name of String(value).split(/\s+/).filter(Boolean)) { this.classList.add(name); }
  }
  get className() { return Array.from(this.classList._set).join(' '); }
  appendChild(child) { child.parentElement = this; this.children.push(child); return child; }
  // `append` takes strings as well as nodes, which is how the activity card writes its
  // status line - a machine, a literal, then the status in bold. Without it that line
  // could not be rendered here at all, so nothing could check what it says.
  append(...nodes) {
    for (const node of nodes) {
      if (typeof node === 'string') { this._text += node; }
      else { this.appendChild(node); this._text += node.textContent; }
    }
  }
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

// The status card's parts, seeded for the same reason as the launch card's.
function seedStatusParts(slots) {
  for (const sel of ['.toggle', '.name', '.summary', '.machines']) {
    if (!slots[sel]) { slots[sel] = new FakeElement('div'); }
  }
}

// The usage card shares the status card's folding head and adds its own body.
function seedUsageParts(slots) {
  if (!slots['.groups']) { slots['.groups'] = new FakeElement('div'); }
}

// The reply card builds an <ha-card>, fills it with markup and then looks its parts
// up inside it. Seeded for the same reason as the launch card's: a selector the card
// asks for and the harness does not model comes back null and fails loudly.
function seedReplyParts(card) {
  const slots = {};
  for (const [sel, tag] of [
    ['textarea', 'textarea'], ['button.attach', 'button'], ['button.send', 'button'],
    ['.chips', 'div'], ['.status', 'div'], ['input[type=file]', 'input'],
  ]) {
    slots[sel] = new FakeElement(tag);
  }
  slots.textarea.value = '';
  card._slots = slots;
  return card;
}

// The choices card builds itself by assigning innerHTML, then looks its parts up.
// The stand-in hands back the same objects for those two selectors.
function makeShadow() {
  const root = new FakeElement('shadow');
  root._slots = { '.choices': new FakeElement('div'), 'ha-card': new FakeElement('ha-card') };
  const selects = seedLaunchParts(root._slots);
  seedStatusParts(root._slots);
  seedUsageParts(root._slots);
  root.querySelectorAll = (sel) => (sel === 'select' ? selects.slice() : []);
  Object.defineProperty(root, 'innerHTML', { set() {}, get() { return ''; } });
  return root;
}

/*
 * Loads the real card file into a sandbox and hands back its classes. A classic
 * script, so a trailing expression is what exposes them.
 */
function loadCards(sourceFile) {
  const sandboxTimers = [];
  const sandboxIntervals = new Map();
  let intervalId = 0;
  const sandbox = {
    console: { info() {}, log() {} },
    window: { customCards: [] },
    // The elapsed-time spinner is a real timer against a real visibility state. Both
    // are controllable here, because the bug they guard against - a hidden tab whose
    // interval keeps firing and doing nothing - is invisible to a source-text check.
    document: {
      hidden: false,
      _listeners: {},
      addEventListener(type, fn) { (this._listeners[type] = this._listeners[type] || []).push(fn); },
      removeEventListener(type, fn) {
        const l = this._listeners[type] || [];
        const i = l.indexOf(fn);
        if (i >= 0) { l.splice(i, 1); }
      },
      _fire(type) { for (const fn of (this._listeners[type] || []).slice()) { fn(); } },
      createElement: (tag) => (String(tag).toLowerCase() === 'ha-card'
        ? seedReplyParts(new FakeElement(tag))
        : new FakeElement(tag)),
    },
    customElements: { get: () => undefined, define: () => {}, whenDefined: () => new Promise(() => {}) },
    HTMLElement: class {
      constructor() { this.hidden = false; }
      attachShadow() { this.shadowRoot = makeShadow(); return this.shadowRoot; }
      dispatchEvent() { return true; }
    },
    CustomEvent: class { constructor(type, init) { this.type = type; Object.assign(this, init); } },
    localStorage: { getItem: () => null, setItem: () => {} },
    // What the reply card needs to upload an image. `fetch` is deliberately a
    // failing stub: a test that means to exercise the direct-token path replaces it
    // on the returned sandbox, and one that does not should hear about the attempt.
    FormData: class {
      constructor() { this.parts = []; }
      append(name, value, filename) { this.parts.push({ name, value, filename }); }
    },
    URL: { createObjectURL: () => 'blob:stub' },
    // Non-image attachments are base64'd into the payload rather than uploaded,
    // because /api/image/upload refuses anything that is not an image.
    btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
    Uint8Array,
    fetch: async () => { throw new Error('fetch was not stubbed'); },
    // The launch card arms a timer while a press is in flight. Recorded rather than
    // run: a real timer would keep the test process alive for its full delay, and
    // nothing here needs it to fire.
    setTimeout: (fn, ms) => { sandboxTimers.push({ fn, ms }); return sandboxTimers.length; },
    clearTimeout: (id) => { if (id) { sandboxTimers[id - 1] = null; } },
    // Recorded, not run, for the same reason as setTimeout. `intervals` is what a test
    // counts to see whether a timer is actually running. Closures rather than `this`,
    // because the card calls these as bare globals.
    intervals: sandboxIntervals,
    setInterval: (fn, ms) => { sandboxIntervals.set(++intervalId, { fn, ms }); return intervalId; },
    clearInterval: (id) => { sandboxIntervals.delete(id); },
  };
  sandbox.globalThis = sandbox;

  // Normally the card in the tree. A path may be given instead to run a *released*
  // card against today's bridge, which is the only way to show that an older one
  // still works rather than asserting that it does.
  const sourcePath = sourceFile || path.join(__dirname, '..', 'agent-bridge-reply-card.js');
  const source = fs.readFileSync(sourcePath, 'utf8');
  const context = vm.createContext(sandbox);
  vm.runInContext(
    `${source}\n;globalThis.__cards = { AgentBridgeReplyCard, AgentBridgeChoicesCard, AgentBridgeSessionCard, AgentBridgeLaunchCard, AgentBridgeStatusCard, AgentBridgeActivityCard, AgentBridgeUsageCard, CARD_VERSION };`,
    context,
    { filename: sourcePath });
  return Object.assign({ sandbox, source }, sandbox.__cards);
}

module.exports = { FakeClassList, FakeElement, makeShadow, seedReplyParts, loadCards };
