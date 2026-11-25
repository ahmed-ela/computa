import { taskElapsedLabel, type SidebarAgentStatus, type SidebarTaskActivity } from './sidebarActivity';

export function TaskActivityIndicator({ task, status, compact, now }: {
  task: SidebarTaskActivity; status: SidebarAgentStatus; compact: boolean; now: number;
}) {
  const elapsed = status === 'working' && !compact ? taskElapsedLabel(task, now) : undefined;
  const unread = status === 'ready';
  return <>
    {elapsed && <span className="task-row-elapsed" title={`${task.status} · ${elapsed}`} aria-hidden="true">{elapsed}</span>}
    {unread && <span className="task-row-unread" title="Completed, unread" aria-hidden="true" />}
    <span className="sr-only">{unread ? 'Completed, unread' : task.status}</span>
  </>;
}
