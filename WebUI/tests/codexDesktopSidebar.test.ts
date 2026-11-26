import 'octane/compiler/register';
import { expect, test } from 'bun:test';
import { desktopRows } from '../src/CodexDesktopSidebar';

const chat = (id: string, title: string) => ({ id, title, updatedAt: 0 });
const sections = [
  { id: 'pins', name: 'Pinned', chats: [chat('b', 'Second'), chat('a', 'First')] },
  { id: 'papers', name: 'Research Papers', chats: [chat('c', 'Paper notes')] },
  { id: 'empty', name: 'Empty group', chats: [] },
  { id: 'recent', name: 'Recent', chats: [chat('d', 'Planning')] },
];

test('the sidebar preserves source order, group names and empty groups', () => {
  expect(desktopRows(sections, '').map(row => 'heading' in row ? row.label : row.id))
    .toEqual(['Pinned', 'b', 'a', 'Research Papers', 'c', 'Empty group', 'Recent', 'd']);
});

test('filtering a Codex sidebar keeps matching chats inside their original group', () => {
  expect(desktopRows(sections, '  PAPER  ')).toEqual([
    { heading: 'papers', label: 'Research Papers' }, chat('c', 'Paper notes'),
  ]);
  expect(desktopRows(sections, 'no-match')).toEqual([]);
});
