#!/usr/bin/env bun
// Deterministic production-transport fixture. It never loads a model or uses
// the desktop. Marker barriers prove delivery before completion, not merely
// that a sufficiently long sleep happened to expose an intermediate frame.
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createInterface } from 'node:readline';

const root = process.env.CODEX_HOME!;
const scenario = readFileSync(join(root, 'scenario'), 'utf8').trim();
const threadId = 'streaming-thread';
const model = 'lmstudio-community/Qwen3.5-4B-MLX-4bit';
const emit = (value: unknown) => process.stdout.write(JSON.stringify(value) + '\n');
const result = (id: unknown, value: unknown = {}) => emit({ id, result: value });
const notify = (method: string, params: object) => emit({ method, params: { threadId, ...params } });
const mark = (name: string) => writeFileSync(join(root, name), 'ready');
let turnCount = 0;
let currentTurn = '';
const timers = new Set<ReturnType<typeof setInterval>>();

function afterMarker(name: string, action: () => void) {
  const timer = setInterval(() => {
    if (!existsSync(join(root, name))) return;
    clearInterval(timer);
    timers.delete(timer);
    action();
  }, 5);
  timers.add(timer);
}
function delta(turnId: string, text: string, itemId = 'streamed-answer') {
  notify('item/agentMessage/delta', { turnId, itemId, delta: text });
}
function startItem(turnId: string, itemId: string, phase: unknown = 'final_answer') {
  notify('item/started', { turnId, item: { id: itemId, type: 'agentMessage', phase, text: '' } });
}
function completeItem(turnId: string, text: string, itemId = 'streamed-answer', phase: unknown = 'final_answer') {
  notify('item/completed', { turnId, item: { id: itemId, type: 'agentMessage', phase, text } });
}
function reasoningDelta(turnId: string, text: string, itemId = 'reasoning-item', contentIndex: unknown = 0) {
  notify('item/reasoning/textDelta', { turnId, itemId, contentIndex, delta: text });
}
function reasoningItem(turnId: string, content: string[], summary: string[] = [], itemId = 'reasoning-item') {
  notify('item/completed', { turnId, item: { id: itemId, type: 'reasoning', content, summary } });
}
function completeTurn(turnId: string, status = 'completed') {
  notify('turn/completed', { turn: { id: turnId, status, error: null } });
}
function fence(turnId: string, value: number) {
  // A public runtime event after rejected frames lets the test deterministically
  // observe that those frames were consumed before asserting their absence.
  notify('thread/tokenUsage/updated', { turnId, tokenUsage: {
    modelContextWindow: 7_782,
    last: { totalTokens: value, inputTokens: value, outputTokens: 0, cachedInputTokens: 0, reasoningOutputTokens: 0 },
    total: { totalTokens: value, inputTokens: value, outputTokens: 0, cachedInputTokens: 0, reasoningOutputTokens: 0 },
  } });
}
function lateOutput(turnId: string) {
  startItem(turnId, 'late-new-item');
  reasoningDelta(turnId, 'LATE_REASONING_MUST_NOT_APPEAR', 'late-reasoning');
  reasoningItem(turnId, ['LATE_REASONING_FINAL_MUST_NOT_APPEAR'], [], 'late-reasoning');
  delta(turnId, 'LATE_DELTA_MUST_NOT_APPEAR');
  delta(turnId, 'LATE_NEW_ITEM_MUST_NOT_APPEAR', 'late-new-item');
  completeItem(turnId, 'LATE_FINAL_MUST_NOT_APPEAR', 'late-new-item');
  fence(turnId, 1_001);
}

const input = createInterface({ input: process.stdin });
input.on('line', line => {
  const request = JSON.parse(line);
  if (!Object.hasOwn(request, 'id') || !request.method) return;
  switch (request.method) {
    case 'initialize': result(request.id, { userAgent: 'streaming-fixture' }); break;
    case 'thread/list': result(request.id, { data: [], nextCursor: null }); break;
    case 'thread/start': result(request.id, { thread: { id: threadId, turns: [] } }); break;
    case 'thread/resume': result(request.id, {
      thread: { id: threadId, status: { type: 'idle' }, turns: [] },
      initialTurnsPage: { data: [], nextCursor: null, hasMore: false }, model,
    }); break;
    case 'thread/name/set': result(request.id); break;
    case 'turn/start': {
      const turnId = currentTurn = `streaming-turn-${++turnCount}`;
      result(request.id, { turn: { id: turnId, status: 'inProgress' } });
      notify('turn/started', { turn: { id: turnId, status: 'inProgress' } });
      if (turnCount > 1) {
        reasoningDelta('streaming-turn-1', 'STALE_REASONING_MUST_NOT_APPEAR');
        delta('streaming-turn-1', 'STALE_PREVIOUS_TURN_MUST_NOT_APPEAR');
        delta(turnId, 'New turn');
        completeItem(turnId, 'New turn completed.');
        completeTurn(turnId);
        fence(turnId, 1_002);
      } else if (scenario === 'phase-contract') {
        startItem('wrong-turn', 'wrong-turn-phase');
        notify('item/started', { threadId: 'wrong-thread', turnId, item: {
          id: 'wrong-thread-phase', type: 'agentMessage', phase: 'final_answer', text: '',
        } });
        startItem(turnId, '', 'final_answer');
        startItem(turnId, '   ', 'final_answer');
        notify('item/started', { item: { id: 'missing-turn-phase', type: 'agentMessage', phase: 'final_answer' } });
        startItem(turnId, 'commentary', 'commentary');
        startItem(turnId, 'commentary', 'commentary');
        fence(turnId, 1_000);
        afterMarker('release-phase-text', () => {
          delta(turnId, 'Working update', 'commentary');
          completeItem(turnId, 'Working update.', 'commentary', 'commentary');
          startItem(turnId, 'commentary', 'final_answer');
          startItem(turnId, 'final', 'final_answer');
          delta(turnId, 'Final reply', 'final');
          completeItem(turnId, 'Final reply.', 'final', 'final_answer');
          completeItem(turnId, 'Final metadata supplied at completion.', 'completed-only');
          for (const [id, phase] of [['null-phase', null], ['unknown-phase', 'analysis'], ['numeric-phase', 1]]) {
            startItem(turnId, String(id), phase);
            completeItem(turnId, 'Unclassified text.', String(id), phase);
          }
          notify('item/started', { turnId, item: { id: 'missing-phase', type: 'agentMessage', text: '' } });
          notify('item/completed', { turnId, item: { id: 'missing-phase', type: 'agentMessage', text: 'Unclassified text.' } });
          completeTurn(turnId);
          lateOutput(turnId);
        });
      } else if (scenario === 'reasoning-progress') {
        reasoningDelta('wrong-turn', 'WRONG_TURN');
        notify('item/reasoning/textDelta', { threadId: 'wrong-thread', turnId, itemId: 'reasoning-item', contentIndex: 0, delta: 'WRONG_THREAD' });
        notify('item/reasoning/textDelta', { turnId, itemId: 'reasoning-item', delta: 'MISSING_INDEX' });
        notify('item/reasoning/textDelta', { itemId: 'reasoning-item', contentIndex: 0, delta: 'MISSING_TURN' });
        notify('item/reasoning/textDelta', { turnId, contentIndex: 0, delta: 'MISSING_ITEM' });
        for (const invalid of [-1, 64, 0.5, true]) reasoningDelta(turnId, 'INVALID_INDEX', 'reasoning-item', invalid);
        reasoningDelta(turnId, 'EMPTY_ID', '');
        reasoningDelta(turnId, 'WHITESPACE_ID', '   ');
        reasoningDelta(turnId, 'Consider ');
        mark('first-reasoning-sent');
        afterMarker('release-reasoning', () => {
          reasoningDelta(turnId, 'facts');
          reasoningDelta(turnId, 'Check facts.', 'reasoning-item', 1);
          notify('item/reasoning/summaryTextDelta', { turnId, itemId: 'reasoning-item', summaryIndex: 0, delta: 'Duplicate summary must not replace raw text' });
          reasoningItem(turnId, ['Consider facts', 'Check facts.'], ['Concise duplicate']);
          reasoningDelta(turnId, 'LATE_COMPLETED_REASONING');
          reasoningItem(turnId, ['DUPLICATE_REASONING_FINAL']);
          delta(turnId, 'Public answer');
          completeItem(turnId, 'Public answer.');
          completeTurn(turnId);
          lateOutput(turnId);
        });
      } else if (scenario === 'reasoning-summary') {
        notify('item/reasoning/summaryPartAdded', { turnId, itemId: 'reasoning-item', summaryIndex: 1 });
        notify('item/reasoning/summaryTextDelta', { turnId, itemId: 'reasoning-item', summaryIndex: 1, delta: 'Second' });
        notify('item/reasoning/summaryPartAdded', { turnId, itemId: 'reasoning-item', summaryIndex: 0 });
        notify('item/reasoning/summaryTextDelta', { turnId, itemId: 'reasoning-item', summaryIndex: 0, delta: 'First' });
        notify('item/reasoning/summaryPartAdded', { turnId, itemId: 'reasoning-item', summaryIndex: 0 });
        notify('item/reasoning/summaryTextDelta', { turnId, itemId: 'reasoning-item', summaryIndex: 0, delta: ' continued' });
        reasoningItem(turnId, [], ['First continued', 'Second']);
        reasoningItem(turnId, [], [], 'empty-reasoning');
        completeItem(turnId, 'Public answer.');
        completeTurn(turnId);
        fence(turnId, 1_001);
      } else if (scenario === 'whitespace-tool' || scenario === 'empty-tool') {
        delta(turnId, '\n\n', 'before-tool');
        completeItem(turnId, scenario === 'empty-tool' ? '' : '\n\n', 'before-tool');
        fence(turnId, 1_000);
        afterMarker('release-tool-answer', () => {
          notify('item/completed', { turnId, item: {
            id: 'status-tool', type: 'dynamicToolCall', name: 'computer_v2_status', success: true,
          } });
          delta(turnId, '\n\nSTREAM_TOOL_OK', 'tool-answer');
          completeItem(turnId, '\n\nSTREAM_TOOL_OK', 'tool-answer');
          completeTurn(turnId);
          fence(turnId, 1_001);
        });
      } else if (scenario === 'progress') {
        delta('wrong-turn', 'WRONG_TURN_MUST_NOT_APPEAR');
        notify('item/agentMessage/delta', { threadId: 'wrong-thread', turnId, itemId: 'streamed-answer', delta: 'WRONG_THREAD' });
        notify('item/agentMessage/delta', { itemId: 'streamed-answer', delta: 'MISSING_TURN' });
        notify('item/agentMessage/delta', { turnId, delta: 'MISSING_ITEM' });
        delta(turnId, 'EMPTY_ITEM', '');
        delta(turnId, 'WHITESPACE_ITEM', '   ');
        delta(turnId, '');
        notify('item/agentMessage/delta', { turnId, itemId: 'streamed-answer', delta: 123 });
        delta(turnId, 'Hello');
        mark('first-delta-sent');
        afterMarker('release-item', () => {
          delta(turnId, ' world');
          completeItem(turnId, 'Hello world.');
          completeItem(turnId, 'DUPLICATE_FINAL_MUST_NOT_APPEAR');
          delta(turnId, 'DELTA_AFTER_ITEM_COMPLETION_MUST_NOT_APPEAR');
          fence(turnId, 1_000);
          mark('item-completed-sent');
          afterMarker('release-terminal', () => {
            completeTurn(turnId);
            lateOutput(turnId);
          });
        });
      } else if (scenario === 'retry') {
        delta(turnId, 'Before ');
        notify('error', { turnId, willRetry: true, error: { message: 'Synthetic recoverable transport error.' } });
        mark('retry-sent');
        afterMarker('release-retry', () => {
          delta(turnId, 'after retry');
          completeItem(turnId, 'Before after retry.');
          completeTurn(turnId);
          fence(turnId, 1_001);
        });
      } else if (scenario === 'retry-new-item') {
        startItem(turnId, 'streamed-answer', 'commentary');
        delta(turnId, 'Abandoned draft');
        notify('error', { turnId, willRetry: true, error: { message: 'Synthetic retry with a replacement item.' } });
        mark('retry-sent');
        afterMarker('release-retry', () => {
          startItem(turnId, 'replacement-answer', 'final_answer');
          delta(turnId, 'Replacement', 'replacement-answer');
          startItem(turnId, 'streamed-answer', 'final_answer');
          delta(turnId, 'ABANDONED_DELTA_MUST_NOT_APPEAR');
          completeItem(turnId, 'ABANDONED_FINAL_MUST_NOT_APPEAR');
          fence(turnId, 1_000);
          afterMarker('release-terminal', () => {
            completeItem(turnId, 'Replacement complete.', 'replacement-answer');
            completeTurn(turnId);
            fence(turnId, 1_001);
          });
        });
      } else if (scenario === 'terminal-error') {
        reasoningDelta(turnId, 'Unfinished local reasoning');
        delta(turnId, 'Unfinished text');
        mark('first-delta-sent');
        afterMarker('release-error', () => {
          notify('error', { turnId, willRetry: false, error: { message: 'Synthetic terminal streaming failure.' } });
          lateOutput(turnId);
        });
      } else if (scenario === 'interrupt' || scenario === 'context-stop') {
        reasoningDelta(turnId, 'Unfinished local reasoning');
        delta(turnId, 'Unfinished text');
        mark('first-delta-sent');
        if (scenario === 'context-stop') afterMarker('release-context-stop', () => {
          for (let index = 0; index < 3; index++) {
            const item = { id: `context-${index}`, type: 'contextCompaction' };
            notify('item/started', { turnId, item });
            startItem(turnId, `context-assistant-${index}`, 'final_answer');
            reasoningDelta(turnId, 'COMPACTION_REASONING_MUST_NOT_APPEAR', `context-reasoning-${index}`);
            delta(turnId, 'COMPACTION_TEXT_MUST_NOT_APPEAR', `context-prose-${index}`);
            notify('item/completed', { turnId, item });
          }
          delta(turnId, 'CONTEXT_STOPPED_TEXT_MUST_NOT_APPEAR', 'stopped-prose');
        });
      } else if (scenario === 'managed-compaction') {
        delta(turnId, 'Baseline');
        completeItem(turnId, 'Baseline.');
        completeTurn(turnId);
      } else throw new Error(`Unknown fixture scenario: ${scenario}`);
      break;
    }
    case 'turn/interrupt': {
      result(request.id);
      completeTurn(currentTurn, 'interrupted');
      lateOutput(currentTurn);
      break;
    }
    case 'thread/compact/start': {
      const turnId = 'managed-maintenance-turn';
      const item = { id: 'managed-compaction', type: 'contextCompaction' };
      notify('turn/started', { turn: { id: turnId, status: 'inProgress' } });
      notify('item/started', { turnId, item });
      startItem(turnId, 'maintenance-assistant', 'final_answer');
      reasoningDelta(turnId, 'PRIVATE_MAINTENANCE_REASONING_MUST_NOT_APPEAR', 'maintenance-reasoning');
      delta(turnId, 'PRIVATE_MAINTENANCE_TEXT_MUST_NOT_APPEAR', 'maintenance-prose');
      mark('maintenance-delta-sent');
      afterMarker('release-maintenance', () => {
        notify('item/completed', { turnId, item });
        completeTurn(turnId);
        result(request.id);
      });
      break;
    }
    case 'thread/inject_items': result(request.id); break;
    default: emit({ id: request.id, error: { code: -32601, message: `Unexpected fixture method: ${request.method}` } });
  }
});
input.on('close', () => {
  for (const timer of timers) clearInterval(timer);
  process.exit(0);
});
