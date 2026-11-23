import ArrowUp from '@octanejs/lucide/icons/arrow-up';
import ArrowDown from '@octanejs/lucide/icons/arrow-down';
import Check from '@octanejs/lucide/icons/check';
import ChevronLeft from '@octanejs/lucide/icons/chevron-left';
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
import SquarePen from '@octanejs/lucide/icons/square-pen';
import Play from '@octanejs/lucide/icons/play';
import RotateCw from '@octanejs/lucide/icons/rotate-cw';
import Search from '@octanejs/lucide/icons/search';
import Settings from '@octanejs/lucide/icons/settings';
import Sparkles from '@octanejs/lucide/icons/sparkles';
import Terminal from '@octanejs/lucide/icons/terminal';
import Trash2 from '@octanejs/lucide/icons/trash-2';
import X from '@octanejs/lucide/icons/x';

// Import only the icons we use, through the same native Octane port as shadcn.
const icons = {
  browser: Globe,
  check: Check,
  back: ChevronLeft,
  chevron: ChevronRight,
  reload: RotateCw,
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
  compose: SquarePen,
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
