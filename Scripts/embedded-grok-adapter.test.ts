import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { composeGrokResource, grokResource } from './embedded-grok-resource';
import { grokFixture, grokGeneration, grokOwner, grokPrompt } from './embedded-grok-adapter-fixture';

describe('Grok private inference adapter', () => {
  test('standalone resource equals its canonical shared core, controls and driver', () => {
    expect(readFileSync(grokResource, 'utf8')).toBe(composeGrokResource());
  });

  test('only a native-granted initial absent shape yields negative hydration readiness', async () => {
    const f = grokFixture(), original = [...f.body.children]; original.forEach(node => node.remove());
    expect(await f.run('inspect', { allowGrokInitialHydration: true })).toEqual({ grokInitialHydrationPending: true, pending: true, composer: false });
    expect(f.f.sendCount).toBe(0); expect(f.f.privateCount).toBe(0); expect(f.f.pickerOpens).toBe(0);
    original.forEach(node => { node.connected = true; f.body.append(node); });
    expect(await f.run('inspect', { allowGrokInitialHydration: true })).toMatchObject({ composer: true, userCount: 0, temporary: false });
    expect(await f.submit()).toMatchObject({ submitted: true });
    expect(await f.run('inspect')).toMatchObject({ answerComplete: true });
    const noGrant = grokFixture(); [...noGrant.body.children].forEach(node => node.remove());
    expect(await noGrant.run('inspect')).toMatchObject({ error: 'composer_unavailable' });
  });

  test('late editor, model, Private or action controls may hydrate only before first readiness', async () => {
    for (const name of ['editor', 'trigger', 'privateToggle', 'send']) {
      const f = grokFixture(), node = f.f[name], parent = node.parentElement; node.remove();
      expect(await f.run('inspect', { allowGrokInitialHydration: true })).toEqual({ grokInitialHydrationPending: true, pending: true, composer: false });
      node.connected = true; parent.append(node);
      expect((await f.run('inspect', { allowGrokInitialHydration: true })).error).toBeUndefined();
      node.remove();
      const lost = await f.run('inspect', { allowGrokInitialHydration: true });
      expect(lost.grokInitialHydrationPending).toBeUndefined();
      // Losing the not-yet-requested Private switch is not a temporary proof;
      // its actual request still fails closed instead of waiting as hydration.
      if (name === 'privateToggle') expect(await f.run('enableTemporary')).toMatchObject({ error: 'temporary_mode_unavailable' });
      else expect(lost.error).toBeDefined();
    }
  });

  test('hidden, malformed, duplicate or nonempty initial controls are never hydration', async () => {
    const scenarios = [
      (f: ReturnType<typeof grokFixture>) => { f.f.editor.setAttribute('hidden', ''); },
      (f: ReturnType<typeof grokFixture>) => { f.f.editor.setAttribute('contenteditable', 'false'); },
      (f: ReturnType<typeof grokFixture>) => { f.body.append(f.f.editor.cloneNode(true)); },
      (f: ReturnType<typeof grokFixture>) => { f.body.append(f.f.trigger.cloneNode(true)); },
      (f: ReturnType<typeof grokFixture>) => { f.f.privateToggle.setAttribute('aria-pressed', 'true'); },
      (f: ReturnType<typeof grokFixture>) => { f.f.editor.textContent = 'existing draft'; },
      (f: ReturnType<typeof grokFixture>) => { f.f.appendUser('foreign transcript'); },
    ];
    for (const alter of scenarios) {
      const f = grokFixture(); alter(f);
      const result = await f.run('inspect', { allowGrokInitialHydration: true });
      expect(result.error).toBeDefined(); expect(result.grokInitialHydrationPending).toBeUndefined();
      expect(f.f.privateCount + f.f.sendCount + f.f.pickerOpens).toBe(0);
    }
  });

  test('the observed inaccessible measurement textarea is excluded without granting readiness', async () => {
    const f = grokFixture();
    expect(await f.run('inspect', { allowGrokInitialHydration: true })).toMatchObject({ composer: true, userCount: 0 });
    const absent = grokFixture();
    [...absent.body.children].filter(node => node !== absent.f.measurement).forEach(node => node.remove());
    expect(await absent.run('inspect', { allowGrokInitialHydration: true }))
      .toEqual({ grokInitialHydrationPending: true, pending: true, composer: false });
    expect(absent.f.privateCount + absent.f.sendCount + absent.f.pickerOpens).toBe(0);
  });

  test('visible, accessible, named or differently placed textareas remain competing editor failures', async () => {
    for (const alter of [
      (f: ReturnType<typeof grokFixture>) => { f.f.measurement.setAttribute('aria-label', 'Message Grok'); },
      (f: ReturnType<typeof grokFixture>) => { f.f.measurement.setAttribute('role', 'textbox'); },
      (f: ReturnType<typeof grokFixture>) => { f.f.measurement.setAttribute('tabindex', '0'); },
      (f: ReturnType<typeof grokFixture>) => { f.f.measurement.setAttribute('aria-hidden', 'false'); },
      (f: ReturnType<typeof grokFixture>) => { f.f.measurement.values.visibility = 'visible'; },
      (f: ReturnType<typeof grokFixture>) => { f.f.measurement.setAttribute('style', 'visibility:hidden;position:absolute;height:1px;z-index:-1000'); },
      (f: ReturnType<typeof grokFixture>) => { f.f.measurement.setAttribute('name', 'unrelated-visible-field'); },
      (f: ReturnType<typeof grokFixture>) => { f.f.form.append(f.f.measurement); },
    ]) {
      const f = grokFixture(); alter(f);
      expect(await f.run('inspect', { allowGrokInitialHydration: true })).toMatchObject({ error: 'composer_unavailable' });
      expect(f.f.privateCount + f.f.sendCount + f.f.pickerOpens).toBe(0);
    }
  });

  test('hydration grants cannot cover a different route or a prior model action', async () => {
    const foreign = grokFixture(); [...foreign.body.children].forEach(node => node.remove()); foreign.document.URL += '?unowned=1';
    expect(await foreign.run('inspect', { allowGrokInitialHydration: true })).toMatchObject({ error: 'document_changed' });
    const selected = grokFixture(); await selected.select(); selected.f.editor.remove();
    expect(await selected.run('inspect', { allowGrokInitialHydration: true })).toMatchObject({ error: 'composer_unavailable' });
  });

  test('composer failures report only the evaluated fixed branch without granting readiness', async () => {
    const scenarios: [string, boolean, (f: ReturnType<typeof grokFixture>) => void][] = [
      ['initial_editor_ambiguous', true, f => { f.body.append(f.f.editor.cloneNode(true)); }],
      ['initial_editor_no_rects', true, f => { f.f.editor.setAttribute('hidden', ''); }],
      ['initial_action_ambiguous', true, f => { f.body.append(new f.Node('BUTTON', { ...f.f.send.values })); }],
      ['initial_action_invalid', true, f => { f.f.send.setAttribute('aria-label', 'Unrecognized private text'); }],
      ['editor_missing', false, f => { f.f.editor.remove(); }],
      ['editor_ambiguous', false, f => { f.body.append(f.f.editor.cloneNode(true)); }],
      ['editor_authored', false, f => { f.f.form.setAttribute('contenteditable', 'true'); }],
      ['action_missing', false, f => { f.f.send.remove(); }],
      ['action_ambiguous', false, f => { f.body.append(new f.Node('BUTTON', { ...f.f.send.values })); }],
    ];
    for (const [detail, allowGrokInitialHydration, change] of scenarios) {
      const f = grokFixture(); change(f);
      const result = await f.run('inspect', { allowGrokInitialHydration });
      expect(result).toMatchObject({ error: 'composer_unavailable', detail });
      expect(Object.keys(result).sort()).toEqual((detail === 'initial_editor_no_rects'
        ? ['error', 'detail', 'grokInitialEditorDiagnostic'] : ['error', 'detail']).sort());
      expect(f.f.sendCount + f.f.privateCount + f.f.pickerOpens).toBe(0);
    }
  });

  test('initial editor failure separates exact predicates and retains only closed shape metadata', async () => {
    const scenarios: [string, (f: ReturnType<typeof grokFixture>) => void][] = [
      ['tag_textarea', f => { f.f.editor.remove(); f.f.form.append(new f.Node('TEXTAREA', { 'aria-label': 'Private draft text' })); }],
      ['tag_other', f => { f.f.editor.remove(); f.f.form.append(new f.Node('SPAN', { role: 'textbox' })); }],
      ['contenteditable', f => { f.f.editor.setAttribute('contenteditable', 'false'); }],
      ['role', f => { f.f.editor.setAttribute('role', 'other'); }],
      ['label', f => { f.f.editor.setAttribute('aria-label', 'Private draft text'); }],
      ['no_rects', f => { f.f.editor.setAttribute('hidden', ''); }],
      ['display_none', f => { f.f.editor.setAttribute('style', 'display:none'); }],
      ['visibility_hidden', f => { f.f.editor.values.visibility = 'hidden'; }],
      ['inert_ancestor', f => { f.f.form.setAttribute('inert', ''); }],
      ['aria_hidden_ancestor', f => { f.f.form.setAttribute('aria-hidden', 'true'); }],
      ['disabled', f => { f.f.editor.disabled = true; }],
      ['aria_disabled', f => { f.f.editor.setAttribute('aria-disabled', 'true'); }],
    ];
    for (const [reason, change] of scenarios) {
      const f = grokFixture(); change(f);
      const result = await f.run('inspect', { allowGrokInitialHydration: true });
      expect(result).toMatchObject({ error: 'composer_unavailable', detail: 'initial_editor_' + reason });
      const { version, tag, ...flags } = result.grokInitialEditorDiagnostic;
      expect(version).toBe(1); expect(['div', 'textarea', 'other']).toContain(tag);
      expect(Object.keys(flags).sort()).toEqual(['editable', 'role', 'label', 'connected', 'rects', 'displayNone',
        'visibilityHidden', 'hiddenAncestor', 'inertAncestor', 'ariaHiddenAncestor', 'disabled', 'ariaDisabled'].sort());
      expect(Object.values(flags).every(value => typeof value === 'boolean')).toBe(true);
      expect(JSON.stringify(result)).not.toContain('Private draft text');
      expect(f.f.sendCount + f.f.privateCount + f.f.pickerOpens).toBe(0);
    }
  });

  test('initial native intent is not mistaken for already-observed model proof', async () => {
    const f = grokFixture();
    expect(await f.run('inspect', { expectedModelChoice: { key: 'Fast', label: 'Fast' } }))
      .toMatchObject({ userCount: 0, modelEvidence: null, temporary: false });
    expect(f.f.send.getAttribute('aria-label')).toBe('Voice mode');
    expect(f.f.send.getAttribute('data-testid')).toBeNull();
    expect(await f.prepare()).toMatchObject({ inserted: true });
    expect(f.f.send.getAttribute('aria-label')).toBe('Send');
  });

  test('background insertion creates one collapsed caret in the owned editor', async () => {
    const f = grokFixture();
    expect(f.selection.anchorNode).toBeNull();
    expect(await f.prepare()).toMatchObject({ inserted: true });
    expect(f.selection.anchorNode).toBe(f.f.editor); expect(f.selection.focusNode).toBe(f.f.editor);
    expect(f.selection.isCollapsed).toBe(true); expect(f.document.insertCommandCount).toBe(1);
  });

  test('missing, foreign and noncollapsed carets cannot dispatch insertion', async () => {
    for (const scenario of ['missing', 'foreign', 'notCollapsed']) {
      const f = grokFixture();
      if (scenario === 'missing') f.window.getSelection = () => null;
      else if (scenario === 'foreign') f.selection.addRange = () => {
        f.selection.anchorNode = f.selection.focusNode = f.body; f.selection.isCollapsed = true;
      };
      else f.selection.addRange = () => {
        f.selection.anchorNode = f.selection.focusNode = f.f.editor; f.selection.isCollapsed = false;
      };
      expect(await f.prepare()).toMatchObject({ error: 'caret_unavailable' });
      expect(f.document.insertCommandCount).toBe(0); expect(f.f.editor.innerText).toBe(''); expect(f.f.sendCount).toBe(0);
    }
  });

  test('the public pilot returns only observed enabled Fast and never invents a missing row', async () => {
    const f = grokFixture(); let discovered: any;
    for (let step = 0; step < 4; step++) { discovered = await f.run('discoverModels'); if (!discovered.pending) break; }
    expect(discovered.modelChoices).toEqual([{ key: 'Fast', label: 'Fast' }]);
    expect(await f.run('selectModel', { modelChoice: { key: 'Expert', label: 'Expert' } })).toMatchObject({ error: 'model_unavailable' });
    const missing = grokFixture(); missing.f.choices = ['Expert']; missing.f.selected = 'Expert';
    missing.f.trigger.setAttribute('aria-label', 'Model: Expert');
    for (let step = 0; step < 4; step++) { discovered = await missing.run('discoverModels'); if (!discovered.pending) break; }
    expect(discovered).toMatchObject({ error: 'model_unavailable' });
  });

  test('observed Stop needs no invented Send attributes and can cancel only the owned verified inference', async () => {
    const f = grokFixture(); f.f.delayResponse = true; await f.submit();
    f.f.send.removeAttribute('data-testid'); f.f.send.removeAttribute('data-composer-action');
    expect(await f.run('inspect')).toMatchObject({ busy: true, answerComplete: false, firstUserVerified: true });
    expect(await f.run('stop')).toMatchObject({ stopped: true });
    expect(f.f.stopCount).toBe(1);
  });

  test('proves Private before single Send and binds completion to exact first body after the toggle disappears', async () => {
    const f = grokFixture();
    expect(await f.prepare()).toMatchObject({ inserted: true });
    const ready = await f.run('sendReady', { prompt: grokPrompt });
    expect(ready).toMatchObject({ sendReady: true, temporary: true, grokPrivateEvidence: {
      version: 1, source: 'current_private_control', ownerToken: grokOwner, documentGeneration: grokGeneration,
      url: 'https://grok.com/', sequence: 0, enteredBeforeSend: true, sendClaimed: false, contradictoryModeObserved: false,
    } });
    expect(await f.run('submit', { prompt: grokPrompt })).toMatchObject({ submitted: true });
    expect(f.f.privateToggle.isConnected).toBe(false);
    expect(await f.run('inspect')).toMatchObject({ userCount: 1, responseCount: 1, temporary: true,
      firstUserVerified: true, firstUserMarkerVerified: true, firstUserFingerprint: expect.stringMatching(/^[a-f0-9]{64}$/),
      text: f.f.reply, answerComplete: true, busy: false,
      grokPrivateEvidence: { source: 'submitted_private_provenance', sequence: 1, sendClaimed: true } });
    expect(f.f.sendCount).toBe(1); expect(f.f.privateCount).toBe(1);
  });

  test('a delayed first body withholds text and completion and never replays Send', async () => {
    const f = grokFixture(); f.f.delayUser = true;
    expect(await f.submit()).toMatchObject({ submitted: true });
    expect(await f.run('inspect')).toMatchObject({ userCount: 0, text: '', answerComplete: false, firstUserVerified: false });
    expect(await f.run('submit', { prompt: grokPrompt })).toMatchObject({ error: 'composer_unavailable' });
    f.f.appendUser(grokPrompt); f.f.finishResponse();
    expect(await f.run('inspect')).toMatchObject({ answerComplete: true, firstUserVerified: true });
    expect(f.f.sendCount).toBe(1);
  });

  test('missing, false or reintroduced contradictory Private controls fail closed', async () => {
    const before = grokFixture(); await before.prepare(); before.f.privateToggle.setAttribute('aria-pressed', 'false');
    expect(await before.run('sendReady', { prompt: grokPrompt })).toMatchObject({ error: 'temporary_mode_unverified' });
    expect(before.f.sendCount).toBe(0);
    const after = grokFixture(); await after.submit();
    const normal = new after.Node('BUTTON', { 'aria-label': 'Switch to Private Chat', 'aria-pressed': 'false' }); after.body.append(normal);
    expect(await after.run('inspect')).toMatchObject({ error: 'temporary_mode_unverified' });
  });

  test('a contradictory transition is latched even after its DOM attribute reverts', async () => {
    const f = grokFixture(); await f.prepare();
    f.observers.at(-1).records.push({ type: 'attributes', target: f.f.privateToggle, attributeName: 'aria-pressed', oldValue: 'false' });
    expect(await f.run('sendReady', { prompt: grokPrompt })).toMatchObject({ error: 'temporary_mode_unverified' });
    expect(await f.run('sendReady', { prompt: grokPrompt })).toMatchObject({ error: 'temporary_mode_unverified' });
    expect(f.f.sendCount).toBe(0);
  });

  test('private entry and uncertain submission are never repeated after missing acknowledgement', async () => {
    const f = grokFixture(); await f.select(); f.f.ignorePrivate = true;
    await f.run('enableTemporary'); expect(await f.run('enableTemporary')).toMatchObject({ error: 'temporary_mode_unverified' });
    expect(f.f.privateCount).toBe(1);
    const sent = grokFixture(); sent.f.ignoreSend = true; await sent.submit();
    expect(await sent.run('submit', { prompt: grokPrompt })).toMatchObject({ error: 'composer_unavailable' });
    expect(sent.f.sendCount).toBe(1);
  });

  test('same marker in a changed prompt, replaced body, changed URL or changed generation cannot bind', async () => {
    for (const change of [
      (f: ReturnType<typeof grokFixture>) => { f.f.userBody.textContent = 'changed ' + grokPrompt; },
      (f: ReturnType<typeof grokFixture>) => { f.document.URL = 'https://grok.com/c/fixture'; },
      (f: ReturnType<typeof grokFixture>) => { f.world.__computaGrokPrivateSessionV1.generation = 'other'; },
    ]) {
      const f = grokFixture(); await f.submit(); change(f);
      expect((await f.run('inspect')).error).toBeDefined();
    }
    const f = grokFixture(); await f.submit(); await f.run('inspect');
    f.f.userBody.textContent = 'changed ' + grokPrompt;
    expect(await f.run('inspect')).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
  });

  test('footer Copy, completion announcement and idle composer must agree on the owned response', async () => {
    for (const change of [
      (f: ReturnType<typeof grokFixture>) => { f.f.copy.remove(); },
      (f: ReturnType<typeof grokFixture>) => { f.f.status.children[0].textContent = ''; },
      (f: ReturnType<typeof grokFixture>) => { f.f.send.setAttribute('aria-label', 'Stop'); },
      (f: ReturnType<typeof grokFixture>) => { f.f.editor.textContent = 'unsent'; },
      (f: ReturnType<typeof grokFixture>) => { f.body.append(f.f.footer); },
    ]) {
      const f = grokFixture(); await f.submit(); change(f);
      expect(await f.run('inspect')).toMatchObject({ text: '', answerComplete: false });
    }
  });

  test('hash-yield mutations cannot preserve stale completion or first-message proof', async () => {
    const busy = grokFixture(); await busy.submit();
    busy.onDigest(() => { busy.f.send.setAttribute('aria-label', 'Stop'); });
    expect(await busy.run('inspect')).toMatchObject({ text: '', answerComplete: false });
    const changed = grokFixture(); await changed.submit();
    changed.onDigest(() => { changed.f.userBody.textContent = 'changed ' + grokPrompt; });
    expect(await changed.run('inspect')).toMatchObject({ error: 'conversation_changed' });
  });

  test('extra authored prose or interactive code descendants cannot become literal tool responses', async () => {
    const prose = grokFixture(); await prose.submit(); prose.f.answer.append(new prose.Node('P', {}, 'extra prose'));
    expect(await prose.run('inspect')).toMatchObject({ error: 'unsupported_response_format', detail: 'grok_extra_text' });
    const interactive = grokFixture(); await interactive.submit(); interactive.f.code.append(new interactive.Node('BUTTON', {}, 'Run'));
    expect(await interactive.run('inspect')).toMatchObject({ error: 'unsupported_response_format', detail: 'grok_code_structure' });
  });

  test('only the observed JSON and Copy-code header is excluded from authored-content checks', async () => {
    for (const alter of [
      (f: ReturnType<typeof grokFixture>) => { f.f.card.append(new f.Node('P', {}, 'extra authored prose')); },
      (f: ReturnType<typeof grokFixture>) => { f.f.card.append(new f.Node('#text', {}, 'extra authored text')); },
      (f: ReturnType<typeof grokFixture>) => { f.f.card.children[0].append(new f.Node('SPAN', {}, 'extra authored prose')); },
      (f: ReturnType<typeof grokFixture>) => { f.f.card.children[0].append(new f.Node('BUTTON', { 'aria-label': 'Unrelated action' })); },
      (f: ReturnType<typeof grokFixture>) => { f.f.card.children[0].children[0].textContent = 'Other language'; },
    ]) {
      const f = grokFixture(); await f.submit(); alter(f);
      expect(await f.run('inspect')).toMatchObject({ error: 'unsupported_response_format' });
    }
  });
});
