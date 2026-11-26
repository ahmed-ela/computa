import { useLayoutEffect, useMemo, useRef } from 'octane';
import { Button } from '@octanejs/shadcn/Button';
import { Icon } from './Icon';
import { AgentStatusIcon } from './AgentStatusIcon';
import { ResponseMarkdown } from './ResponseMarkdown';
import { sidebarRowHeight, useSidebarWindow } from './sidebarWindow';
import type { AppSnapshot, DesktopSection, NativeAction } from './types';

type Action = (action: NativeAction) => void;
type Row = { heading: string; label: string } | DesktopSection['chats'][number];

export function desktopRows(sections: DesktopSection[], search: string): Row[] {
  const term = search.trim().toLocaleLowerCase();
  return sections.flatMap(section => {
    const chats = section.chats.filter(chat => chat.title.toLocaleLowerCase().includes(term));
    if (term && !chats.length) return [];
    return [{ heading: section.id, label: section.name }, ...chats];
  });
}

export function DesktopChatList({snapshot, collapsed, search, post}: {
  snapshot: AppSnapshot; collapsed: boolean; search: string; post: Action;
}) {
  const list = useRef<HTMLElement | null>(null);
  const rows = useMemo(() => desktopRows(snapshot.desktopSections ?? [], search), [snapshot.desktopSections, search]);
  const { start, end } = useSidebarWindow(list, rows.length);
  useLayoutEffect(() => { if (list.current) list.current.scrollTop = 0; }, [search]);
  return <nav ref={list} className={'task-list' + (collapsed ? ' agent-rail' : '')} aria-label="Codex desktop chats"
    style={{ '--sidebar-row-height': sidebarRowHeight + 'px' }}>
    {snapshot.desktopSidebarError && <p className="sidebar-empty" role="status">{snapshot.desktopSidebarError}</p>}
    {!snapshot.desktopSidebarError && !rows.length && <p className="sidebar-empty">{search ? 'No matching chats' : 'Loading Codex chats…'}</p>}
    {start > 0 && <div aria-hidden="true" style={{height: start * sidebarRowHeight + 'px'}} />}
    {rows.slice(start, end).map(row => 'heading' in row
      ? <h2 key={'section:' + row.heading} className="sidebar-section-heading" data-desktop-section={row.heading} title={row.label}>
          <span className={collapsed ? 'sr-only' : undefined}>{row.label}</span></h2>
      : <div key={row.id} className="workspace-tab-row" data-desktop-chat={row.id}>
          <Button variant="ghost" className={'task-row' + (collapsed ? ' agent-rail-button' : '') + (snapshot.desktopReader?.id === row.id ? ' selected' : '')}
            aria-label={row.title} title={row.title} aria-current={snapshot.desktopReader?.id === row.id ? 'page' : undefined}
            onClick={() => post({action:'openDesktopChat', id:row.id})}>
            <AgentStatusIcon taskID={row.id} working={false} />
            {!collapsed && <span className="task-row-title">{row.title}</span>}
          </Button></div>)}
    {end < rows.length && <div aria-hidden="true" style={{height:(rows.length-end)*sidebarRowHeight+'px'}} />}
  </nav>;
}

export function DesktopChatScope({selected, collapsed, choose}: {selected: boolean; collapsed: boolean; choose: (enabled:boolean)=>void}) {
  return <div className={'desktop-chat-scope' + (collapsed ? ' compact' : '')} role="group" aria-label="Chat source">
    {[false, true].map(desktop => <Button key={String(desktop)} variant="ghost" aria-pressed={selected === desktop}
      aria-label={desktop ? 'Codex desktop chats' : 'Kolmogor agents'} title={desktop ? 'Codex desktop chats' : 'Kolmogor agents'}
      onClick={() => choose(desktop)}>{collapsed ? <Icon name={desktop ? 'terminal' : 'computer'} size={15} /> : desktop ? 'Codex' : 'Agents'}</Button>)}
  </div>;
}

export function DesktopConversation({snapshot, post}: {snapshot: AppSnapshot; post: Action}) {
  const reader = snapshot.desktopReader;
  return <>
    <header className="desktop-reader-title"><strong>{reader?.title ?? 'Codex chats'}</strong></header>
    {reader ? <section className="desktop-reader" aria-label="Codex conversation">
      {(reader.older || reader.error) && <Button variant="outline" disabled={reader.loading}
        onClick={() => post({action:'earlierDesktopMessages'})}>{reader.error ? 'Retry' : 'Earlier messages'}</Button>}
      {reader.loading && <p role="status">Loading messages…</p>}
      {reader.error && <p role="alert">{reader.error}</p>}
      {reader.messages.map(message => <article key={message.id}><strong>{message.role === 'user' ? 'You' : 'Codex'}</strong>
        {message.role === 'assistant' ? <ResponseMarkdown text={message.text} /> : <p className="desktop-reader-user">{message.text}</p>}</article>)}
      {!reader.loading && !reader.error && !reader.messages.length && <p>{reader.older ? 'No chat messages on this page.' : 'No chat messages yet.'}</p>}
    </section> : <div className="no-task-view"><p>Select a Codex chat.</p></div>}
  </>;
}
