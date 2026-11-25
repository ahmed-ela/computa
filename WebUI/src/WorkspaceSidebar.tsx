import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'octane';
import { Button } from '@octanejs/shadcn/Button';
import { AgentStatusIcon } from './AgentStatusIcon';
import { Icon } from './Icon';
import { sidebarRowHeight, useSidebarWindow } from './sidebarWindow';
import { TaskActivityIndicator } from './TaskActivityIndicator';
import { displayedConversationID } from './completionAcknowledgment';
import { isTaskActive, sidebarAgentStatus, startSidebarClock } from './sidebarActivity';
import type { AppSnapshot, NativeAction, TaskSnapshot, WorkspaceBrowser, WorkspaceTab } from './types';

type Item = {
  ref: WorkspaceTab; title: string; searchText: string; open: boolean; pinned: boolean;
  updatedAt: number; task?: TaskSnapshot; browser?: WorkspaceBrowser;
};
type Action = (action: NativeAction) => void;
const keyOf = (ref: WorkspaceTab) => ref.kind + ':' + ref.id;

export function sidebarIsCompact(snapshot: AppSnapshot): boolean {
  return Boolean(snapshot.isTaskSidebarCollapsed && !snapshot.isTaskSidebarPeeked);
}

export function workspaceItems(snapshot: AppSnapshot, search: string): Item[] {
  const needle = search.trim().toLocaleLowerCase();
  const available = new Map<string, Item>();
  for (const task of snapshot.tasks) {
    const title = snapshot.agentNames?.[task.id] || (task.title === 'Untitled task' ? 'New agent' : task.title);
    const ref: WorkspaceTab = { kind: 'agent', id: task.id };
    available.set(keyOf(ref), { ref, task, title, open: false, pinned: false, updatedAt: task.updatedAt,
      searchText: [title, task.title, task.summary, task.workspace].join(' ') });
  }
  if (needle) {
    for (const chat of snapshot.savedChats ?? []) {
      const ref: WorkspaceTab = { kind: 'agent', id: chat.id };
      const title = snapshot.agentNames?.[chat.id.toLowerCase()] || chat.title;
      if (!available.has(keyOf(ref))) available.set(keyOf(ref), {
        ref, title, open: false, pinned: false, updatedAt: chat.updatedAt, searchText: [title, chat.title, chat.workspace].join(' '),
      });
    }
  }
  if (snapshot.mixesBrowserTabsInSidebar) {
    for (const browser of snapshot.workspaceBrowsers ?? []) {
      const ref: WorkspaceTab = { kind: 'browser', id: browser.id };
      available.set(keyOf(ref), { ref, browser, title: browser.title, open: false, pinned: false, updatedAt: 0,
        searchText: [browser.title, browser.host].join(' ') });
    }
  }
  const order = snapshot.workspaceOrder ?? snapshot.tasks.map(task => ({ kind: 'agent' as const, id: task.id }));
  const open: Item[] = [];
  for (const [index, ref] of order.entries()) {
    const key = keyOf(ref), item = available.get(key);
    if (item) {
      item.open = true;
      item.pinned = index < (snapshot.workspacePinnedCount ?? 0);
      open.push(item);
      available.delete(key);
    }
  }
  if (!needle) return open;
  const closed = Array.from(available.values()).filter(item => item.ref.kind === 'agent');
  const items = open.concat(closed.sort((a, b) => b.updatedAt - a.updatedAt));
  return items.filter(item => item.searchText.toLocaleLowerCase().includes(needle));
}

// Headings occupy one row so shortcuts, virtual scrolling and the compact rail share the same geometry.
function sidebarRows(items: Item[]): (Item | 'pinned' | 'tabs')[] {
  if (!items[0]?.pinned) return items;
  const firstRegular = items.findIndex(item => !item.pinned);
  if (firstRegular === -1) return ['pinned', ...items];
  return ['pinned', ...items.slice(0, firstRegular), 'tabs', ...items.slice(firstRegular)];
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
  const active = snapshot.tasks.some(isTaskActive);
  const collapsed = sidebarIsCompact(snapshot);
  const viewedChat = displayedConversationID(snapshot);
  useEffect(() => {
    if (collapsed || !active) return;
    return startSidebarClock(setNow, { now: () => Date.now() / 1000, everySecond: (tick) => {
      const timer = window.setInterval(tick, 1000); return () => window.clearInterval(timer);
    } });
  }, [active, collapsed]);
  const items = useMemo(() => workspaceItems(snapshot, search), [snapshot, search]);
  const rows = useMemo(() => sidebarRows(items), [items]);
  const { start, end } = useSidebarWindow(tabList, rows.length);
  const selectedTab = snapshot.primaryBrowserID
    ? 'browser:' + snapshot.primaryBrowserID
    : 'agent:' + (snapshot.savedChatSelection?.id ?? snapshot.selectedTaskID);
  useLayoutEffect(() => {
    if (tabList.current) tabList.current.scrollTop = 0;
  }, [search]);
  useLayoutEffect(() => {
    const list = tabList.current;
    if (!list) return;
    const selected = list.querySelector('[aria-current="page"]');
    if (selected) {
      selected.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    } else {
      // A shortcut can select a tab outside the mounted rows.
      const index = rows.findIndex(row => typeof row !== 'string' && keyOf(row.ref) === selectedTab);
      if (index >= 0) list.scrollTop = index * sidebarRowHeight;
    }
  }, [selectedTab]);
  const noun = snapshot.mixesBrowserTabsInSidebar ? 'tabs' : 'chats';
  const searchLabel = 'Search ' + noun;
  const select = (item: Item) => {
    if (item.ref.kind === 'agent') post({ action: 'selectTask', id: item.ref.id });
    else post({ action: 'selectWorkspaceTab', tab: item.ref });
  };
  const searchField = useRef<HTMLInputElement | null>(null);
  const nativeControls = nativeHost && snapshot.nativeSidebarControls;
  const currentPage = snapshot.workspaceBrowsers?.find(tab => tab.id === snapshot.primaryBrowserID);
  const toggleLabel = snapshot.isTaskSidebarCollapsed ? 'Expand chat sidebar' : 'Collapse chat sidebar';
  const sidebarToggle = <Button variant="ghost" size="icon-xs" id="task-sidebar-toggle"
    aria-label={toggleLabel} title={toggleLabel} aria-expanded={!snapshot.isTaskSidebarCollapsed}
    onClick={() => post({ action: 'setTaskSidebarCollapsed', collapsed: !snapshot.isTaskSidebarCollapsed })}>
    <Icon name={snapshot.isTaskSidebarCollapsed ? 'sidebarOpen' : 'sidebarClose'} size={16} /></Button>;
  return <aside className={snapshot.sidebarDropTarget ? "sidebar workspace-drop-target" : "sidebar"} aria-label="Workspace navigation"
    style={snapshot.sidebarRail && {
      '--rail-width': snapshot.sidebarRail.width + 'px',
      '--rail-center': snapshot.sidebarRail.iconCenter + 'px',
    }}
    onMouseEnter={() => { if (!nativeHost && snapshot.isTaskSidebarCollapsed) post({ action: 'setTaskSidebarPeeked', peeked: true }); }}
    onMouseLeave={() => { if (!nativeHost && snapshot.isTaskSidebarCollapsed) post({ action: 'setTaskSidebarPeeked', peeked: false }); }}>
    <div className="window-drag-strip" style={snapshot.titlebarHeight ? { height: snapshot.titlebarHeight + 'px' } : undefined}>
      {!snapshot.mixesBrowserTabsInSidebar && !nativeControls && sidebarToggle}
    </div>
    {snapshot.mixesBrowserTabsInSidebar && <div className="sidebar-controls-row">
      {sidebarToggle}
      {nativeHost && snapshot.browserAddressPlacement === 'titleBar' && !currentPage && !collapsed &&
        <Button variant="ghost" size="icon-xs" aria-label="Open Google in a new tab" title="Open Google in a new tab"
          onClick={() => post({ action: 'newWorkspaceBrowserTab' })}><Icon name="browser" size={15} /></Button>}
      {nativeHost && currentPage && !collapsed && <div className="sidebar-browser-navigation" role="group" aria-label="Browser navigation">
        <Button variant="ghost" size="icon-xs" aria-label="Back" title="Back" disabled={!currentPage.canGoBack}
          onClick={() => post({ action: 'browserNavigation', id: currentPage.id, command: 'back' })}>
          <Icon name="back" size={16} /></Button>
        <Button variant="ghost" size="icon-xs" aria-label="Forward" title="Forward" disabled={!currentPage.canGoForward}
          onClick={() => post({ action: 'browserNavigation', id: currentPage.id, command: 'forward' })}>
          <Icon name="chevron" size={16} /></Button>
        <Button variant="ghost" size="icon-xs" aria-label={currentPage.isLoading ? 'Stop loading' : 'Reload'}
          title={currentPage.isLoading ? 'Stop loading' : 'Reload'} disabled={!currentPage.isLoading && !currentPage.canReload}
          onClick={() => post({ action: 'browserNavigation', id: currentPage.id, command: currentPage.isLoading ? 'stop' : 'reload' })}>
          <Icon name={currentPage.isLoading ? 'x' : 'reload'} size={15} /></Button>
      </div>}
    </div>}
    {nativeHost && snapshot.browserAddressPlacement === 'sidebar' && (snapshot.mixesBrowserTabsInSidebar || currentPage) && <button type="button" className="sidebar-address"
      aria-label={currentPage ? 'Website address' : 'Open Google in a new tab'}
      title={currentPage ? 'Edit website address (⌘L)' : 'Open Google in a new tab'}
      onClick={() => currentPage ? post({ action: 'openBrowserAddress', id: currentPage.id }) : post({ action: 'newWorkspaceBrowserTab' })}>
      <Icon name="browser" size={15} />
      {currentPage && !collapsed && <span>{currentPage.host || 'Search or enter URL'}</span>}
    </button>}
    <div className="sidebar-search-row">
      {collapsed && <Button variant="ghost" size="icon-xs" className="sidebar-search-icon" aria-label={searchLabel}
        onClick={() => document.dispatchEvent(new Event('kolmogor-focus-tab-search'))}><Icon name="search" size={15} /></Button>}
      {!collapsed && <div className="task-search">
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
          setSearch('');
          post({ action: nativeHost ? 'openTabLauncher' : 'newWorkspaceBrowserTab' });
        }}>
        <span className="new-browser-tab-icon" aria-hidden="true" />
        <span className={collapsed ? 'sr-only' : undefined}>New tab</span></Button>}
      {snapshot.pendingApprovalCount > 0 && <div className="nav-button approval-nav" role="status"><Icon name="info" size={17} />
        <span className={collapsed ? 'sr-only' : undefined}>Native approval</span><span className="count-pill">{snapshot.pendingApprovalCount}</span></div>}
    </nav>}
    <nav ref={tabList} style={{ '--sidebar-row-height': sidebarRowHeight + 'px' }} className={'task-list' + (collapsed ? ' agent-rail' : '')} aria-label={snapshot.mixesBrowserTabsInSidebar ? 'Tabs' : 'Chats'}>
      {start > 0 && <div aria-hidden="true" style={{ height: start * sidebarRowHeight + 'px' }} />}
      {rows.slice(start, end).map((item,index) => {
        if (typeof item === 'string') {
          const heading = item === 'pinned' ? 'Pinned' : snapshot.mixesBrowserTabsInSidebar ? 'Tabs' : 'Chats';
          const dividerOnly = item === 'tabs' && snapshot.mixesBrowserTabsInSidebar;
          return <h2 key={item} className="sidebar-section-heading" data-section={item} title={dividerOnly ? undefined : heading}>
            {item === 'pinned' && <Icon name="pin" size={13} />}
            <span className={collapsed || dividerOnly ? 'sr-only' : undefined}>{heading}</span>
          </h2>;
        }
        const status = item.task && sidebarAgentStatus(item.task, item.task.id === viewedChat);
        const selected = keyOf(item.ref) === selectedTab;
        const label = status ? item.title + (status === 'working' ? ' — Working' : ' — Ready to read') : item.title;
        return <div key={keyOf(item.ref)} className="workspace-tab-row" data-pinned={item.pinned ? 'true' : undefined}
          data-drag-id={item.ref.id} data-drag-kind={item.ref.kind} draggable={item.open}
          onDragStart={event => {
            if (!item.open) return;
            if (nativeHost) {
              event.preventDefault();
              post({ action: 'beginWorkspaceTabDrag', tab: item.ref });
            } else {
              dragging.current = item.ref;
              event.dataTransfer?.setData('text/plain', keyOf(item.ref));
            }
          }}
          onDragEnd={() => { dragging.current = null; }}
          onDragOver={event => { if (item.open && dragging.current) event.preventDefault(); }}
          onDrop={event => { event.preventDefault(); if (item.open && dragging.current) post({ action: 'moveWorkspaceTab', tab: dragging.current, target: item.ref }); dragging.current = null; }}>
          <Button variant="ghost" className={'task-row' + (collapsed ? ' agent-rail-button' : '') + (selected ? ' selected' : '')}
            aria-label={label} title={label} data-agent-status={status}
            data-tab-kind={item.ref.kind} aria-current={selected ? 'page' : undefined} onClick={() => select(item)}
            onKeyDown={event => {
              if (!item.open || !event.altKey || !['ArrowUp','ArrowDown'].includes(event.key)) return;
              event.preventDefault(); const neighbor = rows[start + index + (event.key === 'ArrowUp' ? -1 : 1)];
              if (typeof neighbor !== 'string' && neighbor?.open) post({ action: 'moveWorkspaceTab', tab: item.ref, target: neighbor.ref });
            }}>
            {item.browser ? <SiteIcon tab={item.browser} /> : <AgentStatusIcon taskID={item.ref.id} />}
            {!collapsed && <span className="task-row-title">{item.title}</span>}
            {item.task && <TaskActivityIndicator task={item.task} status={status} compact={collapsed} now={now} />}
          </Button>
          {item.open && !collapsed && <Button variant="ghost" size="icon-xs" className="workspace-pin"
            aria-label={(item.pinned ? 'Unpin tab: ' : 'Pin tab: ') + item.title} title={item.pinned ? 'Unpin tab' : 'Pin tab'}
            onClick={() => post({ action: 'setWorkspaceTabPinned', tab: item.ref, pinned: !item.pinned })}>
            <Icon name={item.pinned ? 'unpin' : 'pin'} size={13} /></Button>}
          {item.open && !collapsed && <Button variant="ghost" size="icon-xs" className="workspace-close" aria-label={'Close tab: ' + item.title}
            title="Close tab" onClick={() => post({ action: 'closeWorkspaceTab', tab: item.ref })}><Icon name="x" size={12} /></Button>}
        </div>;
      })}
      {end < rows.length && <div aria-hidden="true" style={{ height: (rows.length - end) * sidebarRowHeight + 'px' }} />}
      {!items.length && !collapsed && <div className="sidebar-empty">{search ? 'No matching ' + noun : 'No ' + noun}</div>}
    </nav>
  </aside>;
}
