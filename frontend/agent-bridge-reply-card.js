/*
 * agent-bridge-reply-card
 *
 * The reply box for a bridged coding-agent session.
 *
 * It exists because Home Assistant's own `text` entity cannot do this job:
 *   - a text entity only commits on blur or Enter, so tapping a separate Send
 *     button sent whatever was in the box *before* you typed - the reason Send
 *     used to need pressing twice;
 *   - entity state is capped at 255 characters, so longer replies were impossible;
 *   - there is no way to put an image into an entity state at all.
 *
 * This card owns its own Send button, so it reads the live textarea value, and it
 * publishes over MQTT rather than writing an entity state, which removes the
 * length cap. Images are uploaded to Home Assistant and referenced by id; the
 * daemon downloads them and attaches them to the prompt.
 */

const CARD_VERSION = '1.14.0';

// The working line, in the style of Claude Code's own spinner: its glyph cycle, and a
// word picked once per turn. Claude Code does not record which word it chose, so the
// card picks its own from the same kind of list.
// Each followed by U+FE0E, which asks for the plain character: without it iOS draws ✳
// (U+2733) as an emoji - a green square - and the spinner flashed green once a cycle.
const SPINNER_GLYPHS = ['·', '✢', '✳', '✶', '✻', '✽', '✻', '✶', '✳', '✢'].map((g) => `${g}︎`);
const SPINNER_VERBS = [
  'Thinking', 'Pondering', 'Slithering', 'Brewing', 'Conjuring', 'Noodling', 'Percolating',
  'Mulling', 'Cogitating', 'Simmering', 'Ruminating', 'Tinkering', 'Churning', 'Musing',
  'Crafting', 'Forging', 'Marinating', 'Synthesizing', 'Deliberating', 'Puttering',
];

class AgentBridgeReplyCard extends HTMLElement {
  constructor() {
    super();
    this.attachShadow({ mode: 'open' });
    this._built = false;
    this._images = [];
    this._busy = false;
    this._statusTimer = null;
  }

  setConfig(config) {
    if (!config || !config.topic) {
      throw new Error('agent-bridge-reply-card: "topic" is required');
    }
    this._config = Object.assign({ name: 'Reply', placeholder: 'Type a reply...' }, config);
    if (this._built) {
      this._applyConfig();
    }
  }

  set hass(hass) {
    this._hass = hass;
    if (!this._built) {
      this._build();
    }
    // Deliberately nothing else. Re-rendering on every state update would wipe
    // whatever is half-typed in the textarea, which is exactly the failure this
    // card is meant to remove.
  }

  getCardSize() {
    return 3;
  }

  _build() {
    this._built = true;
    const style = document.createElement('style');
    style.textContent = `
      ha-card { padding: 12px; }
      /* stretch, not flex-end: the buttons are pinned to the bottom of their own
         full-height column rather than aligned against the textarea's box directly.
         Aligning them against the textarea meant trusting how its box resolves in
         the flex line, which left them sitting a few pixels high. */
      .row { display: flex; align-items: stretch; gap: 8px; }
      .actions { display: flex; align-items: flex-end; gap: 8px; flex: 0 0 auto; }
      textarea {
        flex: 1 1 auto;
        /* Block, not the default inline-block: an inline textarea sits on the text
           baseline and reserves a few pixels of descender space below itself. */
        display: block;
        vertical-align: bottom;
        min-height: 44px;
        max-height: 40vh;
        resize: vertical;
        padding: 10px;
        border-radius: 10px;
        border: 1px solid var(--divider-color, #444);
        background: var(--card-background-color, #1c1c1c);
        color: var(--primary-text-color, #fff);
        font-family: inherit;
        font-size: 15px;
        line-height: 1.35;
        box-sizing: border-box;
      }
      textarea:focus { outline: none; border-color: var(--primary-color, #03a9f4); }
      button {
        /* Fixed height on both, so the pair match each other and the textarea's
           bottom edge. Left to their content they differ, because an icon and a
           word do not produce the same line box. */
        height: 44px;
        box-sizing: border-box;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        border: none;
        border-radius: 10px;
        padding: 0 16px;
        cursor: pointer;
        color: var(--text-primary-color, #fff);
        background: var(--primary-color, #03a9f4);
        font-size: 14px;
        font-weight: 600;
      }
      button.ghost {
        background: transparent;
        color: var(--secondary-text-color, #aaa);
        border: 1px solid var(--divider-color, #444);
        font-weight: 500;
      }
      button.attach { width: 44px; padding: 0; flex: 0 0 auto; }
      button.attach ha-icon { --mdc-icon-size: 20px; display: flex; }
      button:disabled { opacity: 0.45; cursor: default; }
      .chips { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 8px; }
      .chip {
        display: flex; align-items: center; gap: 6px;
        background: var(--secondary-background-color, #2b2b2b);
        border-radius: 14px; padding: 3px 6px 3px 3px; font-size: 12px;
        color: var(--primary-text-color, #fff);
      }
      .chip img { width: 28px; height: 28px; object-fit: cover; border-radius: 11px; display: block; background: var(--divider-color, #444); }
      .chip .x { cursor: pointer; opacity: 0.6; padding: 0 3px; }
      .chip .x:hover { opacity: 1; }
      .status { margin-top: 8px; font-size: 12px; min-height: 1em; }
      .status.err { color: var(--error-color, #ff5252); }
      .status.ok { color: var(--success-color, #4caf50); }
      .status.busy { color: var(--secondary-text-color, #aaa); }
      .hint { margin-top: 6px; font-size: 11px; color: var(--secondary-text-color, #888); }
      input[type=file] { display: none; }
    `;

    const card = document.createElement('ha-card');
    card.innerHTML = `
      <div class="row">
        <textarea part="input"></textarea>
        <div class="actions">
          <button class="ghost attach" title="Attach an image"><ha-icon icon="mdi:paperclip"></ha-icon></button>
          <button class="send">Send</button>
        </div>
      </div>
      <div class="chips"></div>
      <div class="status"></div>
      <div class="hint">Paste or attach an image to send it with your reply.</div>
      <input type="file" accept="image/*" multiple />
    `;

    this.shadowRoot.appendChild(style);
    this.shadowRoot.appendChild(card);

    this._els = {
      card,
      textarea: card.querySelector('textarea'),
      attach: card.querySelector('button.attach'),
      send: card.querySelector('button.send'),
      chips: card.querySelector('.chips'),
      status: card.querySelector('.status'),
      file: card.querySelector('input[type=file]'),
    };

    this._els.send.addEventListener('click', () => this._send());
    this._els.attach.addEventListener('click', () => this._els.file.click());
    this._els.file.addEventListener('change', (e) => {
      this._ingest(Array.from(e.target.files || []));
      e.target.value = '';
    });
    this._els.textarea.addEventListener('paste', (e) => this._onPaste(e));
    this._els.textarea.addEventListener('input', () => this._syncSendState());
    this._els.textarea.addEventListener('keydown', (e) => {
      // Ctrl/Cmd+Enter sends, matching the muscle memory of most chat boxes.
      // A bare Enter must stay a newline so multi-line replies are possible.
      if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
        e.preventDefault();
        this._send();
      }
    });

    this._applyConfig();
    this._syncSendState();
  }

  _applyConfig() {
    if (!this._els) { return; }
    this._els.textarea.placeholder = this._config.placeholder;
    if (this._config.name) {
      this._els.card.setAttribute('header', this._config.name);
    }
  }

  _onPaste(event) {
    const items = (event.clipboardData && event.clipboardData.items) || [];
    const files = [];
    for (const item of items) {
      if (item.kind === 'file' && item.type && item.type.startsWith('image/')) {
        const file = item.getAsFile();
        if (file) { files.push(file); }
      }
    }
    if (files.length) {
      // Only swallow the paste when it carried an image; a plain text paste must
      // still land in the textarea normally.
      event.preventDefault();
      this._ingest(files);
    }
  }

  async _ingest(files) {
    const images = files.filter((f) => f.type && f.type.startsWith('image/'));
    if (!images.length) { return; }

    this._busy = true;
    this._syncSendState();
    for (const file of images) {
      this._setStatus(`Uploading ${file.name || 'image'}...`, 'busy');
      try {
        const uploaded = await this._upload(file);
        this._images.push(uploaded);
        this._renderChips();
        this._setStatus('', '');
      } catch (err) {
        this._setStatus(`Upload failed: ${err.message || err}`, 'err');
      }
    }
    this._busy = false;
    this._syncSendState();
  }

  async _upload(file) {
    const form = new FormData();
    form.append('file', file, file.name || 'pasted.png');

    const resp = await this._authFetch('/api/image/upload', { method: 'POST', body: form });
    if (!resp.ok) {
      throw new Error(`${resp.status} ${resp.statusText}`);
    }
    const body = await resp.json();
    if (!body || !body.id) { throw new Error('no image id returned'); }
    return {
      id: body.id,
      name: body.name || file.name || 'image.png',
      content_type: body.content_type || file.type || 'image/png',
    };
  }

  _accessToken() {
    const auth = this._hass && this._hass.auth;
    if (!auth) { return null; }
    if (auth.data && auth.data.access_token) { return auth.data.access_token; }
    return auth.accessToken || null;
  }

  // An authenticated request to Home Assistant. Access tokens live 30 minutes, and
  // a browser tab left open keeps its websocket but never refreshes the token until
  // something asks - so reading hass.auth's token directly sent an expired one and
  // got a 401. hass.fetchWithAuth refreshes first; without it, refresh when expired,
  // and once more on a 401.
  async _authFetch(path, init = {}) {
    const hass = this._hass;
    if (hass && typeof hass.fetchWithAuth === 'function') {
      const resp = await hass.fetchWithAuth(path, init);
      if (resp.status !== 401) { return resp; }
    }
    const auth = hass && hass.auth;
    if (!auth) { throw new Error('no access token'); }
    const send = () => fetch(path, {
      ...init,
      headers: { ...(init.headers || {}), authorization: `Bearer ${this._accessToken()}` },
    });
    if (auth.expired && typeof auth.refreshAccessToken === 'function') { await auth.refreshAccessToken(); }
    let resp = await send();
    if (resp.status === 401 && typeof auth.refreshAccessToken === 'function') {
      await auth.refreshAccessToken();
      resp = await send();
    }
    return resp;
  }

  _renderChips() {
    this._els.chips.innerHTML = '';
    this._images.forEach((img, index) => {
      const chip = document.createElement('div');
      chip.className = 'chip';

      const thumb = document.createElement('img');
      thumb.alt = img.name;
      // The serve endpoint needs auth, so the thumbnail is fetched as a blob
      // rather than pointed at directly with a plain src.
      this._authFetch(`/api/image/serve/${img.id}/256x256`)
        .then((r) => (r.ok ? r.blob() : null))
        .then((b) => { if (b) { thumb.src = URL.createObjectURL(b); } })
        .catch(() => {});

      const label = document.createElement('span');
      label.textContent = img.name.length > 18 ? `${img.name.slice(0, 15)}...` : img.name;

      const remove = document.createElement('span');
      remove.className = 'x';
      remove.textContent = '\u2715';
      remove.title = 'Remove';
      remove.addEventListener('click', () => {
        this._images.splice(index, 1);
        this._renderChips();
        this._syncSendState();
      });

      chip.appendChild(thumb);
      chip.appendChild(label);
      chip.appendChild(remove);
      this._els.chips.appendChild(chip);
    });
  }

  _syncSendState() {
    if (!this._els) { return; }
    const hasText = this._els.textarea.value.trim().length > 0;
    this._els.send.disabled = this._busy || (!hasText && this._images.length === 0);
  }

  _setStatus(text, kind) {
    this._els.status.textContent = text;
    this._els.status.className = `status ${kind || ''}`;
    if (this._statusTimer) { clearTimeout(this._statusTimer); this._statusTimer = null; }
    if (kind === 'ok') {
      this._statusTimer = setTimeout(() => this._setStatus('', ''), 4000);
    }
  }

  async _send() {
    if (this._busy) { return; }
    // Read straight from the element. This is the whole point of the card: the
    // value cannot be stale because nothing had to commit it first.
    const text = this._els.textarea.value;
    if (!text.trim() && this._images.length === 0) { return; }

    this._busy = true;
    this._syncSendState();
    this._setStatus('Sending...', 'busy');

    const payload = {
      at: new Date().toISOString(),
      text: text,
      images: this._images.map((i) => ({ id: i.id, name: i.name, content_type: i.content_type })),
      card_version: CARD_VERSION,
    };

    try {
      await this._hass.callService('mqtt', 'publish', {
        topic: this._config.topic,
        payload: JSON.stringify(payload),
        qos: 0,
        retain: false,
      });
      this._els.textarea.value = '';
      this._images = [];
      this._renderChips();
      this._setStatus('Sent', 'ok');
    } catch (err) {
      // Keep the text: losing a long reply because the publish failed would be
      // far worse than an error message.
      this._setStatus(`Send failed: ${err.message || err}`, 'err');
    } finally {
      this._busy = false;
      this._syncSendState();
    }
  }
}

/*
 * agent-bridge-activity-card
 *
 * The live header of a session card: status, the last response, and the reasoning
 * and activity expanders.
 *
 * A markdown card re-renders its whole template whenever any referenced attribute
 * changes. With reasoning streaming in, that meant the expander snapped shut and
 * the page jumped on every update. This card builds its DOM once and afterwards
 * only swaps the text of the parts that changed, so an open expander stays open and
 * nothing else moves.
 */
class AgentBridgeActivityCard extends HTMLElement {
  constructor() {
    super();
    this.attachShadow({ mode: 'open' });
    this._built = false;
    this._last = {};
  }

  setConfig(config) {
    if (!config || !config.activity || !config.status) {
      throw new Error('agent-bridge-activity-card: "activity" and "status" are required');
    }
    this._config = Object.assign({ name: '', machine: '', decision: '' }, config);
    this._last = {};
    if (this._hass) { this._render(); }
  }

  set hass(hass) {
    this._hass = hass;
    if (!this._built) { this._build(); }
    this._render();
  }

  getCardSize() {
    return this._compact ? 1 : 4;
  }

  // Set by a session card that folds; the header then keeps only its first lines.
  set compact(value) {
    this._compact = !!value;
    const card = this.shadowRoot && this.shadowRoot.querySelector('ha-card');
    if (card) { card.classList.toggle('compact', this._compact); }
  }

  get compact() { return !!this._compact; }

  _build() {
    this._built = true;
    const style = document.createElement('style');
    style.textContent = `
      ha-card { padding: 0 16px 8px; background: none; box-shadow: none; border: none; }
      .title {
        font-size: 1.25em; font-weight: 500; margin: 12px 0 4px;
        /* Inside a session card: room for its chevron, and the title folds it. */
        padding-right: var(--agent-bridge-title-inset, 0);
        cursor: var(--agent-bridge-title-cursor, default);
      }
      /* Folded: the header keeps its title, status line and spinner only. */
      ha-card.compact .question, ha-card.compact .response,
      ha-card.compact .reasoning, ha-card.compact .history { display: none !important; }
      .meta { color: var(--secondary-text-color); margin-bottom: 8px; }
      .meta b { color: var(--primary-text-color); }
      .waiting { font-weight: 600; margin: 8px 0 4px; }
      hr { border: none; border-top: 1px solid var(--divider-color); margin: 8px 0; }
      details { margin-top: 8px; }
      summary { cursor: pointer; font-style: italic; color: var(--secondary-text-color); }
      ul { margin: 6px 0; padding-left: 20px; }
      .plain { white-space: pre-wrap; }
      /* A thinking summary shown as the newest line, as the terminal shows it. */
      .response.thinking { font-style: italic; color: var(--secondary-text-color); }
      .response.thinking::before { content: '🧠'; float: left; margin: 0 6px 0 0; font-style: normal; }
      .working { margin: 8px 0 6px; color: var(--agent-bridge-spinner-color, #d97757); font-variant-numeric: tabular-nums; }
      .working .glyph { display: inline-block; width: 1.1em; text-align: center; font-variant-emoji: text; }
      .working .elapsed { color: var(--secondary-text-color); }
      [hidden] { display: none !important; }
    `;

    const card = document.createElement('ha-card');
    card.innerHTML = `
      <div class="title"></div>
      <div class="meta"></div>
      <div class="question" hidden><hr><div class="waiting">Waiting on you:</div><div class="md q"></div></div>
      <div class="md response" hidden></div>
      <details class="reasoning" hidden><summary>🧠 reasoning</summary><div class="md r"></div></details>
      <details class="history" hidden><summary>recent activity</summary><ul></ul></details>
      <div class="working" hidden><span class="glyph"></span><span class="verb"></span><span class="elapsed"></span></div>
    `;
    this.shadowRoot.appendChild(style);
    this.shadowRoot.appendChild(card);
    card.classList.toggle('compact', !!this._compact);
    // A session card around this one folds on a click of the title.
    card.querySelector('.title').addEventListener('click', () => {
      this.dispatchEvent(new CustomEvent('agent-bridge-toggle', { bubbles: true, composed: true }));
    });

    this._els = {
      title: card.querySelector('.title'),
      meta: card.querySelector('.meta'),
      question: card.querySelector('.question'),
      q: card.querySelector('.q'),
      response: card.querySelector('.response'),
      reasoning: card.querySelector('.reasoning'),
      r: card.querySelector('.r'),
      history: card.querySelector('.history'),
      list: card.querySelector('.history ul'),
      working: card.querySelector('.working'),
      glyph: card.querySelector('.working .glyph'),
      verb: card.querySelector('.working .verb'),
      elapsed: card.querySelector('.working .elapsed'),
    };

    // ha-markdown is loaded lazily by the frontend. If it was not there at build
    // time the text went in as plain text, so render it again once it arrives.
    if (!customElements.get('ha-markdown')) {
      customElements.whenDefined('ha-markdown').then(() => {
        this._last = {};
        this._render();
      });
    }
  }

  _changed(key, value) {
    if (this._last[key] === value) { return false; }
    this._last[key] = value;
    return true;
  }

  // Only two small spans change on each frame, so the animation never re-renders the
  // card or moves anything around it.
  _startSpinner() {
    if (this._spinner) { return; }
    let frame = 0;
    const tick = () => {
      this._els.glyph.textContent = SPINNER_GLYPHS[frame++ % SPINNER_GLYPHS.length];
      const secs = Math.max(0, Math.floor((Date.now() - this._since) / 1000));
      const text = secs >= 60 ? `${Math.floor(secs / 60)}m ${secs % 60}s` : `${secs}s`;
      if (this._els.elapsed.textContent !== ` (${text})`) { this._els.elapsed.textContent = ` (${text})`; }
    };
    tick();
    this._spinner = setInterval(tick, 120);
  }

  _stopSpinner() {
    if (this._spinner) { clearInterval(this._spinner); this._spinner = null; }
  }

  connectedCallback() {
    // Re-attached after navigating away and back: resume if the session is working.
    if (this._els && !this._els.working.hidden) { this._startSpinner(); }
  }

  disconnectedCallback() {
    this._stopSpinner();
  }

  _setMarkdown(container, text) {
    if (customElements.get('ha-markdown')) {
      let md = container.firstElementChild;
      if (!md || md.tagName !== 'HA-MARKDOWN') {
        container.textContent = '';
        container.classList.remove('plain');
        md = document.createElement('ha-markdown');
        md.breaks = true;
        container.appendChild(md);
      }
      md.content = text;
    } else {
      container.classList.add('plain');
      container.textContent = text;
    }
  }

  _render() {
    if (!this._els || !this._hass || !this._config) { return; }
    const states = this._hass.states;
    const activity = states[this._config.activity];
    const status = states[this._config.status];
    const decision = this._config.decision ? states[this._config.decision] : undefined;
    const attr = (entity, name) => (entity && entity.attributes ? entity.attributes[name] : undefined);

    const question = attr(decision, 'question') || '';
    // A session's entities are removed once it has exited, but a dashboard that has
    // not reloaded yet still shows its card. That read "status: unknown" over an empty
    // card; it is the end of the session, so it says so.
    const rawStatus = status ? String(status.state) : 'unknown';
    const statusText = ['unknown', 'unavailable'].includes(rawStatus) ? 'ended' : rawStatus;
    const dot = question ? '🟡' : (statusText === 'working' ? '🟢' : (['ending', 'ended'].includes(statusText) ? '⏹️' : '⚪'));

    const title = `${dot} ${this._config.name}`;
    if (this._changed('title', title)) { this._els.title.textContent = title; }

    const shownStatus = question ? 'waiting for you' : statusText;
    let activityText = activity ? String(activity.state || '') : '';
    // The summary is usually the first line of the newest message, which the body
    // right below already starts with. Repeating it read as the card saying
    // everything twice, so it is shown only when it adds something ("Running: Edit",
    // a permission message). The state can be cut at Home Assistant's 255-character
    // limit with a trailing "...", so that is ignored when comparing.
    const bodyText = question ? '' : String(attr(activity, 'response') || '');
    const squash = (s) => s.replace(/\s+/g, ' ').trim();
    const summaryCore = squash(activityText.replace(/\.\.\.$/, ''));
    if (summaryCore && squash(bodyText).startsWith(summaryCore)) { activityText = ''; }
    const meta = `${this._config.machine}\u0001${shownStatus}\u0001${activityText}`;
    if (this._changed('meta', meta)) {
      this._els.meta.textContent = '';
      const machine = document.createElement('i');
      machine.textContent = this._config.machine;
      const bold = document.createElement('b');
      bold.textContent = shownStatus;
      this._els.meta.append(machine, ' • status: ', bold);
      if (activityText) { this._els.meta.append(` • ${activityText}`); }
    }

    // The question, when one is waiting, takes the place of the response.
    if (this._changed('question', question)) {
      this._els.question.hidden = !question;
      if (question) { this._setMarkdown(this._els.q, String(question)); }
    }

    const response = question ? '' : String(attr(activity, 'response') || '');
    const thinking = attr(activity, 'response_kind') === 'reasoning';
    if (this._changed('response', `${thinking ? 'r' : 't'}\u0001${response}`)) {
      this._els.response.hidden = !response;
      this._els.response.classList.toggle('thinking', thinking);
      if (response) { this._setMarkdown(this._els.response, response); }
    }

    // The working line runs whenever the session is working and not waiting on you.
    // Its turn starts when the status last changed to working.
    const working = !question && statusText === 'working';
    const since = working && status ? String(status.last_changed || '') : '';
    if (this._changed('working', since)) {
      this._els.working.hidden = !working;
      if (working) {
        let hash = 0;
        for (const ch of since) { hash = (hash * 31 + ch.charCodeAt(0)) >>> 0; }
        this._els.verb.textContent = `${SPINNER_VERBS[hash % SPINNER_VERBS.length]}…`;
        this._since = Date.parse(since) || Date.now();
        this._startSpinner();
      } else {
        this._stopSpinner();
      }
    }

    const reasoning = String(attr(activity, 'reasoning') || '');
    if (this._changed('reasoning', reasoning)) {
      this._els.reasoning.hidden = !reasoning;
      if (reasoning) { this._setMarkdown(this._els.r, reasoning); }
    }

    const history = attr(activity, 'history');
    const items = Array.isArray(history) ? history.slice(-8).map(String) : [];
    if (this._changed('history', items.join('\u0001'))) {
      this._els.history.hidden = items.length === 0;
      this._els.list.textContent = '';
      for (const item of items) {
        const li = document.createElement('li');
        li.textContent = item;
        this._els.list.appendChild(li);
      }
    }
  }
}

/*
 * The answer to a single-choice question, as tappable rows rather than a dropdown.
 *
 * Home Assistant's own select control sizes its menu to the longest option and will
 * not wrap, so on a phone a question with real sentences for answers ran off the
 * right edge and the choices could not be read at all. Rows in the card wrap onto as
 * many lines as they need and are the same on every screen.
 *
 * The options come from the select entity the bridge arms, so nothing about the
 * answer path changes: a tap is the same `select_option` call the dropdown made.
 * 'Awaiting answer...' is the parked state the bridge drives the selector to, not a
 * choice, so it is never offered; 'Cancel request' is, but as a quieter row at the
 * bottom, because it withdraws the question rather than answering it.
 */
const CHOICE_PLACEHOLDER = 'Awaiting answer...';
const CHOICE_CANCEL = 'Cancel request';

class AgentBridgeChoicesCard extends HTMLElement {
  constructor() {
    super();
    this.attachShadow({ mode: 'open' });
    this._last = '';
    this._sent = '';
  }

  setConfig(config) {
    if (!config || !config.decision) {
      throw new Error('agent-bridge-choices-card: "decision" is required');
    }
    this._config = Object.assign({}, config);
    this._last = '';
    if (this._hass) { this._render(); }
  }

  set hass(hass) {
    this._hass = hass;
    if (this._config) { this._render(); }
  }

  getCardSize() { return 2; }

  _build() {
    this._built = true;
    this.shadowRoot.innerHTML = `
      <style>
        ha-card { padding: 0; background: none; box-shadow: none; border: none; }
        .choices { display: flex; flex-direction: column; gap: 6px; }
        button {
          /* Wrapping is the whole point: the text decides the height, not the row. */
          white-space: normal; overflow-wrap: anywhere; text-align: left;
          width: 100%; min-height: 44px; padding: 10px 12px; box-sizing: border-box;
          font: inherit; line-height: 1.35; color: var(--primary-text-color);
          background: var(--secondary-background-color, rgba(127,127,127,0.1));
          border: 1px solid var(--divider-color); border-radius: 8px; cursor: pointer;
        }
        button:hover { border-color: var(--primary-color); }
        button:active { background: var(--divider-color); }
        button:focus-visible { outline: 2px solid var(--primary-color); outline-offset: 1px; }
        button.cancel {
          color: var(--secondary-text-color); background: none;
          min-height: 36px; font-size: 0.92em;
        }
        /* While the answer is on its way, so a second tap cannot send another. */
        .choices.sending button { opacity: 0.5; cursor: default; pointer-events: none; }
        [hidden] { display: none !important; }
      </style>
      <ha-card><div class="choices"></div></ha-card>`;
    this._els = { list: this.shadowRoot.querySelector('.choices') };
  }

  _render() {
    if (!this._built) { this._build(); }
    const entityId = this._config.decision;
    const entity = this._hass ? this._hass.states[entityId] : undefined;
    const state = entity ? String(entity.state) : '';
    const options = entity && entity.attributes && Array.isArray(entity.attributes.options)
      ? entity.attributes.options.map(String).filter((o) => o && o !== CHOICE_PLACEHOLDER)
      : [];

    // Nothing is waiting: an unarmed selector sits on Idle, and a session that has
    // gone leaves its entity unknown.
    const waiting = state !== '' && state !== 'Idle' && state !== 'unknown' && state !== 'unavailable';
    const show = waiting && options.length > 0;
    this.hidden = !show;
    if (!show) { this._sent = ''; return; }

    // The answer has landed once the selector is no longer parked on the placeholder.
    if (this._sent && state !== CHOICE_PLACEHOLDER) { this._sent = ''; }
    this._els.list.classList.toggle('sending', !!this._sent);

    const signature = `${entityId}\u0001${options.join('\u0001')}`;
    if (signature === this._last) { return; }
    this._last = signature;

    this._els.list.textContent = '';
    for (const option of options) {
      const button = document.createElement('button');
      button.type = 'button';
      button.textContent = option;
      if (option === CHOICE_CANCEL) { button.classList.add('cancel'); }
      button.addEventListener('click', () => this._choose(option));
      this._els.list.appendChild(button);
    }
  }

  _choose(option) {
    if (this._sent || !this._hass) { return; }
    this._sent = option;
    this._els.list.classList.add('sending');
    this._hass.callService('select', 'select_option', {
      entity_id: this._config.decision,
      option,
    });
  }
}

/*
 * One session's cards on a single surface: the border, background and state glow
 * (working, waiting on you) drawn here, the section cards inside it.
 *
 * This used to be a vertical-stack styled by card-mod. card-mod is a dashboard
 * resource, and on a hard refresh the stack could be built before it loaded - and
 * card-mod never went back to it, so every session lost its outline, background
 * and glow until the next navigation. A custom card type has no such race: Home
 * Assistant waits for it to be defined before creating it. The children are made
 * transparent through ha-card's own CSS variables, so they sit on this surface
 * whether or not card-mod has arrived either.
 */
/*
 * It also folds: collapsed, a session keeps only its header - title, status line,
 * the working spinner - and hides the response, reasoning, history, reply box and
 * buttons. The chevron or the title toggles it; each viewer's choice is remembered
 * per session. A collapsed session that starts waiting on you opens by itself, so a
 * question is never folded away unseen.
 */
class AgentBridgeSessionCard extends HTMLElement {
  constructor() {
    super();
    this.attachShadow({ mode: 'open' });
    this._children = [];
    this._collapsed = false;
  }

  setConfig(config) {
    if (!config || !Array.isArray(config.cards)) {
      throw new Error('agent-bridge-session-card: "cards" is required');
    }
    this._config = Object.assign({ status: '', decision: '' }, config);
    this._storeKey = `agent-bridge-collapsed:${this._config.status || ''}`;
    try { this._collapsed = localStorage.getItem(this._storeKey) === '1'; } catch (e) { this._collapsed = false; }
    this._build();
  }

  _setCollapsed(collapsed) {
    this._collapsed = collapsed;
    try {
      if (collapsed) { localStorage.setItem(this._storeKey, '1'); } else { localStorage.removeItem(this._storeKey); }
    } catch (e) { /* a per-viewer nicety; the card works without it */ }
    this._applyCollapsed();
  }

  _applyCollapsed() {
    if (!this._frame) { return; }
    this._frame.classList.toggle('collapsed', this._collapsed);
    this._toggle.setAttribute('aria-expanded', this._collapsed ? 'false' : 'true');
    this._toggle.title = this._collapsed ? 'Expand' : 'Collapse';
    const header = this._children[0];
    if (header) { header.compact = this._collapsed; }
  }

  set hass(hass) {
    this._hass = hass;
    for (const child of this._children) { if (child) { child.hass = hass; } }
    this._renderState();
  }

  getCardSize() {
    if (this._collapsed) { return 2; }
    return Math.max(4, (this._config && this._config.cards.length) || 4);
  }

  _build() {
    const generation = (this._generation = (this._generation || 0) + 1);
    this.shadowRoot.innerHTML = `
      <style>
        :host { display: block; }
        .frame {
          position: relative;
          /* Room for the chevron beside the header's title, and a title that toggles. */
          --agent-bridge-title-inset: 30px;
          --agent-bridge-title-cursor: pointer;
          border-radius: var(--ha-card-border-radius, 12px);
          background: var(--ha-card-background, var(--card-background-color, #fff));
          overflow: hidden;
          padding: 4px 12px 10px 12px;
          box-sizing: border-box;
          border: 1px solid var(--divider-color);
          transition: border-color 0.4s ease;
          /* Children draw no surface of their own. */
          --ha-card-background: transparent;
          --ha-card-box-shadow: none;
          --ha-card-border-width: 0;
          --ha-card-border-color: transparent;
        }
        .frame.working { border-color: var(--primary-color); animation: cpwork 1.6s ease-in-out infinite; }
        .frame.waiting { border-color: var(--warning-color); animation: cpwait 1.6s ease-in-out infinite; }
        /* Driven through Home Assistant by an agent rather than by you. The pulse is
           the same shape so "something is happening" still reads at a glance; only
           the colour changes, and it holds a steady purple edge while idle so a
           session left under an agent's control still says so. */
        .frame.agent { border-color: var(--agent-bridge-agent-color, #a855f7); }
        .frame.agent.working,
        .frame.agent.waiting {
          border-color: var(--agent-bridge-agent-color, #a855f7);
          animation: cpagent 1.6s ease-in-out infinite;
        }
        @keyframes cpagent {
          0%   { box-shadow: 0 0 6px 0px var(--agent-bridge-agent-color, #a855f7); }
          50%  { box-shadow: 0 0 18px 3px var(--agent-bridge-agent-color, #a855f7); }
          100% { box-shadow: 0 0 6px 0px var(--agent-bridge-agent-color, #a855f7); }
        }
        @keyframes cpwork {
          0%   { box-shadow: 0 0 6px 0px var(--primary-color); }
          50%  { box-shadow: 0 0 16px 2px var(--primary-color); }
          100% { box-shadow: 0 0 6px 0px var(--primary-color); }
        }
        @keyframes cpwait {
          0%   { box-shadow: 0 0 6px 0px var(--warning-color); }
          50%  { box-shadow: 0 0 18px 3px var(--warning-color); }
          100% { box-shadow: 0 0 6px 0px var(--warning-color); }
        }
        .fold {
          position: absolute; top: 14px; right: 10px; z-index: 1;
          width: 28px; height: 28px; padding: 0; border: none; border-radius: 50%;
          background: none; cursor: pointer; color: var(--secondary-text-color);
          display: flex; align-items: center; justify-content: center; --mdc-icon-size: 22px;
          transition: transform 0.2s ease;
        }
        .fold:hover { background: var(--secondary-background-color, rgba(127,127,127,0.15)); }
        .collapsed .fold { transform: rotate(-90deg); }
        /* Collapsed, only the header stays. */
        .collapsed .body > :not(:first-child) { display: none; }
        .collapsed { padding-bottom: 4px; }
      </style>
      <div class="frame">
        <button class="fold" aria-expanded="true" title="Collapse"><ha-icon icon="mdi:chevron-down"></ha-icon></button>
        <div class="body"></div>
      </div>`;
    this._frame = this.shadowRoot.querySelector('.frame');
    this._body = this.shadowRoot.querySelector('.body');
    this._toggle = this.shadowRoot.querySelector('.fold');
    this._toggle.addEventListener('click', () => this._setCollapsed(!this._collapsed));
    // The header's title asks for the same, from inside its own shadow root.
    this._frame.addEventListener('agent-bridge-toggle', (ev) => { ev.stopPropagation(); this._setCollapsed(!this._collapsed); });
    this._state = null;
    this._children = [];
    this._applyCollapsed();
    this._renderState();

    const configs = this._config.cards;
    const make = (helpers, index) => {
      const el = helpers.createCardElement(configs[index]);
      if (this._hass) { el.hass = this._hass; }
      if (index === 0) { el.compact = this._collapsed; }
      // A child whose custom type was not defined yet is built as a placeholder that
      // asks to be rebuilt once it is - the same request a stack card honours.
      el.addEventListener('ll-rebuild', (ev) => {
        ev.stopPropagation();
        if (generation !== this._generation) { return; }
        const fresh = make(helpers, index);
        el.replaceWith(fresh);
        this._children[index] = fresh;
      }, { once: true });
      return el;
    };
    window.loadCardHelpers().then((helpers) => {
      if (generation !== this._generation) { return; }
      configs.forEach((_, index) => {
        const el = make(helpers, index);
        this._children[index] = el;
        this._body.appendChild(el);
      });
    });
  }

  _renderState() {
    if (!this._frame || !this._hass || !this._config) { return; }
    const states = this._hass.states;
    const decision = this._config.decision ? states[this._config.decision] : undefined;
    const status = this._config.status ? states[this._config.status] : undefined;
    const activity = this._config.activity ? states[this._config.activity] : undefined;
    const waiting = !!(decision && decision.attributes && decision.attributes.question);
    const state = waiting ? 'waiting' : (status && status.state === 'working' ? 'working' : '');
    // Who last drove this session. Absent on a card served by an older daemon, which
    // reads as yours - the safe way round, since a wrong glow is worse than none.
    const driver = (activity && activity.attributes && activity.attributes.driver) || 'human';
    const key = `${state}\u0001${driver}`;
    if (key === this._stateKey) { return; }
    // A question arriving opens a folded session: it is waiting on you.
    if (state === 'waiting' && this._collapsed) { this._setCollapsed(false); }
    this._stateKey = key;
    this._state = state;
    this._frame.classList.toggle('waiting', state === 'waiting');
    this._frame.classList.toggle('working', state === 'working');
    this._frame.classList.toggle('agent', driver === 'agent');
  }
}

/*
 * Starting a session. The entities card this replaces gave every selector a
 * full-height row, so the card took a screenful to say "press Launch". Here the
 * header carries the title, what a press will start (agent - workspace) and the
 * Launch button itself; the choices fold out beneath it in a compact grid, and the
 * note about the last press sits right under the button.
 *
 * A press shows "Launching..." at once, before the daemon has said anything, and
 * that stays until the daemon's own note replaces it - so a press never looks as if
 * it did nothing.
 */
const LAUNCH_FRESH = 'New session';
const LAUNCH_BLANK = ' ';

class AgentBridgeLaunchCard extends HTMLElement {
  constructor() {
    super();
    this.attachShadow({ mode: 'open' });
    this._pressedAt = 0;
    try { this._open = localStorage.getItem('agent-bridge-launch-open') === '1'; } catch (e) { this._open = false; }
  }

  setConfig(config) {
    if (!config || !Array.isArray(config.machines) || config.machines.length === 0) {
      throw new Error('agent-bridge-launch-card: "machines" is required');
    }
    this._config = Object.assign({ title: 'Start a new session', selector: '' }, config);
    this._built = false;
    if (this._hass) { this._build(); this._render(); }
  }

  set hass(hass) {
    this._hass = hass;
    if (!this._built) { this._build(); }
    this._render();
  }

  getCardSize() { return this._open ? 5 : 2; }

  _build() {
    this._built = true;
    this.shadowRoot.innerHTML = `
      <style>
        ha-card { padding: 12px 16px; }
        .head { display: flex; align-items: center; gap: 10px; }
        .toggle { flex: 1; min-width: 0; cursor: pointer; user-select: none; }
        .title { font-size: 1.1em; font-weight: 500; display: flex; align-items: center; gap: 6px; }
        /* An icon, not a glyph: phones drew the triangle as a colour emoji. */
        .chev { transition: transform 0.2s ease; color: var(--secondary-text-color); --mdc-icon-size: 20px; display: inline-flex; margin-left: -4px; }
        .open .chev { transform: rotate(90deg); }
        .summary { color: var(--secondary-text-color); font-size: 0.9em; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        button.launch {
          border: none; border-radius: 8px; padding: 0 16px; height: 36px; flex: none;
          font: inherit; font-weight: 600; cursor: pointer;
          background: var(--primary-color); color: var(--text-primary-color, #fff);
        }
        button.launch:disabled { opacity: 0.5; cursor: default; }
        .fields {
          display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
          gap: 8px 10px; margin-top: 12px;
        }
        label { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
        label span { font-size: 11px; color: var(--secondary-text-color); }
        label.wide { grid-column: 1 / -1; }
        select, input {
          height: 34px; min-width: 0; box-sizing: border-box; padding: 0 8px;
          font: inherit; color: var(--primary-text-color);
          background: var(--secondary-background-color, rgba(127,127,127,0.1));
          border: 1px solid var(--divider-color); border-radius: 8px;
        }
        select:focus, input:focus { outline: none; border-color: var(--primary-color); }
        .dim { opacity: 0.45; }
        .note { margin-top: 10px; font-size: 0.92em; color: var(--secondary-text-color); display: flex; gap: 6px; align-items: baseline; }
        .note .spin { color: var(--agent-bridge-spinner-color, #d97757); }
        [hidden] { display: none !important; }
      </style>
      <ha-card>
        <div class="head">
          <div class="toggle" role="button" tabindex="0" aria-expanded="false">
            <div class="title"><ha-icon class="chev" icon="mdi:chevron-right"></ha-icon><span class="name"></span></div>
            <div class="summary"></div>
          </div>
          <button class="launch">Launch</button>
        </div>
        <div class="fields" hidden>
          <label class="f-machine wide"><span>Machine</span><select data-key="machine"></select></label>
          <label class="f-resume wide"><span>Resume</span><select data-key="resume"></select></label>
          <label class="f-agent"><span>Agent</span><select data-key="agent"></select></label>
          <label class="f-workspace"><span>Workspace</span><select data-key="workspace"></select></label>
          <label class="f-profile"><span>Profile</span><select data-key="profile"></select></label>
          <label class="f-prompt wide"><span>First message (optional)</span><input data-key="prompt" type="text" placeholder="Start with a task, or leave empty"></label>
        </div>
        <div class="note" hidden><span class="spin"></span><span class="text"></span></div>
      </ha-card>`;
    const $ = (s) => this.shadowRoot.querySelector(s);
    this._els = {
      card: $('ha-card'), toggle: $('.toggle'), name: $('.name'), summary: $('.summary'),
      launch: $('button.launch'), fields: $('.fields'), note: $('.note'), spin: $('.note .spin'), text: $('.note .text'),
      prompt: $('input[data-key="prompt"]'),
    };
    this._els.name.textContent = this._config.title;

    const flip = () => {
      this._open = !this._open;
      try { localStorage.setItem('agent-bridge-launch-open', this._open ? '1' : '0'); } catch (e) { /* per-viewer nicety only */ }
      this._render();
    };
    this._els.toggle.addEventListener('click', flip);
    this._els.toggle.addEventListener('keydown', (ev) => { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); flip(); } });

    this.shadowRoot.querySelectorAll('select').forEach((select) => {
      select.addEventListener('change', () => this._choose(select.dataset.key, select.value));
    });
    this._els.prompt.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') { ev.preventDefault(); this._launch(); } });
    this._els.launch.addEventListener('click', () => this._launch());
  }

  _machine() {
    const machines = this._config.machines;
    const chosen = this._config.selector ? this._state(this._config.selector) : '';
    return machines.find((m) => m.machine === chosen) || machines[0];
  }

  _state(entityId) {
    const s = entityId && this._hass ? this._hass.states[entityId] : undefined;
    return s ? String(s.state) : '';
  }

  _options(entityId) {
    const s = entityId && this._hass ? this._hass.states[entityId] : undefined;
    return s && s.attributes && Array.isArray(s.attributes.options) ? s.attributes.options.map(String) : [];
  }

  _entityFor(key) {
    return key === 'machine' ? this._config.selector : this._machine()[key];
  }

  _choose(key, value) {
    const entityId = this._entityFor(key);
    if (!entityId) { return; }
    const domain = entityId.split('.')[0];
    this._hass.callService(domain, 'select_option', { entity_id: entityId, option: value });
  }

  async _launch() {
    const m = this._machine();
    if (!m.launch || this._els.launch.disabled) { return; }
    this._pressedAt = Date.now();
    this._pressedNote = this._state(m.result);
    this._render();
    try {
      // The prompt is written before the press: the daemon reads it when it sees
      // the press, and a value still sitting in this box would otherwise be missed.
      const typed = this._els.prompt.value.trim();
      if (m.prompt && typed !== this._state(m.prompt).trim()) {
        await this._hass.callService('text', 'set_value', { entity_id: m.prompt, value: typed || LAUNCH_BLANK });
      }
      await this._hass.callService('button', 'press', { entity_id: m.launch });
      this._els.prompt.value = '';
    } catch (err) {
      this._pressedAt = 0;
      this._localNote = `Launch failed: ${err.message || err}`;
      this._render();
    }
  }

  _fill(select, entityId, labelEl) {
    const options = this._options(entityId);
    labelEl.hidden = !entityId || options.length === 0;
    if (labelEl.hidden) { return; }
    const key = options.join('\u0001');
    if (select.dataset.options !== key) {
      select.dataset.options = key;
      select.textContent = '';
      for (const option of options) {
        const el = document.createElement('option');
        el.value = option;
        el.textContent = option;
        select.appendChild(el);
      }
    }
    // Never yank a list out from under someone choosing from it.
    const current = this._state(entityId);
    if (this.shadowRoot.activeElement !== select && options.includes(current) && select.value !== current) {
      select.value = current;
    }
  }

  _render() {
    if (!this._els || !this._hass || !this._config) { return; }
    const m = this._machine();
    const machines = this._config.machines;
    const q = (s) => this.shadowRoot.querySelector(s);

    this._els.toggle.parentElement.classList.toggle('open', this._open);
    this._els.toggle.setAttribute('aria-expanded', this._open ? 'true' : 'false');
    this._els.fields.hidden = !this._open;

    this._fill(q('select[data-key="machine"]'), machines.length > 1 ? this._config.selector : '', q('.f-machine'));
    this._fill(q('select[data-key="resume"]'), m.resume, q('.f-resume'));
    this._fill(q('select[data-key="agent"]'), m.agent, q('.f-agent'));
    this._fill(q('select[data-key="workspace"]'), m.workspace, q('.f-workspace'));
    this._fill(q('select[data-key="profile"]'), m.profile, q('.f-profile'));

    // A resume brings its own agent and folder, so those choices step back.
    const resume = m.resume ? this._state(m.resume) : '';
    const resuming = !!resume && resume !== LAUNCH_FRESH && !['unknown', 'unavailable'].includes(resume);
    const agent = m.agent ? this._state(m.agent) : '';
    q('.f-agent').classList.toggle('dim', resuming);
    q('.f-workspace').classList.toggle('dim', resuming);
    // The profile applies only under Agency.
    if (m.agent && agent && agent !== 'Agency') { q('.f-profile').hidden = true; }

    const promptState = this._state(m.prompt);
    if (this.shadowRoot.activeElement !== this._els.prompt && !this._els.prompt.value && promptState.trim() &&
        !['unknown', 'unavailable'].includes(promptState)) {
      this._els.prompt.value = promptState.trim();
    }

    const workspace = this._state(m.workspace);
    const bits = resuming ? [`Resume: ${resume}`] : [agent, workspace].filter((b) => b && !['unknown', 'unavailable'].includes(b));
    if (machines.length > 1) { bits.unshift(m.machine); }
    this._els.summary.textContent = bits.join(' · ');
    this._els.launch.textContent = resuming ? 'Resume' : 'Launch';

    // The note: the daemon's word on the last press, or "Launching..." from the
    // moment of the press until the daemon's note changes (20 s at most).
    let note = this._state(m.result);
    if (['unknown', 'unavailable'].includes(note)) { note = ''; }
    const waiting = this._pressedAt && note === this._pressedNote && Date.now() - this._pressedAt < 20000;
    if (this._pressedAt && !waiting) { this._pressedAt = 0; }
    if (waiting) { note = 'Launching...'; }
    if (this._localNote) { note = this._localNote; this._localNote = ''; }
    const busy = waiting || /\.\.\.$/.test(note.trim());
    this._els.note.hidden = !note.trim();
    this._els.text.textContent = note.trim();
    this._els.spin.textContent = busy ? '⏳' : '';
    this._els.launch.disabled = waiting;
    if (waiting && !this._pressTimer) {
      // Re-check once the optimistic note would expire, even if no state changes.
      this._pressTimer = setTimeout(() => { this._pressTimer = null; this._render(); }, 20500);
    }
  }
}

if (!customElements.get('agent-bridge-reply-card')) {
  customElements.define('agent-bridge-reply-card', AgentBridgeReplyCard);
}
if (!customElements.get('agent-bridge-launch-card')) {
  customElements.define('agent-bridge-launch-card', AgentBridgeLaunchCard);
}
if (!customElements.get('agent-bridge-session-card')) {
  customElements.define('agent-bridge-session-card', AgentBridgeSessionCard);
}
if (!customElements.get('agent-bridge-activity-card')) {
  customElements.define('agent-bridge-activity-card', AgentBridgeActivityCard);
}
if (!customElements.get('agent-bridge-choices-card')) {
  customElements.define('agent-bridge-choices-card', AgentBridgeChoicesCard);
}

window.customCards = window.customCards || [];
window.customCards.push({
  type: 'agent-bridge-reply-card',
  name: 'Agent Bridge Reply',
  description: 'Reply box for a bridged coding-agent session, with image attachments.',
});
window.customCards.push({
  type: 'agent-bridge-activity-card',
  name: 'Agent Bridge Activity',
  description: 'Live status, response and reasoning for a bridged session, updated in place.',
});
window.customCards.push({
  type: 'agent-bridge-choices-card',
  name: 'Agent Bridge Choices',
  description: 'The answers to a waiting question, as rows that wrap instead of a dropdown.',
});

console.info(`%c AGENT-BRIDGE-REPLY-CARD %c ${CARD_VERSION} `,
  'color: white; background: #03a9f4; font-weight: 700;',
  'color: #03a9f4; background: white; font-weight: 700;');
