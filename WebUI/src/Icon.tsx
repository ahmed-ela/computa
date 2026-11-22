import Bot from '@octanejs/lucide/icons/bot';
import History from '@octanejs/lucide/icons/history';
import ArrowUp from '@octanejs/lucide/icons/arrow-up';
import ArrowDown from '@octanejs/lucide/icons/arrow-down';
import Check from '@octanejs/lucide/icons/check';
import ChevronRight from '@octanejs/lucide/icons/chevron-right';
import Copy from '@octanejs/lucide/icons/copy';
import CircleAlert from '@octanejs/lucide/icons/circle-alert';
import CornerUpLeft from '@octanejs/lucide/icons/corner-up-left';
import Ellipsis from '@octanejs/lucide/icons/ellipsis';
import Globe from '@octanejs/lucide/icons/globe';
import GripVertical from '@octanejs/lucide/icons/grip-vertical';
import Monitor from '@octanejs/lucide/icons/monitor';
import PanelLeft from '@octanejs/lucide/icons/panel-left';
import PanelRight from '@octanejs/lucide/icons/panel-right';
import Pause from '@octanejs/lucide/icons/pause';
import Pencil from '@octanejs/lucide/icons/pencil';
import Play from '@octanejs/lucide/icons/play';
import Search from '@octanejs/lucide/icons/search';
import Settings from '@octanejs/lucide/icons/settings';
import Sparkles from '@octanejs/lucide/icons/sparkles';
import Terminal from '@octanejs/lucide/icons/terminal';
import Trash2 from '@octanejs/lucide/icons/trash-2';
import X from '@octanejs/lucide/icons/x';

// Import only the icons we use, through the same native Octane port as shadcn.
const icons = {
  agent: Bot,
  history: History,
  browser: Globe,
  check: Check,
  chevron: ChevronRight,
  computer: Monitor,
  copy: Copy,
  delete: Trash2,
  down: ArrowDown,
  drag: GripVertical,
  edit: Pencil,
  gear: Settings,
  info: CircleAlert,
  inspect: PanelRight,
  more: Ellipsis,
  pause: Pause,
  resume: Play,
  search: Search,
  send: ArrowUp,
  sidebar: PanelLeft,
  sparkles: Sparkles,
  steer: CornerUpLeft,
  terminal: Terminal,
  x: X,
} as const;

export function Icon({ name, size = 18 }: { name: keyof typeof icons; size?: number }) {
  const LucideIcon = icons[name];
  // The enclosing control/text supplies the accessible name. Icons are decorative.
  return (
    <LucideIcon
      className="icon"
      size={size}
      style={{ width: `${size}px`, height: `${size}px` }}
      strokeWidth={2}
      aria-hidden="true"
      focusable="false"
    />
  );
}

// Fluent UI System Icons, Bot Add 16 Filled (MIT).
export function BotAdd16Filled() {
  return (
    <svg className="icon" width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true" focusable="false">
      <path d="M7 1C7.27614 1 7.5 1.22386 7.5 1.5V2H9.5C10.3284 2 11 2.67157 11 3.5V6.02242C9.4959 6.15796 8.1664 6.89904 7.25716 8H4.5C3.67157 8 3 7.32843 3 6.5V3.5C3 2.67157 3.67157 2 4.5 2H6.5V1.5C6.5 1.22386 6.72386 1 7 1Z
        M6 11.5C6 10.7944 6.13286 10.1199 6.37494 9.5H3.5C2.67157 9.5 2 10.1716 2 11V11.35C2 12.6549 2.59906 13.5997 3.55404 14.1934C4.47904 14.7684 5.70968 15 7 15C7.0852 15 7.17011 14.999 7.25467 14.997C6.47082 14.0465 6 12.8282 6 11.5Z
        M5.5 5.75C5.91421 5.75 6.25 5.41421 6.25 5C6.25 4.58579 5.91421 4.25 5.5 4.25C5.08579 4.25 4.75 4.58579 4.75 5C4.75 5.41421 5.08579 5.75 5.5 5.75Z
        M9.25 5C9.25 4.58579 8.91421 4.25 8.5 4.25C8.08579 4.25 7.75 4.58579 7.75 5C7.75 5.41421 8.08579 5.75 8.5 5.75C8.91421 5.75 9.25 5.41421 9.25 5Z
        M16 11.5C16 13.9853 13.9853 16 11.5 16C9.01472 16 7 13.9853 7 11.5C7 9.01472 9.01472 7 11.5 7C13.9853 7 16 9.01472 16 11.5Z
        M12 9.5C12 9.22386 11.7761 9 11.5 9C11.2239 9 11 9.22386 11 9.5V11H9.5C9.22386 11 9 11.2239 9 11.5C9 11.7761 9.22386 12 9.5 12H11V13.5C11 13.7761 11.2239 14 11.5 14C11.7761 14 12 13.7761 12 13.5V12H13.5C13.7761 12 14 11.7761 14 11.5C14 11.2239 13.7761 11 13.5 11H12V9.5Z" />
    </svg>
  );
}
