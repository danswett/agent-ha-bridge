import { readFileSync } from 'node:fs';
import { isAbsolute } from 'node:path';
import { DEFAULT_URL_PATH } from './dashboard.js';

function baseUrl(value) {
  const message = 'Home Assistant URL must be an absolute HTTP(S) URL without user info, a query, or a fragment.';
  if (typeof value !== 'string' || !value.trim() || /[\s\\]/.test(value.trim())) {
    throw new Error(message);
  }
  let url;
  try {
    url = new URL(value.trim());
  } catch {
    throw new Error(message);
  }
  if (!['http:', 'https:'].includes(url.protocol) || !url.hostname ||
      url.username || url.password || url.search || url.hash || /[?#]/.test(value)) {
    throw new Error(message);
  }
  return url.href.replace(/\/+$/, '');
}

function credential(value) {
  if (value === undefined || value === null || value === '') return '';
  if (typeof value !== 'string' || !value.trim() || /[\r\n]/.test(value)) {
    throw new Error('Home Assistant credentials must be nonempty single-line strings.');
  }
  return value;
}

function referencedCredential(ha, key, variableKey, defaultVariable, env, required) {
  const stored = credential(ha[key]);
  if (stored) return stored;
  const variable = ha[variableKey] ?? defaultVariable;
  if (typeof variable !== 'string') throw new Error(`homeAssistant.${variableKey} must name an environment variable.`);
  const fromEnvironment = credential(variable ? env[variable] : '');
  if (fromEnvironment) return fromEnvironment;
  if (key === 'token') {
    const legacy = credential(env.COPILOT_HA_TOKEN);
    if (legacy) return legacy;
  }
  if (required) {
    throw new Error(
      `No Home Assistant ${key} is available. Set the variable named by homeAssistant.${variableKey} ` +
      `in the MCP client's environment, or configure homeAssistant.${key}.`,
    );
  }
  return '';
}

function connection(env) {
  if (!env.HA_BRIDGE_CONFIG) {
    if (!env.HA_BASE_URL || !env.HA_TOKEN) {
      throw new Error('Set HA_BASE_URL and HA_TOKEN, or set HA_BRIDGE_CONFIG to the bridge configuration file.');
    }
    return {
      baseUrl: baseUrl(env.HA_BASE_URL),
      token: credential(env.HA_TOKEN),
      agentToken: credential(env.HA_AGENT_TOKEN),
    };
  }

  if (typeof env.HA_BRIDGE_CONFIG !== 'string' || !isAbsolute(env.HA_BRIDGE_CONFIG)) {
    throw new Error('HA_BRIDGE_CONFIG must be an absolute path to the bridge configuration file.');
  }
  let config;
  try {
    config = JSON.parse(readFileSync(env.HA_BRIDGE_CONFIG, 'utf8').replace(/^\uFEFF/, ''));
  } catch {
    // JSON and filesystem errors can contain credential values or private paths.
    throw new Error('Cannot read HA_BRIDGE_CONFIG as JSON. Check the referenced file and its permissions.');
  }
  const ha = config?.homeAssistant;
  if (!ha || typeof ha !== 'object' || Array.isArray(ha)) {
    throw new Error('HA_BRIDGE_CONFIG must contain a homeAssistant configuration object.');
  }
  // Resolve the endpoint and both credential sources from the same file. Ambient
  // HA_BASE_URL / HA_TOKEN must not redirect a referenced credential.
  return {
    baseUrl: baseUrl(ha.baseUrl),
    token: referencedCredential(ha, 'token', 'tokenEnvVar', 'AGENT_HA_TOKEN', env, true),
    agentToken: referencedCredential(
      ha, 'agentToken', 'agentTokenEnvVar', 'AGENT_HA_AGENT_TOKEN', env,
      Array.isArray(ha.agentUserIds) ? ha.agentUserIds.length > 0 : Boolean(ha.agentUserIds),
    ),
  };
}

export function loadConfig(env = process.env) {
  return {
    ...connection(env),
    title: env.HA_CARD_TITLE || 'Agent MCP',
    timeoutMs: Number(env.HA_TIMEOUT_MS) || 30 * 60 * 1000,
    dashboard: env.HA_DASHBOARD === undefined ? DEFAULT_URL_PATH : env.HA_DASHBOARD,
    transport: (env.MCP_TRANSPORT || 'stdio').toLowerCase(),
    httpHost: env.MCP_HTTP_HOST || '127.0.0.1',
    httpPort: Number(env.MCP_HTTP_PORT) || 8808,
    httpToken: env.MCP_HTTP_TOKEN || '',
    httpPath: env.MCP_HTTP_PATH || '/mcp',
    httpAllowedHosts: (env.MCP_HTTP_ALLOWED_HOSTS || '').split(',').map((entry) => entry.trim()).filter(Boolean),
  };
}
