import { expect, test } from 'bun:test';
import { CodexHistoryWindow, activityText, entryKey, type CodexEntry, type HistoryDirection } from '../src/codexTranscript';
const row = (i: number): CodexEntry => ({turnId:'turn', item:{type:'userMessage',id:String(i)}});
const history = Array.from({length:110}, (_, i) => row(i));
function page(direction: HistoryDirection, cursor?: string) {
  const ascending = direction === 'asc';
  const boundary = cursor === undefined ? ascending ? 0 : history.length : Number(cursor);
  const start = ascending ? boundary : Math.max(0,boundary-9);
  const end = ascending ? Math.min(history.length,boundary+9) : boundary;
  const entries = history.slice(start,end);
  return {data:ascending ? entries : entries.reverse(),
    nextCursor:ascending ? end < history.length ? String(end) : null : start > 0 ? String(start) : null,
    backwardsCursor:String(ascending ? start : end)};
}
test('scrolls from the last message to the first and back, retaining at most three pages', () => {
  const view = new CodexHistoryWindow(3);
  view.accept(page('desc'),'desc');
  const seen = new Set<string>();
  while (true) {
    view.entries.forEach(row => seen.add(entryKey(row)));
    expect(view.entries.length).toBeLessThanOrEqual(27);
    if (!view.before) break;
    view.accept(page('desc', view.before),'desc',view.before);
  }
  expect(seen.size).toBe(110);
  expect(view.entries[0]).toEqual(row(0));
  while (view.after) view.accept(page('asc',view.after),'asc',view.after);
  expect(view.entries.at(-1)).toEqual(row(109));
  expect(view.entries).toEqual(history.slice(-view.entries.length));
});
test('can open the beginning directly and discard a page from a stale cursor', () => {
  const view = new CodexHistoryWindow();
  view.accept(page('asc'),'asc');
  expect(view.before).toBeNull();
  expect(view.entries[0]).toEqual(row(0));
  expect(view.accept(page('desc'),'desc','stale')).toBe(false);
});
test('a repeated continuation cursor is rejected', () => {
  const view = new CodexHistoryWindow();
  view.accept(page('desc'),'desc');
  const cursor = view.before!;
  expect(() => view.accept({...page('desc',cursor),nextCursor:cursor},'desc',cursor)).toThrow('repeated');
});
test('thinking displays only the published summary', () => {
  expect(activityText({id:'r',type:'reasoning',summary:['Reviewed changes'],content:['private']})).toBe('Reviewed changes');
});
