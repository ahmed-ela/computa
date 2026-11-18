import type { EntrySnapshot, TaskSnapshot } from './types';

// Keep the original diagnostic in the entry for the inspector and persisted history.
export function systemMessageText(entry: EntrySnapshot): string {
  if (entry.kind !== 'system' || entry.title !== 'Agent error') return entry.body;
  try {
    const diagnostic = JSON.parse(entry.body)?.error;
    if (typeof diagnostic?.message === 'string' && diagnostic.message.trim()) return diagnostic.message;
  } catch {
    // Older turns and native errors already contain plain text.
  }
  return entry.body;
}

export function hasReasoningText(entry: EntrySnapshot): boolean {
  const text = entry.body.trim();
  return entry.kind === 'reasoning' && text.length > 0 && text !== 'Reasoning completed.';
}

export function activityDisclosureOpen(isRunning: boolean, hasFinalAnswer: boolean, manualOpen?: boolean): boolean {
  return manualOpen ?? (isRunning && !hasFinalAnswer);
}

export interface ActivityGroup {
  id: string;
  entries: EntrySnapshot[];
  timestamp: number;
  isRunning: boolean;
  hasFinalAnswer: boolean;
  startedAt?: number;
  workedForSeconds?: number;
  timedAnswerID?: string;
}

export type ConversationEntry = EntrySnapshot & { kind: 'user' | 'assistant' | 'system' };

// A tool receipt belongs to its turn for its entire lifetime. Approval prompts
// are presented by the native approval queue, independently of this transcript.
function isConversationEntry(entry: EntrySnapshot): entry is ConversationEntry {
  switch (entry.kind) {
    case 'user': case 'assistant': case 'system': return true;
    case 'reasoning': case 'tool': return false;
  }
}

export type ActivityRow =
  | { kind: 'activity'; group: ActivityGroup }
  | { kind: 'entry'; entry: ConversationEntry; hideAnswerMetadata: boolean };

function validDuration(seconds?: number): seconds is number {
  return seconds != null && Number.isFinite(seconds) && seconds >= 0;
}

export function activityTimeline(task: TaskSnapshot): ActivityRow[] {
  const busy = task.status === 'Running' || task.activeTurnStartedAt != null;
  const lastUser = [...task.entries].reverse().find((entry) => entry.kind === 'user');
  const activeID = busy ? task.activeActivityGroupID ?? lastUser?.activityGroupID ?? lastUser?.id : undefined;
  const owners = new Map<string, string>();
  const groups = new Map<string, ActivityGroup>();
  let legacyOwner = `legacy:${task.id}`;
  const ensure = (id: string, timestamp: number) => {
    let group = groups.get(id);
    if (!group) {
      group = { id, entries: [], timestamp, isRunning: id === activeID,
        hasFinalAnswer: false, startedAt: id === activeID ? task.activeTurnStartedAt : undefined };
      groups.set(id, group);
    }
    return group;
  };

  for (const entry of task.entries) {
    // Exact native ownership keeps steering in the same logical turn. Legacy
    // rows use conservative user boundaries; never infer ownership from time.
    if (entry.kind === 'user') legacyOwner = entry.activityGroupID ?? entry.id;
    const owner = entry.activityGroupID ?? legacyOwner;
    owners.set(entry.id, owner);
    if (entry.kind === 'user' && owner === activeID) ensure(owner, entry.timestamp);
    if (hasReasoningText(entry) || entry.kind === 'tool') ensure(owner, entry.timestamp).entries.push(entry);
  }

  for (const entry of task.entries) {
    if (entry.kind !== 'assistant' || !entry.body.trim()) continue;
    const group = groups.get(owners.get(entry.id)!);
    if (!group) continue;
    // Unknown/null phase and commentary are never evidence of a final answer.
    if (entry.assistantPhase === 'final_answer') group.hasFinalAnswer = true;
    // Native timing is authoritative only after this logical turn has ended.
    // It supplies the completion fallback when the provider omits phases.
    if (!group.isRunning && !entry.isStreaming && validDuration(entry.workedForSeconds)) {
      group.workedForSeconds = entry.workedForSeconds;
      group.timedAnswerID = entry.id;
      group.hasFinalAnswer = true;
      group.timestamp = entry.timestamp;
    }
  }

  const rows: ActivityRow[] = [];
  const inserted = new Set<string>();
  const insertGroup = (id: string) => {
    const group = groups.get(id);
    if (!group || inserted.has(id)) return;
    if (group.entries.length === 0 && !group.isRunning) return;
    rows.push({ kind: 'activity', group });
    inserted.add(id);
  };
  for (const entry of task.entries) {
    const owner = owners.get(entry.id)!;
    if (!isConversationEntry(entry)) {
      if (groups.get(owner)?.entries[0]?.id === entry.id) insertGroup(owner);
      continue;
    }
    if (entry.kind === 'assistant' && !entry.body.trim()) continue;
    rows.push({ kind: 'entry', entry, hideAnswerMetadata: groups.get(owner)?.timedAnswerID === entry.id });
    if (entry.kind === 'user') insertGroup(owner);
  }
  return rows;
}
