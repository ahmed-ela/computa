import type { AgentFileChange, FileReviewSnapshot, ReviewFile } from './types';

export interface ReviewPresentationState {
  identity?: string;
  viewed: Record<string, boolean>;
  files: Record<string, boolean>;
  hunks: Record<string, boolean>;
}

export function reviewPresentationIdentity(taskID: string, snapshot?: Pick<FileReviewSnapshot, 'workspace' | 'scope' | 'reference' | 'revision'>): string | undefined {
  return snapshot ? JSON.stringify([taskID, snapshot.workspace, snapshot.scope, snapshot.reference ?? '', snapshot.revision]) : undefined;
}

// Snapshot UUIDs are native mutation receipts. Presentation belongs to the
// actual content revision and survives a temporary absence while Git reloads.
export function reconcileReviewPresentation(state: ReviewPresentationState, identity?: string): ReviewPresentationState {
  return !identity || identity === state.identity ? state : { identity, viewed: {}, files: {}, hunks: {} };
}

export function fileChangeSummary(change: AgentFileChange): { label: string; additions: number; deletions: number; partial: boolean } {
  const label = change.movePath ? 'Renamed' : change.kind === 'add' ? 'Added' : change.kind === 'delete' ? 'Deleted' : 'Modified';
  // Native per-item add/delete payloads are literal file contents. Only updates
  // contain unified patches; a move without content changes can have no patch.
  if (change.kind === 'add' || change.kind === 'delete') {
    let lines = 0;
    for (let index = 0; index < change.diff.length; index++) if (change.diff[index] === '\n') lines++;
    if (change.diff.length > 0 && !change.diff.endsWith('\n')) lines++;
    return { label, additions: change.kind === 'add' ? lines : 0, deletions: change.kind === 'delete' ? lines : 0, partial: false };
  }
  const parsed = parseUnifiedDiff(change.diff);
  return { label, additions: parsed.additions, deletions: parsed.deletions, partial: parsed.limited || Boolean(parsed.warning) };
}

export interface DiffLine {
  kind: 'context' | 'addition' | 'deletion' | 'note';
  text: string;
  oldNumber?: number;
  newNumber?: number;
}

export interface DiffHunk {
  header: string;
  oldStart: number;
  newStart: number;
  lines: DiffLine[];
}

export interface ParsedDiff {
  hunks: DiffHunk[];
  metadata: string[];
  additions: number;
  deletions: number;
  warning?: string;
  limited: boolean;
}

// A bounded presentation parser. Native Git snapshots and native hunk IDs own
// mutation authority; displaying a plausible patch never grants that authority.
export function parseUnifiedDiff(diff: string, maximumLines = 5000): ParsedDiff {
  const result: ParsedDiff = { hunks: [], metadata: [], additions: 0, deletions: 0, limited: false };
  let current: DiffHunk | undefined;
  let oldRemaining = 0;
  let newRemaining = 0;
  let oldNumber = 0;
  let newNumber = 0;
  const warn = (message: string) => { result.warning ??= message; };
  const finish = () => {
    if (current && (oldRemaining !== 0 || newRemaining !== 0)) warn('This patch has incomplete hunk ranges. Refresh to review the complete changes.');
  };
  const lines = diff.split('\n');
  // A final newline is the patch terminator, not another context line.
  if (lines.at(-1) === '') lines.pop();
  for (let index = 0; index < lines.length; index++) {
    if (index >= maximumLines) {
      result.limited = true;
      warn('This diff is too large to display completely. Copy the diff or open the file to inspect the rest.');
      break;
    }
    const line = lines[index];
    const header = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?:.*)$/.exec(line);
    if (header) {
      finish();
      const values = [header[1], header[2] ?? '1', header[3], header[4] ?? '1'].map(Number);
      if (values.some((value) => !Number.isSafeInteger(value) || value < 0)) {
        warn('This patch contains an invalid line range.');
        current = undefined;
        continue;
      }
      [oldNumber, oldRemaining, newNumber, newRemaining] = values;
      current = { header: line, oldStart: oldNumber, newStart: newNumber, lines: [] };
      result.hunks.push(current);
      continue;
    }
    if (line === '\\ No newline at end of file' && current && current.lines.length > 0) {
      current.lines.push({ kind: 'note', text: 'No newline at end of file' });
      continue;
    }
    if (current && (oldRemaining > 0 || newRemaining > 0)) {
      if (line.startsWith(' ') && oldRemaining > 0 && newRemaining > 0) {
        current.lines.push({ kind: 'context', text: line.slice(1), oldNumber: oldNumber++, newNumber: newNumber++ });
        oldRemaining--; newRemaining--;
      } else if (line.startsWith('-') && oldRemaining > 0) {
        current.lines.push({ kind: 'deletion', text: line.slice(1), oldNumber: oldNumber++ });
        oldRemaining--; result.deletions++;
      } else if (line.startsWith('+') && newRemaining > 0) {
        current.lines.push({ kind: 'addition', text: line.slice(1), newNumber: newNumber++ });
        newRemaining--; result.additions++;
      } else {
        warn('This patch contains an invalid hunk. Refresh to review the complete changes.');
        current = undefined;
      }
      continue;
    }
    if (/^(diff --git |index |--- |\+\+\+ |old mode |new mode |new file mode |deleted file mode |similarity index |dissimilarity index |rename from |rename to |copy from |copy to |Binary files |GIT binary patch|literal |delta )/.test(line)) {
      result.metadata.push(line);
      continue;
    }
    if (line.startsWith('@@@')) warn('Combined merge diffs are available as raw patches only.');
    else if (line !== '') warn('This patch contains unsupported content. View its raw patch before making changes.');
    result.metadata.push(line);
  }
  if (!result.limited) finish();
  return result;
}

export interface SplitDiffLine {
  before?: DiffLine;
  after?: DiffLine;
  note?: string;
}

export function splitDiffLines(lines: DiffLine[]): SplitDiffLine[] {
  const rows: SplitDiffLine[] = [];
  let index = 0;
  while (index < lines.length) {
    const line = lines[index];
    if (line.kind === 'context') {
      rows.push({ before: line, after: line }); index++;
    } else if (line.kind === 'note') {
      rows.push({ note: line.text }); index++;
    } else {
      const before: DiffLine[] = [];
      const after: DiffLine[] = [];
      while (index < lines.length && (lines[index].kind === 'deletion' || lines[index].kind === 'addition')) {
        const change = lines[index++];
        (change.kind === 'deletion' ? before : after).push(change);
      }
      for (let offset = 0; offset < Math.max(before.length, after.length); offset++) {
        rows.push({ before: before[offset], after: after[offset] });
      }
    }
  }
  return rows;
}

export function reviewFeedback(path: string, line: number, side: 'old' | 'new', comment: string): string {
  return `Review ${path}:${line}${side === 'old' ? ' (previous version)' : ''}\n${comment.trim()}`;
}

export function reviewFileLabel(file: Pick<ReviewFile, 'path' | 'previousPath'>): string {
  return file.previousPath ? `${file.previousPath} → ${file.path}` : file.path;
}
