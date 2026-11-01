import { formatElapsedDuration } from './duration';
import type { TaskSnapshot } from './types';

export type SidebarTaskActivity = Pick<TaskSnapshot,
  'status' | 'statusTone' | 'isBusy' | 'activeTurnStartedAt' | 'updatedAt' | 'hasUnreadCompletion'>;

export function isTaskActive(task: SidebarTaskActivity): boolean {
  return task.status === 'Running' || task.isBusy;
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
