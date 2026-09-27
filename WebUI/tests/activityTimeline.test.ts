import { describe, expect, test } from 'bun:test';
import { activityDisclosureOpen, activityTimeline, type ActivityGroup, type ActivityRow } from '../src/activityTimeline';
import type { EntrySnapshot, TaskSnapshot } from '../src/types';

const entry = (id: string, kind: EntrySnapshot['kind'], changes: Partial<EntrySnapshot> = {}): EntrySnapshot => ({
  id, kind, title: kind, body: `${kind} text`, timestamp: 100, ...changes,
});
const tool = (id: string, status = 'Succeeded', changes: Partial<EntrySnapshot> = {}): EntrySnapshot => entry(id, 'tool', {
  tool: { name: 'computer_v2_snapshot', summary: 'Inspect the interface', status, tone: 'neutral', input: '{}' },
  ...changes,
});
const task = (entries: EntrySnapshot[], changes: Partial<TaskSnapshot> = {}): TaskSnapshot => ({
  id: 'task-one', title: 'Test task', summary: '', status: 'Running', statusTone: 'blue', updatedAt: 100,
  workspace: '', model: 'test-model', modelSelectable: true, entries,
  queuedPrompts: [], queuePaused: false, canSteer: true, isBusy: true, ...changes,
});
const activity = (rows: ActivityRow[]): ActivityGroup[] => rows.flatMap((row) => row.kind === 'activity' ? [row.group] : []);
const outside = (rows: ActivityRow[]) => rows.filter((row): row is Extract<ActivityRow, { kind: 'entry' }> => row.kind === 'entry');

describe('activity timeline', () => {
  test('a draft without entries has no phantom activity', () => {
    expect(activityTimeline(task([], { status: 'Draft', isBusy: false }))).toEqual([]);
  });

  test('a running user turn gets one open preparation group before tools or reasoning arrive', () => {
    const rows = activityTimeline(task([entry('prompt', 'user')], { activeTurnStartedAt: 90 }));
    expect(rows.map((row) => row.kind)).toEqual(['entry', 'activity']);
    const [group] = activity(rows);
    expect(group.id).toBe('prompt');
    expect(group.entries).toEqual([]);
    expect(group.startedAt).toBe(90);
    expect(group.isRunning).toBe(true);
    expect(activityDisclosureOpen(group.isRunning, group.hasFinalAnswer)).toBe(true);
  });

  test('approval Waiting remains automatically open while its active-turn clock exists', () => {
    const rows = activityTimeline(task([entry('prompt', 'user'), tool('approve', 'Needs approval')], {
      status: 'Waiting', activeTurnStartedAt: 90,
    }));
    const [group] = activity(rows);
    expect(group.isRunning).toBe(true);
    expect(activityDisclosureOpen(group.isRunning, group.hasFinalAnswer)).toBe(true);
    expect(outside(rows).map(({ entry }) => entry.id)).toEqual(['prompt', 'approve']);
  });

  test('reasoning and ordinary tools share one group without duplicate outside rows', () => {
    const rows = activityTimeline(task([
      entry('prompt', 'user'), entry('thought-one', 'reasoning'), tool('read'),
      entry('commentary', 'assistant', { assistantPhase: 'commentary' }),
      entry('thought-two', 'reasoning'), tool('click', 'Running'),
    ]));
    expect(activity(rows)).toHaveLength(1);
    expect(activity(rows)[0].entries.map(({ id }) => id)).toEqual(['thought-one', 'read', 'thought-two', 'click']);
    expect(outside(rows).map(({ entry }) => entry.id)).toEqual(['prompt', 'commentary']);
    expect(activity(rows)[0].hasFinalAnswer).toBe(false);
  });

  test('failed and approval tools retain compact history and visible external detail', () => {
    const rows = activityTimeline(task([
      entry('prompt', 'user'), tool('succeeded'), tool('running', 'Running'),
      tool('failed', 'Failed'), tool('approval', 'Needs approval'),
    ]));
    expect(activity(rows)[0].entries.map(({ id }) => id)).toEqual(['succeeded', 'running', 'failed', 'approval']);
    expect(outside(rows).map(({ entry }) => entry.id)).toEqual(['prompt', 'failed', 'approval']);
    expect(new Set(outside(rows).map(({ entry }) => entry.id)).size).toBe(outside(rows).length);
  });

  test('a tool becoming failed or approval-needed is immediately exposed outside', () => {
    for (const status of ['Failed', 'Needs approval']) {
      const before = activityTimeline(task([entry('prompt', 'user'), tool('same-tool', 'Running')]));
      const after = activityTimeline(task([entry('prompt', 'user'), tool('same-tool', status)]));
      expect(outside(before).map(({ entry }) => entry.id)).toEqual(['prompt']);
      expect(outside(after).map(({ entry }) => entry.id)).toEqual(['prompt', 'same-tool']);
      expect(activity(after)[0].entries.map(({ id }) => id)).toEqual(['same-tool']);
      expect(activity(after)[0].id).toBe(activity(before)[0].id);
    }
  });

  test('system messages are always external and never hidden within activity', () => {
    const rows = activityTimeline(task([
      entry('prompt', 'user'), entry('info', 'system'), entry('thought', 'reasoning'),
      entry('failure', 'system'), entry('answer', 'assistant', { assistantPhase: 'final_answer' }),
    ]));
    expect(activity(rows)[0].entries.map(({ id }) => id)).toEqual(['thought']);
    expect(outside(rows).map(({ entry }) => entry.id)).toEqual(['prompt', 'info', 'failure', 'answer']);
  });

  test('blank and synthetic reasoning never become activity entries', () => {
    for (const body of ['', ' \n ', 'Reasoning completed.']) {
      const rows = activityTimeline(task([entry('prompt', 'user'), entry('thought', 'reasoning', { body })]));
      expect(activity(rows)[0].entries).toEqual([]);
      expect(outside(rows).map(({ entry }) => entry.id)).toEqual(['prompt']);
      const stopped = activityTimeline(task([entry('prompt', 'user'), entry('thought', 'reasoning', { body })], { status: 'Completed' }));
      expect(activity(stopped)).toEqual([]);
    }
  });

  test('commentary and unknown assistant phases are not final answers', () => {
    for (const assistantPhase of [undefined, 'commentary'] as const) {
      const rows = activityTimeline(task([
        entry('prompt', 'user'), entry('thought', 'reasoning'),
        entry('message', 'assistant', { assistantPhase, isStreaming: false }),
      ]));
      expect(activity(rows)[0].hasFinalAnswer).toBe(false);
      expect(outside(rows).map(({ entry }) => entry.id)).toEqual(['prompt', 'message']);
    }
  });

  test('a duration on commentary or unknown phase cannot prematurely end active work', () => {
    for (const assistantPhase of [undefined, 'commentary'] as const) {
      const rows = activityTimeline(task([
        entry('prompt', 'user'), entry('thought', 'reasoning'),
        entry('message', 'assistant', { assistantPhase, workedForSeconds: 30, isStreaming: false }),
      ]));
      expect(activity(rows)[0].hasFinalAnswer).toBe(false);
      expect(activity(rows)[0].workedForSeconds).toBeUndefined();
      expect(activity(rows)[0].timedAnswerID).toBeUndefined();
      expect(outside(rows).find(({ entry }) => entry.id === 'message')?.hideAnswerMetadata).toBe(false);
    }
  });

  test('a completed unknown-phase answer accepts authoritative native turn timing', () => {
    const rows = activityTimeline(task([
      entry('prompt', 'user'), entry('thought', 'reasoning'),
      entry('answer', 'assistant', { workedForSeconds: 12, isStreaming: false }),
    ], { status: 'Completed', isBusy: false }));
    expect(activity(rows)[0].hasFinalAnswer).toBe(true);
    expect(activity(rows)[0].workedForSeconds).toBe(12);
    expect(activity(rows)[0].timedAnswerID).toBe('answer');
    expect(outside(rows).at(-1)?.hideAnswerMetadata).toBe(true);
  });

  test('nonempty authoritative final text collapses activity before the turn ends', () => {
    const rows = activityTimeline(task([
      entry('prompt', 'user'), entry('thought', 'reasoning'),
      entry('answer', 'assistant', { assistantPhase: 'final_answer', isStreaming: true, body: 'The answer' }),
    ]));
    const [group] = activity(rows);
    expect(group.isRunning).toBe(true);
    expect(group.hasFinalAnswer).toBe(true);
    expect(activityDisclosureOpen(group.isRunning, group.hasFinalAnswer)).toBe(false);
    expect(outside(rows).map(({ entry }) => entry.id)).toEqual(['prompt', 'answer']);
    expect(group.entries.map(({ id }) => id)).toEqual(['thought']);
  });

  test('empty final placeholders do not collapse activity or create empty answer rows', () => {
    for (const body of ['', ' \n ']) {
      const rows = activityTimeline(task([
        entry('prompt', 'user'), entry('thought', 'reasoning'),
        entry('answer', 'assistant', { assistantPhase: 'final_answer', isStreaming: true, body }),
      ]));
      expect(activity(rows)[0].hasFinalAnswer).toBe(false);
      expect(outside(rows).map(({ entry }) => entry.id)).toEqual(['prompt']);
    }
  });

  test('completed final duration appears on the group and only its answer metadata is hidden', () => {
    const rows = activityTimeline(task([
      entry('prompt', 'user'), tool('read'),
      entry('commentary', 'assistant', { assistantPhase: 'commentary' }),
      entry('answer', 'assistant', { assistantPhase: 'final_answer', workedForSeconds: 81, timestamp: 181 }),
    ], { status: 'Completed' }));
    const [group] = activity(rows);
    expect(group.workedForSeconds).toBe(81);
    expect(group.timedAnswerID).toBe('answer');
    expect(group.timestamp).toBe(181);
    expect(group.isRunning).toBe(false);
    expect(outside(rows).map(({ entry, hideAnswerMetadata }) => [entry.id, hideAnswerMetadata])).toEqual([
      ['prompt', false], ['commentary', false], ['answer', true],
    ]);
  });

  test('invalid durations never transfer or hide answer metadata', () => {
    for (const workedForSeconds of [undefined, -1, Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY]) {
      const rows = activityTimeline(task([
        entry('prompt', 'user'), entry('thought', 'reasoning'),
        entry('answer', 'assistant', { assistantPhase: 'final_answer', workedForSeconds }),
      ], { status: 'Completed' }));
      expect(activity(rows)[0].workedForSeconds).toBeUndefined();
      expect(activity(rows)[0].timedAnswerID).toBeUndefined();
      expect(outside(rows).at(-1)?.hideAnswerMetadata).toBe(false);
    }
  });

  test('zero is a valid completed duration but streaming final duration is not yet transferred', () => {
    for (const isStreaming of [false, true]) {
      const rows = activityTimeline(task([
        entry('prompt', 'user'), tool('read'),
        entry('answer', 'assistant', { assistantPhase: 'final_answer', workedForSeconds: 0, isStreaming }),
      ], { status: isStreaming ? 'Running' : 'Completed' }));
      expect(activity(rows)[0].workedForSeconds).toBe(isStreaming ? undefined : 0);
      expect(outside(rows).at(-1)?.hideAnswerMetadata).toBe(!isStreaming);
      expect(activity(rows)[0].hasFinalAnswer).toBe(true);
    }
  });

  test('group identity remains stable from preparation through streamed entries and final text', () => {
    const prompt = entry('prompt', 'user', { activityGroupID: 'native-turn' });
    const additions = [
      entry('blank-thought', 'reasoning', { body: '', activityGroupID: 'native-turn' }),
      entry('thought', 'reasoning', { activityGroupID: 'native-turn' }),
      tool('read', 'Succeeded', { activityGroupID: 'native-turn' }),
      entry('answer', 'assistant', { assistantPhase: 'final_answer', activityGroupID: 'native-turn' }),
    ];
    for (let count = 0; count <= additions.length; count += 1) {
      const rows = activityTimeline(task([prompt, ...additions.slice(0, count)], { activeActivityGroupID: 'native-turn' }));
      expect(activity(rows).map(({ id }) => id)).toEqual(['native-turn']);
    }
  });

  test('steering preserves native turn ownership and does not create another dropdown', () => {
    const own = { activityGroupID: 'original-turn' };
    const rows = activityTimeline(task([
      entry('original-prompt', 'user', own), entry('thought-one', 'reasoning', own),
      entry('steering-prompt', 'user', own), tool('read', 'Succeeded', own), entry('thought-two', 'reasoning', own),
    ], { activeActivityGroupID: 'original-turn', activeTurnStartedAt: 90 }));
    expect(activity(rows).map(({ id }) => id)).toEqual(['original-turn']);
    expect(activity(rows)[0].entries.map(({ id }) => id)).toEqual(['thought-one', 'read', 'thought-two']);
    expect(activity(rows)[0].isRunning).toBe(true);
    expect(outside(rows).map(({ entry }) => entry.id)).toEqual(['original-prompt', 'steering-prompt']);
  });

  test('multiple turns keep separate groups and only the active turn runs', () => {
    const rows = activityTimeline(task([
      entry('prompt-one', 'user', { activityGroupID: 'turn-one' }),
      entry('thought-one', 'reasoning', { activityGroupID: 'turn-one' }),
      entry('answer-one', 'assistant', { activityGroupID: 'turn-one', assistantPhase: 'final_answer', workedForSeconds: 5 }),
      entry('prompt-two', 'user', { activityGroupID: 'turn-two' }),
      entry('thought-two', 'reasoning', { activityGroupID: 'turn-two' }),
    ], { activeActivityGroupID: 'turn-two', activeTurnStartedAt: 110 }));
    expect(activity(rows).map(({ id, isRunning, hasFinalAnswer, workedForSeconds }) =>
      [id, isRunning, hasFinalAnswer, workedForSeconds],
    )).toEqual([['turn-one', false, true, 5], ['turn-two', true, false, undefined]]);
    expect(activity(rows)[1].startedAt).toBe(110);
  });

  test('legacy entries conservatively use user boundaries without borrowing finality or duration', () => {
    const rows = activityTimeline(task([
      entry('prompt-one', 'user'), entry('thought-one', 'reasoning'),
      entry('prompt-two', 'user'), entry('thought-two', 'reasoning'),
      entry('answer-two', 'assistant', { assistantPhase: 'final_answer', workedForSeconds: 7 }),
    ], { status: 'Completed', isBusy: false }));
    expect(activity(rows).map(({ id, hasFinalAnswer, workedForSeconds }) =>
      [id, hasFinalAnswer, workedForSeconds],
    )).toEqual([['prompt-one', false, undefined], ['prompt-two', true, 7]]);
  });

  test('a stopped failed turn keeps its failure visible even when activity defaults closed', () => {
    const rows = activityTimeline(task([
      entry('prompt', 'user'), tool('failed', 'Failed'), entry('error', 'system'),
    ], { status: 'Waiting', isBusy: false }));
    const [group] = activity(rows);
    expect(group.isRunning).toBe(false);
    expect(group.hasFinalAnswer).toBe(false);
    expect(activityDisclosureOpen(group.isRunning, group.hasFinalAnswer)).toBe(false);
    expect(outside(rows).map(({ entry }) => entry.id)).toEqual(['prompt', 'failed', 'error']);
  });

  test('a completed text-only turn has no empty activity group and keeps its metadata', () => {
    const rows = activityTimeline(task([
      entry('prompt', 'user'),
      entry('answer', 'assistant', { assistantPhase: 'final_answer', workedForSeconds: 1 }),
    ], { status: 'Completed' }));
    expect(activity(rows)).toEqual([]);
    expect(outside(rows).at(-1)?.hideAnswerMetadata).toBe(false);
  });

  test('projection does not mutate the native snapshot', () => {
    const input = task([
      entry('prompt', 'user'), entry('thought', 'reasoning'), tool('read'),
      entry('answer', 'assistant', { assistantPhase: 'final_answer', workedForSeconds: 7 }),
    ]);
    const original = structuredClone(input);
    activityTimeline(input);
    expect(input).toEqual(original);
  });
});
