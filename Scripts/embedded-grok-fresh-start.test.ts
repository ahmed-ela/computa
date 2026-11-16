import { describe, expect, test } from 'bun:test';
import { grokFixture, grokGeneration, grokOwner } from './embedded-grok-adapter-fixture';

const saved = 'https://grok.com/c/85c6f8dc-ab95-4cf9-aab6-667c9547fae2';
const rid = '70b6c6e4-a6d3-48cd-a1e7-967e8d21d250';
const token = 'cb711c7f-7128-4c64-803f-86b9938f12ef';
function setup(expanded = false) {
  const f = grokFixture(); f.document.URL = saved; f.f.installFreshStart(expanded);
  f.f.appendUser('Existing saved transcript stays outside inference.');
  const run = (suffix = 'Inspect', overrides: any = {}) => f.run('grokFreshStart' + suffix,
    { allowGrokFreshStart: true, grokFreshStartToken: token, ...overrides }, false);
  return { ...f, fresh: run };
}
const stage = (value: string) => ({ grokFreshStart: { version: 1, stage: value } });

describe('Grok navigation-only fresh-start preparation', () => {
  test('one observed sidebar expansion and New Chat reaches empty root before normal Private setup', async () => {
    const f = setup(), oldBody = f.f.userBody;
    expect(await f.fresh()).toEqual(stage('sidebar_closed'));
    expect(await f.fresh('ExpandSidebar')).toEqual(stage('sidebar_requested'));
    expect(await f.fresh()).toEqual(stage('new_chat_ready'));
    expect(await f.fresh('NewChat')).toEqual(stage('new_chat_requested'));
    expect(f.document.URL).toBe('https://grok.com/');
    expect(await f.fresh('Verify')).toEqual(stage('root_observed'));
    expect(oldBody.textContent).toBe('Existing saved transcript stays outside inference.');
    expect(f.f.savedMessages.contains(oldBody)).toBe(true);
    expect([f.f.sidebarCount, f.f.newChatCount, f.f.otherNewChat.clicks]).toEqual([1, 1, 0]);
    expect(f.f.sendCount + f.f.privateCount + f.f.pickerOpens).toBe(0);
    expect(await f.run('inspect', { allowGrokInitialHydration: true })).toMatchObject({ composer: true, userCount: 0, temporary: false });
    // The existing inference adapter still performs its full model/Private,
    // exact body and completion proof after the navigation-only preparation.
    expect(await f.submit()).toMatchObject({ submitted: true });
    expect(await f.run('inspect')).toMatchObject({ answerComplete: true });
  });

  test('an already open sidebar chooses only the observed primary shortcut row', async () => {
    const f = setup(true);
    expect(await f.fresh()).toEqual(stage('new_chat_ready'));
    expect(await f.fresh('NewChat')).toEqual(stage('new_chat_requested'));
    expect(await f.fresh('Verify')).toEqual(stage('root_observed'));
    expect([f.f.sidebarCount, f.f.newChatCount, f.f.otherNewChat.clicks]).toEqual([0, 1, 0]);
  });

  test('missing controls and plain textarea hydration grant no action or inference authority', async () => {
    for (const missing of ['editor', 'sidebarToggle']) {
      const f = setup(), node = f.f[missing], parent = node.parentElement; node.remove();
      expect(await f.fresh()).toEqual(stage('pending'));
      node.connected = true; parent.append(node);
      expect(await f.fresh()).toEqual(stage('sidebar_closed'));
      expect(f.f.sidebarCount + f.f.newChatCount + f.f.sendCount).toBe(0);
    }
    const f = setup(); f.f.editor.remove(); const textarea = new f.Node('TEXTAREA'); f.f.form.append(textarea);
    expect(await f.fresh()).toEqual(stage('pending'));
    expect(f.f.sidebarCount + f.f.newChatCount + f.f.sendCount).toBe(0);
  });

  test('existing message, unknown text-field, hidden textarea and file drafts are preserved', async () => {
    for (const change of [
      (f: ReturnType<typeof setup>) => { f.f.editor.textContent = 'existing draft'; },
      (f: ReturnType<typeof setup>) => { f.f.editor.textContent = ' \n\t'; },
      (f: ReturnType<typeof setup>) => { const n: any = new f.Node('INPUT', { type: 'text' }); n.value = 'custom onboarding answer'; f.body.append(n); },
      (f: ReturnType<typeof setup>) => { const n: any = new f.Node('TEXTAREA', { hidden: '' }); n.value = 'invisible saved draft'; f.body.append(n); },
      (f: ReturnType<typeof setup>) => { const n: any = new f.Node('INPUT', { type: 'text' }); n.value = '   '; f.body.append(n); },
      (f: ReturnType<typeof setup>) => { const n: any = new f.Node('INPUT', { type: 'file' }); n.files = [{}]; f.body.append(n); },
    ]) {
      const f = setup(); change(f); const before = f.body.textContent;
      expect(await f.fresh()).toMatchObject({ error: 'composer_not_empty' });
      expect(f.body.textContent).toBe(before); expect(f.document.URL).toBe(saved);
      expect(f.f.sidebarCount + f.f.newChatCount + f.f.sendCount).toBe(0);
    }
  });

  test('an empty BR placeholder stays empty, while exact enabled composer Send protects a possible non-text draft', async () => {
    const blank = setup(true); blank.f.editor.append(new blank.Node('P')); blank.f.editor.children[0].append(new blank.Node('BR'));
    blank.body.append(new blank.Node('BUTTON', { type: 'submit', 'aria-label': 'Send' }, 'Send'));
    expect(await blank.fresh()).toEqual(stage('new_chat_ready'));
    const draft = setup(true);
    for (const [name, value] of Object.entries({ type: 'submit', 'aria-label': 'Send', 'data-testid': 'chat-submit', 'data-composer-action': 'send' }))
      draft.f.send.setAttribute(name, value);
    expect(await draft.fresh()).toMatchObject({ error: 'composer_not_empty' });
    expect(draft.f.newChatCount + draft.f.sidebarCount + draft.f.sendCount).toBe(0);
  });

  test('draft appearing between inspection and action blocks navigation', async () => {
    for (const suffix of ['ExpandSidebar', 'NewChat']) {
      const f = setup(suffix === 'NewChat'); await f.fresh(); f.f.editor.textContent = 'new concurrent draft';
      expect(await f.fresh(suffix)).toMatchObject({ error: 'composer_not_empty' });
      expect(f.f.editor.textContent).toBe('new concurrent draft'); expect(f.f.sidebarCount + f.f.newChatCount).toBe(0);
    }
  });

  test('duplicate, malformed and replaced navigation controls fail without clicks', async () => {
    for (const change of [
      (f: ReturnType<typeof setup>) => { f.body.append(f.f.sidebar.cloneNode(true)); },
      (f: ReturnType<typeof setup>) => { f.f.sidebar.append(f.f.newChat.cloneNode(true)); },
      (f: ReturnType<typeof setup>) => { f.f.newChat.setAttribute('type', 'submit'); },
      (f: ReturnType<typeof setup>) => { f.f.newChat.querySelector('[data-sidebar-item-label]').textContent = 'Delete chat'; },
      (f: ReturnType<typeof setup>) => { f.f.sidebarToggle.setAttribute('aria-keyshortcuts', 'Other'); },
    ]) {
      const f = setup(true); change(f);
      expect((await f.fresh()).error).toBeDefined(); expect(f.f.sidebarCount + f.f.newChatCount).toBe(0);
    }
    const f = setup(true); await f.fresh(); const replacement = f.f.newChat.cloneNode(true); f.f.newChat.remove(); f.f.sidebar.append(replacement);
    expect((await f.fresh('NewChat')).error).toBeDefined(); expect(f.f.newChatCount).toBe(0);
  });

  test('a known blocked target grants only finite negative readiness until it is hittable', async () => {
    for (const expanded of [false, true]) {
      const f = setup(expanded), target = expanded ? 'new_chat' : 'toggle'; f.blockHit(true);
      for (let read = 0; read < 3; read++) {
        expect(await f.fresh()).toEqual({ grokFreshStart: { version: 1, stage: 'pending', readiness: { target, reason: 'occluded' } } });
        expect(f.world.__computaGrokFreshStartV1.readyElement).toBeNull();
        expect(f.f.sidebarCount + f.f.newChatCount + f.f.sendCount).toBe(0);
      }
      f.blockHit(false);
      expect(await f.fresh()).toEqual(stage(expanded ? 'new_chat_ready' : 'sidebar_closed'));
      if (!expanded) {
        expect(await f.fresh('ExpandSidebar')).toEqual(stage('sidebar_requested'));
        expect(await f.fresh()).toEqual(stage('new_chat_ready'));
      }
      expect(await f.fresh('NewChat')).toEqual(stage('new_chat_requested'));
      expect(await f.fresh('Verify')).toEqual(stage('root_observed'));
      expect([f.f.sidebarCount, f.f.newChatCount, f.f.otherNewChat.clicks]).toEqual([expanded ? 0 : 1, 1, 0]);
    }
  });

  test('disabled and invalid or offscreen geometry remain pending without becoming ready', async () => {
    for (const [reason, change] of [
      ['disabled', (node: any) => { node.disabled = true; }],
      ['invalid_geometry', (node: any) => { node.rect.width = 0; }],
      ['outside_viewport', (node: any) => { node.rect.left = 2000; }],
    ] as const) {
      for (const expanded of [false, true]) {
        const f = setup(expanded); change(expanded ? f.f.newChat : f.f.sidebarToggle);
        expect(await f.fresh()).toEqual({ grokFreshStart: { version: 1, stage: 'pending', readiness: { target: expanded ? 'new_chat' : 'toggle', reason } } });
        expect(f.world.__computaGrokFreshStartV1.readyElement).toBeNull();
        expect(f.f.newChatCount + f.f.sidebarCount).toBe(0);
      }
    }
  });

  test('only the pending target or its ancestors can cause one CSS-completion wakeup', async () => {
    for (const type of ['transitionend', 'transitioncancel', 'animationend', 'animationcancel']) {
      for (const ancestor of [false, true]) {
        const f = setup(true); f.blockHit(true); await f.fresh();
        const unrelated = new f.Node('DIV'); f.body.append(unrelated);
        expect(f.document.layoutListenerCount()).toBe(4);
        f.document.emitLayout(type, unrelated);
        expect(f.posted).toEqual([]); expect(f.document.layoutListenerCount()).toBe(4);
        f.document.emitLayout(type, ancestor ? f.f.sidebar : f.f.newChat);
        expect(f.posted).toEqual([{ ownerToken: grokOwner, kind: 'dom_changed' }]);
        expect(f.document.layoutListenerCount()).toBe(0);
        f.document.emitLayout(type, f.f.newChat);
        expect(f.posted).toHaveLength(1); expect(f.f.sidebarCount + f.f.newChatCount + f.f.sendCount).toBe(0);
      }
    }
  });

  test('stale layout events cannot wake another document, owner, route or completed preparation', async () => {
    for (const change of [
      (f: ReturnType<typeof setup>) => { f.world.__computaModelOwner = token; },
      (f: ReturnType<typeof setup>) => { f.world.__computaGrokFreshStartV1.generation = token; },
      (f: ReturnType<typeof setup>) => { f.world.__computaGrokFreshStartV1.document = {}; },
      (f: ReturnType<typeof setup>) => { f.document.URL += '?rid=' + rid; },
      (f: ReturnType<typeof setup>) => { f.world.__computaGrokFreshStartV1.terminal = true; },
      (f: ReturnType<typeof setup>) => { f.world.__computaGrokFreshStartV1.verified = true; },
      (f: ReturnType<typeof setup>) => { f.world.__computaGrokFreshStartV1.newChat = true; },
      (f: ReturnType<typeof setup>) => { f.f.newChat.remove(); },
    ]) {
      const f = setup(true); f.blockHit(true); await f.fresh(); change(f);
      f.document.emitLayout('transitionend', f.f.sidebar);
      expect(f.posted).toEqual([]); expect(f.document.layoutListenerCount()).toBe(0);
      expect(f.f.sidebarCount + f.f.newChatCount + f.f.sendCount).toBe(0);
    }
  });

  test('new reads, action attempts, verification and failures remove prior layout listeners', async () => {
    const ready = setup(true); ready.blockHit(true); await ready.fresh();
    await ready.fresh(); expect(ready.document.layoutListenerCount()).toBe(4);
    ready.blockHit(false); expect(await ready.fresh()).toEqual(stage('new_chat_ready'));
    expect(ready.document.layoutListenerCount()).toBe(0);
    for (const action of ['NewChat', 'Verify', 'Invalid']) {
      const f = setup(true); f.blockHit(true); await f.fresh();
      expect((await f.fresh(action)).error).toBeDefined(); expect(f.document.layoutListenerCount()).toBe(0);
    }
    const invalid = setup(true); invalid.blockHit(true); await invalid.fresh(); invalid.f.newChat.setAttribute('type', 'submit');
    expect((await invalid.fresh()).error).toBeDefined(); expect(invalid.document.layoutListenerCount()).toBe(0);
  });

  test('an occlusion appearing after readiness rejects the claimed action without retry', async () => {
    for (const expanded of [false, true]) {
      const f = setup(expanded), action = expanded ? 'NewChat' : 'ExpandSidebar'; await f.fresh(); f.blockHit(true);
      expect(await f.fresh(action)).toMatchObject({ error: 'document_changed', detail: 'fresh_start_action_unverified' });
      f.blockHit(false);
      expect((await f.fresh(action)).error).toBeDefined();
      expect(f.f.sidebarCount + f.f.newChatCount + f.f.sendCount).toBe(0);
    }
  });

  test('New Chat still requires the sidebar toggle to remain enabled at action time', async () => {
    for (const change of [
      (node: any) => { node.disabled = true; },
      (node: any) => { node.setAttribute('aria-disabled', 'true'); },
      (node: any) => { node.setAttribute('hidden', ''); },
    ]) {
      const f = setup(true); expect(await f.fresh()).toEqual(stage('new_chat_ready')); change(f.f.sidebarToggle);
      expect(await f.fresh('NewChat')).toMatchObject({ error: 'document_changed', detail: 'fresh_start_action_unverified' });
      expect(f.f.sidebarCount + f.f.newChatCount + f.f.sendCount).toBe(0);
    }
  });

  test('failed or ambiguous clicks cannot be replayed or repaired into a second navigation', async () => {
    const sidebar = setup(); sidebar.f.ignoreSidebar = true;
    await sidebar.fresh(); expect(await sidebar.fresh('ExpandSidebar')).toEqual(stage('sidebar_requested'));
    expect(await sidebar.fresh()).toEqual(stage('pending'));
    expect((await sidebar.fresh('ExpandSidebar')).error).toBeDefined(); expect(sidebar.f.sidebarCount).toBe(1);
    const next = setup(true); next.f.ignoreNewChat = true;
    await next.fresh(); expect(await next.fresh('NewChat')).toEqual(stage('new_chat_requested'));
    expect(await next.fresh('Verify')).toEqual(stage('pending'));
    expect((await next.fresh('NewChat')).error).toBeDefined(); expect(next.f.newChatCount).toBe(1);
    expect((await next.fresh('Inspect')).error).toBeDefined();
  });

  test('native grant, owner, generation, token and initial action are mandatory', async () => {
    for (const overrides of [{ allowGrokFreshStart: false }, { grokFreshStartToken: 'invalid' }, { bindOwner: false }]) {
      const f = setup(); expect((await f.fresh('Inspect', overrides)).error).toBeDefined(); expect(f.f.newChatCount).toBe(0);
    }
    for (const overrides of [{ ownerToken: token }, { documentGeneration: grokOwner }, { grokFreshStartToken: grokGeneration }]) {
      const f = setup(); await f.fresh(); expect((await f.fresh('ExpandSidebar', overrides)).error).toBeDefined();
      expect(f.f.sidebarCount).toBe(0);
    }
    const f = setup(true); expect((await f.fresh('NewChat')).error).toBeDefined(); expect(f.f.newChatCount).toBe(0);
  });

  test('saved-route query hydration is same-conversation, one-way and pinned', async () => {
    const f = setup(true); expect(await f.fresh()).toEqual(stage('new_chat_ready'));
    f.document.URL = saved + '?rid=' + rid;
    expect(await f.fresh()).toEqual(stage('new_chat_ready'));
    expect(await f.fresh('NewChat')).toEqual(stage('new_chat_requested'));
    expect(await f.fresh('Verify')).toEqual(stage('root_observed'));
    for (const url of [saved + '?other=1', saved + '?rid=' + rid + '&x=1', saved + '#fragment', saved + '/', saved + '\n',
      saved.replace('85c6f8dc', '85C6F8DC'), 'https://grok.com/', 'https://other.test/c/' + rid]) {
      const bad = setup(); bad.document.URL = url; expect((await bad.fresh()).error).toBeDefined();
      expect(bad.f.newChatCount + bad.f.sidebarCount).toBe(0);
    }
    for (const url of [saved, saved + '?rid=' + token, saved.replace('85c6f8dc', '95c6f8dc') + '?rid=' + rid]) {
      const bad = setup(); bad.document.URL += '?rid=' + rid; await bad.fresh(); bad.document.URL = url;
      expect((await bad.fresh()).error).toBeDefined(); expect(bad.f.newChatCount + bad.f.sidebarCount).toBe(0);
    }
  });

  test('root verification requires the claimed SPA transition and full empty-root controls', async () => {
    const unclaimed = setup(); await unclaimed.fresh(); unclaimed.document.URL = 'https://grok.com/';
    expect((await unclaimed.fresh('Verify')).error).toBeDefined();
    for (const change of [
      (f: ReturnType<typeof setup>) => { f.f.appendUser('unexpected transcript'); },
      (f: ReturnType<typeof setup>) => { f.f.editor.textContent = 'restored draft'; },
      (f: ReturnType<typeof setup>) => { f.f.privateToggle.setAttribute('aria-pressed', 'true'); },
      (f: ReturnType<typeof setup>) => { f.f.trigger.setAttribute('aria-expanded', 'true'); },
      (f: ReturnType<typeof setup>) => { f.document.URL += '?private=true'; },
    ]) {
      const f = setup(true); await f.fresh(); await f.fresh('NewChat'); change(f);
      expect((await f.fresh('Verify')).error).toBeDefined(); expect(f.f.privateCount + f.f.sendCount + f.f.pickerOpens).toBe(0);
    }
    const missing = setup(true); await missing.fresh(); await missing.fresh('NewChat'); missing.f.privateToggle.remove();
    expect(await missing.fresh('Verify')).toEqual(stage('pending'));
    expect(await missing.run('inspect')).toMatchObject({ error: 'document_changed', detail: 'fresh_start_unverified' });
  });

  test('a positive root read discarded before native binding is not an action claim', async () => {
    const f = grokFixture();
    expect(await f.run('inspect', { allowGrokInitialHydration: true })).toMatchObject({ composer: true, temporary: false });
    const state = f.world.__computaGrokPrivateSessionV1;
    expect(state.initialHydrationClosed).toBe(true);
    f.document.URL = saved; f.f.installFreshStart(true);
    const run = (suffix: string) => f.run('grokFreshStart' + suffix, { allowGrokFreshStart: true, grokFreshStartToken: token }, false);
    expect(await run('Inspect')).toEqual(stage('new_chat_ready'));
    expect(await run('NewChat')).toEqual(stage('new_chat_requested'));
    expect(await run('Verify')).toEqual(stage('root_observed'));
    expect(state.initialHydrationClosed).toBe(true);
    expect(f.f.privateCount + f.f.sendCount + f.f.pickerOpens).toBe(0);
    f.f.editor.remove();
    const lost = await f.run('inspect', { allowGrokInitialHydration: true });
    expect(lost).toMatchObject({ error: 'composer_unavailable' });
    expect(lost.grokInitialHydrationPending).toBeUndefined();
  });

  test('normal inference never accepts a saved route or permits recovery after actual claims', async () => {
    const savedPage = setup(); expect(await savedPage.run('inspect')).toMatchObject({ error: 'document_changed' });
    for (const setupPrior of [
      async (f: ReturnType<typeof grokFixture>) => f.select(),
      async (f: ReturnType<typeof grokFixture>) => f.run('enableTemporary'),
    ]) {
      const f = grokFixture(); await setupPrior(f); f.document.URL = saved; f.f.installFreshStart(true);
      expect(await f.run('grokFreshStartInspect', { allowGrokFreshStart: true, grokFreshStartToken: token }, false))
        .toMatchObject({ error: 'document_changed', detail: 'fresh_start_already_bound' });
      expect(f.f.newChatCount).toBe(0);
    }
  });
});
