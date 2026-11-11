import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { adapterFixture, adapterSource, canonical, generation, instant, marker, prompt, provisional, submissionFingerprint } from './embedded-kimi-adapter-fixture';

describe('Kimi saved-conversation adapter', () => {
  test('standalone resource embeds the audited core exactly and no other provider adapter', () => {
    const core = readFileSync(new URL('./embedded-provider-core.js', import.meta.url), 'utf8');
    expect(adapterSource.startsWith(core + '\n')).toBe(true);
    expect(adapterSource).not.toContain('claude.ai');
    expect(adapterSource).not.toContain('chat.groq.com');
    expect(adapterSource).not.toContain('websiteChat');
  });

  test('a not-yet-mounted fresh page emits only pending metadata then discovers the observed choice', async () => {
    const f = adapterFixture();
    const controls = [f.scope, f.send, f.trigger];
    controls.forEach(f.remove);
    const pending = { pending: true, sessionLifecycle: 'saved_conversation_delete', temporary: false, composer: false };
    for (let read = 0; read < 3; read++) expect(await f.run()).toEqual(pending);
    expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
    expect(f.trigger.clicks).toBe(0);
    for (const node of controls) { node.connected = true; f.body.append(node); }
    const ready = await f.run();
    expect(ready.pending).toBeUndefined(); expect(ready.composer).toBe(true);
    expect(ready.modelEvidence).toBeNull(); expect(ready.firstUserVerified).toBe(false);
    let discovered: any;
    for (let read = 0; read < 4; read++) {
      discovered = await f.run('discoverModels', { expectedModelChoice: undefined });
      if (!discovered.pending) break;
    }
    expect(discovered.modelChoices).toEqual([instant]); expect(discovered.error).toBeUndefined();
    expect(f.trigger.clicks).toBe(2); expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
  });

  test('partial initial controls may hydrate without publishing partial ownership or model evidence', async () => {
    for (const missing of ['editor', 'send', 'trigger', 'triggerName'] as const) {
      const f = adapterFixture(), node = f[missing], parent = node.parentElement!;
      f.remove(node);
      expect(await f.run()).toEqual({ pending: true, sessionLifecycle: 'saved_conversation_delete', temporary: false, composer: false });
      node.connected = true; parent.append(node);
      expect((await f.run()).composer).toBe(true); expect(f.trigger.clicks).toBe(0);
      expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
    }
  });

  test('attribute-only mounting wakes the owned initial read without granting any action authority', async () => {
    const f = adapterFixture(); f.editor.removeAttribute('role');
    expect((await f.run()).pending).toBe(true); expect(f.signals).toHaveLength(0);
    for (const attribute of ['role', 'contenteditable', 'data-lexical-editor', 'data-testid', 'aria-haspopup', 'id'])
      expect(f.observers[0].attributes).toContain(attribute);
    f.editor.setAttribute('role', 'textbox'); f.emitAttribute('role');
    expect(f.signals).toEqual([{ ownerToken: '9fe25e48-2e0b-46cb-84f7-7b4f32e1794f', kind: 'dom_changed' }]);
    expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 }); expect(f.trigger.clicks).toBe(0);
    const ready = await f.run(); expect(ready.composer).toBe(true); expect(ready.modelEvidence).toBeNull();
    f.world.__computaModelOwner = marker; f.emitAttribute('data-lexical-editor');
    expect(f.signals).toHaveLength(1);
    expect((await f.run()).detail).toBe('owner_token'); expect(f.counts().sends).toBe(0);
  });

  test('initial waiting rejects duplicates, hidden controls, drafts and any transcript instead of treating them as loading', async () => {
    for (const mutation of ['duplicate-editor', 'duplicate-send', 'duplicate-trigger', 'duplicate-label', 'hidden', 'draft', 'transcript']) {
      const f = adapterFixture();
      if (mutation === 'duplicate-editor') f.scope.append(f.editor.cloneNode(true));
      else if (mutation === 'duplicate-send') f.body.append(f.send.cloneNode(true));
      else if (mutation === 'duplicate-trigger') f.body.append(f.trigger.cloneNode(true));
      else if (mutation === 'duplicate-label') f.triggerName.parentElement!.append(f.triggerName.cloneNode(true));
      else if (mutation === 'hidden') f.editor.setAttribute('hidden', '');
      else if (mutation === 'draft') f.setDraft('A prior unsent draft');
      else f.installTranscript();
      // A second missing control must not hide the invalid existing state.
      if (!['duplicate-trigger', 'duplicate-label'].includes(mutation)) f.remove(f.trigger);
      else f.remove(f.send);
      const rejected = await f.run(); expect(rejected.error).toBeDefined(); expect(rejected.pending).toBeUndefined();
      expect((await f.run()).detail).toBe('terminal_operation');
      expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 }); expect(f.trigger.clicks).toBe(0);
    }
  });

  test('initial waiting pins every seen control and never accepts replacement as late mounting', async () => {
    for (const control of ['editor', 'send', 'trigger', 'triggerName'] as const) {
      const f = adapterFixture(), missing = control === 'send' ? f.editor : f.send;
      f.remove(missing); expect((await f.run()).pending).toBe(true);
      const node = f[control], parent = node.parentElement!, replacement = node.cloneNode(true);
      f.remove(node); parent.append(replacement);
      expect((await f.run()).error).toBe('document_changed');
      f.remove(replacement); node.connected = true; parent.append(node);
      expect((await f.run()).detail).toBe('terminal_operation'); expect(f.counts().sends).toBe(0);
    }
  });

  test('a complete initial read or a claimed model operation cannot revert to hydration', async () => {
    for (const phase of ['read', 'model-open', 'selected', 'prepared']) {
      const f = adapterFixture();
      if (phase === 'read') expect((await f.run()).composer).toBe(true);
      else if (phase === 'model-open') expect((await f.run('selectModel')).pending).toBe(true);
      else { await f.select(); if (phase === 'prepared') await f.run('prepare'); }
      f.remove(f.editor);
      const rejected = await f.run(); expect(rejected.error).toBe('document_changed'); expect(rejected.pending).toBeUndefined();
      f.editor.connected = true; f.scope.append(f.editor);
      expect((await f.run()).detail).toBe('terminal_operation'); expect(f.counts().sends).toBe(0);
    }
  });

  test('waiting cannot authorize mutation or bypass changed owner, generation or route', async () => {
    for (const action of ['discoverModels', 'selectModel', 'prepare', 'insert', 'sendReady', 'submit']) {
      const f = adapterFixture(); f.remove(f.editor);
      expect((await f.run()).pending).toBe(true);
      expect((await f.run(action)).error).toBeDefined(); expect(f.counts().sends).toBe(0); expect(f.trigger.clicks).toBe(0);
    }
    for (const mutation of ['owner', 'generation', 'route']) {
      const f = adapterFixture(); f.remove(f.editor); expect((await f.run()).pending).toBe(true);
      const overrides = mutation === 'owner' ? { ownerToken: marker }
        : mutation === 'generation' ? { documentGeneration: marker } : {};
      if (mutation === 'route') f.document.URL = canonical;
      const rejected = await f.run('inspect', overrides);
      expect(rejected.error).toBeDefined(); expect(rejected.pending).toBeUndefined(); expect(f.counts().sends).toBe(0);
    }
  });

  test('unexpected adapter exceptions expose a fixed diagnostic enum without exception text', async () => {
    const f = adapterFixture();
    Object.defineProperty(f.editor, 'childNodes', { get() { throw new Error('Synthetic private value must not escape'); } });
    expect(await f.run()).toEqual({ error: 'document_changed', detail: 'unexpected_exception' });
    expect((await f.run()).detail).toBe('terminal_operation');
  });

  test('observed selected model uses one open/close cycle and exports no guessed More model', async () => {
    const f = adapterFixture(), selected = await f.select();
    expect(selected.selected).toBe(true); expect(selected.modelEvidence.selected).toEqual(instant);
    expect(selected.modelChoices).toEqual([instant]);
    expect(selected.discoveryComplete).toBe(false);
    expect(f.trigger.clicks).toBe(2); expect(f.options.reduce((n, row) => n + row.clicks, 0)).toBe(0);
    await f.select(); expect(f.trigger.clicks).toBe(2);
    expect(adapterSource).not.toContain('k28-instant'); expect(adapterSource).not.toContain('K3.1 Pro');
  });

  test('switch from an observed agent selection to Instant clicks once then reopens to prove checked selection', async () => {
    const f = adapterFixture(); f.triggerName.text = 'K3.1 Pro';
    f.options[0].setAttribute('aria-checked', 'true'); f.options[2].setAttribute('aria-checked', 'false');
    const selected = await f.select();
    expect(selected.modelEvidence.selected).toEqual(instant); expect(f.options[2].clicks).toBe(1);
    expect(f.trigger.clicks).toBe(3); expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
    const mismatch = await f.run('verifyModel', { expectedModelChoice: { key: 'k3d1-agent', label: 'K3.1 Pro' } });
    expect(mismatch.error).toBe('model_mismatch');
  });

  async function discover(f: ReturnType<typeof adapterFixture>) {
    for (let attempt = 0; attempt < 8; attempt++) {
      const result = await f.run('discoverModels', { expectedModelChoice: undefined });
      if (result.error || result.selected) return result;
    }
    throw new Error('Bounded nested discovery did not settle');
  }

  test('nested current K3 is verified without being exposed or aliased to a top-level model', async () => {
    const f = adapterFixture({ nestedSelected: true });
    const result = await discover(f);
    expect(result.modelChoices).toEqual([instant]);
    expect(result.modelEvidence.selected).toEqual({ key: 'k3-agent', label: 'K3' });
    expect(f.trigger.clicks).toBe(2); expect(f.more.events.length).toBe(8);
    expect(f.options.reduce((sum, row) => sum + row.clicks, 0)).toBe(0);
    expect(f.moreOption.clicks).toBe(0);
    expect(f.menu.getAttribute('hidden')).not.toBeNull(); expect(f.moreMenu.getAttribute('hidden')).not.toBeNull();
    expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
  });

  test('switching from verified nested K3 to Instant selects once and reopens to prove the exact target', async () => {
    const f = adapterFixture({ nestedSelected: true });
    const result = await f.select();
    expect(result.modelEvidence.selected).toEqual(instant); expect(result.modelChoices).toEqual([instant]);
    expect(f.trigger.clicks).toBe(3); expect(f.more.events.length).toBe(8);
    expect(f.options[2].clicks).toBe(1); expect(f.moreOption.clicks).toBe(0);
    expect(f.moreOption.getAttribute('aria-checked')).toBe('false');
    expect((await f.run('verifyModel')).modelEvidence.selected).toEqual(instant);
    const forbidden = adapterFixture({ nestedSelected: true });
    expect((await forbidden.select({ key: 'k3-agent', label: 'K3' })).error).toBe('model_mismatch');
    expect(forbidden.options.reduce((sum, row) => sum + row.clicks, 0) + forbidden.moreOption.clicks).toBe(0);
    expect(forbidden.counts().sends).toBe(0);
  });

  test('one fixed boundary sequence supports legacy-mouse and pointer-only listeners with native boundary flags', async () => {
    for (const hoverEvents of ['mouse', 'pointer'] as const) {
      const f = adapterFixture({ nestedSelected: true, hoverEvents });
      expect((await discover(f)).modelChoices).toEqual([instant]);
      const events = f.more.events as any[];
      expect(events.map(event => event.type)).toEqual([
        'pointerover', 'pointerenter', 'mouseover', 'mouseenter',
        'pointerout', 'pointerleave', 'mouseout', 'mouseleave',
      ]);
      events.forEach((event, index) => {
        const crosses = index % 2 === 0;
        expect(event).toMatchObject({ bubbles: crosses, cancelable: crosses, composed: crosses,
          clientX: 60, clientY: 25, buttons: 0, defaultPrevented: false });
        expect(event.view).toBe(f.window);
        expect(event.relatedTarget).toBe(index < 4 ? f.menu : f.body);
        if (event.type.startsWith('pointer')) expect(event).toMatchObject({ pointerType: 'mouse', isPrimary: true, button: -1 });
      });
      expect(f.more.clicks + f.moreOption.clicks).toBe(0);
      expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
      expect((await discover(f)).modelChoices).toEqual([instant]);
      expect(f.more.events.length).toBe(8);
    }
  });

  test('default prevention alone preserves the sequence and only later exact menu proof qualifies it', async () => {
    for (const preventAt of [1, 3, 5, 7]) {
      const f = adapterFixture({ nestedSelected: true }), original = f.more.onDispatch!;
      f.more.onDispatch = (event: any) => {
        if (f.more.events.length === preventAt) event.preventDefault();
        original(event);
      };
      await f.run('discoverModels', { expectedModelChoice: undefined });
      const dispatched = await f.run('discoverModels', { expectedModelChoice: undefined });
      expect(dispatched.pending).toBe(true);
      expect(dispatched.modelEvidence).toBeNull();
      expect(dispatched.modelChoices).toBeUndefined();
      expect(f.more.events.length).toBe(4);
      const proven = await discover(f);
      expect(proven.modelChoices).toEqual([instant]);
      expect(proven.modelEvidence.selected).toEqual({ key: 'k3-agent', label: 'K3' });
      expect(f.more.events.length).toBe(8);
      expect((f.more.events[preventAt - 1] as any).defaultPrevented).toBe(true);
      expect((await discover(f)).modelChoices).toEqual([instant]);
      expect(f.more.events.length).toBe(8);
      expect(f.options.reduce((sum, row) => sum + row.clicks, 0) + f.moreOption.clicks).toBe(0);
      expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
    }
  });

  test('prevented boundary events without submenu acknowledgement remain pending without claiming proof or replay', async () => {
    for (const blocked of ['entry', 'exit']) {
      const f = adapterFixture({ nestedSelected: true }), original = f.more.onDispatch!;
      f.more.onDispatch = (event: any) => {
        event.preventDefault();
        if (blocked === 'exit' && ['pointerover', 'pointerenter', 'mouseover', 'mouseenter'].includes(event.type)) original(event);
      };
      await f.run('discoverModels', { expectedModelChoice: undefined });
      await f.run('discoverModels', { expectedModelChoice: undefined });
      for (let read = 0; read < 5; read++) {
        const result = await f.run('discoverModels', { expectedModelChoice: undefined });
        expect(result.pending).toBe(true);
        expect(result.discoveryProgressDiagnostic.phase).toBe(blocked === 'entry' ? 'moreOpening' : 'moreClosing');
        expect(result.modelEvidence).toBeNull(); expect(result.modelChoices).toBeUndefined();
      }
      expect(f.more.events.length).toBe(blocked === 'entry' ? 4 : 8);
      expect(f.trigger.clicks).toBe(1); expect(f.more.clicks + f.moreOption.clicks).toBe(0);
      expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
    }
  });

  test('every partial-dispatch exception spends the entire claimed boundary without resuming', async () => {
    for (let failAt = 1; failAt <= 8; failAt++) {
      const f = adapterFixture({ nestedSelected: true }), dispatch = f.more.dispatchEvent.bind(f.more);
      f.more.dispatchEvent = (event: any) => {
        const result = dispatch(event);
        if (f.more.events.length === failAt) throw new Error('Synthetic dispatch failure after delivery');
        return result;
      };
      expect((await discover(f)).detail).toBe('unexpected_exception');
      expect(f.more.events.length).toBe(failAt);
      expect((await discover(f)).detail).toBe('terminal_operation');
      expect(f.more.events.length).toBe(failAt);
      expect(f.trigger.clicks).toBe(1); expect(f.counts().sends).toBe(0);
    }
  });

  test('same-ID target replacement between any boundary events cannot receive the remaining sequence', async () => {
    for (let replaceAt = 1; replaceAt <= 8; replaceAt++) {
      const f = adapterFixture({ nestedSelected: true }), original = f.more.onDispatch!;
      let replacement: any;
      f.more.onDispatch = (event: any) => {
        original(event);
        if (f.more.events.length === replaceAt) {
          replacement = f.more.cloneNode(true); f.remove(f.more); f.menu.append(replacement);
        }
      };
      expect((await discover(f)).error).toBe('model_unverified');
      expect(f.more.events.length).toBe(replaceAt);
      expect(replacement.events.length).toBe(0);
      expect((await discover(f)).detail).toBe('terminal_operation');
      expect(f.more.events.length).toBe(replaceAt); expect(replacement.events.length).toBe(0);
      expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
    }
  });

  test('checked-row mutation during exit aborts before remaining boundary events and never replays', async () => {
    for (const change of ['replacement', 'checked', 'label', 'link']) {
      const f = adapterFixture({ nestedSelected: true }), original = f.more.onDispatch!;
      f.more.onDispatch = (event: any) => {
        original(event);
        if (event.type !== 'pointerout') return;
        if (change === 'replacement') { const next = f.moreOption.cloneNode(true); f.remove(f.moreOption); f.moreMenu.append(next); }
        else if (change === 'checked') f.moreOption.setAttribute('aria-checked', 'false');
        else if (change === 'label') f.moreOption.querySelector('.kimi-menu-item__label')!.text = 'Changed';
        else f.moreMenu.setAttribute('aria-labelledby', 'foreign-trigger');
      };
      expect((await discover(f)).error).toBe('model_unverified');
      expect(f.more.events.map((event: any) => event.type)).toEqual(['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'pointerout']);
      expect((await discover(f)).detail).toBe('terminal_operation');
      expect(f.more.events.length).toBe(5); expect(f.moreOption.clicks).toBe(0);
      expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
    }
  });

  test('revoked owner or generation aborts within the synchronous boundary and restoration cannot replay it', async () => {
    for (const revoke of ['owner', 'generation']) {
      const f = adapterFixture({ nestedSelected: true }), original = f.more.onDispatch!;
      let saved: any;
      f.more.onDispatch = (event: any) => {
        original(event);
        if (f.more.events.length !== 2) return;
        if (revoke === 'owner') { saved = f.world.__computaModelOwner; f.world.__computaModelOwner = 'revoked'; }
        else { saved = f.world.__computaKimiSavedSessionV1.generation; f.world.__computaKimiSavedSessionV1.generation = 'revoked'; }
      };
      expect((await discover(f)).error).toBe('document_changed');
      expect(f.more.events.length).toBe(2);
      if (revoke === 'owner') f.world.__computaModelOwner = saved;
      else f.world.__computaKimiSavedSessionV1.generation = saved;
      expect((await discover(f)).detail).toBe('terminal_operation');
      expect(f.more.events.length).toBe(2); expect(f.counts().sends).toBe(0);
    }
  });

  test('finite More reasons distinguish a replaced trigger, replaced label, changed ARIA and an escaped boundary point without replay', async () => {
    const cases: [string, (f: ReturnType<typeof adapterFixture>) => void][] = [
      ['more_trigger_changed', f => { const next = f.more.cloneNode(true); f.remove(f.more); f.menu.append(next); }],
      ['more_label_changed', f => { const next = f.moreCurrent.cloneNode(true), parent = f.moreCurrent.parentElement!; f.remove(f.moreCurrent); parent.append(next); }],
      ['more_aria_links_changed', f => { f.more.setAttribute('aria-controls', 'private-fixture-identifier'); }],
      ['more_point_outside', f => {
        const original = f.more.getBoundingClientRect.bind(f.more);
        f.more.getBoundingClientRect = () => { const rect = original(); return { ...rect, left: rect.left + rect.width + 1 }; };
      }],
    ];
    for (const [detail, mutate] of cases) {
      const f = adapterFixture({ nestedSelected: true }), original = f.more.onDispatch!;
      f.more.onDispatch = (event: any) => { original(event); if (event.type === 'pointerover') mutate(f); };
      const result = await discover(f);
      expect(result).toEqual({ error: 'model_unverified', detail });
      expect(f.more.events.map((event: any) => event.type)).toEqual(['pointerover']);
      expect((await discover(f)).detail).toBe('terminal_operation');
      expect(f.more.events.length).toBe(1); expect(f.trigger.clicks).toBe(1);
      expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
      expect(JSON.stringify(result)).not.toContain('private-fixture-identifier');
    }
  });

  test('finite pre-entry reasons distinguish More shape and expansion without dispatching hover', async () => {
    const cases: [string, (f: ReturnType<typeof adapterFixture>) => void][] = [
      ['more_trigger_count', f => { f.remove(f.more); }],
      ['more_trigger_links', f => { f.more.setAttribute('aria-controls', ''); }],
      ['more_close_policy', f => { f.more.setAttribute('data-close-on-select', 'private-fixture-value'); }],
      ['more_label_count', f => { f.remove(f.moreCurrent); }],
      ['more_label_value', f => { f.moreCurrent.text = 'private-fixture-label'; }],
      ['more_initial_expansion', f => { f.more.setAttribute('aria-expanded', 'true'); }],
    ];
    for (const [detail, mutate] of cases) {
      const f = adapterFixture({ nestedSelected: true });
      await f.run('discoverModels', { expectedModelChoice: undefined }); mutate(f);
      const result = await discover(f);
      expect(result).toEqual({ error: 'model_unverified', detail });
      expect(f.more.events.length).toBe(0); expect(f.trigger.clicks).toBe(1);
      expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
      expect(JSON.stringify(result)).not.toContain('private-fixture');
    }
  });

  test('zero top-level checks require a verified nested selection, never an inferred current model', async () => {
    const f = adapterFixture(); f.options.forEach(row => row.setAttribute('aria-checked', 'false'));
    const result = await discover(f);
    expect(result).toMatchObject({ error: 'model_unverified', detail: 'more_label_value' });
    expect(f.more.events.length).toBe(0); expect(f.counts().sends).toBe(0);
  });

  test('nested discovery rejects malformed links, rows and ambiguous checked state before any model change', async () => {
    const mutations = [
      (f: ReturnType<typeof adapterFixture>) => f.moreMenu.setAttribute('aria-labelledby', 'foreign-trigger'),
      (f: ReturnType<typeof adapterFixture>) => f.moreOption.setAttribute('aria-checked', 'false'),
      (f: ReturnType<typeof adapterFixture>) => f.moreOption.setAttribute('aria-checked', 'unknown'),
      (f: ReturnType<typeof adapterFixture>) => f.moreOption.setAttribute('data-model-id', 'k3d1-agent'),
      (f: ReturnType<typeof adapterFixture>) => f.moreMenu.append(f.moreOption.cloneNode(true)),
      (f: ReturnType<typeof adapterFixture>) => { f.options[0].setAttribute('aria-checked', 'true'); },
      (f: ReturnType<typeof adapterFixture>) => { f.moreCurrent.text = 'K3.1 Pro'; },
      (f: ReturnType<typeof adapterFixture>) => { const old = f.more; f.remove(old); f.menu.append(old.cloneNode(true)); },
    ];
    for (const mutate of mutations) {
      const f = adapterFixture({ nestedSelected: true });
      expect((await f.run('discoverModels', { expectedModelChoice: undefined })).pending).toBe(true);
      expect((await f.run('discoverModels', { expectedModelChoice: undefined })).pending).toBe(true);
      mutate(f);
      const result = await discover(f);
      expect(['model_unverified', 'model_mismatch']).toContain(result.error);
      const clicks = f.trigger.clicks + f.more.events.length;
      expect((await discover(f)).detail).toBe('terminal_operation');
      expect(f.trigger.clicks + f.more.events.length).toBe(clicks);
      expect(f.options.reduce((sum, row) => sum + row.clicks, 0) + f.moreOption.clicks).toBe(0);
      expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
    }
  });

  test('nested menu mounting may lag its single open event without replaying it', async () => {
    const f = adapterFixture({ nestedSelected: true });
    f.more.onDispatch = event => {
      if (!['mouseover', 'mouseout'].includes(event.type)) return;
      if (f.more.getAttribute('aria-expanded') === 'true') {
        f.more.setAttribute('aria-expanded', 'false'); f.moreMenu.setAttribute('hidden', '');
      } else f.more.setAttribute('aria-expanded', 'true');
    };
    await f.run('discoverModels', { expectedModelChoice: undefined });
    await f.run('discoverModels', { expectedModelChoice: undefined });
    for (let read = 0; read < 3; read++) expect((await f.run('discoverModels', { expectedModelChoice: undefined })).pending).toBe(true);
    expect(f.more.events.length).toBe(4);
    f.moreMenu.removeAttribute('hidden');
    expect((await discover(f)).modelChoices).toEqual([instant]);
    expect(f.more.events.length).toBe(8); expect(f.trigger.clicks).toBe(2);
  });

  test('finite discovery progress distinguishes an unacknowledged submenu open without replay', async () => {
    const f = adapterFixture({ nestedSelected: true });
    f.more.onDispatch = () => {};
    expect((await f.run()).discoveryProgressDiagnostic).toBeUndefined();
    await f.run('discoverModels', { expectedModelChoice: undefined });
    const expected = { phase: 'moreOpening', mainMenuPresent: true, mainExpanded: true, mainCollapsed: false,
      submenuClaimed: true, submenuPresent: false, submenuExpanded: false, submenuCollapsed: true };
    for (let read = 0; read < 4; read++) {
      const result = await f.run('discoverModels', { expectedModelChoice: undefined });
      expect(result.pending).toBe(true); expect(result.discoveryProgressDiagnostic).toEqual(expected);
    }
    expect(f.trigger.clicks).toBe(1); expect(f.more.events.length).toBe(4);
    expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
    const serialized = JSON.stringify(expected);
    for (const privateValue of [f.more.getAttribute('id'), f.moreMenu.getAttribute('id'), 'K3', 'kimi.com', marker])
      expect(serialized).not.toContain(privateValue!);
  });

  test('finite discovery progress distinguishes an unacknowledged submenu close and disappears from ordinary reads', async () => {
    const f = adapterFixture({ nestedSelected: true }), click = f.more.onDispatch!;
    f.more.onDispatch = () => { if (f.more.getAttribute('aria-expanded') !== 'true') click({ type: 'mouseover' }); };
    await f.run('discoverModels', { expectedModelChoice: undefined });
    await f.run('discoverModels', { expectedModelChoice: undefined });
    for (let read = 0; read < 4; read++) {
      const result = await f.run('discoverModels', { expectedModelChoice: undefined });
      expect(result.pending).toBe(true);
      expect(result.discoveryProgressDiagnostic).toEqual({ phase: 'moreClosing', mainMenuPresent: true,
        mainExpanded: true, mainCollapsed: false, submenuClaimed: true, submenuPresent: true,
        submenuExpanded: true, submenuCollapsed: false });
    }
    expect(f.more.events.length).toBe(8); expect(f.trigger.clicks).toBe(1);
    expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
    f.more.onDispatch = click; click({ type: 'mouseout' });
    expect((await discover(f)).modelChoices).toEqual([instant]);
    expect((await f.run()).discoveryProgressDiagnostic).toBeUndefined();
    expect((await f.run('verifyModel', { expectedModelChoice: { key: 'k3-agent', label: 'K3' } })).discoveryProgressDiagnostic).toBeUndefined();
    expect(f.counts().sends).toBe(0);
  });

  test('replacement after nested checked-row proof and lost submenu event replies never gain authority or replay', async () => {
    const changed = adapterFixture({ nestedSelected: true });
    const click = changed.more.onDispatch!;
    changed.more.onDispatch = () => { if (changed.more.getAttribute('aria-expanded') !== 'true') click({ type: 'mouseover' }); };
    for (let step = 0; step < 3; step++) await changed.run('discoverModels', { expectedModelChoice: undefined });
    const old = changed.moreOption; changed.remove(old); changed.moreMenu.append(old.cloneNode(true));
    expect((await discover(changed)).detail).toBe('more_selected_label');
    expect(changed.more.events.length).toBe(8);
    expect((await discover(changed)).detail).toBe('terminal_operation');
    const thrown = adapterFixture({ nestedSelected: true }), original = thrown.more.onDispatch!;
    thrown.more.onDispatch = event => { original(event); throw new Error('Synthetic lost event callback'); };
    expect((await discover(thrown)).detail).toBe('unexpected_exception');
    expect((await discover(thrown)).detail).toBe('terminal_operation');
    expect(thrown.more.events.length).toBe(1); expect(thrown.counts().sends).toBe(0);
  });

  test('unknown, duplicated or obscured model choices fail without insertion or Send', async () => {
    const unknown = adapterFixture(); expect((await unknown.select({ key: 'invented', label: 'Invented' })).error).toBe('model_mismatch');
    const agent = adapterFixture(); expect((await agent.select({ key: 'k3d1-agent', label: 'K3.1 Pro' })).error).toBe('model_mismatch');
    expect(agent.options[0].clicks).toBe(0);
    const duplicate = adapterFixture(); duplicate.list.append(duplicate.options[0].cloneNode(true));
    expect((await duplicate.select()).error).toBe('model_unverified');
    const blocked = adapterFixture(); blocked.occlude(blocked.trigger);
    expect((await blocked.select()).error).toBe('model_unverified');
    expect(unknown.counts().sends + duplicate.counts().sends + blocked.counts().sends).toBe(0);
  });

  test('exact insertion and one Send bind the real user and literal answer independently', async () => {
    const f = adapterFixture(), complete = await f.submit();
    expect(complete.error).toBeUndefined(); expect(complete.answerComplete).toBe(true);
    expect(complete.text).toBe('{"type":"message","text":"Synthetic reply"}');
    expect(complete).toMatchObject({ firstUserVerified: true, firstUserMarkerVerified: true,
      conversationIdentity: canonical, sessionLifecycle: 'saved_conversation_delete', temporary: false });
    expect(complete.firstUserFingerprint).toHaveLength(64);
    expect(f.messages.userBody.textContent).toBe(prompt);
    expect(f.counts()).toEqual({ insertions: 1, sends: 1, confirms: 0 });
    expect((await f.run('submit')).error).toBe('prompt_not_inserted'); expect(f.counts().sends).toBe(1);
  });

  test('synthetic WebKit paragraphs preserve the complete payload despite rendered spacing', async () => {
    const outbound = '\n  café 👋\tNBSP\u00a0  \n\nLine \\"quoted\\" and \\\\ literal  \n\n\nComputa session marker: ' + marker;
    const f = adapterFixture({ outbound, paragraphInsertion: true }); await f.select(); await f.run('prepare');
    expect((await f.run('insert')).inserted).toBe(true);
    expect(f.editor.innerText).not.toBe(outbound); expect(f.draftText()).toBe(outbound);
    expect(f.editor.innerText.split('\n').length).toBeGreaterThan(outbound.split('\n').length);
    expect((await f.run('sendReady')).sendReady).toBe(true); expect((await f.run('submit')).submitted).toBe(true);
    const observed = await f.run();
    expect(observed.firstUserVerified).toBe(true); expect(f.messages.userBody.textContent).toBe(outbound);
    expect(f.counts()).toEqual({ insertions: 1, sends: 1, confirms: 0 });
  });

  test('long tool-style prompts are not limited by the generic 256-node query budget', async () => {
    const outbound = Array.from({ length: 400 }, (_, index) => `  Exact synthetic tool field ${index}: \\"quoted\\"  `).join('\n')
      + '\n\nComputa session marker: ' + marker;
    const f = adapterFixture({ outbound }); const result = await f.submit();
    expect(result.firstUserVerified).toBe(true); expect(result.answerComplete).toBe(true);
    expect(f.messages.userBody.textContent).toBe(outbound); expect(f.counts().sends).toBe(1);
  });

  test('one literal insertText preserves bytes without treating HTML-like prompt text as markup', async () => {
    const outbound = '  "straight" and \'single\' — café 👋\u00a0\t  \n\n'
      + '</p><script>globalThis.fixtureInjected = true</script><img src=x onerror="bad()">\n'
      + '&lt; &quot; &#39; &amp; literal\rreturn\n\nComputa session marker: ' + marker;
    const f = adapterFixture({ outbound }); const result = await f.submit();
    expect(result.firstUserVerified).toBe(true); expect(f.messages.userBody.textContent).toBe(outbound);
    expect(f.insertionText).toBe(outbound);
    expect(adapterSource).not.toContain("execCommand('insertHTML'");
    expect(f.editor.querySelectorAll('SCRIPT, IMG')).toHaveLength(0);
    expect(f.counts()).toEqual({ insertions: 1, sends: 1, confirms: 0 });
  });

  test('hidden, nested, ambiguous and reordered composer content cannot pass exact Send verification', async () => {
    for (const mutation of ['hidden', 'inert', 'aria-hidden', 'span', 'control', 'inline-break', 'empty-paragraph', 'root-text', 'reordered', 'changed-space']) {
      const f = adapterFixture({ paragraphInsertion: true }); await f.select(); await f.run('prepare'); await f.run('insert');
      const first = f.editor.children[0];
      if (['hidden', 'inert', 'aria-hidden'].includes(mutation)) first.setAttribute(mutation, mutation === 'aria-hidden' ? 'true' : '');
      else if (mutation === 'span') { const text = first.text; first.replaceChildren(new f.Node('SPAN', {}, text)); }
      else if (mutation === 'control') first.append(new f.Node('INPUT', { value: 'Unexpected' }));
      else if (mutation === 'inline-break') first.append(new f.Node('BR'));
      else if (mutation === 'empty-paragraph') first.replaceChildren();
      else if (mutation === 'root-text') f.editor.text = 'Unexpected root text';
      else if (mutation === 'reordered') [f.editor.children[0], f.editor.children[1]] = [f.editor.children[1], f.editor.children[0]];
      else first.text += ' ';
      expect((await f.run('sendReady')).error).toBeDefined(); expect(f.counts().sends).toBe(0);
      expect((await f.run('submit')).error).toBeDefined(); expect(f.counts().sends).toBe(0);
    }
  });

  test('uncertain insertion and Send acknowledgements cannot be replayed', async () => {
    for (const type of ['insertionFails', 'insertionThrows', 'submitThrows'] as const) {
      const f = adapterFixture({ [type]: true }); const failed = await f.submit();
      expect(failed.error).toBeDefined();
      expect(failed.submissionAcknowledgement).toBeUndefined();
      const before = f.counts();
      expect((await f.run(type === 'submitThrows' ? 'submit' : 'insert')).error).toBe('conversation_changed');
      expect(f.counts()).toEqual(before);
    }
  });

  test('live Lexical shape keeps embedded newlines and excludes the rendered trailing LF', async () => {
    const outbound = 'Synthetic draft\n"literal" & <code>\n\ntrailing  spaces  \n\nComputa session marker: ' + marker;
    const f = adapterFixture({ outbound }); await f.select(); await f.run('prepare');
    const result = await f.run('insert');
    expect(result.inserted).toBe(true); expect(result.insertionPending).toBe(false);
    expect(f.editor.children).toHaveLength(1); expect(f.editor.children[0].getAttribute('dir')).toBe('ltr');
    expect(f.editor.children[0].children[0].getAttribute('data-lexical-text')).toBe('true');
    expect(f.editor.textContent).toBe(outbound); expect(f.editor.innerText).toBe(outbound + '\n');
    expect((await f.run('sendReady')).sendReady).toBe(true);
    expect((await f.run('submit')).submitted).toBe(true); expect((await f.run()).firstUserVerified).toBe(true);
    expect(f.messages.userBody.textContent).toBe(outbound); expect(f.counts().insertions).toBe(1);
  });

  test('async Lexical insertion acknowledges only dispatch until exact settled readback', async () => {
    const f = adapterFixture({ delayedInsertion: true }); await f.select(); await f.run('prepare');
    const result = await f.run('insert');
    expect(result).toMatchObject({ inserted: false, insertionDispatched: true, insertionPending: true, pending: true,
      firstUserVerified: false, userCount: 0, text: '', answerComplete: false });
    expect(result.insertionAcknowledgement).toEqual({ ownerToken: '9fe25e48-2e0b-46cb-84f7-7b4f32e1794f',
      documentGeneration: generation, sequence: 1, outboundFingerprint: submissionFingerprint });
    for (let read = 0; read < 4; read++) {
      expect(await f.run('sendReady')).toMatchObject({ inserted: false, insertionPending: true, pending: true, sendReady: false });
      expect(f.counts()).toEqual({ insertions: 1, sends: 0, confirms: 0 });
    }
    expect((await f.run('insert')).error).toBe('composer_not_empty'); expect(f.counts().insertions).toBe(1);
    f.settleInsertion();
    expect(await f.run('sendReady')).toMatchObject({ inserted: true, insertionPending: false, sendReady: true });
    expect((await f.run('submit')).submitted).toBe(true); expect((await f.run()).firstUserVerified).toBe(true);
    expect(f.counts()).toEqual({ insertions: 1, sends: 1, confirms: 0 });
  });

  test('pending insertion cannot submit early or accept a nonempty wrong settlement', async () => {
    for (const settlement of [null, prompt.replace(/\n/g, ''), prompt.replace('"quoted"', '”quoted”'), prompt + ' ']) {
      const f = adapterFixture({ delayedInsertion: true }); await f.select(); await f.run('prepare'); await f.run('insert');
      if (settlement !== null) f.settleInsertion(settlement);
      const result = await f.run(settlement === null ? 'submit' : 'sendReady');
      expect(result.error).toBe('prompt_not_inserted'); expect(result.insertionAcknowledgement).toBeUndefined();
      f.settleInsertion(); expect((await f.run('sendReady')).detail).toBe('terminal_operation');
      expect(f.counts()).toEqual({ insertions: 1, sends: 0, confirms: 0 });
    }
  });

  test('a verified draft cannot become empty and regain pending-insertion authority', async () => {
    const f = adapterFixture(); await f.select(); await f.run('prepare');
    expect((await f.run('insert')).inserted).toBe(true); f.setDraft('');
    expect((await f.run('sendReady')).error).toBe('prompt_not_inserted');
    expect(f.counts().sends).toBe(0); expect(f.counts().insertions).toBe(1);
  });

  test('Lexical span reader rejects hidden, nested, split, unmarked and changed-byte structures', async () => {
    for (const mutation of ['hidden', 'inert', 'aria-hidden', 'unmarked', 'direction', 'nested', 'split', 'multiple-paragraphs', 'mixed-text', 'unicode', 'nbsp']) {
      const outbound = 'café\tNBSP\u00a0 and "quotes"\n\nComputa session marker: ' + marker;
      const f = adapterFixture({ outbound }); await f.select(); await f.run('prepare'); await f.run('insert');
      const paragraph = f.editor.children[0], span = paragraph.children[0];
      if (['hidden', 'inert', 'aria-hidden'].includes(mutation)) span.setAttribute(mutation, mutation === 'aria-hidden' ? 'true' : '');
      else if (mutation === 'unmarked') span.removeAttribute('data-lexical-text');
      else if (mutation === 'direction') paragraph.removeAttribute('dir');
      else if (mutation === 'nested') span.append(new f.Node('SPAN', {}, 'extra'));
      else if (mutation === 'split') paragraph.append(span.cloneNode(true));
      else if (mutation === 'multiple-paragraphs') f.editor.append(paragraph.cloneNode(true));
      else if (mutation === 'mixed-text') paragraph.text = 'extra';
      else if (mutation === 'unicode') span.text = span.text.normalize('NFD');
      else span.text = span.text.replace('\u00a0', ' ');
      expect((await f.run('sendReady')).error).toBeDefined(); expect(f.counts().sends).toBe(0);
    }
  });

  test('pending readback stays pinned to the prepared editor, owner, generation, prompt and selection', async () => {
    for (const mutation of ['editor', 'owner', 'generation', 'prompt', 'model']) {
      const f = adapterFixture({ delayedInsertion: true }); await f.select(); await f.run('prepare'); await f.run('insert');
      const overrides: Record<string, unknown> = {};
      if (mutation === 'editor') { f.remove(f.editor); f.scope.append(f.editor.cloneNode(true)); }
      if (mutation === 'owner') overrides.ownerToken = marker;
      if (mutation === 'generation') overrides.documentGeneration = marker;
      if (mutation === 'prompt') overrides.prompt = 'Different ' + prompt;
      if (mutation === 'model') f.triggerName.text = 'Changed model';
      expect((await f.run('sendReady', overrides)).error).toBeDefined();
      expect(f.counts()).toEqual({ insertions: 1, sends: 0, confirms: 0 });
    }
  });

  test('Lexical span text nodes are budgeted before iteration or text extraction', async () => {
    const f = adapterFixture(); await f.select(); await f.run('prepare'); await f.run('insert');
    const span = f.editor.children[0].children[0];
    Object.defineProperty(span, 'childNodes', { get: () => ({ length: 360_403,
      [Symbol.iterator]() { throw new Error('Over-budget text nodes must never be iterated'); } }) });
    Object.defineProperty(span, 'textContent', { get() { throw new Error('Over-budget text must never be read'); } });
    expect((await f.run('sendReady')).error).toBe('composer_unavailable'); expect(f.counts().sends).toBe(0);
  });

  test('missing or malformed native insertion fingerprint cannot dispatch input', async () => {
    for (const savedSubmissionFingerprint of [undefined, '', 1, 'a'.repeat(63), 'A'.repeat(64), 'x'.repeat(64)]) {
      const f = adapterFixture(); await f.select(); await f.run('prepare');
      const inserted = await f.run('insert', { savedSubmissionFingerprint });
      expect(inserted.error).toBe('prompt_not_inserted'); expect(inserted.insertionAcknowledgement).toBeUndefined();
      expect(f.counts().insertions).toBe(0); expect(f.counts().sends).toBe(0);
    }
  });

  test('successful Send returns only a bound dispatch acknowledgement before first-body proof', async () => {
    const f = adapterFixture(); await f.select(); await f.run('prepare'); await f.run('insert');
    const sent = await f.run('submit');
    expect(sent.submissionAcknowledgement).toEqual({ ownerToken: '9fe25e48-2e0b-46cb-84f7-7b4f32e1794f',
      documentGeneration: generation, sequence: 1, outboundFingerprint: submissionFingerprint });
    expect(sent.submitted).toBe(true); expect(sent.userCount).toBe(0); expect(sent.firstUserVerified).toBe(false);
    expect(sent.firstUserFingerprint).toBeNull(); expect(sent.answerComplete).toBe(false);
    expect((await f.run()).firstUserVerified).toBe(true); expect(f.counts().sends).toBe(1);
  });

  test('missing or malformed native submission fingerprint cannot dispatch Send', async () => {
    for (const savedSubmissionFingerprint of [undefined, '', 1, 'a'.repeat(63), 'A'.repeat(64), 'x'.repeat(64)]) {
      const f = adapterFixture(); await f.select(); await f.run('prepare'); await f.run('insert');
      const sent = await f.run('submit', { savedSubmissionFingerprint });
      expect(sent.error).toBe('prompt_not_inserted'); expect(sent.submissionAcknowledgement).toBeUndefined();
      expect(f.counts().sends).toBe(0);
    }
  });

  test('occluded or disabled Send never clicks even with an exact draft', async () => {
    for (const mode of ['occluded', 'disabled']) {
      const f = adapterFixture(); await f.select(); await f.run('prepare'); await f.run('insert');
      if (mode === 'occluded') f.occlude(f.send); else f.send.setAttribute('class', 'send-button-container disabled');
      expect((await f.run('sendReady')).sendReady).toBe(false);
      expect((await f.run('submit')).error).toBe('send_unavailable'); expect(f.counts().sends).toBe(0);
    }
  });

  test('provisional route and delayed body stay pending until the exact canonical first-user bind', async () => {
    const f = adapterFixture({ provisional: true, delayedUser: true });
    const empty = await f.submit(); expect(empty.answerComplete).toBe(false); expect(empty.firstUserVerified).toBe(false);
    expect(f.document.URL).toBe(provisional);
    f.appendUser(); const provisionalBody = await f.run();
    expect(provisionalBody.ownershipPending).toBe(true); expect(provisionalBody.text).toBe('');
    f.document.URL = canonical; const canonicalBody = await f.run();
    expect(canonicalBody.firstUserVerified).toBe(true); expect(canonicalBody.answerComplete).toBe(true);
    expect(f.counts().sends).toBe(1);
  });

  test('empty initial IDs wait without binding until the replacement UUID root and canonical route', async () => {
    const f = adapterFixture({ provisional: true, optimisticUser: true });
    const pending = await f.submit(), oldRoot = f.messages.user;
    expect(pending).toMatchObject({ ownershipPending: true, userCount: 1, responseCount: 0, text: '',
      firstUserVerified: false, firstUserMarkerVerified: false, firstUserFingerprint: null, answerComplete: false });
    expect(pending.kimiFirstRootIDDiagnostic).toBeUndefined();
    expect(f.world.__computaKimiSavedSessionV1.first).toBeNull(); expect(f.fingerprint).toBeUndefined();
    const before = f.counts();
    for (let i = 0; i < 3; i++) expect((await f.run()).ownershipPending).toBe(true);
    expect(f.counts()).toEqual(before);
    f.replaceOptimisticUser(); expect(f.messages.user).not.toBe(oldRoot); expect(oldRoot.isConnected).toBe(false);
    const replacement = await f.run(); expect(replacement.ownershipPending).toBe(true);
    expect(replacement.text).toBe(''); expect(f.fingerprint).toBeUndefined();
    f.document.URL = canonical;
    const complete = await f.run();
    expect(complete.firstUserVerified).toBe(true); expect(complete.firstUserMarkerVerified).toBe(true);
    expect(complete.firstUserFingerprint).toBe(submissionFingerprint); expect(complete.answerComplete).toBe(true);
    expect(f.world.__computaKimiSavedSessionV1.first.root).toBe(f.messages.user);
    expect(f.counts()).toEqual(before); expect(f.counts().sends).toBe(1);
  });

  test('one following provisional assistant stays unread until the exact UUID user binds', async () => {
    const f = adapterFixture({ provisional: true, optimisticUser: true });
    await f.select(); await f.run('prepare'); await f.run('insert');
    expect((await f.run('submit')).submitted).toBe(true);
    const preview = new f.Node('DIV', { class: 'chat-content-item chat-content-item-assistant' });
    const getAttribute = preview.getAttribute.bind(preview);
    preview.getAttribute = name => {
      if (name === 'data-archer-id') throw new Error('Preview identity must not be read');
      return getAttribute(name);
    };
    Object.defineProperty(preview, 'textContent', { get: () => { throw new Error('Preview text must not be read'); } });
    f.body.append(new f.Node('DIV'));
    f.body.append(preview);
    let digests = 0;
    f.onDigest(() => { digests++; });
    const pending = await f.run();
    expect(pending).toEqual({ url: provisional, sessionLifecycle: 'saved_conversation_delete', temporary: false,
      composer: true, userCount: 1, responseCount: 0, text: '', answerComplete: false, busy: true, ownershipPending: true,
      modelEvidence: { selected: instant, verification: 'website_selection', source: 'model_picker_label' },
      conversationIdentity: null, firstUserIdentity: null, firstUserVerified: false,
      firstUserMarkerVerified: false, firstUserFingerprint: null });
    expect(await f.run()).toEqual(pending);
    expect(digests).toBe(0);
    expect(f.world.__computaKimiSavedSessionV1.first).toBeNull();
    expect(f.world.__computaKimiSavedSessionV1.canonical).toBeNull();
    expect(f.fingerprint).toBeUndefined();
    expect(f.counts()).toEqual({ insertions: 1, sends: 1, confirms: 0 });

    f.remove(preview); f.replaceOptimisticUser(); f.document.URL = canonical;
    const complete = await f.run();
    expect(complete).toMatchObject({ firstUserVerified: true, firstUserFingerprint: submissionFingerprint,
      conversationIdentity: canonical, answerComplete: true, text: '{"type":"message","text":"Synthetic reply"}' });
    expect(digests).toBe(1);
    expect(f.counts()).toEqual({ insertions: 1, sends: 1, confirms: 0 });
  });

  test('provisional assistant waiting requires an acknowledged ordered row and grants no action authority', async () => {
    for (const kind of ['foreign_parent', 'detached', 'hidden', 'reordered', 'extra', 'prompt', 'unacknowledged',
      'canonical', 'cleanup', 'delete', 'submit'] as const) {
      const f = adapterFixture({ provisional: true, optimisticUser: true });
      expect((await f.submit()).ownershipPending).toBe(true);
      const makePreview = () => new f.Node('DIV', { class: 'chat-content-item chat-content-item-assistant' }, 'PRIVATE_PREVIEW');
      const preview = makePreview(), state = f.world.__computaKimiSavedSessionV1;
      if (kind === 'foreign_parent') {
        const foreign = new f.Node('DIV'); foreign.append(preview); f.body.append(foreign);
      } else if (kind === 'reordered') {
        preview.parentElement = f.body; f.body.children.splice(f.body.children.indexOf(f.messages.user), 0, preview);
      } else {
        f.body.append(preview);
      }
      if (kind === 'detached') preview.connected = false;
      if (kind === 'hidden') preview.setAttribute('hidden', '');
      if (kind === 'extra') f.body.append(makePreview());
      if (kind === 'prompt') f.messages.userBody.text = prompt.replace('Exact', 'Other');
      if (kind === 'unacknowledged') state.submissionAcknowledged = false;
      if (kind === 'canonical') f.document.URL = canonical;
      const result = await f.run(kind === 'delete' ? 'deleteConversation' : kind === 'submit' ? 'submit' : 'inspect',
        kind === 'cleanup' ? { kimiCleanupInspection: true } : {});
      expect(result.error).toBeDefined();
      expect(result.ownershipPending).toBeUndefined();
      expect(result.firstUserVerified).toBeUndefined();
      expect(result.text).toBeUndefined();
      expect(JSON.stringify(result)).not.toContain('PRIVATE_PREVIEW');
      expect(state.first).toBeNull();
      expect(state.initialModelRemount).toBeNull();
      expect(f.fingerprint).toBeUndefined();
      expect(f.counts()).toEqual({ insertions: 1, sends: 1, confirms: 0 });
    }
  });

  test('the first detached model trigger can remount while the same optimistic assistant stays unread', async () => {
    const f = adapterFixture({ provisional: true, optimisticUser: true });
    expect((await f.submit()).ownershipPending).toBe(true);
    const preview = new f.Node('DIV', { class: 'chat-content-item chat-content-item-assistant' });
    const getAttribute = preview.getAttribute.bind(preview);
    preview.getAttribute = name => {
      if (name === 'data-archer-id') throw new Error('Preview identity must not be read');
      return getAttribute(name);
    };
    Object.defineProperty(preview, 'textContent', { get: () => { throw new Error('Preview text must not be read'); } });
    f.body.append(new f.Node('DIV'), preview);
    const replacement = f.trigger.cloneNode(true); f.remove(f.trigger); f.body.append(replacement);
    const state = f.world.__computaKimiSavedSessionV1;
    let digests = 0;
    f.onDigest(() => { digests++; });
    const pending = await f.run();
    expect(pending).toMatchObject({ ownershipPending: true, userCount: 1, responseCount: 0, text: '', busy: true,
      firstUserVerified: false, firstUserMarkerVerified: false, firstUserFingerprint: null, answerComplete: false,
      firstUserIdentity: null, conversationIdentity: null, modelEvidence: { selected: instant } });
    expect(state.model.trigger).toBe(replacement);
    expect(state.initialModelRemount.stage).toBe('verified');
    expect(state.first).toBeNull(); expect(f.fingerprint).toBeUndefined();
    expect(digests).toBe(1);
    const remount = state.initialModelRemount;
    f.onDigest(() => { digests++; });
    expect(await f.run()).toEqual(pending);
    expect(state.initialModelRemount).toBe(remount);
    expect(digests).toBe(1);
    expect(f.counts()).toEqual({ insertions: 1, sends: 1, confirms: 0 });

    f.remove(preview); f.replaceOptimisticUser(); f.document.URL = canonical;
    const complete = await f.run();
    expect(complete).toMatchObject({ firstUserVerified: true, firstUserFingerprint: submissionFingerprint,
      conversationIdentity: canonical, answerComplete: true, text: '{"type":"message","text":"Synthetic reply"}' });
    expect(digests).toBe(2);
    expect(f.counts()).toEqual({ insertions: 1, sends: 1, confirms: 0 });
  });

  test('the model remount rejects preview, transcript, route and model changes across its hash', async () => {
    for (const kind of ['preview_removed', 'preview_replaced', 'preview_hidden', 'second_assistant',
      'same_nodes_reparented', 'prompt', 'route', 'model_label', 'model_trigger', 'old_trigger'] as const) {
      const f = adapterFixture({ provisional: true, optimisticUser: true });
      expect((await f.submit()).ownershipPending).toBe(true);
      const makePreview = () => new f.Node('DIV', { class: 'chat-content-item chat-content-item-assistant' }, 'PRIVATE_PREVIEW');
      const preview = makePreview(); f.body.append(preview);
      const replacement = f.trigger.cloneNode(true); f.remove(f.trigger); f.body.append(replacement);
      const state = f.world.__computaKimiSavedSessionV1;
      let digests = 0;
      f.onDigest(() => {
        digests++;
        if (kind === 'preview_removed' || kind === 'preview_replaced') f.remove(preview);
        if (kind === 'preview_replaced' || kind === 'second_assistant') f.body.append(makePreview());
        if (kind === 'preview_hidden') preview.setAttribute('hidden', '');
        if (kind === 'same_nodes_reparented') {
          const root = f.messages.user, wrapper = new f.Node('DIV');
          f.body.children = f.body.children.filter(node => node !== root && node !== preview);
          wrapper.append(root, preview); f.body.append(wrapper);
        }
        if (kind === 'prompt') f.messages.userBody.text = prompt.replace('Exact', 'Other');
        if (kind === 'route') f.document.URL = canonical;
        if (kind === 'model_label') replacement.querySelector('.name')!.text = 'Foreign selection';
        if (kind === 'model_trigger') {
          const other = replacement.cloneNode(true); f.remove(replacement); f.body.append(other);
        }
        if (kind === 'old_trigger') { f.trigger.connected = true; f.body.append(f.trigger); }
      });
      const result = await f.run();
      expect(digests).toBe(1);
      expect(result.error).toBeDefined(); expect(result.ownershipPending).toBeUndefined();
      expect(result.firstUserVerified).toBeUndefined(); expect(result.text).toBeUndefined();
      expect(JSON.stringify(result)).not.toContain('PRIVATE_PREVIEW');
      expect(state.model.trigger).toBe(f.trigger);
      expect(state.initialModelRemount.stage).toBe('checking');
      expect(state.first).toBeNull(); expect(f.fingerprint).toBeUndefined();
      expect(f.counts()).toEqual({ insertions: 1, sends: 1, confirms: 0 });
    }
  });

  test('optimistic waiting preserves the entire long outbound including its exact marker suffix', async () => {
    const outbound = ('Synthetic tool schema café \\ quoted "value"\n'.repeat(1600)) + '\nComputa session marker: ' + marker;
    const f = adapterFixture({ provisional: true, optimisticUser: true, outbound });
    const pending = await f.submit(); expect(pending.ownershipPending).toBe(true);
    expect(f.messages.userBody.textContent).toBe(outbound); expect(f.fingerprint).toBeUndefined();
    f.replaceOptimisticUser(); f.document.URL = canonical;
    const complete = await f.run(); expect(complete.firstUserVerified).toBe(true); expect(complete.answerComplete).toBe(true);
    expect(f.messages.userBody.textContent).toBe(outbound); expect(f.counts().insertions).toBe(1); expect(f.counts().sends).toBe(1);
  });

  test('empty-ID wait rejects missing malformed mixed or canonical identities and changed content', async () => {
    for (const kind of ['missing_root', 'missing_turn', 'malformed_root', 'nonempty_turn', 'canonical', 'body',
      'marker', 'body_shape', 'duplicate_body', 'duplicate_user', 'count', 'model']) {
      const f = adapterFixture({ provisional: true, optimisticUser: true });
      await f.select(); await f.run('prepare'); await f.run('insert'); await f.run('submit');
      let extra: Record<string, unknown> = {};
      if (kind === 'missing_root') f.messages.user.removeAttribute('data-archer-id');
      if (kind === 'missing_turn') f.messages.user.removeAttribute('data-conversation-turn-id');
      if (kind === 'malformed_root') f.messages.user.setAttribute('data-archer-id', 'private-unaccepted-id');
      if (kind === 'nonempty_turn') f.messages.user.setAttribute('data-conversation-turn-id', marker);
      if (kind === 'canonical') f.document.URL = canonical;
      if (kind === 'body') f.messages.userBody.text = prompt.replace('Exact', 'Other');
      if (kind === 'marker') extra = { expectedFirstUserMarker: generation };
      if (kind === 'body_shape') f.messages.userBody.append(new f.Node('SPAN', {}, ''));
      if (kind === 'duplicate_body') f.messages.content.append(new f.Node('SPAN', { class: 'user-content__text' }, prompt));
      if (kind === 'duplicate_user') f.installTranscript();
      if (kind === 'count') extra = { expectedUserCounts: [0] };
      if (kind === 'model') f.triggerName.text = 'Foreign selection';
      const result = await f.run('inspect', extra);
      expect(result.error).toBeDefined(); expect(result.ownershipPending).toBeUndefined();
      expect(result.firstUserVerified).toBeUndefined(); expect(result.text).toBeUndefined();
      expect(f.fingerprint).toBeUndefined(); expect(f.counts().sends).toBe(1);
    }
  });

  test('empty-ID wait is inspect-only and cannot survive changed ownership or acquire a second Send', async () => {
    for (const kind of ['verifyModel', 'stop', 'deleteConversation', 'cleanup', 'binding', 'fingerprint', 'owner', 'generation']) {
      const f = adapterFixture({ provisional: true, optimisticUser: true });
      expect((await f.submit()).ownershipPending).toBe(true);
      const action = ['verifyModel', 'stop', 'deleteConversation'].includes(kind) ? kind : 'inspect';
      const extra = kind === 'cleanup' ? { kimiCleanupInspection: true } : kind === 'binding' ? { allowFirstUserBinding: false }
        : kind === 'fingerprint' ? { expectedFirstUserFingerprint: submissionFingerprint }
        : kind === 'owner' ? { ownerToken: marker } : kind === 'generation' ? { documentGeneration: marker } : {};
      const result = await f.run(action, extra);
      expect(result.error).toBeDefined(); expect(result.ownershipPending).toBeUndefined();
      expect(f.counts().sends).toBe(1); expect(f.counts().confirms).toBe(0); expect(f.fingerprint).toBeUndefined();
    }
    const f = adapterFixture({ provisional: true, optimisticUser: true }); await f.submit();
    expect((await f.run('submit')).error).toBeDefined(); expect(f.counts().sends).toBe(1);
  });

  test('replaced UUID user still requires exact full-body and post-hash physical ownership', async () => {
    for (const kind of ['wrong_text', 'turn_link', 'changed_during_hash', 'old_root_returns']) {
      const f = adapterFixture({ provisional: true, optimisticUser: true }); await f.submit();
      const oldRoot = f.messages.user; f.replaceOptimisticUser(); f.document.URL = canonical;
      if (kind === 'wrong_text') f.messages.userBody.text = prompt.replace('Exact', 'Other');
      if (kind === 'turn_link') f.messages.user.setAttribute('data-conversation-turn-id', marker);
      if (kind === 'changed_during_hash') f.onDigest(() => { f.messages.userBody.text += ' changed'; });
      if (kind === 'old_root_returns') { oldRoot.connected = true; f.body.append(oldRoot); }
      const result = await f.run(); expect(result.error).toBeDefined(); expect(result.firstUserVerified).toBeUndefined();
      expect(f.fingerprint).toBeUndefined(); expect(f.counts().sends).toBe(1);
    }
  });

  test('stale native route reads cannot poison the one allowed fresh-to-provisional-to-canonical promotion', async () => {
    const f = adapterFixture({ provisional: true });
    await f.select(); await f.run('prepare'); await f.run('insert');
    expect((await f.run('submit')).submitted).toBe(true);
    // Native evaluated the fresh route immediately before the one Send changed
    // it. A rejected stale read publishes no ownership and must be discarded.
    const staleFresh = await f.run('inspect', { expectedURL: 'https://www.kimi.ai/' });
    expect(staleFresh).toEqual({ error: 'document_changed', detail: 'document_url' });
    expect(f.world.__computaKimiSavedSessionV1.terminal).toBe(false);
    let digests = 0; f.onDigest(() => { digests++; });
    const provisionalRead = await f.run();
    expect(provisionalRead.ownershipPending).toBe(true); expect(digests).toBe(0);
    // There is deliberately no awaited hash on a provisional body. Promotion
    // while native awaits its read is handled by a new exact-URL observation.
    f.document.URL = canonical;
    const staleProvisional = await f.run('inspect', { expectedURL: provisional });
    expect(staleProvisional).toEqual({ error: 'document_changed', detail: 'document_url' });
    expect(f.world.__computaKimiSavedSessionV1.terminal).toBe(false);
    const current = await f.run();
    expect(current.firstUserVerified).toBe(true); expect(current.answerComplete).toBe(true);
    expect(digests).toBe(1); expect(f.counts().sends).toBe(1);
  });

  test('foreign canonical route during the first asynchronous digest is terminal and never publishes proof', async () => {
    const f = adapterFixture({ delayedUser: true }); await f.submit(); f.appendUser();
    f.onDigest(() => { f.document.URL = canonical.replace('65258a69', '65258a68'); });
    const changed = await f.run();
    expect(changed).toEqual({ error: 'document_changed', detail: 'document_url' });
    expect(f.fingerprint).toBeUndefined();
    expect(f.world.__computaKimiSavedSessionV1.terminal).toBe(true);
    f.document.URL = canonical;
    expect((await f.run()).detail).toBe('terminal_operation');
    expect(f.counts().sends).toBe(1);
  });

  test('another provisional route, canonical chat or document generation cannot inherit the request', async () => {
    const provisionalFixture = adapterFixture({ provisional: true, delayedUser: true }); await provisionalFixture.submit();
    provisionalFixture.document.URL = provisional.replace('p5258a69', 'p5258a68');
    expect((await provisionalFixture.run()).error).toBe('conversation_changed');
    const canonicalFixture = adapterFixture(); await canonicalFixture.submit();
    canonicalFixture.document.URL = canonical.replace('65258a69', '65258a68');
    expect((await canonicalFixture.run()).error).toBe('conversation_changed');
    const changedGeneration = adapterFixture(); await changedGeneration.submit();
    expect((await changedGeneration.run('inspect', { documentGeneration: marker })).error).toBe('document_changed');
    expect(provisionalFixture.counts().sends + canonicalFixture.counts().sends + changedGeneration.counts().sends).toBe(3);
  });

  test('same-sized wrong body and physical replacement during hash fail ownership', async () => {
    for (const change of ['text', 'body', 'generation']) {
      const f = adapterFixture({ delayedUser: true }); await f.submit(); f.appendUser();
      f.onDigest(() => {
        if (change === 'text') f.messages.userBody.text = prompt.replace('Exact', 'Other');
        if (change === 'body') f.messages.content.replaceChildren(f.messages.userBody.cloneNode(true));
        if (change === 'generation') f.world.__computaKimiSavedSessionV1.generation = marker;
      });
      expect((await f.run()).error).toBeDefined(); expect(f.counts().sends).toBe(1);
    }
  });

  test('response completion must survive the asynchronous ownership check', async () => {
    const f = adapterFixture({ streaming: true }); const streaming = await f.submit();
    expect(streaming.answerComplete).toBe(false); expect(streaming.busy).toBe(true);
    f.finishResponse(); expect((await f.run()).answerComplete).toBe(true);
    f.onDigest(() => f.remove(f.rail));
    expect((await f.run()).answerComplete).toBe(false); expect(f.counts().sends).toBe(1);
  });

  test('authored prose, duplicate code and malformed JSON are never stripped to rescue a tool envelope', async () => {
    const prose = adapterFixture(); await prose.submit();
    prose.part.append(new prose.Node('P', {}, 'This is authored outside prose.'));
    const withProse = await prose.run(); expect(withProse.error).toBe('unsupported_response_format');
    expect(prose.part.textContent).toContain('This is authored outside prose.');
    const duplicate = adapterFixture(); await duplicate.submit(); duplicate.response.markdown.append(duplicate.response.segment.cloneNode(true));
    const duplicated = await duplicate.run(); expect(duplicated.error).toBe('unsupported_response_format');
    const malformed = adapterFixture(); await malformed.submit(); malformed.response.code.text = '{"type":"tool_calls",';
    expect((await malformed.run()).text).toBe('{"type":"tool_calls",');
    const disguised = adapterFixture(); await disguised.submit();
    disguised.response.markdown.append(new disguised.Node('DIV', { class: 'toolcall-flow' }, 'Authored text using a similar class'));
    expect((await disguised.run()).error).toBe('unsupported_response_format');
    expect(disguised.response.markdown.textContent).toContain('Authored text using a similar class');
  });

  test('only structurally known website thinking/tool-flow nodes are excluded from final text', async () => {
    const f = adapterFixture(); const result = await f.submit();
    expect(result.text).not.toContain('Thinking complete');
    f.thoughtPart.append(new f.Node('DIV', { class: 'unknown-provider-widget' }, 'Unknown content must survive'));
    expect((await f.run()).error).toBe('unsupported_response_format');
    expect(f.thoughtPart.textContent).toContain('Unknown content must survive');
  });

  test('a transient code Copy tooltip is optional but extra header text is not silently discarded', async () => {
    const f = adapterFixture(); await f.submit();
    const tooltip = f.response.segment.querySelector('[role="tooltip"]')!;
    f.remove(tooltip);
    expect((await f.run()).text).toBe('{"type":"message","text":"Synthetic reply"}');
    f.response.segment.querySelector('header')!.append(new f.Node('SPAN', {}, 'Unknown header text'));
    expect((await f.run()).error).toBe('unsupported_response_format');
  });

  test('owned deletion performs header, Delete and confirmation once then verifies removal', async () => {
    const f = adapterFixture(); await f.submit(); const operation = f.operation();
    const first = await f.run('deleteConversation', { deleteOperation: operation }); expect(first.pending).toBe(true);
    expect(first.deleteProof).toMatchObject({ phase: 'menu', menuAcknowledged: true, deleteAcknowledged: false, confirmAcknowledged: false, nextActionReady: true });
    expect(f.header.clicks).toBe(1); expect(f.deleteRow.clicks).toBe(0); expect(f.counts().confirms).toBe(0);
    await f.run('observeDeletedConversation', { deleteOperation: operation });
    expect(f.deleteRow.clicks).toBe(0);
    const selected = await f.run('selectConversationDeletion', { deleteOperation: operation });
    expect(selected.deleteProof).toMatchObject({ phase: 'confirmation', deleteAcknowledged: true, confirmAcknowledged: false, nextActionReady: true });
    expect(f.deleteRow.clicks).toBe(1);
    await f.run('observeDeletedConversation', { deleteOperation: operation });
    expect(f.counts().confirms).toBe(0);
    const confirm = await f.run('confirmConversationDeletion', { deleteOperation: operation }); expect(confirm.pending).toBe(true);
    expect(confirm.deleteProof).toMatchObject({ phase: 'observing', confirmAcknowledged: true, conversationDeleted: false, nextActionReady: false });
    expect(confirm.url).toBe('https://www.kimi.ai/'); expect(confirm.userCount).toBeUndefined(); expect(confirm.text).toBeUndefined();
    expect(f.counts().confirms).toBe(1);
    const deleted = await f.run('observeDeletedConversation', { deleteOperation: operation });
    expect(deleted.deleteProof).toMatchObject({ ...operation, menuAcknowledged: true, deleteAcknowledged: true,
      confirmAcknowledged: true, conversationDeleted: true, remoteErasureVerified: false });
    expect(deleted).toMatchObject({ userCount: 0, responseCount: 0, busy: false });
    expect((await f.run('observeDeletedConversation', { deleteOperation: operation })).deleteProof.conversationDeleted).toBe(true);
    expect(f.counts()).toEqual({ insertions: 1, sends: 1, confirms: 1 });
  });

  test('owned streaming response may be deleted without pretending inference completed', async () => {
    const f = adapterFixture({ streaming: true }); expect((await f.submit()).answerComplete).toBe(false);
    const deleteOperation = f.operation();
    await f.run('deleteConversation', { deleteOperation }); await f.run('selectConversationDeletion', { deleteOperation });
    await f.run('confirmConversationDeletion', { deleteOperation });
    expect((await f.run('observeDeletedConversation', { deleteOperation })).deleteProof.conversationDeleted).toBe(true);
  });

  test('wrong operation or unbound first user cannot open a deletion menu', async () => {
    const wrong = adapterFixture(); await wrong.submit();
    const result = await wrong.run('deleteConversation', { deleteOperation: { ...wrong.operation(), conversationURL: canonical + '-wrong' } });
    expect(result.error).toBe('conversation_changed'); expect(wrong.header.clicks).toBe(0);
    const unbound = adapterFixture({ provisional: true }); await unbound.submit();
    const pending = await unbound.run('deleteConversation', { deleteOperation: unbound.operation() });
    expect(pending.ownershipPending).toBe(true); expect(unbound.header.clicks).toBe(0);
  });

  test('wrong confirmation, lost acknowledgement and retained history never become successful cleanup', async () => {
    const wrong = adapterFixture(); await wrong.submit(); const wrongOp = wrong.operation();
    await wrong.run('deleteConversation', { deleteOperation: wrongOp }); await wrong.run('selectConversationDeletion', { deleteOperation: wrongOp });
    wrong.confirmation.title.text = 'Delete all chats';
    expect((await wrong.run('confirmConversationDeletion', { deleteOperation: wrongOp })).error).toBe('conversation_changed');
    expect(wrong.counts().confirms).toBe(0);
    const uncertain = adapterFixture({ confirmationThrows: true }); await uncertain.submit(); const uncertainOp = uncertain.operation();
    await uncertain.run('deleteConversation', { deleteOperation: uncertainOp });
    await uncertain.run('selectConversationDeletion', { deleteOperation: uncertainOp });
    expect((await uncertain.run('confirmConversationDeletion', { deleteOperation: uncertainOp })).error).toBeDefined();
    expect((await uncertain.run('observeDeletedConversation', { deleteOperation: uncertainOp })).error).toBe('conversation_changed');
    expect(uncertain.counts().confirms).toBe(1);
    const retained = adapterFixture({ retainHistoryLink: true }); await retained.submit(); const retainedOp = retained.operation();
    await retained.run('deleteConversation', { deleteOperation: retainedOp }); await retained.run('selectConversationDeletion', { deleteOperation: retainedOp });
    await retained.run('confirmConversationDeletion', { deleteOperation: retainedOp });
    expect((await retained.run('observeDeletedConversation', { deleteOperation: retainedOp })).deleteProof.conversationDeleted).toBe(false);
  });

  test('stale source mutation before confirmation prevents destructive dispatch', async () => {
    const f = adapterFixture(); await f.submit(); const deleteOperation = f.operation();
    await f.run('deleteConversation', { deleteOperation }); await f.run('selectConversationDeletion', { deleteOperation });
    f.messages.userBody.text += ' changed';
    expect((await f.run('confirmConversationDeletion', { deleteOperation })).error).toBe('conversation_changed');
    expect(f.counts().confirms).toBe(0);
  });

  test('read-only cleanup observations wait for mounted controls and a real empty fresh composer', async () => {
    const f = adapterFixture(); await f.submit(); const deleteOperation = f.operation();
    await f.run('deleteConversation', { deleteOperation });
    f.deletionMenu.setAttribute('hidden', '');
    expect((await f.run('observeDeletedConversation', { deleteOperation })).deleteProof.nextActionReady).toBe(false);
    expect(f.deleteRow.clicks).toBe(0);
    f.deletionMenu.removeAttribute('hidden');
    expect((await f.run('observeDeletedConversation', { deleteOperation })).deleteProof.nextActionReady).toBe(true);
    await f.run('selectConversationDeletion', { deleteOperation });
    f.confirmation.mask.setAttribute('hidden', '');
    expect((await f.run('observeDeletedConversation', { deleteOperation })).deleteProof.nextActionReady).toBe(false);
    expect(f.counts().confirms).toBe(0);
    f.confirmation.mask.removeAttribute('hidden');
    expect((await f.run('observeDeletedConversation', { deleteOperation })).deleteProof.nextActionReady).toBe(true);
    await f.run('confirmConversationDeletion', { deleteOperation });
    f.remove(f.editor);
    const skeleton = await f.run('observeDeletedConversation', { deleteOperation });
    expect(skeleton.pending).toBe(true); expect(skeleton.deleteProof.conversationDeleted).toBe(false);
    expect(skeleton.composer).toBeUndefined();
    f.editor.connected = true; f.scope.append(f.editor);
    expect((await f.run('observeDeletedConversation', { deleteOperation })).deleteProof.conversationDeleted).toBe(true);
    expect(f.counts().confirms).toBe(1);
  });

  test('a not-ready claimed cleanup mutation fails instead of silently allowing another attempt', async () => {
    const f = adapterFixture(); await f.submit(); const deleteOperation = f.operation();
    await f.run('deleteConversation', { deleteOperation }); f.deletionMenu.setAttribute('hidden', '');
    expect((await f.run('selectConversationDeletion', { deleteOperation })).detail).toBe('delete_not_ready');
    f.deletionMenu.removeAttribute('hidden');
    expect((await f.run('selectConversationDeletion', { deleteOperation })).detail).toBe('terminal_operation');
    expect(f.deleteRow.clicks).toBe(0);
  });

  test('verification reopen checks the actual picker hit target before another click', async () => {
    const f = adapterFixture(); f.triggerName.text = 'K3.1 Pro';
    f.options[0].setAttribute('aria-checked', 'true'); f.options[2].setAttribute('aria-checked', 'false');
    await f.run('selectModel'); await f.run('selectModel'); f.occlude(f.trigger);
    expect((await f.run('selectModel')).error).toBe('model_unverified'); expect(f.trigger.clicks).toBe(1);
  });

  test('native cleanup inspection can recover the same unpublished first-body proof after format rejection', async () => {
    const f = adapterFixture({ delayedUser: true }); await f.submit(); f.appendUser();
    f.part.append(new f.Node('P', {}, 'Outside prose is not a valid envelope'));
    expect((await f.run()).error).toBe('unsupported_response_format'); expect(f.fingerprint).toBeUndefined();
    const recovered = await f.run('inspect', { kimiCleanupInspection: true });
    expect(recovered.firstUserVerified).toBe(true); expect(recovered.text).toBe(''); expect(recovered.answerComplete).toBe(false);
    expect((await f.run('verifyModel', { kimiCleanupInspection: true })).error).toBe('unsupported_response_format');
    const deleteOperation = f.operation();
    await f.run('deleteConversation', { deleteOperation }); await f.run('selectConversationDeletion', { deleteOperation });
    await f.run('confirmConversationDeletion', { deleteOperation });
    expect((await f.run('observeDeletedConversation', { deleteOperation })).deleteProof.conversationDeleted).toBe(true);
    expect(f.counts()).toEqual({ insertions: 1, sends: 1, confirms: 1 });
  });
  test('a long editor uses its ancestor-clipped visible point without scrolling or reinsertion', async () => {
    for (const transformed of [false, true]) {
      const f = adapterFixture(); await f.select(); await f.run('prepare'); await f.run('insert');
      const dx = transformed ? 11 : 0, dy = transformed ? 7 : 0, scale = transformed ? 0.9 : 1;
      const geometry = { left: 36 + dx, top: 208.5 + dy, width: 303 * scale, height: 170 * scale };
      f.editor.getBoundingClientRect = () => ({ left: geometry.left, top: geometry.top - 14731 * scale, width: geometry.width, height: 14904 * scale });
      f.scope.values.overflowY = 'auto'; f.scope.getBoundingClientRect = () => geometry;
      const fallback = f.document.elementFromPoint, points: number[][] = [];
      f.document.elementFromPoint = (x: number, y: number) => {
        if (x < 150) return fallback(x, y);
        points.push([x,y]); return x > geometry.left && x < geometry.left + geometry.width
          && y > geometry.top && y < geometry.top + geometry.height ? f.editor : f.body;
      };
      expect((await f.run('sendReady')).sendReady).toBe(true);
      expect(points).toEqual([[geometry.left + geometry.width/2, geometry.top + geometry.height/2]]);
      expect(f.counts()).toEqual({ insertions: 1, sends: 0, confirms: 0 });
      expect((await f.run('submit')).submitted).toBe(true); expect(f.counts().sends).toBe(1);
    }
  });

  test('clipping never grants readiness through occlusion, full clipping, invalid geometry or detached controls', async () => {
    for (const mode of ['overlay','fully-clipped','invalid-ancestor','detached','deep-ancestry']) {
      const f = adapterFixture(); await f.select(); await f.run('prepare'); await f.run('insert');
      f.editor.getBoundingClientRect = () => ({ left:36, top:-14522.5, width:303, height:14904 });
      f.scope.values.overflowY = 'auto'; f.scope.getBoundingClientRect = () => ({ left:36,
        top: mode === 'fully-clipped' ? 500 : 208.5, width:mode === 'invalid-ancestor' ? NaN : 303, height:170 });
      const fallback = f.document.elementFromPoint;
      f.document.elementFromPoint = (x: number, y: number) => x < 150 ? fallback(x,y) : mode === 'overlay' ? f.body : f.editor;
      if (mode === 'detached') f.remove(f.scope);
      if (mode === 'deep-ancestry') {
        const oldParent = f.scope.parentElement!; oldParent.children = oldParent.children.filter(node => node !== f.scope);
        let parent = oldParent;
        for (let n = 0; n < 65; n++) { const wrapper = new f.Node('DIV'); parent.append(wrapper); parent = wrapper; }
        parent.append(f.scope);
      }
      const result = await f.run('sendReady'); expect(result.error).toBeDefined();
      if (mode !== 'detached') expect(result).toMatchObject({ error:'composer_unavailable', detail:'editor_hit_' +
        ({ overlay:'occluded', 'fully-clipped':'outside_clip', 'invalid-ancestor':'invalid_geometry', 'deep-ancestry':'ancestor_limit' } as any)[mode] });
      expect(f.counts()).toEqual({ insertions:1, sends:0, confirms:0 });
    }
  });

  test('first-user diagnostics identify the original failing predicate without exposing content or allowing replay', async () => {
    for (const reason of ['first_body_count','first_root_hidden','first_root_id_invalid','first_turn_link_mismatch',
      'first_body_shape','first_submission_unclaimed','first_insertion_missing','first_full_echo_mismatch',
      'first_marker_invalid','first_marker_mismatch','first_marker_suffix','first_binding_not_authorized']) {
      const f = adapterFixture(); await f.select(); await f.run('prepare'); await f.run('insert'); await f.run('submit');
      const state = f.world.__computaKimiSavedSessionV1, overrides: Record<string,unknown> = {};
      if (reason === 'first_body_count') f.remove(f.messages.userBody);
      if (reason === 'first_root_hidden') f.messages.user.getClientRects = () => [];
      if (reason === 'first_root_id_invalid') f.messages.user.setAttribute('data-archer-id','PRIVATE_INVALID_ID');
      if (reason === 'first_turn_link_mismatch') f.messages.user.setAttribute('data-conversation-turn-id',marker);
      if (reason === 'first_body_shape') f.messages.userBody.append(new f.Node('A',{},'PRIVATE_LINK_TEXT'));
      if (reason === 'first_submission_unclaimed') { state.submitted = false; f.document.URL = 'https://www.kimi.ai/'; }
      if (reason === 'first_insertion_missing') state.inserted = null;
      if (reason === 'first_full_echo_mismatch') f.messages.userBody.text = f.messages.userBody.text.replace('Exact','Wrong');
      if (reason === 'first_marker_invalid') overrides.expectedFirstUserMarker = 'PRIVATE_INVALID_MARKER';
      if (reason === 'first_marker_mismatch') overrides.expectedFirstUserMarker = generation;
      if (reason === 'first_marker_suffix') { state.inserted.marker = generation; overrides.expectedFirstUserMarker = generation; }
      if (reason === 'first_binding_not_authorized') overrides.allowFirstUserBinding = false;
      const result = await f.run('inspect',overrides);
      expect(result).toEqual({error:reason === 'first_body_count' ? 'document_changed' : 'conversation_changed',detail:reason,
        ...(reason === 'first_root_id_invalid' ? { kimiFirstRootIDDiagnostic: {
          version: 1, routeKind: 'canonical', rootIDClass: 'other', turnIDClass: 'uuid', userCount: 1, assistantCount: 1,
        } } : {})});
      expect(JSON.stringify(result)).not.toContain('PRIVATE_'); expect(result.firstUserVerified).toBeUndefined();
      expect((await f.run('inspect')).detail).toBe(reason === 'first_submission_unclaimed' ? reason : 'terminal_operation');
      expect(f.counts()).toEqual({insertions:1,sends:1,confirms:0});
    }
  });

  test('invalid first-root IDs report only finite facts from the original rejected transcript', async () => {
    const cases = [
      { routeKind: 'fresh', root: '', turn: '', rootIDClass: 'empty', turnIDClass: 'empty', assistantCount: 0 },
      { routeKind: 'provisional', root: null, turn: '', rootIDClass: 'missing', turnIDClass: 'empty', assistantCount: 0 },
      { routeKind: 'provisional', root: '', turn: null, rootIDClass: 'empty', turnIDClass: 'missing', assistantCount: 0 },
      { routeKind: 'provisional', root: 'PRIVATE_ROOT_ID', turn: 'PRIVATE_TURN_ID', rootIDClass: 'other', turnIDClass: 'other', assistantCount: 0 },
      { routeKind: 'canonical', root: '', turn: marker, rootIDClass: 'empty', turnIDClass: 'uuid', assistantCount: 1 },
    ] as const;
    for (const { routeKind, root, turn, rootIDClass, turnIDClass, assistantCount } of cases) {
      const pending = routeKind !== 'canonical';
      const f = adapterFixture({ provisional: pending, optimisticUser: pending });
      await f.select(); await f.run('prepare'); await f.run('insert'); await f.run('submit');
      if (routeKind === 'fresh') f.document.URL = 'https://www.kimi.ai/';
      for (const [name, value] of [['data-archer-id', root], ['data-conversation-turn-id', turn]] as const) {
        if (value === null) f.messages.user.removeAttribute(name);
        else f.messages.user.setAttribute(name, value);
      }
      const result = await f.run();
      expect(result).toEqual({ error: 'conversation_changed', detail: 'first_root_id_invalid', kimiFirstRootIDDiagnostic: {
        version: 1, routeKind, rootIDClass, turnIDClass, userCount: 1, assistantCount,
      } });
      expect(JSON.stringify(result)).not.toContain('PRIVATE_');
      expect((await f.run()).detail).toBe('terminal_operation');
      expect(f.fingerprint).toBeUndefined();
      expect(f.counts()).toEqual({ insertions: 1, sends: 1, confirms: 0 });
    }
  });

  test('cleanup or a failed diagnostic read preserves the bare first-root rejection', async () => {
    for (const cleanup of [false, true]) {
      const f = adapterFixture();
      await f.select(); await f.run('prepare'); await f.run('insert'); await f.run('submit');
      const root = f.messages.user;
      root.removeAttribute('data-archer-id');
      const getAttribute = root.getAttribute.bind(root);
      let reads = 0;
      root.getAttribute = name => {
        if (name === 'data-conversation-turn-id') { reads++; throw new Error('PRIVATE_DIAGNOSTIC_EXCEPTION'); }
        return getAttribute(name);
      };
      expect(await f.run('inspect', { kimiCleanupInspection: cleanup }))
        .toEqual({ error: 'conversation_changed', detail: 'first_root_id_invalid' });
      expect(reads).toBe(cleanup ? 0 : 1);
      expect((await f.run()).detail).toBe('terminal_operation');
      expect(f.counts()).toEqual({ insertions: 1, sends: 1, confirms: 0 });
    }
  });

  test('digest and pinned-first-user diagnostics preserve exact physical and native fingerprint checks', async () => {
    for (const reason of ['first_changed_during_hash','first_pinned_identity_changed','first_pinned_fingerprint_mismatch',
      'first_expected_fingerprint_mismatch','first_disappeared']) {
      const f = adapterFixture(); await f.select(); await f.run('prepare'); await f.run('insert'); await f.run('submit');
      const overrides: Record<string,unknown> = {};
      if (reason === 'first_changed_during_hash') f.onDigest(() => { f.messages.userBody.text += 'PRIVATE_CHANGED_TEXT'; });
      else {
        expect((await f.run('inspect')).firstUserVerified).toBe(true);
        if (reason === 'first_pinned_identity_changed') f.messages.content.replaceChildren(f.messages.userBody.cloneNode(true));
        if (reason === 'first_pinned_fingerprint_mismatch') f.world.__computaKimiSavedSessionV1.first.fingerprint = '0'.repeat(64);
        if (reason === 'first_expected_fingerprint_mismatch') overrides.expectedFirstUserFingerprint = '0'.repeat(64);
        if (reason === 'first_disappeared') { f.remove(f.messages.user); f.remove(f.messages.answer); }
      }
      const result = await f.run('inspect',overrides);
      expect(result).toEqual({error:'conversation_changed',detail:reason}); expect(result.firstUserVerified).toBeUndefined();
      expect(JSON.stringify(result)).not.toContain('PRIVATE_');
      expect((await f.run('inspect')).detail).toBe('terminal_operation');
      expect(f.counts()).toEqual({insertions:1,sends:1,confirms:0});
    }
  });

});
