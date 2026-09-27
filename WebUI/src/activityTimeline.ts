import type { EntrySnapshot, TaskSnapshot } from './types';

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

export type ActivityRow =
  | { kind: 'activity'; group: ActivityGroup }
  | { kind: 'entry'; entry: EntrySnapshot; hideAnswerMetadata: boolean };

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
    if (entry.kind === 'reasoning') {
      if (hasReasoningText(entry)) insertGroup(owner);
      continue;
    }
    if (entry.kind === 'tool') {
      insertGroup(owner);
      // Safety-relevant steps stay visible even when the activity is closed.
      if (entry.tool?.status !== 'Failed' && entry.tool?.status !== 'Needs approval') continue;
    }
    if (entry.kind === 'assistant' && !entry.body.trim()) continue;
    rows.push({ kind: 'entry', entry, hideAnswerMetadata: groups.get(owner)?.timedAnswerID === entry.id });
    if (entry.kind === 'user') insertGroup(owner);
  }
  return rows;
}
