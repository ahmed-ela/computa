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
test('one order supports overlapping typed IDs, mixed search and separate chat history', () => {
  const snapshot = fixture();
  expect(workspaceItems(snapshot,false,'').map(item => item.ref)).toEqual(snapshot.workspaceOrder!);
  expect(workspaceItems(snapshot,false,'rail.example').map(item => item.title)).toEqual(['Trips']);
  expect(workspaceItems(snapshot,true,'').map(item => item.ref.id)).toEqual(snapshot.tasks.slice(1).map(t => t.id));
  expect(workspaceItems(snapshot,true,'rail.example')).toEqual([]);
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
test('collapsing a filtered list keeps the same tabs in their slots', () => {
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
    expect(html).toContain('aria-label="Open chats"');
    expect(html).toContain('aria-label="New agent"');
    expect(html).toContain('data-tab-kind="agent"');
    expect(html).toContain('aria-current="page"');
    expect(html).not.toContain('data-tab-kind="browser"');
    expect(html).not.toContain('aria-label="New browser tab"');
    expect(workspaceItems(snapshot, false, 'rail.example')).toEqual([]);
  }
});
