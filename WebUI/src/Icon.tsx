import ArrowUp from '@octanejs/lucide/icons/arrow-up';
import ArrowDown from '@octanejs/lucide/icons/arrow-down';
import Check from '@octanejs/lucide/icons/check';
import ChevronRight from '@octanejs/lucide/icons/chevron-right';
import CircleAlert from '@octanejs/lucide/icons/circle-alert';
import CornerUpLeft from '@octanejs/lucide/icons/corner-up-left';
import Ellipsis from '@octanejs/lucide/icons/ellipsis';
import GripVertical from '@octanejs/lucide/icons/grip-vertical';
import Monitor from '@octanejs/lucide/icons/monitor';
import PanelRight from '@octanejs/lucide/icons/panel-right';
import Pencil from '@octanejs/lucide/icons/pencil';
import Play from '@octanejs/lucide/icons/play';
import Plus from '@octanejs/lucide/icons/plus';
import Search from '@octanejs/lucide/icons/search';
import Settings from '@octanejs/lucide/icons/settings';
import Sparkles from '@octanejs/lucide/icons/sparkles';
import Square from '@octanejs/lucide/icons/square';
import SquarePen from '@octanejs/lucide/icons/square-pen';
import Terminal from '@octanejs/lucide/icons/terminal';
import Trash2 from '@octanejs/lucide/icons/trash-2';
import X from '@octanejs/lucide/icons/x';

// Import only the icons we use, through the same native Octane port as shadcn.
const icons = {
  check: Check,
  chevron: ChevronRight,
  computer: Monitor,
  delete: Trash2,
  down: ArrowDown,
  drag: GripVertical,
  edit: Pencil,
  gear: Settings,
  info: CircleAlert,
  inspect: PanelRight,
  more: Ellipsis,
  new: SquarePen,
  plus: Plus,
  resume: Play,
  search: Search,
  send: ArrowUp,
  sparkles: Sparkles,
  steer: CornerUpLeft,
  stop: Square,
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
