import { useLayoutEffect, useMemo, useRef, useState } from 'octane';
import { Button } from '@octanejs/shadcn/Button';
import { Icon } from './Icon';
import { AgentStatusIcon } from './AgentStatusIcon';
import { sidebarRowHeight, useSidebarWindow } from './sidebarWindow';
import type { AppSnapshot, DesktopSection, NativeAction } from './types';

type Action = (action: NativeAction) => void;
type Row = { heading: string; label: string; expanded: boolean } | DesktopSection['chats'][number];

export function desktopRows(sections: DesktopSection[], search: string): Row[] {
  const term = search.trim().toLocaleLowerCase();
  return sections.flatMap(section => {
    const chats = section.chats.filter(chat => chat.title.toLocaleLowerCase().includes(term));
    if (term && !chats.length) return [];
    const expanded = Boolean(term) || !section.isCollapsed;
    return [{ heading: section.id, label: section.name, expanded }, ...(expanded ? chats : [])];
  });
}

export function DesktopChatList({snapshot, collapsed, search, post}: {
  snapshot: AppSnapshot; collapsed: boolean; search: string; post: Action;
}) {
  const list = useRef<HTMLElement | null>(null);
  const rows = useMemo(() => desktopRows(snapshot.desktopSections ?? [], search), [snapshot.desktopSections, search]);
  const [failure, setFailure] = useState('');
  const [copying, setCopying] = useState<string | null>(null);
  const request = snapshot.codexImportRequest;
  useLayoutEffect(() => { setFailure(''); setCopying(null); }, [request]);
  async function select(id: string) {
    if (!request) { post({action:'openDesktopChat', id}); return; }
    if (copying) return;
    setCopying(id); setFailure('');
    try {
      const bridge = window.webkit?.messageHandlers?.codexConversation;
      if (!bridge) throw new Error('The import service is unavailable.');
      await bridge.postMessage({action:'import',thread:id,selection:request});
    } catch (e) { setFailure(e instanceof Error ? e.message : String(e)); }
    finally { setCopying(null); }
  }
  const searching = Boolean(search.trim());
  const { start, end } = useSidebarWindow(list, rows.length);
  useLayoutEffect(() => { if (list.current) list.current.scrollTop = 0; }, [search]);
  return <nav ref={list} className={'task-list' + (collapsed ? ' agent-rail' : '')} aria-label="Codex desktop chats"
    style={{ '--sidebar-row-height': sidebarRowHeight + 'px' }}>
    <Button variant="ghost" title={request ? 'Back to imported chats' : 'Import from Codex'} onClick={() => post({action:request ? 'closeCodexImports' : 'browseCodexImports'})}>
      {collapsed ? <Icon name="terminal" size={15} /> : request ? 'Back to imported chats' : 'Import from Codex…'}
    </Button>
    {failure && <p className="sidebar-empty" role="alert">{failure}</p>}
    {snapshot.desktopSidebarError && <p className="sidebar-empty" role="status">{snapshot.desktopSidebarError}</p>}
    {!snapshot.desktopSidebarError && !rows.length && <p className="sidebar-empty">{search ? 'No matching chats' : request ? 'Looking for Codex chats…' : 'No imported chats yet'}</p>}
    {start > 0 && <div aria-hidden="true" style={{height: start * sidebarRowHeight + 'px'}} />}
    {rows.slice(start, end).map(row => 'heading' in row
      ? <h2 key={'section:' + row.heading} className="sidebar-section-heading" data-desktop-section={row.heading} title={row.label}>
          {searching ? <span className={collapsed ? 'sr-only' : undefined}>{row.label}</span> : (
            <button type="button" className="desktop-section-toggle" aria-expanded={row.expanded}
              onClick={() => post({ action: 'setDesktopSectionCollapsed', id: row.heading, collapsed: row.expanded })}
              onKeyDown={event => {
                if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
                if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
                event.preventDefault();
                const collapse = event.key === 'ArrowLeft';
                if (collapse === row.expanded) post({ action: 'setDesktopSectionCollapsed', id: row.heading, collapsed: collapse });
              }}>
              <Icon name="chevron" size={13} />
              <span className={collapsed ? 'sr-only' : undefined}>{row.label}</span>
            </button>
          )}
        </h2>
      : <div key={row.id} className="workspace-tab-row" data-desktop-chat={row.id}>
          <Button variant="ghost" className={'task-row' + (collapsed ? ' agent-rail-button' : '') + (snapshot.desktopReader?.id === row.id ? ' selected' : '')}
            aria-label={request ? 'Import ' + row.title : row.title} title={row.title} disabled={!!copying} aria-current={snapshot.desktopReader?.id === row.id ? 'page' : undefined}
            onClick={() => { void select(row.id); }}>
            <AgentStatusIcon taskID={row.id} working={false} />
            {!collapsed && <span className="task-row-title">{copying === row.id ? 'Importing…' : row.title}</span>}
          </Button></div>)}
    {end < rows.length && <div aria-hidden="true" style={{height:(rows.length-end)*sidebarRowHeight+'px'}} />}
  </nav>;
}

export function DesktopChatScope({selected, collapsed, choose}: {selected: boolean; collapsed: boolean; choose: (enabled:boolean)=>void}) {
  return <div className={'desktop-chat-scope' + (collapsed ? ' compact' : '')} role="group" aria-label="Chat source">
    {[false, true].map(desktop => <Button key={String(desktop)} variant="ghost" aria-pressed={selected === desktop}
      aria-label={desktop ? 'Imported chats' : 'Kolmogor agents'} title={desktop ? 'Imported chats' : 'Kolmogor agents'}
      onClick={() => choose(desktop)}>{collapsed ? <Icon name={desktop ? 'terminal' : 'computer'} size={15} /> : desktop ? 'Imports' : 'Agents'}</Button>)}
  </div>;
}
