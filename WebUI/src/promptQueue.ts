export interface PromptKeyEvent {
  key: string;
  shiftKey: boolean;
  isComposing: boolean;
  keyCode: number;
  repeat: boolean;
  metaKey?: boolean;
  ctrlKey?: boolean;
}

export interface QueueItemIdentity {
  id: string;
}

export interface PendingPromptSubmission {
  requestID: string;
  draft: string;
}

export interface PromptReceiptIdentity {
  id: string;
  accepted: boolean;
}

export const maxPromptBytes = 200_000;

export function isValidPrompt(value: string): boolean {
  const prompt = value.trim();
  return prompt.length > 0 && new TextEncoder().encode(prompt).length <= maxPromptBytes;
}

export function resolvePromptReceipt(
  currentDraft: string,
  pending: PendingPromptSubmission,
  receipts: readonly PromptReceiptIdentity[],
): { accepted: boolean; draft: string; error?: string } | null {
  const receipt = receipts.find((candidate) => candidate.id === pending.requestID);
  if (!receipt) return null;
  if (!receipt.accepted) {
    return { accepted: false, draft: currentDraft, error: 'Message was not accepted. Try again.' };
  }
  return {
    accepted: true,
    draft: currentDraft === pending.draft ? '' : currentDraft,
  };
}

/** Plain Enter and Cmd/Ctrl+Enter submit. Shift+Enter remains a newline. */
export function shouldSubmitPromptKey(event: PromptKeyEvent): boolean {
  return event.key === 'Enter'
    && !event.shiftKey
    && !event.isComposing
    && event.keyCode !== 229
    && !event.repeat;
}

/** Apply the native queue contract: null appends, otherwise insert before the ID. */
export function reorderQueuedPrompts<T extends QueueItemIdentity>(
  items: readonly T[],
  id: string,
  beforeID: string | null,
): T[] {
  const moving = items.find((item) => item.id === id);
  if (!moving || beforeID === id) return [...items];

  const remaining = items.filter((item) => item.id !== id);
  if (beforeID === null) return [...remaining, moving];
  const insertionIndex = remaining.findIndex((item) => item.id === beforeID);
  if (insertionIndex < 0) return [...items];
  return [
    ...remaining.slice(0, insertionIndex),
    moving,
    ...remaining.slice(insertionIndex),
  ];
}

export interface QueueMove<T extends QueueItemIdentity> {
  items: T[];
  beforeID: string | null;
}

/** Resolve an accessible one-step move into the native beforeID representation. */
export function moveQueuedPrompt<T extends QueueItemIdentity>(
  items: readonly T[],
  id: string,
  direction: -1 | 1,
): QueueMove<T> | null {
  const index = items.findIndex((item) => item.id === id);
  const destination = index + direction;
  if (index < 0 || destination < 0 || destination >= items.length) return null;

  const reordered = [...items];
  const [moving] = reordered.splice(index, 1);
  reordered.splice(destination, 0, moving);
  return {
    items: reordered,
    beforeID: reordered[destination + 1]?.id ?? null,
  };
}

/** Convert a pointer drop before/after a row into the same native beforeID contract. */
export function dropQueuedPrompt<T extends QueueItemIdentity>(
  items: readonly T[],
  id: string,
  targetID: string,
  afterTarget: boolean,
): QueueMove<T> | null {
  if (id === targetID || !items.some((item) => item.id === id)) return null;
  const remaining = items.filter((item) => item.id !== id);
  const targetIndex = remaining.findIndex((item) => item.id === targetID);
  if (targetIndex < 0) return null;
  const beforeID = afterTarget ? remaining[targetIndex + 1]?.id ?? null : targetID;
  return { items: reorderQueuedPrompts(items, id, beforeID), beforeID };
}
