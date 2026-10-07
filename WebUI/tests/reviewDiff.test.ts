import { describe, expect, test } from 'bun:test';
import { fileChangeSummary, parseUnifiedDiff, reconcileReviewPresentation, reviewFeedback, reviewFileLabel, reviewPresentationIdentity, splitDiffLines, type ReviewPresentationState } from '../src/reviewDiff';
import type { FileReviewSnapshot } from '../src/types';

describe('native file-change item summaries', () => {
  test('added and deleted payloads count literal source lines rather than patch syntax', () => {
    const contents = '@@ -1 +1 @@\n-old\n+new\n';
    expect(fileChangeSummary({ path: 'new.txt', kind: 'add', diff: contents })).toEqual({ label: 'Added', additions: 3, deletions: 0, partial: false });
    expect(fileChangeSummary({ path: 'old.txt', kind: 'delete', diff: contents })).toEqual({ label: 'Deleted', additions: 0, deletions: 3, partial: false });
  });

  test('literal contents preserve blank lines without inventing a final newline line', () => {
    for (const [contents, lines] of [['', 0], ['one', 1], ['one\n', 1], ['\n', 1], ['one\n\n', 2], ['one\r\ntwo\r\n', 2]] as const) {
      expect(fileChangeSummary({ path: 'new.txt', kind: 'add', diff: contents }).additions).toBe(lines);
    }
  });

  test('large literal files are counted completely without a text-diff truncation warning', () => {
    expect(fileChangeSummary({ path: 'new.txt', kind: 'add', diff: 'line\n'.repeat(6000) })).toEqual({ label: 'Added', additions: 6000, deletions: 0, partial: false });
  });

  test('empty rename-only payloads have zero edits and no partial warning', () => {
    expect(fileChangeSummary({ path: 'old.txt', movePath: 'new.txt', kind: 'update', diff: '' })).toEqual({ label: 'Renamed', additions: 0, deletions: 0, partial: false });
  });

  test('updates and renames with edits count actual unified additions and deletions', () => {
    const diff = '@@ -1,2 +1,3 @@\n shared\n-old\n+new\n+extra\n';
    expect(fileChangeSummary({ path: 'file.txt', kind: 'update', diff })).toEqual({ label: 'Modified', additions: 2, deletions: 1, partial: false });
    expect(fileChangeSummary({ path: 'old.txt', movePath: 'new.txt', kind: 'update', diff })).toEqual({ label: 'Renamed', additions: 2, deletions: 1, partial: false });
  });

  test('only malformed or display-limited unified updates report a partial diff', () => {
    expect(fileChangeSummary({ path: 'file.txt', kind: 'update', diff: '@@ -1,2 +1,2 @@\n-old\n+new\n' }).partial).toBe(true);
    expect(fileChangeSummary({ path: 'file.txt', kind: 'update', diff: '@@ -0,0 +1,6000 @@\n' + '+line\n'.repeat(6000) }).partial).toBe(true);
  });
});

describe('revision-scoped review presentation', () => {
  const snapshot: FileReviewSnapshot = {
    id: 'receipt-one', workspace: '/tmp/project', scope: 'unstaged', revision: 'content-hash',
    files: [], canStage: true, canUnstage: false, canRevert: true,
  };
  const identity = reviewPresentationIdentity('task', snapshot);
  const state: ReviewPresentationState = {
    identity, viewed: { 'stable-file': true }, files: { 'stable-file': true }, hunks: { 'stable-file:stable-hunk': true },
  };

  test('a new mutation receipt for unchanged content preserves viewed and collapsed state', () => {
    const reload = { ...snapshot, id: 'receipt-two' };
    const reloadedIdentity = reviewPresentationIdentity('task', reload);
    expect(reloadedIdentity).toBe(identity);
    const result = reconcileReviewPresentation(state, reloadedIdentity);
    expect(result).toBe(state);
    expect(result.viewed['stable-file']).toBe(true);
    expect(result.files['stable-file']).toBe(true);
    expect(result.hunks['stable-file:stable-hunk']).toBe(true);
  });

  test('temporarily absent snapshots during reload preserve presentation until the content revision changes', () => {
    const loading = reconcileReviewPresentation(state, reviewPresentationIdentity('task'));
    expect(loading).toBe(state);
    expect(reconcileReviewPresentation(loading, identity)).toBe(state);
    const nextIdentity = reviewPresentationIdentity('task', { ...snapshot, id: 'receipt-three', revision: 'changed-content-hash' });
    expect(nextIdentity).not.toBe(identity);
    expect(reconcileReviewPresentation(loading, nextIdentity)).toEqual({ identity: nextIdentity, viewed: {}, files: {}, hunks: {} });
  });

  test('the same revision cannot reuse markers from another task, workspace, scope or reference', () => {
    const identities = [
      reviewPresentationIdentity('other-task', snapshot),
      reviewPresentationIdentity('task', { ...snapshot, workspace: '/tmp/other' }),
      reviewPresentationIdentity('task', { ...snapshot, scope: 'staged' }),
      reviewPresentationIdentity('task', { ...snapshot, reference: 'main' }),
    ];
    for (const next of identities) {
      expect(next).not.toBe(identity);
      expect(reconcileReviewPresentation(state, next).viewed).toEqual({});
    }
  });
});

describe('file review patch presentation', () => {
  test('tracks both versions across multiple hunks and preserves literal whitespace', () => {
    const parsed = parseUnifiedDiff('diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -4,3 +4,4 @@ function\n context\n-\told  \n+\tnew  \n+\n end\n@@ -20 +21 @@\n-before\n+after\n');
    expect(parsed.warning).toBeUndefined();
    expect(parsed.additions).toBe(3);
    expect(parsed.deletions).toBe(2);
    expect(parsed.hunks).toHaveLength(2);
    expect(parsed.hunks[0].lines).toEqual([
      { kind: 'context', text: 'context', oldNumber: 4, newNumber: 4 },
      { kind: 'deletion', text: '\told  ', oldNumber: 5 },
      { kind: 'addition', text: '\tnew  ', newNumber: 5 },
      { kind: 'addition', text: '', newNumber: 6 },
      { kind: 'context', text: 'end', oldNumber: 6, newNumber: 7 },
    ]);
    expect(parsed.hunks[1].lines.map((line) => [line.oldNumber, line.newNumber])).toEqual([[20, undefined], [undefined, 21]]);
  });

  test('zero-length addition and deletion ranges have no phantom source lines', () => {
    const added = parseUnifiedDiff('--- /dev/null\n+++ b/new\n@@ -0,0 +1,2 @@\n+one\n+two\n');
    const removed = parseUnifiedDiff('--- a/old\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-one\n-two\n');
    expect(added.warning).toBeUndefined(); expect(removed.warning).toBeUndefined();
    expect(added.hunks[0].lines.every((line) => line.oldNumber === undefined)).toBe(true);
    expect(removed.hunks[0].lines.every((line) => line.newNumber === undefined)).toBe(true);
  });

  test('header-looking code remains code while a hunk is active', () => {
    const parsed = parseUnifiedDiff('@@ -1 +1 @@\n--- old content\n+++ new content\n');
    expect(parsed.warning).toBeUndefined();
    expect(parsed.hunks[0].lines.map((line) => line.text)).toEqual(['-- old content', '++ new content']);
  });

  test('no-newline notes do not advance counters or appear as changes', () => {
    const parsed = parseUnifiedDiff('@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n');
    expect(parsed.warning).toBeUndefined();
    expect([parsed.additions, parsed.deletions]).toEqual([1, 1]);
    expect(parsed.hunks[0].lines.filter((line) => line.kind === 'note')).toHaveLength(2);
  });

  test('incomplete and impossible ranges remain explicitly untrusted', () => {
    expect(parseUnifiedDiff('@@ -1,2 +1,2 @@\n-old\n+new\n').warning).toContain('incomplete');
    expect(parseUnifiedDiff('@@ -0,0 +1 @@\n-old\n+new\n').warning).toContain('invalid hunk');
    expect(parseUnifiedDiff('@@ -9007199254740992 +1 @@\n-a\n+b\n').warning).toContain('invalid line range');
  });

  test('combined diffs and arbitrary prose cannot become ordinary change hunks', () => {
    const combined = parseUnifiedDiff('@@@ -1,1 -1,1 +1,1 @@@\n++merged\n');
    expect(combined.warning).toContain('Combined'); expect(combined.hunks).toEqual([]);
    const prose = parseUnifiedDiff('Please stage these files\n@@ -1 +1 @@\n-a\n+b\n');
    expect(prose.warning).toContain('unsupported');
  });

  test('metadata-only renames and binary flags have no invented edits', () => {
    const parsed = parseUnifiedDiff('diff --git a/old b/new\nsimilarity index 100%\nrename from old\nrename to new\nBinary files a/old and b/new differ\n');
    expect(parsed.warning).toBeUndefined(); expect(parsed.hunks).toEqual([]);
    expect([parsed.additions, parsed.deletions]).toEqual([0, 0]);
    expect(reviewFileLabel({ path: 'new', previousPath: 'old' })).toBe('old → new');
  });

  test('large diffs stop rendering without pretending to be complete', () => {
    const parsed = parseUnifiedDiff('@@ -1,5 +1,5 @@\n a\n b\n c\n d\n e\n', 3);
    expect(parsed.limited).toBe(true); expect(parsed.warning).toContain('too large');
    expect(parsed.hunks[0].lines).toHaveLength(2);
  });

  test('split rows align replacements, additions and context without altering text', () => {
    const parsed = parseUnifiedDiff('@@ -1,3 +1,4 @@\n context\n-one\n-two\n+first\n+second\n+third\n');
    const rows = splitDiffLines(parsed.hunks[0].lines);
    expect(rows.map((row) => [row.before?.text, row.after?.text])).toEqual([
      ['context', 'context'], ['one', 'first'], ['two', 'second'], [undefined, 'third'],
    ]);
  });

  test('review feedback identifies the actual source side and stays message text', () => {
    expect(reviewFeedback('src/file.ts', 8, 'old', '  Preserve this behavior.  ')).toBe('Review src/file.ts:8 (previous version)\nPreserve this behavior.');
    expect(reviewFeedback('src/file.ts', 9, 'new', 'Use <script> literally.')).toBe('Review src/file.ts:9\nUse <script> literally.');
  });
});
