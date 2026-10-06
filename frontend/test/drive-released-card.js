/*
 * Runs a card from a released version against what today's bridge publishes, for the
 * compatibility checks in tests/test-choices-form.ps1.
 *
 * The point is evidence rather than assertion. The bridge now publishes a
 * multi-select field's subsets twice - written out while they fit, and as positions -
 * precisely so that a card built before positions existed goes on working. Claiming
 * that is cheap; showing it means taking the actual file out of the released tag and
 * driving it against the actual published option list.
 *
 * Reads a job on stdin:
 *   { card: <path to the card file>, config, states, taps: [<option label>, ...] }
 *
 * Writes on stdout:
 *   { version, hidden, rows, calls, missing, threw }
 *
 * A card old enough not to know a config key simply ignores it, so the same job runs
 * against every version; what differs is what comes back.
 */
'use strict';

const { loadCards } = require('./card-harness');

// A browser logs an unhandled rejection and carries on; Node ends the process. A card
// old enough not to attach a handler to its own service call - 1.22.0 does not, on the
// path where Home Assistant refuses a value - would otherwise take this harness down
// instead of reporting what it wrote. Recorded, not hidden.
const unhandled = [];
process.on('unhandledRejection', (reason) => {
  unhandled.push(String((reason && reason.message) || reason));
});

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => { raw += chunk; });
process.stdin.on('end', () => {
  const job = JSON.parse(raw);
  let loaded;
  try { loaded = loadCards(job.card); }
  catch (err) {
    process.stdout.write(JSON.stringify({ threw: `load: ${err.message}` }));
    return;
  }
  const { AgentBridgeChoicesCard, CARD_VERSION } = loaded;

  const calls = [];
  // Home Assistant rejects a value that is not in the entity's published option list.
  // That refusal is the whole question here, so it is enforced rather than assumed:
  // an older card writing something today's bridge no longer offers has to come back
  // as a refusal, not as a silently stored value.
  const hass = {
    states: job.states,
    callService: (domain, service, data) => {
      const entity = job.states[data.entity_id];
      const offered = entity && entity.attributes && Array.isArray(entity.attributes.options)
        ? entity.attributes.options
        : null;
      if (domain === 'select' && service === 'select_option' && offered && offered.indexOf(data.option) === -1) {
        calls.push({ domain, service, data, rejected: true });
        return Promise.reject(new Error(`Option ${data.option} is not valid`));
      }
      calls.push({ domain, service, data, rejected: false });
      if (domain === 'select' && service === 'select_option' && entity) {
        entity.state = data.option;
        card.hass = hass;
      }
      return Promise.resolve();
    },
  };

  let card;
  try {
    card = new AgentBridgeChoicesCard();
    card.setConfig(job.config);
    card.hass = hass;
  }
  catch (err) {
    process.stdout.write(JSON.stringify({ version: CARD_VERSION, threw: `setup: ${err.message}` }));
    return;
  }

  const flush = () => new Promise((resolve) => setImmediate(resolve));

  (async () => {
    const missing = [];
    let threw = '';
    try {
      for (const label of (job.taps || [])) {
        const row = card.shadowRoot.querySelector('.choices').children
          .filter((r) => r.tagName === 'BUTTON')
          .find((r) => r.textContent === label);
        if (!row) { missing.push(label); continue; }
        row.click();
        await flush();
      }
    }
    catch (err) { threw = `tap: ${err.message}`; }

    const rows = card.shadowRoot.querySelector('.choices').children.map((r) => ({
      tag: r.tagName,
      text: r.textContent,
      classes: ['label', 'cancel', 'chosen'].filter((c) => r.classList.contains(c)),
    }));
    process.stdout.write(JSON.stringify({
      version: CARD_VERSION, hidden: !!card.hidden, rows, calls, missing, threw, unhandled,
    }));
  })();
});
