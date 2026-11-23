import { describe, expect, test } from 'bun:test';
import {
  composerPrimaryAction,
  dropQueuedPrompt,
  isValidPrompt,
  moveQueuedPrompt,
  reorderQueuedPrompts,
  resolvePromptReceipt,
  shouldSubmitPromptKey,
} from '../src/promptQueue';

const key = (overrides: Partial<Parameters<typeof shouldSubmitPromptKey>[0]> = {}) => ({
  key: 'Enter',
  shiftKey: false,
  isComposing: false,
  keyCode: 13,
  repeat: false,
  ...overrides,
});

describe('prompt keyboard behavior', () => {
  test('Enter and Cmd+Enter submit while Shift+Enter stays a newline', () => {
    expect(shouldSubmitPromptKey(key())).toBe(true);
    expect(shouldSubmitPromptKey(key({ metaKey: true }))).toBe(true);
    expect(shouldSubmitPromptKey(key({ shiftKey: true }))).toBe(false);
  });

  test('IME composition, keyCode 229, and repeats never submit', () => {
    expect(shouldSubmitPromptKey(key({ isComposing: true }))).toBe(false);
    expect(shouldSubmitPromptKey(key({ keyCode: 229 }))).toBe(false);
    expect(shouldSubmitPromptKey(key({ repeat: true }))).toBe(false);
  });

  test('validates the native UTF-8 byte limit rather than only character count', () => {
    expect(isValidPrompt(' hello ')).toBe(true);
    expect(isValidPrompt('   ')).toBe(false);
    expect(isValidPrompt('a'.repeat(200_000))).toBe(true);
    expect(isValidPrompt('é'.repeat(100_001))).toBe(false);
  });
});

describe('composer primary action', () => {
  test('a running turn shows Stop until the user has a draft to queue', () => {
    expect(composerPrimaryAction(true, '', true)).toBe('stop');
    expect(composerPrimaryAction(true, 'Follow-up', true)).toBe('queue');
    // A nonempty draft shows the arrow even while the draft is invalid.
    expect(composerPrimaryAction(true, ' ', true)).toBe('queue');
  });

  test('an accepted follow-up restores Stop only if the draft clears and the turn is still running', () => {
    const pending = { requestID: 'request-1', draft: 'Follow-up' };
    const receipts = [{ id: 'request-1', accepted: true }];
    const accepted = resolvePromptReceipt(pending.draft, pending, receipts)!;
    expect(composerPrimaryAction(true, accepted.draft, true)).toBe('stop');
    expect(composerPrimaryAction(false, accepted.draft, false)).toBe('send');
    expect(composerPrimaryAction(false, accepted.draft, true)).toBe('queue');
    const edited = resolvePromptReceipt('Different draft', pending, receipts)!;
    expect(composerPrimaryAction(true, edited.draft, true)).toBe('queue');
  });
});

describe('prompt submission receipts', () => {
  const pending = { requestID: 'request-1', draft: 'Original draft' };

  test('clears only the exact accepted draft', () => {
    expect(resolvePromptReceipt('Original draft', pending, [{ id: 'request-1', accepted: true }]))
      .toEqual({ accepted: true, draft: '' });
    expect(resolvePromptReceipt('Original draft plus new text', pending, [{ id: 'request-1', accepted: true }]))
      .toEqual({ accepted: true, draft: 'Original draft plus new text' });
  });

  test('preserves rejected drafts and ignores unrelated receipts', () => {
    expect(resolvePromptReceipt('Original draft', pending, [{ id: 'request-1', accepted: false }]))
      .toEqual({ accepted: false, draft: 'Original draft', error: 'Message was not accepted. Try again.' });
    expect(resolvePromptReceipt('Original draft', pending, [{ id: 'other', accepted: true }])).toBeNull();
  });
});

describe('queued prompt ordering', () => {
  const items = [{ id: 'a' }, { id: 'b' }, { id: 'c' }];

  test('inserts before an item or at the end using the native contract', () => {
    expect(reorderQueuedPrompts(items, 'c', 'a').map(({ id }) => id)).toEqual(['c', 'a', 'b']);
    expect(reorderQueuedPrompts(items, 'a', null).map(({ id }) => id)).toEqual(['b', 'c', 'a']);
  });

  test('maps keyboard moves to stable before IDs', () => {
    expect(moveQueuedPrompt(items, 'b', -1)).toEqual({ items: [{ id: 'b' }, { id: 'a' }, { id: 'c' }], beforeID: 'a' });
    expect(moveQueuedPrompt(items, 'b', 1)).toEqual({ items: [{ id: 'a' }, { id: 'c' }, { id: 'b' }], beforeID: null });
    expect(moveQueuedPrompt(items, 'a', -1)).toBeNull();
  });

  test('maps pointer drops before and after a row', () => {
    expect(dropQueuedPrompt(items, 'a', 'b', true)?.items.map(({ id }) => id)).toEqual(['b', 'a', 'c']);
    expect(dropQueuedPrompt(items, 'c', 'a', false)?.items.map(({ id }) => id)).toEqual(['c', 'a', 'b']);
  });
});
