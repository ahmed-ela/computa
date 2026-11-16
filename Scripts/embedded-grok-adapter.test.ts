import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { composeGrokResource, grokResource } from './embedded-grok-resource';
import { grokFixture, grokGeneration, grokOwner, grokPrompt } from './embedded-grok-adapter-fixture';

describe('Grok private inference adapter', () => {
  test('standalone resource equals its canonical shared core, controls and driver', () => {
    expect(readFileSync(grokResource, 'utf8')).toBe(composeGrokResource());
  });

  test('Private activation reports fixed unavailable and hit reasons without clicking', async () => {
    const scenarios: [string, (f: ReturnType<typeof grokFixture>) => void][] = [
      ['private_control_missing', f => { f.f.privateToggle.remove(); }],
      ['private_control_shape', f => { f.f.privateToggle.setAttribute('aria-pressed', 'unknown'); }],
      ['private_control_hit_disabled', f => { f.f.privateToggle.disabled = true; }],
      ['private_control_hit_invalid_geometry', f => { f.f.privateToggle.rect.width = 0; }],
      ['private_control_hit_outside_viewport', f => { f.f.privateToggle.rect.left = -200; }],
      ['private_control_hit_occluded', f => { f.blockHit(true); }],
    ];
    for (const [detail, alter] of scenarios) {
      const f = grokFixture(); alter(f);
      expect(await f.run('enableTemporary')).toEqual({ error: 'temporary_mode_unavailable', detail });
      expect(f.f.privateCount).toBe(0); expect(f.f.sendCount).toBe(0);
    }
    const f = grokFixture(); f.blockHit(true);
    expect(await f.run('inspect')).toMatchObject({ temporary: false, temporaryActionAvailable: false });
    expect(await f.run('enableTemporary')).toEqual({ error: 'temporary_mode_unavailable', detail: 'private_control_hit_occluded' });
    expect(f.f.privateCount).toBe(0); expect(f.f.sendCount).toBe(0);
  });

  test('Private readiness waits for a scoped layout wake and rereads before one activation', async () => {
    const f = grokFixture(); f.blockHit(true);
    expect(await f.run('inspect')).toMatchObject({ temporary: false, temporaryActionAvailable: false });
    expect(f.document.layoutListenerCount()).toBe(4);
    f.document.emitLayout('transitionend', f.f.trigger);
    expect(f.posted).toHaveLength(0); expect(f.document.layoutListenerCount()).toBe(4);
    f.document.emitLayout('transitionend', f.f.privateToggle);
    expect(f.posted).toHaveLength(1); expect(f.document.layoutListenerCount()).toBe(0);
    expect(await f.run('inspect')).toMatchObject({ temporaryActionAvailable: false });
    expect(f.f.privateCount).toBe(0);
    f.blockHit(false); f.document.emitLayout('animationend', f.body);
    expect(f.posted).toHaveLength(2); expect(f.document.layoutListenerCount()).toBe(0);
    expect(await f.run('inspect')).toMatchObject({ temporaryActionAvailable: true });
    expect(await f.run('enableTemporary')).toMatchObject({ enabled: false });
    expect(await f.run('inspect')).toMatchObject({ temporary: true, temporaryActionAvailable: false });
    expect(f.f.privateCount).toBe(1); expect(f.f.sendCount).toBe(0);
  });

  test('Private layout wakes reject stale owner, generation, document, route and action claims', async () => {
    const changes: ((f: ReturnType<typeof grokFixture>) => void)[] = [
      f => { f.world.__computaModelOwner = grokGeneration; },
      f => { f.world.__computaGrokPrivateSessionV1.generation = grokOwner; },
      f => { f.world.__computaGrokPrivateSessionV1.document = {}; },
      f => { f.document.URL = 'https://grok.com/c/unowned'; },
      f => { f.world.__computaGrokPrivateSessionV1.toggleClaimed = true; },
      f => { f.world.__computaGrokPrivateSessionV1.privateEntered = true; },
      f => { f.world.__computaGrokPrivateSessionV1.submitted = true; },
      f => { f.f.privateToggle.remove(); },
    ];
    for (const change of changes) {
      const f = grokFixture(); f.blockHit(true); await f.run('inspect'); change(f);
      f.document.emitLayout('transitioncancel', f.body);
      expect(f.posted).toHaveLength(0); expect(f.document.layoutListenerCount()).toBe(0);
      expect(f.f.privateCount).toBe(0); expect(f.f.sendCount).toBe(0);
    }
  });

  test('Private pending reads replace listeners, and an occlusion after readiness still rejects the action', async () => {
    const f = grokFixture(); f.blockHit(true);
    for (let read = 0; read < 3; read++) {
      expect(await f.run('inspect')).toMatchObject({ temporaryActionAvailable: false });
      expect(f.document.layoutListenerCount()).toBe(4); expect(f.f.privateCount).toBe(0);
    }
    f.blockHit(false);
    expect(await f.run('inspect')).toMatchObject({ temporaryActionAvailable: true });
    expect(f.document.layoutListenerCount()).toBe(0);
    f.blockHit(true);
    expect(await f.run('enableTemporary')).toEqual({ error: 'temporary_mode_unavailable', detail: 'private_control_hit_occluded' });
    expect(f.document.layoutListenerCount()).toBe(0); expect(f.f.privateCount).toBe(0);
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

  test('an initial plain empty textarea carries only negative readiness until the observed DIV mounts', async () => {
    const f = grokFixture(), editor = f.f.editor;
    editor.remove(); const placeholder = new f.Node('TEXTAREA', { 'aria-label': 'Initial input' });
    (placeholder as any).value = ''; f.f.form.append(placeholder);
    for (let read = 0; read < 2; read++) {
      expect(await f.run('inspect', { allowGrokInitialHydration: true }))
        .toEqual({ grokInitialHydrationPending: true, pending: true, composer: false });
      expect(f.f.sendCount + f.f.privateCount + f.f.pickerOpens).toBe(0);
    }
    placeholder.remove(); editor.connected = true; f.f.form.append(editor);
    expect(await f.run('inspect', { allowGrokInitialHydration: true })).toMatchObject({ composer: true, userCount: 0, temporary: false });
    expect(await f.submit()).toMatchObject({ submitted: true });
    expect(await f.run('inspect')).toMatchObject({ answerComplete: true });
  });

  test('textarea hydration never hides a draft, expected-editor identity, disabled or competing control', async () => {
    for (const mutate of [
      (node: any) => { node.value = 'existing typed draft'; },
      (node: any) => { node.textContent = 'existing default draft'; },
      (node: any) => { node.setAttribute('aria-label', 'Message Grok'); },
      (node: any) => { node.setAttribute('role', 'textbox'); },
      (node: any) => { node.setAttribute('contenteditable', 'true'); },
      (node: any) => { node.disabled = true; },
      (node: any) => { node.setAttribute('aria-disabled', 'true'); },
      (node: any) => { node.setAttribute('hidden', ''); },
    ]) {
      const f = grokFixture(); f.f.editor.remove();
      const placeholder = new f.Node('TEXTAREA'); f.f.form.append(placeholder); mutate(placeholder);
      const before = [placeholder.textContent, (placeholder as any).value];
      const result = await f.run('inspect', { allowGrokInitialHydration: true });
      expect(result.error).toBeDefined(); expect(result.grokInitialHydrationPending).toBeUndefined();
      expect([placeholder.textContent, (placeholder as any).value]).toEqual(before);
      expect(f.f.sendCount + f.f.privateCount + f.f.pickerOpens).toBe(0);
    }
    const competing = grokFixture(); competing.f.form.append(new competing.Node('TEXTAREA'));
    expect(await competing.run('inspect', { allowGrokInitialHydration: true }))
      .toMatchObject({ error: 'composer_unavailable', detail: 'initial_editor_ambiguous' });
  });

  test('a textarea cannot restart hydration without the initial grant or after model or Private claims', async () => {
    for (const stage of ['ungranted', 'ready', 'model', 'private']) {
      const f = grokFixture();
      if (stage === 'ready') await f.run('inspect', { allowGrokInitialHydration: true });
      if (stage === 'model') await f.select();
      if (stage === 'private') await f.run('enableTemporary');
      f.f.editor.remove(); f.f.form.append(new f.Node('TEXTAREA'));
      const result = await f.run('inspect', { allowGrokInitialHydration: stage !== 'ungranted' });
      expect(result).toMatchObject({ error: 'composer_unavailable' });
      expect(result.grokInitialHydrationPending).toBeUndefined(); expect(f.f.sendCount).toBe(0);
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
      ['tag_textarea', f => { f.f.editor.remove(); f.f.form.append(new f.Node('TEXTAREA', { 'aria-label': 'Message Grok' })); }],
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
    expect(f.document.pasteDispatchCount).toBe(0);
  });

  test('one escaped-text HTML edit preserves large multiline literals without executable markup', async () => {
    const f = grokFixture(), literal = '  repeated  spaces\tTabbed\r\n\r\nUnicode 🌍 e\u0301 中文\r<literal data-value="&<>">text</literal> &amp; &lt;b&gt; \\n \\path\\file\n';
    const prompt = literal.repeat(700) + grokPrompt;
    expect(new TextEncoder().encode(prompt).length).toBeGreaterThan(65536);
    expect(await f.submit(prompt)).toMatchObject({ submitted: true });
    expect(f.document.pasteDispatchCount).toBe(0); expect(f.document.insertCommandCount).toBe(1);
    expect(f.f.sendCount).toBe(1);
    expect(f.f.lastPrompt).toBe(prompt.replace(/\r\n?/g, '\n'));
    expect(f.document.lastInsertHTML.match(/<[^>]*>/g).every((tag: string) => tag === '<br>')).toBe(true);
    expect(f.document.lastInsertHTML).toContain('&lt;literal data-value="&amp;&lt;&gt;"&gt;');
    expect(f.document.lastInsertHTML).toContain('&amp;amp; &amp;lt;b&amp;gt;');
    expect(f.f.editor.querySelectorAll('literal')).toHaveLength(0);
    expect(await f.run('inspect')).toMatchObject({ firstUserVerified: true, answerComplete: true });
  });

  test('rejected, unconfirmed, partial, delayed or replaced edits never fall back or replay', async () => {
    for (const behavior of ['rejected', 'unconfirmed', 'noop', 'partial', 'delayed', 'replaced']) {
      const f = grokFixture(); let commit: (() => void) | null = null;
      const original = f.document.execCommand;
      f.document.execCommand = (command: string, ui: boolean, html: string) => {
        if (behavior === 'rejected' || behavior === 'noop' || behavior === 'delayed') {
          f.document.insertCommandCount++;
          if (behavior === 'delayed') commit = () => { f.f.editor.textContent = grokPrompt; f.f.editor.oninput?.(); };
          return behavior !== 'rejected';
        }
        const result = original(command, ui, html);
        if (behavior === 'partial') f.f.editor.textContent = f.f.editor.textContent.slice(0, -1);
        if (behavior === 'replaced') {
          const replacement = new f.Node('DIV', { ...f.f.editor.values }); replacement.textContent = grokPrompt;
          f.f.editor.remove(); f.f.form.append(replacement);
        }
        return behavior === 'unconfirmed' ? false : result;
      };
      const failed = await f.prepare();
      expect(failed).toMatchObject({ error: ['rejected', 'unconfirmed'].includes(behavior) ? 'insert_command_rejected' : 'prompt_not_inserted' });
      expect(f.document.pasteDispatchCount).toBe(0); expect(f.document.insertCommandCount).toBe(1); expect(f.f.sendCount).toBe(0);
      if (commit) (commit as () => void)();
      expect((await f.run('insert', { prompt: grokPrompt })).error).toBeDefined();
      expect(f.document.pasteDispatchCount).toBe(0); expect(f.document.insertCommandCount).toBe(1); expect(f.f.sendCount).toBe(0);
    }
  });

  test('an editing exception cannot replay or fall back to another primitive', async () => {
    const f = grokFixture();
    f.document.execCommand = () => { f.document.insertCommandCount++; throw new Error('synthetic editing failure'); };
    await expect(f.prepare()).rejects.toThrow('synthetic editing failure');
    expect((await f.run('insert', { prompt: grokPrompt })).error).toBeDefined();
    expect(f.document.pasteDispatchCount).toBe(0); expect(f.document.insertCommandCount).toBe(1); expect(f.f.sendCount).toBe(0);
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
      expect(f.document.insertCommandCount).toBe(0); expect(f.document.pasteDispatchCount).toBe(0);
      expect(f.f.editor.innerText).toBe(''); expect(f.f.sendCount).toBe(0);
    }
  });

  test('Grok editor hit intersects ancestor scrollports before one deterministic point', async () => {
    const f = grokFixture(); expect(await f.prepare()).toMatchObject({ inserted: true });
    const clip: any = new f.Node('DIV', { style: 'overflow:auto' });
    clip.rect = { left: 20, top: 300, width: 620, height: 100 };
    Object.assign(clip, { clientLeft: 1, clientTop: 1, clientWidth: 618, clientHeight: 98 });
    f.f.editor.remove(); f.f.editor.connected = true; clip.append(f.f.editor); f.f.form.append(clip);
    f.f.editor.rect = { left: 24, top: -1600, width: 600, height: 2000 };
    const points: number[][] = [], original = f.document.elementFromPoint;
    f.document.elementFromPoint = (x: number, y: number) => {
      if (x > 300) { points.push([x, y]); return y >= 301 && y <= 399 ? f.f.editor : f.body; }
      return original(x, y);
    };
    expect((await f.run('sendReady', { prompt: grokPrompt })).sendReady).toBe(true);
    expect(points).toEqual([[324, 350]]);
    points.length = 0;
    f.document.elementFromPoint = (x: number, y: number) => { if (x > 300) { points.push([x, y]); return f.body; } return original(x, y); };
    expect(await f.run('submit', { prompt: grokPrompt })).toMatchObject({ error: 'composer_unavailable', detail: 'editor_hit_test' });
    expect(points).toEqual([[324, 350]]); expect(f.f.sendCount).toBe(0);
  });

  test('uncertain or empty ancestor clips never grant editor hit readiness', async () => {
    for (const mode of ['empty', 'invalid', 'transform', 'clip_path', 'paint', 'changed_after_ready']) {
      const f = grokFixture(); expect(await f.prepare()).toMatchObject({ inserted: true });
      const clip: any = new f.Node('DIV', { style: 'overflow:auto' });
      clip.rect = { left: 0, top: 0, width: 100, height: 30 };
      Object.assign(clip, { clientLeft: 0, clientTop: 0, clientWidth: 100, clientHeight: 30 });
      f.f.editor.remove(); f.f.editor.connected = true; clip.append(f.f.editor); f.f.form.append(clip);
      f.document.elementFromPoint = () => f.f.editor;
      if (mode === 'changed_after_ready') {
        // Test geometry helper through the full edit guard; Send is independently
        // hit-tested and therefore intentionally not advertised by this stub.
        const ready = await f.run('sendReady', { prompt: grokPrompt }); expect(ready.error).toBeUndefined();
      }
      if (mode === 'empty' || mode === 'changed_after_ready') clip.clientHeight = 0;
      if (mode === 'invalid') clip.clientWidth = Number.NaN;
      if (mode === 'transform') clip.setAttribute('style', 'overflow:auto;transform:translateX(1px)');
      if (mode === 'clip_path') clip.setAttribute('style', 'overflow:auto;clip-path:inset(1px)');
      if (mode === 'paint') clip.setAttribute('style', 'overflow:auto;contain:paint');
      expect(await f.run('sendReady', { prompt: grokPrompt })).toMatchObject({ error: 'composer_unavailable', detail: 'editor_hit_test' });
      expect(f.f.sendCount).toBe(0);
    }
  });

  test('hidden unbound transcript is only pending and replacement binds only after reveal', async () => {
    const f = grokFixture(); f.f.messages.setAttribute('style', 'visibility:hidden');
    expect(await f.submit()).toMatchObject({ submitted: true });
    let hashed = false; f.onDigest(() => { hashed = true; });
    const grant = { allowGrokTranscriptRenderingPending: true };
    expect(await f.run('inspect', grant)).toEqual({ grokTranscriptRenderingPending: true });
    expect(hashed).toBe(false); expect(f.world.__computaGrokPrivateSessionV1.first).toBeNull();
    const prior = f.f.user;
    f.f.user.remove(); f.f.responseParent.remove(); f.f.appendUser(f.f.lastPrompt); f.f.finishResponse();
    expect(f.f.user).not.toBe(prior);
    expect(await f.run('inspect', grant)).toEqual({ grokTranscriptRenderingPending: true });
    expect(hashed).toBe(false); expect(f.world.__computaGrokPrivateSessionV1.first).toBeNull();
    f.f.messages.setAttribute('style', 'visibility:visible');
    expect(await f.run('inspect', grant)).toMatchObject({ firstUserVerified: true, answerComplete: true });
    expect(hashed).toBe(true); expect(f.world.__computaGrokPrivateSessionV1.first.root).toBe(f.f.user);
    expect(f.f.sendCount).toBe(1); expect(f.document.insertCommandCount).toBe(1);
    f.f.messages.setAttribute('style', 'visibility:hidden');
    expect((await f.run('inspect', grant)).error).toBeDefined();
  });

  test('hidden first user without an answer may wait but can expose no authority', async () => {
    const f = grokFixture(); f.f.delayResponse = true; f.f.messages.setAttribute('style', 'visibility:hidden');
    expect(await f.submit()).toMatchObject({ submitted: true });
    for (let i = 0; i < 3; i++) {
      expect(await f.run('inspect', { allowGrokTranscriptRenderingPending: true })).toEqual({ grokTranscriptRenderingPending: true });
      expect(f.world.__computaGrokPrivateSessionV1.first).toBeNull();
    }
    expect(f.f.sendCount).toBe(1); expect(f.document.insertCommandCount).toBe(1);
  });

  test('transcript rendering wait refuses unowned, changed or differently hidden structures', async () => {
    for (const arm of ['no_grant', 'wrong_action', 'unclaimed', 'wrong_counts', 'fingerprint', 'payload',
      'duplicate_user', 'duplicate_answer', 'role', 'log', 'duplicate_log', 'display_none', 'hidden', 'inert',
      'aria_hidden', 'no_layout', 'authored', 'mixed_visibility', 'missing_body', 'duplicate_body', 'model', 'private']) {
      const f = grokFixture(); f.f.messages.setAttribute('style', 'visibility:hidden');
      expect(await f.submit()).toMatchObject({ submitted: true });
      const overrides: any = { allowGrokTranscriptRenderingPending: true };
      if (arm === 'no_grant') overrides.allowGrokTranscriptRenderingPending = false;
      if (arm === 'unclaimed') f.world.__computaGrokPrivateSessionV1.submitted = false;
      if (arm === 'wrong_counts') overrides.expectedUserCounts = [1];
      if (arm === 'fingerprint') overrides.expectedFirstUserFingerprint = '0'.repeat(64);
      if (arm === 'payload') f.f.userBody.textContent += ' changed';
      if (arm === 'duplicate_user') f.f.appendUser(f.f.lastPrompt);
      if (arm === 'duplicate_answer') f.f.finishResponse();
      if (arm === 'role') f.f.user.setAttribute('role', 'group');
      if (arm === 'log') f.f.messages.removeAttribute('data-testid');
      if (arm === 'duplicate_log') f.body.append(new f.Node('DIV', { role: 'log', 'data-testid': 'chat-transcript-scroller' }));
      if (arm === 'display_none') f.f.user.setAttribute('style', 'display:none');
      if (['hidden', 'inert', 'aria_hidden'].includes(arm)) f.f.messages.setAttribute(arm === 'aria_hidden' ? 'aria-hidden' : arm, arm === 'aria_hidden' ? 'true' : '');
      if (arm === 'no_layout') f.f.user.getClientRects = () => [];
      if (arm === 'authored') f.f.messages.setAttribute('contenteditable', 'false');
      if (arm === 'mixed_visibility') f.f.answer.setAttribute('style', 'visibility:visible');
      if (arm === 'missing_body') f.f.userBody.remove();
      if (arm === 'duplicate_body') f.f.user.append(new f.Node('SPAN', { 'data-bubble-text': '' }, f.f.lastPrompt));
      if (arm === 'model') f.f.trigger.setAttribute('aria-label', 'Model: Expert');
      if (arm === 'private') f.body.append(new f.Node('BUTTON', { 'aria-label': 'Switch to Private Chat', 'aria-pressed': 'false' }));
      const result = await f.run(arm === 'wrong_action' ? 'verifyModel' : 'inspect', overrides);
      expect(result.error).toBeDefined(); expect(result.grokTranscriptRenderingPending).toBeUndefined();
      expect(f.world.__computaGrokPrivateSessionV1.first).toBeNull();
      expect(f.f.sendCount).toBe(1); expect(f.document.insertCommandCount).toBe(1);
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

  test('first-body diagnostics distinguish literal mismatch from rendered blank-line changes', async () => {
    for (const arm of ['content', 'blank_lines', 'whitespace', 'rendered_only']) {
      const f = grokFixture(); expect(await f.submit()).toMatchObject({ submitted: true });
      const expected = f.f.lastPrompt;
      if (arm === 'rendered_only') Object.defineProperty(f.f.userBody, 'innerText', { get: () => expected.replace('\n\n', '\n\n\n') });
      else f.f.userBody.textContent = arm === 'content' ? expected.replace('Return', 'Foreign')
        : arm === 'whitespace' ? expected.replace('a synthetic', 'a  synthetic') : expected.replace('\n\n', '\n\n\n');
      const failed = await f.run('inspect');
      expect(failed).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
      const d = failed.grokFirstUserFailureDiagnostic;
      expect(d).toMatchObject({ version: 1, stage: 'before_hash', reason: 'payload_text', users: 1, answers: 1,
        bodies: 1, bodyVisible: true, expectedUTF16: expected.length, innerTextMatches: false,
        textContentMatches: arm === 'rendered_only', textDifference: arm === 'content' ? 'other' : arm === 'whitespace' ? 'whitespace' : 'blank_lines', identity: 'not_checked' });
      expect(Object.keys(d).sort()).toEqual(['version','stage','reason','users','answers','bodies','bodyVisible',
        'observedUTF16','expectedUTF16','observedLines','expectedLines','textContentMatches','innerTextMatches','textDifference','identity','mismatch'].sort());
      expect(JSON.stringify(d)).not.toContain(expected); expect(JSON.stringify(d)).not.toContain('Computa session marker');
      expect(f.world.__computaGrokPrivateSessionV1.first).toBeNull(); expect(f.f.sendCount).toBe(1);
    }
  });

  test('first-body shape and hash-yield identity diagnostics keep the original rejection', async () => {
    for (const arm of ['missing', 'duplicate', 'hidden', 'root', 'body', 'parent']) {
      const f = grokFixture(); expect(await f.submit()).toMatchObject({ submitted: true });
      if (arm === 'missing') f.f.userBody.remove();
      if (arm === 'duplicate') f.f.user.append(new f.Node('SPAN', { 'data-bubble-text': '' }, f.f.lastPrompt));
      if (arm === 'hidden') f.f.userBody.setAttribute('style', 'visibility:hidden');
      if (['root', 'body', 'parent'].includes(arm)) f.onDigest(() => {
        if (arm === 'root') { f.f.user.remove(); f.f.appendUser(f.f.lastPrompt); }
        if (arm === 'body') { f.f.userBody.remove(); f.f.userBody = new f.Node('SPAN', { 'data-bubble-text': '' }, f.f.lastPrompt); f.f.user.append(f.f.userBody); }
        if (arm === 'parent') {
          f.f.user.remove(); f.f.user.connected = true;
          const parent = new f.Node('DIV'); parent.append(f.f.user); f.f.messages.append(parent);
        }
      });
      const failed = await f.run('inspect');
      expect(failed).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
      const d = failed.grokFirstUserFailureDiagnostic;
      expect(d.stage).toBe(['root','body','parent'].includes(arm) ? 'after_hash' : 'entry');
      expect(d.reason).toBe(['root','body','parent'].includes(arm) ? 'node_identity' : arm === 'hidden' ? 'body_visibility' : 'body_count');
      expect(d.identity).toBe(['root','body','parent'].includes(arm) ? arm + '_changed' : 'not_checked');
      expect(f.world.__computaGrokPrivateSessionV1.first).toBeNull(); expect(f.f.sendCount).toBe(1);
    }
  });

  test('a hash-yield root replacement reports its literal mismatch without binding or replaying', async () => {
    const f = grokFixture(); expect(await f.submit()).toMatchObject({ submitted: true });
    const expected = f.f.lastPrompt;
    f.onDigest(() => { f.f.user.remove(); f.f.appendUser(expected.slice(14)); });
    const failed = await f.run('inspect');
    expect(failed).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message',
      grokFirstUserFailureDiagnostic: { stage:'after_hash', reason:'node_identity', identity:'root_changed',
        expectedUTF16:expected.length, observedUTF16:expected.length-14, innerTextMatches:false,
        textContentMatches:false, textDifference:'other', mismatch:{ offset:0, line:1, column:1, component:'unknown' } } });
    const d = failed.grokFirstUserFailureDiagnostic;
    expect(d.expectedLines).toBe(d.observedLines);
    expect(JSON.stringify(d)).not.toContain(expected);
    expect(f.world.__computaGrokPrivateSessionV1.first).toBeNull();
    expect(f.f.sendCount).toBe(1);
    expect(await f.run('submit', { prompt:grokPrompt })).toMatchObject({ error:'conversation_changed' });
    expect(f.f.sendCount).toBe(1);
  });

  test('fingerprint diagnostic does not reveal either expected or observed hash', async () => {
    const f = grokFixture(); expect(await f.submit()).toMatchObject({ submitted: true });
    const failed = await f.run('inspect', { expectedFirstUserFingerprint: '0'.repeat(64) });
    expect(failed).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message',
      grokFirstUserFailureDiagnostic: { stage: 'after_hash', reason: 'fingerprint', identity: 'stable',
        textDifference: 'none', textContentMatches: true, innerTextMatches: true } });
    expect(JSON.stringify(failed.grokFirstUserFailureDiagnostic)).not.toContain('0'.repeat(64));
    expect(f.world.__computaGrokPrivateSessionV1.first).toBeNull(); expect(f.f.sendCount).toBe(1);
  });

  test('diagnostic metadata is bounded and unreadable metadata cannot replace its original failure', () => {
    const source = readFileSync(new URL('./embedded-grok-first-user-diagnostic.js', import.meta.url), 'utf8');
    const fail = new Function('c','state','transcript', source + '\nreturn computaGrokFirstUserFailure(c,state,"before_hash","payload_text",transcript);');
    const core = { bodyText: (text: string) => text.trim(), visible: () => true };
    let error: any;
    try { fail(core, { prompt: 'owned' }, { users: [], answers: [], bodies: [], text: 'x'.repeat(230000) }); } catch (e) { error = e; }
    expect(error).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message',
      grokFirstUserFailureDiagnostic: { observedUTF16: 220001, observedLines: null, innerTextMatches: null, textDifference: 'unavailable' } });
    expect(error.grokFirstUserFailureDiagnostic.mismatch).toBeUndefined();
    try { fail(core, { prompt: 'owned' }, { body: { get innerText() { throw Error('PRIVATE_DIAGNOSTIC_FAILURE'); } } }); } catch (e) { error = e; }
    expect(error).toEqual({ computaAdapterFailure: true, error: 'conversation_changed', detail: 'first_user_message' });
  });

  test('literal mismatch locations identify fixed prompt sections without emitting any text', () => {
    const source = readFileSync(new URL('./embedded-grok-first-user-diagnostic.js', import.meta.url), 'utf8');
    const fail = new Function('c','state','transcript','reason', source + '\nreturn computaGrokFirstUserFailure(c,state,"before_hash",reason,transcript);');
    const core = { bodyText: (text: string) => text.trim(), visible: () => true };
    const parts = ['COMPUTA_CURRENT_RUNTIME_CONTRACT:', 'runtime sentinel', 'COMPLETE_RESPONSES_REQUEST_JSON:',
      '{"value":"request sentinel"}', 'COMPUTA_CURRENT_USER_LOCATOR:', 'current sentinel',
      'COMPUTA_LOCAL_RESPONSE_HANDOFF:', 'Literal `a` `b` `c` `d` `e` `f` `g`.', 'Computa session marker: marker sentinel'];
    const expected = parts.join('\n');
    const diagnostic = (prompt: string, observed: string, reason = 'payload_text') => {
      try { fail(core, { prompt }, { text: observed }, reason); } catch (e: any) {
        expect(e).toMatchObject({ computaAdapterFailure: true, error: 'conversation_changed', detail: 'first_user_message' });
        return e.grokFirstUserFailureDiagnostic;
      }
    };
    const changed = expected.replace(/`/g, '');
    const d = diagnostic(expected, changed), m = d.mismatch;
    expect(m).toEqual({ offset: expected.indexOf('`'), line: 8, column: 9, component: 'response',
      lastExpectedLine: 8, lastObservedLine: 8, expectedFirstLineLength: parts[7].length,
      observedFirstLineLength: parts[7].length - 14, expectedLastLineLength: parts[7].length,
      observedLastLineLength: parts[7].length - 14, expectedFirstKind: 'prose', observedFirstKind: 'prose',
      expectedLastKind: 'prose', observedLastKind: 'prose', nearBackticksExpected: 14,
      nearBackticksObserved: 0, nearBackslashesExpected: 0, nearBackslashesObserved: 0 });
    expect(d.expectedUTF16 - d.observedUTF16).toBe(14);
    expect(d.expectedLines).toBe(d.observedLines);
    expect(JSON.stringify(d)).not.toContain('sentinel');
    for (const [find, component, line] of [['runtime sentinel','runtime',2], ['request sentinel','request',4],
      ['current sentinel','current_user',6], ['marker sentinel','marker',9]] as const) {
      expect(diagnostic(expected, expected.replace(find, 'changed')).mismatch).toMatchObject({ component, line });
    }
    expect(diagnostic(expected + '\nCOMPUTA_LOCAL_RESPONSE_HANDOFF:', changed + '\nCOMPUTA_LOCAL_RESPONSE_HANDOFF:').mismatch.component).toBe('unknown');
    expect(diagnostic(expected, expected).mismatch).toBeUndefined();
    expect(diagnostic(expected, changed, 'fingerprint').mismatch).toEqual(m);
  });

  test('mismatch coordinates stay bounded at first-byte, newline, Unicode and length boundaries', () => {
    const source = readFileSync(new URL('./embedded-grok-first-user-diagnostic.js', import.meta.url), 'utf8');
    const fail = new Function('c','state','transcript', source + '\nreturn computaGrokFirstUserFailure(c,state,"before_hash","payload_text",transcript);');
    const core = { bodyText: (text: string) => text.trim(), visible: () => true };
    for (const [expected, observed, coordinates] of [
      ['abc','xbc',{ offset:0,line:1,column:1 }], ['abc\ndef','abcX\ndef',{ offset:3,line:1,column:4 }],
      ['abc\ndef','abc\nXdef',{ offset:4,line:2,column:1 }], ['abc','abcd',{ offset:3,line:1,column:4 }],
      ['abcd','abc',{ offset:3,line:1,column:4 }], ['', 'x', { offset:0,line:1,column:1 }],
      ['x', '', { offset:0,line:1,column:1 }], ['🧪a\nb','🧪x\nb',{ offset:2,line:1,column:3 }],
    ] as const) {
      let d: any;
      try { fail(core, { prompt:expected }, { text:observed }); } catch (e: any) { d = e.grokFirstUserFailureDiagnostic; }
      expect(d.mismatch).toMatchObject({ ...coordinates, component:'unknown' });
      expect(d.mismatch.offset).toBeLessThanOrEqual(Math.min(d.expectedUTF16,d.observedUTF16));
      expect(d.mismatch.column).toBeLessThanOrEqual(Math.min(d.mismatch.expectedFirstLineLength,d.mismatch.observedFirstLineLength)+1);
      expect(d.mismatch.lastExpectedLine).toBeLessThanOrEqual(d.expectedLines);
      expect(d.mismatch.lastObservedLine).toBeLessThanOrEqual(d.observedLines);
      expect(d.mismatch.nearBackticksExpected).toBeLessThanOrEqual(64);
      expect(d.mismatch.nearBackslashesObserved).toBeLessThanOrEqual(64);
    }
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
