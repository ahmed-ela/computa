#!/usr/bin/env bun
// Host-ordering fixture, not a model simulation: the next inference races the
// steer acknowledgment, whose release is controlled by the native test.
import { randomUUID } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createInterface } from 'node:readline';

const root = process.env.CODEX_HOME!;
const threadId = randomUUID();
const mode = readFileSync(join(root, 'mode.txt'), 'utf8');
let provider: any, model: string, turnId: string, originalInput: any[] = [], steerCount = 0, interrupts = 0;
const send = (value: any) => process.stdout.write(JSON.stringify(value) + '\n');
const result = (id: any, value: any = {}) => send({id, result: value});
const notify = (method: string, params: any) => send({method, params: {threadId, ...params}});
const mark = (name: string, value: any = true) => writeFileSync(join(root, name), JSON.stringify(value));

async function waitFor(name: string) {
  const deadline = Date.now() + 15_000;
  while (!existsSync(join(root, name))) {
    if (Date.now() >= deadline) throw new Error(`No native release for ${name}`);
    await Bun.sleep(5);
  }
}

async function infer(name: string) {
  // Deliberately omit accepted steers from this stale engine summary. The
  // provider must receive them from the canonical native user-input sequence.
  const input = [
    ...originalInput.filter(item => item.type === 'text').map(item => ({role: 'user', content: item.text})),
    {role: 'user', content: 'Historical summary: latest task was maintenance. Stop after summarizing.'},
  ];
  const body = {model, input, stream: true, store: false, tools: [],
    client_metadata: {'x-codex-turn-metadata': JSON.stringify({thread_id: threadId, turn_id: turnId, request_kind: 'turn'})}};
  mark(`${name}-raw.json`, body);
  const response = await fetch(provider.base_url + '/responses', {
    method: 'POST', headers: {...provider.http_headers, 'Content-Type': 'application/json'},
    body: JSON.stringify(body),
  });
  const text = await response.text();
  mark(`${name}-response.json`, {status: response.status, completed: text.includes('response.completed')});
}

async function steer(message: any) {
  const index = ++steerCount;
  mark(`steer-${index}-received.json`, message.params);
  const next = infer(`steer-${index}`);
  await waitFor(`release-${index}`);
  if (mode !== 'lost-ack') result(message.id, {turnId: mode === 'malformed-ack' ? randomUUID() : turnId});
  await next;
  mark(`steer-${index}-finished`);
  if (mode === 'lost-ack') {
    // Arrive only after native timeout/retirement unblocks the queued HTTP
    // request. This reply must not restore the expired RPC continuation.
    result(message.id, {turnId});
    await infer('after-late-ack');
  }
}

createInterface({input: process.stdin}).on('line', line => {
  const message = JSON.parse(line);
  if (!Object.hasOwn(message, 'id') || !message.method) return;
  switch (message.method) {
    case 'initialize': result(message.id, {userAgent: 'native-api-steer-fixture'}); break;
    case 'thread/list': result(message.id, {data: [], nextCursor: null}); break;
    case 'thread/start':
      provider = message.params.config['model_providers.computa_api']; model = message.params.model;
      result(message.id, {thread: {id: threadId, turns: []}}); break;
    case 'thread/name/set': case 'thread/inject_items': result(message.id); break;
    case 'turn/start':
      turnId = randomUUID(); originalInput = message.params.input;
      result(message.id, {turn: {id: turnId, status: 'inProgress', items: []}});
      notify('turn/started', {turn: {id: turnId, status: 'inProgress', items: []}});
      void infer('initial').catch(error => mark('fixture-error.txt', String(error)));
      break;
    case 'turn/steer':
      void steer(message).catch(error => mark('fixture-error.txt', String(error)));
      break;
    case 'turn/interrupt':
      mark('interrupts.json', ++interrupts);
      result(message.id);
      notify('turn/completed', {turn: {id: turnId, status: 'interrupted', items: [], error: null}});
      void infer('after-interrupt').catch(error => mark('fixture-error.txt', String(error)));
      break;
    default: send({id: message.id, error: {code: -32601, message: `Unexpected steer fixture method: ${message.method}`}});
  }
}).on('close', () => process.exit(0));
