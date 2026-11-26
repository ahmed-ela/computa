import { flushSync } from 'octane';
import type { AppSnapshot } from './types';

function textOffset(root: Element, node: Node, offset: number): number {
  const range = document.createRange();
  range.selectNodeContents(root);
  range.setEnd(node, offset);
  return range.toString().length;
}

function textPoint(root: Element, offset: number): [Node, number] | undefined {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode() as Text | null; node; node = walker.nextNode() as Text | null) {
    if (offset <= node.length) return [node, offset];
    offset -= node.length;
  }
}

// Updating a Markdown text node can collapse WebKit's selection even when the update only appends words.
export function updateWithResponseSelection(current: AppSnapshot | null, next: AppSnapshot, update: () => void) {
  const selection = document.getSelection();
  const anchor = selection?.anchorNode;
  const focus = selection?.focusNode;
  const element = anchor instanceof Element ? anchor : anchor?.parentElement;
  const root = element?.closest('.assistant-copy');
  const entryID = root?.closest<HTMLElement>('.assistant-message')?.dataset.entryId;
  if (!selection || selection.isCollapsed || !anchor || !focus || !root?.contains(focus) || !entryID
      || !current || next.primaryBrowserID || current.selectedTaskID !== next.selectedTaskID) {
    update();
    return;
  }
  const body = (state: AppSnapshot) => state.tasks.find(task => task.id === state.selectedTaskID)?.entries.find(entry => entry.id === entryID)?.body;
  // A selection elsewhere in chat history should not force synchronous rendering on every streamed token.
  if (body(current) === body(next)) {
    update();
    return;
  }

  const anchorOffset = selection.anchorOffset;
  const focusOffset = selection.focusOffset;
  const anchorIndex = textOffset(root, anchor, anchorOffset);
  const focusIndex = textOffset(root, focus, focusOffset);
  const prefix = root.textContent.slice(0, Math.max(anchorIndex, focusIndex));
  const focused = document.activeElement;
  // Keep capture and repair in one event so a later click or keypress always wins.
  flushSync(update);
  if (selection.anchorNode === anchor && selection.anchorOffset === anchorOffset
      && selection.focusNode === focus && selection.focusOffset === focusOffset) return;
  if (!root.isConnected || root.closest('[hidden], [inert]') || document.activeElement !== focused
      || !root.textContent.startsWith(prefix)) return;

  const from = textPoint(root, anchorIndex);
  const to = textPoint(root, focusIndex);
  if (from && to) selection.setBaseAndExtent(...from, ...to);
}
