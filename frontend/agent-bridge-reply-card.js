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
 *
 * Anything that is not an image travels inside the payload itself, base64'd. It
 * cannot go the way images go: /api/image/upload runs the upload through an image
 * decoder and answers 400 for a .md, a .log or a .csv, so there is no id to hand
 * over. The reply is already published over MQTT with no length cap, which leaves
 * the file bytes somewhere to ride - hence the size limit below, since unlike an
 * uploaded image these sit in the sensor's attributes.
 */

const CARD_VERSION = '1.23.0';

/*
 * How large a non-image attachment may be.
 *
 * Images are not counted against this: they are uploaded to Home Assistant and only
 * their id travels. An inline file, though, becomes base64 (a third larger again) in
 * an MQTT payload that Home Assistant keeps as a state attribute, so the ceiling is
 * about being a good citizen of the state machine rather than about any hard limit -
 * 256 KB carried intact in testing, and covers the documents this is for.
 */
const MAX_INLINE_FILE_BYTES = 256 * 1024;

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

/*
 * What to say when Home Assistant turns an upload down.
 *
 * "403 Forbidden" is accurate and useless. Both refusals that happen in practice
 * leave the rest of the card working, which is what makes them so baffling to hit:
 * a reply is published over the page's websocket, which stays authenticated for as
 * long as the tab is open, while an image has to go over HTTP to /api/image/upload,
 * which does not. So replies kept sending and images stopped, and nothing on screen
 * said why - the card reported the status line and left you to guess.
 *
 * A 403 is not about the token at all. An ip_bans entry answers every HTTP request
 * that way, and behind a reverse proxy the banned address is the one the proxy
 * reports - which can be a public address shared by everyone arriving over it, so
 * the block need have nothing to do with this browser or this account.
 */
function describeUploadRefusal(status, statusText) {
  if (status === 401) {
    return "this page's sign-in has lapsed - reload Home Assistant and try again";
  }
  if (status === 403) {
    return 'Home Assistant refused this browser (403). Replies still work because they go over the '
      + 'websocket, which uploads cannot use. Check its IP bans for the address it sees this browser as';
  }
  if (status === 413) {
    return 'that image is larger than Home Assistant will accept (413)';
  }
  return `Home Assistant returned ${status}${statusText ? ` ${statusText}` : ''}`;
}

function describeSize(bytes) {
  return bytes >= 1024 ? `${Math.round(bytes / 1024)} KB` : `${bytes} bytes`;
}

/*
 * Base64 for the bytes of an inline attachment.
 *
 * In chunks because btoa needs a binary string and String.fromCharCode takes the
 * bytes as arguments: spreading a whole file into one call overflows the argument
 * stack and throws on anything but a tiny file.
 */
function toBase64(bytes) {
  const CHUNK = 0x8000;
  let binary = '';
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
  }
  return btoa(binary);
}

/*
 * A thrown value is not always an Error. home-assistant-js-websocket rejects with
 * bare numbers, so a token renewal Home Assistant turned down arrived here as the
 * number 2 and reached the status line as "Upload failed: 2", which told nobody
 * anything whatsoever.
 */
function describeThrown(err) {
  if (err && err.message) { return err.message; }
  if (err === 1 || err === 3) { return 'lost contact with Home Assistant - try again'; }
  if (err === 2) { return "Home Assistant would not renew this page's sign-in - reload it and try again"; }
  return String(err);
}

class AgentBridgeReplyCard extends HTMLElement {
  constructor() {
    super();
    this.attachShadow({ mode: 'open' });
    this._built = false;
    this._images = [];
    this._files = [];
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
      .chip ha-icon {
        --mdc-icon-size: 18px;
        width: 28px; height: 28px; border-radius: 11px;
        display: flex; align-items: center; justify-content: center;
        background: var(--divider-color, #444); color: var(--primary-text-color, #fff);
      }
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
          <button class="ghost attach" title="Attach a file"><ha-icon icon="mdi:paperclip"></ha-icon></button>
          <button class="send">Send</button>
        </div>
      </div>
      <div class="chips"></div>
      <div class="status"></div>
      <div class="hint">Paste or attach an image or file to send it with your reply.</div>
      <input type="file" multiple />
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
      // Any pasted file, not only an image: a document copied from a file manager
      // arrives here exactly as a screenshot does. `kind` is what keeps this safe -
      // pasted text and rich text are 'string' items and are left well alone.
      if (item.kind === 'file') {
        const file = item.getAsFile();
        if (file) { files.push(file); }
      }
    }
    if (files.length) {
      // Only swallow the paste when it carried a file; a plain text paste must
      // still land in the textarea normally.
      event.preventDefault();
      this._ingest(files);
    }
  }

  async _ingest(files) {
    const usable = files.filter((f) => f && (f.name || f.type));
    if (!usable.length) { return; }

    this._busy = true;
    this._syncSendState();
    for (const file of usable) {
      const isImage = !!(file.type && file.type.startsWith('image/'));
      const label = file.name || (isImage ? 'image' : 'file');
      this._setStatus(`${isImage ? 'Uploading' : 'Reading'} ${label}...`, 'busy');
      try {
        if (isImage) { this._images.push(await this._upload(file)); }
        else { this._files.push(await this._read(file)); }
        this._renderChips();
        this._setStatus('', '');
      } catch (err) {
        this._setStatus(`${isImage ? 'Upload' : 'Attach'} failed: ${describeThrown(err)}`, 'err');
      }
    }
    this._busy = false;
    this._syncSendState();
  }

  /*
   * Reads a non-image attachment into the payload.
   *
   * The length is checked twice on purpose. A File's `size` is metadata, and the
   * cheap check keeps a large file from being read into memory at all; the one
   * after the read is the one that is actually true, because a file growing between
   * being picked and being read is exactly the case the first check cannot see.
   */
  async _read(file) {
    const tooBig = (n) => new Error(
      `${describeSize(n)} is over the ${describeSize(MAX_INLINE_FILE_BYTES)} limit for a file attachment`);

    if (typeof file.size === 'number' && file.size > MAX_INLINE_FILE_BYTES) { throw tooBig(file.size); }
    if (typeof file.arrayBuffer !== 'function') { throw new Error('this browser cannot read that file'); }

    const bytes = new Uint8Array(await file.arrayBuffer());
    if (bytes.length > MAX_INLINE_FILE_BYTES) { throw tooBig(bytes.length); }
    if (!bytes.length) { throw new Error('that file is empty'); }

    return {
      name: file.name || 'attachment',
      content_type: file.type || 'application/octet-stream',
      size: bytes.length,
      b64: toBase64(bytes),
    };
  }

  async _upload(file) {
    const form = new FormData();
    form.append('file', file, file.name || 'pasted.png');

    const resp = await this._authFetch('/api/image/upload', { method: 'POST', body: form });
    if (!resp.ok) {
      throw new Error(describeUploadRefusal(resp.status, resp.statusText));
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
  //
  // No step here may end the attempt. fetchWithAuth renews the token before it sends,
  // and a renewal Home Assistant turns down rejects with ERR_INVALID_AUTH - the bare
  // number 2, not an Error - so an upload was abandoned before the token already in
  // hand had been tried even once. That token is usually still good: the page's
  // websocket is authenticated and streaming, which is exactly why replies went on
  // working while images stopped.
  async _authFetch(path, init = {}) {
    const hass = this._hass;
    const auth = hass && hass.auth;
    if (hass && typeof hass.fetchWithAuth === 'function') {
      try {
        const resp = await hass.fetchWithAuth(path, init);
        if (resp.status !== 401 || !auth) { return resp; }
      }
      catch (err) {
        // Nothing left to fall back to, so the caller should see what went wrong.
        if (!auth) { throw err; }
      }
    }
    if (!auth) { throw new Error('no access token'); }
    const send = () => fetch(path, {
      ...init,
      headers: { ...(init.headers || {}), authorization: `Bearer ${this._accessToken()}` },
    });
    if (auth.expired) { await this._refreshed(auth); }
    let resp = await send();
    if (resp.status === 401 && await this._refreshed(auth)) {
      resp = await send();
    }
    return resp;
  }

  // Whether the token was renewed. Best effort by design: the answer decides only
  // whether sending again is worth it, never whether to give up on what was asked.
  async _refreshed(auth) {
    if (!auth || typeof auth.refreshAccessToken !== 'function') { return false; }
    try {
      await auth.refreshAccessToken();
      return true;
    }
    catch {
      return false;
    }
  }

  _renderChips() {
    this._els.chips.innerHTML = '';
    this._images.forEach((img, index) => {
      const thumb = document.createElement('img');
      thumb.alt = img.name;
      // The serve endpoint needs auth, so the thumbnail is fetched as a blob
      // rather than pointed at directly with a plain src.
      this._authFetch(`/api/image/serve/${img.id}/256x256`)
        .then((r) => (r.ok ? r.blob() : null))
        .then((b) => { if (b) { thumb.src = URL.createObjectURL(b); } })
        .catch(() => {});
      this._addChip(this._images, index, img.name, img.name, thumb);
    });
    this._files.forEach((file, index) => {
      // Nothing to show a thumbnail of, so an icon stands in. The size goes in the
      // tooltip rather than the label: it is the one thing about a file attachment
      // that can get it refused, and the name is what identifies it.
      const icon = document.createElement('ha-icon');
      icon.setAttribute('icon', 'mdi:file-document-outline');
      this._addChip(this._files, index, file.name, `${file.name} (${describeSize(file.size)})`, icon);
    });
  }

  _addChip(list, index, name, title, leading) {
    const chip = document.createElement('div');
    chip.className = 'chip';
    chip.setAttribute('title', title);

    const label = document.createElement('span');
    label.textContent = name.length > 18 ? `${name.slice(0, 15)}...` : name;

    const remove = document.createElement('span');
    remove.className = 'x';
    remove.textContent = '\u2715';
    remove.title = 'Remove';
    remove.addEventListener('click', () => {
      list.splice(index, 1);
      this._renderChips();
      this._syncSendState();
    });

    chip.appendChild(leading);
    chip.appendChild(label);
    chip.appendChild(remove);
    this._els.chips.appendChild(chip);
  }

  _syncSendState() {
    if (!this._els) { return; }
    const hasText = this._els.textarea.value.trim().length > 0;
    this._els.send.disabled = this._busy
      || (!hasText && this._images.length === 0 && this._files.length === 0);
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
    if (!text.trim() && this._images.length === 0 && this._files.length === 0) { return; }

    this._busy = true;
    this._syncSendState();
    this._setStatus('Sending...', 'busy');

    const payload = {
      at: new Date().toISOString(),
      text: text,
      images: this._images.map((i) => ({ id: i.id, name: i.name, content_type: i.content_type })),
      files: this._files.map((f) => ({ name: f.name, content_type: f.content_type, b64: f.b64 })),
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
      this._files = [];
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
    // Not `this._spinner`: while the page is hidden there is deliberately no interval,
    // and keying the guard on it would register a second listener on every call.
    if (this._spinning) { return; }
    this._spinning = true;
    let frame = 0;
    const tick = () => {
      this._els.glyph.textContent = SPINNER_GLYPHS[frame++ % SPINNER_GLYPHS.length];
      const secs = Math.max(0, Math.floor((Date.now() - this._since) / 1000));
      const text = secs >= 60 ? `${Math.floor(secs / 60)}m ${secs % 60}s` : `${secs}s`;
      if (this._els.elapsed.textContent !== ` (${text})`) { this._els.elapsed.textContent = ` (${text})`; }
    };
    const hidden = () => typeof document !== 'undefined' && !!document.hidden;
    const resume = () => {
      if (this._spinner || hidden()) { return; }
      // At once, so the elapsed time is right the instant the tab is looked at rather
      // than up to 120ms later.
      tick();
      this._spinner = setInterval(tick, 120);
    };
    // Home Assistant sits in a pinned tab for days, with one of these per working
    // session. Returning early from the tick is not enough - the timer still fires and
    // still wakes the main thread, it just does nothing once it has - so the interval
    // is stopped outright while the page is hidden and started again when it is not.
    this._onVisible = () => {
      if (!hidden()) { resume(); return; }
      if (this._spinner) { clearInterval(this._spinner); this._spinner = null; }
    };
    if (typeof document !== 'undefined' && document.addEventListener) {
      document.addEventListener('visibilitychange', this._onVisible);
    }
    resume();
  }

  _stopSpinner() {
    this._spinning = false;
    if (this._spinner) { clearInterval(this._spinner); this._spinner = null; }
    if (this._onVisible) {
      document.removeEventListener('visibilitychange', this._onVisible);
      this._onVisible = null;
    }
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
 * The answer to a question - one choice or a whole form - as tappable rows rather
 * than dropdowns.
 *
 * Home Assistant's own select control is bad here in two specific ways. It sizes its
 * menu to the longest option and will not wrap, so on a phone a question with real
 * sentences for answers ran off the right edge and could not be read at all. And it
 * commits on blur, so answering meant tapping the option, tapping away, and only then
 * pressing Send. Rows wrap onto as many lines as they need, are the same on every
 * screen, and are tapped once.
 *
 * A question publishes one select per field (`fields`), and the main selector
 * (`decision`) then carries only 'Cancel request'. Both are rendered here: a labelled
 * group of rows per armed field, then whatever the main selector offers. Nothing
 * about the answer path changes - a tap is the same `select_option` call the dropdown
 * made, on the same entity the daemon reads when Send is pressed.
 *
 * 'Awaiting answer...' is the parked state the bridge drives the main selector to and
 * 'Choose...' is a field's, so neither is ever offered as an answer. 'Cancel request'
 * is, but as a quieter row at the bottom, because it withdraws the question rather
 * than answering it.
 *
 * A field that takes several of its options at once - `type: array` in an ask_user
 * schema - is drawn as its own options with as many ticked as you like, not as the
 * list of combinations its slot has to enumerate to hold the answer. Before 1.22.0
 * it was those combinations, which is why "pick any of these" could only ever be
 * answered with one of them.
 *
 * Picking is never sending. Every question is committed by Send answer, this card's
 * own row from 1.22.0 - which is also what lets the reply box below stay the reply
 * card rather than an entity row with a button beside it. Until then a single choice
 * went the moment it was touched while the form beside it waited for Send, which is
 * two behaviours for one gesture and no way back from the easier one to tap by
 * accident. A selector carrying choices with no field behind it - a legacy `choices`
 * argument, an MCP client - still answers on the tap, because there is no slot for
 * it to wait in.
 */
const CHOICE_PLACEHOLDER = 'Awaiting answer...';
const CHOICE_FIELD_PLACEHOLDER = 'Choose...';
const CHOICE_CANCEL = 'Cancel request';
// What the bridge joins a multi-select field's picked options with. Published beside
// the options so the label written back here is built exactly as the one the daemon
// takes apart again; this is only the value to use when an older bridge sends none.
const CHOICE_MULTI_SEPARATOR = ' + ';
// Shown while a tap has been sent to Home Assistant but has not come back. Send is
// held for exactly as long as this is on screen, so the two can never disagree.
const CHOICE_SAVING_NOTE = 'Saving your choice...';
// The states an entity sits in when it is carrying nothing: an unarmed field slot is
// parked on 'Idle', and a session that has gone leaves its entity behind.
const CHOICE_UNARMED = ['', 'Idle', 'unknown', 'unavailable'];
// The short form a slot can hold instead of the picked options written out: '#1,3' is
// the first and third option, one-based and ascending.
//
// Writing the words out is what used to cap this. A Home Assistant select holds one
// value from a published list, so a set has to be one entry in that list, and six
// ordinary sentence-length options joined together ran to 350 characters against a
// 255-character entry - at which point the bridge refused the field and sent the whole
// question to the terminal. Positions are 22 characters for all ten.
const CHOICE_CODE_PATTERN = /^#[1-9][0-9]*(,[1-9][0-9]*)*$/;

/*
 * The picked options as positions: '#1,3'. Ascending, because that is the only order
 * the bridge accepts and the only one it writes.
 */
function multiSelectCode(options, picked) {
  const indexes = picked
    .map((option) => options.indexOf(option))
    .filter((i) => i >= 0)
    .sort((a, b) => a - b);
  if (indexes.length === 0) { return ''; }
  return `#${indexes.map((i) => i + 1).join(',')}`;
}

/*
 * Which of a multi-select field's options its slot currently stands for.
 *
 * Two carriers mean the same thing. Positions are what this card writes when the
 * bridge says the slot will take them. The options written out and joined are what
 * every earlier card writes, and are still published whenever they fit, so both have
 * to read back here.
 *
 * The joined form is matched whole rather than split on the separator: an option's
 * own text may contain " + ", and then two different answers look identical. The
 * bridge refuses to split for the same reason.
 */
function multiSelectPick(options, separator, state) {
  if (!state || options.length === 0 || options.length > 20) { return []; }
  if (CHOICE_CODE_PATTERN.test(state)) {
    const seen = new Set();
    const picked = [];
    for (const part of state.slice(1).split(',')) {
      const index = Number(part) - 1;
      // Out of range or repeated is malformed, not something to make the best of:
      // showing a set nobody picked is how a wrong answer gets sent.
      if (!(index >= 0 && index < options.length) || seen.has(index)) { return []; }
      seen.add(index);
    }
    for (const index of Array.from(seen).sort((a, b) => a - b)) { picked.push(options[index]); }
    return picked;
  }
  for (let mask = 1; mask < (1 << options.length); mask++) {
    const picked = options.filter((_, i) => mask & (1 << i));
    if (picked.join(separator) === state) { return picked; }
  }
  return [];
}

class AgentBridgeChoicesCard extends HTMLElement {
  constructor() {
    super();
    this.attachShadow({ mode: 'open' });
    this._last = '';
    this._sent = '';
    this._fields = [];
    // What has been tapped but not yet seen coming back from Home Assistant.
    // {} when everything on screen is confirmed.
    //
    // Two taps in quick succession used to compute from the same state, because the
    // second ran before the first had been pushed back: ticking Auth then Search
    // sent "Auth" and then "Search", losing Auth. Send had the matching problem -
    // pressed straight after a tap it committed whatever the slot still held. A
    // service call completing and the state actually arriving are separate events,
    // so the pending set is what later taps compose from and what holds Send.
    this._pending = {};
    // Counts taps, so a reply arriving late can be matched to the one that caused
    // it. The question id cannot do that job: two taps on one question share it.
    this._op = 0;
    // Every write still outstanding, by entity. The pending set holds only the
    // *latest* value asked for, so an earlier write that has not come back is
    // invisible to it: ticking a row and unticking it leaves two calls in flight, and
    // acknowledging the second released Send while the first could still land and tick
    // the row back on. Send is held while anything at all is outstanding.
    this._inflight = {};
    this._note = '';
  }

  setConfig(config) {
    if (!config || !config.decision) {
      throw new Error('agent-bridge-choices-card: "decision" is required');
    }
    this._config = Object.assign({}, config);
    // A single-choice question has no fields; a form has up to four, and the unused
    // slots stay parked on Idle rather than being deleted, so the list is fixed.
    this._fields = Array.isArray(config.fields) ? config.fields.map(String).filter(Boolean) : [];
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
        /* A field's own heading, so a form of three-option groups reads as three
           questions rather than one long list of unrelated answers. */
        .label {
          font-size: 0.85em; font-weight: 500; color: var(--secondary-text-color);
          margin: 4px 0 -2px 2px; overflow-wrap: anywhere;
        }
        .label:first-child { margin-top: 0; }
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
        /* A form is answered field by field and only sent with Send, so what has
           already been picked has to stay visible while the rest is filled in. */
        button.chosen {
          border-color: var(--primary-color); border-width: 2px; padding: 9px 11px;
          background: var(--primary-color); color: var(--text-primary-color, #fff);
        }
        button.cancel {
          color: var(--secondary-text-color); background: none;
          min-height: 36px; font-size: 0.92em;
        }
        /* Send answer. A form is only sent when this is pressed, so it has to read
           as the one thing that acts rather than as another option to weigh. */
        button.send {
          border-color: var(--primary-color); color: var(--primary-color);
          font-weight: 600; text-align: center; margin-top: 2px;
        }
        /* While the answer is on its way, so a second tap cannot send another. */
        .choices.sending button { opacity: 0.5; cursor: default; pointer-events: none; }
        /* A tap that Home Assistant has not confirmed yet. The rows stay live so a
           choice can still be changed, but Send is held until what is on screen is
           known to be what the daemon will read. */
        button.send[disabled] { opacity: 0.45; cursor: default; }
        .note {
          font-size: 0.82em; color: var(--secondary-text-color);
          margin: 2px 2px 0 2px; overflow-wrap: anywhere;
        }
        .note.err { color: var(--error-color, #ff5252); }
        [hidden] { display: none !important; }
      </style>
      <ha-card><div class="choices"></div></ha-card>`;
    this._els = { list: this.shadowRoot.querySelector('.choices') };
  }

  /*
   * What one select entity is offering, or null when it is carrying nothing.
   *
   * The two placeholders are dropped here rather than at the call site: they are
   * parked states the bridge drives the entity to so that "waiting" is a state and
   * not merely an absence, and offering either as an answer would send the prompt
   * the word 'Choose...'.
   */
  _armed(entityId) {
    const entity = this._hass ? this._hass.states[entityId] : undefined;
    if (!entity) { return null; }
    const state = String(entity.state);
    if (CHOICE_UNARMED.indexOf(state) !== -1) { return null; }
    const attributes = entity.attributes || {};
    const options = Array.isArray(attributes.options)
      ? attributes.options.map(String).filter((o) => o && o !== CHOICE_PLACEHOLDER && o !== CHOICE_FIELD_PLACEHOLDER)
      : [];
    if (options.length === 0) { return null; }
    return {
      entityId,
      state,
      options,
      label: '',
      // A field still on its placeholder has not been answered yet.
      chosen: (state === CHOICE_PLACEHOLDER || state === CHOICE_FIELD_PLACEHOLDER) ? '' : state,
    };
  }

  _render() {
    if (!this._built) { this._build(); }

    const decisionEntity = this._hass ? this._hass.states[this._config.decision] : undefined;
    const decisionAttrs = (decisionEntity && decisionEntity.attributes) || {};
    // Every pending tap is tied to the question it was made on, so a question that
    // is replaced or withdrawn can never have a stale selection sent against it.
    const generation = String(decisionAttrs.decision_id || '');
    for (const key of Object.keys(this._pending)) {
      if (this._pending[key].generation !== generation) { delete this._pending[key]; }
    }
    // A write still in flight for a question that has been replaced cannot answer the
    // one now on screen, so it must not hold its Send either. Home Assistant refuses
    // a value the republished slot no longer offers, so it cannot quietly land in it.
    for (const key of Object.keys(this._inflight)) {
      const set = this._inflight[key];
      for (const op of Object.keys(set)) {
        if (set[op] !== generation) { delete set[op]; }
      }
      if (Object.keys(set).length === 0) { delete this._inflight[key]; }
    }

    // Fields first, then whatever the main selector offers - which on a form is only
    // 'Cancel request'. A field group is shown only while it is carrying options, so
    // a two-field question renders exactly two groups and the spare slots stay away.
    //
    // The heading comes from the decision entity's field_<n>_label attribute, which
    // is where the bridge has published the labels since the per-field dropdowns
    // existed. The field entity's own friendly_name cannot be used: Home Assistant
    // builds it from the device name plus the entity name, so every heading would
    // start with the session's whole title.
    const fields = [];
    this._fields.forEach((entityId, i) => {
      const armed = this._armed(entityId);
      if (!armed) { return; }
      armed.label = String(decisionAttrs[`field_${i + 1}_label`] || '');
      // A multi-select slot can only hold whole combinations, because a Home
      // Assistant select holds one value. What it is really offering rides on the
      // decision attributes beside the heading, so the rows drawn here are those
      // options and the slot is given the one label that stands for what is ticked.
      if (decisionAttrs[`field_${i + 1}_multi`]) {
        const base = []
          .concat(decisionAttrs[`field_${i + 1}_options`] || [])
          .map(String)
          .filter(Boolean);
        if (base.length > 0) {
          armed.multi = true;
          armed.separator = String(decisionAttrs[`field_${i + 1}_separator`] || CHOICE_MULTI_SEPARATOR);
          // Whether this slot will take positions. Absent from an older bridge, which
          // only ever published the options written out, so the words stay the default.
          armed.codes = !!decisionAttrs[`field_${i + 1}_codes`];
          armed.slotOptions = armed.options;
          armed.options = base;
          armed.picked = multiSelectPick(base, armed.separator, armed.chosen);
        }
      }
      fields.push(armed);
    });

    const decision = this._armed(this._config.decision);
    const groups = fields.slice();
    if (decision) { groups.push(Object.assign({}, decision, { isDecision: true })); }

    // Send answer commits whatever is ticked. It is drawn whenever the view has
    // given this card a submit entity and there is something to commit - a field, or
    // a main selector carrying its own choices, which is the legacy and lone-Claude
    // shape. Cancel is not one of those: withdrawing a question is its own act.
    const commits = fields.length > 0 ||
      !!(decision && decision.options.some((o) => o !== CHOICE_CANCEL));
    const sends = !!(this._config.submit && commits);

    const show = groups.length > 0;
    this.hidden = !show;
    if (!show) { this._sent = ''; this._pending = {}; this._inflight = {}; this._note = ''; return; }

    // What has been tapped and not yet confirmed. A slot is only settled once Home
    // Assistant has both accepted the call and shown the value it was asked for.
    //
    // Matching the state alone released it too early in two ways. Toggling a row on
    // and straight back off asks for the value the slot already holds, so it looked
    // settled before the untick had been accepted at all - and if that call then
    // failed, Send went with the row still ticked underneath. An older acknowledgement
    // arriving after a newer tap did the same thing from the other direction.
    for (const group of groups) {
      const pending = this._pending[group.entityId];
      if (!pending) { continue; }
      if (pending.acked && pending.value === group.state) { delete this._pending[group.entityId]; }
      else if (group.multi) { group.picked = pending.picked.slice(); }
      else { group.chosen = pending.value; }
    }
    const waiting = Object.keys(this._pending).length > 0 || Object.keys(this._inflight).length > 0;
    if (!waiting && this._note === CHOICE_SAVING_NOTE) { this._note = ''; }
    if (waiting && !this._note) { this._note = CHOICE_SAVING_NOTE; }

    // The answer has landed once the selector is no longer parked on the placeholder.
    if (this._sent && (!decision || decision.state !== CHOICE_PLACEHOLDER)) { this._sent = ''; }
    this._els.list.classList.toggle('sending', !!this._sent);

    // Every field's current value is in the signature, so picking one redraws the
    // form and the tick moves. Without it the card short-circuits on an unchanged
    // option list and a tap appears to do nothing at all. The pending set and the
    // note are in it too, so holding Send and saying why are drawn as they happen.
    const signature = groups
      .map((g) => `${g.entityId}\u0002${g.chosen}\u0002${g.label}\u0002${g.multi ? 'm' : 's'}\u0002${g.options.join('\u0001')}\u0002${g.multi ? g.picked.join('\u0001') : ''}`)
      .join('\u0003') + `\u0004${sends}\u0004${waiting}\u0004${this._note}`;
    if (signature === this._last) { return; }
    this._last = signature;

    this._els.list.textContent = '';
    let cancel = null;
    for (const group of groups) {
      // Only when it says something the rows do not. A lone single-choice group's
      // heading is the field name, which on its own card only repeats the question
      // already above it; "(pick any)" is the one thing no row can say.
      const heading = group.label && (group.multi || fields.length > 1)
        ? (group.multi ? `${group.label} (pick any)` : group.label)
        : '';
      if (heading) {
        const label = document.createElement('div');
        label.classList.add('label');
        label.textContent = heading;
        this._els.list.appendChild(label);
      }
      for (const option of group.options) {
        const button = document.createElement('button');
        button.type = 'button';
        button.textContent = option;
        if (option === CHOICE_CANCEL) { button.classList.add('cancel'); }
        else if (group.multi ? group.picked.indexOf(option) >= 0 : option === group.chosen) {
          button.classList.add('chosen');
        }
        button.addEventListener('click', () => this._choose(group, option));
        // Held back so it stays the quiet last row. Send is the thing being looked
        // for after a tap; withdrawing the question is not, and putting it in
        // between would make it the easiest row to hit by mistake.
        if (option === CHOICE_CANCEL) { cancel = button; continue; }
        this._els.list.appendChild(button);
      }
    }
    if (sends) {
      const send = document.createElement('button');
      send.type = 'button';
      send.classList.add('send');
      send.textContent = 'Send answer';
      if (waiting) { send.setAttribute('disabled', 'disabled'); }
      send.addEventListener('click', () => this._send());
      this._els.list.appendChild(send);
    }
    if (cancel) { this._els.list.appendChild(cancel); }
    if (this._note) {
      const note = document.createElement('div');
      note.className = this._note === CHOICE_SAVING_NOTE ? 'note' : 'note err';
      note.textContent = this._note;
      this._els.list.appendChild(note);
    }
  }

  /*
   * A tap changes what will be sent; it does not send. Everything waits for Send
   * answer now - a single choice, a whole form, and a multi-select field's rows,
   * which tick and untick until they say what you mean. Only Cancel still acts on
   * the tap, because withdrawing a question is a deliberate act in itself.
   *
   * The tap composes from the pending set rather than from the entity, so two taps
   * in a row build one answer instead of the second overwriting the first.
   */
  _choose(group, option) {
    if (this._sent || !this._hass) { return; }
    const generation = String(
      ((this._hass.states[this._config.decision] || {}).attributes || {}).decision_id || '');
    // Each tap is its own operation. The question id alone is not enough to tell
    // them apart: two taps on the same question share it, so a rejection arriving
    // late for the first used to delete the second's tick and send the answer
    // without it.
    const op = ++this._op;
    let value = option;
    let picked = null;
    if (group.multi) {
      picked = group.picked.indexOf(option) >= 0
        ? group.picked.filter((o) => o !== option)
        : group.options.filter((o) => group.picked.indexOf(o) >= 0 || o === option);
      // Nothing ticked is not an answer, so the slot goes back to its placeholder and
      // the daemon reads the field as still unanswered rather than as an empty set.
      if (picked.length === 0) { value = CHOICE_FIELD_PLACEHOLDER; }
      // Positions where the bridge said the slot will take them, because the options
      // written out may be far longer than a select entry can hold - which is what
      // used to send an ordinarily-worded question to the terminal instead.
      else if (group.codes) { value = multiSelectCode(group.options, picked); }
      else { value = picked.join(group.separator); }
    }
    else if (group.isDecision && option === CHOICE_CANCEL) {
      this._sent = option;
      this._els.list.classList.add('sending');
    }

    if (!(group.isDecision && option === CHOICE_CANCEL)) {
      this._pending[group.entityId] = { value, picked: picked || [], generation, op, acked: false };
      this._note = CHOICE_SAVING_NOTE;
      this._last = '';
      this._render();
    }

    let call;
    try { call = this._hass.callService('select', 'select_option', { entity_id: group.entityId, option: value }); }
    catch (err) { this._failPending(group.entityId, op, err); return; }
    if (!call || typeof call.then !== 'function') { return; }
    this._track(group.entityId, op, true, generation);
    call.then(
      () => {
        // Accepted. Only this tap's own acknowledgement counts: an older one arriving
        // after a newer tap must not settle the newer one. Usually the new state
        // arrives separately and clears it, but when the slot already held the value
        // nothing further is coming, so this redraw is what stops Send being held for
        // ever.
        this._track(group.entityId, op, false);
        const pending = this._pending[group.entityId];
        if (pending && pending.op === op) { pending.acked = true; }
        this._last = '';
        this._render();
      },
      // A rejected call must take its own tick back with it, and only its own.
      (err) => { this._track(group.entityId, op, false); this._failPending(group.entityId, op, err); });
  }

  /* Adds or removes one outstanding write, tied to the question it was made on. */
  _track(entityId, op, outstanding, generation) {
    const set = this._inflight[entityId] || (this._inflight[entityId] = {});
    if (outstanding) { set[op] = generation; }
    else { delete set[op]; }
    if (Object.keys(set).length === 0) { delete this._inflight[entityId]; }
  }

  /*
   * Drops a tap Home Assistant would not take, and says so.
   *
   * Only if that exact tap is still the pending one. An older failure arriving after
   * a newer tap must leave the newer tick alone: clearing it would show the answer
   * as saved while the card quietly held something else.
   */
  _failPending(entityId, op, err) {
    const pending = this._pending[entityId];
    if (!pending || pending.op !== op) { return; }
    delete this._pending[entityId];
    this._note = `Home Assistant would not take that: ${describeThrown(err)}`;
    this._last = '';
    this._render();
  }

  /*
   * Sends the answer. Held while anything is still unconfirmed, because pressing it
   * then would commit whatever the slot held before the last tap.
   *
   * Deliberately not locked the way Cancel is: the daemon refuses an incomplete form
   * and says which field is still waiting, and a row that had locked itself would
   * leave no way to go and answer it. A press Home Assistant refuses is said out
   * loud for the same reason - a Send that silently did nothing is indistinguishable
   * from one the session is still thinking about.
   */
  _send() {
    if (this._sent || !this._hass || !this._config.submit) { return; }
    // Nothing outstanding, in either sense: no tap waiting to be shown, and no write
    // still in flight that could land afterwards and change what is about to be sent.
    if (Object.keys(this._pending).length > 0) { return; }
    if (Object.keys(this._inflight).length > 0) { return; }
    let call;
    try { call = this._hass.callService('button', 'press', { entity_id: this._config.submit }); }
    catch (err) { this._failSend(err); return; }
    if (call && typeof call.then === 'function') { call.then(() => {}, (err) => this._failSend(err)); }
  }

  _failSend(err) {
    this._note = `Send failed: ${describeThrown(err)}`;
    this._last = '';
    this._render();
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
          transition: border-color 0.4s ease, box-shadow 0.4s ease;
          /* Children draw no surface of their own. */
          --ha-card-background: transparent;
          --ha-card-box-shadow: none;
          --ha-card-border-width: 0;
          --ha-card-border-color: transparent;
        }
        /* The steady core of the glow. Static, so it is painted once when the state
           changes; the breathing halo on top of it is .glow, below. */
        .frame.working { border-color: var(--primary-color); box-shadow: 0 0 6px 0 var(--primary-color); }
        .frame.waiting { border-color: var(--warning-color); box-shadow: 0 0 6px 0 var(--warning-color); }
        /* Driven through Home Assistant by an agent rather than by you. The pulse is
           the same shape so "something is happening" still reads at a glance; only
           the colour changes, and it holds a steady purple edge while idle so a
           session left under an agent's control still says so. */
        .frame.agent { border-color: var(--agent-bridge-agent-color, #a855f7); }
        .frame.agent.working,
        .frame.agent.waiting {
          border-color: var(--agent-bridge-agent-color, #a855f7);
          box-shadow: 0 0 6px 0 var(--agent-bridge-agent-color, #a855f7);
        }
        /*
         * The halo is a layer of its own holding a shadow that never changes, faded
         * in and out by its opacity - not a box-shadow animated on the frame.
         *
         * box-shadow is not a property the compositor can animate, so the old
         * keyframes repainted the entire card on the main thread on every frame, for
         * as long as the session was working. Four sessions working at once meant
         * four full-card repaints 60 times a second that no state change had asked
         * for, and Home Assistant - a tab that stays open for days - stuttered and
         * hung. Opacity is composited on the GPU: the card is rastered once and the
         * main thread does nothing for the rest of the pulse.
         *
         * It has to be a sibling of the frame rather than a child. The frame's
         * overflow: hidden - which keeps the children's square corners inside the
         * rounded edge - would clip a glow drawn inside it to nothing.
         */
        .shell { position: relative; }
        .glow {
          position: absolute;
          inset: 0;
          border-radius: var(--ha-card-border-radius, 12px);
          opacity: 0;
          pointer-events: none;
        }
        .frame.working ~ .glow,
        .frame.waiting ~ .glow {
          animation: cpglow 1.6s ease-in-out infinite;
          /* Only while it is actually pulsing. A promoted layer costs texture memory
             whether or not it moves, and most sessions on the dashboard are idle. */
          will-change: opacity;
        }
        .frame.working ~ .glow { box-shadow: 0 0 16px 2px var(--primary-color); }
        .frame.waiting ~ .glow { box-shadow: 0 0 18px 3px var(--warning-color); }
        .frame.agent.working ~ .glow,
        .frame.agent.waiting ~ .glow { box-shadow: 0 0 18px 3px var(--agent-bridge-agent-color, #a855f7); }
        @keyframes cpglow {
          0%, 100% { opacity: 0; }
          50%      { opacity: 1; }
        }
        /* The breathing is decoration. A viewer who asked for less motion keeps the
           colour and the glow, held at the middle of the pulse. */
        @media (prefers-reduced-motion: reduce) {
          .frame.working ~ .glow,
          .frame.waiting ~ .glow { animation: none; opacity: 0.6; will-change: auto; }
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
      <div class="shell">
        <div class="frame">
          <button class="fold" aria-expanded="true" title="Collapse"><ha-icon icon="mdi:chevron-down"></ha-icon></button>
          <div class="body"></div>
        </div>
        <div class="glow" aria-hidden="true"></div>
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
// The three per-launch settings, in the order the card shows them. Their options
// belong to the selected agent and the daemon republishes them when it moves, so the
// card only ever renders whatever the entity currently offers.
const LAUNCH_TUNING = ['model', 'effort', 'context'];
// The option that means "pass nothing and let the agent decide". Worth a row, but
// not worth a word in the collapsed summary.
const LAUNCH_TUNING_DEFAULT = 'Agent default';
// Permissions. The cautious option is the selector's first, and is not worth a word
// in the collapsed summary - "Allow all" is, because it is the one worth noticing
// before pressing Launch.
const LAUNCH_ALLOW_ALL = 'Allow all';

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
        /* The prompt box takes a whole handover, so it grows instead of scrolling a
           single line, and resizes vertically only - a horizontal drag would push it
           out of the card on a phone. */
        textarea[data-key="prompt"] {
          min-width: 0; box-sizing: border-box; padding: 7px 8px;
          font: inherit; color: var(--primary-text-color);
          background: var(--secondary-background-color, rgba(127,127,127,0.1));
          border: 1px solid var(--divider-color); border-radius: 8px;
          resize: vertical; min-height: 34px; max-height: 40vh;
        }
        select:focus, input:focus, textarea:focus { outline: none; border-color: var(--primary-color); }
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
          <label class="f-model"><span>Model</span><select data-key="model"></select></label>
          <label class="f-effort"><span>Effort</span><select data-key="effort"></select></label>
          <label class="f-context"><span>Context</span><select data-key="context"></select></label>
          <label class="f-permissions"><span>Permissions</span><select data-key="permissions"></select></label>
          <label class="f-prompt wide"><span>First message (optional)</span><textarea data-key="prompt" rows="3" placeholder="Start with a task, or paste the full context to hand over"></textarea></label>
        </div>
        <div class="note" hidden><span class="spin"></span><span class="text"></span></div>
      </ha-card>`;
    const $ = (s) => this.shadowRoot.querySelector(s);
    this._els = {
      card: $('ha-card'), toggle: $('.toggle'), name: $('.name'), summary: $('.summary'),
      launch: $('button.launch'), fields: $('.fields'), note: $('.note'), spin: $('.note .spin'), text: $('.note .text'),
      prompt: $('textarea[data-key="prompt"]'),
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
    // Enter now starts a new line: the box takes a whole handover, not one line. So
    // the keyboard shortcut moves to Ctrl/Cmd+Enter, which is what the reply box
    // already uses for the same reason.
    this._els.prompt.addEventListener('keydown', (ev) => {
      if (ev.key === 'Enter' && (ev.ctrlKey || ev.metaKey)) { ev.preventDefault(); this._launch(); }
    });
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
      //
      // Over MQTT when the machine offers the topic, because a text entity is capped
      // at 255 characters and a handover prompt is routinely longer than that - it
      // used to be truncated on the way through, with nothing to say so. The text
      // entity is still written when there is no topic, so a dashboard talking to an
      // older bridge keeps working.
      const typed = this._els.prompt.value.trim();
      if (m.promptTopic) {
        await this._hass.callService('mqtt', 'publish', {
          topic: m.promptTopic,
          payload: JSON.stringify({ at: new Date().toISOString(), text: typed, card_version: CARD_VERSION }),
          qos: 0,
          retain: true,
        });
      }
      else if (m.prompt && typed !== this._state(m.prompt).trim()) {
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
    for (const axis of LAUNCH_TUNING) {
      this._fill(q(`select[data-key="${axis}"]`), m[axis], q(`.f-${axis}`));
    }
    this._fill(q('select[data-key="permissions"]'), m.permissions, q('.f-permissions'));

    // A resume brings its own agent and folder, so those choices step back.
    const resume = m.resume ? this._state(m.resume) : '';
    const resuming = !!resume && resume !== LAUNCH_FRESH && !['unknown', 'unavailable'].includes(resume);
    const agent = m.agent ? this._state(m.agent) : '';
    q('.f-agent').classList.toggle('dim', resuming);
    q('.f-workspace').classList.toggle('dim', resuming);
    // The profile applies only under Agency.
    if (m.agent && agent && agent !== 'Agency') { q('.f-profile').hidden = true; }

    // Model, effort and context still apply to a resume - they are options of this
    // launch, not properties of the conversation - so unlike agent and workspace they
    // are not dimmed. An axis left at 'Agent default' is not worth a line in the
    // summary, but the row itself stays, because it is how you change it.
    const tuning = LAUNCH_TUNING
      .map((axis) => (m[axis] ? this._state(m[axis]) : ''))
      .filter((value) => value && value !== LAUNCH_TUNING_DEFAULT && !['unknown', 'unavailable'].includes(value));

    // Restore a prompt typed on another device, but only when the text entity is
    // what carries it. With the payload topic the box is the source of truth and the
    // entity is left blank, so reading it back would wipe what is being typed here.
    const promptState = m.promptTopic ? '' : this._state(m.prompt);
    if (!m.promptTopic && this.shadowRoot.activeElement !== this._els.prompt && !this._els.prompt.value &&
        promptState.trim() && !['unknown', 'unavailable'].includes(promptState)) {
      this._els.prompt.value = promptState.trim();
    }

    const workspace = this._state(m.workspace);
    const bits = resuming ? [`Resume: ${resume}`] : [agent, workspace].filter((b) => b && !['unknown', 'unavailable'].includes(b));
    if (machines.length > 1) { bits.unshift(m.machine); }
    // Allow all earns a place in the collapsed summary; asking is the quiet default
    // and would only be noise. It applies to a resume too, so it sits outside that
    // branch.
    const permissions = m.permissions ? this._state(m.permissions) : '';
    const extras = permissions === LAUNCH_ALLOW_ALL ? tuning.concat(LAUNCH_ALLOW_ALL) : tuning;
    this._els.summary.textContent = bits.concat(extras).join(' · ');
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

/*
 * The dashboard's top card: how much is running, what is waiting on you, and the
 * machines it is all running on.
 *
 * It replaces a markdown summary card plus a separate Machines card - two cards that
 * between them took a third of a phone screen to say "three sessions, nothing
 * waiting". Folded it is one line of each; opened it is a row per machine, with that
 * machine's Detailed activity switch beside the name it belongs to - or, when the
 * machine is not running, an X that removes it from the dashboard for good.
 *
 * The counts are worked out here rather than by a Jinja template, so they follow
 * state as it arrives. A template is re-rendered by Home Assistant too, but its
 * *entity list* is fixed when the dashboard is generated, so a machine that came
 * online since the last rebuild was missing from the sum until the next one.
 */
// Decision states that are not a question waiting on an answer.
const STATUS_QUIET = ['Idle', 'unavailable', 'unknown', ''];
// How long a flicked switch holds its new position while the service call lands.
// Without it the next render - which can arrive before Home Assistant has changed
// the state - snaps the switch back, and it visibly bounces.
const STATUS_TOGGLE_GRACE = 5000;
// How long the X on an offline machine stays armed after the first tap. Removing a
// machine is not undoable from the dashboard, and the X sits where a Detail switch
// sits on every other row, so it asks once before doing anything.
const STATUS_FORGET_CONFIRM = 6000;

class AgentBridgeStatusCard extends HTMLElement {
  constructor() {
    super();
    this.attachShadow({ mode: 'open' });
    this._rows = [];
    try { this._open = localStorage.getItem('agent-bridge-status-open') === '1'; } catch (e) { this._open = false; }
  }

  setConfig(config) {
    if (!config || !Array.isArray(config.machines) || config.machines.length === 0) {
      throw new Error('agent-bridge-status-card: "machines" is required');
    }
    this._config = Object.assign({ title: 'Agent sessions', decisions: [] }, config);
    this._built = false;
    if (this._hass) { this._build(); this._render(); }
  }

  set hass(hass) {
    this._hass = hass;
    if (!this._built) { this._build(); }
    this._render();
  }

  getCardSize() { return this._open ? 1 + this._config.machines.length : 1; }

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
        /* A question waiting on you is the one thing here worth colouring. */
        .summary.waiting { color: var(--warning-color); }
        .machines { margin-top: 8px; }
        .row { display: flex; align-items: center; gap: 10px; padding: 7px 0; border-top: 1px solid var(--divider-color); }
        /* A dot rather than 🟢/⚪: the same reason as the chevron above, and it takes
           the theme's colours instead of the platform's idea of green. */
        .dot { flex: none; width: 10px; height: 10px; border-radius: 50%; background: var(--disabled-text-color, #9e9e9e); }
        .row.online .dot { background: var(--success-color, #4caf50); }
        .who { flex: 1; min-width: 0; }
        .name { font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .meta { font-size: 0.85em; color: var(--secondary-text-color); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .detail { display: flex; align-items: center; gap: 6px; flex: none; font-size: 0.85em; color: var(--secondary-text-color); }
        /* The X sits exactly where the Detail switch does, because an offline machine
           has nothing to switch and a machine that is gone has to be removable. */
        .forget { flex: none; display: flex; align-items: center; }
        .forget button {
          display: inline-flex; align-items: center; gap: 4px; cursor: pointer;
          font: inherit; font-size: 0.85em; padding: 3px 8px; border-radius: 14px;
          background: none; border: 1px solid transparent; color: var(--secondary-text-color);
        }
        .forget button:hover { color: var(--error-color, #f44336); }
        .forget button.confirm { color: var(--error-color, #f44336); border-color: var(--error-color, #f44336); }
        .forget ha-icon { --mdc-icon-size: 20px; }
        [hidden] { display: none !important; }
      </style>
      <ha-card>
        <div class="head">
          <div class="toggle" role="button" tabindex="0" aria-expanded="false">
            <div class="title"><ha-icon class="chev" icon="mdi:chevron-right"></ha-icon><span class="name"></span></div>
            <div class="summary"></div>
          </div>
        </div>
        <div class="machines" hidden></div>
      </ha-card>`;
    const $ = (s) => this.shadowRoot.querySelector(s);
    this._els = {
      card: $('ha-card'), toggle: $('.toggle'), name: $('.name'),
      summary: $('.summary'), machines: $('.machines'),
    };
    this._els.name.textContent = this._config.title;

    const flip = () => {
      this._open = !this._open;
      try { localStorage.setItem('agent-bridge-status-open', this._open ? '1' : '0'); } catch (e) { /* per-viewer nicety only */ }
      this._render();
    };
    this._els.toggle.addEventListener('click', flip);
    this._els.toggle.addEventListener('keydown', (ev) => { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); flip(); } });

    this._buildRows();
  }

  // One row per machine, built once. The machine list only changes when the daemon
  // regenerates the dashboard, and that hands the card a fresh config.
  _buildRows() {
    const host = this._els.machines;
    host.textContent = '';
    this._rows = this._config.machines.map((machine) => {      const row = document.createElement('div');
      row.className = 'row';
      const dot = document.createElement('span');
      dot.className = 'dot';
      const who = document.createElement('div');
      who.className = 'who';
      const name = document.createElement('div');
      name.className = 'name';
      name.textContent = machine.machine || '';
      const meta = document.createElement('div');
      meta.className = 'meta';
      who.appendChild(name);
      who.appendChild(meta);
      row.appendChild(dot);
      row.appendChild(who);
      const entry = { machine, row, meta, toggle: null, detail: null, forget: null, pendingAt: 0, pendingFrom: '' };
      // A machine running a bridge from before the switch existed reports no entity
      // for it and gets no switch - drawing one anyway would point at nothing.
      if (machine.detailed) {
        const box = document.createElement('div');
        box.className = 'detail';
        const label = document.createElement('span');
        label.textContent = 'Detail';
        const toggle = document.createElement('ha-switch');
        toggle.addEventListener('change', () => this._flipDetail(entry));
        box.appendChild(label);
        box.appendChild(toggle);
        row.appendChild(box);
        entry.toggle = toggle;
        entry.detail = box;
      }
      // And the X, for when that machine is not running. It is given the topics to
      // clear rather than the machine's name, so the card never has to know how the
      // bridge names anything: the dashboard that drew this row worked them out from
      // the same lists an uninstall walks.
      if (Array.isArray(machine.forget) && machine.forget.length) {
        const box = document.createElement('div');
        box.className = 'forget';
        const button = document.createElement('button');
        const icon = document.createElement('ha-icon');
        icon.setAttribute('icon', 'mdi:close');
        button.appendChild(icon);
        button.setAttribute('title', `Remove ${machine.machine || 'this machine'} from the dashboard`);
        button.setAttribute('aria-label', `Remove ${machine.machine || 'this machine'} from the dashboard`);
        button.addEventListener('click', () => this._forget(entry));
        box.appendChild(button);
        box.hidden = true;
        row.appendChild(box);
        entry.forget = box;
        entry.forgetButton = button;
        entry.forgetIcon = icon;
        entry.forgetArmedAt = 0;
        entry.forgetBusy = false;
      }
      host.appendChild(row);
      return entry;
    });
    this._ensureSwitchElement();
  }

  /*
   * ha-switch lives in a lazily loaded chunk of the Home Assistant frontend, pulled
   * in by whichever card first draws a toggle row. This card replaced the entities
   * card that used to do that, so on a view with no other switch the element could
   * be undefined and the switches would render as nothing at all. Asking the card
   * helpers for a row on an input_boolean imports that chunk; the row itself is
   * thrown away.
   */
  _ensureSwitchElement() {
    const probe = (this._config.machines.find((m) => m.detailed) || {}).detailed;
    if (!probe || customElements.get('ha-switch') || typeof window.loadCardHelpers !== 'function') { return; }
    window.loadCardHelpers()
      .then((helpers) => helpers.createRowElement({ entity: probe }))
      .catch(() => { /* drawn anyway wherever the chunk is already loaded */ });
  }

  _state(entityId) {
    const s = entityId && this._hass ? this._hass.states[entityId] : undefined;
    return s ? String(s.state) : '';
  }

  _attr(entityId, name) {
    const s = entityId && this._hass ? this._hass.states[entityId] : undefined;
    return s && s.attributes && s.attributes[name] ? String(s.attributes[name]) : '';
  }

  _count(entityId) {
    const value = parseInt(this._state(entityId), 10);
    return Number.isFinite(value) && value > 0 ? value : 0;
  }

  _flipDetail(entry) {
    const entityId = entry.machine.detailed;
    if (!entityId || !this._hass) { return; }
    entry.pendingAt = Date.now();
    entry.pendingFrom = this._state(entityId);
    this._hass.callService(entityId.split('.')[0], 'toggle', { entity_id: entityId });
  }

  // The X's label: the icon when it is idle, a word while it is armed or working.
  // Assigning textContent drops the icon, which is exactly what a browser does too,
  // so it is put back rather than hidden.
  _setForgetLabel(entry, text) {
    const button = entry.forgetButton;
    if (!button) { return; }
    button.textContent = text || '';
    if (!text) { button.appendChild(entry.forgetIcon); }
    button.classList.toggle('confirm', !!text);
  }

  _resetForget(entry) {
    if (!entry.forget || entry.forgetBusy) { return; }
    entry.forgetArmedAt = 0;
    this._setForgetLabel(entry, '');
  }

  /*
   * First tap arms, second removes. There is no undo from here: the machine's
   * retained topics are cleared, which is what makes Home Assistant drop its
   * entities. A machine that is merely switched off republishes all of it when it
   * comes back, so the cost of a mistake is a row that returns - but a machine that
   * has been renamed or reimaged never does, and that is what this is for.
   */
  _forget(entry) {
    if (!entry.forget || entry.forgetBusy || !this._hass) { return undefined; }
    const armed = entry.forgetArmedAt && Date.now() - entry.forgetArmedAt < STATUS_FORGET_CONFIRM;
    if (!armed) {
      entry.forgetArmedAt = Date.now();
      this._setForgetLabel(entry, 'Remove?');
      setTimeout(() => this._resetForget(entry), STATUS_FORGET_CONFIRM);
      return undefined;
    }
    entry.forgetArmedAt = 0;
    // Returned so a caller that needs the publishes finished - the tests - can wait
    // for them. A click handler simply ignores it.
    return this._publishForget(entry);
  }

  async _publishForget(entry) {
    entry.forgetBusy = true;
    this._setForgetLabel(entry, 'Removing...');
    try {
      // An empty retained payload is how a retained topic is withdrawn, and how the
      // bridge itself clears every one of these on uninstall.
      for (const topic of entry.machine.forget) {
        await this._hass.callService('mqtt', 'publish', { topic, payload: '', retain: true, qos: 1 });
      }
      // The daemon rebuilds the dashboard within a reconcile and the row goes with
      // it; hiding it now is so the tap has an answer before then.
      entry.row.hidden = true;
      entry.forgetBusy = false;
      this._setForgetLabel(entry, '');
    }
    catch (e) {
      entry.forgetBusy = false;
      this._setForgetLabel(entry, 'Failed');
    }
  }

  _render() {
    if (!this._els || !this._hass || !this._config) { return; }
    this._els.card.classList.toggle('open', this._open);
    this._els.toggle.setAttribute('aria-expanded', this._open ? 'true' : 'false');
    this._els.machines.hidden = !this._open;

    let live = 0;
    let soloVersion = '';
    for (const entry of this._rows) {
      const machine = entry.machine;
      // No liveness entity at all means the caller is not tracking it, so the machine
      // is taken as running - which is what a bridge from before the sensor did.
      const online = !machine.online || this._state(machine.online) === 'on';
      // An offline machine's sessions are hidden, because none of them can be
      // running; counting its retained sensor would keep a dead machine's sessions
      // in the total indefinitely.
      const count = online ? this._count(machine.sessions) : 0;
      live += count;
      const version = this._attr(machine.version, 'installed_version') || '?';
      // "(dev)" marks a machine installed from a working copy. VERSION only moves
      // when a release is cut, so two machines days apart in features otherwise read
      // as the same number.
      const stamp = `${version}${machine.dev ? ' (dev)' : ''}`;
      if (this._rows.length === 1) { soloVersion = stamp; }
      entry.row.classList.toggle('online', online);
      entry.meta.textContent = online
        ? `${count} session${count === 1 ? '' : 's'} \u00b7 ${stamp}`
        : 'offline';

      if (entry.toggle) {
        const value = this._state(machine.detailed);
        const settled = !entry.pendingAt ||
          value !== entry.pendingFrom ||
          Date.now() - entry.pendingAt > STATUS_TOGGLE_GRACE;
        if (settled) {
          entry.pendingAt = 0;
          entry.toggle.checked = value === 'on';
        }
        entry.toggle.disabled = value !== 'on' && value !== 'off';
      }

      // An offline machine is shown the X instead of its Detail switch. The switch is
      // a Home Assistant helper, so it can still be set for when the machine comes
      // back - but the row it sits on is one line on a phone, and what you want from
      // a machine that is not running is the ability to say it is not coming back.
      // A row with no X keeps its switch, which is every dashboard drawn by a bridge
      // older than this.
      if (entry.forget) {
        entry.forget.hidden = online;
        if (online) { this._resetForget(entry); }
      }
      if (entry.detail) { entry.detail.hidden = !online && !!entry.forget; }
    }

    const pending = (this._config.decisions || [])
      .filter((entityId) => !STATUS_QUIET.includes(this._state(entityId))).length;

    const bits = [`Live sessions: ${live}`, `Pending decisions: ${pending}`];
    // With one machine there is no second version to compare against, so the version
    // belongs in the line you can see without opening anything. With several, each
    // machine's version sits on its own row where it can be compared.
    if (soloVersion) { bits.push(`Bridge ${soloVersion}`); }
    this._els.summary.textContent = bits.join(' \u00b7 ');
    this._els.summary.classList.toggle('waiting', pending > 0);
  }
}

if (!customElements.get('agent-bridge-reply-card')) {
  customElements.define('agent-bridge-reply-card', AgentBridgeReplyCard);
}
if (!customElements.get('agent-bridge-status-card')) {
  customElements.define('agent-bridge-status-card', AgentBridgeStatusCard);
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
  description: 'Reply box for a bridged coding-agent session, with image and file attachments.',
});
window.customCards.push({
  type: 'agent-bridge-activity-card',
  name: 'Agent Bridge Activity',
  description: 'Live status, response and reasoning for a bridged session, updated in place.',
});
window.customCards.push({
  type: 'agent-bridge-status-card',
  name: 'Agent Bridge Status',
  description: 'Live and pending counts, folding open to a row per machine with its Detail switch, or an X when it is offline.',
});
window.customCards.push({
  type: 'agent-bridge-choices-card',
  name: 'Agent Bridge Choices',
  description: 'A waiting question or form, as rows that wrap instead of dropdowns.',
});

console.info(`%c AGENT-BRIDGE-REPLY-CARD %c ${CARD_VERSION} `,
  'color: white; background: #03a9f4; font-weight: 700;',
  'color: #03a9f4; background: white; font-weight: 700;');
