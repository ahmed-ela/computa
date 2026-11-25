import { formatElapsedDuration } from './duration';
import { unreadCompletionID } from './completionAcknowledgment';
import type { TaskSnapshot } from './types';

export type SidebarTaskActivity = Pick<TaskSnapshot,
  'status' | 'isBusy' | 'activeTurnStartedAt' | 'updatedAt' | 'hasUnreadCompletion' | 'unreadCompletionID'>;

export type SidebarAgentStatus = 'working' | 'ready' | undefined;

export function isTaskActive(task: SidebarTaskActivity): boolean {
  return task.status === 'Running' || task.isBusy;
}

export function sidebarAgentStatus(task: SidebarTaskActivity, viewing: boolean): SidebarAgentStatus {
  if (isTaskActive(task)) return 'working';
  if (!viewing && unreadCompletionID(task)) return 'ready';
}

export function taskElapsedLabel(task: SidebarTaskActivity, now: number): string {
  const validTime = (value: number | undefined): value is number =>
    value !== undefined && Number.isFinite(value) && value >= 0;
  const start = validTime(task.activeTurnStartedAt) ? task.activeTurnStartedAt
    : validTime(task.updatedAt) ? task.updatedAt : now;
  return formatElapsedDuration(now - start);
}

export interface SidebarClock {
  now: () => number;
  everySecond: (tick: () => void) => () => void;
}

// One subscription belongs to the sidebar, never to an individual task row.
export function startSidebarClock(update: (now: number) => void, clock: SidebarClock): () => void {
  const tick = () => update(clock.now());
  tick();
  return clock.everySecond(tick);
}
