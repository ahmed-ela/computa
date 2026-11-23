import { useEffect, useRef, useState } from 'octane';
import { Button } from '@octanejs/shadcn/Button';
import { AgentStatusIcon } from './AgentStatusIcon';
import { Icon } from './Icon';
import { TaskActivityIndicator } from './TaskActivityIndicator';
import { isTaskActive, sidebarAgentStatus, startSidebarClock } from './sidebarActivity';
import type { AppSnapshot, NativeAction, TaskSnapshot, WorkspaceBrowser, WorkspaceTab } from './types';

type Item = {
  ref: WorkspaceTab; title: string; searchText: string; open: boolean;
  updatedAt: number; task?: TaskSnapshot; browser?: WorkspaceBrowser;
};
type Action = (action: NativeAction) => void;
const keyOf = (ref: WorkspaceTab) => ref.kind + ':' + ref.id;

export function sidebarIsCompact(snapshot: AppSnapshot): boolean {
  return Boolean(snapshot.isTaskSidebarCollapsed && !snapshot.isTaskSidebarPeeked);
}

export function workspaceItems(snapshot: AppSnapshot, search: string): Item[] {
  const collapsed = sidebarIsCompact(snapshot);
  const available = new Map<string, Item>();
  for (const task of snapshot.tasks) {
    if (collapsed && !isTaskActive(task)) continue;
    const ref: WorkspaceTab = { kind: 'agent', id: task.id };
    available.set(keyOf(ref), { ref, task, title: task.title, open: false, updatedAt: task.updatedAt,
      searchText: [task.title, task.summary, task.workspace].join(' ') });
  }
  if (!collapsed) {
    for (const chat of snapshot.savedChats ?? []) {
      const ref: WorkspaceTab = { kind: 'agent', id: chat.id };
      if (!available.has(keyOf(ref))) available.set(keyOf(ref), {
        ref, title: chat.title, open: false, updatedAt: chat.updatedAt, searchText: [chat.title, chat.workspace].join(' '),
      });
    }
  }
  if (snapshot.mixesBrowserTabsInSidebar) {
    for (const browser of snapshot.workspaceBrowsers ?? []) {
      const ref: WorkspaceTab = { kind: 'browser', id: browser.id };
      available.set(keyOf(ref), { ref, browser, title: browser.title, open: false, updatedAt: 0,
        searchText: [browser.title, browser.host].join(' ') });
    }
  }
  const order = snapshot.workspaceOrder ?? snapshot.tasks.map(task => ({ kind: 'agent' as const, id: task.id }));
  const open: Item[] = [];
  for (const ref of order) {
    const key = keyOf(ref), item = available.get(key);
    if (item) {
      item.open = true;
      open.push(item);
      available.delete(key);
    }
  }
  const closed = Array.from(available.values()).filter(item => item.ref.kind === 'agent');
  const items = open.concat(closed.sort((a, b) => b.updatedAt - a.updatedAt));
  const needle = search.trim().toLocaleLowerCase();
  return needle ? items.filter(item => item.searchText.toLocaleLowerCase().includes(needle)) : items;
}

function SiteIcon({ tab }: { tab: WorkspaceBrowser }) {
  if (tab.isFaviconLoading) return <span aria-hidden="true" className="site-favicon-spinner" />;
  if (tab.favicon) return <img className="site-favicon" alt="" src={'data:image/png;base64,' + tab.favicon} />;
  const letter = tab.host?.replace(/^www\./i, '').slice(0, 1).toUpperCase();
  return letter ? <span aria-hidden="true" className="site-initial">{letter}</span> : <Icon name="browser" size={16} />;
}

export function WorkspaceSidebar({ snapshot, search, setSearch, nativeHost, post }: {
  snapshot: AppSnapshot; search: string; setSearch: (value: string) => void; nativeHost: boolean; post: Action;
}) {
  const [now, setNow] = useState(() => Date.now() / 1000);
  const dragging = useRef<WorkspaceTab | null>(null);
  const tabList = useRef<HTMLElement | null>(null);
  useEffect(() => {
    tabList.current?.querySelector('[aria-current="page"]')?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }, [snapshot.selectedTaskID, snapshot.primaryBrowserID, snapshot.isTaskSidebarCollapsed, snapshot.isTaskSidebarPeeked]);
  const active = snapshot.tasks.some(isTaskActive);
  const collapsed = sidebarIsCompact(snapshot);
  useEffect(() => {
    if (collapsed || !active) return;
    return startSidebarClock(setNow, { now: () => Date.now() / 1000, everySecond: (tick) => {
      const timer = window.setInterval(tick, 1000); return () => window.clearInterval(timer);
    } });
  }, [active, collapsed]);
  const items = workspaceItems(snapshot, search);
  const noun = snapshot.mixesBrowserTabsInSidebar ? 'tabs' : 'chats';
  const searchLabel = 'Search ' + noun;
  const select = (item: Item) => {
    if (item.ref.kind === 'agent') post({ action: 'selectTask', id: item.ref.id });
    else post({ action: 'selectWorkspaceTab', tab: item.ref });
  };
  const searchField = useRef<HTMLInputElement | null>(null);
  const nativeControls = nativeHost && snapshot.nativeSidebarControls;
  return <aside className="sidebar" aria-label="Workspace navigation"
    onMouseEnter={() => { if (!nativeHost && snapshot.isTaskSidebarCollapsed) post({ action: 'setTaskSidebarPeeked', peeked: true }); }}
    onMouseLeave={() => { if (!nativeHost && snapshot.isTaskSidebarCollapsed) post({ action: 'setTaskSidebarPeeked', peeked: false }); }}>
    <div className="window-drag-strip" style={snapshot.titlebarHeight ? { height: snapshot.titlebarHeight + 'px' } : undefined}>
      {!nativeControls &&
        <Button variant="ghost" size="icon-xs" aria-label={snapshot.isTaskSidebarCollapsed ? 'Expand chat sidebar' : 'Collapse chat sidebar'}
          aria-expanded={!snapshot.isTaskSidebarCollapsed} onClick={() => post({ action: 'setTaskSidebarCollapsed', collapsed: !snapshot.isTaskSidebarCollapsed })}>
          <Icon name="sidebar" size={16} /></Button>
      }
      {collapsed && !nativeControls && <Button variant="ghost" size="icon-xs" aria-label={searchLabel}
        onClick={() => document.dispatchEvent(new Event('kolmogor-focus-tab-search'))}><Icon name="search" size={15} /></Button>}
      {!collapsed && !nativeControls && <div className="task-search">
        <Icon name="search" size={15} />
        <input ref={searchField} type="text" id="task-search" aria-label={searchLabel} placeholder="Search"
          value={search} autoComplete="off" spellCheck={false}
          onKeyDown={event => { if (event.key === 'Escape') { event.preventDefault(); setSearch(''); } }}
          onInput={event => setSearch((event.currentTarget as HTMLInputElement).value)} />
        {search && <Button variant="ghost" size="icon-xs" className="clear-search" aria-label="Clear search" title="Clear search"
          onClick={() => { setSearch(''); searchField.current?.focus(); }}><Icon name="x" size={13} /></Button>}
      </div>}
    </div>
    {(snapshot.mixesBrowserTabsInSidebar || snapshot.pendingApprovalCount > 0) && <nav className="primary-nav" aria-label="Primary">
      {snapshot.mixesBrowserTabsInSidebar && <Button variant="ghost" className="nav-button new-task-button" aria-label="New tab" title="New tab"
        onClick={() => {
          if (nativeControls) post({ action: 'clearSidebarSearch' });
          setSearch('');
          post({ action: nativeHost ? 'openTabLauncher' : 'newWorkspaceBrowserTab' });
        }}>
        <span className="new-browser-tab-icon" aria-hidden="true" />
        <span className={collapsed ? 'sr-only' : undefined}>New tab</span></Button>}
      {snapshot.pendingApprovalCount > 0 && <div className="nav-button approval-nav" role="status"><Icon name="info" size={17} />
        <span className={collapsed ? 'sr-only' : undefined}>Native approval</span><span className="count-pill">{snapshot.pendingApprovalCount}</span></div>}
    </nav>}
    <nav ref={tabList} className={'task-list' + (collapsed ? ' agent-rail' : '')} aria-label={snapshot.mixesBrowserTabsInSidebar ? 'Tabs' : 'Chats'}>
      {items.map((item,index) => {
        const status = item.task && sidebarAgentStatus(item.task);
        const selected = item.browser ? snapshot.primaryBrowserID === item.ref.id : !snapshot.primaryBrowserID && (snapshot.savedChatSelection?.id ?? snapshot.selectedTaskID) === item.ref.id;
        const label = status ? item.title + (status === 'working' ? ' — Working' : ' — Ready to read') : item.title;
        return <div key={keyOf(item.ref)} className="workspace-tab-row" draggable={item.open}
          onDragStart={event => { if (!item.open) return; dragging.current = item.ref; event.dataTransfer?.setData('text/plain', keyOf(item.ref)); }}
          onDragEnd={() => { dragging.current = null; }}
          onDragOver={event => { if (item.open && dragging.current) event.preventDefault(); }}
          onDrop={event => { event.preventDefault(); if (item.open && dragging.current) post({ action: 'moveWorkspaceTab', tab: dragging.current, target: item.ref }); dragging.current = null; }}>
          <Button variant="ghost" className={'task-row' + (collapsed ? ' agent-rail-button' : '') + (selected ? ' selected' : '')}
            aria-label={label} title={label} data-agent-status={collapsed ? status : undefined}
            data-tab-kind={item.ref.kind} aria-current={selected ? 'page' : undefined} onClick={() => select(item)}
            onKeyDown={event => {
              if (!item.open || !event.altKey || !['ArrowUp','ArrowDown'].includes(event.key)) return;
              event.preventDefault(); const neighbor = items[index + (event.key === 'ArrowUp' ? -1 : 1)];
              if (neighbor?.open) post({ action: 'moveWorkspaceTab', tab: item.ref, target: neighbor.ref });
            }}>
            {item.browser ? <SiteIcon tab={item.browser} /> : collapsed
              ? <AgentStatusIcon taskID={item.ref.id} /> : null}
            {!collapsed && <span className="task-row-title">{item.title}</span>}
            {!collapsed && item.task && <TaskActivityIndicator task={item.task} now={now} />}
          </Button>
          {item.open && !collapsed && <Button variant="ghost" size="icon-xs" className="workspace-close" aria-label={'Close tab: ' + item.title}
            title="Close tab" onClick={() => post({ action: 'closeWorkspaceTab', tab: item.ref })}><Icon name="x" size={12} /></Button>}
        </div>;
      })}
      {!items.length && !collapsed && <div className="sidebar-empty">{search ? 'No matching ' + noun : 'No ' + noun}</div>}
    </nav>
  </aside>;
}
