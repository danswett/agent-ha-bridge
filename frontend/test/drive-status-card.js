/*
 * Runs the real status card against a real dashboard config, for the end-to-end
 * wiring test in tests/test-status-card.ps1.
 *
 * Reads a job on stdin:
 *   { config, states, open, flips: [<machine name>, ...] }
 * where `config` is the card config Save-CopilotSessionDashboard generated and
 * `states` are the entity states the bridge's own publishers produce. Each flip is
 * the name of the machine whose Detail switch to move, in order.
 *
 * Writes on stdout:
 *   { summary, waiting, hidden, size, rows: [...], calls: [...], missing: [...] }
 *
 * Nothing here knows which entity a row should read or a switch should set - that is
 * exactly what is under test. The card decides, and the caller checks the answer
 * against what the daemon publishes.
 */
'use strict';

const { loadCards } = require('./card-harness');

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => { raw += chunk; });
process.stdin.on('end', () => {
  const job = JSON.parse(raw);
  const { AgentBridgeStatusCard } = loadCards();

  const calls = [];
  const hass = {
    states: job.states,
    callService: (domain, service, data) => {
      calls.push({ domain, service, data });
      // Home Assistant applies the toggle and pushes the new state back, which is
      // what settles the switch. Without it every later render sees a stale value.
      const entity = job.states[data.entity_id];
      if (entity && service === 'toggle') { entity.state = entity.state === 'on' ? 'off' : 'on'; }
      card.hass = hass;
    },
  };

  const card = new AgentBridgeStatusCard();
  card.setConfig(job.config);
  card._open = job.open !== false;
  card.hass = hass;

  const missing = [];
  for (const name of (job.flips || [])) {
    const entry = card._rows.find((r) => r.machine.machine === name);
    if (!entry || !entry.toggle) { missing.push(name); continue; }
    // What a tap on an ha-switch does: it moves, then reports the move.
    entry.toggle.checked = !entry.toggle.checked;
    entry.toggle.dispatch('change');
  }

  const rows = card._rows.map((entry) => ({
    machine: entry.machine.machine,
    meta: entry.meta.textContent,
    online: entry.row.classList.contains('online'),
    toggle: entry.toggle ? { checked: !!entry.toggle.checked, disabled: !!entry.toggle.disabled } : null,
  }));

  process.stdout.write(JSON.stringify({
    summary: card._els.summary.textContent,
    waiting: card._els.summary.classList.contains('waiting'),
    hidden: !!card._els.machines.hidden,
    size: card.getCardSize(),
    rows,
    calls,
    missing,
  }));
});
