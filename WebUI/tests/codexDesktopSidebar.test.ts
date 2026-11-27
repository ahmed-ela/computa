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
    { heading: 'papers', label: 'Research Papers', expanded: true }, chat('c', 'Paper notes'),
  ]);
  expect(desktopRows(sections, 'no-match')).toEqual([]);
});

test('a collapsed section keeps its heading and hides only its chats', () => {
  const snapshot = sections.map(section => ({ ...section, isCollapsed: section.id === 'pins' }));
  expect(desktopRows(snapshot, '').map(row => 'heading' in row ? [row.heading, row.expanded] : row.id))
    .toEqual([['pins', false], ['papers', true], 'c', ['empty', true], ['recent', true], 'd']);
  expect(desktopRows(snapshot, ' second ')).toEqual([
    { heading: 'pins', label: 'Pinned', expanded: true }, chat('b', 'Second'),
  ]);
  expect(desktopRows(snapshot, '   ').some(row => 'id' in row && row.id === 'b')).toBe(false);
});
