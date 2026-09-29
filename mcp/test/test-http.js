/**
 * Security tests for the HTTP transport.
 *
 * The properties that matter are the ones that stop this process's Home Assistant
 * token reaching a stranger, so they are asserted rather than assumed:
 *
 *   - the Authorization header is parsed in linear time, before any token is checked;
 *   - a non-local bind without a token is refused outright, not warned about;
 *   - requests without the token are rejected;
 *   - requests with a wrong token are rejected;
 *   - the correct token is accepted.
 *
 * No Home Assistant is needed: the listener is started directly.
 */

import http from 'node:http';
import net from 'node:net';
import { startHttpTransport, isLocalBind, readBearer } from '../src/http.js';

let failures = 0;
// The details logged below include a raw socket response and a header value built to
// contain control characters, so they are folded onto one line before being printed:
// a newline in a log line is how one entry is made to look like two (CodeQL
// js/log-injection). The `/\n|\r/g` shape is deliberate - a character class covering
// the same characters is not recognised as a sanitizer.
const oneLine = (value) => String(value).replace(/\n|\r/g, ' ').replace(/[\u0000-\u001f\u007f]/g, '?');
const check = (name, ok, detail = '') => {
  const line = `  ${ok ? 'PASS' : 'FAIL'}  ${oneLine(name)}${detail ? ` - ${oneLine(detail)}` : ''}`;
  console.log(line);
  if (!ok) failures++;
};

console.log('--- reading the Authorization header ---');
// Parsed before the token is compared, so it is the first thing an anonymous caller
// can reach. It had no test of its own; it was only ever exercised through a request.
const bearer = (authorization) => readBearer({ headers: authorization === undefined ? {} : { authorization } });
for (const [name, header, expected] of [
  ['a plain bearer token is read', 'Bearer abc123', 'abc123'],
  ['the scheme is case-insensitive', 'bearer abc123', 'abc123'],
  ['surrounding and inner whitespace is trimmed', '  Bearer    abc123   ', 'abc123'],
  ['a tab separates the scheme too', 'Bearer\tabc123', 'abc123'],
  ['a missing header reads as no token', undefined, ''],
  ['an empty header reads as no token', '', ''],
  ['another scheme is not a bearer token', 'Basic abc123', ''],
  ['a scheme that merely starts with it is not one', 'Bearerish abc123', ''],
  ['the scheme with nothing after it is no token', 'Bearer', ''],
  ['nor is the scheme followed only by spaces', 'Bearer     ', ''],
]) {
  check(name, bearer(header) === expected, `got '${bearer(header)}'`);
}

// The regex this replaced was `/^Bearer\s+(.+)$/i`. `\s+` and `(.+)` both match a
// space, so a failing match made the engine try every way of splitting a run of them.
// Getting the trigger right took three attempts and each wrong one passed against the
// old code, so the shape is pinned here: the value needs a CR or LF *after* the
// spaces, because `.` matches neither and without one the greedy `(.+)` reaches the
// end first time. Trailing spaces alone do nothing - the old parse trimmed first.
{
  const attack = `Bearer${' '.repeat(8000)}a\nb`;
  const started = process.hrtime.bigint();
  const got = bearer(attack);
  const ms = Number(process.hrtime.bigint() - started) / 1e6;
  check('a value built to make the old parse backtrack is parsed in linear time', ms < 10, `${ms.toFixed(1)} ms`);
  // A deliberate behaviour change, recorded rather than smoothed over: the old parse
  // failed to match this and returned '', the new one returns the rest of the value.
  // Nothing downstream is looser for it. The result is only ever handed to a
  // constant-time comparison against the configured token, which nothing carrying a
  // control character can equal, and the request does not reach the handler at all.
  check('and returns the rest of the value, which no configured token can equal',
    got === 'a\nb', JSON.stringify(got));
  check('trailing whitespace alone is trimmed away, not backtracked over',
    bearer(`Bearer${' '.repeat(8000)}`) === '');
}

console.log('--- a header value that could backtrack never reaches the handler ---');
// Which is why the parse above is defence in depth rather than a hole that was being
// stood in front of. Asserted rather than reasoned about: undici refuses to send such
// a header at all, so this is written onto a raw socket.
{
  const rawPort = 48083;
  const rawToken = 'raw-probe-token';
  const rawServer = await startHttpTransport({ host: '127.0.0.1', port: rawPort, token: rawToken });
  const rawRequest = (authorization) => new Promise((resolve) => {
    const socket = net.connect(rawPort, '127.0.0.1', () => {
      socket.write(
        `POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:${rawPort}\r\n` +
        `Authorization: ${authorization}\r\nContent-Length: 0\r\n\r\n`);
    });
    let seen = '';
    socket.on('data', (chunk) => { seen += chunk; });
    const done = () => resolve((seen.split('\r\n')[0] || '').trim());
    socket.on('close', done);
    socket.on('error', () => resolve('socket error'));
    setTimeout(() => { socket.destroy(); done(); }, 2000);
  });
  try {
    const plain = await rawRequest('Bearer wrong-token');
    check('an ordinary bad token reaches the handler and is a 401', /401/.test(plain), plain);
    for (const [name, control] of [['LF', '\n'], ['CR', '\r']]) {
      const status = await rawRequest(`Bearer${' '.repeat(4000)}a${control}b`);
      check(`a value with an embedded ${name} is a 400 from the parser`, /400/.test(status), status);
    }
  }
  finally {
    rawServer.httpServer.close();
  }
}

console.log('--- local bind detection ---');
for (const host of ['127.0.0.1', '::1', 'localhost']) {
  check(`${host} is local`, isLocalBind(host));
}
for (const host of ['0.0.0.0', '192.168.1.50', '::']) {
  check(`${host} is not local`, !isLocalBind(host));
}

console.log('--- refuses an unauthenticated public bind ---');
let refused = false;
let message = '';
try {
  await startHttpTransport({ host: '0.0.0.0', port: 48081, token: '' });
}
catch (error) {
  refused = true;
  message = error.message;
}
check('binding 0.0.0.0 with no token throws', refused);
check('the reason names the Home Assistant token', /Home Assistant token/.test(message));

console.log('--- authentication ---');
const port = 48082;
const token = 'test-token-do-not-use';
const { httpServer } = await startHttpTransport({ host: '127.0.0.1', port, token });

async function probe(headers) {
  const response = await fetch(`http://127.0.0.1:${port}/mcp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream', ...headers },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'ping' }),
  });
  return response.status;
}

try {
  check('no credentials are rejected', (await probe({})) === 401);
  check('a wrong token is rejected', (await probe({ authorization: 'Bearer wrong' })) === 401);
  check('a token of the wrong length is rejected', (await probe({ authorization: 'Bearer test-token' })) === 401);
  const ok = await probe({ authorization: `Bearer ${token}` });
  check('the correct token passes authentication', ok !== 401, `status ${ok}`);

  const wrongPath = await fetch(`http://127.0.0.1:${port}/not-mcp`, { method: 'POST' });
  check('an unknown path is a 404', wrongPath.status === 404, `status ${wrongPath.status}`);
}
finally {
  httpServer.close();
}

console.log('--- DNS rebinding protection ---');
const dnsPort = 48084;
const dnsToken = 'dns-probe-token';
const dns = await startHttpTransport({
  host: '127.0.0.1',
  port: dnsPort,
  token: dnsToken,
  allowedHosts: ['tunnel.example.com'],
});

// The SDK matches the Host header exactly, so anything fronting this server has to
// be declared. undici's fetch refuses to override Host, hence raw node:http. A
// successful initialize opens an SSE stream that never ends, so this resolves on
// the status code rather than waiting for the body.
function hostProbe(hostHeader) {
  return new Promise((resolve) => {
    const body = JSON.stringify({
      jsonrpc: '2.0', id: 1, method: 'initialize',
      params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'p', version: '0' } },
    });
    const req = http.request({
      host: '127.0.0.1', port: dnsPort, path: '/mcp', method: 'POST',
      headers: {
        'content-type': 'application/json',
        accept: 'application/json, text/event-stream',
        authorization: `Bearer ${dnsToken}`,
        'content-length': Buffer.byteLength(body),
        Host: hostHeader,
      },
    }, (res) => {
      const done = () => { resolve(res.statusCode); req.destroy(); };
      res.on('data', done);
      res.on('end', () => resolve(res.statusCode));
      setTimeout(done, 1500);
    });
    req.on('error', () => resolve(0));
    req.end(body);
  });
}

try {
  // Host validation runs before session handling, so the meaningful distinction is
  // 403 versus anything else. The transport is stateful, so only the first
  // initialize gets a 200 - a later one is a protocol-level 400, which still proves
  // the Host header was accepted.
  const bound = await hostProbe(`127.0.0.1:${dnsPort}`);
  check('the bound host is accepted', bound !== 403, `status ${bound}`);
  const evil = await hostProbe('evil.example.com');
  check('an unknown Host header is rejected', evil === 403, `status ${evil}`);
  const tunnel = await hostProbe('tunnel.example.com');
  check('a declared tunnel hostname is accepted', tunnel !== 403, `status ${tunnel}`);
}
finally {
  dns.httpServer.close();
}

console.log('');
if (failures) {
  console.log(`${failures} check(s) failed`);
}
else {
  console.log('All checks passed');
}
process.exitCode = failures ? 1 : 0;
