#!/usr/bin/env bun
import { appendFileSync } from 'node:fs';
import { join } from 'node:path';
import { createInterface } from 'node:readline';

const history = Array.from({ length: 1717 }, (_, index) => ({
  id: '00000000-0000-4000-8000-' + (index + 1).toString().padStart(12, '0'),
  name: 'Saved chat ' + (index + 1), cwd: '/fixture', model: 'fixture',
  status: { type: 'idle' }, updatedAt: 1_790_000_000 - index,
}));
const oldest = history.at(-1)!;
let firstRead = true;
const reply = (body: object) => process.stdout.write(JSON.stringify(body) + '\n');

for await (const line of createInterface({ input: process.stdin })) {
  const { id, method, params } = JSON.parse(line);
  if (id == null || !method) continue;
  if (method === 'initialize') {
    reply({ id, result: { userAgent: 'sidebar-history-fixture' } });
  } else if (method === 'thread/list') {
    const start = Number(params.cursor ?? 0);
    const end = start + params.limit;
    reply({ id, result: { data: history.slice(start, end), nextCursor: end < history.length ? String(end) : null } });
  } else if (method === 'thread/read') {
    const thread = history.find(row => row.id === params.threadId);
    if (!thread) throw new Error('Unknown fixture chat');
    appendFileSync(join(process.env.CODEX_HOME!, 'read-ids'), thread.id + '\n');
    if (thread === oldest && firstRead) {
      firstRead = false;
      reply({ id, error: { code: -32000, message: 'Synthetic first read failure' } });
    } else {
      const turns = [{ id: 'turn', status: 'completed', items: [
        { id: 'user', type: 'userMessage', content: [{ type: 'text', text: 'Fixture question' }] },
        { id: 'answer', type: 'agentMessage', text: 'Transcript for ' + thread.name },
      ] }];
      reply({ id, result: { thread: { ...thread, turns } } });
    }
  } else {
    reply({ id, error: { code: -32601, message: 'Unexpected fixture method ' + method } });
  }
}
