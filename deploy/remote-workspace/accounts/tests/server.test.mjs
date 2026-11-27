import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { Duplex } from 'node:stream';
import { WebSocket } from 'ws';
import { once } from 'node:events';
import { Accounts, opaque, digest, workspaceFor } from '../identity.mjs';
import { accountServer } from '../server.mjs';

const origin = 'https://accounts.example.invalid',
  host = new URL(origin).host;
async function fixture(t) {
  const accounts = new Accounts(':memory:'),
    calls = [];
  const server = accountServer({
    origin,
    accounts,
    google: {
      url: (tx) => 'https://accounts.google.com/?state=' + tx.state,
      verify: async (code, tx) => ({
        sub: code,
        email: code + '@example.invalid',
        email_verified: true,
        nonce: tx.nonce,
      }),
    },
    admit: (claims) => claims.sub !== 'excluded',
    broker: {
      async call(...args) {
        calls.push(args);
        return { ready: true };
      },
      display() {
        return new Duplex({
          read() {},
          write(_, __, done) {
            done();
          },
        });
      },
    },
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => {
    server.closeAllConnections();
    server.close();
    accounts.db.close();
  });
  function request(path, { method = 'GET', headers = {}, data } = {}) {
    return new Promise((resolve, reject) => {
      const req = http.request(
        { host: '127.0.0.1', port: server.address().port, path, method, headers: { host, ...headers } },
        (res) => {
          let body = '';
          res.setEncoding('utf8');
          res.on('data', (chunk) => (body += chunk));
          res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
        }
      );
      req.on('error', reject);
      req.end(data);
    });
  }
  async function sign(person, challenge) {
    const first = await request('/auth/google' + (challenge ? '?challenge=' + challenge : ''));
    const state = new URL(first.headers.location).searchParams.get('state');
    const cookie = first.headers['set-cookie'][0].split(';')[0];
    return request('/oauth/callback?state=' + state + '&code=' + person, { headers: { cookie } });
  }
  const session = (reply) =>
    reply.headers['set-cookie'].find((cookie) => cookie.startsWith('__Host-kg_session=')).split(';')[0];
  return { request, sign, session, calls, port: server.address().port };
}

test('owner is determined on the server at every provider and workspace route', async (t) => {
  const { request, sign, session, calls } = await fixture(t);
  for (const who of ['alice', 'bob']) {
    const cookie = session(await sign(who));
    for (const path of ['/api/workspace?workspace=other', '/api/connections/claude/start']) {
      const reply = await request(path, {
        method: 'POST',
        headers: { origin, cookie },
        data: 'workspace=other',
      });
      assert.equal(reply.status, 200);
      assert.equal(calls.at(-1)[0], workspaceFor(who));
    }
  }
  assert.equal(calls.length, 4);
  assert.equal((await request('/api/workspace', { method: 'POST', headers: { origin } })).status, 401);
  assert.equal((await sign('excluded')).status, 403);
});
test('requests with a different origin or host cannot change a session', async (t) => {
  const { request, sign, session, calls } = await fixture(t),
    reply = await sign('alice'),
    cookie = session(reply);
  assert.match(reply.headers['set-cookie'][1], /HttpOnly; SameSite=Lax;.*Secure/);
  for (const bad of ['https://another.example', undefined]) {
    assert.equal(
      (
        await request('/auth/logout', {
          method: 'POST',
          headers: { cookie, ...(bad && { origin: bad }) },
        })
      ).status,
      403
    );
  }
  assert.equal(
    (await request('/api/me', { headers: { host: 'unrelated.example', cookie } })).status,
    421
  );
  assert.equal(
    (
      await request('/api/display', {
        headers: {
          cookie,
          origin: 'https://another.example',
          connection: 'Upgrade',
          upgrade: 'websocket',
        },
      })
    ).status,
    403
  );
  assert.equal(
    (await request('/api/me', { headers: { cookie } })).body,
    '{"email":"alice@example.invalid"}'
  );
  assert.equal(
    (await request('/auth/logout', { method: 'POST', headers: { origin, cookie } })).status,
    200
  );
  assert.equal((await request('/api/me', { headers: { cookie } })).body, '{"email":null}');
  assert.equal(calls.length, 0);
});
test('native return gives the app one proof-bound session without leaking the website session', async (t) => {
  const { request, sign } = await fixture(t);
  const verifier = opaque(),
    reply = await sign('alice', digest(verifier));
  const location = new URL(reply.headers.location);
  assert.equal(location.protocol, 'kolmogor-account:');
  assert.equal(reply.headers['set-cookie'].length, 1);
  const ticket = location.searchParams.get('ticket');
  const redeem = (v, from) =>
    request('/auth/redeem', {
      method: 'POST',
      headers: from ? { origin: from } : {},
      data: new URLSearchParams({ ticket, verifier: v }).toString(),
    });
  assert.equal((await redeem(verifier, 'https://elsewhere.example')).status, 403);
  assert.equal((await redeem(opaque())).status, 401);
  assert.equal((await redeem(verifier)).status, 303);
  assert.equal((await redeem(verifier)).status, 401);
});

test('signing out closes an already-open workspace screen', async (t) => {
  const { request, sign, session, port } = await fixture(t);
  const cookie = session(await sign('alice'));
  const ws = new WebSocket('ws://127.0.0.1:' + port + '/api/display', {
    headers: { host, origin, cookie },
  });
  await once(ws, 'open');
  const closed = once(ws, 'close', { signal: AbortSignal.timeout(4000) });
  await request('/auth/logout', { method: 'POST', headers: { origin, cookie } });
  await closed;
  assert.equal(ws.readyState, WebSocket.CLOSED);
});

test('repeated new sign-ins from one client yield a bounded retry, while another client can sign in', async (t) => {
  const { request } = await fixture(t);
  for (let i = 0; i < 12; i++)
    assert.equal(
      (await request('/auth/google', { headers: { 'cf-connecting-ip': '192.0.2.1' } })).status,
      303
    );
  const limited = await request('/auth/google', { headers: { 'cf-connecting-ip': '192.0.2.1' } });
  assert.equal(limited.status, 429);
  assert.equal(limited.headers['retry-after'], '300');
  assert.equal(
    (await request('/auth/google', { headers: { 'cf-connecting-ip': '192.0.2.2' } })).status,
    303
  );
});
