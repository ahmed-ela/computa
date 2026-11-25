import 'octane/compiler/register';
import { expect, mock, test } from 'bun:test';
import { createElement as h } from 'octane';
import { renderToStaticMarkup } from 'octane/server';
import { makePreviewSnapshot } from '../src/preview';
import { displayedCompletionAcknowledgment } from '../src/completionAcknowledgment';
import type { AppSnapshot } from '../src/types';
mock.module('@octanejs/shadcn/Button', () => ({ Button: ({ variant: _variant, size: _size, ...props }: Record<string, unknown>) => h('button', props) }));
mock.module('@octanejs/shadcn/Input', () => ({ Input: (props: Record<string, unknown>) => h('input', props) }));
const { workspaceItems, WorkspaceSidebar } = await import('../src/WorkspaceSidebar');

function fixture(): AppSnapshot {
  const snapshot = makePreviewSnapshot();
  const sharedID = snapshot.tasks[0].id;
  return { ...snapshot, mixesBrowserTabsInSidebar: true, selectedTaskID: sharedID, primaryBrowserID: sharedID,
    workspaceOrder: [{kind:'browser', id:sharedID}, {kind:'agent', id:sharedID}, {kind:'browser', id:'empty'}],
    workspaceBrowsers: [{id:sharedID,title:'Trips',host:'www.rail.example'}, {id:'empty',title:'New tab'}] };
}
test('open tabs keep their order and closed chats appear only in search', () => {
  const snapshot = fixture();
  const stale = { id: snapshot.tasks[0].id, title: 'Old title', workspace: '/', updatedAt: 0 };
  const older = { id: 'oldest', title: 'Saved conversation', workspace: '/old-project', updatedAt: 0 };
  snapshot.savedChats = [stale, older];
  const items = workspaceItems(snapshot, '');
  expect(items.filter(item => item.open).map(item => item.ref)).toEqual(snapshot.workspaceOrder!);
  expect(items.filter(item => !item.open)).toEqual([]);
  expect(workspaceItems(snapshot, 'rail.example').map(item => item.title)).toEqual(['Trips']);
  expect(workspaceItems(snapshot, 'OLD-project').map(item => item.title)).toEqual([older.title]);
  expect(workspaceItems({ ...snapshot, workspaceOrder: [] }, '')).toEqual([]);
});
test('sidebar uses the site icon or hostname initial in both sizes; an empty tab uses the globe', () => {
  for (const collapsed of [true,false]) {
    const snapshot = { ...fixture(), isTaskSidebarCollapsed:collapsed };
    const render = () => renderToStaticMarkup(h(WorkspaceSidebar, {snapshot,search:'',setSearch:()=>{},post:()=>{},nativeHost:true})).html;
    const initial = render();
    expect(initial).toContain('class="site-initial">R</span>');
    expect(initial.match(/aria-current="page"/g)?.length).toBe(1);
    expect(initial).toContain('aria-label="New tab"');
    expect(initial).not.toContain('site-favicon-spinner');
    snapshot.workspaceBrowsers![0].isFaviconLoading = true;
    expect(render()).toContain('class="site-favicon-spinner"');
    expect(render()).not.toContain('class="site-initial"');
    snapshot.workspaceBrowsers![0].isFaviconLoading = false;
    snapshot.workspaceBrowsers![0].favicon = 'aWNvbg==';
    expect(render()).toContain('src="data:image/png;base64,aWNvbg=="');
    expect(render()).not.toContain('site-favicon-spinner');
    expect(render()).not.toContain('class="site-initial"');
  }
});

test('pinned tabs appear once above regular tabs, and filtering hides empty sections', () => {
  const snapshot = fixture();
  snapshot.workspacePinnedCount = 2;
  const render = (search: string, compact = false) => renderToStaticMarkup(h(WorkspaceSidebar, {
    snapshot: { ...snapshot, isTaskSidebarCollapsed: compact }, search, setSearch: () => {}, post: () => {}, nativeHost: true,
  })).html;
  for (const compact of [false, true]) {
    const html = render('', compact);
    expect(html.match(/data-tab-kind=/g)).toHaveLength(3);
    expect(html.match(/data-pinned="true"/g)).toHaveLength(2);
    expect(html.indexOf('data-section="pinned"')).toBeLessThan(html.indexOf('aria-label="Trips"'));
    expect(html.indexOf('aria-label="Trips"')).toBeLessThan(html.indexOf('data-section="tabs"'));
    const divider = html.match(/<h2[^>]*data-section="tabs"[^>]*>[\s\S]*?<\/h2>/)?.[0];
    expect(divider).toContain('<span class="sr-only">Tabs</span>');
    expect(divider).not.toContain('title=');
    expect(html).toContain('lucide-pin');
  }
  expect(render('')).toContain('aria-label="Unpin tab: Trips"');
  expect(render('')).toContain('aria-label="Pin tab: New tab"');
  snapshot.workspaceBrowsers![1].canPin = true;
  expect(render('')).toContain('aria-label="Pin tab: New tab"');
  snapshot.workspaceBrowsers![1].canPin = false;
  expect(render('')).not.toContain('aria-label="Pin tab: New tab"');
  expect(render('')).toContain('aria-label="Close tab: New tab"');
  expect(render('rail.example')).toContain('data-section="pinned"');
  expect(render('rail.example')).not.toContain('data-section="tabs"');
  expect(render('New tab')).not.toContain('data-section="pinned"');
  snapshot.workspacePinnedCount = 0;
  expect(render('')).not.toContain('sidebar-section-heading');
});
test('a matching browser tab stays available at either width in mixed mode', () => {
  for (const isTaskSidebarCollapsed of [false, true]) {
    const html = renderToStaticMarkup(h(WorkspaceSidebar, {
      snapshot: { ...fixture(), isTaskSidebarCollapsed }, search: 'rail.example',
      setSearch: () => {}, nativeHost: true, post: () => {},
    })).html;
    expect(html.match(/data-tab-kind=/g)?.length).toBe(1);
    expect(html).toContain('aria-label="Trips"');
  }
});
test('the browser address is separate from the tab filter and follows the active browser', () => {
  const snapshot = fixture();
  const render = () => renderToStaticMarkup(h(WorkspaceSidebar, {
    snapshot, search: '', setSearch: () => {}, nativeHost: true, post: () => {},
  })).html;
  expect(snapshot.browserAddressPlacement).toBe('titleBar');
  expect(render()).not.toContain('class="sidebar-address"');
  expect(render()).not.toContain('aria-label="Browser navigation"');
  expect(render()).toContain('id="task-search"');
  snapshot.browserAddressPlacement = 'sidebar';
  const expanded = render();
  const controls = expanded.indexOf('class="sidebar-controls-row"');
  const toggle = expanded.indexOf('id="task-sidebar-toggle"');
  const navigation = expanded.indexOf('aria-label="Browser navigation"');
  const address = expanded.indexOf('aria-label="Website address"');
  expect(controls).toBeGreaterThan(expanded.indexOf('class="window-drag-strip"'));
  expect(toggle).toBeGreaterThan(controls);
  expect(navigation).toBeGreaterThan(toggle);
  expect(address).toBeGreaterThan(navigation);
  expect(address).toBeGreaterThan(expanded.indexOf('class="window-drag-strip"'));
  expect(expanded.indexOf('id="task-search"')).toBeGreaterThan(address);
  expect(expanded).toContain('www.rail.example');
  snapshot.isTaskSidebarCollapsed = true;
  expect(render()).toContain('aria-label="Expand chat sidebar"');
  expect(render()).toContain('aria-label="Website address"');
  expect(render()).not.toContain('aria-label="Browser navigation"');
  snapshot.isTaskSidebarPeeked = true;
  expect(render()).toContain('aria-label="Browser navigation"');
  Object.assign(snapshot.workspaceBrowsers![0], { isLoading: true });
  expect(render()).toContain('aria-label="Stop loading"');
  snapshot.primaryBrowserID = undefined;
  for (const compact of [false, true]) {
    snapshot.isTaskSidebarCollapsed = compact;
    snapshot.isTaskSidebarPeeked = false;
    const html = render();
    const emptyAddress = html.match(/<button[^>]*class="sidebar-address"[^>]*>[\s\S]*?<\/button>/)?.[0];
    expect(emptyAddress).toContain('aria-label="Open Google in a new tab"');
    expect(emptyAddress).not.toMatch(/<span|rail\.example/);
    expect(html.indexOf(emptyAddress!)).toBeLessThan(html.indexOf('class="sidebar-search-row"'));
  }
  expect(render()).not.toContain('aria-label="Browser navigation"');
});

test('a browser in the main pane does not acknowledge the previously selected agent', () => {
  const snapshot = fixture(), task = snapshot.tasks[0];
  Object.assign(task,{status:'Completed',hasUnreadCompletion:true,isBusy:false,unreadCompletionID:'completion'});
  expect(displayedCompletionAcknowledgment(snapshot,true,true)).toBeUndefined();
  expect(displayedCompletionAcknowledgment({...snapshot,primaryBrowserID:undefined},true,true)?.taskID).toBe(task.id);
});

test('chat-only navigation hides browser rows and creation in either sidebar width', () => {
  for (const isTaskSidebarCollapsed of [false, true]) {
    const snapshot = { ...fixture(), mixesBrowserTabsInSidebar: false, primaryBrowserID: undefined, isTaskSidebarCollapsed };
    const html = renderToStaticMarkup(h(WorkspaceSidebar, {
      snapshot, search: '', setSearch: () => {}, nativeHost: true, post: () => {},
    })).html;
    expect(html).toContain('aria-label="Chats"');
    expect(html).not.toContain('Show chat history');
    expect(html).not.toContain('aria-label="New agent"');
    expect(html).toContain('data-tab-kind="agent"');
    expect(html).toContain('aria-current="page"');
    expect(html).not.toContain('data-tab-kind="browser"');
    expect(html).not.toContain('aria-label="New tab"');
    expect(workspaceItems(snapshot, 'rail.example')).toEqual([]);
  }
});

test('agent and browser rows retain order, selection, icons and activity in both widths', () => {
  const snapshot = fixture();
  const [active, idle] = snapshot.tasks;
  active.status = 'Running';
  idle.status = 'Completed';
  idle.isBusy = false;
  idle.hasUnreadCompletion = true;
  idle.unreadCompletionID = 'finished-turn';
  snapshot.primaryBrowserID = undefined;
  snapshot.selectedTaskID = idle.id;
  snapshot.workspaceOrder!.push({kind:'agent', id:idle.id});
  snapshot.agentNames = {[idle.id]: 'Release agent'};
  for (const compact of [false, true]) {
    snapshot.isTaskSidebarCollapsed = compact;
    const items = workspaceItems(snapshot, '');
    expect(items.map(item => item.ref)).toEqual(snapshot.workspaceOrder!);
    expect(items.at(-1)?.title).toBe('Release agent');
    const render = () => renderToStaticMarkup(h(WorkspaceSidebar, {snapshot, search:'', setSearch:()=>{}, nativeHost:true, post:()=>{}})).html;
    snapshot.primaryBrowserID = undefined;
    snapshot.canViewConversation = true;
    const rows = render();
    expect(rows.match(/class="agent-status-icon"/g)).toHaveLength(2);
    expect(rows.match(/data-agent-status="working"/g)).toHaveLength(1);
    expect(rows).not.toContain('Ready to read');
    expect(rows).not.toContain('task-row-unread');
    expect(rows.match(/aria-current="page"/g)).toHaveLength(1);
    snapshot.canViewConversation = false;
    expect(render()).toContain('aria-label="Release agent — Ready to read"');
    snapshot.canViewConversation = true;
    snapshot.primaryBrowserID = snapshot.workspaceBrowsers![0].id;
    const behindBrowser = render();
    expect(behindBrowser).toContain('aria-label="Release agent — Ready to read"');
    expect(behindBrowser.match(/task-row-unread/g)).toHaveLength(1);
  }
});

test('tab filtering lives below the title bar and keeps a compact search button', () => {
  const render = (nativeSidebarControls: boolean, isTaskSidebarCollapsed = false, search = '') =>
    renderToStaticMarkup(h(WorkspaceSidebar, {
      snapshot: { ...fixture(), mixesBrowserTabsInSidebar: false, nativeSidebarControls, isTaskSidebarCollapsed },
      nativeHost: true, search, setSearch: () => {}, post: () => {},
    })).html;
  for (const nativeControls of [false, true]) {
    const html = render(nativeControls);
    const titlebar = html.split('class="window-drag-strip"')[1].split('</div>')[0];
    expect(titlebar).not.toContain('id="task-search"');
    expect(html.indexOf('class="sidebar-search-row"')).toBeGreaterThan(html.indexOf('class="window-drag-strip"'));
    expect(titlebar.includes('aria-label="Collapse chat sidebar"')).toBe(!nativeControls);
    expect(render(nativeControls, true)).toContain('aria-label="Search chats"');
    expect(html.match(/id="task-search"/g) ?? []).toHaveLength(1);
    expect(html).not.toContain('aria-label="Clear search"');
    expect(render(nativeControls, false, 'Trip')).toContain('aria-label="Clear search"');
    expect(render(nativeControls, true)).not.toContain('id="task-search"');
  }
});

test('hover reveals the open tabs and their close buttons without changing the pinned preference', () => {
  const snapshot = { ...fixture(), isTaskSidebarCollapsed: true };
  const render = (isTaskSidebarPeeked: boolean) => renderToStaticMarkup(h(WorkspaceSidebar, {
    snapshot: { ...snapshot, isTaskSidebarPeeked }, search: '', setSearch: () => {}, post: () => {}, nativeHost: true,
  })).html;
  expect(render(false)).not.toContain('class="workspace-close"');
  expect(render(true)).toContain('aria-label="Close tab: Trips"');
  expect(render(true)).toContain('id="task-search"');
  expect(render(false)).toContain('agent-rail');
});
