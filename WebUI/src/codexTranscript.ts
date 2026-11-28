export interface CodexItem {
  type: string;
  id: string;
  [field: string]: unknown;
}
export interface CodexEntry {
  model?: string;
  modelLabel?: string;
  item: CodexItem;
  turnId: string;
  outputDeferred?: boolean;
}
export interface CodexPage {
  data: CodexEntry[];
  nextCursor: string | null;
  backwardsCursor: string | null;
}

export function entryKey(entry: CodexEntry): string {
  return JSON.stringify([entry.turnId, entry.item.id]);
}

export type HistoryDirection = 'asc' | 'desc';
type Chunk = { entries: CodexEntry[]; before: string | null; after: string | null };

// Codex supplies an exclusive cursor in both directions for every page.
// Keeping boundary cursors lets an arbitrarily long thread fit in a bounded window.
export class CodexHistoryWindow {
  private chunks: Chunk[] = [];
  constructor(private readonly maxPages = 6) {}
  get before() { return this.chunks[0]?.before ?? null; }
  get after() { return this.chunks.at(-1)?.after ?? null; }
  get pages() { return this.chunks.length; }
  get entries() { return this.chunks.flatMap(chunk => chunk.entries); }

  accept(page: CodexPage, direction: HistoryDirection, cursor?: string) {
    const backwards = direction === 'desc';
    if (cursor && cursor !== (backwards ? this.before : this.after)) return false;
    if (cursor && page.nextCursor === cursor) throw new Error('Codex returned a repeated history cursor.');
    if (!page.data.length && cursor) {
      if (backwards) this.chunks[0].before = null;
      else this.chunks[this.chunks.length - 1].after = null;
      return true;
    }
    const chunk = {
      entries: backwards ? page.data.slice().reverse() : page.data,
      before: backwards ? page.nextCursor : cursor ? page.backwardsCursor : null,
      after: backwards ? cursor ? page.backwardsCursor : null : page.nextCursor,
    };
    if (!cursor) this.chunks = [chunk];
    else if (backwards) this.chunks = [chunk, ...this.chunks].slice(0, this.maxPages);
    else this.chunks = [...this.chunks, chunk].slice(-this.maxPages);
    return true;
  }
}

const labels: Record<string, string> = {
  reasoning: 'Thinking', plan: 'Plan', commandExecution: 'Command', fileChange: 'File changes',
  functionCallOutput: 'Tool output', dynamicToolCall: 'Tool call', mcpToolCall: 'Tool call',
  collabAgentToolCall: 'Agent tool', subAgentActivity: 'Agent activity', webSearch: 'Web search',
  imageView: 'Image', imageGeneration: 'Generated image', sleep: 'Wait', hookPrompt: 'Hook',
  contextCompaction: 'Context compacted', enteredReviewMode: 'Review started', exitedReviewMode: 'Review finished',
};

export function activityLabel(item: CodexItem): string {
  const name = typeof item.tool === 'string' ? item.tool : typeof item.command === 'string' ? item.command : undefined;
  return [labels[item.type] ?? item.type, name].filter(Boolean).join(' · ');
}

export function activityText(item: CodexItem): string {
  if (item.type === 'reasoning') return Array.isArray(item.summary) ? item.summary.join('\n') : '';
  if (item.type === 'plan') return String(item.text ?? '');
  const { id, type, ...detail } = item;
  return Object.keys(detail).length ? JSON.stringify(detail, null, 2) : '';
}

export interface UserPart { type: string; text?: string; name?: string; path?: string; url?: string; fileId?: string }
