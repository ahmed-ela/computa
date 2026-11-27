// Test-only web page and a delayed Responses API reply. No external account needed.
import http from 'node:http';
import { randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';

const page = `<!doctype html><title>Workspace fixture</title><main>
<button id="confirm">Confirm workspace</button><p id="out"></p>
<script>
const marker = new URL(location.href).searchParams.get('check') || '';
document.querySelector('button').onclick = () => {
  document.cookie = 'workspace_check=' + encodeURIComponent(marker) + '; Max-Age=300; SameSite=Strict';
  document.querySelector('#out').textContent = 'Browser confirmed ' + marker;
};
</script></main>`;
http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url.startsWith('/page?')) {
    res.writeHead(200, { 'Content-Type': 'text/html' }).end(page);
    return;
  }
  if (req.method !== 'POST' || req.url !== '/v1/responses') {
    res.writeHead(404).end();
    return;
  }
  let body = '';
  for await (const chunk of req) {
    body += chunk;
    if (body.length > 2_000_000) { res.writeHead(413).end(); return; }
  }
  const marker = body.match(/roundtrip-[0-9a-f]{32}/)?.[0];
  if (!marker) { res.writeHead(400).end('Missing test marker'); return; }
  const id = randomUUID();
  const item = { type: 'message', id: 'msg_' + id, role: 'assistant', status: 'completed',
    content: [{ type: 'output_text', text: 'Finished ' + marker, annotations: [] }] };
  res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
  const event = (type, data) => res.write('data: ' + JSON.stringify({type, ...data}) + '\n\n');
  event('response.created', { response: {id, status: 'in_progress', output: []} });
  await delay(6000);
  event('response.output_item.done', { output_index: 0, item });
  event('response.completed', { response: {id, status: 'completed', output: [item],
    usage: {input_tokens: 1, output_tokens: 1, total_tokens: 2} } });
  res.end();
}).listen(8080, '0.0.0.0');
