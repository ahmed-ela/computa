import { isTaskActive, taskElapsedLabel, type SidebarTaskActivity } from './sidebarActivity';

export function TaskActivityIndicator({ task, now }: { task: SidebarTaskActivity; now: number }) {
  const active = isTaskActive(task);
  const unread = !active && task.status === 'Completed' && task.hasUnreadCompletion;
  const statusDot = !active && task.status !== 'Completed' && task.status !== 'Running';
  return <>
    {active ? <span className="task-row-elapsed" title={`${task.status} · ${taskElapsedLabel(task, now)}`} aria-hidden="true">{taskElapsedLabel(task, now)}</span> : null}
    {unread ? <span className="task-row-status task-row-unread" title="Completed, unread" aria-hidden="true" />
      : statusDot ? <span className={`task-row-status tone-${task.statusTone}`} title={task.status} aria-hidden="true" /> : null}
    <span className="sr-only">{unread ? 'Completed, unread' : task.status}</span>
  </>;
}
