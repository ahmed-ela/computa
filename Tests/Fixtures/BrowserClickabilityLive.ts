// Local-only, disposable observed-click fixture; no browser-control endpoint.
const run = crypto.randomUUID();
const route = `/clickability/${run}`;
const counts = { row: 0, card: 0, direct: 0, passive: 0 };
const server = Bun.serve({hostname: '127.0.0.1', port: 0, async fetch(request) {
  const url = new URL(request.url);
  if (url.pathname === `${route}/counts` && request.method === 'GET') return Response.json(counts);
  if (url.pathname === `${route}/event` && request.method === 'POST') {
    const id = await request.text();
    if (!Object.hasOwn(counts, id)) return new Response('invalid', {status:400});
    counts[id as keyof typeof counts]++;
    return new Response('ok');
  }
  if (request.method !== 'GET' || url.pathname !== route) return new Response('not found', {status:404});
  return new Response(`<!doctype html><html lang="en"><meta charset="utf-8">
<title>Mactopus clickability verification</title>
<style>body{font:18px system-ui;margin:40px}.candidate{cursor:pointer;padding:18px;border:1px solid #bbb;margin:12px}td{padding:16px}</style>
<h1>Mactopus clickability verification</h1>
<div role="grid" aria-label="Synthetic messages"><div role="row" tabindex="-1" class="candidate" id="row" aria-label="Open synthetic itinerary"><span role="gridcell">Open synthetic itinerary</span></div></div>
<div role="list"><div role="listitem" tabindex="0" class="candidate" id="card" aria-label="Open synthetic card">Open synthetic card</div></div>
<div role="group" id="direct" aria-label="Direct listener tile" class="candidate">Direct listener tile</div>
<div role="group" id="passive" aria-label="Passive text panel">Passive text panel</div>
<p role="status" id="result">No actions yet</p>
<script>
const counts={row:0,card:0,direct:0,passive:0};
function record(id){counts[id]++;document.getElementById('result').textContent=JSON.stringify(counts);fetch(location.pathname+'/event',{method:'POST',body:id});}
// Delegated handlers: selected rows/cards have no direct listener.
document.addEventListener('click',event=>{const item=event.target.closest('#row,#card');if(item)record(item.id);});
document.getElementById('direct').addEventListener('click',()=>record('direct'));
</script></html>`, {headers:{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store'}});
}});
console.log(JSON.stringify({url:`http://127.0.0.1:${server.port}${route}`,run}));
for await (const chunk of Bun.stdin.stream()) { if(new TextDecoder().decode(chunk).includes('stop'))break; }
await server.stop(true);
console.log(JSON.stringify({counts,run}));
