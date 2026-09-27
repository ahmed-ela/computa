import { createElement as h, type OctaneNode } from 'octane';
import ChevronRight from '@octanejs/lucide/icons/chevron-right';
import { formatWorkedFor } from './duration';
import { activityDisclosureOpen, type ActivityGroup } from './activityTimeline';

export function activityLabel(group: ActivityGroup, now = Date.now() / 1000): string {
  let label = 'Worked';
  if (group.workedForSeconds != null) label = `Worked for ${formatWorkedFor(group.workedForSeconds)}`;
  else if (group.isRunning) label = group.startedAt != null ? `Working for ${formatWorkedFor(now - group.startedAt)}` : 'Working…';
  return label;
}

export function ActivityDisclosure({ group, time, manualOpen, onOpenChange, label, children }: {
  group: ActivityGroup;
  time: string;
  manualOpen?: boolean;
  onOpenChange: (open: boolean) => void;
  label?: OctaneNode;
  children?: OctaneNode;
}) {
  const open = activityDisclosureOpen(group.isRunning, group.hasFinalAnswer, manualOpen);
  return h('article', { className: 'message-row activity-message', children:
    h('details', {
      open,
      className: `reasoning-disclosure${group.isRunning && !group.hasFinalAnswer ? ' is-streaming' : ''}`,
      children: [
        h('summary', {
          // A native toggle also fires for programmatic open changes. Only
          // user activation should create the persistent manual override.
          onClick: (event: MouseEvent) => { event.preventDefault(); onOpenChange(!open); },
          children: [label ?? h('span', { className: 'reasoning-label', children: activityLabel(group) }),
            h(ChevronRight, { className: 'icon', size: 12, 'aria-hidden': 'true', focusable: 'false' }),
            h('span', { className: 'message-time', children: time })],
        }),
        h('div', { className: 'activity-body', role: 'region', 'aria-label': 'Activity', 'aria-live': 'off',
          children: group.entries.length ? children : h('span', { className: 'activity-placeholder', children: 'Preparing response…' }) }),
      ],
    }),
  });
}
