import { useLayoutEffect, useState } from 'octane';

export const sidebarRowHeight = 28;
const overscan = 8;

// Keep short lists mounted. For long lists the spacers preserve the native scrollbar
// and each row's position, including rows far beyond the mounted window.
export function useSidebarWindow(list: { current: HTMLElement | null }, count: number) {
  const windowed = count > 80;
  const [viewport, setViewport] = useState({ first: 0, rows: 24 });
  useLayoutEffect(() => {
    const node = list.current;
    if (!node || !windowed) return;
    const measure = () => {
      const first = Math.floor(Math.max(0, node.scrollTop) / sidebarRowHeight);
      const rows = Math.ceil(node.clientHeight / sidebarRowHeight) + 1;
      setViewport(old => old.first === first && old.rows === rows ? old : { first, rows });
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(node);
    node.addEventListener('scroll', measure, { passive: true });
    return () => {
      node.removeEventListener('scroll', measure);
      observer.disconnect();
    };
  }, [windowed]);
  const first = Math.min(viewport.first, Math.max(0, count - viewport.rows));
  return windowed
    ? { start: Math.max(0, first - overscan), end: Math.min(count, first + viewport.rows + overscan) }
    : { start: 0, end: count };
}
