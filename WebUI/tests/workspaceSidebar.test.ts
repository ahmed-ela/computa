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
test('open tabs keep their order and closed chats follow once, even with overlapping IDs', () => {
  const snapshot = fixture();
  const stale = { id: snapshot.tasks[0].id, title: 'Old title', workspace: '/', updatedAt: 0 };
  const older = { id: 'oldest', title: 'Saved conversation', workspace: '/old-project', updatedAt: 0 };
  snapshot.savedChats = [stale, older];
  const items = workspaceItems(snapshot, '');
  expect(items.filter(item => item.open).map(item => item.ref)).toEqual(snapshot.workspaceOrder!);
  expect(items.filter(item => !item.open).map(item => item.ref.id)).toEqual([...snapshot.tasks.slice(1).sort((a,b) => b.updatedAt - a.updatedAt).map(t => t.id), older.id]);
  expect(workspaceItems(snapshot, 'rail.example').map(item => item.title)).toEqual(['Trips']);
  expect(workspaceItems(snapshot, 'OLD-project').map(item => item.title)).toEqual([older.title]);
  expect(workspaceItems({ ...snapshot, workspaceOrder: [] }, '').map(item => item.ref.id))
    .toEqual([...snapshot.tasks.slice().sort((a,b) => b.updatedAt - a.updatedAt).map(task => task.id), older.id]);
});
test('sidebar uses the site icon or hostname initial in both sizes; an empty tab uses the globe', () => {
  for (const collapsed of [true,false]) {
    const snapshot = { ...fixture(), isTaskSidebarCollapsed:collapsed };
    const render = () => renderToStaticMarkup(h(WorkspaceSidebar, {snapshot,search:'',setSearch:()=>{},focusSearch:()=>{},post:()=>{},nativeHost:true})).html;
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
test('a matching browser tab stays available at either width in mixed mode', () => {
  for (const isTaskSidebarCollapsed of [false, true]) {
    const html = renderToStaticMarkup(h(WorkspaceSidebar, {
      snapshot: { ...fixture(), isTaskSidebarCollapsed }, search: 'rail.example',
      setSearch: () => {}, focusSearch: () => {}, nativeHost: true, post: () => {},
    })).html;
    expect(html.match(/data-tab-kind=/g)?.length).toBe(1);
    expect(html).toContain('aria-label="Trips"');
  }
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
      snapshot, search: '', setSearch: () => {}, focusSearch: () => {}, nativeHost: true, post: () => {},
    })).html;
    expect(html).toContain('aria-label="Chats"');
    expect(html).not.toContain('Show chat history');
    expect(html).toContain('aria-label="New agent"');
    expect(html).toContain('data-tab-kind="agent"');
    if (!isTaskSidebarCollapsed) expect(html).toContain('aria-current="page"');
    expect(html).not.toContain('data-tab-kind="browser"');
    expect(html).not.toContain('aria-label="New browser tab"');
    expect(workspaceItems(snapshot, 'rail.example')).toEqual([]);
  }
});

test('expanded chats have titles and activity indicators; the rail contains only active chats', () => {
  const snapshot = fixture();
  snapshot.mixesBrowserTabsInSidebar = false;
  snapshot.tasks = ['Running', 'Waiting', 'Completed', 'Failed', 'Draft'].map((status, index) => ({
    ...snapshot.tasks[0], id: String(index), title: 'Chat ' + index, status,
    isBusy: index === 1, hasUnreadCompletion: index === 2,
  }));
  snapshot.workspaceOrder = [];
  snapshot.savedChats = [{ id: 'saved', title: 'Saved chat', workspace: '/', updatedAt: 0 }];
  const rows = () => renderToStaticMarkup(h(WorkspaceSidebar, {
    snapshot, search: '', setSearch: () => {}, focusSearch: () => {}, nativeHost: true, post: () => {},
  })).html.split('<nav').at(-1)!;
  const expanded = rows();
  expect(expanded.match(/class="task-row-title"/g)).toHaveLength(6);
  expect(expanded).not.toContain('<svg');
  expect(expanded).toContain('task-row-unread');
  snapshot.isTaskSidebarCollapsed = true;
  const collapsed = rows();
  expect(workspaceItems(snapshot, '').map(item => item.ref.id)).toEqual(['0', '1']);
  expect(collapsed.match(/data-tab-kind="agent"/g)).toHaveLength(2);
  expect(collapsed.match(/class="agent-status-icon"/g)).toHaveLength(2);
  expect(collapsed).toContain('aria-label="Chat 1 — Working"');
  snapshot.tasks = snapshot.tasks.slice(2);
  expect(rows()).not.toContain('data-tab-kind="agent"');
});
