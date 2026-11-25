import 'octane/compiler/register';
import { describe, expect, test } from 'bun:test';
import { createElement as h } from 'octane';
import { renderToStaticMarkup } from 'octane/server';
import { sidebarAgentStatus, isTaskActive, startSidebarClock, taskElapsedLabel, type SidebarTaskActivity } from '../src/sidebarActivity';
import { makePreviewSnapshot } from '../src/preview';
const { TaskActivityIndicator } = await import('../src/TaskActivityIndicator');

const task = (changes: Partial<SidebarTaskActivity> = {}): SidebarTaskActivity => ({
  status: 'Running', isBusy: true, updatedAt: 190,
  activeTurnStartedAt: 100, hasUnreadCompletion: false, ...changes,
});
const render = (task: SidebarTaskActivity, now = 225) => renderToStaticMarkup(h(TaskActivityIndicator,
  { task, status: sidebarAgentStatus(task, false), compact: false, now })).html;

describe('sidebar activity', () => {
  test('the compact rail shows working turns and unread successful completions', () => {
    const completed = { status: 'Completed', hasUnreadCompletion: true, unreadCompletionID: 'finished-turn' };
    expect(sidebarAgentStatus(task(completed), true)).toBe('working');
    expect(sidebarAgentStatus(task({ ...completed, isBusy: false }), false)).toBe('ready');
    expect(sidebarAgentStatus(task({ ...completed, isBusy: false }), true)).toBeUndefined();
    expect(sidebarAgentStatus(task({ ...completed, isBusy: false, unreadCompletionID: undefined }), false)).toBeUndefined();
    for (const status of ['Draft', 'Waiting', 'Failed', 'Completed']) {
      expect(sidebarAgentStatus(task({ status, isBusy: false }), false)).toBeUndefined();
    }
  });
  test('elapsed time uses the current turn start even as activity updates arrive', () => {
    expect(taskElapsedLabel(task(), 225)).toBe('2m');
    expect(taskElapsedLabel(task({ updatedAt: 224 }), 225)).toBe('2m');
    expect(taskElapsedLabel(task({ activeTurnStartedAt: 220 }), 225)).toBe('5s');
    expect(taskElapsedLabel(task({ activeTurnStartedAt: undefined }), 225)).toBe('35s');
    expect(taskElapsedLabel(task({ activeTurnStartedAt: NaN, updatedAt: NaN }), 225)).toBe('0s');
    expect(taskElapsedLabel(task({ activeTurnStartedAt: 300 }), 225)).toBe('0s');
  });
  test('Running or native busy status uses elapsed text with no pulsing working dot', () => {
    for (const value of [task(), task({ isBusy: false }), task({ status: 'Preparing' })]) {
      expect(isTaskActive(value)).toBe(true);
      const html = render(value);
      expect(html).toContain('class="task-row-elapsed"');
      expect(html).toContain('>2m</span>');
      expect(html).not.toContain('is-running');
      expect(html).not.toContain('task-row-unread');
    }
    expect(render(task())).not.toContain('task-row-status');
  });
  test('only unread completion gets a blue indicator; read completion has none', () => {
    const completed = task({ status: 'Completed', isBusy: false });
    const unread = render({ ...completed, hasUnreadCompletion: true, unreadCompletionID: 'finished-turn' });
    expect(unread).toContain('task-row-unread');
    expect(unread).toContain('Completed, unread');
    expect(unread).not.toContain('tone-green');
    const read = render(completed);
    expect(read).not.toContain('task-row-status');
    expect(read).not.toContain('task-row-elapsed');
    expect(read).toContain('Completed');
  });
  test('drafts, waiting and failed tasks expose their status without drawing a notification dot', () => {
    for (const status of ['Draft', 'Failed', 'Waiting']) {
      for (const isBusy of [false, true]) {
        const html = render(task({ status, isBusy, hasUnreadCompletion: true, unreadCompletionID: 'older-turn' }));
        if (isBusy) {
          expect(html).toContain('task-row-elapsed');
          expect(html).not.toContain('task-row-status');
        } else {
          expect(html).not.toContain('task-row-status');
          expect(html).not.toContain('task-row-elapsed');
        }
        expect(html).toContain(status);
        expect(html).not.toContain('Completed');
        expect(html).not.toContain('task-row-unread');
      }
    }
  });
  test('one sidebar clock advances all rows without snapshots and disposes its interval', () => {
    let now = 159;
    let tick: (() => void) | undefined;
    let starts = 0;
    let stops = 0;
    const rows = [task(), task({ activeTurnStartedAt: 150 })];
    const labels: string[][] = [];
    const stop = startSidebarClock((time) => labels.push(rows.map((row) => taskElapsedLabel(row, time))), {
      now: () => now,
      everySecond: (callback) => { starts++; tick = callback; return () => { stops++; tick = undefined; }; },
    });
    expect(labels).toEqual([['59s', '9s']]);
    now = 160; tick?.();
    expect(labels.at(-1)).toEqual(['1m', '10s']);
    now = 3_700; tick?.();
    expect(labels.at(-1)).toEqual(['1h', '59m']);
    expect(starts).toBe(1);
    stop();
    expect(stops).toBe(1);
    expect(tick).toBeUndefined();
  });
  test('preview exercises running, unread completed, and read completed states', () => {
    const previewSnapshot = makePreviewSnapshot();
    expect(previewSnapshot.tasks.some((value) => isTaskActive(value) && value.activeTurnStartedAt !== undefined)).toBe(true);
    expect(previewSnapshot.tasks.some((value) => value.status === 'Completed' && value.hasUnreadCompletion && value.unreadCompletionID)).toBe(true);
    expect(previewSnapshot.tasks.some((value) => value.status === 'Completed' && !value.hasUnreadCompletion)).toBe(true);
  });
});
