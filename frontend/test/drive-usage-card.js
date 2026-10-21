/*
 * Runs the real usage card against a real dashboard config, for the end-to-end
 * wiring test in tests/test-usage.ps1.
 *
 * Reads a job on stdin:
 *   { config, states, open }
 * where `config` is the card config Save-CopilotSessionDashboard generated and
 * `states` are the entity states Publish-CopilotMqttUsage really produces.
 *
 * Writes on stdout:
 *   { summary, figures: [{ text, severity }], hidden, size, groups: [...] }
 *
 * Nothing here knows which entity a row should read, how two machines reporting one
 * account should be reconciled, or what a bar should be filled to - that is what is
 * under test. The card decides; the caller checks the answer against what the daemon
 * published.
 */
'use strict';

const { loadCards } = require('./card-harness');

// The card builds its rows out of nested elements, so the driver has to read them
// back the way a person would: by class, down the tree it actually built.
function pick(element, className) {
  for (const child of element.children) {
    if (child.classList.contains(className)) { return child; }
    const found = pick(child, className);
    if (found) { return found; }
  }
  return null;
}

function pickAll(element, className) {
  const found = [];
  for (const child of element.children) {
    if (child.classList.contains(className)) { found.push(child); }
    else { found.push(...pickAll(child, className)); }
  }
  return found;
}

function text(element, className) {
  const node = pick(element, className);
  return node ? node.textContent : null;
}

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => { raw += chunk; });
process.stdin.on('end', () => {
  const job = JSON.parse(raw);
  const { AgentBridgeUsageCard } = loadCards();

  const card = new AgentBridgeUsageCard();
  card.setConfig(job.config);
  card._open = job.open !== false;
  card.hass = { states: job.states, callService: () => {} };

  const groups = pickAll(card._els.groups, 'group').map((group) => ({
    name: text(group, 'gname'),
    account: text(group, 'gacct'),
    age: text(group, 'gage'),
    stale: !!(pick(group, 'gage') || { classList: { contains: () => false } }).classList.contains('stale'),
    error: text(group, 'err'),
    windows: pickAll(group, 'win').map((win) => {
      const fill = pick(win, 'fill');
      const pace = pick(win, 'pace');
      return {
        label: text(win, 'wlabel'),
        percent: text(win, 'wpct'),
        width: fill ? fill.style.width : null,
        severity: fill && fill.classList.contains('crit') ? 'crit'
          : (fill && fill.classList.contains('warn') ? 'warn' : ''),
        pace: pace ? pace.style.left : null,
        paceMark: text(win, 'pacemark'),
        verdict: text(win, 'verdict'),
        ahead: !!(pick(win, 'verdict') || { classList: { contains: () => false } }).classList.contains('ahead'),
        detail: text(win, 'wdetail'),
        resets: text(win, 'wreset'),
      };
    }),
  }));

  const severityOf = (element) => (element.classList.contains('crit') ? 'crit'
    : (element.classList.contains('warn') ? 'warn' : ''));

  process.stdout.write(JSON.stringify({
    summary: card._els.summary.textContent,
    // One per client on the folded line, each with the colour it was drawn in.
    figures: pickAll(card._els.summary, 'figure').map((figure) => ({
      text: figure.textContent,
      severity: severityOf(figure),
    })),
    hidden: !!card._els.groups.hidden,
    size: card.getCardSize(),
    groups,
  }));
});
