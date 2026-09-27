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

const CARD_VERSION = '1.9.0';

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
      .row { display: flex; align-items: flex-end; gap: 8px; }
      textarea {
        flex: 1 1 auto;
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
        border: none;
        border-radius: 10px;
        padding: 10px 12px;
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
        <button class="ghost attach" title="Attach an image">&#128206;</button>
        <button class="send">Send</button>
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

if (!customElements.get('agent-bridge-reply-card')) {
  customElements.define('agent-bridge-reply-card', AgentBridgeReplyCard);
}

window.customCards = window.customCards || [];
window.customCards.push({
  type: 'agent-bridge-reply-card',
  name: 'Agent Bridge Reply',
  description: 'Reply box for a bridged coding-agent session, with image attachments.',
});

console.info(`%c AGENT-BRIDGE-REPLY-CARD %c ${CARD_VERSION} `,
  'color: white; background: #03a9f4; font-weight: 700;',
  'color: #03a9f4; background: white; font-weight: 700;');
