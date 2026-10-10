import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { firstMarker, markerLine, installObservedModelPicker } from './embedded-provider-adapter-fixture';

export function defineWebsiteModelChoiceTests(provider: 'chatgpt' | 'gemini' | 'claude', make: (owned?: boolean) => any, Node: any) {
  const target = provider === 'chatgpt' ? 'GPT-5.5' : provider === 'gemini' ? '3.8 Flash' : 'Sonnet 4.6';
  const initial = provider === 'chatgpt' ? 'GPT-5.6 Sol' : provider === 'gemini' ? '3.1 Pro' : 'Sonnet 5.5';
  const choice = (label: string) => ({ key: label, label });
  const setup = (owned = false, behavior: { genericHeader?: boolean; unmountMenus?: boolean; replacePrimaryOnSecondary?: boolean;
    geminiMenuitemMarkers?: boolean; escapeOnlyClose?: boolean; inlineFamilyPanel?: boolean; parentReturnAfterSelection?: boolean } = {}) => {
    const f = make(owned);
    if (provider === 'chatgpt') f.composer.focus = () => { f.document.activeElement = f.composer; };
    return { f, picker: installObservedModelPicker(f, provider, Node, behavior) };
  };
  const advance = async (f: any, action: string, overrides: Record<string, unknown> = {}) => {
    let result: any;
    for (let step = 0; step < 6; step++) {
      result = await f.run(action, overrides);
      if (!result.pending) return result;
    }
    return result;
  };
  const replaceFirstRoot = (f: any, originalRoot: any, originalBody: any) => {
    let replacementBody: any;
    const clone = (node: any): any => {
      const copy = new Node(node.tagName, { ...node.values }, node.text);
      if (node === originalBody) replacementBody = copy;
      copy.append(...node.children.map(clone)); return copy;
    };
    const root = clone(originalRoot), parent = originalRoot.parentElement;
    parent.children[parent.children.indexOf(originalRoot)] = root; root.parentElement = parent;
    originalRoot.connected = false; originalRoot.parentElement = null;
    return { root, body: replacementBody, parent };
  };
  const firstRoot = (f: any) => provider === 'chatgpt' ? f.userBody.parentElement : f.userRoot;
  describe(`${provider} exact website model choices`, () => {
    test('standalone adapter embeds the audited shared model-control source exactly', () => {
      const helper = readFileSync(new URL('./embedded-model-choice-helper.js', import.meta.url), 'utf8');
      const source = readFileSync(new URL(`../Sources/Computa/Resources/BrowserModels/${provider}.js`, import.meta.url), 'utf8');
      expect(source.startsWith(helper + '\n')).toBe(true);
    });

    test('discovery exposes enabled family leaves and excludes descriptions, effort and upgrades', async () => {
      const { f, picker } = setup();
      const result = await advance(f, 'discoverModels');
      const expected = provider === 'chatgpt' ? ['GPT-5.6 Sol', 'GPT-5.5']
        : provider === 'gemini' ? ['3.5 Flash-Lite', '3.8 Flash', '3.1 Pro']
          : ['Sonnet 5.5', 'Haiku 4.5', 'Sonnet 5', 'Sonnet 4.6'];
      expect(result.modelChoices).toEqual(expected.map(choice));
      expect(result.modelChoices.some((item: any) => /Medium|thinking|Upgrade|Leaving|answers|reasoning|help/.test(item.label))).toBe(false);
      expect(picker.options.reduce((sum: number, option: any) => sum + option.clicks, 0)).toBe(0);
      expect(picker.trigger.clicks).toBeLessThanOrEqual(2);
      if (picker.secondary) expect(picker.secondary.clicks).toBe(1);
      expect((await f.run('discoverModels')).modelChoices).toEqual(result.modelChoices);
      expect(picker.trigger.clicks).toBeLessThanOrEqual(2);
    });

    if (provider === 'chatgpt') test('discovery excludes enabled Latest while preserving its baseline for switching to Sol', async () => {
      const { f, picker } = setup();
      picker.selected('Latest');
      const latest = picker.options.find((option: any) => option.children[0].text === 'Latest');
      expect(latest.values['aria-disabled']).toBeUndefined();
      expect(picker.primary.text).toBe('Latest');
      const result = await advance(f, 'discoverModels');
      expect(result.modelChoices).toEqual(['GPT-5.6 Sol', 'GPT-5.5'].map(choice));
      expect(result.modelEvidence.selected).toEqual(choice('Latest'));
      expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      expect((await f.run('discoverModels')).modelChoices).toEqual(result.modelChoices);
      const switched = await advance(f, 'selectModel', { modelChoice: choice(initial) });
      expect(switched).toMatchObject({ selected: true, modelEvidence: { selected: choice(initial) } });
      expect(latest.clicks).toBe(0);
      expect(picker.options.find((option: any) => option.children[0].text === initial).clicks).toBe(1);
    });

    test('one exact choice is clicked once and reinspection confirms its website label', async () => {
      const { f, picker } = setup();
      const result = await advance(f, 'selectModel', { modelChoice: choice(target) });
      expect(result).toMatchObject({ selected: true, modelEvidence: { selected: choice(target), verification: 'website_selection' } });
      const selected = picker.options.find((option: any) => option.children[0].text === target);
      expect(selected.clicks).toBe(1);
      expect((await f.run('verifyModel', { expectedModelChoice: choice(target) })).modelEvidence.selected).toEqual(choice(target));
      expect(await f.run('selectModel', { modelChoice: choice(target) })).toMatchObject({ selected: true });
      expect(selected.clicks).toBe(1);
      expect(picker.options.reduce((sum: number, option: any) => sum + option.clicks, 0)).toBe(1);
    });

    test('picker hydration waits for events without clicking or treating composer readiness as model proof', async () => {
      const { f, picker } = setup(); picker.trigger.connected = false;
      for (let step = 0; step < 3; step++) {
        const result = await f.run('discoverModels');
        expect(result).toMatchObject({ pending: true, modelDiagnostic: { triggerCount: 0, triggerCandidates: [] } });
      }
      expect(picker.trigger.clicks).toBe(0);
      picker.trigger.connected = true;
      expect((await advance(f, 'discoverModels')).modelChoices.length).toBeGreaterThan(0);
      expect(picker.trigger.clicks).toBeLessThanOrEqual(2);
    });

    test('successful discovery retains bounded menu-shape evidence before it closes the picker', async () => {
      const { f, picker } = setup();
      const result = await advance(f, 'discoverModels');
      expect(result.modelDiagnostic.triggerCount).toBe(1);
      expect(result.modelDiagnostic.associatedMenus.every((menu: any) => menu.visible)).toBe(true);
      expect(result.modelDiagnostic.candidates.some((candidate: any) => candidate.primaryFamily === initial)).toBe(true);
      expect(result.modelDiagnostic.rawFamilySummary.some((candidate: any) => candidate.primaryFamily === initial)).toBe(true);
      expect(JSON.stringify(result.modelDiagnostic).length).toBeLessThanOrEqual(8192);
      expect(picker.menu.values.hidden).toBe('');
    });

    if (provider === 'gemini') test('Gemini mode triggers support the observed label without an optional brand', async () => {
      for (const label of ['Open mode picker, currently Pro', 'Open mode picker, currently Flash',
        'Open mode picker, currently 3.1 Pro', 'Open mode picker, currently Gemini Pro']) {
        const { f, picker } = setup(); picker.trigger.values['aria-label'] = label;
        const result = await advance(f, 'discoverModels');
        expect(result.modelChoices).toEqual(['3.5 Flash-Lite', '3.8 Flash', '3.1 Pro'].map(choice));
        expect(result.modelDiagnostic.triggerCount).toBe(1);
        expect(result.modelDiagnostic.triggerCandidates[0].safeLabel).toBe(label);
        expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      }
    });

    if (provider === 'claude') test('the observed Haiku Extended effort suffix verifies the same family and is not a model choice', async () => {
      const { f, picker } = setup(); picker.selected('Haiku 4.5');
      picker.trigger.values['aria-label'] = 'Model: Haiku 4.5 Extended';
      expect((await f.run('verifyModel', { expectedModelChoice: choice('Haiku 4.5') })).modelEvidence.selected).toEqual(choice('Haiku 4.5'));
      const result = await advance(f, 'discoverModels');
      expect(result.modelDiagnostic.triggerCandidates[0].safeLabel).toBe('Model: Haiku 4.5 Extended');
      expect(result.modelChoices.some((model: any) => model.label.includes('Extended'))).toBe(false);
      picker.trigger.values['aria-label'] = 'Model: Haiku 4.5 PRIVATE EFFORT';
      expect((await f.run('verifyModel', { expectedModelChoice: choice('Haiku 4.5') })).error).toBe('model_unverified');
    });

    if (provider === 'gemini') {
      test('observed menuitem Selected icons and selected classes prove Gemini choices without radio attributes', async () => {
        const discovery = setup(false, { genericHeader: true, unmountMenus: true, geminiMenuitemMarkers: true });
        expect((await advance(discovery.f, 'discoverModels')).modelChoices)
          .toEqual(['3.5 Flash-Lite', '3.8 Flash', '3.1 Pro'].map(choice));
        const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true, geminiMenuitemMarkers: true });
        expect(await advance(f, 'selectModel', { modelChoice: choice(target) })).toMatchObject({ selected: true,
          modelEvidence: { selected: choice(target), source: 'selected_model_indicator', verification: 'website_selection' } });
        const selected = picker.options.find((option: any) => option.children[0].text === target);
        expect(selected.clicks).toBe(1);
        expect((await f.run('verifyModel', { expectedModelChoice: choice(target) })).modelEvidence.source).toBe('selected_model_indicator');
        picker.selected(initial);
        expect((await f.run('verifyModel', { expectedModelChoice: choice(target) })).error).toBe('model_mismatch');
        expect(selected.clicks).toBe(1);
      });

      test('Gemini active and focused rows never override the separate Selected marker', async () => {
        const { f, picker } = setup(false, { genericHeader: true, geminiMenuitemMarkers: true });
        picker.options[0].values.class = 'ng-star-inserted active focused';
        expect((await f.run('verifyModel', { expectedModelChoice: choice(initial) })).modelEvidence)
          .toMatchObject({ selected: choice(initial), source: 'selected_model_indicator' });
        expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      });

      test('Gemini missing, duplicate, hidden and contradictory Selected indicators fail closed', async () => {
        for (const change of [
          (p: any, selected: any, marker: any) => { selected.children = selected.children.filter((node: any) => node !== marker); },
          (p: any, selected: any, marker: any) => { marker.values.hidden = ''; },
          (p: any, selected: any, marker: any) => { marker.values['aria-hidden'] = 'true'; },
          (p: any, selected: any) => { selected.append(new Node('GEM-ICON', { 'aria-label': 'Selected' })); },
          (p: any, selected: any) => { selected.values.class = 'ng-star-inserted focused'; },
          (p: any, selected: any) => { selected.values['aria-checked'] = 'false'; },
          (p: any, selected: any) => { selected.values['aria-selected'] = 'true'; },
          (p: any) => { p.options[0].values.class = 'selected'; p.options[0].append(new Node('GEM-ICON', { 'aria-label': 'Selected' })); },
          (p: any) => { p.options[0].append(new Node('GEM-ICON', { 'aria-label': 'Selected' })); },
          (p: any, selected: any) => { selected.children[0].text = 'Unknown family'; },
        ]) {
          const { f, picker } = setup(false, { genericHeader: true, geminiMenuitemMarkers: true }); picker.open();
          const selected = picker.options.find((option: any) => option.children[0].text === initial);
          const marker = selected.children.find((node: any) => node.values['aria-label'] === 'Selected');
          change(picker, selected, marker);
          expect((await f.run('verifyModel', { expectedModelChoice: choice(initial) })).error).toBe('model_unverified');
          expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
        }
      });
    }

    if (provider === 'claude') test('nested navigation labels survive decorative SVG content but need their own popup association', async () => {
      const { f, picker } = setup();
      const name = provider === 'chatgpt' ? 'Select model' : 'More models';
      delete picker.secondary.values['aria-label']; picker.secondary.values.role = 'menuitem';
      picker.secondary.append(new Node('SPAN', {}, name), new Node('SVG', {}, 'Decorative arrow text'));
      const result = await advance(f, 'discoverModels');
      expect(result.modelChoices.some((model: any) => model.label === target)).toBe(true);
      expect(picker.secondary.clicks).toBe(1);
      const ambiguous = setup(); ambiguous.picker.open();
      const second = new Node('DIV', { role: 'menuitem', 'aria-haspopup': 'menu' }); second.append(new Node('SPAN', {}, name));
      ambiguous.picker.menu.append(second);
      expect((await ambiguous.f.run('discoverModels')).error).toBe('model_unverified');
      expect(second.clicks).toBe(0); expect(ambiguous.picker.secondary.clicks).toBe(0);
      const detached = setup(); detached.picker.open();
      delete detached.picker.secondary.values['aria-haspopup'];
      expect(((await advance(detached.f, 'discoverModels')).modelChoices || []).some((model: any) => model.label === target)).toBe(false);
      expect(detached.picker.secondary.clicks).toBe(0);
    });

    test('diagnostic trigger labels expose only finite provider mode grammar', async () => {
      const { f, picker } = setup();
      const prefix = provider === 'chatgpt' ? 'Select ChatGPT model ' : provider === 'gemini' ? 'Open mode picker, currently ' : 'Model: ';
      picker.trigger.values['aria-label'] = prefix + 'PRIVATE ACCOUNT SENTINEL';
      let result = await f.run('modelDiagnostic');
      expect(result.modelDiagnostic.triggerCount).toBe(0);
      expect(result.modelDiagnostic.triggerCandidates[0].safeLabel).toBe(null);
      expect(JSON.stringify(result.modelDiagnostic)).not.toContain('PRIVATE');
      picker.trigger.values['aria-label'] = provider === 'chatgpt' ? 'Select ChatGPT model ' + '0'.repeat(10000)
        : provider === 'gemini' ? 'Open mode picker, currently ' + '0'.repeat(10000) + ' Pro' : 'Model: Sonnet ' + '0'.repeat(10000);
      result = await f.run('modelDiagnostic');
      expect(result.modelDiagnostic.triggerCount).toBe(0);
      expect(result.modelDiagnostic.triggerCandidates[0].safeLabel).toBe(null);
      expect(JSON.stringify(result.modelDiagnostic).length).toBeLessThanOrEqual(8192);
      expect(picker.trigger.clicks).toBe(0);
    });

    test('raw option diagnostics recognize nested family containers without granting selection authority', async () => {
      const { f, picker } = setup(); picker.open();
      const row = new Node('DIV', { role: 'menuitem', 'data-state': 'checked', 'aria-selected': 'true' });
      const label = new Node('DIV');
      const split = Math.floor(target.length / 2);
      label.append(new Node('SPAN', {}, target.slice(0, split)), new Node('SPAN', {}, target.slice(split)));
      const marker = new Node('SVG', { 'aria-label': 'Selected', 'data-account-id': 'PRIVATE ACCOUNT' });
      row.append(label, marker, new Node('SPAN', {}, 'PRIVATE DESCRIPTION'));
      picker.menu.children.forEach((child: any) => { child.connected = false; });
      picker.menu.children = []; picker.menu.text = ''; picker.menu.append(row);
      if (picker.nested) picker.nested.values.hidden = '';
      const result = await f.run('modelDiagnostic');
      expect(result.modelDiagnostic.rawOptionCount).toBe(1);
      expect(result.modelDiagnostic.rawOptions[0]).toMatchObject({ role: 'menuitem', primaryFamily: null,
        checkedAttribute: null, dataState: 'checked', recognizedContainers: [{ family: target, childElementCount: 2 }],
        selectedMarkers: [{ tag: 'svg', kind: 'selected_label' }] });
      expect(result.modelDiagnostic.rawFamilySummary).toEqual([{ role: 'menuitem', primaryFamily: null,
        recognizedFamily: target, visible: true, enabled: true, checkedAttribute: null, dataState: 'checked', selectedMarkerCount: 1 }]);
      expect(JSON.stringify(result.modelDiagnostic)).not.toContain('PRIVATE');
      expect(['model_unavailable', 'model_unverified']).toContain((await f.run('selectModel', { modelChoice: choice(target) })).error);
      expect(row.clicks).toBe(0);
    });

    test('a Selected icon and presentation data cannot prove a generic-header family choice', async () => {
      const { f, picker } = setup(false, { genericHeader: true }); picker.open();
      for (const option of picker.options) delete option.values['aria-checked'];
      const other = picker.options.find((option: any) => option.children[0].text === target);
      other.values['data-state'] = 'checked'; other.append(new Node('SVG', { 'aria-label': 'Selected' }));
      expect((await f.run('verifyModel', { expectedModelChoice: choice(target) })).error).toBe('model_unverified');
      expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
    });

    test('an already selected choice needs no click and a later drift is rejected', async () => {
      const { f, picker } = setup();
      expect(await f.run('selectModel', { modelChoice: choice(initial) })).toMatchObject({ selected: true });
      expect(picker.trigger.clicks).toBe(0);
      picker.selected(target);
      expect(await f.run('selectModel', { modelChoice: choice(initial) })).toMatchObject({ error: 'model_mismatch' });
      expect(picker.trigger.clicks).toBe(0);
    });

    test('strict model drift blocks every editor action before any click or insertion', async () => {
      const { f, picker } = setup();
      for (const action of ['prepare', 'insert', 'sendReady', 'submit', 'inspect', 'verifyModel']) {
        const result = await f.run(action, { expectedModelChoice: choice(target), prompt: 'PRIVATE PROMPT SENTINEL' });
        expect(result).toMatchObject({ error: 'model_mismatch', modelEvidence: { selected: choice(initial) } });
        expect(result.text).toBeUndefined();
        expect(JSON.stringify(result)).not.toContain('PRIVATE PROMPT SENTINEL');
      }
      expect(picker.trigger.clicks).toBe(0);
      expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      if (f.send) expect(f.send.clicks).toBe(0);
      expect(f.composer.textContent).toBe('');
    });

    test('missing, hidden, inert or message-authored picker cannot verify exact models', async () => {
      for (const change of [
        (f: any, p: any) => { p.trigger.connected = false; },
        (f: any, p: any) => { p.trigger.values.hidden = ''; },
        (f: any, p: any) => { p.trigger.values.inert = ''; },
        (f: any, p: any) => { p.trigger.values['aria-hidden'] = 'true'; },
        (f: any, p: any) => { f.body.children = f.body.children.filter((node: any) => node !== p.trigger); f.answer.append(p.trigger); },
      ]) {
        const { f, picker } = setup(true); change(f, picker);
        const result = await f.run('inspect', { expectedModelChoice: choice(initial) });
        expect(result).toMatchObject({ error: 'model_unverified' });
        expect(result.text).toBeUndefined(); expect(picker.trigger.clicks).toBe(0);
      }
    });

    test('duplicate visible pickers and conflicting checked model evidence fail closed', async () => {
      const first = setup();
      installObservedModelPicker(first.f, provider, Node);
      expect(await first.f.run('inspect', { expectedModelChoice: choice(initial) })).toMatchObject({ error: 'model_unverified' });
      const { f, picker } = setup(); picker.open();
      picker.options.forEach((option: any) => { option.values['aria-checked'] = option.children[0].text === target ? 'true' : 'false'; });
      expect(await f.run('inspect', { expectedModelChoice: choice(initial) })).toMatchObject({ error: 'model_unverified' });
      expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      picker.options.forEach((option: any) => { option.values['aria-checked'] = 'true'; });
      expect((await f.run('verifyModel', { expectedModelChoice: choice(initial) })).error).toBe('model_unverified');
    });

    test('focus and presentation selection never substitute for the checked model radio', async () => {
      const { f, picker } = setup(); picker.open();
      const other = picker.options.find((option: any) => option.children[0].text === target);
      other.values.class = 'selected focused'; other.values['data-state'] = 'checked'; other.values['aria-current'] = 'true';
      other.values['aria-selected'] = 'true';
      const result = await f.run('verifyModel', { expectedModelChoice: choice(initial) });
      expect(result.modelEvidence.selected).toEqual(choice(initial));
      expect(other.clicks).toBe(0);
    });

    test('lost primary and target-choice acknowledgments never replay any clicked stage', async () => {
      const primary = setup();
      primary.picker.trigger.onClick = () => { throw new Error('lost primary acknowledgment'); };
      await expect(primary.f.run('selectModel', { modelChoice: choice(target) })).rejects.toThrow('lost primary');
      for (let i = 0; i < 3; i++) expect(await primary.f.run('selectModel', { modelChoice: choice(target) })).toMatchObject({ pending: true });
      expect(primary.picker.trigger.clicks).toBe(1);
      const { f, picker } = setup(); picker.open();
      const selected = picker.options.find((option: any) => option.children[0].text === target);
      selected.onClick = () => { throw new Error('lost choice acknowledgment'); };
      await expect(f.run('selectModel', { modelChoice: choice(target) })).rejects.toThrow('lost choice');
      for (let i = 0; i < 3; i++) {
        const observing = f.run('selectModel', { modelChoice: choice(target) });
        if (provider === 'chatgpt') for (let tick = 0; tick < 8; tick++) { await Promise.resolve(); f.flush(); }
        const rejected = await observing;
        expect(provider === 'chatgpt' ? ['model_unverified', 'model_mismatch'] : ['model_mismatch']).toContain(rejected.error);
        expect(rejected.selected).toBeUndefined();
      }
      expect(selected.clicks).toBe(1);
      expect(picker.options.reduce((sum: number, option: any) => sum + option.clicks, 0)).toBe(1);
    });

    test('unavailable, disabled and duplicate exact choices are never clicked', async () => {
      for (const change of [
        (p: any) => { p.options.find((option: any) => option.children[0].text === target).disabled = true; },
        (p: any) => { p.options.find((option: any) => option.children[0].text === target).values['aria-disabled'] = 'true'; },
        (p: any) => { p.options.find((option: any) => option.children[0].text === target).append(new Node('SPAN', {}, 'Upgrade')); },
        (p: any) => { p.add(p.nested || p.menu, target); },
      ]) {
        const { f, picker } = setup(); picker.open(); change(picker);
        const result = await f.run('selectModel', { modelChoice: choice(target) });
        expect(['model_unavailable', 'model_unverified']).toContain(result.error);
        expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      }
    });

    test('unknown or malformed native choices cannot be coerced from label-only matches', async () => {
      for (const malformed of [null, { key: initial }, { key: initial, label: target }, { key: initial, label: initial, extra: true },
        { key: ' ' + initial, label: initial }, { key: initial, label: initial + ' ' }, { key: initial, label: '' },
        { key: 'x'.repeat(161), label: initial }]) {
        const { f, picker } = setup();
        const result = await advance(f, 'selectModel', { modelChoice: malformed });
        expect(['model_unverified', 'model_unavailable']).toContain(result.error);
        expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      }
    });

    test('unassociated menus provide structure diagnostics but never model choice authority', async () => {
      const { f, picker } = setup();
      delete picker.trigger.values['aria-controls']; delete picker.menu.values['aria-labelledby']; picker.open();
      const result = await f.run('discoverModels');
      expect(result.modelChoices).toBeUndefined();
      expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      const next = await f.run('discoverModels');
      expect(next).toMatchObject({ error: 'model_unverified' });
      expect(next.modelDiagnostic.unassociatedMenus.length).toBeGreaterThan(0);
      expect(next.modelDiagnostic.unassociatedMenus.every((menu: any) => menu.primaryFamily === null)).toBe(true);
    });

    test('response prose cannot grant attribution and ordinary inspections never reopen pickers', async () => {
      const { f, picker } = setup(true);
      f.answer.append(new Node('SPAN', {}, 'I am ' + target));
      for (let i = 0; i < 3; i++) {
        const result = await f.run('inspect', { expectedModelChoice: choice(initial) });
        expect(result.modelEvidence).toMatchObject({ selected: choice(initial), verification: 'website_selection' });
        expect(result.modelEvidence.response).toBeUndefined();
        expect(result.modelEvidence.source).toBe('model_picker_label');
      }
      expect(picker.trigger.clicks).toBe(0);
    });

    test('a digest yield cannot admit a response after the website model changed', async () => {
      const { f, picker } = setup(true);
      f.onDigest(() => picker.selected(target));
      expect(await f.run('inspect', { expectedModelChoice: choice(initial) })).toMatchObject({ error: 'model_mismatch' });
      expect(picker.trigger.clicks).toBe(0);
    });

    test('the final concrete verification must observe current temporary mode after its picker await', async () => {
      const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
      const click = picker.trigger.onClick; let opens = 0;
      picker.trigger.onClick = () => {
        const opening = picker.menu.values.hidden !== undefined; click();
        if (opening && ++opens === (provider === 'chatgpt' ? 1 : 2)) {
          if (provider === 'chatgpt') f.temporary.connected = false;
          else { f.badge.connected = false; f.exit.connected = false; }
        }
      };
      const result = await f.run('verifyModel', { expectedModelChoice: choice(initial) });
      expect(result.error).toBe('temporary_mode_unverified'); expect(result.modelEvidence).toBeUndefined();
      expect(opens).toBe(provider === 'chatgpt' ? 1 : 2); expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      expect(f.composer.textContent).toBe(''); if (f.send) expect(f.send.clicks).toBe(0);
    });

    test('final concrete verification accepts mode controls hidden only by the associated open modal', async () => {
      const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
      const modes = provider === 'chatgpt' ? [f.temporary] : [f.header, f.exit];
      const background = new Node('DIV'); f.body.children = f.body.children.filter((node: any) => !modes.includes(node));
      background.append(...modes); f.body.append(background);
      const click = picker.trigger.onClick; let opens = 0;
      picker.trigger.onClick = () => {
        const opening = picker.menu.values.hidden !== undefined; click();
        if (opening) { opens++; background.values['aria-hidden'] = 'true'; }
        else delete background.values['aria-hidden'];
      };
      if (provider === 'chatgpt') {
        for (const menu of [picker.menu, picker.nested].filter(Boolean)) {
          const escape = menu.onDispatch;
          menu.onDispatch = (event: any) => { escape(event); delete background.values['aria-hidden']; };
        }
      }
      const result = await f.run('verifyModel', { expectedModelChoice: choice(initial) });
      expect(result.error).toBeUndefined(); expect(result.modelEvidence.selected).toEqual(choice(initial));
      expect(opens).toBe(provider === 'chatgpt' ? 1 : 2); expect(background.values['aria-hidden']).toBeUndefined();
      expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      if (f.send) expect(f.send.clicks).toBe(0);
    });

    test('first acknowledged bubbles during either fresh model read discard only the read observation', async () => {
      for (const action of ['inspect', 'verifyModel']) for (const appendOnOpen of provider === 'chatgpt' && action === 'verifyModel' ? [1] : [1, 2]) {
        const { f, picker } = setup(false, { genericHeader: true });
        const prompt = 'Synthetic pending first\n\n' + markerLine;
        Object.assign(f.world, { __computaModelFirstSubmitted: true, __computaModelFirstMarker: firstMarker,
          __computaModelFirstPrompt: prompt, __computaModelLastSubmissionCount: 0 });
        const click = picker.trigger.onClick; let opens = 0, appended = false;
        picker.trigger.onClick = () => {
          const opening = picker.menu.values.hidden !== undefined; click();
          if (opening && ++opens === appendOnOpen) { appended = true; f.appendUser(prompt); }
        };
        const discarded = await f.run(action, { expectedUserCounts: [0, 1], expectedModelChoice: choice(initial) });
        expect(discarded).toEqual({ error: 'acknowledged_user_append', detail: 'readonly_model_observation' });
        expect(appended).toBe(true); expect(f.world.__computaModelFirstProof).toBeUndefined();
        expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
        expect((await f.run('inspect', { expectedUserCounts: [0, 1], expectedModelChoice: choice(initial) })).firstUserVerified).toBe(true);
        if (f.send) expect(f.send.clicks).toBe(0);
      }
    });

    test('acknowledged continuation bubbles during either model read retain exact first-message pins', async () => {
      for (const action of ['inspect', 'verifyModel']) for (const appendOnOpen of provider === 'chatgpt' && action === 'verifyModel' ? [1] : [1, 2]) {
        const { f, picker } = setup(true, { genericHeader: true });
        const first = await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
        const pin = f.world.__computaModelFirstProof;
        f.world.__computaModelLastSubmissionCount = 1;
        const click = picker.trigger.onClick; let opens = 0;
        picker.trigger.onClick = () => {
          const opening = picker.menu.values.hidden !== undefined; click();
          if (opening && ++opens === appendOnOpen) f.appendUser('Synthetic acknowledged continuation');
        };
        expect(await f.run(action, { expectedUserCounts: [1, 2], expectedModelChoice: choice(initial) }))
          .toEqual({ error: 'acknowledged_user_append', detail: 'readonly_model_observation' });
        expect(f.world.__computaModelFirstProof).toBe(pin);
        const fresh = await f.run('inspect', { expectedUserCounts: [1, 2], expectedModelChoice: choice(initial) });
        expect(fresh.firstUserFingerprint).toBe(first.firstUserFingerprint); expect(fresh.firstUserVerified).toBe(true);
        if (f.send) expect(f.send.clicks).toBe(0);
      }
    });

    test('digest-time acknowledged appends keep the same exact model-read constraints', async () => {
      for (const foreignMarker of [false, true]) {
        const { f } = setup(true);
        await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
        f.world.__computaModelLastSubmissionCount = 1;
        f.onDigest(() => {
          f.appendUser('Synthetic digest continuation');
          if (foreignMarker) f.world.__computaModelFirstMarker = '00000000-0000-0000-0000-000000000000';
        });
        const result = await f.run('inspect', { expectedUserCounts: [1, 2], expectedModelChoice: choice(initial) });
        if (foreignMarker) expect(result.error).toBe('conversation_changed');
        else expect(result).toEqual({ error: 'acknowledged_user_append', detail: 'readonly_model_observation' });
      }
    });

    test('an exact disconnected first-root replacement during either model read is discarded for a fresh pinned inspect', async () => {
      for (const action of ['inspect', 'verifyModel']) for (const replaceOnOpen of provider === 'chatgpt' && action === 'verifyModel' ? [1] : [1, 2]) {
        const { f, picker } = setup(true, { genericHeader: true });
        const first = await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
        const originalRoot = firstRoot(f), originalBody = f.userBody, pin = f.world.__computaModelFirstProof;
        const click = picker.trigger.onClick; let opens = 0;
        picker.trigger.onClick = () => {
          const opening = picker.menu.values.hidden !== undefined; click();
          if (opening && ++opens === replaceOnOpen) replaceFirstRoot(f, originalRoot, originalBody);
        };
        expect(await f.run(action, { expectedUserCounts: [1], expectedModelChoice: choice(initial) }))
          .toEqual({ error: 'first_user_observation_replaced', detail: 'readonly_model_observation' });
        expect(originalRoot.isConnected).toBe(false); expect(originalBody.isConnected).toBe(false);
        expect(f.world.__computaModelFirstProof).toBe(pin);
        const fresh = await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
        expect(fresh.firstUserVerified).toBe(true); expect(fresh.firstUserFingerprint).toBe(first.firstUserFingerprint);
        if (f.send) expect(f.send.clicks).toBe(0);
      }
    });

    test('replacement retry requires disconnected exact scoped bytes, marker, count, owner, pins and temporary state', async () => {
      for (const change of [
        (f: any, oldRoot: any, pair: any) => { pair.body.text += ' Changed payload'; },
        (f: any, oldRoot: any, pair: any) => { pair.body.text = pair.body.text.replace(firstMarker, '00000000-0000-0000-0000-000000000000'); },
        (f: any) => { f.world.__computaModelFirstProof.fingerprint = '0'.repeat(64); },
        (f: any) => { f.world.__computaModelFirstMarker = '00000000-0000-0000-0000-000000000000'; },
        (f: any) => { f.world.__computaModelOwner = 'foreign'; },
        (f: any) => { f.document.URL += '&changed=1'; },
        (f: any) => { if (provider === 'chatgpt') f.temporary.connected = false; else f.temporary(false); },
        (f: any) => { f.appendUser('Unexpected count append'); },
        (f: any, oldRoot: any) => { oldRoot.connected = true; oldRoot.values = {}; oldRoot.tagName = 'SECTION'; f.body.append(oldRoot); },
        ...(provider === 'claude' ? [(f: any, oldRoot: any, pair: any) => { pair.parent.values.id = 'different-provider-identity'; }] : []),
      ]) {
        const { f, picker } = setup(true, { genericHeader: true });
        await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
        const root = firstRoot(f), body = f.userBody, click = picker.trigger.onClick; let replaced = false;
        picker.trigger.onClick = () => {
          const opening = picker.menu.values.hidden !== undefined; click();
          if (opening && !replaced) { replaced = true; const pair = replaceFirstRoot(f, root, body); change(f, root, pair); }
        };
        const result = await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
        expect(result.error).toBeDefined(); expect(result.error).not.toBe('first_user_observation_replaced');
        expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
        if (f.send) expect(f.send.clicks).toBe(0);
      }
    });

    test('a second replacement during replacement SHA is rejected and every editor action remains strict', async () => {
      for (const action of ['inspect', 'prepare', 'insert', 'sendReady', 'submit']) {
        const { f, picker } = setup(true, { genericHeader: true });
        await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
        const root = firstRoot(f), body = f.userBody, click = picker.trigger.onClick; let replaced = false;
        picker.trigger.onClick = () => {
          const opening = picker.menu.values.hidden !== undefined; click();
          if (opening && !replaced) {
            replaced = true; const pair = replaceFirstRoot(f, root, body);
            if (action === 'inspect') f.onDigest(() => replaceFirstRoot(f, pair.root, pair.body));
          }
        };
        const result = await f.run(action, { expectedUserCounts: [1], expectedModelChoice: choice(initial), prompt: 'PRIVATE INSERT' });
        expect(result.error).toBe('conversation_changed'); expect(result.error).not.toBe('first_user_observation_replaced');
        expect(f.composer.textContent).toBe(''); if (f.send) expect(f.send.clicks).toBe(0);
      }
    });

    test('changed bodies, foreign markers, unexpected counts and unclaimed appends never get read retry authority', async () => {
      for (const change of [
        (f: any, body: any) => { body.text += ' Changed first body'; },
        (f: any) => { f.world.__computaModelFirstMarker = '00000000-0000-0000-0000-000000000000'; },
        (f: any) => { delete f.world.__computaModelLastSubmissionCount; },
        (f: any) => { f.appendUser('Unexpected second append'); },
        (f: any) => { f.world.__computaModelOwner = 'foreign'; },
      ]) {
        const { f, picker } = setup(true, { genericHeader: true });
        await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
        const body = f.userBody; f.world.__computaModelLastSubmissionCount = 1;
        const click = picker.trigger.onClick; let appended = false;
        picker.trigger.onClick = () => {
          const opening = picker.menu.values.hidden !== undefined; click();
          if (opening && !appended) { appended = true; f.appendUser('Synthetic continuation'); change(f, body); }
        };
        const rejected = await f.run('inspect', { expectedUserCounts: [1, 2], expectedModelChoice: choice(initial) });
        expect(rejected.error).not.toBe('acknowledged_user_append'); expect(rejected.error).toBeDefined();
        expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
        if (f.send) expect(f.send.clicks).toBe(0);
      }
    });

    test('acknowledged appends during model reads never authorize an editor mutation', async () => {
      for (const action of ['prepare', 'insert', 'sendReady', 'submit']) {
        const { f, picker } = setup(true, { genericHeader: true });
        await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
        f.world.__computaModelLastSubmissionCount = 1;
        const click = picker.trigger.onClick; let appended = false;
        picker.trigger.onClick = () => {
          const opening = picker.menu.values.hidden !== undefined; click();
          if (opening && !appended) { appended = true; f.appendUser('Synthetic continuation'); }
        };
        const rejected = await f.run(action, { expectedUserCounts: [1, 2], expectedModelChoice: choice(initial), prompt: 'PRIVATE INSERT SENTINEL' });
        expect(rejected.error).toBe('conversation_changed'); expect(rejected.error).not.toBe('acknowledged_user_append');
        expect(f.composer.textContent).toBe('');
        if (f.send) expect(f.send.clicks).toBe(0);
      }
    });

    if (provider === 'chatgpt') describe('owned collapsed first message expansion', () => {
      const expansionInput = { allowFirstUserExpansion: true, firstUserExpansionModelChoice: choice(initial) };
      const collapsed = async (behavior: { genericHeader?: boolean } = {}) => {
        const { f, picker } = setup(true, behavior);
        // Establish real Chat/temporary provenance without binding the staged
        // first message; the native first-submission permission stays explicit.
        expect((await f.run('inspect', { allowFirstUserBinding: false })).error).toBe('conversation_changed');
        const prompt = 'PRIVATE LONG OUTBOUND\n' + 'x'.repeat(40_000) + '\n\n' + markerLine;
        f.world.__computaModelFirstPrompt = prompt; f.world.__computaModelLastSubmissionCount = 0;
        f.userBody.text = prompt.slice(0, 10_240);
        const root = firstRoot(f), expand = new Node('BUTTON', { 'aria-label': 'Show more' });
        const send = new Node('BUTTON', { 'aria-label': 'Send' }); root.append(expand); f.body.append(send);
        return { f, picker, root, expand, send, prompt };
      };
      const notify = (f: any) => f.observers.forEach((observer: any) => observer.callback([
        { type: 'characterData', target: f.userBody },
      ]));
      const noSend = (f: any, picker: any, send: any) => {
        expect(send.clicks).toBe(0); expect(f.composer.textContent).toBe(''); expect(f.composer.events).toHaveLength(0);
        expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      };
      const rejected = (result: any) => {
        expect(result).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
        expect(result.debugStructure).not.toContain('PRIVATE'); expect(result.debugStructure).not.toContain(firstMarker);
      };

      test('one delayed expansion waits for an event and binds only the complete exact first body', async () => {
        const { f, picker, expand, send, prompt } = await collapsed();
        let dispatched!: () => void; const click = new Promise<void>(resolve => { dispatched = resolve; });
        expand.onClick = () => { expect(f.world.__computaModelFirstExpansion.clicked).toBe(true); dispatched(); };
        let settled = false;
        const pending = f.run('inspect', expansionInput).then((result: any) => { settled = true; return result; });
        await click; await Promise.resolve();
        expect(settled).toBe(false); expect(f.world.__computaModelFirstProof).toBeUndefined();
        expect(f.scheduledDelays.filter((delay: number) => delay > 1_000)).toHaveLength(1);
        rejected(await f.run('inspect', expansionInput)); expect(expand.clicks).toBe(1);
        f.userBody.text = prompt.slice(0, 20_000); notify(f); await Promise.resolve();
        expect(settled).toBe(false); expect(f.world.__computaModelFirstProof).toBeUndefined();
        f.userBody.text = prompt; notify(f);
        const result = await pending;
        expect(result.firstUserVerified).toBe(true); expect(result.firstUserMarkerVerified).toBe(true);
        expect(result.firstUserFingerprint).toMatch(/^[a-f0-9]{64}$/);
        expect(expand.clicks).toBe(1); expect(result.firstUserDebugStructure).not.toContain('PRIVATE');
        expect(JSON.parse(result.firstUserDebugStructure).expansionOutcome).toBe('expanded');
        expect(result.firstUserDebugStructure).not.toContain(firstMarker); noSend(f, picker, send);
        expect((await f.run('inspect', expansionInput)).firstUserVerified).toBe(true); expect(expand.clicks).toBe(1);
      });

      const productRecords = (f: any, records: any[]) => {
        for (const observer of [...f.observers]) observer.callback(records);
      };
      const messageChurn = (f: any, count: number) => Array.from({ length: count }, (_, index) => index % 3 === 0
        ? { type: 'characterData', target: { nodeType: 3, parentElement: f.userBody } }
        : index % 3 === 1 ? { type: 'attributes', target: f.userBody, attributeName: 'class', oldValue: 'PRIVATE OLD CLASS' }
          : { type: 'childList', target: f.userBody, addedNodes: [new Node('SPAN', {}, 'PRIVATE RENDER FRAGMENT')], removedNodes: [] });

      test('product provenance ignores more than 512 message-only rendering mutations during first expansion', async () => {
        const { f, picker, expand, send, prompt } = await collapsed();
        expand.onClick = () => { f.userBody.text = prompt; productRecords(f, messageChurn(f, 768)); };
        const result = await f.run('inspect', expansionInput);
        expect(result.firstUserVerified).toBe(true); expect(f.world.__computaChatProductMode.invalidated).toBe(false);
        expect(JSON.parse(result.firstUserDebugStructure).productProofFailure).toBeUndefined();
        expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('a transient Work selection hidden among message churn still revokes pressed and checked controls', async () => {
        for (const attribute of ['aria-pressed', 'aria-checked']) {
          const { f, picker, expand, send, prompt } = await collapsed();
          if (attribute === 'aria-checked') {
            delete f.chatMode.values['aria-pressed']; delete f.workMode.values['aria-pressed'];
            f.chatMode.values.role = 'radio'; f.workMode.values.role = 'radio';
            f.chatMode.values['aria-checked'] = 'true'; f.workMode.values['aria-checked'] = 'false';
          }
          f.modeGroup.values['aria-hidden'] = 'true';
          expand.onClick = () => {
            f.userBody.text = prompt;
            productRecords(f, [...messageChurn(f, 800), { type: 'attributes', target: f.workMode,
              attributeName: attribute, oldValue: 'true' }]);
          };
          const result = await f.run('inspect', expansionInput); rejected(result);
          expect(JSON.parse(result.debugStructure)).toMatchObject({ expansionContextFailure: 'product',
            productProofFailure: 'work_selected', productMutationRelevantCount: 1, productMutationIgnoredCount: 800 });
          expect(result.debugStructure).not.toContain('PRIVATE'); expect(f.world.__computaModelFirstProof).toBeUndefined();
          expect(expand.clicks).toBe(1); noSend(f, picker, send);
        }
      });

      test('tracked product groups remain authoritative after moving into a message or detaching', async () => {
        for (const disposition of ['moved', 'detached', 'message_marked']) {
          const { f, picker, root, expand, send, prompt } = await collapsed();
          expand.onClick = () => {
            f.userBody.text = prompt;
            const records = messageChurn(f, 700);
            if (disposition === 'message_marked') {
              f.modeGroup.values['data-user-message-bubble'] = '';
              records.push({ type: 'attributes', target: f.modeGroup, attributeName: 'data-user-message-bubble', oldValue: null });
            } else {
              f.body.children = f.body.children.filter((node: any) => node !== f.modeGroup);
              records.push({ type: 'childList', target: f.body, removedNodes: [f.modeGroup], addedNodes: [] });
              if (disposition === 'moved') {
                root.append(f.modeGroup);
                records.push({ type: 'childList', target: root, removedNodes: [], addedNodes: [f.modeGroup] });
              } else { f.modeGroup.parentElement = null; f.modeGroup.connected = false; }
            }
            records.push({ type: 'attributes', target: f.workMode, attributeName: 'aria-pressed', oldValue: 'true' });
            productRecords(f, records);
          };
          const result = await f.run('inspect', expansionInput); rejected(result);
          expect(f.world.__computaChatProductMode.invalidated).toBe(true);
          expect(JSON.parse(result.debugStructure).productProofFailure).toBe('work_selected');
          expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(1); noSend(f, picker, send);
        }
      });

      test('new Work descendants of a tracked group moved into a message cannot escape provenance', async () => {
        const { f, picker, root, expand, send, prompt } = await collapsed();
        expand.onClick = () => {
          f.userBody.text = prompt;
          f.body.children = f.body.children.filter((node: any) => node !== f.modeGroup); root.append(f.modeGroup);
          const oldWork = f.workMode, replacement = new Node('BUTTON', { 'aria-pressed': 'false' }, 'Work');
          f.modeGroup.children = f.modeGroup.children.filter((node: any) => node !== oldWork); f.modeGroup.append(replacement);
          productRecords(f, [...messageChurn(f, 600),
            { type: 'childList', target: root, addedNodes: [f.modeGroup], removedNodes: [] },
            { type: 'childList', target: f.modeGroup, addedNodes: [replacement], removedNodes: [oldWork] },
            { type: 'attributes', target: replacement, attributeName: 'aria-pressed', oldValue: 'true' }]);
        };
        const result = await f.run('inspect', expansionInput); rejected(result);
        expect(JSON.parse(result.debugStructure).productProofFailure).toBe('work_selected');
        expect(f.world.__computaModelFirstProof).toBeUndefined(); noSend(f, picker, send);
      });

      test('a Work control mounted in a tracked group then moved into a message retains its observed provenance', async () => {
        const { f, picker, root, expand, send, prompt } = await collapsed();
        expand.onClick = () => {
          f.userBody.text = prompt;
          const replacement = new Node('BUTTON', { 'aria-pressed': 'false' }, 'Work'); root.append(replacement);
          productRecords(f, [...messageChurn(f, 600),
            { type: 'childList', target: f.modeGroup, addedNodes: [replacement], removedNodes: [] },
            { type: 'attributes', target: replacement, attributeName: 'aria-pressed', oldValue: 'true' },
            { type: 'childList', target: f.modeGroup, addedNodes: [], removedNodes: [replacement] },
            { type: 'childList', target: root, addedNodes: [replacement], removedNodes: [] }]);
        };
        const result = await f.run('inspect', expansionInput); rejected(result);
        expect(JSON.parse(result.debugStructure).productProofFailure).toBe('work_selected');
        expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('a detached conversation-authored product group cannot become trusted while rendering expands', async () => {
        const { f, picker, root, expand, send, prompt } = await collapsed();
        expand.onClick = () => {
          f.userBody.text = prompt;
          const authored = new Node('DIV', { 'aria-label': 'Composer mode' });
          const work = new Node('BUTTON', { 'aria-pressed': 'false' }, 'Work'); authored.append(work); authored.connected = false;
          productRecords(f, [...messageChurn(f, 600),
            { type: 'childList', target: root, addedNodes: [authored], removedNodes: [] },
            { type: 'attributes', target: work, attributeName: 'aria-pressed', oldValue: 'true' },
            { type: 'childList', target: root, addedNodes: [], removedNodes: [authored] }]);
          expect(f.world.__computaChatProductMode.groups.has(authored)).toBe(false);
          expect(f.world.__computaChatProductMode.works.has(work)).toBe(false);
        };
        const result = await f.run('inspect', expansionInput);
        expect(result.firstUserVerified).toBe(true); expect(f.world.__computaChatProductMode.invalidated).toBe(false);
        expect(JSON.parse(result.firstUserDebugStructure).productProofFailure).toBeUndefined();
        expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('more than 512 relevant product records still fail and preserve first-cause bounded counts', async () => {
        const { f, picker, expand, send, prompt } = await collapsed();
        expand.onClick = () => {
          f.userBody.text = prompt;
          productRecords(f, [...messageChurn(f, 1_100), ...Array.from({ length: 513 }, () => ({
            type: 'attributes', target: f.composer, attributeName: 'class', oldValue: 'PRIVATE OLD CLASS' }))]);
          productRecords(f, [{ type: 'attributes', target: f.workMode, attributeName: 'aria-pressed', oldValue: 'true' }]);
        };
        const result = await f.run('inspect', expansionInput); rejected(result);
        expect(JSON.parse(result.debugStructure)).toMatchObject({ productProofFailure: 'mutation_overflow',
          productMutationRelevantCount: 513, productMutationIgnoredCount: 1_000 });
        expect(result.debugStructure).not.toContain('PRIVATE'); expect(f.world.__computaModelFirstProof).toBeUndefined();
        expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('message records adding recognized product groups remain relevant to the mutation budget', async () => {
        const { f, picker, root, expand, send, prompt } = await collapsed();
        expand.onClick = () => {
          f.userBody.text = prompt;
          const group = new Node('DIV', { 'aria-label': 'Composer mode' });
          root.append(group);
          productRecords(f, Array.from({ length: 513 }, () => ({ type: 'childList', target: root, addedNodes: [group], removedNodes: [] })));
        };
        const result = await f.run('inspect', expansionInput); rejected(result);
        expect(JSON.parse(result.debugStructure)).toMatchObject({ productProofFailure: 'mutation_overflow',
          productMutationRelevantCount: 513, productMutationIgnoredCount: 0 });
        expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      const moveRoute = (f: any, url: string) => { f.document.URL = url; f.location.pathname = new URL(url).pathname; };
      const continuation = (fromURL: string, toURL: string) => ({ ...expansionInput,
        firstUserExpansionRouteContinuation: [{ fromURL, toURL }] });
      const routeChain = (root: string, local: string, final: string) => ({ ...expansionInput,
        firstUserExpansionRouteContinuation: [{ fromURL: root, toURL: local }, { fromURL: local, toURL: final }] });
      const crossedExpansion = async () => {
        const stage = await collapsed(), fromURL = stage.f.document.URL;
        const toURL = 'https://chatgpt.com/c/local-chatgpt:owned-expansion?temporary-chat=true';
        stage.expand.onClick = () => { stage.f.userBody.text = stage.prompt; moveRoute(stage.f, toURL); };
        const first = await stage.f.run('inspect', expansionInput); rejected(first);
        expect(JSON.parse(first.debugStructure)).toMatchObject({ expansionOutcome: 'context_changed', expansionContextFailure: 'url' });
        return { ...stage, fromURL, toURL };
      };

      test('native-certified first route continues the same expanded body without another click or Send', async () => {
        const { f, picker, expand, send, prompt, fromURL, toURL } = await crossedExpansion();
        const deadline = f.world.__computaModelFirstExpansion.deadline;
        const result = await f.run('inspect', continuation(fromURL, toURL));
        const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(prompt));
        expect(result.firstUserFingerprint).toBe([...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join(''));
        expect(result.firstUserVerified).toBe(true); expect(JSON.parse(result.firstUserDebugStructure).expansionOutcome).toBe('expanded');
        expect(result.firstUserDebugStructure).not.toContain(fromURL); expect(result.firstUserDebugStructure).not.toContain(toURL);
        expect(f.world.__computaModelFirstExpansion.deadline).toBe(deadline);
        expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('two certified monotonic route edges share the original expansion and absolute deadline', async () => {
        const { f, picker, expand, send, prompt } = await collapsed(), fromURL = f.document.URL;
        const local = 'https://chatgpt.com/c/local-chatgpt:owned-two-edge?temporary-chat=true';
        const final = 'https://chatgpt.com/c/owned-two-edge-public?temporary-chat=true';
        expand.onClick = () => moveRoute(f, local);
        rejected(await f.run('inspect', expansionInput));
        const deadline = f.world.__computaModelFirstExpansion.deadline;
        f.advanceTime(200);
        const pending = f.run('inspect', continuation(fromURL, local)); await Promise.resolve();
        f.userBody.text = prompt; moveRoute(f, final); notify(f);
        const crossed = await pending; rejected(crossed);
        expect(JSON.parse(crossed.debugStructure).expansionContextFailure).toBe('url');
        expect(f.world.__computaModelFirstExpansion.routeURL).toBe(local);
        expect((await f.run('inspect', routeChain(fromURL, local, final))).firstUserVerified).toBe(true);
        expect(f.world.__computaModelFirstExpansion.deadline).toBe(deadline);
        expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('an unconsumed first route receipt survives a native-certified public promotion before the next inspect', async () => {
        const { f, picker, expand, send, fromURL, toURL } = await crossedExpansion();
        const final = 'https://chatgpt.com/c/owned-pre-entry-public?temporary-chat=true';
        const candidate = f.world.__computaModelFirstExpansion, deadline = candidate.deadline;
        expect(candidate.routeURL).toBe(fromURL); moveRoute(f, final); f.advanceTime(200);
        const result = await f.run('inspect', routeChain(fromURL, toURL, final));
        expect(result.firstUserVerified).toBe(true); expect(candidate.routeURL).toBe(final);
        expect(candidate.deadline).toBe(deadline); expect(expand.clicks).toBe(1); noSend(f, picker, send);
        expect(result.firstUserDebugStructure).not.toContain(fromURL);
        expect(result.firstUserDebugStructure).not.toContain(toURL);
        expect(result.firstUserDebugStructure).not.toContain(final);
      });

      test('an exact two-edge chain cannot extend the deadline or rescue changed private lineage', async () => {
        for (const condition of ['deadline', 'owner', 'prompt', 'body', 'product', 'temporary']) {
          const stage = await crossedExpansion(), { f, fromURL, toURL } = stage;
          const final = 'https://chatgpt.com/c/owned-pre-entry-rejected?temporary-chat=true';
          moveRoute(f, final);
          if (condition === 'deadline') f.advanceTime(1_801);
          if (condition === 'owner') f.world.__computaModelOwner = 'PRIVATE WRONG OWNER';
          if (condition === 'prompt') f.world.__computaModelFirstPrompt += 'PRIVATE WRONG PROMPT';
          if (condition === 'body') f.userBody.text = stage.prompt.replace('PRIVATE LONG', 'PRIVATE WRONG');
          if (condition === 'product') { f.workMode.values['aria-pressed'] = 'true'; f.chatMode.values['aria-pressed'] = 'false'; }
          if (condition === 'temporary') f.temporary.connected = false;
          const result = await f.run('inspect', routeChain(fromURL, toURL, final));
          if (condition === 'owner') expect(result).toMatchObject({ error: 'document_changed', detail: 'owner_token' });
          else rejected(result);
          expect(JSON.stringify(result)).not.toContain('PRIVATE WRONG');
          expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(stage.expand.clicks).toBe(1);
          noSend(f, stage.picker, stage.send);
        }
      });

      test('empty, discontinuous, repeated and over-budget native receipt chains fail without a new display click', async () => {
        for (const alter of [
          (edges: any[]) => [],
          (edges: any[]) => [edges[0], { ...edges[1], fromURL: 'https://chatgpt.com/c/unrelated-local' }],
          (edges: any[]) => [edges[0], { fromURL: edges[0].toURL, toURL: edges[0].fromURL }],
          (edges: any[]) => [edges[0], edges[0], edges[1]],
          (edges: any[]) => [{ ...edges[0], privateValue: 'PRIVATE EXTRA' }, edges[1]],
          (edges: any[]) => [{ fromURL: edges[0].fromURL, toURL: edges[0].fromURL }, edges[1]],
        ]) {
          const stage = await crossedExpansion(), final = 'https://chatgpt.com/c/owned-chain-invalid?temporary-chat=true';
          moveRoute(stage.f, final);
          const request = routeChain(stage.fromURL, stage.toURL, final);
          request.firstUserExpansionRouteContinuation = alter(request.firstUserExpansionRouteContinuation);
          rejected(await stage.f.run('inspect', request)); expect(stage.f.world.__computaModelFirstProof).toBeUndefined();
          expect(stage.expand.clicks).toBe(1); noSend(stage.f, stage.picker, stage.send);
        }
      });

      test('missing, mismatched or malformed continuation authority cannot rescue a consumed route failure', async () => {
        for (const alter of [
          (request: any) => { delete request.firstUserExpansionRouteContinuation; },
          (request: any) => { request.firstUserExpansionRouteContinuation[0].fromURL = 'https://chatgpt.com/c/foreign'; },
          (request: any) => { request.firstUserExpansionRouteContinuation[0].toURL = 'https://chatgpt.com/c/foreign'; },
          (request: any) => { request.firstUserExpansionRouteContinuation[0].extra = true; },
          (request: any) => { request.firstUserExpansionRouteContinuation = true; },
          (request: any) => { request.allowFirstUserExpansion = false; },
          (request: any) => { request.allowFirstUserBinding = false; },
          (request: any) => { request.expectedFirstUserFingerprint = 'a'.repeat(64); },
          (request: any) => { request.firstUserExpansionModelChoice = choice(target); },
        ]) {
          const { f, picker, expand, send, fromURL, toURL } = await crossedExpansion();
          const request = continuation(fromURL, toURL); alter(request);
          rejected(await f.run('inspect', request)); expect(f.world.__computaModelFirstProof).toBeUndefined();
          expect(expand.clicks).toBe(1); noSend(f, picker, send);
        }
      });

      test('certified route continuation preserves body, prompt, count, product and temporary rejection', async () => {
        for (const [predicate, mutate] of [
          ['root', (stage: any) => replaceFirstRoot(stage.f, stage.root, stage.f.userBody)],
          ['prompt', (stage: any) => { stage.f.world.__computaModelFirstPrompt += 'PRIVATE MUTATION'; }],
          ['user_count', (stage: any) => stage.f.appendUser('PRIVATE SECOND MESSAGE')],
          ['temporary', (stage: any) => { stage.f.temporary.connected = false; }],
          ['product', (stage: any) => { stage.f.chatMode.values['aria-pressed'] = 'false'; stage.f.workMode.values['aria-pressed'] = 'true'; }],
        ] as [string, (stage: any) => void][]) {
          const stage = await crossedExpansion(); mutate(stage);
          const result = await stage.f.run('inspect', { ...continuation(stage.fromURL, stage.toURL), expectedUserCounts: [1, 2] });
          rejected(result); expect(JSON.parse(result.debugStructure).expansionContextFailure).toBe(predicate);
          expect(stage.f.world.__computaModelFirstProof).toBeUndefined(); expect(stage.expand.clicks).toBe(1);
          noSend(stage.f, stage.picker, stage.send);
        }
      });

      test('URL change accompanied by destructive drift is never classified as URL-only continuation', async () => {
        const { f, picker, expand, send, prompt } = await collapsed(), fromURL = f.document.URL;
        const toURL = 'https://chatgpt.com/c/local-chatgpt:owned-and-foreign?temporary-chat=true';
        expand.onClick = () => { f.userBody.text = prompt; moveRoute(f, toURL); f.world.__computaModelFirstPrompt += 'PRIVATE DRIFT'; };
        const first = await f.run('inspect', expansionInput); rejected(first);
        expect(JSON.parse(first.debugStructure).expansionContextFailure).toBe('prompt');
        f.world.__computaModelFirstPrompt = prompt;
        rejected(await f.run('inspect', continuation(fromURL, toURL)));
        expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('continuation neither extends an expired deadline nor grants cleanup or model-only authority', async () => {
        for (const action of ['expired', 'cleanup', 'stop', 'verifyModel', 'verifyProductMode', 'prepare', 'insert', 'submit']) {
          const { f, picker, expand, send, fromURL, toURL } = await crossedExpansion();
          if (action === 'expired') f.advanceTime(1_801);
          const result = await f.run(action === 'expired' ? 'inspect' : action, continuation(fromURL, toURL)); rejected(result);
          expect(JSON.parse(result.debugStructure).expansionContextFailure).toBe(action === 'expired' ? 'deadline' : 'continuation');
          expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(1); noSend(f, picker, send);
        }
      });

      test('a URL transition cannot conceal incompatible text and revive it after later restoration', async () => {
        const { f, picker, expand, send, prompt } = await collapsed(), fromURL = f.document.URL;
        const toURL = 'https://chatgpt.com/c/local-chatgpt:text-drift?temporary-chat=true';
        expand.onClick = () => { f.userBody.text = prompt.replace('PRIVATE LONG', 'PRIVATE OTHER'); moveRoute(f, toURL); };
        const first = await f.run('inspect', expansionInput); rejected(first);
        expect(JSON.parse(first.debugStructure).expansionOutcome).toBe('text_mismatch');
        f.userBody.text = prompt;
        rejected(await f.run('inspect', continuation(fromURL, toURL)));
        expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('synchronous expansion binds without recurring polling or an extra Send', async () => {
        const { f, picker, expand, send, prompt } = await collapsed();
        expand.onClick = () => { f.userBody.text = prompt; };
        expect((await f.run('inspect', expansionInput)).firstUserVerified).toBe(true);
        expect(expand.clicks).toBe(1); expect(f.scheduledDelays).toHaveLength(0); noSend(f, picker, send);
      });

      test('Markdown delimiter loss rejects expansion while JSON escapes preserve strict ownership', async () => {
        const text = '```swift\\nlet x = 1\\n``` and ```json\\n{}\\n``` and ```text\\nkept\\n```';
        const request = JSON.stringify({ model: 'browser/chatgpt', input: text });
        for (const escaped of [false, true]) {
          const { f, picker, expand, send } = await collapsed();
          const json = escaped ? request.replaceAll('`', '\\u0060') : request;
          expect(JSON.parse(json)).toEqual(JSON.parse(request));
          const outbound = f.userBody.text + 'x'.repeat(10_000) + '\n' + json + '\n\n' + markerLine;
          const rendered = outbound.replaceAll('`', '');
          expect(outbound.length - rendered.length).toBe(escaped ? 0 : 18);
          f.world.__computaModelFirstPrompt = outbound;
          expand.onClick = () => { f.userBody.text = rendered; };
          const result = await f.run('inspect', expansionInput);
          if (escaped) {
            expect(result.firstUserVerified).toBe(true);
            expect((await f.run('inspect', expansionInput)).firstUserFingerprint).toBe(result.firstUserFingerprint);
            f.userBody.text = rendered.replace('let x = 1', 'let x = 2');
            rejected(await f.run('inspect', expansionInput));
          } else {
            rejected(result);
            expect(JSON.parse(result.debugStructure).expansionOutcome).toBe('text_mismatch');
            expect(f.world.__computaModelFirstProof).toBeUndefined();
          }
          expect(expand.clicks).toBe(1); noSend(f, picker, send);
        }
      });

      test('completed provider rendering binds its actual digest when one whitespace run loses twelve source characters', async () => {
        const { f, picker, expand, send } = await collapsed();
        // The live first-message body was twelve characters shorter than the
        // outbound source after a successful display expansion. Preserve its
        // observed exact 10,240-character prefix and model/product context.
        const prefix = f.userBody.text;
        const suffix = '\nUse schema_0 and schema_1' + '\n'.repeat(13) + markerLine;
        const outbound = prefix + 'x'.repeat(46_593 - prefix.length - suffix.length) + suffix;
        const rendered = outbound.replace(/\n{2,}/g, '\n');
        expect(outbound.length).toBe(46_593); expect(rendered.length).toBe(46_581);
        expect(rendered.startsWith(prefix)).toBe(true); expect(rendered).not.toBe(outbound);
        f.world.__computaModelFirstPrompt = outbound;
        expand.onClick = () => { f.userBody.text = rendered; };
        const result = await f.run('inspect', { ...expansionInput, expectedModelChoice: choice(initial) });
        const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(rendered));
        const expectedFingerprint = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
        expect(result).toMatchObject({ firstUserVerified: true, firstUserMarkerVerified: true,
          firstUserFingerprint: expectedFingerprint });
        expect(JSON.parse(result.firstUserDebugStructure)).toMatchObject({ textLength: 46_581,
          expansionOutcome: 'expanded', markerFinalLine: true, markerOccurrences: 1,
          snapshot: { rootSame: true, bodySame: true, textSame: true } });
        expect((await f.run('inspect', { ...expansionInput, expectedModelChoice: choice(initial) })).firstUserFingerprint).toBe(expectedFingerprint);
        f.userBody.text = rendered.replace('schema_0', 'foreign_schema');
        rejected(await f.run('inspect', expansionInput));
        expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('ASCII line breaks inside the captured prefix share the full-message whitespace policy through partial and final rendering', async () => {
        for (const delayed of [false, true]) {
          const { f, picker, expand, send, prompt } = await collapsed();
          const rendered = prompt.replace('PRIVATE LONG', 'PRIVATE ' + '\n'.repeat(15) + 'LONG');
          let clicked!: () => void; const click = new Promise<void>(resolve => { clicked = resolve; });
          expand.onClick = () => { if (!delayed) f.userBody.text = rendered; clicked(); };
          let settled = false;
          const pending = f.run('inspect', expansionInput).then((result: any) => { settled = true; return result; });
          await click; const deadline = f.world.__computaModelFirstExpansion.deadline;
          if (delayed) {
            f.userBody.text = rendered.slice(0, 20_000); notify(f); await Promise.resolve();
            expect(settled).toBe(false); expect(f.world.__computaModelFirstProof).toBeUndefined();
            f.userBody.text = rendered; notify(f);
          }
          const result = await pending;
          expect(result.firstUserVerified).toBe(true);
          expect(JSON.parse(result.firstUserDebugStructure)).toMatchObject({ expansionOutcome: 'expanded',
            expansionTextAnalyzed: true, expansionClicked: true, expansionExactPrefixMatches: false,
            expansionASCIIPrefixMatches: true, expansionASCIIPromptMatches: true, expansionFirstMismatchClass: 'none',
            expansionUnicodeSpaceCount: 0, expansionFormatCount: 0 });
          expect(f.world.__computaModelFirstExpansion.deadline).toBe(deadline);
          const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(rendered));
          expect(result.firstUserFingerprint).toBe([...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join(''));
          expect(result.firstUserDebugStructure).not.toContain('PRIVATE'); expect(result.firstUserDebugStructure).not.toContain(firstMarker);
          expect(expand.clicks).toBe(1); noSend(f, picker, send);
        }
      });

      test('prefix punctuation and Unicode whitespace or format changes fail with latched content-free diagnostics and no replay', async () => {
        for (const [replacement, kind, spaces, formats] of [
          ['!', 'punctuation', 0, 0], ['\u00a0', 'unicode_space', 1, 0], ['\u2028', 'unicode_space', 1, 0],
          ['\u2029', 'unicode_space', 1, 0], ['\u200b', 'format', 0, 1], ['\ufeff', 'format', 0, 1],
        ] as [string, string, number, number][]) {
          const { f, picker, expand, send, prompt } = await collapsed();
          expand.onClick = () => { f.userBody.text = replacement === '!' ? prompt.replace('LONG', 'L!NG')
            : prompt.replace('PRIVATE LONG', 'PRIVATE' + replacement + 'LONG'); };
          const result = await f.run('inspect', expansionInput); rejected(result);
          const diagnostic = JSON.parse(result.debugStructure);
          expect(diagnostic).toMatchObject({ expansionOutcome: 'text_mismatch', expansionTextAnalyzed: true,
            expansionClicked: true, expansionExactPrefixMatches: false, expansionASCIIPrefixMatches: false,
            expansionASCIIPromptMatches: false, expansionFirstMismatchClass: kind,
            expansionUnicodeSpaceCount: spaces, expansionFormatCount: formats,
            expansionExpectedUnicodeSpaceCount: 0, expansionExpectedFormatCount: 0, expansionFirstMismatchOffset: replacement === '!' ? 9 : 7 });
          const latched = { ...f.world.__computaModelFirstExpansion.textDiagnostic };
          f.userBody.text = prompt;
          rejected(await f.run('inspect', expansionInput));
          expect(f.world.__computaModelFirstExpansion.textDiagnostic).toEqual(latched);
          expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(1); noSend(f, picker, send);
        }
      });

      test('prefix normalization cannot authorize a display click after text changes during the model precheck', async () => {
        const { f, picker, expand, send, prompt } = await collapsed({ genericHeader: true });
        const click = picker.trigger.onClick;
        picker.trigger.onClick = () => { click(); f.userBody.text = prompt.replace('PRIVATE LONG', 'PRIVATE \nLONG'); };
        const result = await f.run('inspect', expansionInput); rejected(result);
        expect(JSON.parse(result.debugStructure)).toMatchObject({ expansionOutcome: 'text_mismatch', expansionClicked: false,
          expansionTextAnalyzed: true, expansionASCIIPrefixMatches: true, expansionASCIIPromptMatches: true });
        expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(0); noSend(f, picker, send);
      });

      test('normalized completion waits for its one actual mutation and retains the same bounded event budget', async () => {
        const { f, picker, expand, send, prompt } = await collapsed();
        const suffix = '\nUse schema\n\n' + markerLine;
        const body = prompt.slice(0, -('\n\n' + markerLine).length);
        const outbound = body.slice(0, 12_000) + '\n\n\n' + body.slice(12_000) + suffix;
        f.world.__computaModelFirstPrompt = outbound;
        let clicked!: () => void; const click = new Promise<void>(resolve => { clicked = resolve; });
        expand.onClick = () => clicked();
        let settled = false;
        const pending = f.run('inspect', expansionInput).then((result: any) => { settled = true; return result; });
        await click; await Promise.resolve();
        expect(settled).toBe(false); expect(f.world.__computaModelFirstProof).toBeUndefined();
        f.userBody.text = outbound.slice(0, 20_000).replace(/\n{2,}/g, '\n'); notify(f); await Promise.resolve();
        expect(settled).toBe(false); expect(f.world.__computaModelFirstProof).toBeUndefined();
        f.userBody.text = outbound.replace(/\n{2,}/g, '\n'); notify(f);
        expect((await pending).firstUserVerified).toBe(true);
        expect(f.scheduledDelays.filter((delay: number) => delay > 1_000)).toHaveLength(1);
        expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('completed bodies reject changed exact prefixes, duplicate or nonfinal markers and oversized text', async () => {
        for (const mutate of [
          (text: string) => 'foreign-prefix' + text.slice('foreign-prefix'.length),
          (text: string) => text.replace(/\n\nComputa session marker:/, '\ninline ' + markerLine + '\n\nComputa session marker:'),
          (text: string) => text + '\nPRIVATE TRAILING BODY',
          (text: string) => text.replace(markerLine, markerLine + '-changed'),
          (text: string) => text.slice(0, 10_240) + 'x'.repeat(180_201) + '\n\n' + markerLine,
        ]) {
          const { f, picker, expand, send, prompt } = await collapsed();
          expand.onClick = () => { f.userBody.text = mutate(prompt); };
          const result = await f.run('inspect', expansionInput); rejected(result);
          expect(JSON.parse(result.debugStructure).expansionOutcome).toBe('text_mismatch');
          expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(1); noSend(f, picker, send);
        }
      });

      test('an intact prefix and final marker cannot excuse changed middle, suffix, whitespace boundaries or Markdown delimiters', async () => {
        for (const mutate of [
          (text: string) => text.slice(0, 15_000) + 'foreign' + text.slice(15_007),
          (text: string) => text.replace('schema_0 and schema_1', 'schema_0 or schema_1'),
          (text: string) => text.replace('schema_0 and schema_1', 'schema_0and schema_1'),
          (text: string) => text.replace('`literal_code`', 'literal_code'),
          (text: string) => text.replace('schema_0 and schema_1', 'schema_0\u00a0and schema_1'),
        ]) {
          const { f, picker, expand, send, prompt } = await collapsed();
          const outbound = prompt.replace('\n\n' + markerLine, '\nUse schema_0 and schema_1 and `literal_code`\n\n' + markerLine);
          f.world.__computaModelFirstPrompt = outbound;
          expand.onClick = () => { f.userBody.text = mutate(outbound); };
          const result = await f.run('inspect', expansionInput); rejected(result);
          expect(JSON.parse(result.debugStructure)).toMatchObject({ markerFinalLine: true, expansionOutcome: 'text_mismatch' });
          expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(1); noSend(f, picker, send);
        }
      });

      test('provider-normalized full-body rejection diagnostics use the mutated body and never bind after context or physical node drift', async () => {
        for (const [outcome, mutate] of [
          ['context_changed', ({ f }: any) => { f.document.URL = 'https://chatgpt.com/c/foreign'; }],
          ['context_changed', ({ f }: any) => { f.world.__computaModelOwner = 'foreign'; }],
          ['context_changed', ({ f }: any) => { f.world.__computaModelFirstPrompt += 'PRIVATE DRIFT'; }],
          ['context_changed', ({ f }: any) => { f.temporary.connected = false; }],
          ['context_changed', ({ f }: any) => { f.chatMode.values['aria-pressed'] = 'false'; f.workMode.values['aria-pressed'] = 'true'; }],
          ['node_changed', ({ f, root }: any) => replaceFirstRoot(f, root, f.userBody)],
        ] as [string, (stage: any) => void][]) {
          const stage = await collapsed();
          const outbound = stage.prompt.replace('\n\n' + markerLine, '\nUse schema\n\n' + markerLine);
          stage.f.world.__computaModelFirstPrompt = outbound;
          const rendered = outbound.replace('\n\n' + markerLine, '\n' + markerLine);
          stage.expand.onClick = () => { stage.f.userBody.text = rendered; mutate(stage); };
          const result = await stage.f.run('inspect', expansionInput); rejected(result);
          expect(JSON.parse(result.debugStructure)).toMatchObject({ textLength: rendered.length,
            markerFinalLine: true, expansionOutcome: outcome });
          expect(stage.f.world.__computaModelFirstProof).toBeUndefined(); expect(stage.expand.clicks).toBe(1);
          noSend(stage.f, stage.picker, stage.send);
        }
      });

      test('normalized display completion cannot bind a different selected model', async () => {
        const { f, picker, expand, send, prompt } = await collapsed();
        const outbound = prompt.replace('\n\n' + markerLine, '\nUse schema\n\n' + markerLine);
        f.world.__computaModelFirstPrompt = outbound;
        expand.onClick = () => { f.userBody.text = outbound.replace('\n\n' + markerLine, '\n' + markerLine); picker.selected(target); };
        const result = await f.run('inspect', { ...expansionInput, expectedModelChoice: choice(initial) });
        expect(result.error).toBe('model_mismatch'); expect(f.world.__computaModelFirstProof).toBeUndefined();
        expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('a rejected consumed claim cannot bind a later full body or grant cleanup authority', async () => {
        for (const fail of [
          ({ f, prompt }: any) => { f.userBody.text = 'foreign-prefix' + prompt.slice('foreign-prefix'.length); },
          () => { throw new Error('PRIVATE FAILED EXPANSION'); },
        ]) {
          const stage = await collapsed(); stage.expand.onClick = () => fail(stage);
          rejected(await stage.f.run('inspect', expansionInput));
          // A late site render must not turn a terminally rejected local claim
          // into ownership on either ordinary inspection or cleanup.
          stage.f.userBody.text = stage.prompt;
          for (const action of ['inspect', 'cleanup']) {
            const result = await stage.f.run(action, { ...expansionInput, allowFirstUserExpansion: false });
            rejected(result); expect(stage.f.world.__computaModelFirstProof).toBeUndefined();
          }
          expect(stage.expand.clicks).toBe(1); noSend(stage.f, stage.picker, stage.send);
        }
      });

      test('a timed-out consumed claim cannot bind a late completed body during inspection or cleanup', async () => {
        const { f, picker, expand, send, prompt } = await collapsed();
        let clicked!: () => void; const click = new Promise<void>(resolve => { clicked = resolve; });
        expand.onClick = () => clicked();
        const pending = f.run('inspect', expansionInput); await click; f.flush();
        rejected(await pending); f.userBody.text = prompt;
        for (const action of ['inspect', 'cleanup']) {
          const result = await f.run(action, expansionInput); rejected(result);
          expect(JSON.parse(result.debugStructure).expansionOutcome).toBe('timeout');
        }
        expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('normalized display cannot bypass disabled controls, including changes during the model precheck', async () => {
        for (const duringAwait of [false, true]) {
          const { f, picker, expand, send, prompt } = await collapsed({ genericHeader: duringAwait });
          const outbound = prompt.replace('\n\n' + markerLine, '\nUse schema\n\n' + markerLine);
          f.world.__computaModelFirstPrompt = outbound;
          expand.onClick = () => { f.userBody.text = outbound.replace('\n\n' + markerLine, '\n' + markerLine); };
          if (duringAwait) {
            const click = picker.trigger.onClick; picker.trigger.onClick = () => { click(); expand.disabled = true; };
          } else expand.disabled = true;
          rejected(await f.run('inspect', expansionInput));
          expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(0); noSend(f, picker, send);
        }
      });

      test('a successful expansion awaiting first binding retains its exact full body and physical lineage on later reads', async () => {
        for (const drift of ['none', 'whitespace', 'root']) {
          const { f, picker, root, expand, send, prompt } = await collapsed();
          const outbound = prompt.replace('\n\n' + markerLine, '\nUse schema\n\n' + markerLine);
          const rendered = outbound.replace('\n\n' + markerLine, '\n' + markerLine);
          f.world.__computaModelFirstPrompt = outbound;
          expand.onClick = () => { f.userBody.text = rendered; };
          // Expansion succeeds, but a disallowed final model read prevents
          // first binding; a future read still owes the original full snapshot.
          expect((await f.run('inspect', { ...expansionInput, expectedModelChoice: choice(target) })).error).toBe('model_mismatch');
          expect(f.world.__computaModelFirstProof).toBeUndefined();
          expect(f.world.__computaModelFirstExpansion.outcome).toBe('expanded');
          if (drift === 'whitespace') f.userBody.text = rendered.replace('Use schema', 'Use  schema');
          if (drift === 'root') replaceFirstRoot(f, root, f.userBody);
          const later = await f.run('inspect', { ...expansionInput, expectedModelChoice: choice(initial) });
          if (drift === 'none') expect(later.firstUserVerified).toBe(true);
          else { rejected(later); expect(f.world.__computaModelFirstProof).toBeUndefined(); }
          expect(expand.clicks).toBe(1); noSend(f, picker, send);
        }
      });

      test('an offscreen control scrolls once and must become exposed before its single click', async () => {
        for (const expose of [true, false]) {
          const { f, picker, expand, send, prompt } = await collapsed(); let scrolled = 0;
          expand.getBoundingClientRect = () => ({ left: 0, top: scrolled ? 50 : -100, width: 100, height: 30 });
          expand.scrollIntoView = () => { scrolled++; if (expose) f.setHit(expand); };
          f.setHit(null); expand.onClick = () => { f.userBody.text = prompt; };
          const result = await f.run('inspect', expansionInput);
          expect(scrolled).toBe(1); expect(expand.clicks).toBe(expose ? 1 : 0);
          if (expose) expect(result.firstUserVerified).toBe(true); else rejected(result);
          noSend(f, picker, send);
        }
      });

      test('missing permission, first binding state, marker, prompt or verified model never authorize expansion', async () => {
        for (const [mutate, overrides] of [
          [() => {}, { allowFirstUserExpansion: false }], [() => {}, { allowFirstUserBinding: false }],
          [() => {}, { expectedFirstUserFingerprint: 'a'.repeat(64) }],
          [() => {}, { firstUserExpansionModelChoice: undefined }],
          [(f: any) => { f.world.__computaModelFirstProof = { marker: firstMarker, fingerprint: 'a'.repeat(64) }; }, {}],
          [(f: any) => { f.world.__computaModelFirstSubmitted = false; }, {}],
          [(f: any) => { f.world.__computaModelLastSubmissionCount = 1; }, {}],
          [(f: any) => { f.world.__computaModelFirstMarker = 'foreign'; }, {}],
          [(f: any) => { f.world.__computaModelFirstPrompt = 'PRIVATE DIFFERENT PROMPT\n\n' + markerLine; }, {}],
          [(f: any) => { f.world.__computaModelFirstPrompt = 'x'.repeat(180_001) + '\n\n' + markerLine; }, {}],
          [(f: any) => { f.userBody.text = 'PRIVATE WRONG BODY'; }, {}],
        ] as [(f: any) => void, Record<string, unknown>][]) {
          const { f, picker, expand, send, prompt } = await collapsed(); mutate(f);
          expand.onClick = () => { f.userBody.text = prompt; };
          rejected(await f.run('inspect', { ...expansionInput, ...overrides }));
          expect(expand.clicks).toBe(0); expect(f.world.__computaModelFirstExpansion).toBeUndefined(); noSend(f, picker, send);
        }
      });

      test('insert, submit, preparation, model reads, stop and cleanup never expand a first body', async () => {
        for (const action of ['prepare', 'insert', 'sendReady', 'submit', 'verifyModel', 'verifyProductMode', 'stop', 'cleanup']) {
          const { f, picker, expand, send } = await collapsed();
          rejected(await f.run(action, expansionInput));
          expect(expand.clicks).toBe(0); expect(f.world.__computaModelFirstExpansion).toBeUndefined(); noSend(f, picker, send);
        }
      });

      test('foreign product, temporary, route, identity and model contexts cannot expand', async () => {
        for (const [mutate, overrides] of [
          [(f: any) => { f.chatMode.values['aria-pressed'] = 'false'; f.workMode.values['aria-pressed'] = 'true'; }, {}],
          [(f: any) => { f.temporary.connected = false; }, {}],
          [() => {}, { expectedConversation: 'https://chatgpt.com/c/foreign' }],
          [() => {}, { expectedConversationIdentity: 'PRIVATE FOREIGN IDENTITY' }],
          [() => {}, { firstUserExpansionModelChoice: choice(target) }],
        ] as [(f: any) => void, Record<string, unknown>][]) {
          const { f, picker, expand, send } = await collapsed(); mutate(f);
          rejected(await f.run('inspect', { ...expansionInput, ...overrides }));
          expect(expand.clicks).toBe(0); expect(f.world.__computaModelFirstProof).toBeUndefined(); noSend(f, picker, send);
        }
      });

      test('ambiguous, disabled, hidden, disconnected, obstructed or nonlocal controls are never clicked', async () => {
        for (const mutate of [
          ({ root }: any) => root.append(new Node('BUTTON', { 'aria-label': 'Read more' })),
          ({ expand }: any) => { expand.disabled = true; },
          ({ expand }: any) => { expand.values['aria-disabled'] = 'true'; },
          ({ expand }: any) => { expand.values.hidden = ''; },
          ({ expand }: any) => { expand.values['aria-hidden'] = 'true'; },
          ({ expand }: any) => { expand.connected = false; },
          ({ expand }: any) => { expand.values['aria-label'] = 'PRIVATE OTHER CONTROL'; },
          ({ f }: any) => f.setHit(null),
          ({ expand }: any) => { expand.tagName = 'SUMMARY'; },
          ({ f, root, expand }: any) => { root.children = root.children.filter((node: any) => node !== expand); f.body.append(expand); },
        ]) {
          const stage = await collapsed(); mutate(stage);
          rejected(await stage.f.run('inspect', expansionInput)); expect(stage.expand.clicks).toBe(0);
          expect(stage.f.world.__computaModelFirstProof).toBeUndefined(); noSend(stage.f, stage.picker, stage.send);
        }
      });

      test('ignored expansion times out once and cannot be replayed by a second inspection', async () => {
        const { f, picker, expand, send } = await collapsed();
        let dispatched!: () => void; const click = new Promise<void>(resolve => { dispatched = resolve; });
        expand.onClick = () => dispatched();
        const pending = f.run('inspect', expansionInput); await click; f.flush();
        const timedOut = await pending; rejected(timedOut);
        expect(JSON.parse(timedOut.debugStructure).expansionOutcome).toBe('timeout');
        const repeated = await f.run('inspect', expansionInput); rejected(repeated);
        expect(JSON.parse(repeated.debugStructure).expansionOutcome).toBe('timeout');
        expect(expand.clicks).toBe(1); expect(f.world.__computaModelFirstProof).toBeUndefined(); noSend(f, picker, send);
      });

      test('document, owner, count, body, prompt and mode drift during expansion retain the original rejection', async () => {
        for (const [outcome, mutate] of [
          ['context_changed', ({ f }: any) => { f.document.URL = 'https://chatgpt.com/c/foreign'; }],
          ['context_changed', ({ f }: any) => { f.world.__computaModelOwner = 'foreign'; }],
          ['context_changed', ({ f }: any) => f.appendUser('PRIVATE SECOND MESSAGE')],
          ['node_changed', ({ f, root }: any) => replaceFirstRoot(f, root, f.userBody)],
          ['context_changed', ({ f }: any) => { f.world.__computaModelFirstPrompt += 'PRIVATE DRIFT'; }],
          ['context_changed', ({ f }: any) => { f.temporary.connected = false; }],
          ['context_changed', ({ f }: any) => { f.chatMode.values['aria-pressed'] = 'false'; f.workMode.values['aria-pressed'] = 'true'; }],
          ['text_mismatch', ({ f }: any) => { f.userBody.text = 'PRIVATE DIFFERENT COMPLETE BODY\n\n' + markerLine; }],
        ] as [string, (stage: any) => void][]) {
          const stage = await collapsed();
          let dispatched!: () => void; const click = new Promise<void>(resolve => { dispatched = resolve; });
          stage.expand.onClick = () => dispatched();
          const pending = stage.f.run('inspect', expansionInput); await click;
          stage.f.userBody.text = stage.prompt; mutate(stage); notify(stage.f);
          const result = await pending; rejected(result); expect(stage.expand.clicks).toBe(1);
          expect(JSON.parse(result.debugStructure).expansionOutcome).toBe(outcome);
          expect(stage.f.world.__computaModelFirstProof).toBeUndefined(); noSend(stage.f, stage.picker, stage.send);
        }
      });

      test('context drift during the pre-expansion model await prevents even the display click', async () => {
        const { f, picker, expand, send } = await collapsed({ genericHeader: true });
        const click = picker.trigger.onClick; let changed = false;
        picker.trigger.onClick = () => { click(); if (!changed) { changed = true; f.userBody.text += 'PRIVATE DRIFT'; } };
        rejected(await f.run('inspect', expansionInput));
        expect(expand.clicks).toBe(0); expect(f.world.__computaModelFirstProof).toBeUndefined(); noSend(f, picker, send);
      });

      test('a recognized control in an adjacent foreign card is diagnostic-only and cannot receive expansion authority', async () => {
        const { f, picker, root, expand, send } = await collapsed();
        const parent = root.parentElement, wrapper = new Node('DIV'), foreign = new Node('DIV');
        parent.children = parent.children.filter((node: any) => node !== root);
        root.children = root.children.filter((node: any) => node !== expand); foreign.append(expand);
        wrapper.append(root, foreign); parent.append(wrapper);
        const result = await f.run('inspect', expansionInput); rejected(result);
        expect(JSON.parse(result.debugStructure)).toMatchObject({ scopedExpandControlCount: 1, expansionOutcome: 'unavailable' });
        expect(expand.clicks).toBe(0); noSend(f, picker, send);
      });

      test('a failed dispatch consumes its claim and a later inspection cannot click again', async () => {
        const { f, picker, expand, send } = await collapsed();
        expand.onClick = () => { throw new Error('PRIVATE CONTROL FAILURE'); };
        const first = await f.run('inspect', expansionInput); rejected(first);
        expect(JSON.parse(first.debugStructure).expansionOutcome).toBe('failed');
        rejected(await f.run('inspect', expansionInput)); expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });
    });

    if (provider === 'chatgpt') describe('finite first-user ownership diagnostics', () => {
      const failure = (result: any, reason: string, scope: string, action = 'inspect') => {
        expect(result).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
        const diagnostic = JSON.parse(result.debugStructure);
        expect(diagnostic).toMatchObject({ kind: 'first_user_structure', provider: 'chatgpt', reason, scope, action });
        expect(diagnostic.root.classes).toEqual([]); expect(diagnostic.body.classes).toEqual([]);
        expect(diagnostic.descendants).toBeUndefined();
        expect(result.debugStructure.length).toBeLessThanOrEqual(8192);
        return diagnostic;
      };
      const noMutation = (f: any, picker: any) => {
        expect(f.composer.textContent).toBe(''); expect(f.composer.events).toHaveLength(0);
        expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      };
      for (const [reason, mutate, overrides] of [
        ['marker_invalid', (f: any) => { f.world.__computaModelFirstSubmitted = false; }, { expectedFirstUserMarker: 'PRIVATE INVALID MARKER' }],
        ['submission_unclaimed', (f: any) => { f.world.__computaModelFirstSubmitted = false; f.world.__computaModelFirstMarker = 'foreign'; }, {}],
        ['marker_mismatch', (f: any) => { f.world.__computaModelFirstMarker = 'foreign'; f.userBody.text = ''; }, {}],
        ['body_limit', (f: any) => { f.userBody.text = 'x'.repeat(180_201); }, {}],
        ['marker_not_final', (f: any) => { f.userBody.text = 'Synthetic\n' + markerLine + '\nTrailing control'; }, {}],
        ['marker_duplicate', (f: any) => { f.userBody.text = 'Synthetic\n' + markerLine + '\n' + markerLine; }, {}],
        ['body_empty', (f: any) => { f.userBody.text = markerLine; }, {}],
      ] as [string, (f: any) => void, Record<string, unknown>][]) {
        test(`marker/body rejection retains ${reason} precedence without editor mutation`, async () => {
          const { f, picker } = setup(true); mutate(f);
          failure(await f.run('inspect', overrides), reason, 'marker_validation');
          expect(f.world.__computaModelFirstProof).toBeUndefined(); noMutation(f, picker);
        });
      }

      for (const reason of ['marker_mismatch', 'pinned_fingerprint', 'native_fingerprint']) {
        test(`private/native pin rejection identifies ${reason} without exposing pins`, async () => {
          const { f, picker } = setup(true);
          const first = await f.run('inspect');
          const overrides: Record<string, unknown> = {};
          if (reason === 'marker_mismatch') f.world.__computaModelFirstProof.marker = 'PRIVATE PIN MARKER';
          if (reason === 'pinned_fingerprint') f.world.__computaModelFirstProof.fingerprint = '0'.repeat(64);
          if (reason === 'native_fingerprint') overrides.expectedFirstUserFingerprint = 'f'.repeat(64);
          const result = await f.run('inspect', overrides), diagnostic = failure(result, reason, 'binding');
          expect(diagnostic.privatePinPresent).toBe(true); expect(diagnostic.expectedFingerprintPresent).toBe(true);
          expect(diagnostic.pinnedFingerprintMatch).toBe(reason !== 'pinned_fingerprint');
          expect(diagnostic.nativeFingerprintMatch).toBe(reason !== 'native_fingerprint');
          expect(result.debugStructure).not.toContain(first.firstUserFingerprint);
          expect(result.debugStructure).not.toContain('PRIVATE PIN MARKER'); noMutation(f, picker);
        });
      }

      test('an already-present unbound first bubble binds only through the pending first inspect', async () => {
        for (const action of ['verifyModel', 'prepare', 'inspect']) {
          const { f, picker } = setup(true);
          const result = await f.run(action, { expectedUserCounts: [0, 1], expectedModelChoice: choice(initial),
            ...(action === 'inspect' ? { allowFirstUserBinding: false } : {}) });
          expect(failure(result, 'binding_not_authorized', 'binding', action)).toMatchObject({ privatePinPresent: false,
            expectedFingerprintPresent: false, allowFirstUserBinding: action !== 'inspect' });
          expect(f.world.__computaModelFirstProof).toBeUndefined(); noMutation(f, picker);
        }
        const { f, picker } = setup(true);
        const first = await f.run('inspect', { expectedUserCounts: [0, 1], expectedModelChoice: choice(initial) });
        expect(first.firstUserVerified).toBe(true);
        expect(JSON.parse(first.firstUserDebugStructure)).toMatchObject({ kind: 'first_user_structure', reason: 'first_bound',
          scope: 'binding', action: 'inspect', privatePinPresent: true, expectedFingerprintPresent: false });
        const pendingPin = await f.run('inspect', { expectedUserCounts: [0, 1], expectedFirstUserFingerprint: undefined,
          allowFirstUserBinding: true, expectedModelChoice: choice(initial) });
        expect(pendingPin.firstUserFingerprint).toBe(first.firstUserFingerprint);
        expect(pendingPin.firstUserVerified).toBe(true);
        // An outer inspect can establish the JS pin before a nested native
        // recheck adopts it. That eligible recheck must carry the same finite
        // binding diagnostic; native's existing gate logs it exactly once.
        expect(typeof pendingPin.firstUserDebugStructure).toBe('string');
        expect(JSON.parse(pendingPin.firstUserDebugStructure)).toMatchObject({ kind: 'first_user_structure', reason: 'first_bound',
          scope: 'binding', action: 'inspect', privatePinPresent: true, expectedFingerprintPresent: false,
          allowFirstUserBinding: true, pinnedFingerprintMatch: true });
        const bound = await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
        expect(bound.firstUserVerified).toBe(true); expect(bound.firstUserDebugStructure).toBeUndefined();
        expect(JSON.parse(bound.debugStructure)).toMatchObject({ articleUsers: 1, articleAssistants: 1 });
        noMutation(f, picker);
      });

      test('missing first message reports absence independently of a present expected fingerprint', async () => {
        const { f, picker } = setup(false);
        const result = await f.run('inspect', { expectedFirstUserFingerprint: 'a'.repeat(64) });
        expect(failure(result, 'first_missing', 'first_missing')).toMatchObject({ userCount: 0,
          root: { tag: 'none' }, body: { tag: 'none' }, privatePinPresent: false, expectedFingerprintPresent: true });
        expect(result.debugStructure).not.toContain('a'.repeat(64)); noMutation(f, picker);
      });

      for (const scope of ['digest', 'model_precheck', 'action_final_guard']) {
        test(`first-body drift reports the ${scope} rejection boundary`, async () => {
          const { f, picker } = setup(true, { genericHeader: true });
          if (scope === 'digest') f.onDigest(() => { f.userBody.text += ' PRIVATE DIGEST DRIFT'; });
          else {
            await f.run('inspect', { expectedModelChoice: choice(initial) });
            const click = picker.trigger.onClick; let opens = 0;
            picker.trigger.onClick = () => {
              const opening = picker.menu.values.hidden !== undefined; click();
              if (opening && ++opens === (scope === 'model_precheck' ? 1 : 2)) f.userBody.text += ' PRIVATE MODEL DRIFT';
            };
          }
          const result = await f.run('inspect', { expectedModelChoice: choice(initial) });
          const diagnostic = failure(result, scope === 'digest' ? 'snapshot_before_action' : 'snapshot_after_action', scope);
          expect(diagnostic.snapshot).toEqual({ rootSame: true, bodySame: true, bodyConnected: true, textSame: false,
            countSame: true, urlSame: true, originSame: true, ownerSame: true });
          expect(result.debugStructure).not.toContain('PRIVATE'); noMutation(f, picker);
        });
      }

      test('replacement after private pin but before native binding remains a strict rejection', async () => {
        const { f, picker } = setup(true, { genericHeader: true });
        await f.run('inspect', { expectedModelChoice: choice(initial) });
        const root = firstRoot(f), body = f.userBody, pin = f.world.__computaModelFirstProof;
        const click = picker.trigger.onClick; let replaced = false;
        picker.trigger.onClick = () => {
          const opening = picker.menu.values.hidden !== undefined; click();
          if (opening && !replaced) { replaced = true; replaceFirstRoot(f, root, body); }
        };
        const result = await f.run('inspect', { expectedModelChoice: choice(initial),
          expectedFirstUserFingerprint: undefined, allowFirstUserBinding: true });
        expect(failure(result, 'snapshot_after_action', 'model_precheck')).toMatchObject({ privatePinPresent: true,
          expectedFingerprintPresent: false, snapshot: { rootSame: false, bodySame: false, bodyConnected: false } });
        expect(f.world.__computaModelFirstProof).toBe(pin); noMutation(f, picker);
      });

      test('outbound first insertion and submission failures expose finite predicate booleans only', async () => {
        for (const action of ['insert', 'submit']) for (const cause of action === 'insert' ? ['submitted', 'marker', 'suffix'] : ['submitted', 'prompt', 'suffix']) {
          const { f, picker } = setup(false), send = new Node('BUTTON', { 'data-testid': 'send-button' });
          f.body.append(send);
          const prompt = 'PRIVATE OUTBOUND PROMPT\n\n' + markerLine + (cause === 'suffix' ? '\nPRIVATE TAIL' : '');
          if (action === 'submit') { f.composer.text = prompt; f.world.__computaModelFirstPrompt = cause === 'prompt' ? 'PRIVATE OTHER PROMPT' : prompt; }
          if (cause === 'submitted') f.world.__computaModelFirstSubmitted = true;
          const result = await f.run(action, { prompt, ...(cause === 'marker' ? { expectedFirstUserMarker: 'PRIVATE INVALID MARKER' } : {}) });
          const diagnostic = failure(result, action === 'insert' ? 'first_insert' : 'first_submit', action === 'insert' ? 'first_insert' : 'first_submit', action);
          expect(diagnostic.submitted).toBe(cause === 'submitted'); expect(diagnostic.markerValid).toBe(cause !== 'marker');
          expect(diagnostic.firstPromptPresent).toBe(action === 'submit');
          expect(diagnostic.firstPromptMatches).toBe(action === 'submit' && cause !== 'prompt');
          expect(result.debugStructure).not.toContain('PRIVATE'); expect(result.debugStructure).not.toContain(firstMarker);
          expect(f.composer.textContent).toBe(action === 'submit' ? prompt : '');
          expect(f.composer.events).toHaveLength(0); expect(send.clicks).toBe(0);
          expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
        }
      });

      test('whole-article body fallback reports control-suffix rejection without changing selectors', async () => {
        const { f, picker } = setup(true), root = firstRoot(f);
        f.userBody.values = { 'data-user-message-bubble': '' };
        const result = await f.run('inspect');
        expect(failure(result, 'marker_not_final', 'marker_validation')).toMatchObject({ userCount: 1,
          root: { tag: 'article' }, body: { tag: 'article' }, controlDescendants: 1, markerFinalLine: false });
        expect(root.querySelector('[data-user-message-bubble]')).toBe(f.userBody);
        expect(f.world.__computaModelFirstProof).toBeUndefined(); noMutation(f, picker);
      });

      for (const kind of ['hidden_tail', 'wrong_body', 'clipped_body']) {
        test(`bounded alternate-body evidence distinguishes ${kind} without admitting or expanding it`, async () => {
          const { f, picker } = setup(true), root = firstRoot(f);
          const prompt = 'PRIVATE FULL PROMPT\n' + 'x'.repeat(14_000) + '\n\n' + markerLine;
          const rendered = kind === 'wrong_body' ? 'PRIVATE WRONG BODY\n' + 'z'.repeat(10_221) : prompt.slice(0, 10_240);
          f.world.__computaModelFirstPrompt = prompt;
          f.userBody.text = kind === 'hidden_tail' ? prompt : rendered;
          Object.defineProperty(f.userBody, 'innerText', { configurable: true, get: () => rendered });
          if (kind === 'wrong_body') root.append(new Node('DIV', { 'data-user-message-bubble': '' }, prompt));
          const expand = new Node('BUTTON', { 'aria-label': 'Show more' }, 'PRIVATE CONTROL CONTENT'); root.append(expand);
          const result = await f.run('inspect'), diagnostic = failure(result, 'marker_not_final', 'marker_validation');
          expect(diagnostic).toMatchObject({ bodySelection: 'whitespace_pre_wrap', textLength: rendered.length,
            bodyInnerTextLength: rendered.length, firstPromptLength: prompt.length, firstPromptAnalyzed: true,
            bodyTextContentAnalyzed: true, rootRenderedAnalyzed: true, rootTextContentAnalyzed: true,
            markerOccurrences: 0, bodyTextContentMarkerOccurrences: kind === 'hidden_tail' ? 1 : 0,
            bodyTextContentMarkerFinalLine: kind === 'hidden_tail',
            rootTextContentMarkerOccurrences: kind === 'clipped_body' ? 0 : 1,
            rootRenderedMarkerOccurrences: kind === 'clipped_body' ? 0 : 1,
            renderedPrefixOfFirstPrompt: kind !== 'wrong_body', scopedExpandControlCount: 1 });
          expect(diagnostic.bodyTextContentLength).toBe(kind === 'hidden_tail' ? prompt.length : rendered.length);
          expect(result.debugStructure).not.toContain('PRIVATE'); expect(result.debugStructure).not.toContain(firstMarker);
          expect(expand.clicks).toBe(0); expect(f.world.__computaModelFirstProof).toBeUndefined(); noMutation(f, picker);
        });
      }

      test('body selection diagnostics report existing selector precedence without changing it', async () => {
        for (const [selection, attributes] of [
          ['markdown_user_message', { 'data-markdown-text-style': 'user-message', class: 'whitespace-pre-wrap', 'data-message-author-role': 'user' }],
          ['whitespace_pre_wrap', { class: 'whitespace-pre-wrap', 'data-message-author-role': 'user' }],
          ['author_user', { 'data-message-author-role': 'user' }],
          ['root_fallback', { 'data-user-message-bubble': '' }],
        ] as [string, Record<string, string>][]) {
          const { f, picker } = setup(true); f.userBody.values = attributes;
          const result = await f.run('inspect', { expectedFirstUserMarker: 'invalid' });
          expect(failure(result, 'marker_invalid', 'marker_validation').bodySelection).toBe(selection);
          noMutation(f, picker);
        }
      });

      test('expand-control counts remain exact, physical, uniquely scoped and notification-only', async () => {
        for (const shared of [false, true]) {
          const { f, picker } = setup(true), root = firstRoot(f), parent = root.parentElement;
          const local = new Node('DIV'), known = ['Show more', 'View more', 'Read more', 'Expand']
            .map(label => new Node('BUTTON', { 'aria-label': label }, 'PRIVATE CONTROL CONTENT'));
          parent.children = parent.children.filter((node: any) => node !== root);
          local.append(root, ...known); parent.append(local);
          if (shared) local.append(new Node('ARTICLE', { 'data-turn': 'user' }, 'PRIVATE SIBLING MESSAGE'));
          const hidden = new Node('BUTTON', { 'aria-label': 'Show more', hidden: '' });
          const disconnected = new Node('BUTTON', { 'aria-label': 'View more' }); disconnected.connected = false;
          const arbitrary = new Node('BUTTON', { 'aria-label': 'PRIVATE LABEL Show more' });
          const outside = new Node('BUTTON', { 'aria-label': 'Read more' });
          root.append(hidden, disconnected, arbitrary); f.body.append(outside);
          const result = await f.run('inspect', { expectedFirstUserMarker: 'invalid', expectedUserCounts: [shared ? 2 : 1] });
          expect(failure(result, 'marker_invalid', 'marker_validation').scopedExpandControlCount).toBe(shared ? 0 : 4);
          expect([...known, hidden, disconnected, arbitrary, outside].every(control => control.clicks === 0)).toBe(true);
          expect(result.debugStructure).not.toContain('PRIVATE'); noMutation(f, picker);
        }
      });

      test('expand-control observation does not extend into composer or navigation wrappers', async () => {
        for (const [tag, attributes, wrapperRole] of [
          ['FORM', {}, ''], ['TEXTAREA', {}, ''], ['DIV', { contenteditable: 'true' }, ''],
          ['NAV', {}, ''], ['ASIDE', {}, ''], ['DIV', { role: 'navigation' }, ''],
          ['DIV', { role: 'complementary' }, ''], ['DIV', {}, 'main'],
          ['DIV', {}, 'navigation'], ['DIV', {}, 'complementary'],
        ] as [string, Record<string, string>, string][]) {
          const { f, picker } = setup(true), root = firstRoot(f), parent = root.parentElement;
          const wider = new Node('DIV', wrapperRole ? { role: wrapperRole } : {});
          const inside = new Node('BUTTON', { 'aria-label': 'Show more' });
          const outside = new Node('BUTTON', { 'aria-label': 'Read more' });
          root.append(inside); parent.children = parent.children.filter((node: any) => node !== root);
          wider.append(root, new Node(tag, attributes), outside); parent.append(wider);
          const result = await f.run('inspect', { expectedFirstUserMarker: 'invalid' });
          expect(failure(result, 'marker_invalid', 'marker_validation').scopedExpandControlCount).toBe(1);
          expect(inside.clicks + outside.clicks).toBe(0); noMutation(f, picker);
        }
      });

      test('oversized alternate text is counted with a sentinel but never analyzed as absent marker evidence', async () => {
        const { f, picker } = setup(true), root = firstRoot(f);
        const oversized = 'PRIVATE OVERSIZED TEXT ' + 'x'.repeat(220_001) + '\n' + markerLine;
        Object.defineProperty(f.userBody, 'innerText', { get: () => 'PRIVATE CLIPPED BODY' });
        Object.defineProperty(f.userBody, 'textContent', { get: () => oversized });
        Object.defineProperty(root, 'innerText', { get: () => oversized });
        Object.defineProperty(root, 'textContent', { get: () => oversized });
        f.world.__computaModelFirstPrompt = oversized;
        const result = await f.run('inspect'), diagnostic = failure(result, 'marker_not_final', 'marker_validation');
        expect(diagnostic).toMatchObject({ bodyTextContentLength: 220_001, rootRenderedTextLength: 220_001,
          rootTextContentLength: 220_001, firstPromptLength: 220_001, bodyTextContentAnalyzed: false,
          rootRenderedAnalyzed: false, rootTextContentAnalyzed: false, firstPromptAnalyzed: false });
        for (const prefix of ['bodyTextContent', 'rootRendered', 'rootTextContent']) {
          expect(diagnostic[prefix + 'MarkerOccurrences']).toBeUndefined(); expect(diagnostic[prefix + 'MarkerFinalLine']).toBeUndefined();
        }
        expect(diagnostic.renderedPrefixOfFirstPrompt).toBeUndefined();
        expect(result.debugStructure).not.toContain('PRIVATE'); expect(result.debugStructure).not.toContain(firstMarker); noMutation(f, picker);
      });

      test('alternate diagnostic property failures cannot obscure the original first-user rejection', async () => {
        const { f, picker } = setup(true);
        Object.defineProperty(f.userBody, 'innerText', { get: () => 'PRIVATE CLIPPED BODY' });
        Object.defineProperty(f.userBody, 'textContent', { get: () => { throw new Error('PRIVATE ALTERNATE FAILURE'); } });
        const result = await f.run('inspect'), diagnostic = failure(result, 'marker_not_final', 'marker_validation');
        expect(diagnostic.bodySelection).toBeUndefined();
        expect(result.debugStructure).not.toContain('PRIVATE'); noMutation(f, picker);
      });

      test('poisoned content and metadata never escape the finite diagnostic projection', async () => {
        const { f } = setup(true), root = firstRoot(f);
        // Bootstrap the normal product owner before poisoning the diagnostic
        // inputs, while deliberately leaving first-message proof unbound.
        await f.run('inspect', { expectedFirstUserMarker: 'invalid' });
        root.values = { 'data-message-author-role': 'user', id: 'PRIVATE ROOT ID', class: 'PRIVATE ROOT CLASS', 'data-private': 'PRIVATE ATTRIBUTE' };
        root.tagName = 'PRIVATE-TAG-CANARY';
        f.userBody.values = { class: 'whitespace-pre-wrap PRIVATE BODY CLASS', id: 'PRIVATE BODY ID' };
        f.userBody.text = 'PRIVATE PROMPT AND REPLY';
        f.document.URL += '&PRIVATE_URL_CANARY=secret';
        f.world.__computaModelFirstMarker = 'PRIVATE GLOBAL MARKER';
        f.world.__computaModelOwner = 'PRIVATE OWNER TOKEN';
        f.world.__computaModelFirstPrompt = 'PRIVATE STORED PROMPT';
        f.world.__computaModelFirstProof = { marker: 'PRIVATE PIN MARKER', fingerprint: 'PRIVATE PIN HASH' };
        const result = await f.run('inspect', { ownerToken: 'PRIVATE OWNER TOKEN', expectedFirstUserMarker: 'PRIVATE INPUT MARKER',
          expectedFirstUserFingerprint: 'PRIVATE NATIVE HASH', prompt: 'PRIVATE OUTBOUND PROMPT', unknown: 'PRIVATE UNKNOWN' });
        expect(failure(result, 'marker_invalid', 'marker_validation').root).toEqual({ tag: 'other', classes: [] });
        expect(result.debugStructure).not.toContain('PRIVATE'); expect(result.debugStructure).not.toContain(firstMarker);
        const allowed = new Set(['kind', 'provider', 'reason', 'scope', 'action', 'userCount', 'root', 'body', 'textLength',
          'lineCount', 'markerFinalLine', 'markerOccurrences', 'controlDescendants', 'submitted', 'markerMatches',
          'markerValid', 'allowFirstUserBinding', 'allowFirstUserExpansion', 'privatePinPresent', 'expectedFingerprintPresent', 'bodySelection',
          'bodyInnerTextLength', 'bodyTextContentLength', 'rootRenderedTextLength', 'rootTextContentLength', 'firstPromptLength',
          'bodyTextContentAnalyzed', 'rootRenderedAnalyzed', 'rootTextContentAnalyzed', 'firstPromptAnalyzed',
          'bodyTextContentMarkerOccurrences', 'rootRenderedMarkerOccurrences', 'rootTextContentMarkerOccurrences',
          'bodyTextContentMarkerFinalLine', 'rootRenderedMarkerFinalLine', 'rootTextContentMarkerFinalLine',
          'renderedPrefixOfFirstPrompt', 'scopedExpandControlCount', 'expansionOutcome', 'expansionContextFailure',
          'productProofFailure', 'productMutationRelevantCount', 'productMutationIgnoredCount',
          'expansionTextAnalyzed', 'expansionClicked', 'expansionExactPrefixMatches', 'expansionASCIIPrefixMatches',
          'expansionASCIIPromptMatches', 'expansionASCIIRenderedLength', 'expansionASCIIPrefixLength', 'expansionASCIIPromptLength',
          'expansionUnicodeSpaceCount', 'expansionExpectedUnicodeSpaceCount', 'expansionFormatCount', 'expansionExpectedFormatCount',
          'expansionFirstMismatchClass', 'expansionFirstMismatchOffset']);
        expect(Object.keys(JSON.parse(result.debugStructure)).every(key => allowed.has(key))).toBe(true);
      });

      test('diagnostic construction failure or unknown action retains the original ownership error', async () => {
        for (const broken of ['projection', 'action']) {
          const { f, picker } = setup(true);
          if (broken === 'projection') {
            const query = f.userBody.querySelectorAll.bind(f.userBody);
            f.userBody.querySelectorAll = (selector: string) => {
              if (selector === 'button, [role="button"]') throw new Error('PRIVATE DIAGNOSTIC FAILURE');
              return query(selector);
            };
          }
          const result = await f.run(broken === 'action' ? 'PRIVATE UNKNOWN ACTION' : 'inspect', { expectedFirstUserMarker: 'invalid' });
          expect(result).toEqual({ error: 'conversation_changed', detail: 'first_user_message' }); noMutation(f, picker);
        }
      });
    });

    if (provider === 'claude') test('Claude first-user diagnostics distinguish model-read body drift without private text', async () => {
      const { f, picker } = setup(true, { genericHeader: true });
      await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
      const body = f.userBody, click = picker.trigger.onClick; let changed = false;
      picker.trigger.onClick = () => { click(); if (!changed) { changed = true; body.text += ' PRIVATE BODY CHANGE'; } };
      const result = await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
      expect(result).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
      expect(JSON.parse(result.debugStructure)).toMatchObject({ kind: 'first_user_structure', provider: 'claude',
        root: { tag: 'div', classes: [] }, body: { tag: 'div', classes: [] }, controlDescendants: 0,
        snapshot: { rootSame: true, bodySame: true, bodyConnected: true, textSame: false, identitySame: true, countSame: true,
          urlSame: true, originSame: true, ownerSame: true } });
      expect(Number.isInteger(JSON.parse(result.debugStructure).lineCount)).toBe(true);
      expect(result.debugStructure).not.toContain('PRIVATE'); expect(result.debugStructure).not.toContain(firstMarker);
      expect(result.debugStructure.length).toBeLessThanOrEqual(8192);
    });

    test('generic closed headers freshly read checked family radios after portal unmount', async () => {
      const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
      const result = await advance(f, 'selectModel', { modelChoice: choice(target) });
      expect(result).toMatchObject({ selected: true, modelEvidence: { selected: choice(target), source: 'checked_model_option' } });
      expect(picker.menu.isConnected).toBe(false);
      const selected = picker.options.find((option: any) => option.children[0].text === target);
      expect(selected.clicks).toBe(1);
      for (let i = 0; i < 3; i++) {
        const proof = await f.run('verifyModel', { expectedModelChoice: choice(target) });
        expect(proof.modelEvidence).toMatchObject({ selected: choice(target), source: 'checked_model_option' });
        expect(picker.menu.isConnected).toBe(false);
      }
      expect(selected.clicks).toBe(1);
      picker.selected(initial);
      expect(await f.run('verifyModel', { expectedModelChoice: choice(target) })).toMatchObject({ error: 'model_mismatch' });
      expect(selected.clicks).toBe(1);
    });

    test('failed picker reads expose only finite scope and selection flags', async () => {
      const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
      f.world.__computaModelSelection = { clicked: 'PRIVATE_CLICK_VALUE', settled: 'PRIVATE_SETTLE_VALUE',
        completed: 'PRIVATE_COMPLETE_VALUE', arbitrary: 'PRIVATE_UNRECOGNIZED_FIELD' };
      picker.trigger.onClick = () => {};
      const observing = f.run('verifyModel', { expectedModelChoice: choice(initial) });
      for (let tick = 0; tick < 10; tick++) await Promise.resolve();
      f.flush();
      const result = await observing;
      expect(result).toMatchObject({ error: 'model_unverified', modelDiagnostic: { readContext: {
        scope: provider === 'chatgpt' ? 'action_final_guard' : 'action_precheck', action: 'verifyModel', selectionAttemptPresent: true,
        selectionClicked: false, selectionSettled: false, selectionCompleted: false, recoveryEligible: false,
      } } });
      expect(JSON.stringify(result.modelDiagnostic)).not.toContain('PRIVATE');
      expect(picker.trigger.clicks).toBe(1);
    });

    if (provider === 'chatgpt') {
      const clickedFamily = async (f: any) => {
        for (let stage = 0; stage < 3; stage++) expect((await f.run('selectModel', { modelChoice: choice(target) })).pending).toBe(true);
      };
      const microtasks = async () => { for (let tick = 0; tick < 10; tick++) await Promise.resolve(); };

      test('prepare needs one final proof opening when a redundant second opening would be ignored', async () => {
        const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
        f.composer.focus = () => { f.document.activeElement = f.composer; };
        const click = picker.trigger.onClick;
        let openings = 0;
        picker.trigger.onClick = () => { if (++openings === 1) click(); };
        const observing = f.run('prepare', { expectedModelChoice: choice(initial) });
        for (let tick = 0; tick < 20; tick++) await Promise.resolve();
        f.flush();
        expect(await observing).toMatchObject({ prepared: true,
          modelEvidence: { selected: choice(initial), source: 'checked_model_option' } });
        expect(openings).toBe(1);
        expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
        expect(f.composer.textContent).toBe('');
      });

      test('focus-only prepare rejects a model change before any insertion', async () => {
        const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
        f.composer.focus = () => { f.document.activeElement = f.composer; picker.selected(target); };
        expect(await f.run('prepare', { expectedModelChoice: choice(initial) }))
          .toMatchObject({ error: 'model_mismatch', modelEvidence: { selected: choice(target) } });
        expect(picker.trigger.clicks).toBe(1);
        expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
        expect(f.composer.textContent).toBe('');
        expect(f.world.__computaModelFirstSubmitted).toBeUndefined();
      });

      test('legacy verification without a concrete choice retains its existing read behavior', async () => {
        const { f, picker } = setup();
        f.temporary.connected = false;
        const result = await f.run('verifyModel');
        expect(result.error).toBeUndefined();
        expect(result.modelEvidence.selected).toEqual(choice(initial));
        expect(picker.trigger.clicks).toBe(0);
      });

      test('a failed final picker read keeps its scoped error when mode remains hidden', async () => {
        for (const action of ['prepare', 'verifyModel']) {
          const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
          picker.trigger.onClick = () => { f.temporary.values['aria-hidden'] = 'true'; };
          const observing = f.run(action, { expectedModelChoice: choice(initial) });
          await microtasks(); f.flush();
          const result = await observing;
          expect(result).toMatchObject({ error: 'model_unverified', modelDiagnostic: {
            readStage: 'primary_open_requested', readContext: { scope: 'action_final_guard', action },
          } });
          expect(result.prepared).toBeUndefined(); expect(result.modelEvidence).toBeUndefined();
          expect(picker.trigger.clicks).toBe(1);
        }
      });

      test('one-proof preparation and verification reject context drift after the final await', async () => {
        for (const action of ['prepare', 'verifyModel']) for (const owned of [false, true])
          for (const drift of ['owner', 'url', 'origin', 'top_frame', 'user_count', 'temporary_mode']) {
            const { f, picker } = setup(owned, { genericHeader: true, unmountMenus: true });
            if (owned) await f.run('inspect', { expectedModelChoice: choice(initial) });
            const escape = picker.nested.onDispatch;
            picker.nested.onDispatch = (event: any) => {
              escape(event);
              if (drift === 'owner') f.world.__computaModelOwner = 'foreign-owner';
              if (drift === 'url') f.document.URL += '&foreign-route=true';
              if (drift === 'origin') f.location.origin = 'https://foreign.invalid';
              if (drift === 'top_frame') f.window.top = {};
              if (drift === 'user_count') f.appendUser('Foreign unacknowledged user');
              if (drift === 'temporary_mode') f.temporary.connected = false;
            };
            const result = await f.run(action, { expectedModelChoice: choice(initial) });
            expect(result.error).toBeDefined();
            expect(result.error).not.toBe('acknowledged_user_append');
            expect(result.prepared).toBeUndefined();
            expect(result.inserted).toBeUndefined(); expect(result.submitted).toBeUndefined();
            expect(result.text).toBeUndefined();
            expect(f.composer.textContent).toBe('');
            expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
          }
      });

      test('same-current selection waits for deferred trigger closure before the next proof opening', async () => {
        for (const attribute of ['aria-expanded', 'data-state']) {
          const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true, escapeOnlyClose: true });
          expect(await advance(f, 'selectModel', { modelChoice: choice(initial) }))
            .toMatchObject({ selected: true, modelEvidence: { selected: choice(initial) } });
          expect(f.world.__computaModelSelection.clicked).toBe(false);
          const escape = picker.menu.onDispatch, nestedEscape = picker.nested.onDispatch, click = picker.trigger.onClick;
          let closing = false, deferred = false, consumed = 0;
          const close = (original: (event: any) => void) => (event: any) => {
            original(event);
            if (!deferred && event.key === 'Escape') {
              deferred = true; closing = true;
              picker.trigger.values[attribute] = attribute === 'aria-expanded' ? 'true' : 'open';
            }
          };
          picker.menu.onDispatch = close(escape); picker.nested.onDispatch = close(nestedEscape);
          picker.trigger.onClick = () => { if (closing) consumed++; else click(); };
          const before = picker.trigger.clicks;
          const observing = (async () => {
            const first = await f.run('verifyModel', { expectedModelChoice: choice(initial) });
            return first.error ? first : f.run('verifyModel', { expectedModelChoice: choice(initial) });
          })();
          await microtasks();
          const prematureOpenings = consumed;
          closing = false;
          picker.trigger.values[attribute] = attribute === 'aria-expanded' ? 'false' : 'closed';
          for (const observer of f.observers) observer.callback([{ type: 'attributes', target: picker.trigger, attributeName: attribute }]);
          // Before the fix the next opening is consumed; expire that existing
          // deadline so the regression reports its outcome instead of hanging.
          if (prematureOpenings) { f.advanceTime(1_800); f.flush(); }
          const result = await observing;
          expect(prematureOpenings).toBe(0);
          expect(result).toMatchObject({ modelEvidence: { selected: choice(initial), source: 'checked_model_option' } });
          expect(picker.trigger.clicks - before).toBe(1);
          expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
          expect(f.world.__computaModelSelection.openingRecoveryAttempted).toBeUndefined();
        }
      });

      test('unrestored or replaced closed triggers cannot admit proof or another opening', async () => {
        for (const drift of ['open_attribute', 'disabled', 'replaced', 'foreign_menu']) {
          const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true, escapeOnlyClose: true });
          const escape = picker.nested.onDispatch;
          picker.nested.onDispatch = (event: any) => {
            escape(event);
            if (drift === 'open_attribute') picker.trigger.values['data-state'] = 'open';
            if (drift === 'disabled') picker.trigger.disabled = true;
            if (drift === 'replaced') {
              picker.trigger.connected = false;
              f.body.append(new Node('BUTTON', { ...picker.trigger.values }));
            }
            if (drift === 'foreign_menu') f.body.append(new Node('DIV', { role: 'menu', id: 'foreign-menu' }));
          };
          const observing = f.run('verifyModel', { expectedModelChoice: choice(initial) });
          await microtasks(); f.advanceTime(1_800); f.flush();
          expect(await observing).toMatchObject({ error: 'model_unverified', modelDiagnostic: { readStage: 'close_unconfirmed' } });
          expect(picker.trigger.clicks).toBe(1);
          expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
        }
      });

      test('read diagnostics distinguish final guards from completed-selection checks', async () => {
        for (const scope of ['action_final_guard', 'completed_selection']) {
          const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
          if (scope === 'completed_selection') {
            await advance(f, 'selectModel', { modelChoice: choice(initial) });
            await f.run('verifyModel', { expectedModelChoice: choice(initial) });
          }
          let openings = 0;
          picker.trigger.onClick = () => { openings++; };
          const action = scope === 'completed_selection' ? 'selectModel' : 'verifyModel';
          const observing = f.run(action, action === 'selectModel' ? { modelChoice: choice(initial) } : { expectedModelChoice: choice(initial) });
          await microtasks(); f.advanceTime(1_800); f.flush();
          const result = await observing;
          expect(result).toMatchObject({ error: 'model_unverified', modelDiagnostic: { readContext: {
            scope, action, selectionAttemptPresent: scope === 'completed_selection', selectionClicked: false,
            selectionCompleted: scope === 'completed_selection', recoveryEligible: false,
          } } });
          expect(openings).toBe(1);
        }
      });

      test('a family panel returning to its associated parent is closed once before fresh checked proof', async () => {
        const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true, escapeOnlyClose: true,
          inlineFamilyPanel: true, parentReturnAfterSelection: true });
        const background = new Node('DIV'); f.body.children = f.body.children.filter((node: any) => node !== f.temporary);
        background.append(f.temporary); f.body.append(background);
        const selected = picker.options.find((option: any) => option.children[0].text === target), click = selected.onClick;
        selected.onClick = () => { click(); background.values['aria-hidden'] = 'true'; };
        const escape = picker.menu.onDispatch;
        picker.menu.onDispatch = (event: any) => { escape(event); delete background.values['aria-hidden']; };
        await clickedFamily(f);
        expect(picker.menu.isConnected).toBe(true); expect(picker.menu.values.hidden).toBeUndefined();
        expect(picker.inlinePanel.values.hidden).toBe('');
        expect((await f.run('modelDiagnostic')).modelEvidence).toBeFalsy();
        const before = picker.trigger.clicks;
        const result = await f.run('selectModel', { modelChoice: choice(target) });
        expect(result).toMatchObject({ selected: true, modelEvidence: { selected: choice(target), source: 'checked_model_option' } });
        expect(picker.menu.events.filter((event: any) => event.key === 'Escape').length).toBe(2);
        expect(picker.trigger.clicks - before).toBe(1); expect(selected.clicks).toBe(1);
        expect(f.world.__computaModelSelection.selectionCloseAttempted).toBe(true);
        expect(f.world.__computaModelSelection.openingRecoveryAttempted).toBeUndefined();
        expect(picker.menu.isConnected).toBe(false);
      });

      test('an ignored post-family parent close is attempted once and cannot admit selection or reopen', async () => {
        const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true, escapeOnlyClose: true,
          inlineFamilyPanel: true, parentReturnAfterSelection: true });
        await clickedFamily(f); picker.menu.onDispatch = () => {};
        const before = picker.trigger.clicks, observing = f.run('selectModel', { modelChoice: choice(target) });
        await microtasks(); f.advanceTime(1_800); f.flush();
        expect(await observing).toMatchObject({ error: 'model_unverified', modelDiagnostic: { readStage: 'selection_commit_unconfirmed',
          readAttempt: { closeAttempted: true, observedProof: false, sameTrigger: true, popupStillAssociated: true } } });
        for (let retry = 0; retry < 3; retry++) expect((await f.run('selectModel', { modelChoice: choice(target) })).error).toBe('model_unverified');
        expect(picker.menu.events.filter((event: any) => event.key === 'Escape').length).toBe(1);
        expect(picker.trigger.clicks).toBe(before); expect(f.world.__computaModelSelection.completed).toBeUndefined();
        expect(picker.options.find((option: any) => option.children[0].text === target).clicks).toBe(1);
        expect(f.composer.textContent).toBe('');
      });

      test('a lost post-family Escape acknowledgment cannot replay the claimed parent close', async () => {
        const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true, escapeOnlyClose: true,
          inlineFamilyPanel: true, parentReturnAfterSelection: true });
        await clickedFamily(f); const escape = picker.menu.onDispatch;
        picker.menu.onDispatch = (event: any) => { escape(event); throw new Error('lost parent Escape'); };
        await expect(f.run('selectModel', { modelChoice: choice(target) })).rejects.toThrow('lost parent Escape');
        for (let retry = 0; retry < 3; retry++) expect((await f.run('selectModel', { modelChoice: choice(target) })).error).toBe('model_unverified');
        expect(picker.menu.events.filter((event: any) => event.key === 'Escape').length).toBe(1);
        expect(f.world.__computaModelSelection.completed).toBeUndefined();
        expect(picker.options.find((option: any) => option.children[0].text === target).clicks).toBe(1);
      });

      test('post-family parent ownership, root and association drift rejects before any close', async () => {
        for (const change of [
          (f: any) => { f.world.__computaModelOwner = 'foreign-owner'; },
          (f: any) => { f.document.URL += '&foreign-route=true'; },
          (f: any) => { f.location.origin = 'https://foreign.invalid'; },
          (f: any) => { f.appendUser('Unclaimed user before parent close'); },
          (f: any) => { f.body.append(new Node('ARTICLE', { 'data-turn': 'assistant' }, 'Unclaimed assistant')); },
          (f: any) => { f.world.__computaModelFirstProof = { marker: firstMarker, fingerprint: 'a'.repeat(64) }; },
          (f: any, p: any) => { p.trigger.connected = false; },
          (f: any, p: any) => { p.trigger.disabled = true; },
          (f: any) => { f.body.append(new Node('DIV', { role: 'menu', id: 'foreign-menu' })); },
          (f: any, p: any) => { delete p.trigger.values['aria-controls']; delete p.menu.values['aria-labelledby']; },
          (f: any, p: any) => { const duplicate = new Node('DIV', { role: 'menuitem', 'aria-label': 'Select model' }); p.menu.append(duplicate); },
          (f: any, p: any) => { delete p.inlinePanel.values.hidden; p.options[0].values['aria-checked'] = 'true'; },
        ]) {
          const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true, escapeOnlyClose: true,
            inlineFamilyPanel: true, parentReturnAfterSelection: true });
          await clickedFamily(f); const before = picker.trigger.clicks; change(f, picker);
          const result = await f.run('selectModel', { modelChoice: choice(target) });
          expect(result.error).toBeDefined(); expect(result.selected).toBeUndefined();
          expect(picker.menu.events.filter((event: any) => event.key === 'Escape').length).toBe(0);
          expect(picker.trigger.clicks).toBe(before); expect(f.composer.textContent).toBe('');
          expect(picker.options.find((option: any) => option.children[0].text === target).clicks).toBe(1);
        }
      });

      test('post-family parent close never turns stale model or temporary mode into proof', async () => {
        for (const driftModel of [false, true]) {
          const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true, escapeOnlyClose: true,
            inlineFamilyPanel: true, parentReturnAfterSelection: true });
          await clickedFamily(f); const escape = picker.menu.onDispatch;
          picker.menu.onDispatch = (event: any) => {
            escape(event);
            if (driftModel) { picker.selected(initial); picker.primary.text = initial; }
            else f.temporary.connected = false;
          };
          const before = picker.trigger.clicks, observing = f.run('selectModel', { modelChoice: choice(target) });
          await microtasks(); if (!driftModel) { f.advanceTime(1_800); f.flush(); }
          const result = await observing;
          expect(result.error).toBe(driftModel ? 'model_mismatch' : 'model_unverified');
          expect(result.selected).toBeUndefined(); expect(picker.trigger.clicks).toBe(before);
          expect(picker.menu.events.filter((event: any) => event.key === 'Escape').length).toBe(1);
          expect(picker.options.find((option: any) => option.children[0].text === target).clicks).toBe(1);
        }
      });

      test('one consumed post-family opening recovers actual checked proof without any render callbacks', async () => {
        for (const frameAPI of [undefined, () => { throw new Error('rAF must not be used'); }]) {
          const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true, escapeOnlyClose: true, inlineFamilyPanel: true });
          f.window.requestAnimationFrame = frameAPI;
          const selected = picker.options.find((option: any) => option.children[0].text === target), click = picker.trigger.onClick;
          let consumed = 0;
          picker.trigger.onClick = () => { if (selected.clicks === 1 && consumed === 0) consumed++; else click(); };
          await clickedFamily(f);
          const before = picker.trigger.clicks, observing = f.run('selectModel', { modelChoice: choice(target) });
          await microtasks();
          expect(picker.trigger.clicks - before).toBe(1); expect(f.world.__computaModelSelection.completed).toBeUndefined();
          expect(f.scheduledDelays.at(-1)).toBeLessThanOrEqual(900);
          f.advanceTime(900); f.flush();
          expect(await observing).toMatchObject({ selected: true, modelEvidence: { selected: choice(target), source: 'checked_model_option' } });
          expect(picker.trigger.clicks - before).toBe(2); expect(consumed).toBe(1); expect(selected.clicks).toBe(1);
          expect(f.world.__computaModelSelection.openingRecoveryAttempted).toBe(true);
          expect(picker.menu.isConnected).toBe(false);
        }
      });

      test('a family-change popup closure must be acknowledged before any fresh opening', async () => {
        const { f, picker } = setup(false, { genericHeader: true, escapeOnlyClose: true, inlineFamilyPanel: true });
        const selected = picker.options.find((option: any) => option.children[0].text === target), click = selected.onClick;
        selected.onClick = () => { click(); delete picker.menu.values.hidden; picker.trigger.values['aria-expanded'] = 'true'; };
        const escape = picker.menu.onDispatch; let delayedClose = true;
        picker.menu.onDispatch = (event: any) => { if (delayedClose) { delayedClose = false; return; } escape(event); };
        await clickedFamily(f);
        const before = picker.trigger.clicks, observing = f.run('selectModel', { modelChoice: choice(target) });
        await microtasks(); expect(picker.trigger.clicks).toBe(before);
        picker.menu.values.hidden = ''; picker.trigger.values['aria-expanded'] = 'false';
        for (const observer of f.observers) observer.callback([{ type: 'attributes', target: picker.menu, attributeName: 'hidden' }]);
        expect(await observing).toMatchObject({ selected: true, modelEvidence: { selected: choice(target), source: 'checked_model_option' } });
        expect(selected.clicks).toBe(1); expect(picker.trigger.clicks - before).toBe(1);
        expect(f.world.__computaModelSelection.openingRecoveryAttempted).toBeUndefined();
      });

      test('two unacknowledged fresh openings share one deadline and become a terminal failure', async () => {
        const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
        const selected = picker.options.find((option: any) => option.children[0].text === target), click = picker.trigger.onClick;
        picker.trigger.onClick = () => { if (selected.clicks === 0) click(); };
        await clickedFamily(f);
        const before = picker.trigger.clicks, observing = f.run('selectModel', { modelChoice: choice(target) });
        await microtasks(); f.advanceTime(900); f.flush(); await microtasks();
        expect(picker.trigger.clicks - before).toBe(2);
        expect(f.scheduledDelays.at(-1)).toBeLessThanOrEqual(900);
        f.advanceTime(900); f.flush();
        expect(await observing).toMatchObject({ error: 'model_unverified', modelDiagnostic: { readStage: 'primary_open_recovery_requested',
          readContext: { scope: 'post_selection', action: 'selectModel', selectionAttemptPresent: true,
            selectionClicked: true, selectionSettled: true, selectionCompleted: false, recoveryEligible: true } } });
        for (let retry = 0; retry < 3; retry++) expect((await f.run('selectModel', { modelChoice: choice(target) })).error).toBe('model_unverified');
        expect(picker.trigger.clicks - before).toBe(2); expect(selected.clicks).toBe(1);
        expect(f.world.__computaModelSelection.completed).toBeUndefined(); expect(f.composer.textContent).toBe('');
      });

      test('fresh recovery guards reject crossed ownership, mode, roots and closed picker state before the extra click', async () => {
        for (const change of [
          (f: any) => { f.world.__computaModelOwner = 'changed-owner'; },
          (f: any) => { f.document.URL += '&foreign-route=true'; },
          (f: any) => { f.location.origin = 'https://foreign.invalid'; },
          (f: any, p: any) => { p.trigger.connected = false; },
          (f: any, p: any) => { p.trigger.disabled = true; },
          (f: any) => { f.temporary.connected = false; },
          (f: any) => { f.appendUser('Foreign user while opening'); },
          (f: any) => { f.body.append(new Node('ARTICLE', { 'data-turn': 'assistant' }, 'Foreign assistant')); },
          (f: any) => { f.world.__computaModelFirstSubmitted = true; },
          (f: any) => { f.world.__computaModelFirstProof = { marker: firstMarker, fingerprint: 'a'.repeat(64) }; },
          (f: any, p: any) => { p.trigger.values['data-state'] = 'open'; },
          (f: any, p: any) => { p.trigger.values['aria-expanded'] = 'true'; },
          (f: any) => { f.body.append(new Node('DIV', { id: 'foreign-menu', role: 'menu' })); },
          (f: any, p: any) => { const duplicate = new Node('BUTTON', { ...p.trigger.values }); f.body.append(duplicate); },
        ]) {
          const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
          const selected = picker.options.find((option: any) => option.children[0].text === target), click = picker.trigger.onClick;
          picker.trigger.onClick = () => { if (selected.clicks === 0) click(); };
          await clickedFamily(f);
          const before = picker.trigger.clicks, observing = f.run('selectModel', { modelChoice: choice(target) });
          await microtasks(); change(f, picker); f.advanceTime(900); f.flush();
          const result = await observing;
          expect(result.error).toBeDefined(); expect(result.selected).toBeUndefined(); expect(result.modelEvidence).toBeUndefined();
          expect(picker.trigger.clicks - before).toBe(1); expect(selected.clicks).toBe(1);
          expect(f.world.__computaModelSelection.openingRecoveryAttempted).toBeUndefined();
          expect(f.composer.textContent).toBe('');
        }
      });

      test('model mismatch discovered after a consumed opening rejects without an extra opening', async () => {
        const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
        const selected = picker.options.find((option: any) => option.children[0].text === target), click = picker.trigger.onClick;
        picker.trigger.onClick = () => { if (selected.clicks === 0) click(); };
        await clickedFamily(f);
        const before = picker.trigger.clicks, observing = f.run('selectModel', { modelChoice: choice(target) });
        await microtasks(); picker.primary.text = initial; f.advanceTime(900); f.flush();
        expect(await observing).toMatchObject({ error: 'model_mismatch', modelEvidence: { selected: choice(initial) } });
        expect(picker.trigger.clicks - before).toBe(1); expect(selected.clicks).toBe(1);
        expect(f.world.__computaModelSelection.openingRecoveryAttempted).toBeUndefined();
      });

      test('an acknowledged associated menu still requires exact current checked proof after recovery', async () => {
        const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
        const selected = picker.options.find((option: any) => option.children[0].text === target), click = picker.trigger.onClick;
        let consumed = false;
        picker.trigger.onClick = () => {
          if (selected.clicks === 0) return click();
          if (!consumed) { consumed = true; return; }
          picker.selected(initial); click();
        };
        await clickedFamily(f);
        const observing = f.run('selectModel', { modelChoice: choice(target) });
        await microtasks(); f.advanceTime(900); f.flush();
        expect(await observing).toMatchObject({ error: 'model_mismatch', modelEvidence: { selected: choice(initial) } });
        expect(selected.clicks).toBe(1); expect(f.world.__computaModelSelection.completed).toBeUndefined();
      });

      test('a recovered opening crossed by new message roots or owner state cannot return proof', async () => {
        for (const change of [
          (f: any) => { f.appendUser('Unclaimed new user'); },
          (f: any) => { f.body.append(new Node('ARTICLE', { 'data-turn': 'assistant' }, 'Unclaimed new answer')); },
          (f: any) => { f.world.__computaModelFirstSubmitted = true; },
          (f: any) => { f.world.__computaModelOwner = 'foreign-owner'; },
        ]) {
          const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
          const selected = picker.options.find((option: any) => option.children[0].text === target), click = picker.trigger.onClick;
          let consumed = false;
          picker.trigger.onClick = () => {
            if (selected.clicks === 0) return click();
            if (!consumed) { consumed = true; return; }
            click(); change(f);
          };
          await clickedFamily(f);
          const observing = f.run('selectModel', { modelChoice: choice(target) });
          await microtasks(); f.advanceTime(900); f.flush();
          const result = await observing;
          expect(result.error).toBe('model_unverified'); expect(result.modelEvidence).toBeUndefined();
          expect(result.selected).toBeUndefined(); expect(selected.clicks).toBe(1); expect(f.composer.textContent).toBe('');
        }
      });

      test('temporary mode can be hidden by its associated modal but must verify again after owned close', async () => {
        for (const driftMode of [false, true]) {
          const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true, escapeOnlyClose: true, inlineFamilyPanel: true });
          await clickedFamily(f);
          const click = picker.trigger.onClick, escape = picker.menu.onDispatch;
          picker.trigger.onClick = () => { click(); f.temporary.values['aria-hidden'] = 'true'; };
          picker.menu.onDispatch = (event: any) => { escape(event); delete f.temporary.values['aria-hidden']; if (driftMode) f.temporary.connected = false; };
          const result = await f.run('selectModel', { modelChoice: choice(target) });
          expect(result.selected).toBe(driftMode ? undefined : true);
          if (driftMode) expect(result.error).toBe('model_unverified');
          else expect(result.modelEvidence).toMatchObject({ selected: choice(target), source: 'checked_model_option' });
          expect(picker.menu.events.filter((event: any) => event.key === 'Escape').length).toBe(1);
          expect(picker.options.find((option: any) => option.children[0].text === target).clicks).toBe(1);
        }
      });

      test('the fresh-opening recovery is never available to generic or established conversation reads', async () => {
        for (const owned of [false, true]) {
          const { f, picker } = setup(owned, { genericHeader: true, unmountMenus: true });
          if (owned) expect((await f.run('inspect', { expectedModelChoice: choice(initial) })).firstUserVerified).toBe(true);
          const before = picker.trigger.clicks;
          picker.trigger.onClick = () => { queueMicrotask(() => f.flush()); };
          const observing = f.run('verifyModel', { expectedModelChoice: choice(initial) });
          await microtasks(); f.flush(); await microtasks(); f.flush();
          expect((await observing).error).toBe('model_unverified'); expect(picker.trigger.clicks - before).toBe(1);
          expect(f.world.__computaModelSelection).toBeUndefined();
          expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
        }
      });

      test('a lost first post-selection read acknowledgment cannot replay its opening click', async () => {
        const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
        const selected = picker.options.find((option: any) => option.children[0].text === target), click = picker.trigger.onClick;
        picker.trigger.onClick = () => { if (selected.clicks === 1) throw new Error('lost fresh opening'); else click(); };
        await f.run('selectModel', { modelChoice: choice(target) }); await f.run('selectModel', { modelChoice: choice(target) });
        await f.run('selectModel', { modelChoice: choice(target) });
        await expect(f.run('selectModel', { modelChoice: choice(target) })).rejects.toThrow('lost fresh opening');
        const after = picker.trigger.clicks;
        for (let retry = 0; retry < 3; retry++) expect((await f.run('selectModel', { modelChoice: choice(target) })).error).toBe('model_unverified');
        expect(picker.trigger.clicks).toBe(after); expect(selected.clicks).toBe(1);
        expect(f.world.__computaModelSelection.completed).toBeUndefined();
      });

      test('the observed Select model menuitem needs no popup attribute to expose inline family radios', async () => {
        const discovery = setup(false, { genericHeader: true, unmountMenus: true, escapeOnlyClose: true, inlineFamilyPanel: true });
        expect(discovery.picker.secondary.values['aria-haspopup']).toBeUndefined();
        expect(discovery.picker.secondary.childElementCount).toBeGreaterThan(0);
        const found = await advance(discovery.f, 'discoverModels');
        expect(found.modelChoices).toEqual(['GPT-5.6 Sol', 'GPT-5.5'].map(choice));
        expect(found.modelDiagnostic.associatedMenus.length).toBe(1);
        expect(discovery.picker.secondary.clicks).toBe(1);
        const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true, escapeOnlyClose: true, inlineFamilyPanel: true });
        expect(await advance(f, 'selectModel', { modelChoice: choice('Latest') })).toMatchObject({ selected: true,
          modelEvidence: { selected: choice('Latest'), source: 'checked_model_option' } });
        expect((await f.run('verifyModel', { expectedModelChoice: choice('Latest') })).modelEvidence.selected).toEqual(choice('Latest'));
        expect(picker.options.find((option: any) => option.children[0].text === 'Latest').clicks).toBe(1);
        expect(picker.menu.events.every((event: any) => event.type === 'keydown' && event.key === 'Escape' && event.code === 'Escape'
          && event.bubbles && event.cancelable)).toBe(true);
        expect(picker.menu.isConnected).toBe(false);
      });

      test('a family popup replacing the power menu supplies fresh associated checked proof', async () => {
        const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true, replacePrimaryOnSecondary: true, escapeOnlyClose: true });
        for (let index = 0; index < 3; index++) {
          const result = await f.run('verifyModel', { expectedModelChoice: choice(initial) });
          expect(result.modelEvidence).toMatchObject({ selected: choice(initial), source: 'checked_model_option' });
          expect(picker.menu.isConnected).toBe(false); expect(picker.nested.isConnected).toBe(false);
        }
        expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
        expect(picker.secondary.clicks).toBe(3); expect(picker.trigger.clicks).toBe(3);
        expect(picker.nested.events.filter((event: any) => event.key === 'Escape').length).toBe(3);
        picker.selected(target);
        expect((await f.run('verifyModel', { expectedModelChoice: choice(initial) })).error).toBe('model_mismatch');
      });

      test('discovery and single-click target selection survive a replacement family menu', async () => {
        const discovery = setup(false, { genericHeader: true, unmountMenus: true, replacePrimaryOnSecondary: true, escapeOnlyClose: true });
        const result = await advance(discovery.f, 'discoverModels');
        expect(result.modelChoices).toEqual(['GPT-5.6 Sol', 'GPT-5.5'].map(choice));
        expect(result.modelDiagnostic.associatedMenus.length).toBe(1);
        expect(discovery.picker.secondary.clicks).toBe(1);
        const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true, replacePrimaryOnSecondary: true, escapeOnlyClose: true });
        expect(await advance(f, 'selectModel', { modelChoice: choice(target) })).toMatchObject({ selected: true,
          modelEvidence: { selected: choice(target), source: 'checked_model_option' } });
        const selected = picker.options.find((option: any) => option.children[0].text === target);
        expect(selected.clicks).toBe(1);
        expect((await f.run('selectModel', { modelChoice: choice(target) })).selected).toBe(true);
        expect(selected.clicks).toBe(1);
        picker.trigger.onClick(); picker.secondary.onClick();
        delete picker.trigger.values['aria-controls']; delete picker.nested.values['aria-labelledby'];
        expect((await f.run('verifyModel', { expectedModelChoice: choice(target) })).error).toBe('model_unverified');
        expect(selected.clicks).toBe(1);
      });

      test('an ignored Escape leaves fresh categorical diagnostics and never retries dismissal', async () => {
        const { f, picker } = setup(false, { genericHeader: true, escapeOnlyClose: true }); picker.open();
        picker.nested.onDispatch = () => {};
        const pending = f.run('verifyModel', { expectedModelChoice: choice(initial) });
        for (let tick = 0; tick < 12; tick++) { await Promise.resolve(); f.flush(); }
        const result = await pending;
        expect(result).toMatchObject({ error: 'model_unverified', modelDiagnostic: { readStage: 'close_unconfirmed',
          readAttempt: { primaryOpened: false, secondaryOpened: false, closeAttempted: true, observedProof: true,
            sameTrigger: true, popupStillAssociated: true } } });
        expect(result.modelDiagnostic.associatedMenus.every((menu: any) => menu.visible)).toBe(true);
        expect(JSON.stringify(result.modelDiagnostic).length).toBeLessThanOrEqual(8192);
        expect(picker.nested.events.filter((event: any) => event.key === 'Escape').length).toBe(1);
        expect(picker.trigger.clicks).toBe(0);
      });

      test('a lost Escape acknowledgment cannot replay the close event in final cleanup', async () => {
        const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true, escapeOnlyClose: true }); picker.open();
        const close = picker.nested.onDispatch;
        picker.nested.onDispatch = (event: any) => { close(event); throw new Error('lost Escape acknowledgment'); };
        await expect(f.run('verifyModel', { expectedModelChoice: choice(initial) })).rejects.toThrow('lost Escape acknowledgment');
        expect(picker.nested.isConnected).toBe(false);
        expect(picker.nested.events.filter((event: any) => event.key === 'Escape').length).toBe(1);
        expect(picker.trigger.clicks).toBe(0);
      });

      test('failed discovery closure cannot replay its one claimed Escape', async () => {
        const { f, picker } = setup(false, { genericHeader: true, escapeOnlyClose: true }); picker.open();
        picker.nested.onDispatch = () => {};
        const pending = f.run('discoverModels');
        for (let tick = 0; tick < 12; tick++) { await Promise.resolve(); f.flush(); }
        expect((await pending).error).toBe('model_unverified');
        expect((await f.run('discoverModels')).error).toBe('model_unverified');
        expect(picker.nested.events.filter((event: any) => event.key === 'Escape').length).toBe(1);
        expect(picker.trigger.clicks).toBe(0);
      });
    }

    test('a generic header cannot reuse selection evidence when its menu association changed', async () => {
      const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
      await advance(f, 'selectModel', { modelChoice: choice(target) });
      delete picker.trigger.values['aria-controls']; delete picker.menu.values['aria-labelledby']; picker.open();
      expect(await f.run('verifyModel', { expectedModelChoice: choice(target) })).toMatchObject({ error: 'model_unverified' });
      expect(picker.options.find((option: any) => option.children[0].text === target).clicks).toBe(1);
    });

    test('generic-header verification catches drift during digest and does not admit a response', async () => {
      const { f, picker } = setup(true, { genericHeader: true, unmountMenus: true });
      f.onDigest(() => picker.selected(target));
      const result = await f.run('inspect', { expectedModelChoice: choice(initial) });
      expect(result).toMatchObject({ error: 'model_mismatch' }); expect(result.text).toBeUndefined();
      expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
    });

    test('fresh picker reads do not generate a transport wake loop but real model and response changes wake', async () => {
      const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
      await f.run('verifyModel', { expectedModelChoice: choice(initial) });
      const observer = f.observers[0];
      observer.callback([{ type: 'childList', target: f.body, addedNodes: [picker.menu], removedNodes: [] },
        { type: 'attributes', target: picker.trigger, attributeName: 'aria-expanded' }]);
      f.flush(); expect(f.posted.length).toBe(0);
      observer.callback([{ type: 'attributes', target: picker.options[0], attributeName: 'aria-checked' }]);
      f.flush(); expect(f.posted.length).toBe(1);
      observer.callback([{ type: 'childList', target: f.answer, addedNodes: [new Node('SPAN', {}, 'PRIVATE RESPONSE')], removedNodes: [] },
        { type: 'childList', target: f.body, addedNodes: [], removedNodes: [picker.menu] }]);
      f.flush(); expect(f.posted.length).toBe(2);
      expect(JSON.stringify(f.posted)).not.toContain('PRIVATE');
    });

    if (provider === 'gemini') test('real Gemini selection class and marker changes wake while active-only chrome and portal changes do not', async () => {
      const { f, picker } = setup(false, { genericHeader: true, geminiMenuitemMarkers: true });
      await f.run('verifyModel', { expectedModelChoice: choice(initial) });
      expect(f.observers[0].options.attributeOldValue).toBe(true);
      picker.open();
      const observer = f.observers[0], row = picker.options[0];
      row.values.class = 'ng-star-inserted active focused';
      observer.callback([{ type: 'attributes', target: row, attributeName: 'class', oldValue: 'ng-star-inserted' }]);
      f.flush(); expect(f.posted.length).toBe(0);
      row.values.class += ' selected';
      observer.callback([{ type: 'attributes', target: row, attributeName: 'class', oldValue: 'ng-star-inserted active focused' }]);
      f.flush(); expect(f.posted.length).toBe(1);
      const marker = new Node('GEM-ICON', { 'aria-label': 'Selected' }); row.append(marker);
      observer.callback([{ type: 'childList', target: row, addedNodes: [marker], removedNodes: [] }]);
      f.flush(); expect(f.posted.length).toBe(2);
      row.children = row.children.filter((node: any) => node !== marker);
      observer.callback([{ type: 'childList', target: row, addedNodes: [], removedNodes: [marker] }]);
      f.flush(); expect(f.posted.length).toBe(3);
      row.values.class = 'ng-star-inserted active';
      observer.callback([{ type: 'attributes', target: row, attributeName: 'class', oldValue: 'ng-star-inserted active focused selected' }]);
      f.flush(); expect(f.posted.length).toBe(4);
      observer.callback([{ type: 'childList', target: f.body, addedNodes: [picker.menu], removedNodes: [] },
        { type: 'attributes', target: picker.menu, attributeName: 'class', oldValue: 'closed' }]);
      f.flush(); expect(f.posted.length).toBe(4);
      picker.menu.connected = false;
      observer.callback([{ type: 'childList', target: f.body, addedNodes: [], removedNodes: [picker.menu] },
        { type: 'childList', target: row, addedNodes: [marker], removedNodes: [] }]);
      f.flush(); expect(f.posted.length).toBe(4);
    });

    if (provider === 'chatgpt') test('actual ChatGPT Send claims its old count before click and a lost acknowledgment cannot replay', async () => {
      const { f } = setup();
      const prompt = 'Synthetic first submit\n\n' + markerLine;
      f.composer.text = prompt; f.world.__computaModelFirstPrompt = prompt;
      const send = new Node('BUTTON', { 'data-testid': 'send-button' }); f.body.append(send);
      send.onClick = () => { expect(f.world.__computaModelLastSubmissionCount).toBe(0); throw new Error('lost Send acknowledgment'); };
      await expect(f.run('submit', { expectedUserCounts: [0, 1], expectedModelChoice: choice(initial), prompt }))
        .rejects.toThrow('lost Send acknowledgment');
      expect(f.world.__computaModelLastSubmissionCount).toBe(0); expect(send.clicks).toBe(1);
      expect((await f.run('submit', { expectedUserCounts: [0, 1], expectedModelChoice: choice(initial), prompt })).error).toBe('conversation_changed');
      expect(send.clicks).toBe(1);
    });

    test('more than twenty replaced portal IDs keep newest ownership bounded and never suppress unrelated events', async () => {
      const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
      let latest: any;
      for (let index = 0; index < 24; index++) {
        latest = new Node('DIV', { id: `fresh-model-menu-${index}`, role: 'menu', 'aria-labelledby': 'model-picker-button', hidden: '' });
        latest.connected = false;
        const selected = new Node('DIV', { role: 'menuitemradio', 'aria-checked': 'true' });
        selected.append(new Node('SPAN', {}, initial)); latest.append(selected); f.body.append(latest);
        picker.trigger.values['aria-controls'] = latest.values.id;
        const current = latest;
        picker.trigger.onClick = () => {
          if (current.values.hidden === undefined) { current.values.hidden = ''; current.connected = false; }
          else { delete current.values.hidden; current.connected = true; }
        };
        if (provider === 'chatgpt') current.onDispatch = (event: any) => {
          if (event.key === 'Escape') { current.values.hidden = ''; current.connected = false; }
        };
        expect((await f.run('verifyModel', { expectedModelChoice: choice(initial) })).modelEvidence.selected).toEqual(choice(initial));
        const scope = f.world.__computaModelReadUI;
        expect(scope.roots.length).toBeLessThanOrEqual(16); expect(scope.ids.length).toBeLessThanOrEqual(16);
        expect(scope.roots.includes(current)).toBe(true); expect(scope.roots.includes(picker.trigger)).toBe(true);
        expect(scope.ids.includes(current.values.id)).toBe(true);
        const before = f.posted.length;
        f.observers[0].callback([{ type: 'childList', target: f.body, addedNodes: [current], removedNodes: [] }]);
        f.flush(); expect(f.posted.length).toBe(before);
      }
      const before = f.posted.length;
      f.observers[0].callback([{ type: 'childList', target: f.answer, addedNodes: [new Node('SPAN', {}, 'PRIVATE RESPONSE')], removedNodes: [] }]);
      f.flush(); expect(f.posted.length).toBe(before + 1);
      f.observers[0].callback([{ type: 'attributes', target: picker.trigger, attributeName: 'aria-label' }]);
      f.flush(); expect(f.posted.length).toBe(before + 2);
    });

    test('response metadata diagnostics report model attribute names without promoting opaque values or prose', async () => {
      const { f } = setup(true);
      await f.run('inspect');
      const root = provider === 'chatgpt' ? f.answer.parentElement : f.response;
      root.values['data-model-id'] = 'PRIVATE OPAQUE BACKEND ID';
      root.values['data-model-label'] = initial;
      f.answer.append(new Node('SPAN', {}, 'I am ' + target));
      const result = await f.run('modelDiagnostic');
      expect(result.modelDiagnostic.responseMetadata).toMatchObject({ present: true,
        modelAttributes: [{ name: 'data-model-id', recognizedFamily: null, valueLength: 25 },
          { name: 'data-model-label', recognizedFamily: initial, valueLength: initial.length }] });
      expect(JSON.stringify(result.modelDiagnostic)).not.toContain('PRIVATE');
      expect(result.modelEvidence.response).toBeUndefined();
      const completed = await f.run('inspect', { expectedModelChoice: choice(initial) });
      expect(completed.modelDiagnostic.responseMetadata.modelAttributes).toEqual(result.modelDiagnostic.responseMetadata.modelAttributes);
      expect(completed.modelEvidence.verification).toBe('website_selection');
    });

    test('cleanup Stop remains usable after selected-model drift', async () => {
      const { f, picker } = setup();
      const stop = f.stop || new Node('BUTTON', { 'aria-label': 'Stop streaming' });
      if (!f.stop) f.body.append(stop); else stop.connected = true;
      expect(await f.run('stop', { expectedModelChoice: choice(target) })).toMatchObject({ stopped: true });
      expect(stop.clicks).toBe(1); expect(picker.trigger.clicks).toBe(0);
    });

    test('discovery and selection cannot mutate nonempty conversations', async () => {
      const { f, picker } = setup(true);
      await f.run('inspect');
      for (const action of ['discoverModels', 'selectModel'])
        expect(await f.run(action, { modelChoice: choice(target) })).toMatchObject({ error: 'not_fresh' });
      expect(picker.trigger.clicks).toBe(0);
    });

    test('bounded diagnostics omit private prompt, reply and account data', async () => {
      const { f, picker } = setup(true);
      await f.run('inspect');
      f.answer.append(new Node('SPAN', {}, 'PRIVATE REPLY SENTINEL'));
      picker.trigger.values['data-account-id'] = 'PRIVATE ACCOUNT SENTINEL';
      const result = await f.run('modelDiagnostic');
      const serialized = JSON.stringify(result.modelDiagnostic);
      expect(serialized).not.toContain('PRIVATE'); expect(serialized).not.toContain('Computa session marker');
      expect(serialized.length).toBeLessThanOrEqual(8192);
    });
  });
}
