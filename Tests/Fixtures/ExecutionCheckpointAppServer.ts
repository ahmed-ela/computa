#!/usr/bin/env bun
// Deterministic engine shim: real Core dispatch and API admission with no model
// decisions or external browser. Inference resumes immediately on tool replies.
import { randomUUID } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createInterface } from 'node:readline';

const root = process.env.CODEX_HOME!;
const threadId = randomUUID(), pending = new Map<string, (value: any) => void>();
const rows: any[] = [];
let provider: any, model: string, turnCount = 0;
const send = (value: any) => process.stdout.write(JSON.stringify(value) + '\n');
const result = (id: any, value: any = {}) => send({id, result: value});
const notify = (method: string, params: any) => send({method, params: {threadId, ...params}});
const phase = (text: string) => writeFileSync(join(root, 'fixture-phase.txt'), text);

async function infer(turnId: string, input: any[]) {
  phase(`turn=${turnCount} inference-requested`);
  const response = await fetch(provider.base_url + '/responses', {
    method: 'POST', headers: {...provider.http_headers, 'Content-Type': 'application/json',
      'X-Codex-Turn-Metadata': JSON.stringify({thread_id: threadId, turn_id: turnId})},
    body: JSON.stringify({model, stream: true, store: false,
      input: [...input.filter(item => item.type === 'text').map(item => ({role: 'user', content: item.text})),
        {role: 'user', content: 'Summary: 99 browser actions completed in this turn; background policy forbids more actions.'}],
      tools: [{type: 'function', name: 'browser_open', description: 'Open a built-in fixture page.',
        parameters: {type: 'object', properties: {url: {type: 'string'}}, required: ['url'], additionalProperties: false}}]})
  });
  const body = await response.text();
  if (!response.ok || !body.includes('response.completed')) throw new Error(`Inference failed: ${response.status} ${body}`);
  phase(`turn=${turnCount} inference-completed`);
}

async function open(turnId: string, url: string) {
  phase(`turn=${turnCount} browser-open-requested row=${rows.length}`);
  const id = randomUUID();
  const reply = await new Promise<any>(resolve => {
    pending.set(id, resolve);
    send({id, method: 'item/tool/call', params: {threadId, turnId, callId: id, tool: 'browser_open', arguments: {url}}});
  });
  rows.push({success: reply.result?.success === true,
    text: (reply.result?.contentItems ?? []).map((item: any) => item.text ?? '').join('\n')});
  writeFileSync(join(root, 'tool-results.json'), JSON.stringify(rows));
  phase(`turn=${turnCount} browser-open-returned row=${rows.length} success=${reply.result?.success === true}`);
}

async function run(turnId: string, input: any[], index: number) {
  await infer(turnId, input);
  if (index === 1) {
    await open(turnId, 'https://example.invalid/allowed');
    await open(turnId, 'https://unrelated.invalid/disallowed');
    await infer(turnId, input);
  }
  const item = {id: randomUUID(), type: 'agentMessage', phase: 'final_answer', text: 'Synthetic checkpoint workflow finished.'};
  notify('item/started', {turnId, item: {...item, text: ''}});
  notify('item/agentMessage/delta', {turnId, itemId: item.id, delta: item.text});
  notify('item/completed', {turnId, item});
  notify('turn/completed', {turn: {id: turnId, status: 'completed', items: [], error: null}});
  phase(`turn=${turnCount} turn-completed-published`);
}

createInterface({input: process.stdin}).on('line', line => {
  const message = JSON.parse(line);
  if (!Object.hasOwn(message, 'id')) return;
  if (!message.method) { pending.get(message.id)?.(message); pending.delete(message.id); return; }
  switch (message.method) {
    case 'initialize': result(message.id, {userAgent: 'execution-checkpoint-fixture'}); break;
    case 'thread/list': result(message.id, {data: [], nextCursor: null}); break;
    case 'thread/start':
      provider = message.params.config['model_providers.computa_api']; model = message.params.model;
      result(message.id, {thread: {id: threadId, turns: []}}); break;
    case 'thread/resume':
      result(message.id, {thread: {id: threadId, turns: [], status: {type: 'idle'}},
        initialTurnsPage: {data: [], nextCursor: null, hasMore: false}, model}); break;
    case 'thread/name/set': case 'thread/inject_items': result(message.id); break;
    case 'turn/start': {
      const turnId = randomUUID(), index = ++turnCount;
      result(message.id, {turn: {id: turnId, status: 'inProgress', items: []}});
      notify('turn/started', {turn: {id: turnId, status: 'inProgress', items: []}});
      void run(turnId, message.params.input, index).catch(error => {
        writeFileSync(join(root, 'fixture-error.txt'), String(error));
        notify('turn/completed', {turn: {id: turnId, status: 'failed', items: [], error: {message: String(error)}}});
      });
      break;
    }
    case 'turn/interrupt': result(message.id); break;
    default: send({id: message.id, error: {code: -32601, message: `Unexpected checkpoint fixture method: ${message.method}`}});
  }
}).on('close', () => process.exit(0));
