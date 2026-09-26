// Explicit local wire fixture, not Chrome or a DOM implementation. Synthetic
// protocol data only; it never reads user browser profiles or network content.
import { randomUUID } from 'node:crypto';

const run = randomUUID();
const path = `/devtools/browser/${run}`;
const requests: { id: number; method: string; session: string | null }[] = [];
let opened = 0;
let closed = 0;
let redirectDestinationHits = 0;
const server = Bun.serve({
  hostname: '127.0.0.1', port: 0,
  fetch(request, server) {
    const url = new URL(request.url);
    if (url.pathname === '/state') return Response.json({ run, requests, opened, closed, redirectDestinationHits });
    if (url.pathname === '/devtools/browser/redirect') {
      return new Response(null, { status: 302, headers: { Location: `http://127.0.0.1:${server.port}/devtools/browser/forbidden` } });
    }
    if (url.pathname === '/devtools/browser/forbidden') {
      redirectDestinationHits++;
      return new Response('redirect followed', { status: 403 });
    }
    if (url.pathname === path && server.upgrade(request)) return;
    return new Response('not found', { status: 404 });
  },
  websocket: {
    open() { opened++; },
    close() { closed++; },
    message(socket, raw) {
      const request = JSON.parse(String(raw));
      if (!Number.isSafeInteger(request.id) || typeof request.method !== 'string') {
        socket.close(1008, 'invalid synthetic command'); return;
      }
      requests.push({ id: request.id, method: request.method, session: request.sessionId ?? null });
      const envelope = { id: request.id, ...(request.sessionId ? { sessionId: request.sessionId } : {}) };
      if (request.method === 'Target.attachToTarget') {
        socket.send(JSON.stringify({ ...envelope, result: { sessionId: 'loopback-session' } }));
      } else if (request.method === 'Runtime.callFunctionOn') {
        socket.send(JSON.stringify({ method: 'Runtime.syntheticEvent', params: { marker: run }, sessionId: request.sessionId }));
        socket.send(JSON.stringify({ ...envelope, result: { result: { type: 'string', value: 'HDé7' } } }));
      } else {
        socket.send(JSON.stringify({ ...envelope, result: {} }));
      }
    },
  },
});
console.log(JSON.stringify({ kind: 'synthetic_cdp_wire', endpoint: `ws://127.0.0.1:${server.port}${path}`, run }));
for await (const input of Bun.stdin.stream()) {
  if (new TextDecoder().decode(input).includes('stop')) break;
}
await server.stop(true);
console.log(JSON.stringify({ kind: 'synthetic_cdp_wire_stopped', run, requests: requests.length, opened, closed, redirectDestinationHits }));
