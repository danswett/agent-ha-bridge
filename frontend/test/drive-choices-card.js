/*
 * Runs the real choices card against a real dashboard config, for the end-to-end
 * wiring test in tests/test-choices-form.ps1.
 *
 * Reads a job on stdin:
 *   { config, states, taps: [<option label>, ...] }
 * where `config` is the card config Save-CopilotSessionDashboard generated and
 * `states` are the entity states Set-CopilotMqttDecision published. Each tap is the
 * label of a row to press, in order.
 *
 * Writes on stdout:
 *   { hidden, rows: [{ tag, text, classes }], calls: [{ domain, service, data }],
 *     missing: [<label not found>] }
 *
 * Nothing here knows which entity a row should set - that is exactly what is under
 * test. The card decides, and the caller checks the answer against what the daemon
 * reads.
 */
'use strict';

const { loadCards } = require('./card-harness');

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => { raw += chunk; });
process.stdin.on('end', () => {
  const job = JSON.parse(raw);
  const { AgentBridgeChoicesCard } = loadCards();

  const calls = [];
  const hass = {
    states: job.states,
    callService: (domain, service, data) => {
      calls.push({ domain, service, data });
      // Home Assistant applies the selection and pushes the new state back, which is
      // what lets a form be filled in field by field. Without it every later tap sees
      // a stale form. Only a selection changes a state: a button press records a
      // timestamp the daemon reads, and writing `undefined` here would wipe the slot
      // the press is meant to send.
      if (domain === 'select' && service === 'select_option') {
        const entity = job.states[data.entity_id];
        if (entity) { entity.state = data.option; }
        card.hass = hass;
      }
      // A promise, because the real one is: the card settles a tap only once the call
      // has been acknowledged, so a stand-in that returned nothing left every tap
      // looking unconfirmed for ever and held Send.
      return Promise.resolve();
    },
  };

  const card = new AgentBridgeChoicesCard();
  card.setConfig(job.config);
  card.hass = hass;

  const flush = () => new Promise((resolve) => setImmediate(resolve));

  (async () => {
    const missing = [];
    for (const label of (job.taps || [])) {
      const row = card.shadowRoot.querySelector('.choices').children
        .filter((r) => r.tagName === 'BUTTON')
        .find((r) => r.textContent === label);
      if (!row) { missing.push(label); continue; }
      row.click();
      // Let the acknowledgement land before the next tap, as it would between two
      // taps made by a person.
      await flush();
    }
    const rows = card.shadowRoot.querySelector('.choices').children.map((r) => ({
      tag: r.tagName,
      text: r.textContent,
      classes: ['label', 'cancel', 'chosen'].filter((c) => r.classList.contains(c)),
    }));

    process.stdout.write(JSON.stringify({ hidden: !!card.hidden, rows, calls, missing }));
  })();
});
