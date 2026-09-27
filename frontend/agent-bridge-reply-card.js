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

const CARD_VERSION = '1.11.1';

// The working line, in the style of Claude Code's own spinner: its glyph cycle, and a
// word picked once per turn. Claude Code does not record which word it chose, so the
// card picks its own from the same kind of list.
const SPINNER_GLYPHS = ['·', '✢', '✳', '✶', '✻', '✽', '✻', '✶', '✳', '✢'];
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
    const token = this._accessToken();
    if (!token) { throw new Error('no access token'); }

    const form = new FormData();
    form.append('file', file, file.name || 'pasted.png');

    const resp = await fetch('/api/image/upload', {
      method: 'POST',
      body: form,
      headers: { authorization: `Bearer ${token}` },
    });
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

  _renderChips() {
    const token = this._accessToken();
    this._els.chips.innerHTML = '';
    this._images.forEach((img, index) => {
      const chip = document.createElement('div');
      chip.className = 'chip';

      const thumb = document.createElement('img');
      thumb.alt = img.name;
      if (token) {
        // The serve endpoint needs auth, so the thumbnail is fetched as a blob
        // rather than pointed at directly with a plain src.
        fetch(`/api/image/serve/${img.id}/256x256`, { headers: { authorization: `Bearer ${token}` } })
          .then((r) => (r.ok ? r.blob() : null))
          .then((b) => { if (b) { thumb.src = URL.createObjectURL(b); } })
          .catch(() => {});
      }

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
    return 4;
  }

  _build() {
    this._built = true;
    const style = document.createElement('style');
    style.textContent = `
      ha-card { padding: 0 16px 8px; background: none; box-shadow: none; border: none; }
      .title { font-size: 1.25em; font-weight: 500; margin: 12px 0 4px; }
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
      .working { margin-top: 8px; color: var(--agent-bridge-spinner-color, #d97757); font-variant-numeric: tabular-nums; }
      .working .glyph { display: inline-block; width: 1.1em; text-align: center; }
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
    const statusText = status ? status.state : 'unknown';
    const dot = question ? '🟡' : (statusText === 'working' ? '🟢' : '⚪');

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

if (!customElements.get('agent-bridge-reply-card')) {
  customElements.define('agent-bridge-reply-card', AgentBridgeReplyCard);
}
if (!customElements.get('agent-bridge-activity-card')) {
  customElements.define('agent-bridge-activity-card', AgentBridgeActivityCard);
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

console.info(`%c AGENT-BRIDGE-REPLY-CARD %c ${CARD_VERSION} `,
  'color: white; background: #03a9f4; font-weight: 700;',
  'color: #03a9f4; background: white; font-weight: 700;');
