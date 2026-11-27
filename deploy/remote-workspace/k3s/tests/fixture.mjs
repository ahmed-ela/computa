// Only deployed in the disposable qualification namespace.
import http from 'node:http';
const page = `<!doctype html><title>Workspace handoff</title>
<label>Takeover input <input autofocus id="entry"></label><p id="evidence"></p>
<script>
const field = document.querySelector('input');
const show = () => document.querySelector('p').textContent = 'Viewer entered ' + (localStorage.note || 'nothing');
field.oninput = () => { localStorage.note = field.value; show(); };
show();
</script>`;

http.createServer(async (req, res) => {
  if (req.url === '/page') return res.writeHead(200, {'content-type':'text/html'}).end(page);
  if (!req.url.startsWith('/v1/messages') || req.method !== 'POST') return res.writeHead(404).end();
  let body = '';
  for await (const chunk of req) body += chunk;
  const input = JSON.parse(body);
  const tool = 'mcp__browser__browser_snapshot';
  const result = input.messages.flatMap(m => Array.isArray(m.content) ? m.content : [])
    .find(c => c.type === 'tool_result' && !c.is_error);
  const proof = result && JSON.stringify(result.content).match(/Viewer entered (handoff[a-f0-9]{12})/);
  const call = !result && input.tools?.some(t => t.name === tool);
  const content = call ? {type:'tool_use', id:'toolu_readtab', name:tool, input:{}}
    : {type:'text', text:proof ? 'Observed ' + proof[1] : 'Missing browser evidence'};
  const reason = call ? 'tool_use' : 'end_turn';
  const message = {type:'message', id:'msg_fixture', role:'assistant', model:input.model,
    usage:{input_tokens:10, output_tokens:10}, content:[content], stop_reason:reason, stop_sequence:null};
  if (!input.stream) return res.writeHead(200, {'content-type':'application/json'}).end(JSON.stringify(message));
  res.writeHead(200, {'content-type':'text/event-stream'});
  const event = (type, data) => res.write('event: ' + type + '\ndata: ' + JSON.stringify({type, ...data}) + '\n\n');
  event('message_start', {message:{...message, content:[], stop_reason:null}});
  event('content_block_start', {index:0, content_block:call ? content : {type:'text', text:''}});
  if (!call) event('content_block_delta', {index:0, delta:{type:'text_delta', text:content.text}});
  event('content_block_stop', {index:0});
  event('message_delta', {delta:{stop_reason:reason, stop_sequence:null}, usage:{output_tokens:10}});
  event('message_stop', {});
  res.end();
}).listen(8080);
