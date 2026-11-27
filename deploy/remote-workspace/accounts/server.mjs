import { createServer } from 'node:http';
import { isIP } from 'node:net';
import { readFileSync } from 'node:fs';
import { pipeline } from 'node:stream';
import { WebSocketServer, createWebSocketStream } from 'ws';
import { workspaceFor } from './identity.mjs';
import { WorkspaceError } from './broker-client.mjs';

const staticFiles = new Map([
  ['/', ['web/index.html', 'text/html']],
  ['/account.js', ['web/account.js', 'text/javascript']],
  ['/account.css', ['web/account.css', 'text/css']],
  ['/display.js', ['public/display.js', 'text/javascript']],
  ['/viewer-licenses.txt', ['public/viewer-licenses.txt', 'text/plain']],
]);
const providers = new Set(['codex', 'claude', 'antigravity', 'chrome']);
const minute = 60_000;
function cookies(raw = '') {
  const result = new Map();
  for (const part of raw.split(';')) {
    const at = part.indexOf('=');
    if (at > 0) result.set(part.slice(0, at).trim(), part.slice(at + 1));
  }
  return result;
}
async function body(req) {
  let data = '';
  for await (const chunk of req) {
    data += chunk;
    if (Buffer.byteLength(data) > 8192) throw Error('Request too large');
  }
  return Object.fromEntries(new URLSearchParams(data));
}

export function accountServer({ origin, accounts, google, broker, admit = () => true }) {
  const base = new URL(origin),
    local = base.protocol === 'http:' && base.hostname === '127.0.0.1';
  if (base.origin !== origin || (!local && base.protocol !== 'https:'))
    throw Error('Invalid account origin');
  const prefix = local ? 'kg_local_' : '__Host-kg_';
  const cookie = (name, value, maxAge) =>
    prefix +
    name +
    '=' +
    value +
    '; Path=/; HttpOnly; SameSite=Lax; Max-Age=' +
    maxAge +
    (local ? '' : '; Secure');
  const sessionCookie = (s) => cookie('session', s, 7 * 24 * 60 * 60);
  function currentUser(token) {
    const user = accounts.user(token);
    if (user && !admit({ sub: user.subject, email: user.email, email_verified: true })) {
      accounts.logout(token);
      return undefined;
    }
    return user;
  }
  // Only the node loopback accepts connections. Cloudflare overwrites CF-Connecting-IP
  // at the public edge and the account service never records these addresses in its logs or DB.
  const loginWindows = new Map();
  function allowSignIn(req) {
    const now = Date.now();
    const supplied = req.headers['cf-connecting-ip'];
    const source =
      !local && typeof supplied === 'string' && isIP(supplied) ? supplied : req.socket.remoteAddress;
    for (const [key, window] of loginWindows) {
      if (window.until <= now) loginWindows.delete(key);
    }
    let window = loginWindows.get(source);
    if (!window) {
      if (loginWindows.size >= 2048) return false;
      window = { count: 0, until: now + 5 * minute };
      loginWindows.set(source, window);
    }
    return ++window.count <= 12;
  }
  const server = createServer(async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
    res.setHeader(
      'Content-Security-Policy',
      "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' " +
        origin.replace(/^http/, 'ws')
    );
    if (!local) res.setHeader('Strict-Transport-Security', 'max-age=31536000');
    const json = (status, value) => {
      res.writeHead(status, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(value));
    };
    const redirect = (to) => {
      res.writeHead(303, { Location: to });
      res.end();
    };
    const fail = (status, msg) => json(status, { error: msg });
    try {
      if (req.headers.host !== base.host) return fail(421, 'Unexpected host.');
      const url = new URL(req.url, origin),
        path = url.pathname,
        post = req.method === 'POST';
      const jar = cookies(req.headers.cookie),
        token = jar.get(prefix + 'session');
      if (req.method === 'GET' && staticFiles.has(path)) {
        const [file, type] = staticFiles.get(path);
        const bytes = readFileSync(new URL(file, import.meta.url));
        res.writeHead(200, { 'Content-Type': type + '; charset=utf-8' });
        return res.end(bytes);
      }
      if (req.method === 'GET' && path === '/auth/google') {
        const challenge = url.searchParams.get('challenge') || '';
        if (challenge && !/^[A-Za-z0-9_-]{43}$/.test(challenge))
          return fail(400, 'Invalid sign-in request.');
        if (!allowSignIn(req)) {
          res.setHeader('Retry-After', '300');
          return fail(429, 'Too many sign-in attempts. Try again in a few minutes.');
        }
        const tx = accounts.begin(challenge);
        res.setHeader('Set-Cookie', cookie('login', tx.browser, 600));
        return redirect(google.url(tx));
      }
      if (req.method === 'GET' && path === '/oauth/callback') {
        const tx = accounts.claim(url.searchParams.get('state'), jar.get(prefix + 'login'));
        if (!tx || !url.searchParams.get('code'))
          return fail(401, 'Sign-in expired or was canceled. Start again in Kolmogor.');
        const claims = await google.verify(url.searchParams.get('code'), tx);
        if (!admit(claims)) return fail(403, 'This Google account is outside the workspace pilot.');
        const signed = accounts.identify(claims, tx);
        if (signed.ticket) {
          res.setHeader('Set-Cookie', cookie('login', '', 0));
          return redirect('kolmogor-account://complete?ticket=' + signed.ticket);
        }
        res.setHeader('Set-Cookie', [cookie('login', '', 0), sessionCookie(signed.session)]);
        return redirect('/');
      }
      if (post && path === '/auth/redeem') {
        // Native POST navigation has no web Origin. A website must also possess the app's verifier.
        if (req.headers.origin && req.headers.origin !== origin) return fail(403, 'Unexpected origin.');
        const form = await body(req),
          session = accounts.redeem(form.ticket, form.verifier);
        if (!session) return fail(401, 'This sign-in has expired. Please start again.');
        res.setHeader('Set-Cookie', sessionCookie(session));
        return redirect('/');
      }
      if (post && req.headers.origin !== origin) return fail(403, 'Unexpected origin.');
      const user = currentUser(token);
      if (req.method === 'GET' && path === '/api/me') return json(200, { email: user?.email ?? null });
      if (!user) return fail(401, 'Sign in to Kolmogor first.');
      const workspace = workspaceFor(user.subject);
      if (post && path === '/auth/logout') {
        accounts.logout(token);
        res.setHeader('Set-Cookie', cookie('session', '', 0));
        return json(200, { signedOut: true });
      }
      if (post && path === '/api/workspace') return json(200, await broker.call(workspace, 'ensure'));
      if (req.method === 'GET' && path === '/api/connections')
        return json(200, await broker.call(workspace, 'status'));
      const route = /^\/api\/connections\/(codex|claude|antigravity|chrome)\/(start|code)$/.exec(path);
      if (post && route && providers.has(route[1])) {
        const form = await body(req);
        return json(
          200,
          await broker.call(workspace, route[2], route[1], route[2] === 'code' ? form.code : undefined)
        );
      }
      return fail(404, 'Unknown action.');
    } catch (err) {
      // Provider responses and request URLs can contain credentials.
      if (err instanceof WorkspaceError && !res.headersSent) return fail(err.status, err.message);
      console.error('Account request failed', err.name);
      if (!res.headersSent)
        fail(503, 'This request could not be completed. Check the current connection status.');
      else res.destroy();
    }
  });
  server.requestTimeout = 30_000;
  server.headersTimeout = 10_000;
  const wss = new WebSocketServer({ noServer: true, maxPayload: 1024 * 1024, perMessageDeflate: false });
  const views = new Map();
  server.on('upgrade', (req, socket, head) => {
    const token = cookies(req.headers.cookie).get(prefix + 'session'),
      user = currentUser(token);
    if (
      req.headers.host !== base.host ||
      req.headers.origin !== origin ||
      req.url !== '/api/display' ||
      !user ||
      views.has(user.subject)
    ) {
      socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
      return;
    }
    wss.handleUpgrade(req, socket, head, async (ws) => {
      views.set(user.subject, ws);
      let upstream;
      const check = setInterval(() => {
        if (!currentUser(token)) ws.terminate();
      }, 1000);
      const timeout = setTimeout(() => ws.terminate(), 15 * minute);
      ws.on('error', () => ws.terminate());
      ws.on('close', () => {
        clearInterval(check);
        clearTimeout(timeout);
        views.delete(user.subject);
        upstream?.destroy();
      });
      try {
        upstream = await broker.display(workspaceFor(user.subject));
        if (ws.readyState !== 1) {
          upstream.destroy();
          return;
        }
        const stream = createWebSocketStream(ws);
        pipeline(stream, upstream, () => ws.terminate());
        upstream.pipe(stream);
      } catch {
        ws.terminate();
      }
    });
  });
  return server;
}
