#!/usr/bin/env bun
// Deterministic transport only. No desktop or model operations occur here.
import { createInterface } from 'node:readline';
import { existsSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
const home = process.env.CODEX_HOME!;
const emit = (x: unknown) => process.stdout.write(JSON.stringify(x) + '\n');
const result = (id: unknown, value: unknown = {}) => emit({ id, result: value });
const threadId = 'native-failure-task';
const notify = (method: string, params: object) => emit({ method, params: { threadId, ...params } });
let count = 0;
const input = createInterface({ input: process.stdin });
input.on('line', line => {
  const msg = JSON.parse(line);
  if (!Object.hasOwn(msg, 'id')) return;
  if (!msg.method) {
    if (msg.id === 'failure-request') writeFileSync(join(home, 'result-received'), 'yes');
    return;
  }
  switch (msg.method) {
    case 'initialize': result(msg.id, { userAgent: 'native-failure-fixture' }); break;
    case 'thread/list': result(msg.id, { data: [{ id: threadId, model: 'lmstudio-community/Qwen3.5-4B-MLX-4bit', status: { type: 'idle' } }] }); break;
    case 'thread/resume': result(msg.id, { thread: { id: threadId, turns: [], status: { type: 'idle' } },
      initialTurnsPage: { data: [], nextCursor: null, hasMore: false }, model: 'lmstudio-community/Qwen3.5-4B-MLX-4bit' }); break;
    case 'thread/name/set': result(msg.id); break;
    case 'turn/start': {
      count++;
      const turnId = count === 1 ? 'native-failure-turn' : 'next-turn';
      result(msg.id, { turn: { id: turnId, status: 'inProgress' } });
      notify('turn/started', { turn: { id: turnId, status: 'inProgress' } });
      if (count === 1) {
        setTimeout(() => emit({ id: 'failure-request', method: 'item/tool/call', params: {
          threadId, turnId, callId: 'activation-call', tool: 'computer_v2_open', arguments: { bundle_id: 'com.google.Chrome' },
        } }), 10);
      } else {
        emit({ id: 'stale-tool-after-resume', method: 'item/tool/call', params: {
          threadId, turnId: 'native-failure-turn', callId: 'stale-call', tool: 'computer_v2_status', arguments: {},
        } });
        notify('item/agentMessage/delta', { turnId: 'native-failure-turn', itemId: 'stale-answer',
          delta: 'STALE_EXPLANATION_MUST_NOT_STREAM' });
        notify('item/completed', { turnId: 'native-failure-turn', item: {
          id: 'stale-answer', type: 'agentMessage', phase: 'final_answer', text: 'STALE_EXPLANATION_MUST_NOT_APPEAR',
        } });
        notify('item/completed', { turnId, item: { id: 'next-answer', type: 'agentMessage', phase: 'final_answer', text: 'NEXT_TURN_OK' } });
        notify('turn/completed', { turn: { id: turnId, status: 'completed', error: null } });
      }
      break;
    }
    case 'turn/interrupt': {
      // Interruption must arrive while the tool response is still withheld.
      writeFileSync(join(home, 'interrupt-order'), existsSync(join(home, 'result-received')) ? 'wrong' : 'interrupt-first');
      emit({ id: 'late-tool', method: 'item/tool/call', params: {
        threadId, turnId: 'native-failure-turn', callId: 'late-call', tool: 'computer_v2_status', arguments: {},
      } });
      notify('item/agentMessage/delta', { turnId: 'native-failure-turn', itemId: 'late-answer',
        delta: 'UNSUPPORTED_CAUSE_MUST_NOT_STREAM' });
      notify('item/completed', { turnId: 'native-failure-turn', item: {
        id: 'late-answer', type: 'agentMessage', phase: 'final_answer', text: 'UNSUPPORTED_CAUSE_MUST_NOT_APPEAR',
      } });
      if (existsSync(join(home, 'interrupt-fails'))) {
        emit({ id: msg.id, error: { code: -1, message: 'Synthetic interrupt failed' } });
      } else {
        result(msg.id);
        setTimeout(() => notify('turn/completed', { turn: { id: 'native-failure-turn', status: 'interrupted', error: null } }), 20);
      }
      break;
    }
    default: emit({ id: msg.id, error: { code: -32601, message: 'Unexpected fixture method: ' + msg.method } });
  }
});
input.on('close', () => process.exit(0));
