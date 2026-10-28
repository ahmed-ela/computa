import 'octane/compiler/register';
import { describe, expect, mock, test } from 'bun:test';
import { createElement as h } from 'octane';
import { renderToStaticMarkup } from 'octane/server';
import type { TaskSnapshot } from '../src/types';
mock.module('@octanejs/shadcn/Button', () => ({ Button: ({ variant: _variant, size: _size, ...props }: Record<string, unknown>) => h('button', props) }));
const { WebsiteSessionCleanupControl, websiteSessionCleanupAction } = await import('../src/WebsiteSessionCleanupControl');

const task = (changes: Partial<TaskSnapshot> = {}): TaskSnapshot => ({
  id: 'failed-website-task', title: 'Task', summary: '', status: 'Waiting', statusTone: 'orange',
  updatedAt: 0, workspace: '/tmp', model: 'browser/claude', modelSelectable: true,
  queuedPrompts: [], queuePaused: true, canSteer: false, isBusy: false, entries: [],
  websiteSessionCleanupAvailable: true, ...changes,
});
const render = (value: TaskSnapshot, blocked = false) => renderToStaticMarkup(h(WebsiteSessionCleanupControl, {
  task: value, blocked, post: () => {},
})).html;

describe('website cleanup recovery', () => {
  test('sends only the captured task ID to the cleanup-only action', () => {
    const action = websiteSessionCleanupAction(task());
    expect(action).toEqual({ action: 'retryWebsiteSessionCleanup', taskID: 'failed-website-task' });
    expect(Object.keys(action!)).toEqual(['action', 'taskID']);
    expect(render(task())).toContain('Retry website cleanup');
    expect(render(task())).toContain('keeping your local chat');
  });
  test('failed tasks can clean up without changing their failure or resuming input', () => {
    const value = task({ status: 'Failed', statusTone: 'red' });
    expect(websiteSessionCleanupAction(value)).toEqual({ action: 'retryWebsiteSessionCleanup', taskID: value.id });
    expect(render(value)).toContain('Retry website cleanup');
    expect(value.status).toBe('Failed');
    expect(value.queuePaused).toBe(true);
    expect(websiteSessionCleanupAction({ ...value, isBusy: true })).toBeUndefined();
    expect(websiteSessionCleanupAction(value, true)).toBeUndefined();
  });
  test('running, busy, unavailable, duplicate, approval and completed states cannot request cleanup', () => {
    for (const changes of [{ status: 'Running' }, { status: 'Completed' }, { isBusy: true },
      { websiteSessionCleanupAvailable: false }, { websiteSessionCleanupInProgress: true }]) {
      expect(websiteSessionCleanupAction(task(changes))).toBeUndefined();
    }
    expect(websiteSessionCleanupAction(task(), true)).toBeUndefined();
    expect(render(task(), true)).toMatch(/<button[^>]*disabled/);
  });
  test('in-progress cleanup is one disabled operation with a live status', () => {
    const html = render(task({ websiteSessionCleanupAvailable: false, websiteSessionCleanupInProgress: true, isBusy: true }));
    expect(html).toContain('aria-busy="true"');
    expect(html).toContain('role="status"');
    expect(html).toContain('aria-live="polite"');
    expect(html).toContain('Closing…');
    expect(html).toMatch(/<button[^>]*disabled/);
  });
  test('no-owned result makes no past deletion claim and offers no unnecessary retry', () => {
    const html = render(task({ websiteSessionCleanupAvailable: false, websiteSessionCleanupOutcome: 'no_owned_session' }));
    expect(html).toContain('No owned website session exists now');
    expect(html).toContain('Earlier website deletion is unconfirmed');
    expect(html).not.toContain('<button');
    expect(html).not.toContain('session is closed');
  });
  test('closed and unconfirmed results have separate fixed messages and persistence caveat', () => {
    expect(render(task({ websiteSessionCleanupAvailable: false, websiteSessionCleanupOutcome: 'closed' })))
      .toContain('owned website session is closed');
    const html = render(task({ websiteSessionCleanupOutcome: 'unconfirmed', websiteSessionCleanupReceiptSaved: false }));
    expect(html).toContain('cleanup remains unconfirmed');
    expect(html).toContain('receipt could not be saved locally');
    expect(html).toContain('Retry website cleanup');
  });
  test('authoritative original-session eligibility survives changing the current model selector', () => {
    expect(websiteSessionCleanupAction(task({ model: 'local/model', websiteSessionCleanupOutcome: 'unconfirmed' })))
      .toEqual({ action: 'retryWebsiteSessionCleanup', taskID: 'failed-website-task' });
  });
  test('historical or unavailable tasks have no recovery control', () => {
    expect(render(task({ websiteSessionCleanupAvailable: false }))).toBe('');
  });
});
