import 'octane/compiler/register';
import { describe, expect, mock, test } from 'bun:test';
import { createElement as h } from 'octane';
import { renderToStaticMarkup } from 'octane/server';
import { parseUnifiedDiff } from '../src/reviewDiff';
import type { ReviewFile, ReviewOperation, ReviewState } from '../src/types';

// Static markup tests exercise our review presentation, not the interactive
// shadcn port's browser-only focus machinery. Production still uses those ports.
mock.module('@octanejs/shadcn/Button', () => ({ Button: ({ variant: _variant, size: _size, ...props }: Record<string, unknown>) => h('button', props) }));
mock.module('@octanejs/shadcn/Input', () => ({ Input: (props: Record<string, unknown>) => h('input', props) }));
mock.module('@octanejs/shadcn/Textarea', () => ({ Textarea: (props: Record<string, unknown>) => h('textarea', props) }));
mock.module('@octanejs/shadcn/NativeSelect', () => ({ NativeSelect: (props: Record<string, unknown>) => h('select', props), NativeSelectOption: (props: Record<string, unknown>) => h('option', props) }));
mock.module('../src/Icon', () => ({ Icon: () => h('span', { 'aria-hidden': 'true' }) }));
const { DiffView, ReviewPanel } = await import('../src/ReviewPanel');

const file = (changes: Partial<ReviewFile> = {}): ReviewFile => ({
  id: 'file-one', path: 'src/example.ts', status: 'modified', additions: 1, deletions: 1,
  binary: false, truncated: false,
  diff: '@@ -5,2 +5,2 @@\n shared\n-old()\n+new("<script>unsafe()</script>")\n',
  hunks: [{ id: 'native-hunk-one', header: '@@ -5,2 +5,2 @@', oldStart: 5, newStart: 5 }], ...changes,
});
const review = (changes: Partial<ReviewState> = {}): ReviewState => ({
  taskID: 'task', scope: 'unstaged', reference: '', loading: false,
  snapshot: { id: 'native-snapshot', workspace: '/tmp/project', scope: 'unstaged', revision: 'hash',
    files: [file()], canStage: true, canUnstage: false, canRevert: true }, ...changes,
});
const panel = (state?: ReviewState, busy = false) => renderToStaticMarkup(h(ReviewPanel, {
  taskID: 'task', review: state, busy, post: () => {}, onFeedback: () => {},
})).html;
const diff = (value: ReviewFile, split = false, mutations: ReviewOperation[] = []) => renderToStaticMarkup(h(DiffView, {
  file: value, parsed: parseUnifiedDiff(value.diff), split, wrap: false,
  allowHunkMutation: mutations, onMutation: () => {}, onFeedback: () => {},
})).html;

describe('file review UI', () => {
  test('provides scope, counters, file navigation, view controls and native-bound actions', () => {
    const html = panel(review());
    for (const label of ['Changes scope', 'Last turn', 'Unstaged', 'Staged', 'Against branch', 'Commit', 'Filter changed files', 'Unified', 'Split', 'Wrap', 'Viewed', 'Open file', 'Copy diff', 'Stage file', 'Revert file', 'Stage hunk', 'Revert hunk', 'Stage all', 'Revert all']) expect(html).toContain(label);
    expect(html).toContain('aria-label="Changed files"');
    expect(html).toContain('Current workspace changes include your edits and agent edits.');
    expect(html).not.toContain('Unstage file');
  });

  test('patch code and paths are escaped text and preserve numbered versions', () => {
    const html = diff(file());
    expect(html).toContain('&lt;script&gt;unsafe()&lt;/script&gt;');
    expect(html).not.toMatch(/<script\b/);
    const state = review(); state.snapshot!.files = [file({ path: '<script>path</script>.ts' })];
    expect(panel(state)).toContain('&lt;script&gt;path&lt;/script&gt;.ts');
    expect(html).toContain('previous line 6'); expect(html).toContain('new line 6');
    expect(html).toContain('diff-addition'); expect(html).toContain('diff-deletion');
    expect(html).toContain('aria-label="Collapse hunk 1"');
  });

  test('split view has separate versions and literal source text', () => {
    const html = diff(file(), true);
    expect(html).toContain('Split diff for src/example.ts');
    expect(html).toContain('Previous content'); expect(html).toContain('New content');
    expect(html.match(/shared/g)).toHaveLength(2);
    expect(html).toContain('old()'); expect(html).toContain('new(');
  });

  test('hunk controls require matching complete native hunk identities', () => {
    expect(diff(file(), false, ['stage'])).toContain('Stage hunk');
    expect(diff(file({ hunks: [] }), false, ['stage'])).not.toContain('Stage hunk');
    expect(diff(file({ hunks: [{ id: 'other', header: '@@ -1 +1 @@', oldStart: 1, newStart: 1 }] }), false, ['stage'])).not.toContain('Stage hunk');
    expect(diff(file({ truncated: true }), false, ['stage'])).not.toContain('Stage hunk');
    expect(diff(file({ diff: '@@ -1,2 +1,2 @@\n-old\n+new\n' }), false, ['stage'])).not.toContain('Stage hunk');
  });

  test('binary, truncated and metadata-only changes remain visible with explicit limits', () => {
    expect(diff(file({ binary: true, hunks: [] }))).toContain('Binary file changed');
    expect(diff(file({ truncated: true }))).toContain('diff was truncated');
    const metadata = diff(file({ previousPath: 'old.ts', diff: 'rename from old.ts\nrename to src/example.ts\n', hunks: [] }));
    expect(metadata).toContain('No text hunks'); expect(metadata).toContain('rename from old.ts');
  });

  test('binary file opening is disabled while native whole-file mutations remain available', () => {
    const state = review();
    state.snapshot!.files = [file({ binary: true, hunks: [] })];
    const html = panel(state);
    expect(html).toMatch(/<button\b[^>]*\bdisabled\b[^>]*>Open file<\/button>/);
    expect(html).toMatch(/<button\b(?![^>]*\bdisabled\b)[^>]*>Stage file<\/button>/);
    expect(html).toMatch(/<button\b(?![^>]*\bdisabled\b)[^>]*>Revert file<\/button>/);
    expect(html).not.toContain('Stage hunk');
  });

  test('parent-owned hunk collapse state survives reconstruction after a reload', () => {
    const value = file();
    const html = renderToStaticMarkup(h(DiffView, {
      file: value, parsed: parseUnifiedDiff(value.diff), split: false, wrap: false,
      allowHunkMutation: [], onMutation: () => {}, onFeedback: () => {},
      collapsedHunks: { 'file-one:native-hunk-one': true }, onHunkCollapse: () => {},
    })).html;
    expect(html).toContain('aria-label="Expand hunk 1"');
    expect(html).not.toContain('<table');
    expect(html).not.toContain('old()');
  });

  test('loading, missing snapshots, empty scopes and errors have clear states', () => {
    expect(panel(review({ loading: true }))).toContain('Loading changes…');
    expect(panel()).toContain('Choose a scope and refresh');
    const empty = review(); empty.snapshot = { ...empty.snapshot!, files: [] };
    expect(panel(empty)).toContain('No changes in this scope.');
    expect(panel(review({ error: 'Workspace changed. Refresh.' }))).toContain('role="alert"');
    expect(panel(review({ error: 'Workspace changed. Refresh.' }))).not.toContain('Stage file');
  });

  test('busy tasks, stale scope/reference and another task cannot offer mutations', () => {
    expect(panel(review(), true)).not.toContain('Stage file');
    expect(panel(review({ scope: 'staged' }))).not.toContain('Stage file');
    expect(panel(review({ taskID: 'other-task' }))).not.toContain('src/example.ts');
    const compare = review({ scope: 'branch', reference: 'main' });
    compare.snapshot = { ...compare.snapshot!, scope: 'branch', reference: 'old-main' };
    expect(panel(compare)).not.toContain('Stage file');
    expect(panel(compare)).toContain('Compare branch');
  });

  test('historical edits are explicitly read-only and stage scope offers unstage', () => {
    const history = review({ scope: 'lastTurn' });
    history.snapshot = { ...history.snapshot!, scope: 'lastTurn', canStage: false, canRevert: false };
    const historicalHTML = panel(history);
    expect(historicalHTML).toContain('Recorded edits from the last turn');
    expect(historicalHTML).not.toContain('Stage file'); expect(historicalHTML).not.toContain('Revert file');
    const staged = review({ scope: 'staged' });
    staged.snapshot = { ...staged.snapshot!, scope: 'staged', canStage: false, canRevert: false, canUnstage: true };
    expect(panel(staged)).toContain('Unstage file'); expect(panel(staged)).toContain('Unstage hunk');
  });
});
