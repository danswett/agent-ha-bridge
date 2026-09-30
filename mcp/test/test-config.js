import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadConfig } from '../src/config.js';

let failures = 0;
function check(name, run) {
  try {
    run();
    console.log(`  PASS  ${name}`);
  } catch (error) {
    failures++;
    console.error(`  FAIL  ${name}: ${error.message}`);
  }
}

const root = mkdtempSync(join(tmpdir(), "bridge-config ' \u96ea-"));
const path = join(root, 'config.json');
const ha = {
  baseUrl: 'http://127.0.0.1:1/ha/',
  token: '',
  tokenEnvVar: 'TEST_USER_TOKEN',
  agentToken: '',
  agentTokenEnvVar: 'TEST_AGENT_TOKEN',
  agentUserIds: ['synthetic-agent'],
};
const environment = {
  HA_BRIDGE_CONFIG: path,
  TEST_USER_TOKEN: 'synthetic-user-secret',
  TEST_AGENT_TOKEN: 'synthetic-agent-secret',
};
const writeConfig = (value) => writeFileSync(path, JSON.stringify(value), { mode: 0o600 });

try {
  writeConfig({ homeAssistant: ha });
  check('runtime references support spaced, apostrophe and Unicode file paths', () => {
    const config = loadConfig(environment);
    assert.equal(config.baseUrl, 'http://127.0.0.1:1/ha');
    assert.equal(config.token, environment.TEST_USER_TOKEN);
    assert.equal(config.agentToken, environment.TEST_AGENT_TOKEN);
  });
  check('the referenced endpoint cannot be replaced by ambient direct credentials or a URL', () => {
    const config = loadConfig({
      ...environment, HA_BASE_URL: 'https://other.invalid', HA_TOKEN: 'other-user', HA_AGENT_TOKEN: 'other-agent',
    });
    assert.equal(config.baseUrl, 'http://127.0.0.1:1/ha');
    assert.equal(config.token, environment.TEST_USER_TOKEN);
    assert.equal(config.agentToken, environment.TEST_AGENT_TOKEN);
  });
  check('secret rotation is read at startup rather than frozen into a client config', () => {
    assert.equal(loadConfig({ ...environment, TEST_USER_TOKEN: 'rotated-secret' }).token, 'rotated-secret');
    writeConfig({ homeAssistant: { ...ha, token: 'saved-secret', agentToken: 'saved-agent' } });
    const config = loadConfig(environment);
    assert.equal(config.token, 'saved-secret');
    assert.equal(config.agentToken, 'saved-agent');
    writeConfig({ homeAssistant: ha });
  });
  check('a missing environment-only user credential fails with actionable safe guidance', () => {
    assert.throws(() => loadConfig({ HA_BRIDGE_CONFIG: path }), /tokenEnvVar.*environment/i);
  });
  check('a configured agent identity never silently falls back to the user when its secret is absent', () => {
    assert.throws(() => loadConfig({ ...environment, TEST_AGENT_TOKEN: '' }), /agentTokenEnvVar.*environment/i);
    writeConfig({ homeAssistant: { ...ha, agentUserIds: 'synthetic-agent' } });
    assert.throws(() => loadConfig({ ...environment, TEST_AGENT_TOKEN: '' }), /agentTokenEnvVar.*environment/i);
    writeConfig({ homeAssistant: ha });
  });
  check('an unconfigured optional agent still works without an agent credential', () => {
    writeConfig({ homeAssistant: { baseUrl: ha.baseUrl, token: 'saved-secret' } });
    const config = loadConfig({ HA_BRIDGE_CONFIG: path });
    assert.equal(config.agentToken, '');
    assert.equal(config.token, 'saved-secret');
  });
  check('default and legacy user environment names remain supported', () => {
    writeConfig({ homeAssistant: { baseUrl: ha.baseUrl } });
    assert.equal(loadConfig({ HA_BRIDGE_CONFIG: path, AGENT_HA_TOKEN: 'default-secret' }).token, 'default-secret');
    assert.equal(loadConfig({ HA_BRIDGE_CONFIG: path, COPILOT_HA_TOKEN: 'legacy-secret' }).token, 'legacy-secret');
  });
  check('direct environment configuration remains supported without reading a bridge config', () => {
    const config = loadConfig({
      HA_BASE_URL: 'https://ha.invalid/', HA_TOKEN: 'direct-secret', HA_AGENT_TOKEN: 'direct-agent',
      HA_CARD_TITLE: 'Test card', HA_TIMEOUT_MS: '1000', HA_DASHBOARD: '', MCP_TRANSPORT: 'HTTP',
      MCP_HTTP_HOST: '127.0.0.1', MCP_HTTP_PORT: '8809', MCP_HTTP_TOKEN: 'synthetic-http-secret',
      MCP_HTTP_PATH: '/test', MCP_HTTP_ALLOWED_HOSTS: 'one.invalid, two.invalid',
    });
    assert.deepEqual(config, {
      baseUrl: 'https://ha.invalid', token: 'direct-secret', agentToken: 'direct-agent', title: 'Test card',
      timeoutMs: 1000, dashboard: '', transport: 'http', httpHost: '127.0.0.1', httpPort: 8809,
      httpToken: 'synthetic-http-secret', httpPath: '/test', httpAllowedHosts: ['one.invalid', 'two.invalid'],
    });
  });
  check('a missing direct token fails rather than reading an installed credential implicitly', () => {
    assert.throws(() => loadConfig({ HA_BASE_URL: 'http://127.0.0.1:1' }), /HA_TOKEN/);
  });
  for (const baseUrl of [
    'file:///tmp/ha', 'ftp://ha.invalid', 'ha.invalid:8123', '//ha.invalid:8123',
    'https://user:synthetic-url-secret@ha.invalid', 'https://ha.invalid/?secret=synthetic-url-secret',
    'https://ha.invalid/#synthetic-url-secret', 'http://ha.invalid\\other', 'https://ha.invalid/\nsecret',
  ]) {
    check('invalid endpoints are rejected without reflecting credentials in the error', () => {
      assert.throws(() => loadConfig({ HA_BASE_URL: baseUrl, HA_TOKEN: 'synthetic-token' }), (error) =>
        /URL/.test(error.message) && !/synthetic-url-secret/.test(error.message));
      writeConfig({ homeAssistant: { ...ha, baseUrl } });
      assert.throws(() => loadConfig(environment), /URL/);
    });
  }
  check('invalid or unreadable referenced files fail without falling back to ambient credentials', () => {
    for (const contents of ['{"homeAssistant":synthetic-parser-secret}', '[]', 'null', '{"homeAssistant":[]}']) {
      writeFileSync(path, contents);
      assert.throws(() => loadConfig({ ...environment, HA_TOKEN: 'ambient-secret' }), (error) =>
        !/synthetic-parser-secret|ambient-secret/.test(error.message));
    }
    rmSync(path);
    assert.throws(() => loadConfig(environment), /HA_BRIDGE_CONFIG/);
  });
  check('invalid credential values fail without being coerced or included in errors', () => {
    writeConfig({ homeAssistant: { ...ha, token: { value: 'synthetic-invalid-secret' } } });
    assert.throws(() => loadConfig(environment), (error) => !error.message.includes('synthetic-invalid-secret'));
  });
} finally {
  rmSync(root, { recursive: true, force: true });
}

if (failures) process.exitCode = 1;
else console.log('All configuration checks passed');
