#!/usr/bin/env bun
// Inert owned JSON-RPC fixture using the real native Responses HTTP boundary.
// It emits terminal completion without an error notification; no website/UI.
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
const home = process.env.CODEX_HOME!;
const file = join(home, 'saved-fixture-thread.json');
const threadID = '00000000-0000-4000-a000-000000000001';
const turnID = '00000000-0000-4000-a000-000000000002';
let provider: any;
let model = 'browser/claude';
const saved = () => existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : null;
const emit = (value: unknown) => process.stdout.write(JSON.stringify(value) + '\n');
const result = (id: unknown, value: unknown = {}) => emit({ id, result: value });
createInterface({ input: process.stdin }).on('line', async line => {
  const request = JSON.parse(line), params = request.params ?? {};
  if (!request.method || !Object.hasOwn(request, 'id')) return;
  switch (request.method) {
    case 'initialize': result(request.id, { userAgent: 'cleanup-completion-fixture' }); break;
    case 'thread/list': result(request.id, { data: saved() ? [{ id: threadID, model, cwd: home, status: { type: 'notLoaded' } }] : [], nextCursor: null }); break;
    case 'thread/read': result(request.id, { thread: saved() }); break;
    case 'thread/start':
      model = params.model; provider = params.config['model_providers.web_browser'];
      result(request.id, { thread: { id: threadID, turns: [] } }); break;
    case 'thread/name/set': result(request.id); break;
    case 'turn/start': {
      const startedAt = Math.floor(Date.now() / 1000);
      result(request.id, { turn: { id: turnID, status: 'inProgress' } });
      emit({ method: 'turn/started', params: { threadId: threadID, turn: { id: turnID, status: 'inProgress' } } });
      const response = await fetch(provider.base_url + '/responses', { method: 'POST',
        headers: { ...provider.http_headers, 'content-type': 'application/json' },
        body: JSON.stringify({ model, input: 'Synthetic terminal-completion failure', tools: [], stream: false,
          client_metadata: { 'x-codex-turn-metadata': JSON.stringify({ thread_id: threadID, turn_id: turnID }) } }) });
      const body = await response.json();
      if (response.ok || !body.error) throw Error('Expected exact native failure');
      const turn = { id: turnID, status: 'failed', error: body.error, startedAt, completedAt: Math.floor(Date.now() / 1000),
        items: [{ id: 'user-' + turnID, type: 'userMessage', content: params.input }] };
      writeFileSync(file, JSON.stringify({ id: threadID, model, turns: [turn] }));
      emit({ method: 'turn/completed', params: { threadId: threadID, turn } });
      break;
    }
    case 'turn/interrupt': result(request.id); break;
    default: result(request.id);
  }
});
