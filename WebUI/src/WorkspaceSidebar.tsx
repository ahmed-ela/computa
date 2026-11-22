import { useEffect, useRef, useState } from 'octane';
import { Button } from '@octanejs/shadcn/Button';
import { Input } from '@octanejs/shadcn/Input';
import { AgentStatusIcon } from './AgentStatusIcon';
import { BotAdd16Filled, Icon } from './Icon';
import { TaskActivityIndicator } from './TaskActivityIndicator';
import { isTaskActive, sidebarAgentStatus, startSidebarClock } from './sidebarActivity';
import type { AppSnapshot, NativeAction, TaskSnapshot, WorkspaceBrowser, WorkspaceTab } from './types';

type Item = { ref: WorkspaceTab; title: string; searchText: string } & (
  { task: TaskSnapshot; browser?: never } | { browser: WorkspaceBrowser; task?: never }
);
type Action = (action: NativeAction) => void;
const keyOf = (ref: WorkspaceTab) => ref.kind + ':' + ref.id;

export function workspaceItems(snapshot: AppSnapshot, history: boolean, search: string): Item[] {
  const agents = new Map(snapshot.tasks.map(task => [task.id, task]));
  const browsers = new Map(snapshot.workspaceBrowsers?.map(tab => [tab.id, tab]));
  const open = snapshot.workspaceOrder ?? snapshot.tasks.map(task => ({ kind: 'agent' as const, id: task.id }));
  const openKeys = new Set(open.map(keyOf));
  const order = history ? snapshot.tasks.map(task => ({ kind: 'agent' as const, id: task.id }))
    .filter(ref => !openKeys.has(keyOf(ref))) : open;
  const items: Item[] = [];
  for (const ref of order) {
    if (ref.kind === 'agent') {
      const task = agents.get(ref.id);
      if (task) items.push({ ref, task, title: task.title, searchText: [task.title, task.summary, task.workspace].join(' ') });
    } else {
      const browser = browsers.get(ref.id);
      if (browser) items.push({ ref, browser, title: browser.title, searchText: [browser.title, browser.host].join(' ') });
    }
  }
  const needle = search.trim().toLocaleLowerCase();
  return needle ? items.filter(item => item.searchText.toLocaleLowerCase().includes(needle)) : items;
}

function SiteIcon({ tab }: { tab: WorkspaceBrowser }) {
  if (tab.favicon) return <img className="site-favicon" alt="" src={'data:image/png;base64,' + tab.favicon} />;
  const letter = tab.host?.replace(/^www\./i, '').slice(0, 1).toUpperCase();
  return letter ? <span aria-hidden="true" className="site-initial">{letter}</span> : <Icon name="browser" size={16} />;
}

export function WorkspaceSidebar({ snapshot, search, setSearch, nativeHost, post }: {
  snapshot: AppSnapshot; search: string; setSearch: (value: string) => void; nativeHost: boolean; post: Action;
}) {
  const [history, setHistory] = useState(false);
  const [now, setNow] = useState(() => Date.now() / 1000);
  const dragging = useRef<WorkspaceTab | null>(null);
  const active = snapshot.tasks.some(isTaskActive);
  const collapsed = Boolean(snapshot.isTaskSidebarCollapsed);
  useEffect(() => {
    if (!active) return;
    return startSidebarClock(setNow, { now: () => Date.now() / 1000, everySecond: (tick) => {
      const timer = window.setInterval(tick, 1000); return () => window.clearInterval(timer);
    } });
  }, [active]);
  const items = workspaceItems(snapshot, history, collapsed ? '' : search);
  const select = (item: Item) => {
    if (history) { setHistory(false); setSearch(''); post({ action: 'selectTask', id: item.ref.id }); }
    else post({ action: 'selectWorkspaceTab', tab: item.ref });
  };
  const create = (action: 'createTask' | 'newWorkspaceBrowserTab') => {
    setHistory(false); setSearch(''); post({ action });
  };
  return <aside className="sidebar" aria-label="Workspace navigation">
    <div className="window-drag-strip">
      {!nativeHost && <Button variant="ghost" size="icon-xs" aria-label={collapsed ? 'Expand chat sidebar' : 'Collapse chat sidebar'}
        aria-expanded={!collapsed} onClick={() => post({ action: 'setTaskSidebarCollapsed', collapsed: !collapsed })}>
        <Icon name="sidebar" size={16} /></Button>}
    </div>
    <nav className="primary-nav" aria-label="Primary">
      <Button variant="outline" className="nav-button new-task-button" aria-label="New task" title="New task" onClick={() => create('createTask')}>
        <BotAdd16Filled /><span className={collapsed ? 'sr-only' : undefined}>New task</span></Button>
      <Button variant="outline" className="nav-button new-task-button" aria-label="New browser tab" title="New browser tab" onClick={() => create('newWorkspaceBrowserTab')}>
        <span className="add-browser-icon"><Icon name="browser" size={15} /><b aria-hidden="true">+</b></span>
        <span className={collapsed ? 'sr-only' : undefined}>New browser tab</span></Button>
      {snapshot.pendingApprovalCount > 0 && <div className="nav-button approval-nav" role="status"><Icon name="info" size={17} />
        <span className={collapsed ? 'sr-only' : undefined}>Native approval</span><span className="count-pill">{snapshot.pendingApprovalCount}</span></div>}
    </nav>
    {!collapsed && <div className="task-search">
      <Input id="task-search" className="pr-8" aria-label={history ? 'Search chat history' : 'Search tabs'}
        placeholder={history ? 'Search chat history' : 'Search tabs'} value={search} onInput={event => setSearch((event.currentTarget as HTMLInputElement).value)} />
      {search && <Button variant="ghost" size="icon-xs" aria-label="Clear search" onClick={() => setSearch('')}><Icon name="x" size={13} /></Button>}
    </div>}
    <div className="sidebar-section-heading workspace-list-heading">{!collapsed && <span>{history ? 'Chat history' : 'Open tabs'}</span>}
      <Button variant="ghost" size="icon-xs" aria-pressed={history} aria-label={history ? 'Show open tabs' : 'Show chat history'}
        title={history ? 'Show open tabs' : 'Show chat history'} onClick={() => { setSearch(''); setHistory(!history); }}>
        <Icon name={history ? 'sidebar' : 'history'} size={15} /></Button></div>
    <nav className={'task-list' + (collapsed ? ' agent-rail' : '')} aria-label={history ? 'Chat history' : 'Open tabs'}>
      {items.map((item,index) => {
        const status = item.task && sidebarAgentStatus(item.task);
        const selected = item.browser ? snapshot.primaryBrowserID === item.ref.id : !snapshot.primaryBrowserID && snapshot.selectedTaskID === item.ref.id;
        const label = status ? item.title + (status === 'working' ? ' — Working' : ' — Ready to read') : item.title;
        return <div key={keyOf(item.ref)} className="workspace-tab-row" draggable={!history}
          onDragStart={event => { dragging.current = item.ref; event.dataTransfer?.setData('text/plain', keyOf(item.ref)); }}
          onDragEnd={() => { dragging.current = null; }}
          onDragOver={event => { if (dragging.current) event.preventDefault(); }}
          onDrop={event => { event.preventDefault(); if (dragging.current) post({ action: 'moveWorkspaceTab', tab: dragging.current, target: item.ref }); dragging.current = null; }}>
          <Button variant="ghost" size={collapsed ? 'icon' : 'default'} className={collapsed ? 'agent-rail-button' : 'task-row' + (selected ? ' selected' : '')}
            aria-label={label} title={label} data-agent-status={collapsed ? status : undefined}
            data-tab-kind={item.ref.kind} aria-current={selected ? 'page' : undefined} onClick={() => select(item)}
            onKeyDown={event => {
              if (history || !event.altKey || !['ArrowUp','ArrowDown'].includes(event.key)) return;
              event.preventDefault(); const neighbor = items[index + (event.key === 'ArrowUp' ? -1 : 1)];
              if (neighbor) post({ action: 'moveWorkspaceTab', tab: item.ref, target: neighbor.ref });
            }}>
            {item.browser ? <SiteIcon tab={item.browser} /> : collapsed && status
              ? <AgentStatusIcon working={status === 'working'} taskID={item.ref.id} /> : <Icon name="agent" size={16} />}
            {!collapsed && <span className="task-row-title">{item.title}</span>}
            {!collapsed && item.task && <TaskActivityIndicator task={item.task} now={now} />}
          </Button>
          {!history && <Button variant="ghost" size="icon-xs" className="workspace-close" aria-label={'Close tab: ' + item.title}
            title="Close tab" onClick={() => post({ action: 'closeWorkspaceTab', tab: item.ref })}><Icon name="x" size={12} /></Button>}
        </div>;
      })}
      {!items.length && !collapsed && <div className="sidebar-empty">{search ? 'No matching tabs' : history ? 'No closed chats' : 'No open tabs'}</div>}
    </nav>
  </aside>;
}
