// Dedicated synthetic page for an explicitly approved ordinary-Chrome trial.
// The test controller opens it once. No existing user tab is navigated, and
// this server has no browser-control API or access to Chrome profile data.
import { randomUUID } from 'node:crypto';

const run = randomUUID();
const path = `/heydash-fixture/${run}`;
const page = Bun.file(`${import.meta.dir}/BorrowedChromeFixture.html`);
let pageRequests = 0;
const server = Bun.serve({
  hostname: '127.0.0.1', port: 0,
  fetch(request) {
    const url = new URL(request.url);
    if (request.method !== 'GET' || url.pathname !== path || url.search !== '') {
      return new Response('not found', { status: 404 });
    }
    pageRequests++;
    return new Response(page, { headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' } });
  },
});
console.log(JSON.stringify({ kind: 'borrowed_chrome_fixture', url: `http://127.0.0.1:${server.port}${path}`, run }));
for await (const input of Bun.stdin.stream()) {
  if (new TextDecoder().decode(input).includes('stop')) break;
}
await server.stop(true);
console.log(JSON.stringify({ kind: 'borrowed_chrome_fixture_stopped', run, pageRequests }));
